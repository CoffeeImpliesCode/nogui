//! DrawCtx — the per-frame UI surface.
//!
//! DrawCtx owns the cursor into a `WidgetTree` and the `component_id` that
//! binds event handlers to their owning component. State lives in
//! components; the UI is rebuilt every frame: a fresh tree + DrawCtx, a
//! draw pass, then flex.layout().
//!
//! Node order in the flat array is **post-order**: a container node is
//! appended after all of its descendants. flex.layout() is a single
//! bottom-up pass over the array and sizes children before their parent, so
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
//! Per the prototype spec (notes/v7-prototype-spec.md §4).
const std = @import("std");
const widget = @import("widget.zig");

const Id = @import("id.zig").Id;
const ComponentKey = @import("key.zig").ComponentKey;
const ComponentId = @import("key.zig").ComponentId;
const Box = @import("widget.zig").Box;
const style = @import("style.zig");
const Style = style.Style;
const StyleOverride = style.StyleOverride;
const PaintStyle = style.PaintStyle;
const PaintStyleOverride = style.PaintStyleOverride;
const Sides = style.Sides;
const BoxSizing = style.BoxSizing;
const Justify = style.Justify;
const Align = style.Align;
const FlexWrap = style.FlexWrap;
const AlignContent = style.AlignContent;
const AlignSelf = style.AlignSelf;
const layout = @import("flex.zig").layout;
const hitButton = @import("input.zig").hitButton;
const StateKey = @import("state.zig").Key;
const stateHash = @import("state.zig").hashName;
const StateDir = @import("state.zig").StateDir;
const Component = @import("component.zig").Component;
const IdentityRegistry = @import("component.zig").ComponentRegistry;
const GpuEndpoint = @import("runtime.zig").GpuEndpoint;
pub const ComponentRegistry = struct {
    map: *std.AutoHashMapUnmanaged(Id, Component),
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
    if (@typeInfo(T) != .@"struct") return .{
        .top = .{ .length = 0 },
        .right = .{ .length = 0 },
        .bottom = .{ .length = 0 },
        .left = .{ .length = 0 },
    };
    return .{
        .top = if (@hasField(T, "top")) style.lengthPercentageAutoFrom(x.top) else .{ .length = 0 },
        .right = if (@hasField(T, "right")) style.lengthPercentageAutoFrom(x.right) else .{ .length = 0 },
        .bottom = if (@hasField(T, "bottom")) style.lengthPercentageAutoFrom(x.bottom) else .{ .length = 0 },
        .left = if (@hasField(T, "left")) style.lengthPercentageAutoFrom(x.left) else .{ .length = 0 },
    };
}

