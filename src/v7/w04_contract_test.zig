const std = @import("std");
const Session = @import("session.zig").Session;
const Context = @import("context.zig").Context;
const Token = @import("subscription.zig").Token;
const model = @import("model.zig");
const Size = @import("widget.zig").Size;

const Count = struct { value: u32 = 0 };
const Event = struct {
    number: u8,
    bytes: []u8,
    drops: *u32,

    pub fn deinit(self: *Event, session: *Session) void {
        session.gpa.free(self.bytes);
        self.drops.* += 1;
        self.* = undefined;
    }
};
const Recorder = struct {
    values: *std.ArrayList(u8),
    token: *Token,
    drop_self: bool = false,

    fn onEvent(self: *const Recorder, event: *const Event, session: *Session) void {
        self.values.append(session.gpa, event.number) catch @panic("test append failed");
        if (self.drop_self and !session.unsubscribe(self.token)) @panic("subscription already cancelled");
    }
};

fn emitOwned(session: *Session, source: model.WeakModel(Count), number: u8, drops: *u32) !void {
    const bytes = try session.gpa.dupe(u8, "owned");
    errdefer session.gpa.free(bytes);
    var event: Event = .{ .number = number, .bytes = bytes, .drops = drops };
    try session.emit(Event, Count, source, &event);
}

const Nested = struct {
    session: *Session,
    source: model.WeakModel(Count),
    drops: *u32,
    other: model.WeakModel(Count),
    fn inner(value: *Count, self: *Nested) !void {
        value.value += 1;
        try emitOwned(self.session, self.source, 2, self.drops);
    }
    fn outer(value: *Count, self: *Nested) !void {
        value.value += 1;
        try emitOwned(self.session, self.source, 1, self.drops);
        // A different model is mutated while the outer borrow is held.
        try self.session.update(Count, self.other, self, inner);
        try emitOwned(self.session, self.source, 3, self.drops);
    }
};

test "api-w04 nested updates deliver each owned event FIFO after the outer borrow" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var source_value: Count = .{};
    var source = try session.create(Count, &source_value);
    defer session.release(Count, &source) catch unreachable;
    var other_value: Count = .{};
    var other = try session.create(Count, &other_value);
    defer session.release(Count, &other) catch unreachable;
    var values: std.ArrayList(u8) = .empty;
    defer values.deinit(std.testing.allocator);
    var token: Token = .{};
    var recorder_value: Recorder = .{ .values = &values, .token = &token };
    var recorder = try session.create(Recorder, &recorder_value);
    defer session.release(Recorder, &recorder) catch unreachable;
    token = try session.subscribe(Event, Count, Recorder, source.weak(), recorder.weak(), Recorder.onEvent);
    var drops: u32 = 0;
    var nested: Nested = .{ .session = &session, .source = source.weak(), .other = other.weak(), .drops = &drops };
    try session.update(Count, source, &nested, Nested.outer);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, values.items);
    try std.testing.expectEqual(@as(u32, 3), drops);
}

test "api-w04 self unsubscribe and owner retirement stop later delivery" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var value: Count = .{};
    var source = try session.create(Count, &value);
    defer session.release(Count, &source) catch unreachable;
    var values: std.ArrayList(u8) = .empty;
    defer values.deinit(std.testing.allocator);
    var token: Token = .{};
    var recorder_value: Recorder = .{ .values = &values, .token = &token, .drop_self = true };
    var recorder = try session.create(Recorder, &recorder_value);
    token = try session.subscribe(Event, Count, Recorder, source.weak(), recorder.weak(), Recorder.onEvent);
    var drops: u32 = 0;
    try emitOwned(&session, source.weak(), 7, &drops);
    try emitOwned(&session, source.weak(), 8, &drops);
    try std.testing.expectEqualSlices(u8, &.{7}, values.items);
    try session.release(Recorder, &recorder);
    try std.testing.expect(!session.unsubscribe(&token));
    try std.testing.expectEqual(@as(u32, 2), drops);
}

const WindowState = struct { dirty: u8 = 0 };
fn readCount(value: *const Count, output: *u32) !void {
    output.* = value.value;
}
fn bumpCount(value: *Count, _: void) !void {
    value.value += 1;
}
fn bumpGlobal(value: *WindowState, _: void) !void {
    value.dirty += 1;
}

