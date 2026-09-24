//! Linux screen capture provider.
//!
//! One real path exists: the XDG Desktop Portal `ScreenCast` handshake decides
//! what may be captured, and a PipeWire video stream delivers it. That path is
//! used on Wayland and on X11, because an X11 session reaches the same portal
//! API. The provider does not claim a second, X11-specific adapter: there is
//! none, and a plain `XGetImage` grab would duplicate the portal while
//! bypassing the permission decision the portal exists to make.
//!
//! Nothing here starts a capture on its own. `begin` is the only call that can
//! reach the portal, and only the application decides to make it.
const std = @import("std");
const capture = @import("../capture.zig");
const portal = @import("capture_portal.zig");
const pipewire = @import("capture_pipewire.zig");
const dbus = @import("dbus.zig");

pub const Capabilities = capture.Capabilities;
pub const SessionState = capture.SessionState;
pub const FailureReason = capture.FailureReason;
pub const StreamInfo = capture.StreamInfo;
pub const Backend = capture.Backend;

/// Resolved libpipewire-0.3, shared by every session in the process.
var shared_api: ?pipewire.Api = null;

/// Loads PipeWire once. Returns null when the library or a required entry point
/// is missing, which is reported as an unavailable capability rather than a
/// failure of the capture request.
pub fn pipeWireApi() ?*const pipewire.Api {
    if (shared_api == null) {
        shared_api = pipewire.Api.load() catch null;
    }
    if (shared_api) |*api| return api;
    return null;
}

/// Reads one environment variable out of `/proc/self/environ`. `scratch` holds
/// the copy, so the result stays valid for as long as the caller keeps it.
fn envValue(scratch: []u8, name: []const u8) ?[]const u8 {
    return dbus.getEnvFromProc(name, scratch);
}

/// Which display server the process is attached to. Read from the session the
/// environment describes, never from a probe that could prompt.
pub fn currentPlatform() capture.Platform {
    var scratch: [4096]u8 = undefined;
    if (envValue(&scratch, "XDG_SESSION_TYPE")) |session| {
        if (std.mem.eql(u8, session, "wayland")) return .wayland;
        if (std.mem.eql(u8, session, "x11")) return .x11;
    }
    if (envValue(&scratch, "WAYLAND_DISPLAY") != null) return .wayland;
    if (envValue(&scratch, "DISPLAY") != null) return .x11;
    return .unknown;
}

/// What this provider can do right now. Nothing here contacts a user, so the
/// answer is stable and cheap to poll.
pub fn capabilities() Capabilities {
    const platform = currentPlatform();

    var scratch: [4096]u8 = undefined;
    const bus_address = envValue(&scratch, "DBUS_SESSION_BUS_ADDRESS");
    if (bus_address == null or bus_address.?.len == 0) {
        return .{
            .platform = platform,
            .unavailable_reason = "no D-Bus session bus in the environment",
        };
    }
    if (platform == .unknown) {
        return .{
            .platform = platform,
            .unavailable_reason = "neither Wayland nor X11 is present in the environment",
        };
    }
    if (pipeWireApi() == null) {
        return .{
            .platform = platform,
            .unavailable_reason = "libpipewire-0.3 could not be loaded",
        };
    }

    return .{
        .available = true,
        .platform = platform,
        .backend = .portal_pipewire,
        // What the portal offers, not what this build enumerates. The chooser
        // owns the concrete list of monitors and windows.
        .sources = capture.SourceType.monitor.with(.window),
        .cursor_modes = capture.CursorModes.embedded.with(.hidden).with(.metadata),
        .persistence_modes = capture.PersistenceModes.transient
            .with(.while_connected)
            .with(.until_revoked),
        .multiple_streams = true,
        .requires_user_approval = true,
    };
}

/// The cursor mode the portal accepts, which is not the order this tree
/// numbers its own modes in. The portal takes one bit of the modes it
/// advertises and refuses anything that is not a single one of them, so the
/// two are mapped here rather than carried across as the same number.
///
/// The switch has no fallback on purpose: a mode added to the public enum has
/// to be given a portal value here before any request can carry it.
fn cursorModeOnWire(mode: capture.CursorMode) portal.CursorMode {
    return switch (mode) {
        .embedded => .embedded,
        .hidden => .hidden,
        .metadata => .metadata,
    };
}

