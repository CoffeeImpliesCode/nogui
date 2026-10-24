const std = @import("std");
const drag_drop = @import("drag_drop.zig");
const widget = @import("widget.zig");
const event = @import("event.zig");
const WidgetId = @import("id.zig").WidgetId;
const FrameNodeId = @import("id.zig").FrameNodeId;

const source: WidgetId = .{ .owner = 4, .slot = 1, .generation = 1 };
const destination: WidgetId = .{ .owner = 4, .slot = 2, .generation = 1 };
const pointer: event.PointerId = .{ .mouse = .left };
const Value = struct {
    quantity: u32,
    drops: *u32,
    pub fn deinit(self: *Value) void {
        self.drops.* += 1;
        self.* = undefined;
    }
};
const Trace = struct {
    enters: usize = 0,
    moves: usize = 0,
    leaves: usize = 0,
    checks: usize = 0,
    commits: usize = 0,
    cancels: usize = 0,
    accept: bool = false,
    seen_quantity: u32 = 0,

    fn enter(raw: *anyopaque, _: WidgetId, payload: drag_drop.PayloadView) void {
        const self: *Trace = @ptrCast(@alignCast(raw));
        self.enters += 1;
        self.seen_quantity = payload.get(Value).?.quantity;
        std.debug.assert(payload.get(u32) == null);
    }
    fn move(raw: *anyopaque, _: WidgetId, _: drag_drop.PayloadView) void {
        const self: *Trace = @ptrCast(@alignCast(raw));
        self.moves += 1;
    }
    fn leave(raw: *anyopaque, _: WidgetId, _: drag_drop.PayloadView) void {
        const self: *Trace = @ptrCast(@alignCast(raw));
        self.leaves += 1;
    }
    fn canDrop(raw: *anyopaque, _: WidgetId, _: drag_drop.PayloadView) bool {
        const self: *Trace = @ptrCast(@alignCast(raw));
        self.checks += 1;
        return self.accept;
    }
    fn dropped(raw: *anyopaque, _: WidgetId, _: drag_drop.PayloadView) void {
        const self: *Trace = @ptrCast(@alignCast(raw));
        self.commits += 1;
    }
    fn cancelled(raw: *anyopaque, _: WidgetId, _: drag_drop.PayloadView) void {
        const self: *Trace = @ptrCast(@alignCast(raw));
        self.cancels += 1;
    }
    fn handler(self: *Trace) drag_drop.Handler {
        return .{
            .user = self,
            .enter = enter,
            .move = move,
            .leave = leave,
            .can_drop = canDrop,
            .drop = dropped,
            .cancel = cancelled,
        };
    }
};
fn makeTree(gpa: std.mem.Allocator) !widget.WidgetTree {
    var tree = widget.WidgetTree.init(gpa);
    errdefer tree.deinit();
    try tree.nodes.append(gpa, .{
        .id = @as(FrameNodeId, @fromBackingInt(@intCast(1))),
        .widget_id = source,
        .kind = .{ .button = .{ .label = "Source" } },
        .parent = .root,
        .rect = .{ .w = 40, .h = 30 },
    });
    try tree.nodes.append(gpa, .{
        .id = @as(FrameNodeId, @fromBackingInt(@intCast(2))),
        .widget_id = destination,
        .kind = .{ .button = .{ .label = "Destination" } },
        .parent = .root,
        .rect = .{ .x = 45, .w = 40, .h = 30 },
    });
    return tree;
}

// A preview cannot activate before threshold, and payloads must outlive frame arenas.
test "api-w16 typed drag starts at threshold and survives replacement frame" {
    var tree = try makeTree(std.testing.allocator);
    defer tree.deinit();
    var drag: drag_drop.Manager = .{};
    var trace: Trace = .{ .accept = true };
    var drops: u32 = 0;
    try drag.begin(Value, std.testing.allocator, source, pointer, .{ 1, 1 }, 5, .{ .quantity = 18, .drops = &drops });
    defer drag.deinit();
    drag.pointerMove(&tree, pointer, .{ 4, 4 }, destination, trace.handler());
    try std.testing.expectEqual(@as(usize, 0), trace.enters);
    drag.pointerMove(&tree, pointer, .{ 5, 4 }, destination, trace.handler());
    try std.testing.expectEqual(@as(usize, 1), trace.enters);
    try std.testing.expectEqual(@as(u32, 18), trace.seen_quantity);
    var rebuilt = try makeTree(std.testing.allocator);
    defer rebuilt.deinit();
    drag.reconcile(&rebuilt, trace.handler());
    drag.pointerMove(&rebuilt, pointer, .{ 52, 10 }, destination, trace.handler());
    try std.testing.expectEqual(@as(usize, 1), trace.moves);
    try std.testing.expect(drag.pointerRelease(&rebuilt, pointer, destination, trace.handler()));
    try std.testing.expectEqual(@as(usize, 1), trace.commits);
    try std.testing.expectEqual(@as(u32, 1), drops);
    try std.testing.expect(!drag.pointerRelease(&rebuilt, pointer, destination, trace.handler()));
    try std.testing.expectEqual(@as(u32, 1), drops);
}

