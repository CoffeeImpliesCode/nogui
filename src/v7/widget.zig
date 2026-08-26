//! v7 widget types — geometry, per-child flex data, kind union, and the
//! per-frame widget tree.
//! Per the prototype spec (notes/v7-prototype-spec.md §2).
const std = @import("std");

const Id = @import("id.zig").Id;
const callback = @import("callback.zig");
const style = @import("style.zig");

pub const PaintStyleOverride = style.PaintStyleOverride;
pub const ComponentDefaults = style.ComponentDefaults;
pub const Style = style.Style;
pub const PaintStyle = style.PaintStyle;
pub const StyleOverride = style.StyleOverride;
pub const Display = style.Display;
pub const Position = style.Position;
pub const FlexDirection = style.FlexDirection;
pub const FlexWrap = style.FlexWrap;
pub const Justify = style.Justify;
pub const Align = style.Align;
pub const AlignContent = style.AlignContent;
pub const AlignSelf = style.AlignSelf;
pub const GridTrackBreadth = style.GridTrackBreadth;
pub const GridMinMax = style.GridMinMax;
pub const GridTrack = style.GridTrack;
pub const GridPlacement = style.GridPlacement;
pub const GridLine = style.GridLine;
pub const GridAutoFlow = style.GridAutoFlow;
pub const Sides = style.Sides;
pub const BoxSizing = style.BoxSizing;
pub const Dimension = style.Dimension;
pub const LengthPercentage = style.LengthPercentage;
pub const LengthPercentageAuto = style.LengthPercentageAuto;
pub const TypedSize = style.Size;
pub const TypedRect = style.Rect;
pub const Insets = style.Insets;
pub const Overflow = style.Overflow;
pub const OverflowAxes = style.OverflowAxes;
pub const ResolvedStyle = style.ResolvedStyle;
pub const ResolvedDimensions = style.ResolvedDimensions;
pub const ResolvedConstraints = style.ResolvedConstraints;
pub const ResolvedInsets = style.ResolvedInsets;
pub const DimensionSize = style.DimensionSize;
pub const LengthPercentageSize = style.LengthPercentageSize;
pub const LengthPercentageAutoSize = style.LengthPercentageAutoSize;
pub const LengthPercentageRect = style.LengthPercentageRect;
pub const DimensionOverride = style.DimensionOverride;
pub const ExplicitOverride = style.ExplicitOverride;
/// Axis-aligned rectangle in layout space.
///
/// RELATIVE semantics: a node's rect is its BORDER box, positioned relative
/// to its PARENT'S CONTENT box (root-level nodes: relative to the surface).
/// Absolute positions are resolved on demand via `absoluteRect` /
/// `absoluteBorderOrigin` (a parent walk). Keeping rects relative lets a
/// subtree move as a unit and makes the double-buffered prev_tree diff
/// meaningful (a parent offset change does not invalidate child rects).
pub const Rect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };

/// Border and padding resolved against the layout pass's containing basis.
pub const ResolvedBoxEdges = struct {
    border: Sides,
    padding: Sides,
};

/// Available / required space.
pub const Size = struct { width: f32, height: f32 };

/// A clip rectangle in layout (framebuffer px) space. The GPU clip
/// buffer stores these verbatim (four f32, 16 bytes — the fragment
/// shader's `pc.indirect + 16 * clip_id` stride); the shader discards
/// fragments outside the rect indexed by a vertex's clip_id.
/// 0xFFFFFFFF (no clip id) = no clip.
pub const ClipRect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// Horizontal+vertical sums of a Sides (for content-box derivation).
pub fn sidesSum(s: Sides) struct { w: f32, h: f32 } {
    return .{ .w = s.left + s.right, .h = s.top + s.bottom };
}

/// Sizing parameters for one shared column track.
pub const ColumnTrack = struct {
    grow: f32 = 0,
    shrink: f32 = 1,
    basis: f32 = 0,
    min_main: ?f32 = null,
};

/// Column tracks shared by compatible row children.
pub const SharedColumns = struct {
    tracks: []const ColumnTrack,
};

/// Scrollable axes.
pub const ScrollAxis = enum { vertical, horizontal, both };

/// Mutable scroll offsets and their layout-derived limits.
pub const ScrollState = struct {
    offset: [2]f32 = .{ 0, 0 },
    max_offset: [2]f32 = .{ 0, 0 },
};

/// Scroll behavior for a widget node.
pub const ScrollSpec = struct {
    state: *ScrollState,
    axis: ScrollAxis = .vertical,
};

