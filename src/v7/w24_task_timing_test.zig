//! Behavior tests for the W24 task timing observer. Each test drives the real
//! task service through a Session and checks what an inspector sink can learn:
//! one queue fact per scheduled task, one completion fact per task whose work
//! ended, ordered timestamps from the virtual clock, a real nonzero span from
//! the production clock, and no allocation or fact while the observer is off.
const std = @import("std");
const Session = @import("session.zig").Session;
const Clock = @import("clock.zig").Clock;
const task = @import("task.zig");

const fact_capacity = 8;
const event_capacity = 4 * fact_capacity;

const Work = struct {
    input: u32 = 0,
    result: u32 = 0,
    /// Virtual-clock runs advance the injected clock inside the work, so a
    /// completion span is nonzero without any real waiting.
    ticks: ?*i96 = null,
    advance_ns: i96 = 0,
    /// Production-clock runs sleep, so the measured span is real elapsed time.
    sleep_ns: i96 = 0,
    /// The service owns a payload after enqueue, so anything the test reads
    /// later must live outside the moved value.
    run_thread: ?*std.Thread.Id = null,

    fn run(self: *Work, io: std.Io) void {
        if (self.run_thread) |slot| slot.* = std.Thread.getCurrentId();
        if (self.sleep_ns != 0) {
            std.Io.sleep(io, .fromNanoseconds(self.sleep_ns), .real) catch |err| switch (err) {
                // Shutdown may cancel the wait; the span is measured anyway.
                error.Canceled => {},
            };
        }
        if (self.ticks) |ticks| ticks.* += self.advance_ns;
        self.result = self.input * 2;
    }
};

/// Counts live in the test frame for the same reason: a model takes its value
/// at create time.
const Probe = struct {
    deliveries: *u32,
    last_result: *u32,
    timeouts: *u32,

    fn completed(self: *Probe, payload: *Work, _: *Session) void {
        self.deliveries.* += 1;
        self.last_result.* = payload.result;
    }

    fn timedOut(self: *Probe, _: *const task.Timeout, _: *Session) void {
        self.timeouts.* += 1;
    }
};

/// Fixed-storage sink. An observer must not allocate, so neither does its
/// test-side storage.
const Sink = struct {
    // SAFETY: only entries before queued_count are read.
    queued: [fact_capacity]task.QueuedTask = undefined,
    // SAFETY: only entries before finished_count are read.
    finished: [fact_capacity]task.FinishedTask = undefined,
    queued_count: usize = 0,
    finished_count: usize = 0,
    /// Thread that ran each callback, in callback order.
    // SAFETY: only entries before event_count are read.
    threads: [event_capacity]std.Thread.Id = undefined,
    event_count: usize = 0,
    /// Set only when no worker thread exists: another thread holding the
    /// Service lock would make the probe meaningless.
    service: ?*task.Service = null,
    unlocked: bool = true,
    overflow: bool = false,

    fn observer(self: *Sink) task.Observer {
        return .{ .user = self, .on_queued = onQueued, .on_finished = onFinished };
    }

    fn onQueued(context: *anyopaque, fact: task.QueuedTask) void {
        const self: *Sink = @ptrCast(@alignCast(context));
        if (self.queued_count < fact_capacity) {
            self.queued[self.queued_count] = fact;
            self.queued_count += 1;
        } else self.overflow = true;
        self.note();
    }

    fn onFinished(context: *anyopaque, fact: task.FinishedTask) void {
        const self: *Sink = @ptrCast(@alignCast(context));
        if (self.finished_count < fact_capacity) {
            self.finished[self.finished_count] = fact;
            self.finished_count += 1;
        } else self.overflow = true;
        self.note();
    }

    /// Record the calling thread and prove the Service lock is free. A
    /// regression that ran the sink under the lock fails the probe instead of
    /// deadlocking.
    fn note(self: *Sink) void {
        if (self.event_count < event_capacity) {
            self.threads[self.event_count] = std.Thread.getCurrentId();
            self.event_count += 1;
        } else self.overflow = true;
        const service = self.service orelse return;
        if (service.mutex.tryLock()) {
            service.mutex.unlock(service.io);
            self.unlocked = true;
        } else self.unlocked = false;
    }
};

