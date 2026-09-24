const std = @import("std");
const Session = @import("session.zig").Session;
const Model = @import("model.zig").Model;
const WeakModel = @import("model.zig").WeakModel;
const ModelKey = @import("model.zig").ModelKey;
const GpuEndpoint = @import("runtime.zig").GpuEndpoint;
const Clock = @import("clock.zig").Clock;
const noapi = @import("noapi");

const Count = struct {
    value: u32,
};

fn readCount(value: *const Count, out: *u32) !void {
    out.* = value.value;
}

test "api-w03 exact model types and store ownership" {
    var first = try Session.init(std.testing.allocator);
    defer first.deinit() catch unreachable;
    var second = try Session.init(std.testing.allocator);
    defer second.deinit() catch unreachable;

    var value: Count = .{ .value = 19 };
    var owner = try first.create(Count, &value);
    var erased = owner.erase();
    try std.testing.expectError(error.WrongType, first.cast(u32, &erased));
    owner = try first.cast(Count, &erased);
    defer first.release(Count, &owner) catch unreachable;

    var observed: u32 = 0;
    try std.testing.expectError(error.WrongStore, second.read(Count, owner, &observed, readCount));
    try first.read(Count, owner, &observed, readCount);
    try std.testing.expectEqual(@as(u32, 19), observed);
}

test "api-w03 copied strong tickets do not duplicate ownership" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var value: Count = .{ .value = 8 };
    var first = try session.create(Count, &value);
    var bit_copy = first;
    var second = try session.retain(Count, first);
    const weak = second.weak();

    try session.release(Count, &first);
    try std.testing.expectError(error.AlreadyReleased, session.release(Count, &bit_copy));
    var observed: u32 = 0;
    try session.read(Count, second, &observed, readCount);
    try std.testing.expectEqual(@as(u32, 8), observed);
    try session.release(Count, &second);
    try std.testing.expect((try session.upgrade(Count, weak)) == null);
}

const Linked = struct {
    next: ?WeakModel(@This()) = null,
};

fn readLinked(value: *const Linked, _: void) !void {
    try std.testing.expect(value.next != null);
}

test "api-w03 reservations permit weak cycles without observing uninitialized values" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var left = try session.reserve(Linked);
    var right = try session.reserve(Linked);
    const left_weak = left.weak();
    const right_weak = right.weak();

    try std.testing.expectError(error.UninitializedModel, session.read(Linked, left_weak, {}, readLinked));
    try std.testing.expectError(error.UninitializedModel, session.upgrade(Linked, right_weak));
    var left_value: Linked = .{ .next = right_weak };
    var right_value: Linked = .{ .next = left_weak };
    var left_owner = try session.insert(Linked, &left, &left_value);
    var right_owner = try session.insert(Linked, &right, &right_value);
    try session.read(Linked, left_owner, {}, readLinked);
    try session.read(Linked, right_owner, {}, readLinked);
    try session.release(Linked, &left_owner);
    try session.release(Linked, &right_owner);
    try std.testing.expect((try session.upgrade(Linked, left_weak)) == null);
}

const Reentry = struct {
    session: *Session,
    handle: Model(Count),
};

fn blockedUpdate(value: *Count, _: void) !void {
    value.value += 1;
}

fn verifyConflict(value: *Count, reentry: *Reentry) !void {
    try std.testing.expectError(
        error.ConflictingAccess,
        reentry.session.update(Count, reentry.handle, {}, blockedUpdate),
    );
    var observed: u32 = 0;
    try std.testing.expectError(
        error.ConflictingAccess,
        reentry.session.read(Count, reentry.handle, &observed, readCount),
    );
    value.value += 1;
}

test "api-w03 scoped borrows reject reentrant mutation and release on return" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var value: Count = .{ .value = 3 };
    var owner = try session.create(Count, &value);
    defer session.release(Count, &owner) catch unreachable;
    var reentry: Reentry = .{ .session = &session, .handle = owner };
    try session.update(Count, owner, &reentry, verifyConflict);
    var observed: u32 = 0;
    try session.read(Count, owner, &observed, readCount);
    try std.testing.expectEqual(@as(u32, 4), observed);
}

