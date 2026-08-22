# V1 design: canonical v7, GPU component lifecycle, and typed CSS layout

## Status

Approved foundation. This document defines the V1 implementation contract.

## Goals

1. Make `nogui` export the v7 implementation from `src/v7/root.zig`.
2. Give components scoped access to noapi during explicit GPU lifecycle hooks.
3. Move Mandelbrot ownership from `src/v7_demo/window.zig` into a component.
4. Replace the current nowrap flex-specific layout data model with a typed, pure-Zig, Taffy-compatible CSS layout model.
5. Give each component explicit typed defaults for layout and paint.

## Non-goals

- No selector language, global cascade, specificity, or `!important`.
- No direct Vulkan types in the public API.
- No retained frame command buffers or renderer state in components.
- No compatibility alias for the dead `src/root.zig` library root.
- The legacy `proto` executable may remain a clearly named prototype target; it is not public library implementation.

## Canonical package boundary

`build.zig` defines module `nogui` with root `src/v7/root.zig`. Every demo and test imports that module rather than a `v7/...` symlink path. The obsolete `src/root.zig` is removed.

The package has two public layers:

- `nogui`: tree construction, state, input, typed styles, layout, draw-command collection, and lifecycle contracts.
- `nogui.runtime`: noapi-backed endpoint implementation used by a graphical host. The headless driver never creates this runtime.

The core stays deterministic for a fixed event stream and style tree. The runtime owns SDL, Surface begin/end frame, command-buffer validity, descriptor heaps, and the Oklab GUI pass.

## Stable component identity

Draw-order position is not a lifecycle identity. `ctx.component` receives a caller-provided key:

```zig
try ctx.component(.{ .key = .static("mandelbrot") }, MandelbrotComponent, &self.mandelbrot);
try ctx.component(.{ .key = .u64(track.id) }, TrackRow, row);
```

A component identity derives from its parent identity and key. The registry stores component metadata by that identity: vtable, receiver, last-seen frame, and GPU lifecycle state. A duplicate sibling key is an error. Dynamic collections must use stable model identifiers; array indexes are invalid unless the collection itself is structurally stable.

At the end of a frame, an entry not seen in that frame is unmounted: its GPU hook runs, its ordinary component deinit hook runs when owned storage requires it, and its registry record is removed. The root has the fixed identity `.root`.

Widget-local state uses the same keyed scope instead of per-frame draw-order node IDs. Focus, pressed state, drag state, and layout-golden identity derive from stable widget keys.

## GPU lifecycle

Components may declare any of these optional methods:

```zig
pub fn initGpu(self: *T, endpoint: *nogui.GpuEndpoint) !void;
pub fn frameGpu(self: *T, frame: *nogui.GpuFrame) !void;
pub fn deinitGpu(self: *T, endpoint: *nogui.GpuEndpoint) void;
```

`GpuEndpoint` is persistent for the runtime lifetime. It exposes the noapi GPU endpoint and renderer-owned persistent-resource services. Resource creation and destruction happen only in `initGpu` and `deinitGpu`.

`GpuFrame` is valid only while `frameGpu` runs. It exposes:

- `*noapi.Gpu`
- the current noapi command buffer
- surface extent and frame index
- texture registration and lookup through the renderer-owned bindless heap

A component can issue its own compute/transfer commands. It cannot begin or end a Surface frame, submit a command buffer, modify the GUI renderer's render pass, or retain `GpuFrame`/its command buffer after return.

Frame order is:

1. Runtime begins the Surface frame and obtains its command buffer.
2. Newly mounted components run `initGpu` before their first `draw`.
3. The App processes the event, builds the keyed tree, and computes layout.
4. Mounted GPU components run `frameGpu` against the live command buffer.
5. The renderer converts draw commands, executes its Oklab GUI pass, blits, and ends/presents the Surface frame.
6. Unmounted components run `deinitGpu` after their final frame; app shutdown deinitializes remaining entries before GPU shutdown.

`MandelbrotComponent` owns its compute shaders, target texture, texture registration, center, scale, precision, and interaction methods. Its `draw` method emits a normal textured node. Its `frameGpu` method dispatches compute before the GUI pass. The window driver does not inspect Mandelbrot widget nodes or maintain Mandelbrot globals.

## Typed CSS-compatible styling

The layout API models the Taffy property space with typed Zig values:

```zig
pub const Style = struct {
    display: Display,
    position: Position,
    inset: Rect<LengthPercentageAuto>,
    size: Size<Dimension>,
    min_size: Size<Dimension>,
    max_size: Size<Dimension>,
    margin: Rect<LengthPercentageAuto>,
    padding: Rect<LengthPercentage>,
    border: Rect<LengthPercentage>,
    box_sizing: BoxSizing,
    overflow: Point<Overflow>,
    aspect_ratio: ?f32,
    flex: FlexStyle,
    grid: GridStyle,
    align: AlignStyle,
};
```

The full V1 model includes block, flex, grid, and absolute positioning; auto/min-content/max-content/fixed/percent dimensions; min/max constraints; gaps; wrapping; alignment; intrinsic measurement; overflow; aspect ratio; box sizing; margins/padding/borders; and grid tracks/placement. Layout is pure Zig, deterministic, and callable in headless tests.

`PaintStyle` holds non-layout fields: fill, border color, radii, shadow, clipping, texture, text appearance, and z-layer.

A component declares defaults as data:

```zig
pub const default_style: nogui.Style = .{ .display = .flex, .flex = .column };
pub const default_paint: nogui.PaintStyle = .{ .fill = theme.surface };
```

At a component call, defaults merge with local explicit overrides field-by-field. Parent values inherit only for explicitly inheritable fields such as text style; layout properties do not inherit. There is no selector matching and no implicit global precedence.

## Migration

1. Change the package root and migrate all demo/test imports to `@import("nogui")`.
2. Replace draw-order component IDs with keyed identity and lifecycle registry ownership.
3. Add the runtime endpoint and GPU hook vtable entries while retaining headless `App` operation with no runtime.
4. Migrate Mandelbrot into `MandelbrotComponent`; delete driver-side special cases and globals.
5. Replace `WidgetNode.box`, `FlexChild`, and `FlexStyle` with `Style`/`PaintStyle`; port all existing layout behavior as conformance tests before adding the remaining Taffy algorithms.
6. Port Taffy-compatible block, flex, grid, and absolute layout algorithms with property-level regression tests.
7. Migrate component default styles and caller overrides. Delete ad-hoc layout/paint option application paths after all callers use typed styles.

## Verification

- The canonical module root compiles directly; no source imports `v7/...` or the removed root.
- Headless tests prove stable component mount/reorder/unmount behavior, state retention, duplicate-key rejection, and GPU-hook absence without a runtime.
- A fake `GpuEndpoint` verifies init/frame/deinit ordering, one-time init/deinit, and that unmounted components release resources.
- A window smoke proves Mandelbrot compute dispatch precedes the GUI pass and its registered texture appears in the component's normal node.
- The layout suite includes Taffy-compatible fixtures for each property family and preserves existing layout-golden behavior where semantics overlap.
- Debug and ReleaseSafe builds/tests, formatter, AST checks, and active-tree linters pass.
