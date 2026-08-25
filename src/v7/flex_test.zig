//! Unit test regressions for flexbox layout fixes:
//! - flex-basis precedence over width/height
//! - flex-basis: auto fallback to width/height and intrinsic content size
//! - flex-basis: % in indefinite container falling back to auto
//! - multi-line align-content: space-between and space-evenly
//! - flex wrap gap deduction
//! - cross-axis aspect-ratio transfer into main size

const std = @import("std");
const testing = std.testing;
const Id = @import("id.zig").Id;
const widget = @import("widget.zig");
const flex = @import("flex.zig");

const WidgetTree = widget.WidgetTree;
const WidgetNode = widget.WidgetNode;
const WidgetKind = widget.WidgetKind;
const Rect = widget.Rect;

fn appendNode(tree: *WidgetTree, id: Id, parent: Id, kind: WidgetKind) !void {
    var node: WidgetNode = .{
        .id = id,
        .kind = kind,
        .parent = parent,
    };
    switch (kind) {
        .column => |container| {
            node.style.direction = .column;
            node.style.gap = container.gap;
        },
        .row => |container| {
            node.style.direction = .row;
            node.style.gap = container.gap;
        },
        .button => {
            node.style.direction = .row;
        },
        else => {},
    }
    try tree.nodes.append(tree.allocator, node);
}

fn wireChildren(tree: *WidgetTree) !void {
    for (tree.nodes.items) |*node| {
        if (node.parent == .root) continue;
        const parent = tree.node(node.parent) orelse continue;
        try parent.children.append(tree.allocator, node.id);
    }
}

test "flex-basis takes precedence over width and height" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const row: Id = @enumFromInt(1);
    const item1: Id = @enumFromInt(2);
    const col: Id = @enumFromInt(3);
    const item2: Id = @enumFromInt(4);

    // Row child: width = 100, flex_basis = 40 -> final width must be 40
    try appendNode(&tree, item1, row, .{ .label = .{ .text = "item1" } });
    try appendNode(&tree, row, .root, .{ .row = .{} });

    // Column child: height = 80, flex_basis = 30 -> final height must be 30
    try appendNode(&tree, item2, col, .{ .label = .{ .text = "item2" } });
    try appendNode(&tree, col, .root, .{ .column = .{} });

    try wireChildren(&tree);

    tree.node(item1).?.style.size.width = .{ .length = 100 };
    tree.node(item1).?.style.flex_basis = .{ .length = 40 };
    tree.node(item1).?.style.grow = 0;
    tree.node(item1).?.style.shrink = 0;

    tree.node(item2).?.style.size.height = .{ .length = 80 };
    tree.node(item2).?.style.flex_basis = .{ .length = 30 };
    tree.node(item2).?.style.grow = 0;
    tree.node(item2).?.style.shrink = 0;

    flex.layout(&tree, .{ .width = 400, .height = 400 });

    try testing.expectEqual(@as(f32, 40), tree.node(item1).?.rect.w);
    try testing.expectEqual(@as(f32, 30), tree.node(item2).?.rect.h);
}

test "flex-basis auto falls back to width/height and then intrinsic size" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const row: Id = @enumFromInt(1);
    const item_fixed: Id = @enumFromInt(2);
    const item_auto: Id = @enumFromInt(3);

    try appendNode(&tree, item_fixed, row, .{ .label = .{ .text = "fixed" } });
    try appendNode(&tree, item_auto, row, .{ .label = .{ .text = "auto" } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    try wireChildren(&tree);

    // item_fixed: flex_basis = auto, width = 75 -> width = 75
    tree.node(item_fixed).?.style.flex_basis = .auto;
    tree.node(item_fixed).?.style.size.width = .{ .length = 75 };
    tree.node(item_fixed).?.style.grow = 0;
    tree.node(item_fixed).?.style.shrink = 0;

    // item_auto: flex_basis = auto, width = auto -> width = natural (text "auto" -> 40)
    tree.node(item_auto).?.style.flex_basis = .auto;
    tree.node(item_auto).?.style.size.width = .auto;
    tree.node(item_auto).?.style.grow = 0;
    tree.node(item_auto).?.style.shrink = 0;

    flex.layout(&tree, .{ .width = 400, .height = 100 });

    try testing.expectEqual(@as(f32, 75), tree.node(item_fixed).?.rect.w);
    try testing.expectEqual(@as(f32, 40), tree.node(item_auto).?.rect.w);
}

test "flex-basis percent in indefinite container falls back to auto/intrinsic size" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const outer_col: Id = @enumFromInt(1);
    const inner_row: Id = @enumFromInt(2);
    const item: Id = @enumFromInt(3);

    try appendNode(&tree, item, inner_row, .{ .label = .{ .text = "percent" } });
    try appendNode(&tree, inner_row, outer_col, .{ .row = .{} });
    try appendNode(&tree, outer_col, .root, .{ .column = .{} });
    try wireChildren(&tree);

    // outer column hugs content (main size is indefinite bottom-up)
    // item has flex_basis = 50% and size.width = auto -> falls back to intrinsic content size (70)
    tree.node(item).?.style.flex_basis = .{ .percent = 0.5 };
    tree.node(item).?.style.size.width = .auto;
    tree.node(item).?.style.grow = 0;
    tree.node(item).?.style.shrink = 0;

    flex.layout(&tree, .{ .width = 400, .height = 400 });

    // Text "percent" is 7 chars = 70px natural main
    try testing.expectEqual(@as(f32, 70), tree.node(item).?.rect.w);
}