/// Text overflow behavior.
pub const TextOverflow = enum { visible, clip, ellipsis };

/// A window-rendered SVG icon. This stays value-only so the widget tree
/// remains independent of the GPU cache that owns its path materials.
pub const IconId = enum {
    heart,
    heart_filled,
    shuffle,
    previous,
    play,
    pause,
    next,
    repeat,
    queue,
    devices,
    volume,
};
/// Visible rail height for sliders whose visual label is intentionally hidden.
/// Layout owns this shared intrinsic so such controls remain paintable and
/// interactive without caller-specific vertical padding.
pub const slider_rail_height: f32 = 4;

/// Paint-only thumb geometry. The fixed width keeps the marker visible over
/// both the filled progress and the unfilled rail; this does not increase the
/// slider's intrinsic or pointer-hit height.
pub const slider_thumb_width: f32 = 10;

pub fn sliderThumbRect(rail: Rect, fraction: f32) Rect {
    const width = @min(slider_thumb_width, rail.w);
    const x = rail.x + std.math.clamp(fraction, 0, 1) * @max(0, rail.w - width);
    return .{
        .x = x,
        .y = rail.y,
        .w = width,
        .h = rail.h,
    };
}

/// What a widget node is. Payload differs per kind; fields with defaults
/// may be omitted at construction.
pub const WidgetKind = union(enum) {
    column: struct { gap: f32 = 0 },
    row: struct { gap: f32 = 0 },
    /// `color` is the text color in sRGB (converted to Oklab by the
    /// renderer, like every widget color); default = white.
    label: struct { text: []const u8, color: [4]f32 = .{ 1, 1, 1, 1 } },
    button: struct {
        /// Semantic name retained for input dispatch and accessibility.
        label: []const u8,
        /// Optional visible text. Null uses `label` for text buttons; icons
        /// default to no text. An empty slice explicitly suppresses text.
        visual_label: ?[]const u8 = null,
        /// Optional window-owned SVG cache key; no GPU state belongs here.
        icon: ?IconId = null,
        /// Optional semantic name for assistive technologies; `label` remains
        /// the semantic fallback when this is absent.
        accessible_label: ?[]const u8 = null,
        color: [4]f32 = .{ 1, 1, 1, 1 },
        on_click: ?*const fn (*anyopaque) void = null, // set via callback.wrap()
        owner: Id = .root, // component_id at creation time
        user_callback: ?callback.UserCallback = null,
    },
    slider: struct {
        /// Semantic label retained for diagnostics and machine-readable output.
        label: []const u8,
        /// Optional text shown beside the slider. Null falls back to `label`;
        /// an empty slice intentionally suppresses visible text.
        visual_label: ?[]const u8 = null,
        color: [4]f32 = .{ 1, 1, 1, 1 },
        value: *f32,
        min: f32,
        max: f32,
    },
    spacer: struct { size: f32 = 0 },
};

/// Return a button's visible text while keeping its semantic label intact.
/// Icon buttons intentionally default to no text; an explicit visual label
/// can still opt into a mixed icon-and-text button.
pub fn buttonVisualLabel(kind: WidgetKind) []const u8 {
    return switch (kind) {
        .button => |b| b.visual_label orelse if (b.icon != null) "" else b.label,
        else => unreachable,
    };
}

/// Return the text a slider should display while preserving its semantic label
/// in the slider payload. A null visual label falls back to that label; an
/// explicitly empty visual label remains empty and suppresses visible text.
pub fn sliderVisualLabel(kind: WidgetKind) []const u8 {
    return switch (kind) {
        .slider => |s| s.visual_label orelse s.label,
        else => unreachable,
    };
}

