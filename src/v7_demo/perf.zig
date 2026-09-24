const std = @import("std");
const testing = std.testing;
const nogui = @import("nogui");
const perf_counters = struct {
    pub const Counter = nogui.Counter;
    pub const Snapshot = nogui.Snapshot;
};
const v7_options = nogui.options;

pub const Mode = enum {
    offscreen,
    presented,
};

pub const Config = struct {
    mode: Mode,
    warmup_frames: u32 = 240,
    sample_frames: u32 = 1000,
    output_path: []const u8,

    pub fn validate(config: Config) error{ InvalidPerfFrames, InvalidPerfOutput }!Config {
        if (config.sample_frames == 0) return error.InvalidPerfFrames;
        if (config.warmup_frames > std.math.maxInt(u32) - config.sample_frames) {
            return error.InvalidPerfFrames;
        }
        if (config.output_path.len == 0) return error.InvalidPerfOutput;
        return config;
    }

    pub fn totalFrames(config: Config) error{ InvalidPerfFrames, InvalidPerfOutput }!u32 {
        const validated = try validate(config);
        return validated.warmup_frames + validated.sample_frames;
    }
};

pub const Phase = enum {
    warmup,
    sample,
};

pub const slot_count: u64 = 3;

/// Return the timeline value required before reusing a three-slot target.
/// The first three frames have no predecessor in the ring and therefore do
/// not wait. A submitted frame signals `frame_id + 1`.
pub fn slotWaitValue(frame_id: u64, slots: u64) ?u64 {
    if (slots == 0 or frame_id < slots) return null;
    return frame_id - slots + 1;
}

pub const SlotScheduler = struct {
    last_frame_id: ?u64 = null,
    last_timeline_value: ?u64 = null,

    pub fn next(
        self: *SlotScheduler,
        frame_id: u64,
        timeline_value: u64,
        slots: u64,
    ) error{
        InvalidSlotCount,
        NonMonotonicFrameId,
        NonMonotonicTimelineValue,
    }!?u64 {
        if (slots == 0) return error.InvalidSlotCount;
        if (self.last_frame_id) |previous| {
            if (frame_id <= previous) return error.NonMonotonicFrameId;
        }
        if (self.last_timeline_value) |previous| {
            if (timeline_value <= previous) return error.NonMonotonicTimelineValue;
        }
        self.last_frame_id = frame_id;
        self.last_timeline_value = timeline_value;
        return slotWaitValue(frame_id, slots);
    }
};

pub const QuerySlotScheduler = struct {
    frame_ids: [slot_count]?u64 = .{ null, null, null },

    pub fn begin(self: *QuerySlotScheduler, frame_id: u64) error{QuerySlotMismatch}!?u64 {
        if (frame_id < slot_count) return null;
        const slot: usize = @intCast(frame_id % slot_count);
        const expected_frame_id = frame_id - slot_count;
        const completed_frame_id = self.frame_ids[slot] orelse return error.QuerySlotMismatch;
        if (completed_frame_id != expected_frame_id) return error.QuerySlotMismatch;
        self.frame_ids[slot] = null;
        return completed_frame_id;
    }

    pub fn submitted(self: *QuerySlotScheduler, frame_id: u64) error{QuerySlotBusy}!void {
        const slot: usize = @intCast(frame_id % slot_count);
        if (self.frame_ids[slot] != null) return error.QuerySlotBusy;
        self.frame_ids[slot] = frame_id;
    }
};

pub const PresentIdTracker = struct {
    last_present_id: u64 = 0,

    pub fn observe(self: *PresentIdTracker, present_id: u64) error{
        InvalidPresentationId,
        DuplicatePresentationId,
        NonMonotonicPresentationId,
    }!void {
        if (present_id == 0) return error.InvalidPresentationId;
        if (present_id == self.last_present_id) return error.DuplicatePresentationId;
        if (present_id < self.last_present_id) return error.NonMonotonicPresentationId;
        self.last_present_id = present_id;
    }
};

pub const FrameSample = struct {
    phase: Phase,
    frame_id: u64,
    cpu_app_layout_ns: u64,
    cpu_scene_ns: u64,
    cpu_record_ns: u64,
    cpu_submit_present_ns: u64,
    cpu_compute_ns: u64,
    cpu_acquire_ns: ?u64 = null,
    cpu_slot_wait_ns: ?u64 = null,
    cpu_present_slop_ns: ?u64 = null,
    gpu_execute_ns: ?u64 = null,
    gpu_end_interval_ns: ?u64 = null,
    mechanisms: if (v7_options.perf_counters) perf_counters.Snapshot else void,
    present_interval_ns: ?u64 = null,
    slop_ns: u64,

    pub fn empty(phase: Phase, frame_id: u64) FrameSample {
        return .{
            .phase = phase,
            .frame_id = frame_id,
            .cpu_app_layout_ns = 0,
            .cpu_scene_ns = 0,
            .cpu_record_ns = 0,
            .cpu_submit_present_ns = 0,
            .cpu_compute_ns = 0,
            .mechanisms = if (v7_options.perf_counters)
                .{ .values = .{0} ** std.meta.fields(perf_counters.Counter).len }
            else {},
            .slop_ns = 0,
        };
    }
};

