# nogui

Zig 0.16.0 · SDL3 · noapi (Vulkan) · FreeType · HarfBuzz · Tracy · `jj`.
This prototype is an immediate-mode GUI rendered as 9-slice batched quads.

## Invariants

- Render intermediate colors in Oklab; convert to sRGB in the final blit.
- Use `noapi` (`Gpu.*`, `CommandBuffer.*`) for GPU work. Do not use raw Vulkan handles.
- `App.arenas[2]` keeps frame N-1 alive for layout diffing and hit-testing while frame N builds. Avoid per-frame mallocs in hot rendering paths.
- Nodes use CSS-style margin, border, and padding. `node.rect` is the border box relative to the parent content box. Use explicit conversion, such as `widget.absoluteRect`, for screen coordinates.

## Commands

```bash
zig build run
zig build v7
zig build spotify
zig build test
zig build lint
zig fmt --check .
gate
jj st
```

`run` starts the minimal grid test. `v7` starts the layout demo. `spotify` starts the UI stress benchmark. `test` runs unit tests. `lint` runs ziglint and zlint. `gate` runs the house checks. Use `jj`, not raw Git.

## Environment

- Declare dependencies, headers, libraries, and tools in `devenv.nix`; do not install them imperatively on NixOS.
- Use direnv/devenv. Run `direnv allow` after environment changes or `devenv shell` for a one-off shell.