test "api-w04 committed window dependencies coalesce while aborted reads remain private" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    const left = try session.registerApp();
    defer session.unregisterApp(left);
    const right = try session.registerApp();
    defer session.unregisterApp(right);
    var count_value: Count = .{};
    var count = try session.create(Count, &count_value);
    defer session.release(Count, &count) catch unreachable;
    var initial: WindowState = .{};
    try session.putGlobal(WindowState, &initial);
    defer session.removeGlobal(WindowState) catch unreachable;
    var left_ctx: Context = .{ .session = &session, .window = left };
    var right_ctx: Context = .{ .session = &session, .window = right };
    var observed: u32 = 99;
    try session.beginFrame(left);
    try left_ctx.read(Count, count, &observed, readCount);
    try left_ctx.global(WindowState, {}, struct {
        fn read(_: *const WindowState, _: void) !void {}
    }.read);
    session.finishFrame(left, true);
    try session.beginFrame(right);
    try right_ctx.read(Count, count, &observed, readCount);
    session.finishFrame(right, false);
    try session.update(Count, count, {}, bumpCount);
    try session.update(Count, count, {}, bumpCount);
    try session.updateGlobal(WindowState, {}, bumpGlobal);
    try std.testing.expect(try session.takeRedraw(left));
    try std.testing.expect(!(try session.takeRedraw(left)));
    try std.testing.expect(!(try session.takeRedraw(right)));
    try session.beginFrame(right);
    try right_ctx.read(Count, count, &observed, readCount);
    session.finishFrame(right, true);
    try session.update(Count, count, {}, bumpCount);
    try std.testing.expect(try session.takeRedraw(right));
}

const ReleaseProbe = struct {
    released: *u32,
    fn releasedModel(self: *const ReleaseProbe, dead: model.WeakModel(Count), session: *Session) void {
        std.debug.assert((session.upgrade(Count, dead) catch @panic("invalid release subject")) == null);
        self.released.* += 1;
    }
};

test "api-w04 release observers see dead identity once and shutdown clears per-Session state" {
    var session = try Session.init(std.testing.allocator);
    var count_value: Count = .{};
    var count = try session.create(Count, &count_value);
    var calls: u32 = 0;
    var observer_value: ReleaseProbe = .{ .released = &calls };
    var observer = try session.create(ReleaseProbe, &observer_value);
    var token = try session.observeRelease(
        Count,
        ReleaseProbe,
        count.weak(),
        observer.weak(),
        ReleaseProbe.releasedModel,
    );
    try session.release(Count, &count);
    try std.testing.expectEqual(@as(u32, 1), calls);
    try std.testing.expect(!session.unsubscribe(&token));
    try session.release(ReleaseProbe, &observer);
    try session.deinit();
}

const Reactive = struct {
    events: *std.ArrayList(u8),
    source: model.WeakModel(Count),
    drops: *u32,
    chain: bool,
    fn receive(self: *const Reactive, event: *const Event, session: *Session) void {
        self.events.append(session.gpa, event.number) catch @panic("test append failed");
        if (self.chain and event.number == 1) {
            emitOwned(session, self.source, 2, self.drops) catch @panic("nested emit failed");
        }
    }
};

test "api-w04 an event emitted during delivery follows all listeners for its predecessor" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var source_value: Count = .{};
    var source = try session.create(Count, &source_value);
    defer session.release(Count, &source) catch unreachable;
    var events: std.ArrayList(u8) = .empty;
    defer events.deinit(std.testing.allocator);
    var drops: u32 = 0;
    var first_value: Reactive = .{
        .events = &events,
        .source = source.weak(),
        .drops = &drops,
        .chain = true,
    };
    var first = try session.create(Reactive, &first_value);
    defer session.release(Reactive, &first) catch unreachable;
    var second_value: Reactive = .{
        .events = &events,
        .source = source.weak(),
        .drops = &drops,
        .chain = false,
    };
    var second = try session.create(Reactive, &second_value);
    defer session.release(Reactive, &second) catch unreachable;
    _ = try session.subscribe(Event, Count, Reactive, source.weak(), first.weak(), Reactive.receive);
    _ = try session.subscribe(Event, Count, Reactive, source.weak(), second.weak(), Reactive.receive);
    try emitOwned(&session, source.weak(), 1, &drops);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 2, 2 }, events.items);
    try std.testing.expectEqual(@as(u32, 2), drops);
}