fn asLengthPercentageRect(x: anytype) style.LengthPercentageRect {
    const T = @TypeOf(x);
    if (@typeInfo(T) != .@"struct") return .{
        .top = .{ .length = 0 },
        .right = .{ .length = 0 },
        .bottom = .{ .length = 0 },
        .left = .{ .length = 0 },
    };
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

fn asLegacySide(value: anytype) f32 {
    const resolved = style.lengthPercentageAutoFrom(value);
    return switch (resolved) {
        .auto => 0,
        .length => |length| length,
        .percent => 0,
    };
}
fn asFixedLength(value: anytype) ?f32 {
    return switch (style.lengthPercentageAutoFrom(value)) {
        .auto, .percent => null,
        .length => |length| length,
    };
}
fn asOptionalF32(value: anytype) ?f32 {
    const T = @TypeOf(value);
    if (T == style.Dimension) {
        return switch (value) {
            .length => |length| length,
            .auto, .percent, .min_content, .max_content => null,
        };
    }
    if (T == style.LengthPercentage) {
        return switch (value) {
            .length => |length| length,
            .percent => null,
        };
    }
    if (T == style.LengthPercentageAuto) {
        return switch (value) {
            .length => |length| length,
            .auto, .percent => null,
        };
    }
    if (T == std.meta.Tag(style.Dimension)) {
        return asOptionalF32(style.dimensionFrom(value));
    }
    if (T == style.DimensionOverride) return asOptionalF32(style.dimensionFrom(value));
    if (T == style.LengthPercentageAutoOverride) {
        return asOptionalF32(style.lengthPercentageAutoFrom(value));
    }
    return switch (@typeInfo(T)) {
        .optional => if (value) |inner| asOptionalF32(inner) else null,
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        .enum_literal => asOptionalF32(style.dimensionFrom(value)),
        .@"struct" => asOptionalF32(style.dimensionFrom(value)),
        else => @compileError("expected a numeric or fixed dimension value"),
    };
}

/// Resolve typed layout and paint values from an anonymous widget options
/// value. Missing fields stay unspecified and therefore retain defaults.
fn styleFromOpts(opts: anytype, direction: style.FlexDirection) Style {
    var local: StyleOverride = .{};
    const T = @TypeOf(opts);
    if (@hasField(T, "display")) local.display = @as(style.Display, opts.display);
    if (@hasField(T, "position")) local.position = @as(style.Position, opts.position);
    if (@hasField(T, "direction")) local.direction = @as(style.FlexDirection, opts.direction);
    if (@hasField(T, "wrap")) local.wrap = @as(FlexWrap, opts.wrap);
    if (@hasField(T, "flex_wrap")) local.flex_wrap = @as(FlexWrap, opts.flex_wrap);
    if (@hasField(T, "align_content")) {
        local.align_content = @as(AlignContent, opts.align_content);
    }
    if (@hasField(T, "align_self")) local.align_self = @as(AlignSelf, opts.align_self);
    if (@hasField(T, "justify")) local.justify = @as(Justify, opts.justify);
    if (@hasField(T, "align")) local.@"align" = @as(Align, opts.@"align");
    if (@hasField(T, "gap")) local.gap = opts.gap;
    if (@hasField(T, "column_gap")) local.column_gap = opts.column_gap;
    if (@hasField(T, "row_gap")) local.row_gap = opts.row_gap;
    if (@hasField(T, "grid_template_columns")) {
        local.grid_template_columns = opts.grid_template_columns;
    }
    if (@hasField(T, "grid_template_rows")) {
        local.grid_template_rows = opts.grid_template_rows;
    }
    if (@hasField(T, "grid_auto_columns")) local.grid_auto_columns = opts.grid_auto_columns;
    if (@hasField(T, "grid_auto_rows")) local.grid_auto_rows = opts.grid_auto_rows;
    if (@hasField(T, "grid_auto_flow")) local.grid_auto_flow = @as(style.GridAutoFlow, opts.grid_auto_flow);
    if (@hasField(T, "grid_column_gap")) local.grid_column_gap = opts.grid_column_gap;
    if (@hasField(T, "grid_row_gap")) local.grid_row_gap = opts.grid_row_gap;
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
    if (@hasField(T, "grid_column_start")) local.grid_column_start = opts.grid_column_start;
    if (@hasField(T, "grid_column_end")) local.grid_column_end = opts.grid_column_end;
    if (@hasField(T, "grid_row_start")) local.grid_row_start = opts.grid_row_start;
    if (@hasField(T, "grid_row_end")) local.grid_row_end = opts.grid_row_end;
    if (@hasField(T, "grow")) local.grow = opts.grow;
    if (@hasField(T, "shrink")) local.shrink = opts.shrink;
    if (@hasField(T, "basis")) local.basis = opts.basis;
    if (@hasField(T, "min_main")) {
        local.min_main = .{ .value = asOptionalF32(opts.min_main) };
    }
    if (@hasField(T, "flex_basis")) local.flex_basis = .{ .value = style.dimensionFrom(opts.flex_basis) };
    if (@hasField(T, "size")) local.size = .{ .value = asDimensionSize(opts.size) };
    if (@hasField(T, "min_size")) {
        local.min_size = .{ .value = asLengthPercentageAutoSize(opts.min_size) };
    }
    if (@hasField(T, "max_size")) {
        local.max_size = .{ .value = asLengthPercentageAutoSize(opts.max_size) };
    }
    if (@hasField(T, "width")) {
        local.width = .{ .value = style.dimensionFrom(opts.width) };
    }
    if (@hasField(T, "height")) {
        local.height = .{ .value = style.dimensionFrom(opts.height) };
    }
    if (@hasField(T, "min_width")) {
        local.min_width = .{ .value = style.dimensionFrom(opts.min_width) };
    }
    if (@hasField(T, "min_height")) {
        local.min_height = .{ .value = style.dimensionFrom(opts.min_height) };
    }
    if (@hasField(T, "max_width")) {
        local.max_width = .{ .value = style.dimensionFrom(opts.max_width) };
    }
    if (@hasField(T, "max_height")) {
        local.max_height = .{ .value = style.dimensionFrom(opts.max_height) };
    }
    if (@hasField(T, "width_override")) local.width_override = opts.width_override;
    if (@hasField(T, "height_override")) local.height_override = opts.height_override;
    if (@hasField(T, "min_width_override")) local.min_width_override = opts.min_width_override;
    if (@hasField(T, "min_height_override")) local.min_height_override = opts.min_height_override;
    if (@hasField(T, "max_width_override")) local.max_width_override = opts.max_width_override;
    if (@hasField(T, "max_height_override")) local.max_height_override = opts.max_height_override;
    if (@hasField(T, "inset")) local.inset = .{ .value = asInsets(opts.inset) };
    if (@hasField(T, "aspect_ratio")) local.aspect_ratio = .{ .value = opts.aspect_ratio };
    if (@hasField(T, "overflow")) local.overflow = .{ .value = asOverflowAxes(opts.overflow) };
    if (@hasField(T, "margin")) {
        local.margin = asSides(opts.margin);
        local.margin_inset = asMarginInsets(opts.margin);
    }
    if (@hasField(T, "border")) {
        local.border = asSides(opts.border);
        local.border_inset = asLengthPercentageRect(opts.border);
    }
    if (@hasField(T, "padding")) {
        local.padding = asSides(opts.padding);
        local.padding_inset = asLengthPercentageRect(opts.padding);
    }
    if (@hasField(T, "margin_inset")) local.margin_inset = asInsets(opts.margin_inset);
    if (@hasField(T, "border_inset")) local.border_inset = asLengthPercentageRect(opts.border_inset);
    if (@hasField(T, "padding_inset")) local.padding_inset = asLengthPercentageRect(opts.padding_inset);
    if (@hasField(T, "box_sizing")) local.box_sizing = @as(BoxSizing, opts.box_sizing);
    return Style.resolve(.{ .direction = direction }, local);
}

fn paintStyleFromOpts(opts: anytype) PaintStyle {
    var local: PaintStyleOverride = .{};
    const T = @TypeOf(opts);
    if (@hasField(T, "border_color")) local.border_color = asColor(opts.border_color);
    if (@hasField(T, "radius")) local.radius = asSides(opts.radius);
    if (@hasField(T, "shadow")) local.shadow = opts.shadow;
    if (@hasField(T, "transparent")) local.transparent = opts.transparent;
    if (@hasField(T, "clip")) local.clip = opts.clip;
    if (@hasField(T, "layer")) local.layer = opts.layer;
    if (@hasField(T, "texture")) local.texture = .{ .value = opts.texture };
    if (@hasField(T, "gradient")) local.gradient = asColor(opts.gradient);
    if (@hasField(T, "fill")) local.fill = asColor(opts.fill);
    return PaintStyle.resolve(.{}, local);
}

fn applyFlexStyle(self: *DrawCtx, id: Id, opts: anytype) void {
    const T = @TypeOf(opts);
    const node = self.tree.node(id).?;
    if (@hasField(T, "wrap")) node.style.wrap = @as(FlexWrap, opts.wrap);
    if (@hasField(T, "flex_wrap")) node.style.flex_wrap = @as(FlexWrap, opts.flex_wrap);
    if (@hasField(T, "justify")) node.style.justify = @as(Justify, opts.justify);
    if (@hasField(T, "align")) node.style.@"align" = @as(Align, opts.@"align");
    if (@hasField(T, "align_content")) {
        node.style.align_content = @as(AlignContent, opts.align_content);
    }
    if (@hasField(T, "align_self")) node.style.align_self = @as(AlignSelf, opts.align_self);
}

/// Apply explicit flex sizing; the parent chooses its main-axis direction.
fn applyFlexSizing(self: *DrawCtx, id: Id, opts: anytype) void {
    const node = self.tree.node(id).?;
    const T = @TypeOf(opts);
    if (@hasField(T, "grow")) node.style.grow = opts.grow;
    if (@hasField(T, "shrink")) node.style.shrink = opts.shrink;
    if (@hasField(T, "basis")) {
        node.style.basis = opts.basis;
        node.style.flex_basis = .{ .length = opts.basis };
    }
    if (@hasField(T, "flex_basis")) node.style.flex_basis = style.dimensionFrom(opts.flex_basis);
    if (@hasField(T, "min_main")) {
        const min_value = asOptionalF32(opts.min_main);
        node.style.min_main = min_value;
    }
    node.flex = .{
        .grow = node.style.grow,
        .shrink = node.style.shrink,
        .basis = node.style.basis,
        .min_main = node.style.min_main,
    };
}

/// Apply only explicit shrink/min-main bounds to a generated button label.
fn applyButtonLabelSizing(self: *DrawCtx, id: Id, opts: anytype) void {
    const node = self.tree.node(id).?;
    const T = @TypeOf(opts);
    if (@hasField(T, "shrink")) node.style.shrink = opts.shrink;
    if (@hasField(T, "min_main")) node.style.min_main = asOptionalF32(opts.min_main);
    node.flex.shrink = node.style.shrink;
    node.flex.min_main = node.style.min_main;
}

/// Seed a direct row child from its parent's shared column track.
fn applySharedColumnDefaults(self: *DrawCtx, id: Id) void {
    const child = self.tree.node(id).?;
    if (child.parent == .root) return;
    const parent = self.tree.node(child.parent) orelse return;
    if (parent.kind != .row) return;
    const columns = parent.shared_columns orelse return;
    if (parent.children.len == 0) return;
    const child_index: usize = @intCast(parent.children.len - 1);
    if (child_index >= columns.tracks.len) return;
    const track = columns.tracks[child_index];
    child.style.grow = track.grow;
    child.style.shrink = track.shrink;
    child.style.basis = track.basis;
    child.style.min_main = track.min_main;
    child.style.flex_basis = if (track.basis > 0) .{ .length = track.basis } else .auto;
    // Shared columns are row-main constraints, so this typed width mirror is
    // axis-stable even when the child itself is a column widget.
    child.style.min_size.width = if (track.min_main) |value| .{ .length = value } else .auto;
    child.flex = .{
        .grow = child.style.grow,
        .shrink = child.style.shrink,
        .basis = child.style.basis,
        .min_main = child.style.min_main,
    };
}

fn applyScrollOptions(self: *DrawCtx, id: Id, opts: anytype) void {
    const T = @TypeOf(opts);
    if (!@hasField(T, "scroll_state")) return;
    const node = self.tree.node(id).?;
    node.paint.clip = true;
    node.box.clip = true;
    node.scroll = .{
        .state = opts.scroll_state,
        .axis = if (@hasField(T, "scroll_axis"))
            @as(ScrollAxis, opts.scroll_axis)
        else
            .vertical,
    };
}

fn applyTextOptions(self: *DrawCtx, id: Id, opts: anytype) void {
    const node = self.tree.node(id).?;
    const T = @TypeOf(opts);
    if (@hasField(T, "text_overflow")) {
        node.text_overflow = @as(TextOverflow, opts.text_overflow);
    }
    if (@hasField(T, "max_width")) {
        if (asFixedLength(opts.max_width)) |max_width| node.text_max_width = max_width;
    }
}

fn asSides(x: anytype) Sides {
    const T = @TypeOf(x);
    // Partial Sides literals are allowed: absent sides stay 0.
    return .{
        .top = if (@hasField(T, "top")) asLegacySide(x.top) else 0,
        .right = if (@hasField(T, "right")) asLegacySide(x.right) else 0,
        .bottom = if (@hasField(T, "bottom")) asLegacySide(x.bottom) else 0,
        .left = if (@hasField(T, "left")) asLegacySide(x.left) else 0,
    };
}

fn asColor(x: anytype) [4]f32 {
    return .{ x[0], x[1], x[2], x[3] };
}

pub const DrawCtx = struct {
    tree: *WidgetTree,
    /// The current frame arena's allocator. Components build per-frame
    /// strings here (std.fmt.allocPrint(ctx.arena, ...)) instead of keeping
    /// scratch buffers: the allocation lives as long as the arena, and the
    /// double-buffered arenas keep the previous frame's text readable.
    arena: std.mem.Allocator,
    /// The host surface for this frame. Null keeps direct-draw contexts
    /// independent of an App and lets scenes choose their legacy layout.
    surface: ?widget.Size = null,
    /// The App's component registry + its gpa: component() registers nested
    /// components here so their buttons dispatch (dispatchClick looks the
    /// owner up in this map). Null in single-frame tests — components still
    /// draw, their buttons just never dispatch.
    registry: ?ComponentRegistry = null,
    /// Last frame's state directory (pointers into the OTHER arena, still
    /// alive while this frame builds) — the "stored version" for state().
    state_prev: ?*const StateDir = null,
    /// This frame's state directory (arena-allocated by App).
    state_cur: ?*StateDir = null,
    parent_stack: [64]Id = .{.root} ** 64,
    depth: u32 = 0,
    /// Stable identity used for component-local state and registry lookup.
    component_identity: ComponentId = .root,
    /// Generation of the frame currently being drawn.
    frame_generation: u64 = 0,
    /// App-owned stable component metadata map.
    identity_map: ?*IdentityRegistry = null,
    /// Attached GPU endpoint used to mount newly discovered components.
    gpu_endpoint: ?*GpuEndpoint = null,
    /// Frame-local widget owner retained for event dispatch compatibility.
    component_id: Id = .root,
    /// Nesting depth of pushClip()/popClip() calls. The clip rects
    /// themselves live in the tree's per-frame list (WidgetTree.
    /// clip_rects); this only balances the stack.
    clip_depth: u32 = 0,
    /// Create a node under the cursor. Container kinds do NOT descend here.
    /// The node's `.box` (CSS box model: margin/border/padding/radius) is
    /// set from the opts at creation; its `.rect` is the RELATIVE border
    /// box, filled later by the layout dispatcher.
    /// Font size from a widget's opts (0 = the host default).
    fn optsFontSize(opts: anytype) f32 {
        if (@hasField(@TypeOf(opts), "font_size")) return opts.font_size;
        return 0;
    }
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

    fn optsFontId(opts: anytype) u8 {
        if (@hasField(@TypeOf(opts), "font_id")) return opts.font_id;
        return 0;
    }

    pub fn create(
        self: *DrawCtx,
        kind: WidgetKind,
        resolved_style: Style,
        resolved_paint: PaintStyle,
        font_size: f32,
        font_id: u8,
    ) !Id {
        const id: Id = @enumFromInt(self.tree.next_id);
        self.tree.next_id += 1;

        const parent = self.parent_stack[self.depth];
        var node: widget.WidgetNode = .{
            .id = id,
            .kind = kind,
            .parent = parent,
            .font_size = font_size,
            .font_id = font_id,
        };
        node.setResolvedStyle(resolved_style, resolved_paint);
        try self.tree.nodes.append(self.arena, node);

        // Wire into the parent's children array via a linear scan (the
        // parent was created earlier, so it is already in the array).
        if (parent != .root) {
            const p = self.tree.node(parent).?;
            if (p.children.len < p.children.items.len) {
                p.children.items[p.children.len] = id;
                p.children.len += 1;
                applySharedColumnDefaults(self, id);
            }
        }
        return id;
    }

    /// Container: create + descend. The cursor becomes the new container.
    /// `gap` comes from `opts.gap` when present, else 0; `justify` and
    /// `align` set the FlexStyle distribution/alignment (start / stretch). The box model
    /// (padding/border/radius/margin) comes from the opts and lands on the
    /// node's `.box` — padding/border define where flex places children.
    pub fn column(self: *DrawCtx, opts: anytype) !Id {
        const resolved_style = styleFromOpts(opts, .column);
        const id = try self.create(
            .{ .column = .{ .gap = resolved_style.gap } },
            resolved_style,
            paintStyleFromOpts(opts),
            optsFontSize(opts),
            optsFontId(opts),
        );
        applyFlexSizing(self, id, opts);
        applyScrollOptions(self, id, opts);
        applyFlexStyle(self, id, opts);
        self.descend(id);
        return id;
    }
    /// Container: create + descend (row variant). See `column`.
    pub fn row(self: *DrawCtx, opts: anytype) !Id {
        const resolved_style = styleFromOpts(opts, .row);
        const id = try self.create(
            .{ .row = .{ .gap = resolved_style.gap } },
            resolved_style,
            paintStyleFromOpts(opts),
            optsFontSize(opts),
            optsFontId(opts),
        );
        applyFlexSizing(self, id, opts);
        if (@hasField(@TypeOf(opts), "columns")) {
            self.tree.node(id).?.shared_columns = opts.columns;
        }
        applyScrollOptions(self, id, opts);
        applyFlexStyle(self, id, opts);
        self.descend(id);
        return id;
    }
    /// Grid container: it uses the same tree container kind as column, but
    /// dispatches to the bounded grid algorithm through Style.display.
    pub fn grid(self: *DrawCtx, opts: anytype) !Id {
        var resolved_style = styleFromOpts(opts, .column);
        resolved_style.display = .grid;
        const T = @TypeOf(opts);
        if (!@hasField(T, "grid_justify_content") and @hasField(T, "justify"))
            resolved_style.grid_justify_content = resolved_style.justify;
        if (!@hasField(T, "grid_align_content") and @hasField(T, "align_content"))
            resolved_style.grid_align_content = resolved_style.align_content;
        if (!@hasField(T, "grid_justify_items") and @hasField(T, "align"))
            resolved_style.grid_justify_items = resolved_style.@"align";
        if (!@hasField(T, "grid_align_items") and @hasField(T, "align"))
            resolved_style.grid_align_items = resolved_style.@"align";
        const id = try self.create(
            .{ .column = .{ .gap = resolved_style.gap } },
            resolved_style,
            paintStyleFromOpts(opts),
            optsFontSize(opts),
            optsFontId(opts),
        );
        applyFlexSizing(self, id, opts);
        applyScrollOptions(self, id, opts);
        applyFlexStyle(self, id, opts);
        self.descend(id);
        return id;
    }

    /// Leave the current container, restoring the cursor to the enclosing
    /// parent. Also restores the post-order invariant: the container was
    /// appended before its children, so move it past them, to the end.
    pub fn pop(self: *DrawCtx) void {
        std.debug.assert(self.depth > 0);
        const id = self.parent_stack[self.depth];
        self.depth -= 1;

        // Everything after the container in the array is one of its
        // descendants (nodes are only created while the cursor is inside
        // it), so moving it to the end puts children before their container.
        var idx: usize = 0;
        var found = false;
        for (self.tree.nodes.items, 0..) |*n, i| {
            if (n.id == id) {
                idx = i;
                found = true;
                break;
            }
        }
        std.debug.assert(found); // created by column()/row()
        const node = self.tree.nodes.orderedRemove(idx);
        self.tree.nodes.appendAssumeCapacity(node); // no growth: len just shrank
    }

    /// A static text leaf. The text is DUPLICATED into the frame arena:
    /// components may hand over scratch buffers that get rewritten next
    /// frame (e.g. bufPrint results) — the tree must own a stable copy so
    /// the double-buffered previous frame keeps its original text for
    /// id-keyed dirty diffing.
    pub fn label(self: *DrawCtx, opts: anytype) !Id {
        const text = try self.arena.dupe(u8, opts.text);
        var kind: WidgetKind = .{ .label = .{ .text = text } };
        if (@hasField(@TypeOf(opts), "color")) kind.label.color = asColor(opts.color);
        const id = try self.create(
            kind,
            styleFromOpts(opts, .column),
            paintStyleFromOpts(opts),
            optsFontSize(opts),
            optsFontId(opts),
        );
        applyFlexSizing(self, id, opts);
        applyTextOptions(self, id, opts);
        return id;
    }

    /// A clickable button. `owner` binds the click to the component that
    /// created it (`component_id`); `on_click` is wrapped into a type-erased
    /// callback when `opts.on_click` is present. Label text is duplicated
    /// into the frame arena (see label()).
    ///
    /// The label is a CHILD label node, centered by the button's flex style
    /// — the text pipeline (measure + emission + color) is shared with
    /// plain labels, one path instead of a second kind arm in the
    /// renderer. The kind's `label` field still carries the text (the
    /// click-injection + hit-testing scan it).
    pub fn button(self: *DrawCtx, opts: anytype) !Id {
        var on_click: ?*const fn (*anyopaque) void = null;
        var user_callback: ?callback.UserCallback = null;
        const T = @TypeOf(opts);
        if (@hasField(T, "on_click")) on_click = callback.wrap(opts.on_click);
        if (@hasField(T, "on_click_with_data")) user_callback = opts.on_click_with_data;
        if (@hasField(T, "user_callback")) user_callback = opts.user_callback;

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

        const font_size = optsFontSize(opts);
        const font_id = optsFontId(opts);
        const id = try self.create(
            kind,
            styleFromOpts(opts, .row),
            paintStyleFromOpts(opts),
            font_size,
            font_id,
        );
        applyFlexSizing(self, id, opts);
        applyTextOptions(self, id, opts);

        // Buttons center generated labels unless the caller overrides either
        // flex axis independently.
        const node = self.tree.node(id).?;
        node.style.justify = .center;
        node.style.@"align" = .center;
        applyFlexStyle(self, id, opts);

        const visible_label = widget.buttonVisualLabel(kind);
        if (visible_label.len != 0) {
            self.descend(id);
            const label_id = try self.label(.{
                .text = visible_label,
                .color = kind.button.color,
                .font_size = font_size,
                .font_id = font_id,
            });
            applyButtonLabelSizing(self, label_id, opts);
            applyTextOptions(self, label_id, opts);
            if (@hasField(T, "text_overflow")) {
                const overflow: TextOverflow = opts.text_overflow;
                if (overflow == .ellipsis or overflow == .clip) {
                    if (@hasField(T, "max_width")) {
                        if (asFixedLength(opts.max_width)) |max_width| {
                            if (max_width > 0) {
                                // A bounded button label may shrink to its parent's
                                // final content box instead of its natural width.
                                self.tree.node(label_id).?.style.min_main = 0;
                                self.tree.node(label_id).?.flex.min_main = 0;
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
    pub fn slider(self: *DrawCtx, opts: anytype) !Id {
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
            styleFromOpts(opts, .column),
            paintStyleFromOpts(opts),
            optsFontSize(opts),
            optsFontId(opts),
        );
        applyFlexSizing(self, id, opts);
        return id;
    }
    /// An empty spacer of the given size (`opts.size`, default 0). Box
    /// fields are allowed but inert: the size still rules the node.
    pub fn spacer(self: *DrawCtx, opts: anytype) !Id {
        var size: f32 = 0;
        if (@hasField(@TypeOf(opts), "size")) size = opts.size;
        const id = try self.create(
            .{ .spacer = .{ .size = size } },
            styleFromOpts(opts, .column),
            paintStyleFromOpts(opts),
            optsFontSize(opts),
            optsFontId(opts),
        );
        applyFlexSizing(self, id, opts);
        return id;
    }

    /// Push a clip rect onto the frame's clip-rect list, returning its
    /// clip id (or 0xFFFFFFFF when the list is full — the clip is then
    /// skipped). The id stamps onto the clip-marked container's draw
    /// commands: the `.clip` box option wires this automatically (the
    /// declarative path the demo uses); pushClip is the programmatic API
    /// for widgets that know their rect at draw time (scroll containers).
    /// popClip() balances the push. The list is append-only — ids stay
    /// valid for the frame.
    pub fn pushClip(self: *DrawCtx, x: f32, y: f32, w: f32, h: f32) u32 {
        const id = self.tree.pushClipRect(.{ .x = x, .y = y, .w = w, .h = h }) orelse return 0xFFFFFFFF;
        self.clip_depth += 1;
        return id;
    }

    /// Balance a pushClip(): restores the clip nesting depth. Rects are
    /// never removed from the list (ids must stay stable), so pop only
    /// tracks the stack.
    pub fn popClip(self: *DrawCtx) void {
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
        const child_identity = ComponentId.child(self.component_identity, options.key);
        const child_component = Component.make(T, ptr);
        if (self.identity_map) |identity_map| {
            const entry = try identity_map.map.getOrPut(identity_map.gpa, child_identity);
            if (entry.found_existing and entry.value_ptr.last_seen_frame == self.frame_generation) {
                return error.DuplicateComponentIdentity;
            }
            entry.value_ptr.component = child_component;
            entry.value_ptr.last_seen_frame = self.frame_generation;
            if (!entry.found_existing) {
                entry.value_ptr.gpu_initialized = false;
            }
            if (self.gpu_endpoint) |endpoint| {
                if (!entry.value_ptr.gpu_initialized) {
                    if (child_component.vtable.init_gpu) |init_gpu| {
                        try init_gpu(child_component.ptr, endpoint);
                    }
                    entry.value_ptr.gpu_initialized = true;
                }
            }
        }

        const saved_identity = self.component_identity;
        const saved_owner = self.component_id;
        defer {
            self.component_identity = saved_identity;
            self.component_id = saved_owner;
        }
        self.component_identity = child_identity;
        self.component_id = @enumFromInt(self.tree.next_id);
        self.tree.next_id += 1;
        if (self.registry) |reg| {
            try reg.map.put(reg.gpa, self.component_id, child_component);
        }
        try child_component.vtable.draw(ptr, self);
    }

    /// useState-like inter-frame transient state, component-local: `name`
    /// is scoped to the current stable component identity, so sibling
    /// insertion and widget-node renumbering do not move the stored value.
    /// Returns a pointer to a FRESH T in the frame arena, valid until reset.
    pub fn state(self: *DrawCtx, comptime T: type, name: []const u8, init: T) !*T {
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
        for (cur.items) |sr| {
            // Provenance: every ptr was arena.create(T) (properly aligned)
            // before being stored as *anyopaque — the alignCast can never
            // fail; zbc flags it because it cannot track the provenance
            // through the type erasure.
            if (sr.key.eql(key)) return @ptrCast(@alignCast(sr.ptr));
        }
        const p = try self.arena.create(T);
        var seeded = false;
        if (self.state_prev) |prev| {
            for (prev.items) |sr| {
                if (sr.key.eql(key)) {
                    @memcpy(
                        @as([*]u8, @ptrCast(p))[0..@sizeOf(T)],
                        @as([*]const u8, @ptrCast(sr.ptr))[0..@sizeOf(T)],
                    );
                    seeded = true;
                    break;
                }
            }
        }
        if (!seeded) p.* = init;
        try cur.append(self.arena, .{ .key = key, .ptr = p });
        return p;
    }

    /// Cursor descends into a container: it becomes the parent for nodes
    /// created until the matching `pop()`.
    fn descend(self: *DrawCtx, id: Id) void {
        self.depth += 1;
        self.parent_stack[self.depth] = id;
    }
};

test "DrawCtx: two-level cursor nesting wires parents and children" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const col = try ctx.column(.{});
    const inner_label = try ctx.label(.{ .text = "a" });
    const inner_button = try ctx.button(.{ .label = "B" });
    ctx.pop();
    const outer_label = try ctx.label(.{ .text = "b" });

    // Parents: the column's children point at it; the label after pop() is
    // back at the root.
    try std.testing.expectEqual(col, tree.node(inner_label).?.parent);
    try std.testing.expectEqual(col, tree.node(inner_button).?.parent);
    try std.testing.expectEqual(Id.root, tree.node(outer_label).?.parent);

    // Children adjacency, in creation order. The button's label is the
    // BUTTON's child, not the column's.
    const col_node = tree.node(col).?;
    try std.testing.expectEqual(@as(u8, 2), col_node.children.len);
    try std.testing.expectEqual(inner_label, col_node.children.items[0]);
    try std.testing.expectEqual(inner_button, col_node.children.items[1]);

    // The button's child is its label (a label node with the button's text).
    const btn_node = tree.node(inner_button).?;
    try std.testing.expectEqual(@as(u8, 1), btn_node.children.len);
    const btn_label_id = btn_node.children.items[0];
    const btn_label = tree.node(btn_label_id).?;
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

test "DrawCtx: pop() restores the cursor" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const col = try ctx.column(.{});
    const inner = try ctx.label(.{ .text = "inner" });
    ctx.pop();

    // New nodes after pop() land under .root, not under the column.
    const after = try ctx.label(.{ .text = "outer" });
    try std.testing.expectEqual(Id.root, tree.node(after).?.parent);

    // The column's children are unaffected by pop().
    const col_node = tree.node(col).?;
    try std.testing.expectEqual(@as(u8, 1), col_node.children.len);
    try std.testing.expectEqual(inner, col_node.children.items[0]);
}

test "DrawCtx: button owner binds to component_id, incl. inside component()" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    // At the root the owner is .root (the implicit root component).
    const root_button = try ctx.button(.{ .label = "root" });
    try std.testing.expectEqual(Id.root, tree.node(root_button).?.kind.button.owner);

    const Child = struct {
        const Self = @This();

        pub fn draw(self: *Self, c: *DrawCtx) anyerror!void {
            _ = self;
            _ = try c.button(.{ .label = "child" });
        }
    };
    var child: Child = .{};
    try ctx.component(Child, .{ .key = .{ .static = "child" } }, &child);

    // The component took the next id (3 — 2 was the root button's child
    // label); the inner button (id 4) is owned by the child component,
    // and component_id was restored afterwards.
    const inner: Id = @enumFromInt(4);
    try std.testing.expectEqual(@as(Id, @enumFromInt(3)), tree.node(inner).?.kind.button.owner);
    try std.testing.expectEqual(Id.root, ctx.component_id);

    // A later button is owned by the root component again.
    const later = try ctx.button(.{ .label = "later" });
    try std.testing.expectEqual(Id.root, tree.node(later).?.kind.button.owner);
}

test "DrawCtx: component() draws into the current cursor" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
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
    const root_label: Id = @enumFromInt(2);
    try std.testing.expectEqual(Id.root, tree.node(root_label).?.parent);

    // Drawn inside a column: the child's node lands under the column.
    var arena2 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena2.deinit();
    var tree2 = WidgetTree.init(arena2.allocator());
    defer tree2.nodes.deinit(arena2.allocator());
    var ctx2: DrawCtx = .{ .tree = &tree2, .arena = arena2.allocator() };

    const col = try ctx2.column(.{});
    try ctx2.component(Child, .{ .key = .{ .static = "child" } }, &child);
    ctx2.pop();

    // ids: column = 1, component = 2, child label = 3.
    const nested: Id = @enumFromInt(3);
    try std.testing.expectEqual(col, tree2.node(nested).?.parent);
    const col_node = tree2.node(col).?;
    try std.testing.expectEqual(@as(u8, 1), col_node.children.len);
    try std.testing.expectEqual(nested, col_node.children.items[0]);
}

test "DrawCtx: justify and align flow into the node's FlexStyle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
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
    try std.testing.expectEqual(Justify.start, tree.node(plain).?.style.justify);
    try std.testing.expectEqual(Align.stretch, tree.node(plain).?.style.@"align");
}
test "DrawCtx: button label honors justify and align overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const button = try ctx.button(.{
        .label = "start",
        .justify = .start,
        .@"align" = .end,
    });
    const button_node = tree.node(button).?;
    const label_id = button_node.children.items[0];

    try std.testing.expectEqual(Justify.start, button_node.style.justify);
    try std.testing.expectEqual(Align.end, button_node.style.@"align");
    try std.testing.expectEqualStrings("start", tree.node(label_id).?.kind.label.text);

    layout(&tree, .{ .width = 120, .height = 40 });
    try std.testing.expectEqual(@as(f32, 0), tree.node(label_id).?.rect.x);
}
test "DrawCtx: semantic and visual labels are copied, empty override stays explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    var button_text = [_]u8{ 'B', 'u', 't', 't', 'o', 'n' };
    var semantic_text = [_]u8{ 'S', 'e', 'm' };
    var slider_text = [_]u8{ 'S', 'l', 'i', 'd', 'e', 'r' };
    var visual_text = [_]u8{ 'V', 'i', 's' };
    var value: f32 = 0.5;

    const button = try ctx.button(.{
        .label = button_text[0..],
        .accessible_label = semantic_text[0..],
    });
    const slider = try ctx.slider(.{
        .label = slider_text[0..],
        .visual_label = visual_text[0..],
        .value = &value,
        .min = 0,
        .max = 1,
    });
    const hidden = try ctx.slider(.{
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

    const button_kind = tree.node(button).?.kind.button;
    try std.testing.expectEqualStrings("Button", button_kind.label);
    try std.testing.expectEqualStrings("Sem", button_kind.accessible_label.?);
    const slider_kind = tree.node(slider).?.kind.slider;
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
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const Counter = struct {
        const Self = @This();

        fn click(self: *Self) void {
            _ = self;
        }
    };
    const button = try ctx.button(.{
        .label = "Play",
        .accessible_label = "Play",
        .icon = @as(widget.IconId, .play),
        .on_click = Counter.click,
        .basis = 24,
        .min_main = 24,
        .shrink = 0,
    });

    layout(&tree, .{ .width = 80, .height = 40 });
    const button_node = tree.node(button).?;
    const button_kind = button_node.kind.button;
    try std.testing.expectEqual(@as(u8, 0), button_node.children.len);
    try std.testing.expectEqualStrings("Play", button_kind.accessible_label.?);
    try std.testing.expectEqual(widget.IconId.play, button_kind.icon.?);
    try std.testing.expect(button_kind.on_click != null);
    try std.testing.expect(button_node.rect.w > 0);
    try std.testing.expect(button_node.rect.h > 0);

    const bounds = widget.visualBorderRect(&tree, button);
    const hit = hitButton(&tree, .{ bounds.x + bounds.w / 2, bounds.y + bounds.h / 2 });
    try std.testing.expectEqual(button, hit.?);
}

test "DrawCtx: container gap comes from opts, defaults to 0" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const gapped_col = try ctx.column(.{ .gap = 4 });
    ctx.pop();
    const plain_col = try ctx.column(.{});
    ctx.pop();
    const gapped_row = try ctx.row(.{ .gap = 7 });
    ctx.pop();
    const plain_row = try ctx.row(.{});
    ctx.pop();

    try std.testing.expectEqual(@as(f32, 4), tree.node(gapped_col).?.kind.column.gap);
    try std.testing.expectEqual(@as(f32, 0), tree.node(plain_col).?.kind.column.gap);
    try std.testing.expectEqual(@as(f32, 7), tree.node(gapped_row).?.kind.row.gap);
    try std.testing.expectEqual(@as(f32, 0), tree.node(plain_row).?.kind.row.gap);
}

