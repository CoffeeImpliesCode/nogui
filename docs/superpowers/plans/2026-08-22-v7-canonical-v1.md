# Canonical V7 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make v7 the canonical nogui library, add scoped noapi component lifecycles, and replace the flex-only layout API with the complete typed Taffy-compatible model.

**Architecture:** `src/v7/root.zig` becomes the only public `nogui` module root. A stable keyed component registry owns mount/unmount and optional GPU hooks through a scoped runtime endpoint. Layout becomes a pure typed `Style` engine; `PaintStyle` remains renderer-facing, and the noapi runtime stays outside headless execution.

**Tech Stack:** Zig 0.16, noapi/Vulkan, SDL3, FreeType, HarfBuzz, Slang, Tracy.

## Implementation status (2026-09-09)

This historical plan keeps its original unchecked boxes. They show the planned sequence, not the current blocker list.

- **Implemented source:** The source changes from Tasks 1–8 are integrated. `src/v7/root.zig` is the canonical module. Stable component keys, scoped GPU hooks, Mandelbrot ownership, typed styles, and the replacement layout core are present.
- **Superseded route:** Later parity work replaced the intermediate `src/v7/flex.zig` route with `src/v7/layout/`. The old public root and legacy layout API are absent.
- **Verified stocktake evidence:** The Taffy oracle reports 5,524 passed, 0 failed, and 0 unsupported. The original 581-row layout golden still matches. Both linters scan 77 files with zero warnings.
- **Verified execution evidence:** Debug passes 55/55 steps and 970/970 tests. ReleaseSafe passes 48/48 steps and 970/970 tests. Vendored noapi passes 55/55 tests with Tracy disabled.
- **Verified GPU evidence:** All 10 actual-GPU shots are byte-identical to the frozen shots. They cover five scenes in normal and reverse order. The remount smoke passes Mandelbrot slot-2 reuse after one hidden frame. The presented run passes 24 ordered frames and 20 complete samples with positive intervals on driver 595.99.02.
- **Vendored dependency:** The required noapi commit has no remote. `vendor/noapi-provenance.json` binds the exact source digest and ten patch hashes. The upstream snapshot contains no `LICENSE` file.
- **Current disposition:** The implementation and verification outcomes of Tasks 1–9 are complete. Fresh calibration completed as `capped_unstable`. The full performance baseline was stopped after reported throughput near 1 FPS; it remains incomplete.

## Global Constraints

- Zig minimum version is `0.16.0`.
- No direct Vulkan types in the public API.
- No per-frame malloc; persistent allocations use explicit allocators and frame data uses App arenas.
- No global CSS cascade, selector grammar, specificity, or `!important`.
- `GpuFrame` and its command buffer must not escape `frameGpu`.
- The canonical public import is `@import("nogui")`; delete the dead root rather than aliasing it.
- Every changed Zig file must satisfy formatter, AST, ziglint, and zlint checks.

---

### Task 1: Canonical package root

**Files:**
- Modify: `build.zig`
- Modify: `build.zig.zon`
- Modify: `src/v7/root.zig`
- Modify: `src/v7_demo/main.zig`
- Delete: `src/root.zig`

**Interfaces:**
- Produces: `@import("nogui")` whose root is `src/v7/root.zig`.
- Produces: demo/test modules that share one `DrawCtx` type identity.

- [ ] **Step 1: Add the canonical-root compile test**

Add to `src/v7/root.zig`:

```zig
test "canonical module exports App and DrawCtx" {
    _ = App;
    _ = DrawCtx;
}
```

- [ ] **Step 2: Run the test baseline**

Run: `zig build test`
Expected: existing suite passes before root migration.

- [ ] **Step 3: Point the package module at v7**

In `build.zig`, make the `nogui` module root `src/v7/root.zig`; add its `noapi` import only for the public runtime module. Replace demo relative/symlink imports with `. { .name = "nogui", .module = mod }` and use `const nogui = @import("nogui");`.

- [ ] **Step 4: Remove the obsolete library root**

