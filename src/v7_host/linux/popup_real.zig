//! Native popup roles: a real `xdg_popup` on the compositor's own connection
//! and SDL's popup window on X11.
//!
//! The two paths exist because the two display servers do not offer the same
//! role. SDL's X11 backend turns `SDL_WINDOW_POPUP_MENU` into an
//! override-redirect window, so the role is already there when the window
//! exists. The Wayland half therefore assigns the role itself, on the same
//! `wl_display` and the same libwayland mapping SDL is already using, and only
//! ever through the protocol requests described in `wayland.zig`: a role may
//! only be assigned to a surface that has none, so the window is created with
//! `SDL_PROP_WINDOW_CREATE_WAYLAND_SURFACE_ROLE_CUSTOM` and stays hidden until
//! the role exists. A backend that gave the window a role anyway is refused
//! rather than sent a `get_xdg_surface` the compositor would answer with
//! `xdg_wm_base.role`.
//!
//! What this adapter never does is stand in for a display server that is not
//! there. A driver with no display server behind it, a shell that is not
//! advertised, a seat that is not offered and a positioner the protocol table
//! cannot express are each refused by name, and no toplevel, overlay or
//! client-side placement is reported in their place.
//!
//! A popup also needs two things the protocol itself will not invent for it,
//! and both are answered by the display server rather than by this tree. The
//! serial of the user event that asked for the popup comes from `ParentInput`,
//! which binds a seat and a pointer on a private event queue and latches only
//! real button presses on this popup's own parent surface. The grab itself is
//! a compositor request on the xdg-shell path and a display-server request on
//! the X11 path, and on the X11 path it is only reported as taken once the X
//! server's own `GrabPointer` reply says so.
//!
//! Native window handles come from documented SDL properties and calls.
//! `noapi.Surface.initSdl` creates the GPU surface without exposing graphics
//! handles to the host or its consumers.
const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const state = @import("popup.zig");
const wayland = @import("wayland.zig");
const input = @import("native_input.zig");

pub const PopupError = state.PopupError;
pub const PopupKind = state.PopupKind;
pub const Mapping = state.Mapping;
pub const PointOfRiskApproval = state.PointOfRiskApproval;
pub const Rect = state.Rect;
pub const Size = state.Size;
pub const Point = state.Point;
pub const Positioner = state.Positioner;
pub const ResolvedPlacement = state.ResolvedPlacement;
pub const PopupConfigure = state.PopupConfigure;

/// A real button press on one real window, latched on an event queue of its
/// own. See `native_input.zig` for what it owns, borrows and refuses.
pub const ParentInput = input.ParentInput;
/// What the X11 display server answered to a pointer grab.
pub const GrabStatus = input.GrabStatus;
/// Server-delivered input from the popup's private X11 grab connection.
pub const X11Press = input.X11Press;

/// Everything this adapter can fail for beyond the popup contract itself.
pub const Error = PopupError || input.InputError || error{
    /// A request list longer than `Plan.capacity`. The plan is a fixed buffer
    /// so the protocol order can be inspected without an allocator.
    PlanOverflow,
    /// A request that creates a remote object came back without it, or the
    /// connection refused to carry a request that creates none.
    MarshalRejected,
    /// `wl_display_roundtrip` failed, which means the connection is broken.
    RoundtripFailed,
    /// The compositor sent no configure within the round trips allowed.
    NoConfigure,
    /// The operation belongs to the other display server's popup path.
    NotApplicableOnThisDriver,
    /// The video driver has no display server behind it, so there is nothing
    /// for an OS popup to be a popup of. Named apart from
    /// `NativeRoleUnavailable` because a headless run is an answer, not a
    /// failure of a display server that was there.
    HeadlessDisplayServer,
    /// A reactive positioner cannot be expressed where this popup is going:
    /// the display server offers no positioner at all, or the shell and this
    /// tree negotiated an `xdg_positioner` older than version 3, which is
    /// where `set_reactive` arrived. The request is refused rather than dropped,
    /// because a positioner that never reacts is not the positioner the caller
    /// asked for, and this tree does not report one behaviour while performing
    /// another.
    ReactivePositionerUnsupported,
    /// The `xdg_popup` binding is older than version 3, so it carries no
    /// `reposition` request and the popup cannot follow a moving anchor.
    RepositionUnsupported,
};

/// Which Linux display server is driving the current SDL video context.
pub const Driver = enum { wayland, x11, headless, other };

/// The video drivers SDL offers that have no display server behind them.
/// A popup is a window on a display server, so on these it is refused by name
/// instead of being attempted and reported as unavailable.
const headless_drivers = [_][]const u8{ "dummy", "offscreen", "null" };

pub fn currentDriver() Driver {
    const name = sdl3.video.getCurrentDriverName() orelse return .other;
    if (std.mem.eql(u8, name, "wayland")) return .wayland;
    if (std.mem.eql(u8, name, "x11")) return .x11;
    for (headless_drivers) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return .headless;
    }
    return .other;
}

/// Which popup role a `NativePopup` actually holds.
pub const Path = enum(u8) {
    /// An override-redirect window SDL created for X11. It has no positioner and
    /// no configure handshake, so the placement is the one this tree resolved
    /// and the display server is not asked to second-guess it.
    sdl_popup_window = 0,
    /// A real `xdg_popup` placed by the compositor's own positioner rules.
    xdg_popup = 1,
};

/// Native handles a popup surface reports, read from documented properties.
pub const NativeHandles = struct {
    display: ?*anyopaque = null,
    surface: ?*anyopaque = null,
    xdg_surface: ?*anyopaque = null,
    xdg_popup: ?*anyopaque = null,
    xdg_positioner: ?*anyopaque = null,
    x11_display: ?*anyopaque = null,
    x11_window: ?i64 = null,

    pub fn hasRealPopupRole(self: NativeHandles) bool {
        if (self.display != null and self.surface != null and self.xdg_surface != null and
            self.xdg_popup != null and self.xdg_positioner != null) return true;
        if (self.x11_display != null) {
            if (self.x11_window) |window| return window != 0;
        }
        return false;
    }
};

/// The parent window's own native handles. A popup is a child of the parent's
/// `xdg_surface`, so the parent's role object is what the popup is anchored to.
pub const ParentHandles = struct {
    /// `SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER`.
    display: ?*anyopaque = null,
    /// `SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER`.
    surface: ?*anyopaque = null,
    /// `SDL_PROP_WINDOW_WAYLAND_XDG_SURFACE_POINTER`: the object
    /// `xdg_surface.get_popup` takes as its parent.
    xdg_surface: ?*anyopaque = null,
    /// `SDL_PROP_WINDOW_WAYLAND_XDG_TOPLEVEL_POINTER`. Its presence proves the
    /// parent already carries a role, which the protocol requires of a popup's
    /// parent.
    xdg_toplevel: ?*anyopaque = null,
    x11_display: ?*anyopaque = null,
    x11_window: ?i64 = null,
    driver_name: ?[]const u8 = null,

    pub fn read(window: sdl3.video.Window) !ParentHandles {
        const props = try window.getProperties();
        return .{
            .display = if (props.wayland_display) |v| v.value else null,
            .surface = if (props.wayland_surface) |v| v.value else null,
            .xdg_surface = if (props.wayland_xdg_surface) |v| v.value else null,
            .xdg_toplevel = if (props.wayland_xdg_toplevel) |v| v.value else null,
            .x11_display = if (props.x11_display) |v| v.value else null,
            .x11_window = props.x11_window,
            .driver_name = sdl3.video.getCurrentDriverName(),
        };
    }

    pub fn isWayland(self: ParentHandles) bool {
        const name = self.driver_name orelse return false;
        return std.mem.eql(u8, name, "wayland");
    }

    /// A popup needs a parent that already carries a role: an `xdg_surface` with
    /// an `xdg_toplevel` on it. A parent with no role has nothing to anchor to,
    /// and the protocol answers `xdg_wm_base.invalid_popup_parent`.
    pub fn usableAsPopupParent(self: ParentHandles) bool {
        if (!self.isWayland()) return false;
        return self.xdg_surface != null and self.xdg_toplevel != null;
    }

    /// The proxy `xdg_surface.get_popup` names as the popup's parent.
    pub fn parentXdgSurface(self: ParentHandles) Error!*wayland.Proxy {
        const value = self.xdg_surface orelse return error.MissingParentSurface;
        return @ptrCast(value);
    }
};

/// What a caller asks the adapter to place.
pub const Request = struct {
    /// The rules the display server places the popup by. `anchor_rect` is in the
    /// parent surface's own coordinates, which is the space
    /// `xdg_positioner.set_anchor_rect` takes.
    positioner: Positioner,
    /// This tree's own solution of those rules, in the same parent-relative
    /// space. The X11 path sends it; the xdg-shell path reports it as a
    /// prediction to compare against the compositor's configure, because on that
    /// path the compositor owns the placement.
    predicted: ResolvedPlacement,
};

/// A grab request. `serial` is the serial of the user event that asked for the
/// popup, which is the only kind of serial `xdg_popup.grab` accepts, so it is
/// required on the xdg-shell path and refused without one. It is left null on
/// the X11 path, whose grab names a window and a timestamp rather than a
/// Wayland serial: a number the X server has never seen would be a fabricated
/// serial, and this tree does not send one.
pub const GrabRequest = struct {
    serial: ?u32 = null,
    approval: PointOfRiskApproval = .{},

    pub fn none() GrabRequest {
        return .{};
    }
};

