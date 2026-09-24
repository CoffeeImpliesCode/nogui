//! Specifies natural measurement across mixed dispatcher boundaries.

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
    return .{ .width = 30, .height = 12 };
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

test "fixed block root forces auto-height flex width and keeps natural height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const measured_id: FrameNodeId = @enumFromInt(1);
    const fixed_id: FrameNodeId = @enumFromInt(2);
    const flex_id: FrameNodeId = @enumFromInt(3);
    const root_id: FrameNodeId = @enumFromInt(4);

    try appendNode(
        &tree,
        measured_id,
        flex_id,
        autoStyle(.block),
        .{ .label = .{ .text = "measured" } },
    );
    try appendNode(
        &tree,
        fixed_id,
        flex_id,
        fixedStyle(.block, 20, 18),
        .{ .spacer = .{} },
    );
    var flex_style = autoStyle(.flex);
    flex_style.direction = .row;
    flex_style.@"align" = .start;
    flex_style.gap = .{ .length = 5 };
    try appendNode(&tree, flex_id, root_id, flex_style, .{ .row = .{} });
    var root_style = fixedStyle(.flow_root, 120, 60);
    root_style.size.height = .auto;
    try appendNode(
        &tree,
        root_id,
        .root,
        root_style,
        .{ .column = .{} },
    );
    try tree.appendChild(flex_id, measured_id);
    try tree.appendChild(flex_id, fixed_id);
    try tree.appendChild(root_id, flex_id);

    try layout(&tree, .{ .width = 120, .height = 60 });

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 120, .h = 18 });
    try expectRelative(&tree, flex_id, .{ .x = 0, .y = 0, .w = 120, .h = 18 });
    try expectRelative(&tree, measured_id, .{ .x = 0, .y = 0, .w = 30, .h = 12 });
    try expectRelative(&tree, fixed_id, .{ .x = 35, .y = 0, .w = 20, .h = 18 });
}

test "auto-height block preserves intrinsic main size of wrapped column flex" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @enumFromInt(1);
    const second_id: FrameNodeId = @enumFromInt(2);
    const flex_id: FrameNodeId = @enumFromInt(3);
    const root_id: FrameNodeId = @enumFromInt(4);
    try appendNode(&tree, first_id, flex_id, fixedStyle(.block, 20, 20), .{ .spacer = .{} });
    try appendNode(&tree, second_id, flex_id, fixedStyle(.block, 20, 20), .{ .spacer = .{} });
    var flex_style = autoStyle(.flex);
    flex_style.direction = .column;
    flex_style.flex_wrap = .wrap;
    flex_style.@"align" = .start;
    flex_style.size.width = .{ .length = 100 };
    try appendNode(&tree, flex_id, root_id, flex_style, .{ .column = .{} });
    var root_style = fixedStyle(.flow_root, 120, 60);
    root_style.size.height = .auto;
    try appendNode(&tree, root_id, .root, root_style, .{ .column = .{} });
    try tree.appendChild(flex_id, first_id);
    try tree.appendChild(flex_id, second_id);
    try tree.appendChild(root_id, flex_id);

    try layout(&tree, .{ .width = 120, .height = 60 });

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 120, .h = 40 });
    try expectRelative(&tree, flex_id, .{ .x = 0, .y = 0, .w = 100, .h = 40 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 20, .w = 20, .h = 20 });
}

test "mixed natural measurement allows width percentage with intrinsic height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: FrameNodeId = @enumFromInt(1);
    const flex_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);
    try appendNode(&tree, leaf_id, flex_id, fixedStyle(.block, 10, 10), .{ .spacer = .{} });
    var flex_style = autoStyle(.flex);
    flex_style.direction = .row;
    flex_style.@"align" = .start;
    flex_style.size.width = .{ .percent = 0.5 };
    try appendNode(&tree, flex_id, root_id, flex_style, .{ .row = .{} });
    var root_style = fixedStyle(.flow_root, 100, 40);
    root_style.size.height = .auto;
    try appendNode(&tree, root_id, .root, root_style, .{ .column = .{} });
    try tree.appendChild(flex_id, leaf_id);
    try tree.appendChild(root_id, flex_id);

    try layout(&tree, .{ .width = 100, .height = 40 });

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    try expectRelative(&tree, flex_id, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
}
test "fixed flex root uses auto grid tracks and gap as natural size" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @enumFromInt(1);
    const second_id: FrameNodeId = @enumFromInt(2);
    const grid_id: FrameNodeId = @enumFromInt(3);
    const root_id: FrameNodeId = @enumFromInt(4);
    const columns = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };
    const rows = [_]style.GridTrack{.{ .fixed = 10 }};

    try appendNode(&tree, first_id, grid_id, fixedStyle(.block, 20, 10), .{ .spacer = .{} });
    try appendNode(&tree, second_id, grid_id, fixedStyle(.block, 20, 10), .{ .spacer = .{} });
    var grid_style = autoStyle(.grid);
    grid_style.grid_template_columns = columns[0..];
    grid_style.grid_template_rows = rows[0..];
    grid_style.column_gap = .{ .length = 10 };
    grid_style.grid_justify_items = .start;
    grid_style.grid_align_items = .start;
    try appendNode(&tree, grid_id, root_id, grid_style, .{ .column = .{} });
    var root_style = fixedStyle(.flex, 100, 30);
    root_style.direction = .row;
    root_style.@"align" = .start;
    try appendNode(&tree, root_id, .root, root_style, .{ .row = .{} });
    try tree.appendChild(grid_id, first_id);
    try tree.appendChild(grid_id, second_id);
    try tree.appendChild(root_id, grid_id);

    try layout(&tree, .{ .width = 100, .height = 30 });

    try expectRelative(&tree, grid_id, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 30, .y = 0, .w = 20, .h = 10 });
}