Delete `src/root.zig`. Remove it from `build.zig.zon` paths only if it is individually listed; retain the `src` directory path.

- [ ] **Step 5: Run canonical-root tests**

Run: `zig build test`
Expected: all test roots use the same exported `nogui` types and pass.

- [ ] **Step 6: Commit**

Run: `jj commit -m "refactor(v7): make v7 the canonical library root"`

### Task 2: Stable keys and lifecycle registry

**Files:**
- Create: `src/v7/key.zig`
- Modify: `src/v7/component.zig`
- Modify: `src/v7/drawctx.zig`
- Modify: `src/v7/app.zig`
- Modify: `src/v7/root.zig`

**Interfaces:**
- Produces: `ComponentKey`, `ComponentId`, and keyed `DrawCtx.component`.
- Produces: registry mount/unmount tracking independent of draw order.

- [ ] **Step 1: Add failing stable-identity tests**

Add tests proving that a keyed child keeps its state when a preceding sibling is conditionally inserted, that a duplicate sibling key returns `error.DuplicateComponentKey`, and that an absent child unmounts exactly once.

```zig
try ctx.component(.{ .key = .static("child") }, Child, &root.child);
```

- [ ] **Step 2: Run the test baseline**

Run: `zig build test`
Expected: compilation fails until `ComponentKey` and keyed registration exist.

- [ ] **Step 3: Define typed keys**

In `key.zig`, define a tagged key and hierarchical identity:

```zig
pub const ComponentKey = union(enum) {
    static: []const u8,
    u64: u64,
};
pub const ComponentId = struct { hi: u64, lo: u64 };
pub fn child(parent: ComponentId, key: ComponentKey) ComponentId;
```

Hash the tag and payload with a fixed deterministic algorithm; never use draw order or pointer addresses.

- [ ] **Step 4: Track component lifetime**

Replace the `Id -> Component` registry value with an entry containing `component`, `last_seen_frame`, `mounted`, and the stable `ComponentId`. `DrawCtx.component` accepts `.key`, derives an identity from the current component identity, detects duplicate identities in a frame, marks the entry seen, and restores the parent scope after drawing.

- [ ] **Step 5: Unmount deterministically**

After each present, sweep entries not seen in the current frame. Invoke optional teardown once, remove them from the map, and preserve the root entry. Do not allocate during the sweep except map removal internals supplied by the App allocator.

- [ ] **Step 6: Run stable-identity tests**

Run: `zig build test`
Expected: reorder, duplicate, and unmount tests pass in Debug and use `std.testing.allocator` without leaks.

- [ ] **Step 7: Commit**

Run: `jj commit -m "feat(v7): add stable keyed component identity"`

### Task 3: Scoped noapi lifecycle contract

**Files:**
- Create: `src/v7/runtime.zig`
- Modify: `src/v7/component.zig`
- Modify: `src/v7/app.zig`
- Modify: `src/v7/root.zig`
- Modify: `build.zig`

**Interfaces:**
- Produces: `GpuEndpoint`, `GpuFrame`, and optional `initGpu`, `frameGpu`, `deinitGpu` vtable entries.
- Consumes: stable registry entries from Task 2.

- [ ] **Step 1: Add lifecycle ordering tests using a fake runtime**

Test exactly this order for a mounted child: `init`, `frame`, `frame`, `deinit`. Test headless App execution does not call GPU hooks.

```zig
const Log = enum { init, frame, deinit };
try testing.expectEqualSlices(Log, &.{ .init, .frame, .frame, .deinit }, log.items);
```

- [ ] **Step 2: Run the test baseline**

Run: `zig build test`
Expected: new lifecycle symbols are absent.

- [ ] **Step 3: Define endpoint validity boundaries**

In `runtime.zig`, define:

```zig
pub const GpuEndpoint = struct {
    gpu: *noapi.Gpu,
    texture_registry: *TextureRegistry,
};
pub const GpuFrame = struct {
    endpoint: *GpuEndpoint,
    command_buffer: *noapi.CommandBuffer,
    extent: noapi.Extent2D,
    frame_index: u32,
};
```

