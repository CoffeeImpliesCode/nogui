const std = @import("std");
const Session = @import("session.zig").Session;
const Clock = @import("clock.zig").Clock;
const task = @import("task.zig");
const WeakModel = @import("model.zig").WeakModel;

const State = struct { value: u32 = 0 };
const Probe = struct {
    state: WeakModel(State),
    order: *std.ArrayList(u8),
    timeouts: *u32,
    deliveries: u32 = 0,

    fn completed(self: *Probe, payload: *Work, session: *Session) void {
        self.deliveries += 1;
        self.order.append(session.gpa, payload.id) catch @panic("test append failed");
        session.update(State, self.state, payload.result, add) catch @panic("task update failed");
    }

    fn timedOut(self: *Probe, _: *const task.Timeout, _: *Session) void {
        self.timeouts.* += 1;
    }
};

fn add(value: *State, increment: u32) !void {
    value.value += increment;
}
fn readValue(value: *const State, result: *u32) !void {
    result.* = value.value;
}
fn readDeliveries(value: *const Probe, result: *u32) !void {
    result.* = value.deliveries;
}
fn nowTicks(context: *anyopaque) i96 {
    const ticks: *i96 = @ptrCast(@alignCast(context));
    return ticks.*;
}

const Work = struct {
    id: u8,
    input: u32,
    result: u32 = 0,
    gate: ?*std.Io.Event = null,
    entered: ?*std.Io.Event = null,
    drops: *u32,

    fn run(self: *Work, io: std.Io) void {
        if (self.entered) |entered| entered.set(io);
        if (self.gate) |gate| gate.waitUncancelable(io);
        self.result = self.input * 2;
    }

    pub fn deinit(self: *Work, _: *Session) void {
        self.drops.* += 1;
        self.* = undefined;
    }
};

fn setup(session: *Session, ticks: *i96) !void {
    try session.startTasks(Clock.injected(ticks, nowTicks));
}

fn flushUntil(session: *Session, expected: *const std.ArrayList(u8), count: usize) !void {
    for (0..20) |_| {
        _ = try session.drainTasks();
        if (expected.items.len == count) return;
        const snapshot = try session.taskWakeSnapshot();
        _ = try session.waitForTaskWake(snapshot, 50 * std.time.ns_per_ms);
    }
    return error.WorkerDidNotFinish;
}

fn flushDrops(session: *Session, drops: *const u32, count: u32) !void {
    for (0..20) |_| {
        _ = try session.drainTasks();
        if (drops.* == count) return;
        const snapshot = try session.taskWakeSnapshot();
        _ = try session.waitForTaskWake(snapshot, 50 * std.time.ns_per_ms);
    }
    return error.WorkerDidNotFinish;
}

test "api-w05 timer delivers exactly at the injected deadline after frame publication" {
    var io_impl = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_impl.deinit();
    var session = try Session.init(std.testing.allocator);
    var ticks: i96 = 100;
    try setup(&session, &ticks);
    defer session.deinit() catch unreachable;
    var state_value: State = .{};
    var state = try session.create(State, &state_value);
    defer session.release(State, &state) catch unreachable;
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.testing.allocator);
    var timeouts: u32 = 0;
    var probe_value: Probe = .{ .state = state.weak(), .order = &order, .timeouts = &timeouts };
    var probe = try session.create(Probe, &probe_value);
    defer session.release(Probe, &probe) catch unreachable;
    var drops: u32 = 0;
    var work: Work = .{ .id = 3, .input = 6, .result = 12, .drops = &drops };
    var handle = try session.scheduleUi(Work, Probe, Probe.completed, probe.weak(), &work, 105);
    try std.testing.expectEqual(@as(?i96, 105), try session.nextTaskDeadline());
    ticks = 104;
    try std.testing.expectEqual(@as(usize, 0), try session.drainTasks());
    try std.testing.expectEqual(@as(usize, 0), order.items.len);
    const frame_window = try session.registerApp();
    try session.beginFrame(frame_window);
    ticks = 105;
    try std.testing.expectError(error.TransactionInProgress, session.drainTasks());
    try std.testing.expectEqual(@as(usize, 0), order.items.len);
    session.finishFrame(frame_window, true);
    try std.testing.expectEqual(@as(usize, 1), try session.drainTasks());
    try std.testing.expectEqualSlices(u8, &.{3}, order.items);
    var value: u32 = 0;
    try session.read(State, state, &value, readValue);
    try std.testing.expectEqual(@as(u32, 12), value);
    try std.testing.expectEqual(@as(u32, 1), drops);
    try std.testing.expect(!session.cancelTask(&handle));
    session.unregisterApp(frame_window);
    try session.shutdownTasks(0);
}

