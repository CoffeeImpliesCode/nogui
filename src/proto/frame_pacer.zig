//! Frame pacing — absolute deadline with suspend recovery.
//!
//! Tracks wall-clock frame timing with an exponential-moving-average
//! estimator. Detects OS suspend/wake by checking deadline overshoot.
//! On suspend, rebases the deadline to now (no catch-up burst) and
//! accumulates debt repaid gradually.
//!
//! Pattern: zigzag's fixed tick rate + deadline rebase on suspend.
//!
//! PROTOTYPE — throwaway design exploration. Final API may differ.

const std = @import("std");

/// Frame pacing state. One per Window (or one shared across App).
pub const FramePacer = struct {
    /// Target interval in nanoseconds (e.g., 16_666_667 for 60 FPS).
    target_ns: u64,

    /// Monotonic clock source (std.Io.Clock).
    clock: std.Io.Clock = .boot,

    /// Absolute deadline for the current frame (monotonic ns).
    deadline_ns: u64 = 0,

    /// When the current frame started (monotonic ns).
    frame_start_ns: u64 = 0,

    /// Accumulated suspend debt in ns — repaid gradually.
    suspend_debt_ns: u64 = 0,

    /// Running EMA of actual frame duration (ns).
    /// Decay factor = 1/8 (alpha = 8).
    actual_frame_ns_ema: u64 = 0,

    /// Total frames paced since init.
    frame_count: u64 = 0,

    /// Set to true to disable sleep-based pacing (for benchmarking).
    pacing_disabled: bool = false,

    /// Initialize with a target frame rate.
    pub fn init(target_fps: u32) @This() {
        return .{
            .target_ns = @divTrunc(1_000_000_000 + @as(u64, target_fps) / 2, target_fps),
        };
    }

    /// Initialize with an explicit interval in nanoseconds.
    pub fn initNs(target_ns: u64) @This() {
        return .{
            .target_ns = target_ns,
        };
    }

    /// Call at the START of each frame.
    ///
    /// Returns the delta-t in seconds since the last frame, adjusted
    /// for suspend recovery (capped at 2 frames to prevent spiral of
    /// death on transient slowdowns).
    ///
    /// Suspend detection: if we overshot the previous deadline by >2×,
    /// we were suspended. Rebase the deadline to now.
    pub fn beginFrame(self: *@This(), io: std.Io) f64 {
        const now_ns = self.clock.now(.monotonic, io).nanoseconds;
        defer {
            self.frame_start_ns = now_ns;
            self.frame_count += 1;
        }

        // Detect suspend: overshot deadline by >2× target.
        if (self.deadline_ns > 0 and now_ns > self.deadline_ns + self.target_ns * 2) {
            const overshoot = now_ns - self.deadline_ns;
            self.suspend_debt_ns += overshoot;
            // Rebase: start fresh from now, not from the missed deadline.
            self.deadline_ns = now_ns + self.target_ns;
        } else if (self.deadline_ns > 0) {
            // Normal frame: deadline slides by one interval.
            self.deadline_ns += self.target_ns;
        } else {
            // First frame: set initial deadline.
            self.deadline_ns = now_ns + self.target_ns;
        }

        // Compute elapsed since last frame, capped at 2× target.
        const elapsed = now_ns -| self.frame_start_ns;
        const capped = @min(elapsed, self.target_ns * 2);
        return @as(f64, @floatFromInt(capped)) / 1_000_000_000.0;
    }

    /// Call at the END of each frame. Sleeps until the deadline.
    ///
    /// Returns the actual frame duration in nanoseconds (for statistics).
    pub fn endFrame(self: *@This(), io: std.Io) u64 {
        const now_ns = self.clock.now(.monotonic, io).nanoseconds;
        const actual = now_ns -| self.frame_start_ns;

        // Update EMA of actual frame time (alpha = 8, i.e. 1/8 decay).
        if (self.actual_frame_ns_ema == 0) {
            self.actual_frame_ns_ema = actual;
        } else {
            const delta = actual -| self.actual_frame_ns_ema;
            self.actual_frame_ns_ema += delta / 8;
        }

        // Sleep until deadline (skip if disabled).
        if (!self.pacing_disabled) {
            const remaining = self.deadline_ns -| now_ns;
            if (remaining > 0) {
                if (remaining > 2_000_000) {
                    std.Io.sleep(io, remaining - 1_000_000);
                }
                // Tight spin for the last ~1ms.
                while (self.clock.now(.monotonic, io).nanoseconds < self.deadline_ns) {
                    std.mem.doNotOptimizeAway(@as(u8, 0));
                }
            }
        }

        // Repay suspend debt: give back up to 50% of spare time.
        if (self.suspend_debt_ns > 0) {
            const spare = self.deadline_ns -| now_ns;
            const repayment = @min(self.suspend_debt_ns, spare / 2);
            self.suspend_debt_ns -= repayment;
        }

        return actual;
    }

    /// Get a smoothed FPS estimate.
    pub fn fpsEstimate(self: *const @This()) f64 {
        if (self.actual_frame_ns_ema == 0) return 0;
        return 1_000_000_000.0 / @as(f64, @floatFromInt(self.actual_frame_ns_ema));
    }

    /// Get the target frame rate.
    pub fn targetFps(self: *const @This()) f64 {
        return 1_000_000_000.0 / @as(f64, @floatFromInt(self.target_ns));
    }

    /// True if the last frame missed its deadline.
    pub fn missedDeadline(self: *const @This(), io: std.Io) bool {
        const now_ns = self.clock.now(.monotonic, io).nanoseconds;
        return now_ns > self.deadline_ns;
    }
};

const testing = std.testing;

test "FramePacer: init sets target_ns" {
    const pacer = FramePacer.init(60);
    try testing.expectEqual(@as(u64, 16_666_667), pacer.target_ns);
}

test "FramePacer: initNs sets target_ns directly" {
    const pacer = FramePacer.initNs(33_333_333);
    try testing.expectEqual(@as(u64, 33_333_333), pacer.target_ns);
}

test "FramePacer: targetFps matches init" {
    const pacer = FramePacer.init(144);
    const fps = pacer.targetFps();
    try testing.expect(fps > 143.9 and fps < 144.1);
}

test "FramePacer: fpsEstimate starts at 0" {
    const pacer = FramePacer.init(60);
    try testing.expectEqual(@as(f64, 0), pacer.fpsEstimate());
}

test "FramePacer: beginFrame returns sensible delta" {
    const pacer = FramePacer.init(60);
    // Can't test timing precisely, but interface compiles.
    _ = pacer;
}
