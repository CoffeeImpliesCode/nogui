#!/usr/bin/env python3
"""Transparent byte observer for one speech-dispatcher output module.

speech-dispatcher speaks SSIP to an output module over two pipes: it writes
newline-terminated commands into the module's stdin and reads newline-framed
messages out of the module's stdout (src/server/output.c ``output_send_data``
and ``output_read_message``, src/modules/module_process.c ``module_process``).
Every byte of a synthesised utterance's PCM crosses that stdout pipe, and both
ends of the crossing print the message with ``%s``, which stops at the first
NUL - so the rendered waveform is on the wire and absent from every log.

This program is that wire, observed. It sits where the daemon's module child
sits, forwards both directions byte for byte, and writes the bytes it saw plus
a framing index beside them. It executes the genuine module. It does not
synthesise, replay, substitute, resample or transform anything.

    speech-dispatcher --AddModule--> this observer --exec--> the real module
        stdin  <---------------------------  stdin
        stdout ---------------------------->  stdout
                   plus a private trace

Nothing here changes what the module is told or what it answers:

  * argv is forwarded unchanged. argv[0] becomes the genuine module path,
    which is exactly what the daemon would have exec'd on its own.
  * stdin and stdout are raw descriptors. No text mode, no newline
    translation, no buffering: every chunk read is written on before the next
    read, in the same order.
  * the module's stderr is inherited, so it lands in the log file the daemon
    opened for it, unchanged.
  * EOF, exit status and signals are the module's own; see the paragraph on
    lifetime below for exactly how this process ends when the module is
    signalled.

The index is causal. Every record is stamped and written BEFORE the bytes it
describes are handed to the other side, so a record can never carry a stamp
later than the answer it caused. Nothing in the framing depends on where a
read ended: a line or a message split across two reads is carried whole, and
offsets count from the start of a stream rather than from the start of a read.

Two names are minted where they are true, and they are the only way a reply or
an event is attached to anything:

  request_seq  a positive run-local integer for a message the daemon wrote that
               bears a reply. It is minted at the verb line and written as a
               request_open record BEFORE those bytes are handed to the module.
               The matching submission or block record carries the same
               integer. The name says which message the daemon wrote, so it
               exists whether or not the module ever answers. It is not a count
               of replies and it is never a position in an array.
  txn_id       a positive run-local integer for one utterance the module is
               speaking. It is minted at the reply that ACCEPTS a submission -
               SPEAK, CHAR, KEY or SOUND_ICON, all four accepted with the same
               200 OK SPEAKING and spoken as their own SPDMessageType - and
               written as a transaction_open record before that reply's own
               record, and it is closed by a transaction_close record after the
               event that ended it.

A submission accepted while a previous utterance is still open ends that
utterance and opens a fresh transaction for the new one. The module's own
acceptance reply is the causal edge, so the 701 BEGIN and the audio that follow
it belong to the request just accepted and to nothing else. The transaction
that was replaced is closed with unclosed set and close_reason
"superseded-by-accepted-submission": no 702 END, 703 STOP or 704 PAUSE for it
was on the wire, and none is invented. An event that arrives after that
replacement but before the new transaction's own 701 BEGIN belongs to one of
the two or to neither, so it names no owner at all.

A handshake reply is owned by the request that is current at the instant its
bytes are observed. A 7xx event is owned by the transaction that is open at that
instant, and by nothing else, so a SET block written while a speech runs can
never take that speech's audio. Both slots are read and advanced under one
short-held lock, and no pump holds it across a pipe write, a raw-file write or
an index write, so a name is always decided before the bytes it describes move.

The daemon's own lock-step does the rest of it. It writes one message at a time
and waits for that message's answer before it writes the next message-shaped
exchange, so a request stays current until its CLOSING reply is observed and not
merely until its payload terminator. A SPEAK is still waiting for its
200 OK SPEAKING after its lone dot, and a request closed at the terminator
instead is a way of letting a neighbour's reply be read as this one's answer.

STOP, PAUSE and DEBUG open no request and own no reply. A cancel is a bare
STOP: the transaction stays open, the audio that follows it stays with the same
owner, and the transaction ends on its own 702 END. DEBUG is a plain command,
DEBUG ON or DEBUG OFF, because the module's own entry point is
module_debug(int enable, const char *file) and the flag already travels in the
line, so DEBUG never opens a settings block.

Nothing here re-reads a line because it happens to spell a verb. While a
payload is open every line is payload, because that is what cmd_speak collects
until the lone ``".\\n"``; a payload whose text happens to be the word SET is
still text.
Ownership that the bytes do not decide is written down as unknown: the
record carries an ownership_note naming what was really seen, and a framing
fault that really happened carries a violation. Neither is resolved by a clock,
by a timestamp interval or by an Nth row. The stamps on a record are
diagnostics and they decide nothing.

A signal is passed on through a pidfd for the child this program actually
forked, so it can never land on a process that happens to reuse the number.
That pidfd is REQUIRED, not preferred. Both handles are checked before the
first pipe exists, so an interpreter that cannot name a process by descriptor
never gets as far as starting one. The kernel can still refuse pidfd_open
after the fork - the process table is full, or a policy forbids it - and the
module waits behind a startup gate until it does not: the forked child blocks
on one byte before it executes anything, and that gate opens only once the
descriptor is held and the ownership is written into the index. A refusal
after the fork therefore stops a child that never ran, inside a bound, with
that child's real status in the footer: never an orphaned module, and never a
module exit nobody observed. Just before it execs, the child writes one byte
on a second, separate pipe, so the footer can report from that byte's own
arrival whether the exec call was reached at all - and that byte says nothing
about whether execv then succeeded, which is the module's own to report.

The four signals that are passed on are blocked across the fork and the
pinning and restored once the descriptor exists, so the handler never has a
moment in which it holds a child but no descriptor for that child. A signal
that arrives with no descriptor to use is HELD and delivered through the
descriptor the moment there is one; a signal that arrives after the module is
reaped is reported as undelivered, because the number is not this module's
any more. The child restores the default dispositions and the signal mask it
inherited before it execs, so the genuine module never inherits the
observer's own bookkeeping. While the child is unreaped a pidfd names it;
once the child is reaped the live flag is cleared BEFORE the descriptor is
closed, so no instant exists in which a signal could be aimed at a number the
kernel has already handed to somebody else.

How this process ENDS is the module's own ending, made genuine. The module's
real status is written to footer.json first, and then a module that exited
normally gives this process its exit code, while a module killed by a signal
has that signal RE-RAISED on this process with the default disposition
restored, so the daemon that forked this program reaps a genuine WIFSIGNALED
rather than a synthesised 128+n exit code. If the module's status cannot be
read at all, this program refuses the run rather than reporting a clean exit it
did not observe; and when it refuses before any module exists, it exits with
its own refusal code instead of borrowing a status from a process that never
became a module.

Nothing here claims a byte moved when it did not. The footer counts the bytes
put into each raw file and the bytes handed to the other side as two separate
numbers: a byte that was written down and then refused on its way out is
counted as traced and NOT as forwarded, and both numbers are compared with the
files themselves on the way out.

Configuration arrives through the environment, because the daemon execs a
module with a fixed argv[0] and argv[1] and nothing else:

  NOGUI_MODULE_OBSERVER_MODULE  absolute path of the genuine module to run
  NOGUI_MODULE_OBSERVER_TRACE    private, creator-owned directory for the trace

Both are required, and this program installs nothing. devenv.nix packages it
from ./tools/speech_module_observer.py and exports the store path as
NOGUI_MODULE_OBSERVER.

  NOGUI_MODULE_OBSERVER_META    optional absolute path of the daemon's own
                               native write-record sidecar. This program reads
                               it and never creates, writes, truncates, chmods
                               or unlinks it. Absent means the sideband is off
                               for the whole run and every native attribution
                               is unknown-but-total, which is a different fact
                               from a partial gap.

Trace files - all 0600, all created with O_EXCL, all inside the trace
directory and nowhere else:

  header.json    identity of both processes and of the module file
  stdin.bin      verbatim bytes the daemon wrote towards the module
  stdout.bin     verbatim bytes the module wrote towards the daemon
  events.jsonl   one JSON record per framed message, command and event, with
                 offsets, stamps and the two names above: request_open,
                 command, submission, block, event, transaction_open and
                 transaction_close
  footer.json    exit status, signal, byte counts
  bindings.jsonl  one JSON record per closed daemon->module span - every
                 submission, every block and every command - carrying the
                 native DaemonUID that produced those exact bytes, or the
                 typed unknown that stopped it. Nothing already in
                 events.jsonl is changed, moved or restamped by it

The framing in events.jsonl is derived from the pinned source and is
re-derivable from the two raw streams alone, so the index can be checked
against the bytes it describes instead of being trusted.

The daemon also names its OWN message id at the one function every daemon to
module write passes through, and publishes that name beside the bytes it
really moved. This program joins the two without waiting for the sideband and
without letting it change a single byte in either direction: a span is bound
from its OWN physical extent once the records covering that extent have
actually been read, and a span whose records have not arrived yet stays
unresolved rather than being called unknown too early. One utterance is
several native writes, so coverage is the UNION of contiguous writes and every
one of them must agree on the message id; disagreement, a hole, a foreign pipe,
a reused birth or a partially written command are all unknown, never a pick.
"""

from __future__ import annotations

import base64
import bisect
import errno
import hashlib
import json
import os
import select
import signal
import stat
import sys
import threading
import time

ENV_MODULE = "NOGUI_MODULE_OBSERVER_MODULE"
ENV_TRACE = "NOGUI_MODULE_OBSERVER_TRACE"
ENV_META = "NOGUI_MODULE_OBSERVER_META"

# One read is this much. Large enough that a 10 kB module chunk is never split
# across two records by this program's own buffer, small enough that a quiet
# pipe never sits in a read.
READ_SIZE = 65536
# How long a pump waits in select() before it looks at the stop flag again.
POLL_SECONDS = 0.05
# How long a pump is given to finish after the module has already exited.
JOIN_SECONDS = 1.0
# How long the module's last output is given to leave its pipe after the
# module has been reaped. Bounded on purpose: past this the drain is reported
# as incomplete rather than waited on, because a pipe nobody writes to any
# more reaches EOF on its own and a hang is not evidence.
DRAIN_SECONDS = 5.0

# ── the daemon's native write records, read side ─────────────────────────────
#
# The sidecar is written by the daemon on a descriptor of its own and is read
# here and nowhere else. It names the message the daemon was writing, the pipe
# it wrote into, the daemon's own birth and the byte extent the kernel really
# took. Everything below is bounded: a line, a read, the number of records held
# back, the number of coverage runs and the number of unresolved spans all have
# a ceiling, and a ceiling that is reached is reported as a typed unknown rather
# than absorbed by growing.
META_VERSION = 1
META_KIND = 1
# The daemon formats each row on a fixed stack buffer, so a row that is longer
# than this is not a row: it is a torn or a foreign write, and it stops the
# stream here rather than being assembled out of a growing buffer.
META_LINE_MAX = 1024
META_READ_SIZE = 65536
# How many already-read rows may wait for this run to trace the bytes they name,
# how many merged coverage runs are kept, and how many spans may wait for their
# own records. Each ceiling makes the reader say "meta_pending_overflow",
# "meta_coverage_overflow" or "binding_overflow" instead of growing without end.
META_MAX_PENDING = 1024
META_MAX_RUNS = 4096
META_MAX_BINDINGS = 4096
# How long the sidecar is still read after the module is gone and the daemon
# side has stopped, so the last rows the daemon really wrote are not lost to a
# race between its last append and this program's last poll.
META_DRAIN_SECONDS = 1.0
# The whole outcome vocabulary. "complete" means every requested byte is in the
# pipe; anything else is "error" and can never carry a whole submission, though
# the prefix it did move stays on the record.
META_OUTCOMES = frozenset({"complete", "error"})
# The rows that name a different physical thing and are therefore dropped on
# their own, leaving the rest of the file usable. EVERY other refusal stops the
# stream at that row, because a row this program cannot read is a row it can no
# longer reason about the bytes after either.
META_ROW_EXCLUDED = frozenset({"meta_other_pipe", "meta_other_daemon", "meta_other_proxy"})
# How many refused-but-scoped rows are remembered, so a span one of them landed
# inside can be told WHICH foreign thing claimed its bytes.
META_MAX_EXCLUDED = 1024
META_MAX_CONFLICTS = 1024

# ── the startup gate and the exec notice ────────────────────────────────────
#
# The module is forked behind a gate: it executes nothing until this program
# holds the pidfd that names it and has written that ownership down. Two bytes
# decide the whole thing, one in each direction, and both pipes are CLOEXEC.
GATE_EXEC = b"1"
GATE_ABORT = b"0"
# The byte the child writes immediately before calling execv. Its write end
# exists nowhere else, so once the child is gone a single read either finds
# this byte or finds an end of file - never a wait.
EXEC_NOTICE = b"x"
# How long the child waits for the gate's byte before it gives up and exits
# without executing anything. This program answers in microseconds; the bound
# is there so no child of this program can sit on that read forever.
STARTUP_GATE_SECONDS = 10.0
# How long the child that never executed the module is given to leave once the
# abort byte is written. Polled, never blocked on.
STARTUP_ABORT_SECONDS = 5.0
# What that child exits with. It is this program's own code, not a module's.
STARTUP_ABORT_EXIT = 126
# This program's exit code when it refuses to run. There is no module status
# to reproduce in that case, so the run ends with the observer's own refusal.
REFUSAL_EXIT = 2

# ── the pinned wire format ──────────────────────────────────────────────────
#
# HDLC, written by src/modules/module_process.c `module_tts_output_send_server`
# and undone by src/server/output.c in its 705 branch: a payload byte equal to
# 0x7d or 0x0a goes out as 0x7d followed by that byte with bit 5 inverted.
HDLC_ESCAPE = 0x7D
HDLC_INVERT = 1 << 5
# `output_read_message` reads line by line and ends the message when the C
# string length of that line is under four, or when byte 3 is a space. A
# message's LAST line therefore carries numcode, a space and a phrase; every
# continuation line carries a dash there.
SSIP_SHORT_CSTRING = 4
SSIP_TERMINATOR_INDEX = 3
SSIP_TERMINAL_BYTE = 0x20
# The audio header ends with the literal 705-AUDIO and a NUL, not a newline,
# which is why the payload's own newlines are the escaped ones.
AUDIO_MARKER = b"705-AUDIO\x00"

HEADER_NAME = "header.json"
FOOTER_NAME = "footer.json"
EVENTS_NAME = "events.jsonl"
TO_MODULE_NAME = "stdin.bin"
FROM_MODULE_NAME = "stdout.bin"
# The resolved native attribution for every closed daemon->module span. It is
# its OWN index, written here and read by whoever consumes this trace, so no
# record already in events.jsonl is moved, restamped or delayed by it.
BINDINGS_NAME = "bindings.jsonl"

PRIVATE_FILE_MODE = 0o600
PRIVATE_DIR_MODE = 0o077

# Verbs the daemon answers with a block: the verb line, then payload lines up
# to a lone ".\n". The four submission verbs carry the text a reader fragment
# is later bound to; the rest are recorded whole. DEBUG is NOT in this set: the
# module's own entry point for it is module_debug(int enable, const char
# *file) (spd_module_main.h:106), so the flag travels inside the one line and
# the daemon opens no payload for it.
#
# The four submission verbs are one thing to the module ABI, not four. Each
# names the SPDMessageType that cmd_speak hands module_speak_sync
# (speechd_types.h: SPD_MSGTYPE_TEXT 0, SPD_MSGTYPE_SOUND_ICON 1,
# SPD_MSGTYPE_CHAR 2, SPD_MSGTYPE_KEY 3), and every one of them is collected
# the same way and answered the same way. So one acceptance rule covers all
# four, and none of it applies to SPEAK alone.
SUBMISSION_MESSAGE_TYPES = {
    b"SPEAK": "SPD_MSGTYPE_TEXT",
    b"SOUND_ICON": "SPD_MSGTYPE_SOUND_ICON",
    b"CHAR": "SPD_MSGTYPE_CHAR",
    b"KEY": "SPD_MSGTYPE_KEY",
}
SUBMISSION_VERBS = frozenset(SUBMISSION_MESSAGE_TYPES)
BLOCK_VERBS = frozenset({b"SET", b"AUDIO", b"LOGLEVEL"})
BLOCK_START = SUBMISSION_VERBS | BLOCK_VERBS

# Commands the daemon writes on one line and the module answers on that same
# exchange, with no payload between. INIT opens the session and QUIT ends it.
# The real module answers INIT with "299-Espeak-ng: Initialized successfully."
# and then "299 OK LOADED SUCCESSFULLY", and QUIT with "210 OK QUIT".
SINGLE_REPLY_COMMANDS = frozenset({b"INIT", b"QUIT"})

# Commands that expect NO reply and own nothing. STOP and PAUSE steer the
# transaction that is already open: they do not replace it, they do not close
# it, and no reply of their own follows, so a cancel is a bare STOP, then more
# 705 frames, then the transaction's own terminal 702 END, 703 STOP or 704 PAUSE.
# DEBUG is matched on the first token, so both "DEBUG ON" and "DEBUG OFF" land here.
NO_REPLY_COMMANDS = frozenset({b"STOP", b"PAUSE", b"DEBUG"})

# The reply that ACCEPTS a submission and opens the transaction it speaks. All
# four submission verbs are accepted with this one code: cmd_speak writes
# "202 OK RECEIVING MESSAGE" before the payload and "200 OK SPEAKING" after the
# lone dot, whether the payload was text, a sound icon, one character or one
# key. A refusal never reaches here; a non-2xx reply closes the request as
# refused and opens nothing.
SPEAKING_CODE = 200

# The four module-side speech events, by their numcode. The line that carries
# the code carries it at byte 3 as a space; the words after it are the
# module's to choose, so only the code is matched.
EVENT_CODES = {b"701": "begin", b"702": "end", b"703": "stopped", b"704": "paused"}
# The shapes that end a transaction. A stop and a pause end one the same way
# an end does, because they are the module's own report that it stopped making
# that sound.
CLOSING_SHAPES = frozenset({"end", "stopped", "paused"})

FORWARDED_SIGNALS = ("SIGTERM", "SIGINT", "SIGHUP", "SIGQUIT")

