//! W10 keyboard-layout and cursor smoke — the live identity and the cursor
//! policy on the display server this run is actually connected to.
//!
//! The binary opens nothing by default. Without `--video-driver x11` it
//! reports what it can honestly report (`unsupported_by_sdl`, name and
//! identifier unknown) and returns, so a run on a workstation desktop cannot
//! disturb it. With `--video-driver x11` it drives the real path, and it is
//! meant for an isolated X server:
//!
//! ```sh
//! Xvfb :99 -screen 0 800x600x24 -noreset -nolisten tcp &
//! DISPLAY=:99 zig build w10-keyboard-smoke -- --video-driver x11 --wait-ms 8000
//! ```
//!
//! `-noreset` matters here: a server that resets when its last client leaves
//! puts the default keymap back between the `setxkbmap` and the run, and the
//! layout this smoke reads is then the one the server restored, not the one
//! that was set.
//!
//! The `--wait-ms` phase is the layout handshake: the smoke prints its
//! `w10-keyboard: ready` line with the identity it currently sees, and then
//! waits for a KEYMAP_CHANGED that the X server delivers after an outside
//! `setxkbmap -layout de`. That event is never synthesized here — a run that
//! sees no real layout change within the deadline fails instead of reporting
//! one it manufactured.
//!
//! What each half proves: the identity half reads the XKB extension on SDL's
//! own X11 connection, so the reported name and identifier come from the
//! server; the cursor half creates a real X11 system cursor and reads SDL's
//! cursor visibility back through the public API.
const std = @import("std");
const Io = std.Io;
const sdl3 = @import("sdl3");
const host = @import("nogui_host");

const Keyboard = host.keyboard.Keyboard;
const Cursor = host.cursor.Cursor;

/// Values that belong to this scenario alone, so its numbers cannot be
/// confused with the layout phase in `todo_shortcuts`.
const window_title = "w10-keyboard-smoke";
const window_width: u32 = 320;
const window_height: u32 = 240;

/// Two scancodes whose labels follow the layout. Both are printed as SDL
/// reports them; neither is expected to be any particular character, because
/// a US key table is exactly what this smoke must not carry.
const scan_y: u32 = @backingInt(sdl3.Scancode.y);
const scan_z: u32 = @backingInt(sdl3.Scancode.z);

/// Pump step while waiting for the server's layout change.
const pump_step_ns: u64 = 10 * std.time.ns_per_ms;

pub const Error = error{
    MissingVideoDriver,
    MissingIdentifier,
    MissingWaitMs,
    BadWaitMs,
    UnknownArgument,
    /// No display server behind the requested driver, so no window was opened
    /// and nothing about the layout could be read.
    NoDisplayServer,
    WindowCreationFailed,
    /// SDL's cursor visibility did not follow the per-window policy.
    UnexpectedCursorState,
    /// A `--expect-identifier` the XKB extension did not report.
    UnexpectedLayoutIdentifier,
    /// A borrowed identity exceeds this consumer's bounded snapshot storage.
    LayoutIdentityCapacity,
    /// The deadline passed with no KEYMAP_CHANGED from the server.
    LayoutChangeNotObserved,
    /// The observed KEYMAP_CHANGED left the reported identity untouched, so
    /// the re-probe and the event cannot both be telling the truth.
    LayoutIdentityDidNotMove,
    /// The generation did not move with the change.
    LayoutGenerationStalled,
};

const Reporter = struct {
    io: Io,
    buffer: [4096]u8 = @splat(0),

    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.buffer, fmt, args);
        try Io.File.stdout().writeStreamingAll(self.io, text);
    }
};

const LayoutObserver = struct {
    calls: usize = 0,
    generation: u64 = 0,

    fn changed(raw: *anyopaque, change: Keyboard.LayoutChange) void {
        const self: *LayoutObserver = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.generation = change.generation;
    }
};

