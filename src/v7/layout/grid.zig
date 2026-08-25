const std = @import("std");
const Id = @import("../id.zig").Id;
const layout_context = @import("context.zig");
const sizing = @import("sizing.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");

pub const MeasureFn = layout_context.MeasureFn;
pub const Options = struct {
    allocator: std.mem.Allocator,
    available: widget.Size,
    measure: ?MeasureFn,
    context: ?*layout_context.LayoutContext = null,
};
const Error = sizing.Error;
const TrackAxis = enum { columns, rows };

const Edges = struct {
    border: style.Sides,
    padding: style.Sides,
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
};

const Track = struct {
    spec: style.GridTrack,
    size: f32,
};

const AxisPlacement = struct {
    start: usize = 0,
    end: usize = 1,
    definite: bool = false,
};

const FlowItem = struct {
    index: usize,
    row: AxisPlacement,
    column: AxisPlacement,
    natural: Natural,
    margins: Margins,
};

const Cell = struct {
    row: usize,
    column: usize,
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

pub fn layoutContainer(tree: *widget.WidgetTree, container_id: Id, options: Options) Error!void {
    _ = try finite(options.available.width);
    _ = try finite(options.available.height);
    if (options.available.width < 0 or options.available.height < 0) return error.InvalidStyle;
    const index = tree.nodeIndex(container_id) orelse return error.InvalidStyle;
    if (container_id == .root) return error.InvalidStyle;

    try validateTreeInput(tree, index);
    var path: std.AutoHashMapUnmanaged(Id, void) = .empty;
    defer path.deinit(options.allocator);
    try validateSubtree(options.allocator, tree, index, null, @max(64, tree.nodes.items.len * 4), &path);
    try markHidden(tree, index, false, @max(64, tree.nodes.items.len * 4));
    try layoutPreparedContainer(tree, container_id, options, null);
}

/// Lay out a validated, already-prepared subtree without repeating validation
/// or hidden-state classification.
pub fn layoutPreparedContainer(
    tree: *widget.WidgetTree,
    container_id: Id,
    options: Options,
    forced_border: ?widget.Size,
) Error!void {
    const index = tree.nodeIndex(container_id) orelse return error.InvalidStyle;
    if (tree.nodes.items[index].layout_hidden) return;
    try layoutGridNode(tree, index, options.available, forced_border, options, @max(64, tree.nodes.items.len * 4));
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
    var natural_request = request;
    natural_request.forced_border = null;
    try layout_context.validateNaturalRequest(tree, node, natural_request);

    const natural = try measureNode(
        tree,
        index,
        natural_request,
        .{
            .allocator = context.allocator,
            .available = natural_request.available,
            .measure = context.measure,
            .context = context,
        },
        @max(64, tree.nodes.items.len * 4),
        null,
    );
    return .{
        .content = natural.content,
        .border = natural.border,
    };
}

fn validateTreeInput(tree: *const widget.WidgetTree, root_index: usize) Error!void {
    if (root_index >= tree.nodes.items.len) return error.InvalidStyle;
    var ids: std.AutoHashMapUnmanaged(Id, void) = .empty;
    defer ids.deinit(tree.allocator);

    for (tree.nodes.items) |node| {
        if (ids.contains(node.id)) return error.InvalidStyle;
        ids.put(tree.allocator, node.id, {}) catch return error.InvalidStyle;
        try validateStyle(node.style);
        try validateKind(node.kind);
        _ = try finite(node.font_size);
        if (node.text_max_width) |value| {
            _ = try finite(value);
            if (value < 0) return error.InvalidStyle;
        }
        if (node.parent != .root and tree.nodeIndex(node.parent) == null) return error.InvalidStyle;
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
    expected_parent: ?Id,
    depth: usize,
    path: *std.AutoHashMapUnmanaged(Id, void),
) Error!void {
    if (depth == 0 or index >= tree.nodes.items.len) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    if (expected_parent) |parent| {
        if (node.parent != parent) return error.InvalidStyle;
    }
    if (path.contains(node.id)) return error.InvalidStyle;
    path.put(allocator, node.id, {}) catch return error.InvalidStyle;
    defer _ = path.remove(node.id);

    for (node.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        try validateSubtree(allocator, tree, child_index, node.id, depth - 1, path);
    }

    if (node.style.display == .none) return;
    if (node.children.items.len != 0 and node.style.display != .grid) return error.InvalidStyle;
}

fn validateKind(kind: widget.WidgetKind) Error!void {
    switch (kind) {
        .column => |value| {
            _ = try finiteNonNegative(value.gap);
        },
        .row => |value| {
            _ = try finiteNonNegative(value.gap);
        },
        .label => {},
        .button => {},
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

fn validateStyle(input: style.Style) Error!void {
    try validateTrackSlice(input.grid_template_columns);
    try validateTrackSlice(input.grid_template_rows);
    try validateTrack(input.grid_auto_columns);
    try validateTrack(input.grid_auto_rows);
    _ = try finiteNonNegative(input.gap);
    _ = try finiteNonNegative(input.column_gap);
    _ = try finiteNonNegative(input.row_gap);
    _ = try finiteNonNegative(input.grid_column_gap);
    _ = try finiteNonNegative(input.grid_row_gap);
    _ = try finiteNonNegative(input.grow);
    _ = try finiteNonNegative(input.shrink);
    _ = try finite(input.basis);
    if (input.min_main) |value| _ = try finiteNonNegative(value);
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
    try validateSides(input.margin, true);
    try validateSides(input.border, true);
    try validateSides(input.padding, true);
    if (input.aspect_ratio) |value| {
        _ = try finite(value);
        if (value <= 0) return error.InvalidStyle;
    }
}

fn validateTrack(track: style.GridTrack) Error!void {
    switch (track) {
        .fixed => |value| {
            _ = try finiteNonNegative(value);
        },
        .percent => |value| {
            _ = try finiteNonNegative(value);
        },
        .fit_content => |value| {
            _ = try finiteNonNegative(value);
        },
        .auto, .min_content, .max_content => {},
        .fr => |value| {
            _ = try finiteNonNegative(value);
        },
        .minmax => |value| {
            try validateBreadth(value.min);
            try validateBreadth(value.max);
        },
    }
}

fn validateTrackSlice(tracks: []const style.GridTrack) Error!void {
    for (tracks) |track| try validateTrack(track);
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
            _ = try finiteNonNegative(value);
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

fn validateSides(value: style.Sides, negative_allowed: bool) Error!void {
    _ = try finite(value.top);
    _ = try finite(value.right);
    _ = try finite(value.bottom);
    _ = try finite(value.left);
    if (!negative_allowed and (value.top < 0 or value.right < 0 or value.bottom < 0 or value.left < 0)) {
        return error.InvalidStyle;
    }
}

fn markHidden(tree: *widget.WidgetTree, index: usize, inherited: bool, depth: usize) Error!void {
    if (depth == 0 or index >= tree.nodes.items.len) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    const hidden = inherited or node.style.display == .none;
    node.layout_hidden = hidden;
    if (hidden) {
        node.rect = .{};
        node.natural_main = 0;
        node.resolved_box_edges = null;
    }
    for (node.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        try markHidden(tree, child_index, hidden, depth - 1);
    }
}

fn measureNode(
    tree: *widget.WidgetTree,
    index: usize,
    request: layout_context.Request,
    options: Options,
    depth: usize,
    parent_display: ?style.Display,
) Error!Natural {
    if (depth == 0 or index >= tree.nodes.items.len) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    if (node.layout_hidden or node.style.display == .none) return .{
        .content = .{ .width = 0, .height = 0 },
        .border = .{ .width = 0, .height = 0 },
    };
    _ = try finiteNonNegative(request.available.width);
    _ = try finiteNonNegative(request.available.height);
    const edges = try resolveEdges(node.style, request.percentage_basis.width);
    var intrinsic: widget.Size = .{ .width = 0, .height = 0 };
    if (node.children.items.len == 0) {
        intrinsic = try measureLeaf(node, options.measure);
    } else if (options.context) |context| {
        if (parent_display) |display| {
            if (node.style.display != display) {
                const measured = try context.measure_node(
                    context,
                    tree,
                    node,
                    request,
                );
                return .{
                    .content = measured.content,
                    .border = measured.border,
                };
            }
        }
        if (node.style.display != .grid) return error.InvalidStyle;
        intrinsic = try measureGridContent(tree, index, request, edges, options, depth - 1);
    } else {
        if (node.style.display != .grid) return error.InvalidStyle;
        intrinsic = try measureGridContent(tree, index, request, edges, options, depth - 1);
    }
    const border = try usedSize(
        node.style,
        request.percentage_basis,
        intrinsic,
        edges,
        null,
    );
    return .{ .content = intrinsic, .border = border };
}

fn measureGridContent(
    tree: *widget.WidgetTree,
    index: usize,
    request: layout_context.Request,
    edges: Edges,
    options: Options,
    depth: usize,
) Error!widget.Size {
    if (depth == 0) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    const provisional = try usedSize(
        node.style,
        request.percentage_basis,
        request.available,
        edges,
        request.available,
    );
    const child_available: widget.Size = .{
        .width = @max(0, provisional.width - edges.horizontal),
        .height = @max(0, provisional.height - edges.vertical),
    };
    const width_definite = switch (node.style.size.width) {
        .length => true,
        .percent => request.percentage_basis.width != null,
        .auto, .min_content, .max_content, .fit_content => false,
    };
    const height_definite = switch (node.style.size.height) {
        .length => true,
        .percent => request.percentage_basis.height != null,
        .auto, .min_content, .max_content, .fit_content => false,
    };

    var columns: std.ArrayList(Track) = .empty;
    defer columns.deinit(options.allocator);
    var rows: std.ArrayList(Track) = .empty;
    defer rows.deinit(options.allocator);
    try initTracks(
        options.allocator,
        &columns,
        node.style.grid_template_columns,
        node.style.grid_auto_columns,
        if (width_definite) child_available.width else null,
    );
    try initTracks(
        options.allocator,
        &rows,
        node.style.grid_template_rows,
        node.style.grid_auto_rows,
        if (height_definite) child_available.height else null,
    );

    var items: std.ArrayList(FlowItem) = .empty;
    defer items.deinit(options.allocator);
    const child_request: layout_context.Request = .{
        .available = child_available,
        .percentage_basis = .{
            .width = if (width_definite) @as(?f32, child_available.width) else null,
            .height = if (height_definite) @as(?f32, child_available.height) else null,
        },
        .intrinsic_width = !width_definite,
        .intrinsic_height = !height_definite,
    };
    try collectItems(tree, node, child_request, options, depth - 1, &items);

    var occupied: std.AutoHashMapUnmanaged(Cell, void) = .empty;
    defer occupied.deinit(options.allocator);
    try placeItems(
        options.allocator,
        &columns,
        &rows,
        &items,
        node.style.grid_auto_flow,
        node.style.grid_auto_columns,
        node.style.grid_auto_rows,
        if (width_definite) child_available.width else null,
        if (height_definite) child_available.height else null,
        &occupied,
    );

    const column_gap = try gridGap(node.style, .columns);
    const row_gap = try gridGap(node.style, .rows);

    for (items.items) |item| {
        const width_need = try add(item.natural.border.width, item.margins.value.left + item.margins.value.right);
        const height_need = try add(item.natural.border.height, item.margins.value.top + item.margins.value.bottom);
        try growTracks(
            columns.items,
            item.column.start,
            item.column.end,
            width_need,
            column_gap,
            if (width_definite) child_available.width else null,
        );
        try growTracks(
            rows.items,
            item.row.start,
            item.row.end,
            height_need,
            row_gap,
            if (height_definite) child_available.height else null,
        );
    }

    if (width_definite) {
        try resolveFlexibleTracks(columns.items, child_available.width, column_gap);
    } else {
        try resolveIndefiniteFlexibleTracks(columns.items);
    }

    if (height_definite) {
        try resolveFlexibleTracks(rows.items, child_available.height, row_gap);
    } else {
        try resolveIndefiniteFlexibleTracks(rows.items);
    }

    const width = try trackTotal(columns.items, column_gap);
    const height = try trackTotal(rows.items, row_gap);

    return .{ .width = try nonNegative(width), .height = try nonNegative(height) };
}

fn naturalAxisDefinite(
    dimension: style.Dimension,
    intrinsic: bool,
    percentage_basis: ?f32,
) bool {
    return switch (dimension) {
        .length => true,
        .min_content, .max_content, .fit_content => false,
        .percent => percentage_basis != null,
        .auto => !intrinsic,
    };
}

fn concreteRequest(available: widget.Size) layout_context.Request {
    return .{
        .available = available,
        .percentage_basis = .{
            .width = available.width,
            .height = available.height,
        },
    };
}

fn measureLeaf(node: *const widget.WidgetNode, measure: ?MeasureFn) Error!widget.Size {
    var result: widget.Size = switch (node.kind) {
        .label => |label| if (measure) |callback| callback(label.text, node.font_size, node.font_id) else blk: {
            const font_size = try finiteNonNegative(node.font_size);
            const scale: f32 = if (font_size > 0) font_size / 20 else 1;
            const length: f32 = @floatFromInt(@min(label.text.len, 1 << 24));
            break :blk .{ .width = length * 10 * scale, .height = 20 * scale };
        },
        .spacer => |spacer| .{ .width = spacer.size, .height = spacer.size },
        .button => |button| .{
            .width = if (button.visual_label) |text|
                if (text.len == 0) 100 else @floatFromInt(text.len * 10 + 16)
            else
                100,
            .height = 32,
        },
        .slider => .{ .width = 100, .height = widget.slider_rail_height },
        .row, .column => .{ .width = 0, .height = 0 },
    };
    result.width = try nonNegative(result.width);
    result.height = try nonNegative(result.height);
    if (node.text_max_width) |maximum| {
        if (node.text_overflow != .visible) result.width = @min(result.width, try nonNegative(maximum));
    }
    return result;
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
    if (node.layout_hidden or node.style.display == .none) return;
    if (node.style.display != .grid) return error.InvalidStyle;
    const natural = try measureNode(
        tree,
        index,
        concreteRequest(containing),
        options,
        depth - 1,
        null,
    );
    const edges = try resolveEdges(node.style, containing.width);
    const border = forced_border orelse try usedSize(
        node.style,
        .{ .width = containing.width, .height = containing.height },
        natural.content,
        edges,
        null,
    );
    try checkSize(border);
    node.rect.w = border.width;
    node.rect.h = border.height;
    node.resolveTypedStyleAxes(containing.width, containing.height, natural.content);
    node.resolved_box_edges = .{ .border = edges.border, .padding = edges.padding };
    const content: widget.Size = .{
        .width = @max(0, border.width - edges.horizontal),
        .height = @max(0, border.height - edges.vertical),
    };
    try checkSize(content);

    var columns: std.ArrayList(Track) = .empty;
    defer columns.deinit(options.allocator);
    var rows: std.ArrayList(Track) = .empty;
    defer rows.deinit(options.allocator);
    try initTracks(
        options.allocator,
        &columns,
        node.style.grid_template_columns,
        node.style.grid_auto_columns,
        content.width,
    );
    try initTracks(
        options.allocator,
        &rows,
        node.style.grid_template_rows,
        node.style.grid_auto_rows,
        content.height,
    );

    var items: std.ArrayList(FlowItem) = .empty;
    defer items.deinit(options.allocator);
    try collectItems(tree, node, concreteRequest(content), options, depth - 1, &items);
    var occupied: std.AutoHashMapUnmanaged(Cell, void) = .empty;
    defer occupied.deinit(options.allocator);
    try placeItems(
        options.allocator,
        &columns,
        &rows,
        &items,
        node.style.grid_auto_flow,
        node.style.grid_auto_columns,
        node.style.grid_auto_rows,
        content.width,
        content.height,
        &occupied,
    );
    const width_auto = node.style.size.width == .auto or node.style.size.width == .min_content or
        node.style.size.width == .max_content or node.style.size.width == .fit_content;
    const height_auto = node.style.size.height == .auto or node.style.size.height == .min_content or
        node.style.size.height == .max_content or node.style.size.height == .fit_content;
    const width_definite = forced_border != null or !width_auto;
    const height_definite = forced_border != null or !height_auto;
    try sizeTracks(options.allocator, &columns, &rows, items.items, content, node, width_definite, height_definite);

    var column_offsets: std.ArrayList(f32) = .empty;
    defer column_offsets.deinit(options.allocator);
    var row_offsets: std.ArrayList(f32) = .empty;
    defer row_offsets.deinit(options.allocator);
    const column_gap = try gridGap(node.style, .columns);
    const row_gap = try gridGap(node.style, .rows);
    const column_total = try trackTotal(columns.items, column_gap);
    const row_total = try trackTotal(rows.items, row_gap);
    var final_content_height = content.height;
    if (height_auto and forced_border == null) {
        final_content_height = row_total;
        node.rect.h = try add(row_total, edges.vertical);
    }
    const justify_content = effectiveJustifyContent(node.style);
    const align_content = effectiveAlignContent(node.style);
    const justify_distribution = try justifyContent(
        justify_content,
        @max(0, content.width - column_total),
        columns.items.len,
    );
    const align_distribution = try alignContent(
        align_content,
        @max(0, final_content_height - row_total),
        rows.items.len,
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
            if (trackCanStretch(track.spec)) stretch_count += 1;
        }
        if (stretch_count != 0) {
            const addition = align_distribution.stretch * @as(f32, @floatFromInt(rows.items.len)) /
                @as(f32, @floatFromInt(stretch_count));
            for (rows.items) |*track| {
                if (trackCanStretch(track.spec)) {
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

    for (items.items) |item| {
        const child = &tree.nodes.items[item.index];
        const col_span = item.column.end - item.column.start;
        const row_span = item.row.end - item.row.start;
        if (item.column.start >= columns.items.len or item.row.start >= rows.items.len) return error.InvalidStyle;
        var area_width: f32 = 0;
        var area_height: f32 = 0;
        for (columns.items[item.column.start..@min(columns.items.len, item.column.end)]) |track| {
            area_width = try add(area_width, track.size);
        }
        for (rows.items[item.row.start..@min(rows.items.len, item.row.end)]) |track| {
            area_height = try add(area_height, track.size);
        }
        if (col_span > 1) {
            const span_f: f32 = @floatFromInt(col_span - 1);
            area_width = try add(area_width, (column_gap + justify_distribution.extra_gap) * span_f);
        }
        if (row_span > 1) {
            const span_f: f32 = @floatFromInt(row_span - 1);
            area_height = try add(area_height, (row_gap + align_distribution.extra_gap) * span_f);
        }
        var resolved_natural = item.natural;
        if (child.children.items.len != 0) {
            if (options.context) |context| {
                if (child.style.display != .grid) {
                    const measured = try context.measure_node(
                        context,
                        tree,
                        child,
                        .{
                            .available = .{ .width = area_width, .height = area_height },
                            .percentage_basis = .{
                                .width = area_width,
                                .height = area_height,
                            },
                            .intrinsic_width = false,
                            .intrinsic_height = false,
                        },
                    );
                    resolved_natural = .{
                        .content = measured.content,
                        .border = measured.border,
                    };
                }
            }
        }

        const child_edges = try resolveEdges(child.style, content.width);
        child.resolved_box_edges = .{
            .border = child_edges.border,
            .padding = child_edges.padding,
        };
        var margins = item.margins;
        var child_size = try usedSize(
            child.style,
            .{ .width = area_width, .height = area_height },
            resolved_natural.content,
            child_edges,
            null,
        );
        const justify_items = effectiveJustifyItems(node.style);
        const align_items = effectiveAlignItems(node.style);
        const justify_self = alignValue(child.style.grid_justify_self, justify_items);
        const align_self = alignValue(child.style.grid_align_self, align_items);
        const stretch_width = dimensionAuto(child.style.size.width) and justify_self == .stretch and
            !margins.left_auto and !margins.right_auto;
        if (stretch_width) {
            child_size.width = try clampAxisSize(
                child.style,
                .horizontal,
                @max(
                    0,
                    area_width - margins.value.left - margins.value.right,
                ),
                .{ .width = content.width, .height = content.height },
                resolved_natural.content,
                child_edges,
            );
        }
        const stretch_height = dimensionAuto(child.style.size.height) and align_self == .stretch and
            !margins.top_auto and !margins.bottom_auto;
        if (stretch_height) {
            child_size.height = try clampAxisSize(
                child.style,
                .vertical,
                @max(
                    0,
                    area_height - margins.value.top - margins.value.bottom,
                ),
                .{ .width = content.width, .height = content.height },
                resolved_natural.content,
                child_edges,
            );
        }
        var free_width = @max(
            0,
            area_width - child_size.width - margins.value.left - margins.value.right,
        );
        var free_height = @max(
            0,
            area_height - child_size.height - margins.value.top - margins.value.bottom,
        );
        const horizontal_auto_count: u8 = @as(u8, @intFromBool(margins.left_auto)) +
            @as(u8, @intFromBool(margins.right_auto));
        if (horizontal_auto_count != 0) {
            const share = free_width / @as(f32, @floatFromInt(horizontal_auto_count));
            if (margins.left_auto) margins.value.left = share;
            if (margins.right_auto) margins.value.right = share;
            free_width = 0;
        }
        const vertical_auto_count: u8 = @as(u8, @intFromBool(margins.top_auto)) +
            @as(u8, @intFromBool(margins.bottom_auto));
        if (vertical_auto_count != 0) {
            const share = free_height / @as(f32, @floatFromInt(vertical_auto_count));
            if (margins.top_auto) margins.value.top = share;
            if (margins.bottom_auto) margins.value.bottom = share;
            free_height = 0;
        }
        const logical_track_x = column_offsets.items[item.column.start];
        const track_x = if (node.style.writing_direction == .rtl)
            try finite(content.width - logical_track_x - area_width)
        else
            logical_track_x;
        const x = try add(
            track_x,
            try add(
                margins.value.left,
                alignOffset(justify_self, free_width),
            ),
        );
        var y_offset: f32 = 0;
        if (align_self == .baseline) {
            var max_ascent: f32 = 0;
            for (items.items) |other| {
                if (other.row.start == item.row.start) {
                    const other_child = &tree.nodes.items[other.index];
                    const other_align = alignValue(other_child.style.grid_align_self, align_items);
                    if (other_align == .baseline) {
                        const other_edges = try resolveEdges(other_child.style, content.width);
                        const other_baseline = nodeFirstBaseline(tree, other.index, other.natural.border, other_edges);
                        const other_ascent = other.margins.value.top + other_baseline;
                        max_ascent = @max(max_ascent, other_ascent);
                    }
                }
            }
            const my_baseline = nodeFirstBaseline(tree, item.index, child_size, child_edges);
            const my_ascent = margins.value.top + my_baseline;
            y_offset = @max(0, max_ascent - my_ascent);
        } else {
            y_offset = alignOffset(align_self, free_height);
        }
        const logical_y = try add(
            row_offsets.items[item.row.start],
            try add(
                margins.value.top,
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
        child.natural_main = child_size.width;
        if (child.children.items.len != 0) {
            if (options.context) |context| {
                if (child.style.display != .grid) {
                    try context.layout_node(
                        context,
                        tree,
                        child,
                        .{
                            .available = content,
                            .percentage_basis = .{
                                .width = content.width,
                                .height = content.height,
                            },
                            .forced_border = .{
                                .width = child.rect.w,
                                .height = child.rect.h,
                            },
                        },
                    );
                    continue;
                }
            }
            try layoutGridNode(tree, item.index, content, child_size, options, depth - 1);
        }
    }
    try placeAbsolute(
        tree,
        node,
        .{ .width = content.width, .height = final_content_height },
        columns.items,
        rows.items,
        column_offsets.items,
        row_offsets.items,
        column_gap,
        row_gap,
        justify_distribution.extra_gap,
        align_distribution.extra_gap,
        options,
        depth - 1,
    );

    updateScroll(tree, node, .{ .width = content.width, .height = final_content_height }, column_total, row_total);
}

fn collectItems(
    tree: *widget.WidgetTree,
    container: *widget.WidgetNode,
    request: layout_context.Request,
    options: Options,
    depth: usize,
    items: *std.ArrayList(FlowItem),
) Error!void {
    for (container.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        const child = &tree.nodes.items[child_index];
        if (child.layout_hidden or child.style.position == .absolute) continue;
        var child_req = request;
        if (!naturalAxisDefinite(child.style.size.width, request.intrinsic_width, request.percentage_basis.width)) {
            child_req.intrinsic_width = dimensionAuto(child.style.size.width);
        }
        if (!naturalAxisDefinite(child.style.size.height, request.intrinsic_height, request.percentage_basis.height)) {
            child_req.intrinsic_height = dimensionAuto(child.style.size.height);
        }
        const natural = try measureNode(
            tree,
            child_index,
            child_req,
            options,
            depth,
            container.style.display,
        );
        const margins = try resolveMargins(child.style, request.percentage_basis.width);
        const row_line = gridLineFor(child.style, .rows);
        const column_line = gridLineFor(child.style, .columns);
        const row = try placementFor(row_line, @max(@as(usize, 1), container.style.grid_template_rows.len));
        const column = try placementFor(column_line, @max(@as(usize, 1), container.style.grid_template_columns.len));
        child.natural_main = natural.border.width;
        items.append(options.allocator, .{
            .index = child_index,
            .row = row,
            .column = column,
            .natural = natural,
            .margins = margins,
        }) catch return error.InvalidStyle;
    }
}

fn gridLineFor(input: style.Style, axis: TrackAxis) style.GridLine {
    return switch (axis) {
        .columns => if (!std.meta.eql(input.grid_column, style.GridLine{})) input.grid_column else .{
            .start = input.grid_column_start,
            .end = input.grid_column_end,
        },
        .rows => if (!std.meta.eql(input.grid_row, style.GridLine{})) input.grid_row else .{
            .start = input.grid_row_start,
            .end = input.grid_row_end,
        },
    };
}

fn placementFor(line: style.GridLine, explicit_count: usize) Error!AxisPlacement {
    const start_line = try placementLine(line.start, explicit_count);
    const end_line = try placementLine(line.end, explicit_count);
    const start_span = placementSpan(line.start);
    const end_span = placementSpan(line.end);
    if (start_line) |start| {
        var end = if (end_line) |value| value else start + end_span;
        if (end <= start) end = start + 1;
        return .{ .start = start, .end = end, .definite = true };
    }
    if (end_line) |end| {
        const start = if (end >= start_span) end - start_span else return error.InvalidStyle;
        return .{ .start = start, .end = @max(end, start + 1), .definite = true };
    }
    return .{ .start = 0, .end = start_span, .definite = false };
}

fn placementLine(value: style.GridPlacement, explicit_count: usize) Error!?usize {
    return switch (value) {
        .auto, .span => null,
        .line => |line| blk: {
            if (line == 0) break :blk error.InvalidStyle;
            const line_index: i32 = if (line > 0)
                @as(i32, line) - 1
            else
                @as(i32, @intCast(explicit_count + 1)) + @as(i32, line);
            if (line_index < 0) break :blk error.InvalidStyle;
            break :blk @as(usize, @intCast(line_index));
        },
    };
}

fn placementSpan(value: style.GridPlacement) usize {
    return switch (value) {
        .span => |span| @max(@as(usize, 1), @as(usize, span)),
        .auto, .line => 1,
    };
}

fn initTracks(
    allocator: std.mem.Allocator,
    tracks: *std.ArrayList(Track),
    explicit: []const style.GridTrack,
    auto_track: style.GridTrack,
    basis: ?f32,
) Error!void {
    if (explicit.len == 0) {
        tracks.append(
            allocator,
            .{ .spec = auto_track, .size = try trackMinimum(auto_track, basis) },
        ) catch return error.InvalidStyle;
        return;
    }
    for (explicit) |spec| {
        tracks.append(
            allocator,
            .{ .spec = spec, .size = try trackMinimum(spec, basis) },
        ) catch return error.InvalidStyle;
    }
}

fn ensureTracks(
    allocator: std.mem.Allocator,
    tracks: *std.ArrayList(Track),
    count: usize,
    auto_track: style.GridTrack,
    basis: ?f32,
) Error!void {
    while (tracks.items.len < count) {
        tracks.append(
            allocator,
            .{ .spec = auto_track, .size = try trackMinimum(auto_track, basis) },
        ) catch return error.InvalidStyle;
    }
}

fn placeItems(
    allocator: std.mem.Allocator,
    columns: *std.ArrayList(Track),
    rows: *std.ArrayList(Track),
    items: *std.ArrayList(FlowItem),
    flow: style.GridAutoFlow,
    auto_column: style.GridTrack,
    auto_row: style.GridTrack,
    column_basis: ?f32,
    row_basis: ?f32,
    occupied: *std.AutoHashMapUnmanaged(Cell, void),
) Error!void {
    var cursor_row: usize = 0;
    var cursor_column: usize = 0;
    const row_flow = flow == .row or flow == .row_dense;
    const dense = flow == .row_dense or flow == .column_dense;
    for (items.items) |*item| {
        if (!item.row.definite or !item.column.definite) continue;
        try ensureTracks(allocator, rows, item.row.end, auto_row, row_basis);
        try ensureTracks(allocator, columns, item.column.end, auto_column, column_basis);
        try markArea(
            allocator,
            occupied,
            item.row.start,
            item.column.start,
            item.row.end - item.row.start,
            item.column.end - item.column.start,
        );
    }
    for (items.items) |*item| {
        if (item.row.definite and item.column.definite) continue;

        var candidate_row: usize = if (item.row.definite) item.row.start else if (dense) 0 else cursor_row;
        var candidate_column: usize = if (item.column.definite) item.column.start else if (dense) 0 else cursor_column;
        while (true) {
            const row_span = item.row.end - item.row.start;
            const column_span = item.column.end - item.column.start;
            if (row_span == 0 or column_span == 0) return error.InvalidStyle;

            if (row_flow and !item.column.definite and candidate_column + column_span > columns.items.len) {
                if (item.row.definite or column_span > columns.items.len) {
                    try ensureTracks(allocator, columns, candidate_column + column_span, auto_column, column_basis);
                } else {
                    candidate_row += 1;
                    candidate_column = 0;
                    continue;
                }
            }
            if (!row_flow and !item.row.definite and candidate_row + row_span > rows.items.len) {
                if (item.column.definite or row_span > rows.items.len) {
                    try ensureTracks(allocator, rows, candidate_row + row_span, auto_row, row_basis);
                } else {
                    candidate_column += 1;
                    candidate_row = 0;
                    continue;
                }
            }
            if (candidate_row + row_span > rows.items.len) {
                try ensureTracks(allocator, rows, candidate_row + row_span, auto_row, row_basis);
            }
            if (candidate_column + column_span > columns.items.len) {
                try ensureTracks(allocator, columns, candidate_column + column_span, auto_column, column_basis);
            }

            if (areaFree(occupied, candidate_row, candidate_column, row_span, column_span)) {
                item.row.start = candidate_row;
                item.row.end = candidate_row + row_span;
                item.column.start = candidate_column;
                item.column.end = candidate_column + column_span;
                try markArea(allocator, occupied, candidate_row, candidate_column, row_span, column_span);
                if (!dense) {
                    if (row_flow) {
                        cursor_row = candidate_row;
                        cursor_column = candidate_column + column_span;
                        if (!item.column.definite and cursor_column >= columns.items.len) {
                            cursor_row += 1;
                            cursor_column = 0;
                        }
                    } else {
                        cursor_column = candidate_column;
                        cursor_row = candidate_row + row_span;
                        if (!item.row.definite and cursor_row >= rows.items.len) {
                            cursor_column += 1;
                            cursor_row = 0;
                        }
                    }
                }
                break;
            }

            if (row_flow) {
                if (item.column.definite) {
                    candidate_row += 1;
                } else if (item.row.definite) {
                    candidate_column += 1;
                } else {
                    candidate_column += 1;
                    if (candidate_column >= columns.items.len) {
                        candidate_column = 0;
                        candidate_row += 1;
                    }
                }
            } else {
                if (item.row.definite) {
                    candidate_column += 1;
                } else if (item.column.definite) {
                    candidate_row += 1;
                } else {
                    candidate_row += 1;
                    if (candidate_row >= rows.items.len) {
                        candidate_row = 0;
                        candidate_column += 1;
                    }
                }
            }
        }
    }
}

fn areaFree(
    occupied: *const std.AutoHashMapUnmanaged(Cell, void),
    row: usize,
    column: usize,
    row_span: usize,
    column_span: usize,
) bool {
    for (row..row + row_span) |row_index| {
        for (column..column + column_span) |column_index| {
            if (occupied.contains(.{ .row = row_index, .column = column_index })) return false;
        }
    }
    return true;
}

fn markArea(
    allocator: std.mem.Allocator,
    occupied: *std.AutoHashMapUnmanaged(Cell, void),
    row: usize,
    column: usize,
    row_span: usize,
    column_span: usize,
) Error!void {
    for (row..row + row_span) |row_index| {
        for (column..column + column_span) |column_index| {
            occupied.put(allocator, .{ .row = row_index, .column = column_index }, {}) catch return error.InvalidStyle;
        }
    }
}

fn sizeTracks(
    allocator: std.mem.Allocator,
    columns: *std.ArrayList(Track),
    rows: *std.ArrayList(Track),
    items: []const FlowItem,
    content: widget.Size,
    container: *const widget.WidgetNode,
    width_definite: bool,
    height_definite: bool,
) Error!void {
    _ = allocator;
    const column_gap = try gridGap(container.style, .columns);
    const row_gap = try gridGap(container.style, .rows);
    for (items) |item| {
        const width_need = try add(item.natural.border.width, item.margins.value.left + item.margins.value.right);
        const height_need = try add(item.natural.border.height, item.margins.value.top + item.margins.value.bottom);
        try growTracks(
            columns.items,
            item.column.start,
            item.column.end,
            width_need,
            column_gap,
            if (width_definite) content.width else null,
        );
        try growTracks(
            rows.items,
            item.row.start,
            item.row.end,
            height_need,
            row_gap,
            if (height_definite) content.height else null,
        );
    }
    if (width_definite) {
        try resolveFlexibleTracks(columns.items, content.width, column_gap);
    } else {
        try resolveIndefiniteFlexibleTracks(columns.items);
    }

    if (height_definite) {
        try resolveFlexibleTracks(rows.items, content.height, row_gap);
    } else {
        try resolveIndefiniteFlexibleTracks(rows.items);
    }
}

fn growTracks(tracks: []Track, start: usize, end: usize, need: f32, gap: f32, basis: ?f32) Error!void {
    if (start >= end or end > tracks.len) return error.InvalidStyle;
    const span = end - start;
    var current: f32 = 0;
    for (tracks[start..end]) |track| current = try add(current, track.size);
    if (span > 1) current = try add(current, gap * @as(f32, @floatFromInt(span - 1)));
    var deficit = need - current;
    if (deficit <= 0) return;

    var non_fr_unbounded: usize = 0;
    var non_fr_bounded_capacity: f32 = 0;

    for (tracks[start..end]) |track| {
        if (trackFraction(track.spec) != 0) continue;
        if (!trackAllowsIntrinsic(track.spec)) continue;
        if (try trackMaximum(track.spec, basis)) |maximum| {
            const capacity = @max(0, maximum - track.size);
            if (capacity > 0) {
                non_fr_bounded_capacity = try add(non_fr_bounded_capacity, capacity);
            }
        } else {
            non_fr_unbounded += 1;
        }
    }

    if (non_fr_unbounded > 0) {
        if (non_fr_bounded_capacity > 0) {
            const to_bounded = @min(deficit, non_fr_bounded_capacity);
            for (tracks[start..end]) |*track| {
                if (trackFraction(track.spec) != 0) continue;
                if (!trackAllowsIntrinsic(track.spec)) continue;
                if (try trackMaximum(track.spec, basis)) |maximum| {
                    const capacity = @max(0, maximum - track.size);
                    if (capacity > 0) {
                        const share = to_bounded * capacity / non_fr_bounded_capacity;
                        track.size = try add(track.size, share);
                    }
                }
            }
            deficit -= to_bounded;
        }
        if (deficit > 0) {
            const share = deficit / @as(f32, @floatFromInt(non_fr_unbounded));
            for (tracks[start..end]) |*track| {
                if (trackFraction(track.spec) != 0) continue;
                if (!trackAllowsIntrinsic(track.spec)) continue;
                if ((try trackMaximum(track.spec, basis)) == null) {
                    track.size = try add(track.size, share);
                }
            }
            deficit = 0;
        }
    } else if (non_fr_bounded_capacity > 0) {
        const to_bounded = @min(deficit, non_fr_bounded_capacity);
        for (tracks[start..end]) |*track| {
            if (trackFraction(track.spec) != 0) continue;
            if (!trackAllowsIntrinsic(track.spec)) continue;
            if (try trackMaximum(track.spec, basis)) |maximum| {
                const capacity = @max(0, maximum - track.size);
                if (capacity > 0) {
                    const share = to_bounded * capacity / non_fr_bounded_capacity;
                    track.size = try add(track.size, share);
                }
            }
        }
        deficit -= to_bounded;
    }

    if (deficit > 0) {
        var fr_total: f32 = 0;
        var fr_count: usize = 0;
        for (tracks[start..end]) |track| {
            const fr = trackFraction(track.spec);
            if (fr > 0) {
                fr_total = try add(fr_total, fr);
                fr_count += 1;
            }
        }
        if (fr_total > 0) {
            for (tracks[start..end]) |*track| {
                const fr = trackFraction(track.spec);
                if (fr > 0) {
                    track.size = try add(track.size, deficit * fr / fr_total);
                }
            }
            deficit = 0;
        } else if (fr_count > 0) {
            const share = deficit / @as(f32, @floatFromInt(fr_count));
            for (tracks[start..end]) |*track| {
                if (trackFraction(track.spec) > 0) {
                    track.size = try add(track.size, share);
                }
            }
            deficit = 0;
        }
    }

    for (tracks[start..end]) |*track| {
        if (trackFraction(track.spec) == 0) {
            if (try trackMaximum(track.spec, basis)) |maximum| {
                track.size = @min(track.size, maximum);
            }
            if (track.spec == .minmax) {
                track.size = @max(track.size, try breadthMinimum(track.spec.minmax.min, basis));
            }
        }
        track.size = try nonNegative(track.size);
    }
}

fn resolveFlexibleTracks(tracks: []Track, content_size: f32, gap: f32) Error!void {
    const total_gaps = if (tracks.len > 1) gap * @as(f32, @floatFromInt(tracks.len - 1)) else 0;

    var bounded_capacity: f32 = 0;
    var non_fr_used: f32 = total_gaps;
    for (tracks) |track| {
        if (trackFraction(track.spec) == 0) {
            non_fr_used = try add(non_fr_used, track.size);
            if (try trackMaximum(track.spec, content_size)) |maximum| {
                bounded_capacity = try add(bounded_capacity, @max(0, maximum - track.size));
            }
        }
    }

    const initial_free = @max(0, try finite(content_size - non_fr_used));
    if (bounded_capacity > 0 and initial_free > 0) {
        for (tracks) |*track| {
            if (trackFraction(track.spec) != 0) continue;
            if (try trackMaximum(track.spec, content_size)) |maximum| {
                const capacity = @max(0, maximum - track.size);
                if (capacity > 0) {
                    track.size = try add(track.size, @min(capacity, initial_free * capacity / bounded_capacity));
                }
            }
        }
    }

    non_fr_used = total_gaps;
    for (tracks) |*track| {
        if (trackFraction(track.spec) == 0) {
            if (try trackMaximum(track.spec, content_size)) |maximum| {
                track.size = @min(track.size, maximum);
            }
            track.size = try nonNegative(track.size);
            non_fr_used = try add(non_fr_used, track.size);
        }
    }

    var free_space = @max(0, try finite(content_size - non_fr_used));
    var frozen = [_]bool{false} ** 1024;
    if (tracks.len > 1024) return error.InvalidStyle;
    var bases: [1024]f32 = undefined;
    for (tracks, 0..) |track, i| {
        bases[i] = track.size;
    }

    while (true) {
        var unfrozen_fr_sum: f32 = 0;
        var unfrozen_fr_count: usize = 0;
        for (tracks, 0..) |track, i| {
            const fr = trackFraction(track.spec);
            if (fr > 0 and !frozen[i]) {
                unfrozen_fr_sum = try add(unfrozen_fr_sum, fr);
                unfrozen_fr_count += 1;
            }
        }

        if (unfrozen_fr_count == 0 or free_space <= 0 or unfrozen_fr_sum <= 0) {
            for (tracks, 0..) |*track, i| {
                const fr = trackFraction(track.spec);
                if (fr > 0 and !frozen[i]) {
                    track.size = @max(try trackMinimum(track.spec, content_size), bases[i]);
                    if (try trackMaximum(track.spec, content_size)) |maximum| {
                        track.size = @min(track.size, maximum);
                    }
                    track.size = try nonNegative(track.size);
                }
            }
            break;
        }

        var newly_frozen = false;
        for (tracks, 0..) |*track, i| {
            const fr = trackFraction(track.spec);
            if (fr > 0 and !frozen[i]) {
                const hypothetical_size = free_space * fr / unfrozen_fr_sum;
                if (hypothetical_size < bases[i]) {
                    frozen[i] = true;
                    newly_frozen = true;
                    track.size = bases[i];
                    free_space = @max(0, free_space - bases[i]);
                } else if (try trackMaximum(track.spec, content_size)) |maximum| {
                    if (hypothetical_size > maximum) {
                        frozen[i] = true;
                        newly_frozen = true;
                        track.size = maximum;
                        free_space = @max(0, free_space - maximum);
                    }
                }
            }
        }

        if (newly_frozen) {
            continue;
        }

        for (tracks, 0..) |*track, i| {
            const fr = trackFraction(track.spec);
            if (fr > 0 and !frozen[i]) {
                track.size = @max(free_space * fr / unfrozen_fr_sum, bases[i]);
                const minimum = try trackMinimum(track.spec, content_size);
                track.size = @max(track.size, minimum);
                if (try trackMaximum(track.spec, content_size)) |maximum| {
                    track.size = @min(track.size, maximum);
                }
                track.size = try nonNegative(track.size);
            }
        }
        break;
    }
}

fn nodeFirstBaseline(
    tree: *const widget.WidgetTree,
    child_index: usize,
    child_size: widget.Size,
    child_edges: Edges,
) f32 {
    const node = &tree.nodes.items[child_index];
    switch (node.kind) {
        .label => {
            const font_size = if (node.font_size > 0) node.font_size else 16.0;
            const ascent = font_size * 0.8;
            return child_edges.border.top + child_edges.padding.top + ascent;
        },
        .button => |button| {
            if (button.visual_label != null) {
                const font_size = if (node.font_size > 0) node.font_size else 16.0;
                const ascent = font_size * 0.8;
                return child_edges.border.top + child_edges.padding.top + ascent;
            }
            return child_size.height;
        },
        else => {
            if (node.children.items.len > 0) {
                for (node.children.items) |grandchild_id| {
                    if (tree.nodeIndex(grandchild_id)) |grandchild_index| {
                        const grandchild = &tree.nodes.items[grandchild_index];
                        if (grandchild.layout_hidden or grandchild.style.position == .absolute) continue;
                        const grandchild_edges = resolveEdges(grandchild.style, child_size.width) catch Edges{
                            .border = .{},
                            .padding = .{},
                            .horizontal = 0,
                            .vertical = 0,
                        };
                        const grandchild_baseline = nodeFirstBaseline(
                            tree,
                            grandchild_index,
                            .{ .width = grandchild.rect.w, .height = grandchild.rect.h },
                            grandchild_edges,
                        );
                        return grandchild.rect.y + grandchild_baseline;
                    }
                }
            }
            return child_size.height;
        },
    }
}

fn resolveIndefiniteFlexibleTracks(tracks: []Track) Error!void {
    var max_fr_unit: f32 = 0;
    for (tracks) |track| {
        const fr = trackFraction(track.spec);
        if (fr > 0) {
            const unit = track.size / fr;
            max_fr_unit = @max(max_fr_unit, unit);
        }
    }
    for (tracks) |*track| {
        const fr = trackFraction(track.spec);
        if (fr > 0) {
            const normalized = try finite(@max(track.size, fr * max_fr_unit));
            track.size = try nonNegative(normalized);
        }
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
        .fit_content => |value| try finiteNonNegative(value),
        .percent => |fraction| blk: {
            const percentage_basis = basis orelse return null;
            break :blk fraction * percentage_basis;
        },
        .auto, .min_content, .max_content, .fr => null,
        .minmax => |value| breadthMaximum(value.max, basis),
    };
}

fn breadthMaximum(breadth: style.GridTrackBreadth, basis: ?f32) Error!?f32 {
    return switch (breadth) {
        .fixed => |value| value,
        .fit_content => |value| try finiteNonNegative(value),
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
    };
}

fn trackCanStretch(track: style.GridTrack) bool {
    return switch (track) {
        .auto, .min_content, .max_content, .fit_content => true,
        .minmax => |value| switch (value.min) {
            .auto, .min_content, .max_content, .fixed, .percent, .fit_content => true,
            .fr => false,
        },
        .percent, .fixed, .fr => false,
    };
}

fn trackFraction(track: style.GridTrack) f32 {
    return switch (track) {
        .fr => |value| value,
        .minmax => |value| switch (value.max) {
            .fr => |weight| weight,
            else => 0,
        },
        .fixed, .percent, .auto, .min_content, .max_content, .fit_content => 0,
    };
}

fn trackMinimumSum(tracks: []const style.GridTrack, basis: ?f32) Error!f32 {
    var result: f32 = 0;
    for (tracks) |track| result = try add(result, try trackMinimum(track, basis));
    return result;
}

fn gridGap(input: style.Style, axis: TrackAxis) Error!f32 {
    const value = switch (axis) {
        .columns => if (input.grid_column_gap != 0)
            input.grid_column_gap
        else if (input.column_gap != 0)
            input.column_gap
        else
            input.gap,
        .rows => if (input.grid_row_gap != 0)
            input.grid_row_gap
        else if (input.row_gap != 0)
            input.row_gap
        else
            input.gap,
    };
    return finiteNonNegative(value);
}

fn trackTotal(tracks: []const Track, gap: f32) Error!f32 {
    var result: f32 = if (tracks.len > 1) gap * @as(f32, @floatFromInt(tracks.len - 1)) else 0;
    for (tracks) |track| result = try add(result, track.size);
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
    for (tracks, 0..) |track, index| {
        offsets.append(allocator, cursor) catch return error.InvalidStyle;
        cursor = try add(cursor, track.size);
        if (index + 1 < tracks.len) cursor = try add(cursor, gap + extra_gap);
    }
}

fn justifyContent(mode: style.Justify, free: f32, count: usize) Error!Distribution {
    const available = @max(0, try finite(free));
    if (count == 0) return .{ .offset = 0, .extra_gap = 0 };
    const count_f: f32 = @floatFromInt(count);
    return switch (mode) {
        .start => .{ .offset = 0, .extra_gap = 0 },
        .center => .{ .offset = available / 2, .extra_gap = 0 },
        .end => .{ .offset = available, .extra_gap = 0 },
        .space_between => .{
            .offset = 0,
            .extra_gap = if (count > 1)
                available / @as(f32, @floatFromInt(count - 1))
            else
                0,
        },
        .space_around => .{ .offset = available / count_f / 2, .extra_gap = available / count_f },
        .space_evenly => .{ .offset = available / (count_f + 1), .extra_gap = available / (count_f + 1) },
    };
}

fn alignContent(mode: style.AlignContent, free: f32, count: usize) Error!ContentDistribution {
    const available = @max(0, try finite(free));
    if (count == 0) return .{ .offset = 0, .extra_gap = 0, .stretch = 0 };
    const count_f: f32 = @floatFromInt(count);
    return switch (mode) {
        .stretch => .{ .offset = 0, .extra_gap = 0, .stretch = available / count_f },
        .start => .{ .offset = 0, .extra_gap = 0, .stretch = 0 },
        .center => .{ .offset = available / 2, .extra_gap = 0, .stretch = 0 },
        .end => .{ .offset = available, .extra_gap = 0, .stretch = 0 },
        .space_between => .{
            .offset = 0,
            .extra_gap = if (count > 1)
                available / @as(f32, @floatFromInt(count - 1))
            else
                0,
            .stretch = 0,
        },
        .space_around => .{ .offset = available / count_f / 2, .extra_gap = available / count_f, .stretch = 0 },
        .space_evenly => .{ .offset = available / (count_f + 1), .extra_gap = available / (count_f + 1), .stretch = 0 },
    };
}

fn effectiveJustifyContent(input: style.Style) style.Justify {
    return if (input.grid_justify_content == .start and input.justify != .start)
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
    return if (input.grid_justify_items == .stretch and input.@"align" != .stretch)
        input.@"align"
    else
        input.grid_justify_items;
}

fn effectiveAlignItems(input: style.Style) style.Align {
    return if (input.grid_align_items == .stretch and input.@"align" != .stretch)
        input.@"align"
    else
        input.grid_align_items;
}

fn alignValue(value: style.AlignSelf, fallback: style.Align) style.Align {
    return switch (value) {
        .auto => fallback,
        .stretch => .stretch,
        .start => .start,
        .center => .center,
        .end => .end,
        .baseline => .baseline,
    };
}

fn alignOffset(value: style.Align, free: f32) f32 {
    return switch (value) {
        .stretch, .start, .baseline => 0,
        .center => free / 2,
        .end => free,
    };
}

fn placeAbsolute(
    tree: *widget.WidgetTree,
    container: *widget.WidgetNode,
    content: widget.Size,
    columns: []const Track,
    rows: []const Track,
    column_offsets: []const f32,
    row_offsets: []const f32,
    column_gap: f32,
    row_gap: f32,
    column_extra_gap: f32,
    row_extra_gap: f32,
    options: Options,
    depth: usize,
) Error!void {
    for (container.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        const child = &tree.nodes.items[child_index];
        if (child.layout_hidden or child.style.position != .absolute) continue;

        const col_line = gridLineFor(child.style, .columns);
        const col_placement = try placementFor(col_line, columns.len);
        var area_x: f32 = 0;
        var area_width: f32 = content.width;
        if (col_placement.definite and columns.len > 0 and column_offsets.len > 0) {
            const col_start = @min(col_placement.start, columns.len);
            const col_end = @min(col_placement.end, columns.len);
            if (col_start < column_offsets.len) {
                area_x = column_offsets[col_start];
                if (col_end > col_start) {
                    var width: f32 = 0;
                    for (columns[col_start..col_end]) |track| {
                        width = try add(width, track.size);
                    }
                    if (col_end - col_start > 1) {
                        const span_f: f32 = @floatFromInt(col_end - col_start - 1);
                        width = try add(width, (column_gap + column_extra_gap) * span_f);
                    }
                    area_width = width;
                } else {
                    area_width = 0;
                }
            }
        }

        const row_line = gridLineFor(child.style, .rows);
        const row_placement = try placementFor(row_line, rows.len);
        var area_y: f32 = 0;
        var area_height: f32 = content.height;
        if (row_placement.definite and rows.len > 0 and row_offsets.len > 0) {
            const row_start = @min(row_placement.start, rows.len);
            const row_end = @min(row_placement.end, rows.len);
            if (row_start < row_offsets.len) {
                area_y = row_offsets[row_start];
                if (row_end > row_start) {
                    var height: f32 = 0;
                    for (rows[row_start..row_end]) |track| {
                        height = try add(height, track.size);
                    }
                    if (row_end - row_start > 1) {
                        const span_f: f32 = @floatFromInt(row_end - row_start - 1);
                        height = try add(height, (row_gap + row_extra_gap) * span_f);
                    }
                    area_height = height;
                } else {
                    area_height = 0;
                }
            }
        }

        const natural = try measureNode(
            tree,
            child_index,
            concreteRequest(.{ .width = area_width, .height = area_height }),
            options,
            depth,
            container.style.display,
        );
        const edges = try resolveEdges(child.style, area_width);
        child.resolved_box_edges = .{ .border = edges.border, .padding = edges.padding };
        const margins = try resolveMargins(child.style, area_width);
        var child_size = try usedSize(
            child.style,
            .{ .width = area_width, .height = area_height },
            natural.content,
            edges,
            null,
        );
        const left = try resolveInset(child.style.inset.left, area_width);
        const right = try resolveInset(child.style.inset.right, area_width);
        const top = try resolveInset(child.style.inset.top, area_height);
        const bottom = try resolveInset(child.style.inset.bottom, area_height);
        if (dimensionAuto(child.style.size.width) and left != null and right != null) {
            child_size.width = try clampAxisSize(
                child.style,
                .horizontal,
                @max(
                    0,
                    area_width - left.? - right.? - margins.value.left - margins.value.right,
                ),
                .{ .width = area_width, .height = area_height },
                natural.content,
                edges,
            );
        }
        if (dimensionAuto(child.style.size.height) and top != null and bottom != null) {
            child_size.height = try clampAxisSize(
                child.style,
                .vertical,
                @max(
                    0,
                    area_height - top.? - bottom.? - margins.value.top - margins.value.bottom,
                ),
                .{ .width = area_width, .height = area_height },
                natural.content,
                edges,
            );
        }
        const x = if (left) |value|
            try add(area_x, try add(value, margins.value.left))
        else if (right) |value|
            try finite(area_x + area_width - value - margins.value.right - child_size.width)
        else
            try add(area_x, margins.value.left);
        const y = if (top) |value|
            try add(area_y, try add(value, margins.value.top))
        else if (bottom) |value|
            try finite(area_y + area_height - value - margins.value.bottom - child_size.height)
        else
            try add(area_y, margins.value.top);
        child.rect = .{ .x = x, .y = y, .w = child_size.width, .h = child_size.height };
        try checkRect(child.rect);
        child.natural_main = child_size.width;
        if (child.children.items.len != 0) {
            if (options.context) |context| {
                if (child.style.display != .grid) {
                    try context.layout_node(
                        context,
                        tree,
                        child,
                        .{
                            .available = content,
                            .percentage_basis = .{
                                .width = content.width,
                                .height = content.height,
                            },
                            .forced_border = .{
                                .width = child.rect.w,
                                .height = child.rect.h,
                            },
                        },
                    );
                    continue;
                }
            }
            try layoutGridNode(tree, child_index, content, child_size, options, depth);
        }
    }
}

fn usedSize(
    input: style.Style,
    percentage_basis: style.Size(?f32),
    intrinsic: widget.Size,
    edges: Edges,
    fallback: ?widget.Size,
) Error!widget.Size {
    var width = try resolveDimensionBorder(
        input.size.width,
        percentage_basis.width,
        intrinsic.width,
        edges.horizontal,
        input.box_sizing,
    );
    var height = try resolveDimensionBorder(
        input.size.height,
        percentage_basis.height,
        intrinsic.height,
        edges.vertical,
        input.box_sizing,
    );
    if (width == null) {
        width = if (fallback) |value|
            try borderToSizing(value.width, edges.horizontal, input.box_sizing)
        else
            intrinsic.width;
    }
    if (height == null and input.aspect_ratio != null and width != null) {
        height = try finite(width.? / try ratio(input.aspect_ratio.?));
    }
    if (height == null) {
        height = if (fallback) |value|
            try borderToSizing(value.height, edges.vertical, input.box_sizing)
        else
            intrinsic.height;
    }
    if (width == null and input.aspect_ratio != null and height != null) {
        width = try finite(height.? * try ratio(input.aspect_ratio.?));
    }
    var result: widget.Size = .{
        .width = try sizingToBorder(width orelse 0, edges.horizontal, input.box_sizing),
        .height = try sizingToBorder(height orelse 0, edges.vertical, input.box_sizing),
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
        .width = @max(edges.horizontal, result.width),
        .height = @max(edges.vertical, result.height),
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
    const dimension = if (axis == .horizontal) input.min_size.width else input.min_size.height;
    const maximum_dimension = if (axis == .horizontal) input.max_size.width else input.max_size.height;
    const basis = if (axis == .horizontal) percentage_basis.width else percentage_basis.height;
    const natural = if (axis == .horizontal) intrinsic.width else intrinsic.height;
    const edge_sum = if (axis == .horizontal) edges.horizontal else edges.vertical;
    const minimum = (try resolveDimensionBorder(
        dimension,
        basis,
        natural,
        edge_sum,
        input.box_sizing,
    )) orelse 0;
    const maximum = try resolveDimensionBorder(
        maximum_dimension,
        basis,
        natural,
        edge_sum,
        input.box_sizing,
    );
    var result = try nonNegative(candidate);
    if (maximum) |upper| result = @min(result, try nonNegative(upper));
    return @max(result, try nonNegative(minimum));
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
        .percent => |fraction| blk: {
            const basis = percentage_basis orelse return error.InvalidStyle;
            break :blk @as(?f32, try finite(fraction * basis));
        },
    };
    if (value) |number| {
        const result = try sizingToBorder(number, edges, box_sizing);
        return result;
    }
    return null;
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
    const border: style.Sides = .{
        .top = try edge(input.border_inset.top, input.border.top, basis),
        .right = try edge(input.border_inset.right, input.border.right, basis),
        .bottom = try edge(input.border_inset.bottom, input.border.bottom, basis),
        .left = try edge(input.border_inset.left, input.border.left, basis),
    };
    const padding: style.Sides = .{
        .top = try edge(input.padding_inset.top, input.padding.top, basis),
        .right = try edge(input.padding_inset.right, input.padding.right, basis),
        .bottom = try edge(input.padding_inset.bottom, input.padding.bottom, basis),
        .left = try edge(input.padding_inset.left, input.padding.left, basis),
    };
    return .{
        .border = border,
        .padding = padding,
        .horizontal = try add(try add(border.left, border.right), try add(padding.left, padding.right)),
        .vertical = try add(try add(border.top, border.bottom), try add(padding.top, padding.bottom)),
    };
}

fn edge(value: style.LengthPercentage, legacy: f32, basis: ?f32) Error!f32 {
    return switch (value) {
        .length => |number| nonNegative(if (number == 0 and legacy != 0) legacy else number),
        .percent => |fraction| blk: {
            const percentage_basis = basis orelse return error.InvalidStyle;
            break :blk nonNegative(try finite(fraction * percentage_basis));
        },
    };
}

fn resolveMargins(input: style.Style, basis: ?f32) Error!Margins {
    return .{
        .value = .{
            .top = try margin(input.margin_inset.top, input.margin.top, basis),
            .right = try margin(input.margin_inset.right, input.margin.right, basis),
            .bottom = try margin(input.margin_inset.bottom, input.margin.bottom, basis),
            .left = try margin(input.margin_inset.left, input.margin.left, basis),
        },
        .top_auto = isAuto(input.margin_inset.top),
        .right_auto = isAuto(input.margin_inset.right),
        .bottom_auto = isAuto(input.margin_inset.bottom),
        .left_auto = isAuto(input.margin_inset.left),
    };
}

fn margin(value: style.LengthPercentageAuto, legacy: f32, basis: ?f32) Error!f32 {
    return switch (value) {
        .auto => 0,
        .length => |number| finite(if (number == 0 and legacy != 0) legacy else number),
        .percent => |fraction| blk: {
            const percentage_basis = basis orelse return error.InvalidStyle;
            break :blk finite(fraction * percentage_basis);
        },
    };
}

fn marginHorizontal(input: style.Style, basis: ?f32) Error!f32 {
    const margins = try resolveMargins(input, basis);
    return add(margins.value.left, margins.value.right);
}

fn marginVertical(input: style.Style, basis: ?f32) Error!f32 {
    const margins = try resolveMargins(input, basis);
    return add(margins.value.top, margins.value.bottom);
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
    if (left) |value| {
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

fn updateScroll(
    tree: *widget.WidgetTree,
    node: *widget.WidgetNode,
    content: widget.Size,
    width: f32,
    height: f32,
) void {
    if (node.scroll) |scroll| {
        var extent_width = width;
        var extent_height = height;
        for (node.children.items) |child_id| {
            const child = tree.node(child_id) orelse continue;
            if (child.layout_hidden) continue;
            extent_width = @max(extent_width, child.rect.x + child.rect.w);
            extent_height = @max(extent_height, child.rect.y + child.rect.h);
        }
        const horizontal = switch (scroll.axis) {
            .horizontal, .both => true,
            .vertical => false,
        };
        const vertical = switch (scroll.axis) {
            .vertical, .both => true,
            .horizontal => false,
        };
        scroll.state.max_offset = .{
            if (horizontal) @max(0, extent_width - content.width) else 0,
            if (vertical) @max(0, extent_height - content.height) else 0,
        };
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
