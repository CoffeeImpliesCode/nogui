//! Frame inspection, stable element identification, and bounded performance collection.
//!
//! Exposes read-only frame snapshots with stable widget identities, resolved layout and
//! visual bounds, clipping boundaries, focus state, active input capture, and semantic
//! roles. Pointer capture state comes from every live focus-manager capture
//! slot, not from one caller-supplied id. Overlay placement metadata is read
//! from the node that carries it, and so is the DORMANT marker, so a snapshot
//! names the popups of the tree it was captured from — the published one and
//! the one before it — with no frame to consult: a registered record that no
//! anchor resolved is reported as overlay content with no order, and as
//! neither painted nor pressable, exactly as the frame behaves. An
//! explicitly supplied frame is the fallback for a tree nothing ever staged.
//! Picking elements matches the engine's overlay and z-order input routing
//! policy. Bounded collectors record frame, task, and action metrics with zero
//! allocations when disabled.
const std = @import("std");
const tracy = @import("tracy");
const perf_counters = @import("perf_counters.zig");
const id_mod = @import("id.zig");
const FrameNodeId = id_mod.FrameNodeId;
const WidgetId = id_mod.WidgetId;
const widget = @import("widget.zig");
const overlay = @import("overlay.zig");
const focus = @import("focus.zig");
const style = @import("style.zig");
const task = @import("task.zig");
const action = @import("action.zig");
const input = @import("input.zig");

pub const InspectError = error{
    StaleHandle,
    NotFound,
    InvalidGeometry,
    CapacityExceeded,
} || std.mem.Allocator.Error;

/// Dedicated owner nonce for synthetic stable IDs generated during inspection.
pub const inspection_owner: u64 = 0x4E4F4755495F494E; // "NOGUI_IN"

/// A generation-checked handle that identifies a widget across frames.
pub const InspectHandle = struct {
    id: WidgetId,
    generation: u32,
    frame_number: u64 = 0,

    pub fn isValidFor(self: InspectHandle, current_id: WidgetId) bool {
        return self.id.owner == current_id.owner and
            self.id.slot == current_id.slot and
            self.generation == current_id.generation;
    }

    pub fn eql(a: InspectHandle, b: InspectHandle) bool {
        return a.id.eql(b.id) and
            a.generation == b.generation and
            a.frame_number == b.frame_number;
    }
};

/// Semantic category of a node in the inspection hierarchy.
pub const Role = enum {
    root,
    column,
    row,
    label,
    button,
    slider,
    checkbox,
    switch_control,
    radio,
    progress,
    separator,
    spacer,
    element,
    overlay,
    custom,
};

/// High-level accessible properties extracted from a widget.
pub const Semantics = struct {
    role: Role = .custom,
    label: ?[]const u8 = null,
    accessible_label: ?[]const u8 = null,
    value_text: ?[]const u8 = null,
    numeric_value: ?f32 = null,
    numeric_min: ?f32 = null,
    numeric_max: ?f32 = null,
    is_checked: ?bool = null,
    is_selected: ?bool = null,
};

/// Keyboard and navigation state.
pub const FocusState = struct {
    /// This node itself holds keyboard focus.
    is_focused: bool = false,
    /// This node is the focus scope that holds focus, or lives inside it.
    contains_focus: bool = false,
    /// The focus manager would accept this node as a focus target.
    can_focus: bool = false,
    tab_index: ?i32 = null,
    tab_group: ?u32 = null,
};

/// Pointer and gesture capture state.
pub const CaptureState = struct {
    is_captured: bool = false,
    /// Live capture slots currently holding this node.
    pointer_count: u8 = 0,
};

/// Resolved layout and paint values of one node.
///
/// Every field is a copy. The snapshot never borrows a component's style
/// storage, so it stays readable after the frame arena is retired.
pub const StyleSummary = struct {
    display: style.Display = .flex,
    visibility: style.Visibility = .visible,
    position: style.Position = .relative,
    direction: style.FlexDirection = .column,
    justify: style.Justify = .normal,
    @"align": style.Align = .stretch,
    box_sizing: style.BoxSizing = .content_box,
    /// Per-axis overflow behavior of the node style.
    overflow: style.OverflowAxes = .{ .width = .visible, .height = .visible },
    grow: f32 = 0,
    shrink: f32 = 1,
    /// Resolved flex/grid gap. A percentage gap without a resolved parent
    /// basis reads as 0 rather than as a fabricated pixel value.
    gap: f32 = 0,
    fill: style.Color = .{ 0, 0, 0, 0 },
    border_color: style.Color = .{ 0, 0, 0, 1 },
    radius: style.Sides = .{},
    opacity: f32 = 1,
    /// The AUTHORED local layer exactly as the style resolved it. Placement
    /// raises a painter's layer by a band and never rewrites the style, so
    /// this stays the number the author wrote.
    layer: style.Layer = 0,
    /// The node clips its own content and descendants on at least one axis.
    clips_content: bool = false,
    transparent: bool = false,
    has_shadow: bool = false,
    texture: ?style.TextureId = null,
    /// The resolved text size in px for a text-bearing node, or 0 when the
    /// node asks for the host default. Read from the resolved request, never
    /// from a separate scalar selector.
    text_size: f32 = 0,
};

