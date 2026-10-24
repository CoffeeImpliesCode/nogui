//! W24 action dispatch timing: one measured event per dispatch, reported on
//! the dispatching thread after the dispatch returns, with no allocation.
const std = @import("std");
const action = @import("action.zig");
const Clock = @import("clock.zig").Clock;
const Session = @import("session.zig").Session;
const WidgetId = @import("id.zig").WidgetId;
const WidgetTree = @import("widget.zig").WidgetTree;

const Save = action.Action(void, "file.save");
const Rename = action.Action(struct { name: []const u8 }, "file.rename");
const Clear = action.Action(void, "editor.clear");

const parent_widget: WidgetId = .{ .owner = 7, .slot = 1, .generation = 3 };
const child_widget: WidgetId = .{ .owner = 7, .slot = 2, .generation = 3 };

const event_capacity = 8;

/// Test owned state. Models hold this pointer, so a handler can advance the
/// virtual clock or run a nested dispatch without a Session borrow.
const World = struct {
    now_ns: i96 = 0,
    // SAFETY: only entries before count are read; handlers append in order.
    events: [event_capacity]action.DispatchEvent = undefined,
    count: usize = 0,
    dropped: usize = 0,
    /// Set by a handler before it returns.
    handler_done: bool = false,
    /// Set by a listener before it returns.
    listener_done: bool = false,
    /// Sampled by the callback. True means the handler had already returned.
    handler_ran_first: bool = false,
    /// Sampled by the callback. True means the listener had already returned.
    listener_ran_first: bool = false,
    registry: ?*action.Registry = null,
    tree: ?*const WidgetTree = null,
    nested_name: ?[]const u8 = null,

    fn onDispatch(user: *anyopaque, event: action.DispatchEvent) void {
        const self: *World = @ptrCast(@alignCast(user));
        self.handler_ran_first = self.handler_done;
        self.listener_ran_first = self.listener_done;
        if (self.count < self.events.len) {
            self.events[self.count] = event;
        } else {
            self.dropped += 1;
        }
        self.count += 1;
    }

    fn at(self: *const World, index: usize) action.DispatchEvent {
        std.debug.assert(index < self.count);
        return self.events[index];
    }

    fn last(self: *const World) action.DispatchEvent {
        return self.at(self.count - 1);
    }
};

/// Reads the injected clock. The handler owns the cost of a dispatch, so the
/// clock must move while it runs.
fn nowTicks(context: *anyopaque) i96 {
    const world: *World = @ptrCast(@alignCast(context));
    return world.now_ns;
}

const Controller = struct {
    world: *World,
    suppress: bool = false,
    calls: u32 = 0,
    name_len: usize = 0,

    fn save(self: *Controller, _: *const Save.Payload, _: *Session) !void {
        self.calls += 1;
        self.world.now_ns += 40;
        self.world.handler_done = true;
        if (self.world.nested_name) |name| {
            const registry = self.world.registry orelse return error.MissingRegistry;
            _ = try registry.dispatch(self.world.tree.?, null, name, null);
        }
    }

    fn rename(self: *Controller, payload: *const Rename.Payload, _: *Session) !void {
        self.calls += 1;
        self.name_len = payload.name.len;
        self.world.now_ns += 40;
        self.world.handler_done = true;
    }

    fn state(self: *const Controller, _: *Session) action.Availability {
        return if (self.suppress) .disabled else .available;
    }
};

const Follower = struct {
    world: *World,
    calls: u32 = 0,

    fn clear(self: *Follower, _: *const Clear.Payload, _: *Session) !void {
        self.calls += 1;
        self.world.now_ns += 5;
    }
};

const Watcher = struct {
    world: *World,
    calls: u32 = 0,

    fn onSave(self: *Watcher, _: *const Save.Payload, _: *Session) !void {
        self.calls += 1;
        self.world.listener_done = true;
    }
};

