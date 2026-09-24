//! Windows screen capture provider: Windows.Graphics.Capture, delivering owned
//! CPU frame descriptors.
//!
//! The path is the platform's own and it is the only honest one on Windows. A
//! `BitBlt` or a DXGI desktop duplication grab would produce pixels without
//! asking, and would be a second capture API rather than an adapter for this one;
//! the platform's capture picker is where the user consent decision is made, and
//! an adapter that routes around it is not implementing capture, it is
//! implementing surveillance. So the picker is the only way this provider
//! obtains a target.
//!
//! **Selection semantics.** `capture.Request` says which *classes* of source
//! the chooser should offer. Windows does not take a class mask, so this adapter
//! does the narrowing itself and refuses a request it cannot honour:
//!
//!   * `sources` must be a subset of what the picker offers, which is monitors
//!     and windows. A request naming only `virtual` sources is refused by name
//!     rather than answered with a monitor the user did not ask for.
//!   * `multiple = true` is refused. The picker's single-target operation is the
//!     only one this provider waits on, and reporting one stream from a multi
//!     request would drop the user's other choices silently.
//!   * `cursor_mode` is not a parameter the platform takes. The OS picker owns
//!     the cursor decision, so the provider reports `embedded` -- the picker's
//!     own default -- and claims no mode it cannot select.
//!   * `persistence` has no WGC counterpart. A WGC session ends with the
//!     process, so only `transient` and `while_connected` are reported, and
//!     `until_revoked` is refused rather than answered with a session that
//!     outlives nothing.
//!   * `restore_token` is refused. A token means "resume the session the user
//!     approved earlier without asking again", and Windows has no such path
//!     through the picker: every item comes from a fresh user decision. Accepting
//!     the field and showing the picker anyway would tell the caller its approval
//!     was reused when nothing was reused.
//!
//! **What the OS does not say.** Windows does not report which instance of a
//! source class the user picked. `StreamInfo.source_class_known` is false and
//! `StreamInfo.sources` is empty. The concrete list of monitors and windows
//! belongs to the picker, which an application must
//! not pretend to enumerate. A PipeWire node id, a source position and a frame
//! interval have no Windows counterpart either, and are reported as the zero the
//! contract defines for "unknown": `node_id = 0`, `position_x = position_y = 0`,
//! `frame_interval_ns = 0`, `color_range = .unknown`.
//!
//! **Format changes are real changes.** A captured window or monitor can change
//! size while the stream runs, and the pool then delivers a different surface
//! size. The provider bumps `format_epoch` on every negotiated layout change, so
//! a consumer that caches decoded frames drops them when the epoch moves, and
//! publishes the layout only when it changed rather than once per frame.
//!
//! **Frames are owned.** Every published frame is a CPU copy the provider owns
//! through a heap-stable record, and `release_fn` hands it back to the shim,
//! which wipes the pixels and frees the buffer. A frame the consumer still holds
//! is a live record. `deinit` refuses until every borrowed frame is returned.
//!
//! **One platform context per provider.** The shim's session, frame pool and
//! staging texture live in a context this provider owns, opened once and closed
//! with the provider. Two providers in one process therefore cannot end each
//! other's capture, which a single process-wide session would.
//!
//! No second renderer and no second scheduler. Frames arrive on the host's own
//! thread through `poll`, which the host calls from the loop it already runs.
const std = @import("std");
const win = @import("win32.zig");
const capture = @import("../capture.zig");

const Backend = capture.Backend;
const Capabilities = capture.Capabilities;
const FrameDescriptor = capture.FrameDescriptor;
const Request = capture.Request;
const SessionState = capture.SessionState;
const Sink = capture.Sink;
const SourceType = capture.SourceType;
const StreamInfo = capture.StreamInfo;

/// Narrow C ABI of `native/nogui_capture.cpp`, which is where the WinRT, D3D11
/// and picker calls live.
pub const CaptureStatus = enum(c_int) {
    ok = 0,
    canceled = 1,
    denied = 2,
    unavailable = 3,
    failed = 4,
    timeout = 5,
    bad_format = 6,
};

/// The D3D11 driver the platform gave the capture device.
pub const Driver = enum(c_int) {
    unknown = 0,
    hardware = 1,
    warp = 2,
};

pub const RawFrame = extern struct {
    data: ?[*]u8,
    width: u32,
    height: u32,
    stride: u32,
    /// 0 is BGRA8, 1 is RGBA8.
    format: u32,
    timestamp_ns: u64,
    owner: ?*anyopaque,
};

/// One capture session's platform objects, owned by the shim.
pub const Context = opaque {};

