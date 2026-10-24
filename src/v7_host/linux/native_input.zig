//! Real pointer input for a native popup's parent, and a real pointer grab on
//! an X11 display server.
//!
//! Two things a popup needs from the platform that no request this tree sends
//! can stand in for: the serial of the user event that asked for the popup,
//! and a grab the display server is actually holding.
//!
//!   * `ParentInput` binds this connection's own `wl_seat` and the `wl_pointer`
//!     off it, on a private event queue of its own, and latches the serial of
//!     a real `wl_pointer.button` press — and only while the compositor says
//!     the parent's own `wl_surface` holds the pointer focus. A serial is never
//!     copied from a configure, never counted up, and never taken from a
//!     surface that is not this parent. The private queue is the reason the
//!     latch costs the host nothing: a queue decides where a proxy's events are
//!     delivered, so nothing bound here can deliver an event into the queue
//!     SDL dispatches, and dispatching here never reads SDL's queue.
//!   * `X11Grab` opens one private XCB connection to SDL's actual X display.
//!     SDL's own crossing-event handlers may ungrab its connection, so a native
//!     popup grab cannot share that connection. The server acknowledges the
//!     grab and delivers popup-addressed presses to this private input queue.
//!
//! Wayland borrows the caller's API mapping, SDL display and parent surface,
//! and owns its listener proxies, event queue and stable allocator block.
//! X11 borrows the SDL display only to read its display name during `create`;
//! it owns its connection and library mappings. Neither path closes SDL.
const std = @import("std");
const sdl3 = @import("sdl3");
const wayland = @import("wayland.zig");

/// Everything these two paths can fail for beyond the popup contract itself.
/// The names say which half failed and why, so a caller never has to guess
/// whether it lost a serial, a library or a display-server refusal.
pub const InputError = error{
    /// The stable listener owner could not be allocated.
    OutOfMemory,
    /// libwayland refused a listener, so an event this path needs would be
    /// dropped without anyone noticing. That is refused rather than ignored:
    /// a latch that hears nothing and reports nothing is worse than one that
    /// never started.
    ListenerRejected,
    /// The video driver is not the one this path speaks. A driver with no
    /// display server behind it, or one with a different one, has no protocol
    /// here to bind, so the request is refused by name rather than attempted
    /// against a connection that cannot carry it.
    NotThisDisplayServer,
    /// SDL published no native handle for this window that the request needs.
    NativeHandleUnavailable,
    /// No private event queue could be created on SDL's own display. Input
    /// that must not disturb the host's queue has no other way to run, so this
    /// is a refusal and not a queue this tree shares with the host.
    EventQueueUnavailable,
    /// The compositor advertises no `wl_seat` global, so this connection has no
    /// input device to take a serial from.
    SeatGlobalAbsent,
    /// The seat advertises no pointer capability, so it offers no `wl_pointer`
    /// and no button press on this connection can ever arrive.
    SeatPointerAbsent,
    /// The connection refused to carry a round trip or a dispatch, which means
    /// the display is broken. Nothing read now would ever arrive.
    ConnectionFailed,
    /// No candidate soname carried the entry points a grab needs.
    GrabClientLibraryMissing,
    /// The display server refused the grab. The refusal came from the server:
    /// `GrabPointer` answers with a status, and anything but success leaves the
    /// pointer where it was rather than held.
    NativeGrabRefused,
    /// The private X input queue received a protocol error.
    NativeInputRejected,
    /// This popup already holds a grab. Two grabs are not a stronger grab.
    GrabAlreadyHeld,
};

// -- Wayland: a real button press on the parent's own surface --

/// The advertisement the one registry round trip collects.
///
/// It is a local of `ParentInput.create`: the registry that feeds it is
/// destroyed before that call returns, so nothing can dispatch into this value
/// after it has gone out of scope.
const SeatScan = struct {
    name: ?u32 = null,
    version: u32 = 0,
};

fn onSeatGlobal(
    data: ?*anyopaque,
    registry: *wayland.Registry,
    name: u32,
    interface: [*:0]const u8,
    version: u32,
) callconv(.c) void {
    _ = registry;
    const scan: *SeatScan = @ptrCast(@alignCast(data orelse return));
    if (!std.mem.eql(u8, std.mem.span(interface), "wl_seat")) return;
    // The first `wl_seat` is the one a single-client session has; a later one
    // is a hotplug the compositor never merges into the existing seat.
    if (scan.name != null) return;
    scan.name = name;
    scan.version = version;
}

