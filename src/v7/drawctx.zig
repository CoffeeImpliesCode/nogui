//! DrawCtx — the per-frame UI surface.
//!
//! DrawCtx owns the cursor into a `WidgetTree` and the `component_id` that
//! binds event handlers to their owning component. State lives in
//! components; the UI is rebuilt every frame: a fresh tree + DrawCtx, a
//! draw pass, then `layout.layoutTree` dispatches canonical layout.
//!
//! Node order in the flat array is **post-order**: a container node is
//! appended after all of its descendants. The canonical layout dispatcher
//! validates this order and sizes descendants before their containers, so
//! this order is load-bearing. DrawCtx keeps it by appending children as
//! they are created and, on `pop()`, moving the just-closed container to the
//! end of the array — everything after it is one of its descendants, by the
//! cursor invariant.
//!
//! Per-frame storage: every node is allocated from `arena` (the frame
//! arena). The tree must be re-created per frame — never reuse a
//! `WidgetTree` across an arena reset: `reset(.retain_capacity)` frees any
//! ArrayList buffer that grew past its first arena chunk (Zig 0.16
//! footgun), which would leave a reused tree pointing at freed memory.
//!
const std = @import("std");
const noapi = @import("noapi");
const widget = @import("widget.zig");
const element = @import("element.zig");
const overlay = @import("overlay.zig");

const FrameNodeId = @import("id.zig").FrameNodeId;
const WidgetId = @import("id.zig").WidgetId;
const ComponentKey = @import("key.zig").ComponentKey;
const ComponentId = @import("key.zig").ComponentId;
const style = @import("style.zig");
const text_api = @import("text.zig");
const Style = style.Style;
const StyleOverride = style.StyleOverride;
const PaintStyle = style.PaintStyle;
const PaintStyleOverride = style.PaintStyleOverride;
const ComponentDefaults = style.ComponentDefaults;
const Sides = style.Sides;
const BoxSizing = style.BoxSizing;
const Justify = style.Justify;
const Align = style.Align;
const FlexWrap = style.FlexWrap;
const AlignContent = style.AlignContent;
const FlexDirection = style.FlexDirection;
const AlignSelf = style.AlignSelf;
const layout = @import("layout/root.zig");
const hitActionable = @import("input.zig").hitActionable;
const StateKey = @import("state.zig").Key;
const stateHash = @import("state.zig").hashName;
const StateDir = @import("state.zig").StateDir;
const Component = @import("component.zig").Component;
const IdentityRegistry = @import("identity.zig").IdentityRegistry;
const StableComponentRegistry = @import("component.zig").ComponentRegistry;
const GpuEndpoint = @import("runtime.zig").GpuEndpoint;
const Context = @import("context.zig").Context;
const FrameInfo = @import("context.zig").FrameInfo;
const Session = @import("session.zig").Session;
pub const ComponentRegistry = struct {
    map: *std.AutoHashMapUnmanaged(FrameNodeId, Component),
    gpa: std.mem.Allocator,
};
const WidgetKind = @import("widget.zig").WidgetKind;
const WidgetTree = @import("widget.zig").WidgetTree;
const ScrollAxis = @import("widget.zig").ScrollAxis;
const ScrollState = @import("widget.zig").ScrollState;
const TextOverflow = @import("widget.zig").TextOverflow;
const SharedColumns = @import("widget.zig").SharedColumns;
const ColumnTrack = @import("widget.zig").ColumnTrack;
const callback = @import("callback.zig");
const paint = @import("paint.zig");
const animation = @import("animation.zig");

fn asComponentKey(value: anytype) ComponentKey {
    const T = @TypeOf(value);
    if (T == ComponentKey) return value;
    if (@typeInfo(T) == .@"struct") {
        if (@hasField(T, "static")) return .{ .static = value.static };
        if (@hasField(T, "u64")) return .{ .u64 = value.u64 };
    }
    @compileError("widget key must be a ComponentKey (.static or .u64)");
}

fn asDimensionSize(x: anytype) style.DimensionSize {
    const T = @TypeOf(x);
    if (@typeInfo(T) != .@"struct") {
        return .{ .width = .auto, .height = .auto };
    }
    return .{
        .width = if (@hasField(T, "width")) style.dimensionFrom(x.width) else .auto,
        .height = if (@hasField(T, "height")) style.dimensionFrom(x.height) else .auto,
    };
}

fn asLengthPercentageAutoSize(x: anytype) style.DimensionSize {
    const T = @TypeOf(x);
    if (@typeInfo(T) != .@"struct") {
        return .{ .width = .auto, .height = .auto };
    }
    return .{
        .width = if (@hasField(T, "width")) style.dimensionFrom(x.width) else .auto,
        .height = if (@hasField(T, "height")) style.dimensionFrom(x.height) else .auto,
    };
}

fn asInsets(x: anytype) style.Insets {
    const T = @TypeOf(x);
    if (@typeInfo(T) != .@"struct") return .{
        .top = .auto,
        .right = .auto,
        .bottom = .auto,
        .left = .auto,
    };
    return .{
        .top = if (@hasField(T, "top")) style.lengthPercentageAutoFrom(x.top) else .auto,
        .right = if (@hasField(T, "right")) style.lengthPercentageAutoFrom(x.right) else .auto,
        .bottom = if (@hasField(T, "bottom")) style.lengthPercentageAutoFrom(x.bottom) else .auto,
        .left = if (@hasField(T, "left")) style.lengthPercentageAutoFrom(x.left) else .auto,
    };
}

fn asMarginInsets(x: anytype) style.Insets {
    const T = @TypeOf(x);
    if (@typeInfo(T) != .@"struct") {
        const value = style.lengthPercentageAutoFrom(x);
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }
    return .{
        .top = if (@hasField(T, "top")) style.lengthPercentageAutoFrom(x.top) else .{ .length = 0 },
        .right = if (@hasField(T, "right")) style.lengthPercentageAutoFrom(x.right) else .{ .length = 0 },
        .bottom = if (@hasField(T, "bottom")) style.lengthPercentageAutoFrom(x.bottom) else .{ .length = 0 },
        .left = if (@hasField(T, "left")) style.lengthPercentageAutoFrom(x.left) else .{ .length = 0 },
    };
}
fn asLengthPercentageRect(x: anytype) style.LengthPercentageRect {
    const T = @TypeOf(x);
    if (@typeInfo(T) != .@"struct") {
        const value = style.lengthPercentageFrom(x);
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }
    return .{
        .top = if (@hasField(T, "top")) style.lengthPercentageFrom(x.top) else .{ .length = 0 },
        .right = if (@hasField(T, "right")) style.lengthPercentageFrom(x.right) else .{ .length = 0 },
        .bottom = if (@hasField(T, "bottom")) style.lengthPercentageFrom(x.bottom) else .{ .length = 0 },
        .left = if (@hasField(T, "left")) style.lengthPercentageFrom(x.left) else .{ .length = 0 },
    };
}

fn asGridPlacement(value: anytype) style.GridPlacement {
    const T = @TypeOf(value);
    if (T == style.GridPlacement) return value;
    return switch (@typeInfo(T)) {
        .@"struct" => {
            if (@hasField(T, "line")) return .{ .line = value.line };
            if (@hasField(T, "span")) return .{ .span = value.span };
            return .auto;
        },
        .enum_literal => .auto,
        else => @compileError("expected grid placement"),
    };
}

fn asOverflowAxes(x: anytype) style.OverflowAxes {
    const T = @TypeOf(x);
    if (@typeInfo(T) != .@"struct") return .{ .width = .visible, .height = .visible };
    return .{
        .width = if (@hasField(T, "width")) @as(style.Overflow, x.width) else .visible,
        .height = if (@hasField(T, "height")) @as(style.Overflow, x.height) else .visible,
    };
}

fn asFixedLength(value: anytype) ?f32 {
    return switch (style.lengthPercentageAutoFrom(value)) {
        .auto, .percent => null,
        .length => |length| length,
    };
}

fn asDimensionOverride(value: anytype) style.DimensionOverride {
    if (@TypeOf(value) == style.DimensionOverride) return value;
    return .{ .value = style.dimensionFrom(value) };
}

/// Resolve typed layout and paint values from an anonymous widget options
/// value. Missing fields stay unspecified and therefore retain defaults.
fn styleFromOpts(opts: anytype, defaults: ?Style, direction: style.FlexDirection) Style {
    var local: StyleOverride = .{};
    const T = @TypeOf(opts);
    if (@hasField(T, "display")) local.display = @as(style.Display, opts.display);
    if (@hasField(T, "visibility")) local.visibility = @as(style.Visibility, opts.visibility);
    if (@hasField(T, "position")) local.position = @as(style.Position, opts.position);
    if (@hasField(T, "writing_direction")) {
        local.writing_direction = @as(style.Direction, opts.writing_direction);
    }
    if (@hasField(T, "float")) local.float = @as(style.Float, opts.float);
    if (@hasField(T, "clear")) local.clear = @as(style.Clear, opts.clear);
    if (@hasField(T, "direction")) local.direction = @as(style.FlexDirection, opts.direction);
    if (@hasField(T, "flex_wrap")) local.flex_wrap = @as(FlexWrap, opts.flex_wrap);
    if (@hasField(T, "align_content")) {
        local.align_content = @as(AlignContent, opts.align_content);
    }
    if (@hasField(T, "align_self")) local.align_self = @as(AlignSelf, opts.align_self);
    if (@hasField(T, "justify")) local.justify = @as(Justify, opts.justify);
    if (@hasField(T, "align")) local.@"align" = @as(Align, opts.@"align");
    if (@hasField(T, "text_align")) local.text_align = @as(style.TextAlign, opts.text_align);
    if (@hasField(T, "gap")) local.gap = style.lengthPercentageFrom(opts.gap);
    if (@hasField(T, "column_gap")) local.column_gap = style.lengthPercentageFrom(opts.column_gap);
    if (@hasField(T, "row_gap")) local.row_gap = style.lengthPercentageFrom(opts.row_gap);
    if (@hasField(T, "grid_template_columns")) {
        local.grid_template_columns = opts.grid_template_columns;
    }
    if (@hasField(T, "grid_template_rows")) {
        local.grid_template_rows = opts.grid_template_rows;
    }
    if (@hasField(T, "grid_auto_columns")) local.grid_auto_columns = opts.grid_auto_columns;
    if (@hasField(T, "grid_auto_rows")) local.grid_auto_rows = opts.grid_auto_rows;
    if (@hasField(T, "grid_auto_flow")) local.grid_auto_flow = @as(style.GridAutoFlow, opts.grid_auto_flow);
    if (@hasField(T, "grid_justify_content")) {
        local.grid_justify_content = @as(Justify, opts.grid_justify_content);
    }
    if (@hasField(T, "grid_align_content")) {
        local.grid_align_content = @as(AlignContent, opts.grid_align_content);
    }
    if (@hasField(T, "grid_justify_items")) local.grid_justify_items = @as(Align, opts.grid_justify_items);
    if (@hasField(T, "grid_align_items")) local.grid_align_items = @as(Align, opts.grid_align_items);
    if (@hasField(T, "grid_justify_self")) local.grid_justify_self = @as(AlignSelf, opts.grid_justify_self);
    if (@hasField(T, "grid_align_self")) local.grid_align_self = @as(AlignSelf, opts.grid_align_self);
    if (@hasField(T, "grid_column")) {
        local.grid_column = .{
            .start = asGridPlacement(opts.grid_column.start),
            .end = asGridPlacement(opts.grid_column.end),
        };
    }
    if (@hasField(T, "grid_row")) {
        local.grid_row = .{
            .start = asGridPlacement(opts.grid_row.start),
            .end = asGridPlacement(opts.grid_row.end),
        };
    }
    if (@hasField(T, "grow")) local.grow = opts.grow;
    if (@hasField(T, "shrink")) local.shrink = opts.shrink;
    if (@hasField(T, "flex_basis")) local.flex_basis = asDimensionOverride(opts.flex_basis);
    if (@hasField(T, "size")) local.size = .{ .value = asDimensionSize(opts.size) };
    if (@hasField(T, "min_size")) {
        local.min_size = .{ .value = asLengthPercentageAutoSize(opts.min_size) };
    }
    if (@hasField(T, "max_size")) {
        local.max_size = .{ .value = asLengthPercentageAutoSize(opts.max_size) };
    }
    if (@hasField(T, "width")) local.width = asDimensionOverride(opts.width);
    if (@hasField(T, "height")) local.height = asDimensionOverride(opts.height);
    if (@hasField(T, "min_width")) local.min_width = asDimensionOverride(opts.min_width);
    if (@hasField(T, "min_height")) local.min_height = asDimensionOverride(opts.min_height);
    if (@hasField(T, "max_width")) local.max_width = asDimensionOverride(opts.max_width);
    if (@hasField(T, "max_height")) local.max_height = asDimensionOverride(opts.max_height);
    if (@hasField(T, "inset")) local.inset = .{ .value = asInsets(opts.inset) };
    if (@hasField(T, "aspect_ratio")) local.aspect_ratio = .{ .value = opts.aspect_ratio };
    if (@hasField(T, "overflow")) local.overflow = .{ .value = asOverflowAxes(opts.overflow) };
    if (@hasField(T, "scrollbar_width")) local.scrollbar_width = opts.scrollbar_width;
    if (@hasField(T, "margin")) local.margin_inset = asMarginInsets(opts.margin);
    if (@hasField(T, "border")) local.border_inset = asLengthPercentageRect(opts.border);
    if (@hasField(T, "padding")) local.padding_inset = asLengthPercentageRect(opts.padding);
    if (@hasField(T, "margin_inset")) local.margin_inset = asInsets(opts.margin_inset);
    if (@hasField(T, "border_inset")) local.border_inset = asLengthPercentageRect(opts.border_inset);
    if (@hasField(T, "padding_inset")) local.padding_inset = asLengthPercentageRect(opts.padding_inset);
    if (@hasField(T, "box_sizing")) local.box_sizing = @as(BoxSizing, opts.box_sizing);
    return Style.resolve(defaults orelse .{ .direction = direction }, local);
}

