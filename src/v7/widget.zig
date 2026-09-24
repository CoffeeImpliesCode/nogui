//! v7 widget types — geometry, per-child flex data, kind union, and the
//! per-frame widget tree.
const std = @import("std");
const perf_counters = @import("perf_counters.zig");
const v7_options = @import("v7_options");
const CounterSink = perf_counters.CounterSink;

const FrameNodeId = @import("id.zig").FrameNodeId;
const WidgetId = @import("id.zig").WidgetId;
const callback = @import("callback.zig");
const style = @import("style.zig");
const element = @import("element.zig");
const text = @import("text.zig");

pub const PaintStyleOverride = style.PaintStyleOverride;
pub const ComponentDefaults = style.ComponentDefaults;
pub const Style = style.Style;
pub const PaintStyle = style.PaintStyle;
pub const StyleOverride = style.StyleOverride;
pub const Display = style.Display;
pub const Visibility = style.Visibility;
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

/// A clip rectangle in logical window space. The GPU clip buffer stores
/// these verbatim (four f32, 16 bytes); shader input converts device
/// fragment coordinates to logical units before clipping.
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

/// Text overflow behavior: what a text box does with content wider than itself.
/// The enum lives with the text request that carries the policy; it is
/// re-exported here because a node is where the policy is read and set.
pub const TextOverflow = text.TextOverflow;

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

/// Checkbox and radio indicator size in px.
pub const control_indicator_size: f32 = 18;

/// Switch track width in px.
pub const switch_track_width: f32 = 30;

/// Horizontal gap between a control indicator and its label in px.
pub const control_gap: f32 = 6;

/// The text column a control's caption starts in. Measure decoration and paint
/// both read this ONE table, so a caption and its box cannot disagree about
/// where the text begins.
pub const TextInsets = struct {
    /// Horizontal space before the caption, occupied by a control indicator.
    leading: f32 = 0,
    /// Horizontal space after the caption. Always zero today; the field keeps
    /// the table symmetric so a trailing decoration is one edit rather than a
    /// second convention.
    trailing: f32 = 0,
    top: f32 = 0,
    bottom: f32 = 0,

    /// Total horizontal inset the caption's column gives up.
    pub fn horizontal(self: TextInsets) f32 {
        return self.leading + self.trailing;
    }

    /// Total vertical inset the caption's line box gives up.
    pub fn vertical(self: TextInsets) f32 {
        return self.top + self.bottom;
    }
};

/// The one text-inset table, by widget kind. A default unstyled node has no
/// insets at all, so it needs no decoration work and no extra measurement.
pub fn textInsets(kind: WidgetKind) TextInsets {
    return switch (kind) {
        .checkbox, .radio => .{ .leading = control_indicator_size + control_gap },
        .switch_control => .{ .leading = switch_track_width + control_gap },
        .progress => .{ .bottom = 14 },
        .label, .button, .slider, .spacer, .column, .row, .separator, .element => .{},
    };
}

/// Axis used by a separator leaf.
pub const SeparatorAxis = enum { horizontal, vertical };

