//! Event routing and focus/capture behavior at the pure v7 boundary.
const std = @import("std");
const event = @import("event.zig");
const focus = @import("focus.zig");
const input = @import("input.zig");
const widget = @import("widget.zig");
const FrameNodeId = @import("id.zig").FrameNodeId;
const WidgetId = @import("id.zig").WidgetId;
const Component = @import("component.zig").Component;

const outer: FrameNodeId = @enumFromInt(1);
const inner: FrameNodeId = @enumFromInt(2);
const first: FrameNodeId = @enumFromInt(3);
const second: FrameNodeId = @enumFromInt(4);
const first_key: WidgetId = .{ .owner = 4, .slot = 1, .generation = 1 };
const second_key: WidgetId = .{ .owner = 4, .slot = 2, .generation = 1 };
const recycled_key: WidgetId = .{ .owner = 4, .slot = 1, .generation = 2 };

fn treeWithChildren(swap: bool) !widget.WidgetTree {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    errdefer tree.deinit();
    const ids = if (swap) [_]FrameNodeId{ second, first } else [_]FrameNodeId{ first, second };
    for (ids) |id| {
        const key = if ((id == first) != swap) first_key else second_key;
        try tree.nodes.append(std.testing.allocator, .{
            .id = id,
            .widget_id = key,
            .kind = .{ .button = .{ .label = "Action" } },
            .parent = inner,
            .rect = .{
                .x = if (key.eql(first_key)) 0 else 40,
                .y = 0,
                .w = 40,
                .h = 20,
            },
        });
    }
    try tree.nodes.append(std.testing.allocator, .{
        .id = inner,
        .kind = .{ .column = .{} },
        .parent = outer,
        .rect = .{ .w = 90, .h = 40 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = outer,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .w = 100, .h = 60 },
    });
    return tree;
}

const Visit = struct { node: FrameNodeId, phase: event.Phase };
const Trace = struct {
    // SAFETY: only entries before count are read.
    visits: [12]Visit = undefined,
    count: usize = 0,
    defaults: usize = 0,
    stop_at: ?Visit = null,
    prevent_at: ?Visit = null,
    fn onEvent(raw: *anyopaque, routed: *event.DispatchContext) void {
        const self: *Trace = @ptrCast(@alignCast(raw));
        const visit: Visit = .{ .node = routed.current_target, .phase = routed.phase };
        self.visits[self.count] = visit;
        self.count += 1;
        if (self.stop_at) |stop| {
            if (std.meta.eql(stop, visit)) routed.stopPropagation();
        }
        if (self.prevent_at) |prevent| {
            if (std.meta.eql(prevent, visit)) routed.preventDefault();
        }
    }
    fn onDefault(raw: *anyopaque, _: *event.DispatchContext) void {
        const self: *Trace = @ptrCast(@alignCast(raw));
        self.defaults += 1;
    }
    fn handlers(self: *Trace) event.Handlers {
        return .{ .user = self, .on_event = onEvent, .on_default = onDefault };
    }
};

// All ancestors see capture in root-to-leaf order, then target, then bubble.
test "api-w09 nested route orders phases without allocating a path" {
    var tree = try treeWithChildren(false);
    defer tree.deinit();
    var trace: Trace = .{};
    const ev: event.Event = .{ .mouse_down = .{ .button = .left, .x = 1, .y = 1 } };
    const routed = event.dispatch(&tree, first, &ev, trace.handlers()) orelse
        return error.RouteMissing;
    const expected = [_]Visit{
        .{ .node = outer, .phase = .capture },
        .{ .node = inner, .phase = .capture },
        .{ .node = first, .phase = .target },
        .{ .node = inner, .phase = .bubble },
        .{ .node = outer, .phase = .bubble },
    };
    try std.testing.expectEqualSlices(Visit, &expected, trace.visits[0..trace.count]);
    try std.testing.expect(!routed.default_prevented);
    try std.testing.expectEqual(@as(usize, 1), trace.defaults);
}