/// The routed target and the underlying tree walk at one logical point.
pub const PickResult = struct {
    /// The node real pointer routing selects, including overlay priority.
    node: ?FrameNodeId = null,
    /// The unranked tree hit, before overlay priority. This can name the
    /// control underneath a popup rather than the routed popup.
    tree_node: ?FrameNodeId = null,
};

/// Optional source code location attached to an element.
pub const SourceLocation = struct {
    file: []const u8,
    line: u32,
    column: u32 = 0,
    component_name: []const u8 = "",
};

/// Map of stable widget IDs to source code locations.
pub const SourceMap = struct {
    entries: std.AutoHashMapUnmanaged(WidgetId, SourceLocation) = .empty,

    pub fn deinit(self: *SourceMap, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
        self.* = undefined;
    }

    pub fn put(self: *SourceMap, gpa: std.mem.Allocator, id: WidgetId, loc: SourceLocation) !void {
        try self.entries.put(gpa, id, loc);
    }

    pub fn get(self: *const SourceMap, id: WidgetId) ?SourceLocation {
        return self.entries.get(id);
    }
};

/// Read-only snapshot of one element in an inspected frame.
pub const NodeSnapshot = struct {
    index: u32,
    frame_node_id: FrameNodeId,
    id: WidgetId,
    handle: InspectHandle,
    parent_index: ?u32,
    children_start: u32,
    children_count: u32,
    layout_bounds: widget.Rect,
    /// The box a pointer at this node is tested against. Placement moved the
    /// content root's box IN the tree, so this is the painted box for a placed
    /// node and the laid-out box for every other one.
    input_bounds: widget.Rect,
    /// The painted box. Equal to `input_bounds`: there is no second geometry.
    visual_bounds: widget.Rect,
    /// Intersection of every clipping element from this node up to the window
    /// root, including any clip overlay placement imposed. Null when nothing on
    /// the chain clips.
    clip_bounds: ?widget.Rect,
    /// Which axes of `clip_bounds` are real constraints.
    clip_axes: widget.ClipAxes = .{},
    is_visible: bool,
    /// The layout pass removed this node through itself or an ancestor.
    /// Reported apart from `is_visible`, which follows paint and input.
    layout_hidden: bool = false,
    is_enabled: bool,
    focus: FocusState,
    capture: CaptureState,
    semantics: Semantics,
    style: StyleSummary,
    source: ?SourceLocation = null,
    /// The (priority, registration) key overlay placement assigned this node,
    /// copied from the node's own resolved band. Null for a node no placement
    /// covers, so it carries no place in the paint order.
    overlay_order: ?u64 = null,
    /// The node is OVERLAY CONTENT: a placed record's subtree paints in a band
    /// above the application, and a dormant one is excluded from ordinary
    /// paint and input entirely. A dormant overlay has no placement, so it
    /// stays flagged with no order and none of it is on screen.
    is_overlay: bool = false,
};

/// Options for capturing an immutable frame snapshot.
///
/// Pointer capture comes from every live entry of `focus_manager.captures`, not
/// from one caller-supplied id, so all capture slots reach the snapshot.
pub const CaptureOptions = struct {
    frame_number: u64 = 0,
    timestamp_ns: u64 = 0,
    viewport: widget.Rect,
    tree: *const widget.WidgetTree,
    overlay_frame: ?*const overlay.Frame = null,
    focus_manager: ?*const focus.Manager = null,
    source_map: ?*const SourceMap = null,
};