# ── the pinned fragments the daemon's own rules were read from ─────────────
#
# Two questions about the sideband cannot be answered from a record, because
# both are about code that ran before any record existed: is a lock held
# ACROSS the daemon -> module write, and does that write's own errno survive
# the record describing it. The framing rules further up were read the same way,
# from the functions named in write_header's pinned note. Every entry here
# names the fragment the rule was read from, the exact lines of that fragment,
# and the lines those lines fix in the patched C file, so a reader can go and
# look instead of taking this program's account of its own source for it.
#
# Both fragments are hunks of src/server/output.c in this repository's own
# patches, which is what makes the ranges checkable here: the patched line
# numbers are the ones the hunks fix, and they move if the hunks move.
PINNED_SOURCE = (
    {
        "file": "src/server/output.c",
        "function": "output_write_all",
        "fragment": "tools/patches/speech-dispatcher-write-all.patch",
        "fragment_lines": "21-53",
        "patched_lines": "418-450",
        "anchor": "static int output_write_all(",
        "says": "the daemon's own write loop: a short write continues over the remainder instead of "
            "reporting success, EINTR is retried without consuming the count, a zero return becomes EIO "
            "rather than a reason to spin, and a failure part way through reports the prefix that really "
            "moved. That prefix, never the count asked for, is what a record's written field holds and "
            "what this program advances its own offsets by",
    },
    {
        "file": "src/server/output.c",
        "function": "output_send_data",
        "fragment": "tools/patches/speech-dispatcher-write-all.patch",
        "fragment_lines": "62-64",
        "patched_lines": "470-471",
        "anchor": "ret = output_write_all(output->pipe_in[1], cmd, nbytes, &written);",
        "says": "the one call every daemon -> module write passes through, so the count a record names is "
            "the count that one call really made",
    },
    {
        "file": "src/server/output.c",
        "function": "audit_emit",
        "fragment": "tools/patches/speech-dispatcher-module-metadata.patch",
        "fragment_lines": "367-456",
        "patched_lines": "769-858",
        "anchor": "static void audit_emit(",
        "says": "one fixed-size record per daemon -> module write: the pipe it wrote into, both births, the "
            "stream epoch, the offset BEFORE this write, the count the kernel took, the count asked for, "
            "the message, and the errno. The offset advances by the count taken alone",
    },
    {
        "file": "src/server/output.c",
        "function": "output_send_data",
        "fragment": "tools/patches/speech-dispatcher-module-metadata.patch",
        "fragment_lines": "475-487",
        "patched_lines": "882-894",
        "anchor": "audit_emit(output, msg_id, client_id, client_fd, has_owner,",
        "says": "the record's lock is taken BEFORE the write and released AFTER the record, so the daemon's "
            "offset can never disagree with the byte order on the wire, and the write's errno is captured "
            "immediately after the write and restored after the unlock: neither audit_emit nor the unlock "
            "can change the errno the daemon's own error path goes on to report",
    },
)


class ObserverError(RuntimeError):
    """A precondition this observer refuses to run without."""


# ── small filesystem and process helpers ────────────────────────────────────


def write_all(fd: int, data: bytes) -> None:
    """Write every byte of data to fd, or raise. A short write is retried."""
    view = memoryview(data)
    sent = 0
    while sent < len(view):
        written = os.write(fd, view[sent:])
        if written <= 0:
            raise BrokenPipeError(errno.EPIPE, "write returned nothing")
        sent += written


def open_private(path: str, flags: int) -> int:
    """Create one trace file this run alone owns. Never reused, never opened."""
    return os.open(path, flags | os.O_CREAT | os.O_EXCL, PRIVATE_FILE_MODE)


def write_private_json(path: str, payload: dict) -> None:
    handle = open_private(path, os.O_WRONLY)
    try:
        write_all(handle, json.dumps(payload, indent=1, sort_keys=True).encode("utf-8") + b"\n")
    finally:
        os.close(handle)


def digest_file(path: str) -> str:
    """SHA-256 of a file, read once. This is the module's immutability record."""
    accumulator = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            accumulator.update(block)
    return accumulator.hexdigest()


def require_private_dir(path: str) -> None:
    """A trace directory this run created, reachable by nobody else."""
    if not path:
        raise ObserverError(f"{ENV_TRACE} is not set, so there is nowhere to write a trace")
    if not os.path.isabs(path):
        raise ObserverError(f"{ENV_TRACE} must be an absolute path, not {path!r}")
    try:
        info = os.stat(path)
    except OSError as failure:
        raise ObserverError(f"{ENV_TRACE}={path} cannot be read: {failure}") from failure
    if not stat.S_ISDIR(info.st_mode):
        raise ObserverError(f"{ENV_TRACE}={path} is not a directory")
    if info.st_uid != os.getuid():
        raise ObserverError(f"{ENV_TRACE}={path} is owned by uid {info.st_uid}, not by this process")
    leaked = stat.S_IMODE(info.st_mode) & PRIVATE_DIR_MODE
    if leaked:
        raise ObserverError(
            f"{ENV_TRACE}={path} is mode {stat.S_IMODE(info.st_mode):04o}, so group or other can reach "
            "it; a trace only this run may read or write must not be")


def require_module(path: str) -> dict:
    """The genuine module: a regular, executable, readable file, hashed here."""
    if not path:
        raise ObserverError(f"{ENV_MODULE} is not set, so there is no module to execute")
    if not os.path.isabs(path):
        raise ObserverError(f"{ENV_MODULE} must be an absolute path, not {path!r}")
    try:
        info = os.stat(path)
    except OSError as failure:
        raise ObserverError(f"{ENV_MODULE}={path} cannot be read: {failure}") from failure
    if not stat.S_ISREG(info.st_mode):
        raise ObserverError(f"{ENV_MODULE}={path} is not a regular file")
    if not os.access(path, os.X_OK):
        raise ObserverError(f"{ENV_MODULE}={path} is not executable")
    return {
        "path": path,
        "size": info.st_size,
        "mtime_ns": info.st_mtime_ns,
        "mode": stat.S_IMODE(info.st_mode),
        "sha256": digest_file(path),
    }


def describe_process(pid: int) -> dict:
    """The kernel's own facts about one pid: its birth, in start ticks."""
    described: dict = {"pid": pid}
    try:
        with open(f"/proc/{pid}/stat", "rb") as handle:
            raw = handle.read()
    except OSError as failure:
        described["why"] = f"/proc/{pid}/stat is unreadable: {failure}"
        return described
    close = raw.rfind(b")")
    if close < 0:
        described["why"] = f"/proc/{pid}/stat carries no comm field"
        return described
    fields = raw[close + 2:].split()
    if len(fields) < 20:
        described["why"] = f"/proc/{pid}/stat has {len(fields)} fields after comm"
        return described
    described["state"] = fields[0].decode("ascii", "replace")
    described["pgrp"] = int(fields[2])
    described["session"] = int(fields[3])
    described["start_ticks"] = int(fields[19])
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as handle:
            described["argv"] = [part.decode("utf-8", "replace") for part in handle.read().split(b"\0")[:-1]]
    except OSError:
        described["argv"] = None
    return described


def is_boot_id(value: str) -> bool:
    """Is this a full lowercase 8-4-4-4-12 UUID, or nothing?

    Exactly that shape, and not a repaired, folded or truncated version of it.
    The point of a boot id is that it names one boot and nothing else, so a
    value that is merely boot-id-shaped would agree with a row carrying the
    same wrong value, which is agreement about nothing.
    """
    parts = value.split("-")
    if len(parts) != 5:
        return False
    return all(len(part) == width
               and all(character in "0123456789abcdef" for character in part)
               for part, width in zip(parts, (8, 4, 4, 4, 12)))


def read_boot_id() -> tuple:
    """The kernel's own name for this boot, read once and kept.

    The daemon latches the same string and stamps every row with it, so two
    runs on different boots cannot be joined even if a pipe inode number
    happens to repeat. An unreadable boot id is reported as unknown here rather
    than treated as agreement, because a value nobody could read cannot agree
    with anything - and neither can one that is not a boot id at all.
    """
    try:
        with open("/proc/sys/kernel/random/boot_id", "rb") as handle:
            raw = handle.read(65)
    except OSError as failure:
        return None, f"/proc/sys/kernel/random/boot_id is unreadable: {failure}"
    try:
        value = raw.decode("ascii").strip()
    except UnicodeDecodeError:
        return None, "/proc/sys/kernel/random/boot_id is not ASCII text"
    if not value:
        return None, "/proc/sys/kernel/random/boot_id is empty"
    if not is_boot_id(value):
        return (None, f"/proc/sys/kernel/random/boot_id is not a full 8-4-4-4-12 UUID: {value!r}")
    return value, None


class MetaFieldError(ValueError):
    """A row field this reader cannot read as the type it must have."""


def meta_uint(row: dict, key: str) -> int:
    """One unsigned integer field, read exactly as it was written.

    A JSON true is an int in this language and is NOT an unsigned integer, so
    booleans are refused here rather than silently becoming 0 and 1. A
    negative, a float, a string and a missing key are refused the same way:
    there is no default and no coercion, because a default is a value nobody
    wrote.
    """
    value = row.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise MetaFieldError(f"{key} is not an unsigned integer")
    return value


def meta_nullable_uint(row: dict, key: str) -> int | None:
    """One unsigned integer field that is also allowed to be an explicit null.

    The null is not absence: it is the daemon saying "this write had no
    message", which is a different fact from a field that is not there. So the
    key must be PRESENT either way. A missing key is refused rather than read
    as a null, because a null answers "which message?" with "none" while a
    missing key answers nothing at all, and only the first of those is a fact.
    """
    if key not in row:
        raise MetaFieldError(f"{key} is missing, and a missing field is not an explicit null")
    value = row[key]
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise MetaFieldError(f"{key} is neither null nor an unsigned integer")
    return value


def meta_nullable_int(row: dict, key: str) -> int | None:
    """One signed integer field that is also allowed to be an explicit null.

    Used for the client's own connection descriptor, which the daemon carries
    as a signed int and which can be -1 on a message with no connection behind
    it, and for errno, which the record declares signed too. Those are numbers
    the daemon wrote, not faults, and this reader never compares them to
    anything. As above, the key must be present.
    """
    if key not in row:
        raise MetaFieldError(f"{key} is missing, and a missing field is not an explicit null")
    value = row[key]
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise MetaFieldError(f"{key} is neither null nor an integer")
    return value


def meta_text_or_null(row: dict, key: str) -> str | None:
    """One string field that is also allowed to be an explicit null."""
    if key not in row:
        raise MetaFieldError(f"{key} is missing, and a missing field is not an explicit null")
    value = row[key]
    if value is None or isinstance(value, str):
        return value
    raise MetaFieldError(f"{key} is neither null nor a string")


# ── the framing, taken from the pinned source ───────────────────────────────


class ToModuleFramer:
    """The daemon's side, framed exactly as the module frames it.

    ``module_readline`` returns each line including its newline,
    ``module_process`` dispatches on the whole line, and ``cmd_speak`` collects
    lines until one that is exactly ``".\\n"``. A payload line whose first byte
    is a dot carries it doubled, because ``escape_dot`` on the daemon's side
    doubles every newline-dot.

    A line that spells a verb while a payload is open is still payload text.
    ``cmd_speak`` collects lines until the lone ``".\\n"`` and reads nothing
    else, so a payload whose text happens to be the word SET is text and stays
    text. Only the framer decides what a line is, and it decides it once, from
    whether a payload is open.
    """

    def __init__(self, trace: Trace, ledger: Ledger) -> None:
        self.trace = trace
        self.ledger = ledger
        # The byte spans this framer has closed, queued for the pump. They are
        # NOT registered here: this framer runs before the bytes it framed have
        # reached the module, and touching the native reader from in there would
        # put the reader's lock on the forwarding path. The pump takes them up
        # after the handover, which is also the only order that is honest - a
        # span is real once the module has really been sent it.
        self.closed_spans: list = []
        self.seq = 0
        self.verb: bytes | None = None
        self.request_seq: int | None = None
        self.opened_ns = 0
        self.start = 0
        self.span: list = []
        self.pending = b""
        self.buffer = bytearray()
        self.buffer_offset = 0
        self.opened_wall_ns = 0
        self.last_ns = 0
        self.last_wall_ns = 0

    def feed(self, data: bytes, monotonic_ns: int, wall_ns: int) -> None:
        """Every byte of one read, in the order it was read.

        A read boundary is this program's business and nothing else, so a
        line split across two reads is carried whole and a read that ends
        mid-line keeps its tail. No byte is ever dropped and no byte is ever
        seen twice: the daemon's own fragmentation survives untouched, and
        the offsets below count from the start of the stream, not from the
        start of a read.
        """
        self.buffer += data
        while True:
            index = self.buffer.find(b"\n")
            if index < 0:
                return
            line = bytes(self.buffer[:index + 1])
            del self.buffer[:index + 1]
            offset = self.buffer_offset
            self.buffer_offset += len(line)
            self.last_ns = monotonic_ns
            self.last_wall_ns = wall_ns
            self.feed_line(line, offset, monotonic_ns, wall_ns)

    def feed_line(self, line: bytes, offset: int, monotonic_ns: int, wall_ns: int) -> None:
        """One complete line, newline included, as the module would see it.

        A payload line contributes its WHOLE bytes to the text the module
        assembles: ``cmd_speak`` copies ``strlen(line)`` bytes, and
        ``module_readline`` returns the newline with the line, so the newline
        that ended the line IS part of the text. Two things come off a payload
        line, and only two: one leading dot, because the daemon's ``escape_dot``
        doubled it, and - in ``_close``, not here - the single newline the
        lone ``".\\n"`` terminator accounts for. Every interior newline stays,
        which is what makes a multi-line SPEAK payload byte for byte the text
        the module really reads.
        """
        if self.verb is None:
            self._open_or_command(line, offset, monotonic_ns, wall_ns)
            return
        self.span.append([offset, len(line)])
        if line == b".\n":
            self._close(offset + len(line), monotonic_ns, wall_ns, terminated=True)
            return
        body = line
        if body.startswith(b"."):
            body = body[1:]
        self.pending += body

    def _open_or_command(self, line: bytes, offset: int, monotonic_ns: int, wall_ns: int) -> None:
        """One line that opens a request, or one command line that does not.

        The request_open record is written HERE, at the verb line, and the pump
        has not yet handed this line to the module. The name is therefore on the
        index before any byte of the message it names reaches the module, so the
        reply the module writes for it cannot be seen before the request it
        answers.

        A line that is not a block verb is a command. INIT and QUIT carry one
        reply and so they open a request. STOP, PAUSE and DEBUG carry none, so
        they open nothing, publish nothing and own nothing: a STOP written into
        a live transaction leaves that transaction exactly as it was.
        """
        verb = line[:-1] if line.endswith(b"\n") else line
        if verb in BLOCK_START:
            self.verb = verb
            self.opened_ns = monotonic_ns
            self.opened_wall_ns = wall_ns
            self.start = offset
            self.span = [[offset, len(line)]]
            self.pending = b""
            opened = self.ledger.open_request(
                verb, verb, offset, len(line), "reply-before-payload", True, monotonic_ns, wall_ns)
            self.request_seq = opened["request_seq"]
            self.trace.record({
                "kind": "request_open",
                "request_seq": opened["request_seq"],
                "verb": text_of(verb),
                "verb_hex": verb.hex(),
                "line_hex": line.hex(),
                "offset": offset,
                "length": len(line),
                "expects": "reply-before-payload",
                "opens_payload": True,
                "predecessor_request_seq": opened["predecessor_request_seq"],
                "open_txn_id": self.ledger.current_transaction(),
                "opened_monotonic_ns": monotonic_ns,
                "opened_wall_ns": wall_ns,
                "monotonic_ns": monotonic_ns,
                "wall_ns": wall_ns,
            })
            return
        fields = verb.split()
        token = fields[0] if fields else b""
        if token in NO_REPLY_COMMANDS:
            expects = "no-reply"
        elif token in SINGLE_REPLY_COMMANDS:
            expects = "reply"
        else:
            expects = "unknown"
        opened = None
        if expects != "no-reply":
            opened = self.ledger.open_request(
                verb, token, offset, len(line), expects, False, monotonic_ns, wall_ns)
            self.request_seq = opened["request_seq"]
        self.seq += 1
        self.trace.record({
            "kind": "command",
            "seq": self.seq,
            "verb": text_of(verb),
            "verb_hex": verb.hex(),
            "verb_token": text_of(token),
            "offset": offset,
            "length": len(line),
            # A command that expects no reply carries a null request_seq and no
            # predecessor, because it opened no slot. Every other command
            # carries the slot it published, so its reply can be found.
            "request_seq": None if opened is None else opened["request_seq"],
            "predecessor_request_seq": None if opened is None else opened["predecessor_request_seq"],
            "expects": expects,
            "open_txn_id": self.ledger.current_transaction(),
            "monotonic_ns": monotonic_ns,
            "wall_ns": wall_ns,
        })
        # This command's own bytes are one native write the daemon made, so its
        # span is queued for binding exactly as a block's is. A STOP, PAUSE or
        # DEBUG carries the daemon's explicit null owner, and the binding says
        # so instead of borrowing the utterance it interrupted. Queued only: the
        # pump takes these up once the bytes have reached the module.
        self.closed_spans.append(
            ("command", None if opened is None else opened["request_seq"],
             text_of(verb), offset, len(line)))

    def _close(self, end: int, monotonic_ns: int, wall_ns: int, terminated: bool) -> None:
        verb = self.verb if self.verb is not None else b""
        # The payload this block really carried is captured HERE, before the
        # framer forgets it. Clearing the buffer first and reading the text out
        # of it afterwards would report an empty submission for every request,
        # whatever bytes the daemon really wrote.
        pending = self.pending
        request_seq = self.request_seq
        if request_seq is not None:
            # The lone dot is written; the request is still waiting for its
            # closing reply, so it is NOT retired here. Only the closing reply,
            # or the end of the run, ends it.
            self.ledger.payload_ended(request_seq, terminated)
        entry: dict = {
            "terminated": terminated,
            "offset": self.start,
            "length": end - self.start,
            "lines": self.span,
            "request_seq": request_seq,
            "request_state": None if request_seq is None else self.ledger.request_state(request_seq),
            "open_txn_id": self.ledger.current_transaction(),
            "opened_monotonic_ns": self.opened_ns,
            "opened_wall_ns": self.opened_wall_ns,
            "closed_monotonic_ns": monotonic_ns,
            "closed_wall_ns": wall_ns,
        }
        self.verb = None
        self.pending = b""
        self.span = []
        self.request_seq = None
        self.seq += 1
        entry["seq"] = self.seq
        if verb in SUBMISSION_VERBS:
            text = pending
            entry["kind"] = "submission"
            entry["verb"] = verb.decode("ascii", "replace")
            # The SPDMessageType cmd_speak hands module_speak_sync for this
            # verb. It is what makes a CHAR or a KEY an utterance in its own
            # right rather than a SPEAK that happens to carry one character.
            entry["message_type"] = SUBMISSION_MESSAGE_TYPES[verb]
            # cmd_speak takes exactly ONE newline off the assembled text, and
            # only for the ".\n" terminator that ended the block: that is the
            # single byte its own length arithmetic drops. A block the daemon
            # never terminated keeps the newline its last real line carried.
            if terminated and text.endswith(b"\n"):
                text = text[:-1]
            entry["text_len"] = len(text)
            entry["text_sha256"] = hashlib.sha256(text).hexdigest()
            entry["text_b64"] = base64.b64encode(text).decode("ascii")
        else:
            entry["kind"] = "block"
            entry["verb"] = verb.decode("ascii", "replace")
        self.trace.record(entry)
        # The whole block - verb line, payload and the lone dot - is one native
        # submission the daemon wrote, and it is usually several native writes
        # on the wire. Its own byte extent is what gets bound, never its text,
        # its verb or its position in the index.
        self.closed_spans.append(
            (entry["kind"], request_seq, entry["verb"], entry["offset"], entry["length"]))

    def flush(self) -> None:
        """An unterminated block at EOF is reported, never silently dropped."""
        if self.verb is not None:
            self._close(self.start, time.monotonic_ns(), time.time_ns(), terminated=False)

    def take_spans(self) -> list:
        """The spans closed since this was last called, given up for good.

        The pump calls this after the bytes have reached the module, so the
        reader is never touched on the forwarding path and never names a span
        the module has not really been sent.
        """
        spans = self.closed_spans
        self.closed_spans = []
        return spans


