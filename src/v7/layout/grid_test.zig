//! Specifies the direct-tree contract for the modular grid layout engine.

const std = @import("std");
const FrameNodeId = @import("../id.zig").FrameNodeId;
const style = @import("../style.zig");
const widget = @import("../widget.zig");
const grid = @import("grid.zig");
const layout_context = @import("context.zig");
const layout = @import("root.zig");

const Rect = widget.Rect;
const Style = style.Style;
const WidgetKind = widget.WidgetKind;
const WidgetTree = widget.WidgetTree;

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
    _: layout_context.LayoutRequest,
) layout_context.LayoutError!void {
    unreachable;
}

fn appendContainer(tree: *WidgetTree, id: FrameNodeId, parent: FrameNodeId, node_style: Style) !void {
    const kind: WidgetKind = switch (node_style.display) {
        .flex => .{ .row = .{} },
        .grid => .{ .column = .{} },
        .block, .flow_root => .{ .column = .{} },
        .none => .{ .spacer = .{} },
    };
    try tree.appendNode(.{
        .id = id,
        .kind = kind,
        .parent = parent,
        .style = node_style,
    });
}

fn appendLeaf(
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

fn leafStyle() Style {
    return .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    };
}

fn spacerStyle() Style {
    return leafStyle();
}

fn fixedContainer(
    width: f32,
    height: f32,
    columns: []const style.GridTrack,
    rows: []const style.GridTrack,
) Style {
    return .{
        .display = .grid,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = width },
            .height = .{ .length = height },
        },
        .grid_template_columns = columns,
        .grid_template_rows = rows,
    };
}

fn layoutContainer(
    tree: *WidgetTree,
    container_id: FrameNodeId,
    available: widget.Size,
    measure: ?grid.MeasureSource,
) !void {
    try grid.layoutContainer(tree, container_id, .{
        .allocator = std.testing.allocator,
        .available = available,
        .measure = measure,
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

fn measureLabel(
    _: ?*anyopaque,
    text: []const u8,
    _: layout_context.MeasureInput,
) layout_context.LayoutError!layout_context.TextMeasurement {
    if (std.mem.eql(u8, text, "intrinsic")) {
        return .{ .width = 30, .height = 12 };
    }
    return .{ .width = 8, .height = 8 };
}

test "grid fixed two by two tracks preserve gaps" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const third_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const fourth_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(5));
    const columns = [_]style.GridTrack{ .{ .fixed = 30 }, .{ .fixed = 40 } };
    const rows = [_]style.GridTrack{ .{ .fixed = 10 }, .{ .fixed = 20 } };

    try appendLeaf(&tree, first_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, second_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, third_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, fourth_id, container_id, leafStyle(), .{ .spacer = .{} });
    var container = fixedContainer(75, 33, columns[0..], rows[0..]);
    container.column_gap = .{ .length = 5 };
    container.row_gap = .{ .length = 3 };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);
    try tree.appendChild(container_id, third_id);
    try tree.appendChild(container_id, fourth_id);

    try layoutContainer(&tree, container_id, .{ .width = 75, .height = 33 }, null);

    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 30, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 35, .y = 0, .w = 40, .h = 10 });
    try expectRelative(&tree, third_id, .{ .x = 0, .y = 13, .w = 30, .h = 20 });
    try expectRelative(&tree, fourth_id, .{ .x = 35, .y = 13, .w = 40, .h = 20 });
}

test "grid explicit spans and negative lines select requested tracks" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const spanning_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const negative_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{
        .{ .fixed = 20 },
        .{ .fixed = 30 },
        .{ .fixed = 40 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 10 }};

    try appendLeaf(&tree, spanning_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, negative_id, container_id, leafStyle(), .{ .spacer = .{} });
    var spanning_style = leafStyle();
    spanning_style.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .span = 2 },
    };
    spanning_style.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    const spanning_node = tree.node(spanning_id) orelse return error.TestUnexpectedResult;
    spanning_node.style = spanning_style;

    var negative_style = leafStyle();
    negative_style.grid_column = .{
        .start = .{ .line = -2 },
        .end = .{ .line = -1 },
    };
    negative_style.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    const negative_node = tree.node(negative_id) orelse return error.TestUnexpectedResult;
    negative_node.style = negative_style;

    try appendContainer(&tree, container_id, .root, fixedContainer(90, 10, columns[0..], rows[0..]));
    try tree.appendChild(container_id, spanning_id);
    try tree.appendChild(container_id, negative_id);

    try layoutContainer(&tree, container_id, .{ .width = 90, .height = 10 }, null);

    try expectRelative(&tree, spanning_id, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
    try expectRelative(&tree, negative_id, .{ .x = 50, .y = 0, .w = 40, .h = 10 });
}

test "grid reserves later definite items before earlier auto placement" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const auto_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const definite_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };
    const rows = [_]style.GridTrack{.{ .fixed = 10 }};
    try appendLeaf(&tree, auto_id, container_id, leafStyle(), .{ .spacer = .{} });
    var definite = leafStyle();
    definite.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    definite.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, definite_id, container_id, definite, .{ .spacer = .{} });
    try appendContainer(&tree, container_id, .root, fixedContainer(40, 10, columns[0..], rows[0..]));
    try tree.appendChild(container_id, auto_id);
    try tree.appendChild(container_id, definite_id);

    try layoutContainer(&tree, container_id, .{ .width = 40, .height = 10 }, null);

    try expectRelative(&tree, definite_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
    try expectRelative(&tree, auto_id, .{ .x = 20, .y = 0, .w = 20, .h = 10 });
}

test "grid item auto margin consumes its cell free space" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fixed = 100 }};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};
    var child = leafStyle();
    child.size = .{
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
    };
    child.margin_inset = .{
        .top = .{ .length = 0 },
        .right = .{ .length = 0 },
        .bottom = .{ .length = 0 },
        .left = .auto,
    };
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{} });
    try appendContainer(&tree, container_id, .root, fixedContainer(100, 20, columns[0..], rows[0..]));
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 20 }, null);

    try expectRelative(&tree, child_id, .{ .x = 80, .y = 0, .w = 20, .h = 10 });
}

test "nested auto-sized grid includes track gaps in intrinsic size" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const nested_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const outer_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const nested_columns = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };
    const nested_rows = [_]style.GridTrack{.{ .fixed = 10 }};
    const outer_columns = [_]style.GridTrack{.auto};
    const outer_rows = [_]style.GridTrack{.{ .fixed = 20 }};
    try appendLeaf(&tree, first_id, nested_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, second_id, nested_id, leafStyle(), .{ .spacer = .{} });
    var nested = fixedContainer(0, 0, nested_columns[0..], nested_rows[0..]);
    nested.size = .{ .width = .auto, .height = .auto };
    nested.column_gap = .{ .length = 10 };
    nested.grid_align_self = .start;
    try appendContainer(&tree, nested_id, outer_id, nested);
    var outer = fixedContainer(100, 20, outer_columns[0..], outer_rows[0..]);
    outer.grid_justify_content = .start;
    try appendContainer(&tree, outer_id, .root, outer);
    try tree.appendChild(nested_id, first_id);
    try tree.appendChild(nested_id, second_id);
    try tree.appendChild(outer_id, nested_id);

    try layoutContainer(&tree, outer_id, .{ .width = 100, .height = 20 }, null);

    try expectRelative(&tree, nested_id, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 30, .y = 0, .w = 20, .h = 10 });
}

test "grid auto placement grows more than thirty two implicit tracks" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const container_id: FrameNodeId = @fromBackingInt(@intCast(100));
    const item_count: usize = 40;
    const columns = [_]style.GridTrack{.{ .fixed = 10 }};
    const rows = [_]style.GridTrack{.{ .fixed = 10 }};
    const auto_columns = [_]style.GridTrack{.{ .fixed = 10 }};

    for (0..item_count) |index| {
        const id: FrameNodeId = @fromBackingInt(@intCast(@as(u32, @intCast(index + 1))));
        try appendLeaf(&tree, id, container_id, spacerStyle(), .{ .spacer = .{ .size = 10 } });
    }
    var container = fixedContainer(400, 10, columns[0..], rows[0..]);
    container.grid_auto_columns = auto_columns[0..];
    container.grid_auto_flow = .column;
    try appendContainer(&tree, container_id, .root, container);
    for (0..item_count) |index| {
        const id: FrameNodeId = @fromBackingInt(@intCast(@as(u32, @intCast(index + 1))));
        try tree.appendChild(container_id, id);
    }

    try layoutContainer(&tree, container_id, .{ .width = 400, .height = 10 }, null);

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const thirty_third_id: FrameNodeId = @fromBackingInt(@intCast(33));
    const last_id: FrameNodeId = @fromBackingInt(@intCast(40));
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
    try expectRelative(&tree, thirty_third_id, .{ .x = 320, .y = 0, .w = 10, .h = 10 });
    try expectRelative(&tree, last_id, .{ .x = 390, .y = 0, .w = 10, .h = 10 });
}

test "grid mixed tracks resolve fixed percent auto minmax and fr" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const fixed_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const percent_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const intrinsic_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const minmax_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const fraction_id: FrameNodeId = @fromBackingInt(@intCast(5));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(6));
    const columns = [_]style.GridTrack{
        .{ .fixed = 20 },
        .{ .percent = 0.25 },
        .auto,
        .{ .minmax = .{
            .min = .{ .fixed = 10 },
            .max = .{ .fixed = 25 },
        } },
        .{ .fr = 1 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    try appendLeaf(&tree, fixed_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, percent_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(
        &tree,
        intrinsic_id,
        container_id,
        leafStyle(),
        .{ .label = .{ .text = "intrinsic" } },
    );
    try appendLeaf(&tree, minmax_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, fraction_id, container_id, leafStyle(), .{ .spacer = .{} });

    const item_ids = [_]FrameNodeId{ fixed_id, percent_id, intrinsic_id, minmax_id, fraction_id };
    for (item_ids, 0..) |id, index| {
        const node = tree.node(id) orelse return error.TestUnexpectedResult;
        node.style.grid_column = .{
            .start = .{ .line = @intCast(index + 1) },
            .end = .{ .line = @intCast(index + 2) },
        };
        node.style.grid_row = .{
            .start = .{ .line = 1 },
            .end = .{ .line = 2 },
        };
    }

    try appendContainer(&tree, container_id, .root, fixedContainer(200, 20, columns[0..], rows[0..]));
    for (item_ids) |id| try tree.appendChild(container_id, id);

    try layoutContainer(
        &tree,
        container_id,
        .{ .width = 200, .height = 20 },
        .{ .callback = measureLabel },
    );

    try expectRelative(&tree, fixed_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
    try expectRelative(&tree, percent_id, .{ .x = 20, .y = 0, .w = 50, .h = 20 });
    try expectRelative(&tree, intrinsic_id, .{ .x = 70, .y = 0, .w = 30, .h = 20 });
    try expectRelative(&tree, minmax_id, .{ .x = 100, .y = 0, .w = 25, .h = 20 });
    try expectRelative(&tree, fraction_id, .{ .x = 125, .y = 0, .w = 75, .h = 20 });
}

test "grid RTL content and item alignment reverse columns" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const inherited_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const self_aligned_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };
    const rows = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };

    var inherited = leafStyle();
    inherited.size = .{
        .width = .{ .length = 10 },
        .height = .{ .length = 10 },
    };
    inherited.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    inherited.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, inherited_id, container_id, inherited, .{ .spacer = .{} });

    var self_aligned = leafStyle();
    self_aligned.size = .{
        .width = .{ .length = 10 },
        .height = .{ .length = 10 },
    };
    self_aligned.grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    self_aligned.grid_row = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    self_aligned.grid_justify_self = .start;
    self_aligned.grid_align_self = .start;
    try appendLeaf(&tree, self_aligned_id, container_id, self_aligned, .{ .spacer = .{} });

    var container = fixedContainer(100, 100, columns[0..], rows[0..]);
    container.writing_direction = .rtl;
    container.grid_justify_content = .center;
    container.grid_align_content = .center;
    container.grid_justify_items = .end;
    container.grid_align_items = .end;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, inherited_id);
    try tree.appendChild(container_id, self_aligned_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 }, null);

    try expectRelative(&tree, inherited_id, .{ .x = 50, .y = 40, .w = 10, .h = 10 });
    try expectRelative(&tree, self_aligned_id, .{ .x = 40, .y = 50, .w = 10, .h = 10 });
}

test "grid absolute insets and nested scroll geometry remain relative" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var scroll_state: widget.ScrollState = .{};
    const overflowing_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const absolute_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const inner_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const outer_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const inner_columns = [_]style.GridTrack{.{ .fixed = 160 }};
    const inner_rows = [_]style.GridTrack{.{ .fixed = 100 }};
    const outer_columns = [_]style.GridTrack{.{ .fixed = 100 }};
    const outer_rows = [_]style.GridTrack{.{ .fixed = 60 }};

    var overflowing_style = leafStyle();
    overflowing_style.size = .{
        .width = .{ .length = 160 },
        .height = .{ .length = 100 },
    };
    try appendLeaf(&tree, overflowing_id, inner_id, overflowing_style, .{ .spacer = .{} });

    var absolute_style = leafStyle();
    absolute_style.position = .absolute;
    absolute_style.inset = .{
        .top = .{ .length = 5 },
        .right = .{ .length = 9 },
        .bottom = .{ .length = 11 },
        .left = .{ .length = 7 },
    };
    try appendLeaf(&tree, absolute_id, inner_id, absolute_style, .{ .spacer = .{} });

    const inner = fixedContainer(100, 60, inner_columns[0..], inner_rows[0..]);
    try appendContainer(&tree, inner_id, outer_id, inner);
    const inner_node = tree.node(inner_id) orelse return error.TestUnexpectedResult;
    inner_node.scroll = .{ .state = &scroll_state, .axis = .both };
    try tree.appendChild(inner_id, overflowing_id);
    try tree.appendChild(inner_id, absolute_id);

    var outer = fixedContainer(140, 100, outer_columns[0..], outer_rows[0..]);
    outer.padding_inset = .{
        .top = .{ .length = 8 },
        .right = .{ .length = 10 },
        .bottom = .{ .length = 8 },
        .left = .{ .length = 10 },
    };
    try appendContainer(&tree, outer_id, .root, outer);
    try tree.appendChild(outer_id, inner_id);

    try layoutContainer(&tree, outer_id, .{ .width = 140, .height = 100 }, null);

    try expectRelative(&tree, outer_id, .{ .x = 0, .y = 0, .w = 140, .h = 100 });
    try expectRelative(&tree, inner_id, .{ .x = 0, .y = 0, .w = 100, .h = 60 });
    try expectRelative(&tree, overflowing_id, .{ .x = 0, .y = 0, .w = 160, .h = 100 });
    try expectRelative(&tree, absolute_id, .{ .x = 7, .y = 5, .w = 84, .h = 44 });
    try expectRect(
        .{ .x = 10, .y = 8, .w = 160, .h = 100 },
        widget.absoluteRect(&tree, overflowing_id),
    );
    try expectRect(
        .{ .x = 17, .y = 13, .w = 84, .h = 44 },
        widget.absoluteRect(&tree, absolute_id),
    );
    try std.testing.expectEqual([2]f32{ 60, 40 }, scroll_state.max_offset);
}

test "grid display none zeroes its subtree" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const hidden_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{.{ .fixed = 40 }};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    try appendLeaf(&tree, leaf_id, hidden_id, leafStyle(), .{ .spacer = .{ .size = 12 } });
    try appendContainer(&tree, hidden_id, container_id, .{ .display = .none });
    try appendContainer(&tree, container_id, .root, fixedContainer(40, 20, columns[0..], rows[0..]));
    try tree.appendChild(hidden_id, leaf_id);
    try tree.appendChild(container_id, hidden_id);

    try layoutContainer(&tree, container_id, .{ .width = 40, .height = 20 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 40, .h = 20 });
    try expectRelative(&tree, hidden_id, .{});
    try expectRelative(&tree, leaf_id, .{});
}

test "grid rejects non-finite available size" {
    const invalid_sizes = [_]widget.Size{
        .{ .width = std.math.nan(f32), .height = 20 },
        .{ .width = 100, .height = std.math.inf(f32) },
    };

    for (invalid_sizes) |available| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const container_id: FrameNodeId = @fromBackingInt(@intCast(1));
        const columns = [_]style.GridTrack{.{ .fixed = 40 }};
        const rows = [_]style.GridTrack{.{ .fixed = 20 }};
        try appendContainer(&tree, container_id, .root, fixedContainer(40, 20, columns[0..], rows[0..]));

        try std.testing.expectError(
            error.InvalidStyle,
            grid.layoutContainer(&tree, container_id, .{
                .allocator = std.testing.allocator,
                .available = available,
                .measure = null,
            }),
        );
    }
}

test "grid indefinite fr track sizing scales proportionally to max fr contribution" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{ .{ .fr = 1 }, .{ .fr = 2 } };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var first_style = leafStyle();
    first_style.size = .{
        .width = .{ .length = 50 },
        .height = .{ .length = 20 },
    };
    first_style.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    first_style.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, first_id, container_id, first_style, .{ .spacer = .{} });

    var second_style = leafStyle();
    second_style.size = .{
        .width = .{ .length = 60 },
        .height = .{ .length = 20 },
    };
    second_style.grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    second_style.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, second_id, container_id, second_style, .{ .spacer = .{} });

    var container = fixedContainer(0, 0, columns[0..], rows[0..]);
    container.size = .{ .width = .auto, .height = .auto };
    container.column_gap = .{ .length = 10 };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 200, .height = 50 }, null);

    // 1fr = max(50/1, 60/2) = 50. Track 1 = 50, Track 2 = 100, gap = 10 -> Total width = 160.
    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 160, .h = 20 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 50, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 60, .y = 0, .w = 60, .h = 20 });
}

test "grid multi-track span includes track gaps when comparing item size" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const spanning_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const columns = [_]style.GridTrack{ .auto, .auto, .auto };
    const rows = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };

    var first_style = leafStyle();
    first_style.size = .{ .width = .{ .length = 20 }, .height = .{ .length = 20 } };
    first_style.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    first_style.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, first_id, container_id, first_style, .{ .spacer = .{} });

    var second_style = leafStyle();
    second_style.size = .{ .width = .{ .length = 30 }, .height = .{ .length = 20 } };
    second_style.grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    second_style.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, second_id, container_id, second_style, .{ .spacer = .{} });

    var spanning_style = leafStyle();
    spanning_style.size = .{ .width = .{ .length = 100 }, .height = .{ .length = 20 } };
    spanning_style.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 4 } };
    spanning_style.grid_row = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    try appendLeaf(&tree, spanning_id, container_id, spanning_style, .{ .spacer = .{} });

    var container = fixedContainer(0, 0, columns[0..], rows[0..]);
    container.size = .{ .width = .auto, .height = .auto };
    container.column_gap = .{ .length = 10 };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);
    try tree.appendChild(container_id, spanning_id);

    try layoutContainer(&tree, container_id, .{ .width = 200, .height = 60 }, null);

    // Tracks initially: 20, 30, 0 + 2*10 gap = 70. Deficit = 100 - 70 = 30.
    // 30 is assigned to the empty unbounded auto track -> Tracks become 20, 30, 30.
    // Total width = 20 + 10 + 30 + 10 + 30 = 100.
    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 40 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 30, .y = 0, .w = 30, .h = 20 });
    try expectRelative(&tree, spanning_id, .{ .x = 0, .y = 20, .w = 100, .h = 20 });
}