// Stopping propagation never implies preventDefault; both controls work in every phase.
test "api-w09 propagation stop and default prevention are independent" {
    var tree = try treeWithChildren(false);
    defer tree.deinit();
    var trace: Trace = .{ .stop_at = .{ .node = inner, .phase = .capture } };
    const ev: event.Event = .{ .mouse_up = .{ .button = .left, .x = 1, .y = 1 } };
    const stopped = event.dispatch(&tree, first, &ev, trace.handlers()).?;
    try std.testing.expectEqual(@as(usize, 2), trace.count);
    try std.testing.expect(stopped.propagation_stopped);
    try std.testing.expectEqual(@as(usize, 1), trace.defaults);
    trace = .{ .prevent_at = .{ .node = inner, .phase = .bubble } };
    const prevented = event.dispatch(&tree, first, &ev, trace.handlers()).?;
    try std.testing.expectEqual(@as(usize, 5), trace.count);
    try std.testing.expect(prevented.default_prevented);
    try std.testing.expectEqual(@as(usize, 0), trace.defaults);
}

// A wheel changes only the closest scroller; a listener can stop that default
// without also stopping another listener's bubble notification.
test "api-w09 wheel nearest default and preventDefault" {
    var tree = try treeWithChildren(false);
    defer tree.deinit();
    var parent_scroll: widget.ScrollState = .{ .max_offset = .{ 0, 200 } };
    var child_scroll: widget.ScrollState = .{ .max_offset = .{ 0, 100 } };
    tree.node(outer).?.scroll = .{ .state = &parent_scroll };
    tree.node(inner).?.scroll = .{ .state = &child_scroll };
    const wheel: event.Event = .{ .mouse_wheel = .{
        .x = 1,
        .y = 1,
        .delta_x = 0,
        .delta_y = -1,
        .unit = .line,
        .phase = .update,
    } };
    var trace: Trace = .{ .prevent_at = .{ .node = first, .phase = .target } };
    const prevented = event.dispatch(&tree, first, &wheel, trace.handlers()).?;
    try std.testing.expectEqual(@as(usize, 5), trace.count);
    try std.testing.expect(prevented.default_prevented);
    try std.testing.expectEqual(@as(f32, 0), child_scroll.offset[1]);
    trace = .{};
    _ = event.dispatch(&tree, first, &wheel, trace.handlers()).?;
    try std.testing.expectEqual(@as(f32, 20), child_scroll.offset[1]);
    try std.testing.expectEqual(@as(f32, 0), parent_scroll.offset[1]);
    try std.testing.expectEqual(@as(usize, 0), trace.defaults);
}

const Notifications = struct {
    // SAFETY: only entries before changed are read.
    changes: [8]focus.Change = undefined,
    changed: usize = 0,
    // SAFETY: only entries before cancelled_count are read.
    cancelled: [8]focus.Cancellation = undefined,
    cancelled_count: usize = 0,
    fn changedFocus(raw: *anyopaque, change: focus.Change) void {
        const self: *Notifications = @ptrCast(@alignCast(raw));
        self.changes[self.changed] = change;
        self.changed += 1;
    }
    fn cancelledPointer(raw: *anyopaque, cancelled: focus.Cancellation) void {
        const self: *Notifications = @ptrCast(@alignCast(raw));
        self.cancelled[self.cancelled_count] = cancelled;
        self.cancelled_count += 1;
    }
    fn observer(self: *Notifications) focus.Observer {
        return .{ .user = self, .on_focus = changedFocus, .on_cancel = cancelledPointer };
    }
};

// Dense order is not stable identity. Release must not activate the old slot's
// replacement, and sibling reorder must keep the original target captured.
test "api-w09 capture survives reorder and rejects recycled generation" {
    var original = try treeWithChildren(false);
    defer original.deinit();
    var reordered = try treeWithChildren(true);
    try std.testing.expect(original.frameNode(first_key).? != reordered.frameNode(first_key).?);
    defer reordered.deinit();
    var state: focus.Manager = .{};
    var notices: Notifications = .{};
    try std.testing.expect(try state.press(&original, .{ .mouse = .left }, first_key));
    state.reconcile(&original, &reordered, notices.observer());
    try std.testing.expectEqual(
        @as(?WidgetId, first_key),
        state.captured(&reordered, .{ .mouse = .left }, notices.observer()),
    );
    const release = state.release(&reordered, .{ .mouse = .left }, first_key, notices.observer());
    try std.testing.expectEqual(@as(?WidgetId, first_key), release.target);
    try std.testing.expect(release.activate);
    try std.testing.expectEqual(@as(usize, 0), notices.cancelled_count);
    try std.testing.expect(!state.set(&reordered, recycled_key, notices.observer()));
    try std.testing.expect(!try state.press(&reordered, .{ .mouse = .left }, recycled_key));
}