pub extern fn nogui_capture_supported() callconv(.c) c_int;
pub extern fn nogui_capture_open(out: *?*Context) callconv(.c) CaptureStatus;
pub extern fn nogui_capture_driver_of(cap: *const Context) callconv(.c) Driver;
pub extern fn nogui_capture_driver_name(cap: *const Context) callconv(.c) [*:0]const u8;
pub extern fn nogui_capture_close(cap: *Context) callconv(.c) void;
pub extern fn nogui_capture_picker_show(cap: *Context, hwnd: ?*anyopaque) callconv(.c) CaptureStatus;
pub extern fn nogui_capture_picker_poll(cap: *Context, out_item: *?*anyopaque) callconv(.c) CaptureStatus;
pub extern fn nogui_capture_picker_wait(
    cap: *Context,
    timeout_ms: c_int,
    out: *?*anyopaque,
) callconv(.c) CaptureStatus;
pub extern fn nogui_capture_item_destroy(item: ?*anyopaque) callconv(.c) void;
pub extern fn nogui_capture_start(cap: *Context, item: ?*anyopaque, width: u32, height: u32) callconv(.c) CaptureStatus;
pub extern fn nogui_capture_stop(cap: *Context) callconv(.c) void;
pub extern fn nogui_capture_next_frame(cap: *Context, out: *RawFrame, timeout_ms: c_int) callconv(.c) CaptureStatus;
pub extern fn nogui_capture_frame_release(frame: *RawFrame) callconv(.c) void;
pub extern fn nogui_capture_last_hresult(cap: *const Context) callconv(.c) c_long;

/// The provider's own errors, before any platform call.
pub const Error = error{
    /// The request named source classes the Windows picker does not offer.
    UnsupportedSources,
    /// The request asked for several streams and this provider delivers one.
    MultipleStreamsUnsupported,
    /// The request asked for a persistence level a WGC session does not have.
    UnsupportedPersistence,
    /// The request named a cursor mode this adapter cannot select, because the
    /// OS picker owns that decision.
    UnsupportedCursorMode,
    /// The request asked to resume an earlier session, which the picker cannot
    /// do without asking the user again.
    RestoreTokenUnsupported,
    /// `parent_window` was not a `win32:0x...` handle.
    MalformedParentWindow,
    /// The platform has no capture path on this machine, or the thread this
    /// provider runs on is in an apartment the picker cannot be waited on from.
    CaptureUnsupported,
} || std.mem.Allocator.Error;

