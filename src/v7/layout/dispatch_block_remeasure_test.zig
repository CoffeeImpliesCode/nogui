//! Specifies final-slot remeasurement across the block-to-flex dispatcher bridge.

const std = @import("std");
const Id = @import("../id.zig").Id;
const dispatch = @import("dispatch.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");

const Rect = widget.Rect;
const Style = style.Style;
const WidgetKind = widget.WidgetKind;
const WidgetTree = widget.WidgetTree;

fn fixedStyle(display: style.Display, width: f32, height: f32) Style {
    return .{
        .display = display,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = width },
            .height = .{ .length = height },
        },
    };
}

fn autoStyle(display: style.Display) Style {
    return .{
        .display = display,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    };
}

fn appendNode(
    tree: *WidgetTree,
    id: Id,
    parent: Id,
    node_style: Style,
    kind: WidgetKind,
) !void {
    try tree.appendNode(.{
        .id = id,
        .kind = kind,
        .parent = parent,
        .style = node_style,
    });
}

fn layout(tree: *WidgetTree, available: widget.Size) !void {
    try dispatch.layoutTree(tree, .{
        .allocator = std.testing.allocator,
        .available = available,
        .measure = null,
    });
}

fn expectRect(expected: Rect, actual: Rect) !void {
    const tolerance: f32 = 0.001;
    try std.testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
    try std.testing.expectApproxEqAbs(expected.w, actual.w, tolerance);
    try std.testing.expectApproxEqAbs(expected.h, actual.h, tolerance);
}

fn expectRelative(tree: *const WidgetTree, id: Id, expected: Rect) !void {
    try expectRect(expected, tree.nodeConst(id).?.rect);
}

test "block float slot remeasures auto flex subtree at final width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: Id = @enumFromInt(1);
    const first_id: Id = @enumFromInt(2);
    const second_id: Id = @enumFromInt(3);
    const inner_id: Id = @enumFromInt(4);
    const mixed_id: Id = @enumFromInt(5);
    const root_id: Id = @enumFromInt(6);

    try appendNode(&tree, first_id, inner_id, fixedStyle(.block, 30, 10), .{ .spacer = .{} });
    try appendNode(&tree, second_id, inner_id, fixedStyle(.block, 30, 10), .{ .spacer = .{} });
    var inner_style = autoStyle(.flex);
    inner_style.direction = .row;
    inner_style.flex_wrap = .wrap;
    inner_style.@"align" = .start;
    inner_style.align_content = .start;
    try appendNode(&tree, inner_id, mixed_id, inner_style, .{ .row = .{} });
    var mixed_style = autoStyle(.flex);
    mixed_style.direction = .column;
    mixed_style.@"align" = .stretch;
    mixed_style.overflow = .{ .width = .hidden, .height = .hidden };
    try appendNode(&tree, mixed_id, root_id, mixed_style, .{ .column = .{} });
    var float_style = fixedStyle(.block, 60, 20);
    float_style.float = .left;
    try appendNode(&tree, float_id, root_id, float_style, .{ .spacer = .{} });
    try appendNode(&tree, root_id, .root, fixedStyle(.flow_root, 100, 30), .{ .column = .{} });

    try tree.appendChild(inner_id, first_id);
    try tree.appendChild(inner_id, second_id);
    try tree.appendChild(mixed_id, inner_id);
    try tree.appendChild(root_id, float_id);
    try tree.appendChild(root_id, mixed_id);

    try layout(&tree, .{ .width = 100, .height = 30 });

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 30 });
    try expectRelative(&tree, float_id, .{ .x = 0, .y = 0, .w = 60, .h = 20 });
    try expectRelative(&tree, mixed_id, .{ .x = 60, .y = 0, .w = 40, .h = 20 });
    try expectRelative(&tree, inner_id, .{ .x = 0, .y = 0, .w = 40, .h = 20 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 30, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 10, .w = 30, .h = 10 });
}