test "grid track minmax expands non-fr tracks up to max limit before fr tracks" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const spanning_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{
        .{ .minmax = .{
            .min = .{ .fixed = 10 },
            .max = .{ .fixed = 30 },
        } },
        .{ .fr = 1 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var spanning_style = leafStyle();
    spanning_style.size = .{ .width = .{ .length = 70 }, .height = .{ .length = 20 } };
    spanning_style.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 3 } };
    spanning_style.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, spanning_id, container_id, spanning_style, .{ .spacer = .{} });

    var container = fixedContainer(0, 0, columns[0..], rows[0..]);
    container.size = .{ .width = .auto, .height = .auto };
    container.column_gap = .{ .length = 10 };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, spanning_id);

    try layoutContainer(&tree, container_id, .{ .width = 200, .height = 40 }, null);

    // Col 0: min 10, max 30. Col 1: 0 (1fr). Gap = 10. Initial span space = 10 + 0 + 10 = 20.
    // Deficit = 70 - 20 = 50.
    // Col 0 expands by 20 to hit its max of 30. Remaining deficit 30 goes to Col 1 (1fr).
    // Col 0 = 30, Col 1 = 30. Total width = 30 + 10 + 30 = 70.
    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 70, .h = 20 });
    try expectRelative(&tree, spanning_id, .{ .x = 0, .y = 0, .w = 70, .h = 20 });
}

test "grid item auto margins absorb space under stretch alignment" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fixed = 100 }};
    const rows = [_]style.GridTrack{.{ .fixed = 40 }};

    var child = leafStyle();
    child.margin_inset = .{
        .top = .auto,
        .right = .auto,
        .bottom = .auto,
        .left = .auto,
    };
    child.grid_justify_self = .stretch;
    child.grid_align_self = .stretch;
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{ .size = 20 } });
    try appendContainer(&tree, container_id, .root, fixedContainer(100, 40, columns[0..], rows[0..]));
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 40 }, null);

    // Natural size of spacer is 20x20.
    // Available area: 100x40. Auto margins absorb horizontal (80 / 2 = 40) and vertical (20 / 2 = 10).
    try expectRelative(&tree, child_id, .{ .x = 40, .y = 10, .w = 20, .h = 20 });
}

test "grid fit-content limit does not undercut automatic minimum" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{
        .{ .fit_content = .{ .length = 50 } },
        .{ .fit_content = .{ .length = 50 } },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 30 }};

    // The fit-content limit caps growth, but never reduces an item's minimum contribution.
    var first = leafStyle();
    first.size = .{ .width = .{ .length = 30 }, .height = .{ .length = 30 } };
    first.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, first_id, container_id, first, .{ .spacer = .{} });

    var second = leafStyle();
    second.size = .{ .width = .{ .length = 80 }, .height = .{ .length = 30 } };
    second.grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    try appendLeaf(&tree, second_id, container_id, second, .{ .spacer = .{} });

    var container = fixedContainer(0, 30, columns[0..], rows[0..]);
    container.size.width = .auto;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 200, .height = 30 }, null);

    // The 80px second-item minimum exceeds its 50px fit-content limit.
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 30, .h = 30 });
    try expectRelative(&tree, second_id, .{ .x = 30, .y = 0, .w = 80, .h = 30 });
    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 110, .h = 30 });
}

test "grid fit-content percentage caps track against definite axis" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const marker_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{
        .{ .fit_content = .{ .percent = 0.5 } },
        .{ .fixed = 30 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var child = leafStyle();
    child.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    child.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{ .size = 40 } });

    var marker = leafStyle();
    marker.grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    marker.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, marker_id, container_id, marker, .{ .spacer = .{} });

    var container = fixedContainer(60, 20, columns[0..], rows[0..]);
    container.grid_justify_items = .stretch;
    container.grid_align_items = .stretch;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);
    try tree.appendChild(container_id, marker_id);

    try layoutContainer(&tree, container_id, .{ .width = 60, .height = 20 }, null);

    // The 30px limit cannot undercut the item's 40px automatic minimum.
    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 60, .h = 20 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 40, .h = 20 });
    try expectRelative(&tree, marker_id, .{ .x = 40, .y = 0, .w = 30, .h = 20 });
}

test "grid minmax fit-content maximum does not undercut fixed minimum" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const marker_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{
        .{ .minmax = .{
            .min = .{ .fixed = 60 },
            .max = .{ .fit_content = .{ .percent = 0.5 } },
        } },
        .{ .fixed = 40 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var child = leafStyle();
    child.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    child.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{ .size = 40 } });

    var marker = leafStyle();
    marker.grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    marker.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, marker_id, container_id, marker, .{ .spacer = .{} });

    var container = fixedContainer(100, 20, columns[0..], rows[0..]);
    container.grid_justify_items = .stretch;
    container.grid_align_items = .stretch;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);
    try tree.appendChild(container_id, marker_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 20 }, null);

    // The 50% maximum resolves to 50px, but it cannot undercut the 60px
    // minimum. The marker's x position proves the first track remains 60px.
    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 60, .h = 20 });
    try expectRelative(&tree, marker_id, .{ .x = 60, .y = 0, .w = 40, .h = 20 });
}

test "grid fit-content percentage is unbounded against indefinite axis" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fit_content = .{ .percent = 0.5 } }};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var child = leafStyle();
    child.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    child.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{ .size = 40 } });

    var container = fixedContainer(0, 20, columns[0..], rows[0..]);
    container.size.width = .auto;
    container.grid_justify_items = .stretch;
    container.grid_align_items = .stretch;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 60, .height = 20 }, null);

    // The auto width provides no percentage basis. The 50% limit must not use
    // the synthetic 60px available width and cap the natural 40px child at 30px.
    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 40, .h = 20 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 40, .h = 20 });
}

test "grid measureNatural treats indefinite fit-content percentage as unbounded" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fit_content = .{ .percent = 0.5 } }};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var child = leafStyle();
    child.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    child.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{ .size = 40 } });

    var container = fixedContainer(0, 20, columns[0..], rows[0..]);
    container.size.width = .auto;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = null,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();
    const measured = try grid.measureNatural(
        &tree,
        tree.nodeConst(container_id) orelse return error.TestUnexpectedResult,
        .{
            .available = .{ .width = 60, .height = 20 },
            .percentage_basis = .{ .width = null, .height = 20 },
            .width_mode = .max_content,
        },
        &context,
    );

    // An indefinite width leaves fit-content(50%) unbounded, so the natural
    // 40px contribution determines both content and border width.
    try std.testing.expectEqual(@as(f32, 40), measured.content.width);
    try std.testing.expectEqual(@as(f32, 40), measured.border.width);
    try std.testing.expectEqual(@as(f32, 20), measured.content.height);
    try std.testing.expectEqual(@as(f32, 20), measured.border.height);
}

test "grid min-content and max-content tracks size to item contributions" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.max_content};
    const rows = [_]style.GridTrack{.min_content};

    var child = leafStyle();
    child.size = .{ .width = .{ .length = 60 }, .height = .{ .length = 25 } };
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{} });

    var container = fixedContainer(0, 0, columns[0..], rows[0..]);
    container.size = .{ .width = .auto, .height = .auto };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 200, .height = 100 }, null);

    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 60, .h = 25 });
    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 60, .h = 25 });
}

test "grid fr track sizing with upper bound constraint freezing" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const third_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(4));

    // 3 columns: minmax(0, 60px), 1fr, 1fr. Container width = 240px.
    // Without freezing, each 1fr track would hypothetically get 240 / 3 = 80px.
    // But column 0 has max 60px, so it freezes at 60px.
    // Remaining free space = 240 - 60 = 180px, distributed equally between col 1 and col 2 (90px each).
    const columns = [_]style.GridTrack{
        .{ .minmax = .{
            .min = .{ .fixed = 0 },
            .max = .{ .fixed = 60 },
        } },
        .{ .fr = 1 },
        .{ .fr = 1 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 30 }};

    try appendLeaf(&tree, first_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, second_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, third_id, container_id, leafStyle(), .{ .spacer = .{} });

    try appendContainer(&tree, container_id, .root, fixedContainer(240, 30, columns[0..], rows[0..]));
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);
    try tree.appendChild(container_id, third_id);

    try layoutContainer(&tree, container_id, .{ .width = 240, .height = 30 }, null);

    // Col 0 = 60 (frozen at max), Col 1 = 90, Col 2 = 90.
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 60, .h = 30 });
    try expectRelative(&tree, second_id, .{ .x = 60, .y = 0, .w = 90, .h = 30 });
    try expectRelative(&tree, third_id, .{ .x = 150, .y = 0, .w = 90, .h = 30 });
}

test "grid multi-track span grows minmax non-fr tracks to max before fr tracks" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const spanning_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{
        .{ .minmax = .{
            .min = .{ .fixed = 20 },
            .max = .{ .fixed = 60 },
        } },
        .{ .fr = 1 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 30 }};

    var spanning_style = leafStyle();
    spanning_style.size = .{ .width = .{ .length = 140 }, .height = .{ .length = 30 } };
    spanning_style.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 3 } };
    spanning_style.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, spanning_id, container_id, spanning_style, .{ .spacer = .{} });

    var container = fixedContainer(0, 0, columns[0..], rows[0..]);
    container.size = .{ .width = .auto, .height = .auto };
    container.column_gap = .{ .length = 10 };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, spanning_id);

    try layoutContainer(&tree, container_id, .{ .width = 300, .height = 50 }, null);

    // Col 0: min 20, max 60. Col 1: 0 (1fr). Gap = 10. Initial sum = 20 + 0 + 10 = 30.
    // Deficit = 140 - 30 = 110.
    // Col 0 grows by 40 to hit its max limit of 60. Remaining deficit 70 goes to Col 1 (1fr).
    // Col 0 = 60, Col 1 = 70. Total width = 60 + 10 + 70 = 140.
    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 140, .h = 30 });
    try expectRelative(&tree, spanning_id, .{ .x = 0, .y = 0, .w = 140, .h = 30 });
}

test "grid justify-content space distribution accounts for item margins and gaps" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));

    const columns = [_]style.GridTrack{
        .{ .fixed = 50 },
        .{ .fixed = 50 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 30 }};

    var first = leafStyle();
    first.size = .{ .width = .{ .length = 30 }, .height = .{ .length = 30 } };
    first.margin_inset = .{
        .left = .{ .length = 10 },
        .right = .{ .length = 0 },
        .top = .{ .length = 0 },
        .bottom = .{ .length = 0 },
    };
    try appendLeaf(&tree, first_id, container_id, first, .{ .spacer = .{} });

    var second = leafStyle();
    second.size = .{ .width = .{ .length = 30 }, .height = .{ .length = 30 } };
    second.margin_inset = .{
        .left = .{ .length = 5 },
        .right = .{ .length = 0 },
        .top = .{ .length = 0 },
        .bottom = .{ .length = 0 },
    };
    try appendLeaf(&tree, second_id, container_id, second, .{ .spacer = .{} });

    var container = fixedContainer(300, 30, columns[0..], rows[0..]);
    container.column_gap = .{ .length = 20 };
    container.grid_justify_content = .space_between;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 300, .height = 30 }, null);

    // Track total = 50 + 50 + 20 = 120. Free space = 300 - 120 = 180.
    // space_between extra gap = 180 / (2 - 1) = 180.
    // Col 0 starts at x = 0. Item 1 x = 0 + margin.left (10) = 10.
    // Col 1 starts at x = 0 + 50 + 20 + 180 = 250. Item 2 x = 250 + margin.left (5) = 255.
    try expectRelative(&tree, first_id, .{ .x = 10, .y = 0, .w = 30, .h = 30 });
    try expectRelative(&tree, second_id, .{ .x = 255, .y = 0, .w = 30, .h = 30 });
}

test "grid baseline alignment aligns items with differing font sizes to shared baseline" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));

    const columns = [_]style.GridTrack{
        .{ .fixed = 80 },
        .{ .fixed = 80 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 60 }};

    // First item: a 20px request -> ascent = 20 * 0.8 = 16
    var first = leafStyle();
    first.size = .{ .width = .{ .length = 60 }, .height = .{ .length = 20 } };
    first.grid_align_self = .baseline;
    try appendLeaf(&tree, first_id, container_id, first, .{ .label = .{ .text = "First" } });
    const first_node = tree.node(first_id) orelse return error.TestUnexpectedResult;
    first_node.text_input = &.{ .style = .{ .font_fields = .{ .size = 20 } } };

    // Second item: a 40px request -> ascent = 40 * 0.8 = 32
    var second = leafStyle();
    second.size = .{ .width = .{ .length = 60 }, .height = .{ .length = 40 } };
    second.grid_align_self = .baseline;
    try appendLeaf(&tree, second_id, container_id, second, .{ .label = .{ .text = "Second" } });
    const second_node = tree.node(second_id) orelse return error.TestUnexpectedResult;
    second_node.text_input = &.{ .style = .{ .font_fields = .{ .size = 40 } } };

    var container = fixedContainer(160, 60, columns[0..], rows[0..]);
    container.grid_align_items = .baseline;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 160, .height = 60 }, null);

    // Max row ascent = 32.
    // First item: y = max_ascent - ascent = 32 - 16 = 16. Baseline = 16 + 16 = 32.
    // Second item: y = max_ascent - ascent = 32 - 32 = 0. Baseline = 0 + 32 = 32.
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 16, .w = 60, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 80, .y = 0, .w = 60, .h = 40 });
}

test "grid absolute item positioned in grid area defined by grid-column 2 / 4 with insets" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const in_flow_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const absolute_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));

    const columns = [_]style.GridTrack{
        .{ .fixed = 50 },
        .{ .fixed = 50 },
        .{ .fixed = 50 },
        .{ .fixed = 50 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 80 }};

    var in_flow = leafStyle();
    in_flow.size = .{ .width = .{ .length = 50 }, .height = .{ .length = 80 } };
    try appendLeaf(&tree, in_flow_id, container_id, in_flow, .{ .spacer = .{} });

    // Absolute item in grid-column: 2 / 4
    // (tracks index 1 and 2, start line 2 = x: 60, end line 4 = x: 170, width = 110)
    var absolute_style = leafStyle();
    absolute_style.position = .absolute;
    absolute_style.grid_column = .{
        .start = .{ .line = 2 },
        .end = .{ .line = 4 },
    };
    absolute_style.size = .{ .width = .{ .length = 80 }, .height = .{ .length = 40 } };
    absolute_style.inset = .{
        .left = .{ .length = 10 },
        .top = .{ .length = 5 },
        .right = .auto,
        .bottom = .auto,
    };
    try appendLeaf(&tree, absolute_id, container_id, absolute_style, .{ .spacer = .{} });

    var container = fixedContainer(230, 80, columns[0..], rows[0..]);
    container.column_gap = .{ .length = 10 };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, in_flow_id);
    try tree.appendChild(container_id, absolute_id);

    try layoutContainer(&tree, container_id, .{ .width = 230, .height = 80 }, null);

    // In-flow item placed in column 1 (x: 0, y: 0, w: 50, h: 80)
    try expectRelative(&tree, in_flow_id, .{ .x = 0, .y = 0, .w = 50, .h = 80 });
    // Absolute item placed in grid area [col 2..4] (area_x = 50 + 10 = 60, area_width = 50 + 10 + 50 = 110)
    // With left: 10, top: 5 -> x = 60 + 10 = 70, y = 0 + 5 = 5, w = 80, h = 40
    try expectRelative(&tree, absolute_id, .{ .x = 70, .y = 5, .w = 80, .h = 40 });
}

test "grid percentage tracks 50% 50% in definite container" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));

    const columns = [_]style.GridTrack{
        .{ .percent = 0.5 },
        .{ .percent = 0.5 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 60 }};

    var first = leafStyle();
    first.size = .{ .width = .auto, .height = .auto };
    try appendLeaf(&tree, first_id, container_id, first, .{ .spacer = .{} });

    var second = leafStyle();
    second.size = .{ .width = .auto, .height = .auto };
    try appendLeaf(&tree, second_id, container_id, second, .{ .spacer = .{} });

    var container = fixedContainer(200, 60, columns[0..], rows[0..]);
    container.grid_justify_items = .stretch;
    container.grid_align_items = .stretch;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 200, .height = 60 }, null);

    // Each 50% track in 200px container resolves to 100px
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 100, .h = 60 });
    try expectRelative(&tree, second_id, .{ .x = 100, .y = 0, .w = 100, .h = 60 });
}

test "grid fr floor freeze respects track base before redistribution" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));

    const columns = [_]style.GridTrack{ .{ .fr = 1 }, .{ .fr = 1 } };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var first_style = leafStyle();
    first_style.size = .{ .width = .{ .length = 60 }, .height = .{ .length = 20 } };
    first_style.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    first_style.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, first_id, container_id, first_style, .{ .spacer = .{} });

    try appendLeaf(&tree, second_id, container_id, leafStyle(), .{ .spacer = .{} });
    const second_node = tree.node(second_id) orelse return error.TestUnexpectedResult;
    second_node.style.grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    second_node.style.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };

    try appendContainer(&tree, container_id, .root, fixedContainer(200, 20, columns[0..], rows[0..]));
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 200, .height = 20 }, null);

    // Track 1 base (min-content) = 60. Equal share is 100 >= 60, so no freeze:
    // tracks stay 100/100 under floor-freeze CSS semantics.
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 60, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 100, .y = 0, .w = 100, .h = 20 });
}

test "grid minmax track clamps at max before fr track absorbs remainder" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));

    const columns = [_]style.GridTrack{
        .{ .minmax = .{
            .min = .{ .fixed = 30 },
            .max = .{ .fixed = 100 },
        } },
        .{ .fr = 1 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var first_style = leafStyle();
    first_style.size = .{ .width = .{ .length = 150 }, .height = .{ .length = 20 } };
    first_style.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    first_style.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, first_id, container_id, first_style, .{ .spacer = .{} });

    try appendLeaf(&tree, second_id, container_id, leafStyle(), .{ .spacer = .{} });
    const second_node = tree.node(second_id) orelse return error.TestUnexpectedResult;
    second_node.style.grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    second_node.style.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };

    try appendContainer(&tree, container_id, .root, fixedContainer(200, 20, columns[0..], rows[0..]));
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 200, .height = 20 }, null);

    // Track 1 clamps at its 100 max despite 150 content. The 1fr track takes
    // the remaining free space: 200 - 100 = 100.
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 150, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 100, .y = 0, .w = 100, .h = 20 });
}
test "grid min-width clamp makes post-clamp 1fr track definite" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fr = 1 }};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    try appendLeaf(
        &tree,
        child_id,
        container_id,
        leafStyle(),
        .{ .spacer = .{ .size = 10 } },
    );

    var container = fixedContainer(0, 20, columns[0..], rows[0..]);
    container.size.width = .auto;
    container.min_size.width = .{ .length = 200 };
    container.border_inset = .{
        .top = .{ .length = 0 },
        .right = .{ .length = 1 },
        .bottom = .{ .length = 0 },
        .left = .{ .length = 1 },
    };
    container.padding_inset = .{
        .top = .{ .length = 0 },
        .right = .{ .length = 10 },
        .bottom = .{ .length = 0 },
        .left = .{ .length = 10 },
    };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 300, .height = 20 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 200, .h = 20 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 178, .h = 20 });
    try expectRect(
        .{ .x = 11, .y = 0, .w = 178, .h = 20 },
        widget.absoluteRect(&tree, child_id),
    );
}

test "grid percent width items in two fr columns use grid-area width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{ .{ .fr = 1 }, .{ .fr = 1 } };
    const rows = [_]style.GridTrack{.{ .fixed = 100 }};

    var first = leafStyle();
    first.size = .{
        .width = .{ .percent = 1 },
        .height = .{ .length = 100 },
    };
    first.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    first.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, first_id, container_id, first, .{ .spacer = .{ .size = 10 } });

    var second = leafStyle();
    second.size = .{
        .width = .{ .percent = 1 },
        .height = .{ .length = 100 },
    };
    second.grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    second.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, second_id, container_id, second, .{ .spacer = .{ .size = 10 } });

    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(200, 100, columns[0..], rows[0..]),
    );
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 200, .height = 100 }, null);

    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, second_id, .{ .x = 100, .y = 0, .w = 100, .h = 100 });
}

