# Taffy Functional Layout Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development`. Each task uses test-first development, a fresh implementer, a task-scoped review, and an isolated Jujutsu commit.

**Goal:** Replace v7’s partial bespoke layout engine with a modular pure-Zig implementation that passes every enabled Taffy v0.13.0 fixture variant while preserving nogui’s WidgetTree, frame arenas, and relative border-box geometry.

**Architecture:** `src/v7/style.zig` becomes the only public layout value model. `src/v7/layout/` owns resolution and algorithms over a borrowed WidgetTree adapter; it allocates all dynamic per-frame state from the current frame arena and writes parent-content-relative border boxes plus scroll overflow back to nodes. A pinned, checked-in upstream fixture corpus creates the conformance oracle; normal Zig tests never need Rust or network access.

**Tech Stack:** Zig 0.16, `std.json`, existing double-buffered `std.heap.ArenaAllocator`, SDL3/noapi host, Taffy v0.13.0 fixture corpus, Python 3 stdlib only for maintenance import tooling.

## Global Constraints

- Target upstream revision: `DioxusLabs/taffy@45a56299d366ddb383e593a1f0372158d00e8530` (`v0.13.0`).
- Test every enabled upstream Block, BlockFlex, BlockGrid, Flex, Float, Grid, GridFlex, and Leaf fixture in LTR/RTL and border-box/content-box variants.
- Exclude only upstream-unimplemented table layout, vertical writing modes, named grid-track placement, and full grid baseline alignment.
- Do not add Rust, C, or network dependencies to normal build/test paths.
- `WidgetNode.rect` stays a border box relative to the parent content box; root coordinates are relative to the surface.
- Layout must not call renderer/noapi code.
- Dynamic layout state uses the current frame arena; no hard child, line, placement, or grid-track limit remains.
- GPU clip limits stay in rendering and are not layout limits.
- Migrate every caller before removing `src/v7/flex.zig`; no compatibility aliases or legacy style mirrors remain after cutover.
- Every production change follows RED → verified RED → GREEN → verified GREEN.
- Every task runs its focused test after implementation. The orchestrator runs format, AST, build, full tests, lint, and ReleaseSafe gates at phase boundaries.

---

### Task 1: Pin and run the upstream fixture oracle

**Files:**
- Create: `tools/import_taffy_v013_fixtures.py`
- Create: `testdata/taffy-v0.13.0/MANIFEST.json`
- Create: `testdata/taffy-v0.13.0/normalized/cases.json`
- Create: `src/v7/layout/fixture.zig`
- Modify: `src/v7/root.zig`

**Interfaces:**
- Produces `fixture.runAll(allocator: std.mem.Allocator, filter: ?[]const u8) !FixtureSummary`.
- Produces one normalized case record with `source`, `source_sha256`, `variant`, `rounding`, `viewport`, `nodes`, and `expected` arrays in pre-order.
- Consumes only checked-in `cases.json` and `MANIFEST.json` during normal tests.

- [ ] **Step 1: Write the failing manifest and one-case runner test**

Add a test in `fixture.zig` that reads a one-case normalized corpus and asserts:

```zig
const summary = try runAll(std.testing.allocator, "leaf/leaf_001");
try std.testing.expectEqual(@as(usize, 1), summary.passed);
try std.testing.expectEqual(@as(usize, 0), summary.failed);
```

The initial test must fail because `runAll` and the normalized corpus do not exist.

- [ ] **Step 2: Verify RED**

Run:

```bash
zig build test -- --test-filter "Taffy fixture runner"
```

Expected: compile failure naming the missing runner or fixture corpus.

- [ ] **Step 3: Implement the deterministic importer and format**

Implement a Python-stdlib maintenance command:

```text
python3 tools/import_taffy_v013_fixtures.py \
  --source <pinned-taffy-checkout> \
  --out testdata/taffy-v0.13.0
```

The importer must:

1. reject a source checkout whose `HEAD` is not the pinned commit;
2. walk source fixture paths in bytewise sorted order;
3. skip `_scratch` path components, names beginning `x`, and non-HTML files;
4. emit four variants for each enabled fixture: `border_box/ltr`, `border_box/rtl`, `content_box/ltr`, `content_box/rtl`;
5. preserve Taffy XML input tree, text, writing-mode, viewport, rounding, expected x/y/width/height, and optional scroll widths/heights;
6. emit SHA-256 for every source file and a manifest case count;
7. fail if a duplicate `(source, variant)` key appears.

