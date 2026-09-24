//! The one place this tree asks the platform to ring its desktop bell.
//!
//! A bell is a windowing-system request, not an accessibility-bridge call:
//! AccessKit's Unix adapter exposes no bell entry point and AT-SPI defines no
//! portable one. Each platform is therefore asked the way its own primary
//! source documents the request, and no platform is emulated by another.
//!
//!   * Linux X11 borrows SDL's own Xlib display, asks Xlib for the XCB
//!     connection inside it, and sends the core `Bell` request through xcb.
//!   * Linux Wayland binds the compositor's advertised `xdg_system_bell_v1` on a
//!     private event queue of its own, so the discovery never disturbs the queue
//!     SDL pumps, and sends `ring` from it.
//!   * macOS calls `NSBeep`, Windows calls `MessageBeep(MB_OK)`.
//!
//! `Result.rung` means the platform accepted the request. The Wayland protocol
//! itself lets a compositor answer a ring with a sound, with a visual cue, or
//! with nothing at all, so nothing here ever claims that a sound was produced.
//!
//! What a provider owns is exactly what it allocated: the shared-library
//! mappings it resolved, the private event queue and the bound bell proxy. The
//! SDL window, the Xlib display, the XCB connection inside it, the `wl_display`
//! and the `wl_surface` are borrowed and are never closed here.
const std = @import("std");
const builtin = @import("builtin");
const sdl3 = @import("sdl3");
const wayland = @import("linux/wayland.zig");

/// What asking for a bell answered.
///
/// One type carries every answer a caller has to report, so this module, the
/// window that owns the binding and the caller all speak one vocabulary. This
/// module produces `rung`, `unsupported` and `provider_failed`. The other two
/// are facts about the binding rather than about a platform: only the window
/// knows that it is closed, and only it knows which thread owns it.
pub const Result = enum {
    /// The platform accepted the request.
    rung,
    /// No bell exists here. Either the platform or the video driver has none,
    /// or nothing is bound that could ask for one.
    unsupported,
    /// The bound window is gone.
    window_closed,
    /// The request came from a thread that does not own the window.
    wrong_thread,
    /// A bell does apply here and this provider failed: its library, its
    /// transport or its compositor refused the request.
    provider_failed,
};

/// The observer a window owner installs to hear that its window closed.
///
/// The bell provider never calls it. Closure is the window's fact and not the
/// bell's, so the owner that records it is the one that notifies. The record
/// lives here so an owner and its caller can name one type.
pub const Owner = struct {
    context: *anyopaque,
    on_closed: *const fn (*anyopaque) void,
};

/// A bell bound to one window, or the typed reason there is none.
///
/// `init` neither fails nor traps. An inapplicable platform and an applicable
/// backend that could not be reached are both values, so a caller can hold a
/// provider for any window without first branching on the platform.
///
/// A provider is a value. Moving one moves pointers and never moves a native
/// object, and nothing it holds points back into itself, so the window that owns
/// it may be relocated or copied freely.
pub const Provider = struct {
    /// The tagged payload. Its type is private to this file, so a consumer can
    /// store, move and copy a `Provider` but cannot name a native handle
    /// through it.
    backend: Backend,

    /// Resolve the bell for `window`, which the caller keeps owning.
    ///
    /// On Wayland this performs one round trip to the compositor, so it is
    /// called on the thread that owns the window and never from inside an
    /// event callback.
    pub fn init(window: sdl3.video.Window) Provider {
        return .{ .backend = initBackend(window) };
    }

    /// True when this provider can ring. False for both "there is no bell here"
    /// and "a bell applies and could not be reached": neither can ring, and
    /// `ring` reports which of the two it was.
    pub fn available(self: *const Provider) bool {
        return switch (self.backend) {
            .x11, .wayland, .macos, .windows => true,
            .unsupported, .failed => false,
        };
    }

    /// Ask the platform for one ring.
    ///
    /// This allocates nothing, copies no provider state, and never changes the
    /// volume the user selected.
    pub fn ring(self: *Provider) Result {
        // No prong captures the payload, so the switch reads the tag only and
        // each ring runs against the state where it already lives.
        return switch (self.backend) {
            .unsupported => .unsupported,
            .failed => .provider_failed,
            .macos => macosRing(),
            .windows => windowsRing(),
            .x11 => x11Ring(&self.backend.x11),
            .wayland => waylandRing(&self.backend.wayland),
        };
    }

    /// Release everything this provider owns, and nothing else.
    ///
    /// Call it once, on the thread that owns the window, after the last ring.
    /// A provider that holds nothing releases nothing, so an unconditional
    /// release is right for every provider this module produces.
    pub fn deinit(self: *Provider) void {
        switch (self.backend) {
            .unsupported, .failed, .macos, .windows => {},
            .x11 => self.backend.x11.deinit(),
            .wayland => self.backend.wayland.deinit(),
        }
        self.* = undefined;
    }
};