/// A capture session driven by the portal and a PipeWire stream.
pub const Provider = struct {
    gpa: std.mem.Allocator,
    /// The application's IO instance. Capture locks and the PipeWire callbacks
    /// both run against it, so the provider and the session share one.
    io: std.Io,
    sink: capture.Sink,
    bus: ?portal.ScreenCast = null,
    /// Heap-stable, because a consumer release returns a buffer into it. The
    /// stream therefore outlives the pointer here and is freed by `deinit`,
    /// never by `stop`.
    stream: ?*pipewire.Stream = null,
    /// Owned copy of the portal session handle, valid while `bus` is set. The
    /// two are set and cleared together, because the portal tears a session
    /// down with the connection that created it.
    session_handle: ?[]u8 = null,
    stop_requested: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, sink: capture.Sink) Provider {
        return .{ .gpa = gpa, .io = io, .sink = sink };
    }

    /// Frees the producer.
    ///
    /// Refuses while a consumer still holds a frame this provider produced.
    /// Releasing such a frame returns a buffer into the stream, so the stream
    /// has to stay alive until the frame is back. The refusal is a returned
    /// error rather than an assert because an assert is compiled out of a
    /// ReleaseFast build, and there the late release would hand a buffer to a
    /// freed stream. Nothing is freed on that path, so the provider is intact
    /// for the retry.
    pub fn deinit(self: *Provider) Error!void {
        self.stop();
        try self.releaseStream();
        // `stop` already ended the conversation unless it refused, so this is
        // the release that covers the refusal and the case where `stop` was
        // never reached. It is idempotent, because a handle that has been
        // returned is no longer the provider's to return again.
        self.endSession();
        self.* = undefined;
    }

    /// Frees the PipeWire stream this provider produced. This is only safe
    /// once every frame it produced is back, because releasing such a frame
    /// returns a buffer into that memory, so a frame that is still out refuses
    /// the call instead of leaving a release callback pointing at freed
    /// memory.
    ///
    /// The producer is asked to stop first. A session replaced by a second
    /// `begin` was never stopped, and without that step its thread loop would
    /// keep running and PipeWire would keep calling into freed memory.
    fn releaseStream(self: *Provider) Error!void {
        if (self.stream) |stream| {
            if (stream.outstandingFrames() != 0) return Error.FramesStillBorrowed;
            stream.stop();
            stream.destroyIfReady();
            self.gpa.destroy(stream);
        }
        self.stream = null;
    }

    /// Releases the portal session and the connection that owns it.
    ///
    /// The two are one ownership: the portal tears a session down when the
    /// connection that created it goes away, so the handle only names
    /// something while that connection is open. Releasing one and keeping the
    /// other is what leaves this provider pointing at a session the portal has
    /// already destroyed, which a later call would then hand to the portal as
    /// if it were live.
    ///
    /// Safe to call more than once: a handle that has been returned is no
    /// longer this provider's to return again, and a connection that has been
    /// closed is not this provider's to close again.
    fn endSession(self: *Provider) void {
        if (self.bus) |*bus| bus.deinit();
        self.bus = null;
        if (self.session_handle) |handle| self.gpa.free(handle);
        self.session_handle = null;
    }

    /// The vtable the host session drives.
    pub fn backend(self: *Provider) Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Backend.VTable = .{
        .begin = beginImpl,
        .stop = stopImpl,
        // No `poll`: PipeWire delivers every frame on its own stream thread, so
        // the session has nothing to drive and this provider leaves it absent.
    };

    fn beginImpl(ctx: *anyopaque, request: capture.Request) anyerror!void {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        self.begin(request) catch |err| {
            self.sink.state(self.sink.ctx, .failed, capture.classifyFailure(err));
            return err;
        };
    }

    fn stopImpl(ctx: *anyopaque) void {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        self.stop();
    }

    /// Runs the whole handshake. It blocks while the OS chooser is open, which
    /// is why the host session calls it without holding any lock.
    pub fn begin(self: *Provider, request: capture.Request) !void {
        const caps = capabilities();
        if (!caps.available) return error.CaptureUnsupported;

        const api = pipeWireApi() orelse return error.CaptureUnsupported;

        // A second selection replaces the first one, so the previous stream
        // has to be released before a new one takes its place. A frame that is
        // still out refuses the replacement: it would be returned into a
        // stream this call is about to free.
        try self.releaseStream();
        // The whole previous conversation goes, connection and handle
        // together. Replacing only the connection would leave the handle of a
        // session whose connection this provider has just closed, paired with
        // a connection that has never heard of it.
        self.endSession();
        self.bus = portal.ScreenCast.init(self.gpa) catch |err| {
            self.sink.state(self.sink.ctx, .failed, capture.classifyFailure(err));
            return err;
        };
        self.stop_requested = false;

        const bus = &self.bus.?;
        var created = bus.createSession() catch |err| {
            self.sink.state(self.sink.ctx, .failed, capture.classifyFailure(err));
            return err;
        };
        defer created.deinit();

        switch (created.code) {
            .canceled => {
                self.sink.state(self.sink.ctx, .canceled, .none);
                return error.CaptureCanceled;
            },
            .other => {
                self.sink.state(self.sink.ctx, .denied, .rejected);
                return error.CaptureDenied;
            },
            .success => {},
        }
        // The handle is the outcome's own copy, so this takes it instead of
        // reading one the outcome is about to release. Nothing is live before
        // it: the previous conversation went whole at the top of this call, so
        // there is no earlier handle to free and none to double free.
        const handle = created.session_handle orelse return error.PortalInvalidReply;
        created.session_handle = null;
        self.session_handle = handle;

        var selected = bus.selectSources(
            self.session_handle.?,
            request.sources.bits,
            request.multiple,
            cursorModeOnWire(request.cursor_mode),
            @intFromEnum(request.persistence),
            request.restore_token,
        ) catch |err| {
            self.sink.state(self.sink.ctx, .failed, capture.classifyFailure(err));
            return err;
        };
        defer selected.deinit();

        switch (selected.code) {
            .canceled => {
                self.sink.state(self.sink.ctx, .canceled, .none);
                return error.CaptureCanceled;
            },
            .other => {
                self.sink.state(self.sink.ctx, .denied, .rejected);
                return error.CaptureDenied;
            },
            .success => {},
        }

        var started = bus.start(self.session_handle.?, request.parent_window) catch |err| {
            self.sink.state(self.sink.ctx, .failed, capture.classifyFailure(err));
            return err;
        };
        defer started.deinit();

        switch (started.outcome.code) {
            .canceled => {
                self.sink.state(self.sink.ctx, .canceled, .none);
                return error.CaptureCanceled;
            },
            .other => {
                self.sink.state(self.sink.ctx, .denied, .rejected);
                return error.CaptureDenied;
            },
            .success => {},
        }

        const entry = started.primary() orelse {
            self.sink.state(self.sink.ctx, .failed, .provider_failed);
            return error.PortalNoStream;
        };
        // The portal names the chosen source and where it sits; PipeWire
        // negotiates only the pixel layout. Both halves travel together, so the
        // source survives every later format report instead of being erased by
        // the first one the stream sends.
        const selection: pipewire.SourceSelection = .{
            .sources = .{ .bits = entry.source_type },
            // A portal that names no class is not a source of no class.
            .known = entry.source_type != 0,
            .position_x = if (entry.position) |p| p.x else 0,
            .position_y = if (entry.position) |p| p.y else 0,
        };
        self.sink.format(self.sink.ctx, .{
            .node_id = entry.node_id,
            .sources = selection.sources,
            .source_class_known = selection.known,
            .position_x = selection.position_x,
            .position_y = selection.position_y,
        });

        // A consumer release returns a buffer into this stream, so it has to
        // live at a stable address for as long as any frame can exist.
        // Allocate before opening the remote descriptor, so allocation failure
        // cannot leave a descriptor without an owner.
        const stream = try self.gpa.create(pipewire.Stream);
        errdefer self.gpa.destroy(stream);
        stream.* = pipewire.Stream.init(self.gpa, self.io, api, self.sink);

        const fd = bus.openPipeWireRemote(self.session_handle.?) catch |err| {
            self.sink.state(self.sink.ctx, .failed, capture.classifyFailure(err));
            return err;
        };

        stream.start(fd, entry.node_id, selection) catch |err| {
            self.sink.state(self.sink.ctx, .failed, capture.classifyFailure(err));
            return err;
        };
        self.stream = stream;
    }

    /// Releases the PipeWire stream and the portal session. Every frame is
    /// already gone by the time this runs, because the host session releases
    /// frames before it stops a provider. The stream itself stays allocated
    /// until `deinit`, because a frame released after this call still points
    /// at it. Only the owner thread may call this.
    pub fn stop(self: *Provider) void {
        if (self.stop_requested) {
            if (self.stream) |stream| stream.destroyIfReady();
        } else {
            self.stop_requested = true;
            if (self.stream) |stream| stream.stop();
        }
        // The connection goes with the handle, on the first stop and on every
        // repeat of it. Releasing only the connection is what leaves a stopped
        // provider naming a session whose connection it has already closed,
        // and that stale handle is then freed by a later `begin` or `deinit`
        // as if it were still live.
        self.endSession();
    }
};