class FromModuleFramer:
    """The module's side, framed exactly as the daemon frames it.

    ``output_read_message`` appends each getline result to one buffer and ends
    the message when the C string length of that line is under four or when
    byte 3 is a space. The line carrying the audio header's ``705-AUDIO`` NUL
    is not shorter than four and has ``A`` at byte 3, so the message continues
    into the escaped payload and ends on the trailing ``705 AUDIO`` line.
    """

    def __init__(self, trace: Trace, ledger: Ledger) -> None:
        self.trace = trace
        self.ledger = ledger
        self.seq = 0
        self.buffer = bytearray()
        self.buffer_offset = 0
        self.message = bytearray()
        self.message_offset = 0

    def feed(self, data: bytes, monotonic_ns: int, wall_ns: int) -> None:
        """Every byte of one read, in the order it was read.

        A read boundary decides nothing here either: a message split across
        two reads is carried whole, and the offsets count from the start of
        the stream rather than from the start of a read.
        """
        self.buffer += data
        while True:
            index = self.buffer.find(b"\n")
            if index < 0:
                return
            line = bytes(self.buffer[:index + 1])
            del self.buffer[:index + 1]
            offset = self.buffer_offset
            self.buffer_offset += len(line)
            if not self.message:
                self.message_offset = offset
            self.message += line
            if is_message_terminator(line):
                message = bytes(self.message)
                start = self.message_offset
                self.message = bytearray()
                self._emit(message, start, monotonic_ns, wall_ns)

    def flush(self, monotonic_ns: int, wall_ns: int) -> None:
        """Bytes with no terminating newline are evidence too, not nothing."""
        if self.buffer:
            message = bytes(self.message + self.buffer)
            start = self.message_offset
            self.buffer = bytearray()
            self.message = bytearray()
            self._emit(message, start, monotonic_ns, wall_ns, truncated=True)

        # The module's output ended. A transaction still open at this point never
        # closed, and that is written down as it happened: no closing event is
        # invented for it, because a 702 that was never on the wire would put an
        # end to audio nobody heard end.
        for record in self.ledger.finish_transaction(
                "the module's output ended while this transaction was open, so no closing event was "
                "observed and the transaction is reported unclosed",
                monotonic_ns, wall_ns):
            self.trace.record(record)

    def _emit(self, message: bytes, start: int, monotonic_ns: int, wall_ns: int,
              truncated: bool = False) -> None:
        self.seq += 1
        classified = classify_event(message)
        audio = decode_audio_event(message, start)
        # The owner is decided once, here, from the shape of these bytes and from
        # which slot the ledger holds open at this instant. The ledger lock is
        # released before any byte is written, so the name is settled before the
        # record that carries it and before the handover of the same bytes.
        decision = self.ledger.attribute_event(
            classified, start, len(message), audio.get("audio", {}).get("pcm_length"), monotonic_ns, wall_ns,
            truncated)
        before = decision.pop("before")
        after = decision.pop("after")
        for record in before:
            self.trace.record(record)
        entry: dict = {
            "kind": "event",
            "seq": self.seq,
            "offset": start,
            "length": len(message),
            "truncated": truncated,
            "head": message[:64].decode("utf-8", "replace"),
            # The stamp of the read this message ended in, taken before the
            # bytes were handed to the daemon, never after.
            "monotonic_ns": monotonic_ns,
            "wall_ns": wall_ns,
        }
        entry.update(decision)
        entry.update(audio)
        self.trace.record(entry)
        for record in after:
            self.trace.record(record)


def is_message_terminator(line: bytes) -> bool:
    """The daemon's own end-of-message test, byte for byte."""
    nul = line.find(b"\0")
    c_length = nul if nul >= 0 else len(line)
    if c_length < SSIP_SHORT_CSTRING:
        return True
    return line[SSIP_TERMINATOR_INDEX] == SSIP_TERMINAL_BYTE


def text_of(raw: bytes) -> str:
    """Bytes as the index prints them. One decode rule, used everywhere."""
    return raw.decode("utf-8", "replace")


def classify_event(message: bytes) -> dict:
    """One framed message from the module: its shape, its code, its mark name.

    The shape is read from the message's FIRST line, because that is the line
    the numcode is on. A chunk starts "705-" and runs to the trailing
    "705 AUDIO" line. A mark is "700-" followed by the name the payload used.
    "701", "702", "703" and "704" followed by a space are the begin, end, stop
    and pause events, and the words after the code are the module's to choose.
    Any other line that starts with three digits and then a space or a dash is
    a handshake reply, and any other message is "other".

    An "other" message owns nothing. It is indexed and left for the consumer to
    refuse, because a name read out of a message that is not a handshake reply
    and not a speech event would be invented.
    """
    first = message.split(b"\n", 1)[0]
    if message.startswith(b"705-"):
        return {"shape": "audio", "code": 705, "mark_name": None, "first_line": text_of(first)}
    if first.startswith(b"700-"):
        return {"shape": "mark", "code": 700, "mark_name": first[4:], "first_line": text_of(first)}
    if first[:3] in EVENT_CODES and first[3:4] == b" ":
        return {
            "shape": EVENT_CODES[first[:3]],
            "code": int(first[:3]),
            "mark_name": None,
            "first_line": text_of(first),
        }
    if len(first) >= 4 and first[:3].isdigit() and first[3:4] in (b" ", b"-"):
        return {"shape": "handshake", "code": int(first[:3]), "mark_name": None, "first_line": text_of(first)}
    return {"shape": "other", "code": None, "mark_name": None, "first_line": text_of(first)}


class HDLCError(ValueError):
    """An escape byte with nothing left to unescape."""


def hdlc_decode(escaped: bytes) -> bytes:
    """The payload the module really wrote, byte for byte.

    One rule, the one the daemon's reader applies: 0x7d introduces the next
    byte with bit 5 inverted, and it costs exactly one extra byte on the wire.
    Every other byte stands for itself. A trailing 0x7d has nothing to
    unescape and is reported, never invented.
    """
    out = bytearray()
    index = 0
    size = len(escaped)
    while index < size:
        byte = escaped[index]
        if byte != HDLC_ESCAPE:
            out.append(byte)
            index += 1
            continue
        index += 1
        if index >= size:
            raise HDLCError(
                f"the escaped payload ends on a bare 0x{HDLC_ESCAPE:02x} escape with no byte after it, so "
                "the next real byte is not on this wire")
        out.append(escaped[index] ^ HDLC_INVERT)
        index += 1
    return bytes(out)


def decode_audio_event(message: bytes, start: int) -> dict:
    """One 705 chunk, described by offsets into the raw stream, not by bytes.

    Offsets, not samples: the PCM stays where it was really written, in
    stdout.bin, and this index only says where it is.
    """
    if not message.startswith(b"705-"):
        return {}
    marker = message.find(AUDIO_MARKER)
    if marker < 0:
        return {"audio_error": "no 705-AUDIO NUL marker in the header"}
    fields: dict = {}
    for line in message[:marker].split(b"\n"):
        if not line:
            continue
        if not line.startswith(b"705-"):
            return {"audio_error": f"header line does not start with 705-: {line[:32]!r}"}
        key, equals, value = line[4:].partition(b"=")
        if not equals:
            return {"audio_error": f"header line carries no value: {line[:32]!r}"}
        try:
            fields[key.decode("ascii", "replace")] = int(value)
        except ValueError:
            return {"audio_error": f"header value is not an integer: {line[:32]!r}"}
    payload_at = marker + len(AUDIO_MARKER)
    end = message.find(b"\n", payload_at)
    if end < 0:
        return {"audio_error": "the escaped payload is not terminated by a newline"}
    bits = fields.get("bits", 0)
    channels = fields.get("num_channels", 0)
    samples = fields.get("num_samples", 0)
    expected = channels * samples * bits // 8
    # The payload really on the wire is decoded here, byte for byte, with the
    # same rule the daemon's reader undoes: 0x7d introduces the next byte with
    # bit 5 inverted, and it adds exactly ONE byte per escaped byte. Nothing is
    # inferred from a total message length and no parity is assumed.
    escaped_bytes = message[payload_at:end]
    try:
        payload = hdlc_decode(escaped_bytes)
    except HDLCError as failure:
        return {
            "audio": {
                "bits": bits,
                "num_channels": channels,
                "sample_rate": fields.get("sample_rate"),
                "num_samples": samples,
                "big_endian": fields.get("big_endian"),
                "escaped_offset": start + payload_at,
                "escaped_length": len(escaped_bytes),
                "expected_pcm_bytes": expected,
                "terminator": message[end + 1:].decode("utf-8", "replace"),
            },
            "audio_error": str(failure),
        }
    decoded = {
        "audio": {
            "bits": bits,
            "num_channels": channels,
            "sample_rate": fields.get("sample_rate"),
            "num_samples": samples,
            "big_endian": fields.get("big_endian"),
            "escaped_offset": start + payload_at,
            "escaped_length": len(escaped_bytes),
            # The real count, measured on the real bytes, not derived.
            "pcm_length": len(payload),
            "expected_pcm_bytes": expected,
            # Every escape added exactly one byte, so this is a count, not a
            # guess: escaped_length minus the decoded length.
            "escapes": len(escaped_bytes) - len(payload),
            "terminator": message[end + 1:].decode("utf-8", "replace"),
        },
    }
    if not expected:
        decoded["audio_error"] = (
            "the header declares no usable bit depth, channel count and sample count, so this chunk's "
            "PCM length cannot be checked against anything")
    elif len(payload) != expected:
        decoded["audio_error"] = (
            f"the escaped payload decodes to {len(payload)} PCM bytes but the header declares "
            f"{channels} channel(s) x {samples} sample(s) x {bits} bit(s) = {expected} bytes")
    return decoded


# ── the two names: one request slot, one transaction slot ────────────────────
#
# Both pumps meet here and nowhere else. The daemon writes a line in one
# thread and the module answers in the other, so the question "who owns what"
# has exactly one place it can be asked, and one place it can be wrong.


class Ledger:
    """The request slot and the transaction slot, and the lock that guards both.

    The REQUEST slot names a message the daemon wrote that bears a reply. It is
    opened by its verb line, named by a positive run-local ``request_seq``, and
    stays current until its CLOSING reply is observed. The TRANSACTION slot
    names one utterance the module is speaking. It is opened by the reply that
    accepts a submission - SPEAK, CHAR, KEY or SOUND_ICON alike, because
    cmd_speak accepts all four with the same 200 OK SPEAKING and speaks each as
    its own SPDMessageType - named by a positive run-local ``txn_id``, and closed
    by the event that ends it. An acceptance that arrives while a transaction
    is still open closes that one as superseded and opens a fresh transaction
    for the submission just accepted, so two utterances never share one owner.

    Neither name is a daemon UID. The 0.12.1 module protocol carries no UID,
    no client id and no message id on any stream, so none is minted, guessed
    or called one here; these are run-local counters and nothing else.

    A handshake reply belongs to the request that is current when its bytes are
    observed. A 7xx event belongs to the transaction that is open when its bytes
    are observed and to nothing else, so a SET block written while a speech
    runs can never take that speech's audio, and a bare STOP can never close a
    transaction. STOP, PAUSE and DEBUG open neither slot.

    The lock is held to read or advance an integer and to build the records that
    go with it. No pump holds it across a pipe write, a raw-file write or an
    index write, so a name is always decided before, and independently of, the
    bytes it describes. Nothing here reads a clock: the stamps on a record are
    diagnostics, and ownership is decided only by the shape of the bytes and by
    which slot was open.
    """

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.requests: dict = {}
        self.next_request_seq = 1
        self.current_request_seq: int | None = None
        self.transactions: dict = {}
        self.next_txn_id = 1
        self.open_txn_id: int | None = None

    def current_transaction(self) -> int | None:
        """The transaction open right now, for a record about the other side."""
        with self.lock:
            return self.open_txn_id

    def open_request(self, verb: bytes, token: bytes, offset: int, length: int, expects: str,
                     opens_payload: bool, monotonic_ns: int, wall_ns: int) -> dict:
        """Name the request the daemon is opening, before its bytes are forwarded.

        The name is minted here, at the verb line, and not counted from the
        replies that follow, because it names a message the daemon wrote and a
        message exists whether or not it is answered. The request this one
        replaces is named back, and it is not quietly retired: if it was never
        answered, that stays in the index where a reader can refuse it.
        """
        with self.lock:
            seq = self.next_request_seq
            self.next_request_seq = seq + 1
            predecessor = self.current_request_seq
            self.current_request_seq = seq
            self.requests[seq] = {
                "request_seq": seq,
                "verb": text_of(verb),
                "verb_token": text_of(token),
                "token_bytes": token,
                "offset": offset,
                "length": length,
                "expects": expects,
                "opens_payload": opens_payload,
                "replies": 0,
                "reply_codes": [],
                "state": "awaiting-first-reply",
            }
            return {"request_seq": seq, "predecessor_request_seq": predecessor}

    def payload_ended(self, seq: int, terminated: bool) -> None:
        """The lone dot is written. The request is not finished with.

        The request stays current until its CLOSING reply is observed. For a
        SPEAK that reply is 200 OK SPEAKING and it can arrive long after the
        dot; a request retired here would let the next block's reply be read as
        this one's answer, which is exactly the theft the name exists to stop.
        """
        with self.lock:
            request = self.requests.get(seq)
            if request is None:
                return
            request["payload_terminated"] = terminated
            request["state"] = "awaiting-closing-reply"

    def request_state(self, seq: int) -> str | None:
        """The state of a request at the moment its own close record is written."""
        with self.lock:
            request = self.requests.get(seq)
            return None if request is None else request["state"]

    def attribute_event(self, classified: dict, offset: int, length: int, pcm_length: int | None,
                        monotonic_ns: int, wall_ns: int, truncated: bool) -> dict:
        """Who owns one message from the module, decided now and nowhere else.

        The result is merged into the event record. Its ``before`` and ``after``
        lists are the records that bracket the message, so a transaction's two
        ends sit in the index next to the events they bracket and nowhere else.
        """
        # Every owner and every reply field is present on every event, null
        # where it does not apply. A null is an answer that says "this message
        # is not that kind of thing", not a gap the reader has to guess at.
        decision: dict = {
            "event_shape": classified["shape"],
            "mark_name": None,
            "owner_request_seq": None,
            "owner_txn_id": None,
            "owner_submission_request_seq": None,
            # The transaction this acceptance replaced, on that acceptance's
            # own record, and null on every other message.
            "superseded_txn_id": None,
            "reply_code": None,
            "reply_role": None,
            "reply_disposition": None,
            "before": [],
            "after": [],
        }
        if classified["mark_name"] is not None:
            decision["mark_name"] = text_of(classified["mark_name"])
        if truncated:
            # A message with no terminating newline is bytes, not a message.
            # It names no owner and advances nothing: a half-written reply is
            # not an answer, and a half-written event never counts as PCM.
            decision["ownership_note"] = (
                "this message never reached a terminator, so it is indexed as the bytes it is and is "
                "credited to no request and no transaction")
            return decision
        with self.lock:
            if classified["shape"] == "handshake":
                self._own_reply(classified, offset, length, monotonic_ns, wall_ns, decision)
            else:
                self._own_speech_event(classified, offset, length, pcm_length, monotonic_ns, wall_ns, decision)
        return decision

    def _own_reply(self, classified: dict, offset: int, length: int, monotonic_ns: int, wall_ns: int,
                   decision: dict) -> None:
        """A handshake reply belongs to the request that is open right now."""
        seq = self.current_request_seq
        if seq is None:
            decision["ownership_note"] = (
                "the module answered while no request was open, so this reply names no request and no "
                "request may be credited with it")
            return
        request = self.requests[seq]
        answered = request["replies"]
        request["replies"] = answered + 1
        request["reply_codes"].append(classified["code"])
        code = classified["code"]
        decision["owner_request_seq"] = seq
        decision["reply_code"] = code
        decision["reply_disposition"] = "accept" if 200 <= code < 300 else "refuse"
        expects = request["expects"]
        if expects == "unknown":
            # How many replies this command takes is not something this program
            # knows. LIST VOICES answers with one message per voice and then a
            # last one, so a second reply here is a fact, not a fault, and it is
            # never reported as one.
            decision["reply_role"] = "single" if answered == 0 else "more"
            return
        if expects == "reply":
            if answered:
                decision["reply_role"] = "extra"
                decision["violation"] = (
                    f"request {seq} ({request['verb']}) takes one reply and was already answered by "
                    f"{request['reply_codes']}, so this reply owns nothing")
                return
            decision["reply_role"] = "single"
        else:
            decision["reply_role"] = "ready" if answered == 0 else "closing"
        if decision["reply_disposition"] == "refuse":
            self._close_request(seq, "refused", classified, offset, length)
            return
        if decision["reply_role"] == "ready":
            request["state"] = "awaiting-payload"
            return
        self._close_request(seq, "accepted", classified, offset, length)
        if decision["reply_role"] == "closing":
            self._open_transaction(request, classified, offset, length, monotonic_ns, wall_ns, decision)

    def _close_request(self, seq: int, state: str, classified: dict, offset: int, length: int) -> None:
        """The exchange this request opened is over. The slot is free again."""
        request = self.requests[seq]
        request["state"] = state
        request["closed_by"] = classified["first_line"]
        request["closed_by_code"] = classified["code"]
        request["closed_by_offset"] = offset
        request["closed_by_length"] = length
        if self.current_request_seq == seq:
            self.current_request_seq = None

    def _open_transaction(self, request: dict, classified: dict, offset: int, length: int,
                          monotonic_ns: int, wall_ns: int, decision: dict) -> None:
        """The reply that ACCEPTS a submission opens the transaction it speaks.

        All four submission verbs open one. cmd_speak accepts SPEAK, SOUND_ICON,
        CHAR and KEY with the same 200 OK SPEAKING and hands each to
        module_speak_sync as its own SPDMessageType, so a CHAR is an utterance
        the module speaks and owns a transaction exactly as a SPEAK does. A
        transaction whose origin was never observed - a 701 BEGIN with no
        accepted submission in front of it - is reported and left without an
        owner, because it has no request it could honestly name.

        A submission accepted while a previous transaction is still open ends
        that previous transaction and opens a fresh one for the new submission.
        The module's own acceptance reply is the causal edge: it is the first
        byte written after this request's payload, and everything the module
        says after it belongs to the submission it just accepted. So the
        earlier transaction is closed with close_reason
        "superseded-by-accepted-submission" and unclosed set - the module never
        sent the 702, 703 or 704 that would have closed it, and none is invented
        - and the 701 BEGIN and audio that follow are owned by the new request.
        The earlier transaction keeps the events and audio it really owned and
        is given none of the new ones, so no submission is ever credited with
        an utterance it did not cause.
        """
        if request["token_bytes"] not in SUBMISSION_VERBS:
            return
        if classified["code"] != SPEAKING_CODE:
            decision["ownership_note"] = (
                f"request {request['request_seq']} closed with {classified['code']}, which is not "
                f"{SPEAKING_CODE}, so it opens no transaction")
            return
        supersedes = self.open_txn_id
        if supersedes is not None:
            # Closed HERE, before the new acceptance's own record is written,
            # so the index shows one transaction ending exactly where the next
            # one begins and the two never overlap.
            previous = self.transactions.pop(supersedes)
            self.open_txn_id = None
            decision["after"].append(self._close_record(
                previous, None, offset, None, monotonic_ns, wall_ns, unclosed=True,
                close_reason="superseded-by-accepted-submission",
                note=(f"no 702 END, 703 STOP or 704 PAUSE for transaction {supersedes} was seen before "
                      f"request {request['request_seq']} ({request['verb']}) was accepted at offset "
                      f"{offset}, so this transaction is reported unclosed at the acceptance that replaced "
                      "it and keeps only the events and audio it really owned")))
        txn_id = self.next_txn_id
        self.next_txn_id = txn_id + 1
        self.open_txn_id = txn_id
        self.transactions[txn_id] = {
            "txn_id": txn_id,
            "request_seq": request["request_seq"],
            "verb": request["verb"],
            "message_type": SUBMISSION_MESSAGE_TYPES[request["token_bytes"]],
            "supersedes_txn_id": supersedes,
            "opened_by": classified["first_line"],
            "opened_by_offset": offset,
            "opened_by_length": length,
            "opened_by_code": classified["code"],
            "began": False,
            "audio_chunks": 0,
            "pcm_bytes": 0,
            "mark_names": [],
            "event_offsets": [],
        }
        # The open record is written BEFORE the acceptance reply's own record,
        # and the superseded transaction's close record sits in ``after``, so
        # the index reads: this one ends, then the new one begins, then the
        # acceptance that caused both.
        decision["before"].append({
            "kind": "transaction_open",
            "txn_id": txn_id,
            "request_seq": request["request_seq"],
            "verb": request["verb"],
            "message_type": SUBMISSION_MESSAGE_TYPES[request["token_bytes"]],
            "supersedes_txn_id": supersedes,
            "opened_by": classified["first_line"],
            "opened_by_offset": offset,
            "opened_by_length": length,
            "opened_by_code": classified["code"],
            "opened_monotonic_ns": monotonic_ns,
            "opened_wall_ns": wall_ns,
        })
        decision["superseded_txn_id"] = supersedes

    def _own_speech_event(self, classified: dict, offset: int, length: int, pcm_length: int | None,
                          monotonic_ns: int, wall_ns: int, decision: dict) -> None:
        """A 7xx event belongs to the transaction that is open right now.

        One owner per event, and that owner is the transaction the module's own
        acceptance reply opened. A 701 BEGIN with no accepted submission in
        front of it names no owner and is refused; a second begin inside a
        transaction that already began is a violation on its own, and no
        bracket is merged into the first. An event arriving while no
        transaction is open - including audio that follows a transaction whose
        own end was never observed - names no owner either, and is never handed
        to a neighbouring transaction that happened to be open earlier.
        """
        shape = classified["shape"]
        if shape == "other":
            decision["ownership_note"] = (
                "this message is neither a handshake reply nor a 7xx speech event, so it names no "
                "request and no transaction and is attached to neither, even though a transaction "
                "was open when it arrived")
            return
        txn_id = self.open_txn_id
        if txn_id is None:
            decision["ownership_note"] = (
                f"a {shape} arrived with no transaction open, so it names no owner and no request may be "
                "credited with it")
            return
        txn = self.transactions[txn_id]
        if shape != "begin" and not txn["began"] and txn["supersedes_txn_id"] is not None:
            # This transaction replaced another one and has not sent its own
            # BEGIN yet, so an event here belongs to the utterance it replaced
            # or to this one and the bytes do not say which. It is credited to
            # neither rather than guessed onto whichever slot is open.
            decision["ownership_note"] = (
                f"a {shape} arrived after transaction {txn_id} replaced transaction "
                f"{txn['supersedes_txn_id']} and before transaction {txn_id} sent its own 701 BEGIN, so it "
                "belongs to one of the two or to neither and is credited to no request and no transaction")
            return
        decision["owner_txn_id"] = txn_id
        decision["owner_submission_request_seq"] = txn["request_seq"]
        txn["event_offsets"].append(offset)
        if pcm_length is not None:
            txn["audio_chunks"] += 1
            txn["pcm_bytes"] += pcm_length
        if classified["mark_name"] is not None:
            txn["mark_names"].append(text_of(classified["mark_name"]))
        if shape == "begin":
            if txn["began"]:
                decision["violation"] = (
                    f"transaction {txn_id} already began, so this second begin is reported on its own and "
                    "no bracket is merged into the first")
            txn["began"] = True
            return
        if shape not in CLOSING_SHAPES:
            return
        self.open_txn_id = None
        del self.transactions[txn_id]
        decision["after"].append(self._close_record(
            txn, classified, offset, length, monotonic_ns, wall_ns, unclosed=False,
            close_reason="closing-event", note=None))

    def finish_transaction(self, note: str, monotonic_ns: int, wall_ns: int) -> list:
        """The module's output ended. An open transaction is reported unclosed.

        It is not closed for the module's convenience. The closing event was
        never seen, so the record says so in ``unclosed`` and names what was
        still inside, and a reader has to refuse it rather than credit an end
        the wire never carried.
        """
        with self.lock:
            txn_id = self.open_txn_id
            if txn_id is None:
                return []
            txn = self.transactions.pop(txn_id)
            self.open_txn_id = None
            return [self._close_record(txn, None, None, None, monotonic_ns, wall_ns, unclosed=True,
                                       close_reason="module-output-ended", note=note)]

    def _close_record(self, txn: dict, classified: dict | None, offset: int | None, length: int | None,
                      monotonic_ns: int, wall_ns: int, unclosed: bool, close_reason: str,
                      note: str | None) -> dict:
        """The closing side of one transaction, from what the module really did."""
        record = {
            "kind": "transaction_close",
            "txn_id": txn["txn_id"],
            "request_seq": txn["request_seq"],
            "verb": txn["verb"],
            # The SPDMessageType cmd_speak hands module_speak_sync for this
            # verb, and the transaction this one replaced when a new submission
            # was accepted while it was still open. Null when there was none.
            "message_type": txn["message_type"],
            "supersedes_txn_id": txn["supersedes_txn_id"],
            "opened_by": txn["opened_by"],
            "opened_by_offset": txn["opened_by_offset"],
            "opened_by_length": txn["opened_by_length"],
            "opened_by_code": txn["opened_by_code"],
            # Why this transaction ended, read off the wire and nothing else:
            # closing-event names the 702, 703 or 704 that really closed it, and
            # the other two say that no such event was ever seen.
            "close_reason": close_reason,
            "closed_by": None if classified is None else classified["first_line"],
            "closed_by_offset": offset,
            "closed_by_length": length,
            "closed_by_code": None if classified is None else classified["code"],
            "unclosed": unclosed,
            # Counted on the real decoded bytes of the real chunks, never on a
            # header's claim and never on a total message length.
            "audio_chunks": txn["audio_chunks"],
            "pcm_bytes": txn["pcm_bytes"],
            "mark_names": list(txn["mark_names"]),
            # Every byte offset in the from-module stream this transaction owns,
            # in the order the events arrived.
            "event_offsets": list(txn["event_offsets"]),
            "closed_monotonic_ns": monotonic_ns,
            "closed_wall_ns": wall_ns,
        }
        if note is not None:
            record["ownership_note"] = note
        return record


