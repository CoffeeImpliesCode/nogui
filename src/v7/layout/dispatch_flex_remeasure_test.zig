//! Specifies final-width remeasurement across the flex-to-block dispatcher bridge.

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

test "flex bridge remeasures mixed block after main-axis shrink" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const inner_flex_id: Id = @enumFromInt(3);
    const mixed_block_id: Id = @enumFromInt(4);
    const sibling_id: Id = @enumFromInt(5);
    const root_id: Id = @enumFromInt(6);

    try appendNode(
        &tree,
        first_id,
        inner_flex_id,
        fixedStyle(.block, 40, 10),
        .{ .spacer = .{} },
    );
    try appendNode(
        &tree,
        second_id,
        inner_flex_id,
        fixedStyle(.block, 40, 10),
        .{ .spacer = .{} },
    );

    var inner_flex_style = autoStyle(.flex);
    inner_flex_style.direction = .row;
    inner_flex_style.flex_wrap = .wrap;
    inner_flex_style.@"align" = .start;
    inner_flex_style.align_content = .start;
    try appendNode(
        &tree,
        inner_flex_id,
        mixed_block_id,
        inner_flex_style,
        .{ .row = .{} },
    );

    var mixed_block_style = autoStyle(.block);
    mixed_block_style.flex_basis = .{ .length = 80 };
    mixed_block_style.min_size.width = .{ .length = 0 };
    try appendNode(
        &tree,
        mixed_block_id,
        root_id,
        mixed_block_style,
        .{ .column = .{} },
    );

    var sibling_style = autoStyle(.block);
    sibling_style.size.height = .{ .length = 10 };
    sibling_style.flex_basis = .{ .length = 40 };
    try appendNode(
        &tree,
        sibling_id,
        root_id,
        sibling_style,
        .{ .spacer = .{} },
    );

    var root_style = fixedStyle(.flex, 100, 40);
    root_style.direction = .row;
    root_style.@"align" = .start;
    try appendNode(&tree, root_id, .root, root_style, .{ .row = .{} });

    try tree.appendChild(inner_flex_id, first_id);
    try tree.appendChild(inner_flex_id, second_id);
    try tree.appendChild(mixed_block_id, inner_flex_id);
    try tree.appendChild(root_id, mixed_block_id);
    try tree.appendChild(root_id, sibling_id);

    try layout(&tree, .{ .width = 100, .height = 40 });

    const mixed_width: f32 = 200.0 / 3.0;
    const sibling_width: f32 = 100.0 / 3.0;
    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 40 });
    try expectRelative(
        &tree,
        mixed_block_id,
        .{ .x = 0, .y = 0, .w = mixed_width, .h = 20 },
    );
    try expectRelative(
        &tree,
        inner_flex_id,
        .{ .x = 0, .y = 0, .w = mixed_width, .h = 20 },
    );
    try expectRelative(
        &tree,
        sibling_id,
        .{ .x = mixed_width, .y = 0, .w = sibling_width, .h = 10 },
    );
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 40, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 10, .w = 40, .h = 10 });
}