/// One protocol request, in the order the adapter sends it.
///
/// The list is the evidence for the order rules the protocol states in so many
/// words. Each phase is built as data before anything reaches the wire, so the
/// order can be read without a compositor, and the adapter executes the phase it
/// built.
pub const Op = union(enum) {
    /// `wl_registry.bind` of `xdg_wm_base` at the advertised version.
    bind_wm_base: u32,
    /// `wl_registry.bind` of `wl_seat`, which a grab needs and nothing else does.
    bind_seat: u32,
    /// `xdg_wm_base.create_positioner`.
    create_positioner,
    positioner_set_size: Size,
    positioner_set_anchor_rect: Rect,
    positioner_set_anchor: u32,
    positioner_set_gravity: u32,
    positioner_set_constraint_adjustment: u32,
    positioner_set_offset: Point,
    /// `xdg_positioner.set_reactive`, since version 3. The compositor
    /// reconstrains the popup whenever the conditions it was placed against
    /// change, which is what makes it follow a parent that moves.
    positioner_set_reactive,
    /// `xdg_positioner.destroy`. The compositor copies the rules when
    /// `xdg_surface.get_popup` is sent, so the positioner is released after
    /// that request and not before it: `get_popup` names the positioner as an
    /// argument, and a request that names a destroyed object is what the
    /// compositor answers with an invalid object.
    destroy_positioner,
    /// `xdg_wm_base.get_xdg_surface` for the popup's own surface.
    get_xdg_surface,
    /// `xdg_surface.get_popup` with the parent's `xdg_surface` as its parent.
    get_popup,
    /// `xdg_surface.set_window_geometry`, so the compositor's visible bounds
    /// match the size the popup was asked for.
    set_window_geometry: Size,
    /// `xdg_popup.grab`. Legal only while the popup is unmapped, so it is
    /// planned between the role and the first commit and never after a buffer
    /// was attached.
    grab: u32,
    /// `xdg_popup.reposition`, since version 3. The compositor places the
    /// popup again and answers `repositioned`, then a fresh configure, and the
    /// new position takes effect only once that configure is acknowledged.
    reposition: u32,
    /// The initial `wl_surface.commit` with no buffer attached, which is what
    /// asks the compositor for the first configure.
    commit_no_buffer,
    /// `xdg_surface.ack_configure` of the serial the compositor sent.
    ack_configure: u32,
    /// `wl_surface.commit` with a buffer attached, which maps the popup.
    commit_buffer: Size,
    /// `xdg_wm_base.pong`, answering a `ping`. A binding that stays silent earns
    /// `xdg_wm_base.unresponsive`.
    pong: u32,
    /// `xdg_popup.destroy`: the client's own dismissal, and the documented
    /// teardown after a `popup_done`.
    destroy_popup,
    /// `xdg_surface.destroy`, which may only follow its role object.
    destroy_xdg_surface,
    /// `wl_seat.release`, or the local proxy dropped when the binding is older
    /// than that destructor. Only a grab binds a seat.
    destroy_seat,
    /// `xdg_wm_base.destroy`, once every role object it made is gone.
    destroy_wm_base,
    /// `GrabPointer` on the popup's own X11 window, carrying the timestamp the
    /// request names. `xdg_popup.grab` is a compositor request about a popup
    /// role; this is a display-server request about a window, and it is only
    /// recorded after the display server itself answered with its success
    /// status, because a sent request is not a held grab.
    x11_grab_pointer: u32,
    /// `UngrabPointer` on the same connection, and the only way a grab taken
    /// here is ever given back. It goes out before the window the grab named
    /// is destroyed.
    x11_ungrab_pointer,
};

/// A fixed request list. A fixed buffer rather than an allocation so the order
/// the protocol demands can be inspected with no allocator and no compositor.
pub const Plan = struct {
    pub const capacity = 20;

    // SAFETY: only `ops[0..len]` is read, and `len` counts up only as
    // `push` writes each entry.
    ops: [capacity]Op = undefined,
    len: usize = 0,

    pub fn push(self: *Plan, op: Op) Error!void {
        if (self.len == capacity) return error.PlanOverflow;
        self.ops[self.len] = op;
        self.len += 1;
    }

    pub fn slice(self: *const Plan) []const Op {
        return self.ops[0..self.len];
    }

    /// Index of the first entry carrying `tag`, or null when there is none.
    pub fn indexOf(self: *const Plan, tag: std.meta.Tag(Op)) ?usize {
        for (self.slice(), 0..) |op, index| {
            if (std.meta.activeTag(op) == tag) return index;
        }
        return null;
    }

    pub fn countOf(self: *const Plan, tag: std.meta.Tag(Op)) usize {
        var count: usize = 0;
        for (self.slice()) |op| {
            if (std.meta.activeTag(op) == tag) count += 1;
        }
        return count;
    }
};

/// The requests that give a popup its role.
///
/// Every step is there because of a rule the protocol XML states:
///
///  * A positioner with a zero size or a zero anchor rectangle is incomplete and
///    the compositor answers `xdg_wm_base.invalid_positioner`, so both are
///    checked before the positioner is created.
///  * The compositor copies the rules when `get_popup` is sent, so the
///    positioner is destroyed after that request. `xdg-shell.xml` says the
///    object "can be destroyed or reused" only "after the request is
///    complete", so destroying it first would leave `get_popup` naming an
///    object the compositor has already destroyed.
///  * The parent named by `get_popup` is the parent's `xdg_surface`, not its
///    `wl_surface`.
///  * A reactive positioner adds `set_reactive` after the rules it applies to
///    and before the request that consumes the positioner, so the compositor
///    copies a complete one.
pub fn planRole(out: *Plan, request: Request, wm_base_version: u32) Error!void {
    const positioner = request.positioner;
    if (positioner.size.width == 0 or positioner.size.height == 0) return error.InvalidSize;
    if (positioner.anchor_rect.width == 0 or positioner.anchor_rect.height == 0) {
        return error.PositionerIncomplete;
    }

    try out.push(.{ .bind_wm_base = wm_base_version });
    try out.push(.create_positioner);
    try out.push(.{ .positioner_set_size = positioner.size });
    try out.push(.{ .positioner_set_anchor_rect = positioner.anchor_rect });
    try out.push(.{ .positioner_set_anchor = state.anchorBits(positioner.anchor) });
    try out.push(.{ .positioner_set_gravity = state.gravityBits(positioner.gravity) });
    try out.push(.{
        .positioner_set_constraint_adjustment = state.constraintAdjustmentBits(
            positioner.constraint_adjustment,
        ),
    });
    try out.push(.{ .positioner_set_offset = positioner.offset });
    if (positioner.reactive) try out.push(.positioner_set_reactive);
    try out.push(.get_xdg_surface);
    try out.push(.get_popup);
    try out.push(.destroy_positioner);
    try out.push(.{ .set_window_geometry = positioner.size });
}

/// The requests that move a mapped popup to a new anchor.
///
/// A second positioner is created, handed to `xdg_popup.reposition` and then
/// destroyed, in that order: `reposition` names the positioner, so the same
/// rule that orders the role applies here. The token is the caller's, and the
/// compositor returns it in `repositioned`.
pub fn planReposition(out: *Plan, request: Request, token: u32) Error!void {
    const positioner = request.positioner;
    if (positioner.size.width == 0 or positioner.size.height == 0) return error.InvalidSize;
    if (positioner.anchor_rect.width == 0 or positioner.anchor_rect.height == 0) {
        return error.PositionerIncomplete;
    }

    // The shell is already bound: the popup it made is the one being moved, so
    // this phase binds nothing and only builds a positioner, hands it over and
    // releases it.
    try out.push(.create_positioner);
    try out.push(.{ .positioner_set_size = positioner.size });
    try out.push(.{ .positioner_set_anchor_rect = positioner.anchor_rect });
    try out.push(.{ .positioner_set_anchor = state.anchorBits(positioner.anchor) });
    try out.push(.{ .positioner_set_gravity = state.gravityBits(positioner.gravity) });
    try out.push(.{
        .positioner_set_constraint_adjustment = state.constraintAdjustmentBits(
            positioner.constraint_adjustment,
        ),
    });
    try out.push(.{ .positioner_set_offset = positioner.offset });
    if (positioner.reactive) try out.push(.positioner_set_reactive);
    try out.push(.{ .reposition = token });
    try out.push(.destroy_positioner);
}

/// The requests a grab needs, in their only legal place.
///
/// `xdg_popup.grab` is refused by the protocol once the popup is mapped, so it
/// belongs between the role and the initial commit, and the seat it names is
/// bound in the same phase because a grab without its seat cannot be sent.
pub fn planGrab(out: *Plan, seat_version: u32, serial: u32) Error!void {
    if (serial == 0) return error.MissingSeatSerial;
    try out.push(.{ .bind_seat = seat_version });
    try out.push(.{ .grab = serial });
}

/// The request a display-server pointer grab needs: one grab, against the
/// popup's own window, carrying the timestamp the display server is asked to
/// substitute. There is no seat to bind and no user-event serial, because the
/// X protocol's grab names a window and a time rather than a compositor role
/// and a Wayland serial.
pub fn planX11Grab(out: *Plan, time: u32) Error!void {
    try out.push(.{ .x11_grab_pointer = time });
}

/// The request that gives a display-server pointer grab back. It has to reach
/// the display server before the window the grab named is destroyed.
pub fn planX11Ungrab(out: *Plan) Error!void {
    try out.push(.x11_ungrab_pointer);
}

/// The initial commit. It carries no buffer: attaching one before the first
/// `xdg_surface.configure` is `xdg_surface.unconfigured_buffer`.
pub fn planInitialCommit(out: *Plan) Error!void {
    try out.push(.commit_no_buffer);
}

/// The requests that map a configured popup: the acknowledgement, then the
/// buffer commit the acknowledgement authorises.
pub fn planMapping(out: *Plan, serial: u32, size: Size) Error!void {
    try out.push(.{ .ack_configure = serial });
    try out.push(.{ .commit_buffer = size });
}

/// The requests that dismiss a popup and release its role, in the protocol's own
/// order: the role object, the `xdg_surface` that carried it, the seat a grab
/// bound, then the shell that made them all. Every entry is conditional,
/// because what a popup owns depends on its path and on what was asked of it,
/// and a plan naming an object that was never created would report a teardown
/// that did not happen.
pub fn planTeardown(
    out: *Plan,
    has_popup: bool,
    has_xdg_surface: bool,
    has_seat: bool,
    has_wm_base: bool,
) Error!void {
    if (has_popup) try out.push(.destroy_popup);
    if (has_xdg_surface) try out.push(.destroy_xdg_surface);
    if (has_seat) try out.push(.destroy_seat);
    if (has_wm_base) try out.push(.destroy_wm_base);
}