/// Immutable, self-contained snapshot of one committed frame.
/// Does not retain pointers to transient frame arenas or internal component memory.
pub const FrameSnapshot = struct {
    frame_number: u64,
    timestamp_ns: u64,
    viewport: widget.Rect,
    nodes: []NodeSnapshot,
    children_indices: []u32,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *FrameSnapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Search for an inspected node by its stable widget ID.
    pub fn findNode(self: *const FrameSnapshot, id: WidgetId) ?*const NodeSnapshot {
        for (self.nodes) |*n| {
            if (n.id.eql(id)) return n;
        }
        return null;
    }

    /// Search for an inspected node by its dense frame node ID.
    pub fn findByFrameNodeId(self: *const FrameSnapshot, fnid: FrameNodeId) ?*const NodeSnapshot {
        for (self.nodes) |*n| {
            if (n.frame_node_id == fnid) return n;
        }
        return null;
    }

    /// Resolve an inspection handle against this snapshot.
    /// Returns error.StaleHandle if the widget was replaced, retired, or its generation differs.
    pub fn resolve(self: *const FrameSnapshot, handle: InspectHandle) InspectError!*const NodeSnapshot {
        for (self.nodes) |*n| {
            if (n.id.owner == handle.id.owner and n.id.slot == handle.id.slot) {
                if (n.handle.generation == handle.generation) {
                    return n;
                } else {
                    return error.StaleHandle;
                }
            }
        }
        return error.StaleHandle;
    }

    /// Return the child node indices for a snapshot node.
    pub fn children(self: *const FrameSnapshot, node: *const NodeSnapshot) []const u32 {
        if (node.children_count == 0) return &.{};
        return self.children_indices[node.children_start .. node.children_start + node.children_count];
    }

    /// Pick the element real pointer routing reaches at the point.
    pub fn pick(self: *const FrameSnapshot, pos: [2]f32) ?InspectHandle {
        const hit = self.pickNode(pos) orelse return null;
        return hit.handle;
    }

    /// Pick the node real pointer routing reaches at the point.
    pub fn pickNode(self: *const FrameSnapshot, pos: [2]f32) ?*const NodeSnapshot {
        return self.pickOverlayNode(pos) orelse self.pickTreeNode(pos);
    }

    /// Report the routed target alongside the raw tree walk.
    pub fn pickResult(self: *const FrameSnapshot, pos: [2]f32) PickResult {
        const tree_hit = self.pickTreeNode(pos);
        const hit = self.pickOverlayNode(pos) orelse tree_hit;
        return .{
            .node = if (hit) |n| n.frame_node_id else null,
            .tree_node = if (tree_hit) |n| n.frame_node_id else null,
        };
    }

    /// The first visible node whose box and clip chain contain the point,
    /// without overlay priority.
    fn pickTreeNode(self: *const FrameSnapshot, pos: [2]f32) ?*const NodeSnapshot {
        for (self.nodes) |*n| {
            if (!n.is_visible) continue;
            if (!pointInside(n.input_bounds, pos)) continue;
            if (n.clip_bounds) |clip| {
                if (!widget.pointInClipAxes(clip, n.clip_axes, pos)) continue;
            }
            return n;
        }
        return null;
    }

    /// Topmost overlay content at the point, in paint order. A higher
    /// placement order replaces a lower one; within one placement the first
    /// containing node in post-order wins, as the overlay hit test does.
    fn pickOverlayNode(self: *const FrameSnapshot, pos: [2]f32) ?*const NodeSnapshot {
        var best: ?*const NodeSnapshot = null;
        var best_order: u64 = 0;
        for (self.nodes) |*n| {
            if (!n.is_overlay or !n.is_visible) continue;
            const order = n.overlay_order orelse continue;
            if (best != null and order <= best_order) continue;
            if (!pointInside(n.visual_bounds, pos)) continue;
            if (n.clip_bounds) |clip| {
                if (!widget.pointInClipAxes(clip, n.clip_axes, pos)) continue;
            }
            best = n;
            best_order = order;
        }
        return best;
    }

    /// Write JSON description of snapshot nodes.
    pub fn writeJson(self: *const FrameSnapshot, writer: *std.Io.Writer) !void {
        try writer.print("{{\"frame\":{d},\"nodes\":[", .{self.frame_number});
        for (self.nodes, 0..) |*node, i| {
            if (i != 0) try writer.writeByte(',');
            try writer.print(
                "{{\"index\":{d},\"slot\":{d},\"gen\":{d},\"role\":\"{s}\"," ++
                    "\"vis_rect\":{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}}",
                .{
                    node.index,
                    node.id.slot,
                    node.id.generation,
                    @tagName(node.semantics.role),
                    node.visual_bounds.x,
                    node.visual_bounds.y,
                    node.visual_bounds.w,
                    node.visual_bounds.h,
                },
            );
            if (node.semantics.label) |lbl| {
                try writer.writeAll(",\"label\":");
                try std.json.Stringify.encodeJsonString(lbl, .{}, writer);
            }
            if (node.is_overlay) {
                try writer.print(",\"overlay_order\":{d}", .{node.overlay_order orelse 0});
            }
            if (node.clip_bounds) |clip| {
                try writer.print(
                    ",\"clip_rect\":{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}}," ++
                        // The node object opened above is still open: the
                        // fields below continue the same node, so nothing
                        // closes it here.
                        "\"clip_x\":{},\"clip_y\":{}",
                    .{
                        clip.x,
                        clip.y,
                        clip.w,
                        clip.h,
                        node.clip_axes.x,
                        node.clip_axes.y,
                    },
                );
            }
            try writer.print(
                ",\"visible\":{},\"enabled\":{},\"focused\":{},\"focus_scope\":{}," ++
                    "\"captured\":{},\"can_focus\":{}",
                .{
                    node.is_visible,
                    node.is_enabled,
                    node.focus.is_focused,
                    node.focus.contains_focus,
                    node.capture.is_captured,
                    node.focus.can_focus,
                },
            );
            if (node.source) |source| {
                try writer.writeAll(",\"source\":");
                try std.json.Stringify.encodeJsonString(source.file, .{}, writer);
                try writer.print(":{d}", .{source.line});
            }
            try writer.writeByte('}');
        }
        try writer.writeAll("]}");
    }
};

/// Write a JSON-escaped string field with the given key.
fn writeJsonStringField(writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try writer.print(",\"{s}\":", .{key});
    try std.json.Stringify.encodeJsonString(value, .{}, writer);
}