test "DrawCtx: button on_click is wrapped via callback.wrap when provided" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    // No on_click in opts -> null callback.
    const plain = try ctx.button(.{ .label = "no handler" });
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
    const wired = try ctx.button(.{ .label = "go", .on_click = Counter.click });
    const cb = tree.node(wired).?.kind.button.on_click.?;
    cb(@ptrCast(&counter));
    try std.testing.expectEqual(@as(u32, 1), counter.n);
}

test "DrawCtx: shared columns inherit direct-child flex sizing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const tracks = [_]ColumnTrack{
        .{ .grow = 2, .shrink = 0.5, .basis = 40, .min_main = 12 },
        .{ .grow = 3, .shrink = 0.25, .basis = 60, .min_main = 20 },
    };
    const columns: SharedColumns = .{ .tracks = &tracks };
    const row = try ctx.row(.{ .columns = &columns });
    const first = try ctx.label(.{ .text = "first" });
    const second = try ctx.label(.{
        .text = "second",
        .grow = 9,
        .shrink = 0.75,
        .basis = 90,
        .min_main = 30,
    });
    const button = try ctx.button(.{ .label = "button" });
    ctx.pop();

    try std.testing.expectEqual(row, tree.node(first).?.parent);
    try std.testing.expectEqual(row, tree.node(second).?.parent);
    try std.testing.expectEqual(row, tree.node(button).?.parent);
    try std.testing.expectEqual(@as(f32, 2), tree.node(first).?.flex.grow);
    try std.testing.expectEqual(@as(f32, 0.5), tree.node(first).?.flex.shrink);
    try std.testing.expectEqual(@as(f32, 40), tree.node(first).?.flex.basis);
    try std.testing.expectEqual(@as(?f32, 12), tree.node(first).?.flex.min_main);
    try std.testing.expectEqual(@as(f32, 9), tree.node(second).?.flex.grow);
    try std.testing.expectEqual(@as(f32, 0.75), tree.node(second).?.flex.shrink);
    try std.testing.expectEqual(@as(f32, 90), tree.node(second).?.flex.basis);
    try std.testing.expectEqual(@as(?f32, 30), tree.node(second).?.flex.min_main);
    // The button is the third child, so it is outside the two-track layout.
    try std.testing.expectEqual(@as(f32, 0), tree.node(button).?.flex.grow);
    try std.testing.expectEqual(@as(f32, 1), tree.node(button).?.flex.shrink);
    try std.testing.expectEqual(@as(f32, 0), tree.node(button).?.flex.basis);
    try std.testing.expectEqual(@as(?f32, null), tree.node(button).?.flex.min_main);
}

