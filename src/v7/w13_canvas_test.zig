const std = @import("std");
const element = @import("element.zig");
const path = @import("path.zig");
const painting = @import("paint.zig");
const drawcmd = @import("drawcmd.zig");
const widget = @import("widget.zig");
const input_mod = @import("input.zig");
const DrawCtx = @import("drawctx.zig").DrawCtx;

const green: painting.Color = .{ .srgb = .{ .r = 0, .g = 1, .b = 0 } };
const blue: painting.Color = .{ .srgb = .{ .r = 0, .g = 0, .b = 1 } };

const CanvasElement = struct {
    commands: []path.Command,
    dashes: []f32,
    shadows: []painting.Shadow,

    pub const PhaseState = struct {
        final_content: widget.Rect = .{},
        prepaint_done: bool = false,
    };

    pub fn measure(_: *const CanvasElement, input: element.MeasureInput) element.Error!widget.Size {
        return .{
            .width = input.known_dimensions.width orelse 48,
            .height = input.known_dimensions.height orelse 32,
        };
    }

    pub fn prepaint(_: *const CanvasElement, state: *PhaseState, geometry: element.Geometry) element.Error!void {
        state.final_content = geometry.content;
        state.prepaint_done = true;
    }

    pub fn paint(
        self: *const CanvasElement,
        state: *PhaseState,
        geometry: element.Geometry,
        canvas: *element.PaintWriter,
    ) element.Error!void {
        if (!state.prepaint_done or !std.meta.eql(state.final_content, geometry.content)) return error.PhaseReentry;
        try canvas.addRect(.{
            .bounds = .{ .x = -6, .y = 2, .w = geometry.content.w, .h = 12 },
            .fill = .{ .gradient = .{
                .first = .{ .color = green, .position = 0.1 },
                .second = .{ .color = blue, .position = 0.9 },
                .angle = 0.25,
            } },
            .radii = .{ 1, 2, 3, 4 },
            .shadows = self.shadows,
            .opacity = 0.8,
            .transform = .{ .tx = 3 },
            .layer = 2,
        });
        try canvas.addPath(.{
            .bounds = .{ .x = 3, .y = -2, .w = 18, .h = 10 },
            .path = .{ .commands = self.commands },
            .stroke = .{ .color = green, .width = 2, .dash = self.dashes, .phase = 0.5 },
            .fill = .{ .pattern = .{
                .first = green,
                .second = blue,
                .cell = .{ .x = 2, .y = 3 },
            } },
            .fill_rule = .even_odd,
            .layer = 5,
        });
    }
};