Expose texture registration through `GpuEndpoint`; do not expose Surface begin/end or queue submission. Document that `GpuFrame` is borrowed and cannot be stored.

- [ ] **Step 4: Extend the component vtable**

Add optional typed adapters which are present only when the component declares the exact signatures:

```zig
init_gpu: ?*const fn (*anyopaque, *GpuEndpoint) anyerror!void,
frame_gpu: ?*const fn (*anyopaque, *GpuFrame) anyerror!void,
deinit_gpu: ?*const fn (*anyopaque, *GpuEndpoint) void,
```

- [ ] **Step 5: Integrate App lifecycle dispatch**

App accepts an optional attached `*GpuEndpoint`. Initialize newly registered entries before first draw, call mounted `frame_gpu` after layout and before FrameOutput returns, and call `deinit_gpu` before normal component teardown. Preserve headless behavior when no endpoint is attached.

- [ ] **Step 6: Run lifecycle tests**

Run: `zig build test`
Expected: lifecycle ordering, headless no-op, and teardown tests pass.

- [ ] **Step 7: Commit**

Run: `jj commit -m "feat(v7): add scoped noapi component lifecycle"`

### Task 4: Runtime driver and Mandelbrot component

**Files:**
- Create: `src/v7_demo/mandelbrot_component.zig`
- Modify: `src/v7_demo/window.zig`
- Modify: `src/v7_demo/ui.zig`
- Modify: `src/v7_demo/main.zig`
- Modify: `shaders/mandelbrot.comp.slang`

**Interfaces:**
- Consumes: Task 3 `GpuEndpoint` and `GpuFrame`.
- Produces: a normal textured component node backed by component-owned compute resources.

- [ ] **Step 1: Add a headless Mandelbrot component test**

Verify the component draws a node with no texture when the runtime is absent and preserves center/scale/precision after user-event methods.

- [ ] **Step 2: Add runtime sequencing test**

Use a fake GPU frame to assert the component records compute before renderer collection and publishes the same texture registry index used by its node.

- [ ] **Step 3: Move persistent Mandelbrot resources**

Define `MandelbrotComponent` with fields for target texture, texture registry index, compute shaders, center, scale, and precision. Implement `initGpu` to allocate/register resources, `frameGpu` to dispatch compute, and `deinitGpu` to release every component-owned resource.

- [ ] **Step 4: Delete window special cases**

Remove `mandelbrotRect`, global `ui.mandelbrot_*`, driver hit-testing, and driver compute setup/dispatch. The UI calls component interaction methods and draws its registered texture as a normal node.

- [ ] **Step 5: Run headless and graphical smoke tests**

Run: `zig build test && zig build layout-check && zig build v7`
Expected: tests/layout pass and the headless demo emits six frames. Run the bounded graphical command: `zig build v7 -- --frames 1`; expected exit 0 on a display-capable host.

- [ ] **Step 6: Commit**

Run: `jj commit -m "refactor(demo): move mandelbrot into a GPU component"`

### Task 5: Typed style model and default resolution

**Files:**
- Create: `src/v7/style.zig`
- Modify: `src/v7/widget.zig`
- Modify: `src/v7/drawctx.zig`
- Modify: `src/v7/root.zig`
- Modify: `src/v7_demo/ui.zig`

**Interfaces:**
- Produces: `Style`, `PaintStyle`, typed dimensions, and deterministic local default merging.
- Preserves: existing box, paint, and flex output while later tasks replace algorithms.

- [ ] **Step 1: Add failing style-resolution tests**

Test that a component default column/gap/padding applies, an explicit caller override replaces only that field, non-inheritable layout values do not flow to children, and inheritable text values do.

```zig
const resolved = Style.resolve(Component.default_style, .{ .gap = .length(12) });
try testing.expectEqual(LengthPercentageAuto.length(12), resolved.gap.column);
```

- [ ] **Step 2: Define typed property values**

Define `Dimension`, `LengthPercentage`, `LengthPercentageAuto`, `Display`, `Position`, `Overflow`, `FlexStyle`, `GridStyle`, and `AlignStyle` in `style.zig`. Use tagged unions for auto/length/percent/min-content/max-content values; never encode CSS values as strings.

