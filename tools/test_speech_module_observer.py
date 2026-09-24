"""The consumer-visible state machine of tools/speech_module_observer.py.

Every test here drives the real Ledger through the real framers with real SSIP
bytes and reads back the index the run wrote: request_open, submission, block,
command, event, transaction_open and transaction_close. Nothing is mocked and
nothing is echoed back into the trace.


These claim nothing about executing a module. They are parser and state-machine
transitions over a recorded wire, and what they pin is the ownership rule: which
request owns a reply, which transaction owns an event, what is written down as
unknown when the bytes do not decide it, and what is written down as a fault
when a real fault happened.

The second half drives the real MetadataIndex against a real sidecar file on
disk: rows are appended exactly as the daemon appends them, read back through
the same read-only descriptor the run uses, and joined to the spans the framer
closed. Nothing is mocked there either, and what those tests pin is which
native message id a submission earns and what is written down when it earns
none.
"""

from __future__ import annotations

import errno
import fcntl
import importlib.util
import json
import os
import shutil
import signal
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

OBSERVER_PATH = Path(__file__).with_name("speech_module_observer.py")
OBSERVER_SPEC = importlib.util.spec_from_file_location("nogui_speech_module_observer", OBSERVER_PATH)
if OBSERVER_SPEC is None or OBSERVER_SPEC.loader is None:
    raise RuntimeError(f"cannot load observer from {OBSERVER_PATH}")
observer = importlib.util.module_from_spec(OBSERVER_SPEC)
OBSERVER_SPEC.loader.exec_module(observer)

# What the genuine 0.12.1 module writes, byte for byte.
ACCEPT = b"202 OK RECEIVING MESSAGE\n200 OK SPEAKING\n"
BEGIN = b"701 BEGIN\n"
END = b"702 END\n"
STOP = b"703 STOP\n"
PAUSE = b"704 PAUSE\n"

# The 705 header every chunk below declares.
CHANNELS = 1
BITS = 16
SAMPLE_RATE = 22050

# Four accepted verbs and the SPDMessageType cmd_speak hands module_speak_sync
# for each one.
SUBMISSION_CASES = (
    (b"SPEAK", b"<speak>alpha bravo</speak>", "SPD_MSGTYPE_TEXT"),
    (b"SOUND_ICON", b"sound-icon-name", "SPD_MSGTYPE_SOUND_ICON"),
    (b"CHAR", b"7", "SPD_MSGTYPE_CHAR"),
    (b"KEY", b"Return", "SPD_MSGTYPE_KEY"),
)


# The payload one chunk carries. The module HDLC-escapes 0x7d and 0x0a, so a
# bare payload may hold neither: a raw 0x0a ends the payload early and a raw
# 0x7d would be read as an escape. These values skip both, so the chunk below
# travels unescaped exactly as a real one can.
PCM = bytes(value for value in range(1, 65) if value not in (0x7D, 0x0A))[:32]
# What that payload decodes to, measured on the bytes themselves rather than
# declared anywhere.
PCM_BYTES = len(PCM)


def submission_chunks(verb: bytes, text: bytes) -> list:
    """One submission as the daemon really writes it: three separate writes.

    cmd_speak writes the verb line, then the payload, then the lone dot, and
    each one leaves through the pipe on its own. So a submission is never one
    native write, and a join that needs a single row to hold the whole span
    would refuse every real one.
    """
    return [verb + b"\n", text + b"\n", b".\n"]


def submission(verb: bytes, text: bytes) -> bytes:
    """One submission as the daemon writes it: verb line, payload, lone dot."""
    return b"".join(submission_chunks(verb, text))


# ── the daemon's own write records, exactly as it appends them ───────────────

# The physical facts one run agrees on. os.fstat(0) on this side and
# fstat(pipe_in[1]) on the daemon describe one pipe and so carry one pair, and
# the two births are the daemon and the proxy it forked.
STDIN_DEV = 66306
STDIN_INO = 918273
OBSERVER_PID = 4711
OBSERVER_TICKS = 987654
DAEMON_PID = 4700
DAEMON_TICKS = 123400
BOOT_ID = "0f3a1b2c-4d5e-6f70-8192-a3b4c5d6e7f8"
WRITE_FD = 12


def scope(identity_known: bool = True) -> dict:
    """The kernel facts a run publishes once and matches every row against."""
    return {
        "stdin_dev": STDIN_DEV,
        "stdin_ino": STDIN_INO,
        "observer_pid": OBSERVER_PID,
        "observer_start_ticks": OBSERVER_TICKS,
        "daemon_pid": DAEMON_PID,
        "daemon_start_ticks": DAEMON_TICKS,
        "boot_id": BOOT_ID,
        "identity_known": identity_known,
    }


def row(offset: int, written: int, requested: int, msg_id, client_id, client_fd,
        outcome: str = "complete", **overrides) -> dict:
    """One native write as the daemon publishes it.

    ``written`` is what the kernel took and ``requested`` is what was asked for.
    They are separate fields because a partial write is real, and a row that
    claimed the requested count would be a lie about the pipe.
    """
    entry = {
        "ver": observer.META_VERSION,
        "kind": observer.META_KIND,
        "daemon_pid": DAEMON_PID,
        "daemon_start_ticks": DAEMON_TICKS,
        "boot_id": BOOT_ID,
        "module_pid": OBSERVER_PID,
        "module_start_ticks": OBSERVER_TICKS,
        "pipe_dev": STDIN_DEV,
        "pipe_ino": STDIN_INO,
        "stream_epoch": 1,
        "write_fd": WRITE_FD,
        "msg_id": msg_id,
        "client_id": client_id,
        "client_fd": client_fd,
        "offset": offset,
        "written": written,
        "requested": requested,
        "outcome": outcome,
        "errno": None,
    }
    entry.update(overrides)
    return entry


def rows_for(chunks: list, offset: int, msg_id, client_id, client_fd, **overrides) -> list:
    """The native writes some consecutive chunks really are, in wire order.

    The offset advances by what the kernel took, never by what was asked for,
    so two writers can never be handed each other's extent.
    """
    made = []
    for chunk in chunks:
        made.append(row(offset, len(chunk), len(chunk), msg_id, client_id, client_fd, **overrides))
        offset += len(chunk)
    return made


def audio_chunk() -> bytes:
    """One 705 chunk whose declared header agrees with the payload it carries.

    The header is built from the constants above and the sample count from the
    payload's own length, so the chunk can never declare one thing and carry
    another: channels x samples x bits / 8 is exactly len(PCM).
    """
    samples = len(PCM) * 8 // (CHANNELS * BITS)
    header = (
        f"705-bits={BITS}\n705-num_channels={CHANNELS}\n"
        f"705-sample_rate={SAMPLE_RATE}\n705-num_samples={samples}\n705-big_endian=0\n"
    ).encode("ascii")
    return header + observer.AUDIO_MARKER + PCM + b"\n705 AUDIO\n"


