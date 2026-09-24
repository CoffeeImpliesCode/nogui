const std = @import("std");
const FrameNodeId = @import("../id.zig").FrameNodeId;
const layout_context = @import("context.zig");
const sizing = @import("sizing.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");
const overflow = @import("overflow.zig");
const text_api = @import("../text.zig");

pub const MeasureSource = layout_context.MeasureSource;
pub const Options = struct {
    allocator: std.mem.Allocator,
    available: widget.Size,
    measure: ?MeasureSource,
    context: ?*layout_context.LayoutContext = null,
    measurement_cache: ?*MeasurementCache = null,
};
const Error = sizing.Error;
const TrackAxis = enum { columns, rows };
const AutoRepeatStrategy = enum {
    max_repetitions_that_fit,
    min_repetitions_that_overflow,
};

const DeferredPercentageStyle = struct {
    width: bool = false,
    height: bool = false,
};

const AvailableSpaceKey = struct {
    tag: enum { definite, min_content, max_content },
    value: f32 = 0,
};

const OptionalDimensionKey = struct {
    present: bool,
    value: f32 = 0,
};

const MeasureCacheKey = struct {
    node_index: usize,
    known_width: OptionalDimensionKey,
    known_height: OptionalDimensionKey,
    known_border_width: OptionalDimensionKey,
    known_border_height: OptionalDimensionKey,
    available_width: AvailableSpaceKey,
    available_height: AvailableSpaceKey,
    request_available_width: f32,
    request_available_height: f32,
    percentage_width: OptionalDimensionKey,
    percentage_height: OptionalDimensionKey,
    width_mode: layout_context.MeasureMode,
    height_mode: layout_context.MeasureMode,
    sizing_mode: layout_context.SizingMode,
    parent_display: ?style.Display,
    allow_auto_track_stretch: bool,
    deferred_percentage_style: DeferredPercentageStyle,
    /// The resolved text request identity this measurement was taken under. A
    /// node's record is frame-owned and immutable, so its address plus the
    /// writing mode identify the request exactly; a tree rebuilt into a
    /// recycled arena produces a different address, which is the point.
    text_request: ?*const text_api.NodeText,
    writing_mode: text_api.WritingMode,
};

const MeasureCacheEntry = union(enum) {
    empty,
    occupied: struct {
        key: MeasureCacheKey,
        value: Natural,
    },
};

const measurement_cache_entries_per_node: usize = 9;

fn mixMeasureCacheHash(hash: u64, value: u64) u64 {
    return (hash ^ value) *% 0x00000100000001B3;
}

fn measureCacheFloatHash(value: f32) u64 {
    return @as(u32, @bitCast(value));
}

fn measureCacheHash(key: MeasureCacheKey) u64 {
    var hash: u64 = 0xCBF29CE484222325;
    hash = mixMeasureCacheHash(hash, key.node_index);
    hash = mixMeasureCacheHash(hash, @intFromBool(key.known_width.present));
    hash = mixMeasureCacheHash(hash, measureCacheFloatHash(key.known_width.value));
    hash = mixMeasureCacheHash(hash, @intFromBool(key.known_height.present));
    hash = mixMeasureCacheHash(hash, measureCacheFloatHash(key.known_height.value));
    hash = mixMeasureCacheHash(hash, @intFromBool(key.known_border_width.present));
    hash = mixMeasureCacheHash(hash, measureCacheFloatHash(key.known_border_width.value));
    hash = mixMeasureCacheHash(hash, @intFromBool(key.known_border_height.present));
    hash = mixMeasureCacheHash(hash, measureCacheFloatHash(key.known_border_height.value));
    hash = mixMeasureCacheHash(hash, @intFromEnum(key.available_width.tag));
    hash = mixMeasureCacheHash(hash, measureCacheFloatHash(key.available_width.value));
    hash = mixMeasureCacheHash(hash, @intFromEnum(key.available_height.tag));
    hash = mixMeasureCacheHash(hash, measureCacheFloatHash(key.available_height.value));
    hash = mixMeasureCacheHash(hash, measureCacheFloatHash(key.request_available_width));
    hash = mixMeasureCacheHash(hash, measureCacheFloatHash(key.request_available_height));
    hash = mixMeasureCacheHash(hash, @intFromBool(key.percentage_width.present));
    hash = mixMeasureCacheHash(hash, measureCacheFloatHash(key.percentage_width.value));
    hash = mixMeasureCacheHash(hash, @intFromBool(key.percentage_height.present));
    hash = mixMeasureCacheHash(hash, measureCacheFloatHash(key.percentage_height.value));
    hash = mixMeasureCacheHash(hash, @intFromEnum(key.width_mode));
    hash = mixMeasureCacheHash(hash, @intFromEnum(key.height_mode));
    hash = mixMeasureCacheHash(hash, @intFromEnum(key.sizing_mode));
    hash = mixMeasureCacheHash(hash, if (key.parent_display) |value| @intFromEnum(value) + 1 else 0);
    hash = mixMeasureCacheHash(hash, @intFromBool(key.allow_auto_track_stretch));
    hash = mixMeasureCacheHash(hash, @intFromBool(key.deferred_percentage_style.width));
    hash = mixMeasureCacheHash(hash, @intFromBool(key.deferred_percentage_style.height));
    hash = mixMeasureCacheHash(hash, @intFromPtr(key.text_request));
    return mixMeasureCacheHash(hash, @intFromEnum(key.writing_mode));
}

const MeasurementCache = struct {
    entries: []MeasureCacheEntry,
    next_replacement: *usize,

    fn entryCount(node_count: usize) Error!usize {
        return std.math.mul(
            usize,
            node_count,
            measurement_cache_entries_per_node,
        ) catch error.InvalidStyle;
    }

    fn init(
        allocator: std.mem.Allocator,
        node_count: usize,
        next_replacement: *usize,
    ) Error!MeasurementCache {
        const entries = try allocator.alloc(
            MeasureCacheEntry,
            try entryCount(node_count),
        );
        for (entries) |*entry| entry.* = .empty;
        next_replacement.* = 0;
        return .{
            .entries = entries,
            .next_replacement = next_replacement,
        };
    }

    fn shared(
        context: *layout_context.LayoutContext,
        node_count: usize,
    ) Error!MeasurementCache {
        const entry_count = try entryCount(node_count);
        const entries = try context.gridCacheStorage(
            MeasureCacheEntry,
            entry_count,
        );
        if (context.grid_cache_initialized_items < entry_count) {
            for (entries[context.grid_cache_initialized_items..]) |*entry| {
                entry.* = .empty;
            }
            context.grid_cache_initialized_items = entry_count;
        }
        context.grid_cache_next_replacement %= entry_count;
        return .{
            .entries = entries,
            .next_replacement = &context.grid_cache_next_replacement,
        };
    }

    fn deinit(self: *MeasurementCache, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.* = undefined;
    }

    fn lookup(self: *const MeasurementCache, key: MeasureCacheKey) ?Natural {
        if (self.entries.len == 0) return null;
        var index: usize = @intCast(measureCacheHash(key) % self.entries.len);
        var probes: usize = 0;
        while (probes < self.entries.len) : (probes += 1) {
            switch (self.entries[index]) {
                .empty => return null,
                .occupied => |entry| {
                    if (measureCacheKeyEqual(entry.key, key)) return entry.value;
                },
            }
            index += 1;
            if (index == self.entries.len) index = 0;
        }
        return null;
    }

    fn insert(self: *MeasurementCache, key: MeasureCacheKey, value: Natural) void {
        if (self.entries.len == 0) return;
        const first: usize = @intCast(measureCacheHash(key) % self.entries.len);
        var index = first;
        var probes: usize = 0;
        while (probes < self.entries.len) : (probes += 1) {
            const entry = &self.entries[index];
            switch (entry.*) {
                .empty => {
                    entry.* = .{ .occupied = .{ .key = key, .value = value } };
                    return;
                },
                .occupied => |occupied| {
                    if (measureCacheKeyEqual(occupied.key, key)) {
                        entry.* = .{ .occupied = .{ .key = key, .value = value } };
                        return;
                    }
                },
            }
            index += 1;
            if (index == self.entries.len) index = 0;
        }
        self.entries[self.next_replacement.*] = .{
            .occupied = .{ .key = key, .value = value },
        };
        self.next_replacement.* = (self.next_replacement.* + 1) % self.entries.len;
    }
};

const Edges = struct {
    border: style.Sides,
    padding: style.Sides,
    raw_padding: style.Sides,
    box_horizontal: f32,
    box_vertical: f32,
    horizontal: f32,
    vertical: f32,
};

const Margins = struct {
    value: style.Sides,
    top_auto: bool,
    right_auto: bool,
    bottom_auto: bool,
    left_auto: bool,
};

const Natural = struct {
    content: widget.Size,
    border: widget.Size,
    minimum: widget.Size = .{ .width = 0, .height = 0 },
    min_content: widget.Size = .{ .width = 0, .height = 0 },
    max_content: widget.Size = .{ .width = 0, .height = 0 },
};

const Track = struct {
    spec: style.GridTrack,
    size: f32,
    // This is the current growth limit. A null value represents infinity
    // until the intrinsic growth phases resolve it.
    intrinsic_growth_limit: ?f32 = null,
    infinitely_growable: bool = false,
    planned_increase: f32 = 0,
    item_incurred_increase: f32 = 0,
    can_stretch_in_alignment: bool = true,
    auto_fit: bool = false,
    collapsed: bool = false,
    implicit_auto: bool = false,
};

const AxisPlacement = struct {
    /// Resolved zero-based track indices. These are filled after implicit
    /// prepend tracks have been added.
    start: usize = 0,
    end: usize = 1,
    definite: bool = false,
    /// CSS line coordinates before the implicit-grid origin is shifted.
    logical_start: i128 = 0,
    logical_end: i128 = 1,
};

const FlowItem = struct {
    index: usize,
    row: AxisPlacement,
    column: AxisPlacement,
    natural: Natural,
    margins: Margins,
    overflow: style.OverflowAxes,
    automatic_min_width: bool = false,
    automatic_min_height: bool = false,
    baseline: ?f32 = null,
    baseline_margin_top: f32 = 0,
    baseline_shim: f32 = 0,
};

const OccupiedArea = struct {
    row_start: usize,
    row_end: usize,
    column_start: usize,
    column_end: usize,
};

const Occupancy = struct {
    areas: std.ArrayListUnmanaged(OccupiedArea) = .empty,

    fn deinit(self: *Occupancy, allocator: std.mem.Allocator) void {
        self.areas.deinit(allocator);
        self.* = undefined;
    }
};

const Distribution = struct {
    offset: f32,
    extra_gap: f32,
};

const ContentDistribution = struct {
    offset: f32,
    extra_gap: f32,
    stretch: f32,
};

pub fn layoutContainer(tree: *widget.WidgetTree, container_id: FrameNodeId, options: Options) Error!void {
    _ = try finite(options.available.width);
    _ = try finite(options.available.height);
    if (options.available.width < 0 or options.available.height < 0) return error.InvalidStyle;
    const index = tree.nodeIndex(container_id) orelse return error.InvalidStyle;
    if (container_id == .root) return error.InvalidStyle;

    try validateTreeInput(options.allocator, tree, index);
    var path: std.AutoHashMapUnmanaged(FrameNodeId, void) = .empty;
    defer path.deinit(options.allocator);
    try validateSubtree(options.allocator, tree, index, null, @max(64, tree.nodes.items.len * 4), &path);
    try markHidden(tree, index, false, @max(64, tree.nodes.items.len * 4));
    try layoutPreparedContainer(tree, container_id, options, null);
}

/// Lay out a validated, already-prepared subtree without repeating validation
/// or hidden-state classification.
pub fn layoutPreparedContainer(
    tree: *widget.WidgetTree,
    container_id: FrameNodeId,
    options: Options,
    forced_border: ?widget.Size,
) Error!void {
    const index = tree.nodeIndex(container_id) orelse return error.InvalidStyle;
    if (tree.nodes.items[index].layout_hidden) return;

    if (options.measurement_cache != null) {
        return layoutGridNode(
            tree,
            index,
            options.available,
            forced_border,
            options,
            @max(64, tree.nodes.items.len * 4),
        );
    }

    var local_next_replacement: usize = 0;
    var cache_storage = if (options.context) |context|
        try MeasurementCache.shared(context, tree.nodes.items.len)
    else
        try MeasurementCache.init(
            options.allocator,
            tree.nodes.items.len,
            &local_next_replacement,
        );
    defer if (options.context == null) cache_storage.deinit(options.allocator);

    var prepared_options = options;
    prepared_options.measurement_cache = &cache_storage;

    try layoutGridNode(
        tree,
        index,
        prepared_options.available,
        forced_border,
        prepared_options,
        @max(64, tree.nodes.items.len * 4),
    );
}

/// Measure a grid container's natural content and border size without placing it.
///
/// The caller owns the final used border rectangle and must invoke the layout
/// callback separately after it has resolved that rectangle.
pub fn measureNatural(
    tree: *widget.WidgetTree,
    node: *const widget.WidgetNode,
    request: layout_context.Request,
    context: *layout_context.LayoutContext,
) Error!layout_context.Measured {
    const index = tree.nodeIndex(node.id) orelse return error.InvalidStyle;
    if (&tree.nodes.items[index] != node) return error.InvalidStyle;
    try layout_context.validateNaturalRequest(tree, node, request);

    var cache = try MeasurementCache.shared(context, tree.nodes.items.len);
    const natural = try measureNode(
        tree,
        index,
        request,
        .{
            .allocator = context.allocator,
            .available = request.available,
            .measure = context.measure,
            .context = context,
            .measurement_cache = &cache,
        },
        @max(64, tree.nodes.items.len * 4),
        null,
        false,
        .{},
    );
    return .{
        .content = natural.content,
        .border = natural.border,
    };
}

fn validateTreeInput(
    allocator: std.mem.Allocator,
    tree: *const widget.WidgetTree,
    root_index: usize,
) Error!void {
    if (root_index >= tree.nodes.items.len) return error.InvalidStyle;
    var ids: std.AutoHashMapUnmanaged(FrameNodeId, void) = .empty;
    defer ids.deinit(allocator);

    for (tree.nodes.items) |node| {
        if (ids.contains(node.id)) return error.InvalidStyle;
        try ids.put(allocator, node.id, {});
        try validateStyle(allocator, node.style);
        try validateKind(node.kind);
        if (node.text_request) |request| _ = try finite(request.fontSize());
        if (node.text_max_width) |value| {
            _ = try finite(value);
            if (value < 0) return error.InvalidStyle;
        }
        if (node.parent != .root and tree.nodeIndex(node.parent) == null) {
            return error.InvalidStyle;
        }
    }

    for (tree.nodes.items) |node| {
        for (node.children.items, 0..) |child_id, child_offset| {
            if (child_id == .root) return error.InvalidStyle;
            const child = tree.nodeConst(child_id) orelse return error.InvalidStyle;
            if (child.parent != node.id) return error.InvalidStyle;
            for (node.children.items[0..child_offset]) |prior| {
                if (prior == child_id) return error.InvalidStyle;
            }
        }
        for (tree.nodes.items) |candidate| {
            if (candidate.parent != node.id) continue;
            var listed = false;
            for (node.children.items) |child_id| {
                if (child_id == candidate.id) {
                    listed = true;
                    break;
                }
            }
            if (!listed) return error.InvalidStyle;
        }
    }
}

fn validateSubtree(
    allocator: std.mem.Allocator,
    tree: *const widget.WidgetTree,
    index: usize,
    expected_parent: ?FrameNodeId,
    depth: usize,
    path: *std.AutoHashMapUnmanaged(FrameNodeId, void),
) Error!void {
    if (depth == 0 or index >= tree.nodes.items.len) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    if (expected_parent) |parent| {
        if (node.parent != parent) return error.InvalidStyle;
    }
    if (path.contains(node.id)) return error.InvalidStyle;
    try path.put(allocator, node.id, {});
    defer _ = path.remove(node.id);

    for (node.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        try validateSubtree(allocator, tree, child_index, node.id, depth - 1, path);
    }

    if (node.style.display == .none) return;
    if (node.children.items.len != 0 and node.style.display != .grid) return error.InvalidStyle;
}

fn validateKind(kind: widget.WidgetKind) Error!void {
    try layout_context.validateLeafGeometry(kind);
    switch (kind) {
        .column, .row, .element, .label, .button, .checkbox, .switch_control, .radio, .progress, .separator => {},
        .slider => |value| {
            _ = try finite(value.min);
            _ = try finite(value.max);
            if (value.min > value.max) return error.InvalidStyle;
        },
        .spacer => |value| {
            _ = try finiteNonNegative(value.size);
        },
    }
}

fn validateStyle(allocator: std.mem.Allocator, input: style.Style) Error!void {
    try validateTrackSlice(allocator, input.grid_template_columns);
    try validateTrackSlice(allocator, input.grid_template_rows);
    try validateTrackList(allocator, input.grid_auto_columns);
    try validateTrackList(allocator, input.grid_auto_rows);
    try validateLengthPercentage(input.gap, false);
    try validateLengthPercentage(input.column_gap, false);
    try validateLengthPercentage(input.row_gap, false);
    _ = try finiteNonNegative(input.grow);
    _ = try finiteNonNegative(input.shrink);
    try validateDimension(input.size.width);
    try validateDimension(input.size.height);
    try validateDimension(input.min_size.width);
    try validateDimension(input.min_size.height);
    try validateDimension(input.max_size.width);
    try validateDimension(input.max_size.height);
    try validateDimension(input.flex_basis);
    try validateInsets(input.inset);
    try validateInsets(input.margin_inset);
    try validateRect(input.border_inset, true);
    try validateRect(input.padding_inset, true);
    if (input.aspect_ratio) |value| {
        _ = try finite(value);
        if (value <= 0) return error.InvalidStyle;
    }
}

fn validateTrackDepth(track: style.GridTrack, depth: usize) Error!void {
    if (depth == 0) return error.InvalidStyle;
    switch (track) {
        .fixed => |value| {
            _ = try finiteNonNegative(value);
        },
        .percent => |value| {
            _ = try finiteNonNegative(value);
        },
        .fit_content => |value| {
            try validateLengthPercentage(value, false);
        },
        .auto, .min_content, .max_content => {},
        .fr => |value| {
            _ = try finiteNonNegative(value);
        },
        .minmax => |value| {
            try validateBreadth(value.min);
            try validateBreadth(value.max);
        },
        .repeat => |repeat| {
            if (repeat.tracks.len == 0) return error.InvalidStyle;
            switch (repeat.kind) {
                .count => |count| if (count == 0) return error.InvalidStyle,
                .auto_fill, .auto_fit => {},
            }
            for (repeat.tracks) |nested| {
                try validateTrackDepth(nested, depth - 1);
            }
        },
    }
}

fn validateTrackSlice(
    allocator: std.mem.Allocator,
    tracks: []const style.GridTrack,
) Error!void {
    const depth = try trackDepth(allocator, tracks);
    for (tracks) |track| try validateTrackDepth(track, depth);
}

fn validateTrackList(
    allocator: std.mem.Allocator,
    tracks: []const style.GridTrack,
) Error!void {
    if (tracks.len == 0) return error.InvalidStyle;
    try validateTrackSlice(allocator, tracks);
}

fn validateBreadth(breadth: style.GridTrackBreadth) Error!void {
    switch (breadth) {
        .fixed => |value| {
            _ = try finiteNonNegative(value);
        },
        .percent => |value| {
            _ = try finiteNonNegative(value);
        },
        .fit_content => |value| {
            try validateLengthPercentage(value, false);
        },
        .auto, .min_content, .max_content => {},
        .fr => |value| {
            _ = try finiteNonNegative(value);
        },
    }
}

fn validateDimension(value: style.Dimension) Error!void {
    switch (value) {
        .auto, .min_content, .max_content => {},
        .fit_content => |limit| if (limit) |v| {
            _ = try finiteNonNegative(v);
        },
        .length, .percent => |number| {
            _ = try finiteNonNegative(number);
        },
    }
}

fn validateInsets(value: style.Insets) Error!void {
    try validateLengthPercentageAuto(value.top);
    try validateLengthPercentageAuto(value.right);
    try validateLengthPercentageAuto(value.bottom);
    try validateLengthPercentageAuto(value.left);
}

fn validateRect(value: style.LengthPercentageRect, negative_allowed: bool) Error!void {
    try validateLengthPercentage(value.top, negative_allowed);
    try validateLengthPercentage(value.right, negative_allowed);
    try validateLengthPercentage(value.bottom, negative_allowed);
    try validateLengthPercentage(value.left, negative_allowed);
}

fn validateLengthPercentage(value: style.LengthPercentage, negative_allowed: bool) Error!void {
    switch (value) {
        .length, .percent => |number| {
            _ = try finite(number);
            if (!negative_allowed and number < 0) return error.InvalidStyle;
        },
    }
}

fn validateLengthPercentageAuto(value: style.LengthPercentageAuto) Error!void {
    switch (value) {
        .auto => {},
        .length, .percent => |number| {
            _ = try finite(number);
        },
    }
}

fn clearHiddenLayoutState(node: *widget.WidgetNode) void {
    node.rect = .{};
    node.resolved_box_edges = null;
    node.first_baseline = null;
    node.layout_content_size = .{ .width = 0, .height = 0 };
    if (node.scroll) |scroll| scroll.state.max_offset = .{ 0, 0 };
}

fn markHidden(tree: *widget.WidgetTree, index: usize, inherited: bool, depth: usize) Error!void {
    if (depth == 0 or index >= tree.nodes.items.len) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    const hidden = inherited or node.style.display == .none;
    node.layout_hidden = hidden;
    if (hidden) clearHiddenLayoutState(node);
    for (node.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        try markHidden(tree, child_index, hidden, depth - 1);
    }
}

fn crossLayoutNatural(
    context: *layout_context.LayoutContext,
    tree: *widget.WidgetTree,
    node: *const widget.WidgetNode,
    request: layout_context.Request,
) Error!Natural {
    const measured = try context.measure_node(context, tree, node, request);
    var min_width_request = request;
    min_width_request.width_mode = .min_content;
    const min_width = try context.measure_node(context, tree, node, min_width_request);
    var min_height_request = request;
    min_height_request.height_mode = .min_content;
    const min_height = try context.measure_node(context, tree, node, min_height_request);
    var max_width_request = request;
    max_width_request.width_mode = .max_content;
    const max_width = try context.measure_node(context, tree, node, max_width_request);
    var max_height_request = request;
    max_height_request.height_mode = .max_content;
    const max_height = try context.measure_node(context, tree, node, max_height_request);
    const edges = try resolveEdges(node.style, request.percentage_basis.width);
    const input = try requestSizingStyle(node.style, request, edges);
    const minimum_content: widget.Size = .{
        .width = try minimumContribution(
            input.size.width,
            input.min_size.width,
            input.max_size.width,
            input.overflow.width,
            request.percentage_basis.width,
            min_width.content.width,
            max_width.content.width,
        ),
        .height = try minimumContribution(
            input.size.height,
            input.min_size.height,
            input.max_size.height,
            input.overflow.height,
            request.percentage_basis.height,
            min_height.content.height,
            max_height.content.height,
        ),
    };
    const minimum_border = try usedSizeForRequest(
        input,
        request.percentage_basis,
        minimum_content,
        edges,
        null,
        request,
    );
    return .{
        .content = measured.content,
        .border = measured.border,
        .minimum = minimum_border,
        .min_content = .{
            .width = min_width.border.width,
            .height = min_height.border.height,
        },
        .max_content = .{
            .width = max_width.border.width,
            .height = max_height.border.height,
        },
    };
}
fn optionalDimensionKey(value: ?f32) OptionalDimensionKey {
    return if (value) |number|
        .{ .present = true, .value = number }
    else
        .{ .present = false };
}

fn availableSpaceKey(value: sizing.AvailableSpace) AvailableSpaceKey {
    return switch (value) {
        .definite => |number| .{ .tag = .definite, .value = number },
        .min_content => .{ .tag = .min_content },
        .max_content => .{ .tag = .max_content },
    };
}

fn measureCacheKeyEqual(left: MeasureCacheKey, right: MeasureCacheKey) bool {
    return std.meta.eql(left, right);
}

fn measureCacheKey(
    tree: *widget.WidgetTree,
    index: usize,
    request: layout_context.Request,
    parent_display: ?style.Display,
    allow_auto_track_stretch: bool,
    deferred_percentage_style: DeferredPercentageStyle,
) Error!MeasureCacheKey {
    const node = &tree.nodes.items[index];
    const edges = try resolveEdges(node.style, request.percentage_basis.width);
    const known_dimensions = try leafKnownDimensions(node.style, request, edges);
    const available_space = try leafAvailableSpace(node.style, request, edges);
    return .{
        .node_index = index,
        .known_width = optionalDimensionKey(known_dimensions.width),
        .known_height = optionalDimensionKey(known_dimensions.height),
        .known_border_width = optionalDimensionKey(request.known_border.width),
        .known_border_height = optionalDimensionKey(request.known_border.height),
        .available_width = availableSpaceKey(available_space.width),
        .available_height = availableSpaceKey(available_space.height),
        .percentage_width = optionalDimensionKey(request.percentage_basis.width),
        .percentage_height = optionalDimensionKey(request.percentage_basis.height),
        .width_mode = request.width_mode,
        .height_mode = request.height_mode,
        .sizing_mode = request.sizing_mode,
        .parent_display = parent_display,
        .allow_auto_track_stretch = allow_auto_track_stretch,
        .request_available_width = request.available.width,
        .request_available_height = request.available.height,
        .deferred_percentage_style = deferred_percentage_style,
        .text_request = node.text_request,
        .writing_mode = node.writing_mode,
    };
}
fn measureNode(
    tree: *widget.WidgetTree,
    index: usize,
    request: layout_context.Request,
    options: Options,
    depth: usize,
    parent_display: ?style.Display,
    allow_auto_track_stretch: bool,
    deferred_percentage_style: DeferredPercentageStyle,
) Error!Natural {
    if (depth == 0 or index >= tree.nodes.items.len) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    if (node.layout_hidden or node.style.display == .none) return .{
        .content = .{ .width = 0, .height = 0 },
        .border = .{ .width = 0, .height = 0 },
    };
    _ = try finiteNonNegative(request.available.width);
    _ = try finiteNonNegative(request.available.height);
    const key = try measureCacheKey(
        tree,
        index,
        request,
        parent_display,
        allow_auto_track_stretch,
        deferred_percentage_style,
    );
    if (options.measurement_cache) |cache| {
        if (cache.lookup(key)) |cached| return cached;
    }
    const result = try measureNodeUncached(
        tree,
        index,
        request,
        options,
        depth,
        parent_display,
        allow_auto_track_stretch,
    );
    if (options.measurement_cache) |cache| cache.insert(key, result);
    return result;
}
fn measureNodeUncached(
    tree: *widget.WidgetTree,
    index: usize,
    request: layout_context.Request,
    options: Options,
    depth: usize,
    parent_display: ?style.Display,
    allow_auto_track_stretch: bool,
) Error!Natural {
    if (depth == 0 or index >= tree.nodes.items.len) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    if (node.layout_hidden or node.style.display == .none) return .{
        .content = .{ .width = 0, .height = 0 },
        .border = .{ .width = 0, .height = 0 },
    };
    _ = try finiteNonNegative(request.available.width);
    _ = try finiteNonNegative(request.available.height);
    const raw_input = node.style;
    const edges = try resolveEdges(raw_input, request.percentage_basis.width);
    const input = try requestSizingStyle(raw_input, request, edges);
    var intrinsic: widget.Size = .{ .width = 0, .height = 0 };
    var min_content: widget.Size = .{ .width = 0, .height = 0 };
    var max_content: widget.Size = .{ .width = 0, .height = 0 };
    if (node.children.items.len == 0 or widget.isLateQuery(node)) {
        const leaf = try measureLeaf(node, index, options, request, edges);
        intrinsic = leaf.content;
        min_content = leaf.min_content;
        max_content = leaf.max_content;
    } else {
        if (options.context) |context| {
            if (parent_display) |display| {
                if (node.style.display != display) {
                    return crossLayoutNatural(context, tree, node, request);
                }
            }
        }
        if (node.style.display != .grid) return error.InvalidStyle;
        intrinsic = try measureGridContent(tree, index, request, edges, options, depth - 1, allow_auto_track_stretch);
        var min_width_request = request;
        min_width_request.width_mode = .min_content;
        const min_width = try measureGridContent(
            tree,
            index,
            min_width_request,
            edges,
            options,
            depth - 1,
            allow_auto_track_stretch,
        );
        var min_height_request = request;
        min_height_request.height_mode = .min_content;
        const min_height = try measureGridContent(
            tree,
            index,
            min_height_request,
            edges,
            options,
            depth - 1,
            allow_auto_track_stretch,
        );
        min_content = .{ .width = min_width.width, .height = min_height.height };
        var max_width_request = request;
        max_width_request.width_mode = .max_content;
        const max_width = try measureGridContent(
            tree,
            index,
            max_width_request,
            edges,
            options,
            depth - 1,
            allow_auto_track_stretch,
        );
        var max_height_request = request;
        max_height_request.height_mode = .max_content;
        const max_height = try measureGridContent(
            tree,
            index,
            max_height_request,
            edges,
            options,
            depth - 1,
            allow_auto_track_stretch,
        );
        max_content = .{ .width = max_width.width, .height = max_height.height };
    }
    const border = try usedSizeForRequest(
        input,
        request.percentage_basis,
        intrinsic,
        edges,
        null,
        request,
    );
    const minimum_content: widget.Size = .{
        .width = try minimumContribution(
            input.size.width,
            input.min_size.width,
            input.max_size.width,
            input.overflow.width,
            request.percentage_basis.width,
            min_content.width,
            max_content.width,
        ),
        .height = try minimumContribution(
            input.size.height,
            input.min_size.height,
            input.max_size.height,
            input.overflow.height,
            request.percentage_basis.height,
            min_content.height,
            max_content.height,
        ),
    };
    const minimum_border = try usedSizeForRequest(
        input,
        request.percentage_basis,
        minimum_content,
        edges,
        null,
        request,
    );
    const min_content_border = try usedSizeForRequest(
        input,
        request.percentage_basis,
        min_content,
        edges,
        null,
        request,
    );
    const max_content_border = try usedSizeForRequest(
        input,
        request.percentage_basis,
        max_content,
        edges,
        null,
        request,
    );
    return .{
        .content = intrinsic,
        .border = border,
        .minimum = minimum_border,
        .min_content = min_content_border,
        .max_content = max_content_border,
    };
}

