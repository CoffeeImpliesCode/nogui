//! W20 screen-capture smoke — the half that touches nothing, and the half that
//! needs a person.
//!
//! The default run asks the real Linux provider what it can do and prints the
//! answer. `linux_capture.capabilities` reads the process environment and
//! resolves `libpipewire-0.3`; it opens no D-Bus call, sends no portal
//! request and shows no chooser, so it is safe on a machine with a live
//! desktop session and needs no approval from anyone.
//!
//! The native half drives the real `linux_capture.Provider` through the real
//! `capture.Session` state machine: `begin`, a bounded wait for the stream, one
//! `acquireLatest` per requested frame, `stop`, and — on request — a second
//! approved session whose weak owner is dropped mid-stream. Every frame is
//! checked against the provider's own `FrameDescriptor` and its own release
//! callback, and every frame the run acquires is released through the session
//! before the provider is freed, so a buffer that outlives its producer shows
//! up as a refusal from `Provider.deinit` instead of a silent leak.
//!
//! Arming the native half takes an exact authorization flag, an exact source
//! class, an exact cursor policy and an exact budget. Any native option
//! without the authorization flag is refused by name, so a mistyped flag can
//! never look like a run that quietly did nothing. The flag is not an
//! approval on its own: the portal chooser stays with the operator, this
//! binary never answers it, never accepts a request on anyone's behalf, and
//! never retries a refusal.
//!
//! What this run reports as a result, and what it refuses to call a success:
//! a chooser closed without a selection (`canceled`), a refusal from the
//! operator or a policy (`denied`), a provider that is not on this machine
//! (`unavailable`), a provider or platform failure (`failed`), a session that
//! never went live inside the budget, a run that saw no frame inside the
//! budget, a frame that disagrees with the stream the provider described, a
//! source the provider named outside the classes the operator approved, a
//! session that stopped on its own before the requested frames arrived, a
//! budget that expired while the stream was still live and the run had seen
//! fewer frames than it was asked for, and a frame or buffer that survived
//! teardown. Each has its own exit code, so a parent can tell them apart
//! without parsing prose. A partial run is never rounded up into the success
//! code: the frame count is part of what the caller asked for.
//!
//! What this run cannot observe, reported as such instead of inferred:
//!
//!   - The chooser wait itself. `begin` blocks inside the provider's own
//!     synchronous D-Bus handshake until a person answers or the bus goes
//!     away; the run's budget bounds what happens after the approval, never
//!     the dialog.
//!   - A capture on a session this process does not own, on a second display,
//!     or under a window manager that rewrites what the portal offers. The run
//!     reports the class the portal named, never a list it made up. A portal
//!     that names no class at all leaves the source class unproved: the run
//!     says exactly that and never reads an unnamed class as a match.
//!   - Anything about Windows.Graphics.Capture. The only provider reachable
//!     from this binary is the Linux portal path, and an unavailable one is
//!     reported as unavailable rather than approximated.
//!
//! Run it: `zig build w20-capture-smoke` for the capability report. The native
//! half needs the operator's own approval and a person at the keyboard:
//! `zig build w20-capture-smoke -- --authorize-native-capture --source-monitor
//! --cursor embedded --budget-ms 15000 [--frames 30] [--frame-out <new path>]`.
const std = @import("std");
const Io = std.Io;

const host = @import("nogui_host");

const capture = host.capture;
const linux_capture = host.linux_capture;
const frame_source = host.frame_source;

const Capabilities = capture.Capabilities;
const FrameDescriptor = capture.FrameDescriptor;
const Request = capture.Request;
const SessionState = capture.SessionState;

/// The authorization flag, named exactly. The native half refuses to start
/// without it, and it is not an approval by itself: the chooser still belongs
/// to the operator, and this binary never answers it.
const authorize_flag = "--authorize-native-capture";

/// Exit codes. Every observed outcome that is not a validated stream has its
/// own code, so "the chooser was closed" is never read as "capture worked"
/// and never read as "capture failed" either.
const Exit = enum(u8) {
    /// Frames were observed, each one agreed with the provider's own
    /// description, and every owned resource drained before the provider was
    /// freed.
    observed = 0,
    /// The run refused itself before it reached the portal: a usage error.
    usage = 1,
    /// The chooser closed with no selection.
    canceled = 2,
    /// The operator or a policy refused the request.
    denied = 3,
    /// No provider on this machine. The reason is printed.
    unavailable = 4,
    /// The provider or the platform failed. The reason is printed.
    failed = 5,
    /// The session never went live inside the budget.
    not_streaming = 6,
    /// The session was live and no frame arrived inside the budget.
    no_frame = 7,
    /// A frame disagreed with the stream the provider described.
    mismatch = 8,
    /// A frame or a buffer survived the teardown that was meant to release it.
    still_held = 9,
    /// The requested frame dump was refused or failed.
    dump_refused = 10,
    /// The owner-loss half did not end the way the contracts say it must.
    owner_loss_incomplete = 11,
    /// The requested scope is one this provider cannot serve. Reported before
    /// any chooser opens.
    scope_refused = 12,
    /// The budget expired while the stream was still live and the run had not
    /// seen the frames it was asked for.
    incomplete = 13,
    /// The session ended by itself before the requested frames arrived. A
    /// stream that stopped is neither a refusal nor a failure.
    ended_early = 14,
};

/// The number this run exits the process with. `main` is the only boundary
/// that hands a verdict to a shell; every other one in this file speaks
/// `Exit`, so the conversion lives in exactly one place.
fn exitCode(verdict: Exit) u8 {
    return @backingInt(verdict);
}

const usage_text =
    \\usage: w20-capture-smoke [--help]
    \\  default: report the provider's capabilities, capture nothing
    \\  native: --authorize-native-capture
    \\          --source-monitor | --source-window | --source-virtual   (one or more)
    \\          --cursor embedded | hidden | metadata                  (exactly one)
    \\          --budget-ms <100..60000>                              (required)
    \\          [--frames <1..600>] [--queue-depth <1..8>]
    \\          [--persistence transient | while-connected | until-revoked]
    \\          [--multiple] [--parent-window <handle>]
    \\          [--frame-out <path that does not exist>] [--exercise-owner-loss]
;

/// Every option that arms the native half, in the order the usage text lists
/// them. A run that sees one of these without the authorization flag is
/// refused and names exactly what it saw.
const native_options = [_][]const u8{
    "--source-monitor",
    "--source-window",
    "--source-virtual",
    "--cursor",
    "--budget-ms",
    "--frames",
    "--queue-depth",
    "--persistence",
    "--multiple",
    "--parent-window",
    "--frame-out",
    "--exercise-owner-loss",
};

/// The bounds the run refuses to leave. A budget below the floor cannot
/// observe a stream, and one above the ceiling turns a smoke into a session
/// that holds the user's screen open.
const budget_floor_ms: u64 = 100;
const budget_ceiling_ms: u64 = 60_000;
const frames_ceiling: u32 = 600;
const queue_depth_ceiling: u32 = 8;

/// How long one poll waits between state reads. The provider pushes frames on
/// its own stream thread, so this only paces this process.
const poll_interval = Io.Duration.fromMilliseconds(4);

const Reporter = struct {
    io: Io,
    buffer: [4096]u8 = @splat(0),
    /// Where the report goes. Null sends it to stdout, which is what every
    /// run does. A test points it at its own buffer so a claim this file
    /// makes can be checked instead of only printed.
    sink: ?*std.Io.Writer = null,

    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.buffer, fmt, args);
        if (self.sink) |sink| {
            try sink.writeAll(text);
            return;
        }
        try Io.File.stdout().writeStreamingAll(self.io, text);
    }
};

/// Builds a name list in a fixed buffer, so a bit set prints the same way
/// twice and no run allocates to describe it. The buffer is wide enough for
/// the longest list this file builds, which is every native option name at
/// once: a refusal has to name all of them.
const Names = struct {
    /// Long enough for the thirteen option names, their separators and the
    /// brackets around them.
    buffer: [256]u8 = @splat(0),
    len: usize = 0,

    /// The closing bracket is written with every name, so a list is always
    /// closed at the moment it is read and `text` never has to touch the
    /// buffer it was handed by value.
    fn add(self: *Names, name: []const u8) void {
        var at = self.len;
        if (at == 0) {
            self.buffer[0] = '<';
            at = 1;
        } else {
            self.buffer[at] = '|';
            at += 1;
        }
        @memcpy(self.buffer[at..][0..name.len], name);
        at += name.len;
        self.buffer[at] = '>';
        self.len = at + 1;
    }

    fn addIf(self: *Names, present: bool, name: []const u8) void {
        if (present) self.add(name);
    }

    fn text(self: *const Names) []const u8 {
        if (self.len == 0) return "<none>";
        return self.buffer[0..self.len];
    }
};

fn sourceNames(value: capture.SourceType) Names {
    var names: Names = .{};
    names.addIf(value.has(.monitor), "monitor");
    names.addIf(value.has(.window), "window");
    names.addIf(value.has(.virtual), "virtual");
    return names;
}

/// The class the provider named, rendered the way this run can stand behind
/// it. A provider that names no class leaves the set empty, and an empty set
/// printed as a class is a claim the platform never made, so an unnamed class
/// is written as unproved and is never read as one of no class.
fn reportedSourceNames(info: capture.StreamInfo) Names {
    if (!info.source_class_known) {
        var names: Names = .{};
        names.add("unproved");
        return names;
    }
    return sourceNames(info.sources);
}

fn cursorModeNames(value: capture.CursorModes) Names {
    var names: Names = .{};
    names.addIf(value.supports(.embedded), "embedded");
    names.addIf(value.supports(.hidden), "hidden");
    names.addIf(value.supports(.metadata), "metadata");
    return names;
}

fn persistenceModeNames(value: capture.PersistenceModes) Names {
    var names: Names = .{};
    names.addIf(value.supports(.transient), "transient");
    names.addIf(value.supports(.while_connected), "while_connected");
    names.addIf(value.supports(.until_revoked), "until_revoked");
    return names;
}