class Run:
    """One trace directory, its two framers, its native reader, and the index.

    ``meta=True`` gives the run a sidecar path in its own private directory.
    The harness never writes one itself: the reader opens it read-only and the
    only writer is ``write_rows``, which appends exactly what the daemon
    appends and opens the file the way the daemon opens it.
    """

    def __init__(self, meta: bool = False, identity_known: bool = True) -> None:
        self.directory = tempfile.mkdtemp(prefix="nogui-module-observer-")
        # The observer refuses a trace directory anybody else can reach, so the
        # harness holds itself to the same rule the program enforces.
        observer.require_private_dir(self.directory)
        self.trace = observer.Trace(self.directory, ["/nonexistent/module"])
        self.ledger = observer.Ledger()
        self.meta_path = os.path.join(self.directory, "meta.jsonl") if meta else ""
        self.meta = observer.MetadataIndex(self.trace, self.meta_path, scope(identity_known))
        self.to_framer = observer.ToModuleFramer(self.trace, self.ledger)
        self.from_framer = observer.FromModuleFramer(self.trace, self.ledger)
        self.stamp = 0
        self.to_bytes = bytearray()
        self.from_bytes = bytearray()

    def to_module(self, data: bytes, rows: list | None = None) -> None:
        """The daemon's bytes in the pump's own order, then its own rows after.

        The rows are appended once the bytes are already in stdin.bin, which is
        the order the daemon really uses: it appends after its write returns,
        and the reader may see those rows before or after it traces the bytes.
        The spans the framer closed are handed over only after the handover has
        completed, exactly as the pump does it, so the reader's lock is never
        on the forwarding path.
        """
        self.stamp += 1
        self.trace.raw(self.trace.to_module, data, observer.TO_MODULE_NAME)
        self.to_framer.feed(data, self.stamp, self.stamp)
        self.trace.forwarded[observer.TO_MODULE_NAME] += len(data)
        self.to_bytes += data
        for span_kind, request_seq, verb, offset, length in self.to_framer.take_spans():
            self.meta.bind_span(span_kind, request_seq, verb, offset, length)
        if rows is not None:
            self.write_rows(rows)
            self.meta.read_available()
        self.meta.advance(self.trace.written[observer.TO_MODULE_NAME])

    def write_rows(self, rows: list, raw: bytes = b"") -> None:
        """Append what the daemon appends: one JSON row per line, created once."""
        if not os.path.exists(self.meta_path):
            handle = os.open(self.meta_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                             | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
        else:
            handle = os.open(self.meta_path, os.O_WRONLY | os.O_APPEND)
        with os.fdopen(handle, "wb") as out:
            for entry in rows:
                out.write(json.dumps(entry, separators=(",", ":")).encode("ascii") + b"\n")
            out.write(raw)
            out.flush()
            os.fsync(out.fileno())

    def sidecar_state(self) -> tuple:
        """The sidecar as the kernel sees it: bytes, mode, links and identity."""
        info = os.stat(self.meta_path)
        with open(self.meta_path, "rb") as handle:
            return (handle.read(), info.st_mode, info.st_nlink, info.st_ino)

    def from_module(self, data: bytes) -> None:
        """The module's bytes, in the pump's own order: raw, framing, handover."""
        self.stamp += 1
        self.trace.raw(self.trace.from_module, data, observer.FROM_MODULE_NAME)
        self.from_framer.feed(data, self.stamp, self.stamp)
        self.trace.forwarded[observer.FROM_MODULE_NAME] += len(data)
        self.from_bytes += data

    def end_of_output(self) -> None:
        self.from_framer.flush(self.stamp, self.stamp)

    def raw_file(self, name: str) -> bytes:
        with open(os.path.join(self.directory, name), "rb") as handle:
            return handle.read()

    def records(self) -> list:
        self.trace.close()
        path = os.path.join(self.directory, observer.EVENTS_NAME)
        with open(path, "rb") as handle:
            return [json.loads(line) for line in handle if line.strip()]

    def bindings(self) -> list:
        """The binding rows this run really wrote, read back off the disk."""
        with open(os.path.join(self.directory, observer.BINDINGS_NAME), "rb") as handle:
            return [json.loads(line) for line in handle if line.strip()]

    def close(self) -> None:
        self.meta.close()
        self.trace.close()
        shutil.rmtree(self.directory, ignore_errors=True)


class LedgerStateTests(unittest.TestCase):
    """Ownership transitions, read back off the index the run really wrote."""

    def setUp(self) -> None:
        self.run = Run()
        self.addCleanup(self.run.close)

    @staticmethod
    def of_kind(records: list, kind: str) -> list:
        return [record for record in records if record.get("kind") == kind]

    @staticmethod
    def events(records: list, shape: str) -> list:
        return [record for record in records
                if record.get("kind") == "event" and record.get("event_shape") == shape]

    def index(self) -> list:
        return self.run.records()

    # ── the shape the genuine trace really carried ──────────────────────────

    def speak_then_char_while_the_speech_is_still_open(self) -> None:
        """A SPEAK spoken to the end, then a CHAR written into the running one."""
        self.run.to_module(submission(b"SPEAK", b"<speak>alpha bravo</speak>"))
        self.run.from_module(ACCEPT)
        self.run.from_module(BEGIN)
        self.run.from_module(audio_chunk())
        self.run.to_module(submission(b"CHAR", b"7"))
        self.run.from_module(ACCEPT)
        self.run.from_module(BEGIN)
        self.run.from_module(audio_chunk())
        self.run.from_module(STOP)
        self.run.from_module(STOP)

    def test_a_char_accepted_while_a_speech_runs_owns_its_own_transaction(self) -> None:
        self.speak_then_char_while_the_speech_is_still_open()
        records = self.index()
        opens = self.of_kind(records, "transaction_open")
        closes = self.of_kind(records, "transaction_close")
        submissions = self.of_kind(records, "submission")

        self.assertEqual([open_["verb"] for open_ in opens], ["SPEAK", "CHAR"])
        self.assertEqual([open_["message_type"] for open_ in opens],
                         ["SPD_MSGTYPE_TEXT", "SPD_MSGTYPE_CHAR"])
        self.assertEqual([open_["supersedes_txn_id"] for open_ in opens],
                         [None, opens[0]["txn_id"]])
        self.assertEqual([(sub["verb"], sub["message_type"]) for sub in submissions],
                         [("SPEAK", "SPD_MSGTYPE_TEXT"), ("CHAR", "SPD_MSGTYPE_CHAR")])
        self.assertEqual([sub["request_seq"] for sub in submissions],
                         [open_["request_seq"] for open_ in opens])
        self.assertEqual([close["request_seq"] for close in closes],
                         [open_["request_seq"] for open_ in opens])
        self.assertEqual([close["close_reason"] for close in closes],
                         ["superseded-by-accepted-submission", "closing-event"])
        self.assertEqual([close["unclosed"] for close in closes], [True, False])
        self.assertIn("no 702 END, 703 STOP or 704 PAUSE", closes[0]["ownership_note"])
        self.assertEqual(closes[1]["closed_by"], "703 STOP")

    def test_the_retained_char_never_credits_the_speak_transaction(self) -> None:
        self.speak_then_char_while_the_speech_is_still_open()
        records = self.index()
        opens = self.of_kind(records, "transaction_open")
        closes = self.of_kind(records, "transaction_close")
        speak_txn = opens[0]["txn_id"]
        char_txn = opens[1]["txn_id"]
        char_request = opens[1]["request_seq"]

        acceptances = [event for event in self.events(records, "handshake")
                       if event["reply_code"] == observer.SPEAKING_CODE]
        self.assertEqual([event["owner_request_seq"] for event in acceptances],
                         [opens[0]["request_seq"], char_request])
        self.assertEqual(acceptances[1]["superseded_txn_id"], speak_txn)
        self.assertNotIn("violation", acceptances[1])
        char_accepted_at = acceptances[1]["offset"]

        for event in self.of_kind(records, "event"):
            if event["offset"] >= char_accepted_at:
                self.assertNotEqual(event.get("owner_txn_id"), speak_txn,
                                    f"the SPEAK transaction owns the message at offset {event['offset']}, "
                                    "which is at or after the CHAR acceptance")

        char_audio = [event for event in self.events(records, "audio")
                      if event["offset"] >= char_accepted_at]
        self.assertEqual(len(char_audio), 1)
        self.assertEqual(char_audio[0]["owner_txn_id"], char_txn)
        self.assertEqual(char_audio[0]["owner_submission_request_seq"], char_request)
        self.assertEqual(char_audio[0]["audio"]["pcm_length"], PCM_BYTES)
        self.assertNotIn("audio_error", char_audio[0])

        begins = self.events(records, "begin")
        self.assertEqual([begin["owner_txn_id"] for begin in begins], [speak_txn, char_txn])
        for begin in begins:
            self.assertNotIn("violation", begin)

        self.assertEqual(closes[0]["audio_chunks"], 1)
        self.assertEqual(closes[0]["pcm_bytes"], PCM_BYTES)
        self.assertEqual(closes[1]["audio_chunks"], 1)
        self.assertEqual(closes[1]["pcm_bytes"], PCM_BYTES)
        self.assertNotIn(char_audio[0]["offset"], closes[0]["event_offsets"])
        self.assertIn(begins[0]["offset"], closes[0]["event_offsets"])
        self.assertNotIn(begins[0]["offset"], closes[1]["event_offsets"])
        self.assertIn(begins[1]["offset"], closes[1]["event_offsets"])

    def test_the_second_stop_is_refused_rather_than_borrowed(self) -> None:
        self.speak_then_char_while_the_speech_is_still_open()
        records = self.index()
        opens = self.of_kind(records, "transaction_open")
        stops = self.events(records, "stopped")
        self.assertEqual(len(stops), 2)
        self.assertEqual(stops[0]["owner_txn_id"], opens[1]["txn_id"])
        self.assertIsNone(stops[1]["owner_txn_id"])
        self.assertIsNone(stops[1]["owner_submission_request_seq"])
        self.assertIn("no transaction open", stops[1]["ownership_note"])
        self.assertEqual(len(self.of_kind(records, "transaction_close")), 2)

    # ── the verbs themselves ────────────────────────────────────────────────

    def test_every_accepted_submission_verb_opens_its_own_transaction(self) -> None:
        for verb, text, _ in SUBMISSION_CASES:
            self.run.to_module(submission(verb, text))
            self.run.from_module(ACCEPT)
            self.run.from_module(BEGIN)
            self.run.from_module(audio_chunk())
            self.run.from_module(END)
        records = self.index()
        opens = self.of_kind(records, "transaction_open")
        closes = self.of_kind(records, "transaction_close")
        submissions = self.of_kind(records, "submission")
        self.assertEqual([open_["verb"] for open_ in opens],
                         ["SPEAK", "SOUND_ICON", "CHAR", "KEY"])
        self.assertEqual([open_["message_type"] for open_ in opens],
                         [message_type for _, _, message_type in SUBMISSION_CASES])
        self.assertEqual([sub["request_seq"] for sub in submissions],
                         [open_["request_seq"] for open_ in opens])
        self.assertEqual([close["request_seq"] for close in closes],
                         [open_["request_seq"] for open_ in opens])
        self.assertEqual([close["close_reason"] for close in closes], ["closing-event"] * 4)
        self.assertEqual([close["audio_chunks"] for close in closes], [1] * 4)
        self.assertEqual([open_["supersedes_txn_id"] for open_ in opens],
                         [None] * len(SUBMISSION_CASES))

    def test_a_second_begin_without_a_new_accepted_submission_is_a_violation(self) -> None:
        self.run.to_module(submission(b"SPEAK", b"<speak>alpha</speak>"))
        self.run.from_module(ACCEPT)
        self.run.from_module(BEGIN)
        self.run.from_module(BEGIN)
        self.run.from_module(audio_chunk())
        self.run.from_module(END)
        records = self.index()
        begins = self.events(records, "begin")
        self.assertEqual(len(begins), 2)
        self.assertEqual(begins[1]["owner_txn_id"], begins[0]["owner_txn_id"])
        self.assertIn("already began", begins[1]["violation"])
        opens = self.of_kind(records, "transaction_open")
        closes = self.of_kind(records, "transaction_close")
        self.assertEqual(len(opens), 1)
        self.assertEqual(len(closes), 1)
        self.assertEqual(closes[0]["audio_chunks"], 1)

    def test_a_begin_with_no_accepted_submission_in_front_of_it_names_no_owner(self) -> None:
        self.run.from_module(BEGIN)
        self.run.from_module(audio_chunk())
        self.run.end_of_output()
        records = self.index()
        self.assertEqual(self.of_kind(records, "transaction_open"), [])
        self.assertEqual(self.of_kind(records, "transaction_close"), [])
        for event in self.of_kind(records, "event"):
            self.assertIsNone(event["owner_txn_id"])
            self.assertIsNone(event["owner_submission_request_seq"])
            self.assertIn("no transaction open", event["ownership_note"])

    # ── what does NOT move a transaction ────────────────────────────────────

    def test_a_refused_submission_opens_nothing_and_leaves_the_open_speech_alone(self) -> None:
        self.run.to_module(submission(b"SPEAK", b"<speak>alpha</speak>"))
        self.run.from_module(ACCEPT)
        self.run.from_module(BEGIN)
        self.run.to_module(submission(b"KEY", b"Return"))
        self.run.from_module(b"202 OK RECEIVING MESSAGE\n")
        self.run.from_module(b"401 ERR UNKNOWN KEY\n")
        self.run.from_module(audio_chunk())
        self.run.from_module(END)
        records = self.index()
        opens = self.of_kind(records, "transaction_open")
        closes = self.of_kind(records, "transaction_close")
        self.assertEqual(len(opens), 1)
        self.assertEqual(len(closes), 1)
        self.assertEqual(closes[0]["close_reason"], "closing-event")
        self.assertEqual(closes[0]["audio_chunks"], 1)
        refusal = [event for event in self.events(records, "handshake")
                   if event["reply_code"] == 401]
        self.assertEqual(len(refusal), 1)
        self.assertEqual(refusal[0]["reply_disposition"], "refuse")
        self.assertEqual(refusal[0]["owner_request_seq"], self.of_kind(records, "submission")[1]["request_seq"])
        self.assertIsNone(refusal[0]["owner_txn_id"])
        for audio in self.events(records, "audio"):
            self.assertEqual(audio["owner_txn_id"], opens[0]["txn_id"])

    def test_a_settings_block_written_during_a_speech_takes_no_ownership(self) -> None:
        self.run.to_module(submission(b"SPEAK", b"<speak>alpha</speak>"))
        self.run.from_module(ACCEPT)
        self.run.from_module(BEGIN)
        self.run.to_module(b"SET\nrate=0\n.\n")
        self.run.from_module(b"203 OK RECEIVING SETTINGS\n")
        self.run.from_module(b"203 OK RECEIVING PARAMETERS\n")
        self.run.from_module(audio_chunk())
        self.run.from_module(END)
        records = self.index()
        opens = self.of_kind(records, "transaction_open")
        closes = self.of_kind(records, "transaction_close")
        blocks = self.of_kind(records, "block")
        self.assertEqual(len(opens), 1)
        self.assertEqual(len(closes), 1)
        self.assertEqual(len(blocks), 1)
        self.assertNotEqual(blocks[0]["request_seq"], opens[0]["request_seq"])
        self.assertEqual(closes[0]["audio_chunks"], 1)
        for audio in self.events(records, "audio"):
            self.assertEqual(audio["owner_txn_id"], opens[0]["txn_id"])

    def test_a_pause_closes_the_transaction_it_arrives_in(self) -> None:
        self.run.to_module(submission(b"SPEAK", b"<speak>alpha</speak>"))
        self.run.from_module(ACCEPT)
        self.run.from_module(BEGIN)
        self.run.from_module(audio_chunk())
        self.run.from_module(PAUSE)
        self.run.from_module(audio_chunk())
        records = self.index()
        opens = self.of_kind(records, "transaction_open")
        closes = self.of_kind(records, "transaction_close")
        paused = self.events(records, "paused")
        self.assertEqual(len(paused), 1)
        self.assertEqual(paused[0]["owner_txn_id"], opens[0]["txn_id"])
        self.assertEqual(len(closes), 1)
        self.assertEqual(closes[0]["close_reason"], "closing-event")
        self.assertFalse(closes[0]["unclosed"])
        self.assertEqual(closes[0]["closed_by"], "704 PAUSE")
        self.assertEqual(closes[0]["audio_chunks"], 1)
        trailing = self.events(records, "audio")[1]
        self.assertIsNone(trailing["owner_txn_id"])
        self.assertIn("no transaction open", trailing["ownership_note"])
        self.assertNotIn(trailing["offset"], closes[0]["event_offsets"])

    # ── the ambiguous window between a replacement and its own begin ─────────

    def test_events_before_the_new_begin_after_a_supersede_name_no_owner(self) -> None:
        self.run.to_module(submission(b"SPEAK", b"<speak>alpha bravo</speak>"))
        self.run.from_module(ACCEPT)
        self.run.from_module(BEGIN)
        self.run.from_module(audio_chunk())
        self.run.to_module(submission(b"CHAR", b"7"))
        self.run.from_module(ACCEPT)
        self.run.from_module(audio_chunk())
        self.run.from_module(BEGIN)
        self.run.from_module(END)
        records = self.index()
        opens = self.of_kind(records, "transaction_open")
        closes = self.of_kind(records, "transaction_close")
        char_request = opens[1]["request_seq"]
        accepted_at = next(event["offset"] for event in self.events(records, "handshake")
                           if event["reply_code"] == observer.SPEAKING_CODE
                           and event["owner_request_seq"] == char_request)
        began_at = self.events(records, "begin")[1]["offset"]
        between = [event for event in self.of_kind(records, "event")
                   if accepted_at < event["offset"] < began_at]
        self.assertEqual(len(between), 1)
        self.assertIsNone(between[0]["owner_txn_id"])
        self.assertIsNone(between[0]["owner_submission_request_seq"])
        self.assertIn("before transaction", between[0]["ownership_note"])
        self.assertNotIn(between[0]["offset"], closes[1]["event_offsets"])
        self.assertEqual(closes[1]["audio_chunks"], 0)
        self.assertEqual(closes[1]["pcm_bytes"], 0)

    # ── an ending that never arrived ─────────────────────────────────────────

    def test_an_open_transaction_at_end_of_output_is_reported_unclosed(self) -> None:
        self.run.to_module(submission(b"SPEAK", b"<speak>alpha</speak>"))
        self.run.from_module(ACCEPT)
        self.run.from_module(BEGIN)
        self.run.from_module(audio_chunk())
        self.run.end_of_output()
        records = self.index()
        closes = self.of_kind(records, "transaction_close")
        self.assertEqual(len(closes), 1)
        self.assertTrue(closes[0]["unclosed"])
        self.assertEqual(closes[0]["close_reason"], "module-output-ended")
        self.assertIsNone(closes[0]["closed_by"])
        self.assertIsNone(closes[0]["closed_by_code"])
        self.assertEqual(closes[0]["audio_chunks"], 1)

    def test_a_superseded_transaction_is_closed_once_and_never_reopened(self) -> None:
        self.speak_then_char_while_the_speech_is_still_open()
        records = self.index()
        closes = self.of_kind(records, "transaction_close")
        opens = self.of_kind(records, "transaction_open")
        self.assertEqual(len(opens), 2)
        self.assertEqual(len(closes), 2)
        self.assertEqual(sorted(close["txn_id"] for close in closes),
                         sorted(open_["txn_id"] for open_ in opens))
        self.assertEqual(closes[0]["supersedes_txn_id"], None)
        self.assertEqual(closes[1]["supersedes_txn_id"], closes[0]["txn_id"])

    # ── the bytes the index describes ───────────────────────────────────────

    def test_every_index_offset_slices_the_raw_stream_it_names(self) -> None:
        self.speak_then_char_while_the_speech_is_still_open()
        records = self.index()
        to_bytes = self.run.raw_file(observer.TO_MODULE_NAME)
        from_bytes = self.run.raw_file(observer.FROM_MODULE_NAME)
        self.assertEqual(to_bytes, bytes(self.run.to_bytes))
        self.assertEqual(from_bytes, bytes(self.run.from_bytes))
        for record in records:
            if record.get("kind") == "submission":
                span = to_bytes[record["offset"]:record["offset"] + record["length"]]
                self.assertTrue(span.startswith(record["verb"].encode("ascii")), span[:16])
            if record.get("kind") == "event":
                head = from_bytes[record["offset"]:record["offset"] + record["length"]]
                self.assertTrue(head.startswith(record["head"].encode("utf-8")), head[:32])
        audio = self.events(records, "audio")
        self.assertEqual(len(audio), 2)
        for event in audio:
            chunk = from_bytes[event["audio"]["escaped_offset"]:
                               event["audio"]["escaped_offset"] + event["audio"]["escaped_length"]]
            self.assertEqual(len(observer.hdlc_decode(chunk)), event["audio"]["pcm_length"])


class NativeCarrierTests(unittest.TestCase):
    """Which native message id a closed daemon->module span earns, and why.

    Every test here drives the real MetadataIndex over a real sidecar on disk.
    The only writer is the harness, and it appends exactly what the daemon
    appends; the reader opens the file the way the run does and never writes
    it. What is pinned is the attribution itself and the refusal: which id a
    submission earns, that two messages on one connection separate by their own
    ids, and that nothing which is not the bytes' own joined coverage ever
    becomes an id.
    """

    def setUp(self) -> None:
        self.run = Run(meta=True)
        self.addCleanup(self.run.close)

    # ── driving the daemon's side of the wire ──────────────────────────────

    def say(self, verb: bytes, text: bytes, msg_id, client_id: int = 1,
            client_fd: int = 7, **overrides) -> None:
        """One submission as the daemon wrote it: its bytes, then its own rows."""
        chunks = submission_chunks(verb, text)
        offset = len(self.run.to_bytes)
        self.run.to_module(b"".join(chunks),
                           rows_for(chunks, offset, msg_id, client_id, client_fd, **overrides))

    def control(self, line: bytes, msg_id=None, client_id=None, client_fd=None,
                **overrides) -> None:
        """One command line as the daemon wrote it, with the owner it had."""
        offset = len(self.run.to_bytes)
        self.run.to_module(line, [row(offset, len(line), len(line), msg_id, client_id,
                                      client_fd, **overrides)])

    # ── reading the answer back ────────────────────────────────────────────

    def decided(self) -> list:
        """Close the sideband, then read every binding the run really decided."""
        self.run.meta.finish()
        return self.run.bindings()

    def submissions(self) -> list:
        return [b for b in self.decided() if b["span_kind"] == "submission"]

    def one(self, verb: str) -> dict:
        found = [b for b in self.decided() if b["verb"] == verb]
        self.assertEqual(len(found), 1, f"exactly one binding names a {verb} span")
        return found[0]

    # ── what the join gets right ───────────────────────────────────────────

    def test_two_messages_from_one_client_take_their_own_ids(self) -> None:
        self.say(b"SPEAK", b"<speak>alpha bravo</speak>", 1)
        self.say(b"CHAR", b"7", 2)
        bound = self.submissions()
        self.assertEqual([b["native_msg_id"] for b in bound], [1, 2])
        self.assertEqual([b["native_state"] for b in bound], ["rooted", "rooted"])
        self.assertEqual([b["native_reason"] for b in bound], [None, None])
        self.assertEqual([b["native_client_id"] for b in bound], [1, 1])
        self.assertEqual([b["native_client_fd"] for b in bound], [7, 7])
        # Each submission is three native writes and no single row holds it, so
        # the join has to be the union of contiguous rows or it refuses every
        # real one.
        self.assertEqual([b["native_covering_writes"] for b in bound], [3, 3])
        self.assertEqual([b["native_covering_union"] for b in bound],
                         [[[b["offset"], b["end_offset"]]] for b in bound])
        submissions = [r for r in self.run.records() if r["kind"] == "submission"]
        self.assertEqual([b["request_seq"] for b in bound],
                         [s["request_seq"] for s in submissions])
        self.assertEqual([b["offset"] for b in bound], [s["offset"] for s in submissions])
        self.assertEqual([b["length"] for b in bound], [s["length"] for s in submissions])

    def test_the_id_comes_from_the_row_and_not_from_where_the_span_sits(self) -> None:
        self.say(b"SPEAK", b"<speak>alpha</speak>", 41)
        self.say(b"CHAR", b"7", 77)
        first = [b["native_msg_id"] for b in self.submissions()]
        other = Run(meta=True)
        self.addCleanup(other.close)
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        other.to_module(b"".join(chunks), rows_for(chunks, 0, 5, 1, 7))
        chunks = submission_chunks(b"CHAR", b"7")
        offset = len(other.to_bytes)
        other.to_module(b"".join(chunks), rows_for(chunks, offset, 6, 1, 7))
        other.meta.finish()
        second = [b["native_msg_id"] for b in other.bindings() if b["span_kind"] == "submission"]
        self.assertEqual(first, [41, 77])
        self.assertEqual(second, [5, 6])

    def test_a_message_id_of_zero_is_a_real_id_and_never_absent(self) -> None:
        self.say(b"SPEAK", b"<speak>alpha</speak>", 0)
        bound = self.one("SPEAK")
        self.assertEqual(bound["native_state"], "rooted")
        self.assertEqual(bound["native_msg_id"], 0)
        self.assertIsNone(bound["native_reason"])

    def test_nothing_is_decided_until_the_sidecar_is_closed_and_a_span_is_bound_once(self) -> None:
        """A live sideband says nothing at all, and a span is bound exactly once.

        A row the daemon has not appended yet and a row it will never append
        look identical from inside a live run, so this program writes no verdict
        until the file is closed. That is also what makes a published id safe:
        every row is already in hand when the one verdict for the span is
        written, and a verdict in a file can never need to be taken back.
        """
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        data = b"".join(chunks)
        self.run.to_module(data)
        self.assertEqual(self.run.bindings(), [],
                         "no verdict exists while the daemon's rows are missing")
        self.run.write_rows(rows_for(chunks, 0, 9, 1, 7))
        self.run.meta.read_available()
        self.run.meta.advance(self.run.trace.written[observer.TO_MODULE_NAME])
        self.assertEqual(self.run.bindings(), [],
                         "the rows are in and still nothing is decided")
        self.run.meta.finish()
        self.run.meta.finish()
        bound = self.run.bindings()
        self.assertEqual(len(bound), 1, "a span is bound exactly once, however often finish runs")
        self.assertEqual(bound[0]["native_msg_id"], 9)
        self.assertEqual(bound[0]["native_state"], "rooted")
        self.assertEqual(bound[0]["binding_seq"], 1)

    # ── a typed null owner against a real gap ───────────────────────────────

    def test_a_stop_carries_no_message_and_never_the_one_it_interrupted(self) -> None:
        self.say(b"SPEAK", b"<speak>alpha</speak>", 1)
        self.control(b"STOP\n")
        stop = self.one("STOP")
        self.assertEqual(stop["native_state"], "control")
        self.assertIsNone(stop["native_msg_id"])
        self.assertIsNone(stop["native_reason"])
        self.assertEqual(self.one("SPEAK")["native_msg_id"], 1)

    def test_a_typed_null_owner_is_not_the_same_answer_as_no_coverage(self) -> None:
        self.say(b"SPEAK", b"<speak>alpha</speak>", 1)
        self.control(b"STOP\n")
        self.run.to_module(b"SET\nrate=0\n.\n")
        stop = self.one("STOP")
        settings = self.one("SET")
        self.assertEqual(stop["native_state"], "control")
        self.assertIsNone(stop["native_reason"])
        self.assertEqual(settings["native_state"], "unknown")
        self.assertEqual(settings["native_reason"], "no_metadata_covers_span")
        self.assertIsNone(settings["native_msg_id"])
        self.assertEqual(self.one("SPEAK")["native_msg_id"], 1)

    # ── every way the join must refuse ─────────────────────────────────────

    def test_rows_that_stop_partway_leave_the_submission_unknown(self) -> None:
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        self.run.to_module(b"".join(chunks), rows_for(chunks[:1], 0, 1, 1, 7))
        bound = self.one("SPEAK")
        self.assertEqual(bound["native_state"], "unknown")
        self.assertEqual(bound["native_reason"], "metadata_incomplete")
        self.assertIsNone(bound["native_msg_id"])
        self.assertEqual(bound["native_covering_writes"], 0)

    def test_a_hole_between_native_writes_stops_the_sidecar_for_good(self) -> None:
        first = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        self.run.to_module(b"".join(first), rows_for(first, 0, 1, 1, 7))
        second = submission_chunks(b"CHAR", b"7")
        offset = len(b"".join(first))
        self.run.to_module(b"".join(second), rows_for(second, offset + 4, 2, 1, 7))
        third = submission_chunks(b"KEY", b"Return")
        offset += len(b"".join(second))
        self.run.to_module(b"".join(third), rows_for(third, offset, 3, 1, 7))
        self.assertEqual(self.run.bindings(), [],
                         "a run that has hit a fault still decides nothing until it ends")
        self.assertEqual(self.one("SPEAK")["native_msg_id"], 1)
        for verb in ("CHAR", "KEY"):
            bound = self.one(verb)
            self.assertEqual(bound["native_state"], "unknown")
            self.assertEqual(bound["native_reason"], "meta_gap")
            self.assertIsNone(bound["native_msg_id"])
        self.assertTrue(any(fault.startswith("meta_gap") for fault in self.run.meta.summary()["faults"]))

    def test_rows_naming_another_pipe_daemon_or_proxy_are_refused(self) -> None:
        cases = {
            "meta_other_pipe": {"pipe_ino": STDIN_INO + 1},
            "meta_other_daemon": {"daemon_start_ticks": DAEMON_TICKS + 1},
            "meta_other_proxy": {"module_start_ticks": OBSERVER_TICKS + 1},
        }
        for reason, change in cases.items():
            with self.subTest(reason=reason):
                run = Run(meta=True)
                self.addCleanup(run.close)
                chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
                run.to_module(b"".join(chunks), rows_for(chunks, 0, 1, 1, 7, **change))
                run.meta.finish()
                bound = next(b for b in run.bindings() if b["span_kind"] == "submission")
                self.assertEqual(bound["native_state"], "unknown")
                self.assertEqual(bound["native_reason"], reason)
                self.assertIsNone(bound["native_msg_id"])
                self.assertEqual(run.meta.summary()["records_excluded"], {reason: 3})

    def test_rows_from_another_boot_are_refused_however_right_the_inode_number_is(self) -> None:
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        self.run.to_module(
            b"".join(chunks),
            rows_for(chunks, 0, 1, 1, 7, boot_id="11111111-2222-3333-4444-555555555555"))
        bound = self.one("SPEAK")
        self.assertEqual(bound["native_reason"], "meta_boot_conflict")
        self.assertIsNone(bound["native_msg_id"])

    def test_a_second_epoch_on_one_pipe_is_a_conflict_and_neither_is_picked(self) -> None:
        first = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        self.run.to_module(b"".join(first), rows_for(first, 0, 1, 1, 7))
        second = submission_chunks(b"CHAR", b"7")
        offset = len(b"".join(first))
        self.run.to_module(b"".join(second), rows_for(second, offset, 2, 1, 7, stream_epoch=2))
        self.assertEqual(self.run.bindings(), [],
                         "a live sideband decides nothing, not even after a fault")
        self.assertEqual(self.one("SPEAK")["native_msg_id"], 1)
        bound = self.one("CHAR")
        self.assertEqual(bound["native_state"], "unknown")
        self.assertEqual(bound["native_reason"], "meta_epoch_conflict")
        self.assertIsNone(bound["native_msg_id"])

    def test_a_re_armed_module_instance_restarts_the_offset_and_the_epoch_is_named_first(self) -> None:
        """The native shape of a second epoch: the same inode, the offset back at zero.

        ``output_init_module_audit`` zeroes ``audit_off`` and bumps the daemon's
        process-wide ``audit_epoch`` in one locked step, so every write a
        re-armed instance makes starts at offset zero again - on the pipe and
        the proxy birth this run already joined, which is what keeps the row
        from being refused as somebody else's before the epoch is ever read.

        The row that arrives is also the one every instance really writes
        first: INIT, with the daemon's explicit null owner and the count that
        really moved. Read as anything but an epoch change it would be
        misnamed - a hole, an overlap or a regression of the stream - and this
        pins that the epoch is decided before the offset is, and that the
        extent the new epoch claims is refused for both writers rather than
        credited to the one that happened to be believed first.
        """
        first = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        self.run.to_module(b"".join(first), rows_for(first, 0, 1, 1, 7))
        self.run.to_module(b"INIT\n", [row(0, 5, 5, None, None, None, stream_epoch=2)])
        summary = self.run.meta.summary()
        self.assertEqual(summary["records_matched"], 3,
                         "the three rows of the first epoch were covered; the second epoch's row is not "
                         "a fourth")
        self.assertEqual(len(summary["faults"]), 1, summary["faults"])
        self.assertIn("meta_epoch_conflict", summary["faults"][0])
        for misnamed in ("meta_gap", "meta_overlap", "meta_offset_regression"):
            self.assertNotIn(misnamed, summary["faults"][0],
                             "a row whose epoch moved is an epoch conflict, not a stream fault")
        self.assertEqual(summary["scope"]["stream_epoch"], 1,
                         "the epoch this run joined is still the one it reports")
        self.assertEqual(self.run.bindings(), [],
                         "a live sideband decides nothing, not even after a fault")
        spoken = self.one("SPEAK")
        self.assertEqual(spoken["native_state"], "unknown")
        self.assertEqual(spoken["native_reason"], "meta_epoch_conflict")
        self.assertIsNone(spoken["native_msg_id"],
                          "the bytes the second epoch also claims belong to neither writer")
        self.assertEqual(spoken["native_pipe_ino"], STDIN_INO)
        self.assertEqual(spoken["native_stream_epoch"], 1)
        rearmed = self.one("INIT")
        self.assertEqual(rearmed["native_state"], "unknown")
        self.assertEqual(rearmed["native_reason"], "meta_epoch_conflict")
        self.assertIsNone(rearmed["native_msg_id"],
                          "a re-armed instance's own first write earns nothing from the epoch before it")

    def test_a_command_that_only_partly_moved_cannot_carry_a_whole_submission(self) -> None:
        """A partial write is a real write, and it names the failure it hit.

        The daemon records what the kernel really returned, so its error row
        carries that errno. An error naming no failure at all is a different
        shape, and it is refused as the contradiction it is; see
        test_an_error_row_naming_no_failure_is_refused.
        """
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        rows = rows_for(chunks[:-1], 0, 1, 1, 7)
        tail = chunks[-1]
        rows.append(row(len(b"".join(chunks[:-1])), len(tail) - 1, len(tail),
                        1, 1, 7, outcome="error", errno=-32))
        self.run.to_module(b"".join(chunks), rows)
        bound = self.one("SPEAK")
        self.assertEqual(bound["native_state"], "unknown")
        self.assertEqual(bound["native_reason"], "partial_write_in_span")
        self.assertIsNone(bound["native_msg_id"])

    def test_a_write_of_no_bytes_is_a_row_that_covers_nothing_and_breaks_nothing(self) -> None:
        """An empty payload leaves a complete row that moved no byte at all.

        output_write_all is a while (sent < count) loop, so a zero-length
        command makes no syscall, cannot fail, and is complete. The row is real
        and is read as one: it advances no offset and covers no byte, so it
        neither fills a hole nor invents one, and the next message still roots
        to its own id.
        """
        first = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        self.run.to_module(b"".join(first), rows_for(first, 0, 1, 1, 7))
        offset = len(b"".join(first))
        self.run.write_rows([row(offset, 0, 0, 2, 1, 7)])
        self.run.meta.read_available()
        self.run.meta.advance(self.run.trace.written[observer.TO_MODULE_NAME])
        second = submission_chunks(b"CHAR", b"7")
        self.run.to_module(b"".join(second), rows_for(second, offset, 3, 1, 7))
        self.run.meta.finish()
        bound = {b["verb"]: b["native_msg_id"] for b in self.run.bindings()}
        self.assertEqual(bound, {"SPEAK": 1, "CHAR": 3})
        self.assertEqual(self.run.meta.summary()["records_matched"], 7)
        self.assertEqual(self.run.meta.summary()["faults"], [])

    def test_a_row_claiming_both_a_complete_write_and_an_errno_is_refused(self) -> None:
        """A complete write that also carries an errno contradicts itself.

        The daemon's own rule is that a whole count moved means no error, so a
        row saying both cannot be believed about the extent it claims, and the
        bytes it would have covered are unknown rather than covered.
        """
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        rows = rows_for(chunks, 0, 1, 1, 7)
        rows[1]["errno"] = 32
        self.run.to_module(b"".join(chunks), rows)
        bound = self.one("SPEAK")
        self.assertEqual(bound["native_state"], "unknown")
        self.assertEqual(bound["native_reason"], "meta_outcome_contradiction")
        self.assertIsNone(bound["native_msg_id"])

    def test_two_rows_covering_one_span_that_name_different_messages_conflict(self) -> None:
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        split = len(chunks[0]) + len(chunks[1])
        rows = rows_for(chunks[:2], 0, 1, 1, 7) + rows_for(chunks[2:], split, 2, 1, 7)
        self.run.to_module(b"".join(chunks), rows)
        bound = self.one("SPEAK")
        self.assertEqual(bound["native_state"], "unknown")
        self.assertEqual(bound["native_reason"], "msg_id_conflict")
        self.assertIsNone(bound["native_msg_id"])

    def test_rows_that_agree_on_the_message_and_disagree_on_the_client_are_refused(self) -> None:
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        split = len(chunks[0]) + len(chunks[1])
        rows = rows_for(chunks[:2], 0, 1, 1, 7) + rows_for(chunks[2:], split, 1, 2, 9)
        self.run.to_module(b"".join(chunks), rows)
        bound = self.one("SPEAK")
        self.assertEqual(bound["native_state"], "unknown")
        self.assertEqual(bound["native_reason"], "scope_conflict")
        self.assertIsNone(bound["native_msg_id"])

    def test_a_torn_last_row_is_not_a_row_and_the_bytes_it_would_have_named_stay_unknown(self) -> None:
        """A half-written row is not a row, and its position is not a stream one.

        The torn bytes sit at a position in the SIDECAR, which says nothing at
        all about the pipe. What does say something is that coverage stops at
        the end of the last extent really covered, so the two positions are
        reported in their own coordinates and never compared with each other.
        """
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        rows = rows_for(chunks[:2], 0, 1, 1, 7)
        self.run.to_module(b"".join(chunks), rows)
        whole = os.stat(self.run.meta_path).st_size
        self.run.write_rows([], raw=b'{"ver":1,"kind":1,"offset":12,"writt')
        self.run.meta.read_available()
        bound = self.one("SPEAK")
        self.assertEqual(bound["native_state"], "unknown")
        self.assertEqual(bound["native_reason"], "meta_torn_line")
        self.assertIsNone(bound["native_msg_id"])
        summary = self.run.meta.summary()
        # A position in the sidecar's own bytes, and nothing else.
        self.assertEqual(summary["torn_record_at_sidecar_byte"], whole)
        self.assertEqual(summary["coverage"]["fault_at_sidecar_byte"], whole)
        # A position in the daemon->module stream, and nothing else. It is a
        # different number entirely: two rows are far more bytes than the two
        # writes they describe.
        self.assertEqual(summary["coverage"]["stopped_at_stream_byte"], len(b"".join(chunks[:2])))
        self.assertNotEqual(summary["coverage"]["stopped_at_stream_byte"], whole)

    def test_a_sidecar_that_never_appears_leaves_every_span_unknown_by_name(self) -> None:
        self.run.to_module(submission(b"SPEAK", b"<speak>alpha</speak>"))
        self.run.to_module(submission(b"CHAR", b"7"))
        for bound in self.decided():
            self.assertEqual(bound["native_state"], "unknown")
            self.assertEqual(bound["native_reason"], "meta_never_appeared")
            self.assertIsNone(bound["native_msg_id"])
        self.assertFalse(os.path.exists(self.run.meta_path),
                         "a reader that has no sidecar never creates one")
        self.assertEqual(self.run.meta.summary()["stopped_reason"], "meta_never_appeared")
        self.assertEqual(self.run.meta.summary()["records_read"], 0)

    def test_a_sidecar_somebody_else_may_reach_is_refused_by_name(self) -> None:
        handle = os.open(self.run.meta_path,
                         os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
        os.close(handle)
        os.chmod(self.run.meta_path, 0o644)
        self.say(b"SPEAK", b"<speak>alpha</speak>", 1)
        bound = self.one("SPEAK")
        self.assertEqual(bound["native_state"], "unknown")
        self.assertEqual(bound["native_reason"], "meta_file_unexpected")
        self.assertIsNone(bound["native_msg_id"])
        self.assertEqual(os.stat(self.run.meta_path).st_mode & 0o777, 0o644,
                         "the reader refused the file and left its mode alone")
        self.assertEqual(self.run.meta.summary()["opened"], False)

    def test_a_run_whose_births_could_not_be_read_attributes_nothing(self) -> None:
        run = Run(meta=True, identity_known=False)
        self.addCleanup(run.close)
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        run.to_module(b"".join(chunks), rows_for(chunks, 0, 1, 1, 7))
        run.meta.finish()
        bound = next(b for b in run.bindings() if b["span_kind"] == "submission")
        self.assertEqual(bound["native_state"], "unknown")
        self.assertEqual(bound["native_reason"], "meta_identity_unknown")
        self.assertEqual(run.meta.summary()["records_read"], 0)

    def test_a_run_with_no_sideband_claims_no_message_at_all(self) -> None:
        run = Run()
        self.addCleanup(run.close)
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        run.to_module(b"".join(chunks))
        run.meta.finish()
        bound = next(b for b in run.bindings() if b["span_kind"] == "submission")
        self.assertEqual(bound["native_state"], "unknown")
        self.assertEqual(bound["native_reason"], "hook_off")
        self.assertIsNone(bound["native_msg_id"])
        self.assertEqual(run.meta.summary()["span_bindings"], {"rooted": 0, "control": 0, "unknown": 1})
        self.assertEqual(run.meta.summary()["stopped_reason"], "hook_off")

    def test_the_reader_never_touches_the_sidecar_it_reads(self) -> None:
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        self.run.to_module(b"".join(chunks), rows_for(chunks, 0, 1, 1, 7))
        before = self.run.sidecar_state()
        self.run.meta.read_available()
        self.run.meta.advance(self.run.trace.written[observer.TO_MODULE_NAME])
        self.run.meta.finish()
        self.run.meta.close()
        self.assertEqual(self.run.sidecar_state(), before)

    # ── the boundaries the review forced ────────────────────────────────────

    def test_a_row_claiming_bytes_an_accepted_run_already_owns_refuses_the_span(self) -> None:
        """One covering row cannot speak for ground a refused row also claims.

        The first row covers the whole submission and agrees with itself, which
        is exactly what made this dangerous: without the refused row's extent
        kept, the span would have been credited from the run that happened to
        be accepted first. Contested ground is contested, whoever got there
        first.
        """
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        whole = b"".join(chunks)
        rows = rows_for([whole], 0, 1, 1, 7)
        # A second row, from a different message, claims the middle of it.
        rows.append(row(len(whole) // 2, 3, 3, 2, 1, 7))
        self.run.to_module(whole, rows)
        bound = self.one("SPEAK")
        self.assertEqual(bound["native_state"], "unknown")
        self.assertEqual(bound["native_reason"], "meta_overlap")
        self.assertIsNone(bound["native_msg_id"])
        self.assertEqual(self.run.meta.summary()["records_matched"], 1)

    def test_a_row_that_moves_back_before_the_last_start_regresses_the_stream(self) -> None:
        """A row behind the last row's own start is neither a hole nor an overlap.

        Two sequential rows advance the stream, then a third row from a
        different message claims ground before the second row even started.
        That is the stream moving backwards, and contested ground is
        contested no matter which direction the disagreement comes from.
        """
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        whole = b"".join(chunks)
        half = len(whole) // 2
        rows = rows_for([whole[:half], whole[half:]], 0, 1, 1, 7)
        # Before the second row's own start, but not past the stream end:
        # behind last_offset, inside expected_offset, so neither gap nor
        # overlap. The stream went backwards.
        rows.append(row(half // 2, 3, 3, 2, 1, 7))
        self.run.to_module(whole, rows)
        bound = self.one("SPEAK")
        self.assertEqual(bound["native_state"], "unknown")
        self.assertEqual(bound["native_reason"], "meta_offset_regression")
        self.assertIsNone(bound["native_msg_id"])
        self.assertEqual(self.run.meta.summary()["records_matched"], 2)
        self.assertTrue(any(fault.startswith("meta_offset_regression")
                            for fault in self.run.meta.summary()["faults"]))

    def test_a_row_that_lost_its_owner_fields_is_not_a_control_write(self) -> None:
        """A missing field answers nothing; only an explicit null says "none".

        A row that parses and simply omits the owner would otherwise read as a
        control write, which is a POSITIVE verdict - a genuine ownerless write
        - published from input that lost a field on the way here.
        """
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        rows = rows_for(chunks, 0, None, None, None)
        for entry in rows:
            del entry["msg_id"]
            del entry["client_id"]
            del entry["client_fd"]
        self.run.to_module(b"".join(chunks), rows)
        bound = self.one("SPEAK")
        self.assertEqual(bound["native_state"], "unknown")
        self.assertEqual(bound["native_reason"], "meta_type_error")
        self.assertIsNone(bound["native_msg_id"])

    def test_a_null_owner_still_reads_as_a_genuine_control_write(self) -> None:
        """The counterpart: an explicit null IS the daemon saying "no message"."""
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        self.run.to_module(b"".join(chunks), rows_for(chunks, 0, None, None, None))
        bound = self.one("SPEAK")
        self.assertEqual(bound["native_state"], "control")
        self.assertIsNone(bound["native_reason"])
        self.assertIsNone(bound["native_msg_id"])

    def test_a_row_that_could_not_name_this_boot_is_refused_rather_than_assumed(self) -> None:
        """Boot is a join key like any other, and a missing one is not a match."""
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        self.run.to_module(b"".join(chunks), rows_for(chunks, 0, 1, 1, 7, boot_id=None))
        bound = self.one("SPEAK")
        self.assertEqual(bound["native_state"], "unknown")
        self.assertEqual(bound["native_reason"], "meta_boot_conflict")
        self.assertIsNone(bound["native_msg_id"])

    def test_a_negative_errno_on_an_error_row_is_the_daemons_own_fact(self) -> None:
        """A signed errno is a number the daemon wrote, not a type error."""
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        rows = rows_for(chunks[:-1], 0, 1, 1, 7)
        tail = chunks[-1]
        rows.append(row(len(b"".join(chunks[:-1])), len(tail) - 1, len(tail), 1, 1, 7,
                        outcome="error", errno=-32))
        self.run.to_module(b"".join(chunks), rows)
        bound = self.one("SPEAK")
        self.assertEqual(bound["native_reason"], "partial_write_in_span")
        self.assertIsNone(bound["native_msg_id"])
        self.assertEqual(self.run.meta.summary()["records_matched"], 3)

    def test_an_error_row_naming_no_failure_is_refused(self) -> None:
        """An error that names nothing is not a fact about a real write."""
        for errno_value in (None, 0):
            with self.subTest(errno=errno_value):
                run = Run(meta=True)
                self.addCleanup(run.close)
                chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
                rows = rows_for(chunks[:-1], 0, 1, 1, 7)
                tail = chunks[-1]
                rows.append(row(len(b"".join(chunks[:-1])), len(tail) - 1, len(tail),
                                1, 1, 7, outcome="error", errno=errno_value))
                run.to_module(b"".join(chunks), rows)
                run.meta.finish()
                bound = next(b for b in run.bindings() if b["span_kind"] == "submission")
                self.assertEqual(bound["native_state"], "unknown")
                self.assertEqual(bound["native_reason"], "meta_outcome_contradiction")
                self.assertIsNone(bound["native_msg_id"])
                self.assertEqual(run.meta.summary()["records_matched"], 2)

    def test_a_row_refused_after_valid_coverage_leaves_that_coverage_standing(self) -> None:
        """One malformed row ends the sidecar at its own offset, nowhere else.

        The daemon appends one row per write, so a single poll of it hands this
        program several rows and a refusal together. The rows in front of that
        refusal describe bytes the daemon really covered, and losing them to it
        would let one bad row erase every write before it - which is a claim
        about those bytes that nothing supports.
        """
        first = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        second = submission_chunks(b"CHAR", b"7")
        split = len(b"".join(first))
        self.run.to_module(b"".join(first))
        # Every row arrives in one read, refusal included: the valid rows for
        # the SPEAK and the refusal for the CHAR's last write land together.
        rows = rows_for(first, 0, 1, 1, 7) + rows_for(second[:2], split, 2, 1, 7)
        rows.append(row(split + len(second[0]) + len(second[1]), 1, 2,
                        2, 1, 7, outcome="error"))
        self.run.to_module(b"".join(second), rows)
        speak = self.one("SPEAK")
        self.assertEqual(speak["native_state"], "rooted")
        self.assertEqual(speak["native_msg_id"], 1)
        self.assertEqual(speak["native_covering_writes"], 3)
        char = self.one("CHAR")
        self.assertEqual(char["native_state"], "unknown")
        self.assertEqual(char["native_reason"], "meta_outcome_contradiction")
        self.assertIsNone(char["native_msg_id"])

    def test_rows_the_daemon_appends_after_the_wire_ends_are_still_read(self) -> None:
        """The last row for a submission lands after the wire has gone quiet.

        The daemon appends its record for a write AFTER that write returns, so
        the final row covering a submission can arrive after every byte the
        daemon ever wrote has already been read. This drives the real call
        chain - read, then the pump's bounded drain, then the close - so the one
        second bound is exercised rather than assumed, and it costs a second
        because the product really does spend it.
        """
        chunks = submission_chunks(b"SPEAK", b"<speak>alpha</speak>")
        split = len(chunks[0]) + len(chunks[1])
        # The submission goes out and the daemon publishes two of its three rows.
        self.run.to_module(b"".join(chunks), rows_for(chunks[:2], 0, 5, 1, 7))
        self.assertEqual(self.run.meta.summary()["records_matched"], 2)
        self.assertEqual(self.run.bindings(), [])
        # Every daemon byte is gone and the pump is stopped. The last row for
        # those very bytes lands now, and nothing was held back waiting for it.
        self.run.write_rows(rows_for(chunks[2:], split, 5, 1, 7))
        stop = threading.Event()
        stop.set()
        self.run.meta.pump(stop, observer.POLL_SECONDS)
        self.run.meta.finish()
        bound = self.run.bindings()
        self.assertEqual(len(bound), 1)
        self.assertEqual(bound[0]["native_msg_id"], 5)
        self.assertEqual(bound[0]["native_state"], "rooted")
        self.assertEqual(bound[0]["native_covering_writes"], 3)
        self.assertTrue(self.run.meta.summary()["drained"])

    def test_the_boot_id_this_run_joins_on_is_a_full_uuid_or_nothing(self) -> None:
        """The boot is a join key, so it must be a real one and not a lookalike.

        A value that is merely boot-id-shaped would agree with a row carrying
        the same wrong value, which is agreement about nothing. Upper case is
        the sneaky one: folding it would let two spellings of one boot disagree,
        and refusing it means a row that folds cannot silently match.
        """
        value, note = observer.read_boot_id()
        self.assertIsNotNone(value, note)
        self.assertTrue(observer.is_boot_id(value))
        for wrong in ("", "not-a-uuid", BOOT_ID.upper(), BOOT_ID[:-1], BOOT_ID + "0"):
            with self.subTest(value=wrong):
                self.assertFalse(observer.is_boot_id(wrong))



class SignalDeliveryTests(unittest.TestCase):
    """What a real delivery, and a real NON-delivery, are recorded as.

    Every test here forks a REAL child of this test, takes a REAL retained
    ``os.pidfd_open`` of it, and drives the product's own ``handle_signal``,
    ``send_to_module`` and ``wait_for_module``. No pidfd is faked, no syscall is
    stubbed, and no outcome is written by this harness: every outcome read back
    below is one the kernel gave.

    What is pinned is the consumer-visible claim, not the wiring and not a
    count:

    * a signal that really went through the pin is recorded as ``delivered`` and
      is the only thing that sets ``forwarded_signal``;
    * a signal the kernel refused because the module was ALREADY ended is typed
      ``already_ended`` with the errno that says so, leaves ``forwarded_signal``
      at zero, writes no fault, and is backed by the module's own reap status
      obtained independently through the same pin;
    * ESRCH alone blesses NOTHING. Without a descriptor this process still holds,
      or with a descriptor that is genuinely bad, the same refusal is a fault
      and is written down as one.
    """

    def setUp(self) -> None:
        if getattr(os, "P_PIDFD", None) is None:
            self.skipTest("this kernel gives no pidfd, so there is nothing to pin")
        if getattr(signal, "pidfd_send_signal", None) is None:
            self.skipTest("this interpreter cannot signal through a pidfd")
        self.directory = tempfile.mkdtemp(prefix="nogui-signal-delivery-")
        # The observer refuses a trace directory anybody else can reach, so this
        # harness holds itself to the same rule the product enforces.
        observer.require_private_dir(self.directory)
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        # A real executable, resolved and hashed by the product's own resolver.
        self.module = observer.require_module(sys.executable)
        self.built = []
        self.addCleanup(self._release)

    def _release(self) -> None:
        """Whatever a test did, it leaves no child, no descriptor and no trace."""
        for obs in self.built:
            if obs.child_reaped:
                continue
            try:
                signal.pidfd_send_signal(obs.child_pidfd, signal.SIGKILL)
            except (OSError, TypeError):
                pass
            try:
                os.waitpid(obs.child_pid, 0)
            except (ChildProcessError, TypeError):
                pass
            # Only descriptors this test still holds are closed, and a None is
            # never handed to close(): a disarmed observer has None there, and
            # os.close(None) raises TypeError, which is not an OSError and so
            # would escape the cleanup the very cleanup meant to contain it.
            for fd in (obs.child_pidfd, obs.exec_notice_read, obs.exec_notice_write):
                if isinstance(fd, int):
                    obs.close_fd(fd)
            obs.trace.close()

    def _observer(self):
        """A REAL observer over a real private directory. It forks nothing yet."""
        obs = observer.Observer(self.module, self.directory, [sys.executable])
        self.built.append(obs)
        return obs

    def _real_child(self, obs, body) -> int:
        """A real forked child, a real retained pin, and a real notice pipe.

        ``body`` runs inside the child. Nothing in the child returns to this
        process: it ends the way a module ends, and the only thing this harness
        ever does about that is the pidfd and the wait.
        """
        read_end, write_end = os.pipe()
        os.set_inheritable(read_end, False)
        os.set_inheritable(write_end, False)
        pid = os.fork()
        if pid == 0:
            try:
                # The child announces that it reached its exec, exactly as the
                # product's own child does before execv, so wait_for_module
                # reads a real end of a real pipe.
                os.write(write_end, observer.EXEC_NOTICE)
                body()
            finally:
                os._exit(0)
        os.close(write_end)
        obs.exec_notice_read = read_end
        obs.child_pid = pid
        obs.child_pidfd = os.pidfd_open(pid)
        os.set_inheritable(obs.child_pidfd, False)
        obs.module_pinned = True
        # The observer's belief, which is what the whole edge turns on. Nothing
        # here tells it anything: no test reaches in to agree with reality.
        obs.child_live = True
        return pid

    def _reap_with_a_late_signal(self, obs) -> object:
        """Wait for the module for real, and signal it inside the real window.

        The race this pins is a real one: the daemon retires the module directly
        through its own pin, this observer reaps it, and a signal for the group
        reaches this process AFTER that. The window between the kernel
        consuming the child and the observer learning about it is a few
        instructions wide, so it is entered rather than waited for.

        It is entered by a ``c_return`` profile hook on the product's OWN real
        ``os.waitid`` call. Nothing is mocked and no syscall is stubbed: the
        wait is the real one, the signal is the real one, and the handler is the
        product's own. At that instant the kernel has consumed the child and the
        observer has not been told, so the pin it still holds names nothing that
        can be signalled - which is the fact under test.

        Note what is NOT done here: the child is not left waitable. A zombie is
        still a task the kernel will accept a signal for, so a waitable corpse
        does not reproduce this race at all; only a REAPED child does.
        """
        fired = []

        def on_return(frame, event, arg):
            if event != "c_return":
                return
            # `os.waitid` is a BUILTIN, so it has no `__code__` at all, and for a
            # C call the profile argument IS the function object that was
            # called. Matching on `arg is os.waitid` is therefore the only
            # identity that exists here, and it is a real one rather than a
            # stand-in. `c_return` fires after the kernel has consumed the
            # child and before the observer reads the status or clears its own
            # belief, which is the window this test is about.
            if arg is not os.waitid:
                return
            fired.append(arg)
            sys.setprofile(None)
            obs.handle_signal(int(signal.SIGTERM), None)

        sys.setprofile(on_return)
        try:
            obs.wait_for_module()
        finally:
            sys.setprofile(None)
        self.assertEqual(len(fired), 1,
            f"the observer's own waitid returned {len(fired)} time(s) inside the profile hook, so the real "
            "window was never entered")
        return fired[0]

    def _consume_the_child(self, obs) -> object:
        """Reap this test's OWN child through the product's own reader of a status.

        Nothing here is a stand-in: the wait is a real ``waitid`` on the real
        pin and the status is read by the product's own ``read_waitid``. What the
        test does afterwards is put the observer in the state its own reap leaves
        behind, without telling it anything else.
        """
        info = os.waitid(os.P_PIDFD, obs.child_pidfd, os.WEXITED)
        obs.read_waitid(info)
        obs.child_pidfd = None
        obs.child_reaped = True
        return info

    def test_a_signal_that_really_went_through_is_recorded_as_delivered(self) -> None:
        """The consumer contract: a live module, a real delivery, a real death.

        Nothing here is special-cased. The child is alive, the pin is open, the
        kernel accepts the signal, and the module really dies of it and is
        really reaped with that status.
        """
        obs = self._observer()
        # Bounded, and far longer than this test needs: the delivery below ends
        # this child immediately, so the wait cannot outlast it.
        self._real_child(obs, lambda: time.sleep(5))
        obs.handle_signal(int(signal.SIGTERM), None)

        self.assertEqual(obs.received_signals, [int(signal.SIGTERM)])
        self.assertEqual(obs.forward_intent_signals, [int(signal.SIGTERM)])
        self.assertEqual(obs.delivered_signals, [int(signal.SIGTERM)])
        self.assertEqual(obs.forwarded_signal, int(signal.SIGTERM))
        self.assertIsNone(obs.signal_note)
        self.assertEqual([entry["outcome"] for entry in obs.signal_outcomes], ["delivered"])

        obs.wait_for_module()
        self.assertTrue(obs.child_reaped)
        self.assertEqual(obs.module_exit_signal, int(signal.SIGTERM))
        self.assertEqual(obs.module_exit_code, 0)

        block = obs.footer_common()["signal_delivery"]
        self.assertEqual(block["delivered"], [int(signal.SIGTERM)])
        self.assertEqual(block["delivery_count"], 1)
        self.assertEqual(block["intent_count"], 1)
        self.assertTrue(block["module_reaped"])
        self.assertEqual(block["module_exit_signal"], int(signal.SIGTERM))
        self.assertEqual([entry["outcome"] for entry in block["outcomes"]], ["delivered"])

    def test_a_module_that_ended_first_is_typed_and_claims_no_delivery(self) -> None:
        """The edge: the kernel says there is no longer a task to signal.

        The child is reaped by the observer's OWN wait, and the signal reaches
        the observer's OWN handler inside the window between the kernel
        consuming that child and the observer learning about it. The observer
        still believes the module is live and still holds the pin, because at
        that instant nothing has told it otherwise.
        """
        obs = self._observer()
        self._real_child(obs, lambda: os._exit(0))
        self._reap_with_a_late_signal(obs)

        # NOTHING WAS DELIVERED, so nothing may say it was.
        self.assertEqual(obs.forwarded_signal, 0)
        self.assertEqual(obs.delivered_signals, [])
        # It is not a fault either: nothing failed, there was only nothing left.
        self.assertIsNone(obs.signal_note)
        self.assertEqual([entry["outcome"] for entry in obs.signal_outcomes], ["already_ended"])
        recorded = obs.signal_outcomes[0]
        self.assertEqual(recorded["errno"], errno.ESRCH)
        self.assertEqual(recorded["signal"], int(signal.SIGTERM))
        self.assertEqual(recorded["module_pid"], obs.child_pid)
        self.assertTrue(recorded["module_pidfd_was_held"])
        self.assertTrue(recorded["module_believed_live_at_this_instant"])

        # The observer really did finish its own wait, and really did read the
        # status the kernel gave. That is the independent proof behind the claim.
        self.assertTrue(obs.child_reaped)
        self.assertEqual(obs.module_exit_code, 0)
        self.assertEqual(obs.module_exit_signal, 0)

        footer = obs.footer_common()
        block = footer["signal_delivery"]
        self.assertEqual(footer["forwarded_signal"], 0)
        self.assertEqual(block["delivered"], [])
        self.assertEqual(block["delivery_count"], 0)
        self.assertEqual(block["intent_count"], 1)
        self.assertEqual(len(block["outcomes"]), block["intent_count"])
        self.assertTrue(block["module_reaped"])
        self.assertEqual(block["module_exit_code"], 0)
        self.assertEqual([entry["outcome"] for entry in block["outcomes"]], ["already_ended"])
        # The signal that arrived is still stated. Nothing about the receipt was
        # lost by relocating the outcome out of the fault channel.
        self.assertEqual(block["received"], [int(signal.SIGTERM)])
        self.assertEqual(block["forward_intent"], [int(signal.SIGTERM)])

    def test_esrch_is_not_blessed_when_this_process_no_longer_holds_the_pin(self) -> None:
        """Same refusal, no pin held: a fault, and a fault is written down.

        This is the guard that keeps the previous test honest. The child is
        really consumed by a real wait through the product's own status reader,
        so the kernel answers in exactly the same way, but the observer has
        disarmed its descriptor - the state ``wait_for_module`` leaves behind -
        so there is no pin behind the claim and it is refused instead.
        """
        obs = self._observer()
        self._real_child(obs, lambda: os._exit(0))
        held = obs.child_pidfd
        # A REAL wait that consumes the child, and the product's OWN reader of
        # that status. Nothing about it is a stand-in.
        self._consume_the_child(obs)
        self.assertTrue(obs.child_reaped)
        self.assertIsNone(obs.child_pidfd)

        outcome = obs.send_to_module(held, int(signal.SIGTERM))

        self.assertEqual(outcome, "refused")
        self.assertEqual(obs.signal_outcomes[0]["outcome"], "refused")
        self.assertEqual(obs.signal_outcomes[0]["errno"], errno.ESRCH)
        self.assertFalse(obs.signal_outcomes[0]["module_pidfd_was_held"])
        self.assertEqual(obs.forwarded_signal, 0)
        self.assertEqual(obs.delivered_signals, [])
        self.assertIsNotNone(obs.signal_note, "a refused delivery must leave its fault written down")
        # The module really did end either way; what differs is only whether
        # there was a pin behind the claim.
        self.assertEqual(obs.module_exit_code, 0)
        self.assertEqual(obs.module_exit_signal, 0)
        # The descriptor this test was holding is closed exactly once, here.
        obs.close_fd(held)

    def test_a_genuinely_bad_descriptor_is_a_fault_and_not_an_already_ended(self) -> None:
        """A closed pin is EBADF, and nothing about that is the module's ending."""
        obs = self._observer()
        self._real_child(obs, lambda: time.sleep(0.2))
        bad = obs.child_pidfd
        # A real descriptor, really closed. The number is real and it is wrong.
        obs.close_fd(bad)

        outcome = obs.send_to_module(bad, int(signal.SIGTERM))

        self.assertEqual(outcome, "refused")
        self.assertEqual(obs.signal_outcomes[0]["outcome"], "refused")
        self.assertEqual(obs.signal_outcomes[0]["errno"], errno.EBADF)
        self.assertEqual(obs.forwarded_signal, 0)
        self.assertEqual(obs.delivered_signals, [])
        self.assertIsNotNone(obs.signal_note)
        # The observer was never told anything, and the pin it still names is
        # still named. Only the descriptor is wrong, and that is a fault.
        self.assertTrue(obs.child_live)
        # A FRESH real pin on the same pid, so the module is really waited for
        # and really reaped instead of being abandoned behind a broken
        # descriptor.
        obs.child_pidfd = os.pidfd_open(obs.child_pid)
        obs.wait_for_module()
        self.assertTrue(obs.child_reaped)
        self.assertEqual(obs.module_exit_code, 0)
        self.assertEqual(obs.module_exit_signal, 0)


class PumpJoinTests(unittest.TestCase):
    """The bounded join, on the one occasion the bound is what stopped the pump.

    ``run`` gives the daemon-side pump JOIN_SECONDS to finish once the module
    is gone and writes down the fact when the pump outlived that bound: this
    pump closes spans, so a run that did not wait for it cannot claim its index
    holds every byte the daemon wrote. A pump that is only polling cannot reach
    that branch - it leaves within one poll interval - so the stall below is a
    real one.

    The module this test execs never reads its own stdin. It forks a holder,
    gives the holder its stdin, drops its own stdout, and ends itself. The
    holder reads nothing until well past the join bound, so the pump's write
    into that pipe is a real blocking write the kernel never fails: no EPIPE,
    no SIGPIPE, no substituted object, and the observer's own join is the only
    thing that can end it.
    """

    # The holder starts draining after the join has already given up, and the
    # module itself ends before that. The module's own lifetime is the window
    # the pump has to reach its blocked write inside.
    MODULE_LIFETIME_SECONDS = 0.8
    STALL_HOLD_SECONDS = 2.5
    # The daemon side carries more than the module's stdin pipe can take, so the
    # pump is still handing bytes over when the module is gone. No newline goes
    # into them on purpose, so the stall cannot be mistaken for framing work and
    # the index this run writes stays out of the way.
    DAEMON_BYTES = 3 * 65536
    DAEMON_BLOCK = b"X" * 65536

    @classmethod
    def module_program(cls) -> str:
        """The module this test runs, as the observer execs it: real argv."""
        return (
            "import os, time\n"
            "if os.fork() == 0:\n"
            # The holder keeps the module's stdin open - that is what stops the
            # write from failing - and gives the module's stdout back, so the
            # observer sees the module's real end of output on time.
            "    os.close(1)\n"
            f"    time.sleep({cls.STALL_HOLD_SECONDS})\n"
            "    try:\n"
            "        while os.read(0, 65536):\n"
            "            pass\n"
            "    except OSError:\n"
            "        pass\n"
            "    os._exit(0)\n"
            f"time.sleep({cls.MODULE_LIFETIME_SECONDS})\n"
            "os._exit(0)\n"
        )

    def setUp(self) -> None:
        if getattr(os, "P_PIDFD", None) is None:
            self.skipTest("this kernel gives no pidfd, so the run would refuse before it forked anything")
        if getattr(signal, "pidfd_send_signal", None) is None:
            self.skipTest("this interpreter cannot signal through a pidfd")
        self.directory = tempfile.mkdtemp(prefix="nogui-pump-join-")
        # The observer refuses a trace directory anybody else can reach, so this
        # harness holds itself to the same rule the product enforces.
        observer.require_private_dir(self.directory)
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)

    def _flood(self, descriptor: int) -> None:
        """The same daemon bytes, written from a thread when a pipe is too small.

        The observer reads descriptor 0 as the daemon's pipe, so this is the
        daemon writing and nothing else. It blocks once the pipe is full, which
        is the point: the pump has real work that cannot move.
        """
        sent = 0
        while sent < self.DAEMON_BYTES:
            try:
                sent += os.write(descriptor, self.DAEMON_BLOCK)
            except OSError:
                return

    def _fill_daemon_side(self, read_end: int, write_end: int):
        """The daemon's own bytes, in the pipe, before the run starts.

        The pipe is widened first where the kernel allows it, so the whole side
        fits without blocking and nothing writes it afterwards: the observer
        forks the module itself, and a fork taken while a writer thread sits
        inside a write is a fork this test has no need for. Where the pipe
        cannot be widened the same bytes go in from a thread. That thread is
        returned, or None when there was no need for one.
        """
        if hasattr(fcntl, "F_SETPIPE_SZ"):
            try:
                widened = fcntl.fcntl(read_end, fcntl.F_SETPIPE_SZ, self.DAEMON_BYTES * 2)
            except OSError:
                widened = 0
            if widened >= self.DAEMON_BYTES:
                sent = 0
                while sent < self.DAEMON_BYTES:
                    sent += os.write(write_end, self.DAEMON_BLOCK)
                return None
        writer = threading.Thread(target=self._flood, args=(write_end,), name="daemon-side", daemon=True)
        writer.start()
        return writer

    def test_a_daemon_side_stalled_past_the_join_is_named_and_the_run_still_completes(self) -> None:
        daemon_read, daemon_write = os.pipe()
        os.set_inheritable(daemon_read, False)
        os.set_inheritable(daemon_write, False)
        saved_stdin = os.dup(0)
        saved_mask = signal.pthread_sigmask(signal.SIG_BLOCK, ())
        saved_handlers = {}
        for name in observer.FORWARDED_SIGNALS:
            number = getattr(signal, name, None)
            if number is not None:
                saved_handlers[number] = signal.getsignal(number)
        # The daemon's pipe becomes this process's descriptor 0, which is where
        # the observer reads it from and where it takes the pipe identity from.
        os.dup2(daemon_read, 0)
        writer = None
        obs = None
        try:
            writer = self._fill_daemon_side(daemon_read, daemon_write)
            obs = observer.Observer(observer.require_module(sys.executable), self.directory,
                                    [sys.executable, "-c", self.module_program()])

            began = time.monotonic()
            code = obs.run()
            elapsed = time.monotonic() - began

            # The pump is still in its write when run() returns. That is the
            # whole condition the branch below reports, and it was not produced
            # by this harness: nothing here touched the pump.
            self.assertTrue(obs.to_thread.is_alive(),
                            "the daemon-side pump outlived the join, so the branch this test exists for "
                            "was not entered")
            self.assertGreaterEqual(elapsed, observer.JOIN_SECONDS,
                                    "the run returned before the join bound it was given")
            self.assertEqual(code, 0)
            with open(os.path.join(self.directory, observer.FOOTER_NAME), "rb") as handle:
                footer = json.loads(handle.read())
            self.assertTrue(footer["module_reaped"])
            self.assertEqual(footer["module_exit_code"], 0)
            self.assertEqual(footer["module_exit_signal"], None)
            self.assertEqual(footer["observer_exit_code"], 0)
            self.assertTrue(footer["module_output_reached_eof"],
                            "the module's output really did end, so the note below is about the daemon side")
            self.assertEqual(obs.pump_note, footer["pump_note"])
            self.assertIsNotNone(footer["pump_note"],
                                 "a run that stopped waiting for the daemon-side pump must say so")
            self.assertIn(f"the daemon side was still being read {observer.JOIN_SECONDS:g}s after the "
                          "module was gone", footer["pump_note"])
            self.assertNotIn("the module's last output was still in the pipe", footer["pump_note"])
        finally:
            # The holder starts draining now, so the stalled write completes and
            # the pump really does finish - the run completed without waiting
            # for it, which is the whole point of the note.
            if obs is not None and obs.to_thread is not None:
                obs.to_thread.join(timeout=self.STALL_HOLD_SECONDS + 10)
            os.dup2(saved_stdin, 0)
            os.close(saved_stdin)
            os.close(daemon_read)
            # With the read end gone on both sides, a writer still blocked on a
            # full pipe is released by the kernel.
            if writer is not None:
                writer.join(timeout=10)
            os.close(daemon_write)
            for number, handler in saved_handlers.items():
                signal.signal(number, handler)
            signal.pthread_sigmask(signal.SIG_SETMASK, saved_mask)
            if obs is not None:
                obs.trace.close()


class PinnedSourceTests(unittest.TestCase):
    """The fragments this program says its daemon-side rules were read from.

    The header publishes a range for each of them, so a reader can go and look
    instead of taking this program's account of its own source for it. A record
    like that is only worth anything while it stays TRUE of the source it
    names, and nothing else in this file keeps it true: a hunk moves, a
    function is renamed, a range quietly stops covering the code it claims to
    cover. So every range is opened here and checked against the bytes it
    points at, and the two questions those ranges exist to answer - is the
    daemon's record lock on its forwarding path, and does the write's errno
    survive the record - are checked against the fragment text itself.
    """

    REPOSITORY_ROOT = OBSERVER_PATH.resolve().parent.parent

    def _range(self, entry: dict, key: str) -> tuple:
        """One recorded range as the two integers it names, first before last."""
        first, _, last = entry[key].partition("-")
        start, stop = int(first), int(last)
        self.assertGreaterEqual(start, 1)
        self.assertGreaterEqual(stop, start, f"{entry['function']} names no range: {entry[key]}")
        return start, stop

    def fragment_text(self, entry: dict) -> str:
        """The exact lines of the pinned fragment this entry names."""
        path = self.REPOSITORY_ROOT / entry["fragment"]
        with open(path, "rb") as handle:
            lines = handle.read().decode("utf-8").splitlines()
        start, stop = self._range(entry, "fragment_lines")
        self.assertLessEqual(stop, len(lines),
                             f"{entry['fragment']} has {len(lines)} lines, so {entry['fragment_lines']} "
                             "names lines that are not there")
        return "\n".join(lines[start - 1:stop])

    def test_every_pinned_range_still_carries_the_code_it_names(self) -> None:
        """A range that has drifted off its code is worse than no range."""
        for entry in observer.PINNED_SOURCE:
            with self.subTest(function=entry["function"], fragment=entry["fragment"]):
                self.assertTrue(self.REPOSITORY_ROOT.joinpath(entry["fragment"]).is_file(),
                                f"{entry['fragment']} is not in this repository")
                self._range(entry, "patched_lines")
                self.assertIn(entry["anchor"], self.fragment_text(entry),
                              f"{entry['fragment_lines']} of {entry['fragment']} does not carry "
                              f"{entry['anchor']}")
                self.assertTrue(entry["says"])

    def test_the_write_loop_and_the_record_of_that_write_are_both_pinned(self) -> None:
        """Both functions this program depends on are pinned where they are."""
        by_function = {}
        for entry in observer.PINNED_SOURCE:
            by_function.setdefault(entry["function"], []).append(entry)
        for function in ("output_write_all", "audit_emit"):
            with self.subTest(function=function):
                self.assertIn(function, by_function,
                              f"{function} is not pinned, so the daemon's own write and the record of it "
                              "cannot be checked against the source")
                self.assertTrue(any(entry["says"] for entry in by_function[function]))
        # The loop, the one call that uses it and the record of that call live
        # in different fragments, so the whole record is what has to answer.
        everything = "\n".join(self.fragment_text(entry) for entry in observer.PINNED_SOURCE)
        self.assertIn("static int output_write_all(", everything)
        self.assertIn("ret = output_write_all(output->pipe_in[1], cmd, nbytes, &written);", everything)
        self.assertIn("static void audit_emit(", everything)
        # The loop is what makes a short write a prefix and not a success, and
        # what makes a zero-length command a row that covers nothing.
        self.assertIn("while (sent < count)", everything)
        self.assertIn("*written_out = sent;", everything)
        self.assertIn("output->audit_off = off + (unsigned long long) written;", everything,
                      "the record's offset advances by what the kernel took and nothing else")

    def test_the_lock_is_taken_before_the_write_and_the_errno_is_restored_after_it(self) -> None:
        """Both questions the audit fragment exists to answer, read from it."""
        text = None
        for entry in observer.PINNED_SOURCE:
            fragment = self.fragment_text(entry)
            if "pthread_mutex_lock(&audit_mutex)" in fragment:
                text = fragment
                break
        self.assertIsNotNone(text, "no pinned fragment carries the audit lock, so its placement cannot be "
                         "checked against the source")
        locked = text.index("pthread_mutex_lock(&audit_mutex)")
        written = text.index("ret = output_write_all(")
        captured = text.index("audit_errnum = errno;")
        emitted = text.index("audit_emit(output")
        unlocked = text.index("pthread_mutex_unlock(&audit_mutex);")
        restored = text.index("errno = audit_errnum;")
        self.assertLess(locked, written,
                        "the record's lock is taken before the write, so the offset cannot disagree with "
                        "the wire")
        self.assertLess(written, captured, "the errno is captured from the write that just happened")
        self.assertLess(captured, emitted)
        self.assertLess(emitted, unlocked)
        self.assertLess(unlocked, restored,
                        "the errno is restored after the unlock, so neither the record nor the unlock can "
                        "change what the daemon's own error path reports")
        self.assertIn("if (audit_on) {", text)
        self.assertIn("if (ret == -1) {", text,
                      "the daemon's own error path follows the restored errno, and it is in this range")


if __name__ == "__main__":
    unittest.main()