fn makeTree(gpa: std.mem.Allocator) !WidgetTree {
    var tree = WidgetTree.init(gpa);
    errdefer tree.deinit();
    try tree.nodes.append(gpa, .{
        .id = @fromBackingInt(@intCast(2)),
        .widget_id = child_widget,
        .parent = @fromBackingInt(@intCast(1)),
        .kind = .{ .label = .{ .text = "child" } },
    });
    try tree.nodes.append(gpa, .{
        .id = @fromBackingInt(@intCast(1)),
        .widget_id = parent_widget,
        .parent = .root,
        .kind = .{ .label = .{ .text = "parent" } },
    });
    return tree;
}

/// Attaches the recorder to the registry. The clock stays virtual, so every
/// reported span is exact.
fn observe(registry: *action.Registry, world: *World) void {
    registry.setObserver(.{
        .clock = Clock.injected(world, nowTicks),
        .user = world,
        .on_dispatch = World.onDispatch,
    });
}

/// Reads the call count of any test model. The read borrow ends at return.
fn callsOf(comptime Owner: type, session: *Session, owner: anytype) !u32 {
    const Check = struct {
        fn run(value: *const Owner, result: *u32) !void {
            result.* = value.calls;
        }
    };
    var result: u32 = 0;
    try session.read(Owner, owner.weak(), &result, Check.run);
    return result;
}

test "api-w24: dispatch timing reports the registered name, result, and target" {
    var world: World = .{};
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var initial: Controller = .{ .world = &world };
    var controller = try session.create(Controller, &initial);
    defer session.release(Controller, &controller) catch unreachable;
    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();
    try registry.register(Rename);
    _ = try registry.bind(Rename, Controller, Controller.rename, null, .{ .widget = child_widget }, controller.weak());
    var tree = try makeTree(std.testing.allocator);
    defer tree.deinit();
    observe(&registry, &world);

    world.now_ns = 2_000;
    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        child_widget,
        "file.rename",
        "{\"name\":\"main.zig\"}",
    ));

    try std.testing.expectEqual(@as(usize, 1), world.count);
    try std.testing.expectEqual(@as(usize, 0), world.dropped);
    const event = world.last();
    try std.testing.expectEqualStrings("file.rename", event.name);
    try std.testing.expectEqual(action.Result.handled, event.result);
    try std.testing.expect(event.target.?.eql(child_widget));
    try std.testing.expectEqual(@as(i96, 2_000), event.start_ns);
    try std.testing.expectEqual(@as(i96, 2_040), event.end_ns);
    try std.testing.expectEqual(@as(u64, 40), event.duration_ns);
    try std.testing.expectEqual(@as(u32, 0), event.depth);
    // The handler ran inside the measured span and before the event.
    try std.testing.expect(world.handler_ran_first);
    const Name = struct {
        fn run(value: *const Controller, result: *usize) !void {
            result.* = value.name_len;
        }
    };
    var name_len: usize = 0;
    try session.read(Controller, controller.weak(), &name_len, Name.run);
    try std.testing.expectEqual(@as(usize, 8), name_len);
}

test "api-w24: an alias dispatch reports one event under the registered name" {
    var world: World = .{};
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var initial: Controller = .{ .world = &world };
    var controller = try session.create(Controller, &initial);
    defer session.release(Controller, &controller) catch unreachable;
    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();
    try registry.register(Save);
    try registry.registerAlias("save", "file.save");
    try registry.registerAlias("write", "save");
    _ = try registry.bind(Save, Controller, Controller.save, null, .app, controller.weak());
    var tree = try makeTree(std.testing.allocator);
    defer tree.deinit();
    observe(&registry, &world);

    // A chain of aliases resolves to one registered action and one event.
    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        null,
        "write",
        null,
    ));
    try std.testing.expectEqual(@as(usize, 1), world.count);
    try std.testing.expectEqualStrings("file.save", world.last().name);
    // The App scope decides, so the event names no widget.
    try std.testing.expect(world.last().target == null);
    try std.testing.expectEqual(@as(u64, 40), world.last().duration_ns);

    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        null,
        "save",
        null,
    ));
    try std.testing.expectEqual(@as(usize, 2), world.count);
    try std.testing.expectEqualStrings("file.save", world.at(1).name);
    try std.testing.expectEqual(@as(u32, 2), try callsOf(Controller, &session, &controller));
}

