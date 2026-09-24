const std = @import("std");
const image = @import("image_view.zig");
const paint = @import("paint.zig");
const element = @import("element.zig");
const drawcmd = @import("drawcmd.zig");
const widget = @import("widget.zig");
const DrawCtx = @import("drawctx.zig").DrawCtx;

const bounds: element.Geometry = .{
    .border = .{ .x = 10, .y = 20, .w = 100, .h = 100 },
    .content = .{ .x = 10, .y = 20, .w = 100, .h = 100 },
};

fn paintView(view: image.ImageView, records: *std.ArrayList(element.PaintRecord)) !void {
    var writer: element.PaintWriter = .{ .allocator = std.testing.allocator, .records = records };
    var phase: image.ImageView.PhaseState = .{};
    try view.paint(&phase, bounds, &writer);
}

test "api-w14 cover crops centered source UV while keeping destination within content" {
    var records: std.ArrayList(element.PaintRecord) = .empty;
    defer records.deinit(std.testing.allocator);
    const view: image.ImageView = .{
        .intrinsic = .{ .width = 200, .height = 100 },
        .source = .{ .ready = .{ .index = 7, .generation = 12 } },
        .generation = 12,
        .fit = .cover,
        .label = "Wide landscape",
    };
    try paintView(view, &records);
    try std.testing.expectEqual(@as(usize, 1), records.items.len);
    const spec = records.items[0].image;
    try std.testing.expectEqual(paint.Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, spec.bounds);
    try std.testing.expectEqual(paint.Rect{ .x = 0.25, .y = 0, .w = 0.5, .h = 1 }, spec.src);
    try std.testing.expectEqual(@as(u32, 7), spec.texture_index);
    var phase: image.ImageView.PhaseState = .{};
    try std.testing.expectEqual(element.Role.image, (try view.semantics(&phase, bounds)).?.role);
    try std.testing.expectEqualStrings("Wide landscape", (try view.semantics(&phase, bounds)).?.label);
}

test "api-w14 alignment and none fit crop both axes with fractional UV" {
    var records: std.ArrayList(element.PaintRecord) = .empty;
    defer records.deinit(std.testing.allocator);
    try paintView(.{
        .intrinsic = .{ .width = 200, .height = 150 },
        .fit = .none,
        .alignment = .bottom_right,
        .generation = 1,
        .source = .{ .ready = .{ .index = 9, .generation = 1 } },
    }, &records);
    const spec = records.items[0].image;
    try std.testing.expectEqual(paint.Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, spec.bounds);
    try std.testing.expectEqual(@as(f32, 0.5), spec.src.x);
    try std.testing.expectEqual(@as(f32, 0.5), spec.src.w);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), spec.src.y, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), spec.src.h, 0.000001);
}

test "api-w14 pending and failed paints are distinct and stale descriptors use pending fallback" {
    var records: std.ArrayList(element.PaintRecord) = .empty;
    defer records.deinit(std.testing.allocator);
    const base: image.ImageView = .{ .intrinsic = .{ .width = 40, .height = 20 }, .generation = 6 };
    try paintView(base, &records);
    const pending = records.items[0].rect.fill.?.solid;
    records.clearRetainingCapacity();
    try paintView(.{ .intrinsic = base.intrinsic, .source = .failed }, &records);
    const failed = records.items[0].rect.fill.?.solid;
    try std.testing.expect(!std.meta.eql(pending, failed));
    records.clearRetainingCapacity();
    try paintView(.{
        .intrinsic = base.intrinsic,
        .generation = 6,
        .source = .{ .ready = .{ .index = 21, .generation = 5 } },
    }, &records);
    try std.testing.expect(std.meta.eql(pending, records.items[0].rect.fill.?.solid));
    records.clearRetainingCapacity();
    try paintView(.{
        .intrinsic = base.intrinsic,
        .generation = 6,
        .source = .{ .ready = .{ .index = 0xFFFFFFFF, .generation = 6 } },
    }, &records);
    try std.testing.expect(std.meta.eql(pending, records.items[0].rect.fill.?.solid));
}

