const std = @import("std");
const Id = @import("../id.zig").Id;
const block_float = @import("block_float.zig");
const context = @import("context.zig");
const flex = @import("flex.zig");
const grid = @import("grid.zig");
const sizing = @import("sizing.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");

pub const Options = struct {
    allocator: std.mem.Allocator,
    available: widget.Size,
    measure: ?context.MeasureFn,
};

pub const LayoutError = context.LayoutError;

const Edges = struct {
    border: style.Sides,
    padding: style.Sides,
    horizontal: f32,
    vertical: f32,
};
const RootMeasurement = struct {
    natural: context.Measured,
    width: f32,
};

pub fn layoutTree(tree: *widget.WidgetTree, options: Options) LayoutError!void {
    try validateAvailable(options.available);
    var roots = try validateTree(options.allocator, tree);
    defer roots.deinit(options.allocator);
    for (roots.items) |root_index| {
        try markHidden(tree, root_index, false, tree.nodes.items.len + 1);
    }

    var layout_context: context.LayoutContext = .{
        .allocator = options.allocator,
        .measure = options.measure,
        .measure_node = measureNodeCallback,
        .layout_node = layoutNodeCallback,
    };
    var items: std.ArrayList(RootItem) = .empty;
    defer items.deinit(options.allocator);
    for (roots.items) |root_index| {
        const node = &tree.nodes.items[root_index];
        if (node.layout_hidden) continue;
        const margins = try resolveRootMargins(node.style, options.available.width);
        const absolute = node.style.position == .absolute;
        const measured_root: RootMeasurement = if (absolute) blk: {
            const natural = try layout_context.measure_node(
                &layout_context,
                tree,
                node,
                .{
                    .available = options.available,
                    .percentage_basis = .{
                        .width = options.available.width,
                        .height = options.available.height,
                    },
                },
            );
            break :blk .{
                .natural = natural,
                .width = try rootWidth(
                    node.style,
                    natural,
                    options.available,
                    margins,
                ),
            };
        } else blk: {
            const width = try rootSizeFromInsets(
                options.available.width,
                0,
                0,
                margins.left,
                margins.right,
            );
            const natural = try layout_context.measure_node(
                &layout_context,
                tree,
                node,
                .{
                    .available = .{
                        .width = width,
                        .height = options.available.height,
                    },
                    .percentage_basis = .{
                        .width = width,
                        .height = options.available.height,
                    },
                    .intrinsic_width = false,
                    .intrinsic_height = false,
                },
            );
            break :blk .{
                .natural = natural,
                .width = width,
            };
        };
        const natural = measured_root.natural;
        const used_width = measured_root.width;
        const edge_basis = if (absolute) options.available.width else used_width;
        const edges = try resolveEdges(node.style, edge_basis);
        const base_height = if (absolute)
            try absoluteRootBaseHeight(
                node.style,
                natural,
                options.available,
                edges.vertical,
            )
        else
            try rootBaseHeight(
                node.style,
                natural,
                options.available,
                edges.vertical,
            );
        const min_height = if (absolute)
            try absoluteRootMinHeight(
                node.style,
                natural,
                options.available,
                edges.vertical,
            )
        else
            try rootMinHeight(
                node.style,
                natural,
                options.available,
                edges.vertical,
            );
        const max_height = try rootMaxHeight(
            node.style,
            natural,
            options.available,
            edges.vertical,
        );
        if (!std.math.isFinite(node.style.grow) or node.style.grow < 0) {
            return error.InvalidStyle;
        }
        if (!std.math.isFinite(node.style.shrink) or node.style.shrink < 0) {
            return error.InvalidStyle;
        }
        items.append(options.allocator, .{
            .index = root_index,
            .natural = natural,
            .margins = margins,
            .width = used_width,
            .base_height = base_height,
            .height = clampRoot(base_height, min_height, max_height),
            .min_height = min_height,
            .shrink_floor = if (absolute)
                min_height
            else
                rootShrinkFloor(node.style, natural, min_height),
            .max_height = max_height,
            .grow = node.style.grow,
            .shrink = node.style.shrink,
            .absolute = absolute,
            .frozen = false,
        }) catch return error.InvalidStyle;
    }

    try resolveRootHeights(&items, options.available.height);
    var flow_cursor: f32 = 0;
    for (items.items) |*item| {
        const node = &tree.nodes.items[item.index];
        if (item.absolute) {
            try placeAbsoluteRoot(
                &layout_context,
                tree,
                node,
                item,
                options.available,
            );
        } else {
            try placeFlowRoot(
                &layout_context,
                tree,
                node,
                item,
                options.available,
                &flow_cursor,
            );
        }
    }
}