/// One published frame, at a stable address.
///
/// A consumer's release returns the buffer into this record, so the record cannot
/// move and cannot be freed while a frame is outstanding. That is why it is
/// heap-allocated rather than a field.
const OwnedFrame = struct {
    raw: RawFrame,
    /// The provider that published this frame. Valid until the release, which
    /// the provider's own teardown refusal guarantees: `deinit` refuses while a
    /// frame is still outstanding, so a record that reaches its release always
    /// has a live provider to decrement.
    provider: *Provider,
    /// The allocator that made this record, kept inside the record because the
    /// release is a C callback that carries this pointer and nothing else.
    gpa: std.mem.Allocator,

    /// Take ownership of one frame the shim produced, and count it.
    ///
    /// A record that has been counted is one the provider owes a destruction
    /// for, so `outstanding` rises before the record is reachable and falls
    /// again inside `release`.
    fn publish(provider: *Provider, raw: RawFrame) std.mem.Allocator.Error!*OwnedFrame {
        const self = try provider.gpa.create(OwnedFrame);
        self.* = .{ .raw = raw, .provider = provider, .gpa = provider.gpa };
        provider.outstanding += 1;
        return self;
    }

    fn release(ctx: ?*anyopaque) void {
        const self: *OwnedFrame = @ptrCast(@alignCast(ctx orelse return));
        // The shim wipes the pixels and frees the buffer. The order inside is the
        // shim's, and only a build that has the shim has a buffer to hand back.
        if (comptime win.is_windows) nogui_capture_frame_release(&self.raw);
        self.raw = std.mem.zeroes(RawFrame);
        self.provider.outstanding -= 1;
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

/// The negotiated layout, as the shim last reported it. A different layout means
/// the source resized and the consumer's cached frames are stale.
const Layout = struct {
    width: u32 = 0,
    height: u32 = 0,
    format: u32 = 0,

    fn eql(self: Layout, other: Layout) bool {
        return self.width == other.width and self.height == other.height and
            self.format == other.format;
    }
};

/// `sources` is what the chooser offers, not what this build enumerates. The
/// concrete list of monitors and windows belongs to the picker, and an
/// application must not pretend it can enumerate them -- which is exactly what
/// the shared contract says about the same field on every platform.
pub fn capabilities() Capabilities {
    if (comptime !win.is_windows) {
        return .{
            .platform = .unknown,
            .unavailable_reason = "Windows.Graphics.Capture is not present on this target",
        };
    }
    if (nogui_capture_supported() == 0) {
        return .{
            .platform = .windows,
            .unavailable_reason = "Windows.Graphics.Capture reports capture is not supported here",
        };
    }
    return .{
        .available = true,
        .platform = .windows,
        .backend = .graphics_capture,
        // The picker can offer a monitor or an application window, and nothing
        // else, so this is the honest answer to "which source classes can this
        // machine offer".
        .sources = SourceType.monitor.with(.window),
        // The picker draws the cursor into the frames by default and the OS owns
        // the decision, so `embedded` is what this adapter observes and no other
        // mode is claimed.
        .cursor_modes = capture.CursorModes.embedded,
        // A WGC session ends with the process. `until_revoked` describes a
        // policy-persistent session the platform does not offer.
        .persistence_modes = capture.PersistenceModes.transient.with(.while_connected),
        .multiple_streams = false,
        .requires_user_approval = true,
    };
}

/// True when this build can capture at all. A build that cannot is a build with
/// no platform to ask, which is different from a machine whose capture the user
/// has not approved yet.
pub fn isApplicable() bool {
    return comptime win.is_windows;
}

/// Refuse a request this provider cannot honour, by name.
///
/// Every refusal here is a request the platform would silently answer with
/// something else. A `virtual` source would become a monitor, `multiple` would
/// become one of the user's several choices, `until_revoked` would become a
/// session that dies with the process, a hidden cursor mode would become whatever
/// the picker defaulted to, and a restore token would become a brand new consent
/// prompt the caller believes it did not need. Each of those is a caller that
/// believes it got what it asked for.
pub fn validate(request: Request) Error!void {
    // `has` asks whether the receiver covers the argument, so it is the
    // offerable set that has to hold the request. Asked the other way round it
    // would refuse every request naming fewer sources than the picker offers,
    // and report the caller's own monitor bit as a source class this platform
    // does not have.
    const offerable = SourceType.monitor.with(.window);
    if (!request.sources.isEmpty() and !offerable.has(request.sources)) {
        return error.UnsupportedSources;
    }
    if (request.multiple) return error.MultipleStreamsUnsupported;
    if (!capture.PersistenceModes.transient
        .with(.while_connected)
        .supports(request.persistence))
    {
        return error.UnsupportedPersistence;
    }
    if (request.cursor_mode != .embedded) return error.UnsupportedCursorMode;
    if (request.restore_token) |token| {
        if (token.len != 0) return error.RestoreTokenUnsupported;
    }
}

/// Decode a `win32:0x...` parent handle.
///
/// The shared `Request.parent_window` is a string, and the X11 adapter's format
/// for it is an X11 window in hexadecimal. This is the Windows spelling of the
/// same idea, so a host passes one string in both cases. The handle itself must
/// come from an SDL window property and never from a graphics handle; see
/// `window_interop.zig`.
pub fn parseParentWindow(text: []const u8) Error!win.Hwnd {
    const prefix = "win32:0x";
    if (!std.mem.startsWith(u8, text, prefix)) return error.MalformedParentWindow;
    const value = std.fmt.parseInt(usize, text[prefix.len..], 16) catch
        return error.MalformedParentWindow;
    if (value == 0) return error.MalformedParentWindow;
    return @ptrFromInt(value);
}

/// One capture session driven by the platform picker and frame pool.
pub const Provider = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    sink: Sink,
    /// Re-checked before every frame, so a window that closed while its capture
    /// was running stops the stream instead of feeding a dead model.
    owner: capture.WeakOwner,
    /// The platform objects for this provider alone. Opened with the provider and
    /// closed with it, so one provider cannot end another's stream.
    ctx: ?*Context = null,
    item: ?*anyopaque = null,
    is_streaming: bool = false,
    stop_requested: bool = false,
    /// The layout the stream was last negotiated with, and the epoch it carries.
    layout: Layout = .{},
    epoch: u32 = 0,
    /// Frames handed to the sink and not yet released. Destruction refuses
    /// while a release callback can still reach this provider.
    outstanding: u32 = 0,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        sink: Sink,
        owner: capture.WeakOwner,
    ) Provider {
        return .{ .gpa = gpa, .io = io, .sink = sink, .owner = owner };
    }

    /// Release the provider and the platform objects it opened.
    ///
    /// A consumer release hands the buffer back into a record this provider
    /// allocated, so a frame that is still outstanding means that record is
    /// still live. The teardown refuses with `error.FramesStillBorrowed` and
    /// leaves the provider whole, so the frames can be returned and the
    /// teardown retried; freeing a record a release callback still points at
    /// would turn a consumer that released late into a write into freed memory.
    pub fn deinit(self: *Provider) error{FramesStillBorrowed}!void {
        self.stop();
        if (self.outstanding != 0) {
            // A borrowed frame returns through this provider, so a refusal
            // leaves the provider whole for the second call.
            return error.FramesStillBorrowed;
        }
        // The poison is registered once the refusal is behind the call, so
        // every path that reaches the close leaves the provider dead behind it.
        defer self.* = undefined;
        if (comptime win.is_windows) {
            if (self.ctx) |ctx| nogui_capture_close(ctx);
        }
    }

    pub fn backend(self: *Provider) Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Backend.VTable = .{
        .begin = beginImpl,
        .stop = stopImpl,
        // The frame pool hands a frame over when it is asked, and there is no
        // producer thread behind it, so this provider is driven by the session
        // rather than pushing from one of its own.
        .poll = pollImpl,
    };

    /// The D3D11 driver the platform gave this session's capture device.
    ///
    /// Declared rather than assumed, because a machine with no usable hardware
    /// adapter still captures on the software rasterizer, and a host that reports
    /// "hardware" for a software capture is reporting something false.
    pub fn driver(self: *Provider) Driver {
        if (comptime !win.is_windows) return .unknown;
        const ctx = self.ctx orelse return .unknown;
        return nogui_capture_driver_of(ctx);
    }

    /// Report one terminal answer, with the shared mapping naming the reason.
    ///
    /// There is one mapping from an error to a `FailureReason` in the tree and
    /// this adapter calls it rather than writing a reason of its own, so a
    /// caller polling `Session.failure` reads the same answer whoever reported
    /// it. A non-terminal transition has no error to classify and says `.none`.
    fn report(self: *Provider, next: SessionState, err: anyerror) void {
        self.sink.state(self.sink.ctx, next, capture.classifyFailure(err));
    }

    fn beginImpl(ctx: *anyopaque, request: Request) anyerror!void {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        // Every refusal in `begin` is classified and reported through the sink
        // before it returns, so the vtable does not report it a second time.
        return self.begin(request);
    }

    fn stopImpl(ctx: *anyopaque) void {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        self.stop();
    }

    fn pollImpl(ctx: *anyopaque, timeout_ms: i32) anyerror!usize {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        return self.poll(timeout_ms);
    }

    /// Runs the whole handshake.
    ///
    /// It blocks while the OS picker is open, which is why the shared session calls
    /// it without holding any lock, and the answer arrives through the sink rather
    /// than through the return value.
    pub fn begin(self: *Provider, request: Request) !void {
        if (comptime !win.is_windows) {
            self.report(.failed, error.CaptureUnsupported);
            return error.CaptureUnsupported;
        }
        const caps = capabilities();
        if (!caps.available) {
            self.report(.failed, error.CaptureUnsupported);
            return error.CaptureUnsupported;
        }
        validate(request) catch |err| {
            self.report(.failed, err);
            return err;
        };
        if (!self.owner.isAlive()) {
            // A dead owner gets no picker. Showing a consent dialog for a model
            // that can no longer act on the answer would strand the user.
            self.report(.failed, error.OwnerLost);
            return error.OwnerLost;
        }

        // A second selection replaces the first, so the previous session is
        // released before a new one takes its place.
        self.releaseItem();
        self.stop_requested = false;
        self.layout = .{};
        self.epoch = 0;

        if (self.ctx == null) {
            var opened: ?*Context = null;
            switch (nogui_capture_open(&opened)) {
                .ok => {},
                .unavailable => {
                    self.report(.failed, error.CaptureUnsupported);
                    return error.CaptureUnsupported;
                },
                else => {
                    self.report(.failed, error.CaptureFailed);
                    return error.CaptureFailed;
                },
            }
            self.ctx = opened;
        }
        const ctx = self.ctx.?;
        // A session left over from a previous selection is released before the new
        // consent step, so the old item is not still streaming behind the dialog.
        nogui_capture_stop(ctx);

        var parent: ?win.Hwnd = null;
        if (request.parent_window.len != 0) {
            // A parent handle this platform cannot use is a refusal by this
            // client, and it is reported before it is returned so the sink sees
            // every reason the handshake gave up.
            parent = parseParentWindow(request.parent_window) catch |err| {
                self.report(.failed, err);
                return err;
            };
        }

        self.sink.state(self.sink.ctx, .selecting, .none);
        switch (nogui_capture_picker_show(ctx, parent)) {
            .ok => {},
            .denied => {
                self.report(.denied, error.CaptureDenied);
                return error.CaptureDenied;
            },
            .canceled => {
                self.report(.canceled, error.CaptureCanceled);
                return error.CaptureCanceled;
            },
            .unavailable => {
                self.report(.failed, error.CaptureUnsupported);
                return error.CaptureUnsupported;
            },
            else => {
                self.report(.failed, error.CaptureFailed);
                return error.CaptureFailed;
            },
        }

        var item: ?*anyopaque = null;
        switch (nogui_capture_picker_wait(ctx, -1, &item)) {
            .ok => {},
            .timeout => {
                // The wait has no timeout, so this is the platform reporting a
                // wait it could not finish rather than a user who gave up.
                self.report(.failed, error.CaptureFailed);
                return error.CaptureFailed;
            },
            .canceled => {
                self.report(.canceled, error.CaptureCanceled);
                return error.CaptureCanceled;
            },
            .denied => {
                self.report(.denied, error.CaptureDenied);
                return error.CaptureDenied;
            },
            .unavailable => {
                self.report(.failed, error.CaptureUnsupported);
                return error.CaptureUnsupported;
            },
            else => {
                self.report(.failed, error.CaptureFailed);
                return error.CaptureFailed;
            },
        }
        const chosen = item orelse {
            // The operation completed without a result, which is not a
            // cancellation the user made and must not be reported as one.
            self.report(.failed, error.CaptureFailed);
            return error.CaptureFailed;
        };
        self.item = chosen;

        self.sink.state(self.sink.ctx, .starting, .none);
        switch (nogui_capture_start(ctx, chosen, 0, 0)) {
            .ok => {},
            .denied => {
                self.releaseItem();
                self.report(.denied, error.CaptureDenied);
                return error.CaptureDenied;
            },
            .canceled => {
                self.releaseItem();
                self.report(.canceled, error.CaptureCanceled);
                return error.CaptureCanceled;
            },
            .unavailable => {
                self.releaseItem();
                self.report(.failed, error.CaptureUnsupported);
                return error.CaptureUnsupported;
            },
            else => {
                self.releaseItem();
                self.report(.failed, error.CaptureFailed);
                return error.CaptureFailed;
            },
        }
        self.is_streaming = true;
        self.sink.state(self.sink.ctx, .streaming, .none);
    }

    /// Take the next available frame and publish it.
    ///
    /// Returns the number of frames published, which is zero for a timeout and
    /// for a moment with nothing ready. A terminal platform answer is reported
    /// through the sink exactly once and the stream stops, so a session the user
    /// revoked does not keep asking.
    ///
    /// Nobody calls this by hand: the shared session drives it through
    /// `Backend` while a consumer takes a frame, which is what makes the
    /// documented flow -- attach, begin, acquire -- deliver on a platform with
    /// no producer thread. It stays public for a host that wants a frame on a
    /// schedule of its own.
    pub fn poll(self: *Provider, timeout_ms: i32) usize {
        if (comptime !win.is_windows) return 0;
        if (!self.is_streaming or self.stop_requested) return 0;
        const ctx = self.ctx orelse return 0;
        if (!self.owner.isAlive()) {
            // The owner is gone, so no frame may reach a model that can no longer
            // act on it. The shared session also enforces this; both checks exist
            // because a frame published between the two would already be a delivery
            // to a dead owner.
            self.report(.stopped, error.OwnerLost);
            self.is_streaming = false;
            return 0;
        }

        var raw: RawFrame = std.mem.zeroes(RawFrame);
        switch (nogui_capture_next_frame(ctx, &raw, timeout_ms)) {
            .ok => {},
            // A timeout is the ordinary case between frames and is not a state
            // change, so it says nothing through the sink.
            .timeout => return 0,
            .unavailable => {
                // The item was invalidated: a display change or a policy change
                // ended the stream. That is a disconnect, which is what the
                // contract calls a stream that went away on its own.
                nogui_capture_frame_release(&raw);
                self.is_streaming = false;
                self.report(.failed, error.StreamDisconnected);
                return 0;
            },
            .bad_format => {
                nogui_capture_frame_release(&raw);
                self.is_streaming = false;
                self.report(.failed, error.FormatUnsupported);
                return 0;
            },
            else => {
                nogui_capture_frame_release(&raw);
                self.is_streaming = false;
                self.report(.failed, error.CaptureFailed);
                return 0;
            },
        }

        const data = raw.data orelse {
            nogui_capture_frame_release(&raw);
            return 0;
        };
        if (raw.width == 0 or raw.height == 0 or raw.stride == 0) {
            nogui_capture_frame_release(&raw);
            return 0;
        }

        // Heap-stable, because a consumer release hands the buffer back into this
        // record and a record that moved would leave the release writing into
        // freed memory.
        const owned = OwnedFrame.publish(self, raw) catch {
            nogui_capture_frame_release(&raw);
            return 0;
        };

        const format: capture.PixelFormat = if (raw.format == 1) .rgba8 else .bgra8;
        self.publishLayout(raw, format);

        var frame: FrameDescriptor = .{
            .width = raw.width,
            .height = raw.height,
            .format = format,
            .color_space = .srgb,
            .alpha_type = .fully_opaque,
            .stride = raw.stride,
            .presentation_timestamp_ns = @intCast(raw.timestamp_ns),
            .plane_count = 1,
            .pixels = data,
            .release_fn = OwnedFrame.release,
            .release_ctx = owned,
        };
        frame.planes[0] = .{
            .offset = 0,
            .stride = raw.stride,
            .width = raw.width,
            .height = raw.height,
            .size = @as(usize, raw.stride) * raw.height,
        };
        self.sink.frame(self.sink.ctx, frame);
        return 1;
    }

    /// Report the negotiated layout when it changed, and remember it.
    ///
    /// Windows does not name the source, so `node_id`, the source position and the
    /// frame interval are the zero the contract defines for unknown, `sources` is
    /// the empty set because the picker does not report a class, and
    /// `color_range` is `.unknown` because the platform never says. The epoch moves
    /// on a real layout change, which is what tells a consumer to drop frames it
    /// decoded for the previous size.
    fn publishLayout(self: *Provider, raw: RawFrame, format: capture.PixelFormat) void {
        const current: Layout = .{
            .width = raw.width,
            .height = raw.height,
            .format = raw.format,
        };
        if (self.layout.eql(current) and self.epoch != 0) return;
        self.layout = current;
        self.epoch +%= 1;
        self.sink.format(self.sink.ctx, .{
            .node_id = 0,
            .sources = SourceType.none,
            .source_class_known = false,
            .width = raw.width,
            .height = raw.height,
            .position_x = 0,
            .position_y = 0,
            .format = format,
            .color_range = .unknown,
            .format_epoch = self.epoch,
            .frame_interval_ns = 0,
        });
    }

    /// Frames handed out and not yet released. Nonzero at teardown is a frame
    /// the consumer still holds, and `deinit` refuses on it rather than
    /// sweeping a record the release callback still points at.
    pub fn outstandingFrames(self: *Provider) u32 {
        return self.outstanding;
    }

    /// Stops the stream and releases the picked item, keeping the platform
    /// context for a later selection. Only the owner thread may call this,
    /// because the platform requires the session to be stopped from the thread
    /// that started it.
    ///
    /// Stopping twice is the same as stopping once, and it does not release what
    /// the consumer already borrowed: a frame belongs to the consumer until its
    /// own release returns it, so `outstandingFrames` still reports it
    /// afterwards and `deinit` still refuses.
    pub fn stop(self: *Provider) void {
        self.is_streaming = false;
        if (comptime !win.is_windows) return;
        if (!self.stop_requested) {
            self.stop_requested = true;
            if (self.ctx) |ctx| nogui_capture_stop(ctx);
        }
        self.releaseItem();
    }

    fn releaseItem(self: *Provider) void {
        if (self.item) |item| {
            nogui_capture_item_destroy(item);
            self.item = null;
        }
    }
};

