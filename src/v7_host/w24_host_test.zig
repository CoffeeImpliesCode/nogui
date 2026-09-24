const std = @import("std");
const nogui = @import("nogui");
const Application = @import("application.zig").Application;
const ManagedWindow = @import("application.zig").ManagedWindow;
const Inspector = @import("inspector.zig").Inspector;
const BenchContext = @import("inspector.zig").BenchContext;
const sdl_session = @import("sdl_session.zig");

const View = struct {
    pub fn draw(_: *View, _: *const u8, ctx: *nogui.DrawCtx) !void {
        _ = try ctx.label(.{ .text = "inspected" });
    }
};

const Driver = struct {
    calls: u64 = 0,
    succeed: bool = true,

    fn frame(
        raw: *anyopaque,
        _: *Application,
        window: *ManagedWindow,
        _: nogui.frame_demand.FrameDemand.Work,
    ) !bool {
        const self: *Driver = @ptrCast(@alignCast(raw));
        if (!self.succeed) return false;
        self.calls += 1;
        _ = try window.app.frame(@intCast(self.calls), .{
            .width = @floatFromInt(window.requested.size.width),
            .height = @floatFromInt(window.requested.size.height),
        });
        return true;
    }
};

test "api-w24 native host captures committed frames and never publishes a failed frame" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    try sdl_session.acquireForTest("dummy");
    var host = try Application.init(std.testing.allocator, &session, .{ .video_driver = "dummy" });
    var inspector = try Inspector.initOwned(std.testing.allocator, .{
        .frame_capacity = 4,
        .enable_collectors = true,
        .enable_picking = true,
    });
    defer inspector.deinit();
    defer host.deinit();

    const handle = try host.openWindow(.{ .title = "inspected", .width = 160, .height = 100 });
    const window = try host.getWindow(handle);
    var value: u8 = 0;
    var model = try session.create(u8, &value);
    defer session.release(u8, &model) catch unreachable;
    var view: View = .{};
    try window.app.mountModelRoot(u8, View, model, &view);
    try host.setInspector(handle, &inspector);
    var driver: Driver = .{};
    host.setHooks(.{ .context = &driver, .on_frame = Driver.frame });

    _ = try host.step();
    try std.testing.expectEqual(@as(u64, 1), window.app.frame_generation);
    try std.testing.expectEqual(@as(u64, 1), inspector.latest_snapshot.?.frame_number);
    try std.testing.expectEqual(@as(usize, 1), inspector.frame_collector.count);
    try std.testing.expectEqual(@as(u64, 1), inspector.frame_collector.buffer[0].frame_number);

    driver.succeed = false;
    window.demand.invalidateLayout();
    _ = try host.step();
    try std.testing.expectEqual(@as(u64, 1), inspector.latest_snapshot.?.frame_number);
    try std.testing.expectEqual(@as(usize, 1), inspector.frame_collector.count);

    driver.succeed = true;
    _ = try host.step();
    try std.testing.expectEqual(@as(u64, 2), inspector.latest_snapshot.?.frame_number);
    try std.testing.expectEqual(@as(usize, 2), inspector.frame_collector.count);

    try std.testing.expect(try host.closeWindow(handle));
    try std.testing.expect(inspector.latest_snapshot == null);
}

test "api-w24 a mounted inspector with snapshots off allocates nothing per frame" {
    const gpa = std.testing.allocator;
    var tree = nogui.WidgetTree.init(gpa);
    defer tree.deinit();
    try tree.nodes.append(gpa, .{
        .id = @enumFromInt(1),
        .widget_id = .{ .owner = 1, .slot = 1, .generation = 1 },
        .kind = .{ .label = .{ .text = "quiet" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 20 },
    });

    // Every allocation fails from the first one, so a silent inspector
    // proves it reserves nothing and captures nothing per frame.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var inspector = try Inspector.initOwned(failing.allocator(), .{
        .frame_capacity = 4,
        .task_capacity = 0,
        .action_capacity = 0,
        .capture_snapshots = false,
    });
    defer inspector.deinit();
    try std.testing.expect(!inspector.isSnapshotEnabled());
    try std.testing.expect(!failing.has_induced_failure);

    var frame: u64 = 1;
    while (frame <= 8) : (frame += 1) {
        try inspector.onFrame(.{
            .frame_number = frame,
            .viewport = .{ .w = 100, .h = 100 },
            .tree = &tree,
        }, .{ .frame_number = frame, .timestamp_ns = frame * 10 });
    }
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expect(inspector.latest_snapshot == null);

    // The frame collector still runs: silencing snapshots is not silencing
    // the metrics a host measured.
    try std.testing.expectEqual(@as(u64, 0), inspector.frame_collector.count);

    failing.fail_index = std.math.maxInt(usize);
    try inspector.enableCollectors(true);
    try inspector.onFrame(.{
        .frame_number = 9,
        .viewport = .{ .w = 100, .h = 100 },
        .tree = &tree,
    }, .{ .frame_number = 9, .timestamp_ns = 90 });
    try std.testing.expectEqual(@as(u64, 1), inspector.frame_collector.total_recorded);
    try std.testing.expect(inspector.latest_snapshot == null);

    // Turning capture back on restores the snapshot, and the retained frame
    // is the one the last commit produced.
    failing.fail_index = std.math.maxInt(usize);
    inspector.setSnapshotEnabled(true);
    try std.testing.expect(inspector.isSnapshotEnabled());
    try inspector.onFrame(.{
        .frame_number = 10,
        .viewport = .{ .w = 100, .h = 100 },
        .tree = &tree,
    }, .{ .frame_number = 10, .timestamp_ns = 100 });
    try std.testing.expectEqual(@as(u64, 10), inspector.latest_snapshot.?.frame_number);
    const picked = inspector.pickAt(.{ 5, 5 });
    try std.testing.expectEqual(
        nogui.input.hitTest(&tree, .{ 5, 5 }).?,
        picked.node.?,
    );
}