pub const RecorderError = error{
    OutOfMemory,
    TooManySamples,
    DuplicateFrameMetric,
    InvalidFrameId,
    InvalidFrame,
    MissingFrameMetric,
    TimestampOverflow,
    TimestampUnderflow,
    InvalidTimestamp,
    InvalidTimestampPeriod,
    TimestampConversionOverflow,
    PresentTimestampNotIncreasing,
    PartialPresentFeedback,
    InvalidPresentationId,
    DuplicatePresentationId,
    NonMonotonicPresentationId,
    PresentModeRequired,
    PresentSlopTooLarge,
    GpuTimestampsDisabled,
    InvalidFrameCount,
};
pub const RecorderWriteError = RecorderError || std.Io.Writer.Error;

pub fn checkedAdd(lhs: u64, rhs: u64) error{TimestampOverflow}!u64 {
    const result = @addWithOverflow(lhs, rhs);
    if (result[1] != 0) return error.TimestampOverflow;
    return result[0];
}

pub fn presentIdForFrame(base: u64, frame_id: u64) error{TimestampOverflow}!u64 {
    return checkedAdd(base, frame_id);
}

pub fn frameIdForPresentId(
    present_id: u64,
    base: u64,
    total_frames: u64,
) RecorderError!u64 {
    if (present_id < base) return error.InvalidPresentationId;
    const frame_id = present_id - base;
    if (frame_id >= total_frames) return error.InvalidFrameId;
    return frame_id;
}

pub const PresentPreflightError = error{
    TimestampOverflow,
    PresentTimingFallbackLimit,
};

pub const PresentPreflightIds = struct {
    reserved_id: u64 = 1,
    fallback_attempts: u8 = 0,

    const max_fallback_attempts: u8 = 1;

    pub fn reservedId(self: *const PresentPreflightIds) u64 {
        return self.reserved_id;
    }

    pub fn recordedBase(self: *const PresentPreflightIds) PresentPreflightError!u64 {
        return presentIdForFrame(self.reserved_id, 1);
    }

    pub fn afterUnavailable(
        self: *PresentPreflightIds,
        timing_supported: bool,
    ) PresentPreflightError!?u64 {
        if (!timing_supported) return null;
        if (self.fallback_attempts >= max_fallback_attempts) {
            return error.PresentTimingFallbackLimit;
        }
        self.reserved_id = try checkedAdd(self.reserved_id, 1);
        self.fallback_attempts += 1;
        return self.reserved_id;
    }
};

pub const present_preflight_deadline_ns: u64 = 5_000_000_000;

pub fn presentPreflightDeadlineExpired(elapsed_ns: u64) bool {
    return elapsed_ns >= present_preflight_deadline_ns;
}

pub const PresentPreflightState = struct {
    ids: PresentPreflightIds = .{},
    mode_epoch: u8 = 0,

    pub fn reservedId(self: *const PresentPreflightState) u64 {
        return self.ids.reservedId();
    }

    pub fn recordedBase(self: *const PresentPreflightState) PresentPreflightError!u64 {
        return self.ids.recordedBase();
    }

    pub fn deadlineExpired(_: *const PresentPreflightState, elapsed_ns: u64) bool {
        return presentPreflightDeadlineExpired(elapsed_ns);
    }

    pub fn afterUnavailable(
        self: *PresentPreflightState,
        timing_supported: bool,
    ) PresentPreflightError!?u64 {
        const fallback_id = try self.ids.afterUnavailable(timing_supported);
        if (fallback_id != null) {
            const result = @addWithOverflow(self.mode_epoch, @as(u8, 1));
            if (result[1] != 0) return error.TimestampOverflow;
            self.mode_epoch = result[0];
        }
        return fallback_id;
    }

    pub fn modeEpoch(self: *const PresentPreflightState) u8 {
        return self.mode_epoch;
    }
};

pub fn checkedSub(lhs: u64, rhs: u64) error{TimestampUnderflow}!u64 {
    if (rhs > lhs) return error.TimestampUnderflow;
    return lhs - rhs;
}

pub fn computeNs(sample: *const FrameSample) RecorderError!u64 {
    const present_slop_ns = sample.cpu_present_slop_ns orelse 0;
    if (present_slop_ns > sample.cpu_submit_present_ns) {
        return error.PresentSlopTooLarge;
    }
    const submit_ns = try checkedSub(sample.cpu_submit_present_ns, present_slop_ns);
    var result = try checkedAdd(sample.cpu_app_layout_ns, sample.cpu_scene_ns);
    result = try checkedAdd(result, sample.cpu_record_ns);
    result = try checkedAdd(result, submit_ns);
    return result;
}

pub fn presentSlopNs(before_ns: u64, after_ns: u64, submit_ns: u64) RecorderError!u64 {
    const slop_ns = try checkedSub(after_ns, before_ns);
    if (slop_ns > submit_ns) return error.PresentSlopTooLarge;
    return slop_ns;
}

pub fn modularTickDelta(start_ticks: u64, end_ticks: u64, valid_bits: u8) RecorderError!u64 {
    if (valid_bits == 0 or valid_bits > 64) return error.InvalidTimestamp;
    const mask = if (valid_bits == 64)
        std.math.maxInt(u64)
    else
        (@as(u64, 1) << @intCast(valid_bits)) - 1;
    const start = start_ticks & mask;
    const end = end_ticks & mask;
    if (end >= start) return end - start;
    if (valid_bits == 64) {
        return (~start + 1) + end;
    }
    return (mask - start) + 1 + end;
}

