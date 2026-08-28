//! Specifies the direct-tree contract for the modular grid layout engine.

const std = @import("std");
const Id = @import("../id.zig").Id;
const style = @import("../style.zig");
const widget = @import("../widget.zig");
const grid = @import("grid.zig");
const layout_context = @import("context.zig");

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
    _: layout_context.Request,
) layout_context.LayoutError!void {
    unreachable;
}

fn appendContainer(tree: *WidgetTree, id: Id, parent: Id, node_style: Style) !void {
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
    container_id: Id,
    available: widget.Size,
    measure: ?grid.MeasureFn,
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

fn expectRelative(tree: *const WidgetTree, id: Id, expected: Rect) !void {
    try expectRect(expected, tree.nodeConst(id).?.rect);
}

fn measureLabel(text: []const u8, _: f32, _: u8) widget.Size {
    if (std.mem.eql(u8, text, "intrinsic")) {
        return .{ .width = 30, .height = 12 };
    }
    return .{ .width = 8, .height = 8 };
}

test "grid fixed two by two tracks preserve gaps" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const third_id: Id = @enumFromInt(3);
    const fourth_id: Id = @enumFromInt(4);
    const container_id: Id = @enumFromInt(5);
    const columns = [_]style.GridTrack{ .{ .fixed = 30 }, .{ .fixed = 40 } };
    const rows = [_]style.GridTrack{ .{ .fixed = 10 }, .{ .fixed = 20 } };

    try appendLeaf(&tree, first_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, second_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, third_id, container_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, fourth_id, container_id, leafStyle(), .{ .spacer = .{} });
    var container = fixedContainer(75, 33, columns[0..], rows[0..]);
    container.grid_column_gap = 5;
    container.grid_row_gap = 3;
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

    const spanning_id: Id = @enumFromInt(1);
    const negative_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);
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
    tree.node(spanning_id).?.style = spanning_style;

    var negative_style = leafStyle();
    negative_style.grid_column = .{
        .start = .{ .line = -2 },
        .end = .{ .line = -1 },
    };
    negative_style.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    tree.node(negative_id).?.style = negative_style;

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

    const auto_id: Id = @enumFromInt(1);
    const definite_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);
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

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);
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

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const nested_id: Id = @enumFromInt(3);
    const outer_id: Id = @enumFromInt(4);
    const nested_columns = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };
    const nested_rows = [_]style.GridTrack{.{ .fixed = 10 }};
    const outer_columns = [_]style.GridTrack{.auto};
    const outer_rows = [_]style.GridTrack{.{ .fixed = 20 }};
    try appendLeaf(&tree, first_id, nested_id, leafStyle(), .{ .spacer = .{} });
    try appendLeaf(&tree, second_id, nested_id, leafStyle(), .{ .spacer = .{} });
    var nested = fixedContainer(0, 0, nested_columns[0..], nested_rows[0..]);
    nested.size = .{ .width = .auto, .height = .auto };
    nested.grid_column_gap = 10;
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

    const container_id: Id = @enumFromInt(100);
    const item_count: usize = 40;
    const columns = [_]style.GridTrack{.{ .fixed = 10 }};
    const rows = [_]style.GridTrack{.{ .fixed = 10 }};

    for (0..item_count) |index| {
        const id: Id = @enumFromInt(@as(u32, @intCast(index + 1)));
        try appendLeaf(&tree, id, container_id, spacerStyle(), .{ .spacer = .{ .size = 10 } });
    }
    var container = fixedContainer(400, 10, columns[0..], rows[0..]);
    container.grid_auto_columns = .{ .fixed = 10 };
    container.grid_auto_flow = .column;
    try appendContainer(&tree, container_id, .root, container);
    for (0..item_count) |index| {
        const id: Id = @enumFromInt(@as(u32, @intCast(index + 1)));
        try tree.appendChild(container_id, id);
    }

    try layoutContainer(&tree, container_id, .{ .width = 400, .height = 10 }, null);

    const first_id: Id = @enumFromInt(1);
    const thirty_third_id: Id = @enumFromInt(33);
    const last_id: Id = @enumFromInt(40);
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
    try expectRelative(&tree, thirty_third_id, .{ .x = 320, .y = 0, .w = 10, .h = 10 });
    try expectRelative(&tree, last_id, .{ .x = 390, .y = 0, .w = 10, .h = 10 });
}

