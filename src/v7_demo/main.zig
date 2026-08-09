//! v7 demo entry — switches between headless (default) and graphical modes.
//!
//!   zig build v7                # headless: 6 frames of JSON with injected clicks
//!   zig build v7 -- --window    # graphical: SDL3 + noapi window, mouse-driven
const std = @import("std");
const Io = std.Io;
const Id = @import("v7/id.zig").Id;
const ui = @import("ui.zig");
const window_backend = @import("window.zig");
const measure_cpu = @import("measure_cpu.zig");
const headless = @import("v7/headless.zig");
const hitTest = @import("v7/input.zig").hitTest;
const App = @import("v7/app.zig").App;

/// A value-taking flag with no value after it: print which flag is missing
/// its argument and fail. The runtime reports the returned error and exits
/// non-zero — same orelse-return shape as --hover's error path.
fn errMissingArg(flag: []const u8) error{MissingArg} {
    std.log.err("missing value for {s}", .{flag});
    return error.MissingArg;
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var app = App.init(alloc);
    defer app.deinit();
    var todo = ui.TodoApp{};
    _ = try app.register(ui.TodoApp, &todo);

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer args_it.deinit();
    var window_mode = false;
    var shot_path: ?[]const u8 = null;
    var shot_hover: ?[2]f32 = null;
    var layout_path: ?[]const u8 = null;
    var layout_diff: ?[]const u8 = null;
    var layout_write_golden: ?[]const u8 = null;
    var sim_path: ?[]const u8 = null;
    var subpixel = false; // subpixel AA OFF by default; --subpixel enables
    var quad_debug = false; // --quad-debug tints the glyph quads
    var bgr = false; // --bgr: BGR subpixel stripe order
    var damp = true; // --no-damp: disable the chroma damping
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--window")) {
            window_mode = true;
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
        }
    }

    // Headless driver: read JSON-lines events from a script, feed them to
    // the core (time included — every .frame event carries the driver's
    // tick + clock), and print one JSON frame dump per frame event. Fully
    // deterministic: the same script always produces the same output.
    // TigerBeetle-style full testing — the system is a pure function of the
    // input stream.
    if (sim_path) |sp| {
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
            const out = app.handle(ui.TodoApp, &todo, ev) catch |err| {
                std.log.err("sim line {d}: {s}", .{ line_no, @errorName(err) });
                std.process.exit(1);
            };
            if (out) |o| {
                // The frame dump: layout (tree) + state decisions (focus,
                // hover, pressed — 0 = none). Enough to debug any session.
                const dump = try std.fmt.allocPrint(alloc, "{{\"frame\":{d},\"focus\":{d},\"hover\":{d},\"pressed\":{d},\"tree\":{s}}}\n", .{
                    o.frame_number,
                    if (o.focus) |f| f.index() else 0,
                    if (o.hover) |h| h.index() else 0,
                    if (o.pressed) |p| p.index() else 0,
                    o.json,
                });
                defer alloc.free(dump);
                try stdout.writeStreamingAll(io, dump);
                alloc.free(o.json);
            }
        }
        return;
    }

    if (window_mode) {
        try window_backend.run(&app, ui.TodoApp, &todo, subpixel, quad_debug, bgr, damp);
        return;
    }

    if (shot_path) |p| {
        try window_backend.runShot(&app, ui.TodoApp, &todo, p, shot_hover, subpixel, quad_debug, bgr, damp);
        return;
    }

    // Headless layout verification: CPU-only (no GPU, no display). Lays out
    // one frame at 900x700 with the real FreeType advances, checks the
    // layout invariants, and renders an ASCII map (with the optional
    // --hover outline) to the file or stdout.
    if (layout_path) |lp| {
        defer measure_cpu.deinit();
        app.measure = measure_cpu.measure;
        todo.frame_count = 1;
        const out = try app.frame(ui.TodoApp, &todo, 1, .{ .width = 1100, .height = 1160 });
        defer alloc.free(out.json);

        var io_impl = std.Io.Threaded.init(alloc, .{});
        defer io_impl.deinit();
        const io = io_impl.io();
        const stdout = std.Io.File.stdout();

        const hover_id = if (shot_hover) |p| hitTest(out.tree, p) else null;
        const report = try headless.verifyLayout(out.tree, app.measure, .{ .width = 1100, .height = 1160 }, alloc);
        defer alloc.free(report);
        try stdout.writeStreamingAll(io, report);

        // Golden fingerprint: rects only (labels/values/frame counters are
        // dynamic and would make a map diff flaky).
        const fp = try headless.layoutFingerprint(out.tree, alloc);
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

        const map = try headless.renderAscii(out.tree, hover_id, alloc);
        defer alloc.free(map);
        const rows = std.mem.count(u8, map, "\n");
        if (lp.len > 0) {
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = lp, .data = map });
            const msg = try std.fmt.allocPrint(alloc, "layout map: {s} ({d} rows)\n", .{ lp, rows });
            defer alloc.free(msg);
            try stdout.writeStreamingAll(io, msg);
        } else {
            try stdout.writeStreamingAll(io, map);
            const msg = try std.fmt.allocPrint(alloc, "-- (layout JSON follows)\n{s}\n", .{out.json});
            defer alloc.free(msg);
            try stdout.writeStreamingAll(io, msg);
        }

        // Scriptable: violations fail the process.
        if (!std.mem.startsWith(u8, report, "OK")) return error.LayoutVerificationFailed;
        return;
    }

    // Headless: 6 frames with injected clicks to demonstrate interaction.
    // Uses the same CPU measure so the layout matches the windowed mode.
    defer measure_cpu.deinit();
    app.measure = measure_cpu.measure;
    for (0..6) |i| {
        todo.frame_count = @intCast(i + 1);
        const out = try app.frame(ui.TodoApp, &todo, @intCast(i + 1), .{ .width = 800, .height = 600 });
        defer alloc.free(out.json);
        std.log.info("frame {d}: {s}", .{ i + 1, out.json });

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