fn paintStyleFromOpts(opts: anytype, defaults: ?PaintStyle) PaintStyle {
    var local: PaintStyleOverride = .{};
    const T = @TypeOf(opts);
    if (@hasField(T, "border_color")) {
        if (@TypeOf(opts.border_color) == paint.Color) {
            local.border_colors = .{opts.border_color} ** 4;
        } else {
            local.border_color = asColor(opts.border_color);
        }
    }
    if (@hasField(T, "border_colors")) local.border_colors = opts.border_colors;
    if (@hasField(T, "border_styles")) local.border_styles = opts.border_styles;
    if (@hasField(T, "radius")) local.radius = asPaintSides(opts.radius);
    if (@hasField(T, "radii")) local.radii = opts.radii;
    if (@hasField(T, "shadows")) local.shadows = opts.shadows;
    if (@hasField(T, "opacity")) local.opacity = opts.opacity;
    if (@hasField(T, "transform")) local.transform = opts.transform;
    if (@hasField(T, "transparent")) local.transparent = opts.transparent;
    if (@hasField(T, "clip")) local.clip = opts.clip;
    if (@hasField(T, "layer")) local.layer = opts.layer;
    if (@hasField(T, "texture")) local.texture = .{ .value = opts.texture };
    if (@hasField(T, "fill")) {
        if (@TypeOf(opts.fill) == paint.Fill) {
            local.paint_fill = .{ .value = opts.fill };
        } else if (@TypeOf(opts.fill) == paint.Color) {
            local.paint_fill = .{ .value = .{ .solid = opts.fill } };
        } else {
            local.fill = asColor(opts.fill);
        }
    }
    if (@hasField(T, "paint_fill")) local.paint_fill = .{ .value = opts.paint_fill };
    return PaintStyle.resolve(defaults orelse .{}, local);
}

/// `create()` inserts every returned id before any caller can use it. A
/// missing node is therefore an internal tree invariant violation, not an
/// optional API case; report it explicitly instead of using a bare unwrap.
fn nodeAfterCreate(self: *DrawCtx, id: FrameNodeId) *widget.WidgetNode {
    const items = self.tree.nodes.items;
    if (items.len > 0 and items[items.len - 1].id == id) {
        return &items[items.len - 1];
    }
    return self.tree.node(id) orelse @panic("DrawCtx: created node is missing");
}

fn seedSharedColumnStyleDirect(parent: *const widget.WidgetNode, child: *widget.WidgetNode) void {
    const columns = parent.shared_columns orelse return;
    if (parent.children.items.len == 0) return;
    const child_index = parent.children.items.len - 1;
    if (child_index >= columns.tracks.len) return;
    const track = columns.tracks[child_index];
    if (child.style.grow == 0) child.style.grow = track.grow;
    if (child.style.shrink == 1) child.style.shrink = track.shrink;
    if (std.meta.activeTag(child.style.flex_basis) == .auto) {
        child.style.flex_basis = track.flex_basis;
    }
    if (std.meta.activeTag(child.style.min_size.width) == .auto) {
        child.style.min_size.width = track.min_width;
    }
}

/// Set the generated button label's canonical flex bounds.
fn setButtonLabelSizing(self: *DrawCtx, id: FrameNodeId, opts: anytype) void {
    const node = nodeAfterCreate(self, id);
    const T = @TypeOf(opts);
    if (@hasField(T, "shrink")) node.style.shrink = opts.shrink;
    if (@hasField(T, "min_size")) {
        node.style.min_size.width = asDimensionSize(opts.min_size).width;
    }
    if (@hasField(T, "min_width")) {
        node.style.min_size.width = style.dimensionFrom(opts.min_width);
    }
}

/// Seed a direct row child from its parent's shared column track. Explicit
/// child Style values take precedence; tracks fill only automatic dimensions.
fn seedSharedColumnStyle(self: *DrawCtx, id: FrameNodeId) void {
    const child = nodeAfterCreate(self, id);
    if (child.parent == .root) return;
    const parent = self.tree.node(child.parent) orelse return;
    if (parent.kind != .row) return;
    const columns = parent.shared_columns orelse return;
    if (parent.children.items.len == 0) return;
    const child_index = parent.children.items.len - 1;
    if (child_index >= columns.tracks.len) return;
    const track = columns.tracks[child_index];
    if (child.style.grow == 0) child.style.grow = track.grow;
    if (child.style.shrink == 1) child.style.shrink = track.shrink;
    if (std.meta.activeTag(child.style.flex_basis) == .auto) {
        child.style.flex_basis = track.flex_basis;
    }
    if (std.meta.activeTag(child.style.min_size.width) == .auto) {
        child.style.min_size.width = track.min_width;
    }
}

fn setScrollOptions(self: *DrawCtx, id: FrameNodeId, opts: anytype) void {
    const T = @TypeOf(opts);
    if (!@hasField(T, "scroll_state")) return;
    const node = nodeAfterCreate(self, id);
    node.paint.clip = true;
    node.scroll = .{
        .state = opts.scroll_state,
        .axis = if (@hasField(T, "scroll_axis"))
            @as(ScrollAxis, opts.scroll_axis)
        else
            .vertical,
    };
}

fn setTextOptions(self: *DrawCtx, id: FrameNodeId, opts: anytype) void {
    const T = @TypeOf(opts);
    if (!@hasField(T, "text_overflow") and !@hasField(T, "max_width")) return;
    const node = nodeAfterCreate(self, id);
    if (@hasField(T, "text_overflow")) {
        node.text_overflow = @as(TextOverflow, opts.text_overflow);
    }
    if (@hasField(T, "max_width")) {
        if (asFixedLength(opts.max_width)) |max_width| node.text_max_width = max_width;
    }
}

fn asPaintSide(value: anytype) f32 {
    return switch (style.lengthPercentageAutoFrom(value)) {
        .auto, .percent => 0,
        .length => |length| length,
    };
}

fn asPaintSides(x: anytype) Sides {
    const T = @TypeOf(x);
    return .{
        .top = if (@hasField(T, "top")) asPaintSide(x.top) else 0,
        .right = if (@hasField(T, "right")) asPaintSide(x.right) else 0,
        .bottom = if (@hasField(T, "bottom")) asPaintSide(x.bottom) else 0,
        .left = if (@hasField(T, "left")) asPaintSide(x.left) else 0,
    };
}

fn asColor(x: anytype) [4]f32 {
    return .{ x[0], x[1], x[2], x[3] };
}
pub const ParentEntry = struct {
    id: FrameNodeId,
    index: u32,
};

pub const FramePhase = enum {
    drawing,
    measuring,
    late_build,
    /// Measuring and every bounded late subroot wave are done. The tree has
    /// its final measured geometry, and a caller with work between layout and
    /// paint — overlay placement — has not run it yet.
    measured,
    layout,
    prepaint,
    paint,
    semantics,
    done,
    /// A build or lifecycle hook failed; this frame cannot be published.
    failed,
};