fn onSeatGlobalRemove(data: ?*anyopaque, registry: *wayland.Registry, name: u32) callconv(.c) void {
    _ = registry;
    const scan: *SeatScan = @ptrCast(@alignCast(data orelse return));
    // A seat withdrawn before the round trip answered is a seat this binding
    // must not take: reporting it absent refuses by name rather than binding an
    // object the compositor has already dropped.
    if (scan.name == name) scan.name = null;
}

const seat_scan_listener: wayland.RegistryListener = .{
    .global = onSeatGlobal,
    .global_remove = onSeatGlobalRemove,
};

/// The pointer focus this latch will accept an event from.
///
/// Focus is the whole provenance: a button event is about this parent only
/// while the compositor says this parent's own surface holds the pointer, so
/// every other surface, and every loss of focus, leaves `surface` null and
/// makes a button event a stranger's event rather than this parent's.
const Focus = struct {
    /// Non-null only while the compositor says the parent's own `wl_surface`
    /// holds the pointer focus.
    surface: ?*wayland.Proxy = null,
    /// True while the seat advertises the pointer capability. A seat that
    /// withdraws it stops sending button events at all, so anything latched
    /// before that is stale the moment it happens.
    has_pointer: bool = false,
    /// The parent window was destroyed. Every surface this latch compared
    /// against went with it, so nothing it holds is still about this parent.
    parent_gone: bool = false,
    /// The serial of a real `wl_pointer.button` press, latched only while
    /// `surface` names the parent's own surface and handed out exactly once.
    press: ?u32 = null,
};

