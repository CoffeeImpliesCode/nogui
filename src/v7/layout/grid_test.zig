//! Specifies the direct-tree contract for the modular grid layout engine.

const std = @import("std");
const Id = @import("../id.zig").Id;
const style = @import("../style.zig");
const widget = @import("../widget.zig");
const grid = @import("grid.zig");

const Rect = widget.Rect;
const Style = style.Style;
const WidgetKind = widget.WidgetKind;
const WidgetTree = widget.WidgetTree;

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
    try appendContainer(&tree, outer_id, .root, fixedContainer(100, 20, outer_columns[0..], outer_rows[0..]));
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
