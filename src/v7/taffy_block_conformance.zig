const std = @import("std");

const Id = @import("id.zig").Id;
const flex = @import("flex.zig");
const widget = @import("widget.zig");

const PaintStyle = widget.PaintStyle;
const Rect = widget.Rect;
const Style = widget.Style;
const WidgetNode = widget.WidgetNode;
const WidgetTree = widget.WidgetTree;

const default_paint: PaintStyle = .{};
const rect_tolerance: f32 = 0.001;

fn appendNode(tree: *WidgetTree, id: Id, parent: Id, layout_style: Style) !void {
    const kind: widget.WidgetKind = if (layout_style.display == .block)
        .{ .column = .{} }
    else
        .{ .spacer = .{} };
    const node: WidgetNode = .{
        .id = id,
        .kind = kind,
        .parent = parent,
        .style = layout_style,
        .paint = default_paint,
    };
    try tree.nodes.append(tree.allocator, node);
}

fn expectRect(expected: Rect, actual: Rect) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, rect_tolerance);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, rect_tolerance);
    try std.testing.expectApproxEqAbs(expected.w, actual.w, rect_tolerance);
    try std.testing.expectApproxEqAbs(expected.h, actual.h, rect_tolerance);
}

fn expectRelative(tree: *const WidgetTree, id: Id, expected: Rect) !void {
    try expectRect(expected, tree.nodeConst(id).?.rect);
}

fn expectAbsolute(tree: *const WidgetTree, id: Id, expected: Rect) !void {
    try expectRect(expected, widget.absoluteRect(tree, id));
}

test "test_fixtures/block/block_basic.html" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first: Id = @enumFromInt(1);
    const second: Id = @enumFromInt(2);
    const root: Id = @enumFromInt(3);

    try appendNode(&tree, first, root, .{
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, second, root, .{
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, root, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 50 }, .height = .auto },
    });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);

    flex.layout(&tree, .{ .width = 50, .height = 30 });

    try expectRelative(&tree, root, .{ .x = 0, .y = 0, .w = 50, .h = 20 });
    try expectRelative(&tree, first, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
    try expectRelative(&tree, second, .{ .x = 0, .y = 10, .w = 50, .h = 10 });
}

test "test_fixtures/block/block_padding_border_fixed_size.html" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first: Id = @enumFromInt(1);
    const second: Id = @enumFromInt(2);
    const root: Id = @enumFromInt(3);

    try appendNode(&tree, first, root, .{
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, second, root, .{
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, root, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 50 },
        },
        .padding = .{ .top = 1, .right = 3, .bottom = 5, .left = 7 },
        .border = .{ .top = 2, .right = 4, .bottom = 6, .left = 8 },
    });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);

    flex.layout(&tree, .{ .width = 50, .height = 50 });

    try expectRelative(&tree, root, .{ .x = 0, .y = 0, .w = 50, .h = 50 });
    try expectRelative(&tree, first, .{ .x = 0, .y = 0, .w = 28, .h = 10 });
    try expectRelative(&tree, second, .{ .x = 0, .y = 10, .w = 28, .h = 10 });
    try expectAbsolute(&tree, first, .{ .x = 15, .y = 3, .w = 28, .h = 10 });
    try expectAbsolute(&tree, second, .{ .x = 15, .y = 13, .w = 28, .h = 10 });
}

test "test_fixtures/block/block_inset_fixed.html" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first: Id = @enumFromInt(1);
    const second: Id = @enumFromInt(2);
    const third: Id = @enumFromInt(3);
    const root: Id = @enumFromInt(4);

    try appendNode(&tree, first, root, .{
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 10 } },
        .inset = .{
            .top = .{ .length = 4 },
            .right = .auto,
            .bottom = .auto,
            .left = .{ .length = 2 },
        },
    });
    try appendNode(&tree, second, root, .{
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 10 } },
        .inset = .{
            .top = .auto,
            .right = .{ .length = 6 },
            .bottom = .{ .length = 8 },
            .left = .auto,
        },
    });
    try appendNode(&tree, third, root, .{
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 10 } },
        .inset = .{
            .top = .{ .length = 4 },
            .right = .{ .length = 6 },
            .bottom = .{ .length = 8 },
            .left = .{ .length = 2 },
        },
    });
    try appendNode(&tree, root, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 50 }, .height = .auto },
    });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);
    try tree.appendChild(root, third);

    flex.layout(&tree, .{ .width = 50, .height = 30 });

    try expectRelative(&tree, root, .{ .x = 0, .y = 0, .w = 50, .h = 30 });
    try expectRelative(&tree, first, .{ .x = 2, .y = 4, .w = 50, .h = 10 });
    try expectRelative(&tree, second, .{ .x = -6, .y = 2, .w = 50, .h = 10 });
    try expectRelative(&tree, third, .{ .x = 2, .y = 24, .w = 50, .h = 10 });
}

test "test_fixtures/block/block_item_max_width.html" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first: Id = @enumFromInt(1);
    const second: Id = @enumFromInt(2);
    const root: Id = @enumFromInt(3);

    try appendNode(&tree, first, root, .{
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 50 } },
        .max_size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try appendNode(&tree, second, root, .{
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 50 } },
        .max_size = .{ .width = .{ .length = 300 }, .height = .auto },
    });
    try appendNode(&tree, root, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 200 },
            .height = .{ .length = 200 },
        },
    });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);

    flex.layout(&tree, .{ .width = 200, .height = 200 });

    try expectRelative(&tree, root, .{ .x = 0, .y = 0, .w = 200, .h = 200 });
    try expectRelative(&tree, first, .{ .x = 0, .y = 0, .w = 100, .h = 50 });
    try expectRelative(&tree, second, .{ .x = 0, .y = 50, .w = 200, .h = 50 });
}

test "test_fixtures/block/block_item_min_width_overrides_max_width.html" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child: Id = @enumFromInt(1);
    const root: Id = @enumFromInt(2);

    try appendNode(&tree, child, root, .{
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 50 } },
        .min_size = .{ .width = .{ .length = 200 }, .height = .auto },
        .max_size = .{ .width = .{ .length = 50 }, .height = .auto },
    });
    try appendNode(&tree, root, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(root, child);

    flex.layout(&tree, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, child, .{ .x = 0, .y = 0, .w = 200, .h = 50 });
}

test "test_fixtures/block/block_absolute_layout_no_size.html" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child: Id = @enumFromInt(1);
    const root: Id = @enumFromInt(2);

    try appendNode(&tree, child, root, .{
        .position = .absolute,
        .box_sizing = .border_box,
    });
    try appendNode(&tree, root, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(root, child);

    flex.layout(&tree, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, child, .{ .x = 0, .y = 0, .w = 0, .h = 0 });
}

test "test_fixtures/block/block_absolute_layout_width_height_start_top.html" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child: Id = @enumFromInt(1);
    const root: Id = @enumFromInt(2);

    try appendNode(&tree, child, root, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 10 },
            .height = .{ .length = 10 },
        },
        .inset = .{
            .top = .{ .length = 10 },
            .right = .auto,
            .bottom = .auto,
            .left = .{ .length = 10 },
        },
    });
    try appendNode(&tree, root, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(root, child);

    flex.layout(&tree, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, child, .{ .x = 10, .y = 10, .w = 10, .h = 10 });
}

test "test_fixtures/block/block_absolute_layout_width_height_end_bottom.html" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child: Id = @enumFromInt(1);
    const root: Id = @enumFromInt(2);

    try appendNode(&tree, child, root, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 10 },
            .height = .{ .length = 10 },
        },
        .inset = .{
            .top = .auto,
            .right = .{ .length = 10 },
            .bottom = .{ .length = 10 },
            .left = .auto,
        },
    });
    try appendNode(&tree, root, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(root, child);

    flex.layout(&tree, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, child, .{ .x = 80, .y = 80, .w = 10, .h = 10 });
}

test "test_fixtures/block/block_absolute_layout_start_top_end_bottom.html" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child: Id = @enumFromInt(1);
    const root: Id = @enumFromInt(2);

    try appendNode(&tree, child, root, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .inset = .{
            .top = .{ .length = 10 },
            .right = .{ .length = 10 },
            .bottom = .{ .length = 10 },
            .left = .{ .length = 10 },
        },
    });
    try appendNode(&tree, root, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(root, child);

    flex.layout(&tree, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, child, .{ .x = 10, .y = 10, .w = 80, .h = 80 });
}

test "test_fixtures/block/block_absolute_layout_percentage_bottom_based_on_parent_height.html" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const top: Id = @enumFromInt(1);
    const bottom: Id = @enumFromInt(2);
    const stretched: Id = @enumFromInt(3);
    const root: Id = @enumFromInt(4);

    try appendNode(&tree, top, root, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 10 },
            .height = .{ .length = 10 },
        },
        .inset = .{
            .top = .{ .percent = 0.5 },
            .right = .auto,
            .bottom = .auto,
            .left = .auto,
        },
    });
    try appendNode(&tree, bottom, root, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 10 },
            .height = .{ .length = 10 },
        },
        .inset = .{
            .top = .auto,
            .right = .auto,
            .bottom = .{ .percent = 0.5 },
            .left = .auto,
        },
    });
    try appendNode(&tree, stretched, root, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 10 }, .height = .auto },
        .inset = .{
            .top = .{ .percent = 0.1 },
            .right = .auto,
            .bottom = .{ .percent = 0.1 },
            .left = .auto,
        },
    });
    try appendNode(&tree, root, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 200 },
        },
    });
    try tree.appendChild(root, top);
    try tree.appendChild(root, bottom);
    try tree.appendChild(root, stretched);

    flex.layout(&tree, .{ .width = 100, .height = 200 });
    // The current upstream fixture sets width: 10px on the third child; only
    // its height is derived from the opposing percentage insets.

    try expectRelative(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 200 });
    try expectRelative(&tree, top, .{ .x = 0, .y = 100, .w = 10, .h = 10 });
    try expectRelative(&tree, bottom, .{ .x = 0, .y = 90, .w = 10, .h = 10 });
    try expectRelative(&tree, stretched, .{ .x = 0, .y = 20, .w = 10, .h = 160 });
}

test "test_fixtures/block/block_absolute_child_with_margin_x.html" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const left: Id = @enumFromInt(1);
    const right: Id = @enumFromInt(2);
    const both: Id = @enumFromInt(3);
    const root: Id = @enumFromInt(4);
    const child_size: widget.DimensionSize = .{
        .width = .{ .length = 9 },
        .height = .{ .length = 9 },
    };

    try appendNode(&tree, left, root, .{
        .position = .absolute,
        .box_sizing = .border_box,
        .size = child_size,
        .margin = .{ .left = 7 },
    });
    try appendNode(&tree, right, root, .{
        .position = .absolute,
        .box_sizing = .border_box,
        .size = child_size,
        .margin = .{ .right = 7 },
    });
    try appendNode(&tree, both, root, .{
        .position = .absolute,
        .box_sizing = .border_box,
        .size = child_size,
        .margin = .{ .left = 10, .right = 5 },
    });
    try appendNode(&tree, root, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 20 },
            .height = .{ .length = 37 },
        },
    });
    try tree.appendChild(root, left);
    try tree.appendChild(root, right);
    try tree.appendChild(root, both);

    flex.layout(&tree, .{ .width = 20, .height = 37 });
    try expectRelative(&tree, root, .{ .x = 0, .y = 0, .w = 20, .h = 37 });
    try expectRelative(&tree, left, .{ .x = 7, .y = 0, .w = 9, .h = 9 });
    try expectRelative(&tree, right, .{ .x = 0, .y = 0, .w = 9, .h = 9 });
    try expectRelative(&tree, both, .{ .x = 10, .y = 0, .w = 9, .h = 9 });
}

test "test_fixtures/block/block_absolute_child_with_margin_y.html" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const top: Id = @enumFromInt(1);
    const bottom: Id = @enumFromInt(2);
    const both: Id = @enumFromInt(3);
    const root: Id = @enumFromInt(4);
    const child_size: widget.DimensionSize = .{
        .width = .{ .length = 9 },
        .height = .{ .length = 9 },
    };

    try appendNode(&tree, top, root, .{
        .position = .absolute,
        .box_sizing = .border_box,
        .size = child_size,
        .margin = .{ .top = 7 },
    });
    try appendNode(&tree, bottom, root, .{
        .position = .absolute,
        .box_sizing = .border_box,
        .size = child_size,
        .margin = .{ .bottom = 7 },
    });
    try appendNode(&tree, both, root, .{
        .position = .absolute,
        .box_sizing = .border_box,
        .size = child_size,
        .margin = .{ .top = 10, .bottom = 5 },
    });
    try appendNode(&tree, root, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 20 },
            .height = .{ .length = 37 },
        },
    });
    try tree.appendChild(root, top);
    try tree.appendChild(root, bottom);
    try tree.appendChild(root, both);

    flex.layout(&tree, .{ .width = 20, .height = 37 });

    try expectRelative(&tree, root, .{ .x = 0, .y = 0, .w = 20, .h = 37 });
    try expectRelative(&tree, top, .{ .x = 0, .y = 7, .w = 9, .h = 9 });
    try expectRelative(&tree, bottom, .{ .x = 0, .y = 0, .w = 9, .h = 9 });
    try expectRelative(&tree, both, .{ .x = 0, .y = 10, .w = 9, .h = 9 });
}

