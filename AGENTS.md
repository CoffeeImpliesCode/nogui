# nogui

**Stack**: Zig 0.16 · SDL3 · noapi (Vulkan) · FreeType · Tracy  
**VCS**: jj — DO NOT use git commands  
**Generated**: 2026-07-27

## Overview

Immediate-mode GUI toolkit prototyping on top of `noapi` (Vulkan GPU abstraction). Renders via 9-slice batched quads with an Oklab color pipeline. Currently in throwaway prototype phase — widget system lives in `src/proto/`.

## Structure

```
├── src/
│   ├── root.zig          # Nogui module root — DEAD CODE (placeholder)
│   ├── main.zig          # Minimal test: GPU init + single window + grid shader
│   ├── proto.zig         # Module re-export for prototype subsystem
│   ├── proto_main.zig    # Prototype demo: FreeType font → glyph atlas → GUI
│   ├── glyph_test.zig    # Standalone glyph outline extraction test
│   └── proto/            # Widget system (see src/proto/AGENTS.md)
├── shaders/              # GLSL sources → compiled .spv
├── build.zig             # 4 targets: nogui (exe+mod), proto (exe+mod)
├── build.zig.zon         # Deps: noapi (local), sdl3, freetype, harfbuzz, tracy
└── notes/                # Design notes
```

## Where to Look

| Task | Location |
|------|----------|
| Main app entry | `src/main.zig` or `src/proto_main.zig` |
| Widget system | `src/proto/` |
| GPU initialization | `src/main.zig:42-52` or `src/proto_main.zig:207-216` |
| Build targets | `build.zig:30-88` |
| Shaders | `shaders/*.glsl` → compile via glslangValidator to `.spv` |
| Add dependency | `build.zig.zon:34-54` |

## Conventions (from noapi)

- **Tiger-style**: explicit allocators everywhere, `defer` for cleanup, no hidden allocations
- **Options struct pattern**: every config uses a struct param (e.g. `Gpu.Options`, `SurfaceOptions`, `StyleOpts`)
- **API layering**: proto layer never touches noapi backend directly — goes through `Gpu.*` and `CommandBuffer.*`
- **Frame arena pattern**: per-frame ArenaAllocator, reset each frame — no per-frame GC
- **Oklab color space**: rendering happens in Oklab, blit pass converts to sRGB

## Known Issues

- `src/root.zig` is dead placeholder code — the `nogui` module exports nothing useful
- `Surface.init` calls broken: need `.extent = .{ .width, .height }` wrapper
- `sweeper.zig:deinit` is a no-op — `curve_buf` GPU allocation never freed
- `render_9slice.zig` leaks GPU buffers on every realloc

## Development

- Use `edit` not rewrite for existing files
- Delegate parallel work: N files → N subagents
- Resume task sessions (`task_id`) instead of restarting
- Break tasks small, give subagents full instructions

## Commands

```bash
zig build run       # Build + run main test
zig build proto     # Build + run prototype demo
zig build glyph     # Build + run glyph outline test
zig build test      # Run all tests
ziglint             # Compliance check after every implementation change
```

## Anti-patterns (this project)

- **No direct Vulkan access** — always go through noapi
- **No VkPipeline, render passes, VkShaderModule** — noapi handles these
- **No `usingnamespace`** — removed in Zig 0.16
- **No per-frame malloc** — use frame arena