test "api-w24 the performance JSONL merges the three collectors in one order" {
    const gpa = std.testing.allocator;
    var inspector = try Inspector.initOwned(gpa, .{
        .frame_capacity = 4,
        .task_capacity = 4,
        .action_capacity = 4,
        .enable_collectors = true,
    });
    defer inspector.deinit();

    // Deliberately recorded out of order, and across kinds, so collector
    // order and chronological order cannot be confused.
    inspector.onActionDispatched("late_action", null, 40, 45, .handled, 0);
    inspector.onTaskFinished(9, .high, 5, 20, 30, "worker", null);
    inspector.frame_collector.record(.{
        .frame_number = 1,
        .timestamp_ns = 25,
    });
    inspector.onTaskQueued(8, .normal, 1, "queued", null);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try inspector.writePerformanceJsonl(&out.writer);

    var kinds: [4][]const u8 = undefined;
    var stamps: [4]i64 = undefined;
    var seen: usize = 0;
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer parsed.deinit();
        const record = parsed.value.object;
        kinds[seen] = if (record.get("type")) |kind| kind.string else "frame";
        const stamp = if (record.get("end_ns")) |end|
            end.integer
        else
            record.get("timestamp_ns").?.integer;
        stamps[seen] = stamp;
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), seen);
    // Chronological: the task queued at 0, the frame at 25, the finished
    // task at 30, the action at 45.
    try std.testing.expectEqualStrings("task", kinds[0]);
    try std.testing.expectEqual(@as(i64, 0), stamps[0]);
    try std.testing.expectEqualStrings("frame", kinds[1]);
    try std.testing.expectEqual(@as(i64, 25), stamps[1]);
    try std.testing.expectEqualStrings("task", kinds[2]);
    try std.testing.expectEqual(@as(i64, 30), stamps[2]);
    try std.testing.expectEqualStrings("action", kinds[3]);
    try std.testing.expectEqual(@as(i64, 45), stamps[3]);
}

/// One spawned task, named so a wrong collector entry is visible by name.
const HostWork = struct {
    ticks: *i96,
    advance_ns: i96 = 0,

    fn run(self: *HostWork, _: std.Io) void {
        self.ticks.* += self.advance_ns;
    }
};

fn hostNowTicks(context: *anyopaque) i96 {
    const ticks: *i96 = @ptrCast(@alignCast(context));
    return ticks.*;
}

fn hostWorkDone(_: *u8, _: *HostWork, _: *nogui.Session) void {}

