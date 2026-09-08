# nogui

`nogui` is a Linux-focused immediate-mode GUI research prototype written in Zig 0.16. It renders batched quads through `noapi` and Vulkan.

The v7 implementation is the canonical library. The project does not yet promise a stable API, a release-quality platform layer, or a performance qualification.

## Current stocktake

The following results are verified:

- All 5,524 normalized Taffy variants match: 5,524 passed, 0 failed, and 0 unsupported.
- The separate 581-row application layout golden still matches.
- Both configured linters scan 77 active Zig files and report no warnings.
- The vendored `noapi` unit suite passes all 55 tests with Tracy disabled, including the watchdog regression.
- The watchdog resets its deadline when presentation feedback completes. It still fails a stalled feedback stream after five seconds.
- The Debug core/demo test suite passes all 1,028 tests.
- The ReleaseSafe core/demo test suite passes all 1,028 tests.
- Ten actual GPU shots (five scenes in normal and reverse order) match the frozen shots byte for byte.
- The actual GPU remount smoke passes. Mandelbrot reuses slot 2 after one hidden frame.
- The offscreen smoke passes 24 frames and 20 samples with exact CPU stage sums. It records a GTX 1660 Ti, NVIDIA, vendor 4318, device 8593.
- The presented smoke passes 24 ordered frames and 20 complete samples with positive intervals. It records actual driver `595.99.02`.
- A real Tracy capture and its CSV aggregation pass with 20 sample roots.
- The Python protocol tests pass all 125 tests. Synthetic Tracy aggregation cases cover 200 frames (16.726 seconds to 0.1822 seconds) and 1,000 frames (0.9155 seconds).
- The CI workflow includes the Python protocol test step.

Fresh calibration completed with `capped_unstable` and 2,400 warm-up frames. The full baseline was stopped after reported throughput near 1 FPS. Partial captures are diagnostic evidence, not an accepted baseline.

These results do not prove 120 frames per second. The performance section describes the measurement protocol and its targets only.

## Development environment

The repository provides a Nix development environment:

```bash
direnv allow
devenv shell
```

`devenv.nix` supplies Zig 0.16, Python 3, Jujutsu, both linters, Vulkan and shader tools, FFmpeg, Tracy, and Linux window-system dependencies. It sets the required library and include paths.

The linter package is `ziglint` 0.5.3 with one declarative compatibility patch. The patch classifies public merged error unions as types. It does not suppress a rule or ignore a path.

For another Linux environment, provide these system dependencies:

- Zig 0.16, `pkg-config`, `find`, and `grep`.
- Vulkan headers, loader, and validation layers.
- Wayland, X11, udev, ALSA, libdecor, libusb, and libxkbcommon.
- FFmpeg libraries `avformat`, `avcodec`, `avutil`, `swresample`, and `swscale`.
- `slangc` for the interactive v7, Spotify, and calculator shader-update paths.

The Zig package manager supplies SDL3, FreeType, HarfBuzz, libxml2, and Tracy from pinned dependencies. The repository supplies `noapi` from `vendor/noapi`.

## Build and run

Run these commands from the repository root:

| Command | Result |
| --- | --- |
| `zig build` | Build and install the `nogui` executable and `v7-demo`. |
| `zig build run` | Run the minimal application. Arguments after `--` pass to it. |
| `zig build v7` | Run the default v7 demo. |
| `zig build spotify` | Run the Spotify stress scene. |
| `zig build calculator` | Run the calculator demo. |
| `zig build check` | Compile the library, executables, fixture runner, and test binaries without running them. |
| `zig build test` | Run the project test suite. |
| `zig build test -Dtest-filter=NAME` | Run tests whose names contain `NAME`. |
| `zig build fixture` | Run the complete pinned Taffy fixture oracle. |
| `zig build fixture -Dfixture-filter=leaf/leaf_with_content_and_border.html` | Run all normalized variants for one fixture source. |
| `zig build lint` | Run `ziglint` and recursive `zlint` on the active v7 source tree. |
| `zig build layout-check` | Compare the headless demo layout with `testdata/layout-golden.json`. |
| `zig build layout-update` | Replace `testdata/layout-golden.json` with current headless output. |
| `zig fmt --check src build.zig build.zig.zon` | Check first-party Zig formatting without changing files. |
| `gate` | Run declared formatting, Debug/ReleaseSafe, backend, layout, lint, and Python checks. |

Use `-Doptimize=ReleaseSafe` with a build step for a ReleaseSafe build. The build also accepts `-Dv7-tracy`, `-Dv7-gpu-timestamps`, and `-Dv7-perf-counters` boolean options.

