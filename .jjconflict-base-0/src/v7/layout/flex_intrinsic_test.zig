//! Verifies that intrinsic flex measurement is scoped to each container's auto main axis.

const std = @import("std");
const Id = @import("../id.zig").Id;
const layout_context = @import("context.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");
const flex = @import("flex.zig");

const Style = style.Style;
const WidgetKind = widget.WidgetKind;
const WidgetTree = widget.WidgetTree;

fn appendNode(tree: *WidgetTree, id: Id, parent: Id, node_style: Style) !void {
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

fn fixedItem(width: f32, height: f32) Style {
    return .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = width },
            .height = .{ .length = height },
        },
    };
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

fn expectSize(expected: widget.Size, actual: widget.Size) !void {
    const tolerance: f32 = 0.001;
    try std.testing.expectApproxEqAbs(expected.width, actual.width, tolerance);
    try std.testing.expectApproxEqAbs(expected.height, actual.height, tolerance);
}

fn exactF32FromUsize(value: usize) f32 {
    // An f32 represents every u24 value exactly.
    std.debug.assert(value <= @as(usize, std.math.maxInt(u24)));
    const bounded: u24 = @intCast(value);
    return @floatFromInt(bounded);
}

const ProbeWidthMode = enum {
    definite,
    min_content,
    max_content,
};

const BreakableMeasureProbe = struct {
    const glyph_width: f32 = 10;
    const line_height: f32 = 10;

    var calls: usize = 0;
    var width_mode: ?ProbeWidthMode = null;
    var definite_width: ?f32 = null;

    fn reset() void {
        calls = 0;
        width_mode = null;
        definite_width = null;
    }

    fn measure(text: []const u8, input: layout_context.MeasureInput) widget.Size {
        calls += 1;

        var min_line_length: usize = 0;
        var max_line_length: usize = 0;
        var segments = std.mem.splitSequence(u8, text, "\xE2\x80\x8B");
        while (segments.next()) |segment| {
            min_line_length = @max(min_line_length, segment.len);
            max_line_length += segment.len;
        }

        const min_content_width =
            exactF32FromUsize(min_line_length) * glyph_width;
        const max_content_width =
            exactF32FromUsize(max_line_length) * glyph_width;
        const requested_width: f32 = switch (input.available_space.width) {
            .definite => |width| blk: {
                width_mode = .definite;
                definite_width = width;
                break :blk width;
            },
            .min_content => blk: {
                width_mode = .min_content;
                break :blk min_content_width;
            },
            .max_content => blk: {
                width_mode = .max_content;
                break :blk max_content_width;
            },
        };
        const available_width = input.known_dimensions.width orelse requested_width;
        const width = @max(
            min_content_width,
            @min(available_width, max_content_width),
        );
        const inline_capacity: usize = @intFromFloat(@floor(width / glyph_width));

        var line_count: usize = 1;
        var current_line_length: usize = 0;
        segments = std.mem.splitSequence(u8, text, "\xE2\x80\x8B");
        while (segments.next()) |segment| {
            const combined = current_line_length + segment.len;
            if (combined > inline_capacity) {
                if (current_line_length > 0) line_count += 1;
                current_line_length = segment.len;
            } else {
                current_line_length = combined;
            }
        }

        return .{
            .width = width,
            .height = exactF32FromUsize(line_count) * line_height,
        };
    }
};

