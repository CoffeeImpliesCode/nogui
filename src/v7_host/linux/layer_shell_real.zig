//! Real zwlr_layer_shell_v1 adapter driven through the SDL-owned Wayland display.
//!
//! The compositor global is bound from the same connection SDL uses, so the
//! layer surface and the SDL surface share one display and one libwayland copy.
//! An ordinary toplevel is never relabelled as a layer surface: a surface that
//! already carries an `xdg_toplevel` role is refused.
const std = @import("std");
const sdl3 = @import("sdl3");
const wayland = @import("wayland.zig");
const state = @import("layer_shell.zig");

pub const Options = state.LayerShellOptions;
pub const Anchor = state.Anchor;
pub const Margins = state.Margins;
pub const KeyboardInteractivity = state.KeyboardInteractivity;
pub const SurfaceState = state.SurfaceState;
pub const CompositorCapability = state.CompositorCapability;

pub const Error = error{
    /// The active SDL video driver is not Wayland.
    NotWayland,
    /// SDL created no surface for the supplied window.
    MissingSurface,
    /// The output needed to place the layer surface is absent.
    MissingOutput,
    /// libwayland refused to attach a listener.
    ListenerRejected,
    /// The compositor does not advertise zwlr_layer_shell_v1.
    LayerShellUnsupported,
    /// The bound protocol version is older than the requested request.
    ProtocolVersionTooOld,
} || state.LayerShellError;

const layer_shell_global = "zwlr_layer_shell_v1";

/// SDL-supplied native handles for one window, read from documented properties.
pub const Handles = struct {
    /// The `wl_display` from `SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER`.
    display: ?*anyopaque = null,
    /// The `wl_surface` from `SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER`.
    surface: ?*anyopaque = null,
    /// A live `xdg_toplevel` means the surface already has a toplevel role.
    xdg_toplevel: ?*anyopaque = null,
    /// The active SDL video driver name, which rejects X11 and dummy drivers.
    driver_name: ?[]const u8 = null,
    /// Set only for SDL windows created with wayland_surface_role_custom.
    roleless: bool = false,

    pub fn isWayland(self: Handles) bool {
        const name = self.driver_name orelse return false;
        return std.mem.eql(u8, name, "wayland");
    }

    /// A layer surface needs a roleless surface owned by SDL.
    pub fn usable(self: Handles) bool {
        if (!self.isWayland()) return false;
        if (self.display == null) return false;
        if (self.surface == null) return false;
        return self.roleless and self.xdg_toplevel == null;
    }
};

/// Create an SDL-owned, roleless Wayland Vulkan window. The caller must
/// attach a layer role before showing or presenting this window.
pub fn createRolelessWindow(width: u32, height: u32) !sdl3.video.Window {
    const driver = sdl3.video.getCurrentDriverName() orelse return error.NotWayland;
    if (!std.mem.eql(u8, driver, "wayland")) return error.NotWayland;
    const window, const properties = try sdl3.video.Window.initWithProperties(.{
        .title = "nogui-layer",
        .width = width,
        .height = height,
        .hidden = true,
        .vulkan = true,
        .wayland_surface_role_custom = true,
    });
    properties.deinit();
    return window;
}

pub fn readRolelessHandles(window: sdl3.video.Window) !Handles {
    const props = try window.getProperties();
    const handles: Handles = .{
        .display = if (props.wayland_display) |v| v.value else null,
        .surface = if (props.wayland_surface) |v| v.value else null,
        .xdg_toplevel = if (props.wayland_xdg_toplevel) |v| v.value else null,
        .driver_name = sdl3.video.getCurrentDriverName(),
        .roleless = true,
    };
    if (!handles.usable()) return error.LayerShellUnsupported;
    return handles;
}

/// Globals collected while a registry round trip runs on the SDL display.
const RegistryScan = struct {
    layer_shell_name: u32 = 0,
    layer_shell_version: u32 = 0,
    output_name: u32 = 0,
    output_version: u32 = 0,
    compositor_name: u32 = 0,
    compositor_version: u32 = 0,
    selected_output_name: u32 = 0,
    output_removed: bool = false,
    machine: ?*state.LayerSurface = null,
    /// The output state of a bound surface, so removing that output can detach
    /// the listener which outlives it. A bare round trip binds no output, so
    /// this stays null there.
    output_state: ?*OutputState = null,
    /// The role listener of a bound surface, so removing the output that
    /// surface was placed on can detach that listener too. A bare round trip
    /// binds no role, so this stays null there.
    role: ?*RoleBinding = null,
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
    const text = std.mem.span(interface);
    if (std.mem.eql(u8, text, layer_shell_global)) {
        scan.layer_shell_name = name;
        scan.layer_shell_version = version;
    } else if (std.mem.eql(u8, text, "wl_output")) {
        if (scan.selected_output_name == 0 and (scan.output_name == 0 or name < scan.output_name)) {
            scan.output_name = name;
            scan.output_version = version;
        }
    } else if (std.mem.eql(u8, text, "wl_compositor")) {
        scan.compositor_name = name;
        scan.compositor_version = version;
    }
}

fn onGlobalRemove(data: ?*anyopaque, registry: *wayland.Registry, name: u32) callconv(.c) void {
    _ = registry;
    const scan: *RegistryScan = @ptrCast(@alignCast(data orelse return));
    if (name == (if (scan.selected_output_name != 0) scan.selected_output_name else scan.output_name)) {
        scan.output_removed = true;
        // The output listener and the role listener both outlive the surface
        // they feed, so both are detached here for the same reason `deinit`
        // detaches them: a `done` batch or a `configure` already in flight
        // must not write into a machine this removal has just closed. Each
        // release is a single null store, so a repeated removal cannot repeat
        // one.
        if (scan.output_state) |out| out.machine = null;
        if (scan.machine) |machine| {
            if (scan.role) |role| role.machine = null;
            machine.handleOutputDisconnected();
        }
    }
    if (name == scan.layer_shell_name) scan.layer_shell_name = 0;
}

const registry_listener: wayland.RegistryListener = .{
    .global = onGlobal,
    .global_remove = onGlobalRemove,
};

/// The `wl_output` state a layer surface keeps for the output it is placed on.
///
/// The compositor sends `geometry`, `mode` and `done` as one batch, and `done`
/// is what makes the batch current. A layer surface anchored to an edge follows
/// that edge, so the mode in the batch decides the size the next commit will be
/// given.
pub const OutputState = struct {
    /// The current mode, applied at the last `done`.
    width: u32 = 0,
    height: u32 = 0,
    /// The pending mode, replaced by `done`.
    pending_width: u32 = 0,
    pending_height: u32 = 0,
    scale: i32 = 1,
    /// The connector name, which arrived in `wl_output` version 4.
    name: [64]u8 = @splat(0),
    name_len: usize = 0,
    /// How many `done` events arrived.
    done_count: u32 = 0,
    machine: ?*state.LayerSurface = null,

    fn onMode(self: *OutputState, width: i32, height: i32) void {
        if (width <= 0 or height <= 0) return;
        self.pending_width = @intCast(width);
        self.pending_height = @intCast(height);
    }

    /// Apply the batch the compositor just finished describing. A mode that did
    /// not change is not pushed onto the surface, so a `done` for an unchanged
    /// output does not cost the surface its configure acknowledgement.
    fn onDone(self: *OutputState) void {
        self.done_count += 1;
        if (self.pending_width == 0 or self.pending_height == 0) return;
        if (self.pending_width == self.width and self.pending_height == self.height) return;
        self.width = self.pending_width;
        self.height = self.pending_height;
        const machine = self.machine orelse return;
        // A compositor event has no error channel back to the wire, so a
        // rejected geometry is logged and the next batch supersedes it.
        machine.handleOutputChanged(self.width, self.height) catch |err| {
            std.log.warn("layer output {d}x{d} rejected: {t}", .{
                self.width,
                self.height,
                err,
            });
        };
    }
};