`gate` runs repository-defined checks. It does not depend on `~/.local/bin/zig-gate`.

`layout-update` changes a verification asset. Use it only for an intentional layout-contract change, then review the complete diff.

Do not run recursive formatting over downloaded `zig-pkg` trees or the preserved vendored source.

## v7 module

`build.zig` exports module `nogui` from `src/v7/root.zig`. Graphical code uses `v7_render` from `src/v7_render/root.zig` as a separate renderer module.

The main `nogui` entrypoints are:

| Export | Purpose |
| --- | --- |
| `App` | Own the component registry, input state, frame arenas, and headless frame loop. |
| `DrawCtx` | Build the immediate widget tree and enter keyed component scopes. |
| `WidgetTree`, `WidgetNode`, `Id` | Store one frame of typed widgets and relative geometry. |
| `Style`, `StyleOverride`, `PaintStyle` | Define layout and paint data without a selector cascade. |
| `layout.layoutTree` | Run pure-Zig block, flex, grid, float, and absolute layout. |
| `layout.Options`, `layout.MeasureFn` | Supply an allocator, available size, and optional host measurement callback. |
| `headless`, `treeToJson`, `FrameOutput` | Drive and inspect the core without a GPU runtime. |
| `GpuEndpoint`, `GpuFrame` | Give component lifecycle hooks scoped access to the graphical backend. |

The module also exports input, event, callback, geometry, grid-track, overflow, and performance-counter types from `src/v7/root.zig`.

### Core invariants

- Each frame builds a fresh `WidgetTree` in one of two frame arenas.
- The previous frame remains valid until the next arena reset.
- Tree storage is postorder. Each container follows all its descendants.
- `WidgetNode.rect` is a border box relative to its parent content box.
- A root rectangle is relative to the surface.
- Component identity combines the parent identity with a stable caller key.
- Duplicate sibling component identities return an error.
- Layout uses explicit allocators and does not call the renderer or `noapi`.
- The headless path does not create a GPU runtime.
- GPU frame handles are valid only during their component lifecycle call.

The former fixed 64-level `DrawCtx` parent stack now grows from the frame arena. The former fixed 10,000-track grid cap is also removed.

These removals do not make storage unbounded. Widget identifiers and indexed storage use `u32`, geometry uses `f32`, and collection sizes use `usize`.

Allocation failure can return `OutOfMemory`. Invalid or unrepresentable layout arithmetic can return `InvalidStyle` or `IndefinitePercentage`.

The GPU clip buffer remains a separate 64-rectangle renderer boundary. Exceeding it returns `ClipCapacityExceeded`.

## Layout fixture provenance

The repository stores the pinned Taffy corpus in three forms:

- `testdata/taffy-v0.13.0/upstream/` contains the enabled upstream fixture sources.
- `testdata/taffy-v0.13.0/normalized/cases.json` contains the normalized cases.
- `testdata/taffy-v0.13.0/MANIFEST.json` records source hashes and generator metadata.

The manifest pins DioxusLabs Taffy `v0.13.0` at commit `45a56299d366ddb383e593a1f0372158d00e8530`. It records 1,381 sources and 5,524 cases.

`tools/import_taffy_v013_fixtures.py` is generator version 2. It requires a clean Taffy checkout at the pinned commit through `--source` and writes the corpus selected by `--out`.

Normal fixture-oracle runs do not need Rust, a Taffy checkout, or fixture regeneration. An initial Zig dependency fetch can require network access.

The conformance result includes 20 variants from five `vertical-lr` text fixtures. A fixture-only Ahem measurement adapter handles those variants.

The fixture runner forwards `-Dfixture-filter` to the oracle. One selected source runs its four LTR/RTL and border-box/content-box variants.

This adapter does not implement general vertical text layout or vertical text rendering in the GUI runtime.

The 581-row application golden is a separate nogui regression artifact. It does not replace the upstream conformance oracle.

## Vendored `noapi`

`build.zig.zon` resolves `noapi` from `vendor/noapi`. The original sibling workspace is not part of this package dependency.

`vendor/noapi-provenance.json` records the local Jujutsu commit `f11603da1e953c4496fcd3cd6c5a492cf11f6c7d` and change ID `lxrmvysxnotnwkpwuslzvpmklkmosoom`. Its source repository has no recorded remote.

The provenance record binds the exact source tree with SHA-256 digest `3601d5f0c1c72ebc95c58edd55003d422a18b495384955e949740b2bce6fd745`. It also records original and current hashes for three local patches:

