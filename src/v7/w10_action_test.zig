//! W10 action registry: typed JSON, focused scope, and weak-owner delivery.
const std = @import("std");
const action = @import("action.zig");
const key_context = @import("key_context.zig");
const Session = @import("session.zig").Session;
const WidgetTree = @import("widget.zig").WidgetTree;
const WidgetId = @import("id.zig").WidgetId;

const Open = action.Action(struct {
    path: []const u8,
    line: u32,
}, "file.open");
const Save = action.Action(void, "file.save");
const Inspect = action.Action(struct {
    selection: struct { start: u32, end: u32 },
    tags: []const []const u8 = &.{},
}, "editor.inspect");
const Controller = struct {
    calls: u32 = 0,
    line: u32 = 0,
    // SAFETY: only the first path_len bytes are read, and open fills them.
    path: [32]u8 = undefined,
    path_len: usize = 0,
    source: u8 = 0,

    fn open(self: *Controller, payload: *const Open.Payload, _: *Session) !void {
        self.calls += 1;
        self.line = payload.line;
        self.path_len = payload.path.len;
        @memcpy(self.path[0..payload.path.len], payload.path);
    }

    fn save(self: *Controller, _: *const Save.Payload, _: *Session) !void {
        self.calls += 1;
    }
    fn inspect(self: *Controller, payload: *const Inspect.Payload, _: *Session) !void {
        self.calls += 1;
        self.line = payload.selection.end - payload.selection.start;
        self.path_len = payload.tags.len;
    }

    fn fromApp(self: *Controller, _: *const Open.Payload, _: *Session) !void {
        self.source = 1;
    }

    fn fromParent(self: *Controller, _: *const Open.Payload, _: *Session) !void {
        self.source = 2;
    }

    fn fromChild(self: *Controller, _: *const Open.Payload, _: *Session) !void {
        self.source = 3;
    }

    fn available(self: *const Controller, _: *Session) action.Availability {
        return if (self.source == 9) .unavailable else .available;
    }

    fn disabled(self: *const Controller, _: *Session) action.Availability {
        return if (self.source == 8) .disabled else .available;
    }
};

const Watcher = struct {
    calls: u32 = 0,
    line: u32 = 0,
    observed: *u32,

    fn onOpen(self: *Watcher, payload: *const Open.Payload, _: *Session) !void {
        self.calls += 1;
        self.line = payload.line;
        self.observed.* += 1;
    }
};

fn makeTree(gpa: std.mem.Allocator, parent: WidgetId, child: WidgetId) !WidgetTree {
    var tree = WidgetTree.init(gpa);
    errdefer tree.deinit();
    try tree.nodes.append(gpa, .{
        .id = @enumFromInt(2),
        .widget_id = child,
        .parent = @enumFromInt(1),
        .kind = .{ .label = .{ .text = "child" } },
    });
    try tree.nodes.append(gpa, .{
        .id = @enumFromInt(1),
        .widget_id = parent,
        .parent = .root,
        .kind = .{ .label = .{ .text = "parent" } },
    });
    return tree;
}

test "api-w10 aliases and canonical actions decode identical typed payloads" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var initial: Controller = .{};
    var controller = try session.create(Controller, &initial);
    defer session.release(Controller, &controller) catch unreachable;
    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();
    try registry.register(Open);
    try registry.registerAlias("open", "file.open");
    try registry.registerAlias("launch", "open");
    try std.testing.expectError(error.DuplicateAction, registry.register(Open));
    try std.testing.expectError(error.DuplicateAction, registry.registerAlias("open", "file.open"));
    _ = try registry.bind(Open, Controller, Controller.open, null, .app, controller.weak());
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        null,
        "file.open",
        "{\"path\":\"demo.zig\",\"line\":12}",
    ));
    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        null,
        "launch",
        "{\"path\":\"demo.zig\",\"line\":12}",
    ));
    const Check = struct {
        fn run(value: *const Controller, _: void) !void {
            try std.testing.expectEqual(@as(u32, 2), value.calls);
            try std.testing.expectEqual(@as(u32, 12), value.line);
            try std.testing.expectEqualStrings("demo.zig", value.path[0..value.path_len]);
        }
    };
    try session.read(Controller, controller.weak(), {}, Check.run);
    try std.testing.expectEqualStrings("file.open", registry.descriptor("launch").?.name);
    try std.testing.expectEqual(@as(usize, 2), registry.aliases().len);
    const schema = registry.descriptor("launch").?.schema;
    const fields = switch (schema) {
        .object => |items| items,
        else => return error.InvalidSchema,
    };
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("path", fields[0].name);
    try std.testing.expect(fields[0].required);
    switch (fields[0].value) {
        .string => |length| try std.testing.expectEqual(@as(?usize, null), length),
        else => return error.InvalidSchema,
    }
    try std.testing.expectEqualStrings("line", fields[1].name);
    try std.testing.expect(fields[1].required);
    try std.testing.expect(fields[1].value == .integer);
    try std.testing.expectEqual(action.Availability.available, try registry.inspect(
        &tree,
        null,
        "launch",
    ));
}

