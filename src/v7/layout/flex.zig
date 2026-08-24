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
    intrinsic_width: bool = false,
    intrinsic_height: bool = false,
};

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
    if (tree.nodes.items[index].layout_hidden) return;

    var cache: std.ArrayList(Natural) = .empty;
    defer cache.deinit(options.allocator);
    cache.resize(options.allocator, tree.nodes.items.len) catch return error.InvalidStyle;
    for (cache.items) |*entry| entry.* = .{
        .content = .{ .width = 0, .height = 0 },
        .border = .{ .width = 0, .height = 0 },
    };

    const intrinsic = try measureNode(
        tree,
        index,
        options.available,
        options,
        cache.items,
        tree.nodes.items.len,
        null,
    );
    const edges = try resolveEdges(tree.nodes.items[index].style, options.available.width);
    const size = forced_border orelse try usedSize(
        tree.nodes.items[index].style,
        options.available,
        intrinsic.content,
        edges,
        options.available,
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
        options,
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
    cache.resize(context.allocator, tree.nodes.items.len) catch return error.InvalidStyle;
    for (cache.items) |*entry| entry.* = .{
        .content = .{ .width = 0, .height = 0 },
        .border = .{ .width = 0, .height = 0 },
    };

    const natural = try measureNode(
        tree,
        index,
        request.available,
        .{
            .allocator = context.allocator,
            .available = request.available,
            .measure = context.measure,
            .context = context,
            .intrinsic_width = request.intrinsic_width,
            .intrinsic_height = request.intrinsic_height,
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

const Constraint = struct {
    min: f32,
    max: ?f32,
};

const Constraints = struct {
    main: Constraint,
    cross: Constraint,
};

const Item = struct {
    index: usize,
    base: f32,
    size: f32,
    proposed: f32,
    cross: f32,
    main_min: f32,
    main_max: ?f32,
    cross_min: f32,
    cross_max: ?f32,
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
};

const Line = struct {
    start: usize,
    count: usize,
    cross: f32 = 0,
    position: f32 = 0,
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
}

fn markHidden(
    tree: *widget.WidgetTree,
    index: usize,
    inherited: bool,
    depth: usize,
) sizing.Error!void {
    if (depth == 0) return error.InvalidStyle;
    const hidden = inherited or tree.nodes.items[index].style.display == .none;
    tree.nodes.items[index].layout_hidden = hidden;
    if (hidden) {
        tree.nodes.items[index].rect = .{};
        tree.nodes.items[index].natural_main = 0;
        tree.nodes.items[index].resolved_box_edges = null;
    }
    for (tree.nodes.items[index].children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        try markHidden(tree, child_index, hidden, depth - 1);
    }
}
fn measureNode(
    tree: *widget.WidgetTree,
    index: usize,
    containing: widget.Size,
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
    const edges = try resolveEdges(node.style, containing.width);
    var content: widget.Size = .{ .width = 0, .height = 0 };
    if (node.children.items.len == 0) {
        content = try measureLeaf(node, options.measure);
    } else if (options.context) |context| {
        if (parent_display) |display| {
            if (node.style.display != display) {
                const measured = try context.measure_node(
                    context,
                    tree,
                    node,
                    .{
                        .available = containing,
                        .percentage_basis = .{
                            .width = containing.width,
                            .height = containing.height,
                        },
                    },
                );
                cache[index] = .{
                    .content = measured.content,
                    .border = measured.border,
                };
                return cache[index];
            }
        }
        if (node.style.display != .flex) return error.InvalidStyle;
        content = try measureContainerContent(
            tree,
            index,
            containing,
            edges,
            options,
            cache,
            depth - 1,
        );
    } else {
        if (node.style.display != .flex) return error.InvalidStyle;
        content = try measureContainerContent(
            tree,
            index,
            containing,
            edges,
            options,
            cache,
            depth - 1,
        );
    }
    const border = try usedSize(node.style, containing, content, edges, null);
    cache[index] = .{ .content = content, .border = border };
    return cache[index];
}

fn measureLeaf(node: *const widget.WidgetNode, measure: ?MeasureFn) sizing.Error!widget.Size {
    var result: widget.Size = switch (node.kind) {
        .label => |label| if (measure) |callback| callback(
            label.text,
            node.font_size,
            node.font_id,
        ) else blk: {
            const font_size = try finite(node.font_size);
            if (font_size < 0) return error.InvalidStyle;
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
        if (node.text_overflow != .visible) result.width = @min(
            result.width,
            try nonNegative(maximum),
        );
    }
    return result;
}

fn measureContainerContent(
    tree: *widget.WidgetTree,
    index: usize,
    containing: widget.Size,
    edges: Edges,
    options: Options,
    cache: []Natural,
    depth: usize,
) sizing.Error!widget.Size {
    const node = &tree.nodes.items[index];
    const axes = axesFor(node.style);
    const preferred_width = try resolveDimensionBorder(
        node.style.size.width,
        containing.width,
        0,
        edges.horizontal,
        node.style.box_sizing,
    );
    const preferred_height = try resolveDimensionBorder(
        node.style.size.height,
        containing.height,
        0,
        edges.vertical,
        node.style.box_sizing,
    );
    const minimum_width = (try resolveDimensionBorder(
        node.style.min_size.width,
        containing.width,
        0,
        edges.horizontal,
        node.style.box_sizing,
    )) orelse 0;
    const minimum_height = (try resolveDimensionBorder(
        node.style.min_size.height,
        containing.height,
        0,
        edges.vertical,
        node.style.box_sizing,
    )) orelse 0;
    const maximum_width = try resolveDimensionBorder(
        node.style.max_size.width,
        containing.width,
        0,
        edges.horizontal,
        node.style.box_sizing,
    );
    const maximum_height = try resolveDimensionBorder(
        node.style.max_size.height,
        containing.height,
        0,
        edges.vertical,
        node.style.box_sizing,
    );
    const measured_border: widget.Size = .{
        .width = try clamp(preferred_width orelse containing.width, minimum_width, maximum_width),
        .height = try clamp(
            preferred_height orelse containing.height,
            minimum_height,
            maximum_height,
        ),
    };
    const available: widget.Size = .{
        .width = @max(0, measured_border.width - edges.horizontal),
        .height = @max(0, measured_border.height - edges.vertical),
    };
    const available_main = axisMain(axes, available);
    const main_gap = try gapMain(node, axes);
    const cross_gap = try gapCross(node, axes);
    const auto_main = dimensionAuto(if (axes.horizontal)
        node.style.size.width
    else
        node.style.size.height);
    const intrinsic_main = if (axes.horizontal)
        options.intrinsic_width
    else
        options.intrinsic_height;
    var line_main: f32 = 0;
    var line_cross: f32 = 0;
    var total_main: f32 = 0;
    var total_cross: f32 = 0;
    var unwrapped_main: f32 = 0;
    var line_items: usize = 0;
    var line_count: usize = 0;

    for (node.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        const child = &tree.nodes.items[child_index];
        if (child.layout_hidden or child.style.position == .absolute) continue;
        const natural = try measureNode(
            tree,
            child_index,
            available,
            options,
            cache,
            depth,
            node.style.display,
        );
        const margins = try resolveMargins(child.style, available.width);
        const outer_main = try add(
            try add(axisMain(axes, natural.border), marginStart(axes, margins)),
            marginEnd(axes, margins),
        );
        const outer_cross = try add(
            try add(axisCross(axes, natural.border), crossStart(axes, margins)),
            crossEnd(axes, margins),
        );
        unwrapped_main = if (line_items == 0)
            outer_main
        else
            try add(try add(unwrapped_main, main_gap), outer_main);
        const candidate = if (line_items == 0)
            outer_main
        else
            try add(try add(line_main, main_gap), outer_main);
        if (!intrinsic_main and effectiveWrap(node.style) != .nowrap and
            line_items != 0 and candidate > available_main)
        {
            total_main = @max(total_main, line_main);
            if (line_count != 0) total_cross = try add(total_cross, cross_gap);
            total_cross = try add(total_cross, line_cross);
            line_count += 1;
            line_main = outer_main;
            line_cross = outer_cross;
            line_items = 1;
        } else {
            line_main = candidate;
            line_cross = @max(line_cross, outer_cross);
            line_items += 1;
        }
    }
    if (line_items != 0) {
        total_main = @max(total_main, line_main);
        if (line_count != 0) total_cross = try add(total_cross, cross_gap);
        total_cross = try add(total_cross, line_cross);
    }
    const content_main = if (effectiveWrap(node.style) != .nowrap and auto_main)
        if (intrinsic_main) unwrapped_main else @min(unwrapped_main, available_main)
    else
        total_main;
    return fromAxes(axes, content_main, total_cross);
}

fn layoutFlex(
    tree: *widget.WidgetTree,
    index: usize,
    containing: widget.Size,
    border_size: widget.Size,
    options: Options,
    cache: []Natural,
    depth: usize,
) sizing.Error!void {
    if (depth == 0) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    if (node.layout_hidden) return;
    if (node.style.display != .flex) return error.InvalidStyle;
    const edges = try resolveEdges(node.style, containing.width);
    node.resolved_box_edges = .{ .border = edges.border, .padding = edges.padding };
    node.rect.w = try nonNegative(border_size.width);
    node.rect.h = try nonNegative(border_size.height);
    const content: widget.Size = .{
        .width = @max(0, node.rect.w - edges.horizontal),
        .height = @max(0, node.rect.h - edges.vertical),
    };
    node.resolveTypedStyle(containing, content);
    const axes = axesFor(node.style);
    const main_size = axisMain(axes, content);
    const cross_size = axisCross(axes, content);
    const main_gap = try gapMain(node, axes);
    const cross_gap = try gapCross(node, axes);

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
        effectiveWrap(node.style),
        main_size,
        main_gap,
    );
    for (lines.items) |line| {
        try resolveLine(
            items.items[line.start .. line.start + line.count],
            main_size,
            main_gap,
        );
    }
    if (options.context) |context| {
        for (items.items) |*item| {
            const child = &tree.nodes.items[item.index];
            if (child.children.items.len == 0 or child.style.display == .flex) continue;
            const remeasure_available: widget.Size = if (axes.horizontal)
                .{ .width = item.size, .height = cross_size }
            else
                .{ .width = cross_size, .height = item.size };
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
                    .intrinsic_width = false,
                    .intrinsic_height = false,
                },
            );
            item.cross = try clamp(
                axisCross(axes, measured.border),
                item.cross_min,
                item.cross_max,
            );
        }
    }
    try lineCrossSizes(lines.items, items.items, cross_size, cross_gap);
    try lineDistribution(lines.items, node.style.align_content, cross_size, cross_gap);
    try placeItems(tree, node, axes, content, lines.items, items.items, main_gap);

    for (items.items) |item| {
        const child = &tree.nodes.items[item.index];
        if (child.children.items.len == 0) continue;
        if (options.context) |context| {
            if (child.style.display != .flex) {
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
        try layoutFlex(
            tree,
            item.index,
            content,
            .{ .width = child.rect.w, .height = child.rect.h },
            options,
            cache,
            depth - 1,
        );
    }
    try placeAbsolute(tree, node, content, options, cache, depth - 1);
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
    for (container.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        const child = &tree.nodes.items[child_index];
        if (child.layout_hidden or child.style.position == .absolute) continue;
        const natural = try measureNode(
            tree,
            child_index,
            content,
            options,
            cache,
            depth,
            container.style.display,
        );
        const edges = try resolveEdges(child.style, content.width);
        child.resolved_box_edges = .{ .border = edges.border, .padding = edges.padding };
        const preferred = try usedSize(child.style, content, natural.content, edges, null);
        const margins = try resolveMargins(child.style, content.width);
        const constraints = try constraintsFor(
            child.style,
            content,
            natural.content,
            edges,
            axes,
        );
        const basis = try flexBasis(
            child.style,
            axes,
            main_content,
            axisMain(axes, preferred),
            natural,
            edges,
        );
        const item: Item = .{
            .index = child_index,
            .base = basis,
            .size = basis,
            .proposed = basis,
            .cross = try clamp(
                axisCross(axes, preferred),
                constraints.cross.min,
                constraints.cross.max,
            ),
            .main_min = constraints.main.min,
            .main_max = constraints.main.max,
            .cross_min = constraints.cross.min,
            .cross_max = constraints.cross.max,
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
        };
        child.natural_main = axisMain(axes, natural.border);
        items.append(options.allocator, item) catch return error.InvalidStyle;
    }
}

fn constraintsFor(
    input: style.Style,
    containing: widget.Size,
    intrinsic: widget.Size,
    edges: Edges,
    axes: Axes,
) sizing.Error!Constraints {
    const min_width = (try resolveDimensionBorder(
        input.min_size.width,
        containing.width,
        intrinsic.width,
        edges.horizontal,
        input.box_sizing,
    )) orelse 0;
    const min_height = (try resolveDimensionBorder(
        input.min_size.height,
        containing.height,
        intrinsic.height,
        edges.vertical,
        input.box_sizing,
    )) orelse 0;
    const max_width = try resolveDimensionBorder(
        input.max_size.width,
        containing.width,
        intrinsic.width,
        edges.horizontal,
        input.box_sizing,
    );
    const max_height = try resolveDimensionBorder(
        input.max_size.height,
        containing.height,
        intrinsic.height,
        edges.vertical,
        input.box_sizing,
    );
    var result: Constraints = if (axes.horizontal)
        Constraints{
            .main = .{ .min = try nonNegative(min_width), .max = max_width },
            .cross = .{ .min = try nonNegative(min_height), .max = max_height },
        }
    else
        Constraints{
            .main = .{ .min = try nonNegative(min_height), .max = max_height },
            .cross = .{ .min = try nonNegative(min_width), .max = max_width },
        };
    if (input.min_main) |minimum| {
        result.main.min = @max(result.main.min, try nonNegative(minimum));
    }
    return result;
}

fn flexBasis(
    input: style.Style,
    axes: Axes,
    containing_main: f32,
    preferred: f32,
    natural: Natural,
    edges: Edges,
) sizing.Error!f32 {
    const edge_sum = if (axes.horizontal) edges.horizontal else edges.vertical;
    const intrinsic = if (axes.horizontal) natural.content.width else natural.content.height;
    const basis = switch (input.flex_basis) {
        .auto => null,
        .length, .percent, .min_content, .max_content => try resolveDimensionBorder(
            input.flex_basis,
            containing_main,
            intrinsic,
            edge_sum,
            input.box_sizing,
        ),
    };
    if (basis) |value| return nonNegative(value);
    if (input.basis != 0) {
        return sizingToBorder(
            try nonNegative(input.basis),
            edge_sum,
            input.box_sizing,
        );
    }
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
        const outer = try add(
            try add(try clamp(item.base, item.main_min, item.main_max), item.margin_start),
            item.margin_end,
        );
        const candidate = if (index == start)
            outer
        else
            try add(try add(used, gap), outer);
        if (wrap != .nowrap and index != start and candidate > available) {
            lines.append(allocator, .{ .start = start, .count = index - start }) catch {
                return error.InvalidStyle;
            };
            start = index;
            used = outer;
        } else {
            used = candidate;
        }
    }
    lines.append(allocator, .{ .start = start, .count = items.len - start }) catch {
        return error.InvalidStyle;
    };
}

fn resolveLine(items: []Item, available: f32, gap: f32) sizing.Error!void {
    for (items) |*item| {
        item.size = try clamp(item.base, item.main_min, item.main_max);
        item.frozen = item.size != item.base;
    }

    var iteration: usize = 0;
    while (iteration <= items.len) : (iteration += 1) {
        var used = try gaps(gap, items.len);
        for (items) |item| {
            used = try add(used, item.size);
            used = try add(used, item.margin_start);
            used = try add(used, item.margin_end);
        }
        const free = try finite(available - used);
        if (free == 0) break;
        const growing = free > 0;
        var weight_sum: f32 = 0;
        for (items) |item| {
            if (item.frozen) continue;
            const weight = if (growing) item.grow else item.shrink * item.base;
            weight_sum = try add(weight_sum, weight);
        }
        if (weight_sum <= 0) break;

        var clamped_any = false;
        for (items) |*item| {
            if (item.frozen) continue;
            const weight = if (growing) item.grow else item.shrink * item.base;
            item.proposed = try finite(item.base + free * weight / weight_sum);
            const target = try clamp(item.proposed, item.main_min, item.main_max);
            if (target != item.proposed) {
                item.size = target;
                item.frozen = true;
                clamped_any = true;
            }
        }
        if (!clamped_any) {
            for (items) |*item| {
                if (!item.frozen) item.size = item.proposed;
            }
            break;
        }
    }

    var used = try gaps(gap, items.len);
    var auto_count: usize = 0;
    for (items) |item| {
        used = try add(used, item.size);
        used = try add(used, item.margin_start);
        used = try add(used, item.margin_end);
        if (item.main_start_auto) auto_count += 1;
        if (item.main_end_auto) auto_count += 1;
    }
    const free = @max(0, try finite(available - used));
    if (auto_count != 0 and free > 0) {
        const share = free / @as(f32, @floatFromInt(auto_count));
        for (items) |*item| {
            if (item.main_start_auto) item.margin_start = share;
            if (item.main_end_auto) item.margin_end = share;
        }
    }
}

fn lineCrossSizes(
    lines: []Line,
    items: []const Item,
    available: f32,
    gap: f32,
) sizing.Error!void {
    for (lines) |*line| {
        for (items[line.start .. line.start + line.count]) |item| {
            const outer = try add(
                try add(item.cross, item.cross_margin_start),
                item.cross_margin_end,
            );
            line.cross = @max(line.cross, outer);
        }
    }
    if (lines.len == 1) lines[0].cross = available;
    var total = try gaps(gap, lines.len);
    for (lines) |line| total = try add(total, line.cross);
    _ = try finite(total);
}

fn lineDistribution(
    lines: []Line,
    align_content: style.AlignContent,
    available: f32,
    gap: f32,
) sizing.Error!void {
    if (lines.len == 0) return;
    var used = try gaps(gap, lines.len);
    for (lines) |line| used = try add(used, line.cross);
    var free = @max(0, try finite(available - used));
    var offset: f32 = 0;
    var extra: f32 = 0;
    switch (align_content) {
        .stretch => {
            if (free > 0) {
                const addition = free / @as(f32, @floatFromInt(lines.len));
                for (lines) |*line| line.cross = try add(line.cross, addition);
                free = 0;
            }
        },
        .start => {},
        .center => offset = free / 2,
        .end => offset = free,
        .space_between => {
            if (lines.len > 1) {
                extra = free / @as(f32, @floatFromInt(lines.len - 1));
            }
        },
        .space_around => {
            extra = free / @as(f32, @floatFromInt(lines.len));
            offset = extra / 2;
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
            used = try add(used, item.size);
            used = try add(used, item.margin_start);
            used = try add(used, item.margin_end);
        }
        const free = @max(0, try finite(main_available - used));
        const distribution = if (hasAuto(line_items))
            Distribution{ .offset = 0, .gap = 0 }
        else
            try justify(container.style.justify, free, line_items.len);
        var cursor = distribution.offset;

        for (line_items, 0..) |*item, item_index| {
            cursor = try add(cursor, item.margin_start);
            const logical_main = cursor;
            cursor = try add(cursor, item.size);
            cursor = try add(cursor, item.margin_end);
            if (item_index + 1 < line_items.len) {
                cursor = try add(cursor, gap);
                cursor = try add(cursor, distribution.gap);
            }

            const child = &tree.nodes.items[item.index];
            const alignment = alignValue(child.style.align_self, container.style.@"align");
            var cross_start = item.cross_margin_start;
            var cross_end = item.cross_margin_end;
            var cross = item.cross;
            var cross_free = @max(
                0,
                try finite(line.cross - cross - cross_start - cross_end),
            );
            if (item.cross_start_auto or item.cross_end_auto) {
                const auto_count = @as(usize, @intFromBool(item.cross_start_auto)) +
                    @as(usize, @intFromBool(item.cross_end_auto));
                if (auto_count != 0 and cross_free > 0) {
                    const share = cross_free / @as(f32, @floatFromInt(auto_count));
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
                cross_free = @max(
                    0,
                    try finite(line.cross - cross - cross_start - cross_end),
                );
            }
            const align_offset = if (item.cross_start_auto or item.cross_end_auto)
                0
            else switch (alignment) {
                .stretch, .start => 0,
                .center => cross_free / 2,
                .end => cross_free,
            };
            const logical_cross = try add(line.position, try add(cross_start, align_offset));
            const physical_main = try position(
                logical_main,
                item.size,
                main_available,
                axes.reverse,
            );
            const physical_cross = try position(
                logical_cross,
                cross,
                cross_available,
                axes.cross_reverse,
            );
            child.rect = if (axes.horizontal)
                .{ .x = physical_main, .y = physical_cross, .w = item.size, .h = cross }
            else
                .{ .x = physical_cross, .y = physical_main, .w = cross, .h = item.size };
            try relativeInsets(child, content);
            try checkRect(child.rect);
        }
    }
}

fn placeAbsolute(
    tree: *widget.WidgetTree,
    container: *const widget.WidgetNode,
    content: widget.Size,
    options: Options,
    cache: []Natural,
    depth: usize,
) sizing.Error!void {
    for (container.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        const child = &tree.nodes.items[child_index];
        if (child.layout_hidden or child.style.position != .absolute) continue;
        const natural = try measureNode(
            tree,
            child_index,
            content,
            options,
            cache,
            depth,
            container.style.display,
        );
        const edges = try resolveEdges(child.style, content.width);
        child.resolved_box_edges = .{ .border = edges.border, .padding = edges.padding };
        const size = try usedSize(child.style, content, natural.content, edges, null);
        const left = try resolveInset(child.style.inset.left, content.width);
        const right = try resolveInset(child.style.inset.right, content.width);
        const top = try resolveInset(child.style.inset.top, content.height);
        const bottom = try resolveInset(child.style.inset.bottom, content.height);
        const margins = try resolveMargins(child.style, content.width);
        const x = if (left) |value|
            try add(value, margins.value.left)
        else if (right) |value|
            try finite(content.width - value - margins.value.right - size.width)
        else
            margins.value.left;
        const y = if (top) |value|
            try add(value, margins.value.top)
        else if (bottom) |value|
            try finite(content.height - value - margins.value.bottom - size.height)
        else
            margins.value.top;
        child.rect = .{ .x = x, .y = y, .w = size.width, .h = size.height };
        try checkRect(child.rect);
        if (child.children.items.len != 0) {
            if (options.context) |context| {
                if (child.style.display != .flex) {
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
            try layoutFlex(tree, child_index, content, size, options, cache, depth);
        }
    }
}
fn usedSize(
    input: style.Style,
    containing: widget.Size,
    intrinsic: widget.Size,
    edges: Edges,
    fallback: ?widget.Size,
) sizing.Error!widget.Size {
    var width = try dimensionValue(input.size.width, containing.width, intrinsic.width);
    var height = try dimensionValue(input.size.height, containing.height, intrinsic.height);
    if (width == null) {
        width = if (fallback) |value|
            try borderToSizing(value.width, edges.horizontal, input.box_sizing)
        else
            try contentToBorder(intrinsic.width, edges.horizontal, input.box_sizing);
    }
    if (height == null and input.aspect_ratio != null and width != null) {
        height = try finite(width.? / try ratio(input.aspect_ratio.?));
    }
    if (height == null) {
        height = if (fallback) |value|
            try borderToSizing(value.height, edges.vertical, input.box_sizing)
        else
            try contentToBorder(intrinsic.height, edges.vertical, input.box_sizing);
    }
    if (width == null and input.aspect_ratio != null and height != null) {
        width = try finite(height.? * try ratio(input.aspect_ratio.?));
    }
    var result: widget.Size = .{
        .width = try sizingToBorder(width.?, edges.horizontal, input.box_sizing),
        .height = try sizingToBorder(height.?, edges.vertical, input.box_sizing),
    };
    result.width = try clampSize(
        input,
        .horizontal,
        result.width,
        containing,
        intrinsic,
        edges,
    );
    result.height = try clampSize(
        input,
        .vertical,
        result.height,
        containing,
        intrinsic,
        edges,
    );
    return .{
        .width = @max(edges.horizontal, result.width),
        .height = @max(edges.vertical, result.height),
    };
}

const PhysicalAxis = enum { horizontal, vertical };

fn clampSize(
    input: style.Style,
    axis: PhysicalAxis,
    candidate: f32,
    containing: widget.Size,
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
    const basis = if (axis == .horizontal) containing.width else containing.height;
    const natural = if (axis == .horizontal) intrinsic.width else intrinsic.height;
    const edge_sum = if (axis == .horizontal) edges.horizontal else edges.vertical;
    const minimum = (try resolveDimensionBorder(
        minimum_dimension,
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
    return clamp(candidate, minimum, maximum);
}

fn dimensionValue(
    dimension: style.Dimension,
    containing: f32,
    intrinsic: f32,
) sizing.Error!?f32 {
    return switch (dimension) {
        .auto => null,
        .min_content, .max_content => try nonNegative(intrinsic),
        .length, .percent => sizing.resolveDimension(
            dimension,
            .{ .definite = containing },
            containing,
        ),
    };
}

fn resolveDimensionBorder(
    dimension: style.Dimension,
    containing: f32,
    intrinsic: f32,
    edges: f32,
    box_sizing: style.BoxSizing,
) sizing.Error!?f32 {
    const value = try dimensionValue(dimension, containing, intrinsic);
    if (value) |number| {
        const border = try sizingToBorder(number, edges, box_sizing);
        return @as(?f32, border);
    }
    return null;
}

fn contentToBorder(
    content: f32,
    edges: f32,
    box_sizing: style.BoxSizing,
) sizing.Error!f32 {
    return switch (box_sizing) {
        .content_box => add(try nonNegative(content), edges),
        .border_box => @max(edges, try nonNegative(content)),
    };
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

fn resolveEdges(input: style.Style, basis: f32) sizing.Error!Edges {
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

fn edge(
    value: style.LengthPercentage,
    legacy: f32,
    basis: f32,
) sizing.Error!f32 {
    return switch (value) {
        .length => |number| nonNegative(if (number == 0 and legacy != 0) legacy else number),
        .percent => |fraction| nonNegative(try finite(fraction * basis)),
    };
}

fn resolveMargins(input: style.Style, basis: f32) sizing.Error!Margins {
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

fn margin(
    value: style.LengthPercentageAuto,
    legacy: f32,
    basis: f32,
) sizing.Error!f32 {
    return switch (value) {
        .auto => 0,
        .length => |number| finite(if (number == 0 and legacy != 0) legacy else number),
        .percent => |fraction| finite(fraction * basis),
    };
}

fn resolveInset(value: style.LengthPercentageAuto, basis: f32) sizing.Error!?f32 {
    return switch (value) {
        .auto => null,
        .length => |number| try finite(number),
        .percent => |fraction| try finite(fraction * basis),
    };
}
fn relativeInsets(node: *widget.WidgetNode, containing: widget.Size) sizing.Error!void {
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

fn axesFor(input: style.Style) Axes {
    const horizontal = !style.directionIsColumn(input.direction);
    const inline_reverse = horizontal and input.writing_direction == .rtl;
    const cross_inline_reverse = !horizontal and input.writing_direction == .rtl;
    return .{
        .horizontal = horizontal,
        .reverse = style.directionIsReverse(input.direction) != inline_reverse,
        .cross_reverse = (effectiveWrap(input) == .wrap_reverse) != cross_inline_reverse,
    };
}

fn effectiveWrap(input: style.Style) style.FlexWrap {
    return if (input.flex_wrap != .nowrap) input.flex_wrap else input.wrap;
}

fn gapMain(node: *const widget.WidgetNode, axes: Axes) sizing.Error!f32 {
    const general = if (node.style.gap != 0)
        node.style.gap
    else switch (node.kind) {
        .row => |value| value.gap,
        .column => |value| value.gap,
        else => 0,
    };
    const selected = if (axes.horizontal and node.style.column_gap != 0)
        node.style.column_gap
    else if (!axes.horizontal and node.style.row_gap != 0)
        node.style.row_gap
    else
        general;
    return nonNegative(selected);
}

fn gapCross(node: *const widget.WidgetNode, axes: Axes) sizing.Error!f32 {
    const general = if (node.style.gap != 0)
        node.style.gap
    else switch (node.kind) {
        .row => |value| value.gap,
        .column => |value| value.gap,
        else => 0,
    };
    const selected = if (axes.horizontal and node.style.row_gap != 0)
        node.style.row_gap
    else if (!axes.horizontal and node.style.column_gap != 0)
        node.style.column_gap
    else
        general;
    return nonNegative(selected);
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
        .length, .percent, .min_content, .max_content => false,
    };
}

fn alignValue(self: style.AlignSelf, parent: style.Align) style.Align {
    return switch (self) {
        .auto => parent,
        .stretch => .stretch,
        .start => .start,
        .center => .center,
        .end => .end,
    };
}

fn justify(value: style.Justify, free: f32, count: usize) sizing.Error!Distribution {
    if (count == 0) return .{ .offset = 0, .gap = 0 };
    const count_f: f32 = @floatFromInt(count);
    return switch (value) {
        .start => .{ .offset = 0, .gap = 0 },
        .center => .{ .offset = free / 2, .gap = 0 },
        .end => .{ .offset = free, .gap = 0 },
        .space_between => if (count > 1)
            .{ .offset = 0, .gap = try finite(free / @as(f32, @floatFromInt(count - 1))) }
        else
            .{ .offset = 0, .gap = 0 },
        .space_around => .{
            .offset = try finite(free / count_f / 2),
            .gap = try finite(free / count_f),
        },
        .space_evenly => .{
            .offset = try finite(free / (count_f + 1)),
            .gap = try finite(free / (count_f + 1)),
        },
    };
}

fn hasAuto(items: []const Item) bool {
    for (items) |item| {
        if (item.main_start_auto or item.main_end_auto) return true;
    }
    return false;
}

fn gaps(gap: f32, count: usize) sizing.Error!f32 {
    if (count <= 1) return 0;
    return finite(gap * @as(f32, @floatFromInt(count - 1)));
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