test "grid RTL absolute auto insets use physical end static position" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fr = 1 }};
    const rows = [_]style.GridTrack{.{ .fixed = 160 }};

    var absolute = leafStyle();
    absolute.position = .absolute;
    absolute.size = .{
        .width = .{ .length = 0 },
        .height = .{ .length = 10 },
    };
    absolute.inset = .{
        .top = .{ .length = 2 },
        .right = .auto,
        .bottom = .auto,
        .left = .auto,
    };
    try appendLeaf(&tree, absolute_id, container_id, absolute, .{ .spacer = .{} });

    var container = fixedContainer(200, 160, columns[0..], rows[0..]);
    container.writing_direction = .rtl;
    container.padding_inset = .{
        .top = .{ .length = 0 },
        .right = .{ .length = 10 },
        .bottom = .{ .length = 0 },
        .left = .{ .length = 10 },
    };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, absolute_id);

    try layoutContainer(&tree, container_id, .{ .width = 200, .height = 160 }, null);

    try expectRelative(&tree, absolute_id, .{ .x = 190, .y = 2, .w = 0, .h = 10 });
}

test "grid RTL absolute auto insets use physical end of definite area" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 60 },
        .{ .fixed = 80 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var absolute = leafStyle();
    absolute.position = .absolute;
    absolute.size = .{
        .width = .{ .length = 0 },
        .height = .{ .length = 10 },
    };
    absolute.inset = .{
        .top = .{ .length = 2 },
        .right = .auto,
        .bottom = .auto,
        .left = .auto,
    };
    absolute.grid_column = .{
        .start = .{ .line = 2 },
        .end = .{ .line = 3 },
    };
    absolute.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(&tree, absolute_id, container_id, absolute, .{ .spacer = .{} });

    var container = fixedContainer(180, 20, columns[0..], rows[0..]);
    container.writing_direction = .rtl;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, absolute_id);

    try layoutContainer(&tree, container_id, .{ .width = 180, .height = 20 }, null);

    try expectRelative(&tree, absolute_id, .{ .x = 140, .y = 2, .w = 0, .h = 10 });
}

test "grid vertical scrollbar gutter reduces one fr column" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fr = 1 }};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    try appendLeaf(&tree, child_id, container_id, leafStyle(), .{ .spacer = .{} });
    var container = fixedContainer(100, 20, columns[0..], rows[0..]);
    container.overflow.height = .scroll;
    container.scrollbar_width = 15;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 20 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 85, .h = 20 });
}

test "grid RTL vertical scrollbar gutter shifts content origin" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fr = 1 }};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    try appendLeaf(&tree, child_id, container_id, leafStyle(), .{ .spacer = .{} });
    var container = fixedContainer(100, 20, columns[0..], rows[0..]);
    container.writing_direction = .rtl;
    container.overflow.height = .scroll;
    container.scrollbar_width = 15;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 20 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 85, .h = 20 });
    try expectRect(
        .{ .x = 15, .y = 0, .w = 85, .h = 20 },
        widget.absoluteRect(&tree, child_id),
    );
}

test "grid horizontal scrollbar gutter reduces one fr row" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fixed = 100 }};
    const rows = [_]style.GridTrack{.{ .fr = 1 }};

    try appendLeaf(&tree, child_id, container_id, leafStyle(), .{ .spacer = .{} });
    var container = fixedContainer(100, 100, columns[0..], rows[0..]);
    container.overflow.width = .scroll;
    container.scrollbar_width = 15;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 100, .h = 85 });
}

test "grid content-box vertical scrollbar gutter reduces one fr column" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fr = 1 }};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    try appendLeaf(&tree, child_id, container_id, leafStyle(), .{ .spacer = .{} });
    var container = fixedContainer(100, 20, columns[0..], rows[0..]);
    container.box_sizing = .content_box;
    container.overflow.height = .scroll;
    container.scrollbar_width = 15;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 20 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 85, .h = 20 });
}

test "grid intrinsic border-box scrollbars add gutters without filling available size" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.auto};
    const rows = [_]style.GridTrack{.auto};

    try appendLeaf(
        &tree,
        child_id,
        container_id,
        spacerStyle(),
        .{ .spacer = .{ .size = 40 } },
    );
    var container = fixedContainer(0, 0, columns[0..], rows[0..]);
    container.size = .{ .width = .auto, .height = .auto };
    container.box_sizing = .border_box;
    container.overflow.width = .scroll;
    container.overflow.height = .scroll;
    container.scrollbar_width = 15;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 55, .h = 55 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 40, .h = 40 });
}

test "grid fractional tracks below one leave remaining free space unused" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{ .{ .fr = 0.3 }, .{ .fr = 0.2 } };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    try appendLeaf(&tree, first_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, second_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(100, 20, columns[0..], rows[0..]),
    );
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 20 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 30, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 30, .y = 0, .w = 20, .h = 20 });
}

test "grid zero fr tracks retain intrinsic minimum widths" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{ .{ .fr = 0 }, .{ .fr = 0 } };
    const rows = [_]style.GridTrack{.{ .fixed = 50 }};

    try appendLeaf(
        &tree,
        first_id,
        container_id,
        spacerStyle(),
        .{ .spacer = .{ .size = 50 } },
    );
    try appendLeaf(
        &tree,
        second_id,
        container_id,
        spacerStyle(),
        .{ .spacer = .{ .size = 50 } },
    );
    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(100, 50, columns[0..], rows[0..]),
    );
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 50 }, null);

    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 50, .h = 50 });
    try expectRelative(&tree, second_id, .{ .x = 50, .y = 0, .w = 50, .h = 50 });
}

test "grid normal content alignment stretches auto columns" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{ .auto, .auto };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var first_style = leafStyle();
    first_style.size = .{
        .width = .{ .percent = 1 },
        .height = .{ .length = 20 },
    };
    try appendLeaf(&tree, first_id, container_id, first_style, .{ .spacer = .{} });

    var second_style = leafStyle();
    second_style.size = .{
        .width = .{ .percent = 1 },
        .height = .{ .length = 20 },
    };
    try appendLeaf(&tree, second_id, container_id, second_style, .{ .spacer = .{} });

    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(200, 20, columns[0..], rows[0..]),
    );
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 200, .height = 20 }, null);

    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 100, .y = 0, .w = 100, .h = 20 });
}

test "grid center content alignment preserves signed overflow offset" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const third_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const columns = [_]style.GridTrack{.{ .fixed = 20 }};
    const rows = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };

    try appendLeaf(&tree, first_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, second_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, third_id, container_id, leafStyle(), .{ .spacer = .{} });
    var container = fixedContainer(20, 120, columns[0..], rows[0..]);
    container.row_gap = .{ .length = 10 };
    container.grid_align_content = .center;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);
    try tree.appendChild(container_id, third_id);

    try layoutContainer(&tree, container_id, .{ .width = 20, .height = 120 }, null);

    try expectRelative(&tree, first_id, .{ .x = 0, .y = -10, .w = 20, .h = 40 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 40, .w = 20, .h = 40 });
    try expectRelative(&tree, third_id, .{ .x = 0, .y = 90, .w = 20, .h = 40 });
}

test "grid distributed content alignment falls back to start on overflow" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const third_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const columns = [_]style.GridTrack{.{ .fixed = 20 }};
    const rows = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };

    try appendLeaf(&tree, first_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, second_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, third_id, container_id, leafStyle(), .{ .spacer = .{} });
    var container = fixedContainer(20, 120, columns[0..], rows[0..]);
    container.row_gap = .{ .length = 10 };
    container.grid_align_content = .space_between;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);
    try tree.appendChild(container_id, third_id);

    try layoutContainer(&tree, container_id, .{ .width = 20, .height = 120 }, null);

    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 20, .h = 40 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 50, .w = 20, .h = 40 });
    try expectRelative(&tree, third_id, .{ .x = 0, .y = 100, .w = 20, .h = 40 });
}

test "negative grid inline free space distinguishes safe and unsafe center" {
    const scenarios = [_]struct {
        justify_content: style.Justify,
        expected_x: f32,
    }{
        .{ .justify_content = .safe_center, .expected_x = 0 },
        .{ .justify_content = .unsafe_center, .expected_x = -10 },
        .{ .justify_content = .center, .expected_x = -10 },
    };
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 40 }};

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
        const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
        try appendLeaf(&tree, child_id, container_id, leafStyle(), .{ .spacer = .{} });
        var container = fixedContainer(120, 40, columns[0..], rows[0..]);
        container.column_gap = .{ .length = 10 };
        container.grid_justify_content = scenario.justify_content;
        container.grid_align_content = .start;
        try appendContainer(&tree, container_id, .root, container);
        try tree.appendChild(container_id, child_id);

        try layoutContainer(&tree, container_id, .{ .width = 120, .height = 40 }, null);

        try expectRelative(&tree, child_id, .{
            .x = scenario.expected_x,
            .y = 0,
            .w = 40,
            .h = 40,
        });
    }
}

test "negative grid block free space distinguishes safe and unsafe center" {
    const scenarios = [_]struct {
        align_content: style.AlignContent,
        expected_y: f32,
    }{
        .{ .align_content = .safe_center, .expected_y = 0 },
        .{ .align_content = .unsafe_center, .expected_y = -10 },
        .{ .align_content = .center, .expected_y = -10 },
    };
    const columns = [_]style.GridTrack{.{ .fixed = 40 }};
    const rows = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
        const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
        try appendLeaf(&tree, child_id, container_id, leafStyle(), .{ .spacer = .{} });
        var container = fixedContainer(40, 120, columns[0..], rows[0..]);
        container.row_gap = .{ .length = 10 };
        container.grid_justify_content = .start;
        container.grid_align_content = scenario.align_content;
        try appendContainer(&tree, container_id, .root, container);
        try tree.appendChild(container_id, child_id);

        try layoutContainer(&tree, container_id, .{ .width = 40, .height = 120 }, null);

        try expectRelative(&tree, child_id, .{
            .x = 0,
            .y = scenario.expected_y,
            .w = 40,
            .h = 40,
        });
    }
}

test "oversized grid item distinguishes safe and unsafe alignment" {
    const scenarios = [_]struct {
        justify_items: style.Align,
        justify_self: style.AlignSelf,
        expected_x: f32,
        align_items: style.Align,
        align_self: style.AlignSelf,
        expected_y: f32,
    }{
        .{
            .justify_items = .safe_center,
            .justify_self = .auto,
            .expected_x = 0,
            .align_items = .start,
            .align_self = .auto,
            .expected_y = 0,
        },
        .{
            .justify_items = .unsafe_center,
            .justify_self = .auto,
            .expected_x = -10,
            .align_items = .start,
            .align_self = .auto,
            .expected_y = 0,
        },
        .{
            .justify_items = .center,
            .justify_self = .auto,
            .expected_x = -10,
            .align_items = .start,
            .align_self = .auto,
            .expected_y = 0,
        },
        .{
            .justify_items = .start,
            .justify_self = .safe_center,
            .expected_x = 0,
            .align_items = .start,
            .align_self = .auto,
            .expected_y = 0,
        },
        .{
            .justify_items = .start,
            .justify_self = .unsafe_center,
            .expected_x = -10,
            .align_items = .start,
            .align_self = .auto,
            .expected_y = 0,
        },
        .{
            .justify_items = .start,
            .justify_self = .center,
            .expected_x = -10,
            .align_items = .start,
            .align_self = .auto,
            .expected_y = 0,
        },
        .{
            .justify_items = .start,
            .justify_self = .auto,
            .expected_x = 0,
            .align_items = .safe_center,
            .align_self = .auto,
            .expected_y = 0,
        },
        .{
            .justify_items = .start,
            .justify_self = .auto,
            .expected_x = 0,
            .align_items = .unsafe_center,
            .align_self = .auto,
            .expected_y = -10,
        },
        .{
            .justify_items = .start,
            .justify_self = .auto,
            .expected_x = 0,
            .align_items = .center,
            .align_self = .auto,
            .expected_y = -10,
        },
        .{
            .justify_items = .start,
            .justify_self = .auto,
            .expected_x = 0,
            .align_items = .start,
            .align_self = .safe_center,
            .expected_y = 0,
        },
        .{
            .justify_items = .start,
            .justify_self = .auto,
            .expected_x = 0,
            .align_items = .start,
            .align_self = .unsafe_center,
            .expected_y = -10,
        },
        .{
            .justify_items = .start,
            .justify_self = .auto,
            .expected_x = 0,
            .align_items = .start,
            .align_self = .center,
            .expected_y = -10,
        },
    };
    const columns = [_]style.GridTrack{.{ .fixed = 20 }};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
        const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
        var child = leafStyle();
        child.size = .{
            .width = .{ .length = 40 },
            .height = .{ .length = 40 },
        };
        child.grid_justify_self = scenario.justify_self;
        child.grid_align_self = scenario.align_self;
        try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{} });
        var container = fixedContainer(20, 20, columns[0..], rows[0..]);
        container.grid_justify_content = .start;
        container.grid_align_content = .start;
        container.grid_justify_items = scenario.justify_items;
        container.grid_align_items = scenario.align_items;
        try appendContainer(&tree, container_id, .root, container);
        try tree.appendChild(container_id, child_id);

        try layoutContainer(&tree, container_id, .{ .width = 20, .height = 20 }, null);

        try expectRelative(&tree, child_id, .{
            .x = scenario.expected_x,
            .y = scenario.expected_y,
            .w = 40,
            .h = 40,
        });
    }
}

test "positive grid free space makes all center safety variants equivalent" {
    const scenarios = [_]struct {
        justify_content: style.Justify,
        align_content: style.AlignContent,
        justify_items: style.Align,
        align_items: style.Align,
        justify_self: style.AlignSelf,
        align_self: style.AlignSelf,
    }{
        .{
            .justify_content = .safe_center,
            .align_content = .safe_center,
            .justify_items = .safe_center,
            .align_items = .safe_center,
            .justify_self = .safe_center,
            .align_self = .safe_center,
        },
        .{
            .justify_content = .unsafe_center,
            .align_content = .unsafe_center,
            .justify_items = .unsafe_center,
            .align_items = .unsafe_center,
            .justify_self = .unsafe_center,
            .align_self = .unsafe_center,
        },
        .{
            .justify_content = .center,
            .align_content = .center,
            .justify_items = .center,
            .align_items = .center,
            .justify_self = .center,
            .align_self = .center,
        },
    };
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };
    const rows = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
        const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
        const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
        var first = leafStyle();
        first.size = .{
            .width = .{ .length = 20 },
            .height = .{ .length = 20 },
        };
        var second = first;
        second.grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
        second.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
        second.grid_justify_self = scenario.justify_self;
        second.grid_align_self = scenario.align_self;
        try appendLeaf(&tree, first_id, container_id, first, .{ .spacer = .{} });
        try appendLeaf(&tree, second_id, container_id, second, .{ .spacer = .{} });

        var container = fixedContainer(160, 160, columns[0..], rows[0..]);
        container.column_gap = .{ .length = 10 };
        container.row_gap = .{ .length = 10 };
        container.grid_justify_content = scenario.justify_content;
        container.grid_align_content = scenario.align_content;
        container.grid_justify_items = scenario.justify_items;
        container.grid_align_items = scenario.align_items;
        try appendContainer(&tree, container_id, .root, container);
        try tree.appendChild(container_id, first_id);
        try tree.appendChild(container_id, second_id);

        try layoutContainer(&tree, container_id, .{ .width = 160, .height = 160 }, null);

        try expectRelative(&tree, first_id, .{ .x = 20, .y = 20, .w = 20, .h = 20 });
        try expectRelative(&tree, second_id, .{ .x = 70, .y = 20, .w = 20, .h = 20 });
    }
}

test "grid intrinsic cross spans batch non-flexible items before cross-flex items" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_span_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_span_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const first_marker_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const second_marker_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const third_marker_id: FrameNodeId = @fromBackingInt(@intCast(5));
    const fourth_marker_id: FrameNodeId = @fromBackingInt(@intCast(6));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(7));
    const tracks = [_]style.GridTrack{ .{ .fr = 1 }, .auto, .auto, .auto };

    var first_span = leafStyle();
    first_span.size = .{
        .width = .{ .length = 60 },
        .height = .{ .length = 60 },
    };
    first_span.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .span = 2 },
    };
    first_span.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .span = 2 },
    };
    try appendLeaf(&tree, first_span_id, container_id, first_span, .{ .spacer = .{} });

    var second_span = leafStyle();
    second_span.size = .{
        .width = .{ .length = 150 },
        .height = .{ .length = 150 },
    };
    second_span.grid_column = .{
        .start = .{ .line = 2 },
        .end = .{ .span = 3 },
    };
    second_span.grid_row = .{
        .start = .{ .line = 2 },
        .end = .{ .span = 3 },
    };
    try appendLeaf(&tree, second_span_id, container_id, second_span, .{ .spacer = .{} });

    const marker_ids = [_]FrameNodeId{
        first_marker_id,
        second_marker_id,
        third_marker_id,
        fourth_marker_id,
    };
    for (marker_ids, 0..) |marker_id, index| {
        var marker = leafStyle();
        marker.grid_column = .{
            .start = .{ .line = @intCast(index + 1) },
            .end = .{ .line = @intCast(index + 2) },
        };
        marker.grid_row = .{
            .start = .{ .line = @intCast(index + 1) },
            .end = .{ .line = @intCast(index + 2) },
        };
        try appendLeaf(&tree, marker_id, container_id, marker, .{ .spacer = .{} });
    }

    var container = fixedContainer(50, 50, tracks[0..], tracks[0..]);
    container.border_inset = .{
        .top = .{ .length = 3 },
        .right = .{ .length = 3 },
        .bottom = .{ .length = 3 },
        .left = .{ .length = 3 },
    };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, first_span_id);
    try tree.appendChild(container_id, second_span_id);
    for (marker_ids) |marker_id| try tree.appendChild(container_id, marker_id);

    try layoutContainer(&tree, container_id, .{ .width = 50, .height = 50 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 50, .h = 50 });
    try expectRelative(&tree, first_span_id, .{ .x = 0, .y = 0, .w = 60, .h = 60 });
    try expectRelative(&tree, second_span_id, .{ .x = 10, .y = 10, .w = 150, .h = 150 });
    try expectRelative(&tree, first_marker_id, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
    try expectRelative(&tree, second_marker_id, .{ .x = 10, .y = 10, .w = 50, .h = 50 });
    try expectRelative(&tree, third_marker_id, .{ .x = 60, .y = 60, .w = 50, .h = 50 });
    try expectRelative(&tree, fourth_marker_id, .{ .x = 110, .y = 110, .w = 50, .h = 50 });
}

test "grid cross-span intrinsic deficit grows flexible row before auto row" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const spanning_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const first_marker_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const second_marker_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const columns = [_]style.GridTrack{.{ .fixed = 20 }};
    const rows = [_]style.GridTrack{ .{ .fr = 1 }, .auto };

    var spanning = leafStyle();
    spanning.size = .{
        .width = .{ .length = 20 },
        .height = .{ .length = 60 },
    };
    spanning.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    spanning.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .span = 2 } };
    try appendLeaf(&tree, spanning_id, container_id, spanning, .{ .spacer = .{} });

    var first_marker = leafStyle();
    first_marker.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    first_marker.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, first_marker_id, container_id, first_marker, .{ .spacer = .{} });

    var second_marker = leafStyle();
    second_marker.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    second_marker.grid_row = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    try appendLeaf(&tree, second_marker_id, container_id, second_marker, .{ .spacer = .{} });

    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(20, 50, columns[0..], rows[0..]),
    );
    try tree.appendChild(container_id, spanning_id);
    try tree.appendChild(container_id, first_marker_id);
    try tree.appendChild(container_id, second_marker_id);

    try layoutContainer(&tree, container_id, .{ .width = 20, .height = 50 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 20, .h = 50 });
    try expectRelative(&tree, spanning_id, .{ .x = 0, .y = 0, .w = 20, .h = 60 });
    try expectRelative(&tree, first_marker_id, .{ .x = 0, .y = 0, .w = 20, .h = 60 });
    try expectRelative(&tree, second_marker_id, .{ .x = 0, .y = 60, .w = 20, .h = 0 });
}