`fixture.zig` parses the JSON with `std.json`, builds a temporary test tree, runs the current layout adapter hook, and reports an upstream source path on mismatch. Start with the one pinned leaf case; later tasks enable the complete corpus.

- [ ] **Step 4: Verify GREEN**

Run the filtered test again. Expected: the one normalized leaf case passes.

- [ ] **Step 5: Commit**

```bash
jj commit -m "test(layout): pin Taffy v0.13 fixture oracle"
```

---

### Task 2: Establish canonical Taffy-compatible style values

**Files:**
- Modify: `src/v7/style.zig`
- Modify: `src/v7/widget.zig`
- Modify: `src/v7/root.zig`
- Create: `src/v7/layout/values.zig`

**Interfaces:**
- Produces `Display{ block, flow_root, flex, grid, none }`, `Direction{ ltr, rtl }`, `Float`, `Clear`, `Overflow{ visible, clip, scroll, auto }`, and typed alignment distribution values.
- Produces a non-allocating `Calc` expression and `resolveLengthPercentage(...)` error union.
- Produces `LayoutError{ InvalidStyle, IndefinitePercentage, UnsupportedNamedTrackPlacement }` as the layout error boundary.
- Removes duplicated legacy semantic fields only after Tasks 8–9 migrate their callers.

- [ ] **Step 1: Write failing value-resolution tests**

Add tests proving:

```zig
try testing.expectEqual(@as(f32, 35), try calc(.add(.length(20), .percent(0.15))).resolve(100));
try testing.expectEqual(Display.none, Style{ .display = .none }.display);
try testing.expectError(error.IndefinitePercentage, calc(.percent(0.5)).resolve(null));
```

Also test RTL direction, Auto overflow, Float/Clear defaults, safe/unsafe alignment values, and rejection of non-finite input.

- [ ] **Step 2: Verify RED**

Run the exact value test filter. Expected: symbols or behavior are absent.

- [ ] **Step 3: Implement canonical typed values**

Add tagged unions and enum variants. `Calc` must be a bounded expression tree supplied by caller-owned storage; it must not allocate. Preserve explicit `Dimension`, `LengthPercentage`, `LengthPercentageAuto`, `Insets`, and grid types, but remove the need to synchronize separate legacy and typed values once callers are migrated.

- [ ] **Step 4: Verify GREEN**

Run the value test filter. Expected: all style-resolution tests pass under `std.testing.allocator` with no leak.

- [ ] **Step 5: Commit**

```bash
jj commit -m "feat(layout): add canonical Taffy style values"
```

---

### Task 3: Replace fixed tree and scratch limits with arena-owned layout state

**Files:**
- Modify: `src/v7/widget.zig`
- Modify: `src/v7/drawctx.zig`
- Modify: `src/v7/app.zig`
- Create: `src/v7/layout/root.zig`
- Create: `src/v7/layout/geometry.zig`

**Interfaces:**
- Produces `layout.LayoutOptions{ allocator, available, measure }` and `layout.layoutTree(tree: *WidgetTree, options: LayoutOptions) LayoutError!void`.
- `WidgetNode.children` becomes an arena-owned `[]Id`; DrawCtx appends children without a fixed cap.
- `geometry.zig` owns relative placement, absolute conversion inputs, and scroll overflow writeback.

- [ ] **Step 1: Write failing capacity and geometry tests**

Add tests that build 33 siblings and more than 1,024 grid-placement candidates from an arena, then assert successful construction and layout. Add a test that confirms the root and nested child retain parent-content-relative border boxes after `layoutTree` returns.

- [ ] **Step 2: Verify RED**

Run the new capacity/relative-geometry filters. Expected: current child or placement limits reject the test.

- [ ] **Step 3: Implement arena-backed tree and root adapter**

Make `DrawCtx.create` copy child and layout records into `ctx.arena`. `App.present` passes its active frame allocator to `LayoutOptions`; previous-tree lifetime must remain intact through the double-buffer protocol. `layoutTree` owns only temporary arena slices and writes `rect`, resolved values, and `ScrollState.max_offset` back to nodes.

- [ ] **Step 4: Verify GREEN**

Run the focused capacity/relative-geometry tests. Expected: no fixed-cap error and correct relative/absolute results.

- [ ] **Step 5: Commit**

```bash
jj commit -m "refactor(layout): use frame-arena tree and scratch storage"
```

