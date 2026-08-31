from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
import hashlib
import json
import math
import os
import platform
import random
import select
import shutil
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence


SCHEMA_VERSION = 1
U64_MAX = (1 << 64) - 1
TRACY_PORT = 8086
TRACY_HOST = "127.0.0.1"
PERF_WIDTH = 954
PERF_HEIGHT = 1044
PERF_PRESENT_MODE = "fifo"
CALIBRATION_FRAMES = 2_400
QUALIFICATION_BLOCKS = 300
QUALIFICATION_FRAMES = 1_000
SHADER_FILES = (
    "quad_vert.spv",
    "quad_frag.spv",
    "sort_comp.spv",
    "fullscreen_vert.spv",
    "blit_oklab.spv",
)
SCENES = ("todo", "spotify", "calculator", "tiger", "strokes")
PAIR_PROFILES = ("clean", "gpu", "mechanism")
PROFILE_FLAGS: dict[str, dict[str, bool]] = {
    "clean": {"tracy": False, "gpu_timestamps": False, "perf_counters": False},
    "tracy": {"tracy": True, "gpu_timestamps": False, "perf_counters": False},
    "gpu": {"tracy": False, "gpu_timestamps": True, "perf_counters": False},
    "mechanism": {"tracy": False, "gpu_timestamps": False, "perf_counters": True},
}
COUNTER_NAMES = (
    "measure_requests",
    "harfbuzz_shapes",
    "hard_line_bytes_scanned",
    "segment_bytes_scanned",
    "segment_content_rescan_bytes",
    "glyph_entry_comparisons",
    "node_comparisons",
    "svg_card_node_comparisons",
    "hover_focus_node_comparisons",
    "ancestor_reads",
    "draw_cmd_value_bind_bytes",
    "slice_rect_growth_events",
    "slice_rect_growth_copy_bytes",
    "svg_stroke_write_attempts",
    "svg_stroke_writes",
)
MACHINE_FIELDS = (
    "cpu_model",
    "online_cpu_set",
    "requested_affinity",
    "process_affinity",
    "kernel",
    "cpu_governor",
    "gpu",
    "driver",
    "extent",
    "present_mode",
)
HEADER_FIELDS = (
    "schema_version",
    "scene",
    "mode",
    "optimize_mode",
    "instrumentation_flags",
    "block_id",
    "randomized_order_position",
    "child_argv",
    "zig_version",
    "binary_sha256",
    "runner_sha256",
    "shader_hashes",
    "nogui_jj_change_id",
    "nogui_jj_commit_id",
    "noapi_jj_change_id",
    "noapi_jj_commit_id",
    "cpu_model",
    "online_cpu_set",
    "process_affinity",
    "requested_affinity",
    "kernel",
    "cpu_governor",
    "gpu",
    "driver",
    "extent",
    "present_mode",
    "reported_refresh_data",
    "present_feedback",
    "warmup_rule",
    "process_order_seed",
    "sample_count",
)
CHILD_RUNTIME_FIELDS = (
    "scene",
    "mode",
    "instrumentation_flags",
    "child_argv",
    "cpu_model",
    "online_cpu_set",
    "requested_affinity",
    "process_affinity",
    "kernel",
    "cpu_governor",
    "gpu",
    "driver",
    "extent",
    "present_mode",
    "reported_refresh_data",
    "present_feedback",
    "warmup_frames",
    "sample_count",
)
SAMPLE_FIELDS = (
    "phase",
    "frame_id",
    "cpu_app_layout_ns",
    "cpu_scene_ns",
    "cpu_record_ns",
    "cpu_submit_present_ns",
    "cpu_compute_ns",
    "cpu_acquire_ns",
    "cpu_slot_wait_ns",
    "cpu_present_slop_ns",
    "gpu_execute_ns",
    "gpu_end_interval_ns",
    "present_interval_ns",
    "slop_ns",
)


class ProtocolError(Exception):
    """Raised when an artifact or measurement violates the fixed protocol."""


@dataclass(frozen=True)
class ProcessBlock:
    path: Path
    header: dict[str, Any]
    frames: tuple[dict[str, Any], ...]
    sha256: str
    trace: TraceEvidence | None = None

    @property
    def samples(self) -> tuple[dict[str, Any], ...]:
        return tuple(frame for frame in self.frames if frame["phase"] == "sample")

    @property
    def warmups(self) -> tuple[dict[str, Any], ...]:
        return tuple(frame for frame in self.frames if frame["phase"] == "warmup")


@dataclass(frozen=True)
class Snapshot:
    path: Path
    manifest: dict[str, Any]


@dataclass(frozen=True)
class TraceEvidence:
    trace_path: Path
    csv_path: Path
    trace_sha256: str
    csv_sha256: str
    summary: dict[str, Any]


