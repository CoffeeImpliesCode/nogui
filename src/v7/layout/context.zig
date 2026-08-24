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
};

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