/// Capture an immutable inspection snapshot of a laid-out widget tree.
pub fn captureFrame(gpa: std.mem.Allocator, options: CaptureOptions) !FrameSnapshot {
    const zone = tracy.Zone.begin(.{ .name = "inspection.captureFrame", .src = @src() });
    defer zone.end();

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const tree = options.tree;
    const node_count = tree.nodes.items.len;
    const nodes = try alloc.alloc(NodeSnapshot, node_count);

    // Build dense FrameNodeId to snapshot index map.
    var id_to_index: std.AutoHashMapUnmanaged(FrameNodeId, u32) = .empty;
    try id_to_index.ensureTotalCapacity(alloc, @intCast(node_count));
    for (tree.nodes.items, 0..) |*n, idx| {
        id_to_index.putAssumeCapacity(n.id, @intCast(idx));
    }

    // Count total child references to allocate flat children index storage.
    var total_children: usize = 0;
    for (tree.nodes.items) |*n| {
        total_children += n.children.items.len;
    }
    const children_indices = try alloc.alloc(u32, total_children);
    var children_cursor: u32 = 0;

    for (tree.nodes.items, 0..) |*n, idx| {
        const u_idx: u32 = @intCast(idx);

        // Compute stable ID: use explicit widget_id if present; generate otherwise.
        const stable_id = if (n.widget_id) |wid|
            wid
        else
            generateStableId(n, parentWidgetId(tree, n.parent), childPosition(tree, n));

        const handle: InspectHandle = .{
            .id = stable_id,
            .generation = stable_id.generation,
            .frame_number = options.frame_number,
        };

        const parent_idx = if (n.parent != n.id and n.parent != .root)
            id_to_index.get(n.parent)
        else
            null;

        const start_child = children_cursor;
        for (n.children.items) |ch| {
            if (id_to_index.get(ch)) |ch_idx| {
                children_indices[children_cursor] = ch_idx;
                children_cursor += 1;
            }
        }
        const count_child = children_cursor - start_child;

        // Placement is IN the tree: a placed node's absolute, input and
        // painted boxes are one geometry, so inspection reports what is drawn
        // without re-deriving an offset.
        const layout_rect = widget.absoluteRect(tree, n.id);
        const visual_rect = widget.visualBorderRect(tree, n.id);

        // The band is IN the tree: a placed node carries the record, the
        // resolved base and the (priority, registration) key BY VALUE, so
        // this snapshot answers from the node alone — no bank lookup, and no
        // bank that the next frame recycles can contradict it. A tree the
        // previous frame published therefore still reports ITS popups.
        //
        // The DORMANT marker is by value for the same reason: a registered
        // record that resolved to nothing is flagged on the node itself, so
        // this snapshot reports it as overlay content with no order, and as
        // neither painted nor pressable, exactly as the frame behaves. An
        // explicitly supplied frame stays the fallback for a tree nothing
        // ever staged, which is the only case a node cannot answer alone.
        var is_overlay = n.placement_paint != null or n.overlay_dormant;
        const overlay_order: ?u64 = if (n.placement_paint) |placed| placed.order else null;
        if (!is_overlay) {
            if (options.overlay_frame) |of| {
                is_overlay = of.isOverlayNode(tree, n.id);
            }
        }

        // Input routing walks the whole chain and rejects a hidden or
        // display-none element on the way, so the snapshot folds both into
        // one clip constraint and one visibility answer. A placed node's clip
        // is part of that chain, so the same rule answers for overlays.
        const input_clip = inputChainClip(tree, n.id);

        const is_vis = isInspectableVisible(tree, n);
        const is_en = input.isEnabled(tree, n.id);

        const focus_manager = options.focus_manager;
        const focused_id = if (focus_manager) |fm| fm.current else null;
        const is_foc = if (focused_id) |id| id.eql(stable_id) else false;
        const contains_foc = if (focus_manager) |fm|
            if (focused_id) |id| fm.contains(tree, n.id, id) else false
        else
            false;
        const can_foc = focus.defaultDescribe(tree, n) != null;
        const capture_slots = captureSlotCount(focus_manager, stable_id);

        const semantics = extractSemantics(alloc, n) catch Semantics{ .role = .custom };

        const style_summary: StyleSummary = .{
            .display = n.style.display,
            .visibility = n.style.visibility,
            .position = n.style.position,
            .direction = n.style.direction,
            .justify = n.style.justify,
            .@"align" = n.style.@"align",
            .box_sizing = n.style.box_sizing,
            .overflow = n.style.overflow,
            .grow = n.style.grow,
            .shrink = n.style.shrink,
            .gap = n.style.gap.resolve(null) orelse 0,
            .fill = n.paint.fill,
            .border_color = n.paint.border_color,
            .radius = n.paint.radius,
            .opacity = n.paint.opacity,
            .layer = n.paint.layer,
            .clips_content = n.contentClipAxes().any(),
            .transparent = n.paint.transparent,
            .has_shadow = n.paint.shadows.len != 0,
            .texture = n.paint.texture,
            .text_size = if (n.text_request) |request| request.fontSize() else 0,
        };

        const source_loc: ?SourceLocation = if (options.source_map) |sm|
            if (sm.get(stable_id)) |loc|
                copySourceLocation(alloc, loc) catch null
            else
                null
        else
            null;

        nodes[idx] = .{
            .index = u_idx,
            .frame_node_id = n.id,
            .id = stable_id,
            .handle = handle,
            .parent_index = parent_idx,
            .children_start = start_child,
            .children_count = count_child,
            // One geometry: layout, input and visual bounds of a placed node
            // are the same boxes, and its clip is the tree's own chain.
            .layout_bounds = layout_rect,
            .input_bounds = visual_rect,
            .visual_bounds = visual_rect,
            .clip_bounds = if (input_clip) |clip| clip.rect else null,
            .clip_axes = if (input_clip) |clip| clip.axes else .{},
            .is_visible = is_vis,
            .layout_hidden = n.layout_hidden,
            .is_enabled = is_en,
            .focus = .{
                .is_focused = is_foc,
                .contains_focus = contains_foc,
                .can_focus = can_foc,
                .tab_index = n.interaction.tab_index,
                .tab_group = n.interaction.tab_group,
            },
            .capture = .{
                .is_captured = capture_slots != 0,
                .pointer_count = capture_slots,
            },
            .semantics = semantics,
            .style = style_summary,
            .source = source_loc,
            .overlay_order = overlay_order,
            .is_overlay = is_overlay,
        };
    }

    return .{
        .frame_number = options.frame_number,
        .timestamp_ns = options.timestamp_ns,
        .viewport = options.viewport,
        .nodes = nodes,
        .children_indices = children_indices,
        .arena = arena,
    };
}