// The captured target receives moves outside its hit area. Only a matching
// release inside it activates; cancellation and an outside release never do.
test "api-w09 press move release outside back inside and cancel" {
    var tree = try treeWithChildren(false);
    defer tree.deinit();
    var state: focus.Manager = .{};
    var notices: Notifications = .{};
    try std.testing.expect(try state.press(&tree, .{ .mouse = .left }, first_key));
    try std.testing.expectEqual(
        @as(?WidgetId, first_key),
        state.captured(&tree, .{ .mouse = .left }, notices.observer()),
    );
    const outside = state.release(&tree, .{ .mouse = .left }, second_key, notices.observer());
    try std.testing.expect(!outside.activate);
    try std.testing.expect(state.captured(&tree, .{ .mouse = .left }, notices.observer()) == null);
    try std.testing.expect(try state.press(&tree, .{ .mouse = .left }, first_key));
    try std.testing.expectEqual(
        @as(?WidgetId, first_key),
        state.captured(&tree, .{ .mouse = .left }, notices.observer()),
    );
    try std.testing.expect(state.release(&tree, .{ .mouse = .left }, first_key, notices.observer()).activate);
    try std.testing.expect(try state.press(&tree, .{ .mouse = .left }, first_key));
    state.cancel(.{ .mouse = .left }, notices.observer());
    try std.testing.expectEqual(@as(usize, 1), notices.cancelled_count);
    try std.testing.expectEqual(first_key, notices.cancelled[0].target);
    try std.testing.expect(!state.release(&tree, .{ .mouse = .left }, first_key, notices.observer()).activate);
}

// Focus falls forward to a surviving sibling; a removed pointer owner is
// cancelled before the old tree is retired, never silently retargeted.
test "api-w09 removal fallback and captured owner cancellation" {
    var original = try treeWithChildren(false);
    defer original.deinit();
    var replacement = widget.WidgetTree.init(std.testing.allocator);
    defer replacement.deinit();
    try replacement.nodes.append(std.testing.allocator, .{
        .id = first,
        .widget_id = second_key,
        .kind = .{ .button = .{ .label = "Next" } },
        .parent = .root,
        .rect = .{ .w = 20, .h = 20 },
    });
    var state: focus.Manager = .{};
    var notices: Notifications = .{};
    try std.testing.expect(state.set(&original, first_key, notices.observer()));
    try std.testing.expect(try state.press(&original, .{ .mouse = .left }, first_key));
    state.reconcile(&original, &replacement, notices.observer());
    try std.testing.expectEqual(@as(?WidgetId, second_key), state.current);
    try std.testing.expectEqual(focus.Reason.removed, notices.changes[1].reason);
    try std.testing.expectEqual(@as(usize, 1), notices.cancelled_count);
    try std.testing.expectEqual(first_key, notices.cancelled[0].target);
    const lost: event.Event = .{ .capture_lost = .{
        .target_id = notices.cancelled[0].target,
        .pointer = notices.cancelled[0].pointer,
    } };
    var trace: Trace = .{};
    try std.testing.expect(event.dispatch(&original, first, &lost, trace.handlers()) != null);
    try std.testing.expectEqual(@as(usize, 1), trace.defaults);
    try std.testing.expect(event.dispatch(&replacement, first, &lost, trace.handlers()) == null);
    try std.testing.expect(!state.release(&replacement, .{ .mouse = .left }, second_key, notices.observer()).activate);
}