/// Counts served allocations without changing the allocation itself.
const CountingAllocator = struct {
    inner: std.mem.Allocator,
    allocs: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.allocs += 1;
        return self.inner.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        return self.inner.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.inner.rawFree(memory, alignment, ret_addr);
    }
};

fn nowTicks(context: *anyopaque) i96 {
    const ticks: *i96 = @ptrCast(@alignCast(context));
    return ticks.*;
}

fn serviceOf(session: *Session) !*task.Service {
    return session.task_service orelse error.TasksNotStarted;
}

fn drainUntil(session: *Session, deliveries: *const u32, count: u32) !void {
    for (0..50) |_| {
        _ = try session.drainTasks();
        if (deliveries.* == count) return;
        const snapshot = try session.taskWakeSnapshot();
        _ = try session.waitForTaskWake(snapshot, 50 * std.time.ns_per_ms);
    }
    return error.WorkerDidNotFinish;
}

test "api-w24 deterministic worker publishes one ordered queue and completion fact per task" {
    const gpa = std.testing.allocator;
    var io_impl = std.Io.Threaded.init(gpa, .{});
    defer io_impl.deinit();
    var session = try Session.init(gpa);
    defer session.deinit() catch unreachable;
    var ticks: i96 = 1_000;
    try session.startTasksDeterministic(Clock.injected(&ticks, nowTicks));
    const service = try serviceOf(&session);
    var sink: Sink = .{ .service = service };
    service.setObserver(sink.observer());

    var deliveries: u32 = 0;
    var last_result: u32 = 0;
    var timeouts: u32 = 0;
    var probe_value: Probe = .{
        .deliveries = &deliveries,
        .last_result = &last_result,
        .timeouts = &timeouts,
    };
    var probe = try session.create(Probe, &probe_value);
    defer session.release(Probe, &probe) catch unreachable;
    const window = try session.registerApp();
    defer session.unregisterApp(window);

    var run_thread: std.Thread.Id = 0;
    var first: Work = .{ .input = 3, .ticks = &ticks, .advance_ns = 40, .run_thread = &run_thread };
    const first_handle = try session.spawnWorker(Work, Probe, Work.run, Probe.completed, probe.weak(), &first, .{
        .priority = .high,
        .window = window,
    });
    try std.testing.expectEqual(@as(usize, 1), sink.queued_count);
    try std.testing.expectEqual(@as(usize, 0), sink.finished_count);
    try std.testing.expectEqual(first_handle.id, sink.queued[0].id);
    try std.testing.expectEqual(task.Priority.high, sink.queued[0].priority);
    try std.testing.expectEqual(@as(u64, 1_000), sink.queued[0].queued_ns);
    try std.testing.expectEqualStrings(@typeName(Work), sink.queued[0].name);
    try std.testing.expectEqual(@as(?u64, window), sink.queued[0].window);

    // The worker stamps its run, but only the UI thread publishes the fact.
    ticks = 1_200;
    try std.testing.expectEqual(first_handle.id, try session.stepDeterministicWorker());
    try std.testing.expectEqual(@as(usize, 0), sink.finished_count);
    try std.testing.expectEqual(@as(usize, 1), try session.drainTasks());
    try std.testing.expectEqual(@as(usize, 1), sink.finished_count);
    try std.testing.expectEqual(first_handle.id, sink.finished[0].id);
    try std.testing.expectEqual(task.Priority.high, sink.finished[0].priority);
    try std.testing.expectEqual(@as(u64, 1_000), sink.finished[0].queued_ns);
    try std.testing.expectEqual(@as(u64, 1_200), sink.finished[0].start_ns);
    try std.testing.expectEqual(@as(u64, 1_240), sink.finished[0].end_ns);
    try std.testing.expectEqual(@as(?u64, window), sink.finished[0].window);
    try std.testing.expect(sink.finished[0].start_ns >= sink.finished[0].queued_ns);
    try std.testing.expect(sink.finished[0].end_ns >= sink.finished[0].start_ns);

    // A supplied static name replaces the payload type name.
    var second: Work = .{ .input = 4, .ticks = &ticks, .advance_ns = 5 };
    _ = try session.spawnWorker(Work, Probe, Work.run, Probe.completed, probe.weak(), &second, .{
        .name = "index-rebuild",
    });
    try std.testing.expectEqual(@as(usize, 2), sink.queued_count);
    try std.testing.expectEqualStrings("index-rebuild", sink.queued[1].name);
    try std.testing.expectEqual(@as(?u64, null), sink.queued[1].window);
    try std.testing.expect(sink.queued[1].id > sink.queued[0].id);
    ticks = 2_100;
    _ = try session.stepDeterministicWorker();
    try std.testing.expectEqual(@as(usize, 1), try session.drainTasks());
    try std.testing.expectEqual(@as(usize, 2), sink.finished_count);
    try std.testing.expectEqual(sink.queued[1].id, sink.finished[1].id);
    try std.testing.expectEqual(@as(u64, 1_240), sink.finished[1].queued_ns);
    try std.testing.expectEqual(@as(u64, 2_100), sink.finished[1].start_ns);
    try std.testing.expectEqual(@as(u64, 2_105), sink.finished[1].end_ns);

    // Every callback ran on this thread with the Service lock free.
    try std.testing.expect(!sink.overflow);
    try std.testing.expect(sink.unlocked);
    const ui_thread = std.Thread.getCurrentId();
    for (sink.threads[0..sink.event_count]) |thread| {
        try std.testing.expectEqual(ui_thread, thread);
    }
    try std.testing.expectEqual(ui_thread, run_thread);
    try std.testing.expectEqual(@as(u32, 2), deliveries);
    try std.testing.expectEqual(@as(u32, 8), last_result);
    service.setObserver(null);
    try session.shutdownTasks(0);
}