test "test_fixtures/block/block_absolute_layout_within_border.html" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const start: Id = @enumFromInt(1);
    const end: Id = @enumFromInt(2);
    const start_margin: Id = @enumFromInt(3);
    const end_margin: Id = @enumFromInt(4);
    const root: Id = @enumFromInt(5);
    const child_size: widget.DimensionSize = .{
        .width = .{ .length = 50 },
        .height = .{ .length = 50 },
    };

    try appendNode(&tree, start, root, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = child_size,
        .inset = .{
            .top = .{ .length = 0 },
            .right = .auto,
            .bottom = .auto,
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, end, root, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = child_size,
        .inset = .{
            .top = .auto,
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .auto,
        },
    });
    try appendNode(&tree, start_margin, root, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = child_size,
        .inset = .{
            .top = .{ .length = 0 },
            .right = .auto,
            .bottom = .auto,
            .left = .{ .length = 0 },
        },
        .margin = .{ .top = 10, .right = 10, .bottom = 10, .left = 10 },
    });
    try appendNode(&tree, end_margin, root, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = child_size,
        .inset = .{
            .top = .auto,
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .auto,
        },
        .margin = .{ .top = 10, .right = 10, .bottom = 10, .left = 10 },
    });
    try appendNode(&tree, root, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
        .border = .{ .top = 10, .right = 10, .bottom = 10, .left = 10 },
        .padding = .{ .top = 10, .right = 10, .bottom = 10, .left = 10 },
    });
    try tree.appendChild(root, start);
    try tree.appendChild(root, end);
    try tree.appendChild(root, start_margin);
    try tree.appendChild(root, end_margin);

    flex.layout(&tree, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, start, .{ .x = 0, .y = 0, .w = 50, .h = 50 });
    try expectRelative(&tree, end, .{ .x = 10, .y = 10, .w = 50, .h = 50 });
    try expectRelative(&tree, start_margin, .{ .x = 10, .y = 10, .w = 50, .h = 50 });
    try expectRelative(&tree, end_margin, .{ .x = 0, .y = 0, .w = 50, .h = 50 });
    try expectAbsolute(&tree, start, .{ .x = 20, .y = 20, .w = 50, .h = 50 });
    try expectAbsolute(&tree, end, .{ .x = 30, .y = 30, .w = 50, .h = 50 });
    try expectAbsolute(&tree, start_margin, .{ .x = 30, .y = 30, .w = 50, .h = 50 });
    try expectAbsolute(&tree, end_margin, .{ .x = 20, .y = 20, .w = 50, .h = 50 });
}

test "test_fixtures/block/block_absolute_child_with_max_height.html" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const inner: Id = @enumFromInt(1);
    const absolute: Id = @enumFromInt(2);
    const root: Id = @enumFromInt(3);

    try appendNode(&tree, inner, absolute, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 150 },
        },
    });
    try appendNode(&tree, absolute, root, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .max_size = .{ .width = .auto, .height = .{ .length = 100 } },
        .inset = .{
            .top = .auto,
            .right = .auto,
            .bottom = .{ .length = 20 },
            .left = .auto,
        },
    });
    try appendNode(&tree, root, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 200 },
        },
    });
    try tree.appendChild(absolute, inner);
    try tree.appendChild(root, absolute);

    flex.layout(&tree, .{ .width = 100, .height = 200 });

    try expectRelative(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 200 });
    try expectRelative(&tree, absolute, .{ .x = 0, .y = 80, .w = 100, .h = 100 });
    try expectRelative(&tree, inner, .{ .x = 0, .y = 0, .w = 100, .h = 150 });
    try expectAbsolute(&tree, absolute, .{ .x = 0, .y = 80, .w = 100, .h = 100 });
    try expectAbsolute(&tree, inner, .{ .x = 0, .y = 80, .w = 100, .h = 150 });
}

test "test_fixtures/block/block_absolute_aspect_ratio_fill_width.html" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child: Id = @enumFromInt(1);
    const root: Id = @enumFromInt(2);

    try appendNode(&tree, child, root, .{
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .percent = 0.2 } },
        .inset = .{
            .top = .{ .percent = 0.05 },
            .right = .auto,
            .bottom = .auto,
            .left = .{ .percent = 0.05 },
        },
        .aspect_ratio = 3,
    });
    try appendNode(&tree, root, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 400 },
            .height = .{ .length = 300 },
        },
    });
    try tree.appendChild(root, child);

    flex.layout(&tree, .{ .width = 400, .height = 300 });

    try expectRelative(&tree, root, .{ .x = 0, .y = 0, .w = 400, .h = 300 });
    try expectRelative(&tree, child, .{ .x = 20, .y = 15, .w = 180, .h = 60 });
}
