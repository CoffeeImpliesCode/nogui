//! Shared SDL lifetime, generational native windows, host-owned native dialogs,
//! window-scoped drag ingress and optional external event drive.
//! The caller owns the Session; each owned native window owns exactly one App.
//! A drop over one of these windows is that window's `drop` event; a drop the
//! platform attributes to no window stays a launch of the process.
const std = @import("std");
const sdl3 = @import("sdl3");
const nogui = @import("nogui");
const Window = @import("window.zig").Window;
const display = @import("display.zig");
const Inspector = @import("inspector.zig").Inspector;
const host_clipboard = @import("clipboard.zig");
const sdl_session = @import("sdl_session.zig");
const dialogs = @import("dialogs.zig");
const open_url = @import("open_url.zig");
const system_bell = @import("system_bell.zig");
const contract = nogui.window_contract;
const FrameDemand = nogui.frame_demand.FrameDemand;

var next_host_id: std.atomic.Value(u64) = .init(1);

pub const ManagedWindow = struct {
    native: Window,
    /// SDL can reuse native IDs while old events still wait in the queue.
    created_ns: u64,
    app: *nogui.App,
    ownership: enum { owned, borrowed },
    demand: FrameDemand = .{},
    /// Borrowed; detach before destroying the Inspector.
    inspector: ?*Inspector = null,
    requested: contract.RequestedState,
    observed: contract.ObservedState,
    /// What a consumer has last been told about this window's device scale,
    /// and the question the next routed window event asks of it. Armed from
    /// the reading taken at open, because that reading is the first one this
    /// window hands out.
    scale_notice: ScaleNotice,
    /// The native parent SDL reports for this window, or null. Read back after
    /// creation so a backend that drops the parent property is visible.
    native_parent: ?sdl3.video.WindowId,
    presented_once: bool = false,
    background_srgb: ?nogui.paint.Srgb,
    parent: ?contract.WindowHandle,
    gpa: std.mem.Allocator,
    title: [:0]u8,
    /// The window's system bell backend, built once on the first bind and
    /// released with the window. A platform with no bell leaves it null, which
    /// answers the same as a provider that cannot ring: no request.
    bell: ?system_bell.Provider = null,
    /// The one observer that may ask this window to ring. Exactly one owner
    /// holds a window at a time, and it is released by `unbindSystemBell` or
    /// by `destroyWindow` before the native window goes — never by a handle
    /// that no longer names this window.
    bell_owner: ?system_bell.Owner = null,

    /// Re-read the platform. This is a measurement and not a notification:
    /// it updates `observed` and the frame demand, and it deliberately
    /// leaves `scale_notice` alone, so a probe cannot consume a device-scale
    /// transition that no consumer has been told about yet.
    pub fn refresh(self: *ManagedWindow) !void {
        try self.refreshAt(try self.native.clientExtent());
    }

    /// Re-read the platform from a client measurement the caller already took
    /// for the event it is routing. Taking the reading once is what keeps the
    /// state this window publishes, the extents the routed event reports and
    /// the scale answer that event carries describing the SAME window: two
    /// independent queries can straddle a resize or a display-scale change and
    /// answer differently, and a compositor that rescales a window between
    /// them leaves the consumer holding two sizes for one event.
    pub fn refreshAt(self: *ManagedWindow, extents: Window.ClientExtent) !void {
        self.observed = try observe(&self.native, extents);
        self.demand.setVisible(self.observed.visible and
            (!self.observed.occluded or !self.presented_once));
    }

    /// SDL owns this title until its next change or native window destruction.
    pub fn observedTitle(self: *const ManagedWindow) ?[:0]const u8 {
        return self.native.sdl.getTitle();
    }

    pub fn markPresented(self: *ManagedWindow) void {
        self.presented_once = true;
        self.demand.setVisible(self.observed.visible and !self.observed.occluded);
    }

    pub fn requestTitle(self: *ManagedWindow, title: [:0]const u8) !void {
        const copy = try self.gpa.dupeSentinel(u8, title, 0);
        errdefer self.gpa.free(copy);
        try self.native.sdl.setTitle(copy);
        self.gpa.free(self.title);
        self.title = copy;
        self.requested.title = copy;
    }

    pub fn requestSize(self: *ManagedWindow, size: contract.Size) !void {
        if (size.width == 0 or size.height == 0 or
            size.width > std.math.maxInt(i32) or size.height > std.math.maxInt(i32))
        {
            return error.InvalidWindowSize;
        }
        try self.native.setSize(size);
        self.requested.size = size;
    }

    /// Change the client-size floor. A refused request leaves the recorded
    /// limit alone, so `requested` never claims a bound the platform rejected.
    pub fn requestMinimumSize(self: *ManagedWindow, size: contract.Size) !void {
        try validLimit(size);
        if (self.requested.maximum_size) |maximum| {
            if (size.width > maximum.width or size.height > maximum.height) {
                return error.InvalidMinimumSize;
            }
        }
        try self.native.setMinimumSize(size);
        self.requested.minimum_size = size;
    }

    /// Change the client-size ceiling. A zero bound is the platform's own
    /// "no limit" answer, so it is recorded as the absence of a maximum
    /// rather than as a zero-sized box.
    pub fn requestMaximumSize(self: *ManagedWindow, size: contract.Size) !void {
        try validLimit(size);
        if (self.requested.minimum_size) |minimum| {
            if (size.width < minimum.width or size.height < minimum.height) {
                return error.InvalidMaximumSize;
            }
        }
        try self.native.setMaximumSize(size);
        self.requested.maximum_size = if (size.width == 0 or size.height == 0) null else size;
    }

    /// The client-size limits the platform holds right now. This is the
    /// platform's reading, which is not the same value as what this host last
    /// requested and not the same value either as the client size in use.
    pub fn observedSizeLimits(self: *const ManagedWindow) !Window.SizeLimits {
        return self.native.sizeLimits();
    }

    /// Ask the window manager for its own menu at a client point. There is no
    /// observed counterpart and no capability gate: a platform with no such
    /// menu accepts the request and shows nothing, so a caller must not read
    /// "nothing happened" as a refusal.
    pub fn requestSystemMenu(self: *const ManagedWindow, x: i32, y: i32) !void {
        try self.native.systemMenu(x, y);
    }

    /// The native parent SDL reports, or null. Compared against the requested
    /// parent this is how a caller learns that a backend kept the relationship
    /// or dropped it.
    pub fn observedParent(self: *const ManagedWindow) ?sdl3.video.WindowId {
        return self.native_parent;
    }

    /// The first requested/observed disagreement, or null when they agree.
    pub fn divergence(self: *const ManagedWindow) ?contract.Divergence {
        return contract.divergence(self.requested, self.observed);
    }

    pub fn requestPosition(self: *ManagedWindow, position: contract.Point) !void {
        if (!display.hasGlobalPosition()) return error.UnsupportedGlobalPosition;
        try self.native.setPosition(position);
        self.requested.position = position;
    }

    pub fn requestVisibility(self: *ManagedWindow, visible: bool) !void {
        if (visible) {
            try self.native.show();
        } else {
            try self.native.sdl.hide();
            self.demand.setVisible(false);
        }
        self.requested.visible = visible;
    }

    pub fn requestFocus(self: *ManagedWindow) !void {
        try self.native.sdl.raise();
        self.requested.focused = true;
    }

    pub fn requestMinimize(self: *ManagedWindow) !void {
        try self.native.sdl.minimize();
        self.requested.minimized = true;
    }

    pub fn requestMaximized(self: *ManagedWindow, maximized: bool) !void {
        if (maximized) {
            try self.native.sdl.maximize();
        } else {
            try self.native.sdl.restore();
        }
        self.requested.maximized = maximized;
        if (!maximized) self.requested.minimized = false;
    }

    pub fn requestRestore(self: *ManagedWindow) !void {
        try self.native.sdl.restore();
        self.requested.minimized = false;
        self.requested.maximized = false;
    }

    pub fn requestFullscreen(self: *ManagedWindow, fullscreen: bool) !void {
        try self.native.sdl.setFullscreen(fullscreen);
        self.requested.fullscreen = fullscreen;
    }

    pub fn requestAttention(self: *ManagedWindow, attention: bool) !void {
        try self.native.sdl.flash(if (attention) .briefly else .cancel);
        self.requested.attention = attention;
    }

    pub fn requestPresentation(self: *ManagedWindow) void {
        self.demand.requestPresentation();
    }

    /// Re-arm layout, paint and presentation after the system suspended. The
    /// session-side redraw is re-armed too: a model update that was coalesced
    /// before the suspend has already been consumed by the pre-resume pump,
    /// so without this every window would come back showing the frame it had
    /// when it went away.
    pub fn resumeDemand(self: *ManagedWindow, session: *nogui.Session) !void {
        try self.refresh();
        self.demand.invalidateLayout();
        if (self.observed.visible) self.demand.requestPresentation();
        try session.requestRedraw(self.app.window);
    }

    fn observe(native: *const Window, extents: Window.ClientExtent) !contract.ObservedState {
        const flags = native.sdl.getFlags();
        const native_display = try native.sdl.getDisplayForWindow();
        const position: ?contract.Point = if (display.hasGlobalPosition()) blk: {
            const point = try native.sdl.getPosition();
            break :blk .{ .x = @intCast(point[0]), .y = @intCast(point[1]) };
        } else null;
        // A backend that never sets the flag cannot confirm the state, and a
        // hard `false` there would read as an observation that was never made.
        const minimized: ?bool = if (display.hasWindowMinimized()) flags.minimized else null;
        return .{
            .size = .{ .width = @intFromFloat(extents.logical.width), .height = @intFromFloat(extents.logical.height) },
            .pixels = extents.pixels,
            .display = display.fromNative(native_display),
            .display_scale = try native.sdl.getDisplayScale(),
            .position = position,
            .visible = !flags.hidden and !flags.minimized,
            .occluded = flags.occluded,
            .focused = flags.input_focus,
            .minimized = minimized,
            .maximized = flags.maximized,
            .fullscreen = flags.fullscreen,
            .borders = native.borders(),
        };
    }
};

