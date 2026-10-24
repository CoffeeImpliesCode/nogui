//! W24 performance-recorder paired benchmark.
//!
//! The W24 gate asks for "the current performance recorder smoke, with paired
//! measurements before any speed claim". This binary drives the EXISTING
//! recorder: `perf.zig`'s `Recorder` is instantiated by `window.zig`, which
//! writes the JSONL artifact the protocol tool parses. Nothing here measures a
//! frame. This binary only:
//!
//!   1. runs the real windowed perf path once per arm, interleaved, so a
//!      machine that drifts over the run cannot favour one arm;
//!   2. times every run with `Io.Clock.awake` (CLOCK_MONOTONIC). No injected
//!      clock, no simulated time;
//!   3. reads the per-frame numbers back out of the recorder's own JSONL and
//!      folds them into one secondary statistic per run;
//!   4. writes the distributions, the paired differences and a machine-written
//!      verdict to `bench.json`.
//!
//! Each arm is a configuration of THIS tree, named by the demo's own flags:
//! `--arm-a-scene` / `--arm-b-scene` pick the mounted root, `--arm-a` /
//! `--arm-b` pick the perf mode. The binary, the frame counts, the warm-up and
//! the mechanism counters are identical between the arms; only those two
//! fields differ. The report names the difference in `differs_only_in`.
//!
//! A run that the recorder or the compositor refuses is not a measurement: the
//! pair is retried, the failure is counted and listed in the report, and only
//! pairs where BOTH arms completed enter the distributions.
//!
//! Run it:
//!   zig build w24-perf-pair-bench -- [--pairs 20] [--discard 3] \
//!       [--scene NAME | --arm-a-scene NAME --arm-b-scene NAME] \
//!       [--arm-a offscreen|presented] [--arm-b offscreen|presented] \
//!       [--warmup 240] [--frames 1000] [--out-dir DIR]

const std = @import("std");
const Io = std.Io;

const nogui = @import("nogui");
const ui = @import("ui.zig");
const spotify_ui = @import("spotify.zig");
const calculator_ui = @import("calculator.zig");
const window_backend = @import("window.zig");
const perf = @import("perf.zig");

const App = nogui.App;
const Session = nogui.Session;

/// Title marker so an operator can tell this benchmark's window from the
/// sibling workers' windows on the shared display.
const window_title_suffix = " [w24-perf-pair-bench]";

const Scene = enum {
    todo,
    spotify,
    calculator,
    tiger,
    strokes,

    fn fromName(name: []const u8) ?Scene {
        const info = @typeInfo(Scene).@"enum";
        inline for (info.field_names, info.field_values) |field_name, field_value| {
            if (std.mem.eql(u8, name, field_name)) return @fromBackingInt(@intCast(field_value));
        }
        return null;
    }
};

/// One arm of the comparison: a scene, a perf mode and the label its
/// artifacts are filed under. Both fields are real configurations of this
/// tree; everything else about a run is shared.
const Arm = struct {
    name: []const u8 = "",
    mode: perf.Mode = .offscreen,
    scene: Scene = .todo,
};

const Config = struct {
    pairs: u32 = 20,
    discard: u32 = 3,
    warmup_frames: u32 = 240,
    sample_frames: u32 = 1000,
    out_dir: []const u8 = "zig-out/w24-perf-pair",
    arm_a: Arm = .{ .mode = .offscreen, .scene = .todo },
    arm_b: Arm = .{ .mode = .presented, .scene = .todo },
    bootstrap_resamples: usize = 10_000,
    bootstrap_seed: u64 = 0x5eed_24,

    fn totalPairs(config: Config) u32 {
        return config.discard + config.pairs;
    }
};

/// One completed run: the wall time of the whole perf run plus the per-frame
/// statistics read back out of the recorder's JSONL.
const RunOutcome = struct {
    wall_ns: u64,
    compute_median_ns: u64,
    present_interval_median_ns: ?u64,
    sample_count: u64,
    present_feedback: bool,
    refresh_hz: ?f64,
};

/// A run the recorder or the compositor refused to complete. Reported, never
/// silently retried into the statistics.
const Failure = struct {
    attempt: u32,
    arm: []const u8,
    error_name: []const u8,
};