const Backend = union(enum) {
    /// No platform or video driver here carries a bell.
    unsupported,
    /// A bell applies here and could not be reached.
    failed,
    x11: X11,
    wayland: Wayland,
    /// The platform answers a bell without a windowing library to resolve.
    macos,
    windows,
};

fn initBackend(window: sdl3.video.Window) Backend {
    // Each target takes its branch at comptime, so a build never analyses the
    // natives of a platform it is not running. An entry point that is never
    // analysed is an entry point that is never referenced, which is what keeps
    // a foreign target from failing to link on a symbol it has no definition
    // for.
    if (comptime builtin.os.tag == .linux) {
        // The driver decides, not the window properties. `dummy` and `offscreen`
        // publish no native handle at all, so reading properties first would
        // report the same answer without saying why, and a driver that did
        // publish one would be claimed by accident.
        const driver = sdl3.video.getCurrentDriverName() orelse return .unsupported;
        if (std.mem.eql(u8, driver, "x11")) return x11Backend(window);
        if (std.mem.eql(u8, driver, "wayland")) return waylandBackend(window);
        return .unsupported;
    }
    if (comptime builtin.os.tag == .macos) return .macos;
    if (comptime builtin.os.tag == .windows) return .windows;
    return .unsupported;
}

// -- Linux X11 --

/// Opaque Xlib `Display *`. Only libX11 dereferences it.
const X11Display = opaque {};
/// Opaque `xcb_connection_t *`. Only libxcb dereferences it.
const XcbConnection = opaque {};

/// `xcb_connection_t *XGetXCBConnection(Display *dpy)` from `X11/Xlib-xcb.h`.
const XGetXcbConnectionFn = *const fn (dpy: *anyopaque) callconv(.c) ?*XcbConnection;
/// `void xcb_bell(xcb_connection_t *c, int8_t percent)` from `xcb/xproto.h`. The
/// percent is one signed byte because the X protocol carries it as a CARD8, and
/// zero is the value that rings without changing the volume.
const XcbBellFn = *const fn (c: *XcbConnection, percent: i8) callconv(.c) void;
/// `int xcb_flush(xcb_connection_t *c)` from `xcb/xcb.h`: greater than zero on
/// success, at most zero otherwise.
const XcbFlushFn = *const fn (c: *XcbConnection) callconv(.c) c_int;
/// `int xcb_connection_has_error(xcb_connection_t *c)` from `xcb/xcb.h`: greater
/// than zero once the connection is unusable, zero while it is alive.
const XcbHasErrorFn = *const fn (c: *XcbConnection) callconv(.c) c_int;

/// `XGetXCBConnection` with the mapping that exports it.
const X11Bridge = struct {
    object: sdl3.SharedObject,
    get_xcb_connection: XGetXcbConnectionFn,
};

/// The xcb request helpers a bell needs, with the mapping that exports them.
const XcbApi = struct {
    object: sdl3.SharedObject,
    bell: XcbBellFn,
    flush: XcbFlushFn,
    has_error: XcbHasErrorFn,
};

/// The sonames that may carry `XGetXCBConnection`. Which library exports it is a
/// packaging fact rather than a protocol one: a stock libX11 can carry it, and
/// a distribution that builds `X11-xcb.c` as a library of its own carries it
/// there instead. Both families are asked in turn and the first mapping that
/// exports the symbol is the one used, so neither answer is assumed.
const bridge_sonames = [_][:0]const u8{
    "libX11-xcb.so.1",
    "libX11-xcb.so",
    "libX11.so.6",
    "libX11.so",
};
/// The sonames that carry the xcb request helpers.
const xcb_sonames = [_][:0]const u8{
    "libxcb.so.1",
    "libxcb.so",
};

fn loadBridge() ?X11Bridge {
    for (bridge_sonames) |soname| {
        const object = sdl3.SharedObject.load(soname) catch continue;
        const get_xcb_connection = symbolOf(XGetXcbConnectionFn, object, "XGetXCBConnection") orelse {
            object.unload();
            continue;
        };
        return .{ .object = object, .get_xcb_connection = get_xcb_connection };
    }
    return null;
}

