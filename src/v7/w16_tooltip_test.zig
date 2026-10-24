const std = @import("std");
const tooltip = @import("tooltip.zig");
const Clock = @import("clock.zig").Clock;
const widget = @import("widget.zig");
const WidgetId = @import("id.zig").WidgetId;
const FrameNodeId = @import("id.zig").FrameNodeId;

const owner: WidgetId = .{ .owner = 8, .slot = 1, .generation = 1 };
const node: FrameNodeId = @fromBackingInt(@intCast(1));
fn now(raw: *anyopaque) i96 {
    const ticks: *i96 = @ptrCast(@alignCast(raw));
    return ticks.*;
}
fn ownerTree(gpa: std.mem.Allocator) !widget.WidgetTree {
    var tree = widget.WidgetTree.init(gpa);
    errdefer tree.deinit();
    try tree.nodes.append(gpa, .{
        .id = node,
        .widget_id = owner,
        .kind = .{ .button = .{ .label = "Help" } },
        .parent = .root,
        .rect = .{ .w = 50, .h = 20 },
    });
    return tree;
}

// Expired W05 task tokens cannot revive a tooltip after leave and reentry.
test "api-w16 tooltip leave and reenter resets delay and rejects stale timer" {
    var ticks: i96 = 100;
    var tree = try ownerTree(std.testing.allocator);
    defer tree.deinit();
    var tip = tooltip.Manager.init(std.testing.allocator, Clock.injected(&ticks, now));
    defer tip.deinit();
    try tip.hover(owner, "A useful hint", 50, true);
    const stale = tip.deadline().?;
    try std.testing.expectEqual(@as(i96, 150), stale.at_ns);
    try std.testing.expectEqualStrings("A useful hint", tip.descriptionFor(owner).?);
    ticks = 120;
    tip.leaveOwner(false);
    try std.testing.expect(tip.deadline() == null);
    try tip.hover(owner, "A useful hint", 50, true);
    const current = tip.deadline().?;
    try std.testing.expect(current.token != stale.token);
    try std.testing.expectEqual(@as(i96, 170), current.at_ns);
    ticks = 150;
    try std.testing.expect(!tip.expire(stale.token, &tree));
    try std.testing.expect(!tip.expire(current.token, &tree));
    ticks = 170;
    try std.testing.expect(tip.expire(current.token, &tree));
    try std.testing.expect(tip.visible());
}

// Hoverable content retains the same tooltip after leaving owner bounds.
test "api-w16 hoverable tooltip survives owner-to-content move and closes outside" {
    var ticks: i96 = 0;
    var tree = try ownerTree(std.testing.allocator);
    defer tree.deinit();
    var tip = tooltip.Manager.init(std.testing.allocator, Clock.injected(&ticks, now));
    defer tip.deinit();
    try tip.hover(owner, "Details", 10, true);
    ticks = 10;
    try std.testing.expect(tip.expire(tip.deadline().?.token, &tree));
    tip.setBounds(.{ .x = 25, .y = 25, .w = 60, .h = 24 });
    tip.pointerMove(null, .{ 30, 28 });
    try std.testing.expect(tip.visible());
    tip.pointerMove(null, .{ 90, 60 });
    try std.testing.expect(!tip.visible());
    try std.testing.expect(tip.deadline() == null);
}

// Hidden or removed owners cannot show content, even if an old timer fires.
test "api-w16 owner removal cancels pending tooltip and semantic description" {
    var ticks: i96 = 10;
    var tree = try ownerTree(std.testing.allocator);
    defer tree.deinit();
    var tip = tooltip.Manager.init(std.testing.allocator, Clock.injected(&ticks, now));
    defer tip.deinit();
    try tip.hover(owner, "Description for keyboard", 20, false);
    const token = tip.deadline().?.token;
    tree.node(node).?.interaction.disabled = true;
    tip.reconcile(&tree);
    ticks = 30;
    try std.testing.expect(!tip.expire(token, &tree));
    try std.testing.expect(!tip.visible());
    try std.testing.expect(tip.descriptionFor(owner) == null);
    tree.node(node).?.interaction.disabled = false;
    try tip.hover(owner, "New", 20, false);
    var gone = tree.nodes.orderedRemove(0);
    gone.children.deinit(std.testing.allocator);
    tip.reconcile(&tree);
    try std.testing.expect(tip.deadline() == null);
    try std.testing.expect(tip.descriptionFor(owner) == null);
}
