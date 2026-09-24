//! Screen capture session lifecycle for the host layer.
//!
//! The facade owns the platform-neutral state machine, capability and source
//! metadata, weak-owner lifetimes, and frame delivery. A platform provider
//! (see `linux/capture.zig`) drives transitions through `Sink` and implements
//! `Backend`. Frames cross the seam as `image.FrameDescriptor` values, so the
//! W14 upload path and the noapi import stay the only route to the GPU.
//!
//! A backend either has a producer thread that pushes frames through `Sink` on
//! its own, or a transport that hands a frame over only when it is asked for
//! one. The first shape needs nothing from the facade; the second declares
//! `Backend.VTable.poll` and `Session.acquireLatest` drives it, so the
//! documented flow -- attach, begin, acquire -- reaches a real frame on a
//! platform that has no producer thread. Absent means push, because that is
//! what a provider that publishes on its own thread should say.
const std = @import("std");
const image = @import("image.zig");
const frame_source = @import("frame_source.zig");

pub const FrameDescriptor = image.FrameDescriptor;
pub const PixelFormat = image.PixelFormat;
pub const ColorSpace = image.ColorSpace;
pub const AlphaType = image.AlphaType;
pub const FrameSource = frame_source.FrameSource;

/// Window system the process is attached to.
pub const Platform = enum {
    unknown,
    wayland,
    x11,
    windows,
};

/// Capture path selected by the provider.
pub const BackendKind = enum {
    /// No usable provider was found. `Capabilities.unavailable_reason` says why.
    none,
    /// XDG Desktop Portal `ScreenCast` plus a PipeWire video stream. The
    /// portal is the only path that carries a user permission decision, and
    /// it is also the path an X11 session uses when a portal is present.
    portal_pipewire,
    /// Windows.Graphics.Capture with owned CPU copies of captured frames.
    graphics_capture,
};

/// Set of capturable source classes. The bit values are the portal's
/// `ScreenCast.SelectSources` type mask, so the set is a wire value.
pub const SourceType = struct {
    pub const none: SourceType = .{ .bits = 0 };
    /// Whole monitors.
    pub const monitor: SourceType = .{ .bits = 1 << 0 };
    /// Application windows.
    pub const window: SourceType = .{ .bits = 1 << 1 };
    /// User-created virtual sources such as a region or a webcam.
    pub const virtual: SourceType = .{ .bits = 1 << 2 };

    bits: u32 = 0,

    pub fn with(self: SourceType, other: SourceType) SourceType {
        return .{ .bits = self.bits | other.bits };
    }

    pub fn has(self: SourceType, other: SourceType) bool {
        return (self.bits & other.bits) == other.bits;
    }

    pub fn isEmpty(self: SourceType) bool {
        return self.bits == 0;
    }
};

/// Cursor rendering requested from the provider.
pub const CursorMode = enum(u32) {
    /// Drawn into the delivered frames.
    embedded = 0,
    /// Never drawn.
    hidden = 1,
    /// Left out of the frames and reported as stream metadata instead.
    metadata = 2,
};

/// Set of cursor modes a provider supports.
pub const CursorModes = struct {
    pub const none: CursorModes = .{ .bits = 0 };
    pub const embedded: CursorModes = .{ .bits = 1 << 0 };
    pub const hidden: CursorModes = .{ .bits = 1 << 1 };
    pub const metadata: CursorModes = .{ .bits = 1 << 2 };

    bits: u8 = 0,

    pub fn with(self: CursorModes, other: CursorModes) CursorModes {
        return .{ .bits = self.bits | other.bits };
    }

    pub fn has(self: CursorModes, other: CursorModes) bool {
        return (self.bits & other.bits) == other.bits;
    }

    pub fn supports(self: CursorModes, mode: CursorMode) bool {
        return self.has(switch (mode) {
            .embedded => embedded,
            .hidden => hidden,
            .metadata => metadata,
        });
    }
};