/// The part of one window reading that a device-scale question is asked of.
/// `ObservedState` also carries placement, size limits and flags, and none of
/// those decide the scale a window is drawn at, so these four fields are the
/// whole question. Keeping them alone is what stops the answer from being
/// read off a field that cannot move it.
pub const ScaleReading = struct {
    display: contract.DisplayId,
    display_scale: f32,
    size: contract.Size,
    pixels: nogui.geometry.DeviceSize,

    pub fn capture(state: contract.ObservedState) ScaleReading {
        return .{
            .display = state.display,
            .display_scale = state.display_scale,
            .size = state.size,
            .pixels = state.pixels,
        };
    }
};

/// True when the two readings draw this window at a different device scale.
/// The same rule `display.Delta` applies to a display reading: a different
/// pixel size at an unchanged ratio is a resize, not a scale transition, and
/// a consumer that re-rasterizes at a new scale must not be told otherwise.
///
/// A reading with no client area has no ratio to compare, and a window with
/// no client area is not a scale change. The host refuses a zero-size window
/// at open and reports a collapse through `divergence` instead, so this stays
/// a question about scale alone.
fn scaleMoved(before: ScaleReading, after: ScaleReading) bool {
    if (before.display != after.display) return true;
    if (before.display_scale != after.display_scale) return true;
    const was = nogui.geometry.PixelScale.init(
        .{ .width = @floatFromInt(before.size.width), .height = @floatFromInt(before.size.height) },
        before.pixels,
    ) catch return false;
    const now = nogui.geometry.PixelScale.init(
        .{ .width = @floatFromInt(after.size.width), .height = @floatFromInt(after.size.height) },
        after.pixels,
    ) catch return false;
    return was.x != now.x or was.y != now.y;
}

/// The device scale a consumer has last been told this window is drawn at,
/// and the answer the next routed window event gives about it.
///
/// A window is re-read in places that say nothing to a consumer: a display
/// event re-reads every window that display draws, a resume re-reads after
/// the system suspends, and a caller may probe on its own. Those probes all
/// write `ManagedWindow.observed`, so a routed event measured against that
/// field is measured against whatever the host happened to look at last.
/// When one of them lands between the platform deciding a window changed
/// scale and the window's own event arriving, the new scale is already in
/// the field, the diff finds nothing, and the transition reaches nobody.
/// A compositor that delivers a display event and a per-window event for one
/// output change produces exactly that order, and a consumer that
/// re-rasterizes on this bit then never learns its target moved.
///
/// The baseline moves only here, and only when an event carrying the reading
/// is handed to a consumer. It is one value held by value inside the window:
/// no allocation, and no SDL event is synthesized or reordered to carry a
/// fact the platform already delivered.
pub const ScaleNotice = struct {
    /// The reading behind the last window event a consumer was handed.
    reported: ScaleReading,

    /// Answer one routed window event from the reading the host just took,
    /// and take that reading as the baseline for the next one. Answering and
    /// advancing together is the point: a transition is reported once, the
    /// same ratio is never reported twice, and no path can advance the
    /// baseline without answering for it.
    pub fn measure(self: *ScaleNotice, now: ScaleReading) bool {
        const moved = scaleMoved(self.reported, now);
        self.reported = now;
        return moved;
    }
};

/// A client-size bound must be expressible as one, and 0x0 is never a bound:
/// a caller that meant "no maximum" leaves the option absent instead.
fn validLimit(size: contract.Size) !void {
    if (size.width > std.math.maxInt(i32) or size.height > std.math.maxInt(i32)) {
        return error.InvalidWindowSize;
    }
}

const Slot = struct {
    generation: u32 = 1,
    window: ?*ManagedWindow = null,
    next_free: ?u32 = null,
};