fn onOutputGeometry(
    data: ?*anyopaque,
    output: *wayland.Proxy,
    x: i32,
    y: i32,
    physical_width: i32,
    physical_height: i32,
    subpixel: i32,
    transform: i32,
    make: [*:0]const u8,
    model: [*:0]const u8,
) callconv(.c) void {
    _ = .{ data, output, x, y, physical_width, physical_height, subpixel, transform, make, model };
}

fn onOutputMode(
    data: ?*anyopaque,
    output: *wayland.Proxy,
    flags: u32,
    width: i32,
    height: i32,
    refresh: i32,
) callconv(.c) void {
    _ = .{ output, flags, refresh };
    const state_out: *OutputState = @ptrCast(@alignCast(data orelse return));
    // Only the current mode changes the surface; the other flags describe why
    // a mode was advertised.
    if (flags & 0b1 != 0) state_out.onMode(width, height);
}

fn onOutputDone(data: ?*anyopaque, output: *wayland.Proxy) callconv(.c) void {
    _ = output;
    const state_out: *OutputState = @ptrCast(@alignCast(data orelse return));
    state_out.onDone();
}

fn onOutputScale(data: ?*anyopaque, output: *wayland.Proxy, factor: i32) callconv(.c) void {
    _ = output;
    const state_out: *OutputState = @ptrCast(@alignCast(data orelse return));
    state_out.scale = factor;
}

fn onOutputName(data: ?*anyopaque, output: *wayland.Proxy, name: [*:0]const u8) callconv(.c) void {
    _ = output;
    const state_out: *OutputState = @ptrCast(@alignCast(data orelse return));
    const text = std.mem.span(name);
    const keep = @min(text.len, state_out.name.len);
    @memcpy(state_out.name[0..keep], text[0..keep]);
    state_out.name_len = keep;
}

fn onOutputDescription(
    data: ?*anyopaque,
    output: *wayland.Proxy,
    description: [*:0]const u8,
) callconv(.c) void {
    _ = .{ data, output, description };
}

const output_listener: wayland.OutputListener = .{
    .geometry = onOutputGeometry,
    .mode = onOutputMode,
    .done = onOutputDone,
    .scale = onOutputScale,
    .name = onOutputName,
    .description = onOutputDescription,
};

/// Read the live compositor advertisement without changing any surface role.
pub fn probe(api: wayland.Api, handles: Handles) CompositorCapability {
    if (!handles.isWayland()) return .unavailable;
    const display = handles.display orelse return .unavailable;
    if (handles.xdg_toplevel != null or !handles.roleless) return .unavailable;

    const wl_display: *wayland.Display = @ptrCast(display);
    const registry = api.displayGetRegistry(wl_display) orelse return .unavailable;
    defer api.proxy_destroy(@ptrCast(registry));
    var scan: RegistryScan = .{};
    if (api.proxy_add_listener(
        @ptrCast(registry),
        @ptrCast(&registry_listener),
        &scan,
    ) != 0) return .unavailable;
    if (api.display_roundtrip(wl_display) < 0) return .unavailable;
    return if (scan.layer_shell_name != 0) .supported else .unavailable;
}

const LayerSurfaceListener = extern struct {
    configure: *const fn (
        data: ?*anyopaque,
        surface: *wayland.Proxy,
        serial: u32,
        width: u32,
        height: u32,
    ) callconv(.c) void,
    closed: *const fn (
        data: ?*anyopaque,
        surface: *wayland.Proxy,
    ) callconv(.c) void,
};

/// The `zwlr_layer_surface_v1` listener's handle on the state machine.
///
/// The listener lives on a proxy, and libwayland offers no request that
/// detaches it, so it reaches the machine through this nullable pointer rather
/// than through `&machine` itself. Clearing the pointer releases the listener:
/// an event the compositor had already dispatched then finds nothing to write
/// into instead of reaching a value that no longer exists.
const RoleBinding = struct {
    machine: ?*state.LayerSurface = null,
};

fn onConfigure(
    data: ?*anyopaque,
    surface: *wayland.Proxy,
    serial: u32,
    width: u32,
    height: u32,
) callconv(.c) void {
    _ = surface;
    const binding: *RoleBinding = @ptrCast(@alignCast(data orelse return));
    const machine = binding.machine orelse return;
    // A compositor event has no error channel back to the wire, so a rejected
    // configure is logged; the next configure supersedes it.
    machine.handleConfigure(serial, width, height) catch |err| {
        std.log.warn("layer surface configure {d} rejected: {t}", .{ serial, err });
    };
}

fn onClosed(data: ?*anyopaque, surface: *wayland.Proxy) callconv(.c) void {
    _ = surface;
    const binding: *RoleBinding = @ptrCast(@alignCast(data orelse return));
    const machine = binding.machine orelse return;
    // A `closed` finishes the role, so the listener is released here for the
    // same reason `deinit` releases it: a configure the compositor had already
    // queued must find a finished surface rather than log against a dead one.
    // The release is a single null store, so a repeated `closed` cannot claim
    // the teardown twice.
    binding.machine = null;
    machine.handleClosed();
}

const layer_surface_listener: LayerSurfaceListener = .{
    .configure = onConfigure,
    .closed = onClosed,
};

/// Whether a request may still be marshalled onto a layer surface.
///
/// A compositor `closed`, a removed output and a client teardown each end the
/// surface's life at a different point, and every path that could still talk
/// to the role asks this question the same way.
pub const RequestRefusal = enum {
    /// The request may go on the wire.
    none,
    /// The role is finished: the compositor closed it, or it was torn down here.
    surface_finished,
    /// The output the surface was placed on is gone from the compositor.
    output_gone,
};

/// The one answer to "may this surface still be talked to".
///
/// `zwlr_layer_surface_v1` has no request that re-opens a closed surface and no
/// request that moves a layer surface to another output, so every refusal here
/// ends in a new layer surface rather than in a retry against the dead one.
pub fn refusalFor(surface_state: SurfaceState, output_removed: bool) RequestRefusal {
    return switch (surface_state) {
        .closed, .destroyed => .surface_finished,
        .uninitialized, .attached, .configured, .mapped => if (output_removed) .output_gone else .none,
    };
}