# ── the native carrier, read side ────────────────────────────────────────────


class MetadataIndex:
    """The daemon's own write records, read once and joined to this run's bytes.

    The daemon publishes one row per daemon->module write on a file of its own.
    Each row names the pipe it wrote into, the daemon's birth, the module
    proxy's birth, this boot, the stream epoch, the message the daemon was
    writing, and the byte extent the kernel ACTUALLY took. No row carries a
    timestamp, an ordinal, a line number, a log adjacency or any text, so none
    of them can drift with the pace of the run or with a count of anything.

    WHAT MAKES A ROW ABOUT THIS RUN. os.fstat(0) on this process describes the
    very pipe the daemon wrote into: module.c gives the child pipe_in[0] as
    descriptor 0 and keeps pipe_in[1], and both ends of one pipe are one inode.
    The daemon's birth is this process's parent and the module proxy's birth is
    this process. Those three kernel facts plus the boot id are what make a row
    about THIS pipe and THIS daemon, and not an inode number the kernel has
    since handed to somebody else or a pid that now belongs to a stranger.

    WHY IT NEVER DELAYS A BYTE, AND WHY IT SAYS NOTHING UNTIL THE END. The row
    is produced by the daemon after its write returns, so it legitimately trails
    the bytes, and nothing here waits for it: the pump forwards bytes first and
    takes rows in afterwards. Every verdict is written exactly once, when the
    sidecar is closed at the end of the run, and not before. A row not yet
    appended and a row never to be appended look identical from inside a live
    run, so a verdict written earlier could be a guess that a later row
    contradicts - and a guess in a file cannot be taken back. Waiting costs
    nothing that anything can observe: the binding index is read after this
    process exits, and until then not one record in it exists to contradict.

    WHY ONE SPAN IS MANY ROWS. One utterance is several writes on the wire, so
    a submission's byte span is covered by the UNION of contiguous rows and by
    no single row. Rows naming the same message and the same client scope merge
    into one covered run, which keeps the join bounded by the number of
    messages rather than by the number of writes.

    EVERY REFUSAL HERE IS A REFUSAL. A row this program cannot read, a hole in
    the offsets, a second epoch inside one pipe and one birth, a disagreeing
    message id, a disagreeing client scope, a command only part of which moved,
    a sidecar that never appeared, a sidecar whose size could not be read, and a
    sidecar this program never read to its end: each ends as a named unknown
    carrying no message id at all. Nothing is picked, nothing is counted,
    nothing is timed and nothing a neighbour said is borrowed.

    A JOURNAL THIS PROGRAM COULD NOT FINISH IS NOT A JOURNAL THAT SAID NOTHING.
    "No metadata covers this span" and "the sidecar stopped short of this span"
    are both claims about what the file held, so they may only be made about a
    file this program really read whole. An unreadable one is named as the
    failure it is, and the rows already matched stand: a refusal lands on the
    spans the journal never reached and on nothing in front of them.
    """

    def __init__(self, trace: Trace, path: str, scope: dict) -> None:
        self.trace = trace
        self.path = path
        self.scope = scope
        self.lock = threading.Lock()
        self.handle = -1
        self.opened = False
        self.file_info = None
        self.file_size = None
        self.buffer = bytearray()
        self.file_pos = 0
        self.line_start = 0
        self.torn_record_at_sidecar_byte = None
        # Rows already read and checked, waiting for this run to trace the very
        # bytes they name. Each is (offset, written, msg_id, client_id,
        # client_fd, rootable, epoch, pipe_dev, pipe_ino).
        self.pending: list = []
        # The covered runs of the matched scope, merged and sorted, each
        # [start, end, msg_id, client_id, client_fd, rootable, writes].
        self.runs: list = []
        self.starts: list = []
        self.expected_offset: int | None = None
        self.last_offset: int | None = None
        self.epoch: int | None = None
        self.pipe_dev: int | None = None
        self.pipe_ino: int | None = None
        self.faults: list = []
        self.fault_reason: str | None = None
        self.fault_offset: int | None = None
        # Where in the SIDECAR's own bytes the first fault happened. Kept apart
        # from fault_offset, which is a position in the daemon->module stream;
        # the two are never compared.
        self.sidecar_position: int | None = None
        # Extents a refused row still claimed, and which refusal claimed them.
        # Bounded, and never used to attribute anything: a contested extent can
        # only ever make a span unknown.
        self.conflicts: list = []
        self.unbound: list = []
        self.binding_seq = 0
        self.states = {"rooted": 0, "control": 0, "unknown": 0}
        self.records_read = 0
        self.records_matched = 0
        self.records_unparsed = 0
        self.excluded: dict = {}
        # Which foreign thing each dropped row claimed, and where it claimed it.
        # Bounded, and never used to attribute anything: it only names a
        # refusal for the span it landed in.
        self.excluded_spans: list = []
        self.bytes_read = 0
        self.traced = 0
        self.closed = False
        # Whether every byte of the sidecar was really read before the run
        # ended. None while it is still being read; the footer says it either way.
        self.drained: bool | None = None
        self.state_reason: str | None = None
        if not path:
            self.state_reason = "hook_off"
        elif not os.path.isabs(path):
            self.state_reason = "meta_path_not_absolute"
        elif not scope["identity_known"]:
            self.state_reason = "meta_identity_unknown"

    # ── opening: this program is a reader and nothing else ─────────────────

    def _directory_why(self) -> str | None:
        """Why the sidecar's own directory is not private to this run, or None."""
        parent = os.path.dirname(self.path) or os.sep
        try:
            info = os.stat(parent)
        except OSError as failure:
            return f"its directory {parent} cannot be read: {failure}"
        if not stat.S_ISDIR(info.st_mode):
            return f"{parent} is not a directory"
        if info.st_uid != os.getuid():
            return f"{parent} is owned by uid {info.st_uid}, not by this process ({os.getuid()})"
        leaked = stat.S_IMODE(info.st_mode) & PRIVATE_DIR_MODE
        if leaked:
            return f"{parent} is mode {stat.S_IMODE(info.st_mode):04o}, so group or other can reach it"
        return None

    def _file_why(self, info) -> str | None:
        """Why the opened sidecar is not the daemon's private file, or None.

        The mode is 0600 exactly, not merely private. The contract names 0600
        and the daemon creates the file with it, so any other mode is not the
        file this run agreed to read - including one that is stricter, which
        would mean something other than this run touched it.
        """
        if not stat.S_ISREG(info.st_mode):
            return f"it is not a regular file (mode {stat.S_IMODE(info.st_mode):04o})"
        if info.st_uid != os.getuid():
            return f"it is owned by uid {info.st_uid}, not by this process ({os.getuid()})"
        if stat.S_IMODE(info.st_mode) != PRIVATE_FILE_MODE:
            return f"it is mode {stat.S_IMODE(info.st_mode):04o}, not {PRIVATE_FILE_MODE:04o}"
        if info.st_nlink != 1:
            return f"it has {info.st_nlink} links, so another writer could be holding it open too"
        return self._directory_why()

    def _stop_state(self, reason: str, detail: str) -> None:
        """Reading is over and every later span is that one named unknown.

        THE FIRST REFUSAL IS THE ONE THAT STOPPED THE READ. A later reason is a
        fact and is kept in the list, but it never takes over the name the
        footer publishes: a second refusal is a consequence of the first, and a
        consequence that overwrites the cause reports something that did not
        stop anything as though it did.
        """
        if self.state_reason is None:
            self.state_reason = reason
            # Once the read side is refused this program can no longer say it
            # read the journal whole, whatever the last poll happened to see.
            # "drained" is a claim about the file, and a dead reader certifies
            # nothing about it.
            self.drained = False
        self.faults.append(f"{reason}: {detail}")
        if self.handle >= 0:
            try:
                os.close(self.handle)
            except OSError:
                pass
            self.handle = -1

    def try_open(self) -> bool:
        """Open the sidecar the daemon created, or say why this run has none.

        The daemon creates that file during module init, which happens AFTER
        this program was exec'd as the module, so an absent file is the normal
        first state of a run and not a fault. It is retried on the same bounded
        cadence as the two wire pumps, and only a real refusal ends the trying.

        The descriptor is read-only, non-blocking, close-on-exec and
        non-following, and the file itself is then checked for being regular,
        ours, mode 0600 and holding exactly one link. This program creates
        nothing, writes nothing, truncates nothing, chmods nothing and unlinks
        nothing here or anywhere else.
        """
        with self.lock:
            if self.opened:
                return True
            if self.state_reason is not None:
                return False
            flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | getattr(os, "O_NONBLOCK", 0)
            try:
                handle = os.open(self.path, flags)
            except FileNotFoundError:
                return False
            except OSError as failure:
                self._stop_state("meta_open_failed", str(failure))
                return False
            try:
                info = os.fstat(handle)
            except OSError as failure:
                os.close(handle)
                self._stop_state("meta_open_failed", str(failure))
                return False
            refusal = self._file_why(info)
            if refusal is not None:
                os.close(handle)
                self._stop_state("meta_file_unexpected", refusal)
                return False
            self.handle = handle
            self.file_info = info
            self.opened = True
            return True

    def _read_once(self) -> bool:
        """One bounded read. False means no new bytes yet, not the end."""
        with self.lock:
            if self.closed:
                # Nothing read after the verdicts are written can change one,
                # and counting those bytes would claim this program judged rows
                # it never looked at.
                return False
            try:
                chunk = os.read(self.handle, META_READ_SIZE)
            except OSError as failure:
                self._stop_state("meta_read_failed", str(failure))
                return False
            if not chunk:
                return False
            self.bytes_read += len(chunk)
            self._feed(chunk)
            return True

    def read_available(self) -> int:
        """Take whatever the daemon has written so far, without waiting.

        Opening is retried here and not treated as a fault, because the daemon
        creates the sidecar during module init, which is after this program was
        exec'd. The number of reads actually made is returned, so an empty tick
        is visible as a tick and never as the producer finishing.
        """
        if not self.opened and (self.state_reason is not None or not self.try_open()):
            return 0
        if self.state_reason is not None:
            return 0
        taken = 0
        while self._read_once():
            taken += 1
        self.drained = self._caught_up()
        return taken

    def pump(self, stop: threading.Event, poll_seconds: float) -> None:
        """Read the sidecar on the same bounded cadence as the two wire pumps.

        A regular file always reports ready, so select() would say nothing here
        and an empty read means "no new bytes yet", never "the producer is
        finished". The daemon is still writing, so an empty read is a tick.
        """
        while not stop.is_set():
            if self.state_reason is not None:
                return
            if self.read_available() == 0:
                stop.wait(poll_seconds)
        self.drain(poll_seconds)

    def _caught_up(self) -> bool:
        """Has every byte the daemon really wrote been read by this program?"""
        try:
            size = os.fstat(self.handle).st_size
        except OSError:
            return False
        return size <= self.bytes_read

    def drain(self, poll_seconds: float) -> None:
        """Whatever the daemon wrote last, read until the bound expires.

        The bound is spent, not tested for. Being level with the file says only
        that this program has read what the daemon had written SO FAR, and the
        daemon is still running: a row appended in the next microsecond is a
        real row about real bytes, and a reader that walked away the instant it
        caught up would refuse a complete submission for being one poll late.
        So the whole bound is spent reading, and only the bound decides.
        """
        deadline = time.monotonic() + META_DRAIN_SECONDS
        while self.opened and self.state_reason is None and time.monotonic() < deadline:
            self.drained = self._caught_up()
            if not self._read_once():
                time.sleep(poll_seconds)
        self.drained = self._caught_up()

    def finish(self) -> None:
        """The run is over: the last line is judged and every span is resolved."""
        if self.state_reason is None and not self.closed and not self.opened:
            # The daemon creates this file during module init, which happens
            # after this program was exec'd as the module, so its very first
            # appearance can legitimately be this late. Opening is not waiting:
            # the file is either there or it is not, and either answer is final.
            self.try_open()
        if self.opened and self.state_reason is None and not self.closed:
            # Take whatever arrived in the last moment, without waiting for
            # anything: the bound was already spent once, above, and a second
            # grace period would be a second way to guess.
            self.read_available()
        with self.lock:
            if self.closed:
                return
            self.closed = True
            if self.opened and self.handle >= 0:
                unreadable = None
                try:
                    self.file_size = os.fstat(self.handle).st_size
                except OSError as failure:
                    unreadable = str(failure)
                self.drained = self.file_size is not None and self.file_size <= self.bytes_read
                # Whatever the drain could not take is taken now, against the
                # final count of bytes this run traced, so "the sidecar never
                # said" is a fact about every row rather than about a moment.
                self._consume()
                self._judge_tail()
                # A JOURNAL THIS PROGRAM DID NOT READ TO ITS END IS A REFUSAL
                # AND NOT AN EMPTY ONE. Whether its size could not be read or
                # it simply grew past the last read, this program cannot say
                # the sidecar had nothing further to say about a span - and a
                # span refused as "nothing covered it" is exactly that claim.
                # The rows already read and matched are not undone by either: a
                # fault never takes back what stands in front of it, so the
                # refusal lands only on the spans this journal never reached.
                if unreadable is not None:
                    self._stop_state("meta_size_unreadable", unreadable)
                elif not self.drained and self.state_reason is None:
                    self._stop_state(
                        "meta_not_drained",
                        f"the sidecar held {self.file_size} bytes when this run ended and this program had "
                        f"read {self.bytes_read} of them, so what is left of it was never read")
            elif self.state_reason is None:
                self._stop_state(
                    "meta_never_appeared",
                    "the module was reaped and the daemon side stopped and no such file ever appeared")
            records = self._resolve_all()
        self._write(records)

    def _judge_tail(self) -> None:
        """Bytes after the last newline are a torn row, and are not a row.

        ONLY WHEN THIS PROGRAM REACHED THE END OF THE FILE. A trailing fragment
        in a journal this reader is still behind is not a row the daemon tore:
        the bytes that would finish it are simply unread, so naming a torn row
        there is a claim about the daemon's own write that nothing supports.
        Those bytes are not a row either way - nothing reads them after this -
        and the journal is refused by name for stopping short, which is the
        fact about it. A sidecar position is never published as the place a
        torn row begins unless the end of the sidecar is known.
        """
        if not self.buffer:
            return
        if not self.drained:
            self.buffer = bytearray()
            return
        self.torn_record_at_sidecar_byte = self.line_start
        self._fault("meta_torn_line", None, self.line_start)
        self.buffer = bytearray()

    # ── reading rows ────────────────────────────────────────────────────────

    def _feed(self, chunk: bytes) -> None:
        """Split one read into whole rows inside a fixed bound.

        The buffer never grows without limit: a fragment with no newline in it
        is carried whole while it can still become a row, and once it is longer
        than any row the daemon can write it is named as an oversize line
        instead of being assembled out of a growing buffer.
        """
        if self.closed:
            # The verdicts are already written; a row that arrives now cannot
            # change one of them and must not rewrite one.
            return
        # The buffer's first byte sits at file_pos MINUS what the buffer
        # already held, so that position has to be taken BEFORE this chunk is
        # added. Adding first and subtracting the grown buffer is short by
        # exactly one read, which is how a torn row's position ends up reported
        # as a place several bytes before where the torn row really starts.
        base = self.file_pos - len(self.buffer)
        self.buffer += chunk
        self.file_pos += len(chunk)
        while True:
            index = self.buffer.find(b"\n")
            if index < 0:
                break
            line = bytes(self.buffer[:index])
            self._read_line(line, base)
            base += index + 1
            del self.buffer[:index + 1]
        self.line_start = base
        if len(self.buffer) > META_LINE_MAX:
            self._fault("meta_line_oversize", None, base)
            self.buffer = bytearray()
            self.line_start = self.file_pos

    def _read_line(self, line: bytes, at: int) -> None:
        """One whole row, read against this run's own kernel facts."""
        if self.closed or self.fault_reason is not None or not line.strip():
            return
        self.records_read += 1
        try:
            row = json.loads(line)
        except ValueError:
            self.records_unparsed += 1
            self._fault("meta_record_torn", None, at)
            return
        if not isinstance(row, dict):
            self.records_unparsed += 1
            self._fault("meta_type_error", None, at)
            return
        reason, accepted = self._check(row)
        if reason is not None:
            self.excluded[reason] = self.excluded.get(reason, 0) + 1
            at_offset = self._row_offset(row)
            if reason not in META_ROW_EXCLUDED:
                self._fault(reason, at_offset, at)
            elif at_offset is not None and len(self.excluded_spans) < META_MAX_EXCLUDED:
                self.excluded_spans.append((at_offset, reason))
            return
        if len(self.pending) >= META_MAX_PENDING:
            self._fault("meta_pending_overflow", self._row_offset(row))
            return
        self.pending.append(accepted)

    @staticmethod
    def _row_offset(row: dict) -> int | None:
        """The offset a row claims, when it claims one this reader can read."""
        value = row.get("offset")
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            return None
        return value

    def _check(self, row: dict) -> tuple:
        """Read one row against this run's facts: (refusal, normalised row).

        The refusal is None exactly when the row is usable and the normalised
        row is None exactly when it is not, so the two can never be mistaken
        for one another.

        The order decides only WHICH fault is named; every one of them is a
        refusal and none of them repairs the row. The daemon's own descriptor
        number is read once and never compared, because a number is private to
        a process and means nothing in another one. No id is accepted for
        looking valid: msg_id 0 is as ordinary as any other, and absence is the
        explicit null rather than a missing field.
        """
        try:
            if meta_uint(row, "ver") != META_VERSION:
                return ("meta_version_unknown", None)
            if meta_uint(row, "kind") != META_KIND:
                return ("meta_kind_unknown", None)
            pipe_dev = meta_uint(row, "pipe_dev")
            pipe_ino = meta_uint(row, "pipe_ino")
            daemon_pid = meta_uint(row, "daemon_pid")
            daemon_ticks = meta_uint(row, "daemon_start_ticks")
            proxy_pid = meta_uint(row, "module_pid")
            proxy_ticks = meta_uint(row, "module_start_ticks")
            epoch = meta_uint(row, "stream_epoch")
            meta_uint(row, "write_fd")
            offset = meta_uint(row, "offset")
            written = meta_uint(row, "written")
            requested = meta_uint(row, "requested")
            msg_id = meta_nullable_uint(row, "msg_id")
            client_id = meta_nullable_uint(row, "client_id")
            client_fd = meta_nullable_int(row, "client_fd")
            boot = meta_text_or_null(row, "boot_id")
            outcome = row.get("outcome")
            if not isinstance(outcome, str):
                raise MetaFieldError("outcome is not a string")
            # The record declares errno as a signed integer and it is read as
            # one, so an error row is never turned into a stream-wide fault by
            # a negative value that is exactly what the daemon recorded.
            error = meta_nullable_int(row, "errno")
        except MetaFieldError:
            return ("meta_type_error", None)
        if epoch < 1:
            return ("meta_type_error", None)
        if (pipe_dev, pipe_ino) != (self.scope["stdin_dev"], self.scope["stdin_ino"]):
            return ("meta_other_pipe", None)
        if (daemon_pid, daemon_ticks) != (self.scope["daemon_pid"], self.scope["daemon_start_ticks"]):
            return ("meta_other_daemon", None)
        if (proxy_pid, proxy_ticks) != (self.scope["observer_pid"], self.scope["observer_start_ticks"]):
            return ("meta_other_proxy", None)
        # The boot is a join key like any other, not a hint: every other
        # identity here demands an exact match, and a row that could not name
        # this boot cannot be shown to come from it. With identity_known
        # requiring a readable boot on this side too, an unreadable boot
        # disables attribution for the whole run rather than passing silently.
        if boot != self.scope["boot_id"]:
            return ("meta_boot_conflict", None)
        if outcome not in META_OUTCOMES:
            return ("meta_outcome_unknown", None)
        if written > requested:
            return ("meta_outcome_contradiction", None)
        # The daemon's own completeness rule, taken as it is written: every
        # requested byte is in the pipe, or none of them failed. A zero-length
        # command is complete and moves nothing, so it is a row covering no
        # byte rather than a fault - output_write_all is a while (sent < count)
        # loop, so a zero count makes no syscall at all and cannot fail.
        if (outcome == "complete") != (written == requested):
            return ("meta_outcome_contradiction", None)
        # The whole rule in one place: a whole count moved means no error, and
        # an error is always named by a real errno. An error row whose errno is
        # null, or zero, describes a failure nobody can identify - and zero is
        # not a failure, it is the absence of one. Either way the row contradicts
        # the write it claims, so the bytes it would have covered stay unknown.
        if outcome == "complete" and error is not None:
            return ("meta_outcome_contradiction", None)
        if outcome == "error" and (error is None or error == 0):
            return ("meta_outcome_contradiction", None)
        if (client_id is None) != (msg_id is None) or (client_fd is None) != (msg_id is None):
            return ("meta_scope_shape_error", None)
        return (None, (offset, written, msg_id, client_id, client_fd,
                       outcome == "complete", epoch, pipe_dev, pipe_ino))

    def _fault(self, reason: str, stream_offset: int | None = None,
               sidecar_position: int | None = None) -> None:
        """Stop believing this sidecar from this stream offset, and say why.

        The two coordinates are not the same thing and are never mixed. A row's
        ``offset`` is a position in the daemon->module byte stream; a position
        inside this sidecar says nothing whatever about the pipe. So a fault
        that happened to the sidecar's OWN bytes - a torn row, a line too long
        to be a row, a row that will not parse - carries no stream offset, and
        is placed where coverage demonstrably stops instead: the end of the
        last extent already covered. That is a fact about the pipe, not an
        invention, and it is the only honest place to put such a fault.
        """
        if self.fault_reason is not None:
            return
        self.fault_reason = reason
        if stream_offset is None:
            stream_offset = self.expected_offset if self.expected_offset is not None else 0
        self.fault_offset = stream_offset
        self.sidecar_position = sidecar_position
        where = (f"sidecar offset {sidecar_position}" if sidecar_position is not None
                 else "the sidecar's own bytes")
        self.faults.append(f"{reason} at {where}; stream coverage stops at offset {stream_offset}")

    # ── joining rows to the bytes of this run ───────────────────────────────

    def advance(self, traced: int) -> None:
        """This run has put N bytes into stdin.bin. Take in the rows naming them.

        A row is taken only once this run has itself traced the bytes it
        describes, because until then this program cannot say those bytes went
        anywhere. Rows are taken in file order and never skipped, so their
        offsets can be checked for continuity as they arrive. Nothing is decided
        here: a verdict written now could be contradicted by a row the daemon
        has not appended yet, and a verdict in a file cannot be taken back.
        """
        if self.state_reason is not None:
            return
        with self.lock:
            self.traced = max(self.traced, traced)
            self._consume()

    def _consume(self) -> None:
        """Take in every row whose bytes this run has really traced.

        Rows are taken in file order and never skipped, so their offsets can be
        checked for continuity as they arrive. A row naming bytes this run has
        not traced yet stays, because until then this program cannot say those
        bytes went anywhere.

        A FAULT DOES NOT UNDO THE ROWS IN FRONT OF IT. The daemon appends one
        row per write, so one poll of it hands this program several rows and a
        refusal in a single read, and a row already read and checked describes
        bytes the daemon really covered. Dropping those would let one malformed
        row erase every write before it, which says nothing true about those
        bytes. So a row lying wholly below the fault is still taken in, and a
        row at or past the fault never is.
        """
        if self.state_reason is not None:
            return
        keep = []
        for row in self.pending:
            end = row[0] + row[1]
            limit = self.fault_offset if self.fault_reason is not None else None
            past_fault = limit is not None and (row[0] >= limit or end > limit)
            if past_fault or end > self.traced:
                keep.append(row)
                continue
            self._accept(row)
        self.pending = keep

    def _accept(self, row: tuple) -> None:
        """One checked row, put into the covered runs or ending the stream.

        A row this program refuses to believe still CLAIMS bytes. Dropping the
        row and keeping only the fault would leave its extent looking covered
        by whatever was accepted before it, and a span could then be credited
        from ground two writers disagree about. So the claimed extent is kept
        beside the fault, bounded like everything else here, and any span it
        touches is refused before any owner can be believed.
        """
        offset, written, msg_id, client_id, client_fd, rootable, epoch, pipe_dev, pipe_ino = row
        if self.epoch is None:
            self.epoch = epoch
            self.pipe_dev = pipe_dev
            self.pipe_ino = pipe_ino
        elif epoch != self.epoch:
            # One proxy birth and one pipe belong to one stream epoch. A second
            # epoch here means something else is writing into the same pipe,
            # and this program never picks which of the two is the real writer.
            self._claim_conflict("meta_epoch_conflict", offset, written)
            return
        if self.expected_offset is not None and offset != self.expected_offset:
            if offset > self.expected_offset:
                # A hole names bytes nobody claims. It steals nothing from what
                # came before it, so the fault alone is the whole fact.
                self._fault("meta_gap", offset)
            elif self.last_offset is not None and offset < self.last_offset:
                self._claim_conflict("meta_offset_regression", offset, written)
            else:
                self._claim_conflict("meta_overlap", offset, written)
            return
        self.last_offset = offset
        self.expected_offset = offset + written
        self.records_matched += 1
        self._add_run(offset, offset + written, msg_id, client_id, client_fd, rootable)

    def _claim_conflict(self, reason: str, offset: int, written: int) -> None:
        """A row claiming bytes this stream already gave to somebody else.

        The extent is remembered, not covered: these bytes are contested, so no
        span touching any of them can be bound to a message however well the
        rows around it agree.
        """
        self._fault(reason, offset)
        if len(self.conflicts) < META_MAX_CONFLICTS:
            self.conflicts.append((offset, offset + written, reason))

    def _contested(self, span: dict) -> str | None:
        """The one refusal a contested extent inside this span earns, or None.

        Two different conflicts landing in one span are not settled by picking
        one of them. Contested is contested, and contested is not attributable.
        """
        blame = {reason for start, end, reason in self.conflicts
                 if start < span["end"] and end > span["offset"]}
        return blame.pop() if len(blame) == 1 else None

    def _add_run(self, start: int, end: int, msg_id, client_id, client_fd, rootable) -> None:
        """One covered extent, merged with the run before it when it is the same
        message and the same client scope, so a whole utterance stays one run.

        Rows naming different messages are kept apart on purpose: a span that
        straddles two of them has to be refused, and that refusal needs both of
        them to still be there.
        """
        if start >= end:
            return
        if self.runs:
            last = self.runs[-1]
            if last[1] == start and (last[2], last[3], last[4], last[5]) == (msg_id, client_id, client_fd,
                                                                                rootable):
                last[1] = end
                last[6] += 1
                return
        if len(self.runs) >= META_MAX_RUNS:
            self._fault("meta_coverage_overflow", start)
            return
        self.runs.append([start, end, msg_id, client_id, client_fd, rootable, 1])
        self.starts.append(start)

    def _cover(self, start: int, end: int) -> list:
        """The runs whose UNION covers [start, end), or nothing at all.

        No single run has to hold the whole span: one utterance is several
        writes on the wire, so requiring one row to contain the span would
        refuse every real submission. Containment of the union is the test, and
        a hole anywhere inside the span returns no owners at all - never the
        runs that happen to sit next to it.
        """
        runs = self.runs
        if not runs:
            return []
        first = None
        probe = bisect.bisect_left(self.starts, end) - 1
        while probe >= 0 and runs[probe][1] > start:
            first = probe
            probe -= 1
        if first is None:
            return []
        owners = []
        cursor = start
        index = first
        while index < len(runs) and runs[index][0] < end:
            run = runs[index]
            if run[0] > cursor:
                return []
            owners.append(run)
            cursor = max(cursor, run[1])
            if cursor >= end:
                break
            index += 1
        return owners if cursor >= end else []

    # ── binding one closed span to the message that wrote it ────────────────

    def bind_span(self, span_kind: str, request_seq, verb: str, offset: int, length: int) -> None:
        """One closed daemon->module span, and the id of its own bytes.

        Registered here and decided when the sidecar is closed, and never
        waited for: the bytes go to the module on the next line of the pump
        either way. Two refusals are final the moment they are known, because
        neither can ever change: a reader that has already refused this file,
        and a run holding more spans than its bound allows. Everything else
        waits, so that no span is ever decided by a moment's silence.
        """
        with self.lock:
            self.binding_seq += 1
            span = {
                "binding_seq": self.binding_seq,
                "span_kind": span_kind,
                "request_seq": request_seq,
                "verb": verb,
                "offset": offset,
                "end": offset + length,
            }
            if self.state_reason is not None:
                records = [self._binding(span, self.state_reason, None)]
            elif len(self.unbound) >= META_MAX_BINDINGS:
                records = [self._binding(span, "binding_overflow", None)]
            else:
                self.unbound.append(span)
                records = []
        self._write(records)

    def _resolve_all(self) -> list:
        """Decide every span, now that the sidecar is closed and read out.

        There is exactly one moment at which this program says anything about a
        span, and it is the end of the sidecar. A row the daemon has not
        appended yet and a row it will never append are indistinguishable from
        inside a live run, so a verdict written earlier could be a guess that
        a later row contradicts - and a guess written to a file cannot be taken
        back. Deciding once, at the end, means every row is in hand, every
        refusal is about the whole file, and no published id can be retracted.
        """
        records = [self._binding(span, *self._assess(span)) for span in self.unbound]
        self.unbound = []
        return records

    def _behind_a_fault(self, span: dict) -> bool:
        """Does a fault sit inside this span, or after it and inside its end?"""
        return self.fault_reason is not None and span["end"] > self.fault_offset

    def _partial_inside(self, span: dict) -> bool:
        """Did a write that only partly moved land inside this span?"""
        probe = bisect.bisect_left(self.starts, span["end"]) - 1
        while probe >= 0 and self.runs[probe][1] > span["offset"]:
            if not self.runs[probe][5]:
                return True
            probe -= 1
        return False

    @staticmethod
    def _disagreement(owners: list) -> str | None:
        """The one fault that keeps a covered span from being bound, or None.

        A partial write is named first because it is about the bytes themselves.
        After that a disagreement is a disagreement about who wrote them, and
        the client scope has to agree before a neighbour's id can be trusted as
        anything but a guess. None of them picks: each one is a refusal.
        """
        if not owners:
            return None
        if not all(owner[5] for owner in owners):
            return "partial_write_in_span"
        if len({owner[2] for owner in owners}) != 1:
            return "msg_id_conflict"
        if len({(owner[3], owner[4]) for owner in owners}) != 1:
            return "scope_conflict"
        return None

    def _assess(self, span: dict) -> tuple:
        """The span's real message id, or the one named unknown that replaced it.

        Called once, on the closed sidecar, so "nothing covered this" is a fact
        about the whole file and never a moment's silence. The refusals are
        ordered by how specific they are about THIS span: ground two rows
        disagree about, then what physically happened to its own bytes, then the
        fault that stopped the stream, then the foreign row that claimed them,
        and only then the bare fact that the sidecar stopped short.
        """
        # A refused row still claimed these bytes, so no owner can be believed
        # here however well the rows around it agree. This comes FIRST because
        # every other branch would otherwise hand a span the message id of the
        # run that happened to be accepted before the contradiction.
        contested = self._contested(span)
        if contested is not None:
            return (contested, None)
        owners = self._cover(span["offset"], span["end"])
        reason = self._disagreement(owners)
        if reason is not None:
            return (reason, owners)
        if owners:
            return (None, owners)
        # A command that only part of which moved leaves a hole exactly where
        # the rest of it should be. That hole is the partial write, and it is
        # the most specific thing known about these bytes.
        if self._partial_inside(span):
            return ("partial_write_in_span", None)
        if self._behind_a_fault(span):
            return (self.fault_reason, None)
        # A row that named a different physical thing is still evidence about
        # these bytes: if one of them landed inside this span, that is why
        # nothing covered it. Two different refusals landing here are not
        # settled by picking one - the span is simply not covered.
        blame = {reason for at, reason in self.excluded_spans
                 if span["offset"] <= at < span["end"]}
        if len(blame) == 1:
            return (blame.pop(), None)
        if self.state_reason is not None:
            return (self.state_reason, None)
        # The sidecar stopped before this span was covered whole, and something
        # had already named its first byte: it began and never finished.
        if self.expected_offset is not None and self.expected_offset > span["offset"]:
            return ("metadata_incomplete", None)
        return ("no_metadata_covers_span", None)

    def close(self) -> None:
        """The read side is over. Only this program's own descriptor goes."""
        if self.handle >= 0:
            try:
                os.close(self.handle)
            except OSError:
                pass
            self.handle = -1

    def _binding(self, span: dict, reason: str | None, owners) -> dict:
        """One binding row: the span, its own bytes, and what they turned out
        to belong to.

        Every key is always present. A null msg_id is either the explicit null
        the daemon wrote for a control command or a refusal, and the state and
        the reason are what tell those two apart: "control" with no reason is a
        correct answer, "unknown" with a reason is not.
        """
        if reason is None:
            msg_id = owners[0][2]
            state = "rooted" if msg_id is not None else "control"
            client_id = owners[0][3]
            client_fd = owners[0][4]
            union = [[owner[0], owner[1]] for owner in owners]
            writes = sum(owner[6] for owner in owners)
        else:
            state = "unknown"
            msg_id = None
            client_id = None
            client_fd = None
            union = []
            writes = 0
        self.states[state] += 1
        return {
            "kind": "native_binding",
            "binding_seq": span["binding_seq"],
            "stream": "to_module",
            "span_kind": span["span_kind"],
            "request_seq": span["request_seq"],
            "verb": span["verb"],
            "offset": span["offset"],
            "length": span["end"] - span["offset"],
            "end_offset": span["end"],
            "native_state": state,
            "native_msg_id": msg_id,
            "native_client_id": client_id,
            "native_client_fd": client_fd,
            "native_reason": reason,
            "native_covering_writes": writes,
            "native_covering_union": union,
            "native_pipe_dev": self.pipe_dev,
            "native_pipe_ino": self.pipe_ino,
            "native_stream_epoch": self.epoch,
        }

    def _write(self, records: list) -> None:
        """Binding rows leave here, out of the lock, one line each."""
        for record in records:
            self.trace.binding(record)

    def summary(self) -> dict:
        """What this run did and did not learn from the sidecar, for the footer."""
        with self.lock:
            covered = sum(run[1] - run[0] for run in self.runs)
            return {
                "enabled": bool(self.path),
                "environment": ENV_META,
                "path": self.path,
                "opened": self.opened,
                "ownership": "read-only: opened O_RDONLY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW, and never "
                             "created, written, truncated, chmoded or unlinked by this program",
                "file_dev": None if self.file_info is None else self.file_info.st_dev,
                "file_ino": None if self.file_info is None else self.file_info.st_ino,
                "file_mode": None if self.file_info is None
                else f"{stat.S_IMODE(self.file_info.st_mode):04o}",
                "file_nlink": None if self.file_info is None else self.file_info.st_nlink,
                "file_uid": None if self.file_info is None else self.file_info.st_uid,
                "records_read": self.records_read,
                "records_unparsed": self.records_unparsed,
                "records_matched": self.records_matched,
                "records_excluded": dict(sorted(self.excluded.items())),
                "bytes_read": self.bytes_read,
                "final_file_size": self.file_size,
                "drained": self.drained,
                "torn_record_at_sidecar_byte": self.torn_record_at_sidecar_byte,
                "coverage": {
                    "runs": len(self.runs),
                    "covered_bytes": covered,
                    "stopped_at_stream_byte": self.fault_offset,
                    "fault_at_sidecar_byte": self.sidecar_position,
                    "coordinates": "stopped_at_stream_byte and every binding offset are positions in the "
                        "daemon->module byte stream; fault_at_sidecar_byte and torn_record_at_sidecar_byte "
                        "are positions in this sidecar's own bytes. The two are never compared",
                    "union_rule": "a span is covered by the UNION of contiguous rows, and every row "
                        "owning a byte of it must agree on the message id and on the client scope",
                },
                "faults": list(self.faults),
                "stopped_reason": self.state_reason if self.state_reason is not None else "end-of-run",
                "span_bindings": dict(self.states),
                "scope": {
                    "stdin_dev": self.scope["stdin_dev"],
                    "stdin_ino": self.scope["stdin_ino"],
                    "boot_id": self.scope["boot_id"],
                    "matched_pipe": {"pipe_dev": self.pipe_dev, "pipe_ino": self.pipe_ino},
                    "stream_epoch": self.epoch,
                },
            }


