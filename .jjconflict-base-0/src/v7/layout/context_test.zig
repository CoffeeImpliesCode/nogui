//! Specifies the natural-measure request validation contract.

const std = @import("std");
const Id = @import("../id.zig").Id;
const style = @import("../style.zig");
const sizing = @import("sizing.zig");
const widget = @import("../widget.zig");
const context = @import("context.zig");

const Style = style.Style;
const WidgetTree = widget.WidgetTree;

test "natural request exposes sizing mode and known border" {
    const request_fields = @typeInfo(context.Request).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 6), request_fields.len);
    try std.testing.expectEqualStrings("available", request_fields[0].name);
    try std.testing.expectEqualStrings("percentage_basis", request_fields[1].name);
    try std.testing.expectEqualStrings("width_mode", request_fields[2].name);
    try std.testing.expectEqualStrings("height_mode", request_fields[3].name);
    try std.testing.expectEqualStrings("sizing_mode", request_fields[4].name);
    try std.testing.expectEqualStrings("known_border", request_fields[5].name);

    const request: context.Request = .{
        .available = .{ .width = 100, .height = 100 },
        .percentage_basis = .{ .width = null, .height = null },
    };
    try std.testing.expectEqual(context.SizingMode.inherent, request.sizing_mode);
    try std.testing.expectEqual(
        sizing.OptionalSize{ .width = null, .height = null },
        request.known_border,
    );
}

fn appendRoot(tree: *WidgetTree, node_style: Style) !*const widget.WidgetNode {
    const root_id: Id = @enumFromInt(1);
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = node_style,
    });
    return tree.nodeConst(root_id).?;
}

test "natural request accepts explicit width percentage basis that differs from available space" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try appendRoot(&tree, .{
        .display = .block,
        .size = .{
            .width = .{ .percent = 0.5 },
            .height = .auto,
        },
    });

    try context.validateNaturalRequest(&tree, root, .{
        .available = .{ .width = 100, .height = 100 },
        .percentage_basis = .{ .width = 200, .height = null },
    });
}

test "natural request defers width percentages when the basis is indefinite" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try appendRoot(&tree, .{
        .display = .block,
        .size = .{
            .width = .{ .percent = 0.5 },
            .height = .auto,
        },
    });

    try context.validateNaturalRequest(&tree, root, .{
        .available = .{ .width = 100, .height = 100 },
        .percentage_basis = .{ .width = null, .height = null },
    });
}

test "natural request accepts explicit height percentage basis that differs from available space" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try appendRoot(&tree, .{
        .display = .block,
        .size = .{
            .width = .auto,
            .height = .{ .percent = 0.5 },
        },
    });

    try context.validateNaturalRequest(&tree, root, .{
        .available = .{ .width = 100, .height = 100 },
        .percentage_basis = .{ .width = null, .height = 200 },
    });
}

test "natural request defers height percentages when the basis is indefinite" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try appendRoot(&tree, .{
        .display = .block,
        .size = .{
            .width = .auto,
            .height = .{ .percent = 0.5 },
        },
    });

    try context.validateNaturalRequest(&tree, root, .{
        .available = .{ .width = 100, .height = 100 },
        .percentage_basis = .{ .width = null, .height = null },
    });
}

test "natural request rejects non-concrete available space" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try appendRoot(&tree, .{ .display = .block });

    try std.testing.expectError(
        error.InvalidStyle,
        context.validateNaturalRequest(&tree, root, .{
            .available = .{ .width = -1, .height = 100 },
            .percentage_basis = .{ .width = null, .height = null },
        }),
    );
    try std.testing.expectError(
        error.InvalidStyle,
        context.validateNaturalRequest(&tree, root, .{
            .available = .{ .width = 100, .height = std.math.nan(f32) },
            .percentage_basis = .{ .width = null, .height = null },
        }),
    );
}

