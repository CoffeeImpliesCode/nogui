//! Declarative effect system — Cmd(Msg) for nogui.
//!
//! Inspired by bubbletea's tea.Cmd and zigzag's every/sleep.
//! A Cmd describes a side effect without executing it.
//! The runtime (TimerQueue) processes Cmds and delivers results
//! as Event messages on subsequent frames.
//!
//! This decouples animation timing from frame rate: animation
//! ticks are wall-clock, not frame-counter. A 144 Hz display
//! gets smoother animation without changing the tick interval.
//!
//! PROTOTYPE — throwaway design exploration. Final API may differ.

const std = @import("std");
const Event = @import("event.zig").Event;

/// A command that, when executed, produces zero or one Event messages.
///
/// Model: bubbletea `func (m Model) Update(msg Msg) (Model, Cmd)`.
/// A Cmd is a value, not a closure. The runtime interprets it.
pub const Cmd = union(enum) {
    /// No effect. Equivalent to nil in bubbletea.
    none: void,

    /// Fire an event immediately (next frame).
    immediate: Event,

    /// Fire an event after waiting a given number of frames.
    after_frames: struct {
        frames: u64,
        event: Event,
    },

    /// Fire an event after a wall-clock delay (milliseconds).
    sleep: struct {
        ms: u64,
        event: Event,
    },

    /// Fire an event every N frames, starting now.
    every_frame: struct {
        interval: u64,
        event: Event,
    },

    /// Fire an event every N milliseconds, starting now.
    every_ms: struct {
        interval_ms: u64,
        event: Event,
    },

    /// Run commands in sequence: A completes before B starts.
    sequence: struct {
        a: *Cmd,
        b: *Cmd,
    },

    /// Run all commands in parallel. All events fire on the same frame.
    batch: []const Cmd,

    /// Custom effect: runtime calls the callback.
    /// Callback receives an event sink and can push 0..N events.
    custom: *const fn (sink: *EventSink) callconv(.c) void,
};

/// A sink for pushing events during custom Cmd execution.
/// Simple wrapper around an ArrayList to avoid exposing allocator.
pub const EventSink = struct {
    events: *std.ArrayList(Event),

    pub fn push(self: *EventSink, event: Event) void {
        self.events.append(event) catch return;
    }
};

// ─── Timer Queue ─────────────────────────────

/// A single timer entry.
pub const TimerEntry = struct {
    /// Unique identifier for cancellation.
    id: u64,

    /// Message to emit when this timer fires.
    event: Event,

    /// Fire condition (frame-based or wall-clock).
    fire_type: union(enum) {
        frame: u64,
        ms: u64,
    },

    /// Recurring interval (0 = one-shot).
    interval_frames: u64 = 0,
    interval_ms: u64 = 0,

    /// Whether this timer is still active (cancelled timers are inactive).
    active: bool = true,
};