fn parseCursorMode(value: []const u8) ?capture.CursorMode {
    if (std.mem.eql(u8, value, "embedded")) return .embedded;
    if (std.mem.eql(u8, value, "hidden")) return .hidden;
    if (std.mem.eql(u8, value, "metadata")) return .metadata;
    return null;
}

fn parsePersistenceMode(value: []const u8) ?capture.PersistenceMode {
    if (std.mem.eql(u8, value, "transient")) return .transient;
    if (std.mem.eql(u8, value, "while-connected")) return .while_connected;
    if (std.mem.eql(u8, value, "until-revoked")) return .until_revoked;
    return null;
}

/// The weak owner this run hands the session. The provider re-checks it on
/// every callback, so the owner-loss half drops a real owner instead of
/// pretending one disappeared.
const Owner = struct {
    alive: bool = true,

    fn probe(context: *const anyopaque) bool {
        const self: *const Owner = @ptrCast(@alignCast(context));
        return self.alive;
    }
};

/// The W05 completion wake, counted from whichever thread the provider pushes
/// on. It is what a host uses to unblock a main thread waiting for a frame, so
/// the count is a real observation of that seam and not a copy of it.
const WakeCounter = struct {
    count: std.atomic.Value(u64) = .init(0),

    fn onWake(ctx: ?*anyopaque) void {
        const self: *WakeCounter = @ptrCast(@alignCast(ctx.?));
        _ = self.count.fetchAdd(1, .monotonic);
    }

    fn observed(self: *const WakeCounter) u64 {
        return self.count.load(.monotonic);
    }
};

const Options = struct {
    help: bool = false,
    authorize: bool = false,
    monitor: bool = false,
    window: bool = false,
    virtual: bool = false,
    cursor: ?capture.CursorMode = null,
    persistence: capture.PersistenceMode = .transient,
    multiple: bool = false,
    budget_ms: ?u64 = null,
    frames: u32 = 1,
    queue_depth: u32 = 1,
    parent_window: []const u8 = "",
    frame_out: ?[]const u8 = null,
    owner_loss: bool = false,
    seen: [native_options.len]bool = @splat(false),

    fn note(self: *Options, name: []const u8) void {
        for (native_options, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, name)) {
                self.seen[index] = true;
                return;
            }
        }
    }

    fn nativeOptionsSeen(self: Options) Names {
        var names: Names = .{};
        for (native_options, 0..) |name, index| {
            if (self.seen[index]) names.add(name);
        }
        return names;
    }

    /// The source classes the operator named. The class is what the chooser
    /// offers; which monitor or window is picked stays with the chooser, and
    /// this run never claims to know it before the portal answers.
    fn requestedSources(self: Options) capture.SourceType {
        var sources: capture.SourceType = .none;
        if (self.monitor) sources = sources.with(.monitor);
        if (self.window) sources = sources.with(.window);
        if (self.virtual) sources = sources.with(.virtual);
        return sources;
    }
};

fn parseArgs(gpa: std.mem.Allocator, init: std.process.Init, report: *Reporter) !Options {
    var options: Options = .{};
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    _ = args_it.next();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, authorize_flag)) {
            options.authorize = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            options.help = true;
            return options;
        } else if (std.mem.eql(u8, arg, "--source-monitor")) {
            options.monitor = true;
            options.note(arg);
        } else if (std.mem.eql(u8, arg, "--source-window")) {
            options.window = true;
            options.note(arg);
        } else if (std.mem.eql(u8, arg, "--source-virtual")) {
            options.virtual = true;
            options.note(arg);
        } else if (std.mem.eql(u8, arg, "--cursor")) {
            const value = args_it.next() orelse return error.MissingCursorPolicy;
            options.cursor = parseCursorMode(value) orelse {
                std.log.err("unknown cursor policy: {s}", .{value});
                return error.UnknownCursorPolicy;
            };
            options.note(arg);
        } else if (std.mem.eql(u8, arg, "--persistence")) {
            const value = args_it.next() orelse return error.MissingPersistenceMode;
            options.persistence = parsePersistenceMode(value) orelse {
                std.log.err("unknown persistence mode: {s}", .{value});
                return error.UnknownPersistenceMode;
            };
            options.note(arg);
        } else if (std.mem.eql(u8, arg, "--budget-ms")) {
            const value = args_it.next() orelse return error.MissingBudget;
            options.budget_ms = try std.fmt.parseInt(u64, value, 10);
            options.note(arg);
        } else if (std.mem.eql(u8, arg, "--frames")) {
            const value = args_it.next() orelse return error.MissingFrameCount;
            options.frames = try std.fmt.parseInt(u32, value, 10);
            options.note(arg);
        } else if (std.mem.eql(u8, arg, "--queue-depth")) {
            const value = args_it.next() orelse return error.MissingQueueDepth;
            options.queue_depth = try std.fmt.parseInt(u32, value, 10);
            options.note(arg);
        } else if (std.mem.eql(u8, arg, "--multiple")) {
            options.multiple = true;
            options.note(arg);
        } else if (std.mem.eql(u8, arg, "--parent-window")) {
            options.parent_window = args_it.next() orelse return error.MissingParentWindow;
            options.note(arg);
        } else if (std.mem.eql(u8, arg, "--frame-out")) {
            options.frame_out = args_it.next() orelse return error.MissingFrameOutPath;
            options.note(arg);
        } else if (std.mem.eql(u8, arg, "--exercise-owner-loss")) {
            options.owner_loss = true;
            options.note(arg);
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }

    const seen = options.nativeOptionsSeen();
    if (!options.authorize and seen.len != 0) {
        try report.emit(
            "refused: {s} arms the native capture half, which needs {s}\n" ++
                "refused: this run made no portal call and captured nothing\n",
            .{ seen.text(), authorize_flag },
        );
        return error.NativeOptionWithoutAuthorization;
    }
    if (!options.authorize) return options;

    // The armed half asks for an exact target and an exact scope, because a
    // capture that names neither cannot be reported as anything but a guess.
    const sources = options.requestedSources();
    if (sources.isEmpty()) {
        try report.emit(
            "refused: {s} needs an exact source class: --source-monitor," ++
                " --source-window or --source-virtual\n",
            .{authorize_flag},
        );
        return error.NativeArmNeedsSourceClass;
    }
    if (options.cursor == null) {
        try report.emit(
            "refused: {s} needs an exact cursor policy: --cursor embedded|hidden|metadata\n",
            .{authorize_flag},
        );
        return error.NativeArmNeedsCursorPolicy;
    }
    const budget = options.budget_ms orelse {
        try report.emit(
            "refused: {s} needs an exact budget: --budget-ms {d}..{d}\n",
            .{ authorize_flag, budget_floor_ms, budget_ceiling_ms },
        );
        return error.NativeArmNeedsBudget;
    };
    if (budget < budget_floor_ms or budget > budget_ceiling_ms) {
        try report.emit("refused: --budget-ms {d} is outside {d}..{d}\n", .{
            budget,
            budget_floor_ms,
            budget_ceiling_ms,
        });
        return error.BudgetOutOfRange;
    }
    if (options.frames == 0 or options.frames > frames_ceiling) {
        try report.emit("refused: --frames {d} is outside 1..{d}\n", .{ options.frames, frames_ceiling });
        return error.FrameCountOutOfRange;
    }
    if (options.queue_depth == 0 or options.queue_depth > queue_depth_ceiling) {
        try report.emit("refused: --queue-depth {d} is outside 1..{d}\n", .{
            options.queue_depth,
            queue_depth_ceiling,
        });
        return error.QueueDepthOutOfRange;
    }
    if (options.frame_out) |path| {
        if (path.len == 0) {
            try report.emit("refused: --frame-out needs a path that does not exist yet\n", .{});
            return error.EmptyFrameOutPath;
        }
    }
    return options;
}

/// The capability report. This is what the default run exists for: every line
/// comes from the provider's own probe, and none of it opens a chooser.
fn reportCapabilities(report: *Reporter) !void {
    const caps: Capabilities = linux_capture.capabilities();
    const sources = sourceNames(caps.sources);
    const cursors = cursorModeNames(caps.cursor_modes);
    const persistence = persistenceModeNames(caps.persistence_modes);
    const reason = if (caps.unavailable_reason.len == 0)
        "<none>"
    else
        caps.unavailable_reason;
    try report.emit(
        "capabilities: available={} platform={s} backend={s}\n" ++
            "capabilities: sources={s} cursor_modes={s} persistence_modes={s}\n" ++
            "capabilities: multiple_streams={} requires_user_approval={} " ++
            "unavailable_reason=\"{s}\"\n",
        .{
            caps.available,
            @tagName(caps.platform),
            @tagName(caps.backend),
            sources.text(),
            cursors.text(),
            persistence.text(),
            caps.multiple_streams,
            caps.requires_user_approval,
            reason,
        },
    );
    // The transport library is resolved here, and resolving it opens no
    // stream and no socket. It is reported apart from the capture capability
    // because the two answer different questions.
    try report.emit(
        "libpipewire-0.3: loaded={} (resolved only; no stream, no socket, no chooser)\n",
        .{linux_capture.pipeWireApi() != null},
    );
}

/// Refuses a scope this provider cannot serve, before any chooser opens, so a
/// run never puts a dialog in front of an operator for a request it is going
/// to refuse anyway.
fn checkScope(report: *Reporter, options: Options, caps: Capabilities) !?Exit {
    const sources = options.requestedSources();
    const requested = sourceNames(sources);
    const offered = sourceNames(caps.sources);
    if (!caps.sources.has(sources)) {
        try report.emit("scope refused: requested sources={s}, this provider offers={s}\n", .{
            requested.text(),
            offered.text(),
        });
        return .scope_refused;
    }
    const cursor = options.cursor.?;
    if (!caps.cursor_modes.supports(cursor)) {
        const cursors = cursorModeNames(caps.cursor_modes);
        try report.emit("scope refused: requested cursor={s}, this provider supports={s}\n", .{
            @tagName(cursor),
            cursors.text(),
        });
        return .scope_refused;
    }
    if (!caps.persistence_modes.supports(options.persistence)) {
        const modes = persistenceModeNames(caps.persistence_modes);
        try report.emit("scope refused: requested persistence={s}, this provider supports={s}\n", .{
            @tagName(options.persistence),
            modes.text(),
        });
        return .scope_refused;
    }
    if (options.multiple and !caps.multiple_streams) {
        try report.emit("scope refused: --multiple, this provider offers one stream per session\n", .{});
        return .scope_refused;
    }
    try report.emit(
        "scope: sources={s} cursor={s} persistence={s} multiple={} budget_ms={d} frames={d} queue_depth={d}\n",
        .{
            requested.text(),
            @tagName(cursor),
            @tagName(options.persistence),
            options.multiple,
            options.budget_ms.?,
            options.frames,
            options.queue_depth,
        },
    );
    return null;
}