test "DrawCtx: button label does not consume shared column track" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const tracks = [_]ColumnTrack{
        .{ .grow = 1, .basis = 25 },
        .{ .grow = 4, .basis = 75 },
    };
    const columns: SharedColumns = .{ .tracks = &tracks };
    const row = try ctx.row(.{ .columns = &columns });
    const button = try ctx.button(.{ .label = "button" });
    const sibling = try ctx.label(.{ .text = "sibling" });
    ctx.pop();

    const button_node = tree.node(button).?;
    const button_label = tree.node(button_node.children.items[0]).?;
    try std.testing.expectEqual(@as(f32, 1), button_node.flex.grow);
    try std.testing.expectEqual(@as(f32, 25), button_node.flex.basis);
    try std.testing.expectEqual(@as(f32, 0), button_label.flex.grow);
    try std.testing.expectEqual(@as(f32, 0), button_label.flex.basis);
    try std.testing.expectEqual(@as(f32, 4), tree.node(sibling).?.flex.grow);
    try std.testing.expectEqual(@as(f32, 75), tree.node(sibling).?.flex.basis);
    try std.testing.expectEqual(row, button_node.parent);
}

test "DrawCtx: scroll options wire state, axis, and clipping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
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

    try std.testing.expect(tree.node(column).?.box.clip);
    try std.testing.expect(tree.node(row).?.box.clip);
    try std.testing.expectEqual(&column_state, tree.node(column).?.scroll.?.state);
    try std.testing.expectEqual(ScrollAxis.vertical, tree.node(column).?.scroll.?.axis);
    try std.testing.expectEqual(&row_state, tree.node(row).?.scroll.?.state);
    try std.testing.expectEqual(ScrollAxis.both, tree.node(row).?.scroll.?.axis);
}

