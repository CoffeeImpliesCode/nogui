const std = @import("std");
const Id = @import("../id.zig").Id;
const layout_context = @import("context.zig");
const sizing = @import("sizing.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");
const overflow = @import("overflow.zig");

pub const MeasureFn = layout_context.MeasureFn;
pub const Options = struct {
    allocator: std.mem.Allocator,
    available: widget.Size,
    measure: ?MeasureFn,
    context: ?*layout_context.LayoutContext = null,
    measurement_cache: ?*layout_context.MeasurementCache = null,
    intrinsic_width: bool = false,
    intrinsic_height: bool = false,
};
fn initialRequest(available: widget.Size, options: Options) layout_context.Request {
    return .{
        .available = available,
        .percentage_basis = .{
            .width = available.width,
            .height = available.height,
        },
        .width_mode = if (options.intrinsic_width) .max_content else .definite,
        .height_mode = if (options.intrinsic_height) .max_content else .definite,
        .sizing_mode = .inherent,
        .known_border = .{ .width = null, .height = null },
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

fn childNaturalRequest(
    parent: layout_context.Request,
    parent_node: *const widget.WidgetNode,
    child: *const widget.WidgetNode,
    available: widget.Size,
    percentage_basis: style.Size(?f32),
) layout_context.Request {
    const width_available_definite = if (parent.known_border.width != null)
        true
    else if (parent.sizing_mode == .content)
        false
    else
        naturalAxisDefinite(
            parent_node.style.size.width,
            parent.width_mode,
            parent.percentage_basis.width,
        );
    const height_available_definite = if (parent.known_border.height != null)
        true
    else if (parent.sizing_mode == .content)
        false
    else
        naturalAxisDefinite(
            parent_node.style.size.height,
            parent.height_mode,
            parent.percentage_basis.height,
        );
    const width_basis_definite = parent.known_border.width != null or
        (parent.sizing_mode == .inherent and
            preferredAxisDefinite(
                parent_node.style.size.width,
                parent.percentage_basis.width,
            ));
    const height_basis_definite = parent.known_border.height != null or
        (parent.sizing_mode == .inherent and
            preferredAxisDefinite(
                parent_node.style.size.height,
                parent.percentage_basis.height,
            ));
    const width_basis = if (parent.width_mode == .min_content and
        parent.known_border.width == null)
        null
    else if (width_basis_definite)
        percentage_basis.width
    else
        null;
    const height_basis = if (parent.height_mode == .min_content and
        parent.known_border.height == null)
        null
    else if (height_basis_definite)
        percentage_basis.height
    else
        null;
    const width_mode: layout_context.MeasureMode = if (parent.width_mode == .min_content)
        .min_content
    else if (width_available_definite and dimensionAuto(child.style.size.width))
        .definite
    else if (dimensionNeedsIntrinsicMeasurement(child.style.size.width, width_basis))
        .max_content
    else
        .definite;
    const height_mode: layout_context.MeasureMode = if (parent.height_mode == .min_content)
        .min_content
    else if (height_available_definite and dimensionAuto(child.style.size.height))
        .definite
    else if (dimensionNeedsIntrinsicMeasurement(child.style.size.height, height_basis))
        .max_content
    else
        .definite;
    return .{
        .available = available,
        .percentage_basis = .{
            .width = width_basis,
            .height = height_basis,
        },
        .width_mode = width_mode,
        .height_mode = height_mode,
        .sizing_mode = .inherent,
        .known_border = .{ .width = null, .height = null },
    };
}

fn naturalAxisDefinite(
    dimension: style.Dimension,
    mode: layout_context.MeasureMode,
    percentage_basis: ?f32,
) bool {
    return switch (dimension) {
        .length => true,
        .percent => percentage_basis != null,
        .auto => mode == .definite,
        .min_content, .max_content, .fit_content => false,
    };
}

fn preferredAxisDefinite(
    dimension: style.Dimension,
    percentage_basis: ?f32,
) bool {
    return switch (dimension) {
        .length => true,
        .percent => percentage_basis != null,
        .auto, .min_content, .max_content, .fit_content => false,
    };
}
fn dimensionNeedsIntrinsicMeasurement(
    value: style.Dimension,
    percentage_basis: ?f32,
) bool {
    return switch (value) {
        .auto, .min_content, .max_content, .fit_content => true,
        .percent => percentage_basis == null,
        .length => false,
    };
}

pub fn layoutContainer(tree: *widget.WidgetTree, container_id: Id, options: Options) sizing.Error!void {
    if (!std.math.isFinite(options.available.width)) return error.InvalidStyle;
    if (!std.math.isFinite(options.available.height)) return error.InvalidStyle;
    const index = tree.nodeIndex(container_id) orelse return error.InvalidStyle;
    if (container_id == .root) return error.InvalidStyle;
    try validateTree(tree, index, null, tree.nodes.items.len);
    try markHidden(tree, index, false, tree.nodes.items.len);
    try layoutPreparedContainer(tree, container_id, options, null);
}

/// Lay out a validated, already-prepared subtree without repeating validation
/// or hidden-state classification. The dispatcher uses this entry for mixed
/// children so each engine keeps ownership of its own geometry.
pub fn layoutPreparedContainer(
    tree: *widget.WidgetTree,
    container_id: Id,
    options: Options,
    forced_border: ?widget.Size,
) sizing.Error!void {
    const index = tree.nodeIndex(container_id) orelse return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    node.first_baseline = null;
    if (node.layout_hidden) return;

    var cache: std.ArrayList(Natural) = .empty;
    defer cache.deinit(options.allocator);
    try cache.resize(options.allocator, tree.nodes.items.len);
    for (cache.items) |*entry| entry.* = .{
        .content = .{ .width = 0, .height = 0 },
        .border = .{ .width = 0, .height = 0 },
    };
    var local_measurement_cache: layout_context.MeasurementCache = .{};
    const measurement_cache = options.measurement_cache orelse
        if (options.context) |context|
            &context.flex_measure_cache
        else
            &local_measurement_cache;
    const owns_measurement_cache = options.measurement_cache == null and options.context == null;
    defer if (owns_measurement_cache) local_measurement_cache.deinit(options.allocator);
    var prepared_options = options;
    prepared_options.measurement_cache = measurement_cache;

    const request = initialRequest(options.available, options);
    const intrinsic = try measureNode(
        tree,
        index,
        request,
        prepared_options,
        cache.items,
        tree.nodes.items.len,
        null,
    );
    const edges = try resolveEdges(tree.nodes.items[index].style, request.percentage_basis.width);
    const fallback: widget.Size = .{
        .width = if (options.intrinsic_width) intrinsic.border.width else request.available.width,
        .height = if (options.intrinsic_height) intrinsic.border.height else request.available.height,
    };
    const size = forced_border orelse try usedSize(
        tree.nodes.items[index].style,
        request.available,
        request.percentage_basis,
        intrinsic.content,
        edges,
        fallback,
    );
    const origin = tree.nodes.items[index].rect;
    tree.nodes.items[index].rect = .{
        .x = origin.x,
        .y = origin.y,
        .w = size.width,
        .h = size.height,
    };
    try layoutFlex(
        tree,
        index,
        options.available,
        size,
        forced_border != null,
        prepared_options,
        cache.items,
        tree.nodes.items.len,
    );
}
/// Measure a flex container's natural content and border size without placing it.
///
/// The caller owns the final used border rectangle and must invoke the layout
/// callback separately after it has resolved that rectangle.
pub fn measureNatural(
    tree: *widget.WidgetTree,
    node: *const widget.WidgetNode,
    request: layout_context.Request,
    context: *layout_context.LayoutContext,
) sizing.Error!layout_context.Measured {
    const index = tree.nodeIndex(node.id) orelse return error.InvalidStyle;
    if (&tree.nodes.items[index] != node) return error.InvalidStyle;
    try layout_context.validateNaturalRequest(tree, node, request);

    var cache: std.ArrayList(Natural) = .empty;
    defer cache.deinit(context.allocator);
    try cache.resize(context.allocator, tree.nodes.items.len);
    for (cache.items) |*entry| entry.* = .{
        .content = .{ .width = 0, .height = 0 },
        .border = .{ .width = 0, .height = 0 },
    };

    const natural = try measureNode(
        tree,
        index,
        request,
        .{
            .allocator = context.allocator,
            .available = request.available,
            .measure = context.measure,
            .context = context,
            .measurement_cache = &context.flex_measure_cache,
        },
        cache.items,
        tree.nodes.items.len,
        null,
    );
    return .{
        .content = natural.content,
        .border = natural.border,
    };
}

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

const Axes = struct {
    horizontal: bool,
    reverse: bool,
    cross_reverse: bool,
};

const Natural = struct {
    content: widget.Size,
    border: widget.Size,
};

const AxisConstraints = struct {
    min: ?f32,
    max: ?f32,
};

const Constraints = struct {
    main: AxisConstraints,
    cross: AxisConstraints,
};

const ResolvedConstraints = struct {
    style: Constraints,
    transferred: Constraints,
    minimum_main: f32,
};

const Item = struct {
    index: usize,
    flex_basis: f32,
    inner_flex_basis: f32,
    hypothetical_main: f32,
    hypothetical_outer: f32,
    target: f32,
    provisional: f32,
    violation: f32,
    main_floor: f32,
    cross: f32,
    main_min: f32,
    main_max: ?f32,
    cross_min: f32,
    cross_max: ?f32,
    hypothetical_cross_min: f32,
    hypothetical_cross_max: ?f32,
    margin_start: f32,
    margin_end: f32,
    cross_margin_start: f32,
    cross_margin_end: f32,
    main_start_auto: bool,
    main_end_auto: bool,
    cross_start_auto: bool,
    cross_end_auto: bool,
    cross_auto: bool,
    grow: f32,
    shrink: f32,
    frozen: bool,
    baseline: f32,
    baseline_participates: bool,
    physical_top_margin: f32,
    physical_bottom_margin: f32,
    laid_out: bool,
};

const Line = struct {
    start: usize,
    count: usize,
    cross: f32 = 0,
    position: f32 = 0,
    max_baseline: f32 = 0,
    max_descent: f32 = 0,
    baseline_count: usize = 0,
};

const Distribution = struct {
    offset: f32,
    gap: f32,
};

fn validateTree(
    tree: *const widget.WidgetTree,
    index: usize,
    parent: ?Id,
    depth: usize,
) sizing.Error!void {
    if (depth == 0 or index >= tree.nodes.items.len) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    if (parent) |expected| {
        if (node.parent != expected) return error.InvalidStyle;
    }
    for (node.children.items, 0..) |child_id, offset| {
        if (child_id == .root) return error.InvalidStyle;
        for (node.children.items[0..offset]) |prior_id| {
            if (prior_id == child_id) return error.InvalidStyle;
        }
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        if (child_index >= index) return error.InvalidStyle;
        try validateTree(tree, child_index, node.id, depth - 1);
    }
    for (tree.nodes.items) |candidate| {
        if (candidate.parent != node.id) continue;
        var listed = false;
        for (node.children.items) |child_id| {
            if (child_id == candidate.id) listed = true;
        }
        if (!listed) return error.InvalidStyle;
    }
    if (node.children.items.len == 0 or node.style.display == .none) return;
    if (node.style.display != .flex) return error.InvalidStyle;
    switch (node.kind) {
        .row, .column => {},
        else => return error.InvalidStyle,
    }
    try validateGaps(node.style);
}
fn markHidden(
    tree: *widget.WidgetTree,
    index: usize,
    inherited: bool,
    depth: usize,
) sizing.Error!void {
    if (depth == 0) return error.InvalidStyle;
    const hidden = inherited or tree.nodes.items[index].style.display == .none;
    if (hidden) {
        tree.nodes.items[index].first_baseline = null;
        tree.nodes.items[index].rect = .{};
        tree.nodes.items[index].resolved_box_edges = null;
        tree.nodes.items[index].layout_content_size = .{ .width = 0, .height = 0 };
        if (tree.nodes.items[index].scroll) |scroll| {
            scroll.state.max_offset = .{ 0, 0 };
        }
    }
    for (tree.nodes.items[index].children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        try markHidden(tree, child_index, hidden, depth - 1);
    }
}
fn measureNode(
    tree: *widget.WidgetTree,
    index: usize,
    request: layout_context.Request,
    options: Options,
    cache: []Natural,
    depth: usize,
    parent_display: ?style.Display,
) sizing.Error!Natural {
    if (depth == 0 or index >= tree.nodes.items.len) return error.InvalidStyle;
    const cache_key = layout_context.MeasurementCache.key(
        index,
        request,
        parent_display,
    );
    if (options.measurement_cache) |measurement_cache| {
        if (measurement_cache.lookup(cache_key)) |cached| {
            const natural: Natural = .{
                .content = cached.content,
                .border = cached.border,
            };
            cache[index] = natural;
            return natural;
        }
    }
    const measured = try measureNodeUncached(
        tree,
        index,
        request,
        options,
        cache,
        depth,
        parent_display,
    );
    if (options.measurement_cache) |measurement_cache| {
        try measurement_cache.insert(options.allocator, cache_key, .{
            .content = measured.content,
            .border = measured.border,
        });
    }
    cache[index] = measured;
    return measured;
}
fn measureNodeUncached(
    tree: *widget.WidgetTree,
    index: usize,
    request: layout_context.Request,
    options: Options,
    cache: []Natural,
    depth: usize,
    parent_display: ?style.Display,
) sizing.Error!Natural {
    if (depth == 0) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    if (node.layout_hidden) return .{
        .content = .{ .width = 0, .height = 0 },
        .border = .{ .width = 0, .height = 0 },
    };
    if (node.children.items.len == 0) {
        const edges = try resolveEdges(node.style, request.percentage_basis.width);
        const content = try measureLeaf(node, request, edges, options.measure);
        const border = try usedSizeForRequest(
            node.style,
            request.available,
            request.percentage_basis,
            content,
            edges,
            request,
        );
        cache[index] = .{
            .content = content,
            .border = border,
        };
        return cache[index];
    }
    if (options.context) |context| {
        if (parent_display) |display| {
            if (node.style.display != display) {
                const measured = try context.measure_node(context, tree, node, request);
                cache[index] = .{
                    .content = measured.content,
                    .border = measured.border,
                };
                return cache[index];
            }
        }
    }
    if (node.style.display != .flex) return error.InvalidStyle;
    const edges = try resolveEdges(node.style, request.percentage_basis.width);
    const content = try measureContainerContent(
        tree,
        index,
        request,
        edges,
        options,
        cache,
        depth - 1,
    );
    const border = try usedSizeForRequest(
        node.style,
        request.available,
        request.percentage_basis,
        content,
        edges,
        request,
    );
    cache[index] = .{
        .content = content,
        .border = border,
    };
    return cache[index];
}

fn measureAutomaticMinimum(
    tree: *widget.WidgetTree,
    child_index: usize,
    child: *widget.WidgetNode,
    request: layout_context.Request,
    axes: Axes,
    options: Options,
    cache: []Natural,
    depth: usize,
    parent_display: style.Display,
    intrinsic: widget.Size,
    edges: Edges,
    stretch_cross: bool,
) sizing.Error!Natural {
    const preferred_size = try resolvePreferredSize(
        child.style,
        request.available,
        request.percentage_basis,
        intrinsic,
        edges,
    );
    const bounds = try resolveConstraintBounds(
        child.style,
        request.available,
        request.percentage_basis,
        intrinsic,
        edges,
    );
    const preferred_cross = if (axes.horizontal)
        preferred_size.height
    else
        preferred_size.width;
    const transferred_cross_min = if (axes.horizontal)
        bounds.transferred_min.height
    else
        bounds.transferred_min.width;
    const transferred_cross_max = if (axes.horizontal)
        bounds.transferred_max.height
    else
        bounds.transferred_max.width;
    const known_cross = if (preferred_cross) |cross|
        try clamp(
            cross,
            transferred_cross_min orelse 0,
            transferred_cross_max,
        )
    else if (stretch_cross)
        try clamp(
            if (axes.horizontal) request.available.height else request.available.width,
            transferred_cross_min orelse 0,
            transferred_cross_max,
        )
    else
        null;

    var min_request = request;
    min_request.sizing_mode = .content;
    min_request.known_border = .{ .width = null, .height = null };
    if (axes.horizontal) {
        min_request.width_mode = .min_content;
        min_request.percentage_basis.width = null;
        min_request.known_border.height = known_cross;
    } else {
        min_request.height_mode = .min_content;
        min_request.percentage_basis.height = null;
        min_request.known_border.width = known_cross;
    }
    return measureNode(
        tree,
        child_index,
        min_request,
        options,
        cache,
        depth,
        parent_display,
    );
}

fn measureLeaf(
    node: *const widget.WidgetNode,
    request: layout_context.Request,
    edges: Edges,
    measure: ?MeasureFn,
) sizing.Error!widget.Size {
    const font_size = try finite(node.font_size);
    if (font_size < 0) return error.InvalidStyle;
    const known_dimensions = try measureKnownDimensions(node.style, request, edges);
    const available_space: sizing.AvailableSize = .{
        .width = try measureAvailableSpace(
            node.style.size.width,
            known_dimensions.width,
            request.available.width,
            edges.horizontal,
            request.width_mode,
        ),
        .height = try measureAvailableSpace(
            node.style.size.height,
            known_dimensions.height,
            request.available.height,
            edges.vertical,
            request.height_mode,
        ),
    };
    var result: widget.Size = switch (node.kind) {
        .label => |label| try layout_context.measureText(measure, label.text, .{
            .known_dimensions = known_dimensions,
            .available_space = available_space,
            .font_size = font_size,
            .font_id = node.font_id,
        }, node.text_overflow, node.text_max_width),
        .spacer => |spacer| .{ .width = spacer.size, .height = spacer.size },
        .button => |button| .{
            .width = if (button.visual_label) |text|
                if (text.len == 0) 100 else try countToF32(text.len * 10 + 16)
            else
                100,
            .height = 32,
        },
        .slider => try layout_context.measureSliderContent(measure, node, .{
            .known_dimensions = known_dimensions,
            .available_space = available_space,
            .font_size = font_size,
            .font_id = node.font_id,
        }),
        .row, .column => .{ .width = 0, .height = 0 },
    };
    result.width = try nonNegative(result.width);
    result.height = try nonNegative(result.height);
    return result;
}

fn measureKnownDimensions(
    input: style.Style,
    request: layout_context.Request,
    edges: Edges,
) sizing.Error!sizing.OptionalSize {
    const content_sizing = request.sizing_mode == .content;
    const width_override = request.known_border.width != null;
    const height_override = request.known_border.height != null;
    var width = if (request.known_border.width) |border|
        try nonNegative(border)
    else if (content_sizing)
        null
    else
        try knownBorderDimension(
            input.size.width,
            .horizontal,
            input,
            request,
            edges,
        );
    var height = if (request.known_border.height) |border|
        try nonNegative(border)
    else if (content_sizing)
        null
    else
        try knownBorderDimension(
            input.size.height,
            .vertical,
            input,
            request,
            edges,
        );
    if (!content_sizing) {
        if (width) |value| {
            if (!width_override) {
                width = try clampSize(
                    input,
                    .horizontal,
                    value,
                    request.available,
                    request.percentage_basis,
                    .{ .width = 0, .height = 0 },
                    edges,
                );
            }
        }
        if (height) |value| {
            if (!height_override) {
                height = try clampSize(
                    input,
                    .vertical,
                    value,
                    request.available,
                    request.percentage_basis,
                    .{ .width = 0, .height = 0 },
                    edges,
                );
            }
        }
        if (input.aspect_ratio) |aspect_ratio| {
            const aspect = try ratio(aspect_ratio);
            if (width != null and height == null) {
                const sizing_width = try borderToSizing(
                    width.?,
                    edges.box_horizontal,
                    input.box_sizing,
                );
                height = try sizingToBorder(
                    try finite(sizing_width / aspect),
                    edges.box_vertical,
                    input.box_sizing,
                );
            } else if (height != null and width == null) {
                const sizing_height = try borderToSizing(
                    height.?,
                    edges.box_vertical,
                    input.box_sizing,
                );
                width = try sizingToBorder(
                    try finite(sizing_height * aspect),
                    edges.box_horizontal,
                    input.box_sizing,
                );
            }
        }
    }
    return .{
        .width = if (width) |value| @max(0, try finite(value - edges.horizontal)) else null,
        .height = if (height) |value| @max(0, try finite(value - edges.vertical)) else null,
    };
}

fn knownBorderDimension(
    dimension: style.Dimension,
    axis: PhysicalAxis,
    input: style.Style,
    request: layout_context.Request,
    edges: Edges,
) sizing.Error!?f32 {
    switch (dimension) {
        .auto, .min_content, .max_content, .fit_content => return null,
        .percent => {
            const basis = if (axis == .horizontal)
                request.percentage_basis.width
            else
                request.percentage_basis.height;
            if (basis == null) return null;
        },
        .length => {},
    }
    const containing = if (axis == .horizontal) request.available.width else request.available.height;
    const basis = if (axis == .horizontal)
        request.percentage_basis.width
    else
        request.percentage_basis.height;
    return resolveDimensionBorder(
        dimension,
        containing,
        basis,
        0,
        if (axis == .horizontal) edges.box_horizontal else edges.box_vertical,
        if (axis == .horizontal) edges.horizontal else edges.vertical,
        input.box_sizing,
    );
}

fn measureAvailableSpace(
    dimension: style.Dimension,
    known: ?f32,
    available_border: f32,
    edge_sum: f32,
    mode: layout_context.MeasureMode,
) sizing.Error!sizing.AvailableSpace {
    if (known) |value| {
        const definite = try nonNegative(value);
        return .{ .definite = definite };
    }
    const available_content = @max(0, try finite(available_border - edge_sum));
    return switch (dimension) {
        .min_content => .min_content,
        .max_content => .max_content,
        .fit_content => |limit| blk: {
            const definite = if (limit) |value|
                @min(available_content, try nonNegative(value))
            else
                available_content;
            break :blk .{ .definite = definite };
        },
        .auto, .length, .percent => switch (mode) {
            .definite => .{ .definite = available_content },
            .min_content => .min_content,
            .max_content => .max_content,
        },
    };
}

fn naturalBaseline(
    tree: *widget.WidgetTree,
    index: usize,
    request: layout_context.Request,
    natural: Natural,
    options: Options,
    cache: []Natural,
    depth: usize,
) sizing.Error!f32 {
    if (depth == 0) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    if (node.children.items.len == 0) return natural.border.height;

    const axes = axesFor(node.style);
    if (!axes.horizontal) return natural.border.height;

    const edges = try resolveEdges(node.style, request.percentage_basis.width);
    const content: widget.Size = .{
        .width = @max(0, try finite(natural.border.width - edges.horizontal)),
        .height = @max(0, try finite(natural.border.height - edges.vertical)),
    };
    for (node.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        const child = &tree.nodes.items[child_index];
        if (child.layout_hidden or child.style.position == .absolute) continue;
        const child_request = childNaturalRequest(request, node, child, content, .{
            .width = if (naturalAxisDefinite(
                node.style.size.width,
                request.width_mode,
                request.percentage_basis.width,
            )) @as(?f32, content.width) else null,
            .height = if (naturalAxisDefinite(
                node.style.size.height,
                request.height_mode,
                request.percentage_basis.height,
            )) @as(?f32, content.height) else null,
        });
        const child_natural = try measureNode(
            tree,
            child_index,
            child_request,
            options,
            cache,
            depth - 1,
            node.style.display,
        );
        const margins = try resolveMargins(child.style, child_request.percentage_basis.width);
        const border_padding_top = try add(edges.border.top, edges.padding.top);
        const child_baseline = try naturalBaseline(
            tree,
            child_index,
            child_request,
            child_natural,
            options,
            cache,
            depth - 1,
        );
        const margin_baseline = try add(margins.value.top, child_baseline);
        const baseline = try add(border_padding_top, margin_baseline);
        return baseline;
    }
    return natural.border.height;
}

fn measureContainerContent(
    tree: *widget.WidgetTree,
    index: usize,
    request: layout_context.Request,
    edges: Edges,
    options: Options,
    cache: []Natural,
    depth: usize,
) sizing.Error!widget.Size {
    const node = &tree.nodes.items[index];
    const axes = axesFor(node.style);
    const content_sizing = request.sizing_mode == .content;
    const preferred_width = if (content_sizing)
        null
    else
        try resolveDimensionBorder(
            node.style.size.width,
            request.available.width,
            request.percentage_basis.width,
            0,
            edges.box_horizontal,
            edges.horizontal,
            node.style.box_sizing,
        );
    const preferred_height = if (content_sizing)
        null
    else
        try resolveDimensionBorder(
            node.style.size.height,
            request.available.height,
            request.percentage_basis.height,
            0,
            edges.box_vertical,
            edges.vertical,
            node.style.box_sizing,
        );
    const minimum_width = if (content_sizing)
        0
    else
        (try resolveDimensionBorder(
            node.style.min_size.width,
            request.available.width,
            request.percentage_basis.width,
            0,
            edges.box_horizontal,
            edges.horizontal,
            node.style.box_sizing,
        )) orelse 0;
    const minimum_height = if (content_sizing)
        0
    else
        (try resolveDimensionBorder(
            node.style.min_size.height,
            request.available.height,
            request.percentage_basis.height,
            0,
            edges.box_vertical,
            edges.vertical,
            node.style.box_sizing,
        )) orelse 0;
    const maximum_width = if (content_sizing)
        null
    else
        try resolveDimensionBorder(
            node.style.max_size.width,
            request.available.width,
            request.percentage_basis.width,
            0,
            edges.box_horizontal,
            edges.horizontal,
            node.style.box_sizing,
        );
    const maximum_height = if (content_sizing)
        null
    else
        try resolveDimensionBorder(
            node.style.max_size.height,
            request.available.height,
            request.percentage_basis.height,
            0,
            edges.box_vertical,
            edges.vertical,
            node.style.box_sizing,
        );
    const measured_border: widget.Size = .{
        .width = if (request.known_border.width) |known|
            @max(try nonNegative(known), edges.horizontal)
        else if (content_sizing)
            try nonNegative(request.available.width)
        else
            try clamp(
                preferred_width orelse request.available.width,
                minimum_width,
                maximum_width,
            ),
        .height = if (request.known_border.height) |known|
            @max(try nonNegative(known), edges.vertical)
        else if (content_sizing)
            try nonNegative(request.available.height)
        else
            try clamp(
                preferred_height orelse request.available.height,
                minimum_height,
                maximum_height,
            ),
    };
    const available: widget.Size = .{
        .width = @max(0, measured_border.width - edges.horizontal),
        .height = @max(0, measured_border.height - edges.vertical),
    };
    const available_main = axisMain(axes, available);
    const main_gap_value = gapMainValue(node, axes);
    const cross_gap_value = if (axes.horizontal)
        selectAxisGap(node.style.row_gap, node.style.gap)
    else
        selectAxisGap(node.style.column_gap, node.style.gap);
    const main_gap_is_percentage = switch (main_gap_value) {
        .length => false,
        .percent => true,
    };
    const cross_gap_is_percentage = switch (cross_gap_value) {
        .length => false,
        .percent => true,
    };
    const width_definite_base = if (request.known_border.width != null)
        true
    else if (content_sizing)
        false
    else
        naturalAxisDefinite(
            node.style.size.width,
            request.width_mode,
            request.percentage_basis.width,
        );
    const height_definite_base = if (request.known_border.height != null)
        true
    else if (content_sizing)
        false
    else
        naturalAxisDefinite(
            node.style.size.height,
            request.height_mode,
            request.percentage_basis.height,
        );
    const width_definite = width_definite_base and
        !(request.known_border.width == null and
            dimensionAuto(node.style.size.width) and
            ((!axes.horizontal and cross_gap_is_percentage) or
                (axes.horizontal and main_gap_is_percentage)));
    const height_definite = height_definite_base and
        !(request.known_border.height == null and
            dimensionAuto(node.style.size.height) and
            ((axes.horizontal and cross_gap_is_percentage) or
                (!axes.horizontal and main_gap_is_percentage)));
    const gap_basis: style.Size(?f32) = .{
        .width = if (width_definite) available.width else null,
        .height = if (height_definite) available.height else null,
    };
    const main_gap = try resolveGap(
        main_gap_value,
        if (axes.horizontal) gap_basis.width else gap_basis.height,
    );
    const cross_gap = try resolveGap(
        cross_gap_value,
        if (axes.horizontal) gap_basis.height else gap_basis.width,
    );
    const main_dimension = if (axes.horizontal)
        node.style.size.width
    else
        node.style.size.height;
    const main_known = if (axes.horizontal)
        request.known_border.width
    else
        request.known_border.height;
    const main_mode = if (axes.horizontal) request.width_mode else request.height_mode;
    const auto_main = if (content_sizing and main_known == null)
        true
    else
        dimensionAuto(main_dimension);
    const intrinsic_main = if (content_sizing and main_known == null)
        true
    else
        auto_main and main_mode != .definite;
    const main_percentage_basis = if (axes.horizontal)
        request.percentage_basis.width
    else
        request.percentage_basis.height;
    const main_definite = if (main_known != null)
        true
    else if (content_sizing)
        false
    else
        naturalAxisDefinite(
            main_dimension,
            main_mode,
            main_percentage_basis,
        );
    const main_edge_sum = if (axes.horizontal) edges.horizontal else edges.vertical;
    const minimum_main_border = if (content_sizing)
        0
    else if (axes.horizontal)
        minimum_width
    else
        minimum_height;
    const minimum_main_content = @max(
        0,
        try finite(minimum_main_border - main_edge_sum),
    );
    const maximum_main_dimension = if (axes.horizontal)
        node.style.max_size.width
    else
        node.style.max_size.height;
    const maximum_main_border = if (axes.horizontal) maximum_width else maximum_height;
    const maximum_main_content: ?f32 = if (content_sizing or
        dimensionNeedsIntrinsicMeasurement(
            maximum_main_dimension,
            main_percentage_basis,
        ))
        null
    else
        @max(
            minimum_main_content,
            @max(0, try finite((maximum_main_border orelse 0) - main_edge_sum)),
        );
    const line_mode: layout_context.MeasureMode = if (main_definite or
        maximum_main_content != null)
        .definite
    else
        main_mode;
    const line_capacity = if (maximum_main_content) |maximum|
        @max(
            if (main_definite) available_main else maximum,
            minimum_main_content,
        )
    else
        available_main;
    var line_main: f32 = 0;
    var line_cross: f32 = 0;
    var line_max_baseline: f32 = 0;
    var line_max_descent: f32 = 0;
    var line_baseline_count: usize = 0;
    var total_main: f32 = 0;
    var total_cross: f32 = 0;
    var unwrapped_main: f32 = 0;
    var line_items: usize = 0;
    var line_count: usize = 0;

    for (node.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        const child = &tree.nodes.items[child_index];
        if (child.layout_hidden or child.style.position == .absolute) continue;
        const child_edges = try resolveEdges(
            child.style,
            gap_basis.width,
        );
        const child_bounds = try resolveConstraintBounds(
            child.style,
            available,
            gap_basis,
            .{ .width = 0, .height = 0 },
            child_edges,
        );
        const child_cross_min_opt = if (axes.horizontal)
            child_bounds.transferred_min.height
        else
            child_bounds.transferred_min.width;
        const child_cross_max_opt = if (axes.horizontal)
            child_bounds.transferred_max.height
        else
            child_bounds.transferred_max.width;
        const child_style_cross_min_opt = if (axes.horizontal)
            child_bounds.style_min.height
        else
            child_bounds.style_min.width;
        const child_style_cross_max_opt = if (axes.horizontal)
            child_bounds.style_max.height
        else
            child_bounds.style_max.width;
        const child_cross_min = child_cross_min_opt orelse 0;
        const child_cross_max = child_cross_max_opt;
        const margins = try resolveMargins(child.style, gap_basis.width);
        var child_available = available;
        const child_cross_floor = if (axes.horizontal)
            child_edges.box_vertical
        else
            child_edges.box_horizontal;
        if (axes.horizontal)
            child_available.height = @max(
                child_cross_floor,
                try clamp(
                    @max(
                        0,
                        try finite(
                            available.height - margins.value.top - margins.value.bottom,
                        ),
                    ),
                    child_cross_min,
                    child_cross_max,
                ),
            )
        else
            child_available.width = @max(
                child_cross_floor,
                try clamp(
                    @max(
                        0,
                        try finite(
                            available.width - margins.value.left - margins.value.right,
                        ),
                    ),
                    child_cross_min,
                    child_cross_max,
                ),
            );
        var child_request = childNaturalRequest(request, node, child, child_available, gap_basis);
        const parent_cross_mode = if (axes.horizontal) request.height_mode else request.width_mode;
        if (axes.horizontal) {
            child_request.height_mode = switch (parent_cross_mode) {
                .min_content => if (child_cross_min_opt != null) .definite else child_request.height_mode,
                .max_content => if (child_cross_max_opt != null) .definite else child_request.height_mode,
                .definite => .definite,
            };
        } else {
            child_request.width_mode = switch (parent_cross_mode) {
                .min_content => if (child_cross_min_opt != null) .definite else child_request.width_mode,
                .max_content => if (child_cross_max_opt != null) .definite else child_request.width_mode,
                .definite => .definite,
            };
        }
        const natural = try measureNode(
            tree,
            child_index,
            child_request,
            options,
            cache,
            depth,
            node.style.display,
        );
        const contribution_natural = if (intrinsic_main and
            (child_style_cross_min_opt != child_cross_min_opt or
                child_style_cross_max_opt != child_cross_max_opt))
        blk: {
            var contribution_available = available;
            if (axes.horizontal) {
                contribution_available.height = @max(
                    child_cross_floor,
                    try clamp(
                        @max(
                            0,
                            try finite(
                                available.height - margins.value.top - margins.value.bottom,
                            ),
                        ),
                        child_style_cross_min_opt orelse 0,
                        child_style_cross_max_opt,
                    ),
                );
            } else {
                contribution_available.width = @max(
                    child_cross_floor,
                    try clamp(
                        @max(
                            0,
                            try finite(
                                available.width - margins.value.left - margins.value.right,
                            ),
                        ),
                        child_style_cross_min_opt orelse 0,
                        child_style_cross_max_opt,
                    ),
                );
            }
            var contribution_request = childNaturalRequest(
                request,
                node,
                child,
                contribution_available,
                gap_basis,
            );
            if (axes.horizontal) {
                contribution_request.height_mode = switch (parent_cross_mode) {
                    .min_content => if (child_style_cross_min_opt != null)
                        .definite
                    else
                        contribution_request.height_mode,
                    .max_content => if (child_style_cross_max_opt != null)
                        .definite
                    else
                        contribution_request.height_mode,
                    .definite => .definite,
                };
            } else {
                contribution_request.width_mode = switch (parent_cross_mode) {
                    .min_content => if (child_style_cross_min_opt != null)
                        .definite
                    else
                        contribution_request.width_mode,
                    .max_content => if (child_style_cross_max_opt != null)
                        .definite
                    else
                        contribution_request.width_mode,
                    .definite => .definite,
                };
            }
            break :blk try measureNode(
                tree,
                child_index,
                contribution_request,
                options,
                cache,
                depth,
                node.style.display,
            );
        } else natural;
        const minimum_main_dimension = if (axes.horizontal)
            child.style.min_size.width
        else
            child.style.min_size.height;
        const minimum_main_overflow = if (axes.horizontal)
            child.style.overflow.width
        else
            child.style.overflow.height;
        const preserves_automatic_minimum = switch (minimum_main_overflow) {
            .visible, .clip => true,
            .hidden, .scroll, .auto => false,
        };
        const alignment = alignValue(
            child.style.align_self,
            node.style.@"align",
            child.style.writing_direction == node.style.writing_direction,
            !axes.horizontal,
        );
        const child_cross_mode = if (axes.horizontal)
            child_request.height_mode
        else
            child_request.width_mode;
        const stretch_cross = alignment == .stretch and
            !crossStartAuto(axes, margins) and
            !crossEndAuto(axes, margins) and
            child_cross_mode == .definite;
        const min_natural = if (dimensionAuto(minimum_main_dimension) and
            preserves_automatic_minimum)
            try measureAutomaticMinimum(
                tree,
                child_index,
                child,
                child_request,
                axes,
                options,
                cache,
                depth,
                node.style.display,
                natural.content,
                child_edges,
                stretch_cross,
            )
        else
            natural;
        const preferred_size = try resolvePreferredSize(
            child.style,
            child_request.available,
            child_request.percentage_basis,
            contribution_natural.content,
            child_edges,
        );
        const preferred_main = if (axes.horizontal)
            preferred_size.width
        else
            preferred_size.height;
        const child_constraints = try constraintsFor(
            child.style,
            child_request.available,
            child_request.percentage_basis,
            natural.content,
            min_natural,
            child_edges,
            axes,
            preferred_main,
        );
        const base_preferred = try flexBaseSize(
            child.style,
            child_request.available,
            child_request.percentage_basis,
            natural.content,
            child_edges,
        );
        const child_basis = try flexBasis(
            child.style,
            axes,
            available_main,
            if (axes.horizontal)
                child_request.percentage_basis.width
            else
                child_request.percentage_basis.height,
            axisMain(axes, base_preferred),
            natural,
            child_edges,
        );
        const explicit_main_min = child_constraints.style.main.min orelse 0;
        const explicit_main_max = child_constraints.style.main.max;
        const explicit_basis = switch (child.style.flex_basis) {
            .auto => false,
            else => true,
        };
        const clamping_basis = if (preferred_main) |preferred|
            @max(child_basis, preferred)
        else
            child_basis;
        var contribution_min = @max(
            child_constraints.style.main.min orelse 0,
            child_constraints.minimum_main,
        );
        if (try nonNegative(child.style.shrink) == 0) {
            contribution_min = @max(contribution_min, clamping_basis);
        }
        var contribution_max = if (explicit_basis)
            explicit_main_max
        else
            child_constraints.style.main.max;
        if (try nonNegative(child.style.grow) == 0) {
            contribution_max = if (contribution_max) |maximum|
                @min(maximum, clamping_basis)
            else
                clamping_basis;
        }
        const main_overflow = if (axes.horizontal)
            child.style.overflow.width
        else
            child.style.overflow.height;
        const is_scroll_container = switch (main_overflow) {
            .hidden, .scroll, .auto => true,
            .visible, .clip => false,
        };
        const contribution_border = if (intrinsic_main)
            contribution_natural.border
        else
            natural.border;
        const inherent_main = axisMain(axes, contribution_border);
        const contribution_candidate = if (is_scroll_container)
            child_basis
        else if (!axes.horizontal and explicit_basis and explicit_main_min > child_basis)
            explicit_main_min
        else if (axes.horizontal)
            inherent_main
        else
            @max(inherent_main, child_basis);
        const main_contribution = try clamp(
            contribution_candidate,
            contribution_min,
            contribution_max,
        );

        const outer_main = try add(
            try add(main_contribution, marginStart(axes, margins)),
            marginEnd(axes, margins),
        );
        const outer_cross = try add(
            try add(axisCross(axes, natural.border), crossStart(axes, margins)),
            crossEnd(axes, margins),
        );
        const candidate = if (line_items == 0)
            outer_main
        else
            try add(try add(line_main, main_gap), outer_main);
        unwrapped_main = if (line_items == 0)
            outer_main
        else
            try add(try add(unwrapped_main, main_gap), outer_main);
        const should_wrap = node.style.flex_wrap != .nowrap and
            line_items != 0 and
            switch (line_mode) {
                .max_content => false,
                .min_content => true,
                .definite => candidate > line_capacity,
            };
        if (should_wrap) {
            total_main = @max(total_main, line_main);
            if (line_count != 0) total_cross = try add(total_cross, cross_gap);
            const completed_cross = if (axes.horizontal and line_baseline_count > 1)
                @max(line_cross, try add(line_max_baseline, line_max_descent))
            else
                line_cross;
            total_cross = try add(total_cross, completed_cross);
            line_count += 1;
            line_main = outer_main;
            line_cross = outer_cross;
            line_max_baseline = 0;
            line_max_descent = 0;
            line_baseline_count = 0;
            line_items = 1;
        } else {
            line_main = candidate;
            line_cross = @max(line_cross, outer_cross);
            line_items += 1;
        }
        const baseline = if (axes.horizontal and
            alignment == .baseline and
            !crossStartAuto(axes, margins) and
            !crossEndAuto(axes, margins))
            try naturalBaseline(
                tree,
                child_index,
                child_request,
                natural,
                options,
                cache,
                depth,
            )
        else
            0;
        if (baseline != 0 or (axes.horizontal and alignment == .baseline)) {
            const ascent = try add(margins.value.top, baseline);
            const descent = @max(
                0,
                try finite(margins.value.bottom + axisCross(axes, natural.border) - baseline),
            );
            line_max_baseline = @max(line_max_baseline, ascent);
            line_max_descent = @max(line_max_descent, descent);
            line_baseline_count += 1;
        }
    }
    if (line_items != 0) {
        total_main = @max(total_main, line_main);
        if (line_count != 0) total_cross = try add(total_cross, cross_gap);
        const completed_cross = if (axes.horizontal and line_baseline_count > 1)
            @max(line_cross, try add(line_max_baseline, line_max_descent))
        else
            line_cross;
        total_cross = try add(total_cross, completed_cross);
    }
    const content_main = if (node.style.flex_wrap != .nowrap and auto_main)
        if (line_mode == .min_content)
            total_main
        else if (intrinsic_main)
            unwrapped_main
        else
            @min(unwrapped_main, line_capacity)
    else
        total_main;
    return fromAxes(axes, content_main, total_cross);
}

fn layoutFlex(
    tree: *widget.WidgetTree,
    index: usize,
    containing: widget.Size,
    border_size: widget.Size,
    size_forced: bool,
    options: Options,
    cache: []Natural,
    depth: usize,
) sizing.Error!void {
    if (depth == 0) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    node.first_baseline = null;
    if (node.layout_hidden) return;
    if (node.style.display != .flex) return error.InvalidStyle;
    const edges = try clampEdges(
        try resolveEdges(node.style, containing.width),
        border_size,
    );
    node.resolved_box_edges = .{ .border = edges.border, .padding = edges.padding };
    node.rect.w = try nonNegative(border_size.width);
    node.rect.h = try nonNegative(border_size.height);
    const pad_box: widget.Size = .{
        .width = @max(
            0,
            try finite(node.rect.w - edges.border.left - edges.border.right),
        ),
        .height = @max(
            0,
            try finite(node.rect.h - edges.border.top - edges.border.bottom),
        ),
    };
    const content: widget.Size = .{
        .width = @max(
            0,
            try finite(pad_box.width - edges.padding.left - edges.padding.right),
        ),
        .height = @max(
            0,
            try finite(pad_box.height - edges.padding.top - edges.padding.bottom),
        ),
    };
    const axes = axesFor(node.style);
    const main_size = axisMain(axes, content);
    const cross_size = axisCross(axes, content);
    const cross_dimension = if (axes.horizontal)
        node.style.size.height
    else
        node.style.size.width;
    const cross_mode: layout_context.MeasureMode = if (axes.horizontal)
        if (options.intrinsic_height) .max_content else .definite
    else if (options.intrinsic_width) .max_content else .definite;
    const cross_definite = size_forced or naturalAxisDefinite(
        cross_dimension,
        cross_mode,
        if (axes.horizontal) containing.height else containing.width,
    );
    const main_dimension = if (axes.horizontal)
        node.style.size.width
    else
        node.style.size.height;
    const main_intrinsic = if (axes.horizontal)
        options.intrinsic_width
    else
        options.intrinsic_height;
    const main_gap_value = gapMainValue(node, axes);
    const main_gap_is_percentage = switch (main_gap_value) {
        .length => false,
        .percent => true,
    };
    const main_gap = try resolveGap(main_gap_value, main_size);
    // Intrinsic auto main sizing treats percentage gaps as zero. Preserve those
    // lines and flex sizes when the final percentage basis becomes definite.
    const cyclic_wrapped_main_gap = !size_forced and
        main_intrinsic and
        dimensionAuto(main_dimension) and
        node.style.flex_wrap != .nowrap and
        main_gap_is_percentage;
    const line_gap = if (cyclic_wrapped_main_gap) 0 else main_gap;
    // A percentage cross gap is cyclic while the cross dimension is auto.
    // Forced item geometry does not make that container dimension definite.
    const cross_gap = try gapCross(
        node,
        axes,
        if (cross_definite and !dimensionAuto(cross_dimension))
            @as(?f32, cross_size)
        else
            null,
    );

    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(options.allocator);
    try collectItems(
        tree,
        node,
        axes,
        content,
        options,
        cache,
        &items,
        depth - 1,
    );
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(options.allocator);
    try makeLines(
        options.allocator,
        &lines,
        items.items,
        node.style.flex_wrap,
        main_size,
        line_gap,
    );
    for (lines.items) |line| {
        try resolveLine(
            items.items[line.start .. line.start + line.count],
            main_size,
            line_gap,
        );
    }
    if (options.context) |context| {
        for (items.items) |*item| {
            const child = &tree.nodes.items[item.index];
            if (child.children.items.len == 0 or child.style.display == .flex) continue;
            const remeasure_available: widget.Size = if (axes.horizontal)
                .{ .width = item.target, .height = cross_size }
            else
                .{ .width = cross_size, .height = item.target };
            const measured = try context.measure_node(
                context,
                tree,
                child,
                .{
                    .available = remeasure_available,
                    .percentage_basis = .{
                        .width = remeasure_available.width,
                        .height = remeasure_available.height,
                    },
                    .width_mode = .definite,
                    .height_mode = .definite,
                },
            );
            item.cross = try clamp(
                axisCross(axes, measured.border),
                item.hypothetical_cross_min,
                item.hypothetical_cross_max,
            );
        }
    }
    for (items.items) |*item| {
        const child = &tree.nodes.items[item.index];
        child.first_baseline = null;
        if (!item.baseline_participates) continue;

        const child_border = if (axes.horizontal)
            widget.Size{ .width = item.target, .height = item.cross }
        else
            widget.Size{ .width = item.cross, .height = item.target };
        if (child.children.items.len == 0) {
            child.first_baseline = child_border.height;
        } else if (child.style.display == .flex) {
            try layoutFlex(
                tree,
                item.index,
                content,
                child_border,
                true,
                options,
                cache,
                depth - 1,
            );
        } else if (options.context) |context| {
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
                    .border = child_border,
                },
            );
        } else {
            return error.InvalidStyle;
        }
        if (child.children.items.len != 0) item.laid_out = true;
        item.baseline = baselineForItem(child, child_border);
    }
    try lineCrossSizes(
        lines.items,
        items.items,
        cross_size,
        cross_gap,
        axes,
        node.style.flex_wrap == .nowrap and cross_definite,
    );
    try lineDistribution(
        lines.items,
        node.style.align_content,
        cross_size,
        cross_gap,
        axes.cross_reverse,
        !axes.horizontal and node.style.writing_direction == .rtl,
    );
    try placeItems(
        tree,
        node,
        axes,
        content,
        lines.items,
        items.items,
        main_gap,
    );

    for (items.items) |*item| {
        const child = &tree.nodes.items[item.index];
        if (item.laid_out) continue;
        if (options.context) |context| {
            if (child.children.items.len == 0 or child.style.display != .flex) {
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
                        .border = .{
                            .width = child.rect.w,
                            .height = child.rect.h,
                        },
                    },
                );
                item.laid_out = true;
                continue;
            }
        }
        if (child.children.items.len == 0) {
            item.laid_out = true;
            continue;
        }
        try layoutFlex(
            tree,
            item.index,
            content,
            .{ .width = child.rect.w, .height = child.rect.h },
            true,
            options,
            cache,
            depth - 1,
        );
        item.laid_out = true;
    }
    if (lines.items.len != 0) {
        const selected_index = if (node.style.flex_wrap == .wrap_reverse)
            lines.items.len - 1
        else
            0;
        const selected_line = lines.items[selected_index];
        var donor: ?*const Item = null;
        if (axes.horizontal) {
            const selected_items = items.items[selected_line.start .. selected_line.start + selected_line.count];
            for (selected_items) |*item| {
                if (item.baseline_participates) {
                    donor = item;
                    break;
                }
            }
        }
        if (donor == null and selected_line.count != 0) {
            donor = &items.items[selected_line.start];
        }
        if (donor) |item| {
            const child = &tree.nodes.items[item.index];
            const child_baseline = child.first_baseline orelse child.rect.h;
            node.first_baseline = try add(
                try add(edges.border.top, edges.padding.top),
                try add(child.rect.y, child_baseline),
            );
        }
    }
    try placeAbsolute(tree, node, content, pad_box, edges, options, cache, depth - 1);
    try publishContentSize(tree, node, pad_box, edges);
}