/// Pick against a live tree and report its unranked walk beside routing.
pub fn pickAt(
    tree: *const widget.WidgetTree,
    overlay_frame: ?*const overlay.Frame,
    pos: [2]f32,
) PickResult {
    const tree_node = input.hitTest(tree, pos);
    const placed = if (overlay_frame) |of| of.hitTest(tree, pos) else null;
    return .{
        .node = placed orelse tree_node,
        .tree_node = tree_node,
    };
}

/// Generate a deterministic stable ID for a node lacking an explicit widget_id.
pub fn generateStableId(
    node: *const widget.WidgetNode,
    parent_id: ?WidgetId,
    sibling_index: u32,
) WidgetId {
    if (node.widget_id) |wid| return wid;

    var h: u64 = 0xcbf29ce484222325;
    if (parent_id) |pid| {
        h = (h ^ pid.owner) *% 0x100000001b3;
        h = (h ^ pid.slot) *% 0x100000001b3;
        h = (h ^ pid.generation) *% 0x100000001b3;
    }
    h = (h ^ sibling_index) *% 0x100000001b3;
    h = (h ^ @as(u64, @intFromEnum(std.meta.activeTag(node.kind)))) *% 0x100000001b3;

    var slot: u32 = @truncate(h);
    if (slot == 0) slot = 1;
    const generation: u32 = (@as(u32, @truncate(h >> 32))) | 1;

    return .{
        .owner = inspection_owner,
        .slot = slot,
        .generation = generation,
    };
}

// ── Bounded Performance Collectors ─────────────────────────

/// Metrics recorded for one completed frame.
///
/// `cpu_frame_ns` is the measured span of the whole host frame callback. The
/// finer `cpu_*` fields stay zero unless the host timed that stage, so an
/// absent stage reads as "not measured" and never as zero cost.
pub const FrameRecord = struct {
    frame_number: u64,
    timestamp_ns: u64,
    cpu_frame_ns: u64 = 0,
    cpu_app_layout_ns: u64 = 0,
    cpu_scene_ns: u64 = 0,
    cpu_record_ns: u64 = 0,
    cpu_submit_present_ns: u64 = 0,
    cpu_compute_ns: u64 = 0,
    gpu_execute_ns: ?u64 = null,
    counters: ?perf_counters.Snapshot = null,
    slop_ns: u64 = 0,

    /// `timestamp_ns` is the instant the frame committed. The three collectors
    /// are merged chronologically, and a frame's own ordering key has to be in
    /// the record for that merge to be checkable from the output rather than
    /// only from the collector order.
    pub fn writeJson(self: *const FrameRecord, writer: *std.Io.Writer) !void {
        try writer.print(
            "{{\"type\":\"frame\",\"frame_id\":{d},\"timestamp_ns\":{d}," ++
                "\"cpu_frame_ns\":{d},\"cpu_app_layout_ns\":{d}," ++
                "\"cpu_scene_ns\":{d},\"cpu_record_ns\":{d},\"cpu_submit_present_ns\":{d}," ++
                "\"cpu_compute_ns\":{d}",
            .{
                self.frame_number,
                self.timestamp_ns,
                self.cpu_frame_ns,
                self.cpu_app_layout_ns,
                self.cpu_scene_ns,
                self.cpu_record_ns,
                self.cpu_submit_present_ns,
                self.cpu_compute_ns,
            },
        );
        if (self.gpu_execute_ns) |gpu| {
            try writer.print(",\"gpu_execute_ns\":{d}", .{gpu});
        }
        if (self.counters) |*c| {
            try writer.writeAll(",\"mechanisms\":");
            try c.writeJson(writer);
        }
        try writer.print(",\"slop_ns\":{d}}}", .{self.slop_ns});
    }
};