/// The role carrier. Heap allocated because the compositor writes into it from
/// its own listener, so its address has to outlive the call that created it.
const Role = struct {
    gpa: std.mem.Allocator,
    path: Path,
    machine: state.NativePopup,
    /// The SDL window that owns the surface: SDL's popup window on X11, a
    /// roleless window on Wayland. SDL destroys the `wl_surface` with it, so
    /// this tree never sends `wl_surface.destroy` itself.
    window: sdl3.video.Window,
    events: Events = .{},
    /// What the connection advertises, kept for as long as the popup lives so a
    /// global that disappears afterwards is still observable.
    scan: RegistryScan = .{},
    wl: Wayland = .{},
    /// The display-server pointer grab this popup holds, when it holds one. It
    /// belongs to the display server, is taken against this popup's own
    /// window, and is released before that window is destroyed rather than
    /// with it: a grab left behind is a pointer frozen for everyone.
    x11: ?input.X11Grab = null,

    fn deinit(self: *Role) void {
        // The grab is released before anything else of the popup's goes, and
        // above the window destruction it was taken against. The order is the
        // point: an ungrab that never reaches the display server, or that
        // arrives after its window is gone, leaves the pointer frozen.
        if (self.x11) |*grab| {
            grab.ungrab();
            grab.deinit();
            self.x11 = null;
        }
        // The single teardown is claimed by whichever path ended the popup's
        // life, so a deinit that follows a dismissal does not claim a second.
        self.machine.deinit();
        self.window.deinit();
        const gpa = self.gpa;
        defer gpa.destroy(self);
        self.* = undefined;
    }
};

/// State the compositor's events land in before the machine records them.
const Events = struct {
    /// The popup state machine the listener reports into. Null until `create`
    /// has allocated the role, because the listener table is a DECLARATION:
    /// a default-constructed `Events` has to exist before the machine does.
    machine: ?*state.NativePopup = null,
    /// The table the role was built with. A listener marshals through this one
    /// and never through any other, so a ping can be answered from the handler.
    api: ?wayland.Api = null,
    /// The display the role lives on, so a listener can flush what it sent.
    display: ?*wayland.Display = null,
    /// The geometry from `xdg_popup.configure`. The protocol sends it before
    /// the `xdg_surface.configure` that carries the serial, and a configure
    /// sequence is "a set of one or more events configuring the state of the
    /// xdg_surface" applied atomically, so the two halves are latched here and
    /// folded in whichever order they arrive.
    pending_geometry: ?PopupGeometry = null,
    /// The serial from `xdg_surface.configure`, the other half of a configure.
    pending_serial: ?u32 = null,
    /// `xdg_popup.popup_done` arrived.
    popup_done: bool = false,
    /// How many `xdg_wm_base.ping` events arrived.
    pings: u32 = 0,
    /// How many `xdg_popup.repositioned` events arrived, so a caller can tell a
    /// reposition from a first configure.
    repositioned: u32 = 0,

    /// Fold the two halves of a configure into one.
    ///
    /// The serial is the acknowledgement unit, so nothing is recorded until
    /// both halves are here: a half-delivered configure is dropped rather
    /// than acknowledged with the previous geometry. A second geometry that
    /// arrives before the serial supersedes the first, because only the last
    /// configure of a sequence has to be acknowledged.
    fn foldConfigure(self: *Events) void {
        const geometry = self.pending_geometry orelse return;
        const serial = self.pending_serial orelse return;
        self.pending_geometry = null;
        self.pending_serial = null;
        const machine = self.machine orelse return;
        machine.handleConfigure(
            serial,
            geometry.x,
            geometry.y,
            geometry.width,
            geometry.height,
        ) catch |err| {
            // A compositor event has no error channel back to the wire, so a
            // rejected configure is logged and the next one supersedes it.
            std.log.warn("popup configure {d} rejected: {t}", .{ serial, err });
        };
    }

    /// Record the geometry half of a configure and fold it if the serial has
    /// already arrived.
    fn applyPopupConfigure(self: *Events, x: i32, y: i32, width: i32, height: i32) void {
        self.pending_geometry = .{ .x = x, .y = y, .width = width, .height = height };
        self.foldConfigure();
    }

    /// Record the serial half of a configure and fold it if the geometry has
    /// already arrived.
    fn applySurfaceConfigure(self: *Events, serial: u32) void {
        self.pending_serial = serial;
        self.foldConfigure();
    }
};

/// The placement and size `xdg_popup.configure` answers with: the position is
/// the compositor's own solution of the positioner rules, relative to the
/// parent surface's window geometry, so it is evidence and not a prediction.
const PopupGeometry = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

/// The Wayland proxies one popup owns. All of them live on the display SDL
/// created the windows on, so the compositor sees a single client.
const Wayland = struct {
    display: ?*wayland.Display = null,
    surface: ?*wayland.Proxy = null,
    registry: ?*wayland.Registry = null,
    wm_base: ?*wayland.Proxy = null,
    seat: ?*wayland.Proxy = null,
    xdg_surface: ?*wayland.Proxy = null,
    popup: ?*wayland.Proxy = null,
    /// The version the `xdg_wm_base` binding was made at.
    wm_base_version: u32 = 0,
    /// The version the `xdg_popup` binding was made at. `reposition` exists
    /// only from version 3, so the binding decides whether a mapped popup can
    /// follow a moving anchor at all.
    popup_version: u32 = 0,
    /// The version the `wl_seat` binding was made at.
    seat_version: u32 = 0,
    /// The window geometry last sent with `xdg_surface.set_window_geometry`.
    /// The protocol makes it double-buffered and never unsets it, so the
    /// compositor answers the next configure with the size of the geometry
    /// that is in force, and a client that ignores the answer places a popup
    /// whose visible bounds are the ones it asked for rather than the ones the
    /// compositor configured.
    geometry: Size = .{ .width = 0, .height = 0 },
};

/// What the connection advertises, kept for as long as the popup lives so a
/// global that disappears afterwards is still observable.
pub const RegistryScan = struct {
    wm_base_name: u32 = 0,
    wm_base_version: u32 = 0,
    seat_name: u32 = 0,
    seat_version: u32 = 0,
    globals: u32 = 0,
    /// The `xdg_wm_base` global went away while the popup was live, so the role
    /// it carries can no longer be maintained.
    wm_base_removed: bool = false,

    /// `xdg_wm_base` is advertised and still present.
    pub fn hasWmBase(self: RegistryScan) bool {
        return self.wm_base_name != 0 and !self.wm_base_removed;
    }
};

fn onGlobal(
    data: ?*anyopaque,
    registry: *wayland.Registry,
    name: u32,
    interface: [*:0]const u8,
    version: u32,
) callconv(.c) void {
    _ = registry;
    const scan: *RegistryScan = @ptrCast(@alignCast(data orelse return));
    scan.globals += 1;
    const text = std.mem.span(interface);
    if (std.mem.eql(u8, text, "xdg_wm_base")) {
        scan.wm_base_name = name;
        scan.wm_base_version = version;
    } else if (std.mem.eql(u8, text, "wl_seat")) {
        if (scan.seat_name == 0) {
            scan.seat_name = name;
            scan.seat_version = version;
        }
    }
}

fn onGlobalRemove(data: ?*anyopaque, registry: *wayland.Registry, name: u32) callconv(.c) void {
    _ = registry;
    const scan: *RegistryScan = @ptrCast(@alignCast(data orelse return));
    if (name == scan.wm_base_name) scan.wm_base_removed = true;
    if (name == scan.seat_name) {
        scan.seat_name = 0;
        scan.seat_version = 0;
    }
}

const registry_listener: wayland.RegistryListener = .{
    .global = onGlobal,
    .global_remove = onGlobalRemove,
};

const WmBaseListener = extern struct {
    ping: *const fn (data: ?*anyopaque, base: *wayland.Proxy, serial: u32) callconv(.c) void,
};

/// Answer a ping at once. The protocol makes a client that stays silent
/// `xdg_wm_base.unresponsive`, and a ping is answered immediately by definition,
/// so this is the one handler that must not wait for the host's event loop.
fn onPing(data: ?*anyopaque, base: *wayland.Proxy, serial: u32) callconv(.c) void {
    const events: *Events = @ptrCast(@alignCast(data orelse return));
    events.pings += 1;
    const api = events.api orelse return;
    _ = api.proxy_marshal_flags(base, wayland.opcode.xdg_wm_base_pong, null, 0, 0, serial);
    // The answer rides on the same connection as everything else, so it is
    // flushed here rather than left for the host's next step.
    if (events.display) |display| _ = api.display_flush(display);
}

const wm_base_listener: WmBaseListener = .{ .ping = onPing };

const XdgSurfaceListener = extern struct {
    configure: *const fn (
        data: ?*anyopaque,
        surface: *wayland.Proxy,
        serial: u32,
    ) callconv(.c) void,
};

fn onXdgSurfaceConfigure(data: ?*anyopaque, surface: *wayland.Proxy, serial: u32) callconv(.c) void {
    _ = surface;
    const events: *Events = @ptrCast(@alignCast(data orelse return));
    events.applySurfaceConfigure(serial);
}

const xdg_surface_listener: XdgSurfaceListener = .{ .configure = onXdgSurfaceConfigure };

const XdgPopupListener = extern struct {
    configure: *const fn (
        data: ?*anyopaque,
        popup: *wayland.Proxy,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
    ) callconv(.c) void,
    popup_done: *const fn (data: ?*anyopaque, popup: *wayland.Proxy) callconv(.c) void,
    repositioned: *const fn (data: ?*anyopaque, popup: *wayland.Proxy, token: u32) callconv(.c) void,
};

fn onPopupConfigure(
    data: ?*anyopaque,
    popup: *wayland.Proxy,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) callconv(.c) void {
    _ = popup;
    const events: *Events = @ptrCast(@alignCast(data orelse return));
    // The position is the compositor's own answer to the positioner rules, so
    // it is latched with the surface serial that acknowledges it.
    events.applyPopupConfigure(x, y, width, height);
}