const DeferProbe = struct {
    calls: *u32,
    fn run(self: *const DeferProbe, payload: *DeferredValue, _: *Session) void {
        std.debug.assert(payload.number == 17);
        self.calls.* += 1;
    }
};
const DeferredValue = struct {
    number: u8,
    drops: *u32,
    pub fn deinit(self: *DeferredValue, _: *Session) void {
        self.drops.* += 1;
        self.* = undefined;
    }
};
const DeferredUpdate = struct {
    session: *Session,
    weak_owner: *model.Model(DeferProbe),
    strong_owner: *model.Model(DeferProbe),
    drops: *u32,
    fn schedule(_: *Count, self: *DeferredUpdate) !void {
        var weak_payload: DeferredValue = .{ .number = 17, .drops = self.drops };
        try self.session.deferOwned(DeferredValue, DeferProbe, self.weak_owner.weak(), &weak_payload, DeferProbe.run);
        var strong_payload: DeferredValue = .{ .number = 17, .drops = self.drops };
        try self.session.deferRetained(DeferredValue, DeferProbe, self.strong_owner.*, &strong_payload, DeferProbe.run);
        try self.session.release(DeferProbe, self.weak_owner);
        try self.session.release(DeferProbe, self.strong_owner);
    }
};

test "api-w04 weak deferred work drops after owner release while retained work runs once" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var value: Count = .{};
    var source = try session.create(Count, &value);
    defer session.release(Count, &source) catch unreachable;
    var weak_calls: u32 = 0;
    var strong_calls: u32 = 0;
    var weak_value: DeferProbe = .{ .calls = &weak_calls };
    var weak = try session.create(DeferProbe, &weak_value);
    var strong_value: DeferProbe = .{ .calls = &strong_calls };
    var strong = try session.create(DeferProbe, &strong_value);
    var drops: u32 = 0;
    var scenario: DeferredUpdate = .{
        .session = &session,
        .weak_owner = &weak,
        .strong_owner = &strong,
        .drops = &drops,
    };
    try session.update(Count, source, &scenario, DeferredUpdate.schedule);
    try std.testing.expectEqual(@as(u32, 0), weak_calls);
    try std.testing.expectEqual(@as(u32, 1), strong_calls);
    try std.testing.expectEqual(@as(u32, 2), drops);
}

const GlobalProbe = struct {
    notifications: *u32,
    last: *u8,
    fn changed(self: *const GlobalProbe, global: *const WindowState, session: *Session) void {
        std.testing.expectError(
            error.ConflictingAccess,
            session.updateGlobal(WindowState, {}, bumpGlobal),
        ) catch @panic("global write escaped borrow");
        std.testing.expectError(
            error.ConflictingAccess,
            session.removeGlobal(WindowState),
        ) catch @panic("global release escaped borrow");
        self.notifications.* += 1;
        self.last.* = global.dirty;
    }
};