pub const DrawCtx = struct {
    tree: *WidgetTree,
    /// The current frame arena's allocator. Components build per-frame
    /// strings here (std.fmt.allocPrint(ctx.arena, ...)) instead of keeping
    /// scratch buffers: the allocation lives as long as the arena, and the
    /// double-buffered arenas keep the previous frame's text readable.
    arena: std.mem.Allocator,
    /// The host surface for this frame. Null keeps direct-draw contexts
    /// independent of an App and lets callers select the layout surface.
    surface: ?widget.Size = null,
    /// Populated by App for frames; standalone draw contexts omit it.
    frame_info: ?FrameInfo = null,
    /// A model-backed root resolves its typed handle through this context.
    context: ?Context = null,
    /// Staged dense component owners for dispatch in this frame's tree.
    /// Direct single-frame draws may omit this map.
    registry: ?ComponentRegistry = null,
    /// Exact keyed component paths and stable widget handles for this attempt.
    widget_identities: ?*IdentityRegistry = null,
    /// Read-only during an attempted frame: starting a persistent animation
    /// here would publish it even if layout/GPU work later fails.
    animations: ?*const animation.Registry = null,
    /// Last frame's state directory (pointers into the OTHER arena, still
    /// alive while this frame builds) — the "stored version" for state().
    state_prev: ?*const StateDir = null,
    /// This frame's state directory (arena-allocated by App).
    state_cur: ?*StateDir = null,
    /// Active parent cursors. Storage is owned by the current frame arena.
    parent_stack: std.ArrayListUnmanaged(ParentEntry) = .empty,
    /// App's rollback ledger for scroll states discovered in late subroots.
    scroll_before_layout: ?*std.AutoHashMapUnmanaged(*ScrollState, ScrollState) = null,
    /// Defaults contributed by the component currently being drawn. A child
    /// scope replaces this value for its entire draw and is restored on return.
    component_defaults: ComponentDefaults = .{},
    /// Stable identity used for component-local state and registry lookup.
    component_identity: ComponentId = .root,
    /// Generation of the frame currently being drawn.
    frame_generation: u64 = 0,
    /// Component mounts staged for the current attempt, never the committed map.
    identity_map: ?*StableComponentRegistry = null,
    /// Last committed mounts, read only when deciding whether to reuse GPU state.
    committed_identity_map: ?*const StableComponentRegistry = null,
    /// Attached GPU endpoint used to mount newly discovered components.
    gpu_endpoint: ?*GpuEndpoint = null,
    /// The caller-owned overlay frame this frame's placements are registered
    /// into. App attaches the frame it was given; a direct draw context that
    /// owns a frame attaches it itself.
    overlay: ?*overlay.Frame = null,
    /// Frame-local widget owner used for event dispatch.
    component_id: FrameNodeId = .root,
    /// Nesting depth of pushClip()/popClip() calls. The clip rects
    /// themselves live in the tree's per-frame list (WidgetTree.
    /// clip_rects); this only balances the stack.
    clip_depth: u32 = 0,
    /// The staged frame is writable only during draw or an explicit late scope.
    phase: FramePhase = .drawing,
    late_nodes_remaining: usize = 0,

    /// Attach the frame this context registers placements into, replacing any
    /// previous one. A frame attached here is still owned by its caller.
    pub fn attachOverlay(self: *DrawCtx, frame: ?*overlay.Frame) void {
        self.overlay = frame;
    }

    /// The stable handle this frame's node was registered under, or null when
    /// the node carries no key. Placement is authored with handles, not dense
    /// ids, so a popup names a widget that outlives its frame.
    pub fn widgetIdOf(self: *const DrawCtx, id: FrameNodeId) ?WidgetId {
        const tree = self.tree;
        return tree.nodeConst(id).?.widget_id;
    }

    /// Register one frame-local placement. The content subtree must already
    /// be built: the frame resolves its box after layout, from the geometry
    /// this frame's nodes actually occupy. A duplicate content root is
    /// refused by name.
    pub fn place(self: *DrawCtx, record: overlay.Record) overlay.Error!void {
        const frame = self.overlay orelse return error.OverlayFrameNotAttached;
        try frame.add(record);
    }

    pub fn animationValue(self: *const DrawCtx, key: animation.Key) ?f32 {
        const registry = self.animations orelse return null;
        const frame = self.frame_info orelse return null;
        return registry.sample(key, frame.time_ms);
    }
    /// Create a node under the cursor. Container kinds do NOT descend here.
    /// Its typed Style and PaintStyle are resolved from the options; its
    /// `.rect` is the RELATIVE border box filled later by the layout dispatcher.
    ///
    /// Duplicate text options into the frame arena. Options commonly carry a
    /// plain slice (`.visual_label = "Volume"`), but accepting an optional
    /// slice too keeps the payload's nullable contract natural for callers.
    fn dupeOptionalText(self: *DrawCtx, value: anytype) !?[]const u8 {
        switch (@typeInfo(@TypeOf(value))) {
            .optional => {
                if (value) |text| return try self.arena.dupe(u8, text);
                return null;
            },
            else => return try self.arena.dupe(u8, value),
        }
    }

    fn setInteractionOptions(self: *DrawCtx, id: FrameNodeId, opts: anytype) void {
        const node = nodeAfterCreate(self, id);
        const T = @TypeOf(opts);
        if (@hasField(T, "disabled")) node.interaction.disabled = opts.disabled;
        if (@hasField(T, "focusable")) node.interaction.focusable = opts.focusable;
        if (@hasField(T, "tab_index")) node.interaction.tab_index = opts.tab_index;
        if (@hasField(T, "tab_group")) node.interaction.tab_group = opts.tab_group;
    }

    /// The two foreground layers a text-bearing kind carries. `kind` is the
    /// color the kind defaults to and `own` the one the caller named: only the
    /// second is authorship, and only a text-bearing kind has either. A
    /// separator's `.color` is its line, not its text, so it passes neither.
    const TextForeground = struct {
        kind: ?text_api.Color = null,
        own: ?text_api.Color = null,
    };

    /// Build this node's AUTHORED text override from its options and copy it
    /// into the frame arena. A node that authors nothing returns null, so a
    /// default unstyled container allocates no text record at all.
    ///
    /// Three layers, weakest first: the widget kind's own color, the
    /// component's declared text defaults, and the widget's own options. Only
    /// the last is authorship; the others are defaults and lose to anything an
    /// ancestor authored, which is what `TextInput` keeps them apart for.
    ///
    /// Every retained slice is copied into the frame arena AFTER the layers
    /// merged, so a shorthand, a full `text_style` and a component default
    /// never copy the same bytes twice, and an empty option allocates nothing.
    ///
    /// The returned record is the input, not the resolved request: inheritance
    /// is resolved once, immediately before layout.
    fn textInputFromOpts(
        self: *DrawCtx,
        opts: anytype,
        foreground: TextForeground,
    ) !?*text_api.TextInput {
        const T = @TypeOf(opts);
        var input: text_api.TextInput = .{};
        var authored = false;
        if (foreground.kind) |color| {
            input.kind_foreground = color;
            authored = true;
        }
        if (self.component_defaults.text) |defaults| {
            input.defaults = defaults;
            authored = true;
        }
        // The caller's own color is authorship, so `text_style.foreground`
        // still outranks it: it is applied first and layered over below.
        if (foreground.own) |color| {
            input.style.foreground = color;
            authored = true;
        }
        if (@hasField(T, "text_style")) {
            input.style = input.style.resolve(asTextStyleOverride(opts.text_style));
            authored = true;
        }
        if (@hasField(T, "font_size")) {
            input.style.font_fields.size = opts.font_size;
            authored = true;
        }
        if (@hasField(T, "font_family")) {
            input.style.font_fields.family = opts.font_family;
            // An authored family must be reachable: an inherited handle would
            // otherwise shadow it in every host's font resolution.
            if (!@hasField(T, "font_handle")) input.style.font_fields.handle = null;
            authored = true;
        }
        if (@hasField(T, "font_weight")) {
            input.style.font_fields.weight = opts.font_weight;
            authored = true;
        }
        if (@hasField(T, "font_style")) {
            input.style.font_fields.style = opts.font_style;
            authored = true;
        }
        if (@hasField(T, "font_features")) {
            input.style.font_fields.features = opts.font_features;
            authored = true;
        }
        if (@hasField(T, "font_fallback")) {
            input.style.font_fields.fallback = opts.font_fallback;
            authored = true;
        }
        if (@hasField(T, "text_ranges")) {
            input.extra = (input.extra orelse text_api.TextExtra{});
            input.extra.?.ranges = opts.text_ranges;
            authored = true;
        }
        if (@hasField(T, "paragraph")) {
            input.extra = (input.extra orelse text_api.TextExtra{});
            input.extra.?.paragraph = asParagraphOverride(opts.paragraph);
            authored = true;
        }
        if (@hasField(T, "missing_glyph")) {
            input.extra = (input.extra orelse text_api.TextExtra{});
            input.extra.?.missing_glyph = opts.missing_glyph;
            authored = true;
        }
        if (!authored) return null;
        try self.ownTextInput(&input);
        const record = try self.arena.create(text_api.TextInput);
        record.* = input;
        return record;
    }

    /// Copy every slice a retained text input still borrows into the frame
    /// arena. Callers hand over scratch buffers the next frame rewrites, and
    /// the input outlives this call, so a family's bytes, a feature list, a
    /// fallback list, an inline run override and a truncation suffix must all
    /// be frame-owned. One pass over the merged record, so nothing is copied
    /// twice and nothing is copied before it is known to be retained.
    fn ownTextInput(self: *DrawCtx, input: *text_api.TextInput) !void {
        try self.ownStyleOverride(&input.style);
        // A component's declared defaults can carry slices too, and they are
        // retained exactly like the widget's own options.
        try self.ownStyleOverride(&input.defaults);
        if (input.extra) |*extra| {
            if (extra.ranges.len != 0) {
                const ranges = try self.arena.dupe(text_api.StyledRange, extra.ranges);
                for (ranges) |*run| try self.ownStyleOverride(&run.override);
                extra.ranges = ranges;
            }
            if (extra.paragraph.truncate) |*truncate| {
                truncate.suffix = try self.ownSlice(u8, truncate.suffix);
            }
        }
    }

    /// A style layer's borrowed slices, including a whole `.font` request.
    fn ownStyleOverride(self: *DrawCtx, override: *text_api.TextStyleOverride) !void {
        if (override.font) |*font| {
            font.family = try self.ownSlice(u8, font.family);
            font.features = try self.ownSlice(text_api.Feature, font.features);
            font.fallback = try self.ownSlice(text_api.FontHandle, font.fallback);
        }
        const fields = &override.font_fields;
        if (fields.family) |family| fields.family = try self.ownSlice(u8, family);
        if (fields.features) |features| {
            fields.features = try self.ownSlice(text_api.Feature, features);
        }
        if (fields.fallback) |fallback| {
            fields.fallback = try self.ownSlice(text_api.FontHandle, fallback);
        }
    }

    /// An empty option names no bytes, and the shared empty literal is already
    /// frame-stable, so it never allocates. An authored empty slice still
    /// clears the inherited value: only the null-ness decides that.
    fn ownSlice(self: *DrawCtx, comptime T: type, slice: []const T) ![]const T {
        if (slice.len == 0) return &.{};
        const value = try self.arena.dupe(T, slice);
        return value;
    }

    /// A typed text option may be written as the exact record or as an
    /// anonymous literal of the same fields, so `.paragraph = .{ .wrap =
    /// .no_wrap }` names the same policy as the typed value.
    fn asTextStyleOverride(value: anytype) text_api.TextStyleOverride {
        return asTextRecord(text_api.TextStyleOverride, value);
    }

    fn asParagraphOverride(value: anytype) text_api.ParagraphOverride {
        return asTextRecord(text_api.ParagraphOverride, value);
    }

    /// Fill a typed text record field by field from a caller's value. Every
    /// field is assigned through the target's own type, so nested literals,
    /// enums and optionals coerce; a field the caller omitted keeps the
    /// record default. Nothing here validates a value.
    fn asTextRecord(comptime T: type, value: anytype) T {
        if (@TypeOf(value) == T) return value;
        const V = @TypeOf(value);
        if (@typeInfo(T) != .@"struct" or @typeInfo(V) != .@"struct") return value;
        var result: T = seedTextRecord(T);
        inline for (std.meta.fields(T)) |field| {
            if (!@hasField(V, field.name)) continue;
            @field(result, field.name) = asTextValue(field.type, @field(value, field.name));
        }
        comptime {
            // A field the record does not declare is a typo, not a default.
            for (@typeInfo(V).@"struct".fields) |field| {
                if (!@hasField(T, field.name)) {
                    @compileError("unknown text option field: " ++ field.name);
                }
            }
        }
        return result;
    }

    /// The starting point for the fields a literal leaves out. Every record in
    /// this seam defaults all of its own fields except the two named here, and
    /// their values are the zeroes a literal replaces.
    fn seedTextRecord(comptime T: type) T {
        return switch (T) {
            text_api.Truncation => .{ .suffix = "" },
            text_api.FontHandle => .{ .index = 0, .generation = 0 },
            else => .{},
        };
    }

    /// One typed-text field. An optional or a tagged union naming a record is
    /// filled the same way; anything else relies on the assignment's own
    /// coercion into the target field type.
    fn asTextValue(comptime T: type, value: anytype) T {
        if (@TypeOf(value) == T) return value;
        const V = @TypeOf(value);
        if (@typeInfo(V) != .@"struct") return value;
        switch (@typeInfo(T)) {
            .@"struct" => return asTextRecord(T, value),
            .optional => {
                const child = std.meta.Child(T);
                if (@typeInfo(child) == .@"struct") return @as(T, asTextRecord(child, value));
            },
            .@"union" => {
                inline for (@typeInfo(T).@"union".fields) |field| {
                    if (!@hasField(V, field.name)) continue;
                    if (field.type == void) return @field(T, field.name);
                    // SAFETY: the write below picks the union's active field, so no other field is read.
                    var result: T = undefined;
                    @field(result, field.name) = asTextValue(field.type, @field(value, field.name));
                    return result;
                }
                return value;
            },
            else => {},
        }
        return value;
    }

    /// The color a widget kind implies for its own caption. This is a DEFAULT,
    /// not authorship: it must never shadow a foreground an ancestor authored,
    /// and an explicit option or `text_style.foreground` outranks it.
    fn kindDefaultForeground(kind: WidgetKind) ?text_api.Color {
        return switch (kind) {
            .label => |value| value.color,
            .button => |value| value.color,
            .checkbox => |value| value.color,
            .switch_control => |value| value.color,
            .radio => |value| value.color,
            .progress => |value| value.color,
            .slider => |value| value.color,
            else => null,
        };
    }

    /// The authored text input for a node, with the two foreground layers its
    /// kind and options imply. A node that authors no text at all gets null.
    fn textInputFor(self: *DrawCtx, kind: WidgetKind, opts: anytype) !?*text_api.TextInput {
        const T = @TypeOf(opts);
        return self.textInputFromOpts(opts, .{
            .kind = kindDefaultForeground(kind),
            .own = if (@hasField(T, "color")) asColor(opts.color) else null,
        });
    }

    fn interactiveWidgetId(self: *DrawCtx, opts: anytype) !?WidgetId {
        if (self.phase != .drawing and self.phase != .late_build) return error.PhaseReentry;
        const identities = self.widget_identities orelse return null;
        if (@hasField(@TypeOf(opts), "key")) {
            const widget_id = try identities.widget(self.component_identity, asComponentKey(opts.key));
            return widget_id;
        }
        return error.MissingWidgetKey;
    }

    fn bindOptionalWidgetId(self: *DrawCtx, id: FrameNodeId, opts: anytype) !void {
        if (@hasField(@TypeOf(opts), "key")) {
            if (try self.interactiveWidgetId(opts)) |stable| {
                try self.tree.bindWidget(id, stable);
            }
        }
    }

    pub fn create(
        self: *DrawCtx,
        kind: WidgetKind,
        resolved_style: Style,
        resolved_paint: PaintStyle,
        text_input: ?*const text_api.TextInput,
    ) !FrameNodeId {
        if (self.phase != .drawing and self.phase != .late_build) return error.PhaseReentry;
        if (self.phase == .late_build) {
            if (self.late_nodes_remaining == 0) return error.LateSubrootLimit;
            self.late_nodes_remaining -= 1;
        }
        const id: FrameNodeId = @enumFromInt(self.tree.next_id);
        self.tree.next_id += 1;

        const parent_entry: ?ParentEntry = if (self.parent_stack.items.len == 0)
            null
        else
            self.parent_stack.items[self.parent_stack.items.len - 1];
        const parent_id = if (parent_entry) |p| p.id else FrameNodeId.root;
        const node: widget.WidgetNode = .{
            .id = id,
            .kind = kind,
            .parent = parent_id,
            .owner = self.component_id,
            .style = resolved_style,
            .paint = resolved_paint,
            .text_input = text_input,
        };
        try self.tree.appendNode(node);
        if (parent_entry) |parent| {
            if (parent.index < self.tree.nodes.items.len and
                self.tree.nodes.items[parent.index].id == parent.id)
            {
                const parent_node = &self.tree.nodes.items[parent.index];
                try parent_node.children.append(self.tree.allocator, id);
                if (parent_node.kind == .row and parent_node.shared_columns != null) {
                    seedSharedColumnStyleDirect(parent_node, &self.tree.nodes.items[self.tree.nodes.items.len - 1]);
                }
            } else {
                try self.tree.appendChild(parent.id, id);
                seedSharedColumnStyle(self, id);
            }
        }
        return id;
    }

    /// Container: create + descend. The cursor becomes the new container.
    /// `gap` comes from `opts.gap` when present, else 0; `justify` and
    /// typed Style's padding/border define where the canonical dispatcher
    /// places children.
    pub fn column(self: *DrawCtx, opts: anytype) !FrameNodeId {
        const resolved_style = styleFromOpts(opts, self.component_defaults.style, .column);
        try self.ensureParentCursorCapacity();
        const id = try self.create(
            .{ .column = .{} },
            resolved_style,
            paintStyleFromOpts(opts, self.component_defaults.paint),
            try self.textInputFromOpts(opts, .{}),
        );
        try self.bindOptionalWidgetId(id, opts);
        setScrollOptions(self, id, opts);
        self.descend(id);
        return id;
    }
    /// Container: create + descend (row variant). See `column`.
    pub fn row(self: *DrawCtx, opts: anytype) !FrameNodeId {
        const resolved_style = styleFromOpts(opts, self.component_defaults.style, .row);
        try self.ensureParentCursorCapacity();
        const id = try self.create(
            .{ .row = .{} },
            resolved_style,
            paintStyleFromOpts(opts, self.component_defaults.paint),
            try self.textInputFromOpts(opts, .{}),
        );
        if (@hasField(@TypeOf(opts), "columns")) {
            nodeAfterCreate(self, id).shared_columns = opts.columns;
        }
        try self.bindOptionalWidgetId(id, opts);
        setScrollOptions(self, id, opts);
        self.descend(id);
        return id;
    }
    /// Grid container: it uses the same tree container kind as column, but
    /// dispatches to the bounded grid algorithm through Style.display.
    pub fn grid(self: *DrawCtx, opts: anytype) !FrameNodeId {
        var resolved_style = styleFromOpts(opts, self.component_defaults.style, .column);
        resolved_style.display = .grid;
        const T = @TypeOf(opts);
        if (!@hasField(T, "grid_justify_content") and
            @hasField(T, "justify") and
            resolved_style.grid_justify_content == .normal)
        {
            resolved_style.grid_justify_content = resolved_style.justify;
        }
        if (!@hasField(T, "grid_align_content") and @hasField(T, "align_content"))
            resolved_style.grid_align_content = resolved_style.align_content;
        if (!@hasField(T, "grid_justify_items") and @hasField(T, "align"))
            resolved_style.grid_justify_items = resolved_style.@"align";
        if (!@hasField(T, "grid_align_items") and @hasField(T, "align"))
            resolved_style.grid_align_items = resolved_style.@"align";
        try self.ensureParentCursorCapacity();
        const id = try self.create(
            .{ .column = .{} },
            resolved_style,
            paintStyleFromOpts(opts, self.component_defaults.paint),
            try self.textInputFromOpts(opts, .{}),
        );
        try self.bindOptionalWidgetId(id, opts);
        setScrollOptions(self, id, opts);
        self.descend(id);
        return id;
    }

    /// Add one custom leaf whose payload and phase state live in this frame.
    /// Intrinsic measurement is read-only and opts use normal typed style.
    pub fn elementLeaf(self: *DrawCtx, comptime T: type, value: T, opts: anytype) !FrameNodeId {
        if (self.phase != .drawing and self.phase != .late_build) return error.PhaseReentry;
        const widget_id = if (@hasField(@TypeOf(opts), "key"))
            try self.interactiveWidgetId(opts)
        else
            null;
        const frame = try element.make(T, self.arena, value, .none);
        const id = try self.create(
            .{ .element = frame },
            styleFromOpts(opts, self.component_defaults.style, .column),
            paintStyleFromOpts(opts, self.component_defaults.paint),
            try self.textInputFromOpts(opts, .{}),
        );
        if (widget_id) |stable_id| try self.tree.bindWidget(id, stable_id);
        self.setInteractionOptions(id, opts);
        setScrollOptions(self, id, opts);
        return id;
    }

    /// Custom containers use the same block/flex/grid dispatch as built-ins.
    /// A query/list late scope may append children only after its first layout.
    pub fn elementContainer(self: *DrawCtx, comptime T: type, value: T, opts: anytype) !FrameNodeId {
        if (self.phase != .drawing and self.phase != .late_build) return error.PhaseReentry;
        const scope: element.LateScope = if (@hasField(@TypeOf(opts), "late_scope"))
            opts.late_scope
        else
            .none;
        if (self.phase == .late_build and scope != .none and
            scope != .query and scope != .list) return error.PhaseReentry;
        const widget_id = if (@hasField(@TypeOf(opts), "key"))
            try self.interactiveWidgetId(opts)
        else
            null;
        const frame = try element.make(T, self.arena, value, scope);
        if (scope != .none) frame.component_scope = .{
            .owner = self.component_id,
            .identity = self.component_identity,
            .defaults = self.component_defaults,
        };
        try self.ensureParentCursorCapacity();
        const id = try self.create(
            .{ .element = frame },
            styleFromOpts(opts, self.component_defaults.style, .column),
            paintStyleFromOpts(opts, self.component_defaults.paint),
            try self.textInputFromOpts(opts, .{}),
        );
        if (widget_id) |stable_id| try self.tree.bindWidget(id, stable_id);
        self.setInteractionOptions(id, opts);
        setScrollOptions(self, id, opts);
        self.descend(id);
        return id;
    }

    /// Leave the current container, restoring the cursor to the enclosing
    /// parent. Also restores the post-order invariant: the container was
    /// appended before its children, so move it past them, to the end.
    pub fn pop(self: *DrawCtx) void {
        if (self.phase != .drawing and self.phase != .late_build) {
            self.phase = .failed;
            return;
        }
        if (self.phase == .late_build and self.parent_stack.items.len == 1) {
            self.phase = .failed;
            return;
        }
        std.debug.assert(self.parent_stack.items.len > 0);
        const entry = self.parent_stack.pop().?;

        const index: usize = if (entry.index < self.tree.nodes.items.len and
            self.tree.nodes.items[entry.index].id == entry.id)
            entry.index
        else
            self.tree.nodeIndex(entry.id) orelse @panic("DrawCtx: container node missing on pop");
        self.tree.moveNodeToEnd(index);
    }

    /// A static text leaf. The text is DUPLICATED into the frame arena:
    /// components may hand over scratch buffers that get rewritten next
    /// frame (e.g. bufPrint results) — the tree must own a stable copy so
    /// the double-buffered previous frame keeps its original text for
    /// id-keyed dirty diffing.
    pub fn label(self: *DrawCtx, opts: anytype) !FrameNodeId {
        const text = try self.arena.dupe(u8, opts.text);
        var kind: WidgetKind = .{ .label = .{ .text = text } };
        if (@hasField(@TypeOf(opts), "color")) kind.label.color = asColor(opts.color);
        const id = try self.create(
            kind,
            styleFromOpts(opts, self.component_defaults.style, .column),
            paintStyleFromOpts(opts, self.component_defaults.paint),
            try self.textInputFor(kind, opts),
        );
        try self.bindOptionalWidgetId(id, opts);
        setTextOptions(self, id, opts);
        return id;
    }

    /// A clickable button. `owner` binds the click to the component that
    /// created it (`component_id`); `on_click` is wrapped into a type-erased
    /// callback when `opts.on_click` is present. Label text is duplicated
    /// into the frame arena (see label()).
    ///
    /// The label is a CHILD label node, centered by the button's typed layout
    /// style — the text pipeline (measure + emission + color) is shared with
    /// plain labels, one path instead of a second kind arm in the
    /// renderer. The kind's `label` field still carries the text (the
    /// click-injection + hit-testing scan it).
    pub fn button(self: *DrawCtx, opts: anytype) !FrameNodeId {
        const widget_id = try self.interactiveWidgetId(opts);
        var on_click: ?*const fn (*anyopaque) void = null;
        var user_callback: ?callback.UserCallback = null;
        const T = @TypeOf(opts);
        if (@hasField(T, "on_click")) on_click = callback.wrap(opts.on_click);
        if (@hasField(T, "on_click_with_data")) user_callback = opts.on_click_with_data;

        const label_copy = try self.arena.dupe(u8, opts.label);
        var visual_label: ?[]const u8 = null;
        if (@hasField(T, "visual_label")) {
            visual_label = try self.dupeOptionalText(opts.visual_label);
        }
        var accessible_label: ?[]const u8 = null;
        if (@hasField(T, "accessible_label")) {
            accessible_label = try self.dupeOptionalText(opts.accessible_label);
        }
        var kind: WidgetKind = .{ .button = .{
            .label = label_copy,
            .visual_label = visual_label,
            .accessible_label = accessible_label,
            .on_click = on_click,
            .owner = self.component_id,
            .user_callback = user_callback,
        } };
        if (@hasField(T, "icon")) kind.button.icon = opts.icon;
        if (@hasField(T, "color")) kind.button.color = asColor(opts.color);
        const visible_label = widget.buttonVisualLabel(kind);
        if (visible_label.len != 0) try self.ensureParentCursorCapacity();
        // The button carries the authored text input; its child label inherits
        // that resolved request, so one authored override drives the caption.
        const text_input = try self.textInputFor(kind, opts);
        const id = try self.create(
            kind,
            styleFromOpts(opts, self.component_defaults.style, .row),
            paintStyleFromOpts(opts, self.component_defaults.paint),
            text_input,
        );
        if (widget_id) |stable_id| try self.tree.bindWidget(id, stable_id);
        self.setInteractionOptions(id, opts);
        setTextOptions(self, id, opts);

        // Buttons center generated labels unless the caller overrides either
        // layout axis independently.
        const node = nodeAfterCreate(self, id);
        if (self.component_defaults.style == null) {
            node.style.justify = .center;
            node.style.@"align" = .center;
        }
        if (@hasField(T, "justify")) node.style.justify = @as(Justify, opts.justify);
        if (@hasField(T, "align")) node.style.@"align" = @as(Align, opts.@"align");

        if (visible_label.len != 0) {
            self.descend(id);
            // The caption inherits the button's own resolved request, so the
            // color is named only when the caller did: the kind's own color is
            // a default, and passing it as an option would make an inherited
            // container foreground unreachable.
            const label_id = if (@hasField(T, "color"))
                try self.label(.{ .text = visible_label, .color = kind.button.color })
            else
                try self.label(.{ .text = visible_label });
            setButtonLabelSizing(self, label_id, opts);
            setTextOptions(self, label_id, opts);
            if (@hasField(T, "text_overflow")) {
                const overflow: TextOverflow = opts.text_overflow;
                if (overflow == .ellipsis or overflow == .clip) {
                    if (@hasField(T, "max_width")) {
                        if (asFixedLength(opts.max_width)) |max_width| {
                            if (max_width > 0) {
                                // A bounded button label may shrink to its parent's
                                // final content box instead of its natural width.
                                nodeAfterCreate(self, label_id).style.min_size.width = .{
                                    .length = 0,
                                };
                            }
                        }
                    }
                }
            }
            self.pop();
        }
        return id;
    }

    /// A slider bound to a live f32. Label text is duplicated into the
    /// frame arena (see label()).
    pub fn slider(self: *DrawCtx, opts: anytype) !FrameNodeId {
        const widget_id = try self.interactiveWidgetId(opts);
        const T = @TypeOf(opts);
        const label_copy = try self.arena.dupe(u8, opts.label);
        var visual_label: ?[]const u8 = null;
        if (@hasField(T, "visual_label")) {
            visual_label = try self.dupeOptionalText(opts.visual_label);
        }
        var kind: WidgetKind = .{ .slider = .{
            .label = label_copy,
            .visual_label = visual_label,
            .value = opts.value,
            .min = opts.min,
            .max = opts.max,
        } };
        if (@hasField(T, "color")) kind.slider.color = asColor(opts.color);
        const id = try self.create(
            kind,
            styleFromOpts(opts, self.component_defaults.style, .column),
            paintStyleFromOpts(opts, self.component_defaults.paint),
            try self.textInputFor(kind, opts),
        );
        if (widget_id) |stable_id| try self.tree.bindWidget(id, stable_id);
        // The scene paints a slider's caption over its own content box, so the
        // node's text options are what bound and truncate it. Without them the
        // `text_overflow` and `max_width` a caller wrote would be accepted and
        // ignored, and a caption wider than its control would wrap onto a
        // second baseline instead of truncating.
        setTextOptions(self, id, opts);
        self.setInteractionOptions(id, opts);
        return id;
    }
    /// A checkbox bound to caller-owned state. `value` must outlive both the
    /// current and previous frame trees that retain this node. The label is
    /// copied once into the frame arena; the control remains a leaf.
    pub fn checkbox(self: *DrawCtx, opts: anytype) !FrameNodeId {
        const widget_id = try self.interactiveWidgetId(opts);
        const label_copy = try self.arena.dupe(u8, opts.label);
        var kind: WidgetKind = .{ .checkbox = .{
            .label = label_copy,
            .value = opts.value,
        } };
        if (@hasField(@TypeOf(opts), "color")) kind.checkbox.color = asColor(opts.color);
        const id = try self.create(
            kind,
            styleFromOpts(opts, self.component_defaults.style, .row),
            paintStyleFromOpts(opts, self.component_defaults.paint),
            try self.textInputFor(kind, opts),
        );
        if (widget_id) |stable_id| try self.tree.bindWidget(id, stable_id);
        self.setInteractionOptions(id, opts);
        setTextOptions(self, id, opts);
        return id;
    }

    /// A switch bound to caller-owned state. `value` must outlive both the
    /// current and previous frame trees that retain this node. The label is
    /// copied once into the frame arena; the control remains a leaf.
    pub fn switchControl(self: *DrawCtx, opts: anytype) !FrameNodeId {
        const widget_id = try self.interactiveWidgetId(opts);
        const label_copy = try self.arena.dupe(u8, opts.label);
        var kind: WidgetKind = .{ .switch_control = .{
            .label = label_copy,
            .value = opts.value,
        } };
        if (@hasField(@TypeOf(opts), "color")) kind.switch_control.color = asColor(opts.color);
        const id = try self.create(
            kind,
            styleFromOpts(opts, self.component_defaults.style, .row),
            paintStyleFromOpts(opts, self.component_defaults.paint),
            try self.textInputFor(kind, opts),
        );
        if (widget_id) |stable_id| try self.tree.bindWidget(id, stable_id);
        self.setInteractionOptions(id, opts);
        setTextOptions(self, id, opts);
        return id;
    }

    /// A radio option bound to caller-owned state. `selected` must outlive
    /// both the current and previous frame trees that retain this node. The
    /// label is copied once into the frame arena; the control remains a leaf.
    pub fn radio(self: *DrawCtx, opts: anytype) !FrameNodeId {
        const widget_id = try self.interactiveWidgetId(opts);
        const label_copy = try self.arena.dupe(u8, opts.label);
        var kind: WidgetKind = .{ .radio = .{
            .label = label_copy,
            .selected = opts.selected,
            .option = opts.option,
        } };
        if (@hasField(@TypeOf(opts), "color")) kind.radio.color = asColor(opts.color);
        const id = try self.create(
            kind,
            styleFromOpts(opts, self.component_defaults.style, .row),
            paintStyleFromOpts(opts, self.component_defaults.paint),
            try self.textInputFor(kind, opts),
        );
        if (widget_id) |stable_id| try self.tree.bindWidget(id, stable_id);
        self.setInteractionOptions(id, opts);
        setTextOptions(self, id, opts);
        return id;
    }

    /// A determinate progress leaf. Its optional label defaults to empty.
    /// Values and bounds must be finite, with `max > min`.
    /// An optional `key` supplies stable identity when an App builds this leaf.
    pub fn progress(self: *DrawCtx, opts: anytype) !FrameNodeId {
        const T = @TypeOf(opts);
        const value: f32 = opts.value;
        const min: f32 = opts.min;
        const max: f32 = opts.max;
        if (!std.math.isFinite(value) or
            !std.math.isFinite(min) or
            !std.math.isFinite(max) or
            max <= min)
        {
            return error.InvalidStyle;
        }
        const label_copy: []const u8 = if (@hasField(T, "label"))
            (try self.dupeOptionalText(opts.label)) orelse ""
        else
            "";
        var kind: WidgetKind = .{ .progress = .{
            .label = label_copy,
            .value = value,
            .min = min,
            .max = max,
        } };
        if (@hasField(T, "color")) kind.progress.color = asColor(opts.color);
        const id = try self.create(
            kind,
            styleFromOpts(opts, self.component_defaults.style, .column),
            paintStyleFromOpts(opts, self.component_defaults.paint),
            try self.textInputFor(kind, opts),
        );
        try self.bindOptionalWidgetId(id, opts);
        setTextOptions(self, id, opts);
        return id;
    }

    /// An inert separator leaf. Its thickness defaults to 1px and must be
    /// finite and positive.
    pub fn separator(self: *DrawCtx, opts: anytype) !FrameNodeId {
        const T = @TypeOf(opts);
        const axis: widget.SeparatorAxis = if (@hasField(T, "axis"))
            @as(widget.SeparatorAxis, opts.axis)
        else
            .horizontal;
        const thickness: f32 = if (@hasField(T, "thickness"))
            opts.thickness
        else
            1;
        if (!std.math.isFinite(thickness) or thickness <= 0) return error.InvalidStyle;
        var kind: WidgetKind = .{ .separator = .{
            .axis = axis,
            .thickness = thickness,
        } };
        if (@hasField(T, "color")) kind.separator.color = asColor(opts.color);
        return self.create(
            kind,
            styleFromOpts(opts, self.component_defaults.style, .column),
            paintStyleFromOpts(opts, self.component_defaults.paint),
            try self.textInputFromOpts(opts, .{}),
        );
    }

    /// An empty spacer of the given size (`opts.size`, default 0). Style
    /// and PaintStyle options are retained even though the size rules layout.
    pub fn spacer(self: *DrawCtx, opts: anytype) !FrameNodeId {
        var size: f32 = 0;
        if (@hasField(@TypeOf(opts), "size")) size = opts.size;
        const id = try self.create(
            .{ .spacer = .{ .size = size } },
            styleFromOpts(opts, self.component_defaults.style, .column),
            paintStyleFromOpts(opts, self.component_defaults.paint),
            try self.textInputFromOpts(opts, .{}),
        );
        return id;
    }
    /// Push a clip rect onto the frame's clip-rect list and return its
    /// stable id. A full GPU clip buffer is an explicit error; rendering
    /// without the requested clip would expose content outside its bounds.
    /// The `.clip` PaintStyle option wires the declarative path
    /// automatically. This programmatic API serves widgets that know their
    /// rect at draw time, such as scroll containers. popClip() balances the
    /// push. The list is append-only for the frame.
    pub fn pushClip(self: *DrawCtx, x: f32, y: f32, w: f32, h: f32) !u32 {
        if (self.phase != .drawing and self.phase != .late_build) return error.PhaseReentry;
        const id = try self.tree.pushClipRect(.{ .x = x, .y = y, .w = w, .h = h });
        self.clip_depth += 1;
        return id;
    }

    /// Balance a pushClip(): restores the clip nesting depth. Rects are
    /// never removed from the list (ids must stay stable), so pop only
    /// tracks the stack.
    pub fn popClip(self: *DrawCtx) void {
        if (self.phase != .drawing and self.phase != .late_build) {
            self.phase = .failed;
            return;
        }
        std.debug.assert(self.clip_depth > 0);
        self.clip_depth -= 1;
    }

    /// Nest a sub-component with a stable key. The key is combined with the
    /// current component identity, so sibling identities are deterministic
    pub fn component(
        self: *DrawCtx,
        comptime T: type,
        options: struct { key: ComponentKey },
        ptr: *T,
    ) !void {
        if (self.phase != .drawing and self.phase != .late_build) return error.PhaseReentry;
        const child_identity = if (self.widget_identities) |identities|
            try identities.component(self.component_identity, options.key)
        else
            ComponentId.child(self.component_identity, options.key);
        const child_component = Component.make(T, ptr);
        if (self.identity_map) |identity_map| {
            const entry = try identity_map.map.getOrPut(identity_map.gpa, child_identity);
            if (entry.found_existing) return error.DuplicateComponentIdentity;

            var reused_gpu = false;
            if (self.committed_identity_map) |previous_map| {
                if (previous_map.map.get(child_identity)) |previous| {
                    reused_gpu = previous.gpu_initialized and
                        previous.component.ptr == child_component.ptr and
                        previous.component.vtable == child_component.vtable;
                }
            }
            entry.value_ptr.* = .{
                .component = child_component,
                .last_seen_frame = self.frame_generation,
                .gpu_initialized = reused_gpu,
            };
            if (!reused_gpu) {
                if (self.gpu_endpoint) |endpoint| {
                    // A failed hook can leave resources behind. Clean them
                    // here because the root may catch the error and commit.
                    entry.value_ptr.gpu_initialized = true;
                    if (child_component.vtable.init_gpu) |init_gpu| {
                        init_gpu(child_component.ptr, endpoint) catch |err| {
                            if (child_component.vtable.deinit_gpu) |deinit_gpu| {
                                endpoint.waitForRetirement() catch
                                    @panic("GPU retirement wait failed during child init");
                                deinit_gpu(child_component.ptr, endpoint);
                            }
                            entry.value_ptr.gpu_initialized = false;
                            return err;
                        };
                    }
                }
            }
        }

        const saved_identity = self.component_identity;
        const saved_owner = self.component_id;
        const saved_defaults = self.component_defaults;
        defer {
            self.component_identity = saved_identity;
            self.component_id = saved_owner;
            self.component_defaults = saved_defaults;
        }
        self.component_identity = child_identity;
        self.component_id = @enumFromInt(self.tree.next_id);
        self.tree.next_id += 1;
        if (self.registry) |reg| {
            try reg.map.put(reg.gpa, self.component_id, child_component);
        }
        self.component_defaults = child_component.defaults();
        try child_component.vtable.draw(ptr, self);
    }

    /// useState-like inter-frame transient state, component-local: `name`
    /// is scoped to the current stable component identity, so sibling
    /// insertion and widget-node renumbering do not move the stored value.
    /// Returns a pointer to a FRESH T in the frame arena, valid until reset.
    pub fn state(self: *DrawCtx, comptime T: type, name: []const u8, init: T) !*T {
        if (self.phase != .drawing and self.phase != .late_build) return error.PhaseReentry;
        const key: StateKey = .{
            .component = self.component_identity,
            .name_hash = stateHash(name),
        };
        const cur = self.state_cur orelse {
            // No state mode (single-frame tests): a plain init copy.
            const p = try self.arena.create(T);
            p.* = init;
            return p;
        };
        const value = try cur.getOrCreate(T, self.arena, self.state_prev, key, name, init);
        return value;
    }

    /// Reserve cursor storage before the caller mutates the tree.
    fn ensureParentCursorCapacity(self: *DrawCtx) !void {
        try self.parent_stack.ensureUnusedCapacity(self.arena, 1);
    }

    /// Cursor descends into a container: it becomes the parent for nodes
    /// created until the matching `pop()`.
    fn descend(self: *DrawCtx, id: FrameNodeId) void {
        const index: u32 = @intCast(self.tree.nodes.items.len - 1);
        std.debug.assert(self.tree.nodes.items[index].id == id);
        self.parent_stack.appendAssumeCapacity(.{ .id = id, .index = index });
    }
};