test "grid zero fr track receives no positive free space share" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{ .{ .fr = 0 }, .{ .fr = 1 } };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var first = leafStyle();
    first.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    first.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, first_id, container_id, first, .{ .spacer = .{} });

    var second = leafStyle();
    second.grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    second.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, second_id, container_id, second, .{ .spacer = .{} });

    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(100, 20, columns[0..], rows[0..]),
    );
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 20 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 0, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
}

test "grid positive fr tracks divide free space by weight" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{ .{ .fr = 1 }, .{ .fr = 3 } };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var first = leafStyle();
    first.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    first.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, first_id, container_id, first, .{ .spacer = .{} });

    var second = leafStyle();
    second.grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    second.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, second_id, container_id, second, .{ .spacer = .{} });

    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(100, 20, columns[0..], rows[0..]),
    );
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 20 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 25, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 25, .y = 0, .w = 75, .h = 20 });
}

test "grid zero fr absorbs cross-span intrinsic deficit before auto track" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const spanning_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const first_marker_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const second_marker_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const tracks = [_]style.GridTrack{ .{ .fr = 0 }, .auto };

    var spanning = leafStyle();
    spanning.size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
    };
    spanning.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .span = 2 } };
    spanning.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .span = 2 } };
    try appendLeaf(&tree, spanning_id, container_id, spanning, .{ .spacer = .{} });

    var first_marker = leafStyle();
    first_marker.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    first_marker.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, first_marker_id, container_id, first_marker, .{ .spacer = .{} });

    var second_marker = leafStyle();
    second_marker.grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    second_marker.grid_row = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    try appendLeaf(&tree, second_marker_id, container_id, second_marker, .{ .spacer = .{} });

    var container = fixedContainer(50, 50, tracks[0..], tracks[0..]);
    container.border_inset = .{
        .top = .{ .length = 3 },
        .right = .{ .length = 3 },
        .bottom = .{ .length = 3 },
        .left = .{ .length = 3 },
    };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, spanning_id);
    try tree.appendChild(container_id, first_marker_id);
    try tree.appendChild(container_id, second_marker_id);

    try layoutContainer(&tree, container_id, .{ .width = 50, .height = 50 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 50, .h = 50 });
    try expectRelative(&tree, spanning_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, first_marker_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, second_marker_id, .{ .x = 100, .y = 100, .w = 0, .h = 0 });
}

test "grid zero fr cross-span intrinsic deficit falls back to equal growth" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const spanning_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const first_marker_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const second_marker_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const tracks = [_]style.GridTrack{ .{ .fr = 0 }, .{ .fr = 0 } };

    var spanning = leafStyle();
    spanning.size = .{
        .width = .{ .length = 50 },
        .height = .{ .length = 50 },
    };
    spanning.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .span = 2 } };
    spanning.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .span = 2 } };
    try appendLeaf(&tree, spanning_id, container_id, spanning, .{ .spacer = .{} });

    var first_marker = leafStyle();
    first_marker.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    first_marker.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, first_marker_id, container_id, first_marker, .{ .spacer = .{} });

    var second_marker = leafStyle();
    second_marker.grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    second_marker.grid_row = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    try appendLeaf(&tree, second_marker_id, container_id, second_marker, .{ .spacer = .{} });

    var container = fixedContainer(60, 60, tracks[0..], tracks[0..]);
    container.border_inset = .{
        .top = .{ .length = 3 },
        .right = .{ .length = 3 },
        .bottom = .{ .length = 3 },
        .left = .{ .length = 3 },
    };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, spanning_id);
    try tree.appendChild(container_id, first_marker_id);
    try tree.appendChild(container_id, second_marker_id);

    try layoutContainer(&tree, container_id, .{ .width = 60, .height = 60 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 60, .h = 60 });
    try expectRelative(&tree, spanning_id, .{ .x = 0, .y = 0, .w = 50, .h = 50 });
    try expectRelative(&tree, first_marker_id, .{ .x = 0, .y = 0, .w = 25, .h = 25 });
    try expectRelative(&tree, second_marker_id, .{ .x = 25, .y = 25, .w = 25, .h = 25 });
}

test "grid minmax zero fr cross-span deficit leaves auto track at zero" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const spanning_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const first_marker_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const second_marker_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const tracks = [_]style.GridTrack{
        .{ .minmax = .{
            .min = .{ .fixed = 0 },
            .max = .{ .fr = 1 },
        } },
        .auto,
    };

    var spanning = leafStyle();
    spanning.size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
    };
    spanning.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .span = 2 } };
    spanning.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .span = 2 } };
    try appendLeaf(&tree, spanning_id, container_id, spanning, .{ .spacer = .{} });

    var first_marker = leafStyle();
    first_marker.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    first_marker.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, first_marker_id, container_id, first_marker, .{ .spacer = .{} });

    var second_marker = leafStyle();
    second_marker.grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    second_marker.grid_row = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    try appendLeaf(&tree, second_marker_id, container_id, second_marker, .{ .spacer = .{} });

    var container = fixedContainer(50, 50, tracks[0..], tracks[0..]);
    container.border_inset = .{
        .top = .{ .length = 3 },
        .right = .{ .length = 3 },
        .bottom = .{ .length = 3 },
        .left = .{ .length = 3 },
    };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, spanning_id);
    try tree.appendChild(container_id, first_marker_id);
    try tree.appendChild(container_id, second_marker_id);

    try layoutContainer(&tree, container_id, .{ .width = 50, .height = 50 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 50, .h = 50 });
    try expectRelative(&tree, spanning_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, first_marker_id, .{ .x = 0, .y = 0, .w = 44, .h = 44 });
    try expectRelative(&tree, second_marker_id, .{ .x = 44, .y = 44, .w = 0, .h = 0 });
}

test "grid equal-span intrinsic batches are source-order independent" {
    const source_orders_reversed = [_]bool{ false, true };

    for (source_orders_reversed) |source_order_reversed| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const second_third_span_id: FrameNodeId = @fromBackingInt(@intCast(1));
        const first_second_span_id: FrameNodeId = @fromBackingInt(@intCast(2));
        const first_marker_id: FrameNodeId = @fromBackingInt(@intCast(3));
        const second_marker_id: FrameNodeId = @fromBackingInt(@intCast(4));
        const third_marker_id: FrameNodeId = @fromBackingInt(@intCast(5));
        const container_id: FrameNodeId = @fromBackingInt(@intCast(6));
        const columns = [_]style.GridTrack{ .auto, .auto, .auto };
        const rows = [_]style.GridTrack{.{ .fixed = 20 }};

        var second_third_span = leafStyle();
        second_third_span.size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 20 },
        };
        second_third_span.grid_column = .{
            .start = .{ .line = 2 },
            .end = .{ .line = 4 },
        };
        second_third_span.grid_row = .{
            .start = .{ .line = 1 },
            .end = .{ .line = 2 },
        };
        try appendLeaf(
            &tree,
            second_third_span_id,
            container_id,
            second_third_span,
            .{ .spacer = .{} },
        );

        var first_second_span = leafStyle();
        first_second_span.size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 20 },
        };
        first_second_span.grid_column = .{
            .start = .{ .line = 1 },
            .end = .{ .line = 3 },
        };
        first_second_span.grid_row = .{
            .start = .{ .line = 1 },
            .end = .{ .line = 2 },
        };
        try appendLeaf(
            &tree,
            first_second_span_id,
            container_id,
            first_second_span,
            .{ .spacer = .{} },
        );

        const marker_ids = [_]FrameNodeId{
            first_marker_id,
            second_marker_id,
            third_marker_id,
        };
        for (marker_ids, 0..) |marker_id, index| {
            var marker = leafStyle();
            marker.grid_column = .{
                .start = .{ .line = @intCast(index + 1) },
                .end = .{ .line = @intCast(index + 2) },
            };
            marker.grid_row = .{
                .start = .{ .line = 1 },
                .end = .{ .line = 2 },
            };
            try appendLeaf(
                &tree,
                marker_id,
                container_id,
                marker,
                .{ .spacer = .{ .size = 0 } },
            );
        }

        const container: Style = .{
            .display = .grid,
            .box_sizing = .border_box,
            .size = .{
                .width = .auto,
                .height = .{ .length = 20 },
            },
            .grid_template_columns = columns[0..],
            .grid_template_rows = rows[0..],
        };
        try appendContainer(&tree, container_id, .root, container);
        if (source_order_reversed) {
            try tree.appendChild(container_id, first_second_span_id);
            try tree.appendChild(container_id, second_third_span_id);
        } else {
            try tree.appendChild(container_id, second_third_span_id);
            try tree.appendChild(container_id, first_second_span_id);
        }
        for (marker_ids) |marker_id| try tree.appendChild(container_id, marker_id);

        try layoutContainer(&tree, container_id, .{ .width = 500, .height = 20 }, null);

        try expectRelative(
            &tree,
            container_id,
            .{ .x = 0, .y = 0, .w = 150, .h = 20 },
        );
        try expectRelative(
            &tree,
            second_third_span_id,
            .{ .x = 50, .y = 0, .w = 100, .h = 20 },
        );
        try expectRelative(
            &tree,
            first_second_span_id,
            .{ .x = 0, .y = 0, .w = 100, .h = 20 },
        );
        try expectRelative(
            &tree,
            first_marker_id,
            .{ .x = 0, .y = 0, .w = 50, .h = 20 },
        );
        try expectRelative(
            &tree,
            second_marker_id,
            .{ .x = 50, .y = 0, .w = 50, .h = 20 },
        );
        try expectRelative(
            &tree,
            third_marker_id,
            .{ .x = 100, .y = 0, .w = 50, .h = 20 },
        );
    }
}

test "grid indefinite flex crossing routes intrinsic deficit to fr track" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const spanning_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const fr_marker_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const auto_marker_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const columns = [_]style.GridTrack{ .{ .fr = 1 }, .auto };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var spanning = leafStyle();
    spanning.size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 20 },
    };
    spanning.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 3 },
    };
    spanning.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(&tree, spanning_id, container_id, spanning, .{ .spacer = .{} });

    var fr_marker = leafStyle();
    fr_marker.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    fr_marker.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(
        &tree,
        fr_marker_id,
        container_id,
        fr_marker,
        .{ .spacer = .{ .size = 0 } },
    );

    var auto_marker = leafStyle();
    auto_marker.grid_column = .{
        .start = .{ .line = 2 },
        .end = .{ .line = 3 },
    };
    auto_marker.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(
        &tree,
        auto_marker_id,
        container_id,
        auto_marker,
        .{ .spacer = .{ .size = 0 } },
    );

    const container: Style = .{
        .display = .grid,
        .box_sizing = .border_box,
        .size = .{
            .width = .auto,
            .height = .{ .length = 20 },
        },
        .grid_template_columns = columns[0..],
        .grid_template_rows = rows[0..],
    };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, spanning_id);
    try tree.appendChild(container_id, fr_marker_id);
    try tree.appendChild(container_id, auto_marker_id);

    try layoutContainer(&tree, container_id, .{ .width = 500, .height = 20 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, spanning_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, fr_marker_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, auto_marker_id, .{ .x = 100, .y = 0, .w = 0, .h = 20 });
}

test "grid flexible span contributions batch before final fr distribution" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const spanning_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const first_marker_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const second_marker_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(5));
    const columns = [_]style.GridTrack{ .{ .fr = 1 }, .{ .fr = 1 } };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var first = leafStyle();
    first.size = .{
        .width = .{ .length = 50 },
        .height = .{ .length = 20 },
    };
    first.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    first.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(&tree, first_id, container_id, first, .{ .spacer = .{} });

    var spanning = leafStyle();
    spanning.size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 20 },
    };
    spanning.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 3 },
    };
    spanning.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(&tree, spanning_id, container_id, spanning, .{ .spacer = .{} });

    var first_marker = leafStyle();
    first_marker.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    first_marker.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(
        &tree,
        first_marker_id,
        container_id,
        first_marker,
        .{ .spacer = .{ .size = 0 } },
    );

    var second_marker = leafStyle();
    second_marker.grid_column = .{
        .start = .{ .line = 2 },
        .end = .{ .line = 3 },
    };
    second_marker.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(
        &tree,
        second_marker_id,
        container_id,
        second_marker,
        .{ .spacer = .{ .size = 0 } },
    );

    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(100, 20, columns[0..], rows[0..]),
    );
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, spanning_id);
    try tree.appendChild(container_id, first_marker_id);
    try tree.appendChild(container_id, second_marker_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 20 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 50, .h = 20 });
    try expectRelative(&tree, spanning_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, first_marker_id, .{ .x = 0, .y = 0, .w = 50, .h = 20 });
    try expectRelative(&tree, second_marker_id, .{ .x = 50, .y = 0, .w = 50, .h = 20 });
}

test "grid align self-start stays at block start across direction mismatch" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fixed = 60 }};
    const rows = [_]style.GridTrack{.{ .fixed = 40 }};

    var child = leafStyle();
    child.writing_direction = .rtl;
    child.size = .{
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
    };
    child.grid_justify_self = .start;
    child.grid_align_self = .self_start;
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{} });

    var container = fixedContainer(60, 40, columns[0..], rows[0..]);
    container.writing_direction = .ltr;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 60, .height = 40 }, null);

    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
}

test "grid align self-end stays at block end across direction mismatch" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fixed = 60 }};
    const rows = [_]style.GridTrack{.{ .fixed = 40 }};

    var child = leafStyle();
    child.writing_direction = .rtl;
    child.size = .{
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
    };
    child.grid_justify_self = .start;
    child.grid_align_self = .self_end;
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{} });

    var container = fixedContainer(60, 40, columns[0..], rows[0..]);
    container.writing_direction = .ltr;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 60, .height = 40 }, null);

    try expectRelative(&tree, child_id, .{ .x = 0, .y = 30, .w = 20, .h = 10 });
}

test "grid justify self start and end flip across direction mismatch" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const self_start_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const self_end_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{.{ .fixed = 60 }};
    const rows = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };

    var self_start = leafStyle();
    self_start.writing_direction = .rtl;
    self_start.size = .{
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
    };
    self_start.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    self_start.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    self_start.grid_justify_self = .self_start;
    self_start.grid_align_self = .start;
    try appendLeaf(
        &tree,
        self_start_id,
        container_id,
        self_start,
        .{ .spacer = .{} },
    );

    var self_end = leafStyle();
    self_end.writing_direction = .rtl;
    self_end.size = .{
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
    };
    self_end.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    self_end.grid_row = .{
        .start = .{ .line = 2 },
        .end = .{ .line = 3 },
    };
    self_end.grid_justify_self = .self_end;
    self_end.grid_align_self = .start;
    try appendLeaf(&tree, self_end_id, container_id, self_end, .{ .spacer = .{} });

    var container = fixedContainer(60, 40, columns[0..], rows[0..]);
    container.writing_direction = .ltr;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, self_start_id);
    try tree.appendChild(container_id, self_end_id);

    try layoutContainer(&tree, container_id, .{ .width = 60, .height = 40 }, null);

    try expectRelative(
        &tree,
        self_start_id,
        .{ .x = 40, .y = 0, .w = 20, .h = 10 },
    );
    try expectRelative(
        &tree,
        self_end_id,
        .{ .x = 0, .y = 20, .w = 20, .h = 10 },
    );
}

test "grid negative line prepends implicit columns before the explicit grid" {
    const directions = [_]style.Direction{ .ltr, .rtl };
    const expected_ltr = [_]Rect{
        .{ .x = 0, .y = 0, .w = 20, .h = 40 },
        .{ .x = 40, .y = 0, .w = 20, .h = 40 },
        .{ .x = 0, .y = 40, .w = 20, .h = 40 },
    };
    const expected_rtl = [_]Rect{
        .{ .x = 100, .y = 0, .w = 20, .h = 40 },
        .{ .x = 60, .y = 0, .w = 20, .h = 40 },
        .{ .x = 100, .y = 40, .w = 20, .h = 40 },
    };
    const columns = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };
    const rows = [_]style.GridTrack{ .{ .fixed = 40 }, .{ .fixed = 40 } };

    for (directions) |direction| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const negative_id: FrameNodeId = @fromBackingInt(@intCast(1));
        const auto_id: FrameNodeId = @fromBackingInt(@intCast(2));
        const second_row_id: FrameNodeId = @fromBackingInt(@intCast(3));
        const container_id: FrameNodeId = @fromBackingInt(@intCast(4));

        var negative = leafStyle();
        negative.writing_direction = direction;
        negative.size.width = .{ .length = 20 };
        negative.grid_column.start = .{ .line = -5 };
        negative.grid_row.start = .{ .line = 1 };
        try appendLeaf(&tree, negative_id, container_id, negative, .{ .spacer = .{} });

        var auto = leafStyle();
        auto.writing_direction = direction;
        auto.size.width = .{ .length = 20 };
        try appendLeaf(&tree, auto_id, container_id, auto, .{ .spacer = .{} });

        var second_row = leafStyle();
        second_row.writing_direction = direction;
        second_row.size.width = .{ .length = 20 };
        second_row.grid_row.start = .{ .line = 2 };
        try appendLeaf(
            &tree,
            second_row_id,
            container_id,
            second_row,
            .{ .spacer = .{} },
        );

        var container = fixedContainer(120, 120, columns[0..], rows[0..]);
        container.writing_direction = direction;
        try appendContainer(&tree, container_id, .root, container);
        try tree.appendChild(container_id, negative_id);
        try tree.appendChild(container_id, auto_id);
        try tree.appendChild(container_id, second_row_id);

        try layoutContainer(&tree, container_id, .{ .width = 120, .height = 120 }, null);

        const expected = if (direction == .ltr) expected_ltr[0..] else expected_rtl[0..];
        try expectRelative(
            &tree,
            container_id,
            .{ .x = 0, .y = 0, .w = 120, .h = 120 },
        );
        try expectRelative(&tree, negative_id, expected[0]);
        try expectRelative(&tree, auto_id, expected[1]);
        try expectRelative(&tree, second_row_id, expected[2]);
    }
}

test "grid row flow places column-definite row-auto items in source order" {
    const source_orders_reversed = [_]bool{ false, true };
    const columns = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };
    const rows = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };

    for (source_orders_reversed) |source_order_reversed| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const auto_id: FrameNodeId = @fromBackingInt(@intCast(1));
        const column_definite_id: FrameNodeId = @fromBackingInt(@intCast(2));
        const container_id: FrameNodeId = @fromBackingInt(@intCast(3));

        try appendLeaf(&tree, auto_id, container_id, leafStyle(), .{ .spacer = .{} });

        var column_definite = leafStyle();
        column_definite.grid_column = .{
            .start = .{ .line = 1 },
            .end = .{ .line = 2 },
        };
        try appendLeaf(
            &tree,
            column_definite_id,
            container_id,
            column_definite,
            .{ .spacer = .{} },
        );
        try appendContainer(
            &tree,
            container_id,
            .root,
            fixedContainer(40, 40, columns[0..], rows[0..]),
        );

        if (source_order_reversed) {
            try tree.appendChild(container_id, column_definite_id);
            try tree.appendChild(container_id, auto_id);
        } else {
            try tree.appendChild(container_id, auto_id);
            try tree.appendChild(container_id, column_definite_id);
        }

        try layoutContainer(&tree, container_id, .{ .width = 40, .height = 40 }, null);

        try expectRelative(
            &tree,
            container_id,
            .{ .x = 0, .y = 0, .w = 40, .h = 40 },
        );
        if (source_order_reversed) {
            try expectRelative(
                &tree,
                column_definite_id,
                .{ .x = 0, .y = 0, .w = 20, .h = 20 },
            );
            try expectRelative(&tree, auto_id, .{ .x = 20, .y = 0, .w = 20, .h = 20 });
        } else {
            try expectRelative(&tree, auto_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
            try expectRelative(
                &tree,
                column_definite_id,
                .{ .x = 0, .y = 20, .w = 20, .h = 20 },
            );
        }
    }
}