/// What the provider published, as the only consumer of it can see it.
///
/// The sink is the provider's whole output, so a test that says something about
/// the provider reads the record rather than the provider's own fields.
const Recorder = struct {
    infos: [4]StreamInfo,
    count: usize = 0,
    /// Frames the sink was handed, which is how a test tells a delivered frame
    /// from a session that merely claims to be streaming.
    frames: usize = 0,

    fn format(ctx: *anyopaque, info: StreamInfo) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.count < self.infos.len) {
            self.infos[self.count] = info;
            self.count += 1;
        }
    }
    fn frame(ctx: *anyopaque, descriptor: FrameDescriptor) void {
        _ = descriptor;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.frames += 1;
    }
    fn state(ctx: *anyopaque, session_state: SessionState, failure: capture.FailureReason) void {
        _ = ctx;
        _ = session_state;
        _ = failure;
    }
};

test "api-w23 windows capture refuses a request the picker cannot honour" {
    // Each of these would otherwise be answered with something the caller did not
    // ask for, which is worse than a refusal.
    try std.testing.expectError(error.UnsupportedSources, validate(.{
        .sources = SourceType.virtual,
    }));
    // A request that names one class the picker has and one it does not is
    // refused whole, not narrowed to the half that works: a caller that asked
    // for a monitor and a virtual source and got a monitor is a caller that
    // believes it captured what it asked for.
    try std.testing.expectError(error.UnsupportedSources, validate(.{
        .sources = SourceType.monitor.with(.virtual),
    }));
    // The two refusals are separate answers, so a request that is wrong in both
    // ways is told about the source class first rather than about the stream
    // count it also asked for.
    try std.testing.expectError(error.UnsupportedSources, validate(.{
        .sources = SourceType.virtual,
        .multiple = true,
    }));
    try std.testing.expectError(error.MultipleStreamsUnsupported, validate(.{
        .multiple = true,
    }));
    try std.testing.expectError(error.UnsupportedPersistence, validate(.{
        .persistence = .until_revoked,
    }));
    try std.testing.expectError(error.UnsupportedCursorMode, validate(.{
        .cursor_mode = .hidden,
    }));
    // A restore token means "reuse the earlier consent". Windows has no such path,
    // so accepting it and showing the picker would claim a reuse that never
    // happened.
    try std.testing.expectError(error.RestoreTokenUnsupported, validate(.{
        .restore_token = "session-1",
    }));
    // An empty token asserts nothing, so it is not a refusal.
    try validate(.{ .restore_token = "" });

    // A request the platform can honour passes, including an empty source set,
    // which means "let the chooser decide".
    try validate(.{});
    try validate(.{ .sources = SourceType.none });
    try validate(.{ .sources = SourceType.monitor });
    try validate(.{ .sources = SourceType.monitor.with(.window) });
}

