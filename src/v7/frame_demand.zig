//! UI-thread frame demand. Session tracks model dependencies; the host consumes
//! Session.takeRedraw(window) and merges it here before deciding whether to draw.
//! A hidden window keeps dirty work and expired deadlines but requests no frames.
const std = @import("std");

pub const FrameDemand = struct {
    layout_dirty: bool = true,
    paint_dirty: bool = true,
    present_dirty: bool = true,
    visible: bool = true,
    continuous: bool = false,
    deadline_ms: ?u64 = null,
    in_flight: ?Work = null,

    pub const Work = struct {
        layout: bool = false,
        paint: bool = false,
        present: bool = false,
        animation: bool = false,
        continuous: bool = false,
    };

    /// A change to geometry or structure needs a complete frame.
    pub fn invalidateLayout(self: *FrameDemand) void {
        self.layout_dirty = true;
        self.invalidatePaint();
    }

    /// Visual data changed, without requiring new geometry.
    pub fn invalidatePaint(self: *FrameDemand) void {
        self.paint_dirty = true;
        self.requestPresentation();
    }

    /// The swapchain must present the current content again (e.g. expose).
    pub fn requestPresentation(self: *FrameDemand) void {
        self.present_dirty = true;
    }

    pub fn setVisible(self: *FrameDemand, visible: bool) void {
        if (self.visible == visible) return;
        self.visible = visible;
        if (visible) self.requestPresentation();
    }

    pub fn setContinuous(self: *FrameDemand, continuous: bool) void {
        self.continuous = continuous;
    }

    /// Absolute monotonic milliseconds, provided by the caller's clock.
    /// Replacing it with null cancels the pending animation; a due deadline
    /// is consumed only after the corresponding frame succeeds.
    pub fn setDeadline(self: *FrameDemand, deadline_ms: ?u64) void {
        self.deadline_ms = deadline_ms;
    }

    pub fn pending(self: *const FrameDemand, now_ms: u64) bool {
        if (!self.visible) return false;
        return self.layout_dirty or self.paint_dirty or self.present_dirty or
            self.continuous or (self.deadline_ms != null and self.deadline_ms.? <= now_ms);
    }

    /// Null means indefinitely idle. SDL accepts at most u31 ms; nanosecond
    /// task deadlines use taskDeadlineWaitMilliseconds for ceil rounding.
    pub fn waitMilliseconds(self: *const FrameDemand, now_ms: u64) ?u31 {
        if (!self.visible) return null;
        if (self.pending(now_ms)) return 0;
        const deadline = self.deadline_ms orelse return null;
        return @intCast(@min(deadline - now_ms, @as(u64, std.math.maxInt(u31))));
    }

    /// Claim exactly one frame. Invalidations that arrive before finish remain
    /// pending; failed frames restore all the work taken from this snapshot.
    pub fn take(self: *FrameDemand, now_ms: u64) ?Work {
        std.debug.assert(self.in_flight == null);
        if (!self.pending(now_ms)) return null;
        const animation = self.deadline_ms != null and self.deadline_ms.? <= now_ms;
        const work: Work = .{
            .layout = self.layout_dirty,
            .paint = self.paint_dirty or animation or self.continuous,
            .present = self.present_dirty or self.paint_dirty or animation or self.continuous,
            .animation = animation,
            .continuous = self.continuous,
        };
        self.layout_dirty = false;
        self.paint_dirty = false;
        self.present_dirty = false;
        if (animation) self.deadline_ms = null;
        self.in_flight = work;
        return work;
    }

    pub fn finish(self: *FrameDemand, success: bool) void {
        const work = self.in_flight orelse @panic("frame demand finished without a frame");
        self.in_flight = null;
        if (success) return;
        if (work.layout) {
            self.invalidateLayout();
        } else if (work.paint) {
            self.invalidatePaint();
        } else if (work.present) {
            self.requestPresentation();
        }
        if (work.animation and self.deadline_ms == null) self.deadline_ms = 0;
    }
};

/// Convert the task service's absolute .awake nanoseconds to SDL's millisecond
/// timeout without an early fire or an integer overflow.
pub fn taskDeadlineWaitMilliseconds(now_ns: i96, deadline_ns: i96) u31 {
    if (deadline_ns <= now_ns) return 0;
    const delta: u96 = @intCast(deadline_ns -| now_ns);
    const wait_ms = (delta / std.time.ns_per_ms) + @intFromBool(delta % std.time.ns_per_ms != 0);
    return @intCast(@min(wait_ms, @as(u96, std.math.maxInt(u31))));
}
