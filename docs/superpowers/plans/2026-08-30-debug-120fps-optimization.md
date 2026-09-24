# Debug 120 FPS Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Use a fresh isolated Jujutsu workspace for every conditional candidate. Each accepted change needs a task-scoped correctness review and performance review before integration.

**Goal:** Establish a defensible Debug 120 FPS baseline, then remove only measured CPU/GPU work while preserving the pinned layout oracle and render behavior exactly.

**Architecture:** Measurement is a product feature, not an ad-hoc profiler session. The demo gets compile-time instrumentation controls, a raw per-frame sample format, an equivalent three-frame offscreen path, and a presented path with explicit feedback. Optimization candidates remain independent derived-data changes around canonical `WidgetTree`, text, and render state. Phase 0 evidence selects candidates; this document does not require speculative DOD or SIMD work.

**Tech Stack:** Zig 0.16.0, SDL3, noapi/Vulkan, FreeType, HarfBuzz, Tracy, Python 3 standard library for process orchestration, Jujutsu.

## Implementation status (2026-09-09)

This historical plan keeps its original unchecked boxes and measurements. They show the planned protocol, not the current blocker list or a current performance result.

- **Integrated infrastructure:** Task 1 and the source mechanisms from Tasks 2–6 are integrated. Build controls, raw samples, runner subcommands, noapi timing hooks, shared scene recording, and offscreen and presented runners are present.
- **Integrated Task 7 source:** Attribution counters and the amended calibration protocol are present. This integration does not establish an accepted decision baseline.
- **Current oracle:** The stocktake verified 5,524 passed, 0 failed, and 0 unsupported. This result supersedes the historical 5,504-pass and 20-unsupported contract below without changing that evidence.
- **Validated measurement paths:** The offscreen run passes 24 frames and 20 samples with exact CPU stage sums and actual GPU identity. The presented run passes 24 ordered frames and 20 complete samples with positive intervals on driver 595.99.02. A real Tracy capture and CSV export pass with 20 sample roots.
- **Watchdog contract:** Completed EXT presentation feedback resets the watchdog clock. Stalled feedback keeps the five-second deadline. This change does not bypass input guards.
- **Verified gates:** Debug passes 55/55 steps and 970/970 tests. ReleaseSafe passes 48/48 steps and 970/970 tests. The Python suite passes 125 tests.
- **Verified GPU behavior:** All 10 actual-GPU shots are byte-identical to the frozen shots. The remount smoke passes Mandelbrot slot-2 reuse after one hidden frame.
- **Vendored noapi:** The required local commit has no remote, so the integrated tree uses `vendor/noapi`. Its provenance file binds the exact source digest and three patch hashes. The upstream source has no `LICENSE` file. Vendored noapi passes 55/55 tests with Tracy disabled. The original `../noapi` and performance workspace remain untouched.
- **Fresh measurements:** Calibration completed with `capped_unstable` and 2,400 warm-up frames. Only Strokes sustained the rule, at frame 1,920. The full baseline was stopped after reported throughput near 1 FPS. Seven complete Todo Debug offscreen blocks remain diagnostic evidence, not an accepted decision baseline. Their saved Tracy capture identifies repeated text shaping as the dominant CPU contributor. See the README for artifact paths and totals.
- **Conditional work:** This stocktake did not establish trigger or decision states for Tasks 8–18. Those tasks depend on accepted baseline evidence, not current blockers.
- **User-directed cache work:** After stopping the slow matrix, the user requested cross-frame text shaping optimization with bounded captures. Measurement and rendering now share a 256-run, 4 MiB cache with pinned leases and transient overflow. The clean Todo CPU median changed from 199.385 ms to 34.604 ms in 20-sample diagnostics; sampled shaping calls changed from 928 to 3. All ten shot hashes remain unchanged. `docs/perf/text-shaping-cache-diagnostic.json` records the evidence. This does not assign a protocol acceptance state or authorize restarting the full matrix.
- **No qualification claim:** No fixed 300-block, 1,000-frame qualification is established. The integrated measurement code does not prove 120 FPS.

All measurement tables and corpus counts below remain historical evidence. Do not use them as a fresh baseline or qualification result.

## Global Constraints

- Exact frame budget: `1000 ms / 120`; integer gates use `duration_ns * 120 <= 1_000_000_000`, never a rounded decimal threshold.
- Target scenes: Todo, Calculator, Spotify, Tiger, and Strokes at `954x1044` with fixed inputs and assets.
- Perf runs use no audio tracks, no simulated input, fixed scene assets, a fixed window extent, and a recorded process-order seed.
- Perf logical time is deterministic: frame `n` receives `time_ms = (n * 1000) / 120` with integer floor; wall-clock presentation timestamps remain measurement data only.
- Layout oracle: schema 2, 1,381 sources, four variants, 5,524 cases, exactly 5,504 passed, 0 failed, and the same 20 `Unsupported` identities.
- Unsupported identity stream SHA-256: `88071b9fb911c60b49f2999a29964b4805df92a65741bf9d73a88e7c28bf3a2a`.
- Never regenerate fixture expectations, widen the strict `<0.1` comparator, or change `floor(value + 0.5)` rounding to make a candidate pass.
- Old/new layout comparison is bitwise for unrounded observable fields. The frozen fixture comparator runs separately on both paths.
- Preserve source-preorder logical identity, postorder storage, child/root order, callbacks, `ScrollState.offset`, `max_offset`, clip stamps, first-error behavior, and OOM behavior.
- Rendering stays in Oklab until the final sRGB conversion. All GPU access remains through noapi.
- No per-frame heap allocation is added to production hot paths. Candidate-private allocation may select the old path only before mutation, callback, output, or publication.
- Mechanism builds may contain counters and traces. Baseline-versus-candidate timing builds contain no Tracy, GPU queries, or candidate-specific counters.
- CPU, GPU, completion, and presentation samples carry the same frame ID. Never add or subtract unpaired marginal quantiles.
- Only Tasks 1–7 are unconditional. Tasks 8–18 run only when their stated measurement gate is true; Tasks 17–18 can terminate with a documented no-go decision.
- “Phase 0” means Tasks 1–7: oracle hardening, measurement infrastructure, equivalent runners, and the first decision baseline.
- A candidate ends in one of `accepted`, `rejected`, or `not_applicable`. A no-go result never blocks an unrelated candidate.
- After every accepted candidate, rerun the Task 7 measurement matrix because the bottleneck can move.
- Do not execute Tasks 8–16 by numeric order. After each Task 7 matrix, run only the highest measured removable contributor, resolve it, then re-rank the remaining candidates.
- Use `jj`, not mutating Git commands. Each accepted task gets one focused commit. A rejected experiment is abandoned only inside its isolated workspace.

---

## File Map

- `build.zig`: fixture executable, compile-time Tracy/GPU-query/counter controls, perf test target.
- `src/v7/layout/fixture.zig`: exact unsupported-identity digest in `FixtureSummary`.
- `src/v7/layout/fixture_test.zig`: pinned count and digest contract.
- `src/v7/layout/fixture_main.zig`: listener-free fixture oracle executable.
- `src/v7/perf_counters.zig`: compile-time-erased explicit mechanism counter sink.
- `src/v7_demo/perf.zig`: perf CLI types, raw sample schema, timestamp/counter helpers.
- `src/v7_demo/main.zig`: perf argument parsing and scene selection.
- `src/v7_demo/window.zig`: shared frame recording, presented runner, offscreen three-frame runner.
- `../noapi/noapi/{VkBackend,Gpu,Queue,CommandBuffer,Surface,TimestampQuerySet}.zig`: tracked submissions, generic timestamps, and optional actual presentation feedback.
- `tools/run_v7_perf.py`: randomized process-block collection, validation, and report generation.
- `tools/test_run_v7_perf.py`: deterministic statistical/protocol tests.
- `src/v7_demo/text.zig`: shaped-run reuse, line-pass fusion, segment invariant, glyph index.
- `src/v7_demo/svg_view.zig`: generation-safe stroke-style write guard.
- `src/v7/widget.zig`: existing indexed lookup and geometry reference path.
- `src/v7/frame_geometry.zig`: conditional dense shadow projection.
- `src/v7/frame_geometry_test.zig`: bitwise old/new geometry differential.
- `docs/perf/debug-120-baseline.json`: accepted Phase 0 raw-report manifest.
- `docs/perf/debug-120-final.json`: fixed-sample qualification result and raw artifact hashes.
- `docs/perf/debug-120-roadmap.md`: decisions, rejected candidates, accepted effects, and final qualification.

---

### Task 1: Make the fixture oracle a listener-free hard gate

**Files:**
- Modify: `src/v7/layout/fixture.zig:25-29,128-228`
- Modify: `src/v7/layout/fixture_test.zig:5-18`
- Create: `src/v7/layout/fixture_main.zig`
- Modify: `build.zig:188-212`

**Interfaces:**
- Extend `FixtureSummary` with `unsupported_sha256: [32]u8`.
- Hash each unsupported case as `id ++ "\t" ++ variant ++ "\n"` in corpus order.
- Add `zig build fixture`, implemented as a normal executable rather than Zig's `--listen=-` test runner.

- [ ] **Step 1: Add the failing identity-digest assertion**

In `fixture_test.zig`, compute the expected digest from the five IDs and four variants:

```zig
const unsupported_ids = [_][]const u8{
    "flex/intrinsic_sizing_main_size_column.html",
    "flex/intrinsic_sizing_main_size_column_nested.html",
    "flex/intrinsic_sizing_main_size_column_wrap.html",
    "grid/grid_aspect_ratio_fill_child_max_height.html",
    "grid/grid_relayout_vertical_text.html",
};
const variants = [_][]const u8{
    "border_box_ltr",
    "content_box_ltr",
    "border_box_rtl",
    "content_box_rtl",
};
var hasher = std.crypto.hash.sha2.Sha256.init(.{});
for (unsupported_ids) |id| for (variants) |variant| {
    hasher.update(id);
    hasher.update("\t");
    hasher.update(variant);
    hasher.update("\n");
};
var expected: [32]u8 = undefined;
hasher.final(&expected);
try std.testing.expectEqual(expected, result.unsupported_sha256);
```

- [ ] **Step 2: Verify RED**

Run:

```bash
zig build test -Dtest-filter="runs the complete pinned fixture corpus"
```

Expected: compile failure because `unsupported_sha256` does not exist. The known listener timeout can occur after compilation; the required RED signal is the missing field.

- [ ] **Step 3: Implement deterministic digest accumulation**