- [ ] **Step 3: Define `Style` and `PaintStyle`**

Add the exact fields declared by the design: display, position, inset, size/min/max, margin/padding/border, box sizing, overflow, aspect ratio, flex/grid/alignment; and paint-only fill, border color, radii, shadow, clip, texture, text, layer.

- [ ] **Step 4: Migrate node construction**

Replace `WidgetNode.box`, `flex`, and `style` storage with resolved `Style` plus `PaintStyle`. Make DrawCtx constructors accept `.style` and `.paint` values, resolve defaults locally, and remove field-by-field anonymous-options style mutation once all callers migrate.

- [ ] **Step 5: Run style tests**

Run: `zig build test`
Expected: default, override, and inheritance tests pass while existing layout output remains unchanged.

- [ ] **Step 6: Commit**

Run: `jj commit -m "feat(v7): add typed component style defaults"`

### Task 6: Taffy-compatible block and absolute layout

**Files:**
- Modify: `src/v7/flex.zig`
- Modify: `src/v7/widget.zig`
- Modify: `src/v7/headless.zig`
- Modify: `src/v7_demo/ui.zig`
- Modify: `notes/layout-golden.json`

**Interfaces:**
- Consumes: Task 5 `Style` resolved values.
- Produces: intrinsic block flow, absolute positioning, size constraints, box sizing, overflow, and aspect-ratio semantics.

- [ ] **Step 1: Add property-family fixtures**

Add deterministic tests for auto/fixed/percent/min-content/max-content sizes, min/max clamping, content-box/border-box, block flow margins, absolute inset resolution, clipping overflow, and aspect-ratio sizing.

- [ ] **Step 2: Replace flex-only measure entry**

Rename `layoutWith` to a general `layoutTree`; retain a compatibility wrapper only inside the migration commit. Compute containing blocks, intrinsic sizes, and final border/content boxes from `Style` values. Preserve relative-rect semantics.

- [ ] **Step 3: Implement block and absolute algorithms**

Block children stack in normal flow. Absolute children are removed from flow and resolve each specified inset against their containing block. Percent values resolve only against definite containing dimensions; otherwise use the typed auto path.

- [ ] **Step 4: Update headless serialization and golden**

Serialize resolved layout properties needed for diagnostics. Regenerate `notes/layout-golden.json` only after the legacy demo layout is intentionally matched under the new model.

- [ ] **Step 5: Run layout suite**

Run: `zig build test && zig build layout-check`
Expected: every fixture passes and the golden matches.

- [ ] **Step 6: Commit**

Run: `jj commit -m "feat(layout): add block and absolute style layout"`

### Task 7: Taffy-compatible flex layout

**Files:**
- Modify: `src/v7/flex.zig`
- Modify: `src/v7/style.zig`
- Modify: `src/v7/drawctx.zig`
- Modify: `src/v7/headless.zig`
- Modify: `notes/layout-golden.json`

**Interfaces:**
- Consumes: Task 6 general layout tree and typed Style.
- Produces: complete flex direction/wrap/basis/grow/shrink/alignment/gap behavior.

- [ ] **Step 1: Add flex conformance fixtures**

Cover row/column, reverse directions, wrap and wrap-reverse, flex basis, grow/shrink freeze, auto margins, all justify/align modes, align-content, gaps, min/max constraints, and percentage children.

- [ ] **Step 2: Implement line formation and flex resolution**

Create flex lines from available main size, resolve flex base sizes, freeze clamped items, distribute free space, resolve cross sizes, then apply per-line and multi-line alignment. Use arena scratch storage bounded by the number of children; no heap allocation in the hot layout API.

- [ ] **Step 3: Migrate all current row/column callers**

Translate current constructor options to `Style.flex`. Delete legacy `FlexChild`, legacy `FlexStyle`, and hand-written `applyFlexStyle`/`applyFlexSizing` once no caller uses them.

- [ ] **Step 4: Run flex tests and golden**

