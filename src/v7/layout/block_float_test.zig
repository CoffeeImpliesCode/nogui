//! Specifies the direct-tree contract for block, float, clear, absolute, and none layout.

const std = @import("std");
const FrameNodeId = @import("../id.zig").FrameNodeId;
const style = @import("../style.zig");
const widget = @import("../widget.zig");
const block_float = @import("block_float.zig");
const layout_context = @import("context.zig");
const layout = @import("root.zig");
const sizing = @import("sizing.zig");

const Rect = widget.Rect;
const Style = style.Style;
const WidgetKind = widget.WidgetKind;
const WidgetTree = widget.WidgetTree;

fn appendNode(tree: *WidgetTree, id: FrameNodeId, parent: FrameNodeId, node_style: Style) !void {
    const kind: WidgetKind = switch (node_style.display) {
        .flex => .{ .row = .{} },
        .block, .flow_root, .grid => .{ .column = .{} },
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

fn layoutContainer(tree: *WidgetTree, container_id: FrameNodeId, width: f32, height: f32) !void {
    const measure: ?layout_context.MeasureSource = null;
    try block_float.layoutContainer(
        tree,
        container_id,
        definiteContext(width, height),
        measure,
    );
}

fn layoutTree(tree: *WidgetTree, width: f32, height: f32) !void {
    try layout.layoutTree(tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = width, .height = height },
        .measure = null,
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

fn intrinsicAspectMeasure(
    _: ?*anyopaque,
    _: []const u8,
    _: layout_context.MeasureInput,
) layout_context.LayoutError!layout_context.TextMeasurement {
    return .{ .width = 360, .height = 10 };
}

const intrinsic_aspect_source: layout_context.MeasureSource = .{
    .callback = intrinsicAspectMeasure,
};

test "absolute leaf aspect ratio transfers after width and height constraints" {
    const scenarios = [_]struct {
        min_size: style.DimensionSize,
        max_size: style.DimensionSize,
        aspect_ratio: f32,
        expected: Rect,
    }{
        .{
            .min_size = .{ .width = .auto, .height = .auto },
            .max_size = .{ .width = .{ .length = 50 }, .height = .auto },
            .aspect_ratio = 3,
            .expected = .{ .x = 0, .y = 0, .w = 50, .h = 50.0 / 3.0 },
        },
        .{
            .min_size = .{ .width = .auto, .height = .auto },
            .max_size = .{ .width = .auto, .height = .{ .length = 50 } },
            .aspect_ratio = 0.5,
            .expected = .{ .x = 0, .y = 0, .w = 25, .h = 50 },
        },
        .{
            .min_size = .{ .width = .auto, .height = .auto },
            .max_size = .{
                .width = .{ .length = 50 },
                .height = .{ .length = 100 },
            },
            .aspect_ratio = 3,
            .expected = .{ .x = 0, .y = 0, .w = 50, .h = 50.0 / 3.0 },
        },
        .{
            .min_size = .{ .width = .{ .length = 60 }, .height = .auto },
            .max_size = .{ .width = .{ .length = 50 }, .height = .auto },
            .aspect_ratio = 3,
            .expected = .{ .x = 0, .y = 0, .w = 60, .h = 20 },
        },
    };

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const absolute_id: FrameNodeId = @enumFromInt(1);
        const root_id: FrameNodeId = @enumFromInt(2);
        try tree.appendNode(.{
            .id = absolute_id,
            .kind = .{ .label = .{ .text = "intrinsic" } },
            .parent = root_id,
            .style = .{
                .display = .block,
                .position = .absolute,
                .box_sizing = .border_box,
                .size = .{ .width = .auto, .height = .auto },
                .min_size = scenario.min_size,
                .max_size = scenario.max_size,
                .aspect_ratio = scenario.aspect_ratio,
            },
        });
        try appendNode(&tree, root_id, .root, .{
            .display = .flow_root,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 400 },
                .height = .{ .length = 300 },
            },
        });
        try tree.appendChild(root_id, absolute_id);

        try block_float.layoutContainer(
            &tree,
            root_id,
            definiteContext(400, 300),
            intrinsic_aspect_source,
        );

        try expectRelative(&tree, absolute_id, scenario.expected);
    }
}

test "flow root clears a left float before the following block" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: FrameNodeId = @enumFromInt(1);
    const clear_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

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

test "absolute child uses containing padding box without advancing block flow" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: FrameNodeId = @enumFromInt(1);
    const normal_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

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

    try expectRelative(&tree, absolute_id, .{ .x = 2, .y = 5, .w = 10, .h = 8 });
    try expectRelative(&tree, normal_id, .{ .x = 0, .y = 0, .w = 20, .h = 6 });
    try expectRect(
        .{ .x = 10, .y = 11, .w = 10, .h = 8 },
        widget.absoluteRect(&tree, absolute_id),
    );
}

test "display none receives a zero rect and contributes no block height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const hidden_id: FrameNodeId = @enumFromInt(1);
    const visible_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

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

    const child_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

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

    const normal_id: FrameNodeId = @enumFromInt(1);
    const absolute_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

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

    const absolute_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

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

    const float_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

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

        const float_id: FrameNodeId = @enumFromInt(1);
        const container_id: FrameNodeId = @enumFromInt(2);
        const root_id: FrameNodeId = @enumFromInt(3);

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

    const child_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

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

test "auto block width transfers through aspect ratio" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

    try appendNode(&tree, child_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
        .aspect_ratio = 2,
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 50 }, .height = .auto },
    });
    try tree.appendChild(root_id, child_id);

    try layoutContainer(&tree, root_id, 50, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 50, .h = 25 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 50, .h = 25 });
}

test "indefinite percentage height behaves as auto" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

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

    const root_id: FrameNodeId = @enumFromInt(1);

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

    const root_id: FrameNodeId = @enumFromInt(1);

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

    const root_id: FrameNodeId = @enumFromInt(1);

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

    const absolute_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

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

    const absolute_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

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

    const float_id: FrameNodeId = @enumFromInt(1);
    const flow_root_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

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

    const child_id: FrameNodeId = @enumFromInt(1);
    const hidden_id: FrameNodeId = @enumFromInt(2);
    const visible_id: FrameNodeId = @enumFromInt(3);
    const root_id: FrameNodeId = @enumFromInt(4);

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
    const child = tree.node(child_id) orelse return error.TestUnexpectedResult;
    child.rect = .{ .x = 7, .y = 9, .w = 25, .h = 12 };
    const hidden = tree.node(hidden_id) orelse return error.TestUnexpectedResult;
    hidden.rect = .{ .x = 3, .y = 4, .w = 50, .h = 40 };

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

    const child_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

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

    const blocking_float_id: FrameNodeId = @enumFromInt(1);
    const cleared_float_id: FrameNodeId = @enumFromInt(2);
    const later_float_id: FrameNodeId = @enumFromInt(3);
    const root_id: FrameNodeId = @enumFromInt(4);

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

    const normal_id: FrameNodeId = @enumFromInt(1);
    const absolute_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

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

    const normal_id: FrameNodeId = @enumFromInt(1);
    const absolute_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

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
    const absolute_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

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
    const absolute_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

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

    const descendant_id: FrameNodeId = @enumFromInt(1);
    const nested_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, descendant_id, nested_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 18 } },
    });
    try appendNode(&tree, nested_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 60 }, .height = .auto },
        .border_inset = .{
            .top = .{ .length = 1 },
            .right = .{ .length = 4 },
            .bottom = .{ .length = 2 },
            .left = .{ .length = 3 },
        },
        .padding_inset = .{
            .top = .{ .length = 4 },
            .right = .{ .length = 7 },
            .bottom = .{ .length = 5 },
            .left = .{ .length = 6 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
        .border_inset = .{
            .top = .{ .length = 2 },
            .right = .{ .length = 1 },
            .bottom = .{ .length = 3 },
            .left = .{ .length = 4 },
        },
        .padding_inset = .{
            .top = .{ .length = 5 },
            .right = .{ .length = 8 },
            .bottom = .{ .length = 7 },
            .left = .{ .length = 6 },
        },
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

    const descendant_id: FrameNodeId = @enumFromInt(1);
    const nested_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);
    try appendNode(&tree, descendant_id, nested_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .percent = 0.5 }, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, nested_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 10 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 10 },
        },
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

    const descendant_id: FrameNodeId = @enumFromInt(1);
    const absolute_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);
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

    const child_id: FrameNodeId = @enumFromInt(1);
    const absolute_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);
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

    const child_id: FrameNodeId = @enumFromInt(1);
    const absolute_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);
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

    const descendant_id: FrameNodeId = @enumFromInt(1);
    const absolute_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);
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

    const descendant_id: FrameNodeId = @enumFromInt(1);
    const absolute_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);
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

    const absolute_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);
    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
        .margin_inset = .{
            .top = .{ .length = 3 },
            .right = .{ .length = 5 },
            .bottom = .{ .length = 2 },
            .left = .{ .length = 5 },
        },
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

    const absolute_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);
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

