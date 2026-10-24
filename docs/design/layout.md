# Layout design

The pure-Zig layout engine targets the enabled fixture behavior of
[Taffy v0.13.0](https://github.com/DioxusLabs/taffy/tree/v0.13.0).
The corpus pins commit `45a56299d366ddb383e593a1f0372158d00e8530`.
Nogui retains its own immediate-mode tree, measurement interface, input, and renderer.
Normal layout tests need no Rust toolchain.

## Geometry and storage

`WidgetNode.rect` is a border box relative to its parent's content box.
The root is relative to the logical surface.
Absolute geometry, scrolling, hit testing, and paint collection use this convention.

Layout takes an allocator, available space, and optional host measurement callbacks.
Frame scratch, child lists, flex lines, grid occupancy, and float state use frame-arena storage.
Layout does not call the renderer or noapi.
Output is deterministic for a fixed tree, space, styles, and measurement callback.

Identifiers and indexed storage use `u32`. Geometry uses `f32` and allocation sizes use `usize`.
Allocation and invalid arithmetic return errors.
The renderer's 64-rectangle clip capacity is separate from layout capacity.

## Layout and style model

The implementation lives in `src/v7/layout`.
`src/v7/style.zig` defines public layout and paint values.
Style resolution is local and fieldwise, without selectors, specificity, or inherited layout properties.

The fixture target covers:

- Block, flow-root, flex, grid, and hidden display.
- Relative and absolute positioning, LTR and RTL direction.
- Fixed, percentage, auto, min-content, max-content, and calculated dimensions.
- Margins, padding, borders, box sizing, aspect ratio, and overflow geometry.
- Flex direction, wrapping, basis, grow, shrink, gaps, alignment, and auto margins.
- Grid templates, implicit tracks, placement, spans, areas, sizing, gaps, and alignment.
- Block flow, float, clear, and intrinsic measurement.

Table layout, general vertical writing, named grid-track placement, and full grid baseline alignment are outside this fixture target.
The fixture-only Ahem adapter handles `vertical-lr` test inputs.
It does not implement general vertical text rendering in the GUI.
Taffy's Rust tree, serialization, parser, and crate-private APIs are outside the public API.

## Fixture corpus

| Path | Contents |
| --- | --- |
| `testdata/taffy-v0.13.0/upstream` | Pinned upstream fixture sources. |
| `testdata/taffy-v0.13.0/normalized/cases.json` | Normalized style, tree, input, and expected geometry. |
| `testdata/taffy-v0.13.0/MANIFEST.json` | Revision, file hashes, generator version, and case counts. |

The manifest records 1,381 sources and 5,524 cases.
Each source produces LTR/RTL and border-box/content-box variants.
Normalized cases retain source identity, node order, available space, measurement inputs, geometry, and scroll overflow.

Run the oracle from the repository root:

```sh
zig build fixture
zig build fixture -Dfixture-filter=leaf/leaf_with_content_and_border.html
```

The filter selects an upstream source and its normalized variants.
The runner reports the source path and variant for a mismatch.
Normal oracle runs read committed fixtures without regeneration or Rust.
Initial package dependency fetches can require network access.

`tools/import_taffy_v013_fixtures.py` regenerates the corpus.
Its `--source` option requires a clean Taffy checkout at the pinned commit.
Its `--out` option selects the output directory.

The separate `testdata/layout-golden.json` records application layout regressions.
`zig build layout-check` compares current demo output with that golden.
`zig build layout-update` replaces the golden and needs review.
Application layout checks do not replace the Taffy oracle.

## Upstream references

- [Style definitions](https://github.com/DioxusLabs/taffy/blob/v0.13.0/src/style/mod.rs)
- [Fixture generator](https://github.com/DioxusLabs/taffy/tree/v0.13.0/test_fixtures)
- [XML fixture runner](https://github.com/DioxusLabs/taffy/blob/v0.13.0/tests/xml.rs)
