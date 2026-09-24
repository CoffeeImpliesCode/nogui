//! v7 demo entry — switches between headless (default) and graphical modes.
//!
//!   zig build v7                # headless: 6 frames of JSON with injected clicks
//!   zig build v7 -- --window    # graphical: SDL3 + noapi window, mouse-driven
//!   zig build v7 -- --keyed-reorder-smoke  # headless: verify focus across todo reorder
//!   zig build v7 -- --shortcut-smoke  # headless: W10 actions, bindings, chords
//!   zig build v7 -- --shortcut-layout-check=x11[:WAIT_MS]  # live layout labels + cursor
//!   zig build v7 -- --shortcut-native[=MS]  # hosted: real window, real keys, external controller
//!   zig build v7 -- --shortcut-native --shortcut-pixels=out.ppm  # hosted + PPM of the last frame
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
const nogui_test = @import("nogui_test");
const nogui_text = @import("nogui_text");
const ui = @import("ui.zig");
const todo_shortcuts = @import("todo_shortcuts.zig");
const spotify_ui = @import("spotify.zig");
const calculator_ui = @import("calculator.zig");
const local_library = @import("local_library.zig");
const LocalTrack = @import("spotify_data.zig").LocalTrack;
const window_backend = @import("window.zig");
const perf = @import("perf.zig");
const demo_fonts = @import("fonts.zig");
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

/// The per-step budget the hosted arm publishes. Zero is refused: a step with
/// no budget cannot report that its evidence never arrived, which is the one
/// thing a controller needs to hear.
fn parseShortcutBudget(value: []const u8) error{ BadShortcutStepArg, ZeroShortcutStepBudget }!u64 {
    const budget = std.fmt.parseUnsigned(u64, value, 10) catch return error.BadShortcutStepArg;
    if (budget == 0) return error.ZeroShortcutStepBudget;
    return budget;
}

const interactive_track_count_max: usize = 12;

fn interactiveTracks(records: []const LocalTrack) []const LocalTrack {
    return records[0..@min(records.len, interactive_track_count_max)];
}

fn runKeyedReorderSmoke(io: Io, app: *App, todo: *ui.TodoApp) !void {
    const surface: nogui.Size = .{ .width = 1400, .height = 1600 };
    const first = try app.frame(1, surface);
    const focused_id = app.widgetIdForKey(.root, .{ .u64 = 1 }) orelse
        return error.KeyedReorderTargetMissing;
    const other_id = app.widgetIdForKey(.root, .{ .u64 = 0 }) orelse
        return error.KeyedReorderOtherItemMissing;
    const first_node_id = first.tree.frameNode(focused_id) orelse
        return error.KeyedReorderTargetMissing;
    const first_other_id = first.tree.frameNode(other_id) orelse
        return error.KeyedReorderOtherItemMissing;
    const target = first.tree.nodeConst(first_node_id) orelse return error.KeyedReorderTargetMissing;
    if (target.kind != .checkbox) return error.KeyedReorderWrongTarget;
    if (target.kind.checkbox.value != &todo.done[1]) return error.KeyedReorderWrongTarget;
    if (first_other_id.index() >= first_node_id.index()) return error.KeyedReorderInitialOrderWrong;

    const rect = nogui.widget.absoluteRect(first.tree, first_node_id);
    const x = rect.x + rect.w / 2;
    const y = rect.y + rect.h / 2;
    _ = try app.handle(.{
        .mouse_down = .{ .button = .left, .x = x, .y = y },
    });
    _ = try app.handle(.{
        .mouse_up = .{ .button = .left, .x = x, .y = y },
    });
    if (!todo.done[1] or todo.done[0]) return error.KeyedReorderMouseToggledWrongItem;
    const clicked_focus = app.focus_manager.current orelse return error.KeyedReorderMouseFocusMissing;
    if (!clicked_focus.eql(focused_id)) return error.KeyedReorderMouseFocusWrong;

    todo.item_order[0] = 1;
    todo.item_order[1] = 0;
    const second = try app.frame(2, surface);
    const reordered_id = app.widgetIdForKey(.root, .{ .u64 = 1 }) orelse
        return error.KeyedReorderTargetMissing;
    if (!reordered_id.eql(focused_id)) return error.KeyedReorderIdentityChanged;
    const second_node_id = second.tree.frameNode(reordered_id) orelse
        return error.KeyedReorderTargetMissing;
    const second_other_id = second.tree.frameNode(other_id) orelse
        return error.KeyedReorderOtherItemMissing;
    if (second_node_id == first_node_id or second_node_id.index() >= second_other_id.index()) {
        return error.KeyedReorderDenseOrderUnchanged;
    }
    const second_target = second.tree.nodeConst(second_node_id) orelse
        return error.KeyedReorderTargetMissing;
    if (second_target.kind != .checkbox) return error.KeyedReorderWrongTarget;
    if (second_target.kind.checkbox.value != &todo.done[1]) return error.KeyedReorderWrongTarget;
    const retained_focus = second.focus orelse return error.KeyedReorderFocusLost;
    if (!retained_focus.eql(focused_id)) return error.KeyedReorderFocusMoved;
    if (!todo.done[1] or todo.done[0]) return error.KeyedReorderFrameChangedItems;

    _ = try app.handle(.{
        .key_down = .{ .key = .space, .shift = false },
    });
    if (todo.done[1] or todo.done[0]) return error.KeyedReorderKeyboardToggledWrongItem;
    try Io.File.stdout().writeStreamingAll(io, "keyed-reorder-smoke: OK\n");
}