test "absolute paired horizontal auto margins split positive free space" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);
    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 60 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .auto,
            .bottom = .{ .length = 0 },
            .left = .auto,
        },
        .inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .auto,
            .left = .{ .length = 0 },
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

    try expectRelative(&tree, absolute_id, .{ .x = 20, .y = 0, .w = 60, .h = 10 });
}

test "absolute paired vertical insets split fixed-height auto margins" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);
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

    const absolute_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);
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

    const absolute_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);
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

    const float_id: FrameNodeId = @enumFromInt(1);
    const clear_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);
    try appendNode(&tree, float_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 3 },
            .right = .{ .length = 10 },
            .bottom = .{ .length = 5 },
            .left = .{ .length = 5 },
        },
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

    const inner_float_id: FrameNodeId = @enumFromInt(1);
    const outer_float_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);
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

    const first_float_id: FrameNodeId = @enumFromInt(1);
    const second_float_id: FrameNodeId = @enumFromInt(2);
    const descendant_id: FrameNodeId = @enumFromInt(3);
    const bfc_id: FrameNodeId = @enumFromInt(4);
    const root_id: FrameNodeId = @enumFromInt(5);
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

    const float_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);
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

    const descendant_id: FrameNodeId = @enumFromInt(1);
    const absolute_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);
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

    const relative_id: FrameNodeId = @enumFromInt(1);
    const following_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, relative_id, root_id, .{
        .display = .block,
        .position = .relative,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 4 },
            .right = .{ .length = 1 },
            .bottom = .{ .length = 5 },
            .left = .{ .length = 6 },
        },
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
        .margin_inset = .{
            .top = .{ .length = 2 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 4 },
            .left = .{ .length = 3 },
        },
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

    const first_id: FrameNodeId = @enumFromInt(1);
    const second_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, first_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 20 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, second_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 30 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
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

    const first_id: FrameNodeId = @enumFromInt(1);
    const second_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, first_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 40 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = -20 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, second_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = -30 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
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

    const first_id: FrameNodeId = @enumFromInt(1);
    const second_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, first_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = -30 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, second_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 20 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
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

    const first_id: FrameNodeId = @enumFromInt(1);
    const second_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

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

    const child_id: FrameNodeId = @enumFromInt(1);
    const parent_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, child_id, parent_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 20 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, parent_id, root_id, .{
        .display = .block,
        .position = .relative,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 60 }, .height = .auto },
        .margin_inset = .{
            .top = .{ .length = 30 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
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

    const child_id: FrameNodeId = @enumFromInt(1);
    const parent_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, child_id, parent_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 30 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, parent_id, root_id, .{
        .display = .block,
        .position = .relative,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 60 }, .height = .auto },
        .margin_inset = .{
            .top = .{ .length = 20 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
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

    const child_id: FrameNodeId = @enumFromInt(1);
    const parent_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, child_id, parent_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 30 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, parent_id, root_id, .{
        .display = .block,
        .position = .relative,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 60 }, .height = .auto },
        .margin_inset = .{
            .top = .{ .length = -10 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
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

    const first_id: FrameNodeId = @enumFromInt(1);
    const last_id: FrameNodeId = @enumFromInt(2);
    const parent_id: FrameNodeId = @enumFromInt(3);
    const following_id: FrameNodeId = @enumFromInt(4);
    const root_id: FrameNodeId = @enumFromInt(5);

    try appendNode(&tree, first_id, parent_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, last_id, parent_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 30 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, parent_id, root_id, .{
        .display = .block,
        .position = .relative,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 60 }, .height = .auto },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 20 },
            .left = .{ .length = 0 },
        },
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

    const child_id: FrameNodeId = @enumFromInt(1);
    const parent_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, child_id, parent_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 30 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, parent_id, root_id, .{
        .display = .flow_root,
        .position = .relative,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 60 }, .height = .auto },
        .margin_inset = .{
            .top = .{ .length = 20 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
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

    const relative_id: FrameNodeId = @enumFromInt(1);
    const following_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

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

    const child_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

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

    const child_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

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

    const child_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

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

    const child_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

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

    const first_id: FrameNodeId = @enumFromInt(1);
    const second_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);
    try appendNode(&tree, first_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 10 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 20 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, second_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 30 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
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

    const first_id: FrameNodeId = @enumFromInt(1);
    const second_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);
    try appendNode(&tree, first_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 10 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = -20 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, second_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = -5 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
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

    const first_id: FrameNodeId = @enumFromInt(1);
    const second_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);
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

    const inner_id: FrameNodeId = @enumFromInt(1);
    const outer_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);
    try appendNode(&tree, inner_id, outer_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 10 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, outer_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 40 }, .height = .auto },
        .margin_inset = .{
            .top = .{ .length = 5 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
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

    const inner_id: FrameNodeId = @enumFromInt(1);
    const outer_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);
    try appendNode(&tree, inner_id, outer_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 10 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, outer_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 40 }, .height = .auto },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 5 },
            .left = .{ .length = 0 },
        },
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

    const inner_id: FrameNodeId = @enumFromInt(1);
    const outer_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);
    try appendNode(&tree, inner_id, outer_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 10 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, outer_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 40 }, .height = .auto },
        .margin_inset = .{
            .top = .{ .length = 5 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
        .border_inset = .{
            .top = .{ .length = 1 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
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
    const descendant_id: FrameNodeId = @enumFromInt(1);
    const nested_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

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
        .padding_inset = .{
            .top = .{ .length = 5 },
            .right = .{ .length = 5 },
            .bottom = .{ .length = 5 },
            .left = .{ .length = 5 },
        },
        .overflow = .{ .width = .scroll, .height = .scroll },
    });
    const root = tree.node(root_id) orelse return error.TestUnexpectedResult;
    root.scroll = .{ .state = &scroll_state, .axis = .both };
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

    var hidden_ids: [hidden_count]FrameNodeId = undefined;
    var child_ids: [hidden_count]FrameNodeId = undefined;
    for (0..hidden_count) |index| {
        const child_id: FrameNodeId = @enumFromInt(@as(u32, @intCast(index * 2 + 1)));
        const hidden_id: FrameNodeId = @enumFromInt(@as(u32, @intCast(index * 2 + 2)));
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

    const root_id: FrameNodeId = @enumFromInt(@as(u32, @intCast(hidden_count * 2 + 1)));
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 100 } },
    });
    for (hidden_ids) |hidden_id| {
        try tree.appendChild(root_id, hidden_id);
    }

    for (hidden_ids, child_ids, 0..) |hidden_id, child_id, index| {
        const hidden = tree.node(hidden_id) orelse return error.TestUnexpectedResult;
        hidden.rect = .{
            .x = @floatFromInt(index),
            .y = 2,
            .w = 20,
            .h = 10,
        };
        const child = tree.node(child_id) orelse return error.TestUnexpectedResult;
        child.rect = .{
            .x = 3,
            .y = 4,
            .w = 10,
            .h = 5,
        };
        hidden.resolved_box_edges = .{
            .border = .{},
            .padding = .{},
        };
        child.resolved_box_edges = .{
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

    const first_hidden = tree.node(hidden_ids[0]) orelse return error.TestUnexpectedResult;
    first_hidden.style.display = .block;
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

    const child_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

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
    const child = tree.nodeConst(child_id) orelse return error.TestUnexpectedResult;
    const resolved_edges = child.resolved_box_edges orelse return error.TestUnexpectedResult;
    const resolved_padding = resolved_edges.padding;
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

    const first_id: FrameNodeId = @enumFromInt(1);
    const empty_id: FrameNodeId = @enumFromInt(2);
    const third_id: FrameNodeId = @enumFromInt(3);
    const root_id: FrameNodeId = @enumFromInt(4);

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

    const first_id: FrameNodeId = @enumFromInt(1);
    const empty1_id: FrameNodeId = @enumFromInt(2);
    const empty2_id: FrameNodeId = @enumFromInt(3);
    const third_id: FrameNodeId = @enumFromInt(4);
    const root_id: FrameNodeId = @enumFromInt(5);

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

    const float_id: FrameNodeId = @enumFromInt(1);
    const first_id: FrameNodeId = @enumFromInt(2);
    const clear_id: FrameNodeId = @enumFromInt(3);
    const root_id: FrameNodeId = @enumFromInt(4);

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

    const inner_id: FrameNodeId = @enumFromInt(1);
    const block_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

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

    const first_inner_id: FrameNodeId = @enumFromInt(1);
    const second_inner_id: FrameNodeId = @enumFromInt(2);
    const block_id: FrameNodeId = @enumFromInt(3);
    const root_id: FrameNodeId = @enumFromInt(4);

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

    const inner_id: FrameNodeId = @enumFromInt(1);
    const block_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

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

test "block: definite parent height resolves child percentage height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

    try appendNode(&tree, child_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 40 }, .height = .{ .percent = 0.5 } },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 100 } },
    });
    try tree.appendChild(root_id, child_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(200, 100), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 200, .h = 100 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 40, .h = 50 });
}

test "block: absolute percentage insets resolve against the containing box" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 10 }, .height = .{ .length = 10 } },
        .inset = .{
            .top = .{ .percent = 0.1 },
            .right = .auto,
            .bottom = .auto,
            .left = .{ .percent = 0.25 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .{ .length = 100 } },
    });
    try tree.appendChild(root_id, absolute_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(200, 100), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 200, .h = 100 });
    try expectRelative(&tree, absolute_id, .{ .x = 50, .y = 10, .w = 10, .h = 10 });
}

test "block intrinsic auto width ignores positive and negative percentage child margins" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const positive_child_id: FrameNodeId = @enumFromInt(1);
    const positive_auto_id: FrameNodeId = @enumFromInt(2);
    const positive_intrinsic_id: FrameNodeId = @enumFromInt(3);
    const negative_child_id: FrameNodeId = @enumFromInt(4);
    const negative_auto_id: FrameNodeId = @enumFromInt(5);
    const negative_intrinsic_id: FrameNodeId = @enumFromInt(6);
    const root_id: FrameNodeId = @enumFromInt(7);

    try appendNode(&tree, positive_child_id, positive_auto_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .percent = 0.1 },
            .bottom = .{ .length = 0 },
            .left = .{ .percent = 0.2 },
        },
    });
    try appendNode(&tree, positive_auto_id, positive_intrinsic_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    });
    try appendNode(&tree, positive_intrinsic_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .max_content, .height = .auto },
    });
    try appendNode(&tree, negative_child_id, negative_auto_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .percent = -0.1 },
            .bottom = .{ .length = 0 },
            .left = .{ .percent = -0.2 },
        },
    });
    try appendNode(&tree, negative_auto_id, negative_intrinsic_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    });
    try appendNode(&tree, negative_intrinsic_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .max_content, .height = .auto },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 300 }, .height = .{ .length = 100 } },
    });
    try tree.appendChild(root_id, positive_intrinsic_id);
    try tree.appendChild(root_id, negative_intrinsic_id);
    try tree.appendChild(positive_intrinsic_id, positive_auto_id);
    try tree.appendChild(positive_auto_id, positive_child_id);
    try tree.appendChild(negative_intrinsic_id, negative_auto_id);
    try tree.appendChild(negative_auto_id, negative_child_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(300, 100), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 300, .h = 100 });
    try expectRelative(
        &tree,
        positive_intrinsic_id,
        .{ .x = 0, .y = 0, .w = 100, .h = 10 },
    );
    try expectRelative(&tree, positive_auto_id, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    try expectRelative(&tree, positive_child_id, .{ .x = 20, .y = 0, .w = 100, .h = 10 });
    try expectRelative(
        &tree,
        negative_intrinsic_id,
        .{ .x = 0, .y = 10, .w = 100, .h = 10 },
    );
    try expectRelative(&tree, negative_auto_id, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    try expectRelative(&tree, negative_child_id, .{ .x = -20, .y = 0, .w = 100, .h = 10 });
}

test "absolute oversized child keeps negative free space in one auto margin" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 72 }, .height = .{ .length = 72 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 10 },
            .bottom = .{ .length = 0 },
            .left = .auto,
        },
        .inset = .{
            .top = .auto,
            .right = .{ .length = 20 },
            .bottom = .auto,
            .left = .{ .length = 10 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 52 }, .height = .{ .length = 52 } },
    });
    try tree.appendChild(root_id, absolute_id);

    const pass = try block_float.LayoutPass.init(&tree);
    try pass.layoutContainer(root_id, definiteContext(52, 52), null);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 52, .h = 52 });
    try expectRelative(&tree, absolute_id, .{ .x = -50, .y = 0, .w = 72, .h = 72 });
}

test "vertical scrollbar gutter reduces percentage child width without changing border box" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

    try appendNode(&tree, child_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .percent = 1 }, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
        .overflow = .{ .width = .visible, .height = .scroll },
        .scrollbar_width = 15,
    });
    try tree.appendChild(root_id, child_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 85, .h = 10 });
}

test "horizontal scrollbar gutter contributes to empty auto border height" {
    {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const scroll_id: FrameNodeId = @enumFromInt(1);
        try appendNode(&tree, scroll_id, .root, .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .length = 100 }, .height = .auto },
            .overflow = .{ .width = .scroll, .height = .visible },
            .scrollbar_width = 15,
        });

        try layoutContainer(&tree, scroll_id, 100, 100);

        try expectRelative(&tree, scroll_id, .{ .x = 0, .y = 0, .w = 100, .h = 15 });
    }

    {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const hidden_id: FrameNodeId = @enumFromInt(1);
        try appendNode(&tree, hidden_id, .root, .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .length = 100 }, .height = .auto },
            .overflow = .{ .width = .hidden, .height = .visible },
            .scrollbar_width = 15,
        });

        try layoutContainer(&tree, hidden_id, 100, 100);

        try expectRelative(&tree, hidden_id, .{ .x = 0, .y = 0, .w = 100, .h = 0 });
    }
}

test "rtl vertical scrollbar gutter shifts the absolute content origin" {
    {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: FrameNodeId = @enumFromInt(1);
        const root_id: FrameNodeId = @enumFromInt(2);

        try appendNode(&tree, child_id, root_id, .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .percent = 1 }, .height = .{ .length = 10 } },
        });
        try appendNode(&tree, root_id, .root, .{
            .display = .block,
            .writing_direction = .rtl,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 100 },
            },
            .overflow = .{ .width = .visible, .height = .scroll },
            .scrollbar_width = 15,
        });
        try tree.appendChild(root_id, child_id);

        try layoutContainer(&tree, root_id, 100, 100);

        try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
        try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 85, .h = 10 });
        try expectRect(
            .{ .x = 15, .y = 0, .w = 85, .h = 10 },
            widget.absoluteRect(&tree, child_id),
        );
    }

    {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: FrameNodeId = @enumFromInt(1);
        const root_id: FrameNodeId = @enumFromInt(2);

        try appendNode(&tree, child_id, root_id, .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .percent = 1 }, .height = .{ .length = 10 } },
        });
        try appendNode(&tree, root_id, .root, .{
            .display = .block,
            .writing_direction = .ltr,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 100 },
            },
            .overflow = .{ .width = .visible, .height = .scroll },
            .scrollbar_width = 15,
        });
        try tree.appendChild(root_id, child_id);

        try layoutContainer(&tree, root_id, 100, 100);

        try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
        try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 85, .h = 10 });
        try expectRect(
            .{ .x = 0, .y = 0, .w = 85, .h = 10 },
            widget.absoluteRect(&tree, child_id),
        );
    }
}

test "vertical scrollbar gutter stays inside fixed content box" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

    try appendNode(&tree, child_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .percent = 1 }, .height = .{ .length = 10 } },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .box_sizing = .content_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 20 },
        },
        .overflow = .{ .width = .visible, .height = .scroll },
        .scrollbar_width = 15,
    });
    try tree.appendChild(root_id, child_id);

    try layoutContainer(&tree, root_id, 100, 20);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 85, .h = 10 });
}

test "fixed-width BFC resolves auto margins inside a float-avoiding slot" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: FrameNodeId = @enumFromInt(1);
    const bfc_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, float_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try appendNode(&tree, bfc_id, root_id, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 50 },
        },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .auto,
            .bottom = .{ .length = 0 },
            .left = .auto,
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 300 }, .height = .auto },
    });
    try tree.appendChild(root_id, float_id);
    try tree.appendChild(root_id, bfc_id);

    try layoutContainer(&tree, root_id, 300, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 300, .h = 100 });
    try expectRelative(&tree, float_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, bfc_id, .{ .x = 150, .y = 0, .w = 100, .h = 50 });
}
test "float-avoiding BFC does not subtract its fixed margin twice" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: FrameNodeId = @enumFromInt(1);
    const bfc_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, float_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try appendNode(&tree, bfc_id, root_id, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 50 },
        },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 20 },
            .bottom = .{ .length = 0 },
            .left = .auto,
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 300 }, .height = .auto },
    });
    try tree.appendChild(root_id, float_id);
    try tree.appendChild(root_id, bfc_id);

    try layoutContainer(&tree, root_id, 300, 100);

    try expectRelative(&tree, float_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, bfc_id, .{ .x = 180, .y = 0, .w = 100, .h = 50 });
}

test "auto-width BFC resolves auto margins inside a float-avoiding slot" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: FrameNodeId = @enumFromInt(1);
    const bfc_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, float_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try appendNode(&tree, bfc_id, root_id, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{
            .width = .auto,
            .height = .{ .length = 50 },
        },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .auto,
            .bottom = .{ .length = 0 },
            .left = .auto,
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 300 }, .height = .auto },
    });
    try tree.appendChild(root_id, float_id);
    try tree.appendChild(root_id, bfc_id);

    try layoutContainer(&tree, root_id, 300, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 300, .h = 100 });
    try expectRelative(&tree, float_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, bfc_id, .{ .x = 100, .y = 0, .w = 200, .h = 50 });
}

test "auto-width BFC ignores a small negative leading margin beside a float" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: FrameNodeId = @enumFromInt(1);
    const bfc_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, float_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 100 },
        },
    });
    try appendNode(&tree, bfc_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .auto,
            .height = .{ .length = 100 },
        },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = -20 },
        },
        .overflow = .{ .width = .hidden, .height = .hidden },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(root_id, float_id);
    try tree.appendChild(root_id, bfc_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, float_id, .{ .x = 0, .y = 0, .w = 50, .h = 100 });
    try expectRelative(&tree, bfc_id, .{ .x = 50, .y = 0, .w = 50, .h = 100 });
}

test "auto-width BFC absorbs a positive leading margin beside a float" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: FrameNodeId = @enumFromInt(1);
    const bfc_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, float_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 100 },
        },
    });
    try appendNode(&tree, bfc_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .auto,
            .height = .{ .length = 50 },
        },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 20 },
        },
        .overflow = .{ .width = .hidden, .height = .hidden },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(root_id, float_id);
    try tree.appendChild(root_id, bfc_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, float_id, .{ .x = 0, .y = 0, .w = 50, .h = 100 });
    try expectRelative(&tree, bfc_id, .{ .x = 50, .y = 0, .w = 50, .h = 50 });
}

test "large negative leading margin moves an auto-width BFC below a float" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: FrameNodeId = @enumFromInt(1);
    const bfc_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, float_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 100 },
        },
    });
    try appendNode(&tree, bfc_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .auto,
            .height = .{ .length = 50 },
        },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = -60 },
        },
        .overflow = .{ .width = .hidden, .height = .hidden },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(root_id, float_id);
    try tree.appendChild(root_id, bfc_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 150 });
    try expectRelative(&tree, float_id, .{ .x = 0, .y = 0, .w = 50, .h = 100 });
    try expectRelative(&tree, bfc_id, .{ .x = -60, .y = 100, .w = 160, .h = 50 });
}

test "BFC avoids a float from a preceding sibling subtree" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: FrameNodeId = @enumFromInt(1);
    const preceding_id: FrameNodeId = @enumFromInt(2);
    const bfc_id: FrameNodeId = @enumFromInt(3);
    const root_id: FrameNodeId = @enumFromInt(4);

    try appendNode(&tree, float_id, preceding_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 100 },
        },
    });
    try appendNode(&tree, preceding_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    });
    try appendNode(&tree, bfc_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .auto,
            .height = .{ .length = 50 },
        },
        .overflow = .{ .width = .hidden, .height = .hidden },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(preceding_id, float_id);
    try tree.appendChild(root_id, preceding_id);
    try tree.appendChild(root_id, bfc_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, preceding_id, .{ .x = 0, .y = 0, .w = 100, .h = 0 });
    try expectRelative(&tree, float_id, .{ .x = 0, .y = 0, .w = 50, .h = 100 });
    try expectRelative(&tree, bfc_id, .{ .x = 50, .y = 0, .w = 50, .h = 50 });
}

test "forced clearance ignores an adjoining collapsed top margin" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: FrameNodeId = @enumFromInt(1);
    const float_parent_id: FrameNodeId = @enumFromInt(2);
    const clear_id: FrameNodeId = @enumFromInt(3);
    const container_id: FrameNodeId = @enumFromInt(4);
    const root_id: FrameNodeId = @enumFromInt(5);

    try appendNode(&tree, float_id, float_parent_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 50 },
        },
    });
    try appendNode(&tree, float_parent_id, container_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    });
    try appendNode(&tree, clear_id, container_id, .{
        .display = .block,
        .clear = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .auto,
            .height = .{ .length = 50 },
        },
        .margin_inset = .{
            .top = .{ .length = 400 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, container_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(float_parent_id, float_id);
    try tree.appendChild(container_id, float_parent_id);
    try tree.appendChild(container_id, clear_id);
    try tree.appendChild(root_id, container_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, float_parent_id, .{ .x = 0, .y = 0, .w = 100, .h = 0 });
    try expectRelative(&tree, float_id, .{ .x = 0, .y = 0, .w = 100, .h = 50 });
    try expectRelative(&tree, clear_id, .{ .x = 0, .y = 50, .w = 100, .h = 50 });
}

test "negative clearance preserves following sibling collapse geometry" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: FrameNodeId = @enumFromInt(1);
    const clear_id: FrameNodeId = @enumFromInt(2);
    const inner_id: FrameNodeId = @enumFromInt(3);
    const following_id: FrameNodeId = @enumFromInt(4);
    const container_id: FrameNodeId = @enumFromInt(5);
    const root_id: FrameNodeId = @enumFromInt(6);

    try appendNode(&tree, float_id, inner_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 50 },
        },
    });
    try appendNode(&tree, clear_id, inner_id, .{
        .display = .block,
        .clear = .left,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
        .margin_inset = .{
            .top = .{ .length = 200 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, inner_id, container_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    });
    try appendNode(&tree, following_id, container_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .auto,
            .height = .{ .length = 50 },
        },
    });
    try appendNode(&tree, container_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(inner_id, float_id);
    try tree.appendChild(inner_id, clear_id);
    try tree.appendChild(container_id, inner_id);
    try tree.appendChild(container_id, following_id);
    try tree.appendChild(root_id, container_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, inner_id, .{ .x = 0, .y = 0, .w = 100, .h = 50 });
    try expectRelative(&tree, float_id, .{ .x = 0, .y = 0, .w = 100, .h = 50 });
    try expectRelative(&tree, clear_id, .{ .x = 0, .y = 50, .w = 100, .h = 0 });
    try expectRelative(&tree, following_id, .{ .x = 0, .y = 50, .w = 100, .h = 50 });
}

test "fixed-width BFC retries past every float in a preceding sibling subtree" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_float_id: FrameNodeId = @enumFromInt(1);
    const second_float_id: FrameNodeId = @enumFromInt(2);
    const third_float_id: FrameNodeId = @enumFromInt(3);
    const preceding_id: FrameNodeId = @enumFromInt(4);
    const bfc_id: FrameNodeId = @enumFromInt(5);
    const root_id: FrameNodeId = @enumFromInt(6);

    try appendNode(&tree, first_float_id, preceding_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 10 },
        },
    });
    try appendNode(&tree, second_float_id, preceding_id, .{
        .display = .block,
        .float = .left,
        .clear = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 10 },
        },
    });
    try appendNode(&tree, third_float_id, preceding_id, .{
        .display = .block,
        .float = .left,
        .clear = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 10 },
        },
    });
    try appendNode(&tree, preceding_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    });
    try appendNode(&tree, bfc_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 60 },
            .height = .{ .length = 5 },
        },
        .overflow = .{ .width = .hidden, .height = .hidden },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(preceding_id, first_float_id);
    try tree.appendChild(preceding_id, second_float_id);
    try tree.appendChild(preceding_id, third_float_id);
    try tree.appendChild(root_id, preceding_id);
    try tree.appendChild(root_id, bfc_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 35 });
    try expectRelative(&tree, preceding_id, .{ .x = 0, .y = 0, .w = 100, .h = 0 });
    try expectRelative(&tree, first_float_id, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
    try expectRelative(&tree, second_float_id, .{ .x = 0, .y = 10, .w = 50, .h = 10 });
    try expectRelative(&tree, third_float_id, .{ .x = 0, .y = 20, .w = 50, .h = 10 });
    try expectRelative(&tree, bfc_id, .{ .x = 0, .y = 30, .w = 60, .h = 5 });
}

test "auto-width BFC retries past every float in a preceding sibling subtree" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_float_id: FrameNodeId = @enumFromInt(1);
    const second_float_id: FrameNodeId = @enumFromInt(2);
    const third_float_id: FrameNodeId = @enumFromInt(3);
    const preceding_id: FrameNodeId = @enumFromInt(4);
    const bfc_id: FrameNodeId = @enumFromInt(5);
    const root_id: FrameNodeId = @enumFromInt(6);

    try appendNode(&tree, first_float_id, preceding_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 10 },
        },
    });
    try appendNode(&tree, second_float_id, preceding_id, .{
        .display = .block,
        .float = .left,
        .clear = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 10 },
        },
    });
    try appendNode(&tree, third_float_id, preceding_id, .{
        .display = .block,
        .float = .left,
        .clear = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 10 },
        },
    });
    try appendNode(&tree, preceding_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    });
    try appendNode(&tree, bfc_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .auto,
            .height = .{ .length = 5 },
        },
        .min_size = .{
            .width = .{ .length = 60 },
            .height = .auto,
        },
        .overflow = .{ .width = .hidden, .height = .hidden },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .auto },
    });
    try tree.appendChild(preceding_id, first_float_id);
    try tree.appendChild(preceding_id, second_float_id);
    try tree.appendChild(preceding_id, third_float_id);
    try tree.appendChild(root_id, preceding_id);
    try tree.appendChild(root_id, bfc_id);

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 35 });
    try expectRelative(&tree, preceding_id, .{ .x = 0, .y = 0, .w = 100, .h = 0 });
    try expectRelative(&tree, first_float_id, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
    try expectRelative(&tree, second_float_id, .{ .x = 0, .y = 10, .w = 50, .h = 10 });
    try expectRelative(&tree, third_float_id, .{ .x = 0, .y = 20, .w = 50, .h = 10 });
    try expectRelative(&tree, bfc_id, .{ .x = 0, .y = 30, .w = 100, .h = 5 });
}

test "flex-item block keeps vertical margins inside its BFC" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @enumFromInt(1);
    const second_id: FrameNodeId = @enumFromInt(2);
    const third_id: FrameNodeId = @enumFromInt(3);
    const fourth_id: FrameNodeId = @enumFromInt(4);
    const block_item_id: FrameNodeId = @enumFromInt(5);
    const flex_root_id: FrameNodeId = @enumFromInt(6);

    try appendNode(&tree, first_id, block_item_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 10 },
        },
        .margin_inset = .{
            .top = .{ .length = 10 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 10 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, second_id, block_item_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 10 },
        },
        .margin_inset = .{
            .top = .{ .length = 10 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 10 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, third_id, block_item_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 10 },
        },
        .margin_inset = .{
            .top = .{ .length = 5 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 5 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, fourth_id, block_item_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 10 },
        },
        .margin_inset = .{
            .top = .{ .length = 10 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 10 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, block_item_id, flex_root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .auto,
        },
    });
    try appendNode(&tree, flex_root_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 90 },
        },
    });
    try tree.appendChild(block_item_id, first_id);
    try tree.appendChild(block_item_id, second_id);
    try tree.appendChild(block_item_id, third_id);
    try tree.appendChild(block_item_id, fourth_id);
    try tree.appendChild(flex_root_id, block_item_id);

    try layoutTree(&tree, 50, 90);

    try expectRelative(&tree, flex_root_id, .{ .x = 0, .y = 0, .w = 50, .h = 90 });
    try expectRelative(&tree, block_item_id, .{ .x = 0, .y = 0, .w = 50, .h = 90 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 10, .w = 50, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 30, .w = 50, .h = 10 });
    try expectRelative(&tree, third_id, .{ .x = 0, .y = 50, .w = 50, .h = 10 });
    try expectRelative(&tree, fourth_id, .{ .x = 0, .y = 70, .w = 50, .h = 10 });
}

test "flex-item block contains a float before a following flow root" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: FrameNodeId = @enumFromInt(1);
    const flow_root_id: FrameNodeId = @enumFromInt(2);
    const block_item_id: FrameNodeId = @enumFromInt(3);
    const flex_root_id: FrameNodeId = @enumFromInt(4);

    try appendNode(&tree, float_id, block_item_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 100 },
        },
    });
    try appendNode(&tree, flow_root_id, block_item_id, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{
            .width = .auto,
            .height = .{ .length = 50 },
        },
        .min_size = .{
            .width = .{ .length = 50 },
            .height = .auto,
        },
    });
    try appendNode(&tree, block_item_id, flex_root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .auto,
        },
    });
    try appendNode(&tree, flex_root_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(block_item_id, float_id);
    try tree.appendChild(block_item_id, flow_root_id);
    try tree.appendChild(flex_root_id, block_item_id);

    try layoutTree(&tree, 100, 100);

    try expectRelative(&tree, flex_root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, block_item_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, float_id, .{ .x = 0, .y = 0, .w = 50, .h = 100 });
    try expectRelative(&tree, flow_root_id, .{ .x = 50, .y = 0, .w = 50, .h = 50 });
}

fn expectTextAlignCase(
    text_align: style.TextAlign,
    writing_direction: style.Direction,
    expected_x: f32,
) !void {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

    try appendNode(&tree, child_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 50 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .writing_direction = writing_direction,
        .text_align = text_align,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 200 },
            .height = .{ .length = 200 },
        },
    });
    try tree.appendChild(root_id, child_id);

    try layoutTree(&tree, 200, 200);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 200, .h = 200 });
    try expectRelative(&tree, child_id, .{ .x = expected_x, .y = 0, .w = 100, .h = 50 });
}

test "text-align left physically places a fixed block" {
    try expectTextAlignCase(.left, .ltr, 0);
}

test "text-align center physically places a fixed block" {
    try expectTextAlignCase(.center, .ltr, 50);
}

test "text-align right physically places a fixed block" {
    try expectTextAlignCase(.right, .ltr, 100);
}

test "text-align center remains physical under RTL" {
    try expectTextAlignCase(.center, .rtl, 50);
}

test "flex-item BFC contains an empty child's collapsed margins" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const empty_id: FrameNodeId = @enumFromInt(1);
    const block_item_id: FrameNodeId = @enumFromInt(2);
    const flex_root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, empty_id, block_item_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 0 },
        },
        .margin_inset = .{
            .top = .{ .length = 10 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 20 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, block_item_id, flex_root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .auto,
        },
    });
    try appendNode(&tree, flex_root_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .auto,
        },
    });
    try tree.appendChild(block_item_id, empty_id);
    try tree.appendChild(flex_root_id, block_item_id);

    try layoutTree(&tree, 100, 200);

    try expectRelative(&tree, flex_root_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, block_item_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, empty_id, .{ .x = 0, .y = 10, .w = 100, .h = 0 });
}

test "flex-item BFC natural height contains staggered opposing floats" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const left_float_id: FrameNodeId = @enumFromInt(1);
    const first_right_float_id: FrameNodeId = @enumFromInt(2);
    const second_right_float_id: FrameNodeId = @enumFromInt(3);
    const block_item_id: FrameNodeId = @enumFromInt(4);
    const flex_root_id: FrameNodeId = @enumFromInt(5);

    try appendNode(&tree, left_float_id, block_item_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 100 },
        },
    });
    try appendNode(&tree, first_right_float_id, block_item_id, .{
        .display = .block,
        .float = .right,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 20 },
        },
    });
    try appendNode(&tree, second_right_float_id, block_item_id, .{
        .display = .block,
        .float = .right,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 20 },
        },
    });
    try appendNode(&tree, block_item_id, flex_root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .auto,
        },
    });
    try appendNode(&tree, flex_root_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .auto,
        },
    });
    try tree.appendChild(block_item_id, left_float_id);
    try tree.appendChild(block_item_id, first_right_float_id);
    try tree.appendChild(block_item_id, second_right_float_id);
    try tree.appendChild(flex_root_id, block_item_id);

    try layoutTree(&tree, 100, 200);

    try expectRelative(&tree, flex_root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, block_item_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, left_float_id, .{ .x = 0, .y = 0, .w = 50, .h = 100 });
    try expectRelative(
        &tree,
        first_right_float_id,
        .{ .x = 50, .y = 0, .w = 50, .h = 20 },
    );
    try expectRelative(
        &tree,
        second_right_float_id,
        .{ .x = 50, .y = 20, .w = 50, .h = 20 },
    );
}

fn expectBfcTextAlignCase(
    child_display: style.Display,
    child_overflow: style.OverflowAxes,
    text_align: style.TextAlign,
    expected_x: f32,
) !void {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

    try appendNode(&tree, child_id, root_id, .{
        .display = child_display,
        .overflow = child_overflow,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 50 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .writing_direction = .rtl,
        .text_align = text_align,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 200 },
            .height = .{ .length = 200 },
        },
    });
    try tree.appendChild(root_id, child_id);

    try layoutTree(&tree, 200, 200);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 200, .h = 200 });
    try expectRelative(&tree, child_id, .{ .x = expected_x, .y = 0, .w = 100, .h = 50 });
}

test "RTL physical text-align positions flow-root and overflow BFC children" {
    const visible_overflow: style.OverflowAxes = .{
        .width = .visible,
        .height = .visible,
    };
    const hidden_overflow: style.OverflowAxes = .{
        .width = .hidden,
        .height = .hidden,
    };

    try expectBfcTextAlignCase(.flow_root, visible_overflow, .left, 0);
    try expectBfcTextAlignCase(.flow_root, visible_overflow, .center, 50);
    try expectBfcTextAlignCase(.block, hidden_overflow, .left, 0);
    try expectBfcTextAlignCase(.block, hidden_overflow, .center, 50);
}