fn measureGridContent(
    tree: *widget.WidgetTree,
    index: usize,
    request: layout_context.Request,
    edges: Edges,
    options: Options,
    depth: usize,
    allow_auto_track_stretch: bool,
) Error!widget.Size {
    if (depth == 0) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    const input = try requestSizingStyle(node.style, request, edges);
    const provisional = try usedSizeForRequest(
        input,
        request.percentage_basis,
        request.available,
        edges,
        request.available,
        request,
    );
    const child_available: widget.Size = .{
        .width = @max(0, provisional.width - edges.horizontal),
        .height = @max(0, provisional.height - edges.vertical),
    };
    const width_mode = modeForDimension(
        input.size.width,
        request.width_mode,
        request.percentage_basis.width,
    );
    const height_mode = modeForDimension(
        input.size.height,
        request.height_mode,
        request.percentage_basis.height,
    );
    const width_available_definite = width_mode == .definite;
    const height_available_definite = height_mode == .definite;
    const width_basis_definite = request.known_border.width != null or
        knownDimension(input.size.width, request.percentage_basis.width) != null;
    const height_basis_definite = request.known_border.height != null or
        knownDimension(input.size.height, request.percentage_basis.height) != null;
    const column_repeat_strategy = autoRepeatStrategy(
        input.size.width,
        input.max_size.width,
        input.min_size.width,
        request.percentage_basis.width,
        width_basis_definite,
    );
    const row_repeat_strategy = autoRepeatStrategy(
        input.size.height,
        input.max_size.height,
        input.min_size.height,
        request.percentage_basis.height,
        height_basis_definite,
    );
    const column_repeat_basis = try autoRepeatContentBasis(
        if (width_basis_definite) child_available.width else null,
        input,
        .horizontal,
        edges,
        request.percentage_basis.width,
    );
    const row_repeat_basis = try autoRepeatContentBasis(
        if (height_basis_definite) child_available.height else null,
        input,
        .vertical,
        edges,
        request.percentage_basis.height,
    );
    const column_gap = try gridGap(
        input,
        .columns,
        if (width_basis_definite) child_available.width else null,
    );
    const row_gap = try gridGap(
        input,
        .rows,
        if (height_basis_definite) child_available.height else null,
    );
    const column_repeat_gap = try gridGap(input, .columns, column_repeat_basis);
    const row_repeat_gap = try gridGap(input, .rows, row_repeat_basis);

    var items: std.ArrayList(FlowItem) = .empty;
    defer items.deinit(options.allocator);

    var columns: std.ArrayList(Track) = .empty;
    defer columns.deinit(options.allocator);
    var rows: std.ArrayList(Track) = .empty;
    defer rows.deinit(options.allocator);
    const explicit_columns = try initTracks(
        options.allocator,
        &columns,
        input.grid_template_columns,
        input.grid_auto_columns,
        column_repeat_basis,
        column_repeat_strategy,
        column_repeat_gap,
    );
    const explicit_rows = try initTracks(
        options.allocator,
        &rows,
        input.grid_template_rows,
        input.grid_auto_rows,
        row_repeat_basis,
        row_repeat_strategy,
        row_repeat_gap,
    );

    const child_request: layout_context.Request = .{
        .available = child_available,
        .percentage_basis = .{
            .width = if (width_basis_definite) @as(?f32, child_available.width) else null,
            .height = if (height_basis_definite) @as(?f32, child_available.height) else null,
        },
        .width_mode = width_mode,
        .height_mode = height_mode,
        .sizing_mode = .inherent,
        .known_border = .{ .width = null, .height = null },
    };
    try collectItems(
        tree,
        node,
        child_request,
        columns.items,
        explicit_columns,
        explicit_rows,
        options,
        depth - 1,
        &items,
    );

    var occupied: Occupancy = .{};
    defer occupied.deinit(options.allocator);
    _ = try placeItems(
        options.allocator,
        &columns,
        &rows,
        &items,
        input.grid_auto_flow,
        input.grid_auto_columns,
        input.grid_auto_rows,
        if (width_available_definite) child_available.width else null,
        if (height_available_definite) child_available.height else null,
        &occupied,
    );
    collapseAutoFitTracks(columns.items, items.items, .columns);
    collapseAutoFitTracks(rows.items, items.items, .rows);
    try remeasureItemsForColumns(
        tree,
        node,
        items.items,
        columns.items,
        rows.items,
        row_gap,
        child_request,
        options,
        depth - 1,
    );

    try growTrackItems(
        options.allocator,
        columns.items,
        items.items,
        .columns,
        column_gap,
        if (width_available_definite) child_available.width else null,
        availableForDimension(input.size.width, width_mode, child_available.width),
    );

    if (width_available_definite) {
        try maximizeIndefiniteTracks(
            columns.items,
            .{ .definite = child_available.width },
            child_available.width,
            column_gap,
        );
        try resolveFlexibleTracks(options.allocator, columns.items, child_available.width, column_gap);
    } else {
        try maximizeIndefiniteTracks(
            columns.items,
            availableForDimension(input.size.width, width_mode, child_available.width),
            null,
            column_gap,
        );
        try resolveIndefiniteFlexibleTracks(
            columns.items,
            items.items,
            .columns,
            availableForDimension(input.size.width, width_mode, child_available.width),
            column_gap,
        );
    }
    if (width_available_definite and
        (allow_auto_track_stretch or
            knownDimension(input.size.width, request.percentage_basis.width) != null or
            knownDimension(input.min_size.width, request.percentage_basis.width) != null))
    {
        try stretchAutoTracks(columns.items, column_gap, child_available.width, input);
    }

    try remeasureItemsForRows(
        tree,
        node,
        items.items,
        columns.items,
        column_gap,
        child_request,
        options,
        depth - 1,
    );
    try growTrackItems(
        options.allocator,
        rows.items,
        items.items,
        .rows,
        row_gap,
        if (height_available_definite) child_available.height else null,
        availableForDimension(input.size.height, height_mode, child_available.height),
    );

    if (height_available_definite) {
        try maximizeIndefiniteTracks(
            rows.items,
            .{ .definite = child_available.height },
            child_available.height,
            row_gap,
        );
        try resolveFlexibleTracks(options.allocator, rows.items, child_available.height, row_gap);
    } else {
        try maximizeIndefiniteTracks(
            rows.items,
            availableForDimension(input.size.height, height_mode, child_available.height),
            null,
            row_gap,
        );
        try resolveIndefiniteFlexibleTracks(
            rows.items,
            items.items,
            .rows,
            availableForDimension(input.size.height, height_mode, child_available.height),
            row_gap,
        );
    }

    const width = try trackTotal(columns.items, column_gap);
    const height = try trackTotal(rows.items, row_gap);

    return .{ .width = try nonNegative(width), .height = try nonNegative(height) };
}

fn intrinsicContributionStyle(
    input: style.Style,
    defer_width: bool,
    defer_height: bool,
) style.Style {
    var result = input;
    if (defer_width) {
        if (result.size.width == .percent) result.size.width = .auto;
        if (result.min_size.width == .percent) result.min_size.width = .auto;
        if (result.max_size.width == .percent) result.max_size.width = .auto;
    }
    if (defer_height) {
        if (result.size.height == .percent) result.size.height = .auto;
        if (result.min_size.height == .percent) result.min_size.height = .auto;
        if (result.max_size.height == .percent) result.max_size.height = .auto;
    }
    return result;
}

fn hasPercentageContribution(input: style.Style, axis: TrackAxis) bool {
    const preferred = switch (axis) {
        .columns => input.size.width,
        .rows => input.size.height,
    };
    const minimum = switch (axis) {
        .columns => input.min_size.width,
        .rows => input.min_size.height,
    };
    const maximum = switch (axis) {
        .columns => input.max_size.width,
        .rows => input.max_size.height,
    };
    return preferred == .percent or minimum == .percent or maximum == .percent;
}
fn autoAxisClamped(
    input: style.Style,
    axis: enum { horizontal, vertical },
    intrinsic: widget.Size,
    edges: Edges,
    percentage_basis: style.Size(?f32),
) Error!bool {
    const dimension = if (axis == .horizontal) input.size.width else input.size.height;
    if (dimension != .auto) return false;
    const natural = if (axis == .horizontal) intrinsic.width else intrinsic.height;
    const content_inset = if (axis == .horizontal) edges.horizontal else edges.vertical;
    const box_adjustment = if (axis == .horizontal) edges.box_horizontal else edges.box_vertical;
    const candidate = try sizingToBorder(
        try contentToSizing(natural, content_inset, box_adjustment, input.box_sizing),
        box_adjustment,
        input.box_sizing,
    );
    const minimum_dimension = if (axis == .horizontal)
        input.min_size.width
    else
        input.min_size.height;
    const maximum_dimension = if (axis == .horizontal)
        input.max_size.width
    else
        input.max_size.height;
    const basis = if (axis == .horizontal) percentage_basis.width else percentage_basis.height;
    const minimum = try resolveDimensionBorder(
        minimum_dimension,
        basis,
        natural,
        dimensionAdjustment(minimum_dimension, content_inset, box_adjustment),
        input.box_sizing,
    );
    if (minimum) |value| {
        if (candidate < value) return true;
    }
    const maximum = try resolveDimensionBorder(
        maximum_dimension,
        basis,
        natural,
        dimensionAdjustment(maximum_dimension, content_inset, box_adjustment),
        input.box_sizing,
    );
    if (maximum) |value| {
        if (candidate > value) return true;
    }
    return false;
}
fn modeForDimension(
    dimension: style.Dimension,
    requested: layout_context.MeasureMode,
    percentage_basis: ?f32,
) layout_context.MeasureMode {
    return switch (dimension) {
        .min_content => .min_content,
        .max_content => .max_content,
        .length => .definite,
        .percent => if (percentage_basis != null) .definite else requested,
        .auto, .fit_content => requested,
    };
}

fn availableForDimension(
    dimension: style.Dimension,
    mode: layout_context.MeasureMode,
    available: f32,
) sizing.AvailableSpace {
    return switch (dimension) {
        .min_content => .min_content,
        .max_content => .max_content,
        .auto, .length, .percent, .fit_content => switch (mode) {
            .definite => .{ .definite = available },
            .min_content => .min_content,
            .max_content => .max_content,
        },
    };
}

fn concreteRequest(available: widget.Size) layout_context.Request {
    return .{
        .available = available,
        .percentage_basis = .{
            .width = available.width,
            .height = available.height,
        },
        .sizing_mode = .inherent,
        .known_border = .{ .width = null, .height = null },
    };
}

fn preferredContent(
    value: style.Dimension,
    basis: ?f32,
    min_content: f32,
    max_content: f32,
) Error!?f32 {
    return switch (value) {
        .auto => null,
        .length => |number| @as(?f32, try finiteNonNegative(number)),
        .percent => |fraction| if (basis) |size|
            @as(?f32, try finiteNonNegative(try finite(fraction * size)))
        else
            null,
        .min_content => @as(?f32, min_content),
        .max_content => @as(?f32, max_content),
        .fit_content => |limit| blk: {
            var cap = max_content;
            if (limit) |value_limit| cap = @min(cap, try finiteNonNegative(value_limit));
            break :blk @as(?f32, @min(max_content, cap));
        },
    };
}

fn minimumContribution(
    preferred: style.Dimension,
    minimum: style.Dimension,
    maximum: style.Dimension,
    overflow_mode: style.Overflow,
    basis: ?f32,
    min_content: f32,
    max_content: f32,
) Error!f32 {
    const preferred_size = try preferredContent(preferred, basis, min_content, max_content);
    const minimum_size = try preferredContent(minimum, basis, min_content, max_content);
    const maximum_size = try preferredContent(maximum, basis, min_content, max_content);
    var result = if (preferred_size) |value|
        value
    else if (minimum_size) |value|
        value
    else if (overflow_mode == .visible)
        min_content
    else
        0;
    if (minimum_size) |value| result = @max(result, value);
    if (maximum_size) |value| result = @min(result, value);
    return finiteNonNegative(result);
}

fn contentDimensionFromBorder(
    value: ?f32,
    inset: f32,
    box_sizing: style.BoxSizing,
) Error!?f32 {
    const sizing_value = value orelse return null;
    const border_value = try sizingToBorder(sizing_value, inset, box_sizing);
    const content_value = try borderToSizing(border_value, inset, .content_box);
    return content_value;
}

fn leafKnownDimensions(
    input: style.Style,
    request: layout_context.Request,
    edges: Edges,
) Error!sizing.OptionalSize {
    const content_sizing = request.sizing_mode == .content;
    return .{
        .width = if (request.known_border.width) |border|
            try borderToSizing(border, edges.horizontal, .content_box)
        else if (content_sizing)
            null
        else
            try contentDimensionFromBorder(
                knownDimension(input.size.width, request.percentage_basis.width),
                edges.horizontal,
                input.box_sizing,
            ),
        .height = if (request.known_border.height) |border|
            try borderToSizing(border, edges.vertical, .content_box)
        else if (content_sizing)
            null
        else
            try contentDimensionFromBorder(
                knownDimension(input.size.height, request.percentage_basis.height),
                edges.vertical,
                input.box_sizing,
            ),
    };
}

fn leafAvailableSpaceForDimension(
    dimension: style.Dimension,
    mode: layout_context.MeasureMode,
    available_border: f32,
    inset: f32,
) Error!sizing.AvailableSpace {
    return contentAvailableSpace(
        availableForDimension(dimension, mode, available_border),
        inset,
    );
}

fn leafAvailableSpace(
    input: style.Style,
    request: layout_context.Request,
    edges: Edges,
) Error!sizing.AvailableSize {
    const content_sizing = request.sizing_mode == .content;
    const width: sizing.AvailableSpace = if (request.known_border.width) |border| blk: {
        const definite = try borderToSizing(border, edges.horizontal, .content_box);
        break :blk .{ .definite = definite };
    } else try leafAvailableSpaceForDimension(
        if (content_sizing) .auto else input.size.width,
        request.width_mode,
        request.available.width,
        edges.horizontal,
    );
    const height: sizing.AvailableSpace = if (request.known_border.height) |border| blk: {
        const definite = try borderToSizing(border, edges.vertical, .content_box);
        break :blk .{ .definite = definite };
    } else try leafAvailableSpaceForDimension(
        if (content_sizing) .auto else input.size.height,
        request.height_mode,
        request.available.height,
        edges.vertical,
    );
    return .{ .width = width, .height = height };
}

fn contentAvailableSpace(
    available: sizing.AvailableSpace,
    inset: f32,
) Error!sizing.AvailableSpace {
    return switch (available) {
        .definite => |value| blk: {
            const content_value = try finite(value - inset);
            break :blk .{ .definite = @max(0, content_value) };
        },
        .min_content => .min_content,
        .max_content => .max_content,
    };
}

const IntrinsicCaption = struct {
    text: []const u8,
    decoration: layout_context.TextDecoration,
};

/// The intrinsic caption a control contributes to its own min/max content
/// probes, with the decoration from the ONE inset table. A control with no
/// caption contributes nothing.
fn intrinsicCaption(node: *const widget.WidgetNode) ?IntrinsicCaption {
    return switch (node.kind) {
        .label => |label| .{ .text = label.text, .decoration = .{} },
        .checkbox, .radio, .switch_control, .progress => .{
            .text = layout_context.controlCaption(node),
            .decoration = layout_context.textDecoration(node.kind),
        },
        .button, .slider, .spacer, .separator, .row, .column, .element => null,
    };
}

fn measureLeaf(
    node: *const widget.WidgetNode,
    node_index: usize,
    options: Options,
    request: layout_context.Request,
    edges: Edges,
) Error!Natural {
    const input = node.style;
    try layout_context.validateLeafGeometry(node.kind);
    const known_dimensions = try leafKnownDimensions(input, request, edges);
    const available_space = try leafAvailableSpace(input, request, edges);
    const measure_input: layout_context.MeasureInput = .{
        .known_dimensions = known_dimensions,
        .available_space = available_space,
        .text = node.text_request,
        .writing_mode = node.writing_mode,
    };
    var content = try leafContent(node, node_index, options, measure_input);
    var min_content = content;
    var max_content = content;
    if (intrinsicCaption(node)) |caption| {
        const min_width = try measureIntrinsicCaption(
            node,
            node_index,
            options,
            caption,
            measure_input,
            .min_content,
            available_space.height,
        );
        const min_height = try measureIntrinsicCaption(
            node,
            node_index,
            options,
            caption,
            measure_input,
            available_space.width,
            .min_content,
        );
        min_content = .{ .width = min_width.width, .height = min_height.height };
        const max_width = try measureIntrinsicCaption(
            node,
            node_index,
            options,
            caption,
            measure_input,
            .max_content,
            available_space.height,
        );
        const max_height = try measureIntrinsicCaption(
            node,
            node_index,
            options,
            caption,
            measure_input,
            available_space.width,
            .max_content,
        );
        max_content = .{ .width = max_width.width, .height = max_height.height };
    } else if (node.kind == .element) {
        var intrinsic_input = measure_input;
        intrinsic_input.available_space.width = .min_content;
        min_content.width = (try layout_context.measureElement(node, intrinsic_input)).width;
        intrinsic_input.available_space.width = .max_content;
        max_content.width = (try layout_context.measureElement(node, intrinsic_input)).width;
        intrinsic_input.available_space.width = available_space.width;
        intrinsic_input.available_space.height = .min_content;
        min_content.height = (try layout_context.measureElement(node, intrinsic_input)).height;
        intrinsic_input.available_space.height = .max_content;
        max_content.height = (try layout_context.measureElement(node, intrinsic_input)).height;
    }
    content = try finiteSize(content);
    min_content = try finiteSize(min_content);
    max_content = try finiteSize(max_content);
    const minimum: widget.Size = .{
        .width = try minimumContribution(
            input.size.width,
            input.min_size.width,
            input.max_size.width,
            input.overflow.width,
            request.percentage_basis.width,
            min_content.width,
            max_content.width,
        ),
        .height = try minimumContribution(
            input.size.height,
            input.min_size.height,
            input.max_size.height,
            input.overflow.height,
            request.percentage_basis.height,
            min_content.height,
            max_content.height,
        ),
    };
    return .{
        .content = content,
        .border = content,
        .minimum = minimum,
        .min_content = min_content,
        .max_content = max_content,
    };
}

fn measureIntrinsicCaption(
    node: *const widget.WidgetNode,
    node_index: usize,
    options: Options,
    caption: IntrinsicCaption,
    input: layout_context.MeasureInput,
    width: sizing.AvailableSpace,
    height: sizing.AvailableSpace,
) Error!widget.Size {
    var measure_input = input;
    measure_input.available_space = .{ .width = width, .height = height };
    return measureCaption(node, node_index, options, caption, measure_input);
}

fn measureCaption(
    node: *const widget.WidgetNode,
    node_index: usize,
    options: Options,
    caption: IntrinsicCaption,
    input: layout_context.MeasureInput,
) Error!widget.Size {
    if (options.context) |context| {
        return context.measureDecoratedTextSizeCached(
            node_index,
            caption.text,
            input,
            node.text_overflow,
            node.text_max_width,
            caption.decoration,
        );
    }
    return layout_context.measureDecoratedTextSize(
        options.measure,
        caption.text,
        input,
        node.text_overflow,
        node.text_max_width,
        caption.decoration,
    );
}

fn leafContent(
    node: *const widget.WidgetNode,
    node_index: usize,
    options: Options,
    input: layout_context.MeasureInput,
) Error!widget.Size {
    return switch (node.kind) {
        .element => try layout_context.measureElement(node, input),
        .label, .checkbox, .radio, .switch_control, .progress => try measureCaption(node, node_index, options, .{
            .text = switch (node.kind) {
                .label => |label| label.text,
                else => layout_context.controlCaption(node),
            },
            .decoration = layout_context.textDecoration(node.kind),
        }, input),
        .spacer => |spacer| .{ .width = spacer.size, .height = spacer.size },
        .button => |button| .{
            .width = if (button.visual_label) |text|
                if (text.len == 0)
                    100
                else blk: {
                    const text_width = std.math.mul(usize, text.len, 10) catch
                        return error.InvalidStyle;
                    const padded_width = std.math.add(usize, text_width, 16) catch
                        return error.InvalidStyle;
                    break :blk try countToF32(padded_width);
                }
            else
                100,
            .height = 32,
        },
        .slider => if (options.context) |context| try context.measureSliderContentCached(
            node_index,
            node,
            input,
        ) else try layout_context.measureSliderContent(options.measure, node, input),
        .separator => |separator| switch (separator.axis) {
            .horizontal => .{ .width = 100, .height = separator.thickness },
            .vertical => .{ .width = separator.thickness, .height = 100 },
        },
        .row, .column => .{ .width = 0, .height = 0 },
    };
}

fn knownDimension(value: style.Dimension, basis: ?f32) ?f32 {
    return switch (value) {
        .length => |number| number,
        .percent => |fraction| if (basis) |size| size * fraction else null,
        .auto, .min_content, .max_content, .fit_content => null,
    };
}

fn autoRepeatStrategy(
    preferred: style.Dimension,
    maximum: style.Dimension,
    minimum: style.Dimension,
    percentage_basis: ?f32,
    forced: bool,
) AutoRepeatStrategy {
    if (forced or
        knownDimension(preferred, percentage_basis) != null or
        knownDimension(maximum, percentage_basis) != null)
    {
        return .max_repetitions_that_fit;
    }
    return if (knownDimension(minimum, percentage_basis) != null)
        .min_repetitions_that_overflow
    else
        .max_repetitions_that_fit;
}

fn autoRepeatContentBasis(
    definite_content: ?f32,
    input: style.Style,
    axis: enum { horizontal, vertical },
    edges: Edges,
    percentage_basis: ?f32,
) Error!?f32 {
    const preferred = if (axis == .horizontal) input.size.width else input.size.height;
    const maximum = if (axis == .horizontal) input.max_size.width else input.max_size.height;
    const minimum = if (axis == .horizontal) input.min_size.width else input.min_size.height;
    const inset = if (axis == .horizontal) edges.horizontal else edges.vertical;
    const preferred_content = try contentDimensionFromBorder(
        knownDimension(preferred, percentage_basis),
        inset,
        input.box_sizing,
    );
    const maximum_content = try contentDimensionFromBorder(
        knownDimension(maximum, percentage_basis),
        inset,
        input.box_sizing,
    );
    const minimum_content = try contentDimensionFromBorder(
        knownDimension(minimum, percentage_basis),
        inset,
        input.box_sizing,
    );
    var basis = definite_content orelse
        preferred_content orelse
        maximum_content orelse
        minimum_content orelse return null;
    if (maximum_content) |value| basis = @min(basis, value);
    if (minimum_content) |value| basis = @max(basis, value);
    return @as(?f32, try finiteNonNegative(basis));
}

fn finiteSize(value: widget.Size) Error!widget.Size {
    return .{
        .width = try finiteNonNegative(value.width),
        .height = try finiteNonNegative(value.height),
    };
}

