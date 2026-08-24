//! Specifies the checked layout facade before the production module exists.

const std = @import("std");
const Id = @import("../id.zig").Id;
const widget = @import("../widget.zig");
const layout = @import("root.zig");

fn layoutTreeMeasure(text: []const u8, _: f32, _: u8) widget.Size {
    return .{
        .width = @floatFromInt(text.len * 5),
        .height = 12,
    };
}

test "layoutTree preserves legacy relative column geometry" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try tree.appendNode(.{
        .id = first_id,
        .kind = .{ .label = .{ .text = "one" } },
        .parent = root_id,
    });
    try tree.appendNode(.{
        .id = second_id,
        .kind = .{ .label = .{ .text = "second" } },
        .parent = root_id,
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{ .gap = 4 } },
        .parent = .root,
        .style = .{ .@"align" = .start, .gap = 4 },
    });
    try tree.appendChild(root_id, first_id);
    try tree.appendChild(root_id, second_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 80 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 100, .h = 28 },
        tree.node(root_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 15, .h = 12 },
        tree.node(first_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 16, .w = 30, .h = 12 },
        tree.node(second_id).?.rect,
    );
}

test "layoutTree rejects non-finite available width" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expectError(
        error.InvalidStyle,
        layout.layoutTree(&tree, .{
            .allocator = std.testing.allocator,
            .available = .{ .width = std.math.inf(f32), .height = 80 },
            .measure = layoutTreeMeasure,
        }),
    );
}