fn elapsedMs(io: Io, started: Io.Timestamp) i64 {
    return Io.Timestamp.durationTo(started, .now(io, .real)).toMilliseconds();
}

/// The window the run's budget bounds. It is measured from the moment the
/// request was answered, never from before it: `begin` blocks inside the
/// provider's own synchronous D-Bus handshake until a person answers, and an
/// approval that takes longer than the budget must still leave the whole
/// budget for the stream. Every elapsed time this run reports is measured
/// against the same base, so a number on screen and the deadline behind it
/// always describe the same window.
const Budget = struct {
    started: Io.Timestamp,
    deadline: Io.Timestamp,
};

fn postApprovalBudget(approved_at: Io.Timestamp, budget_ms: u64) Budget {
    return .{
        .started = approved_at,
        .deadline = approved_at.addDuration(Io.Duration.fromMilliseconds(@intCast(budget_ms))),
    };
}

/// Waits for the provider to report a live stream, bounded by the run's
/// budget. The chooser is deliberately outside this wait: `begin` blocks in
/// the provider's own synchronous D-Bus handshake until a person answers, and
/// nothing here answers for them.
fn waitForLiveStream(
    io: Io,
    report: *Reporter,
    session: *capture.Session,
    started: Io.Timestamp,
    deadline: Io.Timestamp,
) !SessionState {
    while (true) {
        const state = session.state();
        if (state == .streaming or capture.isTerminal(state)) {
            try report.emit("stream: state={s} after {d} ms\n", .{ @tagName(state), elapsedMs(io, started) });
            return state;
        }
        if (Io.Timestamp.now(io, .real).nanoseconds >= deadline.nanoseconds) {
            try report.emit("stream: state={s} after {d} ms, the budget expired first\n", .{
                @tagName(state),
                elapsedMs(io, started),
            });
            return state;
        }
        try Io.sleep(io, poll_interval, .real);
    }
}

/// Checks one acquired frame against the stream the provider itself
/// described. Every field is read from the provider's own descriptor, so a
/// disagreement is an observation about the provider, not a guess. Returns
/// null when the frame agrees, and the reason it does not otherwise.
///
/// `requested` is the source class the operator's own command line approved.
/// A provider that named its class is read against it: a class outside the
/// approved request is a capture of something the operator never asked for,
/// and no frame from it validates the scope this run was armed for. A
/// provider that named no class stays unproved, which is neither a match nor
/// a mismatch — the platform said nothing, and nothing is what this run says
/// about it.
fn inspectFrame(
    report: *Reporter,
    session: *capture.Session,
    frame: *const FrameDescriptor,
    index: u32,
    requested: capture.SourceType,
) !?[]const u8 {
    const info = session.streamInfo();
    const sources = reportedSourceNames(info);
    try report.emit(
        "stream report: node_id={d} {d}x{d} format={s} color_space={s} color_range={s} " ++
            "sources={s} source_class_known={} pos={d},{d} frame_interval_ns={d} format_epoch={d}\n",
        .{
            info.node_id,
            info.width,
            info.height,
            @tagName(info.format),
            @tagName(info.color_space),
            @tagName(info.color_range),
            sources.text(),
            info.source_class_known,
            info.position_x,
            info.position_y,
            info.frame_interval_ns,
            info.format_epoch,
        },
    );

    if (info.source_class_known) {
        // A named class is a fact about the surface the portal selected, and
        // the approved request is the fact it is read against. Every class the
        // provider named has to be one the operator asked for: a request that
        // offered a monitor and a window is still served by either of them,
        // while a window answering a monitor-only request is a surface nobody
        // approved.
        if (info.sources.isEmpty()) {
            try report.emit("frame[{d}]: refused, the portal named a source of no class\n", .{
                index,
            });
            return "a source the portal says belongs to no class";
        }
        if (!requested.has(info.sources)) {
            const wanted = sourceNames(requested);
            try report.emit(
                "frame[{d}]: refused, the portal named {s} and the approved request was {s}\n",
                .{
                    index,
                    sources.text(),
                    wanted.text(),
                },
            );
            return "a source class the approved request did not ask for";
        }
    }

    const bytes_per_pixel = frame.format.bytesPerPixel() orelse {
        try report.emit("frame[{d}]: refused, {s} is planar and has no packed row\n", .{
            index,
            @tagName(frame.format),
        });
        return "a planar frame this run cannot measure";
    };
    if (frame.width == 0 or frame.height == 0 or frame.stride == 0) {
        try report.emit("frame[{d}]: refused, the descriptor has no layout\n", .{index});
        return "a descriptor with no layout";
    }
    if (frame.plane_count == 0) {
        try report.emit("frame[{d}]: refused, the descriptor names no plane\n", .{index});
        return "a descriptor with no plane";
    }
    const base = frame.pixels orelse {
        try report.emit("frame[{d}]: refused, the descriptor names no pixel memory\n", .{index});
        return "a descriptor with no pixel memory";
    };
    const row_bytes = std.math.mul(usize, @as(usize, frame.width), bytes_per_pixel) catch {
        try report.emit("frame[{d}]: refused, a row of {d} pixels does not fit an address\n", .{
            index,
            frame.width,
        });
        return "a row size that overflowed";
    };
    const payload_bytes = std.math.mul(usize, @as(usize, frame.stride), @as(usize, frame.height)) catch {
        try report.emit("frame[{d}]: refused, {d} rows of {d} bytes do not fit an address\n", .{
            index,
            frame.height,
            frame.stride,
        });
        return "a payload size that overflowed";
    };
    if (frame.release_fn == null) {
        try report.emit("frame[{d}]: refused, the provider cannot take this frame back\n", .{index});
        return "a frame the provider cannot take back";
    }
    if (@as(usize, frame.stride) < row_bytes) {
        try report.emit("frame[{d}]: refused, stride {d} is shorter than one row of {d} bytes\n", .{
            index,
            frame.stride,
            row_bytes,
        });
        return "a stride shorter than one row of pixels";
    }
    if (frame.planes[0].size < payload_bytes) {
        try report.emit("frame[{d}]: refused, the provider mapped {d} bytes and the descriptor claims {d}\n", .{
            index,
            frame.planes[0].size,
            payload_bytes,
        });
        return "a mapped buffer shorter than the descriptor claims";
    }
    // Every guard above runs before the first byte is read, because
    // `FrameDescriptor.pixels` is a raw pointer with no length: an index past
    // what the provider says it mapped is a read of memory this process was
    // never given, and no build mode turns that into an error. Both ends are
    // read while the frame is out, because the provider keeps the mapping
    // mapped for exactly that long; reading them after the release would be
    // the use-after-free this run must not contain.
    const head = base[0];
    const tail = base[payload_bytes - 1];
    try report.emit(
        "frame[{d}]: {d}x{d} format={s} color_space={s} alpha={s} stride={d} row_bytes={d} " ++
            "payload_bytes={d} plane_bytes={d} ts_ns={d}\n" ++
            "frame[{d}]: mapped bytes head=0x{X:0>2} tail=0x{X:0>2}\n",
        .{
            index,
            frame.width,
            frame.height,
            @tagName(frame.format),
            @tagName(frame.color_space),
            @tagName(frame.alpha_type),
            frame.stride,
            row_bytes,
            payload_bytes,
            frame.planes[0].size,
            frame.presentation_timestamp_ns,
            index,
            head,
            tail,
        },
    );
    if (info.isConfigured()) {
        if (frame.width != info.width or frame.height != info.height) {
            return "a frame size the stream report does not describe";
        }
        if (frame.format != info.format) return "a pixel format the stream report does not describe";
        if (frame.color_space != info.color_space) return "a colour space the stream report does not describe";
    }
    return null;
}

/// Writes the frame the run is holding to a file the operator named, through
/// the public W14 CPU upload seam: the same adapter an ordinary image
/// consumer uses converts the captured bytes, and no renderer, no private
/// pipeline and no raw GPU import is involved.
///
/// The file is created exclusively. A path that already exists is a refusal,
/// because a capture dump is this run's own artifact and must never land on
/// top of something a person already had.
fn dumpFrame(
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    path: []const u8,
    frame: *const FrameDescriptor,
) !void {
    const bytes_per_pixel = frame.format.bytesPerPixel() orelse return error.PlanoFrameHasNoPackedRow;
    if (frame.width == 0 or frame.height == 0 or frame.stride == 0) return error.FrameHasNoLayout;
    const base = frame.pixels orelse return error.FrameHasNoPixelMemory;
    const payload_bytes = std.math.mul(
        usize,
        @as(usize, frame.stride),
        @as(usize, frame.height),
    ) catch return error.FrameTooLarge;
    // A chunk that maps less than the descriptor claims, or a stride shorter
    // than one row of pixels, would have the dump read bytes the provider
    // never filled or write rows that overlap. Both are refused instead.
    if (frame.plane_count == 0 or frame.planes[0].size < payload_bytes) return error.ChunkIsPartial;
    const row_bytes = std.math.mul(usize, @as(usize, frame.width), bytes_per_pixel) catch
        return error.FrameTooLarge;
    if (@as(usize, frame.stride) < row_bytes) return error.StrideShorterThanOneRow;

    const mapped: []const u8 = base[0..payload_bytes];
    var image = try frame_source.CpuUploadAdapter.uploadToRgba(gpa, frame.*, mapped, .{});
    defer image.deinit();

    const rgb_bytes = std.math.mul(usize, @as(usize, image.width), 3) catch
        return error.FrameTooLarge;
    const file = Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.FrameDumpPathExists,
        else => return err,
    };
    defer file.close(io);

    var header: [64]u8 = undefined;
    const head = try std.fmt.bufPrint(&header, "P6\n{d} {d}\n255\n", .{ image.width, image.height });
    try file.writeStreamingAll(io, head);

    const row = try gpa.alloc(u8, rgb_bytes);
    defer gpa.free(row);
    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        const source_row = image.pixels[@as(usize, y) * @as(usize, image.stride) ..][0 .. @as(usize, image.width) * 4];
        var x: usize = 0;
        while (x < image.width) : (x += 1) {
            row[x * 3] = source_row[x * 4];
            row[x * 3 + 1] = source_row[x * 4 + 1];
            row[x * 3 + 2] = source_row[x * 4 + 2];
        }
        try file.writeStreamingAll(io, row);
    }
    try report.emit(
        "frame dump: path=\"{s}\" format=P6 size={d}x{d} bytes={d} " ++
            "source=the provider's own frame through the W14 CPU upload seam\n",
        .{ path, image.width, image.height, head.len + @as(usize, image.height) * rgb_bytes },
    );
}