/// A button press on one real window, taken on a queue of this latch's own.
///
/// The value is heap allocated because libwayland calls the listeners with a
/// `data` pointer this latch's proxies were given, so the address has to
/// outlive the call that created them.
pub const ParentInput = struct {
    gpa: std.mem.Allocator,
    /// Borrowed: the caller's libwayland mapping. Every proxy and the queue
    /// below are released through it, so it has to outlive this latch; it is
    /// never unmapped here.
    api: wayland.Api,
    /// Borrowed: SDL's own `wl_display`. Never disconnected here.
    display: *wayland.Display,
    /// Borrowed: the parent window's `wl_surface`. The window owns it, so it is
    /// only ever compared against, never destroyed.
    parent_surface: *wayland.Proxy,
    /// Owned: the queue the seat, the pointer and the registry discovery all
    /// deliver on, so none of them can deliver into the queue SDL dispatches.
    queue: ?*wayland.EventQueue = null,
    /// Owned: this connection's own `wl_seat`, on that queue.
    seat: ?*wayland.Proxy = null,
    /// Owned: the `wl_pointer` off that seat, on the same queue.
    pointer: ?*wayland.Proxy = null,
    focus: Focus = .{},
    /// The pump that latched the newest press. A release retires the press it
    /// completes, but one that arrives in the very pump that latched that press
    /// does not: the caller has not been offered the serial yet, and
    /// `xdg_popup.grab` names the press and stays valid once the button is up.
    press_pump: u64 = 0,
    /// How many pumps have run, so the line above can name one.
    pump_index: u64 = 0,

    /// Bind a seat and a pointer for `parent`, which the caller keeps owning.
    ///
    /// `api` is the caller's libwayland mapping and has to outlive this latch.
    /// `create` performs three private-queue round trips: discover the seat,
    /// read its pointer capability, then install the pointer and collect focus.
    /// They borrow SDL's connection but dispatch only this latch's queue. Call
    /// this on the thread that owns the window.
    pub fn create(
        gpa: std.mem.Allocator,
        api: wayland.Api,
        parent: sdl3.video.Window,
    ) InputError!*ParentInput {
        // The driver decides, not the window properties: an X11 window
        // publishes no Wayland display at all, and reading properties first
        // would report the same refusal without saying why.
        const driver = sdl3.video.getCurrentDriverName() orelse
            return error.NotThisDisplayServer;
        if (!std.mem.eql(u8, driver, "wayland")) return error.NotThisDisplayServer;

        const props = parent.getProperties() catch return error.NativeHandleUnavailable;
        const raw_display = if (props.wayland_display) |v| v.value else null;
        const published_display = raw_display orelse return error.NativeHandleUnavailable;
        const raw_surface = if (props.wayland_surface) |v| v.value else null;
        const published_surface = raw_surface orelse return error.NativeHandleUnavailable;

        const self = try gpa.create(ParentInput);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .api = api,
            .display = @ptrCast(published_display),
            .parent_surface = @ptrCast(published_surface),
        };

        const display = self.display;
        const queue = api.display_create_queue(display) orelse
            return error.EventQueueUnavailable;
        self.queue = queue;
        // Everything this latch owns is released through this one rollback, in
        // the order `deinit` uses: proxies, then the queue they arrived on,
        // then the block. The borrowed display and mapping are never touched.
        errdefer self.release();

        // The registry is built through a wrapper that sits on the private
        // queue, never through SDL's display itself. A queue decides where a
        // proxy's events are delivered, so requeueing the display proxy would
        // take the display itself, and everything created through it
        // afterwards, off the queue SDL dispatches. The registry inherits the
        // wrapper's queue as it is created, and the wrapper is dropped the
        // moment that has happened. This is the shape SDL uses for its own
        // side round trips, in `SDL_waylandopengles.c` and
        // `SDL_waylandmouse.c`.
        const wrapper = api.proxy_create_wrapper(@ptrCast(display)) orelse
            return error.EventQueueUnavailable;
        api.proxy_set_queue(wrapper, queue);
        const registry = api.displayGetRegistry(@ptrCast(wrapper)) orelse {
            api.proxy_wrapper_destroy(wrapper);
            return error.EventQueueUnavailable;
        };
        api.proxy_wrapper_destroy(wrapper);
        // The registry answers one scan and then dies, before the listener and
        // the scan it feeds leave scope, so no callback can outlive either.
        defer api.proxy_destroy(@ptrCast(registry));

        var scan: SeatScan = .{};
        if (api.proxy_add_listener(
            @ptrCast(registry),
            @ptrCast(&seat_scan_listener),
            &scan,
        ) != 0) return error.EventQueueUnavailable;
        if (api.display_roundtrip_queue(display, queue) < 0) return error.ConnectionFailed;
        const advertised = scan.name orelse return error.SeatGlobalAbsent;

        // Core pointer constructors inherit the seat's version on the server.
        // Passing a lower client-side constructor version cannot downgrade it.
        const seat_version = @min(
            scan.version,
            @as(u32, @intCast(@min(
                wayland.wl_seat_interface.version,
                wayland.wl_pointer_interface.version,
            ))),
        );
        const seat = api.registryBind(
            registry,
            advertised,
            &wayland.wl_seat_interface,
            seat_version,
        ) orelse return error.SeatGlobalAbsent;
        self.seat = seat;
        // The seat is delivered on the private queue like the registry it was
        // bound through, and this makes that explicit rather than inherited.
        api.proxy_set_queue(seat, queue);
        if (api.proxy_add_listener(
            seat,
            @ptrCast(&seat_listener),
            self,
        ) != 0) return error.ListenerRejected;
        // The seat answers its own capabilities once and then whenever they
        // change. Until that answer arrives there is no way to know whether
        // this connection is offered a pointer, so the round trip is what makes
        // the answer exist rather than a guess at what a seat usually offers.
        if (api.display_roundtrip_queue(display, queue) < 0) return error.ConnectionFailed;
        if (!self.focus.has_pointer) return error.SeatPointerAbsent;

        const pointer = api.proxy_marshal_flags(
            seat,
            wayland.opcode.wl_seat_get_pointer,
            &wayland.wl_pointer_interface,
            seat_version,
            0,
            @as(?*wayland.Proxy, null),
        ) orelse return error.SeatPointerAbsent;
        self.pointer = pointer;
        api.proxy_set_queue(pointer, queue);
        if (api.proxy_add_listener(
            pointer,
            @ptrCast(&pointer_listener),
            self,
        ) != 0) return error.ListenerRejected;
        // Submit the binding without waiting for input. The flush keeps EAGAIN
        // in the display's own buffer, and the round trip that follows both
        // settles the request and delivers whatever focus the compositor has
        // for this parent right now.
        _ = api.display_flush(display);
        if (api.display_roundtrip_queue(display, queue) < 0) return error.ConnectionFailed;
        return self;
    }

    /// Deliver whatever arrived on this latch's own queue, without blocking.
    ///
    /// Only the private queue is dispatched. The host's queue is never read
    /// here, so pumping this latch cannot take an event out from under the
    /// host, and nothing is sent, so there is nothing to flush.
    pub fn pump(self: *ParentInput) InputError!void {
        const api = &self.api;
        // A display the compositor has stopped serving answers nothing, and its
        // error is permanent: nothing read now would ever arrive, so whatever
        // this latch was holding is stale by definition rather than by guess.
        if (api.display_get_error(self.display) != 0) {
            self.clearPress();
            return error.ConnectionFailed;
        }
        const queue = self.queue orelse return error.ConnectionFailed;
        self.pump_index +%= 1;
        if (api.display_dispatch_queue_pending(self.display, queue) < 0) {
            self.clearPress();
            return error.ConnectionFailed;
        }
        // A seat that withdrew the pointer capability sends nothing more, and
        // this latch never sees the event that would clear the old serial.
        if (!self.focus.has_pointer) self.clearPress();
    }

    /// Hand out the latched press serial, once.
    ///
    /// A serial is consumed here or never: a caller that asks twice gets null
    /// the second time, because a `xdg_popup.grab` names one event and reusing
    /// a spent one would be this tree inventing provenance.
    pub fn takePress(self: *ParentInput) ?u32 {
        const serial = self.focus.press orelse return null;
        self.focus.press = null;
        return serial;
    }

    /// The parent window is gone. Every surface this latch compared against went
    /// with it, so the latched serial is dropped and no later button event can
    /// be read as an event on this parent again.
    pub fn onParentLost(self: *ParentInput) void {
        self.focus.parent_gone = true;
        self.focus.surface = null;
        self.clearPress();
    }

    /// True while the compositor says the parent's own surface holds the
    /// pointer focus, which is the only state a button event may be latched in.
    pub fn hasParentFocus(self: *const ParentInput) bool {
        return !self.focus.parent_gone and self.focus.surface == self.parent_surface;
    }

    /// Release everything this latch owns, then give its block back.
    ///
    /// `gpa` is read before the poison and the block is destroyed after it,
    /// because a poisoned handle is not one this value owns any more and a
    /// write past `destroy` would be the use-after-free this poisons for.
    /// `release` stays repeatable, as a failed `create` has to be able to roll
    /// back through it while the block this latch lives in is still live.
    pub fn deinit(self: *ParentInput) void {
        self.release();
        const gpa = self.gpa;
        defer gpa.destroy(self);
        self.* = undefined;
    }

    /// Drop everything this latch owns, in the only order that is safe: the
    /// pointer before the seat that made it, both before the queue they were
    /// delivered on, and the queue before the borrowed display goes.
    fn release(self: *ParentInput) void {
        self.clearPress();
        const api = &self.api;
        if (self.pointer) |pointer| {
            // `wl_pointer.release` arrived in version 3. A lower binding has no
            // destructor to send, and sending one anyway is a fatal protocol
            // error, so the local proxy is dropped instead.
            const version = api.proxy_get_version(pointer);
            if (wayland.pointerCanRelease(version)) {
                _ = api.proxy_marshal_flags(
                    pointer,
                    wayland.opcode.wl_pointer_release,
                    null,
                    version,
                    wayland.marshal_destroy,
                );
            } else api.proxy_destroy(pointer);
            self.pointer = null;
        }
        if (self.seat) |seat| {
            const version = api.proxy_get_version(seat);
            if (wayland.seatCanRelease(version)) {
                _ = api.proxy_marshal_flags(
                    seat,
                    wayland.destructor.wl_seat_release,
                    null,
                    version,
                    wayland.marshal_destroy,
                );
            } else api.proxy_destroy(seat);
            self.seat = null;
        }
        if (self.queue) |queue| {
            // The destructors above only go on the wire once the borrowed
            // display is flushed, and that flush needs the queue still there.
            _ = api.display_flush(self.display);
            api.event_queue_destroy(queue);
            self.queue = null;
        }
        // The mapping behind `api` is the caller's. This latch borrowed it and
        // never unmaps a library its owner still uses.
    }

    fn clearPress(self: *ParentInput) void {
        self.focus.press = null;
    }
};

