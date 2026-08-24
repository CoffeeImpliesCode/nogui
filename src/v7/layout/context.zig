const std = @import("std");
const sizing = @import("sizing.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");

pub const MeasureFn = *const fn ([]const u8, f32, u8) widget.Size;
pub const LayoutError = sizing.Error;

pub const Request = struct {
    available: widget.Size,
    percentage_basis: style.Size(?f32),
    forced_border: ?widget.Size = null,
    intrinsic_width: bool = false,
    intrinsic_height: bool = false,
};
/// Validate the first-phase natural-measurement contract.
///
/// Explicit percentage bases come from the caller's resolution context.
/// `available` is the space available to the natural-measurement pass.
pub fn validateNaturalRequest(
    tree: *const widget.WidgetTree,
    node: *const widget.WidgetNode,
    request: Request,
) LayoutError!void {
    try validateConcrete(request.available.width);
    try validateConcrete(request.available.height);

    const dependencies = percentageDependencies(
        tree,
        node,
        tree.nodes.items.len + 1,
        null,
    );
    if (request.percentage_basis.width) |basis| {
        try validateConcrete(basis);
    } else if (dependencies.width) {
        return error.InvalidStyle;
    }
    if (request.percentage_basis.height) |basis| {
        try validateConcrete(basis);
    } else if (dependencies.height) {
        return error.InvalidStyle;
    }
}

fn validateConcrete(value: f32) LayoutError!void {
    if (!std.math.isFinite(value) or value < 0) return error.InvalidStyle;
}

const PercentageDependencies = struct {
    width: bool = false,
    height: bool = false,

    fn combine(left: PercentageDependencies, right: PercentageDependencies) PercentageDependencies {
        return .{
            .width = left.width or right.width,
            .height = left.height or right.height,
        };
    }
};

fn percentageDependencies(
    tree: *const widget.WidgetTree,
    node: *const widget.WidgetNode,
    depth: usize,
    parent_direction: ?style.FlexDirection,
) PercentageDependencies {
    if (depth == 0) return .{ .width = true, .height = true };
    if (node.layout_hidden or node.style.display == .none) return .{};
    const input = node.style;
    var result: PercentageDependencies = .{
        .width = isPercentDimension(input.size.width) or
            isPercentDimension(input.min_size.width) or
            isPercentDimension(input.max_size.width) or
            isPercentRectWidth(input.border_inset) or
            isPercentRectWidth(input.padding_inset) or
            isPercentInsetsWidth(input.margin_inset) or
            isPercentTrack(input.grid_auto_columns),
        .height = isPercentDimension(input.size.height) or
            isPercentDimension(input.min_size.height) or
            isPercentDimension(input.max_size.height) or
            isPercentTrack(input.grid_auto_rows),
    };
    if (isPercentDimension(input.flex_basis)) {
        if (parent_direction) |direction| {
            if (style.directionIsColumn(direction)) {
                result.height = true;
            } else {
                result.width = true;
            }
        }
    }
    for (input.grid_template_columns) |track| {
        if (isPercentTrack(track)) result.width = true;
    }
    for (input.grid_template_rows) |track| {
        if (isPercentTrack(track)) result.height = true;
    }
    const child_parent_direction: ?style.FlexDirection = if (input.display == .flex)
        input.direction
    else
        null;
    for (node.children.items) |child_id| {
        const child = tree.nodeConst(child_id) orelse return .{ .width = true, .height = true };
        result = result.combine(
            percentageDependencies(tree, child, depth - 1, child_parent_direction),
        );
    }
    return result;
}

fn isPercentDimension(value: style.Dimension) bool {
    return switch (value) {
        .percent => true,
        .auto, .length, .min_content, .max_content => false,
    };
}

fn isPercentRectWidth(value: style.LengthPercentageRect) bool {
    return isPercentLength(value.top) or
        isPercentLength(value.right) or
        isPercentLength(value.bottom) or
        isPercentLength(value.left);
}

fn isPercentInsetsWidth(value: style.Insets) bool {
    return isPercentAuto(value.top) or
        isPercentAuto(value.right) or
        isPercentAuto(value.bottom) or
        isPercentAuto(value.left);
}

fn isPercentInsetsHorizontal(value: style.Insets) bool {
    return isPercentAuto(value.left) or isPercentAuto(value.right);
}

fn isPercentInsetsHeight(value: style.Insets) bool {
    return isPercentAuto(value.top) or isPercentAuto(value.bottom);
}

fn isPercentLength(value: style.LengthPercentage) bool {
    return switch (value) {
        .percent => true,
        .length => false,
    };
}

fn isPercentAuto(value: style.LengthPercentageAuto) bool {
    return switch (value) {
        .percent => true,
        .auto, .length => false,
    };
}

fn isPercentTrack(value: style.GridTrack) bool {
    return switch (value) {
        .percent => true,
        .minmax => |bounds| isPercentBreadth(bounds.min) or isPercentBreadth(bounds.max),
        .fixed, .auto, .min_content, .max_content, .fr => false,
    };
}

fn isPercentBreadth(value: style.GridTrackBreadth) bool {
    return switch (value) {
        .percent => true,
        .fixed, .auto, .min_content, .max_content, .fr => false,
    };
}

pub const Measured = struct {
    content: widget.Size,
    border: widget.Size,
};

pub const MeasureNodeFn = *const fn (
    self: *LayoutContext,
    tree: *widget.WidgetTree,
    node: *const widget.WidgetNode,
    request: Request,
) LayoutError!Measured;

pub const LayoutNodeFn = *const fn (
    self: *LayoutContext,
    tree: *widget.WidgetTree,
    node: *widget.WidgetNode,
    request: Request,
) LayoutError!void;

pub const LayoutContext = struct {
    allocator: std.mem.Allocator,
    measure: ?MeasureFn,
    measure_node: MeasureNodeFn,
    layout_node: LayoutNodeFn,
};