test "DrawCtx: box fields from opts flow into the node's box" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const id = try ctx.label(.{
        .text = "boxed",
        .margin = .{ .top = 1, .right = 2, .bottom = 3, .left = 4 },
        .padding = .{ .top = 5, .right = 6, .bottom = 7, .left = 8 },
        .border = .{ .top = 9, .right = 10, .bottom = 11, .left = 12 },
        .border_color = .{ 0.1, 0.2, 0.3, 0.4 },
        .radius = .{ .top = 13, .right = 14, .bottom = 15, .left = 16 },
        .box_sizing = .border_box,
    });

    try std.testing.expectEqual(Box{
        .margin = .{ .top = 1, .right = 2, .bottom = 3, .left = 4 },
        .padding = .{ .top = 5, .right = 6, .bottom = 7, .left = 8 },
        .border = .{ .top = 9, .right = 10, .bottom = 11, .left = 12 },
        .border_color = .{ 0.1, 0.2, 0.3, 0.4 },
        .radius = .{ .top = 13, .right = 14, .bottom = 15, .left = 16 },
        .box_sizing = .border_box,
    }, tree.node(id).?.box);

    // The same opts flow into container boxes too (column and row).
    const col = try ctx.column(.{ .padding = .{ .top = 8, .left = 8 } });
    ctx.pop();
    const row = try ctx.row(.{ .border = .{ .top = 2 } });
    ctx.pop();
    try std.testing.expectEqual(Box{ .padding = .{ .top = 8, .left = 8 } }, tree.node(col).?.box);
    try std.testing.expectEqual(Box{ .border = .{ .top = 2 } }, tree.node(row).?.box);
}