test "api-w02 DrawCtx requires keys and rejects duplicate interactive identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var identities = IdentityRegistry.init(std.testing.allocator);
    defer identities.deinit();
    try identities.beginFrame();
    defer identities.abortFrame();

    var ctx: DrawCtx = .{
        .tree = &tree,
        .arena = arena.allocator(),
        .widget_identities = &identities,
    };
    var value: f32 = 0.5;
    var checked = false;
    var selected: ?u32 = null;
    try std.testing.expectError(error.MissingWidgetKey, ctx.button(.{ .label = "first" }));
    try std.testing.expectError(error.MissingWidgetKey, ctx.slider(.{
        .label = "level",
        .value = &value,
        .min = 0,
        .max = 1,
    }));
    try std.testing.expectError(error.MissingWidgetKey, ctx.checkbox(.{
        .label = "check",
        .value = &checked,
    }));
    try std.testing.expectError(error.MissingWidgetKey, ctx.switchControl(.{
        .label = "switch",
        .value = &checked,
    }));
    try std.testing.expectError(error.MissingWidgetKey, ctx.radio(.{
        .label = "choose",
        .selected = &selected,
        .option = 1,
    }));
    try std.testing.expectEqual(@as(usize, 0), tree.nodes.items.len);

    const button_id = try ctx.button(.{
        .key = .{ .static = "action" },
        .label = "first",
    });
    const widget_id = tree.node(button_id).?.widget_id orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(button_id, tree.frameNode(widget_id).?);
    const generated_label_id = tree.node(button_id).?.children.items[0];
    try std.testing.expect(tree.node(generated_label_id).?.widget_id == null);
    const node_count = tree.nodes.items.len;
    try std.testing.expectError(error.DuplicateWidgetKey, ctx.slider(.{
        .key = .{ .static = "action" },
        .label = "different control",
        .value = &value,
        .min = 0,
        .max = 1,
    }));
    try std.testing.expectEqual(node_count, tree.nodes.items.len);
    try std.testing.expectEqual(button_id, tree.frameNode(widget_id).?);
    const slider_id = try ctx.slider(.{
        .key = .{ .u64 = 42 },
        .label = "level",
        .value = &value,
        .min = 0,
        .max = 1,
    });
    const checkbox_id = try ctx.checkbox(.{
        .key = .{ .static = "check" },
        .label = "check",
        .value = &checked,
    });
    const switch_id = try ctx.switchControl(.{
        .key = .{ .static = "switch" },
        .label = "switch",
        .value = &checked,
    });
    const radio_id = try ctx.radio(.{
        .key = .{ .static = "radio" },
        .label = "radio",
        .selected = &selected,
        .option = 1,
    });
    for ([_]FrameNodeId{ button_id, slider_id, checkbox_id, switch_id, radio_id }) |id| {
        const stable_id = tree.node(id).?.widget_id orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(id, tree.frameNode(stable_id).?);
    }

    const Nested = struct {
        const Self = @This();
        button_id: FrameNodeId = .root,

        pub fn draw(self: *Self, nested_ctx: *DrawCtx) !void {
            self.button_id = try nested_ctx.button(.{
                .key = .{ .static = "action" },
                .label = "same key in another scope",
            });
        }
    };
    var nested: Nested = .{};
    try ctx.component(Nested, .{ .key = .{ .static = "nested" } }, &nested);
    const nested_widget = tree.node(nested.button_id).?.widget_id orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(!widget_id.eql(nested_widget));
    try std.testing.expectEqual(nested.button_id, tree.frameNode(nested_widget).?);
}

