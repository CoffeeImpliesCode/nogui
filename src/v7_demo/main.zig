//! v7 demo entry — switches between headless (default) and graphical modes.
//!
//!   zig build v7                # headless: 6 frames of JSON with injected clicks
//!   zig build v7 -- --window    # graphical: SDL3 + noapi window, mouse-driven
const std = @import("std");
const Io = std.Io;
/// Enables the Tracy profiler client (the "tracy" module's zones emit only
/// when the root declares this). Selects the enabled impl + links the C
/// client library via build.zig.
pub const tracy = @import("tracy");
pub const tracy_impl = @import("tracy_impl");
pub const tracy_options: tracy.Options = .{
    .on_demand = false,
    .no_broadcast = false,
    .only_localhost = false,
    .only_ipv4 = false,
    .delayed_init = false,
    .manual_lifetime = false,
    .verbose = false,
    .data_port = null,
    .broadcast_port = null,
    .default_callstack_depth = 8,
};
const nogui = @import("nogui");
const Id = nogui.Id;
const ui = @import("ui.zig");
const spotify_ui = @import("spotify.zig");
const calculator_ui = @import("calculator.zig");
const local_library = @import("local_library.zig");
const LocalTrack = @import("spotify_data.zig").LocalTrack;
const window_backend = @import("window.zig");
const perf = @import("perf.zig");
const measure_cpu = @import("measure_cpu.zig");
const headless = nogui.headless;
const hitTest = nogui.hitTest;
const App = nogui.App;

/// A value-taking flag with no value after it: print which flag is missing
/// its argument and fail. The runtime reports the returned error and exits
/// non-zero — same orelse-return shape as --hover's error path.
fn errMissingArg(flag: []const u8) error{MissingArg} {
    std.log.err("missing value for {s}", .{flag});
    return error.MissingArg;
}

fn nextPerfArg(args_it: anytype, flag: []const u8) error{MissingArg}![]const u8 {
    const value = args_it.next() orelse return errMissingArg(flag);
    if (std.mem.startsWith(u8, value, "--")) return errMissingArg(flag);
    return value;
}
const interactive_track_count_max: usize = 12;

fn interactiveTracks(records: []const LocalTrack) []const LocalTrack {
    return records[0..@min(records.len, interactive_track_count_max)];
}