Initialize a SHA-256 hasher in `runFiltered`. On `error.Unsupported`, update it before incrementing the count. Finalize it on every successful return, including empty ranges. Do not retain corpus string slices in `FixtureSummary`.

```zig
pub const FixtureSummary = struct {
    passed: usize = 0,
    failed: usize = 0,
    unsupported: usize = 0,
    unsupported_sha256: [32]u8 = undefined,
};
```

Use a helper that returns the SHA-256 of an empty stream for early successful returns. Do not use zero bytes as the empty digest.

- [ ] **Step 4: Add the standalone oracle executable**

`fixture_main.zig` calls `fixture.runAll`, checks `5504/0/20`, checks the pinned digest, prints one JSON summary, and returns `error.OracleMismatch` on any difference.

```zig
const expected_digest = [32]u8{
    0x88, 0x07, 0x1b, 0x9f, 0xb9, 0x11, 0xc6, 0x0b,
    0x49, 0xf2, 0x99, 0x9a, 0x29, 0x96, 0x4b, 0x48,
    0x05, 0xdf, 0x92, 0xa6, 0x57, 0x41, 0xbf, 0x9d,
    0x73, 0xa8, 0x8e, 0x7c, 0x28, 0xbf, 0x3a, 0x2a,
};
const summary = try fixture.runAll(allocator, null);
if (summary.passed != 5504 or summary.failed != 0 or summary.unsupported != 20)
    return error.OracleMismatch;
if (!std.mem.eql(
    u8,
    summary.unsupported_sha256[0..],
    expected_digest[0..],
)) return error.OracleMismatch;
```

Wire it as `zig build fixture` with the same `nogui`, `noapi`, Tracy-disabled, and fixture-option imports as `v7_tests`.

- [ ] **Step 5: Verify GREEN**

Run:

```bash
zig build fixture -Doptimize=Debug
```

Expected: exit 0 and JSON containing `5504`, `0`, `20`, and digest `88071b9fb911c60b49f2999a29964b4805df92a65741bf9d73a88e7c28bf3a2a`.

- [ ] **Step 6: Commit**

```bash
jj commit -m "test(layout): pin fixture unsupported identities"
```

---

### Task 2: Separate measurement, attribution, and production builds

**Files:**
- Modify: `build.zig:80-113,188-380`
- Create: `src/v7_demo/perf.zig`
- Create: `src/v7/perf_counters.zig`
- Modify: `src/v7/root.zig`
- Modify: `src/v7_demo/main.zig:64-151`
- Modify: `src/v7_demo/window.zig:26-70,1427-1437`

**Interfaces:**
- Build options: `-Dv7-tracy`, `-Dv7-gpu-timestamps`, `-Dv7-perf-counters`.
- Runtime options: `--perf-mode offscreen|presented`, `--perf-warmup N`, `--perf-frames N`, `--perf-out PATH`.
- `perf.Config` is explicit and passed into `window.run`; no global perf state.
- `perf_counters.Sink(v7_options.perf_counters)` is explicit runner-owned state: it is zero-sized when counters are disabled and contains the only counter pointer when enabled. No process-global or thread-local counter state is allowed.

- [ ] **Step 1: Write failing parser and default tests in `perf.zig`**

```zig
test "perf mode parser rejects unknown modes" {
    try testing.expectEqual(Mode.offscreen, try parseMode("offscreen"));
    try testing.expectEqual(Mode.presented, try parseMode("presented"));
    try testing.expectError(error.InvalidPerfMode, parseMode("shot"));
}

test "perf config rejects zero sample count" {
    try testing.expectError(error.InvalidPerfFrames, Config.validate(.{
        .mode = .offscreen,
        .warmup_frames = 240,
        .sample_frames = 0,
        .output_path = "/tmp/nogui-perf.jsonl",
    }));
}
```

- [ ] **Step 2: Verify RED**

Run `zig build test -Dtest-filter="perf mode"`. Expected: missing `Mode`, `Config`, and `parseMode`.

- [ ] **Step 3: Add compile-time build controls**

In `build.zig`:

```zig
const v7_tracy = b.option(bool, "v7-tracy", "Enable Tracy in v7-demo") orelse false;
const v7_gpu_timestamps = b.option(bool, "v7-gpu-timestamps", "Enable v7 GPU timestamps") orelse false;
const v7_perf_counters = b.option(bool, "v7-perf-counters", "Enable mechanism counters") orelse false;
const v7_options = b.addOptions();
v7_options.addOption(bool, "tracy", v7_tracy);
v7_options.addOption(bool, "gpu_timestamps", v7_gpu_timestamps);
v7_options.addOption(bool, "perf_counters", v7_perf_counters);
```

Select `tracy_impl_enabled` only when `v7_tracy` is true. Add the same `v7_options` import to every root module that transitively imports `src/v7/perf_counters.zig`; explicitly cover `v7_demo`, `v7_tests`, the Task 1 fixture executable, `v7_text_tests`, `v7_ui_tests`, `v7_spotify_tests`, `v7_calculator_tests`, `v7_svg_tests`, and `exe_tests`. This prevents focused tests from acquiring an implicit build-only configuration. In `window.zig`, set `.timestamp_queries = v7_options.gpu_timestamps` instead of hard-coded `true`.

Implement `perf_counters.Counter` as a closed enum, `Counters` as a fixed `[std.meta.fields(Counter).len]u64` plus `overflowed: bool`, and `Sink(comptime enabled: bool)`. `Sink.add` checks `std.math.maxInt(u64) - current < amount`; on overflow it sets `overflowed` and performs no wrapped or saturated write, which keeps no-error measurement callbacks valid. `Counters.snapshot` returns `error.CounterOverflow` when set. `Snapshot` is copied into the matching `FrameSample` before the next frame resets `Counters`; its JSON writer emits counter names in enum declaration order, not an unlabeled numeric array. `Sink(false)` stores no pointer and every method is a compile-time no-op; add compile-time size tests for both branches. Export only `Counter`, `Counters`, `Snapshot`, and `Sink` from `v7`.

- [ ] **Step 4: Add the runtime config types and CLI parsing**

```zig
pub const Mode = enum { offscreen, presented };
pub const Config = struct {
    mode: Mode,
    warmup_frames: u32 = 240,
    sample_frames: u32 = 1000,
    output_path: []const u8,
};
```

Require `--perf-mode` and `--perf-out` together. Reject duplicate flags, missing values, zero sample frames, `warmup_frames + sample_frames` overflow, multiple scene flags, and any perf combination with `--window`, `--frames`, `--shot`, `--layout`, `--diff`, `--write-golden`, `--sim`, `--library`, `--hover`, `--gpu-remount-smoke`, `--gpu-sort-verify`, `--subpixel`, `--no-subpixel`, `--quad-debug`, `--bgr`, or `--no-damp`. Reuse the existing scene flags: no scene flag means Todo; `--calculator`, `--spotify`, `--tiger`, and `--strokes` select the other four. Perf mode itself enters the finite GPU path with the fixed default render options. Preserve every non-perf CLI path.

- [ ] **Step 5: Compile observer-isolated cells**

```bash
zig build install -Doptimize=Debug      -Dv7-tracy=false -Dv7-gpu-timestamps=false -Dv7-perf-counters=false
zig build install -Doptimize=Debug      -Dv7-tracy=true  -Dv7-gpu-timestamps=false -Dv7-perf-counters=false
zig build install -Doptimize=Debug      -Dv7-tracy=false -Dv7-gpu-timestamps=true  -Dv7-perf-counters=false
zig build install -Doptimize=Debug      -Dv7-tracy=false -Dv7-gpu-timestamps=false -Dv7-perf-counters=true
zig build install -Doptimize=ReleaseFast -Dv7-tracy=false -Dv7-gpu-timestamps=false -Dv7-perf-counters=false
zig build install -Doptimize=ReleaseFast -Dv7-tracy=true  -Dv7-gpu-timestamps=false -Dv7-perf-counters=false
zig build install -Doptimize=ReleaseFast -Dv7-tracy=false -Dv7-gpu-timestamps=true  -Dv7-perf-counters=false
zig build install -Doptimize=ReleaseFast -Dv7-tracy=false -Dv7-gpu-timestamps=false -Dv7-perf-counters=true
```

Expected: all eight compile. Clean binaries do not link enabled Tracy. Tracy, generic GPU queries, and mechanism counters can each be enabled without enabling either of the other observers.

- [ ] **Step 6: Commit**

```bash
jj commit -m "feat(perf): separate v7 measurement builds"
```

---

### Task 3: Define raw samples and a fixed statistical protocol

**Files:**
- Modify: `src/v7_demo/perf.zig`
- Create: `tools/run_v7_perf.py`
- Create: `tools/test_run_v7_perf.py`
- Modify: `build.zig`
- Modify: `src/v7/perf_counters.zig`

**Interfaces:**
- Every final runner artifact contains one merged JSON header followed by one JSON object per observed warm-up or retained sample frame.
- Every sample contains `phase`, `frame_id`, `cpu_app_layout_ns`, `cpu_scene_ns`, `cpu_record_ns`, `cpu_submit_present_ns`, `cpu_compute_ns`, optional `cpu_acquire_ns`, optional `cpu_slot_wait_ns`, optional `cpu_present_slop_ns`, optional `gpu_execute_ns`, optional `gpu_end_interval_ns`, optional `present_interval_ns`, `slop_ns`, and optional `mechanisms`. `mechanisms` is present only in mechanism builds.
- `run_v7_perf.py` treats fresh process blocks as independent units.
- Runner subcommands are `snapshot`, `calibrate`, `matrix`, `pair`, and `qualify`. They never create, describe, abandon, rebase, or move a Jujutsu change.
- Tracy-only cells retain the `.tracy` capture and a `tracy-csvexport -u` event export; the runner hashes both and treats them as attribution evidence, never acceptance timing.
- `snapshot` runs a read-only Jujutsu inspection to capture current nogui and `../noapi` change IDs plus commit IDs, builds one requested cell, copies the executable into the artifact root, computes its SHA-256, and writes `snapshot.json`.
- `snapshot` also hashes `shaders/quad_vert.spv`, `shaders/quad_frag.spv`, `shaders/sort_comp.spv`, `shaders/fullscreen_vert.spv`, and `shaders/blit_oklab.spv`; `pair` rejects any shader-manifest difference.
- `calibrate`, `matrix`, and `qualify` create immutable snapshots internally before they launch scene processes.
- `pair` consumes baseline and candidate manifests for three matched profiles: clean, GPU-query-only, and mechanism-only. It rejects a missing profile, any within-profile flag mismatch, an equal corresponding binary hash, a missing copied binary, a recomputed hash mismatch, or any shader-manifest difference.
- Before launching a pair, require identical machine identity, online CPU set, requested affinity, governor, GPU/driver, extent, and present mode. A mid-pair change invalidates the complete pair and stops the run; it is never replaced with another pair after results are visible.
- `matrix`, `pair`, and `qualify` always run all five target scenes. `calibrate` also defaults to all five; a diagnostic `--scene` filter is not valid for an acceptance run.
- `perf.Recorder.init(allocator, expected_frames)` allocates one exact `[]FrameSample` before GPU work; `append`, `attachGpu`, and `attachPresent` only write existing slots. `writeJsonl` runs after all delayed GPU and presentation fields are resolved.