/// Metrics recorded for one asynchronous task.
pub const TaskRecord = struct {
    task_id: u64,
    priority: task.Priority,
    queued_ns: u64,
    start_ns: u64,
    end_ns: u64,
    duration_ns: u64,
    name: [32]u8 = .{0} ** 32,
    name_len: u8 = 0,
    window_id: ?u64 = null,

    pub fn setName(self: *TaskRecord, name_str: []const u8) void {
        const copy_len = @min(name_str.len, self.name.len);
        @memcpy(self.name[0..copy_len], name_str[0..copy_len]);
        self.name_len = @intCast(copy_len);
    }

    pub fn getName(self: *const TaskRecord) []const u8 {
        return self.name[0..self.name_len];
    }

    /// The instant this record belongs at in a chronological merge. A task
    /// that has only been QUEUED has no end: `end_ns` is 0 for it, and using
    /// that would place a task queued at the very end of a run at the very
    /// beginning of the log. A record that finished orders by when it ended.
    pub fn orderNs(self: *const TaskRecord) u64 {
        return if (self.end_ns == 0) self.queued_ns else self.end_ns;
    }

    pub fn writeJson(self: *const TaskRecord, writer: *std.Io.Writer) !void {
        try writer.print(
            "{{\"type\":\"task\",\"task_id\":{d},\"priority\":\"{s}\"," ++
                "\"queued_ns\":{d},\"start_ns\":{d},\"end_ns\":{d},\"duration_ns\":{d}",
            .{
                self.task_id,
                @tagName(self.priority),
                self.queued_ns,
                self.start_ns,
                self.end_ns,
                self.duration_ns,
            },
        );
        if (self.name_len > 0) {
            try writeJsonStringField(writer, "name", self.getName());
        }
        if (self.window_id) |w| {
            try writer.print(",\"window\":{d}", .{w});
        }
        try writer.writeByte('}');
    }
};

/// Metrics recorded for one action dispatch.
pub const ActionRecord = struct {
    name: [48]u8 = .{0} ** 48,
    name_len: u8 = 0,
    target: ?WidgetId = null,
    start_ns: u64,
    end_ns: u64,
    duration_ns: u64,
    result: action.Result,
    dispatch_depth: u32 = 0,

    pub fn setName(self: *ActionRecord, name_str: []const u8) void {
        const copy_len = @min(name_str.len, self.name.len);
        @memcpy(self.name[0..copy_len], name_str[0..copy_len]);
        self.name_len = @intCast(copy_len);
    }

    pub fn getName(self: *const ActionRecord) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn writeJson(self: *const ActionRecord, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"type\":\"action\",\"name\":");
        try std.json.Stringify.encodeJsonString(self.getName(), .{}, writer);
        try writer.print(
            ",\"start_ns\":{d},\"end_ns\":{d},\"duration_ns\":{d},\"result\":\"{s}\",\"depth\":{d}",
            .{
                self.start_ns,
                self.end_ns,
                self.duration_ns,
                @tagName(self.result),
                self.dispatch_depth,
            },
        );
        if (self.target) |tgt| {
            try writer.print(",\"target\":{{\"owner\":{d},\"slot\":{d},\"generation\":{d}}}", .{
                tgt.owner, tgt.slot, tgt.generation,
            });
        }
        try writer.writeByte('}');
    }
};

