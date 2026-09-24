const std = @import("std");
const widget = @import("widget.zig");
const DrawCtx = @import("drawctx.zig").DrawCtx;
const element = @import("element.zig");
const layout = @import("layout/root.zig");
const drawcmd = @import("drawcmd.zig");
const input = @import("input.zig");
const headless = @import("headless.zig");
const ComponentId = @import("key.zig").ComponentId;

const Ruler = struct {
    width: f32 = 120,
    height: f32 = 18,
    revision: u64 = 1,
    pub const PhaseState = struct {
        layout_calls: u8 = 0,
        prepaint_calls: u8 = 0,
        paint_calls: u8 = 0,
        semantic_calls: u8 = 0,
        observed_width: f32 = 0,
    };

    pub fn measure(self: *const Ruler, measure_input: element.MeasureInput) element.Error!widget.Size {
        const width: f32 = switch (measure_input.available_space.width) {
            .min_content => 12,
            .max_content => self.width,
            .definite => self.width,
        };
        return .{
            .width = measure_input.known_dimensions.width orelse width,
            .height = measure_input.known_dimensions.height orelse self.height,
        };
    }

    pub fn layout(_: *const Ruler, state: *PhaseState, geometry: element.Geometry) element.Error!void {
        if (state.layout_calls != 0) return error.PhaseReentry;
        state.layout_calls = 1;
        state.observed_width = geometry.border.w;
    }

    pub fn prepaint(_: *const Ruler, state: *PhaseState, _: element.Geometry) element.Error!void {
        if (state.layout_calls != 1 or state.prepaint_calls != 0) return error.PhaseReentry;
        state.prepaint_calls = 1;
    }

    pub fn paint(
        _: *const Ruler,
        state: *PhaseState,
        geometry: element.Geometry,
        writer: *element.PaintWriter,
    ) element.Error!void {
        if (state.prepaint_calls != 1 or state.paint_calls != 0) return error.PhaseReentry;
        state.paint_calls = 1;
        try writer.rect(.{ .x = 0, .y = 0, .w = geometry.content.w, .h = 1 }, .{ 0.8, 0.3, 0.1, 1 });
        var x: f32 = 0;
        while (x < geometry.content.w) : (x += 10) {
            try writer.rect(.{ .x = x, .y = 1, .w = 1, .h = 5 }, .{ 0.8, 0.3, 0.1, 1 });
        }
    }

    pub fn semantics(_: *const Ruler, state: *PhaseState, _: element.Geometry) element.Error!?element.Semantic {
        if (state.paint_calls != 1 or state.semantic_calls != 0) return error.PhaseReentry;
        state.semantic_calls = 1;
        return .{ .role = .image, .label = "ruler" };
    }
};

fn newContext(arena: std.mem.Allocator, tree: *widget.WidgetTree) DrawCtx {
    return .{ .tree = tree, .arena = arena };
}

fn frame(ctx: *DrawCtx, surface: widget.Size) !void {
    try element.prepareFrame(ctx, .{ .allocator = ctx.arena, .available = surface, .measure = null });
}

// Check built-in block/flex/grid sizing and all three available-space modes.
test "api-w08 custom intrinsic obeys min max and definite size in each layout mode" {
    const WidthCase = enum { min_content, max_content, definite };
    inline for (.{ .block, .flex, .grid }) |display| {
        inline for ([_]WidthCase{ .min_content, .max_content, .definite }) |width| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var tree = widget.WidgetTree.init(arena.allocator());
            defer tree.deinit();
            var ctx = newContext(arena.allocator(), &tree);
            _ = try ctx.column(.{ .display = display, .width = 200 });
            const dimension: widget.Dimension = switch (width) {
                .min_content => .min_content,
                .max_content => .max_content,
                .definite => .{ .length = 55 },
            };
            const id = try ctx.elementLeaf(Ruler, .{}, .{
                .width = dimension,
                .min_width = 40,
                .max_width = 70,
            });
            ctx.pop();
            try frame(&ctx, .{ .width = 200, .height = 120 });
            const leaf = tree.nodeConst(id).?;
            try std.testing.expectEqual(@as(f32, switch (width) {
                .min_content => 40,
                .max_content => 70,
                .definite => 55,
            }), leaf.rect.w);
            try std.testing.expectEqual(@as(f32, 18), leaf.rect.h);
            try std.testing.expectEqual(@as(u8, 1), leaf.kind.element.phaseState(Ruler.PhaseState).layout_calls);
        }
    }
}