// A rejected candidate, a release outside, and explicit cancellation cannot commit.
test "api-w16 rejected and cancelled drops release payload exactly once" {
    var tree = try makeTree(std.testing.allocator);
    defer tree.deinit();
    var drag: drag_drop.Manager = .{};
    defer drag.deinit();
    var trace: Trace = .{};
    var releases: u32 = 0;
    try drag.begin(Value, std.testing.allocator, source, pointer, .{ 0, 0 }, 2, .{ .quantity = 1, .drops = &releases });
    drag.pointerMove(&tree, pointer, .{ 2, 0 }, destination, trace.handler());
    try std.testing.expect(!drag.pointerRelease(&tree, pointer, destination, trace.handler()));
    try std.testing.expectEqual(@as(usize, 1), trace.cancels);
    try std.testing.expectEqual(@as(usize, 0), trace.commits);
    try std.testing.expectEqual(@as(u32, 1), releases);

    trace.accept = true;
    try drag.begin(Value, std.testing.allocator, source, pointer, .{ 0, 0 }, 2, .{ .quantity = 2, .drops = &releases });
    drag.pointerMove(&tree, pointer, .{ 2, 0 }, destination, trace.handler());
    try std.testing.expect(!drag.pointerRelease(&tree, pointer, null, trace.handler()));
    try std.testing.expectEqual(@as(usize, 0), trace.commits);
    try std.testing.expectEqual(@as(u32, 2), releases);

    try drag.begin(Value, std.testing.allocator, source, pointer, .{ 0, 0 }, 2, .{ .quantity = 3, .drops = &releases });
    drag.pointerMove(&tree, pointer, .{ 2, 0 }, destination, trace.handler());
    drag.cancel(pointer, trace.handler());
    drag.cancel(pointer, trace.handler());
    try std.testing.expect(!drag.pointerRelease(&tree, pointer, destination, trace.handler()));
    try std.testing.expectEqual(@as(usize, 0), trace.commits);
    try std.testing.expectEqual(@as(u32, 3), releases);
}

// If the source disappears after drag start, no later release can commit.
test "api-w16 disappearing drag source cancels and invalidates drop" {
    var tree = try makeTree(std.testing.allocator);
    defer tree.deinit();
    var drag: drag_drop.Manager = .{};
    defer drag.deinit();
    var trace: Trace = .{ .accept = true };
    var releases: u32 = 0;
    try drag.begin(Value, std.testing.allocator, source, pointer, .{ 0, 0 }, 1, .{ .quantity = 2, .drops = &releases });
    drag.pointerMove(&tree, pointer, .{ 4, 0 }, destination, trace.handler());
    var gone = tree.nodes.orderedRemove(0);
    gone.children.deinit(std.testing.allocator);
    drag.reconcile(&tree, trace.handler());
    try std.testing.expect(!drag.pointerRelease(&tree, pointer, destination, trace.handler()));
    try std.testing.expectEqual(@as(usize, 1), trace.cancels);
    try std.testing.expectEqual(@as(usize, 0), trace.commits);
    try std.testing.expectEqual(@as(u32, 1), releases);
}

// A cancelled drag releases its payload EXACTLY ONCE, and the manager is
// already empty before any handler runs. That is what makes a handler free to
// cancel, release or begin again from inside its own callback without
// double-freeing the payload it was handed a view of.
const Reentrant = struct {
    drag: *drag_drop.Manager,
    tree: *const widget.WidgetTree,
    /// Re-entrant calls made from inside the cancel callback.
    nested_cancels: usize = 0,
    views_alive: bool = false,

    fn cancel(raw: *anyopaque, _: WidgetId, payload: drag_drop.PayloadView) void {
        const self: *Reentrant = @ptrCast(@alignCast(raw));
        // The view is still valid for the whole callback, and it is the real
        // payload: the manager has not released it yet.
        self.views_alive = payload.get(Value) != null;
        self.nested_cancels += 1;
        // Re-entering both terminal paths from inside the cancellation must
        // find an empty manager and release nothing further.
        self.drag.cancel(pointer, self.handler());
        _ = self.drag.pointerRelease(self.tree, pointer, destination, self.handler());
    }
    fn handler(self: *Reentrant) drag_drop.Handler {
        return .{ .user = self, .cancel = cancel };
    }
};

test "api-w16 a cancelled drag releases its payload exactly once under re-entrancy" {
    const gpa = std.testing.allocator;
    var tree = try makeTree(gpa);
    defer tree.deinit();
    var drag: drag_drop.Manager = .{};
    defer drag.deinit();
    var releases: u32 = 0;
    try drag.begin(Value, gpa, source, pointer, .{ 0, 0 }, 1, .{
        .quantity = 4,
        .drops = &releases,
    });
    var trace: Reentrant = .{ .drag = &drag, .tree = &tree };

    drag.cancel(pointer, trace.handler());

    // The handler ran once, saw a live payload, and its re-entrant cancel and
    // release both found nothing to do.
    try std.testing.expectEqual(@as(usize, 1), trace.nested_cancels);
    try std.testing.expect(trace.views_alive);
    try std.testing.expect(drag.active == null);
    // ONE release for ONE cancellation, not one per nested call.
    try std.testing.expectEqual(@as(u32, 1), releases);

    // A second explicit cancel and a release after the fact are both no-ops:
    // the drag is retired, so the payload cannot be released again.
    drag.cancel(pointer, trace.handler());
    try std.testing.expect(!drag.pointerRelease(&tree, pointer, destination, trace.handler()));
    try std.testing.expectEqual(@as(usize, 1), trace.nested_cancels);
    try std.testing.expectEqual(@as(u32, 1), releases);

    // A fresh drag after the retirement owns its own payload and releases it
    // on its own cancellation, so the two never share a release.
    try drag.begin(Value, gpa, source, pointer, .{ 0, 0 }, 1, .{
        .quantity = 5,
        .drops = &releases,
    });
    drag.cancel(pointer, trace.handler());
    try std.testing.expectEqual(@as(u32, 2), releases);
    try std.testing.expectEqual(@as(usize, 2), trace.nested_cancels);
}