const RunRecord = struct {
    pair: usize,
    attempt: u32,
    arm: []const u8,
    mode: []const u8,
    scene: []const u8,
    wall_ns: u64,
    compute_median_ns: u64,
    present_interval_median_ns: ?u64,
    sample_count: u64,
    present_feedback: bool,
    refresh_hz: ?f64,
    recorder_path: []const u8,
    kept: bool,
};

const Distribution = struct {
    n: usize,
    min_ns: u64,
    p25_ns: f64,
    median_ns: f64,
    mean_ns: f64,
    p75_ns: f64,
    max_ns: u64,
    stddev_ns: f64,
    median_ci95_lo_ns: f64,
    median_ci95_hi_ns: f64,
};

const Paired = struct {
    n: usize,
    b_faster_than_a: usize,
    median_diff_ns: f64,
    mean_diff_ns: f64,
    stddev_diff_ns: f64,
    effect_size_dz: f64,
    sign_test_p: f64,
    relative_median_diff: f64,
    spread_ratio_b_over_a_stddev: f64,
    distinguishable: bool,
    verdict: []const u8,
};

const Report = struct {
    schema: []const u8 = "nogui.w24-perf-pair-bench.v1",
    arm_a: []const u8,
    arm_a_mode: []const u8,
    arm_a_scene: []const u8,
    arm_b: []const u8,
    arm_b_mode: []const u8,
    arm_b_scene: []const u8,
    differs_only_in: []const u8,
    pairs_kept: u32,
    pairs_discarded: u32,
    pair_attempts: u32,
    failed_runs: usize,
    failures: []const Failure,
    warmup_frames: u32,
    sample_frames: u32,
    clock: []const u8 = "Io.Clock.awake (CLOCK_MONOTONIC)",
    runs: []const RunRecord,
    wall_a: Distribution,
    wall_b: Distribution,
    compute_a: Distribution,
    compute_b: Distribution,
    paired_wall: Paired,
    paired_compute: Paired,
};

fn lessThanU64(_: void, lhs: u64, rhs: u64) bool {
    return lhs < rhs;
}

fn medianOfSorted(sorted: []const u64) f64 {
    std.debug.assert(sorted.len != 0);
    const middle = sorted.len / 2;
    if (sorted.len % 2 == 1) return @floatFromInt(sorted[middle]);
    return @as(f64, @floatFromInt(sorted[middle - 1] + sorted[middle])) / 2.0;
}

fn percentileOfSorted(sorted: []const u64, numerator: usize, denominator: usize) f64 {
    std.debug.assert(sorted.len != 0);
    if (sorted.len == 1) return @floatFromInt(sorted[0]);
    const rank = (numerator * (sorted.len - 1) + denominator / 2) / denominator;
    return @floatFromInt(sorted[rank]);
}

fn meanOf(values: []const u64) f64 {
    var total: f64 = 0.0;
    for (values) |value| total += @floatFromInt(value);
    return total / @as(f64, @floatFromInt(values.len));
}

fn stddevOf(values: []const u64, mean: f64) f64 {
    if (values.len < 2) return 0.0;
    var total: f64 = 0.0;
    for (values) |value| {
        const delta = @as(f64, @floatFromInt(value)) - mean;
        total += delta * delta;
    }
    return @sqrt(total / @as(f64, @floatFromInt(values.len - 1)));
}

fn sortedCopy(gpa: std.mem.Allocator, values: []const u64) ![]u64 {
    const copy = try gpa.dupe(u64, values);
    std.mem.sortUnstable(u64, copy, {}, lessThanU64);
    return copy;
}

/// Bootstrap percentile interval for the median. The resample draw is seeded,
/// so the interval is reproducible instead of a fresh coin toss per report.
fn bootstrapMedianCi95(
    gpa: std.mem.Allocator,
    sorted: []const u64,
    resamples: usize,
    seed: u64,
) !struct { lo: f64, hi: f64 } {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const draws = try gpa.alloc(u64, sorted.len * resamples);
    defer gpa.free(draws);
    for (0..resamples) |resample| {
        const draw = draws[resample * sorted.len ..][0..sorted.len];
        for (draw) |*slot| slot.* = sorted[random.uintLessThan(usize, sorted.len)];
        std.mem.sortUnstable(u64, draw, {}, lessThanU64);
    }
    const medians = draws[0..resamples];
    std.mem.sortUnstable(u64, medians, {}, lessThanU64);
    return .{
        .lo = percentileOfSorted(medians, 25, 100),
        .hi = percentileOfSorted(medians, 75, 100),
    };
}

fn summarize(
    gpa: std.mem.Allocator,
    values: []const u64,
    resamples: usize,
    seed: u64,
) !Distribution {
    if (values.len == 0) return error.NoRuns;
    const sorted = try sortedCopy(gpa, values);
    defer gpa.free(sorted);
    const mean = meanOf(values);
    const ci = try bootstrapMedianCi95(gpa, sorted, resamples, seed);
    return .{
        .n = values.len,
        .min_ns = sorted[0],
        .p25_ns = percentileOfSorted(sorted, 25, 100),
        .median_ns = medianOfSorted(sorted),
        .mean_ns = mean,
        .p75_ns = percentileOfSorted(sorted, 75, 100),
        .max_ns = sorted[sorted.len - 1],
        .stddev_ns = stddevOf(values, mean),
        .median_ci95_lo_ns = ci.lo,
        .median_ci95_hi_ns = ci.hi,
    };
}

/// Exact two-sided sign test on the paired differences. Under the null the
/// sign of a difference is a fair coin, so the p-value is the binomial tail.
fn signTestP(b_faster: usize, n: usize) f64 {
    if (n == 0) return 1.0;
    const minority = @min(b_faster, n - b_faster);
    // Every ordering of n fair-coin signs is one of 2^n equally likely
    // outcomes, so the tail probability is the binomial sum over 2^n.
    const total = std.math.pow(f64, 2.0, @floatFromInt(n));
    var tail: f64 = 0.0;
    var choose: f64 = 1.0;
    var index: usize = 0;
    while (index <= minority) : (index += 1) {
        tail += choose;
        choose *= @as(f64, @floatFromInt(n - index)) / @as(f64, @floatFromInt(index + 1));
    }
    return @min(1.0, 2.0 * tail / total);
}

fn intervalsMiss(a: Distribution, b: Distribution) bool {
    return a.median_ci95_hi_ns < b.median_ci95_lo_ns or
        b.median_ci95_hi_ns < a.median_ci95_lo_ns;
}

fn compareArms(gpa: std.mem.Allocator, a: []const u64, b: []const u64) !Paired {
    if (a.len != b.len or a.len == 0) return error.UnpairedRuns;
    const diffs = try gpa.alloc(u64, a.len);
    defer gpa.free(diffs);
    var b_faster: usize = 0;
    for (a, b, 0..) |a_ns, b_ns, index| {
        diffs[index] = b_ns -| a_ns;
        if (b_ns < a_ns) b_faster += 1;
    }
    const sorted_diffs = try sortedCopy(gpa, diffs);
    defer gpa.free(sorted_diffs);
    const sorted_a = try sortedCopy(gpa, a);
    defer gpa.free(sorted_a);
    const sorted_b = try sortedCopy(gpa, b);
    defer gpa.free(sorted_b);
    const dist_a: Distribution = .{
        .n = a.len,
        .min_ns = sorted_a[0],
        .p25_ns = 0,
        .median_ns = medianOfSorted(sorted_a),
        .mean_ns = meanOf(a),
        .p75_ns = 0,
        .max_ns = sorted_a[a.len - 1],
        .stddev_ns = stddevOf(a, meanOf(a)),
        .median_ci95_lo_ns = 0,
        .median_ci95_hi_ns = 0,
    };
    const dist_b: Distribution = .{
        .n = b.len,
        .min_ns = sorted_b[0],
        .p25_ns = 0,
        .median_ns = medianOfSorted(sorted_b),
        .mean_ns = meanOf(b),
        .p75_ns = 0,
        .max_ns = sorted_b[b.len - 1],
        .stddev_ns = stddevOf(b, meanOf(b)),
        .median_ci95_lo_ns = 0,
        .median_ci95_hi_ns = 0,
    };
    const mean = meanOf(diffs);
    const stddev = stddevOf(diffs, mean);
    return .{
        .n = a.len,
        .b_faster_than_a = b_faster,
        .median_diff_ns = medianOfSorted(sorted_diffs),
        .mean_diff_ns = mean,
        .stddev_diff_ns = stddev,
        .effect_size_dz = if (stddev == 0.0) 0.0 else mean / stddev,
        .sign_test_p = signTestP(b_faster, a.len),
        .relative_median_diff = if (dist_a.median_ns == 0.0)
            0.0
        else
            medianOfSorted(sorted_diffs) / dist_a.median_ns,
        .spread_ratio_b_over_a_stddev = if (dist_a.stddev_ns == 0.0)
            0.0
        else
            dist_b.stddev_ns / dist_a.stddev_ns,
        .distinguishable = intervalsMiss(dist_a, dist_b),
        .verdict = "",
    };
}