test "grid dense row flow places column-definite row-auto items in source order" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_auto_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_auto_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const reserved_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const columns = [_]style.GridTrack{
        .{ .fixed = 20 },
        .{ .fixed = 20 },
        .{ .fixed = 20 },
    };
    const rows = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };

    try appendLeaf(&tree, first_auto_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, second_auto_id, container_id, leafStyle(), .{ .spacer = .{} });
    var reserved = leafStyle();
    reserved.grid_column = .{ .start = .{ .line = 1 }, .end = .auto };
    try appendLeaf(&tree, reserved_id, container_id, reserved, .{ .spacer = .{} });

    var container = fixedContainer(60, 40, columns[0..], rows[0..]);
    container.grid_auto_flow = .row_dense;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, first_auto_id);
    try tree.appendChild(container_id, second_auto_id);
    try tree.appendChild(container_id, reserved_id);

    try layoutContainer(&tree, container_id, .{ .width = 60, .height = 40 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 60, .h = 40 });
    try expectRelative(&tree, reserved_id, .{ .x = 0, .y = 20, .w = 20, .h = 20 });
    try expectRelative(&tree, first_auto_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
    try expectRelative(&tree, second_auto_id, .{ .x = 20, .y = 0, .w = 20, .h = 20 });
}

test "grid positive line beyond 1024 creates an implicit auto track" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fixed = 20 }};
    const auto_rows = [_]style.GridTrack{.{ .fixed = 0 }};

    var child = leafStyle();
    child.size = .{
        .width = .{ .length = 20 },
        .height = .{ .length = 20 },
    };
    child.grid_column.start = .{ .line = 1 };
    child.grid_row.start = .{ .line = 1026 };
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{} });

    var container = fixedContainer(20, 0, columns[0..], &.{});
    container.grid_auto_rows = auto_rows[0..];
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 20, .height = 20 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 20, .h = 0 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
}

test "grid negative line beyond 1024 prepends an implicit auto track" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fixed = 20 }};
    const rows: []const style.GridTrack = &.{};
    const auto_rows = [_]style.GridTrack{.{ .fixed = 0 }};

    var child = leafStyle();
    child.size = .{
        .width = .{ .length = 20 },
        .height = .{ .length = 20 },
    };
    child.grid_column.start = .{ .line = 1 };
    child.grid_row.start = .{ .line = -1026 };
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{} });

    var container = fixedContainer(20, 0, columns[0..], rows);
    container.grid_auto_rows = auto_rows[0..];
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 20, .height = 20 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 20, .h = 0 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
}

test "grid multi-span auto tracks mirror taffy issue 624 in both directions" {
    const directions = [_]style.Direction{ .ltr, .rtl };
    const expected_ltr = [_]Rect{
        .{ .x = 0, .y = 0, .w = 100, .h = 50 },
        .{ .x = 100, .y = 0, .w = 40, .h = 30 },
        .{ .x = 0, .y = 50, .w = 120, .h = 20 },
    };
    const expected_rtl = [_]Rect{
        .{ .x = 220, .y = 0, .w = 100, .h = 50 },
        .{ .x = 180, .y = 0, .w = 40, .h = 30 },
        .{ .x = 200, .y = 50, .w = 120, .h = 20 },
    };
    const columns = [_]style.GridTrack{ .auto, .auto, .{ .fr = 1 } };
    const rows = [_]style.GridTrack{ .auto, .auto, .auto, .{ .fr = 1 } };

    for (directions) |direction| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
        const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
        const third_id: FrameNodeId = @fromBackingInt(@intCast(3));
        const container_id: FrameNodeId = @fromBackingInt(@intCast(4));

        var first = leafStyle();
        first.writing_direction = direction;
        first.size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 50 },
        };
        first.grid_column.start = .{ .line = 1 };
        first.grid_row = .{
            .start = .{ .line = 1 },
            .end = .{ .span = 2 },
        };
        try appendLeaf(&tree, first_id, container_id, first, .{ .spacer = .{} });

        var second = leafStyle();
        second.writing_direction = direction;
        second.size = .{
            .width = .{ .length = 40 },
            .height = .{ .length = 30 },
        };
        second.grid_column = .{
            .start = .{ .line = 2 },
            .end = .{ .span = 2 },
        };
        second.grid_row = .{
            .start = .{ .line = 1 },
            .end = .{ .span = 2 },
        };
        try appendLeaf(&tree, second_id, container_id, second, .{ .spacer = .{} });

        var third = leafStyle();
        third.writing_direction = direction;
        third.size = .{
            .width = .{ .length = 120 },
            .height = .{ .length = 20 },
        };
        third.grid_column = .{
            .start = .{ .line = 1 },
            .end = .{ .span = 2 },
        };
        third.grid_row = .{
            .start = .{ .line = 3 },
            .end = .{ .span = 1 },
        };
        try appendLeaf(&tree, third_id, container_id, third, .{ .spacer = .{} });

        var container = fixedContainer(320, 640, columns[0..], rows[0..]);
        container.writing_direction = direction;
        container.grid_justify_content = .start;
        container.grid_justify_items = .start;
        try appendContainer(&tree, container_id, .root, container);
        try tree.appendChild(container_id, first_id);
        try tree.appendChild(container_id, second_id);
        try tree.appendChild(container_id, third_id);

        try layoutContainer(&tree, container_id, .{ .width = 320, .height = 640 }, null);

        const expected = if (direction == .ltr) expected_ltr[0..] else expected_rtl[0..];
        try expectRelative(
            &tree,
            container_id,
            .{ .x = 0, .y = 0, .w = 320, .h = 640 },
        );
        try expectRelative(&tree, first_id, expected[0]);
        try expectRelative(&tree, second_id, expected[1]);
        try expectRelative(&tree, third_id, expected[2]);
    }
}

test "grid absolute placement uses the parent padding and border frame" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const third_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const fourth_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(5));

    const empty_tracks: []const style.GridTrack = &.{};
    const absolute_size: style.DimensionSize = .{
        .width = .{ .length = 50 },
        .height = .{ .length = 50 },
    };
    const zero_insets: style.Insets = .{
        .top = .{ .length = 0 },
        .right = .{ .length = 0 },
        .bottom = .{ .length = 0 },
        .left = .{ .length = 0 },
    };

    var first = leafStyle();
    first.position = .absolute;
    first.size = absolute_size;
    first.inset = zero_insets;
    first.inset.right = .auto;
    first.inset.bottom = .auto;
    try appendLeaf(&tree, first_id, container_id, first, .{ .spacer = .{} });

    var second = leafStyle();
    second.position = .absolute;
    second.size = absolute_size;
    second.inset = zero_insets;
    second.inset.left = .auto;
    second.inset.top = .auto;
    try appendLeaf(&tree, second_id, container_id, second, .{ .spacer = .{} });

    var third = leafStyle();
    third.position = .absolute;
    third.size = absolute_size;
    third.inset = zero_insets;
    third.inset.right = .auto;
    third.inset.bottom = .auto;
    third.margin_inset = .{
        .top = .{ .length = 10 },
        .right = .{ .length = 10 },
        .bottom = .{ .length = 10 },
        .left = .{ .length = 10 },
    };
    try appendLeaf(&tree, third_id, container_id, third, .{ .spacer = .{} });

    var fourth = leafStyle();
    fourth.position = .absolute;
    fourth.size = absolute_size;
    fourth.inset = zero_insets;
    fourth.inset.left = .auto;
    fourth.inset.top = .auto;
    fourth.margin_inset = .{
        .top = .{ .length = 10 },
        .right = .{ .length = 10 },
        .bottom = .{ .length = 10 },
        .left = .{ .length = 10 },
    };
    try appendLeaf(&tree, fourth_id, container_id, fourth, .{ .spacer = .{} });

    var container = fixedContainer(100, 100, empty_tracks, empty_tracks);
    container.border_inset = .{
        .top = .{ .length = 10 },
        .right = .{ .length = 10 },
        .bottom = .{ .length = 10 },
        .left = .{ .length = 10 },
    };
    container.padding_inset = .{
        .top = .{ .length = 10 },
        .right = .{ .length = 10 },
        .bottom = .{ .length = 10 },
        .left = .{ .length = 10 },
    };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);
    try tree.appendChild(container_id, third_id);
    try tree.appendChild(container_id, fourth_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, first_id, .{ .x = -10, .y = -10, .w = 50, .h = 50 });
    try expectRelative(&tree, second_id, .{ .x = 20, .y = 20, .w = 50, .h = 50 });
    try expectRelative(&tree, third_id, .{ .x = 0, .y = 0, .w = 50, .h = 50 });
    try expectRelative(&tree, fourth_id, .{ .x = 10, .y = 10, .w = 50, .h = 50 });
}

test "grid absolute column start defaults its opposite side to the padding frame" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };
    const rows = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };

    var absolute = leafStyle();
    absolute.position = .absolute;
    absolute.grid_column.start = .{ .line = 1 };
    absolute.inset = .{
        .top = .{ .length = 1 },
        .right = .{ .length = 3 },
        .bottom = .{ .length = 2 },
        .left = .{ .length = 4 },
    };
    try appendLeaf(&tree, absolute_id, container_id, absolute, .{ .spacer = .{} });

    var container = fixedContainer(180, 160, columns[0..], rows[0..]);
    container.padding_inset = .{
        .top = .{ .length = 10 },
        .right = .{ .length = 20 },
        .bottom = .{ .length = 30 },
        .left = .{ .length = 40 },
    };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, absolute_id);

    try layoutContainer(&tree, container_id, .{ .width = 180, .height = 160 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 180, .h = 160 });
    try expectRelative(&tree, absolute_id, .{ .x = 4, .y = -9, .w = 133, .h = 157 });
}

test "grid absolute justify-self positions sized items across the containing area" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const container_id: FrameNodeId = @fromBackingInt(@intCast(9));
    const columns = [_]style.GridTrack{.{ .fixed = 100 }};
    const rows = [_]style.GridTrack{.{ .fixed = 100 }};
    const justifies = [_]style.AlignSelf{
        .start,
        .start,
        .end,
        .end,
        .center,
        .center,
        .stretch,
        .stretch,
    };
    const widths = [_]f32{ 20, 60, 20, 60, 20, 60, 20, 60 };
    const expected_x = [_]f32{ 0, 0, 80, 40, 40, 20, 0, 0 };
    const child_ids = [_]FrameNodeId{
        @fromBackingInt(@intCast(1)),
        @fromBackingInt(@intCast(2)),
        @fromBackingInt(@intCast(3)),
        @fromBackingInt(@intCast(4)),
        @fromBackingInt(@intCast(5)),
        @fromBackingInt(@intCast(6)),
        @fromBackingInt(@intCast(7)),
        @fromBackingInt(@intCast(8)),
    };

    for (justifies, widths, child_ids) |justify, width, id| {
        var child = leafStyle();
        child.position = .absolute;
        child.grid_justify_self = justify;
        child.size = .{
            .width = .{ .length = width },
            .height = .{ .length = width },
        };
        try appendLeaf(&tree, id, container_id, child, .{ .spacer = .{} });
    }

    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(100, 100, columns[0..], rows[0..]),
    );
    for (0..justifies.len) |index| {
        const id: FrameNodeId = @fromBackingInt(@intCast(@as(u32, @intCast(index + 1))));
        try tree.appendChild(container_id, id);
    }

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    for (expected_x, widths, 0..) |x, width, index| {
        const id: FrameNodeId = @fromBackingInt(@intCast(@as(u32, @intCast(index + 1))));
        try expectRelative(&tree, id, .{ .x = x, .y = 0, .w = width, .h = width });
    }
}

test "grid absolute full insets resolve percentage frame before aspect ratio" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const empty_tracks: []const style.GridTrack = &.{};

    var absolute = leafStyle();
    absolute.position = .absolute;
    absolute.aspect_ratio = 3;
    absolute.inset = .{
        .top = .{ .percent = 0.05 },
        .right = .{ .percent = 0.05 },
        .bottom = .{ .percent = 0.05 },
        .left = .{ .percent = 0.05 },
    };
    try appendLeaf(&tree, absolute_id, container_id, absolute, .{ .spacer = .{} });
    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(400, 300, empty_tracks, empty_tracks),
    );
    try tree.appendChild(container_id, absolute_id);

    try layoutContainer(&tree, container_id, .{ .width = 400, .height = 300 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 400, .h = 300 });
    try expectRelative(&tree, absolute_id, .{ .x = 20, .y = 15, .w = 360, .h = 120 });
}

test "grid negative align-content distribution preserves signed row offsets in RTL" {
    const scenarios = [_]struct {
        align_content: style.AlignContent,
        first_row_y: f32,
    }{
        .{ .align_content = .center, .first_row_y = -10 },
        .{ .align_content = .end, .first_row_y = -20 },
        .{ .align_content = .start, .first_row_y = 0 },
        .{ .align_content = .space_between, .first_row_y = 0 },
    };
    const columns = [_]style.GridTrack{
        .{ .fixed = 20 },
        .{ .fixed = 20 },
        .{ .fixed = 20 },
    };
    const rows = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };
    const empty_tracks: []const style.GridTrack = &.{};

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const inner_id: FrameNodeId = @fromBackingInt(@intCast(10));
        const outer_id: FrameNodeId = @fromBackingInt(@intCast(11));

        for (1..10) |child_number| {
            const child_id: FrameNodeId = @fromBackingInt(@intCast(@as(u32, @intCast(child_number))));
            var child = leafStyle();
            child.writing_direction = .rtl;
            try appendLeaf(&tree, child_id, inner_id, child, .{ .spacer = .{} });
        }

        var inner = fixedContainer(120, 120, columns[0..], rows[0..]);
        inner.writing_direction = .rtl;
        inner.column_gap = .{ .length = 10 };
        inner.row_gap = .{ .length = 10 };
        inner.grid_align_content = scenario.align_content;
        inner.grid_justify_content = .center;
        try appendContainer(&tree, inner_id, outer_id, inner);
        for (1..10) |child_number| {
            const child_id: FrameNodeId = @fromBackingInt(@intCast(@as(u32, @intCast(child_number))));
            try tree.appendChild(inner_id, child_id);
        }

        var outer = fixedContainer(240, 240, empty_tracks, empty_tracks);
        outer.box_sizing = .content_box;
        outer.writing_direction = .rtl;
        outer.border_inset = .{
            .top = .{ .length = 60 },
            .right = .{ .length = 60 },
            .bottom = .{ .length = 60 },
            .left = .{ .length = 60 },
        };
        outer.grid_justify_content = .start;
        outer.grid_align_content = .start;
        outer.grid_justify_items = .start;
        outer.grid_align_items = .start;
        try appendContainer(&tree, outer_id, .root, outer);
        try tree.appendChild(outer_id, inner_id);

        try layoutContainer(&tree, outer_id, .{ .width = 360, .height = 360 }, null);

        try expectRelative(&tree, outer_id, .{ .x = 0, .y = 0, .w = 360, .h = 360 });
        try expectRelative(&tree, inner_id, .{ .x = 120, .y = 0, .w = 120, .h = 120 });
        for (1..10) |child_number| {
            const child_id: FrameNodeId = @fromBackingInt(@intCast(@as(u32, @intCast(child_number))));
            const child_index = child_number - 1;
            const row_index = child_index / 3;
            const column_index = child_index % 3;
            const row_offset_px = row_index * 50;
            std.debug.assert(row_offset_px <= 100);
            const row_offset_f64: f64 = @floatFromInt(row_offset_px);
            const row_offset_f32: f32 = @floatCast(row_offset_f64);
            const expected_y = scenario.first_row_y + row_offset_f32;
            const column_offset_px = column_index * 30;
            std.debug.assert(column_offset_px <= 60);
            const column_position_f64: f64 = @floatFromInt(80 - column_offset_px);
            const expected_x: f32 = @floatCast(column_position_f64);
            try expectRelative(&tree, child_id, .{
                .x = expected_x,
                .y = expected_y,
                .w = 20,
                .h = 40,
            });
        }
    }
}

test "grid baseline propagation keeps simple RTL rows on their shared grid" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{.{ .fixed = 50 }};
    const empty_rows: []const style.GridTrack = &.{};

    var first = leafStyle();
    first.writing_direction = .rtl;
    first.size = .{
        .width = .{ .length = 50 },
        .height = .{ .length = 50 },
    };
    try appendLeaf(&tree, first_id, container_id, first, .{ .spacer = .{} });

    var second = leafStyle();
    second.writing_direction = .rtl;
    second.size = .{
        .width = .{ .length = 50 },
        .height = .{ .length = 20 },
    };
    try appendLeaf(&tree, second_id, container_id, second, .{ .spacer = .{} });

    var container = fixedContainer(100, 100, columns[0..], empty_rows);
    container.writing_direction = .rtl;
    container.grid_align_items = .baseline;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, first_id, .{ .x = 50, .y = 0, .w = 50, .h = 50 });
    try expectRelative(&tree, second_id, .{ .x = 50, .y = 65, .w = 50, .h = 20 });
}

test "grid safe and unsafe align-self control oversized item overflow" {
    const scenarios = [_]struct {
        align_self: style.AlignSelf,
        expected_y: f32,
    }{
        .{ .align_self = .safe_end, .expected_y = 0 },
        .{ .align_self = .unsafe_end, .expected_y = -50 },
    };
    const columns = [_]style.GridTrack{.{ .fixed = 100 }};
    const rows = [_]style.GridTrack{.{ .fixed = 100 }};

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
        const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
        var child = leafStyle();
        child.size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 150 },
        };
        child.grid_align_self = scenario.align_self;
        try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{} });

        var container = fixedContainer(100, 100, columns[0..], rows[0..]);
        container.grid_justify_content = .start;
        container.grid_align_content = .start;
        container.grid_justify_items = .start;
        container.grid_align_items = .start;
        try appendContainer(&tree, container_id, .root, container);
        try tree.appendChild(container_id, child_id);

        try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 }, null);

        try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
        try expectRelative(
            &tree,
            child_id,
            .{ .x = 0, .y = scenario.expected_y, .w = 50, .h = 150 },
        );
    }
}

test "grid definite percentage column gap expands max-content span tracks" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const container_id: FrameNodeId = @fromBackingInt(@intCast(10));
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .max_content,
        .max_content,
    };
    const rows = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };

    for (0..9) |index| {
        const id: FrameNodeId = @fromBackingInt(@intCast(@as(u32, @intCast(index + 1))));
        var child = leafStyle();
        if (index == 1) {
            child.grid_column.start = .{ .span = 2 };
        }
        const kind: WidgetKind = if (index == 1)
            .{ .spacer = .{ .size = 60 } }
        else
            .{ .spacer = .{} };
        try appendLeaf(&tree, id, container_id, child, kind);
    }

    var container = fixedContainer(100, 120, columns[0..], rows[0..]);
    container.column_gap = .{ .percent = 0.2 };
    container.row_gap = .{ .length = 0 };
    try appendContainer(&tree, container_id, .root, container);
    for (0..9) |index| {
        const id: FrameNodeId = @fromBackingInt(@intCast(@as(u32, @intCast(index + 1))));
        try tree.appendChild(container_id, id);
    }

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 120 }, null);

    const expected = [_]Rect{
        .{ .x = 0, .y = 0, .w = 100, .h = 120 },
        .{ .x = 0, .y = 0, .w = 40, .h = 40 },
        .{ .x = 60, .y = 0, .w = 60, .h = 40 },
        .{ .x = 0, .y = 40, .w = 40, .h = 40 },
        .{ .x = 60, .y = 40, .w = 20, .h = 40 },
        .{ .x = 100, .y = 40, .w = 20, .h = 40 },
        .{ .x = 0, .y = 80, .w = 40, .h = 40 },
        .{ .x = 60, .y = 80, .w = 20, .h = 40 },
        .{ .x = 100, .y = 80, .w = 20, .h = 40 },
        .{ .x = 0, .y = 120, .w = 40, .h = 0 },
    };
    try expectRelative(&tree, container_id, expected[0]);
    for (1..10) |index| {
        const id: FrameNodeId = @fromBackingInt(@intCast(@as(u32, @intCast(index))));
        try expectRelative(&tree, id, expected[index]);
    }
}

