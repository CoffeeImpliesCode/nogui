const std = @import("std");
const paint = @import("nogui").paint;
const path = @import("nogui").path;
const renderer = @import("renderer.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const approx = std.testing.expectApproxEqAbs;

test "api-w13 lowering preserves gradient direction independent radii border sides and clip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var list = paint.PaintList.init(arena.allocator(), &.{}, 3);
    try list.addRect(.{
        .bounds = .{ .x = 10, .y = 12, .w = 20, .h = 16 },
        .fill = .{ .gradient = .{
            .first = .{ .color = .{ .srgb = .{ .r = 1, .g = 0, .b = 0 } }, .position = 0.2 },
            .second = .{ .color = .{ .srgb = .{ .r = 0, .g = 0, .b = 1 } }, .position = 0.8 },
            .angle = 0,
        } },
        .borders = .{
            .{ .width = 1, .style = .solid },  .{ .width = 2, .style = .dashed },
            .{ .width = 3, .style = .dotted }, .{ .width = 4, .style = .solid },
        },
        .radii = .{ 1, 2, 3, 4 },
        .clip_id = 5,
        .transform = .{ .tx = 3, .ty = 4 },
    });
    var rects: [3]renderer.SceneRect = undefined;
    var curves: [4]path.Quadratic = undefined;
    var mats: [3]renderer.PaintMaterial = undefined;
    const prepared = try renderer.lowerPaint(
        &.{},
        list.records.items,
        &rects,
        &curves,
        &mats,
        .{ .first = 10, .end = 13 },
    );
    try expectEqual(@as(usize, 2), prepared.rects.len);
    try expectEqual(@as(usize, 2), prepared.materials.len);
    try expectEqual(@as(u32, 5), prepared.rects[0].clip_id);
    try expectEqual(@as(u32, 10), prepared.rects[0].material_index);
    try expectEqual(@as(u32, 11), prepared.rects[1].material_index);
    try expectEqual(@as(u32, 3), prepared.materials[0].extra.mode[0]);
    try expectEqual(@as(u32, 1), prepared.materials[1].extra.mode[0]);
    try expectEqual(@as(f32, 4), prepared.materials[1].extra.border_width[3]);
    try expectEqual(@as(f32, 1), prepared.materials[1].extra.radii[0]);
    try expectEqual(@as(f32, 4), prepared.materials[1].extra.radii[3]);
    try expectEqual(@as(u32, 2), prepared.materials[1].extra.border_styles[1]);
    try expectEqual(@as(u32, 3), prepared.materials[1].extra.border_styles[2]);
    try approx(@as(f32, 1), prepared.materials[0].extra.gradient[0], 0.0001);
    try approx(@as(f32, 0), prepared.materials[0].extra.gradient[1], 0.0001);
    try expectEqual(@as(f32, 0.2), prepared.materials[0].extra.gradient[2]);
    try expectEqual(@as(f32, 0.8), prepared.materials[0].extra.gradient[3]);
    try expectEqual(@as(f32, 3), prepared.materials[0].extra.transform_x[2]);
    try expectEqual(@as(f32, 4), prepared.materials[0].extra.transform_y[2]);
}

test "api-w13 path fill and dashed stroke create geometry with transformed bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var list = paint.PaintList.init(arena.allocator(), &.{}, 2);
    const commands = [_]path.Command{
        .{ .move = .{ .x = 0, .y = 0 } },
        .{ .line = .{ .x = 8, .y = 0 } },
        .{ .line = .{ .x = 8, .y = 8 } },
        .{ .close = {} },
    };
    try list.addPath(.{
        .bounds = .{ .x = 4, .y = 5, .w = 8, .h = 8 },
        .path = .{ .commands = &commands },
        .fill = .{ .solid = .{ .srgb = .{ .r = 1, .g = 0, .b = 0 } } },
        .fill_rule = .even_odd,
        .stroke = .{
            .color = .{ .srgb = .{ .r = 0, .g = 0, .b = 1 } },
            .width = 1,
            .dash = &.{ 3, 2 },
        },
        .transform = .{ .a = 2, .d = 2, .tx = 10, .ty = 20 },
    });
    var rects: [2]renderer.SceneRect = undefined;
    var curves: [64]path.Quadratic = undefined;
    var mats: [2]renderer.PaintMaterial = undefined;
    const prepared = try renderer.lowerPaint(
        &.{},
        list.records.items,
        &rects,
        &curves,
        &mats,
        .{ .first = 20, .end = 22 },
    );
    try expectEqual(@as(usize, 2), prepared.rects.len);
    try expectEqual(@as(u32, renderer.type_path_fill), prepared.materials[0].material.type);
    try expectEqual(@as(u32, 1), prepared.materials[0].extra.mode[2]);
    try expectEqual(@as(u32, renderer.type_path_stroke), prepared.materials[1].material.type);
    try expect(prepared.curves.len > 5);
    try expectEqual(@as(f32, 17), prepared.rects[0].dst[0]);
    try expect(prepared.rects[0].dst[1] > 27);
    try expectEqual(@as(f32, 18), prepared.curves[0].p0.x);
    try expectEqual(@as(f32, 30), prepared.curves[0].p0.y);
}