/// Live layer surface owning the compositor proxies plus its state machine.
pub const LayerSurface = struct {
    api: ?wayland.Api = null,
    machine: state.LayerSurface,
    display: ?*wayland.Display = null,
    shell: ?*wayland.Proxy = null,
    surface: ?*wayland.Proxy = null,
    layer_surface: ?*wayland.Proxy = null,
    output: ?*wayland.Proxy = null,
    compositor: ?*wayland.Proxy = null,
    registry: ?*wayland.Registry = null,
    scan: RegistryScan = .{},
    /// The output this surface is placed on, as the compositor describes it.
    output_state: OutputState = .{},
    /// The live role listener's handle on `machine`, so a close can release
    /// the listener without destroying the state machine the caller reads.
    role: RoleBinding = .{},
    /// True once a `wl_region` is on this surface, so the way back to the
    /// compositor's infinite default is known to need a request of its own.
    input_region_published: bool = false,

    /// Create the state machine only. No native call happens here.
    pub fn init(options: Options) state.LayerShellError!LayerSurface {
        return .{ .machine = try state.LayerSurface.init(options, .supported) };
    }

    /// Attach a real `zwlr_layer_surface_v1` role to a roleless SDL surface.
    ///
    /// The caller must hold `LayerSurface` by address first: the compositor
    /// listener stores a pointer into this value and outlives this call.
    pub fn attach(self: *LayerSurface, api: wayland.Api, handles: Handles, options: Options) !void {
        if (!handles.isWayland()) return error.NotWayland;
        if (handles.display == null or handles.surface == null) return error.MissingSurface;
        // A surface that already carries a toplevel role is never reused here.
        if (handles.xdg_toplevel != null or !handles.roleless) return error.LayerShellUnsupported;
        if (self.layer_surface != null) return error.ProtocolViolation;
        // One role per state machine. A second role would inherit the
        // configure serial and commit count of a role the compositor has
        // already dropped, so every later answer would describe the wrong
        // surface. A failed attach releases its own proxies through
        // `releaseNative`, so retrying one needs a new `LayerSurface`.
        if (self.machine.state != .attached or
            self.machine.configured_count != 0 or
            self.machine.committed_count != 0)
        {
            return error.ProtocolViolation;
        }
        self.machine.options = options;

        const display: *wayland.Display = @ptrCast(handles.display.?);
        const surface: *wayland.Proxy = @ptrCast(handles.surface.?);

        self.scan = .{
            .machine = &self.machine,
            .output_state = &self.output_state,
            .role = &self.role,
        };
        const registry = api.displayGetRegistry(display) orelse
            return error.LayerShellUnsupported;
        var registry_owned = true;
        errdefer if (registry_owned) api.proxy_destroy(@ptrCast(registry));
        if (api.proxy_add_listener(
            @ptrCast(registry),
            @ptrCast(&registry_listener),
            &self.scan,
        ) != 0) return error.ListenerRejected;
        if (api.display_roundtrip(display) < 0) return error.LayerShellUnsupported;
        if (self.scan.layer_shell_name == 0) return error.LayerShellUnsupported;
        if (self.scan.output_name == 0 or self.scan.output_removed) return error.MissingOutput;
        self.scan.selected_output_name = self.scan.output_name;
        const shell_version = @min(self.scan.layer_shell_version, wayland.layer_shell_interface.version);
        if (shell_version < 2 or
            (options.keyboard_interactivity == .on_demand and shell_version < 4))
        {
            return error.ProtocolVersionTooOld;
        }

        const shell = api.registryBind(
            registry,
            self.scan.layer_shell_name,
            &wayland.layer_shell_interface,
            shell_version,
        ) orelse return error.LayerShellUnsupported;

        const output = api.registryBind(
            registry,
            self.scan.output_name,
            &wayland.wl_output_interface,
            @min(self.scan.output_version, wayland.wl_output_interface.version),
        ) orelse {
            api.proxy_destroy(shell);
            return error.MissingOutput;
        };
        if (self.scan.compositor_name == 0) {
            api.proxy_destroy(output);
            api.proxy_destroy(shell);
            return error.LayerShellUnsupported;
        }
        const compositor = api.registryBind(
            registry,
            self.scan.compositor_name,
            &wayland.wl_compositor_interface,
            @min(self.scan.compositor_version, wayland.wl_compositor_interface.version),
        ) orelse {
            api.proxy_destroy(output);
            api.proxy_destroy(shell);
            return error.LayerShellUnsupported;
        };

        // get_layer_surface(new_id surface, surface, output, layer, namespace)
        const layer_surface = api.proxy_marshal_flags(
            shell,
            wayland.layer_shell_get_layer_surface_opcode,
            &wayland.layer_surface_interface,
            @min(shell_version, wayland.layer_surface_interface.version),
            0,
            @as(?*wayland.Proxy, null),
            surface,
            output,
            @as(u32, @backingInt(options.layer)),
            options.namespace.ptr,
        ) orelse {
            api.proxy_destroy(compositor);
            api.proxy_destroy(output);
            api.proxy_destroy(shell);
            return error.LayerShellUnsupported;
        };

        // The listener is registered on the binding rather than on
        // `&self.machine`, so a close releases the listener while the state
        // machine stays readable for the caller.
        self.role.machine = &self.machine;
        if (api.proxy_add_listener(
            layer_surface,
            @ptrCast(&layer_surface_listener),
            &self.role,
        ) != 0) {
            self.role.machine = null;
            api.proxy_destroy(layer_surface);
            api.proxy_destroy(compositor);
            api.proxy_destroy(output);
            api.proxy_destroy(shell);
            return error.ListenerRejected;
        }

        self.api = api;
        self.display = display;
        self.shell = shell;
        self.surface = surface;
        self.layer_surface = layer_surface;
        self.output = output;
        self.compositor = compositor;
        self.registry = registry;
        registry_owned = false;
        self.scan.machine = &self.machine;
        errdefer self.releaseNative();

        try self.applyOptions();
        // A roleless wl_surface needs an initial commit with no buffer to
        // prompt the compositor's first configure.
        _ = api.proxy_marshal_flags(
            surface,
            wayland.opcode.wl_surface_commit,
            null,
            api.proxy_get_version(surface),
            0,
        );
        // The output's own geometry batch is asked for after the role exists, so
        // the surface already has a machine to apply a mode change to.
        self.output_state = .{ .machine = &self.machine };
        if (api.proxy_add_listener(
            output,
            @ptrCast(&output_listener),
            &self.output_state,
        ) != 0) return error.ListenerRejected;
        _ = api.display_flush(display);
    }

    /// The output this surface is placed on, as the compositor last described
    /// it. A `done_count` of zero means the compositor has not finished a
    /// geometry batch yet, so nothing about that output is known.
    pub fn outputGeometry(self: *const LayerSurface) OutputState {
        return self.output_state;
    }

    /// The connector name the compositor reported, empty until it does.
    pub fn outputName(self: *const LayerSurface) []const u8 {
        return self.output_state.name[0..self.output_state.name_len];
    }

    /// True when a real layer role is attached to a live compositor proxy.
    pub fn isAttached(self: *const LayerSurface) bool {
        return self.layer_surface != null;
    }

    /// True once the compositor has removed the output this surface was placed
    /// on. No request moves a layer surface to a different output, so this is
    /// terminal for the role: the way forward is a new layer surface.
    pub fn outputDisconnected(self: *const LayerSurface) bool {
        return self.scan.output_removed;
    }

    /// The exclusive zone that goes on the wire for the current anchor set.
    ///
    /// A positive zone an anchor set cannot express is sent as zero, which is
    /// what the compositor does with it anyway, so the request and
    /// `LayerSurface.reservedZone` can never report different numbers. A
    /// negative zone asks the compositor to ignore other reservations and is
    /// passed through whatever the anchors are.
    pub fn exclusiveZoneRequest(self: *const LayerSurface) i32 {
        const want: *const Options = &self.machine.options;
        return want.anchor.effectiveExclusiveZone(want.exclusive_zone);
    }

    /// The live connection and role every request needs, resolved before
    /// anything is recorded or marshalled.
    const Live = struct {
        api: wayland.Api,
        role: *wayland.Proxy,

        fn flush(self: Live, display: ?*wayland.Display) void {
            if (display) |wl| _ = self.api.display_flush(wl);
        }
    };

    /// Resolve the live connection and role, or refuse before anything is
    /// recorded or marshalled.
    fn requireLive(self: *LayerSurface) Error!Live {
        const api = self.api orelse return error.AlreadyDestroyed;
        const role = self.layer_surface orelse return error.AlreadyDestroyed;
        return switch (refusalFor(self.machine.state, self.scan.output_removed)) {
            .none => .{ .api = api, .role = role },
            .surface_finished => error.AlreadyDestroyed,
            .output_gone => error.OutputDisconnected,
        };
    }

    /// Republish the whole options snapshot onto the live layer surface.
    ///
    /// `attach` sends this once for a new role. A live update goes through the
    /// single-request setters below instead, because `set_size` and `set_anchor`
    /// are stateful on the compositor: republishing them from the original
    /// `Options` would withdraw a size the compositor has already granted, and
    /// the answer to that is a second configure nobody asked for.
    /// `setDesiredSize` is the live counterpart of the `set_size` line below.
    pub fn applyOptions(self: *LayerSurface) !void {
        const live = try self.requireLive();
        const api = live.api;
        const proxy = live.role;
        const want: *const Options = &self.machine.options;
        if (want.input_region.count > want.input_region.rects.len) return error.InvalidDimensions;
        if (want.keyboard_interactivity == .on_demand and api.proxy_get_version(proxy) < 4) {
            return error.ProtocolVersionTooOld;
        }
        _ = api.proxy_marshal_flags(
            proxy,
            wayland.layer_surface_opcode.set_size,
            null,
            0,
            0,
            want.desired_width,
            want.desired_height,
        );
        _ = api.proxy_marshal_flags(
            proxy,
            wayland.layer_surface_opcode.set_anchor,
            null,
            0,
            0,
            anchorBits(want.anchor),
        );
        // One number goes on the wire here: the zone these anchors can
        // express, which is what `reservedZone` reports, rather than a request
        // the compositor would silently reduce to zero.
        _ = api.proxy_marshal_flags(
            proxy,
            wayland.layer_surface_opcode.set_exclusive_zone,
            null,
            0,
            0,
            self.exclusiveZoneRequest(),
        );
        _ = api.proxy_marshal_flags(
            proxy,
            wayland.layer_surface_opcode.set_margin,
            null,
            0,
            0,
            want.margins.top,
            want.margins.right,
            want.margins.bottom,
            want.margins.left,
        );
        _ = api.proxy_marshal_flags(
            proxy,
            wayland.layer_surface_opcode.set_keyboard_interactivity,
            null,
            0,
            0,
            @as(u32, @backingInt(want.keyboard_interactivity)),
        );
        try self.applyInputRegion(&want.input_region);
        live.flush(self.display);
    }

    /// Push the input region onto the live surface.
    ///
    /// The region is borrowed, not copied: the rectangles marshalled below are
    /// the ones the caller's own region holds, read through the plan's view of
    /// it, so nothing between the call and the marshalling can change what
    /// goes on the wire.
    ///
    /// The three shapes are not interchangeable, and the difference is the whole
    /// point of the request: `wayland.xml` line 1697 says the initial value is
    /// infinite and that a null `wl_region` also means infinite, so click-through
    /// needs a region that exists and is empty. Sending nothing at all, an empty
    /// region and a null region are three different requests, and the request
    /// tells them apart — including the way back, which needs the null region on
    /// the wire because an empty one never expires on its own.
    fn applyInputRegion(self: *LayerSurface, region: *const state.InputRegion) !void {
        const live = try self.requireLive();
        const api = live.api;
        const surface = self.surface orelse return error.AlreadyDestroyed;
        const compositor = self.compositor orelse return error.LayerShellUnsupported;
        if (region.count > region.rects.len) return error.InvalidDimensions;

        // The plan is a view of the caller's region, which outlives the loop
        // below: the rectangles marshalled here are the ones the caller holds,
        // not a copy that anything else could have written over.
        const plan = region.plan();
        if (!plan.send_region) {
            if (!self.input_region_published) {
                // The compositor's initial value already accepts input
                // everywhere, so there is no request to make.
                return;
            }
            // A region is already on the wire, so returning to the compositor
            // default takes a request of its own. Sending nothing would leave
            // the surface click-through for the rest of its life.
            _ = api.proxy_marshal_flags(
                surface,
                wayland.opcode.wl_surface_set_input_region,
                null,
                api.proxy_get_version(surface),
                0,
                @as(?*wayland.Proxy, null),
            );
            self.input_region_published = false;
            live.flush(self.display);
            return;
        }

        const proxy = api.proxy_marshal_flags(
            compositor,
            wayland.opcode.wl_compositor_create_region,
            &wayland.wl_region_interface,
            api.proxy_get_version(compositor),
            0,
            @as(?*wayland.Proxy, null),
        ) orelse return error.LayerShellUnsupported;
        // Registered before the region's own destructor, so the flush runs
        // after it: that destructor is a request too.
        defer live.flush(self.display);
        defer _ = api.proxy_marshal_flags(proxy, 0, null, api.proxy_get_version(proxy), wayland.marshal_destroy);
        for (plan.rects) |rect| {
            if (rect.width > std.math.maxInt(i32) or
                rect.height > std.math.maxInt(i32))
            {
                return error.InvalidDimensions;
            }
            _ = api.proxy_marshal_flags(
                proxy,
                wayland.opcode.wl_region_add,
                null,
                api.proxy_get_version(proxy),
                0,
                rect.x,
                rect.y,
                @as(i32, @intCast(rect.width)),
                @as(i32, @intCast(rect.height)),
            );
        }
        _ = api.proxy_marshal_flags(
            surface,
            wayland.opcode.wl_surface_set_input_region,
            null,
            api.proxy_get_version(surface),
            0,
            proxy,
        );
        self.input_region_published = true;
    }

    /// Push the input region and record it.
    ///
    /// The wire is updated first, so a refusal leaves the recorded options
    /// describing what the compositor actually has.
    pub fn setInputRegion(self: *LayerSurface, region: state.InputRegion) !void {
        try self.applyInputRegion(&region);
        self.machine.setInputRegion(region);
    }

    /// Ask the compositor for a new size on the live surface.
    ///
    /// This is the one option that cannot be republished from the original
    /// snapshot, because the compositor reads `set_size` as a standing request
    /// rather than a one-shot: sending it again would withdraw the size an
    /// earlier configure already granted. The answer is a fresh configure,
    /// acknowledged exactly as the first one was.
    pub fn setDesiredSize(self: *LayerSurface, width: u32, height: u32) !void {
        const live = try self.requireLive();
        self.machine.options.desired_width = width;
        self.machine.options.desired_height = height;
        _ = live.api.proxy_marshal_flags(
            live.role,
            wayland.layer_surface_opcode.set_size,
            null,
            0,
            0,
            width,
            height,
        );
        live.flush(self.display);
    }

    /// Update one option and republish exactly that request.
    ///
    /// Every setter refuses before it records, so a request that never reaches
    /// the compositor cannot leave the state machine describing an option the
    /// compositor does not have. The change itself takes effect at the next
    /// commit, and a size the compositor disagrees with comes back as a fresh
    /// configure to acknowledge.
    pub fn setAnchor(self: *LayerSurface, anchor: Anchor) !void {
        const live = try self.requireLive();
        self.machine.setAnchor(anchor);
        _ = live.api.proxy_marshal_flags(
            live.role,
            wayland.layer_surface_opcode.set_anchor,
            null,
            0,
            0,
            anchorBits(anchor),
        );
        live.flush(self.display);
    }

    pub fn setMargins(self: *LayerSurface, margins: Margins) !void {
        const live = try self.requireLive();
        self.machine.setMargins(margins);
        _ = live.api.proxy_marshal_flags(
            live.role,
            wayland.layer_surface_opcode.set_margin,
            null,
            0,
            0,
            margins.top,
            margins.right,
            margins.bottom,
            margins.left,
        );
        live.flush(self.display);
    }

    /// Change the space the compositor is asked to reserve.
    ///
    /// The request is legal from the first commit until the surface is closed,
    /// and the compositor applies it at the next commit. What it then reserves
    /// is not observable through this protocol: `zwlr_layer_shell_v1` has no
    /// request that reports the result, so a caller can know only what it asked
    /// for and what its anchors allow.
    pub fn setExclusiveZone(self: *LayerSurface, zone: i32) !void {
        const live = try self.requireLive();
        self.machine.setExclusiveZone(zone);
        _ = live.api.proxy_marshal_flags(
            live.role,
            wayland.layer_surface_opcode.set_exclusive_zone,
            null,
            0,
            0,
            self.exclusiveZoneRequest(),
        );
        live.flush(self.display);
    }

    pub fn setKeyboardInteractivity(
        self: *LayerSurface,
        interactivity: KeyboardInteractivity,
    ) !void {
        const live = try self.requireLive();
        // `on_demand` arrived in version 4, so an older binding is refused
        // before the state machine records the option.
        if (interactivity == .on_demand and live.api.proxy_get_version(live.role) < 4) {
            return error.ProtocolVersionTooOld;
        }
        self.machine.setKeyboardInteractivity(interactivity);
        _ = live.api.proxy_marshal_flags(
            live.role,
            wayland.layer_surface_opcode.set_keyboard_interactivity,
            null,
            0,
            0,
            @as(u32, @backingInt(interactivity)),
        );
        live.flush(self.display);
    }

    /// Acknowledge a compositor configure serial on the real layer surface.
    ///
    /// The acknowledgement goes on the wire only after the state machine has
    /// accepted the serial, so a refused ack neither reaches the compositor nor
    /// spends a serial it is holding.
    pub fn ackConfigure(self: *LayerSurface, serial: u32) !void {
        const live = try self.requireLive();
        if (self.machine.last_configured_serial != serial) return error.UnacknowledgedConfigure;
        try self.machine.ackConfigure();
        _ = live.api.proxy_marshal_flags(
            live.role,
            wayland.layer_surface_ack_configure_opcode,
            null,
            live.api.proxy_get_version(live.role),
            0,
            serial,
        );
        live.flush(self.display);
    }

    /// Acknowledge the newest configure the state machine has recorded.
    pub fn ackLatestConfigure(self: *LayerSurface) !void {
        const serial = self.machine.last_configured_serial orelse
            return error.UnacknowledgedConfigure;
        try self.ackConfigure(serial);
    }

    /// Commit the surface so the compositor maps the layer surface.
    ///
    /// This is the request a closed or a disconnected surface must not make:
    /// the compositor answers a commit after `closed` by killing the display
    /// connection, so the refusal happens before the machine or the wire is
    /// touched.
    pub fn commit(self: *LayerSurface) !void {
        const live = try self.requireLive();
        const surface = self.surface orelse return error.AlreadyDestroyed;
        try self.machine.commit();
        _ = live.api.proxy_marshal_flags(
            surface,
            wayland.opcode.wl_surface_commit,
            null,
            live.api.proxy_get_version(surface),
            0,
        );
        live.flush(self.display);
    }

    /// Claim the one client-side teardown and release the role listener.
    ///
    /// A compositor `closed` and a client close finish a role the same way, so
    /// they finish it the same way: the listener goes first, then the state
    /// machine claims its single teardown. The wire-level destroy still waits
    /// for `deinit`, so `isAttached` stays true until then — the compositor
    /// still holds the role until the destructor reaches it.
    pub fn close(self: *LayerSurface) !void {
        // A surface the compositor already closed, or one whose output is gone,
        // has no client teardown left to claim, and claiming one is exactly the
        // double teardown the state machine refuses to report.
        if (refusalFor(self.machine.state, self.scan.output_removed) != .none) {
            return error.DoubleTeardown;
        }
        _ = try self.requireLive();
        // The listener is released before the machine is consumed, so a
        // configure the compositor had already queued finds nothing instead of
        // reporting itself against a surface the client has closed.
        self.role.machine = null;
        try self.machine.teardown();
    }

    /// Release the role and every proxy this surface owns, leaving the state
    /// machine intact.
    ///
    /// This is the part of a teardown a caller can survive: a failed `attach`
    /// lands here, and the value stays readable, refusing further work because
    /// no role is bound. Each listener is released before any destructor
    /// reaches the wire, and each release is a single null store, so no
    /// teardown can release one twice.
    pub fn releaseNative(self: *LayerSurface) void {
        // The role and output listeners outlive the surface they feed, so both
        // machine pointers go first: a `configure` or a `done` already in
        // flight must not write into a machine that is being torn down. The
        // scan goes with them, so a global removal arriving during teardown
        // finds no machine either.
        self.role.machine = null;
        self.output_state.machine = null;
        self.output_state = .{};
        self.scan.machine = null;
        self.scan.output_state = null;
        self.scan.role = null;
        if (self.api) |api| {
            if (self.layer_surface) |proxy| {
                _ = api.proxy_marshal_flags(
                    proxy,
                    wayland.layer_surface_destroy_opcode,
                    null,
                    api.proxy_get_version(proxy),
                    wayland.marshal_destroy,
                );
            }
            if (self.output) |proxy| {
                const version = api.proxy_get_version(proxy);
                if (wayland.outputCanRelease(version)) {
                    _ = api.proxy_marshal_flags(
                        proxy,
                        wayland.wl_output_release_opcode,
                        null,
                        version,
                        wayland.marshal_destroy,
                    );
                } else api.proxy_destroy(proxy);
            }
            if (self.compositor) |proxy| {
                // `wl_compositor.release` exists from version 7 up only. The
                // bound version is whatever the compositor advertised, capped
                // by the descriptor, so on a version 6 compositor the request
                // has no protocol meaning: sending it would make the server
                // kill the display connection. There is then no destructor to
                // send at all, and dropping the local proxy is the whole
                // release the protocol can offer.
                const version = api.proxy_get_version(proxy);
                if (wayland.compositorCanRelease(version)) {
                    _ = api.proxy_marshal_flags(
                        proxy,
                        wayland.wl_compositor_release_opcode,
                        null,
                        version,
                        wayland.marshal_destroy,
                    );
                } else api.proxy_destroy(proxy);
            }
            if (self.shell) |proxy| {
                // `zwlr_layer_shell_v1.destroy` arrived in version 3, so a
                // version 2 binding is torn down locally instead.
                const version = api.proxy_get_version(proxy);
                if (wayland.layerShellCanDestroy(version)) {
                    _ = api.proxy_marshal_flags(
                        proxy,
                        wayland.layer_shell_destroy_opcode,
                        null,
                        version,
                        wayland.marshal_destroy,
                    );
                } else api.proxy_destroy(proxy);
            }
            if (self.registry) |registry| api.proxy_destroy(@ptrCast(registry));
            // Nothing above reaches the compositor on its own: these are
            // queued requests, and a process that exits straight after this
            // call would otherwise release nothing at all.
            if (self.display) |display| _ = api.display_flush(display);
        }
        self.layer_surface = null;
        self.output = null;
        self.shell = null;
        self.registry = null;
        self.compositor = null;
        self.surface = null;
        self.display = null;
        self.api = null;
        self.scan = .{};
    }

    /// Destroy the layer role exactly once and release the shell binding.
    ///
    /// The destructors are requests the compositor waits for, and the flush at
    /// the end is what puts them on the wire. This consumes the value: a
    /// process that exited straight after this call would otherwise release
    /// nothing, and a second call would read the `undefined` this ends with.
    /// The single teardown is claimed in `machine.deinit`, which does not
    /// re-claim one a compositor `closed`, a `close` or a removed output
    /// already took.
    pub fn deinit(self: *LayerSurface) void {
        self.releaseNative();
        self.machine.deinit();
        self.* = undefined;
    }
};