const BeginOutcome = enum {
    /// The session is still live: the request is in flight or the stream is
    /// already delivering.
    live,
    canceled,
    denied,
    failed,
    /// The session ended by itself. A stream that stopped is neither a refusal
    /// nor a failure, and reporting it as either would be a lie.
    stopped,
};

/// The state is the answer, not the returned error. The provider reports its
/// own outcome through the sink and the facade records it, so a refusal that
/// also returns an error must not be reported twice as a failure.
fn beginOutcome(state: SessionState, begin_error: ?anyerror) BeginOutcome {
    if (capture.isTerminal(state)) return switch (state) {
        .canceled => .canceled,
        .denied => .denied,
        .stopped => .stopped,
        else => .failed,
    };
    if (begin_error != null) return .failed;
    return .live;
}

fn outcomeExit(outcome: BeginOutcome) Exit {
    return switch (outcome) {
        .live => .observed,
        .canceled => .canceled,
        .denied => .denied,
        .failed => .failed,
        .stopped => .ended_early,
    };
}

/// Takes up to `options.frames` frames out of a live session, checks each one
/// against the provider's own stream report, and returns what the run
/// actually observed. Every frame is released inside the loop, so no path out
/// of it can leave a provider buffer held by this process.
///
/// A session can be live and not streaming — a paused transport still has a
/// stream coming — so the wait ends on the deadline or on a state the session
/// never leaves, never on a state it can come back from. A verdict about the
/// budget is therefore only ever written where a clock was read.
fn observeFrames(
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    session: *capture.Session,
    wake: *const WakeCounter,
    options: Options,
    started: Io.Timestamp,
    deadline: Io.Timestamp,
    dump_failed: *bool,
) !Exit {
    // The approved source class is read once, because the operator's command
    // line cannot change while the run is in flight.
    const requested_sources = options.requestedSources();
    var observed: u32 = 0;
    var mismatch: ?[]const u8 = null;
    var dump_attempted = false;
    var previous_ts: ?i96 = null;
    var timestamps_monotonic = true;
    // Set where a clock was read and compared, so a verdict below can only
    // describe a window this run actually waited out.
    var expired = false;
    while (observed < options.frames and mismatch == null) {
        // A live session can stop delivering without ending: a transport that
        // pauses is still building the stream the run asked for, and the frames
        // behind it arrive the moment it comes back. Only a state the session
        // never leaves ends the wait here; every other state runs on until the
        // deadline, which is compared again below on the iterations that
        // delivered a frame, so a stream that never goes quiet is bounded too.
        if (capture.isTerminal(session.state())) break;
        if (session.acquireLatest()) |frame| {
            var owned = frame;
            // The release is a defer, so an error between acquiring and
            // checking a frame cannot leave a provider buffer held by this
            // process on its way out.
            defer session.releaseFrame(&owned);
            if (options.frame_out) |path| {
                if (!dump_attempted) {
                    dump_attempted = true;
                    // The dump runs before the release: the provider keeps
                    // the mapping only while the frame is out.
                    dumpFrame(gpa, io, report, path, &owned) catch |err| {
                        dump_failed.* = true;
                        try report.emit("frame dump refused: {s} path=\"{s}\"\n", .{ @errorName(err), path });
                    };
                }
            }
            if (try inspectFrame(report, session, &owned, observed, requested_sources)) |reason|
                mismatch = reason;
            if (previous_ts) |last| {
                // A presentation timestamp that moves backwards disagrees
                // with the stream the provider described, exactly as a stride
                // or a format that does not match does. A boolean nobody reads
                // is not a verdict.
                if (owned.presentation_timestamp_ns < last) {
                    timestamps_monotonic = false;
                    mismatch = "presentation timestamps that move backwards";
                }
            }
            previous_ts = owned.presentation_timestamp_ns;
            observed += 1;
        } else {
            if (Io.Timestamp.now(io, .real).nanoseconds >= deadline.nanoseconds) {
                expired = true;
                break;
            }
            try Io.sleep(io, poll_interval, .real);
            continue;
        }
        // A screen that never runs dry hands a frame over on every acquire, so
        // the wait above is never entered and the requested count would be the
        // only thing that ended this run. The clock is read here too, after the
        // frame this iteration was holding went back to its producer: its
        // release belongs to the block above, so a run that stops on this
        // comparison owns nothing on its way out.
        if (observed < options.frames and mismatch == null and
            Io.Timestamp.now(io, .real).nanoseconds >= deadline.nanoseconds)
        {
            expired = true;
            break;
        }
    }
    try report.emit(
        "frames: observed={d} requested={d} pushed={d} dropped={d} presented={d} " ++
            "outstanding={d} wakes={d} timestamps_monotonic={} after {d} ms\n",
        .{
            observed,
            options.frames,
            session.frames.total_pushed,
            session.frames.total_dropped,
            session.frames.total_presented,
            session.outstandingFrames(),
            wake.observed(),
            timestamps_monotonic,
            elapsedMs(io, started),
        },
    );
    if (mismatch) |reason| {
        try report.emit("frame mismatch: {s}\n", .{reason});
        return .mismatch;
    }
    // A terminal outcome is the answer whether or not a frame ever arrived: a
    // provider that failed or was refused mid-stream is not a run that sat out
    // its budget seeing nothing, and the two must not share a code. A run that
    // already holds every frame it asked for is not downgraded by a transition
    // that lands after the last one.
    const state = session.state();
    if (observed < options.frames and capture.isTerminal(state)) {
        const ended = outcomeExit(beginOutcome(state, null));
        try report.emit("frames: the session ended at {s} after {d} of {d} frames\n", .{
            @tagName(state),
            observed,
            options.frames,
        });
        return ended;
    }
    // A run that still wants frames left the loop on the clock or on a state it
    // has already answered above. The check is what keeps the two verdicts below
    // from describing a window nobody waited out.
    std.debug.assert(observed >= options.frames or expired);
    if (observed == 0) {
        try report.emit("frames: the session was {s} and no frame arrived before the budget expired after {d} ms\n", .{
            @tagName(state),
            elapsedMs(io, started),
        });
        return .no_frame;
    }
    if (observed < options.frames) {
        // The stream is still live and the budget is gone. The frame count is
        // part of what this run was asked for, so a partial run is a result of
        // its own and never a rounded-up success.
        try report.emit("frames: the budget expired while the session was {s}, after {d} of {d} frames\n", .{
            @tagName(state),
            observed,
            options.frames,
        });
        return .incomplete;
    }
    return .observed;
}