test "grid indefinite percentage gap stays zero intrinsically then resolves at final width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const container_id: FrameNodeId = @fromBackingInt(@intCast(10));
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .max_content,
        .max_content,
    };
    const rows = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };

    for (0..9) |index| {
        const id: FrameNodeId = @fromBackingInt(@intCast(@as(u32, @intCast(index + 1))));
        var child = leafStyle();
        if (index == 1) {
            child.grid_column.start = .{ .span = 2 };
        }
        const kind: WidgetKind = if (index == 1)
            .{ .spacer = .{ .size = 60 } }
        else
            .{ .spacer = .{} };
        try appendLeaf(&tree, id, container_id, child, kind);
    }

    var container = fixedContainer(0, 0, columns[0..], rows[0..]);
    container.size = .{ .width = .auto, .height = .auto };
    container.column_gap = .{ .percent = 0.2 };
    container.row_gap = .{ .length = 0 };
    try appendContainer(&tree, container_id, .root, container);
    for (0..9) |index| {
        const id: FrameNodeId = @fromBackingInt(@intCast(@as(u32, @intCast(index + 1))));
        try tree.appendChild(container_id, id);
    }

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 120 }, null);

    const expected = [_]Rect{
        .{ .x = 0, .y = 0, .w = 100, .h = 120 },
        .{ .x = 0, .y = 0, .w = 40, .h = 40 },
        .{ .x = 60, .y = 0, .w = 60, .h = 40 },
        .{ .x = 0, .y = 40, .w = 40, .h = 40 },
        .{ .x = 60, .y = 40, .w = 20, .h = 40 },
        .{ .x = 100, .y = 40, .w = 20, .h = 40 },
        .{ .x = 0, .y = 80, .w = 40, .h = 40 },
        .{ .x = 60, .y = 80, .w = 20, .h = 40 },
        .{ .x = 100, .y = 80, .w = 20, .h = 40 },
        .{ .x = 0, .y = 120, .w = 40, .h = 0 },
    };
    try expectRelative(&tree, container_id, expected[0]);
    for (1..10) |index| {
        const id: FrameNodeId = @fromBackingInt(@intCast(@as(u32, @intCast(index))));
        try expectRelative(&tree, id, expected[index]);
    }
}

test "grid prepended implicit auto track stretches before explicit track" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const auto_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const explicit_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{.{ .fixed = 20 }};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var auto_item = leafStyle();
    auto_item.size = .{
        .width = .{ .length = 10 },
        .height = .{ .length = 20 },
    };
    auto_item.grid_column = .{
        .start = .{ .line = -3 },
        .end = .auto,
    };
    auto_item.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(&tree, auto_id, container_id, auto_item, .{ .spacer = .{ .size = 10 } });

    var explicit_item = leafStyle();
    explicit_item.size = .{
        .width = .{ .length = 20 },
        .height = .{ .length = 20 },
    };
    explicit_item.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    explicit_item.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(&tree, explicit_id, container_id, explicit_item, .{ .spacer = .{} });

    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(100, 20, columns[0..], rows[0..]),
    );
    try tree.appendChild(container_id, auto_id);
    try tree.appendChild(container_id, explicit_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 20 }, null);

    try expectRelative(&tree, auto_id, .{ .x = 0, .y = 0, .w = 10, .h = 20 });
    try expectRelative(&tree, explicit_id, .{ .x = 80, .y = 0, .w = 20, .h = 20 });
}

test "grid RTL start uses container edge while self-start uses child edge" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const start_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const self_start_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{.{ .fixed = 100 }};
    const rows = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };

    var start = leafStyle();
    start.writing_direction = .ltr;
    start.size = .{
        .width = .{ .length = 20 },
        .height = .{ .length = 20 },
    };
    start.grid_justify_self = .start;
    start.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    start.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(&tree, start_id, container_id, start, .{ .spacer = .{} });

    var self_start = leafStyle();
    self_start.writing_direction = .ltr;
    self_start.size = .{
        .width = .{ .length = 20 },
        .height = .{ .length = 20 },
    };
    self_start.grid_justify_self = .self_start;
    self_start.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    self_start.grid_row = .{
        .start = .{ .line = 2 },
        .end = .{ .line = 3 },
    };
    try appendLeaf(&tree, self_start_id, container_id, self_start, .{ .spacer = .{} });

    var container = fixedContainer(100, 40, columns[0..], rows[0..]);
    container.writing_direction = .rtl;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, start_id);
    try tree.appendChild(container_id, self_start_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 40 }, null);

    try expectRelative(&tree, start_id, .{ .x = 80, .y = 0, .w = 20, .h = 20 });
    try expectRelative(&tree, self_start_id, .{ .x = 0, .y = 20, .w = 20, .h = 20 });
}

test "grid RTL absolute start and end use container edges" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const start_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const end_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{.{ .fixed = 100 }};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};
    const auto_insets: style.Insets = .{
        .top = .auto,
        .right = .auto,
        .bottom = .auto,
        .left = .auto,
    };

    var start = leafStyle();
    start.position = .absolute;
    start.writing_direction = .ltr;
    start.size = .{
        .width = .{ .length = 20 },
        .height = .{ .length = 20 },
    };
    start.inset = auto_insets;
    start.grid_justify_self = .start;
    try appendLeaf(&tree, start_id, container_id, start, .{ .spacer = .{} });

    var end = leafStyle();
    end.position = .absolute;
    end.writing_direction = .ltr;
    end.size = .{
        .width = .{ .length = 20 },
        .height = .{ .length = 20 },
    };
    end.inset = auto_insets;
    end.grid_justify_self = .end;
    try appendLeaf(&tree, end_id, container_id, end, .{ .spacer = .{} });

    var container = fixedContainer(100, 20, columns[0..], rows[0..]);
    container.writing_direction = .rtl;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, start_id);
    try tree.appendChild(container_id, end_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 20 }, null);

    try expectRelative(&tree, start_id, .{ .x = 80, .y = 0, .w = 20, .h = 20 });
    try expectRelative(&tree, end_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
}

test "grid absolute intrinsic auto size is excluded from default stretch" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fixed = 100 }};
    const rows = [_]style.GridTrack{.{ .fixed = 100 }};

    var child = leafStyle();
    child.position = .absolute;
    child.inset = .{
        .top = .auto,
        .right = .auto,
        .bottom = .auto,
        .left = .auto,
    };
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{ .size = 20 } });

    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(100, 100, columns[0..], rows[0..]),
    );
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 }, null);

    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
}

test "grid absolute aspect ratio resolves height before opposing insets" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fixed = 100 }};
    const rows = [_]style.GridTrack{.{ .fixed = 200 }};

    var child = leafStyle();
    child.position = .absolute;
    child.aspect_ratio = 2;
    child.size = .{
        .width = .{ .length = 100 },
        .height = .auto,
    };
    child.inset = .{
        .top = .{ .length = 0 },
        .right = .auto,
        .bottom = .{ .length = 0 },
        .left = .auto,
    };
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{ .size = 20 } });

    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(100, 200, columns[0..], rows[0..]),
    );
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 200 }, null);

    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 100, .h = 50 });
}
test "grid absolute aspect ratio derives width from definite height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fixed = 100 }};
    const rows = [_]style.GridTrack{.{ .fixed = 200 }};

    var child = leafStyle();
    child.position = .absolute;
    child.aspect_ratio = 2;
    child.size = .{
        .width = .auto,
        .height = .{ .length = 50 },
    };
    child.inset = .{
        .top = .{ .length = 0 },
        .right = .auto,
        .bottom = .{ .length = 0 },
        .left = .auto,
    };
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{ .size = 20 } });

    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(100, 200, columns[0..], rows[0..]),
    );
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 200 }, null);

    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 100, .h = 50 });
}

test "grid absolute auto margins do not shift inset-positioned item" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fixed = 100 }};
    const rows = [_]style.GridTrack{.{ .fixed = 100 }};

    var child = leafStyle();
    child.position = .absolute;
    child.size = .{
        .width = .{ .length = 20 },
        .height = .{ .length = 20 },
    };
    child.inset = .{
        .top = .{ .length = 0 },
        .right = .{ .length = 20 },
        .bottom = .auto,
        .left = .{ .length = 10 },
    };
    child.margin_inset = .{
        .top = .{ .length = 0 },
        .right = .auto,
        .bottom = .{ .length = 0 },
        .left = .auto,
    };
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{ .size = 20 } });

    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(100, 100, columns[0..], rows[0..]),
    );
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 }, null);

    try expectRelative(&tree, child_id, .{ .x = 10, .y = 0, .w = 20, .h = 20 });
}

test "grid cyclic percentage row gap resolves after intrinsic auto height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{.{ .fixed = 100 }};
    const rows = [_]style.GridTrack{ .{ .fixed = 40 }, .{ .fixed = 40 } };

    var first = leafStyle();
    first.size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 40 },
    };
    try appendLeaf(&tree, first_id, container_id, first, .{ .spacer = .{ .size = 40 } });

    var second = leafStyle();
    second.size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 40 },
    };
    try appendLeaf(&tree, second_id, container_id, second, .{ .spacer = .{ .size = 40 } });

    var container = fixedContainer(100, 0, columns[0..], rows[0..]);
    container.size.height = .auto;
    container.row_gap = .{ .percent = 0.1 };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 200 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 80 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 100, .h = 40 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 48, .w = 100, .h = 40 });
}

test "definite Grid availability does not define an auto percentage axis" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{.{ .fixed = 10 }};
    const rows = [_]style.GridTrack{ .{ .fixed = 10 }, .{ .fixed = 10 } };

    try appendLeaf(&tree, first_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, second_id, container_id, leafStyle(), .{ .spacer = .{} });

    var container = fixedContainer(10, 0, columns[0..], rows[0..]);
    container.size.height = .auto;
    container.row_gap = .{ .percent = 0.5 };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = null,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();

    const measured = try grid.measureNatural(
        &tree,
        tree.nodeConst(container_id) orelse return error.TestUnexpectedResult,
        .{
            .available = .{ .width = 10, .height = 200 },
            .percentage_basis = .{ .width = 10, .height = null },
            .height_mode = .definite,
        },
        &context,
    );

    // Definite availability constrains auto height; it does not provide the
    // percentage basis needed to resolve the cyclic 50% gap.
    try std.testing.expectEqual(@as(f32, 20), measured.content.height);
    try std.testing.expectEqual(@as(f32, 20), measured.border.height);
}

test "grid bounded occupancy lays out a two by ten-thousand definite span" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const definite_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const auto_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns: [10_000]style.GridTrack = @splat(.{ .fixed = 1 });
    const rows = [_]style.GridTrack{ .{ .fixed = 1 }, .{ .fixed = 1 } };

    var definite = leafStyle();
    definite.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 10001 },
    };
    definite.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 3 },
    };
    try appendLeaf(&tree, definite_id, container_id, definite, .{ .spacer = .{} });
    try appendLeaf(&tree, auto_id, container_id, leafStyle(), .{ .spacer = .{} });

    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(10_000, 2, columns[0..], rows[0..]),
    );
    try tree.appendChild(container_id, definite_id);
    try tree.appendChild(container_id, auto_id);

    try layoutContainer(&tree, container_id, .{ .width = 10_000, .height = 2 }, null);

    // The 20,000-cell definite area remains bounded and finite. Row-major
    // auto-placement wraps to the first column of the implicit third row.
    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 10_000, .h = 2 });
    try expectRelative(&tree, definite_id, .{ .x = 0, .y = 0, .w = 10_000, .h = 2 });
    try expectRelative(&tree, auto_id, .{ .x = 0, .y = 2, .w = 1, .h = 0 });
}

test "grid sparse occupancy jumps past collision rectangles" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_blocker_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_blocker_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const spanning_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const columns: [5_000]style.GridTrack = @splat(.{ .fixed = 1 });
    const rows = [_]style.GridTrack{
        .{ .fixed = 1 },
        .{ .fixed = 1 },
        .{ .fixed = 1 },
    };

    var first_blocker = leafStyle();
    first_blocker.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    first_blocker.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(
        &tree,
        first_blocker_id,
        container_id,
        first_blocker,
        .{ .spacer = .{} },
    );

    var second_blocker = leafStyle();
    second_blocker.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    second_blocker.grid_row = .{
        .start = .{ .line = 2 },
        .end = .{ .line = 3 },
    };
    try appendLeaf(
        &tree,
        second_blocker_id,
        container_id,
        second_blocker,
        .{ .spacer = .{} },
    );

    var spanning = leafStyle();
    spanning.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 5001 },
    };
    try appendLeaf(&tree, spanning_id, container_id, spanning, .{ .spacer = .{} });

    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(5_000, 3, columns[0..], rows[0..]),
    );
    try tree.appendChild(container_id, first_blocker_id);
    try tree.appendChild(container_id, second_blocker_id);
    try tree.appendChild(container_id, spanning_id);

    try layoutContainer(&tree, container_id, .{ .width = 5_000, .height = 3 }, null);

    try expectRelative(&tree, spanning_id, .{ .x = 0, .y = 2, .w = 5_000, .h = 1 });
}

test "grid phase three pre-sizes implicit columns before auto placement" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const spanning_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };
    const rows: []const style.GridTrack = &.{};
    const auto_columns = [_]style.GridTrack{.{ .fixed = 20 }};
    const auto_rows = [_]style.GridTrack{.{ .fixed = 20 }};

    try appendLeaf(&tree, first_id, container_id, leafStyle(), .{ .spacer = .{} });

    var spanning = leafStyle();
    spanning.grid_column = .{
        .start = .{ .span = 3 },
        .end = .auto,
    };
    try appendLeaf(&tree, spanning_id, container_id, spanning, .{ .spacer = .{} });

    var container = fixedContainer(60, 40, columns[0..], rows);
    container.grid_auto_columns = auto_columns[0..];
    container.grid_auto_rows = auto_rows[0..];
    container.grid_auto_flow = .row;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, spanning_id);

    try layoutContainer(&tree, container_id, .{ .width = 60, .height = 40 }, null);

    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
    try expectRelative(&tree, spanning_id, .{ .x = 0, .y = 20, .w = 60, .h = 20 });
}

test "grid sparse phase two resets column cursor for each definite row" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };
    const rows = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };

    var first = leafStyle();
    first.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(&tree, first_id, container_id, first, .{ .spacer = .{} });

    var second = leafStyle();
    second.grid_row = .{
        .start = .{ .line = 2 },
        .end = .{ .line = 3 },
    };
    try appendLeaf(&tree, second_id, container_id, second, .{ .spacer = .{} });

    var container = fixedContainer(40, 40, columns[0..], rows[0..]);
    container.grid_auto_flow = .row;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 40, .height = 40 }, null);

    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 20, .w = 20, .h = 20 });
}

test "grid absolute explicit stretch preserves intrinsic auto size" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fixed = 100 }};
    const rows = [_]style.GridTrack{.{ .fixed = 100 }};

    var child = leafStyle();
    child.position = .absolute;
    child.size = .{ .width = .auto, .height = .auto };
    child.inset = .{
        .top = .auto,
        .right = .auto,
        .bottom = .auto,
        .left = .auto,
    };
    child.grid_justify_self = .stretch;
    child.grid_align_self = .stretch;
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{ .size = 20 } });

    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(100, 100, columns[0..], rows[0..]),
    );
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 }, null);

    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
}

test "grid RTL absolute static position uses padding box end" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fixed = 100 }};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var child = leafStyle();
    child.position = .absolute;
    child.size = .{ .width = .auto, .height = .auto };
    child.grid_justify_self = .auto;
    child.grid_align_self = .auto;
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{ .size = 20 } });

    var container = fixedContainer(120, 20, columns[0..], rows[0..]);
    container.writing_direction = .rtl;
    container.padding_inset = .{
        .top = .{ .length = 0 },
        .right = .{ .length = 20 },
        .bottom = .{ .length = 0 },
        .left = .{ .length = 0 },
    };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 120, .height = 20 }, null);

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 120, .h = 20 });
    try expectRelative(&tree, child_id, .{ .x = 100, .y = 0, .w = 20, .h = 20 });
}

test "grid sparse phase two advances every spanned row cursor" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const blocker_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const spanning_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const later_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const columns = [_]style.GridTrack{
        .{ .fixed = 20 },
        .{ .fixed = 20 },
        .{ .fixed = 20 },
    };
    const rows = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };

    var blocker = leafStyle();
    blocker.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    blocker.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(&tree, blocker_id, container_id, blocker, .{ .spacer = .{} });

    var spanning = leafStyle();
    spanning.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 3 },
    };
    try appendLeaf(&tree, spanning_id, container_id, spanning, .{ .spacer = .{} });

    var later = leafStyle();
    later.grid_row = .{
        .start = .{ .line = 2 },
        .end = .{ .line = 3 },
    };
    try appendLeaf(&tree, later_id, container_id, later, .{ .spacer = .{} });

    var container = fixedContainer(60, 40, columns[0..], rows[0..]);
    container.grid_auto_flow = .row;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, blocker_id);
    try tree.appendChild(container_id, spanning_id);
    try tree.appendChild(container_id, later_id);

    try layoutContainer(&tree, container_id, .{ .width = 60, .height = 40 }, null);

    try expectRelative(&tree, blocker_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
    try expectRelative(&tree, spanning_id, .{ .x = 20, .y = 0, .w = 20, .h = 40 });
    try expectRelative(&tree, later_id, .{ .x = 40, .y = 20, .w = 20, .h = 20 });
}

test "grid sparse phase four wraps decreasing definite columns" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const later_column_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const earlier_column_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{
        .{ .fixed = 20 },
        .{ .fixed = 20 },
        .{ .fixed = 20 },
    };
    const rows = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };

    var later_column = leafStyle();
    later_column.grid_column = .{
        .start = .{ .line = 3 },
        .end = .{ .line = 4 },
    };
    try appendLeaf(
        &tree,
        later_column_id,
        container_id,
        later_column,
        .{ .spacer = .{} },
    );

    var earlier_column = leafStyle();
    earlier_column.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(
        &tree,
        earlier_column_id,
        container_id,
        earlier_column,
        .{ .spacer = .{} },
    );

    var container = fixedContainer(60, 40, columns[0..], rows[0..]);
    container.grid_auto_flow = .row;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, later_column_id);
    try tree.appendChild(container_id, earlier_column_id);

    try layoutContainer(&tree, container_id, .{ .width = 60, .height = 40 }, null);

    try expectRelative(&tree, later_column_id, .{ .x = 40, .y = 0, .w = 20, .h = 20 });
    try expectRelative(&tree, earlier_column_id, .{ .x = 0, .y = 20, .w = 20, .h = 20 });
}