/// Fold the recorder's own artifact back in. A line the recorder wrote that
/// does not parse, or a run with no sample-phase frame, is a failure of the
/// recorder, not something to be smoothed over.
const RecorderFile = struct {
    present_feedback: bool,
    refresh_hz: ?f64,
    compute_median_ns: u64,
    present_interval_median_ns: ?u64,
    sample_count: u64,

    const HeaderLine = struct {
        present_feedback: bool,
        reported_refresh_data: ?struct { refresh_hz: f64 },
    };
    const SampleLine = struct {
        phase: []const u8,
        cpu_compute_ns: u64,
        present_interval_ns: ?u64 = null,
    };

    fn read(gpa: std.mem.Allocator, io: Io, path: []const u8, scratch: []u64) !RecorderFile {
        const text = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        const header_line = lines.next() orelse return error.EmptyRecorderArtifact;
        const header = try std.json.parseFromSlice(HeaderLine, gpa, header_line, .{
            .ignore_unknown_fields = true,
        });
        defer header.deinit();
        var compute: usize = 0;
        var present: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const sample = try std.json.parseFromSlice(SampleLine, gpa, line, .{
                .ignore_unknown_fields = true,
            });
            defer sample.deinit();
            if (!std.mem.eql(u8, sample.value.phase, "sample")) continue;
            if (compute < scratch.len) scratch[compute] = sample.value.cpu_compute_ns;
            compute += 1;
            if (sample.value.present_interval_ns) |interval_ns| {
                if (present < scratch.len) scratch[present] = interval_ns;
                present += 1;
            }
        }
        if (compute == 0) return error.NoSamplePhaseFrames;
        if (compute > scratch.len) return error.ScratchTooSmall;
        const compute_sorted = try sortedCopy(gpa, scratch[0..compute]);
        defer gpa.free(compute_sorted);
        var present_median: ?u64 = null;
        if (present != 0) {
            const present_sorted = try sortedCopy(gpa, scratch[0..present]);
            defer gpa.free(present_sorted);
            present_median = present_sorted[present / 2];
        }
        return .{
            .present_feedback = header.value.present_feedback,
            .refresh_hz = if (header.value.reported_refresh_data) |refresh| refresh.refresh_hz else null,
            .compute_median_ns = compute_sorted[compute / 2],
            .present_interval_median_ns = present_median,
            .sample_count = compute,
        };
    }
};

fn runScene(
    comptime T: type,
    gpa: std.mem.Allocator,
    root: *T,
    config: perf.Config,
) !void {
    var session = try Session.init(gpa);
    defer session.deinit() catch @panic("bench Session has live models or windows");
    var app = try App.init(gpa, &session);
    defer app.deinit();
    try app.mountRoot(T, root);
    try window_backend.run(T, &app, root, .{
        .perf = config,
        .window_title_suffix = window_title_suffix,
    });
}
const RunResult = struct {
    outcome: RunOutcome,
    path: []const u8,
};