test "api-w05 early worker result waits for its injected delivery deadline" {
    var io_impl = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_impl.deinit();
    var session = try Session.init(std.testing.allocator);
    var ticks: i96 = 10;
    try setup(&session, &ticks);
    defer session.deinit() catch unreachable;
    var state_value: State = .{};
    var state = try session.create(State, &state_value);
    defer session.release(State, &state) catch unreachable;
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.testing.allocator);
    var timeouts: u32 = 0;
    var probe_value: Probe = .{ .state = state.weak(), .order = &order, .timeouts = &timeouts };
    var owner = try session.create(Probe, &probe_value);
    defer session.release(Probe, &owner) catch unreachable;
    const window = try session.registerApp();
    defer session.unregisterApp(window);
    try session.beginFrame(window);
    try session.readWindow(Probe, window, owner, {}, struct {
        fn read(_: *const Probe, _: void) !void {}
    }.read);
    session.finishFrame(window, true);
    var gate: std.Io.Event = .unset;
    defer gate.set(io_impl.io());
    var entered: std.Io.Event = .unset;
    var drops: u32 = 0;
    var work: Work = .{ .id = 5, .input = 4, .gate = &gate, .entered = &entered, .drops = &drops };
    _ = try session.spawnWorker(Work, Probe, Work.run, Probe.completed, owner.weak(), &work, .{
        .not_before_ns = 15,
    });
    try entered.waitTimeout(io_impl.io(), .{
        .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake },
    });
    const snapshot = try session.taskWakeSnapshot();
    gate.set(io_impl.io());
    try std.testing.expect(try session.waitForTaskWake(snapshot, 500 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(usize, 0), try session.drainTasks());
    try std.testing.expectEqual(@as(?i96, 15), try session.nextTaskDeadline());
    ticks = 14;
    try std.testing.expectEqual(@as(usize, 0), try session.drainTasks());
    ticks = 15;
    try std.testing.expectEqual(@as(usize, 1), try session.drainTasks());
    try std.testing.expectEqualSlices(u8, &.{5}, order.items);
    try std.testing.expectEqual(@as(u32, 1), drops);
    var deliveries: u32 = 0;
    try session.read(Probe, owner, &deliveries, readDeliveries);
    try std.testing.expectEqual(@as(u32, 1), deliveries);
    try std.testing.expect(try session.takeRedraw(window));
    try std.testing.expect(!(try session.takeRedraw(window)));
    try session.shutdownTasks(500 * std.time.ns_per_ms);
}

