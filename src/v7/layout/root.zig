const std = @import("std");
const Id = @import("../id.zig").Id;
const context = @import("context.zig");
const dispatch = @import("dispatch.zig");
const widget = @import("../widget.zig");

pub const MeasureInput = context.MeasureInput;
pub const MeasureFn = context.MeasureFn;
pub const MeasureMode = context.MeasureMode;

pub const Options = struct {
    allocator: std.mem.Allocator,
    available: widget.Size,
    measure: ?MeasureFn,
    width_mode: MeasureMode = .definite,
    height_mode: MeasureMode = .definite,
};

pub const LayoutError = context.LayoutError;

pub fn validateAvailable(available: widget.Size) LayoutError!void {
    if (!std.math.isFinite(available.width) or available.width < 0) {
        return error.InvalidStyle;
    }
    if (!std.math.isFinite(available.height) or available.height < 0) {
        return error.InvalidStyle;
    }
}

pub fn layoutTree(tree: *widget.WidgetTree, options: Options) LayoutError!void {
    return dispatch.layoutTree(tree, .{
        .allocator = options.allocator,
        .available = options.available,
        .measure = options.measure,
        .width_mode = options.width_mode,
        .height_mode = options.height_mode,
    });
}
fn rootIntrinsicMeasure(text: []const u8, _: MeasureInput) widget.Size {
    return .{
        .width = @floatFromInt(text.len),
        .height = @floatFromInt(text.len + 1),
    };
}

test "root max-content request uses natural leaf border on both axes" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: Id = @enumFromInt(1);
    const text = "max-content";
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .label = .{ .text = text } },
        .parent = .root,
        .style = .{
            .display = .flow_root,
            .box_sizing = .border_box,
            .size = .{ .width = .auto, .height = .auto },
        },
    });

    try layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 211, .height = 157 },
        .measure = rootIntrinsicMeasure,
        .width_mode = .max_content,
        .height_mode = .max_content,
    });

    try std.testing.expectEqual(
        @as(f32, @floatFromInt(text.len)),
        tree.node(root_id).?.rect.w,
    );
    try std.testing.expectEqual(
        @as(f32, @floatFromInt(text.len + 1)),
        tree.node(root_id).?.rect.h,
    );
}

test "root definite width preserves width while height uses max-content" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: Id = @enumFromInt(1);
    const text = "definite-width";
    const available_width: f32 = 73;
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .label = .{ .text = text } },
        .parent = .root,
        .style = .{
            .display = .flow_root,
            .box_sizing = .border_box,
            .size = .{ .width = .auto, .height = .auto },
        },
    });

    try layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = available_width, .height = 157 },
        .measure = rootIntrinsicMeasure,
        .height_mode = .max_content,
    });

    try std.testing.expectEqual(available_width, tree.node(root_id).?.rect.w);
    try std.testing.expectEqual(
        @as(f32, @floatFromInt(text.len + 1)),
        tree.node(root_id).?.rect.h,
    );
}