pub const Application = struct {
    gpa: std.mem.Allocator,
    session: *nogui.Session,
    host_id: u64,
    /// The thread that created this host, which is the thread that drives it:
    /// `start`, `step` and `run` are all one-thread operations, and so is
    /// every window. Recorded once, at `init`, because a bell is native work
    /// bound to the window's own thread — so that work is refused up front,
    /// before a handle is even resolved, instead of after reading the slots.
    ui_thread: std.Thread.Id,
    /// One SDL clipboard offer shared by every window in this application.
    clipboard: host_clipboard.Clipboard,
    /// Native dialogs for the windows this host owns. A request parented to a
    /// window resolves as `parent_closed` when that window closes, so a late
    /// native completion can never update a window that is already gone. The
    /// manager's leases point back at this host, so move the Application to
    /// its final address before the first request, exactly as `start` says.
    ///
    /// No worker is installed: this library starts no thread of its own, so a
    /// request that blocks on a person reports `unsupported` until the host
    /// installs a worker it already owns.
    dialogs: dialogs.DialogManager,
    /// The native drag in flight. A window that dies mid-drag clears it, so
    /// no later phase is measured against a window this host no longer owns.
    drop_tracker: open_url.DropPhaseTracker = .init(),
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    /// The displays this host has read. Every display event is diffed against
    /// it, so a scale or bounds change is reported as a measurement and a
    /// caller can enumerate the desktop without asking SDL again.
    displays: display.Snapshot,
    native_windows: std.AutoHashMapUnmanaged(sdl3.video.WindowId, contract.WindowHandle) = .empty,
    free_slot: ?u32 = null,
    pending_launches: std.ArrayListUnmanaged(OwnedLaunch) = .empty,
    window_count: u32 = 0,
    hooks: Hooks = .{},
    quit_timeout_ms: u31,
    restart_policy: RestartPolicy,
    running: bool = true,
    launched: bool = false,
    wake_registered: bool = false,
    wake_type: sdl3.c.SDL_EventType = 0,
    wake_failed: std.atomic.Value(bool) = .init(false),
    next_quit_token: u64 = 1,
    /// True between an application-level hide (or a background transition) and
    /// the activate or reopen that brings the windows back. Per-window
    /// visibility is a different thing and lives in `RequestedState`.
    hidden: bool = false,
    pending_quit: ?PendingQuit = null,
    closing: bool = false,
    considering_quit: bool = false,
    frame_callback_active: bool = false,
    flushing_launches: bool = false,

    pub const Options = struct {
        video_driver: ?[:0]const u8 = null,
        render_driver: ?[:0]const u8 = null,
        /// SDL metadata is process-wide; set this before initializing video.
        app_id: ?[:0]const u8 = null,
        quit_timeout_ms: u31 = 2_000,
        restart: RestartPolicy = .never,
    };
    pub const RestartPolicy = enum { never, explicit };
    pub const QuitDecision = enum { approve, veto, defer_decision };
    pub const LastWindowDecision = enum { keep_running, request_quit };
    pub const QuitToken = struct { host: u64, sequence: u64 };
    const PendingQuit = struct { token: QuitToken, deadline_ms: u64 };
    /// A deferred quit and the time left to resolve it. Exposed so a caller can
    /// report the bound it is actually held to rather than a configured
    /// constant it never observed being applied.
    pub const PendingQuitState = struct { token: QuitToken, remaining_ms: u64 };
    pub const IncomingLaunch = struct {
        kind: enum { file, text },
        /// Borrowed for the callback; callers retain a copy for deferred processing.
        value: []const u8,
    };
    const OwnedLaunch = struct {
        kind: @FieldType(IncomingLaunch, "kind"),
        value: []u8,
    };

    pub const WindowEvent = struct {
        handle: contract.WindowHandle,
        translated: ?Window.Event = null,
        state_changed: bool = false,
        /// This event moved the window's DISPLAY SCALE, measured against the
        /// last reading a consumer was given and not read off the event's tag.
        /// A re-read that reached no consumer — a display event for this
        /// window's output, a resume — does not become the baseline, so a
        /// transition the platform has already applied is still reported once,
        /// by whichever window event arrives next.
        ///
        /// A compositor that only delivers per-window scale events reports
        /// the same thing here that one delivering a display-scale event
        /// reports through `DisplayChange.delta.scale_changed`, so a consumer
        /// that re-rasterizes at a new device scale does not have to know
        /// which of the two routes the platform took.
        ///
        /// False whenever the scale did not move, including for a plain
        /// resize: a different pixel size at an unchanged ratio is a resize,
        /// and reporting it as a scale change would be the same confusion
        /// `display.Delta.scale_changed` exists to prevent.
        scale_changed: bool = false,
    };
    pub const DisplayChangeKind = enum { added, removed, geometry, scale };
    pub const DisplayChange = struct {
        id: display.Id,
        kind: DisplayChangeKind,
        /// What changed, measured against the reading this host held before
        /// the event. Never null: a display event that changes nothing still
        /// reports every field as false.
        delta: display.Delta,
        current: ?display.Info,
    };
    /// One native drag phase, scoped to a window this host owns. The phase and
    /// the offer kind come from the same `open_url` contract a standalone
    /// consumer uses, so the order SDL reports is the order this host
    /// reports. `offer.value` borrows SDL's payload for this dispatch: the
    /// host opens nothing and hands nothing to the App, so a consumer that
    /// needs the payload after dispatch returns keeps its own copy.
    pub const DropEvent = struct {
        handle: contract.WindowHandle,
        phase: open_url.DropPhase,
        position: ?[2]f32 = null,
        offer: ?open_url.DropOffer = null,
    };
    pub const Event = union(enum) {
        window: WindowEvent,
        drop: DropEvent,
        display: DisplayChange,
        system_wake,
    };
    pub const Hooks = struct {
        context: ?*anyopaque = null,
        on_launch: ?*const fn (*anyopaque, *Application) void = null,
        on_reopen: ?*const fn (*anyopaque, *Application) void = null,
        on_activate: ?*const fn (*anyopaque, *Application) void = null,
        on_hide: ?*const fn (*anyopaque, *Application) void = null,
        on_system_wake: ?*const fn (*anyopaque, *Application) void = null,
        on_incoming_launch: ?*const fn (*anyopaque, *Application, IncomingLaunch) void = null,
        on_close_request: ?*const fn (*anyopaque, contract.WindowHandle) bool = null,
        /// Runs while the platform window is still alive and immediately
        /// before the host destroys it. A consumer that owns resources
        /// presenting INTO that window — a swapchain, a platform surface — must
        /// release them here: SDL documents the Vulkan surface destroy as
        /// belonging before `Window.deinit`, and on X11 the swapchain and its
        /// `VkSurfaceKHR` reference the X11 `Window` that destroy frees. The
        /// App's GPU mounts are already detached when this runs.
        ///
        /// A window closed by a veto never reaches it, and neither does one
        /// whose `on_close_request` returned false.
        on_before_close: ?*const fn (*anyopaque, *ManagedWindow) void = null,
        /// The handle is stale: the host has already destroyed the window. Read
        /// a window's own state in `on_before_close`, not here.
        on_closed: ?*const fn (*anyopaque, contract.WindowHandle) void = null,
        on_last_window_closed: ?*const fn (*anyopaque, *Application) LastWindowDecision = null,
        on_quit_request: ?*const fn (*anyopaque, *Application, QuitToken) QuitDecision = null,
        on_event: ?*const fn (*anyopaque, *Application, Event) anyerror!void = null,
        /// Return false for a failed frame; its demand is restored for retry.
        on_frame: ?*const fn (*anyopaque, *Application, *ManagedWindow, FrameDemand.Work) anyerror!bool = null,
    };
    pub const Capabilities = struct {
        /// False on Wayland and headless drivers; other options report native
        /// errors. This also gates a window move: a `requestPosition` on a
        /// platform without a global desktop space is refused, and so is an
        /// open that asks for one, instead of silently landing somewhere else.
        global_position: bool,
        /// False on backends that never set `SDL_WINDOW_MINIMIZED`; the matching
        /// `ObservedState.minimized` is `null` there rather than a false reading.
        minimized: bool,
        /// False on headless drivers that keep no parent/child window
        /// hierarchy, where a `menu` or `tooltip` window is created with no
        /// parent relationship left to observe. A client-size request has no
        /// capability gate at all: SDL forwards it everywhere and the
        /// compositor still decides the observed size, which is what keeps
        /// requested and observed size separate values.
        hierarchy: bool,
    };

    pub fn init(
        gpa: std.mem.Allocator,
        session: *nogui.Session,
        options: Options,
    ) !Application {
        if (options.app_id) |id| try sdl3.setAppMetadataProperty(.identifier, id);
        try sdl_session.acquire(.{
            .video_driver = options.video_driver,
            .render_driver = options.render_driver,
        });
        errdefer sdl_session.release();
        const id = next_host_id.fetchAdd(1, .monotonic);
        if (id == 0 or id == std.math.maxInt(u64)) return error.HostIdExhausted;
        var snapshot: display.Snapshot = .empty(gpa);
        errdefer snapshot.deinit();
        snapshot = try display.Snapshot.capture(gpa);
        return .{
            .gpa = gpa,
            .session = session,
            .clipboard = host_clipboard.Clipboard.init(gpa),
            .dialogs = dialogs.DialogManager.init(gpa),
            .host_id = id,
            .ui_thread = std.Thread.getCurrentId(),
            .displays = snapshot,
            .quit_timeout_ms = options.quit_timeout_ms,
            .restart_policy = options.restart,
        };
    }

    /// Call from the UI thread after moving this Application to its final address.
    /// Session's task service may have been started by the caller already.
    pub fn start(self: *Application) !void {
        if (!self.running) return error.ApplicationStopped;
        if (!self.wake_registered) {
            if (!self.session.tasksStarted()) try self.session.startTasksOwned();
            self.wake_type = sdl3.events.register(1) orelse return error.SdlUserEventUnavailable;
            try self.session.setTaskWake(self, wakeFromTask);
            self.wake_registered = true;
        }
        if (!self.launched) {
            self.launched = true;
            if (self.hooks.on_launch) |callback| callback(self.hooks.context.?, self);
        }
        self.flushPendingLaunches();
    }

    /// Externally driven loops check the SDL wake push before draining tasks.
    pub fn checkWakeFailure(self: *Application) !void {
        if (self.wake_failed.swap(false, .acq_rel)) return error.SdlTaskWakeFailed;
    }

    pub fn setHooks(self: *Application, hooks: Hooks) void {
        std.debug.assert(hooks.context != null or
            (hooks.on_launch == null and hooks.on_reopen == null and hooks.on_activate == null and
                hooks.on_hide == null and hooks.on_system_wake == null and
                hooks.on_incoming_launch == null and hooks.on_close_request == null and
                hooks.on_before_close == null and hooks.on_closed == null and
                hooks.on_last_window_closed == null and hooks.on_quit_request == null and
                hooks.on_event == null and hooks.on_frame == null));
        self.hooks = hooks;
        if (self.launched and !self.flushing_launches) self.flushPendingLaunches();
    }

    /// Platform launch adapters may call this before a consumer installs its callback.
    /// Pending payloads are owned by this host and delivered once after launch.
    pub fn incomingLaunch(self: *Application, launch: IncomingLaunch) !void {
        if (!self.running) return error.ApplicationStopped;
        if (self.launched) {
            if (self.hooks.on_incoming_launch) |callback| {
                callback(self.hooks.context.?, self, launch);
                return;
            }
        }
        const copy = try self.gpa.dupe(u8, launch.value);
        errdefer self.gpa.free(copy);
        try self.pending_launches.append(self.gpa, .{ .kind = launch.kind, .value = copy });
    }

    fn flushPendingLaunches(self: *Application) void {
        if (self.flushing_launches) return;
        const callback = self.hooks.on_incoming_launch orelse return;
        const context = self.hooks.context.?;
        self.flushing_launches = true;
        defer self.flushing_launches = false;
        var queued = self.pending_launches;
        self.pending_launches = .empty;
        defer queued.deinit(self.gpa);
        for (queued.items) |launch| {
            callback(context, self, .{ .kind = launch.kind, .value = launch.value });
            self.gpa.free(launch.value);
        }
    }

    pub fn capabilities(self: *const Application) Capabilities {
        _ = self;
        return .{
            .global_position = display.hasGlobalPosition(),
            .minimized = display.hasWindowMinimized(),
            .hierarchy = display.hasWindowHierarchy(),
        };
    }

    /// The displays this host last read, in the order SDL enumerated them.
    /// Borrowed; the host owns the slice until it is deinitialized.
    pub fn displayList(self: *const Application) []const display.Info {
        return self.displays.infos.items;
    }

    pub fn isRunning(self: *const Application) bool {
        return self.running;
    }

    /// True while an application-level hide is in force. This is not a window
    /// property: `RequestedState.visible` is what each window asked for, and
    /// `reopen` restores exactly those.
    pub fn isHidden(self: *const Application) bool {
        return self.hidden;
    }

    /// The deferred quit still open for resolution, and the time left before
    /// it expires. `null` when no quit is deferred. A caller that reads this
    /// sees the bound this host is actually enforcing.
    pub fn pendingQuit(self: *const Application) ?PendingQuitState {
        const pending = self.pending_quit orelse return null;
        return .{
            .token = pending.token,
            .remaining_ms = pending.deadline_ms -| sdl3.timer.getMillisecondsSinceInit(),
        };
    }

    pub fn openWindow(self: *Application, options: contract.WindowOptions) !contract.WindowHandle {
        if (!self.running) return error.ApplicationStopped;
        if (self.closing or self.frame_callback_active) return error.LifecycleReentry;
        const owned = try self.gpa.create(nogui.App);
        errdefer self.gpa.destroy(owned);
        owned.* = try nogui.App.init(self.gpa, self.session);
        errdefer owned.deinit();
        return self.open(owned, .owned, options);
    }

    /// The caller retains the App and deinits it only after this window is closed.
    /// Closing retires its Session window so queued worker work cannot reach it.
    pub fn openWindowWithApp(
        self: *Application,
        app: *nogui.App,
        options: contract.WindowOptions,
    ) !contract.WindowHandle {
        if (app.session != self.session) return error.WrongSession;
        if (!self.session.hasWindow(app.window)) return error.UnknownWindow;
        for (self.slots.items) |slot| {
            if (slot.window) |window| {
                if (window.app == app) return error.AppAlreadyMounted;
            }
        }
        return self.open(app, .borrowed, options);
    }

    fn open(
        self: *Application,
        app: *nogui.App,
        ownership: @FieldType(ManagedWindow, "ownership"),
        options: contract.WindowOptions,
    ) !contract.WindowHandle {
        if (!self.running) return error.ApplicationStopped;
        if (self.closing) return error.LifecycleReentry;
        if (self.frame_callback_active) return error.LifecycleReentry;
        if (self.window_count == std.math.maxInt(u32)) return error.CapacityExceeded;
        if (self.free_slot == null and self.slots.items.len >= std.math.maxInt(u32)) {
            return error.CapacityExceeded;
        }
        if (options.width == 0 or options.height == 0 or
            options.width > std.math.maxInt(i32) or options.height > std.math.maxInt(i32))
        {
            return error.InvalidWindowSize;
        }
        if (options.minimum_size) |minimum| {
            if (minimum.width == 0 or minimum.height == 0) return error.InvalidMinimumSize;
            try validLimit(minimum);
        }
        if (options.maximum_size) |maximum| {
            if (maximum.width == 0 or maximum.height == 0) return error.InvalidMaximumSize;
            try validLimit(maximum);
            if (options.minimum_size) |minimum| {
                if (maximum.width < minimum.width or maximum.height < minimum.height) {
                    return error.InvalidMaximumSize;
                }
            }
        }
        // Every capability this open depends on is checked before anything is
        // allocated or created, so a request the platform cannot serve leaves
        // no title copy, no native window and no slot behind it.
        if (options.position != null and !display.hasGlobalPosition()) {
            return error.UnsupportedGlobalPosition;
        }
        const needs_parent = options.kind == .tooltip or options.kind == .menu;
        if (needs_parent and options.parent == null) return error.MissingParent;
        if (needs_parent and (options.maximized or options.fullscreen)) return error.InvalidPopupState;
        const parent = if (options.parent) |parent_id| try self.getWindow(parent_id) else null;
        if (parent != null and !needs_parent and options.kind != .normal) return error.InvalidWindowKind;
        if (options.display) |id| {
            _ = try display.query(id);
        }
        try self.native_windows.ensureUnusedCapacity(self.gpa, 1);
        if (self.free_slot == null) try self.slots.ensureUnusedCapacity(self.gpa, 1);
        const title = try self.gpa.dupeSentinel(u8, options.title, 0);
        errdefer self.gpa.free(title);
        const props: sdl3.video.Window.CreateProperties = .{
            .title = title,
            .width = options.width,
            .height = options.height,
            .resizable = options.resizable,
            .hidden = true,
            .focusable = options.focusable,
            .borderless = !options.decorated,
            .transparent = options.transparent,
            .utility = options.kind == .utility,
            .tooltip = options.kind == .tooltip,
            .menu = options.kind == .menu,
            .parent = if (parent) |window| window.native.sdl else null,
            .maximized = options.maximized,
            .fullscreen = options.fullscreen,
            .vulkan = options.gpu_surface,
            .high_pixel_density = true,
            .x = if (options.position) |position|
                .{ .absolute = position.x }
            else if (options.display) |id|
                .{ .centered = display.toNative(id) }
            else
                null,
            .y = if (options.position) |position|
                .{ .absolute = position.y }
            else if (options.display) |id|
                .{ .centered = display.toNative(id) }
            else
                null,
        };
        const created_ns = sdl3.timer.getNanosecondsSinceInit();
        const created = try sdl3.video.Window.initWithProperties(props);
        defer created[1].deinit();
        const sdl_window = created[0];
        errdefer sdl_window.deinit();
        const id = try sdl_window.getId();
        var native: Window = .{ .sdl = sdl_window, .id = id };
        if (options.minimum_size) |minimum| {
            try native.setMinimumSize(minimum);
        }
        if (options.maximum_size) |maximum| {
            try native.setMaximumSize(maximum);
        }
        if (options.visible) try native.show();
        // The reading an open publishes, and the baseline every later routed
        // window event is measured against. Both spaces come from one query
        // pair, so the logical box and the pixel box this window opens with
        // describe the same instant.
        const observed = try ManagedWindow.observe(&native, try native.clientExtent());
        const managed = try self.gpa.create(ManagedWindow);
        errdefer self.gpa.destroy(managed);
        managed.* = .{
            .native = native,
            .created_ns = created_ns,
            .app = app,
            .ownership = ownership,
            .requested = .{
                .title = title,
                .size = .{ .width = options.width, .height = options.height },
                .position = options.position,
                .visible = options.visible,
                .maximized = options.maximized,
                .fullscreen = options.fullscreen,
                .parent = options.parent,
                .kind = options.kind,
                .display = options.display,
                .minimum_size = options.minimum_size,
                .maximum_size = options.maximum_size,
                .resizable = options.resizable,
                .focusable = options.focusable,
                .decorated = options.decorated,
                .transparent = options.transparent,
                .background_srgb = options.background_srgb,
            },
            .observed = observed,
            .scale_notice = .{ .reported = ScaleReading.capture(observed) },
            .native_parent = native.nativeParent(),
            .background_srgb = options.background_srgb,
            .parent = options.parent,
            .gpa = self.gpa,
            .title = title,
        };
        app.textInputManager().native = managed.native.nativeTextInput();
        app.textInputManager().clipboard = .{
            .user = &self.clipboard,
            .read = textClipboardRead,
            .write = textClipboardWrite,
        };
        managed.demand.setVisible(managed.observed.visible);
        const index: u32 = self.free_slot orelse @intCast(self.slots.items.len);
        const handle: contract.WindowHandle = .{
            .host = self.host_id,
            .slot = index,
            .generation = if (self.free_slot != null) self.slots.items[index].generation else 1,
            .session_window = app.window,
        };
        if (self.free_slot) |reuse| {
            const slot = &self.slots.items[reuse];
            self.free_slot = slot.next_free;
            slot.next_free = null;
            slot.window = managed;
        } else {
            self.slots.appendAssumeCapacity(.{ .window = managed });
        }
        self.native_windows.putAssumeCapacity(id, handle);
        self.window_count += 1;
        return handle;
    }

    pub fn getWindow(self: *Application, handle: contract.WindowHandle) !*ManagedWindow {
        if (handle.host != self.host_id) return error.WrongHost;
        if (handle.slot >= self.slots.items.len) return error.StaleWindow;
        const slot = &self.slots.items[handle.slot];
        if (slot.generation != handle.generation) return error.StaleWindow;
        const window = slot.window orelse return error.StaleWindow;
        if (window.app.window != handle.session_window) return error.StaleWindow;
        return window;
    }

    /// Attach one inspector to one native window. It observes only committed
    /// frames and retains its own snapshots after the App replaces its arena.
    pub fn setInspector(
        self: *Application,
        handle: contract.WindowHandle,
        selected: ?*Inspector,
    ) !void {
        const window = try self.getWindow(handle);
        if (selected) |candidate| {
            for (self.slots.items) |slot| {
                if (slot.window) |other| {
                    if (other != window and other.inspector == candidate)
                        return error.InspectorAlreadyMounted;
                }
            }
        }
        if (window.inspector == selected) return;
        if (window.inspector) |previous| previous.clearSnapshots();
        window.inspector = selected;
    }

    /// Bind this window's system bell to one observer.
    ///
    /// The thread comes first, before the handle is even resolved: a request
    /// from anywhere but the thread that owns these windows is refused without
    /// reading the slot table, because building the backend is native work
    /// that belongs to one thread and no other.
    ///
    /// Past that, a binding is a claim on a WINDOW, not on a handle: it goes
    /// through the same generational check as every other window call, so a
    /// handle whose slot was reused is refused instead of reaching whichever
    /// window sits there now. One window has one owner, and a second bind is
    /// refused rather than displacing the observer already in place.
    ///
    /// The binding succeeds on a platform with no bell at all. That is a
    /// lifetime statement, not a capability one: `systemBellAvailable` and
    /// `ringSystemBell` are what report what the platform can do.
    pub fn bindSystemBell(
        self: *Application,
        handle: contract.WindowHandle,
        owner: system_bell.Owner,
    ) !void {
        if (std.Thread.getCurrentId() != self.ui_thread) return error.WrongThread;
        const window = try self.getWindow(handle);
        if (self.closing or self.frame_callback_active) return error.LifecycleReentry;
        if (window.bell_owner != null) return error.BellObserverBound;
        if (window.bell == null) window.bell = system_bell.Provider.init(window.native.sdl);
        window.bell_owner = owner;
    }

    /// Release this window's bell observer, if this observer still holds it.
    ///
    /// A release mutates the window, so it belongs to the thread that owns it:
    /// another thread is refused with `error.WrongThread` and the observer
    /// stays exactly where it is. A caller that gave its binding up and then
    /// released it would otherwise leave this window holding a callback into
    /// memory nobody owns.
    ///
    /// Everything else is an idempotent success. A handle that no longer names
    /// this window, a window with no observer, and an observer that has
    /// already been replaced all release nothing, because there is nothing
    /// left to release. The backend stays bound to the window until the
    /// window is destroyed.
    pub fn unbindSystemBell(
        self: *Application,
        handle: contract.WindowHandle,
        owner: system_bell.Owner,
    ) !void {
        if (std.Thread.getCurrentId() != self.ui_thread) return error.WrongThread;
        const window = self.getWindow(handle) catch return;
        const current = window.bell_owner orelse return;
        if (current.context != owner.context or current.on_closed != owner.on_closed) return;
        window.bell_owner = null;
    }

    /// Ring this window, or report why it cannot.
    ///
    /// Every refusal is an answer, not a crash. The thread is checked before
    /// anything else is read, so a request from another thread is turned away
    /// without touching the host; after that a handle that no longer names a
    /// live window is `window_closed` and a window with no observer behind it
    /// is `unsupported`.
    pub fn ringSystemBell(
        self: *Application,
        handle: contract.WindowHandle,
    ) system_bell.Result {
        if (std.Thread.getCurrentId() != self.ui_thread) return .wrong_thread;
        const window = self.getWindow(handle) catch return .window_closed;
        if (window.bell_owner == null) return .unsupported;
        // `ring` needs the backend itself, not a copy of it, so the provider
        // is reached through the window that owns it.
        const provider = if (window.bell) |*live| live else return .unsupported;
        return provider.ring();
    }

    /// Whether this window's backend can ring at all, measured at run time.
    ///
    /// A handle that no longer names a live window can ring nothing. A query
    /// from another thread reports false rather than reading a backend it does
    /// not own: the caller gets the conservative answer, and the window keeps
    /// its real one for the thread that drives it.
    pub fn systemBellAvailable(
        self: *Application,
        handle: contract.WindowHandle,
    ) bool {
        if (std.Thread.getCurrentId() != self.ui_thread) return false;
        const window = self.getWindow(handle) catch return false;
        if (window.bell_owner == null) return false;
        const provider = if (window.bell) |*live| live else return false;
        return provider.available();
    }

    pub fn closeWindow(self: *Application, handle: contract.WindowHandle) !bool {
        const window = try self.getWindow(handle);
        if (self.closing or self.frame_callback_active) return error.LifecycleReentry;
        for (self.slots.items) |slot| {
            if (slot.window) |child| {
                if (child.parent != null and std.meta.eql(child.parent.?, handle)) {
                    return error.ChildWindowsOpen;
                }
            }
        }
        self.closing = true;
        defer self.closing = false;
        if (self.hooks.on_close_request) |callback| {
            if (!callback(self.hooks.context.?, handle)) return false;
        }
        self.destroyWindow(handle, window);
        self.closing = false;
        if (self.window_count == 0 and !self.considering_quit) {
            if (self.hooks.on_last_window_closed) |callback| {
                if (callback(self.hooks.context.?, self) == .request_quit) try self.requestQuit();
            }
        }
        return true;
    }

    /// Quitting preflights every veto before destroying any window.
    pub fn requestQuit(self: *Application) !void {
        if (!self.running or self.pending_quit != null) return;
        if (self.frame_callback_active) return error.LifecycleReentry;
        if (self.considering_quit) return error.LifecycleReentry;
        self.considering_quit = true;
        defer self.considering_quit = false;
        const token: QuitToken = .{ .host = self.host_id, .sequence = self.next_quit_token };
        self.next_quit_token +%= 1;
        if (self.next_quit_token == 0) return error.QuitTokenExhausted;
        const decision = if (self.hooks.on_quit_request) |callback|
            callback(self.hooks.context.?, self, token)
        else
            QuitDecision.approve;
        switch (decision) {
            .approve => try self.commitQuit(),
            .veto => {},
            .defer_decision => self.pending_quit = .{
                .token = token,
                .deadline_ms = sdl3.timer.getMillisecondsSinceInit() +| self.quit_timeout_ms,
            },
        }
    }

    /// A timed-out or foreign token cannot approve shutdown. Timeouts veto.
    pub fn resolveQuit(self: *Application, token: QuitToken, approve: bool) !void {
        const pending = self.pending_quit orelse return error.NoPendingQuit;
        if (!std.meta.eql(token, pending.token)) return error.StaleQuitToken;
        self.pending_quit = null;
        if (sdl3.timer.getMillisecondsSinceInit() >= pending.deadline_ms) {
            return error.QuitRequestExpired;
        }
        if (approve) try self.commitQuit();
    }

    fn commitQuit(self: *Application) !void {
        if (self.closing) return error.LifecycleReentry;
        self.closing = true;
        defer self.closing = false;
        for (self.slots.items, 0..) |slot, index| {
            if (slot.window != null) {
                if (self.hooks.on_close_request) |callback| {
                    const handle = self.handleFor(@intCast(index));
                    if (!callback(self.hooks.context.?, handle)) return error.CloseVetoed;
                }
            }
        }
        while (self.window_count > 0) {
            var closed = false;
            for (self.slots.items, 0..) |slot, index| {
                const window = slot.window orelse continue;
                const handle = self.handleFor(@intCast(index));
                if (self.hasChild(handle)) continue;
                self.destroyWindow(handle, window);
                closed = true;
                break;
            }
            std.debug.assert(closed);
        }
        self.running = false;
    }

    fn hasChild(self: *const Application, parent: contract.WindowHandle) bool {
        for (self.slots.items) |slot| {
            if (slot.window) |window| {
                if (window.parent != null and std.meta.eql(window.parent.?, parent)) return true;
            }
        }
        return false;
    }

    fn handleFor(self: *const Application, index: u32) contract.WindowHandle {
        const slot = self.slots.items[index];
        return .{
            .host = self.host_id,
            .slot = index,
            .generation = slot.generation,
            .session_window = slot.window.?.app.window,
        };
    }

    fn destroyWindow(
        self: *Application,
        handle: contract.WindowHandle,
        window: *ManagedWindow,
    ) void {
        const native_id = window.native.id;
        // Everything that addresses this window is still whole here: the
        // native parent exists, its App is mounted, and nothing is released.
        // A `parent_closed` callback therefore cannot reach a retired owner,
        // and the one reply the host still has to give is given now. A drag
        // over this window died with it.
        self.dialogs.onWindowClosed(native_id);
        if (self.drop_tracker.active_window == native_id) self.drop_tracker.clear();
        // The bell observer hears about the window while the window is still
        // whole: it is told before the backend is released and before the
        // native window goes, so it can drop its own borrow of this host
        // instead of holding a pointer into memory that is about to be freed.
        // The notification is the reverse link — nothing else unlinks it.
        if (window.bell) |*provider| {
            if (window.bell_owner) |owner| {
                window.bell_owner = null;
                owner.on_closed(owner.context);
            }
            provider.deinit();
            window.bell = null;
        }
        window.app.textInputManager().clear();
        window.app.textInputManager().native = null;
        window.app.textInputManager().clipboard = null;
        if (window.inspector) |active| active.clearSnapshots();
        window.app.detachGpu();
        if (self.hooks.on_before_close) |callback| callback(self.hooks.context.?, window);
        const session_window = window.app.window;
        if (window.ownership == .borrowed) {
            self.session.retireWindow(session_window) catch @panic("borrowed App registration missing");
        } else {
            window.app.deinit();
            self.gpa.destroy(window.app);
        }
        window.native.deinit();
        self.gpa.free(window.title);
        self.gpa.destroy(window);
        const removed = self.native_windows.remove(native_id);
        std.debug.assert(removed);
        const slot = &self.slots.items[handle.slot];
        slot.window = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        slot.next_free = self.free_slot;
        self.free_slot = handle.slot;
        self.window_count -= 1;
        if (self.hooks.on_closed) |callback| callback(self.hooks.context.?, handle);
    }

    /// Bring a stopped application back under the explicit restart policy. The
    /// process already launched, so `start` here does not invoke `on_launch`
    /// a second time; a deferred quit is dropped because the request it
    /// belonged to is gone with the shutdown it was gating.
    pub fn restart(self: *Application) !void {
        if (self.restart_policy != .explicit) return error.RestartDisabled;
        if (self.running or self.window_count != 0) return error.ApplicationStillRunning;
        self.pending_quit = null;
        self.hidden = false;
        self.running = true;
    }

    /// The dock or taskbar asked for this application's windows back. Only the
    /// windows that were asked to be visible come back, and an application-level
    /// hide is lifted, because reopening is the answer to that hide.
    pub fn reopen(self: *Application) !void {
        if (!self.running) return error.ApplicationStopped;
        if (self.hooks.on_reopen) |callback| callback(self.hooks.context.?, self);
        self.hidden = false;
        for (self.slots.items) |slot| {
            if (slot.window) |window| {
                if (window.requested.visible) try window.requestVisibility(true);
            }
        }
    }

    /// This application became the active one. A window that an
    /// application-level hide put away is shown again before focus is raised,
    /// because raising an unmapped window asks for nothing.
    pub fn activate(self: *Application) !void {
        if (!self.running) return error.ApplicationStopped;
        if (self.hidden) {
            for (self.slots.items) |slot| {
                if (slot.window) |window| {
                    if (window.requested.visible) try window.requestVisibility(true);
                }
            }
            self.hidden = false;
        }
        for (self.slots.items) |slot| {
            if (slot.window) |window| {
                if (window.requested.visible) try window.requestFocus();
            }
        }
        if (self.hooks.on_activate) |callback| callback(self.hooks.context.?, self);
    }

    /// Put every window away without changing what any of them asked for. The
    /// per-window `requested.visible` is deliberately untouched, so `reopen`
    /// can restore exactly the set that was up when this was called.
    pub fn hide(self: *Application) !void {
        if (!self.running) return error.ApplicationStopped;
        for (self.slots.items) |slot| {
            if (slot.window) |window| {
                try window.native.sdl.hide();
                window.demand.setVisible(false);
            }
        }
        self.hidden = true;
        if (self.hooks.on_hide) |callback| callback(self.hooks.context.?, self);
    }

    /// The system came back. Every live window re-reads the compositor, has
    /// its layout and presentation demand recomputed, and has its session-side
    /// redraw re-armed, so a window that came back does not show the frame it
    /// had when it went away.
    pub fn notifySystemWake(self: *Application) !void {
        for (self.slots.items) |slot| {
            if (slot.window) |window| {
                try window.resumeDemand(self.session);
            }
        }
        if (self.hooks.on_system_wake) |callback| callback(self.hooks.context.?, self);
    }

    /// Borrowed event data (such as text input) expires at the next SDL poll.
    /// Applications driving another loop call pollEvent + dispatch themselves.
    pub fn pollEvent(self: *Application) ?sdl3.events.Event {
        _ = self;
        return sdl3.events.poll();
    }

    /// Route one SDL event once; no input is sent to App until the caller or hook consumes it.
    pub fn dispatch(self: *Application, raw: *const sdl3.events.Event) !?Event {
        if (self.frame_callback_active) return error.LifecycleReentry;
        try self.start();
        const event: ?Event = switch (raw.*) {
            .unknown => null,
            .quit => blk: {
                try self.requestQuit();
                break :blk null;
            },
            .terminating => blk: {
                try self.requestQuit();
                break :blk null;
            },
            .did_enter_foreground => blk: {
                // The system woke the process, not the application, so the
                // hidden flag and every window's demand are settled before the
                // activate hook runs and may open or show a window.
                self.hidden = false;
                try self.notifySystemWake();
                if (self.hooks.on_activate) |callback| callback(self.hooks.context.?, self);
                break :blk .system_wake;
            },
            .did_enter_background => blk: {
                self.hidden = true;
                if (self.hooks.on_hide) |callback| callback(self.hooks.context.?, self);
                break :blk null;
            },
            .drop_file => |value| blk: {
                const owner: ?sdl3.video.WindowId = value.window;
                // A drop the platform attributes to no window is a launch of
                // this process, exactly as it was before window drops had a
                // path of their own. A drop over one of this host's windows
                // is that window's business, not a launch.
                if (owner) |id| break :blk try self.routeDrop(raw, id, value.common.timestamp);
                try self.incomingLaunch(.{ .kind = .file, .value = value.file_name });
                break :blk null;
            },
            .drop_text => |value| blk: {
                const owner: ?sdl3.video.WindowId = value.window;
                if (owner) |id| break :blk try self.routeDrop(raw, id, value.common.timestamp);
                try self.incomingLaunch(.{ .kind = .text, .value = value.text });
                break :blk null;
            },
            // The remaining three name the drag rather than a payload. One the
            // platform attributes to no window has no window-scoped phase, so
            // the host routes it to nothing instead of picking a window of its
            // own for it.
            inline .drop_begin, .drop_position, .drop_complete => |value| blk: {
                const owner: ?sdl3.video.WindowId = value.window;
                if (owner) |id| break :blk try self.routeDrop(raw, id, value.common.timestamp);
                break :blk null;
            },
            .display_added => |value| try self.displayChanged(value.display, .added),
            .display_removed => |value| try self.displayChanged(value.display, .removed),
            inline .display_moved,
            .display_desktop_mode_changed,
            .display_current_mode_changed,
            .display_usable_bounds_changed,
            => |value| try self.displayChanged(value.display, .geometry),
            .display_content_scale_changed => |value| try self.displayChanged(value.display, .scale),
            .window_close_requested => |value| blk: {
                const handle = self.native_windows.get(value.id) orelse break :blk null;
                const window = try self.getWindow(handle);
                if (value.common.timestamp < window.created_ns) break :blk null;
                // A close this host declines is the same answer as a vetoed
                // one: the window is still whole, and nothing was released.
                // Letting `error.ChildWindowsOpen` out of here instead ended
                // the caller's event loop over an ordinary user action — a
                // parent whose popup is still open is a SUPPORTED
                // configuration, so the person clicking its close button must
                // not take the application down. The direct `closeWindow`
                // caller still receives the typed refusal; only the platform
                // event path treats it as the non-event it is.
                if (self.closeWindow(handle)) |closed| {
                    _ = closed;
                } else |err| switch (err) {
                    error.ChildWindowsOpen => {},
                    else => |fatal| return fatal,
                }
                break :blk null;
            },
            else => try self.routeWindow(raw),
        };
        if (event) |value| {
            if (self.hooks.on_event) |callback| try callback(self.hooks.context.?, self, value);
        }
        return event;
    }

    fn displayChanged(
        self: *Application,
        id: sdl3.video.Display,
        kind: DisplayChangeKind,
    ) !Event {
        const target = display.fromNative(id);
        const previous = self.displays.get(target);
        // A display event for a display SDL no longer enumerates is reported
        // as an unreadable reading rather than as a failed dispatch: the
        // event happened, and the event loop must survive hearing it.
        const current: ?display.Info = if (kind == .removed)
            null
        else
            display.query(target) catch null;
        if (current) |info| {
            // A snapshot that cannot record a display it has never seen keeps
            // the readings it already holds. The reading this event carries
            // rides in the payload below either way, so the same rule as the
            // query above holds: the event happened, and the loop survives it.
            self.displays.put(info) catch |err| std.log.warn(
                "display snapshot cannot record display {d}: {s}",
                .{ @backingInt(info.id), @errorName(err) },
            );
        } else {
            self.displays.remove(target);
        }
        // A display event re-reads the windows it draws, so each of them sees
        // the display's new reading immediately. That re-read is a probe: it
        // reaches no consumer, so it leaves `scale_notice` alone and the
        // window's own next event still reports a transition this probe saw
        // land. Nothing here is synthesized either — the display's own delta
        // below is the display-level delivery, and it stands on its own.
        for (self.slots.items) |slot| {
            if (slot.window) |window| {
                if (window.observed.display == target) {
                    if (kind != .removed) try window.refresh();
                    window.demand.invalidateLayout();
                }
            }
        }
        return .{ .display = .{
            .id = target,
            .kind = kind,
            .delta = display.diff(previous, current),
            .current = current,
        } };
    }

    fn routeWindow(self: *Application, raw: *const sdl3.events.Event) !?Event {
        const target: struct { id: ?sdl3.video.WindowId, timestamp: u64 } = switch (raw.*) {
            inline .window_shown,
            .window_hidden,
            .window_exposed,
            .window_moved,
            .window_resized,
            .window_pixel_size_changed,
            .window_minimized,
            .window_maximized,
            .window_restored,
            .window_focus_gained,
            .window_focus_lost,
            .window_mouse_enter,
            .window_mouse_leave,
            .window_display_changed,
            .window_display_scale_changed,
            .window_occluded,
            .window_enter_fullscreen,
            .window_leave_fullscreen,
            => |value| .{
                .id = @as(?sdl3.video.WindowId, value.id),
                .timestamp = value.common.timestamp,
            },
            inline .mouse_motion,
            .mouse_button_down,
            .mouse_button_up,
            .mouse_wheel,
            .key_down,
            .key_up,
            .text_input,
            .text_editing,
            .finger_down,
            .finger_motion,
            .finger_up,
            .finger_canceled,
            => |value| .{ .id = value.window_id, .timestamp = value.common.timestamp },
            else => return null,
        };
        const handle = if (target.id) |id|
            self.native_windows.get(id) orelse return null
        else blk: {
            // A null SDL input target is ambiguous when several windows are live.
            if (self.window_count != 1) return null;
            for (self.slots.items, 0..) |slot, index| {
                if (slot.window != null) break :blk self.handleFor(@intCast(index));
            }
            unreachable;
        };
        const window = try self.getWindow(handle);
        if (target.timestamp < window.created_ns) return null;
        // ONE client measurement for this event, taken before anything reads
        // it. The observed state this window publishes, the extents the routed
        // event reports and the logical box a finger is normalized against are
        // three views of the same value; two independent queries can straddle
        // a resize or a display-scale change and answer differently, and the
        // consumer then holds two sizes for one event.
        const extents = try window.native.clientExtent();
        var state_changed = false;
        switch (raw.*) {
            inline .window_resized,
            .window_pixel_size_changed,
            .window_display_changed,
            .window_display_scale_changed,
            .window_moved,
            .window_minimized,
            .window_maximized,
            .window_restored,
            .window_shown,
            .window_hidden,
            .window_occluded,
            .window_focus_gained,
            .window_focus_lost,
            .window_enter_fullscreen,
            .window_leave_fullscreen,
            => {
                try window.refreshAt(extents);
                state_changed = true;
            },
            else => {},
        }
        switch (raw.*) {
            .window_exposed, .window_shown, .window_restored => window.demand.requestPresentation(),
            else => {},
        }
        // A re-read is a layout input, whatever tag carried it. The switch
        // above reports `scale_changed` for EVERY event that re-read the
        // window, and a window moved between two outputs, restored from a
        // minimize, or taken in and out of fullscreen changes its pixel box
        // without ever arriving as a resize. Arming layout from the event tag
        // instead of from the re-read left those transitions reported to a
        // consumer with no frame behind them: the consumer was told to
        // re-rasterize at a new device scale and the host then asked for
        // nothing, so pointer, IME and render coordinates kept describing the
        // window as it was before the change.
        if (state_changed) window.demand.invalidateLayout();
        const translated = window.native.translate(raw, extents);
        // Diffed against the last reading a CONSUMER was given, not against
        // the last one this host took, so the answer is "the scale moved" and
        // not "an event of this tag arrived" — and a display event or a resume
        // that re-read this window in between cannot swallow the transition.
        // Compositors differ in which of the two scale routes they use, and
        // the routed event is the same fact either way.
        //
        // The baseline advances AFTER the event is built and before this
        // function returns, with nothing left that can fail. Advancing it
        // earlier would let a failed translation or a throwing `on_event`
        // consume a transition that reached nobody, and `ScaleNotice` exists
        // so that no path advances the baseline without answering for it.
        const scale_changed = if (state_changed)
            window.scale_notice.measure(ScaleReading.capture(window.observed))
        else
            false;
        return .{ .window = .{
            .handle = handle,
            .translated = translated,
            .state_changed = state_changed,
            .scale_changed = scale_changed,
        } };
    }

    /// One drag phase for the live window that owns `native_id`. The window
    /// lookup is the same generational and timestamp check every other native
    /// event passes, so a phase SDL queued for a window this host has since
    /// replaced reaches nobody.
    fn routeDrop(
        self: *Application,
        raw: *const sdl3.events.Event,
        native_id: sdl3.video.WindowId,
        timestamp: u64,
    ) !?Event {
        const handle = self.native_windows.get(native_id) orelse return null;
        const window = try self.getWindow(handle);
        if (timestamp < window.created_ns) return null;
        const phase = self.drop_tracker.translate(raw) orelse return null;
        return .{ .drop = .{
            .handle = handle,
            .phase = phase.phase,
            .position = phase.position,
            .offer = phase.offer,
        } };
    }

    /// One nonblocking event batch, then task delivery and ready frame callbacks.
    pub fn step(self: *Application) !bool {
        if (self.frame_callback_active) return error.LifecycleReentry;
        if (!self.running) return false;
        try self.start();
        if (self.wake_failed.swap(false, .acq_rel)) return error.SdlTaskWakeFailed;
        var processed: usize = 0;
        while (processed < 256) : (processed += 1) {
            const raw = self.pollEvent() orelse break;
            _ = try self.dispatch(&raw);
            if (!self.running) return false;
        }
        _ = try self.session.drainTasks();
        try self.updateFrames();
        self.expireQuit();
        return self.running;
    }

    fn updateFrames(self: *Application) !void {
        const now = sdl3.timer.getMillisecondsSinceInit();
        for (self.slots.items) |slot| {
            const window = slot.window orelse continue;
            try window.app.tickShortcuts();
            if (try self.session.takeRedraw(window.app.window)) window.demand.invalidateLayout();
            const callback = self.hooks.on_frame orelse continue;
            const work = takeWindowWork(
                &window.demand,
                window.app.animationDemand(now, 16).deadline_ms,
                now,
            ) orelse continue;
            const capture_timing = if (window.inspector) |active|
                active.frame_collector.enabled
            else
                false;
            const started_ns: u64 = if (capture_timing) sdl3.timer.getNanosecondsSinceInit() else 0;
            const previous_generation = window.app.frame_generation;
            const success = blk: {
                self.frame_callback_active = true;
                defer self.frame_callback_active = false;
                break :blk callback(self.hooks.context.?, self, window, work) catch |err| {
                    window.demand.finish(false);
                    return err;
                };
            };
            window.demand.finish(success);
            if (success and window.app.frame_generation != previous_generation) {
                // Read the endpoint after it publishes its final layout.
                // This also sends the line box and caret offset to SDL.
                _ = try window.app.text_input.caretGeometry();
                if (window.inspector) |active| {
                    const tree = window.app.tree_ptr orelse return error.MissingCommittedTree;
                    const finished_ns: u64 = if (capture_timing) sdl3.timer.getNanosecondsSinceInit() else 0;
                    const timestamp_ns: u64 = if (capture_timing) finished_ns else now * std.time.ns_per_ms;
                    const record: ?nogui.inspection.FrameRecord = if (capture_timing) .{
                        .frame_number = window.app.frame_generation,
                        .timestamp_ns = finished_ns,
                        .cpu_frame_ns = finished_ns - started_ns,
                    } else null;
                    try active.onFrame(.{
                        .frame_number = window.app.frame_generation,
                        .timestamp_ns = timestamp_ns,
                        .viewport = .{ .x = 0, .y = 0, .w = window.app.surface.width, .h = window.app.surface.height },
                        .tree = tree,
                        .focus_manager = &window.app.focus_manager,
                    }, record);
                }
            }
            if (success and work.present) {
                window.markPresented();
                window.app.framePresented(sdl3.timer.getMillisecondsSinceInit());
            }
        }
    }

    fn expireQuit(self: *Application) void {
        if (self.pending_quit) |pending| {
            if (sdl3.timer.getMillisecondsSinceInit() >= pending.deadline_ms) {
                self.pending_quit = null;
            }
        }
    }

    pub fn nextWaitMilliseconds(self: *Application) !?u31 {
        var timeout: ?u31 = null;
        const now_ms = sdl3.timer.getMillisecondsSinceInit();
        for (self.slots.items) |slot| {
            if (slot.window) |window| {
                if (self.hooks.on_frame != null) {
                    if (windowWaitMilliseconds(
                        &window.demand,
                        window.app.animationDemand(now_ms, 16).deadline_ms,
                        now_ms,
                    )) |delay| {
                        timeout = if (timeout) |old| @min(old, delay) else delay;
                    }
                }
                if (window.app.nextShortcutWaitMilliseconds()) |delay| {
                    timeout = if (timeout) |old| @min(old, delay) else delay;
                }
            }
        }
        if (self.pending_quit) |pending| {
            const delay: u31 = @intCast(@min(
                pending.deadline_ms -| now_ms,
                @as(u64, std.math.maxInt(u31)),
            ));
            timeout = if (timeout) |old| @min(old, delay) else delay;
        }
        if (self.session.task_service) |service| {
            if (try self.session.nextTaskDeadline()) |deadline| {
                const delay = nogui.frame_demand.taskDeadlineWaitMilliseconds(
                    service.clock.now(),
                    deadline,
                );
                timeout = if (timeout) |old| @min(old, delay) else delay;
            }
        }
        return timeout;
    }

    /// Own the SDL loop until quit; on_frame and on_event perform rendering and input.
    /// A zero-window keep-running policy returns to the caller for external reopening.
    pub fn run(self: *Application) !void {
        if (self.hooks.on_event == null or self.hooks.on_frame == null) {
            return error.MissingRunHooks;
        }
        try self.start();
        while (self.running) {
            if (!(try self.step())) break;
            if (self.window_count == 0 and self.pending_quit == null) break;
            const timeout = try self.nextWaitMilliseconds();
            const raw = if (timeout) |delay|
                sdl3.events.waitAndPopTimeout(delay)
            else
                try sdl3.events.waitAndPop();
            if (raw) |event| _ = try self.dispatch(&event);
        }
    }

    fn wakeFromTask(raw: *anyopaque) void {
        const self: *Application = @ptrCast(@alignCast(raw));
        var event: sdl3.c.SDL_Event = .{ .user = .{
            .type = self.wake_type,
            .reserved = 0,
            .timestamp = 0,
            .windowID = 0,
            .code = 0,
            .data1 = null,
            .data2 = null,
        } };
        if (!sdl3.c.SDL_PushEvent(&event)) self.wake_failed.store(true, .release);
    }

    pub fn deinit(self: *Application) void {
        if (self.wake_registered) {
            self.session.setTaskWake(null, null) catch @panic("task wake unregister failed");
            self.wake_registered = false;
        }
        self.hooks.on_close_request = null;
        self.closing = true;
        while (self.window_count > 0) {
            var closed = false;
            for (self.slots.items, 0..) |slot, index| {
                const window = slot.window orelse continue;
                const handle = self.handleFor(@intCast(index));
                if (self.hasChild(handle)) continue;
                self.destroyWindow(handle, window);
                closed = true;
                break;
            }
            std.debug.assert(closed);
        }
        // Every window is gone, so every parented request has already been
        // resolved. The manager releases what is left, and no lease outlives
        // the manager that owns it.
        self.dialogs.deinit();
        for (self.pending_launches.items) |launch| self.gpa.free(launch.value);
        self.pending_launches.deinit(self.gpa);
        self.displays.deinit();
        self.native_windows.deinit(self.gpa);
        self.slots.deinit(self.gpa);
        self.clipboard.deinit();
        sdl_session.release();
        self.* = undefined;
    }
};