fn layoutGridNode(
    tree: *widget.WidgetTree,
    index: usize,
    containing: widget.Size,
    forced_border: ?widget.Size,
    options: Options,
    depth: usize,
) Error!void {
    if (depth == 0 or index >= tree.nodes.items.len) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    node.first_baseline = null;
    var intrinsic_request = concreteRequest(containing);
    intrinsic_request.width_mode = if (forced_border != null or
        knownDimension(node.style.size.width, intrinsic_request.percentage_basis.width) != null)
        .definite
    else
        .max_content;
    intrinsic_request.height_mode = if (forced_border != null or
        knownDimension(node.style.size.height, intrinsic_request.percentage_basis.height) != null)
        .definite
    else
        .max_content;
    const natural = try measureNode(
        tree,
        index,
        intrinsic_request,
        options,
        depth - 1,
        null,
        false,
        .{},
    );
    var edges = try resolveEdges(node.style, containing.width);
    const border = forced_border orelse try usedSize(
        node.style,
        .{ .width = containing.width, .height = containing.height },
        natural.content,
        edges,
        null,
    );
    edges = try clampScrollbarGutter(edges, border);
    try checkSize(border);
    node.rect.w = border.width;
    node.rect.h = border.height;
    node.resolved_box_edges = .{ .border = edges.border, .padding = edges.padding };
    const content: widget.Size = .{
        .width = @max(0, border.width - edges.horizontal),
        .height = @max(0, border.height - edges.vertical),
    };
    try checkSize(content);
    const width_auto = node.style.size.width == .auto or node.style.size.width == .min_content or
        node.style.size.width == .max_content or node.style.size.width == .fit_content;
    const height_auto = node.style.size.height == .auto or node.style.size.height == .min_content or
        node.style.size.height == .max_content or node.style.size.height == .fit_content;
    const width_clamped = try autoAxisClamped(
        node.style,
        .horizontal,
        natural.content,
        edges,
        .{ .width = containing.width, .height = containing.height },
    );
    const height_clamped = try autoAxisClamped(
        node.style,
        .vertical,
        natural.content,
        edges,
        .{ .width = containing.width, .height = containing.height },
    );
    const width_definite = forced_border != null or !width_auto or width_clamped;
    const height_definite = forced_border != null or !height_auto or height_clamped;
    const width_mode: layout_context.MeasureMode = if (width_definite)
        .definite
    else
        modeForDimension(node.style.size.width, .max_content, null);
    const height_mode: layout_context.MeasureMode = if (height_definite)
        .definite
    else
        modeForDimension(node.style.size.height, .max_content, null);
    const intrinsic_auto_height = height_auto and forced_border == null and !height_clamped;
    const column_repeat_strategy = autoRepeatStrategy(
        node.style.size.width,
        node.style.max_size.width,
        node.style.min_size.width,
        containing.width,
        forced_border != null,
    );
    const row_repeat_strategy = autoRepeatStrategy(
        node.style.size.height,
        node.style.max_size.height,
        node.style.min_size.height,
        containing.height,
        forced_border != null,
    );
    const column_repeat_basis = try autoRepeatContentBasis(
        if (width_mode == .definite) content.width else null,
        node.style,
        .horizontal,
        edges,
        containing.width,
    );
    const row_repeat_basis = try autoRepeatContentBasis(
        if (height_mode == .definite) content.height else null,
        node.style,
        .vertical,
        edges,
        containing.height,
    );

    var column_gap = try gridGap(
        node.style,
        .columns,
        if (width_mode == .definite) content.width else null,
    );
    var row_gap = try gridGap(
        node.style,
        .rows,
        if (height_mode == .definite) content.height else null,
    );
    const column_repeat_gap = try gridGap(node.style, .columns, column_repeat_basis);
    const row_repeat_gap = try gridGap(node.style, .rows, row_repeat_basis);

    var columns: std.ArrayList(Track) = .empty;
    defer columns.deinit(options.allocator);
    var rows: std.ArrayList(Track) = .empty;
    defer rows.deinit(options.allocator);
    var explicit_columns = try initTracks(
        options.allocator,
        &columns,
        node.style.grid_template_columns,
        node.style.grid_auto_columns,
        column_repeat_basis,
        column_repeat_strategy,
        column_repeat_gap,
    );
    var explicit_rows = try initTracks(
        options.allocator,
        &rows,
        node.style.grid_template_rows,
        node.style.grid_auto_rows,
        row_repeat_basis,
        row_repeat_strategy,
        row_repeat_gap,
    );

    var items: std.ArrayList(FlowItem) = .empty;
    defer items.deinit(options.allocator);
    try collectItems(
        tree,
        node,
        .{
            .available = content,
            .percentage_basis = .{
                .width = if (width_definite) @as(?f32, content.width) else null,
                .height = if (height_definite) @as(?f32, content.height) else null,
            },
            .width_mode = width_mode,
            .height_mode = height_mode,
        },
        columns.items,
        explicit_columns,
        explicit_rows,
        options,
        depth - 1,
        &items,
    );
    var occupied: Occupancy = .{};
    defer occupied.deinit(options.allocator);
    var placement_origins = try placeItems(
        options.allocator,
        &columns,
        &rows,
        &items,
        node.style.grid_auto_flow,
        node.style.grid_auto_columns,
        node.style.grid_auto_rows,
        if (width_mode == .definite) content.width else null,
        if (height_mode == .definite) content.height else null,
        &occupied,
    );
    collapseAutoFitTracks(columns.items, items.items, .columns);
    collapseAutoFitTracks(rows.items, items.items, .rows);
    try resolveIntrinsicBaselineShims(tree, node, items.items, content, options, depth);
    try sizeTracks(
        tree,
        node,
        &columns,
        &rows,
        items.items,
        content,
        column_gap,
        row_gap,
        width_mode,
        height_mode,
        options,
        depth - 1,
    );
    if (!width_definite or !height_definite) {
        column_gap = try gridGap(node.style, .columns, content.width);
        row_gap = try gridGap(node.style, .rows, content.height);
        columns.clearRetainingCapacity();
        rows.clearRetainingCapacity();
        items.clearRetainingCapacity();
        occupied.areas.clearRetainingCapacity();
        explicit_columns = try initTracks(
            options.allocator,
            &columns,
            node.style.grid_template_columns,
            node.style.grid_auto_columns,
            column_repeat_basis,
            column_repeat_strategy,
            column_repeat_gap,
        );
        explicit_rows = try initTracks(
            options.allocator,
            &rows,
            node.style.grid_template_rows,
            node.style.grid_auto_rows,
            row_repeat_basis,
            row_repeat_strategy,
            row_repeat_gap,
        );
        try collectItems(
            tree,
            node,
            .{
                .available = content,
                .percentage_basis = .{
                    .width = if (width_definite) @as(?f32, content.width) else null,
                    .height = if (height_definite) @as(?f32, content.height) else null,
                },
                .width_mode = width_mode,
                .height_mode = height_mode,
            },
            columns.items,
            explicit_columns,
            explicit_rows,
            options,
            depth - 1,
            &items,
        );
        placement_origins = try placeItems(
            options.allocator,
            &columns,
            &rows,
            &items,
            node.style.grid_auto_flow,
            node.style.grid_auto_columns,
            node.style.grid_auto_rows,
            if (width_definite) content.width else null,
            if (height_definite) content.height else null,
            &occupied,
        );
        collapseAutoFitTracks(columns.items, items.items, .columns);
        collapseAutoFitTracks(rows.items, items.items, .rows);
        try resolveIntrinsicBaselineShims(tree, node, items.items, content, options, depth);
        try sizeTracks(
            tree,
            node,
            &columns,
            &rows,
            items.items,
            content,
            column_gap,
            row_gap,
            width_mode,
            height_mode,
            options,
            depth - 1,
        );
    }

    var column_offsets: std.ArrayList(f32) = .empty;
    defer column_offsets.deinit(options.allocator);
    var row_offsets: std.ArrayList(f32) = .empty;
    defer row_offsets.deinit(options.allocator);
    var column_total = try trackTotal(columns.items, column_gap);
    const final_content_height = content.height;
    if (intrinsic_auto_height) {
        row_gap = try gridGap(node.style, .rows, final_content_height);
    }
    const row_total = try trackTotal(rows.items, row_gap);
    const justify_content = effectiveJustifyContent(node.style);
    const align_content = effectiveAlignContent(node.style);
    if (width_definite) {
        try stretchAutoTracks(columns.items, column_gap, content.width, node.style);
        column_total = try trackTotal(columns.items, column_gap);
    }
    const column_visible_count = visibleTrackCount(columns.items);
    const row_visible_count = visibleTrackCount(rows.items);
    const justify_distribution = try justifyContent(
        justify_content,
        content.width - column_total,
        column_visible_count,
    );
    const align_distribution = try alignContent(
        align_content,
        final_content_height - row_total,
        row_visible_count,
    );
    try buildOffsets(
        options.allocator,
        &column_offsets,
        columns.items,
        column_gap,
        justify_distribution.offset,
        justify_distribution.extra_gap,
    );
    try buildOffsets(
        options.allocator,
        &row_offsets,
        rows.items,
        row_gap,
        align_distribution.offset,
        align_distribution.extra_gap,
    );
    if (align_distribution.stretch > 0) {
        var stretch_count: usize = 0;
        for (rows.items) |track| {
            if (track.can_stretch_in_alignment and trackCanStretch(track.spec)) stretch_count += 1;
        }
        if (stretch_count != 0) {
            const addition = align_distribution.stretch *
                (try countToF32(row_visible_count)) /
                (try countToF32(stretch_count));
            for (rows.items) |*track| {
                if (track.can_stretch_in_alignment and trackCanStretch(track.spec)) {
                    track.size = try add(track.size, addition);
                    if (try trackMaximum(track.spec, content.height)) |maximum| {
                        track.size = @min(track.size, maximum);
                    }
                }
            }
            row_offsets.clearRetainingCapacity();
            try buildOffsets(
                options.allocator,
                &row_offsets,
                rows.items,
                row_gap,
                align_distribution.offset,
                align_distribution.extra_gap,
            );
        }
    }

    try resolveFinalBaselineShims(
        tree,
        node,
        items.items,
        columns.items,
        rows.items,
        column_gap,
        row_gap,
        justify_distribution.extra_gap,
        align_distribution.extra_gap,
        options,
        depth,
    );

    for (items.items) |item| {
        const child = &tree.nodes.items[item.index];
        if (item.column.start >= columns.items.len or item.column.end > columns.items.len or
            item.row.start >= rows.items.len or item.row.end > rows.items.len)
        {
            return error.InvalidStyle;
        }
        const area_width = try trackSpanTotal(
            columns.items,
            item.column.start,
            item.column.end,
            try add(column_gap, justify_distribution.extra_gap),
        );
        const area_height = try trackSpanTotal(
            rows.items,
            item.row.start,
            item.row.end,
            try add(row_gap, align_distribution.extra_gap),
        );

        const resolved_natural = try resolveFinalNatural(
            tree,
            item,
            .{ .width = area_width, .height = area_height },
            options,
            depth,
            node.style.display,
        );

        const child_edges = try resolveEdges(child.style, area_width);
        child.resolved_box_edges = .{
            .border = child_edges.border,
            .padding = child_edges.padding,
        };
        const margins = try resolveMargins(child.style, area_width);
        var child_size = try usedSize(
            child.style,
            .{ .width = area_width, .height = area_height },
            resolved_natural.content,
            child_edges,
            null,
        );
        const justify_items = effectiveJustifyItems(node.style);
        const align_items = effectiveAlignItems(node.style);
        const directions_match = child.style.writing_direction == node.style.writing_direction;
        const justify_self = alignValue(
            child.style.grid_justify_self,
            justify_items,
            directions_match,
            true,
        );
        const align_self = alignValue(
            child.style.grid_align_self,
            align_items,
            directions_match,
            false,
        );
        const stretch_width = dimensionAuto(child.style.size.width) and justify_self == .stretch and
            !margins.left_auto and !margins.right_auto and
            !(child.style.aspect_ratio != null and !dimensionAuto(child.style.size.height));
        if (stretch_width) {
            child_size.width = try clampAxisSize(
                child.style,
                .horizontal,
                @max(
                    0,
                    area_width - margins.value.left - margins.value.right,
                ),
                .{ .width = area_width, .height = area_height },
                resolved_natural.content,
                child_edges,
            );
        }
        const stretch_height = dimensionAuto(child.style.size.height) and align_self == .stretch and
            !margins.top_auto and !margins.bottom_auto and
            !(child.style.aspect_ratio != null and !dimensionAuto(child.style.size.width));
        if (stretch_height) {
            child_size.height = try clampAxisSize(
                child.style,
                .vertical,
                @max(
                    0,
                    area_height - margins.value.top - margins.value.bottom,
                ),
                .{ .width = area_width, .height = area_height },
                resolved_natural.content,
                child_edges,
            );
        }
        child_size = try reapplyAspectRatio(
            child.style,
            child_size,
            .{ .width = area_width, .height = area_height },
            resolved_natural.content,
            child_edges,
        );
        var margin_values = margins.value;
        try distributeAbsoluteAutoMargins(
            &margin_values.left,
            &margin_values.right,
            margins.left_auto,
            margins.right_auto,
            area_width,
            child_size.width,
            0,
            0,
        );
        try distributeAbsoluteAutoMargins(
            &margin_values.top,
            &margin_values.bottom,
            margins.top_auto,
            margins.bottom_auto,
            area_height,
            child_size.height,
            0,
            0,
        );
        const logical_track_x = column_offsets.items[item.column.start];
        const track_x = if (node.style.writing_direction == .rtl)
            try finite(content.width - logical_track_x - area_width)
        else
            logical_track_x;
        const free_width = try finite(
            area_width - child_size.width - margin_values.left - margin_values.right,
        );
        const alignment_offset = alignOffset(justify_self, free_width, directions_match, true);
        const physical_alignment_offset = if (node.style.writing_direction == .rtl)
            free_width - alignment_offset
        else
            alignment_offset;
        const x = try add(
            track_x,
            try add(margin_values.left, physical_alignment_offset),
        );
        const free_height = try finite(
            area_height - child_size.height - margin_values.top - margin_values.bottom,
        );
        var y_offset: f32 = 0;
        if (align_self == .baseline) {
            y_offset = @max(0, item.baseline_shim);
        } else {
            y_offset = alignOffset(align_self, free_height, directions_match, false);
        }
        const logical_y = try add(
            row_offsets.items[item.row.start],
            try add(
                margin_values.top,
                y_offset,
            ),
        );
        child.rect = .{
            .x = x,
            .y = logical_y,
            .w = child_size.width,
            .h = child_size.height,
        };
        try relativeInsets(child, content);
        try checkRect(child.rect);
        if (options.context) |context| {
            if (child.children.items.len == 0 or child.style.display != .grid) {
                try context.layout_node(
                    context,
                    tree,
                    child,
                    .{
                        .available = .{ .width = area_width, .height = area_height },
                        .percentage_basis = .{
                            .width = area_width,
                            .height = area_height,
                        },
                        .border = .{
                            .width = child.rect.w,
                            .height = child.rect.h,
                        },
                    },
                );
                continue;
            }
        }
        if (child.children.items.len != 0) {
            try layoutGridNode(
                tree,
                item.index,
                .{ .width = area_width, .height = area_height },
                child_size,
                options,
                depth - 1,
            );
        }
    }
    try writeGridBaseline(tree, node, items.items, content, edges, options.context);

    try placeAbsolute(
        tree,
        node,
        .{ .width = content.width, .height = final_content_height },
        edges,
        placement_origins,
        explicit_columns,
        explicit_rows,
        columns.items,
        rows.items,
        column_offsets.items,
        row_offsets.items,
        node.style.writing_direction,
        options,
        depth - 1,
    );

    const pad_box: widget.Size = .{
        .width = @max(0, try finite(node.rect.w - edges.border.left - edges.border.right)),
        .height = @max(0, try finite(node.rect.h - edges.border.top - edges.border.bottom)),
    };
    try publishContentSize(tree, node, pad_box, edges);
}

fn baselineAligned(
    child: *const widget.WidgetNode,
    container: *const widget.WidgetNode,
) bool {
    const directions_match = child.style.writing_direction == container.style.writing_direction;
    return alignValue(
        child.style.grid_align_self,
        effectiveAlignItems(container.style),
        directions_match,
        false,
    ) == .baseline;
}

fn prepareBaselineChild(
    tree: *widget.WidgetTree,
    item: FlowItem,
    area: widget.Size,
    child_size: widget.Size,
    options: Options,
    depth: usize,
) Error!void {
    const child = &tree.nodes.items[item.index];
    if (child.children.items.len == 0) return;
    if (depth == 0) return error.InvalidStyle;
    if (child.style.display == .grid) {
        try layoutGridNode(tree, item.index, area, child_size, options, depth - 1);
    } else if (options.context) |context| {
        try context.layout_node(
            context,
            tree,
            child,
            .{
                .available = area,
                .percentage_basis = .{
                    .width = area.width,
                    .height = area.height,
                },
                .border = .{
                    .width = child_size.width,
                    .height = child_size.height,
                },
            },
        );
    }
}

fn resolveIntrinsicBaselineShims(
    tree: *widget.WidgetTree,
    container: *widget.WidgetNode,
    items: []FlowItem,
    content: widget.Size,
    options: Options,
    depth: usize,
) Error!void {
    var row_counts: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    defer row_counts.deinit(options.allocator);
    var row_max_ascent: std.AutoHashMapUnmanaged(usize, f32) = .empty;
    defer row_max_ascent.deinit(options.allocator);
    for (items) |*item| {
        item.baseline = null;
        item.baseline_margin_top = 0;
        item.baseline_shim = 0;
        const child = &tree.nodes.items[item.index];
        if (!baselineAligned(child, container)) continue;
        const count = row_counts.get(item.row.start) orelse 0;
        const next = std.math.add(usize, count, 1) catch return error.InvalidStyle;
        try row_counts.put(options.allocator, item.row.start, next);
    }
    for (items) |*item| {
        const count = row_counts.get(item.row.start) orelse 0;
        if (count <= 1) continue;
        const child = &tree.nodes.items[item.index];
        const child_edges = try resolveEdges(child.style, content.width);
        try prepareBaselineChild(tree, item.*, content, item.natural.border, options, depth);
        const baseline = try nodeFirstBaseline(
            tree,
            item.index,
            item.natural.border,
            child_edges,
            options.context,
        );
        item.baseline = baseline;
        item.baseline_margin_top = item.margins.value.top;
        const ascent = try add(item.margins.value.top, baseline);
        const current = row_max_ascent.get(item.row.start) orelse 0;
        if (ascent > current) {
            try row_max_ascent.put(options.allocator, item.row.start, ascent);
        }
    }
    for (items) |*item| {
        const count = row_counts.get(item.row.start) orelse 0;
        if (count <= 1) continue;
        const child = &tree.nodes.items[item.index];
        if (!baselineAligned(child, container)) continue;
        const baseline = item.baseline orelse 0;
        const ascent = try add(item.baseline_margin_top, baseline);
        const max_ascent = row_max_ascent.get(item.row.start) orelse ascent;
        item.baseline_shim = @max(0, max_ascent - ascent);
    }
}
fn resolveFinalNatural(
    tree: *widget.WidgetTree,
    item: FlowItem,
    area: widget.Size,
    options: Options,
    depth: usize,
    parent_display: style.Display,
) Error!Natural {
    const child = &tree.nodes.items[item.index];
    var resolved_natural = item.natural;
    const final_request: layout_context.Request = .{
        .available = area,
        .percentage_basis = .{
            .width = area.width,
            .height = area.height,
        },
        .width_mode = .definite,
        .height_mode = .definite,
        .sizing_mode = .inherent,
        .known_border = .{ .width = null, .height = null },
    };
    if (child.children.items.len == 0) {
        const margins = try resolveMargins(child.style, area.width);
        const child_edges = try resolveEdges(child.style, area.width);
        const provisional_size = try usedSize(
            child.style,
            .{ .width = area.width, .height = area.height },
            resolved_natural.content,
            child_edges,
            null,
        );
        var leaf_request = final_request;
        leaf_request.available = .{
            .width = @min(
                @max(
                    0,
                    area.width - margins.value.left - margins.value.right,
                ),
                @max(0, provisional_size.width - child_edges.horizontal),
            ),
            .height = @min(
                @max(
                    0,
                    area.height - margins.value.top - margins.value.bottom,
                ),
                @max(0, provisional_size.height - child_edges.vertical),
            ),
        };
        resolved_natural = try measureNode(
            tree,
            item.index,
            leaf_request,
            options,
            depth - 1,
            parent_display,
            false,
            .{},
        );
    } else if (child.style.display != .grid) {
        if (options.context) |context| {
            resolved_natural = try crossLayoutNatural(
                context,
                tree,
                child,
                final_request,
            );
        }
    } else if (hasPercentageContribution(child.style, .columns) or
        hasPercentageContribution(child.style, .rows))
    {
        resolved_natural = try measureNode(
            tree,
            item.index,
            final_request,
            options,
            depth - 1,
            parent_display,
            true,
            .{},
        );
    }
    return resolved_natural;
}

const FinalChildMetrics = struct {
    edges: Edges,
    margin_values: style.Sides,
    size: widget.Size,
};

fn finalChildMetrics(
    tree: *widget.WidgetTree,
    container: *const widget.WidgetNode,
    item: FlowItem,
    area: widget.Size,
    options: Options,
    depth: usize,
) Error!FinalChildMetrics {
    const child = &tree.nodes.items[item.index];
    const resolved_natural = try resolveFinalNatural(
        tree,
        item,
        area,
        options,
        depth,
        container.style.display,
    );
    const child_edges = try resolveEdges(child.style, area.width);
    const margins = try resolveMargins(child.style, area.width);
    const directions_match = child.style.writing_direction == container.style.writing_direction;
    const justify_self = alignValue(
        child.style.grid_justify_self,
        effectiveJustifyItems(container.style),
        directions_match,
        true,
    );
    const align_self = alignValue(
        child.style.grid_align_self,
        effectiveAlignItems(container.style),
        directions_match,
        false,
    );
    var child_size = try usedSize(
        child.style,
        .{ .width = area.width, .height = area.height },
        resolved_natural.content,
        child_edges,
        null,
    );
    const stretch_width = dimensionAuto(child.style.size.width) and justify_self == .stretch and
        !margins.left_auto and !margins.right_auto and
        !(child.style.aspect_ratio != null and !dimensionAuto(child.style.size.height));
    if (stretch_width) {
        child_size.width = try clampAxisSize(
            child.style,
            .horizontal,
            @max(0, area.width - margins.value.left - margins.value.right),
            .{ .width = area.width, .height = area.height },
            resolved_natural.content,
            child_edges,
        );
    }
    const stretch_height = dimensionAuto(child.style.size.height) and align_self == .stretch and
        !margins.top_auto and !margins.bottom_auto and
        !(child.style.aspect_ratio != null and !dimensionAuto(child.style.size.width));
    if (stretch_height) {
        child_size.height = try clampAxisSize(
            child.style,
            .vertical,
            @max(0, area.height - margins.value.top - margins.value.bottom),
            .{ .width = area.width, .height = area.height },
            resolved_natural.content,
            child_edges,
        );
    }
    child_size = try reapplyAspectRatio(
        child.style,
        child_size,
        .{ .width = area.width, .height = area.height },
        resolved_natural.content,
        child_edges,
    );
    var margin_values = margins.value;
    try distributeAbsoluteAutoMargins(
        &margin_values.left,
        &margin_values.right,
        margins.left_auto,
        margins.right_auto,
        area.width,
        child_size.width,
        0,
        0,
    );
    try distributeAbsoluteAutoMargins(
        &margin_values.top,
        &margin_values.bottom,
        margins.top_auto,
        margins.bottom_auto,
        area.height,
        child_size.height,
        0,
        0,
    );
    return .{
        .edges = child_edges,
        .margin_values = margin_values,
        .size = child_size,
    };
}

fn resolveFinalBaselineShims(
    tree: *widget.WidgetTree,
    container: *widget.WidgetNode,
    items: []FlowItem,
    columns: []const Track,
    rows: []const Track,
    column_gap: f32,
    row_gap: f32,
    column_extra_gap: f32,
    row_extra_gap: f32,
    options: Options,
    depth: usize,
) Error!void {
    var row_counts: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    defer row_counts.deinit(options.allocator);
    var row_max_ascent: std.AutoHashMapUnmanaged(usize, f32) = .empty;
    defer row_max_ascent.deinit(options.allocator);
    for (items) |*item| {
        item.baseline = null;
        item.baseline_margin_top = 0;
        item.baseline_shim = 0;
        const child = &tree.nodes.items[item.index];
        if (!baselineAligned(child, container)) continue;
        const count = row_counts.get(item.row.start) orelse 0;
        const next = std.math.add(usize, count, 1) catch return error.InvalidStyle;
        try row_counts.put(options.allocator, item.row.start, next);
    }
    for (items) |*item| {
        const count = row_counts.get(item.row.start) orelse 0;
        if (count <= 1) continue;
        const area_width = try trackSpanTotal(
            columns,
            item.column.start,
            item.column.end,
            try add(column_gap, column_extra_gap),
        );
        const area_height = try trackSpanTotal(
            rows,
            item.row.start,
            item.row.end,
            try add(row_gap, row_extra_gap),
        );
        const metrics = try finalChildMetrics(
            tree,
            container,
            item.*,
            .{ .width = area_width, .height = area_height },
            options,
            depth,
        );
        try prepareBaselineChild(
            tree,
            item.*,
            .{ .width = area_width, .height = area_height },
            metrics.size,
            options,
            depth,
        );
        item.baseline_margin_top = metrics.margin_values.top;
        const baseline = try nodeFirstBaseline(
            tree,
            item.index,
            metrics.size,
            metrics.edges,
            options.context,
        );
        item.baseline = baseline;
        const ascent = try add(metrics.margin_values.top, baseline);
        const current = row_max_ascent.get(item.row.start) orelse 0;
        if (ascent > current) {
            try row_max_ascent.put(options.allocator, item.row.start, ascent);
        }
    }
    for (items) |*item| {
        const count = row_counts.get(item.row.start) orelse 0;
        if (count <= 1) continue;
        const child = &tree.nodes.items[item.index];
        if (!baselineAligned(child, container)) continue;
        const baseline = item.baseline orelse 0;
        const ascent = try add(item.baseline_margin_top, baseline);
        const max_ascent = row_max_ascent.get(item.row.start) orelse ascent;
        item.baseline_shim = @max(0, max_ascent - ascent);
    }
}
fn automaticMinimumDimension(
    preferred: style.Dimension,
    minimum: style.Dimension,
    deferred: bool,
) bool {
    const preferred_auto = preferred == .auto or (deferred and preferred == .percent);
    const minimum_auto = minimum == .auto or (deferred and minimum == .percent);
    return preferred_auto and minimum_auto;
}
fn tracksHaveDefiniteArea(tracks: []const Track, basis: ?f32) bool {
    if (tracks.len == 0) return false;
    for (tracks) |track| {
        if (!trackMinimumIsDefinite(track.spec, basis) or
            !trackHasDefiniteMaximum(track.spec, basis))
        {
            return false;
        }
    }
    return true;
}

fn collectItems(
    tree: *widget.WidgetTree,
    container: *widget.WidgetNode,
    request: layout_context.Request,
    columns: []const Track,
    explicit_columns: usize,
    explicit_rows: usize,
    options: Options,
    depth: usize,
    items: *std.ArrayList(FlowItem),
) Error!void {
    for (container.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        const child = &tree.nodes.items[child_index];
        if (child.layout_hidden or child.style.position == .absolute) continue;
        const defer_width = hasPercentageContribution(child.style, .columns) and
            !tracksHaveDefiniteArea(columns, request.percentage_basis.width);
        const defer_height = request.percentage_basis.height == null and
            hasPercentageContribution(child.style, .rows);
        var child_req = request;
        child_req.sizing_mode = .inherent;
        child_req.known_border = .{ .width = null, .height = null };
        if (defer_width) child_req.percentage_basis.width = null;
        if (defer_height) child_req.percentage_basis.height = null;
        child_req.width_mode = if (defer_width)
            .max_content
        else
            modeForDimension(
                child.style.size.width,
                request.width_mode,
                request.percentage_basis.width,
            );
        child_req.height_mode = if (defer_height)
            .max_content
        else
            modeForDimension(
                child.style.size.height,
                request.height_mode,
                request.percentage_basis.height,
            );
        const natural = blk: {
            const original_style = child.style;
            child.style = intrinsicContributionStyle(
                original_style,
                defer_width,
                defer_height,
            );
            defer child.style = original_style;
            break :blk try measureNode(
                tree,
                child_index,
                child_req,
                options,
                depth,
                container.style.display,
                child_req.width_mode == .definite,
                .{ .width = defer_width, .height = defer_height },
            );
        };
        const margins = try resolveMargins(child.style, null);
        const row_line = gridLineFor(child.style, .rows);
        const column_line = gridLineFor(child.style, .columns);
        const row = try placementFor(row_line, explicit_rows);
        const column = try placementFor(column_line, explicit_columns);
        try items.append(options.allocator, .{
            .index = child_index,
            .row = row,
            .column = column,
            .natural = natural,
            .margins = margins,
            .overflow = child.style.overflow,
            .automatic_min_width = automaticMinimumDimension(
                child.style.size.width,
                child.style.min_size.width,
                defer_width,
            ),
            .automatic_min_height = automaticMinimumDimension(
                child.style.size.height,
                child.style.min_size.height,
                defer_height,
            ),
        });
    }
}

fn definiteTrackSpanMaximum(
    tracks: []const Track,
    start: usize,
    end: usize,
    gap: f32,
    basis: ?f32,
) Error!?f32 {
    if (start >= end or end > tracks.len) return error.InvalidStyle;
    var result: f32 = 0;
    var visible_count: usize = 0;
    for (tracks[start..end]) |track| {
        if (track.collapsed) continue;
        if (!trackHasDefiniteMaximum(track.spec, basis)) return null;
        const maximum = (try trackMaximum(track.spec, basis)) orelse
            return error.InvalidStyle;
        if (visible_count != 0) result = try add(result, gap);
        result = try add(result, maximum);
        visible_count += 1;
    }
    const finite_result: f32 = try finiteNonNegative(result);
    return finite_result;
}