const App = @import("app.zig").App;
const DrawCtx = @import("drawctx.zig").DrawCtx;
const Size = @import("widget.zig").Size;

const CountView = struct {
    label: []const u8,

    pub fn draw(self: *CountView, count: *const Count, ctx: *DrawCtx) !void {
        const text = try std.fmt.allocPrint(ctx.arena, "{s}: {d}", .{ self.label, count.value });
        _ = try ctx.label(.{ .text = text });
    }
};

fn addCount(count: *Count, delta: u32) !void {
    count.value += delta;
}

test "api-w03 one model drives independent App views across updates" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var count: Count = .{ .value = 5 };
    var shared = try session.create(Count, &count);
    defer session.release(Count, &shared) catch unreachable;

    var left = try App.init(std.testing.allocator, &session);
    defer left.deinit();
    var right = try App.init(std.testing.allocator, &session);
    defer right.deinit();
    var left_view: CountView = .{ .label = "left" };
    var right_view: CountView = .{ .label = "right" };
    try left.mountModelRoot(Count, CountView, shared, &left_view);
    try right.mountModelRoot(Count, CountView, shared, &right_view);

    const surface: Size = .{ .width = 320, .height = 120 };
    const left_before = try left.frame(1, surface);
    const right_before = try right.frame(1, surface);
    try std.testing.expectEqualStrings("left: 5", left_before.tree.nodes.items[0].kind.label.text);
    try std.testing.expectEqualStrings("right: 5", right_before.tree.nodes.items[0].kind.label.text);

    try session.update(Count, shared, @as(u32, 3), addCount);
    const left_after = try left.frame(2, surface);
    const right_after = try right.frame(2, surface);
    try std.testing.expectEqualStrings("left: 8", left_after.tree.nodes.items[0].kind.label.text);
    try std.testing.expectEqualStrings("right: 8", right_after.tree.nodes.items[0].kind.label.text);
}

const Destroyed = struct {
    count: *u32,

    pub fn deinit(self: *Destroyed, _: *Session) void {
        self.count.* += 1;
        self.* = undefined;
    }
};

test "api-w03 Session shutdown refuses owners and destroys once after release" {
    var session = try Session.init(std.testing.allocator);
    var calls: u32 = 0;
    var value: Destroyed = .{ .count = &calls };
    var owner = try session.create(Destroyed, &value);
    var retained = try session.retain(Destroyed, owner);
    try std.testing.expectError(error.LiveModels, session.deinit());
    try session.release(Destroyed, &owner);
    try std.testing.expectEqual(@as(u32, 0), calls);
    try session.release(Destroyed, &retained);
    try std.testing.expectEqual(@as(u32, 1), calls);
    try session.deinit();
}

fn readModelKey(value: *const ModelKey, out: *ModelKey) !void {
    out.* = value.*;
}

test "api-w03 moving an aliased reservation value keeps the owner identity" {
    var session = try Session.init(std.testing.allocator);
    var pending = try session.reserve(ModelKey);
    const expected = pending.key;
    var owner = try session.insert(ModelKey, &pending, &pending.key);
    try std.testing.expectEqual(expected, owner.key);
    var observed: ModelKey = .{};
    try session.read(ModelKey, owner, &observed, readModelKey);
    try std.testing.expectEqual(expected, observed);
    try session.release(ModelKey, &owner);
    try session.deinit();
}

const ReentrantDrop = struct {
    owner: *Model(ReentrantDrop),
    spawn: bool,

    pub fn deinit(self: *ReentrantDrop, session: *Session) void {
        if (self.spawn) {
            var replacement: ReentrantDrop = .{ .owner = self.owner, .spawn = false };
            self.owner.* = session.create(ReentrantDrop, &replacement) catch @panic("replacement allocation failed");
        }
        self.* = undefined;
    }
};