# ── the run ─────────────────────────────────────────────────────────────────


class Trace:
    """The two raw streams, the framing index, and the process identities."""

    def __init__(self, directory: str, module_argv: list) -> None:
        self.directory = directory
        self.module_argv = module_argv
        self.to_module = open_private(os.path.join(directory, TO_MODULE_NAME), os.O_WRONLY)
        self.from_module = open_private(os.path.join(directory, FROM_MODULE_NAME), os.O_WRONLY)
        self.events = open_private(os.path.join(directory, EVENTS_NAME), os.O_WRONLY | os.O_APPEND)
        # The resolved native attribution for every closed daemon->module span.
        # It is its OWN index: nothing in events.jsonl is moved, restamped or
        # made to wait for it, and a reader that does not want it never sees it.
        self.bindings = open_private(os.path.join(directory, BINDINGS_NAME), os.O_WRONLY | os.O_APPEND)
        self.lock = threading.Lock()
        self.counts: dict = {}
        # How many bytes this run put down in each raw file. The footer's
        # stream check compares this with the file's own size, so a trace whose
        # index and bytes disagree says so instead of passing quietly.
        self.written: dict = {TO_MODULE_NAME: 0, FROM_MODULE_NAME: 0}
        # How many bytes actually reached the OTHER side. A byte that was put
        # down and then refused on its way to the module or to the daemon is
        # counted here as NOT forwarded, because forwarding is what did not
        # happen; the footer reports the two counts side by side.
        self.forwarded: dict = {TO_MODULE_NAME: 0, FROM_MODULE_NAME: 0}

    def raw(self, handle: int, data: bytes, name: str) -> None:
        """Put the bytes down before the record that describes them."""
        with self.lock:
            write_all(handle, data)
            self.written[name] += len(data)

    def record(self, entry: dict) -> None:
        """One index line, written whole or not at all."""
        entry.setdefault("monotonic_ns", time.monotonic_ns())
        entry.setdefault("wall_ns", time.time_ns())
        line = json.dumps(entry, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"
        with self.lock:
            write_all(self.events, line)
        kind = entry.get("kind", "?")
        self.counts[kind] = self.counts.get(kind, 0) + 1

    def binding(self, entry: dict) -> None:
        """One native attribution line, written whole or not at all."""
        entry.setdefault("monotonic_ns", time.monotonic_ns())
        entry.setdefault("wall_ns", time.time_ns())
        line = json.dumps(entry, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"
        with self.lock:
            write_all(self.bindings, line)

    def size_of(self, handle: int) -> int:
        return os.fstat(handle).st_size

    def close(self) -> None:
        for handle in (self.to_module, self.from_module, self.events, self.bindings):
            try:
                os.close(handle)
            except OSError:
                pass  # already closed by a failing write


class Observer:
    """Two pumps, one child, one trace, and no transformation of any kind."""

    def __init__(self, module: dict, trace_dir: str, module_argv: list) -> None:
        self.module = module
        self.trace_dir = trace_dir
        self.module_argv = module_argv
        self.trace = Trace(trace_dir, module_argv)
        self.meta_thread: threading.Thread | None = None
        # Both pumps meet here. It is the only place that decides who owns a
        # reply or an event, and it decides it from the bytes and the slots.
        self.ledger = Ledger()
        self.child_pid = 0
        self.child_pidfd: int | None = None
        self.child_live = False
        # True from the instant a pidfd names the forked child. It tells "not
        # pinned yet" apart from "reaped", so a signal that lands in either
        # window is reported as what it is instead of being sent by number.
        self.module_pinned = False
        self.child_reaped = False
        self.child_stdin = -1
        self.module_stdout = -1
        # The daemon's own two descriptors, kept by number rather than assumed.
        self.daemon_stdin = 0
        self.daemon_stdout = 1
        self.from_thread: threading.Thread | None = None
        self.to_thread: threading.Thread | None = None
        self.gate_write = -1
        self.exec_notice_read = -1
        self.exec_notice_write = -1
        self.module_output_eof = False
        self.stop = threading.Event()
        # THE SIGNAL THIS PROGRAM DELIVERED TO THE MODULE, and nothing else. It
        # is set only by an actual `pidfd_send_signal` that returned without an
        # error. It used to be set the instant a signal was RECEIVED, which let a
        # footer claim a forwarding that had demonstrably not happened.
        self.forwarded_signal = 0
        # Every signal this program received, and every one it TRIED to pass on.
        # The intent is recorded whatever the delivery did, because "I meant to"
        # is a fact about this process and "it arrived" is a fact about the
        # module. Neither is a claim that anything was delivered.
        self.received_signals: list = []
        self.forward_intent_signals: list = []
        self.delivered_signals: list = []
        # ONE TYPED RECORD PER FORWARDING ATTEMPT. Three different things can
        # happen on that one path and only one of them is a fault: it went
        # through, the module was already gone so the kernel refused a signal to
        # a task that no longer existed, or the delivery failed for some other
        # reason. A free sentence cannot tell those apart; these can.
        self.signal_outcomes: list = []
        # A signal that arrived before the module's pidfd existed. It is held
        # and delivered later through the descriptor, never through a number.
        self.held_signal: int | None = None
        # The mask this process started with, restored in the child before its
        # exec so the genuine module never inherits this program's blocked set.
        self.inherited_mask: set = set()
        self.module_exit_code = 0
        self.module_exit_signal = 0
        # What the kernel itself said about the exec: the child wrote one byte
        # on the exec-notice pipe immediately before calling execv, so an
        # absence is an observation rather than an assumption.
        self.module_exec_reached = False
        self.pump_note: str | None = None
        self.signal_note: str | None = None
        self.startup_failure: str | None = None
        # The kernel facts that make one daemon row about THIS pipe and THIS
        # daemon, read once here: before anything is executed, and before the
        # daemon has put a byte in the pipe, so no row is ever matched against a
        # value that was read later and might already have moved.
        self.observer_birth = describe_process(os.getpid())
        self.parent_birth = describe_process(os.getppid())
        stdin = os.fstat(self.daemon_stdin)
        self.boot_id, self.boot_note = read_boot_id()
        self.meta_scope = {
            # The very pipe this process reads as descriptor 0, which is the
            # pipe the daemon writes into: one pipe, one inode, both ends.
            "stdin_dev": stdin.st_dev,
            "stdin_ino": stdin.st_ino,
            # The module proxy is this process, and the daemon is its parent.
            "observer_pid": os.getpid(),
            "observer_start_ticks": self.observer_birth.get("start_ticks"),
            "daemon_pid": os.getppid(),
            "daemon_start_ticks": self.parent_birth.get("start_ticks"),
            "boot_id": self.boot_id,
            # A birth or a boot this process could not read cannot be compared,
            # and an identity that cannot be compared cannot make a foreign row
            # foreign. Attribution is therefore off for the run; speech is not.
            "identity_known": ("start_ticks" in self.observer_birth
                               and "start_ticks" in self.parent_birth
                               and self.boot_id is not None),
        }
        self.meta = MetadataIndex(self.trace, os.environ.get(ENV_META, ""), self.meta_scope)
        self.write_header()

    # ── identity, before anything is executed ───────────────────────────────

    def write_header(self) -> None:
        write_private_json(os.path.join(self.trace_dir, HEADER_NAME), {
            "kind": "header",
            "observer_pid": os.getpid(),
            "observer_session": os.getsid(0),
            "observer_pgrp": os.getpgid(0),
            "observer": self.observer_birth,
            "parent": self.parent_birth,
            # The physical pipe both this program and the daemon name, and the
            # boot this run happened on. A daemon row is only about this run if
            # it carries both of these and the births above.
            "stdin_dev": self.meta_scope["stdin_dev"],
            "stdin_ino": self.meta_scope["stdin_ino"],
            "boot_id": self.boot_id,
            "boot_id_note": self.boot_note,
            "meta": {
                "environment": ENV_META,
                "path": self.meta.path,
                "enabled": self.meta.state_reason != "hook_off",
                "directory": os.path.dirname(self.meta.path) if self.meta.path else None,
                "join": "a closed daemon->module span is bound to the message id of the native rows "
                    "whose UNION covers that span's own bytes, from rows that name this pipe, this "
                    "daemon's birth, this proxy's birth and this boot. Every owning row must agree on "
                    "the message id and on the client scope; nothing is picked, counted or timed",
                "ownership": "this program is a reader: it never creates, writes, truncates, chmods "
                    "or unlinks the sidecar, and it never waits for it before forwarding a byte",
            },
            "module": self.module,
            "module_argv": self.module_argv,
            "trace_dir": self.trace_dir,
            "file_mode": PRIVATE_FILE_MODE,
            "trace_files": {
                "to_module": TO_MODULE_NAME,
                "from_module": FROM_MODULE_NAME,
                "events": EVENTS_NAME,
                "footer": FOOTER_NAME,
                "bindings": BINDINGS_NAME,
            },
            "wire": {
                "escape": HDLC_ESCAPE,
                "invert_mask": HDLC_INVERT,
                "audio_marker": AUDIO_MARKER.decode("ascii", "replace"),
                "message_ends_when": "the line's C string length is under 4, or byte 3 is a space",
                "topology": "daemon stdin -> pipe -> module stdin (fd 0); module stdout (fd 1) -> pipe -> "
                    "daemon stdout. Both pipes are CLOEXEC, so the module is exec'd holding exactly the two "
                    "descriptors the daemon would have handed it",
                "request_order": "a submission is a two-step request: the daemon writes the verb and waits "
                    "for the module's 202 OK RECEIVING MESSAGE (src/modules/module_process.c cmd_speak, the "
                    "literal string '202 OK RECEIVING MESSAGE'), only then writes the payload and its lone "
                    "dot, and only then waits for 200 OK SPEAKING from the same function. A submission "
                    "therefore owns the reply that follows its payload terminator, not one that could "
                    "precede it",
                "index_is_written_before_handover": "every index record is stamped and written before the "
                    "bytes it describes are handed to the other side, so a record can never carry a stamp "
                    "later than the answer it caused",
                "payload_length_rule": "one 0x7d escape costs exactly one extra wire byte; the decoded length "
                    "is measured on the real bytes and compared with channels x samples x bits / 8",
                "payload_text_rule": "a submission's text is its payload lines exactly as they were "
                    "written, interior newlines included, minus the ONE newline the lone '.\\n' terminator "
                    "accounts for: cmd_speak copies strlen(line) for every line and drops a single byte "
                    "at the terminator. A leading dot comes off a line because escape_dot doubled it",
                "request_slot": "a request is a message the daemon wrote that bears a reply. It is "
                    "opened by its verb line and closed by the reply that ends the exchange, never by "
                    "the payload terminator: a SPEAK is still current after its lone '.\\n', because "
                    "its 200 OK SPEAKING is still to come. request_seq is a positive run-local integer "
                    "minted at the verb line, published in a request_open record BEFORE those bytes "
                    "are handed to the module, and repeated on the matching submission or block record",
                "request_seq_placement": "request_seq appears on request_open, on the matching "
                    "submission and block records, and on every command record whose expects is not "
                    "no-reply. A no-reply command carries request_seq null, because it opened no slot. "
                    "request_open and both transaction bracket records carry no seq field; the per-"
                    "stream seq on command, submission, block and event is unchanged and is not an "
                    "identity",
                "predecessor_request_seq": "the request that was still current when this one opened, "
                    "or null. It is a fact about the run and not a fault: a request whose replies were "
                    "never counted, such as a multi-message LIST VOICES, is still named here when the "
                    "next request takes the slot",
                "request_classes": "reply-before-payload: SPEAK, SOUND_ICON, CHAR, KEY, SET, AUDIO, "
                    "LOGLEVEL, each a verb line, then payload lines up to a lone '.\\n', then the "
                    "closing reply. reply: INIT and QUIT, one line and one reply, the module answering "
                    "299 OK LOADED SUCCESSFULLY and 210 OK QUIT. unknown: any other one-line command, "
                    "whose replies are attributed while the slot is open and are never counted against "
                    "it, because how many replies such a command takes is not known here",
                "no_reply_commands": "STOP, PAUSE and DEBUG open no request and own no reply. DEBUG is a "
                    "plain command, DEBUG ON or DEBUG OFF, not a DEBUG settings block: the module's own "
                    "entry point is module_debug(int enable, const char *file), so the flag travels "
                    "inside the one line. STOP and PAUSE steer the transaction that is already open "
                    "and change nothing about it: the audio that follows and the closing event stay "
                    "with the same owner",
                "transaction_slot": "a transaction is one utterance the module speaks. It is opened by the "
                    "reply that ACCEPTS a submission, written as a transaction_open record before that "
                    "reply's own record, and closed by a transaction_close record after the event that "
                    "ended it. txn_id is a positive run-local integer; it is not a daemon UID, because the "
                    "0.12.1 module protocol carries no UID, no client id and no message id on either "
                    "stream. All four submission verbs open one - SPEAK, SOUND_ICON, CHAR and KEY - because "
                    "cmd_speak accepts all four with the same 200 OK SPEAKING and hands each to "
                    "module_speak_sync as its own SPDMessageType, so a CHAR is an utterance and owns its "
                    "transaction exactly as a SPEAK does. Nothing else opens one, so a 701 BEGIN with no "
                    "accepted submission in front of it has no owner and is refused rather than attached "
                    "to whatever happened to be open",
                "supersede": "a submission accepted while a previous transaction is still open closes that "
                    "transaction with close_reason 'superseded-by-accepted-submission' and unclosed set, "
                    "because no 702 END, 703 STOP or 704 PAUSE for it was on the wire and none is invented, "
                    "and opens a fresh transaction for the new submission. The acceptance reply is the "
                    "causal edge, so the 701 BEGIN and the audio after it belong to the request just "
                    "accepted; the replaced transaction keeps only the events and audio it really owned. "
                    "An event arriving after that replacement but before the new transaction's own 701 "
                    "BEGIN belongs to one of the two or to neither, so it names no owner and is credited "
                    "to neither. A second 701 BEGIN with no accepted submission in front of it is still a "
                    "violation on its own",
                "ownership": "a handshake reply is owned by the request current when its bytes are "
                    "observed; a 700, 701, 702, 703, 704 or 705 is owned by the transaction open at "
                    "that instant and by nothing else. owner_request_seq, owner_txn_id and "
                    "owner_submission_request_seq are always present and are null when they do not "
                    "apply: null is an answer, not a gap to fill. A record that cannot name an owner "
                    "says so in ownership_note, and a fault that really happened is named in "
                    "violation. No stamp, no timestamp interval and no Nth row decides any of this",
                "payload_line_is_payload": "while a payload is open every line is payload, because "
                    "cmd_speak collects lines until the lone '.\\n' and reads nothing else. A payload "
                    "line that happens to spell a verb is text and is never re-read as a command",
                "index_is_written_before_handover_note": "request_open, and both transaction bracket "
                    "records, are written before the bytes they name are handed over",
                "pinned": "src/server/output.c output_read_message and output.c's 705 branch, with "
                    "src/modules/module_process.c module_readline, module_process, cmd_speak and "
                    "module_tts_output_send_server, and with spd_module_main.h module_speak_sync, "
                    "module_speak_ok, module_report_index_mark, module_debug and module_stdout_mutex",
                "pinned_source": PINNED_SOURCE,
                "pinned_source_note": "each entry names the fragment a rule was read from, the exact "
                    "lines of that fragment and the lines those lines fix in the patched C file, so the "
                    "lock placement and the errno preservation of the daemon's own sideband are answerable "
                    "from the pinned source instead of from this program's own account of it",
            },
        })

    # ── the two pumps ───────────────────────────────────────────────────────

    def pump_to_module(self, child_stdin: int) -> None:
        """Daemon to module: the bytes, then the framing, then the bytes.

        The index record is written BEFORE the bytes are handed over, so no
        record about an input can carry a stamp later than the module's own
        answer to that input. Read boundaries are this program's business:
        the framer carries a partial line, so the daemon's own fragmentation
        is preserved and nothing is dropped or seen twice.
        """
        framer = ToModuleFramer(self.trace, self.ledger)
        forwarded = 0
        try:
            while not self.stop.is_set():
                if not select.select([self.daemon_stdin], [], [], POLL_SECONDS)[0]:
                    continue
                chunk = os.read(self.daemon_stdin, READ_SIZE)
                if not chunk:
                    break
                at = time.monotonic_ns()
                wall = time.time_ns()
                self.trace.raw(self.trace.to_module, chunk, TO_MODULE_NAME)
                framer.feed(chunk, at, wall)
                write_all(child_stdin, chunk)
                # Counted only once the handover really completed.
                self.trace.forwarded[TO_MODULE_NAME] += len(chunk)
                forwarded += len(chunk)
                # The bytes are in the module now. Only then is anything about
                # them registered or read: the sideband never sits between the
                # daemon and the module, and its lock is never on this path.
                self.register_spans(framer)
                self.meta.advance(self.trace.written[TO_MODULE_NAME])
        except OSError as failure:
            traced = self.trace.written[TO_MODULE_NAME]
            self.pump_note = (
                f"the daemon side ended after {forwarded} of {traced} traced bytes had reached the module: "
                f"{failure}")
        finally:
            framer.flush()
            self.register_spans(framer)
            # The daemon has stopped writing. This close is the module's EOF,
            # and it is the only one it gets: the write end exists in this
            # process alone and dies with the pump.
            self.close_fd(child_stdin)

    def register_spans(self, framer: ToModuleFramer) -> None:
        """Hand every span the framer just closed to the native reader.

        Called after the handover and never before it. The index records those
        spans were written before the bytes moved, which is the invariant that
        matters for causality; the binding runs the other way on purpose,
        because a native id may only be claimed for bytes the module has really
        been sent.
        """
        for span_kind, request_seq, verb, offset, length in framer.take_spans():
            self.meta.bind_span(span_kind, request_seq, verb, offset, length)

    def pump_from_module(self) -> None:
        """Module to daemon: the bytes, then the framing, then the bytes."""
        framer = FromModuleFramer(self.trace, self.ledger)
        forwarded = 0
        try:
            while not self.stop.is_set():
                if not select.select([self.module_stdout], [], [], POLL_SECONDS)[0]:
                    continue
                chunk = os.read(self.module_stdout, READ_SIZE)
                if not chunk:
                    self.module_output_eof = True
                    break
                at = time.monotonic_ns()
                wall = time.time_ns()
                self.trace.raw(self.trace.from_module, chunk, FROM_MODULE_NAME)
                framer.feed(chunk, at, wall)
                write_all(self.daemon_stdout, chunk)
                # Counted only once the handover really completed, so a failed
                # handover is never reported as forwarded bytes.
                self.trace.forwarded[FROM_MODULE_NAME] += len(chunk)
                forwarded += len(chunk)
        except OSError as failure:
            traced = self.trace.written[FROM_MODULE_NAME]
            self.pump_note = (
                f"the module side ended after {forwarded} of {traced} traced bytes had reached the daemon: "
                f"{failure}")
        finally:
            # EOF, EPIPE and a truncated tail are all evidence, so the framer
            # is flushed on EVERY path out of this loop, not only the clean
            # one: the partial trailing line and the message in progress are
            # indexed here or they are lost from the index.
            try:
                framer.flush(time.monotonic_ns(), time.time_ns())
            except OSError as failure:
                self.pump_note = (
                    ((self.pump_note + "; ") if self.pump_note else "")
                    + f"the truncated tail of the module's last message could not be indexed: {failure}")

    @staticmethod
    def close_fd(fd: int) -> None:
        try:
            os.close(fd)
        except OSError:
            pass

    # ── signals and lifetime ────────────────────────────────────────────────

    def require_pidfd_api(self) -> None:
        """Refuse BEFORE anything is created, and before anything is forked.

        Both handles are checked before the first pipe exists, so an
        interpreter that cannot name a process by descriptor never gets as far
        as starting one. The kernel's own answer to ``pidfd_open`` can still
        fail after the fork, and that refusal is handled where it happens: the
        gated child has executed nothing yet.
        """
        if getattr(os, "pidfd_open", None) is None:
            raise ObserverError(
                "this interpreter has no os.pidfd_open, so a signal could only reach the module through "
                "a bare pid, which the kernel may already have reused; this observer forwards no signal "
                "by number and refuses the run instead, having created nothing")
        if getattr(signal, "pidfd_send_signal", None) is None:
            raise ObserverError(
                "this interpreter has no signal.pidfd_send_signal, so a pinned pidfd could not be used "
                "to reach the module and the only alternative would be a bare pid; this observer "
                "forwards no signal by number and refuses the run instead, having created nothing")

    def open_pidfd(self, child_pid: int) -> int:
        """A pinned descriptor for this one child, and no other way to signal it.

        A pidfd is REQUIRED, not preferred. ``os.pidfd_open`` and
        ``signal.pidfd_send_signal`` are the only two handles that name the
        module instead of naming a number, and the number is reusable the
        moment the module is reaped. So a kernel that hands out no pidfd - the
        process table is full, or a seccomp policy forbids it - is a
        precondition this observer REFUSES rather than degrades around: there
        is no numeric path in this program at all.
        """
        try:
            handle = os.pidfd_open(child_pid)
        except OSError as failure:
            raise ObserverError(
                f"this kernel gave no pidfd for the module (pid {child_pid}): {failure}; a signal could "
                "then only be aimed at a number the kernel may already have reused, so this observer "
                "refuses the run instead and stops the child it forked before it executes anything") from failure
        os.set_inheritable(handle, False)
        return handle

    @staticmethod
    def signal_name(signum: int) -> str:
        try:
            return signal.Signals(signum).name
        except ValueError:
            return f"signal {signum}"

    def note_signal(self, text: str) -> None:
        self.signal_note = text if not self.signal_note else self.signal_note + "; " + text

    def record_signal_outcome(self, signum: int, outcome: str, failure, why: str) -> None:
        self.signal_outcomes.append({
            "signal": signum,
            "signal_name": self.signal_name(signum),
            "outcome": outcome,
            "errno": failure.errno if failure is not None else None,
            "error": f"{type(failure).__name__}: {failure}" if failure is not None else None,
            "module_pid": self.child_pid,
            "module_pidfd_was_held": self.child_pidfd is not None,
            "module_believed_live_at_this_instant": self.child_live,
            "why": why,
        })

    def send_to_module(self, pidfd: int, signum: int) -> str:
        """The one delivery path: through the descriptor, never the number.

        It returns the OUTCOME and records it as a typed record whatever it is.
        The distinction that matters is between "the kernel refused" and "there
        was nothing left to signal".

        This program is the daemon's module proxy, and the daemon may retire the
        module DIRECTLY through its own pin, in the same pass that reaches this
        process. The module can therefore already be a corpse - or already
        reaped - by the instant this process tries to pass the same signal on.
        `pidfd_send_signal` answers that with ESRCH, and ESRCH there means one
        specific thing: that descriptor no longer names a running task. That is
        a fact about the module, delivered by the retained pidfd itself, so it
        is recorded as `already_ended` and NOT as a delivery fault.

        It is not blessed unconditionally. The branch is taken only on ESRCH,
        only while this process still believes the child is live, and only
        while it still holds the descriptor. The footer's `signal_delivery`
        block publishes the module's independently obtained reap status beside
        the outcome, so the claim is checkable rather than asserted.

        Every other failure keeps its note and its `refused` outcome. A delivery
        that actually happened is the only thing that sets `forwarded_signal`.
        """
        try:
            signal.pidfd_send_signal(pidfd, signum)
        except OSError as failure:
            if failure.errno == errno.ESRCH and self.child_live and self.child_pidfd is not None:
                self.record_signal_outcome(signum, "already_ended", failure,
                    "the kernel refused a signal to this retained descriptor because the module was no "
                    "longer a running task, which is what a module another owner ended first looks like "
                    "from here. This program delivered nothing and claims nothing was delivered; the "
                    "module's own reap status is published beside this in signal_delivery")
                return "already_ended"
            self.note_signal(
                f"{self.signal_name(signum)} was not delivered through the module's pidfd: {failure}")
            self.record_signal_outcome(signum, "refused", failure,
                "the delivery failed for a reason that is not the module having already ended, so this is "
                "reported as an undelivered signal")
            return "refused"
        self.forwarded_signal = signum
        self.delivered_signals.append(signum)
        self.record_signal_outcome(signum, "delivered", None,
            "delivered through the descriptor this program holds for the module, and by no other route")
        return "delivered"

    def handle_signal(self, signum, _frame) -> None:
        """Pass the signal on, to the module this program owns and only it.

        There is exactly one delivery path and it goes through the pidfd. A
        bare ``os.kill`` is never attempted, not even when a delivery fails:
        the number this program holds stops being the module's the instant the
        module is reaped, and a failed pidfd send is a fact to report rather
        than a reason to aim at something else.

        Nothing here can raise. A handler that raised would tear through
        whatever bytecode the main thread was in, which is how a moment with
        no descriptor took down this process instead of the module. A signal
        that arrives with no descriptor to use is HELD and delivered the moment
        there is one; a signal that arrives after the module is gone is
        reported as undelivered. The four forwarded signals are blocked across
        the fork and the pinning, so this covers the window between installing
        these handlers and blocking them.
        """
        self.received_signals.append(signum)
        # THE INTENT IS RECORDED HERE, NOT THE DELIVERY. What this process did
        # is "a signal arrived and I meant to pass it on"; whether it actually
        # went through is settled by `send_to_module`, which is the only place
        # that can know, and only a real delivery sets `forwarded_signal`.
        self.forward_intent_signals.append(signum)
        pidfd = self.child_pidfd
        if self.child_live and pidfd is not None:
            self.send_to_module(pidfd, signum)
            return
        if pidfd is None and not self.module_pinned:
            # No descriptor yet, or none ever: the only delivery left would be
            # by number, so the signal is kept rather than guessed at.
            self.held_signal = signum
            self.note_signal(
                f"{self.signal_name(signum)} arrived before this program held a pidfd for the module, so "
                "it is held and delivered through that descriptor once it exists, never by number")
            return
        if self.child_reaped:
            # The child has been reaped. Its number may already belong to
            # something else, so nothing is sent to it any more.
            self.note_signal(
                f"{self.signal_name(signum)} arrived after the module was reaped and was not sent "
                "anywhere, because the number it would have used is not this module's any more")
            return
        self.note_signal(
            f"{self.signal_name(signum)} arrived while the module's pidfd was already closed, and was not "
            "sent anywhere, because the descriptor that named the module is gone")

    def forward_held_signal(self) -> None:
        """The signal held across startup goes out the moment a descriptor exists."""
        held = self.held_signal
        if held is None:
            return
        self.held_signal = None
        pidfd = self.child_pidfd
        if self.child_live and pidfd is not None:
            self.send_to_module(pidfd, held)
            return
        self.note_signal(
            f"{self.signal_name(held)} was held from before the module was pinned until this run finished, "
            "and there was no pinned module to hand it to, so it was sent nowhere; this program never "
            "falls back to the module's number")

    def run(self) -> int:
        # Nothing is created and nothing is forked until this program can say
        # it will hold a pidfd for the module it is about to start.
        self.require_pidfd_api()
        # The mask this process arrived with is read first and kept: the child
        # must hold exactly this mask, and not this program's blocked one, when
        # it execs the genuine module.
        self.inherited_mask = signal.pthread_sigmask(signal.SIG_BLOCK, ())
        for name in FORWARDED_SIGNALS:
            number = getattr(signal, name, None)
            if number is not None:
                signal.signal(number, self.handle_signal)
        # From here until the module's pidfd is held, all four signals stay
        # blocked in this thread. A handler that ran in that window would have
        # no descriptor to send through, and the only alternative - sending by
        # number - is what this program refuses to do at any price.
        signal.pthread_sigmask(signal.SIG_BLOCK, self.forwarded_numbers())

        # Four pipes. Two carry the wire, one gates the exec, one carries the
        # exec notice back:
        #
        #     daemon stdin  -> to_child write end   -> child stdin   (fd 0)
        #     child stdout  -> from_child read end  -> daemon stdout (fd 1)
        #     this program  -> gate write end       -> child waits before exec
        #     child         -> notice write end     -> this program reads one byte
        #
        # Every descriptor is CLOEXEC, so the exec hands the module exactly the
        # two descriptors the daemon would have handed it and nothing of this
        # program survives into it.
        try:
            gate = os.pipe()
        except OSError as failure:
            raise ObserverError(f"the startup gate could not be created: {failure}") from failure
        created = [gate]
        try:
            notice = os.pipe()
            created.append(notice)
            to_child = os.pipe()
            created.append(to_child)
            from_child = os.pipe()
            created.append(from_child)
            for pair in created:
                for handle in pair:
                    os.set_inheritable(handle, False)
        except OSError as failure:
            self.close_pairs(created)
            raise ObserverError(f"the module's pipes could not be created: {failure}") from failure
        self.exec_notice_read = notice[0]
        self.exec_notice_write = notice[1]
        try:
            child_pid = os.fork()
        except OSError as failure:
            self.close_pairs(created)
            raise ObserverError(f"the module could not be forked: {failure}") from failure
        if child_pid == 0:
            self.become_module(to_child, from_child, gate)
            os._exit(127)  # unreachable: become_module never returns

        # THIS PROCESS STOPS DYING OF A BROKEN PIPE. The module is not
        # affected: `main` left SIGPIPE at its default disposition before this
        # fork, the child inherited that, and nothing below touches the
        # child's dispositions. This process is different, because it has an
        # ending of its own to reach: it holds two pipes the module does not
        # have, the daemon's and the module's, and both of them are closed by
        # the other side during an ordinary shutdown. speech-dispatcher sends
        # STOP and QUIT and then closes the module it just retired, so the
        # handover this program is in the middle of fails at exactly the
        # moment its own finalisation is about to begin.
        #
        # With the default disposition that failure is not a failure at all: the
        # kernel kills this process on the write, `pump_from_module` never
        # reaches its own `except OSError`, and the run ends with no footer, no
        # span bindings and no record of why - which is a trace that cannot
        # answer a single question about its own ending, produced by a
        # disposition this file chose for the module's benefit and never
        # limited to it. Ignoring it makes `os.write` raise the EPIPE both
        # pumps are already written to handle: they record the bytes as
        # traced and NOT forwarded, say so in the footer, and this process goes
        # on to the finalisation it was written to perform.
        signal.signal(signal.SIGPIPE, signal.SIG_IGN)

        self.child_stdin = to_child[1]
        self.module_stdout = from_child[0]
        self.child_pid = child_pid
        self.gate_write = gate[1]
        self.close_fd(gate[0])
        self.close_fd(to_child[0])
        self.close_fd(from_child[1])
        # Only the read end of the notice stays in this process, so the notice
        # ends at end of file the moment the child is gone, instead of waiting
        # on a writer that will never write again.
        self.close_fd(self.exec_notice_write)
        # The pidfd is REQUIRED, and the kernel can refuse it HERE, after the
        # fork. The gate is still shut, so this child has executed nothing:
        # refusing now stops a process that never ran instead of orphaning a
        # module that did, and there is no status to pretend to have read.
        try:
            self.child_pidfd = self.open_pidfd(child_pid)
        except ObserverError as failure:
            return self.refuse_module_startup(failure)
        self.module_pinned = True
        self.child_live = True
        try:
            self.trace.record({
                "kind": "spawned",
                "child_pid": child_pid,
                "child": describe_process(child_pid),
                "child_described_at": "the gated child, before its exec, so child.argv is this observer's "
                    "own forked copy; module_argv below is the genuine argv this observer execs",
                "child_pidfd": self.child_pidfd,
                "child_stdin_pipe": self.child_stdin,
                "module_stdout_pipe": self.module_stdout,
                "daemon_stdin": self.daemon_stdin,
                "daemon_stdout": self.daemon_stdout,
                "module_argv": self.module_argv,
                "startup_gate": "this ownership record is written before the gate is opened, so the "
                    "module's exec cannot have happened at the instant it entered the index",
            })
        except OSError as record_failure:
            # The ownership is not in the index, so this program will not claim
            # a module it cannot account for: the gate stays shut and the child
            # leaves without having executed anything.
            return self.refuse_module_startup(ObserverError(
                f"the module's ownership could not be written into the index, so this observer will not "
                f"claim a module it cannot account for: {record_failure}"))
        # Open the gate: from this byte the child execs the genuine module.
        self.release_startup_gate(GATE_EXEC)
        # The mask is restored only now, so every signal that arrived while it
        # was blocked is delivered to a handler that already holds a descriptor.
        signal.pthread_sigmask(signal.SIG_SETMASK, self.inherited_mask)
        self.forward_held_signal()

        self.from_thread = threading.Thread(
            target=self.pump_from_module, name="from-module", daemon=True)
        self.to_thread = threading.Thread(
            target=self.pump_to_module, args=(self.child_stdin,), name="to-module", daemon=True)
        self.meta_thread = threading.Thread(
            target=self.pump_metadata, name="metadata", daemon=True)
        for thread in (self.from_thread, self.to_thread, self.meta_thread):
            thread.start()
        self.wait_for_module()
        # The module is gone. What it wrote last is still in the pipe this
        # program holds, so the output pump is given a bounded chance to read
        # that final reply out and hand it on before this program returns. The
        # bound is a bound: past it the drain is reported, not waited for.
        self.from_thread.join(timeout=DRAIN_SECONDS)
        if self.from_thread.is_alive():
            self.pump_note = (
                (self.pump_note + "; ") if self.pump_note else ""
                + f"the module's last output was still in the pipe {DRAIN_SECONDS:g}s after it exited, so "
                  "this trace stops short of the reply it had already written")
        self.stop.set()
        self.to_thread.join(timeout=JOIN_SECONDS)
        if self.to_thread.is_alive():
            # This pump closes spans, so a run that did not wait for it cannot
            # claim the index holds every byte the daemon wrote. Saying so is
            # the whole point: the count and the bindings must not quietly
            # disagree.
            self.pump_note = (
                (self.pump_note + "; ") if self.pump_note else ""
                + f"the daemon side was still being read {JOIN_SECONDS:g}s after the module was gone, so "
                  "this trace stops short of the last daemon bytes and of any block they would have closed")
        # The daemon is not writing anything any more, so its last rows are read
        # inside a bound and then the sideband is closed and every span left over
        # is decided. This happens AFTER the wire pumps are done and never
        # before a byte was forwarded.
        self.meta_thread.join(timeout=META_DRAIN_SECONDS + JOIN_SECONDS)
        if self.meta_thread.is_alive():
            self.pump_note = (
                (self.pump_note + "; ") if self.pump_note else ""
                + f"the daemon's metadata sidecar was still being read {META_DRAIN_SECONDS:g}s after the "
                  "wire pumps stopped, so this trace stops short of the rows it had already written")
        self.meta.finish()
        self.meta.close()
        return self.report_footer()

    def pump_metadata(self) -> None:
        """The daemon's own write records, read on the same cadence as the wire.

        It starts alongside the two wire pumps, costs one empty read per tick
        when there is nothing to read, and never touches either pipe. When the
        environment carries no path there is nothing to read and no thread does
        any work at all.
        """
        if self.meta.state_reason is not None:
            return
        self.meta.pump(self.stop, POLL_SECONDS)

    @staticmethod
    def forwarded_numbers() -> list:
        """The four signals this observer passes on, as this interpreter has them."""
        numbers = (getattr(signal, name, None) for name in FORWARDED_SIGNALS)
        return [number for number in numbers if number is not None]

    def close_pairs(self, pairs: list) -> None:
        for pair in pairs:
            for handle in pair:
                self.close_fd(handle)

    def release_startup_gate(self, token: bytes) -> None:
        """Hand the child its one instruction, and close the write end."""
        try:
            write_all(self.gate_write, token)
        except OSError as failure:
            self.startup_failure = ((self.startup_failure or "") + f"; the startup gate could not be "
                                    f"written: {failure}")
        self.close_fd(self.gate_write)

    def await_startup_gate(self, gate: int) -> bool:
        """The child half: exec only if, and only when, the parent says so.

        One byte decides it. ``GATE_EXEC`` opens the way to the genuine module;
        anything else - an abort token, an end of file because this program
        died, a gate that never came - leaves this child to exit without having
        executed anything. The wait is bounded as well, so no child of this
        program can sit on this read forever.
        """
        deadline = time.monotonic() + STARTUP_GATE_SECONDS
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                os.write(2, b"speech-module-observer: the startup gate stayed shut, so the module was "
                            b"never executed\n")
                return False
            try:
                if not select.select([gate], [], [], min(POLL_SECONDS, left))[0]:
                    continue
                token = os.read(gate, 1)
            except InterruptedError:
                continue
            except OSError:
                return False
            return token == GATE_EXEC

    def read_exec_notice(self, handle: int) -> bool:
        """Did this run's child really reach the exec call for the module?

        The child writes one byte on the notice pipe immediately before
        ``execv`` and nothing else, and that pipe's write end exists nowhere
        else, so once the child is gone this read returns at once: a byte means
        the exec call was reached, an end of file means it was not. It says
        nothing about whether ``execv`` itself then succeeded, which only the
        module's own stderr and exit status can say.
        """
        try:
            token = os.read(handle, 1)
        except OSError as failure:
            self.pump_note = ((self.pump_note + "; ") if self.pump_note else "") + (
                f"the exec notice could not be read: {failure}")
            return False
        return token == EXEC_NOTICE

    def refuse_module_startup(self, failure: ObserverError) -> int:
        """Startup refused after the fork: the module is stopped before it ran.

        Either the kernel gave no pidfd for the child, or the index would not
        take the ownership that lets this program account for it. Both answers
        arrive while the gate is still shut, so nothing has been executed:
        there is no module process to orphan and no module status to read. One
        abort byte tells the child to leave, its own end is waited for inside a
        bound, and the footer states the refusal, that child's real status and
        the fact that no module ran. The exit code is this program's own
        refusal code, not a status borrowed from a process that never became a
        module.
        """
        # Disarm before anything else. A run that is about to refuse must not
        # go on aiming at a child it is sending away, and the descriptor goes
        # before the abort byte does.
        had_pidfd = self.child_pidfd is not None
        self.child_live = False
        if self.child_pidfd is not None:
            self.close_fd(self.child_pidfd)
            self.child_pidfd = None
        self.startup_failure = str(failure)
        self.release_startup_gate(GATE_ABORT)
        reaped = self.reap_unstarted_child()
        self.module_exec_reached = self.read_exec_notice(self.exec_notice_read)
        self.close_fd(self.exec_notice_read)
        # The signals stay blocked only until the refusal is on the record; a
        # signal held from before the fork has no module to reach and is said so
        # rather than aimed at a number.
        signal.pthread_sigmask(signal.SIG_SETMASK, self.inherited_mask)
        self.forward_held_signal()
        # The run is refused here, so the sideband is closed and judged with it.
        self.meta.finish()
        self.meta.close()
        write_private_json(os.path.join(self.trace_dir, FOOTER_NAME), self.footer_common() | {
            "module_executed": False,
            "module_exec_reached": self.module_exec_reached,
            "module_reaped": None,
            "module_exit_code": None,
            "module_exit_signal": None,
            "module_end": "never started",
            "startup_refusal": self.startup_failure,
            "child_exit_code": self.module_exit_code,
            "child_exit_signal": self.module_exit_signal or None,
            "child_end": "signalled" if self.module_exit_signal else "exited",
            "child_reaped": reaped,
            "child_status_read_with": "os.waitpid on the forked child, because the refusal that brought "
                "this run here is precisely the absence of a pidfd" if not had_pidfd else
                "os.waitpid on the forked child, after the pidfd this run did hold was closed with the "
                "refusal; no module was ever executed, so nothing here needed a descriptor to wait with",
            "observer_exit_code": REFUSAL_EXIT,
            "observer_end": "this program refuses the run and exits with its own code, because no module "
                "was ever executed and there is no module status for it to reproduce",
            "module_output_reached_eof": self.module_output_eof,
            "signals_delivered_by": "pidfd only, and this refusal sent no signal at all: this program "
                "never sends a signal by number, and the child it stopped never became a module",
        })
        os.write(2, f"speech-module-observer: {self.startup_failure}\n".encode())
        return REFUSAL_EXIT

    def reap_unstarted_child(self) -> bool:
        """Wait for the child that never became a module, inside a bound.

        There is no pidfd here - that absence is the whole reason for this
        path - so the wait uses the one handle a parent always has for its own
        unreaped child. It polls rather than blocks, and past the bound it says
        so instead of waiting on a process this program can no longer signal.
        """
        deadline = time.monotonic() + STARTUP_ABORT_SECONDS
        while True:
            try:
                pid, status = os.waitpid(self.child_pid, os.WNOHANG)
            except ChildProcessError as failure:
                self.startup_failure = (self.startup_failure or "") + (
                    f"; the child that never executed the module ({self.child_pid}) was waited for by "
                    f"something other than this observer: {failure}")
                return False
            except OSError as failure:
                self.startup_failure = (self.startup_failure or "") + (
                    f"; the child that never executed the module ({self.child_pid}) could not be waited "
                    f"for: {failure}")
                return False
            if pid == self.child_pid:
                self.read_status(status)
                return True
            if time.monotonic() >= deadline:
                self.startup_failure = (self.startup_failure or "") + (
                    f"; the child that never executed the module ({self.child_pid}) did not leave within "
                    f"{STARTUP_ABORT_SECONDS:g}s and this program holds no pidfd for it, so it is left "
                    "unreaped and unsignalled rather than aimed at by number")
                return False
            time.sleep(POLL_SECONDS)

    def become_module(self, to_child: tuple, from_child: tuple, gate: tuple) -> None:
        """The child half of the fork: descriptors rewired, a gate, then exec.

        Nothing but the gate and the exec belongs here. No tracing, no
        buffering, no Python runtime left behind, and no descriptor this
        program holds beyond the two the daemon itself would have provided.

        Two things happen before the exec, and both are about honesty rather
        than about the wire. This process's signal handlers go back to their
        default disposition, so nothing here can forward anything to anything.
        And the mask this program blocked for its own bookkeeping goes back to
        the mask this process started with, because the genuine module must not
        inherit a signal set that belongs to the observer alone.
        """
        to_read, _to_write = to_child
        _from_read, from_write = from_child
        gate_read, gate_write = gate
        if to_read != 0:
            os.dup2(to_read, 0)
        if from_write != 1:
            os.dup2(from_write, 1)
        for handle in to_child + from_child:
            if handle not in (0, 1):
                os.close(handle)
        self.close_fd(gate_write)
        self.close_fd(self.exec_notice_read)
        for name in FORWARDED_SIGNALS:
            number = getattr(signal, name, None)
            if number is not None:
                signal.signal(number, signal.SIG_DFL)
        signal.pthread_sigmask(signal.SIG_SETMASK, self.inherited_mask)
        if not self.await_startup_gate(gate_read):
            # Nothing was executed. The parent learns that from this exit and
            # from an exec notice that never arrives, not from a status it has
            # to invent for a module that never ran.
            self.close_fd(gate_read)
            self.close_fd(self.exec_notice_write)
            os._exit(STARTUP_ABORT_EXIT)
        self.close_fd(gate_read)
        try:
            os.write(self.exec_notice_write, EXEC_NOTICE)
        except OSError:
            pass
        self.close_fd(self.exec_notice_write)
        try:
            os.execv(self.module_argv[0], self.module_argv)
        except OSError as failure:
            os.write(2, f"exec of {self.module_argv[0]} failed: {failure}\n".encode())
        os._exit(127)

    def wait_for_module(self) -> None:
        """The module's exit is this program's exit. Nothing is invented."""
        pidfd = self.child_pidfd
        while True:
            try:
                if getattr(os, "P_PIDFD", None) is not None:
                    info = os.waitid(os.P_PIDFD, pidfd, os.WEXITED)
                    self.read_waitid(info)
                else:
                    _, status = os.waitpid(self.child_pid, 0)
                    self.read_status(status)
            except InterruptedError:
                continue
            except ChildProcessError as failure:
                # This program holds the only handle to this child, so a wait
                # that finds nothing is a fact about the run. It is reported,
                # never rounded down to a module that exited cleanly.
                raise ObserverError(
                    f"the module (pid {self.child_pid}) was waited for by something other than this "
                    f"observer, so its real exit status cannot be read: {failure}") from failure
            break
        # DISARM BEFORE THE DESCRIPTOR GOES AWAY. child_live is cleared first,
        # so a signal that arrives at any later instant takes the early return
        # in handle_signal and is delivered nowhere. Closing first would leave
        # a window in which the child is already reaped, its number may already
        # belong to another process, and the handler still believes it may send.
        self.child_live = False
        self.child_pidfd = None
        self.child_reaped = True
        self.close_fd(pidfd)
        # The child is gone, so its end of the exec notice is either a byte or
        # an end of file: one read now, with nothing left to wait for.
        self.module_exec_reached = self.read_exec_notice(self.exec_notice_read)
        self.close_fd(self.exec_notice_read)

    def read_waitid(self, info) -> None:
        """The module's own status, as waitid reports it."""
        if info.si_code == os.CLD_EXITED:
            self.module_exit_code = info.si_status
        elif info.si_code in (os.CLD_KILLED, os.CLD_DUMPED):
            self.module_exit_signal = info.si_status
        else:
            raise ObserverError(
                f"the module ended with wait status class {info.si_code}, which is neither an exit nor a "
                "signal death, so this program cannot say how it ended")

    def read_status(self, status: int) -> None:
        """The module's own status, as waitpid reports it."""
        if os.WIFEXITED(status):
            self.module_exit_code = os.WEXITSTATUS(status)
        elif os.WIFSIGNALED(status):
            self.module_exit_signal = os.WTERMSIG(status)
        else:
            raise ObserverError(
                f"the module ended with wait status {status}, which is neither an exit nor a signal death, "
                "so this program cannot say how it ended")

    def footer_common(self) -> dict:
        """What every footer states, however the run ended."""
        return {
            "kind": "footer",
            "observer_pid": os.getpid(),
            "module_pid": self.child_pid,
            # THE SIGNAL THIS PROGRAM DELIVERED, which is 0 when it delivered
            # none. It is not "the signal that arrived": `forward_intent_signal`
            # is that, and the two are told apart on purpose.
            "forwarded_signal": self.forwarded_signal,
            "received_signals": list(self.received_signals),
            # THE WHOLE TRANSCRIPT OF WHAT HAPPENED TO THE SIGNALS, as facts.
            #
            # `signal_note` above is the FAULT channel and stays null when
            # nothing failed. Nothing is suppressed by that: every attempt is
            # here, with its outcome, its errno and the reason, so a reader who
            # wants the prose can find the fact and a reader who wants the fact
            # never has to parse the prose.
            "signal_delivery": {
                "received": list(self.received_signals),
                "forward_intent": list(self.forward_intent_signals),
                "delivered": list(self.delivered_signals),
                "delivery_count": len(self.delivered_signals),
                "intent_count": len(self.forward_intent_signals),
                "outcomes": list(self.signal_outcomes),
                # The module's own end, obtained INDEPENDENTLY through the
                # retained pidfd by `wait_for_module`. It is published beside
                # the outcomes so an `already_ended` outcome is checkable rather
                # than asserted: this process says the module was already gone,
                # and this is what the kernel says about how it went.
                "module_reaped": self.child_reaped,
                "module_exit_code": self.module_exit_code,
                "module_exit_signal": self.module_exit_signal,
                "rule": "one record per forwarding attempt, with the outcome the kernel gave. `delivered` "
                    "means `pidfd_send_signal` returned without an error through the descriptor this "
                    "program holds. `already_ended` means the kernel refused that descriptor because the "
                    "module was no longer a running task, which is what a module the daemon retired "
                    "directly in the same pass looks like from here; nothing was delivered and nothing is "
                    "claimed as delivered, and module_reaped with the exit status is the independent proof "
                    "of how it ended. `refused` is every other failure and is the only outcome that "
                    "writes a signal_note.",
            },
            "events": dict(self.trace.counts),
            "pump_note": self.pump_note,
            "signal_note": self.signal_note,
            "signals_delivered_by": "pidfd only; this program never sends a signal by number",
            "startup_failure": self.startup_failure,
            "stream_check": self.stream_check(),
            "metadata": self.meta.summary(),
            "monotonic_ns": time.monotonic_ns(),
            "wall_ns": time.time_ns(),
        }

    def stream_check(self) -> dict:
        """Two counts, told apart, each against the file on disk.

        ``in_trace`` is what this run put down; ``forwarded`` is what the other
        side really received. Those are equal on a clean run and are reported
        separately precisely when they are not: a byte that was written down
        and then refused on its way out is traced and NOT forwarded, and saying
        otherwise would claim a handover that did not happen.
        """
        traced_to = self.trace.written[TO_MODULE_NAME]
        traced_from = self.trace.written[FROM_MODULE_NAME]
        disk_to = self.trace.size_of(self.trace.to_module)
        disk_from = self.trace.size_of(self.trace.from_module)
        sent_to = self.trace.forwarded[TO_MODULE_NAME]
        sent_from = self.trace.forwarded[FROM_MODULE_NAME]
        return {
            "to_module_bytes_in_trace": traced_to,
            "to_module_bytes_on_disk": disk_to,
            "to_module_bytes_forwarded": sent_to,
            "from_module_bytes_in_trace": traced_from,
            "from_module_bytes_on_disk": disk_from,
            "from_module_bytes_forwarded": sent_from,
            "agrees": traced_to == disk_to and traced_from == disk_from,
            "forwarded_matches_trace": sent_to == traced_to and sent_from == traced_from,
            "counted": "in_trace counts the bytes this run put into the raw file; forwarded counts the "
                "bytes it then handed to the other side. A byte that was traced and whose handover failed "
                "is counted only as traced, never as forwarded",
            "read_boundaries": "none of the framing depends on where a read ended; both framers carry a "
                "partial message or line across reads and count offsets from the start of the stream",
        }

    def report_footer(self) -> int:
        """Write the module's real ending, then end this process the same way.

        The footer is the record and it is written FIRST, while this process is
        still able to write it. Then the exit status is the module's own: an
        ordinary exit becomes this process's exit code, and a module killed by
        a signal has that signal re-raised here with the disposition restored
        to the default, so the daemon that forked this program reaps a genuine
        WIFSIGNALED carrying the module's signal number instead of a
        synthesised 128+n exit code. Nothing is claimed that was not observed:
        the footer records the real code and the real signal, and 128+n appears
        only as the shell's own convention for a process killed by that signal.
        """
        if not self.module_exec_reached:
            write_private_json(os.path.join(self.trace_dir, FOOTER_NAME), self.footer_common() | {
                "module_executed": False,
                "module_exec_reached": False,
                "module_reaped": None,
                "module_exit_code": None,
                "module_exit_signal": None,
                "module_end": "the forked child ended before reaching the module exec",
                "child_reaped": True,
                "child_exit_code": self.module_exit_code,
                "child_exit_signal": self.module_exit_signal or None,
                "child_end": "signalled" if self.module_exit_signal else "exited",
                "observer_exit_code": REFUSAL_EXIT,
                "observer_end": "this observer refuses the run; no module status exists to reproduce",
                "module_output_reached_eof": self.module_output_eof,
            })
            return REFUSAL_EXIT
        number = self.module_exit_signal
        code = 128 + number if number else self.module_exit_code
        write_private_json(os.path.join(self.trace_dir, FOOTER_NAME), self.footer_common() | {
            "module_exit_code": self.module_exit_code,
            "module_exit_signal": number or None,
            "module_end": "signalled" if number else "exited",
            "module_exec_reached": self.module_exec_reached,
            "module_exec_evidence": "the child wrote one byte on the exec-notice pipe immediately before "
                "calling execv, and that byte was waiting here when the child was reaped. It does not say "
                "whether execv then succeeded, which only the module's own stderr and status can say",
            "module_status_read_with": "os.waitid(os.P_PIDFD, ...) on the module's own pidfd"
                if getattr(os, "P_PIDFD", None) is not None else "os.waitpid on the forked child",
            "to_module_bytes": self.trace.size_of(self.trace.to_module),
            "from_module_bytes": self.trace.size_of(self.trace.from_module),
            "observer_exit_code": code,
            "observer_end": "this process re-raised the module's own signal after writing this footer, so "
                "the daemon reaps a real WIFSIGNALED" if number
                else "this process exits with the module's own exit code",
            "module_output_reached_eof": self.module_output_eof,
            "module_reaped": True,
        })
        return self.end_like_the_module(code)

    def end_like_the_module(self, code: int) -> int:
        """Return the module's exit code, or die of the module's own signal.

        A signal death is reproduced, not encoded. SIG_DFL is restored first so
        the disposition is the one this process started with, then the signal is
        raised against this process, which kills it exactly as the kernel killed
        the module. The os._exit below is unreachable in that case and exists
        only so this function is total.
        """
        number = self.module_exit_signal
        if number:
            try:
                if number not in (signal.SIGKILL, signal.SIGSTOP):
                    signal.signal(number, signal.SIG_DFL)
                signal.pthread_sigmask(signal.SIG_UNBLOCK, {number})
                os.kill(os.getpid(), number)
            except (OSError, ValueError) as failure:
                os.write(2, f"speech-module-observer: could not re-raise {number}: {failure}\n"
                            .encode())
            os._exit(code)
        return code


def main(argv: list) -> int:
    # SIGPIPE keeps its default disposition, so a module writing into a closed
    # pipe dies the way it would have without this program in the way.
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    trace: Trace | None = None
    try:
        trace_dir = os.environ.get(ENV_TRACE, "")
        require_private_dir(trace_dir)
        module = require_module(os.environ.get(ENV_MODULE, ""))
        # argv[0] becomes the genuine module; argv[1] onwards is the daemon's
        # own argument, its module configuration path, forwarded untouched.
        module_argv = [module["path"], *argv[1:]]
        observer = Observer(module, trace_dir, module_argv)
        trace = observer.trace
        return observer.run()
    except ObserverError as failure:
        # Every refusal ends here with this program's own code. No module ran,
        # so there is no module status to reproduce and nothing to claim.
        os.write(2, f"speech-module-observer: {failure}\n".encode())
        return REFUSAL_EXIT
    finally:
        if trace is not None:
            trace.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv))