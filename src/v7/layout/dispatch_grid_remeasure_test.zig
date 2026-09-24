//! Specifies final-area remeasurement across the grid-to-flex dispatcher bridge.

const std = @import("std");
const FrameNodeId = @import("../id.zig").FrameNodeId;
const layout_api = @import("root.zig");
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
    id: FrameNodeId,
    parent: FrameNodeId,
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

fn measureLabel(
    _: ?*anyopaque,
    _: []const u8,
    _: layout_api.MeasureInput,
) layout_api.LayoutError!layout_api.TextMeasurement {
    return .{ .width = 0, .height = 0 };
}

fn layout(tree: *WidgetTree, available: widget.Size) !void {
    try layout_api.layoutTree(tree, .{
        .allocator = std.testing.allocator,
        .available = available,
        .measure = .{ .callback = measureLabel },
    });
}

fn expectRect(expected: Rect, actual: Rect) !void {
    const tolerance: f32 = 0.001;
    try std.testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
    try std.testing.expectApproxEqAbs(expected.w, actual.w, tolerance);
    try std.testing.expectApproxEqAbs(expected.h, actual.h, tolerance);
}

fn expectRelative(tree: *const WidgetTree, id: FrameNodeId, expected: Rect) !void {
    const node = tree.nodeConst(id) orelse return error.TestUnexpectedResult;
    try expectRect(expected, node.rect);
}

test "grid remeasures auto flex child at final area width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @enumFromInt(1);
    const second_id: FrameNodeId = @enumFromInt(2);
    const flex_id: FrameNodeId = @enumFromInt(3);
    const grid_id: FrameNodeId = @enumFromInt(4);
    const columns = [_]style.GridTrack{ .{ .fixed = 60 }, .{ .fixed = 40 } };
    const rows = [_]style.GridTrack{.{ .fixed = 30 }};

    try appendNode(&tree, first_id, flex_id, fixedStyle(.block, 40, 10), .{ .spacer = .{} });
    try appendNode(&tree, second_id, flex_id, fixedStyle(.block, 40, 10), .{ .spacer = .{} });
    var flex_style = autoStyle(.flex);
    flex_style.direction = .row;
    flex_style.flex_wrap = .wrap;
    flex_style.@"align" = .start;
    try appendNode(&tree, flex_id, grid_id, flex_style, .{ .row = .{} });
    var grid_style = fixedStyle(.grid, 100, 30);
    grid_style.grid_template_columns = columns[0..];
    grid_style.grid_template_rows = rows[0..];
    grid_style.grid_justify_items = .stretch;
    grid_style.grid_align_items = .start;
    try appendNode(&tree, grid_id, .root, grid_style, .{ .column = .{} });
    try tree.appendChild(flex_id, first_id);
    try tree.appendChild(flex_id, second_id);
    try tree.appendChild(grid_id, flex_id);

    try layout(&tree, .{ .width = 100, .height = 30 });

    try expectRelative(&tree, grid_id, .{ .x = 0, .y = 0, .w = 100, .h = 30 });
    try expectRelative(&tree, flex_id, .{ .x = 0, .y = 0, .w = 60, .h = 20 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 40, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 10, .w = 40, .h = 10 });
}
