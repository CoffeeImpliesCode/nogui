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

pub fn layoutTree(tree: *widget.WidgetTree, options: Options) LayoutError!void {
    try validateAvailable(options.available);
    const root_index = try validateTree(tree);
    try markHidden(tree, root_index, false, tree.nodes.items.len + 1);

    var layout_context: context.LayoutContext = .{
        .allocator = options.allocator,
        .measure = options.measure,
        .measure_node = measureNodeCallback,
        .layout_node = layoutNodeCallback,
    };
    const root = &tree.nodes.items[root_index];
    root.rect.x = 0;
    root.rect.y = 0;
    try layoutNodeCallback(
        &layout_context,
        tree,
        root,
        .{
            .available = options.available,
            .percentage_basis = .{
                .width = options.available.width,
                .height = options.available.height,
            },
        },
    );
}

/// Return true only for a concrete tree that contains a real display boundary.
/// The facade uses this conservative predicate before selecting this path.
pub fn eligibleMixedFixedTree(tree: *const widget.WidgetTree) bool {
    const root_index = rootIndex(tree) orelse return false;
    if (tree.nodes.items[root_index].style.display == .none) return false;
    if (!hasDefaultSurfacePlacement(&tree.nodes.items[root_index])) return false;
    if (!isConcreteTree(tree, root_index, tree.nodes.items.len + 1, true)) return false;
    return hasMixedDisplay(tree, root_index, tree.nodes.items.len + 1);
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
        .auto, .min_content, .max_content => true,
        .length, .percent => false,
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
        .auto, .min_content, .max_content => intrinsic,
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

fn validateTree(tree: *const widget.WidgetTree) LayoutError!usize {
    for (tree.nodes.items, 0..) |node, node_index| {
        if (node.id == .root) return error.InvalidStyle;
        for (tree.nodes.items[0..node_index]) |prior| {
            if (prior.id == node.id) return error.InvalidStyle;
        }
    }
    const root_index = rootIndex(tree) orelse return error.InvalidStyle;
    const visited_count = try validateNode(
        tree,
        root_index,
        .root,
        tree.nodes.items.len + 1,
    );
    if (visited_count != tree.nodes.items.len) return error.InvalidStyle;
    return root_index;
}

fn validateNode(
    tree: *const widget.WidgetTree,
    index: usize,
    expected_parent: Id,
    depth: usize,
) LayoutError!usize {
    if (depth == 0 or index >= tree.nodes.items.len) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    if (node.parent != expected_parent) return error.InvalidStyle;
    var visited_count: usize = 1;
    for (node.children.items, 0..) |child_id, child_offset| {
        if (child_id == .root) return error.InvalidStyle;
        for (node.children.items[0..child_offset]) |prior_id| {
            if (prior_id == child_id) return error.InvalidStyle;
        }
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        if (child_index >= index) return error.InvalidStyle;
        visited_count += try validateNode(tree, child_index, node.id, depth - 1);
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
    return visited_count;
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

fn rootIndex(tree: *const widget.WidgetTree) ?usize {
    var result: ?usize = null;
    for (tree.nodes.items, 0..) |node, index| {
        if (node.parent != .root) continue;
        if (result != null) return null;
        result = index;
    }
    return result;
}

fn hasMixedDisplay(tree: *const widget.WidgetTree, index: usize, depth: usize) bool {
    if (depth == 0) return false;
    const node = &tree.nodes.items[index];
    for (node.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return false;
        const child = &tree.nodes.items[child_index];
        if (child.children.items.len != 0 and child.style.display != node.style.display) return true;
        if (hasMixedDisplay(tree, child_index, depth - 1)) return true;
    }
    return false;
}

fn hasDefaultSurfacePlacement(node: *const widget.WidgetNode) bool {
    const input = node.style;
    if (input.position != .relative) return false;
    if (input.float != .none or input.clear != .none) return false;
    if (node.scroll != null) return false;
    if (input.grow != 0 or input.shrink != 1 or input.basis != 0) return false;
    if (!isZeroMargins(input)) return false;
    if (!hasAutomaticInsets(input)) return false;
    return switch (input.flex_basis) {
        .auto => true,
        else => false,
    };
}

fn isZeroMargins(input: style.Style) bool {
    return input.margin.top == 0 and
        input.margin.right == 0 and
        input.margin.bottom == 0 and
        input.margin.left == 0 and
        isZeroMarginInset(input.margin_inset.top) and
        isZeroMarginInset(input.margin_inset.right) and
        isZeroMarginInset(input.margin_inset.bottom) and
        isZeroMarginInset(input.margin_inset.left);
}

fn isZeroMarginInset(value: style.LengthPercentageAuto) bool {
    return switch (value) {
        .auto => false,
        .length => |number| number == 0,
        .percent => |fraction| fraction == 0,
    };
}

fn hasAutomaticInsets(input: style.Style) bool {
    return isAutomaticInset(input.inset.top) and
        isAutomaticInset(input.inset.right) and
        isAutomaticInset(input.inset.bottom) and
        isAutomaticInset(input.inset.left);
}

fn isAutomaticInset(value: style.LengthPercentageAuto) bool {
    return switch (value) {
        .auto => true,
        .length, .percent => false,
    };
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
        if (is_root and
            (!isConcreteDimension(node.style.size.width) or
                !isConcreteDimension(node.style.size.height)))
        {
            return false;
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

fn isConcreteDimension(value: style.Dimension) bool {
    return switch (value) {
        .length, .percent => true,
        .auto, .min_content, .max_content => false,
    };
}
