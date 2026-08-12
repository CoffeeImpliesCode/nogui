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
- **Always consult your inspirations**: immediate-mode GUI pattern from Dear ImGui + the noapi API — consult both for design questions; match their semantics unless a documented reason says otherwise.

- **Tiger-style**: explicit allocators everywhere, `defer` for cleanup, no hidden allocations
- **Options struct pattern**: every config uses a struct param (e.g. `Gpu.Options`, `SurfaceOptions`, `StyleOpts`)
- **API layering**: proto layer never touches noapi backend directly — goes through `Gpu.*` and `CommandBuffer.*`
- **Frame arena pattern**: two double-buffered per-frame arenas (App.arenas[2]) — frame N builds in one while the previous frame's tree stays alive in the other, enabling id-keyed diffing (dirty flags, retained layout, hitboxes)
- **Box model + RELATIVE layout**: every node carries a CSS-style Box (margin/border/radius/padding); `node.rect` = the BORDER box RELATIVE to the parent's CONTENT box — absolute positions only via `widget.absoluteRect`/`contentRect` (never treat rects as absolute)
- **Oklab color space**: rendering happens in Oklab, blit pass converts to sRGB

## Known Issues

- `src/root.zig` is dead placeholder code — the `nogui` module exports nothing useful
- `Surface.init` calls broken: need `.extent = .{ .width, .height }` wrapper
- `sweeper.zig:deinit` is a no-op — `curve_buf` GPU allocation never freed

## Development

- Use tools, always use `edit` instead of rewriting the file
- Using shell for large edits is unadvised
- **MANDATORY — tools over shell**: file changes go through `edit`/`write` only. NEVER patch files with inline python/perl/sed/awk scripts, heredocs, or `echo >` redirection — this corrupts files and bypasses review. Read with `read`, search with `grep`/`glob`. Shell is for builds/tests and one-shot fact queries only. If an `edit` fails, read and retry with exact text — never fall back to scripting.
- Delegate, Delegate, Delegate
- Be as parallel as possible: 20 files to edit → 20 workers, 8 files touched → 8 workers, 3 research topics → 3 librarians, 5 hard problems → 5 oracles
- Break tasks down, assume subagents are dumb, give full instruction, use many subagents with small tasks each
- Appending task sessions (`task_id`) preserves full context — always prefer resume over restart

## Commands

```bash
zig build run       # Build + run main test
zig build proto     # Build + run prototype demo
zig build glyph     # Build + run glyph outline test
zig build test      # Run all tests
zig build check     # Quick errors only
zig build lint      # House linters: ziglint (enforced rules) + zlint on src/v7 + src/v7_demo
ziglint [paths]     # Style/correctness linter (0.5.3; dirs scanned recursively)
zlint -S            # zlinter 0.16.x — stdin mode: `find src/v7 src/v7_demo -name '*.zig' | zlint -S`
glslangValidator -V shaders/file.vert -o shaders/file_vert.spv  # Compile shader
```

## Validation

- `zig build check` for quick errors
- `zig build` full validation
- `zig build lint` — the gateable lint step. Runs on the ACTIVE tree
  (`src/v7` + `src/v7_demo`) only; `src/proto/*` is prototype debt (see below).
  - ziglint (`~/.local/bin/ziglint`, 0.5.3) with NO ignores — the whole
    tree is ziglint-clean (the systematic cleanup 2026-08-12 fixed the
    proto + standalone findings too). Every rule (incl. Z010/Z011
    deprecations) must be zero.
  - zlint (`~/.local/bin/zlint`, stdin mode only — the dir arg is broken):
    `find src/v7 src/v7_demo -name '*.zig' | zlint -S --deny-warnings` — every
    finding fails the step. Rules: `unsafe-undefined` (a `// SAFETY: <reason>`
    comment must sit DIRECTLY ABOVE each intentional `undefined` — inline
    disables do not work), `avoid-as` → typed annotations, `no-print` →
    `std.log`, `suppressed-errors` → propagate, `unused-decls` → remove.
  - Per-change convention: the linters must be clean on changed files even
    where the step's scope/exclusions don't apply.