fn loadXcb() ?XcbApi {
    for (xcb_sonames) |soname| {
        const object = sdl3.SharedObject.load(soname) catch continue;
        const bell = symbolOf(XcbBellFn, object, "xcb_bell") orelse {
            object.unload();
            continue;
        };
        const flush = symbolOf(XcbFlushFn, object, "xcb_flush") orelse {
            object.unload();
            continue;
        };
        const has_error = symbolOf(XcbHasErrorFn, object, "xcb_connection_has_error") orelse {
            object.unload();
            continue;
        };
        return .{ .object = object, .bell = bell, .flush = flush, .has_error = has_error };
    }
    return null;
}

fn symbolOf(comptime Proto: type, object: sdl3.SharedObject, name: [:0]const u8) ?Proto {
    const raw = object.loadFunction(name) catch return null;
    return @ptrCast(@alignCast(raw));
}

const X11 = struct {
    bridge: X11Bridge,
    xcb: XcbApi,
    /// Borrowed: SDL's Xlib display, published as
    /// `SDL_PROP_WINDOW_X11_DISPLAY_POINTER`. Never closed here.
    display: *X11Display,
    /// Borrowed: the XCB connection inside that display. Never disconnected
    /// here; it belongs to the display SDL opened.
    connection: *XcbConnection,

    fn deinit(self: *X11) void {
        // Only the mappings are released. The display is SDL's and the
        // connection is the display's, so neither is touched on the way out.
        self.bridge.object.unload();
        self.xcb.object.unload();
        self.* = undefined;
    }
};

const X11Error = error{
    /// SDL published no Xlib display for this window.
    DisplayUnavailable,
    /// No candidate soname carried the entry points a bell needs.
    ClientLibraryMissing,
    /// This Xlib display has no XCB connection inside it.
    NoXcbConnection,
};

fn x11Backend(window: sdl3.video.Window) Backend {
    const live = x11Init(window) catch return .failed;
    return .{ .x11 = live };
}

fn x11Init(window: sdl3.video.Window) X11Error!X11 {
    const properties = window.getProperties() catch return error.DisplayUnavailable;
    const published = properties.x11_display orelse return error.DisplayUnavailable;
    const raw = published.value orelse return error.DisplayUnavailable;

    const bridge = loadBridge() orelse return error.ClientLibraryMissing;
    errdefer bridge.object.unload();
    const xcb = loadXcb() orelse return error.ClientLibraryMissing;
    errdefer xcb.object.unload();

    // The connection inside SDL's display is the one that display already
    // authenticated and already flushes, so the bell needs no second connection
    // and no XAUTHORITY handling of its own.
    const connection = bridge.get_xcb_connection(raw) orelse return error.NoXcbConnection;
    return .{
        .bridge = bridge,
        .xcb = xcb,
        .display = @ptrCast(raw),
        .connection = connection,
    };
}

fn x11Ring(self: *const X11) Result {
    // A connection the server has stopped serving carries no request, so the
    // error is read before anything is sent rather than after.
    if (self.xcb.has_error(self.connection) != 0) return .provider_failed;
    // The core `Bell` request. Percent 0 is the protocol's "ring without
    // changing the volume", which is what leaves the user's own setting alone.
    self.xcb.bell(self.connection, 0);
    // xcb documents greater than zero on success, so anything else means the
    // request did not reach the server and nothing was rung.
    const sent = self.xcb.flush(self.connection);
    if (sent <= 0) return .provider_failed;
    return if (self.xcb.has_error(self.connection) == 0) .rung else .provider_failed;
}

// -- Linux Wayland --

/// The global this provider binds, spelled the way the registry advertises it.
const bell_global = "xdg_system_bell_v1";

/// The advertisement a round trip collects.
///
/// It is a local of `waylandInit`: the registry that feeds it is destroyed
/// before that call returns, so nothing can dispatch into this value after it
/// has gone out of scope.
const BellScan = struct {
    name: ?u32 = null,
    version: u32 = 0,
};

fn onGlobal(
    data: ?*anyopaque,
    registry: *wayland.Registry,
    name: u32,
    interface: [*:0]const u8,
    version: u32,
) callconv(.c) void {
    _ = registry;
    const scan: *BellScan = @ptrCast(@alignCast(data orelse return));
    if (!std.mem.eql(u8, std.mem.span(interface), bell_global)) return;
    scan.name = name;
    scan.version = version;
}