/// One node in the tree.
pub const WidgetNode = struct {
    id: Id,
    kind: WidgetKind,
    parent: Id,
    children: std.ArrayListUnmanaged(Id) = .empty,
    /// BORDER box, positioned relative to the parent's CONTENT box (see
    /// Rect's doc). Filled by the layout dispatcher.
    rect: Rect = .{},
    /// First baseline from the border-box top after final child placement.
    /// Null means the node has no natural baseline.
    first_baseline: ?f32 = null,
    /// Resolved typed layout values. This is the canonical flex/style view.
    resolved_style: ResolvedStyle = .{},
    resolved_dimensions: ResolvedDimensions = .{},
    resolved_insets: ResolvedInsets = .{
        .top = null,
        .right = null,
        .bottom = null,
        .left = null,
    },
    resolved_constraints: ResolvedConstraints = .{},
    resolved_aspect_ratio: ?f32 = null,
    resolved_overflow: OverflowAxes = .{ .width = .visible, .height = .visible },
    /// Border and padding resolved against the layout pass's containing basis.
    resolved_box_edges: ?ResolvedBoxEdges = null,
    /// True when the current block layout pass hides this node through itself or
    /// an ancestor. Recomputed at every direct block layout entry.
    layout_hidden: bool = false,
    /// Resolved typed layout values. This is the canonical flex/style view.
    style: Style = .{},
    /// Resolved typed paint values. This is the canonical paint view.
    paint: PaintStyle = .{},
    scroll: ?ScrollSpec = null,
    text_overflow: TextOverflow = .visible,
    text_max_width: ?f32 = null,
    shared_columns: ?*const SharedColumns = null,
    /// Font size in px for text-bearing nodes; 0 = the host's default.
    /// Set from opts.font_size; the measure hook and the text engine
    /// dispatch on it.
    font_size: f32 = 0,
    /// Font selection: 0 = the host default font, 1 = the second font.
    font_id: u8 = 0,
    /// The item's natural (measured/hugged) main size before any basis
    /// override, recorded by the parent when placing. The flex-shrink
    /// floor: shrink never crosses it (the canonical automatic minimum,
    /// CSS flexbox §4.5). Filled by flex.layout().
    natural_main: f32 = 0,
    /// The clip rect id (index into WidgetTree.clip_rects) enclosing this
    /// node, stamped by collectDrawCmds during its walk; 0xFFFFFFFF = no
    /// clip. The renderer clips the node's glyphs to that rect.
    clip_id: u32 = 0xFFFFFFFF,

    /// Resolve typed dimensions, constraints, insets, and overflow for the
    /// containing block known by the current layout pass.
    pub fn resolveTypedStyle(
        self: *WidgetNode,
        containing: ?Size,
        intrinsic: Size,
    ) void {
        const width_containing = if (containing) |value| value.width else null;
        const height_containing = if (containing) |value| value.height else null;
        self.resolveTypedStyleAxes(width_containing, height_containing, intrinsic);
    }

    /// Resolve typed values with independent width and height definiteness.
    pub fn resolveTypedStyleAxes(
        self: *WidgetNode,
        width_containing: ?f32,
        height_containing: ?f32,
        intrinsic: Size,
    ) void {
        const resolved = self.style.resolveTotalAxes(
            width_containing,
            height_containing,
            style.Size(f32){ .width = intrinsic.width, .height = intrinsic.height },
        );
        self.resolved_style = resolved;
        self.resolved_dimensions = resolved.dimensions;
        self.resolved_insets = resolved.insets;
        self.resolved_constraints = resolved.constraints;
        self.resolved_aspect_ratio = resolved.aspect_ratio;
        self.resolved_overflow = resolved.overflow;
    }
};