fn onPopupDone(data: ?*anyopaque, popup: *wayland.Proxy) callconv(.c) void {
    _ = popup;
    const events: *Events = @ptrCast(@alignCast(data orelse return));
    events.popup_done = true;
    // The protocol says the client destroys the role object at this point, so
    // the dismissal is recorded now and the proxies are released in `deinit`.
    if (events.machine) |machine| machine.onCompositorDismiss();
}

fn onRepositioned(data: ?*anyopaque, popup: *wayland.Proxy, token: u32) callconv(.c) void {
    _ = popup;
    _ = token;
    const events: *Events = @ptrCast(@alignCast(data orelse return));
    events.repositioned += 1;
}

const xdg_popup_listener: XdgPopupListener = .{
    .configure = onPopupConfigure,
    .popup_done = onPopupDone,
    .repositioned = onRepositioned,
};

/// True when SDL's own backend already gave the window a surface role. The
/// only state a client may assign a role to is a surface that has none, and
/// `get_xdg_surface` on a surface that has one is `xdg_wm_base.role`.
fn carriesRole(props: anytype) bool {
    if (props.wayland_xdg_surface) |own| {
        if (own.value != null) return true;
    }
    if (props.wayland_xdg_toplevel) |own| {
        if (own.value != null) return true;
    }
    if (props.wayland_xdg_popup) |own| {
        if (own.value != null) return true;
    }
    return false;
}

/// Create a positioner and marshal the placement rules into it.
///
/// The rules are the ones the protocol requires of a complete positioner: a
/// non-zero size from `set_size` and a non-zero anchor rectangle from
/// `set_anchor_rect`, or the compositor answers `xdg_wm_base.invalid_positioner`
/// instead of placing anything. A reactive positioner adds `set_reactive`,
/// which only exists from version 3 of the binding, so a caller's request for
/// one is either sent or refused by name and never dropped. The caller owns
/// the returned proxy and releases it with `releasePositioner` once the request
/// naming it is sent.
fn buildPositioner(
    api: wayland.Api,
    wm_base: *wayland.Proxy,
    request: Request,
) Error!*wayland.Proxy {
    const rules = request.positioner;
    if (rules.size.width == 0 or rules.size.height == 0) return error.InvalidSize;
    if (rules.anchor_rect.width == 0 or rules.anchor_rect.height == 0) {
        return error.PositionerIncomplete;
    }
    const shell_version = api.proxy_get_version(wm_base);
    // The binding is the smaller of what the compositor offered and what this
    // tree describes, and it is the binding that decides which requests exist.
    const version: u32 = @min(shell_version, wayland.xdg_positioner_interface.version);
    // `set_reactive` arrived in version 3. Sending it from an older binding is
    // answered with `invalid version` and closes the display connection, so a
    // reactive positioner is refused BEFORE the proxy exists, which is also
    // why nothing has to be unwound here.
    if (rules.reactive and !wayland.positionerCanReact(version)) {
        return error.ReactivePositionerUnsupported;
    }
    const positioner = api.proxy_marshal_flags(
        wm_base,
        wayland.opcode.xdg_wm_base_create_positioner,
        &wayland.xdg_positioner_interface,
        version,
        0,
        @as(?*wayland.Proxy, null),
    ) orelse return error.MarshalRejected;
    errdefer api.proxy_destroy(positioner);

    _ = api.proxy_marshal_flags(
        positioner,
        wayland.opcode.xdg_positioner_set_size,
        null,
        0,
        0,
        @as(i32, @intCast(rules.size.width)),
        @as(i32, @intCast(rules.size.height)),
    );
    _ = api.proxy_marshal_flags(
        positioner,
        wayland.opcode.xdg_positioner_set_anchor_rect,
        null,
        0,
        0,
        rules.anchor_rect.x,
        rules.anchor_rect.y,
        @as(i32, @intCast(rules.anchor_rect.width)),
        @as(i32, @intCast(rules.anchor_rect.height)),
    );
    _ = api.proxy_marshal_flags(
        positioner,
        wayland.opcode.xdg_positioner_set_anchor,
        null,
        0,
        0,
        state.anchorBits(rules.anchor),
    );
    _ = api.proxy_marshal_flags(
        positioner,
        wayland.opcode.xdg_positioner_set_gravity,
        null,
        0,
        0,
        state.gravityBits(rules.gravity),
    );
    _ = api.proxy_marshal_flags(
        positioner,
        wayland.opcode.xdg_positioner_set_constraint_adjustment,
        null,
        0,
        0,
        state.constraintAdjustmentBits(rules.constraint_adjustment),
    );
    _ = api.proxy_marshal_flags(
        positioner,
        wayland.opcode.xdg_positioner_set_offset,
        null,
        0,
        0,
        rules.offset.x,
        rules.offset.y,
    );
    if (rules.reactive) {
        _ = api.proxy_marshal_flags(
            positioner,
            wayland.opcode.xdg_positioner_set_reactive,
            null,
            0,
            0,
        );
    }
    return positioner;
}

/// `xdg_positioner.destroy`.
///
/// Only ever called after the request that names the positioner: the
/// compositor copies the rules when that request arrives, and a request that
/// names an object already destroyed is answered with an invalid object.
fn releasePositioner(api: wayland.Api, positioner: *wayland.Proxy) void {
    _ = api.proxy_marshal_flags(
        positioner,
        wayland.opcode.xdg_positioner_destroy,
        null,
        api.proxy_get_version(positioner),
        wayland.marshal_destroy,
    );
}

/// `xdg_surface.set_window_geometry` at the surface origin.
///
/// Double-buffered like every other piece of surface state, so it reaches the
/// compositor with the next commit rather than at once. The compositor's next
/// configure answers with the size of the geometry that is in force, which is
/// why the caller sends it again once that answer arrives.
fn setWindowGeometry(api: wayland.Api, xdg_surface: *wayland.Proxy, size: Size) void {
    _ = api.proxy_marshal_flags(
        xdg_surface,
        wayland.opcode.xdg_surface_set_window_geometry,
        null,
        0,
        0,
        @as(i32, 0),
        @as(i32, 0),
        @as(i32, @intCast(size.width)),
        @as(i32, @intCast(size.height)),
    );
}

/// Send what is queued and report whether the connection refused to carry it.
///
/// `wl_proxy_marshal_flags` hands back the proxy of a request that creates a
/// remote object and nothing at all for every other one, so a request that
/// creates nothing has no proxy to return and comes back null on success.
/// `xdg_surface.ack_configure`, `xdg_popup.grab` and `xdg_popup.reposition`
/// all look refused that way when they were sent. The transport is the only
/// place a refusal shows up.
fn flushRefused(api: wayland.Api, display: *wayland.Display) bool {
    const sent = api.display_flush(display);
    // `wl_display_flush` never blocks: it writes what it can and, when the
    // socket refused the rest, answers -1 with EAGAIN while keeping the
    // requests in the client buffer for the display's next flush, so those
    // were accepted. Any other errno is a transport fault, so this reports a
    // refusal only where one happened.
    return sent < 0 and std.posix.errno(sent) != .AGAIN;
}