test "flex-item BFC clear uses only the requested float side" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const left_float_id: FrameNodeId = @enumFromInt(1);
    const right_float_id: FrameNodeId = @enumFromInt(2);
    const clear_id: FrameNodeId = @enumFromInt(3);
    const block_item_id: FrameNodeId = @enumFromInt(4);
    const flex_root_id: FrameNodeId = @enumFromInt(5);

    try appendNode(&tree, left_float_id, block_item_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 100 },
        },
    });
    try appendNode(&tree, right_float_id, block_item_id, .{
        .display = .block,
        .float = .right,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 20 },
        },
    });
    try appendNode(&tree, clear_id, block_item_id, .{
        .display = .block,
        .clear = .right,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 10 },
        },
    });
    try appendNode(&tree, block_item_id, flex_root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .auto,
        },
    });
    try appendNode(&tree, flex_root_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .auto,
        },
    });
    try tree.appendChild(block_item_id, left_float_id);
    try tree.appendChild(block_item_id, right_float_id);
    try tree.appendChild(block_item_id, clear_id);
    try tree.appendChild(flex_root_id, block_item_id);

    try layoutTree(&tree, 100, 200);

    try expectRelative(&tree, flex_root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, block_item_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, left_float_id, .{ .x = 0, .y = 0, .w = 50, .h = 100 });
    try expectRelative(&tree, right_float_id, .{ .x = 50, .y = 0, .w = 50, .h = 20 });
    try expectRelative(&tree, clear_id, .{ .x = 0, .y = 20, .w = 100, .h = 10 });
}

test "full inset absolute aspect ratio overrides height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

    try appendNode(&tree, absolute_id, root_id, .{
        .display = .block,
        .position = .absolute,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
        .aspect_ratio = 3.0,
        .inset = .{
            .top = .{ .percent = 0.05 },
            .right = .{ .percent = 0.05 },
            .bottom = .{ .percent = 0.05 },
            .left = .{ .percent = 0.05 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 400 },
            .height = .{ .length = 300 },
        },
    });
    try tree.appendChild(root_id, absolute_id);

    try layoutContainer(&tree, root_id, 400, 300);

    try expectRelative(&tree, absolute_id, .{ .x = 20, .y = 15, .w = 360, .h = 120 });
}

test "block container align content center" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @enumFromInt(1);
    const second_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, first_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 50 } },
    });
    try appendNode(&tree, second_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 50 } },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .align_content = .center,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 200 },
        },
    });
    try tree.appendChild(root_id, first_id);
    try tree.appendChild(root_id, second_id);

    try layoutContainer(&tree, root_id, 100, 200);

    try expectRelative(&tree, first_id, .{ .x = 0, .y = 50, .w = 100, .h = 50 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 100, .w = 100, .h = 50 });
}

test "block container align content end" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @enumFromInt(1);
    const second_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, first_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 50 } },
    });
    try appendNode(&tree, second_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 50 } },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .align_content = .end,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 200 },
        },
    });
    try tree.appendChild(root_id, first_id);
    try tree.appendChild(root_id, second_id);

    try layoutContainer(&tree, root_id, 100, 200);

    try expectRelative(&tree, first_id, .{ .x = 0, .y = 100, .w = 100, .h = 50 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 150, .w = 100, .h = 50 });
}

test "block container align content space between retains normal block flow" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @enumFromInt(1);
    const second_id: FrameNodeId = @enumFromInt(2);
    const root_id: FrameNodeId = @enumFromInt(3);

    try appendNode(&tree, first_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 50 } },
    });
    try appendNode(&tree, second_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 50 } },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .align_content = .space_between,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 200 },
        },
    });
    try tree.appendChild(root_id, first_id);
    try tree.appendChild(root_id, second_id);

    try layoutContainer(&tree, root_id, 100, 200);

    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 100, .h = 50 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 50, .w = 100, .h = 50 });
}

fn expectBlockOverflowAlignment(
    align_content: style.AlignContent,
    expected_y: [3]f32,
) !void {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @enumFromInt(1);
    const second_id: FrameNodeId = @enumFromInt(2);
    const third_id: FrameNodeId = @enumFromInt(3);
    const root_id: FrameNodeId = @enumFromInt(4);
    const child_ids = [_]FrameNodeId{ first_id, second_id, third_id };

    for (child_ids) |child_id| {
        try appendNode(&tree, child_id, root_id, .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 50 },
            },
        });
    }
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .align_content = align_content,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    for (child_ids) |child_id| {
        try tree.appendChild(root_id, child_id);
    }

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(
        &tree,
        first_id,
        .{ .x = 0, .y = expected_y[0], .w = 100, .h = 50 },
    );
    try expectRelative(
        &tree,
        second_id,
        .{ .x = 0, .y = expected_y[1], .w = 100, .h = 50 },
    );
    try expectRelative(
        &tree,
        third_id,
        .{ .x = 0, .y = expected_y[2], .w = 100, .h = 50 },
    );
}

test "plain block align content center remains unsafe during overflow" {
    try expectBlockOverflowAlignment(.center, .{ -25, 25, 75 });
}

test "plain block align content end remains unsafe during overflow" {
    try expectBlockOverflowAlignment(.end, .{ -50, 0, 50 });
}

test "safe block align content center falls back to start during overflow" {
    try expectBlockOverflowAlignment(.safe_center, .{ 0, 50, 100 });
}

test "safe block align content end falls back to start during overflow" {
    try expectBlockOverflowAlignment(.safe_end, .{ 0, 50, 100 });
}

test "auto block min height aligns content in the final box" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @enumFromInt(1);
    const root_id: FrameNodeId = @enumFromInt(2);

    try appendNode(&tree, child_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 50 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .align_content = .center,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .auto,
        },
        .min_size = .{
            .width = .auto,
            .height = .{ .length = 200 },
        },
    });
    try tree.appendChild(root_id, child_id);

    try layoutContainer(&tree, root_id, 100, 200);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 200 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 75, .w = 100, .h = 50 });
}