test "grid contribution phases separate minima and growth limits across fit and flex span" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const growth_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const fit_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const spanning_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const first_marker_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const second_marker_id: FrameNodeId = @fromBackingInt(@intCast(5));
    const third_marker_id: FrameNodeId = @fromBackingInt(@intCast(6));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(7));
    const columns = [_]style.GridTrack{
        .{ .minmax = .{
            .min = .auto,
            .max = .max_content,
        } },
        .{ .fit_content = .{ .length = 30 } },
        .{ .fr = 1 },
    };
    const rows = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };

    var growth_item = leafStyle();
    growth_item.size.height = .{ .length = 20 };
    growth_item.min_size.width = .{ .length = 0 };
    growth_item.grid_justify_self = .start;
    growth_item.grid_align_self = .start;
    growth_item.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    growth_item.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(
        &tree,
        growth_id,
        container_id,
        growth_item,
        .{ .spacer = .{ .size = 80 } },
    );

    var fit_item = leafStyle();
    fit_item.size.height = .{ .length = 20 };
    fit_item.min_size.width = .{ .length = 0 };
    fit_item.grid_justify_self = .start;
    fit_item.grid_align_self = .start;
    fit_item.grid_column = .{
        .start = .{ .line = 2 },
        .end = .{ .line = 3 },
    };
    fit_item.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(
        &tree,
        fit_id,
        container_id,
        fit_item,
        .{ .spacer = .{ .size = 20 } },
    );

    var spanning_item = leafStyle();
    spanning_item.size.height = .{ .length = 20 };
    spanning_item.min_size.width = .{ .length = 20 };
    spanning_item.grid_justify_self = .start;
    spanning_item.grid_align_self = .start;
    spanning_item.grid_column = .{
        .start = .{ .line = 2 },
        .end = .{ .line = 4 },
    };
    spanning_item.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(
        &tree,
        spanning_id,
        container_id,
        spanning_item,
        .{ .spacer = .{ .size = 70 } },
    );

    const marker_ids = [_]FrameNodeId{ first_marker_id, second_marker_id, third_marker_id };
    for (marker_ids, 0..) |marker_id, index| {
        var marker = leafStyle();
        marker.grid_column = .{
            .start = .{ .line = @intCast(index + 1) },
            .end = .{ .line = @intCast(index + 2) },
        };
        marker.grid_row = .{
            .start = .{ .line = 2 },
            .end = .{ .line = 3 },
        };
        try appendLeaf(&tree, marker_id, container_id, marker, .{ .spacer = .{} });
    }

    var container = fixedContainer(100, 40, columns[0..], rows[0..]);
    container.grid_justify_content = .start;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, growth_id);
    try tree.appendChild(container_id, fit_id);
    try tree.appendChild(container_id, spanning_id);
    for (marker_ids) |marker_id| try tree.appendChild(container_id, marker_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 40 }, null);

    // The first item has a zero minimum and an 80px min/max-content contribution.
    // The fit track has a 20px min/max-content contribution and a 30px fit-content cap.
    // The spanning item has a 20px minimum and a 70px min-content contribution.
    // These values must be applied in separate base-size and growth-limit phases.
    try expectRelative(&tree, growth_id, .{ .x = 0, .y = 0, .w = 80, .h = 20 });
    try expectRelative(&tree, fit_id, .{ .x = 60, .y = 0, .w = 20, .h = 20 });
    try expectRelative(&tree, spanning_id, .{ .x = 60, .y = 0, .w = 70, .h = 20 });
    try expectRelative(
        &tree,
        first_marker_id,
        .{ .x = 0, .y = 20, .w = 60, .h = 20 },
    );
    try expectRelative(
        &tree,
        second_marker_id,
        .{ .x = 60, .y = 20, .w = 20, .h = 20 },
    );
    try expectRelative(
        &tree,
        third_marker_id,
        .{ .x = 80, .y = 20, .w = 20, .h = 20 },
    );
}

test "grid auto-fit repeat collapses empty track and adjacent gutter" {
    const repeated_track = [_]style.GridTrack{.{ .fixed = 40 }};
    const auto_fill_columns = [_]style.GridTrack{
        .{ .repeat = .{
            .kind = .auto_fill,
            .tracks = repeated_track[0..],
        } },
    };
    const auto_fit_columns = [_]style.GridTrack{
        .{ .repeat = .{
            .kind = .auto_fit,
            .tracks = repeated_track[0..],
        } },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};
    const scenarios = [_]struct {
        columns: []const style.GridTrack,
        trailing_x: f32,
    }{
        .{ .columns = auto_fill_columns[0..], .trailing_x = 100 },
        .{ .columns = auto_fit_columns[0..], .trailing_x = 50 },
    };

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
        const trailing_id: FrameNodeId = @fromBackingInt(@intCast(2));
        const container_id: FrameNodeId = @fromBackingInt(@intCast(3));

        var first = leafStyle();
        first.grid_column = .{
            .start = .{ .line = 1 },
            .end = .{ .line = 2 },
        };
        first.grid_row = .{
            .start = .{ .line = 1 },
            .end = .{ .line = 2 },
        };
        try appendLeaf(&tree, first_id, container_id, first, .{ .spacer = .{} });

        var trailing = leafStyle();
        trailing.grid_column = .{
            .start = .{ .line = 3 },
            .end = .{ .line = 4 },
        };
        trailing.grid_row = .{
            .start = .{ .line = 1 },
            .end = .{ .line = 2 },
        };
        try appendLeaf(&tree, trailing_id, container_id, trailing, .{ .spacer = .{} });

        var container = fixedContainer(140, 20, scenario.columns, rows[0..]);
        container.column_gap = .{ .length = 10 };
        container.grid_justify_content = .start;
        try appendContainer(&tree, container_id, .root, container);
        try tree.appendChild(container_id, first_id);
        try tree.appendChild(container_id, trailing_id);
        try layoutContainer(&tree, container_id, .{ .width = 140, .height = 20 }, null);

        // Auto-fill retains the empty middle track and both gutters.
        // Auto-fit collapses that track and its adjacent gutters.
        try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 40, .h = 20 });
        try expectRelative(
            &tree,
            trailing_id,
            .{ .x = scenario.trailing_x, .y = 0, .w = 40, .h = 20 },
        );
    }
}

test "grid cyclic implicit list representation gap preserves source order on both sides" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const negative_ids = [_]FrameNodeId{
        @fromBackingInt(@intCast(1)),
        @fromBackingInt(@intCast(2)),
        @fromBackingInt(@intCast(3)),
    };
    const explicit_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const positive_ids = [_]FrameNodeId{
        @fromBackingInt(@intCast(5)),
        @fromBackingInt(@intCast(6)),
        @fromBackingInt(@intCast(7)),
    };
    const container_id: FrameNodeId = @fromBackingInt(@intCast(8));
    const negative_lines = [_]i16{ -5, -4, -3 };
    const positive_lines = [_]i16{ 2, 3, 4 };
    const auto_columns = [_]style.GridTrack{
        .{ .fixed = 10 },
        .{ .fixed = 20 },
        .{ .fixed = 30 },
    };
    const explicit_columns = [_]style.GridTrack{.{ .fixed = 40 }};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    for (negative_ids, negative_lines) |id, line| {
        var child = leafStyle();
        child.grid_column = .{
            .start = .{ .line = line },
            .end = .auto,
        };
        child.grid_row = .{
            .start = .{ .line = 1 },
            .end = .{ .line = 2 },
        };
        try appendLeaf(&tree, id, container_id, child, .{ .spacer = .{} });
    }

    var explicit = leafStyle();
    explicit.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    explicit.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(&tree, explicit_id, container_id, explicit, .{ .spacer = .{} });

    for (positive_ids, positive_lines) |id, line| {
        var child = leafStyle();
        child.grid_column = .{
            .start = .{ .line = line },
            .end = .auto,
        };
        child.grid_row = .{
            .start = .{ .line = 1 },
            .end = .{ .line = 2 },
        };
        try appendLeaf(&tree, id, container_id, child, .{ .spacer = .{} });
    }

    var container = fixedContainer(160, 20, explicit_columns[0..], rows[0..]);
    container.grid_auto_columns = auto_columns[0..];
    container.grid_justify_content = .start;
    try appendContainer(&tree, container_id, .root, container);
    for (negative_ids) |id| try tree.appendChild(container_id, id);
    try tree.appendChild(container_id, explicit_id);
    for (positive_ids) |id| try tree.appendChild(container_id, id);

    try layoutContainer(&tree, container_id, .{ .width = 160, .height = 20 }, null);

    const negative_expected = [_]Rect{
        .{ .x = 0, .y = 0, .w = 10, .h = 20 },
        .{ .x = 10, .y = 0, .w = 20, .h = 20 },
        .{ .x = 30, .y = 0, .w = 30, .h = 20 },
    };
    const positive_expected = [_]Rect{
        .{ .x = 100, .y = 0, .w = 10, .h = 20 },
        .{ .x = 110, .y = 0, .w = 20, .h = 20 },
        .{ .x = 130, .y = 0, .w = 30, .h = 20 },
    };
    for (negative_ids, negative_expected) |id, expected| {
        try expectRelative(&tree, id, expected);
    }
    try expectRelative(&tree, explicit_id, .{ .x = 60, .y = 0, .w = 40, .h = 20 });
    for (positive_ids, positive_expected) |id, expected| {
        try expectRelative(&tree, id, expected);
    }
}

test "grid lays out a child beyond the 10000-track cap" {
    const track_count: usize = 10_001;
    var columns = try std.testing.allocator.alloc(style.GridTrack, track_count);
    defer std.testing.allocator.free(columns);
    for (columns) |*track| track.* = .{ .fixed = 1 };
    const rows = [_]style.GridTrack{.{ .fixed = 1 }};
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    var child = leafStyle();
    child.grid_column = .{
        .start = .{ .line = 10_001 },
        .end = .{ .line = 10_002 },
    };
    child.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{} });
    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(10_001, 1, columns[0..], rows[0..]),
    );
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 10_001, .height = 1 }, null);

    try expectRelative(&tree, child_id, .{ .x = 10_000, .y = 0, .w = 1, .h = 1 });
}

test "grid preserves representable line and span limits" {
    {
        const track_count: usize = 10_001;
        var columns = try std.testing.allocator.alloc(style.GridTrack, track_count);
        defer std.testing.allocator.free(columns);
        for (columns) |*track| track.* = .{ .fixed = 1 };
        const rows = [_]style.GridTrack{.{ .fixed = 1 }};
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
        const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
        var child = leafStyle();
        child.grid_column = .{
            .start = .{ .line = std.math.maxInt(i16) },
            .end = .auto,
        };
        child.grid_row = .{
            .start = .{ .line = 1 },
            .end = .{ .line = 2 },
        };
        try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{} });
        try appendContainer(
            &tree,
            container_id,
            .root,
            fixedContainer(10_001, 1, columns[0..], rows[0..]),
        );
        try tree.appendChild(container_id, child_id);

        try layoutContainer(&tree, container_id, .{ .width = 10_001, .height = 1 }, null);

        // The representable positive line remains distinct from the old
        // ten-thousand-track clamp.
        try expectRelative(&tree, child_id, .{ .x = 10_001, .y = 0, .w = 0, .h = 1 });
    }

    {
        const track_count: usize = 10_001;
        var columns = try std.testing.allocator.alloc(style.GridTrack, track_count);
        defer std.testing.allocator.free(columns);
        for (columns) |*track| track.* = .{ .fixed = 1 };
        const rows = [_]style.GridTrack{.{ .fixed = 1 }};
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
        const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
        var child = leafStyle();
        child.grid_column = .{
            .start = .{ .line = 1 },
            .end = .{ .span = std.math.maxInt(u16) },
        };
        child.grid_row = .{
            .start = .{ .line = 1 },
            .end = .{ .line = 2 },
        };
        try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{} });
        try appendContainer(
            &tree,
            container_id,
            .root,
            fixedContainer(10_001, 1, columns[0..], rows[0..]),
        );
        try tree.appendChild(container_id, child_id);

        try layoutContainer(&tree, container_id, .{ .width = 10_001, .height = 1 }, null);

        // The representable span keeps all explicit tracks instead of
        // saturating at the old storage boundary.
        try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 10_001, .h = 1 });
    }
}

test "grid percentage margins defer in an indefinite intrinsic axis then resolve in area" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.max_content};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var child = leafStyle();
    child.size.height = .{ .length = 20 };
    child.margin_inset = .{
        .top = .{ .length = 0 },
        .right = .{ .percent = 0.25 },
        .bottom = .{ .length = 0 },
        .left = .{ .percent = 0.25 },
    };
    child.grid_justify_self = .start;
    child.grid_align_self = .start;
    child.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    child.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{ .size = 40 } });

    var container = fixedContainer(0, 20, columns[0..], rows[0..]);
    container.size.width = .auto;
    container.grid_justify_content = .start;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 200, .height = 20 }, null);

    // Indefinite intrinsic sizing treats both percentages as zero, producing
    // a 40px area. Final layout resolves each margin to 25% of that area.
    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 40, .h = 20 });
    try expectRelative(&tree, child_id, .{ .x = 10, .y = 0, .w = 40, .h = 20 });
}

test "grid border-box leaf measurement reports content-box known width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.{ .fixed = 100 }};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var child = leafStyle();
    child.size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 20 },
    };
    child.padding_inset = .{
        .top = .{ .length = 0 },
        .right = .{ .length = 10 },
        .bottom = .{ .length = 0 },
        .left = .{ .length = 10 },
    };
    try appendLeaf(
        &tree,
        child_id,
        container_id,
        child,
        .{ .label = .{ .text = "content-box probe" } },
    );
    try appendContainer(
        &tree,
        container_id,
        .root,
        fixedContainer(100, 20, columns[0..], rows[0..]),
    );
    try tree.appendChild(container_id, child_id);

    ContentBoxMeasureProbe.reset();
    try layoutContainer(
        &tree,
        container_id,
        .{ .width = 100, .height = 20 },
        ContentBoxMeasureProbe.source,
    );

    const known_width = ContentBoxMeasureProbe.known_width orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(
        @as(f32, 80),
        known_width,
        @as(f32, 0.001),
    );
}

test "grid auto-fill reserves suffix tracks when counting repeats" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const suffix_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const repeated_tracks = [_]style.GridTrack{.{ .fixed = 20 }};
    const columns = [_]style.GridTrack{
        .{ .repeat = .{
            .kind = .auto_fill,
            .tracks = repeated_tracks[0..],
        } },
        .{ .fixed = 40 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var suffix = leafStyle();
    suffix.grid_column = .{
        .start = .{ .line = 4 },
        .end = .{ .line = 5 },
    };
    suffix.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(&tree, suffix_id, container_id, suffix, .{ .spacer = .{} });

    var container = fixedContainer(100, 20, columns[0..], rows[0..]);
    container.grid_justify_content = .start;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, suffix_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 20 }, null);

    // Three 20px repeats consume the space before the 40px suffix.
    try expectRelative(&tree, suffix_id, .{ .x = 60, .y = 0, .w = 40, .h = 20 });
}

test "grid auto-fill uses definite minmax maximum for repeat count" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const suffix_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const repeated_tracks = [_]style.GridTrack{.{ .minmax = .{
        .min = .{ .fixed = 100 },
        .max = .{ .fixed = 200 },
    } }};
    const columns = [_]style.GridTrack{
        .{ .repeat = .{
            .kind = .auto_fill,
            .tracks = repeated_tracks[0..],
        } },
        .{ .fixed = 20 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var suffix = leafStyle();
    suffix.grid_column = .{
        .start = .{ .line = 3 },
        .end = .{ .line = 4 },
    };
    suffix.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(&tree, suffix_id, container_id, suffix, .{ .spacer = .{} });

    var container = fixedContainer(500, 20, columns[0..], rows[0..]);
    container.grid_justify_content = .start;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, suffix_id);

    try layoutContainer(&tree, container_id, .{ .width = 500, .height = 20 }, null);

    // The 200px definite maximum permits two repeats before the suffix.
    try expectRelative(&tree, suffix_id, .{ .x = 400, .y = 0, .w = 20, .h = 20 });
}

test "grid auto-fill counts against a nonbinding maximum size" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const repeated_tracks = [_]style.GridTrack{.{ .fixed = 100 }};
    const columns = [_]style.GridTrack{.{ .repeat = .{
        .kind = .auto_fill,
        .tracks = repeated_tracks[0..],
    } }};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var child = leafStyle();
    child.grid_column = .{
        .start = .{ .line = -2 },
        .end = .{ .line = -1 },
    };
    child.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{} });

    var container = fixedContainer(0, 20, columns[0..], rows[0..]);
    container.size.width = .auto;
    container.max_size.width = .{ .length = 250 };
    container.grid_justify_content = .start;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 500, .height = 20 }, null);

    try expectRelative(&tree, child_id, .{ .x = 100, .y = 0, .w = 100, .h = 20 });
}

test "grid auto-fill min-only size creates repetitions that overflow minimum" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const repeated_tracks = [_]style.GridTrack{.{ .fixed = 100 }};
    const columns = [_]style.GridTrack{.{ .repeat = .{
        .kind = .auto_fill,
        .tracks = repeated_tracks[0..],
    } }};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var child = leafStyle();
    child.grid_column = .{
        .start = .{ .line = -2 },
        .end = .{ .line = -1 },
    };
    child.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{} });

    var container = fixedContainer(0, 20, columns[0..], rows[0..]);
    container.size.width = .auto;
    container.min_size.width = .{ .length = 250 };
    container.grid_justify_content = .start;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 500, .height = 20 }, null);

    // Min-only sizing uses ceil: three 100px repeats are required to exceed 250px.
    try expectRelative(&tree, child_id, .{ .x = 200, .y = 0, .w = 100, .h = 20 });
}

test "grid zero-size auto-fill uses a one-pixel repetition floor" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const repeated_tracks = [_]style.GridTrack{.{ .fixed = 0 }};
    const columns = [_]style.GridTrack{
        .{ .repeat = .{
            .kind = .auto_fill,
            .tracks = repeated_tracks[0..],
        } },
        .{ .fixed = 1 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 1 }};

    var child = leafStyle();
    child.grid_column = .{
        .start = .{ .line = 2 },
        .end = .{ .line = 3 },
    };
    child.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{} });

    var container = fixedContainer(10_000, 1, columns[0..], rows[0..]);
    container.grid_justify_content = .start;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 10_000, .height = 1 }, null);
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 0, .h = 1 });
}

test "grid negative explicit line resolves after auto-fill expansion" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const repeated_tracks = [_]style.GridTrack{.{ .fixed = 100 }};
    const columns = [_]style.GridTrack{.{ .repeat = .{
        .kind = .auto_fill,
        .tracks = repeated_tracks[0..],
    } }};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var child = leafStyle();
    child.size = .{
        .width = .{ .length = 10 },
        .height = .{ .length = 20 },
    };
    child.grid_justify_self = .start;
    child.grid_column = .{
        .start = .{ .line = -1 },
        .end = .auto,
    };
    child.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    try appendLeaf(&tree, child_id, container_id, child, .{ .spacer = .{} });

    var container = fixedContainer(500, 20, columns[0..], rows[0..]);
    container.grid_justify_content = .start;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 500, .height = 20 }, null);

    // Five 100px repeats make -1 the sixth line, at the 500px edge.
    try expectRelative(&tree, child_id, .{ .x = 500, .y = 0, .w = 10, .h = 20 });
}