test "api-w02 DrawCtx stages mounts without changing committed GPU owners" {
    const Child = struct {
        const Self = @This();
        tag: u8,
        pub fn draw(_: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.label(.{ .text = "child" });
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var identities = IdentityRegistry.init(std.testing.allocator);
    defer identities.deinit();
    try identities.beginFrame();
    defer identities.abortFrame();
    var committed = StableComponentRegistry.init(std.testing.allocator);
    defer committed.deinit();
    var staged = StableComponentRegistry.init(arena.allocator());
    defer staged.deinit();
    var owners: std.AutoHashMapUnmanaged(FrameNodeId, Component) = .empty;
    defer owners.deinit(arena.allocator());

    var retained: Child = .{ .tag = 1 };
    var retired: Child = .{ .tag = 2 };
    var replacement: Child = .{ .tag = 3 };
    const retained_id = ComponentId.child(.root, .{ .static = "retained" });
    const replaced_id = ComponentId.child(.root, .{ .static = "replaced" });
    try committed.map.put(committed.gpa, retained_id, .{
        .component = Component.make(Child, &retained),
        .last_seen_frame = 1,
        .gpu_initialized = true,
    });
    try committed.map.put(committed.gpa, replaced_id, .{
        .component = Component.make(Child, &retired),
        .last_seen_frame = 1,
        .gpu_initialized = true,
    });
    var ctx: DrawCtx = .{
        .tree = &tree,
        .arena = arena.allocator(),
        .widget_identities = &identities,
        .identity_map = &staged,
        .committed_identity_map = &committed,
        .registry = .{ .map = &owners, .gpa = arena.allocator() },
        .frame_generation = 2,
    };
    try ctx.component(Child, .{ .key = .{ .static = "retained" } }, &retained);
    try ctx.component(Child, .{ .key = .{ .static = "replaced" } }, &replacement);
    try std.testing.expect(staged.map.get(retained_id).?.gpu_initialized);
    try std.testing.expect(!staged.map.get(replaced_id).?.gpu_initialized);
    try std.testing.expect(committed.map.get(replaced_id).?.component.ptr == @as(*anyopaque, @ptrCast(&retired)));
    try std.testing.expect(committed.map.get(retained_id).?.component.ptr == @as(*anyopaque, @ptrCast(&retained)));
    try std.testing.expectEqual(@as(usize, 2), owners.count());
    try std.testing.expectError(error.DuplicateComponentIdentity, ctx.component(
        Child,
        .{ .key = .{ .static = "retained" } },
        &retained,
    ));
    try std.testing.expectEqual(@as(usize, 2), owners.count());
}

test "api-w02 caught GPU init error cleans failed mounts without reusing them" {
    // A root can catch a failed child mount and still publish its fallback frame.
    const App = @import("app.zig").App;
    const Wait = struct {
        var calls: usize = 0;
        fn complete() void {
            calls += 1;
        }
    };
    const Child = struct {
        const Self = @This();
        text: []const u8,
        fail_init: bool = false,
        inits: usize = 0,
        deinits: usize = 0,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.label(.{ .text = self.text });
        }
        pub fn initGpu(self: *Self, _: *GpuEndpoint) !void {
            self.inits += 1;
            if (self.fail_init) return error.StagedInitFailure;
        }
        pub fn deinitGpu(self: *Self, _: *GpuEndpoint) void {
            self.deinits += 1;
        }
    };
    const Root = struct {
        const Self = @This();
        committed: Child = .{ .text = "committed" },
        candidate: Child = .{ .text = "ready", .fail_init = true },
        replace: bool = false,
        propagate_failure: bool = false,
        caught: usize = 0,
        old_retired_during_draw: bool = false,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            const child = if (self.replace) &self.candidate else &self.committed;
            ctx.component(Child, .{ .key = .{ .static = "slot" } }, child) catch |err| {
                if (err != error.StagedInitFailure) return err;
                self.caught += 1;
                self.old_retired_during_draw = self.committed.deinits != 0;
                if (self.propagate_failure) return err;
                _ = try ctx.label(.{ .text = "fallback" });
            };
        }
    };

    Wait.calls = 0;
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var root: Root = .{};
    try app.mountRoot(Root, &root);
    var gpu: noapi.Gpu = undefined;
    var endpoint: GpuEndpoint = .{
        .gpu = &gpu,
        .retirement_wait_for_test = Wait.complete,
    };
    try app.attachGpu(&endpoint);
    const surface: widget.Size = .{ .width = 100, .height = 100 };
    const first = try app.frame(1, surface);
    const slot = ComponentId.child(.root, .{ .static = "slot" });
    try std.testing.expectEqual(@as(usize, 1), root.committed.inits);
    try std.testing.expectEqualStrings("committed", first.tree.nodes.items[0].kind.label.text);

    root.replace = true;
    root.propagate_failure = true;
    try std.testing.expectError(error.StagedInitFailure, app.frame(2, surface));
    try std.testing.expectEqual(@as(usize, 1), root.candidate.inits);
    try std.testing.expectEqual(@as(usize, 1), root.candidate.deinits);
    try std.testing.expectEqual(@as(usize, 1), Wait.calls);
    try std.testing.expectEqual(@as(usize, 1), root.caught);
    try std.testing.expect(!root.old_retired_during_draw);
    try std.testing.expectEqual(@as(usize, 0), root.committed.deinits);
    try std.testing.expect(app.tree_ptr == first.tree);
    try std.testing.expectEqual(@as(u64, 1), app.frame_generation);
    try std.testing.expect(app.identity_registry.map.get(slot).?.gpu_initialized);
    try std.testing.expect(app.identity_registry.map.get(slot).?.component.ptr ==
        @as(*anyopaque, @ptrCast(&root.committed)));

    root.propagate_failure = false;
    const fallback = try app.frame(2, surface);
    try std.testing.expectEqualStrings("fallback", fallback.tree.nodes.items[0].kind.label.text);
    try std.testing.expectEqual(@as(usize, 2), root.caught);
    try std.testing.expect(!root.old_retired_during_draw);
    try std.testing.expectEqual(@as(usize, 2), root.candidate.inits);
    try std.testing.expectEqual(@as(usize, 2), root.candidate.deinits);
    try std.testing.expectEqual(@as(usize, 1), root.committed.deinits);
    try std.testing.expectEqual(@as(usize, 3), Wait.calls);
    try std.testing.expect(!app.identity_registry.map.get(slot).?.gpu_initialized);

    root.candidate.fail_init = false;
    const recovered = try app.frame(3, surface);
    try std.testing.expectEqualStrings("ready", recovered.tree.nodes.items[0].kind.label.text);
    try std.testing.expectEqual(@as(usize, 3), root.candidate.inits);
    try std.testing.expectEqual(@as(usize, 2), root.candidate.deinits);
    try std.testing.expect(app.identity_registry.map.get(slot).?.gpu_initialized);
    app.detachGpu();
    try std.testing.expectEqual(@as(usize, 3), root.candidate.deinits);
    try std.testing.expectEqual(@as(usize, 4), Wait.calls);
}