test "api-w05 worker priority is FIFO within each class; queued cancellation drops once" {
    var io_impl = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_impl.deinit();
    var session = try Session.init(std.testing.allocator);
    var ticks: i96 = 10;
    try setup(&session, &ticks);
    defer session.deinit() catch unreachable;
    var state_value: State = .{};
    var state = try session.create(State, &state_value);
    defer session.release(State, &state) catch unreachable;
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.testing.allocator);
    var timeouts: u32 = 0;
    var probe_value: Probe = .{ .state = state.weak(), .order = &order, .timeouts = &timeouts };
    var probe = try session.create(Probe, &probe_value);
    defer session.release(Probe, &probe) catch unreachable;
    var gate: std.Io.Event = .unset;
    defer gate.set(io_impl.io());
    var entered: std.Io.Event = .unset;
    var drops: u32 = 0;
    var blocker: Work = .{ .id = 0, .input = 1, .gate = &gate, .entered = &entered, .drops = &drops };
    var blocker_handle = try session.spawnWorker(Work, Probe, Work.run, Probe.completed, probe.weak(), &blocker, .{});
    try entered.waitTimeout(io_impl.io(), .{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } });
    var low: Work = .{ .id = 4, .input = 4, .drops = &drops };
    var low_handle = try session.spawnWorker(
        Work,
        Probe,
        Work.run,
        Probe.completed,
        probe.weak(),
        &low,
        .{ .priority = .low },
    );
    var high_a: Work = .{ .id = 1, .input = 1, .drops = &drops };
    var high_a_handle = try session.spawnWorker(
        Work,
        Probe,
        Work.run,
        Probe.completed,
        probe.weak(),
        &high_a,
        .{ .priority = .high },
    );
    try std.testing.expect(session.detachTask(&high_a_handle));
    var high_b: Work = .{ .id = 2, .input = 2, .drops = &drops };
    var high_b_handle = try session.spawnWorker(
        Work,
        Probe,
        Work.run,
        Probe.completed,
        probe.weak(),
        &high_b,
        .{ .priority = .high },
    );
    var cancelled: Work = .{ .id = 9, .input = 9, .drops = &drops };
    var cancelled_handle = try session.spawnWorker(
        Work,
        Probe,
        Work.run,
        Probe.completed,
        probe.weak(),
        &cancelled,
        .{ .priority = .high },
    );
    try std.testing.expect(session.cancelTask(&cancelled_handle));
    _ = try session.drainTasks();
    gate.set(io_impl.io());
    try flushUntil(&session, &order, 4);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 4 }, order.items);
    try std.testing.expectEqual(@as(u32, 5), drops);
    _ = session.detachTask(&blocker_handle);
    _ = session.detachTask(&low_handle);
    _ = session.detachTask(&high_b_handle);
    try session.shutdownTasks(500 * std.time.ns_per_ms);
}

test "api-w05 cancellation while running and stale owner prevent slot-reuse delivery" {
    var io_impl = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_impl.deinit();
    var session = try Session.init(std.testing.allocator);
    var ticks: i96 = 0;
    try setup(&session, &ticks);
    defer session.deinit() catch unreachable;
    var state_value: State = .{};
    var state = try session.create(State, &state_value);
    defer session.release(State, &state) catch unreachable;
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.testing.allocator);
    var timeouts: u32 = 0;
    var probe_value: Probe = .{ .state = state.weak(), .order = &order, .timeouts = &timeouts };
    var owner = try session.create(Probe, &probe_value);
    var gate: std.Io.Event = .unset;
    defer gate.set(io_impl.io());
    var entered: std.Io.Event = .unset;
    var drops: u32 = 0;
    var first: Work = .{ .id = 1, .input = 5, .gate = &gate, .entered = &entered, .drops = &drops };
    var handle = try session.spawnWorker(Work, Probe, Work.run, Probe.completed, owner.weak(), &first, .{});
    try entered.waitTimeout(io_impl.io(), .{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } });
    try std.testing.expect(session.cancelTask(&handle));
    var second: Work = .{ .id = 2, .input = 7, .drops = &drops };
    _ = try session.spawnWorker(Work, Probe, Work.run, Probe.completed, owner.weak(), &second, .{});
    try session.release(Probe, &owner);
    var replacement_value: Probe = .{ .state = state.weak(), .order = &order, .timeouts = &timeouts };
    var replacement = try session.create(Probe, &replacement_value);
    defer session.release(Probe, &replacement) catch unreachable;
    gate.set(io_impl.io());
    try flushDrops(&session, &drops, 2);
    try session.shutdownTasks(500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 0), order.items.len);
    try std.testing.expectEqual(@as(u32, 2), drops);
}

