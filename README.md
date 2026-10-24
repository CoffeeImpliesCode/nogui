# nogui

A Linux-focused immediate-mode GUI toolkit in Zig. It renders batched quads through
`noapi` and Vulkan, with typed layout, shaped text, keyed widgets, and native services.

Experimental. The API is unstable, and cross-platform runtime support is incomplete.

## Requirements

- Zig 0.17.0 and `pkg-config`.
- For graphics: Vulkan headers, loader, driver, and validation layers.
- For shader compilation: `slangc`. The demos and `check` step require it.
- For the Linux host: Wayland/X11, libxkbcommon, udev, ALSA, libdecor, and libusb.
- For the full demo build: FFmpeg development libraries.
- For native accessibility: Cargo, rustc, and AT-SPI2 on Linux.
- For CPU text: FriBidi and utf8proc development libraries.
- For tooling: Python 3, `ziglint`, and `zlint`.

The package manager supplies SDL3, FreeType, HarfBuzz, and Tracy.
The Vulkan layer lives in `vendor/noapi`.
The Nix environment declares the development dependencies:

```sh
devenv shell
```

Alternatively, use direnv with the supplied `.envrc`.
The host enables the AccessKit bridge by default. Use `-Daccesskit-bridge=false`
to omit the Rust bridge. The accessibility API then reports native support unavailable.

The bridge builds offline. Populate Cargo's cache before the first host build:

```sh
cargo fetch --locked --manifest-path src/v7_host/accesskit_bridge/Cargo.toml
```

## Build and run

Run commands from the repository root:

| Command | Purpose |
| --- | --- |
| `zig build` | Install the minimal application and v7 demo. |
| `zig build run` | Run the minimal GPU application. |
| `zig build v7` | Run the v7 demo. |
| `zig build v7 -- --window` | Open the interactive Todo demo. |
| `zig build spotify` | Run the Spotify stress scene. |
| `zig build calculator` | Run the calculator demo. |
| `zig build check` | Compile targets without running them. |
| `zig build test` | Run the project tests. |
| `zig build test -Dtest-filter=NAME` | Select tests by name. |
| `zig build fixture` | Compare layout with the pinned Taffy corpus. |
| `zig build layout-check` | Compare the demo layout with its golden file. |
| `zig build lint` | Run the source linters. |
| `zig build docs` | Generate API documentation. |

Use `-Doptimize=safe` or `-Doptimize=fast` for optimized builds.
Arguments after `--` pass to the selected executable.
`zig build layout-update` replaces `testdata/layout-golden.json`.
Review that change before keeping it.

The Python tooling has a separate test suite:

```sh
python3 -m unittest discover -s tools -p 'test_*.py'
```

## Use as a dependency

For a local checkout, add this entry to your package's `build.zig.zon`:

```zig
.dependencies = .{
    .nogui = .{ .path = "../nogui" },
},
```

Select a product when you configure the dependency:

```zig
const dependency = b.dependency("nogui", .{
    .target = target,
    .optimize = optimize,
    .product = .core,
});
exe.root_module.addImport("nogui", dependency.module("nogui"));
```

| Product | Modules | Purpose |
| --- | --- | --- |
| `core` | `nogui`, `nogui_test` | Trees, layout, models, input, deterministic tests. |
| `text` | `nogui`, `nogui_text`, `nogui_test` | CPU text measurement and shaping. |
| `render` | `nogui`, `v7_render`, `nogui_test` | Paint lowering and GPU rendering. |
| `host` | `nogui`, `nogui_host`, `nogui_test` | SDL windows and native services. |
| `frame` | `nogui`, `nogui_text`, `v7_render`, `v7_frame`, `nogui_test` | GPU scenes, text, and windowless readback. |

The default product, `all`, includes demos and native examples.
Core frames need no window or GPU initialization, but the compile graph includes `noapi` and Tracy.
See the [standalone consumers](examples/consumers/README.md) for complete packages.

## Reference

- [API guide](docs/API.md): entry points, lifetimes, and native-service limits.
- [Core design](docs/design/architecture.md): identity, frame publication, and GPU lifetime.
- [Layout design](docs/design/layout.md): geometry and fixture provenance.
- [Performance protocol](docs/design/performance.md): measurement profiles and calibration.

`src/v7` contains the core. `src/v7_text`, `src/v7_render`, `src/v7_frame`, and
`src/v7_host` contain the text, renderer, frame, and host modules.
`examples/parity` contains runnable integration examples.

Linux is the primary platform. macOS, Windows, and mobile adapters require their
native SDKs and runtimes. Full screen-reader and screen-capture support remains unqualified.
Native clipboard changes, dialogs, URL launches, credentials, and capture require caller approval.

## License

Original nogui code uses the [MIT license](LICENSE).
Original vendored noapi code uses its [MIT license](vendor/noapi/LICENSE).
Dependency and bundled-font licenses remain separate and unchanged.
The bundled fonts retain the [Inter](src/Inter-LICENSE.txt),
[DejaVu](src/DejaVu-LICENSE.txt), [Fira Code](src/FiraCode-LICENSE.txt), and
[Nerd Fonts](src/NerdFonts-LICENSE.txt) notices.