/// A native popup, whichever role its display server supports.
///
/// The xdg-shell path is deliberately three steps — `attachRole`, `grab`,
/// `initialCommit` — because the protocol only allows a grab between the role
/// and the first commit. Folding them into one call would make that window
/// unobservable, and a grab sent after the first commit is a fatal
/// `xdg_popup.invalid_grab` rather than a mistake the compositor ignores.
pub const NativePopup = struct {
    gpa: std.mem.Allocator,
    role: *Role,
    path: Path,
    /// The request list the last protocol phase was built from. Reading it after
    /// a phase is how the order that reached the wire is inspected.
    plan: Plan = .{},
    window_alive: bool = true,
    handles: NativeHandles = .{},
    /// What the X display server answered to the last pointer grab on this
    /// popup, kept on the popup rather than on the grab because a refusal
    /// releases the grab: the reason is exactly what a caller still needs
    /// after the thing that produced it is gone.
    x11_status: ?GrabStatus = null,

    /// Create a popup attached to `parent`.
    ///
    /// `kind` must be `os_surface`: an in-app overlay never allocates a
    /// compositor surface, so it is refused here rather than silently
    /// downgraded to a window or an overlay.
    ///
    /// On X11 this creates SDL's popup window, which already carries the
    /// override-redirect role. On Wayland it creates a roleless window and stops
    /// there, because the role is assigned by `attachRole` and the grab has to
    /// be able to land before the first commit.
    ///
    /// A driver with no display server behind it is refused by name, and so is a
    /// reactive positioner on a path with no positioner: the X11 popup window
    /// is placed once by `SDL_CreatePopupWindow`, and no request there would
    /// make it follow an anchor afterwards. On Wayland the positioner is this
    /// adapter's, and `attachRole` sends `set_reactive` when the negotiated
    /// binding carries it and refuses by name when it does not.
    pub fn create(
        gpa: std.mem.Allocator,
        kind: PopupKind,
        parent: sdl3.video.Window,
        request: Request,
    ) !NativePopup {
        if (kind != .os_surface) return error.InAppOverlayHasNoNativeSurface;
        const size = request.positioner.size;
        if (size.width == 0 or size.height == 0) return error.InvalidSize;
        if (request.positioner.anchor_rect.width == 0 or
            request.positioner.anchor_rect.height == 0)
        {
            return error.PositionerIncomplete;
        }

        const parent_handles = try ParentHandles.read(parent);
        const role = try gpa.create(Role);
        errdefer gpa.destroy(role);
        // `create` returns UNDEFINED memory, so every field the driver
        // branches do not assign is written here. Assigning only `gpa` left
        // `vulkan`, `scan` and `wl` as whatever the allocator returned, and
        // `deinit` then read that garbage as a Vulkan surface to destroy.
        role.* = .{
            .gpa = gpa,
            .path = .sdl_popup_window,
            // SAFETY: each driver branch assigns the whole machine below.
            .machine = undefined,
            .events = .{ .machine = &role.machine },
            // SAFETY: each driver branch assigns the window below.
            .window = undefined,
        };

        switch (currentDriver()) {
            .x11 => {
                // The X11 popup window is placed once, by SDL, with no request
                // that would move it to a new anchor afterwards, so a reactive
                // positioner is refused rather than quietly dropped. The role
                // is not allocated yet, so this costs nothing.
                if (request.positioner.reactive) {
                    return error.ReactivePositionerUnsupported;
                }
                const placement = request.predicted;
                const flags: sdl3.video.Window.Flags = .{
                    .popup_menu = true,
                    .hidden = true,
                    .vulkan = true,
                };
                role.window = try parent.createPopup(
                    @intCast(placement.rect.x),
                    @intCast(placement.rect.y),
                    placement.rect.width,
                    placement.rect.height,
                    flags,
                );
                role.path = .sdl_popup_window;
                role.machine = try state.NativePopup.init(
                    .os_surface,
                    .window_manager_direct,
                    request.positioner,
                    .{
                        .x = 0,
                        .y = 0,
                        .width = placement.rect.width,
                        .height = placement.rect.height,
                    },
                    .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                );
            },
            .wayland => {
                if (!parent_handles.usableAsPopupParent()) return error.MissingParentSurface;
                // A roleless window is the only surface that may take a role
                // this tree assigns itself, and it stays hidden: showing it is
                // what makes SDL assign a role of its own.
                role.window = try createRolelessWindow(size.width, size.height);
                role.path = .xdg_popup;
                role.machine = try state.NativePopup.init(
                    .os_surface,
                    .compositor_configure,
                    request.positioner,
                    .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                    .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                );
            },
            // A windowless driver has no display server to place a popup on,
            // and a driver this tree knows nothing about cannot be reported
            // as a working one either.
            .headless => return error.HeadlessDisplayServer,
            .other => return error.NativeRoleUnavailable,
        }
        // The prediction is this tree's own solution of the positioner rules. The
        // X11 path sends it to the display server; the xdg-shell path compares it
        // with the compositor's answer and never uses it to place anything.
        role.machine.placement = request.predicted;

        return .{ .gpa = gpa, .role = role, .path = role.path };
    }

    /// The window carrying the popup. On the X11 path this is the SDL popup
    /// window; on the xdg-shell path it is the roleless window this adapter
    /// assigned the role to. Borrowed, and it dies with the popup.
    pub fn window(self: *const NativePopup) sdl3.video.Window {
        return self.role.window;
    }

    /// The driver path that actually produced this popup.
    pub fn driver(self: *const NativePopup) Driver {
        _ = self;
        return currentDriver();
    }

    /// The state machine, for the same reads a caller makes on a live popup.
    pub fn machine(self: *const NativePopup) *const state.NativePopup {
        return &self.role.machine;
    }

    pub fn mutMachine(self: *NativePopup) *state.NativePopup {
        return &self.role.machine;
    }

    /// How many `xdg_wm_base.ping` events the compositor sent this popup's
    /// shell, which is what an unresponsive client would be told about.
    pub fn pingsAnswered(self: *const NativePopup) u32 {
        return self.role.events.pings;
    }

    /// How many `xdg_popup.repositioned` events the compositor answered, so a
    /// caller can compare the requests it sent with the answers it got.
    pub fn repositionedCount(self: *const NativePopup) u32 {
        return self.role.events.repositioned;
    }

    /// What the connection advertised for this popup, so a caller can report the
    /// globals the role was built from rather than the adapter's own verdict.
    pub fn advertisement(self: *const NativePopup) RegistryScan {
        return self.role.scan;
    }

    /// True when the `xdg_wm_base` global went away while this popup was live.
    pub fn shellGlobalRemoved(self: *const NativePopup) bool {
        return self.role.scan.wm_base_removed;
    }

    /// True when the display server gave the popup a real role: an `xdg_popup` on
    /// Wayland, an override-redirect window on X11.
    pub fn hasNativeRole(self: *const NativePopup) bool {
        return switch (self.path) {
            .xdg_popup => self.role.wl.popup != null,
            .sdl_popup_window => self.window_alive,
        };
    }

    /// Assign the `xdg_popup` role: bind the shell, build the positioner, and
    /// create the popup under the parent's `xdg_surface`.
    ///
    /// Nothing is committed here, so a grab is still legal. The compositor
    /// copies the placement rules when `get_popup` is sent, so the positioner
    /// is released after that request rather than before it.
    ///
    /// The positioner is built at the binding this connection negotiated with
    /// the compositor, so a reactive positioner is sent as `set_reactive` when
    /// that binding carries the request and refused by name when it does not.
    pub fn attachRole(
        self: *NativePopup,
        api: wayland.Api,
        parent: ParentHandles,
        request: Request,
    ) !void {
        if (self.path != .xdg_popup) return error.NotApplicableOnThisDriver;
        if (!self.window_alive) return error.AlreadyClosed;
        if (self.role.wl.popup != null) return error.AlreadyActive;
        const role = self.role;

        const props = try role.window.getProperties();
        // A role may only be assigned to a surface that has none, and the
        // property that asks for that is the only thing standing between this
        // request and `xdg_wm_base.role`. A backend that ignored it left the
        // window with a role of its own, so the request is refused here instead
        // of being sent and taking the connection down with it.
        if (carriesRole(props)) return error.NativeRoleUnavailable;
        const wl_display: *wayland.Display = @ptrCast(
            (if (props.wayland_display) |v| v.value else null) orelse
                return error.NativeRoleUnavailable,
        );
        const wl_surface: *wayland.Proxy = @ptrCast(
            (if (props.wayland_surface) |v| v.value else null) orelse
                return error.NativeRoleUnavailable,
        );
        const parent_xdg_surface = try parent.parentXdgSurface();

        const registry = api.displayGetRegistry(wl_display) orelse
            return error.WaylandShellUnsupported;
        var registry_owned = true;
        defer if (registry_owned) api.proxy_destroy(@ptrCast(registry));
        // The scan belongs to the role, not to this call: the registry listener
        // stays registered for the popup's whole life so a global that
        // disappears later is observed rather than missed.
        role.scan = .{};
        if (api.proxy_add_listener(
            @ptrCast(registry),
            @ptrCast(&registry_listener),
            &role.scan,
        ) != 0) return error.ListenerRejected;
        if (api.display_roundtrip(wl_display) < 0) return error.RoundtripFailed;
        // Without `xdg_wm_base` there are no desktop surface roles at all. The
        // refusal names that global and never falls back to a toplevel or an
        // in-app overlay.
        if (!role.scan.hasWmBase()) return error.WaylandShellUnsupported;

        const wm_base_version = @min(
            role.scan.wm_base_version,
            wayland.xdg_wm_base_interface.version,
        );
        var plan: Plan = .{};
        try planRole(&plan, request, wm_base_version);
        self.plan = plan;

        const wm_base = api.registryBind(
            registry,
            role.scan.wm_base_name,
            &wayland.xdg_wm_base_interface,
            wm_base_version,
        ) orelse return error.WaylandShellUnsupported;
        var wm_base_owned = true;
        errdefer if (wm_base_owned) api.proxy_destroy(wm_base);

        const shell_version = api.proxy_get_version(wm_base);
        const positioner = try buildPositioner(api, wm_base, request);
        var positioner_owned = true;
        errdefer if (positioner_owned) api.proxy_destroy(positioner);

        const xdg_surface = api.proxy_marshal_flags(
            wm_base,
            wayland.opcode.xdg_wm_base_get_xdg_surface,
            &wayland.xdg_surface_interface,
            @min(shell_version, wayland.xdg_surface_interface.version),
            0,
            @as(?*wayland.Proxy, null),
            wl_surface,
        ) orelse return error.MarshalRejected;
        var xdg_owned = true;
        errdefer if (xdg_owned) api.proxy_destroy(xdg_surface);

        // The parent argument is the parent's `xdg_surface`, not its
        // `wl_surface`: a popup is a child of the parent's role object.
        const popup = api.proxy_marshal_flags(
            xdg_surface,
            wayland.opcode.xdg_surface_get_popup,
            &wayland.xdg_popup_interface,
            @min(shell_version, wayland.xdg_popup_interface.version),
            0,
            @as(?*wayland.Proxy, null),
            parent_xdg_surface,
            positioner,
        ) orelse return error.MarshalRejected;
        var popup_owned = true;
        errdefer if (popup_owned) api.proxy_destroy(popup);

        // The positioner is released here and not one line earlier. The
        // request above names it, and the compositor only copies the rules
        // when that request arrives, so a positioner destroyed before it
        // leaves a request naming an object that no longer exists.
        releasePositioner(api, positioner);
        positioner_owned = false;

        if (api.proxy_add_listener(
            wm_base,
            @ptrCast(&wm_base_listener),
            &role.events,
        ) != 0) return error.ListenerRejected;
        if (api.proxy_add_listener(
            xdg_surface,
            @ptrCast(&xdg_surface_listener),
            &role.events,
        ) != 0) return error.ListenerRejected;
        if (api.proxy_add_listener(
            popup,
            @ptrCast(&xdg_popup_listener),
            &role.events,
        ) != 0) return error.ListenerRejected;
        role.events.api = api;
        role.events.display = wl_display;
        // The geometry is double-buffered like every other surface state, so it
        // reaches the compositor with the initial commit and is what the
        // configure that follows is an answer to.
        setWindowGeometry(api, xdg_surface, request.positioner.size);

        role.wl = .{
            .display = wl_display,
            .surface = wl_surface,
            .registry = registry,
            .wm_base = wm_base,
            .xdg_surface = xdg_surface,
            .popup = popup,
            .wm_base_version = wm_base_version,
            .popup_version = @min(shell_version, wayland.xdg_popup_interface.version),
            .geometry = request.positioner.size,
        };
        wm_base_owned = false;
        xdg_owned = false;
        popup_owned = false;
        registry_owned = false;
    }

    /// Take a grab, through whichever display server owns this popup.
    ///
    /// The approval gate comes first on both paths, so an unapproved request
    /// never reaches the wire and never reaches a display server. After that
    /// the two paths differ, and both differences come from the display server
    /// rather than from this tree:
    ///
    ///  * xdg-shell names a role and a user-event serial. `xdg_popup.grab` is
    ///    refused by the protocol once the popup is mapped, so the serial has
    ///    to be a real `wl_pointer.button` press on this popup's own parent
    ///    and the grab has to land before the first commit. `ParentInput` is
    ///    what latches that serial; nothing here invents one, and a request
    ///    without one is refused because the protocol has nothing to send.
    ///  * X11 names a window and a timestamp. Its grab is taken on the popup's
    ///    own mapped window through a private XCB connection to SDL's actual
    ///    display, after `show` rather than before the first commit.
    ///    It names no serial: `XCB_CURRENT_TIME` is the X
    ///    protocol's own "now" and is substituted by the display server.
    ///
    /// X11 sets `has_grab` only after a successful server reply. xdg-shell has
    /// no grab acknowledgement: its flag records an issued protocol request,
    /// not compositor acceptance. Later events or a protocol error supply that
    /// witness. A refused request clears the machine's pending intention.
    pub fn grab(self: *NativePopup, request: GrabRequest) !void {
        if (!self.window_alive) return error.AlreadyClosed;
        if (!request.approval.confirmed) return error.RiskConfirmationRequired;
        if (self.path == .sdl_popup_window) return self.grabX11(request);
        return self.grabXdg(request);
    }

    /// What the X display server answered to the last pointer grab on this
    /// popup, success or not. It is the server's own status from the
    /// `GrabPointer` reply, kept so a caller can report WHY a grab was refused
    /// rather than only that it was. Null before any grab was attempted, and
    /// null on every driver that has no display-server pointer grab at all.
    pub fn grabStatus(self: *const NativePopup) ?GrabStatus {
        return self.x11_status;
    }

    /// True while the X display server is holding this popup's pointer grab.
    /// False on every other driver, and false after the grab is released.
    pub fn grabHeld(self: *const NativePopup) bool {
        if (!self.window_alive) return false;
        const role = self.role;
        if (role.x11) |*held| return held.isHeld();
        return false;
    }

    /// Read native X11 grab input, separate from SDL's focus-based mouse queue.
    pub fn takeX11Press(self: *NativePopup) Error!?X11Press {
        if (!self.window_alive) return error.AlreadyClosed;
        if (self.path != .sdl_popup_window) return error.NotApplicableOnThisDriver;
        if (self.role.x11) |*held| return held.takePress();
        return null;
    }

    /// `xdg_popup.grab`, between the role and the first commit.
    fn grabXdg(self: *NativePopup, request: GrabRequest) !void {
        const role = self.role;
        const popup = role.wl.popup orelse return error.NativeRoleUnavailable;
        const api = role.events.api orelse return error.AlreadyDestroyed;
        // Everything that can refuse is settled before the machine is told a
        // grab is coming. A grab that was refused has to leave nothing behind:
        // a pending serial would make the initial commit refuse a grab the
        // caller had already given up on.
        const serial = request.serial orelse return error.MissingSeatSerial;
        if (role.scan.seat_name == 0) return error.MissingSeatSerial;
        const registry = role.wl.registry orelse return error.AlreadyDestroyed;
        const display = role.wl.display orelse return error.AlreadyDestroyed;
        try role.machine.requestGrab(serial, request.approval);

        const seat_version = @min(
            role.scan.seat_version,
            wayland.wl_seat_interface.version,
        );
        var plan: Plan = .{};
        try planGrab(&plan, seat_version, serial);
        self.plan = plan;

        // The seat comes from the scan the same round trip that proved
        // `xdg_wm_base` is advertised, and the registry listener keeps that
        // scan current, so a grab names a seat this connection really offers.
        const seat = api.registryBind(
            registry,
            role.scan.seat_name,
            &wayland.wl_seat_interface,
            seat_version,
        ) orelse {
            role.machine.clearPendingGrab();
            return error.MissingSeatSerial;
        };
        role.wl.seat = seat;
        role.wl.seat_version = seat_version;

        // `xdg_popup.grab` creates no remote object, so a null return is what a
        // sent request looks like, and the connection is what a refusal shows
        // up on.
        _ = api.proxy_marshal_flags(
            popup,
            wayland.opcode.xdg_popup_grab,
            null,
            api.proxy_get_version(popup),
            0,
            seat,
            serial,
        );
        if (flushRefused(api, display)) {
            // No compositor that is still there was asked for the grab, so the
            // serial is an intention again rather than a fact.
            role.machine.clearPendingGrab();
            return error.MarshalRejected;
        }
        try role.machine.onGrabIssued();
    }

    /// The pointer grab on an X11 display server, taken against this popup's
    /// own window.
    ///
    /// SDL creates the override-redirect window inside
    /// `SDL_CreatePopupWindow` and exposes no grab of its own, so the request
    /// goes through a private XCB connection to SDL's actual display. SDL's
    /// crossing-event handlers may ungrab SDL's own connection, so native
    /// popup input must use a separate client. No graphics handle is read.
    ///
    /// `GrabPointer` answers with a status, and this reads it. A status that is
    /// not success leaves the pointer where it was, so `has_grab` stays false
    /// and the refusal is reported with the reason kept in `grabStatus`. A
    /// request that was merely sent is never reported as a grab.
    ///
    /// The caller serial is deliberately not sent. It is a Wayland serial from
    /// a different display server's serial space, and the X protocol's grab
    /// names a window and a time; `XCB_CURRENT_TIME` is the X protocol's own
    /// "now", which the display server substitutes for itself. Passing a
    /// number here that the X server has never seen would be a fabricated
    /// serial, so nothing is passed.
    fn grabX11(self: *NativePopup, request: GrabRequest) !void {
        const role = self.role;
        // The window has to be the one SDL created for this popup, and its
        // Xlib display the one SDL opened. Both are read from the window's own
        // documented properties rather than remembered from creation, so a
        // backend that published something else is refused rather than used.
        const props = role.window.getProperties() catch return error.NativeHandleUnavailable;
        const published = props.x11_display orelse return error.NativeHandleUnavailable;
        const display = published.value orelse return error.NativeHandleUnavailable;
        const window_id = props.x11_window orelse return error.NativeHandleUnavailable;
        if (window_id <= 0 or window_id > std.math.maxInt(u32)) {
            return error.NativeHandleUnavailable;
        }

        // The machine refuses a pre-map grab on this path before anything is
        // sent, because an unmapped window is not viewable and the display
        // server can only answer `NotViewable` to it.
        try role.machine.requestGrab(null, request.approval);

        // The plan is built before anything native happens, so no failure can
        // follow a grab the display server has already taken. One request goes
        // into a buffer of twenty, so this cannot fail while that holds.
        var plan: Plan = .{};
        try planX11Grab(&plan, input.current_time);

        // The grab is stored on the role BEFORE it is taken, so the teardown
        // can reach it whatever happens next, and everything after this point
        // drives the stored copy rather than a local one: a second copy would
        // be a second answer to "is the grab held", and the teardown would
        // read the copy that never took it.
        role.x11 = input.X11Grab.create(display) catch |err| {
            role.machine.clearPendingGrab();
            return err;
        };
        // `x11_status` is recorded from the grab's own answer, so it is the
        // display server's status whether the grab succeeded or was refused.
        // A caller reading it after a refusal gets the server's reason, not
        // just the error name this tree chose for the refusal.
        role.x11.?.grab(@intCast(window_id), input.current_time) catch |err| {
            // Nothing was held, so the mappings go back and the role is left
            // with no grab rather than with one no display server granted.
            var refused = role.x11.?;
            self.x11_status = refused.answer();
            role.x11 = null;
            refused.deinit();
            role.machine.clearPendingGrab();
            return err;
        };
        self.x11_status = role.x11.?.answer();
        self.plan = plan;
        try role.machine.onGrabIssued();
    }

    /// The initial commit, which carries no buffer and asks for the first
    /// configure. A grab the caller asked for but never issued is refused here
    /// rather than silently dropped, so the popup the compositor maps is the
    /// popup the caller approved.
    pub fn initialCommit(self: *NativePopup) !void {
        if (!self.window_alive) return error.AlreadyClosed;
        const role = self.role;
        if (role.machine.grab_pending) return error.GrabFailed;
        if (role.machine.commit_count > 0) return error.AlreadyActive;
        if (self.path == .sdl_popup_window) return error.NotApplicableOnThisDriver;
        // A commit with no role behind it would ask the compositor to place a
        // surface that has no position, so the role is named as the missing
        // thing rather than as a connection that died.
        if (role.wl.popup == null) return error.NativeRoleUnavailable;

        const api = role.events.api orelse return error.AlreadyDestroyed;
        const surface = role.wl.surface orelse return error.AlreadyDestroyed;
        const display = role.wl.display orelse return error.AlreadyDestroyed;
        var plan: Plan = .{};
        try planInitialCommit(&plan);
        self.plan = plan;
        _ = api.proxy_marshal_flags(
            surface,
            wayland.opcode.wl_surface_commit,
            null,
            api.proxy_get_version(surface),
            0,
        );
        _ = api.display_flush(display);
    }

    /// Wait for an unacknowledged configure, including a reposition response.
    pub fn waitForConfigure(self: *NativePopup, max_roundtrips: u32) !PopupConfigure {
        if (!self.window_alive) return error.AlreadyClosed;
        if (self.path != .xdg_popup) return error.NotApplicableOnThisDriver;
        const role = self.role;
        if (role.wl.popup == null) return error.NativeRoleUnavailable;
        const api = role.events.api orelse return error.AlreadyDestroyed;
        const display = role.wl.display orelse return error.AlreadyDestroyed;
        var rounds: u32 = 0;
        while ((role.machine.configure == null or role.machine.acked_serial != null) and rounds < max_roundtrips) {
            rounds += 1;
            if (api.display_roundtrip(display) < 0) return error.RoundtripFailed;
        }
        if (role.machine.acked_serial != null) return error.NoConfigure;
        return role.machine.configure orelse error.NoConfigure;
    }

    /// Acknowledge the newest configure and report the size a buffer must have.
    ///
    /// The acknowledgement is what the protocol makes a new position depend
    /// on. The window geometry is brought in line with the size the compositor
    /// configured first, because the geometry is double-buffered and reaches
    /// the compositor with the commit that maps the popup: a popup whose
    /// visible bounds still named the size it asked for would be placed
    /// against the wrong rectangle.
    pub fn ackLatestConfigure(self: *NativePopup) !Size {
        if (!self.window_alive) return error.AlreadyClosed;
        const role = self.role;
        if (role.wl.popup == null) return error.NativeRoleUnavailable;
        const api = role.events.api orelse return error.AlreadyDestroyed;
        const xdg_surface = role.wl.xdg_surface orelse return error.AlreadyDestroyed;
        const display = role.wl.display orelse return error.AlreadyDestroyed;
        const configure = role.machine.configure orelse return error.UnacknowledgedConfigure;
        const size = try role.machine.ackConfigure(configure.serial);
        if (!std.meta.eql(role.wl.geometry, size)) {
            setWindowGeometry(api, xdg_surface, size);
            role.wl.geometry = size;
        }
        var plan: Plan = .{};
        try plan.push(.{ .ack_configure = configure.serial });
        self.plan = plan;
        // `xdg_surface.ack_configure` takes a serial and creates nothing, so a
        // null return is what a sent acknowledgement looks like. The machine
        // has already taken the size the acknowledgement names, and a refused
        // connection can carry nothing from here on, so the refusal is reported
        // rather than hidden.
        _ = api.proxy_marshal_flags(
            xdg_surface,
            wayland.opcode.xdg_surface_ack_configure,
            null,
            0,
            0,
            configure.serial,
        );
        if (flushRefused(api, display)) return error.MarshalRejected;
        return size;
    }

    /// Commit a buffer of `size` and report the popup mapped.
    ///
    /// A commit with no buffer attached still maps an `xdg_surface`: the
    /// protocol makes the acknowledgement, not a buffer, the thing a new
    /// position depends on. The visible content of a popup is the host's
    /// business, through the platform surface this window carries, and this
    /// adapter never attaches one itself.
    pub fn commit(self: *NativePopup, size: Size) !void {
        if (!self.window_alive) return error.AlreadyClosed;
        const role = self.role;
        if (self.path == .xdg_popup and role.wl.popup == null) {
            return error.NativeRoleUnavailable;
        }
        try role.machine.commit(size);
        if (self.path == .sdl_popup_window) {
            var recorded: Plan = .{};
            try planMapping(&recorded, 0, size);
            self.plan = recorded;
            return;
        }
        const api = role.events.api orelse return error.AlreadyDestroyed;
        const surface = role.wl.surface orelse return error.AlreadyDestroyed;
        var plan: Plan = .{};
        try planMapping(&plan, role.machine.acked_serial orelse 0, size);
        self.plan = plan;
        _ = api.proxy_marshal_flags(
            surface,
            wayland.opcode.wl_surface_commit,
            null,
            api.proxy_get_version(surface),
            0,
        );
        if (role.wl.display) |display| _ = api.display_flush(display);
    }

    /// Move a mapped popup to a new anchor with `xdg_popup.reposition`.
    ///
    /// The request exists only from `xdg_popup` version 3, so a lower binding
    /// is refused by name: on that path the compositor owns the placement and
    /// there is no protocol way to ask it again, so this tree will not place
    /// the popup itself and call that a reposition. The token is the caller's
    /// and comes back in `repositioned`; the new position takes effect once
    /// the configure that follows is acknowledged, which is the same rule the
    /// first configure follows.
    pub fn reposition(self: *NativePopup, request: Request, token: u32) !void {
        if (!self.window_alive) return error.AlreadyClosed;
        if (self.path != .xdg_popup) return error.NotApplicableOnThisDriver;
        const role = self.role;
        const popup = role.wl.popup orelse return error.NativeRoleUnavailable;
        const api = role.events.api orelse return error.AlreadyDestroyed;
        if (role.wl.popup_version < wayland.since_version.xdg_popup_reposition) {
            return error.RepositionUnsupported;
        }
        // The request places an already-mapped popup, so asking before the
        // first commit or after a dismissal is a state the protocol does not
        // accept and no request is sent into it.
        if (role.machine.commit_count == 0) return error.ProtocolViolation;
        if (role.machine.state == .dismissed or role.machine.state == .closed) {
            return error.AlreadyClosed;
        }
        const wm_base = role.wl.wm_base orelse return error.AlreadyDestroyed;
        const display = role.wl.display orelse return error.AlreadyDestroyed;

        var plan: Plan = .{};
        try planReposition(&plan, request, token);
        self.plan = plan;

        const positioner = try buildPositioner(api, wm_base, request);
        // The request names the positioner and its destroy follows it into the
        // same flush, so the compositor copies the rules and the object goes
        // out in one write. `xdg_popup.reposition` creates no remote object, so
        // a null return is what a sent request looks like.
        _ = api.proxy_marshal_flags(
            popup,
            wayland.opcode.xdg_popup_reposition,
            null,
            role.wl.popup_version,
            0,
            positioner,
            token,
        );
        releasePositioner(api, positioner);
        if (flushRefused(api, display)) return error.MarshalRejected;

        // The machine records the request only now, so its count never names a
        // reposition the compositor was never asked for. As in `create`, the
        // prediction is this tree's own answer, to be compared with the
        // compositor's rather than sent as a placement.
        try role.machine.reposition(
            request.positioner,
            role.machine.parent_bounds,
            role.machine.work_area,
        );
        role.machine.placement = request.predicted;
    }

    /// Deliver whatever the compositor has queued, without blocking. A negative
    /// result is a protocol error on the shared connection.
    pub fn pump(self: *NativePopup) i32 {
        const api = self.role.events.api orelse return 0;
        const display = self.role.wl.display orelse return 0;
        return api.display_dispatch_pending(display);
    }

    /// Map the popup on a display server that maps its window directly.
    ///
    /// The xdg-shell path has no show step: the role exists from `attachRole`
    /// and the popup is mapped by the configure, its acknowledgement and the
    /// commit. Asking for `show` there is asking for a step the protocol does
    /// not have, so it is refused by name rather than mapped behind the
    /// caller's back.
    ///
    /// Every failure here releases the role, because a popup that could not be
    /// shown has no life of its own. The value is left closed and readable, so
    /// a caller can report `plan` before its own `deinit` poisons it.
    pub fn show(self: *NativePopup) !void {
        if (!self.window_alive) return error.AlreadyClosed;
        if (self.path != .sdl_popup_window) {
            self.release();
            return error.NotApplicableOnThisDriver;
        }
        self.role.window.show() catch |err| {
            self.release();
            return err;
        };
        self.handles = readHandles(self.role.window) catch |err| {
            self.release();
            return err;
        };
        if (!self.handles.hasRealPopupRole()) {
            self.release();
            return error.NativeRoleUnavailable;
        }
        const rect = self.role.machine.placement.rect;
        self.commit(.{ .width = rect.width, .height = rect.height }) catch |err| {
            self.release();
            return err;
        };
    }

    /// Dismiss the popup, release its role exactly once, and report the order
    /// the teardown went out in.
    ///
    /// The plan comes back instead of being read from a value this call has
    /// just emptied, so a caller can show what was released. A second
    /// `dismiss` is refused with `AlreadyClosed` rather than releasing twice,
    /// and `deinit` after a dismissal only poisons the value.
    pub fn dismiss(self: *NativePopup) !Plan {
        if (!self.window_alive) return error.AlreadyClosed;
        try self.role.machine.dismiss();
        self.release();
        return self.plan;
    }

    /// The parent window closed. A compositor that also sends `popup_done` for
    /// the same closure is counted separately in `popup_done_count`.
    pub fn onParentClose(self: *NativePopup) void {
        if (!self.window_alive) return;
        if (self.role.x11) |*held| held.ungrab();
        self.role.machine.onParentClose();
    }

    /// Create the popup's GPU surface after its native role exists.
    /// The caller owns the result and must release it before this popup.
    pub fn createGpuSurface(
        self: *NativePopup,
        gpu: *noapi.Gpu,
        extent: noapi.Extent2D,
    ) !noapi.Surface {
        if (!self.window_alive) return error.AlreadyClosed;
        if (self.path == .xdg_popup and self.role.wl.popup == null) {
            return error.NativeRoleUnavailable;
        }
        return noapi.Surface.initSdl(
            gpu,
            @ptrCast(self.role.window.value),
            @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
            .{ .extent = extent },
        );
    }

    /// Release the role and the window, recording the teardown order in `plan`.
    ///
    /// The value stays readable in its closed state: `window_alive` is false,
    /// `plan` names the requests that were sent, and the role is gone. Only
    /// `deinit` poisons it, and only its owner calls that.
    fn release(self: *NativePopup) void {
        self.window_alive = false;
        const role = self.role;
        // A display-server grab is released by `role.deinit`, above the window
        // destruction it was taken against. The plan records the request here
        // so a caller reading `dismiss`'s result sees the ungrab in the order
        // it went out, which is the one thing the teardown cannot report after
        // the value has gone.
        if (role.x11 != null) {
            var held: Plan = .{};
            planX11Ungrab(&held) catch |err| {
                // One request goes into a buffer of twenty, so this cannot
                // fire while that holds.
                std.log.warn("x11 ungrab plan rejected: {t}", .{err});
            };
            self.plan = held;
        }
        if (role.events.api) |api| {
            var plan: Plan = .{};
            planTeardown(
                &plan,
                role.wl.popup != null,
                role.wl.xdg_surface != null,
                role.wl.seat != null,
                role.wl.wm_base != null,
            ) catch |err| {
                // Four requests go into a buffer of twenty, so this cannot
                // fire while that holds. The role dies either way, and
                // `self.plan` still reports what the plan did take.
                std.log.warn("popup teardown plan rejected: {t}", .{err});
            };
            self.plan = plan;
            releaseProxies(api, &role.wl);
        }
        role.deinit();
    }

    /// Destroy the role, the platform surface and the window exactly once, and
    /// poison the value so a use after free is a compile error rather than a
    /// silent second teardown.
    pub fn deinit(self: *NativePopup) void {
        if (self.window_alive) self.release();
        self.* = undefined;
    }

    /// Send the teardown in the protocol's order: the role object, the
    /// `xdg_surface` that carried it, the seat, then the shell that made both.
    fn releaseProxies(api: wayland.Api, wl: *Wayland) void {
        if (wl.popup) |proxy| {
            _ = api.proxy_marshal_flags(
                proxy,
                wayland.opcode.xdg_popup_destroy,
                null,
                api.proxy_get_version(proxy),
                wayland.marshal_destroy,
            );
            wl.popup = null;
        }
        if (wl.xdg_surface) |proxy| {
            // `xdg_surface` may only be destroyed after its role object, so the
            // popup above is always released first.
            _ = api.proxy_marshal_flags(
                proxy,
                wayland.opcode.xdg_surface_destroy,
                null,
                api.proxy_get_version(proxy),
                wayland.marshal_destroy,
            );
            wl.xdg_surface = null;
        }
        if (wl.seat) |proxy| {
            // `wl_seat.release` exists from version 5. A lower binding has no
            // destructor to send, and sending one anyway is a fatal protocol
            // error, so the local proxy is dropped instead.
            const version = api.proxy_get_version(proxy);
            if (wayland.seatCanRelease(version)) {
                _ = api.proxy_marshal_flags(
                    proxy,
                    wayland.destructor.wl_seat_release,
                    null,
                    version,
                    wayland.marshal_destroy,
                );
            } else api.proxy_destroy(proxy);
            wl.seat = null;
        }
        if (wl.wm_base) |proxy| {
            _ = api.proxy_marshal_flags(
                proxy,
                wayland.opcode.xdg_wm_base_destroy,
                null,
                api.proxy_get_version(proxy),
                wayland.marshal_destroy,
            );
            wl.wm_base = null;
        }
        if (wl.registry) |registry| {
            api.proxy_destroy(@ptrCast(registry));
            wl.registry = null;
        }
        if (wl.display) |display| _ = api.display_flush(display);
    }
};