pub fn ticksToNs(ticks: u64, timestamp_period: f64) RecorderError!u64 {
    if (!std.math.isFinite(timestamp_period)) return error.InvalidTimestampPeriod;
    if (timestamp_period <= 0.0) return error.InvalidTimestampPeriod;
    const nanoseconds = @as(f64, @floatFromInt(ticks)) * timestamp_period;
    if (!std.math.isFinite(nanoseconds) or nanoseconds < 0.0) {
        return error.TimestampConversionOverflow;
    }
    const rounded = @round(nanoseconds);
    // 2^64 - 2048 is the largest u64-adjacent integer exactly representable by f64.
    if (rounded > 18_446_744_073_709_549_568.0) {
        return error.TimestampConversionOverflow;
    }
    return @intFromFloat(rounded);
}

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    samples: []FrameSample,
    count: usize = 0,
    next_gpu_frame_id: u64 = 0,
    next_present_frame_id: u64 = 0,
    last_gpu_end_ticks: ?u64 = null,
    last_gpu_valid_bits: ?u8 = null,
    last_gpu_timestamp_period: ?f64 = null,
    last_present_timestamp_ns: ?u64 = null,
    mode: Mode = .offscreen,
    presentation_timing_supported: bool = true,

    pub fn init(allocator: std.mem.Allocator, expected_frames: u64) RecorderError!Recorder {
        const frame_count = std.math.cast(usize, expected_frames) orelse {
            return error.InvalidFrameCount;
        };
        if (frame_count == 0) return error.InvalidFrameCount;
        const samples = try allocator.alloc(FrameSample, frame_count);
        errdefer allocator.free(samples);
        for (samples, 0..) |*sample, index| {
            sample.* = FrameSample.empty(.warmup, @intCast(index));
        }
        return .{
            .allocator = allocator,
            .samples = samples,
        };
    }

    pub fn deinit(self: *Recorder) void {
        self.allocator.free(self.samples);
        self.* = undefined;
    }

    pub fn setMode(self: *Recorder, mode: Mode) void {
        self.mode = mode;
    }

    pub fn setPresentationTimingSupported(self: *Recorder, supported: bool) void {
        self.presentation_timing_supported = supported;
    }
    pub fn markPresentTimingUnavailable(self: *Recorder) RecorderError!void {
        if (self.mode != .presented) return error.PresentModeRequired;
        if (self.count != self.samples.len) return error.MissingFrameMetric;
        if (self.next_present_frame_id != 0) return error.PartialPresentFeedback;
        self.presentation_timing_supported = false;
        while (self.next_present_frame_id < @as(u64, @intCast(self.samples.len))) : (self.next_present_frame_id += 1) {}
    }

    pub fn append(self: *Recorder, sample: FrameSample) RecorderError!void {
        if (self.count == self.samples.len) return error.TooManySamples;
        if (sample.frame_id != @as(u64, @intCast(self.count))) return error.InvalidFrameId;
        if (sample.phase == .warmup) {
            var index: usize = 0;
            while (index < self.count) : (index += 1) {
                if (self.samples[index].phase == .sample) return error.InvalidFrame;
            }
        }
        if (try computeNs(&sample) != sample.cpu_compute_ns) return error.InvalidFrame;
        if (self.mode == .offscreen) {
            if (sample.cpu_present_slop_ns != null) return error.InvalidFrame;
            if (sample.cpu_acquire_ns != null) return error.InvalidFrame;
            if (sample.cpu_slot_wait_ns) |slot_wait_ns| {
                if (slot_wait_ns != sample.slop_ns) return error.InvalidFrame;
            }
        } else {
            const present_slop_ns = sample.cpu_present_slop_ns orelse return error.MissingFrameMetric;
            if (present_slop_ns > sample.cpu_submit_present_ns) return error.PresentSlopTooLarge;
            if (sample.cpu_acquire_ns == null) return error.MissingFrameMetric;
            if (sample.cpu_slot_wait_ns != null) return error.InvalidFrame;
        }
        self.samples[self.count] = sample;
        self.count += 1;
    }

    fn sampleAt(self: *Recorder, frame_id: u64) RecorderError!*FrameSample {
        const index = std.math.cast(usize, frame_id) orelse return error.InvalidFrameId;
        if (index >= self.count) return error.InvalidFrameId;
        if (self.samples[index].frame_id != frame_id) return error.InvalidFrameId;
        return &self.samples[index];
    }

    pub fn attachGpu(
        self: *Recorder,
        frame_id: u64,
        start_ticks: u64,
        end_ticks: u64,
        timestamp_period: f64,
        valid_bits: u8,
    ) RecorderError!void {
        if (!v7_options.gpu_timestamps) return error.GpuTimestampsDisabled;
        if (frame_id < self.next_gpu_frame_id) return error.DuplicateFrameMetric;
        if (frame_id != self.next_gpu_frame_id) return error.InvalidFrameId;
        const sample = try self.sampleAt(frame_id);
        if (sample.gpu_execute_ns != null or sample.gpu_end_interval_ns != null) {
            return error.DuplicateFrameMetric;
        }
        if (self.last_gpu_valid_bits) |previous_bits| {
            if (previous_bits != valid_bits) return error.InvalidTimestamp;
        }
        if (self.last_gpu_timestamp_period) |previous_period| {
            if (previous_period != timestamp_period) return error.InvalidTimestampPeriod;
        }
        const execute_ticks = try modularTickDelta(start_ticks, end_ticks, valid_bits);
        sample.gpu_execute_ns = try ticksToNs(execute_ticks, timestamp_period);
        if (self.last_gpu_end_ticks) |previous_end_ticks| {
            const interval_ticks = try modularTickDelta(previous_end_ticks, end_ticks, valid_bits);
            sample.gpu_end_interval_ns = try ticksToNs(interval_ticks, timestamp_period);
        }
        self.last_gpu_end_ticks = end_ticks;
        self.last_gpu_valid_bits = valid_bits;
        self.last_gpu_timestamp_period = timestamp_period;
        self.next_gpu_frame_id = try checkedAdd(self.next_gpu_frame_id, 1);
    }

    pub fn attachPresent(
        self: *Recorder,
        frame_id: u64,
        actual_timestamp_ns: u64,
    ) RecorderError!void {
        if (self.mode != .presented) return error.PresentModeRequired;
        if (frame_id < self.next_present_frame_id) return error.DuplicateFrameMetric;
        if (frame_id != self.next_present_frame_id) return error.InvalidFrameId;
        const sample = try self.sampleAt(frame_id);
        if (sample.present_interval_ns != null) return error.DuplicateFrameMetric;
        if (!self.presentation_timing_supported) {
            self.next_present_frame_id = try checkedAdd(self.next_present_frame_id, 1);
            return;
        }
        if (self.last_present_timestamp_ns) |previous_timestamp_ns| {
            if (actual_timestamp_ns <= previous_timestamp_ns) {
                return error.PresentTimestampNotIncreasing;
            }
            sample.present_interval_ns = try checkedSub(actual_timestamp_ns, previous_timestamp_ns);
        }
        self.last_present_timestamp_ns = actual_timestamp_ns;
        self.next_present_frame_id = try checkedAdd(self.next_present_frame_id, 1);
    }

    pub fn validateComplete(self: *const Recorder) RecorderError!void {
        if (self.count != self.samples.len) return error.MissingFrameMetric;
        var index: usize = 0;
        var saw_sample = false;
        while (index < self.samples.len) : (index += 1) {
            const sample = &self.samples[index];
            if (sample.frame_id != @as(u64, @intCast(index))) return error.InvalidFrameId;
            if (sample.phase == .sample) saw_sample = true;
            if (sample.phase == .warmup and saw_sample) return error.InvalidFrame;
            if (try computeNs(sample) != sample.cpu_compute_ns) return error.InvalidFrame;
            if (self.mode == .offscreen) {
                const slot_wait_ns = sample.cpu_slot_wait_ns orelse return error.MissingFrameMetric;
                if (sample.slop_ns != slot_wait_ns) return error.InvalidFrame;
                if (sample.cpu_acquire_ns != null) return error.InvalidFrame;
                if (sample.cpu_present_slop_ns != null) return error.InvalidFrame;
                if (sample.present_interval_ns != null) return error.InvalidFrame;
            } else {
                if (sample.cpu_acquire_ns == null) return error.MissingFrameMetric;
                const present_slop_ns = sample.cpu_present_slop_ns orelse return error.MissingFrameMetric;
                if (present_slop_ns > sample.cpu_submit_present_ns) return error.PresentSlopTooLarge;
                if (sample.cpu_slot_wait_ns != null) return error.InvalidFrame;
                if (self.presentation_timing_supported) {
                    if (index == 0 and sample.present_interval_ns != null) {
                        return error.InvalidFrame;
                    }
                    if (index != 0 and sample.present_interval_ns == null) {
                        return error.MissingFrameMetric;
                    }
                } else if (sample.present_interval_ns != null) {
                    return error.InvalidFrame;
                }
            }
            if (v7_options.gpu_timestamps) {
                if (sample.gpu_execute_ns == null) return error.MissingFrameMetric;
                if (index == 0 and sample.gpu_end_interval_ns != null) {
                    return error.InvalidFrame;
                }
                if (index != 0 and sample.gpu_end_interval_ns == null) {
                    return error.MissingFrameMetric;
                }
            } else if (sample.gpu_execute_ns != null or sample.gpu_end_interval_ns != null) {
                return error.InvalidFrame;
            }
        }
        if (v7_options.gpu_timestamps and self.next_gpu_frame_id != @as(u64, @intCast(self.samples.len))) {
            return error.MissingFrameMetric;
        }
        if (self.mode == .presented and self.next_present_frame_id != @as(u64, @intCast(self.samples.len))) {
            return error.MissingFrameMetric;
        }
        if (!saw_sample) return error.MissingFrameMetric;
    }

    fn writeOptional(writer: *std.Io.Writer, value: ?u64) !void {
        if (value) |number| {
            try writer.print("{d}", .{number});
        } else {
            try writer.writeAll("null");
        }
    }

    fn writeSample(sample: *const FrameSample, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"phase\":\"");
        try writer.writeAll(if (sample.phase == .warmup) "warmup" else "sample");
        try writer.print(
            "\",\"frame_id\":{d},\"cpu_app_layout_ns\":{d}," ++
                "\"cpu_scene_ns\":{d},\"cpu_record_ns\":{d}," ++
                "\"cpu_submit_present_ns\":{d},\"cpu_compute_ns\":{d}," ++
                "\"cpu_acquire_ns\":",
            .{
                sample.frame_id,
                sample.cpu_app_layout_ns,
                sample.cpu_scene_ns,
                sample.cpu_record_ns,
                sample.cpu_submit_present_ns,
                sample.cpu_compute_ns,
            },
        );
        try writeOptional(writer, sample.cpu_acquire_ns);
        try writer.writeAll(",\"cpu_slot_wait_ns\":");
        try writeOptional(writer, sample.cpu_slot_wait_ns);
        try writer.writeAll(",\"cpu_present_slop_ns\":");
        try writeOptional(writer, sample.cpu_present_slop_ns);
        try writer.writeAll(",\"gpu_execute_ns\":");
        try writeOptional(writer, sample.gpu_execute_ns);
        try writer.writeAll(",\"gpu_end_interval_ns\":");
        try writeOptional(writer, sample.gpu_end_interval_ns);
        if (v7_options.perf_counters) {
            try writer.writeAll(",\"mechanisms\":");
            try sample.mechanisms.writeJson(writer);
        }
        try writer.writeAll(",\"present_interval_ns\":");
        try writeOptional(writer, sample.present_interval_ns);
        try writer.print(",\"slop_ns\":{d}}}\n", .{sample.slop_ns});
    }

    pub fn writeJsonl(self: *const Recorder, writer: *std.Io.Writer) RecorderWriteError!void {
        try self.validateComplete();
        for (self.samples) |*sample| {
            try writeSample(sample, writer);
        }
    }

    pub fn writeJsonlWithHeader(
        self: *const Recorder,
        header_json: []const u8,
        writer: *std.Io.Writer,
    ) RecorderWriteError!void {
        try self.validateComplete();
        try writer.writeAll(header_json);
        try writer.writeByte('\n');
        for (self.samples) |*sample| {
            try writeSample(sample, writer);
        }
    }
};