fn onSeatCapabilities(data: ?*anyopaque, seat: *wayland.Proxy, capabilities: u32) callconv(.c) void {
    _ = seat;
    const self: *ParentInput = @ptrCast(@alignCast(data orelse return));
    self.focus.has_pointer =
        capabilities & wayland.pointer_wire.seat_capability_pointer != 0;
    // A withdrawn capability means no further button event will arrive, so
    // whatever was latched is stale the moment the seat says so.
    if (!self.focus.has_pointer) self.clearPress();
}

// The seat's name says which input device it is and nothing about provenance.
fn onSeatName(data: ?*anyopaque, seat: *wayland.Proxy, name: [*:0]const u8) callconv(.c) void {
    _ = data;
    _ = seat;
    _ = name;
}

const seat_listener: wayland.SeatListener = .{
    .capabilities = onSeatCapabilities,
    .name = onSeatName,
};

fn onPointerEnter(
    data: ?*anyopaque,
    pointer: *wayland.Proxy,
    serial: u32,
    surface: *wayland.Proxy,
    surface_x: i32,
    surface_y: i32,
) callconv(.c) void {
    _ = pointer;
    _ = serial;
    _ = surface_x;
    _ = surface_y;
    const self: *ParentInput = @ptrCast(@alignCast(data orelse return));
    if (self.focus.parent_gone) return;
    // Focus on this parent's own surface is the only focus a button event on
    // this parent may come from. Entering any other surface clears the record
    // rather than leaving the previous one standing.
    self.focus.surface = if (surface == self.parent_surface) surface else null;
    if (self.focus.surface == null) self.clearPress();
}