- [ ] **Step 1: Write failing Python protocol tests**

```python
class QualificationTests(unittest.TestCase):
    def test_nearest_rank_p99_is_not_interpolated(self):
        self.assertEqual(p99_ns(list(range(1, 1001))), 990)

    def test_exact_integer_frame_budget(self):
        self.assertTrue(within_120_fps_budget(8_333_333))
        self.assertFalse(within_120_fps_budget(8_333_334))

    def test_zero_failure_upper_bound(self):
        self.assertLess(1.0 - 0.05 ** (1.0 / 300.0), 0.01)

    def test_any_failed_block_rejects(self):
        self.assertFalse(qualifies([False] * 299 + [True]))

    def test_wrong_block_count_rejects(self):
        with self.assertRaises(ProtocolError):
            qualifies([False] * 299)
```

Here `True` means that the complete 1,000-frame block violates at least one predeclared cell criterion: required p99, presented throughput, sample integrity, or runtime correctness. A single frame above budget does not by itself fail a block when the declared contract is p99.

Also test non-contiguous frame IDs, missing delayed metrics, negative durations, present slop larger than submit duration, wrong profile flags, changed shader manifests, copied-binary hash mismatch, a busy Tracy port, capture timeout, and a capture/export subprocess failure. Use temporary files and fake child processes; protocol tests must not launch Vulkan or Tracy.

- [ ] **Step 2: Verify RED**

Run `python3 -m unittest tools.test_run_v7_perf -v`. Expected: import failure for missing protocol functions.

- [ ] **Step 3: Implement the raw schema**

Use integer nanoseconds. The header records schema version, scene, mode, optimize mode, instrumentation flags, block ID, randomized order position, exact child argv, Zig version, binary SHA-256, runner SHA-256, shader hashes, nogui Jujutsu change and commit IDs, noapi Jujutsu change and commit IDs, CPU model, online CPU set, process affinity, kernel, CPU governor when readable, GPU/driver, extent, present mode, reported refresh data, warm-up rule, process-order seed, and sample count. Reject NaN-like strings, negative durations, changed affinity, and missing required metadata during parsing.

Use this stable record:

```zig
pub const Phase = enum { warmup, sample };

pub const FrameSample = struct {
    phase: Phase,
    frame_id: u64,
    cpu_app_layout_ns: u64,
    cpu_scene_ns: u64,
    cpu_record_ns: u64,
    cpu_submit_present_ns: u64,
    cpu_compute_ns: u64,
    cpu_acquire_ns: ?u64 = null,
    cpu_slot_wait_ns: ?u64 = null,
    cpu_present_slop_ns: ?u64 = null,
    gpu_execute_ns: ?u64 = null,
    gpu_end_interval_ns: ?u64 = null,
    mechanisms: if (v7_options.perf_counters) perf_counters.Snapshot else void,
    present_interval_ns: ?u64 = null,
    slop_ns: u64,
};
```

Initialize `mechanisms` with the same compile-time branch. The JSONL writer emits a `mechanisms` object only when counters are enabled; it does not emit `null` or an empty object in clean, Tracy, or GPU-query cells.

Use adjacent `std.Io.Timestamp.now(io, .awake)` boundaries for slot wait or acquire and the four non-overlapping work stages. In presented mode, sample `Surface.slopNs()` immediately before and after `endFrame`; their checked difference is `cpu_present_slop_ns` and must not exceed `cpu_submit_present_ns`. The fourth compute term is `cpu_submit_present_ns - cpu_present_slop_ns`; in offscreen mode the present-slop term is zero. Compute `cpu_compute_ns` with checked addition from app/layout, scene conversion, command recording, and the non-blocked submit term for the same frame before serialization. Never derive it by adding or subtracting aggregate quantiles. `cpu_acquire_ns` and `cpu_slot_wait_ns` are outside compute capacity because they pace the producer. In offscreen mode `slop_ns` equals the measured slot wait; in presented mode it equals total `Surface.slopNs()`. Actual presented intervals and GPU frame-end intervals measure delivered cadence.

Reject `warmup_frames + sample_frames` overflow before allocation. Frame IDs start at zero and are contiguous, so delayed updates index the preallocated slice by checked `frame_id` and then verify the stored ID. `append` returns `error.TooManySamples`; duplicate GPU or presentation updates return `error.DuplicateFrameMetric`; missing required updates fail serialization.


`attachGpu` stores execution duration and computes the end interval with modular subtraction under the queue's timestamp-valid-bit mask. Convert ticks in `f64` with the device `timestampPeriod`, then range-check and round to the nearest integer nanosecond. `attachPresent` requires one strictly increasing actual timestamp per presented frame and uses checked subtraction. The first frame alone has null intervals; the first retained sample uses the final warm-up frame as its predecessor.

- [ ] **Step 4: Implement process-block collection**

The script uses `subprocess.run(command, shell=False)` for ordinary finite commands. A Tracy cell uses two direct-argv `subprocess.Popen` children only for the concurrently connected capture and demo; both have bounded startup and completion waits. The runner randomizes cell order from a recorded seed and balances baseline/candidate or instrumentation off/on with AB/BA blocks. It never pairs ordinal frames from different processes. The runner merges runtime GPU/display metadata with the immutable snapshot metadata when it writes each final JSONL header; it never query-stamps an old binary with the current workspace ID. `calibrate` requires exactly 2,400 diagnostic frames. `matrix` requires a frozen warm-up manifest and a positive block count. `pair` requires valid distinct snapshot manifests. `qualify` rejects any block count other than 300 or sample length other than 1,000.

For each Tracy-only process, derive `trace_path` from its cell and block IDs. Coordinate `["tracy-capture", "-o", trace_path, "-a", "127.0.0.1", "-p", "8086", "-f"]` with the finite demo, wait for both processes, then run `["tracy-csvexport", "-u", trace_path]` with stdout captured to the CSV artifact. Use bounded connection/startup waits, fail if port 8086 is already occupied, and kill neither an unverified PID nor an unrelated listener.

Parse Tracy attribution only from events whose complete interval is inside a `perfSampleFrame` root zone. Require exactly the requested number of non-overlapping sample roots, reject a child crossing a root boundary, and exclude every `perfWarmupFrame` event. Store per-zone call count, inclusive nanoseconds, self nanoseconds, median, and nearest-rank p99 beside the raw CSV hash.

Compute p99 with the deterministic nearest-rank definition: sort integer samples and select rank `ceil(0.99 * n)`, without interpolation. Test budget membership with integer cross-multiplication. Presented throughput passes only when `interval_count * 1_000_000_000 >= 120 * sum(interval_ns)`; do not round a displayed FPS before the gate.

- [ ] **Step 5: Implement final qualification without optional stopping**

Exactly 300 predeclared 1,000-frame blocks are required per scene and target cell. Collect all 300. Do not inspect an interim bound, stop, extend, replace, or discard a valid block. Compute the one-sided zero-failure endpoint once:

```python
def p99_ns(values: list[int]) -> int:
    if not values:
        raise ProtocolError("p99 requires at least one sample")
    rank = (len(values) * 99 + 99) // 100
    return sorted(values)[rank - 1]

def within_120_fps_budget(duration_ns: int) -> bool:
    return duration_ns * 120 <= 1_000_000_000

def zero_failure_upper_bound(block_count: int, alpha: float = 0.05) -> float:
    return 1.0 - alpha ** (1.0 / block_count)

def qualifies(failed_blocks: list[bool]) -> bool:
    if len(failed_blocks) != 300:
        raise ProtocolError("qualification requires exactly 300 blocks")
    return not any(failed_blocks) and zero_failure_upper_bound(300) < 0.01
```

- [ ] **Step 6: Verify GREEN**

Run the Python tests and `zig build test -Dtest-filter="perf"`. Include a recorder test that rejects `cpu_present_slop_ns > cpu_submit_present_ns`. Expected: all protocol/schema tests pass.

- [ ] **Step 7: Commit**

```bash
jj commit -m "feat(perf): add raw samples and fixed qualification"
```

---

### Task 4: Add noapi synchronization, timestamp, and presentation contracts

**Repository:** `../noapi` in a separate Jujutsu workspace. Read that repository's rules before editing.

**Files:**
- Create: `../noapi/noapi/TimestampQuerySet.zig`
- Modify: `../noapi/noapi/VkBackend.zig:120-620,1000-1180,1202-1425`
- Modify: `../noapi/noapi/Gpu.zig:28-80,188-250`
- Modify: `../noapi/noapi/CommandBuffer.zig:1-70`
- Modify: `../noapi/noapi/Queue.zig`
- Modify: `../noapi/noapi/Surface.zig:57-93`
- Modify: `../noapi/noapi/root.zig:6-68`
- Modify: `../noapi/test/main.zig`
- Modify: `../noapi/build.zig`
- Modify: `../noapi/examples/7_deferred_async_load/main.zig`

**Interfaces:**
- Offscreen submission with a timeline signal retains a fence and reclaims command buffers after completion.
- Generic timestamp queries work when Tracy is compiled out; noapi keeps every Vulkan query handle private.
- Optional presented-frame feedback exposes a monotonic present ID and the compositor-reported timestamp through `VK_EXT_present_timing` or `VK_GOOGLE_display_timing`.
- Unsupported timestamp or presentation features return explicit capability values. They do not substitute CPU timestamps.

- [ ] **Step 1: Write a failing real-backend submission lifecycle check**

Add a noninteractive `--submission-lifecycle-test 8` path to `test/main.zig` and a `zig build submission-lifecycle` step. Initialize the real backend with a `std.heap.DebugAllocator`, submit no-op command buffers with increasing timeline values, and wait only before reusing each of three slots. Inspect backend-owned lifecycle state from the noapi test executable: each successful signal submission must enter `submitted_work`; completed work must leave it on the next reclaim; after eight submissions and a final flush, the count must be zero and the allocator clean. Expected RED: the current `queueSubmitSignal` path creates no fence and never adds its command buffer to `submitted_work`.