// Rebuilding the same stable leaf with a new revision cannot reuse stale size.
test "api-w08 revision changes intrinsic geometry without reusing old payload" {
    var arena_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_a.deinit();
    var arena_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_b.deinit();
    var first = widget.WidgetTree.init(arena_a.allocator());
    defer first.deinit();
    var next = widget.WidgetTree.init(arena_b.allocator());
    defer next.deinit();
    var first_ctx = newContext(arena_a.allocator(), &first);
    var second_ctx = newContext(arena_b.allocator(), &next);
    var storage = layout.LayoutStorage.init(std.testing.allocator);
    defer storage.deinit();
    var payload: Ruler = .{ .width = 30, .revision = 1 };
    const before_id = try first_ctx.elementLeaf(Ruler, payload, .{ .position = .absolute });
    try element.prepareFrame(&first_ctx, .{
        .allocator = arena_a.allocator(),
        .available = .{ .width = 200, .height = 100 },
        .measure = null,
        .storage = &storage,
    });
    payload = .{ .width = 80, .revision = 2 };
    const after_id = try second_ctx.elementLeaf(Ruler, payload, .{ .position = .absolute });
    try element.prepareFrame(&second_ctx, .{
        .allocator = arena_b.allocator(),
        .available = .{ .width = 200, .height = 100 },
        .measure = null,
        .storage = &storage,
    });
    try std.testing.expectEqual(@as(f32, 30), first.nodeConst(before_id).?.rect.w);
    try std.testing.expectEqual(@as(f32, 80), next.nodeConst(after_id).?.rect.w);
    try std.testing.expectEqual(@as(u64, 1), first.nodeConst(before_id).?.kind.element.revision);
    try std.testing.expectEqual(@as(u64, 2), next.nodeConst(after_id).?.kind.element.revision);
    try std.testing.expect(first.nodeConst(before_id).?.kind.element.payload !=
        next.nodeConst(after_id).?.kind.element.payload);
}

// Hooks run before publication, and old arena records survive the next frame.
test "api-w08 phase records and semantic state survive two live frame arenas" {
    var arena_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_a.deinit();
    var arena_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_b.deinit();
    var first = widget.WidgetTree.init(arena_a.allocator());
    defer first.deinit();
    var second = widget.WidgetTree.init(arena_b.allocator());
    defer second.deinit();
    var ctx_a = newContext(arena_a.allocator(), &first);
    var ctx_b = newContext(arena_b.allocator(), &second);
    const id_a = try ctx_a.elementLeaf(Ruler, .{ .width = 42 }, .{ .position = .absolute });
    try frame(&ctx_a, .{ .width = 180, .height = 60 });
    const id_b = try ctx_b.elementLeaf(Ruler, .{ .width = 73 }, .{ .position = .absolute });
    try frame(&ctx_b, .{ .width = 180, .height = 60 });
    const prev = first.nodeConst(id_a).?.kind.element;
    const current = second.nodeConst(id_b).?.kind.element;
    try std.testing.expectEqual(@as(f32, 42), prev.phaseState(Ruler.PhaseState).observed_width);
    try std.testing.expectEqual(@as(f32, 73), current.phaseState(Ruler.PhaseState).observed_width);
    try std.testing.expectEqual(@as(u8, 1), prev.phaseState(Ruler.PhaseState).semantic_calls);
    try std.testing.expectEqual(@as(usize, 6), prev.paint_records.items.len);
    try std.testing.expectEqual(@as(usize, 9), current.paint_records.items.len);
    try std.testing.expectEqualStrings("ruler", prev.semantic.?.label);
}

const LayoutReentry = struct {
    ctx: *DrawCtx,
    pub fn measure(self: *const LayoutReentry, _: element.MeasureInput) element.Error!widget.Size {
        _ = self.ctx.label(.{ .text = "illegal" }) catch |err| switch (err) {
            error.PhaseReentry => return error.PhaseReentry,
            else => return error.InvalidStyle,
        };
        return .{ .width = 10, .height = 10 };
    }
};

