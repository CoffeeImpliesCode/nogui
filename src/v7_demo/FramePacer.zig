//! Frame pacer — ported from mr_gpu's FramePacer
//! (codeberg.org/Games-by-Mason/mr_gpu, src/ext/FramePacer.zig).
//!
//! A standalone std+tracy port (no mr_geom dependency): smooths delta time
//! and reduces input latency under FIFO (vsync) presentation.
//!
//! # Why
//!
//! With a FIFO swapchain + vsync, once the image queue is full the CPU
//! blocks on the GPU *after* polling input and rendering the frame —
//! pushing input latency up to a full frame. The pacer measures that block
//! (the "slop": CPU ns spent blocked on the GPU, from `Surface.slopNs()`)
//! and uses it to schedule the next frame's start (sleep before the input
//! poll) so the frame lands just before the vblank instead of blocking
//! after it.
//!
//! # Algorithm (per frame, call `update` immediately after present)
//!
//! 1. Lap the frame timer; the lap is the period since the last `update`
//!    (the whole frame: render + present + sleep).
//! 2. `unscaled_ds` = EMA of `min(delta_s, max_smoothed_s)` with weight
//!    `smoothed_rwa` — `lerp(old, min(delta, max_smoothed), smoothed_rwa)`.
//! 3. Sleep control:
//!    - Overshoot (`delta_ms > refresh_period_ms + overshoot_ms`):
//!      `sleep_ms *= overshoot_scale` (0.9) — back off the sleep.
//!    - Otherwise: `sleep_ms += (slop_ms - headroom_ms) * sleep_rwa` — scale
//!      toward leaving only `headroom_ms` of slop.
//!    - Clamp `sleep_ms` to `[0, refresh_period_ms - headroom_ms]`.
//! 4. Return `sleep_ms` in ns — the recommended delay before polling input.
//!
//! Wrap the actual sleep in `beginSleep`/`endSleep` so it is excluded from
//! the per-frame CPU time reported by `cpuS()` (the delta measurement still
//! includes it — it IS the frame period).
//!
//! `refresh_rate_hz == 0` means "unknown": the pacer falls back to
//! `refresh_rate_safe_hz` for pacing and `headroom_safe_ms` for headroom.

const std = @import("std");
const tracy = @import("tracy");
const Io = std.Io;

pub const FramePacer = @This();

/// The target frame time, or `0` for unknown (safe fallbacks apply). You may
/// update this if the monitor changes; don't poll the OS for it every frame.
refresh_rate_hz: f32,
/// If the refresh rate is unknown, never sleep below this rate.
refresh_rate_safe_hz: f32 = 60.0,
/// The amount of headroom to leave. Configurable.
headroom_ms: f32 = 2.0,
/// The amount of headroom to leave when the refresh rate is unknown —
/// less aggressive, to mitigate a death spiral when driver overhead
/// exceeds the headroom.
headroom_safe_ms: f32 = 5.0,
/// If a frame time overshoots the target by more than this, scale back the
/// sleep amount. (Checking the sum of the last two frames against twice the
/// refresh period would be more robust — being late once is actually okay —
/// but this is simple and works well enough.)
overshoot_ms: f32 = 1.0,
/// The amount to scale back the sleep on overshoot.
overshoot_scale: f32 = 0.9,
/// The current sleep amount. Updated by `update`.
sleep_ms: f32 = 0.0,
/// The ratio of the slop to convert to sleep each update.
sleep_rwa: f32 = 0.1,
/// The ratio of the current frame time to factor into the smoothed delta
/// time every frame.
smoothed_rwa: f32 = 0.1,
/// The max smooth frame time.
max_smoothed_s: f32 = 1.0 / 30.0,
/// The scaled smoothed delta time ("delta seconds"). Updated by `update`.
///
/// "ds" is short for "delta seconds", chosen over the more familiar "dt" to
/// make the units clearer.
ds: f32,
/// The unscaled smoothed delta time. Updated by `update`. Prefer `ds`.
unscaled_ds: f32,
/// The unsmoothed, unscaled delta time. Updated by `update`. Prefer `ds`.
raw_ds: f32,
/// The slop time (seconds). Updated by `update`.
slop_s: f32 = 0.0,
/// The frame timer (lapped per update).
timer: Timer,
/// Used to track sleep time.
sleep_timer: Timer,
/// Used to accumulate sleep time.
sleep_accum_s: f32 = 0.0,
/// The time spent sleeping last frame (seconds). Updated by `update`.
sleep_s: f32 = 0.0,
/// The amount to scale smoothed delta time. Defaults to 1; can be set to
/// other values to speed up or slow down the entire game.
time_scale: f32 = 1.0,

const plot_smoothed_delta_s_unscaled = "FP: Smoothed Delta S (unscaled)";
const plot_delta_s = "FP: Delta S";
const plot_slop_ms = "FP: Slop MS";
const plot_sleep_ms = "FP: Sleep MS";