pub fn main(init: std.process.Init) !void {
    var alloc = init.gpa;
    // var gpa = std.heap.DebugAllocator(.{}){};
    // defer _ = gpa.deinit();
    // const alloc = gpa.allocator();

    var app = App.init(alloc);
    defer app.deinit();
    var todo: ui.TodoApp = .{};
    var spotify: spotify_ui.SpotifyApp = .{};
    var calc: calculator_ui.CalculatorApp = .{};
    var tiger: ui.TigerApp = .{}; // registered at the --tiger dispatch (the App holds ONE root)
    var strokes: ui.TestStrokesApp = .{}; // --strokes: the stroke test scene

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer args_it.deinit();
    var window_mode = false;
    var spotify_mode = false; // --spotify: the Spotify layout stress scene
    var tiger_mode = false; // --tiger: the dedicated tiger showcase window
    var strokes_mode = false; // --strokes: the stroke test scene
    var calc_mode = false; // --calculator: the calculator demo window
    var gpu_remount_smoke = false; // --gpu-remount-smoke: finite GPU lifecycle run
    var perf_mode: ?perf.Mode = null;
    var perf_warmup_frames: ?u32 = null;
    var perf_sample_frames: ?u32 = null;
    var perf_output_path: ?[]const u8 = null;
    var perf_mode_seen = false;
    var perf_warmup_seen = false;
    var perf_sample_seen = false;
    var perf_output_seen = false;
    var scene_flag_count: u32 = 0;

    var frames: ?u32 = null;
    var shot_path: ?[]const u8 = null;
    var shot_hover: ?[2]f32 = null;
    var layout_path: ?[]const u8 = null;
    var layout_diff: ?[]const u8 = null;
    var layout_write_golden: ?[]const u8 = null;
    var sim_path: ?[]const u8 = null;
    var library_path: ?[]const u8 = null;
    var subpixel = false; // subpixel AA OFF by default; --subpixel enables
    var quad_debug = false; // --quad-debug tints the glyph quads
    var bgr = false; // --bgr: BGR subpixel stripe order
    var damp = true; // --no-damp: disable the chroma damping
    var no_subpixel = false; // --no-subpixel: explicitly disable subpixel AA
    var gpu_sort_verify = false; // --gpu-sort-verify: submit the bag in reverse paint order

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--spotify")) {
            spotify_mode = true;
            scene_flag_count += 1;
        } else if (std.mem.eql(u8, arg, "--tiger")) {
            // The dedicated showcase: the tiger LARGE (our sweep) next to
            // the librsvg reference render. Nothing else.
            tiger_mode = true;
            scene_flag_count += 1;
        } else if (std.mem.eql(u8, arg, "--strokes")) {
            // The systematic stroke test scene: curved thin strokes with
            // scale / algo / oversize sliders.
            strokes_mode = true;
            scene_flag_count += 1;
        } else if (std.mem.eql(u8, arg, "--window")) {
            window_mode = true;
        } else if (std.mem.eql(u8, arg, "--calculator")) {
            calc_mode = true;
            scene_flag_count += 1;
        } else if (std.mem.eql(u8, arg, "--gpu-remount-smoke")) {
            gpu_remount_smoke = true;
        } else if (std.mem.eql(u8, arg, "--gpu-sort-verify")) {
            // V1b verification: the CPU submits the drawable bag in
            // REVERSE paint order; the CS1 sort (stable on (z, order))
            // must restore it, so the runShot stays byte-identical.
            gpu_sort_verify = true;
        } else if (std.mem.eql(u8, arg, "--quad-debug")) {
            quad_debug = true;
        } else if (std.mem.eql(u8, arg, "--no-damp")) {
            damp = false;
        } else if (std.mem.eql(u8, arg, "--bgr")) {
            bgr = true;
        } else if (std.mem.eql(u8, arg, "--subpixel")) {
            subpixel = true;
        } else if (std.mem.eql(u8, arg, "--no-subpixel")) {
            subpixel = false;
            no_subpixel = true;
        } else if (std.mem.eql(u8, arg, "--frames")) {
            // Profiling: run the REAL windowed loop (swapchain presents
            // included) for N frames, then exit — tracy-capture friendly.
            frames = std.fmt.parseUnsigned(
                u32,
                args_it.next() orelse return errMissingArg("--frames"),
                10,
            ) catch return error.BadFramesArg;
        } else if (std.mem.eql(u8, arg, "--shot")) {
            shot_path = args_it.next() orelse return errMissingArg("--shot");
        } else if (std.mem.eql(u8, arg, "--layout")) {
            layout_path = args_it.next() orelse return errMissingArg("--layout"); // optional output file
        } else if (std.mem.eql(u8, arg, "--diff")) {
            layout_diff = args_it.next() orelse return errMissingArg("--diff"); // compare against a golden file
        } else if (std.mem.eql(u8, arg, "--write-golden")) {
            layout_write_golden = args_it.next() orelse return errMissingArg("--write-golden");
        } else if (std.mem.eql(u8, arg, "--sim")) {
            sim_path = args_it.next() orelse return errMissingArg("--sim"); // JSON-lines event script
        } else if (std.mem.eql(u8, arg, "--library")) {
            library_path = args_it.next() orelse return errMissingArg("--library");
        } else if (std.mem.eql(u8, arg, "--hover")) {
            // "--hover x,y": render the hover outline at a fixed position
            // in the shot (headless mouse-position verification).
            const spec = args_it.next() orelse return error.MissingHoverArg;
            var it = std.mem.splitScalar(u8, spec, ',');
            const xs = it.next() orelse return error.BadHoverArg;
            const ys = it.next() orelse return error.BadHoverArg;
            shot_hover = .{
                try std.fmt.parseFloat(f32, xs),
                try std.fmt.parseFloat(f32, ys),
            };
        } else if (std.mem.eql(u8, arg, "--perf-mode")) {
            if (perf_mode_seen) return error.DuplicatePerfFlag;
            perf_mode_seen = true;
            const value = try nextPerfArg(&args_it, "--perf-mode");
            perf_mode = perf.parseMode(value) catch return error.InvalidPerfMode;
        } else if (std.mem.eql(u8, arg, "--perf-warmup")) {
            if (perf_warmup_seen) return error.DuplicatePerfFlag;
            perf_warmup_seen = true;
            perf_warmup_frames = std.fmt.parseUnsigned(
                u32,
                try nextPerfArg(&args_it, "--perf-warmup"),
                10,
            ) catch return error.BadPerfWarmupArg;
        } else if (std.mem.eql(u8, arg, "--perf-frames")) {
            if (perf_sample_seen) return error.DuplicatePerfFlag;
            perf_sample_seen = true;
            perf_sample_frames = std.fmt.parseUnsigned(
                u32,
                try nextPerfArg(&args_it, "--perf-frames"),
                10,
            ) catch return error.BadPerfFramesArg;
        } else if (std.mem.eql(u8, arg, "--perf-out")) {
            if (perf_output_seen) return error.DuplicatePerfFlag;
            perf_output_seen = true;
            perf_output_path = try nextPerfArg(&args_it, "--perf-out");
        }
    }
    const perf_config = try perf.parseConfig(.{
        .mode = perf_mode,
        .warmup_frames = perf_warmup_frames,
        .sample_frames = perf_sample_frames,
        .output_path = perf_output_path,
        .scene_flag_count = scene_flag_count,
        .conflicting_flag = window_mode or frames != null or shot_path != null or
            layout_path != null or layout_diff != null or layout_write_golden != null or
            sim_path != null or library_path != null or shot_hover != null or
            gpu_remount_smoke or gpu_sort_verify or subpixel or no_subpixel or quad_debug or
            bgr or !damp,
    });

    if (spotify_mode and !gpu_remount_smoke) {
        _ = try app.register(spotify_ui.SpotifyApp, &spotify);
    } else if (calc_mode and !gpu_remount_smoke) {
        _ = try app.register(calculator_ui.CalculatorApp, &calc);
    } else if (perf_config != null and tiger_mode) {
        _ = try app.register(ui.TigerApp, &tiger);
    } else if (perf_config != null and strokes_mode) {
        _ = try app.register(ui.TestStrokesApp, &strokes);
    } else {
        // Keep the default root registered for specialized modes until they
        // replace it below. The simulator still dispatches TodoApp for those
        // legacy modes.
        _ = try app.register(ui.TodoApp, &todo);
    }

    if (perf_config) |config| {
        if (strokes_mode) {
            try window_backend.run(
                ui.TestStrokesApp,
                &app,
                &strokes,
                false,
                false,
                false,
                true,
                false,
                null,
                null,
                config,
            );
        } else if (tiger_mode) {
            try window_backend.run(
                ui.TigerApp,
                &app,
                &tiger,
                false,
                false,
                false,
                true,
                false,
                null,
                null,
                config,
            );
        } else if (spotify_mode) {
            try window_backend.run(
                spotify_ui.SpotifyApp,
                &app,
                &spotify,
                false,
                false,
                false,
                true,
                false,
                null,
                null,
                config,
            );
        } else if (calc_mode) {
            try window_backend.run(
                calculator_ui.CalculatorApp,
                &app,
                &calc,
                false,
                false,
                false,
                true,
                false,
                null,
                null,
                config,
            );
        } else {
            try window_backend.run(
                ui.TodoApp,
                &app,
                &todo,
                false,
                false,
                false,
                true,
                false,
                null,
                null,
                config,
            );
        }
        return;
    }

    if (gpu_remount_smoke) {
        // This path is deliberately separate from --window and --frames:
        // the window driver owns a fixed three-frame lifecycle schedule.
        ui.gpu_remount_smoke = true;
        defer ui.gpu_remount_smoke = false;
        window_backend.run(
            ui.TodoApp,
            &app,
            &todo,
            subpixel,
            quad_debug,
            bgr,
            damp,
            gpu_sort_verify,
            null,
            null,
            null,
        ) catch |e| {
            std.log.err("gpu-remount-smoke failed: {s}", .{@errorName(e)});
            return e;
        };
        return;
    }

    // Headless driver: read JSON-lines events from a script, feed them to
    // the core (time included — every .frame event carries the driver's
    // tick + clock), and print one JSON frame dump per frame event. Fully
    // deterministic: the same script always produces the same output.
    // TigerBeetle-style full testing — the system is a pure function of the
    // input stream.
    if (sim_path) |sp| {
        app.serialize_json = true;
        defer measure_cpu.deinit();
        app.measure = measure_cpu.measure;

        var io_impl = std.Io.Threaded.init(alloc, .{});
        defer io_impl.deinit();
        const io = io_impl.io();
        const stdout = std.Io.File.stdout();
        const content = try Io.Dir.cwd().readFileAlloc(io, sp, alloc, .unlimited);
        defer alloc.free(content);

        var it = std.mem.splitScalar(u8, content, '\n');
        var line_no: usize = 0;
        while (it.next()) |line| {
            line_no += 1;
            if (line.len == 0) continue;
            const ev = headless.eventFromJson(alloc, line) catch |err| {
                std.log.err("sim line {d}: {s}", .{ line_no, @errorName(err) });
                std.process.exit(1);
            };
            const out = (if (spotify_mode)
                app.handle(spotify_ui.SpotifyApp, &spotify, ev)
            else if (calc_mode)
                app.handle(calculator_ui.CalculatorApp, &calc, ev)
            else
                app.handle(ui.TodoApp, &todo, ev)) catch |err| {
                std.log.err("sim line {d}: {s}", .{ line_no, @errorName(err) });
                std.process.exit(1);
            };
            if (out) |o| {
                // The frame dump: layout (tree) + state decisions (focus,
                // hover, pressed — 0 = none). Enough to debug any session.
                const dump = try std.fmt.allocPrint(
                    alloc,
                    "{{\"frame\":{d},\"focus\":{d},\"hover\":{d},\"pressed\":{d},\"tree\":{s}}}\n",
                    .{
                        o.frame_number,
                        if (o.focus) |f| f.index() else 0,
                        if (o.hover) |h| h.index() else 0,
                        if (o.pressed) |p| p.index() else 0,
                        if (o.json) |j| j else "",
                    },
                );
                defer alloc.free(dump);
                try stdout.writeStreamingAll(io, dump);
                if (o.json) |j| alloc.free(j);
            }
        }
        return;
    }

    if (strokes_mode) {
        _ = try app.register(ui.TestStrokesApp, &strokes);
        if (frames) |n| {
            window_backend.run(
                ui.TestStrokesApp,
                &app,
                &strokes,
                subpixel,
                quad_debug,
                bgr,
                damp,
                gpu_sort_verify,
                n,
                null,
                null,
            ) catch |e| {
                std.log.err("run failed: {s}", .{@errorName(e)});
                return e;
            };
            return;
        }
        if (shot_path) |p| {
            window_backend.runShot(
                ui.TestStrokesApp,
                &app,
                &strokes,
                p,
                shot_hover,
                subpixel,
                quad_debug,
                bgr,
                damp,
                gpu_sort_verify,
            ) catch |e| {
                std.log.err("runShot failed: {s}", .{@errorName(e)});
                return e;
            };
            return;
        }
        try window_backend.run(
            ui.TestStrokesApp,
            &app,
            &strokes,
            subpixel,
            quad_debug,
            bgr,
            damp,
            gpu_sort_verify,
            null,
            null,
            null,
        );
        return;
    }

    if (tiger_mode) {
        _ = try app.register(ui.TigerApp, &tiger);
        if (frames) |n| {
            window_backend.run(
                ui.TigerApp,
                &app,
                &tiger,
                subpixel,
                quad_debug,
                bgr,
                damp,
                gpu_sort_verify,
                n,
                null,
                null,
            ) catch |e| {
                std.log.err("run failed: {s}", .{@errorName(e)});
                return e;
            };
            return;
        }
        if (shot_path) |p| {
            window_backend.runShot(
                ui.TigerApp,
                &app,
                &tiger,
                p,
                shot_hover,
                subpixel,
                quad_debug,
                bgr,
                damp,
                gpu_sort_verify,
            ) catch |e| {
                std.log.err("runShot failed: {s}", .{@errorName(e)});
                return e;
            };
            return;
        }
        try window_backend.run(
            ui.TigerApp,
            &app,
            &tiger,
            subpixel,
            quad_debug,
            bgr,
            damp,
            gpu_sort_verify,
            null,
            null,
            null,
        );
        return;
    }

    if (spotify_mode) {
        if (frames == null and shot_path == null and layout_path == null) {
            var io_impl = std.Io.Threaded.init(alloc, .{});
            defer io_impl.deinit();
            const io = io_impl.io();

            var default_library_root: ?[]u8 = null;
            defer if (default_library_root) |root_path| alloc.free(root_path);
            if (library_path == null) {
                if (init.environ_map.get("HOME")) |home| {
                    default_library_root = std.fs.path.join(alloc, &.{ home, "songs", "Sunnify" }) catch |err| blk: {
                        std.log.err("default Spotify library path failed: {s}", .{@errorName(err)});
                        break :blk null;
                    };
                } else {
                    std.log.err("HOME is unset; Spotify playback library is unavailable", .{});
                }
            }

            const selected_library_root: ?[]const u8 = if (library_path) |path|
                path
            else if (default_library_root) |path|
                path
            else
                null;
            var library: ?local_library.LocalLibrary = null;
            defer if (library) |*value| value.deinit();
            if (selected_library_root) |path| {
                library = local_library.LocalLibrary.scan(alloc, io, path, .{}) catch |err| blk: {
                    std.log.err("Spotify library scan failed for {s}: {s}", .{ path, @errorName(err) });
                    std.log.err("Spotify playback unavailable: local library scan failed", .{});
                    _ = spotify.initLocalTracks(&.{});
                    break :blk null;
                };
            } else {
                std.log.err("Spotify playback unavailable: no local library configured", .{});
                _ = spotify.initLocalTracks(&.{});
            }

            var audio_tracks: ?[]const LocalTrack = null;

            if (library) |*value| {
                const records = interactiveTracks(value.records());
                const active_count = spotify.initLocalTracks(records);
                if (active_count == 0) {
                    std.log.err("Spotify playback unavailable: no supported local audio tracks found", .{});
                } else {
                    audio_tracks = records[0..active_count];
                }
            }

            try window_backend.run(
                spotify_ui.SpotifyApp,
                &app,
                &spotify,
                subpixel,
                quad_debug,
                bgr,
                damp,
                gpu_sort_verify,
                null,
                audio_tracks,
                null,
            );
            return;
        }
        if (frames) |n| {
            window_backend.run(
                spotify_ui.SpotifyApp,
                &app,
                &spotify,
                subpixel,
                quad_debug,
                bgr,
                damp,
                gpu_sort_verify,
                n,
                null,
                null,
            ) catch |e| {
                std.log.err("run failed: {s}", .{@errorName(e)});
                return e;
            };
            return;
        }
        if (shot_path) |p| {
            window_backend.runShot(
                spotify_ui.SpotifyApp,
                &app,
                &spotify,
                p,
                shot_hover,
                subpixel,
                quad_debug,
                bgr,
                damp,
                gpu_sort_verify,
            ) catch |e| {
                std.log.err("runShot failed: {s}", .{@errorName(e)});
                return e;
            };
            return;
        }
    }

    if (calc_mode) {
        if (frames) |n| {
            window_backend.run(
                calculator_ui.CalculatorApp,
                &app,
                &calc,
                subpixel,
                quad_debug,
                bgr,
                damp,
                gpu_sort_verify,
                n,
                null,
                null,
            ) catch |e| {
                std.log.err("run failed: {s}", .{@errorName(e)});
                return e;
            };
            return;
        }
        if (shot_path) |p| {
            window_backend.runShot(
                calculator_ui.CalculatorApp,
                &app,
                &calc,
                p,
                shot_hover,
                subpixel,
                quad_debug,
                bgr,
                damp,
                gpu_sort_verify,
            ) catch |e| {
                std.log.err("runShot failed: {s}", .{@errorName(e)});
                return e;
            };
            return;
        }
        try window_backend.run(
            calculator_ui.CalculatorApp,
            &app,
            &calc,
            subpixel,
            quad_debug,
            bgr,
            damp,
            gpu_sort_verify,
            null,
            null,
            null,
        );
        return;
    }

    if (window_mode) {
        try window_backend.run(ui.TodoApp, &app, &todo, subpixel, quad_debug, bgr, damp, gpu_sort_verify, null, null, null);
        return;
    }

    if (frames) |n| {
        window_backend.run(
            ui.TodoApp,
            &app,
            &todo,
            subpixel,
            quad_debug,
            bgr,
            damp,
            gpu_sort_verify,
            n,
            null,
            null,
        ) catch |e| {
            std.log.err("run failed: {s}", .{@errorName(e)});
            return e;
        };
        return;
    }

    if (shot_path) |p| {
        window_backend.runShot(
            ui.TodoApp,
            &app,
            &todo,
            p,
            shot_hover,
            subpixel,
            quad_debug,
            bgr,
            damp,
            gpu_sort_verify,
        ) catch |e| {
            std.log.err("runShot failed: {s}", .{@errorName(e)});
            return e;
        };
        return;
    }

    // Headless layout verification: CPU-only (no GPU, no display). Lays out
    // one frame at 900x700 with the real FreeType advances, checks the
    // layout invariants, and renders an ASCII map (with the optional
    // --hover outline) to the file or stdout.
    if (layout_path) |lp| {
        app.serialize_json = true;
        defer measure_cpu.deinit();
        app.measure = measure_cpu.measure;
        if (!spotify_mode) todo.frame_count = 1;
        const out = if (spotify_mode)
            try app.frame(spotify_ui.SpotifyApp, &spotify, 1, .{ .width = 1100, .height = 1160 })
        else
            try app.frame(ui.TodoApp, &todo, 1, .{ .width = 1100, .height = 1160 });
        defer if (out.json) |j| alloc.free(j);

        var io_impl = std.Io.Threaded.init(alloc, .{});
        defer io_impl.deinit();
        const io = io_impl.io();
        const stdout = std.Io.File.stdout();

        const hover_id = if (shot_hover) |p| hitTest(out.tree, p) else null;
        const report = try headless.verifyLayout(alloc, out.tree, app.measure, .{ .width = 1100, .height = 1160 });
        defer alloc.free(report);
        try stdout.writeStreamingAll(io, report);

        // Golden fingerprint: rects only (labels/values/frame counters are
        // dynamic and would make a map diff flaky).
        const fp = try headless.layoutFingerprint(alloc, out.tree);
        defer alloc.free(fp);
        if (layout_write_golden) |gp| {
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = gp, .data = fp });
            const msg = try std.fmt.allocPrint(alloc, "golden written: {s}\n", .{gp});
            defer alloc.free(msg);
            try stdout.writeStreamingAll(io, msg);
        }
        if (layout_diff) |gp| {
            const expected = try Io.Dir.cwd().readFileAlloc(io, gp, alloc, .unlimited);
            defer alloc.free(expected);
            if (std.mem.eql(u8, expected, fp)) {
                try stdout.writeStreamingAll(io, "layout matches golden\n");
            } else {
                const msg = try std.fmt.allocPrint(alloc, "LAYOUT DIFFERS from {s}\n", .{gp});
                defer alloc.free(msg);
                try stdout.writeStreamingAll(io, msg);
                return error.LayoutGoldenMismatch;
            }
        }

        const map = try headless.renderAscii(alloc, out.tree, hover_id);
        defer alloc.free(map);
        const rows = std.mem.count(u8, map, "\n");
        if (lp.len > 0) {
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = lp, .data = map });
            const msg = try std.fmt.allocPrint(alloc, "layout map: {s} ({d} rows)\n", .{ lp, rows });
            defer alloc.free(msg);
            try stdout.writeStreamingAll(io, msg);
        } else {
            try stdout.writeStreamingAll(io, map);
            const msg = try std.fmt.allocPrint(alloc, "-- (layout JSON follows)\n{s}\n", .{out.json orelse ""});
            defer alloc.free(msg);
            try stdout.writeStreamingAll(io, msg);
        }

        // Scriptable: violations fail the process.
        if (!std.mem.startsWith(u8, report, "OK")) return error.LayoutVerificationFailed;
        return;
    }

    // Headless: 6 frames with injected clicks to demonstrate interaction.
    // Uses the same CPU measure so the layout matches the windowed mode.
    app.serialize_json = true;
    defer measure_cpu.deinit();
    app.measure = measure_cpu.measure;
    for (0..6) |i| {
        todo.frame_count = @intCast(i + 1);
        const out = try app.frame(ui.TodoApp, &todo, @intCast(i + 1), .{ .width = 800, .height = 600 });
        defer if (out.json) |j| alloc.free(j);
        std.log.info("frame {d}: {s}", .{ i + 1, out.json orelse "" });

        const click_label: ?[]const u8 = switch (i) {
            1 => "inc",
            2 => "toggle0",
            3 => "add",
            else => null,
        };
        if (click_label) |label| {
            var found: ?Id = null;
            for (out.tree.nodes.items) |*n| {
                if (n.kind == .button and std.mem.eql(u8, n.kind.button.label, label)) {
                    found = n.id;
                    break;
                }
            }
            if (found) |id| app.click(out.tree, id);
        }
    }
}

test {
    _ = @import("FramePacer.zig");
    _ = @import("perf.zig");
}
