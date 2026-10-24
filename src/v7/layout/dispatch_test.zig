const std = @import("std");
const FrameNodeId = @import("../id.zig").FrameNodeId;
const context = @import("context.zig");
const dispatch = @import("dispatch.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");

fn fixedSize(width: f32, height: f32) style.DimensionSize {
    return .{
        .width = .{ .length = width },
        .height = .{ .length = height },
    };
}

fn fixedStyle(display: style.Display, width: f32, height: f32) style.Style {
    return .{
        .display = display,
        .box_sizing = .border_box,
        .size = fixedSize(width, height),
    };
}

fn layout(tree: *widget.WidgetTree, available: widget.Size) !void {
    try dispatch.layoutTree(tree, .{
        .allocator = std.testing.allocator,
        .available = available,
        .measure = null,
    });
}

const ValidationNode = struct {
    id: FrameNodeId,
    parent: FrameNodeId,
    display: style.Display = .block,
};

const ValidationEdge = struct {
    parent: FrameNodeId,
    child: FrameNodeId,
};

const ValidationCase = struct {
    nodes: []const ValidationNode,
    edges: []const ValidationEdge = &.{},
};

fn expectInvalidTree(case: ValidationCase) !void {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    for (case.nodes) |node| {
        try tree.appendNode(.{
            .id = node.id,
            .kind = .{ .column = .{} },
            .parent = node.parent,
            .style = fixedStyle(node.display, 20, 20),
        });
    }
    for (case.edges) |edge| {
        try tree.appendChild(edge.parent, edge.child);
    }

    try std.testing.expectError(
        error.InvalidStyle,
        layout(&tree, .{ .width = 20, .height = 20 }),
    );
}

test "fixed block container dispatches a nested flex container" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const flex_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const root_id: FrameNodeId = @fromBackingInt(@intCast(4));
    try tree.appendNode(.{
        .id = first_id,
        .kind = .{ .spacer = .{} },
        .parent = flex_id,
        .style = fixedStyle(.block, 20, 10),
    });
    try tree.appendNode(.{
        .id = second_id,
        .kind = .{ .spacer = .{} },
        .parent = flex_id,
        .style = fixedStyle(.block, 20, 10),
    });
    var flex_style = fixedStyle(.flex, 60, 20);
    flex_style.direction = .row;
    flex_style.@"align" = .start;
    try tree.appendNode(.{
        .id = flex_id,
        .kind = .{ .row = .{} },
        .parent = root_id,
        .style = flex_style,
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = fixedStyle(.flow_root, 100, 50),
    });
    try tree.appendChild(flex_id, first_id);
    try tree.appendChild(flex_id, second_id);
    try tree.appendChild(root_id, flex_id);

    try layout(&tree, .{ .width = 100, .height = 50 });

    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 60, .h = 20 },
        tree.node(flex_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 20, .h = 10 },
        tree.node(first_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 20, .y = 0, .w = 20, .h = 10 },
        tree.node(second_id).?.rect,
    );
}

test "fixed flex container dispatches a nested grid container" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const grid_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const root_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const columns = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };
    const rows = [_]style.GridTrack{.{ .fixed = 10 }};
    try tree.appendNode(.{
        .id = first_id,
        .kind = .{ .spacer = .{} },
        .parent = grid_id,
        .style = fixedStyle(.block, 20, 10),
    });
    try tree.appendNode(.{
        .id = second_id,
        .kind = .{ .spacer = .{} },
        .parent = grid_id,
        .style = fixedStyle(.block, 20, 10),
    });
    var grid_style = fixedStyle(.grid, 40, 20);
    grid_style.grid_template_columns = columns[0..];
    grid_style.grid_template_rows = rows[0..];
    grid_style.grid_justify_items = .start;
    grid_style.grid_align_items = .start;
    try tree.appendNode(.{
        .id = grid_id,
        .kind = .{ .column = .{} },
        .parent = root_id,
        .style = grid_style,
    });
    var root_style = fixedStyle(.flex, 100, 30);
    root_style.direction = .row;
    root_style.@"align" = .start;
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .row = .{} },
        .parent = .root,
        .style = root_style,
    });
    try tree.appendChild(grid_id, first_id);
    try tree.appendChild(grid_id, second_id);
    try tree.appendChild(root_id, grid_id);

    try layout(&tree, .{ .width = 100, .height = 30 });

    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 40, .h = 20 },
        tree.node(grid_id).?.rect,
    );
    try std.testing.expectEqual(@as(f32, 0), tree.node(first_id).?.rect.x);
    try std.testing.expectEqual(@as(f32, 20), tree.node(second_id).?.rect.x);
}