test "api-w14 intrinsic aspect and known dimensions preserve image proportions" {
    const view: image.ImageView = .{ .intrinsic = .{ .width = 200, .height = 100 } };
    const input: element.MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
    };
    try std.testing.expectEqual(widget.Size{ .width = 200, .height = 100 }, try view.measure(input));
    var known_width = input;
    known_width.known_dimensions.width = 80;
    try std.testing.expectEqual(widget.Size{ .width = 80, .height = 40 }, try view.measure(known_width));
    var known_height = input;
    known_height.known_dimensions.height = 50;
    try std.testing.expectEqual(widget.Size{ .width = 100, .height = 50 }, try view.measure(known_height));
}

test "api-w14 image command keeps parent background, image and child in tree paint order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = widget.WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
    const id = try ctx.elementContainer(image.ImageView, .{
        .intrinsic = .{ .width = 200, .height = 100 },
        .generation = 2,
        .source = .{ .ready = .{ .index = 17, .generation = 2 } },
        .fit = .cover,
    }, .{
        .position = .absolute,
        .width = 100,
        .height = 100,
        .fill = [4]f32{ 0.2, 0.3, 0.4, 1 },
        .opacity = 0.6,
        .layer = 3,
    });
    _ = try ctx.button(.{ .key = .{ .static = "on-top" }, .label = "top", .width = 10, .height = 8 });
    ctx.pop();
    try element.prepareFrame(&ctx, .{ .allocator = arena.allocator(), .available = .{ .width = 200, .height = 200 } });
    const commands = try drawcmd.collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(commands);
    try std.testing.expectEqual(@as(usize, 3), commands.len);
    try std.testing.expectEqual(@as(u32, 0), commands[0].rect_paint.order.?);
    const image_spec = commands[1].image_paint.?;
    try std.testing.expectEqual(@as(u32, 1), image_spec.order.?);
    try std.testing.expectEqual(@as(f32, 0.6), image_spec.opacity);
    try std.testing.expectEqual(@as(u32, 3), image_spec.layer);
    try std.testing.expectEqual(@as(u32, 2), commands[2].rect_paint.order.?);
    try std.testing.expectEqual(widget.visualContentRect(&tree, id).w, image_spec.bounds.w);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), image_spec.clip_id);
    try std.testing.expectEqual(paint.Rect{ .x = 0.25, .y = 0, .w = 0.5, .h = 1 }, image_spec.src);
    var list = paint.PaintList.init(arena.allocator(), &.{}, commands.len);
    for (commands) |cmd| {
        if (cmd.image_paint) |spec| {
            try list.addImage(spec);
        } else if (cmd.path_paint) |spec| {
            try list.addPath(spec);
        } else {
            try list.addRect(cmd.rect_paint);
        }
    }
    try std.testing.expectEqual(@as(u32, 17), list.records.items[1].shape.image.texture_index);
}

test "api-w14 authored image rejects invalid UV, opacity, grayscale and descriptor sentinel" {
    var list = paint.PaintList.init(std.testing.allocator, &.{}, 3);
    defer list.deinit();
    try std.testing.expectError(error.InvalidPaint, list.addImage(.{
        .bounds = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .src = .{ .x = 0.8, .y = 0, .w = 0.3, .h = 1 },
        .texture_index = 1,
    }));
    try std.testing.expectError(error.InvalidPaint, list.addImage(.{
        .bounds = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .texture_index = 0xFFFFFFFF,
    }));
    try std.testing.expectError(error.InvalidPaint, list.addImage(.{
        .bounds = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .texture_index = 1,
        .opacity = 2,
    }));
    for ([_]f32{ -0.01, 1.01, std.math.nan(f32), std.math.inf(f32) }) |amount| {
        try std.testing.expectError(error.InvalidPaint, list.addImage(.{
            .bounds = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
            .texture_index = 1,
            .grayscale = amount,
        }));
    }
    try std.testing.expectEqual(@as(usize, 0), list.records.items.len);
}