fn textClipboardRead(allocator: std.mem.Allocator, _: *anyopaque) nogui.text_input.ClipboardRead {
    const bytes = host_clipboard.readText(allocator) catch return .failed;
    return if (bytes) |owned| .{ .text = owned } else .empty;
}

fn textClipboardWrite(user: *anyopaque, bytes: []const u8) nogui.text_input.ClipboardWrite {
    const clipboard: *host_clipboard.Clipboard = @ptrCast(@alignCast(user));
    clipboard.setText(bytes) catch return .failed;
    return .written;
}

fn earliestDeadline(first: ?u64, second: ?u64) ?u64 {
    return if (first) |a| if (second) |b| @min(a, b) else a else second;
}

fn takeWindowWork(demand: *FrameDemand, scalar_deadline: ?u64, now_ms: u64) ?FrameDemand.Work {
    const external_deadline = demand.deadline_ms;
    demand.deadline_ms = earliestDeadline(external_deadline, scalar_deadline);
    const work = demand.take(now_ms);
    // Scalar demand is derived, not caller-owned storage. Restore the image
    // deadline before the callback can replace it for its next frame.
    demand.deadline_ms = if (work != null and external_deadline != null and external_deadline.? <= now_ms)
        null
    else
        external_deadline;
    return work;
}