test "api-w22 removing the selected compositor output closes its layer lifecycle" {
    var machine = try state.LayerSurface.init(.{ .desired_height = 32 }, .supported);
    var scan: RegistryScan = .{
        .output_name = 11,
        .selected_output_name = 11,
        .machine = &machine,
    };
    onGlobal(&scan, @ptrFromInt(0x1000), 8, "wl_output", 4);
    try std.testing.expectEqual(@as(u32, 11), scan.output_name);
    onGlobalRemove(&scan, @ptrFromInt(0x1000), 9);
    try std.testing.expect(machine.output_attached);
    onGlobalRemove(&scan, @ptrFromInt(0x1000), 11);
    try std.testing.expect(scan.output_removed);
    try std.testing.expect(!machine.output_attached);
    try std.testing.expectError(error.AlreadyDestroyed, machine.handleConfigure(12, 100, 32));
    onGlobalRemove(&scan, @ptrFromInt(0x1000), 11);
    try std.testing.expect(machine.teardown_performed);
}

/// Map a packed anchor to the protocol bit order.
pub fn anchorBits(anchor: Anchor) u32 {
    var bits: u32 = 0;
    if (anchor.top) bits |= 1;
    if (anchor.bottom) bits |= 2;
    if (anchor.left) bits |= 4;
    if (anchor.right) bits |= 8;
    return bits;
}