- [ ] **Step 2: Refactor normal and signaling submission through one tracked helper**

Under the queue lock, the helper duplicates the handle list, reserves `submitted_work` capacity, and creates a fence before mutating command-buffer state. It then records optional checkpoints, ends every command buffer, and calls `queue.submit`. On success it uses `appendAssumeCapacity`, so no fallible ownership operation remains after submission. Submission consumes these offscreen command buffers: an end or submit failure frees the unsubmitted original handles from `offscreen_cmd_pool`, destroys the unused fence, and frees the copied tracking slice. Both `queueSubmit` and `queueSubmitSignal` use this helper; the latter supplies timeline signal data.


In both fixed-64 public wrappers, reject `cmd_bufs.len > 64` with `error.TooManyCommandBuffers` before copying or submitting. Add 64/65 boundary tests. Never retain the current silent truncation.

Before deleting the exported method, run LSP references in both workspaces. The current exact inventory is two noapi example calls and five nogui `window.zig` calls; a changed count must be fully migrated.

Delete the unused `free_cmd_bufs` list and the misleading `Gpu.commandsEnd`/backend `commandsEnd` API. Migrate both calls in `examples/7_deferred_async_load/main.zig`; Task 5 migrates every nogui caller when the path dependency advances. Do not retain a compatibility no-op.

- [ ] **Step 3: Add generic timestamp queries**

Export these noapi types and methods:

```text
pub const TimestampStage = enum {
    all_commands_start,
    all_commands_end,
};

pub const TimestampInfo = struct {
    period_ns: f64,
    valid_bits: u7,
};

pub const TimestampQuerySet = struct {
    gpu: *Gpu,
    handle: Gpu.TimestampQueryHandle,
    count: u32,
};

pub fn timestampInfo(self: *const Gpu) ?TimestampInfo;
pub fn timestampQuerySetCreate(self: *Gpu, count: u32) !TimestampQuerySet;
pub fn timestampQuerySetDestroy(self: *Gpu, set: TimestampQuerySet) void;
pub fn timestampQuerySetRead(
    self: *Gpu,
    set: TimestampQuerySet,
    first: u32,
    out: []u64,
) !void;
pub fn timestampReset(
    self: *CommandBuffer,
    set: TimestampQuerySet,
    first: u32,
    count: u32,
) !void;
pub fn timestampWrite(
    self: *CommandBuffer,
    set: TimestampQuerySet,
    index: u32,
    stage: TimestampStage,
) !void;
```

Reject zero counts and every `first + count` overflow or out-of-range request. Map the two stages to full-command start/end. `timestampQuerySetRead` uses caller storage and returns `error.NotReady` instead of waiting. Refactor `Options.timestamp_queries` so generic query support is independent of `tracy.enabled`; keep a separate internal `tracy_gpu_zones` flag for Tracy pools and calibration.

Add unit tests for one-bit, 32-bit, and 64-bit valid masks, wraparound modular subtraction, and zero/out-of-range query spans. Extend `submission-lifecycle` to write one start/end pair, wait on its timeline value, read it, and require a valid modular delta under the reported mask. Expected RED before implementation: no generic query type or commands.


- [ ] **Step 4: Add optional presentation timing support**

First add backend-normalization tests for unsupported capability, zero/duplicate IDs, Google `u32` overflow, out-of-order completed records, and output-too-small behavior that consumes nothing. Reference the public methods from `test/main.zig`; expected RED is the missing API. Use injected backend records for deterministic tests, then add one real-surface capability smoke path that passes when support is honestly false.

Enable `VK_EXT_present_timing` when available. Use `VK_GOOGLE_display_timing` as the fallback. Attach the extension's application present ID to each present. Normalize completed records through:

```text
pub const PresentFeedback = struct {
    present_id: u64,
    actual_present_ns: u64,
};

pub fn supportsPresentTiming(self: *const Surface) bool;
pub const PresentInfo = struct {
    blit_to_swapchain: bool = true,
    timing_id: ?u64 = null,
};

pub fn pollPresentFeedback(
    self: *Surface,
    out: []PresentFeedback,
) !usize;
```

`pollPresentFeedback` writes into caller storage and does not allocate. Query the available record count first; if it exceeds `out.len`, return `error.OutputTooSmall` before consuming records, and never truncate or drop feedback. Sort the bounded result by present ID, reject duplicates, and return only completed records in increasing order. A timed present passes the nonzero `frame_id + 1` through `PresentInfo.timing_id`; reject duplicate IDs, zero, and values outside the Google extension's `u32` range when that fallback is active. Supplying `timing_id` without either timing extension returns `error.PresentTimingUnsupported`. If neither timing extension is available, `supportsPresentTiming()` is false, the runner submits without an ID, and nogui may claim compute capacity only. `VK_KHR_present_wait` alone does not supply the actual presentation timestamp required by this gate.
- [ ] **Step 5: Verify noapi**

Run:

```bash
zig build submission-lifecycle -Doptimize=Debug -Denable-tracy=false
zig build test -Doptimize=Debug -Denable-tracy=false
zig fmt --check .
gate
```

Expected: signal submissions enter and leave tracked ownership, pending submissions reach zero after flush, generic timestamp deltas work without Tracy, the debug allocator reports no leaks, optional presentation timing reports its actual capability, and every command exits zero.

- [ ] **Step 6: Commit in noapi**

```bash
jj commit -m "feat(gpu): expose tracked timing primitives"
```

- [ ] **Step 7: Integrate the accepted noapi change before resuming nogui**

Record the accepted noapi change and commit IDs. Because `build.zig.zon` uses the path dependency `../noapi`, the noapi workspace at that exact path must contain the accepted change for nogui builds. Task 5 removes every nogui `gpu.commandsEnd` call while introducing the shared submit helpers. Do not copy backend files into nogui and do not access Vulkan handles as a workaround. Record both repositories' change and commit IDs in every perf header.

---

### Task 5: Extract shared scene recording without changing pixels

**Files:**
- Modify: `src/v7_demo/window.zig:787-1320,1736-1928,2140-2227`
- Modify: `src/v7_demo/main.zig`

**Interfaces:**
- `buildFrameScene` owns `collectDrawCmds`, `buildSliceRects`, temporary `DrawCmd` cleanup, and optional reverse-sort verification. The caller owns the output list.
- `recordFrameScene` is the renamed `renderPass1` and records only GUI commands into an Oklab target.
- `recordColorConversion` records the existing Oklab-to-sRGB fullscreen pass into a caller-supplied destination texture.
- `run` and the perf paths use all three helpers. `runShot` uses the first two and preserves its current pass-1 readback.

```text
fn buildFrameScene(
    gpa: std.mem.Allocator,
    text_engine: *TextEngine,
    svg_view: ?*SvgView,
    icon_cache: ?*const IconCache,
    frame: *const nogui.FrameOutput,
    out: *std.ArrayList(SceneRect),
    gpu_sort_verify: bool,
) !void;

fn recordFrameScene(
    gui_renderer: *Renderer,
    cmd: *noapi.CommandBuffer,
    scene_rects: []const SceneRect,
    clip_rects: []const ClipRect,
    render_target: noapi.TextureHandle,
    surface_size: noapi.Extent2D,
    texture_heap: noapi.DescriptorHeap,
) !void;

fn recordColorConversion(
    cmd: *noapi.CommandBuffer,
    destination: noapi.TextureHandle,
    surface_size: noapi.Extent2D,
    blit_vert: noapi.Shader,
    blit_frag: noapi.Shader,
    blit_heap: noapi.DescriptorHeap,
) void;
```

- [ ] **Step 1: Freeze five scene outputs before refactoring**

Create `/tmp/nogui-perf/behavior-before`. Render Todo, Calculator, Spotify, Tiger, and Strokes shots with and without `--gpu-sort-verify`. Save all PPM SHA-256 values. Save layout fingerprints for Todo and Spotify, which are the two current `--layout` paths.

Example commands:

```bash
zig build v7 -- --shot /tmp/nogui-perf/behavior-before/todo.ppm
zig build calculator -- --shot /tmp/nogui-perf/behavior-before/calculator.ppm
zig build spotify -- --shot /tmp/nogui-perf/behavior-before/spotify.ppm
zig build v7 -- --tiger --shot /tmp/nogui-perf/behavior-before/tiger.ppm
zig build v7 -- --strokes --shot /tmp/nogui-perf/behavior-before/strokes.ppm
```

Repeat with reverse-sort verification:

```bash
zig build v7 -- --gpu-sort-verify --shot /tmp/nogui-perf/behavior-before/todo-sort.ppm
zig build calculator -- --gpu-sort-verify --shot /tmp/nogui-perf/behavior-before/calculator-sort.ppm
zig build spotify -- --gpu-sort-verify --shot /tmp/nogui-perf/behavior-before/spotify-sort.ppm
zig build v7 -- --tiger --gpu-sort-verify --shot /tmp/nogui-perf/behavior-before/tiger-sort.ppm
zig build v7 -- --strokes --gpu-sort-verify --shot /tmp/nogui-perf/behavior-before/strokes-sort.ppm
zig build v7 -- --layout /tmp/nogui-perf/behavior-before/todo-layout.txt
zig build spotify -- --layout /tmp/nogui-perf/behavior-before/spotify-layout.txt
sha256sum /tmp/nogui-perf/behavior-before/*.ppm > /tmp/nogui-perf/behavior-before/sha256.txt
```

- [ ] **Step 2: Extract `buildFrameScene`**

Move `collectDrawCmds`, `buildSliceRects`, temporary command cleanup, and optional reversal into the helper. Preserve statement order, allocation ownership, clip stamping, material writes, `SceneRect` order, and error propagation. Do not change loop binding types or reserve capacity in this task.

- [ ] **Step 3: Rename `renderPass1` and extract `recordColorConversion`**

Rename `renderPass1` to `recordFrameScene` without changing its body. Extract the existing fullscreen pass into `recordColorConversion`; parameterize only the destination texture. The presented path passes `gw.currentImage()`. The shot path remains pass-1 plus readback and does not pretend to include the color conversion.

At `window.zig:651-652,709-710,781-782,2225-2226,2239-2240`, delete the five post-submit `gpu.commandsEnd` calls removed by Task 4. `queueSubmit` now ends and tracks each command buffer. Preserve every submit/wait order and migrate all five callsites in the same change.

- [ ] **Step 4: Verify behavior lock**

Render the same ten shots under `/tmp/nogui-perf/behavior-after`. Expected: every corresponding SHA-256 and layout fingerprint is identical. Run `zig build fixture -Doptimize=Debug`.

- [ ] **Step 5: Commit**