fn onPointerLeave(
    data: ?*anyopaque,
    pointer: *wayland.Proxy,
    serial: u32,
    surface: *wayland.Proxy,
) callconv(.c) void {
    _ = pointer;
    _ = serial;
    _ = surface;
    const self: *ParentInput = @ptrCast(@alignCast(data orelse return));
    // A leave always ends the focus the compositor had, so whatever this latch
    // recorded is gone whether or not it named this parent.
    self.focus.surface = null;
    self.clearPress();
}

fn onPointerMotion(
    data: ?*anyopaque,
    pointer: *wayland.Proxy,
    time: u32,
    surface_x: i32,
    surface_y: i32,
) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = time;
    _ = surface_x;
    _ = surface_y;
    // Motion carries no serial and changes no button state. It is here only
    // because libwayland dispatches an event by its index, so the slot has to
    // exist and has to do nothing.
}

fn onPointerButton(
    data: ?*anyopaque,
    pointer: *wayland.Proxy,
    serial: u32,
    time: u32,
    button: u32,
    state: u32,
) callconv(.c) void {
    _ = pointer;
    _ = time;
    _ = button;
    const self: *ParentInput = @ptrCast(@alignCast(data orelse return));
    if (self.focus.parent_gone) return;
    // The whole provenance, in one comparison: the button event is about this
    // parent only while the compositor says this parent's own surface holds
    // the pointer. An event from any other surface is a stranger's event and
    // is dropped, not reported as a press on this popup's parent.
    if (self.focus.surface != self.parent_surface) return;
    if (state == wayland.pointer_wire.button_state_press) {
        // The newest press supersedes an older one, so a serial the caller
        // never took cannot be handed out twice under two different presses.
        self.focus.press = serial;
        self.press_pump = self.pump_index;
        return;
    }
    if (state == wayland.pointer_wire.button_state_release) {
        // A release retires the press it completes, so a serial from a click
        // that is already over is never handed out afterwards. A release in
        // the same pump that latched its press is the exception the pump
        // counter exists for.
        if (self.press_pump != self.pump_index) self.clearPress();
    }
}

fn onPointerAxis(
    data: ?*anyopaque,
    pointer: *wayland.Proxy,
    time: u32,
    axis: u32,
    value: i32,
) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = time;
    _ = axis;
    _ = value;
}

const pointer_listener: wayland.PointerListener = .{
    .enter = onPointerEnter,
    .leave = onPointerLeave,
    .motion = onPointerMotion,
    .button = onPointerButton,
    .axis = onPointerAxis,
};

// -- X11: a pointer grab the display server is holding --

/// The X server's own answer to `GrabPointer`, `xproto.h` line 2172. The
/// first byte is success and the rest are the reasons the server gives for
/// saying no; nothing here decides what a refusal means, it only names what the
/// server returned.
pub const GrabStatus = enum(u8) {
    /// The server is holding the pointer for this client.
    success = 0,
    /// Another client already holds the pointer, so this one does not.
    already_grabbed = 1,
    /// The timestamp asked for is neither a real one nor `CurrentTime`.
    invalid_time = 2,
    /// The grab window is not viewable, which is what an unmapped window is.
    not_viewable = 3,
    /// The pointer is frozen by an earlier grab this client failed to release.
    frozen = 4,
    /// The server answered with a status this table does not name. It is
    /// reported as the server's own answer rather than as a success.
    unrecognised = 0xff,

    pub fn fromWire(status: u8) GrabStatus {
        return switch (status) {
            0...4 => @fromBackingInt(@intCast(status)),
            else => .unrecognised,
        };
    }
};