test "api-w22 layer shell adapter refuses non-Wayland and toplevel-role handles" {
    const x11: Handles = .{
        .display = @ptrFromInt(0x1000),
        .surface = @ptrFromInt(0x2000),
        .driver_name = "x11",
    };
    try std.testing.expect(!x11.isWayland());
    try std.testing.expect(!x11.usable());

    const toplevel: Handles = .{
        .display = @ptrFromInt(0x1000),
        .surface = @ptrFromInt(0x2000),
        .xdg_toplevel = @ptrFromInt(0x3000),
        .driver_name = "wayland",
    };
    try std.testing.expect(toplevel.isWayland());
    // A surface that already has a toplevel role is not a layer surface.
    try std.testing.expect(!toplevel.usable());

    const roleless: Handles = .{
        .display = @ptrFromInt(0x1000),
        .surface = @ptrFromInt(0x2000),
        .driver_name = "wayland",
        .roleless = true,
    };
    try std.testing.expect(roleless.usable());
}

test "api-w22 layer shell adapter encodes anchors in protocol bit order" {
    try std.testing.expectEqual(@as(u32, 0), anchorBits(Anchor.none));
    try std.testing.expectEqual(@as(u32, 1), anchorBits(.{ .top = true }));
    try std.testing.expectEqual(@as(u32, 2), anchorBits(.{ .bottom = true }));
    try std.testing.expectEqual(@as(u32, 4), anchorBits(.{ .left = true }));
    try std.testing.expectEqual(@as(u32, 8), anchorBits(.{ .right = true }));
    try std.testing.expectEqual(@as(u32, 15), anchorBits(Anchor.all));
    try std.testing.expectEqual(@as(u32, 13), anchorBits(Anchor.top_dock));
    try std.testing.expectEqual(@as(u32, 14), anchorBits(Anchor.bottom_dock));
    try std.testing.expectEqual(@as(u32, 7), anchorBits(Anchor.left_dock));
    try std.testing.expectEqual(@as(u32, 11), anchorBits(Anchor.right_dock));
}