fn onGlobalRemove(data: ?*anyopaque, registry: *wayland.Registry, name: u32) callconv(.c) void {
    // A global withdrawn before the round trip answered is a global this
    // binding must not keep. Reporting it absent refuses by name rather than
    // binding something the compositor has already dropped.
    _ = registry;
    const scan: *BellScan = @ptrCast(@alignCast(data orelse return));
    if (scan.name == name) scan.name = null;
}

const registry_listener: wayland.RegistryListener = .{
    .global = onGlobal,
    .global_remove = onGlobalRemove,
};

const Wayland = struct {
    api: wayland.Api,
    /// Borrowed: SDL's `wl_display`, published as
    /// `SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER`. Never disconnected here.
    display: *wayland.Display,
    /// The window's `wl_surface` when that window has a toplevel role, else
    /// the protocol's null. Borrowed either way: the window owns the surface.
    surface: ?*wayland.Proxy,
    /// Owned: the private event queue this provider works on. The registry the
    /// discovery ran through and the bound bell are both attached to it, so
    /// neither can deliver an event into the queue SDL dispatches.
    queue: *wayland.EventQueue,
    /// Owned: the bound `xdg_system_bell_v1`.
    bell: *wayland.Proxy,

    fn deinit(self: *Wayland) void {
        const api = &self.api;
        // The destructor goes on the wire before anything else is released, so
        // the compositor is told the object is finished with instead of holding
        // it until this connection closes. The marshal carries the destroy flag,
        // so the same call also frees the local proxy.
        _ = api.proxy_marshal_flags(
            self.bell,
            wayland.opcode.xdg_system_bell_destroy,
            null,
            api.proxy_get_version(self.bell),
            wayland.marshal_destroy,
        );
        _ = api.display_flush(self.display);
        // The bell is gone before the queue that carried its discovery.
        api.event_queue_destroy(self.queue);
        // Last: the mapping those entry points live in goes only after every
        // proxy and the queue that call it have been released.
        api.deinit();
        self.* = undefined;
    }
};

const WaylandError = error{
    /// SDL published no Wayland display or surface for this window.
    DisplayUnavailable,
    /// libwayland-client could not be resolved through SDL's own loader.
    ClientLibraryMissing,
    /// No private event queue could be created for the discovery.
    QueueUnavailable,
    /// The discovery round trip itself failed.
    DiscoveryFailed,
    /// The compositor advertises no `xdg_system_bell_v1`.
    GlobalAbsent,
    /// The advertised global refused to bind.
    BindFailed,
};

fn waylandBackend(window: sdl3.video.Window) Backend {
    const live = waylandInit(window) catch |err| return switch (err) {
        // Wayland has this protocol and this compositor does not implement it,
        // which is a capability this host lacks rather than one that failed.
        error.GlobalAbsent => .unsupported,
        else => .failed,
    };
    return .{ .wayland = live };
}