fn remeasureItemsForColumns(
    tree: *widget.WidgetTree,
    container: *widget.WidgetNode,
    items: []FlowItem,
    columns: []const Track,
    rows: []const Track,
    row_gap: f32,
    request: layout_context.Request,
    options: Options,
    depth: usize,
) Error!void {
    for (items) |*item| {
        if (item.column.start >= item.column.end or item.column.end > columns.len) {
            return error.InvalidStyle;
        }
        if (tracksHaveDefiniteArea(
            columns[item.column.start..item.column.end],
            request.percentage_basis.width,
        )) continue;
        const area_height = (try definiteTrackSpanMaximum(
            rows,
            item.row.start,
            item.row.end,
            row_gap,
            request.percentage_basis.height,
        )) orelse continue;
        const child = &tree.nodes.items[item.index];
        const original_style = child.style;
        var child_request = request;
        child_request.sizing_mode = .inherent;
        child_request.known_border = .{ .width = null, .height = null };
        child_request.available.height = @max(
            0,
            area_height - item.margins.value.top - item.margins.value.bottom,
        );
        child_request.percentage_basis.height = area_height;
        child_request.height_mode = .definite;
        const defer_width = hasPercentageContribution(child.style, .columns);
        if (defer_width or child.style.size.width == .auto) {
            if (defer_width) child_request.percentage_basis.width = null;
            child_request.width_mode = .max_content;
        }
        child.style = intrinsicContributionStyle(
            original_style,
            defer_width,
            false,
        );
        defer child.style = original_style;
        const natural = try measureNode(
            tree,
            item.index,
            child_request,
            options,
            depth,
            container.style.display,
            child_request.width_mode == .definite,
            .{ .width = defer_width, .height = false },
        );
        item.automatic_min_width = automaticMinimumDimension(
            original_style.size.width,
            original_style.min_size.width,
            defer_width,
        );
        item.natural = natural;
    }
}

fn remeasureItemsForRows(
    tree: *widget.WidgetTree,
    container: *widget.WidgetNode,
    items: []FlowItem,
    columns: []const Track,
    column_gap: f32,
    request: layout_context.Request,
    options: Options,
    depth: usize,
) Error!void {
    for (items) |*item| {
        const child = &tree.nodes.items[item.index];
        const area_width = try trackSpanTotal(
            columns,
            item.column.start,
            item.column.end,
            column_gap,
        );
        const original_style = child.style;
        const area_margins = try resolveMargins(original_style, area_width);
        var child_request = request;
        child_request.sizing_mode = .inherent;
        child_request.known_border = .{ .width = null, .height = null };
        child_request.available.width = @max(
            0,
            area_width - area_margins.value.left - area_margins.value.right,
        );
        child_request.percentage_basis.width = area_width;
        child_request.width_mode = .definite;
        const defer_height = hasPercentageContribution(child.style, .rows);
        if (defer_height or child.style.size.height == .auto) {
            if (defer_height) child_request.percentage_basis.height = null;
            child_request.height_mode = .max_content;
        }
        child.style = intrinsicContributionStyle(
            original_style,
            false,
            defer_height,
        );
        defer child.style = original_style;
        const natural = try measureNode(
            tree,
            item.index,
            child_request,
            options,
            depth,
            container.style.display,
            child_request.width_mode == .definite,
            .{ .width = false, .height = defer_height },
        );
        item.automatic_min_height = automaticMinimumDimension(
            original_style.size.height,
            original_style.min_size.height,
            defer_height,
        );
        item.natural = natural;
        item.margins = area_margins;
    }
}

fn gridLineFor(input: style.Style, axis: TrackAxis) style.GridLine {
    return switch (axis) {
        .columns => input.grid_column,
        .rows => input.grid_row,
    };
}
fn placementFor(line: style.GridLine, explicit_count: usize) Error!AxisPlacement {
    const start_line = try placementLine(line.start, explicit_count);
    const end_line = try placementLine(line.end, explicit_count);
    const start_span = try placementSpan(line.start);
    const end_span = try placementSpan(line.end);

    var logical_start: i128 = 0;
    var logical_end: i128 = 1;
    if (start_line) |start| {
        logical_start = start;
        logical_end = if (end_line) |end|
            end
        else
            try addLineSpan(start, end_span);
    } else if (end_line) |end| {
        logical_end = end;
        logical_start = try subtractLineSpan(end, start_span);
    } else {
        logical_end = @intCast(start_span);
    }

    if (logical_end < logical_start) {
        const old_start = logical_start;
        logical_start = logical_end;
        logical_end = old_start;
    }
    if (logical_end == logical_start) {
        logical_end = try addLineSpan(logical_start, 1);
    }

    return .{
        .definite = start_line != null or end_line != null,
        .logical_start = logical_start,
        .logical_end = logical_end,
    };
}

fn placementLine(value: style.GridPlacement, explicit_count: usize) Error!?i128 {
    return switch (value) {
        .auto, .span => null,
        .line => |line| blk: {
            if (line == 0) break :blk error.InvalidStyle;
            const explicit_line_count: i128 = std.math.add(
                i128,
                @intCast(explicit_count),
                1,
            ) catch return error.InvalidStyle;
            const raw = if (line > 0)
                std.math.sub(i128, @as(i128, line), 1) catch
                    return error.InvalidStyle
            else
                std.math.add(i128, explicit_line_count, @as(i128, line)) catch
                    return error.InvalidStyle;
            break :blk raw;
        },
    };
}

fn placementSpan(value: style.GridPlacement) Error!usize {
    return switch (value) {
        .span => |span| if (span == 0) error.InvalidStyle else @as(usize, span),
        .auto, .line => 1,
    };
}

fn addLineSpan(line: i128, span: usize) Error!i128 {
    return std.math.add(i128, line, @as(i128, @intCast(span))) catch
        error.InvalidStyle;
}

fn subtractLineSpan(line: i128, span: usize) Error!i128 {
    return std.math.sub(i128, line, @as(i128, @intCast(span))) catch
        error.InvalidStyle;
}

const TrackDepthFrame = struct {
    tracks: []const style.GridTrack,
    next: usize,
    depth: usize,
};

fn trackDepth(
    allocator: std.mem.Allocator,
    tracks: []const style.GridTrack,
) Error!usize {
    var has_nested_tracks = false;
    for (tracks) |track| {
        switch (track) {
            .repeat => |repeat| {
                if (repeat.tracks.len != 0) {
                    has_nested_tracks = true;
                    break;
                }
            },
            else => {},
        }
    }
    if (!has_nested_tracks) return 1;

    var stack: std.ArrayList(TrackDepthFrame) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .tracks = tracks, .next = 0, .depth = 1 });
    var maximum: usize = 1;
    while (stack.items.len != 0) {
        const frame_index = stack.items.len - 1;
        if (stack.items[frame_index].next == stack.items[frame_index].tracks.len) {
            _ = stack.pop();
            continue;
        }
        const track_index = stack.items[frame_index].next;
        const track = stack.items[frame_index].tracks[track_index];
        stack.items[frame_index].next = std.math.add(usize, track_index, 1) catch
            return error.InvalidStyle;
        switch (track) {
            .repeat => |repeat| {
                if (repeat.tracks.len == 0) continue;
                for (stack.items) |ancestor| {
                    if (repeat.tracks.ptr == ancestor.tracks.ptr and
                        repeat.tracks.len == ancestor.tracks.len)
                    {
                        return error.InvalidStyle;
                    }
                }
                const next_depth = std.math.add(
                    usize,
                    stack.items[frame_index].depth,
                    1,
                ) catch return error.InvalidStyle;
                maximum = @max(maximum, next_depth);
                try stack.append(allocator, .{
                    .tracks = repeat.tracks,
                    .next = 0,
                    .depth = next_depth,
                });
            },
            else => {},
        }
    }
    return maximum;
}

fn initTracks(
    allocator: std.mem.Allocator,
    tracks: *std.ArrayList(Track),
    explicit: []const style.GridTrack,
    auto_tracks: []const style.GridTrack,
    basis: ?f32,
    repeat_strategy: AutoRepeatStrategy,
    gap: f32,
) Error!usize {
    const source = if (explicit.len == 0) auto_tracks else explicit;
    if (source.len == 0) return error.InvalidStyle;
    const depth = try trackDepth(allocator, source);
    for (source, 0..) |spec, source_index| {
        try appendExpandedTrack(
            allocator,
            tracks,
            spec,
            basis,
            repeat_strategy,
            gap,
            false,
            depth,
            source,
            source_index,
        );
    }
    if (explicit.len == 0) {
        for (tracks.items) |*track| track.implicit_auto = true;
    }
    if (tracks.items.len == 0) return error.InvalidStyle;
    return @max(@as(usize, 1), tracks.items.len);
}

fn appendExpandedTrack(
    allocator: std.mem.Allocator,
    tracks: *std.ArrayList(Track),
    spec: style.GridTrack,
    basis: ?f32,
    repeat_strategy: AutoRepeatStrategy,
    gap: f32,
    auto_fit: bool,
    depth: usize,
    template: []const style.GridTrack,
    template_index: usize,
) Error!void {
    if (depth == 0) return error.InvalidStyle;
    switch (spec) {
        .repeat => |repeat| {
            if (repeat.tracks.len == 0) return error.InvalidStyle;
            const collapse = auto_fit or repeat.kind == .auto_fit;
            const repeat_count = try repetitionCount(
                template,
                template_index,
                repeat,
                basis,
                repeat_strategy,
                gap,
                depth,
            );
            var repetition: usize = 0;
            while (repetition < repeat_count) : (repetition += 1) {
                for (repeat.tracks, 0..) |nested, nested_index| {
                    try appendExpandedTrack(
                        allocator,
                        tracks,
                        nested,
                        basis,
                        repeat_strategy,
                        gap,
                        collapse,
                        depth - 1,
                        repeat.tracks,
                        nested_index,
                    );
                }
            }
        },
        else => {
            const size = try trackMinimum(spec, basis);
            const growth = try initialGrowthLimit(spec, basis);
            try tracks.append(allocator, .{
                .spec = spec,
                .size = size,
                .intrinsic_growth_limit = if (growth) |limit| @max(size, limit) else null,
                .auto_fit = auto_fit,
            });
        },
    }
}

fn initialGrowthLimit(spec: style.GridTrack, basis: ?f32) Error!?f32 {
    return switch (spec) {
        .fixed => |value| @as(?f32, try finiteNonNegative(value)),
        .percent => |fraction| if (basis) |size|
            @as(?f32, try finiteNonNegative(try finite(fraction * size)))
        else
            null,
        .minmax => |value| blk: {
            const minimum = try breadthMinimum(value.min, basis);
            const maximum = switch (value.max) {
                .fixed => |fixed| @as(?f32, try finiteNonNegative(fixed)),
                .percent => |fraction| if (basis) |size|
                    @as(?f32, try finiteNonNegative(try finite(fraction * size)))
                else
                    null,
                .auto, .min_content, .max_content, .fr, .fit_content => null,
            };
            break :blk if (maximum) |limit| @max(minimum, limit) else null;
        },
        .auto, .min_content, .max_content, .fr, .fit_content, .repeat => null,
    };
}

fn repetitionCount(
    template: []const style.GridTrack,
    template_index: usize,
    repeat: style.GridRepeat,
    basis: ?f32,
    strategy: AutoRepeatStrategy,
    gap: f32,
    depth: usize,
) Error!usize {
    if (depth == 0 or repeat.tracks.len == 0 or template_index >= template.len) {
        return error.InvalidStyle;
    }
    return switch (repeat.kind) {
        .count => |count| @as(usize, count),
        .auto_fill, .auto_fit => blk: {
            const available = basis orelse break :blk @as(usize, 1);
            const prefix = template[0..template_index];
            const suffix = template[template_index + 1 ..];
            const prefix_count = try trackListCount(prefix, depth);
            const suffix_count = try trackListCount(suffix, depth);
            const fragment_count = try trackListCount(repeat.tracks, depth - 1);
            if (fragment_count == 0) break :blk @as(usize, 1);
            const prefix_used = try trackListMinimum(prefix, basis, depth);
            const suffix_used = try trackListMinimum(suffix, basis, depth);
            const fragment_used = try trackListMinimum(repeat.tracks, basis, depth - 1);
            const fragment_and_suffix_count = std.math.add(
                usize,
                fragment_count,
                suffix_count,
            ) catch return error.InvalidStyle;
            const first_track_count = std.math.add(
                usize,
                prefix_count,
                fragment_and_suffix_count,
            ) catch return error.InvalidStyle;
            const first_gap_count = std.math.sub(usize, first_track_count, 1) catch
                return error.InvalidStyle;
            const first_gaps = try finite(
                gap * (try countToF32(first_gap_count)),
            );
            const first_used = try add(
                try add(prefix_used, fragment_used),
                try add(suffix_used, first_gaps),
            );
            if (first_used > available) break :blk @as(usize, 1);

            const per_repetition = @max(
                @as(f32, 1),
                try add(
                    fragment_used,
                    try finite(gap * (try countToF32(fragment_count))),
                ),
            );

            const unrounded_extra = @max(0, available - first_used) / per_repetition;
            const extra = switch (strategy) {
                .max_repetitions_that_fit => @floor(unrounded_extra),
                .min_repetitions_that_overflow => @ceil(unrounded_extra),
            };
            if (!std.math.isFinite(extra) or extra < 0) return error.InvalidStyle;
            if (extra > 16_777_216.0) return error.InvalidStyle;
            const extra_count: usize = @intFromFloat(extra);
            break :blk std.math.add(usize, extra_count, 1) catch
                return error.InvalidStyle;
        },
    };
}
fn autoRepeatTrackMinimum(track: style.GridTrack, basis: ?f32) Error!f32 {
    return switch (track) {
        .minmax => |value| blk: {
            const minimum = try breadthMinimum(value.min, basis);
            const maximum = try breadthMaximum(value.max, basis);
            break :blk if (maximum) |limit|
                @max(minimum, try finiteNonNegative(limit))
            else
                minimum;
        },
        else => trackMinimum(track, basis),
    };
}

fn trackListCount(tracks: []const style.GridTrack, depth: usize) Error!usize {
    if (depth == 0) return error.InvalidStyle;
    var count: usize = 0;
    for (tracks) |track| {
        const addition: usize = switch (track) {
            .repeat => |repeat| blk: {
                const nested = try trackListCount(repeat.tracks, depth - 1);
                const repetitions = switch (repeat.kind) {
                    .count => |value| @as(usize, value),
                    .auto_fill, .auto_fit => 1,
                };
                break :blk std.math.mul(usize, nested, repetitions) catch
                    return error.InvalidStyle;
            },
            else => 1,
        };
        count = std.math.add(usize, count, addition) catch
            return error.InvalidStyle;
    }
    return count;
}

fn trackListMinimum(
    tracks: []const style.GridTrack,
    basis: ?f32,
    depth: usize,
) Error!f32 {
    if (depth == 0) return error.InvalidStyle;
    var result: f32 = 0;
    for (tracks) |track| {
        const contribution = switch (track) {
            .repeat => |repeat| blk: {
                const nested = try trackListMinimum(repeat.tracks, basis, depth - 1);
                const repetitions = switch (repeat.kind) {
                    .count => |value| @as(usize, value),
                    .auto_fill, .auto_fit => 1,
                };
                break :blk try finite(nested * (try countToF32(repetitions)));
            },
            else => try autoRepeatTrackMinimum(track, basis),
        };
        result = try add(result, contribution);
    }
    return result;
}

const PlacementOrigins = struct {
    column_prepend: usize = 0,
    row_prepend: usize = 0,
};

fn ensureTracks(
    allocator: std.mem.Allocator,
    tracks: *std.ArrayList(Track),
    count: usize,
    auto_tracks: []const style.GridTrack,
    basis: ?f32,
) Error!void {
    if (tracks.items.len >= count) return;
    if (auto_tracks.len == 0) return error.InvalidStyle;
    const depth = try trackDepth(allocator, auto_tracks);
    const target = count;
    var source_index: usize = 0;
    for (tracks.items) |track| {
        if (track.implicit_auto) {
            source_index = std.math.add(usize, source_index, 1) catch
                return error.InvalidStyle;
        }
    }
    while (tracks.items.len < target) {
        const spec = auto_tracks[source_index % auto_tracks.len];
        const before = tracks.items.len;
        try appendExpandedTrack(
            allocator,
            tracks,
            spec,
            basis,
            .max_repetitions_that_fit,
            0,
            false,
            depth,
            auto_tracks,
            source_index % auto_tracks.len,
        );
        if (tracks.items.len == before) return error.InvalidStyle;
        if (tracks.items.len > target) tracks.items.len = target;
        for (tracks.items[before..]) |*track| track.implicit_auto = true;
        source_index = std.math.add(
            usize,
            source_index,
            tracks.items.len - before,
        ) catch return error.InvalidStyle;
    }
}

fn prependTracks(
    allocator: std.mem.Allocator,
    tracks: *std.ArrayList(Track),
    count: usize,
    auto_tracks: []const style.GridTrack,
    basis: ?f32,
) Error!void {
    if (count == 0) return;
    if (auto_tracks.len == 0) return error.InvalidStyle;
    const new_count = std.math.add(usize, tracks.items.len, count) catch
        return error.InvalidStyle;
    const depth = try trackDepth(allocator, auto_tracks);
    const implicit_track = try firstConcreteTrack(
        try prependTrackAt(auto_tracks, count, 0),
        depth,
    );

    const first_size = try trackMinimum(implicit_track, basis);
    const first_growth = try initialGrowthLimit(implicit_track, basis);
    const first: Track = .{
        .spec = implicit_track,
        .size = first_size,
        .intrinsic_growth_limit = if (first_growth) |limit| @max(first_size, limit) else null,
    };
    try tracks.ensureUnusedCapacity(allocator, count);
    const old_count = tracks.items.len;
    tracks.items.len = new_count;
    @memmove(tracks.items[count..], tracks.items[0..old_count]);
    tracks.items[0] = first;
    var index: usize = 1;
    while (index < count) : (index += 1) {
        const spec = try firstConcreteTrack(
            try prependTrackAt(auto_tracks, count, index),
            depth,
        );
        const size = try trackMinimum(spec, basis);
        const growth = try initialGrowthLimit(spec, basis);
        tracks.items[index] = .{
            .spec = spec,
            .size = size,
            .intrinsic_growth_limit = if (growth) |limit| @max(size, limit) else null,
        };
    }
}

fn firstConcreteTrack(spec: style.GridTrack, depth: usize) Error!style.GridTrack {
    var current = spec;
    var remaining = depth;
    while (true) {
        if (remaining == 0) return error.InvalidStyle;
        switch (current) {
            .repeat => |repeat| {
                if (repeat.tracks.len == 0) return error.InvalidStyle;
                current = repeat.tracks[0];
                remaining -= 1;
            },
            else => return current,
        }
    }
}

fn prependTrackAt(
    auto_tracks: []const style.GridTrack,
    count: usize,
    index: usize,
) Error!style.GridTrack {
    if (auto_tracks.len == 0) return error.InvalidStyle;
    const offset = (auto_tracks.len - (count % auto_tracks.len)) % auto_tracks.len;
    const wrapped_index = index % auto_tracks.len;
    const selected = if (wrapped_index == 0)
        offset
    else if (offset >= auto_tracks.len - wrapped_index)
        offset - (auto_tracks.len - wrapped_index)
    else
        offset + wrapped_index;
    return auto_tracks[selected];
}

fn shiftPlacementIndices(
    placement: *AxisPlacement,
    prepend: usize,
) Error!void {
    if (!placement.definite) {
        const span_distance = std.math.sub(
            i128,
            placement.logical_end,
            placement.logical_start,
        ) catch return error.InvalidStyle;
        if (span_distance <= 0) return error.InvalidStyle;
        const span = std.math.cast(usize, span_distance) orelse
            return error.InvalidStyle;
        placement.start = 0;
        placement.end = span;
        return;
    }
    placement.start = try shiftedLineIndex(placement.logical_start, prepend);
    placement.end = try shiftedLineIndex(placement.logical_end, prepend);
    if (placement.end <= placement.start) return error.InvalidStyle;
}

fn shiftedLineIndex(line: i128, prepend: usize) Error!usize {
    const shifted = std.math.add(i128, line, @as(i128, @intCast(prepend))) catch
        return error.InvalidStyle;
    if (shifted <= 0) return 0;
    return std.math.cast(usize, shifted) orelse error.InvalidStyle;
}

fn normalizeAxisPlacements(
    allocator: std.mem.Allocator,
    tracks: *std.ArrayList(Track),
    items: []FlowItem,
    axis: TrackAxis,
    auto_tracks: []const style.GridTrack,
    basis: ?f32,
) Error!usize {
    var minimum_start: i128 = 0;
    for (items) |item| {
        const placement = switch (axis) {
            .columns => item.column,
            .rows => item.row,
        };
        if (placement.definite and placement.logical_start < minimum_start) {
            minimum_start = placement.logical_start;
        }
    }
    const prepend: usize = if (minimum_start < 0)
        std.math.cast(usize, -minimum_start) orelse return error.InvalidStyle
    else
        0;
    try prependTracks(allocator, tracks, prepend, auto_tracks, basis);
    for (items) |*item| {
        switch (axis) {
            .columns => try shiftPlacementIndices(&item.column, prepend),
            .rows => try shiftPlacementIndices(&item.row, prepend),
        }
    }
    return prepend;
}

fn placeItems(
    allocator: std.mem.Allocator,
    columns: *std.ArrayList(Track),
    rows: *std.ArrayList(Track),
    items: *std.ArrayList(FlowItem),
    flow: style.GridAutoFlow,
    auto_columns: []const style.GridTrack,
    auto_rows: []const style.GridTrack,
    column_basis: ?f32,
    row_basis: ?f32,
    occupied: *Occupancy,
) Error!PlacementOrigins {
    const origins: PlacementOrigins = .{
        .column_prepend = try normalizeAxisPlacements(
            allocator,
            columns,
            items.items,
            .columns,
            auto_columns,
            column_basis,
        ),
        .row_prepend = try normalizeAxisPlacements(
            allocator,
            rows,
            items.items,
            .rows,
            auto_rows,
            row_basis,
        ),
    };
    const dense = flow == .row_dense or flow == .column_dense;
    const row_flow = flow == .row or flow == .row_dense;
    var partial_primary_cursors: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    defer partial_primary_cursors.deinit(allocator);

    for (items.items) |*item| {
        if (!item.row.definite or !item.column.definite) continue;
        const row_span = try placementSpanIndices(item.row);
        const column_span = try placementSpanIndices(item.column);
        try ensureTracks(allocator, rows, item.row.end, auto_rows, row_basis);
        try ensureTracks(allocator, columns, item.column.end, auto_columns, column_basis);
        try markArea(
            allocator,
            occupied,
            item.row.start,
            item.column.start,
            row_span,
            column_span,
        );
    }

    for (items.items) |*item| {
        if (item.row.definite == item.column.definite) continue;
        const secondary_axis_definite = if (row_flow) item.row.definite else item.column.definite;
        if (!secondary_axis_definite) continue;
        const secondary_start = if (row_flow) item.row.start else item.column.start;
        var cursor_row: usize = 0;
        var cursor_column: usize = 0;
        if (!dense) {
            if (partial_primary_cursors.get(secondary_start)) |primary_cursor| {
                if (row_flow) {
                    cursor_column = primary_cursor;
                } else {
                    cursor_row = primary_cursor;
                }
            }
        }
        try placeItem(
            allocator,
            columns,
            rows,
            item,
            flow,
            dense,
            auto_columns,
            auto_rows,
            column_basis,
            row_basis,
            occupied,
            &cursor_row,
            &cursor_column,
        );
        if (!dense) {
            const primary_end = if (row_flow) item.column.end else item.row.end;
            const secondary_end = if (row_flow) item.row.end else item.column.end;
            if (secondary_end <= secondary_start) return error.InvalidStyle;
            for (secondary_start..secondary_end) |secondary_index| {
                const current = partial_primary_cursors.get(secondary_index) orelse 0;
                if (current < primary_end) {
                    try partial_primary_cursors.put(allocator, secondary_index, primary_end);
                }
            }
        }
    }

    if (row_flow) {
        try preSizePrimaryTracks(
            allocator,
            columns,
            items.items,
            .columns,
            auto_columns,
            column_basis,
        );
    } else {
        try preSizePrimaryTracks(
            allocator,
            rows,
            items.items,
            .rows,
            auto_rows,
            row_basis,
        );
    }

    var auto_cursor_row: usize = 0;
    var auto_cursor_column: usize = 0;
    for (items.items) |*item| {
        if (item.row.definite and item.column.definite) continue;
        const secondary_axis_definite = if (row_flow) item.row.definite else item.column.definite;
        if (secondary_axis_definite) continue;
        try placeItem(
            allocator,
            columns,
            rows,
            item,
            flow,
            dense,
            auto_columns,
            auto_rows,
            column_basis,
            row_basis,
            occupied,
            &auto_cursor_row,
            &auto_cursor_column,
        );
    }
    return origins;
}

fn placementSpanIndices(placement: AxisPlacement) Error!usize {
    if (placement.end <= placement.start) return error.InvalidStyle;
    return placement.end - placement.start;
}

fn preSizePrimaryTracks(
    allocator: std.mem.Allocator,
    tracks: *std.ArrayList(Track),
    items: []const FlowItem,
    axis: TrackAxis,
    auto_tracks: []const style.GridTrack,
    basis: ?f32,
) Error!void {
    var required = tracks.items.len;
    for (items) |item| {
        const placement = switch (axis) {
            .columns => item.column,
            .rows => item.row,
        };
        const span = try placementSpanIndices(placement);
        const extent = if (placement.definite) placement.end else span;
        required = @max(required, extent);
    }
    try ensureTracks(allocator, tracks, required, auto_tracks, basis);
}

fn placeItem(
    allocator: std.mem.Allocator,
    columns: *std.ArrayList(Track),
    rows: *std.ArrayList(Track),
    item: *FlowItem,
    flow: style.GridAutoFlow,
    dense: bool,
    auto_columns: []const style.GridTrack,
    auto_rows: []const style.GridTrack,
    column_basis: ?f32,
    row_basis: ?f32,
    occupied: *Occupancy,
    cursor_row: *usize,
    cursor_column: *usize,
) Error!void {
    const row_flow = flow == .row or flow == .row_dense;
    const row_span = try placementSpanIndices(item.row);
    const column_span = try placementSpanIndices(item.column);
    const max_attempts = try placementAttemptLimit(
        occupied.areas.items.len,
        rows.items.len,
        columns.items.len,
        row_span,
        column_span,
    );
    var candidate_row: usize = if (item.row.definite)
        item.row.start
    else if (dense)
        0
    else
        cursor_row.*;
    var candidate_column: usize = if (item.column.definite)
        item.column.start
    else if (dense)
        0
    else
        cursor_column.*;
    if (!dense) {
        if (row_flow and item.column.definite and !item.row.definite and
            candidate_column < cursor_column.*)
        {
            try incrementIndex(&candidate_row);
        } else if (!row_flow and item.row.definite and !item.column.definite and
            candidate_row < cursor_row.*)
        {
            try incrementIndex(&candidate_column);
        }
    }
    var attempts: usize = 0;
    while (attempts < max_attempts) : (attempts = std.math.add(
        usize,
        attempts,
        1,
    ) catch return error.InvalidStyle) {
        const candidate_row_end = try indexAdd(candidate_row, row_span);
        const candidate_column_end = try indexAdd(candidate_column, column_span);

        if (row_flow and !item.column.definite and candidate_column_end > columns.items.len) {
            if (item.row.definite or column_span > columns.items.len) {
                try ensureTracks(
                    allocator,
                    columns,
                    candidate_column_end,
                    auto_columns,
                    column_basis,
                );
            } else {
                try incrementIndex(&candidate_row);
                candidate_column = 0;
                continue;
            }
        }
        if (!row_flow and !item.row.definite and candidate_row_end > rows.items.len) {
            if (item.column.definite or row_span > rows.items.len) {
                try ensureTracks(
                    allocator,
                    rows,
                    candidate_row_end,
                    auto_rows,
                    row_basis,
                );
            } else {
                try incrementIndex(&candidate_column);
                candidate_row = 0;
                continue;
            }
        }

        if (candidate_row_end > rows.items.len) {
            try ensureTracks(allocator, rows, candidate_row_end, auto_rows, row_basis);
        }
        if (candidate_column_end > columns.items.len) {
            try ensureTracks(
                allocator,
                columns,
                candidate_column_end,
                auto_columns,
                column_basis,
            );
        }

        const collision = occupiedAreaAt(
            occupied,
            candidate_row,
            candidate_row_end,
            candidate_column,
            candidate_column_end,
        );
        if (collision == null) {
            item.row.start = candidate_row;
            item.row.end = candidate_row_end;
            item.column.start = candidate_column;
            item.column.end = candidate_column_end;
            try markArea(
                allocator,
                occupied,
                candidate_row,
                candidate_column,
                row_span,
                column_span,
            );
            if (!dense) {
                if (row_flow) {
                    cursor_row.* = candidate_row;
                    cursor_column.* = candidate_column_end;
                    if (!item.column.definite and cursor_column.* >= columns.items.len) {
                        try incrementIndex(cursor_row);
                        cursor_column.* = 0;
                    }
                } else {
                    cursor_column.* = candidate_column;
                    cursor_row.* = candidate_row_end;
                    if (!item.row.definite and cursor_row.* >= rows.items.len) {
                        try incrementIndex(cursor_column);
                        cursor_row.* = 0;
                    }
                }
            }
            return;
        }

        const previous_row = candidate_row;
        const previous_column = candidate_column;
        try advancePastCollision(
            row_flow,
            item.row.definite,
            item.column.definite,
            &candidate_row,
            &candidate_column,
            collision.?,
        );
        if (candidate_row == previous_row and candidate_column == previous_column) {
            return error.InvalidStyle;
        }
    }
    return error.InvalidStyle;
}