test "DrawCtx: progress rejects non-finite or empty ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    try std.testing.expectError(error.InvalidStyle, ctx.progress(.{
        .value = std.math.nan(f32),
        .min = 0,
        .max = 1,
    }));
    try std.testing.expectError(error.InvalidStyle, ctx.progress(.{
        .value = std.math.inf(f32),
        .min = 0,
        .max = 1,
    }));
    try std.testing.expectError(error.InvalidStyle, ctx.progress(.{
        .value = 0.5,
        .min = 0,
        .max = std.math.inf(f32),
    }));
    try std.testing.expectError(error.InvalidStyle, ctx.progress(.{
        .value = 0.5,
        .min = -std.math.inf(f32),
        .max = 1,
    }));
    try std.testing.expectError(error.InvalidStyle, ctx.progress(.{
        .value = 0.5,
        .min = 0,
        .max = 0,
    }));
    try std.testing.expectError(error.InvalidStyle, ctx.progress(.{
        .value = 0.5,
        .min = 1,
        .max = 0,
    }));
}

test "DrawCtx: separator rejects non-finite or non-positive thickness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    try std.testing.expectError(error.InvalidStyle, ctx.separator(.{
        .thickness = std.math.nan(f32),
    }));
    try std.testing.expectError(error.InvalidStyle, ctx.separator(.{
        .thickness = std.math.inf(f32),
    }));
    try std.testing.expectError(error.InvalidStyle, ctx.separator(.{
        .thickness = 0,
    }));
    try std.testing.expectError(error.InvalidStyle, ctx.separator(.{
        .thickness = -1,
    }));
}

test "DrawCtx: two-level cursor nesting wires parents and children" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const col = try ctx.column(.{});
    const inner_label = try ctx.label(.{ .text = "a" });
    const inner_button = try ctx.button(.{ .key = .{ .static = "inner" }, .label = "B" });
    ctx.pop();
    const outer_label = try ctx.label(.{ .text = "b" });

    // Parents: the column's children point at it; the label after pop() is
    // back at the root.
    try std.testing.expectEqual(col, tree.node(inner_label).?.parent);
    try std.testing.expectEqual(col, tree.node(inner_button).?.parent);
    try std.testing.expectEqual(FrameNodeId.root, tree.node(outer_label).?.parent);

    // Children adjacency, in creation order. The button's label is the
    // BUTTON's child, not the column's.
    const col_node = tree.node(col) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), col_node.children.items.len);
    try std.testing.expectEqual(inner_label, col_node.children.items[0]);
    try std.testing.expectEqual(inner_button, col_node.children.items[1]);

    // The button's child is its label (a label node with the button's text).
    const btn_node = tree.node(inner_button) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), btn_node.children.items.len);
    const btn_label_id = btn_node.children.items[0];
    const btn_label = tree.node(btn_label_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(inner_button, btn_label.parent);
    try std.testing.expectEqualStrings("B", btn_label.kind.label.text);

    // Post-order: children first, then their container, then the root label.
    // The button's pop moved it past its child label, so the child precedes
    // it.
    try std.testing.expectEqual(inner_label, tree.nodes.items[0].id);
    try std.testing.expectEqual(btn_label_id, tree.nodes.items[1].id);
    try std.testing.expectEqual(inner_button, tree.nodes.items[2].id);
    try std.testing.expectEqual(col, tree.nodes.items[3].id);
    try std.testing.expectEqual(outer_label, tree.nodes.items[4].id);
}

test "DrawCtx: more than 64 nested containers preserve cursor and tree order" {
    // Exercise the public nesting cursor beyond the old fixed stack limit,
    // then prove that closing every container restores both tree order and scope.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const container_count: usize = 65;
    var container_ids: [container_count]FrameNodeId = undefined;
    for (&container_ids) |*container_id| {
        container_id.* = try ctx.column(.{});
    }
    const deepest_label = try ctx.label(.{ .text = "deepest" });
    for (0..container_count) |_| ctx.pop();
    const root_label = try ctx.label(.{ .text = "root" });

    for (container_ids, 0..) |container_id, index| {
        const container_node =
            tree.node(container_id) orelse return error.TestUnexpectedResult;
        const expected_parent = if (index == 0) FrameNodeId.root else container_ids[index - 1];
        try std.testing.expectEqual(expected_parent, container_node.parent);
    }
    const deepest_node =
        tree.node(deepest_label) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(container_ids[container_count - 1], deepest_node.parent);
    const root_node = tree.node(root_label) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FrameNodeId.root, root_node.parent);

    try std.testing.expectEqual(deepest_label, tree.nodes.items[0].id);
    try std.testing.expectEqual(container_ids[0], tree.nodes.items[container_count].id);
    try std.testing.expectEqual(root_label, tree.nodes.items[container_count + 1].id);
}

test "DrawCtx: column wires 33 children in creation order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const column = try ctx.column(.{});
    var child_ids: [33]FrameNodeId = undefined;
    for (&child_ids) |*child_id| {
        child_id.* = try ctx.label(.{ .text = "child" });
    }
    ctx.pop();

    const parent = tree.node(column) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, child_ids.len), parent.children.items.len);
    try std.testing.expectEqualSlices(FrameNodeId, &child_ids, parent.children.items);
}

test "DrawCtx: pop() restores the cursor" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const col = try ctx.column(.{});
    const inner = try ctx.label(.{ .text = "inner" });
    ctx.pop();

    // New nodes after pop() land under .root, not under the column.
    const after = try ctx.label(.{ .text = "outer" });
    try std.testing.expectEqual(FrameNodeId.root, tree.node(after).?.parent);

    // The column's children are unaffected by pop().
    const col_node = tree.node(col) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), col_node.children.items.len);
    try std.testing.expectEqual(inner, col_node.children.items[0]);
}

test "DrawCtx: button owner binds to component_id, incl. inside component()" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    // At the root the owner is .root (the implicit root component).
    const root_button = try ctx.button(.{ .key = .{ .static = "root" }, .label = "root" });
    try std.testing.expectEqual(FrameNodeId.root, tree.node(root_button).?.kind.button.owner);

    const Child = struct {
        const Self = @This();

        pub fn draw(self: *Self, c: *DrawCtx) anyerror!void {
            _ = self;
            _ = try c.button(.{ .key = .{ .static = "child" }, .label = "child" });
        }
    };
    var child: Child = .{};
    try ctx.component(Child, .{ .key = .{ .static = "child" } }, &child);

    // The component took the next id (3 — 2 was the root button's child
    // label); the inner button (id 4) is owned by the child component,
    // and component_id was restored afterwards.
    const inner: FrameNodeId = @enumFromInt(4);
    try std.testing.expectEqual(@as(FrameNodeId, @enumFromInt(3)), tree.node(inner).?.kind.button.owner);
    try std.testing.expectEqual(FrameNodeId.root, ctx.component_id);

    // A later button is owned by the root component again.
    const later = try ctx.button(.{ .key = .{ .static = "later" }, .label = "later" });
    try std.testing.expectEqual(FrameNodeId.root, tree.node(later).?.kind.button.owner);
}

test "DrawCtx: component() draws into the current cursor" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const Child = struct {
        const Self = @This();

        pub fn draw(self: *Self, c: *DrawCtx) anyerror!void {
            _ = self;
            _ = try c.label(.{ .text = "in-child" });
        }
    };
    var child: Child = .{};

    // Drawn at root level: the child's node is root-level.
    // component() reserves id 1 for the child component, so its label is 2.
    try ctx.component(Child, .{ .key = .{ .static = "child" } }, &child);
    const root_label: FrameNodeId = @enumFromInt(2);
    try std.testing.expectEqual(FrameNodeId.root, tree.node(root_label).?.parent);

    // Drawn inside a column: the child's node lands under the column.
    var arena2 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena2.deinit();
    var tree2 = WidgetTree.init(arena2.allocator());
    defer tree2.deinit();
    var ctx2: DrawCtx = .{ .tree = &tree2, .arena = arena2.allocator() };

    const col = try ctx2.column(.{});
    try ctx2.component(Child, .{ .key = .{ .static = "child" } }, &child);
    ctx2.pop();

    // ids: column = 1, component = 2, child label = 3.
    const nested: FrameNodeId = @enumFromInt(3);
    try std.testing.expectEqual(col, tree2.node(nested).?.parent);
    const col_node = tree2.node(col) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), col_node.children.items.len);
    try std.testing.expectEqual(nested, col_node.children.items[0]);
}

test "DrawCtx: component defaults apply before local overrides and restore" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const Styled = struct {
        const Self = @This();
        pub const default_style: Style = .{
            .direction = .row,
            .gap = .{ .length = 12 },
        };
        pub const default_paint: PaintStyle = .{
            .fill = .{ 1, 0, 0, 1 },
            .layer = 7,
        };
        first: FrameNodeId = .root,
        second: FrameNodeId = .root,

        pub fn draw(self: *Self, c: *DrawCtx) anyerror!void {
            self.first = try c.label(.{ .text = "default" });
            self.second = try c.label(.{
                .text = "local",
                .gap = 3,
                .fill = .{ 0, 1, 0, 1 },
            });
        }
    };

    var styled: Styled = .{};
    try ctx.component(Styled, .{ .key = .{ .static = "styled" } }, &styled);
    const first = tree.node(styled.first) orelse return error.TestUnexpectedResult;
    const second = tree.node(styled.second) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FlexDirection.row, first.style.direction);
    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 12 }),
        first.style.gap,
    ));
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 1 }, first.paint.fill);
    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 3 }),
        second.style.gap,
    ));
    try std.testing.expectEqual([4]f32{ 0, 1, 0, 1 }, second.paint.fill);

    const after = try ctx.label(.{ .text = "after" });
    try std.testing.expectEqual(FlexDirection.column, tree.node(after).?.style.direction);
    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 0 }),
        tree.node(after).?.style.gap,
    ));
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, tree.node(after).?.paint.fill);
    try std.testing.expectEqual(@as(?Style, null), ctx.component_defaults.style);
    try std.testing.expectEqual(@as(?PaintStyle, null), ctx.component_defaults.paint);
}

test "DrawCtx: component default scope restores after draw error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const Failing = struct {
        const Self = @This();
        pub const default_style: Style = .{ .gap = .{ .length = 8 } };

        pub fn draw(self: *Self, c: *DrawCtx) anyerror!void {
            _ = self;
            _ = c;
            return error.TestComponentFailure;
        }
    };

    var failing: Failing = .{};
    try std.testing.expectError(
        error.TestComponentFailure,
        ctx.component(Failing, .{ .key = .{ .static = "failing" } }, &failing),
    );
    try std.testing.expectEqual(@as(?Style, null), ctx.component_defaults.style);
    const after = try ctx.label(.{ .text = "after-error" });
    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 0 }),
        tree.node(after).?.style.gap,
    ));
}