// A measure callback cannot resume tree construction or recursively lay out.
test "api-w08 illegal measure phase reentry rejects tree mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = widget.WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx = newContext(arena.allocator(), &tree);
    _ = try ctx.elementLeaf(LayoutReentry, .{ .ctx = &ctx }, .{ .position = .absolute });
    try std.testing.expectError(error.PhaseReentry, frame(&ctx, .{ .width = 90, .height = 40 }));
    try std.testing.expectEqual(@as(usize, 1), tree.nodes.items.len);
}

const QueryContainer = struct {
    pub fn measure(_: *const QueryContainer, _: element.MeasureInput) element.Error!widget.Size {
        return .{ .width = 100, .height = 20 };
    }
    pub fn buildLate(_: *const QueryContainer, size: widget.Size, ctx: *DrawCtx) anyerror!void {
        const visible = size.width >= 80;
        _ = try ctx.row(.{ .height = 25 });
        _ = try ctx.label(.{ .text = if (visible) "wide" else "narrow" });
        ctx.pop();
    }
};

// A size query may append built-ins only inside its declared late subroot.
test "api-w08 late query composes built-ins and finalizes postorder once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = widget.WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx = newContext(arena.allocator(), &tree);
    _ = try ctx.column(.{});
    const container = try ctx.elementContainer(QueryContainer, .{}, .{ .late_scope = .query, .height = 40 });
    ctx.pop();
    _ = try ctx.label(.{ .text = "sibling" });
    ctx.pop();
    try frame(&ctx, .{ .width = 120, .height = 100 });
    const parent = tree.nodeConst(container).?;
    try std.testing.expectEqual(@as(usize, 1), parent.children.items.len);
    const row = tree.nodeConst(parent.children.items[0]).?;
    try std.testing.expectEqual(@as(usize, 1), row.children.items.len);
    try std.testing.expectEqualStrings("wide", tree.nodeConst(row.children.items[0]).?.kind.label.text);
    try std.testing.expect(tree.nodeIndex(row.children.items[0]).? < tree.nodeIndex(row.id).?);
    try std.testing.expect(tree.nodeIndex(row.id).? < tree.nodeIndex(container).?);
}

// Hidden preserves flow/scroll geometry but blocks input, draw and semantics.
test "api-w08 hidden ancestry suppresses hit paint and semantics but keeps extent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = widget.WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx = newContext(arena.allocator(), &tree);
    const scroll = try arena.allocator().create(widget.ScrollState);
    scroll.* = .{};
    _ = try ctx.column(.{ .height = 30, .scroll_state = scroll });
    const hidden = try ctx.column(.{ .visibility = .hidden });
    _ = try ctx.elementLeaf(Ruler, .{ .width = 70 }, .{ .height = 100 });
    const button = try ctx.button(.{ .key = .{ .static = "hidden" }, .label = "secret" });
    ctx.pop();
    const visible = try ctx.button(.{ .key = .{ .static = "visible" }, .label = "public" });
    ctx.pop();
    try frame(&ctx, .{ .width = 120, .height = 120 });
    try std.testing.expect(tree.nodeConst(hidden).?.rect.h > 0);
    try std.testing.expect(scroll.max_offset[1] > 0);
    try std.testing.expect(!widget.isVisible(&tree, button));
    try std.testing.expect(widget.isVisible(&tree, visible));
    const point = widget.visualBorderRect(&tree, button);
    try std.testing.expect(input.hitActionable(&tree, .{ point.x + 1, point.y + 1 }) != button);
    const cmds = try drawcmd.collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);
    for (cmds) |cmd| {
        try std.testing.expect(cmd.rect.y != point.y or cmd.rect.x != point.x);
    }
    const json = try headless.treeToJson(std.testing.allocator, &tree);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"visibility\":\"hidden\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"semantic_label\":\"ruler\"") == null);
}