const Options = struct {
    /// The only value that drives the native path. Anything else reports
    /// unknown without opening a window.
    video_driver: ?[]const u8 = null,
    /// How long to wait for a real KEYMAP_CHANGED. Zero skips the wait and
    /// the phase that needs it.
    wait_ms: u31 = 0,
    /// The identifier the initial read must report, for a gated us/de run.
    expect_identifier: ?[]const u8 = null,
    /// Map the window, which is what a compositor-side cursor check needs.
    /// The default keeps the run windowless.
    show_window: bool = false,
};

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    const options = try parseArgs(gpa, init);
    var report: Reporter = .{ .io = io };
    try report.emit("W10 keyboard layout and cursor smoke\n", .{});

    if (options.video_driver) |driver| {
        var driver_buffer: [32]u8 = undefined;
        const driver_name = std.fmt.bufPrintSentinel(&driver_buffer, "{s}", .{driver}, 0) catch
            return Error.MissingVideoDriver;
        sdl3.hints.setWithPriority(.video_driver, driver_name, .override) catch
            return Error.NoDisplayServer;
    }

    // SDL owns the event thread, the window and the cursor state below.
    sdl3.init(.{ .video = true, .events = true }) catch {
        try report.emit(
            "w10-keyboard: NoDisplayServer, no window opened, layout identity unknown\n",
            .{},
        );
        return Error.NoDisplayServer;
    };
    defer sdl3.quit(.{ .video = true, .events = true });

    const driver = sdl3.video.getCurrentDriverName() orelse "<null>";
    try report.emit("video driver: {s}\n", .{driver});

    // The windowless default. A driver that publishes no X11 display has no
    // layout identity to report, and it is reported as unknown rather than
    // dressed up with a name.
    if (options.video_driver == null or !std.mem.eql(u8, driver, "x11")) {
        try report.emit(
            "w10-keyboard: status={s} name=unknown identifier=unknown" ++
                " (no X11 XKB connection on this driver, no window opened)\n",
            .{@tagName(Keyboard.LayoutStatus.unsupported_by_sdl)},
        );
        try report.emit(
            "w10-keyboard: pass --video-driver x11 against an isolated X server to read the live identity\n",
            .{},
        );
        return;
    }

    const window = sdl3.video.Window.init(window_title, window_width, window_height, .{
        .hidden = !options.show_window,
    }) catch return Error.WindowCreationFailed;
    defer window.deinit();

    var keyboard = Keyboard.init();
    var observer: LayoutObserver = .{};
    keyboard.setOnLayoutChanged(.{
        .context = &observer,
        .callback = LayoutObserver.changed,
    });
    // The XKB extension answers only for the connection SDL published on this
    // window, so this is what turns an unknown layout into a reported one.
    keyboard.attachDisplay(window);

    const initial = keyboard.layout();
    try emitLayout(&report, "initial", initial);
    if (options.expect_identifier) |expected| {
        const found = initial.identifier orelse return Error.UnexpectedLayoutIdentifier;
        if (!std.mem.eql(u8, found, expected)) return Error.UnexpectedLayoutIdentifier;
    }

    try cursorPhase(io, &report, window, options.show_window);
    try labelPhase(&report, &keyboard);
    if (options.wait_ms != 0) {
        try layoutPhase(io, &report, &keyboard, &observer, options.wait_ms);
    }
    try report.emit("w10-keyboard: done\n", .{});
}

/// Prints the identity the way a reader has to take it: the status first,
/// then the strings or an explicit unknown for each.
fn emitLayout(report: *Reporter, label: []const u8, layout: Keyboard.Layout) !void {
    try report.emit(
        "w10-keyboard: {s} status={s} generation={d} name={s} identifier={s}\n",
        .{
            label,
            @tagName(layout.status),
            layout.generation,
            layout.name orelse "unknown",
            layout.identifier orelse "unknown",
        },
    );
}

fn emitLabel(report: *Reporter, label: []const u8, keyboard: *const Keyboard, scancode: u32) !void {
    const text = keyboard.shortcutLabel(scancode, .none) orelse "unmapped";
    try report.emit("w10-keyboard: {s} scancode={d} label=\"{s}\"\n", .{ label, scancode, text });
}