/// The native capture half: one approved session, driven through begin, a
/// bounded wait, `acquireLatest` per requested frame, `stop`, and a teardown
/// the provider itself has to accept.
fn runCaptureArm(
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    options: Options,
) !Exit {
    const caps: Capabilities = linux_capture.capabilities();
    if (!caps.available) {
        try report.emit("capture: not started, this provider is unavailable: {s}\n", .{caps.unavailable_reason});
        return .unavailable;
    }
    if (try checkScope(report, options, caps)) |code| return code;

    const request: Request = .{
        .sources = options.requestedSources(),
        .cursor_mode = options.cursor.?,
        .persistence = options.persistence,
        .multiple = options.multiple,
        .parent_window = options.parent_window,
    };
    try report.emit(
        "portal request: sources_bits={d} cursor_bits={d} persistence_bits={d} " ++
            "multiple={} parent_window=\"{s}\"\n",
        .{
            request.sources.bits,
            @backingInt(request.cursor_mode),
            @backingInt(request.persistence),
            request.multiple,
            request.parent_window,
        },
    );
    try report.emit(
        "portal chooser: it opens on this machine now. Approve it yourself; " ++
            "this run never answers it and never retries a refusal.\n",
        .{},
    );

    var owner: Owner = .{};
    var wake: WakeCounter = .{};
    // The session and the provider stay at fixed addresses: the provider's
    // vtable points at it, and a frame released later still names its stream.
    var session: capture.Session = capture.Session.init(
        gpa,
        io,
        .{ .context = &owner, .is_alive_fn = Owner.probe },
        @as(usize, options.queue_depth),
    );
    var provider: linux_capture.Provider = linux_capture.Provider.init(gpa, io, session.sink());
    var session_live = true;
    var provider_live = true;
    // Declared provider-first so the defers run session-first: the session
    // releases every frame, and only then does the provider free the stream
    // those frames pointed into. A refusal here is reported, never swallowed.
    defer if (provider_live) provider.deinit() catch |err| {
        report.emit("PROVIDER CLEANUP REFUSED: {s}\n", .{@errorName(err)}) catch
            @panic("W20 capture smoke could not report the refused provider cleanup");
    };
    defer if (session_live) session.deinit() catch |err| {
        report.emit("SESSION CLEANUP REFUSED: {s}\n", .{@errorName(err)}) catch
            @panic("W20 capture smoke could not report the refused session cleanup");
    };
    session.attach(provider.backend());
    session.setWake(&wake, WakeCounter.onWake);

    // The budget bounds what happens after the approval, so it is measured
    // from the moment `begin` returns. `begin` blocks inside the provider's
    // own synchronous D-Bus handshake until a person answers, and an approval
    // that took longer than the budget must still leave the whole budget for
    // the stream instead of none.
    const chooser_opened: Io.Timestamp = .now(io, .real);
    var begin_error: ?anyerror = null;
    session.begin(request) catch |err| {
        begin_error = err;
    };
    const budget = postApprovalBudget(Io.Timestamp.now(io, .real), options.budget_ms.?);
    try report.emit(
        "begin: state={s} failure={s} returned={s} chooser={d} ms\n",
        .{
            @tagName(session.state()),
            @tagName(session.failure()),
            if (begin_error) |err| @errorName(err) else "<accepted>",
            elapsedMs(io, chooser_opened),
        },
    );

    // A terminal outcome is the answer, whatever `begin` returned with it.
    var verdict: ?Exit = switch (beginOutcome(session.state(), begin_error)) {
        .live => null,
        .canceled => .canceled,
        .denied => .denied,
        .failed => .failed,
        .stopped => .ended_early,
    };
    var dump_failed = false;
    if (verdict == null) {
        const live_state = try waitForLiveStream(io, report, &session, budget.started, budget.deadline);
        if (live_state == .streaming) {
            verdict = try observeFrames(
                gpa,
                io,
                report,
                &session,
                &wake,
                options,
                budget.started,
                budget.deadline,
                &dump_failed,
            );
        } else if (capture.isTerminal(live_state)) {
            verdict = outcomeExit(beginOutcome(live_state, null));
        } else {
            // The budget ran out while the session was still selecting or
            // starting. That is neither a stream nor a provider failure, and
            // it gets its own code rather than being counted as either.
            try report.emit("stream: never went live inside the budget\n", .{});
            verdict = .not_streaming;
        }
    }
    var result: Exit = verdict.?;

    const borrowed = session.stop();
    try report.emit("stop: state={s} outstanding={d} after {d} ms\n", .{
        @tagName(session.state()),
        borrowed,
        elapsedMs(io, budget.started),
    });
    if (borrowed != 0) result = .still_held;

    session.deinit() catch |err| {
        try report.emit("session deinit refused: {s}\n", .{@errorName(err)});
        return .still_held;
    };
    session_live = false;
    provider.deinit() catch |err| {
        try report.emit("provider deinit refused: {s}\n", .{@errorName(err)});
        return .still_held;
    };
    provider_live = false;
    if (result == .observed and dump_failed) result = .dump_refused;
    return result;
}

/// The owner-loss half: a second approved session whose weak owner is dropped
/// while a real frame from the provider is still out. It exists because the
/// one thing a capture session must never leak is the buffer a window that has
/// already gone away was holding.
fn runOwnerLossArm(
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    options: Options,
) !Exit {
    const caps: Capabilities = linux_capture.capabilities();
    if (!caps.available) {
        try report.emit("owner loss: not started, this provider is unavailable: {s}\n", .{caps.unavailable_reason});
        return .unavailable;
    }
    try report.emit(
        "owner loss: this is a second approved session; the chooser opens again, " ++
            "and you approve it again yourself\n",
        .{},
    );

    const request: Request = .{
        .sources = options.requestedSources(),
        .cursor_mode = options.cursor.?,
        .persistence = options.persistence,
        .multiple = options.multiple,
        .parent_window = options.parent_window,
    };

    var owner: Owner = .{};
    var wake: WakeCounter = .{};
    var session: capture.Session = capture.Session.init(
        gpa,
        io,
        .{ .context = &owner, .is_alive_fn = Owner.probe },
        @as(usize, options.queue_depth),
    );
    var provider: linux_capture.Provider = linux_capture.Provider.init(gpa, io, session.sink());
    var session_live = true;
    var provider_live = true;
    defer if (provider_live) provider.deinit() catch |err| {
        report.emit("PROVIDER CLEANUP REFUSED: {s}\n", .{@errorName(err)}) catch
            @panic("W20 capture smoke could not report the refused provider cleanup");
    };
    defer if (session_live) session.deinit() catch |err| {
        report.emit("SESSION CLEANUP REFUSED: {s}\n", .{@errorName(err)}) catch
            @panic("W20 capture smoke could not report the refused session cleanup");
    };
    session.attach(provider.backend());
    session.setWake(&wake, WakeCounter.onWake);

    // The held frame is released on every path out of this function, so an
    // error between holding it and returning it cannot pin the provider.
    var held: ?FrameDescriptor = null;
    defer if (held) |*frame| session.releaseFrame(frame);

    const chooser_opened: Io.Timestamp = .now(io, .real);
    var begin_error: ?anyerror = null;
    session.begin(request) catch |err| {
        begin_error = err;
    };
    const budget = postApprovalBudget(Io.Timestamp.now(io, .real), options.budget_ms.?);
    const outcome = beginOutcome(session.state(), begin_error);
    try report.emit("owner loss begin: state={s} failure={s} returned={s} chooser={d} ms\n", .{
        @tagName(session.state()),
        @tagName(session.failure()),
        if (begin_error) |err| @errorName(err) else "<accepted>",
        elapsedMs(io, chooser_opened),
    });
    if (outcome != .live) return outcomeExit(outcome);

    if (try waitForLiveStream(io, report, &session, budget.started, budget.deadline) != .streaming) {
        try report.emit("owner loss: the stream never went live inside the budget\n", .{});
        return if (capture.isTerminal(session.state()))
            outcomeExit(beginOutcome(session.state(), null))
        else
            .not_streaming;
    }

    // One frame is taken out and held on purpose: the buffer this run pins is
    // the thing the owner-loss path has to survive.
    while (true) {
        if (session.acquireLatest()) |frame| {
            held = frame;
            break;
        }
        if (Io.Timestamp.now(io, .real).nanoseconds >= budget.deadline.nanoseconds) {
            try report.emit("owner loss: no frame arrived inside the budget\n", .{});
            return .no_frame;
        }
        try Io.sleep(io, poll_interval, .real);
    }
    if (try inspectFrame(report, &session, &(held.?), 0, options.requestedSources())) |reason| {
        try report.emit("owner loss frame mismatch: {s}\n", .{reason});
        return .mismatch;
    }
    const held_bytes = held.?.totalBytes();
    try report.emit("owner loss: holding one real frame of {d} bytes while the owner dies\n", .{held_bytes});

    // The owner is gone for real: the probe every provider callback re-checks
    // now answers false, and the facade does the rest.
    owner.alive = false;
    session.enforceOwnerLifetime();
    try report.emit(
        "owner loss: state={s} needs_teardown={} outstanding={d}\n",
        .{
            @tagName(session.state()),
            session.needsTeardown(),
            session.outstandingFrames(),
        },
    );
    if (session.state() != .stopped or session.outstandingFrames() != 1) {
        try report.emit("owner loss: the session did not end while one frame was still out\n", .{});
        return .owner_loss_incomplete;
    }

    // The provider is asked to free itself with a frame it produced still out.
    // It must refuse, and it must leave itself intact for the retry.
    if (provider.deinit()) |_| {
        // The provider freed itself with a frame still out, which is the
        // contract this half exists to disprove. Two things follow from it and
        // both are deliberate. The flag is cleared so the deferred cleanup does
        // not touch a provider that no longer exists, and the hold is dropped
        // without a release: the frame's release callback lives in the
        // provider that just freed itself, so calling it would be using the
        // freed lifetime. The buffer stays leaked, and that leak is the
        // contract violation this line reports.
        provider_live = false;
        held = null;
        try report.emit(
            "owner loss: the provider freed itself while a frame of {d} bytes was still out; " ++
                "the buffer is leaked and its release callback is not called on a freed provider\n",
            .{held_bytes},
        );
        return .owner_loss_incomplete;
    } else |err| {
        try report.emit("owner loss: provider.deinit refused as expected: {s}\n", .{@errorName(err)});
    }

    session.releaseFrame(&(held.?));
    held = null;
    try report.emit("owner loss: frame returned, outstanding={d}\n", .{session.outstandingFrames()});
    if (session.outstandingFrames() != 0) return .owner_loss_incomplete;

    session.deinit() catch |err| {
        try report.emit("owner loss: session deinit refused: {s}\n", .{@errorName(err)});
        return .still_held;
    };
    session_live = false;
    provider.deinit() catch |err| {
        try report.emit("owner loss: provider deinit refused: {s}\n", .{@errorName(err)});
        return .still_held;
    };
    provider_live = false;
    try report.emit(
        "owner loss: the session and the provider are both freed, no frame and no buffer left, wakes={d}\n",
        .{wake.observed()},
    );
    return .observed;
}

pub fn main(init: std.process.Init) !u8 {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var report: Reporter = .{ .io = io };
    try report.emit("W20 screen capture smoke\n", .{});
    try report.emit("{s}\n", .{usage_text});

    const options = parseArgs(gpa, init, &report) catch |err| {
        // Every refusal has already said why on stdout; the exit code only
        // says that this run never reached the portal.
        std.log.err("refused before any capture: {s}", .{@errorName(err)});
        return exitCode(.usage);
    };
    if (options.help) return exitCode(.observed);

    try reportCapabilities(&report);

    if (!options.authorize) {
        try report.emit(
            "default run: no provider call, no portal request, no chooser, no frame\n" ++
                "native half: {s} with an exact source class, cursor policy and budget;\n" ++
                "             the flag is not an approval, and this binary never answers the chooser\n",
            .{authorize_flag},
        );
        try report.emit("verdict: capabilities only, nothing captured; exit={d}\n", .{exitCode(.observed)});
        return exitCode(.observed);
    }
    try report.emit("native half: armed for this process by {s}\n", .{authorize_flag});

    const capture_code = try runCaptureArm(gpa, io, &report, options);
    if (capture_code != .observed) {
        try report.emit("verdict: the capture half did not observe a validated stream; exit={d}\n", .{
            exitCode(capture_code),
        });
        return exitCode(capture_code);
    }
    if (options.owner_loss) {
        const owner_code = try runOwnerLossArm(gpa, io, &report, options);
        if (owner_code != .observed) {
            try report.emit("verdict: the owner-loss half did not release everything it owned; exit={d}\n", .{
                exitCode(owner_code),
            });
            return exitCode(owner_code);
        }
        try report.emit("verdict: frames validated and every owned resource released; exit={d}\n", .{
            exitCode(.observed),
        });
        return exitCode(.observed);
    }
    try report.emit("not run: the owner-loss half (--exercise-owner-loss), which needs a second approval\n", .{});
    try report.emit("verdict: frames validated and every owned resource released; exit={d}\n", .{
        exitCode(.observed),
    });
    return exitCode(.observed);
}