/// `XCB_CURRENT_TIME`, `xcb/xproto.h` line 7072: the X protocol's own "the
/// server's current time", which the server substitutes for itself. It is a
/// documented wire value and not a serial this tree made up.
pub const current_time: u32 = 0;
/// `XCB_NONE`, `xcb/xproto.h` line 7097: no such object. It is what the grab
/// takes for `confine_to` and for `cursor`, neither of which this path sets.
const none: u32 = 0;
/// `XCB_GRAB_MODE_ASYNC`, `xcb/xproto.h` line 2126: pointer events keep being
/// processed normally rather than freezing until this client releases them.
const grab_mode_async: u8 = 1;
/// `XCB_EVENT_MASK_BUTTON_PRESS` and `XCB_EVENT_MASK_BUTTON_RELEASE`,
/// `xcb/xproto.h` lines 345 and 346: the two events a menu popup needs, so
/// the grab reports the click that dismisses it to the window that owns the
/// grab rather than to whatever was under the pointer.
const grab_event_mask: u16 = 4 | 8;

/// Opaque `xcb_connection_t *`. Only libxcb dereferences it.
const XcbConnection = opaque {};

/// `xcb_grab_pointer_cookie_t`, `xcb/xproto.h` line 2146: the request's reply
/// cookie. It is one unsigned int by value in both the header and here.
const GrabCookie = extern struct { sequence: c_uint };

/// `xcb_grab_pointer_reply_t`, `xcb/xproto.h` line 2172. Only `status` is read;
/// the rest is what the header says the reply carries.
const GrabReply = extern struct {
    response_type: u8,
    status: u8,
    sequence: u16,
    length: u32,
};

/// `char *XDisplayString(Display *)` from Xlib.
const XDisplayStringFn = *const fn (dpy: *anyopaque) callconv(.c) [*:0]const u8;
/// `xcb_connect`, `xcb_disconnect`, and `xcb_poll_for_event` from xcb/xcb.h.
const XcbConnectFn = *const fn (display_name: [*:0]const u8, screen: ?*c_int) callconv(.c) *XcbConnection;
const XcbDisconnectFn = *const fn (connection: *XcbConnection) callconv(.c) void;
const XcbPollEventFn = *const fn (connection: *XcbConnection) callconv(.c) ?*XcbButtonPress;
/// `xcb_grab_pointer(xcb_connection_t *c, uint8_t owner_events,
/// xcb_window_t grab_window, uint16_t event_mask, uint8_t pointer_mode,
/// uint8_t keyboard_mode, xcb_window_t confine_to, xcb_cursor_t cursor,
/// xcb_timestamp_t time)` from `xcb/xproto.h` line 7331.
const XcbGrabPointerFn = *const fn (
    c: *XcbConnection,
    owner_events: u8,
    grab_window: u32,
    event_mask: u16,
    pointer_mode: u8,
    keyboard_mode: u8,
    confine_to: u32,
    cursor: u32,
    time: u32,
) callconv(.c) GrabCookie;
/// `xcb_grab_pointer_reply(xcb_connection_t *c, xcb_grab_pointer_cookie_t
/// cookie, xcb_generic_error_t **e)` from `xcb/xproto.h` line 7406. It waits for
/// the server, so its answer is the server's and not this tree's.
const XcbGrabPointerReplyFn = *const fn (
    c: *XcbConnection,
    cookie: GrabCookie,
    e: *?*anyopaque,
) callconv(.c) ?*GrabReply;
/// `xcb_ungrab_pointer(xcb_connection_t *c, xcb_timestamp_t time)` from
/// `xcb/xproto.h` line 7452.
const XcbUngrabPointerFn = *const fn (c: *XcbConnection, time: u32) callconv(.c) void;
/// `int xcb_flush(xcb_connection_t *c)`: greater than zero on success.
const XcbFlushFn = *const fn (c: *XcbConnection) callconv(.c) c_int;
/// `int xcb_connection_has_error(xcb_connection_t *c)`: greater than zero once
/// the server has stopped serving this connection.
const XcbHasErrorFn = *const fn (c: *XcbConnection) callconv(.c) c_int;