/// Bounded cursor-based circular collector for performance records.
/// A disabled collector holds no buffer and allocates nothing; enabling it
/// allocates the reserved capacity exactly once. Recording never allocates.
pub fn BoundedCollector(comptime T: type) type {
    return struct {
        buffer: []T,
        cursor: usize = 0,
        count: usize = 0,
        total_recorded: u64 = 0,
        overruns: u64 = 0,
        enabled: bool = true,
        allocator: ?std.mem.Allocator = null,
        /// Capacity this collector may take when it is enabled.
        reserved: usize = 0,

        const Self = @This();

        pub const empty: Self = .{
            .buffer = &.{},
            .enabled = false,
        };

        pub fn init(allocator: std.mem.Allocator, cap: usize) !Self {
            if (cap == 0) return Self.empty;
            const buffer = try allocator.alloc(T, cap);
            return .{
                .buffer = buffer,
                .enabled = true,
                .allocator = allocator,
                .reserved = cap,
            };
        }

        /// Reserve capacity without allocating. The buffer is created by
        /// `setEnabled(true)`, so a disabled collector costs no memory.
        pub fn initLazy(allocator: std.mem.Allocator, cap: usize) Self {
            if (cap == 0) return Self.empty;
            return .{
                .buffer = &.{},
                .enabled = false,
                .allocator = allocator,
                .reserved = cap,
            };
        }

        pub fn initBuffer(buffer: []T) Self {
            return .{
                .buffer = buffer,
                .enabled = true,
                .allocator = null,
                .reserved = buffer.len,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.allocator) |alloc| {
                if (self.buffer.len != 0) alloc.free(self.buffer);
            }
            self.* = Self.empty;
        }

        /// Enable or disable recording. Enabling allocates the reserved
        /// capacity once; disabling and re-enabling never allocates twice.
        pub fn setEnabled(self: *Self, enabled: bool) error{OutOfMemory}!void {
            if (enabled and self.buffer.len == 0) {
                if (self.reserved == 0) {
                    self.enabled = false;
                    return;
                }
                const gpa = self.allocator orelse {
                    self.enabled = false;
                    return;
                };
                self.buffer = try gpa.alloc(T, self.reserved);
            }
            self.enabled = enabled and self.buffer.len != 0;
        }

        pub fn reservedCapacity(self: *const Self) usize {
            return self.reserved;
        }

        pub fn reset(self: *Self) void {
            self.cursor = 0;
            self.count = 0;
            self.total_recorded = 0;
            self.overruns = 0;
        }

        /// Record one item into the ring buffer.
        /// Zero allocations; updates overrun counter when capacity is exceeded.
        pub fn record(self: *Self, item: T) void {
            if (!self.enabled or self.buffer.len == 0) return;
            self.buffer[self.cursor] = item;
            self.cursor = (self.cursor + 1) % self.buffer.len;
            if (self.count < self.buffer.len) {
                self.count += 1;
            } else {
                self.overruns += 1;
            }
            self.total_recorded += 1;
        }

        /// Capacity available for retained records right now.
        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
        }

        /// Access chronological entry: 0 is oldest retained, count - 1 is newest.
        pub fn get(self: *const Self, chronological_index: usize) ?T {
            if (chronological_index >= self.count or self.buffer.len == 0) return null;
            const start = if (self.count < self.buffer.len)
                0
            else
                self.cursor;
            const idx = (start + chronological_index) % self.buffer.len;
            return self.buffer[idx];
        }

        /// Mutable access to one retained record, 0 is oldest retained. Null
        /// when the index is out of range. The pointer stays valid until the
        /// next `record` writes or wraps that slot, which is what lets a
        /// measurement join the record a frame already produced instead of
        /// adding a second record for the same frame.
        pub fn at(self: *Self, chronological_index: usize) ?*T {
            if (chronological_index >= self.count or self.buffer.len == 0) return null;
            const start = if (self.count < self.buffer.len)
                0
            else
                self.cursor;
            const idx = (start + chronological_index) % self.buffer.len;
            return &self.buffer[idx];
        }

        /// Return latest recorded entry.
        pub fn latest(self: *const Self) ?T {
            if (self.count == 0 or self.buffer.len == 0) return null;
            const idx = if (self.cursor == 0) self.buffer.len - 1 else self.cursor - 1;
            return self.buffer[idx];
        }

        /// Copy the retained records into caller storage, oldest first.
        /// Returns how many were written: `out.len` or the retained count,
        /// whichever is smaller. Never allocates, so a benchmark can take a
        /// bounded snapshot on the hot path.
        pub fn copyChronological(self: *const Self, out: []T) usize {
            const wanted = @min(out.len, self.count);
            var i: usize = 0;
            while (i < wanted) : (i += 1) {
                out[i] = self.get(i).?;
            }
            return wanted;
        }

        /// Stream retained entries in chronological order to a JSONL writer.
        pub fn writeJsonl(self: *const Self, writer: *std.Io.Writer) !void {
            var i: usize = 0;
            while (i < self.count) : (i += 1) {
                if (self.get(i)) |item| {
                    try item.writeJson(writer);
                    try writer.writeByte('\n');
                }
            }
        }
    };
}

/// Comptime zero-cost sink for collector call sites.
pub fn CollectorSink(comptime T: type, comptime enabled: bool) type {
    return if (enabled) struct {
        collector: ?*BoundedCollector(T),

        const Self = @This();

        pub fn init(collector: ?*BoundedCollector(T)) Self {
            return .{ .collector = collector };
        }

        pub fn record(self: *const Self, item: T) void {
            if (self.collector) |c| c.record(item);
        }
    } else struct {
        const Self = @This();

        pub fn init(_: ?*anyopaque) Self {
            return .{};
        }

        pub fn record(_: *const Self, _: T) void {}
    };
}

// ── Internal Helpers ─────────────────────────────

fn pointInside(r: widget.Rect, p: [2]f32) bool {
    return p[0] >= r.x and p[0] < (r.x + r.w) and
        p[1] >= r.y and p[1] < (r.y + r.h);
}

fn parentWidgetId(tree: *const widget.WidgetTree, parent_fnid: FrameNodeId) ?WidgetId {
    if (parent_fnid == .root) return null;
    for (tree.nodes.items) |*node| {
        if (node.id == parent_fnid) return node.widget_id;
    }
    return null;
}

fn childPosition(tree: *const widget.WidgetTree, child: *const widget.WidgetNode) u32 {
    if (child.parent == child.id or child.parent == .root) return 0;
    for (tree.nodes.items) |*parent| {
        if (parent.id == child.parent) {
            for (parent.children.items, 0..) |ch, idx| {
                if (ch == child.id) return @intCast(idx);
            }
            break;
        }
    }
    return 0;
}

/// A resolved clip constraint: the rectangle and the axes it constrains.
const ClipBounds = struct {
    rect: widget.Rect,
    axes: widget.ClipAxes,
};

/// Count live focus capture slots holding this widget.
fn captureSlotCount(fm: ?*const focus.Manager, id: WidgetId) u8 {
    const manager = fm orelse return 0;
    var count: u8 = 0;
    for (manager.captures) |entry| {
        const capture = entry orelse continue;
        if (capture.target.eql(id)) count += 1;
    }
    return count;
}