test "api-w13 material and curve exhaustion permit a later complete scene" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var list = paint.PaintList.init(arena.allocator(), &.{}, 2);
    const commands = [_]path.Command{
        .{ .move = .{ .x = 0, .y = 0 } },
        .{ .line = .{ .x = 10, .y = 0 } },
        .{ .line = .{ .x = 10, .y = 10 } },
    };
    try list.addPath(.{
        .bounds = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .path = .{ .commands = &commands },
        .fill = .{ .solid = .{ .srgb = .{ .r = 1, .g = 0, .b = 0 } } },
        .stroke = .{ .color = .{ .srgb = .{ .r = 1, .g = 1, .b = 1 } }, .width = 2 },
    });
    var rects: [2]renderer.SceneRect = undefined;
    var curves: [8]path.Quadratic = undefined;
    var mats: [2]renderer.PaintMaterial = undefined;
    try std.testing.expectError(error.MaterialCapacity, renderer.lowerPaint(
        &.{},
        list.records.items,
        &rects,
        &curves,
        &mats,
        .{ .first = 9, .end = 10 },
    ));
    try std.testing.expectError(error.TessellationCapacity, renderer.lowerPaint(
        &.{},
        list.records.items,
        &rects,
        curves[0..1],
        &mats,
        .{ .first = 9, .end = 11 },
    ));
    const later = try renderer.lowerPaint(
        &.{},
        list.records.items,
        &rects,
        &curves,
        &mats,
        .{ .first = 9, .end = 11 },
    );
    try expectEqual(@as(usize, 2), later.rects.len);
    try expectEqual(@as(u32, 9), later.rects[0].material_index);
    try std.testing.expectError(error.MaterialOverlap, renderer.lowerPaint(
        later.rects[0..1],
        list.records.items,
        &rects,
        &curves,
        &mats,
        .{ .first = 9, .end = 11 },
    ));
}

test "api-w13 inset and outset shadows keep separate geometry and primitive opacity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var list = paint.PaintList.init(arena.allocator(), &.{}, 1);
    try list.addRect(.{
        .bounds = .{ .x = 20, .y = 30, .w = 12, .h = 8 },
        .fill = .{ .solid = .{ .srgb = .{ .r = 1, .g = 1, .b = 1 } } },
        .opacity = 0.5,
        .shadows = &.{
            .{
                .color = .{ .srgb = .{ .r = 0, .g = 0, .b = 0, .a = 0.8 } },
                .offset = .{ .x = 2, .y = -1 },
                .blur = 3,
                .spread = 1,
            },
            .{
                .color = .{ .srgb = .{ .r = 0, .g = 0, .b = 0, .a = 0.6 } },
                .offset = .{ .x = -1, .y = 2 },
                .blur = 2,
                .spread = 1,
                .inset = true,
            },
        },
    });
    var rects: [3]renderer.SceneRect = undefined;
    var curves: [0]path.Quadratic = .{};
    var mats: [3]renderer.PaintMaterial = undefined;
    const lowered = try renderer.lowerPaint(
        &.{},
        list.records.items,
        &rects,
        &curves,
        &mats,
        .{ .first = 50, .end = 53 },
    );
    try expectEqual(@as(usize, 3), lowered.rects.len);
    try expectEqual(@as(f32, 18), lowered.rects[0].dst[0]);
    try expectEqual(@as(f32, 25), lowered.rects[0].dst[1]);
    try expectEqual(@as(f32, 20), lowered.rects[0].dst[2]);
    try expectEqual(@as(f32, 16), lowered.rects[0].dst[3]);
    try expectEqual(@as(u32, 0), lowered.materials[0].extra.mode[2]);
    try expectEqual(@as(f32, 0.4), lowered.rects[0].color[3]);
    try expectEqual(@as(f32, 0.5), lowered.rects[1].color[3]);
    try expectEqual(@as(f32, 20), lowered.rects[2].dst[0]);
    try expectEqual(@as(f32, 30), lowered.rects[2].dst[1]);
    try expectEqual(@as(u32, 1), lowered.materials[2].extra.mode[2]);
    try approx(@as(f32, 0.3), lowered.rects[2].color[3], 0.0001);
}