test "multi-line flex align-content: space-between" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const row: Id = @enumFromInt(1);
    const id1: Id = @enumFromInt(2);
    const id2: Id = @enumFromInt(3);
    const id3: Id = @enumFromInt(4);
    const id4: Id = @enumFromInt(5);

    try appendNode(&tree, id1, row, .{ .label = .{ .text = "line1a" } });
    try appendNode(&tree, id2, row, .{ .label = .{ .text = "line1b" } });
    try appendNode(&tree, id3, row, .{ .label = .{ .text = "line2a" } });
    try appendNode(&tree, id4, row, .{ .label = .{ .text = "line2b" } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    try wireChildren(&tree);

    tree.node(row).?.style.wrap = .wrap;
    tree.node(row).?.style.align_content = .space_between;
    tree.node(row).?.style.size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
    };

    // 4 items of width 60, height 20 each. 60+60 > 100, so line 1: id1, id2 wraps to line 2: id3, id4.
    for ([_]Id{ id1, id2, id3, id4 }) |id| {
        tree.node(id).?.style.size = .{
            .width = .{ .length = 60 },
            .height = .{ .length = 20 },
        };
        tree.node(id).?.style.grow = 0;
        tree.node(id).?.style.shrink = 0;
    }

    flex.layout(&tree, .{ .width = 200, .height = 200 });

    // Container content height = 100.
    // 4 lines of height 20 each: line 1 at y=0, line 2 at y=26.6667, line 3 at y=53.3333, line 4 at y=80.
    try testing.expectEqual(@as(f32, 0), tree.node(id1).?.rect.y);
    try testing.expectApproxEqAbs(@as(f32, 26.667), tree.node(id2).?.rect.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 53.333), tree.node(id3).?.rect.y, 0.01);
    try testing.expectEqual(@as(f32, 80), tree.node(id4).?.rect.y);
}

test "multi-line flex align-content: space-evenly" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const row: Id = @enumFromInt(1);
    const id1: Id = @enumFromInt(2);
    const id2: Id = @enumFromInt(3);

    try appendNode(&tree, id1, row, .{ .label = .{ .text = "line1" } });
    try appendNode(&tree, id2, row, .{ .label = .{ .text = "line2" } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    try wireChildren(&tree);

    tree.node(row).?.style.wrap = .wrap;
    tree.node(row).?.style.align_content = .space_evenly;
    tree.node(row).?.style.size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
    };

    // 2 items of width 60, height 20 each. 60+60 > 100, so line 1: id1 (y=20), line 2: id2 (y=60).
    // Total line cross = 40, free cross = 60, 3 slots of 20 each.
    for ([_]Id{ id1, id2 }) |id| {
        tree.node(id).?.style.size = .{
            .width = .{ .length = 60 },
            .height = .{ .length = 20 },
        };
        tree.node(id).?.style.grow = 0;
        tree.node(id).?.style.shrink = 0;
    }

    flex.layout(&tree, .{ .width = 200, .height = 200 });

    try testing.expectEqual(@as(f32, 20), tree.node(id1).?.rect.y);
    try testing.expectEqual(@as(f32, 60), tree.node(id2).?.rect.y);
}

