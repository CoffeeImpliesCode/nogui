const std = @import("std");

const flex = @import("flex.zig");
const Id = @import("id.zig").Id;
const widget = @import("widget.zig");

const PaintStyle = widget.PaintStyle;
const Rect = widget.Rect;
const Size = widget.Size;
const Style = widget.Style;
const WidgetKind = widget.WidgetKind;
const WidgetNode = widget.WidgetNode;
const WidgetTree = widget.WidgetTree;
const testing = std.testing;

fn appendNode(
    tree: *WidgetTree,
    id: Id,
    parent: Id,
    kind: WidgetKind,
    node_style: Style,
) !void {
    try tree.nodes.append(tree.allocator, WidgetNode{
        .id = id,
        .kind = kind,
        .parent = parent,
        .style = node_style,
        .paint = PaintStyle{},
    });
}

fn wireChildren(tree: *WidgetTree) !void {
    for (tree.nodes.items) |*node| {
        if (node.parent == .root) continue;
        const parent = tree.node(node.parent).?;
        try tree.appendChild(parent.id, node.id);
    }
}

fn expectRect(tree: *const WidgetTree, id: Id, expected: Rect) !void {
    try testing.expectEqual(expected, tree.nodeConst(id).?.rect);
}

fn expectRectApprox(tree: *const WidgetTree, id: Id, expected: Rect) !void {
    const actual = tree.nodeConst(id).?.rect;
    const tolerance: f32 = 0.01;
    try testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
    try testing.expectApproxEqAbs(expected.w, actual.w, tolerance);
    try testing.expectApproxEqAbs(expected.h, actual.h, tolerance);
}

test "test_fixtures/flex/flex_direction_row.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child_1: Id = @enumFromInt(1);
    const child_2: Id = @enumFromInt(2);
    const child_3: Id = @enumFromInt(3);
    const root: Id = @enumFromInt(4);
    const child_style: Style = .{
        .size = .{ .width = .{ .length = 10 }, .height = .auto },
    };
    try appendNode(&tree, child_1, root, .{ .spacer = .{} }, child_style);
    try appendNode(&tree, child_2, root, .{ .spacer = .{} }, child_style);
    try appendNode(&tree, child_3, root, .{ .spacer = .{} }, child_style);
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .row,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 100, .height = 100 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRect(&tree, child_1, .{ .x = 0, .y = 0, .w = 10, .h = 100 });
    try expectRect(&tree, child_2, .{ .x = 10, .y = 0, .w = 10, .h = 100 });
    try expectRect(&tree, child_3, .{ .x = 20, .y = 0, .w = 10, .h = 100 });
}

test "test_fixtures/flex/flex_direction_column.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child_1: Id = @enumFromInt(1);
    const child_2: Id = @enumFromInt(2);
    const child_3: Id = @enumFromInt(3);
    const root: Id = @enumFromInt(4);
    const child_style: Style = .{
        .size = .{ .width = .auto, .height = .{ .length = 10 } },
    };
    try appendNode(&tree, child_1, root, .{ .spacer = .{} }, child_style);
    try appendNode(&tree, child_2, root, .{ .spacer = .{} }, child_style);
    try appendNode(&tree, child_3, root, .{ .spacer = .{} }, child_style);
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .column,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 100, .height = 100 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRect(&tree, child_1, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    try expectRect(&tree, child_2, .{ .x = 0, .y = 10, .w = 100, .h = 10 });
    try expectRect(&tree, child_3, .{ .x = 0, .y = 20, .w = 100, .h = 10 });
}

test "test_fixtures/flex/flex_direction_row_reverse.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child_1: Id = @enumFromInt(1);
    const child_2: Id = @enumFromInt(2);
    const child_3: Id = @enumFromInt(3);
    const root: Id = @enumFromInt(4);
    const child_style: Style = .{
        .size = .{ .width = .{ .length = 10 }, .height = .auto },
    };
    try appendNode(&tree, child_1, root, .{ .spacer = .{} }, child_style);
    try appendNode(&tree, child_2, root, .{ .spacer = .{} }, child_style);
    try appendNode(&tree, child_3, root, .{ .spacer = .{} }, child_style);
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .row_reverse,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 100, .height = 100 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRect(&tree, child_1, .{ .x = 90, .y = 0, .w = 10, .h = 100 });
    try expectRect(&tree, child_2, .{ .x = 80, .y = 0, .w = 10, .h = 100 });
    try expectRect(&tree, child_3, .{ .x = 70, .y = 0, .w = 10, .h = 100 });
}

