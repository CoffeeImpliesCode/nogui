# nogui

Prototype immediate-mode GUI toolkit using Zig 0.16.0, SDL3, `noapi` (Vulkan), FreeType, HarfBuzz, and Tracy. Rendering uses 9-slice batched quads with an Oklab color pipeline. `src/v7/` contains the layout and widget system; `src/v7_demo/` has its demo and stress benchmarks. `src/proto_main.zig` generates a FreeType atlas and runs the GUI demo. Shaders and compiled SPIR-V are in `shaders/`. `build.zig` defines `run`, `v7`, `spotify`, and test targets.

## Contracts

- Keep intermediate rendering in Oklab and convert to sRGB in the final blit.
- Route all GPU work through `noapi` (`Gpu.*`, `CommandBuffer.*`). Do not use raw Vulkan handles.
- `App.arenas[2]` are per-frame arenas: frame N and frame N-1 remain alive together for layout diffing and hit-testing. Avoid per-frame allocations in hot rendering paths.
- Nodes use CSS-style margin, border, and padding. `node.rect` is the border box relative to the parent content box. Use explicit conversion such as `widget.absoluteRect` for screen coordinates.

## Commands

Run from the repository root:

```bash
zig build run       # Minimal grid test
zig build v7        # v7 layout demo
zig build spotify   # Spotify UI stress benchmark
zig build test      # Unit tests
zig build lint      # ziglint and zlint
zig fmt --check .   # Formatting check
gate                # House gate
jj st               # VCS status
```

Use `jj`, not Git mutation commands. On NixOS, declare dependencies, headers, libraries, and tools in `devenv.nix`; do not install them imperatively. Use the repository's direnv/devenv environment and run `direnv allow` after environment changes. Use `devenv shell` for a one-off shell.