test "grid direct relayout clears a subtree hidden after first layout" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var scroll_state: widget.ScrollState = .{};
    const overflowing_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const inner_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const outer_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const inner_columns = [_]style.GridTrack{.{ .fixed = 40 }};
    const inner_rows = [_]style.GridTrack{.{ .fixed = 20 }};
    const outer_columns = [_]style.GridTrack{.{ .fixed = 80 }};
    const outer_rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var overflowing = leafStyle();
    overflowing.size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 20 },
    };
    try appendLeaf(
        &tree,
        overflowing_id,
        inner_id,
        overflowing,
        .{ .spacer = .{} },
    );

    var inner = fixedContainer(40, 20, inner_columns[0..], inner_rows[0..]);
    inner.overflow.width = .scroll;
    inner.scrollbar_width = 10;
    try appendContainer(&tree, inner_id, outer_id, inner);
    {
        const inner_node = tree.node(inner_id) orelse return error.TestUnexpectedResult;
        inner_node.scroll = .{
            .state = &scroll_state,
            .axis = .horizontal,
        };
    }
    try tree.appendChild(inner_id, overflowing_id);

    try appendContainer(
        &tree,
        outer_id,
        .root,
        fixedContainer(80, 20, outer_columns[0..], outer_rows[0..]),
    );
    try tree.appendChild(outer_id, inner_id);

    try layoutContainer(&tree, outer_id, .{ .width = 80, .height = 20 }, null);

    {
        const inner_node_after_first_layout =
            tree.nodeConst(inner_id) orelse return error.TestUnexpectedResult;
        try std.testing.expect(inner_node_after_first_layout.resolved_box_edges != null);
        try std.testing.expect(inner_node_after_first_layout.layout_content_size.width > 0);
        try std.testing.expect(inner_node_after_first_layout.first_baseline != null);
    }
    try std.testing.expect(scroll_state.max_offset[0] > 0);

    {
        const inner_node_before_hidden_layout =
            tree.node(inner_id) orelse return error.TestUnexpectedResult;
        inner_node_before_hidden_layout.style.display = .none;
    }
    try layoutContainer(&tree, outer_id, .{ .width = 80, .height = 20 }, null);

    try expectRelative(&tree, inner_id, .{});
    try expectRelative(&tree, overflowing_id, .{});
    {
        const inner_node_after_hidden_layout =
            tree.nodeConst(inner_id) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(
            widget.Size{ .width = 0, .height = 0 },
            inner_node_after_hidden_layout.layout_content_size,
        );
        try std.testing.expectEqual(
            @as(?widget.ResolvedBoxEdges, null),
            inner_node_after_hidden_layout.resolved_box_edges,
        );
        try std.testing.expectEqual(
            @as(?f32, null),
            inner_node_after_hidden_layout.first_baseline,
        );
    }
    try std.testing.expectEqual([2]f32{ 0, 0 }, scroll_state.max_offset);
}

test "grid nested intrinsic measurement stays within finite mode bound" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const nesting_depth: usize = 6;
    const leaf_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const columns = [_]style.GridTrack{.{ .fixed = 10 }};
    const rows = [_]style.GridTrack{.{ .fixed = 10 }};

    try appendLeaf(
        &tree,
        leaf_id,
        @fromBackingInt(@intCast(2)),
        leafStyle(),
        .{ .label = .{ .text = "nested intrinsic probe" } },
    );

    var child_id = leaf_id;
    for (0..nesting_depth) |level| {
        const grid_id: FrameNodeId = @fromBackingInt(@intCast(@as(u32, @intCast(level + 2))));
        const parent_id: FrameNodeId = if (level + 1 == nesting_depth)
            .root
        else
            @fromBackingInt(@intCast(@as(u32, @intCast(level + 3))));
        const is_outer = level + 1 == nesting_depth;
        var grid_style = if (is_outer)
            fixedContainer(100, 20, columns[0..], rows[0..])
        else
            fixedContainer(10, 10, columns[0..], rows[0..]);
        if (!is_outer) {
            grid_style.size = .{ .width = .auto, .height = .auto };
        }
        grid_style.grid_justify_content = .start;
        grid_style.grid_align_content = .start;
        try appendContainer(&tree, grid_id, parent_id, grid_style);
        try tree.appendChild(grid_id, child_id);
        child_id = grid_id;
    }

    NestedMeasureCounter.reset();
    try layoutContainer(
        &tree,
        child_id,
        .{ .width = 100, .height = 20 },
        .{ .callback = NestedMeasureCounter.measure },
    );

    const request_mode_count: usize = 3 * 3;
    const leaf_queries_per_request: usize = 5;
    const callback_limit = tree.nodes.items.len * request_mode_count * leaf_queries_per_request;
    try std.testing.expect(NestedMeasureCounter.calls <= callback_limit);
}

test "grid content sizing ignores root constraints and stays on the target" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const columns = [_]style.GridTrack{.max_content};
    const rows = [_]style.GridTrack{.max_content};

    try appendLeaf(
        &tree,
        child_id,
        container_id,
        leafStyle(),
        .{ .label = .{ .text = "content child" } },
    );

    var container = fixedContainer(200, 100, columns[0..], rows[0..]);
    container.min_size = .{
        .width = .{ .length = 150 },
        .height = .{ .length = 150 },
    };
    container.max_size = .{
        .width = .{ .length = 300 },
        .height = .{ .length = 300 },
    };
    container.aspect_ratio = 3;
    container.padding_inset = .{
        .top = .{ .length = 4 },
        .right = .{ .length = 4 },
        .bottom = .{ .length = 4 },
        .left = .{ .length = 4 },
    };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, child_id);

    ContentRootChildProbe.reset();
    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = ContentRootChildProbe.source,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();

    const measured = try grid.measureNatural(
        &tree,
        tree.nodeConst(container_id) orelse return error.TestUnexpectedResult,
        .{
            .available = .{ .width = 300, .height = 300 },
            .percentage_basis = .{ .width = 300, .height = 300 },
            .width_mode = .min_content,
            .height_mode = .definite,
            .sizing_mode = .content,
            .known_border = .{ .width = null, .height = 5 },
        },
        &context,
    );

    try std.testing.expectEqual(@as(f32, 20), measured.border.width);
    try std.testing.expectEqual(@as(f32, 8), measured.border.height);
    try std.testing.expect(ContentRootChildProbe.calls > 0);
    try std.testing.expect(!ContentRootChildProbe.saw_known_width);
    try std.testing.expect(!ContentRootChildProbe.saw_known_height);
}

test "grid content sizing does not leak through nested grid children" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const inner_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const outer_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const columns = [_]style.GridTrack{.max_content};
    const rows = [_]style.GridTrack{.max_content};

    try appendLeaf(
        &tree,
        leaf_id,
        inner_id,
        leafStyle(),
        .{ .label = .{ .text = "nested content child" } },
    );
    try appendContainer(
        &tree,
        inner_id,
        outer_id,
        fixedContainer(50, 50, columns[0..], rows[0..]),
    );
    try appendContainer(
        &tree,
        outer_id,
        .root,
        fixedContainer(200, 100, columns[0..], rows[0..]),
    );
    try tree.appendChild(inner_id, leaf_id);
    try tree.appendChild(outer_id, inner_id);

    ContentRootChildProbe.reset();
    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = ContentRootChildProbe.source,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();

    _ = try grid.measureNatural(
        &tree,
        tree.nodeConst(outer_id) orelse return error.TestUnexpectedResult,
        .{
            .available = .{ .width = 300, .height = 300 },
            .percentage_basis = .{ .width = 300, .height = 300 },
            .sizing_mode = .content,
            .known_border = .{ .width = null, .height = 5 },
        },
        &context,
    );

    try std.testing.expect(ContentRootChildProbe.calls > 0);
    try std.testing.expect(!ContentRootChildProbe.saw_known_width);
    try std.testing.expect(!ContentRootChildProbe.saw_known_height);
}

test "grid content sizing converts known border only at the leaf callback" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: FrameNodeId = @fromBackingInt(@intCast(1));
    var leaf = leafStyle();
    leaf.display = .grid;
    leaf.size = .{
        .width = .{ .length = 200 },
        .height = .{ .length = 300 },
    };
    leaf.min_size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
    };
    leaf.max_size = .{
        .width = .{ .length = 400 },
        .height = .{ .length = 400 },
    };
    leaf.aspect_ratio = 2;
    leaf.padding_inset = .{
        .top = .{ .length = 5 },
        .right = .{ .length = 10 },
        .bottom = .{ .length = 5 },
        .left = .{ .length = 10 },
    };
    try appendLeaf(
        &tree,
        leaf_id,
        .root,
        leaf,
        .{ .label = .{ .text = "content root" } },
    );

    ContentRootLeafProbe.reset();
    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = ContentRootLeafProbe.source,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();

    const measured = try grid.measureNatural(
        &tree,
        tree.nodeConst(leaf_id) orelse return error.TestUnexpectedResult,
        .{
            .available = .{ .width = 300, .height = 300 },
            .percentage_basis = .{ .width = 300, .height = 300 },
            .width_mode = .min_content,
            .height_mode = .definite,
            .sizing_mode = .content,
            .known_border = .{ .width = null, .height = 40 },
        },
        &context,
    );

    try std.testing.expect(!ContentRootLeafProbe.saw_known_width);
    try std.testing.expectEqual(@as(?f32, 30), ContentRootLeafProbe.known_height);
    try std.testing.expectEqual(@as(f32, 37), measured.border.width);
    try std.testing.expectEqual(@as(f32, 40), measured.border.height);
}

test "grid measurement cache identifies the complete sizing request" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: FrameNodeId = @fromBackingInt(@intCast(1));
    var leaf = leafStyle();
    leaf.display = .grid;
    leaf.size = .{
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
    };
    try appendLeaf(
        &tree,
        leaf_id,
        .root,
        leaf,
        .{ .label = .{ .text = "cache identity" } },
    );

    CacheIdentityProbe.reset();
    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = CacheIdentityProbe.source,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();

    const requests = [_]layout_context.Request{
        .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = 100, .height = 100 },
        },
        .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = 100, .height = 100 },
            .known_border = .{ .width = 20, .height = null },
        },
        .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = 100, .height = 100 },
            .known_border = .{ .width = null, .height = 10 },
        },
        .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = 100, .height = 100 },
            .sizing_mode = .content,
            .known_border = .{ .width = 20, .height = 10 },
        },
    };

    for (requests) |request| {
        const calls_before = CacheIdentityProbe.calls;
        _ = try grid.measureNatural(
            &tree,
            tree.nodeConst(leaf_id) orelse return error.TestUnexpectedResult,
            request,
            &context,
        );
        const calls_after = CacheIdentityProbe.calls;
        try std.testing.expect(calls_after > calls_before);

        _ = try grid.measureNatural(
            &tree,
            tree.nodeConst(leaf_id) orelse return error.TestUnexpectedResult,
            request,
            &context,
        );
        try std.testing.expectEqual(calls_after, CacheIdentityProbe.calls);
    }
}

const ContentRootChildProbe = struct {
    var calls: usize = 0;
    var saw_known_width: bool = false;
    var saw_known_height: bool = false;

    fn reset() void {
        calls = 0;
        saw_known_width = false;
        saw_known_height = false;
    }

    fn measure(
        _: ?*anyopaque,
        _: []const u8,
        input: layout_context.MeasureInput,
    ) layout_context.LayoutError!layout_context.TextMeasurement {
        calls += 1;
        saw_known_width = saw_known_width or input.known_dimensions.width != null;
        saw_known_height = saw_known_height or input.known_dimensions.height != null;
        return .{ .width = 12, .height = 12 };
    }

    const source: layout_context.MeasureSource = .{ .callback = measure };
};

const ContentRootLeafProbe = struct {
    var saw_known_width: bool = false;
    var known_height: ?f32 = null;

    fn reset() void {
        saw_known_width = false;
        known_height = null;
    }

    fn measure(
        _: ?*anyopaque,
        _: []const u8,
        input: layout_context.MeasureInput,
    ) layout_context.LayoutError!layout_context.TextMeasurement {
        saw_known_width = saw_known_width or input.known_dimensions.width != null;
        if (input.known_dimensions.height) |height| known_height = height;
        return .{ .width = 17, .height = 13 };
    }

    const source: layout_context.MeasureSource = .{ .callback = measure };
};

const CacheIdentityProbe = struct {
    var calls: usize = 0;

    fn reset() void {
        calls = 0;
    }

    fn measure(
        _: ?*anyopaque,
        _: []const u8,
        _: layout_context.MeasureInput,
    ) layout_context.LayoutError!layout_context.TextMeasurement {
        calls += 1;
        return .{ .width = 20, .height = 10 };
    }

    const source: layout_context.MeasureSource = .{ .callback = measure };
};

const ContentBoxMeasureProbe = struct {
    var known_width: ?f32 = null;

    fn reset() void {
        known_width = null;
    }

    fn measure(
        _: ?*anyopaque,
        _: []const u8,
        input: layout_context.MeasureInput,
    ) layout_context.LayoutError!layout_context.TextMeasurement {
        if (input.known_dimensions.width) |width| known_width = width;
        return .{ .width = 0, .height = 0 };
    }

    const source: layout_context.MeasureSource = .{ .callback = measure };
};

const NestedMeasureCounter = struct {
    var calls: usize = 0;

    fn reset() void {
        calls = 0;
    }

    fn measure(
        _: ?*anyopaque,
        _: []const u8,
        _: layout_context.MeasureInput,
    ) layout_context.LayoutError!layout_context.TextMeasurement {
        calls += 1;
        return .{ .width = 10, .height = 10 };
    }

    const source: layout_context.MeasureSource = .{ .callback = measure };
};
/// A provider that shapes a first baseline of 8 inside a 40-tall box, so a
/// baseline-aligned sibling needs a 32px shim to reach that shared line.
const BaselineShimMeasure = struct {
    fn measure(
        _: ?*anyopaque,
        _: []const u8,
        _: layout_context.MeasureInput,
    ) layout_context.LayoutError!layout_context.TextMeasurement {
        return .{ .width = 10, .height = 40, .first_baseline = 8 };
    }

    const source: grid.MeasureSource = .{ .callback = measure };
};
test "grid baseline shim skips items that opt out of baseline alignment" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const donor_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const participant_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const outsider_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const probe_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(5));

    // Three columns so all three items share row 0; probe goes to row 1.
    const columns = [_]style.GridTrack{
        .{ .fixed = 30 },
        .{ .fixed = 30 },
        .{ .fixed = 30 },
    };
    const rows: []const style.GridTrack = &.{};
    var participant_value = false;
    var outsider_value = false;

    // The donor is a textless leaf whose box is 40 tall; its bottom edge
    // establishes the shared baseline at 40. The participant's caption
    // shapes a baseline of 8 (via BaselineShimMeasure) in its own 40-tall
    // box, so it needs a 32px shim to reach the shared line. The outsider
    // opts out of baseline alignment (align-self: start) and is 48 tall,
    // so if it incorrectly received the 32px shim its contribution would
    // be 80 and the shared row would grow from 72 to 80. The probe in the
    // next row reports the row's real height.
    var donor = leafStyle();
    donor.size = .{ .width = .{ .length = 30 }, .height = .{ .length = 40 } };
    try appendLeaf(&tree, donor_id, container_id, donor, .{ .spacer = .{} });

    var participant = leafStyle();
    participant.size = .{ .width = .{ .length = 30 }, .height = .{ .length = 40 } };
    try appendLeaf(&tree, participant_id, container_id, participant, .{
        .checkbox = .{ .label = "B", .value = &participant_value },
    });

    var outsider = leafStyle();
    outsider.size = .{ .width = .{ .length = 30 }, .height = .{ .length = 48 } };
    outsider.grid_align_self = .start;
    try appendLeaf(&tree, outsider_id, container_id, outsider, .{
        .checkbox = .{ .label = "C", .value = &outsider_value },
    });

    var probe = leafStyle();
    probe.size = .{ .width = .{ .length = 30 }, .height = .{ .length = 8 } };
    try appendLeaf(&tree, probe_id, container_id, probe, .{ .spacer = .{} });

    var container = fixedContainer(100, 100, columns[0..], rows);
    container.grid_align_items = .baseline;
    container.grid_justify_items = .start;
    container.grid_align_content = .start;
    container.grid_justify_content = .start;
    try appendContainer(&tree, container_id, .root, container);

    try tree.appendChild(container_id, donor_id);
    try tree.appendChild(container_id, participant_id);
    try tree.appendChild(container_id, outsider_id);
    try tree.appendChild(container_id, probe_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 100 },
        .measure = BaselineShimMeasure.source,
    });

    // The donor keeps the line at 40. The participant is shimmed down by 32
    // so its own baseline of 8 meets the donor's 40.
    try expectRelative(&tree, donor_id, .{ .x = 0, .y = 0, .w = 30, .h = 40 });
    try expectRelative(&tree, participant_id, .{ .x = 30, .y = 32, .w = 30, .h = 40 });
    // The outsider aligns to its own start edge and never receives a shim,
    // so it sits at the row top rather than 32 below it.
    try expectRelative(&tree, outsider_id, .{ .x = 60, .y = 0, .w = 30, .h = 48 });
    // The shared row is 40 from the donor and 40 + 32 from the shimmed
    // participant, never the 80 a leaked shim on the outsider would make it.
    try expectRelative(&tree, probe_id, .{ .x = 0, .y = 72, .w = 30, .h = 8 });
}

test "grid baseline shim leaves a non participant row track unsized" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const donor_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const participant_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const outsider_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const probe_id: FrameNodeId = @fromBackingInt(@intCast(4));
    const container_id: FrameNodeId = @fromBackingInt(@intCast(5));
    var participant_value = false;
    var outsider_value = false;

    // Same three-column layout, but the participant is only 8 tall so the
    // shared row is 40 tall (donor's height). The outsider is 48 tall and
    // opts out; if it were counted as a baseline participant it would
    // donate a baseline of 8 and force a 32px shim on itself, pushing its
    // contribution from 48 to 80 and growing the row from 48 to 80.
    // The probe in the next row proves the row track stayed at 48.
    const columns = [_]style.GridTrack{
        .{ .fixed = 30 },
        .{ .fixed = 30 },
        .{ .fixed = 30 },
    };
    const rows: []const style.GridTrack = &.{};
    var donor = leafStyle();
    donor.size = .{ .width = .{ .length = 30 }, .height = .{ .length = 40 } };
    try appendLeaf(&tree, donor_id, container_id, donor, .{ .spacer = .{} });

    var participant = leafStyle();
    participant.size = .{ .width = .{ .length = 30 }, .height = .{ .length = 8 } };
    try appendLeaf(&tree, participant_id, container_id, participant, .{
        .checkbox = .{ .label = "B", .value = &participant_value },
    });

    var outsider = leafStyle();
    outsider.size = .{ .width = .{ .length = 30 }, .height = .{ .length = 48 } };
    outsider.grid_align_self = .start;
    try appendLeaf(&tree, outsider_id, container_id, outsider, .{
        .checkbox = .{ .label = "C", .value = &outsider_value },
    });

    var probe = leafStyle();
    probe.size = .{ .width = .{ .length = 30 }, .height = .{ .length = 8 } };
    try appendLeaf(&tree, probe_id, container_id, probe, .{ .spacer = .{} });

    var container = fixedContainer(100, 100, columns[0..], rows);
    container.grid_align_items = .baseline;
    container.grid_justify_items = .start;
    container.grid_align_content = .start;
    container.grid_justify_content = .start;
    try appendContainer(&tree, container_id, .root, container);

    try tree.appendChild(container_id, donor_id);
    try tree.appendChild(container_id, participant_id);
    try tree.appendChild(container_id, outsider_id);
    try tree.appendChild(container_id, probe_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 100 },
        .measure = BaselineShimMeasure.source,
    });

    // The donor keeps the line at 40. The participant is shimmed down by 32
    // so its own baseline of 8 meets the donor's 40.
    try expectRelative(&tree, donor_id, .{ .x = 0, .y = 0, .w = 30, .h = 40 });
    try expectRelative(&tree, participant_id, .{ .x = 30, .y = 32, .w = 30, .h = 8 });
    // The outsider aligns to its own start edge and never receives a shim,
    // so it sits at the row top and the row track stays at 48 (donor's 40
    // and the participant's 40 from shimmed 8). A leaked shim would push
    // the outsider's contribution to 80 and the row to 80.
    try expectRelative(&tree, outsider_id, .{ .x = 60, .y = 0, .w = 30, .h = 48 });
    // The shared row is 40 from the donor and 40 from the shimmed
    // participant, never the 80 a leaked shim on the outsider would make it.
    try expectRelative(&tree, probe_id, .{ .x = 0, .y = 48, .w = 30, .h = 8 });
}