/// The refusals this provider raises for itself, plus the one that keeps a
/// borrowed frame alive. Errors the portal, the bus or PipeWire raise are their
/// own; `capture.classifyFailure` is the single mapping from every one of those
/// names to the reason a session records.
pub const Error = error{
    /// No provider on this platform. `Capabilities.unavailable_reason` says why.
    CaptureUnsupported,
    /// The chooser closed without a selection.
    CaptureCanceled,
    /// The user or policy refused the request.
    CaptureDenied,
    /// The portal answered without the session handle the next call needs.
    PortalInvalidReply,
    /// The portal answered without a stream to attach to.
    PortalNoStream,
    /// A consumer still holds a frame this provider produced, so the producer
    /// cannot be freed yet. Return the frame, then call `deinit` again.
    FramesStillBorrowed,
};

test "api-w20 a cursor mode this tree asks for reaches the portal as the bit it accepts" {
    // The portal advertises the modes it can draw as the bits one, two and
    // four, and refuses a request carrying anything else, so a request that
    // carried this tree's own numbering would be refused rather than honoured.
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(cursorModeOnWire(.embedded)));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(cursorModeOnWire(.hidden)));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(cursorModeOnWire(.metadata)));
}

// -- Session ownership regressions -----------------------------------------
// A portal session lives exactly as long as the connection that created it, so
// the handle and the connection are one thing to release. These cases drive the
// provider over a real socket pair with a counting allocator, so what they
// assert is the release accounting itself: how many copies the provider holds
// before the release, none after it, and exactly one connection closed.

