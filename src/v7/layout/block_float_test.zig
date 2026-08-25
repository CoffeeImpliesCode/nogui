//! Specifies the direct-tree contract for block, float, clear, absolute, and none layout.

const std = @import("std");
const Id = @import("../id.zig").Id;
const flex = @import("../flex.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");
const block_float = @import("block_float.zig");
const sizing = @import("sizing.zig");

const Rect = widget.Rect;
const Style = style.Style;
const WidgetKind = widget.WidgetKind;
const WidgetTree = widget.WidgetTree;

fn appendNode(tree: *WidgetTree, id: Id, parent: Id, node_style: Style) !void {
    const kind: WidgetKind = switch (node_style.display) {
        .block, .flow_root => .{ .column = .{} },
        .flex, .grid => .{ .column = .{} },
        .none => .{ .spacer = .{} },
    };
    try tree.appendNode(.{
        .id = id,
        .kind = kind,
        .parent = parent,
        .style = node_style,
    });
}

fn definiteContext(width: f32, height: f32) sizing.SizingContext {
    return .{
        .available = .{
            .width = .{ .definite = width },
            .height = .{ .definite = height },
        },
        .percentage_basis = .{ .width = width, .height = height },
    };
}

fn layoutContainer(tree: *WidgetTree, container_id: Id, width: f32, height: f32) !void {
    const measure: ?flex.MeasureFn = null;
    try block_float.layoutContainer(
        tree,
        container_id,
        definiteContext(width, height),
        measure,
    );
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

test "flow root clears a left float before the following block" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: Id = @enumFromInt(1);
    const clear_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, float_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 30 }, .height = .{ .length = 20 } },
    });
    try appendNode(&tree, clear_id, root_id, .{
        .display = .block,
        .clear = .both,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 40 }, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(root_id, float_id);
    try tree.appendChild(root_id, clear_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, float_id, .{ .x = 0, .y = 0, .w = 30, .h = 20 });
    try expectRelative(&tree, clear_id, .{ .x = 0, .y = 20, .w = 40, .h = 10 });
}

test "absolute child uses containing content box without advancing block flow" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const normal_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 10 }, .height = .{ .length = 8 } },
        .inset = .{
            .top = .{ .length = 9 },
            .right = .auto,
            .bottom = .auto,
            .left = .{ .length = 7 },
        },
    });
    try appendNode(&tree, normal_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 6 } },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 30 } },
        .border = .{ .top = 2, .left = 3 },
        .padding = .{ .top = 4, .left = 5 },
        .border_inset = .{
            .top = .{ .length = 2 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 3 },
        },
        .padding_inset = .{
            .top = .{ .length = 4 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 5 },
        },
    });
    try tree.appendChild(root_id, absolute_id);
    try tree.appendChild(root_id, normal_id);

    try layoutContainer(&tree, root_id, 100, 30);

    try expectRelative(&tree, absolute_id, .{ .x = 7, .y = 9, .w = 10, .h = 8 });
    try expectRelative(&tree, normal_id, .{ .x = 0, .y = 0, .w = 20, .h = 6 });
    try expectRect(
        .{ .x = 15, .y = 15, .w = 10, .h = 8 },
        widget.absoluteRect(&tree, absolute_id),
    );
}

test "display none receives a zero rect and contributes no block height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const hidden_id: Id = @enumFromInt(1);
    const visible_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, hidden_id, root_id, .{
        .display = .none,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 50 }, .height = .{ .length = 40 } },
    });
    try appendNode(&tree, visible_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 6 } },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(root_id, hidden_id);
    try tree.appendChild(root_id, visible_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, hidden_id, .{});
    try expectRelative(&tree, visible_id, .{ .x = 0, .y = 0, .w = 20, .h = 6 });
    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 6 });
}

test "rtl flow root places an ordinary block at the right inline origin" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);

    try appendNode(&tree, child_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .writing_direction = .rtl,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(root_id, child_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    try expectRelative(&tree, child_id, .{ .x = 80, .y = 0, .w = 20, .h = 10 });
    try expectRect(
        .{ .x = 80, .y = 0, .w = 20, .h = 10 },
        widget.absoluteRect(&tree, child_id),
    );
}

test "auto-height root resolves bottom absolute child after normal flow" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const normal_id: Id = @enumFromInt(1);
    const absolute_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, normal_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 20 } },
    });
    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 10 }, .height = .{ .length = 5 } },
        .inset = .{
            .top = .auto,
            .right = .auto,
            .bottom = .{ .length = 0 },
            .left = .auto,
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(root_id, normal_id);
    try tree.appendChild(root_id, absolute_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, normal_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
    try expectRelative(&tree, absolute_id, .{ .x = 0, .y = 15, .w = 10, .h = 5 });
    try expectRect(
        .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        widget.absoluteRect(&tree, normal_id),
    );
    try expectRect(
        .{ .x = 0, .y = 15, .w = 10, .h = 5 },
        widget.absoluteRect(&tree, absolute_id),
    );
}

test "absolute percentage insets use the definite content basis" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);

    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 10 }, .height = .{ .length = 10 } },
        .inset = .{
            .top = .{ .percent = 0.2 },
            .right = .auto,
            .bottom = .auto,
            .left = .{ .percent = 0.1 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(root_id, absolute_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, absolute_id, .{ .x = 10, .y = 20, .w = 10, .h = 10 });
    try expectRect(
        .{ .x = 10, .y = 20, .w = 10, .h = 10 },
        widget.absoluteRect(&tree, absolute_id),
    );
}

test "scrolling block establishes a float-containing formatting context" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);

    try appendNode(&tree, float_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 30 } },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
        .overflow = .{ .width = .scroll, .height = .scroll },
    });
    try tree.appendChild(root_id, float_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 30 });
    try expectRelative(&tree, float_id, .{ .x = 0, .y = 0, .w = 20, .h = 30 });
    try expectRect(
        .{ .x = 0, .y = 0, .w = 20, .h = 30 },
        widget.absoluteRect(&tree, float_id),
    );
}

