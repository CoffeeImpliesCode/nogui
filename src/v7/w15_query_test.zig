const std = @import("std");
const container_query = @import("container_query.zig");
const DrawCtx = @import("drawctx.zig").DrawCtx;
const element = @import("element.zig");
const widget = @import("widget.zig");
const FrameNodeId = @import("id.zig").FrameNodeId;

fn prepare(ctx: *DrawCtx, surface: widget.Size) !void {
    try element.prepareFrame(ctx, .{
        .allocator = ctx.arena,
        .available = surface,
        .measure = null,
    });
}

const Branch = struct {
    threshold: f32,
    narrow: []const u8 = "narrow",
    wide: []const u8 = "wide",
    builds: *usize,
    tall: bool = false,

    pub fn build(self: *const Branch, size: widget.Size, ctx: *DrawCtx) !void {
        self.builds.* += 1;
        _ = try ctx.label(.{
            .text = if (size.width >= self.threshold) self.wide else self.narrow,
            .height = if (self.tall) @as(f32, 900) else 10,
        });
    }
};

fn onlyLabel(tree: *const widget.WidgetTree, id: FrameNodeId) []const u8 {
    const parent = tree.nodeConst(id).?;
    std.debug.assert(parent.children.items.len == 1);
    return tree.nodeConst(parent.children.items[0]).?.kind.label.text;
}

test "api-w15 query branches at measured width boundary and builds once" {
    inline for (.{
        .{ .width = 99, .label = "narrow" },
        .{ .width = 100, .label = "wide" },
        .{ .width = 101, .label = "wide" },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var tree = widget.WidgetTree.init(arena.allocator());
        defer tree.deinit();
        var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
        var builds: usize = 0;
        const id = try container_query.query(Branch, &ctx, .{
            .threshold = 100,
            .builds = &builds,
        }, .{
            .width = .{ .length = case.width },
            .height = .{ .length = 25 },
            .position = .absolute,
        });
        try prepare(&ctx, .{ .width = 250, .height = 120 });
        try std.testing.expectEqual(@as(usize, 1), builds);
        try std.testing.expectEqual(@as(f32, case.width), tree.nodeConst(id).?.rect.w);
        try std.testing.expectEqual(@as(f32, 25), tree.nodeConst(id).?.rect.h);
        try std.testing.expectEqualStrings(case.label, onlyLabel(&tree, id));
    }
}

test "api-w15 query compares content width after box sizing and padding" {
    inline for (.{
        .{ .border_width = 119, .label = "narrow" },
        .{ .border_width = 120, .label = "wide" },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var tree = widget.WidgetTree.init(arena.allocator());
        defer tree.deinit();
        var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
        var builds: usize = 0;
        const id = try container_query.query(Branch, &ctx, .{
            .threshold = 100,
            .builds = &builds,
        }, .{
            .width = .{ .length = case.border_width },
            .height = .{ .length = 25 },
            .box_sizing = .border_box,
            .position = .absolute,
            .padding_inset = .{
                .top = .{ .length = 0 },
                .right = .{ .length = 10 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 10 },
            },
        });
        try prepare(&ctx, .{ .width = 250, .height = 120 });
        try std.testing.expectEqual(@as(f32, case.border_width), tree.nodeConst(id).?.rect.w);
        try std.testing.expectEqualStrings(case.label, onlyLabel(&tree, id));
        try std.testing.expectEqual(@as(usize, 1), builds);
    }
}

test "api-w15 sibling queries use independent constrained widths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = widget.WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
    var left_builds: usize = 0;
    var right_builds: usize = 0;
    _ = try ctx.row(.{ .width = 200, .height = 45 });
    const left = try container_query.query(Branch, &ctx, .{
        .threshold = 100,
        .builds = &left_builds,
        .narrow = "left-narrow",
        .wide = "left-wide",
    }, .{
        .width = .{ .percent = 0.25 },
        .height = .{ .length = 25 },
    });
    const right = try container_query.query(Branch, &ctx, .{
        .threshold = 100,
        .builds = &right_builds,
        .narrow = "right-narrow",
        .wide = "right-wide",
    }, .{
        .width = .{ .percent = 0.25 },
        .height = .{ .length = 25 },
        .min_width = .{ .length = 120 },
    });
    ctx.pop();
    try prepare(&ctx, .{ .width = 200, .height = 100 });
    try std.testing.expectEqual(@as(f32, 50), tree.nodeConst(left).?.rect.w);
    try std.testing.expectEqual(@as(f32, 120), tree.nodeConst(right).?.rect.w);
    try std.testing.expectEqualStrings("left-narrow", onlyLabel(&tree, left));
    try std.testing.expectEqualStrings("right-wide", onlyLabel(&tree, right));
    try std.testing.expectEqual(@as(usize, 1), left_builds);
    try std.testing.expectEqual(@as(usize, 1), right_builds);
}

test "api-w15 late children cannot resize their query or auto-sized ancestor" {
    inline for (.{ false, true }) |tall| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var tree = widget.WidgetTree.init(arena.allocator());
        defer tree.deinit();
        var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
        var builds: usize = 0;
        const root = try ctx.column(.{ .width = 200 });
        const id = try container_query.query(Branch, &ctx, .{
            .threshold = 100,
            .builds = &builds,
            .tall = tall,
        }, .{
            .width = .{ .length = 120 },
            .height = .{ .length = 25 },
        });
        const sibling = try ctx.label(.{ .text = "after", .height = 10 });
        ctx.pop();
        try prepare(&ctx, .{ .width = 200, .height = 1000 });
        try std.testing.expectEqual(@as(f32, 25), tree.nodeConst(id).?.rect.h);
        try std.testing.expectEqual(@as(f32, 35), tree.nodeConst(root).?.rect.h);
        try std.testing.expectEqual(@as(f32, 25), tree.nodeConst(sibling).?.rect.y);
        try std.testing.expectEqual(@as(usize, 1), builds);
    }
}