test "api-w10 invalid parameter JSON, unknown fields, and alias cycles fail" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var initial: Controller = .{};
    var controller = try session.create(Controller, &initial);
    defer session.release(Controller, &controller) catch unreachable;
    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();
    try registry.register(Open);
    try registry.register(Save);
    _ = try registry.bind(Open, Controller, Controller.open, null, .app, controller.weak());
    _ = try registry.bind(Save, Controller, Controller.save, null, .app, controller.weak());
    try registry.registerAlias("first", "second");
    try std.testing.expectError(error.AliasCycle, registry.registerAlias("second", "first"));
    try std.testing.expectError(error.AliasCycle, registry.registerAlias("self", "self"));
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    try std.testing.expectError(error.UnknownAction, registry.dispatch(
        &tree,
        null,
        "first",
        null,
    ));
    const bad = [_][]const u8{
        "{\"path\":\"x\",\"line\":1,\"extra\":true}",
        "{\"path\":\"x\",\"line\":true}",
        "{\"path\":\"x\",\"line\":\"12\"}",
        "{\"path\":\"x\",\"line\":1.0}",
        "{\"path\":\"x\"}",
        "{\"path\":\"x\",\"line\":1} trailing",
        "{\"path\":\"x\",\"line\":1,\"line\":2}",
    };
    for (bad) |payload| {
        try std.testing.expectError(error.InvalidParameters, registry.dispatch(
            &tree,
            null,
            "file.open",
            payload,
        ));
    }
    try std.testing.expectError(error.InvalidParameters, registry.dispatch(
        &tree,
        null,
        "file.open",
        null,
    ));
    try std.testing.expectError(error.InvalidParameters, registry.dispatch(
        &tree,
        null,
        "file.save",
        "{\"ignored\":true}",
    ));
    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        null,
        "file.save",
        null,
    ));
    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        null,
        "file.save",
        " { \n  } ",
    ));
    const Check = struct {
        fn run(value: *const Controller, _: void) !void {
            try std.testing.expectEqual(@as(u32, 2), value.calls);
        }
    };
    try session.read(Controller, controller.weak(), {}, Check.run);
}

test "api-w10 nearest eligible context wins, disabled context blocks fallback" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var initial: Controller = .{};
    var controller = try session.create(Controller, &initial);
    defer session.release(Controller, &controller) catch unreachable;
    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();
    try registry.register(Open);
    const parent: WidgetId = .{ .owner = 1, .slot = 1, .generation = 1 };
    const child: WidgetId = .{ .owner = 1, .slot = 2, .generation = 1 };
    var tree = try makeTree(std.testing.allocator, parent, child);
    defer tree.deinit();
    _ = try registry.bind(Open, Controller, Controller.fromApp, null, .app, controller.weak());
    _ = try registry.bind(Open, Controller, Controller.fromParent, null, .{ .widget = parent }, controller.weak());
    var child_token = try registry.bind(
        Open,
        Controller,
        Controller.fromChild,
        Controller.available,
        .{ .widget = child },
        controller.weak(),
    );
    const payload = "{\"path\":\"x\",\"line\":4}";
    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        child,
        "file.open",
        payload,
    ));
    const Check = struct {
        fn run(value: *const Controller, expected: u8) !void {
            try std.testing.expectEqual(expected, value.source);
        }
    };
    try session.read(Controller, controller.weak(), @as(u8, 3), Check.run);
    const Set = struct {
        fn run(value: *Controller, next: u8) !void {
            value.source = next;
        }
    };
    try session.update(Controller, controller.weak(), @as(u8, 9), Set.run);
    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        child,
        "file.open",
        payload,
    ));
    try session.read(Controller, controller.weak(), @as(u8, 2), Check.run);
    try std.testing.expect(registry.unbind(&child_token));
    _ = try registry.bind(
        Open,
        Controller,
        Controller.fromChild,
        Controller.disabled,
        .{ .widget = child },
        controller.weak(),
    );
    try session.update(Controller, controller.weak(), @as(u8, 8), Set.run);
    try std.testing.expectEqual(action.Result.disabled, try registry.dispatch(
        &tree,
        child,
        "file.open",
        payload,
    ));
    try session.read(Controller, controller.weak(), @as(u8, 8), Check.run);
    try std.testing.expectEqual(action.Availability.disabled, try registry.inspect(
        &tree,
        child,
        "file.open",
    ));
    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        null,
        "file.open",
        payload,
    ));
    try session.read(Controller, controller.weak(), @as(u8, 1), Check.run);
    try session.update(Controller, controller.weak(), @as(u8, 8), Set.run);
    tree.node(@enumFromInt(1)).?.interaction.disabled = true;
    var path = key_context.Path.init(&tree, child);
    try std.testing.expect((@as(key_context.Scope, .app)).eql(path.next().?));
    try std.testing.expect(path.next() == null);
    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        child,
        "file.open",
        payload,
    ));
    try session.read(Controller, controller.weak(), @as(u8, 1), Check.run);
}