test "api-w22 layer shell attach refuses handles that are not a real Wayland roleless surface" {
    // A state machine alone never counts as a live layer surface.
    var surface = try LayerSurface.init(.{ .desired_width = 800, .desired_height = 32 });
    try std.testing.expect(!surface.isAttached());
    // Without a resolved API table there is nothing to marshal through.
    try std.testing.expectError(error.NotWayland, surface.attach(undefined, .{
        .display = @ptrFromInt(0x1000),
        .surface = @ptrFromInt(0x2000),
        .driver_name = "x11",
    }, .{}));
    try std.testing.expectError(error.LayerShellUnsupported, surface.attach(undefined, .{
        .display = @ptrFromInt(0x1000),
        .surface = @ptrFromInt(0x2000),
        .driver_name = "wayland",
    }, .{}));
    try std.testing.expect(!surface.isAttached());
}

test "api-w22 a removed output detaches its listener before the machine closes" {
    var machine = try state.LayerSurface.init(.{ .desired_height = 32 }, .supported);
    var output: OutputState = .{ .machine = &machine };
    var scan: RegistryScan = .{
        .output_name = 11,
        .selected_output_name = 11,
        .machine = &machine,
        .output_state = &output,
    };
    onGlobalRemove(&scan, @ptrFromInt(0x1000), 11);
    try std.testing.expect(scan.output_removed);
    try std.testing.expect(machine.teardown_performed);
    // The listener is detached, so a `done` batch already in flight finds no
    // machine to write into instead of pushing a change at a closed surface.
    try std.testing.expect(output.machine == null);
    const after_removal = machine.state;
    onOutputDone(&output, @ptrFromInt(0x2000));
    try std.testing.expectEqual(after_removal, machine.state);
}

test "api-w22 a closed or detached surface refuses every further request" {
    // One decision, asked the same way by the commit path, the ack path and
    // every option update.
    try std.testing.expectEqual(RequestRefusal.none, refusalFor(.uninitialized, false));
    try std.testing.expectEqual(RequestRefusal.none, refusalFor(.attached, false));
    try std.testing.expectEqual(RequestRefusal.none, refusalFor(.configured, false));
    try std.testing.expectEqual(RequestRefusal.none, refusalFor(.mapped, false));
    try std.testing.expectEqual(RequestRefusal.output_gone, refusalFor(.mapped, true));
    try std.testing.expectEqual(RequestRefusal.output_gone, refusalFor(.attached, true));
    try std.testing.expectEqual(RequestRefusal.surface_finished, refusalFor(.closed, false));
    try std.testing.expectEqual(RequestRefusal.surface_finished, refusalFor(.destroyed, false));
    // A surface that is already finished stays finished, whichever of the two
    // events got it there: that teardown is the one the caller claimed.
    try std.testing.expectEqual(RequestRefusal.surface_finished, refusalFor(.destroyed, true));
}

test "api-w22 a refused option update leaves the recorded options untouched" {
    var surface = try LayerSurface.init(.{
        .anchor = .top_dock,
        .exclusive_zone = 64,
    });
    // With no bound role every request is refused, and the refusal lands
    // before the state machine records anything: the options it still reports
    // are the ones the wire would carry.
    try std.testing.expectError(error.AlreadyDestroyed, surface.setAnchor(.all));
    try std.testing.expectError(error.AlreadyDestroyed, surface.setMargins(.{ .top = 1 }));
    try std.testing.expectError(error.AlreadyDestroyed, surface.setExclusiveZone(0));
    try std.testing.expectError(
        error.AlreadyDestroyed,
        surface.setKeyboardInteractivity(.exclusive),
    );
    var region: state.InputRegion = .{};
    region.setPassthrough();
    try std.testing.expectError(error.AlreadyDestroyed, surface.setInputRegion(region));
    try std.testing.expectError(error.AlreadyDestroyed, surface.commit());
    try std.testing.expectEqual(@as(i32, 64), surface.machine.options.exclusive_zone);
    try std.testing.expectEqual(state.Anchor.top_dock, surface.machine.options.anchor);
    try std.testing.expectEqual(Margins{}, surface.machine.options.margins);
    try std.testing.expect(surface.machine.options.keyboard_interactivity == .none);
    try std.testing.expect(surface.machine.options.input_region.mode == .inherit);
    try std.testing.expect(!surface.machine.teardown_performed);
    surface.deinit();
}

