# Core design

## Module boundaries

`nogui` exports tree construction, typed state, input, styles, layout, and component lifecycle contracts from `src/v7/root.zig`.
The text, renderer, frame, and host modules provide separate dependency products.
The [README](../../README.md#use-as-a-dependency) lists these products.
The [API guide](../API.md) describes their public entry points and lifetimes.

Headless App frames create no GPU runtime.
Graphical hosts use `GpuEndpoint` and `GpuFrame` to connect component hooks to noapi.
The host owns native windows. The frame adapter owns rendering and submission resources.

## Stable identity

Component identity derives from its parent's identity and a caller-supplied key.
Use stable model identifiers for dynamic collections.
Duplicate sibling keys return an error.

`FrameNodeId` indexes one tree. `WidgetId` identifies a control by owner, slot, and generation.
Focus, pressed state, and pointer capture follow stable controls across tree reorder.
Removed or replaced handles cannot address a different control.
Labels and translated captions do not affect identity.

The component registry tracks receivers, lifecycle methods, and GPU mount state.
A component absent from a committed frame unmounts.
Frame failure does not retire the last committed tree or its mounts.

## Frame transaction

The App builds a fresh tree in one of two frame arenas.
The previous tree remains available for comparison while the next tree builds.
Draw, layout, GPU hooks, JSON, mounts, focus, and semantics publish together.
Failure retains the last committed output.

A previous-tree snapshot expires at the next frame attempt.
A current tree survives that attempt, but can expire after a newer commit and another attempt.
Borrowed component resources must survive every tree that can still read them.
GPU resources require separate submission and recording lifetime management.

Tree storage is postorder. Each container follows its descendants.
Node rectangles are border boxes relative to the parent's content box.
A root rectangle is relative to the logical surface.
Layout, hit testing, scrolling, and caret geometry use logical window units.
The renderer converts device coordinates at the pixel-scale boundary.

## GPU lifecycle

Components can provide these optional methods:

```zig
pub fn initGpu(self: *T, endpoint: *nogui.GpuEndpoint) !void;
pub fn frameGpu(self: *T, frame: *nogui.GpuFrame) !void;
pub fn deinitGpu(self: *T, endpoint: *nogui.GpuEndpoint) void;
```

`GpuEndpoint` provides persistent noapi resources and texture registration services.
`GpuFrame` borrows the active command recording only during the callback.
A component can record compute and transfer work.
It must not retain the frame, submit commands, or own the host's surface frame.

The host starts recording before component GPU work.
The App initializes new mounts, builds and lays out the tree, and invokes GPU frame hooks.
The renderer lowers paint records, renders Oklab output, and converts to sRGB for presentation.
The host finishes recording after submission.

A failed App frame cancels recording before releasing staged GPU mounts.
Cancellation failure leaves resources protected rather than freeing them during possible use.
Shutdown detaches App GPU mounts before releasing the renderer, surface, and GPU.
Release a native surface during `Application.Hooks.on_before_close`, while its window remains alive.

## Styles and layout

`Style` holds typed layout fields. `PaintStyle` holds fill, border, shadow, clipping, texture, and other paint data.
Component defaults and explicit local overrides merge field by field.
Only inheritable fields, such as text style, flow from ancestors.
There is no selector language or global cascade.

The pure-Zig layout engine supports block, flex, grid, float, and absolute layout.
It uses explicit allocators and does not call renderer or noapi code.
See the [layout design](2026-08-24-taffy-functional-parity-design.md) for fixture coverage and geometry rules.
