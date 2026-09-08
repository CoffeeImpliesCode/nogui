//! v7 widget types — geometry, per-child flex data, kind union, and the
//! per-frame widget tree.
//! Per the prototype spec (notes/v7-prototype-spec.md §2).
const std = @import("std");
const perf_counters = @import("perf_counters.zig");
const v7_options = @import("v7_options");
const CounterSink = perf_counters.CounterSink;

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

/// Content-clip axes. PaintStyle.clip enables both axes; typed overflow can
/// enable either axis independently.
pub const ClipAxes = struct {
    x: bool = false,
    y: bool = false,

    pub fn any(self: ClipAxes) bool {
        return self.x or self.y;
    }
};

/// A clip rectangle in layout (framebuffer px) space. The GPU clip buffer
/// stores these verbatim (four f32, 16 bytes). An extent of
/// `disabled_extent` disables clipping on that axis without changing the GPU
/// ABI; all real clip extents are nonnegative.
/// 0xFFFFFFFF (no clip id) disables both axes by bypassing the clip lookup.
pub const ClipRect = extern struct {
    pub const disabled_extent: f32 = -1;

    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn fromRect(rect: Rect, axes: ClipAxes) ClipRect {
        std.debug.assert(axes.any());
        return .{
            .x = if (axes.x) rect.x else 0,
            .y = if (axes.y) rect.y else 0,
            .w = if (axes.x) @max(0, rect.w) else disabled_extent,
            .h = if (axes.y) @max(0, rect.h) else disabled_extent,
        };
    }

    pub fn clipsX(self: ClipRect) bool {
        return self.w != disabled_extent;
    }

    pub fn clipsY(self: ClipRect) bool {
        return self.h != disabled_extent;
    }
};

/// Horizontal+vertical sums of a Sides (for content-box derivation).
pub fn sidesSum(s: Sides) struct { w: f32, h: f32 } {
    return .{ .w = s.left + s.right, .h = s.top + s.bottom };
}

/// Sizing parameters for one shared column track.
pub const ColumnTrack = struct {
    grow: f32 = 0,
    shrink: f32 = 1,
    flex_basis: Dimension = .auto,
    min_width: Dimension = .auto,
};