test "api-w23 windows capture parent window is a borrowed sdl handle" {
    // The shared `Request.parent_window` is a string, and this is the Windows
    // spelling of the X11 adapter's. A handle that is not in that form is refused
    // rather than guessed at.
    try std.testing.expectEqual(
        @as(usize, 0x1234),
        @intFromPtr(try parseParentWindow("win32:0x1234")),
    );
    try std.testing.expectError(error.MalformedParentWindow, parseParentWindow("x11:0x1234"));
    try std.testing.expectError(error.MalformedParentWindow, parseParentWindow("win32:"));
    try std.testing.expectError(error.MalformedParentWindow, parseParentWindow("win32:0x0"));
    try std.testing.expectError(error.MalformedParentWindow, parseParentWindow(""));
}

test "api-w23 windows capture without a platform says why" {
    // A build with no Windows capture reports why, and never claims the fields a
    // platform would have filled in.
    if (comptime !win.is_windows) {
        const caps = capabilities();
        try std.testing.expect(!caps.available);
        try std.testing.expectEqual(capture.BackendKind.none, caps.backend);
        try std.testing.expect(caps.unavailable_reason.len != 0);
        try std.testing.expect(!isApplicable());
    }
}

test "api-w23 windows capture moves the format epoch only on a real change" {
    // A captured window can resize mid-stream, and the pool then delivers a
    // different surface size. A consumer that caches decoded frames drops them
    // when the epoch moves, so an unchanged stream must not move it and a changed
    // one must. The sink records what the provider published, because that is the
    // only thing a consumer ever sees.
    // SAFETY: `count` starts at zero and only counts slots `format` has written,
    // so no entry is read before it is recorded.
    var recorder: Recorder = .{ .infos = undefined };
    var provider: Provider = .init(std.testing.allocator, std.testing.io, .{
        .ctx = &recorder,
        .frame = Recorder.frame,
        .format = Recorder.format,
        .state = Recorder.state,
    }, .{});
    defer provider.deinit() catch unreachable;

    var raw: RawFrame = std.mem.zeroes(RawFrame);
    raw.width = 1920;
    raw.height = 1080;
    provider.publishLayout(raw, .bgra8);
    // The same layout again is not a change, so nothing is republished.
    provider.publishLayout(raw, .bgra8);
    // A resized source is a change, and the epoch moves with it.
    raw.width = 1280;
    raw.height = 720;
    provider.publishLayout(raw, .bgra8);
    // A different format at the same size is also a change.
    raw.format = 1;
    provider.publishLayout(raw, .rgba8);

    try std.testing.expectEqual(@as(usize, 3), recorder.count);
    try std.testing.expectEqual(@as(u32, 1), recorder.infos[0].format_epoch);
    try std.testing.expectEqual(@as(u32, 2), recorder.infos[1].format_epoch);
    try std.testing.expectEqual(@as(u32, 3), recorder.infos[2].format_epoch);
    try std.testing.expectEqual(@as(u32, 1920), recorder.infos[0].width);
    try std.testing.expectEqual(@as(u32, 1280), recorder.infos[1].width);
    try std.testing.expectEqual(capture.PixelFormat.rgba8, recorder.infos[2].format);
    // An unknown source class must remain distinct from no selected source.
    try std.testing.expectEqual(SourceType.none, recorder.infos[2].sources);
    try std.testing.expect(!recorder.infos[2].source_class_known);
}