test "fixed grid container dispatches a nested block container" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const block_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const root_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{.{ .fixed = 40 }};
    const rows = [_]style.GridTrack{.{ .fixed = 30 }};
    try tree.appendNode(.{
        .id = leaf_id,
        .kind = .{ .spacer = .{} },
        .parent = block_id,
        .style = fixedStyle(.block, 10, 5),
    });
    try tree.appendNode(.{
        .id = block_id,
        .kind = .{ .column = .{} },
        .parent = root_id,
        .style = fixedStyle(.flow_root, 30, 20),
    });
    var root_style = fixedStyle(.grid, 40, 30);
    root_style.grid_template_columns = columns[0..];
    root_style.grid_template_rows = rows[0..];
    root_style.grid_justify_items = .start;
    root_style.grid_align_items = .start;
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = root_style,
    });
    try tree.appendChild(block_id, leaf_id);
    try tree.appendChild(root_id, block_id);

    try layout(&tree, .{ .width = 40, .height = 30 });

    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 30, .h = 20 },
        tree.node(block_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 10, .h = 5 },
        tree.node(leaf_id).?.rect,
    );
}

test "mixed border boxes stay parent-content-relative" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const flex_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const root_id: FrameNodeId = @fromBackingInt(@intCast(3));
    try tree.appendNode(.{
        .id = leaf_id,
        .kind = .{ .spacer = .{} },
        .parent = flex_id,
        .style = fixedStyle(.block, 10, 5),
    });
    var flex_style = fixedStyle(.flex, 30, 20);
    flex_style.direction = .row;
    flex_style.@"align" = .start;
    flex_style.border_inset = .{
        .top = .{ .length = 1 },
        .right = .{ .length = 1 },
        .bottom = .{ .length = 1 },
        .left = .{ .length = 1 },
    };
    flex_style.padding_inset = .{
        .top = .{ .length = 2 },
        .right = .{ .length = 2 },
        .bottom = .{ .length = 2 },
        .left = .{ .length = 2 },
    };
    try tree.appendNode(.{
        .id = flex_id,
        .kind = .{ .row = .{} },
        .parent = root_id,
        .style = flex_style,
    });
    var root_style = fixedStyle(.flow_root, 60, 40);
    root_style.border_inset = .{
        .top = .{ .length = 2 },
        .right = .{ .length = 2 },
        .bottom = .{ .length = 2 },
        .left = .{ .length = 2 },
    };
    root_style.padding_inset = .{
        .top = .{ .length = 3 },
        .right = .{ .length = 3 },
        .bottom = .{ .length = 3 },
        .left = .{ .length = 3 },
    };
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = root_style,
    });
    try tree.appendChild(flex_id, leaf_id);
    try tree.appendChild(root_id, flex_id);

    try layout(&tree, .{ .width = 60, .height = 40 });

    try std.testing.expectEqual(@as(f32, 0), tree.node(flex_id).?.rect.x);
    try std.testing.expectEqual(@as(f32, 0), tree.node(flex_id).?.rect.y);
    try std.testing.expectEqual(@as(f32, 0), tree.node(leaf_id).?.rect.x);
    try std.testing.expectEqual(@as(f32, 0), tree.node(leaf_id).?.rect.y);
    try std.testing.expectEqual(
        widget.Rect{ .x = 8, .y = 8, .w = 10, .h = 5 },
        widget.absoluteRect(&tree, leaf_id),
    );
}