test "api-w24: a disabled scope reports the disabled widget and blocks fallback" {
    var world: World = .{};
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var initial: Controller = .{ .world = &world, .suppress = true };
    var controller = try session.create(Controller, &initial);
    defer session.release(Controller, &controller) catch unreachable;
    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();
    try registry.register(Save);
    _ = try registry.bind(Save, Controller, Controller.save, null, .app, controller.weak());
    _ = try registry.bind(
        Save,
        Controller,
        Controller.save,
        Controller.state,
        .{ .widget = child_widget },
        controller.weak(),
    );
    var tree = try makeTree(std.testing.allocator);
    defer tree.deinit();
    observe(&registry, &world);

    world.now_ns = 300;
    try std.testing.expectEqual(action.Result.disabled, try registry.dispatch(
        &tree,
        child_widget,
        "file.save",
        null,
    ));

    try std.testing.expectEqual(@as(usize, 1), world.count);
    const event = world.last();
    try std.testing.expectEqual(action.Result.disabled, event.result);
    try std.testing.expect(event.target.?.eql(child_widget));
    try std.testing.expectEqual(@as(i96, 300), event.start_ns);
    try std.testing.expectEqual(@as(i96, 300), event.end_ns);
    try std.testing.expectEqual(@as(u64, 0), event.duration_ns);
    // No handler ran, because the disabled scope suppressed the App fallback.
    try std.testing.expectEqual(@as(u32, 0), try callsOf(Controller, &session, &controller));
}

test "api-w24: an unavailable dispatch reports no target" {
    var world: World = .{ .now_ns = 500 };
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var initial: Controller = .{ .world = &world };
    var controller = try session.create(Controller, &initial);
    defer session.release(Controller, &controller) catch unreachable;
    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();
    try registry.register(Clear);
    var tree = try makeTree(std.testing.allocator);
    defer tree.deinit();
    observe(&registry, &world);

    // A registered action with no live handler is a real, measured result.
    try std.testing.expectEqual(action.Result.unavailable, try registry.dispatch(
        &tree,
        child_widget,
        "editor.clear",
        null,
    ));

    try std.testing.expectEqual(@as(usize, 1), world.count);
    const event = world.last();
    try std.testing.expectEqual(action.Result.unavailable, event.result);
    try std.testing.expectEqualStrings("editor.clear", event.name);
    try std.testing.expect(event.target == null);
    try std.testing.expectEqual(@as(i96, 500), event.start_ns);
    try std.testing.expectEqual(@as(i96, 500), event.end_ns);
}