fn windowWaitMilliseconds(demand: *const FrameDemand, scalar_deadline: ?u64, now_ms: u64) ?u31 {
    if (!demand.visible) return null;
    if (demand.pending(now_ms)) return 0;
    const deadline = earliestDeadline(demand.deadline_ms, scalar_deadline) orelse return null;
    return @intCast(@min(deadline -| now_ms, @as(u64, std.math.maxInt(u31))));
}

fn quietDemand() FrameDemand {
    return .{ .layout_dirty = false, .paint_dirty = false, .present_dirty = false };
}

test "api-w14 external image deadline survives absent and earlier scalar demand" {
    var demand = quietDemand();
    demand.setDeadline(50);
    try std.testing.expectEqual(@as(?u31, 50), windowWaitMilliseconds(&demand, null, 0));
    try std.testing.expect(takeWindowWork(&demand, null, 0) == null);
    const scalar_work = takeWindowWork(&demand, 25, 25).?;
    try std.testing.expect(scalar_work.animation and scalar_work.paint);
    demand.finish(true);
    try std.testing.expectEqual(@as(?u31, 25), windowWaitMilliseconds(&demand, null, 25));
    const image_work = takeWindowWork(&demand, null, 50).?;
    try std.testing.expect(image_work.animation and image_work.present);
    demand.finish(true);
    try std.testing.expectEqual(@as(?u31, null), windowWaitMilliseconds(&demand, null, 50));
}