// Display none removes border geometry and flow contribution, unlike hidden.
test "api-w08 display none clears descendant geometry and scroll contribution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = widget.WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx = newContext(arena.allocator(), &tree);
    const root = try ctx.column(.{ .height = 30 });
    const none = try ctx.column(.{ .display = .none });
    const leaf = try ctx.elementLeaf(Ruler, .{ .height = 100 }, .{});
    ctx.pop();
    const shown = try ctx.label(.{ .text = "shown" });
    ctx.pop();
    try frame(&ctx, .{ .width = 120, .height = 100 });
    try std.testing.expectEqual(@as(f32, 0), tree.nodeConst(none).?.rect.h);
    try std.testing.expectEqual(@as(f32, 0), tree.nodeConst(leaf).?.rect.h);
    try std.testing.expectEqual(@as(f32, 0), tree.nodeConst(shown).?.rect.y);
    try std.testing.expect(tree.nodeConst(root).?.layout_content_size.height < 100);
    try std.testing.expect(!widget.isVisible(&tree, none));
}

// The command collector cannot invoke fallible hooks after publication.
test "api-w08 command capacity counts custom records and clips to content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = widget.WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx = newContext(arena.allocator(), &tree);
    const id = try ctx.elementLeaf(Ruler, .{ .width = 120 }, .{
        .position = .absolute,
        .padding = .{ .top = 2, .right = 4, .bottom = 2, .left = 4 },
    });
    try frame(&ctx, .{ .width = 160, .height = 60 });
    const content = widget.visualContentRect(&tree, id);
    const count = try drawcmd.requiredCapacity(&tree);
    try std.testing.expect(count > tree.nodes.items.len * 3);
    var cmds: std.ArrayList(drawcmd.DrawCmd) = .empty;
    defer cmds.deinit(std.testing.allocator);
    try cmds.ensureTotalCapacity(std.testing.allocator, 3);
    try std.testing.expectError(error.OutOfMemory, drawcmd.collectDrawCmdsInto(&tree, null, 0, &cmds));
    try cmds.ensureTotalCapacity(std.testing.allocator, count);
    try drawcmd.collectDrawCmdsInto(&tree, null, 0, &cmds);
    try std.testing.expect(cmds.items.len > 3);
    for (cmds.items) |cmd| {
        try std.testing.expect(cmd.rect.x >= content.x);
        try std.testing.expect(cmd.rect.y >= content.y);
        try std.testing.expect(cmd.rect.x + cmd.rect.w <= content.x + content.w);
        try std.testing.expect(cmd.rect.y + cmd.rect.h <= content.y + content.h);
    }
}

const InvalidMeasure = struct {
    pub fn measure(_: *const InvalidMeasure, _: element.MeasureInput) element.Error!widget.Size {
        return .{ .width = std.math.nan(f32), .height = 10 };
    }
};

const TooManyTicks = struct {
    pub const PhaseState = struct {};
    pub fn measure(_: *const TooManyTicks, _: element.MeasureInput) element.Error!widget.Size {
        return .{ .width = 20, .height = 20 };
    }
    pub fn paint(
        _: *const TooManyTicks,
        _: *PhaseState,
        _: element.Geometry,
        writer: *element.PaintWriter,
    ) element.Error!void {
        for (0..(element.PaintWriter.max_records + 1)) |_| {
            try writer.rect(.{ .w = 1, .h = 1 }, .{ 1, 1, 1, 1 });
        }
    }
};

// Invalid intrinsic sizes and unbounded paint output fail before commit.
test "api-w08 invalid measurement and paint overflow fail the staged frame" {
    inline for (.{ InvalidMeasure, TooManyTicks }) |T| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var tree = widget.WidgetTree.init(arena.allocator());
        defer tree.deinit();
        var ctx = newContext(arena.allocator(), &tree);
        _ = try ctx.elementLeaf(T, .{}, .{ .position = .absolute });
        const expected: anyerror = if (T == InvalidMeasure)
            error.InvalidStyle
        else
            error.PaintCapacityExceeded;
        try std.testing.expectError(expected, frame(&ctx, .{ .width = 60, .height = 40 }));
        try std.testing.expectEqual(@as(@TypeOf(ctx.phase), .failed), ctx.phase);
        try std.testing.expectError(error.PhaseReentry, ctx.label(.{ .text = "too late" }));
    }
}