/// The per-frame widget tree.
///
/// Invariant: node order is **post-order** — a node's children are appended
/// before the node itself. A container therefore appears after all of its
/// descendants, so flex.layout() can run bottom-up in one pass.
///
/// Storage is owned by the caller (the frame arena, see drawctx.zig); the
/// tree must be re-created per frame, never reused across a reset.
pub const WidgetTree = struct {
    nodes: std.ArrayListUnmanaged(WidgetNode) = .empty,
    allocator: std.mem.Allocator,
    next_id: u32 = 1,
    /// Frame-local index maintained by `appendNode` for production trees.
    /// Directly assembled trees can leave it incomplete; lookup then scans.
    id_index: std.AutoHashMapUnmanaged(Id, u32) = .empty,
    /// Per-frame clip-rect list (cap 64 = the GPU clip buffer's size). Clip
    /// ids are indices into this list; 0xFFFFFFFF = no clip. The core
    /// appends here (DrawCtx.pushClip + drawcmd's clip-stack walk); the
    /// renderer copies the list into the GPU clip buffer each frame.
    /// Append-only per frame — ids must stay stable for the frame.
    // SAFETY: written only via pushClipRect before any read; clip_count tracks the filled count
    clip_rects: [64]ClipRect = undefined,
    clip_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) WidgetTree {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WidgetTree) void {
        for (self.nodes.items) |*node_value| {
            node_value.children.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.id_index.deinit(self.allocator);
        self.* = undefined;
    }

    /// Append a node and atomically add its frame-local lookup entry.
    pub fn appendNode(self: *WidgetTree, node_value: WidgetNode) !void {
        try self.nodes.append(self.allocator, node_value);
        errdefer _ = self.nodes.pop();
        try self.id_index.put(
            self.allocator,
            node_value.id,
            @intCast(self.nodes.items.len - 1),
        );
    }

    /// Append a child id through the tree-owned frame allocator.
    pub fn appendChild(self: *WidgetTree, parent: Id, child: Id) !void {
        const parent_node = self.node(parent).?;
        try parent_node.children.append(self.allocator, child);
    }

    /// Return a node's array index. Production trees use the complete map;
    /// directly assembled trees fall back to their original linear lookup.
    pub fn nodeIndex(self: *const WidgetTree, id: Id) ?usize {
        if (self.id_index.get(id)) |stored_index| {
            const index: usize = @intCast(stored_index);
            if (index < self.nodes.items.len and self.nodes.items[index].id == id) {
                return index;
            }
        } else if (self.id_index.count() == self.nodes.items.len) {
            return null;
        }

        for (self.nodes.items, 0..) |node_value, index| {
            if (node_value.id == id) return index;
        }
        return null;
    }

    /// Move one node to the end while updating every shifted map entry.
    pub fn moveNodeToEnd(self: *WidgetTree, index: usize) void {
        std.debug.assert(index < self.nodes.items.len);
        const moved = self.nodes.orderedRemove(index);
        self.nodes.appendAssumeCapacity(moved);
        for (self.nodes.items[index..], index..) |node_value, new_index| {
            if (self.id_index.getPtr(node_value.id)) |stored_index| {
                stored_index.* = @intCast(new_index);
            }
        }
    }

    /// Append a clip rect, returning its id (the index into clip_rects).
    pub fn pushClipRect(self: *WidgetTree, r: ClipRect) ?u32 {
        if (self.clip_count >= self.clip_rects.len) return null;
        const id = self.clip_count;
        self.clip_rects[id] = r;
        self.clip_count += 1;
        return id;
    }

    /// Lookup by id. Indexed frame trees resolve in O(1); directly assembled
    /// trees retain linear lookup semantics. Unknown IDs return null.
    pub fn node(self: *WidgetTree, id: Id) ?*WidgetNode {
        const index = self.nodeIndex(id) orelse return null;
        return &self.nodes.items[index];
    }

    /// Const-safe lookup with the same indexed and fallback behavior as `node`.
    pub fn nodeConst(self: *const WidgetTree, id: Id) ?*const WidgetNode {
        const index = self.nodeIndex(id) orelse return null;
        return &self.nodes.items[index];
    }

    /// All nodes whose parent == .root (top-level).
    /// Fills `buf` (caller provides, cap 64) up to `buf.len` entries and
    /// returns the total count — truncation-safe: a too-small `buf` never
    /// overflows, the caller just gets the count that would have been written.
    pub fn roots(self: *WidgetTree, buf: []*WidgetNode) usize {
        var count: usize = 0;
        for (self.nodes.items) |*n| {
            if (n.parent != .root) continue;
            if (count < buf.len) buf[count] = n;
            count += 1;
        }
        return count;
    }
};

fn resolveGeometryEdge(
    typed: LengthPercentage,
    legacy: f32,
    border_box_width: f32,
) f32 {
    return switch (typed) {
        .length => |value| if (value == 0 and legacy != 0) legacy else value,
        .percent => |fraction| border_box_width * fraction,
    };
}

fn geometryBoxEdges(node: *const WidgetNode, border_box_width: f32) ResolvedBoxEdges {
    if (node.resolved_box_edges) |edges| return edges;
    return .{
        .border = .{
            .top = resolveGeometryEdge(
                node.style.border_inset.top,
                node.style.border.top,
                border_box_width,
            ),
            .right = resolveGeometryEdge(
                node.style.border_inset.right,
                node.style.border.right,
                border_box_width,
            ),
            .bottom = resolveGeometryEdge(
                node.style.border_inset.bottom,
                node.style.border.bottom,
                border_box_width,
            ),
            .left = resolveGeometryEdge(
                node.style.border_inset.left,
                node.style.border.left,
                border_box_width,
            ),
        },
        .padding = .{
            .top = resolveGeometryEdge(
                node.style.padding_inset.top,
                node.style.padding.top,
                border_box_width,
            ),
            .right = resolveGeometryEdge(
                node.style.padding_inset.right,
                node.style.padding.right,
                border_box_width,
            ),
            .bottom = resolveGeometryEdge(
                node.style.padding_inset.bottom,
                node.style.padding.bottom,
                border_box_width,
            ),
            .left = resolveGeometryEdge(
                node.style.padding_inset.left,
                node.style.padding.left,
                border_box_width,
            ),
        },
    };
}