test "api-w14 canceled scalar demand leaves no stored ghost wake" {
    var demand = quietDemand();
    try std.testing.expectEqual(@as(?u31, 20), windowWaitMilliseconds(&demand, 20, 0));
    try std.testing.expectEqual(@as(?u64, null), demand.deadline_ms);
    try std.testing.expect(takeWindowWork(&demand, 20, 0) == null);
    try std.testing.expectEqual(@as(?u64, null), demand.deadline_ms);
    try std.testing.expectEqual(@as(?u31, null), windowWaitMilliseconds(&demand, null, 21));
    try std.testing.expect(takeWindowWork(&demand, null, 21) == null);
}

test "api-w14 hidden deadline survives and a failed due frame retries" {
    var demand = quietDemand();
    demand.setDeadline(50);
    demand.setVisible(false);
    try std.testing.expectEqual(@as(?u31, null), windowWaitMilliseconds(&demand, 25, 60));
    try std.testing.expect(takeWindowWork(&demand, 25, 60) == null);
    try std.testing.expectEqual(@as(?u64, 50), demand.deadline_ms);
    demand.setVisible(true);
    const work = takeWindowWork(&demand, 25, 60).?;
    try std.testing.expect(work.animation and work.paint);
    demand.finish(false);
    try std.testing.expectEqual(@as(?u31, 0), windowWaitMilliseconds(&demand, null, 60));
    const retry = takeWindowWork(&demand, null, 60).?;
    try std.testing.expect(retry.paint and retry.present);
    demand.finish(true);
    try std.testing.expectEqual(@as(?u31, null), windowWaitMilliseconds(&demand, null, 60));
}