fn flexItemCrossAvailable(
    input: style.Style,
    axes: Axes,
    available: widget.Size,
    percentage_basis: style.Size(?f32),
    edges: Edges,
    margins: Margins,
) sizing.Error!f32 {
    const bounds = try resolveConstraintBounds(
        input,
        available,
        percentage_basis,
        .{ .width = 0, .height = 0 },
        edges,
    );
    const minimum = if (axes.horizontal)
        bounds.transferred_min.height orelse 0
    else
        bounds.transferred_min.width orelse 0;
    const maximum = if (axes.horizontal)
        bounds.transferred_max.height
    else
        bounds.transferred_max.width;
    const margin_cross_start = if (crossStartAuto(axes, margins))
        0
    else
        crossStart(axes, margins);
    const margin_cross_end = if (crossEndAuto(axes, margins))
        0
    else
        crossEnd(axes, margins);
    const margin_sum = try add(margin_cross_start, margin_cross_end);
    const available_cross = axisCross(axes, available);
    const cross_floor = if (axes.horizontal) edges.box_vertical else edges.box_horizontal;
    return @max(
        cross_floor,
        try clamp(
            @max(0, try finite(available_cross - margin_sum)),
            minimum,
            maximum,
        ),
    );
}

fn collectItems(
    tree: *widget.WidgetTree,
    container: *const widget.WidgetNode,
    axes: Axes,
    content: widget.Size,
    options: Options,
    cache: []Natural,
    items: *std.ArrayList(Item),
    depth: usize,
) sizing.Error!void {
    const main_content = axisMain(axes, content);
    const request = concreteRequest(content);
    for (container.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        const child = &tree.nodes.items[child_index];
        if (child.layout_hidden or child.style.position == .absolute) continue;
        const alignment = alignValue(
            child.style.align_self,
            container.style.@"align",
            child.style.writing_direction == container.style.writing_direction,
            !axes.horizontal,
        );
        const edges = try resolveEdges(child.style, request.percentage_basis.width);
        child.resolved_box_edges = .{ .border = edges.border, .padding = edges.padding };
        const margins = try resolveMargins(child.style, content.width);
        var natural_request = request;
        const cross_bounds = try resolveConstraintBounds(
            child.style,
            content,
            request.percentage_basis,
            .{ .width = 0, .height = 0 },
            edges,
        );
        const natural_cross_min = if (axes.horizontal)
            cross_bounds.transferred_min.height
        else
            cross_bounds.transferred_min.width;
        const natural_cross_max = if (axes.horizontal)
            cross_bounds.transferred_max.height
        else
            cross_bounds.transferred_max.width;
        const natural_cross_available = try flexItemCrossAvailable(
            child.style,
            axes,
            content,
            request.percentage_basis,
            edges,
            margins,
        );
        const parent_cross_mode = if (axes.horizontal) request.height_mode else request.width_mode;
        const natural_cross_mode: layout_context.MeasureMode = switch (parent_cross_mode) {
            .min_content => if (natural_cross_min != null) .definite else .min_content,
            .max_content => if (natural_cross_max != null) .definite else .max_content,
            .definite => .definite,
        };
        if (axes.horizontal) {
            natural_request.available.height = natural_cross_available;
            natural_request.height_mode = natural_cross_mode;
        } else {
            natural_request.available.width = natural_cross_available;
            natural_request.width_mode = natural_cross_mode;
        }
        const natural = try measureNode(
            tree,
            child_index,
            natural_request,
            options,
            cache,
            depth,
            container.style.display,
        );
        const main_dimension = if (axes.horizontal)
            child.style.size.width
        else
            child.style.size.height;
        const main_percentage_basis = if (axes.horizontal)
            request.percentage_basis.width
        else
            request.percentage_basis.height;
        const base_natural = if (child.style.flex_basis != .auto or
            !dimensionNeedsIntrinsicMeasurement(main_dimension, main_percentage_basis))
            natural
        else blk: {
            var base_request = natural_request;
            const parent_main_min_content = if (axes.horizontal)
                request.width_mode == .min_content
            else
                request.height_mode == .min_content;
            const base_main_mode: layout_context.MeasureMode = if (parent_main_min_content)
                .min_content
            else
                .max_content;
            if (axes.horizontal) {
                base_request.width_mode = base_main_mode;
                base_request.percentage_basis.width = null;
            } else {
                base_request.height_mode = base_main_mode;
                base_request.percentage_basis.height = null;
            }
            break :blk try measureNode(
                tree,
                child_index,
                base_request,
                options,
                cache,
                depth,
                container.style.display,
            );
        };
        const preferred = try usedSize(
            child.style,
            request.available,
            request.percentage_basis,
            natural.content,
            edges,
            null,
        );
        const base_preferred = try flexBaseSize(
            child.style,
            request.available,
            request.percentage_basis,
            base_natural.content,
            edges,
        );
        const main_min_dimension = if (axes.horizontal)
            child.style.min_size.width
        else
            child.style.min_size.height;
        const main_overflow = if (axes.horizontal)
            child.style.overflow.width
        else
            child.style.overflow.height;
        const preserves_automatic_minimum = switch (main_overflow) {
            .visible, .clip => true,
            .hidden, .scroll, .auto => false,
        };
        const stretch_cross = alignment == .stretch and
            !crossStartAuto(axes, margins) and
            !crossEndAuto(axes, margins) and
            natural_cross_mode == .definite;
        const min_natural = if (dimensionAuto(main_min_dimension) and
            preserves_automatic_minimum)
            try measureAutomaticMinimum(
                tree,
                child_index,
                child,
                natural_request,
                axes,
                options,
                cache,
                depth,
                container.style.display,
                natural.content,
                edges,
                stretch_cross,
            )
        else
            natural;
        const preferred_size = try resolvePreferredSize(
            child.style,
            request.available,
            request.percentage_basis,
            natural.content,
            edges,
        );
        const preferred_main = if (axes.horizontal)
            preferred_size.width
        else
            preferred_size.height;
        const constraints = try constraintsFor(
            child.style,
            request.available,
            request.percentage_basis,
            natural.content,
            min_natural,
            edges,
            axes,
            preferred_main,
        );
        const basis = try flexBasis(
            child.style,
            axes,
            main_content,
            if (axes.horizontal)
                request.percentage_basis.width
            else
                request.percentage_basis.height,
            axisMain(axes, base_preferred),
            base_natural,
            edges,
        );
        const baseline_participates = axes.horizontal and
            alignment == .baseline and
            !crossStartAuto(axes, margins) and
            !crossEndAuto(axes, margins);
        const box_edge_sum = if (axes.horizontal) edges.box_horizontal else edges.box_vertical;
        const inner_flex_basis = @max(0, try finite(basis - box_edge_sum));
        const hypothetical_main_min = @max(
            @max(
                constraints.style.main.min orelse 0,
                constraints.minimum_main,
            ),
            constraints.transferred.main.min orelse 0,
        );
        const hypothetical_main_max = constraints.transferred.main.max;
        const cross_floor = if (axes.horizontal) edges.box_vertical else edges.box_horizontal;
        const hypothetical_cross_min = @max(
            @max(
                cross_floor,
                constraints.style.cross.min orelse 0,
            ),
            constraints.transferred.cross.min orelse 0,
        );
        const hypothetical_cross_max = constraints.transferred.cross.max;
        const hypothetical_main = @max(
            box_edge_sum,
            try clamp(
                try flexBasis(
                    child.style,
                    axes,
                    main_content,
                    if (axes.horizontal)
                        request.percentage_basis.width
                    else
                        request.percentage_basis.height,
                    axisMain(axes, base_preferred),
                    natural,
                    edges,
                ),
                hypothetical_main_min,
                hypothetical_main_max,
            ),
        );

        const item: Item = .{
            .index = child_index,
            .flex_basis = basis,
            .inner_flex_basis = inner_flex_basis,
            .hypothetical_main = hypothetical_main,
            .hypothetical_outer = try add(
                try add(hypothetical_main, marginStart(axes, margins)),
                marginEnd(axes, margins),
            ),
            .target = basis,
            .provisional = basis,
            .violation = 0,
            .main_floor = box_edge_sum,
            .cross = @max(
                cross_floor,
                try clamp(
                    axisCross(axes, preferred),
                    hypothetical_cross_min,
                    hypothetical_cross_max,
                ),
            ),
            .main_min = @max(constraints.style.main.min orelse 0, constraints.minimum_main),
            .main_max = constraints.style.main.max,
            .cross_min = @max(cross_floor, constraints.style.cross.min orelse 0),
            .cross_max = constraints.style.cross.max,
            .hypothetical_cross_min = hypothetical_cross_min,
            .hypothetical_cross_max = hypothetical_cross_max,
            .margin_start = marginStart(axes, margins),
            .margin_end = marginEnd(axes, margins),
            .cross_margin_start = crossStart(axes, margins),
            .cross_margin_end = crossEnd(axes, margins),
            .main_start_auto = marginStartAuto(axes, margins),
            .main_end_auto = marginEndAuto(axes, margins),
            .cross_start_auto = crossStartAuto(axes, margins),
            .cross_end_auto = crossEndAuto(axes, margins),
            .cross_auto = dimensionAuto(if (axes.horizontal)
                child.style.size.height
            else
                child.style.size.width),
            .grow = try nonNegative(child.style.grow),
            .shrink = try nonNegative(child.style.shrink),
            .frozen = false,
            .baseline = 0,
            .baseline_participates = baseline_participates,
            .physical_top_margin = margins.value.top,
            .physical_bottom_margin = margins.value.bottom,
            .laid_out = false,
        };
        try items.append(options.allocator, item);
    }
}