const CrossMaxContributionProbe = struct {
    var calls: usize = 0;
    var definite_calls: usize = 0;
    var max_content_calls: usize = 0;
    var definite_height: ?f32 = null;
    var automatic_max_definite_calls: usize = 0;
    var automatic_max_definite_height: ?f32 = null;
    var automatic_min_definite_calls: usize = 0;
    var automatic_min_definite_height: ?f32 = null;
    var automatic_max_content_calls: usize = 0;

    fn reset() void {
        calls = 0;
        definite_calls = 0;
        max_content_calls = 0;
        definite_height = null;
    }

    fn resetAutomatic() void {
        automatic_max_definite_calls = 0;
        automatic_max_definite_height = null;
        automatic_min_definite_calls = 0;
        automatic_min_definite_height = null;
        automatic_max_content_calls = 0;
    }

    fn measure(_: []const u8, input: layout_context.MeasureInput) widget.Size {
        calls += 1;
        return switch (input.available_space.height) {
            .definite => |height| blk: {
                definite_calls += 1;
                definite_height = height;
                break :blk .{ .width = 20, .height = 20 };
            },
            .min_content => .{ .width = 20, .height = 20 },
            .max_content => blk: {
                max_content_calls += 1;
                break :blk .{ .width = 100, .height = 20 };
            },
        };
    }

    fn measureAutomaticMinimum(
        _: []const u8,
        input: layout_context.MeasureInput,
    ) widget.Size {
        const main_max_content = switch (input.available_space.width) {
            .definite => false,
            .min_content => false,
            .max_content => true,
        };
        const cross_definite = switch (input.available_space.height) {
            .definite => true,
            .min_content, .max_content => false,
        };
        if (main_max_content and cross_definite) {
            automatic_max_definite_calls += 1;
            automatic_max_definite_height = switch (input.available_space.height) {
                .definite => |height| height,
                .min_content, .max_content => unreachable,
            };
            return .{ .width = 100, .height = 20 };
        }
        if (!main_max_content and cross_definite) {
            automatic_min_definite_calls += 1;
            automatic_min_definite_height = switch (input.available_space.height) {
                .definite => |height| height,
                .min_content, .max_content => unreachable,
            };
            return .{ .width = 5, .height = 20 };
        }
        if (main_max_content) {
            automatic_max_content_calls += 1;
            return .{ .width = 20, .height = 20 };
        }
        return .{ .width = 5, .height = 20 };
    }
};

test "measureNatural scopes intrinsic height to auto-sized flex container" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const nested_id: Id = @enumFromInt(3);
    const outer_id: Id = @enumFromInt(4);

    try appendNode(&tree, first_id, nested_id, fixedItem(10, 60));
    try appendNode(&tree, second_id, nested_id, fixedItem(10, 60));
    try appendNode(&tree, nested_id, outer_id, .{
        .display = .flex,
        .direction = .column,
        .flex_wrap = .wrap,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .auto,
            .height = .{ .length = 100 },
        },
    });
    try appendNode(&tree, outer_id, .root, .{
        .display = .flex,
        .direction = .column,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    });
    try tree.appendChild(nested_id, first_id);
    try tree.appendChild(nested_id, second_id);
    try tree.appendChild(outer_id, nested_id);

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = null,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();
    const outer = tree.nodeConst(outer_id) orelse return error.TestUnexpectedResult;
    const measured = try flex.measureNatural(
        &tree,
        outer,
        .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = 100, .height = 100 },
            .height_mode = .max_content,
        },
        &context,
    );

    try expectSize(.{ .width = 20, .height = 100 }, measured.content);
    try expectSize(.{ .width = 20, .height = 100 }, measured.border);
}

test "measureNatural defers percentage margins below intrinsic auto width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const outer_id: Id = @enumFromInt(2);

    var child_style = fixedItem(10, 10);
    child_style.margin_inset.left = .{ .percent = 0.5 };
    try appendNode(&tree, child_id, outer_id, child_style);
    try appendNode(&tree, outer_id, .root, .{
        .display = .flex,
        .direction = .row,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = 10 } },
    });
    try tree.appendChild(outer_id, child_id);

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = null,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();
    const outer = tree.nodeConst(outer_id) orelse return error.TestUnexpectedResult;
    const measured = try flex.measureNatural(
        &tree,
        outer,
        .{
            .available = .{ .width = 100, .height = 10 },
            .percentage_basis = .{ .width = 200, .height = 10 },
            .width_mode = .max_content,
        },
        &context,
    );

    try expectSize(.{ .width = 10, .height = 10 }, measured.content);
    try expectSize(.{ .width = 10, .height = 10 }, measured.border);
}

test "max-content forwards definite child cross maximum" {
    BreakableMeasureProbe.reset();

    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .label = .{ .text = "HH\xE2\x80\x8BHH\xE2\x80\x8BHH" } },
        .parent = container_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .auto, .height = .auto },
            .min_size = .{
                .width = .auto,
                .height = .{ .length = 0 },
            },
            .max_size = .{
                .width = .{ .length = 40 },
                .height = .auto,
            },
        },
    });
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .column,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    });
    try tree.appendChild(container_id, child_id);

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = BreakableMeasureProbe.measure,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();
    const container = tree.nodeConst(container_id) orelse return error.TestUnexpectedResult;
    const measured = try flex.measureNatural(
        &tree,
        container,
        .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = 100, .height = 100 },
            .width_mode = .max_content,
            .height_mode = .max_content,
        },
        &context,
    );

    try std.testing.expectEqual(@as(usize, 1), BreakableMeasureProbe.calls);
    try std.testing.expectEqual(
        ProbeWidthMode.definite,
        BreakableMeasureProbe.width_mode.?,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 40),
        BreakableMeasureProbe.definite_width.?,
        @as(f32, 0.001),
    );
    try expectSize(.{ .width = 40, .height = 20 }, measured.content);
    try expectSize(.{ .width = 40, .height = 20 }, measured.border);
}

