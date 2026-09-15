# nogui

Zig 0.16.0 prototype/research for a high-performance immediate-mode GUI toolkit using SDL3, `noapi` (Vulkan), FreeType, HarfBuzz, and Tracy. `src/main.zig` runs a GPU grid test; `src/proto.zig` exports the prototype; `src/proto_main.zig` generates a FreeType atlas and GUI demo. `src/v7/` contains layout and widgets, and `src/v7_demo/` contains demos and stress benchmarks. `shaders/` holds GLSL and SPIR-V. `build.zig` defines targets, and `build.zig.zon` lists dependencies.

## Invariants

- Render 9-slice batched quads in Oklab; convert to sRGB only at the final blit.
- Use `noapi` (`Gpu.*`, `CommandBuffer.*`) for all GPU work. Do not access raw Vulkan handles.
- `App.arenas[2]` keep the previous frame alive for layout diffing and hit-testing while the next frame builds. Do not allocate per frame in hot rendering paths.
- Nodes use CSS-style margin, border, and padding. `node.rect` is a border box relative to the parent content box; obtain screen coordinates with `widget.absoluteRect`.

## Commands

```sh
zig build run        # GPU grid test
zig build v7         # Layout demo
zig build spotify    # Spotify UI stress benchmark
zig build test       # Unit tests
zig build lint       # ziglint + zlint
zig fmt --check .    # Formatting check
gate                 # House gate
```

## Local workflow

Use the repo's direnv/devenv on NixOS; declare dependencies in `devenv.nix`, not through imperative installs. Run `direnv allow` after environment changes or `devenv shell` for a one-off shell. Keep durable architecture and experiment notes in `docs/`. Use `jj st` for status in the colocated jj repo, not raw git.