const PhysicalConstraintBounds = struct {
    style_min: style.Size(?f32),
    style_max: style.Size(?f32),
    transferred_min: style.Size(?f32),
    transferred_max: style.Size(?f32),
};
fn resolvePreferredSize(
    input: style.Style,
    containing: widget.Size,
    percentage_basis: style.Size(?f32),
    intrinsic: widget.Size,
    edges: Edges,
) sizing.Error!style.Size(?f32) {
    var width = try dimensionValue(
        input.size.width,
        containing.width,
        percentage_basis.width,
        intrinsic.width,
    );
    var height = try dimensionValue(
        input.size.height,
        containing.height,
        percentage_basis.height,
        intrinsic.height,
    );
    if (input.aspect_ratio) |aspect| {
        const ratio_value = try ratio(aspect);
        if (width == null and height != null) {
            width = try finite(height.? * ratio_value);
        } else if (height == null and width != null) {
            height = try finite(width.? / ratio_value);
        }
    }
    const width_adjustment = if (input.box_sizing == .content_box) edges.box_horizontal else 0;
    const height_adjustment = if (input.box_sizing == .content_box) edges.box_vertical else 0;
    return .{
        .width = if (width) |value|
            try add(try nonNegative(value), width_adjustment)
        else
            null,
        .height = if (height) |value|
            try add(try nonNegative(value), height_adjustment)
        else
            null,
    };
}