// Interaction disabled and hidden ancestry deny hit, focus, pointer action,
// and direct semantic activation. Hidden layout must remain in the tree.
test "api-w09 disabled and hidden nodes are not actionable" {
    var tree = try treeWithChildren(false);
    defer tree.deinit();
    tree.node(first).?.interaction.disabled = true;
    try std.testing.expect(input.hitActionable(&tree, .{ 1, 1 }) == null);
    var state: focus.Manager = .{};
    var notices: Notifications = .{};
    try std.testing.expect(!state.set(&tree, first_key, notices.observer()));
    try std.testing.expect(!try state.press(&tree, .{ .mouse = .left }, first_key));
    tree.node(first).?.interaction.disabled = false;
    try std.testing.expect(try state.press(&tree, .{ .mouse = .left }, first_key));
    tree.node(inner).?.style.visibility = .hidden;
    try std.testing.expect(state.captured(&tree, .{ .mouse = .left }, notices.observer()) == null);
    try std.testing.expectEqual(@as(usize, 1), notices.cancelled_count);
    try std.testing.expect(!state.release(&tree, .{ .mouse = .left }, first_key, notices.observer()).activate);
    try std.testing.expect(!widget.isVisible(&tree, first));
    try std.testing.expect(input.hitActionable(&tree, .{ 1, 1 }) == null);
    try std.testing.expect(!state.set(&tree, first_key, notices.observer()));
    try std.testing.expect(!try state.press(&tree, .{ .mouse = .left }, first_key));
    try std.testing.expectEqual(@as(f32, 40), tree.nodeConst(first).?.rect.w);
}

// Tab groups sort positive indices first, permit focus on negative indices,
// and support keyed custom leaves without relying on their dense positions.
test "api-w09 focus tab groups custom leaves and explicit blur" {
    var tree = try treeWithChildren(false);
    defer tree.deinit();
    tree.node(first).?.interaction = .{ .tab_index = 2, .tab_group = 7 };
    tree.node(second).?.interaction = .{ .tab_index = 1, .tab_group = 7 };
    var state: focus.Manager = .{};
    var notices: Notifications = .{};
    try std.testing.expectEqual(@as(?WidgetId, second_key), state.step(&tree, .forward, 7, notices.observer()));
    try std.testing.expectEqual(@as(?WidgetId, first_key), state.step(&tree, .forward, 7, notices.observer()));
    try std.testing.expectEqual(@as(?WidgetId, second_key), state.step(&tree, .forward, 7, notices.observer()));
    try std.testing.expectEqual(@as(?WidgetId, first_key), state.step(&tree, .backward, 7, notices.observer()));
    tree.node(first).?.interaction.tab_index = -1;
    try std.testing.expect(state.set(&tree, first_key, notices.observer()));
    try std.testing.expectEqual(@as(?WidgetId, second_key), state.step(&tree, .forward, 7, notices.observer()));
    try std.testing.expect(state.contains(&tree, inner, second_key));
    try std.testing.expect(!state.contains(&tree, first, second_key));
    state.blur(notices.observer());
    try std.testing.expect(state.current == null);
    try std.testing.expectEqual(focus.Reason.blur, notices.changes[notices.changed - 1].reason);
    const custom: FrameNodeId = @enumFromInt(9);
    const custom_key: WidgetId = .{ .owner = 4, .slot = 9, .generation = 1 };
    try tree.nodes.append(std.testing.allocator, .{
        .id = custom,
        .widget_id = custom_key,
        .kind = .{ .spacer = .{} },
        .parent = .root,
        .rect = .{ .w = 10, .h = 10 },
        .interaction = .{ .focusable = true },
    });
    try std.testing.expect(state.set(&tree, custom_key, notices.observer()));
}

// Mouse and touch captures are independent; cancellation retires only its
// own contact and a late end cannot activate that contact.
test "api-w09 touch start target capture and cancel isolation" {
    var tree = try treeWithChildren(false);
    defer tree.deinit();
    var state: focus.Manager = .{};
    var notices: Notifications = .{};
    try std.testing.expect(try state.press(&tree, .{ .touch = 10 }, first_key));
    try std.testing.expect(try state.press(&tree, .{ .touch = 11 }, second_key));
    try std.testing.expectEqual(@as(?WidgetId, first_key), state.captured(&tree, .{ .touch = 10 }, notices.observer()));
    state.cancel(.{ .touch = 10 }, notices.observer());
    try std.testing.expect(!state.release(&tree, .{ .touch = 10 }, first_key, notices.observer()).activate);
    try std.testing.expect(state.release(&tree, .{ .touch = 11 }, second_key, notices.observer()).activate);
    try std.testing.expectEqual(@as(usize, 1), notices.cancelled_count);
}