fn contentBoxRect(border_rect: Rect, node: *const WidgetNode) Rect {
    const edges = geometryBoxEdges(node, border_rect.w);
    return .{
        .x = border_rect.x + edges.border.left + edges.padding.left,
        .y = border_rect.y + edges.border.top + edges.padding.top,
        .w = @max(
            0,
            border_rect.w -
                edges.border.left -
                edges.border.right -
                edges.padding.left -
                edges.padding.right,
        ),
        .h = @max(
            0,
            border_rect.h -
                edges.border.top -
                edges.border.bottom -
                edges.padding.top -
                edges.padding.bottom,
        ),
    };
}

/// Resolve a node's absolute border-box origin by walking parents: each
/// ancestor contributes its own (relative) offset plus the step into its
/// CONTENT box (border + padding). The surface origin is (0,0).
pub fn absoluteBorderOrigin(tree: *const WidgetTree, id: Id) [2]f32 {
    var ox: f32 = 0;
    var oy: f32 = 0;
    var cur = id;
    while (cur != .root) {
        const n = tree.nodeConst(cur) orelse break;
        ox += n.rect.x;
        oy += n.rect.y;
        const parent = tree.nodeConst(n.parent) orelse break;
        const edges = geometryBoxEdges(parent, parent.rect.w);
        ox += edges.border.left + edges.padding.left;
        oy += edges.border.top + edges.padding.top;
        cur = n.parent;
    }
    return .{ ox, oy };
}

/// Absolute border box of a node (origin + its own w/h).
pub fn absoluteRect(tree: *const WidgetTree, id: Id) Rect {
    const origin = absoluteBorderOrigin(tree, id);
    const n = tree.nodeConst(id) orelse return .{ .x = origin[0], .y = origin[1] };
    return .{ .x = origin[0], .y = origin[1], .w = n.rect.w, .h = n.rect.h };
}

/// Resolve a node's visual border-box origin, accounting for ancestor scroll.
/// The target node's own scroll offset does not move its border box.
pub fn visualBorderOrigin(tree: *const WidgetTree, id: Id) [2]f32 {
    var ox: f32 = 0;
    var oy: f32 = 0;
    var cur = id;
    while (cur != .root) {
        const n = tree.nodeConst(cur) orelse break;
        ox += n.rect.x;
        oy += n.rect.y;
        const parent = tree.nodeConst(n.parent) orelse break;
        const edges = geometryBoxEdges(parent, parent.rect.w);
        ox += edges.border.left + edges.padding.left;
        oy += edges.border.top + edges.padding.top;
        if (parent.scroll) |scroll| {
            ox -= scroll.state.offset[0];
            oy -= scroll.state.offset[1];
        }
        cur = n.parent;
    }
    return .{ ox, oy };
}

/// Visual border box of a node, after ancestor scroll offsets are applied.
pub fn visualBorderRect(tree: *const WidgetTree, id: Id) Rect {
    const origin = visualBorderOrigin(tree, id);
    const n = tree.nodeConst(id) orelse return .{ .x = origin[0], .y = origin[1] };
    return .{ .x = origin[0], .y = origin[1], .w = n.rect.w, .h = n.rect.h };
}

/// Visual content box of a node, after ancestor scroll offsets are applied.
pub fn visualContentRect(tree: *const WidgetTree, id: Id) Rect {
    const border_rect = visualBorderRect(tree, id);
    const node = tree.nodeConst(id) orelse return border_rect;
    return contentBoxRect(border_rect, node);
}

/// Return whether a point is inside every clipped ancestor of a node.
pub fn pointInClipChain(tree: *const WidgetTree, id: Id, pos: [2]f32) bool {
    var cur = id;
    while (cur != .root) {
        const n = tree.nodeConst(cur) orelse break;
        if (n.paint.clip and !rectContainsPoint(visualBorderRect(tree, cur), pos)) return false;
        cur = n.parent;
    }
    return true;
}

fn rectContainsPoint(rect: Rect, pos: [2]f32) bool {
    return pos[0] >= rect.x and pos[0] < rect.x + rect.w and
        pos[1] >= rect.y and pos[1] < rect.y + rect.h;
}

/// Absolute CONTENT box of a node: the absolute border box inset by the
/// node's own border + padding. Where children live and text draws.
pub fn contentRect(tree: *const WidgetTree, id: Id) Rect {
    const border_rect = absoluteRect(tree, id);
    const node = tree.nodeConst(id).?;
    return contentBoxRect(border_rect, node);
}