test "api-w23 windows capture teardown refuses a frame the consumer still holds" {
    // A consumer release hands the buffer back into a record this provider
    // allocated, so a frame that has not been released is still live. Stopping
    // the stream does not take it back, and the teardown refuses by name instead
    // of freeing a record the release callback still points at.
    // SAFETY: `count` starts at zero and only counts slots `format` has written,
    // so no entry is read before it is recorded.
    var recorder: Recorder = .{ .infos = undefined };
    var provider: Provider = .init(std.testing.allocator, std.testing.io, .{
        .ctx = &recorder,
        .frame = Recorder.frame,
        .format = Recorder.format,
        .state = Recorder.state,
    }, .{});
    try std.testing.expectEqual(@as(u32, 0), provider.outstandingFrames());

    // Two real frames handed to the sink, neither of them released yet. The
    // records are the ones the release callback will be handed, so the count is
    // what the provider actually owes rather than a number written into it.
    var pixels: [8]u8 = undefined;
    const first = try OwnedFrame.publish(&provider, .{
        .data = &pixels,
        .width = 2,
        .height = 2,
        .stride = 4,
        .format = 0,
        .timestamp_ns = 1,
        .owner = null,
    });
    const second = try OwnedFrame.publish(&provider, .{
        .data = &pixels,
        .width = 2,
        .height = 2,
        .stride = 4,
        .format = 0,
        .timestamp_ns = 2,
        .owner = null,
    });
    provider.is_streaming = true;
    provider.stop();
    provider.stop();
    provider.stop();
    try std.testing.expect(!provider.is_streaming);
    try std.testing.expectEqual(@as(u32, 2), provider.outstandingFrames());

    // The refusal repeats and leaves the provider whole, so the frames the
    // consumer holds still have a provider to come back to.
    try std.testing.expectError(error.FramesStillBorrowed, provider.deinit());
    try std.testing.expectError(error.FramesStillBorrowed, provider.deinit());
    try std.testing.expectEqual(@as(u32, 2), provider.outstandingFrames());

    // A release is what gives the record back: the count falls by exactly the
    // one frame that was returned, so a release cannot be counted twice and a
    // frame cannot be released on the provider's behalf.
    OwnedFrame.release(first);
    try std.testing.expectEqual(@as(u32, 1), provider.outstandingFrames());

    // Every borrowed frame back, and the teardown goes through. The records are
    // freed with the frames, which the testing allocator reports if they are
    // not.
    OwnedFrame.release(second);
    try std.testing.expectEqual(@as(u32, 0), provider.outstandingFrames());
    try provider.deinit();
}

test "api-w23 the windows capture provider is driven by the shared session" {
    // The frame pool hands a frame over when it is asked, and no thread of this
    // provider's pushes one, so the shared session has to be able to drive it.
    // A backend without a drive reaches a healthy streaming session that never
    // delivers anything: a black screen behind a session that reports itself
    // working.
    // SAFETY: `count` starts at zero and only counts slots `format` has written,
    // so no entry is read before it is recorded.
    var recorder: Recorder = .{ .infos = undefined };
    var provider: Provider = .init(std.testing.allocator, std.testing.io, .{
        .ctx = &recorder,
        .frame = Recorder.frame,
        .format = Recorder.format,
        .state = Recorder.state,
    }, .{});
    defer provider.deinit() catch unreachable;

    const backend = provider.backend();
    try std.testing.expect(backend.isPollDriven());

    // The drive reaches the same code a host's own poll would, and publishes
    // nothing while no stream is running: an idle provider has no frame to hand
    // over, and says so with a count of zero rather than a frame of zeros.
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(0));
    try std.testing.expectEqual(@as(usize, 0), recorder.frames);
}