pub const CliRequest = struct {
    mode: ?Mode = null,
    warmup_frames: ?u32 = null,
    sample_frames: ?u32 = null,
    output_path: ?[]const u8 = null,
    duplicate_flag: bool = false,
    scene_flag_count: u32 = 0,
    conflicting_flag: bool = false,
};

pub fn parseConfig(request: CliRequest) error{
    DuplicatePerfFlag,
    MultiplePerfScenes,
    PerfModeRequired,
    PerfOutputRequired,
    PerfFlagConflict,
    InvalidPerfFrames,
    InvalidPerfOutput,
}!?Config {
    const perf_requested = request.mode != null or request.warmup_frames != null or
        request.sample_frames != null or request.output_path != null or request.duplicate_flag;
    if (!perf_requested) return null;
    if (request.duplicate_flag) return error.DuplicatePerfFlag;
    if (request.scene_flag_count > 1) return error.MultiplePerfScenes;
    if (request.conflicting_flag) return error.PerfFlagConflict;
    const mode = request.mode orelse return error.PerfModeRequired;
    const output_path = request.output_path orelse return error.PerfOutputRequired;
    return try Config.validate(.{
        .mode = mode,
        .warmup_frames = request.warmup_frames orelse 240,
        .sample_frames = request.sample_frames orelse 1000,
        .output_path = output_path,
    });
}