test "grid mixed tracks resolve fixed percent auto minmax and fr" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const fixed_id: Id = @enumFromInt(1);
    const percent_id: Id = @enumFromInt(2);
    const intrinsic_id: Id = @enumFromInt(3);
    const minmax_id: Id = @enumFromInt(4);
    const fraction_id: Id = @enumFromInt(5);
    const container_id: Id = @enumFromInt(6);
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

    const item_ids = [_]Id{ fixed_id, percent_id, intrinsic_id, minmax_id, fraction_id };
    for (item_ids, 0..) |id, index| {
        tree.node(id).?.style.grid_column = .{
            .start = .{ .line = @intCast(index + 1) },
            .end = .{ .line = @intCast(index + 2) },
        };
        tree.node(id).?.style.grid_row = .{
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
        measureLabel,
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

    const inherited_id: Id = @enumFromInt(1);
    const self_aligned_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);
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

    try expectRelative(&tree, inherited_id, .{ .x = 60, .y = 40, .w = 10, .h = 10 });
    try expectRelative(&tree, self_aligned_id, .{ .x = 30, .y = 50, .w = 10, .h = 10 });
}

test "grid absolute insets and nested scroll geometry remain relative" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var scroll_state: widget.ScrollState = .{};
    const overflowing_id: Id = @enumFromInt(1);
    const absolute_id: Id = @enumFromInt(2);
    const inner_id: Id = @enumFromInt(3);
    const outer_id: Id = @enumFromInt(4);
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
    tree.node(inner_id).?.scroll = .{ .state = &scroll_state, .axis = .both };
    try tree.appendChild(inner_id, overflowing_id);
    try tree.appendChild(inner_id, absolute_id);

    var outer = fixedContainer(140, 100, outer_columns[0..], outer_rows[0..]);
    outer.padding = .{ .top = 8, .right = 10, .bottom = 8, .left = 10 };
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

    const leaf_id: Id = @enumFromInt(1);
    const hidden_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);
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

        const container_id: Id = @enumFromInt(1);
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

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);
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
    container.grid_column_gap = 10;
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

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const spanning_id: Id = @enumFromInt(3);
    const container_id: Id = @enumFromInt(4);
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
    container.grid_column_gap = 10;
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);
    try tree.appendChild(container_id, spanning_id);

    try layoutContainer(&tree, container_id, .{ .width = 200, .height = 60 }, null);

    // Tracks initially: 20, 30, 0 + 2*10 gap = 70. Deficit = 100 - 70 = 30.
    // 30 is divided among 3 auto tracks (+10 each) -> Tracks become 30, 40, 10.
    // Total width = 30 + 10 + 40 + 10 + 10 = 100.
    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 40 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 40, .y = 0, .w = 30, .h = 20 });
    try expectRelative(&tree, spanning_id, .{ .x = 0, .y = 20, .w = 100, .h = 20 });
}

test "grid track minmax expands non-fr tracks up to max limit before fr tracks" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const spanning_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);
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
    container.grid_column_gap = 10;
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

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);
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

test "grid fit-content track clamps content growth to limit" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);
    const columns = [_]style.GridTrack{
        .{ .fit_content = .{ .length = 50 } },
        .{ .fit_content = .{ .length = 50 } },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 30 }};

    // First item has width 30 (< 50 limit), second item has width 80 (> 50 limit)
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

    // Column 0: 30 (unclamped). Column 1: 50 (track clamped at 50, item retains explicit 80).
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 30, .h = 30 });
    try expectRelative(&tree, second_id, .{ .x = 30, .y = 0, .w = 80, .h = 30 });
    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 80, .h = 30 });
}

test "grid fit-content percentage caps track against definite axis" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const marker_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);
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

    // The 50% limit resolves against the definite 60px width. The marker starts
    // at the resulting 30px boundary, which proves the first track was capped.
    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 60, .h = 20 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 30, .h = 20 });
    try expectRelative(&tree, marker_id, .{ .x = 30, .y = 0, .w = 30, .h = 20 });
}