/// Column tracks shared by row children.
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
    column: struct {},
    row: struct {},
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
    /// Propagated content extent produced by the current layout pass.
    layout_content_size: Size = .{ .width = 0, .height = 0 },
    /// First baseline from the border-box top after final child placement.
    /// Null means the node has no natural baseline.
    first_baseline: ?f32 = null,
    /// Cached physical border and padding edges from layout resolution.
    /// This preserves the containing basis for percentage edges during later
    /// absolute and visual geometry walks.
    resolved_box_edges: ?ResolvedBoxEdges = null,
    /// True when the current block layout pass hides this node through itself
    /// or an ancestor. Recomputed at every direct block layout entry.
    layout_hidden: bool = false,
    /// Canonical typed layout values.
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
    /// Ancestor clip applied to this node's own decorations. The node's
    /// content clip must not crop its border, shadow, slider chrome, or
    /// interaction rings.
    paint_clip_id: u32 = 0xFFFFFFFF,
    /// Clip applied to this node's content, including text and icons.
    /// 0xFFFFFFFF means no clip.
    clip_id: u32 = 0xFFFFFFFF,

    /// Return the independent axes on which this node clips content and
    /// descendants.
    pub fn contentClipAxes(self: *const WidgetNode) ClipAxes {
        return .{
            .x = self.paint.clip or self.style.overflow.width != .visible,
            .y = self.paint.clip or self.style.overflow.height != .visible,
        };
    }

    pub fn clipsContent(self: *const WidgetNode) bool {
        return self.contentClipAxes().any();
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
    const dense_absent: u32 = std.math.maxInt(u32);

    nodes: std.ArrayListUnmanaged(WidgetNode) = .empty,
    allocator: std.mem.Allocator,
    next_id: u32 = 1,
    /// Frame-local index maintained by `appendNode` for production trees.
    /// Directly assembled trees can leave it incomplete; lookup then scans.
    id_index: std.AutoHashMapUnmanaged(Id, u32) = .empty,
    /// Optional bounded ID-to-node-index view prepared at the tree-complete
    /// boundary. `dense_absent` marks an ID that is not present.
    dense_id_index: ?[]u32 = null,
    /// Per-frame clip-rect list (cap 64 = the GPU clip buffer's size). Clip
    /// ids are indices into this list; 0xFFFFFFFF = no clip. The core
    /// appends here (DrawCtx.pushClip + drawcmd's clip-stack walk); the
    /// renderer copies the list into the GPU clip buffer each frame.
    /// Append-only per frame — ids must stay stable for the frame.
    // SAFETY: written only via pushClipRect before any read; clip_count tracks the filled count
    clip_rects: [64]ClipRect = undefined,
    clip_count: u32 = 0,
    counter_sink: CounterSink = CounterSink.init(null),

    pub fn init(allocator: std.mem.Allocator) WidgetTree {
        return .{
            .allocator = allocator,
            .counter_sink = CounterSink.init(null),
        };
    }

    pub fn setCounterSink(self: *WidgetTree, counters: ?*perf_counters.Counters) void {
        self.counter_sink = CounterSink.init(counters);
    }

    pub fn addCounter(self: *const WidgetTree, counter: perf_counters.Counter, amount: u64) void {
        self.counter_sink.add(counter, amount);
    }

    fn invalidateDenseIdLookup(self: *WidgetTree) void {
        if (self.dense_id_index) |dense_id_index| {
            self.allocator.free(dense_id_index);
            self.dense_id_index = null;
        }
    }

    pub fn prepareIdLookup(self: *WidgetTree) error{OutOfMemory}!void {
        if (self.nodes.items.len == 0) {
            self.invalidateDenseIdLookup();
            return;
        }
        if (self.id_index.count() != self.nodes.items.len) {
            self.invalidateDenseIdLookup();
            return;
        }

        var maximum_id: u32 = 0;
        for (self.nodes.items, 0..) |*node_value, node_index| {
            const stored_index = self.id_index.get(node_value.id) orelse {
                self.invalidateDenseIdLookup();
                return;
            };
            const index_u32 = std.math.cast(u32, node_index) orelse {
                self.invalidateDenseIdLookup();
                return;
            };
            if (index_u32 == dense_absent or stored_index != index_u32) {
                self.invalidateDenseIdLookup();
                return;
            }
            maximum_id = @max(maximum_id, @intFromEnum(node_value.id));
        }

        if (maximum_id == std.math.maxInt(u32)) {
            self.invalidateDenseIdLookup();
            return;
        }
        const dense_len_u64: u64 = @as(u64, maximum_id) + 1;
        // Compare against ceil(dense_len / 2) so neither side can overflow.
        const minimum_node_count: u64 = (dense_len_u64 + 1) / 2;
        const node_count_u64 = std.math.cast(u64, self.nodes.items.len) orelse {
            self.invalidateDenseIdLookup();
            return;
        };
        if (node_count_u64 < minimum_node_count) {
            self.invalidateDenseIdLookup();
            return;
        }
        const dense_len = std.math.cast(usize, dense_len_u64) orelse {
            self.invalidateDenseIdLookup();
            return;
        };

        const candidate = try self.allocator.alloc(u32, dense_len);
        errdefer self.allocator.free(candidate);
        @memset(candidate, dense_absent);
        for (self.nodes.items, 0..) |*node_value, node_index| {
            const index_u32 = std.math.cast(u32, node_index) orelse unreachable;
            candidate[@intFromEnum(node_value.id)] = index_u32;
        }

        // Keep the previous view published until the candidate is complete.
        const previous = self.dense_id_index;
        self.dense_id_index = candidate;
        if (previous) |dense_id_index| self.allocator.free(dense_id_index);
    }

    pub fn deinit(self: *WidgetTree) void {
        self.invalidateDenseIdLookup();
        for (self.nodes.items) |*node_value| {
            node_value.children.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.id_index.deinit(self.allocator);
        self.* = undefined;
    }

    /// Append a node and atomically add its frame-local lookup entry.
    pub fn appendNode(self: *WidgetTree, node_value: WidgetNode) !void {
        self.invalidateDenseIdLookup();
        try self.nodes.append(self.allocator, node_value);
        errdefer _ = self.nodes.pop();
        try self.id_index.put(
            self.allocator,
            node_value.id,
            @intCast(self.nodes.items.len - 1),
        );
    }

    /// Append a child id through the tree-owned frame allocator.
    /// Missing parent IDs are malformed tree input and return
    /// `error.InvalidStyle`.
    pub fn appendChild(self: *WidgetTree, parent: Id, child: Id) !void {
        const parent_node = self.node(parent) orelse return error.InvalidStyle;
        try parent_node.children.append(self.allocator, child);
    }

    /// Return a node's array index. Production trees use the complete map;
    /// directly assembled trees fall back to their original linear lookup.
    pub fn nodeIndex(self: *const WidgetTree, id: Id) ?usize {
        if (self.dense_id_index) |dense_id_index| {
            const id_value = @intFromEnum(id);
            if (id_value < dense_id_index.len) {
                const stored_index = dense_id_index[id_value];
                if (stored_index != dense_absent) {
                    const index: usize = @intCast(stored_index);
                    if (index < self.nodes.items.len) {
                        self.counter_sink.add(.node_comparisons, 1);
                        if (self.nodes.items[index].id == id) return index;
                    }
                }
            }
        }
        if (self.id_index.get(id)) |stored_index| {
            const index: usize = @intCast(stored_index);
            if (index < self.nodes.items.len) {
                self.counter_sink.add(.node_comparisons, 1);
                if (self.nodes.items[index].id == id) return index;
            }
        } else if (self.id_index.count() == self.nodes.items.len) {
            return null;
        }

        for (self.nodes.items, 0..) |node_value, index| {
            self.counter_sink.add(.node_comparisons, 1);
            if (node_value.id == id) return index;
        }
        return null;
    }

    /// Move one node to the end while updating every shifted map entry.
    pub fn moveNodeToEnd(self: *WidgetTree, index: usize) void {
        std.debug.assert(index < self.nodes.items.len);
        self.invalidateDenseIdLookup();
        const moved = self.nodes.orderedRemove(index);
        self.nodes.appendAssumeCapacity(moved);
        for (self.nodes.items[index..], index..) |node_value, new_index| {
            if (self.id_index.getPtr(node_value.id)) |stored_index| {
                stored_index.* = @intCast(new_index);
            }
        }
    }

    /// Append a clip rect and return its stable frame-local id.
    pub fn pushClipRect(self: *WidgetTree, rect: ClipRect) error{ClipCapacityExceeded}!u32 {
        if (self.clip_count >= self.clip_rects.len) return error.ClipCapacityExceeded;
        const id = self.clip_count;
        self.clip_rects[id] = rect;
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

fn resolveGeometryEdge(typed: LengthPercentage, border_box_width: f32) f32 {
    return switch (typed) {
        .length => |value| value,
        .percent => |fraction| border_box_width * fraction,
    };
}

/// Resolve physical border and padding edges for geometry walks.
///
/// Layout stores resolved edges when percentage values use a containing basis
/// that differs from the node's own border-box width. Before layout, typed
/// lengths and percentages provide the canonical fallback.
pub fn geometryBoxEdges(node: *const WidgetNode, border_box_width: f32) ResolvedBoxEdges {
    if (node.resolved_box_edges) |edges| return edges;
    return .{
        .border = .{
            .top = resolveGeometryEdge(node.style.border_inset.top, border_box_width),
            .right = resolveGeometryEdge(node.style.border_inset.right, border_box_width),
            .bottom = resolveGeometryEdge(node.style.border_inset.bottom, border_box_width),
            .left = resolveGeometryEdge(node.style.border_inset.left, border_box_width),
        },
        .padding = .{
            .top = resolveGeometryEdge(node.style.padding_inset.top, border_box_width),
            .right = resolveGeometryEdge(node.style.padding_inset.right, border_box_width),
            .bottom = resolveGeometryEdge(node.style.padding_inset.bottom, border_box_width),
            .left = resolveGeometryEdge(node.style.padding_inset.left, border_box_width),
        },
    };
}

/// Inset a border box by the node's resolved border and padding edges.
pub fn contentBoxRect(border_rect: Rect, node: *const WidgetNode) Rect {
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

const BorderOrigin = struct {
    origin: [2]f32,
    node: ?*const WidgetNode,
};

fn resolveBorderOrigin(
    comptime visual: bool,
    tree: *const WidgetTree,
    id: Id,
) BorderOrigin {
    var ox: f32 = 0;
    var oy: f32 = 0;
    if (id == .root) {
        return .{ .origin = .{ ox, oy }, .node = tree.nodeConst(.root) };
    }

    tree.counter_sink.add(.ancestor_reads, 1);
    var current = tree.nodeConst(id) orelse {
        return .{ .origin = .{ ox, oy }, .node = null };
    };
    const target = current;
    while (true) {
        ox += current.rect.x;
        oy += current.rect.y;

        const parent_id = current.parent;
        const parent = tree.nodeConst(parent_id) orelse break;
        const edges = geometryBoxEdges(parent, parent.rect.w);
        ox += edges.border.left + edges.padding.left;
        oy += edges.border.top + edges.padding.top;
        if (visual) {
            if (parent.scroll) |scroll| {
                ox -= scroll.state.offset[0];
                oy -= scroll.state.offset[1];
            }
        }
        if (parent_id == .root) break;
        current = parent;
        tree.counter_sink.add(.ancestor_reads, 1);
    }
    return .{ .origin = .{ ox, oy }, .node = target };
}

/// Resolve a node's absolute border-box origin by walking parents: each
/// ancestor contributes its own (relative) offset plus the step into its
/// CONTENT box (border + padding). The surface origin is (0,0).
pub fn absoluteBorderOrigin(tree: *const WidgetTree, id: Id) [2]f32 {
    return resolveBorderOrigin(false, tree, id).origin;
}

/// Absolute border box of a node (origin + its own w/h).
pub fn absoluteRect(tree: *const WidgetTree, id: Id) Rect {
    const resolved = resolveBorderOrigin(false, tree, id);
    const origin = resolved.origin;
    const node = resolved.node orelse return .{ .x = origin[0], .y = origin[1] };
    return .{ .x = origin[0], .y = origin[1], .w = node.rect.w, .h = node.rect.h };
}

/// Resolve a node's visual border-box origin, accounting for ancestor scroll.
/// The target node's own scroll offset does not move its border box.
pub fn visualBorderOrigin(tree: *const WidgetTree, id: Id) [2]f32 {
    return resolveBorderOrigin(true, tree, id).origin;
}

/// Visual border box of a node, after ancestor scroll offsets are applied.
pub fn visualBorderRect(tree: *const WidgetTree, id: Id) Rect {
    const resolved = resolveBorderOrigin(true, tree, id);
    const origin = resolved.origin;
    const node = resolved.node orelse return .{ .x = origin[0], .y = origin[1] };
    return .{ .x = origin[0], .y = origin[1], .w = node.rect.w, .h = node.rect.h };
}

/// Visual content box of a node, after ancestor scroll offsets are applied.
pub fn visualContentRect(tree: *const WidgetTree, id: Id) Rect {
    const resolved = resolveBorderOrigin(true, tree, id);
    const origin = resolved.origin;
    const node = resolved.node orelse return .{ .x = origin[0], .y = origin[1] };
    const border_rect: Rect = .{
        .x = origin[0],
        .y = origin[1],
        .w = node.rect.w,
        .h = node.rect.h,
    };
    return contentBoxRect(border_rect, node);
}

/// Return whether a point is inside every clipped axis of a rectangle.
pub fn pointInClipAxes(rect: Rect, axes: ClipAxes, pos: [2]f32) bool {
    if (axes.x and (pos[0] < rect.x or pos[0] >= rect.x + rect.w)) return false;
    if (axes.y and (pos[1] < rect.y or pos[1] >= rect.y + rect.h)) return false;
    return true;
}

/// Return whether a point is inside every clipped ancestor axis of a node.
pub fn pointInClipChain(tree: *const WidgetTree, id: Id, pos: [2]f32) bool {
    var cur = id;
    while (cur != .root) {
        tree.counter_sink.add(.ancestor_reads, 1);
        const node = tree.nodeConst(cur) orelse break;
        if (!pointInClipAxes(
            visualBorderRect(tree, cur),
            node.contentClipAxes(),
            pos,
        )) return false;
        cur = node.parent;
    }
    return true;
}

/// Absolute CONTENT box of a node: the absolute border box inset by the
/// node's own border + padding. Where children live and text draws.
/// Missing IDs are malformed tree input and return `error.InvalidStyle`.
pub fn contentRect(tree: *const WidgetTree, id: Id) error{InvalidStyle}!Rect {
    const node = tree.nodeConst(id) orelse return error.InvalidStyle;
    const border_rect = absoluteRect(tree, id);
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

// A prepared lookup must use stored post-order indices instead of deriving
// positions from sequential IDs, and stale stored indices must still scan.
test "WidgetTree: prepared lookup follows current post-order nodes" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const parent_id: Id = @enumFromInt(1);
    const child_id: Id = @enumFromInt(3);
    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .label = .{ .text = "child" } },
        .parent = parent_id,
    });
    try tree.appendNode(.{
        .id = parent_id,
        .kind = .{ .column = .{} },
        .parent = .root,
    });
    try tree.prepareIdLookup();

    try std.testing.expectEqual(@as(?usize, 0), tree.nodeIndex(child_id));
    try std.testing.expectEqual(@as(?usize, 1), tree.nodeIndex(parent_id));
    try std.testing.expectEqual(@as(?usize, null), tree.nodeIndex(@enumFromInt(2)));

    std.mem.swap(WidgetNode, &tree.nodes.items[0], &tree.nodes.items[1]);
    try std.testing.expectEqual(@as(?usize, 1), tree.nodeIndex(child_id));
    try std.testing.expectEqual(@as(?usize, 0), tree.nodeIndex(parent_id));

    try tree.prepareIdLookup();
    try std.testing.expectEqual(@as(?usize, 1), tree.nodeIndex(child_id));
    try std.testing.expectEqual(@as(?usize, 0), tree.nodeIndex(parent_id));
}

// A full-cardinality map can still be malformed. Preparation must not replace
// its established missing-key behavior with a dense node scan.
test "WidgetTree: malformed complete map remains lookup authority" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    const unrelated_id: Id = @enumFromInt(3);
    for ([_]Id{ id1, id2 }) |id| {
        try tree.appendNode(.{
            .id = id,
            .kind = .{ .spacer = .{} },
            .parent = .root,
        });
    }
    try tree.prepareIdLookup();

    try std.testing.expect(tree.id_index.remove(id2));
    try tree.id_index.put(tree.allocator, unrelated_id, 1);
    try tree.prepareIdLookup();

    try std.testing.expectEqual(@as(?usize, 0), tree.nodeIndex(id1));
    try std.testing.expectEqual(@as(?usize, null), tree.nodeIndex(id2));
}