const RootItem = struct {
    index: usize,
    natural: context.Measured,
    margins: style.Sides,
    width: f32,
    base_height: f32,
    height: f32,
    min_height: f32,
    shrink_floor: f32,
    max_height: ?f32,
    grow: f32,
    shrink: f32,
    absolute: bool,
    frozen: bool,
};
const RootInsets = struct {
    top: ?f32,
    right: ?f32,
    bottom: ?f32,
    left: ?f32,
};

fn placeFlowRoot(
    self: *context.LayoutContext,
    tree: *widget.WidgetTree,
    node: *widget.WidgetNode,
    item: *RootItem,
    available: widget.Size,
    cursor: *f32,
) LayoutError!void {
    const y = try finiteAdd(cursor.*, item.margins.top);
    node.rect = .{
        .x = item.margins.left,
        .y = y,
        .w = item.width,
        .h = item.height,
    };
    try applyRelativeRootInset(node, available);
    try validateRootRect(node.rect);
    try self.layout_node(
        self,
        tree,
        node,
        .{
            .available = available,
            .percentage_basis = .{
                .width = available.width,
                .height = available.height,
            },
            .forced_border = .{ .width = item.width, .height = item.height },
        },
    );
    const next_cursor = try finiteAdd(y, item.height);
    cursor.* = try finiteAdd(next_cursor, item.margins.bottom);
}

fn placeAbsoluteRoot(
    self: *context.LayoutContext,
    tree: *widget.WidgetTree,
    node: *widget.WidgetNode,
    item: *RootItem,
    available: widget.Size,
) LayoutError!void {
    const insets = try resolveRootInsets(node.style, available);
    const edges = try resolveEdges(node.style, available.width);
    const min_width = (try rootDimensionBorder(
        node.style.min_size.width,
        available.width,
        item.natural.content.width,
        edges.horizontal,
        node.style.box_sizing,
    )) orelse 0;
    const max_width = try rootDimensionBorder(
        node.style.max_size.width,
        available.width,
        item.natural.content.width,
        edges.horizontal,
        node.style.box_sizing,
    );
    const width_from_insets = node.style.size.width == .auto and
        insets.left != null and insets.right != null;
    const height_from_insets = node.style.size.height == .auto and
        insets.top != null and insets.bottom != null;
    var width = if (width_from_insets)
        try rootSizeFromInsets(
            available.width,
            insets.left.?,
            insets.right.?,
            item.margins.left,
            item.margins.right,
        )
    else if (node.style.size.width == .auto)
        item.natural.border.width
    else
        item.width;
    if (width_from_insets and
        !hasIntrinsicRootConstraint(node.style.min_size.width) and
        !hasIntrinsicRootConstraint(node.style.max_size.width))
    {
        width = try clampRootFinite(width, min_width, max_width);
        item.natural = try self.measure_node(
            self,
            tree,
            node,
            .{
                .available = .{
                    .width = width,
                    .height = available.height,
                },
                .percentage_basis = .{
                    .width = width,
                    .height = available.height,
                },
                .intrinsic_width = false,
                .intrinsic_height = false,
            },
        );
    }
    const base_height = try absoluteRootBaseHeight(
        node.style,
        item.natural,
        available,
        edges.vertical,
    );
    const min_height = try absoluteRootMinHeight(
        node.style,
        item.natural,
        available,
        edges.vertical,
    );
    const max_height = try rootMaxHeight(
        node.style,
        item.natural,
        available,
        edges.vertical,
    );
    var height = if (height_from_insets)
        try rootSizeFromInsets(
            available.height,
            insets.top.?,
            insets.bottom.?,
            item.margins.top,
            item.margins.bottom,
        )
    else
        base_height;

    if (node.style.aspect_ratio) |ratio| {
        if (!std.math.isFinite(ratio) or ratio <= 0) return error.InvalidStyle;
        const width_definite = node.style.size.width != .auto;
        const height_definite = node.style.size.height != .auto;
        if ((width_definite or width_from_insets) and
            !height_definite and
            !height_from_insets)
        {
            const width_for_ratio = try borderToContent(
                width,
                edges.horizontal,
                node.style.box_sizing,
            );
            const height_for_ratio = try finiteDivide(width_for_ratio, ratio);
            height = try sizingToBorder(
                height_for_ratio,
                edges.vertical,
                node.style.box_sizing,
            );
        } else if (!width_definite and
            (height_definite or height_from_insets) and
            !width_from_insets)
        {
            const height_for_ratio = try borderToContent(
                height,
                edges.vertical,
                node.style.box_sizing,
            );
            const width_for_ratio = try finiteMultiply(height_for_ratio, ratio);
            width = try sizingToBorder(
                width_for_ratio,
                edges.horizontal,
                node.style.box_sizing,
            );
        }
    }

    width = try clampRootFinite(width, min_width, max_width);
    height = try clampRootFinite(height, min_height, max_height);
    item.width = width;
    item.height = height;
    const x = if (insets.left) |left|
        try finiteAdd(left, item.margins.left)
    else if (insets.right) |right| blk: {
        const after_right = try finiteSubtract(available.width, right);
        const after_margin = try finiteSubtract(after_right, item.margins.right);
        break :blk try finiteSubtract(after_margin, width);
    } else item.margins.left;
    const y = if (insets.top) |top|
        try finiteAdd(top, item.margins.top)
    else if (insets.bottom) |bottom| blk: {
        const after_bottom = try finiteSubtract(available.height, bottom);
        const after_margin = try finiteSubtract(after_bottom, item.margins.bottom);
        break :blk try finiteSubtract(after_margin, height);
    } else item.margins.top;
    node.rect = .{ .x = x, .y = y, .w = width, .h = height };
    try validateRootRect(node.rect);
    try self.layout_node(
        self,
        tree,
        node,
        .{
            .available = available,
            .percentage_basis = .{
                .width = available.width,
                .height = available.height,
            },
            .forced_border = .{ .width = width, .height = height },
        },
    );
}