const LateScroll = struct {
    scroll: *widget.ScrollState,
    fail_paint: bool,
    pub const PhaseState = struct {};

    pub fn measure(_: *const LateScroll, _: element.MeasureInput) element.Error!widget.Size {
        return .{ .width = 100, .height = 30 };
    }
    pub fn buildLate(self: *const LateScroll, _: widget.Size, ctx: *DrawCtx) anyerror!void {
        _ = try ctx.column(.{ .height = 20, .scroll_state = self.scroll });
        _ = try ctx.spacer(.{ .size = 100 });
        ctx.pop();
    }
    pub fn paint(
        self: *const LateScroll,
        _: *PhaseState,
        _: element.Geometry,
        _: *element.PaintWriter,
    ) element.Error!void {
        if (self.fail_paint) return error.InvalidStyle;
    }
};

// A late scroll extent written before a failed paint belongs to the failed frame.
test "api-w08 failed late frame restores scroll and previous committed tree" {
    const App = @import("app.zig").App;
    const Session = @import("session.zig").Session;
    const Root = struct {
        const Self = @This();
        scroll: widget.ScrollState = .{},
        late: bool = false,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            if (!self.late) {
                _ = try ctx.label(.{ .text = "committed" });
                return;
            }
            _ = try ctx.elementContainer(LateScroll, .{
                .scroll = &self.scroll,
                .fail_paint = true,
            }, .{ .late_scope = .query, .height = 30 });
            ctx.pop();
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var root: Root = .{};
    try app.mountRoot(Root, &root);
    const surface: widget.Size = .{ .width = 120, .height = 120 };
    const committed = try app.frame(1, surface);
    root.late = true;
    try std.testing.expectError(error.InvalidStyle, app.frame(2, surface));
    try std.testing.expect(app.tree_ptr == committed.tree);
    try std.testing.expectEqual(@as(f32, 0), root.scroll.max_offset[1]);
    try std.testing.expectEqualStrings("committed", committed.tree.nodes.items[0].kind.label.text);
}

const OrderProbe = struct {
    child_phase: *const ?*const PhaseState,
    pub const PhaseState = struct {
        prepaint_done: bool = false,
        paint_done: bool = false,
    };

    pub fn measure(_: *const OrderProbe, _: element.MeasureInput) element.Error!widget.Size {
        return .{ .width = 30, .height = 10 };
    }
    pub fn prepaint(self: *const OrderProbe, phase: *PhaseState, _: element.Geometry) element.Error!void {
        if (self.child_phase.*) |child| {
            if (!child.prepaint_done) return error.PhaseReentry;
        }
        phase.prepaint_done = true;
    }
    pub fn paint(
        self: *const OrderProbe,
        phase: *PhaseState,
        _: element.Geometry,
        _: *element.PaintWriter,
    ) element.Error!void {
        if (self.child_phase.*) |child| {
            if (!child.paint_done) return error.PhaseReentry;
        }
        phase.paint_done = true;
    }
};

// Postorder hooks run children before their custom container parent.
test "api-w08 child prepaint and paint finish before parent hooks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = widget.WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx = newContext(arena.allocator(), &tree);
    const child_slot = try arena.allocator().create(?*const OrderProbe.PhaseState);
    child_slot.* = null;
    const empty_slot = try arena.allocator().create(?*const OrderProbe.PhaseState);
    empty_slot.* = null;
    const parent = try ctx.elementContainer(OrderProbe, .{ .child_phase = child_slot }, .{});
    const child = try ctx.elementLeaf(OrderProbe, .{ .child_phase = empty_slot }, .{});
    child_slot.* = tree.nodeConst(child).?.kind.element.phaseState(OrderProbe.PhaseState);
    ctx.pop();
    try frame(&ctx, .{ .width = 100, .height = 80 });
    try std.testing.expect(tree.nodeConst(parent).?.kind.element.phaseState(OrderProbe.PhaseState).paint_done);
    try std.testing.expect(tree.nodeConst(child).?.kind.element.phaseState(OrderProbe.PhaseState).paint_done);
}