test "api-w03 reentrant destruction preserves a replacement owner" {
    var session = try Session.init(std.testing.allocator);
    var owner: Model(ReentrantDrop) = .{};
    var value: ReentrantDrop = .{ .owner = &owner, .spawn = true };
    owner = try session.create(ReentrantDrop, &value);
    try session.release(ReentrantDrop, &owner);
    try std.testing.expect(owner.ticket != 0);
    try session.release(ReentrantDrop, &owner);
    try session.deinit();
}

test "api-w03 replaceRoot rejects a missing root" {
    const View = struct {
        const Self = @This();
        pub fn draw(_: *Self, _: *DrawCtx) !void {}
    };
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var view: View = .{};
    try std.testing.expectError(error.RootNotMounted, app.replaceRoot(View, &view));

    var count: Count = .{ .value = 1 };
    var owner = try session.create(Count, &count);
    defer session.release(Count, &owner) catch unreachable;
    var model_view: CountView = .{ .label = "new" };
    try std.testing.expectError(
        error.RootNotMounted,
        app.replaceModelRoot(Count, CountView, owner, &model_view),
    );
}

const ReplaceWhileRead = struct {
    app: *App,
    owner: Model(Count),
    candidate: *CountView,
};

fn rejectModelReplacement(_: *const Count, request: *ReplaceWhileRead) !void {
    try std.testing.expectError(
        error.ConflictingAccess,
        request.app.replaceModelRoot(Count, CountView, request.owner, request.candidate),
    );
}

test "api-w03 replacing a borrowed model returns a conflict without losing its root" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var count: Count = .{ .value = 2 };
    var owner = try session.create(Count, &count);
    defer session.release(Count, &owner) catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var current: CountView = .{ .label = "old" };
    var candidate: CountView = .{ .label = "new" };
    try app.mountModelRoot(Count, CountView, owner, &current);
    const first = try app.frame(1, .{ .width = 320, .height = 120 });
    var request: ReplaceWhileRead = .{ .app = &app, .owner = owner, .candidate = &candidate };
    try session.read(Count, owner, &request, rejectModelReplacement);
    try std.testing.expect(app.tree_ptr == first.tree);
    const second = try app.frame(2, .{ .width = 320, .height = 120 });
    try std.testing.expectEqualStrings("old: 2", second.tree.nodes.items[0].kind.label.text);
}

const AliasChild = struct {
    starts: *u32,
    stops: *u32,

    pub fn draw(_: *AliasChild, _: *DrawCtx) !void {}

    pub fn initGpu(self: *AliasChild, _: *GpuEndpoint) !void {
        self.starts.* += 1;
    }

    pub fn deinitGpu(self: *AliasChild, _: *GpuEndpoint) void {
        self.stops.* += 1;
    }
};

const AliasParent = struct {
    child: AliasChild,

    pub fn draw(self: *AliasParent, ctx: *DrawCtx) !void {
        try ctx.component(AliasChild, .{ .key = .{ .static = "child" } }, &self.child);
    }
};

fn noGpuWait() void {}

test "api-w03 replacing root with mounted child rejects duplicate GPU ownership" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var starts: u32 = 0;
    var stops: u32 = 0;
    var parent: AliasParent = .{ .child = .{ .starts = &starts, .stops = &stops } };
    try app.mountRoot(AliasParent, &parent);
    var gpu: noapi.Gpu = undefined;
    var endpoint: GpuEndpoint = .{
        .gpu = &gpu,
        .retirement_wait_for_test = noGpuWait,
    };
    try app.attachGpu(&endpoint);
    const first = try app.frame(1, .{ .width = 120, .height = 100 });
    try std.testing.expectEqual(@as(u32, 1), starts);
    try std.testing.expectError(
        error.ComponentAlreadyMounted,
        app.replaceRoot(AliasChild, &parent.child),
    );
    try std.testing.expectEqual(@as(u32, 1), starts);
    try std.testing.expectEqual(@as(u32, 0), stops);
    try std.testing.expect(app.tree_ptr == first.tree);
}

