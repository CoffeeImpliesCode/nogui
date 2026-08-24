//! Direct dispatcher coverage for multiple root pseudo-items.
//!
//! Each tree is assembled in post-order and sent through `dispatch.layoutTree`.
//! The assertions inspect relative border boxes and absolute geometry so root
//! flow remains separate from the selected mixed layout engine.

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

fn expectRect(tree: *const WidgetTree, id: Id, expected: Rect) !void {
    const actual = tree.nodeConst(id).?.rect;
    const tolerance: f32 = 0.001;
    try std.testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
    try std.testing.expectApproxEqAbs(expected.w, actual.w, tolerance);
    try std.testing.expectApproxEqAbs(expected.h, actual.h, tolerance);
}

test "forest roots preserve source order and margin cursor overlap" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);

    var first_style = fixedStyle(.flex, 30, 20);
    first_style.margin = .{ .top = 4, .bottom = -24, .left = 5 };
    try appendNode(&tree, first_id, .root, first_style, .{ .column = .{} });

    var second_style = fixedStyle(.flex, 40, 10);
    second_style.margin.left = 7;
    try appendNode(&tree, second_id, .root, second_style, .{ .column = .{} });

    try layout(&tree, .{ .width = 100, .height = 80 });

    try expectRect(&tree, first_id, .{ .x = 5, .y = 4, .w = 95, .h = 20 });
    try expectRect(&tree, second_id, .{ .x = 7, .y = 0, .w = 93, .h = 10 });
}

test "forest auto root stretches width and keeps natural height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: Id = @enumFromInt(1);
    const block_id: Id = @enumFromInt(2);
    const auto_root_id: Id = @enumFromInt(3);
    const next_root_id: Id = @enumFromInt(4);

    try appendNode(
        &tree,
        leaf_id,
        block_id,
        fixedStyle(.block, 12, 12),
        .{ .spacer = .{ .size = 12 } },
    );
    try appendNode(
        &tree,
        block_id,
        auto_root_id,
        autoStyle(.block),
        .{ .column = .{} },
    );

    var auto_root_style = autoStyle(.flex);
    auto_root_style.margin = .{ .top = 2, .right = 6, .bottom = 3, .left = 4 };
    try appendNode(
        &tree,
        auto_root_id,
        .root,
        auto_root_style,
        .{ .column = .{} },
    );

    try appendNode(
        &tree,
        next_root_id,
        .root,
        fixedStyle(.flex, 20, 5),
        .{ .column = .{} },
    );
    try tree.appendChild(block_id, leaf_id);
    try tree.appendChild(auto_root_id, block_id);
    try std.testing.expect(dispatch.eligibleMixedForest(&tree));

    try layout(&tree, .{ .width = 100, .height = 80 });

    try expectRect(&tree, auto_root_id, .{ .x = 4, .y = 2, .w = 90, .h = 12 });
    try expectRect(&tree, block_id, .{ .x = 0, .y = 0, .w = 90, .h = 12 });
    try expectRect(&tree, leaf_id, .{ .x = 0, .y = 0, .w = 12, .h = 12 });
    try expectRect(&tree, next_root_id, .{ .x = 0, .y = 17, .w = 100, .h = 5 });
}

