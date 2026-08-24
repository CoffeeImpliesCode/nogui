# Taffy v0.13.0 Functional Layout Parity

## Status

Approved architecture. This document defines the functional layout compatibility target for nogui v7.

## Goal

Make nogui’s pure-Zig layout engine match the enabled, layout-observable behavior of DioxusLabs Taffy `v0.13.0`, pinned to commit `45a56299d366ddb383e593a1f0372158d00e8530`, while preserving nogui’s immediate-mode `WidgetTree`, double-buffered frame arenas, and parent-content-relative border-box geometry.

## Compatibility boundary

Parity means equivalent layout results for every enabled upstream Taffy `v0.13.0` fixture after adapting Taffy layout coordinates to nogui’s relative-rect invariant. The fixture oracle includes all enabled Block, BlockFlex, BlockGrid, Flex, Float, Grid, GridFlex, and Leaf cases in the pinned revision, with every generated LTR/RTL and content-box/border-box variant.

The target includes:

- `display: block`, `flow-root`, `flex`, `grid`, and `none`;
- relative and absolute positioning;
- LTR and RTL direction;
- typed fixed, percentage, auto, min-content, max-content, and `calc()` values;
- margin, padding, border, box sizing, aspect ratio, overflow geometry, scrollbar reservation, and scroll overflow;
- Flexbox direction, wrap, balance, basis, grow, shrink, auto margins, gaps, line formation, and alignment;
- Grid templates, implicit tracks, auto-placement, areas, spans, gaps, sizing, placement, and alignment;
- Block flow, FlowRoot boundaries, Float, Clear, and measurement callbacks.

Parity excludes features that upstream Taffy v0.13.0 does not implement or does not establish with a passing fixture contract:

- table layout;
- vertical writing modes;
- named grid-track placement;
- full grid baseline alignment;
- Rust-specific `TaffyTree`, node mutation, cache, serde, CSS parser, no-std, and detailed-layout host APIs;
- Taffy crate-private helpers and profiling/debug switches.

Nogui keeps its own public tree, state, input, renderer, and measurement interfaces. It does not bind to Rust or require Rust in normal build or test paths.

## Invariants

- `WidgetNode.rect` remains a border box relative to the parent content box. The root is relative to the surface.
- `absoluteRect`, visual geometry, draw-command collection, hit testing, and scrolling continue to consume this invariant.
- Layout uses only explicit allocators. Per-frame layout scratch, child lists, line lists, grid occupancy, and float state allocate from the current frame arena.
- Layout has no fixed child, line, grid-placement, or scratch-array limit. GPU clip-buffer capacity remains a renderer boundary and reports its own failure.
- The layout core never calls noapi or renderer code.
- Existing public callers migrate in one cutover. Obsolete `flex.zig` paths, legacy style mirrors, aliases, and compatibility wrappers are deleted after replacement callers and tests exist.
- Layout output is deterministic for a fixed tree, available space, measure callback, and style values.

## Layout core

The replacement is a modular pure-Zig implementation under `src/v7/layout/`:

```text
layout/
  root.zig          Layout entry point and WidgetTree adapter
  values.zig        CSS-like typed values, calc expression evaluation, direction
  sizing.zig        available space, intrinsic measurement, box-model resolution
  block_float.zig   block flow, FlowRoot, Float, Clear, absolute participation
  flex.zig          line formation, flexible-length resolution, alignment
  grid.zig          placement, tracks, intrinsic sizing, alignment
  geometry.zig      relative rect placement and scroll-overflow writeback
```

`src/v7/style.zig` owns the public typed style model. It becomes the sole source of layout values. The replacement removes the current duplicate legacy mirrors such as axis-specific fixed flex fields after all callers have migrated.

`layout/root.zig` receives a `WidgetTree`, a root identifier, available space, and the existing measurement callback. It maps node storage to an internal traversal contract but does not duplicate or retain a second tree. It writes relative border boxes and resolved overflow back to `WidgetNode`.

Algorithm modules share only explicit value and geometry types. They do not form a generic utility layer. `sizing.zig` resolves common box-model and intrinsic rules; each algorithm owns its own sequencing and scratch records.

