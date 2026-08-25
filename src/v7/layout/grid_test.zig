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
        .{ .fit_content = 50 },
        .{ .fit_content = 50 },
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