// A repeated key remains observable, key-up is delivered, and neither key
// event inserts text. Only committed text carries a character sequence.
test "api-w09 key-up repeat and committed text are distinct events" {
    var tree = try treeWithChildren(false);
    defer tree.deinit();
    const Probe = struct {
        const Self = @This();
        down: usize = 0,
        up: usize = 0,
        text: usize = 0,
        repeat: bool = false,
        fn onEvent(raw: *anyopaque, route: *event.DispatchContext) void {
            if (route.phase != .target) return;
            const self: *Self = @ptrCast(@alignCast(raw));
            switch (route.event.*) {
                .key_down => |key| {
                    self.down += 1;
                    self.repeat = key.repeat;
                    std.debug.assert(key.modifiers.control);
                    std.debug.assert(key.physical.?.code == 30);
                },
                .key_up => self.up += 1,
                .text_input => |text| {
                    std.debug.assert(std.mem.eql(u8, text.text, "a"));
                    self.text += 1;
                },
                else => {},
            }
        }
    };
    var probe: Probe = .{};
    const handlers: event.Handlers = .{ .user = &probe, .on_event = Probe.onEvent };
    const key: event.KeyEvent = .{
        .key = .unidentified,
        .logical = .{ .character = "a" },
        .physical = .{ .code = 30 },
        .modifiers = .{ .control = true },
        .repeat = true,
    };
    const down: event.Event = .{ .key_down = key };
    const up: event.Event = .{ .key_up = key };
    const text: event.Event = .{ .text_input = .{ .text = "a" } };
    _ = event.dispatch(&tree, first, &down, handlers).?;
    _ = event.dispatch(&tree, first, &up, handlers).?;
    try std.testing.expectEqual(@as(usize, 0), probe.text);
    _ = event.dispatch(&tree, first, &text, handlers).?;
    try std.testing.expectEqual(@as(usize, 1), probe.down);
    try std.testing.expectEqual(@as(usize, 1), probe.up);
    try std.testing.expect(probe.repeat);
    try std.testing.expectEqual(@as(usize, 1), probe.text);
}

// All activation sources share one default action. A mouse down alone cannot
// mutate the control; preventing the semantic event's default cancels it.
test "api-w09 release keyboard and a11y activate the same action once" {
    var tree = try treeWithChildren(false);
    defer tree.deinit();
    var checked = false;
    tree.node(first).?.kind = .{ .checkbox = .{ .label = "Check", .value = &checked } };
    var components: std.AutoHashMapUnmanaged(FrameNodeId, Component) = .empty;
    defer components.deinit(std.testing.allocator);
    const Receiver = struct {
        const Self = @This();
        tree: *const widget.WidgetTree,
        components: *std.AutoHashMapUnmanaged(FrameNodeId, Component),
        actions: usize = 0,
        last_click_count: u8 = 0,
        prevent: bool = false,
        fn onEvent(raw: *anyopaque, route: *event.DispatchContext) void {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.prevent and route.phase == .target and route.event.* == .activate) {
                route.preventDefault();
            }
        }
        fn onDefault(raw: *anyopaque, route: *event.DispatchContext) void {
            const self: *Self = @ptrCast(@alignCast(raw));
            switch (route.event.*) {
                .activate => |action| {
                    self.last_click_count = action.click_count;
                    if (event.activate(self.tree, action.target_id, self.components)) {
                        self.actions += 1;
                    }
                },
                else => {},
            }
        }
        fn handlers(self: *Self) event.Handlers {
            return .{ .user = self, .on_event = onEvent, .on_default = onDefault };
        }
    };
    var receiver: Receiver = .{ .tree = &tree, .components = &components };
    var state: focus.Manager = .{};
    const down: event.Event = .{ .mouse_down = .{ .button = .left, .x = 5, .y = 5 } };
    const up: event.Event = .{ .mouse_up = .{ .button = .left, .x = 5, .y = 5 } };
    try std.testing.expect(try state.press(&tree, .{ .mouse = .left }, first_key));
    _ = event.dispatch(&tree, first, &down, receiver.handlers()).?;
    try std.testing.expect(!checked);
    _ = event.dispatch(&tree, first, &up, receiver.handlers()).?;
    try std.testing.expect(!checked);
    const released = state.release(&tree, .{ .mouse = .left }, first_key, null);
    try std.testing.expect(released.activate);
    const pointer: event.Event = .{ .activate = .{
        .target_id = released.target.?,
        .source = .pointer,
        .click_count = 2,
    } };
    _ = event.dispatch(&tree, first, &pointer, receiver.handlers()).?;
    try std.testing.expect(checked);
    try std.testing.expectEqual(@as(usize, 1), receiver.actions);
    try std.testing.expectEqual(@as(u8, 2), receiver.last_click_count);
    try std.testing.expect(!state.release(&tree, .{ .mouse = .left }, first_key, null).activate);

    const keyboard: event.Event = .{ .activate = .{
        .target_id = first_key,
        .source = .keyboard,
    } };
    _ = event.dispatch(&tree, first, &keyboard, receiver.handlers()).?;
    try std.testing.expect(!checked);
    const accessibility: event.Event = .{ .activate = .{
        .target_id = first_key,
        .source = .accessibility,
    } };
    receiver.prevent = true;
    _ = event.dispatch(&tree, first, &accessibility, receiver.handlers()).?;
    try std.testing.expect(!checked);
    receiver.prevent = false;
    _ = event.dispatch(&tree, first, &accessibility, receiver.handlers()).?;
    try std.testing.expect(checked);
    try std.testing.expectEqual(@as(usize, 3), receiver.actions);
    tree.node(inner).?.interaction.disabled = true;
    try std.testing.expect(!event.activate(&tree, first_key, &components));
    try std.testing.expect(checked);
}

