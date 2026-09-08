from __future__ import annotations

from collections.abc import Callable
import argparse
import csv
import hashlib
import json
import os
import shutil
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from unittest import mock

from tools import run_v7_perf as perf


HASH_A = "a" * 64
HASH_B = "b" * 64
HASH_C = "c" * 64
NOGUI_CHANGE_ID = "k" * 32
NOGUI_COMMIT_ID = "1" * 40
NOAPI_CHANGE_ID = "l" * 32
NOAPI_COMMIT_ID = "2" * 40

TEST_STABILITY_RULE = {
    "window_frames": 120,
    "window_count": 3,
    "first_boundary": 600,
    "last_boundary": 2160,
    "boundary_step": 120,
    "maximum_spread_basis_points": 1200,
    "guard_frames": 240,
    "frame_cap": 2400,
}


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def flags_for(profile: str) -> dict[str, bool]:
    return {
        "tracy": profile == "tracy",
        "gpu_timestamps": profile == "gpu",
        "perf_counters": profile == "mechanism",
    }


def valid_identity() -> dict[str, object]:
    return {
        "cpu_model": "Test CPU",
        "online_cpu_set": "0-3",
        "requested_affinity": [0, 1],
        "process_affinity": [0, 1],
        "kernel": "test-kernel",
        "cpu_governor": "performance",
        "gpu": "Test GPU",
        "gpu_vendor_id": 4318,
        "gpu_device_id": 7824,
        "driver": "test-driver",
        "extent": {"width": 954, "height": 1044},
        "present_mode": "fifo",
    }


def valid_header(
    *,
    profile: str = "clean",
    mode: str = "offscreen",
    sample_count: int = 2,
) -> dict[str, object]:
    identity = valid_identity()
    return {
        "schema_version": perf.SCHEMA_VERSION,
        "scene": "todo",
        "mode": mode,
        "optimize_mode": "Debug",
        "instrumentation_flags": flags_for(profile),
        "block_id": 0,
        "randomized_order_position": 0,
        "child_argv": ["artifact/v7-demo", "--perf-mode", mode],
        "zig_version": "0.16.0",
        "binary_sha256": HASH_A,
        "runner_sha256": HASH_B,
        "shader_hashes": {name: HASH_C for name in perf.SHADER_FILES},
        "nogui_jj_change_id": NOGUI_CHANGE_ID,
        "nogui_jj_commit_id": NOGUI_COMMIT_ID,
        "noapi_content_digest": HASH_A,
        "noapi_jj_change_id": NOAPI_CHANGE_ID,
        "noapi_jj_commit_id": NOAPI_COMMIT_ID,
        **identity,
        "extent": {"width": 954, "height": 1044},
        "present_mode": "fifo",
        "reported_refresh_data": (
            {"numerator": 120, "denominator": 1} if mode == "presented" else None
        ),
        "present_feedback": mode == "presented",
        "warmup_rule": {"frames": 1, "manifest_sha256": HASH_C},
        "process_order_seed": 0x4E4F475549313230,
        "sample_count": sample_count,
    }


def valid_sample(
    frame_id: int,
    *,
    phase: str,
    profile: str = "clean",
    mode: str = "offscreen",
) -> dict[str, object]:
    present_slop = 5 if mode == "presented" else None
    sample: dict[str, object] = {
        "phase": phase,
        "frame_id": frame_id,
        "cpu_app_layout_ns": 10,
        "cpu_scene_ns": 20,
        "cpu_record_ns": 30,
        "cpu_submit_present_ns": 40,
        "cpu_compute_ns": 95 if mode == "presented" else 100,
        "cpu_acquire_ns": 3 if mode == "presented" else None,
        "cpu_slot_wait_ns": 7 if mode == "offscreen" else None,
        "cpu_present_slop_ns": present_slop,
        "gpu_execute_ns": 50 if profile == "gpu" else None,
        "gpu_end_interval_ns": (
            None if profile != "gpu" or frame_id == 0 else 8_000_000
        ),
        "present_interval_ns": (
            None if mode != "presented" or frame_id == 0 else 8_000_000
        ),
        "slop_ns": 7 if mode == "offscreen" else 5,
    }
    if profile == "mechanism":
        sample["mechanisms"] = {name: frame_id + 1 for name in perf.COUNTER_NAMES}
    return sample


def write_jsonl(
    path: Path,
    header: dict[str, object],
    samples: list[dict[str, object]],
) -> None:
    records = [header, *samples]
    path.write_text(
        "".join(json.dumps(record, sort_keys=True) + "\n" for record in records),
        encoding="utf-8",
    )


def valid_block(
    root: Path,
    *,
    profile: str = "clean",
    mode: str = "offscreen",
    name: str = "block",
) -> perf.ProcessBlock:
    root.mkdir(parents=True, exist_ok=True)
    path = root / f"{name}.jsonl"
    header = valid_header(profile=profile, mode=mode, sample_count=1)
    samples = [
        valid_sample(0, phase="warmup", profile=profile, mode=mode),
        valid_sample(1, phase="sample", profile=profile, mode=mode),
    ]
    write_jsonl(path, header, samples)
    return perf.parse_process_jsonl(path)


def write_warmup_manifest(root: Path, *, warmup_frames: int = 840) -> Path:
    raw = root / "raw"
    raw.mkdir(parents=True, exist_ok=True)
    hashes: dict[str, str] = {}
    diagnostics: dict[str, object] = {}
    for scene_index, scene in enumerate(perf.SCENES):
        order = (
            ["clean", "gpu"]
            if scene_index % 2 == 0
            else ["gpu", "clean"]
        )
        scene_diagnostics: dict[str, object] = {
            "order": order,
            "boundary": 600,
            "stability": [
                {
                    "boundary": boundary,
                    "cpu_spread_basis_points": 0,
                    "gpu_cpu_spread_basis_points": 0,
                    "gpu_spread_basis_points": 0,
                    "stable": True,
                }
                for boundary in range(
                    perf.CALIBRATION_STABILITY_RULE["first_boundary"],
                    perf.CALIBRATION_STABILITY_RULE["last_boundary"]
                    + perf.CALIBRATION_STABILITY_RULE["boundary_step"],
                    perf.CALIBRATION_STABILITY_RULE["boundary_step"],
                )
            ],
        }
        for profile in ("clean", "gpu"):
            path = raw / f"{scene}-{profile}.jsonl"
            header = valid_header(
                profile=profile,
                mode="offscreen",
                sample_count=perf.CALIBRATION_FRAMES,
            )
            header.update({
                "scene": scene,
                "warmup_rule": {"frames": 0, "kind": "calibration"},
                "process_order_seed": 7,
                "randomized_order_position": order.index(profile),
            })
            write_jsonl(
                path,
                header,
                [
                    valid_sample(frame_id, phase="sample", profile=profile)
                    for frame_id in range(perf.CALIBRATION_FRAMES)
                ],
            )
            relative = path.relative_to(root).as_posix()
            digest = perf.sha256_file(path)
            hashes[relative] = digest
            scene_diagnostics[profile] = {
                "path": relative,
                "sha256": digest,
            }
        diagnostics[scene] = scene_diagnostics
    manifest = {
        "schema_version": perf.SCHEMA_VERSION,
        "noapi_content_digest": HASH_A,
        "warmup_frames": warmup_frames,
        "diagnostic_frames": perf.CALIBRATION_FRAMES,
        "seed": 7,
        "acceptance": True,
        "diagnostics": diagnostics,
        "mode": "offscreen",
        "diagnostic_hashes": hashes,
        "stability_rule": dict(TEST_STABILITY_RULE),
        "stability_status": "sustained",
    }
    path = root / "warmup.json"
    path.write_text(json.dumps(manifest), encoding="utf-8")
    return path

def rewrite_warmup_diagnostic(
    manifest_path: Path,
    scene: str,
    profile: str,
    update: Callable[[dict[str, object]], None],
) -> None:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    descriptor = manifest["diagnostics"][scene][profile]
    artifact = manifest_path.parent / descriptor["path"]
    records = artifact.read_text(encoding="utf-8").splitlines()
    header = json.loads(records[0])
    update(header)
    records[0] = json.dumps(header, sort_keys=True)
    artifact.write_text("\n".join(records) + "\n", encoding="utf-8")
    digest = perf.sha256_file(artifact)
    descriptor["sha256"] = digest
    manifest["diagnostic_hashes"][descriptor["path"]] = digest
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")


def write_snapshot(
    directory: Path,
    *,
    profile: str,
    binary_data: bytes,
    shader_hash: str = HASH_C,
    optimize_mode: str = "Debug",
) -> Path:
    directory.mkdir(parents=True)
    binary_path = directory / "v7-demo"
    binary_path.write_bytes(binary_data)
    shader_dir = directory / "shaders"
    shader_dir.mkdir()
    shader_manifest: dict[str, dict[str, str]] = {}
    for name in perf.SHADER_FILES:
        shader_data = f"{shader_hash}:{name}".encode()
        shader_path = shader_dir / name
        shader_path.write_bytes(shader_data)
        shader_manifest[name] = {
            "path": f"shaders/{name}",
            "sha256": sha256_bytes(shader_data),
        }
    manifest = {
        "schema_version": perf.SCHEMA_VERSION,
        "profile": profile,
        "optimize_mode": optimize_mode,
        "instrumentation_flags": flags_for(profile),
        "binary": {
            "path": "v7-demo",
            "sha256": sha256_bytes(binary_data),
        },
        "zig_version": "0.16.0",
        "runner_sha256": HASH_B,
        "shaders": shader_manifest,
        "nogui": {"change_id": NOGUI_CHANGE_ID, "commit_id": NOGUI_COMMIT_ID},
        "noapi": {
            "change_id": NOAPI_CHANGE_ID,
            "commit_id": NOAPI_COMMIT_ID,
            "content_digest": HASH_A,
        },
        "machine": valid_identity(),
    }
    manifest_path = directory / "snapshot.json"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    return manifest_path


class QualificationTests(unittest.TestCase):
    def test_nearest_rank_p99_is_not_interpolated(self) -> None:
        self.assertEqual(perf.p99_ns(list(range(1, 1001))), 990)

    def test_p99_rejects_empty_input(self) -> None:
        with self.assertRaisesRegex(perf.ProtocolError, "at least one"):
            perf.p99_ns([])

    def test_exact_integer_frame_budget(self) -> None:
        self.assertTrue(perf.within_120_fps_budget(8_333_333))
        self.assertFalse(perf.within_120_fps_budget(8_333_334))

    def test_exact_integer_presented_throughput(self) -> None:
        self.assertTrue(perf.presented_throughput_passes([8_333_333] * 120))
        self.assertFalse(perf.presented_throughput_passes([8_333_334] * 120))
        with self.assertRaises(perf.ProtocolError):
            perf.presented_throughput_passes([])

    def test_zero_failure_upper_bound(self) -> None:
        self.assertLess(perf.zero_failure_upper_bound(300), 0.01)
        with self.assertRaises(perf.ProtocolError):
            perf.zero_failure_upper_bound(0)

    def test_any_failed_block_rejects(self) -> None:
        self.assertFalse(perf.qualifies([False] * 299 + [True]))

    def test_wrong_block_count_rejects(self) -> None:
        with self.assertRaisesRegex(perf.ProtocolError, "exactly 300"):
            perf.qualifies([False] * 299)

    def test_collection_never_stops_after_visible_failure(self) -> None:
        observed: list[int] = []

        def collect(block_id: int) -> bool:
            observed.append(block_id)
            return block_id == 0

        self.assertFalse(perf.collect_qualification(300, collect))
        self.assertEqual(observed, list(range(300)))


class JsonlValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.path = self.root / "block.jsonl"

    def parse(
        self,
        *,
        profile: str = "clean",
        mode: str = "offscreen",
        header: dict[str, object] | None = None,
        samples: list[dict[str, object]] | None = None,
        expected_identity: dict[str, object] | None = None,
    ) -> perf.ProcessBlock:
        actual_header = header or valid_header(profile=profile, mode=mode)
        actual_samples = samples or [
            valid_sample(0, phase="warmup", profile=profile, mode=mode),
            valid_sample(1, phase="sample", profile=profile, mode=mode),
            valid_sample(2, phase="sample", profile=profile, mode=mode),
        ]
        write_jsonl(self.path, actual_header, actual_samples)
        return perf.parse_process_jsonl(
            self.path,
            expected_identity=expected_identity,
        )

    def test_valid_block_preserves_warmup_and_samples(self) -> None:
        block = self.parse()
        self.assertEqual(len(block.frames), 3)
        self.assertEqual([sample["phase"] for sample in block.frames], [
            "warmup",
            "sample",
            "sample",
        ])
        self.assertEqual(block.sha256, perf.sha256_file(self.path))

    def test_malformed_json_rejects(self) -> None:
        self.path.write_text("{not json}\n", encoding="utf-8")
        with self.assertRaisesRegex(perf.ProtocolError, "JSON"):
            perf.parse_process_jsonl(self.path)

    def test_non_object_record_rejects(self) -> None:
        self.path.write_text("[]\n", encoding="utf-8")
        with self.assertRaisesRegex(perf.ProtocolError, "object"):
            perf.parse_process_jsonl(self.path)

    def test_duplicate_json_key_rejects(self) -> None:
        self.path.write_text('{"schema_version":1,"schema_version":1}\n', encoding="utf-8")
        with self.assertRaisesRegex(perf.ProtocolError, "duplicate"):
            perf.parse_process_jsonl(self.path)

    def test_nan_token_rejects(self) -> None:
        header = json.dumps(valid_header())
        sample = json.dumps(valid_sample(0, phase="sample")).replace(
            '"cpu_scene_ns": 20',
            '"cpu_scene_ns": NaN',
        )
        self.path.write_text(header + "\n" + sample + "\n", encoding="utf-8")
        with self.assertRaisesRegex(perf.ProtocolError, "NaN"):
            perf.parse_process_jsonl(self.path)

    def test_nan_like_string_rejects(self) -> None:
        sample = valid_sample(1, phase="sample")
        sample["cpu_scene_ns"] = "NaN"
        with self.assertRaisesRegex(perf.ProtocolError, "integer"):
            self.parse(samples=[valid_sample(0, phase="warmup"), sample])

    def test_missing_required_header_metadata_rejects(self) -> None:
        header = valid_header()
        del header["nogui_jj_commit_id"]
        with self.assertRaisesRegex(perf.ProtocolError, "nogui_jj_commit_id"):
            self.parse(header=header)

    def test_present_feedback_is_required(self) -> None:
        header = valid_header(mode="presented", sample_count=1)
        del header["present_feedback"]
        with self.assertRaisesRegex(perf.ProtocolError, "present_feedback"):
            self.parse(
                mode="presented",
                header=header,
                samples=[
                    valid_sample(0, phase="warmup", mode="presented"),
                    valid_sample(1, phase="sample", mode="presented"),
                ],
            )

    def test_present_feedback_is_independent_of_refresh_data(self) -> None:
        header = valid_header(mode="presented", sample_count=1)
        header["present_feedback"] = False
        header["reported_refresh_data"] = {"numerator": 120, "denominator": 1}
        first = valid_sample(0, phase="warmup", mode="presented")
        second = valid_sample(1, phase="sample", mode="presented")
        first["present_interval_ns"] = None
        second["present_interval_ns"] = None
        block = self.parse(
            mode="presented",
            header=header,
            samples=[first, second],
        )
        self.assertIsNone(block.samples[0]["present_interval_ns"])

    def test_non_contiguous_frame_ids_reject(self) -> None:
        with self.assertRaisesRegex(perf.ProtocolError, "contiguous"):
            self.parse(samples=[
                valid_sample(0, phase="warmup"),
                valid_sample(2, phase="sample"),
                valid_sample(3, phase="sample"),
            ])

    def test_sample_count_mismatch_rejects(self) -> None:
        header = valid_header(sample_count=1)
        with self.assertRaisesRegex(perf.ProtocolError, "sample_count"):
            self.parse(header=header)

    def test_warmup_after_retained_sample_rejects(self) -> None:
        with self.assertRaisesRegex(perf.ProtocolError, "warmup"):
            self.parse(samples=[
                valid_sample(0, phase="sample"),
                valid_sample(1, phase="warmup"),
            ])

    def test_negative_duration_rejects(self) -> None:
        sample = valid_sample(1, phase="sample")
        sample["cpu_record_ns"] = -1
        with self.assertRaisesRegex(perf.ProtocolError, "non-negative"):
            self.parse(samples=[valid_sample(0, phase="warmup"), sample])

    def test_present_slop_larger_than_submit_rejects(self) -> None:
        sample = valid_sample(1, phase="sample", mode="presented")
        sample["cpu_present_slop_ns"] = 41
        with self.assertRaisesRegex(perf.ProtocolError, "present slop"):
            self.parse(
                mode="presented",
                samples=[
                    valid_sample(0, phase="warmup", mode="presented"),
                    sample,
                ],
            )

    def test_presented_cumulative_slop_is_not_current_delta(self) -> None:
        sample = valid_sample(1, phase="sample", mode="presented")
        sample["slop_ns"] = 9
        block = self.parse(
            mode="presented",
            header=valid_header(mode="presented", sample_count=1),
            samples=[
                valid_sample(0, phase="warmup", mode="presented"),
                sample,
            ],
        )
        self.assertEqual(block.samples[0]["slop_ns"], 9)

    def test_compute_arithmetic_mismatch_rejects(self) -> None:
        sample = valid_sample(1, phase="sample")
        sample["cpu_compute_ns"] = 99
        with self.assertRaisesRegex(perf.ProtocolError, "cpu_compute_ns"):
            self.parse(samples=[valid_sample(0, phase="warmup"), sample])

    def test_offscreen_slop_must_equal_slot_wait(self) -> None:
        sample = valid_sample(1, phase="sample")
        sample["slop_ns"] = 8
        with self.assertRaisesRegex(perf.ProtocolError, "slot wait"):
            self.parse(samples=[valid_sample(0, phase="warmup"), sample])

    def test_gpu_build_requires_delayed_metrics(self) -> None:
        second = valid_sample(1, phase="sample", profile="gpu")
        second["gpu_end_interval_ns"] = None
        with self.assertRaisesRegex(perf.ProtocolError, "gpu_end_interval_ns"):
            self.parse(
                profile="gpu",
                samples=[valid_sample(0, phase="warmup", profile="gpu"), second],
            )

    def test_gpu_build_requires_execution_duration(self) -> None:
        first = valid_sample(0, phase="warmup", profile="gpu")
        first["gpu_execute_ns"] = None
        with self.assertRaisesRegex(perf.ProtocolError, "gpu_execute_ns"):
            self.parse(
                profile="gpu",
                samples=[first, valid_sample(1, phase="sample", profile="gpu")],
            )

    def test_presented_build_requires_delayed_interval(self) -> None:
        second = valid_sample(1, phase="sample", mode="presented")
        second["present_interval_ns"] = None
        with self.assertRaisesRegex(perf.ProtocolError, "present_interval_ns"):
            self.parse(
                mode="presented",
                samples=[
                    valid_sample(0, phase="warmup", mode="presented"),
                    second,
                ],
            )

    def test_first_frame_alone_may_have_null_delayed_intervals(self) -> None:
        block = self.parse(
            profile="gpu",
            mode="presented",
            header=valid_header(profile="gpu", mode="presented", sample_count=1),
            samples=[
                valid_sample(0, phase="warmup", profile="gpu", mode="presented"),
                valid_sample(1, phase="sample", profile="gpu", mode="presented"),
            ],
        )
        self.assertIsNone(block.frames[0]["gpu_end_interval_ns"])
        self.assertIsNone(block.frames[0]["present_interval_ns"])

    def test_mechanisms_present_only_in_mechanism_build(self) -> None:
        clean = valid_sample(1, phase="sample")
        clean["mechanisms"] = {"measure_requests": 1}
        with self.assertRaisesRegex(perf.ProtocolError, "mechanisms"):
            self.parse(samples=[valid_sample(0, phase="warmup"), clean])

        mechanism = valid_sample(1, phase="sample", profile="mechanism")
        del mechanism["mechanisms"]
        with self.assertRaisesRegex(perf.ProtocolError, "mechanisms"):
            self.parse(
                profile="mechanism",
                samples=[
                    valid_sample(0, phase="warmup", profile="mechanism"),
                    mechanism,
                ],
            )
    def test_valid_mechanism_sample_has_complete_counter_snapshot(self) -> None:
        block = self.parse(
            profile="mechanism",
            header=valid_header(profile="mechanism", sample_count=1),
            samples=[
                valid_sample(0, phase="warmup", profile="mechanism"),
                valid_sample(1, phase="sample", profile="mechanism"),
            ],
        )
        self.assertEqual(set(block.frames[1]["mechanisms"]), set(perf.COUNTER_NAMES))

    def test_every_declared_optional_sample_field_is_serialized(self) -> None:
        sample = valid_sample(0, phase="sample")
        del sample["gpu_execute_ns"]
        with self.assertRaisesRegex(perf.ProtocolError, "gpu_execute_ns"):
            self.parse(samples=[sample])

    def test_changed_affinity_rejects(self) -> None:
        expected = valid_identity()
        header = valid_header()
        header["process_affinity"] = [2, 3]
        with self.assertRaisesRegex(perf.ProtocolError, "process_affinity"):
            self.parse(header=header, expected_identity=expected)


class SnapshotBuildTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.project_root = Path(perf.__file__).resolve().parents[1]

    def test_profile_builds_are_direct_and_distinct(self) -> None:
        calls: list[list[str]] = []

        def runner(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
            calls.append(argv)
            prefix = Path(argv[argv.index("--prefix") + 1])
            binary = prefix / "bin" / "v7-demo"
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(prefix.name.encode())
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")
        base = argparse.Namespace(optimize="Debug", binary=None, build_timeout=1.0)
        clean = perf._snapshot_binary_source(
            base,
            self.project_root,
            self.root / "clean",
            "clean",
            runner=runner,
        )
        gpu = perf._snapshot_binary_source(
            base,
            self.project_root,
            self.root / "gpu",
            "gpu",
            runner=runner,
        )
        self.assertNotEqual(clean, gpu)
        self.assertNotEqual(clean.read_bytes(), gpu.read_bytes())
        self.assertIn("-Dv7-gpu-timestamps=true", calls[1])
        self.assertIn("-Dv7-tracy=false", calls[1])
        self.assertIn("-Dv7-perf-counters=false", calls[1])

    def test_binary_override_cannot_bypass_profile_build(self) -> None:
        binary = self.root / "existing-v7-demo"
        binary.write_bytes(b"existing")
        args = argparse.Namespace(
            optimize="Debug",
            binary=binary,
            build_timeout=1.0,
        )
        with self.assertRaisesRegex(perf.ProtocolError, "overrides"):
            perf._snapshot_binary_source(
                args,
                self.project_root,
                self.root / "clean",
                "clean",
                runner=mock.Mock(),
            )

    def test_snapshot_manifest_builds_copies_and_loads(self) -> None:
        def runner(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
            if argv[:3] == ["zig", "build", "install"]:
                prefix = Path(argv[argv.index("--prefix") + 1])
                binary = prefix / "bin" / "v7-demo"
                binary.parent.mkdir(parents=True, exist_ok=True)
                binary.write_bytes(b"built-clean")
                return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")
            if argv[:3] == ["jj", "log", "--no-graph"]:
                return subprocess.CompletedProcess(
                    argv,
                    0,
                    stdout=f"{NOGUI_CHANGE_ID}\n{NOGUI_COMMIT_ID}\n",
                    stderr="",
                )
            if argv[:2] == ["lspci", "-nnk"]:
                return subprocess.CompletedProcess(
                    argv,
                    0,
                    stdout="00:00.0 VGA compatible controller: Test GPU\n\tKernel driver in use: test-driver\n",
                    stderr="",
                )
            if argv[:2] == ["zig", "version"]:
                return subprocess.CompletedProcess(argv, 0, stdout="0.16.0\n", stderr="")
            raise AssertionError(argv)

        args = argparse.Namespace(
            optimize="Debug",
            binary=None,
            tracy=False,
            gpu_timestamps=False,
            perf_counters=False,
            scene="todo",
            mode="offscreen",
            nogui_root=self.project_root,
            noapi_root=self.project_root,
            affinity=[0, 1],
            width=954,
            height=1044,
            present_mode="fifo",
            zig_version=None,
            build_timeout=1.0,
        )
        snapshot = perf._snapshot_manifest(
            args,
            self.root / "snapshot",
            self.project_root,
            runner=runner,
        )
        self.assertEqual(snapshot.manifest["profile"], "clean")
        copied = snapshot.path.parent / snapshot.manifest["binary"]["path"]
        self.assertEqual(copied.read_bytes(), b"built-clean")
        self.assertEqual(snapshot.manifest["zig_version"], "0.16.0")

class ProtocolReviewRegressionTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.snapshot_path = write_snapshot(
            self.root / "snapshot",
            profile="clean",
            binary_data=b"clean-profile",
        )
        self.snapshot = perf._load_snapshot(self.snapshot_path)

    def test_calibration_accepts_twelve_percent(self) -> None:
        below = [1000] * 120 + [1050] * 120 + [1119] * 120
        at_limit = [1000] * 120 + [1050] * 120 + [1120] * 120
        above = [1000] * 120 + [1050] * 120 + [1121] * 120
        all_zero = [0] * 360
        mixed_zero = [0] * 240 + [1] * 120

        self.assertTrue(perf._stable_triplet(below, 360))
        self.assertTrue(perf._stable_triplet(at_limit, 360))
        self.assertFalse(perf._stable_triplet(above, 360))
        self.assertTrue(perf._stable_triplet(all_zero, 360))
        self.assertFalse(perf._stable_triplet(mixed_zero, 360))

    def test_calibration_fallback_caps_missing_boundary(self) -> None:
        self.assertEqual(
            perf.select_calibration_warmup([600, 720]),
            (960, "sustained"),
        )
        self.assertEqual(
            perf.select_calibration_warmup([600, None]),
            (2400, "capped_unstable"),
        )

    def test_warmup_requires_stability_status_and_audit(self) -> None:
        missing_status_path = write_warmup_manifest(self.root / "missing-status")
        missing_status = json.loads(missing_status_path.read_text(encoding="utf-8"))
        del missing_status["stability_status"]
        missing_status_path.write_text(json.dumps(missing_status), encoding="utf-8")
        with self.assertRaisesRegex(perf.ProtocolError, "stability status"):
            perf._load_warmup(missing_status_path)

        invalid_status_path = write_warmup_manifest(self.root / "invalid-status")
        invalid_status = json.loads(invalid_status_path.read_text(encoding="utf-8"))
        invalid_status["stability_status"] = "stable"
        invalid_status_path.write_text(json.dumps(invalid_status), encoding="utf-8")
        with self.assertRaisesRegex(perf.ProtocolError, "stability status"):
            perf._load_warmup(invalid_status_path)

        missing_audit_path = write_warmup_manifest(self.root / "missing-audit")
        missing_audit = json.loads(missing_audit_path.read_text(encoding="utf-8"))
        del missing_audit["diagnostics"]["todo"]["stability"]
        missing_audit_path.write_text(json.dumps(missing_audit), encoding="utf-8")
        with self.assertRaisesRegex(perf.ProtocolError, "stability audit"):
            perf._load_warmup(missing_audit_path)

        capped_without_null_path = write_warmup_manifest(self.root / "capped-without-null")
        capped_without_null = json.loads(
            capped_without_null_path.read_text(encoding="utf-8")
        )
        capped_without_null["stability_status"] = "capped_unstable"
        capped_without_null["warmup_frames"] = 2400
        capped_without_null_path.write_text(json.dumps(capped_without_null), encoding="utf-8")
        with self.assertRaisesRegex(perf.ProtocolError, "stability status"):
            perf._load_warmup(capped_without_null_path)

        sustained_with_null_path = write_warmup_manifest(self.root / "sustained-with-null")
        sustained_with_null = json.loads(
            sustained_with_null_path.read_text(encoding="utf-8")
        )
        sustained_with_null["diagnostics"]["todo"]["boundary"] = None
        sustained_with_null_path.write_text(
            json.dumps(sustained_with_null),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(perf.ProtocolError, "boundary"):
            perf._load_warmup(sustained_with_null_path)

    def test_warmup_requires_stability_rule(self) -> None:
        valid_path = write_warmup_manifest(self.root / "valid-stability-rule")
        self.assertEqual(
            perf._load_warmup(valid_path)["stability_rule"],
            TEST_STABILITY_RULE,
        )

        missing_path = write_warmup_manifest(self.root / "missing-stability-rule")
        missing = json.loads(missing_path.read_text(encoding="utf-8"))
        del missing["stability_rule"]
        missing_path.write_text(json.dumps(missing), encoding="utf-8")
        with self.assertRaisesRegex(perf.ProtocolError, "stability rule"):
            perf._load_warmup(missing_path)

        former_path = write_warmup_manifest(self.root / "former-stability-rule")
        former = json.loads(former_path.read_text(encoding="utf-8"))
        former["stability_rule"]["maximum_spread_basis_points"] = 200
        former_path.write_text(json.dumps(former), encoding="utf-8")
        with self.assertRaisesRegex(perf.ProtocolError, "stability rule"):
            perf._load_warmup(former_path)

    def test_matrix_copies_stability_rule(self) -> None:
        warmup_path = write_warmup_manifest(self.root / "matrix-warmup")
        output = self.root / "matrix"
        report_path = output / "report.json"
        block = valid_block(self.root / "matrix-block")
        snapshots = {
            profile: self.snapshot
            for profile in ("clean", "tracy", "gpu", "mechanism")
        }
        args = argparse.Namespace(
            warmup_from=warmup_path,
            out=output,
            blocks=1,
            seed=7,
            mode="offscreen",
            frames=1,
            report=report_path,
        )
        with (
            mock.patch.object(
                perf,
                "_required_snapshot_profiles",
                return_value=snapshots,
            ),
            mock.patch.object(perf, "_run_demo_block", return_value=block),
        ):
            self.assertEqual(perf._run_matrix_command(args), 0)

        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(report["stability_rule"], TEST_STABILITY_RULE)
        self.assertEqual(report["stability_status"], "sustained")
        self.assertEqual(
            report["warmup_manifest_sha256"],
            perf.sha256_file(warmup_path),
        )

    def test_calibration_zero_warmup_summary_ignores_global_frame_zero(self) -> None:
        path = self.root / "calibration.jsonl"
        header = valid_header(sample_count=1)
        header["warmup_rule"] = {"frames": 0, "kind": "calibration"}
        write_jsonl(path, header, [valid_sample(0, phase="sample")])
        block = perf.parse_process_jsonl(path)
        summary = perf._block_summary(block)
        self.assertNotIn("gpu_end_interval_ns", summary)
        self.assertEqual(summary["sample_count"], 1)

    def test_warmup_count_must_match_header(self) -> None:
        path = self.root / "wrong-warmup.jsonl"
        header = valid_header(sample_count=1)
        write_jsonl(path, header, [valid_sample(0, phase="sample")])
        with self.assertRaisesRegex(perf.ProtocolError, "warmup frame count"):
            perf.parse_process_jsonl(path)

    def test_positive_present_interval_is_required_after_global_frame_zero(self) -> None:
        path = self.root / "zero-present-interval.jsonl"
        header = valid_header(mode="presented", sample_count=1)
        sample = valid_sample(1, phase="sample", mode="presented")
        sample["present_interval_ns"] = 0
        write_jsonl(
            path,
            header,
            [valid_sample(0, phase="warmup", mode="presented"), sample],
        )
        with self.assertRaisesRegex(perf.ProtocolError, "positive"):
            perf.parse_process_jsonl(path)

    def _child_runner(
        self,
        *,
        scene: str = "todo",
        remove_field: str | None = None,
        warmup_frames: int = 0,
        profile: str = "clean",
    ) -> object:
        def runner(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
            output = Path(argv[argv.index("--perf-out") + 1])
            sample_frames = int(argv[argv.index("--perf-frames") + 1])
            header = valid_header(profile=profile, mode="offscreen", sample_count=sample_frames)
            header.update({
                "scene": scene,
                "mode": "offscreen",
                "child_argv": list(argv),
                "warmup_frames": warmup_frames,
            })
            if remove_field is not None:
                del header[remove_field]
            output.parent.mkdir(parents=True, exist_ok=True)
            write_jsonl(
                output,
                header,
                [
                    valid_sample(
                        frame_id,
                        phase="warmup" if frame_id < warmup_frames else "sample",
                    )
                    for frame_id in range(warmup_frames + sample_frames)
                ],
            )
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        return runner

    def test_child_runtime_header_is_strictly_bound_to_request(self) -> None:
        block = perf._run_demo_block(
            self.snapshot,

            scene="todo",
            mode="offscreen",
            warmup_frames=0,
            sample_frames=1,
            block_id=0,
            order_position=0,
            seed=7,
            out=self.root / "run",
            runner=self._child_runner(),
            warmup_rule={"frames": 0, "kind": "calibration"},
        )
        self.assertEqual(block.header["scene"], "todo")
        with self.assertRaisesRegex(perf.ProtocolError, "scene"):
            perf._run_demo_block(
                self.snapshot,
                scene="todo",
                mode="offscreen",
                warmup_frames=0,
                sample_frames=1,
                block_id=1,
                order_position=0,
                seed=7,
                out=self.root / "wrong-scene",
                runner=self._child_runner(scene="spotify"),
                warmup_rule={"frames": 0, "kind": "calibration"},
            )
        with self.assertRaisesRegex(perf.ProtocolError, "missing"):
            perf._run_demo_block(
                self.snapshot,
                scene="todo",
                mode="offscreen",
                warmup_frames=0,
                sample_frames=1,
                block_id=2,
                order_position=0,
                seed=7,
                out=self.root / "missing-runtime",
                runner=self._child_runner(remove_field="gpu"),
                warmup_rule={"frames": 0, "kind": "calibration"},
            )
        with self.assertRaisesRegex(perf.ProtocolError, "missing"):
            perf._run_demo_block(
                self.snapshot,
                scene="todo",
                mode="offscreen",
                warmup_frames=0,
                sample_frames=1,
                block_id=3,
                order_position=0,
                seed=7,
                out=self.root / "missing-gpu-id",
                runner=self._child_runner(remove_field="gpu_vendor_id"),
                warmup_rule={"frames": 0, "kind": "calibration"},
            )
    def test_child_reports_warmup_count_and_runner_binds_manifest(self) -> None:
        warmup_rule = {"frames": 1, "manifest_sha256": HASH_C}
        block = perf._run_demo_block(
            self.snapshot,
            scene="todo",
            mode="offscreen",
            warmup_frames=1,
            sample_frames=1,
            block_id=3,
            order_position=0,
            seed=7,
            out=self.root / "positive-warmup",
            runner=self._child_runner(warmup_frames=1),
            warmup_rule=warmup_rule,
        )
        self.assertEqual(block.header["warmup_rule"], warmup_rule)

    def test_child_output_parent_exists_before_launch(self) -> None:
        child_runner = self._child_runner()

        def runner(argv: list[str], **kwargs: object) -> object:
            output = Path(argv[argv.index("--perf-out") + 1])
            self.assertTrue(output.parent.is_dir())
            return child_runner(argv, **kwargs)

        block = perf._run_demo_block(
            self.snapshot,
            scene="todo",
            mode="offscreen",
            warmup_frames=0,
            sample_frames=1,
            block_id=0,
            order_position=0,
            seed=7,
            out=self.root / "raw-parent",
            runner=runner,
            warmup_rule={"frames": 0, "kind": "calibration"},
        )
        self.assertEqual(block.path.parent.name, "raw")

    def test_relative_output_launches_resolved_executable_and_artifact_paths(self) -> None:
        previous = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, previous)
        relative_snapshot = perf._load_snapshot(
            self.snapshot.path.relative_to(self.root)
        )
        child_runner = self._child_runner()

        def runner(argv: list[str], **kwargs: object) -> object:
            self.assertTrue(Path(argv[0]).is_absolute())
            output = Path(argv[argv.index("--perf-out") + 1])
            self.assertTrue(output.is_absolute())
            return child_runner(argv, **kwargs)

        block = perf._run_demo_block(
            relative_snapshot,
            scene="todo",
            mode="offscreen",
            warmup_frames=0,
            sample_frames=1,
            block_id=0,
            order_position=0,
            seed=7,
            out=Path("relative-run"),
            runner=runner,
            warmup_rule={"frames": 0, "kind": "calibration"},
        )
        self.assertTrue(block.path.is_absolute())

    def test_raw_paths_are_fresh_and_pair_variants_are_distinct(self) -> None:
        runner = self._child_runner()
        base = self.root / "paths"
        stale = base / "raw" / "todo-clean-offscreen-0000-0000.jsonl"
        stale.parent.mkdir(parents=True)
        stale.write_bytes(b"stale")
        with self.assertRaisesRegex(perf.ProtocolError, "not fresh"):
            perf._run_demo_block(
                self.snapshot,
                scene="todo",
                mode="offscreen",
                warmup_frames=0,
                sample_frames=1,
                block_id=0,
                order_position=0,
                seed=7,
                out=base,
                runner=runner,
                warmup_rule={"frames": 0, "kind": "calibration"},
            )
        baseline = perf._run_demo_block(
            self.snapshot,
            scene="todo",
            mode="offscreen",
            warmup_frames=0,
            sample_frames=1,
            block_id=0,
            order_position=0,
            seed=7,
            out=self.root / "pair",
            runner=runner,
            warmup_rule={"frames": 0, "kind": "calibration"},
            artifact_variant="baseline",
        )
        candidate = perf._run_demo_block(
            self.snapshot,
            scene="todo",
            mode="offscreen",
            warmup_frames=0,
            sample_frames=1,
            block_id=0,
            order_position=1,
            seed=7,
            out=self.root / "pair",
            runner=runner,
            warmup_rule={"frames": 0, "kind": "calibration"},
            artifact_variant="candidate",
        )
        self.assertNotEqual(baseline.path, candidate.path)

    def test_warmup_manifest_recomputes_confined_artifacts(self) -> None:
        manifest_path = write_warmup_manifest(self.root / "warmup")
        self.assertEqual(perf._load_warmup(manifest_path)["warmup_frames"], 840)
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["diagnostic_hashes"] = {"../outside.jsonl": HASH_A}
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaisesRegex(perf.ProtocolError, "normalized relative"):
            perf._load_warmup(manifest_path)
    def test_warmup_manifest_recomputes_diagnostic_boundaries(self) -> None:
        manifest_path = write_warmup_manifest(self.root / "tampered-warmup")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["diagnostics"]["todo"]["boundary"] = 720
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaisesRegex(perf.ProtocolError, "boundary"):
            perf._load_warmup(manifest_path)

    def test_warmup_diagnostic_headers_require_calibration_rule(self) -> None:
        manifest_path = write_warmup_manifest(self.root / "bad-rule")
        rewrite_warmup_diagnostic(
            manifest_path,
            "todo",
            "clean",
            lambda header: header["warmup_rule"].update({"extra": True}),
        )
        with self.assertRaisesRegex(perf.ProtocolError, "calibration rule"):
            perf._load_warmup(manifest_path)

    def test_warmup_diagnostic_headers_bind_manifest_seed(self) -> None:
        manifest_path = write_warmup_manifest(self.root / "bad-seed")
        rewrite_warmup_diagnostic(
            manifest_path,
            "todo",
            "clean",
            lambda header: header.update({"process_order_seed": 8}),
        )
        with self.assertRaisesRegex(perf.ProtocolError, "seed"):
            perf._load_warmup(manifest_path)

    def test_warmup_diagnostic_headers_bind_declared_order(self) -> None:
        manifest_path = write_warmup_manifest(self.root / "bad-order")
        rewrite_warmup_diagnostic(
            manifest_path,
            "todo",
            "clean",
            lambda header: header.update({"randomized_order_position": 1}),
        )
        with self.assertRaisesRegex(perf.ProtocolError, "order"):
            perf._load_warmup(manifest_path)

    def test_warmup_diagnostics_share_machine_identity(self) -> None:
        manifest_path = write_warmup_manifest(self.root / "bad-machine")
        rewrite_warmup_diagnostic(
            manifest_path,
            "todo",
            "clean",
            lambda header: header.update({"online_cpu_set": "0-7"}),
        )
        with self.assertRaisesRegex(perf.ProtocolError, "machine"):
            perf._load_warmup(manifest_path)
    def test_warmup_diagnostics_share_noapi_content_digest(self) -> None:
        manifest_path = write_warmup_manifest(self.root / "bad-noapi-digest")
        rewrite_warmup_diagnostic(
            manifest_path,
            "todo",
            "clean",
            lambda header: header.update({"noapi_content_digest": HASH_B}),
        )
        with self.assertRaisesRegex(perf.ProtocolError, "noapi content digest"):
            perf._load_warmup(manifest_path)

    def test_warmup_diagnostics_share_requested_process_affinity(self) -> None:
        manifest_path = write_warmup_manifest(self.root / "bad-affinity")
        rewrite_warmup_diagnostic(
            manifest_path,
            "todo",
            "clean",
            lambda header: header.update({"process_affinity": [2, 3]}),
        )
        with self.assertRaisesRegex(perf.ProtocolError, "affinity"):
            perf._load_warmup(manifest_path)


    def test_tracy_artifacts_reject_stale_trace_before_children(self) -> None:
        trace = self.root / "stale.tracy"
        trace.write_bytes(b"old")
        with self.assertRaisesRegex(perf.ProtocolError, "not fresh"):
            perf.run_tracy_capture(
                demo_argv=["artifact/v7-demo"],
                trace_path=trace,
                csv_path=self.root / "events.csv",
                sample_roots=1,
                process_timeout_s=1.0,
                export_timeout_s=1.0,
                popen_factory=mock.Mock(),
                port_checker=lambda **_: None,
            )

    def test_tracy_evidence_is_preserved_in_block_summary(self) -> None:
        block = valid_block(self.root, name="tracy-source")
        evidence = perf.TraceEvidence(
            trace_path=self.root / "x.tracy",
            csv_path=self.root / "x.csv",
            trace_sha256=HASH_A,
            csv_sha256=HASH_B,
            summary={"sample_root_count": 1, "zones": {}},
        )
        traced = perf.ProcessBlock(
            path=block.path,
            header=block.header,
            frames=block.frames,
            sha256=block.sha256,
            trace=evidence,
        )
        summary = perf._block_summary(traced)
        self.assertEqual(summary["tracy"]["trace_sha256"], HASH_A)
        self.assertEqual(summary["tracy"]["csv_sha256"], HASH_B)

    def test_tracy_evidence_is_removed_when_process_validation_fails(self) -> None:
        snapshot = perf._load_snapshot(
            write_snapshot(
                self.root / "tracy-snapshot",
                profile="tracy",
                binary_data=b"tracy-profile",
            )
        )
        out = self.root / "tracy-transaction"

        def fake_tracy(**kwargs: object) -> dict[str, object]:
            argv = list(kwargs["demo_argv"])
            self._child_runner(profile="tracy")(argv)
            trace = Path(kwargs["trace_path"])
            csv_path = Path(kwargs["csv_path"])
            temporary_trace = trace.with_name(trace.name + ".partial")
            temporary_csv = csv_path.with_name(csv_path.name + ".partial")
            temporary_trace.parent.mkdir(parents=True, exist_ok=True)
            temporary_trace.write_bytes(b"trace")
            temporary_csv.write_bytes(b"csv")
            return {
                "trace_path": str(trace),
                "csv_path": str(csv_path),
                "trace_temporary_path": str(temporary_trace),
                "csv_temporary_path": str(temporary_csv),
                "trace_sha256": perf.sha256_file(temporary_trace),
                "csv_sha256": perf.sha256_file(temporary_csv),
                "summary": {"sample_root_count": 1, "zones": {}},
            }

        with mock.patch.object(perf, "run_tracy_capture", side_effect=fake_tracy):
            with mock.patch.object(
                perf,
                "parse_process_jsonl",
                side_effect=perf.ProtocolError("late process validation"),
            ):
                with self.assertRaisesRegex(perf.ProtocolError, "late process"):
                    perf._run_demo_block(
                        snapshot,
                        scene="todo",
                        mode="offscreen",
                        warmup_frames=0,
                        sample_frames=1,
                        block_id=0,
                        order_position=0,
                        seed=7,
                        out=out,
                        warmup_rule={"frames": 0, "kind": "calibration"},
                    )
        self.assertFalse(any(
            path.is_file() or path.is_symlink()
            for path in out.rglob("*")
        ))


class ArtifactManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def paired_paths(self) -> dict[str, tuple[Path, Path]]:
        return {
            profile: (
                write_snapshot(
                    self.root / "baseline" / profile,
                    profile=profile,
                    binary_data=f"baseline-{profile}".encode(),
                ),
                write_snapshot(
                    self.root / "candidate" / profile,
                    profile=profile,
                    binary_data=f"candidate-{profile}".encode(),
                ),
            )
            for profile in perf.PAIR_PROFILES
        }

    def rewrite(self, path: Path, update: object) -> None:
        manifest = json.loads(path.read_text(encoding="utf-8"))
        update(manifest)
        path.write_text(json.dumps(manifest), encoding="utf-8")

    def test_pair_accepts_three_distinct_matched_profiles(self) -> None:
        validated = perf.validate_pair_manifests(self.paired_paths())
        self.assertEqual(set(validated), set(perf.PAIR_PROFILES))

    def test_missing_profile_rejects(self) -> None:
        paths = self.paired_paths()
        del paths["gpu"]
        with self.assertRaisesRegex(perf.ProtocolError, "missing profile"):
            perf.validate_pair_manifests(paths)

    def test_wrong_profile_flags_reject(self) -> None:
        paths = self.paired_paths()
        candidate = paths["clean"][1]
        self.rewrite(
            candidate,
            lambda value: value["instrumentation_flags"].update(
                {"gpu_timestamps": True}
            ),
        )
        with self.assertRaisesRegex(perf.ProtocolError, "flags"):
            perf.validate_pair_manifests(paths)

    def test_within_profile_optimize_mismatch_rejects(self) -> None:
        paths = self.paired_paths()
        candidate = paths["gpu"][1]
        self.rewrite(candidate, lambda value: value.update({"optimize_mode": "ReleaseFast"}))
        with self.assertRaisesRegex(perf.ProtocolError, "optimize"):
            perf.validate_pair_manifests(paths)

    def test_equal_corresponding_binary_hash_rejects(self) -> None:
        paths = self.paired_paths()
        baseline = paths["mechanism"][0]
        candidate = paths["mechanism"][1]
        baseline_bytes = (baseline.parent / "v7-demo").read_bytes()
        (candidate.parent / "v7-demo").write_bytes(baseline_bytes)
        self.rewrite(
            candidate,
            lambda value: value["binary"].update(
                {"sha256": sha256_bytes(baseline_bytes)}
            ),
        )
        with self.assertRaisesRegex(perf.ProtocolError, "distinct"):
            perf.validate_pair_manifests(paths)

    def test_missing_copied_binary_rejects(self) -> None:
        paths = self.paired_paths()
        (paths["clean"][0].parent / "v7-demo").unlink()
        with self.assertRaisesRegex(perf.ProtocolError, "binary"):
            perf.validate_pair_manifests(paths)

    def test_copied_binary_hash_mismatch_rejects(self) -> None:
        paths = self.paired_paths()
        (paths["gpu"][1].parent / "v7-demo").write_bytes(b"tampered")
        with self.assertRaisesRegex(perf.ProtocolError, "hash"):
            perf.validate_pair_manifests(paths)

    def test_changed_shader_manifest_rejects(self) -> None:
        paths = self.paired_paths()
        candidate = paths["clean"][1]
        self.rewrite(
            candidate,
            lambda value: value["shaders"][perf.SHADER_FILES[0]].update(
                {"sha256": HASH_A}
            ),
        )
        with self.assertRaisesRegex(perf.ProtocolError, "shader"):
            perf.validate_pair_manifests(paths)

    def test_changed_machine_identity_rejects(self) -> None:
        paths = self.paired_paths()
        candidate = paths["clean"][1]
        self.rewrite(
            candidate,
            lambda value: value["machine"].update({"online_cpu_set": "0-1"}),
        )
        with self.assertRaisesRegex(perf.ProtocolError, "online_cpu_set"):
            perf.validate_pair_manifests(paths)
    def test_changed_noapi_provenance_rejects(self) -> None:
        paths = self.paired_paths()
        candidate = paths["gpu"][1]
        self.rewrite(
            candidate,
            lambda value: value["noapi"].update({"content_digest": HASH_B}),
        )
        with self.assertRaisesRegex(perf.ProtocolError, "noapi provenance"):
            perf.validate_pair_manifests(paths)

    def test_placeholder_machine_identity_rejects(self) -> None:
        path = write_snapshot(
            self.root / "placeholder",
            profile="clean",
            binary_data=b"placeholder",
        )
        self.rewrite(
            path,
            lambda value: value["machine"].update({"gpu": "unavailable"}),
        )
        with self.assertRaisesRegex(perf.ProtocolError, "placeholder"):
            perf._load_snapshot(path)

    def test_nonstandard_extent_rejects(self) -> None:
        path = write_snapshot(
            self.root / "extent",
            profile="clean",
            binary_data=b"extent",
        )
        self.rewrite(
            path,
            lambda value: value["machine"].update(
                {"extent": {"width": 1100, "height": 1160}}
            ),
        )
        with self.assertRaisesRegex(perf.ProtocolError, "954"):
            perf._load_snapshot(path)
    def test_vendored_noapi_provenance_rejects_backend_tampering(self) -> None:
        source_root = perf._project_root()
        project = self.root / "project"
        (project / "vendor").mkdir(parents=True)
        shutil.copytree(source_root / "vendor" / "noapi", project / "vendor" / "noapi")
        shutil.copy2(
            source_root / "vendor" / "noapi-provenance.json",
            project / "vendor" / "noapi-provenance.json",
        )
        provenance = perf._load_noapi_provenance(project)
        self.assertRegex(provenance["content_digest"], r"^[0-9a-f]{64}$")
        self.assertEqual(len(provenance["source"]["commit_id"]), 40)
        self.assertEqual(len(provenance["source"]["change_id"]), 32)
        tampered = project / "vendor" / "noapi" / "noapi" / "Gpu.zig"
        tampered.write_bytes(tampered.read_bytes() + b"\n")
        with self.assertRaisesRegex(perf.ProtocolError, "provenance"):
            perf._load_noapi_provenance(project)



    def test_freeze_artifact_copies_bytes_and_makes_them_read_only(self) -> None:
        source = self.root / "source.bin"
        source.write_bytes(b"immutable evidence")
        destination = self.root / "artifact" / "copy.bin"
        digest = perf.freeze_artifact(source, destination)
        self.assertEqual(destination.read_bytes(), source.read_bytes())
        self.assertEqual(digest, sha256_bytes(source.read_bytes()))
        self.assertEqual(destination.stat().st_mode & 0o222, 0)

    def test_jj_identity_uses_ungraphed_read_only_full_ids(self) -> None:
        calls: list[list[str]] = []

        def runner(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
            calls.append(argv)
            return subprocess.CompletedProcess(
                argv,
                0,
                stdout=f"{NOGUI_CHANGE_ID}\n{NOGUI_COMMIT_ID}\n",
                stderr="",
            )

        identity = perf.capture_jj_identity(self.root, runner=runner)
        self.assertEqual(
            identity,
            {"change_id": NOGUI_CHANGE_ID, "commit_id": NOGUI_COMMIT_ID},
        )
        self.assertIn("--no-graph", calls[0])
        forbidden = {"new", "describe", "abandon", "rebase", "edit", "squash"}
        self.assertTrue(forbidden.isdisjoint(calls[0]))

    def test_jj_identity_rejects_abbreviated_or_extra_output(self) -> None:
        for output in (
            f"short\n{NOGUI_COMMIT_ID}\n",
            f"{NOGUI_CHANGE_ID}\nshort\n",
            f"{NOGUI_CHANGE_ID}\n{NOGUI_COMMIT_ID}\nextra\n",
        ):
            runner = mock.Mock(return_value=subprocess.CompletedProcess(
                ["jj"],
                0,
                stdout=output,
                stderr="",
            ))
            with self.subTest(output=output), self.assertRaisesRegex(
                perf.ProtocolError,
                "identity",
            ):
                perf.capture_jj_identity(self.root, runner=runner)

    def test_runtime_header_requires_present_feedback(self) -> None:
        runtime = {
            "scene": "todo",
            "mode": "offscreen",
            "instrumentation_flags": flags_for("clean"),
            "child_argv": ["artifact/v7-demo"],
            **valid_identity(),
            "reported_refresh_data": None,
            "warmup_frames": 0,
            "sample_count": 1,
        }
        with self.assertRaisesRegex(perf.ProtocolError, "present_feedback"):
            perf._validate_runtime_header(
                runtime,
                expected_scene="todo",
                expected_mode="offscreen",
                expected_profile="clean",
                expected_argv=["artifact/v7-demo"],
                expected_warmup_frames=0,
                expected_sample_count=1,
            )

    def test_final_header_uses_snapshot_ids_not_current_workspace(self) -> None:
        manifest = {
            "optimize_mode": "Debug",
            "instrumentation_flags": flags_for("clean"),
            "binary": {"sha256": HASH_A},
            "runner_sha256": HASH_B,
            "shaders": {
                name: {"sha256": HASH_C} for name in perf.SHADER_FILES
            },
            "nogui": {"change_id": NOGUI_CHANGE_ID, "commit_id": NOGUI_COMMIT_ID},
            "noapi": {
                "change_id": NOAPI_CHANGE_ID,
                "commit_id": NOAPI_COMMIT_ID,
                "content_digest": HASH_A,
            },
            "zig_version": "0.16.0",
        }
        runtime = {
            **valid_identity(),
            "extent": {"width": 954, "height": 1044},
            "present_mode": "fifo",
            "reported_refresh_data": None,
            "present_feedback": False,
        }
        header = perf.merge_final_header(
            manifest,
            runtime,
            scene="todo",
            mode="offscreen",
            block_id=4,
            order_position=2,
            child_argv=["artifact/v7-demo"],
            warmup_rule={"frames": 600, "manifest_sha256": HASH_C},
            seed=9,
            sample_count=1000,
        )
        self.assertEqual(header["nogui_jj_change_id"], NOGUI_CHANGE_ID)
        self.assertEqual(header["nogui_jj_commit_id"], NOGUI_COMMIT_ID)
        self.assertEqual(header["noapi_content_digest"], HASH_A)


class TracyProtocolTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.csv_path = self.root / "events.csv"

    def ready_popen(self, children: object) -> object:
        sequence = iter(children)
        startup_log: Path | None = None

        def popen(argv: list[str], **kwargs: object) -> FakeProcess:
            nonlocal startup_log
            trace = Path(argv[argv.index("-o") + 1]) if argv[0] == "tracy-capture" else None
            if trace is not None:
                startup_log = Path(
                    str(trace).removesuffix(".partial") + ".startup.partial"
                )
                startup_log.write_text(
                    "Connecting to 127.0.0.1:8086...",
                    encoding="utf-8",
                )
            elif startup_log is not None:
                with startup_log.open("a", encoding="utf-8") as output:
                    output.write("\nTimer resolution: test\n")
            return next(sequence)

        return popen

    def write_events(self, rows: list[list[object]]) -> None:
        with self.csv_path.open("w", encoding="utf-8", newline="") as output:
            writer = csv.writer(output)
            writer.writerow(
                [
                    "name",
                    "src_file",
                    "src_line",
                    "ns_since_start",
                    "exec_time_ns",
                    "thread",
                    "value",
                ]
            )
            writer.writerows(rows)

    def valid_rows(self) -> list[list[object]]:
        return [
            ["perfWarmupFrame", "perf.zig", 1, 0, 100, 1, ""],
            ["warmupChild", "perf.zig", 2, 10, 10, 1, ""],
            ["perfSampleFrame", "perf.zig", 3, 1000, 100, 1, ""],
            ["zoneA", "perf.zig", 4, 1010, 50, 1, ""],
            ["zoneB", "perf.zig", 5, 1020, 10, 1, ""],
            ["perfSampleFrame", "perf.zig", 3, 2000, 100, 1, ""],
            ["zoneA", "perf.zig", 4, 2010, 60, 1, ""],
        ]

    def test_tracy_summary_uses_only_complete_sample_roots(self) -> None:
        self.write_events(self.valid_rows())
        summary = perf.parse_tracy_csv(self.csv_path, expected_sample_roots=2)
        self.assertNotIn("warmupChild", summary["zones"])
        self.assertEqual(summary["sample_root_count"], 2)
        self.assertEqual(summary["zones"]["zoneA"], {
            "call_count": 2,
            "inclusive_ns": 110,
            "self_ns": 100,
            "median_ns": 55,
            "p99_ns": 60,
        })
        self.assertEqual(summary["zones"]["zoneB"]["self_ns"], 10)
    def test_nested_zones_across_frames_and_threads_keep_direct_child_self_time(self) -> None:
        self.write_events([
            ["perfSampleFrame", "perf.zig", 3, 100, 100, 1, ""],
            ["outerA", "perf.zig", 4, 110, 80, 1, ""],
            ["innerA", "perf.zig", 5, 120, 20, 1, ""],
            ["otherThreadA", "perf.zig", 6, 130, 10, 2, ""],
            ["perfSampleFrame", "perf.zig", 3, 300, 100, 2, ""],
            ["outerB", "perf.zig", 4, 310, 70, 2, ""],
            ["innerB", "perf.zig", 5, 320, 20, 2, ""],
            ["otherThreadB", "perf.zig", 6, 330, 10, 1, ""],
        ])
        summary = perf.parse_tracy_csv(self.csv_path, expected_sample_roots=2)
        self.assertEqual(summary["sample_root_count"], 2)
        self.assertEqual(summary["zones"]["outerA"], {
            "call_count": 1,
            "inclusive_ns": 80,
            "self_ns": 60,
            "median_ns": 80,
            "p99_ns": 80,
        })
        self.assertEqual(summary["zones"]["outerB"]["self_ns"], 50)
        self.assertEqual(summary["zones"]["otherThreadA"]["self_ns"], 10)
        self.assertEqual(summary["zones"]["otherThreadB"]["self_ns"], 10)


    def test_wrong_sample_root_count_rejects(self) -> None:
        self.write_events(self.valid_rows())
        with self.assertRaisesRegex(perf.ProtocolError, "sample roots"):
            perf.parse_tracy_csv(self.csv_path, expected_sample_roots=3)
    def test_tracy_integer_type_errors_become_protocol_errors(self) -> None:
        with self.assertRaises(perf.ProtocolError):
            perf._csv_int(None, "start")


    def test_overlapping_sample_roots_reject(self) -> None:
        rows = self.valid_rows()
        rows[5][3] = 1050
        self.write_events(rows)
        with self.assertRaisesRegex(perf.ProtocolError, "overlap"):
            perf.parse_tracy_csv(self.csv_path, expected_sample_roots=2)

    def test_child_crossing_root_boundary_rejects(self) -> None:
        rows = self.valid_rows()
        rows.insert(5, ["crossing", "perf.zig", 6, 1090, 20, 1, ""])
        self.write_events(rows)
        with self.assertRaisesRegex(perf.ProtocolError, "boundary"):
            perf.parse_tracy_csv(self.csv_path, expected_sample_roots=2)

    def test_busy_tracy_port_rejects_without_touching_listener(self) -> None:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.addCleanup(listener.close)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        port = listener.getsockname()[1]
        with self.assertRaisesRegex(perf.ProtocolError, "busy"):
            perf.ensure_port_available(port=port)
        self.assertEqual(listener.getsockname()[1], port)

    def test_capture_readiness_requires_observable_signal(self) -> None:
        capture = FakeProcess(returncode=0)
        children = iter([capture])
        with self.assertRaisesRegex(perf.ProtocolError, "readiness"):
            perf.run_tracy_capture(
                demo_argv=["artifact/v7-demo"],
                trace_path=self.root / "silent.tracy",
                csv_path=self.root / "silent.csv",
                sample_roots=1,
                process_timeout_s=1.0,
                export_timeout_s=1.0,
                readiness_timeout_s=0.01,
                popen_factory=lambda *args, **kwargs: next(children),
                runner=mock.Mock(),
                port_checker=lambda **kwargs: None,
            )

    def test_capture_requires_post_connection_marker_after_demo(self) -> None:
        trace_path = self.root / "post-handshake.tracy"
        temporary_trace = trace_path.with_name(trace_path.name + ".partial")
        startup_log = trace_path.with_name(trace_path.name + ".startup.partial")
        capture = FakeProcess(
            returncode=0,
            on_wait=lambda: temporary_trace.write_bytes(b"trace"),
        )
        demo = FakeProcess(returncode=0)
        children = iter([capture, demo])
        demo_started = False

        def popen(argv: list[str], **_: object) -> FakeProcess:
            nonlocal demo_started
            if argv[0] == "tracy-capture":
                startup_log.write_text(
                    "Connecting to 127.0.0.1:8086...",
                    encoding="utf-8",
                )
            else:
                demo_started = True
            return next(children)

        def export(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
            output = kwargs["stdout"]
            assert hasattr(output, "write")
            output.write(
                "name,src_file,ns_since_start,exec_time_ns,thread\n"
                "perfSampleFrame,perf.zig,0,100,1\n"
                "perfSampleFrame,perf.zig,200,100,1\n"
            )
            output.flush()
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        with self.assertRaisesRegex(perf.ProtocolError, "readiness"):
            perf.run_tracy_capture(
                demo_argv=["artifact/v7-demo"],
                trace_path=trace_path,
                csv_path=self.root / "post-handshake.csv",
                sample_roots=2,
                process_timeout_s=1.0,
                export_timeout_s=1.0,
                readiness_timeout_s=0.01,
                popen_factory=popen,
                runner=export,
                port_checker=lambda **kwargs: None,
            )
        self.assertTrue(demo_started)
    def test_capture_timeout_terminates_only_spawned_children(self) -> None:
        capture = FakeProcess(returncode=0)
        demo = FakeProcess(returncode=0, timeout=True)
        children = iter([capture, demo])
        with self.assertRaisesRegex(perf.ProtocolError, "timed out"):
            perf.run_tracy_capture(
                demo_argv=["artifact/v7-demo", "--perf-mode", "offscreen"],
                trace_path=self.root / "cell-0.tracy",
                csv_path=self.csv_path,
                sample_roots=2,
                process_timeout_s=1.0,
                export_timeout_s=1.0,
                popen_factory=self.ready_popen(children),
                runner=mock.Mock(),
                port_checker=lambda **kwargs: None,
            )
        self.assertTrue(capture.terminated)
        self.assertTrue(demo.terminated)

    def test_capture_child_failure_rejects(self) -> None:
        capture = FakeProcess(returncode=1)
        demo = FakeProcess(returncode=0)
        children = iter([capture, demo])
        with self.assertRaisesRegex(perf.ProtocolError, "capture"):
            perf.run_tracy_capture(
                demo_argv=["artifact/v7-demo"],
                trace_path=self.root / "cell-0.tracy",
                csv_path=self.csv_path,
                sample_roots=2,
                process_timeout_s=1.0,
                export_timeout_s=1.0,
                popen_factory=self.ready_popen(children),
                runner=mock.Mock(),
                port_checker=lambda **kwargs: None,
            )

    def test_export_subprocess_failure_rejects(self) -> None:
        trace_path = self.root / "cell-0.tracy"
        temporary_trace = trace_path.with_name(trace_path.name + ".partial")
        capture = FakeProcess(
            returncode=0,
            on_wait=lambda: temporary_trace.write_bytes(b"trace"),
        )
        demo = FakeProcess(returncode=0)
        children = iter([capture, demo])
        runner = mock.Mock(
            return_value=subprocess.CompletedProcess(
                ["tracy-csvexport"],
                1,
                stdout="",
                stderr="export failed",
            )
        )
        with self.assertRaisesRegex(perf.ProtocolError, "csvexport"):
            perf.run_tracy_capture(
                demo_argv=["artifact/v7-demo"],
                trace_path=trace_path,
                csv_path=self.csv_path,
                sample_roots=2,
                process_timeout_s=1.0,
                export_timeout_s=1.0,
                popen_factory=self.ready_popen(children),
                runner=runner,
                port_checker=lambda **kwargs: None,
            )
        self.assertFalse(trace_path.exists())
        self.assertFalse(self.csv_path.exists())
        self.assertFalse(any(self.root.glob("*.partial")))

    def test_tracy_commands_are_direct_argv_and_artifacts_are_hashed(self) -> None:
        trace_path = self.root / "cell-7.tracy"
        temporary_trace = trace_path.with_name(trace_path.name + ".partial")
        capture = FakeProcess(
            returncode=0,
            on_wait=lambda: temporary_trace.write_bytes(b"trace"),
        )
        demo = FakeProcess(returncode=0)
        children = iter([capture, demo])
        popen_calls: list[list[str]] = []
        def popen(argv: list[str], **kwargs: object) -> FakeProcess:
            if argv[0] == "tracy-capture":
                os.write(int(kwargs["stdout"]), b"\nConnecting to 127.0.0.1:8086...\n")
            else:
                startup_log = Path(
                    str(temporary_trace).removesuffix(".partial") + ".startup.partial"
                )
                with startup_log.open("a", encoding="utf-8") as output:
                    output.write("Timer resolution: test\n")
            popen_calls.append(argv)
            return next(children)

        def runner(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
            self.assertEqual(
                argv,
                ["tracy-csvexport", "-u", str(temporary_trace)],
            )
            output = kwargs["stdout"]
            assert hasattr(output, "write")
            output.write(
                "name,src_file,src_line,ns_since_start,exec_time_ns,thread,value\n"
                "perfSampleFrame,perf.zig,1,0,100,1,\n"
                "perfSampleFrame,perf.zig,1,200,100,1,\n"
            )
            output.flush()
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        evidence = perf.run_tracy_capture(
            demo_argv=["artifact/v7-demo", "--perf-mode", "offscreen"],
            trace_path=trace_path,
            csv_path=self.csv_path,
            sample_roots=2,
            process_timeout_s=1.0,
            export_timeout_s=1.0,
            popen_factory=popen,
            runner=runner,
            port_checker=lambda **kwargs: None,
        )
        self.assertEqual(
            popen_calls[0],
            [
                "tracy-capture",
                "-o",
                str(temporary_trace),
                "-a",
                "127.0.0.1",
                "-p",
                "8086",
                "-f",
            ],
        )
        self.assertEqual(popen_calls[1][0], "artifact/v7-demo")
        self.assertEqual(evidence["trace_sha256"], sha256_bytes(b"trace"))
        self.assertEqual(evidence["csv_sha256"], perf.sha256_file(self.csv_path))


class FakeProcess:
    def __init__(
        self,
        *,
        returncode: int,
        timeout: bool = False,
        on_wait: object | None = None,
    ) -> None:
        self.returncode = returncode
        self.timeout = timeout
        self.on_wait = on_wait
        self.waited = False
        self.terminated = False
        self.killed = False

    def wait(self, timeout: float | None = None) -> int:
        if self.timeout and not self.terminated:
            raise subprocess.TimeoutExpired(["fake"], timeout)
        self.waited = True
        if callable(self.on_wait):
            self.on_wait()
        return self.returncode

    def poll(self) -> int | None:
        if not self.waited and not self.terminated:
            return None
        return self.returncode

    def terminate(self) -> None:
        self.terminated = True

    def kill(self) -> None:
        self.killed = True
        self.terminated = True


class MachineAndQualificationRegressionTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def test_unavailable_gpu_and_empty_affinity_reject(self) -> None:
        failed_gpu = mock.Mock(
            return_value=subprocess.CompletedProcess(
                ["lspci", "-nnk"],
                0,
                stdout="",
                stderr="",
            )
        )
        with self.assertRaisesRegex(perf.ProtocolError, "GPU/driver"):
            perf._gpu_driver(runner=failed_gpu)
        with mock.patch.object(perf.os, "sched_getaffinity", return_value=set()):
            with self.assertRaisesRegex(perf.ProtocolError, "affinity is empty"):
                perf.capture_machine_identity(
                    runner=failed_gpu,
                )

    def test_affinity_is_applied_in_child_preexec(self) -> None:
        runner = mock.Mock(
            return_value=subprocess.CompletedProcess(
                ["tool"],
                0,
                stdout="",
                stderr="",
            )
        )
        with mock.patch.object(perf.os, "sched_setaffinity") as set_affinity:
            perf.run_checked(["tool"], timeout_s=1.0, affinity=[2, 3], runner=runner)
            preexec = runner.call_args.kwargs["preexec_fn"]
            preexec()
        set_affinity.assert_called_once_with(0, {2, 3})

    def test_qualification_order_is_seeded_and_balanced(self) -> None:
        first = perf.balanced_cell_orders(
            ("clean", "gpu"),
            block_count=4,
            seed=123,
            control="clean",
        )
        second = perf.balanced_cell_orders(
            ("clean", "gpu"),
            block_count=4,
            seed=123,
            control="clean",
        )
        self.assertEqual(first, second)
        self.assertEqual(
            sum(order.index("gpu") < order.index("clean") for order in first),
            2,
        )

    def test_presented_qualification_without_timing_fails(self) -> None:
        clean = valid_block(self.root, profile="clean", name="clean")
        gpu = valid_block(self.root, profile="gpu", name="gpu")
        presented = valid_block(
            self.root,
            profile="clean",
            mode="presented",
            name="presented",
        )
        presented.header["present_feedback"] = False
        snapshots = {
            "clean": perf._load_snapshot(
                write_snapshot(
                    self.root / "snapshot-clean",
                    profile="clean",
                    binary_data=b"clean",
                )
            ),
            "gpu": perf._load_snapshot(
                write_snapshot(
                    self.root / "snapshot-gpu",
                    profile="gpu",
                    binary_data=b"gpu",
                )
            ),
        }
        with mock.patch.object(
            perf,
            "_run_demo_block",
            side_effect=[clean, gpu, presented],
        ):
            self.assertTrue(perf._run_qualification_block(
                "todo",
                0,
                snapshots=snapshots,
                warmup_frames=1,
                mode="presented",
                out=self.root / "out",
                seed=1,
                warmup_rule={"frames": 1, "manifest_sha256": HASH_C},
            ))


class CommandExecutionRegressionTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.warmup_path = write_warmup_manifest(self.root / "source-warmup")
        self.snapshots: dict[str, perf.Snapshot] = {}
        for profile in ("clean", "tracy", "gpu", "mechanism"):
            path = write_snapshot(
                self.root / "matrix-snapshots" / profile,
                profile=profile,
                binary_data=f"matrix-{profile}".encode(),
            )
            self.snapshots[profile] = perf._load_snapshot(path)
        self.pair_snapshots: dict[str, tuple[perf.Snapshot, perf.Snapshot]] = {}
        for profile in perf.PAIR_PROFILES:
            baseline = write_snapshot(
                self.root / "baseline" / profile,
                profile=profile,
                binary_data=f"baseline-{profile}".encode(),
            )
            candidate = write_snapshot(
                self.root / "candidate" / profile,
                profile=profile,
                binary_data=f"candidate-{profile}".encode(),
            )
            self.pair_snapshots[profile] = (
                perf._load_snapshot(baseline),
                perf._load_snapshot(candidate),
            )

    def test_all_handlers_execute_with_fake_children_and_publish_artifacts(self) -> None:
        fake_children: list[tuple[str, str]] = []
        child_timeouts: list[float] = []
        tracy_timeouts: list[float] = []
        fake_snapshots: list[perf.Snapshot] = []
        binary_profiles: dict[str, str] = {}
        for snapshot in self.snapshots.values():
            binary_profiles[str(snapshot.path.parent / "v7-demo")] = str(
                snapshot.manifest["profile"]
            )
        for baseline, candidate in self.pair_snapshots.values():
            for snapshot in (baseline, candidate):
                binary_profiles[str(snapshot.path.parent / "v7-demo")] = str(
                    snapshot.manifest["profile"]
                )

        def fake_snapshot(args: argparse.Namespace, out: Path, _: Path) -> perf.Snapshot:
            profile = perf.profile_for_flags({
                "tracy": args.tracy,
                "gpu_timestamps": args.gpu_timestamps,
                "perf_counters": args.perf_counters,
            })
            path = write_snapshot(
                out,
                profile=profile,
                binary_data=f"internal-{profile}-{len(fake_snapshots)}".encode(),
            )
            snapshot = perf._load_snapshot(path)
            fake_snapshots.append(snapshot)
            binary_profiles[str(snapshot.path.parent / "v7-demo")] = profile
            return snapshot

        def fake_child_runner(
            argv: list[str],
            **kwargs: object,
        ) -> subprocess.CompletedProcess[str]:
            timeout = kwargs.get("timeout")
            if timeout is not None:
                child_timeouts.append(float(timeout))
            profile = binary_profiles[str(Path(argv[0]))]
            mode = argv[argv.index("--perf-mode") + 1]
            warmup_frames = int(argv[argv.index("--perf-warmup") + 1])
            sample_frames = int(argv[argv.index("--perf-frames") + 1])
            output = Path(argv[argv.index("--perf-out") + 1])
            scene = "todo"
            for candidate in perf.SCENES:
                if candidate != "todo" and f"--{candidate}" in argv:
                    scene = candidate
            header = valid_header(
                profile=profile,
                mode=mode,
                sample_count=sample_frames,
            )
            header.update({
                "scene": scene,
                "child_argv": list(argv),
                "present_mode": "fifo",
                "reported_refresh_data": (
                    {"numerator": 120, "denominator": 1}
                    if mode == "presented"
                    else None
                ),
                "warmup_frames": warmup_frames,
            })
            samples = [
                valid_sample(
                    frame_id,
                    phase="warmup" if frame_id < warmup_frames else "sample",
                    profile=profile,
                    mode=mode,
                )
                for frame_id in range(warmup_frames + sample_frames)
            ]
            output.parent.mkdir(parents=True, exist_ok=True)
            write_jsonl(output, header, samples)
            fake_children.append((profile, mode))
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        def fake_tracy(**kwargs: object) -> dict[str, object]:
            demo_argv = list(kwargs["demo_argv"])
            tracy_timeouts.append(float(kwargs["process_timeout_s"]))
            fake_child_runner(demo_argv)
            trace = Path(kwargs["trace_path"])
            csv_path = Path(kwargs["csv_path"])
            temporary_trace = trace.with_name(trace.name + ".partial")
            temporary_csv = csv_path.with_name(csv_path.name + ".partial")
            trace.parent.mkdir(parents=True, exist_ok=True)
            temporary_trace.write_bytes(b"fake tracy trace")
            temporary_csv.write_text("fake tracy csv", encoding="utf-8")
            return {
                "trace_path": str(trace),
                "csv_path": str(csv_path),
                "trace_temporary_path": str(temporary_trace),
                "csv_temporary_path": str(temporary_csv),
                "trace_sha256": perf.sha256_file(temporary_trace),
                "csv_sha256": perf.sha256_file(temporary_csv),
                "summary": {"sample_root_count": 1, "zones": {}},
            }

        real_demo = perf._run_demo_block

        def fake_demo(snapshot: perf.Snapshot, **kwargs: object) -> perf.ProcessBlock:
            return real_demo(
                snapshot,
                runner=fake_child_runner,
                identity_runner=mock.Mock(return_value=valid_identity()),
                **kwargs,
            )

        snapshot_args = [
            "snapshot",
            "--optimize", "Debug",
            "--tracy", "false",
            "--gpu-timestamps", "false",
            "--perf-counters", "false",
            "--out", str(self.root / "snapshot-command"),
        ]
        calibrate_args = [
            "calibrate",
            "--frames", "2400",
            "--seed", "7",
            "--out", str(self.root / "calibrate-command"),
        ]
        matrix_args = [
            "matrix",
            "--warmup-from", str(self.warmup_path),
            "--blocks", "1",
            "--frames", "1",
            "--seed", "7",
            "--report", str(self.root / "matrix-command" / "report.json"),
            "--out", str(self.root / "matrix-command"),
        ]
        pair_args = [
            "pair",
            "--baseline-clean-manifest", str(self.pair_snapshots["clean"][0].path),
            "--candidate-clean-manifest", str(self.pair_snapshots["clean"][1].path),
            "--baseline-gpu-manifest", str(self.pair_snapshots["gpu"][0].path),
            "--candidate-gpu-manifest", str(self.pair_snapshots["gpu"][1].path),
            "--baseline-mechanism-manifest", str(self.pair_snapshots["mechanism"][0].path),
            "--candidate-mechanism-manifest", str(self.pair_snapshots["mechanism"][1].path),
            "--warmup-from", str(self.warmup_path),
            "--blocks", "2",
            "--frames", "1",
            "--seed", "7",
            "--out", str(self.root / "pair-command"),
        ]
        qualify_args = [
            "qualify",
            "--warmup-from", str(self.warmup_path),
            "--blocks", "2",
            "--frames", "1",
            "--seed", "7",
            "--report", str(self.root / "qualify-command" / "report.json"),
            "--out", str(self.root / "qualify-command"),
        ]
        with (
            mock.patch.object(perf, "_snapshot_manifest", side_effect=fake_snapshot),
            mock.patch.object(perf, "_run_demo_block", side_effect=fake_demo),
            mock.patch.object(
                perf,
                "_required_snapshot_profiles",
                return_value=self.snapshots,
            ),
            mock.patch.object(
                perf,
                "validate_pair_manifests",
                return_value=self.pair_snapshots,
            ),
            mock.patch.object(
                perf,
                "capture_machine_identity",
                return_value=valid_identity(),
            ),
            mock.patch.object(perf, "run_tracy_capture", side_effect=fake_tracy),
            mock.patch.object(perf, "sustained_stable_boundary", return_value=600),
            mock.patch.object(perf, "QUALIFICATION_BLOCKS", 2),
            mock.patch.object(perf, "QUALIFICATION_FRAMES", 1),
        ):
            self.assertEqual(perf.main(snapshot_args), 0)
            self.assertEqual(perf.main(calibrate_args), 0)
            self.assertEqual(perf.main(matrix_args), 0)
            self.assertEqual(perf.main(pair_args), 0)
            self.assertEqual(perf.main(qualify_args), 0)
        for path in (
            self.root / "snapshot-command" / "snapshot.json",
            self.root / "calibrate-command" / "warmup.json",
            self.root / "matrix-command" / "report.json",
            self.root / "pair-command" / "pair.json",
            self.root / "qualify-command" / "report.json",
        ):
            self.assertTrue(path.is_file(), path)
        matrix_report = json.loads(
            (self.root / "matrix-command" / "report.json").read_text(encoding="utf-8")
        )
        required_cells = {
            (cell["optimize_mode"], cell["mode"])
            for cell in matrix_report["required_cells"]
        }
        self.assertEqual(
            required_cells,
            {
                ("Debug", "offscreen"),
                ("ReleaseFast", "offscreen"),
                ("Debug", "presented"),
            },
        )
        expected_profiles = {"clean", "tracy", "gpu", "mechanism"}
        for optimize_mode, mode in required_cells:
            self.assertEqual(
                {
                    summary["profile"]
                    for summary in matrix_report["summaries"]
                    if summary["optimize_mode"] == optimize_mode
                    and summary["mode"] == mode
                },
                expected_profiles,
            )
        pair_report = json.loads(
            (self.root / "pair-command" / "pair.json").read_text(encoding="utf-8")
        )
        qualify_report = json.loads(
            (self.root / "qualify-command" / "report.json").read_text(encoding="utf-8")
        )
        self.assertEqual(pair_report["stability_rule"], TEST_STABILITY_RULE)
        self.assertEqual(pair_report["stability_status"], "sustained")
        self.assertEqual(qualify_report["stability_rule"], TEST_STABILITY_RULE)
        self.assertEqual(qualify_report["stability_status"], "sustained")
        for path in self.root.rglob("*"):
            self.assertFalse(path.name.endswith((".partial", ".writing")), path)
        self.assertTrue(child_timeouts)
        self.assertEqual(set(child_timeouts), {perf.PERF_CHILD_TIMEOUT_S})
        self.assertTrue(tracy_timeouts)
        self.assertEqual(set(tracy_timeouts), {perf.PERF_CHILD_TIMEOUT_S})

class OrderingAndCommandTests(unittest.TestCase):
    def test_affinity_ranges_expand_sorted_cpu_sets(self) -> None:
        self.assertEqual(perf.parse_cpu_list("6-7,10"), [6, 7, 10])
        with self.assertRaises(argparse.ArgumentTypeError):
            perf.parse_cpu_list("7-6")

    def test_matrix_orders_balance_each_observer_against_clean(self) -> None:
        cells = ("clean", "tracy", "gpu", "mechanism")
        orders = perf.balanced_cell_orders(cells, block_count=4, seed=7, control="clean")
        self.assertEqual(len(orders), 4)
        for order in orders:
            self.assertEqual(set(order), set(cells))
        for observer in cells[1:]:
            before = sum(order.index(observer) < order.index("clean") for order in orders)
            self.assertEqual(before, 2)

    def test_pair_orders_are_ab_ba_for_every_profile(self) -> None:
        orders = perf.paired_block_orders(perf.PAIR_PROFILES, block_count=4, seed=11)
        for profile in perf.PAIR_PROFILES:
            orientations = [
                tuple(variant for item_profile, variant in order if item_profile == profile)
                for order in orders
            ]
            self.assertEqual(orientations.count(("baseline", "candidate")), 2)
            self.assertEqual(orientations.count(("candidate", "baseline")), 2)
    def test_odd_logical_count_has_near_balanced_orders(self) -> None:
        cells = ("clean", "tracy", "gpu", "mechanism")
        orders = perf.balanced_cell_orders(cells, block_count=5, seed=7, control="clean")
        self.assertEqual(len(orders), 5)
        for order in orders:
            self.assertEqual(set(order), set(cells))
        for observer in cells[1:]:
            before = sum(order.index(observer) < order.index("clean") for order in orders)
            after = len(orders) - before
            self.assertLessEqual(abs(before - after), 1)

    def test_finite_subprocess_uses_shell_false_and_direct_argv(self) -> None:
        runner = mock.Mock(
            return_value=subprocess.CompletedProcess(
                ["tool", "arg"],
                0,
                stdout="ok",
                stderr="",
            )
        )
        result = perf.run_checked(["tool", "arg"], timeout_s=1.0, runner=runner)
        self.assertEqual(result.stdout, "ok")
        _, kwargs = runner.call_args
        self.assertIs(kwargs["shell"], False)
        self.assertEqual(runner.call_args.args[0], ["tool", "arg"])

    def test_demo_argv_uses_one_process_block_and_exact_frame_counts(self) -> None:
        argv = perf.demo_argv(
            Path("artifact/v7-demo"),
            scene="spotify",
            mode="presented",
            warmup_frames=600,
            sample_frames=1000,
            output_path=Path("raw/block.jsonl"),
        )
        self.assertEqual(argv[0], "artifact/v7-demo")
        self.assertIn("--spotify", argv)
        self.assertEqual(argv[argv.index("--perf-warmup") + 1], "600")
        self.assertEqual(argv[argv.index("--perf-frames") + 1], "1000")
        self.assertNotIn(";", argv)

    def test_calibration_requires_exactly_2400_frames(self) -> None:
        parser = perf.build_parser()
        args = parser.parse_args([
            "calibrate",
            "--frames",
            "2399",
            "--seed",
            "1",
            "--out",
            "/tmp/calibrate",
        ])
        with self.assertRaisesRegex(perf.ProtocolError, "2,400"):
            perf.validate_command_args(args)

    def test_matrix_requires_positive_block_count(self) -> None:
        parser = perf.build_parser()
        args = parser.parse_args([
            "matrix",
            "--warmup-from",
            "warmup.json",
            "--blocks",
            "0",
            "--frames",
            "1000",
            "--seed",
            "1",
            "--report",
            "report.json",
            "--out",
            "/tmp/matrix",
        ])
        with self.assertRaisesRegex(perf.ProtocolError, "positive"):
            perf.validate_command_args(args)

    def test_qualify_requires_exact_blocks_and_sample_length(self) -> None:
        parser = perf.build_parser()
        base = [
            "qualify",
            "--warmup-from",
            "warmup.json",
            "--seed",
            "1",
            "--report",
            "report.json",
            "--out",
            "/tmp/qualify",
        ]
        args = parser.parse_args([*base, "--blocks", "299", "--frames", "1000"])
        with self.assertRaisesRegex(perf.ProtocolError, "300"):
            perf.validate_command_args(args)
        args = parser.parse_args([*base, "--blocks", "300", "--frames", "999"])
        with self.assertRaisesRegex(perf.ProtocolError, "1,000"):
            perf.validate_command_args(args)

    def test_all_five_subcommands_parse_task_invocations(self) -> None:
        parser = perf.build_parser()
        invocations = [
            [
                "snapshot",
                "--optimize",
                "Debug",
                "--tracy",
                "false",
                "--gpu-timestamps",
                "false",
                "--perf-counters",
                "false",
                "--out",
                "/tmp/snapshot",
            ],
            ["calibrate", "--frames", "2400", "--seed", "0x10", "--out", "/tmp/c"],
            [
                "matrix",
                "--affinity",
                "6-7",

                "--warmup-from",
                "warmup.json",
                "--blocks",
                "10",
                "--frames",
                "1000",
                "--seed",
                "0x10",
                "--report",
                "report.json",
                "--out",
                "/tmp/m",
            ],
            [
                "pair",
                "--baseline-clean-manifest",
                "bc.json",
                "--candidate-clean-manifest",
                "cc.json",
                "--baseline-gpu-manifest",
                "bg.json",
                "--candidate-gpu-manifest",
                "cg.json",
                "--baseline-mechanism-manifest",
                "bm.json",
                "--candidate-mechanism-manifest",
                "cm.json",
                "--warmup-from",
                "warmup.json",
                "--blocks",
                "20",
                "--frames",
                "1000",
                "--seed",
                "0x10",
                "--out",
                "/tmp/p",
            ],
            [
                "qualify",
                "--warmup-from",
                "warmup.json",
                "--blocks",
                "300",
                "--frames",
                "1000",
                "--seed",
                "0x10",
                "--report",
                "report.json",
                "--out",
                "/tmp/q",
            ],
        ]
        self.assertEqual(
            [parser.parse_args(argv).command for argv in invocations],
            ["snapshot", "calibrate", "matrix", "pair", "qualify"],
        )

    def test_matrix_defaults_cover_required_optimization_and_modes(self) -> None:
        parser = perf.build_parser()
        args = parser.parse_args([
            "matrix",
            "--warmup-from",
            "warmup.json",
            "--seed",
            "7",
            "--report",
            "report.json",
            "--out",
            "matrix",
        ])
        self.assertEqual(args.blocks, 10)
        self.assertEqual(args.frames, 1_000)
        self.assertEqual(
            perf._matrix_cells(args),
            [
                ("Debug", "offscreen"),
                ("ReleaseFast", "offscreen"),
                ("Debug", "presented"),
            ],
        )

    def test_scene_filter_is_diagnostic_not_acceptance_calibration(self) -> None:
        scenes, acceptance = perf.calibration_scenes("spotify")
        self.assertEqual(scenes, ("spotify",))
        self.assertFalse(acceptance)
        self.assertEqual(perf.calibration_scenes(None), (perf.SCENES, True))


class CalibrationTests(unittest.TestCase):
    def test_constant_diagnostics_choose_first_stable_boundary(self) -> None:
        values = [1_000_000] * 2400
        self.assertEqual(perf.sustained_stable_boundary(values), 600)
    def test_calibration_rejects_extra_diagnostics(self) -> None:

        with self.assertRaisesRegex(perf.ProtocolError, "exactly"):
            perf.sustained_stable_boundary([1_000_000] * 2401)
        with self.assertRaisesRegex(perf.ProtocolError, "exactly"):
            perf.sustained_stable_boundary(
                [1_000_000] * 2400,
                [1_000_000] * 2401,
            )
    def test_calibration_audit_records_all_boundary_spreads(self) -> None:
        clean_cpu = [1_000_000] * 2400
        gpu_execute = [2_000_000] * 2400
        gpu_cpu = [3_000_000] * 2400
        audit = perf.calibration_stability_audit(
            clean_cpu,
            gpu_execute,
            gpu_cpu,
        )
        self.assertEqual(len(audit), 14)
        self.assertEqual(audit[0], {
            "boundary": 600,
            "cpu_spread_basis_points": 0,
            "gpu_spread_basis_points": 0,
            "stable": True,
            "gpu_cpu_spread_basis_points": 0,
        })

    def test_gpu_execution_must_also_be_sustained_stable(self) -> None:
        clean_cpu = [1_000_000] * 2400
        gpu_execute = [1_000_000] * 2400
        gpu_cpu = [1_000_000] * 2400
        gpu_execute[1560:1680] = [2_000_000] * 120
        self.assertEqual(
            perf.sustained_stable_boundary(clean_cpu, gpu_execute, gpu_cpu),
            2040,
        )

    def test_gpu_profile_cpu_must_also_be_sustained_stable(self) -> None:
        clean_cpu = [1_000_000] * 2400
        gpu_execute = [1_000_000] * 2400
        gpu_cpu = [1_000_000] * 2400
        gpu_cpu[1560:1680] = [2_000_000] * 120
        self.assertEqual(
            perf.sustained_stable_boundary(clean_cpu, gpu_execute, gpu_cpu),
            2040,
        )

    def test_no_sustained_stability_rejects(self) -> None:
        values = []
        for window in range(20):
            values.extend([1_000_000 if window % 2 == 0 else 2_000_000] * 120)
        with self.assertRaisesRegex(perf.ProtocolError, "stable"):
            perf.sustained_stable_boundary(values)

    def test_warmup_uses_latest_boundary_plus_fixed_guard_and_cap(self) -> None:
        self.assertEqual(perf.select_warmup_frames([600, 960, 2160]), 2400)
        self.assertEqual(perf.select_warmup_frames([600, 720]), 960)


if __name__ == "__main__":
    unittest.main()
