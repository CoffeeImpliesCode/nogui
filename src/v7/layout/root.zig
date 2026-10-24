const std = @import("std");
const FrameNodeId = @import("../id.zig").FrameNodeId;
const context = @import("context.zig");
const dispatch = @import("dispatch.zig");
const widget = @import("../widget.zig");

pub const MeasureInput = context.MeasureInput;
pub const MeasureSource = context.MeasureSource;
pub const TextMeasurement = context.TextMeasurement;
pub const MeasureMode = context.MeasureMode;
pub const LayoutStorage = context.LayoutStorage;
pub const Options = struct {
    allocator: std.mem.Allocator,
    available: widget.Size,
    measure: ?MeasureSource = null,
    width_mode: MeasureMode = .definite,
    height_mode: MeasureMode = .definite,
    storage: ?*LayoutStorage = null,
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
        .storage = options.storage,
    });
}
fn exactF32FromUsize(value: usize) f32 {
    std.debug.assert(value <= (1 << 24));
    const value_f64: f64 = @floatFromInt(value);
    return @floatCast(value_f64);
}

fn rootIntrinsicMeasure(
    _: ?*anyopaque,
    text: []const u8,
    _: MeasureInput,
) LayoutError!context.TextMeasurement {
    std.debug.assert(text.len < (1 << 24));
    const height_length = text.len + 1;
    return .{
        .width = exactF32FromUsize(text.len),
        .height = exactF32FromUsize(height_length),
    };
}

test "root max-content request uses natural leaf border on both axes" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: FrameNodeId = @fromBackingInt(@intCast(1));
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
        .measure = .{ .callback = rootIntrinsicMeasure },
        .width_mode = .max_content,
        .height_mode = .max_content,
    });

    try std.testing.expectEqual(
        exactF32FromUsize(text.len),
        tree.node(root_id).?.rect.w,
    );
    try std.testing.expectEqual(
        exactF32FromUsize(text.len + 1),
        tree.node(root_id).?.rect.h,
    );
}

test "root definite width preserves width while height uses max-content" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: FrameNodeId = @fromBackingInt(@intCast(1));
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
        .measure = .{ .callback = rootIntrinsicMeasure },
        .height_mode = .max_content,
    });

    try std.testing.expectEqual(available_width, tree.node(root_id).?.rect.w);
    try std.testing.expectEqual(
        exactF32FromUsize(text.len + 1),
        tree.node(root_id).?.rect.h,
    );
}