test "fixed grid root gives wrapped flex a natural auto height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @enumFromInt(1);
    const second_id: FrameNodeId = @enumFromInt(2);
    const flex_id: FrameNodeId = @enumFromInt(3);
    const root_id: FrameNodeId = @enumFromInt(4);
    const columns = [_]style.GridTrack{.{ .fixed = 100 }};
    const rows = [_]style.GridTrack{.auto};

    try appendNode(&tree, first_id, flex_id, fixedStyle(.block, 60, 10), .{ .spacer = .{} });
    try appendNode(&tree, second_id, flex_id, fixedStyle(.block, 60, 10), .{ .spacer = .{} });
    var flex_style = autoStyle(.flex);
    flex_style.direction = .row;
    flex_style.flex_wrap = .wrap;
    flex_style.@"align" = .start;
    flex_style.size.width = .{ .length = 100 };
    try appendNode(&tree, flex_id, root_id, flex_style, .{ .row = .{} });
    var root_style = fixedStyle(.grid, 100, 40);
    root_style.grid_template_columns = columns[0..];
    root_style.grid_template_rows = rows[0..];
    root_style.grid_justify_items = .start;
    root_style.grid_align_items = .start;
    root_style.grid_align_content = .start;
    try appendNode(&tree, root_id, .root, root_style, .{ .column = .{} });
    try tree.appendChild(flex_id, first_id);
    try tree.appendChild(flex_id, second_id);
    try tree.appendChild(root_id, flex_id);

    try layout(&tree, .{ .width = 100, .height = 40 });

    try expectRelative(&tree, flex_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 60, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 10, .w = 60, .h = 10 });
}

test "cross-layout block natural size honors minimum and maximum constraints" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: FrameNodeId = @enumFromInt(1);
    const block_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, leaf_id, block_id, fixedStyle(.block, 50, 20), .{ .spacer = .{} });
    var block_style = autoStyle(.flow_root);
    block_style.min_size.width = .{ .length = 70 };
    block_style.max_size.height = .{ .length = 12 };
    try appendNode(&tree, block_id, root_id, block_style, .{ .column = .{} });
    var root_style = fixedStyle(.flex, 120, 30);
    root_style.direction = .row;
    root_style.@"align" = .start;
    try appendNode(&tree, root_id, .root, root_style, .{ .row = .{} });
    try tree.appendChild(block_id, leaf_id);
    try tree.appendChild(root_id, block_id);

    try layout(&tree, .{ .width = 120, .height = 30 });

    try expectRelative(&tree, block_id, .{ .x = 0, .y = 0, .w = 70, .h = 12 });
    try expectRelative(&tree, leaf_id, .{ .x = 0, .y = 0, .w = 50, .h = 20 });
}

test "hidden auto mixed subtree remains zero" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: FrameNodeId = @enumFromInt(1);
    const flex_id: FrameNodeId = @enumFromInt(2);
    const grid_id: FrameNodeId = @enumFromInt(3);
    const hidden_id: FrameNodeId = @enumFromInt(4);
    const visible_id: FrameNodeId = @enumFromInt(5);
    const root_id: FrameNodeId = @enumFromInt(6);

    try appendNode(&tree, leaf_id, flex_id, fixedStyle(.block, 10, 10), .{ .spacer = .{} });
    try appendNode(&tree, flex_id, grid_id, autoStyle(.flex), .{ .row = .{} });
    try appendNode(&tree, grid_id, hidden_id, autoStyle(.grid), .{ .column = .{} });
    try appendNode(&tree, hidden_id, root_id, autoStyle(.none), .{ .spacer = .{} });
    try appendNode(&tree, visible_id, root_id, fixedStyle(.block, 15, 10), .{ .spacer = .{} });
    var root_style = fixedStyle(.flex, 100, 20);
    root_style.direction = .row;
    root_style.@"align" = .start;
    try appendNode(&tree, root_id, .root, root_style, .{ .row = .{} });
    try tree.appendChild(flex_id, leaf_id);
    try tree.appendChild(grid_id, flex_id);
    try tree.appendChild(hidden_id, grid_id);
    try tree.appendChild(root_id, hidden_id);
    try tree.appendChild(root_id, visible_id);
    const leaf = tree.node(leaf_id) orelse return error.TestUnexpectedResult;
    leaf.rect = .{ .x = 1, .y = 2, .w = 3, .h = 4 };
    const flex = tree.node(flex_id) orelse return error.TestUnexpectedResult;
    flex.rect = .{ .x = 2, .y = 3, .w = 4, .h = 5 };
    const grid = tree.node(grid_id) orelse return error.TestUnexpectedResult;
    grid.rect = .{ .x = 3, .y = 4, .w = 5, .h = 6 };
    const hidden = tree.node(hidden_id) orelse return error.TestUnexpectedResult;
    hidden.rect = .{ .x = 4, .y = 5, .w = 6, .h = 7 };

    try layout(&tree, .{ .width = 100, .height = 20 });

    try expectRelative(&tree, hidden_id, .{});
    try expectRelative(&tree, grid_id, .{});
    try expectRelative(&tree, flex_id, .{});
    try expectRelative(&tree, leaf_id, .{});
    try expectRelative(&tree, visible_id, .{ .x = 0, .y = 0, .w = 15, .h = 10 });
    try std.testing.expect(tree.node(hidden_id).?.layout_hidden);
    try std.testing.expect(tree.node(grid_id).?.layout_hidden);
    try std.testing.expect(tree.node(flex_id).?.layout_hidden);
    try std.testing.expect(tree.node(leaf_id).?.layout_hidden);
}
