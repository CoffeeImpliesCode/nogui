//! Verifies that direct grid measurement resolves percentages from the request basis.

const std = @import("std");
const Id = @import("../id.zig").Id;
const layout_context = @import("context.zig");
const widget = @import("../widget.zig");
const grid = @import("grid.zig");

const WidgetTree = widget.WidgetTree;

fn unreachableMeasureNode(
    _: *layout_context.LayoutContext,
    _: *WidgetTree,
    _: *const widget.WidgetNode,
    _: layout_context.Request,
) layout_context.LayoutError!layout_context.Measured {
    unreachable;
}

fn unreachableLayoutNode(
    _: *layout_context.LayoutContext,
    _: *WidgetTree,
    _: *widget.WidgetNode,
    _: layout_context.Request,
) layout_context.LayoutError!void {
    unreachable;
}

test "measureNatural resolves grid percentages from percentage basis" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: Id = @enumFromInt(1);
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .grid,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .percent = 0.5 },
                .height = .{ .length = 20 },
            },
        },
    });

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = null,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    const root = tree.nodeConst(root_id).?;
    const measured = try grid.measureNatural(
        &tree,
        root,
        .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = 200, .height = 200 },
        },
        &context,
    );

    try std.testing.expectEqual(@as(f32, 100), measured.border.width);
    try std.testing.expectEqual(@as(f32, 20), measured.border.height);
}
