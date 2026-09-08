# nogui

Zig 0.16.0 · SDL3 · noapi (Vulkan) · FreeType · HarfBuzz · Tracy · `jj`.
This Linux-focused immediate-mode GUI is a research prototype rendered as batched quads.
`src/v7/` is the canonical library, `src/v7_render/` is the renderer, and `src/v7_demo/` contains demos and performance tools.

## Invariants

- Render intermediate colors in Oklab; convert to sRGB in the final blit.
- Use `noapi` (`Gpu.*`, `CommandBuffer.*`) for GPU work. Do not access raw Vulkan handles.
- `App.arenas[2]` keeps the previous frame alive for layout diffing and hit-testing while the next frame builds. Avoid per-frame mallocs in hot rendering paths.
- Nodes use CSS-style margin, border, and padding. `node.rect` is the border box relative to the parent content box. Use `widget.absoluteRect` for screen coordinates.

## Commands

```sh
zig build run
zig build v7
zig build spotify
zig build test
zig build fixture
zig build layout-check
zig build lint
zig fmt --check src build.zig build.zig.zon
python3 -m unittest discover -s tools -p 'test_*.py'
gate
jj st
```

`run` starts the GPU grid test. `v7` starts the layout demo. `spotify` runs the UI stress scene. `fixture` checks the pinned Taffy corpus. `layout-check` compares the headless output with the golden layout. `gate` runs the house checks. Use `jj`, not raw Git.

## Environment and notes

- Declare dependencies, headers, libraries, and tools in `devenv.nix`; do not install them imperatively on NixOS.
- Use direnv/devenv. Run `direnv allow` after environment changes or `devenv shell` for a one-off shell.
- Keep durable architecture and experiment notes under `docs/`.
- Keep private or cross-project agent handoff notes under `~/.agents/agent-notes/`, not in the repository.
