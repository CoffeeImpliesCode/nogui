//! Verifies that block natural measurement preserves an intrinsically indefinite child axis.

const std = @import("std");
const Id = @import("../id.zig").Id;
const layout_context = @import("context.zig");
const widget = @import("../widget.zig");
const block_float = @import("block_float.zig");
const flex = @import("flex.zig");

const WidgetTree = widget.WidgetTree;

fn measureFlexNode(
    context: *layout_context.LayoutContext,
    tree: *WidgetTree,
    node: *const widget.WidgetNode,
    request: layout_context.Request,
) layout_context.LayoutError!layout_context.Measured {
    if (node.style.display != .flex) return error.InvalidStyle;
    return flex.measureNatural(tree, node, request, context);
}

fn unreachableLayoutNode(
    _: *layout_context.LayoutContext,
    _: *WidgetTree,
    _: *widget.WidgetNode,
    _: layout_context.Request,
) layout_context.LayoutError!void {
    unreachable;
}

test "auto intrinsic block height leaves flex percentage height indefinite" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: Id = @enumFromInt(1);
    const flex_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try tree.appendNode(.{
        .id = leaf_id,
        .kind = .{ .spacer = .{} },
        .parent = flex_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 10 },
                .height = .{ .length = 10 },
            },
        },
    });
    try tree.appendNode(.{
        .id = flex_id,
        .kind = .{ .row = .{} },
        .parent = root_id,
        .style = .{
            .display = .flex,
            .direction = .row,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 40 },
                .height = .{ .percent = 0.5 },
            },
        },
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .auto,
            },
        },
    });
    try tree.appendChild(flex_id, leaf_id);
    try tree.appendChild(root_id, flex_id);

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = null,
        .measure_node = measureFlexNode,
        .layout_node = unreachableLayoutNode,
    };
    try std.testing.expectError(
        error.InvalidStyle,
        block_float.measureNatural(
            &tree,
            tree.nodeConst(root_id).?,
            .{
                .available = .{ .width = 100, .height = 100 },
                .percentage_basis = .{ .width = 100, .height = 200 },
                .intrinsic_height = true,
            },
            &context,
        ),
    );
}