---

### Task 4: Implement shared sizing and leaf measurement

**Files:**
- Create: `src/v7/layout/sizing.zig`
- Modify: `src/v7/layout/values.zig`
- Modify: `src/v7/layout/root.zig`
- Modify: `src/v7/widget.zig`

**Interfaces:**
- Produces `AvailableSpace{ definite: f32, min_content, max_content }`.
- Produces pure sizing functions for content, padding, border, margin, min/max, aspect ratio, and replaced/leaf measurement.
- Consumes the existing `MeasureFn`: `*const fn ([]const u8, u32, u8) widget.Size`.

- [ ] **Step 1: Write failing sizing tests**

Cover definite and indefinite percentages, min-content/max-content, content-box versus border-box, min/max precedence, aspect-ratio-derived axis, and a measured leaf receiving the available width.

- [ ] **Step 2: Verify RED**

Run the sizing test filter. Expected: at least one typed sizing result differs from the desired contract.

- [ ] **Step 3: Implement sizing resolution**

Move `measureLeaf`, typed dimension resolution, and box-model arithmetic out of `flex.zig`. Resolution must return `LayoutError` for invalid values, avoid non-finite geometry, and round only at the fixture/output boundary.

- [ ] **Step 4: Verify GREEN**

Run the sizing tests. Expected: exact expected border/content size and no extra allocations beyond supplied arena.

- [ ] **Step 5: Commit**

```bash
jj commit -m "feat(layout): add shared intrinsic sizing core"
```

---

### Task 5: Implement Block, FlowRoot, Float, Clear, None, and absolute layout

**Files:**
- Create: `src/v7/layout/block_float.zig`
- Modify: `src/v7/layout/root.zig`
- Modify: `src/v7/layout/geometry.zig`
- Modify: `src/v7/taffy_block_conformance.zig`
- Modify: `src/v7/layout/fixture.zig`

**Interfaces:**
- Produces `block_float.layoutContainer(...) LayoutError!void`.
- Consumes shared sizing/geometry and arena scratch from `LayoutOptions`.
- Enables fixture groups `block`, `blockflex`, `blockgrid`, `float`, and `leaf` as each behavior becomes green.

- [ ] **Step 1: Write failing Block/Float behavior tests**

Add targeted cases for FlowRoot float containment, left/right float placement, Clear, hidden subtree zero layout, relative inset offset, absolute opposing insets, auto margins, scroll overflow, and RTL block direction.

- [ ] **Step 2: Verify RED**

Run the Block/Float filter. Expected: failure because current code lacks FlowRoot, Float/Clear, None, and RTL behavior.

- [ ] **Step 3: Implement the algorithm**

Implement normal-flow block stacking, float exclusion regions, clear advancement, FlowRoot boundary reset, hidden-subtree handling, absolute containing blocks, and scroll-overflow accumulation. Reuse `sizing.zig`; do not copy `flex.zig` legacy block helpers.

- [ ] **Step 4: Enable and verify fixture groups**

Run filtered normalized cases for every Block/Float/Leaf group and direct nogui relative-box tests. Expected: zero mismatches for enabled cases in those groups.

- [ ] **Step 5: Commit**

```bash
jj commit -m "feat(layout): implement block flow and floats"
```

---

### Task 6: Implement complete Flexbox layout

**Files:**
- Create: `src/v7/layout/flex.zig`
- Modify: `src/v7/layout/root.zig`
- Modify: `src/v7/layout/sizing.zig`
- Modify: `src/v7/taffy_flex_conformance.zig`
- Modify: `src/v7/layout/fixture.zig`

**Interfaces:**
- Produces `flex.layoutContainer(...) LayoutError!void`.
- Uses frame-arena slices for items, lines, freeze state, auto margins, and cross-axis records.
- Supports Flex direction, RTL, reverse directions, wrap, wrap-reverse, balance, basis, grow, shrink, gaps, min/max freeze, auto margins, align-self/items/content, justify-content, and intrinsic sizing.

- [ ] **Step 1: Write failing line-resolution tests**

Add tests for min/max freeze after grow and shrink, all justify distributions, multi-line align-content, wrap-reverse in RTL, auto margins before distribution, percentage basis under definite/indefinite parents, and balanced line count.

- [ ] **Step 2: Verify RED**

Run the Flex filter. Expected: current partial advanced/legacy paths fail at least one new behavior.