test "hidden mixed subtree is cleared once for every descendant" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const grid_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const hidden_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const root_id: FrameNodeId = @fromBackingInt(@intCast(4));
    try tree.appendNode(.{
        .id = leaf_id,
        .kind = .{ .spacer = .{} },
        .parent = grid_id,
        .style = fixedStyle(.block, 10, 10),
        .rect = .{ .x = 1, .y = 2, .w = 3, .h = 4 },
    });
    try tree.appendNode(.{
        .id = grid_id,
        .kind = .{ .column = .{} },
        .parent = hidden_id,
        .style = .{ .display = .grid },
        .rect = .{ .x = 2, .y = 3, .w = 4, .h = 5 },
    });
    try tree.appendNode(.{
        .id = hidden_id,
        .kind = .{ .column = .{} },
        .parent = root_id,
        .style = .{ .display = .none },
        .rect = .{ .x = 3, .y = 4, .w = 5, .h = 6 },
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .row = .{} },
        .parent = .root,
        .style = fixedStyle(.flex, 100, 20),
    });
    try tree.appendChild(grid_id, leaf_id);
    try tree.appendChild(hidden_id, grid_id);
    try tree.appendChild(root_id, hidden_id);

    try layout(&tree, .{ .width = 100, .height = 20 });

    try std.testing.expectEqual(widget.Rect{}, tree.node(hidden_id).?.rect);
    try std.testing.expectEqual(widget.Rect{}, tree.node(grid_id).?.rect);
    try std.testing.expectEqual(widget.Rect{}, tree.node(leaf_id).?.rect);
    try std.testing.expect(tree.node(hidden_id).?.layout_hidden);
    try std.testing.expect(tree.node(grid_id).?.layout_hidden);
    try std.testing.expect(tree.node(leaf_id).?.layout_hidden);
}

test "dispatcher rejects non-finite availability and malformed trees" {
    var empty = widget.WidgetTree.init(std.testing.allocator);
    defer empty.deinit();
    try std.testing.expectError(
        error.InvalidStyle,
        dispatch.layoutTree(&empty, .{
            .allocator = std.testing.allocator,
            .available = .{ .width = std.math.inf(f32), .height = 20 },
            .measure = null,
        }),
    );

    var malformed = widget.WidgetTree.init(std.testing.allocator);
    defer malformed.deinit();
    const missing_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const root_id: FrameNodeId = @fromBackingInt(@intCast(2));
    try malformed.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = fixedStyle(.block, 20, 20),
    });
    try malformed.appendChild(root_id, missing_id);
    try std.testing.expectError(
        error.InvalidStyle,
        dispatch.layoutTree(&malformed, .{
            .allocator = std.testing.allocator,
            .available = .{ .width = 20, .height = 20 },
            .measure = null,
        }),
    );
    var orphaned = widget.WidgetTree.init(std.testing.allocator);
    defer orphaned.deinit();
    const orphan_id: FrameNodeId = @fromBackingInt(@intCast(3));
    try orphaned.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = fixedStyle(.block, 20, 20),
    });
    try orphaned.appendNode(.{
        .id = orphan_id,
        .kind = .{ .spacer = .{} },
        .parent = missing_id,
        .style = fixedStyle(.block, 10, 10),
    });
    try std.testing.expectError(
        error.InvalidStyle,
        dispatch.layoutTree(&orphaned, .{
            .allocator = std.testing.allocator,
            .available = .{ .width = 20, .height = 20 },
            .measure = null,
        }),
    );
}

test "dispatcher rejects duplicate node identifiers and reserved root identifiers" {
    const duplicate_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const first_parent_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const second_parent_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const root_id: FrameNodeId = @fromBackingInt(@intCast(4));

    const cases = [_]ValidationCase{
        .{
            .nodes = &.{
                .{ .id = duplicate_id, .parent = .root },
                .{ .id = duplicate_id, .parent = .root },
            },
        },
        .{
            .nodes = &.{
                .{ .id = duplicate_id, .parent = first_parent_id, .display = .none },
                .{ .id = duplicate_id, .parent = second_parent_id, .display = .none },
                .{ .id = first_parent_id, .parent = root_id, .display = .none },
                .{ .id = second_parent_id, .parent = root_id, .display = .none },
                .{ .id = root_id, .parent = .root },
            },
            .edges = &.{
                .{ .parent = first_parent_id, .child = duplicate_id },
                .{ .parent = second_parent_id, .child = duplicate_id },
                .{ .parent = root_id, .child = first_parent_id },
                .{ .parent = root_id, .child = second_parent_id },
            },
        },
        .{
            .nodes = &.{
                .{ .id = .root, .parent = .root },
            },
        },
        .{
            .nodes = &.{
                .{ .id = root_id, .parent = .root },
            },
            .edges = &.{
                .{ .parent = root_id, .child = .root },
            },
        },
    };

    for (cases) |case| try expectInvalidTree(case);
}