def _duplicate_key_error(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_json_constant(value: str) -> Any:
    raise ProtocolError(f"JSON contains non-finite value {value}")


def _load_json(path: Path) -> Any:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise ProtocolError(f"cannot read JSON artifact {path}: {exc}") from exc
    try:
        return json.loads(
            text,
            object_pairs_hook=_duplicate_key_error,
            parse_constant=_reject_json_constant,
        )
    except ProtocolError:
        raise
    except json.JSONDecodeError as exc:
        raise ProtocolError(f"invalid JSON in {path}: {exc.msg}") from exc


def _require_object(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ProtocolError(f"{name} must be a JSON object")
    return value


def _require_string(value: Any, name: str, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str):
        raise ProtocolError(f"{name} must be a string")
    if not allow_empty and not value:
        raise ProtocolError(f"{name} must not be empty")
    return value

PLACEHOLDER_METADATA = frozenset({
    "unavailable",
    "unknown",
    "n/a",
    "na",
    "none",
    "null",
})


def _require_real_string(value: Any, name: str) -> str:
    result = _require_string(value, name)
    if result.strip().casefold() in PLACEHOLDER_METADATA:
        raise ProtocolError(f"{name} contains placeholder metadata")
    return result


def _require_bool(value: Any, name: str) -> bool:
    if not isinstance(value, bool):
        raise ProtocolError(f"{name} must be boolean")
    return value


def _require_u64(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ProtocolError(f"{name} must be an integer")
    if value < 0:
        raise ProtocolError(f"{name} must be non-negative")
    if value > U64_MAX:
        raise ProtocolError(f"{name} exceeds u64")
    return value


def _optional_u64(value: Any, name: str) -> int | None:
    if value is None:
        return None
    return _require_u64(value, name)


def _require_sha256(value: Any, name: str) -> str:
    result = _require_string(value, name)
    if len(result) != 64:
        raise ProtocolError(f"{name} must be a SHA-256 digest")
    try:
        int(result, 16)
    except ValueError as exc:
        raise ProtocolError(f"{name} must be a SHA-256 digest") from exc
    return result.lower()


def _require_string_list(value: Any, name: str) -> list[str]:
    if not isinstance(value, list) or not value:
        raise ProtocolError(f"{name} must be a non-empty string list")
    for index, item in enumerate(value):
        _require_string(item, f"{name}[{index}]")
    return value


def _require_cpu_set(value: Any, name: str) -> list[int]:
    if not isinstance(value, list):
        raise ProtocolError(f"{name} must be a list")
    result: list[int] = []
    for index, item in enumerate(value):
        if isinstance(item, bool) or not isinstance(item, int) or item < 0:
            raise ProtocolError(f"{name}[{index}] must be a non-negative integer")
        result.append(item)
    if not result:
        raise ProtocolError(f"{name} must not be empty")
    if result != sorted(set(result)):
        raise ProtocolError(f"{name} must be sorted and unique")
    return result


def _validate_flags(value: Any, name: str = "instrumentation_flags") -> dict[str, bool]:
    flags = _require_object(value, name)
    expected = set(PROFILE_FLAGS["clean"])
    if set(flags) != expected:
        raise ProtocolError(f"{name} has unexpected keys")
    return {key: _require_bool(flags[key], f"{name}.{key}") for key in sorted(expected)}


def profile_for_flags(flags: Mapping[str, bool]) -> str:
    for profile, expected in PROFILE_FLAGS.items():
        if dict(flags) == expected:
            return profile
    raise ProtocolError("instrumentation flags do not describe an isolated profile")


def _validate_shader_hashes(value: Any, name: str = "shader_hashes") -> dict[str, str]:
    hashes = _require_object(value, name)
    if set(hashes) != set(SHADER_FILES):
        raise ProtocolError(f"{name} must contain every required shader")
    return {shader: _require_sha256(hashes[shader], f"{name}.{shader}") for shader in SHADER_FILES}


def _validate_warmup_rule(value: Any) -> dict[str, Any]:
    rule = _require_object(value, "warmup_rule")
    frames = _require_u64(rule.get("frames"), "warmup_rule.frames")
    if frames > CALIBRATION_FRAMES:
        raise ProtocolError("warmup_rule.frames exceeds calibration limit")
    if frames == 0:
        if rule.get("kind") != "calibration":
            raise ProtocolError("warmup_rule.frames must be positive outside calibration")
    elif "manifest_sha256" not in rule:
        raise ProtocolError("warmup_rule.manifest_sha256 is required")
    manifest_sha256 = rule.get("manifest_sha256")
    if manifest_sha256 is not None:
        _require_sha256(manifest_sha256, "warmup_rule.manifest_sha256")
    return rule


def _validate_header(header: Any) -> dict[str, Any]:
    result = _require_object(header, "JSONL header")
    missing = [field for field in HEADER_FIELDS if field not in result]
    if missing:
        raise ProtocolError(f"missing required header metadata: {missing[0]}")
    if result["schema_version"] != SCHEMA_VERSION:
        raise ProtocolError("unsupported schema_version")
    _require_string(result["scene"], "scene")
    if result["scene"] not in SCENES:
        raise ProtocolError("unknown scene")
    if result["mode"] not in ("offscreen", "presented"):
        raise ProtocolError("mode must be offscreen or presented")
    _require_string(result["optimize_mode"], "optimize_mode")
    flags = _validate_flags(result["instrumentation_flags"])
    profile_for_flags(flags)
    _require_u64(result["block_id"], "block_id")
    _require_u64(result["randomized_order_position"], "randomized_order_position")
    _require_string_list(result["child_argv"], "child_argv")
    _require_string(result["zig_version"], "zig_version")
    _require_sha256(result["binary_sha256"], "binary_sha256")
    _require_sha256(result["runner_sha256"], "runner_sha256")
    _validate_shader_hashes(result["shader_hashes"])
    for field in ("nogui_jj_change_id", "nogui_jj_commit_id", "noapi_jj_change_id", "noapi_jj_commit_id"):
        _require_string(result[field], field)
    _validate_machine(
        {field: result[field] for field in MACHINE_FIELDS},
        "header",
    )
    refresh = result["reported_refresh_data"]
    if refresh is not None:
        _require_object(refresh, "reported_refresh_data")
    _require_bool(result["present_feedback"], "present_feedback")
    _validate_warmup_rule(result["warmup_rule"])
    _require_u64(result["process_order_seed"], "process_order_seed")
    sample_count = _require_u64(result["sample_count"], "sample_count")
    if sample_count == 0:
        raise ProtocolError("sample_count must be positive")
    return result


def _validate_mechanisms(value: Any) -> dict[str, int]:
    mechanisms = _require_object(value, "mechanisms")
    if not mechanisms:
        raise ProtocolError("mechanisms must not be empty")
    if set(mechanisms) != set(COUNTER_NAMES):
        raise ProtocolError("mechanisms must contain every counter")
    return {
        name: _require_u64(mechanisms[name], f"mechanisms.{name}")
        for name in COUNTER_NAMES
    }


def _validate_sample(
    sample: Any,
    header: Mapping[str, Any],
    expected_frame_id: int,
) -> dict[str, Any]:
    result = _require_object(sample, "sample")
    missing = [field for field in SAMPLE_FIELDS if field not in result]
    if missing:
        raise ProtocolError(f"missing required sample field: {missing[0]}")
    phase = result["phase"]
    if phase not in ("warmup", "sample"):
        raise ProtocolError("sample phase must be warmup or sample")
    frame_id = _require_u64(result["frame_id"], "frame_id")
    if frame_id != expected_frame_id:
        raise ProtocolError("frame IDs must be contiguous from zero")
    for field in (
        "cpu_app_layout_ns",
        "cpu_scene_ns",
        "cpu_record_ns",
        "cpu_submit_present_ns",
        "cpu_compute_ns",
        "slop_ns",
    ):
        _require_u64(result[field], field)
    profile = profile_for_flags(_validate_flags(header["instrumentation_flags"]))
    mode = header["mode"]
    acquire = _optional_u64(result.get("cpu_acquire_ns"), "cpu_acquire_ns")
    slot_wait = _optional_u64(result.get("cpu_slot_wait_ns"), "cpu_slot_wait_ns")
    present_slop = _optional_u64(result.get("cpu_present_slop_ns"), "cpu_present_slop_ns")
    if mode == "offscreen":
        if acquire is not None:
            raise ProtocolError("offscreen samples must leave cpu_acquire_ns null")
        if present_slop is not None:
            raise ProtocolError("offscreen samples must leave cpu_present_slop_ns null")
        if slot_wait is None:
            raise ProtocolError("offscreen samples require cpu_slot_wait_ns")
        expected_slop = slot_wait
        submit_term = result["cpu_submit_present_ns"]
    else:
        if acquire is None:
            raise ProtocolError("presented samples require cpu_acquire_ns")
        if present_slop is None:
            raise ProtocolError("presented samples require cpu_present_slop_ns")
        if slot_wait is not None:
            raise ProtocolError("presented samples must leave cpu_slot_wait_ns null")
        if present_slop > result["cpu_submit_present_ns"]:
            raise ProtocolError("present slop exceeds submit duration")
        submit_term = result["cpu_submit_present_ns"] - present_slop
    if result["cpu_compute_ns"] != (
        result["cpu_app_layout_ns"]
        + result["cpu_scene_ns"]
        + result["cpu_record_ns"]
        + submit_term
    ):
        raise ProtocolError("cpu_compute_ns does not equal checked stage sum")
    if mode == "offscreen" and result["slop_ns"] != expected_slop:
        raise ProtocolError("offscreen slop must equal slot wait")
    gpu_execute = _optional_u64(result.get("gpu_execute_ns"), "gpu_execute_ns")
    gpu_end = _optional_u64(result.get("gpu_end_interval_ns"), "gpu_end_interval_ns")
    if profile == "gpu":
        if gpu_execute is None:
            raise ProtocolError("GPU profile requires gpu_execute_ns")
        if frame_id == 0:
            if gpu_end is not None:
                raise ProtocolError("first GPU frame must not have gpu_end_interval_ns")
        else:
            if gpu_end is None:
                raise ProtocolError("GPU profile requires gpu_end_interval_ns after frame zero")
            if gpu_end == 0:
                raise ProtocolError("GPU frame-end intervals must be positive")
    elif gpu_execute is not None or gpu_end is not None:
        raise ProtocolError("non-GPU profiles must leave GPU fields null")
    present_interval = _optional_u64(result.get("present_interval_ns"), "present_interval_ns")
    if mode != "presented":
        if present_interval is not None:
            raise ProtocolError("offscreen samples must leave present_interval_ns null")
    else:
        timing_supported = header["present_feedback"]
        if timing_supported and frame_id == 0 and present_interval is not None:
            raise ProtocolError("first presented frame must not have present_interval_ns")
        if timing_supported and frame_id != 0 and present_interval is None:
            raise ProtocolError("presented samples require present_interval_ns after frame zero")
        if timing_supported and frame_id != 0 and present_interval == 0:
            raise ProtocolError("present intervals must be positive")
        if not timing_supported and present_interval is not None:
            raise ProtocolError("presentation interval is unavailable")
    actual_timestamp = result.get("present_timestamp_ns")
    if actual_timestamp is not None:
        _require_u64(actual_timestamp, "present_timestamp_ns")
    if profile == "mechanism":
        if "mechanisms" not in result:
            raise ProtocolError("mechanism profile requires mechanisms")
        _validate_mechanisms(result["mechanisms"])
    elif "mechanisms" in result:
        raise ProtocolError("mechanisms are only valid in mechanism builds")
    return result


def _validate_expected_identity(header: Mapping[str, Any], expected: Mapping[str, Any]) -> None:
    for field, expected_value in expected.items():
        if field not in header:
            raise ProtocolError(f"missing identity field {field}")
        if header[field] != expected_value:
            raise ProtocolError(f"{field} changed during measurement")


def _load_jsonl_records(path: Path) -> list[Any]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise ProtocolError(f"cannot read JSONL artifact {path}: {exc}") from exc
    if not lines:
        raise ProtocolError("JSONL artifact is empty")
    records: list[Any] = []
    for line_number, line in enumerate(lines, start=1):
        if not line.strip():
            raise ProtocolError(f"blank JSONL line {line_number}")
        try:
            records.append(
                json.loads(
                    line,
                    object_pairs_hook=_duplicate_key_error,
                    parse_constant=_reject_json_constant,
                )
            )
        except ProtocolError:
            raise
        except json.JSONDecodeError as exc:
            raise ProtocolError(f"invalid JSON on line {line_number}: {exc.msg}") from exc
    return records


def parse_process_jsonl(
    path: str | Path,
    *,
    expected_identity: Mapping[str, Any] | None = None,
    expected_profile: str | None = None,
    expected_mode: str | None = None,
    expected_scene: str | None = None,
    expected_sample_frames: int | None = None,
) -> ProcessBlock:
    artifact_path = Path(path)
    if artifact_path.is_symlink() or not artifact_path.is_file():
        raise ProtocolError(f"JSONL artifact is not a regular file: {artifact_path}")
    records = _load_jsonl_records(artifact_path)
    header = _validate_header(records[0])
    if expected_identity is not None:
        _validate_expected_identity(header, expected_identity)
    profile = profile_for_flags(header["instrumentation_flags"])
    if expected_profile is not None and profile != expected_profile:
        raise ProtocolError(f"profile mismatch: expected {expected_profile}, got {profile}")
    if expected_mode is not None and header["mode"] != expected_mode:
        raise ProtocolError("mode mismatch")
    if expected_scene is not None and header["scene"] != expected_scene:
        raise ProtocolError("scene mismatch")
    if len(records) == 1:
        raise ProtocolError("JSONL artifact contains no samples")
    frames: list[dict[str, Any]] = []
    saw_sample = False
    for expected_frame_id, record in enumerate(records[1:]):
        frame = _validate_sample(record, header, expected_frame_id)
        if frame["phase"] == "sample":
            saw_sample = True
        elif saw_sample:
            raise ProtocolError("warmup frame follows a retained sample")
        frames.append(frame)
    observed_warmups = sum(frame["phase"] == "warmup" for frame in frames)
    declared_warmups = _require_u64(header["warmup_rule"]["frames"], "warmup_rule.frames")
    if observed_warmups != declared_warmups:
        raise ProtocolError("warmup frame count does not match warmup_rule")
    retained_count = sum(frame["phase"] == "sample" for frame in frames)
    if retained_count != header["sample_count"]:
        raise ProtocolError("sample_count does not match retained samples")
    if expected_sample_frames is not None and retained_count != expected_sample_frames:
        raise ProtocolError("unexpected retained sample count")
    if not any(frame["phase"] == "sample" for frame in frames):
        raise ProtocolError("JSONL artifact contains no retained samples")
    previous_present_timestamp: int | None = None
    for frame in frames:
        timestamp = frame.get("present_timestamp_ns")
        if timestamp is None:
            continue
        if previous_present_timestamp is not None and timestamp <= previous_present_timestamp:
            raise ProtocolError("present timestamps must be strictly increasing")
        previous_present_timestamp = timestamp
    return ProcessBlock(
        path=artifact_path,
        header=header,
        frames=tuple(frames),
        sha256=sha256_file(artifact_path),
    )


def sha256_file(path: str | Path) -> str:
    digest = hashlib.sha256()
    artifact_path = Path(path)
    try:
        with artifact_path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        raise ProtocolError(f"cannot hash {artifact_path}: {exc}") from exc
    return digest.hexdigest()


def freeze_artifact(source: str | Path, destination: str | Path) -> str:
    source_path = Path(source)
    destination_path = Path(destination)
    if source_path.is_symlink() or not source_path.is_file():
        raise ProtocolError(f"artifact is not a regular file: {source_path}")
    destination_path.parent.mkdir(parents=True, exist_ok=True)
    if destination_path.exists() or destination_path.is_symlink():
        if destination_path.is_symlink() or not destination_path.is_file():
            raise ProtocolError(f"destination is not a regular file: {destination_path}")
        if sha256_file(source_path) != sha256_file(destination_path):
            raise ProtocolError(f"immutable artifact already differs: {destination_path}")
    else:
        try:
            shutil.copyfile(source_path, destination_path)
        except OSError as exc:
            raise ProtocolError(f"cannot copy artifact {source_path}: {exc}") from exc
    try:
        mode = source_path.stat().st_mode & ~0o222
        destination_path.chmod(mode)
    except OSError as exc:
        raise ProtocolError(f"cannot make artifact immutable: {destination_path}") from exc
    return sha256_file(destination_path)


def _immutable_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    if path.is_symlink():
        raise ProtocolError(f"immutable JSON path must not be a symlink: {path}")
    if path.exists():
        try:
            if not path.is_file() or path.read_bytes() != encoded:
                raise ProtocolError(f"immutable JSON already differs: {path}")
            path.chmod(0o444)
        except OSError as exc:
            raise ProtocolError(f"cannot verify immutable JSON {path}: {exc}") from exc
        return
    temporary = path.with_name(path.name + ".tmp")
    if temporary.exists() or temporary.is_symlink():
        raise ProtocolError(f"immutable JSON temporary path is not fresh: {temporary}")
    try:
        temporary.write_bytes(encoded)
        temporary.chmod(0o444)
        temporary.replace(path)
    except OSError as exc:
        raise ProtocolError(f"cannot write immutable JSON {path}: {exc}") from exc
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def parse_int(value: str) -> int:
    try:
        return int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid integer: {value}") from exc


def parse_bool(value: str) -> bool:
    lowered = value.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    raise argparse.ArgumentTypeError("expected true or false")


def p99_ns(values: list[int]) -> int:
    if not values:
        raise ProtocolError("p99 requires at least one sample")
    for value in values:
        _require_u64(value, "p99 sample")
    rank = (len(values) * 99 + 99) // 100
    return sorted(values)[rank - 1]


def within_120_fps_budget(duration_ns: int) -> bool:
    _require_u64(duration_ns, "duration_ns")
    return duration_ns * 120 <= 1_000_000_000


def presented_throughput_passes(interval_ns: list[int]) -> bool:
    if not interval_ns:
        raise ProtocolError("presented throughput requires intervals")
    for interval in interval_ns:
        _require_u64(interval, "present interval")
        if interval == 0:
            raise ProtocolError("present intervals must be positive")
    return len(interval_ns) * 1_000_000_000 >= 120 * sum(interval_ns)


def zero_failure_upper_bound(block_count: int, alpha: float = 0.05) -> float:
    if isinstance(block_count, bool) or not isinstance(block_count, int) or block_count <= 0:
        raise ProtocolError("block_count must be positive")
    if not math.isfinite(alpha) or not 0.0 < alpha < 1.0:
        raise ProtocolError("alpha must be between zero and one")
    return 1.0 - alpha ** (1.0 / block_count)


def qualifies(failed_blocks: list[bool]) -> bool:
    if len(failed_blocks) != QUALIFICATION_BLOCKS:
        raise ProtocolError("qualification requires exactly 300 blocks")
    if any(not isinstance(value, bool) for value in failed_blocks):
        raise ProtocolError("failed_blocks must contain booleans")
    return not any(failed_blocks) and zero_failure_upper_bound(QUALIFICATION_BLOCKS) < 0.01


def collect_qualification(
    block_count: int,
    collect: Callable[[int], bool],
) -> bool:
    if block_count != QUALIFICATION_BLOCKS:
        raise ProtocolError("qualification requires exactly 300 blocks")
    failed_blocks = [False] * block_count
    for block_id in range(block_count):
        failed_blocks[block_id] = bool(collect(block_id))
    return qualifies(failed_blocks)


def _median(values: list[int]) -> int:
    if not values:
        raise ProtocolError("median requires samples")
    ordered = sorted(values)
    lower = ordered[(len(ordered) - 1) // 2]
    upper = ordered[len(ordered) // 2]
    return (lower + upper) // 2


def _stable_triplet(values: Sequence[int], boundary: int) -> bool:
    if boundary < 360 or boundary > 2_160 or boundary % 120 != 0:
        raise ProtocolError("stability boundary is outside the calibration range")
    medians = [
        _median(list(values[boundary - 360 : boundary - 240])),
        _median(list(values[boundary - 240 : boundary - 120])),
        _median(list(values[boundary - 120 : boundary])),
    ]
    minimum = min(medians)
    maximum = max(medians)
    if minimum == 0:
        return maximum == 0
    return (maximum - minimum) * 100 <= minimum * 2


def sustained_stable_boundary(
    cpu_values: Sequence[int],
    gpu_values: Sequence[int] | None = None,
) -> int:
    if len(cpu_values) != CALIBRATION_FRAMES:
        raise ProtocolError("calibration requires exactly 2,400 diagnostic frames")
    if gpu_values is not None and len(gpu_values) != CALIBRATION_FRAMES:
        raise ProtocolError("GPU calibration requires exactly 2,400 diagnostic frames")
    boundaries = tuple(range(600, 2_161, 120))
    stable: list[bool] = []
    for boundary in boundaries:
        cpu_stable = _stable_triplet(cpu_values, boundary)
        gpu_stable = gpu_values is None or _stable_triplet(gpu_values, boundary)
        stable.append(cpu_stable and gpu_stable)
    for index, boundary in enumerate(boundaries):
        if all(stable[index:]):
            return boundary
    raise ProtocolError("no sustained stable calibration boundary")


def select_warmup_frames(boundaries: Sequence[int]) -> int:
    if not boundaries:
        raise ProtocolError("at least one stable boundary is required")
    latest = max(boundaries)
    if latest < 0:
        raise ProtocolError("stable boundary must be non-negative")
    return min(latest + 240, 2_400)


def calibration_scenes(scene: str | None) -> tuple[tuple[str, ...], bool]:
    if scene is None:
        return SCENES, True
    if scene not in SCENES:
        raise ProtocolError(f"unknown scene: {scene}")
    return (scene,), False


def balanced_cell_orders(
    cells: Sequence[str],
    *,
    block_count: int,
    seed: int,
    control: str,
) -> list[tuple[str, ...]]:
    if block_count <= 0:
        raise ProtocolError("block count must be positive")
    if not cells or len(set(cells)) != len(cells):
        raise ProtocolError("balanced cell order requires distinct cells")
    if control not in cells:
        raise ProtocolError("control cell is missing")
    rng = random.Random(seed)
    orders: list[tuple[str, ...]] = []
    for _ in range(block_count // 2):
        first = list(cells)
        rng.shuffle(first)
        orders.append(tuple(first))
        orders.append(tuple(reversed(first)))
    if block_count % 2:
        extra = list(cells)
        rng.shuffle(extra)
        orders.append(tuple(extra))
    return orders


def paired_block_orders(
    profiles: Sequence[str],
    *,
    block_count: int,
    seed: int,
) -> list[list[tuple[str, str]]]:
    if block_count <= 0:
        raise ProtocolError("block count must be positive")
    if tuple(profiles) != PAIR_PROFILES:
        raise ProtocolError("pair requires clean, gpu, and mechanism profiles")
    rng = random.Random(seed)
    orders: list[list[tuple[str, str]]] = []
    for block_id in range(block_count):
        profile_order = list(profiles)
        rng.shuffle(profile_order)
        order: list[tuple[str, str]] = []
        for profile in profile_order:
            first, second = (
                ("baseline", "candidate")
                if block_id % 2 == 0
                else ("candidate", "baseline")
            )
            order.extend(((profile, first), (profile, second)))
        orders.append(order)
    return orders


def capture_jj_identity(
    repository_root: str | Path,
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> dict[str, str]:
    root = Path(repository_root)
    command = ["jj", "log", "-r", "@", "-T", 'change_id ++ "\\n" ++ commit_id']
    try:
        result = runner(
            command,
            cwd=root,
            shell=False,
            check=False,
            capture_output=True,
            text=True,
            timeout=10.0,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ProtocolError(f"cannot inspect Jujutsu identity in {root}: {exc}") from exc
    if result.returncode != 0:
        raise ProtocolError(f"Jujutsu identity inspection failed in {root}")
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if len(lines) < 2:
        raise ProtocolError(f"Jujutsu identity output is incomplete in {root}")
    return {"change_id": lines[0], "commit_id": lines[1]}


def capture_jj_identities(
    nogui_root: str | Path,
    noapi_root: str | Path,
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> dict[str, dict[str, str]]:
    return {
        "nogui": capture_jj_identity(nogui_root, runner=runner),
        "noapi": capture_jj_identity(noapi_root, runner=runner),
    }


def _read_optional(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        return None


def _online_cpu_set() -> str:
    value = _read_optional(Path("/sys/devices/system/cpu/online"))
    if value is None or value == "unavailable":
        raise ProtocolError("online CPU set is unavailable")
    return value


def _cpu_model() -> str:
    cpuinfo = _read_optional(Path("/proc/cpuinfo"))
    if cpuinfo is not None:
        for line in cpuinfo.splitlines():
            if line.lower().startswith("model name") and ":" in line:
                model = line.split(":", 1)[1].strip()
                if model:
                    return model
    model = platform.processor()
    if not model:
        raise ProtocolError("CPU model is unavailable")
    return model


def _cpu_governor() -> str | None:
    governors = sorted(Path("/sys/devices/system/cpu").glob("cpu[0-9]*/cpufreq/scaling_governor"))
    if not governors:
        return None
    return _read_optional(governors[0])


def _gpu_driver(
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> tuple[str, str]:
    try:
        result = runner(
            ["lspci", "-nnk"],
            shell=False,
            check=False,
            capture_output=True,
            text=True,
            timeout=5.0,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ProtocolError("GPU/driver query failed") from exc
    if result.returncode != 0:
        raise ProtocolError("GPU/driver query failed")
    device: str | None = None
    driver: str | None = None
    in_display_device = False
    for line in result.stdout.splitlines():
        if "VGA compatible controller" in line or "3D controller" in line:
            device = line.strip()
            in_display_device = True
            continue
        if in_display_device and "Kernel driver in use:" in line:
            driver = line.split(":", 1)[1].strip()
            break
        if line and not line.startswith((" ", "\t")):
            in_display_device = False
    if not device or not driver:
        raise ProtocolError("GPU/driver query returned no display device")
    return device, driver
def capture_machine_identity(
    *,
    requested_affinity: Sequence[int] | None = None,
    extent: Mapping[str, int] | None = None,
    present_mode: str = "fifo",
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> dict[str, Any]:
    try:
        process_affinity = sorted(os.sched_getaffinity(0))
    except (AttributeError, OSError) as exc:
        raise ProtocolError("process affinity query failed") from exc
    if not process_affinity:
        raise ProtocolError("process affinity is empty")
    requested = sorted(set(
        requested_affinity if requested_affinity is not None else process_affinity
    ))
    if not requested:
        raise ProtocolError("requested affinity is empty")
    gpu, driver = _gpu_driver(runner=runner)
    identity = {
        "cpu_model": _cpu_model(),
        "online_cpu_set": _online_cpu_set(),
        "requested_affinity": requested,
        "process_affinity": process_affinity,
        "kernel": platform.release(),
        "cpu_governor": _cpu_governor(),
        "gpu": gpu,
        "driver": driver,
        "extent": dict(extent or {"width": PERF_WIDTH, "height": PERF_HEIGHT}),
        "present_mode": present_mode,
    }
    _validate_machine(identity, "captured machine")
    return identity


def _query_zig_version(
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> str:
    result = run_checked(["zig", "version"], timeout_s=10.0, runner=runner)
    versions = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if len(versions) != 1:
        raise ProtocolError("zig version query returned incomplete output")
    return _require_string(versions[0], "zig_version")
def _affinity_preexec(affinity: Sequence[int] | None) -> Callable[[], None] | None:
    if affinity is None:
        return None
    cpu_set = set(affinity)
    if not cpu_set:
        raise ProtocolError("requested affinity is empty")

    def apply() -> None:
        try:
            os.sched_setaffinity(0, cpu_set)
        except (AttributeError, OSError) as exc:
            raise RuntimeError("cannot apply requested affinity") from exc

    return apply




def run_checked(
    command: Sequence[str],
    *,
    timeout_s: float,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    cwd: str | Path | None = None,
    env: Mapping[str, str] | None = None,
    affinity: Sequence[int] | None = None,
) -> subprocess.CompletedProcess[str]:
    argv = [str(argument) for argument in command]
    if not argv or any(not argument for argument in argv):
        raise ProtocolError("finite subprocess requires a non-empty argv")
    try:
        result = runner(
            argv,
            cwd=cwd,
            env=env,
            shell=False,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_s,
            **({"preexec_fn": _affinity_preexec(affinity)} if affinity is not None else {}),
        )
    except subprocess.TimeoutExpired as exc:
        raise ProtocolError(f"subprocess timed out: {argv[0]}") from exc
    except (OSError, subprocess.SubprocessError, RuntimeError) as exc:
        raise ProtocolError(f"cannot start subprocess {argv[0]}: {exc}") from exc
    if result.returncode != 0:
        stderr = (result.stderr or "").strip()
        detail = f": {stderr}" if stderr else ""
        raise ProtocolError(f"subprocess failed ({result.returncode}): {argv[0]}{detail}")
    return result


def demo_argv(
    binary_path: str | Path,
    *,
    scene: str,
    mode: str,
    warmup_frames: int,
    sample_frames: int,
    output_path: str | Path,
) -> list[str]:
    if scene not in SCENES:
        raise ProtocolError(f"unknown scene: {scene}")
    if mode not in ("offscreen", "presented"):
        raise ProtocolError("mode must be offscreen or presented")
    if warmup_frames < 0 or sample_frames <= 0:
        raise ProtocolError("invalid frame counts")
    scene_flags = {
        "todo": (),
        "spotify": ("--spotify",),
        "calculator": ("--calculator",),
        "tiger": ("--tiger",),
        "strokes": ("--strokes",),
    }
    return [
        str(binary_path),
        *scene_flags[scene],
        "--perf-mode",
        mode,
        "--perf-warmup",
        str(warmup_frames),
        "--perf-frames",
        str(sample_frames),
        "--perf-out",
        str(output_path),
    ]


def _validate_machine(value: Any, name: str = "machine") -> dict[str, Any]:
    machine = _require_object(value, name)
    for field in ("cpu_model", "online_cpu_set", "kernel", "gpu", "driver", "present_mode"):
        _require_real_string(machine.get(field), f"{name}.{field}")
    _require_cpu_set(machine.get("requested_affinity"), f"{name}.requested_affinity")
    _require_cpu_set(machine.get("process_affinity"), f"{name}.process_affinity")
    extent = _require_object(machine.get("extent"), f"{name}.extent")
    width = _require_u64(extent.get("width"), f"{name}.extent.width")
    height = _require_u64(extent.get("height"), f"{name}.extent.height")
    if width != PERF_WIDTH or height != PERF_HEIGHT:
        raise ProtocolError(
            f"{name}.extent must be {PERF_WIDTH}x{PERF_HEIGHT}"
        )
    if machine["present_mode"] != PERF_PRESENT_MODE:
        raise ProtocolError(f"{name}.present_mode must be {PERF_PRESENT_MODE}")
    governor = machine.get("cpu_governor")
    if governor is not None:
        _require_real_string(governor, f"{name}.cpu_governor")
    return machine


def _manifest_machine(manifest: Mapping[str, Any]) -> dict[str, Any]:
    machine = manifest.get("machine")
    return _validate_machine(machine, "snapshot.machine")


def _confined_path(root: Path, relative: Any, name: str) -> Path:
    relative = _require_string(relative, name)
    relative_path = Path(relative)
    if (
        relative_path.is_absolute()
        or relative != relative_path.as_posix()
        or any(part in ("", ".", "..") for part in relative_path.parts)
    ):
        raise ProtocolError(f"{name} must be a normalized relative path")
    root_resolved = root.resolve()
    candidate = root / relative_path
    try:
        resolved = candidate.resolve(strict=False)
        resolved.relative_to(root_resolved)
    except (OSError, ValueError) as exc:
        raise ProtocolError(f"{name} escapes snapshot root") from exc
    current = root
    for part in relative_path.parts:
        current = current / part
        if current.is_symlink():
            raise ProtocolError(f"{name} must not use symlinks")
    return candidate

def _load_snapshot(path: str | Path) -> Snapshot:
    manifest_path = Path(path)
    if manifest_path.is_symlink():
        raise ProtocolError(f"snapshot manifest must not be a symlink: {manifest_path}")
    manifest = _require_object(_load_json(manifest_path), "snapshot manifest")
    required = (
        "schema_version",
        "profile",
        "optimize_mode",
        "instrumentation_flags",
        "binary",
        "runner_sha256",
        "shaders",
        "nogui",
        "noapi",
        "zig_version",
        "machine",
    )
    for field in required:
        if field not in manifest:
            raise ProtocolError(f"snapshot is missing {field}")
    if manifest["schema_version"] != SCHEMA_VERSION:
        raise ProtocolError("unsupported snapshot schema_version")
    profile = _require_string(manifest["profile"], "profile")
    if profile not in PROFILE_FLAGS:
        raise ProtocolError("unknown snapshot profile")
    flags = _validate_flags(manifest["instrumentation_flags"])
    if flags != PROFILE_FLAGS[profile]:
        raise ProtocolError("snapshot profile flags mismatch")
    _require_string(manifest["optimize_mode"], "optimize_mode")
    _require_string(manifest["zig_version"], "zig_version")
    binary = _require_object(manifest["binary"], "binary")
    binary_path = _confined_path(manifest_path.parent, binary.get("path"), "binary.path")
    _require_sha256(binary.get("sha256"), "binary.sha256")
    if not binary_path.is_file():
        raise ProtocolError(f"snapshot copied binary is missing: {binary_path}")
    if sha256_file(binary_path) != binary["sha256"]:
        raise ProtocolError(f"snapshot copied binary hash mismatch: {binary_path}")
    _require_sha256(manifest["runner_sha256"], "runner_sha256")
    shaders = _require_object(manifest["shaders"], "shaders")
    if set(shaders) != set(SHADER_FILES):
        raise ProtocolError("snapshot shader manifest is incomplete")
    for shader in SHADER_FILES:
        record = _require_object(shaders[shader], f"shaders.{shader}")
        shader_path = _confined_path(
            manifest_path.parent,
            record.get("path"),
            f"shaders.{shader}.path",
        )
        shader_hash = _require_sha256(record.get("sha256"), f"shaders.{shader}.sha256")
        if not shader_path.is_file():
            raise ProtocolError(f"snapshot copied shader is missing: {shader_path}")
        if sha256_file(shader_path) != shader_hash:
            raise ProtocolError(f"snapshot copied shader hash mismatch: {shader_path}")
    for identity_name in ("nogui", "noapi"):
        identity = _require_object(manifest[identity_name], identity_name)
        _require_string(identity.get("change_id"), f"{identity_name}.change_id")
        _require_string(identity.get("commit_id"), f"{identity_name}.commit_id")
    _validate_machine(manifest["machine"], "machine")
    return Snapshot(path=manifest_path, manifest=manifest)


def _machine_difference(left: Mapping[str, Any], right: Mapping[str, Any]) -> str | None:
    for field in MACHINE_FIELDS:
        if left.get(field) != right.get(field):
            return field
    return None


def validate_pair_manifests(
    paths: Mapping[str, tuple[str | Path, str | Path]],
) -> dict[str, tuple[Snapshot, Snapshot]]:
    if set(paths) != set(PAIR_PROFILES):
        missing = set(PAIR_PROFILES) - set(paths)
        if missing:
            raise ProtocolError(f"missing profile: {sorted(missing)[0]}")
        raise ProtocolError("pair contains unexpected profile")
    validated: dict[str, tuple[Snapshot, Snapshot]] = {}
    reference_machine: dict[str, Any] | None = None
    reference_shaders: dict[str, Any] | None = None
    for profile in PAIR_PROFILES:
        baseline_path, candidate_path = paths[profile]
        baseline = _load_snapshot(baseline_path)
        candidate = _load_snapshot(candidate_path)
        if baseline.manifest["profile"] != profile or candidate.manifest["profile"] != profile:
            raise ProtocolError(f"profile mismatch for {profile}")
        if baseline.manifest["instrumentation_flags"] != candidate.manifest["instrumentation_flags"]:
            raise ProtocolError(f"flags mismatch within {profile}")
        if baseline.manifest["optimize_mode"] != candidate.manifest["optimize_mode"]:
            raise ProtocolError(f"optimize mode mismatch within {profile}")
        baseline_hash = baseline.manifest["binary"]["sha256"]
        candidate_hash = candidate.manifest["binary"]["sha256"]
        if baseline_hash == candidate_hash:
            raise ProtocolError(f"baseline and candidate binaries are not distinct for {profile}")
        baseline_shaders = baseline.manifest["shaders"]
        candidate_shaders = candidate.manifest["shaders"]
        if baseline_shaders != candidate_shaders:
            raise ProtocolError(f"shader manifest mismatch within {profile}")
        machine = _manifest_machine(baseline.manifest)
        candidate_machine = _manifest_machine(candidate.manifest)
        difference = _machine_difference(machine, candidate_machine)
        if difference is not None:
            raise ProtocolError(f"machine identity mismatch within {profile}: {difference}")
        if reference_machine is None:
            reference_machine = machine
            reference_shaders = baseline_shaders
        else:
            difference = _machine_difference(machine, reference_machine)
            if difference is not None:
                raise ProtocolError(f"machine identity mismatch across {profile}: {difference}")
            if baseline_shaders != reference_shaders:
                raise ProtocolError(f"shader manifest mismatch across {profile}")
        validated[profile] = (baseline, candidate)
    return validated


def merge_final_header(
    snapshot_manifest: Mapping[str, Any],
    runtime_metadata: Mapping[str, Any],
    *,
    scene: str,
    mode: str,
    block_id: int,
    order_position: int,
    child_argv: Sequence[str],
    warmup_rule: Mapping[str, Any],
    seed: int,
    sample_count: int,
) -> dict[str, Any]:
    flags = _validate_flags(snapshot_manifest.get("instrumentation_flags"))
    binary = _require_object(snapshot_manifest.get("binary"), "binary")
    shaders = _require_object(snapshot_manifest.get("shaders"), "shaders")
    machine = dict(runtime_metadata)
    required_runtime = (
        "cpu_model",
        "online_cpu_set",
        "requested_affinity",
        "process_affinity",
        "kernel",
        "cpu_governor",
        "gpu",
        "driver",
        "extent",
        "present_mode",
        "reported_refresh_data",
        "present_feedback",
    )
    for field in required_runtime:
        if field not in machine:
            raise ProtocolError(f"runtime metadata is missing {field}")
    nogui = _require_object(snapshot_manifest.get("nogui"), "nogui")
    noapi = _require_object(snapshot_manifest.get("noapi"), "noapi")
    return {
        "schema_version": SCHEMA_VERSION,
        "scene": scene,
        "mode": mode,
        "optimize_mode": snapshot_manifest["optimize_mode"],
        "instrumentation_flags": flags,
        "block_id": block_id,
        "randomized_order_position": order_position,
        "child_argv": list(child_argv),
        "zig_version": _require_string(snapshot_manifest.get("zig_version"), "zig_version"),
        "binary_sha256": binary["sha256"],
        "runner_sha256": snapshot_manifest["runner_sha256"],
        "shader_hashes": {shader: shaders[shader]["sha256"] for shader in SHADER_FILES},
        "nogui_jj_change_id": nogui["change_id"],
        "nogui_jj_commit_id": nogui["commit_id"],
        "noapi_jj_change_id": noapi["change_id"],
        "noapi_jj_commit_id": noapi["commit_id"],
        **machine,
        "warmup_rule": dict(warmup_rule),
        "process_order_seed": seed,
        "sample_count": sample_count,
    }


def ensure_port_available(
    *,
    host: str = TRACY_HOST,
    port: int = TRACY_PORT,
) -> None:
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind((host, port))
        except OSError as exc:
            raise ProtocolError(f"Tracy port {port} is busy") from exc
    finally:
        probe.close()


def _terminate_child(child: Any) -> None:
    try:
        child.terminate()
    except (OSError, AttributeError):
        return
    try:
        child.wait(timeout=1.0)
    except (OSError, AttributeError, subprocess.TimeoutExpired):
        try:
            child.kill()
        except (OSError, AttributeError):
            return


def _remove_owned(path: Path) -> None:
    try:
        if path.exists() or path.is_symlink():
            path.unlink()
    except FileNotFoundError:
        pass

def _drain_capture_output(
    master_fd: int,
    startup_log: Path,
    stop: threading.Event,
) -> None:
    try:
        with startup_log.open("ab") as output:
            while not stop.is_set():
                try:
                    readable, _, _ = select.select([master_fd], [], [], 0.05)
                except (OSError, ValueError):
                    return
                if not readable:
                    continue
                try:
                    data = os.read(master_fd, 4096)
                except OSError:
                    return
                if not data:
                    return
                output.write(data)
                output.flush()
    except OSError:
        return



def _wait_for_capture_marker(
    capture: Any,
    startup_log: Path,
    marker: str,
    deadline: float,
    *,
    demo: Any | None = None,
) -> None:
    while True:
        try:
            startup = startup_log.read_text(encoding="utf-8", errors="replace")
        except FileNotFoundError:
            startup = ""
        if marker in startup:
            return
        capture_status = capture.poll()
        if capture_status is not None:
            if capture_status != 0:
                raise ProtocolError("Tracy capture exited before readiness")
            raise ProtocolError("Tracy capture exited without readiness")
        if demo is not None:
            demo_status = demo.poll()
            if demo_status is not None:
                raise ProtocolError("Tracy demo exited before readiness")
        if time.monotonic() >= deadline:
            raise ProtocolError("Tracy capture readiness timed out")
        time.sleep(0.01)


def run_tracy_capture(
    *,
    demo_argv: Sequence[str],
    trace_path: str | Path,
    csv_path: str | Path,
    sample_roots: int,
    process_timeout_s: float,
    export_timeout_s: float,
    requested_affinity: Sequence[int] | None = None,
    readiness_timeout_s: float = 5.0,
    popen_factory: Callable[..., Any] = subprocess.Popen,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    port_checker: Callable[..., None] = ensure_port_available,
    publish: bool = True,
) -> dict[str, Any]:
    if sample_roots <= 0:
        raise ProtocolError("Tracy capture requires positive sample roots")
    if process_timeout_s <= 0 or export_timeout_s <= 0 or readiness_timeout_s <= 0:
        raise ProtocolError("Tracy timeouts must be positive")
    trace = Path(trace_path)
    csv_artifact = Path(csv_path)
    trace_temporary = trace.with_name(trace.name + ".partial")
    csv_temporary = csv_artifact.with_name(csv_artifact.name + ".partial")
    startup_log = trace.with_name(trace.name + ".startup.partial")
    all_artifacts = (
        trace,
        csv_artifact,
        trace_temporary,
        csv_temporary,
        startup_log,
    )
    for artifact in all_artifacts:
        if artifact.exists() or artifact.is_symlink():
            raise ProtocolError(f"Tracy artifact path is not fresh: {artifact}")
    trace.parent.mkdir(parents=True, exist_ok=True)
    csv_artifact.parent.mkdir(parents=True, exist_ok=True)
    port_checker(host=TRACY_HOST, port=TRACY_PORT)
    capture_argv = [
        "tracy-capture",
        "-o",
        str(trace_temporary),
        "-a",
        TRACY_HOST,
        "-p",
        str(TRACY_PORT),
        "-f",
    ]
    preexec = _affinity_preexec(requested_affinity)
    popen_options: dict[str, Any] = {
        "shell": False,
        "stderr": subprocess.DEVNULL,
        "text": True,
    }
    if preexec is not None:
        popen_options["preexec_fn"] = preexec
    children: list[Any] = []
    published: list[Path] = []
    master_fd: int | None = None
    slave_fd: int | None = None
    reader_stop: threading.Event | None = None
    reader_thread: threading.Thread | None = None
    try:
        master_fd, slave_fd = os.openpty()
        os.set_blocking(master_fd, False)
        startup_log.touch()
        reader_stop = threading.Event()
        reader_thread = threading.Thread(
            target=_drain_capture_output,
            args=(master_fd, startup_log, reader_stop),
            daemon=True,
        )
        reader_thread.start()
        popen_options["stdout"] = slave_fd
        children.append(popen_factory(capture_argv, **popen_options))
        os.close(slave_fd)
        slave_fd = None
        deadline = time.monotonic() + readiness_timeout_s
        capture = children[0]
        _wait_for_capture_marker(
            capture,
            startup_log,
            "Connecting to ",
            deadline,
        )
        popen_options["stdout"] = subprocess.DEVNULL
        demo = popen_factory(list(demo_argv), **popen_options)
        children.append(demo)
        _wait_for_capture_marker(
            capture,
            startup_log,
            "Timer resolution:",
            deadline,
            demo=demo,
        )
        for index, child in enumerate(children):
            try:
                returncode = child.wait(timeout=process_timeout_s)
            except subprocess.TimeoutExpired as exc:
                raise ProtocolError(
                    f"Tracy {'capture' if index == 0 else 'demo'} timed out"
                ) from exc
            if returncode != 0:
                raise ProtocolError(
                    f"Tracy {'capture' if index == 0 else 'demo'} failed"
                )
        if not trace_temporary.is_file() or trace_temporary.is_symlink():
            raise ProtocolError(f"Tracy capture did not produce {trace_temporary}")
        trace_temporary.chmod(0o444)
        export_argv = ["tracy-csvexport", "-u", str(trace_temporary)]
        with csv_temporary.open("w", encoding="utf-8", newline="") as output:
            try:
                result = runner(
                    export_argv,
                    shell=False,
                    check=False,
                    stdout=output,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    timeout=export_timeout_s,
                )
            except subprocess.TimeoutExpired as exc:
                raise ProtocolError("tracy-csvexport timed out") from exc
            except OSError as exc:
                raise ProtocolError(f"cannot start tracy-csvexport: {exc}") from exc
        if result.returncode != 0:
            raise ProtocolError("tracy-csvexport failed")
        if not csv_temporary.is_file() or csv_temporary.is_symlink():
            raise ProtocolError("tracy-csvexport did not produce CSV")
        csv_temporary.chmod(0o444)
        summary = parse_tracy_csv(
            csv_temporary,
            expected_sample_roots=sample_roots,
        )
        evidence = {
            "trace_path": str(trace),
            "csv_path": str(csv_artifact),
            "trace_temporary_path": str(trace_temporary),
            "csv_temporary_path": str(csv_temporary),
            "trace_sha256": sha256_file(trace_temporary),
            "csv_sha256": sha256_file(csv_temporary),
            "summary": summary,
        }
        if publish:
            trace_temporary.replace(trace)
            published.append(trace)
            csv_temporary.replace(csv_artifact)
            published.append(csv_artifact)
        return evidence
    except (OSError, ProtocolError, RuntimeError, TypeError, ValueError):
        for child in children:
            _terminate_child(child)
        for artifact in all_artifacts:
            _remove_owned(artifact)
        for artifact in published:
            _remove_owned(artifact)
        raise
    finally:
        if reader_stop is not None:
            reader_stop.set()
        if slave_fd is not None:
            try:
                os.close(slave_fd)
            except OSError:
                pass
        if master_fd is not None:
            try:
                os.close(master_fd)
            except OSError:
                pass
        if reader_thread is not None:
            reader_thread.join(timeout=1.0)
        _remove_owned(startup_log)


def _csv_int(value: str, name: str) -> int:
    try:
        parsed = int(value, 10)
    except (TypeError, ValueError) as exc:
        raise ProtocolError(f"Tracy {name} is not an integer") from exc
    return _require_u64(parsed, f"Tracy {name}")


def _zone_stat(durations: list[int], self_durations: list[int]) -> dict[str, int]:
    return {
        "call_count": len(durations),
        "inclusive_ns": sum(durations),
        "self_ns": sum(self_durations),
        "median_ns": _median(durations),
        "p99_ns": p99_ns(durations),
    }


def parse_tracy_csv(
    path: str | Path,
    *,
    expected_sample_roots: int,
) -> dict[str, Any]:
    if expected_sample_roots <= 0:
        raise ProtocolError("Tracy sample root count must be positive")
    events: list[dict[str, Any]] = []
    try:
        with Path(path).open("r", encoding="utf-8", newline="") as source:
            reader = csv.DictReader(source)
            required = {"name", "ns_since_start", "exec_time_ns", "thread"}
            if reader.fieldnames is None or not required.issubset(reader.fieldnames):
                raise ProtocolError("Tracy CSV is missing event columns")
            for row_number, row in enumerate(reader, start=2):
                name = _require_string(row.get("name"), f"Tracy name on row {row_number}")
                start = _csv_int(row.get("ns_since_start", ""), f"start on row {row_number}")
                duration = _csv_int(row.get("exec_time_ns", ""), f"duration on row {row_number}")
                thread = _csv_int(row.get("thread", ""), f"thread on row {row_number}")
                if duration == 0:
                    raise ProtocolError(f"Tracy event on row {row_number} has zero duration")
                if duration > U64_MAX - start:
                    raise ProtocolError("Tracy interval overflows u64")
                events.append({"name": name, "start": start, "end": start + duration, "duration": duration, "thread": thread})
    except (OSError, UnicodeError) as exc:
        raise ProtocolError(f"cannot read Tracy CSV {path}: {exc}") from exc
    roots = [event for event in events if event["name"] == "perfSampleFrame"]
    if len(roots) != expected_sample_roots:
        raise ProtocolError("Tracy CSV has the wrong number of sample roots")
    roots.sort(key=lambda event: (event["start"], event["end"]))
    for previous, current in zip(roots, roots[1:]):
        if current["start"] < previous["end"]:
            raise ProtocolError("Tracy sample roots overlap")
    included: list[dict[str, Any]] = []
    for event in events:
        if event["name"] in ("perfSampleFrame", "perfWarmupFrame"):
            continue
        containing = [root for root in roots if root["start"] <= event["start"] and event["end"] <= root["end"]]
        intersects = [root for root in roots if event["start"] < root["end"] and root["start"] < event["end"]]
        if intersects and not containing:
            raise ProtocolError("Tracy child interval crosses a sample root boundary")
        if containing:
            included.append(event)
    self_by_event: dict[int, int] = {}
    for index, event in enumerate(included):
        direct_children: list[dict[str, Any]] = []
        for child_index, child in enumerate(included):
            if index == child_index or child["thread"] != event["thread"]:
                continue
            if event["start"] <= child["start"] and child["end"] <= event["end"]:
                has_intermediate = False
                for intermediate_index, intermediate in enumerate(included):
                    if intermediate_index in (index, child_index):
                        continue
                    if intermediate["thread"] != event["thread"]:
                        continue
                    if (
                        event["start"] <= intermediate["start"]
                        and intermediate["end"] <= event["end"]
                        and intermediate["start"] <= child["start"]
                        and child["end"] <= intermediate["end"]
                    ):
                        has_intermediate = True
                        break
                if not has_intermediate:
                    direct_children.append(child)
        child_time = sum(child["duration"] for child in direct_children)
        if child_time > event["duration"]:
            raise ProtocolError("Tracy child time exceeds parent duration")
        self_by_event[index] = event["duration"] - child_time
    durations_by_name: dict[str, list[int]] = {}
    self_durations_by_name: dict[str, list[int]] = {}
    for index, event in enumerate(included):
        durations_by_name.setdefault(event["name"], []).append(event["duration"])
        self_durations_by_name.setdefault(event["name"], []).append(self_by_event[index])
    return {
        "sample_root_count": len(roots),
        "zones": {
            name: _zone_stat(durations_by_name[name], self_durations_by_name[name])
            for name in sorted(durations_by_name)
        },
    }


def _project_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _snapshot_binary_source(
    args: argparse.Namespace,
    project_root: Path,
    output_root: Path,
    profile: str,
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> Path:
    profile_flags = PROFILE_FLAGS[profile]
    build_root = output_root / "build" / profile
    if getattr(args, "binary", None) is not None:
        raise ProtocolError("binary overrides are forbidden; build the requested profile")
    if build_root.exists():
        raise ProtocolError(f"profile build root is not fresh: {build_root}")
    build_command = [
        "zig",
        "build",
        "install",
        "--prefix",
        str(build_root),
        f"-Doptimize={args.optimize}",
        f"-Dv7-tracy={'true' if profile_flags['tracy'] else 'false'}",
        f"-Dv7-gpu-timestamps={'true' if profile_flags['gpu_timestamps'] else 'false'}",
        f"-Dv7-perf-counters={'true' if profile_flags['perf_counters'] else 'false'}",
    ]
    run_checked(
        build_command,
        timeout_s=getattr(args, "build_timeout", 900.0),
        cwd=project_root,
        runner=runner,
    )
    source = build_root / "bin" / "v7-demo"
    if not source.is_file():
        raise ProtocolError(f"v7-demo executable is missing: {source}")
    return source

def _snapshot_manifest(
    args: argparse.Namespace,
    out: Path,
    project_root: Path,
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> Snapshot:
    if out.is_symlink():
        raise ProtocolError(f"snapshot output must not be a symlink: {out}")
    if out.exists() and any(out.iterdir()):
        raise ProtocolError(f"snapshot output is not fresh: {out}")
    profile = profile_for_flags({
        "tracy": args.tracy,
        "gpu_timestamps": args.gpu_timestamps,
        "perf_counters": args.perf_counters,
    })
    source = _snapshot_binary_source(args, project_root, out, profile, runner=runner)
    out.mkdir(parents=True, exist_ok=True)
    copied_binary = out / "v7-demo"
    binary_hash = freeze_artifact(source, copied_binary)
    shader_records: dict[str, dict[str, str]] = {}
    for shader_name in SHADER_FILES:
        shader_source = project_root / "shaders" / shader_name
        if not shader_source.is_file():
            raise ProtocolError(f"required shader is missing: {shader_source}")
        shader_destination = out / "shaders" / shader_name
        shader_hash = freeze_artifact(shader_source, shader_destination)
        shader_records[shader_name] = {
            "path": f"shaders/{shader_name}",
            "sha256": shader_hash,
        }
    runner_hash = sha256_file(Path(__file__))
    nogui_root = Path(getattr(args, "nogui_root", None) or project_root)
    noapi_root = Path(getattr(args, "noapi_root", None) or project_root.parent / "noapi")
    jj_identities = capture_jj_identities(nogui_root, noapi_root, runner=runner)
    for field, expected in (
        ("width", PERF_WIDTH),
        ("height", PERF_HEIGHT),
        ("present_mode", PERF_PRESENT_MODE),
    ):
        if hasattr(args, field) and getattr(args, field) != expected:
            raise ProtocolError(f"{field} is fixed at {expected}")
    machine = capture_machine_identity(
        requested_affinity=getattr(args, "affinity", None),
        extent={"width": PERF_WIDTH, "height": PERF_HEIGHT},
        present_mode=PERF_PRESENT_MODE,
        runner=runner,
    )
    zig_version = _query_zig_version(runner=runner)
    declared_zig_version = getattr(args, "zig_version", None)
    if declared_zig_version is not None and declared_zig_version != zig_version:
        raise ProtocolError("requested Zig version does not match queried version")
    manifest: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "profile": profile,
        "scene": args.scene,
        "mode": args.mode,
        "optimize_mode": args.optimize,
        "instrumentation_flags": PROFILE_FLAGS[profile],
        "binary": {"path": copied_binary.name, "sha256": binary_hash},
        "runner_sha256": runner_hash,
        "shaders": shader_records,
        "nogui": jj_identities["nogui"],
        "noapi": jj_identities["noapi"],
        "zig_version": zig_version,
        "machine": machine,
    }
    manifest_path = out / "snapshot.json"
    _immutable_json(manifest_path, manifest)
    return _load_snapshot(manifest_path)


def _load_warmup(path: str | Path) -> dict[str, Any]:
    manifest_path = Path(path)
    if manifest_path.is_symlink():
        raise ProtocolError(f"warm-up manifest must not be a symlink: {manifest_path}")
    manifest = _require_object(_load_json(manifest_path), "warm-up manifest")
    if manifest.get("schema_version") != SCHEMA_VERSION:
        raise ProtocolError("unsupported warm-up manifest schema_version")
    if manifest.get("acceptance") is not True:
        raise ProtocolError("warm-up manifest is not an acceptance calibration")
    mode = manifest.get("mode")
    if mode not in ("offscreen", "presented"):
        raise ProtocolError("warm-up manifest mode is invalid")
    diagnostic_frames = _require_u64(manifest.get("diagnostic_frames"), "diagnostic_frames")
    if diagnostic_frames != CALIBRATION_FRAMES:
        raise ProtocolError("warm-up manifest requires exactly 2,400 diagnostic frames")
    warmup_frames = _require_u64(manifest.get("warmup_frames"), "warmup_frames")
    if warmup_frames == 0 or warmup_frames > CALIBRATION_FRAMES:
        raise ProtocolError("warmup_frames must be between one and 2,400")
    seed = _require_u64(manifest.get("seed"), "warm-up seed")
    diagnostics = _require_object(manifest.get("diagnostics"), "diagnostics")
    if set(diagnostics) != set(SCENES):
        raise ProtocolError("warm-up diagnostics must cover all five scenes")
    hashes = _require_object(manifest.get("diagnostic_hashes"), "diagnostic_hashes")
    expected_hashes: dict[str, str] = {}
    expected_boundaries: list[int] = []
    expected_orders: dict[str, list[str]] = {}
    diagnostic_blocks: dict[tuple[str, str], Path] = {}
    for scene in SCENES:
        diagnostic = _require_object(diagnostics[scene], f"diagnostics.{scene}")
        order = _require_string_list(diagnostic.get("order"), f"diagnostics.{scene}.order")
        if set(order) != {"clean", "gpu"} or len(order) != 2:
            raise ProtocolError(f"diagnostics.{scene}.order must contain clean and gpu")
        expected_orders[scene] = order
        expected_boundaries.append(
            _require_u64(diagnostic.get("boundary"), f"diagnostics.{scene}.boundary")
        )
        for profile in ("clean", "gpu"):
            descriptor = _require_object(
                diagnostic.get(profile),
                f"diagnostics.{scene}.{profile}",
            )
            relative = _require_string(descriptor.get("path"), "diagnostic artifact path")
            digest = _require_sha256(
                descriptor.get("sha256"),
                f"diagnostics.{scene}.{profile}.sha256",
            )
            confined = _confined_path(
                manifest_path.parent,
                relative,
                "diagnostic artifact path",
            )
            normalized = confined.relative_to(manifest_path.parent).as_posix()
            if normalized in expected_hashes:
                raise ProtocolError("warm-up diagnostics reuse an artifact path")
            expected_hashes[normalized] = digest
            diagnostic_blocks[(scene, profile)] = confined
    declared_hashes: dict[str, str] = {}
    for name, digest in hashes.items():
        confined = _confined_path(
            manifest_path.parent,
            name,
            "diagnostic artifact name",
        )
        normalized = confined.relative_to(manifest_path.parent).as_posix()
        if normalized in declared_hashes:
            raise ProtocolError("warm-up diagnostic hashes reuse an artifact path")
        declared_hashes[normalized] = _require_sha256(
            digest,
            f"diagnostic_hashes.{name}",
        )
    if declared_hashes != expected_hashes:
        raise ProtocolError("warm-up diagnostic hash manifest does not match descriptors")
    actual_boundaries: list[int] = []
    parsed_blocks: dict[tuple[str, str], ProcessBlock] = {}
    common_machine: dict[str, Any] | None = None
    for scene in SCENES:
        for profile in ("clean", "gpu"):
            artifact = diagnostic_blocks[(scene, profile)]
            if not artifact.is_file() or artifact.is_symlink():
                raise ProtocolError(f"diagnostic artifact is missing: {artifact}")
            relative = artifact.relative_to(manifest_path.parent).as_posix()
            if sha256_file(artifact) != expected_hashes[relative]:
                raise ProtocolError(f"diagnostic artifact hash mismatch: {artifact}")
            block = parse_process_jsonl(
                artifact,
                expected_profile=profile,
                expected_mode=mode,
                expected_scene=scene,
                expected_sample_frames=diagnostic_frames,
            )
            header = block.header
            if header["warmup_rule"] != {"frames": 0, "kind": "calibration"}:
                raise ProtocolError("diagnostic header must use zero-warmup calibration rule")
            if header["process_order_seed"] != seed:
                raise ProtocolError("diagnostic header seed does not match warm-up manifest")
            if header["randomized_order_position"] != expected_orders[scene].index(profile):
                raise ProtocolError("diagnostic header order does not match warm-up manifest")
            machine = _validate_machine(
                {field: header[field] for field in MACHINE_FIELDS},
                f"diagnostic.{scene}.{profile}.machine",
            )
            if machine["process_affinity"] != machine["requested_affinity"]:
                raise ProtocolError("diagnostic affinity does not match requested affinity")
            if common_machine is None:
                common_machine = machine
            else:
                for field in MACHINE_FIELDS:
                    if machine[field] != common_machine[field]:
                        raise ProtocolError(f"diagnostic machine identity mismatch: {field}")
            parsed_blocks[(scene, profile)] = block
    for scene in SCENES:
        clean_block = parsed_blocks[(scene, "clean")]
        gpu_block = parsed_blocks[(scene, "gpu")]
        actual_boundaries.append(
            sustained_stable_boundary(
                _sample_values(clean_block, "cpu_compute_ns"),
                _sample_values(gpu_block, "gpu_execute_ns"),
            )
        )
    if actual_boundaries != expected_boundaries:
        raise ProtocolError("warm-up diagnostic boundary mismatch")
    if select_warmup_frames(actual_boundaries) != warmup_frames:
        raise ProtocolError("warm-up frame selection does not match diagnostics")
    return manifest


def _validate_runtime_header(
    value: Any,
    *,
    expected_profile: str,
    expected_scene: str,
    expected_mode: str,
    expected_argv: Sequence[str],
    expected_warmup_frames: int,
    expected_sample_count: int,
) -> dict[str, Any]:
    runtime = _require_object(value, "runtime JSONL header")
    missing = [field for field in CHILD_RUNTIME_FIELDS if field not in runtime]
    if missing:
        raise ProtocolError(f"runtime header is missing {missing[0]}")
    if runtime["scene"] != expected_scene:
        raise ProtocolError("child scene does not match requested scene")
    if runtime["mode"] != expected_mode:
        raise ProtocolError("child mode does not match requested mode")
    flags = _validate_flags(runtime["instrumentation_flags"], "runtime.instrumentation_flags")
    if flags != PROFILE_FLAGS[expected_profile]:
        raise ProtocolError("child instrumentation flags do not match snapshot profile")
    child_argv = _require_string_list(runtime["child_argv"], "runtime.child_argv")
    if child_argv != list(expected_argv):
        raise ProtocolError("child argv does not match requested argv")
    machine = {field: runtime[field] for field in MACHINE_FIELDS}
    _validate_machine(machine, "runtime")
    if machine["process_affinity"] != machine["requested_affinity"]:
        raise ProtocolError("child process affinity does not match requested affinity")
    refresh = runtime["reported_refresh_data"]
    if refresh is not None:
        _require_object(refresh, "runtime.reported_refresh_data")
    present_feedback = _require_bool(runtime["present_feedback"], "runtime.present_feedback")
    observed_warmup_frames = _require_u64(runtime["warmup_frames"], "runtime.warmup_frames")
    if observed_warmup_frames != expected_warmup_frames:
        raise ProtocolError("child warm-up count does not match requested warm-up")
    if runtime["sample_count"] != expected_sample_count:
        raise ProtocolError("child sample count does not match requested sample count")
    _require_u64(runtime["sample_count"], "runtime.sample_count")
    return machine | {
        "reported_refresh_data": refresh,
        "present_feedback": present_feedback,
    }


def _machine_for_snapshot(snapshot: Snapshot) -> dict[str, Any]:
    return _manifest_machine(snapshot.manifest)

def _assert_machine_unchanged(expected: Mapping[str, Any], current: Mapping[str, Any]) -> None:
    for field in MACHINE_FIELDS:
        if expected.get(field) != current.get(field):
            raise ProtocolError(f"machine identity changed during pair: {field}")



def _run_demo_block(
    snapshot: Snapshot,
    *,
    scene: str,
    mode: str,
    warmup_frames: int,
    sample_frames: int,
    block_id: int,
    order_position: int,
    seed: int,
    out: Path,
    expected_identity: Mapping[str, Any] | None = None,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    identity_runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    warmup_rule: Mapping[str, Any] | None = None,
    artifact_variant: str | None = None,
) -> ProcessBlock:
    profile = snapshot.manifest["profile"]
    if warmup_rule is None:
        if warmup_frames == 0:
            warmup_rule = {"frames": 0, "kind": "calibration"}
        else:
            raise ProtocolError("acceptance block requires a frozen warm-up rule")
    if warmup_rule.get("frames") != warmup_frames:
        raise ProtocolError("warm-up rule does not match requested frame count")
    label = f"{block_id:04d}-{order_position:04d}"
    if artifact_variant is not None:
        if not artifact_variant or any(
            character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
            for character in artifact_variant
        ):
            raise ProtocolError("artifact variant is not a safe path component")
        label += f"-{artifact_variant}"
    out.mkdir(parents=True, exist_ok=True)
    final_path = out / "raw" / f"{scene}-{profile}-{mode}-{label}.jsonl"
    launch_path = final_path.with_name(final_path.name + ".partial")
    writing_path = final_path.with_name(final_path.name + ".writing")
    if any(path.exists() or path.is_symlink() for path in (final_path, launch_path, writing_path)):
        raise ProtocolError(f"raw artifact path is not fresh: {final_path}")
    argv = demo_argv(
        snapshot.path.parent / snapshot.manifest["binary"]["path"],
        scene=scene,
        mode=mode,
        warmup_frames=warmup_frames,
        sample_frames=sample_frames,
        output_path=launch_path,
    )
    expected_affinity = _manifest_machine(snapshot.manifest)["requested_affinity"]
    if expected_identity is not None:
        before = capture_machine_identity(
            requested_affinity=expected_identity["requested_affinity"],
            extent=expected_identity["extent"],
            present_mode=expected_identity["present_mode"],
            runner=identity_runner,
        )
        _assert_machine_unchanged(expected_identity, before)
    trace: TraceEvidence | None = None
    tracy_temporary: tuple[Path, Path] | None = None
    published: list[Path] = []
    try:
        if profile == "tracy":
            trace_path = out / "tracy" / f"{scene}-{profile}-{mode}-{label}.tracy"
            csv_path = out / "tracy" / f"{scene}-{profile}-{mode}-{label}.csv"
            evidence = run_tracy_capture(
                demo_argv=argv,
                trace_path=trace_path,
                csv_path=csv_path,
                sample_roots=sample_frames,
                process_timeout_s=600.0,
                export_timeout_s=120.0,
                requested_affinity=expected_affinity,
                runner=runner,
                publish=False,
            )
            trace = TraceEvidence(
                trace_path=Path(evidence["trace_path"]),
                csv_path=Path(evidence["csv_path"]),
                trace_sha256=evidence["trace_sha256"],
                csv_sha256=evidence["csv_sha256"],
                summary=evidence["summary"],
            )
            tracy_temporary = (
                Path(evidence["trace_temporary_path"]),
                Path(evidence["csv_temporary_path"]),
            )
        else:
            run_checked(
                argv,
                timeout_s=600.0,
                runner=runner,
                affinity=expected_affinity,
            )
        if not launch_path.is_file() or launch_path.is_symlink():
            raise ProtocolError(f"child did not create a fresh raw artifact: {launch_path}")
        records = _load_jsonl_records(launch_path)
        runtime_metadata = _validate_runtime_header(
            records[0],
            expected_profile=profile,
            expected_scene=scene,
            expected_mode=mode,
            expected_argv=argv,
            expected_warmup_frames=warmup_frames,
            expected_sample_count=sample_frames,
        )
        merged_header = merge_final_header(
            snapshot.manifest,
            runtime_metadata,
            scene=scene,
            mode=mode,
            block_id=block_id,
            order_position=order_position,
            child_argv=argv,
            warmup_rule=warmup_rule,
            seed=seed,
            sample_count=sample_frames,
        )
        encoded = "".join(
            json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n"
            for record in [merged_header, *records[1:]]
        ).encode()
        parse_identity = None
        if expected_identity is not None:
            parse_identity = dict(expected_identity)
            parse_identity["process_affinity"] = parse_identity["requested_affinity"]
            after = capture_machine_identity(
                requested_affinity=expected_identity["requested_affinity"],
                extent=expected_identity["extent"],
                present_mode=expected_identity["present_mode"],
                runner=identity_runner,
            )
            _assert_machine_unchanged(expected_identity, after)
        if writing_path.exists() or writing_path.is_symlink():
            raise ProtocolError(f"final artifact path is not fresh: {final_path}")
        writing_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            writing_path.write_bytes(encoded)
            writing_path.chmod(0o444)
            validated = parse_process_jsonl(
                writing_path,
                expected_identity=parse_identity,
                expected_profile=profile,
                expected_mode=mode,
                expected_scene=scene,
                expected_sample_frames=sample_frames,
            )
        except OSError as exc:
            raise ProtocolError(f"cannot publish process artifact {final_path}: {exc}") from exc
        try:
            if tracy_temporary is not None:
                for temporary, final in (
                    (tracy_temporary[0], trace.trace_path),
                    (tracy_temporary[1], trace.csv_path),
                ):
                    if temporary != final:
                        temporary.replace(final)
                    published.append(final)
            launch_path.unlink()
            writing_path.replace(final_path)
            published.append(final_path)
        except OSError as exc:
            raise ProtocolError(f"cannot publish process artifact {final_path}: {exc}") from exc
    except (OSError, TypeError, ValueError) as exc:
        for artifact in published:
            _remove_owned(artifact)
        _remove_owned(launch_path)
        _remove_owned(writing_path)
        if tracy_temporary is not None:
            for artifact in tracy_temporary:
                _remove_owned(artifact)
        raise ProtocolError(f"cannot publish process artifact {final_path}: {exc}") from exc
    except ProtocolError:
        for artifact in published:
            _remove_owned(artifact)
        _remove_owned(launch_path)
        _remove_owned(writing_path)
        if tracy_temporary is not None:
            for artifact in tracy_temporary:
                _remove_owned(artifact)
        raise
    return ProcessBlock(
        path=final_path,
        header=validated.header,
        frames=validated.frames,
        sha256=validated.sha256,
        trace=trace,
    )


def _sample_values(block: ProcessBlock, name: str) -> list[int]:
    values: list[int] = []
    for sample in block.samples:
        value = sample.get(name)
        if value is None:
            raise ProtocolError(f"sample is missing {name}")
        values.append(_require_u64(value, name))
    return values
def _delayed_values(block: ProcessBlock, name: str) -> list[int]:
    values = [
        _require_u64(sample[name], name)
        for sample in block.samples
        if sample.get(name) is not None
    ]
    if not values:
        raise ProtocolError(f"sample is missing {name}")
    return values


def _diagnostic_descriptor(block: ProcessBlock, root: Path) -> dict[str, str]:
    try:
        relative = block.path.relative_to(root).as_posix()
    except ValueError as exc:
        raise ProtocolError(f"diagnostic path escapes calibration root: {block.path}") from exc
    return {"path": relative, "sha256": block.sha256}




def _block_summary(block: ProcessBlock) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "path": str(block.path),
        "sha256": block.sha256,
        "sample_count": len(block.samples),
        "cpu_compute_p99_ns": p99_ns(_sample_values(block, "cpu_compute_ns")),
    }
    if any(sample.get("gpu_execute_ns") is not None for sample in block.samples):
        summary["gpu_execute_p99_ns"] = p99_ns(_sample_values(block, "gpu_execute_ns"))
    if any(sample.get("gpu_end_interval_ns") is not None for sample in block.samples):
        summary["gpu_end_interval_p99_ns"] = p99_ns(_delayed_values(block, "gpu_end_interval_ns"))
    if any(sample.get("present_interval_ns") is not None for sample in block.samples):
        intervals = _delayed_values(block, "present_interval_ns")
        summary["present_interval_p99_ns"] = p99_ns(intervals)
        summary["presented_throughput_pass"] = presented_throughput_passes(intervals)
    if block.trace is not None:
        summary["tracy"] = {
            "trace_path": str(block.trace.trace_path),
            "csv_path": str(block.trace.csv_path),
            "trace_sha256": block.trace.trace_sha256,
            "csv_sha256": block.trace.csv_sha256,
            "summary": block.trace.summary,
        }
    return summary


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Fixed v7 performance measurement protocol")
    subparsers = parser.add_subparsers(dest="command", required=True)

    snapshot = subparsers.add_parser("snapshot")
    snapshot.add_argument("--optimize", default="Debug")
    snapshot.add_argument("--tracy", type=parse_bool, required=True)
    snapshot.add_argument("--gpu-timestamps", type=parse_bool, required=True)
    snapshot.add_argument("--perf-counters", type=parse_bool, required=True)
    snapshot.add_argument("--scene", choices=SCENES, default="todo")
    snapshot.add_argument("--mode", choices=("offscreen", "presented"), default="offscreen")
    snapshot.add_argument("--nogui-root", type=Path)
    snapshot.add_argument("--out", type=Path, required=True)
    snapshot.add_argument("--noapi-root", type=Path)
    snapshot.add_argument("--affinity", type=parse_cpu_list)
    snapshot.add_argument("--zig-version")
    snapshot.add_argument("--build-timeout", type=float, default=900.0)

    calibrate = subparsers.add_parser("calibrate")
    calibrate.add_argument("--frames", type=int, default=CALIBRATION_FRAMES)
    calibrate.add_argument("--seed", type=parse_int, required=True)
    calibrate.add_argument("--out", type=Path, required=True)
    calibrate.add_argument("--scene", choices=SCENES)
    calibrate.add_argument("--diagnostic", action="store_true")
    calibrate.add_argument("--mode", choices=("offscreen", "presented"), default="offscreen")
    calibrate.add_argument("--nogui-root", type=Path)
    calibrate.add_argument("--noapi-root", type=Path)
    calibrate.add_argument("--affinity", type=parse_cpu_list)
    calibrate.add_argument("--zig-version")

    matrix = subparsers.add_parser("matrix")
    matrix.add_argument("--warmup-from", type=Path, required=True)
    matrix.add_argument("--blocks", type=int, required=True)
    matrix.add_argument("--frames", type=int, required=True)
    matrix.add_argument("--seed", type=parse_int, required=True)
    matrix.add_argument("--report", type=Path, required=True)
    matrix.add_argument("--out", type=Path, required=True)
    matrix.add_argument("--mode", choices=("offscreen", "presented"), default="offscreen")
    pair = subparsers.add_parser("pair")
    for profile in PAIR_PROFILES:
        pair.add_argument(f"--baseline-{profile}-manifest", type=Path, required=True)
        pair.add_argument(f"--candidate-{profile}-manifest", type=Path, required=True)
    pair.add_argument("--warmup-from", type=Path, required=True)
    pair.add_argument("--blocks", type=int, required=True)
    pair.add_argument("--frames", type=int, required=True)
    pair.add_argument("--seed", type=parse_int, required=True)
    pair.add_argument("--out", type=Path, required=True)
    pair.add_argument("--mode", choices=("offscreen", "presented"), default="offscreen")

    qualify = subparsers.add_parser("qualify")
    qualify.add_argument("--warmup-from", type=Path, required=True)
    qualify.add_argument("--blocks", type=int, required=True)
    qualify.add_argument("--frames", type=int, required=True)
    qualify.add_argument("--seed", type=parse_int, required=True)
    qualify.add_argument("--report", type=Path, required=True)
    qualify.add_argument("--out", type=Path, required=True)
    qualify.add_argument("--mode", choices=("offscreen", "presented"), default="presented")

    return parser


def build_parser() -> argparse.ArgumentParser:
    return _build_parser()


def parse_cpu_list(value: str) -> list[int]:
    values: list[int] = []
    for token in value.split(","):
        try:
            cpu = int(token, 10)
        except ValueError as exc:
            raise argparse.ArgumentTypeError("affinity must contain integers") from exc
        if cpu < 0:
            raise argparse.ArgumentTypeError("affinity must be non-negative")
        values.append(cpu)
    if values != sorted(set(values)):
        raise argparse.ArgumentTypeError("affinity must be sorted and unique")
    return values


def validate_command_args(args: argparse.Namespace) -> None:
    command = args.command
    if command == "snapshot":
        profile_for_flags({
            "tracy": args.tracy,
            "gpu_timestamps": args.gpu_timestamps,
            "perf_counters": args.perf_counters,
        })
        return
    if command == "calibrate":
        if args.frames != CALIBRATION_FRAMES:
            raise ProtocolError("calibrate requires exactly 2,400 frames")
        if args.scene is not None and not args.diagnostic:
            raise ProtocolError("--scene is diagnostic-only; pass --diagnostic")
        if args.seed < 0:
            raise ProtocolError("seed must be non-negative")
        return
    if command == "matrix":
        if args.blocks <= 0:
            raise ProtocolError("matrix requires a positive block count")
        if args.frames <= 0:
            raise ProtocolError("matrix requires positive sample frames")
        if args.seed < 0:
            raise ProtocolError("seed must be non-negative")
        _load_warmup(args.warmup_from)
        return
    if command == "pair":
        if args.blocks <= 0 or args.blocks % 2 != 0:
            raise ProtocolError("pair requires a positive even block count")
        if args.frames <= 0:
            raise ProtocolError("pair requires positive sample frames")
        if args.seed < 0:
            raise ProtocolError("seed must be non-negative")
        _load_warmup(args.warmup_from)
        return
    if command == "qualify":
        if args.blocks != QUALIFICATION_BLOCKS:
            raise ProtocolError("qualification requires exactly 300 blocks")
        if args.frames != QUALIFICATION_FRAMES:
            raise ProtocolError("qualification requires exactly 1,000 frames")
        if args.seed < 0:
            raise ProtocolError("seed must be non-negative")
        _load_warmup(args.warmup_from)
        return
    raise ProtocolError(f"unknown command: {command}")


def _snapshot_args(
    *,
    profile: str,
    out: Path,
    base: argparse.Namespace,
    project_root: Path,
) -> argparse.Namespace:
    args = argparse.Namespace(**vars(base))
    args.tracy = PROFILE_FLAGS[profile]["tracy"]
    args.gpu_timestamps = PROFILE_FLAGS[profile]["gpu_timestamps"]
    args.perf_counters = PROFILE_FLAGS[profile]["perf_counters"]
    args.optimize = getattr(base, "optimize", "Debug")
    args.scene = getattr(base, "scene", "todo")
    args.mode = getattr(base, "mode", "offscreen")
    args.out = out
    args.binary = getattr(base, "binary", None)
    args.nogui_root = getattr(base, "nogui_root", None)
    args.noapi_root = getattr(base, "noapi_root", None)
    args.affinity = getattr(base, "affinity", None)
    for field, expected in (
        ("width", PERF_WIDTH),
        ("height", PERF_HEIGHT),
        ("present_mode", PERF_PRESENT_MODE),
    ):
        if hasattr(base, field) and getattr(base, field) != expected:
            raise ProtocolError(f"{field} is fixed at {expected}")
        setattr(args, field, expected)
    args.zig_version = getattr(base, "zig_version", None)
    args.build_timeout = getattr(base, "build_timeout", 900.0)
    return args


def _run_snapshot_command(args: argparse.Namespace) -> int:
    _snapshot_manifest(args, args.out, _project_root())
    return 0


def _run_calibrate_command(args: argparse.Namespace) -> int:
    project_root = _project_root()
    scenes, acceptance = calibration_scenes(args.scene)
    if args.scene is not None and not args.diagnostic:
        raise ProtocolError("diagnostic scene filter is not valid for acceptance calibration")
    args.out.mkdir(parents=True, exist_ok=True)
    clean_args = _snapshot_args(
        profile="clean",
        out=args.out / "snapshots" / "clean",
        base=args,
        project_root=project_root,
    )
    gpu_args = _snapshot_args(
        profile="gpu",
        out=args.out / "snapshots" / "gpu",
        base=args,
        project_root=project_root,
    )
    clean = _snapshot_manifest(clean_args, clean_args.out, project_root)
    gpu = _snapshot_manifest(gpu_args, gpu_args.out, project_root)
    if clean.manifest["binary"]["sha256"] == gpu.manifest["binary"]["sha256"]:
        raise ProtocolError("calibration profiles did not produce distinct binaries")
    reference_machine = _machine_for_snapshot(clean)
    _assert_machine_unchanged(reference_machine, _machine_for_snapshot(gpu))
    orders = balanced_cell_orders(
        ("clean", "gpu"),
        block_count=len(scenes),
        seed=args.seed,
        control="clean",
    )
    calibration_rule = {"frames": 0, "kind": "calibration"}
    diagnostics: dict[str, Any] = {}
    boundaries: list[int] = []
    snapshots = {"clean": clean, "gpu": gpu}
    for scene, order in zip(scenes, orders):
        blocks: dict[str, ProcessBlock] = {}
        for order_position, profile in enumerate(order):
            blocks[profile] = _run_demo_block(
                snapshots[profile],
                scene=scene,
                mode=args.mode,
                warmup_frames=0,
                sample_frames=args.frames,
                block_id=len(diagnostics),
                order_position=order_position,
                seed=args.seed,
                out=args.out,
                expected_identity=reference_machine,
                warmup_rule=calibration_rule,
            )
        boundary = sustained_stable_boundary(
            _sample_values(blocks["clean"], "cpu_compute_ns"),
            _sample_values(blocks["gpu"], "gpu_execute_ns"),
        )
        boundaries.append(boundary)
        diagnostics[scene] = {
            "order": list(order),
            "clean": _diagnostic_descriptor(blocks["clean"], args.out),
            "gpu": _diagnostic_descriptor(blocks["gpu"], args.out),
            "boundary": boundary,
        }
    warmup_frames = select_warmup_frames(boundaries)
    diagnostic_hashes = {
        descriptor["path"]: descriptor["sha256"]
        for diagnostic in diagnostics.values()
        for descriptor in (diagnostic["clean"], diagnostic["gpu"])
    }
    warmup = {
        "schema_version": SCHEMA_VERSION,
        "warmup_frames": warmup_frames,
        "diagnostic_frames": args.frames,
        "seed": args.seed,
        "acceptance": acceptance,
        "mode": args.mode,
        "diagnostics": diagnostics,
        "diagnostic_hashes": diagnostic_hashes,
    }
    _immutable_json(args.out / "warmup.json", warmup)
    return 0


def _required_snapshot_profiles(args: argparse.Namespace, out: Path) -> dict[str, Snapshot]:
    project_root = _project_root()
    snapshots: dict[str, Snapshot] = {}
    reference_machine: dict[str, Any] | None = None
    binary_hashes: set[str] = set()
    for profile in ("clean", "tracy", "gpu", "mechanism"):
        profile_args = _snapshot_args(
            profile=profile,
            out=out / "snapshots" / profile,
            base=args,
            project_root=project_root,
        )
        snapshot = _snapshot_manifest(profile_args, profile_args.out, project_root)
        machine = _manifest_machine(snapshot.manifest)
        if reference_machine is None:
            reference_machine = machine
        else:
            _assert_machine_unchanged(reference_machine, machine)
        binary_hashes.add(snapshot.manifest["binary"]["sha256"])
        snapshots[profile] = snapshot
    if len(binary_hashes) != len(snapshots):
        raise ProtocolError("instrumentation profiles did not produce distinct binaries")
    return snapshots


def _run_matrix_command(args: argparse.Namespace) -> int:
    warmup_path = Path(args.warmup_from)
    warmup = _load_warmup(warmup_path)
    warmup_rule = {
        "frames": warmup["warmup_frames"],
        "manifest_sha256": sha256_file(warmup_path),
    }
    args.out.mkdir(parents=True, exist_ok=True)
    snapshots = _required_snapshot_profiles(args, args.out)
    orders = balanced_cell_orders(
        tuple(snapshots),
        block_count=args.blocks,
        seed=args.seed,
        control="clean",
    )
    summaries: list[dict[str, Any]] = []
    for scene in SCENES:
        for block_id, order in enumerate(orders):
            for order_position, profile in enumerate(order):
                snapshot = snapshots[profile]
                block = _run_demo_block(
                    snapshot,
                    scene=scene,
                    mode=args.mode,
                    warmup_frames=warmup["warmup_frames"],
                    sample_frames=args.frames,
                    block_id=block_id,
                    order_position=order_position,
                    seed=args.seed,
                    out=args.out,
                    expected_identity=_machine_for_snapshot(snapshot),
                    warmup_rule=warmup_rule,
                )
                summaries.append({
                    "scene": scene,
                    "block_id": block_id,
                    "profile": profile,
                    "order_position": order_position,
                    **_block_summary(block),
                })
    report = {
        "schema_version": SCHEMA_VERSION,
        "command": "matrix",
        "seed": args.seed,
        "blocks": args.blocks,
        "frames": args.frames,
        "warmup_frames": warmup["warmup_frames"],
        "warmup_manifest_sha256": warmup_rule["manifest_sha256"],
        "scenes": list(SCENES),
        "summaries": summaries,
    }
    _immutable_json(args.report, report)
    return 0


def _pair_paths_from_args(args: argparse.Namespace) -> dict[str, tuple[Path, Path]]:
    return {
        profile: (
            getattr(args, f"baseline_{profile}_manifest"),
            getattr(args, f"candidate_{profile}_manifest"),
        )
        for profile in PAIR_PROFILES
    }


def _run_pair_command(args: argparse.Namespace) -> int:
    warmup_path = Path(args.warmup_from)
    warmup = _load_warmup(warmup_path)
    warmup_rule = {
        "frames": warmup["warmup_frames"],
        "manifest_sha256": sha256_file(warmup_path),
    }
    manifests = validate_pair_manifests(_pair_paths_from_args(args))
    reference_machine = _manifest_machine(manifests["clean"][0].manifest)
    orders = paired_block_orders(PAIR_PROFILES, block_count=args.blocks, seed=args.seed)
    args.out.mkdir(parents=True, exist_ok=True)
    summaries: list[dict[str, Any]] = []
    for scene in SCENES:
        for block_id, order in enumerate(orders):
            current_machine = capture_machine_identity(
                requested_affinity=reference_machine["requested_affinity"],
                extent=reference_machine["extent"],
                present_mode=reference_machine["present_mode"],
            )
            _assert_machine_unchanged(reference_machine, current_machine)
            for order_position, (profile, variant) in enumerate(order):
                snapshot = manifests[profile][0 if variant == "baseline" else 1]
                block = _run_demo_block(
                    snapshot,
                    scene=scene,
                    mode=args.mode,
                    warmup_frames=warmup["warmup_frames"],
                    sample_frames=args.frames,
                    block_id=block_id,
                    order_position=order_position,
                    seed=args.seed,
                    out=args.out,
                    expected_identity=reference_machine,
                    warmup_rule=warmup_rule,
                    artifact_variant=variant,
                )
                summaries.append({
                    "scene": scene,
                    "block_id": block_id,
                    "profile": profile,
                    "variant": variant,
                    "order_position": order_position,
                    **_block_summary(block),
                })
    _immutable_json(args.out / "pair.json", {
        "schema_version": SCHEMA_VERSION,
        "command": "pair",
        "seed": args.seed,
        "blocks": args.blocks,
        "frames": args.frames,
        "warmup_frames": warmup["warmup_frames"],
        "warmup_manifest_sha256": warmup_rule["manifest_sha256"],
        "scenes": list(SCENES),
        "summaries": summaries,
    })
    return 0


def _run_qualification_block(
    scene: str,
    block_id: int,
    *,
    snapshots: Mapping[str, Snapshot],
    warmup_frames: int,
    mode: str,
    out: Path,
    seed: int,
    order: Sequence[str] = ("clean", "gpu"),
    expected_identity: Mapping[str, Any] | None = None,
    warmup_rule: Mapping[str, Any] | None = None,
) -> bool:
    if tuple(order) != ("clean", "gpu") and tuple(order) != ("gpu", "clean"):
        raise ProtocolError("qualification order must contain clean and gpu exactly once")
    blocks: list[ProcessBlock | None] = []
    for order_position, profile in enumerate(order):
        try:
            blocks.append(_run_demo_block(
                snapshots[profile],
                scene=scene,
                mode="offscreen",
                warmup_frames=warmup_frames,
                sample_frames=QUALIFICATION_FRAMES,
                block_id=block_id,
                order_position=order_position,
                seed=seed,
                out=out,
                expected_identity=expected_identity,
                warmup_rule=warmup_rule,
            ))
        except ProtocolError:
            blocks.append(None)
    if mode == "presented":
        try:
            blocks.append(_run_demo_block(
                snapshots["clean"],
                scene=scene,
                mode="presented",
                warmup_frames=warmup_frames,
                sample_frames=QUALIFICATION_FRAMES,
                block_id=block_id,
                order_position=len(blocks),
                seed=seed,
                out=out,
                expected_identity=expected_identity,
                warmup_rule=warmup_rule,
            ))
        except ProtocolError:
            blocks.append(None)
    if any(block is None for block in blocks):
        return True
    by_profile = {profile: blocks[index] for index, profile in enumerate(order)}
    clean_offscreen = by_profile["clean"]
    gpu_offscreen = by_profile["gpu"]
    assert clean_offscreen is not None
    assert gpu_offscreen is not None
    try:
        failed = False
        if not within_120_fps_budget(p99_ns(_sample_values(clean_offscreen, "cpu_compute_ns"))):
            failed = True
        if not within_120_fps_budget(p99_ns(_sample_values(gpu_offscreen, "gpu_execute_ns"))):
            failed = True
        if not within_120_fps_budget(p99_ns(_sample_values(gpu_offscreen, "gpu_end_interval_ns"))):
            failed = True
        if mode == "presented":
            presented = blocks[2]
            assert presented is not None
            if presented.header["present_feedback"] is not True:
                return True
            intervals = _sample_values(presented, "present_interval_ns")
            if not within_120_fps_budget(p99_ns(intervals)):
                failed = True
            if not presented_throughput_passes(intervals):
                failed = True
        return failed
    except ProtocolError:
        return True


def _run_qualify_command(args: argparse.Namespace) -> int:
    warmup_path = Path(args.warmup_from)
    warmup = _load_warmup(warmup_path)
    warmup_rule = {
        "frames": warmup["warmup_frames"],
        "manifest_sha256": sha256_file(warmup_path),
    }
    project_root = _project_root()
    args.out.mkdir(parents=True, exist_ok=True)
    snapshot_base = argparse.Namespace(
        optimize="Debug",
        binary=None,
        scene="todo",
        mode=args.mode,
        nogui_root=None,
        noapi_root=None,
        affinity=None,
        width=PERF_WIDTH,
        height=PERF_HEIGHT,
        present_mode="fifo",
        zig_version=None,
        build_timeout=900.0,
    )
    snapshots: dict[str, Snapshot] = {}
    reference_machine: dict[str, Any] | None = None
    binary_hashes: set[str] = set()
    for profile in ("clean", "gpu"):
        profile_args = _snapshot_args(
            profile=profile,
            out=args.out / "snapshots" / profile,
            base=snapshot_base,
            project_root=project_root,
        )
        snapshot = _snapshot_manifest(profile_args, profile_args.out, project_root)
        machine = _machine_for_snapshot(snapshot)
        if reference_machine is None:
            reference_machine = machine
        else:
            _assert_machine_unchanged(reference_machine, machine)
        binary_hashes.add(snapshot.manifest["binary"]["sha256"])
        snapshots[profile] = snapshot
    if len(binary_hashes) != len(snapshots):
        raise ProtocolError("qualification profiles did not produce distinct binaries")
    assert reference_machine is not None
    orders = balanced_cell_orders(
        ("clean", "gpu"),
        block_count=args.blocks,
        seed=args.seed,
        control="clean",
    )
    failures: dict[str, list[bool]] = {scene: [] for scene in SCENES}
    for scene in SCENES:
        for block_id, order in enumerate(orders):
            failures[scene].append(_run_qualification_block(
                scene,
                block_id,
                snapshots=snapshots,
                warmup_frames=warmup["warmup_frames"],
                mode=args.mode,
                out=args.out,
                seed=args.seed,
                order=order,
                expected_identity=reference_machine,
                warmup_rule=warmup_rule,
            ))
    scene_results = {
        scene: {
            "failed_blocks": values,
            "accepted": qualifies(values),
            "zero_failure_upper_bound": zero_failure_upper_bound(args.blocks),
        }
        for scene, values in failures.items()
    }
    report = {
        "schema_version": SCHEMA_VERSION,
        "command": "qualify",
        "seed": args.seed,
        "blocks": args.blocks,
        "frames": args.frames,
        "warmup_frames": warmup["warmup_frames"],
        "warmup_manifest_sha256": warmup_rule["manifest_sha256"],
        "scenes": list(SCENES),
        "results": scene_results,
        "accepted": all(result["accepted"] for result in scene_results.values()),
    }
    _immutable_json(args.report, report)
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        validate_command_args(args)
        if args.command == "snapshot":
            return _run_snapshot_command(args)
        if args.command == "calibrate":
            return _run_calibrate_command(args)
        if args.command == "matrix":
            return _run_matrix_command(args)
        if args.command == "pair":
            return _run_pair_command(args)
        if args.command == "qualify":
            return _run_qualify_command(args)
        raise ProtocolError(f"unknown command: {args.command}")
    except ProtocolError as exc:
        print(f"run_v7_perf: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