pub fn parseMode(value: []const u8) error{InvalidPerfMode}!Mode {
    if (std.mem.eql(u8, value, "offscreen")) return .offscreen;
    if (std.mem.eql(u8, value, "presented")) return .presented;
    return error.InvalidPerfMode;
}

test "perf mode parser rejects unknown modes" {
    try testing.expectEqual(Mode.offscreen, try parseMode("offscreen"));
    try testing.expectEqual(Mode.presented, try parseMode("presented"));
    try testing.expectError(error.InvalidPerfMode, parseMode("shot"));
}

test "perf config rejects zero sample count" {
    try testing.expectError(error.InvalidPerfFrames, Config.validate(.{
        .mode = .offscreen,
        .warmup_frames = 240,
        .sample_frames = 0,
        .output_path = "/tmp/nogui-perf.jsonl",
    }));
}

test "perf config rejects total frame overflow" {
    try testing.expectError(error.InvalidPerfFrames, Config.validate(.{
        .mode = .presented,
        .warmup_frames = std.math.maxInt(u32),
        .sample_frames = 1,
        .output_path = "/tmp/nogui-perf.jsonl",
    }));
}

test "perf config defaults have a finite frame total" {
    const config: Config = .{
        .mode = .offscreen,
        .output_path = "/tmp/nogui-perf.jsonl",
    };
    try testing.expectEqual(@as(u32, 1240), try config.totalFrames());
}

test "perf cli requires mode and output as a pair" {
    try testing.expectError(error.PerfModeRequired, parseConfig(.{
        .output_path = "/tmp/nogui-perf.jsonl",
    }));
    try testing.expectError(error.PerfOutputRequired, parseConfig(.{
        .mode = .offscreen,
    }));
}

test "perf cli rejects duplicate flags" {
    try testing.expectError(error.DuplicatePerfFlag, parseConfig(.{
        .mode = .offscreen,
        .output_path = "/tmp/nogui-perf.jsonl",
        .duplicate_flag = true,
    }));
}

test "perf cli rejects multiple scenes" {
    try testing.expectError(error.MultiplePerfScenes, parseConfig(.{
        .mode = .offscreen,
        .output_path = "/tmp/nogui-perf.jsonl",
        .scene_flag_count = 2,
    }));
}

test "perf cli rejects incompatible flags" {
    try testing.expectError(error.PerfFlagConflict, parseConfig(.{
        .mode = .presented,
        .output_path = "/tmp/nogui-perf.jsonl",
        .conflicting_flag = true,
    }));
}

test "perf cli leaves non-perf requests unchanged" {
    try testing.expectEqual(@as(?Config, null), try parseConfig(.{}));
}

test "perf config rejects empty output path" {
    try testing.expectError(error.InvalidPerfOutput, Config.validate(.{
        .mode = .offscreen,
        .output_path = "",
    }));
}