/// Exact `xcb_button_press_event_t` layout, xcb/xproto.h.
const XcbButtonPress = extern struct {
    response_type: u8,
    detail: u8,
    sequence: u16,
    time: u32,
    root: u32,
    event: u32,
    child: u32,
    root_x: i16,
    root_y: i16,
    event_x: i16,
    event_y: i16,
    state: u16,
    same_screen: u8,
    pad0: u8,
};

/// A server-delivered press addressed to the grabbed popup. Coordinates are
/// popup-relative and may lie outside it; the 32-bit server time wraps.
pub const X11Press = struct {
    window: u32,
    button: u8,
    timestamp_ms: u32,
    x: i16,
    y: i16,
    root: u32,
    root_x: i16,
    root_y: i16,
};
/// SDL's actual display name, read through Xlib's documented entry point.
const X11Bridge = struct {
    object: sdl3.SharedObject,
    display_string: XDisplayStringFn,
};

/// The xcb request helpers a grab needs, with the mapping that exports them.
const XcbApi = struct {
    object: sdl3.SharedObject,
    grab_pointer: XcbGrabPointerFn,
    grab_pointer_reply: XcbGrabPointerReplyFn,
    ungrab_pointer: XcbUngrabPointerFn,
    flush: XcbFlushFn,
    has_error: XcbHasErrorFn,
    connect: XcbConnectFn,
    disconnect: XcbDisconnectFn,
    poll_event: XcbPollEventFn,
};

/// The Xlib sonames that export `XDisplayString`.
const bridge_sonames = [_][:0]const u8{
    "libX11.so.6",
    "libX11.so",
};
/// The sonames that carry the xcb request helpers.
const xcb_sonames = [_][:0]const u8{
    "libxcb.so.1",
    "libxcb.so",
};

fn symbolOf(comptime Proto: type, object: sdl3.SharedObject, name: [:0]const u8) ?Proto {
    const raw = object.loadFunction(name) catch return null;
    return @ptrCast(@alignCast(raw));
}

fn loadBridge() ?X11Bridge {
    for (bridge_sonames) |soname| {
        const object = sdl3.SharedObject.load(soname) catch continue;
        const display_string = symbolOf(XDisplayStringFn, object, "XDisplayString") orelse {
            object.unload();
            continue;
        };
        return .{ .object = object, .display_string = display_string };
    }
    return null;
}