// ── Behaviour regressions ──────────────────
//
// Everything below drives this file's own verdict through a provider that
// does no I/O: no D-Bus call, no portal request, no chooser, no display
// server and no PipeWire daemon. What a test checks is what a parent reads,
// the exit code and the report it would otherwise have to parse in prose.

/// Real memory behind every scripted frame's `pixels`, plus the count of
/// producer buffers this process still holds. `released` is what went back
/// through the session's own release path, which is the only path that
/// leaves the provider's accounting honest.
const FramePool = struct {
    bytes: [4096]u8 = @splat(0),
    live: u32 = 0,
    released: u32 = 0,

    fn release(ctx: ?*anyopaque) void {
        const self: *FramePool = @ptrCast(@alignCast(ctx.?));
        self.live -= 1;
        self.released += 1;
    }
};

/// One frame the scripted provider hands over, described the way a provider
/// describes its own buffers: the payload is named by `pixels`, and how much
/// of it the provider filled is named by `mapped_bytes`.
const ScriptedFrame = struct {
    ts_ns: i96 = 0,
    /// What the descriptor claims is mapped. Zero claims the whole payload.
    mapped_bytes: usize = 0,
    /// Names an address this process must never read. A descriptor that
    /// over-claims its mapping may not touch it, and an address with nothing
    /// mapped behind it turns a surviving read into a fault instead of a
    /// quiet number this test could not see.
    unreadable_pixels: bool = false,
};

/// How long a scripted provider waits on a drive before it hands over the next
/// frame, the way a real screen delivers one at the rate it paints rather than
/// as fast as a consumer can ask for it.
const Pace = struct {
    io: Io,
    interval: Io.Duration,
};

/// One thing the scripted provider does on a drive. A transport that goes
/// quiet and comes back, or dies halfway through, is an ordered list of these,
/// so a test states the whole sequence and gets the same verdict every run.
const Step = union(enum) {
    /// A state the provider reports, the way a paused transport reports one
    /// without ending the stream behind it.
    state: SessionState,
    frame: ScriptedFrame,
};

/// A provider that does no I/O and reports exactly what the test scripted.
/// Its transport does one scripted step per drive, which is the shape a provider
/// with a frame pool has, so every frame the run observes is one the run
/// asked for and the whole sequence arrives in the order the test wrote it.
const ScriptedProvider = struct {
    sink: capture.Sink,
    pool: *FramePool,
    steps: []const Step = &.{},
    /// The terminal state the provider reports once it is streaming, so a
    /// test can name the exact moment a stream dies.
    terminal: ?SessionState = null,

    /// The negotiated stream report the scripted provider hands the facade
    /// before any frame, the way a provider describes what it negotiated.
    /// Null reports none at all, which leaves the source class unproved.
    format: ?capture.StreamInfo = null,
    /// Keeps producing the last scripted step once the script is spent, the way
    /// a live screen never runs out of something to deliver. A run waiting on a
    /// paused stream waits against this, so what bounds it is the budget rather
    /// than the length of the script.
    repeat_last: bool = false,
    /// Waits this long on every drive before it produces, so a run asked for
    /// more frames than its window can carry is bounded by its clock instead of
    /// by how fast it can pull.
    pace: ?Pace = null,
    next_step: usize = 0,
    drives: u32 = 0,

    fn backend(self: *ScriptedProvider) capture.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: capture.Backend.VTable = .{
        .begin = beginImpl,
        .stop = stopImpl,
        .poll = pollImpl,
    };

    fn beginImpl(ctx: *anyopaque, _: Request) anyerror!void {
        const self: *ScriptedProvider = @ptrCast(@alignCast(ctx));
        self.sink.state(self.sink.ctx, .selecting, .none);
        self.sink.state(self.sink.ctx, .starting, .none);
        self.sink.state(self.sink.ctx, .streaming, .none);
        if (self.format) |info| self.sink.format(self.sink.ctx, info);
        if (self.terminal) |state| self.sink.state(self.sink.ctx, state, .provider_failed);
    }

    fn stopImpl(ctx: *anyopaque) void {
        const self: *ScriptedProvider = @ptrCast(@alignCast(ctx));
        self.sink.state(self.sink.ctx, .stopped, .none);
    }

    fn pollImpl(ctx: *anyopaque, _: i32) anyerror!usize {
        const self: *ScriptedProvider = @ptrCast(@alignCast(ctx));
        self.drives += 1;
        if (self.pace) |pace| try Io.sleep(pace.io, pace.interval, .real);
        if (self.steps.len == 0) return 0;
        if (self.next_step >= self.steps.len and !self.repeat_last) return 0;
        const at = @min(self.next_step, self.steps.len - 1);
        self.next_step += 1;
        switch (self.steps[at]) {
            .state => |reported| {
                // A stream that ends is a failure the way a provider reports
                // one; a pause is not an ending and carries no reason.
                self.sink.state(self.sink.ctx, reported, if (capture.isTerminal(reported)) .provider_failed else .none);
                return 0;
            },
            .frame => |scripted| {
                self.sink.frame(self.sink.ctx, self.build(scripted));
                return 1;
            },
        }
    }

    /// A 4x4 BGRA frame: four packed pixels a row, 16 bytes a row and 64
    /// bytes of payload, which is a real layout rather than a stub value.
    fn build(self: *ScriptedProvider, scripted: ScriptedFrame) FrameDescriptor {
        self.pool.live += 1;
        var frame: FrameDescriptor = .{
            .width = 4,
            .height = 4,
            .format = .bgra8,
            .stride = 16,
            .presentation_timestamp_ns = scripted.ts_ns,
            .pixels = if (scripted.unreadable_pixels)
                @as([*]const u8, @ptrFromInt(1))
            else
                self.pool.bytes[0..].ptr,
            .release_fn = FramePool.release,
            .release_ctx = self.pool,
        };
        frame.planes[0] = .{
            .offset = 0,
            .stride = 16,
            .width = 4,
            .height = 4,
            .size = if (scripted.mapped_bytes == 0) 64 else scripted.mapped_bytes,
        };
        return frame;
    }
};

/// Runs the frame half once against a session that is already streaming, with
/// a budget that has already expired. Nothing here waits on a clock, so a
/// test states the case it means and gets the same answer every run.
///
/// `sources` is the class the operator approved, which is what the provider's
/// own class is read against.
fn observeUnderExpiredBudget(
    session: *capture.Session,
    wake: *const WakeCounter,
    sources: capture.SourceType,
    frames: u32,
    report: *Reporter,
) !Exit {
    const options: Options = .{
        .authorize = true,
        .monitor = sources.has(.monitor),
        .window = sources.has(.window),
        .virtual = sources.has(.virtual),
        .cursor = .embedded,
        .budget_ms = budget_floor_ms,
        .frames = frames,
        .queue_depth = 4,
    };
    const now = Io.Timestamp.now(std.testing.io, .real);
    var dump_failed = false;
    return observeFrames(
        std.testing.allocator,
        std.testing.io,
        report,
        session,
        wake,
        options,
        now,
        now,
        &dump_failed,
    );
}

/// The same half with a budget that starts now and ends in `budget_ms`, plus
/// the wall time the wait actually took. A test that has to prove the run
/// waited — rather than returned the moment something else happened — needs a
/// clock it can read, and this is the only place one is handed to it.
fn observeUnderLiveBudget(
    session: *capture.Session,
    wake: *const WakeCounter,
    sources: capture.SourceType,
    frames: u32,
    budget_ms: u64,
    report: *Reporter,
) !struct { code: Exit, elapsed_ms: i64 } {
    const options: Options = .{
        .authorize = true,
        .monitor = sources.has(.monitor),
        .window = sources.has(.window),
        .virtual = sources.has(.virtual),
        .cursor = .embedded,
        .budget_ms = budget_ms,
        .frames = frames,
        .queue_depth = 4,
    };
    const started = Io.Timestamp.now(std.testing.io, .real);
    const deadline = started.addDuration(Io.Duration.fromMilliseconds(@intCast(budget_ms)));
    var dump_failed = false;
    const code = try observeFrames(
        std.testing.allocator,
        std.testing.io,
        report,
        session,
        wake,
        options,
        started,
        deadline,
        &dump_failed,
    );
    return .{ .code = code, .elapsed_ms = elapsedMs(std.testing.io, started) };
}

test "api-w20 capture runner: a provider that fails before the first frame keeps its own exit code" {
    var owner: Owner = .{};
    var pool: FramePool = .{};
    var wake: WakeCounter = .{};
    var session: capture.Session = capture.Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = Owner.probe },
        4,
    );
    defer session.deinit() catch unreachable;

    // The stream dies before anything was ever delivered. That is a provider
    // failure, not a run that sat out its budget seeing nothing.
    var provider: ScriptedProvider = .{
        .sink = session.sink(),
        .pool = &pool,
        .terminal = .failed,
    };
    session.attach(provider.backend());
    try session.begin(.{ .sources = .monitor });

    const out = try std.testing.allocator.alloc(u8, 4096);
    var sink: std.Io.Writer.Allocating = .initOwnedSlice(std.testing.allocator, out);
    defer sink.deinit();
    var report: Reporter = .{ .io = std.testing.io, .sink = &sink.writer };
    const code = try observeUnderExpiredBudget(&session, &wake, .monitor, 30, &report);

    try std.testing.expectEqual(Exit.failed, code);
    try std.testing.expectEqual(@as(u32, 0), pool.live);
    try std.testing.expectEqual(@as(u32, 0), pool.released);
}