test "forest auto root remeasures wrapped flex at margin-resolved width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_leaf_id: Id = @enumFromInt(1);
    const second_leaf_id: Id = @enumFromInt(2);
    const flex_id: Id = @enumFromInt(3);
    const root_id: Id = @enumFromInt(4);

    try appendNode(
        &tree,
        first_leaf_id,
        flex_id,
        fixedStyle(.block, 50, 10),
        .{ .spacer = .{} },
    );
    try appendNode(
        &tree,
        second_leaf_id,
        flex_id,
        fixedStyle(.block, 50, 10),
        .{ .spacer = .{} },
    );

    var flex_style = autoStyle(.flex);
    flex_style.direction = .row;
    flex_style.wrap = .wrap;
    flex_style.flex_wrap = .wrap;
    flex_style.@"align" = .start;
    try appendNode(&tree, flex_id, root_id, flex_style, .{ .row = .{} });

    var root_style = autoStyle(.flow_root);
    root_style.margin = .{ .right = 10, .left = 10 };
    try appendNode(&tree, root_id, .root, root_style, .{ .column = .{} });

    try tree.appendChild(flex_id, first_leaf_id);
    try tree.appendChild(flex_id, second_leaf_id);
    try tree.appendChild(root_id, flex_id);

    try layout(&tree, .{ .width = 100, .height = 80 });

    try expectRect(&tree, root_id, .{ .x = 10, .y = 0, .w = 80, .h = 20 });
    try expectRect(&tree, flex_id, .{ .x = 0, .y = 0, .w = 80, .h = 20 });
    try expectRect(&tree, first_leaf_id, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
    try expectRect(&tree, second_leaf_id, .{ .x = 0, .y = 10, .w = 50, .h = 10 });
}

test "forest root flex basis and grow distribute positive free space" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);

    var first_style = fixedStyle(.flex, 10, 0);
    first_style.size.height = .auto;
    first_style.basis = 20;
    first_style.grow = 1;
    try appendNode(&tree, first_id, .root, first_style, .{ .column = .{} });

    var second_style = fixedStyle(.flex, 10, 0);
    second_style.size.height = .auto;
    second_style.basis = 10;
    second_style.grow = 2;
    try appendNode(&tree, second_id, .root, second_style, .{ .column = .{} });

    try layout(&tree, .{ .width = 100, .height = 90 });

    try expectRect(&tree, first_id, .{ .x = 0, .y = 0, .w = 100, .h = 40 });
    try expectRect(&tree, second_id, .{ .x = 0, .y = 40, .w = 100, .h = 50 });
}

test "forest root shrink freezes at minimum main floor" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);

    var first_style = fixedStyle(.flex, 10, 0);
    first_style.size.height = .auto;
    first_style.basis = 40;
    first_style.shrink = 1;
    first_style.min_main = 30;
    try appendNode(&tree, first_id, .root, first_style, .{ .column = .{} });

    var second_style = fixedStyle(.flex, 10, 0);
    second_style.size.height = .auto;
    second_style.basis = 30;
    second_style.shrink = 1;
    try appendNode(&tree, second_id, .root, second_style, .{ .column = .{} });

    try layout(&tree, .{ .width = 100, .height = 50 });

    try expectRect(&tree, first_id, .{ .x = 0, .y = 0, .w = 100, .h = 30 });
    try expectRect(&tree, second_id, .{ .x = 0, .y = 30, .w = 100, .h = 20 });
}

test "forest absolute and hidden roots do not consume flow" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_left_id: Id = @enumFromInt(1);
    const absolute_right_id: Id = @enumFromInt(2);
    const hidden_id: Id = @enumFromInt(3);
    const flow_id: Id = @enumFromInt(4);

    var absolute_left_style = fixedStyle(.flex, 20, 10);
    absolute_left_style.position = .absolute;
    absolute_left_style.margin = .{ .top = 2, .left = 3 };
    absolute_left_style.inset = .{
        .top = .{ .length = 9 },
        .right = .auto,
        .bottom = .auto,
        .left = .{ .length = 7 },
    };
    try appendNode(
        &tree,
        absolute_left_id,
        .root,
        absolute_left_style,
        .{ .column = .{} },
    );

    var absolute_right_style = fixedStyle(.flex, 10, 8);
    absolute_right_style.position = .absolute;
    absolute_right_style.margin = .{ .right = 2, .bottom = 1 };
    absolute_right_style.inset = .{
        .top = .auto,
        .right = .{ .length = 4 },
        .bottom = .{ .length = 5 },
        .left = .auto,
    };
    try appendNode(
        &tree,
        absolute_right_id,
        .root,
        absolute_right_style,
        .{ .column = .{} },
    );

    const hidden_style = fixedStyle(.none, 30, 20);
    try appendNode(&tree, hidden_id, .root, hidden_style, .{ .column = .{} });
    tree.node(hidden_id).?.rect = .{ .x = 1, .y = 2, .w = 3, .h = 4 };

    try appendNode(
        &tree,
        flow_id,
        .root,
        fixedStyle(.flex, 30, 20),
        .{ .column = .{} },
    );

    try layout(&tree, .{ .width = 100, .height = 80 });

    try expectRect(&tree, absolute_left_id, .{ .x = 10, .y = 11, .w = 20, .h = 10 });
    try expectRect(&tree, absolute_right_id, .{ .x = 84, .y = 66, .w = 10, .h = 8 });
    try expectRect(&tree, hidden_id, .{});
    try expectRect(&tree, flow_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try std.testing.expect(tree.node(hidden_id).?.layout_hidden);
    try std.testing.expectEqual(
        widget.absoluteRect(&tree, absolute_left_id),
        tree.node(absolute_left_id).?.rect,
    );
}