test "api-w05 timeout is delivered on UI while worker owns its buffer; shutdown can retry" {
    var io_impl = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_impl.deinit();
    var session = try Session.init(std.testing.allocator);
    var ticks: i96 = 100;
    try setup(&session, &ticks);
    defer session.deinit() catch unreachable;
    var state_value: State = .{};
    var state = try session.create(State, &state_value);
    defer session.release(State, &state) catch unreachable;
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.testing.allocator);
    var timeouts: u32 = 0;
    var probe_value: Probe = .{ .state = state.weak(), .order = &order, .timeouts = &timeouts };
    var owner = try session.create(Probe, &probe_value);
    defer session.release(Probe, &owner) catch unreachable;
    var gate: std.Io.Event = .unset;
    defer gate.set(io_impl.io());
    var entered: std.Io.Event = .unset;
    var drops: u32 = 0;
    var work: Work = .{ .id = 7, .input = 1, .gate = &gate, .entered = &entered, .drops = &drops };
    _ = try session.spawnWorker(Work, Probe, Work.run, Probe.completed, owner.weak(), &work, .{
        .timeout_ns = 110,
        .on_timeout = Probe.timedOut,
    });
    try entered.waitTimeout(io_impl.io(), .{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } });
    ticks = 109;
    _ = try session.drainTasks();
    try std.testing.expectEqual(@as(u32, 0), timeouts);
    ticks = 110;
    _ = try session.drainTasks();
    try std.testing.expectEqual(@as(u32, 1), timeouts);
    try std.testing.expectEqual(@as(u32, 0), drops);
    try std.testing.expectError(error.UnfinishedWork, session.shutdownTasks(0));
    try std.testing.expectError(error.UnfinishedWork, session.deinit());
    gate.set(io_impl.io());
    try session.shutdownTasks(500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 1), drops);
    try std.testing.expectEqual(@as(usize, 0), order.items.len);
}

test "api-w05 completion between snapshot and sleep wakes host and unregister fences callback" {
    var io_impl = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_impl.deinit();
    var session = try Session.init(std.testing.allocator);
    var ticks: i96 = 0;
    try setup(&session, &ticks);
    defer session.deinit() catch unreachable;
    var state_value: State = .{};
    var state = try session.create(State, &state_value);
    defer session.release(State, &state) catch unreachable;
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.testing.allocator);
    var timeouts: u32 = 0;
    var probe_value: Probe = .{ .state = state.weak(), .order = &order, .timeouts = &timeouts };
    var owner = try session.create(Probe, &probe_value);
    defer session.release(Probe, &owner) catch unreachable;
    var calls = std.atomic.Value(u32).init(0);
    const Wake = struct {
        fn notify(context: *anyopaque) void {
            const count: *std.atomic.Value(u32) = @ptrCast(@alignCast(context));
            _ = count.fetchAdd(1, .seq_cst);
        }
    };
    try session.setTaskWake(&calls, Wake.notify);
    var gate: std.Io.Event = .unset;
    defer gate.set(io_impl.io());
    var entered: std.Io.Event = .unset;
    var drops: u32 = 0;
    var work: Work = .{ .id = 8, .input = 3, .gate = &gate, .entered = &entered, .drops = &drops };
    _ = try session.spawnWorker(Work, Probe, Work.run, Probe.completed, owner.weak(), &work, .{});
    try entered.waitTimeout(io_impl.io(), .{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } });
    const snapshot = try session.taskWakeSnapshot();
    gate.set(io_impl.io());
    try std.testing.expect(try session.waitForTaskWake(snapshot, 500 * std.time.ns_per_ms));
    try flushUntil(&session, &order, 1);
    const before = calls.load(.seq_cst);
    try std.testing.expect(before > 0);
    try session.setTaskWake(null, null);
    var timer: Work = .{ .id = 9, .input = 1, .result = 2, .drops = &drops };
    _ = try session.scheduleUi(Work, Probe, Probe.completed, owner.weak(), &timer, 1);
    _ = try session.drainTasks();
    try std.testing.expectEqual(before, calls.load(.seq_cst));
    try session.shutdownTasks(500 * std.time.ns_per_ms);
}