const Nested = struct {
    outer_builds: *usize,
    inner_builds: *usize,

    pub fn build(self: *const Nested, size: widget.Size, ctx: *DrawCtx) !void {
        self.outer_builds.* += 1;
        _ = try ctx.label(.{
            .text = if (size.width >= 200) "outer-wide" else "outer-narrow",
            .height = 10,
        });
        _ = try container_query.query(Branch, ctx, .{
            .threshold = 100,
            .narrow = "inner-narrow",
            .wide = "inner-wide",
            .builds = self.inner_builds,
        }, .{
            .width = .{ .percent = 0.5 },
            .height = .{ .length = 20 },
        });
    }
};

test "api-w15 nested queries build after parent layout at independent widths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = widget.WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
    var wide_outer_builds: usize = 0;
    var narrow_outer_builds: usize = 0;
    var wide_inner_builds: usize = 0;
    var narrow_inner_builds: usize = 0;
    _ = try ctx.column(.{ .width = 400, .height = 140 });
    const wide_outer = try container_query.query(Nested, &ctx, .{
        .outer_builds = &wide_outer_builds,
        .inner_builds = &wide_inner_builds,
    }, .{ .width = .{ .length = 240 }, .height = .{ .length = 50 } });
    const narrow_outer = try container_query.query(Nested, &ctx, .{
        .outer_builds = &narrow_outer_builds,
        .inner_builds = &narrow_inner_builds,
    }, .{ .width = .{ .length = 150 }, .height = .{ .length = 50 } });
    ctx.pop();
    try prepare(&ctx, .{ .width = 400, .height = 200 });
    const wide = tree.nodeConst(wide_outer).?;
    const narrow = tree.nodeConst(narrow_outer).?;
    try std.testing.expectEqualStrings("outer-wide", tree.nodeConst(wide.children.items[0]).?.kind.label.text);
    try std.testing.expectEqualStrings("outer-narrow", tree.nodeConst(narrow.children.items[0]).?.kind.label.text);
    const wide_inner = wide.children.items[1];
    const narrow_inner = narrow.children.items[1];
    try std.testing.expectEqual(@as(f32, 120), tree.nodeConst(wide_inner).?.rect.w);
    try std.testing.expectEqual(@as(f32, 75), tree.nodeConst(narrow_inner).?.rect.w);
    try std.testing.expectEqualStrings("inner-wide", onlyLabel(&tree, wide_inner));
    try std.testing.expectEqualStrings("inner-narrow", onlyLabel(&tree, narrow_inner));
    inline for (.{ &wide_outer_builds, &narrow_outer_builds, &wide_inner_builds, &narrow_inner_builds }) |calls| {
        try std.testing.expectEqual(@as(usize, 1), calls.*);
    }
}

const Reenter = struct {
    pub fn build(_: *const Reenter, _: widget.Size, ctx: *DrawCtx) !void {
        try prepare(ctx, .{ .width = 100, .height = 100 });
    }
};

test "api-w15 recursive phase entry is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = widget.WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
    _ = try container_query.query(Reenter, &ctx, .{}, .{
        .width = .{ .length = 100 },
        .height = .{ .length = 20 },
    });
    try std.testing.expectError(error.PhaseReentry, prepare(&ctx, .{ .width = 100, .height = 100 }));
    try std.testing.expectEqual(@as(@TypeOf(ctx.phase), .failed), ctx.phase);
}

const Recursive = struct {
    pub fn build(_: *const Recursive, _: widget.Size, ctx: *DrawCtx) !void {
        _ = try container_query.query(Recursive, ctx, .{}, .{
            .width = .{ .length = 20 },
            .height = .{ .length = 20 },
        });
    }
};

test "api-w15 recursive nested queries stop at a bounded phase limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = widget.WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
    _ = try container_query.query(Recursive, &ctx, .{}, .{
        .width = .{ .length = 20 },
        .height = .{ .length = 20 },
    });
    try std.testing.expectError(error.LateSubrootLimit, prepare(&ctx, .{
        .width = 100,
        .height = 1600,
    }));
    try std.testing.expectEqual(@as(@TypeOf(ctx.phase), .failed), ctx.phase);
    try std.testing.expect(tree.nodes.items.len <= 65);
}