test "forest absolute auto root keeps its natural width without paired insets" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);
    try appendNode(
        &tree,
        leaf_id,
        root_id,
        fixedStyle(.block, 20, 10),
        .{ .spacer = .{} },
    );
    var root_style = autoStyle(.flex);
    root_style.position = .absolute;
    root_style.direction = .row;
    root_style.@"align" = .start;
    root_style.inset = .{
        .top = .{ .length = 4 },
        .right = .auto,
        .bottom = .auto,
        .left = .auto,
    };
    try appendNode(&tree, root_id, .root, root_style, .{ .row = .{} });
    try tree.appendChild(root_id, leaf_id);

    try layout(&tree, .{ .width = 100, .height = 80 });

    try expectRect(&tree, root_id, .{ .x = 0, .y = 4, .w = 20, .h = 10 });
}

test "forest absolute auto-width column flex shrinks to widest intrinsic child" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const nested_leaf_id: Id = @enumFromInt(3);
    const third_id: Id = @enumFromInt(4);
    const absolute_id: Id = @enumFromInt(5);
    const root_id: Id = @enumFromInt(6);

    try appendNode(
        &tree,
        first_id,
        absolute_id,
        fixedStyle(.block, 200, 10),
        .{ .spacer = .{} },
    );

    var second_style = autoStyle(.block);
    second_style.size.width = .{ .percent = 1 };
    second_style.size.height = .{ .length = 10 };
    try appendNode(
        &tree,
        second_id,
        absolute_id,
        second_style,
        .{ .spacer = .{} },
    );

    try appendNode(
        &tree,
        nested_leaf_id,
        third_id,
        fixedStyle(.block, 10, 10),
        .{ .spacer = .{} },
    );

    var third_style = autoStyle(.flex);
    third_style.size.width = .{ .percent = 1 };
    third_style.size.height = .{ .length = 10 };
    try appendNode(
        &tree,
        third_id,
        absolute_id,
        third_style,
        .{ .column = .{} },
    );

    var absolute_style = autoStyle(.flex);
    absolute_style.position = .absolute;
    absolute_style.direction = .column;
    absolute_style.inset = .{
        .top = .{ .length = 40 },
        .right = .auto,
        .bottom = .auto,
        .left = .{ .length = 50 },
    };
    try appendNode(
        &tree,
        absolute_id,
        root_id,
        absolute_style,
        .{ .column = .{} },
    );

    try appendNode(
        &tree,
        root_id,
        .root,
        fixedStyle(.block, 300, 110),
        .{ .column = .{} },
    );

    try tree.appendChild(third_id, nested_leaf_id);
    try tree.appendChild(absolute_id, first_id);
    try tree.appendChild(absolute_id, second_id);
    try tree.appendChild(absolute_id, third_id);
    try tree.appendChild(root_id, absolute_id);

    try layout(&tree, .{ .width = 300, .height = 110 });

    try expectRect(&tree, root_id, .{ .x = 0, .y = 0, .w = 300, .h = 110 });
    try expectRect(&tree, absolute_id, .{ .x = 50, .y = 40, .w = 200, .h = 30 });
    try expectRect(&tree, first_id, .{ .x = 0, .y = 0, .w = 200, .h = 10 });
    try expectRect(&tree, second_id, .{ .x = 0, .y = 10, .w = 200, .h = 10 });
    try expectRect(&tree, third_id, .{ .x = 0, .y = 20, .w = 200, .h = 10 });
    try expectRect(&tree, nested_leaf_id, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
}