test "api-w24 a UI timer reports its delivery instant as start and end" {
    const gpa = std.testing.allocator;
    var io_impl = std.Io.Threaded.init(gpa, .{});
    defer io_impl.deinit();
    var session = try Session.init(gpa);
    defer session.deinit() catch unreachable;
    var ticks: i96 = 500;
    try session.startTasksDeterministic(Clock.injected(&ticks, nowTicks));
    const service = try serviceOf(&session);
    var sink: Sink = .{ .service = service };
    service.setObserver(sink.observer());

    var deliveries: u32 = 0;
    var last_result: u32 = 0;
    var timeouts: u32 = 0;
    var probe_value: Probe = .{
        .deliveries = &deliveries,
        .last_result = &last_result,
        .timeouts = &timeouts,
    };
    var probe = try session.create(Probe, &probe_value);
    defer session.release(Probe, &probe) catch unreachable;

    var timer: Work = .{ .input = 5 };
    const handle = try session.scheduleUi(Work, Probe, Probe.completed, probe.weak(), &timer, 700);
    try std.testing.expectEqual(@as(usize, 1), sink.queued_count);
    try std.testing.expectEqual(@as(u64, 500), sink.queued[0].queued_ns);
    try std.testing.expectEqual(task.Priority.normal, sink.queued[0].priority);

    ticks = 699;
    try std.testing.expectEqual(@as(usize, 0), try session.drainTasks());
    try std.testing.expectEqual(@as(usize, 0), sink.finished_count);
    ticks = 700;
    try std.testing.expectEqual(@as(usize, 1), try session.drainTasks());
    try std.testing.expectEqual(@as(usize, 1), sink.finished_count);
    try std.testing.expectEqual(handle.id, sink.finished[0].id);
    try std.testing.expectEqual(@as(u64, 700), sink.finished[0].start_ns);
    try std.testing.expectEqual(@as(u64, 700), sink.finished[0].end_ns);
    try std.testing.expectEqual(@as(u64, 500), sink.finished[0].queued_ns);
    try std.testing.expectEqualStrings(@typeName(Work), sink.finished[0].name);
    try std.testing.expect(sink.unlocked);
    try std.testing.expectEqual(@as(u32, 1), deliveries);
    service.setObserver(null);
    try session.shutdownTasks(0);
}