```bash
jj commit -m "refactor(render): share frame recording paths"
```

---

### Task 6: Implement equivalent offscreen and presented perf runners

**Files:**
- Modify: `src/v7_demo/window.zig`
- Modify: `src/v7_demo/perf.zig`
- Modify: `src/v7_demo/main.zig`

**Interfaces:**
- `window.RunOptions` replaces the existing positional option tail and contains `perf: ?perf.Config`.
- Offscreen mode uses three Oklab targets, three sRGB targets, three immutable per-slot blit descriptor heaps, one timeline semaphore, and slot-reuse waits.
- `OffscreenSlots` owns exactly those six textures, three descriptor heaps, one timeline semaphore, and one six-entry timestamp query set when GPU timestamps are enabled.
- Presented mode uses the existing FIFO path and noapi presentation timing.
- Perf execution branches inside `run` after shared GPU/shader/font/resource initialization. Do not copy that initialization into a third runner.
- Both perf modes use `noapi.Extent2D{ .width = 954, .height = 1044 }`. Presented mode verifies the swapchain extent before warm-up and on every frame; any mismatch fails the block.
- Offscreen mode may retain the SDL Vulkan loader window, but it creates no `noapi.Surface` or swapchain. Presented mode uses the existing FIFO surface path.

- [ ] **Step 1: Write failing slot and frame-ID state-machine tests**

Test the pure slot scheduler:

```zig
try testing.expectEqual(@as(?u64, null), slotWaitValue(0, 3));
try testing.expectEqual(@as(?u64, null), slotWaitValue(2, 3));
try testing.expectEqual(@as(?u64, 1), slotWaitValue(3, 3));
try testing.expectEqual(@as(?u64, 2), slotWaitValue(4, 3));
```

Also reject non-monotonic timeline values, duplicate frame IDs, and non-monotonic presentation IDs in the sample writer.

- [ ] **Step 2: Verify RED**

Run `zig build test -Dtest-filter="perf slot"`. Expected: missing scheduler and frame sample validation.

- [ ] **Step 3: Replace the long `run` option tail**

```zig
pub const RunOptions = struct {
    subpixel: bool = false,
    quad_debug: bool = false,
    bgr_order: bool = false,
    damp_chroma: bool = true,
    gpu_sort_verify: bool = false,
    max_frames: ?u32 = null,
    audio_tracks: ?[]const LocalTrack = null,
    perf: ?perf.Config = null,
};
```

Add `RunOptions.validate`: when `perf != null`, require all render options at the fixed defaults, `max_frames == null`, and `audio_tracks == null`. Return an explicit error before SDL or GPU initialization on conflict.


Move `Surface.init`, the single presented Oklab target, window ID, refresh query, and pacer below common GPU/shader/font/texture/SVG/icon initialization. Dispatch once into an offscreen helper or a presented/interactive helper; do not carry `?Surface` checks through the hot loop. The common initialization and reverse-order cleanup remain single-owner code in `run`.

For perf, choose the fixed `954x1044` extent before SDL window creation. The offscreen branch uses a hidden Vulkan-capable SDL loader window and never creates a noapi surface. The presented branch creates a visible window, queries its pixel extent, and fails before warm-up unless it is exactly `954x1044`.

Run LSP references on exported `window.run` before editing. Migrate all 11 current calls in `main.zig` to named `RunOptions` literals; if the reference count differs, migrate every returned caller before removing the positional signature. Keep `runShot` unchanged in this task.

- [ ] **Step 4: Implement the three-slot offscreen path**

For frame `n`, measure the timeline wait into `cpu_slot_wait_ns`, wait for value `n - 2` only when `n >= 3`, then reuse slot `n % 3`; frames 0–2 record zero wait rather than null. `OffscreenSlots.init` creates all textures, the semaphore, three blit descriptor heaps, and the optional six-query set before warm-up, with reverse-order `errdefer` cleanup; each heap is pointed at its slot's Oklab source once and is never mutated while any slot is in flight. `deinit` runs after the final wait. Record the same `recordFrameScene`, barrier, and `recordColorConversion` work as the presented path, with the slot's sRGB texture as destination. Submit through `noapi.Queue.submitSignal`; never create a swapchain, read back pixels, write a PPM, or call per-frame `waitIdle`. In GPU-timestamp builds, reset and write the slot's start/end pair, resolve it only after slot completion, handle the queue's timestamp-valid-bit mask, and derive `gpu_execute_ns` plus consecutive frame-end `gpu_end_interval_ns` using the device timestamp period.

- [ ] **Step 5: Implement presented sampling**



Presented perf does not run predictive `FramePacer` sleep or update logic; FIFO and the compositor remain the only pacing source. Drain setup events before warm-up. After warm-up starts, any quit, resize, minimize, or input event fails the block before it can mutate app state.

Measure adjacent CPU boundaries for acquire, app/layout, scene conversion, command recording, and submit/present. Read `Surface.slopNs()` immediately before and after `endFrame`; checked subtraction isolates end-frame blocking, and subtracting that value from `cpu_submit_present_ns` yields the non-blocked submit term. Build `cpu_compute_ns` from the four non-overlapping work terms for that frame. Record total `Surface.slopNs()` separately. Poll completed presentation records into a fixed 64-entry stack buffer after each `endFrame`, then attach each timestamp to `timing_id - 1` in the preallocated recorder. Polling must not wait or allocate; `error.OutputTooSmall` fails the block. After the final frame, drain all outstanding IDs with a bounded five-second deadline and `SDL_Delay(1)` between empty polls; missing, duplicate, zero, or unknown IDs fail the run. When presentation timing is unsupported, write `present_feedback=false` in the header and refuse final presented qualification.

- [ ] **Step 6: Exclude warm-up frames without resetting state**

Warm-up runs the real frame path for the exact count passed in `Config`. Start from a fresh process and advance deterministic logical time as `(frame_id * 1000) / 120`; warm-up and sample form one continuous app state. Set `ui.fps = 120` before every perf app frame and skip the wall-clock rolling-FPS update so rendered text and layout do not depend on scheduler timing. Mark warm-up slots with `phase = .warmup` and the following exact count with `phase = .sample`. After delayed metrics are complete, serialize both phases. Resource creation, first glyph rasterization, and initial cache population remain visible in raw warm-up diagnostics but are excluded from sample quantiles. The binary never decides convergence or changes the requested counts. A resize, minimize, out-of-date surface, missing asset, or injected input fails the block instead of skipping or replacing a frame.

In Tracy builds, wrap the complete CPU work of each iteration in `perfWarmupFrame` or `perfSampleFrame` according to the recorded phase. These root zones exist only to delimit attribution; clean, GPU-only, and mechanism-only builds compile them out.

- [ ] **Step 7: Verify**

Run 20-frame Debug offscreen and presented smoke cells for all five scenes. Expected: contiguous frame IDs, no slot reuse before timeline completion, equivalent scene/color work, valid JSONL, no PPM/file work in offscreen mode, and unchanged fixture/shot outputs.

- [ ] **Step 8: Commit**

```bash
jj commit -m "feat(perf): add equivalent frame runners"
```

---

### Task 7: Establish the decision baseline

**Files:**
- Modify: `src/v7/perf_counters.zig`
- Modify: `src/v7/app.zig`
- Modify: `src/v7/widget.zig`
- Modify: `src/v7/drawcmd.zig`
- Modify: `src/v7_demo/text.zig`
- Modify: `src/v7_demo/window.zig`
- Modify: `src/v7_demo/svg_view.zig`
- Create: `docs/perf/debug-120-baseline.json`
- Create: `docs/perf/debug-120-roadmap.md`

**Interfaces:**
- Baseline report contains raw artifact hashes and process-block summaries; it never embeds only hand-copied medians.
- Each hypothesis gets a measured trigger and state.
- One runner-owned `Counters` object feeds `Sink(true)` into `App`, `WidgetTree`, `TextEngine`, and scene conversion. `Sink(false)` remains zero-sized and compiles every increment out.

- [ ] **Step 1: Wire isolated attribution**

Add coarse Tracy zones around app draw, `layoutTree`, state/input validation, and GPU component dispatch. Keep the existing `measureText`, `getOrShape`, `emitText`, `emitTextFlow`, `collectDrawCmds`, `buildSliceRects`, and `renderPass1` zones. Add `shapeForMeasure` and SVG stroke-update zones, but do not put a zone around per-glyph or per-node inner iterations.

Define these permanent mechanism counters: `measure_requests`, `harfbuzz_shapes`, `hard_line_bytes_scanned`, `segment_bytes_scanned`, `segment_content_rescan_bytes`, `glyph_entry_comparisons`, `node_comparisons`, `svg_card_node_comparisons`, `hover_focus_node_comparisons`, `ancestor_reads`, `draw_cmd_value_bind_bytes`, `slice_rect_growth_events`, `slice_rect_growth_copy_bytes`, `svg_stroke_write_attempts`, and `svg_stroke_writes`. A value-bind counter describes source-level wide bindings; only disassembly can prove a physical copy.

Reset the runner-owned counter object immediately before each app frame. Copy one snapshot into that frame's sample after scene conversion and before reset for the next frame. Checked overflow invalidates the process block. Unit-test each counter route in a mechanism build and assert that the clean build stores neither a counter pointer nor a snapshot payload.

- [ ] **Step 2: Freeze one warm-up length**

Run one 2,400-frame diagnostic per scene and target cell. At each 120-frame boundary from frame 600 through frame 2,160, compare the last three disjoint 120-frame windows. A boundary is stable when the maximum and minimum `cpu_compute_ns` medians differ by at most 12%; require the same rule for `gpu_execute_ns` in instrumented cells. Record a sustained boundary when one exists. If any cell has no sustained boundary, record a null boundary, set the global warm-up to 2,400, mark the manifest `capped_unstable`, and continue. Wall-time instability is evidence about the host, not a blocker. Record the full rule and every raw hash in the manifest. Design: `docs/superpowers/specs/2026-08-30-debug-120-calibration-threshold-design.md`.

Run:

```bash
python3 tools/run_v7_perf.py calibrate \
  --frames 2400 \
  --seed 0x4e4f475549313230 \
  --out /tmp/nogui-perf/calibration
```

Expected: `warmup.json` names one fixed count and contains hashes for every diagnostic file.

- [ ] **Step 3: Run the 10-block attribution matrix**

For offscreen mode and each optimize mode, collect four isolated cells: clean, Tracy-only, GPU-timestamp-only, and mechanism-counter-only. For Debug presented mode, collect the same four cells when presentation timing exists. Every process uses the frozen warm-up count and then ten fresh 1,000-frame sample blocks. Never use a combined “all observers on” cell to attribute an observer's cost.