// The maximum representable ID must avoid max-plus-one overflow and retain the
// existing sparse-map lookup path.
test "WidgetTree: maximum ID remains on sparse fallback" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const maximum_id: Id = @enumFromInt(std.math.maxInt(u32));
    try tree.appendNode(.{
        .id = maximum_id,
        .kind = .{ .spacer = .{} },
        .parent = .root,
    });
    try tree.prepareIdLookup();

    try std.testing.expectEqual(@as(?usize, 0), tree.nodeIndex(maximum_id));
    try std.testing.expectEqual(@as(?usize, null), tree.nodeIndex(.root));
}

// A failed replacement must leave the old validated lookup safe, and the tree
// must accept a later preparation attempt.
test "WidgetTree: prepare allocation failure keeps lookup retryable" {
    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{},
    );
    const allocator = failing_allocator.allocator();
    var tree = WidgetTree.init(allocator);
    defer tree.deinit();

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    const id3: Id = @enumFromInt(3);
    for ([_]Id{ id1, id2 }) |id| {
        try tree.appendNode(.{
            .id = id,
            .kind = .{ .spacer = .{} },
            .parent = .root,
        });
    }
    try tree.prepareIdLookup();

    tree.nodes.items[1].id = id3;
    try std.testing.expect(tree.id_index.remove(id2));
    try tree.id_index.put(allocator, id3, 1);
    failing_allocator.fail_index = failing_allocator.alloc_index;

    try std.testing.expectError(error.OutOfMemory, tree.prepareIdLookup());
    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(?usize, 1), tree.nodeIndex(id3));
    try std.testing.expectEqual(@as(?usize, null), tree.nodeIndex(id2));

    failing_allocator.fail_index = std.math.maxInt(usize);
    try tree.prepareIdLookup();
    try tree.prepareIdLookup();
    try std.testing.expectEqual(@as(?usize, 1), tree.nodeIndex(id3));
}