/// The cursor policy applies only while this window owns pointer focus.
/// A mapped run waits for real enter/motion events from its private server.
/// The external controller supplies both motions. No SDL event is injected.
fn cursorPhase(io: Io, report: *Reporter, window: sdl3.video.Window, shown: bool) !void {
    var cursor = Cursor.init(window) catch return Error.WindowCreationFailed;
    defer cursor.deinit();

    try cursor.select(.pointer);
    try report.emit("w10-keyboard: native cursor allocated shape={s} window={s}\n", .{
        @tagName(cursor.shape),
        if (shown) "mapped" else "hidden",
    });
    if (!shown) {
        try report.emit("w10-keyboard: hidden window owns no pointer focus; global cursor policy not exercised\n", .{});
        return;
    }

    try report.emit("w10-keyboard: pointer-focus-ready; move the private pointer into this window\n", .{});
    const id = window.getId() catch return Error.WindowCreationFailed;
    var waited_ns: u64 = 0;
    const focus_wait_ns: u64 = 15 * std.time.ns_per_s;
    var entered = false;
    while (!entered and waited_ns < focus_wait_ns) : (waited_ns += pump_step_ns) {
        sdl3.events.pump();
        while (sdl3.events.poll()) |raw| {
            try cursor.handleEvent(&raw);
            if (raw == .window_mouse_enter and raw.window_mouse_enter.id == id) entered = true;
        }
        const focused = sdl3.mouse.getFocus();
        if (entered and (focused == null or focused.?.value != window.value)) entered = false;
        if (!entered) try Io.sleep(io, .fromNanoseconds(pump_step_ns), .real);
    }
    if (!entered) return Error.UnexpectedCursorState;
    try report.emit("w10-keyboard: this window owns native pointer focus\n", .{});

    if (!cursor.visible or cursor.hidden_until_move) return Error.UnexpectedCursorState;
    if (!sdl3.mouse.visible()) return Error.UnexpectedCursorState;
    try cursor.setVisible(false);
    if (cursor.visible or sdl3.mouse.visible()) return Error.UnexpectedCursorState;
    try cursor.setVisible(true);
    if (!cursor.visible or !sdl3.mouse.visible()) return Error.UnexpectedCursorState;
    try report.emit("w10-keyboard: cursor visibility followed the window policy\n", .{});

    try cursor.hideUntilPointerMove();
    if (!cursor.hidden_until_move or sdl3.mouse.visible()) return Error.UnexpectedCursorState;
    try report.emit("w10-keyboard: pointer-motion-ready; move the private pointer again\n", .{});
    waited_ns = 0;
    var delivered = false;
    while (!delivered and waited_ns < focus_wait_ns) : (waited_ns += pump_step_ns) {
        sdl3.events.pump();
        while (sdl3.events.poll()) |raw| {
            try cursor.handleEvent(&raw);
            if (raw == .mouse_motion and raw.mouse_motion.window_id != null and
                raw.mouse_motion.window_id.? == id and
                (raw.mouse_motion.id == null or raw.mouse_motion.id.?.value != sdl3.mouse.Id.touch.value))
            {
                delivered = true;
            }
        }
        if (!delivered) try Io.sleep(io, .fromNanoseconds(pump_step_ns), .real);
    }
    if (!delivered or cursor.hidden_until_move or !sdl3.mouse.visible())
        return Error.UnexpectedCursorState;
    try report.emit("w10-keyboard: hide-until-move released on native pointer motion\n", .{});
}

/// The shortcut label is read from SDL's live keymap for a physical code, so
/// the two scancodes below print whatever the active layout says. A run that
/// only ever printed "y" and "z" would be carrying the US key table this
/// scenario exists to avoid.
fn labelPhase(report: *Reporter, keyboard: *const Keyboard) !void {
    try emitLabel(report, "label-before", keyboard, scan_y);
    try emitLabel(report, "label-before", keyboard, scan_z);
}