test "test_fixtures/flex/flex_direction_column_reverse.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child_1: Id = @enumFromInt(1);
    const child_2: Id = @enumFromInt(2);
    const child_3: Id = @enumFromInt(3);
    const root: Id = @enumFromInt(4);
    const child_style: Style = .{
        .size = .{ .width = .auto, .height = .{ .length = 10 } },
    };
    try appendNode(&tree, child_1, root, .{ .spacer = .{} }, child_style);
    try appendNode(&tree, child_2, root, .{ .spacer = .{} }, child_style);
    try appendNode(&tree, child_3, root, .{ .spacer = .{} }, child_style);
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .column_reverse,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 100, .height = 100 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRect(&tree, child_1, .{ .x = 0, .y = 90, .w = 100, .h = 10 });
    try expectRect(&tree, child_2, .{ .x = 0, .y = 80, .w = 100, .h = 10 });
    try expectRect(&tree, child_3, .{ .x = 0, .y = 70, .w = 100, .h = 10 });
}

test "test_fixtures/flex/wrap_row.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child_1: Id = @enumFromInt(1);
    const child_2: Id = @enumFromInt(2);
    const child_3: Id = @enumFromInt(3);
    const child_4: Id = @enumFromInt(4);
    const root: Id = @enumFromInt(5);
    try appendNode(&tree, child_1, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 31 }, .height = .{ .length = 30 } },
    });
    try appendNode(&tree, child_2, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 32 }, .height = .{ .length = 30 } },
    });
    try appendNode(&tree, child_3, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 33 }, .height = .{ .length = 30 } },
    });
    try appendNode(&tree, child_4, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 34 }, .height = .{ .length = 30 } },
    });
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .row,
        .wrap = .wrap,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 60 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 100, .height = 60 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 60 });
    try expectRect(&tree, child_1, .{ .x = 0, .y = 0, .w = 31, .h = 30 });
    try expectRect(&tree, child_2, .{ .x = 31, .y = 0, .w = 32, .h = 30 });
    try expectRect(&tree, child_3, .{ .x = 63, .y = 0, .w = 33, .h = 30 });
    try expectRect(&tree, child_4, .{ .x = 0, .y = 30, .w = 34, .h = 30 });
}

test "test_fixtures/flex/wrap_column.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child_1: Id = @enumFromInt(1);
    const child_2: Id = @enumFromInt(2);
    const child_3: Id = @enumFromInt(3);
    const child_4: Id = @enumFromInt(4);
    const root: Id = @enumFromInt(5);
    try appendNode(&tree, child_1, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 30 }, .height = .{ .length = 31 } },
    });
    try appendNode(&tree, child_2, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 30 }, .height = .{ .length = 32 } },
    });
    try appendNode(&tree, child_3, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 30 }, .height = .{ .length = 33 } },
    });
    try appendNode(&tree, child_4, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 30 }, .height = .{ .length = 34 } },
    });
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .column,
        .wrap = .wrap,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 100, .height = 100 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRect(&tree, child_1, .{ .x = 0, .y = 0, .w = 30, .h = 31 });
    try expectRect(&tree, child_2, .{ .x = 0, .y = 31, .w = 30, .h = 32 });
    try expectRect(&tree, child_3, .{ .x = 0, .y = 63, .w = 30, .h = 33 });
    try expectRect(&tree, child_4, .{ .x = 50, .y = 0, .w = 30, .h = 34 });
}

test "test_fixtures/flex/wrap_reverse_column_fixed_size.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child_1: Id = @enumFromInt(1);
    const child_2: Id = @enumFromInt(2);
    const child_3: Id = @enumFromInt(3);
    const child_4: Id = @enumFromInt(4);
    const child_5: Id = @enumFromInt(5);
    const root: Id = @enumFromInt(6);
    try appendNode(&tree, child_1, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 30 }, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, child_2, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 30 }, .height = .{ .length = 20 } },
    });
    try appendNode(&tree, child_3, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 30 }, .height = .{ .length = 30 } },
    });
    try appendNode(&tree, child_4, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 30 }, .height = .{ .length = 40 } },
    });
    try appendNode(&tree, child_5, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 30 }, .height = .{ .length = 50 } },
    });
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .column,
        .wrap = .wrap_reverse,
        .@"align" = .center,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 100 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 200, .height = 100 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 200, .h = 100 });
    try expectRect(&tree, child_1, .{ .x = 135, .y = 0, .w = 30, .h = 10 });
    try expectRect(&tree, child_2, .{ .x = 135, .y = 10, .w = 30, .h = 20 });
    try expectRect(&tree, child_3, .{ .x = 135, .y = 30, .w = 30, .h = 30 });
    try expectRect(&tree, child_4, .{ .x = 135, .y = 60, .w = 30, .h = 40 });
    try expectRect(&tree, child_5, .{ .x = 35, .y = 0, .w = 30, .h = 50 });
}