Run:

```bash
python3 tools/run_v7_perf.py matrix \
  --warmup-from /tmp/nogui-perf/calibration/warmup.json \
  --blocks 10 \
  --frames 1000 \
  --seed 0x4e4f475549313230 \
  --report docs/perf/debug-120-baseline.json \
  --out /tmp/nogui-perf/baseline
```

Expected: every requested cell has ten valid process blocks, every Tracy process has hashed `.tracy` and event-CSV artifacts, and the baseline report references every raw hash.

- [ ] **Step 4: Measure complete stages**

Use clean cells for CPU timing, Tracy cells for nested CPU-zone attribution inside `perfSampleFrame`, GPU-query cells for execution/completion intervals, and mechanism cells only for work counts. Account for app draw, `layoutTree`, validation/reset, text measurement, draw collection, scene conversion, command recording/submission, GPU execution, slot wait, acquire, present, and pacing separately. Require the per-zone aggregate and its raw trace/CSV hashes in the baseline report. Never compare a Tracy or mechanism-cell duration to a clean-cell acceptance threshold.

- [ ] **Step 5: Assign candidate states**

A candidate is triggered when isolated mechanism counters confirm removable work and Tracy shows that route is active. Use noisy wall-time measurements as context and ranking evidence, not as a validity gate. Record `not_applicable` for absent work. Do not use the historical Tracy marginals as the trigger.

- [ ] **Step 6: Select exactly one first candidate**

The expected hypothesis is shaped-run reuse, but the report decides. Record the candidate, predeclared counter reduction, counter-free timing comparison, correctness gates, and rejection rule before implementation.

- [ ] **Step 7: Commit the baseline report**

```bash
jj commit -m "perf(v7): establish Debug frame baseline"
```

---

## Conditional Candidate Protocol

Every Task 8–16 implementer applies this protocol in addition to the task-specific steps. Set `CANDIDATE` from this fixed map:

| Task | `CANDIDATE` |
|---:|---|
| 8 | `shaped-run-reuse` |
| 9 | `max-content-lines` |
| 10 | `segment-content` |
| 11 | `drawcmd-pointer` |
| 12 | `scenerect-reserve` |
| 13 | `id-index-lookup` |
| 14 | `svg-stroke-state` |
| 15 | `glyph-index` |
| 16 | `frame-geometry` |

1. Start from the latest accepted parent in an isolated Jujutsu workspace.
2. Before editing, snapshot three Debug profiles from that exact parent:

```bash
export CANDIDATE=shaped-run-reuse
python3 tools/run_v7_perf.py snapshot \
  --optimize Debug \
  --tracy false \
  --gpu-timestamps false \
  --perf-counters false \
  --out "/tmp/nogui-perf/${CANDIDATE}/baseline/clean"
python3 tools/run_v7_perf.py snapshot \
  --optimize Debug \
  --tracy false \
  --gpu-timestamps true \
  --perf-counters false \
  --out "/tmp/nogui-perf/${CANDIDATE}/baseline/gpu"
python3 tools/run_v7_perf.py snapshot \
  --optimize Debug \
  --tracy false \
  --gpu-timestamps false \
  --perf-counters true \
  --out "/tmp/nogui-perf/${CANDIDATE}/baseline/mechanism"
```

Replace only the `export` value with the task's mapped slug.

3. After correctness gates pass, snapshot the candidate with the same three profiles:

```bash
python3 tools/run_v7_perf.py snapshot \
  --optimize Debug \
  --tracy false \
  --gpu-timestamps false \
  --perf-counters false \
  --out "/tmp/nogui-perf/${CANDIDATE}/candidate/clean"
python3 tools/run_v7_perf.py snapshot \
  --optimize Debug \
  --tracy false \
  --gpu-timestamps true \
  --perf-counters false \
  --out "/tmp/nogui-perf/${CANDIDATE}/candidate/gpu"
python3 tools/run_v7_perf.py snapshot \
  --optimize Debug \
  --tracy false \
  --gpu-timestamps false \
  --perf-counters true \
  --out "/tmp/nogui-perf/${CANDIDATE}/candidate/mechanism"
```

4. Run all 20 predeclared AB/BA block pairs for all three matched profiles. Do not inspect interim results or extend the run:

```bash
python3 tools/run_v7_perf.py pair \
  --baseline-clean-manifest "/tmp/nogui-perf/${CANDIDATE}/baseline/clean/snapshot.json" \
  --candidate-clean-manifest "/tmp/nogui-perf/${CANDIDATE}/candidate/clean/snapshot.json" \
  --baseline-gpu-manifest "/tmp/nogui-perf/${CANDIDATE}/baseline/gpu/snapshot.json" \
  --candidate-gpu-manifest "/tmp/nogui-perf/${CANDIDATE}/candidate/gpu/snapshot.json" \
  --baseline-mechanism-manifest "/tmp/nogui-perf/${CANDIDATE}/baseline/mechanism/snapshot.json" \
  --candidate-mechanism-manifest "/tmp/nogui-perf/${CANDIDATE}/candidate/mechanism/snapshot.json" \
  --warmup-from docs/perf/debug-120-baseline.json \
  --blocks 20 \
  --frames 1000 \
  --seed 0x4e4f475549313230 \
  --out "/tmp/nogui-perf/${CANDIDATE}/paired"
```

The clean profile supplies CPU and presented comparisons. The GPU profile supplies execution and frame-end comparisons. The mechanism profile supplies only task-specific work counts; its durations are never acceptance data.

5. Accept only when the task-specific mechanism count falls, the candidate has lower per-block `cpu_compute_ns` p99 in at least 16 of 20 clean pairs for every triggering scene, the median paired reduction is at least 0.5%, and pooled clean `cpu_compute_ns` p99 is lower. Non-triggering-scene clean CPU, GPU-profile execution/end, and clean presented p99 may not regress by more than 1%. A candidate that adds storage must declare exact bytes per existing bounded element or a finite new capacity bound before measurement; undeclared or unbounded storage rejects.
6. Copy raw artifact hashes and the decision into `docs/perf/debug-120-roadmap.md`. Commit accepted code and its decision together. For a rejection, transfer only the artifact paths, hashes, and conclusion to the integration workspace at the accepted parent, commit that documentation-only decision there, then abandon the isolated candidate change. Never restore or abandon the shared integration workspace.


### Task 8: Reuse exact cached shaped runs during measurement

**Condition:** Execute only when retained unchanged frames still call `shapeForMeasure`, `harfbuzz_shapes` stays nonzero after emission has populated the run cache, and the Tracy zone is material.

**Files:**
- Modify: `src/v7_demo/text.zig:80-101,214-267,845-942,1655-1735`

**Interfaces:**
- Add `cluster: u32` to `GlyphPos`.
- Add allocation-free `cachedRunForMeasure(self: *TextEngine, font: *FontState, text: []const u8) ?*TextRun`.
- Add `CachedAdvance` with the same scalar prefix accumulation order as `ShapedAdvance`.
- A miss still uses `shapeForMeasure`; `MeasureFn` remains no-error.
- Record `@sizeOf(GlyphPos)` before and after adding `cluster`; multiply the checked size delta by the cached-glyph count. This task adds no collection and does not raise `run_cache_capacity`.

- [ ] **Step 1: Write failing cached-advance tests**

Create manual glyph data with repeated clusters, zero-advance controls, non-ASCII byte offsets, CRLF, and ZWS. For increasing offsets, assert bitwise equality between expected scalar prefixes and `CachedAdvance.prefixAt`.

Also test a same-hash/different-text entry returns a miss rather than the wrong run.

- [ ] **Step 2: Verify RED**

Run `zig build test -Dtest-filter="cached advance"`. Expected: missing `cluster`, `CachedAdvance`, and lookup helper.

- [ ] **Step 3: Store HarfBuzz clusters in cached glyphs**

```zig
const GlyphPos = struct {
    cluster: u32,
    gid: u32,
    x_advance: f32,
    y_advance: f32,
    x_offset: f32,
    y_offset: f32,
};
```

Populate `cluster = infos[index].cluster` before destroying the HarfBuzz buffer. Keep control advances at zero exactly as today.

- [ ] **Step 4: Implement allocation-free lookup**

Build the existing `RunKey`, use `getPtr`, and require exact text equality after the hash hit. A collision is a miss for measurement; do not evict, allocate, call `fallbackMeasure`, advance the cache clock, or change run generation. Emission remains the only LRU-touch path, which preserves current eviction and OOM behavior.

The current shaping configuration is fixed to LTR, Latin, no optional features, and engine-lifetime font objects. Record these invariants beside `RunKey`. If any becomes mutable, extend the key before that change reaches this cache.

- [ ] **Step 5: Implement `CachedAdvance`**

Iterate glyphs in stored HarfBuzz order while `cluster < byte_offset`, add `x_advance` with the same `f32 +=` sequence, and preserve reset/monotonic-offset assertions.

- [ ] **Step 6: Use cached data in `measureText`**

On hit, call `measureByLinePolicy(&cached, text, input)` and use `run.line_height`. On miss, execute the current `shapeForMeasure` path unchanged. Do not route a fallible `getOrShape` call through `MeasureFn`.

- [ ] **Step 7: Verify correctness and performance**

Run focused text tests, `zig build fixture`, five before/after shots, and changed-text/font/newline/flow/ellipsis cases. Add a three-frame sequence that emits on frame 1, forces the cached measurement path on frames 2–3, and compares widths, heights, glyph positions, SceneRects, and pixels against a forced-miss engine. Mechanism builds must show fewer HarfBuzz shapes after frame 1. The Conditional Candidate Protocol decides timing and regression acceptance.

- [ ] **Step 8: Accept or reject**

Accept with:

```bash
jj commit -m "perf(text): reuse cached shaped runs for measurement"
```

Otherwise abandon the isolated candidate change and record `rejected` with raw evidence.

---

### Task 9: Fuse max-content hard-line counting

**Condition:** Execute only when `hard_line_bytes_scanned` is nonzero and the hard-line traversal is material in the latest matrix.

**Files:**
- Modify: `src/v7_demo/text.zig:198-205,379-415,520-550`

**Interfaces:**
- Extend `IntrinsicMetrics` with `hard_line_count`.
- Use it only for `WidthMode.max_content`; all other modes retain `wrappedLineCount`.

- [ ] **Step 1: Write failing exact-line tests**

Test empty text, one line, leading/trailing newline, consecutive newlines, CR, CRLF, ZWS, spaces-only, and mixed hard/soft separators. Assert exact width and line count.