fn placementAttemptLimit(
    occupied_count: usize,
    row_count: usize,
    column_count: usize,
    row_span: usize,
    column_span: usize,
) Error!usize {
    const conflict_count = std.math.add(usize, occupied_count, 1) catch
        return error.InvalidStyle;
    const row_bound = std.math.add(
        usize,
        row_count,
        std.math.add(usize, conflict_count, row_span) catch
            return error.InvalidStyle,
    ) catch return error.InvalidStyle;
    const column_bound = std.math.add(
        usize,
        column_count,
        std.math.add(usize, conflict_count, column_span) catch
            return error.InvalidStyle,
    ) catch return error.InvalidStyle;
    const position_count = std.math.mul(usize, row_bound, column_bound) catch
        return error.InvalidStyle;
    return std.math.mul(usize, position_count, conflict_count) catch
        error.InvalidStyle;
}

fn advanceIndexTo(index: *usize, target: usize) Error!void {
    if (target <= index.*) return error.InvalidStyle;
    index.* = target;
}

fn advancePastCollision(
    row_flow: bool,
    row_definite: bool,
    column_definite: bool,
    candidate_row: *usize,
    candidate_column: *usize,
    collision: OccupiedArea,
) Error!void {
    if (row_flow) {
        if (column_definite) {
            try advanceIndexTo(candidate_row, collision.row_end);
        } else {
            try advanceIndexTo(candidate_column, collision.column_end);
        }
    } else if (row_definite) {
        try advanceIndexTo(candidate_column, collision.column_end);
    } else {
        try advanceIndexTo(candidate_row, collision.row_end);
    }
}

fn indexAdd(start: usize, span: usize) Error!usize {
    if (span == 0) return error.InvalidStyle;
    return std.math.add(usize, start, span) catch error.InvalidStyle;
}

fn incrementIndex(index: *usize) Error!void {
    index.* = std.math.add(usize, index.*, 1) catch
        return error.InvalidStyle;
}

fn occupiedAreaAt(
    occupied: *const Occupancy,
    row: usize,
    row_end: usize,
    column: usize,
    column_end: usize,
) ?OccupiedArea {
    for (occupied.areas.items) |area| {
        if (row < area.row_end and area.row_start < row_end and
            column < area.column_end and area.column_start < column_end)
        {
            return area;
        }
    }
    return null;
}

fn markArea(
    allocator: std.mem.Allocator,
    occupied: *Occupancy,
    row: usize,
    column: usize,
    row_span: usize,
    column_span: usize,
) Error!void {
    const row_end = try indexAdd(row, row_span);
    const column_end = try indexAdd(column, column_span);
    try occupied.areas.append(allocator, .{
        .row_start = row,
        .row_end = row_end,
        .column_start = column,
        .column_end = column_end,
    });
}

const ContributionKind = enum { minimum, min_content, max_content };
const BasePhase = enum { minimum, min_content, max_content_auto, max_content };
const DistributionLimit = enum { growth, fit_content, infinite, beyond };
fn itemContributionContent(
    item: FlowItem,
    axis: TrackAxis,
    kind: ContributionKind,
) Error!f32 {
    const contribution = switch (kind) {
        .minimum => item.natural.minimum,
        .min_content => item.natural.min_content,
        .max_content => item.natural.max_content,
    };
    return switch (axis) {
        .columns => finiteNonNegative(contribution.width),
        .rows => finiteNonNegative(contribution.height),
    };
}

fn itemContribution(item: FlowItem, axis: TrackAxis, kind: ContributionKind) Error!f32 {
    const size = try itemContributionContent(item, axis, kind);
    const margin_total = switch (axis) {
        .columns => try add(item.margins.value.left, item.margins.value.right),
        .rows => try add(item.margins.value.top, item.margins.value.bottom),
    };
    const baseline_extra = if (axis == .rows) item.baseline_shim else 0;
    return add(try add(size, margin_total), baseline_extra);
}
fn itemUsesFitContentLimit(item: FlowItem, axis: TrackAxis) bool {
    const overflow_axis = switch (axis) {
        .columns => item.overflow.width,
        .rows => item.overflow.height,
    };
    return switch (overflow_axis) {
        .visible, .clip => false,
        .hidden, .scroll, .auto => true,
    };
}

fn singleSpanContributionKind(track: style.GridTrack) ContributionKind {
    return switch (track) {
        .auto => .minimum,
        .min_content => .min_content,
        .max_content => .max_content,
        .fit_content => .minimum,
        .percent => .minimum,
        .fixed => .minimum,
        .fr => .minimum,
        .minmax => |value| switch (value.min) {
            .auto => .minimum,
            .min_content => .min_content,
            .max_content => .max_content,
            .fit_content => .minimum,
            .percent => .minimum,
            .fixed, .fr => .minimum,
        },
        .repeat => .minimum,
    };
}

fn availableIsMaxContent(available: sizing.AvailableSpace) bool {
    return switch (available) {
        .max_content => true,
        .definite, .min_content => false,
    };
}

fn availableIsMinOrMaxContent(available: sizing.AvailableSpace) bool {
    return switch (available) {
        .definite => false,
        .min_content, .max_content => true,
    };
}

fn spanDefiniteMaximum(
    tracks: []const Track,
    start: usize,
    end: usize,
    gap: f32,
    basis: ?f32,
) Error!?f32 {
    if (start >= end or end > tracks.len) return error.InvalidStyle;
    var result: f32 = 0;
    var visible_count: usize = 0;
    for (tracks[start..end]) |track| {
        if (track.collapsed) continue;
        const maximum = (try trackMaximum(track.spec, basis)) orelse return null;
        if (visible_count != 0) result = try add(result, gap);
        result = try add(result, maximum);
        visible_count += 1;
    }
    const finite_result: f32 = try finiteNonNegative(result);
    return finite_result;
}
fn trackFixedMaximum(
    track: style.GridTrack,
    basis: ?f32,
) Error!?f32 {
    return switch (track) {
        .fixed => |value| @as(?f32, try finiteNonNegative(value)),
        .percent => |fraction| if (basis) |percentage_basis|
            @as(?f32, try finiteNonNegative(try finite(fraction * percentage_basis)))
        else
            null,
        .minmax => |value| breadthFixedMaximum(value.max, basis),
        .auto, .min_content, .max_content, .fr, .fit_content, .repeat => null,
    };
}

fn breadthFixedMaximum(
    breadth: style.GridTrackBreadth,
    basis: ?f32,
) Error!?f32 {
    return switch (breadth) {
        .fixed => |value| @as(?f32, try finiteNonNegative(value)),
        .percent => |fraction| if (basis) |percentage_basis|
            @as(?f32, try finiteNonNegative(try finite(fraction * percentage_basis)))
        else
            null,
        .auto, .min_content, .max_content, .fr, .fit_content => null,
    };
}

fn spanFixedMaximum(
    tracks: []const Track,
    start: usize,
    end: usize,
    gap: f32,
    basis: ?f32,
) Error!?f32 {
    if (start >= end or end > tracks.len) return error.InvalidStyle;
    var result: f32 = 0;
    var visible_count: usize = 0;
    for (tracks[start..end]) |track| {
        if (track.collapsed) continue;
        const maximum = (try trackFixedMaximum(track.spec, basis)) orelse return null;
        if (visible_count != 0) result = try add(result, gap);
        result = try add(result, maximum);
        visible_count += 1;
    }
    const finite_result: f32 = try finiteNonNegative(result);
    return finite_result;
}

fn trackMinimumIsAuto(track: style.GridTrack) bool {
    return switch (trackMinimumBreadth(track)) {
        .auto, .fr => true,
        .fixed, .percent, .min_content, .max_content, .fit_content => false,
    };
}

fn spanHasAutoMinimum(
    tracks: []const Track,
    start: usize,
    end: usize,
) bool {
    for (tracks[start..end]) |track| {
        if (!track.collapsed and trackMinimumIsAuto(track.spec)) return true;
    }
    return false;
}

fn itemAutomaticMinimum(item: FlowItem, axis: TrackAxis) bool {
    return switch (axis) {
        .columns => item.automatic_min_width,
        .rows => item.automatic_min_height,
    };
}

fn itemContributionFromContent(
    item: FlowItem,
    axis: TrackAxis,
    content: f32,
) Error!f32 {
    const margin_total = switch (axis) {
        .columns => try add(item.margins.value.left, item.margins.value.right),
        .rows => try add(item.margins.value.top, item.margins.value.bottom),
    };
    const baseline_extra = if (axis == .rows) item.baseline_shim else 0;
    return add(try add(try finiteNonNegative(content), margin_total), baseline_extra);
}

fn itemMinimumContributionForSingleTrack(
    item: FlowItem,
    axis: TrackAxis,
    track: Track,
    basis: ?f32,
) Error!f32 {
    if (!itemAutomaticMinimum(item, axis)) {
        return itemContribution(item, axis, .minimum);
    }
    if (itemUsesFitContentLimit(item, axis) or !trackMinimumIsAuto(track.spec)) {
        return 0;
    }
    var content = try itemContributionContent(item, axis, .min_content);
    if (try trackFixedMaximum(track.spec, basis)) |limit| {
        content = @min(content, limit);
    }
    return itemContributionFromContent(item, axis, content);
}

fn itemMinimumContribution(
    item: FlowItem,
    axis: TrackAxis,
    tracks: []const Track,
    placement: AxisPlacement,
    gap: f32,
    basis: ?f32,
) Error!f32 {
    if (!itemAutomaticMinimum(item, axis)) {
        return itemContribution(item, axis, .minimum);
    }
    if (placement.start >= placement.end or placement.end > tracks.len) {
        return error.InvalidStyle;
    }
    if (itemUsesFitContentLimit(item, axis)) return 0;
    const span = placement.end - placement.start;
    if (!spanHasAutoMinimum(tracks, placement.start, placement.end) or
        (span > 1 and spanHasFlexible(tracks, placement.start, placement.end)))
    {
        return 0;
    }
    var content = try itemContributionContent(item, axis, .min_content);
    if (try spanFixedMaximum(
        tracks,
        placement.start,
        placement.end,
        gap,
        basis,
    )) |limit| {
        content = @min(content, limit);
    }
    return itemContributionFromContent(item, axis, content);
}

fn singleSpanBaseContribution(
    item: FlowItem,
    axis: TrackAxis,
    track: Track,
    available: sizing.AvailableSpace,
    basis: ?f32,
) Error!f32 {
    const minimum = try itemMinimumContributionForSingleTrack(item, axis, track, basis);
    const min_content = try itemContribution(item, axis, .min_content);
    const maximum = try itemContribution(item, axis, .max_content);
    const minimum_breadth = trackMinimumBreadth(track.spec);
    const result = if (minimum_breadth == .auto and
        availableIsMinOrMaxContent(available) and
        !itemUsesFitContentLimit(item, axis))
    blk: {
        const limit = (try trackMaximum(track.spec, basis)) orelse min_content;
        break :blk @max(minimum, @min(min_content, try finiteNonNegative(limit)));
    } else switch (minimum_breadth) {
        .min_content => min_content,
        .max_content => maximum,
        .percent => if (basis == null) min_content else minimum,
        else => minimum,
    };
    return result;
}

fn batchContribution(
    item: FlowItem,
    axis: TrackAxis,
    tracks: []const Track,
    placement: AxisPlacement,
    gap: f32,
    basis: ?f32,
    available: sizing.AvailableSpace,
    phase: BasePhase,
) Error!f32 {
    return switch (phase) {
        .minimum => blk: {
            const minimum = try itemMinimumContribution(
                item,
                axis,
                tracks,
                placement,
                gap,
                basis,
            );
            if (!availableIsMinOrMaxContent(available) or itemUsesFitContentLimit(item, axis)) {
                break :blk minimum;
            }
            const min_content = try itemContribution(item, axis, .min_content);
            const limit = (try spanDefiniteMaximum(
                tracks,
                placement.start,
                placement.end,
                gap,
                basis,
            )) orelse min_content;
            break :blk @max(minimum, @min(min_content, limit));
        },
        .min_content => itemContribution(item, axis, .min_content),
        .max_content_auto => blk: {
            const max_content = try itemContribution(item, axis, .max_content);
            const limit = (try spanDefiniteMaximum(
                tracks,
                placement.start,
                placement.end,
                gap,
                basis,
            )) orelse max_content;
            break :blk @min(max_content, limit);
        },
        .max_content => itemContribution(item, axis, .max_content),
    };
}

const TrackBatchItem = struct {
    index: usize,
    start: usize,
    span: usize,
    crosses_intrinsic: bool,
    has_max_content_minimum: bool,
};

const TrackTraitCounts = struct {
    flexible: usize = 0,
    intrinsic: usize = 0,
    max_content_minimum: usize = 0,
};

const SpanItemBuckets = struct {
    ordered: []TrackBatchItem,
    offsets: []usize,
    stride: usize,
    bucket_count: usize,
    fn init(
        allocator: std.mem.Allocator,
        tracks: []const Track,
        items: []const FlowItem,
        axis: TrackAxis,
        basis: ?f32,
    ) Error!SpanItemBuckets {
        const stride = std.math.add(usize, tracks.len, 1) catch
            return error.InvalidStyle;
        const start_offsets_len = std.math.add(usize, stride, 1) catch
            return error.InvalidStyle;
        const bucket_count = std.math.mul(usize, stride, 2) catch
            return error.InvalidStyle;
        const offsets_len = std.math.add(usize, bucket_count, 1) catch
            return error.InvalidStyle;

        const prefixes = try allocator.alloc(TrackTraitCounts, stride);
        defer allocator.free(prefixes);
        prefixes[0] = .{};
        for (tracks, 0..) |track, index| {
            var next = prefixes[index];
            if (!track.collapsed) {
                if (trackIsFlexible(track.spec)) {
                    next.flexible = std.math.add(usize, next.flexible, 1) catch
                        return error.InvalidStyle;
                }
                if (trackHasIntrinsicMinimum(track.spec) or
                    trackHasIntrinsicMaximum(track.spec, basis))
                {
                    next.intrinsic = std.math.add(usize, next.intrinsic, 1) catch
                        return error.InvalidStyle;
                }
                if (trackMinimumIsMaxContent(track.spec)) {
                    next.max_content_minimum = std.math.add(
                        usize,
                        next.max_content_minimum,
                        1,
                    ) catch return error.InvalidStyle;
                }
            }
            prefixes[index + 1] = next;
        }

        const start_offsets = try allocator.alloc(usize, start_offsets_len);
        defer allocator.free(start_offsets);
        @memset(start_offsets, 0);
        if (start_offsets.len < 2) return error.InvalidStyle;
        for (items) |item| {
            const placement = switch (axis) {
                .columns => item.column,
                .rows => item.row,
            };
            if (placement.start >= placement.end or placement.end > tracks.len) {
                return error.InvalidStyle;
            }
            const start_offset_index = std.math.add(usize, placement.start, 1) catch
                return error.InvalidStyle;
            start_offsets[start_offset_index] = std.math.add(
                usize,
                start_offsets[start_offset_index],
                1,
            ) catch return error.InvalidStyle;
        }
        for (start_offsets[1..], 0..) |*offset, index| {
            offset.* = std.math.add(
                usize,
                offset.*,
                start_offsets[index],
            ) catch return error.InvalidStyle;
        }

        const temporary = try allocator.alloc(TrackBatchItem, items.len);
        defer allocator.free(temporary);
        for (items, 0..) |item, item_index| {
            const placement = switch (axis) {
                .columns => item.column,
                .rows => item.row,
            };
            const span = placement.end - placement.start;
            const traits_start = prefixes[placement.start];
            const traits_end = prefixes[placement.end];
            const batch_item: TrackBatchItem = .{
                .index = item_index,
                .start = placement.start,
                .span = span,
                .crosses_intrinsic = traits_end.intrinsic != traits_start.intrinsic,
                .has_max_content_minimum = traits_end.max_content_minimum !=
                    traits_start.max_content_minimum,
            };
            const temporary_index = start_offsets[placement.start];
            if (temporary_index >= temporary.len) return error.InvalidStyle;
            temporary[temporary_index] = batch_item;
            start_offsets[placement.start] = std.math.add(
                usize,
                temporary_index,
                1,
            ) catch return error.InvalidStyle;
        }

        const offsets = try allocator.alloc(usize, offsets_len);
        errdefer allocator.free(offsets);
        @memset(offsets, 0);
        if (offsets.len < 2) return error.InvalidStyle;
        for (temporary) |batch_item| {
            const traits_start = prefixes[batch_item.start];
            const traits_end = prefixes[batch_item.start + batch_item.span];
            const flexible = traits_end.flexible != traits_start.flexible;
            const key = batch_item.span + if (flexible) stride else 0;
            offsets[key + 1] = std.math.add(usize, offsets[key + 1], 1) catch
                return error.InvalidStyle;
        }
        for (offsets[1..], 0..) |*offset, index| {
            offset.* = std.math.add(
                usize,
                offset.*,
                offsets[index],
            ) catch return error.InvalidStyle;
        }
        if (offsets[offsets.len - 1] != items.len) return error.InvalidStyle;

        const ordered = try allocator.alloc(TrackBatchItem, items.len);
        errdefer allocator.free(ordered);
        const cursors = try allocator.alloc(usize, bucket_count);
        defer allocator.free(cursors);
        @memcpy(cursors, offsets[0..bucket_count]);
        for (temporary) |batch_item| {
            const traits_start = prefixes[batch_item.start];
            const traits_end = prefixes[batch_item.start + batch_item.span];
            const flexible = traits_end.flexible != traits_start.flexible;
            const key = batch_item.span + if (flexible) stride else 0;
            const ordered_index = cursors[key];
            if (ordered_index >= ordered.len) return error.InvalidStyle;
            ordered[ordered_index] = batch_item;
            cursors[key] = std.math.add(usize, ordered_index, 1) catch
                return error.InvalidStyle;
        }
        return .{
            .ordered = ordered,
            .offsets = offsets,
            .stride = stride,
            .bucket_count = bucket_count,
        };
    }

    fn deinit(self: SpanItemBuckets, allocator: std.mem.Allocator) void {
        allocator.free(self.ordered);
        allocator.free(self.offsets);
    }

    fn batch(
        self: SpanItemBuckets,
        span: usize,
        flexible: bool,
    ) []const TrackBatchItem {
        std.debug.assert(span < self.stride);
        const key = span + if (flexible) self.stride else 0;
        return self.ordered[self.offsets[key]..self.offsets[key + 1]];
    }

    fn all(self: SpanItemBuckets, flexible: bool) []const TrackBatchItem {
        const first_key = if (flexible) self.stride + 1 else 1;
        const last_key = if (flexible) self.bucket_count else self.stride;
        return self.ordered[self.offsets[first_key]..self.offsets[last_key]];
    }
};

test "baseline maps propagate allocation failure" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .kind = .{ .spacer = .{} },
        .parent = @enumFromInt(2),
        .style = .{ .grid_align_self = .baseline },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(2),
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{ .grid_align_items = .baseline },
    });
    var items = [_]FlowItem{.{
        .index = 0,
        .row = .{},
        .column = .{},
        .natural = .{
            .content = .{ .width = 0, .height = 0 },
            .border = .{ .width = 0, .height = 0 },
        },
        .margins = .{
            .value = .{},
            .top_auto = false,
            .right_auto = false,
            .bottom_auto = false,
            .left_auto = false,
        },
        .overflow = .{ .width = .visible, .height = .visible },
    }};
    var storage: [0]u8 = .{};
    var exhausted = std.heap.FixedBufferAllocator.init(&storage);

    try std.testing.expectError(
        error.OutOfMemory,
        resolveIntrinsicBaselineShims(
            &tree,
            &tree.nodes.items[1],
            &items,
            .{ .width = 0, .height = 0 },
            .{
                .allocator = exhausted.allocator(),
                .available = .{ .width = 0, .height = 0 },
                .measure = null,
            },
            1,
        ),
    );
}

test "span item buckets propagate allocation failure" {
    var storage: [0]u8 = .{};
    var exhausted = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(
        error.OutOfMemory,
        SpanItemBuckets.init(
            exhausted.allocator(),
            &.{},
            &.{},
            .columns,
            null,
        ),
    );
}
fn growTrackItems(
    allocator: std.mem.Allocator,
    tracks: []Track,
    items: []const FlowItem,
    axis: TrackAxis,
    gap: f32,
    basis: ?f32,
    available: sizing.AvailableSpace,
) Error!void {
    var batches = try SpanItemBuckets.init(allocator, tracks, items, axis, basis);
    defer batches.deinit(allocator);

    var span: usize = 1;
    while (span < batches.stride) : (span += 1) {
        const batch = batches.batch(span, false);
        if (batch.len == 0) continue;
        try growTrackBatch(
            tracks,
            items,
            axis,
            gap,
            basis,
            available,
            batch,
            false,
            .minimum,
        );
        if (span == 1) {
            try recordSingleSpanGrowthLimits(tracks, items, axis, basis, batch);
            continue;
        }

        try growTrackBatch(
            tracks,
            items,
            axis,
            gap,
            basis,
            available,
            batch,
            false,
            .min_content,
        );
        if (availableIsMaxContent(available)) {
            try growTrackBatch(
                tracks,
                items,
                axis,
                gap,
                basis,
                available,
                batch,
                false,
                .max_content_auto,
            );
        }
        try growTrackBatch(
            tracks,
            items,
            axis,
            gap,
            basis,
            available,
            batch,
            false,
            .max_content,
        );
        try recordSpanningGrowthLimits(
            tracks,
            items,
            axis,
            gap,
            basis,
            .min_content,
            true,
            batch,
        );
        try recordSpanningGrowthLimits(
            tracks,
            items,
            axis,
            gap,
            basis,
            .max_content,
            false,
            batch,
        );
    }

    const flexible_batch = batches.all(true);
    if (flexible_batch.len != 0) {
        try growTrackBatch(
            tracks,
            items,
            axis,
            gap,
            basis,
            available,
            flexible_batch,
            true,
            .minimum,
        );
        try growTrackBatch(
            tracks,
            items,
            axis,
            gap,
            basis,
            available,
            flexible_batch,
            true,
            .min_content,
        );
        if (availableIsMaxContent(available)) {
            try growTrackBatch(
                tracks,
                items,
                axis,
                gap,
                basis,
                available,
                flexible_batch,
                true,
                .max_content_auto,
            );
        }
        try growTrackBatch(
            tracks,
            items,
            axis,
            gap,
            basis,
            available,
            flexible_batch,
            true,
            .max_content,
        );
    }
    for (tracks) |*track| {
        if ((try trackGrowthLimit(track.*, basis)) == null) {
            track.intrinsic_growth_limit = try finiteNonNegative(track.size);
        }
        track.infinitely_growable = false;
    }
}

fn growTrackBatch(
    tracks: []Track,
    items: []const FlowItem,
    axis: TrackAxis,
    gap: f32,
    basis: ?f32,
    available: sizing.AvailableSpace,
    batch: []const TrackBatchItem,
    flex_only: bool,
    phase: BasePhase,
) Error!void {
    if (batch.len == 0) return;
    var touched_start = tracks.len;
    var touched_end: usize = 0;
    for (batch) |batch_item| {
        if (batch_item.index >= items.len) return error.InvalidStyle;
        const item = items[batch_item.index];
        const placement = switch (axis) {
            .columns => item.column,
            .rows => item.row,
        };
        if (placement.start != batch_item.start or
            placement.end <= placement.start or
            placement.end > tracks.len or
            placement.end - placement.start != batch_item.span)
        {
            return error.InvalidStyle;
        }
        touched_start = @min(touched_start, placement.start);
        touched_end = @max(touched_end, placement.end);
        if (!flex_only and phase == .minimum and !batch_item.crosses_intrinsic) {
            continue;
        }
        const item_kind: ContributionKind = if (!flex_only and batch_item.span == 1)
            singleSpanContributionKind(tracks[placement.start].spec)
        else switch (phase) {
            .minimum => .minimum,
            .min_content => .min_content,
            .max_content_auto, .max_content => .max_content,
        };
        const need = if (!flex_only and batch_item.span == 1)
            try singleSpanBaseContribution(
                item,
                axis,
                tracks[placement.start],
                available,
                basis,
            )
        else
            try batchContribution(
                item,
                axis,
                tracks,
                placement,
                gap,
                basis,
                available,
                phase,
            );
        const max_content_auto = phase == .max_content_auto and
            !batch_item.has_max_content_minimum;
        const limit: DistributionLimit = if (phase == .max_content_auto)
            (if (max_content_auto) .fit_content else .infinite)
        else if (phase == .max_content)
            .growth
        else if (itemUsesFitContentLimit(item, axis))
            .fit_content
        else
            .growth;
        try growTracks(
            tracks,
            placement.start,
            placement.end,
            need,
            gap,
            basis,
            flex_only,
            item_kind,
            limit,
            max_content_auto,
        );
    }
    try flushTrackPlansRange(tracks, basis, touched_start, touched_end);
}

fn flushTrackPlansRange(
    tracks: []Track,
    basis: ?f32,
    start: usize,
    end: usize,
) Error!void {
    if (start > end or end > tracks.len) return error.InvalidStyle;
    for (tracks[start..end]) |*track| {
        if (track.planned_increase > 0) {
            track.size = try add(track.size, track.planned_increase);
        }
        if (track.spec == .minmax) {
            track.size = @max(track.size, try breadthMinimum(track.spec.minmax.min, basis));
        }
        track.size = try nonNegative(track.size);
        track.planned_increase = 0;
        track.item_incurred_increase = 0;
    }
}

fn trackHasFitContentMaximum(track: style.GridTrack) bool {
    return switch (track) {
        .fit_content => true,
        .minmax => |value| value.max == .fit_content,
        else => false,
    };
}

fn singleSpanGrowthKind(track: style.GridTrack, basis: ?f32) ContributionKind {
    return switch (track) {
        .auto => .max_content,
        .min_content => .min_content,
        .max_content => .max_content,
        .fit_content => .min_content,
        .percent => if (basis == null) .max_content else .minimum,
        .minmax => |value| switch (value.max) {
            .max_content => .max_content,
            .percent => if (basis == null) .max_content else .minimum,
            .auto => .max_content,
            .min_content, .fit_content => .min_content,
            .fixed, .fr => .minimum,
        },
        .fixed, .fr, .repeat => .minimum,
    };
}