- [ ] **Step 3: Implement a single complete flex sequence**

Implement item collection, flex-base/hypothetical-size resolution, line formation, freeze/distribute loops, auto-margin consumption, cross-size resolution, line alignment, main-axis placement, cross-axis placement, and overflow output. Do not retain `needsAdvancedFlex`, `finalizeMainLegacy`, or the repeated five-pass legacy protocol.

- [ ] **Step 4: Enable and verify the full Flex fixture group**

Run all normalized Flex cases plus existing direct flex tests. Expected: zero fixture mismatches and preserved relative geometry.

- [ ] **Step 5: Commit**

```bash
jj commit -m "feat(layout): implement complete flexbox resolution"
```

---

### Task 7: Implement complete CSS Grid layout

**Files:**
- Create: `src/v7/layout/grid.zig`
- Modify: `src/v7/layout/root.zig`
- Modify: `src/v7/style.zig`
- Modify: `src/v7/taffy_grid_conformance.zig`
- Modify: `src/v7/layout/fixture.zig`

**Interfaces:**
- Produces `grid.layoutContainer(...) LayoutError!void`.
- Supports explicit/implicit tracks, fixed/percent/auto/min-content/max-content/fr/minmax sizing, areas, spans, auto flow/dense placement, gaps, RTL, content/item/self alignment, and scroll overflow.
- Returns `error.UnsupportedNamedTrackPlacement` only for the upstream-unimplemented named-track-placement forms.

- [ ] **Step 1: Write failing grid tests**

Add tests for area placement, negative/line/span placement, implicit expansion in both axes, row/column dense flow, intrinsic track sizing, fr distribution after fixed/minmax tracks, RTL column placement, all item/self/content alignment distributions, and absolute grid descendants.

- [ ] **Step 2: Verify RED**

Run the Grid filter. Expected: partial current grid behavior fails the new cases.

- [ ] **Step 3: Implement placement and track sizing**

Implement explicit grid construction, occupancy via arena-backed bitsets or spans, definite-placement pass, auto-placement pass, intrinsic contribution collection, track base/growth-limit resolution, fr distribution, area placement, and alignment. The algorithm must not use fixed `[32]` arrays or a hard placement-attempt budget.

- [ ] **Step 4: Enable and verify Grid fixture groups**

Run every normalized Grid, GridFlex, and BlockGrid case. Expected: zero enabled-group mismatches; named-track unsupported inputs report the documented error.

- [ ] **Step 5: Commit**

```bash
jj commit -m "feat(layout): implement CSS grid parity"
```

---

### Task 8: Cut production and headless callers to the replacement core

**Files:**
- Modify: `src/v7/app.zig`
- Modify: `src/v7/drawctx.zig`
- Modify: `src/v7/headless.zig`
- Modify: `src/v7/input.zig`
- Modify: `src/v7/event.zig`

**Interfaces:**
- `App.present` calls `layout.layoutTree` once after tree construction and before GPU hooks/FrameOutput publication.
- DrawCtx constructors write only canonical `Style` values and arena-owned construction data.
- Headless JSON, fingerprints, ASCII, hit testing, slider input, scroll events, and draw collection retain the existing relative/visual geometry contract.

- [ ] **Step 1: Write failing integration tests**

Add a headless frame test that draws nested flow-root/flex/grid content, handles an event, and asserts the same FrameOutput tree supports `hitTest`, `contentRect`, `absoluteRect`, `visualBorderRect`, scroll limits, and JSON serialization.

- [ ] **Step 2: Verify RED**

Run the integration filter. Expected: old `flex.layoutWith` path or legacy style fields prevent the new feature tree from compiling or behaving correctly.

- [ ] **Step 3: Migrate production boundaries**

Replace all `flex.layout`/`layoutWith` calls. Convert `styleFromOpts`, `setButtonLabelSizing`, and `seedSharedColumnStyle` to canonical values. Copy shared track data out of stack-local Spotify records into `ctx.arena` before it can be observed by layout. Preserve App’s double-buffer lifetime and noapi ordering.

- [ ] **Step 4: Verify GREEN**

Run focused App, DrawCtx, Headless, Input, and Event tests. Expected: all old output consumers use correct geometry from the new core.

- [ ] **Step 5: Commit**

```bash
jj commit -m "refactor(layout): cut app and headless paths to layout core"
```

---

### Task 9: Migrate every demo and Spotify style caller