// --- Typed-model access contract ------------------------------------------
//
// `Model(T)` and `Reservation(T)` are distinct Zig types, so a reservation is
// rejected at comptime wherever a handle is required. At runtime each of the
// four bad-access classes carries its own error, an uninitialised reservation
// is invisible, and a scoped borrow never outlives its callback.

const Tagged = struct {
    value: u32,
};

const Other = struct {
    value: u32,
};

fn readTagged(value: *const Tagged, out: *u32) !void {
    out.* = value.value;
}

fn bumpTagged(value: *Tagged, delta: u32) !void {
    value.value += delta;
}

const Access = struct {
    session: *Session,
    tagged: Model(Tagged),
    observed: u32 = 0,
};

const Conflicting = struct {
    access: *Access,

    fn write(value: *Tagged, self: *Conflicting) !void {
        // This callback holds the only writer borrow on the slot, so a second
        // write, a read of the same slot and a release all conflict.
        try std.testing.expectError(
            error.ConflictingAccess,
            self.access.session.update(Tagged, self.access.tagged, @as(u32, 1), bumpTagged),
        );
        try std.testing.expectError(
            error.ConflictingAccess,
            self.access.session.read(Tagged, self.access.tagged, &self.access.observed, readTagged),
        );
        var doomed = self.access.tagged;
        try std.testing.expectError(
            error.ConflictingAccess,
            self.access.session.release(Tagged, &doomed),
        );
        // The refused release consumed nothing.
        try std.testing.expect(doomed.ticket != 0);
        value.value += 1;
    }
};

test "api-w03 wrong store, wrong type and conflicting mutation fail distinctly" {
    var home = try Session.init(std.testing.allocator);
    defer home.deinit() catch unreachable;
    var away = try Session.init(std.testing.allocator);
    defer away.deinit() catch unreachable;

    var tagged_value: Tagged = .{ .value = 5 };
    var other_value: Other = .{ .value = 6 };
    var tagged = try home.create(Tagged, &tagged_value);
    defer home.release(Tagged, &tagged) catch unreachable;
    var other = try home.create(Other, &other_value);
    defer home.release(Other, &other) catch unreachable;

    var access: Access = .{ .session = &home, .tagged = tagged };

    // Wrong store: the ticket is live, this Session is not the one that made it.
    try std.testing.expectError(
        error.WrongStore,
        away.read(Tagged, access.tagged, &access.observed, readTagged),
    );
    try std.testing.expectError(
        error.WrongStore,
        away.update(Tagged, access.tagged, @as(u32, 1), bumpTagged),
    );
    try std.testing.expectError(
        error.WrongStore,
        away.read(Tagged, access.tagged.weak(), &access.observed, readTagged),
    );
    try std.testing.expectError(error.WrongStore, away.retain(Tagged, access.tagged));

    // Wrong type: the ticket is live here, but its slot holds `Tagged`. Only an
    // erased handle can name the wrong type; both strengths refuse it, and the
    // refusal consumes no ticket.
    var erased = access.tagged.erase();
    try std.testing.expectError(error.WrongType, home.cast(Other, &erased));
    try std.testing.expectError(
        error.WrongType,
        home.castWeak(Other, access.tagged.weak().erase()),
    );
    try std.testing.expect(erased.ticket != 0);
    access.tagged = try home.cast(Tagged, &erased);

    // Conflicting mutable access: one open writer borrow on one slot.
    var conflicting: Conflicting = .{ .access = &access };
    try home.update(Tagged, access.tagged, &conflicting, Conflicting.write);
    try home.read(Tagged, access.tagged, &access.observed, readTagged);
    try std.testing.expectEqual(@as(u32, 6), access.observed);

    // No class may collapse onto another class's error.
    try std.testing.expect(!std.mem.eql(
        u8,
        @errorName(error.WrongStore),
        @errorName(error.WrongType),
    ));
    try std.testing.expect(!std.mem.eql(
        u8,
        @errorName(error.WrongStore),
        @errorName(error.ConflictingAccess),
    ));
    try std.testing.expect(!std.mem.eql(
        u8,
        @errorName(error.StaleModel),
        @errorName(error.ConflictingAccess),
    ));
}