test "perf recorder computes non-overlapping CPU capacity" {
    const sample = FrameSample{
        .phase = .sample,
        .frame_id = 0,
        .cpu_app_layout_ns = 10,
        .cpu_scene_ns = 20,
        .cpu_record_ns = 30,
        .cpu_submit_present_ns = 40,
        .cpu_compute_ns = 100,
        .mechanisms = if (v7_options.perf_counters)
            .{ .values = .{0} ** std.meta.fields(perf_counters.Counter).len }
        else {},
        .slop_ns = 0,
    };
    try testing.expectEqual(@as(u64, 100), try computeNs(&sample));
}

test "perf recorder rejects present slop above submit duration" {
    const sample = FrameSample{
        .phase = .sample,
        .frame_id = 0,
        .cpu_app_layout_ns = 1,
        .cpu_scene_ns = 1,
        .cpu_record_ns = 1,
        .cpu_submit_present_ns = 3,
        .cpu_compute_ns = 0,
        .cpu_present_slop_ns = 4,
        .mechanisms = if (v7_options.perf_counters)
            .{ .values = .{0} ** std.meta.fields(perf_counters.Counter).len }
        else {},
        .slop_ns = 0,
    };
    try testing.expectError(error.PresentSlopTooLarge, computeNs(&sample));
}

test "perf recorder rejects duplicate delayed metrics and too many samples" {
    var recorder = try Recorder.init(testing.allocator, 1);
    defer recorder.deinit();
    const sample = FrameSample.empty(.sample, 0);
    try recorder.append(sample);
    try testing.expectError(error.TooManySamples, recorder.append(FrameSample.empty(.sample, 1)));
    recorder.setMode(.presented);
    try recorder.attachPresent(0, 1);
    try testing.expectError(error.DuplicateFrameMetric, recorder.attachPresent(0, 1));
}

test "perf recorder rejects missing required offscreen slot wait" {
    var recorder = try Recorder.init(testing.allocator, 1);
    defer recorder.deinit();
    try recorder.append(FrameSample.empty(.sample, 0));
    try testing.expectError(error.MissingFrameMetric, recorder.validateComplete());
}

test "perf recorder rejects non-increasing presentation timestamp" {
    var recorder = try Recorder.init(testing.allocator, 2);
    defer recorder.deinit();
    recorder.setMode(.presented);
    var first = FrameSample.empty(.warmup, 0);
    first.cpu_acquire_ns = 0;
    first.cpu_present_slop_ns = 0;
    try recorder.append(first);
    var second = FrameSample.empty(.sample, 1);
    second.cpu_acquire_ns = 0;
    second.cpu_present_slop_ns = 0;
    try recorder.append(second);
    try recorder.attachPresent(0, 10);
    try testing.expectError(error.PresentTimestampNotIncreasing, recorder.attachPresent(1, 10));
}

test "perf recorder wraps GPU timestamps under valid-bit mask" {
    try testing.expectEqual(@as(u64, 2), try modularTickDelta(14, 0, 4));
    try testing.expectEqual(@as(u64, 2), try modularTickDelta(std.math.maxInt(u64) - 1, 0, 64));
    try testing.expectError(error.InvalidTimestamp, modularTickDelta(0, 1, 0));
    try testing.expectError(error.InvalidTimestampPeriod, ticksToNs(1, 0.0));
}
test "perf recorder serializes build-gated fields" {
    var recorder = try Recorder.init(testing.allocator, 1);
    defer recorder.deinit();
    var sample = FrameSample.empty(.sample, 0);
    sample.cpu_slot_wait_ns = 0;
    try recorder.append(sample);
    if (v7_options.gpu_timestamps) {
        try recorder.attachGpu(0, 0, 1, 1.0, 64);
    }
    var bytes: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try recorder.writeJsonl(&writer);
    const output = writer.buffered();
    if (v7_options.perf_counters) {
        try testing.expect(std.mem.indexOf(u8, output, "\"mechanisms\":") != null);
    } else {
        try testing.expect(std.mem.indexOf(u8, output, "\"mechanisms\":") == null);
    }
    try testing.expect(std.mem.indexOf(u8, output, "\"cpu_slot_wait_ns\":0") != null);
}

test "perf recorder rejects GPU attachment when disabled" {
    if (v7_options.gpu_timestamps) return;
    var recorder = try Recorder.init(testing.allocator, 1);
    defer recorder.deinit();
    var sample = FrameSample.empty(.sample, 0);
    sample.cpu_slot_wait_ns = 0;
    try recorder.append(sample);
    try testing.expectError(
        error.GpuTimestampsDisabled,
        recorder.attachGpu(0, 0, 1, 1.0, 64),
    );
}

test "perf recorder preserves null presentation intervals without timing support" {
    var recorder = try Recorder.init(testing.allocator, 2);
    defer recorder.deinit();
    recorder.setMode(.presented);
    recorder.setPresentationTimingSupported(false);
    var warmup = FrameSample.empty(.warmup, 0);
    warmup.cpu_acquire_ns = 0;
    warmup.cpu_present_slop_ns = 0;
    try recorder.append(warmup);
    var sample = FrameSample.empty(.sample, 1);
    sample.cpu_acquire_ns = 0;
    sample.cpu_present_slop_ns = 0;
    try recorder.append(sample);
    try recorder.attachPresent(0, 0);
    try recorder.attachPresent(1, 0);
    if (v7_options.gpu_timestamps) {
        try recorder.attachGpu(0, 0, 1, 1.0, 64);
        try recorder.attachGpu(1, 1, 2, 1.0, 64);
    }
    try recorder.validateComplete();
    try testing.expectEqual(@as(?u64, null), recorder.samples[0].present_interval_ns);
    try testing.expectEqual(@as(?u64, null), recorder.samples[1].present_interval_ns);
}