test "api-w10 weak-owner listeners release and cancellations prevent delivery" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var initial: Controller = .{};
    var controller = try session.create(Controller, &initial);
    defer session.release(Controller, &controller) catch unreachable;
    var notifications: u32 = 0;
    var watcher_value: Watcher = .{ .observed = &notifications };
    var watcher = try session.create(Watcher, &watcher_value);
    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();
    try registry.register(Open);
    _ = try registry.bind(Open, Controller, Controller.open, null, .app, controller.weak());
    var token = try registry.listen(Open, Watcher, Watcher.onOpen, watcher.weak());
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    const payload = "{\"path\":\"x\",\"line\":7}";
    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        null,
        "file.open",
        payload,
    ));
    const Check = struct {
        fn run(value: *const Watcher, _: void) !void {
            try std.testing.expectEqual(@as(u32, 1), value.calls);
            try std.testing.expectEqual(@as(u32, 7), value.line);
        }
    };
    try session.read(Watcher, watcher.weak(), {}, Check.run);
    try std.testing.expectEqual(@as(u32, 1), notifications);
    try std.testing.expect(registry.unlisten(&token));
    try std.testing.expect(!registry.unlisten(&token));
    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        null,
        "file.open",
        payload,
    ));
    try std.testing.expectEqual(@as(u32, 1), notifications);
    _ = try registry.listen(Open, Watcher, Watcher.onOpen, watcher.weak());
    try session.release(Watcher, &watcher);
    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        null,
        "file.open",
        payload,
    ));
    try std.testing.expectEqual(@as(u32, 1), notifications);
}

test "api-w10 nested JSON rejects unknown fields and preserves optional defaults" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var initial: Controller = .{};
    var controller = try session.create(Controller, &initial);
    defer session.release(Controller, &controller) catch unreachable;
    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();
    try registry.register(Inspect);
    _ = try registry.bind(Inspect, Controller, Controller.inspect, null, .app, controller.weak());
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expectError(error.InvalidParameters, registry.dispatch(
        &tree,
        null,
        "editor.inspect",
        "{\"selection\":{\"start\":2,\"end\":5,\"extra\":0}}",
    ));
    try std.testing.expectError(error.InvalidParameters, registry.dispatch(
        &tree,
        null,
        "editor.inspect",
        "{\"selection\":{\"start\":2,\"end\":5},\"tags\":[42]}",
    ));
    try std.testing.expectEqual(action.Result.handled, try registry.dispatch(
        &tree,
        null,
        "editor.inspect",
        "{\"selection\":{\"start\":2,\"end\":5}}",
    ));
    const Check = struct {
        fn run(value: *const Controller, _: void) !void {
            try std.testing.expectEqual(@as(u32, 1), value.calls);
            try std.testing.expectEqual(@as(u32, 3), value.line);
            try std.testing.expectEqual(@as(usize, 0), value.path_len);
        }
    };
    try session.read(Controller, controller.weak(), {}, Check.run);
}