/// What a widget node is. Payload differs per kind; fields with defaults
/// may be omitted at construction.
/// Caller-owned control state must remain valid while any frame tree that
/// refers to it can still be inspected, including the previous double-buffered
/// frame.
pub const WidgetKind = union(enum) {
    column: struct {},
    row: struct {},
    /// `color` is the text color in sRGB (converted to Oklab by the
    /// renderer, like every widget color); default = white.
    label: struct { text: []const u8, color: [4]f32 = .{ 1, 1, 1, 1 } },
    checkbox: struct {
        label: []const u8,
        value: *bool,
        color: [4]f32 = .{ 1, 1, 1, 1 },
    },
    switch_control: struct {
        label: []const u8,
        value: *bool,
        color: [4]f32 = .{ 1, 1, 1, 1 },
    },
    radio: struct {
        label: []const u8,
        selected: *?u32,
        option: u32,
        color: [4]f32 = .{ 1, 1, 1, 1 },
    },
    progress: struct {
        label: []const u8,
        value: f32,
        min: f32,
        max: f32,
        color: [4]f32 = .{ 1, 1, 1, 1 },
    },
    separator: struct {
        axis: SeparatorAxis = .horizontal,
        thickness: f32 = 1,
        color: [4]f32 = .{ 1, 1, 1, 1 },
    },
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
        owner: FrameNodeId = .root, // component_id at creation time
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
    element: *element.Frame,
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

/// Per-frame input eligibility. Focus policy resolves defaults by widget kind.
pub const Interaction = struct {
    disabled: bool = false,
    focusable: ?bool = null,
    /// Negative values stay programmatically focusable but leave Tab traversal.
    tab_index: ?i32 = null,
    tab_group: ?u32 = null,
};

/// The band a placed subtree paints in.
///
/// Placement is frame-local, so this travels with the NODE and by VALUE: a
/// published tree — and the previous tree a consumer still reads — carries
/// its own bands without reaching into a bank the next frame recycles. It is
/// a resolved physical band, never the authored node layer, so a placed node
/// keeps its own authored order INSIDE the band.
pub const PlacementPaint = struct {
    /// Registration index of the record whose subtree this node is in. The
    /// band it names is one indexed read, not a search.
    record_index: u32,
    /// Band BASE. Disjoint per placed record and above every application
    /// layer, so a popup covers the whole application while its own nodes
    /// keep the order they authored.
    layer: u32,
    /// The (priority, registration) key this band was assigned by: the same
    /// comparator hit routing uses.
    order: u64,
};

/// One node in the tree.
pub const WidgetNode = struct {
    id: FrameNodeId,
    /// Stable identity for interactive nodes; display nodes remain unkeyed.
    widget_id: ?WidgetId = null,
    interaction: Interaction = .{},
    /// Dense component receiver for routed input in this committed frame.
    owner: FrameNodeId = .root,
    kind: WidgetKind,
    parent: FrameNodeId,
    children: std.ArrayListUnmanaged(FrameNodeId) = .empty,
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
    /// Paint, input and semantic visibility, including hidden ancestors.
    paint_hidden: bool = false,
    /// A REGISTERED overlay record resolved to nothing this frame, so this
    /// node is inside a DORMANT overlay subtree: laid out, filled and
    /// authored visible, and placed by nothing. Painting or hitting it would
    /// show and route a popup the consumer dismissed, so every ordinary paint
    /// and hit walk skips it — the draw-command collector, the scene's own
    /// chrome and rings, `input.hitTest`, `input.isEnabled` (and with it tab
    /// order and focus assignment) and the inspector's own visibility.
    ///
    /// The flag is PER NODE and never inherited: `stage` decides it by the
    /// DEEPEST record that names the node, so a node inside a dormant subtree
    /// is dormant itself, a nested unplaced record is hidden inside a placed
    /// ancestor at any priority, and a nested PLACED record inside a dormant
    /// one stays painted, hittable, pressable and focusable together.
    ///
    /// BY VALUE, like `placement_clip` and `placement_paint`: `Frame.stage`
    /// writes it into the tree it resolves and it is published with that tree,
    /// so a tree keeps answering for its own frame and no walk has to consult
    /// the frame's bank. It is a placement fact, never an authored one:
    /// `isVisible` reads `paint_hidden` alone, and `stage` clears this flag for
    /// every node before it resolves anything, so a marker left by an earlier
    /// resolution can never be read back as authored hidden content.
    overlay_dormant: bool = false,
    /// Canonical typed layout values.
    style: Style = .{},
    /// Resolved typed paint values. This is the canonical paint view.
    paint: PaintStyle = .{},
    scroll: ?ScrollSpec = null,
    text_overflow: TextOverflow = .visible,
    text_max_width: ?f32 = null,
    shared_columns: ?*const SharedColumns = null,
    /// The AUTHORED text override for this node, copied into the frame arena.
    /// Null on a node that carries no text options of its own; a container with
    /// overrides keeps it so directly assembled trees inherit too.
    text_input: ?*const text.TextInput = null,
    /// The RESOLVED text request, frame-owned and immutable after layout.
    /// Null until inheritance is resolved, and forever on a node whose whole
    /// subtree asks for no text.
    text_request: ?*const text.NodeText = null,
    /// Carried through measure so a fixture can ask for vertical text. Layout
    /// assigns no writing-mode semantics of its own.
    writing_mode: text.WritingMode = .horizontal_tb,
    /// Ancestor clip applied to this node's own decorations. The node's
    /// content clip must not crop its border, shadow, slider chrome, or
    /// interaction rings.
    paint_clip_id: u32 = 0xFFFFFFFF,
    /// Clip applied to this node's content, including text and icons.
    /// 0xFFFFFFFF means no clip.
    clip_id: u32 = 0xFFFFFFFF,
    /// A clip imposed on this node by something that does not resize it.
    /// Overlay placement writes the anchor's inherited clip here instead of
    /// shrinking the content box, so a clipped popup keeps its laid-out size
    /// and origin. Frame-local: default null, cloned like any other node
    /// field, and it constrains this node's OWN fill and every descendant —
    /// paint, hit and inspection all read this one field. The GPU clip buffer
    /// ABI is unchanged; consumers intersect it into a pushed clip rect.
    placement_clip: ?ClipRect = null,

    /// The paint band overlay placement assigned this node, or null when no
    /// placement covers it. Frame-local like `placement_clip` and cloned like
    /// any other node field: every painter reads it through
    /// `effectiveLayer`, and the authored `paint.layer` is never mutated, so
    /// the authored style stays exactly what inspection reports it as.
    placement_paint: ?PlacementPaint = null,

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

/// A late query or list measures its viewport independently of materialized
/// children. Layout still visits those children to establish scroll extent.
pub fn isLateQuery(node: *const WidgetNode) bool {
    return node.kind == .element and switch (node.kind.element.late_scope) {
        .query, .list => true,
        .none => false,
    };
}

/// A node is visible only if neither it nor any ancestor is hidden or display-none.
/// The parent walk also handles directly assembled trees without a layout pass.
pub fn isVisible(tree: *const WidgetTree, id: FrameNodeId) bool {
    if (tree.visibility_prepared) {
        const node = tree.nodeConst(id) orelse return false;
        return !node.paint_hidden;
    }
    var current = id;
    var remaining = tree.nodes.items.len;
    while (current != .root and remaining > 0) : (remaining -= 1) {
        const node = tree.nodeConst(current) orelse return false;
        if (node.style.display == .none or node.style.visibility == .hidden) return false;
        current = node.parent;
    }
    return current == .root;
}

/// The authored local layer plus one custom record's own bump. Every layer
/// addition is CHECKED and typed: a layer space that cannot hold the sum
/// fails the frame instead of wrapping or clamping onto a layer that means
/// something else.
pub fn localLayer(node: *const WidgetNode, bump: u32) error{PaintLayerOverflow}!u32 {
    return std.math.add(u32, node.paint.layer, bump) catch error.PaintLayerOverflow;
}

/// The physical layer this node paints in: its authored local layer, raised
/// by the band its placement assigned. One definition every painter reads —
/// node background, custom records and generated control chrome alike — so a
/// placed subtree can never be painted over by the application it covers,
/// while its own nodes keep the order they authored inside the band.
pub fn effectiveLayer(node: *const WidgetNode, bump: u32) error{PaintLayerOverflow}!u32 {
    const local = try localLayer(node, bump);
    const band = node.placement_paint orelse return local;
    return std.math.add(u32, local, band.layer) catch error.PaintLayerOverflow;
}

/// The highest raw local layer THIS node emits: its own authored layer, or
/// the largest authored-plus-custom-bump sum among its custom records. A node
/// with no custom records emits its authored layer and nothing else.
pub fn emittedLocalLayer(node: *const WidgetNode) error{PaintLayerOverflow}!u32 {
    var raw = node.paint.layer;
    if (node.kind == .element) {
        for (node.kind.element.paint_records.items) |record| {
            const bump = switch (record) {
                .rect => |value| value.layer,
                .path => |value| value.layer,
                .image => |value| value.layer,
            };
            raw = @max(raw, try localLayer(node, bump));
        }
    }
    return raw;
}

/// The highest raw local layer the application actually emits. Overlay bands
/// are assigned above it, so a placed popup always covers the whole tree.
///
/// ONE scalar pass and no scratch: the answer is a maximum, so a node never
/// needs its descendants' maxima and nothing here inherits from an ancestor.
/// The painter skips exactly the nodes this skips, so an unplaced custom
/// record that stays high still counts — it is only ever missing a band. A
/// DORMANT overlay subtree is the one exception, and it is the same
/// exception on both sides: its nodes are excluded here and excluded by every
/// painter, so a record nothing placed can neither paint nor lift a band.
/// Its own raw layer is untouched: `emittedLocalLayer` still reports it, so
/// the same record counts again the moment a placement places it.
pub fn maximumPaintLayer(tree: *const WidgetTree) error{PaintLayerOverflow}!u32 {
    var maximum: u32 = 0;
    for (tree.nodes.items) |node| {
        if (node.paint_hidden or node.overlay_dormant) continue;
        maximum = @max(maximum, try emittedLocalLayer(&node));
    }
    return maximum;
}

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
    /// Storage for the immutable text records `layoutTree` publishes. A record
    /// outlives the publication that replaced it: a snapshot taken before the
    /// change still reads the superseded record, so nothing here is ever freed
    /// individually. One arena releases the whole set at `deinit`, which is why
    /// a repeated layout over a GPA-backed tree leaks nothing. Backing chunks
    /// come from `allocator`, so a tree built inside a frame arena carries its
    /// records in that arena and needs no teardown of its own.
    text_records: std.heap.ArenaAllocator,
    next_id: u32 = 1,
    /// The canonical layout pass has propagated display and visibility flags.
    visibility_prepared: bool = false,
    /// Frame-local index maintained by `appendNode` for production trees.
    /// Directly assembled trees can leave it incomplete; lookup then scans.
    id_index: std.AutoHashMapUnmanaged(FrameNodeId, u32) = .empty,
    /// Stable handle to this frame's dense node ID. Owned by this frame arena.
    stable_index: std.AutoHashMapUnmanaged(WidgetId, FrameNodeId) = .empty,
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
            .text_records = std.heap.ArenaAllocator.init(allocator),
            .counter_sink = CounterSink.init(null),
        };
    }

    /// The allocator `layoutTree` publishes text records through. Read it
    /// through the tree's own address: `init` returns by value, so an allocator
    /// captured while building the tree would name the temporary, not the
    /// storage the records live in.
    pub fn textRecordAllocator(self: *WidgetTree) std.mem.Allocator {
        return self.text_records.allocator();
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
        var minimum_id: u32 = std.math.maxInt(u32);
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
            const node_id = @intFromEnum(node_value.id);
            maximum_id = @max(maximum_id, node_id);
            minimum_id = @min(minimum_id, node_id);
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
        const interval_len_u64 =
            @as(u64, maximum_id) - @as(u64, minimum_id) + 1;
        const contiguous_interval = interval_len_u64 == node_count_u64;

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
        if (contiguous_interval) {
            // Validation and cardinality prove every ID from minimum through
            // maximum is filled below, so only the absent prefix needs setup.
            const prefix_len = std.math.cast(usize, minimum_id) orelse unreachable;
            @memset(candidate[0..prefix_len], dense_absent);
        } else {
            @memset(candidate, dense_absent);
        }
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
        self.stable_index.deinit(self.allocator);
        // Superseded records included: nothing read them after the tree died.
        self.text_records.deinit();
        self.* = undefined;
    }

    /// Append a node and atomically add its frame-local lookup entry.
    pub fn appendNode(self: *WidgetTree, node_value: WidgetNode) error{ OutOfMemory, DuplicateWidgetKey }!void {
        self.invalidateDenseIdLookup();
        self.visibility_prepared = false;
        try self.nodes.append(self.allocator, node_value);
        errdefer _ = self.nodes.pop();
        try self.id_index.put(
            self.allocator,
            node_value.id,
            @intCast(self.nodes.items.len - 1),
        );
        errdefer _ = self.id_index.remove(node_value.id);
        if (node_value.widget_id) |widget_id| {
            const entry = try self.stable_index.getOrPut(self.allocator, widget_id);
            if (entry.found_existing) return error.DuplicateWidgetKey;
            entry.value_ptr.* = node_value.id;
        }
    }

    /// Attach an explicit key after a control's dense node was created.
    /// The frame-local lookup is published only after the map insert succeeds.
    pub fn bindWidget(self: *WidgetTree, id: FrameNodeId, widget_id: WidgetId) !void {
        const node_value = self.node(id) orelse return error.InvalidStyle;
        if (node_value.widget_id != null) return error.DuplicateWidgetKey;
        const entry = try self.stable_index.getOrPut(self.allocator, widget_id);
        if (entry.found_existing) return error.DuplicateWidgetKey;
        node_value.widget_id = widget_id;
        entry.value_ptr.* = id;
    }

    /// Append a child id through the tree-owned frame allocator.
    /// Missing parent IDs are malformed tree input and return
    /// `error.InvalidStyle`.
    pub fn appendChild(self: *WidgetTree, parent: FrameNodeId, child: FrameNodeId) !void {
        const parent_node = self.node(parent) orelse return error.InvalidStyle;
        try parent_node.children.append(self.allocator, child);
    }

    /// Return a node's array index. Production trees use the complete map;
    /// directly assembled trees fall back to their original linear lookup.
    pub fn nodeIndex(self: *const WidgetTree, id: FrameNodeId) ?usize {
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
        self.visibility_prepared = false;
        const moved = self.nodes.orderedRemove(index);
        self.nodes.appendAssumeCapacity(moved);
        for (self.nodes.items[index..], index..) |node_value, new_index| {
            if (self.id_index.getPtr(node_value.id)) |stored_index| {
                stored_index.* = @intCast(new_index);
            }
        }
    }

    /// Rebuild postorder once after a bounded late subroot has added children
    /// beneath an already closed ancestor. Validation precedes any mutation.
    pub fn finalizePostorder(self: *WidgetTree, allocator: std.mem.Allocator) !void {
        const count = self.nodes.items.len;
        const ordered = try allocator.alloc(WidgetNode, count);
        defer allocator.free(ordered);
        const marks = try allocator.alloc(u8, count);
        defer allocator.free(marks);
        @memset(marks, 0);
        const Cursor = struct { index: usize, child: usize = 0 };
        const stack = try allocator.alloc(Cursor, count);
        defer allocator.free(stack);
        var written: usize = 0;
        for (self.nodes.items, 0..) |node_value, root_index| {
            if (node_value.parent != .root) continue;
            var depth: usize = 1;
            stack[0] = .{ .index = root_index };
            marks[root_index] = 1;
            while (depth > 0) {
                const cursor = &stack[depth - 1];
                const current = &self.nodes.items[cursor.index];
                if (cursor.child < current.children.items.len) {
                    const child_id = current.children.items[cursor.child];
                    cursor.child += 1;
                    const child_index = self.nodeIndex(child_id) orelse return error.InvalidStyle;
                    if (self.nodes.items[child_index].parent != current.id or
                        marks[child_index] != 0 or depth == count) return error.InvalidStyle;
                    marks[child_index] = 1;
                    stack[depth] = .{ .index = child_index };
                    depth += 1;
                    continue;
                }
                ordered[written] = current.*;
                written += 1;
                marks[cursor.index] = 2;
                depth -= 1;
            }
        }
        if (written != count) return error.InvalidStyle;
        self.invalidateDenseIdLookup();
        @memcpy(self.nodes.items, ordered);
        for (self.nodes.items, 0..) |node_value, index| {
            const stored = self.id_index.getPtr(node_value.id) orelse return error.InvalidStyle;
            stored.* = @intCast(index);
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
    pub fn node(self: *WidgetTree, id: FrameNodeId) ?*WidgetNode {
        const index = self.nodeIndex(id) orelse return null;
        return &self.nodes.items[index];
    }

    /// Const-safe lookup with the same indexed and fallback behavior as `node`.
    pub fn nodeConst(self: *const WidgetTree, id: FrameNodeId) ?*const WidgetNode {
        const index = self.nodeIndex(id) orelse return null;
        return &self.nodes.items[index];
    }

    /// Resolve a persistent handle inside this specific committed or staged
    /// tree. A handle from another owner or retired generation cannot match.
    pub fn frameNode(self: *const WidgetTree, widget_id: WidgetId) ?FrameNodeId {
        if (self.stable_index.get(widget_id)) |id| return id;
        if (self.id_index.count() == self.nodes.items.len) return null;
        for (self.nodes.items) |node_value| {
            if (node_value.widget_id) |candidate| {
                if (candidate.eql(widget_id)) return node_value.id;
            }
        }
        return null;
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
    id: FrameNodeId,
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
pub fn absoluteBorderOrigin(tree: *const WidgetTree, id: FrameNodeId) [2]f32 {
    return resolveBorderOrigin(false, tree, id).origin;
}

/// Absolute border box of a node (origin + its own w/h).
pub fn absoluteRect(tree: *const WidgetTree, id: FrameNodeId) Rect {
    const resolved = resolveBorderOrigin(false, tree, id);
    const origin = resolved.origin;
    const node = resolved.node orelse return .{ .x = origin[0], .y = origin[1] };
    return .{ .x = origin[0], .y = origin[1], .w = node.rect.w, .h = node.rect.h };
}

/// Resolve a node's visual border-box origin, accounting for ancestor scroll.
/// The target node's own scroll offset does not move its border box.
pub fn visualBorderOrigin(tree: *const WidgetTree, id: FrameNodeId) [2]f32 {
    return resolveBorderOrigin(true, tree, id).origin;
}

/// Visual border box of a node, after ancestor scroll offsets are applied.
pub fn visualBorderRect(tree: *const WidgetTree, id: FrameNodeId) Rect {
    const resolved = resolveBorderOrigin(true, tree, id);
    const origin = resolved.origin;
    const node = resolved.node orelse return .{ .x = origin[0], .y = origin[1] };
    return .{ .x = origin[0], .y = origin[1], .w = node.rect.w, .h = node.rect.h };
}

/// Move a node's RELATIVE border box so its VISUAL origin lands at `origin`.
/// This is the one mutation a frame-local placement performs: every
/// descendant inherits the move through the parent walk in
/// `visualBorderRect`, and the node's own border box, content box and
/// semantic bounds follow it, so paint, input, semantics and inspection read
/// the same geometry without a per-node offset.
///
/// Relative rects stay the storage form: the offset is written into the
/// subtree's root, never into a second copy of the tree.
pub fn moveVisualOrigin(
    tree: *WidgetTree,
    id: FrameNodeId,
    origin: [2]f32,
) error{InvalidGeometry}!void {
    if (!std.math.isFinite(origin[0]) or !std.math.isFinite(origin[1]))
        return error.InvalidGeometry;
    const node = tree.node(id) orelse return error.InvalidGeometry;
    const parent_id = node.parent;
    if (parent_id == .root) {
        node.rect.x = origin[0];
        node.rect.y = origin[1];
        return;
    }
    const parent = tree.nodeConst(parent_id) orelse return error.InvalidGeometry;
    const edges = geometryBoxEdges(parent, parent.rect.w);
    var base = resolveBorderOrigin(true, tree, parent_id).origin;
    base[0] += edges.border.left + edges.padding.left;
    base[1] += edges.border.top + edges.padding.top;
    if (parent.scroll) |scroll| {
        base[0] -= scroll.state.offset[0];
        base[1] -= scroll.state.offset[1];
    }
    node.rect.x = origin[0] - base[0];
    node.rect.y = origin[1] - base[1];
    if (!std.math.isFinite(node.rect.x) or !std.math.isFinite(node.rect.y))
        return error.InvalidGeometry;
}

/// Visual content box of a node, after ancestor scroll offsets are applied.
pub fn visualContentRect(tree: *const WidgetTree, id: FrameNodeId) Rect {
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

/// The effective clip on a node's own painted box: its border box intersected
/// with the nearest `placement_clip` on itself or an ancestor. This is the ONE
/// definition every consumer reads — paint, hit and inspection — so a popup
/// clipped by placement clips identically in all three. Null means no
/// placement clip constrains the node.
pub fn placedContentRect(tree: *const WidgetTree, id: FrameNodeId) ?Rect {
    var clip: ?ClipRect = null;
    var current = id;
    var remaining = tree.nodes.items.len + 1;
    while (current != .root and remaining > 0) : (remaining -= 1) {
        const node = tree.nodeConst(current) orelse break;
        if (node.placement_clip) |imposed| {
            clip = if (clip) |existing| intersectClips(existing, imposed) else imposed;
        }
        if (current == id) break;
        current = node.parent;
    }
    const imposed = clip orelse return null;
    return clipRectToRect(visualBorderRect(tree, id), imposed);
}

/// Intersect two clip rects, keeping an axis unconstrained when either side
/// leaves it unconstrained. This is the same rule drawcmd applies when it
/// folds a clip into a pushed rect, expressed once for the core.
pub fn intersectClips(first: ClipRect, second: ClipRect) ClipRect {
    const x = intersectClipAxis(first.x, first.w, second.x, second.w);
    const y = intersectClipAxis(first.y, first.h, second.y, second.h);
    return .{ .x = x.start, .y = y.start, .w = x.extent, .h = y.extent };
}

const ClipAxisSpan = struct { start: f32, extent: f32 };

fn intersectClipAxis(
    start: f32,
    extent: f32,
    other_start: f32,
    other_extent: f32,
) ClipAxisSpan {
    if (extent == ClipRect.disabled_extent) return .{ .start = other_start, .extent = other_extent };
    if (other_extent == ClipRect.disabled_extent) return .{ .start = start, .extent = extent };
    const from = @max(start, other_start);
    return .{
        .start = from,
        .extent = @max(0, @min(start + extent, other_start + other_extent) - from),
    };
}

/// The part of `rect` a clip leaves visible, as a plain rectangle. An axis the
/// clip does not constrain keeps the whole extent.
pub fn clipRectToRect(rect: Rect, clip: ClipRect) Rect {
    var out = rect;
    if (clip.clipsX()) {
        const start = @max(rect.x, clip.x);
        out.x = start;
        out.w = @max(0, @min(rect.x + rect.w, clip.x + clip.w) - start);
    }
    if (clip.clipsY()) {
        const start = @max(rect.y, clip.y);
        out.y = start;
        out.h = @max(0, @min(rect.y + rect.h, clip.y + clip.h) - start);
    }
    return out;
}

/// Return whether a point is inside every clipped ancestor axis of a node,
/// including any clip imposed by placement. This is the single clipping rule:
/// hit routing, the painter and the inspector all reduce to this.
pub fn pointInPlacedClipChain(tree: *const WidgetTree, id: FrameNodeId, pos: [2]f32) bool {
    var cur = id;
    var remaining = tree.nodes.items.len + 1;
    while (cur != .root and remaining > 0) : (remaining -= 1) {
        tree.counter_sink.add(.ancestor_reads, 1);
        const node = tree.nodeConst(cur) orelse break;
        if (node.placement_clip) |imposed| {
            if (!pointInClipAxes(
                clipRectToRect(visualBorderRect(tree, cur), imposed),
                .{ .x = imposed.clipsX(), .y = imposed.clipsY() },
                pos,
            )) return false;
        }
        if (!pointInClipAxes(
            visualBorderRect(tree, cur),
            node.contentClipAxes(),
            pos,
        )) return false;
        cur = node.parent;
    }
    return true;
}

/// Return whether a point is inside every clipped ancestor axis of a node.
/// A clip imposed by overlay placement is part of that chain, so hit routing,
/// the painter and the inspector cannot disagree about a clipped popup.
pub fn pointInClipChain(tree: *const WidgetTree, id: FrameNodeId, pos: [2]f32) bool {
    return pointInPlacedClipChain(tree, id, pos);
}

/// Absolute CONTENT box of a node: the absolute border box inset by the
/// node's own border + padding. Where children live and text draws.
/// Missing IDs are malformed tree input and return `error.InvalidStyle`.
pub fn contentRect(tree: *const WidgetTree, id: FrameNodeId) error{InvalidStyle}!Rect {
    const node = tree.nodeConst(id) orelse return error.InvalidStyle;
    const border_rect = absoluteRect(tree, id);
    return contentBoxRect(border_rect, node);
}

test "WidgetTree: indexed lookup finds live ids and rejects absent ids" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const id1: FrameNodeId = @enumFromInt(1);
    const id2: FrameNodeId = @enumFromInt(2);
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

test "api-w02 a dense node cannot be rebound to a second stable identity" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    const first_node: FrameNodeId = @enumFromInt(1);
    const second_node: FrameNodeId = @enumFromInt(2);
    try tree.appendNode(.{
        .id = first_node,
        .kind = .{ .spacer = .{} },
        .parent = .root,
    });
    try tree.appendNode(.{
        .id = second_node,
        .kind = .{ .spacer = .{} },
        .parent = .root,
    });
    const first: WidgetId = .{ .owner = 1, .slot = 1, .generation = 1 };
    const second: WidgetId = .{ .owner = 1, .slot = 2, .generation = 1 };
    try tree.bindWidget(first_node, first);
    try std.testing.expectError(error.DuplicateWidgetKey, tree.bindWidget(first_node, second));
    try std.testing.expectEqual(first_node, tree.frameNode(first).?);
    try std.testing.expectEqual(@as(?FrameNodeId, null), tree.frameNode(second));
    try tree.bindWidget(second_node, second);
    try std.testing.expectError(error.DuplicateWidgetKey, tree.bindWidget(second_node, first));
    try std.testing.expectEqual(first, tree.nodeConst(first_node).?.widget_id.?);
    try std.testing.expectEqual(second, tree.nodeConst(second_node).?.widget_id.?);
}

// A contiguous interval covers every ID from its minimum through its maximum,
// even when post-order node indices do not follow ID order.
test "WidgetTree: consecutive IDs start at zero, one, or two" {
    for ([_]u32{ 0, 1, 2 }) |minimum_id| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const ids = [_]FrameNodeId{
            @enumFromInt(minimum_id + 2),
            @enumFromInt(minimum_id),
            @enumFromInt(minimum_id + 1),
        };
        for (ids) |id| {
            try tree.appendNode(.{
                .id = id,
                .kind = .{ .spacer = .{} },
                .parent = .root,
            });
        }
        try tree.prepareIdLookup();

        const lookup = tree.dense_id_index.?;
        for (ids, 0..) |id, node_index| {
            try std.testing.expectEqual(@as(?usize, node_index), tree.nodeIndex(id));
            try std.testing.expectEqual(id, tree.nodeConst(id).?.id);
        }
        var absent_id: u32 = 0;
        while (absent_id < minimum_id) : (absent_id += 1) {
            try std.testing.expectEqual(WidgetTree.dense_absent, lookup[absent_id]);
            try std.testing.expectEqual(@as(?usize, null), tree.nodeIndex(@enumFromInt(absent_id)));
        }
        try std.testing.expectEqual(
            @as(?usize, null),
            tree.nodeIndex(@enumFromInt(minimum_id + 3)),
        );
    }
}

// A prepared lookup must use stored post-order indices instead of deriving
// positions from sequential IDs, and stale stored indices must still scan.
test "WidgetTree: prepared lookup follows current post-order nodes" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const parent_id: FrameNodeId = @enumFromInt(1);
    const child_id: FrameNodeId = @enumFromInt(3);
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

// Gaps inside a dense-enough span must remain absent, not inherit data from
// the allocator or a previously prepared view.
test "WidgetTree: sparse IDs retain absent entries inside the dense span" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const ids = [_]FrameNodeId{ @enumFromInt(4), .root, @enumFromInt(2) };
    for (ids) |id| {
        try tree.appendNode(.{
            .id = id,
            .kind = .{ .spacer = .{} },
            .parent = .root,
        });
    }
    try tree.prepareIdLookup();

    const lookup = tree.dense_id_index.?;
    for ([_]u32{ 1, 3 }) |absent_id| {
        try std.testing.expectEqual(WidgetTree.dense_absent, lookup[absent_id]);
        try std.testing.expectEqual(@as(?usize, null), tree.nodeIndex(@enumFromInt(absent_id)));
    }
    for (ids, 0..) |id, node_index| {
        try std.testing.expectEqual(@as(?usize, node_index), tree.nodeIndex(id));
    }
}

// A full-cardinality map can still be malformed. Preparation must not replace
// its established missing-key behavior with a dense node scan.
test "WidgetTree: malformed complete map remains lookup authority" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const id1: FrameNodeId = @enumFromInt(1);
    const id2: FrameNodeId = @enumFromInt(2);
    const unrelated_id: FrameNodeId = @enumFromInt(3);
    for ([_]FrameNodeId{ id1, id2 }) |id| {
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

// If the map omits a node, preparation must leave lookup on the linear
// fallback so that the missing map entry does not hide that node.
test "WidgetTree: incomplete map scans nodes after preparation" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const id1: FrameNodeId = @enumFromInt(1);
    const id2: FrameNodeId = @enumFromInt(2);
    for ([_]FrameNodeId{ id1, id2 }) |id| {
        try tree.appendNode(.{
            .id = id,
            .kind = .{ .spacer = .{} },
            .parent = .root,
        });
    }
    try tree.prepareIdLookup();
    try std.testing.expect(tree.id_index.remove(id1));
    try tree.prepareIdLookup();

    try std.testing.expect(tree.dense_id_index == null);
    try std.testing.expectEqual(@as(?usize, 0), tree.nodeIndex(id1));
    try std.testing.expectEqual(id1, tree.nodeConst(id1).?.id);
}

// Equal map cardinality does not prove that stored post-order indices match.
test "WidgetTree: mismatched map index rejects prepared lookup" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const id1: FrameNodeId = @enumFromInt(1);
    try tree.appendNode(.{
        .id = .root,
        .kind = .{ .spacer = .{} },
        .parent = .root,
    });
    try tree.appendNode(.{
        .id = id1,
        .kind = .{ .spacer = .{} },
        .parent = .root,
    });
    try tree.prepareIdLookup();
    tree.id_index.getPtr(.root).?.* = 1;
    try tree.prepareIdLookup();

    try std.testing.expect(tree.dense_id_index == null);
    try std.testing.expectEqual(@as(?usize, 0), tree.nodeIndex(.root));
    try std.testing.expectEqual(id1, tree.nodeConst(id1).?.id);
}