test "forest absolute paired insets clamp auto and concrete widths" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const auto_id: Id = @enumFromInt(1);
    const concrete_id: Id = @enumFromInt(2);

    var auto_style = autoStyle(.flex);
    auto_style.position = .absolute;
    auto_style.size.height = .{ .length = 10 };
    auto_style.max_size.width = .{ .length = 50 };
    auto_style.inset = .{
        .top = .{ .length = 0 },
        .right = .{ .length = 10 },
        .bottom = .auto,
        .left = .{ .length = 10 },
    };
    try appendNode(&tree, auto_id, .root, auto_style, .{ .column = .{} });

    var concrete_style = fixedStyle(.flex, 60, 10);
    concrete_style.position = .absolute;
    concrete_style.min_size.width = .{ .length = 90 };
    concrete_style.inset = .{
        .top = .{ .length = 20 },
        .right = .{ .length = 10 },
        .bottom = .auto,
        .left = .{ .length = 10 },
    };
    try appendNode(&tree, concrete_id, .root, concrete_style, .{ .column = .{} });

    try layout(&tree, .{ .width = 100, .height = 80 });

    try expectRect(&tree, auto_id, .{ .x = 10, .y = 0, .w = 50, .h = 10 });
    try expectRect(&tree, concrete_id, .{ .x = 10, .y = 20, .w = 90, .h = 10 });
}

test "forest absolute paired auto width drives aspect-ratio height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: Id = @enumFromInt(1);
    var root_style = autoStyle(.flex);
    root_style.position = .absolute;
    root_style.aspect_ratio = 2;
    root_style.inset = .{
        .top = .{ .length = 0 },
        .right = .{ .length = 10 },
        .bottom = .auto,
        .left = .{ .length = 10 },
    };
    try appendNode(&tree, root_id, .root, root_style, .{ .column = .{} });

    try layout(&tree, .{ .width = 100, .height = 80 });

    try expectRect(&tree, root_id, .{ .x = 10, .y = 0, .w = 80, .h = 40 });
}

test "forest absolute inset and margin overflow returns InvalidStyle" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const extreme: f32 = 3.0e38;
    try std.testing.expect(std.math.isFinite(extreme));

    const root_id: Id = @enumFromInt(1);
    var root_style = fixedStyle(.flex, 10, 10);
    root_style.position = .absolute;
    root_style.margin.left = extreme;
    root_style.inset.left = .{ .length = extreme };
    try appendNode(&tree, root_id, .root, root_style, .{ .column = .{} });

    try std.testing.expectError(
        error.InvalidStyle,
        layout(&tree, .{ .width = 100, .height = 80 }),
    );
}

test "forest relative inset overflow returns InvalidStyle" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const extreme: f32 = 3.0e38;
    try std.testing.expect(std.math.isFinite(extreme));

    const root_id: Id = @enumFromInt(1);
    var root_style = fixedStyle(.flex, 10, 10);
    root_style.margin.left = extreme;
    root_style.margin.right = -extreme;
    root_style.inset.left = .{ .length = extreme };
    try appendNode(&tree, root_id, .root, root_style, .{ .column = .{} });

    try std.testing.expectError(
        error.InvalidStyle,
        layout(&tree, .{ .width = 100, .height = 80 }),
    );
}

test "forest max-clamped root remains shrinkable" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: Id = @enumFromInt(1);
    var root_style = fixedStyle(.flex, 10, 0);
    root_style.size.height = .auto;
    root_style.basis = 200;
    root_style.max_size.height = .{ .length = 150 };
    root_style.shrink = 1;
    try appendNode(&tree, root_id, .root, root_style, .{ .column = .{} });

    try layout(&tree, .{ .width = 100, .height = 100 });

    try expectRect(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
}