/// Manages a queue of timers. Called once per frame by App.run() to
/// advance time and produce events for any timers that have fired.
pub const TimerQueue = struct {
    entries: std.ArrayList(TimerEntry) = .empty,
    next_id: u64 = 1,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TimerQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TimerQueue) void {
        self.entries.deinit();
        self.* = undefined;
    }

    /// Add a Cmd to the timer queue. Returns the timer ID for cancellation.
    pub fn add(self: *TimerQueue, cmd: Cmd, now_frame: u64, now_ms: u64) !?u64 {
        const id = self.next_id;
        self.next_id += 1;

        switch (cmd) {
            .none => return null,
            .immediate => |ev| {
                try self.entries.append(.{
                    .id = id,
                    .event = ev,
                    .fire_type = .{ .frame = now_frame },
                    .active = true,
                });
                return id;
            },
            .after_frames => |af| {
                try self.entries.append(.{
                    .id = id,
                    .event = af.event,
                    .fire_type = .{ .frame = now_frame + af.frames },
                    .active = true,
                });
                return id;
            },
            .sleep => |s| {
                try self.entries.append(.{
                    .id = id,
                    .event = s.event,
                    .fire_type = .{ .ms = now_ms + s.ms },
                    .active = true,
                });
                return id;
            },
            .every_frame => |ef| {
                try self.entries.append(.{
                    .id = id,
                    .event = ef.event,
                    .fire_type = .{ .frame = now_frame + ef.interval },
                    .interval_frames = ef.interval,
                    .active = true,
                });
                return id;
            },
            .every_ms => |em| {
                try self.entries.append(.{
                    .id = id,
                    .event = em.event,
                    .fire_type = .{ .ms = now_ms + em.interval_ms },
                    .interval_ms = em.interval_ms,
                    .active = true,
                });
                return id;
            },
            .sequence => |seq| {
                _ = try self.add(seq.a.*, now_frame, now_ms);
                return try self.add(seq.b.*, now_frame, now_ms);
            },
            .batch => |batch| {
                for (batch) |sub| {
                    _ = try self.add(sub, now_frame, now_ms);
                }
                return id;
            },
            .custom => |cb| {
                var sink_events = std.ArrayList(Event).empty;
                defer sink_events.deinit();
                var sink = EventSink{
                    .events = &sink_events,
                };
                cb(&sink);
                for (sink_events.items) |ev| {
                    try self.entries.append(.{
                        .id = id,
                        .event = ev,
                        .fire_type = .{ .frame = now_frame },
                        .active = true,
                    });
                }
                return id;
            },
        }
    }

    /// Cancel a timer by ID. No-op if already fired or not found.
    pub fn cancel(self: *TimerQueue, id: u64) void {
        for (self.entries.items) |*entry| {
            if (entry.id == id) {
                entry.active = false;
                return;
            }
        }
    }

    /// Advance the timer queue. For each fired timer, appends its
    /// Event to `out_events` and either reschedules (recurring) or
    /// marks inactive (one-shot).
    pub fn advance(
        self: *TimerQueue,
        current_frame: u64,
        current_ms: u64,
        out_events: *std.ArrayList(Event),
    ) void {
        for (self.entries.items) |*entry| {
            if (!entry.active) continue;

            const fired = switch (entry.fire_type) {
                .frame => |f| current_frame >= f,
                .ms => |m| current_ms >= m,
            };

            if (fired) {
                out_events.append(entry.event) catch continue;

                if (entry.interval_frames > 0) {
                    // Recurring frame-based timer.
                    entry.fire_type = .{ .frame = current_frame + entry.interval_frames };
                } else if (entry.interval_ms > 0) {
                    // Recurring wall-clock timer.
                    entry.fire_type = .{ .ms = current_ms + entry.interval_ms };
                } else {
                    // One-shot: deactivate.
                    entry.active = false;
                }
            }
        }
    }

    /// Remove all inactive entries and compact.
    pub fn gc(self: *TimerQueue) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (!self.entries.items[i].active) {
                _ = self.entries.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

// ─── Tests ─────────────────────────────────

const testing = std.testing;

test "Cmd: none produces no timer" {
    var tq = TimerQueue.init(testing.allocator);
    defer tq.deinit();
    var events = std.ArrayList(Event).empty;
    defer events.deinit();
    tq.advance(0, 0, &events);
    try testing.expectEqual(@as(usize, 0), events.items.len);
}

test "Cmd: immediate fires same frame" {
    var tq = TimerQueue.init(testing.allocator);
    defer tq.deinit();
    _ = try tq.add(.{ .immediate = .{ .custom = .{ .id = 42, .data = 0 } } }, 0, 0);
    var events = std.ArrayList(Event).empty;
    defer events.deinit();
    tq.advance(0, 0, &events);
    try testing.expectEqual(@as(usize, 1), events.items.len);
}

test "Cmd: after_frames fires after N frames" {
    var tq = TimerQueue.init(testing.allocator);
    defer tq.deinit();
    _ = try tq.add(.{ .after_frames = .{ .frames = 3, .event = .{ .custom = .{ .id = 1, .data = 0 } } } }, 0, 0);
    var events = std.ArrayList(Event).empty;
    defer events.deinit();
    tq.advance(1, 0, &events); // not yet
    try testing.expectEqual(@as(usize, 0), events.items.len);
    tq.advance(3, 0, &events); // fires
    try testing.expectEqual(@as(usize, 1), events.items.len);
}

test "Cmd: every_frame recurs" {
    var tq = TimerQueue.init(testing.allocator);
    defer tq.deinit();
    _ = try tq.add(.{ .every_frame = .{ .interval = 5, .event = .{ .custom = .{ .id = 1, .data = 0 } } } }, 0, 0);
    var events = std.ArrayList(Event).empty;
    defer events.deinit();
    tq.advance(5, 0, &events);
    try testing.expectEqual(@as(usize, 1), events.items.len);
    tq.advance(10, 0, &events);
    try testing.expectEqual(@as(usize, 2), events.items.len);
}

test "Cmd: cancel removes timer" {
    var tq = TimerQueue.init(testing.allocator);
    defer tq.deinit();
    const id = (try tq.add(.{ .sleep = .{ .ms = 100, .event = .{ .custom = .{ .id = 1, .data = 0 } } } }, 0, 0)).?;
    tq.cancel(id);
    var events = std.ArrayList(Event).empty;
    defer events.deinit();
    tq.advance(0, 200, &events);
    try testing.expectEqual(@as(usize, 0), events.items.len);
}

test "TimerQueue: gc removes inactive" {
    var tq = TimerQueue.init(testing.allocator);
    defer tq.deinit();
    _ = try tq.add(.{ .immediate = .{ .custom = .{ .id = 1, .data = 0 } } }, 0, 0);
    _ = try tq.add(.{ .immediate = .{ .custom = .{ .id = 2, .data = 0 } } }, 0, 0);
    var events = std.ArrayList(Event).empty;
    defer events.deinit();
    tq.advance(0, 0, &events); // both fire → inactive
    try testing.expectEqual(@as(usize, 2), tq.entries.items.len);
    tq.gc();
    try testing.expectEqual(@as(usize, 0), tq.entries.items.len);
}