/// How long the provider keeps the session alive after the app stops asking
/// for frames. The values are the portal persistence levels.
pub const PersistenceMode = enum(u32) {
    /// Ends with the process.
    transient = 0,
    /// Ends when the last consumer disconnects.
    while_connected = 1,
    /// Ends only when the user or policy revokes it.
    until_revoked = 2,
};

/// Set of persistence levels a provider supports.
pub const PersistenceModes = struct {
    pub const none: PersistenceModes = .{ .bits = 0 };
    pub const transient: PersistenceModes = .{ .bits = 1 << 0 };
    pub const while_connected: PersistenceModes = .{ .bits = 1 << 1 };
    pub const until_revoked: PersistenceModes = .{ .bits = 1 << 2 };

    bits: u8 = 0,

    pub fn with(self: PersistenceModes, other: PersistenceModes) PersistenceModes {
        return .{ .bits = self.bits | other.bits };
    }

    pub fn has(self: PersistenceModes, other: PersistenceModes) bool {
        return (self.bits & other.bits) == other.bits;
    }

    pub fn supports(self: PersistenceModes, mode: PersistenceMode) bool {
        return self.has(switch (mode) {
            .transient => transient,
            .while_connected => while_connected,
            .until_revoked => until_revoked,
        });
    }
};

/// Luminance range of the delivered pixels.
pub const ColorRange = enum {
    unknown,
    /// The full 0 to 255 range.
    full,
    /// The studio 16 to 235 range.
    limited,
};

/// Lifecycle of a capture session. A session reaches at most one terminal
/// state. `canceled`, `denied`, `stopped` and `failed` are all final.
pub const SessionState = enum {
    /// Nothing has been requested yet.
    idle,
    /// The OS chooser is open and no answer has arrived.
    selecting,
    /// A source was chosen and the provider is building the stream.
    starting,
    /// Frames are being delivered.
    streaming,
    /// The chooser closed without a selection.
    canceled,
    /// The user or policy refused the request.
    denied,
    /// A started session ended on request.
    stopped,
    /// The provider or the platform failed. See `FailureReason`.
    failed,
};

/// True for the states a session never leaves.
pub fn isTerminal(state: SessionState) bool {
    return switch (state) {
        .canceled, .denied, .stopped, .failed => true,
        else => false,
    };
}

/// True for the states in which a provider may still be working.
pub fn isActive(state: SessionState) bool {
    return switch (state) {
        .selecting, .starting, .streaming => true,
        else => false,
    };
}

/// Why a session reached `SessionState.failed`.
pub const FailureReason = enum {
    none,
    /// No provider on this platform. Not an error the user can act on.
    unsupported,
    /// No D-Bus session address in the environment.
    no_session_bus,
    /// A session bus exists but the portal service does not answer.
    portal_unavailable,
    /// The portal refused the request outright.
    rejected,
    /// The provider, the stream or the session bus went away.
    disconnected,
    /// The provider reported an error of its own.
    provider_failed,
    /// A read, write or allocation step failed.
    io_failed,
    /// The provider negotiated a frame layout this build cannot describe.
    format_unsupported,
};

/// What a provider can do on this machine, right now.
pub const Capabilities = struct {
    available: bool = false,
    platform: Platform = .unknown,
    backend: BackendKind = .none,
    /// Source classes the OS can offer. On Wayland the concrete list of
    /// monitors and windows belongs to the portal chooser; an application
    /// must not pretend it can enumerate them.
    sources: SourceType = .none,
    cursor_modes: CursorModes = .none,
    persistence_modes: PersistenceModes = .none,
    /// The provider can hand back more than one stream per session.
    multiple_streams: bool = false,
    /// The OS will show a permission dialog on `begin`.
    requires_user_approval: bool = false,
    /// Why the backend is unavailable. Empty when it is available.
    unavailable_reason: []const u8 = "",
};

