# nogui

**Stack**: Zig 0.16.0 · SDL3 · noapi (Vulkan) · FreeType · HarfBuzz · Tracy · `jj` (colocated git)  
**Status**: Prototype / Research — High-performance immediate-mode GUI toolkit

---

## 1. Overview & Directory Structure

`nogui` is an immediate-mode GUI toolkit rendering via 9-slice batched quads with an Oklab color pipeline on top of `noapi`.

```
├── src/
│   ├── main.zig          # Minimal GPU initialization & grid test
│   ├── proto.zig         # Prototype module exports
│   ├── proto_main.zig    # FreeType atlas generation & GUI demo
│   ├── v7/               # Next-generation layout & widget system
│   └── v7_demo/          # Layout demo & stress benchmarks
├── shaders/              # GLSL shader sources and compiled SPIR-V
├── build.zig             # Build targets (nogui, proto, v7, spotify demo)
└── build.zig.zon         # Dependencies (noapi, sdl3, freetype, tracy)
```

---

## 2. Invariants & Conventions

1. **Rendering & Color Pipeline**:
   - All intermediate rendering is performed in **Oklab** color space; final blit converts to sRGB.
   - All GPU interaction goes through `noapi` abstractions (`Gpu.*`, `CommandBuffer.*`). Never access raw Vulkan handles directly.
2. **Memory & Double-Buffered Arenas**:
   - Double-buffered per-frame arenas (`App.arenas[2]`): frame $N$ builds in one arena while frame $N-1$ stays alive for layout diffing and hit-testing.
   - Zero per-frame mallocs in hot rendering paths.
3. **Box Model & Relative Coordinates**:
   - Nodes carry CSS-style Box dimensions (margin, border, padding).
   - `node.rect` is the border box **relative** to parent content box. Absolute screen coordinates are obtained only via explicit conversions (`widget.absoluteRect`).

---

## 3. Commands & Quality Gates

```bash
zig build run                  # Run minimal grid test
zig build v7                   # Run v7 layout demo
zig build spotify              # Run Spotify UI stress benchmark
zig build test                 # Run all unit tests
zig build lint                 # Run project linters (ziglint + zlint)
zig fmt --check .              # Verify formatting
gate                           # Run house gate script
jj st                          # VCS status (NEVER raw git)
```

## NixOS, Development Environment & Shared Notes

- This host runs NixOS. Never install system or development libraries imperatively.
- Declare dependencies, headers, runtime libraries, and tools in `devenv.nix`.
- Use the repository's direnv/devenv environment. Run `direnv allow` after environment changes.
- Use `devenv shell` for a one-off shell.
- Put durable architecture, design, protocol, and experiment notes under `docs/`.
- Put cross-project or private agent handoff notes in `~/.agents/agent-notes/`. Never commit these notes.
