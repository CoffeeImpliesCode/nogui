//! Verifies that flex natural measurement resolves percentages from the request basis.

const std = @import("std");
const FrameNodeId = @import("../id.zig").FrameNodeId;
const layout_context = @import("context.zig");
const widget = @import("../widget.zig");
const flex = @import("flex.zig");

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

fn freshMeasureNatural(
    tree: *WidgetTree,
    node: *const widget.WidgetNode,
    request: layout_context.Request,
) !layout_context.Measured {
    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = null,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();
    return flex.measureNatural(tree, node, request, &context);
}

test "measureNatural resolves flex percentages from request basis" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: FrameNodeId = @fromBackingInt(@intCast(1));
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .row = .{} },
        .parent = .root,
        .style = .{
            .display = .flex,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .percent = 0.5 },
                .height = .{ .length = 20 },
            },
        },
    });

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = null,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();
    const root = tree.nodeConst(root_id) orelse return error.TestUnexpectedResult;
    const measured = try flex.measureNatural(
        &tree,
        root,
        .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = 200, .height = 200 },
        },
        &context,
    );

    try std.testing.expectEqual(@as(f32, 100), measured.border.width);
    try std.testing.expectEqual(@as(f32, 20), measured.border.height);
}

test "measureNatural preserves indefinite edges across a definite basis" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: FrameNodeId = @fromBackingInt(@intCast(1));
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .row = .{} },
        .parent = .root,
        .style = .{
            .display = .flex,
            .box_sizing = .content_box,
            .size = .{
                .width = .auto,
                .height = .{ .length = 10 },
            },
            .padding_inset = .{
                .top = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .percent = 0.1 },
                .right = .{ .percent = 0.1 },
            },
        },
    });

    var storage = layout_context.LayoutStorage.init(std.testing.allocator);
    defer storage.deinit();
    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = null,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
        .storage = &storage,
    };
    defer context.deinit();
    const root = tree.nodeConst(root_id) orelse return error.TestUnexpectedResult;

    const indefinite_request: layout_context.Request = .{
        .available = .{ .width = 40, .height = 10 },
        .percentage_basis = .{ .width = null, .height = 10 },
        .width_mode = .max_content,
    };
    const indefinite = try flex.measureNatural(&tree, root, indefinite_request, &context);
    try std.testing.expectEqual(
        try freshMeasureNatural(&tree, root, indefinite_request),
        indefinite,
    );

    var definite_request = indefinite_request;
    definite_request.percentage_basis.width = 80;
    const definite = try flex.measureNatural(&tree, root, definite_request, &context);
    try std.testing.expectEqual(
        try freshMeasureNatural(&tree, root, definite_request),
        definite,
    );
    try std.testing.expectEqual(@as(f32, 16), definite.border.width);

    var repeated_indefinite_request = indefinite_request;
    repeated_indefinite_request.available.width = 60;
    const repeated_indefinite = try flex.measureNatural(
        &tree,
        root,
        repeated_indefinite_request,
        &context,
    );
    try std.testing.expectEqual(
        try freshMeasureNatural(&tree, root, repeated_indefinite_request),
        repeated_indefinite,
    );
    try std.testing.expectEqual(indefinite.border.width, repeated_indefinite.border.width);
}

test "measureNatural distinguishes an indefinite edge basis from zero" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: FrameNodeId = @fromBackingInt(@intCast(1));
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .row = .{} },
        .parent = .root,
        .style = .{
            .display = .flex,
            .box_sizing = .content_box,
            .size = .{
                .width = .auto,
                .height = .{ .length = 10 },
            },
            .padding_inset = .{
                .top = .{ .length = 0 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .percent = std.math.nan(f32) },
            },
        },
    });

    var storage = layout_context.LayoutStorage.init(std.testing.allocator);
    defer storage.deinit();
    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = null,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
        .storage = &storage,
    };
    defer context.deinit();
    const root = tree.nodeConst(root_id) orelse return error.TestUnexpectedResult;

    const indefinite_request: layout_context.Request = .{
        .available = .{ .width = 40, .height = 10 },
        .percentage_basis = .{ .width = null, .height = 10 },
        .width_mode = .max_content,
    };
    const indefinite = try flex.measureNatural(&tree, root, indefinite_request, &context);
    try std.testing.expectEqual(
        try freshMeasureNatural(&tree, root, indefinite_request),
        indefinite,
    );

    var zero_request = indefinite_request;
    zero_request.percentage_basis.width = 0;
    try std.testing.expectError(
        error.InvalidStyle,
        flex.measureNatural(&tree, root, zero_request, &context),
    );

    var repeated_indefinite_request = indefinite_request;
    repeated_indefinite_request.available.width = 60;
    const repeated_indefinite = try flex.measureNatural(
        &tree,
        root,
        repeated_indefinite_request,
        &context,
    );
    try std.testing.expectEqual(
        try freshMeasureNatural(&tree, root, repeated_indefinite_request),
        repeated_indefinite,
    );
}