test "DrawCtx: absent box fields leave Box defaults" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const plain_label = try ctx.label(.{ .text = "plain" });
    const plain_button = try ctx.button(.{ .label = "B" });
    var slider_value: f32 = 0.5;
    const plain_slider = try ctx.slider(.{ .label = "S", .value = &slider_value, .min = 0, .max = 1 });
    const plain_spacer = try ctx.spacer(.{});
    const plain_col = try ctx.column(.{ .gap = 4 });
    ctx.pop();

    // No box fields in the opts -> the node carries Box{} exactly.
    try std.testing.expectEqual(Box{}, tree.node(plain_label).?.box);
    try std.testing.expectEqual(Box{}, tree.node(plain_button).?.box);
    try std.testing.expectEqual(Box{}, tree.node(plain_slider).?.box);
    try std.testing.expectEqual(Box{}, tree.node(plain_spacer).?.box);
    try std.testing.expectEqual(Box{}, tree.node(plain_col).?.box);
}

test "DrawCtx: the .layer box option lands on the node's box" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    // Any widget kind carries the option: a container, a label, a button.
    const layered_col = try ctx.column(.{ .layer = 3 });
    ctx.pop();
    const layered_label = try ctx.label(.{ .text = "layer", .layer = 1 });
    try std.testing.expectEqual(@as(u32, 3), tree.node(layered_col).?.box.layer);
    try std.testing.expectEqual(@as(u32, 1), tree.node(layered_label).?.box.layer);

    // Absent -> the Box default (0 = the base tree).
    const plain_col = try ctx.column(.{});
    ctx.pop();
    try std.testing.expectEqual(@as(u32, 0), tree.node(plain_col).?.box.layer);
}