/// The negotiated stream, as reported by the provider.
///
/// A report is the whole truth: a provider sends the complete description every
/// time, so a consumer never has to guess whether an omitted field means "no"
/// or "the provider does not know". The epoch is the one field this facade
/// owns, because it is what tells a consumer to drop frames it decoded for an
/// earlier layout.
pub const StreamInfo = struct {
    /// PipeWire node the provider attached to. Zero until a stream exists, and
    /// zero on a platform that names no node.
    node_id: u32 = 0,
    /// Chosen source classes, meaningful only when `source_class_known` is
    /// true. Empty then means a source that belongs to no class, which is not
    /// the same as a platform that named no class.
    sources: SourceType = .none,
    /// False by default, because a description that says nothing about the
    /// chosen source is not evidence of one. A provider that knows the class
    /// sets this to true.
    source_class_known: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    position_x: i32 = 0,
    position_y: i32 = 0,
    format: PixelFormat = .bgra8,
    color_space: ColorSpace = .srgb,
    color_range: ColorRange = .unknown,
    /// Bumped on every negotiated format change. A consumer that caches
    /// decoded frames must drop them when this value moves.
    format_epoch: u32 = 0,
    /// Time between frames in nanoseconds, or zero when unknown.
    frame_interval_ns: u64 = 0,

    /// True once the provider has negotiated a usable size.
    pub fn isConfigured(self: StreamInfo) bool {
        return self.width != 0 and self.height != 0;
    }
};

/// What the app asks the provider to select.
pub const Request = struct {
    /// Source classes to offer in the chooser. The user picks the instance.
    sources: SourceType = .monitor,
    cursor_mode: CursorMode = .embedded,
    persistence: PersistenceMode = .transient,
    /// Offer more than one source in the chooser.
    multiple: bool = false,
    /// Restore token from an earlier session, when the platform allows reuse
    /// without a new prompt.
    restore_token: ?[]const u8 = null,
    /// XDG window handle of the owning toplevel, as an empty string when the
    /// platform cannot name one.
    parent_window: []const u8 = "",
};

/// Weak owner descriptor. A capture session outlives the frame that asked for
/// it, so every provider callback re-checks the owner first. A dead owner is
/// indistinguishable from a cleared context, and both mean "let go".
pub const WeakOwner = struct {
    context: ?*const anyopaque = null,
    is_alive_fn: ?*const fn (context: *const anyopaque) bool = null,

    pub fn isAlive(self: WeakOwner) bool {
        const ctx = self.context orelse return false;
        const check = self.is_alive_fn orelse return true;
        return check(ctx);
    }
};

/// Callbacks a provider uses to report progress to the facade.
pub const Sink = struct {
    ctx: *anyopaque,
    /// Hands one negotiated frame over. Ownership moves to the sink; a
    /// refused frame is released before this call returns.
    frame: *const fn (ctx: *anyopaque, frame: FrameDescriptor) void,
    /// Reports a new negotiated format. The report is the complete
    /// description, so a later one replaces the earlier one whole and a
    /// provider must not send a partial one to mean "the rest is unchanged".
    format: *const fn (ctx: *anyopaque, info: StreamInfo) void,
    /// Reports a lifecycle transition. The facade records the state.
    state: *const fn (ctx: *anyopaque, state: SessionState, failure: FailureReason) void,
};

/// The platform side of a session.
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Runs the platform handshake. It may block on a user decision and
        /// may show an OS dialog, so the caller must not hold session locks.
        /// The outcome arrives through `Sink.state`, not through this call.
        begin: *const fn (ctx: *anyopaque, request: Request) anyerror!void,
        /// Releases every platform resource. Must tolerate repeat calls.
        stop: *const fn (ctx: *anyopaque) void,
        /// Moves one frame out of the transport and publishes it, and returns
        /// how many it published. `timeout_ms` of 0 never blocks.
        ///
        /// Null for a provider that pushes frames from its own thread, which is
        /// the default, so such a backend is never asked to drive anything.
        /// Present only for a transport whose frames move when they are asked
        /// for; the session calls it while taking a frame.
        poll: ?*const fn (ctx: *anyopaque, timeout_ms: i32) anyerror!usize = null,
    };

    pub fn begin(self: Backend, request: Request) anyerror!void {
        return self.vtable.begin(self.ptr, request);
    }

    pub fn stop(self: Backend) void {
        self.vtable.stop(self.ptr);
    }

    /// Ask the transport for what it has, and return how many frames it
    /// published. `timeout_ms` of 0 never blocks. Zero when this backend
    /// publishes from its own thread, because there is nothing to drive.
    pub fn poll(self: Backend, timeout_ms: i32) anyerror!usize {
        const pump = self.vtable.poll orelse return 0;
        return pump(self.ptr, timeout_ms);
    }

    /// True when this backend only moves frames when it is driven, so a session
    /// that never polls it stays healthy-looking and delivers nothing.
    pub fn isPollDriven(self: Backend) bool {
        return self.vtable.poll != null;
    }
};