const plot_names: []const [:0]const u8 = &.{
    plot_smoothed_delta_s_unscaled,
    plot_delta_s,
    plot_slop_ms,
    plot_sleep_ms,
};

/// Pass `0` for the refresh rate if it is unknown. (In-band signaling,
/// mirroring the platforms that already use 0 as "unknown".)
pub fn init(io: Io, refresh_rate_hz: f32) FramePacer {
    for (plot_names) |name| {
        tracy.plotConfig(.{
            .name = name,
            .format = .number,
            .mode = .line,
            .fill = true,
        });
    }

    // Pre-warm the smoothed delta to the target frame period. It may not be
    // correct (e.g. under VRR) but it's a good starting point.
    const warmed_delta_s = if (refresh_rate_hz == 0)
        1.0 / 60.0 // no known refresh rate — warm to 60hz
    else
        1.0 / refresh_rate_hz;

    return .{
        .refresh_rate_hz = refresh_rate_hz,
        .unscaled_ds = warmed_delta_s,
        .ds = warmed_delta_s,
        .raw_ds = warmed_delta_s,
        .timer = .start(io),
        .sleep_timer = .start(io),
    };
}

/// `slop_ns` is the amount of CPU time spent blocked on the GPU this frame
/// (from `Surface.slopNs()`); pass `0` if this value is unknown or you don't
/// care about lowering input latency. The return value is the suggested
/// number of nanoseconds to delay before polling for user input.
pub fn update(self: *FramePacer, io: Io, slop_ns: u64) u64 {
    // Lap the frame timer, get constants and convert to useful units.
    const delta_ns = self.timer.lap(io).toNanoseconds();
    const delta_s = @as(f32, @floatFromInt(delta_ns)) / std.time.ns_per_s;
    const delta_ms = @as(f32, @floatFromInt(delta_ns)) / std.time.ns_per_ms;
    const slop_ms = @as(f32, @floatFromInt(slop_ns)) / std.time.ns_per_ms;
    const slop_s = @as(f32, @floatFromInt(slop_ns)) / std.time.ns_per_s;
    const headroom_ms = if (self.refresh_rate_hz == 0) self.headroom_safe_ms else self.headroom_ms;
    const rate_hz = if (self.refresh_rate_hz == 0) self.refresh_rate_safe_hz else self.refresh_rate_hz;
    const refresh_period_ms = 1000.0 / rate_hz;

    // Update the delta time and smoothed delta time.
    self.raw_ds = delta_s;
    self.slop_s = slop_s;
    self.unscaled_ds = lerp(self.unscaled_ds, @min(delta_s, self.max_smoothed_s), self.smoothed_rwa);
    self.ds = self.unscaled_ds * self.time_scale;
    self.sleep_s = self.sleep_accum_s;
    self.sleep_accum_s = 0.0;

    // Check our timing and adjust the sleep amount as needed.
    if (delta_ms > refresh_period_ms + self.overshoot_ms) {
        // If our frame time overshot our max due to sleeping, scale back
        // our sleep amount. Ideally this will never happen due to sleeping;
        // if it happens often our headroom is too low. 0.15 is an arbitrary
        // epsilon that prevents showing the warning unnecessarily when
        // performance is bad for unrelated reasons.
        if (self.sleep_ms > 0.15) {
            tracy.message(.{ .text = "frame pacer overshot", .callstack_depth = 0 });
        }
        self.sleep_ms *= self.overshoot_scale;
    } else {
        // Sleep toward the vblank deadline: refresh_period - headroom minus
        // the non-blocked CPU/GPU work (raw frame time - the blocked slop -
        // the previous sleep). NOTE: the mr_gpu's original targets slop
        // (sleep = slop - headroom) because its gx.slop_ns counts ONLY the
        // present block. Our Surface.slopNs() accumulates the acquire wait
        // too, and with FIFO the acquire block IS the queue-full wait — so
        // targeting slop double-waits and every frame misses the vblank.
        // Targeting the deadline directly is robust to whatever the slop
        // happens to measure.
        const work_ms = delta_ms - slop_ms - self.sleep_s * std.time.ns_per_ms / std.time.ns_per_ms;
        const target_sleep_ms = refresh_period_ms - headroom_ms - @max(work_ms, 0.0);
        self.sleep_ms += (target_sleep_ms - self.sleep_ms) * self.sleep_rwa;
    }

    // Clamp to the headroom allowed range.
    self.sleep_ms = std.math.clamp(self.sleep_ms, 0.0, @max(refresh_period_ms - headroom_ms, 0.0));
    const sleep_ns = sleepNsFromMs(self.sleep_ms) orelse {
        self.sleep_ms = 0.0;
        return 0;
    };

    // Tracy plots.
    tracy.plot(.{ .name = plot_slop_ms, .value = .{ .f32 = slop_ms } });
    tracy.plot(.{ .name = plot_delta_s, .value = .{ .f32 = delta_s } });
    tracy.plot(.{ .name = plot_smoothed_delta_s_unscaled, .value = .{ .f32 = self.unscaled_ds } });
    tracy.plot(.{ .name = plot_sleep_ms, .value = .{ .f32 = self.sleep_ms } });

    // Return the recommended delay in nanoseconds.
    return sleep_ns;
}

