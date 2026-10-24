const std = @import("std");
const paint = @import("paint.zig");
const style = @import("style.zig");
const drawcmd = @import("drawcmd.zig");
const widget = @import("widget.zig");
const FrameNodeId = @import("id.zig").FrameNodeId;
const DrawCtx = @import("drawctx.zig").DrawCtx;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApprox = std.testing.expectApproxEqAbs;

const blue: paint.Color = .{ .srgb = .{ .r = 0, .g = 0, .b = 1 } };
const themed: paint.Color = .{ .palette = 0 };
const stops: paint.Fill = .{ .gradient = .{
    .first = .{ .color = themed, .position = 0.2 },
    .second = .{ .color = blue, .position = 0.8 },
    .angle = 0.4,
} };

test "rich local fill replaces the component fill, while unrelated borders and shadows remain" {
    const defaults: style.PaintStyle = .{
        .fill = .{ 0.4, 0.2, 0.1, 1 },
        .paint_fill = stops,
        .border_colors = .{ themed, blue, themed, blue },
        .border_styles = .{ .solid, .dashed, .dotted, .solid },
        .shadows = &.{.{ .color = blue, .blur = 4 }},
        .layer = 9,
    };
    const solid = style.PaintStyle.resolve(defaults, .{ .fill = .{ 0, 1, 0, 1 } });
    try expect(solid.paint_fill == null);
    try expectEqual([4]f32{ 0, 1, 0, 1 }, solid.fill);
    try expectEqual(paint.BorderStyle.dashed, solid.border_styles[1]);
    try expectEqual(@as(usize, 1), solid.shadows.len);
    try expectEqual(@as(u32, 9), solid.layer);

    const gradient = style.PaintStyle.resolve(solid, .{
        .paint_fill = .{ .value = stops },
        .border_color = .{ 1, 0, 0, 1 },
        .radii = .{ 3, 5, 7, 11 },
        .opacity = 0.6,
        .transform = .{ .tx = 12 },
    });
    try expectEqual(@as(f32, 0.4), gradient.paint_fill.?.gradient.angle);
    try expect(gradient.border_colors == null);
    try expectEqual(@as(f32, 7), gradient.resolvedRadii()[2]);
    try expectEqual(@as(f32, 0.6), gradient.opacity);
    try expectEqual(@as(f32, 12), gradient.transform.tx);
    const cleared = style.PaintStyle.resolve(gradient, .{
        .paint_fill = .clear,
        .shadows = &.{},
    });
    try expect(cleared.paint_fill == null);
    try expectEqual(@as(usize, 0), cleared.shadows.len);
}

test "DrawCtx options keep typed pattern and theme border instead of dropping them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = widget.WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{
        .tree = &tree,
        .arena = arena.allocator(),
    };
    const id = try ctx.button(.{
        .key = .{ .static = "pattern" },
        .label = "pattern",
        .fill = paint.Fill{ .pattern = .{
            .first = themed,
            .second = blue,
            .cell = .{ .x = 7, .y = 9 },
            .kind = .stripes,
        } },
        .border_color = paint.Color{ .palette = 0 },
        .opacity = 0.4,
    });
    const resolved = tree.node(id).?.paint;
    try expectEqual(@as(f32, 7), resolved.paint_fill.?.pattern.cell.x);
    try expectEqual(paint.PatternKind.stripes, resolved.paint_fill.?.pattern.kind);
    try expectEqual(@as(usize, 0), resolved.border_colors.?[3].palette);
    try expectEqual(@as(f32, 0.4), resolved.opacity);
}