fn resolveRootHeights(items: *std.ArrayList(RootItem), available: f32) LayoutError!void {
    var used: f32 = 0;
    for (items.items) |*item| {
        if (item.absolute) continue;
        item.height = clampRoot(item.base_height, item.min_height, item.max_height);
        item.frozen = false;
        used += item.height + item.margins.top + item.margins.bottom;
    }
    if (!std.math.isFinite(used)) return error.InvalidStyle;
    var iteration: usize = 0;
    while (iteration <= items.items.len) : (iteration += 1) {
        used = 0;
        for (items.items) |item| {
            if (item.absolute) continue;
            used += item.height + item.margins.top + item.margins.bottom;
        }
        if (!std.math.isFinite(used)) return error.InvalidStyle;
        const free = available - used;
        if (!std.math.isFinite(free) or free == 0) return;
        const growing = free > 0;
        for (items.items) |*item| {
            if (item.absolute) continue;
            if (growing) {
                if (item.max_height) |maximum| {
                    if (item.height >= maximum) item.frozen = true;
                }
            } else if (item.height <= item.shrink_floor) {
                item.frozen = true;
            }
        }
        var weight_sum: f32 = 0;
        for (items.items) |item| {
            if (item.absolute or item.frozen) continue;
            weight_sum += if (growing) item.grow else item.shrink * item.base_height;
        }
        if (!std.math.isFinite(weight_sum) or weight_sum <= 0) return;
        var clamped_any = false;
        for (items.items) |*item| {
            if (item.absolute or item.frozen) continue;
            const weight = if (growing) item.grow else item.shrink * item.base_height;
            const proposed = item.height + free * weight / weight_sum;
            if (!std.math.isFinite(proposed)) return error.InvalidStyle;
            var target = clampRoot(proposed, item.min_height, item.max_height);
            if (!growing and item.height > item.shrink_floor) {
                target = @max(target, item.shrink_floor);
            }
            if (target != proposed) {
                item.height = target;
                item.frozen = true;
                clamped_any = true;
            } else {
                item.height = proposed;
            }
        }
        if (!clamped_any) return;
    }
}

fn clampRoot(value: f32, minimum: f32, maximum: ?f32) f32 {
    var result = value;
    if (maximum) |limit| result = @min(result, limit);
    return @max(result, minimum);
}
fn clampRootFinite(value: f32, minimum: f32, maximum: ?f32) LayoutError!f32 {
    const finite_value = try finiteNonNegative(value);
    const finite_minimum = try finiteNonNegative(minimum);
    const finite_maximum = if (maximum) |limit|
        try finiteNonNegative(limit)
    else
        null;
    return finiteNonNegative(clampRoot(finite_value, finite_minimum, finite_maximum));
}