test "DrawCtx: the .clip opt lands on the container box; pushClip appends to the tree's clip list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const card = try ctx.column(.{ .clip = true });
    ctx.pop();
    try std.testing.expect(tree.node(card).?.box.clip);

    // Programmatic clips append to the SAME list the declarative path
    // uses (collectDrawCmds reads it); ids are stable indices.
    const id0 = ctx.pushClip(10, 20, 30, 40);
    const id1 = ctx.pushClip(50, 60, 70, 80);
    ctx.popClip();
    ctx.popClip();
    try std.testing.expectEqual(@as(u32, 0), id0);
    try std.testing.expectEqual(@as(u32, 1), id1);
    try std.testing.expectEqual(@as(u32, 2), tree.clip_count);
    try std.testing.expectEqual(@as(f32, 30), tree.clip_rects[0].w);
    try std.testing.expectEqual(@as(f32, 80), tree.clip_rects[1].h);
}
test "DrawCtx: legacy basis and min_main stay in the parent-axis flex model" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
    const id = try ctx.label(.{ .text = "typed", .basis = 30, .min_main = 12 });
    const node = tree.node(id).?;
    switch (node.style.flex_basis) {
        .length => |value| try std.testing.expectEqual(@as(f32, 30), value),
        else => try std.testing.expect(false),
    }
    try std.testing.expectEqual(@as(f32, 30), node.style.basis);
    try std.testing.expectEqual(@as(?f32, 12), node.style.min_main);
    try std.testing.expect(std.meta.eql(@as(style.Dimension, .auto), node.style.min_size.height));
}