fn resolveConstraintDimension(
    dimension: style.Dimension,
    containing: f32,
    percentage_basis: ?f32,
    intrinsic: f32,
    box_edges: f32,
    box_sizing: style.BoxSizing,
) sizing.Error!?f32 {
    const value = try dimensionValue(dimension, containing, percentage_basis, intrinsic);
    if (value) |number| {
        const non_negative = try nonNegative(number);
        const adjustment = if (box_sizing == .content_box) box_edges else 0;
        const adjusted = try add(non_negative, adjustment);
        return adjusted;
    }
    return null;
}

fn resolveConstraintBounds(
    input: style.Style,
    containing: widget.Size,
    percentage_basis: style.Size(?f32),
    intrinsic: widget.Size,
    edges: Edges,
) sizing.Error!PhysicalConstraintBounds {
    const style_min: style.Size(?f32) = .{
        .width = try resolveConstraintDimension(
            input.min_size.width,
            containing.width,
            percentage_basis.width,
            intrinsic.width,
            edges.box_horizontal,
            input.box_sizing,
        ),
        .height = try resolveConstraintDimension(
            input.min_size.height,
            containing.height,
            percentage_basis.height,
            intrinsic.height,
            edges.box_vertical,
            input.box_sizing,
        ),
    };
    const style_max: style.Size(?f32) = .{
        .width = try resolveConstraintDimension(
            input.max_size.width,
            containing.width,
            percentage_basis.width,
            intrinsic.width,
            edges.box_horizontal,
            input.box_sizing,
        ),
        .height = try resolveConstraintDimension(
            input.max_size.height,
            containing.height,
            percentage_basis.height,
            intrinsic.height,
            edges.box_vertical,
            input.box_sizing,
        ),
    };
    return .{
        .style_min = style_min,
        .style_max = style_max,
        .transferred_min = try applyAspectRatioToBounds(style_min, input.aspect_ratio),
        .transferred_max = try applyAspectRatioToBounds(style_max, input.aspect_ratio),
    };
}