/// A roleless SDL window: the only surface that may take a role this tree
/// assigns itself. The window stays hidden, because showing it is what makes
/// SDL assign a role of its own.
pub fn createRolelessWindow(width: u32, height: u32) !sdl3.video.Window {
    switch (currentDriver()) {
        .wayland => {},
        .headless => return error.HeadlessDisplayServer,
        else => return error.NativeRoleUnavailable,
    }
    const window, const properties = try sdl3.video.Window.initWithProperties(.{
        .title = "nogui-popup",
        .width = width,
        .height = height,
        .hidden = true,
        .vulkan = true,
        .wayland_surface_role_custom = true,
    });
    properties.deinit();
    return window;
}

fn readHandles(window: sdl3.video.Window) !NativeHandles {
    const props = try window.getProperties();
    return .{
        .display = if (props.wayland_display) |v| v.value else null,
        .surface = if (props.wayland_surface) |v| v.value else null,
        .xdg_surface = if (props.wayland_xdg_surface) |v| v.value else null,
        .xdg_popup = if (props.wayland_xdg_popup) |v| v.value else null,
        .xdg_positioner = if (props.wayland_xdg_positioner) |v| v.value else null,
        .x11_display = if (props.x11_display) |v| v.value else null,
        .x11_window = props.x11_window,
    };
}

