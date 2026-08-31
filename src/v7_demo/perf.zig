const std = @import("std");
const testing = std.testing;

pub const Mode = enum {
    offscreen,
    presented,
};

pub const Config = struct {
    mode: Mode,
    warmup_frames: u32 = 240,
    sample_frames: u32 = 1000,
    output_path: []const u8,

    pub fn validate(config: Config) error{InvalidPerfFrames, InvalidPerfOutput}!Config {
        if (config.sample_frames == 0) return error.InvalidPerfFrames;
        if (config.warmup_frames > std.math.maxInt(u32) - config.sample_frames) {
            return error.InvalidPerfFrames;
        }
        if (config.output_path.len == 0) return error.InvalidPerfOutput;
        return config;
    }

    pub fn totalFrames(config: Config) error{InvalidPerfFrames, InvalidPerfOutput}!u32 {
        const validated = try validate(config);
        return validated.warmup_frames + validated.sample_frames;
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
}! ?Config {
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