test "api-w24 cancelled and timed-out jobs report one zero-duration completion fact" {
    const gpa = std.testing.allocator;
    var io_impl = std.Io.Threaded.init(gpa, .{});
    defer io_impl.deinit();
    var session = try Session.init(gpa);
    defer session.deinit() catch unreachable;
    var ticks: i96 = 100;
    try session.startTasksDeterministic(Clock.injected(&ticks, nowTicks));
    const service = try serviceOf(&session);
    var sink: Sink = .{ .service = service };
    service.setObserver(sink.observer());

    var deliveries: u32 = 0;
    var last_result: u32 = 0;
    var timeouts: u32 = 0;
    var probe_value: Probe = .{
        .deliveries = &deliveries,
        .last_result = &last_result,
        .timeouts = &timeouts,
    };
    var probe = try session.create(Probe, &probe_value);
    defer session.release(Probe, &probe) catch unreachable;

    // Cancelled before the step: the work never runs, so the cancel instant,
    // not the queue instant, is both the start and the end.
    var doomed: Work = .{ .input = 9, .ticks = &ticks, .advance_ns = 1_000 };
    var doomed_handle = try session.spawnWorker(Work, Probe, Work.run, Probe.completed, probe.weak(), &doomed, .{});
    try std.testing.expectEqual(@as(u64, 100), sink.queued[0].queued_ns);
    ticks = 150;
    try std.testing.expect(session.cancelTask(&doomed_handle));
    _ = try session.drainTasks();
    try std.testing.expectEqual(@as(usize, 1), sink.finished_count);
    try std.testing.expectEqual(sink.queued[0].id, sink.finished[0].id);
    try std.testing.expectEqual(@as(u64, 100), sink.finished[0].queued_ns);
    try std.testing.expectEqual(@as(u64, 150), sink.finished[0].start_ns);
    try std.testing.expectEqual(@as(u64, 150), sink.finished[0].end_ns);

    // Timed out while queued: the timeout instant ends the run that never
    // started, and the UI still hears the timeout exactly once.
    var stale: Work = .{ .input = 8, .ticks = &ticks, .advance_ns = 1_000 };
    _ = try session.spawnWorker(Work, Probe, Work.run, Probe.completed, probe.weak(), &stale, .{
        .timeout_ns = 250,
        .on_timeout = Probe.timedOut,
    });
    ticks = 249;
    _ = try session.drainTasks();
    try std.testing.expectEqual(@as(usize, 1), sink.finished_count);
    try std.testing.expectEqual(@as(u32, 0), timeouts);
    ticks = 260;
    _ = try session.drainTasks();
    try std.testing.expectEqual(@as(u32, 1), timeouts);
    try std.testing.expectEqual(@as(usize, 2), sink.finished_count);
    try std.testing.expectEqual(@as(u64, 150), sink.finished[1].queued_ns);
    try std.testing.expectEqual(@as(u64, 260), sink.finished[1].start_ns);
    try std.testing.expectEqual(@as(u64, 260), sink.finished[1].end_ns);
    try std.testing.expect(sink.finished[1].id > sink.finished[0].id);

    // One pass emitted each fact once, and neither payload ever ran.
    _ = try session.drainTasks();
    try std.testing.expectEqual(@as(usize, 2), sink.finished_count);
    try std.testing.expectEqual(@as(u32, 0), deliveries);
    try std.testing.expectEqual(@as(i96, 260), ticks);
    try std.testing.expect(sink.unlocked);
    service.setObserver(null);
    try session.shutdownTasks(0);
}