test "DrawCtx: nested component defaults replace and isolate parent scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const Bare = struct {
        const Self = @This();
        label_id: FrameNodeId = .root,

        pub fn draw(self: *Self, c: *DrawCtx) anyerror!void {
            self.label_id = try c.label(.{ .text = "bare" });
        }
    };
    const Child = struct {
        const Self = @This();
        pub const default_style: Style = .{
            .direction = .column,
            .gap = .{ .length = 5 },
        };
        pub const default_paint: PaintStyle = .{ .fill = .{ 0, 0, 1, 1 } };
        bare: *Bare,
        label_id: FrameNodeId = .root,

        pub fn draw(self: *Self, c: *DrawCtx) anyerror!void {
            self.label_id = try c.label(.{ .text = "child" });
            try c.component(Bare, .{ .key = .{ .static = "bare" } }, self.bare);
        }
    };
    const Parent = struct {
        const Self = @This();
        pub const default_style: Style = .{
            .direction = .row,
            .gap = .{ .length = 20 },
        };
        pub const default_paint: PaintStyle = .{ .fill = .{ 1, 0, 0, 1 } };
        child: *Child,
        before_id: FrameNodeId = .root,
        after_id: FrameNodeId = .root,

        pub fn draw(self: *Self, c: *DrawCtx) anyerror!void {
            self.before_id = try c.label(.{ .text = "before" });
            try c.component(Child, .{ .key = .{ .static = "child" } }, self.child);
            self.after_id = try c.label(.{ .text = "after" });
        }
    };

    var bare: Bare = .{};
    var child: Child = .{ .bare = &bare };
    var parent: Parent = .{ .child = &child };
    try ctx.component(Parent, .{ .key = .{ .static = "parent" } }, &parent);

    const before = tree.node(parent.before_id) orelse return error.TestUnexpectedResult;
    const child_label = tree.node(child.label_id) orelse return error.TestUnexpectedResult;
    const bare_label = tree.node(bare.label_id) orelse return error.TestUnexpectedResult;
    const after = tree.node(parent.after_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FlexDirection.row, before.style.direction);
    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 20 }),
        before.style.gap,
    ));
    try std.testing.expectEqual(FlexDirection.column, child_label.style.direction);
    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 5 }),
        child_label.style.gap,
    ));
    try std.testing.expectEqual([4]f32{ 0, 0, 1, 1 }, child_label.paint.fill);
    try std.testing.expectEqual(FlexDirection.column, bare_label.style.direction);
    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 0 }),
        bare_label.style.gap,
    ));
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, bare_label.paint.fill);
    try std.testing.expectEqual(FlexDirection.row, after.style.direction);
    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 20 }),
        after.style.gap,
    ));
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 1 }, after.paint.fill);
    try std.testing.expectEqual(@as(?Style, null), ctx.component_defaults.style);
    try std.testing.expectEqual(@as(?PaintStyle, null), ctx.component_defaults.paint);
}

test "DrawCtx: justify and align flow into the node's Style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const jcol = try ctx.column(.{ .justify = .space_between });
    ctx.pop();
    const acol = try ctx.column(.{ .@"align" = .center });
    ctx.pop();
    const plain = try ctx.column(.{});
    ctx.pop();

    try std.testing.expectEqual(Justify.space_between, tree.node(jcol).?.style.justify);
    try std.testing.expectEqual(Align.center, tree.node(acol).?.style.@"align");
    // Defaults stay when the opts omit the fields.
    try std.testing.expectEqual(Justify.normal, tree.node(plain).?.style.justify);
    try std.testing.expectEqual(Align.stretch, tree.node(plain).?.style.@"align");
}

test "DrawCtx: text align flows into the node's Style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const centered = try ctx.column(.{ .text_align = .center });
    ctx.pop();
    const plain = try ctx.column(.{});
    ctx.pop();

    try std.testing.expectEqual(
        style.TextAlign.center,
        tree.node(centered).?.style.text_align,
    );
    try std.testing.expectEqual(style.TextAlign.start, tree.node(plain).?.style.text_align);
}
test "DrawCtx: button label honors justify and align overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const button = try ctx.button(.{
        .key = .{ .static = "start" },
        .label = "start",
        .justify = .start,
        .@"align" = .end,
    });
    const button_node = tree.node(button) orelse return error.TestUnexpectedResult;
    const label_id = button_node.children.items[0];

    try std.testing.expectEqual(Justify.start, button_node.style.justify);
    try std.testing.expectEqual(Align.end, button_node.style.@"align");
    try std.testing.expectEqualStrings("start", tree.node(label_id).?.kind.label.text);

    try layout.layoutTree(&tree, .{
        .allocator = arena.allocator(),
        .available = .{ .width = 120, .height = 40 },
        .measure = null,
    });
    try std.testing.expectEqual(@as(f32, 0), tree.node(label_id).?.rect.x);
}
test "DrawCtx: semantic and visual labels are copied, empty override stays explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    var button_text = [_]u8{ 'B', 'u', 't', 't', 'o', 'n' };
    var semantic_text = [_]u8{ 'S', 'e', 'm' };
    var slider_text = [_]u8{ 'S', 'l', 'i', 'd', 'e', 'r' };
    var visual_text = [_]u8{ 'V', 'i', 's' };
    var value: f32 = 0.5;

    const button = try ctx.button(.{
        .key = .{ .static = "button" },
        .label = button_text[0..],
        .accessible_label = semantic_text[0..],
    });
    const slider = try ctx.slider(.{
        .key = .{ .static = "slider" },
        .label = slider_text[0..],
        .visual_label = visual_text[0..],
        .value = &value,
        .min = 0,
        .max = 1,
    });
    const hidden = try ctx.slider(.{
        .key = .{ .static = "hidden" },
        .label = "semantic only",
        .visual_label = "",
        .value = &value,
        .min = 0,
        .max = 1,
    });

    @memset(&button_text, 'x');
    @memset(&semantic_text, 'x');
    @memset(&slider_text, 'x');
    @memset(&visual_text, 'x');

    const button_node = tree.node(button) orelse return error.TestUnexpectedResult;
    const button_kind = button_node.kind.button;
    try std.testing.expectEqualStrings("Button", button_kind.label);
    try std.testing.expectEqualStrings("Sem", button_kind.accessible_label.?);
    const slider_node = tree.node(slider) orelse return error.TestUnexpectedResult;
    const slider_kind = slider_node.kind.slider;
    try std.testing.expectEqualStrings("Slider", slider_kind.label);
    try std.testing.expectEqualStrings("Vis", slider_kind.visual_label.?);
    try std.testing.expectEqualStrings("", tree.node(hidden).?.kind.slider.visual_label.?);
}

test "DrawCtx: icon-only button stays interactive without a label child" {
    // Layout an icon-only button, then verify that its semantic and renderer
    // metadata stay on the hit-testable button instead of a generated leaf.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const Counter = struct {
        const Self = @This();

        fn click(self: *Self) void {
            _ = self;
        }
    };
    const button = try ctx.button(.{
        .key = .{ .static = "play" },
        .label = "Play",
        .accessible_label = "Play",
        .icon = @as(widget.IconId, .play),
        .on_click = Counter.click,
        .flex_basis = 24,
        .min_width = 24,
        .shrink = 0,
    });

    try layout.layoutTree(&tree, .{
        .allocator = arena.allocator(),
        .available = .{ .width = 80, .height = 40 },
        .measure = null,
    });
    const button_node = tree.node(button) orelse return error.TestUnexpectedResult;
    const button_kind = button_node.kind.button;
    try std.testing.expectEqual(@as(usize, 0), button_node.children.items.len);
    try std.testing.expectEqualStrings("Play", button_kind.accessible_label.?);
    try std.testing.expectEqual(widget.IconId.play, button_kind.icon.?);
    try std.testing.expect(button_kind.on_click != null);
    try std.testing.expect(button_node.rect.w > 0);
    try std.testing.expect(button_node.rect.h > 0);

    const bounds = widget.visualBorderRect(&tree, button);
    const hit = hitActionable(&tree, .{ bounds.x + bounds.w / 2, bounds.y + bounds.h / 2 });
    try std.testing.expectEqual(button, hit.?);
}

test "DrawCtx: container gap is stored in Style, defaults to zero" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const gapped_col = try ctx.column(.{ .gap = 4 });
    ctx.pop();
    const plain_col = try ctx.column(.{});
    ctx.pop();
    const gapped_row = try ctx.row(.{ .gap = 7 });
    ctx.pop();
    const plain_row = try ctx.row(.{});
    ctx.pop();

    try std.testing.expectEqual(
        style.LengthPercentage{ .length = 4 },
        tree.node(gapped_col).?.style.gap,
    );
    try std.testing.expectEqual(
        style.LengthPercentage{ .length = 0 },
        tree.node(plain_col).?.style.gap,
    );
    try std.testing.expectEqual(
        style.LengthPercentage{ .length = 7 },
        tree.node(gapped_row).?.style.gap,
    );
    try std.testing.expectEqual(
        style.LengthPercentage{ .length = 0 },
        tree.node(plain_row).?.style.gap,
    );
}

test "DrawCtx: button on_click is wrapped via callback.wrap when provided" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    // No on_click in opts -> null callback.
    const plain = try ctx.button(.{ .key = .{ .static = "plain" }, .label = "no handler" });
    try std.testing.expectEqual(@as(?*const fn (*anyopaque) void, null), tree.node(plain).?.kind.button.on_click);

    // With on_click -> a type-erased callback that reaches the receiver.
    const Counter = struct {
        const Self = @This();

        n: u32 = 0,

        fn click(self: *Self) void {
            self.n += 1;
        }
    };
    var counter: Counter = .{};
    const wired = try ctx.button(.{
        .key = .{ .static = "wired" },
        .label = "go",
        .on_click = Counter.click,
    });
    const wired_node = tree.node(wired) orelse return error.TestUnexpectedResult;
    const cb = wired_node.kind.button.on_click orelse return error.TestUnexpectedResult;
    cb(@ptrCast(&counter));
    try std.testing.expectEqual(@as(u32, 1), counter.n);
}

test "DrawCtx: shared columns seed canonical child flex sizing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const tracks = [_]ColumnTrack{
        .{
            .grow = 2,
            .shrink = 0.5,
            .flex_basis = .{ .length = 40 },
            .min_width = .{ .length = 12 },
        },
        .{
            .grow = 3,
            .shrink = 0.25,
            .flex_basis = .{ .length = 60 },
            .min_width = .{ .length = 20 },
        },
    };
    const columns: SharedColumns = .{ .tracks = &tracks };
    const row = try ctx.row(.{ .columns = &columns });
    const first = try ctx.label(.{ .text = "first" });
    const second = try ctx.label(.{
        .text = "second",
        .grow = 9,
        .shrink = 0.75,
        .flex_basis = 90,
        .min_width = 30,
    });
    const button = try ctx.button(.{ .key = .{ .static = "button" }, .label = "button" });
    ctx.pop();

    try std.testing.expectEqual(row, tree.node(first).?.parent);
    try std.testing.expectEqual(row, tree.node(second).?.parent);
    try std.testing.expectEqual(row, tree.node(button).?.parent);
    try std.testing.expectEqual(@as(f32, 2), tree.node(first).?.style.grow);
    try std.testing.expectEqual(@as(f32, 0.5), tree.node(first).?.style.shrink);
    try std.testing.expectEqual(
        style.Dimension{ .length = 40 },
        tree.node(first).?.style.flex_basis,
    );
    try std.testing.expectEqual(
        style.Dimension{ .length = 12 },
        tree.node(first).?.style.min_size.width,
    );
    try std.testing.expectEqual(@as(f32, 9), tree.node(second).?.style.grow);
    try std.testing.expectEqual(@as(f32, 0.75), tree.node(second).?.style.shrink);
    try std.testing.expectEqual(
        style.Dimension{ .length = 90 },
        tree.node(second).?.style.flex_basis,
    );
    try std.testing.expectEqual(
        style.Dimension{ .length = 30 },
        tree.node(second).?.style.min_size.width,
    );
    // The button is the third child, so it is outside the two-track layout.
    try std.testing.expectEqual(@as(f32, 0), tree.node(button).?.style.grow);
    try std.testing.expectEqual(@as(f32, 1), tree.node(button).?.style.shrink);
    try std.testing.expectEqual(style.Dimension.auto, tree.node(button).?.style.flex_basis);
    try std.testing.expectEqual(style.Dimension.auto, tree.node(button).?.style.min_size.width);
}

test "DrawCtx: button label does not consume shared column track" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const tracks = [_]ColumnTrack{
        .{ .grow = 1, .flex_basis = .{ .length = 25 } },
        .{ .grow = 4, .flex_basis = .{ .length = 75 } },
    };
    const columns: SharedColumns = .{ .tracks = &tracks };
    const row = try ctx.row(.{ .columns = &columns });
    const button = try ctx.button(.{ .key = .{ .static = "button" }, .label = "button" });
    const sibling = try ctx.label(.{ .text = "sibling" });
    ctx.pop();

    const button_node = tree.node(button) orelse return error.TestUnexpectedResult;
    const button_label = tree.node(button_node.children.items[0]) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 1), button_node.style.grow);
    try std.testing.expectEqual(
        style.Dimension{ .length = 25 },
        button_node.style.flex_basis,
    );
    try std.testing.expectEqual(@as(f32, 0), button_label.style.grow);
    try std.testing.expectEqual(style.Dimension.auto, button_label.style.flex_basis);
    try std.testing.expectEqual(@as(f32, 4), tree.node(sibling).?.style.grow);
    try std.testing.expectEqual(
        style.Dimension{ .length = 75 },
        tree.node(sibling).?.style.flex_basis,
    );
    try std.testing.expectEqual(row, button_node.parent);
}