test "api-w04 rejected borrow emits nothing and global update observes committed state" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    const window = try session.registerApp();
    defer session.unregisterApp(window);
    var count_value: Count = .{};
    var count = try session.create(Count, &count_value);
    defer session.release(Count, &count) catch unreachable;
    var initial: WindowState = .{};
    try session.putGlobal(WindowState, &initial);
    defer session.removeGlobal(WindowState) catch unreachable;
    var notifications: u32 = 0;
    var last: u8 = 0;
    var listener_value: GlobalProbe = .{ .notifications = &notifications, .last = &last };
    var listener = try session.create(GlobalProbe, &listener_value);
    defer session.release(GlobalProbe, &listener) catch unreachable;
    _ = try session.observeGlobal(WindowState, GlobalProbe, listener.weak(), GlobalProbe.changed);
    const ctx: Context = .{ .session = &session, .window = window };
    try session.beginFrame(window);
    try ctx.global(WindowState, {}, struct {
        fn read(_: *const WindowState, _: void) !void {}
    }.read);
    session.finishFrame(window, true);
    const Blocked = struct {
        const Self = @This();
        session: *Session,
        count: model.Model(Count),
        fn read(_: *const Count, self: *Self) !void {
            try std.testing.expectError(error.ConflictingAccess, self.session.update(Count, self.count, {}, bumpCount));
        }
    };
    var blocked: Blocked = .{ .session = &session, .count = count };
    try session.read(Count, count, &blocked, Blocked.read);
    try std.testing.expect(!(try session.takeRedraw(window)));
    try session.updateGlobal(WindowState, {}, bumpGlobal);
    try std.testing.expectEqual(@as(u32, 1), notifications);
    try std.testing.expectEqual(@as(u8, 1), last);
    try std.testing.expect(try session.takeRedraw(window));
}

test "api-w04 failed frame re-arms consumed demand without publishing candidate reads" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    const window = try session.registerApp();
    defer session.unregisterApp(window);
    var first_value: Count = .{};
    var first = try session.create(Count, &first_value);
    defer session.release(Count, &first) catch unreachable;
    var second_value: Count = .{};
    var second = try session.create(Count, &second_value);
    defer session.release(Count, &second) catch unreachable;
    const ctx: Context = .{ .session = &session, .window = window };
    var observed: u32 = 0;
    try session.beginFrame(window);
    try ctx.read(Count, first, &observed, readCount);
    session.finishFrame(window, true);
    try session.update(Count, first, {}, bumpCount);
    try std.testing.expect(try session.takeRedraw(window));
    try session.beginFrame(window);
    try ctx.read(Count, second, &observed, readCount);
    try std.testing.expectError(error.DrawMutationForbidden, session.update(Count, second, {}, bumpCount));
    session.finishFrame(window, false);
    try std.testing.expect(try session.takeRedraw(window));
    try session.beginFrame(window);
    try ctx.read(Count, first, &observed, readCount);
    session.finishFrame(window, true);
    try session.update(Count, second, {}, bumpCount);
    try std.testing.expect(!(try session.takeRedraw(window)));
    try session.clearWindowDependencies(window);
    try session.update(Count, first, {}, bumpCount);
    try std.testing.expect(!(try session.takeRedraw(window)));
    try session.requestRedraw(window);
    try std.testing.expect(try session.takeRedraw(window));
}

const ChangedObserver = struct {
    id: u8,
    order: *std.ArrayList(u8),
    fn changed(self: *const ChangedObserver, _: model.WeakModel(Count), session: *Session) void {
        self.order.append(session.gpa, self.id) catch @panic("test append failed");
    }
};
const TwoUpdates = struct {
    session: *Session,
    second: model.WeakModel(Count),
    fn outer(value: *Count, self: *TwoUpdates) !void {
        value.value += 1;
        try self.session.update(Count, self.second, {}, bumpCount);
    }
};

test "api-w04 model observations follow nested update admission order and errors retain writes" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var first_value: Count = .{};
    var first = try session.create(Count, &first_value);
    defer session.release(Count, &first) catch unreachable;
    var second_value: Count = .{};
    var second = try session.create(Count, &second_value);
    defer session.release(Count, &second) catch unreachable;
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.testing.allocator);
    var first_observer_value: ChangedObserver = .{ .id = 1, .order = &order };
    var first_observer = try session.create(ChangedObserver, &first_observer_value);
    defer session.release(ChangedObserver, &first_observer) catch unreachable;
    var second_observer_value: ChangedObserver = .{ .id = 2, .order = &order };
    var second_observer = try session.create(ChangedObserver, &second_observer_value);
    defer session.release(ChangedObserver, &second_observer) catch unreachable;
    _ = try session.observe(Count, ChangedObserver, first.weak(), first_observer.weak(), ChangedObserver.changed);
    _ = try session.observe(Count, ChangedObserver, second.weak(), second_observer.weak(), ChangedObserver.changed);
    var nested: TwoUpdates = .{ .session = &session, .second = second.weak() };
    try session.update(Count, first, &nested, TwoUpdates.outer);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, order.items);
    const ErrorUpdate = struct {
        fn change(value: *Count, _: void) error{Updated}!void {
            value.value += 1;
            return error.Updated;
        }
    };
    try std.testing.expectError(error.Updated, session.update(Count, first, {}, ErrorUpdate.change));
    var observed: u32 = 0;
    try session.read(Count, first, &observed, readCount);
    try std.testing.expectEqual(@as(u32, 2), observed);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 1 }, order.items);
}