test "forest vertical percentage insets use surface height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: Id = @enumFromInt(1);
    var root_style = fixedStyle(.flex, 20, 10);
    root_style.inset = .{
        .top = .{ .percent = 0.5 },
        .right = .auto,
        .bottom = .auto,
        .left = .{ .percent = 0.1 },
    };
    try appendNode(&tree, root_id, .root, root_style, .{ .column = .{} });

    try layout(&tree, .{ .width = 100, .height = 40 });

    try expectRect(&tree, root_id, .{ .x = 10, .y = 20, .w = 100, .h = 10 });
}

test "forest absolute root ignores flex basis and minimum main" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);
    try appendNode(
        &tree,
        leaf_id,
        root_id,
        fixedStyle(.block, 20, 10),
        .{ .spacer = .{} },
    );
    var root_style = autoStyle(.flex);
    root_style.position = .absolute;
    root_style.direction = .row;
    root_style.@"align" = .start;
    root_style.basis = 50;
    root_style.min_main = 40;
    root_style.inset = .{
        .top = .{ .length = 0 },
        .right = .auto,
        .bottom = .auto,
        .left = .{ .length = 0 },
    };
    try appendNode(&tree, root_id, .root, root_style, .{ .row = .{} });
    try tree.appendChild(root_id, leaf_id);

    try layout(&tree, .{ .width = 100, .height = 80 });

    try expectRect(&tree, root_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
}

test "forest relative inset moves root after flow without moving cursor" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const relative_id: Id = @enumFromInt(1);
    const following_id: Id = @enumFromInt(2);

    var relative_style = fixedStyle(.flex, 20, 10);
    relative_style.inset = .{
        .top = .{ .length = 7 },
        .right = .auto,
        .bottom = .auto,
        .left = .{ .length = 4 },
    };
    try appendNode(&tree, relative_id, .root, relative_style, .{ .column = .{} });
    try appendNode(
        &tree,
        following_id,
        .root,
        fixedStyle(.flex, 20, 10),
        .{ .column = .{} },
    );

    try layout(&tree, .{ .width = 100, .height = 80 });

    try expectRect(&tree, relative_id, .{ .x = 4, .y = 7, .w = 100, .h = 10 });
    try expectRect(&tree, following_id, .{ .x = 0, .y = 10, .w = 100, .h = 10 });
    try std.testing.expectEqual(
        widget.absoluteRect(&tree, relative_id),
        tree.node(relative_id).?.rect,
    );
}

test "forest dispatch handles more than sixty-four roots" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_count: usize = 70;
    var root_index: usize = 0;
    while (root_index < root_count) : (root_index += 1) {
        const root_id: Id = @enumFromInt(@as(u32, @intCast(root_index + 1)));
        try appendNode(
            &tree,
            root_id,
            .root,
            fixedStyle(.flex, 5, 1),
            .{ .column = .{} },
        );
    }

    try layout(&tree, .{ .width = 100, .height = 100 });

    root_index = 0;
    while (root_index < root_count) : (root_index += 1) {
        const root_id: Id = @enumFromInt(@as(u32, @intCast(root_index + 1)));
        try expectRect(&tree, root_id, .{
            .x = 0,
            .y = @floatFromInt(root_index),
            .w = 100,
            .h = 1,
        });
    }
}

test "forest dispatcher rejects an orphan parent" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: Id = @enumFromInt(1);
    const missing_parent_id: Id = @enumFromInt(2);
    const orphan_id: Id = @enumFromInt(3);

    try appendNode(
        &tree,
        root_id,
        .root,
        fixedStyle(.flex, 20, 20),
        .{ .column = .{} },
    );
    try appendNode(
        &tree,
        orphan_id,
        missing_parent_id,
        fixedStyle(.block, 10, 10),
        .{ .spacer = .{} },
    );

    try std.testing.expectError(
        error.InvalidStyle,
        layout(&tree, .{ .width = 20, .height = 20 }),
    );
}