/// Waits for the layout change the X server makes from outside this process.
///
/// The deadline is wall clock. Nothing here pushes a KEYMAP_CHANGED: only an
/// event SDL received from the server may move the generation.
fn layoutPhase(
    io: Io,
    report: *Reporter,
    keyboard: *Keyboard,
    observer: *LayoutObserver,
    wait_ms: u31,
) !void {
    var before = keyboard.layout();
    // Both strings borrow Keyboard's mutable identity buffers. Preserve the
    // old values before the next KEYMAP_CHANGED overwrites those buffers.
    var name_snapshot: [128]u8 = undefined;
    var identifier_snapshot: [128]u8 = undefined;
    if (before.name) |name| {
        if (name.len > name_snapshot.len) return Error.LayoutIdentityCapacity;
        @memcpy(name_snapshot[0..name.len], name);
        before.name = name_snapshot[0..name.len];
    }
    if (before.identifier) |identifier| {
        if (identifier.len > identifier_snapshot.len) return Error.LayoutIdentityCapacity;
        @memcpy(identifier_snapshot[0..identifier.len], identifier);
        before.identifier = identifier_snapshot[0..identifier.len];
    }
    try emitLayout(report, "before-change", before);
    try report.emit(
        "w10-keyboard: ready, switch the private X server now (setxkbmap -layout de); deadline_ms={d}\n",
        .{wait_ms},
    );

    const wait_ns = @as(u64, wait_ms) * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    while (waited_ns < wait_ns and observer.calls == 0) : (waited_ns += pump_step_ns) {
        sdl3.events.pump();
        while (sdl3.events.poll()) |raw| {
            _ = keyboard.handleEvent(&raw);
        }
        if (observer.calls == 0) try Io.sleep(io, .fromNanoseconds(pump_step_ns), .real);
    }

    try report.emit(
        "w10-keyboard: keymap-changed callbacks={d} observed_generation={d} waited_ms={d}\n",
        .{ observer.calls, observer.generation, waited_ns / std.time.ns_per_ms },
    );
    if (observer.calls == 0) return Error.LayoutChangeNotObserved;

    const after = keyboard.layout();
    try emitLayout(report, "after-change", after);
    try emitLabel(report, "label-after", keyboard, scan_y);
    try emitLabel(report, "label-after", keyboard, scan_z);

    // The observer saw the generation the layout reports, so a stale identity
    // cannot be passed off as a fresh one.
    if (after.generation != observer.generation) return Error.LayoutGenerationStalled;
    if (after.generation <= before.generation) return Error.LayoutGenerationStalled;
    // An XKB identity that answered before and after a real change has to
    // differ. An unknown identity has nothing to compare, and it was printed
    // as unknown above.
    if (before.status == .x11_xkb and after.status == .x11_xkb and
        sameText(before.name, after.name) and sameText(before.identifier, after.identifier))
    {
        return Error.LayoutIdentityDidNotMove;
    }
    try report.emit(
        "w10-keyboard: the server's layout change reached the identity, the generation and the labels\n",
        .{},
    );
}

fn sameText(a: ?[]const u8, b: ?[]const u8) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    return std.mem.eql(u8, left, right);
}

fn parseArgs(gpa: std.mem.Allocator, init: std.process.Init) !Options {
    var options: Options = .{};
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--video-driver")) {
            options.video_driver = args.next() orelse return Error.MissingVideoDriver;
        } else if (std.mem.eql(u8, arg, "--wait-ms")) {
            const value = args.next() orelse return Error.MissingWaitMs;
            options.wait_ms = std.fmt.parseInt(u31, value, 10) catch return Error.BadWaitMs;
        } else if (std.mem.eql(u8, arg, "--expect-identifier")) {
            options.expect_identifier = args.next() orelse return Error.MissingIdentifier;
        } else if (std.mem.eql(u8, arg, "--show-window")) {
            options.show_window = true;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return Error.UnknownArgument;
        }
    }
    return options;
}
