const std = @import("std");
const FrameDemand = @import("frame_demand.zig").FrameDemand;
const Session = @import("session.zig").Session;

test "api-w05 one frame then a long idle interval does not build or present" {
    var demand: FrameDemand = .{};
    var frames: u32 = 0;
    for (0..1001) |now_ms| {
        if (demand.take(@intCast(now_ms))) |work| {
            frames += 1;
            try std.testing.expect(work.layout and work.paint and work.present);
            demand.finish(true);
        }
    }
    try std.testing.expectEqual(@as(u32, 1), frames);
    try std.testing.expectEqual(@as(?u31, null), demand.waitMilliseconds(1000));
}

test "api-w05 event and coalesced model update wake only their owning window" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    const left = try session.registerApp();
    defer session.unregisterApp(left);
    const right = try session.registerApp();
    defer session.unregisterApp(right);
    var left_demand: FrameDemand = .{};
    var right_demand: FrameDemand = .{};
    _ = left_demand.take(0).?;
    left_demand.finish(true);
    _ = right_demand.take(0).?;
    right_demand.finish(true);

    left_demand.invalidateLayout(); // translated input
    try session.requestRedraw(left); // model update
    try session.requestRedraw(left); // coalesced update
    try std.testing.expect(try session.takeRedraw(left));
    try std.testing.expect(!(try session.takeRedraw(left)));
    try std.testing.expect(!(try session.takeRedraw(right)));
    const work = left_demand.take(5).?;
    try std.testing.expect(work.layout and work.paint and work.present);
    left_demand.finish(true);
    try session.beginFrame(left);
    session.finishFrame(left, true);
    try std.testing.expect(right_demand.take(5) == null);
    try std.testing.expect(left_demand.take(6) == null);
}

test "api-w05 invalidation tiers coalesce and a failed frame remains demanded" {
    var demand: FrameDemand = .{};
    _ = demand.take(0).?;
    demand.finish(true);
    demand.requestPresentation();
    const presentation = demand.take(10).?;
    try std.testing.expect(presentation.present and !presentation.paint and !presentation.layout);
    demand.invalidatePaint();
    demand.finish(false);
    const retry = demand.take(10).?;
    try std.testing.expect(retry.paint and retry.present and !retry.layout);
    demand.finish(true);
    demand.invalidateLayout();
    const layout = demand.take(11).?;
    try std.testing.expect(layout.layout and layout.paint and layout.present);
    demand.finish(true);
    try std.testing.expect(demand.take(12) == null);
}

test "api-w05 hidden window neither animates nor continuously paints and retains changes" {
    var demand: FrameDemand = .{};
    demand.setContinuous(true);
    demand.setDeadline(100);
    demand.setVisible(false);
    for (0..400) |now_ms| {
        try std.testing.expect(demand.take(@intCast(now_ms)) == null);
    }
    try std.testing.expectEqual(@as(?u31, null), demand.waitMilliseconds(400));
    demand.setVisible(true);
    const work = demand.take(400).?;
    try std.testing.expect(work.layout and work.animation and work.continuous);
    demand.finish(true);
    try std.testing.expect(demand.take(401) != null);
    demand.finish(true);
    demand.setContinuous(false);
    try std.testing.expect(demand.take(402) == null);
}

test "api-w05 deadline waits until its injected time and stops after one frame" {
    var demand: FrameDemand = .{};
    _ = demand.take(0).?;
    demand.finish(true);
    demand.setDeadline(120);
    try std.testing.expectEqual(@as(?u31, 20), demand.waitMilliseconds(100));
    try std.testing.expect(demand.take(119) == null);
    const work = demand.take(120).?;
    try std.testing.expect(!work.layout and work.paint and work.present and work.animation);
    demand.finish(true);
    try std.testing.expect(demand.take(121) == null);
    try std.testing.expectEqual(@as(?u31, null), demand.waitMilliseconds(121));
}

test "api-w05 failed animation frame retries its deadline once" {
    var demand: FrameDemand = .{};
    _ = demand.take(0).?;
    demand.finish(true);
    demand.setDeadline(40);
    try std.testing.expect(demand.take(39) == null);
    try std.testing.expect(demand.take(40).?.animation);
    demand.finish(false);
    try std.testing.expect(demand.take(41).?.animation);
    demand.finish(true);
    try std.testing.expect(demand.take(42) == null);
}

test "api-w05 deadline timeout rounds up and saturates without early firing" {
    var demand: FrameDemand = .{};
    _ = demand.take(0).?;
    demand.finish(true);
    demand.setDeadline(std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(u31), demand.waitMilliseconds(0).?);
    try std.testing.expect(demand.take(1) == null);
    demand.setDeadline(null);
    try std.testing.expectEqual(@as(?u31, null), demand.waitMilliseconds(1));
}

test "api-w05 task deadline uses ceil milliseconds and does not overflow SDL timeout" {
    const timeout = @import("frame_demand.zig").taskDeadlineWaitMilliseconds;
    try std.testing.expectEqual(@as(u31, 0), timeout(1_000_000, 1_000_000));
    try std.testing.expectEqual(@as(u31, 1), timeout(1_000_000, 1_000_001));
    try std.testing.expectEqual(@as(u31, 2), timeout(1_000_000, 2_000_001));
    try std.testing.expectEqual(std.math.maxInt(u31), timeout(0, std.math.maxInt(i96)));
}

test "api-w05 explicit continuous mode advances every visible GPU frame" {
    var demand: FrameDemand = .{};
    _ = demand.take(0).?;
    demand.finish(true);
    demand.setContinuous(true);
    var frames: u32 = 0;
    for (1..25) |now_ms| {
        const work = demand.take(@intCast(now_ms)).?;
        try std.testing.expect(work.continuous and work.paint and work.present);
        demand.finish(true);
        frames += 1;
    }
    try std.testing.expectEqual(@as(u32, 24), frames);
    demand.setContinuous(false);
    try std.testing.expect(demand.take(25) == null);
}
