//! Monotonic virtual time for the production task service and headless driver.
const std = @import("std");
const Clock = @import("nogui").Clock;

pub const VirtualClock = struct {
    now_ns: i96 = 0,

    pub fn injected(self: *VirtualClock) Clock {
        return Clock.injected(self, readNow);
    }

    fn readNow(raw: *anyopaque) i96 {
        const self: *VirtualClock = @ptrCast(@alignCast(raw));
        return self.now_ns;
    }

    pub fn now(self: *const VirtualClock) i96 {
        return self.now_ns;
    }

    /// Time never runs backward. A later call can observe all due work.
    pub fn advanceTo(self: *VirtualClock, target_ns: i96) error{TimeWentBackwards}!void {
        if (target_ns < self.now_ns) return error.TimeWentBackwards;
        self.now_ns = target_ns;
    }

    pub fn advanceBy(self: *VirtualClock, delta_ns: u64) error{TimeOverflow}!void {
        self.now_ns = std.math.add(i96, self.now_ns, @as(i96, delta_ns)) catch
            return error.TimeOverflow;
    }

    pub fn advanceToMs(self: *VirtualClock, target_ms: u64) error{TimeWentBackwards}!void {
        // A u64 count of milliseconds fits in signed i96 nanoseconds.
        try self.advanceTo(@as(i96, target_ms) * std.time.ns_per_ms);
    }
};
