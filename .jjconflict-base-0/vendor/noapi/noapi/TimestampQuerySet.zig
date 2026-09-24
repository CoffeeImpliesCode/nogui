//! Generic GPU timestamp query sets independent of Tracy.

const std = @import("std");
const Gpu = @import("Gpu.zig").Gpu;

pub const TimestampStage = enum {
    all_commands_start,
    all_commands_end,
};

pub const TimestampInfo = struct {
    period_ns: f64,
    valid_bits: u7,

    pub fn mask(self: TimestampInfo) u64 {
        if (self.valid_bits == 64) return std.math.maxInt(u64);
        if (self.valid_bits == 0) return 0;
        return (@as(u64, 1) << @intCast(self.valid_bits)) - 1;
    }

    pub fn spanTicks(self: TimestampInfo, start_ticks: u64, end_ticks: u64) u64 {
        const timestamp_mask = self.mask();
        const start = start_ticks & timestamp_mask;
        const end = end_ticks & timestamp_mask;
        if (end >= start) return end - start;
        return timestamp_mask - start + 1 + end;
    }
};

pub const TimestampQuerySet = struct {
    gpu: *Gpu,
    handle: Gpu.TimestampQueryHandle,
    count: u32,
};

pub fn validateQueryRange(set_count: u32, first: u32, count: u32) !void {
    if (count == 0) return error.InvalidTimestampRange;
    const end = @addWithOverflow(first, count);
    if (end[1] != 0) return error.InvalidTimestampRange;
    if (end[0] > set_count) return error.InvalidTimestampRange;
}

test "timestamp info computes valid masks and modular spans" {
    const one_bit: TimestampInfo = .{ .period_ns = 1.0, .valid_bits = 1 };
    try std.testing.expectEqual(@as(u64, 1), one_bit.mask());
    try std.testing.expectEqual(@as(u64, 1), one_bit.spanTicks(1, 0));

    const thirty_two_bit: TimestampInfo = .{ .period_ns = 1.0, .valid_bits = 32 };
    try std.testing.expectEqual(@as(u64, 0xffff_ffff), thirty_two_bit.mask());
    try std.testing.expectEqual(@as(u64, 3), thirty_two_bit.spanTicks(0xffff_fffe, 1));

    const sixty_four_bit: TimestampInfo = .{ .period_ns = 1.0, .valid_bits = 64 };
    try std.testing.expectEqual(std.math.maxInt(u64), sixty_four_bit.mask());
    try std.testing.expectEqual(
        @as(u64, 3),
        sixty_four_bit.spanTicks(std.math.maxInt(u64) - 1, 1),
    );
}

test "timestamp query ranges reject zero overflow and out of range spans" {
    try std.testing.expectError(error.InvalidTimestampRange, validateQueryRange(4, 0, 0));
    try std.testing.expectError(
        error.InvalidTimestampRange,
        validateQueryRange(4, std.math.maxInt(u32), 2),
    );
    try std.testing.expectError(error.InvalidTimestampRange, validateQueryRange(4, 3, 2));
    try validateQueryRange(4, 1, 3);
}