test "WidgetTree: indexed lookup finds live ids and rejects absent ids" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    try tree.appendNode(.{
        .id = id1,
        .kind = .{ .label = .{ .text = "a" } },
        .parent = .root,
    });
    try tree.appendNode(.{
        .id = id2,
        .kind = .{ .spacer = .{} },
        .parent = id1,
    });
    try tree.appendChild(id1, id2);

    try std.testing.expectEqual(id2, tree.node(id2).?.id);
    try std.testing.expectEqual(id1, tree.nodeConst(id1).?.id);
    try std.testing.expectEqual(@as(?*WidgetNode, null), tree.node(@enumFromInt(99)));
    try std.testing.expectEqual(@as(usize, 1), tree.node(id1).?.children.items.len);
    try std.testing.expectEqual(id2, tree.node(id1).?.children.items[0]);
}

test "WidgetTree: moving a node to the end reindexes shifted nodes" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    const id3: Id = @enumFromInt(3);
    for ([_]Id{ id1, id2, id3 }) |id| {
        try tree.appendNode(.{
            .id = id,
            .kind = .{ .spacer = .{} },
            .parent = .root,
        });
    }

    tree.moveNodeToEnd(0);

    try std.testing.expectEqual(id2, tree.nodes.items[0].id);
    try std.testing.expectEqual(id3, tree.nodes.items[1].id);
    try std.testing.expectEqual(id1, tree.nodes.items[2].id);
    try std.testing.expectEqual(id1, tree.node(id1).?.id);
    try std.testing.expectEqual(id2, tree.node(id2).?.id);
    try std.testing.expectEqual(id3, tree.nodeConst(id3).?.id);
}

test "WidgetTree: roots() returns only top-level nodes in append order" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    const id3: Id = @enumFromInt(3);
    const id4: Id = @enumFromInt(4);
    const id5: Id = @enumFromInt(5);

    // Post-order: children first, then their containers.
    try tree.nodes.append(std.testing.allocator, .{ .id = id4, .kind = .{ .label = .{ .text = "c" } }, .parent = id1 });
    try tree.nodes.append(std.testing.allocator, .{ .id = id5, .kind = .{ .label = .{ .text = "d" } }, .parent = id2 });
    try tree.nodes.append(std.testing.allocator, .{ .id = id1, .kind = .{ .column = .{} }, .parent = .root });
    try tree.nodes.append(std.testing.allocator, .{ .id = id2, .kind = .{ .row = .{} }, .parent = .root });
    try tree.nodes.append(std.testing.allocator, .{ .id = id3, .kind = .{ .spacer = .{} }, .parent = .root });
    try tree.appendChild(id1, id4);
    try tree.appendChild(id2, id5);

    var buf: [8]*WidgetNode = undefined;
    const count = tree.roots(&buf);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(id1, buf[0].id);
    try std.testing.expectEqual(id2, buf[1].id);
    try std.testing.expectEqual(id3, buf[2].id);
}

test "WidgetTree: roots() with a too-small buf returns the full count, no overflow" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    for (0..5) |i| {
        try tree.nodes.append(std.testing.allocator, .{
            .id = @enumFromInt(@as(u32, @intCast(i + 1))),
            .kind = .{ .spacer = .{} },
            .parent = .root,
        });
    }

    var small: [2]*WidgetNode = undefined;
    const count = tree.roots(&small);
    // Count reflects everything that would have been written.
    try std.testing.expectEqual(@as(usize, 5), count);
    // The first entries still land, in append order.
    try std.testing.expectEqual(@as(Id, @enumFromInt(1)), small[0].id);
    try std.testing.expectEqual(@as(Id, @enumFromInt(2)), small[1].id);
    // Writing past buf.len would trip the slice bounds check under `zig test`.
}

