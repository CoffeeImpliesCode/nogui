//! Specifies the natural-measure request validation contract.

const std = @import("std");
const Id = @import("../id.zig").Id;
const style = @import("../style.zig");
const widget = @import("../widget.zig");
const context = @import("context.zig");

const Style = style.Style;
const WidgetTree = widget.WidgetTree;

fn appendRoot(tree: *WidgetTree, node_style: Style) !*const widget.WidgetNode {
    const root_id: Id = @enumFromInt(1);
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = node_style,
    });
    return tree.nodeConst(root_id).?;
}

test "natural request accepts explicit width percentage basis that differs from available space" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try appendRoot(&tree, .{
        .display = .block,
        .size = .{
            .width = .{ .percent = 0.5 },
            .height = .auto,
        },
    });

    try context.validateNaturalRequest(&tree, root, .{
        .available = .{ .width = 100, .height = 100 },
        .percentage_basis = .{ .width = 200, .height = null },
    });
}

test "natural request rejects missing width basis for percentage-dependent subtree" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try appendRoot(&tree, .{
        .display = .block,
        .size = .{
            .width = .{ .percent = 0.5 },
            .height = .auto,
        },
    });

    try std.testing.expectError(
        error.InvalidStyle,
        context.validateNaturalRequest(&tree, root, .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = null, .height = null },
        }),
    );
}

test "natural request accepts explicit height percentage basis that differs from available space" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try appendRoot(&tree, .{
        .display = .block,
        .size = .{
            .width = .auto,
            .height = .{ .percent = 0.5 },
        },
    });

    try context.validateNaturalRequest(&tree, root, .{
        .available = .{ .width = 100, .height = 100 },
        .percentage_basis = .{ .width = null, .height = 200 },
    });
}

test "natural request rejects missing height basis for percentage-dependent subtree" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try appendRoot(&tree, .{
        .display = .block,
        .size = .{
            .width = .auto,
            .height = .{ .percent = 0.5 },
        },
    });

    try std.testing.expectError(
        error.InvalidStyle,
        context.validateNaturalRequest(&tree, root, .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = null, .height = null },
        }),
    );
}

test "natural request rejects non-concrete available space" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try appendRoot(&tree, .{ .display = .block });

    try std.testing.expectError(
        error.InvalidStyle,
        context.validateNaturalRequest(&tree, root, .{
            .available = .{ .width = -1, .height = 100 },
            .percentage_basis = .{ .width = null, .height = null },
        }),
    );
    try std.testing.expectError(
        error.InvalidStyle,
        context.validateNaturalRequest(&tree, root, .{
            .available = .{ .width = 100, .height = std.math.nan(f32) },
            .percentage_basis = .{ .width = null, .height = null },
        }),
    );
}
