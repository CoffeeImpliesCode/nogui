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
};

const grid_tracks_max: usize = 10_000;
const grid_cells_max: usize = 10_000;

const Track = struct {
    spec: style.GridTrack,
    size: f32,
    intrinsic_growth_limit: ?f32 = null,
    planned_increase: f32 = 0,
    can_stretch_in_alignment: bool = true,
};

const AxisPlacement = struct {
    /// Resolved zero-based track indices. These are filled after implicit
    /// prepend tracks have been added.
    start: usize = 0,
    end: usize = 1,
    definite: bool = false,
    /// CSS line coordinates before the implicit-grid origin is shifted.
    logical_start: i32 = 0,
    logical_end: i32 = 1,
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
    try validateLengthPercentage(input.gap, false);
    try validateLengthPercentage(input.column_gap, false);
    try validateLengthPercentage(input.row_gap, false);
    try validateLengthPercentage(input.grid_column_gap, false);
    try validateLengthPercentage(input.grid_row_gap, false);
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
    const input = node.style;
    const edges = try resolveEdges(input, request.percentage_basis.width);
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
        input,
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
    const input = node.style;
    const provisional = try usedSize(
        input,
        request.percentage_basis,
        request.available,
        edges,
        request.available,
    );
    const child_available: widget.Size = .{
        .width = @max(0, provisional.width - edges.horizontal),
        .height = @max(0, provisional.height - edges.vertical),
    };
    const width_definite = switch (input.size.width) {
        .length => true,
        .percent => request.percentage_basis.width != null,
        .auto, .min_content, .max_content, .fit_content => false,
    };
    const height_definite = switch (input.size.height) {
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
        input.grid_template_columns,
        input.grid_auto_columns,
        if (width_definite) child_available.width else null,
    );
    try initTracks(
        options.allocator,
        &rows,
        input.grid_template_rows,
        input.grid_auto_rows,
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
    _ = try placeItems(
        options.allocator,
        &columns,
        &rows,
        &items,
        input.grid_auto_flow,
        input.grid_auto_columns,
        input.grid_auto_rows,
        if (width_definite) child_available.width else null,
        if (height_definite) child_available.height else null,
        &occupied,
    );

    const column_gap = try gridGap(
        input,
        .columns,
        if (width_definite) child_available.width else null,
    );
    const row_gap = try gridGap(
        input,
        .rows,
        if (height_definite) child_available.height else null,
    );

    try growTrackItems(
        columns.items,
        items.items,
        .columns,
        column_gap,
        if (width_definite) child_available.width else null,
    );
    try growTrackItems(
        rows.items,
        items.items,
        .rows,
        row_gap,
        if (height_definite) child_available.height else null,
    );

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
    node.first_baseline = null;
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
    const placement_origins = try placeItems(
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
    const intrinsic_auto_height = height_auto and forced_border == null and !height_clamped;
    const column_gap = try gridGap(node.style, .columns, content.width);
    var row_gap = try gridGap(
        node.style,
        .rows,
        if (intrinsic_auto_height) null else content.height,
    );
    try sizeTracks(
        &columns,
        &rows,
        items.items,
        content,
        column_gap,
        row_gap,
        width_definite,
        height_definite,
    );

    var column_offsets: std.ArrayList(f32) = .empty;
    defer column_offsets.deinit(options.allocator);
    var row_offsets: std.ArrayList(f32) = .empty;
    defer row_offsets.deinit(options.allocator);
    var column_total = try trackTotal(columns.items, column_gap);
    var final_content_height = content.height;
    if (intrinsic_auto_height) {
        final_content_height = try trackTotal(rows.items, row_gap);
        node.rect.h = try add(final_content_height, edges.vertical);
        row_gap = try gridGap(node.style, .rows, final_content_height);
    }
    const row_total = try trackTotal(rows.items, row_gap);
    const justify_content = effectiveJustifyContent(node.style);
    const align_content = effectiveAlignContent(node.style);
    if (node.style.grid_justify_content == .normal and justify_content == .normal and width_definite) {
        const inline_free = try finite(content.width - column_total);
        if (inline_free > 0) {
            var stretch_count: usize = 0;
            for (columns.items) |track| {
                if (track.can_stretch_in_alignment and
                    trackCanStretch(track.spec) and
                    trackHasAutoMaximum(track.spec))
                {
                    stretch_count += 1;
                }
            }
            if (stretch_count != 0) {
                const addition = inline_free / @as(f32, @floatFromInt(stretch_count));
                for (columns.items) |*track| {
                    if (track.can_stretch_in_alignment and
                        trackCanStretch(track.spec) and
                        trackHasAutoMaximum(track.spec))
                    {
                        track.size = try add(track.size, addition);
                    }
                }
                column_total = try trackTotal(columns.items, column_gap);
            }
        }
    }
    const justify_distribution = try justifyContent(
        justify_content,
        content.width - column_total,
        columns.items.len,
    );
    const align_distribution = try alignContent(
        align_content,
        final_content_height - row_total,
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
            if (track.can_stretch_in_alignment and trackCanStretch(track.spec)) stretch_count += 1;
        }
        if (stretch_count != 0) {
            const addition = align_distribution.stretch * @as(f32, @floatFromInt(rows.items.len)) /
                @as(f32, @floatFromInt(stretch_count));
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
        var free_width = area_width - child_size.width - margins.value.left - margins.value.right;
        var free_height = area_height - child_size.height - margins.value.top - margins.value.bottom;
        const horizontal_auto_count: u8 = @as(u8, @intFromBool(margins.left_auto)) +
            @as(u8, @intFromBool(margins.right_auto));
        if (horizontal_auto_count != 0) {
            const share = @max(0, free_width) / @as(f32, @floatFromInt(horizontal_auto_count));
            if (margins.left_auto) margins.value.left = share;
            if (margins.right_auto) margins.value.right = share;
            free_width = 0;
        }
        const vertical_auto_count: u8 = @as(u8, @intFromBool(margins.top_auto)) +
            @as(u8, @intFromBool(margins.bottom_auto));
        if (vertical_auto_count != 0) {
            const share = @max(0, free_height) / @as(f32, @floatFromInt(vertical_auto_count));
            if (margins.top_auto) margins.value.top = share;
            if (margins.bottom_auto) margins.value.bottom = share;
            free_height = 0;
        }
        const logical_track_x = column_offsets.items[item.column.start];
        const track_x = if (node.style.writing_direction == .rtl)
            try finite(content.width - logical_track_x - area_width)
        else
            logical_track_x;
        const alignment_offset = alignOffset(justify_self, free_width, directions_match, true);
        const physical_alignment_offset = if (node.style.writing_direction == .rtl)
            free_width - alignment_offset
        else
            alignment_offset;
        const x = try add(
            track_x,
            try add(margins.value.left, physical_alignment_offset),
        );
        var y_offset: f32 = 0;
        if (align_self == .baseline) {
            var max_ascent: f32 = 0;
            for (items.items) |other| {
                if (other.row.start == item.row.start) {
                    const other_child = &tree.nodes.items[other.index];
                    const other_directions_match =
                        other_child.style.writing_direction == node.style.writing_direction;
                    const other_align = alignValue(
                        other_child.style.grid_align_self,
                        align_items,
                        other_directions_match,
                        false,
                    );
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
            y_offset = alignOffset(align_self, free_height, directions_match, false);
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
    try writeGridBaseline(tree, node, items.items, content, edges);

    try placeAbsolute(
        tree,
        node,
        .{ .width = content.width, .height = final_content_height },
        edges,
        placement_origins,
        columns.items,
        rows.items,
        column_offsets.items,
        row_offsets.items,
        column_gap,
        row_gap,
        justify_distribution.extra_gap,
        align_distribution.extra_gap,
        node.style.writing_direction,
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
        const defer_width = hasPercentageContribution(child.style, .columns);
        const defer_height = hasPercentageContribution(child.style, .rows);
        var child_req = request;
        if (defer_width) {
            child_req.intrinsic_width = true;
        } else if (!naturalAxisDefinite(
            child.style.size.width,
            request.intrinsic_width,
            request.percentage_basis.width,
        )) {
            child_req.intrinsic_width = dimensionAuto(child.style.size.width);
        }
        if (defer_height) {
            child_req.intrinsic_height = true;
        } else if (!naturalAxisDefinite(
            child.style.size.height,
            request.intrinsic_height,
            request.percentage_basis.height,
        )) {
            child_req.intrinsic_height = dimensionAuto(child.style.size.height);
        }
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
            );
        };
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
    if (explicit_count > grid_tracks_max) return error.InvalidStyle;

    const start_line = try placementLine(line.start, explicit_count);
    const end_line = try placementLine(line.end, explicit_count);
    const start_span = try placementSpan(line.start);
    const end_span = try placementSpan(line.end);

    var logical_start: i32 = 0;
    var logical_end: i32 = 1;
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

fn placementLine(value: style.GridPlacement, explicit_count: usize) Error!?i32 {
    return switch (value) {
        .auto, .span => null,
        .line => |line| blk: {
            if (line == 0) break :blk error.InvalidStyle;
            const explicit_line_count: i32 = @intCast(explicit_count + 1);
            if (line > 0) {
                break :blk @as(i32, line) - 1;
            }
            break :blk explicit_line_count + @as(i32, line);
        },
    };
}

fn placementSpan(value: style.GridPlacement) Error!usize {
    return switch (value) {
        .span => |span| blk: {
            const result = @max(@as(usize, 1), @as(usize, span));
            if (result > grid_tracks_max) break :blk error.InvalidStyle;
            break :blk result;
        },
        .auto, .line => 1,
    };
}

fn addLineSpan(line: i32, span: usize) Error!i32 {
    if (span > grid_tracks_max) return error.InvalidStyle;
    const result = @as(i64, line) + @as(i64, @intCast(span));
    if (result < -@as(i64, grid_tracks_max) or result > @as(i64, grid_tracks_max)) {
        return error.InvalidStyle;
    }
    return @intCast(result);
}

fn subtractLineSpan(line: i32, span: usize) Error!i32 {
    if (span > grid_tracks_max) return error.InvalidStyle;
    const result = @as(i64, line) - @as(i64, @intCast(span));
    if (result < -@as(i64, grid_tracks_max) or result > @as(i64, grid_tracks_max)) {
        return error.InvalidStyle;
    }
    return @intCast(result);
}

fn initTracks(
    allocator: std.mem.Allocator,
    tracks: *std.ArrayList(Track),
    explicit: []const style.GridTrack,
    auto_track: style.GridTrack,
    basis: ?f32,
) Error!void {
    if (explicit.len > grid_tracks_max) return error.InvalidStyle;
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
    if (count > grid_tracks_max or tracks.items.len > grid_tracks_max) {
        return error.InvalidStyle;
    }
    const needed = count -| tracks.items.len;
    if (needed > grid_tracks_max - tracks.items.len) return error.InvalidStyle;
    var added: usize = 0;
    while (added < needed and added < grid_tracks_max) : (added += 1) {
        tracks.append(
            allocator,
            .{ .spec = auto_track, .size = try trackMinimum(auto_track, basis) },
        ) catch return error.InvalidStyle;
    }
    if (tracks.items.len < count) return error.InvalidStyle;
}

const PlacementOrigins = struct {
    column_prepend: usize = 0,
    row_prepend: usize = 0,
};

fn prependTracks(
    allocator: std.mem.Allocator,
    tracks: *std.ArrayList(Track),
    count: usize,
    auto_track: style.GridTrack,
    basis: ?f32,
) Error!void {
    if (count > grid_tracks_max or tracks.items.len > grid_tracks_max - count) {
        return error.InvalidStyle;
    }
    if (count == 0) return;

    const implicit_track: Track = .{
        .spec = auto_track,
        .size = try trackMinimum(auto_track, basis),
    };
    tracks.ensureUnusedCapacity(allocator, count) catch return error.InvalidStyle;
    const old_count = tracks.items.len;
    tracks.items.len = old_count + count;
    @memmove(tracks.items[count..], tracks.items[0..old_count]);
    @memset(tracks.items[0..count], implicit_track);
}

fn shiftPlacementIndices(
    placement: *AxisPlacement,
    prepend: usize,
) Error!void {
    if (!placement.definite) {
        const span_i32 = placement.logical_end - placement.logical_start;
        if (span_i32 <= 0) return error.InvalidStyle;
        const span: usize = @intCast(span_i32);
        if (span > grid_tracks_max) return error.InvalidStyle;
        placement.start = 0;
        placement.end = span;
        return;
    }
    placement.start = try shiftedLineIndex(placement.logical_start, prepend);
    placement.end = try shiftedLineIndex(placement.logical_end, prepend);
    if (placement.end <= placement.start) return error.InvalidStyle;
}

fn shiftedLineIndex(line: i32, prepend: usize) Error!usize {
    const shifted = @as(i64, line) + @as(i64, @intCast(prepend));
    if (shifted < 0 or shifted > @as(i64, grid_tracks_max)) {
        return error.InvalidStyle;
    }
    return @intCast(shifted);
}

fn normalizeAxisPlacements(
    allocator: std.mem.Allocator,
    tracks: *std.ArrayList(Track),
    items: []FlowItem,
    axis: TrackAxis,
    auto_track: style.GridTrack,
    basis: ?f32,
) Error!usize {
    var minimum_start: i32 = 0;
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
        @intCast(-@as(i64, minimum_start))
    else
        0;
    try prependTracks(allocator, tracks, prepend, auto_track, basis);
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
    auto_column: style.GridTrack,
    auto_row: style.GridTrack,
    column_basis: ?f32,
    row_basis: ?f32,
    occupied: *std.AutoHashMapUnmanaged(Cell, void),
) Error!PlacementOrigins {
    const origins: PlacementOrigins = .{
        .column_prepend = try normalizeAxisPlacements(
            allocator,
            columns,
            items.items,
            .columns,
            auto_column,
            column_basis,
        ),
        .row_prepend = try normalizeAxisPlacements(
            allocator,
            rows,
            items.items,
            .rows,
            auto_row,
            row_basis,
        ),
    };
    const dense = flow == .row_dense or flow == .column_dense;
    const row_flow = flow == .row or flow == .row_dense;
    var partial_primary_cursors: [grid_tracks_max]u16 = undefined;
    const PartialCursorSet = std.StaticBitSet(grid_tracks_max);
    var partial_cursor_set: PartialCursorSet = undefined;
    if (!dense) partial_cursor_set = PartialCursorSet.initEmpty();
    var scan_cells_remaining = grid_cells_max;

    // Fully definite items reserve their cells first, independent of source order.
    for (items.items) |*item| {
        if (!item.row.definite or !item.column.definite) continue;
        const row_span = try placementSpanIndices(item.row);
        const column_span = try placementSpanIndices(item.column);
        const cell_count = try gridCellCount(row_span, column_span);
        try ensureTracks(allocator, rows, item.row.end, auto_row, row_basis);
        try ensureTracks(allocator, columns, item.column.end, auto_column, column_basis);
        try markArea(
            allocator,
            occupied,
            item.row.start,
            item.column.start,
            row_span,
            column_span,
            cell_count,
        );
    }

    // Phase 2 places only items locked to the secondary axis.
    for (items.items) |*item| {
        if (item.row.definite == item.column.definite) continue;
        const secondary_axis_definite = if (row_flow) item.row.definite else item.column.definite;
        if (!secondary_axis_definite) continue;
        const secondary_start = if (row_flow) item.row.start else item.column.start;
        if (secondary_start >= grid_tracks_max) return error.InvalidStyle;
        var cursor_row: usize = 0;
        var cursor_column: usize = 0;
        if (!dense and partial_cursor_set.isSet(secondary_start)) {
            const primary_cursor: usize = partial_primary_cursors[secondary_start];
            if (row_flow) {
                cursor_column = primary_cursor;
            } else {
                cursor_row = primary_cursor;
            }
        }
        try placeItem(
            allocator,
            columns,
            rows,
            item,
            flow,
            dense,
            auto_column,
            auto_row,
            column_basis,
            row_basis,
            occupied,
            &scan_cells_remaining,
            &cursor_row,
            &cursor_column,
        );
        if (!dense) {
            const primary_end = if (row_flow) item.column.end else item.row.end;
            const secondary_end = if (row_flow) item.row.end else item.column.end;
            if (primary_end > grid_tracks_max or primary_end > std.math.maxInt(u16)) {
                return error.InvalidStyle;
            }
            if (secondary_end <= secondary_start or secondary_end > grid_tracks_max) {
                return error.InvalidStyle;
            }
            const bounded_primary_end: u16 = @intCast(primary_end);
            for (secondary_start..secondary_end) |secondary_index| {
                if (!partial_cursor_set.isSet(secondary_index) or
                    partial_primary_cursors[secondary_index] < bounded_primary_end)
                {
                    partial_primary_cursors[secondary_index] = bounded_primary_end;
                    partial_cursor_set.set(secondary_index);
                }
            }
        }
    }

    // Phase 3 fixes the primary-axis extent before the shared cursor places
    // the remaining items.
    if (row_flow) {
        try preSizePrimaryTracks(
            allocator,
            columns,
            items.items,
            .columns,
            auto_column,
            column_basis,
        );
    } else {
        try preSizePrimaryTracks(
            allocator,
            rows,
            items.items,
            .rows,
            auto_row,
            row_basis,
        );
    }

    // Phase 4 shares one cursor across main-axis-definite and fully-auto
    // items, preserving their source order.
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
            auto_column,
            auto_row,
            column_basis,
            row_basis,
            occupied,
            &scan_cells_remaining,
            &auto_cursor_row,
            &auto_cursor_column,
        );
    }
    return origins;
}

fn placementSpanIndices(placement: AxisPlacement) Error!usize {
    if (placement.end <= placement.start) return error.InvalidStyle;
    const span = placement.end - placement.start;
    if (span > grid_tracks_max) return error.InvalidStyle;
    return span;
}

fn preSizePrimaryTracks(
    allocator: std.mem.Allocator,
    tracks: *std.ArrayList(Track),
    items: []const FlowItem,
    axis: TrackAxis,
    auto_track: style.GridTrack,
    basis: ?f32,
) Error!void {
    if (tracks.items.len > grid_tracks_max) return error.InvalidStyle;
    var required = tracks.items.len;
    for (items) |item| {
        const placement = switch (axis) {
            .columns => item.column,
            .rows => item.row,
        };
        const span = try placementSpanIndices(placement);
        const extent = if (placement.definite) placement.end else span;
        if (extent > grid_tracks_max) return error.InvalidStyle;
        required = @max(required, extent);
    }
    try ensureTracks(allocator, tracks, required, auto_track, basis);
}

fn placeItem(
    allocator: std.mem.Allocator,
    columns: *std.ArrayList(Track),
    rows: *std.ArrayList(Track),
    item: *FlowItem,
    flow: style.GridAutoFlow,
    dense: bool,
    auto_column: style.GridTrack,
    auto_row: style.GridTrack,
    column_basis: ?f32,
    row_basis: ?f32,
    occupied: *std.AutoHashMapUnmanaged(Cell, void),
    scan_cells_remaining: *usize,
    cursor_row: *usize,
    cursor_column: *usize,
) Error!void {
    const row_flow = flow == .row or flow == .row_dense;
    const row_span = try placementSpanIndices(item.row);
    const column_span = try placementSpanIndices(item.column);
    const cell_count = try gridCellCount(row_span, column_span);
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
    while (attempts < grid_cells_max) : (attempts += 1) {
        const candidate_row_end = try indexAdd(candidate_row, row_span);
        const candidate_column_end = try indexAdd(candidate_column, column_span);

        if (row_flow and !item.column.definite and candidate_column_end > columns.items.len) {
            if (item.row.definite or column_span > columns.items.len) {
                try ensureTracks(
                    allocator,
                    columns,
                    candidate_column_end,
                    auto_column,
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
                    auto_row,
                    row_basis,
                );
            } else {
                try incrementIndex(&candidate_column);
                candidate_row = 0;
                continue;
            }
        }

        if (candidate_row_end > rows.items.len) {
            try ensureTracks(allocator, rows, candidate_row_end, auto_row, row_basis);
        }
        if (candidate_column_end > columns.items.len) {
            try ensureTracks(
                allocator,
                columns,
                candidate_column_end,
                auto_column,
                column_basis,
            );
        }

        if (try areaFree(
            occupied,
            candidate_row,
            candidate_column,
            row_span,
            column_span,
            cell_count,
            scan_cells_remaining,
        )) {
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
                cell_count,
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

        if (row_flow) {
            if (item.column.definite) {
                try incrementIndex(&candidate_row);
            } else if (item.row.definite) {
                try incrementIndex(&candidate_column);
            } else {
                try incrementIndex(&candidate_column);
                if (candidate_column >= columns.items.len) {
                    candidate_column = 0;
                    try incrementIndex(&candidate_row);
                }
            }
        } else {
            if (item.row.definite) {
                try incrementIndex(&candidate_column);
            } else if (item.column.definite) {
                try incrementIndex(&candidate_row);
            } else {
                try incrementIndex(&candidate_row);
                if (candidate_row >= rows.items.len) {
                    candidate_row = 0;
                    try incrementIndex(&candidate_column);
                }
            }
        }
    }
    return error.InvalidStyle;
}

fn gridCellCount(row_span: usize, column_span: usize) Error!usize {
    if (row_span == 0 or column_span == 0) return error.InvalidStyle;
    if (column_span > grid_cells_max) return error.InvalidStyle;
    if (row_span > grid_cells_max / column_span) return error.InvalidStyle;
    return row_span * column_span;
}

fn indexAdd(start: usize, span: usize) Error!usize {
    if (span == 0 or span > grid_tracks_max) return error.InvalidStyle;
    if (start > grid_tracks_max - span) return error.InvalidStyle;
    return start + span;
}

fn incrementIndex(index: *usize) Error!void {
    if (index.* >= grid_tracks_max) return error.InvalidStyle;
    index.* += 1;
}

fn areaFree(
    occupied: *const std.AutoHashMapUnmanaged(Cell, void),
    row: usize,
    column: usize,
    row_span: usize,
    column_span: usize,
    cell_count: usize,
    scan_cells_remaining: *usize,
) Error!bool {
    if (cell_count == 0 or cell_count > grid_cells_max) return error.InvalidStyle;
    const row_end = try indexAdd(row, row_span);
    const column_end = try indexAdd(column, column_span);

    for (row..row_end) |row_index| {
        for (column..column_end) |column_index| {
            if (scan_cells_remaining.* == 0) return error.InvalidStyle;
            scan_cells_remaining.* -= 1;
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
    cell_count: usize,
) Error!void {
    if (cell_count == 0 or cell_count > grid_cells_max) return error.InvalidStyle;
    if (occupied.count() > grid_cells_max) return error.InvalidStyle;
    const row_end = try indexAdd(row, row_span);
    const column_end = try indexAdd(column, column_span);
    const cells_available = grid_cells_max - occupied.count();

    if (cell_count > cells_available) {
        var cells_new: usize = 0;
        for (row..row_end) |row_index| {
            for (column..column_end) |column_index| {
                if (occupied.contains(.{ .row = row_index, .column = column_index })) continue;
                if (cells_new >= cells_available) return error.InvalidStyle;
                cells_new += 1;
            }
        }
    }

    for (row..row_end) |row_index| {
        for (column..column_end) |column_index| {
            occupied.put(allocator, .{ .row = row_index, .column = column_index }, {}) catch
                return error.InvalidStyle;
        }
    }
}

fn growTrackItems(
    tracks: []Track,
    items: []const FlowItem,
    axis: TrackAxis,
    gap: f32,
    basis: ?f32,
) Error!void {
    if (tracks.len > grid_tracks_max) return error.InvalidStyle;
    const axis_has_flexible_track = spanHasFlexible(tracks, 0, tracks.len);
    var span: usize = 1;
    while (span <= tracks.len and span <= grid_tracks_max) : (span += 1) {
        clearTrackPlans(tracks);
        for (items) |item| {
            const placement = switch (axis) {
                .columns => item.column,
                .rows => item.row,
            };
            if (placement.end - placement.start != span) continue;
            if (spanHasFlexible(tracks, placement.start, placement.end)) continue;
            const need = switch (axis) {
                .columns => try add(
                    item.natural.border.width,
                    item.margins.value.left + item.margins.value.right,
                ),
                .rows => try add(
                    item.natural.border.height,
                    item.margins.value.top + item.margins.value.bottom,
                ),
            };
            try growTracks(
                tracks,
                placement.start,
                placement.end,
                need,
                gap,
                basis,
            );
        }
        try flushTrackPlans(tracks, basis);
        if (span == 1 and axis_has_flexible_track) {
            try recordSingleSpanGrowthLimits(tracks, items, axis, basis);
        }
    }

    clearTrackPlans(tracks);
    for (items) |item| {
        const placement = switch (axis) {
            .columns => item.column,
            .rows => item.row,
        };
        if (!spanHasFlexible(tracks, placement.start, placement.end)) continue;
        const need = switch (axis) {
            .columns => try add(
                item.natural.border.width,
                item.margins.value.left + item.margins.value.right,
            ),
            .rows => try add(
                item.natural.border.height,
                item.margins.value.top + item.margins.value.bottom,
            ),
        };
        try growTracks(
            tracks,
            placement.start,
            placement.end,
            need,
            gap,
            basis,
        );
    }
    try flushTrackPlans(tracks, basis);
}

fn clearTrackPlans(tracks: []Track) void {
    for (tracks) |*track| {
        track.planned_increase = 0;
    }
}

fn flushTrackPlans(tracks: []Track, basis: ?f32) Error!void {
    for (tracks) |*track| {
        if (track.planned_increase > 0) {
            track.size = try add(track.size, track.planned_increase);
        }
        if (!trackIsFlexible(track.spec)) {
            if (try trackMaximum(track.spec, basis)) |maximum| {
                track.size = @min(track.size, try finiteNonNegative(maximum));
            }
            if (track.spec == .minmax) {
                track.size = @max(track.size, try breadthMinimum(track.spec.minmax.min, basis));
            }
        }
        track.size = try nonNegative(track.size);
        track.planned_increase = 0;
    }
}
fn recordSingleSpanGrowthLimits(
    tracks: []Track,
    items: []const FlowItem,
    axis: TrackAxis,
    basis: ?f32,
) Error!void {
    for (items) |item| {
        const placement = switch (axis) {
            .columns => item.column,
            .rows => item.row,
        };
        if (placement.end <= placement.start or placement.end > tracks.len) {
            return error.InvalidStyle;
        }
        if (placement.end - placement.start != 1) continue;
        const track = &tracks[placement.start];
        if (trackIsFlexible(track.spec)) continue;
        if (!trackAllowsIntrinsicContribution(track.spec)) continue;
        if ((try trackMaximum(track.spec, basis)) != null) continue;
        const need = switch (axis) {
            .columns => try add(
                item.natural.border.width,
                item.margins.value.left + item.margins.value.right,
            ),
            .rows => try add(
                item.natural.border.height,
                item.margins.value.top + item.margins.value.bottom,
            ),
        };
        const limit = try finiteNonNegative(@max(track.size, need));
        if (track.intrinsic_growth_limit) |current| {
            track.intrinsic_growth_limit = @max(current, limit);
        } else {
            track.intrinsic_growth_limit = limit;
        }
    }
}

fn trackGrowthLimit(track: Track, basis: ?f32) Error!?f32 {
    const specified = try trackMaximum(track.spec, basis);
    if (specified) |maximum| {
        const finite_maximum = try finiteNonNegative(maximum);
        if (track.intrinsic_growth_limit) |intrinsic| {
            return @min(finite_maximum, try finiteNonNegative(intrinsic));
        }
        return finite_maximum;
    }
    if (track.intrinsic_growth_limit) |intrinsic| {
        return @as(?f32, try finiteNonNegative(intrinsic));
    }
    return null;
}

fn intrinsicOverflowTrack(track: Track, basis: ?f32) Error!bool {
    if (!trackParticipatesInIntrinsicSizing(track.spec)) return false;
    if (!trackAllowsIntrinsicContribution(track.spec)) return false;
    return (try trackMaximum(track.spec, basis)) == null;
}

fn planTrackIncreaseBeyondLimit(track: *Track, increase: f32) Error!void {
    const planned = try finiteNonNegative(increase);
    if (planned > track.planned_increase) track.planned_increase = planned;
}

fn spanHasFlexible(tracks: []const Track, start: usize, end: usize) bool {
    for (tracks[start..end]) |track| {
        if (trackIsFlexible(track.spec)) return true;
    }
    return false;
}

fn sizeTracks(
    columns: *std.ArrayList(Track),
    rows: *std.ArrayList(Track),
    items: []const FlowItem,
    content: widget.Size,
    column_gap: f32,
    row_gap: f32,
    width_definite: bool,
    height_definite: bool,
) Error!void {
    try growTrackItems(
        columns.items,
        items,
        .columns,
        column_gap,
        if (width_definite) content.width else null,
    );
    try growTrackItems(
        rows.items,
        items,
        .rows,
        row_gap,
        if (height_definite) content.height else null,
    );

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

    const crosses_flexible = spanHasFlexible(tracks, start, end);
    var suppress_non_flex = false;
    if (crosses_flexible) {
        if (try distributeIntrinsicFlexDeficit(tracks[start..end], deficit, basis)) {
            deficit = 0;
        } else {
            suppress_non_flex = true;
        }
    }

    var non_fr_unbounded: usize = 0;
    var non_fr_bounded_capacity: f32 = 0;

    for (tracks[start..end]) |track| {
        if (!trackParticipatesInIntrinsicSizing(track.spec)) continue;
        if (!trackAllowsIntrinsicContribution(track.spec)) continue;
        if (try trackGrowthLimit(track, basis)) |maximum| {
            const capacity = @max(0, maximum - track.size);
            if (capacity > 0) {
                non_fr_bounded_capacity = try add(non_fr_bounded_capacity, capacity);
            }
        } else {
            non_fr_unbounded += 1;
        }
    }

    if (suppress_non_flex) return;

    if (non_fr_unbounded > 0) {
        if (non_fr_bounded_capacity > 0) {
            const to_bounded = @min(deficit, non_fr_bounded_capacity);
            for (tracks[start..end]) |*track| {
                if (!trackParticipatesInIntrinsicSizing(track.spec)) continue;
                if (!trackAllowsIntrinsicContribution(track.spec)) continue;
                if (try trackGrowthLimit(track.*, basis)) |maximum| {
                    const capacity = @max(0, maximum - track.size);
                    if (capacity > 0) {
                        const share = to_bounded * capacity / non_fr_bounded_capacity;
                        try planTrackIncrease(track, share, basis);
                    }
                }
            }
            deficit -= to_bounded;
        }
        if (deficit > 0) {
            const share = deficit / @as(f32, @floatFromInt(non_fr_unbounded));
            for (tracks[start..end]) |*track| {
                if (!trackParticipatesInIntrinsicSizing(track.spec)) continue;
                if (!trackAllowsIntrinsicContribution(track.spec)) continue;
                if ((try trackGrowthLimit(track.*, basis)) == null) {
                    try planTrackIncrease(track, share, basis);
                }
            }
            deficit = 0;
        }
    } else if (non_fr_bounded_capacity > 0) {
        const to_bounded = @min(deficit, non_fr_bounded_capacity);
        for (tracks[start..end]) |*track| {
            if (!trackParticipatesInIntrinsicSizing(track.spec)) continue;
            if (!trackAllowsIntrinsicContribution(track.spec)) continue;
            if (try trackGrowthLimit(track.*, basis)) |maximum| {
                const capacity = @max(0, maximum - track.size);
                if (capacity > 0) {
                    const share = to_bounded * capacity / non_fr_bounded_capacity;
                    try planTrackIncrease(track, share, basis);
                }
            }
        }
        deficit -= to_bounded;
    }

    if (deficit > 0) {
        if (try distributeIntrinsicFlexDeficit(tracks[start..end], deficit, basis)) {
            deficit = 0;
        }
    }

    if (deficit > 0) {
        var overflow_track_count: usize = 0;
        for (tracks[start..end]) |track| {
            if (try intrinsicOverflowTrack(track, basis)) overflow_track_count += 1;
        }
        if (overflow_track_count > 0) {
            const share = deficit / @as(f32, @floatFromInt(overflow_track_count));
            for (tracks[start..end]) |*track| {
                if (try intrinsicOverflowTrack(track.*, basis)) {
                    try planTrackIncreaseBeyondLimit(track, share);
                }
            }
        }
    }
}

fn resolveFlexibleTracks(tracks: []Track, content_size: f32, gap: f32) Error!void {
    if (tracks.len > grid_tracks_max) return error.InvalidStyle;
    const total_gaps = if (tracks.len > 1) gap * @as(f32, @floatFromInt(tracks.len - 1)) else 0;

    var bounded_capacity: f32 = 0;
    var non_fr_used: f32 = total_gaps;
    for (tracks) |track| {
        if (!trackIsFlexible(track.spec)) {
            non_fr_used = try add(non_fr_used, track.size);
            if (try trackMaximum(track.spec, content_size)) |maximum| {
                bounded_capacity = try add(bounded_capacity, @max(0, maximum - track.size));
            }
        } else if (trackHasZeroFlexWeight(track.spec)) {
            non_fr_used = try add(non_fr_used, track.size);
        }
    }

    const initial_free = @max(0, try finite(content_size - non_fr_used));
    if (bounded_capacity > 0 and initial_free > 0) {
        for (tracks) |*track| {
            if (trackIsFlexible(track.spec)) continue;
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
        if (!trackIsFlexible(track.spec)) {
            if (try trackMaximum(track.spec, content_size)) |maximum| {
                track.size = @min(track.size, maximum);
            }
            track.size = try nonNegative(track.size);
            non_fr_used = try add(non_fr_used, track.size);
        } else if (trackHasZeroFlexWeight(track.spec)) {
            track.size = try nonNegative(track.size);
            non_fr_used = try add(non_fr_used, track.size);
        }
    }

    var free_space = @max(0, try finite(content_size - non_fr_used));
    var frozen: [grid_tracks_max]bool = undefined;
    @memset(frozen[0..tracks.len], false);
    var bases: [grid_tracks_max]f32 = undefined;
    for (tracks, 0..) |track, i| {
        bases[i] = track.size;
    }

    var iterations: usize = 0;
    while (iterations <= grid_tracks_max) : (iterations += 1) {
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

        const fr_denominator = @max(unfrozen_fr_sum, 1);

        var newly_frozen = false;
        for (tracks, 0..) |*track, i| {
            const fr = trackFraction(track.spec);
            if (fr > 0 and !frozen[i]) {
                const hypothetical_size = free_space * fr / fr_denominator;
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
                track.size = @max(free_space * fr / fr_denominator, bases[i]);
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
    if (iterations > grid_tracks_max) return error.InvalidStyle;
}

fn nodeFirstBaseline(
    tree: *const widget.WidgetTree,
    child_index: usize,
    child_size: widget.Size,
    child_edges: Edges,
) f32 {
    const node = &tree.nodes.items[child_index];
    if (node.first_baseline) |baseline| return baseline;
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
                            .box_horizontal = 0,
                            .box_vertical = 0,
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
fn writeGridBaseline(
    tree: *widget.WidgetTree,
    container: *widget.WidgetNode,
    items: []const FlowItem,
    content: widget.Size,
    edges: Edges,
) Error!void {
    if (items.len == 0) {
        container.first_baseline = null;
        return;
    }
    var first_row: usize = grid_tracks_max;
    for (items) |item| {
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
        const child_baseline = nodeFirstBaseline(
            tree,
            item.index,
            .{ .width = child.rect.w, .height = child.rect.h },
            child_edges,
        );
        container.first_baseline = try add(
            try add(edges.border.top, edges.padding.top),
            try add(child.rect.y, child_baseline),
        );
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

fn trackHasAutoMaximum(track: style.GridTrack) bool {
    return switch (track) {
        .auto => true,
        .minmax => |value| switch (value.max) {
            .auto => true,
            .fixed, .percent, .min_content, .max_content, .fr, .fit_content => false,
        },
        .fixed, .percent, .min_content, .max_content, .fr, .fit_content => false,
    };
}

fn trackIsFlexible(track: style.GridTrack) bool {
    return switch (track) {
        .fr => true,
        .minmax => |value| switch (value.max) {
            .fr => true,
            .fixed, .percent, .auto, .min_content, .max_content, .fit_content => false,
        },
        .fixed, .percent, .auto, .min_content, .max_content, .fit_content => false,
    };
}

fn trackHasZeroFlexWeight(track: style.GridTrack) bool {
    return switch (track) {
        .fr => |weight| weight == 0,
        .minmax => |value| switch (value.max) {
            .fr => |weight| weight == 0,
            .fixed, .percent, .auto, .min_content, .max_content, .fit_content => false,
        },
        .fixed, .percent, .auto, .min_content, .max_content, .fit_content => false,
    };
}

fn trackHasIntrinsicMinimum(track: style.GridTrack) bool {
    return switch (track) {
        .auto, .min_content, .max_content, .fit_content, .fr => true,
        .minmax => |value| switch (value.min) {
            .auto, .min_content, .max_content, .fit_content => true,
            .fixed, .percent, .fr => false,
        },
        .fixed, .percent => false,
    };
}

fn planTrackIncrease(track: *Track, increase: f32, basis: ?f32) Error!void {
    var planned = try finiteNonNegative(increase);
    if (try trackGrowthLimit(track.*, basis)) |maximum| {
        const capacity = @max(0, maximum - track.size);
        planned = @min(planned, capacity);
    }
    if (planned > track.planned_increase) track.planned_increase = planned;
}

fn distributeIntrinsicFlexDeficit(tracks: []Track, deficit: f32, basis: ?f32) Error!bool {
    var flex_total: f32 = 0;
    var eligible_flexible_count: usize = 0;
    for (tracks) |track| {
        if (!trackIsFlexible(track.spec)) continue;
        if (!trackHasIntrinsicMinimum(track.spec)) continue;
        eligible_flexible_count += 1;
        const fraction = trackFraction(track.spec);
        if (fraction > 0) flex_total = try add(flex_total, fraction);
    }
    if (eligible_flexible_count == 0) return false;

    if (flex_total > 0) {
        for (tracks) |*track| {
            if (!trackIsFlexible(track.spec)) continue;
            if (!trackHasIntrinsicMinimum(track.spec)) continue;
            const fraction = trackFraction(track.spec);
            if (fraction > 0) {
                try planTrackIncrease(track, deficit * fraction / flex_total, basis);
            }
        }
    } else {
        const share = deficit / @as(f32, @floatFromInt(eligible_flexible_count));
        for (tracks) |*track| {
            if (!trackIsFlexible(track.spec)) continue;
            if (!trackHasIntrinsicMinimum(track.spec)) continue;
            try planTrackIncrease(track, share, basis);
        }
    }
    return true;
}

fn trackParticipatesInIntrinsicSizing(track: style.GridTrack) bool {
    return !trackIsFlexible(track) or trackHasZeroFlexWeight(track);
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
        .fixed, .percent, .auto, .min_content, .max_content, .fit_content => 0,
    };
}

fn trackMinimumSum(tracks: []const style.GridTrack, basis: ?f32) Error!f32 {
    var result: f32 = 0;
    for (tracks) |track| result = try add(result, try trackMinimum(track, basis));
    return result;
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
            input.grid_column_gap,
            selectAxisGap(input.column_gap, input.gap),
        ),
        .rows => selectAxisGap(
            input.grid_row_gap,
            selectAxisGap(input.row_gap, input.gap),
        ),
    };
    try validateLengthPercentage(value, false);
    return finiteNonNegative(value.resolve(basis) orelse 0);
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
    const available = try finite(free);
    const distributed = @max(0, available);
    if (count == 0) return .{ .offset = 0, .extra_gap = 0 };
    const count_f: f32 = @floatFromInt(count);
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
                distributed / @as(f32, @floatFromInt(count - 1))
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
    const count_f: f32 = @floatFromInt(count);
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
                distributed / @as(f32, @floatFromInt(count - 1))
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
    gap: f32,
    extra_gap: f32,
    content_extent: f32,
    frame_start: f32,
    frame_end: f32,
    reverse: bool,
) Error!AbsoluteArea {
    const start_line = try placementLine(line.start, explicit_count);
    const end_line = try placementLine(line.end, explicit_count);
    const start_span: ?usize = if (line.start == .span)
        placementSpan(line.start) catch null
    else
        null;
    const end_span: ?usize = if (line.end == .span)
        placementSpan(line.end) catch null
    else
        null;

    // Resolve each side before converting it to the final track index. A
    // span that cannot be resolved leaves only its opposite side definite.
    var logical_start: ?i32 = start_line;
    if (logical_start == null and line.start == .span) {
        if (end_line) |end| {
            if (start_span) |span| {
                logical_start = subtractLineSpan(end, span) catch null;
            }
        }
    }
    var logical_end: ?i32 = end_line;
    if (logical_end == null and line.end == .span) {
        if (start_line) |start| {
            if (end_span) |span| {
                logical_end = addLineSpan(start, span) catch null;
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
            logical_end = addLineSpan(logical_start.?, 1) catch null;
        }
    }

    const start_index: ?usize = if (logical_start) |logical| blk: {
        const index = shiftedLineIndex(logical, prepend) catch break :blk null;
        if (index > tracks.len) break :blk null;
        break :blk index;
    } else null;
    const end_index: ?usize = if (logical_end) |logical| blk: {
        const index = shiftedLineIndex(logical, prepend) catch break :blk null;
        if (index > tracks.len) break :blk null;
        break :blk index;
    } else null;

    if (start_index != null and end_index != null) {
        const logical_start_offset = try absoluteBoundaryOffset(
            start_index.?,
            tracks,
            offsets,
            gap,
            extra_gap,
            .start,
        );
        const logical_end_offset = try absoluteBoundaryOffset(
            end_index.?,
            tracks,
            offsets,
            gap,
            extra_gap,
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
            gap,
            extra_gap,
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
            gap,
            extra_gap,
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
    gap: f32,
    extra_gap: f32,
    boundary: AbsoluteBoundary,
) Error!f32 {
    if (index > tracks.len) return error.InvalidStyle;
    if (boundary == .start) {
        if (index < offsets.len) return finite(offsets[index]);
        if (index > 0 and index - 1 < offsets.len) {
            return add(offsets[index - 1], tracks[index - 1].size);
        }
    } else {
        if (index == 0) {
            if (offsets.len > 0) return finite(offsets[0]);
        } else if (index - 1 < offsets.len) {
            return add(offsets[index - 1], tracks[index - 1].size);
        }
    }

    const preceding_track = boundary == .end and index > 0;
    const start_index = if (preceding_track) index - 1 else index;
    var result: f32 = 0;
    for (tracks, 0..) |track, track_index| {
        if (track_index >= start_index) break;
        result = try add(result, track.size);
        if (track_index + 1 < start_index) {
            result = try add(result, gap + extra_gap);
        }
    }
    if (preceding_track) {
        result = try add(result, tracks[index - 1].size);
    }
    return finite(result);
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
    columns: []const Track,
    rows: []const Track,
    column_offsets: []const f32,
    row_offsets: []const f32,
    column_gap: f32,
    row_gap: f32,
    column_extra_gap: f32,
    row_extra_gap: f32,
    writing_direction: style.Direction,
    options: Options,
    depth: usize,
) Error!void {
    for (container.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        const child = &tree.nodes.items[child_index];
        if (child.layout_hidden or child.style.position != .absolute) continue;
        const frame_start_x = try finite(-container_edges.padding.left);
        const frame_end_x = try add(content.width, container_edges.padding.right);
        const column_area = try absoluteAreaFor(
            gridLineFor(child.style, .columns),
            @max(@as(usize, 1), container.style.grid_template_columns.len),
            placement_origins.column_prepend,
            columns,
            column_offsets,
            column_gap,
            column_extra_gap,
            content.width,
            frame_start_x,
            frame_end_x,
            writing_direction == .rtl,
        );
        const area_x = column_area.start;
        const area_width = try column_area.width();

        const frame_start_y = try finite(-container_edges.padding.top);
        const frame_end_y = try add(content.height, container_edges.padding.bottom);
        const row_area = try absoluteAreaFor(
            gridLineFor(child.style, .rows),
            @max(@as(usize, 1), container.style.grid_template_rows.len),
            placement_origins.row_prepend,
            rows,
            row_offsets,
            row_gap,
            row_extra_gap,
            content.height,
            frame_start_y,
            frame_end_y,
            false,
        );
        const area_y = row_area.start;
        const area_height = try row_area.width();
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
            sizing_style.size.width = .{ .length = try borderToSizing(
                inset_width,
                edges.box_horizontal,
                child.style.box_sizing,
            ) };
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
            sizing_style.size.height = .{ .length = try borderToSizing(
                inset_height,
                edges.box_vertical,
                child.style.box_sizing,
            ) };
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
        const x = if (left_wins)
            try add(area_x, try add(left.?, margins.value.left))
        else if (right) |value|
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
        const y = if (top_wins)
            try add(area_y, try add(top.?, margins.value.top))
        else if (bottom) |value|
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
    if (width == null and input.aspect_ratio != null and height != null) {
        width = try finite(height.? * try ratio(input.aspect_ratio.?));
        width_edge_sum = edges.box_horizontal;
    }
    var result: widget.Size = .{
        .width = if (width_resolved_border)
            width.?
        else
            try sizingToBorder(width orelse 0, width_edge_sum, input.box_sizing),
        .height = if (height_resolved_border)
            height.?
        else
            try sizingToBorder(height orelse 0, height_edge_sum, input.box_sizing),
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
        .width = @max(
            dimensionAdjustment(input.size.width, edges.horizontal, edges.box_horizontal),
            result.width,
        ),
        .height = @max(
            dimensionAdjustment(input.size.height, edges.vertical, edges.box_vertical),
            result.height,
        ),
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
        .percent => |fraction| blk: {
            const basis = percentage_basis orelse return error.InvalidStyle;
            break :blk @as(?f32, try finite(fraction * basis));
        },
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
        .top = try edge(input.border_inset.top, input.border.top, basis),
        .right = try edge(input.border_inset.right, input.border.right, basis),
        .bottom = try edge(input.border_inset.bottom, input.border.bottom, basis),
        .left = try edge(input.border_inset.left, input.border.left, basis),
    };
    const resolved_padding: style.Sides = .{
        .top = try edge(input.padding_inset.top, input.padding.top, basis),
        .right = try edge(input.padding_inset.right, input.padding.right, basis),
        .bottom = try edge(input.padding_inset.bottom, input.padding.bottom, basis),
        .left = try edge(input.padding_inset.left, input.padding.left, basis),
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