test "api-w24: a nested dispatch reports its depth inside the outer span" {
    var world: World = .{};
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var initial: Controller = .{ .world = &world };
    var controller = try session.create(Controller, &initial);
    defer session.release(Controller, &controller) catch unreachable;
    var follower_value: Follower = .{ .world = &world };
    var follower = try session.create(Follower, &follower_value);
    defer session.release(Follower, &follower) catch unreachable;
    var watcher_value: Watcher = .{ .world = &world };
    var watcher = try session.create(Watcher, &watcher_value);
    defer session.release(Watcher, &watcher) catch unreachable;
    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();
    try registry.register(Save);
    try registry.register(Clear);
    var tree = try makeTree(std.testing.allocator);
    defer tree.deinit();
    _ = try registry.bind(Save, Controller, Controller.save, null, .app, controller.weak());
    _ = try registry.bind(Clear, Follower, Follower.clear, null, .app, follower.weak());
    _ = try registry.listen(Save, Watcher, Watcher.onSave, watcher.weak());
    world.registry = &registry;
    world.tree = &tree;
    world.nested_name = "editor.clear";
    observe(&registry, &world);

    world.now_ns = 10_000;
    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        null,
        "file.save",
        null,
    ));

    try std.testing.expectEqual(@as(usize, 2), world.count);
    try std.testing.expectEqual(@as(usize, 0), world.dropped);
    // The inner dispatch finishes first, so it is the first event.
    const inner = world.at(0);
    const outer = world.at(1);
    try std.testing.expectEqualStrings("editor.clear", inner.name);
    try std.testing.expectEqual(@as(u32, 1), inner.depth);
    try std.testing.expectEqualStrings("file.save", outer.name);
    try std.testing.expectEqual(@as(u32, 0), outer.depth);
    try std.testing.expectEqual(action.Result.handled, inner.result);
    try std.testing.expectEqual(action.Result.handled, outer.result);
    // Spans nest instead of overlapping.
    try std.testing.expectEqual(@as(i96, 10_040), inner.start_ns);
    try std.testing.expectEqual(@as(i96, 10_045), inner.end_ns);
    try std.testing.expectEqual(@as(u64, 5), inner.duration_ns);
    try std.testing.expectEqual(@as(i96, 10_000), outer.start_ns);
    try std.testing.expectEqual(@as(i96, 10_045), outer.end_ns);
    try std.testing.expectEqual(@as(u64, 45), outer.duration_ns);
    // The outer event arrives after its handler and after its listener.
    try std.testing.expect(world.handler_ran_first);
    try std.testing.expect(world.listener_ran_first);
    try std.testing.expectEqual(@as(u32, 1), try callsOf(Controller, &session, &controller));
    try std.testing.expectEqual(@as(u32, 1), try callsOf(Follower, &session, &follower));
    try std.testing.expectEqual(@as(u32, 1), try callsOf(Watcher, &session, &watcher));
    try std.testing.expectEqual(@as(usize, 0), registry.dispatch_depth);
}

test "api-w24: a failed dispatch reports no event and keeps the registry usable" {
    var world: World = .{};
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var initial: Controller = .{ .world = &world };
    var controller = try session.create(Controller, &initial);
    defer session.release(Controller, &controller) catch unreachable;
    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();
    try registry.register(Rename);
    try registry.register(Save);
    _ = try registry.bind(Rename, Controller, Controller.rename, null, .app, controller.weak());
    _ = try registry.bind(Save, Controller, Controller.save, null, .app, controller.weak());
    var tree = try makeTree(std.testing.allocator);
    defer tree.deinit();
    observe(&registry, &world);

    try std.testing.expectError(error.UnknownAction, registry.dispatch(
        &tree,
        null,
        "file.absent",
        null,
    ));
    try std.testing.expectError(error.InvalidParameters, registry.dispatch(
        &tree,
        null,
        "file.rename",
        "{\"name\":12}",
    ));
    try std.testing.expectError(error.InvalidParameters, registry.dispatch(
        &tree,
        null,
        "file.rename",
        null,
    ));
    // A dispatch that produced no result records nothing.
    try std.testing.expectEqual(@as(usize, 0), world.count);
    try std.testing.expectEqual(@as(usize, 0), registry.dispatch_depth);

    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        null,
        "file.rename",
        "{\"name\":\"main.zig\"}",
    ));
    try std.testing.expectEqual(@as(usize, 1), world.count);
    try std.testing.expectEqual(@as(usize, 0), registry.dispatch_depth);
}

test "api-w24: a dispatch allocates nothing with or without an observer" {
    // The allocator outlives the registry, which frees through the same field.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var world: World = .{};
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var initial: Controller = .{ .world = &world };
    var controller = try session.create(Controller, &initial);
    defer session.release(Controller, &controller) catch unreachable;
    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();
    try registry.register(Save);
    _ = try registry.bind(Save, Controller, Controller.save, null, .app, controller.weak());
    var tree = try makeTree(std.testing.allocator);
    defer tree.deinit();
    registry.gpa = failing.allocator();

    // Disabled instrumentation costs the same as enabled instrumentation.
    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        null,
        "file.save",
        null,
    ));
    observe(&registry, &world);
    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        null,
        "file.save",
        " { } ",
    ));
    try std.testing.expectEqual(@as(usize, 1), world.count);
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);

    // Clearing the observer stops the records.
    registry.setObserver(null);
    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        null,
        "file.save",
        null,
    ));
    try std.testing.expectEqual(@as(usize, 1), world.count);
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}
