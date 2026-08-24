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
/// Engine adapters use the available content space as their percentage basis.
/// A missing basis is accepted only when the measured subtree contains no
/// percentage-dependent style value.
pub fn validateNaturalRequest(
    tree: *const widget.WidgetTree,
    node: *const widget.WidgetNode,
    request: Request,
) LayoutError!void {
    try validateConcrete(request.available.width);
    try validateConcrete(request.available.height);
    if (request.percentage_basis.width) |basis| {
        try validateConcrete(basis);
        if (!request.intrinsic_width and basis != request.available.width) {
            return error.InvalidStyle;
        }
    } else if (hasPercentageDependency(tree, node, tree.nodes.items.len + 1)) {
        return error.InvalidStyle;
    }
    if (request.percentage_basis.height) |basis| {
        try validateConcrete(basis);
        if (!request.intrinsic_height and basis != request.available.height) {
            return error.InvalidStyle;
        }
    } else if (hasPercentageDependency(tree, node, tree.nodes.items.len + 1)) {
        return error.InvalidStyle;
    }
}

fn validateConcrete(value: f32) LayoutError!void {
    if (!std.math.isFinite(value) or value < 0) return error.InvalidStyle;
}

fn hasPercentageDependency(
    tree: *const widget.WidgetTree,
    node: *const widget.WidgetNode,
    depth: usize,
) bool {
    if (depth == 0) return true;
    const input = node.style;
    if (isPercentDimension(input.size.width) or
        isPercentDimension(input.size.height) or
        isPercentDimension(input.min_size.width) or
        isPercentDimension(input.min_size.height) or
        isPercentDimension(input.max_size.width) or
        isPercentDimension(input.max_size.height) or
        isPercentDimension(input.flex_basis))
    {
        return true;
    }
    if (isPercentRect(input.border_inset) or isPercentRect(input.padding_inset)) return true;
    if (isPercentAutoRect(input.inset) or isPercentAutoRect(input.margin_inset)) return true;
    if (isPercentTrack(input.grid_auto_columns) or isPercentTrack(input.grid_auto_rows)) {
        return true;
    }
    for (input.grid_template_columns) |track| {
        if (isPercentTrack(track)) return true;
    }
    for (input.grid_template_rows) |track| {
        if (isPercentTrack(track)) return true;
    }
    for (node.children.items) |child_id| {
        const child = tree.nodeConst(child_id) orelse return true;
        if (hasPercentageDependency(tree, child, depth - 1)) return true;
    }
    return false;
}

fn isPercentDimension(value: style.Dimension) bool {
    return switch (value) {
        .percent => true,
        .auto, .length, .min_content, .max_content => false,
    };
}

fn isPercentRect(value: style.LengthPercentageRect) bool {
    return isPercentLength(value.top) or
        isPercentLength(value.right) or
        isPercentLength(value.bottom) or
        isPercentLength(value.left);
}

fn isPercentAutoRect(value: style.Insets) bool {
    return isPercentAuto(value.top) or
        isPercentAuto(value.right) or
        isPercentAuto(value.bottom) or
        isPercentAuto(value.left);
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