fn recordSingleSpanGrowthLimits(
    tracks: []Track,
    items: []const FlowItem,
    axis: TrackAxis,
    basis: ?f32,
    batch: []const TrackBatchItem,
) Error!void {
    for (batch) |batch_item| {
        if (batch_item.index >= items.len or batch_item.span != 1) {
            return error.InvalidStyle;
        }
        const item = items[batch_item.index];
        const placement = switch (axis) {
            .columns => item.column,
            .rows => item.row,
        };
        if (placement.start != batch_item.start or
            placement.end <= placement.start or
            placement.end > tracks.len or
            placement.end - placement.start != batch_item.span)
        {
            return error.InvalidStyle;
        }
        const track = &tracks[batch_item.start];
        if (trackIsFlexible(track.spec)) continue;
        if (!trackAllowsIntrinsicContribution(track.spec)) continue;
        if (!trackHasIntrinsicMaximum(track.spec, basis)) continue;
        // SAFETY: Both branches assign `need` before the value is read below.
        var need: f32 = undefined;
        if (trackHasFitContentMaximum(track.spec)) {
            const min_content = try itemContribution(item, axis, .min_content);
            const max_content = try itemContribution(item, axis, .max_content);
            const cap = try trackMaximum(track.spec, basis) orelse max_content;
            var fit_need = @min(max_content, cap);
            if (!itemUsesFitContentLimit(item, axis)) fit_need = @max(fit_need, min_content);
            need = fit_need;
        } else {
            need = try itemContribution(item, axis, singleSpanGrowthKind(track.spec, basis));
        }
        if (need > 0) {
            const limit = try finiteNonNegative(@max(track.size, need));
            if (track.intrinsic_growth_limit) |current| {
                track.intrinsic_growth_limit = @max(current, limit);
            } else {
                track.intrinsic_growth_limit = limit;
            }
        }
        track.infinitely_growable = false;
    }
}

fn trackHasMaxContentMaximum(track: style.GridTrack, basis: ?f32) bool {
    return switch (track) {
        .auto, .max_content, .fit_content => true,
        .percent => basis == null,
        .minmax => |value| switch (value.max) {
            .auto, .max_content, .fit_content => true,
            .percent => basis == null,
            .fixed, .min_content, .fr => false,
        },
        .fixed, .min_content, .fr, .repeat => false,
    };
}

fn recordSpanningGrowthLimits(
    tracks: []Track,
    items: []const FlowItem,
    axis: TrackAxis,
    gap: f32,
    basis: ?f32,
    kind: ContributionKind,
    set_infinitely_growable: bool,
    batch: []const TrackBatchItem,
) Error!void {
    if (batch.len == 0) return;
    var touched_start = tracks.len;
    var touched_end: usize = 0;
    for (batch) |batch_item| {
        if (batch_item.index >= items.len or batch_item.span <= 1) {
            return error.InvalidStyle;
        }
        const item = items[batch_item.index];
        const placement = switch (axis) {
            .columns => item.column,
            .rows => item.row,
        };
        if (placement.start != batch_item.start or
            placement.end <= placement.start or
            placement.end > tracks.len or
            placement.end - placement.start != batch_item.span)
        {
            return error.InvalidStyle;
        }
        touched_start = @min(touched_start, placement.start);
        touched_end = @max(touched_end, placement.end);
    }
    if (set_infinitely_growable) {
        for (tracks[touched_start..touched_end]) |*track| {
            track.infinitely_growable = false;
        }
    }
    for (batch) |batch_item| {
        const item = items[batch_item.index];
        const placement = switch (axis) {
            .columns => item.column,
            .rows => item.row,
        };
        const need = try itemContribution(item, axis, kind);
        var remaining = need - try trackGrowthSpanTotal(
            tracks,
            placement.start,
            placement.end,
            gap,
            basis,
        );
        if (remaining <= 0) continue;

        var growable_count: usize = 0;
        for (tracks[placement.start..placement.end]) |track| {
            if (track.collapsed or trackIsFlexible(track.spec)) continue;
            const eligible = if (kind == .max_content)
                trackHasMaxContentMaximum(track.spec, basis)
            else
                trackHasIntrinsicMaximum(track.spec, basis);
            if (!eligible) continue;
            if (try trackIsInfinitelyGrowable(track, basis)) growable_count += 1;
        }
        if (growable_count > 0) {
            const share = remaining / (try countToF32(growable_count));
            for (tracks[placement.start..placement.end]) |*track| {
                if (track.collapsed or trackIsFlexible(track.spec)) continue;
                const eligible = if (kind == .max_content)
                    trackHasMaxContentMaximum(track.spec, basis)
                else
                    trackHasIntrinsicMaximum(track.spec, basis);
                if (!eligible) continue;
                if (try trackIsInfinitelyGrowable(track.*, basis)) {
                    if (share > 0) track.item_incurred_increase = share;
                }
            }
        } else {
            var affected_count: usize = 0;
            for (tracks[placement.start..placement.end]) |track| {
                if (track.collapsed or trackIsFlexible(track.spec)) continue;
                const eligible = if (kind == .max_content)
                    trackHasMaxContentMaximum(track.spec, basis)
                else
                    trackHasIntrinsicMaximum(track.spec, basis);
                if (eligible) affected_count += 1;
            }
            var previous_candidates: usize = std.math.maxInt(usize);
            var rounds: usize = 0;
            while (remaining > 0) {
                var candidates: usize = 0;
                var has_finite_limit = false;
                var increment_limit = remaining;
                for (tracks[placement.start..placement.end]) |track| {
                    if (track.collapsed or trackIsFlexible(track.spec)) continue;
                    const eligible = if (kind == .max_content)
                        trackHasMaxContentMaximum(track.spec, basis)
                    else
                        trackHasIntrinsicMaximum(track.spec, basis);
                    if (!eligible) continue;
                    const current = try add(
                        try trackGrowthSpanSize(track, basis),
                        track.item_incurred_increase,
                    );
                    if (try fitContentLimit(track, basis)) |maximum| {
                        if (current >= maximum) continue;
                        has_finite_limit = true;
                        increment_limit = @min(increment_limit, maximum - current);
                    }
                    candidates += 1;
                }
                if (candidates == 0) break;
                std.debug.assert(candidates <= previous_candidates);
                if (rounds != 0) std.debug.assert(candidates < previous_candidates);
                previous_candidates = candidates;
                std.debug.assert(rounds <= affected_count);
                if (!has_finite_limit) {
                    const share = remaining / (try countToF32(candidates));
                    for (tracks[placement.start..placement.end]) |*track| {
                        if (track.collapsed or trackIsFlexible(track.spec)) continue;
                        const eligible = if (kind == .max_content)
                            trackHasMaxContentMaximum(track.spec, basis)
                        else
                            trackHasIntrinsicMaximum(track.spec, basis);
                        if (eligible) {
                            track.item_incurred_increase = try add(
                                track.item_incurred_increase,
                                share,
                            );
                        }
                    }
                    remaining = 0;
                    break;
                }
                const share = @min(
                    remaining / (try countToF32(candidates)),
                    increment_limit,
                );
                if (share <= 0) return error.InvalidStyle;
                var consumed: f32 = 0;
                for (tracks[placement.start..placement.end]) |*track| {
                    if (track.collapsed or trackIsFlexible(track.spec)) continue;
                    const eligible = if (kind == .max_content)
                        trackHasMaxContentMaximum(track.spec, basis)
                    else
                        trackHasIntrinsicMaximum(track.spec, basis);
                    if (!eligible) continue;
                    const current = try add(
                        try trackGrowthSpanSize(track.*, basis),
                        track.item_incurred_increase,
                    );
                    const increase = if (try fitContentLimit(track.*, basis)) |maximum|
                        @min(share, @max(0, maximum - current))
                    else
                        share;
                    if (increase <= 0) continue;
                    track.item_incurred_increase = try add(
                        track.item_incurred_increase,
                        increase,
                    );
                    consumed = try add(consumed, increase);
                }
                std.debug.assert(consumed > 0);
                if (consumed <= 0) return error.InvalidStyle;
                const next_remaining = if (consumed >= remaining) 0 else remaining - consumed;
                std.debug.assert(next_remaining < remaining);
                remaining = next_remaining;
                rounds += 1;
                std.debug.assert(rounds <= affected_count);
            }
        }
        for (tracks[placement.start..placement.end]) |*track| {
            if (track.item_incurred_increase > track.planned_increase) {
                track.planned_increase = track.item_incurred_increase;
            }
            track.item_incurred_increase = 0;
        }
    }
    for (tracks[touched_start..touched_end]) |*track| {
        if (track.planned_increase > 0) {
            const current = try trackGrowthSpanSize(track.*, basis);
            track.intrinsic_growth_limit = try finiteNonNegative(
                try add(current, track.planned_increase),
            );
            track.infinitely_growable = set_infinitely_growable;
        } else {
            track.infinitely_growable = false;
        }
        track.planned_increase = 0;
    }
}
fn trackGrowthLimit(track: Track, basis: ?f32) Error!?f32 {
    _ = basis;
    if (track.intrinsic_growth_limit) |limit| {
        return @max(
            try finiteNonNegative(track.size),
            try finiteNonNegative(limit),
        );
    }
    return null;
}
fn trackGrowthSpanSize(track: Track, basis: ?f32) Error!f32 {
    return try trackGrowthLimit(track, basis) orelse finiteNonNegative(track.size);
}

fn trackGrowthSpanTotal(
    tracks: []const Track,
    start: usize,
    end: usize,
    gap: f32,
    basis: ?f32,
) Error!f32 {
    if (start >= end or end > tracks.len) return error.InvalidStyle;
    var result: f32 = 0;
    var visible_count: usize = 0;
    for (tracks[start..end]) |track| {
        if (track.collapsed) continue;
        if (visible_count != 0) result = try add(result, gap);
        result = try add(result, try trackGrowthSpanSize(track, basis));
        visible_count += 1;
    }
    return result;
}

fn fitContentLimit(track: Track, basis: ?f32) Error!?f32 {
    if (!trackHasFitContentMaximum(track.spec)) return null;
    return trackMaximum(track.spec, basis);
}

fn fitContentLimitedGrowthLimit(track: Track, basis: ?f32) Error!?f32 {
    const growth_limit = try trackGrowthLimit(track, basis);
    if (!trackHasFitContentMaximum(track.spec)) return growth_limit;
    const fit_limit = try fitContentLimit(track, basis);
    if (fit_limit) |maximum| {
        const finite_maximum = try finiteNonNegative(maximum);
        if (growth_limit) |growth| return @min(growth, finite_maximum);
        return finite_maximum;
    }
    return growth_limit;
}

fn trackIsInfinitelyGrowable(track: Track, basis: ?f32) Error!bool {
    if (track.infinitely_growable) return true;
    return (try fitContentLimitedGrowthLimit(track, basis)) == null;
}

fn spanHasFlexible(tracks: []const Track, start: usize, end: usize) bool {
    for (tracks[start..end]) |track| {
        if (!track.collapsed and trackIsFlexible(track.spec)) return true;
    }
    return false;
}
fn sizeTracks(
    tree: *widget.WidgetTree,
    container: *widget.WidgetNode,
    columns: *std.ArrayList(Track),
    rows: *std.ArrayList(Track),
    items: []FlowItem,
    content: widget.Size,
    column_gap: f32,
    row_gap: f32,
    width_mode: layout_context.MeasureMode,
    height_mode: layout_context.MeasureMode,
    options: Options,
    depth: usize,
) Error!void {
    const width_definite = width_mode == .definite;
    const height_definite = height_mode == .definite;
    const width_available = availableForDimension(.auto, width_mode, content.width);
    const height_available = availableForDimension(.auto, height_mode, content.height);
    const child_request: layout_context.Request = .{
        .available = content,
        .percentage_basis = .{
            .width = if (width_definite) @as(?f32, content.width) else null,
            .height = if (height_definite) @as(?f32, content.height) else null,
        },
        .width_mode = width_mode,
        .height_mode = height_mode,
    };
    try remeasureItemsForColumns(
        tree,
        container,
        items,
        columns.items,
        rows.items,
        row_gap,
        child_request,
        options,
        depth,
    );
    try growTrackItems(
        options.allocator,
        columns.items,
        items,
        .columns,
        column_gap,
        if (width_definite) content.width else null,
        width_available,
    );
    if (width_definite) {
        try maximizeIndefiniteTracks(
            columns.items,
            width_available,
            content.width,
            column_gap,
        );
        try resolveFlexibleTracks(
            options.allocator,
            columns.items,
            content.width,
            column_gap,
        );
    } else {
        try maximizeIndefiniteTracks(columns.items, width_available, null, column_gap);
        try resolveIndefiniteFlexibleTracks(
            columns.items,
            items,
            .columns,
            width_available,
            column_gap,
        );
    }
    if (width_definite) {
        try stretchAutoTracks(columns.items, column_gap, content.width, container.style);
    }

    try remeasureItemsForRows(
        tree,
        container,
        items,
        columns.items,
        column_gap,
        child_request,
        options,
        depth,
    );
    try growTrackItems(
        options.allocator,
        rows.items,
        items,
        .rows,
        row_gap,
        if (height_definite) content.height else null,
        height_available,
    );
    if (height_definite) {
        try maximizeIndefiniteTracks(
            rows.items,
            height_available,
            content.height,
            row_gap,
        );
        try resolveFlexibleTracks(
            options.allocator,
            rows.items,
            content.height,
            row_gap,
        );
    } else {
        try maximizeIndefiniteTracks(rows.items, height_available, null, row_gap);
        try resolveIndefiniteFlexibleTracks(
            rows.items,
            items,
            .rows,
            height_available,
            row_gap,
        );
    }
}

fn baseTrackAffected(
    track: Track,
    basis: ?f32,
    kind: ContributionKind,
    max_content_auto: bool,
) bool {
    return switch (kind) {
        .minimum => !trackMinimumIsDefinite(track.spec, basis),
        .min_content => trackMinimumIsContent(track.spec),
        .max_content => trackMinimumIsMaxContent(track.spec) or
            (max_content_auto and trackMinimumBreadth(track.spec) == .auto),
    };
}

fn distributionLimitValue(
    track: Track,
    basis: ?f32,
    limit: DistributionLimit,
) Error!?f32 {
    return switch (limit) {
        .growth => trackGrowthLimit(track, basis),
        .fit_content => fitContentLimitedGrowthLimit(track, basis),
        .infinite => null,
        .beyond => fitContentLimit(track, basis),
    };
}

fn distributeTrackSpace(
    tracks: []Track,
    start: usize,
    end: usize,
    amount: f32,
    flex_only: bool,
    basis: ?f32,
    kind: ContributionKind,
    limit: DistributionLimit,
    max_content_auto: bool,
    preferred_only: bool,
) Error!f32 {
    var remaining = try finiteNonNegative(amount);
    var affected_count: usize = 0;
    for (tracks[start..end]) |track| {
        if (track.collapsed or
            (flex_only != trackIsFlexible(track.spec)) or
            !baseTrackAffected(track, basis, kind, max_content_auto))
        {
            continue;
        }
        if (preferred_only and
            (if (kind == .max_content)
                !trackHasMaxContentMaximum(track.spec, basis)
            else
                !trackHasIntrinsicMaximum(track.spec, basis)))
        {
            continue;
        }
        affected_count += 1;
    }

    var previous_candidates: usize = std.math.maxInt(usize);
    var iterations: usize = 0;
    while (remaining > 0) {
        var total_weight: f32 = 0;
        var candidate_count: usize = 0;
        var increment_limit = remaining;
        var has_finite_limit = false;
        for (tracks[start..end]) |track| {
            if (track.collapsed or
                (flex_only != trackIsFlexible(track.spec)) or
                !baseTrackAffected(track, basis, kind, max_content_auto))
            {
                continue;
            }
            if (preferred_only and
                (if (kind == .max_content)
                    !trackHasMaxContentMaximum(track.spec, basis)
                else
                    !trackHasIntrinsicMaximum(track.spec, basis)))
            {
                continue;
            }
            const current = try add(track.size, track.item_incurred_increase);
            if (try distributionLimitValue(track, basis, limit)) |maximum| {
                if (current >= maximum) continue;
                has_finite_limit = true;
            }
            const raw_weight = if (flex_only) @max(0, trackFraction(track.spec)) else 1;
            total_weight = try add(total_weight, raw_weight);
            candidate_count += 1;
        }
        if (candidate_count == 0) break;
        std.debug.assert(candidate_count <= previous_candidates);
        if (iterations != 0) std.debug.assert(candidate_count < previous_candidates);
        previous_candidates = candidate_count;
        std.debug.assert(iterations <= affected_count);

        const equal_flex = flex_only and total_weight <= 0;
        if (equal_flex) total_weight = try countToF32(candidate_count);
        if (!has_finite_limit) {
            const per_weight = remaining / total_weight;
            for (tracks[start..end]) |*track| {
                if (track.collapsed or
                    (flex_only != trackIsFlexible(track.spec)) or
                    !baseTrackAffected(track.*, basis, kind, max_content_auto))
                {
                    continue;
                }
                if (preferred_only and
                    (if (kind == .max_content)
                        !trackHasMaxContentMaximum(track.spec, basis)
                    else
                        !trackHasIntrinsicMaximum(track.spec, basis)))
                {
                    continue;
                }
                const current = try add(track.size, track.item_incurred_increase);
                if (try distributionLimitValue(track.*, basis, limit)) |maximum| {
                    if (current >= maximum) continue;
                }
                const raw_weight = if (flex_only) @max(0, trackFraction(track.spec)) else 1;
                const weight = if (equal_flex) 1 else raw_weight;
                if (weight > 0) {
                    track.item_incurred_increase = try add(
                        track.item_incurred_increase,
                        per_weight * weight,
                    );
                }
            }
            remaining = 0;
            break;
        }
        for (tracks[start..end]) |track| {
            if (track.collapsed or
                (flex_only != trackIsFlexible(track.spec)) or
                !baseTrackAffected(track, basis, kind, max_content_auto))
            {
                continue;
            }
            if (preferred_only and
                (if (kind == .max_content)
                    !trackHasMaxContentMaximum(track.spec, basis)
                else
                    !trackHasIntrinsicMaximum(track.spec, basis)))
            {
                continue;
            }
            const raw_weight = if (flex_only) @max(0, trackFraction(track.spec)) else 1;
            const weight = if (equal_flex) 1 else raw_weight;
            if (weight <= 0) continue;
            if (try distributionLimitValue(track, basis, limit)) |maximum| {
                const current = try add(track.size, track.item_incurred_increase);
                if (current >= maximum) continue;
                const capacity = maximum - current;
                increment_limit = @min(increment_limit, capacity / weight);
            }
        }
        const per_weight = @min(remaining / total_weight, increment_limit);
        if (per_weight <= 0) return error.InvalidStyle;
        var consumed: f32 = 0;
        for (tracks[start..end]) |*track| {
            if (track.collapsed or
                (flex_only != trackIsFlexible(track.spec)) or
                !baseTrackAffected(track.*, basis, kind, max_content_auto))
            {
                continue;
            }
            if (preferred_only and
                (if (kind == .max_content)
                    !trackHasMaxContentMaximum(track.spec, basis)
                else
                    !trackHasIntrinsicMaximum(track.spec, basis)))
            {
                continue;
            }
            const raw_weight = if (flex_only) @max(0, trackFraction(track.spec)) else 1;
            const weight = if (equal_flex) 1 else raw_weight;
            if (weight <= 0) continue;
            var increase = per_weight * weight;
            if (try distributionLimitValue(track.*, basis, limit)) |maximum| {
                const current = try add(track.size, track.item_incurred_increase);
                if (current >= maximum) continue;
                const capacity = maximum - current;
                increase = @min(increase, capacity);
            }
            if (increase <= 0) continue;
            track.item_incurred_increase = try add(
                track.item_incurred_increase,
                increase,
            );
            consumed = try add(consumed, increase);
        }
        std.debug.assert(consumed > 0);
        if (consumed <= 0) return error.InvalidStyle;
        const next_remaining = if (consumed >= remaining) 0 else remaining - consumed;
        std.debug.assert(next_remaining < remaining);
        remaining = next_remaining;
        iterations += 1;
        std.debug.assert(iterations <= affected_count);
    }
    const distributed: f32 = try finiteNonNegative(amount - remaining);
    return distributed;
}

fn commitItemIncurred(tracks: []Track, start: usize, end: usize) void {
    for (tracks[start..end]) |*track| {
        if (track.item_incurred_increase > track.planned_increase) {
            track.planned_increase = track.item_incurred_increase;
        }
        track.item_incurred_increase = 0;
    }
}

fn growTracks(
    tracks: []Track,
    start: usize,
    end: usize,
    need: f32,
    gap: f32,
    basis: ?f32,
    flex_only: bool,
    kind: ContributionKind,
    limit: DistributionLimit,
    max_content_auto: bool,
) Error!void {
    var current: f32 = 0;
    var visible_count: usize = 0;
    for (tracks[start..end]) |track| {
        if (track.collapsed) continue;
        if (visible_count != 0) current = try add(current, gap);
        const size = if (flex_only and
            !trackIsFlexible(track.spec) and
            trackHasDefiniteMaximum(track.spec, basis))
            try trackGrowthSpanSize(track, basis)
        else
            track.size;
        current = try add(current, size);
        visible_count += 1;
    }
    const deficit = need - current;
    if (deficit <= 0) return;

    _ = try distributeTrackSpace(
        tracks,
        start,
        end,
        deficit,
        flex_only,
        basis,
        kind,
        limit,
        max_content_auto,
        false,
    );
    var remaining = deficit;
    for (tracks[start..end]) |track| {
        remaining = @max(0, remaining - track.item_incurred_increase);
    }
    if (remaining > 0) {
        var preferred_count: usize = 0;
        for (tracks[start..end]) |track| {
            if (track.collapsed or
                (flex_only != trackIsFlexible(track.spec)) or
                !baseTrackAffected(track, basis, kind, max_content_auto))
            {
                continue;
            }
            const preferred = if (kind == .max_content)
                trackHasMaxContentMaximum(track.spec, basis)
            else
                trackHasIntrinsicMaximum(track.spec, basis);
            if (preferred) preferred_count += 1;
        }
        _ = try distributeTrackSpace(
            tracks,
            start,
            end,
            remaining,
            flex_only,
            basis,
            kind,
            .beyond,
            max_content_auto,
            preferred_count != 0,
        );
    }
    commitItemIncurred(tracks, start, end);
}

fn maximizeIndefiniteTracks(
    tracks: []Track,
    available: sizing.AvailableSpace,
    basis: ?f32,
    gap: f32,
) Error!void {
    const used_space = try trackTotal(tracks, gap);
    const free_space = switch (available) {
        .min_content => 0,
        .max_content => std.math.inf(f32),
        .definite => |size| @max(0, size - used_space),
    };
    if (std.math.isInf(free_space)) {
        for (tracks) |*track| {
            if (track.collapsed or trackIsFlexible(track.spec)) continue;
            const limit = (try fitContentLimitedGrowthLimit(track.*, basis)) orelse track.size;
            track.size = @max(track.size, try finiteNonNegative(limit));
        }
        return;
    }
    var remaining = free_space;
    var affected_count: usize = 0;
    for (tracks) |track| {
        if (track.collapsed or trackIsFlexible(track.spec)) continue;
        if (try fitContentLimitedGrowthLimit(track, basis)) |limit| {
            if (limit > track.size) affected_count += 1;
        } else {
            affected_count += 1;
        }
    }
    var previous_candidates: usize = std.math.maxInt(usize);
    var rounds: usize = 0;
    while (remaining > 0) {
        var candidates: usize = 0;
        var increment_limit = remaining;
        for (tracks) |track| {
            if (track.collapsed or trackIsFlexible(track.spec)) continue;
            if (try fitContentLimitedGrowthLimit(track, basis)) |limit| {
                if (limit <= track.size) continue;
                increment_limit = @min(increment_limit, limit - track.size);
            }
            candidates += 1;
        }
        if (candidates == 0) break;
        std.debug.assert(candidates <= previous_candidates);
        if (rounds != 0) std.debug.assert(candidates < previous_candidates);
        previous_candidates = candidates;
        std.debug.assert(rounds <= affected_count);
        const share = @min(
            remaining / (try countToF32(candidates)),
            increment_limit,
        );
        if (share <= 0) return error.InvalidStyle;
        var consumed: f32 = 0;
        for (tracks) |*track| {
            if (track.collapsed or trackIsFlexible(track.spec)) continue;
            const increase = if (try fitContentLimitedGrowthLimit(track.*, basis)) |limit|
                @min(share, @max(0, limit - track.size))
            else
                share;
            if (increase <= 0) continue;
            track.size = try add(track.size, increase);
            consumed = try add(consumed, increase);
        }
        std.debug.assert(consumed > 0);
        if (consumed <= 0) return error.InvalidStyle;
        const next_remaining = if (consumed >= remaining) 0 else remaining - consumed;
        std.debug.assert(next_remaining < remaining);
        remaining = next_remaining;
        rounds += 1;
        std.debug.assert(rounds <= affected_count);
    }
}

fn gapTotal(tracks: []const Track, gap: f32) Error!f32 {
    var result: f32 = 0;
    var visible = false;
    for (tracks) |track| {
        if (track.collapsed) continue;
        if (visible) result = try add(result, gap);
        visible = true;
    }
    return result;
}

fn trackMaximizationLimit(track: Track, basis: ?f32) Error!?f32 {
    return fitContentLimitedGrowthLimit(track, basis);
}

fn maximizeBoundedTracks(
    tracks: []Track,
    available: f32,
    basis: ?f32,
) Error!void {
    var remaining = try finite(available);
    var affected_count: usize = 0;
    for (tracks) |track| {
        if (track.collapsed or trackIsFlexible(track.spec)) continue;
        if (try trackMaximizationLimit(track, basis)) |maximum| {
            if (maximum > track.size) affected_count += 1;
        } else {
            affected_count += 1;
        }
    }
    var previous_candidates: usize = std.math.maxInt(usize);
    var rounds: usize = 0;
    while (remaining > 0) {
        var candidates: usize = 0;
        var increment_limit = remaining;
        for (tracks) |track| {
            if (track.collapsed or trackIsFlexible(track.spec)) continue;
            if (try trackMaximizationLimit(track, basis)) |maximum| {
                if (maximum <= track.size) continue;
                increment_limit = @min(increment_limit, maximum - track.size);
            }
            candidates += 1;
        }
        if (candidates == 0) break;
        std.debug.assert(candidates <= previous_candidates);
        if (rounds != 0) std.debug.assert(candidates < previous_candidates);
        previous_candidates = candidates;
        std.debug.assert(rounds <= affected_count);
        const share = @min(
            remaining / (try countToF32(candidates)),
            increment_limit,
        );
        if (share <= 0) return error.InvalidStyle;
        var consumed: f32 = 0;
        for (tracks) |*track| {
            if (track.collapsed or trackIsFlexible(track.spec)) continue;
            const increase = if (try trackMaximizationLimit(track.*, basis)) |maximum|
                @min(share, @max(0, maximum - track.size))
            else
                share;
            if (increase <= 0) continue;
            track.size = try add(track.size, increase);
            consumed = try add(consumed, increase);
        }
        std.debug.assert(consumed > 0);
        if (consumed <= 0) return error.InvalidStyle;
        const next_remaining = if (consumed >= remaining) 0 else remaining - consumed;
        std.debug.assert(next_remaining < remaining);
        remaining = next_remaining;
        rounds += 1;
        std.debug.assert(rounds <= affected_count);
    }
}