test "hidden overflow on either axis contains floats while clip does not" {
    const Scenario = struct {
        overflow: style.OverflowAxes,
        expected_height: f32,
    };
    const scenarios = [_]Scenario{
        .{
            .overflow = .{ .width = .hidden, .height = .clip },
            .expected_height = 30,
        },
        .{
            .overflow = .{ .width = .clip, .height = .hidden },
            .expected_height = 30,
        },
        .{
            .overflow = .{ .width = .clip, .height = .clip },
            .expected_height = 0,
        },
    };

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const float_id: Id = @enumFromInt(1);
        const container_id: Id = @enumFromInt(2);
        const root_id: Id = @enumFromInt(3);

        try appendNode(&tree, float_id, container_id, .{
            .display = .block,
            .float = .left,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 30 } },
        });
        try appendNode(&tree, container_id, root_id, .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .length = 60 }, .height = .auto },
            .overflow = scenario.overflow,
        });
        try appendNode(&tree, root_id, .root, .{
            .display = .flow_root,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .length = 100 }, .height = .auto },
        });
        try tree.appendChild(container_id, float_id);
        try tree.appendChild(root_id, container_id);

        const pass = try block_float.LayoutPass.init(&tree);
        try pass.layoutContainer(root_id, definiteContext(100, 100), null);

        try expectRelative(
            &tree,
            container_id,
            .{ .x = 0, .y = 0, .w = 60, .h = scenario.expected_height },
        );
        try expectRelative(&tree, float_id, .{ .x = 0, .y = 0, .w = 20, .h = 30 });
    }
}

test "minimum width clamp drives block child aspect-ratio height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);

    try appendNode(&tree, child_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .auto },
        .min_size = .{ .width = .{ .length = 40 }, .height = .auto },
        .aspect_ratio = 2,
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(root_id, child_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 40, .h = 20 });
    try expectRect(
        .{ .x = 0, .y = 0, .w = 40, .h = 20 },
        widget.absoluteRect(&tree, child_id),
    );
}

test "indefinite percentage height behaves as auto" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);

    try appendNode(&tree, child_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .percent = 0.5 } },
        .padding_inset = .{
            .top = .{ .length = 3 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 7 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(root_id, child_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
    try expectRect(
        .{ .x = 0, .y = 0, .w = 20, .h = 10 },
        widget.absoluteRect(&tree, child_id),
    );
}

test "container minimum width changes its final border box" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: Id = @enumFromInt(1);

    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 20 },
            .height = .{ .length = 10 },
        },
        .min_size = .{
            .width = .{ .length = 40 },
            .height = .auto,
        },
    });

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 40, .h = 10 });
}

test "container maximum width changes its final border box" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: Id = @enumFromInt(1);

    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 80 },
            .height = .{ .length = 10 },
        },
        .max_size = .{
            .width = .{ .length = 50 },
            .height = .auto,
        },
    });

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
}

test "container aspect ratio changes its final border box" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: Id = @enumFromInt(1);

    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 40 },
            .height = .auto,
        },
        .aspect_ratio = 2,
    });

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 40, .h = 20 });
}

test "absolute auto width fills between paired horizontal insets" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);

    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 8 } },
        .inset = .{
            .top = .{ .length = 4 },
            .right = .{ .length = 15 },
            .bottom = .auto,
            .left = .{ .length = 10 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 30 },
        },
    });
    try tree.appendChild(root_id, absolute_id);

    try layoutContainer(&tree, root_id, 100, 30);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 30 });
    try expectRelative(&tree, absolute_id, .{ .x = 10, .y = 4, .w = 75, .h = 8 });
    try expectRect(
        .{ .x = 10, .y = 4, .w = 75, .h = 8 },
        widget.absoluteRect(&tree, absolute_id),
    );
}

test "rtl absolute child prefers the right inset for its origin" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);

    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 8 } },
        .inset = .{
            .top = .{ .length = 4 },
            .right = .{ .length = 15 },
            .bottom = .auto,
            .left = .{ .length = 10 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .writing_direction = .rtl,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 30 },
        },
    });
    try tree.appendChild(root_id, absolute_id);

    try layoutContainer(&tree, root_id, 100, 30);

    try expectRelative(&tree, absolute_id, .{ .x = 65, .y = 4, .w = 20, .h = 8 });
    try expectRect(
        .{ .x = 65, .y = 4, .w = 20, .h = 8 },
        widget.absoluteRect(&tree, absolute_id),
    );
}

test "auto-width flow root re-resolves after moving below a float" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: Id = @enumFromInt(1);
    const flow_root_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, float_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 50 }, .height = .{ .length = 20 } },
    });
    try appendNode(&tree, flow_root_id, root_id, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 10 } },
        .min_size = .{
            .width = .{ .length = 60 },
            .height = .auto,
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(root_id, float_id);
    try tree.appendChild(root_id, flow_root_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 30 });
    try expectRelative(&tree, float_id, .{ .x = 0, .y = 0, .w = 50, .h = 20 });
    try expectRelative(&tree, flow_root_id, .{ .x = 0, .y = 20, .w = 100, .h = 10 });
}

test "display none parent recursively zeroes its child" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const hidden_id: Id = @enumFromInt(2);
    const visible_id: Id = @enumFromInt(3);
    const root_id: Id = @enumFromInt(4);

    try appendNode(&tree, child_id, hidden_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 25 }, .height = .{ .length = 12 } },
    });
    try appendNode(&tree, hidden_id, root_id, .{
        .display = .none,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 50 }, .height = .{ .length = 40 } },
    });
    try appendNode(&tree, visible_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 6 } },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(hidden_id, child_id);
    try tree.appendChild(root_id, hidden_id);
    try tree.appendChild(root_id, visible_id);
    tree.node(child_id).?.rect = .{ .x = 7, .y = 9, .w = 25, .h = 12 };
    tree.node(hidden_id).?.rect = .{ .x = 3, .y = 4, .w = 50, .h = 40 };

    try layoutContainer(&tree, hidden_id, 50, 40);
    try expectRelative(&tree, child_id, .{});
    try expectRelative(&tree, hidden_id, .{});

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, child_id, .{});
    try expectRelative(&tree, hidden_id, .{});
    try expectRelative(&tree, visible_id, .{ .x = 0, .y = 0, .w = 20, .h = 6 });
    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 6 });
}

test "oversized fixed rtl block keeps its negative right origin" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);

    try appendNode(&tree, child_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 120 }, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .writing_direction = .rtl,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(root_id, child_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    try expectRelative(&tree, child_id, .{ .x = -20, .y = 0, .w = 120, .h = 10 });
    try expectRect(
        .{ .x = -20, .y = 0, .w = 120, .h = 10 },
        widget.absoluteRect(&tree, child_id),
    );
}

