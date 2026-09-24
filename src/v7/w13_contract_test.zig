const std = @import("std");
const path = @import("path.zig");
const paint = @import("paint.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApprox = std.testing.expectApproxEqAbs;

test "api-w13 path curves arcs close and affine produce bounded window geometry" {
    var builder = path.Builder.init(std.testing.allocator, 16);
    defer builder.deinit();
    try builder.moveTo(.{ .x = 2, .y = 3 });
    try builder.lineTo(.{ .x = 6, .y = 3 });
    try builder.quadraticTo(.{ .x = 8, .y = 5 }, .{ .x = 6, .y = 7 });
    try builder.cubicTo(.{ .x = 4, .y = 9 }, .{ .x = 2, .y = 9 }, .{ .x = 2, .y = 7 });
    try builder.arc(.{ .x = 2, .y = 5 }, .{ .x = 2, .y = 2 }, .{ .start = std.math.pi / 2.0, .sweep = -std.math.pi });
    try builder.close();
    const shape = builder.path();
    var curves: [128]path.Quadratic = undefined;
    const geometry = try path.tessellate(shape, &curves, .{
        .transform = .{ .a = 2, .d = 2, .tx = 10, .ty = 20 },
        .tolerance = 0.1,
        .close_open = true,
    });
    try expect(geometry.len() >= 9);
    try expect(geometry.bounds.x >= 9);
    try expect(geometry.bounds.y >= 24);
    try expect(geometry.bounds.w > 8);
    try expect(geometry.bounds.h > 8);
    try expectApprox(@as(f32, 14), geometry.curves[0].p0.x, 0.001);
    try expectApprox(@as(f32, 26), geometry.curves[0].p0.y, 0.001);
    try expectApprox(@as(f32, 22), geometry.curves[0].p2.x, 0.001);
}

test "api-w13 evenodd hole differs from nonzero on nested same-direction outlines" {
    var builder = path.Builder.init(std.testing.allocator, 16);
    defer builder.deinit();
    for ([_][4]path.Point{
        .{ .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 0 }, .{ .x = 8, .y = 8 }, .{ .x = 0, .y = 8 } },
        .{ .{ .x = 2, .y = 2 }, .{ .x = 6, .y = 2 }, .{ .x = 6, .y = 6 }, .{ .x = 2, .y = 6 } },
    }) |corners| {
        try builder.moveTo(corners[0]);
        for (corners[1..]) |corner| try builder.lineTo(corner);
        try builder.close();
    }
    var curves: [16]path.Quadratic = undefined;
    const shape = try path.tessellate(builder.path(), &curves, .{ .close_open = true });
    try expect(path.contains(shape.curves, .{ .x = 4, .y = 4 }, .nonzero));
    try expect(!path.contains(shape.curves, .{ .x = 4, .y = 4 }, .even_odd));
    try expect(path.contains(shape.curves, .{ .x = 1, .y = 1 }, .even_odd));
    try expect(!path.contains(shape.curves, .{ .x = 9, .y = 4 }, .nonzero));
}

test "api-w13 dash phase survives corners and explicit tessellation capacity errors" {
    var builder = path.Builder.init(std.testing.allocator, 3);
    defer builder.deinit();
    try builder.moveTo(.{ .x = 0, .y = 0 });
    try builder.lineTo(.{ .x = 6, .y = 0 });
    try builder.lineTo(.{ .x = 6, .y = 6 });
    const shape = builder.path();
    var curves: [16]path.Quadratic = undefined;
    const dashed = try path.tessellate(shape, &curves, .{
        .stroke = .{ .dash = &.{ 4, 2 }, .width = 2 },
    });
    try expectEqual(@as(usize, 2), dashed.len());
    try expectApprox(@as(f32, 0), dashed.curves[0].p0.x, 0.001);
    try expectApprox(@as(f32, 4), dashed.curves[0].p2.x, 0.001);
    try expectApprox(@as(f32, 6), dashed.curves[1].p0.x, 0.001);
    try expectApprox(@as(f32, 4), dashed.curves[1].p2.y, 0.001);
    var small: [1]path.Quadratic = undefined;
    try std.testing.expectError(error.TessellationCapacity, path.tessellate(shape, &small, .{}));
    try std.testing.expectError(error.PathCapacity, builder.arc(
        .{ .x = 0, .y = 0 },
        .{ .x = 2, .y = 2 },
        .{ .start = 0, .sweep = std.math.pi * 2 },
    ));
}