**Files:**
- Modify: `src/v7_demo/ui.zig`
- Modify: `src/v7_demo/spotify.zig`
- Modify: `src/v7_demo/spotify_sidebar.zig`
- Modify: `src/v7_demo/spotify_content.zig`
- Modify: `src/v7_demo/spotify_player.zig`

**Interfaces:**
- All component defaults and local overrides use canonical Style fields.
- Spotify workspace tracks and shared columns are frame-arena-owned or replaced by canonical grid/flex declarations.
- No demo reads legacy `basis`, `min_main`, `grow`, `shrink`, or fixed child-limit fields.

- [ ] **Step 1: Write failing demo regression tests**

Add direct tests for Todo badge alignment, text width clipping, Spotify desktop/medium/compact shell geometry, player seek bounds, album-label width, and shared-column alignment using canonical styles only.

- [ ] **Step 2: Verify RED**

Run the new demo filters. Expected: compilation or geometry failure until constructors no longer depend on legacy fields.

- [ ] **Step 3: Migrate construction code**

Replace legacy flex and grid option literals in all active demo roots and child modules. Preserve colors, paint, callbacks, texture slots, layer ordering, clips, and semantic labels. Convert any stack-lived layout record retained by a node into arena-owned data.

- [ ] **Step 4: Verify GREEN**

Run the Todo and Spotify focused suites plus `zig build layout-check`. Expected: all demo layout contracts pass.

- [ ] **Step 5: Commit**

```bash
jj commit -m "refactor(demo): migrate callers to canonical layout styles"
```

---

### Task 10: Remove the legacy engine and prove the clean cutover

**Files:**
- Delete: `src/v7/flex.zig`
- Modify: `src/v7/root.zig`
- Modify: `src/v7/widget.zig`
- Modify: `src/v7/style.zig`
- Modify: `build.zig`

**Interfaces:**
- `nogui.layout` exports the replacement module.
- No reachable source imports `flex.zig`, calls `layoutWith`, or reads legacy style mirrors.
- The complete normalized fixture corpus is registered by the root test import.

- [ ] **Step 1: Write failing clean-cutover checks**

Add a root test that imports all layout modules and runs the full fixture summary. Add a build-time search test or explicit compile references that prove `flex.zig` is absent and the new entry point is exported.

- [ ] **Step 2: Verify RED**

Run the cutover filter. Expected: failures while legacy imports and fields still exist.

- [ ] **Step 3: Delete obsolete implementation and migrate all references**

Remove `flex.zig`, old conformance fixture runners superseded by normalized cases, duplicate typed/legacy fields, compatibility re-exports, and dead helper code. Update `build.zig` only for the new layout files and test data access; do not add a normal-build Rust dependency.

- [ ] **Step 4: Verify GREEN**

Run all layout tests and source-reference checks. Expected: one production layout engine, one Style representation, no stale references.

- [ ] **Step 5: Commit**

```bash
jj commit -m "refactor(layout): remove legacy layout engine"
```

---

### Task 11: Run full parity and project gates

**Files:**
- Modify only if verification reveals a real defect in the files above.

**Interfaces:**
- Produces fixture count, group counts, zero mismatch count, and manifest validation evidence.

- [ ] **Step 1: Run the fixture contract in Debug**

```bash
zig build test -- --test-filter "Taffy v0.13 fixtures"
```

Expected: manifest revision/hash/count match and every enabled normalized case passes.

- [ ] **Step 2: Run ReleaseSafe conformance**

```bash
zig build test -Doptimize=ReleaseSafe -- --test-filter "Taffy v0.13 fixtures"
```

Expected: identical zero-mismatch result with no allocator leaks.

- [ ] **Step 3: Run nogui behavior gates**

```bash
zig fmt --check build.zig src
zig build
zig build test
zig build layout-check
zig build lint
zig build -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
```

Expected: all project-owned checks exit zero. Record unrelated pre-existing gate debt separately; do not mask it.

- [ ] **Step 4: Run graphical smoke tests**

```bash
zig build v7 -- --frames 1
zig build spotify -- --frames 1
```

Expected: both complete one visible surface frame without layout, draw, input, or GPU ordering error.

- [ ] **Step 5: Perform final independent review and commit**

Dispatch standards and specification reviewers over the complete change. Fix every critical or important finding, rerun the relevant gates, then:

```bash
jj commit -m "feat(layout): reach Taffy functional parity"
```