fn sleepNsFromMs(sleep_ms: f32) ?u64 {
    const sleep_ns_f32 = sleep_ms * std.time.ns_per_ms;
    const sleep_ns: f64 = @floatCast(sleep_ns_f32);
    const max_safe_ns = std.math.maxInt(u64) - 2048;
    const max_safe_ns_f64: f64 = @floatFromInt(max_safe_ns);

    if (!std.math.isFinite(sleep_ns)) return null;
    if (sleep_ns < 0.0) return null;
    if (sleep_ns > max_safe_ns_f64) return null;

    const bounded_ns = @min(
        @max(sleep_ns, 0.0),
        max_safe_ns_f64,
    );
    return @intFromFloat(bounded_ns);
}

/// Call this before sleeping the main thread for the sleep to not count
/// against the calculated CPU time.
pub fn beginSleep(self: *FramePacer, io: Io) void {
    self.sleep_timer.reset(io);
}

/// See `beginSleep`.
pub fn endSleep(self: *FramePacer, io: Io) void {
    self.sleep_accum_s += @as(f32, @floatFromInt(self.sleep_timer.read(io).toNanoseconds())) / std.time.ns_per_s;
}

/// Returns the time last frame spent on CPU work, not including time spent
/// blocked on the GPU or time spent sleeping as accounted for by
/// `beginSleep`/`endSleep`.
pub fn cpuS(self: *const FramePacer) f32 {
    return self.raw_ds - self.slop_s - self.sleep_s;
}

/// Linear interpolation `a + (b - a) * t`. Inlined from mr_geom's tween —
/// the only mr_geom use, which the port drops.
fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// A monotonic, high performance timer. Adapted from the Timer class that
/// used to be in std (via mr_gpu's ext/Timer.zig).
///
/// Monotonicity is ensured by saturating on the most previous sample: while
/// timings reported are monotonic, they're not guaranteed to tick at a
/// steady rate as this is up to the underlying system.
const Timer = struct {
    const clock: Io.Clock = .boot;

    started: Io.Timestamp,
    previous: Io.Timestamp,

    fn start(io: Io) Timer {
        const current = Io.Timestamp.now(io, clock);
        return .{ .started = current, .previous = current };
    }

    /// Reads the timer value since start or the last reset.
    fn read(self: *Timer, io: Io) Io.Duration {
        return self.started.untilNow(io, clock);
    }

    /// Resets the timer value to 0/now.
    fn reset(self: *Timer, io: Io) void {
        self.started = self.sample(io);
    }

    /// Returns the current value of the timer, then resets it.
    fn lap(self: *Timer, io: Io) Io.Duration {
        const current = self.sample(io);
        defer self.started = current;
        return self.started.durationTo(current);
    }

    /// Returns an Io.Timestamp sampled at the callsite that is guaranteed
    /// to be monotonic with respect to the timer's starting point.
    fn sample(self: *Timer, io: Io) Io.Timestamp {
        const current = Io.Timestamp.now(io, clock);
        if (std.math.order(current.toNanoseconds(), self.previous.toNanoseconds()) == .gt) {
            self.previous = current;
        }
        return self.previous;
    }
};

test "update clears sleep for a tiny finite refresh rate" {
    var io_impl = Io.Threaded.init(std.testing.allocator, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var pacer = FramePacer.init(io, 60.0);
    pacer.refresh_rate_hz = 1e-20;
    pacer.sleep_ms = 4.0;

    try std.testing.expectEqual(@as(u64, 0), pacer.update(io, 0));
    try std.testing.expectEqual(@as(f32, 0.0), pacer.sleep_ms);
}

test "update clears sleep when the refresh period overflows" {
    var io_impl = Io.Threaded.init(std.testing.allocator, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var pacer = FramePacer.init(io, 60.0);
    pacer.refresh_rate_hz = 1e-40;
    pacer.sleep_ms = 4.0;

    try std.testing.expectEqual(@as(u64, 0), pacer.update(io, 0));
    try std.testing.expectEqual(@as(f32, 0.0), pacer.sleep_ms);
}

test "update keeps unknown refresh at the finite 60 Hz cap" {
    var io_impl = Io.Threaded.init(std.testing.allocator, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var pacer = FramePacer.init(io, 0.0);
    pacer.sleep_ms = 100.0;

    const sleep_ns = pacer.update(io, 0);
    try std.testing.expect(sleep_ns > 0);
    try std.testing.expect(sleep_ns <= 11_667_000);
}