const linux = std.os.linux;

/// One bus pair whose client end is a live `ScreenCast`, so a case can name
/// the connection descriptor and prove it was closed rather than forgotten.
fn conversationOn(gpa: std.mem.Allocator) !struct {
    screen: portal.ScreenCast,
    peer: std.posix.fd_t,
    near: std.posix.fd_t,
} {
    var ends: [2]i32 = undefined;
    const rc = linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &ends);
    if (linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    return .{
        .screen = .{ .gpa = gpa, .conn = dbus.Connection.initCustom(gpa, ends[0]) },
        .peer = @intCast(ends[1]),
        .near = @intCast(ends[0]),
    };
}

/// True while the descriptor is still open. `fcntl` reports without claiming, so
/// probing cannot change what a release after it finds.
fn isOpen(fd: std.posix.fd_t) bool {
    return linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)) != .BADF;
}

/// Counts every block the provider hands out and takes back, so a case can
/// name the number it is holding rather than only that the leak check at the
/// end of the test was quiet.
const CountingAllocator = struct {
    back: std.mem.Allocator,
    live: usize = 0,
    released: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const block = self.back.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live += 1;
        return block;
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.back.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remapFn(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.back.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.live -= 1;
        self.released += 1;
        self.back.rawFree(memory, alignment, ret_addr);
    }
};

/// A sink that records nothing, so these cases can drive `stop` and `deinit`
/// without a session on the other end.
const SilentSink = struct {
    fn frame(_: *anyopaque, _: capture.FrameDescriptor) void {}
    fn format(_: *anyopaque, _: StreamInfo) void {}
    fn state(_: *anyopaque, _: SessionState, _: FailureReason) void {}

    fn sink(self: *SilentSink) capture.Sink {
        return .{ .ctx = self, .frame = frame, .format = format, .state = state };
    }
};