fn findSizeOfFr(tracks: []const Track, space_to_fill: f32) Error!f32 {
    if (space_to_fill <= 0) return 0;
    var affected_count: usize = 0;
    for (tracks) |track| {
        if (!track.collapsed and trackFraction(track.spec) > 0) affected_count += 1;
    }
    var hypothetical = std.math.inf(f32);
    var previous = hypothetical;
    var iterations: usize = 0;
    while (true) {
        var used_space: f32 = 0;
        var flex_factor_sum: f32 = 0;
        for (tracks) |track| {
            if (track.collapsed) continue;
            const fraction = trackFraction(track.spec);
            if (fraction > 0 and fraction * hypothetical >= track.size) {
                flex_factor_sum = try add(flex_factor_sum, fraction);
            } else {
                used_space = try add(used_space, track.size);
            }
        }
        const leftover = try finite(space_to_fill - used_space);
        hypothetical = leftover / @max(flex_factor_sum, 1);
        var valid = true;
        for (tracks) |track| {
            if (track.collapsed) continue;
            const fraction = trackFraction(track.spec);
            if (fraction > 0 and fraction * hypothetical < track.size and
                fraction * previous >= track.size)
            {
                valid = false;
                break;
            }
        }
        if (valid) return hypothetical;
        std.debug.assert(iterations < affected_count);
        iterations += 1;
        previous = hypothetical;
    }
}

fn resolveFlexibleTracks(
    allocator: std.mem.Allocator,
    tracks: []Track,
    content_size: f32,
    gap: f32,
) Error!void {
    _ = allocator;
    const total_gaps = try gapTotal(tracks, gap);
    var used_space: f32 = total_gaps;
    for (tracks) |track| {
        if (!track.collapsed) used_space = try add(used_space, track.size);
    }
    const free_space = @max(0, try finite(content_size - used_space));
    if (free_space > 0) try maximizeBoundedTracks(tracks, free_space, content_size);
    const space_to_fill = @max(0, try finite(content_size - total_gaps));
    const fr_size = try findSizeOfFr(tracks, space_to_fill);
    for (tracks) |*track| {
        if (track.collapsed) continue;
        if (!trackIsFlexible(track.spec)) continue;
        const fraction = trackFraction(track.spec);
        var size = @max(track.size, fraction * fr_size);
        size = @max(size, try trackMinimum(track.spec, content_size));
        if (try trackMaximum(track.spec, content_size)) |maximum| {
            size = @min(size, try finiteNonNegative(maximum));
        }
        track.size = try nonNegative(size);
    }
}
fn nodeFirstBaseline(
    tree: *const widget.WidgetTree,
    child_index: usize,
    child_size: widget.Size,
    child_edges: Edges,
    context: ?*layout_context.LayoutContext,
) Error!f32 {
    const node = &tree.nodes.items[child_index];
    if (node.first_baseline) |baseline| return baseline;
    const content = layout_context.visibleNodeText(node);
    if (content.len != 0) {
        const top_inset = try add(child_edges.border.top, child_edges.padding.top);
        const measured: ?layout_context.TextMeasurement = if (context) |cache|
            try cache.measureVisibleNodeTextCached(child_index, node, .{
                .known_dimensions = .{ .width = null, .height = null },
                .available_space = .{ .width = .max_content, .height = .max_content },
                .text = node.text_request,
                .writing_mode = node.writing_mode,
            })
        else
            null;
        if (try layout_context.textNodeBaseline(node, top_inset, measured)) |baseline| {
            return baseline;
        }
        return child_size.height;
    }
    if (node.children.items.len > 0) {
        for (node.children.items) |grandchild_id| {
            if (tree.nodeIndex(grandchild_id)) |grandchild_index| {
                const grandchild = &tree.nodes.items[grandchild_index];
                if (grandchild.layout_hidden or grandchild.style.position == .absolute) continue;
                const grandchild_edges = try resolveEdges(grandchild.style, child_size.width);
                const grandchild_baseline = try nodeFirstBaseline(
                    tree,
                    grandchild_index,
                    .{ .width = grandchild.rect.w, .height = grandchild.rect.h },
                    grandchild_edges,
                    context,
                );
                return grandchild.rect.y + grandchild_baseline;
            }
        }
    }
    return child_size.height;
}

fn writeGridBaseline(
    tree: *widget.WidgetTree,
    container: *widget.WidgetNode,
    items: []const FlowItem,
    content: widget.Size,
    edges: Edges,
    context: ?*layout_context.LayoutContext,
) Error!void {
    if (items.len == 0) {
        container.first_baseline = null;
        return;
    }
    var first_row = items[0].row.start;
    for (items[1..]) |item| {
        if (item.row.start < first_row) first_row = item.row.start;
    }
    var donor: ?FlowItem = null;
    for (items) |item| {
        if (item.row.start != first_row) continue;
        const child = &tree.nodes.items[item.index];
        const directions_match = child.style.writing_direction == container.style.writing_direction;
        const alignment = alignValue(
            child.style.grid_align_self,
            effectiveAlignItems(container.style),
            directions_match,
            false,
        );
        if (donor == null) donor = item;
        if (alignment == .baseline) {
            donor = item;
            break;
        }
    }
    if (donor) |item| {
        const child = &tree.nodes.items[item.index];
        const child_edges = try resolveEdges(child.style, content.width);
        const child_baseline = try nodeFirstBaseline(
            tree,
            item.index,
            .{ .width = child.rect.w, .height = child.rect.h },
            child_edges,
            context,
        );
        container.first_baseline = try add(
            try add(edges.border.top, edges.padding.top),
            try add(child.rect.y, child_baseline),
        );
    }
}

fn resolveIndefiniteFlexibleTracks(
    tracks: []Track,
    items: []const FlowItem,
    axis: TrackAxis,
    available: sizing.AvailableSpace,
    gap: f32,
) Error!void {
    const is_max_content = switch (available) {
        .max_content => true,
        .definite, .min_content => false,
    };
    if (!is_max_content) return;
    var max_fr_unit: f32 = 0;
    for (tracks) |track| {
        if (track.collapsed) continue;
        const fraction = trackFraction(track.spec);
        if (fraction <= 0) continue;
        const unit = if (fraction > 1) track.size / fraction else track.size;
        max_fr_unit = @max(max_fr_unit, unit);
    }
    for (items) |item| {
        const placement = switch (axis) {
            .columns => item.column,
            .rows => item.row,
        };
        if (placement.start >= placement.end or placement.end > tracks.len) continue;
        if (!spanHasFlexible(tracks, placement.start, placement.end)) continue;
        const contribution = try itemContribution(item, axis, .max_content);
        const span_gap = try spanGapTotal(tracks, placement.start, placement.end, gap);
        const unit = try findSizeOfFr(
            tracks[placement.start..placement.end],
            @max(0, contribution - span_gap),
        );
        max_fr_unit = @max(max_fr_unit, unit);
    }
    for (tracks) |*track| {
        if (track.collapsed) continue;
        const fraction = trackFraction(track.spec);
        if (fraction <= 0) continue;
        track.size = try nonNegative(@max(track.size, fraction * max_fr_unit));
    }
}

fn trackMinimum(track: style.GridTrack, basis: ?f32) Error!f32 {
    return switch (track) {
        .fixed => |value| finiteNonNegative(value),
        .percent => |fraction| blk: {
            const percentage_basis = basis orelse return 0;
            break :blk finiteNonNegative(try finite(fraction * percentage_basis));
        },
        .auto, .min_content, .max_content, .fr, .fit_content => 0,
        .minmax => |value| breadthMinimum(value.min, basis),
        // Repeats are expanded before track minimums are requested.
        .repeat => error.InvalidStyle,
    };
}

fn breadthMinimum(breadth: style.GridTrackBreadth, basis: ?f32) Error!f32 {
    return switch (breadth) {
        .fixed => |value| finiteNonNegative(value),
        .percent => |fraction| blk: {
            const percentage_basis = basis orelse return 0;
            break :blk finiteNonNegative(try finite(fraction * percentage_basis));
        },
        .auto, .min_content, .max_content, .fr, .fit_content => 0,
    };
}

fn trackMaximum(track: style.GridTrack, basis: ?f32) Error!?f32 {
    return switch (track) {
        .fixed => |value| value,
        .fit_content => |value| blk: {
            const resolved = value.resolve(basis) orelse break :blk null;
            break :blk try finiteNonNegative(resolved);
        },
        .percent => |fraction| blk: {
            const percentage_basis = basis orelse return null;
            break :blk fraction * percentage_basis;
        },
        .auto, .min_content, .max_content, .fr => null,
        .minmax => |value| blk: {
            const maximum = (try breadthMaximum(value.max, basis)) orelse break :blk null;
            break :blk @max(maximum, try breadthMinimum(value.min, basis));
        },
        .repeat => null,
    };
}

fn breadthMaximum(breadth: style.GridTrackBreadth, basis: ?f32) Error!?f32 {
    return switch (breadth) {
        .fixed => |value| value,
        .fit_content => |value| blk: {
            const resolved = value.resolve(basis) orelse break :blk null;
            break :blk try finiteNonNegative(resolved);
        },
        .percent => |fraction| blk: {
            const percentage_basis = basis orelse return null;
            break :blk fraction * percentage_basis;
        },
        .auto, .min_content, .max_content, .fr => null,
    };
}

fn trackAllowsIntrinsic(track: style.GridTrack) bool {
    return switch (track) {
        .auto, .min_content, .max_content, .fit_content => true,
        .minmax => |value| switch (value.min) {
            .auto, .min_content, .max_content, .fixed, .percent, .fit_content => true,
            .fr => false,
        },
        .percent => true,
        .fixed, .fr => false,
        .repeat => true,
    };
}
fn stretchAutoTracks(
    tracks: []Track,
    gap: f32,
    available: f32,
    input: style.Style,
) Error!void {
    const justify_content = effectiveJustifyContent(input);
    if (input.grid_justify_content != .normal or justify_content != .normal) return;
    const free_space = try finite(available - try trackTotal(tracks, gap));
    if (free_space <= 0) return;

    var stretch_count: usize = 0;
    for (tracks) |track| {
        if (track.can_stretch_in_alignment and
            trackCanStretch(track.spec) and
            trackHasAutoMaximum(track.spec))
        {
            stretch_count += 1;
        }
    }
    if (stretch_count == 0) return;

    const addition = free_space / (try countToF32(stretch_count));
    for (tracks) |*track| {
        if (track.can_stretch_in_alignment and
            trackCanStretch(track.spec) and
            trackHasAutoMaximum(track.spec))
        {
            track.size = try add(track.size, addition);
        }
    }
}

fn trackCanStretch(track: style.GridTrack) bool {
    return trackHasAutoMaximum(track);
}

fn trackHasAutoMaximum(track: style.GridTrack) bool {
    return switch (track) {
        .auto => true,
        .minmax => |value| switch (value.max) {
            .auto => true,
            .fixed, .percent, .min_content, .max_content, .fr, .fit_content => false,
        },
        .fixed, .percent, .min_content, .max_content, .fr, .fit_content, .repeat => false,
    };
}
fn trackHasIntrinsicMaximum(track: style.GridTrack, basis: ?f32) bool {
    return switch (track) {
        .auto, .min_content, .max_content, .fit_content => true,
        .minmax => |value| switch (value.max) {
            .auto, .min_content, .max_content, .fit_content => true,
            .percent => basis == null,
            .fixed, .fr => false,
        },
        .percent => basis == null,
        .fixed, .fr, .repeat => false,
    };
}

fn trackHasDefiniteMaximum(track: style.GridTrack, basis: ?f32) bool {
    return switch (track) {
        .fixed => true,
        .percent => basis != null,
        .minmax => |value| switch (value.max) {
            .fixed => true,
            .percent => basis != null,
            .auto, .min_content, .max_content, .fr, .fit_content => false,
        },
        .auto, .min_content, .max_content, .fr, .fit_content, .repeat => false,
    };
}

fn trackIsFlexible(track: style.GridTrack) bool {
    return switch (track) {
        .fr => true,
        .minmax => |value| switch (value.max) {
            .fr => true,
            .fixed, .percent, .auto, .min_content, .max_content, .fit_content => false,
        },
        .fixed, .percent, .auto, .min_content, .max_content, .fit_content, .repeat => false,
    };
}

fn trackHasZeroFlexWeight(track: style.GridTrack) bool {
    return switch (track) {
        .fr => |weight| weight == 0,
        .minmax => |value| switch (value.max) {
            .fr => |weight| weight == 0,
            .fixed, .percent, .auto, .min_content, .max_content, .fit_content => false,
        },
        .fixed, .percent, .auto, .min_content, .max_content, .fit_content, .repeat => false,
    };
}

fn trackHasIntrinsicMinimum(track: style.GridTrack) bool {
    return switch (track) {
        .auto, .min_content, .max_content, .fit_content, .fr => true,
        .minmax => |value| switch (value.min) {
            .auto, .min_content, .max_content, .fit_content => true,
            .fixed, .percent, .fr => false,
        },
        .fixed, .percent, .repeat => false,
    };
}
fn trackMinimumBreadth(track: style.GridTrack) style.GridTrackBreadth {
    return switch (track) {
        .fixed => |value| .{ .fixed = value },
        .percent => |value| .{ .percent = value },
        .auto => .auto,
        .min_content => .min_content,
        .max_content => .max_content,
        .fr => |value| .{ .fr = value },
        .fit_content => .auto,
        .minmax => |value| value.min,
        .repeat => .auto,
    };
}

fn breadthHasDefiniteMinimum(
    breadth: style.GridTrackBreadth,
    basis: ?f32,
) bool {
    return switch (breadth) {
        .fixed => true,
        .percent => basis != null,
        .auto, .min_content, .max_content, .fr, .fit_content => false,
    };
}

fn trackMinimumIsDefinite(track: style.GridTrack, basis: ?f32) bool {
    return breadthHasDefiniteMinimum(trackMinimumBreadth(track), basis);
}

fn trackMinimumIsContent(track: style.GridTrack) bool {
    return switch (trackMinimumBreadth(track)) {
        .min_content, .max_content => true,
        .fixed, .percent, .auto, .fr, .fit_content => false,
    };
}

fn trackMinimumIsMaxContent(track: style.GridTrack) bool {
    return switch (trackMinimumBreadth(track)) {
        .max_content => true,
        .fixed, .percent, .auto, .min_content, .fr, .fit_content => false,
    };
}

fn trackAllowsIntrinsicContribution(track: style.GridTrack) bool {
    if (trackHasZeroFlexWeight(track)) return trackHasIntrinsicMinimum(track);
    return trackAllowsIntrinsic(track);
}
fn trackFraction(track: style.GridTrack) f32 {
    return switch (track) {
        .fr => |value| value,
        .minmax => |value| switch (value.max) {
            .fr => |weight| weight,
            else => 0,
        },
        .fixed, .percent, .auto, .min_content, .max_content, .fit_content, .repeat => 0,
    };
}

fn gapSpecified(value: style.LengthPercentage) bool {
    return switch (value) {
        .length => |number| number != 0,
        .percent => true,
    };
}

fn selectAxisGap(
    axis: style.LengthPercentage,
    generic: style.LengthPercentage,
) style.LengthPercentage {
    return if (gapSpecified(axis)) axis else generic;
}

fn gridGap(input: style.Style, axis: TrackAxis, basis: ?f32) Error!f32 {
    const value = switch (axis) {
        .columns => selectAxisGap(
            input.column_gap,
            input.gap,
        ),
        .rows => selectAxisGap(
            input.row_gap,
            input.gap,
        ),
    };
    try validateLengthPercentage(value, false);
    return finiteNonNegative(value.resolve(basis) orelse 0);
}

fn collapseAutoFitTracks(
    tracks: []Track,
    items: []const FlowItem,
    axis: TrackAxis,
) void {
    for (tracks, 0..) |*track, index| {
        if (!track.auto_fit) continue;
        var used = false;
        for (items) |item| {
            const placement = switch (axis) {
                .columns => item.column,
                .rows => item.row,
            };
            if (placement.start <= index and index < placement.end) {
                used = true;
                break;
            }
        }
        if (!used) {
            track.collapsed = true;
            track.size = 0;
            track.can_stretch_in_alignment = false;
        }
    }
}
fn visibleTrackCount(tracks: []const Track) usize {
    var count: usize = 0;
    for (tracks) |track| {
        if (!track.collapsed) count += 1;
    }
    return count;
}

fn spanGapTotal(tracks: []const Track, start: usize, end: usize, gap: f32) Error!f32 {
    if (start >= end or end > tracks.len) return error.InvalidStyle;
    var result: f32 = 0;
    var visible_count: usize = 0;
    for (tracks[start..end]) |track| {
        if (track.collapsed) continue;
        if (visible_count != 0) result = try add(result, gap);
        visible_count += 1;
    }
    return result;
}

fn trackSpanTotal(tracks: []const Track, start: usize, end: usize, gap: f32) Error!f32 {
    if (start >= end or end > tracks.len) return error.InvalidStyle;
    var result: f32 = 0;
    var visible_count: usize = 0;
    for (tracks[start..end]) |track| {
        if (track.collapsed) continue;
        if (visible_count != 0) result = try add(result, gap);
        result = try add(result, track.size);
        visible_count += 1;
    }
    return result;
}

fn trackTotal(tracks: []const Track, gap: f32) Error!f32 {
    var result: f32 = 0;
    var visible_count: usize = 0;
    for (tracks) |track| {
        if (track.collapsed) continue;
        if (visible_count != 0) result = try add(result, gap);
        result = try add(result, track.size);
        visible_count += 1;
    }
    return finite(result);
}

fn buildOffsets(
    allocator: std.mem.Allocator,
    offsets: *std.ArrayList(f32),
    tracks: []const Track,
    gap: f32,
    offset: f32,
    extra_gap: f32,
) Error!void {
    offsets.clearRetainingCapacity();
    var cursor = try finite(offset);
    var visible = false;
    for (tracks) |track| {
        if (!track.collapsed and visible) {
            cursor = try add(cursor, try add(gap, extra_gap));
        }
        try offsets.append(allocator, cursor);
        if (!track.collapsed) {
            cursor = try add(cursor, track.size);
            visible = true;
        }
    }
}

fn justifyContent(mode: style.Justify, free: f32, count: usize) Error!Distribution {
    const available = try finite(free);
    const distributed = @max(0, available);
    if (count == 0) return .{ .offset = 0, .extra_gap = 0 };
    const count_f = try countToF32(count);
    return switch (mode) {
        .normal, .start, .flex_start => .{ .offset = 0, .extra_gap = 0 },
        .safe_center => .{ .offset = distributed / 2, .extra_gap = 0 },
        .center, .unsafe_center => .{ .offset = available / 2, .extra_gap = 0 },
        .end, .flex_end => .{ .offset = available, .extra_gap = 0 },
        .safe_end => .{ .offset = distributed, .extra_gap = 0 },
        .unsafe_end => .{ .offset = available, .extra_gap = 0 },
        .space_between => .{
            .offset = 0,
            .extra_gap = if (count > 1)
                distributed / (try countToF32(count - 1))
            else
                0,
        },
        .space_around => .{ .offset = distributed / count_f / 2, .extra_gap = distributed / count_f },
        .space_evenly => .{
            .offset = distributed / (count_f + 1),
            .extra_gap = distributed / (count_f + 1),
        },
    };
}

fn alignContent(mode: style.AlignContent, free: f32, count: usize) Error!ContentDistribution {
    const available = try finite(free);
    const distributed = @max(0, available);
    if (count == 0) return .{ .offset = 0, .extra_gap = 0, .stretch = 0 };
    const count_f = try countToF32(count);
    return switch (mode) {
        .stretch => .{ .offset = 0, .extra_gap = 0, .stretch = distributed / count_f },
        .start, .flex_start => .{ .offset = 0, .extra_gap = 0, .stretch = 0 },
        .safe_center => .{ .offset = distributed / 2, .extra_gap = 0, .stretch = 0 },
        .center, .unsafe_center => .{ .offset = available / 2, .extra_gap = 0, .stretch = 0 },
        .end, .flex_end => .{ .offset = available, .extra_gap = 0, .stretch = 0 },
        .safe_end => .{ .offset = distributed, .extra_gap = 0, .stretch = 0 },
        .unsafe_end => .{ .offset = available, .extra_gap = 0, .stretch = 0 },
        .space_between => .{
            .offset = 0,
            .extra_gap = if (count > 1)
                distributed / (try countToF32(count - 1))
            else
                0,
            .stretch = 0,
        },
        .space_around => .{
            .offset = distributed / count_f / 2,
            .extra_gap = distributed / count_f,
            .stretch = 0,
        },
        .space_evenly => .{
            .offset = distributed / (count_f + 1),
            .extra_gap = distributed / (count_f + 1),
            .stretch = 0,
        },
    };
}

fn effectiveJustifyContent(input: style.Style) style.Justify {
    return if (input.grid_justify_content == .normal and input.justify != .start)
        input.justify
    else
        input.grid_justify_content;
}

fn effectiveAlignContent(input: style.Style) style.AlignContent {
    return if (input.grid_align_content == .stretch and input.align_content != .stretch)
        input.align_content
    else
        input.grid_align_content;
}

fn effectiveJustifyItems(input: style.Style) style.Align {
    return input.grid_justify_items;
}

fn effectiveAlignItems(input: style.Style) style.Align {
    return input.grid_align_items;
}

fn alignValue(
    value: style.AlignSelf,
    fallback: style.Align,
    directions_match: bool,
    axis_is_inline: bool,
) style.Align {
    const reverse_self = axis_is_inline and !directions_match;
    return switch (value) {
        .auto => fallback,
        .stretch => .stretch,
        .start, .flex_start => .start,
        .safe_center => .safe_center,
        .center => .center,
        .unsafe_center => .unsafe_center,
        .end, .flex_end => .end,
        .safe_end => .safe_end,
        .unsafe_end => .unsafe_end,
        .self_start => if (reverse_self) .end else .start,
        .self_end => if (reverse_self) .start else .end,
        .baseline => .baseline,
    };
}

fn alignOffset(
    value: style.Align,
    free: f32,
    directions_match: bool,
    axis_is_inline: bool,
) f32 {
    const reverse_self = axis_is_inline and !directions_match;
    return switch (value) {
        .stretch, .start, .flex_start, .baseline => 0,
        .safe_center => @max(0, free) / 2,
        .center, .unsafe_center => free / 2,
        .end, .flex_end, .unsafe_end => free,
        .safe_end => @max(0, free),
        .self_start => if (reverse_self) free else 0,
        .self_end => if (reverse_self) 0 else free,
    };
}

const AbsoluteArea = struct {
    start: f32,
    end: f32,

    fn width(self: AbsoluteArea) Error!f32 {
        return nonNegative(self.end - self.start);
    }
};
const AbsoluteBoundary = enum { start, end };

fn absoluteAreaFor(
    line: style.GridLine,
    explicit_count: usize,
    prepend: usize,
    tracks: []const Track,
    offsets: []const f32,
    content_extent: f32,
    frame_start: f32,
    frame_end: f32,
    reverse: bool,
) Error!AbsoluteArea {
    const start_line = try placementLine(line.start, explicit_count);
    const end_line = try placementLine(line.end, explicit_count);
    const start_span: ?usize = if (line.start == .span)
        try placementSpan(line.start)
    else
        null;
    const end_span: ?usize = if (line.end == .span)
        try placementSpan(line.end)
    else
        null;

    // Resolve each side before converting it to the final track index. A
    // span that cannot be resolved leaves only its opposite side definite.
    var logical_start: ?i128 = start_line;
    if (logical_start == null and line.start == .span) {
        if (end_line) |end| {
            if (start_span) |span| {
                logical_start = try subtractLineSpan(end, span);
            }
        }
    }
    var logical_end: ?i128 = end_line;
    if (logical_end == null and line.end == .span) {
        if (start_line) |start| {
            if (end_span) |span| {
                logical_end = try addLineSpan(start, span);
            }
        }
    }

    // Grid placement normalizes reversed lines and expands equal lines.
    if (logical_start != null and logical_end != null) {
        if (logical_end.? < logical_start.?) {
            const old_start = logical_start.?;
            logical_start = logical_end;
            logical_end = old_start;
        }
        if (logical_end.? == logical_start.?) {
            logical_end = try addLineSpan(logical_start.?, 1);
        }
    }

    const start_index: ?usize = if (logical_start) |logical| blk: {
        const index = try shiftedLineIndex(logical, prepend);
        if (index > tracks.len) break :blk null;
        break :blk index;
    } else null;
    const end_index: ?usize = if (logical_end) |logical| blk: {
        const index = try shiftedLineIndex(logical, prepend);
        if (index > tracks.len) break :blk null;
        break :blk index;
    } else null;

    if (start_index != null and end_index != null) {
        const logical_start_offset = try absoluteBoundaryOffset(
            start_index.?,
            tracks,
            offsets,
            .start,
        );
        const logical_end_offset = try absoluteBoundaryOffset(
            end_index.?,
            tracks,
            offsets,
            .end,
        );
        return if (reverse)
            .{
                .start = try finite(content_extent - logical_end_offset),
                .end = try finite(content_extent - logical_start_offset),
            }
        else
            .{ .start = logical_start_offset, .end = logical_end_offset };
    }

    if (start_index) |index| {
        const logical_start_offset = try absoluteBoundaryOffset(
            index,
            tracks,
            offsets,
            .start,
        );
        return if (reverse)
            .{
                .start = frame_start,
                .end = try finite(content_extent - logical_start_offset),
            }
        else
            .{ .start = logical_start_offset, .end = frame_end };
    }

    if (end_index) |index| {
        const logical_end_offset = try absoluteBoundaryOffset(
            index,
            tracks,
            offsets,
            .end,
        );
        return if (reverse)
            .{
                .start = try finite(content_extent - logical_end_offset),
                .end = frame_end,
            }
        else
            .{ .start = frame_start, .end = logical_end_offset };
    }

    return .{ .start = frame_start, .end = frame_end };
}

fn absoluteBoundaryOffset(
    index: usize,
    tracks: []const Track,
    offsets: []const f32,
    boundary: AbsoluteBoundary,
) Error!f32 {
    if (index > tracks.len or offsets.len < tracks.len) return error.InvalidStyle;
    if (boundary == .start) {
        var next = index;
        while (next < tracks.len) : (next += 1) {
            if (!tracks[next].collapsed) return finite(offsets[next]);
        }
        var previous = index;
        while (previous > 0) {
            previous -= 1;
            if (!tracks[previous].collapsed) {
                return add(offsets[previous], tracks[previous].size);
            }
        }
        return 0;
    }
    var previous = index;
    while (previous > 0) {
        previous -= 1;
        if (!tracks[previous].collapsed) {
            return add(offsets[previous], tracks[previous].size);
        }
    }
    var next = index;
    while (next < tracks.len) : (next += 1) {
        if (!tracks[next].collapsed) return finite(offsets[next]);
    }
    return 0;
}
fn absoluteSizeFromInsets(
    available: f32,
    start: f32,
    end: f32,
    margin_start: f32,
    margin_end: f32,
) Error!f32 {
    return @max(0, try finite(available - start - end - margin_start - margin_end));
}

fn distributeAbsoluteAutoMargins(
    start: *f32,
    end: *f32,
    start_auto: bool,
    end_auto: bool,
    available: f32,
    size: f32,
    start_inset: f32,
    end_inset: f32,
) Error!void {
    if (!start_auto and !end_auto) return;
    const fixed_start = if (start_auto) 0 else start.*;
    const fixed_end = if (end_auto) 0 else end.*;
    const remaining = try finite(
        available - start_inset - end_inset - size - fixed_start - fixed_end,
    );
    const distributed = @max(0, remaining);
    if (start_auto and end_auto) {
        start.* = distributed / 2;
        end.* = distributed / 2;
    } else if (start_auto) {
        start.* = distributed;
    } else {
        end.* = distributed;
    }
}