test "api-w03 a stale generation never resolves to a recycled slot" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;

    var first_value: Tagged = .{ .value = 4 };
    var first = try session.create(Tagged, &first_value);
    const stale = first.weak();
    const recycled_slot = stale.key.slot;
    const stale_generation = stale.key.generation;
    try session.release(Tagged, &first);

    var second_value: Other = .{ .value = 8 };
    var second = try session.create(Other, &second_value);
    // The store hands the same slot index back with a fresh generation.
    try std.testing.expectEqual(recycled_slot, second.key.slot);
    try std.testing.expect(stale_generation != second.key.generation);

    var observed: u32 = 0;
    try std.testing.expectError(
        error.StaleModel,
        session.read(Tagged, stale, &observed, readTagged),
    );
    try std.testing.expectError(
        error.StaleModel,
        session.update(Tagged, stale, @as(u32, 1), bumpTagged),
    );
    try std.testing.expectError(error.StaleModel, session.castWeak(Tagged, stale.erase()));
    try std.testing.expect((try session.upgrade(Tagged, stale)) == null);
    // Not one stale access read a byte of the replacement model.
    try std.testing.expectEqual(@as(u32, 0), observed);

    try session.release(Other, &second);
}

test "api-w03 a weak handle upgrades while a ticket remains and never after the last" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;

    var value: Tagged = .{ .value = 1 };
    var owner = try session.create(Tagged, &value);
    const weak = owner.weak();

    var first_extra = (try session.upgrade(Tagged, weak)).?;
    try session.release(Tagged, &owner);
    // One ticket is still outstanding, so the weak identity resolves.
    var second_extra = (try session.upgrade(Tagged, weak)).?;
    try session.release(Tagged, &first_extra);
    try session.release(Tagged, &second_extra);

    try std.testing.expect((try session.upgrade(Tagged, weak)) == null);
    var observed: u32 = 0;
    try std.testing.expectError(
        error.StaleModel,
        session.read(Tagged, weak, &observed, readTagged),
    );
}

fn clearLinked(value: *Linked, _: void) !void {
    value.next = null;
}

fn ignoreLinked(_: *const Linked, _: WeakModel(Linked), _: *Session) void {}

fn ignoreLinkedEffect(_: *const Linked, _: *Linked, _: *Session) void {}

test "api-w03 a reservation stays unreadable until insert publishes it" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;

    var pending = try session.reserve(Linked);
    const weak = pending.weak();

    try std.testing.expectError(
        error.UninitializedModel,
        session.read(Linked, weak, {}, readLinked),
    );
    try std.testing.expectError(error.UninitializedModel, session.update(Linked, weak, {}, clearLinked));
    try std.testing.expectError(error.UninitializedModel, session.upgrade(Linked, weak));
    try std.testing.expectError(
        error.UninitializedModel,
        session.observe(Linked, Linked, weak, weak, ignoreLinked),
    );
    var effect: Linked = .{};
    try std.testing.expectError(
        error.UninitializedModel,
        session.deferOwned(Linked, Linked, weak, &effect, ignoreLinkedEffect),
    );
    // Every refused entry point moved no storage out of the caller's value.
    try std.testing.expect(effect.next == null);

    var value: Linked = .{ .next = weak };
    var owner = try session.insert(Linked, &pending, &value);
    defer session.release(Linked, &owner) catch unreachable;
    try session.read(Linked, owner, {}, readLinked);
    var upgraded = (try session.upgrade(Linked, weak)).?;
    try session.release(Linked, &upgraded);
}

const DeferredEffect = struct {
    session: *Session,
    owner: Model(Tagged),
    queued: *bool,
    seen: *u32,

    fn deliver(_: *const Tagged, payload: *DeferredEffect, _: *Session) void {
        payload.session.read(Tagged, payload.owner, payload.seen, readTagged) catch |err|
            std.debug.panic("the deferred read refused in this fixture: {s}", .{@errorName(err)});
        payload.queued.* = true;
    }
};