test "test_fixtures/flex/gap_row_gap_determines_parent_height.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child_1: Id = @enumFromInt(1);
    const child_2: Id = @enumFromInt(2);
    const child_3: Id = @enumFromInt(3);
    const root: Id = @enumFromInt(4);
    try appendNode(&tree, child_1, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .auto, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, child_2, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .auto, .height = .{ .length = 20 } },
    });
    try appendNode(&tree, child_3, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .auto, .height = .{ .length = 30 } },
    });
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .column,
        .gap = .{ .length = 10 },
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 80 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 100, .height = 80 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 80 });
    try expectRect(&tree, child_1, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    try expectRect(&tree, child_2, .{ .x = 0, .y = 20, .w = 100, .h = 20 });
    try expectRect(&tree, child_3, .{ .x = 0, .y = 50, .w = 100, .h = 30 });
}

test "test_fixtures/flex/gap_column_gap_determines_parent_width.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child_1: Id = @enumFromInt(1);
    const child_2: Id = @enumFromInt(2);
    const child_3: Id = @enumFromInt(3);
    const root: Id = @enumFromInt(4);
    try appendNode(&tree, child_1, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 10 }, .height = .auto },
    });
    try appendNode(&tree, child_2, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 20 }, .height = .auto },
    });
    try appendNode(&tree, child_3, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 30 }, .height = .auto },
    });
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .row,
        .gap = .{ .length = 10 },
        .size = .{ .width = .{ .length = 80 }, .height = .{ .length = 100 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 80, .height = 100 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 80, .h = 100 });
    try expectRect(&tree, child_1, .{ .x = 0, .y = 0, .w = 10, .h = 100 });
    try expectRect(&tree, child_2, .{ .x = 20, .y = 0, .w = 20, .h = 100 });
    try expectRect(&tree, child_3, .{ .x = 50, .y = 0, .w = 30, .h = 100 });
}

test "test_fixtures/flex/flex_basis_flex_grow_row.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child_1: Id = @enumFromInt(1);
    const child_2: Id = @enumFromInt(2);
    const root: Id = @enumFromInt(3);
    try appendNode(&tree, child_1, root, .{ .spacer = .{} }, .{
        .grow = 1,
        .flex_basis = .{ .length = 50 },
    });
    try appendNode(&tree, child_2, root, .{ .spacer = .{} }, .{
        .grow = 1,
    });
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .row,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 100, .height = 100 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRect(&tree, child_1, .{ .x = 0, .y = 0, .w = 75, .h = 100 });
    try expectRect(&tree, child_2, .{ .x = 75, .y = 0, .w = 25, .h = 100 });
}

test "test_fixtures/flex/flex_basis_flex_shrink_row.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child_1: Id = @enumFromInt(1);
    const child_2: Id = @enumFromInt(2);
    const root: Id = @enumFromInt(3);
    try appendNode(&tree, child_1, root, .{ .spacer = .{} }, .{
        .flex_basis = .{ .length = 100 },
    });
    try appendNode(&tree, child_2, root, .{ .spacer = .{} }, .{
        .flex_basis = .{ .length = 50 },
    });
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .row,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 100, .height = 100 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRectApprox(&tree, child_1, .{ .x = 0, .y = 0, .w = 66.6667, .h = 100 });
    try expectRectApprox(
        &tree,
        child_2,
        .{ .x = 66.6667, .y = 0, .w = 33.3333, .h = 100 },
    );
}

test "test_fixtures/flex/align_items_center.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child: Id = @enumFromInt(1);
    const root: Id = @enumFromInt(2);
    try appendNode(&tree, child, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 10 }, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .row,
        .@"align" = .center,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 100, .height = 100 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRect(&tree, child, .{ .x = 0, .y = 45, .w = 10, .h = 10 });
}

test "test_fixtures/flex/align_items_flex_end.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child: Id = @enumFromInt(1);
    const root: Id = @enumFromInt(2);
    try appendNode(&tree, child, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 10 }, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .row,
        .@"align" = .end,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 100, .height = 100 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRect(&tree, child, .{ .x = 0, .y = 90, .w = 10, .h = 10 });
}