test "absoluteRect: walks parent content boxes through border+padding" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    // root-level column with padding, holding a row with a border, holding
    // a label offset relative to the row's content box.
    const col: Id = @enumFromInt(1);
    const row: Id = @enumFromInt(2);
    const label: Id = @enumFromInt(3);

    try tree.nodes.append(std.testing.allocator, .{
        .id = label,
        .kind = .{ .label = .{ .text = "x" } },
        .parent = row,
        .rect = .{ .x = 5, .y = 3, .w = 20, .h = 24 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = row,
        .kind = .{ .row = .{} },
        .parent = col,
        .rect = .{ .x = 10, .y = 10, .w = 100, .h = 40 },
        .style = .{ .border = .{ .top = 1, .right = 2, .bottom = 3, .left = 4 } },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = col,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 200, .h = 200 },
        .style = .{ .padding = .{ .top = 8, .left = 8 } },
    });
    try tree.appendChild(row, label);
    try tree.appendChild(col, row);

    // Label absolute border box: col content origin (8,8) + row rect
    // (10,10) + row border (4,1) + label rect (5,3).
    const r = absoluteRect(&tree, label);
    try std.testing.expectEqual(Rect{ .x = 8 + 10 + 4 + 5, .y = 8 + 10 + 1 + 3, .w = 20, .h = 24 }, r);

    // Label content box: its own border+padding are zero, so identical.
    const c = contentRect(&tree, label);
    try std.testing.expectEqual(r, c);

    // Row content box: absolute border box (18,18,100,40) inset by its
    // border (4,1,2,3).
    const rc = contentRect(&tree, row);
    try std.testing.expectEqual(Rect{ .x = 18 + 4, .y = 18 + 1, .w = 100 - 6, .h = 40 - 4 }, rc);
}

test "absoluteRect: typed zero edges override inherited legacy content origin" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const parent_id: Id = @enumFromInt(2);
    const inherited_style = Style.resolve(.{}, .{
        .border = .{ .top = 2, .left = 13 },
        .padding = .{ .top = 3, .left = 17 },
    });
    const resolved_parent_style = Style.resolve(inherited_style, .{
        .border_inset = .{
            .top = .{ .length = 2 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
        .padding_inset = .{
            .top = .{ .length = 3 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
    });

    try tree.nodes.append(std.testing.allocator, .{
        .id = child_id,
        .kind = .{ .label = .{ .text = "child" } },
        .parent = parent_id,
        .rect = .{ .x = 4, .y = 6, .w = 20, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = parent_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 10, .y = 20, .w = 100, .h = 80 },
        .style = resolved_parent_style,
    });
    try tree.appendChild(parent_id, child_id);

    // The typed left border and padding are explicitly zero. The inherited
    // legacy mirrors still contain 13 and 17 and must not shift the child.
    try std.testing.expectEqual(
        Rect{ .x = 14, .y = 31, .w = 20, .h = 10 },
        absoluteRect(&tree, child_id),
    );
}

test "geometry: typed percentage parent edges define child absolute and visual origin" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const parent_id: Id = @enumFromInt(2);
    const parent_style: Style = .{
        .display = .block,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 40 },
        },
        .border_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 5 },
        },
        .padding_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .percent = 0.25 },
        },
    };

    try tree.nodes.append(std.testing.allocator, .{
        .id = child_id,
        .kind = .{ .label = .{ .text = "child" } },
        .parent = parent_id,
        .rect = .{ .x = 0, .y = 0, .w = 20, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = parent_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 40 },
        .style = parent_style,
    });
    try tree.appendChild(parent_id, child_id);

    const content_origin_x: f32 = 5 + 100 * 0.25;
    const expected: Rect = .{ .x = content_origin_x, .y = 0, .w = 20, .h = 10 };
    try std.testing.expectEqual(@as(f32, 0), tree.nodeConst(child_id).?.rect.x);
    try std.testing.expectEqual(expected, absoluteRect(&tree, child_id));
    try std.testing.expectEqual(expected, visualContentRect(&tree, child_id));
}

test "geometry: stored resolved percentage edges retain containing basis" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const parent_id: Id = @enumFromInt(2);
    const containing_width: f32 = 200;
    const parent_width: f32 = 100;
    const padding_fraction: f32 = 0.10;
    const resolved_padding_left = containing_width * padding_fraction;

    try tree.nodes.append(std.testing.allocator, .{
        .id = child_id,
        .kind = .{ .label = .{ .text = "child" } },
        .parent = parent_id,
        .rect = .{ .w = 20, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = parent_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .w = parent_width, .h = 40 },
        .style = .{
            .display = .block,
            .padding_inset = .{
                .top = .{ .length = 0 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .percent = padding_fraction },
            },
        },
        .resolved_box_edges = .{
            .border = .{},
            .padding = .{ .left = resolved_padding_left },
        },
    });
    try tree.appendChild(parent_id, child_id);

    // Recomputing 10% from the 100px border box would incorrectly yield 10px.
    const expected_origin = [2]f32{ 20, 0 };
    try std.testing.expectEqual(expected_origin, absoluteBorderOrigin(&tree, child_id));
    try std.testing.expectEqual(expected_origin, visualBorderOrigin(&tree, child_id));
}