test "api-w13 transformed path gradient samples original local axis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var list = paint.PaintList.init(arena.allocator(), &.{}, 1);
    const commands = [_]path.Command{
        .{ .move = .{ .x = 0, .y = 0 } },
        .{ .line = .{ .x = 4, .y = 0 } },
        .{ .line = .{ .x = 4, .y = 4 } },
        .{ .close = {} },
    };
    try list.addPath(.{
        .bounds = .{ .x = 0, .y = 0, .w = 4, .h = 4 },
        .path = .{ .commands = &commands },
        .fill = .{ .gradient = .{
            .first = .{ .color = .{ .srgb = .{ .r = 1, .g = 0, .b = 0 } }, .position = 0 },
            .second = .{ .color = .{ .srgb = .{ .r = 0, .g = 0, .b = 1 } }, .position = 1 },
            .angle = 0,
        } },
        .transform = .{ .a = 0, .b = 1, .c = -1, .d = 0, .tx = 12, .ty = 2 },
    });
    var rects: [1]renderer.SceneRect = undefined;
    var curves: [3]path.Quadratic = undefined;
    var mats: [1]renderer.PaintMaterial = undefined;
    const scene = try renderer.lowerPaint(
        &.{},
        list.records.items,
        &rects,
        &curves,
        &mats,
        .{ .first = 7, .end = 8 },
    );
    const inverse = scene.materials[0].extra;
    const first_x = inverse.transform_x[0] * 12 + inverse.transform_x[1] * 2 +
        inverse.transform_x[2];
    const last_x = inverse.transform_x[0] * 12 + inverse.transform_x[1] * 6 +
        inverse.transform_x[2];
    try approx(@as(f32, 0), first_x, 0.0001);
    try approx(@as(f32, 4), last_x, 0.0001);
    try expectEqual(@as(f32, 4), inverse.size[0]);
    try expectEqual(@as(f32, 8), scene.rects[0].dst[0] + 1);
}

test "api-w13 repeating checker and stripe fills keep separate converted colors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var list = paint.PaintList.init(arena.allocator(), &.{}, 2);
    const red: paint.Color = .{ .srgb = .{ .r = 1, .g = 0, .b = 0, .a = 0.8 } };
    const blue: paint.Color = .{ .srgb = .{ .r = 0, .g = 0, .b = 1, .a = 0.6 } };
    try list.addRect(.{
        .bounds = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .fill = .{ .pattern = .{
            .first = red,
            .second = blue,
            .cell = .{ .x = 2, .y = 3 },
            .kind = .checker,
        } },
        .opacity = 0.5,
    });
    try list.addRect(.{
        .bounds = .{ .x = 8, .y = 0, .w = 8, .h = 8 },
        .fill = .{ .pattern = .{
            .first = red,
            .second = blue,
            .cell = .{ .x = 2, .y = 3 },
            .kind = .stripes,
        } },
    });
    var rects: [2]renderer.SceneRect = undefined;
    var curves: [0]path.Quadratic = .{};
    var mats: [2]renderer.PaintMaterial = undefined;
    const lowered = try renderer.lowerPaint(
        &.{},
        list.records.items,
        &rects,
        &curves,
        &mats,
        .{ .first = 17, .end = 19 },
    );
    try expectEqual(@as(u32, 4), lowered.materials[0].extra.mode[0]);
    try expectEqual(@as(u32, 5), lowered.materials[1].extra.mode[0]);
    try expectEqual(@as(f32, 2), lowered.materials[0].extra.pattern[0]);
    try expectEqual(@as(f32, 3), lowered.materials[0].extra.pattern[1]);
    try approx(@as(f32, 0.4), lowered.materials[0].extra.from[3], 0.0001);
    try approx(@as(f32, 0.3), lowered.materials[0].extra.to[3], 0.0001);
    try expect(lowered.materials[0].extra.from[0] >
        lowered.materials[0].extra.to[0]);
}