test "max-content ignores transferred cross max for contribution" {
    CrossMaxContributionProbe.reset();

    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .label = .{ .text = "probe" } },
        .parent = container_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .auto, .height = .auto },
            .min_size = .{
                .width = .{ .length = 0 },
                .height = .auto,
            },
            .max_size = .{
                .width = .{ .length = 40 },
                .height = .auto,
            },
            .aspect_ratio = 2,
            .flex_basis = .{ .length = 0 },
            .grow = 1,
        },
    });
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    });
    try tree.appendChild(container_id, child_id);

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = CrossMaxContributionProbe.measure,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();
    const container = tree.nodeConst(container_id) orelse return error.TestUnexpectedResult;
    const measured = try flex.measureNatural(
        &tree,
        container,
        .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = 100, .height = 100 },
            .width_mode = .max_content,
            .height_mode = .max_content,
        },
        &context,
    );

    try std.testing.expect(CrossMaxContributionProbe.definite_calls > 0);
    try std.testing.expect(CrossMaxContributionProbe.max_content_calls > 0);
    try std.testing.expectApproxEqAbs(
        @as(f32, 20),
        CrossMaxContributionProbe.definite_height.?,
        @as(f32, 0.001),
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 40),
        measured.content.width,
        @as(f32, 0.001),
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 40),
        measured.border.width,
        @as(f32, 0.001),
    );
}

test "max-content uses aspect-derived preferred main with zero basis" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    try appendNode(&tree, child_id, container_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .auto,
            .height = .{ .length = 10 },
        },
        .min_size = .{
            .width = .{ .length = 0 },
            .height = .auto,
        },
        .aspect_ratio = 2,
        .flex_basis = .{ .length = 0 },
        .grow = 0,
    });
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    });
    try tree.appendChild(container_id, child_id);

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = null,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();
    const container = tree.nodeConst(container_id) orelse return error.TestUnexpectedResult;
    const measured = try flex.measureNatural(
        &tree,
        container,
        .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = 100, .height = 100 },
            .width_mode = .max_content,
            .height_mode = .max_content,
        },
        &context,
    );

    try expectSize(.{ .width = 20, .height = 10 }, measured.content);
    try expectSize(.{ .width = 20, .height = 10 }, measured.border);
}

test "max-content measures automatic minimum under min-content main mode" {
    CrossMaxContributionProbe.resetAutomatic();

    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .label = .{ .text = "probe" } },
        .parent = container_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .auto, .height = .auto },
            .max_size = .{
                .width = .{ .length = 40 },
                .height = .auto,
            },
            .aspect_ratio = 2,
            .flex_basis = .{ .length = 0 },
            .grow = 1,
        },
    });
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    });
    try tree.appendChild(container_id, child_id);

    var context: layout_context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = CrossMaxContributionProbe.measureAutomaticMinimum,
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    defer context.deinit();
    const container = tree.nodeConst(container_id) orelse return error.TestUnexpectedResult;
    const measured = try flex.measureNatural(
        &tree,
        container,
        .{
            .available = .{ .width = 100, .height = 100 },
            .percentage_basis = .{ .width = 100, .height = 100 },
            .width_mode = .max_content,
            .height_mode = .max_content,
        },
        &context,
    );

    try std.testing.expect(CrossMaxContributionProbe.automatic_max_definite_calls > 0);
    try std.testing.expect(CrossMaxContributionProbe.automatic_min_definite_calls > 0);
    try std.testing.expect(CrossMaxContributionProbe.automatic_max_content_calls > 0);
    try std.testing.expectApproxEqAbs(
        @as(f32, 20),
        CrossMaxContributionProbe.automatic_max_definite_height.?,
        @as(f32, 0.001),
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 20),
        CrossMaxContributionProbe.automatic_min_definite_height.?,
        @as(f32, 0.001),
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 20),
        measured.content.width,
        @as(f32, 0.001),
    );
}