test "later float respects the placement ceiling established by a cleared float" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const blocking_float_id: Id = @enumFromInt(1);
    const cleared_float_id: Id = @enumFromInt(2);
    const later_float_id: Id = @enumFromInt(3);
    const root_id: Id = @enumFromInt(4);

    try appendNode(&tree, blocking_float_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 60 }, .height = .{ .length = 20 } },
    });
    try appendNode(&tree, cleared_float_id, root_id, .{
        .display = .block,
        .float = .right,
        .clear = .both,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, later_float_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 40 }, .height = .{ .length = 5 } },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(root_id, blocking_float_id);
    try tree.appendChild(root_id, cleared_float_id);
    try tree.appendChild(root_id, later_float_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(
        &tree,
        blocking_float_id,
        .{ .x = 0, .y = 0, .w = 60, .h = 20 },
    );
    try expectRelative(
        &tree,
        cleared_float_id,
        .{ .x = 80, .y = 20, .w = 20, .h = 10 },
    );
    try expectRelative(
        &tree,
        later_float_id,
        .{ .x = 0, .y = 20, .w = 40, .h = 5 },
    );
}

test "all-auto absolute child keeps its static y after normal flow" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const normal_id: Id = @enumFromInt(1);
    const absolute_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, normal_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 20 } },
    });
    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 10 }, .height = .{ .length = 5 } },
        .inset = .{
            .top = .auto,
            .right = .auto,
            .bottom = .auto,
            .left = .auto,
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 50 } },
    });
    try tree.appendChild(root_id, normal_id);
    try tree.appendChild(root_id, absolute_id);

    try layoutContainer(&tree, root_id, 100, 50);

    try expectRelative(&tree, normal_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
    try expectRelative(&tree, absolute_id, .{ .x = 0, .y = 20, .w = 10, .h = 5 });
}

test "rtl all-auto absolute child uses its static inline end after normal flow" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const normal_id: Id = @enumFromInt(1);
    const absolute_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, normal_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 20 } },
    });
    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 10 }, .height = .{ .length = 5 } },
        .inset = .{
            .top = .auto,
            .right = .auto,
            .bottom = .auto,
            .left = .auto,
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .writing_direction = .rtl,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 50 } },
    });
    try tree.appendChild(root_id, normal_id);
    try tree.appendChild(root_id, absolute_id);

    try layoutContainer(&tree, root_id, 100, 50);

    try expectRelative(&tree, normal_id, .{ .x = 80, .y = 0, .w = 20, .h = 20 });
    try expectRelative(&tree, absolute_id, .{ .x = 90, .y = 20, .w = 10, .h = 5 });
}

test "finite horizontal paired insets that overflow return InvalidStyle" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const extreme_inset: f32 = -3.0e38;
    const absolute_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);

    try std.testing.expect(std.math.isFinite(extreme_inset));
    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 8 } },
        .inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = extreme_inset },
            .bottom = .auto,
            .left = .{ .length = extreme_inset },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 30 } },
    });
    try tree.appendChild(root_id, absolute_id);

    try std.testing.expectError(error.InvalidStyle, layoutContainer(&tree, root_id, 100, 30));
}

test "finite vertical paired insets that overflow return InvalidStyle" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const extreme_inset: f32 = -3.0e38;
    const absolute_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);

    try std.testing.expect(std.math.isFinite(extreme_inset));
    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 10 }, .height = .auto },
        .inset = .{
            .top = .{ .length = extreme_inset },
            .right = .auto,
            .bottom = .{ .length = extreme_inset },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 30 } },
    });
    try tree.appendChild(root_id, absolute_id);

    try std.testing.expectError(error.InvalidStyle, layoutContainer(&tree, root_id, 100, 30));
}

test "prepared pass recursively sizes nested auto-height blocks in relative coordinates" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const descendant_id: Id = @enumFromInt(1);
    const nested_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, descendant_id, nested_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 18 } },
    });
    try appendNode(&tree, nested_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 60 }, .height = .auto },
        .border = .{ .top = 1, .right = 4, .bottom = 2, .left = 3 },
        .padding = .{ .top = 4, .right = 7, .bottom = 5, .left = 6 },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
        .border = .{ .top = 2, .right = 1, .bottom = 3, .left = 4 },
        .padding = .{ .top = 5, .right = 8, .bottom = 7, .left = 6 },
    });
    try tree.appendChild(nested_id, descendant_id);
    try tree.appendChild(root_id, nested_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 47 });
    try expectRelative(&tree, nested_id, .{ .x = 0, .y = 0, .w = 60, .h = 30 });
    try expectRelative(&tree, descendant_id, .{ .x = 0, .y = 0, .w = 20, .h = 18 });
    try expectRect(
        .{ .x = 10, .y = 7, .w = 60, .h = 30 },
        widget.absoluteRect(&tree, nested_id),
    );
    try expectRect(
        .{ .x = 19, .y = 12, .w = 20, .h = 18 },
        widget.absoluteRect(&tree, descendant_id),
    );
}

test "nested auto width resolves percent descendants after margins" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const descendant_id: Id = @enumFromInt(1);
    const nested_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try appendNode(&tree, descendant_id, nested_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .percent = 0.5 }, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, nested_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
        .margin = .{ .left = 10, .right = 10 },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(nested_id, descendant_id);
    try tree.appendChild(root_id, nested_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, nested_id, .{ .x = 10, .y = 0, .w = 80, .h = 10 });
    try expectRelative(&tree, descendant_id, .{ .x = 0, .y = 0, .w = 40, .h = 10 });
}

test "absolute nested block resolves descendants before auto height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const descendant_id: Id = @enumFromInt(1);
    const absolute_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try appendNode(&tree, descendant_id, absolute_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 15 } },
    });
    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 50 }, .height = .auto },
        .inset = .{
            .top = .{ .length = 2 },
            .right = .auto,
            .bottom = .auto,
            .left = .{ .length = 3 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 40 } },
    });
    try tree.appendChild(absolute_id, descendant_id);
    try tree.appendChild(root_id, absolute_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 40), null);

    try expectRelative(&tree, absolute_id, .{ .x = 3, .y = 2, .w = 50, .h = 15 });
    try expectRelative(&tree, descendant_id, .{ .x = 0, .y = 0, .w = 20, .h = 15 });
}