test "dispatcher rejects duplicate shared mismatched and unlisted children" {
    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const first_parent_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const second_parent_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const root_id: FrameNodeId = @fromBackingInt(@intCast(4));

    const cases = [_]ValidationCase{
        .{
            .nodes = &.{
                .{ .id = child_id, .parent = root_id },
                .{ .id = root_id, .parent = .root },
            },
            .edges = &.{
                .{ .parent = root_id, .child = child_id },
                .{ .parent = root_id, .child = child_id },
            },
        },
        .{
            .nodes = &.{
                .{ .id = child_id, .parent = first_parent_id },
                .{ .id = first_parent_id, .parent = root_id },
                .{ .id = second_parent_id, .parent = root_id },
                .{ .id = root_id, .parent = .root },
            },
            .edges = &.{
                .{ .parent = first_parent_id, .child = child_id },
                .{ .parent = second_parent_id, .child = child_id },
                .{ .parent = root_id, .child = first_parent_id },
                .{ .parent = root_id, .child = second_parent_id },
            },
        },
        .{
            .nodes = &.{
                .{ .id = child_id, .parent = second_parent_id },
                .{ .id = first_parent_id, .parent = root_id },
                .{ .id = second_parent_id, .parent = root_id },
                .{ .id = root_id, .parent = .root },
            },
            .edges = &.{
                .{ .parent = first_parent_id, .child = child_id },
                .{ .parent = root_id, .child = first_parent_id },
                .{ .parent = root_id, .child = second_parent_id },
            },
        },
        .{
            .nodes = &.{
                .{ .id = child_id, .parent = root_id },
                .{ .id = root_id, .parent = .root },
            },
        },
    };

    for (cases) |case| try expectInvalidTree(case);
}

test "dispatcher rejects self forward cyclic and rootless graphs" {
    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const first_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const root_id: FrameNodeId = @fromBackingInt(@intCast(4));

    const cases = [_]ValidationCase{
        .{
            .nodes = &.{
                .{ .id = child_id, .parent = root_id },
                .{ .id = root_id, .parent = .root },
            },
            .edges = &.{
                .{ .parent = root_id, .child = child_id },
                .{ .parent = child_id, .child = child_id },
            },
        },
        .{
            .nodes = &.{
                .{ .id = root_id, .parent = .root },
                .{ .id = child_id, .parent = root_id },
            },
            .edges = &.{
                .{ .parent = root_id, .child = child_id },
            },
        },
        .{
            .nodes = &.{
                .{ .id = child_id, .parent = root_id },
                .{ .id = root_id, .parent = .root },
            },
            .edges = &.{
                .{ .parent = child_id, .child = root_id },
                .{ .parent = root_id, .child = child_id },
            },
        },
        .{
            .nodes = &.{
                .{ .id = first_id, .parent = second_id },
                .{ .id = second_id, .parent = first_id },
            },
            .edges = &.{
                .{ .parent = first_id, .child = second_id },
                .{ .parent = second_id, .child = first_id },
            },
        },
    };

    for (cases) |case| try expectInvalidTree(case);
}

test "a failed layoutTree leaves the shared layout storage empty" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    var storage: context.LayoutStorage = .init(std.testing.allocator);
    defer storage.deinit();

    // A healthy first root: its flex container and label stage entries in
    // the shared measurement and text caches while they lay out.
    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const flex_id: FrameNodeId = @fromBackingInt(@intCast(2));
    try tree.appendNode(.{
        .id = first_id,
        .kind = .{ .label = .{ .text = "abc" } },
        .parent = flex_id,
        .style = .{
            .display = .block,
            .size = .{ .width = .auto, .height = .auto },
        },
    });
    var flex_style = fixedStyle(.flex, 60, 20);
    flex_style.direction = .row;
    flex_style.@"align" = .start;
    try tree.appendNode(.{
        .id = flex_id,
        .kind = .{ .row = .{} },
        .parent = .root,
        .style = flex_style,
    });
    // A second root with a negative preferred width: the first root lays out
    // and stages cache entries, then this root fails measurement, so the
    // frame exercises the error unwind with entries staged.
    const bad_id: FrameNodeId = @fromBackingInt(@intCast(3));
    try tree.appendNode(.{
        .id = bad_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .length = -10 }, .height = .{ .length = 20 } },
        },
    });
    try tree.appendChild(flex_id, first_id);

    try std.testing.expectError(
        error.InvalidStyle,
        dispatch.layoutTree(&tree, .{
            .allocator = std.testing.allocator,
            .available = .{ .width = 200, .height = 100 },
            .measure = null,
            .storage = &storage,
        }),
    );
    // The entry clear runs before any root lays out and the exit clear runs
    // on the error path, so no staged measurement survives the failed frame.
    try std.testing.expectEqual(@as(usize, 0), storage.flex_measure_cache.map.count());
}