fn loadXcb() ?XcbApi {
    for (xcb_sonames) |soname| {
        const object = sdl3.SharedObject.load(soname) catch continue;
        const connect = symbolOf(XcbConnectFn, object, "xcb_connect") orelse {
            object.unload();
            continue;
        };
        const disconnect = symbolOf(XcbDisconnectFn, object, "xcb_disconnect") orelse {
            object.unload();
            continue;
        };
        const poll_event = symbolOf(XcbPollEventFn, object, "xcb_poll_for_event") orelse {
            object.unload();
            continue;
        };
        const grab_pointer = symbolOf(XcbGrabPointerFn, object, "xcb_grab_pointer") orelse {
            object.unload();
            continue;
        };
        const grab_pointer_reply =
            symbolOf(XcbGrabPointerReplyFn, object, "xcb_grab_pointer_reply") orelse {
                object.unload();
                continue;
            };
        const ungrab_pointer = symbolOf(XcbUngrabPointerFn, object, "xcb_ungrab_pointer") orelse {
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
        return .{
            .object = object,
            .connect = connect,
            .disconnect = disconnect,
            .poll_event = poll_event,
            .grab_pointer = grab_pointer,
            .grab_pointer_reply = grab_pointer_reply,
            .ungrab_pointer = ungrab_pointer,
            .flush = flush,
            .has_error = has_error,
        };
    }
    return null;
}

/// A server-acknowledged popup grab on one owned XCB connection.
/// Native presses stay separate from SDL's focus-derived mouse events.
pub const X11Grab = struct {
    bridge: X11Bridge,
    xcb: XcbApi,
    /// Owned: a separate client prevents SDL from releasing this grab.
    connection: *XcbConnection,
    /// The window the grab names, so a release undoes exactly what was taken.
    window: u32 = 0,
    /// True only after the display server answered with `GrabSuccess`.
    held: bool = false,
    /// What the display server answered, kept so a caller can read the reason a
    /// grab was refused instead of only being told that it was.
    status: GrabStatus = .not_viewable,

    /// Open the actual SDL display without changing SDL's connection or queue.
    pub fn create(display: *anyopaque) InputError!X11Grab {
        const bridge = loadBridge() orelse return error.GrabClientLibraryMissing;
        errdefer bridge.object.unload();
        const xcb = loadXcb() orelse return error.GrabClientLibraryMissing;
        errdefer xcb.object.unload();

        const connection = xcb.connect(bridge.display_string(display), null);
        errdefer xcb.disconnect(connection);
        const failure = xcb.has_error(connection);
        if (failure == 3) return error.OutOfMemory;
        if (failure != 0) return error.ConnectionFailed;
        return .{
            .bridge = bridge,
            .xcb = xcb,
            .connection = connection,
        };
    }

    /// True while the display server is holding this grab for this client.
    pub fn isHeld(self: *const X11Grab) bool {
        return self.held;
    }

    /// What the display server answered to the last grab, success or not.
    pub fn answer(self: *const X11Grab) GrabStatus {
        return self.status;
    }

    /// Ask the display server for the pointer and wait for its answer.
    ///
    /// The reply is the server's, so this is the only place a grab becomes a
    /// fact. A status that is not success is refused by name with the reason
    /// recorded, and no caller is ever told a grab is held on the strength of a
    /// request that was merely sent.
    pub fn grab(self: *X11Grab, window: u32, time: u32) InputError!void {
        if (self.held) return error.GrabAlreadyHeld;
        // A connection the server has stopped serving carries no request, so the
        // error is read before anything is sent rather than after.
        if (self.xcb.has_error(self.connection) != 0) return error.ConnectionFailed;
        const cookie = self.xcb.grab_pointer(
            self.connection,
            // owner_events=false routes selected presses to the grab window,
            // including outside clicks that SDL otherwise reports to its parent.
            0,
            window,
            grab_event_mask,
            grab_mode_async,
            grab_mode_async,
            none,
            none,
            time,
        );
        var failure: ?*anyopaque = null;
        const reply = self.xcb.grab_pointer_reply(self.connection, cookie, &failure) orelse {
            // The request itself failed, so there is no status to record: there
            // is no reply at all. The error the server sent is released here
            // because it was allocated by the library that produced it.
            if (failure) |error_value| std.c.free(error_value);
            self.status = .unrecognised;
            return error.NativeGrabRefused;
        };
        // The reply was allocated by libxcb and belongs to libxcb's allocator,
        // so it goes back the moment it has been read.
        defer std.c.free(reply);
        self.status = GrabStatus.fromWire(reply.status);
        if (reply.status != 0) return error.NativeGrabRefused;
        self.window = window;
        self.held = true;
        return;
    }

    /// Release the grab, if this client still holds one.
    ///
    /// The request answers nothing, so there is no status to read here and
    /// nothing to report beyond whether the connection carried it. What
    /// matters is that this is called before the window the grab named is
    /// destroyed: a grab left behind is a pointer frozen for everyone.
    pub fn ungrab(self: *X11Grab) void {
        if (!self.held) return;
        // The last answer stays readable until the mappings go: it describes
        // the grab this client took, and overwriting it with a sentinel would
        // lose the only record of what the display server said about it.
        self.held = false;
        self.window = 0;
        self.xcb.ungrab_pointer(self.connection, current_time);
        const sent = self.xcb.flush(self.connection);
        if (sent <= 0) {
            std.log.warn(
                "x11 pointer ungrab was not carried by the connection: {d}",
                .{sent},
            );
        }
    }

    /// Consume one real popup-addressed press. No SDL event is synthesized.
    pub fn takePress(self: *X11Grab) InputError!?X11Press {
        if (!self.held) return null;
        while (true) {
            const event = self.xcb.poll_event(self.connection) orelse {
                if (self.xcb.has_error(self.connection) != 0) return error.ConnectionFailed;
                return null;
            };
            defer std.c.free(event);
            if (event.response_type == 0) return error.NativeInputRejected;
            // Exclude releases, unrelated windows and XSendEvent messages.
            if (event.response_type != 4 or event.event != self.window) continue;
            return .{
                .window = event.event,
                .button = event.detail,
                .timestamp_ms = event.time,
                .x = event.event_x,
                .y = event.event_y,
                .root = event.root,
                .root_x = event.root_x,
                .root_y = event.root_y,
            };
        }
    }

    pub fn deinit(self: *X11Grab) void {
        self.ungrab();
        self.xcb.disconnect(self.connection);
        self.bridge.object.unload();
        self.xcb.object.unload();
        self.* = undefined;
    }
};