fn applyAspectRatioToBounds(
    value: style.Size(?f32),
    aspect_ratio: ?f32,
) sizing.Error!style.Size(?f32) {
    const aspect = if (aspect_ratio) |ratio_value| try ratio(ratio_value) else return value;
    if (value.width == null and value.height != null) {
        return .{
            .width = try finite(value.height.? * aspect),
            .height = value.height,
        };
    }
    if (value.width != null and value.height == null) {
        return .{
            .width = value.width,
            .height = try finite(value.width.? / aspect),
        };
    }
    return value;
}

fn axisConstraints(
    bounds: PhysicalConstraintBounds,
    axes: Axes,
    transferred: bool,
) AxisConstraints {
    const minimum = if (transferred) bounds.transferred_min else bounds.style_min;
    const maximum = if (transferred) bounds.transferred_max else bounds.style_max;
    if (axes.horizontal) {
        return .{ .min = minimum.width, .max = maximum.width };
    }
    return .{ .min = minimum.height, .max = maximum.height };
}

fn constraintsFor(
    input: style.Style,
    containing: widget.Size,
    percentage_basis: style.Size(?f32),
    intrinsic: widget.Size,
    min_natural: Natural,
    edges: Edges,
    axes: Axes,
    preferred_main: ?f32,
) sizing.Error!ResolvedConstraints {
    const bounds = try resolveConstraintBounds(
        input,
        containing,
        percentage_basis,
        intrinsic,
        edges,
    );
    const style_constraints: Constraints = .{
        .main = axisConstraints(bounds, axes, false),
        .cross = if (axes.horizontal)
            .{ .min = bounds.style_min.height, .max = bounds.style_max.height }
        else
            .{ .min = bounds.style_min.width, .max = bounds.style_max.width },
    };
    const transferred_constraints: Constraints = .{
        .main = axisConstraints(bounds, axes, true),
        .cross = if (axes.horizontal)
            .{ .min = bounds.transferred_min.height, .max = bounds.transferred_max.height }
        else
            .{ .min = bounds.transferred_min.width, .max = bounds.transferred_max.width },
    };
    const main_min_dimension = if (axes.horizontal) input.min_size.width else input.min_size.height;
    const main_overflow = if (axes.horizontal) input.overflow.width else input.overflow.height;
    const preserves_automatic_minimum = switch (main_overflow) {
        .visible, .clip => true,
        .hidden, .scroll, .auto => false,
    };
    var minimum_main: f32 = 0;
    if (dimensionAuto(main_min_dimension) and preserves_automatic_minimum) {
        const content_suggestion = try add(
            axisMain(axes, min_natural.content),
            if (axes.horizontal) edges.horizontal else edges.vertical,
        );
        minimum_main = if (preferred_main) |preferred|
            @min(preferred, content_suggestion)
        else
            content_suggestion;
        if (transferred_constraints.main.max) |maximum| {
            minimum_main = @min(minimum_main, maximum);
        }
        minimum_main = @max(
            if (axes.horizontal) edges.box_horizontal else edges.box_vertical,
            try nonNegative(minimum_main),
        );
    }
    return .{
        .style = style_constraints,
        .transferred = transferred_constraints,
        .minimum_main = minimum_main,
    };
}

fn resolvedFlexBasis(
    input: style.Style,
    axes: Axes,
    containing_main: f32,
    percentage_basis: ?f32,
    natural: Natural,
    edges: Edges,
) sizing.Error!?f32 {
    const box_edge_sum = if (axes.horizontal) edges.box_horizontal else edges.box_vertical;
    const content_edge_sum = if (axes.horizontal) edges.horizontal else edges.vertical;
    const intrinsic = if (axes.horizontal) natural.content.width else natural.content.height;
    const dimension = switch (input.flex_basis) {
        .auto => return null,
        .length, .percent, .min_content, .max_content, .fit_content => input.flex_basis,
    };
    const basis = try resolveDimensionBorder(
        dimension,
        containing_main,
        percentage_basis,
        intrinsic,
        box_edge_sum,
        content_edge_sum,
        input.box_sizing,
    );
    return if (basis) |value| @as(?f32, try nonNegative(value)) else null;
}

fn flexBasis(
    input: style.Style,
    axes: Axes,
    containing_main: f32,
    percentage_basis: ?f32,
    preferred: f32,
    natural: Natural,
    edges: Edges,
) sizing.Error!f32 {
    if (try resolvedFlexBasis(
        input,
        axes,
        containing_main,
        percentage_basis,
        natural,
        edges,
    )) |basis| return basis;
    return nonNegative(preferred);
}

fn makeLines(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    items: []const Item,
    wrap: style.FlexWrap,
    available: f32,
    gap: f32,
) sizing.Error!void {
    if (items.len == 0) return;
    var start: usize = 0;
    var used: f32 = 0;
    for (items, 0..) |item, index| {
        const outer = try finite(item.hypothetical_outer);
        const candidate = if (index == start)
            outer
        else
            try add(try add(used, gap), outer);
        if (wrap != .nowrap and index != start and candidate > available) {
            try lines.append(allocator, .{ .start = start, .count = index - start });
            start = index;
            used = outer;
        } else {
            used = candidate;
        }
    }
    try lines.append(allocator, .{ .start = start, .count = items.len - start });
}

fn resolveLine(items: []Item, available: f32, gap: f32) sizing.Error!void {
    if (items.len == 0) return;
    const gap_total = try gaps(gap, items.len);
    var hypothetical_used = gap_total;
    for (items) |item| {
        hypothetical_used = try add(hypothetical_used, item.hypothetical_outer);
    }
    const growing = hypothetical_used < available;
    const shrinking = hypothetical_used > available;
    for (items) |*item| {
        item.target = item.hypothetical_main;
        item.provisional = item.target;
        item.violation = 0;
        item.frozen = (!growing and !shrinking) or
            (growing and item.flex_basis > item.hypothetical_main) or
            (shrinking and item.flex_basis < item.hypothetical_main) or
            (item.grow == 0 and item.shrink == 0);
    }

    var initial_used = gap_total;
    for (items) |item| {
        const used = if (item.frozen) item.target else item.flex_basis;
        initial_used = try add(initial_used, used);
        initial_used = try add(initial_used, item.margin_start);
        initial_used = try add(initial_used, item.margin_end);
    }
    const initial_free = try finite(available - initial_used);
    while (true) {
        var used = gap_total;
        var unfrozen_count: usize = 0;
        var factor_sum: f32 = 0;
        var weight_sum: f32 = 0;
        for (items) |item| {
            const contribution = if (item.frozen) item.target else item.flex_basis;
            used = try add(used, contribution);
            used = try add(used, item.margin_start);
            used = try add(used, item.margin_end);
            if (!item.frozen) {
                unfrozen_count += 1;
                const factor = if (growing) item.grow else item.shrink;
                factor_sum = try add(factor_sum, factor);
                const weight = if (growing) factor else factor * item.inner_flex_basis;
                weight_sum = try add(weight_sum, weight);
            }
        }
        if (unfrozen_count == 0) break;
        const free = try finite(available - used);
        for (items) |*item| {
            if (!item.frozen) item.provisional = item.target;
        }
        if (free != 0 and factor_sum > 0 and weight_sum > 0) {
            const distributable = if (factor_sum < 1) blk: {
                const scaled = try finite(initial_free * factor_sum - gap_total);
                break :blk if (growing) @min(scaled, free) else @max(scaled, free);
            } else free;
            for (items) |*item| {
                if (item.frozen) continue;
                const weight = if (growing) item.grow else item.shrink * item.inner_flex_basis;
                item.provisional = try finite(item.flex_basis + distributable * weight / weight_sum);
            }
        }
        for (items) |*item| {
            if (item.frozen) continue;
            const clamped = @max(
                item.main_floor,
                try clamp(@max(0, item.provisional), item.main_min, item.main_max),
            );
            item.violation = try finite(clamped - item.provisional);
            item.target = clamped;
        }
        var total_violation: f32 = 0;
        for (items) |item| {
            if (!item.frozen) total_violation = try add(total_violation, item.violation);
        }
        for (items) |*item| {
            if (item.frozen) continue;
            item.frozen = if (total_violation > 0)
                item.violation > 0
            else if (total_violation < 0)
                item.violation < 0
            else
                true;
        }
    }

    var used = gap_total;
    var auto_count: usize = 0;
    for (items) |item| {
        used = try add(used, item.target);
        used = try add(used, item.margin_start);
        used = try add(used, item.margin_end);
        if (item.main_start_auto) auto_count += 1;
        if (item.main_end_auto) auto_count += 1;
    }
    const free = @max(0, try finite(available - used));
    if (auto_count != 0 and free > 0) {
        const share = free / (try countToF32(auto_count));
        for (items) |*item| {
            if (item.main_start_auto) item.margin_start = share;
            if (item.main_end_auto) item.margin_end = share;
        }
    }
}
fn baselineForItem(child: *const widget.WidgetNode, border: widget.Size) f32 {
    if (child.children.items.len == 0) return border.height;
    return switch (child.style.display) {
        .block, .flow_root, .none => border.height,
        .flex, .grid => child.first_baseline orelse border.height,
    };
}

fn lineCrossSizes(
    lines: []Line,
    items: []const Item,
    available: f32,
    gap: f32,
    axes: Axes,
    force_single_line_cross: bool,
) sizing.Error!void {
    for (lines) |*line| {
        line.cross = 0;
        line.max_baseline = 0;
        line.max_descent = 0;
        line.baseline_count = 0;
        for (items[line.start .. line.start + line.count]) |item| {
            const outer = try add(
                try add(item.cross, item.cross_margin_start),
                item.cross_margin_end,
            );
            line.cross = @max(line.cross, outer);
            if (axes.horizontal and item.baseline_participates) {
                const ascent = try add(item.physical_top_margin, item.baseline);
                const descent = @max(
                    0,
                    try finite(
                        item.physical_bottom_margin + item.cross - item.baseline,
                    ),
                );
                line.max_baseline = @max(line.max_baseline, ascent);
                line.max_descent = @max(line.max_descent, descent);
                line.baseline_count += 1;
            }
        }
        if (axes.horizontal and line.baseline_count > 1) {
            line.cross = @max(
                line.cross,
                try add(line.max_baseline, line.max_descent),
            );
        }
    }
    if (force_single_line_cross and lines.len == 1) lines[0].cross = available;
    var total = try gaps(gap, lines.len);
    for (lines) |line| total = try add(total, line.cross);
    _ = try finite(total);
}

fn lineDistribution(
    lines: []Line,
    align_content: style.AlignContent,
    available: f32,
    gap: f32,
    flex_reverse: bool,
    writing_reverse: bool,
) sizing.Error!void {
    if (lines.len == 0) return;
    var used = try gaps(gap, lines.len);
    for (lines) |line| used = try add(used, line.cross);
    const signed_free = try finite(available - used);
    const free = @max(0, signed_free);
    const start_offset = if (flex_reverse == writing_reverse) 0 else free;
    const end_offset = if (flex_reverse == writing_reverse) signed_free else 0;
    var offset: f32 = 0;
    var extra: f32 = 0;
    switch (align_content) {
        .stretch => {
            if (free > 0) {
                const addition = free / (try countToF32(lines.len));
                for (lines) |*line| line.cross = try add(line.cross, addition);
            }
        },
        .start => offset = start_offset,
        .flex_start => {},
        .safe_center => offset = free / 2,
        .center, .unsafe_center => offset = signed_free / 2,
        .end, .unsafe_end => offset = end_offset,
        .flex_end => offset = signed_free,
        .safe_end => offset = if (signed_free < 0) 0 else end_offset,
        .space_between => {
            if (lines.len > 1) {
                extra = free / (try countToF32(lines.len - 1));
            }
        },
        .space_around => {
            extra = free / (try countToF32(lines.len));
            offset = extra / 2;
        },
        .space_evenly => {
            extra = free / (try countToF32(lines.len + 1));
            offset = extra;
        },
    }
    var cursor = try finite(offset);
    for (lines, 0..) |*line, line_index| {
        line.position = cursor;
        cursor = try add(cursor, line.cross);
        if (line_index + 1 < lines.len) cursor = try add(cursor, try add(gap, extra));
    }
}