- [ ] **Step 2: Verify RED**

Reference `hard_line_count` in the test. Expected: missing field.

- [ ] **Step 3: Count hard lines in `intrinsicMetrics`**

Start at one line, increment once for each hard break, and preserve the current width update order. Do not count soft separators or ZWS as hard lines.

- [ ] **Step 4: Select the fused result narrowly**

```zig
const line_count = switch (mode) {
    .max_content => intrinsic.hard_line_count,
    else => wrappedLineCount(measurer, text, inline_width),
};
```

Do not infer that a `.definite` request resolving to the same numeric width is max-content.

- [ ] **Step 5: Verify and decide**

Run focused text tests, fixture oracle, shots, and paired counter-free timing. Accept only if one complete traversal disappears and Debug improves. Commit as `perf(text): fuse max-content line counting`; otherwise reject in the isolated workspace.

---

### Task 10: Remove the duplicate segment-content scan

**Condition:** Execute only when `segment_content_rescan_bytes` is nonzero and segment scanning is material.

**Files:**
- Modify: `src/v7_demo/text.zig:192-196,341-376,379-518`

**Interfaces:**
- `TextSegment` carries `has_content` computed by `nextTextSegment`.
- Remove `segmentHasContent` only after every caller consumes the explicit bit.

- [ ] **Step 1: Write failing segment-table tests**

Use a table covering empty input, ordinary bytes, spaces, tabs, CR, CRLF, LF, one/multiple ZWS sequences, delimiters after text, and trailing delimiters. Assert `end`, `next`, `break_kind`, and `has_content` for every returned segment.

- [ ] **Step 2: Verify RED**

Expected: `TextSegment` has no `has_content` field.

- [ ] **Step 3: Compute the bit during the original scan**

For every return path, set `has_content = index > start`; for the terminal return use `text.len > start`. This is safe because the scan stops at the first delimiter/ZWS. Preserve byte offsets and separator advancement.

- [ ] **Step 4: Migrate every caller and delete `segmentHasContent`**

Use `segment.has_content` in `intrinsicMetrics` and `LineRangeIterator`. Do not keep a compatibility helper.

- [ ] **Step 5: Verify and decide**

Run focused tests, fixture oracle, shots, and paired timing. Accept only with measured scan-byte reduction and a counter-free Debug gain. Commit as `perf(text): carry segment content state`; otherwise reject.

---

### Task 11: Remove retained wide command copies

**Condition:** Execute only when Debug disassembly shows retained wide value copies, `draw_cmd_value_bind_bytes` is nonzero, and `buildSliceRects` is material.

**Files:**
- Modify: `src/v7_demo/window.zig:832-955`

- [ ] **Step 1: Record the Debug assembly and command-copy counter baseline**

The mechanism build records bytes copied per command. Save the relevant assembly and counter totals in the candidate evidence directory.

- [ ] **Step 2: Change only loop bindings**

```zig
for (cmds) |*cmd| {
    const paint = &cmd.paint;
    // Existing statement order and output writes remain unchanged.
}
```

Update field access through pointers. Do not alter branches, materials, or output capacity in this task.

- [ ] **Step 3: Verify deep semantic output**

Compare `DrawCmd` field-by-field and `SceneRect` defined fields/order; never raw bytes containing pointers or padding. Compare `clip_rects`, node `paint_clip_id`/`clip_id`, five shots, GPU-sort verification, and fixture oracle.

- [ ] **Step 4: Verify timing and decide**

The counter-free candidate must reduce `buildSliceRects` or whole-frame Debug time beyond paired noise. Commit as `perf(render): avoid wide command copies`; otherwise reject.

---

### Task 12: Reserve the guaranteed SceneRect lower bound

**Condition:** Execute only when `slice_rect_growth_events` or `slice_rect_growth_copy_bytes` is nonzero in retained frames.

**Files:**
- Modify: `src/v7_demo/window.zig:1869-1889,2170-2194`

- [ ] **Step 1: Confirm the established growth counters**

Use the Task 7 `slice_rect_growth_events` and `slice_rect_growth_copy_bytes` fields. Do not add another counter or change allocator behavior before the baseline is recorded.

- [ ] **Step 2: Verify the baseline grows**

Run the triggering scene. If no steady-state growth occurs, mark this candidate `not_applicable` and stop.

- [ ] **Step 3: Write failing preflight and OOM tests**

Reference `reserveBaseSceneRectsBestEffort` from focused tests. Cover enough existing capacity, a successful lower-bound reservation, injected preflight OOM that leaves length/capacity/output unchanged, and a later canonical append OOM that still propagates. Expected RED: the helper does not exist.

- [ ] **Step 4: Add the preflight reservation**

Every `DrawCmd` emits one base `SceneRect`, so `base_cmds.len` is a lower bound. Before any scene append, call:

```zig
fn reserveBaseSceneRectsBestEffort(
    slice_rects: *std.ArrayList(SceneRect),
    allocator: std.mem.Allocator,
    lower_bound: usize,
) void {
    slice_rects.ensureTotalCapacity(allocator, lower_bound) catch |err| switch (err) {
        error.OutOfMemory => return,
    };
}
```

The helper handles optional-reservation OOM explicitly. Failure selects the unchanged incremental append path before mutation. All later canonical append errors still propagate. Compare complete SceneRect sequences and pixels under successful and failed preflight.

- [ ] **Step 5: Verify timing and decide**

Require fewer growth copies and counter-free Debug improvement. Commit as `perf(render): reserve base scene rects`; otherwise reject.

---

### Task 13: Replace known single-ID scans with the existing index

**Condition:** Execute only when `svg_card_node_comparisons` or `hover_focus_node_comparisons` identifies the named single-ID scans.

**Files:**
- Modify: `src/v7_demo/window.zig:176-186,1025-1102`
- Test: `src/v7/widget.zig:354-403` existing lookup tests

- [ ] **Step 1: Add behavior-lock tests**

Cover complete production `id_index`, incomplete direct-tree fallback, stale stored index, zero/unknown ID, hidden node, and absent hover/focus IDs.

- [ ] **Step 2: Replace `svgCardRect` scan**

Use `tree.nodeConst(id)`. Preserve the zero rectangle/layer when the global ID is null or absent and preserve `contentRect` errors.

- [ ] **Step 3: Replace hover/focus scans**

Resolve each known ID once with `nodeConst`. Preserve non-positive geometry behavior, material allocation order, and ring order.

- [ ] **Step 4: Verify and decide**

Compare selected logical IDs, interactions, SceneRects, pixels, fixture oracle, and counter-free timing. Commit as `perf(render): use indexed single-id lookups`; otherwise reject.

---

### Task 14: Guard unchanged SVG stroke-style writes

**Condition:** Execute only when `svg_stroke_write_attempts` is nonzero on retained unchanged frames and the SVG stroke-update zone is material.

**Files:**
- Modify: `src/v7_demo/svg_view.zig:491-530,889-927`
- Modify: `src/v7_demo/window.zig:1226-1245`

**Interfaces:**
- `SvgView` owns `last_stroke_style: ?StrokeStyle`.
- `StrokeStyle` compares `algo` and exact `oversize` bits.
- `setScale` remains independent.

- [ ] **Step 1: Write failing state-transition tests**

Test first write, identical repeat, algorithm change, oversize-bit change, scale-only change, and newly initialized/remounted view. The first call on every new view must write.

- [ ] **Step 2: Verify RED**

Expected: no style state or unchanged-write suppression.

- [ ] **Step 3: Add exact local generation state**

```zig
const StrokeStyle = struct { algo: u32, oversize_bits: u32 };
last_stroke_style: ?StrokeStyle = null,
```

At the start of `setStrokeStyle`, build the exact style using `@bitCast(oversize)`, return only on equality, and store the new value only after all material writes finish. A new `SvgView.init` starts at null. Do not couple this to `scale`.

- [ ] **Step 4: Verify multi-frame rendering and decide**

Exercise static, one-change, repeated-change, resize, remount, and three-frame reuse. Require identical pixels on every frame, fewer writes only on unchanged frames, and counter-free Debug improvement. Commit as `perf(svg): skip unchanged stroke style writes`; otherwise reject.

---

### Task 15: Add an exact derived GlyphKey index

**Condition:** Execute only when `glyph_entry_comparisons` is material in the latest matrix.

**Files:**
- Modify: `src/v7_demo/text.zig:80-105,608-660,789-802,943-1038`

**Interfaces:**
- `GlyphKey = { font_id: u8, size: u32, gid: u32 }`.
- Derived map stores entry indices; the current linear scan remains the correctness fallback.
- The map is append-only for the current append-only `entries` lifetime and never allocates after `TextEngine.init`.

- Reserve once for at most `max_materials` logical entries, record the map's resulting key/value/control-byte capacity, and forbid later growth.

- [ ] **Step 1: Write failing map/fallback tests**

Cover exact hit, wrong font/size/gid, stale/out-of-range map index, map capacity preflight failure, and a glyph appended without an index entry.

- [ ] **Step 2: Verify RED**

Expected: missing `GlyphKey` and index map.

- [ ] **Step 3: Implement lookup with validation and fallback**

On a map hit, validate that the stored index is in range and the entry key still matches. Otherwise run the existing linear scan. Never return an unchecked index.

- [ ] **Step 4: Preflight the optional map once during initialization**

During `TextEngine.init`, call `ensureTotalCapacity(gpa, max_materials)` before any glyph mutation. If this candidate-private allocation fails, leave the derived index disabled for the engine lifetime and use the unchanged linear path. When enabled, use `putAssumeCapacity` only after `entries.append` succeeds and assert `entries.items.len <= max_materials`. No frame-time map allocation or rehash is allowed.

- [ ] **Step 5: Deinitialize the map and verify failure cleanup**

No map pointer survives append or rehash. Compare glyph material indices, geometry, missing glyphs, raster errors, fallback, pixels, and fixture oracle.

- [ ] **Step 6: Verify timing and decide**

Require fewer comparisons and a net counter-free Debug emission/frame improvement after map maintenance. Commit as `perf(text): index glyph entries`; otherwise reject.

---

### Task 16: Build a shadow dense geometry view

**Condition:** Execute only after every triggered narrow candidate has been accepted or rejected, and the latest matrix still attributes material cost to parent/scroll/clip geometry walks.

**Files:**
- Create: `src/v7/frame_geometry.zig`
- Create: `src/v7/frame_geometry_test.zig`
- Modify: `src/v7/root.zig`
- Modify: `src/v7/app.zig:591-673`
- Modify: measured consumers in `src/v7/drawcmd.zig` and `src/v7_demo/window.zig` only after shadow equality passes