fn borderToContent(
    value: f32,
    edges: f32,
    box_sizing: style.BoxSizing,
) LayoutError!f32 {
    const finite_value = try finiteNonNegative(value);
    return switch (box_sizing) {
        .content_box => blk: {
            const difference = try finiteSubtract(finite_value, edges);
            break :blk finiteNonNegative(@max(0, difference));
        },
        .border_box => finite_value,
    };
}

fn rootSizeFromInsets(
    available: f32,
    leading: f32,
    trailing: f32,
    margin_leading: f32,
    margin_trailing: f32,
) LayoutError!f32 {
    var result = try finiteSubtract(available, leading);
    result = try finiteSubtract(result, trailing);
    result = try finiteSubtract(result, margin_leading);
    result = try finiteSubtract(result, margin_trailing);
    return finiteNonNegative(@max(0, result));
}

fn finiteAdd(lhs: f32, rhs: f32) LayoutError!f32 {
    return finiteSigned(lhs + rhs);
}

fn finiteSubtract(lhs: f32, rhs: f32) LayoutError!f32 {
    return finiteSigned(lhs - rhs);
}

fn finiteMultiply(lhs: f32, rhs: f32) LayoutError!f32 {
    return finiteSigned(lhs * rhs);
}

fn finiteDivide(lhs: f32, rhs: f32) LayoutError!f32 {
    return finiteSigned(lhs / rhs);
}

fn validateRootRect(rect: widget.Rect) LayoutError!void {
    _ = try finiteSigned(rect.x);
    _ = try finiteSigned(rect.y);
    _ = try finiteNonNegative(rect.w);
    _ = try finiteNonNegative(rect.h);
}

fn rootWidth(
    input: style.Style,
    natural: context.Measured,
    available: widget.Size,
    margins: style.Sides,
) LayoutError!f32 {
    return switch (input.size.width) {
        .auto => rootSizeFromInsets(
            available.width,
            0,
            0,
            margins.left,
            margins.right,
        ),
        .length, .percent, .min_content, .max_content, .fit_content => finiteNonNegative(
            natural.border.width,
        ),
    };
}

fn rootBaseHeight(
    input: style.Style,
    natural: context.Measured,
    available: widget.Size,
    vertical_edges: f32,
) LayoutError!f32 {
    if (input.basis != 0) {
        return sizingToBorder(input.basis, vertical_edges, input.box_sizing);
    }
    const basis = switch (input.flex_basis) {
        .auto => null,
        .length => |value| @as(?f32, value),
        .percent => |fraction| @as(?f32, fraction * available.height),
        .min_content, .max_content, .fit_content => @as(?f32, natural.content.height),
    };
    if (basis) |value| return sizingToBorder(value, vertical_edges, input.box_sizing);
    return finiteNonNegative(natural.border.height);
}

fn rootMinHeight(
    input: style.Style,
    natural: context.Measured,
    available: widget.Size,
    vertical_edges: f32,
) LayoutError!f32 {
    var result: f32 = 0;
    if (input.min_main) |minimum| result = try finiteNonNegative(minimum);
    if (try rootDimensionBorder(
        input.min_size.height,
        available.height,
        natural.content.height,
        vertical_edges,
        input.box_sizing,
    )) |minimum| {
        result = @max(result, minimum);
    }
    return result;
}

fn absoluteRootBaseHeight(
    input: style.Style,
    natural: context.Measured,
    available: widget.Size,
    vertical_edges: f32,
) LayoutError!f32 {
    return (try rootDimensionBorder(
        input.size.height,
        available.height,
        natural.content.height,
        vertical_edges,
        input.box_sizing,
    )) orelse finiteNonNegative(natural.border.height);
}

fn absoluteRootMinHeight(
    input: style.Style,
    natural: context.Measured,
    available: widget.Size,
    vertical_edges: f32,
) LayoutError!f32 {
    return (try rootDimensionBorder(
        input.min_size.height,
        available.height,
        natural.content.height,
        vertical_edges,
        input.box_sizing,
    )) orelse 0;
}

fn rootMaxHeight(
    input: style.Style,
    natural: context.Measured,
    available: widget.Size,
    vertical_edges: f32,
) LayoutError!?f32 {
    return rootDimensionBorder(
        input.max_size.height,
        available.height,
        natural.content.height,
        vertical_edges,
        input.box_sizing,
    );
}

fn rootDimensionBorder(
    value: style.Dimension,
    basis: f32,
    intrinsic: f32,
    edges: f32,
    box_sizing: style.BoxSizing,
) LayoutError!?f32 {
    const content = switch (value) {
        .auto => return null,
        .length => |number| number,
        .percent => |fraction| try finiteMultiply(fraction, basis),
        .min_content, .max_content => intrinsic,
        .fit_content => |limit_opt| if (limit_opt) |limit| @min(limit, intrinsic) else intrinsic,
    };
    return @as(?f32, try sizingToBorder(content, edges, box_sizing));
}

