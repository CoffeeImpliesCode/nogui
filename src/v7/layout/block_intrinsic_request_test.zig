//! Verifies that block natural measurement preserves an intrinsically indefinite child axis.

const std = @import("std");
const FrameNodeId = @import("../id.zig").FrameNodeId;
const layout_context = @import("context.zig");
const widget = @import("../widget.zig");
const block_float = @import("block_float.zig");
const flex = @import("flex.zig");

const WidgetTree = widget.WidgetTree;

fn measureFlexNode(
    context: *layout_context.LayoutContext,
    tree: *WidgetTree,
    node: *const widget.WidgetNode,
    request: layout_context.Request,
) layout_context.LayoutError!layout_context.Measured {
    if (node.style.display != .flex) return error.InvalidStyle;
    return flex.measureNatural(tree, node, request, context);
}

fn unreachableLayoutNode(
    _: *layout_context.LayoutContext,
    _: *WidgetTree,
    _: *widget.WidgetNode,
    _: layout_context.LayoutRequest,
) layout_context.LayoutError!void {
    unreachable;
}

const MeasureProbe = struct {
    var calls: usize = 0;
    var known_width: ?f32 = null;
    var known_height: ?f32 = null;
    var width_is_min_content: bool = false;
    var available_height: ?f32 = null;

    fn reset() void {
        calls = 0;
        known_width = null;
        known_height = null;
        width_is_min_content = false;
        available_height = null;
    }

    fn measure(
        _: ?*anyopaque,
        _: []const u8,
        input: layout_context.MeasureInput,
    ) layout_context.LayoutError!layout_context.TextMeasurement {
        calls += 1;
        known_width = input.known_dimensions.width;
        known_height = input.known_dimensions.height;
        width_is_min_content = switch (input.available_space.width) {
            .min_content => true,
            .definite, .max_content => false,
        };
        available_height = switch (input.available_space.height) {
            .definite => |height| height,
            .min_content, .max_content => null,
        };
        return .{ .width = 10, .height = 20 };
    }

    const source: layout_context.MeasureSource = .{ .callback = measure };
};

test "auto intrinsic block height leaves flex percentage height indefinite" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const flex_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const root_id: FrameNodeId = @fromBackingInt(@intCast(3));

    try tree.appendNode(.{
        .id = leaf_id,
        .kind = .{ .spacer = .{} },
        .parent = flex_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 10 },
                .height = .{ .length = 10 },
            },
        },
    });
    try tree.appendNode(.{
        .id = flex_id,
        .kind = .{ .row = .{} },
        .parent = root_id,
        .style = .{
            .display = .flex,
            .direction = .row,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 40 },
                .height = .{ .percent = 0.5 },
            },
        },
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .auto,
            },
        },
    });
    try tree.appendChild(flex_id, leaf_id);
    try tree.appendChild(root_id, flex_id);

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = null,
        .measure_node = measureFlexNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();
    const measured = try block_float.measureNatural(
        &tree,
        tree.nodeConst(root_id) orelse return error.TestUnexpectedResult,
        .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = 100, .height = 200 },
            .height_mode = .max_content,
        },
        &context,
    );
    try std.testing.expectEqual(@as(f32, 40), measured.content.width);
    try std.testing.expectEqual(@as(f32, 10), measured.content.height);
    try std.testing.expectEqual(@as(f32, 100), measured.border.width);
    try std.testing.expectEqual(@as(f32, 10), measured.border.height);
}

test "definite Block availability does not define an auto percentage axis" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const flex_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const root_id: FrameNodeId = @fromBackingInt(@intCast(3));

    try tree.appendNode(.{
        .id = leaf_id,
        .kind = .{ .spacer = .{} },
        .parent = flex_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 10 },
                .height = .{ .length = 10 },
            },
        },
    });
    try tree.appendNode(.{
        .id = flex_id,
        .kind = .{ .row = .{} },
        .parent = root_id,
        .style = .{
            .display = .flex,
            .direction = .row,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 40 },
                .height = .{ .percent = 0.5 },
            },
        },
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .align_self = .start,
            .size = .{
                .width = .{ .length = 100 },
                .height = .auto,
            },
        },
    });
    try tree.appendChild(flex_id, leaf_id);
    try tree.appendChild(root_id, flex_id);

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = null,
        .measure_node = measureFlexNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();
    const measured = try block_float.measureNatural(
        &tree,
        tree.nodeConst(root_id) orelse return error.TestUnexpectedResult,
        .{
            .available = .{ .width = 100, .height = 200 },
            .percentage_basis = .{ .width = 100, .height = 200 },
            .height_mode = .definite,
        },
        &context,
    );
    try std.testing.expectEqual(@as(f32, 40), measured.content.width);
    try std.testing.expectEqual(@as(f32, 10), measured.content.height);
    try std.testing.expectEqual(@as(f32, 100), measured.border.width);
    try std.testing.expectEqual(@as(f32, 10), measured.border.height);
}