test "api-w22 an input region plan reads the rectangles the surface holds" {
    var surface = try LayerSurface.init(.{});
    var region: state.InputRegion = .{};
    region.addRect(.{ .x = 462, .y = 32, .width = 308, .height = 64 });
    surface.machine.setInputRegion(region);

    const plan = surface.machine.inputRegionPlan();
    try std.testing.expect(plan.send_region);
    try std.testing.expectEqual(@as(usize, 1), plan.rects.len);
    try std.testing.expectEqual(region.rects[0], plan.rects[0]);
    // The plan is a view of the options the surface keeps, so a change to the
    // recorded region is a change to what the plan reports. A plan built from
    // a copy of the region would keep reporting that copy's bytes, which is
    // how a marshalled rectangle ends up describing whatever happened to share
    // its storage.
    surface.machine.options.input_region.rects[0].x = 463;
    try std.testing.expectEqual(@as(i32, 463), plan.rects[0].x);

    // The empty and inherited shapes keep their own meaning: a region that
    // exists and carries nothing, and no region at all.
    var empty: state.InputRegion = .{};
    empty.setPassthrough();
    surface.machine.setInputRegion(empty);
    const passthrough = surface.machine.inputRegionPlan();
    try std.testing.expect(passthrough.send_region);
    try std.testing.expectEqual(@as(usize, 0), passthrough.rects.len);
    surface.machine.setInputRegion(.{});
    const inherit = surface.machine.inputRegionPlan();
    try std.testing.expect(!inherit.send_region);
    try std.testing.expectEqual(@as(usize, 0), inherit.rects.len);
    surface.deinit();
}

test "api-w22 the exclusive zone on the wire is the zone the anchors can express" {
    var surface = try LayerSurface.init(.{ .anchor = .top_dock, .exclusive_zone = 64 });
    try std.testing.expectEqual(@as(i32, 64), surface.exclusiveZoneRequest());
    // Four edges cannot express a positive reservation, so the request and the
    // report both fall back to zero rather than to a number the compositor
    // would ignore.
    surface.machine.setAnchor(Anchor.all);
    try std.testing.expectEqual(@as(i32, 0), surface.exclusiveZoneRequest());
    // A negative zone asks to ignore other reservations, and passes through
    // whatever the anchors are.
    surface.machine.setExclusiveZone(-1);
    try std.testing.expectEqual(@as(i32, -1), surface.exclusiveZoneRequest());
    surface.deinit();
}

/// A stand-in protocol table that counts what reached the wire.
///
/// The gate under test is "may this surface still be talked to", and a count
/// is the only honest evidence for it: an error return proves the caller was
/// told, not that the compositor was spared. The table never creates an
/// object, which is what a live surface's setters see — none of them needs one.
const FakeWire = struct {
    /// The table in use, or null outside a test that installed one. The
    /// entry points libwayland hands out are bare `extern` pointers with no
    /// user data, so the only place they can find their counter is storage of
    /// their own.
    var current: ?*FakeWire = null;
    marshals: u32 = 0,
    destructors: u32 = 0,
    flushes: u32 = 0,
    /// The bound version every proxy reports, high enough for the requests
    /// that are gated on a since-version.
    version: u32 = 4,

    const api: wayland.Api = .{
        .proxy_marshal_flags = marshal,
        .proxy_destroy = destroy,
        .proxy_add_listener = addListener,
        .proxy_set_user_data = setUserData,
        .proxy_get_version = getVersion,
        .display_roundtrip = roundtrip,
        .display_flush = flush,
        .display_dispatch_pending = dispatchPending,
        .display_create_queue = createQueue,
        .proxy_set_queue = setQueue,
        .display_roundtrip_queue = roundtripQueue,
        .display_dispatch_queue_pending = dispatchQueuePending,
        .display_get_error = getError,
        .event_queue_destroy = destroyQueue,
        .proxy_create_wrapper = createWrapper,
        .proxy_wrapper_destroy = destroyWrapper,
    };

    fn install(self: *FakeWire) void {
        std.debug.assert(current == null);
        current = self;
    }

    fn marshal(
        proxy: *wayland.Proxy,
        opcode: u32,
        interface: ?*const wayland.Interface,
        version: u32,
        flags: u32,
        ...,
    ) callconv(.c) ?*wayland.Proxy {
        _ = .{ proxy, opcode, interface, version };
        const wire = current orelse return null;
        wire.marshals += 1;
        if (flags & wayland.marshal_destroy != 0) wire.destructors += 1;
        return null;
    }

    fn destroy(proxy: *wayland.Proxy) callconv(.c) void {
        _ = proxy;
        if (current) |wire| wire.destructors += 1;
    }

    fn addListener(
        proxy: *wayland.Proxy,
        implementation: [*]const ?*const anyopaque,
        data: ?*anyopaque,
    ) callconv(.c) c_int {
        _ = .{ proxy, implementation, data };
        return 0;
    }

    fn setUserData(proxy: *wayland.Proxy, data: ?*anyopaque) callconv(.c) void {
        _ = .{ proxy, data };
    }

    fn getVersion(proxy: *wayland.Proxy) callconv(.c) u32 {
        _ = proxy;
        return if (current) |wire| wire.version else 0;
    }

    fn roundtrip(display: *wayland.Display) callconv(.c) c_int {
        _ = display;
        return 0;
    }

    fn flush(display: *wayland.Display) callconv(.c) c_int {
        _ = display;
        if (current) |wire| wire.flushes += 1;
        return 0;
    }

    fn dispatchPending(display: *wayland.Display) callconv(.c) c_int {
        _ = display;
        return 0;
    }

    // The private-queue entry points are required on the real table, and a
    // layer surface never reaches for one: it sends every request on the
    // queue it was given. These answers only have to exist and refuse nothing
    // the tests above rely on.
    fn createQueue(display: *wayland.Display) callconv(.c) ?*wayland.EventQueue {
        _ = display;
        return @ptrFromInt(0x4000);
    }

    fn setQueue(proxy: *wayland.Proxy, queue: *wayland.EventQueue) callconv(.c) void {
        _ = .{ proxy, queue };
    }

    fn roundtripQueue(display: *wayland.Display, queue: *wayland.EventQueue) callconv(.c) c_int {
        _ = .{ display, queue };
        return 0;
    }

    fn dispatchQueuePending(display: *wayland.Display, queue: *wayland.EventQueue) callconv(.c) c_int {
        _ = .{ display, queue };
        return 0;
    }

    fn getError(display: *wayland.Display) callconv(.c) c_int {
        _ = display;
        return 0;
    }

    fn destroyQueue(queue: *wayland.EventQueue) callconv(.c) void {
        _ = queue;
    }

    fn createWrapper(proxy: *anyopaque) callconv(.c) ?*wayland.Proxy {
        _ = proxy;
        return null;
    }

    fn destroyWrapper(wrapper: *wayland.Proxy) callconv(.c) void {
        _ = wrapper;
    }
};

/// Put a `LayerSurface` into the state `attach` leaves behind: the connection,
/// the proxies and the listener that reaches the machine. The pointers are
/// never dereferenced by the counting table, so their values only have to be
/// distinct and stable.
///
/// The value is filled in place rather than returned because the listener
/// holds the address of the machine: a returned copy would leave that address
/// pointing at the frame that built it.
fn armLive(surface: *LayerSurface) !void {
    surface.* = try LayerSurface.init(.{
        .anchor = .top_dock,
        .exclusive_zone = 64,
        .margins = .{ .top = 12, .right = 24, .bottom = 0, .left = 24 },
    });
    surface.api = FakeWire.api;
    surface.display = @ptrFromInt(0x1000);
    surface.surface = @ptrFromInt(0x2000);
    surface.layer_surface = @ptrFromInt(0x3000);
    surface.role.machine = &surface.machine;
}