fn placeAbsolute(
    tree: *widget.WidgetTree,
    container: *widget.WidgetNode,
    content: widget.Size,
    container_edges: Edges,
    placement_origins: PlacementOrigins,
    explicit_columns: usize,
    explicit_rows: usize,
    columns: []const Track,
    rows: []const Track,
    column_offsets: []const f32,
    row_offsets: []const f32,
    writing_direction: style.Direction,
    options: Options,
    depth: usize,
) Error!void {
    for (container.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        const child = &tree.nodes.items[child_index];
        if (child.layout_hidden or child.style.position != .absolute) continue;
        const frame_start_x = try finite(-container_edges.raw_padding.left);
        const frame_end_x = try add(content.width, container_edges.raw_padding.right);
        const column_area = try absoluteAreaFor(
            gridLineFor(child.style, .columns),
            explicit_columns,
            placement_origins.column_prepend,
            columns,
            column_offsets,
            content.width,
            frame_start_x,
            frame_end_x,
            writing_direction == .rtl,
        );
        const area_x = column_area.start;
        const area_width = try column_area.width();

        const frame_start_y = try finite(-container_edges.raw_padding.top);
        const frame_end_y = try add(content.height, container_edges.raw_padding.bottom);
        const row_area = try absoluteAreaFor(
            gridLineFor(child.style, .rows),
            explicit_rows,
            placement_origins.row_prepend,
            rows,
            row_offsets,
            content.height,
            frame_start_y,
            frame_end_y,
            false,
        );
        const area_y = row_area.start;
        const area_height = try row_area.width();
        var natural_request = concreteRequest(.{ .width = area_width, .height = area_height });
        natural_request.width_mode = modeForDimension(
            child.style.size.width,
            .max_content,
            area_width,
        );
        natural_request.height_mode = modeForDimension(
            child.style.size.height,
            .max_content,
            area_height,
        );
        const natural = try measureNode(
            tree,
            child_index,
            natural_request,
            options,
            depth,
            container.style.display,
            true,
            .{},
        );
        const edges = try resolveEdges(child.style, area_width);
        child.resolved_box_edges = .{ .border = edges.border, .padding = edges.padding };
        var margins = try resolveMargins(child.style, area_width);
        const left = try resolveInset(child.style.inset.left, area_width);
        const right = try resolveInset(child.style.inset.right, area_width);
        const top = try resolveInset(child.style.inset.top, area_height);
        const bottom = try resolveInset(child.style.inset.bottom, area_height);
        const all_insets_definite = left != null and right != null and top != null and bottom != null;
        const has_aspect_ratio = child.style.aspect_ratio != null;
        const full_inset_aspect_ratio = child.style.size.width == .auto and
            child.style.size.height == .auto and
            has_aspect_ratio and
            all_insets_definite;
        var sizing_style = child.style;
        if (dimensionAuto(child.style.size.width) and left != null and right != null and
            !(has_aspect_ratio and !dimensionAuto(child.style.size.height)))
        {
            const inset_width = try absoluteSizeFromInsets(
                area_width,
                left.?,
                right.?,
                margins.value.left,
                margins.value.right,
            );
            const sizing_width = try borderToSizing(
                inset_width,
                edges.box_horizontal,
                child.style.box_sizing,
            );
            sizing_style.size.width = .{ .length = sizing_width };
        }
        if (dimensionAuto(child.style.size.height) and top != null and bottom != null and
            !full_inset_aspect_ratio and
            !(has_aspect_ratio and !dimensionAuto(child.style.size.width)))
        {
            const inset_height = try absoluteSizeFromInsets(
                area_height,
                top.?,
                bottom.?,
                margins.value.top,
                margins.value.bottom,
            );
            const sizing_height = try borderToSizing(
                inset_height,
                edges.box_vertical,
                child.style.box_sizing,
            );
            sizing_style.size.height = .{ .length = sizing_height };
        }
        const child_size = try usedSize(
            sizing_style,
            .{ .width = area_width, .height = area_height },
            natural.content,
            edges,
            null,
        );

        const directions_match = child.style.writing_direction == writing_direction;
        const justify_items = effectiveJustifyItems(container.style);
        const align_items = effectiveAlignItems(container.style);
        const justify_self = alignValue(
            child.style.grid_justify_self,
            justify_items,
            directions_match,
            true,
        );
        const align_self = alignValue(
            child.style.grid_align_self,
            align_items,
            directions_match,
            false,
        );

        if (left == null and right == null) {
            const start_inset = left orelse 0;
            const end_inset = right orelse 0;
            try distributeAbsoluteAutoMargins(
                &margins.value.left,
                &margins.value.right,
                margins.left_auto,
                margins.right_auto,
                area_width,
                child_size.width,
                start_inset,
                end_inset,
            );
        }
        if (top == null and bottom == null) {
            const start_inset = top orelse 0;
            const end_inset = bottom orelse 0;
            try distributeAbsoluteAutoMargins(
                &margins.value.top,
                &margins.value.bottom,
                margins.top_auto,
                margins.bottom_auto,
                area_height,
                child_size.height,
                start_inset,
                end_inset,
            );
        }

        const left_wins = left != null and (right == null or writing_direction == .ltr);
        const x = if (left_wins) blk: {
            const left_value = left orelse return error.InvalidStyle;
            break :blk try add(area_x, try add(left_value, margins.value.left));
        } else if (right) |value|
            try finite(area_x + area_width - value - margins.value.right - child_size.width)
        else if (writing_direction == .rtl and child.style.grid_justify_self == .auto and
            justify_items == .stretch)
        blk: {
            const static_end = try add(area_x, area_width);
            break :blk try finite(static_end - margins.value.right - child_size.width);
        } else blk: {
            const free_width = try finite(
                area_width - child_size.width - margins.value.left - margins.value.right,
            );
            const alignment_offset = alignOffset(justify_self, free_width, directions_match, true);
            const physical_alignment_offset = if (writing_direction == .rtl)
                free_width - alignment_offset
            else
                alignment_offset;
            break :blk try add(area_x, try add(margins.value.left, physical_alignment_offset));
        };

        const top_wins = top != null;
        const y = if (top_wins) blk: {
            const top_value = top orelse return error.InvalidStyle;
            break :blk try add(area_y, try add(top_value, margins.value.top));
        } else if (bottom) |value|
            try finite(area_y + area_height - value - margins.value.bottom - child_size.height)
        else blk: {
            const free_height = try finite(
                area_height - child_size.height - margins.value.top - margins.value.bottom,
            );
            const offset = alignOffset(align_self, free_height, directions_match, false);
            break :blk try add(area_y, try add(margins.value.top, offset));
        };
        child.rect = .{ .x = x, .y = y, .w = child_size.width, .h = child_size.height };
        try checkRect(child.rect);
        if (options.context) |context| {
            if (child.children.items.len == 0 or child.style.display != .grid) {
                try context.layout_node(
                    context,
                    tree,
                    child,
                    .{
                        .available = .{ .width = area_width, .height = area_height },
                        .percentage_basis = .{
                            .width = area_width,
                            .height = area_height,
                        },
                        .border = .{
                            .width = child.rect.w,
                            .height = child.rect.h,
                        },
                    },
                );
                continue;
            }
        }
        if (child.children.items.len != 0) {
            try layoutGridNode(
                tree,
                child_index,
                .{ .width = area_width, .height = area_height },
                child_size,
                options,
                depth,
            );
        }
    }
}

fn requestSizingStyle(
    input: style.Style,
    request: layout_context.Request,
    edges: Edges,
) Error!style.Style {
    var result = input;
    switch (request.sizing_mode) {
        .content => {
            result.aspect_ratio = null;
            if (request.known_border.width) |known| {
                const sizing_width = try borderToSizing(
                    known,
                    edges.box_horizontal,
                    input.box_sizing,
                );
                result.size.width = .{ .length = sizing_width };
            } else {
                result.size.width = .auto;
            }
            if (request.known_border.height) |known| {
                const sizing_height = try borderToSizing(
                    known,
                    edges.box_vertical,
                    input.box_sizing,
                );
                result.size.height = .{ .length = sizing_height };
            } else {
                result.size.height = .auto;
            }
            result.min_size = .{ .width = .auto, .height = .auto };
            result.max_size = .{ .width = .auto, .height = .auto };
        },
        .inherent => {
            if (request.known_border.width) |known| {
                const sizing_width = try borderToSizing(
                    known,
                    edges.box_horizontal,
                    input.box_sizing,
                );
                result.size.width = .{
                    .length = sizing_width,
                };
                result.min_size.width = .auto;
                result.max_size.width = .auto;
            }
            if (request.known_border.height) |known| {
                const sizing_height = try borderToSizing(
                    known,
                    edges.box_vertical,
                    input.box_sizing,
                );
                result.size.height = .{
                    .length = sizing_height,
                };
                result.min_size.height = .auto;
                result.max_size.height = .auto;
            }
        },
    }
    return result;
}

fn usedSizeForRequest(
    input: style.Style,
    percentage_basis: style.Size(?f32),
    intrinsic: widget.Size,
    edges: Edges,
    fallback: ?widget.Size,
    request: layout_context.Request,
) Error!widget.Size {
    if (request.sizing_mode == .inherent and
        request.known_border.width == null and
        request.known_border.height == null)
    {
        return usedSize(input, percentage_basis, intrinsic, edges, fallback);
    }

    const sizing_input = try requestSizingStyle(input, request, edges);
    var result = try usedSize(sizing_input, percentage_basis, intrinsic, edges, fallback);
    if (request.known_border.width) |known| {
        result.width = @max(try nonNegative(known), edges.horizontal);
    } else if (request.sizing_mode == .content) {
        result.width = @max(result.width, edges.horizontal);
    }
    if (request.known_border.height) |known| {
        result.height = @max(try nonNegative(known), edges.vertical);
    } else if (request.sizing_mode == .content) {
        result.height = @max(result.height, edges.vertical);
    }
    return result;
}

fn usedSize(
    input: style.Style,
    percentage_basis: style.Size(?f32),
    intrinsic: widget.Size,
    edges: Edges,
    fallback: ?widget.Size,
) Error!widget.Size {
    const width_adjustment = dimensionAdjustment(
        input.size.width,
        edges.horizontal,
        edges.box_horizontal,
    );
    const height_adjustment = dimensionAdjustment(
        input.size.height,
        edges.vertical,
        edges.box_vertical,
    );
    var width = try resolveDimensionBorder(
        input.size.width,
        percentage_basis.width,
        intrinsic.width,
        width_adjustment,
        input.box_sizing,
    );
    var height = try resolveDimensionBorder(
        input.size.height,
        percentage_basis.height,
        intrinsic.height,
        height_adjustment,
        input.box_sizing,
    );
    const width_resolved_border = width != null;
    const height_resolved_border = height != null;
    var width_edge_sum = width_adjustment;
    var height_edge_sum = height_adjustment;

    // Aspect-ratio transfer from a definite cross size to an auto main size
    // must happen before the intrinsic fallback, so that a definite cross size
    // with an aspect ratio produces the correct main size even when the main
    // axis has no explicit size.
    if (width == null and height != null and input.aspect_ratio != null) {
        const height_sizing = if (height_resolved_border)
            try borderToSizing(height.?, height_adjustment, input.box_sizing)
        else
            height.?;
        width = try finite(height_sizing * try ratio(input.aspect_ratio.?));
        width_edge_sum = edges.box_horizontal;
    }

    if (width == null) {
        if (fallback) |value| {
            width = try borderToSizing(value.width, edges.horizontal, input.box_sizing);
            width_edge_sum = edges.horizontal;
        } else {
            width = try contentToSizing(
                intrinsic.width,
                edges.horizontal,
                edges.box_horizontal,
                input.box_sizing,
            );
            width_edge_sum = edges.box_horizontal;
        }
    }
    if (height == null and input.aspect_ratio != null and width != null) {
        const width_sizing = if (width_resolved_border)
            try borderToSizing(width.?, width_adjustment, input.box_sizing)
        else
            width.?;
        height = try finite(width_sizing / try ratio(input.aspect_ratio.?));
        height_edge_sum = edges.box_vertical;
    }
    if (height == null) {
        if (fallback) |value| {
            height = try borderToSizing(value.height, edges.vertical, input.box_sizing);
            height_edge_sum = edges.vertical;
        } else {
            height = try contentToSizing(
                intrinsic.height,
                edges.vertical,
                edges.box_vertical,
                input.box_sizing,
            );
            height_edge_sum = edges.box_vertical;
        }
    }
    var result: widget.Size = .{
        .width = if (width_resolved_border) blk: {
            const resolved_width = width orelse return error.InvalidStyle;
            break :blk resolved_width;
        } else try sizingToBorder(width orelse 0, width_edge_sum, input.box_sizing),
        .height = if (height_resolved_border) blk: {
            const resolved_height = height orelse return error.InvalidStyle;
            break :blk resolved_height;
        } else try sizingToBorder(height orelse 0, height_edge_sum, input.box_sizing),
    };
    result.width = try clampAxisSize(
        input,
        .horizontal,
        result.width,
        percentage_basis,
        intrinsic,
        edges,
    );
    result.height = try clampAxisSize(
        input,
        .vertical,
        result.height,
        percentage_basis,
        intrinsic,
        edges,
    );
    return .{
        .width = @max(edges.box_horizontal, result.width),
        .height = @max(edges.box_vertical, result.height),
    };
}

fn clampAxisSize(
    input: style.Style,
    axis: enum { horizontal, vertical },
    candidate: f32,
    percentage_basis: style.Size(?f32),
    intrinsic: widget.Size,
    edges: Edges,
) Error!f32 {
    const minimum_dimension = if (axis == .horizontal)
        input.min_size.width
    else
        input.min_size.height;
    const maximum_dimension = if (axis == .horizontal)
        input.max_size.width
    else
        input.max_size.height;

    const basis = if (axis == .horizontal) percentage_basis.width else percentage_basis.height;
    const natural = if (axis == .horizontal) intrinsic.width else intrinsic.height;
    const content_inset = if (axis == .horizontal) edges.horizontal else edges.vertical;
    const box_adjustment = if (axis == .horizontal) edges.box_horizontal else edges.box_vertical;
    const minimum = (try resolveDimensionBorder(
        minimum_dimension,
        basis,
        natural,
        dimensionAdjustment(minimum_dimension, content_inset, box_adjustment),
        input.box_sizing,
    )) orelse 0;
    const maximum = try resolveDimensionBorder(
        maximum_dimension,
        basis,
        natural,
        dimensionAdjustment(maximum_dimension, content_inset, box_adjustment),
        input.box_sizing,
    );
    var result = try nonNegative(candidate);
    if (maximum) |upper| result = @min(result, try nonNegative(upper));
    return @max(result, try nonNegative(minimum));
}
fn reapplyAspectRatio(
    input: style.Style,
    candidate: widget.Size,
    percentage_basis: style.Size(?f32),
    intrinsic: widget.Size,
    edges: Edges,
) Error!widget.Size {
    const ratio_value = input.aspect_ratio orelse return candidate;
    const width_auto = dimensionAuto(input.size.width);
    const height_auto = dimensionAuto(input.size.height);
    if (!width_auto and !height_auto) return candidate;
    const aspect = try ratio(ratio_value);
    var width = try nonNegative(candidate.width);
    var height = try nonNegative(candidate.height);
    if (width_auto and height_auto) {
        if (width <= 0 and height > 0) {
            width = try finite(height * aspect);
        } else if (height <= 0 and width > 0) {
            height = try finite(width / aspect);
        } else if (width > height * aspect) {
            width = try finite(height * aspect);
        } else {
            height = try finite(width / aspect);
        }
        var iteration: usize = 0;
        while (iteration < 4) : (iteration += 1) {
            const clamped_width = try clampAxisSize(
                input,
                .horizontal,
                width,
                percentage_basis,
                intrinsic,
                edges,
            );
            const clamped_height = try clampAxisSize(
                input,
                .vertical,
                height,
                percentage_basis,
                intrinsic,
                edges,
            );
            if (clamped_width != width) {
                width = clamped_width;
                height = try finite(width / aspect);
                continue;
            }
            if (clamped_height != height) {
                height = clamped_height;
                width = try finite(height * aspect);
                continue;
            }
            break;
        }
        return .{
            .width = try clampAxisSize(input, .horizontal, width, percentage_basis, intrinsic, edges),
            .height = try clampAxisSize(input, .vertical, height, percentage_basis, intrinsic, edges),
        };
    }
    if (width_auto) {
        width = try finite(height * aspect);
        width = try clampAxisSize(input, .horizontal, width, percentage_basis, intrinsic, edges);
    } else {
        height = try finite(width / aspect);
        height = try clampAxisSize(input, .vertical, height, percentage_basis, intrinsic, edges);
    }
    return .{ .width = width, .height = height };
}

fn dimensionAdjustment(
    dimension: style.Dimension,
    content_inset: f32,
    box_adjustment: f32,
) f32 {
    return switch (dimension) {
        .length, .percent => box_adjustment,
        .auto, .min_content, .max_content, .fit_content => content_inset,
    };
}

fn resolveDimensionBorder(
    dimension: style.Dimension,
    percentage_basis: ?f32,
    intrinsic: f32,
    edges: f32,
    box_sizing: style.BoxSizing,
) Error!?f32 {
    const value: ?f32 = switch (dimension) {
        .auto => null,
        .min_content, .max_content => try nonNegative(intrinsic),
        .fit_content => |limit| blk: {
            const non_neg_intrinsic = try nonNegative(intrinsic);
            if (limit) |lim| {
                const non_neg_limit = try finiteNonNegative(lim);
                break :blk @min(non_neg_intrinsic, non_neg_limit);
            }
            break :blk non_neg_intrinsic;
        },
        .length => |number| try finite(number),
        .percent => |fraction| if (percentage_basis) |basis|
            @as(?f32, try finite(fraction * basis))
        else
            null,
    };
    if (value) |number| {
        const sizing_value = switch (dimension) {
            .min_content, .max_content, .fit_content => try contentToSizing(
                number,
                edges,
                edges,
                box_sizing,
            ),
            .length, .percent => number,
            .auto => unreachable,
        };
        return @as(?f32, try sizingToBorder(sizing_value, edges, box_sizing));
    }
    return null;
}

fn contentToSizing(
    content: f32,
    content_inset: f32,
    box_adjustment: f32,
    box_sizing: style.BoxSizing,
) Error!f32 {
    const border = try add(try nonNegative(content), content_inset);
    return borderToSizing(border, box_adjustment, box_sizing);
}

fn sizingToBorder(value: f32, edges: f32, box_sizing: style.BoxSizing) Error!f32 {
    return switch (box_sizing) {
        .content_box => add(try nonNegative(value), edges),
        .border_box => @max(edges, try nonNegative(value)),
    };
}

fn borderToSizing(value: f32, edges: f32, box_sizing: style.BoxSizing) Error!f32 {
    return switch (box_sizing) {
        .content_box => @max(0, try finite(value - edges)),
        .border_box => nonNegative(value),
    };
}

fn resolveEdges(input: style.Style, basis: ?f32) Error!Edges {
    const scrollbar_width = try finite(input.scrollbar_width);
    if (scrollbar_width < 0) return error.InvalidStyle;
    const scrollbar_gutter = input.scrollbarGutter();
    const border: style.Sides = .{
        .top = try edge(input.border_inset.top, basis),
        .right = try edge(input.border_inset.right, basis),
        .bottom = try edge(input.border_inset.bottom, basis),
        .left = try edge(input.border_inset.left, basis),
    };
    const resolved_padding: style.Sides = .{
        .top = try edge(input.padding_inset.top, basis),
        .right = try edge(input.padding_inset.right, basis),
        .bottom = try edge(input.padding_inset.bottom, basis),
        .left = try edge(input.padding_inset.left, basis),
    };
    const padding: style.Sides = .{
        .top = try add(resolved_padding.top, scrollbar_gutter.top),
        .right = try add(resolved_padding.right, scrollbar_gutter.right),
        .bottom = try add(resolved_padding.bottom, scrollbar_gutter.bottom),
        .left = try add(resolved_padding.left, scrollbar_gutter.left),
    };
    const box_horizontal = try add(
        try add(border.left, border.right),
        try add(resolved_padding.left, resolved_padding.right),
    );
    const box_vertical = try add(
        try add(border.top, border.bottom),
        try add(resolved_padding.top, resolved_padding.bottom),
    );
    return .{
        .border = border,
        .padding = padding,
        .raw_padding = resolved_padding,
        .box_horizontal = box_horizontal,
        .box_vertical = box_vertical,
        .horizontal = try add(
            box_horizontal,
            try add(scrollbar_gutter.left, scrollbar_gutter.right),
        ),
        .vertical = try add(
            box_vertical,
            try add(scrollbar_gutter.top, scrollbar_gutter.bottom),
        ),
    };
}
fn clampScrollbarGutter(input: Edges, border_size: widget.Size) Error!Edges {
    var result = input;
    const available_width = @max(
        0,
        try finite(border_size.width - input.box_horizontal),
    );
    const available_height = @max(
        0,
        try finite(border_size.height - input.box_vertical),
    );
    const gutter: style.Sides = .{
        .top = @min(
            @max(0, try finite(input.padding.top - input.raw_padding.top)),
            available_height,
        ),
        .right = @min(
            @max(0, try finite(input.padding.right - input.raw_padding.right)),
            available_width,
        ),
        .bottom = @min(
            @max(0, try finite(input.padding.bottom - input.raw_padding.bottom)),
            available_height,
        ),
        .left = @min(
            @max(0, try finite(input.padding.left - input.raw_padding.left)),
            available_width,
        ),
    };
    result.padding = .{
        .top = try add(input.raw_padding.top, gutter.top),
        .right = try add(input.raw_padding.right, gutter.right),
        .bottom = try add(input.raw_padding.bottom, gutter.bottom),
        .left = try add(input.raw_padding.left, gutter.left),
    };
    result.horizontal = try add(
        input.box_horizontal,
        try add(gutter.left, gutter.right),
    );
    result.vertical = try add(
        input.box_vertical,
        try add(gutter.top, gutter.bottom),
    );
    return result;
}

fn edge(value: style.LengthPercentage, basis: ?f32) Error!f32 {
    return switch (value) {
        .length => |number| nonNegative(number),
        .percent => |fraction| blk: {
            const percentage_basis = basis orelse break :blk @as(f32, 0);
            break :blk nonNegative(try finite(fraction * percentage_basis));
        },
    };
}

fn resolveMargins(input: style.Style, basis: ?f32) Error!Margins {
    return .{
        .value = .{
            .top = try margin(input.margin_inset.top, basis),
            .right = try margin(input.margin_inset.right, basis),
            .bottom = try margin(input.margin_inset.bottom, basis),
            .left = try margin(input.margin_inset.left, basis),
        },
        .top_auto = isAuto(input.margin_inset.top),
        .right_auto = isAuto(input.margin_inset.right),
        .bottom_auto = isAuto(input.margin_inset.bottom),
        .left_auto = isAuto(input.margin_inset.left),
    };
}

fn margin(value: style.LengthPercentageAuto, basis: ?f32) Error!f32 {
    return switch (value) {
        .auto => 0,
        .length => |number| finite(number),
        .percent => |fraction| blk: {
            const percentage_basis = basis orelse break :blk @as(f32, 0);
            break :blk finite(fraction * percentage_basis);
        },
    };
}

fn resolveInset(value: style.LengthPercentageAuto, basis: f32) Error!?f32 {
    return switch (value) {
        .auto => null,
        .length => |number| blk: {
            const resolved = try finite(number);
            break :blk @as(?f32, resolved);
        },
        .percent => |fraction| blk: {
            const resolved = try finite(fraction * basis);
            break :blk @as(?f32, resolved);
        },
    };
}

fn relativeInsets(node: *widget.WidgetNode, containing: widget.Size) Error!void {
    if (node.style.position != .relative) return;
    const left = try resolveInset(node.style.inset.left, containing.width);
    const right = try resolveInset(node.style.inset.right, containing.width);
    const top = try resolveInset(node.style.inset.top, containing.height);
    const bottom = try resolveInset(node.style.inset.bottom, containing.height);
    if (node.style.writing_direction == .rtl) {
        if (right) |value| {
            node.rect.x = try finite(node.rect.x - value);
        } else if (left) |value| {
            node.rect.x = try add(node.rect.x, value);
        }
    } else if (left) |value| {
        node.rect.x = try add(node.rect.x, value);
    } else if (right) |value| {
        node.rect.x = try finite(node.rect.x - value);
    }
    if (top) |value| {
        node.rect.y = try add(node.rect.y, value);
    } else if (bottom) |value| {
        node.rect.y = try finite(node.rect.y - value);
    }
}

fn paddingBoxContributionRect(
    rect: widget.Rect,
    client_width: f32,
    raw_padding: style.Sides,
    direction: style.Direction,
) Error!widget.Rect {
    const physical_x = try add(raw_padding.left, rect.x);
    const physical_right = try add(physical_x, rect.w);
    return .{
        .x = if (direction == .ltr)
            physical_x
        else
            try finite(client_width - physical_right),
        .y = try add(raw_padding.top, rect.y),
        .w = rect.w,
        .h = rect.h,
    };
}

fn publishContentSize(
    tree: *widget.WidgetTree,
    container: *widget.WidgetNode,
    pad_box: widget.Size,
    edges: Edges,
) Error!void {
    const gutter: style.Sides = .{
        .top = @max(0, try finite(edges.padding.top - edges.raw_padding.top)),
        .right = @max(0, try finite(edges.padding.right - edges.raw_padding.right)),
        .bottom = @max(0, try finite(edges.padding.bottom - edges.raw_padding.bottom)),
        .left = @max(0, try finite(edges.padding.left - edges.raw_padding.left)),
    };
    const client: widget.Size = .{
        .width = @max(0, try finite(pad_box.width - gutter.left - gutter.right)),
        .height = @max(0, try finite(pad_box.height - gutter.top - gutter.bottom)),
    };
    var inflow_extent: widget.Size = .{
        .width = 0,
        .height = 0,
    };
    var absolute_extent: widget.Size = .{
        .width = 0,
        .height = 0,
    };
    for (container.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        const child = &tree.nodes.items[child_index];
        if (child.layout_hidden) continue;
        const contribution_rect = try paddingBoxContributionRect(
            child.rect,
            client.width,
            edges.raw_padding,
            container.style.writing_direction,
        );
        const contribution = try overflow.contentContribution(
            contribution_rect,
            child.layout_content_size,
            child.style.overflow,
        );
        if (child.style.position == .absolute) {
            absolute_extent.width = @max(absolute_extent.width, contribution.width);
            absolute_extent.height = @max(absolute_extent.height, contribution.height);
        } else {
            inflow_extent.width = @max(inflow_extent.width, contribution.width);
            inflow_extent.height = @max(inflow_extent.height, contribution.height);
        }
    }
    const trailing_width = if (container.style.writing_direction == .rtl)
        edges.raw_padding.left
    else
        edges.raw_padding.right;
    const inflow_with_padding: widget.Size = .{
        .width = try add(inflow_extent.width, trailing_width),
        .height = try add(inflow_extent.height, edges.raw_padding.bottom),
    };
    const extent: widget.Size = .{
        .width = @max(inflow_with_padding.width, absolute_extent.width),
        .height = @max(inflow_with_padding.height, absolute_extent.height),
    };
    container.layout_content_size = extent;
    if (container.scroll) |scroll| {
        scroll.state.max_offset = try overflow.maxOffset(extent, client, scroll.axis);
    }
}

fn dimensionAuto(value: style.Dimension) bool {
    return value == .auto;
}

fn isAuto(value: style.LengthPercentageAuto) bool {
    return value == .auto;
}

fn checkSize(value: widget.Size) Error!void {
    _ = try finiteNonNegative(value.width);
    _ = try finiteNonNegative(value.height);
}

fn checkRect(value: widget.Rect) Error!void {
    _ = try finite(value.x);
    _ = try finite(value.y);
    _ = try finiteNonNegative(value.w);
    _ = try finiteNonNegative(value.h);
}

fn ratio(value: f32) Error!f32 {
    const result = try finite(value);
    if (result <= 0) return error.InvalidStyle;
    return result;
}

fn countToF32(value: usize) Error!f32 {
    if (value == 1 << 24) return 16_777_216;
    const exact: u24 = std.math.cast(u24, value) orelse return error.InvalidStyle;
    return @floatFromInt(exact);
}

fn add(left: f32, right: f32) Error!f32 {
    return finite(left + right);
}

fn finiteNonNegative(value: f32) Error!f32 {
    const result = try finite(value);
    if (result < 0) return error.InvalidStyle;
    return result;
}

fn nonNegative(value: f32) Error!f32 {
    return finiteNonNegative(value);
}

fn finite(value: f32) Error!f32 {
    if (!std.math.isFinite(value)) return error.InvalidStyle;
    return value;
}