test "DrawCtx: scroll options wire state, axis, and clipping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
    var column_state: ScrollState = .{};
    var row_state: ScrollState = .{};

    const column = try ctx.column(.{
        .scroll_state = &column_state,
        .scroll_axis = .vertical,
    });
    ctx.pop();
    const row = try ctx.row(.{
        .scroll_state = &row_state,
        .scroll_axis = .both,
    });
    ctx.pop();

    try std.testing.expect(tree.node(column).?.paint.clip);
    try std.testing.expect(tree.node(row).?.paint.clip);
    try std.testing.expectEqual(&column_state, tree.node(column).?.scroll.?.state);
    try std.testing.expectEqual(ScrollAxis.vertical, tree.node(column).?.scroll.?.axis);
    try std.testing.expectEqual(&row_state, tree.node(row).?.scroll.?.state);
    try std.testing.expectEqual(ScrollAxis.both, tree.node(row).?.scroll.?.axis);
}

test "DrawCtx: typed Style and PaintStyle fields flow from opts" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const id = try ctx.label(.{
        .text = "typed",
        .margin = .{ .top = 1, .right = 2, .bottom = 3, .left = 4 },
        .padding = .{ .top = 5, .right = 6, .bottom = 7, .left = 8 },
        .border = .{ .top = 9, .right = 10, .bottom = 11, .left = 12 },
        .border_color = .{ 0.1, 0.2, 0.3, 0.4 },
        .radius = .{ .top = 13, .right = 14, .bottom = 15, .left = 16 },
        .box_sizing = .border_box,
    });

    try std.testing.expectEqual(
        style.Insets{
            .top = .{ .length = 1 },
            .right = .{ .length = 2 },
            .bottom = .{ .length = 3 },
            .left = .{ .length = 4 },
        },
        tree.node(id).?.style.margin_inset,
    );
    try std.testing.expectEqual(
        style.LengthPercentageRect{
            .top = .{ .length = 5 },
            .right = .{ .length = 6 },
            .bottom = .{ .length = 7 },
            .left = .{ .length = 8 },
        },
        tree.node(id).?.style.padding_inset,
    );
    try std.testing.expectEqual(
        style.LengthPercentageRect{
            .top = .{ .length = 9 },
            .right = .{ .length = 10 },
            .bottom = .{ .length = 11 },
            .left = .{ .length = 12 },
        },
        tree.node(id).?.style.border_inset,
    );
    try std.testing.expectEqual(BoxSizing.border_box, tree.node(id).?.style.box_sizing);
    try std.testing.expectEqual(
        [4]f32{ 0.1, 0.2, 0.3, 0.4 },
        tree.node(id).?.paint.border_color,
    );
    try std.testing.expectEqual(
        Sides{ .top = 13, .right = 14, .bottom = 15, .left = 16 },
        tree.node(id).?.paint.radius,
    );

    const col = try ctx.column(.{ .padding = .{ .top = 8, .left = 8 } });
    ctx.pop();
    const row = try ctx.row(.{ .border = .{ .top = 2 } });
    ctx.pop();
    try std.testing.expectEqual(
        style.LengthPercentageRect{
            .top = .{ .length = 8 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 8 },
        },
        tree.node(col).?.style.padding_inset,
    );
    try std.testing.expectEqual(
        style.LengthPercentageRect{
            .top = .{ .length = 2 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
        tree.node(row).?.style.border_inset,
    );
}

test "DrawCtx: absent typed fields retain defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
    const default_style: Style = .{};

    const plain_label = try ctx.label(.{ .text = "plain" });
    const plain_button = try ctx.button(.{ .key = .{ .static = "button" }, .label = "B" });
    var slider_value: f32 = 0.5;
    const plain_slider = try ctx.slider(.{
        .key = .{ .static = "slider" },
        .label = "S",
        .value = &slider_value,
        .min = 0,
        .max = 1,
    });
    const plain_spacer = try ctx.spacer(.{});
    const plain_col = try ctx.column(.{ .gap = 4 });
    ctx.pop();

    for ([_]FrameNodeId{ plain_label, plain_button, plain_slider, plain_spacer }) |id| {
        const node = tree.node(id) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(default_style.margin_inset, node.style.margin_inset);
        try std.testing.expectEqual(default_style.border_inset, node.style.border_inset);
        try std.testing.expectEqual(default_style.padding_inset, node.style.padding_inset);
        try std.testing.expectEqual(PaintStyle{}, node.paint);
    }
    try std.testing.expectEqual(default_style.margin_inset, tree.node(plain_col).?.style.margin_inset);
    try std.testing.expectEqual(default_style.border_inset, tree.node(plain_col).?.style.border_inset);
    try std.testing.expectEqual(default_style.padding_inset, tree.node(plain_col).?.style.padding_inset);
    try std.testing.expectEqual(PaintStyle{}, tree.node(plain_col).?.paint);
}

test "DrawCtx: typed PaintStyle layer option" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const layered_col = try ctx.column(.{ .layer = 3 });
    ctx.pop();
    const layered_label = try ctx.label(.{ .text = "layer", .layer = 1 });
    try std.testing.expectEqual(@as(u32, 3), tree.node(layered_col).?.paint.layer);
    try std.testing.expectEqual(@as(u32, 1), tree.node(layered_label).?.paint.layer);

    const plain_col = try ctx.column(.{});
    ctx.pop();
    try std.testing.expectEqual(@as(u32, 0), tree.node(plain_col).?.paint.layer);
}

test "DrawCtx: typed PaintStyle clip option; pushClip appends to the tree clip list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const card = try ctx.column(.{ .clip = true });
    ctx.pop();
    try std.testing.expect(tree.node(card).?.paint.clip);

    const id0 = try ctx.pushClip(10, 20, 30, 40);
    const id1 = try ctx.pushClip(50, 60, 70, 80);
    ctx.popClip();
    ctx.popClip();
    try std.testing.expectEqual(@as(u32, 0), id0);
    try std.testing.expectEqual(@as(u32, 1), id1);
    try std.testing.expectEqual(@as(u32, 2), tree.clip_count);
    try std.testing.expectEqual(@as(f32, 30), tree.clip_rects[0].w);
    try std.testing.expectEqual(@as(f32, 80), tree.clip_rects[1].h);
}
test "DrawCtx: canonical flex basis and parent-axis minimums" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
    const id = try ctx.label(.{ .text = "typed", .flex_basis = 30, .min_height = 12 });
    const node = tree.node(id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        style.Dimension{ .length = 30 },
        node.style.flex_basis,
    );
    try std.testing.expectEqual(
        style.Dimension{ .length = 12 },
        node.style.min_size.height,
    );
    try std.testing.expectEqual(style.Dimension.auto, node.style.min_size.width);
}

test "DrawCtx: canonical dimensions convert optional and fixed values" {
    const optional_number: ?u16 = 9;
    const optional_fixed: ?style.Dimension = style.Dimension.fixed(18);

    const resolved = styleFromOpts(.{
        .flex_basis = optional_number,
        .min_width = optional_fixed,
        .min_height = style.Dimension.percentage(0.5),
    }, null, .row);
    try std.testing.expectEqual(
        style.Dimension{ .length = 9 },
        resolved.flex_basis,
    );
    try std.testing.expectEqual(
        style.Dimension{ .length = 18 },
        resolved.min_size.width,
    );
    try std.testing.expectEqual(
        style.Dimension{ .percent = 0.5 },
        resolved.min_size.height,
    );

    const min_content = styleFromOpts(.{
        .min_width = @as(style.Dimension, .min_content),
    }, null, .row);
    try std.testing.expectEqual(style.Dimension.min_content, min_content.min_size.width);
}

test "DrawCtx: direct min height retains fixed and percentage dimensions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const fixed_id = try ctx.label(.{
        .text = "fixed",
        .min_height = style.Dimension.fixed(18),
    });
    const fixed = tree.node(fixed_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        style.Dimension{ .length = 18 },
        fixed.style.min_size.height,
    );
    try std.testing.expectEqual(style.Dimension.auto, fixed.style.min_size.width);

    const percent_id = try ctx.label(.{
        .text = "percent",
        .min_height = style.Dimension.percentage(0.5),
    });
    const percent = tree.node(percent_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        style.Dimension{ .percent = 0.5 },
        percent.style.min_size.height,
    );
}

test "DrawCtx: constructor translates display and position into Style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const id = try ctx.column(.{ .display = .block, .position = .absolute });
    ctx.pop();

    try std.testing.expectEqual(style.Display.block, tree.node(id).?.style.display);
    try std.testing.expectEqual(style.Position.absolute, tree.node(id).?.style.position);
}

test "DrawCtx: canonical flex options translate into typed Style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const id = try ctx.row(.{
        .direction = .row_reverse,
        .flex_wrap = .wrap_reverse,
        .align_content = .space_around,
        .align_self = .end,
        .margin_inset = .{
            .top = .auto,
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
    });
    ctx.pop();

    const node = tree.node(id) orelse return error.TestUnexpectedResult;
    const resolved = node.style;
    try std.testing.expectEqual(style.FlexDirection.row_reverse, resolved.direction);
    try std.testing.expectEqual(style.FlexWrap.wrap_reverse, resolved.flex_wrap);
    try std.testing.expectEqual(style.AlignContent.space_around, resolved.align_content);
    try std.testing.expectEqual(style.AlignSelf.end, resolved.align_self);
    try std.testing.expect(std.meta.eql(@as(style.LengthPercentageAuto, .auto), resolved.margin_inset.top));
}

test "DrawCtx: grid constructor translates tracks placement and canonical gaps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
    const tracks = [_]style.GridTrack{ .{ .fixed = 32 }, .{ .fr = 1 } };

    const id = try ctx.grid(.{
        .grid_template_columns = tracks[0..],
        .column_gap = 4,
        .row_gap = 8,
        .grid_auto_flow = .column,
        .grid_column = .{
            .start = .{ .line = 1 },
            .end = .{ .span = 2 },
        },
    });
    ctx.pop();
    const node = tree.node(id) orelse return error.TestUnexpectedResult;
    const resolved = node.style;
    try std.testing.expectEqual(style.Display.grid, resolved.display);
    try std.testing.expectEqual(@as(usize, 2), resolved.grid_template_columns.len);
    try std.testing.expectEqual(
        style.LengthPercentage{ .length = 4 },
        resolved.column_gap,
    );
    try std.testing.expectEqual(
        style.LengthPercentage{ .length = 8 },
        resolved.row_gap,
    );
    try std.testing.expectEqual(style.GridAutoFlow.column, resolved.grid_auto_flow);
}

test "DrawCtx numeric canonical gap options become typed lengths" {
    const resolved = styleFromOpts(.{
        .gap = 12,
        .column_gap = 13,
        .row_gap = 14,
    }, null, .column);

    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 12 }),
        resolved.gap,
    ));
    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 13 }),
        resolved.column_gap,
    ));
    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 14 }),
        resolved.row_gap,
    ));
}

test "DrawCtx typed percentage gap survives override and resolution" {
    const resolved = styleFromOpts(.{
        .gap = style.LengthPercentage{ .percent = 0.1 },
    }, null, .column);

    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .percent = 0.1 }),
        resolved.gap,
    ));
}

test "DrawCtx container gaps remain typed for percentage options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const fixed = try ctx.column(.{ .gap = 12 });
    ctx.pop();
    const percentage = try ctx.column(.{
        .gap = style.LengthPercentage{ .percent = 0.1 },
    });
    ctx.pop();

    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 12 }),
        tree.node(fixed).?.style.gap,
    ));
    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .percent = 0.1 }),
        tree.node(percentage).?.style.gap,
    ));
}

test "DrawCtx: fast path deduplication preserves tree hierarchy and post-order ordering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const shared: SharedColumns = .{ .tracks = &[_]ColumnTrack{
        .{ .grow = 2, .shrink = 0.5, .flex_basis = .{ .length = 50 }, .min_width = .{ .length = 20 } },
        .{ .grow = 1, .shrink = 1.0, .flex_basis = .{ .length = 100 }, .min_width = .{ .length = 30 } },
    } };

    const outer_col = try ctx.column(.{});
    const row_container = try ctx.row(.{ .columns = &shared });
    const child1 = try ctx.label(.{ .text = "item 1" });
    const button_id = try ctx.button(.{ .key = .{ .static = "action" }, .label = "action" });
    ctx.pop(); // pop row
    const trailing_label = try ctx.label(.{ .text = "done" });
    ctx.pop(); // pop outer_col

    // Verify parent links
    try std.testing.expectEqual(FrameNodeId.root, tree.node(outer_col).?.parent);
    try std.testing.expectEqual(outer_col, tree.node(row_container).?.parent);
    try std.testing.expectEqual(outer_col, tree.node(trailing_label).?.parent);
    try std.testing.expectEqual(row_container, tree.node(child1).?.parent);
    try std.testing.expectEqual(row_container, tree.node(button_id).?.parent);

    // Verify shared column track seeding
    const c1_node = tree.node(child1).?;
    try std.testing.expectEqual(@as(f32, 2), c1_node.style.grow);
    try std.testing.expectEqual(@as(f32, 0.5), c1_node.style.shrink);
    try std.testing.expectEqual(style.Dimension{ .length = 50 }, c1_node.style.flex_basis);
    try std.testing.expectEqual(style.Dimension{ .length = 20 }, c1_node.style.min_size.width);

    // Verify button label child was generated and correctly nested under button
    const btn_node = tree.node(button_id).?;
    try std.testing.expectEqual(@as(usize, 1), btn_node.children.items.len);
    const btn_label_id = btn_node.children.items[0];
    try std.testing.expectEqual(button_id, tree.node(btn_label_id).?.parent);

    // Post-order invariant: children appear before containers in tree.nodes
    try std.testing.expectEqual(child1, tree.nodes.items[0].id);
    try std.testing.expectEqual(btn_label_id, tree.nodes.items[1].id);
    try std.testing.expectEqual(button_id, tree.nodes.items[2].id);
    try std.testing.expectEqual(row_container, tree.nodes.items[3].id);
    try std.testing.expectEqual(trailing_label, tree.nodes.items[4].id);
    try std.testing.expectEqual(outer_col, tree.nodes.items[5].id);
}