test "grid minmax fit-content maximum does not undercut fixed minimum" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const marker_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);
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

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);
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

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);
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
    const measured = try grid.measureNatural(
        &tree,
        tree.nodeConst(container_id).?,
        .{
            .available = .{ .width = 60, .height = 20 },
            .percentage_basis = .{ .width = null, .height = 20 },
            .intrinsic_width = true,
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

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);
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

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const third_id: Id = @enumFromInt(3);
    const container_id: Id = @enumFromInt(4);

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

    const spanning_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);
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
    container.grid_column_gap = 10;
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

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);

    const columns = [_]style.GridTrack{
        .{ .fixed = 50 },
        .{ .fixed = 50 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 30 }};

    var first = leafStyle();
    first.size = .{ .width = .{ .length = 30 }, .height = .{ .length = 30 } };
    first.margin = .{ .left = 10, .right = 0, .top = 0, .bottom = 0 };
    first.margin_inset = .{
        .left = .{ .length = 10 },
        .right = .{ .length = 0 },
        .top = .{ .length = 0 },
        .bottom = .{ .length = 0 },
    };
    try appendLeaf(&tree, first_id, container_id, first, .{ .spacer = .{} });

    var second = leafStyle();
    second.size = .{ .width = .{ .length = 30 }, .height = .{ .length = 30 } };
    second.margin = .{ .left = 5, .right = 0, .top = 0, .bottom = 0 };
    second.margin_inset = .{
        .left = .{ .length = 5 },
        .right = .{ .length = 0 },
        .top = .{ .length = 0 },
        .bottom = .{ .length = 0 },
    };
    try appendLeaf(&tree, second_id, container_id, second, .{ .spacer = .{} });

    var container = fixedContainer(300, 30, columns[0..], rows[0..]);
    container.grid_column_gap = 20;
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

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);

    const columns = [_]style.GridTrack{
        .{ .fixed = 80 },
        .{ .fixed = 80 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 60 }};

    // First item: font_size 20 -> ascent = 20 * 0.8 = 16
    var first = leafStyle();
    first.size = .{ .width = .{ .length = 60 }, .height = .{ .length = 20 } };
    first.grid_align_self = .baseline;
    try appendLeaf(&tree, first_id, container_id, first, .{ .label = .{ .text = "First" } });
    tree.node(first_id).?.font_size = 20;

    // Second item: font_size 40 -> ascent = 40 * 0.8 = 32
    var second = leafStyle();
    second.size = .{ .width = .{ .length = 60 }, .height = .{ .length = 40 } };
    second.grid_align_self = .baseline;
    try appendLeaf(&tree, second_id, container_id, second, .{ .label = .{ .text = "Second" } });
    tree.node(second_id).?.font_size = 40;

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

    const in_flow_id: Id = @enumFromInt(1);
    const absolute_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);

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
    container.grid_column_gap = 10;
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

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);

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

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);

    const columns = [_]style.GridTrack{ .{ .fr = 1 }, .{ .fr = 1 } };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    var first_style = leafStyle();
    first_style.size = .{ .width = .{ .length = 60 }, .height = .{ .length = 20 } };
    first_style.grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    first_style.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };
    try appendLeaf(&tree, first_id, container_id, first_style, .{ .spacer = .{} });

    try appendLeaf(&tree, second_id, container_id, leafStyle(), .{ .spacer = .{} });
    tree.node(second_id).?.style.grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    tree.node(second_id).?.style.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };

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

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);

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
    tree.node(second_id).?.style.grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } };
    tree.node(second_id).?.style.grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } };

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

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);
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
    container.border = .{ .left = 1, .right = 1 };
    container.border_inset = .{
        .top = .{ .length = 0 },
        .right = .{ .length = 1 },
        .bottom = .{ .length = 0 },
        .left = .{ .length = 1 },
    };
    container.padding = .{ .left = 10, .right = 10 };
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

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);
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

    const absolute_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);
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
    container.padding = .{ .left = 10, .right = 10 };
    container.padding_inset = .{
        .top = .{ .length = 0 },
        .right = .{ .length = 10 },
        .bottom = .{ .length = 0 },
        .left = .{ .length = 10 },
    };
    try appendContainer(&tree, container_id, .root, container);
    try tree.appendChild(container_id, absolute_id);

    try layoutContainer(&tree, container_id, .{ .width = 200, .height = 160 }, null);

    try expectRelative(&tree, absolute_id, .{ .x = 180, .y = 2, .w = 0, .h = 10 });
}

