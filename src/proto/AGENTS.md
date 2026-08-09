# nogui — proto/widget system

**Status**: PROTOTYPE — throwaway design exploration.

## Overview

Immediate-mode widget system built on noapi GPU rendering. Arena-allocated widget tree with two-phase layout (measure → position). Renders via 9-slice batched quads with Oklab color space. FreeType-based glyph curve extraction for text rendering.

## Files

| File | Responsibility |
|------|----------------|
| `context.zig` | App-global state: Gpu ref, widget state map, frame counter |
| `window.zig` | OS window: SDL3 window, noapi Surface, swapchain, blit shaders |
| `drawctx.zig` | Per-frame drawing context: widget constructors, layout runner |
| `widget.zig` | Widget tree types: Id, Sizing, Size, Rect, Direction, Kind |
| `layout.zig` | Two-phase layout engine: measure (bottom-up) + position (top-down) |
| `render_9slice.zig` | 9-slice batching: CPU vertex expansion, GPU indexed draw |
| `sweeper.zig` | Glyph curve data + GPU material buffer writing |

## Data Flow

```
proto_main.zig
  └── Context.init(gpu)
  └── Window.init(context, ...)        # SDL window + noapi Surface + batch renderer
       └── GlyphSweeper.init(gpu, curves)   # GPU curve buffer
  └── win.run(&gui)
       ├── pollEvents()
       ├── beginFrame()
       │    └── gui.draw(dc)           # User code: builds widget tree in frame arena
       │         ├── dc.column/row(children, opts)
       │         ├── dc.button/label/slider(...)
       │         └── dc.layoutAndRender(root)
       │              ├── layout.measure(root, available)   # bottom-up
       │              └── layout.layout(root, pos, size)    # top-down
       └── endFrame(root)
            └── window.zig: widget tree → Batch9Slice.emitSceneRect → GPU draw
```

## Conventions

- **MANDATORY — tools over shell**: file changes go through `edit`/`write` only. NEVER patch files with inline python/perl/sed/awk scripts, heredocs, or `echo >` redirection — this corrupts files and bypasses review. Read with `read`, search with `grep`/`glob`. Shell is for builds/tests and one-shot fact queries only. If an `edit` fails, read and retry with exact text — never fall back to scripting.
- All widgets allocated into `DrawCtx.allocator` (frame arena) — reset every frame
- `StyleOpts` pattern: shared styling param struct for all widget constructors
- Two-phase layout: measure returns content size, position distributes space
- GPU state set per-pass, not per-widget (minimize driver calls)
- Vertex expansion on CPU: 9-slice → 36 verts + 54 indices per rect

## Anti-patterns

- **No per-widget GPU state**: all rendering is batched
- **No persistent widget tree**: rebuilt from scratch every frame (immediate mode)
- **No text shaping yet**: monospace approximation, HarfBuzz dep exists but unused
- **No event handling**: button/slider don't respond to clicks yet