test "api-w20 capture runner: a backwards presentation timestamp is a frame mismatch" {
    var owner: Owner = .{};
    var pool: FramePool = .{};
    var wake: WakeCounter = .{};
    var session: capture.Session = capture.Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = Owner.probe },
        4,
    );
    defer session.deinit() catch unreachable;

    // Two good frames, in a layout the provider agreed with, whose
    // presentation timestamps move backwards: a descriptor that disagrees
    // with the stream it claims to describe. The verdict is a fact about both
    // frames, so the window here has room for them: this run may not need a
    // second frame behind an expired budget to find a disagreement.
    var provider: ScriptedProvider = .{
        .sink = session.sink(),
        .pool = &pool,
        .steps = &.{ .{ .frame = .{ .ts_ns = 2000 } }, .{ .frame = .{ .ts_ns = 1000 } } },
    };
    session.attach(provider.backend());
    try session.begin(.{ .sources = .monitor });

    const out = try std.testing.allocator.alloc(u8, 4096);
    var sink: std.Io.Writer.Allocating = .initOwnedSlice(std.testing.allocator, out);
    defer sink.deinit();
    var report: Reporter = .{ .io = std.testing.io, .sink = &sink.writer };

    const result = try observeUnderLiveBudget(&session, &wake, .monitor, 2, 1_000, &report);

    try std.testing.expectEqual(Exit.mismatch, result.code);
    // Both frames went back to the producer, and the verdict says one of them
    // disagreed with the stream it came from.
    try std.testing.expectEqual(@as(u32, 2), pool.released);
    try std.testing.expectEqual(@as(u32, 0), pool.live);
}

test "api-w20 capture runner: a descriptor that over-claims its mapping is refused before any pixel byte is read" {
    var owner: Owner = .{};
    var pool: FramePool = .{};
    var wake: WakeCounter = .{};
    var session: capture.Session = capture.Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = Owner.probe },
        4,
    );
    defer session.deinit() catch unreachable;

    // One row of the mapping is filled and the descriptor claims four. The
    // pixel address names nothing this process may read, so a run that samples
    // the head or the tail before checking the mapping faults here instead of
    // returning a number this test could not see.
    var provider: ScriptedProvider = .{
        .sink = session.sink(),
        .pool = &pool,
        .steps = &.{.{ .frame = .{ .ts_ns = 1000, .mapped_bytes = 16, .unreadable_pixels = true } }},
    };
    session.attach(provider.backend());
    try session.begin(.{ .sources = .monitor });

    const out = try std.testing.allocator.alloc(u8, 4096);
    var sink: std.Io.Writer.Allocating = .initOwnedSlice(std.testing.allocator, out);
    defer sink.deinit();
    var report: Reporter = .{ .io = std.testing.io, .sink = &sink.writer };

    const code = try observeUnderExpiredBudget(&session, &wake, .monitor, 1, &report);

    try std.testing.expectEqual(Exit.mismatch, code);
    // Refused rather than graded, and the frame still went back to the
    // producer exactly once.
    try std.testing.expectEqual(@as(u32, 1), pool.released);
    try std.testing.expectEqual(@as(u32, 0), pool.live);
}

test "api-w20 capture runner: a frame the provider publishes after stop goes straight back and is never queued" {
    var owner: Owner = .{};
    var pool: FramePool = .{};
    var wake: WakeCounter = .{};
    var session: capture.Session = capture.Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = Owner.probe },
        4,
    );
    defer session.deinit() catch unreachable;

    // The provider thread is still running when the session is stopped. The
    // next frame it publishes is the boundary this run has to survive: it
    // belongs to the producer, not to a stopped queue.
    var provider: ScriptedProvider = .{
        .sink = session.sink(),
        .pool = &pool,
    };
    session.attach(provider.backend());
    session.setWake(&wake, WakeCounter.onWake);
    try session.begin(.{ .sources = .monitor });
    const queued_before_stop = session.frames.total_pushed;

    try std.testing.expectEqual(@as(u32, 0), session.stop());
    provider.sink.frame(provider.sink.ctx, provider.build(.{}));

    try std.testing.expectEqual(SessionState.stopped, session.state());
    try std.testing.expectEqual(queued_before_stop, session.frames.total_pushed);
    try std.testing.expect(session.acquireLatest() == null);
    // Handed back once, nothing left holding it, and a consumer blocked on
    // this session was never woken for a frame that never became one.
    try std.testing.expectEqual(@as(u32, 1), pool.released);
    try std.testing.expectEqual(@as(u32, 0), pool.live);
    try std.testing.expectEqual(@as(u32, 0), session.outstandingFrames());
    try std.testing.expectEqual(@as(u64, 0), wake.observed());
}

test "api-w20 capture runner: a paused stream that keeps producing frames is waited out to the deadline" {
    var owner: Owner = .{};
    var pool: FramePool = .{};
    var wake: WakeCounter = .{};
    var session: capture.Session = capture.Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = Owner.probe },
        4,
    );
    defer session.deinit() catch unreachable;

    // A transport that pauses in front of a screen that never runs out of
    // something to deliver. The stream is not over, so the only thing allowed
    // to end this run is the budget it was handed.
    var provider: ScriptedProvider = .{
        .sink = session.sink(),
        .pool = &pool,
        .steps = &.{ .{ .state = .starting }, .{ .frame = .{ .ts_ns = 1000 } } },
        .repeat_last = true,
    };
    session.attach(provider.backend());
    try session.begin(.{ .sources = .monitor });

    const out = try std.testing.allocator.alloc(u8, 4096);
    var sink: std.Io.Writer.Allocating = .initOwnedSlice(std.testing.allocator, out);
    defer sink.deinit();
    var report: Reporter = .{ .io = std.testing.io, .sink = &sink.writer };

    const result = try observeUnderLiveBudget(&session, &wake, .monitor, 1, 250, &report);

    // The whole window went by instead of a pause being reported as an expired
    // one, and the frames that kept arriving did not keep the run alive past it.
    try std.testing.expect(result.elapsed_ms >= 250);
    try std.testing.expect(result.elapsed_ms < 5_000);
    try std.testing.expectEqual(Exit.no_frame, result.code);
    try std.testing.expectEqual(SessionState.starting, session.state());
    // A frame a paused session cannot deliver goes back to its producer every
    // time it arrives, and not one of them reached the run.
    try std.testing.expectEqual(@as(u32, 0), pool.live);
    try std.testing.expect(pool.released > 0);
}

test "api-w20 capture runner: a stream that pauses and delivers nothing is waited out to the deadline" {
    var owner: Owner = .{};
    var pool: FramePool = .{};
    var wake: WakeCounter = .{};
    var session: capture.Session = capture.Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = Owner.probe },
        4,
    );
    defer session.deinit() catch unreachable;

    // A pause that stays a pause. Nothing arrives behind it, so the run has
    // nothing to observe — and it still has to wait before it can say so.
    var provider: ScriptedProvider = .{
        .sink = session.sink(),
        .pool = &pool,
        .steps = &.{.{ .state = .starting }},
    };
    session.attach(provider.backend());
    try session.begin(.{ .sources = .monitor });

    const out = try std.testing.allocator.alloc(u8, 4096);
    var sink: std.Io.Writer.Allocating = .initOwnedSlice(std.testing.allocator, out);
    defer sink.deinit();
    var report: Reporter = .{ .io = std.testing.io, .sink = &sink.writer };

    const result = try observeUnderLiveBudget(&session, &wake, .monitor, 1, 200, &report);

    try std.testing.expect(result.elapsed_ms >= 200);
    try std.testing.expect(result.elapsed_ms < 5_000);
    // No frame is a verdict about the window, and it took the window.
    try std.testing.expectEqual(Exit.no_frame, result.code);
    try std.testing.expectEqual(SessionState.starting, session.state());
    try std.testing.expectEqual(@as(u32, 0), pool.live);
    try std.testing.expectEqual(@as(u32, 0), pool.released);
}

test "api-w20 capture runner: a stream that pauses and comes back still delivers the frames the run asked for" {
    var owner: Owner = .{};
    var pool: FramePool = .{};
    var wake: WakeCounter = .{};
    var session: capture.Session = capture.Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = Owner.probe },
        4,
    );
    defer session.deinit() catch unreachable;

    // The stream goes quiet for one frame and comes back. The run was asked for
    // two frames, so the pause is a wait and not an ending.
    var provider: ScriptedProvider = .{
        .sink = session.sink(),
        .pool = &pool,
        .steps = &.{
            .{ .state = .starting },
            .{ .frame = .{ .ts_ns = 1000 } },
            .{ .state = .streaming },
            .{ .frame = .{ .ts_ns = 2000 } },
            .{ .frame = .{ .ts_ns = 3000 } },
        },
    };
    session.attach(provider.backend());
    try session.begin(.{ .sources = .monitor });

    const out = try std.testing.allocator.alloc(u8, 4096);
    var sink: std.Io.Writer.Allocating = .initOwnedSlice(std.testing.allocator, out);
    defer sink.deinit();
    var report: Reporter = .{ .io = std.testing.io, .sink = &sink.writer };

    const result = try observeUnderLiveBudget(&session, &wake, .monitor, 2, 5_000, &report);

    try std.testing.expectEqual(Exit.observed, result.code);
    try std.testing.expectEqual(SessionState.streaming, session.state());
    // The frame behind the pause went back to the producer, the two behind the
    // resume went back through the run, and nothing is still held.
    try std.testing.expectEqual(@as(u32, 3), pool.released);
    try std.testing.expectEqual(@as(u32, 0), pool.live);
    try std.testing.expectEqual(@as(u32, 0), session.outstandingFrames());
    try std.testing.expect(result.elapsed_ms < 2_000);
}