/// A capture session. The facade is the only place that decides whether a
/// frame may reach the renderer.
pub const Session = struct {
    pub const Error = error{
        /// `begin` was called outside `idle`.
        InvalidState,
        /// The weak owner is gone, so no session may be created.
        OwnerLost,
        /// No provider is attached.
        NoBackend,
        /// Frames were requested while no stream was running.
        NotStreaming,
        /// `deinit` was called while a consumer still holds an acquired frame.
        /// Nothing was freed: return the frame through `releaseFrame` or
        /// `presentFrame`, then call `deinit` again.
        FramesStillBorrowed,
    };

    gpa: std.mem.Allocator,
    state_value: SessionState = .idle,
    failure_value: FailureReason = .none,
    owner: WeakOwner = .{},
    frames: FrameSource,
    info: StreamInfo = .{},
    backend: ?Backend = null,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Set once the provider and the frames have been released.
    torn_down: bool = false,
    /// Set once the frame source itself has been freed.
    disposed: bool = false,
    /// Set by a terminal provider callback. The teardown itself belongs to
    /// the owner thread, because a provider may only be stopped from the
    /// thread that started it.
    teardown_pending: bool = false,

    /// `max_queue` is the number of unconsumed frames kept before the oldest
    /// is released. Video is only worth the newest frame, so the default is
    /// deliberately small.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, owner: WeakOwner, max_queue: usize) Session {
        return .{
            .gpa = gpa,
            .io = io,
            .owner = owner,
            .frames = FrameSource.init(gpa, io, max_queue),
        };
    }

    /// Attaches a provider. Call before `begin`. The session does not own the
    /// provider; its lifetime stays with the caller.
    pub fn attach(self: *Session, backend: Backend) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.backend = backend;
    }

    /// Forwards the W05 completion wake to the frame source, so a consumer
    /// blocked on the main thread is signalled when a frame lands.
    pub fn setWake(self: *Session, ctx: ?*anyopaque, callback: ?FrameSource.WakeCallback) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.frames.setWake(ctx, callback);
    }

    /// Starts a selection. Returns once the platform accepted the request.
    /// The answer itself arrives later through the sink, so poll `state()`.
    ///
    /// A refusal is recorded on the session as well as returned, so a caller
    /// that only polls the state still sees the reason. A request that cannot
    /// start a session at all, because there is no provider or no live owner,
    /// leaves the session `failed`. A request refused because a selection is
    /// already in flight keeps that live selection, and a request refused
    /// after a terminal outcome keeps that outcome: both already say something
    /// truer than a second failure would.
    pub fn begin(self: *Session, request: Request) anyerror!void {
        self.mutex.lockUncancelable(self.io);
        if (!self.owner.isAlive()) {
            self.failLocked(.disconnected);
            self.mutex.unlock(self.io);
            return error.OwnerLost;
        }
        if (self.state_value != .idle) {
            self.mutex.unlock(self.io);
            return error.InvalidState;
        }
        const backend = self.backend orelse {
            self.failLocked(.unsupported);
            self.mutex.unlock(self.io);
            return error.NoBackend;
        };
        self.state_value = .selecting;
        self.failure_value = .none;
        self.mutex.unlock(self.io);

        backend.begin(request) catch |err| {
            self.mutex.lockUncancelable(self.io);
            if (self.state_value == .selecting) self.failLocked(classifyFailure(err));
            self.mutex.unlock(self.io);
            return err;
        };
    }

    pub fn state(self: *Session) SessionState {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state_value;
    }

    pub fn failure(self: *Session) FailureReason {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.failure_value;
    }

    pub fn streamInfo(self: *Session) StreamInfo {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.info;
    }

    pub fn isStreaming(self: *Session) bool {
        return self.state() == .streaming;
    }

    /// The sink a provider reports through.
    pub fn sink(self: *Session) Sink {
        return .{
            .ctx = self,
            .frame = sinkFrame,
            .format = sinkFormat,
            .state = sinkState,
        };
    }

    /// Takes the newest unconsumed frame, or null when none is ready.
    ///
    /// A backend whose transport only moves when it is asked is driven here
    /// first, so a host that attaches, begins and acquires reaches a real
    /// frame without knowing which kind of backend it has. Frames that arrived
    /// in a state that cannot deliver are released here rather than handed out.
    pub fn acquireLatest(self: *Session) ?FrameDescriptor {
        self.mutex.lockUncancelable(self.io);
        const was_active = isActive(self.state_value);
        const backend = self.backend;
        self.mutex.unlock(self.io);

        // The lock is not held across the drive: the backend reports every
        // frame, every format and every state through the sink, and each of
        // those takes this lock again.
        if (backend) |b| {
            if (was_active) self.drive(b);
        }

        // Read again, because driving the transport is the one thing here that
        // can end the session: a frame queued a moment ago was deliverable, and
        // one queued after a failure is not.
        self.mutex.lockUncancelable(self.io);
        const current = self.state_value;
        self.mutex.unlock(self.io);

        const frame = self.frames.acquireLatest() orelse return null;
        if (current != .streaming) {
            var mut_frame = frame;
            self.frames.releaseFrame(&mut_frame);
            return null;
        }
        return frame;
    }

    /// Drive a transport that hands frames over only when asked.
    ///
    /// A transport that fails is recorded through the same path a provider
    /// report takes, so `state` and `failure` say the stream ended and why, and
    /// `stop` still owns the teardown. A black screen behind a session that
    /// reports itself healthy is the failure this exists to prevent.
    fn drive(self: *Session, backend: Backend) void {
        _ = backend.poll(0) catch |err| {
            self.terminateWith(.failed, classifyFailure(err));
            return;
        };
    }

    /// Returns an acquired frame to the session without presenting it. A
    /// consumer MUST use this rather than `frame.release()` for anything it
    /// got from `acquireLatest`, so the source keeps an honest count of the
    /// frames it is still waiting for.
    pub fn releaseFrame(self: *Session, frame: *FrameDescriptor) void {
        self.frames.releaseFrame(frame);
    }

    /// Frames a consumer acquired and has not returned yet. A nonzero count
    /// at teardown means a release callback can still run later.
    pub fn outstandingFrames(self: *Session) u32 {
        return self.frames.outstandingFrames();
    }

    /// Hands the newest frame to the renderer, releasing the previous one only
    /// after the new frame is in place.
    pub fn presentFrame(self: *Session, frame: FrameDescriptor) void {
        self.frames.presentFrame(frame);
    }

    pub fn activeFrame(self: *Session) ?FrameDescriptor {
        return self.frames.getActiveFrame();
    }

    /// Ends the session and releases every retained frame. A session that
    /// already failed, was denied or was canceled keeps that outcome, because
    /// it is the more useful one to report. Safe to call more than once.
    /// Returns the frames a consumer still holds, which must reach zero
    /// before `deinit`.
    ///
    /// Call this from the owner thread. A terminal provider callback only
    /// records `needsTeardown`; it never stops the provider, because a
    /// provider may not be torn down from its own callback thread.
    pub fn stop(self: *Session) u32 {
        self.mutex.lockUncancelable(self.io);
        const backend = self.backend;
        // A terminal outcome still owns a provider and may still own frames,
        // so anything that left `idle` has to be torn down.
        const teardown = self.state_value != .idle and !self.torn_down;
        if (teardown) self.torn_down = true;
        if (teardown) self.teardown_pending = false;
        if (teardown and isActive(self.state_value)) self.state_value = .stopped;
        self.mutex.unlock(self.io);

        if (!teardown) return self.frames.outstandingFrames();
        // Frames first: releasing a frame hands a buffer back to the provider,
        // so the provider must outlive every frame it produced.
        const outstanding = self.frames.stop();
        if (backend) |b| b.stop();
        return outstanding;
    }

    /// True when a provider reported a terminal outcome and the owner thread
    /// still has to call `stop`. A host polls this once per frame.
    pub fn needsTeardown(self: *Session) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.teardown_pending;
    }

    /// Stops the session when the weak owner has gone, or when a provider
    /// already reported a terminal outcome. Call once per frame; it is the
    /// last line of defence against a window that closed while its capture
    /// session was still running.
    pub fn enforceOwnerLifetime(self: *Session) void {
        if (self.owner.isAlive()) {
            if (self.needsTeardown()) _ = self.stop();
            return;
        }
        self.mutex.lockUncancelable(self.io);
        const orphan = isActive(self.state_value) or self.teardown_pending;
        self.mutex.unlock(self.io);
        if (orphan) _ = self.stop();
    }

    /// Releases the session. Tolerates a repeated call while the previous one
    /// refused; once it succeeds the session is gone, so a caller that defers
    /// it must not also call it explicitly.
    /// Refuses while a consumer still holds an acquired frame. That frame's
    /// return path walks this session's queue and the provider behind it, so
    /// the session stays alive and intact: return the frame, then call
    /// `deinit` again. The refusal is an error rather than an assert because an
    /// assert is compiled out of a ReleaseFast build, and there the late
    /// release would run against a destroyed session.
    ///
    /// Call this from the owner thread, like `stop`.
    pub fn deinit(self: *Session) Error!void {
        const borrowed = self.stop();
        if (borrowed != 0) {
            // A borrowed frame returns through this session's queue, so a
            // refusal leaves the session intact for the second call.
            return error.FramesStillBorrowed;
        }
        self.mutex.lockUncancelable(self.io);
        const disposed = self.disposed;
        self.disposed = true;
        self.mutex.unlock(self.io);
        if (!disposed) {
            // `stop` just reported no borrowed frame, and a stopped source
            // hands out nothing new, so this cannot refuse.
            try self.frames.deinit();
            self.backend = null;
        }
        // The poison is registered after both refusals are behind the call,
        // because each one has to leave the session whole for the retry.
        defer self.* = undefined;
    }

    fn sinkFrame(ctx: *anyopaque, frame: FrameDescriptor) void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        const accepted = self.state_value == .streaming and self.owner.isAlive();
        self.mutex.unlock(self.io);

        if (!accepted) {
            var mut_frame = frame;
            mut_frame.release();
            return;
        }
        // A refused push releases the frame itself, so nothing leaks here.
        // `error.SourceStopped` is the teardown race and `error.OutOfMemory`
        // is the queue refusing to grow: both mean drop this frame.
        self.frames.pushFrame(frame) catch {
            return;
        };
    }

    fn sinkFormat(ctx: *anyopaque, info: StreamInfo) void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        const changed = info.format != self.info.format or
            info.width != self.info.width or
            info.height != self.info.height;

        // The report is the whole negotiated state, so only the epoch is owned
        // here. A repeated report of the same layout keeps it, so a consumer
        // that caches decoded frames is not told to drop them for nothing, and
        // a changed layout moves it forward even when a provider restarted its
        // own count at one.
        var next = info;
        next.format_epoch = if (changed)
            @max(info.format_epoch, self.info.format_epoch +| 1)
        else
            self.info.format_epoch;
        self.info = next;
        self.mutex.unlock(self.io);

        // Frames from the old layout would decode into the wrong buffer, so
        // they go now. The frame the consumer is presenting stays alive until
        // the consumer replaces it.
        if (changed) self.drainPending();
    }

    fn sinkState(ctx: *anyopaque, next: SessionState, reason: FailureReason) void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        switch (next) {
            .idle => {},
            .selecting, .starting, .streaming => {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                if (!isTerminal(self.state_value)) self.state_value = next;
            },
            .canceled, .denied, .stopped, .failed => self.terminateWith(next, reason),
        }
    }

    /// Record a terminal state and its reason, the way a provider report does.
    ///
    /// A transport error that reaches the session through its own drive lands
    /// here too, so a caller polling `failure` reads one answer whoever
    /// reported it, and the teardown still belongs to the owner thread: this
    /// only raises the flag the owner polls.
    fn terminateWith(self: *Session, next: SessionState, reason: FailureReason) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (isTerminal(self.state_value)) return;
        self.state_value = next;
        self.failure_value = reason;
        // A provider reports this from its own callback thread. Tearing the
        // provider down there would stop a transport from the thread that
        // drives it, so the owner thread does it instead; the flag is what it
        // polls.
        if (!self.torn_down) self.teardown_pending = true;
    }

    /// Releases every queued frame without closing the session.
    fn drainPending(self: *Session) void {
        while (self.frames.acquireLatest()) |frame| {
            var mut_frame = frame;
            self.frames.releaseFrame(&mut_frame);
        }
    }

    /// Records a terminal failure. Every path that calls it has nothing
    /// running, so there is no provider to tear down and no teardown to defer.
    fn failLocked(self: *Session, reason: FailureReason) void {
        self.state_value = .failed;
        self.failure_value = reason;
    }
};