// Pixel deltas are not line scaled; page deltas use the scroller's viewport.
// A propagation stop does not suppress the nearest scrolling default.
test "api-w09 wheel units and propagation stop preserve one default" {
    var tree = try treeWithChildren(false);
    defer tree.deinit();
    var scrolling: widget.ScrollState = .{ .max_offset = .{ 0, 300 } };
    tree.node(inner).?.scroll = .{ .state = &scrolling };
    var trace: Trace = .{ .stop_at = .{ .node = first, .phase = .target } };
    const pixels: event.Event = .{ .mouse_wheel = .{
        .x = 1,
        .y = 1,
        .delta_x = 0,
        .delta_y = -4,
        .unit = .pixel,
        .phase = .momentum,
    } };
    const result = event.dispatch(&tree, first, &pixels, trace.handlers()).?;
    try std.testing.expect(result.propagation_stopped);
    try std.testing.expectEqual(@as(?FrameNodeId, inner), result.default_target);
    try std.testing.expectEqual(@as(f32, 4), scrolling.offset[1]);
    const page: event.Event = .{ .mouse_wheel = .{
        .x = 1,
        .y = 1,
        .delta_x = 0,
        .delta_y = -1,
        .unit = .page,
        .phase = .end,
    } };
    _ = event.dispatch(&tree, first, &page, trace.handlers()).?;
    try std.testing.expectEqual(@as(f32, 44), scrolling.offset[1]);
}

// Unkeyed descendants inherit a keyed owner, but neither an ancestor's
// disabled state nor its hidden state may be bypassed by that descendant.
test "api-w09 unkeyed leaf hit resolves stable enabled owner" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    const leaf: FrameNodeId = @enumFromInt(10);
    try tree.nodes.append(std.testing.allocator, .{
        .id = leaf,
        .parent = first,
        .kind = .{ .label = .{ .text = "child" } },
        .rect = .{ .w = 10, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = first,
        .widget_id = first_key,
        .parent = .root,
        .kind = .{ .button = .{ .label = "owner" } },
        .rect = .{ .w = 20, .h = 20 },
    });
    try std.testing.expectEqual(@as(?WidgetId, first_key), input.hitStable(&tree, .{ 1, 1 }));
    tree.node(first).?.interaction.disabled = true;
    try std.testing.expect(input.hitStable(&tree, .{ 1, 1 }) == null);
    tree.node(first).?.interaction.disabled = false;
    tree.node(first).?.style.visibility = .hidden;
    try std.testing.expect(input.hitStable(&tree, .{ 1, 1 }) == null);
}