test "flex wrap gap deduction breaks lines accurately" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const row: Id = @enumFromInt(1);
    const id1: Id = @enumFromInt(2);
    const id2: Id = @enumFromInt(3);

    try appendNode(&tree, id1, row, .{ .label = .{ .text = "a" } });
    try appendNode(&tree, id2, row, .{ .label = .{ .text = "b" } });
    try appendNode(&tree, row, .root, .{ .row = .{ .gap = 10 } });
    try wireChildren(&tree);

    tree.node(row).?.style.wrap = .wrap;
    tree.node(row).?.style.size.width = .{ .length = 100 };
    tree.node(row).?.style.@"align" = .start;

    // Item 1 width = 50, Item 2 width = 45.
    // 50 + 10 (gap) + 45 = 105 > 100 -> Item 2 MUST wrap to line 2!
    tree.node(id1).?.style.size = .{ .width = .{ .length = 50 }, .height = .{ .length = 20 } };
    tree.node(id1).?.style.grow = 0;
    tree.node(id1).?.style.shrink = 0;

    tree.node(id2).?.style.size = .{ .width = .{ .length = 45 }, .height = .{ .length = 20 } };
    tree.node(id2).?.style.grow = 0;
    tree.node(id2).?.style.shrink = 0;

    flex.layout(&tree, .{ .width = 100, .height = 200 });

    // Item 1 is at x=0, y=0.
    // Item 2 wraps to line 2 at x=0, y=20 + gap(10) = 30.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 50, .h = 20 }, tree.node(id1).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 30, .w = 45, .h = 20 }, tree.node(id2).?.rect);
}

test "cross-axis aspect-ratio transfers cross constraints into main size" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const row: Id = @enumFromInt(1);
    const item: Id = @enumFromInt(2);

    try appendNode(&tree, item, row, .{ .label = .{ .text = "aspect" } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    try wireChildren(&tree);

    // Row has definite height = 60, align = .stretch.
    // Item has aspect_ratio = 2.0, size.width = auto, size.height = auto.
    // Stretched cross height is 60 -> main width transfers to 60 * 2.0 = 120.
    tree.node(row).?.style.size = .{ .width = .{ .length = 300 }, .height = .{ .length = 60 } };
    tree.node(row).?.style.@"align" = .stretch;

    tree.node(item).?.style.size = .{ .width = .auto, .height = .auto };
    tree.node(item).?.style.aspect_ratio = 2.0;
    tree.node(item).?.style.grow = 0;
    tree.node(item).?.style.shrink = 0;

    flex.layout(&tree, .{ .width = 300, .height = 60 });

    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 120, .h = 60 }, tree.node(item).?.rect);
}