/// Merge one clipping element into the running constraint. A disabled axis
/// of `axes` leaves that side of `rect` untouched, so per-axis clipping stays
/// per-axis instead of collapsing to the first box.
fn clipRectInto(acc: ?ClipBounds, rect: widget.Rect, axes: widget.ClipAxes) ?ClipBounds {
    if (!axes.any()) return acc;
    const current = acc orelse return .{ .rect = rect, .axes = axes };
    var out = current;
    if (axes.x) {
        const start = @max(current.rect.x, rect.x);
        const end = @min(current.rect.x + current.rect.w, rect.x + rect.w);
        out.rect.x = start;
        out.rect.w = @max(0, end - start);
    }
    if (axes.y) {
        const start = @max(current.rect.y, rect.y);
        const end = @min(current.rect.y + current.rect.h, rect.y + rect.h);
        out.rect.y = start;
        out.rect.h = @max(0, end - start);
    }
    out.axes.x = current.axes.x or axes.x;
    out.axes.y = current.axes.y or axes.y;
    return out;
}

/// Every clipping element from `id` up to the window root, including any clip
/// overlay placement imposed. This is exactly the set the engine's own hit
/// test walks and the painter folds into its clip stack, so a snapshot pick
/// agrees with routing instead of approximating it.
fn clipRectToBounds(clip: widget.ClipRect) ClipBounds {
    return .{
        .rect = .{ .x = clip.x, .y = clip.y, .w = @max(0, clip.w), .h = @max(0, clip.h) },
        .axes = .{ .x = clip.clipsX(), .y = clip.clipsY() },
    };
}

fn inputChainClip(tree: *const widget.WidgetTree, id: FrameNodeId) ?ClipBounds {
    var acc: ?ClipBounds = null;
    var current = id;
    var remaining = tree.nodes.items.len + 1;
    while (current != .root and remaining > 0) : (remaining -= 1) {
        const node = tree.nodeConst(current) orelse break;
        acc = clipRectInto(acc, widget.visualBorderRect(tree, current), node.contentClipAxes());
        if (node.placement_clip) |imposed| {
            const bounds = clipRectToBounds(imposed);
            acc = clipRectInto(acc, bounds.rect, bounds.axes);
        }
        current = node.parent;
    }
    return acc;
}

/// Paint, input and semantic visibility. `input.hitTest` rejects a
/// display-none or hidden element anywhere on the chain, so this walk does
/// the same instead of trusting the prepared flag alone. A DORMANT overlay
/// subtree is rejected for the same reason the painter and the hit test
/// reject it: a registered record that no anchor resolved is not on screen
/// and cannot be pressed, and a snapshot that called it visible would put
/// the inspector against the engine on the first question anyone asks it.
fn isInspectableVisible(tree: *const widget.WidgetTree, node: *const widget.WidgetNode) bool {
    if (node.paint_hidden) return false;
    if (node.overlay_dormant) return false;
    var current = node.id;
    var remaining = tree.nodes.items.len + 1;
    while (current != .root and remaining > 0) : (remaining -= 1) {
        const entry = tree.nodeConst(current) orelse break;
        if (entry.style.display == .none or entry.style.visibility == .hidden) return false;
        current = entry.parent;
    }
    return true;
}

fn extractSemantics(alloc: std.mem.Allocator, n: *const widget.WidgetNode) !Semantics {
    return switch (n.kind) {
        .column => .{ .role = .column },
        .row => .{ .role = .row },
        .label => |l| .{
            .role = .label,
            .label = try alloc.dupe(u8, l.text),
        },
        .button => |b| .{
            .role = .button,
            .label = try alloc.dupe(u8, b.label),
            .accessible_label = if (b.accessible_label) |al| try alloc.dupe(u8, al) else null,
        },
        .slider => |s| .{
            .role = .slider,
            .label = try alloc.dupe(u8, s.label),
            .numeric_value = s.value.*,
            .numeric_min = s.min,
            .numeric_max = s.max,
        },
        .checkbox => |cb| .{
            .role = .checkbox,
            .label = try alloc.dupe(u8, cb.label),
            .is_checked = cb.value.*,
        },
        .switch_control => |sw| .{
            .role = .switch_control,
            .label = try alloc.dupe(u8, sw.label),
            .is_checked = sw.value.*,
        },
        .radio => |r| .{
            .role = .radio,
            .label = try alloc.dupe(u8, r.label),
            .is_selected = if (r.selected.*) |sel| sel == r.option else null,
        },
        .progress => |p| .{
            .role = .progress,
            .label = try alloc.dupe(u8, p.label),
            .numeric_value = p.value,
            .numeric_min = p.min,
            .numeric_max = p.max,
        },
        .separator => .{ .role = .separator },
        .spacer => .{ .role = .spacer },
        .element => .{ .role = .element },
    };
}

fn copySourceLocation(alloc: std.mem.Allocator, loc: SourceLocation) !SourceLocation {
    return .{
        .file = try alloc.dupe(u8, loc.file),
        .line = loc.line,
        .column = loc.column,
        .component_name = try alloc.dupe(u8, loc.component_name),
    };
}