test "WidgetTree counters record node lookup and ancestor reads" {
    var counters: perf_counters.Counters = .{};
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    tree.setCounterSink(&counters);
    const root_id: Id = @enumFromInt(1);
    const child_id: Id = @enumFromInt(2);
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 1, .y = 2, .w = 10, .h = 10 },
    });
    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .label = .{ .text = "x" } },
        .parent = root_id,
        .rect = .{ .x = 3, .y = 4, .w = 5, .h = 6 },
    });
    try tree.appendChild(root_id, child_id);

    _ = absoluteBorderOrigin(&tree, child_id);
    const snapshot = try counters.snapshot();
    if (comptime v7_options.perf_counters) {
        try std.testing.expect(snapshot.value(.node_comparisons) > 0);
        try std.testing.expect(snapshot.value(.ancestor_reads) > 0);
    } else {
        try std.testing.expectEqual(@as(u64, 0), snapshot.value(.node_comparisons));
        try std.testing.expectEqual(@as(u64, 0), snapshot.value(.ancestor_reads));
    }
}

test "WidgetTree: malformed IDs return InvalidStyle instead of panicking" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const missing_id: Id = @enumFromInt(99);
    try std.testing.expectError(
        error.InvalidStyle,
        tree.appendChild(missing_id, @enumFromInt(1)),
    );
    try std.testing.expectError(error.InvalidStyle, contentRect(&tree, missing_id));
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
    try tree.prepareIdLookup();

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

    // Root-level column with padding, holding a row with a border, holding
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
        .style = .{
            .border_inset = .{
                .top = .{ .length = 1 },
                .right = .{ .length = 2 },
                .bottom = .{ .length = 3 },
                .left = .{ .length = 4 },
            },
        },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = col,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 200, .h = 200 },
        .style = .{
            .padding_inset = .{
                .top = .{ .length = 8 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 8 },
            },
        },
    });
    try tree.appendChild(row, label);
    try tree.appendChild(col, row);

    // Label absolute border box: col content origin (8,8) + row rect
    // (10,10) + row border (4,1) + label rect (5,3).
    const r = absoluteRect(&tree, label);
    try std.testing.expectEqual(
        Rect{ .x = 8 + 10 + 4 + 5, .y = 8 + 10 + 1 + 3, .w = 20, .h = 24 },
        r,
    );

    // Label content box: its own border+padding are zero, so identical.
    const c = try contentRect(&tree, label);
    try std.testing.expectEqual(r, c);

    // Row content box: absolute border box (18,18,100,40) inset by its
    // border (4,1,2,3).
    const rc = try contentRect(&tree, row);
    try std.testing.expectEqual(
        Rect{ .x = 18 + 4, .y = 18 + 1, .w = 100 - 6, .h = 40 - 4 },
        rc,
    );
}