test "perf recorder reports duplicate GPU attachment" {
    if (!v7_options.gpu_timestamps) return;
    var recorder = try Recorder.init(testing.allocator, 1);
    defer recorder.deinit();
    var sample = FrameSample.empty(.sample, 0);
    sample.cpu_slot_wait_ns = 0;
    try recorder.append(sample);
    try recorder.attachGpu(0, 0, 1, 1.0, 64);
    try testing.expectError(
        error.DuplicateFrameMetric,
        recorder.attachGpu(0, 0, 1, 1.0, 64),
    );
}

test "perf recorder rejects first-frame delayed intervals" {
    if (v7_options.gpu_timestamps) {
        var gpu_recorder = try Recorder.init(testing.allocator, 1);
        defer gpu_recorder.deinit();
        var sample = FrameSample.empty(.sample, 0);
        sample.cpu_slot_wait_ns = 0;
        try gpu_recorder.append(sample);
        try gpu_recorder.attachGpu(0, 0, 1, 1.0, 64);
        gpu_recorder.samples[0].gpu_end_interval_ns = 1;
        try testing.expectError(error.InvalidFrame, gpu_recorder.validateComplete());
    }

    var present_recorder = try Recorder.init(testing.allocator, 1);
    defer present_recorder.deinit();
    present_recorder.setMode(.presented);
    var sample = FrameSample.empty(.sample, 0);
    sample.cpu_acquire_ns = 0;
    sample.cpu_present_slop_ns = 0;
    try present_recorder.append(sample);
    try present_recorder.attachPresent(0, 1);
    present_recorder.samples[0].present_interval_ns = 1;
    try testing.expectError(error.InvalidFrame, present_recorder.validateComplete());
}

test "perf recorder preserves cumulative presented slop" {
    var recorder = try Recorder.init(testing.allocator, 1);
    defer recorder.deinit();
    recorder.setMode(.presented);
    var sample = FrameSample.empty(.sample, 0);
    sample.cpu_submit_present_ns = 10;
    sample.cpu_compute_ns = 9;
    sample.cpu_acquire_ns = 0;
    sample.cpu_present_slop_ns = 1;
    sample.slop_ns = 5;
    try recorder.append(sample);
    if (v7_options.gpu_timestamps) {
        try recorder.attachGpu(0, 0, 1, 1.0, 64);
    }
    try recorder.attachPresent(0, 0);
    try recorder.validateComplete();
}

test "perf slot scheduler waits only before reuse" {
    try testing.expectEqual(@as(?u64, null), slotWaitValue(0, 3));
    try testing.expectEqual(@as(?u64, null), slotWaitValue(2, 3));
    try testing.expectEqual(@as(?u64, 1), slotWaitValue(3, 3));
    try testing.expectEqual(@as(?u64, 2), slotWaitValue(4, 3));
}

test "perf slot scheduler rejects non-monotonic timeline values" {
    var scheduler: SlotScheduler = .{};
    try testing.expectEqual(@as(?u64, null), try scheduler.next(0, 1, 3));
    try testing.expectError(error.NonMonotonicTimelineValue, scheduler.next(1, 1, 3));
}

test "perf slot recorder rejects duplicate frame IDs" {
    var recorder = try Recorder.init(testing.allocator, 2);
    defer recorder.deinit();
    var sample = FrameSample.empty(.warmup, 0);
    sample.cpu_slot_wait_ns = 0;
    try recorder.append(sample);
    try testing.expectError(error.InvalidFrameId, recorder.append(sample));
}

test "perf slot recorder rejects non-monotonic presentation IDs" {
    var recorder = try Recorder.init(testing.allocator, 2);
    defer recorder.deinit();
    recorder.setMode(.presented);
    var first = FrameSample.empty(.warmup, 0);
    first.cpu_acquire_ns = 0;
    first.cpu_present_slop_ns = 0;
    try recorder.append(first);
    var second = FrameSample.empty(.sample, 1);
    second.cpu_acquire_ns = 0;
    second.cpu_present_slop_ns = 0;
    try recorder.append(second);
    try recorder.attachPresent(0, 10);
    try testing.expectError(error.PresentTimestampNotIncreasing, recorder.attachPresent(1, 10));
}

test "perf recorder downgrades unavailable presentation timing before metrics" {
    var recorder = try Recorder.init(testing.allocator, 2);
    defer recorder.deinit();
    recorder.setMode(.presented);
    var warmup = FrameSample.empty(.warmup, 0);
    warmup.cpu_acquire_ns = 0;
    warmup.cpu_present_slop_ns = 0;
    try recorder.append(warmup);
    var sample = FrameSample.empty(.sample, 1);
    sample.cpu_acquire_ns = 0;
    sample.cpu_present_slop_ns = 0;
    try recorder.append(sample);
    if (v7_options.gpu_timestamps) {
        try recorder.attachGpu(0, 0, 1, 1.0, 64);
        try recorder.attachGpu(1, 1, 2, 1.0, 64);
    }

    try recorder.markPresentTimingUnavailable();

    try testing.expect(!recorder.presentation_timing_supported);
    try testing.expectEqual(@as(u64, 2), recorder.next_present_frame_id);
    try testing.expectEqual(@as(?u64, null), recorder.samples[0].present_interval_ns);
    try testing.expectEqual(@as(?u64, null), recorder.samples[1].present_interval_ns);
    try recorder.validateComplete();
}