fn waylandInit(window: sdl3.video.Window) WaylandError!Wayland {
    const properties = window.getProperties() catch return error.DisplayUnavailable;
    const published_display = properties.wayland_display orelse return error.DisplayUnavailable;
    const raw_display = published_display.value orelse return error.DisplayUnavailable;
    const published_surface = properties.wayland_surface orelse return error.DisplayUnavailable;
    const raw_surface = published_surface.value orelse return error.DisplayUnavailable;

    var api = wayland.Api.load(wayland.sdlLoader()) catch return error.ClientLibraryMissing;
    errdefer api.deinit();
    const display: *wayland.Display = @ptrCast(raw_display);

    // A queue of this provider's own. The registry below is built on it and the
    // round trip runs on it, so the discovery can never dispatch one of SDL's
    // events out of the queue SDL pumps.
    const queue = api.display_create_queue(display) orelse return error.QueueUnavailable;
    errdefer api.event_queue_destroy(queue);

    // The registry is created through a wrapper that sits on the private queue,
    // never through the SDL display itself. A queue decides where a proxy's
    // incoming events are delivered, so requeueing SDL's display proxy would
    // take the display itself, and everything created through it afterwards,
    // off the queue SDL dispatches. The registry inherits the wrapper's queue as
    // it is created, and the wrapper is dropped the moment that has happened.
    // This is the shape SDL uses for its own side round trips, in
    // `SDL_waylandopengles.c` and `SDL_waylandmouse.c`.
    const wrapper = api.proxy_create_wrapper(@ptrCast(display)) orelse return error.DiscoveryFailed;
    api.proxy_set_queue(wrapper, queue);
    const registry = api.displayGetRegistry(@ptrCast(wrapper)) orelse {
        api.proxy_wrapper_destroy(wrapper);
        return error.DiscoveryFailed;
    };
    api.proxy_wrapper_destroy(wrapper);
    // The registry dies with this call, and it does so before the listener and
    // the scan it feeds leave scope, so no callback can outlive both.
    defer api.proxy_destroy(@ptrCast(registry));

    var scan: BellScan = .{};
    if (api.proxy_add_listener(@ptrCast(registry), @ptrCast(&registry_listener), &scan) != 0) {
        return error.DiscoveryFailed;
    }
    if (api.display_roundtrip_queue(display, queue) < 0) return error.DiscoveryFailed;
    const advertised = scan.name orelse return error.GlobalAbsent;

    // The bell is bound on the registry and then attached to the same private
    // queue this provider owns. A queue decides where a proxy's incoming events
    // are delivered, so this is what keeps anything the provider owns from
    // delivering an event into the queue SDL dispatches. The interface declares
    // no events at all, so nothing will ever arrive for it either way.
    const bell = api.registryBind(
        registry,
        advertised,
        &wayland.system_bell_interface,
        @min(scan.version, @as(u32, @intCast(wayland.system_bell_interface.version))),
    ) orelse return error.BindFailed;
    api.proxy_set_queue(bell, queue);
    // Submit the binding without blocking. EAGAIN keeps it in the display's
    // output buffer; a connection fault is reported by the ring path.
    _ = api.display_flush(display);

    // The protocol asks for a toplevel-like surface or for null, so the surface
    // is named only when SDL published a toplevel role for this window. A
    // popup, a roleless surface and a layer-shell surface have no such role,
    // and the unassociated ring the protocol offers is what those get.
    const toplevel_role = properties.wayland_xdg_toplevel;
    const toplevel_like = toplevel_role != null and toplevel_role.?.value != null;
    var surface: ?*wayland.Proxy = null;
    if (toplevel_like) surface = @ptrCast(raw_surface);

    return .{
        .api = api,
        .display = display,
        .surface = surface,
        .queue = queue,
        .bell = bell,
    };
}

fn waylandRing(self: *const Wayland) Result {
    if (comptime builtin.os.tag != .linux) return .provider_failed;
    const api = &self.api;
    // A display the compositor has stopped serving answers nothing, and its
    // error is permanent: a request sent now would never be delivered.
    if (api.display_get_error(self.display) != 0) return .provider_failed;
    _ = api.proxy_marshal_flags(
        self.bell,
        wayland.opcode.xdg_system_bell_ring,
        null,
        api.proxy_get_version(self.bell),
        0,
        self.surface,
    );
    const sent = api.display_flush(self.display);
    // `wl_display_flush` never blocks: it writes what it can and, when the
    // socket refused the rest, answers -1 with EAGAIN while keeping the request
    // in the client buffer for the display's next flush. That request was
    // accepted. Any other errno is a transport fault.
    if (sent >= 0 or std.posix.errno(sent) == .AGAIN) return .rung;
    return .provider_failed;
}

// -- macOS and Windows --

/// `void NSBeep(void)` from `<AppKit/NsSound.h>`: the system sound, played at
/// the volume the user chose. The symbol arrives with the frameworks SDL
/// already links, so this declares no link step of its own.
extern fn NSBeep() void;

/// `MB_OK` from `winuser.h`: the Windows default beep.
const mb_ok: u32 = 0x0000_0000;

/// `BOOL WINAPI MessageBeep(UINT uType)` from `winuser.h`. `BOOL` is a signed
/// 32-bit result, which is why the declaration says `i32` and not a boolean.
extern "user32" fn MessageBeep(uType: u32) callconv(.winapi) i32;

fn macosRing() Result {
    // Every reference to a target-only entry point opens with this guard. The
    // branch is comptime, so a build for another target never analyses the
    // call below, never emits a reference to it, and so never fails to link on
    // a symbol that target has no definition for. The same rule is why
    // `macos/native.zig` guards each call into its shim.
    if (comptime builtin.os.tag != .macos) return .provider_failed;
    NSBeep();
    // There is no result to read. The request reached the audio system, and
    // whether that system makes a sound is its answer, not this one's.
    return .rung;
}

fn windowsRing() Result {
    if (comptime builtin.os.tag != .windows) return .provider_failed;
    // Non-zero means the sound played, or that a user policy silenced it. Zero
    // means the request itself was refused, which is a provider fault and not a
    // ring.
    return if (MessageBeep(mb_ok) != 0) .rung else .provider_failed;
}