fn rootShrinkFloor(
    input: style.Style,
    natural: context.Measured,
    minimum: f32,
) f32 {
    const explicit_minimum = input.min_main != null or input.min_size.height != .auto;
    return if (explicit_minimum) minimum else natural.border.height;
}
fn sizingToBorder(value: f32, edges: f32, box_sizing: style.BoxSizing) LayoutError!f32 {
    const non_negative = try finiteNonNegative(value);
    return switch (box_sizing) {
        .content_box => try finiteAdd(non_negative, edges),
        .border_box => finiteNonNegative(@max(edges, non_negative)),
    };
}

fn resolveRootMargins(input: style.Style, basis: f32) LayoutError!style.Sides {
    return .{
        .top = try resolveRootMargin(input.margin_inset.top, input.margin.top, basis),
        .right = try resolveRootMargin(input.margin_inset.right, input.margin.right, basis),
        .bottom = try resolveRootMargin(input.margin_inset.bottom, input.margin.bottom, basis),
        .left = try resolveRootMargin(input.margin_inset.left, input.margin.left, basis),
    };
}

fn resolveRootMargin(
    value: style.LengthPercentageAuto,
    legacy: f32,
    basis: f32,
) LayoutError!f32 {
    const result = switch (value) {
        .auto => 0,
        .length => |number| if (number == 0 and legacy != 0) legacy else number,
        .percent => |fraction| try finiteMultiply(fraction, basis),
    };
    return finiteSigned(result);
}
fn resolveRootInsets(input: style.Style, available: widget.Size) LayoutError!RootInsets {
    return .{
        .top = try resolveRootInset(input.inset.top, available.height),
        .right = try resolveRootInset(input.inset.right, available.width),
        .bottom = try resolveRootInset(input.inset.bottom, available.height),
        .left = try resolveRootInset(input.inset.left, available.width),
    };
}

fn resolveRootInset(value: style.LengthPercentageAuto, basis: f32) LayoutError!?f32 {
    return switch (value) {
        .auto => null,
        .length => |number| blk: {
            const resolved = try finiteSigned(number);
            break :blk @as(?f32, resolved);
        },
        .percent => |fraction| blk: {
            const resolved = try finiteMultiply(fraction, basis);
            break :blk @as(?f32, resolved);
        },
    };
}
fn finiteSigned(value: f32) LayoutError!f32 {
    if (!std.math.isFinite(value)) return error.InvalidStyle;
    return value;
}

fn applyRelativeRootInset(
    node: *widget.WidgetNode,
    available: widget.Size,
) LayoutError!void {
    if (node.style.position != .relative) return;
    const insets = try resolveRootInsets(node.style, available);
    if (insets.left) |left| {
        node.rect.x = try finiteAdd(node.rect.x, left);
    } else if (insets.right) |right| {
        node.rect.x = try finiteSubtract(node.rect.x, right);
    }
    if (insets.top) |top| {
        node.rect.y = try finiteAdd(node.rect.y, top);
    } else if (insets.bottom) |bottom| {
        node.rect.y = try finiteSubtract(node.rect.y, bottom);
    }
}

fn measureNodeCallback(
    self: *context.LayoutContext,
    tree: *widget.WidgetTree,
    node: *const widget.WidgetNode,
    request: context.Request,
) LayoutError!context.Measured {
    if (node.children.items.len != 0 and needsNaturalMeasurement(node)) {
        return switch (node.style.display) {
            .block, .flow_root => block_float.measureNatural(
                tree,
                node,
                request,
                self,
            ),
            .flex => flex.measureNatural(tree, node, request, self),
            .grid => grid.measureNatural(tree, node, request, self),
            .none => .{
                .content = .{ .width = 0, .height = 0 },
                .border = .{ .width = 0, .height = 0 },
            },
        };
    }
    return measureNode(
        tree,
        node,
        request,
        tree.nodes.items.len + 1,
        self.measure,
    );
}

fn needsNaturalMeasurement(node: *const widget.WidgetNode) bool {
    return isIntrinsicDimension(node.style.size.width) or
        isIntrinsicDimension(node.style.size.height);
}