pub fn main(init: std.process.Init) !void {
    var alloc = init.gpa;

    var todo: ui.TodoApp = .{};
    var spotify: spotify_ui.SpotifyApp = .{};
    var calc: calculator_ui.CalculatorApp = .{};
    var tiger: ui.TigerApp = .{};
    var strokes: ui.TestStrokesApp = .{};
    // Spotify's view borrows track metadata through App deinit.
    var library: ?local_library.LocalLibrary = null;
    defer if (library) |*value| value.deinit();
    var session = try nogui.Session.init(alloc);
    defer session.deinit() catch @panic("demo Session has live models or windows");
    var app = try App.init(alloc, &session);
    defer app.deinit();

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer args_it.deinit();
    var window_mode = false;
    var uncapped = false;
    var spotify_mode = false; // --spotify: the Spotify layout stress scene
    var tiger_mode = false; // --tiger: the dedicated tiger showcase window
    var strokes_mode = false; // --strokes: the stroke test scene
    var calc_mode = false; // --calculator: the calculator demo window
    var gpu_remount_smoke = false; // --gpu-remount-smoke: finite GPU lifecycle run
    var keyed_reorder_smoke = false; // --keyed-reorder-smoke: finite headless focus check
    var ruler_smoke = false; // --ruler-smoke: opt-in custom-element Todo view
    var paint_smoke = false; // --paint-smoke: W13 GPU pixel specimen on the Todo root
    var shortcut_smoke = false; // --shortcut-smoke: W10 configurable Todo shortcuts
    var shortcut_layout_spec: ?[]const u8 = null; // --shortcut-layout-check=DRIVER[:MS]
    var shortcut_native = false; // --shortcut-native[=MS]: the hosted arm
    var shortcut_step_ms: ?u64 = null; // --shortcut-native=MS | --shortcut-step-ms MS
    var shortcut_pixels: ?[]const u8 = null; // --shortcut-pixels=PATH
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
        } else if (std.mem.eql(u8, arg, "--uncapped")) {
            uncapped = true;
        } else if (std.mem.eql(u8, arg, "--calculator")) {
            calc_mode = true;
            scene_flag_count += 1;
        } else if (std.mem.eql(u8, arg, "--gpu-remount-smoke")) {
            gpu_remount_smoke = true;
        } else if (std.mem.eql(u8, arg, "--keyed-reorder-smoke")) {
            keyed_reorder_smoke = true;
        } else if (std.mem.eql(u8, arg, "--ruler-smoke")) {
            ruler_smoke = true;
        } else if (std.mem.eql(u8, arg, "--paint-smoke")) {
            paint_smoke = true;
        } else if (std.mem.eql(u8, arg, "--shortcut-smoke")) {
            shortcut_smoke = true;
        } else if (std.mem.startsWith(u8, arg, "--shortcut-layout-check=") or
            std.mem.eql(u8, arg, "--shortcut-layout-check"))
        {
            // The layout phase reads the live keyboard map, so it names the
            // SDL video driver explicitly and never inherits the session's.
            if (shortcut_layout_spec != null) return error.DuplicateLayoutCheckFlag;
            shortcut_layout_spec = if (std.mem.startsWith(u8, arg, "--shortcut-layout-check="))
                arg["--shortcut-layout-check=".len..]
            else
                try nextPerfArg(&args_it, "--shortcut-layout-check");
            if (shortcut_layout_spec.?.len == 0) return error.BadLayoutCheckArg;
        } else if (std.mem.startsWith(u8, arg, "--shortcut-native=") or
            std.mem.eql(u8, arg, "--shortcut-native"))
        {
            // The hosted arm drives one real window from one real controller,
            // so it refuses to share a run with the headless gate or the
            // layout probe: one run, one set of claims.
            if (shortcut_native) return error.DuplicateShortcutNativeFlag;
            if (shortcut_smoke or shortcut_layout_spec != null)
                return error.ConflictingShortcutFlags;
            shortcut_native = true;
            // Only the `=` form carries a budget, so the bare flag never
            // swallows the argument that follows it. `--shortcut-step-ms` is
            // the form that takes the next argument.
            if (std.mem.startsWith(u8, arg, "--shortcut-native=")) {
                const value = arg["--shortcut-native=".len..];
                if (value.len == 0) return error.BadShortcutStepArg;
                shortcut_step_ms = try parseShortcutBudget(value);
            }
        } else if (std.mem.eql(u8, arg, "--shortcut-step-ms")) {
            if (shortcut_step_ms != null) return error.DuplicateShortcutStepFlag;
            shortcut_step_ms = try parseShortcutBudget(
                try nextPerfArg(&args_it, "--shortcut-step-ms"),
            );
        } else if (std.mem.startsWith(u8, arg, "--shortcut-pixels=")) {
            // The last presented frame, read back out of the run's own
            // target and written as a P6 PPM.
            if (shortcut_pixels != null) return error.DuplicateShortcutPixelsFlag;
            shortcut_pixels = arg["--shortcut-pixels=".len..];
            if (shortcut_pixels.?.len == 0) return error.BadShortcutPixelsArg;
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
            gpu_remount_smoke or keyed_reorder_smoke or ruler_smoke or paint_smoke or
            shortcut_smoke or shortcut_layout_spec != null or
            shortcut_native or shortcut_step_ms != null or shortcut_pixels != null or
            gpu_sort_verify or uncapped or subpixel or no_subpixel or quad_debug or bgr or !damp,
    });
    if (ruler_smoke and (scene_flag_count != 0 or gpu_remount_smoke or
        keyed_reorder_smoke or sim_path != null))
        return error.RulerSmokeRequiresTodo;
    // Both hosted-only options mean nothing without the hosted arm, and
    // saying so here is cheaper than a run that opens a window to do nothing.
    if (!shortcut_native and (shortcut_step_ms != null or shortcut_pixels != null))
        return error.ShortcutOptionsNeedNative;
    ui.custom_ruler_smoke = ruler_smoke;
    defer ui.custom_ruler_smoke = false;
    ui.custom_paint_smoke = paint_smoke;
    defer ui.custom_paint_smoke = false;

    // The shortcut arms always run against the Todo root and return before
    // any other driver starts, so they mount the root themselves.
    if (shortcut_native or shortcut_pixels != null or shortcut_step_ms != null or
        shortcut_smoke or shortcut_layout_spec != null)
    {
        try app.mountRoot(ui.TodoApp, &todo);
        var options: todo_shortcuts.Options = .{ .interaction = shortcut_smoke };
        if (shortcut_layout_spec) |spec| {
            // The wait lets the real SDL queue deliver KEYMAP_CHANGED.
            const colon = std.mem.indexOfScalar(u8, spec, ':') orelse spec.len;
            const driver = spec[0..colon];
            if (driver.len == 0) return error.BadLayoutCheckArg;
            options.video_driver = driver;
            if (colon == spec.len) {
                options.layout_wait_ms = 0;
            } else {
                options.layout_wait_ms = std.fmt.parseUnsigned(u31, spec[colon + 1 ..], 10) catch
                    return error.BadLayoutCheckArg;
            }
        }
        if (shortcut_native) {
            // The hosted arm owns the whole run: it opens the host window,
            // paints the real scene and waits for a controller on the
            // caller's own display server.
            options.native = true;
            options.step_ms = shortcut_step_ms orelse todo_shortcuts.native_step_ms;
            options.pixel_path = shortcut_pixels;
        }
        try todo_shortcuts.run(alloc, init.io, &app, &session, &todo, options);
        return;
    }

    // The App borrows exactly the root that the selected driver will use.
    // Replay takes precedence over graphical scene flags; remount and keyed
    // smokes always use Todo, even if another scene flag was also supplied.
    if (keyed_reorder_smoke or gpu_remount_smoke) {
        try app.mountRoot(ui.TodoApp, &todo);
    } else if (sim_path != null) {
        if (spotify_mode) {
            try app.mountRoot(spotify_ui.SpotifyApp, &spotify);
        } else if (calc_mode) {
            try app.mountRoot(calculator_ui.CalculatorApp, &calc);
        } else {
            try app.mountRoot(ui.TodoApp, &todo);
        }
    } else if (strokes_mode) {
        try app.mountRoot(ui.TestStrokesApp, &strokes);
    } else if (tiger_mode) {
        try app.mountRoot(ui.TigerApp, &tiger);
    } else if (spotify_mode) {
        try app.mountRoot(spotify_ui.SpotifyApp, &spotify);
    } else if (calc_mode) {
        try app.mountRoot(calculator_ui.CalculatorApp, &calc);
    } else {
        try app.mountRoot(ui.TodoApp, &todo);
    }

    if (keyed_reorder_smoke) {
        try runKeyedReorderSmoke(init.io, &app, &todo);
        return;
    }

    if (perf_config) |config| {
        if (strokes_mode) {
            try window_backend.run(
                ui.TestStrokesApp,
                &app,
                &strokes,
                .{ .perf = config },
            );
        } else if (tiger_mode) {
            try window_backend.run(
                ui.TigerApp,
                &app,
                &tiger,
                .{ .perf = config },
            );
        } else if (spotify_mode) {
            try window_backend.run(
                spotify_ui.SpotifyApp,
                &app,
                &spotify,
                .{ .perf = config },
            );
        } else if (calc_mode) {
            try window_backend.run(
                calculator_ui.CalculatorApp,
                &app,
                &calc,
                .{ .perf = config },
            );
        } else {
            try window_backend.run(
                ui.TodoApp,
                &app,
                &todo,
                .{ .perf = config },
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
            .{
                .subpixel = subpixel,
                .quad_debug = quad_debug,
                .bgr_order = bgr,
                .damp_chroma = damp,
                .gpu_sort_verify = gpu_sort_verify,
                .uncapped = uncapped,
            },
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
        // One `TextService` and one retained scratch arena, owned in place by
        // this process: the App measures through the same canonical
        // `MeasureSource` the GPU path binds, with no thread-local scope.
        // SAFETY: `init` fills the measurer before `source()` borrows it.
        var measurer: nogui_text.TextMeasurer = undefined;
        try measurer.init(alloc, &demo_fonts.pinned_fonts, demo_fonts.default_text_size);
        defer measurer.deinit();
        app.measure = measurer.source();

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
            const out = nogui_test.dispatcher.dispatchJson(&app, null, alloc, line) catch |err| {
                std.log.err("sim line {d}: {s}", .{ line_no, @errorName(err) });
                std.process.exit(1);
            };
            if (out) |o| {
                // The replay dump's numeric targets index THIS tree, while
                // App keeps stable handles across frame reorderings.
                const focus = if (o.focus) |id| if (o.tree.frameNode(id)) |node| node.index() else 0 else 0;
                const hover = if (o.hover) |id| if (o.tree.frameNode(id)) |node| node.index() else 0 else 0;
                const pressed = if (o.pressed) |id| if (o.tree.frameNode(id)) |node| node.index() else 0 else 0;
                const dump = try std.fmt.allocPrint(
                    alloc,
                    "{{\"frame\":{d},\"focus\":{d},\"hover\":{d},\"pressed\":{d},\"tree\":{s}}}\n",
                    .{ o.frame_number, focus, hover, pressed, o.json orelse "[]" },
                );
                defer alloc.free(dump);
                try stdout.writeStreamingAll(io, dump);
                if (o.json) |j| alloc.free(j);
            }
        }
        return;
    }

    if (strokes_mode) {
        if (frames) |n| {
            window_backend.run(
                ui.TestStrokesApp,
                &app,
                &strokes,
                .{
                    .subpixel = subpixel,
                    .quad_debug = quad_debug,
                    .bgr_order = bgr,
                    .damp_chroma = damp,
                    .gpu_sort_verify = gpu_sort_verify,
                    .uncapped = uncapped,
                    .max_frames = n,
                },
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
            .{
                .subpixel = subpixel,
                .quad_debug = quad_debug,
                .bgr_order = bgr,
                .damp_chroma = damp,
                .gpu_sort_verify = gpu_sort_verify,
                .uncapped = uncapped,
            },
        );
        return;
    }

    if (tiger_mode) {
        if (frames) |n| {
            window_backend.run(
                ui.TigerApp,
                &app,
                &tiger,
                .{
                    .subpixel = subpixel,
                    .quad_debug = quad_debug,
                    .bgr_order = bgr,
                    .damp_chroma = damp,
                    .gpu_sort_verify = gpu_sort_verify,
                    .uncapped = uncapped,
                    .max_frames = n,
                },
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
            .{
                .subpixel = subpixel,
                .quad_debug = quad_debug,
                .bgr_order = bgr,
                .damp_chroma = damp,
                .gpu_sort_verify = gpu_sort_verify,
                .uncapped = uncapped,
            },
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
                .{
                    .subpixel = subpixel,
                    .quad_debug = quad_debug,
                    .bgr_order = bgr,
                    .damp_chroma = damp,
                    .gpu_sort_verify = gpu_sort_verify,
                    .uncapped = uncapped,
                    .audio_tracks = audio_tracks,
                },
            );
            return;
        }
        if (frames) |n| {
            window_backend.run(
                spotify_ui.SpotifyApp,
                &app,
                &spotify,
                .{
                    .subpixel = subpixel,
                    .quad_debug = quad_debug,
                    .bgr_order = bgr,
                    .damp_chroma = damp,
                    .gpu_sort_verify = gpu_sort_verify,
                    .uncapped = uncapped,
                    .max_frames = n,
                },
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
                .{
                    .subpixel = subpixel,
                    .quad_debug = quad_debug,
                    .bgr_order = bgr,
                    .damp_chroma = damp,
                    .gpu_sort_verify = gpu_sort_verify,
                    .uncapped = uncapped,
                    .max_frames = n,
                },
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
            .{
                .subpixel = subpixel,
                .quad_debug = quad_debug,
                .bgr_order = bgr,
                .damp_chroma = damp,
                .gpu_sort_verify = gpu_sort_verify,
                .uncapped = uncapped,
            },
        );
        return;
    }

    if (window_mode) {
        try window_backend.run(
            ui.TodoApp,
            &app,
            &todo,
            .{
                .subpixel = subpixel,
                .quad_debug = quad_debug,
                .bgr_order = bgr,
                .damp_chroma = damp,
                .gpu_sort_verify = gpu_sort_verify,
                .uncapped = uncapped,
            },
        );
        return;
    }

    if (frames) |n| {
        window_backend.run(
            ui.TodoApp,
            &app,
            &todo,
            .{
                .subpixel = subpixel,
                .quad_debug = quad_debug,
                .bgr_order = bgr,
                .damp_chroma = damp,
                .gpu_sort_verify = gpu_sort_verify,
                .uncapped = uncapped,
                .max_frames = n,
            },
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
        // SAFETY: `init` fills the measurer before `source()` borrows it.
        var measurer: nogui_text.TextMeasurer = undefined;
        try measurer.init(alloc, &demo_fonts.pinned_fonts, demo_fonts.default_text_size);
        defer measurer.deinit();
        app.measure = measurer.source();
        const out = try app.frame(1, .{ .width = 1100, .height = 1160 });
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
    // Uses the same CPU measurer so the layout matches the windowed mode.
    app.serialize_json = true;
    // SAFETY: `init` fills the measurer before `source()` borrows it.
    var measurer: nogui_text.TextMeasurer = undefined;
    try measurer.init(alloc, &demo_fonts.pinned_fonts, demo_fonts.default_text_size);
    defer measurer.deinit();
    app.measure = measurer.source();
    for (0..6) |i| {
        const out = try app.frame(@intCast(i + 1), .{ .width = 800, .height = 600 });
        defer if (out.json) |j| alloc.free(j);
        std.log.info("frame {d}: {s}", .{ i + 1, out.json orelse "" });

        const click_key: ?nogui.ComponentKey = switch (i) {
            1 => .{ .static = "counter-inc" },
            2 => .{ .u64 = 0 }, // The first todo item, independent of its caption.
            3 => .{ .static = "todo-add" },
            else => null,
        };
        if (click_key) |key| {
            const id = app.widgetIdForKey(.root, key) orelse return error.DemoClickTargetMissing;
            app.activate(out.tree, id);
        }
    }
}

// One test binary for the whole demo. Every scene file is listed here so a
// removed import cannot silently drop that file's tests: the build graph runs
// this artifact instead of one artifact per scene.
test {
    _ = @import("FramePacer.zig");
    _ = @import("audio_player.zig");
    _ = @import("calculator.zig");
    _ = @import("ffmpeg_decoder.zig");
    _ = @import("local_library.zig");
    _ = @import("mandelbrot_component.zig");
    _ = @import("perf.zig");
    _ = @import("spotify.zig");
    _ = @import("spotify_content.zig");
    _ = @import("spotify_layout.zig");
    _ = @import("svg.zig");
    _ = @import("ui.zig");
    _ = @import("window.zig");
    _ = @import("fonts.zig");
}