test "absolute auto size measures child before max height and bottom placement" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const absolute_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try appendNode(&tree, child_id, absolute_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 150 } },
    });
    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
        .max_size = .{ .width = .auto, .height = .{ .length = 100 } },
        .inset = .{
            .top = .auto,
            .right = .auto,
            .bottom = .{ .length = 20 },
            .left = .auto,
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 200 } },
    });
    try tree.appendChild(absolute_id, child_id);
    try tree.appendChild(root_id, absolute_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 200), null);

    try expectRelative(&tree, absolute_id, .{ .x = 0, .y = 80, .w = 100, .h = 100 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 100, .h = 150 });
}

test "absolute paired vertical insets clamp auto height before nested layout" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const absolute_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try appendNode(&tree, child_id, absolute_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 150 } },
    });
    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
        .max_size = .{ .width = .auto, .height = .{ .length = 100 } },
        .inset = .{
            .top = .{ .length = 10 },
            .right = .auto,
            .bottom = .{ .length = 10 },
            .left = .auto,
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 200 } },
    });
    try tree.appendChild(absolute_id, child_id);
    try tree.appendChild(root_id, absolute_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(200, 200), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 200, .h = 200 });
    try expectRelative(&tree, absolute_id, .{ .x = 0, .y = 10, .w = 100, .h = 100 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 100, .h = 150 });
}

test "absolute max-width clamp remeasures percentage child aspect-ratio height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const descendant_id: Id = @enumFromInt(1);
    const absolute_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try appendNode(&tree, descendant_id, absolute_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .percent = 1 }, .height = .auto },
        .aspect_ratio = 1,
    });
    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
        .max_size = .{ .width = .{ .length = 100 }, .height = .auto },
        .inset = .{
            .top = .auto,
            .right = .auto,
            .bottom = .{ .length = 20 },
            .left = .auto,
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 300 } },
    });
    try tree.appendChild(absolute_id, descendant_id);
    try tree.appendChild(root_id, absolute_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(200, 300), null);

    try expectRelative(&tree, absolute_id, .{ .x = 0, .y = 180, .w = 100, .h = 100 });
    try expectRelative(&tree, descendant_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
}

test "absolute specified width max-width clamp remeasures percentage child aspect-ratio height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const descendant_id: Id = @enumFromInt(1);
    const absolute_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try appendNode(&tree, descendant_id, absolute_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .percent = 1 }, .height = .auto },
        .aspect_ratio = 1,
    });
    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .auto },
        .max_size = .{ .width = .{ .length = 100 }, .height = .auto },
        .inset = .{
            .top = .auto,
            .right = .auto,
            .bottom = .{ .length = 20 },
            .left = .auto,
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 300 } },
    });
    try tree.appendChild(absolute_id, descendant_id);
    try tree.appendChild(root_id, absolute_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(200, 300), null);

    try expectRelative(&tree, absolute_id, .{ .x = 0, .y = 180, .w = 100, .h = 100 });
    try expectRelative(&tree, descendant_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
}

test "absolute paired insets reserve child margins" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);
    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
        .margin = .{ .top = 3, .right = 5, .bottom = 2, .left = 5 },
        .inset = .{
            .top = .{ .length = 4 },
            .right = .{ .length = 15 },
            .bottom = .{ .length = 6 },
            .left = .{ .length = 10 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 50 } },
    });
    try tree.appendChild(root_id, absolute_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 50), null);

    try expectRelative(&tree, absolute_id, .{ .x = 15, .y = 7, .w = 65, .h = 35 });
}

test "absolute paired horizontal insets split fixed-width auto margins" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);
    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .auto,
            .bottom = .{ .length = 0 },
            .left = .auto,
        },
        .inset = .{
            .top = .{ .length = 4 },
            .right = .{ .length = 10 },
            .bottom = .auto,
            .left = .{ .length = 10 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 50 } },
    });
    try tree.appendChild(root_id, absolute_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 50), null);

    try expectRelative(&tree, absolute_id, .{ .x = 40, .y = 4, .w = 20, .h = 10 });
}

test "absolute paired vertical insets split fixed-height auto margins" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);
    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 10 }, .height = .{ .length = 20 } },
        .margin_inset = .{
            .top = .auto,
            .right = .{ .length = 0 },
            .bottom = .auto,
            .left = .{ .length = 0 },
        },
        .inset = .{
            .top = .{ .length = 10 },
            .right = .auto,
            .bottom = .{ .length = 10 },
            .left = .{ .length = 5 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 60 }, .height = .{ .length = 100 } },
    });
    try tree.appendChild(root_id, absolute_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(60, 100), null);

    try expectRelative(&tree, absolute_id, .{ .x = 5, .y = 40, .w = 10, .h = 20 });
}

test "absolute paired insets leave auto margins zero for auto width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);
    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 8 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .auto,
            .bottom = .{ .length = 0 },
            .left = .auto,
        },
        .inset = .{
            .top = .{ .length = 4 },
            .right = .{ .length = 15 },
            .bottom = .auto,
            .left = .{ .length = 10 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 30 } },
    });
    try tree.appendChild(root_id, absolute_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 30), null);

    try expectRelative(&tree, absolute_id, .{ .x = 10, .y = 4, .w = 75, .h = 8 });
}

test "absolute auto margin stays zero without its corresponding inset" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);
    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .auto,
        },
        .inset = .{
            .top = .{ .length = 4 },
            .right = .auto,
            .bottom = .auto,
            .left = .auto,
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 30 } },
    });
    try tree.appendChild(root_id, absolute_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 30), null);

    try expectRelative(&tree, absolute_id, .{ .x = 0, .y = 4, .w = 20, .h = 10 });
}

test "float margins reserve clear and flow extent" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: Id = @enumFromInt(1);
    const clear_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try appendNode(&tree, float_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .top = 3, .right = 10, .bottom = 5, .left = 5 },
    });
    try appendNode(&tree, clear_id, root_id, .{
        .display = .block,
        .clear = .both,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 40 }, .height = .{ .length = 6 } },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(root_id, float_id);
    try tree.appendChild(root_id, clear_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, float_id, .{ .x = 5, .y = 3, .w = 20, .h = 10 });
    try expectRelative(&tree, clear_id, .{ .x = 0, .y = 18, .w = 40, .h = 6 });
    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 24 });
}

test "floated auto-height block contains its inner float" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const inner_float_id: Id = @enumFromInt(1);
    const outer_float_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try appendNode(&tree, inner_float_id, outer_float_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 10 }, .height = .{ .length = 20 } },
    });
    try appendNode(&tree, outer_float_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 30 }, .height = .auto },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(outer_float_id, inner_float_id);
    try tree.appendChild(root_id, outer_float_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, outer_float_id, .{ .x = 0, .y = 0, .w = 30, .h = 20 });
    try expectRelative(&tree, inner_float_id, .{ .x = 0, .y = 0, .w = 10, .h = 20 });
}