## Style model

The public model gains the Taffy-compatible semantic fields needed by the fixture corpus:

- `Display`: Block, FlowRoot, Flex, Grid, None.
- `Direction`: Ltr, Rtl.
- `Position`: Relative, Absolute.
- `Overflow`: Visible, Clip, Scroll, Auto, with scrollbar width.
- `Float` and `Clear`.
- Full alignment distribution values, including safe/unsafe and self-start/self-end where Taffy exposes them.
- A typed calculation expression for valid length-percentage arithmetic. Invalid arithmetic and non-finite values return an explicit layout error rather than silently producing geometry.
- Grid area and named-line declarations as style input. Known upstream-unimplemented named-track placement remains unsupported and is not claimed as parity.

Style resolution remains local and fieldwise. There is no selector language, cascade, specificity, or inherited layout style.

## Fixture oracle

The repository vendors two forms of the pinned upstream corpus:

```text
testdata/taffy-v0.13.0/
  upstream/               exact enabled upstream fixture source and revision manifest
  normalized/cases.json   normalized tree/style/input/expected-layout cases
  MANIFEST.json           upstream commit, file hashes, generator version, case count
```

A maintenance-only importer regenerates `normalized/cases.json` from the pinned upstream source and Taffy v0.13.0. Normal builds and normal Zig tests do not invoke Rust, download data, or regenerate fixtures.

Every normalized case records:

- upstream source path and source hash;
- generated direction and box-sizing variant;
- style tree and node order;
- root available space;
- intrinsic measurement inputs where present;
- expected local border/content geometry;
- expected absolute geometry and scroll overflow.

The Zig fixture runner constructs a temporary `WidgetTree` with `std.testing.allocator`, runs the nogui layout core, and compares every node’s geometry and overflow exactly using the same tolerance Taffy’s source fixture format permits. A fixture fails with its upstream path and generated variant.

Existing nogui layout tests remain. They test nogui-specific relative geometry, scrolling, input, and rendering contracts that upstream Taffy does not cover. `notes/layout-golden.json` remains a separate application regression test; it does not substitute for conformance.

## Migration sequence

1. Add fixture import, normalized corpus, and a failing fixture runner before algorithm changes.
2. Expand style values and migrate all live constructors to the new model.
3. Replace fixed child and layout scratch limits with frame-arena-backed data.
4. Implement shared sizing and geometry writeback, then Block/FlowRoot/Float/absolute behavior.
5. Implement Flexbox against the complete Flex fixture set.
6. Implement Grid against the complete Grid, GridFlex, and BlockGrid fixture sets.
7. Delete legacy layout paths and migrate every caller to the replacement entry point.
8. Run full fixture conformance, nogui regression tests, demo/layout golden checks, Debug and ReleaseSafe gates, and graphical smoke tests.

Each algorithm family lands only with its fixture family green. The old and new engines do not coexist after the final cutover.

## Verification

Required evidence for completion:

- all enabled normalized Taffy v0.13.0 fixture variants pass in Debug and ReleaseSafe;
- fixture manifest hashes and expected case count match the pinned upstream revision;
- `zig build test`, `zig build layout-check`, `zig build`, `zig build lint`, formatter checks, and AST checks pass;
- the Spotify and default demos complete bounded graphical smoke runs;
- frame-arena layout paths show no per-frame general-purpose allocation and no fixed layout-cap rejection;
- direct tests cover nogui-only relative boxes, absolute conversion, visual scroll offsets, clipping, and hit testing;
- no legacy layout implementation, compatibility wrapper, or duplicate style field remains reachable.

## Sources

- Taffy v0.13.0 package and enabled features: https://github.com/DioxusLabs/taffy/blob/v0.13.0/Cargo.toml
- Taffy public Style contract: https://github.com/DioxusLabs/taffy/blob/v0.13.0/src/style/mod.rs
- Taffy fixture generation: https://github.com/DioxusLabs/taffy/tree/v0.13.0/test_fixtures
- Taffy XML fixture test runner: https://github.com/DioxusLabs/taffy/blob/v0.13.0/tests/xml.rs