test "api-w13 tiny dash on long segment fails within output budget" {
    const commands = [_]path.Command{
        .{ .move = .{ .x = 0, .y = 0 } },
        .{ .line = .{ .x = 1000000, .y = 0 } },
    };
    var curves: [4]path.Quadratic = undefined;
    try std.testing.expectError(error.TessellationCapacity, path.tessellate(
        .{ .commands = &commands },
        &curves,
        .{ .stroke = .{ .width = 1, .dash = &.{ 0.00001, 0.00001 } } },
    ));
}

test "api-w13 frame paint owns path and shadows and converts theme endpoints once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const palette = [_]paint.Srgb{.{ .r = 1, .g = 0, .b = 0, .a = 1 }};
    var list = paint.PaintList.init(arena.allocator(), &palette, 2);
    var local_commands = [_]path.Command{
        .{ .move = .{ .x = 0, .y = 0 } },
        .{ .line = .{ .x = 8, .y = 0 } },
        .{ .line = .{ .x = 8, .y = 8 } },
        .{ .close = {} },
    };
    var local_shadows = [_]paint.Shadow{.{
        .color = .{ .srgb = .{ .r = 0, .g = 0, .b = 0, .a = 0.5 } },
        .offset = .{ .x = 2, .y = 3 },
        .blur = 3,
        .spread = 1,
        .inset = true,
    }};
    try list.addPath(.{
        .path = .{ .commands = &local_commands },
        .fill = .{ .solid = .{ .palette = 0 } },
        .bounds = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
    });
    try list.addRect(.{
        .bounds = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .fill = .{ .gradient = .{
            .first = .{ .color = .{ .palette = 0 }, .position = 0.25 },
            .second = .{ .color = .{ .srgb = .{ .r = 0, .g = 0, .b = 1, .a = 0.7 } }, .position = 0.75 },
            .angle = 0,
        } },
        .shadows = &local_shadows,
    });
    local_commands[0] = .{ .move = .{ .x = 50, .y = 50 } };
    local_shadows[0].blur = 9;
    try expectEqual(@as(f32, 0), list.records.items[0].shape.path.path.commands[0].move.x);
    try expectEqual(@as(f32, 3), list.records.items[1].shape.rect.shadows[0].blur);
    try expectApprox(@as(f32, 0.6279554), list.records.items[0].shape.path.fill.?.solid.l, 0.001);
    try expectApprox(@as(f32, 0.6279554), list.records.items[1].shape.rect.fill.?.gradient.first.color.l, 0.001);
    try expectEqual(@as(f32, 0.7), list.records.items[1].shape.rect.fill.?.gradient.second.color.alpha);
    try std.testing.expectError(error.PaintCapacity, list.addRect(.{
        .bounds = .{ .x = 0, .y = 0, .w = 2, .h = 2 },
    }));
}

test "api-w13 invalid colors, gradient stops and geometry fail before publication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var list = paint.PaintList.init(arena.allocator(), &.{}, 3);
    try std.testing.expectError(error.PaletteOutOfRange, list.addRect(.{
        .bounds = .{ .x = 0, .y = 0, .w = 4, .h = 4 },
        .fill = .{ .solid = .{ .palette = 0 } },
    }));
    try std.testing.expectError(error.InvalidPaint, list.addRect(.{
        .bounds = .{ .x = 0, .y = 0, .w = 4, .h = 4 },
        .fill = .{ .gradient = .{
            .first = .{ .color = .{ .srgb = .{ .r = 1, .g = 0, .b = 0 } }, .position = 0.8 },
            .second = .{ .color = .{ .srgb = .{ .r = 0, .g = 0, .b = 1 } }, .position = 0.2 },
        } },
    }));
    try std.testing.expectError(error.InvalidPaint, list.addRect(.{
        .bounds = .{ .x = 0, .y = 0, .w = -4, .h = 4 },
    }));
    try expectEqual(@as(usize, 0), list.records.items.len);
}