// The maximum representable ID must avoid max-plus-one overflow and retain the
// existing sparse-map lookup path.
test "WidgetTree: maximum ID remains on sparse fallback" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const maximum_id: FrameNodeId = @enumFromInt(std.math.maxInt(u32));
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

    const id1: FrameNodeId = @enumFromInt(1);
    const id2: FrameNodeId = @enumFromInt(2);
    const id3: FrameNodeId = @enumFromInt(3);
    for ([_]FrameNodeId{ id1, id2 }) |id| {
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
    const root_id: FrameNodeId = @enumFromInt(1);
    const child_id: FrameNodeId = @enumFromInt(2);
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

    const missing_id: FrameNodeId = @enumFromInt(99);
    try std.testing.expectError(
        error.InvalidStyle,
        tree.appendChild(missing_id, @enumFromInt(1)),
    );
    try std.testing.expectError(error.InvalidStyle, contentRect(&tree, missing_id));
}

test "WidgetTree: moving a node to the end reindexes shifted nodes" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const id1: FrameNodeId = @enumFromInt(1);
    const id2: FrameNodeId = @enumFromInt(2);
    const id3: FrameNodeId = @enumFromInt(3);
    for ([_]FrameNodeId{ id1, id2, id3 }) |id| {
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

    const id1: FrameNodeId = @enumFromInt(1);
    const id2: FrameNodeId = @enumFromInt(2);
    const id3: FrameNodeId = @enumFromInt(3);
    const id4: FrameNodeId = @enumFromInt(4);
    const id5: FrameNodeId = @enumFromInt(5);

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
    try std.testing.expectEqual(@as(FrameNodeId, @enumFromInt(1)), small[0].id);
    try std.testing.expectEqual(@as(FrameNodeId, @enumFromInt(2)), small[1].id);
    // Writing past buf.len would trip the slice bounds check under `zig test`.
}