fn placeItems(
    tree: *widget.WidgetTree,
    container: *const widget.WidgetNode,
    axes: Axes,
    content: widget.Size,
    lines: []const Line,
    items: []Item,
    gap: f32,
) sizing.Error!void {
    const main_available = axisMain(axes, content);
    const cross_available = axisCross(axes, content);
    for (lines) |line| {
        const line_items = items[line.start .. line.start + line.count];
        var used = try gaps(gap, line_items.len);
        for (line_items) |item| {
            used = try add(used, item.target);
            used = try add(used, item.margin_start);
            used = try add(used, item.margin_end);
        }
        const free = try finite(main_available - used);
        const distribution = if (hasAuto(line_items))
            Distribution{ .offset = 0, .gap = 0 }
        else
            try justify(
                container.style.justify,
                free,
                line_items.len,
                axes.reverse,
                mainWritingReverse(axes, container.style.writing_direction),
            );
        var cursor = distribution.offset;

        for (line_items, 0..) |*item, item_index| {
            cursor = try add(cursor, item.margin_start);
            const logical_main = cursor;
            cursor = try add(cursor, item.target);
            cursor = try add(cursor, item.margin_end);
            if (item_index + 1 < line_items.len) {
                cursor = try add(cursor, gap);
                cursor = try add(cursor, distribution.gap);
            }

            const child = &tree.nodes.items[item.index];
            const resolved_alignment = alignValue(
                child.style.align_self,
                container.style.@"align",
                child.style.writing_direction == container.style.writing_direction,
                !axes.horizontal,
            );
            const baseline_column = !axes.horizontal and resolved_alignment == .baseline;
            const alignment = if (baseline_column)
                style.Align.flex_start
            else
                resolved_alignment;
            const baseline_column_reverse = baseline_column and
                axes.cross_reverse and
                container.style.flex_wrap == .nowrap;
            var cross_start = item.cross_margin_start;
            var cross_end = item.cross_margin_end;
            var cross = item.cross;
            var cross_free = try finite(line.cross - cross - cross_start - cross_end);
            if (item.cross_start_auto or item.cross_end_auto) {
                const auto_count = @as(usize, @intFromBool(item.cross_start_auto)) +
                    @as(usize, @intFromBool(item.cross_end_auto));
                if (auto_count != 0 and cross_free > 0) {
                    const share = cross_free / (try countToF32(auto_count));
                    if (item.cross_start_auto) cross_start = share;
                    if (item.cross_end_auto) cross_end = share;
                    cross_free = 0;
                }
            } else if (alignment == .stretch and item.cross_auto) {
                cross = try clamp(
                    @max(0, line.cross - cross_start - cross_end),
                    item.cross_min,
                    item.cross_max,
                );
                cross_free = try finite(line.cross - cross - cross_start - cross_end);
            }
            const align_offset = if (item.cross_start_auto or item.cross_end_auto)
                0
            else if (alignment == .baseline and axes.horizontal and line.baseline_count > 1)
                if (axes.cross_reverse)
                    line.max_descent - (cross_start + cross - item.baseline)
                else
                    line.max_baseline - (cross_start + item.baseline)
            else
                try alignmentOffset(
                    alignment,
                    cross_free,
                    axes.cross_reverse,
                    !axes.horizontal and container.style.writing_direction == .rtl,
                );
            const logical_cross = try add(line.position, try add(cross_start, align_offset));
            const physical_main = try position(
                logical_main,
                item.target,
                main_available,
                axes.reverse,
            );
            const baseline_wrapped_rtl = baseline_column and
                axes.cross_reverse and
                container.style.flex_wrap != .nowrap;
            const physical_cross = if (baseline_wrapped_rtl)
                try add(
                    try finite(cross_available - line.position - line.cross),
                    try add(cross_start, align_offset),
                )
            else
                try position(
                    logical_cross,
                    cross,
                    cross_available,
                    if (baseline_column) baseline_column_reverse else axes.cross_reverse,
                );
            child.rect = if (axes.horizontal)
                .{ .x = physical_main, .y = physical_cross, .w = item.target, .h = cross }
            else
                .{ .x = physical_cross, .y = physical_main, .w = cross, .h = item.target };
            try relativeInsets(
                child,
                content,
                container.style.writing_direction,
            );
            try checkRect(child.rect);
        }
    }
}
fn paddingBoxContributionRect(
    rect: widget.Rect,
    client_width: f32,
    raw_padding: style.Sides,
    direction: style.Direction,
) sizing.Error!widget.Rect {
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

fn resolvedGutter(edges: Edges) style.Sides {
    return .{
        .top = @max(0, edges.padding.top - edges.raw_padding.top),
        .right = @max(0, edges.padding.right - edges.raw_padding.right),
        .bottom = @max(0, edges.padding.bottom - edges.raw_padding.bottom),
        .left = @max(0, edges.padding.left - edges.raw_padding.left),
    };
}

fn publishContentSize(
    tree: *widget.WidgetTree,
    container: *widget.WidgetNode,
    pad_box: widget.Size,
    edges: Edges,
) sizing.Error!void {
    const gutter = resolvedGutter(edges);
    const client: widget.Size = .{
        .width = @max(0, try finite(pad_box.width - gutter.left - gutter.right)),
        .height = @max(0, try finite(pad_box.height - gutter.top - gutter.bottom)),
    };
    var inflow_extent: widget.Size = .{ .width = 0, .height = 0 };
    var absolute_extent: widget.Size = .{ .width = 0, .height = 0 };
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
        const absolute = child.style.position == .absolute;
        const contribution = if (absolute)
            try overflow.absoluteFlexContribution(
                contribution_rect,
                child.layout_content_size,
                child.style.overflow,
                container.style.writing_direction,
            )
        else
            try overflow.contentContribution(
                contribution_rect,
                child.layout_content_size,
                child.style.overflow,
            );
        const target = if (absolute) &absolute_extent else &inflow_extent;
        target.width = @max(target.width, contribution.width);
        target.height = @max(target.height, contribution.height);
    }
    const trailing_width = if (container.style.writing_direction == .rtl)
        edges.raw_padding.left
    else
        edges.raw_padding.right;
    inflow_extent.width = try add(inflow_extent.width, trailing_width);
    inflow_extent.height = try add(inflow_extent.height, edges.raw_padding.bottom);
    const extent: widget.Size = .{
        .width = @max(inflow_extent.width, absolute_extent.width),
        .height = @max(inflow_extent.height, absolute_extent.height),
    };
    container.layout_content_size = extent;

    if (container.scroll) |scroll| {
        scroll.state.max_offset = try overflow.maxOffset(extent, client, scroll.axis);
    }
}