test "api-w04 tokens belong to one Session and owner shutdown cannot leak listeners" {
    var first = try Session.init(std.testing.allocator);
    var second = try Session.init(std.testing.allocator);
    defer second.deinit() catch unreachable;
    var source_value: Count = .{};
    var source = try first.create(Count, &source_value);
    var events: std.ArrayList(u8) = .empty;
    defer events.deinit(std.testing.allocator);
    var token: Token = .{};
    var recorder_value: Recorder = .{ .values = &events, .token = &token };
    var owner = try first.create(Recorder, &recorder_value);
    token = try first.subscribe(Event, Count, Recorder, source.weak(), owner.weak(), Recorder.onEvent);
    try std.testing.expect(!second.unsubscribe(&token));
    var drops: u32 = 0;
    try first.release(Recorder, &owner);
    try emitOwned(&first, source.weak(), 9, &drops);
    try std.testing.expectEqual(@as(u32, 1), drops);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
    try first.release(Count, &source);
    try first.deinit();
}

const RetireOther = struct {
    victim: *model.Model(Recorder),
    calls: *u32,
    fn receive(self: *const RetireOther, _: *const Event, session: *Session) void {
        self.calls.* += 1;
        session.release(Recorder, self.victim) catch @panic("victim release failed");
    }
};

test "api-w04 owner release within dispatch skips the later listener safely" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var source_value: Count = .{};
    var source = try session.create(Count, &source_value);
    defer session.release(Count, &source) catch unreachable;
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(std.testing.allocator);
    var victim_token: Token = .{};
    var victim_value: Recorder = .{ .values = &received, .token = &victim_token };
    var victim = try session.create(Recorder, &victim_value);
    var calls: u32 = 0;
    var killer_value: RetireOther = .{ .victim = &victim, .calls = &calls };
    var killer = try session.create(RetireOther, &killer_value);
    defer session.release(RetireOther, &killer) catch unreachable;
    _ = try session.subscribe(Event, Count, RetireOther, source.weak(), killer.weak(), RetireOther.receive);
    victim_token = try session.subscribe(Event, Count, Recorder, source.weak(), victim.weak(), Recorder.onEvent);
    var drops: u32 = 0;
    try emitOwned(&session, source.weak(), 4, &drops);
    try std.testing.expectEqual(@as(u32, 1), calls);
    try std.testing.expectEqual(@as(usize, 0), received.items.len);
    try std.testing.expectEqual(@as(u32, 1), drops);
}