test "grid RTL absolute auto insets use physical end of definite area" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);
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

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);
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

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);
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

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);
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

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);
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

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);
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

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);
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

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);
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

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);
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

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const third_id: Id = @enumFromInt(3);
    const container_id: Id = @enumFromInt(4);
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
    container.grid_row_gap = 10;
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

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const third_id: Id = @enumFromInt(3);
    const container_id: Id = @enumFromInt(4);
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
    container.grid_row_gap = 10;
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

        const child_id: Id = @enumFromInt(1);
        const container_id: Id = @enumFromInt(2);
        try appendLeaf(&tree, child_id, container_id, leafStyle(), .{ .spacer = .{} });
        var container = fixedContainer(120, 40, columns[0..], rows[0..]);
        container.grid_column_gap = 10;
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

        const child_id: Id = @enumFromInt(1);
        const container_id: Id = @enumFromInt(2);
        try appendLeaf(&tree, child_id, container_id, leafStyle(), .{ .spacer = .{} });
        var container = fixedContainer(40, 120, columns[0..], rows[0..]);
        container.grid_row_gap = 10;
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

        const child_id: Id = @enumFromInt(1);
        const container_id: Id = @enumFromInt(2);
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

        const first_id: Id = @enumFromInt(1);
        const second_id: Id = @enumFromInt(2);
        const container_id: Id = @enumFromInt(3);
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
        container.grid_column_gap = 10;
        container.grid_row_gap = 10;
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

    const first_span_id: Id = @enumFromInt(1);
    const second_span_id: Id = @enumFromInt(2);
    const first_marker_id: Id = @enumFromInt(3);
    const second_marker_id: Id = @enumFromInt(4);
    const third_marker_id: Id = @enumFromInt(5);
    const fourth_marker_id: Id = @enumFromInt(6);
    const container_id: Id = @enumFromInt(7);
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

    const marker_ids = [_]Id{
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
    container.border = .{ .top = 3, .right = 3, .bottom = 3, .left = 3 };
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

    const spanning_id: Id = @enumFromInt(1);
    const first_marker_id: Id = @enumFromInt(2);
    const second_marker_id: Id = @enumFromInt(3);
    const container_id: Id = @enumFromInt(4);
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

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);
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

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);
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

    const spanning_id: Id = @enumFromInt(1);
    const first_marker_id: Id = @enumFromInt(2);
    const second_marker_id: Id = @enumFromInt(3);
    const container_id: Id = @enumFromInt(4);
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
    container.border = .{ .top = 3, .right = 3, .bottom = 3, .left = 3 };
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

    const spanning_id: Id = @enumFromInt(1);
    const first_marker_id: Id = @enumFromInt(2);
    const second_marker_id: Id = @enumFromInt(3);
    const container_id: Id = @enumFromInt(4);
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
    container.border = .{ .top = 3, .right = 3, .bottom = 3, .left = 3 };
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

    const spanning_id: Id = @enumFromInt(1);
    const first_marker_id: Id = @enumFromInt(2);
    const second_marker_id: Id = @enumFromInt(3);
    const container_id: Id = @enumFromInt(4);
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
    container.border = .{ .top = 3, .right = 3, .bottom = 3, .left = 3 };
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

        const second_third_span_id: Id = @enumFromInt(1);
        const first_second_span_id: Id = @enumFromInt(2);
        const first_marker_id: Id = @enumFromInt(3);
        const second_marker_id: Id = @enumFromInt(4);
        const third_marker_id: Id = @enumFromInt(5);
        const container_id: Id = @enumFromInt(6);
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

        const marker_ids = [_]Id{
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

    const spanning_id: Id = @enumFromInt(1);
    const fr_marker_id: Id = @enumFromInt(2);
    const auto_marker_id: Id = @enumFromInt(3);
    const container_id: Id = @enumFromInt(4);
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

    const first_id: Id = @enumFromInt(1);
    const spanning_id: Id = @enumFromInt(2);
    const first_marker_id: Id = @enumFromInt(3);
    const second_marker_id: Id = @enumFromInt(4);
    const container_id: Id = @enumFromInt(5);
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

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);
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

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);
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

    const self_start_id: Id = @enumFromInt(1);
    const self_end_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);
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