fn placeAbsolute(
    tree: *widget.WidgetTree,
    container: *const widget.WidgetNode,
    content: widget.Size,
    pad_box: widget.Size,
    container_edges: Edges,
    options: Options,
    cache: []Natural,
    depth: usize,
) sizing.Error!void {
    const gutter = resolvedGutter(container_edges);
    const inset_box: widget.Size = .{
        .width = @max(0, try finite(pad_box.width - gutter.left - gutter.right)),
        .height = @max(0, try finite(pad_box.height - gutter.top - gutter.bottom)),
    };
    for (container.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        const child = &tree.nodes.items[child_index];
        if (child.layout_hidden or child.style.position != .absolute) continue;
        const edges = try resolveEdges(child.style, inset_box.width);
        child.resolved_box_edges = .{ .border = edges.border, .padding = edges.padding };
        const left = try resolveInset(child.style.inset.left, inset_box.width);
        const right = try resolveInset(child.style.inset.right, inset_box.width);
        const top = try resolveInset(child.style.inset.top, inset_box.height);
        const bottom = try resolveInset(child.style.inset.bottom, inset_box.height);
        const width_intrinsic = (child.style.size.width == .auto or
            dimensionIntrinsic(child.style.size.width)) and
            (left == null or right == null);
        const height_intrinsic = (child.style.size.height == .auto or
            dimensionIntrinsic(child.style.size.height)) and
            (top == null or bottom == null);
        var natural_request = concreteRequest(inset_box);
        if (width_intrinsic) {
            natural_request.available.width = 0;
            natural_request.width_mode = .max_content;
            natural_request.percentage_basis.width = null;
        }
        if (height_intrinsic) {
            natural_request.available.height = 0;
            natural_request.height_mode = .max_content;
            natural_request.percentage_basis.height = null;
        }
        const natural = try measureNode(
            tree,
            child_index,
            natural_request,
            options,
            cache,
            depth,
            container.style.display,
        );
        var margins = try resolveMargins(child.style, inset_box.width);
        const full_inset_aspect_ratio = child.style.size.width == .auto and
            child.style.size.height == .auto and
            child.style.aspect_ratio != null and
            left != null and
            right != null and
            top != null and
            bottom != null;
        var sizing_style = child.style;
        if (child.style.size.width == .auto and left != null and right != null) {
            const inset_width = try absoluteSizeFromInsets(
                inset_box.width,
                left.?,
                right.?,
                margins.value.left,
                margins.value.right,
            );
            const inset_sizing_width = try borderToSizing(
                inset_width,
                edges.box_horizontal,
                child.style.box_sizing,
            );
            sizing_style.size.width = .{ .length = inset_sizing_width };
        }
        if (!full_inset_aspect_ratio and
            child.style.size.height == .auto and
            top != null and
            bottom != null)
        {
            const inset_height = try absoluteSizeFromInsets(
                inset_box.height,
                top.?,
                bottom.?,
                margins.value.top,
                margins.value.bottom,
            );
            const inset_sizing_height = try borderToSizing(
                inset_height,
                edges.box_vertical,
                child.style.box_sizing,
            );
            sizing_style.size.height = .{ .length = inset_sizing_height };
        }
        const size = try usedSize(
            sizing_style,
            inset_box,
            .{ .width = inset_box.width, .height = inset_box.height },
            natural.content,
            edges,
            null,
        );
        try distributeAbsoluteAutoMargins(
            &margins.value.left,
            &margins.value.right,
            margins.left_auto,
            margins.right_auto,
            inset_box.width,
            size.width,
            left,
            right,
        );
        try distributeAbsoluteAutoMargins(
            &margins.value.top,
            &margins.value.bottom,
            margins.top_auto,
            margins.bottom_auto,
            inset_box.height,
            size.height,
            top,
            bottom,
        );
        const axes = axesFor(container.style);
        const main_writing_reverse =
            axes.horizontal and container.style.writing_direction == .rtl;
        const cross_writing_reverse =
            !axes.horizontal and container.style.writing_direction == .rtl;
        const alignment = alignValue(
            child.style.align_self,
            container.style.@"align",
            child.style.writing_direction == container.style.writing_direction,
            !axes.horizontal,
        );
        const static_main = try staticMainPosition(
            container.style.justify,
            axisMain(axes, content),
            axisMain(axes, size),
            marginStart(axes, margins),
            marginEnd(axes, margins),
            axes.reverse,
            main_writing_reverse,
        );
        const static_cross = try staticCrossPosition(
            alignment,
            axisCross(axes, content),
            axisCross(axes, size),
            crossStart(axes, margins),
            crossEnd(axes, margins),
            axes.cross_reverse,
            cross_writing_reverse,
        );
        const static_x = if (axes.horizontal) static_main else static_cross;
        const static_y = if (axes.horizontal) static_cross else static_main;
        const right_basis = try finite(pad_box.width - gutter.right);
        const bottom_basis = try finite(pad_box.height - gutter.bottom);
        const x = if (container.style.writing_direction == .rtl and right != null)
            try finite(
                right_basis -
                    right.? -
                    margins.value.right -
                    size.width -
                    container_edges.padding.left,
            )
        else if (left) |value|
            try finite(
                value +
                    margins.value.left +
                    (if (container.style.writing_direction == .rtl) gutter.left else 0) -
                    container_edges.padding.left,
            )
        else if (right) |value|
            try finite(
                right_basis -
                    value -
                    margins.value.right -
                    size.width -
                    container_edges.padding.left,
            )
        else
            static_x;
        const y = if (top) |value|
            try finite(value + margins.value.top - container_edges.padding.top)
        else if (bottom) |value|
            try finite(
                bottom_basis -
                    value -
                    margins.value.bottom -
                    size.height -
                    container_edges.padding.top,
            )
        else
            static_y;
        child.rect = .{ .x = x, .y = y, .w = size.width, .h = size.height };
        try checkRect(child.rect);
        if (options.context) |context| {
            if (child.children.items.len == 0 or child.style.display != .flex) {
                try context.layout_node(
                    context,
                    tree,
                    child,
                    .{
                        .available = inset_box,
                        .percentage_basis = .{
                            .width = inset_box.width,
                            .height = inset_box.height,
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
            try layoutFlex(
                tree,
                child_index,
                inset_box,
                size,
                true,
                options,
                cache,
                depth,
            );
        }
    }
}

fn absoluteSizeFromInsets(
    available: f32,
    start: f32,
    end: f32,
    margin_start: f32,
    margin_end: f32,
) sizing.Error!f32 {
    return @max(0, try finite(available - start - end - margin_start - margin_end));
}

fn distributeAbsoluteAutoMargins(
    start: *f32,
    end: *f32,
    start_auto: bool,
    end_auto: bool,
    available: f32,
    size: f32,
    start_inset: ?f32,
    end_inset: ?f32,
) sizing.Error!void {
    if (start_inset == null or end_inset == null) return;
    if (!start_auto and !end_auto) return;
    const fixed_start = if (start_auto) 0 else start.*;
    const fixed_end = if (end_auto) 0 else end.*;
    const auto_space = try finite(available - start_inset.? - end_inset.?);
    const remaining = try finite(@max(
        0,
        auto_space - size - fixed_start - fixed_end,
    ));
    if (start_auto and end_auto) {
        const share = try finite(remaining / 2);
        start.* = share;
        end.* = share;
    } else if (start_auto) {
        start.* = remaining;
    } else {
        end.* = remaining;
    }
}
fn staticMainPosition(
    value: style.Justify,
    available: f32,
    size: f32,
    margin_start: f32,
    margin_end: f32,
    flex_reverse: bool,
    writing_reverse: bool,
) sizing.Error!f32 {
    const free = try finite(available - size - margin_start - margin_end);
    const offset = try staticMainOffset(value, free, flex_reverse, writing_reverse);
    return position(try add(margin_start, offset), size, available, flex_reverse);
}

fn staticMainOffset(
    value: style.Justify,
    free: f32,
    flex_reverse: bool,
    writing_reverse: bool,
) sizing.Error!f32 {
    const distributed_free = @max(0, free);
    const start_offset = staticStartOffset(free, flex_reverse, writing_reverse);
    const end_offset = staticEndOffset(free, flex_reverse, writing_reverse);
    return switch (value) {
        .normal, .flex_start, .space_between => 0,
        .start => start_offset,
        .safe_center => try finite(distributed_free / 2),
        .center, .unsafe_center => try finite(free / 2),
        .end, .unsafe_end => end_offset,
        .flex_end => free,
        .safe_end => end_offset,
        .space_around, .space_evenly => try finite(distributed_free / 2),
    };
}

fn staticCrossPosition(
    value: style.Align,
    available: f32,
    size: f32,
    margin_start: f32,
    margin_end: f32,
    flex_reverse: bool,
    writing_reverse: bool,
) sizing.Error!f32 {
    const free = try finite(available - size - margin_start - margin_end);
    const offset = try staticCrossOffset(value, free, flex_reverse, writing_reverse);
    return position(try add(margin_start, offset), size, available, flex_reverse);
}

fn staticCrossOffset(
    value: style.Align,
    free: f32,
    flex_reverse: bool,
    writing_reverse: bool,
) sizing.Error!f32 {
    const start_offset = staticStartOffset(free, flex_reverse, writing_reverse);
    const end_offset = staticEndOffset(free, flex_reverse, writing_reverse);
    return switch (value) {
        .stretch, .flex_start => 0,
        .start, .baseline, .self_start => start_offset,
        .safe_center => try finite(@max(0, free) / 2),
        .center, .unsafe_center => try finite(free / 2),
        .end, .unsafe_end, .self_end => end_offset,
        .flex_end => free,
        .safe_end => if (free < 0) start_offset else end_offset,
    };
}

fn staticStartOffset(free: f32, flex_reverse: bool, writing_reverse: bool) f32 {
    return if (flex_reverse == writing_reverse) 0 else free;
}

fn staticEndOffset(free: f32, flex_reverse: bool, writing_reverse: bool) f32 {
    return if (flex_reverse == writing_reverse) free else 0;
}

fn alignmentOffset(
    value: style.Align,
    free: f32,
    flex_reverse: bool,
    writing_reverse: bool,
) sizing.Error!f32 {
    const distributed_free = @max(0, free);
    const start_offset = staticStartOffset(free, flex_reverse, writing_reverse);
    const end_offset = staticEndOffset(free, flex_reverse, writing_reverse);
    return switch (value) {
        .stretch, .flex_start, .baseline => 0,
        .start, .self_start => start_offset,
        .safe_center => try finite(distributed_free / 2),
        .center, .unsafe_center => try finite(free / 2),
        .end, .unsafe_end, .self_end => end_offset,
        .flex_end => free,
        .safe_end => if (free < 0) start_offset else end_offset,
    };
}
fn flexBaseSize(
    input: style.Style,
    containing: widget.Size,
    percentage_basis: style.Size(?f32),
    intrinsic: widget.Size,
    edges: Edges,
) sizing.Error!widget.Size {
    var width = try dimensionValue(
        input.size.width,
        containing.width,
        percentage_basis.width,
        intrinsic.width,
    );
    var height = try dimensionValue(
        input.size.height,
        containing.height,
        percentage_basis.height,
        intrinsic.height,
    );
    var width_edge_sum = dimensionEdgeSum(
        input.size.width,
        edges.box_horizontal,
        edges.horizontal,
    );
    var height_edge_sum = dimensionEdgeSum(
        input.size.height,
        edges.box_vertical,
        edges.vertical,
    );
    const width_auto = width == null;
    const height_auto = height == null;
    if (width == null and height != null and input.aspect_ratio != null) {
        width = try finite(height.? * try ratio(input.aspect_ratio.?));
        width_edge_sum = explicitEdgeSum(edges.box_horizontal);
    }
    if (height == null and width != null and input.aspect_ratio != null) {
        height = try finite(width.? / try ratio(input.aspect_ratio.?));
        height_edge_sum = explicitEdgeSum(edges.box_vertical);
    }
    if (width == null) {
        width_edge_sum = edges.horizontal;
        width = try borderToSizing(
            try add(intrinsic.width, edges.horizontal),
            edges.horizontal,
            input.box_sizing,
        );
    }
    if (height == null) {
        height_edge_sum = edges.vertical;
        height = try borderToSizing(
            try add(intrinsic.height, edges.vertical),
            edges.vertical,
            input.box_sizing,
        );
    }
    if (input.aspect_ratio) |aspect| {
        const ratio_value = try ratio(aspect);
        if (width_auto and height_auto) {
            // With two auto dimensions, the intrinsic width establishes the
            // ratio-constrained base size. Min/max constraints belong to the
            // hypothetical-size step, not the flex base size.
            height = try finite(width.? / ratio_value);
            height_edge_sum = explicitEdgeSum(edges.box_vertical);
        }
    }
    return .{
        .width = if (dimensionIntrinsic(input.size.width))
            try add(width.?, edges.horizontal)
        else
            try sizingToBorder(width.?, width_edge_sum, input.box_sizing),
        .height = if (dimensionIntrinsic(input.size.height))
            try add(height.?, edges.vertical)
        else
            try sizingToBorder(height.?, height_edge_sum, input.box_sizing),
    };
}

fn usedSizeForRequest(
    input: style.Style,
    containing: widget.Size,
    percentage_basis: style.Size(?f32),
    intrinsic: widget.Size,
    edges: Edges,
    request: layout_context.Request,
) sizing.Error!widget.Size {
    return switch (request.sizing_mode) {
        .content => contentRootUsedSize(intrinsic, edges, request.known_border),
        .inherent => blk: {
            var seeded_input = input;
            if (request.known_border.width) |known| {
                const sizing_width = try borderToSizing(
                    known,
                    edges.box_horizontal,
                    input.box_sizing,
                );
                seeded_input.size.width = .{ .length = sizing_width };
            }
            if (request.known_border.height) |known| {
                const sizing_height = try borderToSizing(
                    known,
                    edges.box_vertical,
                    input.box_sizing,
                );
                seeded_input.size.height = .{ .length = sizing_height };
            }
            var result = try usedSize(
                seeded_input,
                containing,
                percentage_basis,
                intrinsic,
                edges,
                null,
            );
            if (request.known_border.width) |known| {
                result.width = @max(try nonNegative(known), edges.horizontal);
            }
            if (request.known_border.height) |known| {
                result.height = @max(try nonNegative(known), edges.vertical);
            }
            break :blk result;
        },
    };
}

/// Resolve a root's border size while keeping request-owned content sizing out
/// of descendant style resolution.
fn contentRootUsedSize(
    intrinsic: widget.Size,
    edges: Edges,
    known_border: sizing.OptionalSize,
) sizing.Error!widget.Size {
    return .{
        .width = if (known_border.width) |known|
            @max(try nonNegative(known), edges.horizontal)
        else
            try add(try nonNegative(intrinsic.width), edges.horizontal),
        .height = if (known_border.height) |known|
            @max(try nonNegative(known), edges.vertical)
        else
            try add(try nonNegative(intrinsic.height), edges.vertical),
    };
}

fn usedSize(
    input: style.Style,
    containing: widget.Size,
    percentage_basis: style.Size(?f32),
    intrinsic: widget.Size,
    edges: Edges,
    fallback: ?widget.Size,
) sizing.Error!widget.Size {
    var width = try dimensionValue(
        input.size.width,
        containing.width,
        percentage_basis.width,
        intrinsic.width,
    );
    var height = try dimensionValue(
        input.size.height,
        containing.height,
        percentage_basis.height,
        intrinsic.height,
    );
    var width_edge_sum = dimensionEdgeSum(
        input.size.width,
        edges.box_horizontal,
        edges.horizontal,
    );
    var height_edge_sum = dimensionEdgeSum(
        input.size.height,
        edges.box_vertical,
        edges.vertical,
    );
    const width_auto = width == null;
    const height_auto = height == null;
    if (width == null and height != null and input.aspect_ratio != null) {
        width = try finite(height.? * try ratio(input.aspect_ratio.?));
        width_edge_sum = explicitEdgeSum(edges.box_horizontal);
    }
    if (height == null and width != null and input.aspect_ratio != null) {
        height = try finite(width.? / try ratio(input.aspect_ratio.?));
        height_edge_sum = explicitEdgeSum(edges.box_vertical);
    }
    if (width == null) {
        width_edge_sum = edges.horizontal;
        width = if (fallback) |value|
            try borderToSizing(value.width, edges.horizontal, input.box_sizing)
        else
            try borderToSizing(
                try add(intrinsic.width, edges.horizontal),
                edges.horizontal,
                input.box_sizing,
            );
    }
    if (height == null) {
        height_edge_sum = edges.vertical;
        height = if (fallback) |value|
            try borderToSizing(value.height, edges.vertical, input.box_sizing)
        else
            try borderToSizing(
                try add(intrinsic.height, edges.vertical),
                edges.vertical,
                input.box_sizing,
            );
    }
    var result: widget.Size = .{
        .width = if (dimensionIntrinsic(input.size.width))
            try add(width.?, edges.horizontal)
        else
            try sizingToBorder(width.?, width_edge_sum, input.box_sizing),
        .height = if (dimensionIntrinsic(input.size.height))
            try add(height.?, edges.vertical)
        else
            try sizingToBorder(height.?, height_edge_sum, input.box_sizing),
    };
    result.width = try clampSize(
        input,
        .horizontal,
        result.width,
        containing,
        percentage_basis,
        intrinsic,
        edges,
    );
    result.height = try clampSize(
        input,
        .vertical,
        result.height,
        containing,
        percentage_basis,
        intrinsic,
        edges,
    );
    if (input.aspect_ratio) |aspect_ratio| {
        const ratio_value = try ratio(aspect_ratio);
        if (width_auto and height_auto) {
            // An aspect-ratio replaces the unconstrained auto pair with one
            // intrinsic ratio candidate. Clamp that candidate, then transfer
            // the limiting axis back to the other dimension.
            const base = try flexBaseSize(
                input,
                containing,
                percentage_basis,
                intrinsic,
                edges,
            );
            var ratio_result: widget.Size = .{
                .width = try clampSize(
                    input,
                    .horizontal,
                    base.width,
                    containing,
                    percentage_basis,
                    intrinsic,
                    edges,
                ),
                .height = try clampSize(
                    input,
                    .vertical,
                    base.height,
                    containing,
                    percentage_basis,
                    intrinsic,
                    edges,
                ),
            };
            if (ratio_result.width != base.width) {
                const width_sizing = try borderToDimensionValue(
                    input.size.width,
                    ratio_result.width,
                    width_edge_sum,
                    input.box_sizing,
                );
                ratio_result.height = try clampSize(
                    input,
                    .vertical,
                    try sizingToBorder(
                        try finite(width_sizing / ratio_value),
                        explicitEdgeSum(edges.box_vertical),
                        input.box_sizing,
                    ),
                    containing,
                    percentage_basis,
                    intrinsic,
                    edges,
                );
            } else if (ratio_result.height != base.height) {
                const height_sizing = try borderToDimensionValue(
                    input.size.height,
                    ratio_result.height,
                    height_edge_sum,
                    input.box_sizing,
                );
                ratio_result.width = try clampSize(
                    input,
                    .horizontal,
                    try sizingToBorder(
                        try finite(height_sizing * ratio_value),
                        explicitEdgeSum(edges.box_horizontal),
                        input.box_sizing,
                    ),
                    containing,
                    percentage_basis,
                    intrinsic,
                    edges,
                );
            }
            result = ratio_result;
        } else if (height_auto) {
            const width_sizing = try borderToDimensionValue(
                input.size.width,
                result.width,
                width_edge_sum,
                input.box_sizing,
            );
            result.height = try clampSize(
                input,
                .vertical,
                try sizingToBorder(
                    try finite(width_sizing / ratio_value),
                    explicitEdgeSum(edges.box_vertical),
                    input.box_sizing,
                ),
                containing,
                percentage_basis,
                intrinsic,
                edges,
            );
        } else if (width_auto) {
            const height_sizing = try borderToDimensionValue(
                input.size.height,
                result.height,
                height_edge_sum,
                input.box_sizing,
            );
            result.width = try clampSize(
                input,
                .horizontal,
                try sizingToBorder(
                    try finite(height_sizing * ratio_value),
                    explicitEdgeSum(edges.box_horizontal),
                    input.box_sizing,
                ),
                containing,
                percentage_basis,
                intrinsic,
                edges,
            );
        }
    }
    return .{
        .width = @max(edges.box_horizontal, result.width),
        .height = @max(edges.box_vertical, result.height),
    };
}

const PhysicalAxis = enum { horizontal, vertical };

fn clampSize(
    input: style.Style,
    axis: PhysicalAxis,
    candidate: f32,
    containing: widget.Size,
    percentage_basis: style.Size(?f32),
    intrinsic: widget.Size,
    edges: Edges,
) sizing.Error!f32 {
    const minimum_dimension = if (axis == .horizontal)
        input.min_size.width
    else
        input.min_size.height;
    const maximum_dimension = if (axis == .horizontal)
        input.max_size.width
    else
        input.max_size.height;
    const available = if (axis == .horizontal) containing.width else containing.height;
    const basis = if (axis == .horizontal)
        percentage_basis.width
    else
        percentage_basis.height;
    const natural = if (axis == .horizontal) intrinsic.width else intrinsic.height;
    const box_edge_sum = if (axis == .horizontal) edges.box_horizontal else edges.box_vertical;
    const content_edge_sum = if (axis == .horizontal) edges.horizontal else edges.vertical;
    const minimum = (try resolveDimensionBorder(
        minimum_dimension,
        available,
        basis,
        natural,
        box_edge_sum,
        content_edge_sum,
        input.box_sizing,
    )) orelse 0;
    const maximum = try resolveDimensionBorder(
        maximum_dimension,
        available,
        basis,
        natural,
        box_edge_sum,
        content_edge_sum,
        input.box_sizing,
    );
    return clamp(candidate, minimum, maximum);
}

fn dimensionValue(
    dimension: style.Dimension,
    containing: f32,
    percentage_basis: ?f32,
    intrinsic: f32,
) sizing.Error!?f32 {
    return switch (dimension) {
        .auto => null,
        .min_content, .max_content => try nonNegative(intrinsic),
        .fit_content => |limit| blk: {
            const non_neg_intrinsic = try nonNegative(intrinsic);
            if (limit) |lim| {
                const non_neg_limit = try nonNegative(lim);
                break :blk @min(non_neg_intrinsic, non_neg_limit);
            }
            break :blk non_neg_intrinsic;
        },
        .length => sizing.resolveDimension(
            dimension,
            .{ .definite = containing },
            percentage_basis,
        ),
        .percent => if (percentage_basis) |basis|
            sizing.resolveDimension(
                dimension,
                .{ .definite = containing },
                basis,
            )
        else
            null,
    };
}

fn explicitEdgeSum(box_edges: f32) f32 {
    return box_edges;
}

fn dimensionIntrinsic(dimension: style.Dimension) bool {
    return switch (dimension) {
        .min_content, .max_content, .fit_content => true,
        .auto, .length, .percent => false,
    };
}

fn dimensionEdgeSum(
    dimension: style.Dimension,
    box_edges: f32,
    content_edges: f32,
) f32 {
    return switch (dimension) {
        .length, .percent => explicitEdgeSum(box_edges),
        .auto, .min_content, .max_content, .fit_content => content_edges,
    };
}

fn borderToDimensionValue(
    dimension: style.Dimension,
    border: f32,
    edge_sum: f32,
    box_sizing: style.BoxSizing,
) sizing.Error!f32 {
    if (dimensionIntrinsic(dimension)) {
        return @max(0, try finite(border - edge_sum));
    }
    return borderToSizing(border, edge_sum, box_sizing);
}

fn resolveDimensionBorder(
    dimension: style.Dimension,
    containing: f32,
    percentage_basis: ?f32,
    intrinsic: f32,
    box_edges: f32,
    content_edges: f32,
    box_sizing: style.BoxSizing,
) sizing.Error!?f32 {
    const value = try dimensionValue(dimension, containing, percentage_basis, intrinsic);
    if (value) |number| {
        const border = if (dimensionIntrinsic(dimension))
            try add(number, content_edges)
        else
            try sizingToBorder(
                number,
                dimensionEdgeSum(dimension, box_edges, content_edges),
                box_sizing,
            );
        return @as(?f32, border);
    }
    return null;
}

fn sizingToBorder(
    value: f32,
    edges: f32,
    box_sizing: style.BoxSizing,
) sizing.Error!f32 {
    return switch (box_sizing) {
        .content_box => add(try nonNegative(value), edges),
        .border_box => @max(edges, try nonNegative(value)),
    };
}

fn borderToSizing(
    value: f32,
    edges: f32,
    box_sizing: style.BoxSizing,
) sizing.Error!f32 {
    return switch (box_sizing) {
        .content_box => @max(0, try finite(value - edges)),
        .border_box => nonNegative(value),
    };
}

fn resolveEdges(input: style.Style, basis: ?f32) sizing.Error!Edges {
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
    return .{
        .border = border,
        .padding = padding,
        .raw_padding = resolved_padding,
        .box_horizontal = try add(
            try add(border.left, border.right),
            try add(resolved_padding.left, resolved_padding.right),
        ),
        .box_vertical = try add(
            try add(border.top, border.bottom),
            try add(resolved_padding.top, resolved_padding.bottom),
        ),
        .horizontal = try add(
            try add(border.left, border.right),
            try add(padding.left, padding.right),
        ),
        .vertical = try add(
            try add(border.top, border.bottom),
            try add(padding.top, padding.bottom),
        ),
    };
}
fn clampEdges(edges: Edges, border_size: widget.Size) sizing.Error!Edges {
    var result = edges;
    const horizontal_room = @max(
        0,
        try finite(border_size.width - edges.box_horizontal),
    );
    const vertical_room = @max(
        0,
        try finite(border_size.height - edges.box_vertical),
    );
    const left_gutter = @max(
        0,
        try finite(edges.padding.left - edges.raw_padding.left),
    );
    const right_gutter = @max(
        0,
        try finite(edges.padding.right - edges.raw_padding.right),
    );
    const top_gutter = @max(
        0,
        try finite(edges.padding.top - edges.raw_padding.top),
    );
    const bottom_gutter = @max(
        0,
        try finite(edges.padding.bottom - edges.raw_padding.bottom),
    );
    const left = @min(left_gutter, horizontal_room);
    const right = @min(right_gutter, horizontal_room);
    const top = @min(top_gutter, vertical_room);
    const bottom = @min(bottom_gutter, vertical_room);
    result.padding.left = try add(edges.raw_padding.left, left);
    result.padding.right = try add(edges.raw_padding.right, right);
    result.padding.top = try add(edges.raw_padding.top, top);
    result.padding.bottom = try add(edges.raw_padding.bottom, bottom);
    result.horizontal = try add(edges.box_horizontal, try add(left, right));
    result.vertical = try add(edges.box_vertical, try add(top, bottom));
    return result;
}

fn edge(
    value: style.LengthPercentage,
    basis: ?f32,
) sizing.Error!f32 {
    return switch (value) {
        .length => |number| nonNegative(number),
        .percent => |fraction| blk: {
            const percentage_basis = basis orelse break :blk 0;
            break :blk nonNegative(try finite(fraction * percentage_basis));
        },
    };
}

fn resolveMargins(input: style.Style, basis: ?f32) sizing.Error!Margins {
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

fn margin(
    value: style.LengthPercentageAuto,
    basis: ?f32,
) sizing.Error!f32 {
    return switch (value) {
        .auto => 0,
        .length => |number| finite(number),
        .percent => |fraction| blk: {
            const percentage_basis = basis orelse break :blk 0;
            break :blk finite(fraction * percentage_basis);
        },
    };
}

fn resolveInset(value: style.LengthPercentageAuto, basis: f32) sizing.Error!?f32 {
    return switch (value) {
        .auto => null,
        .length => |number| try finite(number),
        .percent => |fraction| try finite(fraction * basis),
    };
}
fn relativeInsets(
    node: *widget.WidgetNode,
    containing: widget.Size,
    writing_direction: style.Direction,
) sizing.Error!void {
    if (node.style.position != .relative) return;
    const left = try resolveInset(node.style.inset.left, containing.width);
    const right = try resolveInset(node.style.inset.right, containing.width);
    const top = try resolveInset(node.style.inset.top, containing.height);
    const bottom = try resolveInset(node.style.inset.bottom, containing.height);
    const horizontal_offset = if (writing_direction == .rtl)
        if (right) |value| -value else if (left) |value| value else 0
    else if (left) |value|
        value
    else if (right) |value|
        -value
    else
        0;
    const vertical_offset = if (top) |value|
        value
    else if (bottom) |value|
        -value
    else
        0;
    node.rect.x = try add(node.rect.x, horizontal_offset);
    node.rect.y = try add(node.rect.y, vertical_offset);
}

fn axesFor(input: style.Style) Axes {
    const horizontal = !style.directionIsColumn(input.direction);
    const inline_reverse = horizontal and input.writing_direction == .rtl;
    const cross_inline_reverse = !horizontal and input.writing_direction == .rtl;
    return .{
        .horizontal = horizontal,
        .reverse = style.directionIsReverse(input.direction) != inline_reverse,
        .cross_reverse = (input.flex_wrap == .wrap_reverse) != cross_inline_reverse,
    };
}

fn validateGaps(input: style.Style) sizing.Error!void {
    _ = try resolveGap(input.gap, null);
    _ = try resolveGap(input.column_gap, null);
    _ = try resolveGap(input.row_gap, null);
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

fn resolveGap(value: style.LengthPercentage, basis: ?f32) sizing.Error!f32 {
    return switch (value) {
        .length => |number| nonNegative(number),
        .percent => |fraction| blk: {
            const validated_fraction = try nonNegative(fraction);
            const percentage_basis = basis orelse break :blk 0;
            break :blk nonNegative(validated_fraction * try nonNegative(percentage_basis));
        },
    };
}

fn gapMainValue(
    node: *const widget.WidgetNode,
    axes: Axes,
) style.LengthPercentage {
    const axis = if (axes.horizontal) node.style.column_gap else node.style.row_gap;
    return selectAxisGap(axis, node.style.gap);
}

fn gapMain(
    node: *const widget.WidgetNode,
    axes: Axes,
    basis: ?f32,
) sizing.Error!f32 {
    return resolveGap(gapMainValue(node, axes), basis);
}
fn mainWritingReverse(axes: Axes, direction: style.Direction) bool {
    return axes.horizontal and direction == .rtl;
}

fn gapCross(
    node: *const widget.WidgetNode,
    axes: Axes,
    basis: ?f32,
) sizing.Error!f32 {
    const axis = if (axes.horizontal) node.style.row_gap else node.style.column_gap;
    return resolveGap(selectAxisGap(axis, node.style.gap), basis);
}

fn axisMain(axes: Axes, value: widget.Size) f32 {
    return if (axes.horizontal) value.width else value.height;
}

fn axisCross(axes: Axes, value: widget.Size) f32 {
    return if (axes.horizontal) value.height else value.width;
}

fn fromAxes(axes: Axes, main: f32, cross: f32) sizing.Error!widget.Size {
    return if (axes.horizontal)
        .{ .width = try nonNegative(main), .height = try nonNegative(cross) }
    else
        .{ .width = try nonNegative(cross), .height = try nonNegative(main) };
}

fn marginStart(axes: Axes, margins: Margins) f32 {
    if (axes.horizontal) return if (axes.reverse) margins.value.right else margins.value.left;
    return if (axes.reverse) margins.value.bottom else margins.value.top;
}

fn marginEnd(axes: Axes, margins: Margins) f32 {
    if (axes.horizontal) return if (axes.reverse) margins.value.left else margins.value.right;
    return if (axes.reverse) margins.value.top else margins.value.bottom;
}

fn crossStart(axes: Axes, margins: Margins) f32 {
    if (axes.horizontal) return if (axes.cross_reverse) margins.value.bottom else margins.value.top;
    return if (axes.cross_reverse) margins.value.right else margins.value.left;
}

fn crossEnd(axes: Axes, margins: Margins) f32 {
    if (axes.horizontal) return if (axes.cross_reverse) margins.value.top else margins.value.bottom;
    return if (axes.cross_reverse) margins.value.left else margins.value.right;
}

fn marginStartAuto(axes: Axes, margins: Margins) bool {
    if (axes.horizontal) return if (axes.reverse) margins.right_auto else margins.left_auto;
    return if (axes.reverse) margins.bottom_auto else margins.top_auto;
}

fn marginEndAuto(axes: Axes, margins: Margins) bool {
    if (axes.horizontal) return if (axes.reverse) margins.left_auto else margins.right_auto;
    return if (axes.reverse) margins.top_auto else margins.bottom_auto;
}

fn crossStartAuto(axes: Axes, margins: Margins) bool {
    if (axes.horizontal) return if (axes.cross_reverse) margins.bottom_auto else margins.top_auto;
    return if (axes.cross_reverse) margins.right_auto else margins.left_auto;
}

fn crossEndAuto(axes: Axes, margins: Margins) bool {
    if (axes.horizontal) return if (axes.cross_reverse) margins.top_auto else margins.bottom_auto;
    return if (axes.cross_reverse) margins.left_auto else margins.right_auto;
}

fn isAuto(value: style.LengthPercentageAuto) bool {
    return switch (value) {
        .auto => true,
        .length, .percent => false,
    };
}

fn dimensionAuto(value: style.Dimension) bool {
    return switch (value) {
        .auto => true,
        .length, .percent, .min_content, .max_content, .fit_content => false,
    };
}

fn alignValue(
    self: style.AlignSelf,
    parent: style.Align,
    directions_match: bool,
    alignment_axis_inline: bool,
) style.Align {
    const value: style.Align = switch (self) {
        .auto => parent,
        .stretch => .stretch,
        .start => .start,
        .flex_start => .flex_start,
        .center => .center,
        .safe_center => .safe_center,
        .unsafe_center => .unsafe_center,
        .end => .end,
        .flex_end => .flex_end,
        .safe_end => .safe_end,
        .unsafe_end => .unsafe_end,
        .self_start => .self_start,
        .self_end => .self_end,
        .baseline => .baseline,
    };
    return switch (value) {
        .stretch,
        .start,
        .flex_start,
        .center,
        .safe_center,
        .unsafe_center,
        .end,
        .flex_end,
        .safe_end,
        .unsafe_end,
        .baseline,
        => value,
        .self_start => if (!alignment_axis_inline or directions_match) .start else .end,
        .self_end => if (!alignment_axis_inline or directions_match) .end else .start,
    };
}

fn justify(
    value: style.Justify,
    free: f32,
    count: usize,
    flex_reverse: bool,
    writing_reverse: bool,
) sizing.Error!Distribution {
    if (count == 0) return .{ .offset = 0, .gap = 0 };
    const count_f = try countToF32(count);
    const distributed_free = @max(0, free);
    const start_offset = staticStartOffset(free, flex_reverse, writing_reverse);
    const end_offset = staticEndOffset(free, flex_reverse, writing_reverse);
    return switch (value) {
        .normal, .flex_start => .{ .offset = 0, .gap = 0 },
        .start => .{ .offset = start_offset, .gap = 0 },
        .safe_center => .{ .offset = try finite(distributed_free / 2), .gap = 0 },
        .center, .unsafe_center => .{ .offset = try finite(free / 2), .gap = 0 },
        .end, .unsafe_end => .{ .offset = end_offset, .gap = 0 },
        .flex_end => .{ .offset = free, .gap = 0 },
        .safe_end => .{ .offset = if (free < 0) start_offset else end_offset, .gap = 0 },
        .space_between => if (count > 1)
            .{
                .offset = 0,
                .gap = try finite(distributed_free / (try countToF32(count - 1))),
            }
        else
            .{ .offset = 0, .gap = 0 },
        .space_around => .{
            .offset = try finite(distributed_free / count_f / 2),
            .gap = try finite(distributed_free / count_f),
        },
        .space_evenly => .{
            .offset = try finite(distributed_free / (count_f + 1)),
            .gap = try finite(distributed_free / (count_f + 1)),
        },
    };
}

fn hasAuto(items: []const Item) bool {
    for (items) |item| {
        if (item.main_start_auto or item.main_end_auto) return true;
    }
    return false;
}

fn countToF32(value: usize) sizing.Error!f32 {
    if (value == 1 << 24) return 16_777_216;
    const exact: u24 = std.math.cast(u24, value) orelse return error.InvalidStyle;
    return @floatFromInt(exact);
}

fn gaps(gap: f32, count: usize) sizing.Error!f32 {
    if (count <= 1) return 0;
    return finite(gap * (try countToF32(count - 1)));
}

fn position(logical: f32, size: f32, available: f32, reverse: bool) sizing.Error!f32 {
    return if (reverse) finite(available - logical - size) else finite(logical);
}

fn clamp(value: f32, minimum: f32, maximum: ?f32) sizing.Error!f32 {
    var result = try nonNegative(value);
    if (maximum) |upper| result = @min(result, try nonNegative(upper));
    return @max(result, try nonNegative(minimum));
}

fn ratio(value: f32) sizing.Error!f32 {
    const result = try finite(value);
    if (result <= 0) return error.InvalidStyle;
    return result;
}

fn checkRect(value: widget.Rect) sizing.Error!void {
    _ = try finite(value.x);
    _ = try finite(value.y);
    _ = try nonNegative(value.w);
    _ = try nonNegative(value.h);
}

fn add(left: f32, right: f32) sizing.Error!f32 {
    return finite(left + right);
}

fn nonNegative(value: f32) sizing.Error!f32 {
    const result = try finite(value);
    if (result < 0) return error.InvalidStyle;
    return result;
}

fn finite(value: f32) sizing.Error!f32 {
    if (!std.math.isFinite(value)) return error.InvalidStyle;
    return value;
}