// A hidden ancestor removes focus eligibility without removing its geometry.
test "api-w08 hiding a focused control clears focus while preserving its box" {
    const App = @import("app.zig").App;
    const Session = @import("session.zig").Session;
    const Root = struct {
        const Self = @This();
        hidden: bool = false,
        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{
                .visibility = if (self.hidden) widget.Visibility.hidden else widget.Visibility.visible,
                .height = 40,
            });
            _ = try ctx.button(.{ .key = .{ .static = "focus" }, .label = "Focus" });
            ctx.pop();
        }
    };
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var root: Root = .{};
    try app.mountRoot(Root, &root);
    const surface: widget.Size = .{ .width = 140, .height = 80 };
    _ = try app.frame(1, surface);
    _ = try app.handle(.{ .key_down = .{ .key = .tab, .shift = false } });
    try std.testing.expect(app.focus_manager.current != null);
    root.hidden = true;
    const hidden_frame = try app.frame(2, surface);
    try std.testing.expect(app.focus_manager.current == null);
    for (hidden_frame.tree.nodes.items) |node| {
        if (node.kind != .button) continue;
        try std.testing.expect(node.rect.h > 0);
        try std.testing.expect(node.paint_hidden);
        try std.testing.expect(input.hitActionable(hidden_frame.tree, .{
            widget.visualBorderRect(hidden_frame.tree, node.id).x + 1,
            widget.visualBorderRect(hidden_frame.tree, node.id).y + 1,
        }) == null);
    }
}

const BorrowedSemantic = struct {
    text: []u8,
    pub const PhaseState = struct {};
    pub fn measure(_: *const BorrowedSemantic, _: element.MeasureInput) element.Error!widget.Size {
        return .{ .width = 10, .height = 10 };
    }
    pub fn semantics(
        self: *const BorrowedSemantic,
        _: *PhaseState,
        _: element.Geometry,
    ) element.Error!?element.Semantic {
        return .{ .role = .image, .label = self.text };
    }
};

test "api-w08 semantic snapshot owns its label through caller buffer reuse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = widget.WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx = newContext(arena.allocator(), &tree);
    var label = [_]u8{ 'f', 'i', 'r', 's', 't' };
    const id = try ctx.elementLeaf(BorrowedSemantic, .{ .text = &label }, .{});
    try frame(&ctx, .{ .width = 50, .height = 50 });
    label = .{ 'l', 'a', 't', 'e', 'r' };
    try std.testing.expectEqualStrings(
        "first",
        tree.nodeConst(id).?.kind.element.semantic.?.label,
    );
}

const UnboundedLate = struct {
    pub fn measure(_: *const UnboundedLate, _: element.MeasureInput) element.Error!widget.Size {
        return .{ .width = 100, .height = 20 };
    }
    pub fn buildLate(_: *const UnboundedLate, _: widget.Size, ctx: *DrawCtx) anyerror!void {
        for (0..1025) |_| _ = try ctx.label(.{ .text = "item" });
    }
};

test "api-w08 late subroot rejects unbounded child construction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = widget.WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx = newContext(arena.allocator(), &tree);
    _ = try ctx.elementContainer(UnboundedLate, .{}, .{
        .late_scope = .list,
        .height = 30,
    });
    ctx.pop();
    try std.testing.expectError(error.LateSubrootLimit, frame(&ctx, .{ .width = 100, .height = 100 }));
    try std.testing.expectEqual(@as(@TypeOf(ctx.phase), .failed), ctx.phase);
}

test "api-w08 semantic label overflow and invalid paint geometry fail before publication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = widget.WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx = newContext(arena.allocator(), &tree);
    var label: [element.max_semantic_bytes + 1]u8 = undefined;
    @memset(&label, 'x');
    _ = try ctx.elementLeaf(BorrowedSemantic, .{ .text = &label }, .{});
    try std.testing.expectError(error.SemanticCapacityExceeded, frame(&ctx, .{ .width = 30, .height = 30 }));
    try std.testing.expectEqual(@as(@TypeOf(ctx.phase), .failed), ctx.phase);

    var records: std.ArrayList(element.PaintRecord) = .empty;
    defer records.deinit(std.testing.allocator);
    var writer: element.PaintWriter = .{ .allocator = std.testing.allocator, .records = &records };
    try std.testing.expectError(error.InvalidStyle, writer.rect(.{
        .x = std.math.floatMax(f32),
        .w = std.math.floatMax(f32),
        .h = 1,
    }, .{ 1, 1, 1, 1 }));
    try std.testing.expectEqual(@as(usize, 0), records.items.len);
}