test "absoluteRect: typed zero edges preserve content origin" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const parent_id: Id = @enumFromInt(2);
    const parent_style: Style = .{
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
    };

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
        .style = parent_style,
    });
    try tree.appendChild(parent_id, child_id);

    // Explicit typed zero edges remain authoritative during geometry fallback.
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

test "geometry preserves nested fractional child-to-root accumulation" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const middle_id: Id = @enumFromInt(2);
    const outer_id: Id = @enumFromInt(3);
    var middle_scroll: ScrollState = .{ .offset = .{ 5.89, 0.4 } };
    var outer_scroll: ScrollState = .{ .offset = .{ 7.28, 0.6 } };

    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .label = .{ .text = "child" } },
        .parent = middle_id,
        .rect = .{ .x = 74.9, .y = 9.7, .w = 13.25, .h = 4.5 },
    });
    try tree.appendNode(.{
        .id = middle_id,
        .kind = .{ .row = .{} },
        .parent = outer_id,
        .rect = .{ .x = 6.8, .y = 4.6, .w = 100, .h = 80 },
        .style = .{
            .border_inset = .{
                .top = .{ .length = 1.2 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 12.3 },
            },
            .padding_inset = .{
                .top = .{ .length = 2.3 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 22.5 },
            },
        },
        .scroll = .{ .state = &middle_scroll, .axis = .both },
    });
    try tree.appendNode(.{
        .id = outer_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 78.7, .y = 7.9, .w = 200, .h = 160 },
        .style = .{
            .border_inset = .{
                .top = .{ .length = 5.7 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 31.4 },
            },
            .padding_inset = .{
                .top = .{ .length = 6.8 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 46.5 },
            },
        },
        .scroll = .{ .state = &outer_scroll, .axis = .both },
    });
    try tree.appendChild(middle_id, child_id);
    try tree.appendChild(outer_id, middle_id);

    const absolute_origin = absoluteBorderOrigin(&tree, child_id);
    const visual_origin = visualBorderOrigin(&tree, child_id);
    try std.testing.expectEqual(
        @as(u32, 0x4388_8CCC),
        @as(u32, @bitCast(absolute_origin[0])),
    );
    try std.testing.expectEqual(
        @as(u32, 0x4218_CCCD),
        @as(u32, @bitCast(absolute_origin[1])),
    );
    try std.testing.expectEqual(
        @as(u32, 0x4381_F70A),
        @as(u32, @bitCast(visual_origin[0])),
    );
    try std.testing.expectEqual(
        @as(u32, 0x4214_CCCD),
        @as(u32, @bitCast(visual_origin[1])),
    );

    const absolute_rect = absoluteRect(&tree, child_id);
    const visual_rect = visualBorderRect(&tree, child_id);
    try std.testing.expectEqual(absolute_origin[0], absolute_rect.x);
    try std.testing.expectEqual(absolute_origin[1], absolute_rect.y);
    try std.testing.expectEqual(visual_origin[0], visual_rect.x);
    try std.testing.expectEqual(visual_origin[1], visual_rect.y);
    try std.testing.expectEqual(@as(f32, 13.25), absolute_rect.w);
    try std.testing.expectEqual(@as(f32, 4.5), absolute_rect.h);
    try std.testing.expectEqual(@as(f32, 13.25), visual_rect.w);
    try std.testing.expectEqual(@as(f32, 4.5), visual_rect.h);
}