test "api-w13 canvas records final prepaint geometry and frame-owned gradient, shadow, path and dash" {
    var builder = path.Builder.init(std.testing.allocator, 16);
    defer builder.deinit();
    try builder.moveTo(.{ .x = 1, .y = 1 });
    try builder.lineTo(.{ .x = 5, .y = 2 });
    try builder.quadraticTo(.{ .x = 9, .y = 3 }, .{ .x = 10, .y = 4 });
    try builder.cubicTo(.{ .x = 11, .y = 5 }, .{ .x = 12, .y = 6 }, .{ .x = 13, .y = 7 });
    try builder.arc(.{ .x = 12, .y = 8 }, .{ .x = 2, .y = 2 }, .{ .start = 0, .sweep = 0.5 });
    try builder.close();
    const authored_commands = try std.testing.allocator.dupe(path.Command, builder.path().commands);
    defer std.testing.allocator.free(authored_commands);
    var dash = [_]f32{ 2, 3 };
    var shadows = [_]painting.Shadow{.{ .color = blue, .offset = .{ .x = 1, .y = 2 }, .blur = 3 }};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = widget.WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
    const parent = try ctx.elementContainer(CanvasElement, .{
        .commands = builder.commands.items,
        .dashes = &dash,
        .shadows = &shadows,
    }, .{
        .position = .absolute,
        .width = 48,
        .height = 32,
        // The border box is 48x32, so the prepaint content box is the 40x26
        // the hooks below are asserted against.
        .box_sizing = .border_box,
        .padding = .{ .top = 2, .right = 3, .bottom = 4, .left = 5 },
        .fill = [4]f32{ 0.2, 0.3, 0.4, 1 },
        .layer = 4,
        .opacity = 0.5,
        .clip = true,
    });
    const child = try ctx.button(.{ .key = .{ .static = "canvas-child" }, .label = "child", .width = 10, .height = 8 });
    ctx.pop();
    try element.prepareFrame(&ctx, .{
        .allocator = arena.allocator(),
        .available = .{ .width = 100, .height = 80 },
    });
    const content = widget.visualContentRect(&tree, parent);
    try std.testing.expectEqual(widget.Rect{
        .x = 5,
        .y = 2,
        .w = 40,
        .h = 26,
    }, content);
    const frame = tree.nodeConst(parent).?.kind.element;
    try std.testing.expectEqual(content, frame.phaseState(CanvasElement.PhaseState).final_content);
    try std.testing.expectEqual(@as(usize, 2), frame.paint_records.items.len);

    builder.commands.items[0] = .{ .move = .{ .x = 777, .y = 888 } };
    dash[0] = 99;
    shadows[0].blur = 99;
    const cmds = try drawcmd.collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);
    try std.testing.expectEqual(@as(usize, 4), cmds.len);
    try std.testing.expectEqual(@as(u32, 0), cmds[0].rect_paint.order.?);
    try std.testing.expectEqual(@as(u32, 1), cmds[1].rect_paint.order.?);
    try std.testing.expectEqual(@as(u32, 2), cmds[2].path_paint.?.order.?);
    try std.testing.expectEqual(@as(u32, 3), cmds[3].rect_paint.order.?);
    try std.testing.expectEqual(@as(u32, 6), cmds[1].rect_paint.layer);
    try std.testing.expectEqual(@as(u32, 9), cmds[2].path_paint.?.layer);
    try std.testing.expectEqual(painting.Rect{ .x = -1, .y = 4, .w = 40, .h = 12 }, cmds[1].rect_paint.bounds);
    try std.testing.expectEqual(painting.Rect{ .x = 8, .y = 0, .w = 18, .h = 10 }, cmds[2].path_paint.?.bounds);
    try std.testing.expectEqual(@as(f32, 0.4), cmds[1].rect_paint.opacity);
    try std.testing.expectEqual(@as(f32, 3), cmds[1].rect_paint.transform.tx);
    // The translated paint record does not move the child's layout or hit box.
    try std.testing.expectEqual(child, input_mod.hitActionable(&tree, .{ 6, 3 }).?);
    try std.testing.expect(input_mod.hitTest(&tree, .{ 50, 4 }) == null);
    try std.testing.expectEqual(@as(f32, 3), cmds[1].rect_paint.shadows[0].blur);
    try std.testing.expectEqual(@as(f32, 2), cmds[2].path_paint.?.stroke.?.dash[0]);
    try std.testing.expectEqualSlices(path.Command, authored_commands, cmds[2].path_paint.?.path.commands);
    try std.testing.expectEqual(painting.FillRule.even_odd, cmds[2].path_paint.?.fill_rule);
    try std.testing.expectEqual(@as(f32, 0.25), cmds[1].rect_paint.fill.?.gradient.angle);
    try std.testing.expectEqual(@as(f32, 2), cmds[2].path_paint.?.fill.?.pattern.cell.x);

    const clip_id = cmds[1].rect_paint.clip_id;
    try std.testing.expectEqual(clip_id, cmds[2].path_paint.?.clip_id);
    try std.testing.expect(clip_id != 0xFFFFFFFF);
    const clip = tree.clip_rects[clip_id];
    try std.testing.expectEqual(content.x, clip.x);
    try std.testing.expectEqual(content.y, clip.y);
    try std.testing.expectEqual(content.w, clip.w);
    try std.testing.expectEqual(content.h, clip.h);
    try std.testing.expect(cmds[1].rect_paint.bounds.x < clip.x); // clip, do not reshape gradient.
    try std.testing.expect(cmds[2].path_paint.?.bounds.y < clip.y); // clip, do not shift path.
    try std.testing.expectEqual(@as(f32, 1), cmds[2].path_paint.?.path.commands[0].move.x);

    var list = painting.PaintList.init(arena.allocator(), &.{}, cmds.len);
    for (cmds) |cmd| {
        if (cmd.path_paint) |spec| {
            try list.addPath(spec);
        } else {
            try list.addRect(cmd.rect_paint);
        }
    }
    try std.testing.expectEqual(@as(usize, 4), list.records.items.len);
    try std.testing.expectEqual(@as(f32, 1), list.records.items[2].shape.path.path.commands[0].move.x);
    try std.testing.expectEqual(@as(f32, 2), list.records.items[2].shape.path.stroke.?.dash[0]);
}

test "api-w13 canvas rejects invalid geometry, path commands, stroke and bounded output before appending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var records: std.ArrayList(element.PaintRecord) = .empty;
    var canvas: element.PaintWriter = .{ .allocator = arena.allocator(), .records = &records };
    const one = [_]path.Command{.{ .move = .{ .x = 0, .y = 0 } }};
    try std.testing.expectError(error.InvalidPaint, canvas.addRect(.{
        .bounds = .{ .x = std.math.floatMax(f32), .y = 0, .w = std.math.floatMax(f32), .h = 1 },
        .fill = .{ .solid = green },
    }));
    try std.testing.expectError(error.InvalidPaint, canvas.addPath(.{
        .bounds = .{ .x = 0, .y = 0, .w = -1, .h = 1 },
        .path = .{ .commands = &one },
    }));
    const invalid = [_]path.Command{.{ .line = .{ .x = 1, .y = 1 } }};
    try std.testing.expectError(error.InvalidPath, canvas.addPath(.{
        .bounds = .{ .x = 0, .y = 0, .w = 2, .h = 2 },
        .path = .{ .commands = &invalid },
    }));
    try std.testing.expectError(error.InvalidPaint, canvas.addPath(.{
        .bounds = .{ .x = 0, .y = 0, .w = 2, .h = 2 },
        .path = .{ .commands = &one },
        .stroke = .{ .color = green, .width = 1, .dash = &.{ 1, 0 } },
    }));
    try std.testing.expectEqual(@as(usize, 0), records.items.len);
    const oversized = try arena.allocator().alloc(path.Command, element.PaintWriter.max_path_commands + 1);
    @memset(oversized, .{ .close = {} });
    try std.testing.expectError(error.PathCapacity, canvas.addPath(.{
        .bounds = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .path = .{ .commands = oversized },
    }));
    try std.testing.expectEqual(@as(usize, 0), records.items.len);
    for (0..element.PaintWriter.max_records) |_| try canvas.rect(.{ .w = 1, .h = 1 }, .{ 1, 1, 1, 1 });
    try std.testing.expectError(error.PaintCapacityExceeded, canvas.addPath(.{
        .bounds = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .path = .{ .commands = &one },
    }));
    try std.testing.expectEqual(@as(usize, element.PaintWriter.max_records), records.items.len);
    try std.testing.expect(records.items[0] == .rect);
    try std.testing.expect(records.items[0].rect.fill.? == .solid);
}
