const std = @import("std");
const flex = @import("../flex.zig");
const sizing = @import("sizing.zig");
const widget = @import("../widget.zig");

pub const Options = struct {
    allocator: std.mem.Allocator,
    available: widget.Size,
    measure: ?flex.MeasureFn,
};

pub const LayoutError = sizing.Error;

pub fn validateAvailable(available: widget.Size) LayoutError!void {
    if (!std.math.isFinite(available.width)) return error.InvalidStyle;
    if (!std.math.isFinite(available.height)) return error.InvalidStyle;
}

pub fn layoutTree(tree: *widget.WidgetTree, options: Options) LayoutError!void {
    try validateAvailable(options.available);

    flex.layoutWith(tree, options.available, options.measure);
}
