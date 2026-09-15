const std = @import("std");
const v7_options = @import("v7_options");

const counter_count = std.meta.fields(Counter).len;

pub const Counter = enum {
    measure_requests,
    harfbuzz_shapes,
    hard_line_bytes_scanned,
    segment_bytes_scanned,
    segment_content_rescan_bytes,
    glyph_entry_comparisons,
    node_comparisons,
    svg_card_node_comparisons,
    hover_focus_node_comparisons,
    ancestor_reads,
    draw_cmd_value_bind_bytes,
    slice_rect_growth_events,
    slice_rect_growth_copy_bytes,
    svg_stroke_write_attempts,
    svg_stroke_writes,
};

pub const Counters = struct {
    values: [std.meta.fields(Counter).len]u64 = .{0} ** counter_count,
    overflowed: bool = false,

    pub fn reset(self: *Counters) void {
        self.values = .{0} ** counter_count;
        self.overflowed = false;
    }

    pub fn add(self: *Counters, counter: Counter, amount: u64) void {
        const index = @intFromEnum(counter);
        const current = self.values[index];
        if (std.math.maxInt(u64) - current < amount) {
            self.overflowed = true;
            return;
        }
        self.values[index] = current + amount;
    }

    pub fn snapshot(self: *const Counters) error{CounterOverflow}!Snapshot {
        if (self.overflowed) return error.CounterOverflow;
        return .{ .values = self.values };
    }
};

pub const Snapshot = struct {
    values: [std.meta.fields(Counter).len]u64,

    pub fn value(self: *const Snapshot, counter: Counter) u64 {
        return self.values[@intFromEnum(counter)];
    }

    pub fn writeJson(self: *const Snapshot, writer: anytype) !void {
        try writer.writeByte('{');
        inline for (std.meta.fields(Counter), 0..) |field, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.print("\"{s}\":{d}", .{ field.name, self.values[index] });
        }
        try writer.writeByte('}');
    }
};

pub fn Sink(comptime enabled: bool) type {
    return if (enabled) struct {
        counters: ?*Counters,

        const Self = @This();

        pub fn init(counters: ?*Counters) Self {
            return .{ .counters = counters };
        }

        pub fn add(self: *const Self, counter: Counter, amount: u64) void {
            if (self.counters) |counters| counters.add(counter, amount);
        }

        pub fn pointer(self: *const Self) ?*Counters {
            return self.counters;
        }
    } else struct {
        const Self = @This();

        pub fn init(_: ?*Counters) Self {
            return .{};
        }

        pub fn add(_: *const Self, _: Counter, _: u64) void {}

        pub fn pointer(_: *const Self) ?*Counters {
            return null;
        }
    };
}

pub const CounterSink = Sink(v7_options.perf_counters);

comptime {
    std.debug.assert(std.meta.fields(Counter).len == 15);
    std.debug.assert(@sizeOf(Sink(false)) == 0);
    std.debug.assert(@sizeOf(Sink(true)) == @sizeOf(*Counters));
}

test "perf counters preserve declaration order in JSON" {
    var counters: Counters = .{};
    counters.add(.measure_requests, 3);
    counters.add(.svg_stroke_writes, 7);
    const snapshot = try counters.snapshot();

    var bytes: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try snapshot.writeJson(&writer);
    try std.testing.expectEqualStrings(
        "{\"measure_requests\":3,\"harfbuzz_shapes\":0,\"hard_line_bytes_scanned\":0," ++
            "\"segment_bytes_scanned\":0,\"segment_content_rescan_bytes\":0," ++
            "\"glyph_entry_comparisons\":0,\"node_comparisons\":0," ++
            "\"svg_card_node_comparisons\":0,\"hover_focus_node_comparisons\":0," ++
            "\"ancestor_reads\":0,\"draw_cmd_value_bind_bytes\":0," ++
            "\"slice_rect_growth_events\":0,\"slice_rect_growth_copy_bytes\":0," ++
            "\"svg_stroke_write_attempts\":0,\"svg_stroke_writes\":7}",
        writer.buffered(),
    );
}

test "perf counters snapshot survives reset" {
    var counters: Counters = .{};
    counters.add(.measure_requests, 9);
    const snapshot = try counters.snapshot();
    counters.reset();
    try std.testing.expectEqual(@as(u64, 9), snapshot.value(.measure_requests));
    try std.testing.expectEqual(@as(u64, 0), counters.values[@intFromEnum(Counter.measure_requests)]);
}

test "perf counters accept exact maximum before overflow" {
    var counters: Counters = .{};
    counters.values[@intFromEnum(Counter.measure_requests)] = std.math.maxInt(u64) - 2;
    counters.add(.measure_requests, 2);
    try std.testing.expect(!counters.overflowed);
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        counters.values[@intFromEnum(Counter.measure_requests)],
    );
    counters.add(.measure_requests, 1);
    try std.testing.expect(counters.overflowed);
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        counters.values[@intFromEnum(Counter.measure_requests)],
    );
}

test "enabled perf sink forwards additions" {
    var counters: Counters = .{};
    var sink = Sink(true).init(&counters);
    sink.add(.harfbuzz_shapes, 4);
    try std.testing.expectEqual(@as(u64, 4), counters.values[@intFromEnum(Counter.harfbuzz_shapes)]);
}

test "perf counters reset clears values and overflow" {
    var counters: Counters = .{};
    counters.add(.measure_requests, 9);
    counters.overflowed = true;
    counters.reset();
    try std.testing.expectEqual(@as(u64, 0), counters.values[@intFromEnum(Counter.measure_requests)]);
    try std.testing.expect(!counters.overflowed);
}

test "perf counters reject overflow without writing" {
    var counters: Counters = .{};
    counters.values[@intFromEnum(Counter.measure_requests)] = std.math.maxInt(u64);
    counters.add(.measure_requests, 1);
    try std.testing.expect(counters.overflowed);
    try std.testing.expectEqual(std.math.maxInt(u64), counters.values[@intFromEnum(Counter.measure_requests)]);
    try std.testing.expectError(error.CounterOverflow, counters.snapshot());
}

test "disabled perf sink is zero-sized and inert" {
    var counters: Counters = .{};
    var sink = Sink(false).init(&counters);
    sink.add(.measure_requests, 5);
    try std.testing.expectEqual(@as(u64, 0), counters.values[@intFromEnum(Counter.measure_requests)]);
}