test "api-w05 closing a window suppresses its worker result without retiring the model" {
    var io_impl = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_impl.deinit();
    var session = try Session.init(std.testing.allocator);
    var ticks: i96 = 0;
    try setup(&session, &ticks);
    defer session.deinit() catch unreachable;
    var state_value: State = .{};
    var state = try session.create(State, &state_value);
    defer session.release(State, &state) catch unreachable;
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.testing.allocator);
    var timeouts: u32 = 0;
    var probe_value: Probe = .{ .state = state.weak(), .order = &order, .timeouts = &timeouts };
    var owner = try session.create(Probe, &probe_value);
    defer session.release(Probe, &owner) catch unreachable;
    const previous_window = try session.registerApp();
    var gate: std.Io.Event = .unset;
    defer gate.set(io_impl.io());
    var entered: std.Io.Event = .unset;
    var drops: u32 = 0;
    var work: Work = .{
        .id = 6,
        .input = 6,
        .gate = &gate,
        .entered = &entered,
        .drops = &drops,
    };
    _ = try session.spawnWorker(Work, Probe, Work.run, Probe.completed, owner.weak(), &work, .{
        .window = previous_window,
    });
    try entered.waitTimeout(io_impl.io(), .{
        .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake },
    });
    session.unregisterApp(previous_window);
    const replacement_window = try session.registerApp();
    defer session.unregisterApp(replacement_window);
    const snapshot = try session.taskWakeSnapshot();
    gate.set(io_impl.io());
    try std.testing.expect(try session.waitForTaskWake(snapshot, 500 * std.time.ns_per_ms));
    _ = try session.drainTasks();
    try std.testing.expectEqual(@as(usize, 0), order.items.len);
    try std.testing.expectEqual(@as(u32, 1), drops);
    try session.shutdownTasks(500 * std.time.ns_per_ms);
}

test "api-w07 borrowed window close rejects new tasks and drops completed work" {
    var session = try Session.init(std.testing.allocator);
    var ticks: i96 = 0;
    try session.startTasksDeterministic(Clock.injected(&ticks, nowTicks));
    defer session.deinit() catch unreachable;
    var state_value: State = .{};
    var state = try session.create(State, &state_value);
    defer session.release(State, &state) catch unreachable;
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.testing.allocator);
    var timeouts: u32 = 0;
    var probe_value: Probe = .{ .state = state.weak(), .order = &order, .timeouts = &timeouts };
    var owner = try session.create(Probe, &probe_value);
    defer session.release(Probe, &owner) catch unreachable;
    const window = try session.registerApp();
    defer session.unregisterApp(window);
    var drops: u32 = 0;
    var work: Work = .{ .id = 4, .input = 7, .drops = &drops };
    _ = try session.spawnWorker(Work, Probe, Work.run, Probe.completed, owner.weak(), &work, .{
        .window = window,
    });
    try session.retireWindow(window);
    try std.testing.expect(!session.hasWindow(window));
    try std.testing.expectError(error.UnknownWindow, session.beginFrame(window));
    try std.testing.expectError(error.UnknownWindow, session.requestRedraw(window));
    try std.testing.expectError(error.UnknownWindow, session.takeRedraw(window));
    var rejected: Work = .{ .id = 5, .input = 5, .drops = &drops };
    try std.testing.expectError(error.UnknownWindow, session.spawnWorker(
        Work,
        Probe,
        Work.run,
        Probe.completed,
        owner.weak(),
        &rejected,
        .{ .window = window },
    ));
    try std.testing.expect((try session.stepDeterministicWorker()) != null);
    try std.testing.expectEqual(@as(usize, 0), try session.drainTasks());
    try std.testing.expectEqual(@as(usize, 0), order.items.len);
    try std.testing.expectEqual(@as(u32, 1), drops);
    try session.shutdownTasks(0);
}
