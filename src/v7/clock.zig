//! Monotonic task time, with a caller-controlled clock for deterministic tests.
const std = @import("std");

pub const Clock = union(enum) {
    io: std.Io,
    source: Source,

    pub const Source = struct {
        context: *anyopaque,
        now_ns: *const fn (*anyopaque) i96,
    };

    pub fn monotonic(io: std.Io) Clock {
        return .{ .io = io };
    }

    pub fn injected(context: *anyopaque, now_ns: *const fn (*anyopaque) i96) Clock {
        return .{ .source = .{ .context = context, .now_ns = now_ns } };
    }

    pub fn now(self: Clock) i96 {
        return switch (self) {
            .io => |io| std.Io.Timestamp.now(io, .awake).nanoseconds,
            .source => |source| source.now_ns(source.context),
        };
    }
};