- `zbc` (static memory-safety analysis, needs `PATH=~/tools/anyzig/zig-out/bin:$PATH`) — clean except ONE documented `aligncast-on-byte-slice` false positive (drawctx.zig:382 — the arena's type-erased `*anyopaque` record pointer, alignment guaranteed by `arena.create(T)`, unprovable through the erasure; zbc has no suppression). The FreeType 26.6-metric f32-narrowings and the struct-literal/`@intFromFloat`/index-guard findings were all fixed 2026-08-12.
- All linters/analyzers are locally built (~/.local/bin/*, ~/tools/*) and may be patched for this setup; prefer them over nixpkgs versions.
- Lint debt ledger (pre-existing, not gate-blocking; fix as filed work):
  - `src/proto/*`: ~60 zlint findings (unsafe-undefined 13, suppressed-errors 10, no-print 4, unused-decls 11, avoid-as 13) + ziglint style findings — prototype debt, excluded from `zig build lint`
  - `src/v7` + `src/v7_demo`: the ziglint style debt (Z004/Z024/Z020/Z006/Z023/Z030 — 317 findings) + the proto/standalone findings (448) were systematically fixed 2026-08-12; the whole `src/` tree is now ziglint-clean with zero ignores, and zbc has 1 documented false positive
  - `src/app_framework.zig` is an orphan (not in any build target)

## Anti-patterns (this project)

- **No direct Vulkan access** — always go through noapi
- **No VkPipeline, render passes, VkShaderModule** — noapi handles these
- **No `usingnamespace`** — removed in Zig 0.16
- **No per-frame malloc** — use frame arena


## Hardcore quality bar (2026-08)

Applies Tiger Style (loose) + aggressive linting/coverage/verification +
mandatory post-implementation review. Read before coding:
`zig-tiger-style`, `zig-best-practices`, `zig-project`, `zig-linting`,
`zig-coverage`, `zig-testing`, `verification-before-completion`,
`code-review`, `jj-core`, `using-git-worktrees`.

- **Prototype phase**: gates apply to new work; the existing Known
  Issues list is the debt ledger — fix them as filed work, never as
  silent side-effects.

### Gates — definition of done (evidence in the same turn)
- **`gate`** (devenv shell; runs `zig-gate`): run all quality gates in one command — fmt --check, build, test, ast-check, ziglint, zlint (local ~/.local/bin tools); zbc by default (advisory; strict via ZBC_STRICT=1); optional `--cov`; exits 1 on issues.
1. `zig fmt --check .` — zero diffs.
2. `zig build` Debug + ReleaseSafe — exit 0.
3. `zig build test` Debug + ReleaseSafe — all green, zero leaks (`std.testing.allocator`).
4. `zig ast-check` on every changed `.zig`.
5. `test { std.testing.refAllDecls(@This()); }` in each root — unused decls still type-check.
6. Linter — zero errors on changed files: ziglint (enforced rules) + zlint (see Validation; `zig build lint` runs both on the active tree).
7. Coverage (kcov 0.16): every uncovered path is test / refactor / accept-with-written-reason.
8. Optional: `-fsanitize-c=full`, `-fsanitize-thread`, valgrind (`-fvalgrind`).
9. Parser/decoder changes: `zig build test --fuzz=<bounded>` — no crashes, inputs replayed.

Density rule: 12/357 covered paths is noise; 352/357 makes each missing
path a judgment call. Coverage guides, never gates alone.

### Reviewer workflow (mandatory after every implementation)
1. Run the gates; attach raw output (exit codes, counts) — no summaries.
2. Standards: tiger rules + Fowler smells (mysterious names, duplication,
   feature envy, primitive obsession, repeated switches, shotgun surgery,
   speculative generality, message chains, middle man, refused bequest).
   Repo rules override; smells are judgment calls.
3. Spec: re-read the task — missing requirements, scope creep, wrong
   implementations; quote the spec line per finding.
4. Spawn a reviewer subagent for non-trivial diffs; it re-runs gates
   1–3, 6–7 and both axes independently.
5. Fix at root cause; re-run failed gates.
6. Report shape:
   `GATES: fmt=… test=… leaks=… lint=… coverage=… | REVIEW: Standards N | Spec N | FIXED: … | SKIPPED (reason): … | DEBT: (ceiling + trigger)`
   3 failed fix attempts on one file → stop, escalate.

### Clean environment (jj)
- New work starts on a clean change. Dirty? `jj commit -m "wip: ..."`
  (checkpoint) or a fresh change — jj snapshots the working copy, so a
  dirty tree mixes new work with WIP and restore/abandon sweeps both.
- Parallel/risky work: `jj worktree add <path>`; detect existing
  isolation first, never nest. Editing subagents get their own isolated
  worktree/change.
- Baseline tests must pass before the first edit — a red suite is
  provably yours.

### AI-slop guard
- Obvious comments → remove; KEEP why-comments. Over-defensive checks →
  prove redundancy (keep boundary validation). Nesting >3 / god fns
  (>50 lines) / long param lists → restructure. Needless abstraction →
  delete. Dead code (unused decls, `std.debug.print` in non-test) →
  remove. Duplication → extract only shared intent. Missing tests → add
  the narrowest regression test, never remove code. >250 pure LOC
  modules → split by responsibility (never `utils.zig`). Performance
  equivalences → only when provably equivalent; unsure → SKIP. Silent
  skips forbidden; report `N/A` explicitly.