test "api-w24 the production clock measures a real span on the UI thread" {
    const gpa = std.testing.allocator;
    var io_impl = std.Io.Threaded.init(gpa, .{});
    defer io_impl.deinit();
    var session = try Session.init(gpa);
    defer session.deinit() catch unreachable;
    try session.startTasksOwned();
    const service = try serviceOf(&session);
    // A worker thread may hold the Service lock, so this sink records only
    // which thread ran the callbacks.
    var sink: Sink = .{};
    service.setObserver(sink.observer());

    var deliveries: u32 = 0;
    var last_result: u32 = 0;
    var timeouts: u32 = 0;
    var probe_value: Probe = .{
        .deliveries = &deliveries,
        .last_result = &last_result,
        .timeouts = &timeouts,
    };
    var probe = try session.create(Probe, &probe_value);
    defer session.release(Probe, &probe) catch unreachable;

    const ui_thread = std.Thread.getCurrentId();
    var run_thread: std.Thread.Id = 0;
    var work: Work = .{ .input = 6, .sleep_ns = 2 * std.time.ns_per_ms, .run_thread = &run_thread };
    _ = try session.spawnWorker(Work, Probe, Work.run, Probe.completed, probe.weak(), &work, .{});
    try drainUntil(&session, &deliveries, 1);

    try std.testing.expectEqual(@as(usize, 1), sink.queued_count);
    try std.testing.expectEqual(@as(usize, 1), sink.finished_count);
    try std.testing.expect(sink.queued[0].id == sink.finished[0].id);
    try std.testing.expectEqual(ui_thread, sink.threads[0]);
    try std.testing.expectEqual(ui_thread, sink.threads[1]);
    try std.testing.expect(run_thread != ui_thread);

    const fact = sink.finished[0];
    try std.testing.expect(fact.end_ns > fact.start_ns);
    try std.testing.expect(fact.end_ns - fact.start_ns >= 2 * std.time.ns_per_ms);
    try std.testing.expect(fact.start_ns >= fact.queued_ns);
    try std.testing.expect(service.clock.now() > @as(i96, @intCast(fact.end_ns)));
    try std.testing.expectEqual(@as(u32, 12), last_result);
    service.setObserver(null);
    try session.shutdownTasks(500 * std.time.ns_per_ms);
}

/// One spawn, step, drain and shutdown cycle. The sink uses fixed storage, so
/// any difference in the count comes from the service itself.
fn taskCycle(gpa: std.mem.Allocator, observed: bool) !usize {
    var counter: CountingAllocator = .{ .inner = gpa };
    {
        var session = try Session.init(counter.allocator());
        defer session.deinit() catch |err|
            std.debug.panic("cycle session deinit: {s}", .{@errorName(err)});
        var ticks: i96 = 10;
        try session.startTasksDeterministic(Clock.injected(&ticks, nowTicks));
        const service = try serviceOf(&session);
        var sink: Sink = .{};
        if (observed) service.setObserver(sink.observer());
        var deliveries: u32 = 0;
        var last_result: u32 = 0;
        var timeouts: u32 = 0;
        var probe_value: Probe = .{
            .deliveries = &deliveries,
            .last_result = &last_result,
            .timeouts = &timeouts,
        };
        var probe = try session.create(Probe, &probe_value);
        defer session.release(Probe, &probe) catch |err|
            std.debug.panic("probe release: {s}", .{@errorName(err)});
        var work: Work = .{ .input = 2, .ticks = &ticks, .advance_ns = 3 };
        _ = try session.spawnWorker(Work, Probe, Work.run, Probe.completed, probe.weak(), &work, .{});
        try std.testing.expect((try session.stepDeterministicWorker()) != null);
        try std.testing.expectEqual(@as(usize, 1), try session.drainTasks());
        service.setObserver(null);
        try session.shutdownTasks(0);
        const expected: usize = if (observed) 1 else 0;
        try std.testing.expectEqual(expected, sink.queued_count);
        try std.testing.expectEqual(expected, sink.finished_count);
        try std.testing.expectEqual(@as(u32, 1), deliveries);
    }
    return counter.allocs;
}

