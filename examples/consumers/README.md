# External consumers

Six downstream packages. Each one is a standalone Zig package with its own
`build.zig` and `build.zig.zon` that names `nogui` as a `.path` dependency:

```zig
.dependencies = .{
    .nogui = .{ .path = "../../.." },
},
```

None is reachable from the repository's root `build.zig`. None compiles a file
under `src/v7_demo/` or `examples/parity/`. The first five need no runtime assets;
the offscreen `run` step supplies SPIR-V paths from the packaged dependency.

## Commands

Run each command from the consumer's own directory. `zig build` installs the
executable into `<consumer>/zig-out/bin/`; `zig build run` builds and runs it.

| Consumer | Product | Build | Run |
| --- | --- | --- | --- |
| `core_only` | `core` | `cd core_only && zig build` | `cd core_only && zig build run` |
| `text_only` | `text` | `cd text_only && zig build` | `cd text_only && zig build run` |
| `renderer` | `render` | `cd renderer && zig build` | `cd renderer && zig build run` |
| `host` | `host` | `cd host && zig build` | `cd host && zig build run` |
| `test_support` | `core` | `cd test_support && zig build` | `cd test_support && zig build run` |
| `offscreen` | `frame` | `cd offscreen && zig build` | `cd offscreen && zig build run` |

The host consumer enables the AccessKit bridge by default, matching the package
graph, so its default build needs Cargo and rustc. `cd host && zig build run
-Daccesskit-bridge=false` is the explicit Rust-free host path; it does not build
or link the native accessibility bridge.

`test_support` also has a test step:

```sh
cd test_support && zig build test
```

Direct execution, after a build:

```sh
./core_only/zig-out/bin/core_only
./text_only/zig-out/bin/text_only
./renderer/zig-out/bin/renderer
./host/zig-out/bin/host
./test_support/zig-out/bin/test_support
```

The offscreen executable requires three shader paths. Its `run` step supplies
them; direct execution must supply `quad_vert.spv`, `quad_frag.spv` and
`sort_comp.spv` from the same package. `zig build run -- PATH` saves the GPU
image as PPM. `zig build -Dnative=true run-native -- PATH` opts into an owned
native window, and that step supplies the two additional blit shaders, so a
direct native execution needs five. The default graph does not fetch SDL or
create a window, and asking a default build for `--native` is refused by name.

`cd offscreen && zig build run -- --empty-font-registry` is a CPU-only refusal
and recovery arm: no GPU, window or surface, and 32 checks. It proves that an
ordinary caption with no registered face returns `FontUnavailable` without
committing a tree, then measures the same caption through the same App and
service after adding the pinned primary and fallback fonts. It cannot be
combined with `--native`.

The windowless arms need no display server. Prefix them with
`env -u DISPLAY -u WAYLAND_DISPLAY` so an inherited session cannot reach them.
The native arm needs an owned display server and GPU, so give it its own
explicit `DISPLAY` or `WAYLAND_DISPLAY` rather than the session's desktop.

Each program asserts its contract and exits nonzero on a violation. The first
five report the following results; offscreen reports its detailed pixel checks:

```
core_only: OK
text_only: OK width=136.09
renderer: OK rects=3 materials=2
host: OK session_window=… idle_frames=1 worker_frames=2 wakes=1
test_support: OK checked=true generation=2
```

## What each one proves

* **core_only** — mounts a component on a headless `nogui.App`, produces a
  frame, asserts the frame's exact node count and that a button and a label
  exist, clicks the button through `App.handle` with a real pointer down/up
  pair, and asserts the component state changed. Asks for `product = "core"`,
  so SDL, FreeType, HarfBuzz and every demo artifact stay out of the graph.
* **text_only** — registers a font with `nogui_text`, reads its metrics, and
  lays out a shaped string twice. The measured width must be positive, equal
  across both calls, and `shapeCount()` must not grow on the second call,
  which is the shape cache being reused.
* **renderer** — lowers paint records to scene records with `v7_render` on the
  CPU. No window, no GPU, no native display. Asserts the record count, the
  scene-rect and material counts, the material-slot assignment, and that the
  red fill, blue fill and green border each survive lowering with their own
  Oklab colour.
* **host** — drives `nogui_host` `Application` with `.video_driver = "dummy"`
  and a borrowed App. It drains initial SDL events, then checks that 20 idle
  steps produce no extra frame or deadline. A real background worker updates
  the Session model; the host wakes and renders exactly one further frame.
  Ten more idle steps stay idle. It retires the window handle, unregisters
  the host wake callback, and shuts down the task service without a live
  completion or borrowed window.
* **test_support** — drives a deterministic `nogui.App` through
  `nogui_test.Context`: resize, frame, a scripted JSON mouse down/up pair that
  must toggle a checkbox, a virtual-clock advance that must be visible in the
  next frame, and a query handle that must be refused as stale once a newer
  frame commits. The whole script is then replayed against a second context
  with the same seed and must reach the same state.
* **offscreen** — defaults to a real windowless GPU target with no SDL/host
  dependency. It checks ordinary captions, mixed-script pinned-font fallback,
  paragraph alignment/clamp/truncation, and old/current layout lifetime.
  `zig build -Dnative=true run-native -- /tmp/paragraph.ppm` opts into the
  same scene/oracles through a real `Application` and `NativeFrame` at an
  exact 640×640 logical/device extent. The current default run passes 1,016
  checks on the GTX 1660 Ti, and the native arm last passed 1,023 checks at 1×
  with its image inspected. Both return nonzero on a mismatched oracle. These
  are rendered-image checks only: they are not real IME and not screen-reader
  acceptance.

## Notes on the environment

* `ZIG_GLOBAL_CACHE_DIR` is set to the **relative** path `.zig-global-cache`
  by `devenv.nix`. Run from a consumer directory it resolves *there*, so each
  consumer keeps its own artifact cache. If you want the consumers to share the
  repository's compiled artifacts, pass an absolute path:
  `ZIG_GLOBAL_CACHE_DIR=/path/to/nogui/.zig-global-cache zig build run`.
* Each consumer materialises its fetched packages into its own
  `zig-pkg/` directory. Delete `.zig-cache`, `zig-out` and `zig-pkg` to prove a
  cold build.
* The `text` and `host` products pull lazy dependencies (FreeType, HarfBuzz,
  SDL3). The first configure pass records that they are needed, the build
  runner fetches them, and the build script runs again; each `build.zig`
  therefore returns without creating steps when the requested module is not
  materialised yet, rather than aborting.