test "absoluteRect: root-level node is relative to the surface (0,0)" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const col: Id = @enumFromInt(1);
    try tree.nodes.append(std.testing.allocator, .{
        .id = col,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
    });

    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, absoluteRect(&tree, col));
}

test "WidgetNode: defaults are zero-valued" {
    const n: WidgetNode = .{
        .id = .root,
        .kind = .{ .label = .{ .text = "x" } },
        .parent = .root,
    };

    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, n.rect);
    try std.testing.expectEqual(Style{}, n.style);
    try std.testing.expectEqual(PaintStyle{}, n.paint);
    try std.testing.expectEqual(@as(usize, 0), n.children.items.len);
}
test "WidgetNode: typed dimensions and constraints are stored after resolution" {
    var node: WidgetNode = .{
        .id = .root,
        .kind = .{ .label = .{ .text = "typed" } },
        .parent = .root,
        .style = .{
            .size = .{ .width = .{ .percent = 0.5 }, .height = .auto },
            .min_size = .{ .width = .{ .length = 40 }, .height = .auto },
            .inset = .{
                .top = .auto,
                .right = .{ .length = 8 },
                .bottom = .auto,
                .left = .auto,
            },
        },
    };
    node.resolveTypedStyle(.{ .width = 200, .height = 100 }, .{ .width = 30, .height = 20 });
    try std.testing.expectEqual(@as(?f32, 100), node.resolved_dimensions.width);
    try std.testing.expectEqual(@as(?f32, 40), node.resolved_constraints.min_width);
    try std.testing.expectEqual(@as(?f32, 8), node.resolved_insets.right);
}

test "sliderVisualLabel: null falls back, empty suppresses visible text" {
    var value: f32 = 0.5;
    const fallback: WidgetKind = .{ .slider = .{
        .label = "volume",
        .value = &value,
        .min = 0,
        .max = 1,
    } };
    const override: WidgetKind = .{ .slider = .{
        .label = "semantic",
        .visual_label = "shown",
        .value = &value,
        .min = 0,
        .max = 1,
    } };
    const hidden: WidgetKind = .{ .slider = .{
        .label = "semantic",
        .visual_label = "",
        .value = &value,
        .min = 0,
        .max = 1,
    } };

    try std.testing.expectEqualStrings("volume", sliderVisualLabel(fallback));
    try std.testing.expectEqualStrings("shown", sliderVisualLabel(override));
    try std.testing.expectEqualStrings("", sliderVisualLabel(hidden));
}

test "visualBorderRect: scroll offset applies only to descendants" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const scroll_id: Id = @enumFromInt(1);
    const child_id: Id = @enumFromInt(2);
    var scroll_state: ScrollState = .{ .offset = .{ 4, 6 } };

    try tree.nodes.append(std.testing.allocator, .{
        .id = child_id,
        .kind = .{ .label = .{ .text = "child" } },
        .parent = scroll_id,
        .rect = .{ .x = 5, .y = 7, .w = 20, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = scroll_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 10, .y = 20, .w = 100, .h = 80 },
        .style = .{
            .border = .{ .top = 3, .left = 2 },
            .padding = .{ .top = 2, .left = 1 },
        },
        .scroll = .{ .state = &scroll_state },
    });
    try tree.appendChild(scroll_id, child_id);

    try std.testing.expectEqual(
        Rect{ .x = 10, .y = 20, .w = 100, .h = 80 },
        visualBorderRect(&tree, scroll_id),
    );
    try std.testing.expectEqual(
        Rect{ .x = 14, .y = 26, .w = 20, .h = 10 },
        visualBorderRect(&tree, child_id),
    );
}

test "pointInClipChain: rejects points outside a scrolled ancestor clip" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const clip_id: Id = @enumFromInt(1);
    const child_id: Id = @enumFromInt(2);
    var scroll_state: ScrollState = .{ .offset = .{ 5, 0 } };

    try tree.nodes.append(std.testing.allocator, .{
        .id = child_id,
        .kind = .{ .label = .{ .text = "child" } },
        .parent = clip_id,
        .rect = .{ .x = 25, .y = 5, .w = 20, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = clip_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 10, .y = 20, .w = 30, .h = 30 },
        .paint = .{ .clip = true },
        .scroll = .{ .state = &scroll_state },
    });
    try tree.appendChild(clip_id, child_id);

    try std.testing.expect(pointInClipChain(&tree, child_id, .{ 35, 27 }));
    try std.testing.expect(!pointInClipChain(&tree, child_id, .{ 45, 27 }));
}