test "flex-grow with max-width clamping and iterative redistribution" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const row: Id = @enumFromInt(1);
    const id1: Id = @enumFromInt(2);
    const id2: Id = @enumFromInt(3);
    const id3: Id = @enumFromInt(4);

    try appendNode(&tree, id1, row, .{ .label = .{ .text = "a" } });
    try appendNode(&tree, id2, row, .{ .label = .{ .text = "b" } });
    try appendNode(&tree, id3, row, .{ .label = .{ .text = "c" } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    try wireChildren(&tree);

    tree.node(row).?.style.size = .{ .width = .{ .length = 500 }, .height = .{ .length = 50 } };
    for ([_]Id{ id1, id2, id3 }) |id| {
        tree.node(id).?.style.size = .{ .width = .{ .length = 100 }, .height = .{ .length = 50 } };
        tree.node(id).?.style.grow = 1;
        tree.node(id).?.style.shrink = 0;
    }
    tree.node(id1).?.style.max_size = .{ .width = .{ .length = 130 }, .height = .auto };

    flex.layout(&tree, .{ .width = 500, .height = 50 });

    // Free space = 500 - 300 = 200.
    // id1 clamps to 130 (takes 30px). Remaining free space = 170.
    // id2 and id3 take 85px each -> 185px each.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 130, .h = 50 }, tree.node(id1).?.rect);
    try testing.expectEqual(Rect{ .x = 130, .y = 0, .w = 185, .h = 50 }, tree.node(id2).?.rect);
    try testing.expectEqual(Rect{ .x = 315, .y = 0, .w = 185, .h = 50 }, tree.node(id3).?.rect);
}

test "flex-shrink with min-width clamping and iterative redistribution" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const row: Id = @enumFromInt(1);
    const id1: Id = @enumFromInt(2);
    const id2: Id = @enumFromInt(3);
    const id3: Id = @enumFromInt(4);

    try appendNode(&tree, id1, row, .{ .label = .{ .text = "a" } });
    try appendNode(&tree, id2, row, .{ .label = .{ .text = "b" } });
    try appendNode(&tree, id3, row, .{ .label = .{ .text = "c" } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    try wireChildren(&tree);

    tree.node(row).?.style.size = .{ .width = .{ .length = 200 }, .height = .{ .length = 50 } };
    for ([_]Id{ id1, id2, id3 }) |id| {
        tree.node(id).?.style.size = .{ .width = .{ .length = 100 }, .height = .{ .length = 50 } };
        tree.node(id).?.style.grow = 0;
        tree.node(id).?.style.shrink = 1;
    }
    tree.node(id1).?.style.min_size = .{ .width = .{ .length = 80 }, .height = .auto };

    flex.layout(&tree, .{ .width = 200, .height = 50 });

    // Overflow = 300 - 200 = 100.
    // id1 clamps to min 80 (shrinks by 20px). Remaining overflow = 80.
    // id2 and id3 shrink by 40px each -> 60px each.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 80, .h = 50 }, tree.node(id1).?.rect);
    try testing.expectEqual(Rect{ .x = 80, .y = 0, .w = 60, .h = 50 }, tree.node(id2).?.rect);
    try testing.expectEqual(Rect{ .x = 140, .y = 0, .w = 60, .h = 50 }, tree.node(id3).?.rect);
}

test "justify-content space-between accurately deducts margins and gaps" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const row: Id = @enumFromInt(1);
    const id1: Id = @enumFromInt(2);
    const id2: Id = @enumFromInt(3);

    try appendNode(&tree, id1, row, .{ .label = .{ .text = "a" } });
    try appendNode(&tree, id2, row, .{ .label = .{ .text = "b" } });
    try appendNode(&tree, row, .root, .{ .row = .{ .gap = 10 } });
    try wireChildren(&tree);

    tree.node(row).?.style.size = .{ .width = .{ .length = 400 }, .height = .{ .length = 50 } };
    tree.node(row).?.style.justify = .space_between;

    tree.node(id1).?.style.size = .{ .width = .{ .length = 100 }, .height = .{ .length = 50 } };
    tree.node(id1).?.style.margin = .{ .right = 20 };
    tree.node(id1).?.style.grow = 0;
    tree.node(id1).?.style.shrink = 0;

    tree.node(id2).?.style.size = .{ .width = .{ .length = 100 }, .height = .{ .length = 50 } };
    tree.node(id2).?.style.margin = .{ .left = 30 };
    tree.node(id2).?.style.grow = 0;
    tree.node(id2).?.style.shrink = 0;

    flex.layout(&tree, .{ .width = 400, .height = 50 });

    // Consumed width = 100 + 20 (m1.right) + 10 (gap) + 30 (m2.left) + 100 = 260.
    // Free space = 400 - 260 = 140.
    // Extra gap = 140.
    // id1 is at x = 0, w = 100.
    // id2 is at x = 100 + 20 + 10 + 140 + 30 = 300, w = 100.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 50 }, tree.node(id1).?.rect);
    try testing.expectEqual(Rect{ .x = 300, .y = 0, .w = 100, .h = 50 }, tree.node(id2).?.rect);
}

test "aspect-ratio propagates cross-axis min/max constraints to main axis" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const row: Id = @enumFromInt(1);
    const item: Id = @enumFromInt(2);

    try appendNode(&tree, item, row, .{ .label = .{ .text = "aspect" } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    try wireChildren(&tree);

    // Row has definite height = 60, align = .stretch.
    // Item has aspect_ratio = 2.0, max_height = 40.
    // Stretched cross height 60 is clamped by max_height 40.
    // Transferred main width = 40 * 2.0 = 80.
    tree.node(row).?.style.size = .{ .width = .{ .length = 300 }, .height = .{ .length = 60 } };
    tree.node(row).?.style.@"align" = .stretch;

    tree.node(item).?.style.size = .{ .width = .auto, .height = .auto };
    tree.node(item).?.style.max_size = .{ .width = .auto, .height = .{ .length = 40 } };
    tree.node(item).?.style.aspect_ratio = 2.0;
    tree.node(item).?.style.grow = 0;
    tree.node(item).?.style.shrink = 0;

    flex.layout(&tree, .{ .width = 300, .height = 60 });

    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 80, .h = 40 }, tree.node(item).?.rect);
}