test "test_fixtures/flex/align_items_stretch.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child: Id = @enumFromInt(1);
    const root: Id = @enumFromInt(2);
    try appendNode(&tree, child, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 10 }, .height = .auto },
    });
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .row,
        .@"align" = .stretch,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 100, .height = 100 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRect(&tree, child, .{ .x = 0, .y = 0, .w = 10, .h = 100 });
}

test "test_fixtures/flex/justify_content_column_center.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child_1: Id = @enumFromInt(1);
    const child_2: Id = @enumFromInt(2);
    const child_3: Id = @enumFromInt(3);
    const root: Id = @enumFromInt(4);
    const child_style: Style = .{
        .size = .{ .width = .auto, .height = .{ .length = 10 } },
    };
    try appendNode(&tree, child_1, root, .{ .spacer = .{} }, child_style);
    try appendNode(&tree, child_2, root, .{ .spacer = .{} }, child_style);
    try appendNode(&tree, child_3, root, .{ .spacer = .{} }, child_style);
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .column,
        .justify = .center,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 100, .height = 100 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRect(&tree, child_1, .{ .x = 0, .y = 35, .w = 100, .h = 10 });
    try expectRect(&tree, child_2, .{ .x = 0, .y = 45, .w = 100, .h = 10 });
    try expectRect(&tree, child_3, .{ .x = 0, .y = 55, .w = 100, .h = 10 });
}

test "test_fixtures/flex/margin_auto_left.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child_1: Id = @enumFromInt(1);
    const child_2: Id = @enumFromInt(2);
    const root: Id = @enumFromInt(3);
    try appendNode(&tree, child_1, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 50 }, .height = .{ .length = 50 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .auto,
        },
    });
    try appendNode(&tree, child_2, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 50 }, .height = .{ .length = 50 } },
    });
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .row,
        .@"align" = .center,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 200 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 200, .height = 200 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 200, .h = 200 });
    try expectRect(&tree, child_1, .{ .x = 100, .y = 75, .w = 50, .h = 50 });
    try expectRect(&tree, child_2, .{ .x = 150, .y = 75, .w = 50, .h = 50 });
}

test "test_fixtures/flex/margin_auto_top.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child_1: Id = @enumFromInt(1);
    const child_2: Id = @enumFromInt(2);
    const root: Id = @enumFromInt(3);
    try appendNode(&tree, child_1, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 50 }, .height = .{ .length = 50 } },
        .margin_inset = .{
            .top = .auto,
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, child_2, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .length = 50 }, .height = .{ .length = 50 } },
    });
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .row,
        .@"align" = .center,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 200 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 200, .height = 200 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 200, .h = 200 });
    try expectRect(&tree, child_1, .{ .x = 0, .y = 150, .w = 50, .h = 50 });
    try expectRect(&tree, child_2, .{ .x = 50, .y = 75, .w = 50, .h = 50 });
}

test "test_fixtures/flex/percentage_width_height.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child: Id = @enumFromInt(1);
    const root: Id = @enumFromInt(2);
    try appendNode(&tree, child, root, .{ .spacer = .{} }, .{
        .size = .{ .width = .{ .percent = 0.3 }, .height = .{ .percent = 0.3 } },
    });
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .row,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 400 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 200, .height = 400 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 200, .h = 400 });
    try expectRectApprox(&tree, child, .{ .x = 0, .y = 0, .w = 60, .h = 120 });
}

test "test_fixtures/flex/percentage_flex_basis.html" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const child_1: Id = @enumFromInt(1);
    const child_2: Id = @enumFromInt(2);
    const root: Id = @enumFromInt(3);
    try appendNode(&tree, child_1, root, .{ .spacer = .{} }, .{
        .grow = 1,
        .flex_basis = .{ .percent = 0.5 },
    });
    try appendNode(&tree, child_2, root, .{ .spacer = .{} }, .{
        .grow = 1,
        .flex_basis = .{ .percent = 0.25 },
    });
    try appendNode(&tree, root, .root, .{ .row = .{} }, .{
        .direction = .row,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 200 } },
    });
    try wireChildren(&tree);

    flex.layout(&tree, Size{ .width = 200, .height = 200 });

    try expectRect(&tree, root, .{ .x = 0, .y = 0, .w = 200, .h = 200 });
    try expectRect(&tree, child_1, .{ .x = 0, .y = 0, .w = 125, .h = 200 });
    try expectRect(&tree, child_2, .{ .x = 125, .y = 0, .w = 75, .h = 200 });
}