test "nested BFC reflows after descendant height resolves" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_float_id: Id = @enumFromInt(1);
    const second_float_id: Id = @enumFromInt(2);
    const descendant_id: Id = @enumFromInt(3);
    const bfc_id: Id = @enumFromInt(4);
    const root_id: Id = @enumFromInt(5);
    try appendNode(&tree, first_float_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 40 }, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, second_float_id, root_id, .{
        .display = .block,
        .float = .right,
        .clear = .both,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 40 }, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, descendant_id, bfc_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 20 } },
    });
    try appendNode(&tree, bfc_id, root_id, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(bfc_id, descendant_id);
    try tree.appendChild(root_id, first_float_id);
    try tree.appendChild(root_id, second_float_id);
    try tree.appendChild(root_id, bfc_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, bfc_id, .{ .x = 0, .y = 10, .w = 60, .h = 20 });
}
test "root block contains floated height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);
    try appendNode(&tree, float_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 18 } },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(root_id, float_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 18 });
}

test "absolute paired height insets provide descendant percentage basis" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const descendant_id: Id = @enumFromInt(1);
    const absolute_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try appendNode(&tree, descendant_id, absolute_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .percent = 0.5 } },
    });
    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 50 }, .height = .auto },
        .inset = .{
            .top = .{ .length = 10 },
            .right = .auto,
            .bottom = .{ .length = 10 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try tree.appendChild(absolute_id, descendant_id);
    try tree.appendChild(root_id, absolute_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, absolute_id, .{ .x = 0, .y = 10, .w = 50, .h = 80 });
    try expectRelative(&tree, descendant_id, .{ .x = 0, .y = 0, .w = 20, .h = 40 });
}

test "prepared pass applies margins and relative insets without shifting later flow" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const relative_id: Id = @enumFromInt(1);
    const following_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, relative_id, root_id, .{
        .display = .block,
        .position = .relative,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .top = 4, .right = 1, .bottom = 5, .left = 6 },
        .inset = .{
            .top = .{ .length = 3 },
            .right = .auto,
            .bottom = .auto,
            .left = .{ .length = 7 },
        },
    });
    try appendNode(&tree, following_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 15 }, .height = .{ .length = 8 } },
        .margin = .{ .top = 2, .right = 0, .bottom = 4, .left = 3 },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 60 } },
    });
    try tree.appendChild(root_id, relative_id);
    try tree.appendChild(root_id, following_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 60), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 60 });
    try expectRelative(&tree, relative_id, .{ .x = 13, .y = 7, .w = 20, .h = 10 });
    try expectRelative(&tree, following_id, .{ .x = 3, .y = 19, .w = 15, .h = 8 });
}

test "prepared pass collapses positive sibling margins to their maximum" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, first_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .bottom = 20 },
    });
    try appendNode(&tree, second_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .top = 30 },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try tree.appendChild(root_id, first_id);
    try tree.appendChild(root_id, second_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 40, .w = 20, .h = 10 });
}

test "prepared pass collapses negative sibling margins to the most negative" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, first_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 40 } },
        .margin = .{ .bottom = -20 },
    });
    try appendNode(&tree, second_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .top = -30 },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try tree.appendChild(root_id, first_id);
    try tree.appendChild(root_id, second_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 20, .h = 40 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 10, .w = 20, .h = 10 });
}

test "prepared pass collapses mixed sibling margins by their extrema" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, first_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .bottom = -30 },
    });
    try appendNode(&tree, second_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .top = 20 },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try tree.appendChild(root_id, first_id);
    try tree.appendChild(root_id, second_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
}

test "prepared pass resolves percentage sibling margins against width and collapses them" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, first_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .percent = 0.1 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, second_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .percent = 0.15 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 100 } },
    });
    try tree.appendChild(root_id, first_id);
    try tree.appendChild(root_id, second_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(200, 100), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 200, .h = 100 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 40, .w = 20, .h = 10 });
}

test "prepared pass collapses larger parent top margin through first child" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const parent_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, child_id, parent_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .top = 20 },
    });
    try appendNode(&tree, parent_id, root_id, .{
        .display = .block,
        .position = .relative,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 60 }, .height = .auto },
        .margin = .{ .top = 30 },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try tree.appendChild(parent_id, child_id);
    try tree.appendChild(root_id, parent_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, parent_id, .{ .x = 0, .y = 30, .w = 60, .h = 10 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
    try expectRect(
        .{ .x = 0, .y = 30, .w = 60, .h = 10 },
        widget.absoluteRect(&tree, parent_id),
    );
    try expectRect(
        .{ .x = 0, .y = 30, .w = 20, .h = 10 },
        widget.absoluteRect(&tree, child_id),
    );
}

test "prepared pass collapses larger first-child top margin through parent" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const parent_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, child_id, parent_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .top = 30 },
    });
    try appendNode(&tree, parent_id, root_id, .{
        .display = .block,
        .position = .relative,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 60 }, .height = .auto },
        .margin = .{ .top = 20 },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try tree.appendChild(parent_id, child_id);
    try tree.appendChild(root_id, parent_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, parent_id, .{ .x = 0, .y = 30, .w = 60, .h = 10 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
    try expectRect(
        .{ .x = 0, .y = 30, .w = 60, .h = 10 },
        widget.absoluteRect(&tree, parent_id),
    );
    try expectRect(
        .{ .x = 0, .y = 30, .w = 20, .h = 10 },
        widget.absoluteRect(&tree, child_id),
    );
}

test "prepared pass combines mixed parent and first-child top margins" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const parent_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, child_id, parent_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .top = 30 },
    });
    try appendNode(&tree, parent_id, root_id, .{
        .display = .block,
        .position = .relative,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 60 }, .height = .auto },
        .margin = .{ .top = -10 },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try tree.appendChild(parent_id, child_id);
    try tree.appendChild(root_id, parent_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, parent_id, .{ .x = 0, .y = 20, .w = 60, .h = 10 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
    try expectRect(
        .{ .x = 0, .y = 20, .w = 60, .h = 10 },
        widget.absoluteRect(&tree, parent_id),
    );
    try expectRect(
        .{ .x = 0, .y = 20, .w = 20, .h = 10 },
        widget.absoluteRect(&tree, child_id),
    );
}

test "prepared pass collapses last-child bottom margin through auto-height parent" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const last_id: Id = @enumFromInt(2);
    const parent_id: Id = @enumFromInt(3);
    const following_id: Id = @enumFromInt(4);
    const root_id: Id = @enumFromInt(5);

    try appendNode(&tree, first_id, parent_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, last_id, parent_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .bottom = 30 },
    });
    try appendNode(&tree, parent_id, root_id, .{
        .display = .block,
        .position = .relative,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 60 }, .height = .auto },
        .margin = .{ .bottom = 20 },
    });
    try appendNode(&tree, following_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try tree.appendChild(parent_id, first_id);
    try tree.appendChild(parent_id, last_id);
    try tree.appendChild(root_id, parent_id);
    try tree.appendChild(root_id, following_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, parent_id, .{ .x = 0, .y = 0, .w = 60, .h = 20 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
    try expectRelative(&tree, last_id, .{ .x = 0, .y = 10, .w = 20, .h = 10 });
    try expectRelative(&tree, following_id, .{ .x = 0, .y = 50, .w = 20, .h = 10 });
    try expectRect(
        .{ .x = 0, .y = 0, .w = 60, .h = 20 },
        widget.absoluteRect(&tree, parent_id),
    );
    try expectRect(
        .{ .x = 0, .y = 10, .w = 20, .h = 10 },
        widget.absoluteRect(&tree, last_id),
    );
    try expectRect(
        .{ .x = 0, .y = 50, .w = 20, .h = 10 },
        widget.absoluteRect(&tree, following_id),
    );
}

test "prepared pass keeps first-child top margin inside flow root" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const parent_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, child_id, parent_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .top = 30 },
    });
    try appendNode(&tree, parent_id, root_id, .{
        .display = .flow_root,
        .position = .relative,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 60 }, .height = .auto },
        .margin = .{ .top = 20 },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    try tree.appendChild(parent_id, child_id);
    try tree.appendChild(root_id, parent_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, parent_id, .{ .x = 0, .y = 20, .w = 60, .h = 40 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 30, .w = 20, .h = 10 });
    try expectRect(
        .{ .x = 0, .y = 20, .w = 60, .h = 40 },
        widget.absoluteRect(&tree, parent_id),
    );
    try expectRect(
        .{ .x = 0, .y = 50, .w = 20, .h = 10 },
        widget.absoluteRect(&tree, child_id),
    );
}