test "collector orders parent and rich child before resolving their paint" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    const child: FrameNodeId = @fromBackingInt(@intCast(1));
    const parent: FrameNodeId = @fromBackingInt(@intCast(2));
    var shadows = [_]paint.Shadow{
        .{ .color = themed, .offset = .{ .x = -2, .y = 3 }, .blur = 5, .spread = 1 },
        .{ .color = blue, .blur = 2, .inset = true },
    };
    try tree.nodes.append(std.testing.allocator, .{
        .id = child,
        .kind = .{ .button = .{ .label = "rich" } },
        .parent = parent,
        .rect = .{ .x = 4, .y = 5, .w = 30, .h = 20 },
        .style = .{ .border_inset = .{
            .top = .{ .length = 1 },
            .right = .{ .length = 2 },
            .bottom = .{ .length = 3 },
            .left = .{ .length = 4 },
        } },
        .paint = .{
            .paint_fill = stops,
            .border_colors = .{ themed, blue, themed, blue },
            .border_styles = .{ .solid, .dashed, .dotted, .none },
            .radii = .{ 2, 3, 4, 5 },
            .shadows = &shadows,
            .opacity = 0.5,
            .transform = .{ .tx = 7, .ty = -3 },
            .layer = 4,
        },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = parent,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 10, .y = 12, .w = 60, .h = 50 },
        .paint = .{ .clip = true },
    });
    try tree.appendChild(parent, child);

    var cmds: std.ArrayList(drawcmd.DrawCmd) = .empty;
    defer cmds.deinit(std.testing.allocator);
    try cmds.ensureTotalCapacity(std.testing.allocator, try drawcmd.requiredCapacity(&tree));
    try drawcmd.collectDrawCmdsInto(&tree, null, 0, &cmds);
    try expectEqual(@as(usize, 2), cmds.items.len);
    try expectEqual(@as(u32, 0), cmds.items[0].rect_paint.order.?);
    try expectEqual(@as(u32, 1), cmds.items[1].rect_paint.order.?);
    try expectEqual(@as(u32, 0xFFFFFFFF), cmds.items[0].rect_paint.clip_id);
    try expectEqual(@as(u32, 0), cmds.items[1].rect_paint.clip_id);
    try expectEqual(paint.Rect{ .x = 14, .y = 17, .w = 30, .h = 20 }, cmds.items[1].rect_paint.bounds);
    try expectEqual(@as(f32, 7), cmds.items[1].rect_paint.transform.tx);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var palette = [_]paint.Srgb{.{ .r = 1, .g = 0, .b = 0 }};
    var list = paint.PaintList.init(arena.allocator(), &palette, cmds.items.len);
    for (cmds.items) |cmd| try list.addRect(cmd.rect_paint);
    shadows[0].blur = 99;
    palette[0] = .{ .r = 0, .g = 1, .b = 0 };
    const rich = list.records.items[1];
    try expectEqual(@as(f32, 5), rich.shape.rect.shadows[0].blur);
    try expectEqual(@as(usize, 2), rich.shape.rect.shadows.len);
    try expectEqual(@as(f32, -2), rich.shape.rect.shadows[0].offset.x);
    try expectEqual(@as(f32, 1), rich.shape.rect.shadows[0].spread);
    try expect(rich.shape.rect.shadows[1].inset);
    try expectApprox(@as(f32, 0.6279554), rich.shape.rect.shadows[0].color.l, 0.001);
    try expectEqual(@as(f32, 0.5), rich.opacity);
    try expectEqual(@as(f32, 0.2), rich.shape.rect.fill.?.gradient.first.position);
    try expectApprox(@as(f32, 0.6279554), rich.shape.rect.fill.?.gradient.first.color.l, 0.001);
    try expectApprox(@as(f32, 0.5), rich.shape.rect.fill.?.gradient.first.color.alpha, 0.001);
    try expectEqual(paint.BorderStyle.dashed, rich.shape.rect.borders[1].style);
    try expectApprox(@as(f32, 0.6279554), rich.shape.rect.borders[0].color.l, 0.001);
    try expectApprox(@as(f32, 0.4520137), rich.shape.rect.borders[1].color.l, 0.001);
    try expectEqual(@as(f32, 2), rich.shape.rect.borders[1].width);
    try expectEqual(@as(f32, 0), rich.shape.rect.borders[3].width);
    try expectEqual(@as(f32, 4), rich.shape.rect.radii[2]);
}

test "pattern and texture fills survive node collection with authored coordinates" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    const pattern: FrameNodeId = @fromBackingInt(@intCast(1));
    const image: FrameNodeId = @fromBackingInt(@intCast(2));
    try tree.nodes.append(std.testing.allocator, .{
        .id = pattern,
        .parent = .root,
        .kind = .{ .label = .{ .text = "painted" } },
        .rect = .{ .x = 3, .y = 4, .w = 22, .h = 17 },
        .paint = .{ .paint_fill = .{ .pattern = .{
            .first = themed,
            .second = blue,
            .cell = .{ .x = 6, .y = 8 },
            .kind = .checker,
        } } },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = image,
        .parent = .root,
        .kind = .{ .button = .{ .label = "image" } },
        .rect = .{ .x = 29, .y = 4, .w = 31, .h = 21 },
        .paint = .{ .texture = 17, .opacity = 0.3 },
    });
    const commands = try drawcmd.collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(commands);
    try expectEqual(@as(usize, 2), commands.len);
    try expectEqual(@as(u32, 17), commands[0].rect_paint.fill.?.image_pattern.texture_index);
    try expectEqual(@as(f32, 31), commands[0].rect_paint.fill.?.image_pattern.tile.x);
    try expectEqual(@as(f32, 21), commands[0].rect_paint.fill.?.image_pattern.tile.y);
    try expectEqual(@as(f32, 6), commands[1].rect_paint.fill.?.pattern.cell.x);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var colors = [_]paint.Srgb{.{ .r = 1, .g = 0, .b = 0 }};
    var list = paint.PaintList.init(arena.allocator(), &colors, 2);
    for (commands) |cmd| try list.addRect(cmd.rect_paint);
    colors[0] = .{ .r = 0, .g = 1, .b = 0 };
    try expectEqual(@as(f32, 0.3), list.records.items[0].opacity);
    try expectEqual(@as(u32, 17), list.records.items[0].shape.rect.fill.?.image_pattern.texture_index);
    try expectEqual(paint.PatternKind.checker, list.records.items[1].shape.rect.fill.?.pattern.kind);
    try expectApprox(@as(f32, 0.6279554), list.records.items[1].shape.rect.fill.?.pattern.first.l, 0.001);
}

test "collector rejects undersized command storage before changing its contents" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.appendNode(.{
        .id = @fromBackingInt(@intCast(1)),
        .parent = .root,
        .kind = .{ .button = .{ .label = "capacity" } },
        .rect = .{ .w = 10, .h = 10 },
    });
    var commands: std.ArrayList(drawcmd.DrawCmd) = .empty;
    defer commands.deinit(std.testing.allocator);
    try std.testing.expectError(error.OutOfMemory, drawcmd.collectDrawCmdsInto(
        &tree,
        null,
        0,
        &commands,
    ));
    try expectEqual(@as(usize, 0), commands.items.len);
}