test "api-w20 capture runner: a stream that dies while it is paused ends at the failure, not at the deadline" {
    var owner: Owner = .{};
    var pool: FramePool = .{};
    var wake: WakeCounter = .{};
    var session: capture.Session = capture.Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = Owner.probe },
        4,
    );
    defer session.deinit() catch unreachable;

    // A pause, then a provider failure. A state the session never leaves is the
    // answer, so the budget is never the reason this run reports one — even
    // though it has five whole seconds left to wait.
    var provider: ScriptedProvider = .{
        .sink = session.sink(),
        .pool = &pool,
        .steps = &.{ .{ .state = .starting }, .{ .state = .failed } },
    };
    session.attach(provider.backend());
    try session.begin(.{ .sources = .monitor });

    const out = try std.testing.allocator.alloc(u8, 4096);
    var sink: std.Io.Writer.Allocating = .initOwnedSlice(std.testing.allocator, out);
    defer sink.deinit();
    var report: Reporter = .{ .io = std.testing.io, .sink = &sink.writer };

    const result = try observeUnderLiveBudget(&session, &wake, .monitor, 1, 5_000, &report);

    try std.testing.expectEqual(Exit.failed, result.code);
    try std.testing.expectEqual(SessionState.failed, session.state());
    try std.testing.expect(result.elapsed_ms < 2_000);
    try std.testing.expectEqual(@as(u32, 0), pool.live);
    try std.testing.expectEqual(@as(u32, 0), pool.released);
}

test "api-w20 capture runner: a stream that never runs dry still ends on the budget" {
    var owner: Owner = .{};
    var pool: FramePool = .{};
    var wake: WakeCounter = .{};
    var session: capture.Session = capture.Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = Owner.probe },
        4,
    );
    defer session.deinit() catch unreachable;

    // A screen that never runs out of something to deliver, handing it over
    // as fast as it is asked. Nothing here waits and nothing here ends, so the
    // requested count would be the only thing that stopped this run — and a
    // budget that is already gone has to stop it anyway.
    var provider: ScriptedProvider = .{
        .sink = session.sink(),
        .pool = &pool,
        .steps = &.{.{ .frame = .{ .ts_ns = 1000 } }},
        .repeat_last = true,
    };
    session.attach(provider.backend());
    try session.begin(.{ .sources = .monitor });

    const out = try std.testing.allocator.alloc(u8, 4096);
    var sink: std.Io.Writer.Allocating = .initOwnedSlice(std.testing.allocator, out);
    defer sink.deinit();
    var report: Reporter = .{ .io = std.testing.io, .sink = &sink.writer };

    const code = try observeUnderExpiredBudget(&session, &wake, .monitor, 30, &report);

    // Thirty frames were asked for and the window for them closed, so the
    // answer is the partial run's own code and never the complete run's.
    try std.testing.expectEqual(Exit.incomplete, code);
    try std.testing.expectEqual(SessionState.streaming, session.state());
    // The frame the run was holding when the budget ended went back to its
    // producer exactly once, and nothing is still held by this process.
    try std.testing.expectEqual(@as(u32, 1), pool.released);
    try std.testing.expectEqual(@as(u32, 0), pool.live);
    try std.testing.expectEqual(@as(u32, 0), session.outstandingFrames());
}

test "api-w20 capture runner: a screen that paints faster than the budget is stopped by the clock, not by the count" {
    var owner: Owner = .{};
    var pool: FramePool = .{};
    var wake: WakeCounter = .{};
    var session: capture.Session = capture.Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = Owner.probe },
        4,
    );
    defer session.deinit() catch unreachable;

    // A screen painting four milliseconds a frame, asked for five hundred of
    // them inside four hundred milliseconds. The window carries about a
    // hundred, so the requested count is out of reach whatever this run does,
    // and the only thing that can end it honestly is the clock it was given.
    const requested: u32 = 500;
    var provider: ScriptedProvider = .{
        .sink = session.sink(),
        .pool = &pool,
        .steps = &.{.{ .frame = .{ .ts_ns = 1000 } }},
        .repeat_last = true,
        .pace = .{ .io = std.testing.io, .interval = Io.Duration.fromMilliseconds(4) },
    };
    session.attach(provider.backend());
    try session.begin(.{ .sources = .monitor });

    const out = try std.testing.allocator.alloc(u8, 4096);
    var sink: std.Io.Writer.Allocating = .initOwnedSlice(std.testing.allocator, out);
    defer sink.deinit();
    var report: Reporter = .{ .io = std.testing.io, .sink = &sink.writer };

    const result = try observeUnderLiveBudget(&session, &wake, .monitor, requested, 400, &report);

    // The budget closed while the stream was still live, so this run reports
    // what it saw rather than the five hundred frames it was owed.
    try std.testing.expectEqual(Exit.incomplete, result.code);
    try std.testing.expectEqual(SessionState.streaming, session.state());
    // The window went by before the answer, so the verdict names a deadline
    // this run actually reached rather than one it never looked at.
    try std.testing.expect(result.elapsed_ms >= 400);
    // It stopped on the clock rather than on the count it was handed.
    try std.testing.expect(provider.drives < requested);
    // Every frame it took went back to its producer exactly once, the last one
    // included, and nothing is still held by this process.
    try std.testing.expectEqual(provider.drives, pool.released);
    try std.testing.expectEqual(@as(u32, 0), pool.live);
    try std.testing.expectEqual(@as(u32, 0), session.outstandingFrames());
}

test "api-w20 capture runner: a portal that named a class the approved request did not name is refused" {
    var owner: Owner = .{};
    var pool: FramePool = .{};
    var wake: WakeCounter = .{};
    var session: capture.Session = capture.Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = Owner.probe },
        4,
    );
    defer session.deinit() catch unreachable;

    // The operator approved a monitor and the portal answered with a window.
    // Every other field of the stream report describes the scripted frame
    // exactly, so the class is the only thing that disagrees — and it is the
    // one thing the approval was about. A window stream handed back as a
    // monitor capture is not the surface anybody approved.
    var provider: ScriptedProvider = .{
        .sink = session.sink(),
        .pool = &pool,
        .format = .{ .sources = .window, .source_class_known = true, .width = 4, .height = 4 },
        .steps = &.{.{ .frame = .{ .ts_ns = 1000 } }},
    };
    session.attach(provider.backend());
    try session.begin(.{ .sources = .monitor });

    const out = try std.testing.allocator.alloc(u8, 4096);
    var sink: std.Io.Writer.Allocating = .initOwnedSlice(std.testing.allocator, out);
    defer sink.deinit();
    var report: Reporter = .{ .io = std.testing.io, .sink = &sink.writer };

    const code = try observeUnderExpiredBudget(&session, &wake, .monitor, 1, &report);

    try std.testing.expectEqual(Exit.mismatch, code);
    // Refused rather than counted, and the frame still went back to its
    // producer exactly once.
    try std.testing.expectEqual(@as(u32, 1), pool.released);
    try std.testing.expectEqual(@as(u32, 0), pool.live);
    // Both sides of the disagreement are named, so a parent reads which class
    // was delivered and which one was approved instead of parsing prose.
    try std.testing.expect(std.mem.indexOf(
        u8,
        sink.written(),
        "the portal named <window> and the approved request was <monitor>",
    ) != null);
}

test "api-w20 capture runner: a named class inside a mixed request is not a mismatch" {
    var owner: Owner = .{};
    var pool: FramePool = .{};
    var wake: WakeCounter = .{};
    var session: capture.Session = capture.Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = Owner.probe },
        4,
    );
    defer session.deinit() catch unreachable;

    // The operator approved a monitor or a window and the chooser answered
    // with a monitor. That is one of the two approved classes, so there is
    // nothing to refuse: a request that offers more than the portal returned
    // is an ordinary answer, not a surface nobody approved.
    var provider: ScriptedProvider = .{
        .sink = session.sink(),
        .pool = &pool,
        .format = .{ .sources = .monitor, .source_class_known = true, .width = 4, .height = 4 },
        .steps = &.{.{ .frame = .{ .ts_ns = 1000 } }},
    };
    session.attach(provider.backend());
    try session.begin(.{ .sources = capture.SourceType.monitor.with(.window) });

    const out = try std.testing.allocator.alloc(u8, 4096);
    var sink: std.Io.Writer.Allocating = .initOwnedSlice(std.testing.allocator, out);
    defer sink.deinit();
    var report: Reporter = .{ .io = std.testing.io, .sink = &sink.writer };

    const code = try observeUnderExpiredBudget(&session, &wake, capture.SourceType.monitor.with(.window), 1, &report);

    try std.testing.expectEqual(Exit.observed, code);
    try std.testing.expectEqual(@as(u32, 1), pool.released);
    try std.testing.expectEqual(@as(u32, 0), pool.live);
    try std.testing.expectEqual(@as(u32, 0), session.outstandingFrames());
}

test "api-w20 capture runner: a portal that named no class leaves the class unproved, not guessed" {
    var owner: Owner = .{};
    var pool: FramePool = .{};
    var wake: WakeCounter = .{};
    var session: capture.Session = capture.Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = Owner.probe },
        4,
    );
    defer session.deinit() catch unreachable;

    // The portal named no class. It did not name a source of no class, so the
    // run neither refuses the frame nor calls the capture a match: the report
    // says the class is unproved, and every other field of the frame is still
    // checked against the stream the provider described.
    var provider: ScriptedProvider = .{
        .sink = session.sink(),
        .pool = &pool,
        .steps = &.{.{ .frame = .{ .ts_ns = 1000 } }},
    };
    session.attach(provider.backend());
    try session.begin(.{ .sources = .monitor });

    const out = try std.testing.allocator.alloc(u8, 4096);
    var sink: std.Io.Writer.Allocating = .initOwnedSlice(std.testing.allocator, out);
    defer sink.deinit();
    var report: Reporter = .{ .io = std.testing.io, .sink = &sink.writer };

    const code = try observeUnderExpiredBudget(&session, &wake, .monitor, 1, &report);

    try std.testing.expectEqual(Exit.observed, code);
    try std.testing.expectEqual(@as(u32, 1), pool.released);
    try std.testing.expectEqual(@as(u32, 0), pool.live);
    // An unnamed class is reported as unnamed. Printing the empty set as a
    // class of its own is the guess this run used to make.
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "sources=<unproved>") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "sources=<none>") == null);
}