test "relative percentage insets use container width and zero height basis" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const relative_id: Id = @enumFromInt(1);
    const following_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, relative_id, root_id, .{
        .display = .block,
        .position = .relative,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .inset = .{
            .top = .{ .percent = 0.5 },
            .right = .auto,
            .bottom = .auto,
            .left = .{ .percent = 0.1 },
        },
    });
    try appendNode(&tree, following_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 15 }, .height = .{ .length = 8 } },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 60 } },
    });
    try tree.appendChild(root_id, relative_id);
    try tree.appendChild(root_id, following_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 60), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 60 });
    try expectRelative(&tree, relative_id, .{ .x = 10, .y = 0, .w = 20, .h = 10 });
    try expectRelative(&tree, following_id, .{ .x = 0, .y = 10, .w = 15, .h = 8 });
}

test "prepared pass centers fixed-width block with horizontal auto margins" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);

    try appendNode(&tree, child_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .auto,
            .bottom = .{ .length = 0 },
            .left = .auto,
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 30 } },
    });
    try tree.appendChild(root_id, child_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 30), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 30 });
    try expectRelative(&tree, child_id, .{ .x = 40, .y = 0, .w = 20, .h = 10 });
}

test "prepared pass gives one auto margin all remaining inline space" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);

    try appendNode(&tree, child_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .auto,
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 30 } },
    });
    try tree.appendChild(root_id, child_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 30), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 30 });
    try expectRelative(&tree, child_id, .{ .x = 80, .y = 0, .w = 20, .h = 10 });
}

test "prepared pass uses physical auto-margin coordinates under rtl" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);

    try appendNode(&tree, child_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .auto,
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .writing_direction = .rtl,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 30 } },
    });
    try tree.appendChild(root_id, child_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 30), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 30 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
}

test "prepared pass gives auto-width block no auto-margin expansion" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);

    try appendNode(&tree, child_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .auto,
            .right = .auto,
            .bottom = .auto,
            .left = .auto,
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 30 } },
    });
    try tree.appendChild(root_id, child_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 30), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 30 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
}

test "adjacent positive vertical margins collapse to their maximum" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try appendNode(&tree, first_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .top = 10, .bottom = 20 },
    });
    try appendNode(&tree, second_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .top = 30 },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(root_id, first_id);
    try tree.appendChild(root_id, second_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, first_id, .{ .x = 0, .y = 10, .w = 20, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 50, .w = 20, .h = 10 });
    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 60 });
}

test "adjacent negative vertical margins collapse to the most negative" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try appendNode(&tree, first_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .top = 10, .bottom = -20 },
    });
    try appendNode(&tree, second_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .top = -5 },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(root_id, first_id);
    try tree.appendChild(root_id, second_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, first_id, .{ .x = 0, .y = 10, .w = 20, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
}

test "percentage vertical sibling margins collapse against parent width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try appendNode(&tree, first_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .percent = 0.1 },
            .right = .{ .length = 0 },
            .bottom = .{ .percent = 0.1 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, second_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .percent = 0.15 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .auto },
    });
    try tree.appendChild(root_id, first_id);
    try tree.appendChild(root_id, second_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(200, 100), null);

    try expectRelative(&tree, first_id, .{ .x = 0, .y = 20, .w = 20, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 60, .w = 20, .h = 10 });
}

test "ordinary block collapses its first child top margin" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const inner_id: Id = @enumFromInt(1);
    const outer_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try appendNode(&tree, inner_id, outer_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .top = 10 },
    });
    try appendNode(&tree, outer_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 40 }, .height = .auto },
        .margin = .{ .top = 5 },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(outer_id, inner_id);
    try tree.appendChild(root_id, outer_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, outer_id, .{ .x = 0, .y = 10, .w = 40, .h = 10 });
    try expectRelative(&tree, inner_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
    try expectRect(
        .{ .x = 0, .y = 10, .w = 20, .h = 10 },
        widget.absoluteRect(&tree, inner_id),
    );
}