test "api-w20 stopping a provider releases the portal session with its connection" {
    var gate: CountingAllocator = .{ .back = std.testing.allocator };
    const gpa = gate.allocator();
    var silence: SilentSink = .{};

    const pair = try conversationOn(gpa);
    defer _ = linux.close(pair.peer);

    var provider: Provider = .{
        .gpa = gpa,
        .io = std.testing.io,
        .sink = silence.sink(),
        .bus = pair.screen,
    };
    // One owned copy of the handle, which is what the provider is holding when
    // it is asked to stop.
    provider.session_handle = try gpa.dupe(u8, "/org/freedesktop/portal/desktop/session/nogui_stop");
    try std.testing.expectEqual(@as(usize, 1), gate.live);

    provider.stop();

    // The connection the session lived on is closed, not just dropped, and the
    // copy naming that session is gone: what is left is no handle and no
    // connection, so a stopped provider names nothing.
    try std.testing.expect(!isOpen(pair.near));
    try std.testing.expectEqual(@as(usize, 0), gate.live);
    try std.testing.expect(provider.session_handle == null);
    try std.testing.expect(provider.bus == null);

    // A repeated stop releases nothing twice. A second close of the same
    // descriptor number would land on whatever took that number next, and a
    // second free of the same block would be a double free, so the accounting
    // and a fresh probe of the number together prove neither happened.
    const before = gate.released;
    provider.stop();
    provider.stop();
    try std.testing.expectEqual(before, gate.released);
    try std.testing.expectEqual(@as(usize, 0), gate.live);

    try provider.deinit();
    try std.testing.expectEqual(@as(usize, 0), gate.live);
}

test "api-w20 a second begin leaves no handle from the session it replaced" {
    var gate: CountingAllocator = .{ .back = std.testing.allocator };
    const gpa = gate.allocator();
    var silence: SilentSink = .{};

    // A provider left holding the handle of a session whose connection a second
    // `begin` has already closed is the stale-session case this covers. The
    // second `begin` cannot run against a real bus here, so what the case drives
    // is the release the replacement performs and the invariant that has to hold
    // after it: whatever it released is gone, and nothing it did not release is
    // touched. A replacement that closed only the connection leaves the handle
    // behind, which is the first assertion; one that closed the connection twice
    // closes a descriptor it never opened, which is the accounting.
    const first = try conversationOn(gpa);
    defer _ = linux.close(first.peer);

    var provider: Provider = .{
        .gpa = gpa,
        .io = std.testing.io,
        .sink = silence.sink(),
        .bus = first.screen,
    };
    provider.session_handle = try gpa.dupe(u8, "/org/freedesktop/portal/desktop/session/nogui_first");
    try std.testing.expectEqual(@as(usize, 1), gate.live);

    // What the top of `begin` does before it builds a replacement: the whole
    // previous conversation goes, connection and handle together.
    provider.endSession();
    try std.testing.expect(!isOpen(first.near));
    try std.testing.expectEqual(@as(usize, 0), gate.live);
    try std.testing.expectEqual(@as(usize, 1), gate.released);

    // The handle and its connection are one ownership, so neither survives
    // without the other. A provider left naming a session its closed connection
    // took with it would hand that dead name back to the portal on the next
    // call.
    try std.testing.expect(provider.bus == null);
    try std.testing.expect(provider.session_handle == null);

    // The replacement's own handle is the only copy then, and releasing it
    // returns exactly that one: two handles were handed out across this case
    // and two came back.
    const second = try conversationOn(gpa);
    defer _ = linux.close(second.peer);
    provider.bus = second.screen;
    provider.session_handle = try gpa.dupe(u8, "/org/freedesktop/portal/desktop/session/nogui_second");
    try std.testing.expectEqual(@as(usize, 1), gate.live);
    provider.endSession();
    try std.testing.expect(!isOpen(second.near));
    try std.testing.expectEqual(@as(usize, 0), gate.live);
    try std.testing.expectEqual(@as(usize, 2), gate.released);

    try provider.deinit();
    try std.testing.expectEqual(@as(usize, 0), gate.live);
    try std.testing.expectEqual(@as(usize, 2), gate.released);
}

test "api-w20 a provider that never reached the portal holds nothing to release" {
    var gate: CountingAllocator = .{ .back = std.testing.allocator };
    const gpa = gate.allocator();
    var silence: SilentSink = .{};

    // A refused `begin` never opens a connection, so this provider is the state
    // a refusal leaves behind: no bus and no handle. Its release must therefore
    // release nothing, on the first call and on every repeat, or it would be
    // closing a descriptor it never opened.
    var provider: Provider = .{
        .gpa = gpa,
        .io = std.testing.io,
        .sink = silence.sink(),
    };
    try std.testing.expectEqual(@as(usize, 0), gate.live);

    provider.stop();
    provider.stop();
    try provider.deinit();

    try std.testing.expectEqual(@as(usize, 0), gate.live);
    try std.testing.expectEqual(@as(usize, 0), gate.released);
}
