# nogui

`nogui` is a Linux-focused immediate-mode GUI research prototype written in Zig 0.16. It renders batched quads through `noapi` and Vulkan.

The v7 implementation is the canonical library. The project does not yet promise a stable API, a release-quality platform layer, or a performance qualification.


## Acceptance status

What this repository proves today, and what it does not, is recorded in
[`docs/ACCEPTANCE.md`](docs/ACCEPTANCE.md). Read it before claiming parity
with any reference implementation: the house gate is green, but macOS,
Windows and mobile runtime acceptance needs SDKs and devices this project has
never had, and the acceptance harnesses for those runs do not travel with the
source.

## Prior stocktake

These results predate the 2026-09-25 `noapi` and widget changes. The full performance matrix and Zwanzig analysis were not repeated. Later short diagnostics appear below.

- All 5,524 normalized Taffy variants match: 5,524 passed, 0 failed, and 0 unsupported.
- The layout golden then recorded 581 rows. The golden now in the repository is
  `testdata/layout-golden.json`, **74 rows**; that is the file
  `zig build layout-check` compares, and the 74-row figure is what is reproducible
  today.
- Both configured linters pass across 77 active Zig files.
- The vendored `noapi` suite passes all 55 tests with Tracy disabled, including the watchdog regression.
- The watchdog resets its deadline when presentation feedback completes. It still fails a stalled feedback stream after five seconds.
- The Debug core/demo suite passes 55/55 steps and 970/970 tests.
- The ReleaseSafe core/demo suite passes 48/48 steps and 970/970 tests.
- Ten actual GPU shots (five scenes in normal and reverse order) matched recorded
  SHA-256 values byte for byte **as of that stocktake**. The reference shots and
  their hashes were not kept in the repository, so that comparison is not
  reproducible in this checkout. See [Performance protocol](#performance-protocol).
- The GPU remount smoke passes. Mandelbrot reuses slot 2 after one hidden frame.
- A Todo Debug offscreen run records 24 ordered frames and 20 samples on the GTX 1660 Ti.
- A Todo Debug presented run records 24 ordered frames, 20 samples, and positive presentation intervals on driver `595.99.02`.
- The Python protocol suite passes all 125 tests. Synthetic Tracy aggregation covers 200-frame and 1,000-frame cases.
- The CI workflow includes the Python protocol test step.
- Zwanzig 0.15.1 analyzed all 79 `src/` Zig files. After triage, 17 diagnostics remain: 14 guarded optional unwraps, two dynamically used methods, and one demo heading mistaken for a TODO. Explicit `type` declarations keep `CounterSink` PascalCase and let Zwanzig recognize both aliases. Zwanzig exits 1 and is not part of `gate`.

Those two suite counts and the `noapi` count are the stocktake's own, and the dated records agree: [`2026-08-22-v7-canonical-v1.md`](docs/superpowers/plans/2026-08-22-v7-canonical-v1.md), [`2026-08-24-taffy-functional-parity.md`](docs/superpowers/plans/2026-08-24-taffy-functional-parity.md), [`2026-08-30-debug-120fps-optimization.md`](docs/superpowers/plans/2026-08-30-debug-120fps-optimization.md) and [`2026-08-30-relax-debug-calibration-threshold.md`](docs/superpowers/plans/2026-08-30-relax-debug-calibration-threshold.md) each record 55/55 Debug steps with 970/970 tests, 48/48 ReleaseSafe steps with 970/970 tests, and the vendored `noapi` suite at 55/55 with Tracy disabled. A larger `noapi` figure of 58 belongs to the later 2026-09-26 parity work and is recorded there as a dated W01 observation, not as part of this stocktake.

These short Todo runs have CPU medians of 10.151 ms offscreen and 9.630 ms presented. They are diagnostics, not a stable baseline. An earlier real Tracy capture and CSV aggregation passed with 20 sample roots; that capture was not repeated here.

Earlier calibration reached `capped_unstable` and selected 2,400 warm-up frames. The full baseline was stopped after reported throughput near 1 FPS. The partial captures are not an accepted baseline, and no 120 FPS qualification has been established.

That stocktake's `gate` run passed: format, lint for 78 Zig files, the then-581-row
layout golden, Zig tests, and 125 Python tests. The vendored `noapi` tests passed
with Tracy disabled. Two GPU frames, six headless Todo frames with a checkbox
click, and an offscreen widget render ran. These runs do not establish a
performance baseline.

### Verification after that stocktake

Only the distribution manifest, the Python protocol suite and the layout golden
were re-checked afterwards. Every other number in this section stays as dated
history.

- `vendor/noapi-provenance.json` records 92 upstream files, 93 current files including the owner-authorized MIT grant, and 11 local patches. The upstream digest is `612ae7dfc9f8b1db81a38b1f736e6e01ff54d86ebf5854286ab299f37a08bb56`; the current digest is `eb49985cd0727119f998e27b48ad08307c7c3f7c1060e41c60b666f3f2f055df`, read from the manifest's own `content_digest` field.
- `testdata/layout-golden.json` is a 74-entry JSON array and is the golden the `layout-check` step reads. The earlier 581-row figure belongs to a superseded golden that is not in this checkout. The command itself was not re-run here, so 74 is the count the committed file carries, not a fresh pass.
- The Python suite is discovered by CI as `python3 -m unittest discover -s tools -p 'test_*.py'`. The three `tools/test_*.py` files declare **180** test methods between them: 116 in `test_run_v7_perf.py`, 10 in `test_import_taffy_v013_fixtures.py`, and 54 in `test_speech_module_observer.py`. No `load_tests` hook or dynamic method injection is present, so the declared count is the discoverable count. This suite was not executed for this revision.

No Zig test count, lint-file count, fixture result or GPU shot result was re-run for
this revision, so none of them is restated here as current.

## Development environment

The repository provides a Nix development environment:

```bash
direnv allow
devenv shell
```

`devenv.nix` supplies Zig 0.16, Python 3, Jujutsu, both linters, Vulkan and shader tools, FFmpeg, Tracy, and Linux window-system dependencies. Cargo and rustc build the pinned AccessKit bridge. AT-SPI2 supplies its launcher and registry daemon for isolated native accessibility checks; `AT_SPI_BUS_LAUNCHER`, `AT_SPI2_REGISTRYD` and `AT_SPI_DATADIR` name those declared paths. The environment also sets the required library and include paths.

The linter package is `ziglint` 0.5.3 with one declarative compatibility patch. The patch classifies public merged error unions as types. It does not suppress a rule or ignore a path.

For another Linux environment, provide these system dependencies:

- Zig 0.16, `pkg-config`, `find`, and `grep`.
- Vulkan headers, loader, and validation layers.
- Wayland, X11 (including `libXcursor` for nested Niri acceptance), udev, ALSA, libdecor, libusb, and libxkbcommon.
- FFmpeg libraries `avformat`, `avcodec`, `avutil`, `swresample`, and `swscale`.
- `slangc` for the steps that compile shaders: `v7`, `spotify`, `calculator`, `run-parity-list-live`, `run-parity-state-pair`, and the `w07-host-smoke`, `w13-canvas-smoke`, `w14-asset-smoke`, `w17-anim-smoke`, `w21-atspi-smoke` and `w24-inspector-smoke` steps, including the headless v7 default. `zig build check` reaches the same shader step through three of those smokes, so it needs `slangc` too; `test`, `lint` and `fixture` do not.
- Cargo and rustc whenever the AccessKit bridge is built, which is the default in the package graph and in the `host` consumer graph; `-Daccesskit-bridge=false` keeps the build free of a Rust toolchain.
- AT-SPI2's bus launcher and registry daemon for native Linux accessibility acceptance.

The Zig package manager supplies SDL3, FreeType, HarfBuzz, libxml2, and Tracy from pinned dependencies. The repository supplies `noapi` from `vendor/noapi`.

FreeType is PNG-enabled to match HarfBuzz's transitive dependency. Both requests use the same target and optimization mode, so Zig shares one static FreeType artifact. Both font libraries follow `-Doptimize`.

## Build and run

Run these commands from the repository root:

| Command | Result |
| --- | --- |
| `zig build` | Build and install the `nogui` executable and `v7-demo`. |
| `zig build run` | Run the minimal application. Arguments after `--` pass to it. |
| `zig build v7` | Run the default v7 demo. |
| `zig build v7 -- --keyed-reorder-smoke` | Run the finite Todo list reorder/focus smoke through real frame and input dispatch. |
| `zig build v7 -- --sim testdata/sim/todo-increment.jsonl` | Replay three headless Todo frames. Six Tab events focus `inc`; Enter changes `Counter: 0` to `Counter: 1` while focus stays on that button. Emits one JSON state/tree line per frame. |
| `zig build v7 -- --frames 3` | Open a native Todo window, render three frames, and exit. Do not combine with `--window`. |
| `zig build spotify` | Run the Spotify stress scene. |
| `zig build calculator` | Run the calculator demo. |
| `zig build check` | Compile the library, executables, fixture runner, parity examples, work-package smokes and test binaries without running any of them. |
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

Use `zig build v7 -- --window --uncapped` for an interactive render loop without FIFO pacing, or `mangohud zig-out/bin/v7-demo --window --uncapped` to inspect FPS. The flag requests Vulkan IMMEDIATE presentation and skips the optional frame pacer; normal window runs keep FIFO vsync. If IMMEDIATE is unavailable, `noapi` logs its selected fallback mode. On Wayland, rendered FPS may exceed the monitor refresh rate, but visible updates cannot.

`gate` runs repository-defined checks. It does not depend on `~/.local/bin/zig-gate`.

`layout-update` changes a verification asset. Use it only for an intentional layout-contract change, then review the complete diff.

Do not run recursive formatting over downloaded `zig-pkg` trees or the preserved vendored source.

### Work-package smoke steps

Each work-package smoke is its own executable with its own step. The default run is headless, windowless, or on SDL's `dummy` driver. Native presentation, a live compositor, or a user-visible system action needs an explicit flag.

| Step | What the default run does | Explicit opt-in |
| --- | --- | --- |
| `zig build w07-host-smoke` | Two real windows on one `Session` model, a shared revision, a close veto and an accepted `Session.deinit`. | Needs a live display server and GPU. Arguments after `--`: `--hold-ms MS`, `--minimized-hold-ms MS`, `--windows 1` or `--windows 2`, `--present-frames N`, `--scale-watch-ms N`, `--pointer-watch`, `--fail-after-open N`. |
| `zig build w09-controls-smoke` | Headless Todo control lifecycle: press, move, release and cancel. | `--native --step-ms MS --ppm PATH`: real external-controller input, presented GPU image; verified private X11 at 1×. |
| `zig build w10-keyboard-smoke` | Probes the keyboard and cursor services. | `--show-window`, `--video-driver`, `--expect-identifier`. |
| `zig build v7 -- --shortcut-native` | Actual hosted Todo shortcut registry and real-clock chord/replay acceptance through external keys. | `--shortcut-native=MS`, `--shortcut-step-ms MS`, `--shortcut-pixels=PATH`; private X11 proof on GTX 1660 Ti, 37 presentations. |
| `zig build w12-ime-smoke` | SDL `dummy` text-input lifecycle with synthetic events. | `--native`, `--interactive`. |
| `zig build w13-canvas-smoke` | Windowless paint pixel specimen: 386 checks on the GTX 1660 Ti. | `--native [PPM] --hold-ms N` presents the same specimen plus old/current-frame paint and pixels: 430 checks, 1× private-X11 evidence. |
| `zig build w14-asset-smoke` | Asset and rendered-image path through the public renderer. | Needs a live display server and GPU. |
| `zig build w17-anim-smoke` | Authored animation and reduced motion through a host. | Needs a live display server and GPU. |
| `zig build w18-dialog-smoke` | Dialog provider refusal and the no-session-bus child. | `--authorize-clipboard-mutation` for the clipboard half. |
| `zig build w19-service-smoke` | Capability report without notification posts or credential reads. | `--help` lists separate notification and synthetic secret-store approval scopes. Run only against the intended provider. |
| `zig build w20-capture-smoke` | Capability report without a chooser or capture stream. | Native capture needs `--authorize-native-capture`, explicit source/cursor policy, a bounded budget and interactive portal approval. |
| `zig build w21-atspi-smoke` | Headless semantic tree and action gate. | `--native` publishes through AccessKit and needs the bridge linked plus a live a11y bus; that bridge is on by default, and `-Daccesskit-bridge=false` is the Rust-free route on which the adapter keeps reporting `unavailable`. `--bell` rings that window's platform bell once and refuses to run without `--native`. `--hold-ms` sets the hold and `--ppm` writes the last presented frame's own pixels. |
| `zig build w22-layer-shell-smoke` | Windowless protocol and refusal checks. | `--native` requests a real Wayland layer buffer. Terminal checks require compositor-delivered `closed` or output removal. |
| `zig build w22-popup-smoke` | Windowless popup refusal. | `--native` requests a real popup buffer. |
| `zig build w23-diagnostics-smoke` | Real windowless GPU metadata. | Windowless only. |
| `zig build w23-macos-smoke` | Portable probe reporting unavailable native support on Linux. | macOS SDK/runtime and the requested phase's approvals are required. |
| `zig build w23-windows-smoke` | Portable capability probe. | Native Windows runtime, SDK and explicit service approvals are required. |
| `zig build w23-windows-field-test -Daccesskit-bridge=false` | Production CPU-font field regressions: Unicode selection/movement, empty/full hit-testing, pointer refocus and painted/native caret agreement. | No display or target SDK required; not Windows-native acceptance. |
| `zig build w23-mobile-smoke` | Portable platform-half probe, not a device claim. | An Android/iOS SDK and device or simulator are required. |
| `zig build w24-inspector-smoke` | Headless overlay picking, style/clip/focus round trips and bounded real task/action collectors. | `--native` presents the inspected scene; `--gpu-timing` reads and attaches device queries by frame ID; `--ppm PATH` saves inspected sRGB pixels. |
| `zig build w24-perf-pair-bench` | Paired recorder distributions over one tree. | Needs a live GPU and takes minutes by design. |

The 2026-10-02 W07 evidence came from owned private servers, never from a user desktop. On a private Niri/Xvfb session the output scale moved 1→1.25 and back to 1 while the window held logical 900×620 against device 1125×775; real pointer motions agreed with their routed counterparts and hit the committed probe at both scales, the settled candidate and App generations matched at 26, and 119 presented frames reported zero extent mismatches. That arm started no native IME, so it is geometry evidence, not a candidate-window claim. An owned Openbox/X11 run observed minimize as `minimized=true, visible=false` and, after restore, `minimized=false, visible=true`, both within the deadline; its external loop took nine steps and never called `Application.run`, both GPU surfaces retired before their windows, and the injected `--fail-after-open 2` refusal returned its own error without a reported leak. The `api-w07` filter passed 44/44.

The 2026-10-01 mapped W10 smoke passed on a private Xvfb: actual pointer enter/motion exercised cursor visibility and hide-until-move; a real US→German server layout change delivered one callback, generation 0→1 and physical-scancode labels Y/Z→Z/Y. The controller targeted only that owned server/window. No synthetic SDL event or user desktop setting was used.


The complete 2026-10-02 private X11/IBus scenario accepted 35 items with zero refusals. Real preedit, one multibyte commit, cancellation, wrapped/scrolled caret geometry and composition after focus return passed. Both attributed candidate windows passed, and their pixels were inspected. The run used one focused engine setter and never touched the user input method or clipboard.

### Point-of-risk actions

Mutating the native clipboard, opening a file or message dialog, revealing a path in a file manager, opening an external URL, posting a notification, reading or writing a secret-store entry, and starting a capture stream are all external, user-visible actions. The host gates each one on a value the caller supplies instead of performing it on demand.

- `dialogs.PointOfRiskApproval` and `open_url.PointOfRiskApproval` are `struct { confirmed: bool = false }` in [`src/v7_host/dialogs.zig`](src/v7_host/dialogs.zig) and [`src/v7_host/open_url.zig`](src/v7_host/open_url.zig). An unconfirmed call returns `error.ActionNotApproved` before any provider runs.
- `linux.decorations.PointOfRiskApproval` in [`src/v7_host/linux/decorations.zig`](src/v7_host/linux/decorations.zig) covers a server-side move or resize request.
- `capture.Capabilities.requires_user_approval` in [`src/v7_host/capture.zig`](src/v7_host/capture.zig) records whether the platform asks a person; the stream still starts only when the caller asks for it.

`zig build w18-dialog-smoke` refuses its clipboard half unless the run passes
`--authorize-clipboard-mutation`, so a plain run of that step cannot touch what the
operator owns. Native acceptance has been observed on owned private fixtures, and
only there: notifications against a private Dunst instance, and a synthetic
credential round trip, a denial and a provider disconnect against a private Secret
Service. The 2026-10-03 continuation adds an owned private **Wayland** clipboard
round trip and all three real GTK chooser endings, as recorded under
[current Linux closeout evidence](#current-linux-closeout-evidence).

Two present-tense claims are separated because they have different truth values.
Screen capture acceptance **is** still unobserved, but the reason has changed. The
user approved exactly one first capture on 2026-10-03, bounded to one private
Niri/Xvfb `:6` session, one monitor and one stream, 30 frames, a 15 000 ms
post-approval budget, one PPM and a manually chosen source, and that approval has
now been **used**. The latest run at
`/tmp/nogui-w20-private-capture-1RLlCp` started the real private portal backend,
front end and PipeWire daemon, and the consumer really issued `CreateSession` and
`SelectSources` (`types=1`, `multiple=false`, `cursor_mode=2`, `persist_mode=0`).
The chooser witness never appeared inside its 240 000 ms bound, and the run
retired with `begin: state=denied failure=rejected returned=CaptureDenied` and
consumer exit 3. There is no validated stream and no production PPM. Nothing has
been auto-answered: no chooser input was generated by this project, and a second
capture is blocked until the user grants new point-of-risk approval. Under its
separate W21 approval, the latest isolated run at
`/tmp/nogui-w21-approved-2026-10-04T14-09-07-151Z/evidence/result.json`
held real Unicode, empty and restore writes through AT-SPI `SetTextContents`,
including an empty caret at zero and no selection, native keyboard activation,
slider, radio and text movement, and a signed named-action publication the live
model answered. Every owned pid is gone; the normal accessibility setting read
`false` before and after. Full acceptance is still false: that run exited 1 with
18 of 22 required items established and name-plus-state audio still 0/6. That
scope is spent. A fresh W21 private sequence, the W19 locked-store `Unlock` and a
second W20 capture each need their own renewed approval at the time they are
attempted; resuming this work granted none of them.

No existing user credential has ever been read, written or deleted, and no Unlock
prompt has been answered. External URL opening, path reveal, desktop scheme
association and real file-manager drop remain unapproved.

## External consumers

`examples/consumers/*` are separate Zig packages. Each depends on this repository by path, imports only published modules, and copies its font bytes out of the dependency with `addCopyFile`. None of them imports a demo, a smoke or any other repository file.

| Directory | Product | Module imports | Command |
| --- | --- | --- | --- |
| `examples/consumers/core_only` | `core` | `nogui` | `cd examples/consumers/core_only && zig build run` |
| `examples/consumers/text_only` | `text` | `nogui_text` | `cd examples/consumers/text_only && zig build run` |
| `examples/consumers/renderer` | `render` | `nogui`, `v7_render` | `cd examples/consumers/renderer && zig build run` |
| `examples/consumers/test_support` | `core` | `nogui`, `nogui_test` | `cd examples/consumers/test_support && zig build run`, `zig build test` |
| `examples/consumers/host` | `host` | `nogui`, `nogui_host` | `cd examples/consumers/host && zig build run` |
| `examples/consumers/offscreen` | `frame` | `v7_frame`, `nogui`, `v7_render` | `cd examples/consumers/offscreen && env -u DISPLAY -u WAYLAND_DISPLAY zig build run -- /tmp/offscreen.ppm` |

What each one proves:

- `core_only` mounts a component, produces one frame, clicks a widget and observes the change. No window, font, GPU or SDL.
- `text_only` registers a font, reads its metrics and lays out a shaped string twice; the second layout reuses the shape cache and adds no entry. No window and no GPU.
- `renderer` lowers `nogui.paint.PaintList` records to `v7_render` scene records on the CPU. No display, no Vulkan loader, no driver.
- `test_support` drives a real `App` through `nogui_test` with a virtual clock and scripted JSON input, and refuses a stale query handle after a new frame commits. It also has its own `zig build test`.
- `host` selects SDL's `dummy` video driver everywhere except macOS, where attachment needs Cocoa. A real worker updates a model after an idle interval, and the externally driven host wakes, redraws once and shuts down. No GPU is needed. Its own `-Daccesskit-bridge` defaults to `true`, matching this package, so a plain `zig build run` builds and links the W21 bridge and therefore needs the declared Cargo and rustc toolchain; `-Daccesskit-bridge=false` is the Rust-free route, on which the adapter stops building the bridge and keeps reporting `unavailable`. **Both configurations are now observed rather than source-only.** The 2026-10-04 paired run built the declared Rust bridge for real under the default — `accesskit` 0.25, `accesskit_unix` 0.23, `accesskit_atspi_common` 0.20, 5 m 47 s of release build inside a 394.60 s exit-0 invocation — and then ran the consumer, while a separate `-Daccesskit-bridge=false` build invoked no Rust build at all and ran the same way. Both printed exactly `host: OK session_window=1 idle_frames=1 worker_frames=2 wakes=1 target_adapter=ShimUnavailable`, both left five expected SDL `dummy` unsupported/peripheral stderr lines visible rather than suppressing them, and both ran with `DISPLAY` and `WAYLAND_DISPLAY` unset and `DBUS_SESSION_BUS_ADDRESS`/`AT_SPI_BUS_ADDRESS` naming the run's own nonexistent sockets, so no bus, window server or accessibility UI started. `target_adapter=ShimUnavailable` is what keeps this a build-graph and dummy-CLI result rather than a native accessibility claim.
- `offscreen` registers both pinned faces, renders one real windowless GPU frame, and checks every submitted rectangle against the measured run geometry and the read-back pixels against the rectangles those rects claimed. Its build passes the three SPIR-V modules and an optional PPM output path as file arguments.

That consumer also carries three slider captions on one row: an ordinary caption whose only authored text layer is the widget kind's own default foreground, and the same long bytes declared twice, once with `.text_overflow = .ellipsis` and `.max_width = 118` and once with neither. A 2026-10-01 run of `env -u DISPLAY -u WAYLAND_DISPLAY taskset -c 3,4 zig build run -j1 -- /tmp/nogui-offscreen-slider-green.ppm` in `examples/consumers/offscreen` exited 0 on a real NVIDIA GeForce GTX 1660 Ti under Vulkan 1.4 with 930 checks; the inspected 640×400 pixels show `Speaker output volume`, a truncated `Normalization o...`, and the unbounded `Normalization output gain level`. The consumer rebuilds each caption through the public `TextService.nodeLayoutIn` seam and keeps only the scene's glyph quads that land on one of its own pen origins, so no test-only layout export was added to the library. That is a windowless frame read back from a real GPU, not a windowed session. The [GPUI API parity roadmap](docs/superpowers/plans/2026-09-26-gpui-api-parity.md) holds the full per-scenario counts.

The expanded paragraph consumer also passed 1,016 checks on 2026-10-01: `env -u DISPLAY -u WAYLAND_DISPLAY taskset -c 3,4 zig build run -j1 -- /tmp/nogui-w11-paragraph-expanded.ppm`. The inspected 640×640 GPU image includes a centered two-line clamp and start/middle/end truncation with the explicit `~~` suffix. A changed three-line second frame preserves the previous frame's original text records and layout. This remains a windowless result, not native-window or screen-reader acceptance.

The three offscreen arms differ in what they need. `env -u DISPLAY -u WAYLAND_DISPLAY zig build run -- /tmp/offscreen.ppm` is the windowless default: a real GPU target with no window, and its current run passes 1,016 checks. `zig build run -- --empty-font-registry` is CPU-only at 32 checks and opens no GPU, window or surface. `zig build -Dnative=true run-native -- /tmp/offscreen-native.ppm` presents the same specimen into a real window; its last recorded run passed 1,023 checks at 1× with the image inspected. That arm needs an owned display server and GPU, so give it an explicit `DISPLAY` or `WAYLAND_DISPLAY` of its own instead of the desktop this session is using.

All six were also run from a fetched package rather than from this checkout. On
2026-10-03 `zig fetch` resolved `nogui-0.0.0-CnwuaG3HQAKb0ToiHHC8yGLT3hYbbFZ2TdJxNqSYVCbV`,
the archive was extracted into a private root, and every consumer was built and run
from that extraction with its own empty local and global caches verified empty
before its first command and with `DISPLAY`, `WAYLAND_DISPLAY`,
`DBUS_SESSION_BUS_ADDRESS` and `ZIG_GLOBAL_CACHE_DIR` cleared. All six passed:
`core_only: OK`; `text_only: OK width=136.09` with `FontUnavailable` and
`UnknownFont` still distinct; `renderer: OK rects=3 materials=2`;
`test_support: OK checked=true generation=2` plus its own `zig build test`;
`host: OK session_window=1 idle_frames=1 worker_frames=2 wakes=1`; and both
`offscreen` arms, 32 CPU checks then 1,016 windowless GPU checks writing a real
 640×640 image. The extracted tree carries README, both MIT grants and all four
 bundled-font notices, with no undeclared and no missing declared path.

The fetch did not prove a wider "checkout untouched" claim, and that wording is
corrected rather than kept. What the 2026-10-03 run actually checked was two
absences: the generated `src/v7_host/accesskit_bridge/target` tree did not ship
in the package, and the exact checkout path
`zig-pkg/nogui-0.0.0-CnwuaG3HQAKb0ToiHHC8yGLT3hYbbFZ2TdJxNqSYVCbV` was absent.
A read-only re-derivation on 2026-10-04 confirmed the generated bridge target is
present in the checkout and absent from the package, and found the checkout also
carries a `.tmp-6d5594940322ddbf` directory, so the package record does not
establish that nothing in the checkout changed. Evidence:
`/tmp/nogui-w26-provenance-proof.json`.

A current read-only continuation on the same day re-derives those records
without re-running a consumer. Five marker groups re-read the retained logs as
1,016 GPU and 32 CPU checks and refused a missing marker, an unparsable count
and the retained original `marker_missing` refusal exactly as recorded. Four
refusal groups — preexisting root, unsafe root, symlinked parent and version
gate — each refused and left the checkout listing unchanged. The provenance
re-derivation measured 281,031 of 409,600 frame pixels differing from the
`33,36,41` background and bound no compiler file to the 2026-10-03 run, because
all ten of that run's compiler commands name the bare `zig` and none records an
absolute `argv0`. That binding is not recoverable and is not assumed now; the
toolchain on this host today is
`/nix/store/fvlqxywq2p7h2147m0wdp8g0m38zdprp-zig-0.16.0/bin/zig`, which reports
version 0.16.0. The original `report.json`, `completed-report.json` and PPM are
unchanged and no completed consumer was re-run. Evidence:
`/tmp/nogui-w26-offscreen-marker-resumed-20261004.json`,
`/tmp/nogui-w26-refusal-resumed-20261004.json` and
`/tmp/nogui-w26-provenance-resumed-20261004.json`.

That run did not finish in one invocation, and the record says so. The harness
stopped on an incidental wording mismatch in one expectation — it wanted the
literal `refused=error.FontUnavailable` while the consumer correctly printed
`refused=FontUnavailable`. The consumer itself exited 0 and all 32 of its checks
passed; only the controller's incidental marker was wrong. That wording gate was
removed rather than repinned, and a continuation kept every successful cold-cache
command and ran only the remaining GPU arm. The `offscreen` cold-cache guard was
established by the original controller before its own first CPU command, not by the
continuation. No consumer was re-run to present a single clean invocation, and none
was skipped.
Packaging the consumers and running them clean is what is required, and the six
cold-source results are that evidence; one uninterrupted controller invocation is
not, so nothing here is pending a rerun. See the
[W26 plan entry](docs/superpowers/plans/2026-09-26-gpui-api-parity.md#w26--distribution-and-full-acceptance)
for the exact commands, per-consumer exits and retained evidence root.

`examples/parity` holds in-repository parity examples wired into this repository's own build, not external packages:

| Step | Source |
| --- | --- |
| `zig build run-parity-virtual-feed` | [`examples/parity/virtual_feed.zig`](examples/parity/virtual_feed.zig) |
| `zig build run-parity-uniform-feed` | [`examples/parity/uniform_feed.zig`](examples/parity/uniform_feed.zig) |
| `zig build run-parity-query-consumer` | [`examples/parity/query_consumer.zig`](examples/parity/query_consumer.zig) |
| `zig build run-parity-canvas-view` | [`examples/parity/canvas_view.zig`](examples/parity/canvas_view.zig); real windowless GPU image/SVG rendering and stale-asset retirement |
| `zig build run-parity-canvas-view-native -- --ppm PATH` | The same decoded raster/SVG assets in an actual hosted window; pixel probes also verify stale/unbound asset retirement. Needs an owned display and GPU. |
| `zig build run-parity-shared-model` | [`examples/parity/shared_model.zig`](examples/parity/shared_model.zig); compares headless and SDL `dummy` state |
| `zig build run-parity-shared-model-native -- --ppm LEFT.ppm --ppm-right RIGHT.ppm` | The same shared model in two actual `Application`/`NativeFrame` windows; synthetic input, independent focus and retained-mount lifetime. Needs an owned display and GPU. |
| `zig build run-parity-text-field` | [`examples/parity/text_field.zig`](examples/parity/text_field.zig); application-owned editable text with pinned-font shaping, no window |
| `zig build run-parity-text-field-native -- --ppm PATH` | The same pinned-font field presented through the host; synthetic input, matching windowless selection/text geometry and explicit layout-before-renderer teardown. Needs an owned display and GPU. |
| `zig build run-parity-test-context` | [`examples/parity/test_context.zig`](examples/parity/test_context.zig); reusable real-font CPU and windowless GPU contexts |
| `zig build run-parity-menu-overlay` | [`examples/parity/menu_overlay.zig`](examples/parity/menu_overlay.zig) |
| `zig build run-parity-list-live` | [`examples/parity/list_live.zig`](examples/parity/list_live.zig); the default is windowless, `--native` presents |
| `zig build run-parity-state-pair -- --ppm PATH` | [`examples/parity/state_pair.zig`](examples/parity/state_pair.zig); one state scenario on the windowless `v7_frame.Offscreen` route, compared field by field. The step supplies the five shader paths. |
| `zig build run-parity-state-pair-native -- --ppm PATH` | The same scenario and the same comparisons, presented by `v7_frame.NativeFrame` through a real `nogui_host.Application` window. Needs an owned display server and GPU. |

Every parity example except `state_pair` and `test_context` also contributes a test artifact to `zig build test`. All of them contribute a compile to `zig build check`.

`zig build run-parity-menu-overlay -- --native --capture /tmp/menu-overlay.ppm --capture-step closing`
opens the real SDL/noapi specimen and prints bounded requests for its menu, scroll,
tooltip, focus-loss and drag interactions. It requires an owned display and GPU;
the default run remains headless. The 2026-10-02 private-X11 controller run completed
all 15 steps and 98 assertions, presented 86 frames, and retired its auxiliary
window cleanly. Its closing image was inspected, including the full tooltip
description within its background. This is native X11 evidence, not a claim for
every SDL backend or a file-manager drag ingress.

Both state-pair routes exited 0 on 2026-10-02. They compared 64 model, focus, selection, semantic and geometry fields and 12 character pen and advance elements with no mismatch, and both 320×220 GPU images were inspected. The scenario appends `é`, checks the agreement control and compares focus, both selection unit pairs, published semantics and measured geometry; mutating one pen, advance or value rectangle made the comparison exit 1 naming the differing field. Every event is synthetic in both routes, so the presented run shows that the hosted path carries the same transitions, not real IME or external keystrokes. A missing required shader, a missing native blit shader and an unavailable native video backend each return their own error instead of a fallback.

### Current Linux closeout evidence

Every number in this subsection is a dated record of a run, not a claim about the
current tree. Two figures drifted after those runs and are corrected against what is
in the checkout now: the layout golden is **74 rows** (not 581), and the discoverable
Python suite declares **180** test methods (not 126). Neither correction comes from a
re-run; both are read from the committed files. Nothing in this subsection was
re-executed for this revision.

The 2026-10-03 serial `test check fixture layout-check lint` build passed
113/113 steps and 1,912/1,912 tests. All 5,524 fixtures matched, and the layout
golden matched the committed 74 rows; both linters reported zero errors and
warnings across 258 files, which is the file count `zig build lint` enumerates from
`src/v7`, `src/v7_demo`, `src/v7_render`, `src/v7_frame`, `src/v7_text` and
`src/v7_host` today. Formatting passed
for the source/build files and explicitly named first-party examples/manifests,
excluding generated `zig-pkg` dependency copies. That run reported 126 Python
tests passing; the suite now declares 180.
Initial formatter scope/argument failures are retained in the
[W26 record](docs/superpowers/plans/2026-09-26-gpui-api-parity.md#w26--distribution-and-full-acceptance),
not described as one uninterrupted shell pass.

The 2026-10-04 full `direnv exec . gate` passed after three lint corrections.
It completed Debug and ReleaseSafe checks, noapi tests, formatting, lint and Python tooling.
Both linters reported zero errors and warnings across 258 files.
The layout comparison matched the committed 74 rows. That run reported 126 Python
tests passing; the suite now declares 180.
The separately renewed fixture command passed all 5,524 cases, with zero failures or unsupported cases.
The cold-package and native acceptance records below remain separate from this house gate.

A second canonical gate on the same day ran against the landed docs and the
frozen source and exited 0 in 986.08 s. It reached every leg: Debug `test check
layout-check lint`, ReleaseSafe `test check`, the vendored noapi suite with
Tracy off, 126 Python tests in 31.670 s, and the standalone fixture command at
5,524 passed, 0 failed, 0 unsupported over 5/5 steps. Both linters reported
zero errors and zero warnings across 258 files, formatting was checked across
the tree after a narrow pass corrected two files, and the layout golden matched.
The default mobile probe reported its platform unavailable with
no device. The linked W21 headless consumer exited 0 with **38 passed, 0
failed**, including `publish.an_abandoned_stage_changes_nothing` and the
borrowed-text cancel whole-value case, with the native adapter inactive and the
screen reader false. **That run printed no aggregate Zig test count, so none is
restated here and none is carried over from the failed attempt below.**

The first attempt at that same gate failed and is kept as dated evidence: 111 of
113 steps and 1,932 of 1,933 tests, with the only failure the `w23_mobile_smoke`
`PublishedRunIsNotOwned` frame-lifetime test and its ReleaseSafe, noapi, Python
and fixture legs never reached. The repair was behaviour-only and
source-consumer scoped — an obsolete allocator provenance assertion and a dead
`LiveLedger` removed, no production behaviour changed — and the real
`w23-mobile-field-test` target then passed 21/21 steps and 4/4 tests in 5.84 s.
A real mount of `Field`/`Session`/`App`/`annotate` leaves the complete initial
text, caret and generation 1 after a failed publication and grows to
generation 2 on retry. No mobile device is involved and no mobile runtime
acceptance is claimed.

Neither gate is native acceptance. The W21 native evidence is still the
14:09:07 run recorded in [Open findings](#open-findings) with four criteria
unestablished, and the cold-package record above is unchanged.

A real private GNOME Secret Service consumer also proved transport loss during an
unanswered credential read: exactly one `provider_failed/io_error`, zero late
completion, a joined worker, an empty private store and no surviving child.
No write, delete, Unlock, Prompt or existing user credential was involved.

All 66 original audit IDs and 26 packages are reconciled against source and
recorded acceptance. This is not full platform parity. The user approved an
isolated Orca/AT-SPI run, private Wayland checks and the first manual-chooser
capture on 2026-10-03. All three have now executed: the private Wayland W18
clipboard and chooser runs and the isolated Orca/AT-SPI run retired, and the
first manual-chooser capture has **started and spent its single approval** —
the portal call really went out and the run still ended `CaptureDenied` with no
validated stream and no production PPM. Capture acceptance therefore remains
open, and a second capture needs fresh point-of-risk approval.
Locked-store Unlock and external desktop actions remain approval-gated.
Other-target SDK/OS/device runs are unavailable. The user kept embedded-editor
work separate. Neovim adapter requirements remain in that separate plan.
The package hash above identifies the archived proof, not this later
documentation/formatting tree.

#### Renewed private Wayland evidence (2026-10-03, continuation)

The renewed narrow approvals produced real runs on an owned private
Niri/Xvfb `:4` fixture with private buses and private HOME. Every run below
retired its controller, compositor, window manager and Xvfb with zero surviving
owned or unattributed processes.

| Phase | Executable | Verdict | Controller exit | Evidence root |
| --- | --- | --- | ---: | --- |
| `w18-clipboard` | `fe6dcb4cbeb511fdc293d4ef9c88cdbd/w18-dialog-smoke` | `observed`, phase exit 0 | 22 (a later phase in the same wrapper failed) | `/tmp/nogui-w18-approved-wayland-runs/2026-10-03T17-16-05Z/result.json` |
| `w18-dialog-selected` | same | `observed` | 22 (a sibling phase failed) | `/tmp/nogui-w18-approved-wayland-runs/2026-10-03T17-28-56Z/result.json` |
| `w18-dialog-cancelled` | same | `observed` | 22 (a sibling phase failed) | `/tmp/nogui-w18-approved-wayland-runs/2026-10-03T17-35-45Z/result.json` |
| `w18-dialog-parent-closed` | `ebef0947c7df79c5fed45ac22c7aaac4/w18-dialog-smoke` | `observed` | 0 | `/tmp/nogui-w18-approved-wayland-runs/2026-10-03T18-40-35Z/result.json` |
| all three chooser endings, one invocation | same current mapped-parent executable | `observed` × 3 | 0 | `/tmp/nogui-w18-approved-wayland-runs/2026-10-03T18-44-24Z/result.json` |

The exit column is the **whole controller wrapper**, not the named phase. The
first three invocations each bundled several phases, so the wrapper returned `22`
because a *different* phase in the same invocation failed while the named phase
was still `observed` with its own exit 0 and its fixture retired cleanly. The
17-16-05Z case is concrete: the clipboard phase completed its full restore and
retired with zero survivors, and the wrapper then failed on the *next* phase,
which could not resolve an absolute Niri path. The current all-three wrapper
exited 0.

The final row is the confirmation this section needed. Selected, Cancel and
parent-close each returned `observed` against the **current** mapped-parent
executable `ebef0947c7df79c5fed45ac22c7aaac4` in a single run, controller exit 0,
with `/proc` argv readback matching the composed request and zero surviving owned
or unattributed processes. Together with the clipboard arm, the whole newly
approved **private Wayland** subset is now observed against a current executable.

The clipboard arm offered three MIME formats in one item: text, one 1×1 PNG of
exactly 67 bytes and one JSON metadata blob of exactly 37 bytes. Both non-text
formats read back at their exact expected lengths, and the whole item was put
back. PRIMARY was handled as a separate selection whose
`supportsPrimarySelection` read `true`. The independent reader is what makes the
restore trustworthy: `wl-paste --primary` exited 1 with `Nothing is copied` and
zero bytes **both** before and after the run, so the before and after states
agree through a process this run did not control and the restore is independent
rather than self-confirming.

The three chooser endings are three separate observations, not one. Escape is the
backend's own `aborted` result and is deliberately **not** remapped to
cancellation; the actual Cancel mnemonic (Alt+C) is what produced
`outcome=cancelled`. The fixture's driving side was corrected to use the real
mnemonic; no production result enum changed.

The first parent-close attempt on 2026-10-03T17-35-45Z **failed correctly**: no
buffer had been mapped on the SDL parent, so the chooser never appeared and the
controller recorded `no window titled w18 dialog smoke parent appeared on the
owned compositor within 30000 ms`. That is a real refusal, not a pass. After the
noapi mapped-parent fix, the 18:40:35Z run against
`ebef0947c7df79c5fed45ac22c7aaac4` presented a real 320×180 noapi parent buffer,
committed it on `gpu_surface=true`, and the owned compositor's `close-window`
action produced `native parent close observed`, `parent-closed rounds=125
deliveries=1`, `outcome=parent_closed` with `Session.deinit=<accepted>`.

One earlier W18 attempt aborted at process start with an ELF entry point of `0`.
That was a cached **ZLS/tooling placeholder** artifact, not a clipboard or
chooser defect; no production result enum or production source was involved, and
the diagnosis is recorded so the next reader does not mistake it for one.

These runs retire real W18 Linux clipboard/chooser acceptance for this
executable set. They do not widen any other row: W18's macOS Find pasteboard, the
external open/reveal/scheme/drop actions, W19's locked-store Unlock, W20's live
capture, W21's native speech and every other-target runtime were unchanged by
those runs. W21's own approved native run has since executed and retired; its
current limits are in [Open findings](#open-findings).

#### Provider-free capture-fixture fault modes (2026-10-03, continuation)

The W20 private capture fixture's own fault modes were driven with **no provider,
chooser, portal request or frame** involved. Each was red on the earlier fixture
hash `d12f98f470b7` and green after the guard repair on `4efd8bd8f5e5`:

| Fault mode | State | Evidence |
| --- | --- | --- |
| bounded consumer retire | `GREEN`, exit 0 | `/tmp/nogui-w20-fault-green-20261003/consumer-retire-report.json` |
| exited-leader group descendant | `OK`, exit 0 | `/tmp/nogui-w20-fault-green-20261003/group-descendant-report.json` |
| foreign-birth unknown group | `REFUSED`, exit 0 | `/tmp/nogui-w20-fault-green-unknown-v2-20261003/unknown-group-report.json` |
| no-approval consumer | `GREEN`, exit 0 | `/tmp/nogui-w20-fault-green-approval-v3-20261003/consumer-retire-report.json` |

`REFUSED` is the correct green answer for the foreign-birth mode. After the owned
pid, pgid, session and start time were swapped with a stranger, the guard recorded
`group 1513546 is not this run's to signal`, signalled nothing, and the stranger's
own group settled with `zero_surviving_members`. The later-than-15s timing fault
is separate: `/tmp/nogui-w20-approval-wait-proof-1791051478197/result.json` records
a timing protocol arriving at 17.5 s with `childAliveUntilAnswer: true` and no
premature retirement, plus a refusal that ended waiting without granting approval.
It states `nativeProvidersStarted: false`, `captureOccurred: false` and
`realApprovalEstablished: false`.

These are **fixture-harness** faults. They prove the harness refuses to signal a
process it does not own and does not hang; they are not capture evidence, not
permission, and not a substitute for the approved single first capture.

## v7 module

`build.zig` exports these modules:

| Module | Source | Product | Ownership |
| --- | --- | --- | --- |
| `nogui` | `src/v7/root.zig` | `core` | Core layout, components, input state, and two frame arenas. |
| `nogui_text` | `src/v7_text/root.zig` | `text` | CPU FreeType/HarfBuzz measurement and the bounded shape cache. |
| `v7_render` | `src/v7_render/root.zig` | `render` | Batched GPU rendering through `noapi`. |
| `nogui_host` | `src/v7_host/root.zig` | `host` | SDL video/events lifetime, windows, and native event translation. |
| `v7_frame` | `src/v7_frame/root.zig` | `frame` | Reusable scene lowering, GPU text, bindless heap and surface-free rendering/readback. No SDL dependency. |
| `nogui_test` | `src/v7_test/root.zig` | every product | Deterministic Session/App, clock, event replay and stable queries. |

Use `-Dproduct=core`, `text`, `render`, `host`, or `frame` to select a library product. Each includes the core and its own dependencies, keeps the core test, fixture, lint and docs steps, and configures no demo, media or XML artifact. `core` installs the `nogui` static library; `text`, `render`, `host` and `frame` install that product's library beside it. The default, `all`, installs the `nogui` executable and `v7-demo` instead and keeps the demo commands.

`-Daccesskit-bridge` is consulted only for the `host` product. It defaults to `true` in this package and to the same `true` in [`examples/consumers/host/build.zig`](examples/consumers/host/build.zig), so the two graphs no longer hand a consumer that omits the option a different accessibility build. `linked` is `true` only when the flag is set, the target is macOS, Windows or non-Android Linux, and `cargo` is on `PATH`. A build with `-Daccesskit-bridge=false` still compiles the whole accessibility API and reports `State.unavailable`. The 2026-10-04 consumer run exercised both configurations for real — the default built and linked the declared Rust bridge, and `-Daccesskit-bridge=false` invoked no Rust build — and both reported `target_adapter=ShimUnavailable`, so neither run observed a live accessibility adapter.

The bridge pins one AccessKit version per target: `accesskit` 0.25.0,
`accesskit_unix` 0.23.0 with `accesskit_atspi_common` 0.20.0, `accesskit_macos`
0.27.0 and `accesskit_windows` 0.35.0. The earlier locked Rust run passed
19/19 before the public setter callback change. The current parent workspace
run passed 22 SDK tests and 22 bridge tests, including the SDK's `simplified`
feature. It does not prove native screen-reader acceptance.

Run the complete Rust provider gate from the repository root:

```sh
direnv exec . cargo test --workspace --all-features --locked --offline \
  --manifest-path src/v7_host/accesskit_bridge/Cargo.toml
```

Plain `cargo test` selects only the default bridge member. `--workspace`
includes the patched `accesskit_atspi_common` tests; `--all-features` also
compiles its otherwise dormant `simplified` module. The vendored 0.20.0
provider retains `LICENSE-MIT`, `LICENSE-APACHE` and `LICENSE.chromium`.

For an external core-only consumer, request the product on the package dependency:

```zig
const dependency = b.dependency("nogui", .{
    .target = target,
    .optimize = optimize,
    .product = .core,
});
exe.root_module.addImport("nogui", dependency.module("nogui"));
```

The core product does not request SDL3, FreeType, HarfBuzz, libxml2, or FFmpeg. Core frames need no window or GPU initialization.

`nogui_text.TextMeasurer` owns a `TextService` and retained scratch arena over caller-supplied fonts. Initialize it in stable storage and bind `source()` as the core `layout.MeasureSource`; call `deinit` after its last layout pass and all borrowed layouts have been released. `nogui_text.NodeMeasurer` borrows an existing service and scratch arena for graphical hosts. Keep the measurer, service and scratch addresses fixed while the source is bound. `nogui_text.shaping.Cache` owns shaped runs and their pinning leases.

Keep `nogui_host.Application` alive until all its windows are destroyed. The caller drives event polling, frame timing and rendering. Each `Window` owns its SDL window and translates events into core input. Its `sdl` field is borrowed by platform-surface adapters. Scene selection, audio and benchmark policy remain in the demo.

`text_input.Native.set_area` returns `anyerror!void`. `Manager.caretGeometry` propagates publication failures and caches geometry only after success. Candidate rectangles and caret offsets use logical window units.

`Window.setTextInputArea` rejects a non-finite rectangle or offset with `error.InvalidCandidateArea` or `error.InvalidCandidateCursor` before SDL runs, so the last successful publication survives. `Window.candidate_publication` records the rectangle, offset, and wrapping generation after SDL accepts them. Republishing identical geometry advances the generation. Mobile observers adopt this record, not SDL's initial default rectangle. Safe-area or keyboard changes keep candidate geometry stale until a fresh application layout republishes it.

`v7_frame.Offscreen` owns a stable noapi GPU endpoint, bindless heap, Oklab target and readback buffer without creating an SDL window or native surface. Keep its injected loader alive until `Offscreen.deinit`; retire App GPU mounts and text/renderer resources first. `beginFrame` borrows caller-owned command/frame storage until `submitRead` or cancellation. `submitRead` waits for the submitted copy; its Oklab pixel slice expires on the next submission, resize or deinit. `writePpm` converts those pixels to final sRGB bytes.

The external windowless consumer lives in `examples/consumers/offscreen`: run `env -u DISPLAY -u WAYLAND_DISPLAY zig build run -- /tmp/offscreen.ppm` from that directory, or add `-- --empty-font-registry` for the CPU-only refusal arm. Its package README is [`examples/consumers/README.md`](examples/consumers/README.md). Ordinary core/layout consumers still initialize no GPU.

The main `nogui` entrypoints are:

| Export | Purpose |
| --- | --- |
| `App` | Own keyed component/widget identities, input state, frame transactions, and two frame arenas. |
| `Session`, `Model(T)`, `WeakModel(T)` | Own persistent typed values independently of frame arenas and individual App windows. |
| `DrawCtx` | Build the immediate widget tree and enter keyed component scopes. |
| `WidgetTree`, `WidgetNode`, `FrameNodeId`, `WidgetId` | Store one frame of relative geometry; distinguish dense tree indices from stable generational control handles. |
| `ComponentKey`, `ComponentId` | Give components and interactive controls exact keys within their parent component scope. |
| `Style`, `StyleOverride`, `PaintStyle` | Define layout and paint data without a selector cascade. |
| `layout.layoutTree` | Run pure-Zig block, flex, grid, float, and absolute layout. |
| `layout.Options`, `layout.MeasureSource` | Supply an allocator, available size, and optional context-bound host measurement callback. |
| `headless`, `treeToJson`, `FrameOutput` | Drive and inspect the core without a GPU runtime. |
| `GpuEndpoint`, `GpuFrame` | Give component lifecycle hooks scoped access to the graphical backend and recording cancellation. |

The module also exports input, event, callback, geometry, grid-track, overflow, and performance-counter types from `src/v7/root.zig`.

`renderAscii` draws a button's visible caption once: from the generated label child when the control has one, otherwise from the button's own `widget.buttonVisualLabel`, while the semantic name stays in JSON either way. The [API guide](docs/API.md#semantic-names-and-visible-captions) records the rule and its headless evidence.

Components can declare `pub const default_text: nogui.text.TextStyleOverride`.
The declaration applies within their draw scope. Explicit widget text options
and inherited authored fields outrank component defaults field by field.
An authored font family without a handle clears the inherited handle;
a weaker default must not restore it.

### Session and root ownership

Create one `Session` before its Apps, and destroy each App before the Session. `App.init(allocator, &session)` registers one window identity. `mountRoot(T, &view)` binds a caller-owned view once; `replaceRoot` replaces an existing root. Keep the view alive through App shutdown and any readable prior-frame snapshots.

For shared persistent state, move a value into `session.create(T, &value)` and mount it with `app.mountModelRoot(ModelType, ViewType, model, &view)`. The App retains its own strong model ticket; release the caller's ticket only after the last consumer no longer needs it. A second App can mount the same model with a separate view and GPU resources. `Session.deinit` rejects live Apps, models, reservations, or borrows rather than freeing them underneath a consumer.

```zig
var session = try nogui.Session.init(allocator);
defer session.deinit() catch unreachable;
var value: Counter = .{ .count = 0 };
var owner = try session.create(Counter, &value);
defer session.release(Counter, &owner) catch unreachable;
var view: CounterView = .{};
var app = try nogui.App.init(allocator, &session);
defer app.deinit();
try app.mountModelRoot(Counter, CounterView, owner, &view);
_ = try app.frame(1, .{ .width = 800, .height = 600 });
```

`CounterView.draw(self, model: *const Counter, ctx: *nogui.DrawCtx) !void` reads its model only within the draw callback. `Session.read` and `Session.update` likewise expose guarded callback-scoped pointers; do not store them in a view, frame node, effect, or task. A conflicting borrow fails, and callback errors do not undo writes already made. A weak handle cannot upgrade after the last strong owner releases. Cycles must use weak edges; `reserve`/`insert` lets constructors link weak identities without exposing an uninitialized value.

For local frame state, `ctx.state` still makes a shallow copy into the next frame arena: it does not own resources and resets after the component is absent from a committed frame. `ctx.frame_info` supplies tick, time, generation, and surface without a special field on the root view. Model changes invalidate committed readers; W05 adds host wakeup and idle-frame scheduling.

### Notifications and window dependencies

`Context.read(T, model, user, callback)` and `Context.global(T, user, callback)` record a window dependency only when the scoped read succeeds. A successful frame publishes its complete read set; a failed frame keeps the previous set and re-arms consumed redraw demand. `Session.update`, `updateGlobal`, and root replacement invalidate dependent windows. A host checks `takeRedraw(window)` and renders only when needed; repeated invalidations coalesce until consumption.

`Session.observe`, `observeRelease`, `subscribe`, and `observeGlobal` bind weak model owners and return cancellation tokens. `emit(Event, Source, source, &value)`, `deferOwned`, `deferRetained`, and `putGlobal` move their payloads on success; use `deinit(*T, *Session)` for owned members. Effects drain FIFO after the outermost update, after active borrows end, and after frame publication. An event emitted during delivery follows the current event; self-unsubscribe and owner release stop subsequent delivery. `deferRetained` holds a separate strong ticket until its callback or drop. Do not retain borrowed callback pointers or call a Session mutation from draw, measure, prepaint, or paint.

### Custom elements and visibility

`DrawCtx.elementLeaf(T, value, options)` and `DrawCtx.elementContainer(T, value, options)` store a typed payload and optional `T.PhaseState` in the frame arena; borrowed resources must survive both readable trees. `T.measure(*const T, element.MeasureInput)` supplies intrinsic dimensions for min-content, max-content, and definite space, and must be pure. Optional `layout`, `prepaint`, `paint`, and `semantics` hooks run before publication; paint emits bounded rect records through `element.PaintWriter`, not GPU handles. A container with `.late_scope = .query` or `.list` may append a bounded subroot after its first layout; an ordinary hook cannot resize an already laid-out ancestor or build arbitrary siblings. A changed `revision` field invalidates intrinsic measurement identity, and a caller can opt out of measurement caching.

`.visibility = .hidden` retains geometry and scroll extent but suppresses subtree paint, hit targets, focus eligibility, and semantics. `.display = .none` excludes layout geometry as well.

`zig build v7 -- --ruler-smoke --shot /tmp/nogui-ruler.ppm` renders a non-text custom ruler in the Todo scene. Prefix the command with `env -u DISPLAY -u WAYLAND_DISPLAY` for a windowless run: the ruler supplies intrinsic 240×18, then stretches to its parent width, and that run initializes a noapi GPU but no native window.

### Basic widgets

`DrawCtx` offers `checkbox`, `switchControl`, `radio`, `progress`, and `separator` alongside buttons, labels, and sliders. The first three bind to component-owned state; keep those pointers valid while either frame tree can receive input. Radio options share a `*?u32` selection and use distinct `u32` option values. Progress takes a read-only value snapshot.

```zig
const Panel = struct {
    done: bool = false,
    preview: bool = false,
    choice: ?u32 = null,

    pub fn draw(self: *Panel, ctx: *nogui.DrawCtx) !void {
        _ = try ctx.column(.{ .gap = 8 });
        defer ctx.pop();
        _ = try ctx.checkbox(.{ .key = .{ .static = "done" }, .label = "Done", .value = &self.done });
        _ = try ctx.switchControl(.{ .key = .{ .static = "preview" }, .label = "Preview", .value = &self.preview });
        _ = try ctx.radio(.{ .key = .{ .static = "light" }, .label = "Light", .selected = &self.choice, .option = 0 });
        _ = try ctx.radio(.{ .key = .{ .static = "dark" }, .label = "Dark", .selected = &self.choice, .option = 1 });
        _ = try ctx.progress(.{ .label = "Completion", .value = 0.5, .min = 0, .max = 1 });
        _ = try ctx.separator(.{ .axis = .horizontal });
    }
};
```

A slider caption is a real text record, not chrome. `DrawCtx.slider` copies the label into the frame arena, resolves the caption request through the same kind-level default-foreground path every other text-bearing kind uses, and applies the caller's `text_overflow` and `max_width` before its interaction options, so the node's own truncation policy and cap reach both layout and the scene text pass. That kind-level foreground is the slider payload's `color`, opaque white by default, and it is the only layer that gives an unauthored caption a foreground: an ancestor style, a component `default_text`, an authored `.color` or `text_style.foreground` outranks it, and it never shadows an inherited foreground. `widget.sliderVisualLabel` selects the visible bytes: a `visual_label` wins, an empty one suppresses visible text while the semantic `label` stays available to JSON and semantics.

A valid left-button press/release activates a bound control once; pointer-down alone does not activate it. Pointer capture keeps sliders receiving moves and release/cancel outside their box. Focused Enter/Space uses the same activation route. Radio arrow keys select and focus adjacent options in the same group. Progress and separators do not accept input. Headless JSON exposes checked, selected, and progress values. In the windowed Todo demo, the wheel zooms Mandelbrot only when the pointer is inside its visible viewport; keyboard focus alone does not zoom it.

Implementation plans: [GPUI API parity roadmap](docs/superpowers/plans/2026-09-26-gpui-api-parity.md) with its [source-backed capability audit](docs/superpowers/plans/2026-09-26-gpui-api-audit.md), [slug-based localization](docs/superpowers/plans/2026-09-25-drawctx-localization.md), and [code editor with embedded Neovim](docs/superpowers/plans/2026-09-25-code-editor-widget.md). W01–W06 and W08 have closed gates. W07 has two-window, DPI, pointer and minimize/restore evidence on owned private X11 and Wayland sessions. The real IME candidate window is no longer missing: the complete 2026-10-03 private X11/IBus scenario observed and inspected a real candidate measuring 306×65 at (753,951) beside anchor (740,951) at 1×, recorded as T07's own evidence with its log at `/tmp/nogui-w12-current-real-ime-20261003/log/`. A candidate transition at a scale other than 1× **is owed** and carries its own blocked item pending a freshly approved owned fixture; any other-target runtime is a separate requirement under W23. CJK is not part of this limit: rendering a CJK face is the caller's font mechanism, not bundled coverage the library promises, and nothing here opens a new CJK feature scope — only the fixture obligation to register such a face when it needs inspectable glyph pixels. Later packages have implemented portions with acceptance limits recorded in the roadmap. A passing filter alone is not native parity.

### Core invariants

- Each frame builds a fresh `WidgetTree` in one of two frame arenas. Draw, layout, GPU hooks, JSON, and mount publication commit together; failure leaves the last committed tree, focus, state, and scroll limits intact.
- The current tree survives failed attempts. A previous-tree snapshot remains readable only until the next frame attempt resets its arena; it cannot dispatch input after a successful replacement. GPU resources wait for command cancellation and submitted-work completion separately from arena resets.
- Tree storage is postorder. Each container follows all its descendants.
- `WidgetNode.rect` is a border box relative to its parent content box.
- Layout, hit testing, scroll, and text positions use logical window units. SDL events remain fractional window points; the renderer converts device fragments to logical coordinates once. `geometry.PixelScale.init(logical_size, device_size)` names the boundary. Clip buffer layout stays 16 bytes.
- A root rectangle is relative to the logical window surface.
- Components use stable parent-scoped keys. Interactive controls require an explicit `ComponentKey` within that scope; duplicate keys fail the frame. Labels, captions, and localized text are not identity.
- `FrameNodeId` is a dense frame index. `WidgetId` includes owner, slot, and generation; `App.widgetIdForKey(scope, key)` finds a committed control, and `WidgetTree.frameNode(id)` resolves it in the current frame. Removed/replaced handles cannot dispatch to another control.
- Duplicate sibling component identities return an error.
- Layout uses explicit allocators and does not call the renderer or `noapi`.
- The headless path does not create a GPU runtime.
- GPU frame handles are valid only during their component lifecycle call.
- `GpuFrame` hosts must provide recording cancellation and call `finishRecording` after submission. A failed App frame cancels the active recording before releasing staged GPU mounts; cancellation failure fails closed.
- A host that presents through a borrowed native window owns its `noapi.Surface`. Release that surface in `Application.Hooks.on_before_close`, after the App's GPU mounts detach but before the SDL window is destroyed. `on_closed` receives only a stale handle; it is too late to release a swapchain or platform surface. Retire host windows and call `Application.deinit` before `Session.shutdownTasks`, since the host unregisters its task wake callback during deinit. `examples/consumers/host` exercises idle/wake/shutdown without a display.

The former fixed 64-level `DrawCtx` parent stack now grows from the frame arena. The former fixed 10,000-track grid cap is also removed.

These removals do not make storage unbounded. Widget identifiers and indexed storage use `u32`, geometry uses `f32`, and collection sizes use `usize`.

Allocation failure can return `OutOfMemory`. Invalid or unrepresentable layout arithmetic can return `InvalidStyle` or `IndefinitePercentage`.

The GPU clip buffer remains a separate 64-rectangle renderer boundary. Exceeding it returns `ClipCapacityExceeded`.

## API families

The per-family API tables live in [`docs/API.md`](docs/API.md). Each table there names the public entry points a consumer calls, the source that declares them, and the ownership or limit rule that same source states, and together they cover the implemented work packages from W05 through W26.

This README keeps the contracts those tables depend on instead of repeating them: module boundaries in [v7 module](#v7-module), identity and coordinates in [Core invariants](#core-invariants), session and model ownership in [Session and root ownership](#session-and-root-ownership), notifications and globals in [Notifications and window dependencies](#notifications-and-window-dependencies), commands in [Build and run](#build-and-run) and [Work-package smoke steps](#work-package-smoke-steps), the runnable packages in [External consumers](#external-consumers), the caller-supplied approvals in [Point-of-risk actions](#point-of-risk-actions), and the remaining source-level gaps in [Open findings](#open-findings).

There is one guide, not two conventions. `docs/API.md` holds the entry points, ownership rules and stated platform limits; a rule there cites the source that states it, and a rule here is a contract section with its own evidence. Neither file restates the other.

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

The application layout golden is a separate nogui regression artifact. It does not
replace the upstream conformance oracle. The committed golden is
`testdata/layout-golden.json`, **74 rows**; `zig build layout-check` regenerates the
fingerprint from `v7_demo --layout` and compares it byte for byte against that file.
The older 581-row golden is not part of this checkout.

## Vendored `noapi`

`build.zig.zon` resolves `noapi` from `vendor/noapi`. The original sibling workspace is not part of this package dependency.

`vendor/noapi-provenance.json` records the local Jujutsu commit `5a6aec7c2b1b1dafea0e1bd686e4ccc041db75f4` and change ID `plxkynpvunpqwlkqnnlkxlvvnpqvlssy`. Its source repository has no recorded remote.

The manifest selects 92 files from that commit and records 92 upstream entries and 93 current entries. The additional file is the owner-authorized MIT grant. The upstream content digest is `612ae7dfc9f8b1db81a38b1f736e6e01ff54d86ebf5854286ab299f37a08bb56`; the current content digest is `eb49985cd0727119f998e27b48ad08307c7c3f7c1060e41c60b666f3f2f055df`, the value of the manifest's `content_digest` field. Both use the manifest's canonical rule: for each regular file sorted by its UTF-8 relative POSIX path, concatenate the lowercase file SHA-256, two spaces, the path, and one LF, then hash the stream. Symlinks are not permitted.

Eleven of those files retain local patches, and the manifest records the reason for each one:

| Patched file | Local change |
| --- | --- |
| `build.zig`, `build.zig.zon` | Build the vendored tree as an SDL-free library: drop the `sdl3` import, declare `sdl3` lazy, add `-Dlibrary-only`, and register the test step first. |
| `examples/3_3D/main.zig`, `examples/5_indirect_triangles/main.zig`, `examples/common.zig`, `test/main.zig` | Use `drawIndexed` with a buffer-owned index format and create native surfaces through `Surface.initSdl` with one owner. |
| `noapi/CommandBuffer.zig` | Add the `pixel_scale` push constant carrying physical framebuffer pixels per logical window unit. |
| `noapi/Gpu.zig`, `noapi/Queue.zig` | Add `commandsCancel` to discard an unsent offscreen command buffer and reject a cancelled buffer in `copyCommandBufferHandles`. |
| `noapi/Surface.zig` | Add `abortFrame` to discard an active recording, make `initSdl` the sole public surface factory, and release the platform surface exactly once. |
| `noapi/VkBackend.zig` | Track per-window frame recording state, add `abortFrame` and `commandsCancel`, and set the `draw_indirect_bit` destination stage beside `indirect_command_read_bit` for indirect-draw hazards. |

The NVIDIA checkpoint fix, vblank pacing, shared example updates, and upstream test additions match this commit.

The pinned upstream commit contains no root `LICENSE`, `COPYING` or `NOTICE`. On 2026-10-02, Janis Gertulla explicitly authorized MIT licensing for the original `nogui` and `noapi` code. The grants are in [`LICENSE`](LICENSE) and [`vendor/noapi/LICENSE`](vendor/noapi/LICENSE), and both package manifests include them.

Dependency, bundled-font and other third-party licenses remain unchanged; these grants do not relicense third-party work. Integrity digests are separate from permission. The owner-grant prerequisite is resolved, but no stable 1.0 release, release-quality platform layer or performance qualification is claimed by this decision.
The bundled Inter fonts retain the [SIL Open Font License 1.1](src/Inter-LICENSE.txt); DejaVu Sans retains its [upstream notices](src/DejaVu-LICENSE.txt). FiraCode Nerd Font retains the full [Fira Code OFL notice](src/FiraCode-LICENSE.txt) and [Nerd Fonts distribution notice](src/NerdFonts-LICENSE.txt). All four complete notice files are packaged. Their text comes from the [Inter font commit](https://raw.githubusercontent.com/rsms/inter/9221beed3/LICENSE.txt), [DejaVu 2.37](https://raw.githubusercontent.com/dejavu-fonts/dejavu-fonts/version_2_37/LICENSE), [Nerd Fonts FiraCode directory](https://raw.githubusercontent.com/ryanoasis/nerd-fonts/master/patched-fonts/FiraCode/LICENSE) and [Nerd Fonts project notice](https://raw.githubusercontent.com/ryanoasis/nerd-fonts/master/LICENSE), not the original-code MIT grants.

On 2026-10-03 each of those four files was compared byte for byte against its
upstream source, without normalizing line endings or whitespace: all four matched
exactly, at 4,380, 8,816, 4,389 and 6,200 bytes respectively. Evidence:
`/tmp/nogui-font-notice-byte-proof-20261003.json`. The third-party font terms are
therefore reproduced verbatim and none is relicensed.

## Performance protocol

### What this section's evidence is

Every measurement below is a **dated record of a past run**, not a reproducible
check. Two things follow, and both matter when reading these numbers.

**Reproducible in this checkout.** The Taffy oracle and the layout golden are
in-repo and re-runnable: `zig build fixture` re-derives all **5,524** normalized
cases from the 1,381 pinned sources, and `zig build layout-check` re-derives the
fingerprint from `v7_demo --layout` and compares it against
`testdata/layout-golden.json`, **74 rows**. Counts quoted for those two are live.

**Dated history, not reproducible here.** Every frozen-shot pixel comparison, every
`perf stat` count, every flamegraph, and every Tracy capture cited below was stored
outside the repository and **none of those artefacts exist on this machine any
more**. The specific absences are named at each claim. Nothing in this section
asserts that a byte-for-byte shot match can be re-established today, and no such
comparison is part of `gate`. The retained in-repo report is
[`docs/perf/text-shaping-cache-diagnostic.json`](docs/perf/text-shaping-cache-diagnostic.json),
which preserves capture and binary hashes as a record of that measurement.

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

The full matrix was stopped after the user reported throughput near 1 FPS. Seven
complete Todo Debug offscreen blocks were left under
`~/.cache/nogui/perf/stocktake-2026-09-09/baseline/Debug/offscreen/`.
That directory does not exist on this host, so the blocks are gone and the partial
captures do not constitute an accepted baseline.

The pre-cache Tracy block `todo-tracy-offscreen-0001-0002.csv` attributed 847.502
seconds to `shapeForMeasure` across 3,400 frames: 894 calls per frame. These are
inclusive zone totals across warm-up and sample frames, not independent stage sums.
Measurement reshaped every request before the cross-frame cache change below. The
CSV itself is not in this checkout and was not re-derived.

The calibration manifest was written to `~/.cache/nogui/perf/stocktake-2026-09-09/calibration/warmup.json`. That local cache is no longer present on this host. Do not restart the full matrix without revisiting the measurement plan.

### Cross-frame text shaping

`nogui_text.shaping` (`src/v7_text/shape_cache.zig`) owns text and shaped glyph data across frame-arena resets. Demo measurement and rendering share it. Keys compare exact text bytes, immutable font identity, and pixel size. The current shaping settings are fixed LTR/Latin. Layout width and paint are not key fields; wrapping is recomputed from retained clusters and advances.

The cache retains at most 256 runs and 4 MiB of payload, plus fixed bookkeeping. Leases pin active runs against eviction. Oversized runs and fully pinned admission pressure use owned transient runs, without changing the output. Cache hits allocate and shape nothing. Font resources must remain immutable for the cache lifetime.

The user chose short diagnostics instead of restarting the full matrix. Each capture used four warm-up frames and 20 samples, with matching runtime identity and extent:

| Todo Debug offscreen metric | Before | After |
| --- | ---: | ---: |
| Clean CPU median | 199.385 ms | 34.604 ms |
| Mechanism-profile CPU median | 229.197 ms | 30.538 ms |
| HarfBuzz shapes per sampled frame | 928 | 3 |

The three remaining shapes are the changing frame header and two visible toggle
counters. At the time, all ten actual-GPU reference shots compared byte-identical;
the reference images were not kept in this checkout, so that is a dated observation
and not a check that can be repeated. Tests cover mutable input ownership,
released-run reuse, font and size changes, width-dependent wrapping, pinned
lifetimes, payload and entry pressure, and allocation failures.

A separate 100-sample churn check also kept exactly three shapes per frame after the changing labels exceeded the cache entry capacity.

The [diagnostic report](docs/perf/text-shaping-cache-diagnostic.json) preserves capture and binary hashes. The raw files and shots were stored under `~/.cache/nogui/perf/stocktake-2026-09-09/text-cache/`, which is no longer present on this host. This was one short process per profile and version, not a stable repeated-process baseline or a 120 FPS qualification. The full matrix remains deferred.

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

The 5,524 Taffy variants matched, and the layout golden matched the 74-row file
committed at the time. Ten actual-GPU reference shots compared byte-identical; those
shots are not in this checkout, so that comparison cannot be repeated here. The
temporary probes checked 225,792 lookup results and 4,096 measurement keys before
removal.

Raw data, binary hashes, rejection evidence, and `results.json` were stored under
`~/.cache/nogui/perf/stocktake-2026-09-09/hotspot-fixes/spotify-round3/`.
That directory does not exist on this host. These were short diagnostics, not a
120 FPS qualification, and the full matrix remains deferred.

### Flex, cache, ID lookup, and render-path diagnostics

The 2026-09-25 changes reuse resolved flex bounds, prepare measurement-cache hashes once, and skip dense-ID zeroing when every slot is filled. Render commands now borrow paint data, and SVG hover lookup uses the ID index with a scan fallback.

The Debug comparison used frozen binaries, CPU 2, a 954 × 1044 offscreen target, 60 warm-up frames, and 240 sampled frames per process. Tracy, GPU timestamps, and internal counters were off. Each scene ran in A/B/B/A order, where A is the pre-change binary and B is the candidate. Negative changes mean less work for B.

| Scene | Clean CPU median change, pairs 1 / 2 | User-space instruction change, pairs 1 / 2 |
| --- | ---: | ---: |
| Todo | +0.84% / -4.78% | -0.60% / -0.58% |
| Calculator | -0.12% / -2.37% | -0.50% / -0.62% |
| Spotify | -30.55% / -10.04% | -0.79% / -0.79% |

External `perf stat` measured the instruction column in separate A/B/B/A runs. Those counts include startup, warm-up, and shutdown. A keymap event interrupted the first Spotify instruction quartet, so it was discarded and run again. Spotify CPU medians in the valid instruction quartet were *slower* for B in both pairs. CPU timing is unstable; these short runs do not establish a CPU speedup or 120 FPS qualification.

The 5,524 Taffy variants matched, and the layout golden matched the 74-row file
committed at the time. Ten GPU scene shots and a hovered Todo shot matched the
pre-change binary byte for byte; those shots are not in this checkout, so the
comparison is a dated record. The raw traces and count files were written under
`/tmp/nogui-opt-pair-*` and `/tmp/nogui-opt-stat-*`, and neither pattern matches
anything on this host now. They were temporary diagnostic files, not a protocol
baseline.

### Borrowed flex styles

The next profile found repeated copies of the 360-byte `Style` during flex measurement. In ReleaseSafe, 145 of 215 sampled `memcpy` calls had `measureNodeUncached` as their immediate caller. Private flex helpers now borrow `*const Style`. `usedSizeForRequest` copies the style only when a known border size overrides it.

The comparison used the i7-9750H and GTX 1660 Ti at 954 × 1044. Each scene ran one pinned A/B/B/A quartet per mode on CPU 2. Every process used 60 warm-up frames and 240 samples. Both binaries disabled Tracy, GPU timestamps, and internal counters. External `perf stat` measured user-space instructions in separate quartets, including startup and warm-up.

| Scene | Debug instruction reduction, pairs 1 / 2 | ReleaseSafe instruction reduction, pairs 1 / 2 |
| --- | ---: | ---: |
| Todo | 5.72% / 5.74% | 8.58% / 8.62% |
| Calculator | 5.39% / 5.35% | 6.70% / 6.58% |
| Spotify | 6.85% / 6.85% | 12.24% / 12.26% |
| Tiger | 2.96% / 2.97% | 2.85% / 3.00% |
| Strokes | 3.11% / 3.14% | 2.89% / 3.04% |

Clean Spotify CPU medians fell 6.44% and 5.73% in Debug, and 12.25% and 12.99% in ReleaseSafe. The sampled ReleaseSafe `memcpy` share fell from 7.66% to 0.98%. One ReleaseSafe Calculator CPU pair rose 14.66%, but four more pairs fell 9.50% to 11.90%. That spread limits claims about small-scene CPU time.

A separate forced-inline trial cut Debug Spotify instructions by 6.78% against the borrowed-style build. It raised hardware cycles 2.42% to 2.99% and clean CPU medians 0.64% to 4.44%. That trial was reverted.

A separate timestamp-enabled ReleaseSafe run measured Spotify GPU execution at 1.339 ms median and 2.813 ms p99. Its CPU compute median was 6.054 ms. Todo GPU execution was 2.370 ms median, against 2.065 ms CPU compute. These offscreen samples do not include presentation, and this build is not the clean comparison build.

The Debug binaries have SHA-256 hashes `3f4c7f378e3af8a7a8647b041dba07bb3d34a1e0f6296a96c4fedb8f50f34956` and `ccee45eedab0fba38963241b760700085038d479f9a04ec87fe32f876f0c5724`. The ReleaseSafe hashes are `ecd311f3806f9dd654fe240a54cbab763d5ee5295fccd4da487b4600deea847f` and `fce051b1c33dc61222503a61be839ccec6e90c28c62d26239bce80271f25e7cc`. Each pair lists baseline, then candidate.

Ten GPU shots, covering five scenes in normal and reverse order, compared
byte-identical, as did a hovered Todo shot and six clicked Todo frame trees. Those
images and the raw traces under `/tmp/nogui-round2-*` are not present on this host,
so this is a dated record only. These short runs are not the full performance matrix
or a 120 FPS qualification.

### Deep flex measurement rounds

Four rounds on 2026-09-25 tested nine variants around `layout.flex.measureNodeUncached`. Three changes remain:

- `resolveConstraintBounds` returns unbounded results directly when all four min/max dimensions are `auto`. It still validates the aspect ratio.
- `dimensionValue` is inline, which removes call and result-handling overhead.
- Private measurement helpers borrow `*const Request`. Child requests still get separate values when their constraints change.

These changes add no cache or allocation. Public interfaces, cache keys, numeric validation, and runtime-safety settings stay unchanged.

The baseline was rebuilt after FreeType's PNG configuration changed. Both sides use the same dependency configuration. The comparison used CPU 2, the i7-9750H, GTX 1660 Ti, and a 954 × 1044 offscreen target. Tracy, GPU timestamps, and internal counters were off.

Each scene and mode ran two A/B/B/A quartets. Each process used 120 warm-up frames and 480 measured frames. The table compares the median of four per-process `cpu_compute_ns` medians. Negative changes mean less time for the candidate.

| Scene | Debug CPU change | ReleaseSafe CPU change | ReleaseFast CPU change |
| --- | ---: | ---: | ---: |
| Todo | -6.66% | -11.21% | -8.42% |
| Calculator | -2.09% | -9.62% | -7.21% |
| Spotify | -0.98% | -12.23% | -13.60% |
| Tiger | +2.03% | -0.64% | -7.15% |
| Strokes | -1.97% | -9.30% | -4.55% |

Spotify's ReleaseSafe compute time changed from 6.376 ms to 5.596 ms. ReleaseFast changed from 5.286 ms to 4.567 ms. These stage times exclude GPU waits and are not frame intervals or FPS measurements.

Timing remains noisy. Debug Tiger's aggregate increased even though three of four paired comparisons decreased. Some Debug p99 values also increased. These results do not establish a universal latency improvement or a 120 FPS qualification.

Separate `perf stat` quartets used 60 warm-up frames and 240 samples per process. User-space instruction counts include startup, warm-up, and shutdown. The table gives the mean change of the two pairs.

| Scene | Debug instruction change | ReleaseSafe instruction change | ReleaseFast instruction change |
| --- | ---: | ---: | ---: |
| Todo | -5.73% | -11.66% | -11.48% |
| Calculator | -5.26% | -9.54% | -9.00% |
| Spotify | -5.06% | -13.45% | -12.95% |
| Tiger | -3.22% | -4.79% | -4.25% |
| Strokes | -3.19% | -4.80% | -4.28% |

The rejected variants were:

- Reused automatic-minimum bounds by value: faster in Debug, but slower in ReleaseSafe.
- Reused those bounds through a pointer: no repeatable whole-frame gain.
- Forced the container measurement body out of line: slower in ReleaseFast.
- Disabled runtime safety in `measureNodeUncached`: about 0.04% fewer Debug instructions, with no repeatable speedup.
- Forced `finite` inline: faster in Debug, but more instructions and slower timings in optimized builds.
- Aligned recursive measurement results to 16 bytes: no meaningful gain.

`gate` passed, including Debug/ReleaseSafe checks, lint, the layout golden, backend
checks, and 125 Python tests. The separate ReleaseFast suite passed 1,093 tests. All
5,524 Taffy variants passed in Debug and ReleaseFast. The layout golden matched the
74-row file committed at the time. Ten GPU comparisons covered all five scenes in
normal and reverse paint order, with byte-identical images, and a six-frame
checkbox-click and resize replay matched byte for byte in all three modes. The
compared images and replay trees were not committed, so none of that is repeatable
from this checkout.

Frozen binaries, raw traces, counters, image comparisons, and `final-summary.json`
were written under `/tmp/nogui-flex-deep-20260925/`. That directory does not exist on
this host, so the frozen binaries and image comparisons are gone and the numbers
below stand as a dated record. The baseline flex source hash is
`d31de717ae652742313385c0ba887bbf17659fac6bd73d23cb59d9b92cfa4c89`. The retained
source hash is `0d265a4f241d05954a52b3f9a93b901a2d7742f00d23a97123b8867d75bc5875`.

| Mode | Baseline binary SHA-256 | Candidate binary SHA-256 |
| --- | --- | --- |
| Debug | `7a6d1c6b78860aefabb74081e5f4f65dcabcc83f0fb3800af1fb1c4636a72166` | `9f10702a12bf00d041901521f8c0082d6d47afa16a9d8948395fcf49f3072175` |
| ReleaseSafe | `b74ade7d0730c6207ad4cd43eea1b1b0009ece73ceb7c748f916539a5bc97e97` | `7054a59ab47c1cdfc17cafd18ed156ac0e11f20ea1ea4b7fd22ea76873668ed1` |
| ReleaseFast | `c5d507efef5ca8a6f2c2ee7b7b2f5831f350fa781650b06d1401d30ce72aad55` | `c2dfe07b92e5cafd54652643cc80c8c680016a93d2fb7773a31473ef8fa64b2d` |

Final ReleaseFast profiles used `perf record -e cycles:u -F 199 -g --call-graph fp`, CPU 2, 120 warm-up frames, and 2,400 sample frames. All four captures had zero lost samples. The retained binary's sampled user-cycle shares were:

| Symbol | Todo self | Todo inclusive | Spotify self | Spotify inclusive |
| --- | ---: | ---: | ---: | ---: |
| `measureNodeUncached` | 17.85% | 60.21% | 21.12% | 71.16% |
| `measureNode` | 10.50% | 61.93% | 12.27% | 72.83% |
| `measureAutomaticMinimum` | 2.74% | 39.54% | 3.30% | 35.05% |
| `measureTextCached` | 2.93% | 11.44% | 4.19% | 11.13% |
| `resolveConstraintBounds` | 1.84% | 1.84% | 4.27% | 5.37% |

Recursive measurement and automatic-minimum passes remain the main cost. Inclusive shares overlap and must not be added. These profiles include startup and warm-up, not GPU execution time. Inline work stays attributed to callers, so the absence of a separate `dimensionValue` symbol does not mean its work disappeared.

The weighted-cycle flamegraphs were written to `/tmp/nogui-flex-deep-20260925/final-todo.svg`
and `final-spotify.svg`, which are absent; the graphs under `docs/perf/` retain the
earlier capture and are the committed artefacts. `final-profile-summary.json` records
before/after attribution and is likewise absent.

To repeat one clean Spotify run with those frozen binaries, the recorded command was:

```sh
taskset -c 2 /tmp/nogui-flex-deep-20260925/request-ReleaseFast \
  --spotify --perf-mode offscreen --perf-warmup 120 --perf-frames 480 \
  --perf-out /tmp/nogui-flex-deep-20260925/reproduce-spotify.jsonl
```

That command cannot be run as written: `/tmp/nogui-flex-deep-20260925/` does not
exist here, so `request-ReleaseFast` must first be rebuilt from a source tree at the
recorded hash. The invocation is kept as a dated record of how the numbers above
were produced.

For a comparison, use `base-aligned-ReleaseFast` as A and `request-ReleaseFast` as B, with a separate output file per process. Run A/B/B/A twice. Replace the mode suffix for Debug or ReleaseSafe. Omit `--spotify` for Todo, or use `--calculator`, `--tiger`, or `--strokes`. Keep counter and sampling runs separate from clean timing runs.

## Open findings

These are current architecture differences and acceptance limits. The [API guide](docs/API.md) and dated parity plan distinguish source implementation from observed native behavior; a runnable entry point does not close an unrun backend or permission-gated scenario.

- The core module always compiles against `noapi` and `tracy`. [`build.zig`](build.zig) imports both into the `nogui` module for every product, so a `core` consumer's compile graph contains `noapi` even though core frames initialize no GPU and request no Vulkan loader at runtime. The separation is a runtime property, not a compile-graph property.
- The accessibility bell is a **window** call, not a tree call. `Capability.bell` is measured from a bound native window, so it is independent of the AccessKit `State` and of screen-reader activation, and `bell()` answers `rung`, `unsupported`, `provider_failed`, `window_closed` or `wrong_thread` instead of claiming a sound was produced. [`src/v7_host/system_bell.zig`](src/v7_host/system_bell.zig) asks each platform its own way: X11 sends the core `Bell` request at percent 0 through the XCB connection inside SDL's own Xlib display, optional Wayland binds an advertised `xdg_system_bell_v1` on a private event queue, macOS calls `NSBeep` and Windows calls `MessageBeep(MB_OK)`. It rang for real on X11 here (`available=true`, `request=rung`) with the adapter still `inactive` and `screen_reader=false`, and it answered `unsupported` on an owned nested compositor whose registry advertises no bell global. There is no `NSBeep` or `MessageBeep` runtime evidence here and no compositor on this host that advertises the Wayland bell, so no positive Wayland bell proof exists. `Capability.bell` stays `false` on mobile because that host owns its window outside the desktop `Application`. The [API guide](docs/API.md#the-accessibility-bell) states the thread and lifetime contract; the [W21 plan entry](docs/superpowers/plans/2026-09-26-gpui-api-parity.md#w21--semantics-and-native-accessibility) records the runs.
- W19 has a runnable `zig build w19-service-smoke` entry point. Notification replacement, dismissal, actions and provider disconnect have native proof against a private Dunst instance. A private GNOME Secret Service on its own PID-verified bus and per-phase keyring accepted a synthetic write, read-back, delete and confirmed absence, a `denied` refusal with a following `not_found`, and a post-shutdown `provider_failed/disconnected` read. The locked-collection case is still open: its private keyring fixture cannot answer the unlock prompt without a keyring UI agent and explicit interactive approval, so locked reads and item cleanup have no run. Typed wire tests do not replace that proof.
- W20 has a runnable `zig build w20-capture-smoke` entry point. Portal/socket and retained-frame contract tests are not live capture proof. Interactive permission, selected-surface preview, stop and native resource retirement remain open. Neither smoke grants its own external-action approval. What a 2026-10-03 run did settle is the consumer's runtime library: the fixture's `--check-runtime-library` arm exited 0 and spawned nothing, resolving `libpipewire-0.3.so.0` from the PipeWire 1.6.8 store output rather than the operator's `LD_LIBRARY_PATH`, with ELF `SONAME` matching the name the consumer opens, 1,126,128 bytes and SHA-256 `12131ad16fac5d978266c15243b3a307e70e915af404074fb156447fa1c80430`. 14 of 16 declared providers resolved; the chooser and portal front-end each have two installed matches and are selected with `--chooser-bin` and `--portal-bin`, which is a conservative fixture choice rather than missing information. None of this is chooser or capture evidence — the real run still needs `--execute`, the exact approval and a person at the chooser.
  The 2026-10-03 continuation additionally drove the capture fixture's own
  provider-free fault modes to green: bounded consumer retire, exited-leader
  group descendant, foreign-birth unknown group, and the no-approval consumer,
  plus a later-than-15 s timing fault whose protocol arrived at 17.5 s with no
  premature retirement. The foreign-birth mode's green answer is a recorded
  **refusal** to signal a stranger's process group after its identity was
  swapped, with zero surviving members. None of these starts a provider, opens a
  chooser, requests a source or grants permission; they are harness faults, not
  capture. On 2026-10-03 the first manual-chooser capture was approved once —
  one private Niri/Xvfb `:6` viewer window with clipboard sharing disabled, one
  monitor and one stream, 30 frames, a 15 000 ms post-approval budget, one PPM
  and a source a person selects manually — and had not started; the `:6` viewer
  was preparation for that one capture, not new capture authorization.
  *(That state is superseded below: the single approved capture has now run.)*
  Any second capture, any Unlock, any external open/reveal/drop and every other
  OS or SDK remain blocked.
  On 2026-10-04 the first private setup proved X authentication: cookie client
  exit 0, cookieless client exit 1. Niri then exited 101 because the private
  environment could not load `libXcursor.so.1`, before any viewer or capture.
  All seven recorded owners retired and were re-observed absent; the Node
  wrapper still timed out after 600 seconds. Evidence:
  `/tmp/nogui-w20-private-capture-WetkjW/fixture.json`.
  Current provider-free runtime checks resolve all six required compositor SONAMEs.
  A real SONAME-scan refusal now releases all owned directory descriptors.
  The real-child lifecycle smoke drains naturally at Node `beforeExit`, without a forced success exit.
  All 19 safety cases held across 20 fresh module instances, with all instances retired.
  The final audit found no live owners, zombies or unobservable processes.
  Evidence: `/tmp/nogui-w20-runtime-lifecycle-fd-green-20261004/result.json` and
  `/tmp/nogui-w20-viewer-current22-20261004/result.json`.
  Native setup then advanced beyond those provider-free checks. The real backend
  crashed on a null DRM device. The declared provider patch now preserves its
  shared-memory path and reaches readiness with the private Niri compositor.
  The incompatible `weston-color` client required `wp_color_manager_v1`.
  The declared `weston-image` client now paints an owned static image instead.
  Its private compositor screenshot was inspected. Two still witnesses matched.
  Evidence: `/tmp/nogui-w20-private-capture-lUUPJb/fixture.json`.
  All 19 fixture-owned process groups retired completely. The parent viewer
  authenticated but never received a verified compositor window witness.
  It exited 0 after the fixture retired. No viewer acknowledgement, ScreenCast
  request, chooser, stream or captured frame occurred.
  *(Superseded 2026-10-04 below: that attempt started no capture, while the later
  run at `/tmp/nogui-w20-private-capture-1RLlCp` really did issue `CreateSession`
  and `SelectSources`.)*

  **The single approved capture has now run (2026-10-04), and it did not produce
  a stream.** Evidence: `/tmp/nogui-w20-private-capture-1RLlCp/fixture.json`.

  - The first actual `CreateSession`/`SelectSources` in this project's history
    went out on the real private portal: `types=1`, `multiple=false`,
    `cursor_mode=2`, `persist_mode=0`, and the provider advertised exactly those
    cursor modes and source types. The approved single capture's permission was
    spent here and is not available again.
  - The private VNC viewer half was proved for real. The viewer process
    `3764550` with start ticks `30773721` was matched on the private X server:
    niri reported window `295` through relay pid `4315` — an XWayland satellite,
    not the viewer — and `xprop` on XID `0x1400005` returned that exact viewer
    pid, caption and class. The private server `3762235` (start ticks
    `30771058`) and its secure acknowledgement were exact: 108 bytes, mode
    `0600`, uid `1000`, `nlink` 1, carrying this run's own nonce and the same
    server identity. Private `HOME`/`XDG_*`, clipboard off in both directions,
    `-FullScreen=0` and `-RemoteResize=0` were all proved, and the real private
    pixels were inspected and saved. The post-resize still-witness pair was
    equal.
  - The chooser half still failed, and it failed on the harness's own parser
    before that. The chooser's real `slurp` layer-shell trace existed, but the
    old parser rejected libwayland-client's `{Default Queue} ->` prefix, so the
    witness expired at its 240 000 ms bound without being recognised. That
    parser prefix is now fixed, and replaying the actual retained trace through
    it yields shell 5, layer 10, surface 3, output 9, xdg-output 11, winit 1,
    selection 1 and config/ack 201 in order. **That is a replay of a real
    captured trace, not a new live witness; the corrected parser has not been
    run against a fresh chooser.**
  - The run's own outcome is a denial, not a pass: the terminal consumer log
    reads `begin: state=denied failure=rejected returned=CaptureDenied` and
    `verdict: the capture half did not observe a validated stream; exit=3`. No
    stream was validated and **no production PPM was written**. The fixture
    wrapper itself exited 22 after 345.68 s.
  - All 23 owned process groups were observed gone, with no survivors, no
    unresolved ownership, no observation failures, no unsettled reap and no
    open pipes. That much is clean. **The six `invalid_pidfd_reply` refusals are now
    classified in source rather than unexplained, and that classification is not a
    live witness.** The reported cause is ordering: the old caller allowed 2000 ms
    and then sent its own `SIGTERM` before the helper's own 5000 ms budget, and the
    history record agrees — all six helper stdouts were empty and carried `SIGTERM`.
    The collector now declares a 20 s startup contract of 5 + 2. No fresh capture
    produced that explanation and no earlier component proof explains it, so the
    run is source-repaired and classified but still not called clean as a whole.
  - The post-run final retirement outcome and its two follow-on units are **done**. The
    old code produced a verdict carrying no exit status while the consumer's own log
    recorded exit 3, so that run had no final result at all; the source now records the
    exit status instead of dropping it, a named export of that code exists, and a driver
    takes an actual owned child pidfd through the fixture helper. The parent then ran the
    owned-kernel closure at **exit 0 in 17.76 s**, durable JSON at
    `/tmp/nogui-w20-owned-kernel-closure-EhJ1NX/owned-kernel-closure.json` under a mode-700
    root, Node check on the actual fixture and the new proof reporting **782** passing. The
    helper it drove is the exact declared `/tmp/nogui-w20-pidfd-signal.py`, SHA-256
    `b272a192…`, 28,071 bytes, on an explicit Python 3.14.7 pin. Case A pinned an actual
    owned member syscall to its start ticks and sent `TERM`, answering
    `pidfd_helper_complete`; case B got an actual gone-and-reaped kernel refusal and
    confirmed the genuine helper answer was not lost; case C took an actual `TERM`-ignoring
    owned child through the wait boundary, `TERM`, grace and `KILL`, reaped it on a real FD
    and refreshed the consumer's retirement from teardown so `retired-by-this-run` updated,
    with its **exit 22 preserved**. Case C is a standalone process, so **no capture consumer
    and no genuine `Deny` claim comes from it**. No bus, display, Wayland, runtime or audio
    environment was involved and no capture was requested, consumed or renewed; this is
    corrected collector and root-owned-child behaviour, **not native proof**, and the seven
    original W20 full-fixture acceptance items stay blocked.
  - The round trip was already exercised in its first order by the old run itself —
    `after_attempts` 05:59:51.114 and the resumed 05:59:54.478 — and the
    `NULL`-returned control refused correctly. The two scene-control images are
    byte-identical **1280×800** PPMs of 3,072,016 bytes sharing a SHA-256 that
    begins `df4d7d4a` (3,072,016 is the file's byte count, not its size), so
    scene control is proved; the chooser-specific values are `null` because the
    parser was the old one, not because the control failed. That parser is now
    repaired and read back against the recorded trace: it reads 119 protocol
    lines, the chooser's own `zwlr_layer_shell_v1#5.get_layer_surface(new id
    zwlr_layer_surface_v1#10, wl_surface#3, wl_output#9, 3, "selection")`, the
    ordered quartet on that one surface, and the namespace `selection` binds the
    compositor's own live layer list that the old parser left empty. Full native
    acceptance stays pending, and the gate still needs renewed approval and a
    person at the chooser.
  - The earlier viewer/ACK attempts (`WetkjW`, `lUUPJb`) started no capture and
    are retired history. They are not evidence for, or against, this run.
  - No second capture is approved. A further attempt needs renewed
    point-of-risk approval at the time it is made.
- The `-Daccesskit-bridge` default no longer differs between this package and its external consumers. [`build.zig`](build.zig) and [`examples/consumers/host/build.zig`](examples/consumers/host/build.zig) both default the option to `true`, so a consumer that omits it now receives the same accessibility build as the package graph. **That convergence is observed now, not source-only.** The 2026-10-04 paired run in `examples/consumers/host` exited 0 in 394.60 s: the default really compiled and linked the declared Rust bridge (`accesskit` 0.25, `accesskit_unix` 0.23, `accesskit_atspi_common` 0.20, 5 m 47 s of release build) and then ran the consumer, while a separate `-Daccesskit-bridge=false` build invoked no Rust build and ran the same way. Both printed exactly `host: OK session_window=1 idle_frames=1 worker_frames=2 wakes=1 target_adapter=ShimUnavailable`, and both left five expected SDL `dummy` unsupported/peripheral stderr lines visible instead of suppressing them. `DISPLAY` and `WAYLAND_DISPLAY` were unset and `DBUS_SESSION_BUS_ADDRESS`/`AT_SPI_BUS_ADDRESS` named the run's own nonexistent sockets, so no bus, window server or accessibility UI started; `ShimUnavailable` is the honest adapter report and is **not** a native accessibility claim. The 2026-10-03 cold-fetch consumer runs above stay the separate dated record they are. A default build of the `host` product needs the declared Cargo and rustc toolchain on `PATH`; `-Daccesskit-bridge=false` remains the explicit Rust-free, no-native-bridge route in both graphs, and [`examples/consumers/offscreen/build.zig`](examples/consumers/offscreen/build.zig) already passes that value instead of relying on a default.
- Screen-reader acceptance remains open. The **latest** isolated W21 run is
  `/tmp/nogui-w21-approved-2026-10-04T14-09-07-151Z/evidence/result.json`: exit
  1, `full_acceptance: false`, **18 of 22** required items established. Its
  main client exited 0 with zero failures and its named-policy client exited 0
  with **23/23** checks. Both signed named list actions published under their own
  names (`Negative Edge`, `Min Edge`), index 0 was a named action and not a
  click, the source recorded **two named-list activations and zero clicks**, and
  each blocked node offered no `Action` at all, established by enumerating that
  node's own interfaces instead of catching an exception. The typed consumer was
  retired before the reader started, every owner was retired after it, and the
  operator accessibility setting read `false` before and after. Stock Orca 50.2
  handled `Insert+ctrl+Left` as `Left` (113) after 102 ms and presented
  `[progress bar: 'W21 Progress']`; the application model moved nothing, the
  keyboard stayed on `W21 Slider`, and the indicator stayed `focusable=false`
  and was never focused. Four criteria remain unestablished: progress value
  with real audio, progress name through stock object navigation, reader object
  navigation leaving the application untouched, and six-role audio at 0/6.
  Whole-value text writes and keyboard paths still hold against exact model
  counters; native IME composition is still unproved.
- **A full real native stack now produces genuine speech.** Three real-stack runs are on record,
  all on a real Xvfb `:90`, a real session bus, real dconf with `screen_reader_enabled` read back
  true, the real AT-SPI bus and registryd with `ScreenReaderEnabled=true`, a real
  speech-dispatcher with the espeak-ng module and module observer all owned and pinned, real
  Orca 50.2 attached and alive, a real focused window, a real XTEST keyboard, a real AT-SPI
  client, and a real PCM monitor capture on the LIBAO NULL no-hardware backend. The first two,
  `bg355` and `bg357`, exited 1 with no synthesis — the second after the owner-gate repair below.
  The third, `bg367`, ran after that repair **and** the reader-hook restructure, and it is the one
  that speaks: **0 tracebacks, a 372-row reader trace, `spoken_utterances=9`, `synthesized=true`**,
  the evidence gate `ok`, and PCM genuinely read and clock-paced.
  What that run proves about attribution: **50 native utterances, every one lineage `owned`, on
  the real reader thread**; **35 carrying message ids**; **37 distinct `frag_seq`, each with its
  own ACSS**; **100 `reader_text` rows beside 100 `ssip_argument` rows**; **waveform identity
  proved for 9** by exact-once PCM location, with **41 unproved and explicitly not credited**; and
  the wire paired **35/35 with zero unpaired and zero disagreements**.
  Required items that **PASS**: `screen_reader_attached`; `published_roles`; the radio group
  relation and its check marks; the progress value equal to the model value; native actions
  reaching the model; a whole-value multilingual write through the real interface; every keyboard
  path; both settings landing; the terminal owned and registered; and the operator's own
  accessibility setting untouched.
  Required items that **FAIL and are recorded as unclaimed rather than pending**: progress
  announced with real audio; progress name through navigation; reader navigation leaving the
  application untouched, with **0 chords delivered** in that run; and six roles spoken with real
  audio at **4/6**, the button role mismatched and progress unannounced.
- **Reader attached and roles published is not reader announced.** That distinction is the
  load-bearing one here. The nine utterances above are observed with real audio and are claimed;
  everything beyond them is not — not the 41 unproved waveforms, not progress, not the two missing
  roles.
- **Native full acceptance stays 18/22 and is not granted.** The four remaining native items —
  progress name/state binding and progress identity credit — plus two reader dispatch/retirement
  branches, five provenance partials that need native faults or a fragment extension, and five
  Windows/macOS menu items that need a non-Linux runtime, are **blocked with named prerequisites**.
  They are not pending and not reachable.
- **Two real product defects were found by these runs and fixed, each with before/after proof.**
  `correlateSpeech()` read its evidence-owner gate from the 4th positional argument while the
  finalised owner list was passed *inside* the reader-identity object in the 3rd, so the gate
  always received `null`, saw all three required owners missing, and refused to read any PCM or
  credit any utterance **even though finalisation had succeeded**. Fixed by passing the finalised
  list positionally; the re-run flips `evidence_owners.ok` from `false` to `true` with all three
  owners recorded `established=true missing=[]` and 6,646,888 bytes read at `clock_paced=true`.
  The closure-order proof had already shown that gate refusing correctly, so the repair fixes the
  real run's inability to ever *use* it. Separately, the reader dispatch hook **crashed on a
  `None` target**: its guard was gated on `_pending`, which let unbound frames dispatch `None`
  once binding had completed, and the error path itself dereferenced `None`, killing Orca 50.2 at
  startup before any presentation. It is restructured so a still-`None` target always returns,
  verified by zero tracebacks, the 372-row trace and 9 spoken utterances. Both reader proofs
  stayed green through every hook revision.
- **The reader proofs are green against the current helper.** Compatibility **111/111**, verdict
  `proven`, 0 failures; failure proof **226/226**, verdict `proven`, 0 failures. The helper is
  `nogui_reader_origin.py`, **SHA-256** `4ecc9fcf5dfa704c97cfb758b7dad16a8ac0dcf36118f7aa48491bb0953ea271`,
  measured by the parent with `sha256sum /tmp/nogui-w21-reader-origin/nogui_reader_origin.py` and
  reproducible with that exact command. Two earlier digests are prior states only and are not
  current: `b8d38931…` from the cleanup round and `1d0605a4…` from before it.
- **Gates.** That run reported the full Python `unittest` suite passing **175 tests**
  with Ruff clean; the three `tools/test_*.py` files now declare **180** test methods,
  so that figure is dated. Zig lint
  reports **0 errors and 0 warnings across 258 files**; Debug check is **89/89**; ReleaseSafe check
  is green in 133 s with **1959/1959** tests passed. The ReleaseSafe leg became green after a
  concrete fix rather than a lucky rerun: `w23_windows_smoke.zig` shadowed its top-level
  `refusal()` function with a local `refusal` bool, and renaming that local to
  `duplicate_refused` removed the only compile failure. Formatting is clean after touching one
  file. The fixture gate passes **5,524** with 0 failed and 0 unsupported, the layout golden
  matches the committed **74 rows** rather than the 581 quoted in the dated run, the build
  passes **25 of 25** steps, and the vendored noapi tests pass **3/3**
  steps with **66/66** tests. None of these legs was re-executed for this revision.
- **All six external dependency consumers pass** — `core`, `text`, `renderer`, `host`,
  `test_support` and `offscreen`, the last with its CPU arm at 32 checks. That is consumer and
  packaging evidence; it is not native OS evidence.
- **The W21 headless and W19 portable scopes stand as they were.** The current W21 headless source
  passes **42/42** — typed positioned composition, live sequential selection, an 8192-byte storage
  refusal, ring whole-value 4096×2 plus overflow and the exact published state — which is core and
  headless evidence with no native adapter, bus or reader involved. The device-free private W19
  kernel proof passes **28 of 28** with 0 skips, descriptors balanced at 16 → 16 and every private
  owned child gone, and it **earns no native credit**; `NOGUI_W19_CONTROLLER_MAIN=1` refuses with
  exit 2 before any import.
- **W19 keeps two honest unknowns.** The canonical controller source is unchanged at `A71E` with
  every item already fixed in source, but the **native 11 fields and 2 kernel branches remain
  unknown** — source-fixed is not observed — and no UI approval was used. **GCR 3 preparation is
  done and is preparation only:** the inert unlock-plan run is source-ready against real
  providers, the gcr3 41.2 prompter wrapper and two `Exec` service cross-checks, on a private
  `:90` X11 display with a fresh root, but **no child service, GUI, keyring or prompt was started,
  nothing was observed, and no native approval was used**. `Unlock` itself stays blocked on fresh
  consent.
- **The lifecycle closure proof is green:** exit 0, no missing claims, `unexpected_programs` empty,
  no re-signal, zero live owned groups and every owned pid gone. Earlier failed lifecycle attempts
  are prior states, not results.
- **Metadata C is green:** 9 cases, **115 PASS / 0 FAILED / 1 UNEXERCISED**, the single
  unexercised case being the named mid-call symlink swap that needs an in-window adversary. Both
  independent birth references agree exactly and exactly one field is plausible. The `EMFILE` is
  real and kernel-level. The metadata fragment is 7,246 bytes. Root
  `/tmp/nogui-native-metadata-kernel-final-failed-92c0d0c5-1d4c-4f1e-9b6a-63e3f4d3e0ba` — *the
  directory name predates the repair round; the run it holds is the green one.*
- **The reader helper is proved against a real kernel peer.** A `SO_PEERCRED` socketpair reports
  PID 2469773, UID 1000 and GID 100, each matching that process's own `getpid`, `getuid` and
  `getgid`; the socket is unconnected and closed with no peer, and descriptors are balanced at
  8 → 8. A peer-credential mechanism result, not a presentation or audio result.
- **The first-phase native `Action` describe and `TextSelection` steps remain source-complete and
  native-unexercised.** The native unknown and refusal branches have never run: the retained real
  act answered everything and recorded no query refusal. Both stay **blocked** on a fresh approved
  private AT-SPI fault provider or query refusal — not on a refused mock echo, not on a source
  assertion, and not on rerunning the unchanged boundary proof.
- **Cocoa and Windows are source-typed, with no native claim.** Six real `C struct`
  `@property(copy)` errors were reproduced against the real `nogui_macos.h` and corrected at
  source, and the portable GNUstep ARC syntax passes. **Full AppKit SDK, the shim and native Cocoa
  remain unexercised.** Windows source is type-checked, cross-compilation reached link and the
  native ReleaseSafe gate is green; an actual Windows or Cocoa menu run still needs that runtime.
- **The tracker is closed:** 838 items, 751 done and 87 explicitly blocked with a named
  prerequisite, zero open.
- Further W21 and viewer work settled without closing native acceptance. A
  bus-free boundary proof, `/tmp/nogui-w21-native-boundary-resumed-EN3QjV`, is
  green and deliberately narrow: the actual callback exception report, its
  retention, a later callback and the `KeyboardInterrupt` escape. The retained
  `/tmp/nogui-w21-native-boundary-resumed-EN3QjV/boundaries.json` proves only the later
  gate continuation and `KeyboardInterrupt` propagation, and is **explicitly not native `Text`
  or `Selection`**.
  It is not a native RPC refusal either. Root isolation went red then green: the preserved RED
  held 7 of 14 at `/tmp/nogui-w21-root-isolation-pP0ivE/results.json` with a
  stale `RootA` model and stale speech counters in an empty `RootB`, and after
  minimal state resets `/tmp/nogui-w21-root-isolation-Ez2wDA/results.json` holds
  **14/14** in one process and one import — real `RootA` with 16 model keys and
  actual speech counts, then a new empty `RootB` with no old keys, level `null`
  rather than `0`, and every counter at 0. The viewer component is green too:
  `/tmp/nogui-w19-viewer-transport-proof-E2vRoL/actual-results.json` exited 0
  with `passed: true` in 12.77 s and all ten component cases in scope REACHED —
  its own Xvfb with binary Xauthority, the actual 8-byte mode-0600 VNC
  password, its own 127.0.0.1 LISTEN inode with a wrong live PID refused, a real
  RFB handshake accepting 12 against the upstream first 11 same-byte relay
  refused, an exclusive manifest collision with inode and bytes preserved, and
  an absent prompter whose start spawned nothing and left no new children and no
  Gcr. Only the proof's retirement order changed: a handle is retained and its
  known exit taken before any bare PID probe, so an already-exited VNC password
  process was known to be gone and was never probed or signalled. Its three owned
  children all report known exits, Xvfb 0, VNC 0 and x11vnc **1**, with the
  non-zero preserved; relay connections closed, cleanup completed, and the root
  descriptor was retained and then closed. No parent viewer window, no pixels,
  no user acknowledgement, no `Unlock` and no prompt is involved, and there is
  no IPv6 proof. Two earlier reds are preserved rather than rewritten: `aAHBq2`,
  the original API-shape failure, and `SeyT6a`, the real ten-case cleanup
  misclassification.
- Reader log IO is green at 10/10
  (`/tmp/nogui-w21-reader-log-io-proof-2026-10-04T16-23-43-912Z-564174.json`):
  `ENOENT`, `EISDIR` and `EACCES` each answer a typed unknown rather than a
  readable empty result, a failed log explicitly cannot be used to claim a
  `HANDLE` marker, the whole actual 1,477,471-byte Orca log reads with its
  SHA-256 unchanged, and no kernel child was left behind. The causal replay is
  closed again at 16/16
  (`/tmp/nogui-w21-causality-regression-e9bzdo/result.json`) with the raw and
  root index original unchanged. That is the invariant replay, not full native
  acceptance: three native fixes and the causal-ownership design are still
  underway, the 18/22 native result stands immutable, and a fresh private run
  needs renewed approval. The four unestablished criteria stay unestablished
  here, and no regenerated 18/22 result and no native full pass are claimed.
- The earlier run at
  `/tmp/nogui-w21-approved-2026-10-04T04-54-32-795Z/evidence/result.json`
  used private PulseAudio, speech-dispatcher, AT-SPI and Orca on owned `:90`,
  with a private `HOME`. Its native smoke exited 0; its client and complete
  fixture exited 1. All 32 owned pids are gone, with no own survivor and the
  normal accessibility setting `false` before and after. Native keyboard
  button activation (Space and Return), slider keys, radio movement, printable
  text and caret movement all held against real published model counters. The
  capture is clock-paced and real synthesis is proved, but name-plus-state audio
  remains 0/6: the six roles' utterances are recorded while their own capture
  windows never advance, so nothing owns audio and no role is credited.
  Exactly eight non-text client steps failed, and they are not a single vague
  category: `slider:set-value`; `progress:is-read-only-and-cannot-be-driven`
  (the indicator really is `read_only=true`, `focusable=false`, `actions=0x0`,
  and the run never attempted a mutation — this is a bogus gate, not a product
  failure); `list:the-selection-interface-reads-back-what-was-asked`, which
  compared a `selected_count` of 1 and an `index` of 2 as though they were two
  child counts; the absent `Add`/`Remove` named actions; a real SDK bug where a
  disabled node still published `Enabled`/`Sensitive`, which also made the
  `Disabled` gate impossible to satisfy; and `list-add` reactivation after the
  dialog closed. The stock Orca object navigator is the one route that reached
  the read-only indicator: from `W21 Slider` at sibling 7, one
  `Orca+Control+Left` reaches `W21 Progress` at sibling 6, and the reader's own
  log then generated `W21 Progress` and `30 percent.` through its
  `_generate_accessible_label_and_name` and `_generate_progress_bar_value`
  branches. That line is still not credited with audio for the same
  zero-width-attribution reason.
- Native `EditableText.SetTextContents` now has real Unicode, empty and restore
  proof. The platform returned the complete 35-byte/21-character Unicode value
  with caret 21, empty text with caret 0, and the original 11-byte/7-character
  value with caret 7. Each had zero selections and exactly one model write.
  Staging owns the value and character tables for one committed frame; an empty
  value crosses the C ABI as a present empty string, not absent text. The native
  SDK no longer panicked on these writes. `accesskit_unix` 0.23.0 over
  `accesskit_atspi_common` 0.20.0 implements this whole-value route. **That is
  not the composition criterion.** The audit's stricter wording stands:
  positioned native `EditableText` composition through the published semantic
  model is owed, and whole-value writes alone — or an SDL-side IME run — do not
  close it. **The wire facts are now derived from the pinned source rather than
  guessed.** `org.a11y.atspi.EditableText` has six members — `SetTextContents`,
  `InsertText`, `CopyText`, `CutText`, `DeleteText` and `PasteText` — and the
  names an earlier revision recorded here, `insertTextAtPosition` and
  `deleteTextBySelection`, exist on no wire, in no specification and nowhere in
  this repository; that seven-name enumeration was wrong and is withdrawn. The
  pinned adapter wires only `SetTextContents`; the other five answer
  `org.freedesktop.DBus.Error.NotSupported`, so the refusal is a loud D-Bus error
  rather than a silent `false`. Inside one call the wire mixes units:
  `InsertText.position` is a character offset while `InsertText.length` is a
  **byte upper bound** on how much of `text` to insert — not a character count and
  not a delete count. No `EditableText` member carries a spec-mandated caret
  result; that is verified silence in the specification, not an omission here. The
  obstacle sits in the pinned dependencies rather than in this repository, and
  **none of it downgrades the criterion**: positioned composition stays owed, the
  source work comes first, and a fresh native approval follows it.
- The older counts here are dated baselines, not current-tree results. The
  2026-10-03 core `api-w21` run at 41/41, its three-generation public
  App/Publisher progress/radio consumer and the headless W21 smoke at 32/32 are
  **core and source evidence**: none activated a native adapter, reached the a11y
  bus or produced speech. After the public nullable-value setter cutover, the
  linked core `api-w21` passed 90/90 and the headless W21 program passed 38/38.
  The unfiltered mobile model suite passed 4/4, Windows passed 7/7, and both
  portable smoke targets compiled. Mobile proof includes ordinary empty clear,
  character-table edits, failed-frame borrow retention and an overlapping
  whole-value write that previously crashed in memcpy. Windows' non-prefix
  model alias also changed from a real memcpy abort to exact `😀Ωtail`,
  six characters and UTF-16 caret 7, without an extra buffer. W21 preserves an
  aliased whole payload across active-preedit cancellation and a later cancel,
  using a bounded stack copy only for a marked overlapping payload.
  Before the named-action cutover, the Rust bridge suite passed 22/22,
  unlinked `api-w21` passed 93/93 and the linked CLI passed 38/38.
  These dated counts do not establish six-role speech or other-target SDK acceptance.

- The named-action and disabled-state cutover has focused unit and CLI checks,
  and the 14:09 run above now exercises the cutover on a live AT-SPI bus. The bridge C ABI carries
  `nogui_accesskit_custom_action { int32_t id; const char* name; size_t name_len; }`
  on every node, and the host's tree buffer reserves every descriptor slice
  before it hands out a single pointer, so the SDK owns its own copy of each
  name. The locally pinned same-version `accesskit_atspi_common` 0.20.0 patch
  publishes real named actions, keeps index 0 reserved for `click` only when
  the node is genuinely clickable (a custom-only action list starts at index 0),
  returns each action's exact signed id, and publishes a genuinely disabled
  node's real state instead of `Enabled | Sensitive`. The parent reproduced
  the former named-list-owner routing failure (`expected 1, found 0`), then
  verified the corrected Core `api-w21` at **95/95**, the locked all-features
  Rust workspace at **22 SDK + 22 bridge tests**, and the rebuilt linked CLI
  at **38/38**. Those checks cover the source cutover. Live AT-SPI named
  publication has since been exercised — that run's named-policy client passes
  23/23 with two signed named-list activations and zero clicks — while six-role
  owned speech and other-target runtime acceptance remain unestablished.
- The 11:16 run of the same day, kept as dated history, had zero main-client
  failures and established **17/21** required fixture criteria. It is superseded
  by the run above, and its own numbers are:
  write moves 25→60 exactly once; a real Progress write to 75 is acknowledged
  but leaves both readbacks at 60 with zero writes for 15 seconds. Stable
  logical-row selection, hidden Add, disabled Remove and real Unicode/empty
  EditableText writes hold. A separate public consumer performs both signed-ID
  named-list actions with two model activations and no click fallback. The
  native fixture still failed there: its named-policy client had four unreadable
  Action-absence checks and an incorrect two-click expectation; its audio
  parser disagrees with genuine multiline index marks, and the stock reader's
  completion marker arrives too late through buffered file logging. No
  six-role waveform acceptance is claimed. All owners retire and normal
  accessibility stays `false`. Evidence:
  `/tmp/nogui-w21-approved-2026-10-04T11-16-02-453Z/evidence/result.json`.



## Design records

These documents preserve approved design history. Their dated results are historical; the current checks and vendored provenance are recorded above.

- [`docs/superpowers/specs/2026-08-22-v7-canonical-design.md`](docs/superpowers/specs/2026-08-22-v7-canonical-design.md)
- [`docs/superpowers/specs/2026-08-24-taffy-functional-parity-design.md`](docs/superpowers/specs/2026-08-24-taffy-functional-parity-design.md)
- [`docs/superpowers/specs/2026-08-30-debug-120-calibration-threshold-design.md`](docs/superpowers/specs/2026-08-30-debug-120-calibration-threshold-design.md)