// Raw touch values and composition preedit are delivered to the original
// captured contact, including its cancellation rather than a late tap.
test "api-w09 touch cancel and composition payload reach their consumers" {
    var tree = try treeWithChildren(false);
    defer tree.deinit();
    const Probe = struct {
        const Self = @This();
        // SAFETY: only entries before touch_count are read.
        touches: [3]std.meta.Tag(event.Event) = undefined,
        touch_count: usize = 0,
        composition_count: usize = 0,
        fn onEvent(raw: *anyopaque, route: *event.DispatchContext) void {
            if (route.phase != .target) return;
            const self: *Self = @ptrCast(@alignCast(raw));
            switch (route.event.*) {
                .touch_start, .touch_move, .touch_cancel => |touch| {
                    std.debug.assert(touch.id == 17);
                    self.touches[self.touch_count] = std.meta.activeTag(route.event.*);
                    self.touch_count += 1;
                },
                .composition => |value| {
                    std.debug.assert(value.phase == .update);
                    std.debug.assert(std.mem.eql(u8, value.text, "é"));
                    std.debug.assert(value.selection_start == 0);
                    std.debug.assert(value.selection_end == 2);
                    self.composition_count += 1;
                },
                else => {},
            }
        }
    };
    var probe: Probe = .{};
    const handlers: event.Handlers = .{ .user = &probe, .on_event = Probe.onEvent };
    var state: focus.Manager = .{};
    try std.testing.expect(try state.press(&tree, .{ .touch = 17 }, first_key));
    const start: event.Event = .{ .touch_start = .{ .id = 17, .x = 1, .y = 1 } };
    const moved: event.Event = .{ .touch_move = .{ .id = 17, .x = 70, .y = 1 } };
    const cancelled: event.Event = .{ .touch_cancel = .{ .id = 17, .x = 70, .y = 1 } };
    _ = event.dispatch(&tree, first, &start, handlers).?;
    const captured = state.captured(&tree, .{ .touch = 17 }, null).?;
    _ = event.dispatch(&tree, tree.frameNode(captured).?, &moved, handlers).?;
    _ = event.dispatch(&tree, tree.frameNode(captured).?, &cancelled, handlers).?;
    state.cancel(.{ .touch = 17 }, null);
    try std.testing.expect(!state.release(&tree, .{ .touch = 17 }, first_key, null).activate);
    const composition: event.Event = .{ .composition = .{
        .phase = .update,
        .text = "é",
        .selection_start = 0,
        .selection_end = 2,
    } };
    _ = event.dispatch(&tree, first, &composition, handlers).?;
    try std.testing.expectEqualSlices(
        std.meta.Tag(event.Event),
        &.{ .touch_start, .touch_move, .touch_cancel },
        probe.touches[0..probe.touch_count],
    );
    try std.testing.expectEqual(@as(usize, 1), probe.composition_count);
}

// A disabled topmost control blocks the lower layer rather than forwarding
// its press to an unrelated sibling underneath.
test "api-w09 disabled overlay does not click through to another control" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    for ([_]FrameNodeId{ first, second }) |id| {
        try tree.nodes.append(std.testing.allocator, .{
            .id = id,
            .parent = .root,
            .widget_id = if (id == first) first_key else second_key,
            .kind = .{ .button = .{ .label = "overlap" } },
            .rect = .{ .w = 20, .h = 20 },
            .interaction = .{ .disabled = id == first },
        });
    }
    try std.testing.expect(input.hitActionable(&tree, .{ 5, 5 }) == null);
    try std.testing.expect(input.hitStable(&tree, .{ 5, 5 }) == null);
}

// Native Unicode keycodes pass through a scalar logical identity with no
// temporary string lifetime, while committed text stays a separate event.
test "api-w09 native logical codepoint is received without synthesized text" {
    var tree = try treeWithChildren(false);
    defer tree.deinit();
    const Probe = struct {
        const Self = @This();
        scalar: ?u21 = null,
        text_count: usize = 0,
        fn onEvent(raw: *anyopaque, route: *event.DispatchContext) void {
            if (route.phase != .target) return;
            const self: *Self = @ptrCast(@alignCast(raw));
            switch (route.event.*) {
                .key_down => |key| switch (key.logical) {
                    .codepoint => |scalar| self.scalar = scalar,
                    else => {},
                },
                .text_input => self.text_count += 1,
                else => {},
            }
        }
    };
    var probe: Probe = .{};
    const key: event.Event = .{ .key_down = .{
        .key = .unidentified,
        .physical = .{ .code = 4 },
        .logical = .{ .codepoint = 'a' },
    } };
    _ = event.dispatch(&tree, first, &key, .{
        .user = &probe,
        .on_event = Probe.onEvent,
    }).?;
    try std.testing.expectEqual(@as(?u21, 'a'), probe.scalar);
    try std.testing.expectEqual(@as(usize, 0), probe.text_count);
}