test "ordinary block collapses its last child bottom margin" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const inner_id: Id = @enumFromInt(1);
    const outer_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try appendNode(&tree, inner_id, outer_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .bottom = 10 },
    });
    try appendNode(&tree, outer_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 40 }, .height = .auto },
        .margin = .{ .bottom = 5 },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(outer_id, inner_id);
    try tree.appendChild(root_id, outer_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, outer_id, .{ .x = 0, .y = 0, .w = 40, .h = 10 });
    try expectRelative(&tree, inner_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
}

test "top border blocks parent first-child margin collapse" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const inner_id: Id = @enumFromInt(1);
    const outer_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try appendNode(&tree, inner_id, outer_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin = .{ .top = 10 },
    });
    try appendNode(&tree, outer_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 40 }, .height = .auto },
        .margin = .{ .top = 5 },
        .border = .{ .top = 1 },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(outer_id, inner_id);
    try tree.appendChild(root_id, outer_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);

    try expectRelative(&tree, outer_id, .{ .x = 0, .y = 5, .w = 40, .h = 21 });
    try expectRelative(&tree, inner_id, .{ .x = 0, .y = 10, .w = 20, .h = 10 });
}

test "prepared pass updates scroll limits after recursive child geometry" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var scroll_state: widget.ScrollState = .{ .max_offset = .{ 99, 99 } };
    const descendant_id: Id = @enumFromInt(1);
    const nested_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, descendant_id, nested_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 24 }, .height = .{ .length = 45 } },
    });
    try appendNode(&tree, nested_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 70 }, .height = .auto },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 50 }, .height = .{ .length = 30 } },
        .padding = .{ .top = 5, .right = 5, .bottom = 5, .left = 5 },
        .overflow = .{ .width = .scroll, .height = .scroll },
    });
    tree.node(root_id).?.scroll = .{ .state = &scroll_state, .axis = .both };
    try tree.appendChild(nested_id, descendant_id);
    try tree.appendChild(root_id, nested_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(50, 30), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 50, .h = 30 });
    try expectRelative(&tree, nested_id, .{ .x = 0, .y = 0, .w = 70, .h = 45 });
    try expectRelative(&tree, descendant_id, .{ .x = 0, .y = 0, .w = 24, .h = 45 });
    try std.testing.expectEqual([2]f32{ 30, 25 }, scroll_state.max_offset);
}

test "prepared pass classifies once and lays out many containers without allocation" {
    const hidden_count: usize = 128;
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var hidden_ids: [hidden_count]Id = undefined;
    var child_ids: [hidden_count]Id = undefined;
    for (0..hidden_count) |index| {
        const child_id: Id = @enumFromInt(@as(u32, @intCast(index * 2 + 1)));
        const hidden_id: Id = @enumFromInt(@as(u32, @intCast(index * 2 + 2)));
        child_ids[index] = child_id;
        hidden_ids[index] = hidden_id;

        try appendNode(&tree, child_id, hidden_id, .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .length = 10 }, .height = .{ .length = 5 } },
        });
        try appendNode(&tree, hidden_id, .root, .{
            .display = .none,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        });
        try tree.appendChild(hidden_id, child_id);
    }

    const root_id: Id = @enumFromInt(@as(u32, @intCast(hidden_count * 2 + 1)));
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    for (hidden_ids) |hidden_id| {
        try tree.appendChild(root_id, hidden_id);
    }

    for (hidden_ids, child_ids, 0..) |hidden_id, child_id, index| {
        tree.node(hidden_id).?.rect = .{
            .x = @floatFromInt(index),
            .y = 2,
            .w = 20,
            .h = 10,
        };
        tree.node(child_id).?.rect = .{
            .x = 3,
            .y = 4,
            .w = 10,
            .h = 5,
        };
        tree.node(hidden_id).?.resolved_box_edges = .{
            .border = .{},
            .padding = .{},
        };
        tree.node(child_id).?.resolved_box_edges = .{
            .border = .{},
            .padding = .{},
        };
    }

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    tree.allocator = failing_allocator.allocator();

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 100), null);
    try pass.layoutContainer(hidden_ids[0], definiteContext(20, 10), null);

    try std.testing.expectEqual(@as(usize, 0), failing_allocator.alloc_index);
    for (hidden_ids, child_ids) |hidden_id, child_id| {
        try expectRelative(&tree, hidden_id, .{});
        try expectRelative(&tree, child_id, .{});
        try std.testing.expect(tree.nodeConst(hidden_id).?.layout_hidden);
        try std.testing.expect(tree.nodeConst(child_id).?.layout_hidden);
        try std.testing.expect(tree.nodeConst(hidden_id).?.resolved_box_edges == null);
        try std.testing.expect(tree.nodeConst(child_id).?.resolved_box_edges == null);
    }

    tree.node(hidden_ids[0]).?.style.display = .block;
    try std.testing.expect(tree.nodeConst(hidden_ids[0]).?.layout_hidden);
    try std.testing.expect(tree.nodeConst(child_ids[0]).?.layout_hidden);

    const refreshed_pass = try block_float.LayoutPass.init(&tree);
    try std.testing.expect(!tree.nodeConst(hidden_ids[0]).?.layout_hidden);
    try std.testing.expect(!tree.nodeConst(child_ids[0]).?.layout_hidden);
    try refreshed_pass.layoutContainer(root_id, definiteContext(100, 100), null);
    try refreshed_pass.layoutContainer(hidden_ids[0], definiteContext(20, 10), null);

    try expectRelative(&tree, child_ids[0], .{ .x = 0, .y = 0, .w = 10, .h = 5 });
    try std.testing.expectEqual(@as(usize, 0), failing_allocator.alloc_index);
}

test "block: vertical percentage padding and margin resolve against containing block width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);

    try appendNode(&tree, child_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 50 } },
        .padding_inset = .{
            .top = .{ .percent = 0.10 },
            .right = .{ .percent = 0.05 },
            .bottom = .{ .percent = 0.05 },
            .left = .{ .percent = 0.05 },
        },
        .margin_inset = .{
            .top = .{ .percent = 0.10 },
            .right = .{ .percent = 0.025 },
            .bottom = .{ .percent = 0.05 },
            .left = .{ .percent = 0.025 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 400 }, .height = .{ .length = 200 } },
    });
    try tree.appendChild(root_id, child_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(400, 200), null);

    // Padding should resolve against width (400): top = 40, bottom = 20, left = 20, right = 20
    const resolved_padding = tree.nodeConst(child_id).?.resolved_box_edges.?.padding;
    try std.testing.expectApproxEqAbs(@as(f32, 40), resolved_padding.top, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), resolved_padding.bottom, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), resolved_padding.left, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), resolved_padding.right, 0.001);

    // Margin should resolve against width (400): top = 40, left = 10
    // Border-box height is max(specified 50, vertical padding 60) = 60
    try expectRelative(&tree, child_id, .{ .x = 10, .y = 40, .w = 200, .h = 60 });
}

