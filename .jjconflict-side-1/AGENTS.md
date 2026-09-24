# nogui

Zig 0.16.0 immediate-mode GUI on SDL3 and `noapi` (Vulkan), with FreeType, HarfBuzz, and Tracy. It renders batched 9-slice quads.

## Invariants

- Render intermediate colors in Oklab. Convert to sRGB in the final blit.
- Access the GPU through `noapi` (`Gpu.*`, `CommandBuffer.*`), not raw Vulkan handles.
- Use `App.arenas[2]`: frame $N$ builds in one arena while frame $N-1$ remains for layout diffing and hit-testing. Avoid per-frame mallocs in hot rendering paths.
- Nodes have CSS-style Box dimensions (margin, border, padding). `node.rect` is the border box relative to the parent content box. Use `widget.absoluteRect` for screen coordinates.

## Repository and commands

`src/main.zig` runs the grid test; `src/proto.zig` exports prototype modules; `src/proto_main.zig` runs the atlas and GUI demo. `src/v7/` holds layout and widgets; `src/v7_demo/` holds demos and stress benchmarks. `shaders/` holds GLSL and SPIR-V.

```bash
zig build run         # grid test
zig build v7          # layout demo
zig build spotify     # Spotify UI stress benchmark
zig build test        # unit tests
zig build lint        # ziglint and zlint
zig fmt --check .     # formatting check
gate                  # house quality gate
jj st                 # status; use jj, not raw git
```

On NixOS, declare dependencies, headers, runtime libraries, and tools in `devenv.nix`, not through imperative installs. Use direnv/devenv; run `direnv allow` after environment changes or `devenv shell` for a one-off shell. Keep durable project design notes under `docs/`.