fn isIntrinsicDimension(value: style.Dimension) bool {
    return switch (value) {
        .auto, .min_content, .max_content, .fit_content => true,
        .length, .percent => false,
    };
}
fn hasIntrinsicRootConstraint(value: style.Dimension) bool {
    return switch (value) {
        .min_content, .max_content, .fit_content => true,
        .auto, .length, .percent => false,
    };
}

fn layoutNodeCallback(
    self: *context.LayoutContext,
    tree: *widget.WidgetTree,
    node: *widget.WidgetNode,
    request: context.Request,
) LayoutError!void {
    try validateRequest(request);
    if (node.layout_hidden) return;
    const node_index = tree.nodeIndex(node.id) orelse return error.InvalidStyle;
    if (&tree.nodes.items[node_index] != node) return error.InvalidStyle;
    const sizing_context: sizing.SizingContext = .{
        .available = .{
            .width = .{ .definite = request.available.width },
            .height = .{ .definite = request.available.height },
        },
        .percentage_basis = request.percentage_basis,
    };
    switch (node.style.display) {
        .none => return,
        .block, .flow_root => {
            var pass = block_float.LayoutPass.prepared(tree);
            try pass.layoutPreparedContainer(
                node.id,
                sizing_context,
                self.measure,
                self,
                request.forced_border,
            );
        },
        .flex => try flex.layoutPreparedContainer(tree, node.id, .{
            .allocator = self.allocator,
            .available = request.available,
            .measure = self.measure,
            .context = self,
        }, request.forced_border),
        .grid => try grid.layoutPreparedContainer(tree, node.id, .{
            .allocator = self.allocator,
            .available = request.available,
            .measure = self.measure,
            .context = self,
        }, request.forced_border),
    }
}

fn measureNode(
    _: *const widget.WidgetTree,
    node: *const widget.WidgetNode,
    request: context.Request,
    depth: usize,
    measure: ?context.MeasureFn,
) LayoutError!context.Measured {
    if (depth == 0) return error.InvalidStyle;
    try validateRequest(request);
    if (node.layout_hidden or node.style.display == .none) return .{
        .content = .{ .width = 0, .height = 0 },
        .border = .{ .width = 0, .height = 0 },
    };
    const edges = try resolveEdges(node.style, request.percentage_basis.width);
    const intrinsic: widget.Size = if (node.children.items.len == 0)
        try measureLeaf(node, measure)
    else
        .{ .width = 0, .height = 0 };
    const width = try resolveConcreteDimension(
        node.style.size.width,
        request.percentage_basis.width,
        if (node.children.items.len == 0) intrinsic.width else null,
    );
    const height = try resolveConcreteDimension(
        node.style.size.height,
        request.percentage_basis.height,
        if (node.children.items.len == 0) intrinsic.height else null,
    );
    if (width == null or height == null) return error.InvalidStyle;
    const border = try borderSize(
        node.style,
        .{ .width = width.?, .height = height.? },
        edges,
    );
    return .{
        .content = .{
            .width = @max(0, border.width - edges.horizontal),
            .height = @max(0, border.height - edges.vertical),
        },
        .border = border,
    };
}

fn measureLeaf(
    node: *const widget.WidgetNode,
    measure: ?context.MeasureFn,
) LayoutError!widget.Size {
    var result: widget.Size = switch (node.kind) {
        .label => |label| if (measure) |callback|
            callback(label.text, node.font_size, node.font_id)
        else blk: {
            const text_length: f32 = @floatFromInt(@min(label.text.len, 1 << 24));
            break :blk .{
                .width = text_length * (if (node.font_size > 0) node.font_size / 2 else 10),
                .height = if (node.font_size > 0) node.font_size else 20,
            };
        },
        .spacer => |spacer| .{ .width = spacer.size, .height = spacer.size },
        .button => .{ .width = 100, .height = 32 },
        .slider => .{ .width = 100, .height = widget.slider_rail_height },
        .row, .column => .{ .width = 0, .height = 0 },
    };
    if (node.text_max_width) |maximum| {
        if (node.text_overflow != .visible) result.width = @min(result.width, maximum);
    }
    if (!std.math.isFinite(result.width) or !std.math.isFinite(result.height)) {
        return error.InvalidStyle;
    }
    if (result.width < 0 or result.height < 0) return error.InvalidStyle;
    return result;
}

fn borderSize(input: style.Style, dimensions: widget.Size, edges: Edges) LayoutError!widget.Size {
    const width = if (input.box_sizing == .content_box)
        dimensions.width + edges.horizontal
    else
        dimensions.width;
    const height = if (input.box_sizing == .content_box)
        dimensions.height + edges.vertical
    else
        dimensions.height;
    if (!std.math.isFinite(width) or !std.math.isFinite(height)) return error.InvalidStyle;
    return .{ .width = @max(edges.horizontal, width), .height = @max(edges.vertical, height) };
}