test "api-w04 nested tracked reads invalidate both committed dependencies" {
    const Probe = struct {
        const Self = @This();
        context: *const Context,
        second: model.WeakModel(Count),
        first_value: u32 = 0,
        second_value: u32 = 0,

        fn outer(value: *const Count, self: *Self) !void {
            self.first_value = value.value;
            try self.context.read(Count, self.second, &self.second_value, readCount);
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    const window = try session.registerApp();
    defer session.unregisterApp(window);
    var first_value: Count = .{ .value = 5 };
    var first = try session.create(Count, &first_value);
    defer session.release(Count, &first) catch unreachable;
    var second_value: Count = .{ .value = 7 };
    var second = try session.create(Count, &second_value);
    defer session.release(Count, &second) catch unreachable;
    const context: Context = .{ .session = &session, .window = window };
    var probe: Probe = .{ .context = &context, .second = second.weak() };

    try session.beginFrame(window);
    try context.read(Count, first, &probe, Probe.outer);
    session.finishFrame(window, true);
    try std.testing.expectEqual(@as(u32, 5), probe.first_value);
    try std.testing.expectEqual(@as(u32, 7), probe.second_value);
    try session.update(Count, first, {}, bumpCount);
    try std.testing.expect(try session.takeRedraw(window));
    try session.beginFrame(window);
    try context.read(Count, first, &probe, Probe.outer);
    session.finishFrame(window, true);
    try session.update(Count, second, {}, bumpCount);
    try std.testing.expect(try session.takeRedraw(window));
}

test "api-w04 two App views coalesce a self-unsubscribing deferred model update" {
    const App = @import("app.zig").App;
    const DrawCtx = @import("drawctx.zig").DrawCtx;
    const View = struct {
        const Self = @This();
        label: []const u8,

        pub fn draw(self: *Self, _: *const Count, ctx: *DrawCtx) !void {
            const context = ctx.context orelse return error.MissingContext;
            const source = try context.root(Count);
            var number: u32 = 0;
            try context.read(Count, source, &number, readCount);
            const text = try std.fmt.allocPrint(ctx.arena, "{s}: {d}", .{ self.label, number });
            _ = try ctx.label(.{ .text = text });
        }
    };
    const Request = struct { source: model.WeakModel(Count) };
    const Probe = struct {
        const Self = @This();
        // An unbound probe has no owner yet; the empty key is a valid weak
        // model and `bind` replaces it before any callback can read it.
        owner: model.WeakModel(Self) = .{},
        source: model.WeakModel(Count),
        token: *Token,
        calls: *u32,

        fn bind(self: *Self, owner: model.WeakModel(Self)) !void {
            self.owner = owner;
        }
        fn changed(self: *const Self, _: model.WeakModel(Count), session: *Session) void {
            self.calls.* += 1;
            std.debug.assert(session.unsubscribe(self.token));
            var request: Request = .{ .source = self.source };
            session.deferOwned(Request, Self, self.owner, &request, apply) catch
                @panic("deferred model update admission failed");
        }
        fn apply(_: *const Self, request: *Request, session: *Session) void {
            session.update(Count, request.source, {}, bumpCount) catch
                @panic("deferred model update failed");
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var initial: Count = .{};
    var source = try session.create(Count, &initial);
    defer session.release(Count, &source) catch unreachable;
    var left = try App.init(std.testing.allocator, &session);
    defer left.deinit();
    var right = try App.init(std.testing.allocator, &session);
    defer right.deinit();
    var left_view: View = .{ .label = "left" };
    var right_view: View = .{ .label = "right" };
    try left.mountModelRoot(Count, View, source, &left_view);
    try right.mountModelRoot(Count, View, source, &right_view);
    try std.testing.expect(try session.takeRedraw(left.window));
    try std.testing.expect(try session.takeRedraw(right.window));
    const surface: Size = .{ .width = 320, .height = 120 };
    const left_before = try left.frame(1, surface);
    const right_before = try right.frame(1, surface);
    try std.testing.expectEqualStrings("left: 0", left_before.tree.nodes.items[0].kind.label.text);
    try std.testing.expectEqualStrings("right: 0", right_before.tree.nodes.items[0].kind.label.text);

    var token: Token = .{};
    var calls: u32 = 0;
    var observer_value: Probe = .{ .source = source.weak(), .token = &token, .calls = &calls };
    var observer = try session.create(Probe, &observer_value);
    defer session.release(Probe, &observer) catch unreachable;
    try session.update(Probe, observer, observer.weak(), Probe.bind);
    token = try session.observe(Count, Probe, source.weak(), observer.weak(), Probe.changed);

    try session.update(Count, source, {}, bumpCount);
    try std.testing.expectEqual(@as(u32, 1), calls);
    try std.testing.expect(try session.takeRedraw(left.window));
    try std.testing.expect(!(try session.takeRedraw(left.window)));
    try std.testing.expect(try session.takeRedraw(right.window));
    try std.testing.expect(!(try session.takeRedraw(right.window)));
    const left_after = try left.frame(2, surface);
    const right_after = try right.frame(2, surface);
    try std.testing.expectEqualStrings("left: 2", left_after.tree.nodes.items[0].kind.label.text);
    try std.testing.expectEqualStrings("right: 2", right_after.tree.nodes.items[0].kind.label.text);
}
