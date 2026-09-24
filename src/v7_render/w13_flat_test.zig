const std = @import("std");
const paint = @import("nogui").paint;
const path = @import("nogui").path;
const renderer = @import("renderer.zig");

test "api-w13 flat fills preserve paint order and clip without exhausting rich materials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var list = paint.PaintList.init(arena.allocator(), &.{}, 514);
    for (0..513) |index| {
        try list.addRect(.{
            .bounds = .{ .x = @floatFromInt(index), .y = 1, .w = 1, .h = 2 },
            .fill = .{ .solid = .{ .srgb = .{ .r = 1, .g = 0, .b = 0, .a = 0.5 } } },
            .opacity = 0.5,
            .clip_id = 2,
            .layer = 3,
            .order = @intCast(index),
        });
    }
    try list.addRect(.{
        .bounds = .{ .x = 513, .y = 1, .w = 1, .h = 2 },
        .fill = .{ .solid = .{ .srgb = .{ .r = 0, .g = 0, .b = 1 } } },
        .radii = .{ 1, 0, 0, 0 },
        .order = 513,
    });
    var rects: [514]renderer.SceneRect = undefined;
    var curves: [0]path.Quadratic = .{};
    var mats: [1]renderer.PaintMaterial = undefined;
    try std.testing.expectError(error.SceneCapacity, renderer.lowerPaint(
        &.{},
        list.records.items,
        rects[0..513],
        &curves,
        &mats,
        .{ .first = 1024, .end = 1025 },
    ));
    const lowered = try renderer.lowerPaint(
        &.{},
        list.records.items,
        &rects,
        &curves,
        &mats,
        .{ .first = 1024, .end = 1025 },
    );
    try std.testing.expectEqual(@as(usize, 514), lowered.rects.len);
    try std.testing.expectEqual(@as(usize, 1), lowered.materials.len);
    try std.testing.expectEqual(@as(u32, 0), lowered.rects[0].material_index);
    try std.testing.expectEqual(@as(u32, 0), lowered.rects[512].material_index);
    try std.testing.expectEqual(@as(u32, 1024), lowered.rects[513].material_index);
    try std.testing.expectEqual(@as(f32, 0.25), lowered.rects[0].color[3]);
    try std.testing.expectEqual(@as(u32, 2), lowered.rects[0].clip_id);
    try std.testing.expectEqual(@as(u32, 3), lowered.rects[512].z);
    try std.testing.expectEqual(@as(u32, 512), lowered.rects[512].order);
}