test "perf recorder rejects unavailable timing after one presentation metric" {
    var recorder = try Recorder.init(testing.allocator, 1);
    defer recorder.deinit();
    recorder.setMode(.presented);
    var sample = FrameSample.empty(.sample, 0);
    sample.cpu_acquire_ns = 0;
    sample.cpu_present_slop_ns = 0;
    try recorder.append(sample);
    try recorder.attachPresent(0, 10);

    try testing.expectError(
        error.PartialPresentFeedback,
        recorder.markPresentTimingUnavailable(),
    );
}

test "perf presented query slots resolve only after fence reuse" {
    var slots: QuerySlotScheduler = .{};
    try testing.expectEqual(@as(?u64, null), try slots.begin(0));
    try slots.submitted(0);
    try testing.expectEqual(@as(?u64, null), try slots.begin(1));
    try slots.submitted(1);
    try testing.expectEqual(@as(?u64, null), try slots.begin(2));
    try slots.submitted(2);
    try testing.expectEqual(@as(?u64, 0), try slots.begin(3));
    try slots.submitted(3);
    try testing.expectEqual(@as(?u64, 1), try slots.begin(4));
}

test "perf presented query slots reject overwrite before recycle" {
    var slots: QuerySlotScheduler = .{};
    try slots.submitted(0);
    try testing.expectError(error.QuerySlotBusy, slots.submitted(3));

    var missing: QuerySlotScheduler = .{};
    try testing.expectError(error.QuerySlotMismatch, missing.begin(3));
}

test "perf presented IDs reserve preflight and map recorded frames" {
    try testing.expectEqual(@as(u64, 2), try presentIdForFrame(2, 0));
    try testing.expectEqual(@as(u64, 3), try presentIdForFrame(2, 1));
    try testing.expectEqual(@as(u64, 1), try frameIdForPresentId(3, 2, 4));
    try testing.expectError(error.InvalidPresentationId, frameIdForPresentId(1, 2, 4));
    try testing.expectError(error.InvalidFrameId, frameIdForPresentId(6, 2, 4));
    try testing.expectError(error.TimestampOverflow, presentIdForFrame(std.math.maxInt(u64), 1));
}

test "perf preflight timestamp is discarded before first recorded interval" {
    var recorder = try Recorder.init(testing.allocator, 2);
    defer recorder.deinit();
    recorder.setMode(.presented);
    var first = FrameSample.empty(.sample, 0);
    first.cpu_acquire_ns = 0;
    first.cpu_present_slop_ns = 0;
    try recorder.append(first);
    var second = FrameSample.empty(.sample, 1);
    second.cpu_acquire_ns = 0;
    second.cpu_present_slop_ns = 0;
    try recorder.append(second);

    try recorder.attachPresent(0, 100);
    try recorder.attachPresent(1, 200);
    try testing.expectEqual(@as(?u64, null), recorder.samples[0].present_interval_ns);
    try testing.expectEqual(@as(?u64, 100), recorder.samples[1].present_interval_ns);
}

test "perf preflight IDs advance once for supported fallback" {
    var ids: PresentPreflightIds = .{};
    try testing.expectEqual(@as(u64, 1), ids.reservedId());

    try testing.expectEqual(@as(u64, 2), try ids.recordedBase());
    try testing.expectEqual(@as(?u64, 2), try ids.afterUnavailable(true));
    try testing.expectEqual(@as(u64, 2), ids.reservedId());
    try testing.expectEqual(@as(u64, 3), try ids.recordedBase());
    try testing.expectError(error.PresentTimingFallbackLimit, ids.afterUnavailable(true));
}

test "perf preflight IDs stop when timing is unsupported" {
    var ids: PresentPreflightIds = .{};
    try testing.expectEqual(@as(?u64, null), try ids.afterUnavailable(false));
    try testing.expectEqual(@as(u64, 1), ids.reservedId());
    try testing.expectEqual(@as(u64, 2), try ids.recordedBase());
}

test "perf preflight IDs reject overflow without advancing" {
    var ids: PresentPreflightIds = .{ .reserved_id = std.math.maxInt(u64) };
    try testing.expectError(error.TimestampOverflow, ids.recordedBase());
    try testing.expectError(error.TimestampOverflow, ids.afterUnavailable(true));
    try testing.expectEqual(std.math.maxInt(u64), ids.reservedId());
}

test "perf preflight deadline spans repeated out-of-date retries" {
    var state: PresentPreflightState = .{};
    try testing.expectEqual(@as(u8, 0), state.modeEpoch());
    try testing.expect(!state.deadlineExpired(4_999_999_999));
    try testing.expect(state.deadlineExpired(5_000_000_000));
    try testing.expectEqual(@as(u8, 0), state.modeEpoch());
    try testing.expectEqual(@as(?u64, 2), try state.afterUnavailable(true));
    try testing.expectEqual(@as(u8, 1), state.modeEpoch());
    try testing.expect(!state.deadlineExpired(0));
}

test "perf preflight deadline resets only after supported fallback" {
    var state: PresentPreflightState = .{};
    try testing.expectEqual(@as(?u64, null), try state.afterUnavailable(false));
    try testing.expectEqual(@as(u8, 0), state.modeEpoch());
    try testing.expectEqual(@as(?u64, 2), try state.afterUnavailable(true));
    try testing.expectError(error.PresentTimingFallbackLimit, state.afterUnavailable(true));
    try testing.expectEqual(@as(u8, 1), state.modeEpoch());
}

test "perf preflight deadline rejects late positive feedback" {
    var state: PresentPreflightState = .{};
    try testing.expect(!state.deadlineExpired(4_999_999_999));
    try testing.expect(state.deadlineExpired(5_000_000_000));
}