test "measureText: ellipsis forces single-line policy without a width cap, clip stays flow" {
    const policyMeasure = struct {
        fn measure(_: []const u8, input: context.MeasureInput) widget.Size {
            return .{
                .width = if (input.line_policy == .single_line) 40 else 20,
                .height = if (input.line_policy == .single_line) 10 else 30,
            };
        }
    }.measure;
    const input: context.MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .{ .definite = 20 }, .height = .max_content },
        .font_size = 20,
        .font_id = 0,
    };

    const bounded = try context.measureText(policyMeasure, "a\nb", input, .ellipsis, 20);
    try std.testing.expectEqual(@as(f32, 20), bounded.width);
    try std.testing.expectEqual(@as(f32, 10), bounded.height);
    const unbounded_ellipsis = try context.measureText(policyMeasure, "a\nb", input, .ellipsis, null);
    try std.testing.expectEqual(@as(f32, 40), unbounded_ellipsis.width);
    try std.testing.expectEqual(@as(f32, 10), unbounded_ellipsis.height);
    const unbounded_clip = try context.measureText(policyMeasure, "a\nb", input, .clip, null);
    try std.testing.expectEqual(@as(f32, 20), unbounded_clip.width);
    try std.testing.expectEqual(@as(f32, 30), unbounded_clip.height);
}

fn testMeasureNode(
    _: *context.LayoutContext,
    _: *widget.WidgetTree,
    _: *const widget.WidgetNode,
    _: context.Request,
) context.LayoutError!context.Measured {
    return .{
        .content = .{ .width = 0, .height = 0 },
        .border = .{ .width = 0, .height = 0 },
    };
}

fn testLayoutNode(
    _: *context.LayoutContext,
    _: *widget.WidgetTree,
    _: *widget.WidgetNode,
    _: context.LayoutRequest,
) context.LayoutError!void {}

test "nested block scratch uses one tree-sized allocation" {
    var layout_context: context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = null,
        .measure_node = testMeasureNode,
        .layout_node = testLayoutNode,
    };
    defer layout_context.deinit();

    const outer = try layout_context.acquireBlockScratch(u64, 8);
    outer[0] = 11;
    try layout_context.setBlockScratchCount(u64, 1);
    try std.testing.expectError(
        error.InvalidStyle,
        layout_context.acquireBlockScratch(u32, 16),
    );
    const inner = try layout_context.acquireBlockScratch(u64, 8);
    try std.testing.expectEqual(@as(usize, 7), inner.len);
    inner[0] = 22;
    try layout_context.setBlockScratchCount(u64, 1);
    layout_context.releaseBlockScratch();
    try std.testing.expectEqual(@as(u64, 11), outer[0]);
    layout_context.releaseBlockScratch();

    try std.testing.expectEqual(
        @divExact(@sizeOf(u64) * 8, @sizeOf(u128)),
        layout_context.block_scratch_words.?.len,
    );
}

test "TextMeasurementCache caches unconstrained size for single-line text and reuses across wider available bounds" {
    TextMeasureProbe.reset();
    var layout_context: context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = TextMeasureProbe.measure,
        .measure_node = testMeasureNode,
        .layout_node = testLayoutNode,
    };
    defer layout_context.deinit();

    const input_narrow: context.MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{
            .width = .{ .definite = 100 },
            .height = .{ .definite = 40 },
        },
        .font_size = 20,
        .font_id = 3,
    };
    const first = try layout_context.measureTextCached(
        5,
        "abcd",
        input_narrow,
        .visible,
        null,
    );
    try std.testing.expectEqual(@as(f32, 40), first.width);
    try std.testing.expectEqual(@as(usize, 1), TextMeasureProbe.calls);

    var input_wide = input_narrow;
    input_wide.available_space.width = .{ .definite = 200 };
    const second = try layout_context.measureTextCached(
        5,
        "abcd",
        input_wide,
        .visible,
        null,
    );
    try std.testing.expectEqual(@as(f32, 40), second.width);
    try std.testing.expectEqual(@as(usize, 1), TextMeasureProbe.calls);

    var input_max = input_narrow;
    input_max.available_space.width = .max_content;
    const third = try layout_context.measureTextCached(
        5,
        "abcd",
        input_max,
        .visible,
        null,
    );
    try std.testing.expectEqual(@as(f32, 40), third.width);
    try std.testing.expectEqual(@as(usize, 1), TextMeasureProbe.calls);
}