test "api-w08 custom background paints behind its recorded marks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = widget.WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx = newContext(arena.allocator(), &tree);
    const background: [4]f32 = .{ 0.1, 0.2, 0.3, 1 };
    _ = try ctx.elementLeaf(Ruler, .{ .width = 20 }, .{
        .position = .absolute,
        .fill = background,
    });
    try frame(&ctx, .{ .width = 80, .height = 50 });
    const cmds = try drawcmd.collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);
    try std.testing.expectEqual(@as(usize, 4), cmds.len);
    // The ORDER claim, read from the live fill each command carries: the
    // element's authored background first, its first recorded mark second.
    const background_fill = cmds[0].rect_paint.fill.?.solid.srgb;
    try std.testing.expectEqual(background[0], background_fill.r);
    try std.testing.expectEqual(background[1], background_fill.g);
    try std.testing.expectEqual(background[2], background_fill.b);
    try std.testing.expectEqual(background[3], background_fill.a);
    const mark_fill = cmds[1].rect_paint.fill.?.solid.srgb;
    try std.testing.expectEqual(@as(f32, 0.8), mark_fill.r);
    try std.testing.expectEqual(@as(f32, 0.3), mark_fill.g);
    try std.testing.expectEqual(@as(f32, 0.1), mark_fill.b);
    try std.testing.expectEqual(@as(f32, 1), mark_fill.a);
}

test "api-w08 late builder restores nested component owner and state scope" {
    const Child = struct {
        const Self = @This();
        clicks: u32 = 0,
        late_state: u32 = 0,

        const Late = struct {
            output: *u32,

            pub fn measure(_: *const Late, _: element.MeasureInput) element.Error!widget.Size {
                return .{ .width = 100, .height = 30 };
            }

            pub fn buildLate(self: *const Late, _: widget.Size, ctx: *DrawCtx) anyerror!void {
                const state = try ctx.state(u32, "scope", 100);
                state.* += 1;
                self.output.* = state.*;
                _ = try ctx.button(.{
                    .key = .{ .static = "go" },
                    .label = "Go",
                    .width = 40,
                    .height = 20,
                    .on_click = Self.clicked,
                });
            }
        };

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.elementContainer(Late, .{ .output = &self.late_state }, .{
                .late_scope = .query,
                .height = 30,
            });
            ctx.pop();
        }

        pub fn clicked(self: *Self) void {
            self.clicks += 1;
        }
    };
    const Root = struct {
        const Self = @This();
        guard: u64 = 0x123456789abcdef0,
        child: Child = .{},
        root_state: u32 = 0,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            const state = try ctx.state(u32, "scope", 1);
            state.* += 1;
            self.root_state = state.*;
            try ctx.component(Child, .{ .key = .{ .static = "child" } }, &self.child);
        }
    };

    const App = @import("app.zig").App;
    const Session = @import("session.zig").Session;
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var root: Root = .{};
    try app.mountRoot(Root, &root);
    const surface: widget.Size = .{ .width = 140, .height = 80 };
    const first = try app.frame(1, surface);
    try std.testing.expectEqual(@as(u32, 2), root.root_state);
    try std.testing.expectEqual(@as(u32, 101), root.child.late_state);
    const child_scope = ComponentId.child(.root, .{ .static = "child" });
    const button = app.widgetIdForKey(child_scope, .{ .static = "go" }) orelse
        return error.MissingChildButton;
    app.activate(first.tree, button);
    try std.testing.expectEqual(@as(u32, 1), root.child.clicks);
    try std.testing.expectEqual(@as(u64, 0x123456789abcdef0), root.guard);
    _ = try app.frame(2, surface);
    try std.testing.expectEqual(@as(u32, 3), root.root_state);
    try std.testing.expectEqual(@as(u32, 102), root.child.late_state);
}