Run: `zig build test && zig build layout-check`
Expected: conformance fixtures and prior demo layout pass.

- [ ] **Step 5: Commit**

Run: `jj commit -m "feat(layout): implement typed flex layout"`

### Task 8: Taffy-compatible grid, overflow, and default-style migration

**Files:**
- Modify: `src/v7/flex.zig`
- Modify: `src/v7/style.zig`
- Modify: `src/v7/drawctx.zig`
- Modify: `src/v7_demo/ui.zig`
- Modify: `src/v7_demo/spotify.zig`

**Interfaces:**
- Consumes: Task 7 general flex engine.
- Produces: grid tracks/placement and complete component defaults used by active roots.

- [ ] **Step 1: Add grid and default-style fixtures**

Cover fixed/flexible/auto/minmax tracks, explicit placement, auto-placement, spans, gaps, alignment, overflow clipping/scroll extents, and each active component’s default/override contract.

- [ ] **Step 2: Implement grid track sizing and placement**

Resolve explicit track sizes, intrinsic auto tracks, flexible fractions, item spans, placement, and alignment inside the final grid content box. Grid items participate in the same typed box model as block/flex items.

- [ ] **Step 3: Migrate active components**

Move `ui.zig` and `spotify.zig` from ad-hoc box/flex literals to `default_style`, `default_paint`, and local explicit overrides. Preserve all colors, clips, texture slots, layers, and interaction geometry.

- [ ] **Step 4: Delete legacy layout option paths**

Remove obsolete box/flex fields, old anonymous option appliers, and compatibility wrapper only after all v7/demo callers use typed styles.

- [ ] **Step 5: Run full behavior checks**

Run: `zig build test && zig build layout-check && zig build v7`
Expected: suite passes, layout golden matches, and six headless frames are emitted.

- [ ] **Step 6: Commit**

Run: `jj commit -m "feat(layout): complete typed grid and component defaults"`

### Task 9: Final integration and review

**Files:**
- Modify: `build.zig`
- Modify: `build.zig.zon`
- Modify: `docs/superpowers/specs/2026-08-22-v7-canonical-design.md`
- Modify: `notes/layout-golden.json`
- Modify: `src/v7/root.zig`

**Interfaces:**
- Produces: canonical library, lifecycle, Mandelbrot component, and typed layout model with no obsolete public root or layout API.

- [ ] **Step 1: Search for obsolete imports and APIs**

Run searches for `@import("v7/`, `src/root.zig`, `FlexChild`, `boxFromOpts`, `applyFlexStyle`, and `applyFlexSizing`. Migrate every live caller or remove the dead API.

- [ ] **Step 2: Run format and AST validation**

Run: `zig fmt --check build.zig src` and `zig ast-check` on every changed Zig file.
Expected: zero formatting diffs and zero AST errors.

- [ ] **Step 3: Run Debug gates**

Run: `zig build && zig build test && zig build lint && zig build layout-check && zig build v7`.
Expected: every command exits 0.

- [ ] **Step 4: Run ReleaseSafe gates**

Run: `zig build -Doptimize=ReleaseSafe && zig build test -Doptimize=ReleaseSafe`.
Expected: every command exits 0 with no allocator leaks.

- [ ] **Step 5: Run a graphical Mandelbrot smoke**

Run: `zig build v7 -- --frames 1` on a display-capable host.
Expected: exit 0 after one surface frame; inspect the result for no compute/render ordering error.

- [ ] **Step 6: Commit**

Run: `jj commit -m "feat(v7): complete canonical version-one architecture"`

## Plan self-review

- Spec coverage: Tasks 1–4 cover canonical root, stable identity, noapi lifecycle, and Mandelbrot ownership. Tasks 5–8 cover typed styles, block, flex, grid, absolute positioning, overflow, and component defaults. Task 9 covers cleanup and all gates.
- Placeholder scan: no deferred implementation markers appear in tasks.
- Type consistency: Tasks 2–4 share `ComponentId`, `GpuEndpoint`, and `GpuFrame`; Tasks 5–8 share `Style` and `PaintStyle`.