- `noapi/Gpu.zig`
- `noapi/Queue.zig`
- `noapi/VkBackend.zig`

The complete vendored tree has digest `0bd201ce839905535c4ea4edc878ae43cbd03eb33f9b2e04b54d8cfd73e8a1d3` under the manifest's canonical digest rule.

The upstream `noapi` source tree contains no `LICENSE`, `COPYING`, or `NOTICE` file at its root. Do not infer redistribution terms from dependency license files under `vendor/noapi/zig-pkg`.

## Performance protocol

`tools/run_v7_perf.py` uses only the Python standard library. It accepts five subcommands:

| Subcommand | Purpose |
| --- | --- |
| `snapshot` | Build and freeze one isolated instrumentation profile. |
| `calibrate` | Measure warm-up stability for all five scenes. |
| `matrix` | Collect the default multi-profile baseline matrix. |
| `pair` | Compare frozen baseline and candidate manifests. |
| `qualify` | Run the fixed final qualification protocol. |

Use each command's built-in interface description:

```bash
python3 tools/run_v7_perf.py snapshot --help
python3 tools/run_v7_perf.py calibrate --help
python3 tools/run_v7_perf.py matrix --help
python3 tools/run_v7_perf.py pair --help
python3 tools/run_v7_perf.py qualify --help
```

The four isolated profiles map to build flags as follows:

| Profile | Tracy | GPU timestamps | Mechanism counters |
| --- | ---: | ---: | ---: |
| `clean` | false | false | false |
| `tracy` | true | false | false |
| `gpu` | false | true | false |
| `mechanism` | false | false | true |

A fresh calibration and the default 10-block, 1,000-frame matrix use these commands:

```bash
python3 tools/run_v7_perf.py calibrate \
  --seed 1 \
  --out /tmp/nogui-perf/calibration

python3 tools/run_v7_perf.py matrix \
  --warmup-from /tmp/nogui-perf/calibration/warmup.json \
  --seed 2 \
  --report /tmp/nogui-perf/matrix-report.json \
  --out /tmp/nogui-perf/matrix
```

Use fresh output paths. The runner rejects stale or inconsistent artifacts.

The default matrix covers Debug and ReleaseFast offscreen cells plus a Debug presented cell. It collects `clean`, `tracy`, `gpu`, and `mechanism` snapshots for each required cell.

`pair` consumes distinct baseline and candidate manifests for `clean`, `gpu`, and `mechanism`. Its block count must be positive and even.

`qualify` requires exactly 300 blocks and 1,000 frames for every one of the five scenes. This command is distinct from the default matrix.

### Calibration stability

Calibration always records exactly 2,400 diagnostic frames per scene and profile. It examines boundaries from frame 600 through frame 2,160 in 120-frame steps.

At each boundary, it compares three disjoint 120-frame window medians. A metric is stable when this integer relation holds:

```text
(maximum_median - minimum_median) * 10000 <= minimum_median * 1200
```

The relation permits a maximum spread of 12%. A selected boundary and every later boundary must pass.

When all scenes sustain the rule, the runner adds a 240-frame guard to the latest boundary. It caps the selected warm-up at 2,400 frames.

If any scene has no sustained boundary, the runner selects 2,400 frames and writes `stability_status: capped_unstable`.

`capped_unstable` means that the host did not satisfy the sustained-stability rule before the cap. It does not mean stable, accepted, or fast.

The 12% rule selects warm-up only. It does not change any frame budget or prove the 120 FPS target.

Fresh calibration completed across all five scenes and both profiles. Only Strokes sustained the 12% stability rule, at frame 1,920. The other four scenes had no sustained boundary, so the manifest records `capped_unstable` and 2,400 warm-up frames.

The full matrix was stopped after the user reported throughput near 1 FPS. Seven complete Todo Debug offscreen blocks remain under `~/.cache/nogui/perf/stocktake-2026-09-09/baseline/Debug/offscreen/`. They do not constitute an accepted baseline.

The saved pre-cache Tracy block `todo-tracy-offscreen-0001-0002.csv` attributes 847.502 seconds to `shapeForMeasure` across 3,400 frames: 894 calls per frame. These are inclusive zone totals across warm-up and sample frames, not independent stage sums. Measurement reshaped every request before the cross-frame cache change below.

The calibration manifest is `~/.cache/nogui/perf/stocktake-2026-09-09/calibration/warmup.json`. Do not restart the full matrix at this throughput without revisiting the measurement plan.

### Cross-frame text shaping