test "block: empty block self-collapsing margin chains" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const empty_id: Id = @enumFromInt(2);
    const third_id: Id = @enumFromInt(3);
    const root_id: Id = @enumFromInt(4);

    try appendNode(&tree, first_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 50 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 20 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, empty_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 0 } },
        .margin_inset = .{
            .top = .{ .length = 30 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 40 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, third_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 50 } },
        .margin_inset = .{
            .top = .{ .length = 10 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .auto },
    });
    try tree.appendChild(root_id, first_id);
    try tree.appendChild(root_id, empty_id);
    try tree.appendChild(root_id, third_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(200, 100), null);

    // first block: y = 0, h = 50
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 200, .h = 50 });
    // empty block: top border edge at 50 + max(20, 30) = 80, h = 0
    try expectRelative(&tree, empty_id, .{ .x = 0, .y = 80, .w = 200, .h = 0 });
    // third block: collapsed margin is max(20, 30, 40, 10) = 40, so y = 50 + 40 = 90
    try expectRelative(&tree, third_id, .{ .x = 0, .y = 90, .w = 200, .h = 50 });
    // container height: 90 + 50 = 140
    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 200, .h = 140 });
}

test "block: multiple empty blocks with mixed margins collapse through to sibling" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const empty1_id: Id = @enumFromInt(2);
    const empty2_id: Id = @enumFromInt(3);
    const third_id: Id = @enumFromInt(4);
    const root_id: Id = @enumFromInt(5);

    try appendNode(&tree, first_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 40 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 15 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, empty1_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 0 } },
        .margin_inset = .{
            .top = .{ .length = 25 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = -10 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, empty2_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 0 } },
        .margin_inset = .{
            .top = .{ .length = -20 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 30 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, third_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 40 } },
        .margin_inset = .{
            .top = .{ .length = 10 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .auto },
    });
    try tree.appendChild(root_id, first_id);
    try tree.appendChild(root_id, empty1_id);
    try tree.appendChild(root_id, empty2_id);
    try tree.appendChild(root_id, third_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(200, 100), null);

    // Margins: positive max(15, 25, 30, 10) = 30, negative min(0, -10, -20) = -20 => resolved margin = 10
    // first: y = 0, h = 40
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 200, .h = 40 });
    // third: y = 40 + 10 = 50, h = 40
    try expectRelative(&tree, third_id, .{ .x = 0, .y = 50, .w = 200, .h = 40 });
    // root: h = 50 + 40 = 90
    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 200, .h = 90 });
}

test "block: float margin clearance prevents margin collapsing with preceding content" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: Id = @enumFromInt(1);
    const first_id: Id = @enumFromInt(2);
    const clear_id: Id = @enumFromInt(3);
    const root_id: Id = @enumFromInt(4);

    try appendNode(&tree, float_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 50 }, .height = .{ .length = 100 } },
    });
    try appendNode(&tree, first_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 30 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 20 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, clear_id, root_id, .{
        .display = .block,
        .clear = .left,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 40 } },
        .margin_inset = .{
            .top = .{ .length = 10 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .auto },
    });
    try tree.appendChild(root_id, float_id);
    try tree.appendChild(root_id, first_id);
    try tree.appendChild(root_id, clear_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(200, 100), null);

    // float: y = 0, h = 100
    try expectRelative(&tree, float_id, .{ .x = 0, .y = 0, .w = 50, .h = 100 });
    // first: y = 0, h = 30
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 200, .h = 30 });
    // clear block: cleared below float (100) with top margin 10, y = 110
    try expectRelative(&tree, clear_id, .{ .x = 0, .y = 110, .w = 200, .h = 40 });
    // root height: 110 + 40 = 150
    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 200, .h = 150 });
}

test "block: block child with width: min-content sizes to child intrinsic content bounds rather than parent width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const inner_id: Id = @enumFromInt(1);
    const block_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, inner_id, block_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 80 }, .height = .{ .length = 30 } },
    });
    try appendNode(&tree, block_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .min_content, .height = .auto },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 300 }, .height = .{ .length = 200 } },
    });
    try tree.appendChild(root_id, block_id);
    try tree.appendChild(block_id, inner_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(300, 200), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 300, .h = 200 });
    try expectRelative(&tree, block_id, .{ .x = 0, .y = 0, .w = 80, .h = 30 });
    try expectRelative(&tree, inner_id, .{ .x = 0, .y = 0, .w = 80, .h = 30 });
}

test "block: block child with width: max-content sizes to child intrinsic content bounds rather than parent width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_inner_id: Id = @enumFromInt(1);
    const second_inner_id: Id = @enumFromInt(2);
    const block_id: Id = @enumFromInt(3);
    const root_id: Id = @enumFromInt(4);

    try appendNode(&tree, first_inner_id, block_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 60 }, .height = .{ .length = 25 } },
    });
    try appendNode(&tree, second_inner_id, block_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 120 }, .height = .{ .length = 35 } },
    });
    try appendNode(&tree, block_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .max_content, .height = .auto },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 400 }, .height = .{ .length = 200 } },
    });
    try tree.appendChild(root_id, block_id);
    try tree.appendChild(block_id, first_inner_id);
    try tree.appendChild(block_id, second_inner_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(400, 200), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 400, .h = 200 });
    try expectRelative(&tree, block_id, .{ .x = 0, .y = 0, .w = 120, .h = 60 });
    try expectRelative(&tree, first_inner_id, .{ .x = 0, .y = 0, .w = 60, .h = 25 });
    try expectRelative(&tree, second_inner_id, .{ .x = 0, .y = 25, .w = 120, .h = 35 });
}

test "block: block child with width: fit-content clamped by containing block width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const inner_id: Id = @enumFromInt(1);
    const block_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try appendNode(&tree, inner_id, block_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 150 }, .height = .{ .length = 40 } },
    });
    try appendNode(&tree, block_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .fit_content = null }, .height = .auto },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 200 } },
    });
    try tree.appendChild(root_id, block_id);
    try tree.appendChild(block_id, inner_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(100, 200), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 200 });
    try expectRelative(&tree, block_id, .{ .x = 0, .y = 0, .w = 100, .h = 40 });
}