// Slider drag updates continue outside its box because capture keeps the
// original stable target; release clears capture and later moves do nothing.
test "api-w09 slider drag out and back releases without a delayed update" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    var value: f32 = 0;
    try tree.nodes.append(std.testing.allocator, .{
        .id = first,
        .widget_id = first_key,
        .parent = .root,
        .kind = .{ .slider = .{ .label = "range", .value = &value, .min = 0, .max = 1 } },
        .rect = .{ .w = 100, .h = 20 },
    });
    var state: focus.Manager = .{};
    try std.testing.expect(try state.press(&tree, .{ .mouse = .left }, first_key));
    const owner = state.captured(&tree, .{ .mouse = .left }, null).?;
    try std.testing.expect(event.sliderSet(
        &tree,
        tree.frameNode(owner).?,
        150,
        widget.visualBorderRect(&tree, tree.frameNode(owner).?),
    ));
    try std.testing.expectEqual(@as(f32, 1), value);
    try std.testing.expect(event.sliderSet(
        &tree,
        tree.frameNode(owner).?,
        25,
        widget.visualBorderRect(&tree, tree.frameNode(owner).?),
    ));
    try std.testing.expectEqual(@as(f32, 0.25), value);
    _ = state.release(&tree, .{ .mouse = .left }, first_key, null);
    if (state.captured(&tree, .{ .mouse = .left }, null)) |late| {
        _ = event.sliderSet(
            &tree,
            tree.frameNode(late).?,
            80,
            widget.visualBorderRect(&tree, tree.frameNode(late).?),
        );
    }
    try std.testing.expectEqual(@as(f32, 0.25), value);
}

// Two SDL touch devices can reuse one finger ID. Focus loss cancels both
// captures and emits one blur, so no late end can activate either owner.
test "api-w09 touch device identity and window focus loss revoke captures" {
    var tree = try treeWithChildren(false);
    defer tree.deinit();
    const device_a: u128 = (@as(u128, 1) << 64) | 17;
    const device_b: u128 = (@as(u128, 2) << 64) | 17;
    var state: focus.Manager = .{};
    var notices: Notifications = .{};
    try std.testing.expect(state.set(&tree, first_key, notices.observer()));
    try std.testing.expect(try state.press(&tree, .{ .touch = device_a }, first_key));
    try std.testing.expect(try state.press(&tree, .{ .touch = device_b }, second_key));
    try std.testing.expectEqual(
        @as(?WidgetId, first_key),
        state.captured(&tree, .{ .touch = device_a }, notices.observer()),
    );
    try std.testing.expectEqual(
        @as(?WidgetId, second_key),
        state.captured(&tree, .{ .touch = device_b }, notices.observer()),
    );
    const lost: event.Event = .window_focus_lost;
    switch (lost) {
        .window_focus_lost => state.reset(notices.observer()),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 2), notices.cancelled_count);
    try std.testing.expectEqual(focus.Reason.blur, notices.changes[1].reason);
    try std.testing.expect(state.current == null);
    try std.testing.expect(!state.release(&tree, .{ .touch = device_a }, first_key, null).activate);
    try std.testing.expect(!state.release(&tree, .{ .touch = device_b }, second_key, null).activate);
}

// The routed target and the semantic action ID must name the same widget;
// otherwise listeners for one control could trigger another control's action.
test "api-w09 semantic action rejects mismatched or stale route target" {
    var tree = try treeWithChildren(false);
    defer tree.deinit();
    var trace: Trace = .{};
    const action: event.Event = .{ .activate = .{
        .target_id = second_key,
        .source = .accessibility,
    } };
    try std.testing.expect(event.dispatch(&tree, first, &action, trace.handlers()) == null);
    try std.testing.expectEqual(@as(usize, 0), trace.count);
    try std.testing.expectEqual(@as(usize, 0), trace.defaults);
    const stale: event.Event = .{ .activate = .{
        .target_id = recycled_key,
        .source = .keyboard,
    } };
    try std.testing.expect(event.dispatch(&tree, first, &stale, trace.handlers()) == null);
    try std.testing.expect(event.dispatch(&tree, second, &action, trace.handlers()) != null);
    try std.testing.expectEqual(@as(usize, 1), trace.defaults);
}