test "api-w24 the real task service attributes one queued and one finished record" {
    const gpa = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    var session = try nogui.Session.init(gpa);
    defer session.deinit() catch unreachable;
    var ticks: i96 = 1_000;
    try session.startTasksDeterministic(nogui.Clock.injected(&ticks, hostNowTicks));
    const service = session.task_service orelse return error.TasksNotStarted;

    var inspector = try Inspector.initOwned(gpa, .{
        .frame_capacity = 0,
        .task_capacity = 4,
        .action_capacity = 0,
        .enable_collectors = true,
    });
    defer inspector.deinit();
    service.setObserver(inspector.taskObserver());

    var owner_value: u8 = 0;
    var owner = try session.create(u8, &owner_value);
    defer session.release(u8, &owner) catch unreachable;

    var first: HostWork = .{ .ticks = &ticks, .advance_ns = 40 };
    const first_handle = try session.spawnWorker(
        HostWork,
        u8,
        HostWork.run,
        hostWorkDone,
        owner.weak(),
        &first,
        .{ .name = "host-first", .priority = .high },
    );
    try std.testing.expectEqual(@as(usize, 1), inspector.task_collector.count);
    const queued = inspector.task_collector.get(0).?;
    try std.testing.expectEqual(first_handle.id, queued.task_id);
    try std.testing.expectEqualStrings("host-first", queued.getName());
    try std.testing.expectEqual(nogui.task.Priority.high, queued.priority);
    try std.testing.expectEqual(@as(u64, 1_000), queued.queued_ns);
    // A queue fact carries no work yet, so it must not invent a duration.
    try std.testing.expectEqual(@as(u64, 0), queued.duration_ns);
    try std.testing.expectEqual(@as(u64, 0), queued.start_ns);
    try std.testing.expectEqual(@as(u64, 0), queued.end_ns);

    ticks = 1_200;
    _ = try session.stepDeterministicWorker();
    // The worker ran, but only the UI thread publishes the fact.
    try std.testing.expectEqual(@as(usize, 1), inspector.task_collector.count);
    _ = try session.drainTasks();
    try std.testing.expectEqual(@as(usize, 2), inspector.task_collector.count);
    const finished = inspector.task_collector.get(1).?;
    try std.testing.expectEqual(first_handle.id, finished.task_id);
    try std.testing.expectEqualStrings("host-first", finished.getName());
    try std.testing.expectEqual(@as(u64, 1_000), finished.queued_ns);
    try std.testing.expectEqual(@as(u64, 1_200), finished.start_ns);
    try std.testing.expectEqual(@as(u64, 1_240), finished.end_ns);
    try std.testing.expectEqual(@as(u64, 40), finished.duration_ns);
    try std.testing.expect(finished.end_ns >= finished.start_ns);
    try std.testing.expect(finished.start_ns >= finished.queued_ns);

    // With the observer cleared, the service still runs and the collector
    // stops: attribution lives at the service boundary, not in the caller.
    service.setObserver(null);
    var third: HostWork = .{ .ticks = &ticks, .advance_ns = 5 };
    _ = try session.spawnWorker(
        HostWork,
        u8,
        HostWork.run,
        hostWorkDone,
        owner.weak(),
        &third,
        .{ .name = "host-unobserved" },
    );
    _ = try session.stepDeterministicWorker();
    _ = try session.drainTasks();
    try std.testing.expectEqual(@as(usize, 2), inspector.task_collector.count);

    // A second observed task is a distinct id, and a full ring keeps the
    // newest records without losing chronological order.
    service.setObserver(inspector.taskObserver());
    var second: HostWork = .{ .ticks = &ticks, .advance_ns = 10 };
    const second_handle = try session.spawnWorker(
        HostWork,
        u8,
        HostWork.run,
        hostWorkDone,
        owner.weak(),
        &second,
        .{ .name = "host-second" },
    );
    _ = try session.stepDeterministicWorker();
    _ = try session.drainTasks();
    try std.testing.expectEqual(@as(usize, 4), inspector.task_collector.count);
    try std.testing.expectEqual(@as(u64, 0), inspector.task_collector.overruns);
    try std.testing.expectEqual(
        second_handle.id,
        inspector.task_collector.latest().?.task_id,
    );
    try std.testing.expectEqual(
        first_handle.id,
        inspector.task_collector.get(0).?.task_id,
    );
    try std.testing.expectEqual(
        first_handle.id,
        inspector.task_collector.get(1).?.task_id,
    );
    service.setObserver(null);
    try session.shutdownTasks(0);
}

/// The bodies are `fn (std.Io) void`, so each reaches the injected clock
/// through the tick counter this file owns.
var bench_ticks: i96 = 0;

fn burnSamples(_: std.Io) void {
    bench_ticks += 250;
}

fn burnRealTime(io: std.Io) void {
    bench_ticks += 1;
    std.Io.sleep(io, .fromNanoseconds(2 * std.time.ns_per_ms), .real) catch |err| switch (err) {
        error.Canceled => {},
    };
}