**Interfaces:**
- `FrameGeometry.build(allocator, tree) error{OutOfMemory,InvalidTree}!FrameGeometry` allocates only from the current frame arena.
- Arrays are indexed by physical node index but store logical parent/child identity explicitly.
- The view contains absolute/visual border origins, content rectangles, hidden state, clip ancestry, `ScrollState.offset`, and `max_offset` snapshots.
- `WidgetTree` remains semantic authority. Any declared build error occurs before publication and selects the complete old reader path for that frame.
- `memoryBytesForNodeCount` uses checked arithmetic. Storage is one exact-capacity SoA storage set plus one `u32` worklist entry and one visited bit per existing node; assert `@sizeOf(GeometryRow) <= 96` at compile time and report the two-live-frame byte bound.

- [ ] **Step 1: Write failing bitwise differential tests**

Build nested border/padding trees, non-contiguous sibling subtrees, multiple roots, direct trees with incomplete `id_index`, hidden descendants, and nested horizontal/vertical/both-axis nonzero scrolling. For every logical ID, compare old and shadow fields by bits, including signed zero. Add missing-child, duplicate-child, and cyclic malformed trees; they must select the complete old reader path without publishing a partial view.

- [ ] **Step 2: Verify RED**

Expected: missing `FrameGeometry` module.

- [ ] **Step 3: Build the shadow projection**

Use a bounded iterative worklist with exact capacity `tree.nodes.items.len` and a visited bit per physical node; recursion is forbidden. Seed roots in their existing order, resolve explicit child IDs with the existing indexed-plus-fallback semantics, and derive parent-before-child processing without assuming contiguous subtrees. A missing child, duplicate child, cycle, or worklist overflow returns `error.InvalidTree` before publication. Use `std.MultiArrayList(GeometryRow)` for the SoA projection and frame-arena storage for its exact node count plus the worklist and visited bits. Preserve relative `node.rect`; compute only derived absolute/visual views. Add candidate-specific `frame_geometry_oom_fallbacks` and `frame_geometry_invalid_fallbacks` fields behind `v7_perf_counters`. On either declared error, publish no slices, increment only the matching fallback counter, and run every old geometry reader for that frame.

- [ ] **Step 4: Run shadow-only mode**

Build the view but keep every consumer on old functions. Compare old/new values, callbacks, hit tests, `clip_rects`, node clip stamps, SceneRects, and pixels over multiple frames. Any mismatch rejects the design before reader switching.

- [ ] **Step 5: Switch one consumer at a time**

Order: `buildSliceRects` geometry reads, `collectDrawCmds`, then hit testing. After each switch, rerun exact differential, fixture, shots, nested-scroll sequences, and timing. Do not change layout algorithms or child storage.

- [ ] **Step 6: Verify projection cost is repaid**

Accept only when build plus all switched readers reduces counter-free Debug whole-frame time and memory stays within the frame-arena budget. Commit as `perf(core): add dense frame geometry view`; otherwise restore old readers and reject.

---

### Task 17: Decide whether an ordered render plan deserves its own implementation plan

**Condition:** Run only if command conversion/repeated scene scans remain material after Task 16 is accepted, rejected, or not applicable.

**Files:**
- Update: `docs/perf/debug-120-roadmap.md`

- [ ] **Step 1: Measure remaining render conversion work**

Count command scans, node scans, ancestor reads, records by kind, branch distribution, and bytes copied in a mechanism build. Use counter-free timing for the decision.

- [ ] **Step 2: Apply the go/no-go rule**

Create a separate render-plan implementation plan only if conversion remains a material budget contributor and narrower accepted changes cannot remove it. Otherwise record `not_applicable` or `rejected`.

- [ ] **Step 3: Pin the required future interface**

Any accepted design must use one explicit original-order sequence plus typed payload arrays. It must preserve `collectDrawCmds` side effects: `tree.clip_rects`, every node's `paint_clip_id`, and every node's `clip_id`, including injected failures and later-frame readers. Grouping by type/material is forbidden during differential proof.

- [ ] **Step 4: Commit the decision report**

```bash
jj commit -m "perf(render): decide ordered render plan"
```

---

### Task 18: Decide whether SIMD has a measured kernel

**Condition:** Run only after scalar/DOD changes stabilize and a homogeneous kernel remains material.

**Files:**
- Update: `docs/perf/debug-120-roadmap.md`

- [ ] **Step 1: Exclude ordered kernels**

Do not vectorize HarfBuzz calls, text prefix accumulation, line breaking, flex freeze/distribution, grid placement/water filling, winding, glyph emission, mixed draw commands, or any loop with order-visible `f32` reassociation.

- [ ] **Step 2: Name and inspect one candidate**

The mechanism report must name one exact symbol with contiguous independent lanes, a bounded scalar tail, no hidden allocation, and material frame cost. Inspect its Debug disassembly with `llvm-objdump`; a vector-looking source type without vector instructions or a scalar implementation that is already optimal is a no-go.

- [ ] **Step 3: Apply the go/no-go rule**

Record `not_applicable` unless the named symbol is material after all accepted scalar/DOD work and its scalar numerical contract permits lane-independent evaluation. `srgbToOklab` is eligible only if measured color conversion remains material. Ordered `f32` reduction or prefix results are never eligible.

- [ ] **Step 4: Write a separate implementation plan on go**

The new plan must name the exact source file and symbol, lane type/count, target feature assumptions, scalar tail, and differential tests for zero length, one less/equal/one more than lane width, unaligned start, signed zero, infinities/NaNs accepted by the scalar contract, and randomized exact inputs. It must reuse this fixture, SceneRect, pixel, memory, CPU-tail, and GPU-tail gate. Do not add SIMD code in this decision task.

- [ ] **Step 5: Commit the decision**

```bash
jj commit -m "perf(simd): decide measured kernel"
```

---

### Task 19: Final qualification and cleanup

**Condition:** Run after every triggered Task 8–16 item has an accepted, rejected, or not-applicable decision. A go decision from Task 17 or 18 blocks this task until its separate implementation plan is executed, that candidate is accepted or rejected through the same protocol, and the latest Task 7 matrix is frozen. Qualification can still produce a documented failure.

**Files:**
- Update: `docs/perf/debug-120-roadmap.md`
- Create: `docs/perf/debug-120-final.json`
- Remove temporary candidate counters/zones not behind compile-time false branches

- [ ] **Step 1: Run focused correctness gates**

Run all changed-module tests, allocation-failure tests, text edge cases, nested-scroll differential, five scene shots, GPU-sort verification, and multi-frame real-surface checks.

- [ ] **Step 2: Run the exact fixture gate**

```bash
zig build fixture -Doptimize=Debug
```

Required: 5,504 passed, 0 failed, 20 Unsupported, and digest `88071b9fb911c60b49f2999a29964b4805df92a65741bf9d73a88e7c28bf3a2a`.

- [ ] **Step 3: Run project phase gates**

```bash
zig fmt --check .
zig build test
zig build lint
gate
```

If the Zig test listener still fails without an assertion, report it separately; the standalone fixture executable remains the fixture authority. Do not call the aggregate command green unless it exits zero.

- [ ] **Step 4: Run final fixed-sample qualification**

Run:

```bash
python3 tools/run_v7_perf.py qualify \
  --warmup-from docs/perf/debug-120-baseline.json \
  --blocks 300 \
  --frames 1000 \
  --seed 0x4e4f475549313230 \
  --report docs/perf/debug-120-final.json \
  --out /tmp/nogui-perf/qualification
```

Expected: the runner collects the complete predeclared matrix before it computes the qualification result.

For every scene, predeclare 300 block indices. Each index groups one counter-free Debug offscreen process, one counter-free Debug presented process, and one GPU-query-only Debug offscreen twin, each with 1,000 retained frames. No interim stop, extension, replacement, or discard is allowed. If presentation timing is unavailable, omit the presented process from every index and prohibit the presented 120 FPS claim.

- [ ] **Step 5: Apply the complete pass contract**

For every scene, conditions 1–4 must hold in each applicable process of every grouped block index and in that cell's pooled 300,000-frame predeclared sample. One process failure fails the whole grouped block:

1. `within_120_fps_budget(p99_ns(cpu_compute_ns))` is true for clean offscreen and clean presented processes.
2. `within_120_fps_budget(p99_ns(gpu_execute_ns))` is true for the frame-ID-paired GPU-query-only offscreen twin.
3. `within_120_fps_budget(p99_ns(gpu_end_interval_ns))` is true for the three-slot GPU-query-only offscreen twin.
4. `within_120_fps_budget(p99_ns(present_interval_ns))` is true for the clean presented process, every presentation timestamp is unique, and the integer throughput gate is at least 120 frames/s.
5. Each scene has zero failed grouped blocks; its exact one-sided 95% block-failure upper bound from 300 blocks is `<1%`.
6. Exact fixture, semantic render, pixel, error, OOM, and multi-frame state gates pass.

If present feedback is unsupported, publish only “Debug compute capacity”; do not claim presented 120 FPS.

- [ ] **Step 6: Remove research-only scaffolding**

Delete rejected candidate code, unused counters, duplicate helpers, temporary aliases, and stale comments. Keep the reproducible perf runner, raw schema, standalone fixture gate, and compile-time instrumentation controls.

- [ ] **Step 7: Final review and commit**

Require independent performance and oracle reviews with no blockers. Then:

```bash
jj commit -m "perf(v7): qualify Debug frame budget"
```

---

## Phase Gates

### After Tasks 1–6

Run fixture, focused perf tests, five shots, GPU-sort verification, format, build, lint, and gate. Do not collect the baseline until these pass.

### After Every Conditional Candidate

1. Mechanism build proves the intended work decreased.
2. Counter-free paired blocks prove the timing effect.
3. Exact fixture digest remains pinned.
4. Old/new semantic and pixel checks pass.
5. OOM/failure behavior remains exact.
6. Candidate is accepted, rejected, or not applicable; no dormant alternate implementation remains.
7. The Task 7 measurement matrix is rerun after acceptance.

### Before Any 120 FPS Claim

The fixed 300-block qualification, actual presentation feedback, and all five scenes are mandatory. Historical Tracy captures, GPU-only headroom, frame-start medians, or one screenshot cannot substitute for this gate.

## Explicit Non-Goals

- No full retained-layout system in this work.
- No repo-wide ECS conversion.
- No broad `WidgetNode` SoA rewrite before the shadow geometry view proves value.
- No type/material draw batching before ordered render-plan equivalence.
- No SIMD chosen from source appearance alone.
- No numerical speedup promise before counter-free paired measurements.