fn runOnce(
    gpa: std.mem.Allocator,
    io: Io,
    config: Config,
    arm: Arm,
    index: u32,
    scratch: []u64,
) !RunResult {
    const path = try std.fmt.allocPrint(
        gpa,
        "{s}/{s}-r{d:0>3}.jsonl",
        .{ config.out_dir, arm.name, index },
    );
    errdefer gpa.free(path);
    const perf_config = try perf.Config.validate(.{
        .mode = arm.mode,
        .warmup_frames = config.warmup_frames,
        .sample_frames = config.sample_frames,
        .output_path = path,
    });
    const start = Io.Clock.awake.now(io);
    switch (arm.scene) {
        .todo => {
            var root: ui.TodoApp = .{};
            try runScene(ui.TodoApp, gpa, &root, perf_config);
        },
        .spotify => {
            var root: spotify_ui.SpotifyApp = .{};
            try runScene(spotify_ui.SpotifyApp, gpa, &root, perf_config);
        },
        .calculator => {
            var root: calculator_ui.CalculatorApp = .{};
            try runScene(calculator_ui.CalculatorApp, gpa, &root, perf_config);
        },
        .tiger => {
            var root: ui.TigerApp = .{};
            try runScene(ui.TigerApp, gpa, &root, perf_config);
        },
        .strokes => {
            var root: ui.TestStrokesApp = .{};
            try runScene(ui.TestStrokesApp, gpa, &root, perf_config);
        },
    }
    const elapsed = start.durationTo(Io.Clock.awake.now(io));
    const recorder = try RecorderFile.read(gpa, io, path, scratch);
    return .{
        .outcome = .{
            .wall_ns = @intCast(@max(0, elapsed.toNanoseconds())),
            .compute_median_ns = recorder.compute_median_ns,
            .present_interval_median_ns = recorder.present_interval_median_ns,
            .sample_count = recorder.sample_count,
            .present_feedback = recorder.present_feedback,
            .refresh_hz = recorder.refresh_hz,
        },
        .path = path,
    };
}

