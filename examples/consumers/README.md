# Standalone consumers

These six Zig 0.17.0 packages use only published nogui modules.
Each has its own `build.zig` and this local dependency:

```zig
.dependencies = .{
    .nogui = .{ .path = "../../.." },
},
```

Run `zig build` or `zig build run` from the consumer's directory.
The repository's root build does not include these packages.

| Directory | Product | Example |
| --- | --- | --- |
| `core_only` | `core` | Mount a component, build a headless frame, and click a button. |
| `text_only` | `text` | Register a font, measure text, and reuse a shaped run. |
| `renderer` | `render` | Lower paint records into scene records on the CPU. |
| `host` | `host` | Drive an external event loop and redraw after a worker updates a model. |
| `test_support` | `core` | Replay input with a virtual clock and reject stale queries. |
| `offscreen` | `frame` | Render text and controls to a windowless GPU target. |

The first five need no GPU at runtime. The host selects SDL's `dummy` driver
except on macOS, where window attachment needs Cocoa.
The host enables AccessKit by default and needs Cargo and rustc.
Use `zig build run -Daccesskit-bridge=false` to omit that bridge.

`test_support` also provides `zig build test`.
Use `-Doptimize=safe` or `-Doptimize=fast` for optimized builds.

## Offscreen rendering

The default run needs a Vulkan device but no display server:

```sh
cd offscreen
env -u DISPLAY -u WAYLAND_DISPLAY zig build run -- output.ppm
```

The `run` step supplies the three required SPIR-V shader paths.
Direct execution must supply `quad_vert.spv`, `quad_frag.spv`, and `sort_comp.spv`.
The optional positional output path saves a PPM image.

A CPU-only mode checks missing-font refusal and subsequent font registration:

```sh
zig build run -- --empty-font-registry
```

The native variant presents the same scene through `Application` and `NativeFrame`:

```sh
zig build -Dnative=true run-native -- output.ppm
```

This variant needs a display server and GPU. Its build step supplies two additional blit shaders.
The `--empty-font-registry` and `--native` modes cannot be combined.

The rendered scene checks font fallback, slider captions, paragraph alignment,
line clamping, truncation, and previous-frame layout lifetime.
These checks do not establish native IME or screen-reader support.

## Resources and shutdown

The examples copy font assets through the dependency's build interface.
They do not import demo source files.
Release text-layout leases before the text service or GPU text cache.
Release native surfaces before their platform windows.
See the [API guide](../../docs/API.md) for ownership rules.
