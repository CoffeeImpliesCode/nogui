//! Verifies that intrinsic flex measurement is scoped to each container's auto main axis.

const std = @import("std");
const Id = @import("../id.zig").Id;
const layout_context = @import("context.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");
const flex = @import("flex.zig");

const Style = style.Style;
const WidgetKind = widget.WidgetKind;
const WidgetTree = widget.WidgetTree;

fn appendNode(tree: *WidgetTree, id: Id, parent: Id, node_style: Style) !void {
    const kind: WidgetKind = switch (node_style.display) {
        .flex => .{ .row = .{} },
        .block, .flow_root, .grid => .{ .column = .{} },
        .none => .{ .spacer = .{} },
    };
    try tree.appendNode(.{
        .id = id,
        .kind = kind,
        .parent = parent,
        .style = node_style,
    });
}

fn fixedItem(width: f32, height: f32) Style {
    return .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = width },
            .height = .{ .length = height },
        },
    };
}

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

fn expectSize(expected: widget.Size, actual: widget.Size) !void {
    const tolerance: f32 = 0.001;
    try std.testing.expectApproxEqAbs(expected.width, actual.width, tolerance);
    try std.testing.expectApproxEqAbs(expected.height, actual.height, tolerance);
}

test "measureNatural scopes intrinsic height to auto-sized flex container" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const nested_id: Id = @enumFromInt(3);
    const outer_id: Id = @enumFromInt(4);

    try appendNode(&tree, first_id, nested_id, fixedItem(10, 60));
    try appendNode(&tree, second_id, nested_id, fixedItem(10, 60));
    try appendNode(&tree, nested_id, outer_id, .{
        .display = .flex,
        .direction = .column,
        .wrap = .wrap,
        .flex_wrap = .wrap,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .auto,
            .height = .{ .length = 100 },
        },
    });
    try appendNode(&tree, outer_id, .root, .{
        .display = .flex,
        .direction = .column,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    });
    try tree.appendChild(nested_id, first_id);
    try tree.appendChild(nested_id, second_id);
    try tree.appendChild(outer_id, nested_id);

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = null,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    const outer = tree.nodeConst(outer_id).?;
    const measured = try flex.measureNatural(
        &tree,
        outer,
        .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = 100, .height = 100 },
            .intrinsic_height = true,
        },
        &context,
    );

    try expectSize(.{ .width = 20, .height = 100 }, measured.content);
    try expectSize(.{ .width = 20, .height = 100 }, measured.border);
}

test "measureNatural defers percentage margins below intrinsic auto width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const outer_id: Id = @enumFromInt(2);

    var child_style = fixedItem(10, 10);
    child_style.margin_inset.left = .{ .percent = 0.5 };
    try appendNode(&tree, child_id, outer_id, child_style);
    try appendNode(&tree, outer_id, .root, .{
        .display = .flex,
        .direction = .row,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 10 } },
    });
    try tree.appendChild(outer_id, child_id);

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = null,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    const outer = tree.nodeConst(outer_id).?;
    const measured = try flex.measureNatural(
        &tree,
        outer,
        .{
            .available = .{ .width = 100, .height = 10 },
            .percentage_basis = .{ .width = 200, .height = 10 },
            .intrinsic_width = true,
        },
        &context,
    );

    try expectSize(.{ .width = 10, .height = 10 }, measured.content);
    try expectSize(.{ .width = 10, .height = 10 }, measured.border);
}