fn resolveConcreteDimension(
    value: style.Dimension,
    percentage_basis: ?f32,
    intrinsic: ?f32,
) LayoutError!?f32 {
    return switch (value) {
        .length => |number| blk: {
            const resolved = try finiteNonNegative(number);
            break :blk @as(?f32, resolved);
        },
        .percent => |fraction| blk: {
            const basis = percentage_basis orelse return error.InvalidStyle;
            const resolved = try finiteNonNegative(fraction * basis);
            break :blk @as(?f32, resolved);
        },
        .auto, .min_content, .max_content, .fit_content => intrinsic,
    };
}

fn resolveEdges(input: style.Style, basis: ?f32) LayoutError!Edges {
    const width_basis = basis orelse return error.InvalidStyle;
    const border: style.Sides = .{
        .top = try resolveEdge(input.border_inset.top, input.border.top, width_basis),
        .right = try resolveEdge(input.border_inset.right, input.border.right, width_basis),
        .bottom = try resolveEdge(input.border_inset.bottom, input.border.bottom, width_basis),
        .left = try resolveEdge(input.border_inset.left, input.border.left, width_basis),
    };
    const padding: style.Sides = .{
        .top = try resolveEdge(input.padding_inset.top, input.padding.top, width_basis),
        .right = try resolveEdge(input.padding_inset.right, input.padding.right, width_basis),
        .bottom = try resolveEdge(input.padding_inset.bottom, input.padding.bottom, width_basis),
        .left = try resolveEdge(input.padding_inset.left, input.padding.left, width_basis),
    };
    return .{
        .border = border,
        .padding = padding,
        .horizontal = border.left + border.right + padding.left + padding.right,
        .vertical = border.top + border.bottom + padding.top + padding.bottom,
    };
}

fn resolveEdge(value: style.LengthPercentage, legacy: f32, basis: f32) LayoutError!f32 {
    const result = switch (value) {
        .length => |number| if (number == 0 and legacy != 0) legacy else number,
        .percent => |fraction| fraction * basis,
    };
    return finiteNonNegative(result);
}

fn validateRequest(request: context.Request) LayoutError!void {
    try validateAvailable(request.available);
    if (request.percentage_basis.width) |width| _ = try finiteNonNegative(width);
    if (request.percentage_basis.height) |height| _ = try finiteNonNegative(height);
    if (request.forced_border) |border| {
        _ = try finiteNonNegative(border.width);
        _ = try finiteNonNegative(border.height);
    }
}

fn validateAvailable(available: widget.Size) LayoutError!void {
    _ = try finiteNonNegative(available.width);
    _ = try finiteNonNegative(available.height);
}

fn finiteNonNegative(value: f32) LayoutError!f32 {
    if (!std.math.isFinite(value) or value < 0) return error.InvalidStyle;
    return value;
}

fn validateTree(
    allocator: std.mem.Allocator,
    tree: *const widget.WidgetTree,
) LayoutError!std.ArrayList(usize) {
    var roots: std.ArrayList(usize) = .empty;
    errdefer roots.deinit(allocator);
    const visited = allocator.alloc(bool, tree.nodes.items.len) catch {
        return error.InvalidStyle;
    };
    defer allocator.free(visited);
    @memset(visited, false);
    for (tree.nodes.items, 0..) |node, node_index| {
        if (node.id == .root) return error.InvalidStyle;
        for (tree.nodes.items[0..node_index]) |prior| {
            if (prior.id == node.id) return error.InvalidStyle;
        }
        if (node.parent == .root) {
            roots.append(allocator, node_index) catch return error.InvalidStyle;
        }
    }
    if (roots.items.len == 0) return error.InvalidStyle;
    for (roots.items) |root_index| {
        try validateNode(
            tree,
            root_index,
            .root,
            visited,
            tree.nodes.items.len + 1,
        );
    }
    for (visited) |was_visited| {
        if (!was_visited) return error.InvalidStyle;
    }
    return roots;
}