test "automatic minimum size content floor prevents shrink past min-content" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const row: Id = @enumFromInt(1);
    const item: Id = @enumFromInt(2);

    // Leaf label: default baked approximation width is 60 (6 chars * 10px), height = 20
    try appendNode(&tree, item, row, .{ .label = .{ .text = "123456" } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    try wireChildren(&tree);

    tree.node(row).?.style.size = .{ .width = .{ .length = 40 }, .height = .{ .length = 50 } };
    tree.node(item).?.style.flex_basis = .{ .length = 100 };
    tree.node(item).?.style.shrink = 1;
    tree.node(item).?.style.grow = 0;

    flex.layout(&tree, .{ .width = 40, .height = 50 });

    // Automatic minimum size (CSS Flexbox §4.5) floors the shrink at natural content main (60),
    // preventing the item from collapsing down to the available width 40.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 60, .h = 50 }, tree.node(item).?.rect);
}

test "explicit min-width: 0 allows flex item to shrink past min-content" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const row: Id = @enumFromInt(1);
    const item: Id = @enumFromInt(2);

    try appendNode(&tree, item, row, .{ .label = .{ .text = "123456" } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    try wireChildren(&tree);

    tree.node(row).?.style.size = .{ .width = .{ .length = 40 }, .height = .{ .length = 50 } };
    tree.node(item).?.style.flex_basis = .{ .length = 100 };
    tree.node(item).?.style.min_size = .{ .width = .{ .length = 0 }, .height = .auto };
    tree.node(item).?.style.shrink = 1;
    tree.node(item).?.style.grow = 0;

    flex.layout(&tree, .{ .width = 40, .height = 50 });

    // Explicit min_width: 0 allows the item to shrink past its 60px content size down to 40.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 40, .h = 50 }, tree.node(item).?.rect);
}

test "overflow not visible allows flex item with auto min-width to shrink past min-content" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const row: Id = @enumFromInt(1);
    const item: Id = @enumFromInt(2);

    try appendNode(&tree, item, row, .{ .label = .{ .text = "123456" } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    try wireChildren(&tree);

    tree.node(row).?.style.size = .{ .width = .{ .length = 40 }, .height = .{ .length = 50 } };
    tree.node(item).?.style.flex_basis = .{ .length = 100 };
    tree.node(item).?.style.overflow = .{ .width = .hidden, .height = .visible };
    tree.node(item).?.style.shrink = 1;
    tree.node(item).?.style.grow = 0;

    flex.layout(&tree, .{ .width = 40, .height = 50 });

    // Overflow != visible disables the automatic content minimum, allowing shrink to 40.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 40, .h = 50 }, tree.node(item).?.rect);
}

test "percentage padding resolves against parent flex container content width" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const row: Id = @enumFromInt(1);
    const item: Id = @enumFromInt(2);

    try appendNode(&tree, item, row, .{ .spacer = .{ .size = 10 } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    try wireChildren(&tree);

    tree.node(row).?.style.size = .{ .width = .{ .length = 200 }, .height = .{ .length = 100 } };
    tree.node(row).?.style.@"align" = .start;
    tree.node(item).?.style.padding_inset = .{
        .left = .{ .percent = 0.10 }, // 20px
        .right = .{ .percent = 0.05 }, // 10px
        .top = .{ .percent = 0.05 }, // 10px
        .bottom = .{ .percent = 0.10 }, // 20px
    };
    tree.node(item).?.style.grow = 0;
    tree.node(item).?.style.shrink = 0;

    flex.layout(&tree, .{ .width = 200, .height = 100 });

    // Padding resolves against parent content width (200):
    // horizontal padding = 20 + 10 = 30, vertical padding = 10 + 20 = 30.
    // Spacer size 10 + horizontal padding 30 = 40 width, spacer 10 + vertical padding 30 = 40 height.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 40, .h = 40 }, tree.node(item).?.rect);
}

test "percentage padding in column container resolves against content inline width" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const col: Id = @enumFromInt(1);
    const item: Id = @enumFromInt(2);

    try appendNode(&tree, item, col, .{ .spacer = .{ .size = 10 } });
    try appendNode(&tree, col, .root, .{ .column = .{} });
    try wireChildren(&tree);

    // Column container width 300, height 100.
    tree.node(col).?.style.size = .{ .width = .{ .length = 300 }, .height = .{ .length = 100 } };
    tree.node(col).?.style.@"align" = .start;
    tree.node(item).?.style.padding_inset = .{
        .top = .{ .percent = 0.10 }, // 30px (10% of 300 width, not 100 height)
        .right = .{ .percent = 0.05 }, // 15px
        .bottom = .{ .percent = 0.05 }, // 15px
        .left = .{ .percent = 0.10 }, // 30px
    };
    tree.node(item).?.style.grow = 0;
    tree.node(item).?.style.shrink = 0;

    flex.layout(&tree, .{ .width = 300, .height = 100 });

    // Horizontal padding = 30 + 15 = 45, vertical padding = 30 + 15 = 45.
    // Width = 10 + 45 = 55, Height = 10 + 45 = 55.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 55, .h = 55 }, tree.node(item).?.rect);
}

test "percentage margin in column container resolves against content inline width" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const col: Id = @enumFromInt(1);
    const item: Id = @enumFromInt(2);

    try appendNode(&tree, item, col, .{ .spacer = .{ .size = 20 } });
    try appendNode(&tree, col, .root, .{ .column = .{} });
    try wireChildren(&tree);

    // Column container width 200, height 100.
    tree.node(col).?.style.size = .{ .width = .{ .length = 200 }, .height = .{ .length = 100 } };
    tree.node(col).?.style.@"align" = .start;
    tree.node(item).?.style.margin_inset = .{
        .top = .{ .percent = 0.10 }, // 20px (10% of 200 width)
        .left = .{ .percent = 0.05 }, // 10px (5% of 200 width)
        .bottom = .auto,
        .right = .auto,
    };
    tree.node(item).?.style.grow = 0;
    tree.node(item).?.style.shrink = 0;

    flex.layout(&tree, .{ .width = 200, .height = 100 });

    try testing.expectEqual(Rect{ .x = 10, .y = 20, .w = 20, .h = 20 }, tree.node(item).?.rect);
}

test "absolute positioned child in flex container placed relative to content box with insets and alignment" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.deinit();

    const row: Id = @enumFromInt(1);
    const normal: Id = @enumFromInt(2);
    const abs_with_insets: Id = @enumFromInt(3);
    const abs_aligned: Id = @enumFromInt(4);

    try appendNode(&tree, normal, row, .{ .spacer = .{ .size = 50 } });
    try appendNode(&tree, abs_with_insets, row, .{ .spacer = .{ .size = 40 } });
    try appendNode(&tree, abs_aligned, row, .{ .spacer = .{ .size = 30 } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    try wireChildren(&tree);

    // Row container: border 2 on all sides, padding 8 on all sides.
    // Border-box: 200 x 100.
    // Content-box: (200 - 4 - 16) x (100 - 4 - 16) = 180 x 80.
    tree.node(row).?.style.size = .{ .width = .{ .length = 200 }, .height = .{ .length = 100 } };
    tree.node(row).?.style.border = .{ .top = 2, .right = 2, .bottom = 2, .left = 2 };
    tree.node(row).?.style.padding = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 };
    tree.node(row).?.style.justify = .start;
    tree.node(row).?.style.@"align" = .start;

    // Normal in-flow child:
    tree.node(normal).?.style.size = .{ .width = .{ .length = 50 }, .height = .{ .length = 50 } };
    tree.node(normal).?.style.grow = 0;
    tree.node(normal).?.style.shrink = 0;

    // Absolute child with explicit insets:
    tree.node(abs_with_insets).?.style.position = .absolute;
    tree.node(abs_with_insets).?.style.size = .{ .width = .{ .length = 40 }, .height = .{ .length = 30 } };
    tree.node(abs_with_insets).?.style.inset = .{
        .left = .{ .length = 15 },
        .top = .{ .length = 10 },
        .right = .auto,
        .bottom = .auto,
    };

    // Absolute child with auto insets and self-alignment (align_self = .center, parent justify = .center):
    tree.node(abs_aligned).?.style.position = .absolute;
    tree.node(abs_aligned).?.style.size = .{ .width = .{ .length = 60 }, .height = .{ .length = 20 } };
    tree.node(abs_aligned).?.style.align_self = .center;

    flex.layout(&tree, .{ .width = 200, .height = 100 });

    // Normal item placed at (0, 0) inside content box:
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 50, .h = 50 }, tree.node(normal).?.rect);

    // Absolute item with insets placed at (15, 10) relative to content box:
    try testing.expectEqual(Rect{ .x = 15, .y = 10, .w = 40, .h = 30 }, tree.node(abs_with_insets).?.rect);

    // Absolute item with auto insets and align_self = .center
    // (cross axis Y = (80 - 20) / 2 = 30, main axis X = 0 for justify.start):
    try testing.expectEqual(Rect{ .x = 0, .y = 30, .w = 60, .h = 20 }, tree.node(abs_aligned).?.rect);
}