/// The requests that would give this popup its role, at the version the tree
/// describes. The plan is built from the same function the adapter executes,
/// so a test reads the order that reaches the wire rather than a copy of it.
fn rolePlan(request: Request) Error!Plan {
    var plan: Plan = .{};
    try planRole(&plan, request, wayland.xdg_positioner_interface.version);
    return plan;
}

/// A positioner with every axis meaningful, so a test failure points at the
/// order rule under test and not at an incomplete fixture.
fn sampleRequest(reactive: bool) Request {
    return .{
        .positioner = .{
            .anchor_rect = .{ .x = 40, .y = 220, .width = 120, .height = 32 },
            .anchor = .bottom_left,
            .gravity = .bottom_left,
            .offset = .{ .x = 16, .y = 24 },
            .size = .{ .width = 180, .height = 120 },
            .reactive = reactive,
        },
        .predicted = .{ .rect = .{ .x = 56, .y = 276, .width = 180, .height = 120 } },
    };
}

test "api-w22 a reactive positioner is planned inside the rules it applies to" {
    const plan = try rolePlan(sampleRequest(true));
    const reactive = plan.indexOf(.positioner_set_reactive).?;
    // The compositor copies the rules when `get_popup` arrives, so every one of
    // them, `set_reactive` included, has to precede that request.
    try std.testing.expect(reactive > plan.indexOf(.positioner_set_offset).?);
    try std.testing.expect(reactive < plan.indexOf(.get_xdg_surface).?);
    try std.testing.expectEqual(@as(usize, 1), plan.countOf(.positioner_set_reactive));
}