const WritesThenDefers = struct {
    effect: *DeferredEffect,

    fn write(value: *Tagged, self: *WritesThenDefers) !void {
        value.value += 10;
        self.effect.queued.* = false;
        var payload: DeferredEffect = .{
            .session = self.effect.session,
            .owner = self.effect.owner,
            .queued = self.effect.queued,
            .seen = self.effect.seen,
        };
        try self.effect.session.deferOwned(
            DeferredEffect,
            Tagged,
            self.effect.owner.weak(),
            &payload,
            DeferredEffect.deliver,
        );
        // The effect holds a copied payload, not this borrow: it stays queued.
        try std.testing.expect(!(self.effect.queued.*));
    }
};

test "api-w03 a scoped borrow cannot escape into a deferred effect or a frame" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;

    var value: Tagged = .{ .value = 4 };
    var owner = try session.create(Tagged, &value);
    defer session.release(Tagged, &owner) catch unreachable;

    var queued = false;
    var seen: u32 = 0;
    var effect: DeferredEffect = .{ .session = &session, .owner = owner, .queued = &queued, .seen = &seen };
    var writer: WritesThenDefers = .{ .effect = &effect };
    try session.update(Tagged, owner, &writer, WritesThenDefers.write);

    // Delivery waited for the write borrow to end, then took its own borrow
    // and observed the committed value.
    try std.testing.expect(queued);
    try std.testing.expectEqual(@as(u32, 14), seen);

    const window = try session.registerApp();
    defer session.unregisterApp(window);
    try session.beginFrame(window);
    var observed: u32 = 0;
    try session.readWindow(Tagged, window, owner, &observed, readTagged);
    try std.testing.expectEqual(@as(u32, 14), observed);
    try std.testing.expectError(
        error.DrawMutationForbidden,
        session.update(Tagged, owner, @as(u32, 1), bumpTagged),
    );
    session.finishFrame(window, true);

    // The frame borrow closed with the frame.
    try session.update(Tagged, owner, @as(u32, 1), bumpTagged);
    try session.read(Tagged, owner, &observed, readTagged);
    try std.testing.expectEqual(@as(u32, 15), observed);
}

const FrozenClock = struct {
    context: u32 = 0,

    fn now(_: *anyopaque) i96 {
        return 0;
    }
};

const TaskNote = struct {
    delivered: *u32,
};

fn noteTagged(_: *Tagged, note: *TaskNote, _: *Session) void {
    note.delivered.* += 1;
}

fn noteOther(_: *Other, note: *TaskNote, _: *Session) void {
    note.delivered.* += 1;
}

test "api-w03 a task completion runs only while its weak owner is live" {
    var session = try Session.init(std.testing.allocator);
    var clock: FrozenClock = .{};
    try session.startTasksDeterministic(Clock.injected(&clock.context, FrozenClock.now));
    defer session.deinit() catch unreachable;

    var live_value: Other = .{ .value = 2 };
    var live = try session.create(Other, &live_value);
    var live_delivered: u32 = 0;
    var live_note: TaskNote = .{ .delivered = &live_delivered };
    _ = try session.scheduleUi(TaskNote, Other, noteOther, live.weak(), &live_note, 0);

    var gone_value: Tagged = .{ .value = 1 };
    var gone = try session.create(Tagged, &gone_value);
    var gone_delivered: u32 = 0;
    var gone_note: TaskNote = .{ .delivered = &gone_delivered };
    _ = try session.scheduleUi(TaskNote, Tagged, noteTagged, gone.weak(), &gone_note, 0);
    try session.release(Tagged, &gone);

    _ = try session.drainTasks();
    // The released owner's completion was dropped, never run against storage
    // the drain had already freed; the live one ran exactly once.
    try std.testing.expectEqual(@as(u32, 1), live_delivered);
    try std.testing.expectEqual(@as(u32, 0), gone_delivered);

    try session.release(Other, &live);
}