test "geometry returns the accumulated prefix when a parent is missing" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const parent_id: Id = @enumFromInt(2);
    const missing_id: Id = @enumFromInt(99);
    var scroll_state: ScrollState = .{ .offset = .{ 2, 3 } };

    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .label = .{ .text = "child" } },
        .parent = parent_id,
        .rect = .{ .x = 1, .y = 2, .w = 7, .h = 8 },
    });
    try tree.appendNode(.{
        .id = parent_id,
        .kind = .{ .column = .{} },
        .parent = missing_id,
        .rect = .{ .x = 10, .y = 20, .w = 50, .h = 40 },
        .style = .{
            .border_inset = .{
                .top = .{ .length = 5 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 3 },
            },
            .padding_inset = .{
                .top = .{ .length = 6 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 4 },
            },
        },
        .scroll = .{ .state = &scroll_state, .axis = .both },
    });
    try tree.appendChild(parent_id, child_id);

    try std.testing.expectEqual(
        Rect{ .x = 18, .y = 33, .w = 7, .h = 8 },
        absoluteRect(&tree, child_id),
    );
    try std.testing.expectEqual(
        Rect{ .x = 16, .y = 30, .w = 7, .h = 8 },
        visualBorderRect(&tree, child_id),
    );
}

test "geometry preserves explicit root sentinel lookup semantics" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    var root_scroll: ScrollState = .{ .offset = .{ 3, 4 } };
    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .label = .{ .text = "child" } },
        .parent = .root,
        .rect = .{ .x = 2, .y = 3, .w = 7, .h = 8 },
    });
    try tree.appendNode(.{
        .id = .root,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 100, .y = 200, .w = 30, .h = 40 },
        .style = .{
            .border_inset = .{
                .top = .{ .length = 11 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 5 },
            },
            .padding_inset = .{
                .top = .{ .length = 13 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 7 },
            },
        },
        .scroll = .{ .state = &root_scroll, .axis = .both },
    });
    try tree.appendChild(.root, child_id);

    try std.testing.expectEqual(
        Rect{ .x = 0, .y = 0, .w = 30, .h = 40 },
        absoluteRect(&tree, .root),
    );
    try std.testing.expectEqual(
        Rect{ .x = 14, .y = 27, .w = 7, .h = 8 },
        absoluteRect(&tree, child_id),
    );
    try std.testing.expectEqual(
        Rect{ .x = 11, .y = 23, .w = 7, .h = 8 },
        visualBorderRect(&tree, child_id),
    );
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
            .border_inset = .{
                .top = .{ .length = 3 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 2 },
            },
            .padding_inset = .{
                .top = .{ .length = 2 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 1 },
            },
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