fn emit(comptime format: []const u8, gpa: std.mem.Allocator, io: Io, args: anytype) !void {
    const line = try std.fmt.allocPrint(gpa, format, args);
    defer gpa.free(line);
    try Io.File.stdout().writeStreamingAll(io, line);
}

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var config: Config = .{};
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    _ = args_it.next();
    while (args_it.next()) |arg| {
        const value = args_it.next() orelse return error.MissingArgumentValue;
        if (std.mem.eql(u8, arg, "--scene")) {
            const scene = Scene.fromName(value) orelse return error.UnknownScene;
            config.arm_a.scene = scene;
            config.arm_b.scene = scene;
        } else if (std.mem.eql(u8, arg, "--pairs")) {
            config.pairs = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--discard")) {
            config.discard = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            config.warmup_frames = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--frames")) {
            config.sample_frames = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--out-dir")) {
            config.out_dir = value;
        } else if (std.mem.eql(u8, arg, "--arm-a")) {
            config.arm_a.mode = try perf.parseMode(value);
        } else if (std.mem.eql(u8, arg, "--arm-b")) {
            config.arm_b.mode = try perf.parseMode(value);
        } else if (std.mem.eql(u8, arg, "--arm-a-scene")) {
            config.arm_a.scene = Scene.fromName(value) orelse return error.UnknownScene;
        } else if (std.mem.eql(u8, arg, "--arm-b-scene")) {
            config.arm_b.scene = Scene.fromName(value) orelse return error.UnknownScene;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }
    if (config.pairs == 0) return error.NoPairs;
    if (config.sample_frames == 0) return error.NoSampleFrames;
    if (config.arm_a.mode == config.arm_b.mode and
        config.arm_a.scene == config.arm_b.scene) return error.ArmsMustDiffer;

    // The artifact name carries the arm's own configuration, so a file is
    // never filed under a label that contradicts what it recorded.
    config.out_dir = try gpa.dupe(u8, config.out_dir);
    defer gpa.free(config.out_dir);
    config.arm_a.name = try std.fmt.allocPrint(
        gpa,
        "a-{s}-{s}",
        .{ @tagName(config.arm_a.mode), @tagName(config.arm_a.scene) },
    );
    defer gpa.free(config.arm_a.name);
    config.arm_b.name = try std.fmt.allocPrint(
        gpa,
        "b-{s}-{s}",
        .{ @tagName(config.arm_b.mode), @tagName(config.arm_b.scene) },
    );
    defer gpa.free(config.arm_b.name);

    try Io.Dir.cwd().createDirPath(io, config.out_dir);
    const total = config.totalPairs();
    const scratch = try gpa.alloc(u64, config.warmup_frames + config.sample_frames);
    defer gpa.free(scratch);

    var records: std.ArrayList(RunRecord) = .empty;
    defer records.deinit(gpa);
    var a_wall: std.ArrayList(u64) = .empty;
    defer a_wall.deinit(gpa);
    var b_wall: std.ArrayList(u64) = .empty;
    defer b_wall.deinit(gpa);
    var a_compute: std.ArrayList(u64) = .empty;
    defer a_compute.deinit(gpa);
    var b_compute: std.ArrayList(u64) = .empty;
    defer b_compute.deinit(gpa);
    var failures: std.ArrayList(Failure) = .empty;
    defer failures.deinit(gpa);
    // The report prints the recorder path of every run, so the paths stay
    // owned by main until bench.json has been written.
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| gpa.free(path);
        paths.deinit(gpa);
    }

    // Interleaved: arm A then arm B for every pair index, so a machine that
    // warms up, throttles or gets busy during the run taxes both alike. A
    // presented run that the compositor interrupts is not a measurement, so
    // the whole pair is retried; only pairs where BOTH arms completed enter
    // the distributions.
    var attempt: u32 = 0;
    var complete: u32 = 0;
    const max_attempts = total * 3;
    while (complete < total and attempt < max_attempts) : (attempt += 1) {
        const kept = complete >= config.discard;
        const a_run = runOnce(gpa, io, config, config.arm_a, attempt, scratch) catch |err| {
            try failures.append(gpa, .{
                .attempt = attempt,
                .arm = config.arm_a.name,
                .error_name = @errorName(err),
            });
            try emit(
                "w24-perf-pair-bench: attempt {d} {s} failed: {s}\n",
                gpa,
                io,
                .{ attempt, config.arm_a.name, @errorName(err) },
            );
            continue;
        };
        try paths.append(gpa, a_run.path);
        const b_run = runOnce(gpa, io, config, config.arm_b, attempt, scratch) catch |err| {
            try failures.append(gpa, .{
                .attempt = attempt,
                .arm = config.arm_b.name,
                .error_name = @errorName(err),
            });
            try emit(
                "w24-perf-pair-bench: attempt {d} {s} failed: {s}\n",
                gpa,
                io,
                .{ attempt, config.arm_b.name, @errorName(err) },
            );
            continue;
        };
        try paths.append(gpa, b_run.path);
        try emit(
            "w24-perf-pair-bench: attempt {d} {s} wall_ns={d} compute_median_ns={d} recorder={s}\n" ++
                "w24-perf-pair-bench: attempt {d} {s} wall_ns={d} compute_median_ns={d} recorder={s}\n",
            gpa,
            io,
            .{
                attempt,
                config.arm_a.name,
                a_run.outcome.wall_ns,
                a_run.outcome.compute_median_ns,
                a_run.path,
                attempt,
                config.arm_b.name,
                b_run.outcome.wall_ns,
                b_run.outcome.compute_median_ns,
                b_run.path,
            },
        );
        for ([_]RunResult{ a_run, b_run }, [_]Arm{ config.arm_a, config.arm_b }, 0..) |run, arm, arm_index| {
            try records.append(gpa, .{
                .pair = complete,
                .attempt = attempt,
                .arm = arm.name,
                .mode = @tagName(arm.mode),
                .scene = @tagName(arm.scene),
                .wall_ns = run.outcome.wall_ns,
                .compute_median_ns = run.outcome.compute_median_ns,
                .present_interval_median_ns = run.outcome.present_interval_median_ns,
                .sample_count = run.outcome.sample_count,
                .present_feedback = run.outcome.present_feedback,
                .refresh_hz = run.outcome.refresh_hz,
                .recorder_path = run.path,
                .kept = kept,
            });
            if (arm_index == 0) {
                try a_wall.append(gpa, run.outcome.wall_ns);
                try a_compute.append(gpa, run.outcome.compute_median_ns);
            } else {
                try b_wall.append(gpa, run.outcome.wall_ns);
                try b_compute.append(gpa, run.outcome.compute_median_ns);
            }
        }
        complete += 1;
    }
    if (complete < total) return error.TooManyFailedPairs;
    const kept_from: usize = config.discard;
    const a_kept = a_wall.items[kept_from..];
    const b_kept = b_wall.items[kept_from..];
    const a_compute_kept = a_compute.items[kept_from..];
    const b_compute_kept = b_compute.items[kept_from..];
    const wall_a = try summarize(gpa, a_kept, config.bootstrap_resamples, config.bootstrap_seed);
    const wall_b = try summarize(gpa, b_kept, config.bootstrap_resamples, config.bootstrap_seed + 1);
    const compute_a = try summarize(gpa, a_compute_kept, config.bootstrap_resamples, config.bootstrap_seed + 2);
    const compute_b = try summarize(gpa, b_compute_kept, config.bootstrap_resamples, config.bootstrap_seed + 3);
    var paired_wall = try compareArms(gpa, a_kept, b_kept);
    var paired_compute = try compareArms(gpa, a_compute_kept, b_compute_kept);
    paired_wall.distinguishable = intervalsMiss(wall_a, wall_b);
    paired_wall.verdict = verdictFor(paired_wall.distinguishable);
    paired_compute.distinguishable = intervalsMiss(compute_a, compute_b);
    paired_compute.verdict = verdictFor(paired_compute.distinguishable);

    const summary_path = try std.fmt.allocPrint(gpa, "{s}/bench.json", .{config.out_dir});
    defer gpa.free(summary_path);
    const differs_only_in = try std.fmt.allocPrint(
        gpa,
        "perf mode {s} vs {s} and scene {s} vs {s}; binary, frame counts, warm-up and counters are identical",
        .{
            @tagName(config.arm_a.mode),
            @tagName(config.arm_b.mode),
            @tagName(config.arm_a.scene),
            @tagName(config.arm_b.scene),
        },
    );
    defer gpa.free(differs_only_in);
    const report: Report = .{
        .arm_a = config.arm_a.name,
        .arm_a_mode = @tagName(config.arm_a.mode),
        .arm_a_scene = @tagName(config.arm_a.scene),
        .arm_b = config.arm_b.name,
        .arm_b_mode = @tagName(config.arm_b.mode),
        .arm_b_scene = @tagName(config.arm_b.scene),
        .differs_only_in = differs_only_in,
        .pairs_kept = config.pairs,
        .pairs_discarded = config.discard,
        .pair_attempts = attempt,
        .failed_runs = failures.items.len,
        .failures = failures.items,
        .warmup_frames = config.warmup_frames,
        .sample_frames = config.sample_frames,
        .runs = records.items,
        .wall_a = wall_a,
        .wall_b = wall_b,
        .compute_a = compute_a,
        .compute_b = compute_b,
        .paired_wall = paired_wall,
        .paired_compute = paired_compute,
    };
    {
        var file = try Io.Dir.cwd().createFile(io, summary_path, .{ .truncate = true });
        defer file.close(io);
        var backing: [16 * 1024]u8 = undefined;
        var file_writer = file.writer(io, &backing);
        try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, &file_writer.interface);
        try file_writer.interface.writeByte('\n');
        try file_writer.interface.flush();
    }

    try emit(
        "w24-perf-pair-bench: wall median {s}={d:.0}ns {s}={d:.0}ns distinguishable={} ({s})\n" ++
            "w24-perf-pair-bench: compute median {s}={d:.0}ns {s}={d:.0}ns distinguishable={} ({s})\n" ++
            "w24-perf-pair-bench: summary={s}\n",
        gpa,
        io,
        .{
            config.arm_a.name,
            wall_a.median_ns,
            config.arm_b.name,
            wall_b.median_ns,
            paired_wall.distinguishable,
            paired_wall.verdict,
            config.arm_a.name,
            compute_a.median_ns,
            config.arm_b.name,
            compute_b.median_ns,
            paired_compute.distinguishable,
            paired_compute.verdict,
            summary_path,
        },
    );
}

fn verdictFor(distinguishable: bool) []const u8 {
    return if (distinguishable)
        "median bootstrap intervals do not overlap"
    else
        "median bootstrap intervals overlap: not distinguishable";
}