test "api-w24 a benchmark context keeps virtual time in tests and real time in production" {
    const gpa = std.testing.allocator;
    var inspector = try Inspector.initOwned(gpa, .{
        .frame_capacity = 2,
        .task_capacity = 0,
        .action_capacity = 0,
        .enable_collectors = true,
    });
    defer inspector.deinit();

    // Deterministic half: the injected clock advances inside the body, so
    // every sample is exact and no wall time is involved.
    bench_ticks = 1_000;
    var storage: [3]u64 = undefined;
    var bench = BenchContext.init(
        nogui.Clock.injected(&bench_ticks, hostNowTicks),
        &storage,
    );
    bench.label = "virtual";
    try std.testing.expectEqual(@as(u64, 250), bench.run(std.testing.io, burnSamples));
    try std.testing.expectEqual(@as(u64, 250), bench.run(std.testing.io, burnSamples));
    const stats = bench.summary();
    try std.testing.expectEqual(@as(usize, 2), stats.iterations.?);
    try std.testing.expectEqual(@as(u64, 250), stats.min_ns.?);
    try std.testing.expectEqual(@as(u64, 250), stats.max_ns.?);
    try std.testing.expectEqual(@as(u64, 250), stats.mean_ns.?);
    try std.testing.expectEqual(@as(u64, 500), stats.total_ns.?);

    // The third sample fills the window exactly, so nothing is dropped.
    try std.testing.expectEqual(@as(u64, 250), bench.run(std.testing.io, burnSamples));
    try std.testing.expectEqual(@as(usize, 3), bench.recorded);
    try std.testing.expectEqual(@as(u64, 750), bench.summary().total_ns.?);

    // A fourth sample has no storage, so the loss is reported rather than
    // hidden in a silent allocation, and the statistics keep the three
    // samples that were kept.
    try std.testing.expectEqual(@as(u64, 250), bench.run(std.testing.io, burnSamples));
    try std.testing.expectEqual(@as(usize, 3), bench.recorded);
    try std.testing.expectEqual(@as(u64, 750), bench.summary().total_ns.?);

    // Retention is read from the inspector, not measured again.
    var frame: u64 = 1;
    while (frame <= 3) : (frame += 1) {
        inspector.frame_collector.record(.{
            .frame_number = frame,
            .timestamp_ns = frame,
            .gpu_execute_ns = if (frame == 3) 4242 else null,
        });
    }
    bench.observe(&inspector);
    try std.testing.expectEqual(@as(usize, 2), bench.frame_records);
    try std.testing.expectEqual(@as(u64, 1), bench.frame_overruns);
    try std.testing.expectEqual(@as(u64, 4242), bench.gpu_execute_ns.?);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try bench.writeJson(&out.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.written(), .{});
    defer parsed.deinit();
    const report = parsed.value.object;
    try std.testing.expectEqualStrings("virtual", report.get("bench").?.string);
    try std.testing.expectEqual(@as(i64, 3), report.get("iterations").?.integer);
    try std.testing.expectEqual(@as(i64, 1), report.get("dropped").?.integer);
    try std.testing.expectEqual(@as(i64, 250), report.get("min_ns").?.integer);
    try std.testing.expectEqual(@as(i64, 2), report.get("frame_records").?.integer);
    try std.testing.expectEqual(@as(i64, 4242), report.get("gpu_execute_ns").?.integer);

    try std.testing.expectEqual(@as(i64, 250), report.get("mean_ns").?.integer);
    try std.testing.expectEqual(@as(i64, 750), report.get("total_ns").?.integer);

    // Production half: the same context on the real monotonic clock must
    // report elapsed time, not a simulated one.
    var io_impl: std.Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    var real_storage: [1]u64 = undefined;
    var real_bench = BenchContext.initMonotonic(io_impl.io(), &real_storage);
    real_bench.label = "production";
    _ = real_bench.run(io_impl.io(), burnRealTime);
    const real_stats = real_bench.summary();
    try std.testing.expectEqual(@as(usize, 1), real_stats.iterations.?);
    try std.testing.expect(real_stats.min_ns.? >= 1 * std.time.ns_per_ms);

    // A context that recorded nothing reports "not measured" as nulls.
    var empty_storage: [1]u64 = undefined;
    var empty_bench = BenchContext.init(
        nogui.Clock.injected(&bench_ticks, hostNowTicks),
        &empty_storage,
    );
    var empty_out: std.Io.Writer.Allocating = .init(gpa);
    defer empty_out.deinit();
    try empty_bench.writeJson(&empty_out.writer);
    const empty_parsed = try std.json.parseFromSlice(std.json.Value, gpa, empty_out.written(), .{});
    defer empty_parsed.deinit();
    // "Not measured" is a JSON null, so the check reads the union's tag rather
    // than touching the `float` field of a value that is not a float.
    try std.testing.expect(empty_parsed.value.object.get("min_ns").? == .null);
    try std.testing.expect(empty_parsed.value.object.get("gpu_execute_ns").? == .null);
    try std.testing.expectEqual(
        @as(i64, 0),
        empty_parsed.value.object.get("iterations").?.integer,
    );
}