test "content-sized block root does not reconstruct an unknown axis" {
    MeasureProbe.reset();
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: FrameNodeId = @fromBackingInt(@intCast(1));
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .label = .{ .text = "probe" } },
        .parent = .root,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .auto,
                .height = .{ .length = 100 },
            },
            .max_size = .{
                .width = .{ .length = 40 },
                .height = .auto,
            },
            .aspect_ratio = 2,
        },
    });

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = MeasureProbe.source,
        .measure_node = measureFlexNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();
    const measured = try block_float.measureNatural(
        &tree,
        tree.nodeConst(root_id) orelse return error.TestUnexpectedResult,
        .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = 100, .height = 100 },
            .width_mode = .min_content,
            .sizing_mode = .content,
            .known_border = .{ .width = null, .height = 20 },
        },
        &context,
    );

    try std.testing.expectEqual(@as(usize, 1), MeasureProbe.calls);
    try std.testing.expect(MeasureProbe.width_is_min_content);
    try std.testing.expectEqual(@as(?f32, null), MeasureProbe.known_width);
    try std.testing.expectEqual(@as(?f32, 20), MeasureProbe.known_height);
    try std.testing.expectEqual(@as(?f32, 20), MeasureProbe.available_height);
    try std.testing.expectEqual(@as(f32, 10), measured.border.width);
    try std.testing.expectEqual(@as(f32, 20), measured.border.height);
}

test "inherent block root known border overrides style" {
    MeasureProbe.reset();
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: FrameNodeId = @fromBackingInt(@intCast(1));
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .label = .{ .text = "probe" } },
        .parent = .root,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 80 },
                .height = .auto,
            },
            .max_size = .{
                .width = .{ .length = 10 },
                .height = .auto,
            },
            .aspect_ratio = 2,
        },
    });

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = MeasureProbe.source,
        .measure_node = measureFlexNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();
    const measured = try block_float.measureNatural(
        &tree,
        tree.nodeConst(root_id) orelse return error.TestUnexpectedResult,
        .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = 100, .height = 100 },
            .known_border = .{ .width = 30, .height = null },
        },
        &context,
    );

    try std.testing.expectEqual(@as(?f32, 30), MeasureProbe.known_width);
    try std.testing.expectEqual(@as(?f32, null), MeasureProbe.known_height);
    try std.testing.expectEqual(@as(f32, 30), measured.border.width);
    try std.testing.expectEqual(@as(f32, 15), measured.border.height);
}

test "content-sized block root floors known border by edges and gutter" {
    MeasureProbe.reset();
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: FrameNodeId = @fromBackingInt(@intCast(1));
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .label = .{ .text = "probe" } },
        .parent = .root,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 100 },
            },
            .border_inset = .{
                .top = .{ .length = 2 },
                .right = .{ .length = 2 },
                .bottom = .{ .length = 2 },
                .left = .{ .length = 2 },
            },
            .padding_inset = .{
                .top = .{ .length = 4 },
                .right = .{ .length = 4 },
                .bottom = .{ .length = 4 },
                .left = .{ .length = 4 },
            },
            .overflow = .{ .width = .scroll, .height = .scroll },
            .scrollbar_width = 15,
        },
    });

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = MeasureProbe.source,
        .measure_node = measureFlexNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();
    const measured = try block_float.measureNatural(
        &tree,
        tree.nodeConst(root_id) orelse return error.TestUnexpectedResult,
        .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = 100, .height = 100 },
            .sizing_mode = .content,
            .known_border = .{ .width = 5, .height = 5 },
        },
        &context,
    );

    try std.testing.expectEqual(@as(?f32, 0), MeasureProbe.known_width);
    try std.testing.expectEqual(@as(?f32, 0), MeasureProbe.known_height);
    try std.testing.expectEqual(@as(f32, 27), measured.border.width);
    try std.testing.expectEqual(@as(f32, 27), measured.border.height);
}

test "block root sizing override does not leak to descendants" {
    MeasureProbe.reset();
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const root_id: FrameNodeId = @fromBackingInt(@intCast(2));
    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .label = .{ .text = "probe" } },
        .parent = root_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 12 },
                .height = .{ .length = 8 },
            },
        },
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 200 },
                .height = .auto,
            },
        },
    });
    try tree.appendChild(root_id, child_id);

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = MeasureProbe.source,
        .measure_node = measureFlexNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();
    const measured = try block_float.measureNatural(
        &tree,
        tree.nodeConst(root_id) orelse return error.TestUnexpectedResult,
        .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = 100, .height = 100 },
            .sizing_mode = .content,
            .known_border = .{ .width = 80, .height = null },
        },
        &context,
    );

    try std.testing.expectEqual(@as(usize, 1), MeasureProbe.calls);
    try std.testing.expectEqual(@as(?f32, 12), MeasureProbe.known_width);
    try std.testing.expectEqual(@as(?f32, 8), MeasureProbe.known_height);
    try std.testing.expectEqual(@as(f32, 80), measured.border.width);
    try std.testing.expectEqual(@as(f32, 8), measured.border.height);
}

test "block natural measurement returns OutOfMemory when scratch allocation fails" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: FrameNodeId = @fromBackingInt(@intCast(1));
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .auto, .height = .auto },
        },
    });

    var zero_capacity_storage: [0]u8 = .{};
    var exhausted_allocator = std.heap.FixedBufferAllocator.init(&zero_capacity_storage);
    var context: layout_context.LayoutContext = .{
        .allocator = exhausted_allocator.allocator(),
        .measure = null,
        .measure_node = measureFlexNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();
    try std.testing.expectError(
        error.OutOfMemory,
        block_float.measureNatural(
            &tree,
            tree.nodeConst(root_id).?,
            .{
                .available = .{ .width = 100, .height = 100 },
                .percentage_basis = .{ .width = 100, .height = 100 },
            },
            &context,
        ),
    );
}