test "api-w22 a positioner is released only after the request that names it" {
    // `get_popup` takes the positioner as an argument, and the XML only allows
    // the object to be destroyed once that request is complete. A plan that put
    // the destroy first would name an object the compositor has already gone.
    for ([_]bool{ false, true }) |reactive| {
        const plan = try rolePlan(sampleRequest(reactive));
        try std.testing.expect(plan.indexOf(.get_popup).? < plan.indexOf(.destroy_positioner).?);
        try std.testing.expectEqual(@as(usize, 1), plan.countOf(.destroy_positioner));
    }
}

test "api-w22 a positioner that was not asked to react never plans set_reactive" {
    const plan = try rolePlan(sampleRequest(false));
    try std.testing.expectEqual(@as(?usize, null), plan.indexOf(.positioner_set_reactive));
}

test "api-w22 an incomplete positioner is refused before any request is planned" {
    var request = sampleRequest(false);
    request.positioner.size = .{ .width = 0, .height = 0 };
    try std.testing.expectError(error.InvalidSize, rolePlan(request));
    request.positioner.size = .{ .width = 180, .height = 120 };
    request.positioner.anchor_rect.width = 0;
    try std.testing.expectError(error.PositionerIncomplete, rolePlan(request));
}

test "api-w22 a reposition binds nothing and releases its positioner afterwards" {
    var plan: Plan = .{};
    try planReposition(&plan, sampleRequest(true), 30583);
    // The shell is already bound: the popup it made is the one being moved, so
    // a plan that named a bind would report a request this phase never sends.
    try std.testing.expectEqual(@as(?usize, null), plan.indexOf(.bind_wm_base));
    const moved = plan.indexOf(.reposition).?;
    try std.testing.expect(plan.indexOf(.positioner_set_reactive).? < moved);
    try std.testing.expect(moved < plan.indexOf(.destroy_positioner).?);
    try std.testing.expectEqual(@as(u32, 30583), plan.ops[moved].reposition);
}

test "api-w22 the teardown names only what the popup owns, in the protocol's order" {
    var owned: Plan = .{};
    try planTeardown(&owned, true, true, true, true);
    try std.testing.expect(owned.indexOf(.destroy_popup).? < owned.indexOf(.destroy_xdg_surface).?);
    try std.testing.expect(owned.indexOf(.destroy_xdg_surface).? < owned.indexOf(.destroy_seat).?);
    try std.testing.expect(owned.indexOf(.destroy_seat).? < owned.indexOf(.destroy_wm_base).?);
    try std.testing.expectEqual(@as(usize, 4), owned.len);

    // A popup that bound no seat names no seat release: the plan reports the
    // requests that went out, not the ones the protocol would allow.
    var no_seat: Plan = .{};
    try planTeardown(&no_seat, true, true, false, true);
    try std.testing.expectEqual(@as(?usize, null), no_seat.indexOf(.destroy_seat));
    try std.testing.expectEqual(@as(usize, 3), no_seat.len);

    // The X11 path owns no protocol object at all, and an empty plan is what
    // says so rather than a plan full of requests that never existed.
    var none: Plan = .{};
    try planTeardown(&none, false, false, false, false);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "api-w22 a display-server grab names no serial and only after the map" {
    var pop = try state.NativePopup.init(
        .os_surface,
        .window_manager_direct,
        sampleRequest(false).positioner,
        .{ .x = 0, .y = 0, .width = 480, .height = 360 },
        .{ .x = 0, .y = 0, .width = 1600, .height = 2000 },
    );
    // The X protocol's grab is taken on a window, and a window that is not
    // viewable cannot be one, so asking before the map is refused before any
    // request goes out rather than sent for the display server to refuse.
    try std.testing.expectError(error.GrabBeforeMap, pop.requestGrab(null, .{ .confirmed = true }));
    try std.testing.expect(!pop.grab_pending);

    // A display-server grab carries no user-event serial, so a null one is the
    // honest request there and must not be refused the way xdg-shell refuses it.
    try pop.commit(.{ .width = 180, .height = 120 });
    try pop.requestGrab(null, .{ .confirmed = true });
    try std.testing.expect(pop.grab_pending);
    // Still only an intention: the display server has not answered yet.
    try std.testing.expect(!pop.has_grab);
    try pop.onGrabIssued();
    try std.testing.expect(pop.has_grab);
    // The recorded serial is null, because none was sent. It is not zero and
    // not a counted-up number standing in for one the X server never gave.
    try std.testing.expectEqual(@as(?u32, null), pop.seat_serial);
    try std.testing.expect(!pop.grab_pending);
}

test "api-w22 removing an advertised seat prevents a later stale binding" {
    var scan: RegistryScan = .{
        .wm_base_name = 3,
        .wm_base_version = 7,
        .seat_name = 40,
        .seat_version = 9,
    };
    onGlobalRemove(@ptrCast(&scan), undefined, 41);
    try std.testing.expectEqual(@as(u32, 40), scan.seat_name);
    onGlobalRemove(@ptrCast(&scan), undefined, 40);
    try std.testing.expectEqual(@as(u32, 0), scan.seat_name);
    try std.testing.expectEqual(@as(u32, 0), scan.seat_version);
    try std.testing.expect(scan.hasWmBase());
    onGlobal(@ptrCast(&scan), undefined, 42, "wl_seat", 8);
    try std.testing.expectEqual(@as(u32, 42), scan.seat_name);
    try std.testing.expectEqual(@as(u32, 8), scan.seat_version);
    onGlobalRemove(@ptrCast(&scan), undefined, 40);
    try std.testing.expectEqual(@as(u32, 42), scan.seat_name);
}