test "DrawCtx: min_main conversion accepts optionals and fixed dimensions" {
    const optional_number: ?u16 = 9;
    const optional_fixed: ?style.Dimension = style.Dimension.fixed(18);

    try std.testing.expectEqual(@as(?f32, 9), asOptionalF32(optional_number));
    try std.testing.expectEqual(@as(?f32, 18), asOptionalF32(optional_fixed));
    try std.testing.expectEqual(
        @as(?f32, null),
        asOptionalF32(style.Dimension.percentage(0.5)),
    );
    try std.testing.expectEqual(
        @as(?f32, null),
        asOptionalF32(@as(style.Dimension, .min_content)),
    );
}

test "DrawCtx: fixed and percentage min_main retain legacy axis semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const fixed_id = try ctx.label(.{
        .text = "fixed",
        .min_main = style.Dimension.fixed(18),
    });
    const fixed = tree.node(fixed_id).?;
    try std.testing.expectEqual(@as(?f32, 18), fixed.style.min_main);
    try std.testing.expect(std.meta.eql(@as(style.Dimension, .auto), fixed.style.min_size.height));

    const percent_id = try ctx.label(.{
        .text = "percent",
        .min_main = style.Dimension.percentage(0.5),
    });
    const percent = tree.node(percent_id).?;
    try std.testing.expectEqual(@as(?f32, null), percent.style.min_main);
    try std.testing.expect(std.meta.eql(
        @as(style.Dimension, .auto),
        percent.style.min_size.height,
    ));
}

test "DrawCtx: constructor translates display and position into Style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const id = try ctx.column(.{ .display = .block, .position = .absolute });
    ctx.pop();

    try std.testing.expectEqual(style.Display.block, tree.node(id).?.style.display);
    try std.testing.expectEqual(style.Position.absolute, tree.node(id).?.style.position);
}

test "DrawCtx: wrapped flex options translate into typed Style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const id = try ctx.row(.{
        .direction = .row_reverse,
        .wrap = .wrap_reverse,
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

    const resolved = tree.node(id).?.style;
    try std.testing.expectEqual(style.FlexDirection.row_reverse, resolved.direction);
    try std.testing.expectEqual(style.FlexWrap.wrap_reverse, resolved.wrap);
    try std.testing.expectEqual(style.AlignContent.space_around, resolved.align_content);
    try std.testing.expectEqual(style.AlignSelf.end, resolved.align_self);
    try std.testing.expect(std.meta.eql(@as(style.LengthPercentageAuto, .auto), resolved.margin_inset.top));
}

test "DrawCtx: grid constructor translates tracks placement and gaps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
    const tracks = [_]style.GridTrack{ .{ .fixed = 32 }, .{ .fr = 1 } };

    const id = try ctx.grid(.{
        .grid_template_columns = tracks[0..],
        .grid_column_gap = 4,
        .grid_row_gap = 8,
        .grid_auto_flow = .column,
        .grid_column = .{
            .start = .{ .line = 1 },
            .end = .{ .span = 2 },
        },
    });
    ctx.pop();
    const resolved = tree.node(id).?.style;
    try std.testing.expectEqual(style.Display.grid, resolved.display);
    try std.testing.expectEqual(@as(usize, 2), resolved.grid_template_columns.len);
    try std.testing.expectEqual(@as(f32, 4), resolved.grid_column_gap);
    try std.testing.expectEqual(style.GridAutoFlow.column, resolved.grid_auto_flow);
}