`src/v7_demo/text_shape_cache.zig` owns text and shaped glyph data across frame-arena resets. Measurement and rendering share it. Keys compare exact text bytes, immutable font identity, and pixel size. The current shaping settings are fixed LTR/Latin. Layout width and paint are not key fields; wrapping is recomputed from retained clusters and advances.

The cache retains at most 256 runs and 4 MiB of payload, plus fixed bookkeeping. Leases pin active runs against eviction. Oversized runs and fully pinned admission pressure use owned transient runs, without changing the output. Cache hits allocate and shape nothing. Font resources must remain immutable for the cache lifetime.

The user chose short diagnostics instead of restarting the full matrix. Each capture used four warm-up frames and 20 samples, with matching runtime identity and extent:

| Todo Debug offscreen metric | Before | After |
| --- | ---: | ---: |
| Clean CPU median | 199.385 ms | 34.604 ms |
| Mechanism-profile CPU median | 229.197 ms | 30.538 ms |
| HarfBuzz shapes per sampled frame | 928 | 3 |

The three remaining shapes are the changing frame header and two visible toggle counters. All ten actual-GPU reference shots remain byte-identical. Tests cover mutable input ownership, released-run reuse, font and size changes, width-dependent wrapping, pinned lifetimes, payload and entry pressure, and allocation failures.

A separate 100-sample churn check also kept exactly three shapes per frame after the changing labels exceeded the cache entry capacity.

The [diagnostic report](docs/perf/text-shaping-cache-diagnostic.json) records capture and binary hashes. Raw files and shots are retained under `~/.cache/nogui/perf/stocktake-2026-09-09/text-cache/`. This is one short process per profile and version, not a stable repeated-process baseline or a 120 FPS qualification. The full matrix remains deferred.

### Frame-local lookup and measurement keys

`WidgetTree.prepareIdLookup` builds a dense ID index when the ID range is at most twice the node count. It preserves postorder indices. Its payload uses at most eight bytes per node in the frame allocator. Node insertion and relocation discard the view. Sparse or inconsistent maps keep their existing lookup behavior.

`MeasurementCache.key` now hashes 32 request bytes and mixes the node index separately. It adds no persistent cache. Neither change retains measurement results across layout passes.

The comparison uses eight mirrored blocks in one process for each scene and build mode. Each process has eight warm-up frames. Each variant contributes 160 sampled frames. Runs use CPU 2 and a 954 × 1044 offscreen target. Tracy, mechanism counters, and GPU timestamps are off.

The CPU values measure main-thread work, not wall-clock frame intervals. Parentheses show faster blocks out of eight.

| Scene | Debug CPU reduction | ReleaseSafe CPU reduction | Debug instruction reduction | ReleaseSafe instruction reduction |
| --- | ---: | ---: | ---: | ---: |
| Spotify | 8.5% (7/8) | 4.6% (6/8) | 8.0% | 2.3% |
| Todo | 5.5% (8/8) | 2.0% (4/8) | 4.1% | 0.9% |
| Calculator | 5.7% (7/8) | 2.3% (5/8) | 5.4% | 1.3% |

A Debug identical-binary control differs by 0.35%. This does not establish an error bound. ReleaseSafe timing remains variable, especially Todo.

The instruction comparison uses unmodified production executables in ABBA order. Each executable runs twice per scene and build mode, with eight warm-up frames and 200 samples. These counts include process setup and warm-up.

The node-local measurement cache had too few recent hits. A shared request-hash cache also failed the performance check: it added about 1.5% to ReleaseSafe frame CPU time. Both caches were removed.

All 5,524 Taffy variants and the 581-row layout golden still match. Ten actual GPU reference shots remain byte-identical. The temporary probes checked 225,792 lookup results and 4,096 measurement keys before removal.

Raw data, binary hashes, rejection evidence, and `results.json` are under `~/.cache/nogui/perf/stocktake-2026-09-09/hotspot-fixes/spotify-round3/`. These are short diagnostics, not a 120 FPS qualification. The full matrix remains deferred.

## Design records

These documents preserve the approved design history and state the current implementation boundary:

- [`docs/superpowers/specs/2026-08-22-v7-canonical-design.md`](docs/superpowers/specs/2026-08-22-v7-canonical-design.md)
- [`docs/superpowers/specs/2026-08-24-taffy-functional-parity-design.md`](docs/superpowers/specs/2026-08-24-taffy-functional-parity-design.md)
- [`docs/superpowers/specs/2026-08-30-debug-120-calibration-threshold-design.md`](docs/superpowers/specs/2026-08-30-debug-120-calibration-threshold-design.md)