test "api-w22 a compositor close releases the role listener and spares the wire" {
    var wire: FakeWire = .{};
    wire.install();
    defer FakeWire.current = null;

    var surface: LayerSurface = undefined;
    try armLive(&surface);
    try surface.machine.handleConfigure(21, 1872, 64);
    try surface.ackConfigure(21);
    try surface.commit();
    const mapped_marshals = wire.marshals;
    const mapped_flushes = wire.flushes;
    try std.testing.expect(mapped_marshals > 0);

    // A compositor `closed` is the one event no live compositor in this
    // tree's record has delivered, so the listener is driven directly.
    onClosed(&surface.role, @ptrFromInt(0x3000));
    try std.testing.expect(surface.role.machine == null);
    try std.testing.expect(surface.machine.teardown_performed);
    try std.testing.expectEqual(state.SurfaceState.destroyed, surface.machine.state);

    // Every request path refuses, and not one of them reaches the wire.
    try std.testing.expectError(error.AlreadyDestroyed, surface.setAnchor(.bottom_dock));
    try std.testing.expectError(error.AlreadyDestroyed, surface.setMargins(.{ .top = 1 }));
    try std.testing.expectError(error.AlreadyDestroyed, surface.setExclusiveZone(0));
    try std.testing.expectError(
        error.AlreadyDestroyed,
        surface.setKeyboardInteractivity(.exclusive),
    );
    try std.testing.expectError(error.AlreadyDestroyed, surface.setDesiredSize(200, 40));
    try std.testing.expectError(error.AlreadyDestroyed, surface.setInputRegion(.{}));
    try std.testing.expectError(error.AlreadyDestroyed, surface.applyOptions());
    try std.testing.expectError(error.AlreadyDestroyed, surface.ackConfigure(21));
    try std.testing.expectError(error.AlreadyDestroyed, surface.commit());
    try std.testing.expectError(error.DoubleTeardown, surface.close());
    try std.testing.expectEqual(mapped_marshals, wire.marshals);
    try std.testing.expectEqual(mapped_flushes, wire.flushes);

    // A refused update recorded nothing, so the options still describe what
    // the wire carries.
    try std.testing.expectEqual(@as(i32, 64), surface.machine.options.exclusive_zone);
    try std.testing.expectEqual(state.Anchor.top_dock, surface.machine.options.anchor);
    try std.testing.expectEqual(
        Margins{ .top = 12, .right = 24, .bottom = 0, .left = 24 },
        surface.machine.options.margins,
    );
    try std.testing.expectEqual(@as(u32, 0), surface.machine.options.desired_width);
    try std.testing.expectEqual(@as(u32, 0), surface.machine.options.desired_height);

    // A configure the compositor had already queued finds the released
    // listener, so it cannot re-open the role, and a second `closed` is the
    // same null store again, so the teardown is still claimed once.
    const configured = surface.machine.configured_count;
    onConfigure(&surface.role, @ptrFromInt(0x3000), 22, 640, 48);
    onClosed(&surface.role, @ptrFromInt(0x3000));
    try std.testing.expectEqual(configured, surface.machine.configured_count);
    try std.testing.expectEqual(mapped_marshals, wire.marshals);

    // The role is still the compositor's until the destructor is sent.
    try std.testing.expect(surface.isAttached());
    surface.deinit();
    try std.testing.expectEqual(@as(u32, 1), wire.destructors);
    try std.testing.expectEqual(mapped_flushes + 1, wire.flushes);
}

test "api-w22 a removed output refuses every request and releases both listeners" {
    var wire: FakeWire = .{};
    wire.install();
    defer FakeWire.current = null;

    var surface: LayerSurface = undefined;
    try armLive(&surface);
    surface.output_state = .{ .machine = &surface.machine };
    surface.scan = .{
        .machine = &surface.machine,
        .output_state = &surface.output_state,
        .role = &surface.role,
        .output_name = 11,
        .selected_output_name = 11,
    };
    try surface.machine.handleConfigure(31, 1872, 64);
    try surface.ackConfigure(31);
    try surface.commit();
    const mapped_marshals = wire.marshals;

    onGlobalRemove(&surface.scan, @ptrFromInt(0x1000), 11);
    try std.testing.expect(surface.outputDisconnected());
    try std.testing.expect(!surface.machine.output_attached);
    // Both listeners outlive the surface they feed, so both are detached in
    // the same step and a `done` batch and a `configure` each find nothing to
    // write into.
    try std.testing.expect(surface.output_state.machine == null);
    try std.testing.expect(surface.role.machine == null);

    try std.testing.expectError(error.AlreadyDestroyed, surface.setMargins(.{ .top = 2 }));
    try std.testing.expectError(error.AlreadyDestroyed, surface.setExclusiveZone(0));
    try std.testing.expectError(error.AlreadyDestroyed, surface.setDesiredSize(10, 10));
    try std.testing.expectError(error.AlreadyDestroyed, surface.commit());
    try std.testing.expectError(error.DoubleTeardown, surface.close());
    try std.testing.expectEqual(mapped_marshals, wire.marshals);
    try std.testing.expectEqual(@as(i32, 64), surface.machine.options.exclusive_zone);

    // A repeated removal repeats the same null stores, so the teardown is
    // still claimed once and a late `done` still changes nothing.
    const settled = surface.machine.state;
    onGlobalRemove(&surface.scan, @ptrFromInt(0x1000), 11);
    onOutputDone(&surface.output_state, @ptrFromInt(0x2000));
    onConfigure(&surface.role, @ptrFromInt(0x3000), 32, 640, 48);
    try std.testing.expectEqual(settled, surface.machine.state);
    try std.testing.expectEqual(mapped_marshals, wire.marshals);

    surface.deinit();
    try std.testing.expectEqual(@as(u32, 1), wire.destructors);
}

test "api-w22 a live option update marshals its own request and records it" {
    var wire: FakeWire = .{};
    wire.install();
    defer FakeWire.current = null;

    var surface: LayerSurface = undefined;
    try armLive(&surface);
    try surface.machine.handleConfigure(41, 1872, 64);
    try surface.ackConfigure(41);
    try surface.commit();
    const before = wire.marshals;

    try surface.setDesiredSize(960, 48);
    try std.testing.expectEqual(before + 1, wire.marshals);
    try std.testing.expectEqual(@as(u32, 960), surface.machine.options.desired_width);
    try std.testing.expectEqual(@as(u32, 48), surface.machine.options.desired_height);

    // An anchor set that cannot express a positive reservation sends the zone
    // the anchors allow, so the request and `reservedZone` cannot disagree.
    try surface.setAnchor(Anchor.all);
    try surface.setExclusiveZone(64);
    try std.testing.expectEqual(before + 3, wire.marshals);
    try std.testing.expectEqual(@as(i32, 0), surface.machine.reservedZone());
    try std.testing.expectEqual(@as(i32, 0), surface.exclusiveZoneRequest());

    surface.deinit();
    try std.testing.expectEqual(@as(u32, 1), wire.destructors);
}

test "api-w22 a failed attach leaves the value readable and unbound" {
    var wire: FakeWire = .{};
    wire.install();
    defer FakeWire.current = null;

    // A real-looking Wayland handle pair with nothing behind it: the registry
    // round trip that resolves a global finds no object, so the attach is
    // refused before a single binding is made.
    var surface = try LayerSurface.init(.{ .desired_height = 32 });
    try std.testing.expectError(error.LayerShellUnsupported, surface.attach(FakeWire.api, .{
        .display = @ptrFromInt(0x1000),
        .surface = @ptrFromInt(0x2000),
        .driver_name = "wayland",
        .roleless = true,
    }, .{}));
    try std.testing.expectEqual(@as(u32, 0), wire.destructors);
    // The value is readable and unbound rather than poisoned, so the caller
    // can read why it failed and release it in the ordinary way. A value that
    // `deinit` had consumed on the way out could not be asked anything.
    try std.testing.expect(!surface.isAttached());
    try std.testing.expect(!surface.machine.teardown_performed);
    try std.testing.expectError(error.AlreadyDestroyed, surface.commit());
    surface.deinit();
    try std.testing.expectEqual(@as(u32, 0), wire.destructors);
}