/// The reason a provider error records. This is the one mapping in the tree:
/// the platform providers and this facade all call it, so a caller that polls
/// `Session.failure` gets the same answer whoever reported the error.
///
/// The names are the ones the shipped providers and their transports actually
/// return. An explicit native outcome always wins over a transport failure: a
/// chooser the user closed is not a failure, and one the user refused is a
/// rejection, whatever else the handshake reported on its way out.
pub fn classifyFailure(err: anyerror) FailureReason {
    return switch (err) {
        error.CaptureCanceled => .none,
        error.CaptureDenied, error.MultipleStreamsUnsupported => .rejected,
        // A request this build, or this platform, will not make at all.
        error.CaptureUnsupported,
        error.UnsupportedSources,
        error.UnsupportedPersistence,
        error.UnsupportedCursorMode,
        error.RestoreTokenUnsupported,
        => .unsupported,
        // No session bus in the environment, so nothing was ever asked.
        error.NoSessionBus => .no_session_bus,
        // The bus answered but the portal did not, or answered with a reply
        // this client cannot use.
        error.PortalUnavailable,
        error.PortalCallFailed,
        error.InvalidReply,
        error.NoFileDescriptor,
        => .portal_unavailable,
        // The transport went away: the bus closed, the connection was never
        // there, or the PipeWire daemon could not be reached.
        error.StreamDisconnected,
        error.ConnectionClosed,
        error.NotConnected,
        error.ReadFailed,
        error.WriteFailed,
        error.PipeWireMissing,
        error.PipeWireIncomplete,
        error.StreamConnectFailed,
        error.OwnerLost,
        => .disconnected,
        // A layout this build cannot describe as a frame.
        error.FormatUnsupported => .format_unsupported,
        // A reply that named no usable stream, a parent window this platform
        // cannot use, and a frame a consumer still holds: all of them are
        // refusals by this client rather than by the platform.
        error.PortalNoStream,
        error.PortalInvalidReply,
        error.CaptureFailed,
        error.MalformedParentWindow,
        error.FramesStillBorrowed,
        => .provider_failed,
        error.OutOfMemory => .io_failed,
        else => .provider_failed,
    };
}