fn validateNode(
    tree: *const widget.WidgetTree,
    index: usize,
    expected_parent: Id,
    visited: []bool,
    depth: usize,
) LayoutError!void {
    if (depth == 0 or index >= tree.nodes.items.len) return error.InvalidStyle;
    if (visited[index]) return error.InvalidStyle;
    visited[index] = true;
    const node = &tree.nodes.items[index];
    if (node.parent != expected_parent) return error.InvalidStyle;
    if (node.style.display != .none and node.children.items.len != 0) {
        switch (node.kind) {
            .row, .column => {},
            else => return error.InvalidStyle,
        }
    }
    for (node.children.items, 0..) |child_id, child_offset| {
        if (child_id == .root) return error.InvalidStyle;
        for (node.children.items[0..child_offset]) |prior_id| {
            if (prior_id == child_id) return error.InvalidStyle;
        }
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        if (child_index >= index) return error.InvalidStyle;
        try validateNode(tree, child_index, node.id, visited, depth - 1);
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

pub fn eligibleMixedForest(tree: *const widget.WidgetTree) bool {
    var roots = validateTree(tree.allocator, tree) catch return false;
    defer roots.deinit(tree.allocator);
    var mixed = false;
    for (roots.items) |root_index| {
        const root = &tree.nodes.items[root_index];
        if (!eligibleRoot(root)) return false;
        if (!isConcreteTree(tree, root_index, tree.nodes.items.len + 1, true)) {
            return false;
        }
        if (hasMixedDisplay(tree, root_index, tree.nodes.items.len + 1)) {
            mixed = true;
        }
    }
    return mixed;
}

fn eligibleRoot(node: *const widget.WidgetNode) bool {
    if (node.scroll != null or hasScrollOverflow(node.style)) return false;
    if (node.style.float != .none or node.style.clear != .none) return false;
    if (!isSupportedRootDimension(node.style.size.width)) return false;
    if (!isSupportedRootDimension(node.style.size.height)) return false;
    if (!isFiniteRootStyle(node.style)) return false;
    return true;
}

fn hasScrollOverflow(input: style.Style) bool {
    return input.overflow.width == .scroll or
        input.overflow.width == .auto or
        input.overflow.height == .scroll or
        input.overflow.height == .auto;
}

fn isFiniteRootStyle(input: style.Style) bool {
    if (!std.math.isFinite(input.grow) or input.grow < 0) return false;
    if (!std.math.isFinite(input.shrink) or input.shrink < 0) return false;
    if (!std.math.isFinite(input.basis) or input.basis < 0) return false;
    if (input.min_main) |minimum| {
        if (!std.math.isFinite(minimum) or minimum < 0) return false;
    }
    return true;
}

fn markHidden(
    tree: *widget.WidgetTree,
    index: usize,
    inherited: bool,
    depth: usize,
) LayoutError!void {
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

const EngineFamily = enum { none, block, flex, grid };

fn engineFamily(display: style.Display) EngineFamily {
    return switch (display) {
        .none => .none,
        .block, .flow_root => .block,
        .flex => .flex,
        .grid => .grid,
    };
}

fn hasMixedDisplay(tree: *const widget.WidgetTree, index: usize, depth: usize) bool {
    if (depth == 0) return false;
    const node = &tree.nodes.items[index];
    if (node.style.display == .none) return false;
    const family = engineFamily(node.style.display);
    for (node.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return false;
        const child = &tree.nodes.items[child_index];
        if (child.style.display == .none) continue;
        if (child.children.items.len != 0 and engineFamily(child.style.display) != family) {
            return true;
        }
        if (hasMixedDisplay(tree, child_index, depth - 1)) return true;
    }
    return false;
}

fn isConcreteTree(
    tree: *const widget.WidgetTree,
    index: usize,
    depth: usize,
    is_root: bool,
) bool {
    if (depth == 0 or index >= tree.nodes.items.len) return false;
    const node = &tree.nodes.items[index];
    if (node.scroll != null) return false;
    if (node.style.display != .none and node.children.items.len != 0) {
        if (is_root) {
            if (!isSupportedRootDimension(node.style.size.width)) return false;
            if (node.style.display != .block and
                node.style.display != .flow_root and
                !isSupportedRootDimension(node.style.size.height))
            {
                return false;
            }
        }
        switch (node.kind) {
            .row, .column => {},
            else => return false,
        }
    }
    for (node.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return false;
        if (!isConcreteTree(tree, child_index, depth - 1, false)) return false;
    }
    return true;
}

fn isSupportedRootDimension(value: style.Dimension) bool {
    return switch (value) {
        .auto => true,
        .length => |number| std.math.isFinite(number) and number >= 0,
        .percent => |fraction| std.math.isFinite(fraction) and fraction >= 0,
        .min_content, .max_content, .fit_content => false,
    };
}