test "absolute children use the padding box for opposing insets and margins" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const Case = struct {
        id: FrameNodeId,
        inset: style.Insets,
        margin: style.Insets = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
        expected_relative: Rect,
        expected_absolute: Rect,
    };
    const cases = [_]Case{
        .{
            .id = @enumFromInt(1),
            .inset = .{
                .top = .{ .length = 0 },
                .right = .auto,
                .bottom = .auto,
                .left = .{ .length = 0 },
            },
            .expected_relative = .{ .x = -10, .y = -10, .w = 50, .h = 50 },
            .expected_absolute = .{ .x = 10, .y = 10, .w = 50, .h = 50 },
        },
        .{
            .id = @enumFromInt(2),
            .inset = .{
                .top = .auto,
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .auto,
            },
            .expected_relative = .{ .x = 20, .y = 20, .w = 50, .h = 50 },
            .expected_absolute = .{ .x = 40, .y = 40, .w = 50, .h = 50 },
        },
        .{
            .id = @enumFromInt(3),
            .inset = .{
                .top = .{ .length = 0 },
                .right = .auto,
                .bottom = .auto,
                .left = .{ .length = 0 },
            },
            .margin = .{
                .top = .{ .length = 10 },
                .right = .{ .length = 10 },
                .bottom = .{ .length = 10 },
                .left = .{ .length = 10 },
            },
            .expected_relative = .{ .x = 0, .y = 0, .w = 50, .h = 50 },
            .expected_absolute = .{ .x = 20, .y = 20, .w = 50, .h = 50 },
        },
        .{
            .id = @enumFromInt(4),
            .inset = .{
                .top = .auto,
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .auto,
            },
            .margin = .{
                .top = .{ .length = 10 },
                .right = .{ .length = 10 },
                .bottom = .{ .length = 10 },
                .left = .{ .length = 10 },
            },
            .expected_relative = .{ .x = 10, .y = 10, .w = 50, .h = 50 },
            .expected_absolute = .{ .x = 30, .y = 30, .w = 50, .h = 50 },
        },
    };
    const root_id: FrameNodeId = @enumFromInt(5);

    for (cases) |case| {
        try appendNode(&tree, case.id, root_id, .{
            .display = .block,
            .position = .absolute,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 50 },
                .height = .{ .length = 50 },
            },
            .inset = case.inset,
            .margin_inset = case.margin,
        });
    }
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
        .border_inset = .{
            .top = .{ .length = 10 },
            .right = .{ .length = 10 },
            .bottom = .{ .length = 10 },
            .left = .{ .length = 10 },
        },
        .padding_inset = .{
            .top = .{ .length = 10 },
            .right = .{ .length = 10 },
            .bottom = .{ .length = 10 },
            .left = .{ .length = 10 },
        },
    });
    for (cases) |case| {
        try tree.appendChild(root_id, case.id);
    }

    try layoutContainer(&tree, root_id, 100, 100);

    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    for (cases) |case| {
        try expectRelative(&tree, case.id, case.expected_relative);
        try expectRect(case.expected_absolute, widget.absoluteRect(&tree, case.id));
    }
}

test "float placement preserves a preceding collapsed bottom margin strut" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const preceding_id: FrameNodeId = @enumFromInt(1);
    const float_id: FrameNodeId = @enumFromInt(2);
    const following_id: FrameNodeId = @enumFromInt(3);
    const root_id: FrameNodeId = @enumFromInt(4);

    try appendNode(&tree, preceding_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 200 },
            .height = .{ .length = 20 },
        },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 16 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, float_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 50 },
        },
    });
    try appendNode(&tree, following_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 200 },
            .height = .{ .length = 30 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 200 }, .height = .auto },
    });
    try tree.appendChild(root_id, preceding_id);
    try tree.appendChild(root_id, float_id);
    try tree.appendChild(root_id, following_id);

    try layoutContainer(&tree, root_id, 200, 100);

    try expectRelative(&tree, preceding_id, .{ .x = 0, .y = 0, .w = 200, .h = 20 });
    try expectRelative(&tree, float_id, .{ .x = 0, .y = 36, .w = 50, .h = 50 });
    try expectRelative(&tree, following_id, .{ .x = 0, .y = 36, .w = 200, .h = 30 });
    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 200, .h = 86 });
}

test "intrinsic auto width packs a same-side float run in a nested shrink-to-fit block" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_float_id: FrameNodeId = @enumFromInt(1);
    const second_float_id: FrameNodeId = @enumFromInt(2);
    const shrink_id: FrameNodeId = @enumFromInt(3);
    const root_id: FrameNodeId = @enumFromInt(4);

    try appendNode(&tree, first_float_id, shrink_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 30 },
            .height = .{ .length = 10 },
        },
    });
    try appendNode(&tree, second_float_id, shrink_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 20 },
            .height = .{ .length = 10 },
        },
    });
    try appendNode(&tree, shrink_id, root_id, .{
        .display = .block,
        .float = .left,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .flow_root,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(shrink_id, first_float_id);
    try tree.appendChild(shrink_id, second_float_id);
    try tree.appendChild(root_id, shrink_id);

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = null,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();
    const shrink = tree.nodeConst(shrink_id) orelse return error.TestUnexpectedResult;
    const measured = try block_float.measureNatural(
        &tree,
        shrink,
        .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = 100, .height = 100 },
            .width_mode = .max_content,
            .height_mode = .max_content,
        },
        &context,
    );
    const tolerance: f32 = 0.001;

    try std.testing.expectApproxEqAbs(@as(f32, 50), measured.content.width, tolerance);
    try std.testing.expectApproxEqAbs(@as(f32, 10), measured.content.height, tolerance);
    try std.testing.expectApproxEqAbs(@as(f32, 50), measured.border.width, tolerance);
    try std.testing.expectApproxEqAbs(@as(f32, 10), measured.border.height, tolerance);
}

test "empty flex and grid children keep vertical margins from collapsing through" {
    const displays = [_]style.Display{ .flex, .grid };

    for (displays) |independent_display| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const preceding_id: FrameNodeId = @enumFromInt(1);
        const independent_id: FrameNodeId = @enumFromInt(2);
        const following_id: FrameNodeId = @enumFromInt(3);
        const root_id: FrameNodeId = @enumFromInt(4);

        try appendNode(&tree, preceding_id, root_id, .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 50 },
                .height = .{ .length = 10 },
            },
            .margin_inset = .{
                .top = .{ .length = 0 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 10 },
                .left = .{ .length = 0 },
            },
        });
        try appendNode(&tree, independent_id, root_id, .{
            .display = independent_display,
            .box_sizing = .border_box,
            .size = .{ .width = .auto, .height = .auto },
            .margin_inset = .{
                .top = .{ .length = 10 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 10 },
                .left = .{ .length = 0 },
            },
        });
        try appendNode(&tree, following_id, root_id, .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 50 },
                .height = .{ .length = 10 },
            },
            .margin_inset = .{
                .top = .{ .length = 10 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 0 },
            },
        });
        try appendNode(&tree, root_id, .root, .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .length = 50 }, .height = .auto },
        });
        try tree.appendChild(root_id, preceding_id);
        try tree.appendChild(root_id, independent_id);
        try tree.appendChild(root_id, following_id);

        try layoutTree(&tree, 50, 100);

        try expectRelative(&tree, preceding_id, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
        try expectRelative(&tree, independent_id, .{ .x = 0, .y = 20, .w = 50, .h = 0 });
        try expectRelative(&tree, following_id, .{ .x = 0, .y = 30, .w = 50, .h = 10 });
        try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 50, .h = 40 });
    }
}

test "aspect-ratio block contributes transferred height between collapsing margins" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const preceding_id: FrameNodeId = @enumFromInt(1);
    const ratio_id: FrameNodeId = @enumFromInt(2);
    const following_id: FrameNodeId = @enumFromInt(3);
    const root_id: FrameNodeId = @enumFromInt(4);

    try appendNode(&tree, preceding_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 10 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, ratio_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
        .aspect_ratio = 2,
        .margin_inset = .{
            .top = .{ .length = 10 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 10 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, following_id, root_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 10 } },
        .margin_inset = .{
            .top = .{ .length = 10 },
            .right = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 0 },
        },
    });
    try appendNode(&tree, root_id, .root, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{ .width = .{ .length = 50 }, .height = .auto },
    });
    try tree.appendChild(root_id, preceding_id);
    try tree.appendChild(root_id, ratio_id);
    try tree.appendChild(root_id, following_id);

    try layoutTree(&tree, 50, 100);

    try expectRelative(&tree, preceding_id, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
    try expectRelative(&tree, ratio_id, .{ .x = 0, .y = 20, .w = 50, .h = 25 });
    try expectRelative(&tree, following_id, .{ .x = 0, .y = 55, .w = 50, .h = 10 });
    try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 50, .h = 65 });
}