test "absoluteRect: walks parent content boxes through border+padding" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    // Root-level column with padding, holding a row with a border, holding
    // a label offset relative to the row's content box.
    const col: FrameNodeId = @enumFromInt(1);
    const row: FrameNodeId = @enumFromInt(2);
    const label: FrameNodeId = @enumFromInt(3);

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

    const child_id: FrameNodeId = @enumFromInt(1);
    const parent_id: FrameNodeId = @enumFromInt(2);
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

    const child_id: FrameNodeId = @enumFromInt(1);
    const parent_id: FrameNodeId = @enumFromInt(2);
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

    const child_id: FrameNodeId = @enumFromInt(1);
    const parent_id: FrameNodeId = @enumFromInt(2);
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

    const child_id: FrameNodeId = @enumFromInt(1);
    const middle_id: FrameNodeId = @enumFromInt(2);
    const outer_id: FrameNodeId = @enumFromInt(3);
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

    const child_id: FrameNodeId = @enumFromInt(1);
    const parent_id: FrameNodeId = @enumFromInt(2);
    const missing_id: FrameNodeId = @enumFromInt(99);
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

    const child_id: FrameNodeId = @enumFromInt(1);
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

    const col: FrameNodeId = @enumFromInt(1);
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

    const scroll_id: FrameNodeId = @enumFromInt(1);
    const child_id: FrameNodeId = @enumFromInt(2);
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

    const clip_id: FrameNodeId = @enumFromInt(1);
    const child_id: FrameNodeId = @enumFromInt(2);
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