test "api-w24 a disabled observer adds no allocation and reports no fact" {
    const gpa = std.testing.allocator;
    const quiet = try taskCycle(gpa, false);
    const observed = try taskCycle(gpa, true);
    try std.testing.expectEqual(quiet, observed);
}

test "api-w24 clearing the observer stops facts before the sink storage ends" {
    const gpa = std.testing.allocator;
    var io_impl = std.Io.Threaded.init(gpa, .{});
    defer io_impl.deinit();
    var session = try Session.init(gpa);
    defer session.deinit() catch unreachable;
    var ticks: i96 = 10;
    try session.startTasksDeterministic(Clock.injected(&ticks, nowTicks));
    const service = try serviceOf(&session);
    var sink: Sink = .{ .service = service };
    service.setObserver(sink.observer());

    var deliveries: u32 = 0;
    var last_result: u32 = 0;
    var timeouts: u32 = 0;
    var probe_value: Probe = .{
        .deliveries = &deliveries,
        .last_result = &last_result,
        .timeouts = &timeouts,
    };
    var probe = try session.create(Probe, &probe_value);
    defer session.release(Probe, &probe) catch unreachable;

    var first: Work = .{ .input = 1, .ticks = &ticks, .advance_ns = 2 };
    _ = try session.spawnWorker(Work, Probe, Work.run, Probe.completed, probe.weak(), &first, .{});
    _ = try session.stepDeterministicWorker();
    _ = try session.drainTasks();
    try std.testing.expectEqual(@as(usize, 1), sink.queued_count);
    try std.testing.expectEqual(@as(usize, 1), sink.finished_count);

    // A cleared sink sees nothing while the jobs keep their normal delivery.
    service.setObserver(null);
    var second: Work = .{ .input = 2, .ticks = &ticks, .advance_ns = 2 };
    _ = try session.spawnWorker(Work, Probe, Work.run, Probe.completed, probe.weak(), &second, .{});
    _ = try session.stepDeterministicWorker();
    _ = try session.drainTasks();
    try std.testing.expectEqual(@as(usize, 1), sink.queued_count);
    try std.testing.expectEqual(@as(usize, 1), sink.finished_count);

    // A fact staged while observed and flushed after the clear is dropped, so
    // the sink's storage may end while the service still runs.
    service.setObserver(sink.observer());
    var third: Work = .{ .input = 3, .ticks = &ticks, .advance_ns = 2 };
    _ = try session.spawnWorker(Work, Probe, Work.run, Probe.completed, probe.weak(), &third, .{});
    _ = try session.stepDeterministicWorker();
    service.setObserver(null);
    var fourth: Work = .{ .input = 4, .ticks = &ticks, .advance_ns = 2 };
    _ = try session.spawnWorker(Work, Probe, Work.run, Probe.completed, probe.weak(), &fourth, .{});
    _ = try session.stepDeterministicWorker();
    try std.testing.expectEqual(@as(usize, 2), try session.drainTasks());
    // Jobs two and four ran while the observer was off.
    try std.testing.expectEqual(@as(usize, 2), sink.queued_count);
    try std.testing.expectEqual(@as(usize, 1), sink.finished_count);
    try std.testing.expectEqual(@as(usize, 0), try session.drainTasks());
    try std.testing.expectEqual(@as(u32, 4), deliveries);
    service.setObserver(null);
    try session.shutdownTasks(0);
}
