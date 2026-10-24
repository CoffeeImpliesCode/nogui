//! W22 Wayland layer-shell smoke — one real zwlr_layer_shell_v1 surface on the
//! compositor this process is actually connected to, plus the reserved extent
//! measured from outside the layer protocol.
//!
//! `w22_linux_surfaces_test.zig` drives the layer-shell state machine against a
//! fake seat. This binary drives the real protocol through the public
//! `nogui_host.linux.layer_shell_real` API: probe the advertised global, create
//! the layer surface, take the configure the compositor delivers, acknowledge
//! that serial, put a real buffer up on the device this run opened, update the
//! options on the live surface, and close. An ordinary SDL toplevel is opened in
//! the same process while that layer surface is up, so a broken layer attempt
//! can never hide behind a broken ordinary path.
//!
//! The close is two steps, because the protocol has two. The client first
//! claims its single teardown and refuses every later request while the role
//! is still the compositor's; only then does the wire retirement send
//! `zwlr_layer_surface_v1.destroy` and drop the output, shell and compositor
//! bindings. `attached` reads true after the first step and false after the
//! second, and it is never turned ahead of the request that earns it. The
//! content that presents into the layer surface is released before the role is
//! retired, and the SDL window carrying the `wl_surface` is destroyed after
//! it, so no swapchain outlives the surface it presents into.
//!
//! Both surfaces in this run are drawn by `noapi` on ONE device this run opens
//! itself, through `noapi.Surface.initSdl` on the window SDL already made: the
//! layer bar on the roleless window `createRolelessWindow` made, the probe on
//! an ordinary toplevel opened with `gpu_surface`. This process never holds a
//! Vulkan instance, surface or swapchain handle of its own.
//!
//! Alongside that, `main` sets `SDL_FRAMEBUFFER_ACCELERATION` to `"0"` before
//! SDL video starts. That hint does not name this run's renderer — there is
//! none — it decides what SDL builds UNDER a renderer of its own. Left alone,
//! `SW_CreateRenderer` takes the window's framebuffer as a 3D-accelerated
//! texture on a renderer SDL creates behind its own back; on Wayland, where
//! SDL's video backend registers no framebuffer of its own, that hidden
//! renderer was the only thing that could have drawn anything. Destroying the
//! software renderer tore it down through `SW_DestroyRenderer` ->
//! `SDL_DestroyWindowSurface` -> `SDL_DestroyWindowTexture` ->
//! `SDL_DestroyRenderer_REAL` -> `VULKAN_DestroyRenderer` ->
//! `VULKAN_DestroyAll`, where the driver called through a null entry point and
//! this process died at address 0 before one destructor could reach the wire.
//! With the hint at `"0"` there is no hidden renderer to inherit, and the only
//! drawing context in the process is the one this run owns.
//!
//! The reserved extent is the acceptance point `zwlr_layer_shell_v1` cannot
//! report about itself, so the run answers it from a source that is not this
//! process's own request. A compositor reserves a top dock's exclusive zone out
//! of the area it hands to managed windows, so an ordinary toplevel, mapped and
//! configured on the same display, reports the reservation in the height the
//! compositor configured for it. The run measures that height
//! before and after the live zone update and compares the two: the delta must
//! be the zone delta in logical pixels, with the device scale accounted for.
//!
//! Nothing in that comparison is a client-side fact. `reservedZone()`,
//! `exclusiveZoneRequest()`, the requested zone and the configure the
//! compositor sent are printed as what this process asked for and what it was
//! told, and they are never counted as the reserved extent.
//!
//! What this run still cannot observe, reported as such instead of inferred:
//!
//!   - The reserved extent on a compositor that does not reserve one from the
//!     area it gives to managed windows. A compositor that floats every window
//!     never changes the probe's height, and the run then reports the effect
//!     as NOT observed; `--verify-reservation` fails the run rather than
//!     reporting a pass from the zone it requested.
//!   - A compositor-delivered `zwlr_layer_surface_v1.closed`, and a removal of
//!     the output the role sits on, in a run that does not provoke one. A
//!     healthy compositor sends neither for a healthy surface, so the default
//!     run prints `compositor_closed=false` and drives the close path
//!     client-side. `--terminal-expect closed|output-removed` with
//!     `--terminal-arm-ms N` opens a last bounded window in which this process
//!     only pumps, so something outside it can end the live role while it is
//!     still mapped; the run then reports which ending it saw, requires the one
//!     it was asked for, and fails when the other one is all that arrived. The
//!     run cannot tell a `closed` EVENT from the output's removal — both finish
//!     its state machine — so it reports each of them separately and leaves the
//!     distinction to a reader of the protocol log.
//!   - A grab. This protocol reserves no input exclusively, the run asks for
//!     `keyboard_interactivity=none`, and nothing here claims one.
//!
//!   - A device, on a machine with no GPU and no `--native`. The default run
//!     takes the windowless driver, opens no window, reaches no compositor and
//!     asks for no surface, so it needs no device. `--native` opens one and a
//!     device that will not open ends the run with that error rather than
//!     quietly turning the run into one that draws nothing.
//!
//!   - A compositor's own account of an input region. No Wayland request reads
//!     one back, so the run can only report what it put on the wire and what the
//!     pointer did afterwards. Aiming a pointer at this surface is something
//!     outside this process has to do, and a run that never saw one reports
//!     `delivered=0` instead of a pass.
//!
//! `--output-watch-ms` opens a bounded watch on the real `wl_output` the layer
//! surface is placed on: the run prints `OUTPUT-WATCH-READY`, records every
//! `done` batch, scale and mode the compositor sends while the window is open,
//! and answers each applied mode change with the configure/ack/new-buffer cycle
//! the changed size requires. This process never touches a compositor: an
//! operator changes the output while the watch is open, and the run only reads
//! what comes back.
//!
//! Two further arms are opt-in, because both need a named point at which the
//! compositor can be read while this run holds one particular state.
//!
//! `--input-region-ms N` drives three live input regions on that same layer
//! surface, in the order the protocol makes them distinguishable from one
//! another: an empty region, whose surface is transparent to the pointer; one
//! rectangle in the middle of the panel, so "some of it accepts input" can be
//! told from "all of it" and from "none of it"; and the compositor's infinite
//! default, restored by the explicit null request that a region already on the
//! wire never replaces on its own. Each step commits before it prints
//! `INPUT-REGION-STEP-READY`, and every observation window counts only the
//! pointer events the compositor delivered to this layer's own surface.
//!
//! `--keyboard-arm-ms N` drives keyboard interactivity `none`, `on-demand`,
//! `none` on that same surface and prints `KEYBOARD-STEP-READY` after each
//! request has been committed. `set_keyboard_interactivity` is double-buffered
//! state the compositor applies at the next `wl_surface.commit`, so a step
//! that did not commit would report a request the compositor never acted on;
//! `committed_count` and `carried` are this process's own witness that it did.
//! `on_demand` arrived in layer-shell version 4 and is refused by name below it.
//! No exclusive keyboard capture is taken and no seat serial is invented: a
//! grab is not this run's to take.
//!
//! Both arms print the wire id of this layer surface's own `wl_surface`, which
//! is what lets a `WAYLAND_DEBUG` log be read against THIS layer rather than
//! against the ordinary toplevel open beside it.
//!
//! The run changes no compositor setting, opens no configuration tool and
//! touches no external session state: every line it prints comes from this
//! process and from libwayland.
//!
//! Run it: `zig build w22-layer-shell-smoke -- --native [--hold-ms 9000]
//! [--verify-reservation] [--output-watch-ms 8000] [--verify-output]
//! [--input-region-ms 6000] [--keyboard-arm-ms 4000]`.
//!
//! For the terminal ending, add `--terminal-expect closed` or
//! `--terminal-expect output-removed` together with `--terminal-arm-ms N`. That
//! run is driven from outside: it prints `TERMINAL-ARM-READY` and then watches
//! for the ending until the bound, and the driver makes the compositor change
//! after that line. This process never makes it.
//!
//! Without `--native` the host is told to take the windowless driver, so a run
//! on a machine with a desktop session opens no window and reaches no
//! compositor.
const std = @import("std");
const Io = std.Io;
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const nogui = @import("nogui");
const host = @import("nogui_host");

const real = host.linux.layer_shell_real;
const machine_state = host.linux.layer_shell;
const contract = nogui.window_contract;

const wayland = host.linux.wayland;
const Color = sdl3.pixels.Color;

// The host exports the Wayland protocol table, so every type below is named
// directly. Recovering them by reflecting on the adapter's own signatures
// would tie this smoke to a private implementation detail and break whenever a
// parameter or return type changed.
const WaylandApi = wayland.Api;
const WaylandLoader = wayland.Loader;
const WaylandObject = wayland.Object;

/// The opaque `wl_display` SDL handed out, in the shape the table wants it.
const DisplayPtr = *wayland.Display;

/// `wl_proxy` in the shape the one entry point this run resolves itself takes
/// it.
const ProxyPtr = *wayland.Proxy;

/// One wire id as the report spells it: `@17`, or `unavailable` when the client
/// library does not expose `wl_proxy_get_id`.
///
/// The storage lives in the value rather than in a temporary, because a
/// formatted id is handed to a report that reads it after this function has
/// returned. A missing id reads as a word, so no reader has to tell it apart
/// from a zero one.
const WireText = struct {
    text: [16]u8 = "unavailable".* ++ @as([5]u8, @splat(0)),
    len: usize = "unavailable".len,

    fn of(id: ?u32) WireText {
        var out: WireText = .{};
        const value = id orelse return out;
        const written = std.fmt.bufPrint(&out.text, "@{d}", .{value}) catch return out;
        out.len = written.len;
        return out;
    }

    fn slice(self: *const WireText) []const u8 {
        return self.text[0..self.len];
    }
};

/// Values that belong to this scenario alone: a top-dock panel with its own
/// asymmetric margins and a 64 logical-pixel exclusive zone, so the compositor's
/// answer cannot be confused with the unit-test fixtures.
///
/// The top margin is zero on purpose. A top dock whose panel starts at the
/// output's own top edge puts the boundary the exclusive zone makes at exactly
/// the panel's bottom row, so a screenshot can be read against the configured
/// height without first resolving where the panel sits. The left and right
/// insets stay: they are what makes this panel distinguishable from a
/// full-width one, and a reservation is a vertical measurement.
const layer_options: real.Options = .{
    .layer = .top,
    .anchor = .top_dock,
    .margins = .{ .top = 0, .right = 24, .bottom = 0, .left = 24 },
    .exclusive_zone = baseline_zone,
    .keyboard_interactivity = .none,
    .namespace = "w22-layer-smoke",
    // The width is left to the anchored edges so the compositor answers with
    // the width it will actually use; that answer is what the run reports.
    .desired_width = 0,
    .desired_height = @intCast(baseline_zone),
};

/// Window title prefix for this scenario, unique on a shared display.
const toplevel_title = "w22-layer-smoke-toplevel";

/// The two reserved zones the run asks for, in logical pixels. A run that
/// never changes the zone cannot observe an effect at all, and the change has
/// to be large enough that a compositor which reserves the smaller of the zone
/// and the panel is still distinguishable from one that reserves neither.
const baseline_zone: i32 = 64;
const updated_zone: i32 = 128;

/// The probe window's content, in sRGB, so a screenshot names the exact pixels
/// the run measured. The body is a colour no other surface in this run uses,
/// and the two bands are this window's top and bottom device-pixel rows: the
/// top band is the edge a top dock's reservation moves.
const probe_body: Color = .{ .r = 0x0E, .g = 0x7A, .b = 0x3C, .a = 0xFF };
const probe_top_band: Color = .{ .r = 0xFF, .g = 0xD0, .b = 0x20, .a = 0xFF };
const probe_bottom_band: Color = .{ .r = 0xFF, .g = 0x2D, .b = 0x55, .a = 0xFF };

/// The layer bar's content, in sRGB, on the same terms as the probe's: the body
/// is a colour no other surface in this run uses, the gold rectangle is the
/// eighth-and-a-half marker inset from the top-left, and the black band is the
/// bar's bottom device-pixel rows — the edge a top dock's reservation ends at.
const bar_body: Color = .{ .r = 0x1E, .g = 0x40, .b = 0xD8, .a = 0xFF };
const bar_marker: Color = .{ .r = 0xFF, .g = 0xD0, .b = 0x20, .a = 0xFF };
const bar_edge: Color = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xFF };

/// How long a settle loop waits for the probe window to stop moving, how many
/// samples it takes at most, and how many identical samples in a row count as
/// settled. The bound is what keeps an unsettled window an honest observation
/// instead of a wait: the samples that were taken are printed with it.
const settle_bound_ms: u64 = 6000;
const settle_max_samples: u32 = 600;
const settle_min_samples: u32 = 6;
const settle_stable_samples: u32 = 4;

/// How long the run waits for the configure a changed output mode owes the
/// surface, and how many output events it prints before it only counts them.
const reconfigure_bound_ms: u64 = 4000;
const watch_print_limit: u32 = 16;

/// How long one arm waits for a configure its own request may have provoked,
/// and how long one bounded observation window watches for pointer events on
/// the layer's own surface before it is reported. The cadence is short enough
/// that a reader can bracket its own request between two samples, and the
/// printed count is bounded so a long window stays readable.
const arm_settle_ms: u64 = 250;
const pointer_sample_ms: u64 = 250;
const pointer_sample_limit: u32 = 64;

/// The pump period for every loop in this run. Long enough to leave the
/// compositor room, short enough that a bounded wait ends on time.
const poll_ms: u64 = 8;

/// The compositor-initiated end of a live role that this run is asked to
/// witness.
///
/// A healthy compositor sends no `zwlr_layer_surface_v1.closed` for a healthy
/// surface and removes no output under it, so the healthy run names neither and
/// claims neither. The other two are the two real ways a compositor ends a role
/// that is still mapped. Which of them arrived is a question about the wire and
/// not about this process: both leave the state machine finished, both arrive on
/// the connection this process owns, and the adapter records one teardown for
/// both, so the run reports each of them separately and never reports one as
/// the other.
const TerminalEvent = enum {
    none,
    closed,
    output_removed,

    /// The spelling this event is asked for and reported under, so a reader can
    /// compare the two without knowing the enum's own tag names.
    fn text(self: TerminalEvent) []const u8 {
        return switch (self) {
            .none => "none",
            .closed => "closed",
            .output_removed => "output-removed",
        };
    }

    fn parse(value: []const u8) ?TerminalEvent {
        if (std.mem.eql(u8, value, "closed")) return .closed;
        if (std.mem.eql(u8, value, "output-removed")) return .output_removed;
        return null;
    }
};

/// How long the terminal arm keeps pumping after the role has ended, so the
/// second of the two endings is recorded too when a compositor sends both. The
/// order is not fixed by the wire format, and a report carrying only the first
/// thing observed would leave the other one unrecorded for good.
const terminal_grace_ms: u64 = 750;

/// What one run is asked to do. Every mode that opens a window, keeps a hold
/// open or claims a measurement is named here rather than inferred from an
/// argument that happened to be present.
const Options = struct {
    /// Keep the layer surface and the probe window up, for an external capture.
    hold_ms: u64 = 0,
    /// Drive the display server this run is actually connected to. Without it
    /// the host is told to take the windowless driver, so a default run opens
    /// no window and reaches no compositor.
    native: bool = false,
    /// Measure the reserved extent through the probe window and fail the run
    /// when the measured delta is not the requested zone delta. Off by default:
    /// a run that only reports the measurement must not fail on a compositor
    /// that reserves nothing.
    verify_reservation: bool = false,
    /// How long to watch the real output the layer surface is on, zero for no
    /// watch at all.
    output_watch_ms: u64 = 0,
    /// Fail the run when that watch saw no output event, or when an applied
    /// mode change was not answered by a configure, an acknowledgement and a
    /// new buffer.
    verify_output: bool = false,
    /// Per-step observation window for the live input-region arm, zero to skip
    /// the arm. Three regions in protocol order: an empty click-through, one
    /// bounded rectangle, and the explicit null that restores the compositor's
    /// infinite default.
    input_region_ms: u64 = 0,
    /// Per-step observation window for the live keyboard-interactivity arm,
    /// zero to skip the arm. `none`, then `on-demand`, then `none` again.
    keyboard_arm_ms: u64 = 0,
    /// Which compositor-initiated end of this role the run is asked to witness,
    /// or `none` for the healthy run, which expects neither and claims
    /// neither.
    terminal_expect: TerminalEvent = .none,
    /// How long the terminal arm waits for that end, zero to skip the arm. The
    /// arm is bounded, it pumps and does nothing else, and it ends early only
    /// when the role really is finished.
    terminal_arm_ms: u64 = 0,
};

/// A verification this run was asked for and could not satisfy.
///
/// The first failure is kept and the rest of the run still happens: the
/// surfaces are closed, the machine is torn down and every observation is
/// printed, and only then does the process fail. An exit code and an evidence
/// log that describe the same run are worth more than an early exit that hides
/// the close path behind the failure.
const Verdict = struct {
    failure: ?anyerror = null,

    /// Record a failure unless one is already recorded. A run that cannot
    /// measure one thing may still be able to say why it cannot measure the
    /// next, and the first failure is the one that names the run.
    fn require(self: *Verdict, satisfied: bool, failure: anyerror) void {
        if (satisfied) return;
        if (self.failure == null) self.failure = failure;
    }
};

/// An error union reports its error; a delivered success reports as itself.
fn outcomeText(comptime T: type, result: anyerror!T) []const u8 {
    if (result) |_| return "<accepted>" else |err| return @errorName(err);
}

/// `std.DynLib` behind the adapter's loader contract. The smoke resolves
/// libwayland-client the way the tree resolves its other optional native
/// libraries, and the loader hands back the copy SDL already mapped.
const DynLoader = struct {
    lib: ?std.DynLib = null,
    soname: [:0]const u8 = "<none>",

    const object_vtable: WaylandObject.VTable = .{ .loadFunction = loadFunction, .unload = unload };
    const loader_vtable: WaylandLoader.VTable = .{ .loadObject = loadObject };

    fn loader(self: *DynLoader) WaylandLoader {
        return .{ .context = @ptrCast(self), .vtable = &loader_vtable };
    }

    // The error union is written out rather than aliased: the rule that checks
    // `try` cannot see through a type alias and would call a `try` here
    // homeless.
    fn loadObject(context: *anyopaque, soname: [:0]const u8) anyerror!wayland.Object {
        const self: *DynLoader = @ptrCast(@alignCast(context));
        self.lib = try std.DynLib.open(soname);
        self.soname = soname;
        return .{ .context = context, .vtable = &object_vtable };
    }

    fn loadFunction(context: *anyopaque, name: [:0]const u8) anyerror!*const anyopaque {
        const self: *DynLoader = @ptrCast(@alignCast(context));
        const lib = if (self.lib) |*loaded| loaded else return error.WaylandClientIncomplete;
        return lib.lookup(*const anyopaque, name) orelse error.WaylandClientIncomplete;
    }

    /// The wire identity of one proxy, when libwayland exposes it.
    ///
    /// A `WAYLAND_DEBUG` log names every object by the id the client library
    /// gave it, so a run that prints its own ids can be read against that log
    /// without guessing which of two surfaces on one connection a request went
    /// to. A library without the entry point answers null, and the run then
    /// reports the id as unavailable rather than inventing one.
    fn wireId(self: *DynLoader, proxy: ?*anyopaque) ?u32 {
        const entry = loadFunction(@ptrCast(self), "wl_proxy_get_id") catch return null;
        const get_id: *const fn (ProxyPtr) callconv(.c) u32 = @ptrCast(@alignCast(entry));
        return get_id(@ptrCast(proxy orelse return null));
    }

    fn unload(context: *anyopaque) void {
        const self: *DynLoader = @ptrCast(@alignCast(context));
        if (self.lib) |*lib| lib.close();
        self.lib = null;
    }
};

/// What one registry round trip on the live connection reports. The adapter
/// runs the same round trip inside its own probe; this scan only publishes the
/// advertisement itself, so the probe's verdict can be read against it.
const RegistryScan = struct {
    globals: u32 = 0,
    layer_shell_name: u32 = 0,
    layer_shell_version: u32 = 0,
    output_count: u32 = 0,
    compositor_version: u32 = 0,
};

/// C layout of `wl_registry_listener`. Only the raw slot array crosses into
/// libwayland, exactly as the adapter passes its own listener.
const RegistryListener = extern struct {
    global: *const fn (?*anyopaque, *anyopaque, u32, [*:0]const u8, u32) callconv(.c) void,
    global_remove: *const fn (?*anyopaque, *anyopaque, u32) callconv(.c) void,
};

fn onGlobal(
    data: ?*anyopaque,
    _: *anyopaque,
    name: u32,
    interface: [*:0]const u8,
    version: u32,
) callconv(.c) void {
    const scan: *RegistryScan = @ptrCast(@alignCast(data orelse return));
    scan.globals += 1;
    const text = std.mem.span(interface);
    if (std.mem.eql(u8, text, "zwlr_layer_shell_v1")) {
        scan.layer_shell_name = name;
        scan.layer_shell_version = version;
    } else if (std.mem.eql(u8, text, "wl_output")) {
        scan.output_count += 1;
    } else if (std.mem.eql(u8, text, "wl_compositor")) {
        scan.compositor_version = version;
    }
}

fn onGlobalRemove(_: ?*anyopaque, _: *anyopaque, _: u32) callconv(.c) void {}

/// Read the live advertisement without touching any surface role.
fn scanGlobals(api: WaylandApi, display: DisplayPtr) !RegistryScan {
    const registry = api.displayGetRegistry(display) orelse return error.NoRegistry;
    defer api.proxy_destroy(@ptrCast(registry));
    var scan: RegistryScan = .{};
    const listener: RegistryListener = .{ .global = onGlobal, .global_remove = onGlobalRemove };
    if (api.proxy_add_listener(
        @ptrCast(registry),
        @ptrCast(&listener),
        &scan,
    ) != 0) return error.ListenerRejected;
    if (api.display_roundtrip(display) < 0) return error.RoundtripFailed;
    return scan;
}

const Reporter = struct {
    io: Io,
    buffer: [4096]u8 = @splat(0),

    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.buffer, fmt, args);
        try Io.File.stdout().writeStreamingAll(self.io, text);
    }
};

/// The other half of the gate: on a compositor without the global the adapter
/// must refuse explicitly, not fail obscurely and never fake a role.
fn reportUnavailable(
    report: *Reporter,
    api: WaylandApi,
    handles: real.Handles,
) !void {
    const state = machine_state.LayerSurface.init(layer_options, .unavailable);
    try report.emit("state machine on an unavailable compositor: {s}\n", .{
        outcomeText(machine_state.LayerSurface, state),
    });
    if (state) |surface| {
        _ = surface;
        return error.UnavailableStateAccepted;
    } else |_| {}

    var refused = try real.LayerSurface.init(layer_options);
    // The refused value is released like every other one: an attach that got
    // as far as a binding hands it back through the failed attach, and this
    // run leaves no live state machine behind it even on the path that proves
    // the global is absent.
    defer refused.deinit();
    const attach = refused.attach(api, handles, layer_options);
    const attached = refused.isAttached();
    try report.emit("attach on an unavailable compositor: {s} attached={}\n", .{
        outcomeText(void, attach),
        attached,
    });
    if (attached) return error.UnavailableAttachSucceeded;
}

/// The instance extensions the device asked for. `noapi.Gpu.init` takes a
/// plain function, so the storage it reads has to outlive the call; the copy
/// is released as soon as init returns and this is emptied, so nothing is left
/// pointing at freed bytes.
var instance_extensions: [][*:0]const u8 = &.{};

fn currentInstanceExtensions() []const [*:0]const u8 {
    return instance_extensions;
}

/// Open the one device both windows in this run present through, on the loader
/// the session already has.
///
/// This is the same seam `w22_popup_smoke` opens its device on: noapi asks SDL
/// for the instance entry points and for the extensions SDL's own backend
/// needs, so the device and every surface made from it live on one loader. The
/// caller owns the result and must destroy it AFTER every surface and BEFORE
/// the host quits SDL — quitting SDL unloads the Vulkan loader, and a live
/// device would then dispatch through an unmapped page.
fn openDevice(gpa: std.mem.Allocator, io: Io, app_name: [:0]const u8) !noapi.Gpu {
    try sdl3.vulkan.loadLibrary(null);
    const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();
    instance_extensions = try gpa.dupe([*:0]const u8, try sdl3.vulkan.getInstanceExtensions());
    defer {
        gpa.free(instance_extensions);
        instance_extensions = &.{};
    }
    return noapi.Gpu.init(.{
        .frames_in_flight = 2,
        .app_name = app_name,
        .validation = false,
        .loader = .{
            .get_instance_proc_addr = @ptrCast(get_proc_addr),
            .get_instance_extensions = &currentInstanceExtensions,
        },
        .io = io,
        .allocator = gpa,
    });
}

/// One colour band on a surface, in device pixels from the top left.
///
/// Bands are drawn in order and the first one covers the whole image, so a
/// later band lands on top of it. They are plain rectangles rather than
/// geometry: each is one dynamic render pass whose render AREA is the
/// rectangle and whose clear colour is the band's, which is what puts these
/// pixels on a real swapchain image without a pipeline, a shader or a
/// per-frame allocation.
const Band = struct {
    offset: [2]u32,
    size: [2]u32,
    color: [4]f32,
};

/// Whether the image these clears land in is an `_srgb` attachment.
///
/// noapi's Vulkan backend creates every window swapchain as
/// `VK_FORMAT_B8G8R8A8_SRGB`: `VkBackend.swapchain_format` is a fixed field
/// defaulted to it, `Surface.initSdl` takes no format, and nothing in the tree
/// writes it. So the answer is known before the first frame and is not
/// something this run has to probe for at runtime.
const swapchain_is_srgb = true;

/// One normalised sRGB channel to linear light.
///
/// This is the transfer the tree already applies before anything works in
/// linear light — `src/v7/paint.zig`, `src/v7_frame/text_gpu.zig` and the two
/// demo copies carry the same one-liner — and it is repeated here as the same
/// expression rather than as a new piece of maths, because the conversion a
/// clear value needs is decided by the attachment and not by the caller.
fn srgbChannelToLinear(value: f32) f32 {
    return if (value <= 0.04045)
        value / 12.92
    else
        std.math.pow(f32, (value + 0.055) / 1.055, 2.4);
}

/// The clear value one authored colour takes in the attachment this run
/// presents into, computed ONCE at comptime.
///
/// A clear value is written to the attachment the way a shader write is, so
/// an `_srgb` attachment encodes it on the way in. Handing it gamma-encoded
/// sRGB therefore encodes twice, and the compositor is given a washed-out
/// version of every marker: `#1E40D8` arrives as a pastel blue and `#FFD020`
/// as a pale yellow, while black stays black and a channel already at 1.0
/// barely moves. A plain `_unorm` attachment stores what it is given, so there
/// the encoded form is the correct one.
///
/// The colour parameter is `comptime` and the branch is taken inside a
/// `comptime` block, so every band colour is a literal folded when this binary
/// is compiled: no transfer function runs while a frame is being recorded.
fn clearValue(comptime color: Color) [4]f32 {
    return comptime blk: {
        const red: f32 = @as(f32, @floatFromInt(color.r)) / 255.0;
        const green: f32 = @as(f32, @floatFromInt(color.g)) / 255.0;
        const blue: f32 = @as(f32, @floatFromInt(color.b)) / 255.0;
        break :blk .{
            if (swapchain_is_srgb) srgbChannelToLinear(red) else red,
            if (swapchain_is_srgb) srgbChannelToLinear(green) else green,
            if (swapchain_is_srgb) srgbChannelToLinear(blue) else blue,
            @as(f32, @floatFromInt(color.a)) / 255.0,
        };
    };
}

/// The device-side surface one window in this run presents through.
///
/// Ownership is the whole point. `noapi.Surface.initSdl` creates the platform
/// surface from the window SDL already made and hands back a surface that
/// already owns it, so this value holds no SDL wrapper, no `VkSurfaceKHR` and
/// no second release to get wrong: this process never holds a raw Vulkan
/// handle at all. What is left here is device-side state, and it has to be
/// released BEFORE the window is destroyed on every path, because the
/// platform surface references the native window.
const GpuContent = struct {
    surface: noapi.Surface,
    released: bool = false,
    /// The frame currently being recorded. `cmd` and `image` are only read
    /// while `recording` is true, and both are written by `beginFrame` before
    /// it is set, so neither is ever read uninitialised. The storage is handed
    /// over by `open` rather than defaulted, so a content value that never
    /// opened a surface cannot be mistaken for one that has.
    cmd: noapi.CommandBuffer,
    image: noapi.Extent2D = .{ .width = 0, .height = 0 },
    recording: bool = false,
    swapchain_recreated: bool = false,

    /// What one presented frame actually did. The image is the swapchain's,
    /// which the driver is free to clamp, so it is reported next to the size
    /// that was asked for instead of replacing it.
    const Presented = struct {
        image: noapi.Extent2D,
        swapchain_recreated: bool,
        present_out_of_date: bool,
    };

    /// Take the window over to the platform and get the surface back.
    ///
    /// The window must already carry `SDL_WINDOW_VULKAN`: `SDL_Vulkan_CreateSurface`
    /// refuses a window without it, and that flag is the reason this run does
    /// not ask SDL for a renderer at all — the layer window gets it from
    /// `createRolelessWindow` and the probe toplevel through `gpu_surface`.
    fn open(
        gpu: *noapi.Gpu,
        window: sdl3.video.Window,
        extent: noapi.Extent2D,
    ) !GpuContent {
        return .{
            .surface = try noapi.Surface.initSdl(
                gpu,
                @ptrCast(window.value),
                @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
                .{ .extent = extent },
            ),
            // SAFETY: `cmd` is only read while `recording` is true, and
            // `beginFrame` writes it before it sets that flag, so this storage
            // is never read before the first acquire has filled it.
            .cmd = undefined,
        };
    }

    /// Release the device-side surface. Idempotent, because the release has to
    /// happen on the way out as well as at the end of a successful run.
    fn release(self: *GpuContent) void {
        if (self.released) return;
        self.released = true;
        self.surface.deinit();
    }

    /// Tell the swapchain the size the compositor configured this time. It is
    /// applied by the next `beginFrame`, so the image that comes back is the
    /// resized one and not the one this call replaced.
    fn resize(self: *GpuContent, extent: noapi.Extent2D) void {
        if (self.released) return;
        self.surface.notifyResize(extent);
    }

    /// Acquire the next image and start recording, and hand back the image the
    /// driver gave out.
    ///
    /// Every band is sized against THAT image and never against a requested
    /// extent: the driver clamps the swapchain to the surface capabilities, so
    /// a band laid out against what was asked for could fall outside what was
    /// given. That is also why this is separate from the draw and the present:
    /// the geometry has to be built between the acquire and the recording.
    fn beginFrame(self: *GpuContent) !noapi.Extent2D {
        const schedule = try self.surface.beginFrame();
        const image = self.surface.surfaceSize();
        if (image.width == 0 or image.height == 0) return error.SwapchainImageEmpty;
        self.swapchain_recreated = schedule.swapchain_recreated;
        self.image = image;
        self.cmd = self.surface.commandsBegin();
        self.recording = true;
        return image;
    }

    /// Clear each band's rectangle on the image currently being recorded.
    ///
    /// One dynamic render pass per band, each clipped to the image, so the
    /// first band covers whatever the driver gave out and the later ones land
    /// on top of it. Nothing here allocates: the bands are the caller's own
    /// array and the clear value is a value.
    fn drawBands(self: *GpuContent, bands: []const Band) void {
        std.debug.assert(self.recording);
        const image = self.image;
        for (bands) |band| {
            const left = @min(band.offset[0], image.width);
            const top = @min(band.offset[1], image.height);
            const wide = @min(band.size[0], image.width - left);
            const tall = @min(band.size[1], image.height - top);
            if (wide == 0 or tall == 0) continue;
            self.cmd.beginRendering(.{
                .render_area_offset = .{ @intCast(left), @intCast(top) },
                .render_area_size = .{ wide, tall },
                .color_attachments = &.{.{
                    .texture = self.surface.currentImage(),
                    .load_op = .clear,
                    .store_op = .store,
                    .clear_color = band.color,
                }},
            });
            self.cmd.endRendering();
        }
    }

    /// Submit and present the frame that `beginFrame` and `drawBands` built.
    fn presentFrame(self: *GpuContent) !Presented {
        std.debug.assert(self.recording);
        self.recording = false;
        const result = try self.surface.endFrame(.{});
        return .{
            .image = self.image,
            .swapchain_recreated = self.swapchain_recreated,
            .present_out_of_date = result.present_out_of_date,
        };
    }

    /// Give the acquired image back without presenting it. Used from an error
    /// path between the acquire and the present, so a failed frame never
    /// leaves the swapchain waiting on a recording that was abandoned.
    fn abortFrame(self: *GpuContent) !void {
        if (!self.recording) return;
        self.recording = false;
        try self.surface.abortFrame();
    }
};

/// Everything one live layer surface owns, kept alive across the toplevel
/// control. The surface is heap allocated because the compositor listener
/// stores the address of the state machine and outlives the attach call.
const LayerRun = struct {
    gpa: std.mem.Allocator,
    layer: *real.LayerSurface,
    window: *sdl3.video.Window,
    /// The device-side surface the layer bar is presented through. It is
    /// mandatory: this run presents real pixels into the role it attached, so
    /// a surface it could not create is a run that failed, not a run that
    /// quietly stopped drawing. The device it lives on belongs to `main` and
    /// outlives every surface this value owns.
    content: GpuContent,
    display: DisplayPtr,

    /// The layer-shell version this registry round trip advertised. `on_demand`
    /// keyboard interactivity arrived in version 4, so the arms that need it
    /// report the version they were given rather than assuming one.
    shell_version: u32 = 0,
    /// The wire id of this layer surface's own `wl_surface`, when libwayland
    /// exposes `wl_proxy_get_id`. This is what a `WAYLAND_DEBUG` log can be
    /// correlated against, so an input-region request on this surface is never
    /// confused with one on the ordinary toplevel beside it.
    wire_surface: ?u32 = null,

    /// Retire everything this run owns, in the order those lifetimes nest.
    ///
    /// The GPU surface presents into the layer surface, so it goes first: a
    /// swapchain left alive across the destruction of the role it presents
    /// into is the one way this run can hand the driver a surface that has
    /// already been torn down. The role is retired on the wire next, through
    /// `retireNative`, and its destructor is the last request this run puts on
    /// the wire before SDL destroys the `wl_surface` that carries it. Every
    /// pointer stays readable until the last one has been used, and the value
    /// is poisoned after that rather than before.
    ///
    /// Every one of those four retirements runs exactly once on every path.
    /// `retireNative` is asked for its answer and is not unwound from: a
    /// retirement that stopped at its first error would leave the window, the
    /// role and this value alive, and the caller's own error path would then
    /// release the surface a second time over freed storage. The failure is
    /// therefore reported once everything this run owned is already gone.
    fn deinit(self: *LayerRun, report: *Reporter) !void {
        const gpa = self.gpa;
        const layer = self.layer;
        const window = self.window;
        // The only place the GPU surface is retired, and it is reached before
        // the first request that can take the `wl_surface` away. `retireNative`
        // is called from here and nowhere else. The one other path that sends
        // a role destructor — the failed construction in `driveLayerSurface` —
        // reaches its surface and its role in that same order through its own
        // registrations, so the swapchain cannot outlive its surface on any
        // path. The device is NOT released here: it belongs to `main` and both
        // windows present through it.
        self.content.release();
        const retired = retireNative(report, layer);
        window.deinit();
        gpa.destroy(window);
        // The role is already retired on the wire, so this consumes the value
        // without sending a second destructor: `releaseNative` finds no
        // connection left to answer it.
        layer.deinit();
        gpa.destroy(layer);
        // The poison is registered once all four retirements are behind the
        // call and before the one request that can still fail, so the value is
        // dead on that failure too: everything it named is already gone, and
        // the storage the caller frees next holds nothing this run still uses.
        defer self.* = undefined;
        try retired;
    }
};

/// Release a layer run and the storage holding it.
///
/// The run's own `deinit` poisons the value, so the allocator is captured
/// first: freeing the storage has to come after the pointers inside it have
/// been used, never after the value has been overwritten with `undefined`.
/// The storage is freed on the failing path too, because the value is poisoned
/// either way and a caller left holding a pointer to it has nothing to retire.
fn retireLayerRun(run: *LayerRun, report: *Reporter) !void {
    const gpa = run.gpa;
    const retired = run.deinit(report);
    gpa.destroy(run);
    try retired;
}

/// Drive the real layer-surface lifecycle on this connection. Returns the live
/// surface, still up and mapped at the baseline zone, or null when the
/// compositor does not advertise the global.
///
/// Everything after the first buffer lives in `main`, because the run's later
/// observations all need the ordinary toplevel up at the same time as this
/// surface: the hold, the reserved extent and the output watch each measure
/// what this surface did to the rest of the display.
fn driveLayerSurface(
    gpa: std.mem.Allocator,
    report: *Reporter,
    api: WaylandApi,
    dyn: *DynLoader,
    gpu: ?*noapi.Gpu,
) !?*LayerRun {
    const driver = sdl3.video.getCurrentDriverName() orelse return error.NoVideoDriver;
    try report.emit("video driver: {s}\n", .{driver});
    if (!std.mem.eql(u8, driver, "wayland")) {
        // A layer role is a Wayland protocol. On any other driver the adapter
        // must refuse in so many words, never relabel a toplevel as one.
        if (real.createRolelessWindow(512, 64)) |window| {
            var refused_window = window;
            refused_window.deinit();
            try report.emit("createRolelessWindow on a {s} driver: <accepted>\n", .{driver});
            return error.LayerRoleOnNonWaylandDriver;
        } else |err| {
            try report.emit("createRolelessWindow on a {s} driver: {s}\n", .{
                driver,
                @errorName(err),
            });
        }
        try reportUnavailable(report, api, .{ .driver_name = driver });
        return null;
    }
    // A roleless SDL window is the only surface that may take a layer role.
    const window = try gpa.create(sdl3.video.Window);
    errdefer gpa.destroy(window);
    window.* = try real.createRolelessWindow(512, 64);
    errdefer window.deinit();
    const handles = try real.readRolelessHandles(window.*);
    const display: DisplayPtr = @ptrCast(handles.display orelse return error.NoDisplay);
    try report.emit(
        "roleless window: is_wayland={} usable={} xdg_toplevel={any}\n",
        .{ handles.isWayland(), handles.usable(), handles.xdg_toplevel },
    );

    const scan = try scanGlobals(api, display);
    try report.emit(
        "registry round trip: globals={d} zwlr_layer_shell_v1_name={d}" ++
            " zwlr_layer_shell_v1_version={d} wl_output_count={d}" ++
            " wl_compositor_version={d}\n",
        .{
            scan.globals,
            scan.layer_shell_name,
            scan.layer_shell_version,
            scan.output_count,
            scan.compositor_version,
        },
    );

    const capability = real.probe(api, handles);
    try report.emit("adapter probe: capability={s}\n", .{@tagName(capability)});
    if (capability == .unavailable) {
        try reportUnavailable(report, api, handles);
        // Nothing takes ownership of this window on the way out of this
        // function, so it is released here rather than left to an `errdefer`
        // that a successful return never runs. Same order as the hand-over
        // below: the window goes, then the storage holding it.
        window.deinit();
        gpa.destroy(window);
        return null;
    }

    // The role value is created here and attached below, once the drawing
    // context exists: the value holds no native binding of its own, and the
    // attach is what asks the compositor for one.
    //
    // Its two registrations sit above the GPU surface's and the window's on
    // purpose. Errdefers unwind last in first out, so an error return from
    // here on retires the swapchain first, the role it presents into next and
    // the window last: the order `LayerRun.deinit` retires them in.
    // That covers every error return after the attach — the round trip, the
    // configure, the ack, the present, a report and the run's own allocation
    // — so none of them leaves the role bound to the display with its
    // exclusive zone reserved and three listeners pointing into storage that
    // is about to be freed. An `attach` that failed released its own proxies,
    // so `deinit` finds nothing bound and sends no destructor twice.
    const layer = try gpa.create(real.LayerSurface);
    errdefer gpa.destroy(layer);
    layer.* = try real.LayerSurface.init(layer_options);
    errdefer layer.deinit();

    // The GPU surface is created before the role is attached, because a layer
    // surface only maps once a buffer is committed on it — and because the
    // device it is made on belongs to `main` and is already live.
    //
    // It is MANDATORY, and that is the point of the cutover. SDL's Wayland
    // video backend registers no window framebuffer of its own: it sets
    // neither `CreateWindowFramebuffer` nor `UpdateWindowFramebuffer`, so the
    // only drawing context SDL could ever hand this window was the hidden
    // accelerated one whose teardown killed the process. With the CPU
    // framebuffer policy in `main` there is no such thing on this driver, and
    // noapi presents into the window's own `wl_surface` directly instead. A
    // surface that cannot be created is this run's original error, propagated
    // unchanged: it never becomes a run that draws nothing and calls the role
    // mapped.
    //
    // `createRolelessWindow` already asked for `SDL_WINDOW_VULKAN`, and that
    // flag is what `SDL_Vulkan_CreateSurface` needs; the surface below is the
    // only Vulkan surface in this run and noapi owns it from the first call.
    const created = try window.getSizeInPixels();
    const device = gpu orelse return error.NoGpuDevice;
    var content = try GpuContent.open(device, window.*, .{
        .width = @intCast(created[0]),
        .height = @intCast(created[1]),
    });
    // Registered in this scope, above the role's and the window's own, so an
    // error return from here on unwinds in the order `LayerRun.deinit` retires
    // them: the swapchain first, the role it presents into next, the window
    // last. That covers every error return after the attach — the round trip,
    // the configure, the ack, the present, a report and the run's own
    // allocation — and an `errdefer` never fires on the successful return, so
    // the hand-over into `LayerRun` needs nothing to disarm it.
    errdefer content.release();
    try report.emit(
        "framebuffer surface: size={d}x{d} surface_version={d} content=noapi gpu surface\n",
        .{
            created[0],
            created[1],
            api.proxy_get_version(@ptrCast(handles.surface.?)),
        },
    );
    try layer.attach(api, handles, layer_options);
    try report.emit(
        "attach: attached={} layer={s} anchor_bits={d} exclusive_zone={d}" ++
            " margins=t{},r{},b{},l{} namespace=\"{s}\"\n",
        .{
            layer.isAttached(),
            @tagName(layer_options.layer),
            real.anchorBits(layer_options.anchor),
            layer_options.exclusive_zone,
            layer_options.margins.top,
            layer_options.margins.right,
            layer_options.margins.bottom,
            layer_options.margins.left,
            layer_options.namespace,
        },
    );

    // The compositor answers the initial empty commit with one configure.
    var roundtrips: u32 = 0;
    while (layer.machine.last_configured_serial == null and roundtrips < 32) {
        roundtrips += 1;
        if (api.display_roundtrip(display) < 0) return error.RoundtripFailed;
    }
    const serial = layer.machine.last_configured_serial orelse return error.NoConfigure;
    try report.emit(
        "configure delivered: serial={d} size={d}x{d} (requested {d}x{d})" ++
            " configured_count={d} state={s} roundtrips={d}\n",
        .{
            serial,
            layer.machine.current_width,
            layer.machine.current_height,
            layer_options.desired_width,
            layer_options.desired_height,
            layer.machine.configured_count,
            @tagName(layer.machine.state),
            roundtrips,
        },
    );

    try layer.ackLatestConfigure();
    try report.emit("ack delivered: acked_serial={?d} acked_count={d} state={s}\n", .{
        layer.machine.last_acked_serial,
        layer.machine.acked_count,
        @tagName(layer.machine.state),
    });

    try presentConfigured(layer, window, &content, report);

    // The state after this surface has been up while the run held the window,
    // measured the reserved extent and watched the output, is printed by
    // `reportSurfaceState` in `main`. A compositor `closed` is the only event
    // that can move a live surface out of the mapped state, and a healthy
    // compositor does not close a healthy layer surface on demand, so that
    // line records what the run actually witnessed rather than what it would
    // have liked to witness.

    // What the compositor said about the output, and how it reached the
    // surface. `output_changes` counts the mode batches that were pushed onto
    // the surface, so zero here means the output never moved rather than that
    // the adapter ignored one.
    const geometry = layer.outputGeometry();
    try report.emit(
        "output: connector=\"{s}\" mode={d}x{d} done_batches={d} scale={d}" ++
            " surface_output={d}x{d} output_changes={d} disconnected={}\n",
        .{
            layer.outputName(),
            geometry.width,
            geometry.height,
            geometry.done_count,
            geometry.scale,
            layer.machine.output_width,
            layer.machine.output_height,
            layer.machine.output_change_count,
            layer.outputDisconnected(),
        },
    );
    // The two zone numbers a client can know on its own. They are printed as
    // what this process asked for, and they are NOT the reserved extent: the
    // protocol has no request that reports what the compositor reserved. The
    // measured reservation is `measureReservation`, and it comes from an
    // ordinary window on the same display.
    try report.emit(
        "exclusive zone: requested={d} on_the_wire={d} reserved_zone={d}" ++
            " (client-side facts: what this run asked for and what its anchors" ++
            " allow. The compositor's reserved extent is measured in" ++
            " `reservation effect:` from an ordinary toplevel)\n",
        .{
            layer.machine.options.exclusive_zone,
            layer.exclusiveZoneRequest(),
            layer.machine.reservedZone(),
        },
    );

    const owned = try gpa.create(LayerRun);
    owned.* = .{
        .gpa = gpa,
        .layer = layer,
        .window = window,
        .content = content,
        .display = display,
        .shell_version = scan.layer_shell_version,
        .wire_surface = dyn.wireId(handles.surface),
    };
    return owned;
}

/// Follow the compositor's configure with a commit, drawing the bar first.
///
/// The configured size is the size the buffer needs, so the SDL window follows
/// the compositor rather than the other way round, and the swapchain is told
/// that size before the image is acquired. This is the commit half of the
/// cycle, and it runs once per configure the run acknowledges.
///
/// The bar carries one marker: its bottom rows, which are the edge a top dock's
/// reservation ends at. Every band is laid out in DEVICE pixels on the image
/// the driver handed out — never on a logical size — so one unit is one output
/// pixel and the rows counted here are the rows a capture sees. The same
/// numbers are printed with the frame that drew them.
fn presentConfigured(
    layer: *real.LayerSurface,
    window: *sdl3.video.Window,
    content: *GpuContent,
    report: *Reporter,
) !void {
    const width = layer.machine.current_width;
    const height = layer.machine.current_height;
    try window.setSize(width, height);
    const pixels = try window.getSizeInPixels();
    content.resize(.{ .width = @intCast(pixels[0]), .height = @intCast(pixels[1]) });
    // SAFETY: the image is acquired below and this returns the acquired one.
    const image = try content.beginFrame();
    // A rollback that fails leaves the recording abandoned with the driver
    // still holding the image, so it is reported rather than dropped and the
    // error that got this run here still propagates. A print that failed
    // would leave the process no way to report at all, so that case panics.
    errdefer content.abortFrame() catch |err| {
        report.emit("layer bar frame abort failed: {s}\n", .{@errorName(err)}) catch
            @panic("W22 layer shell could not report the frame abort failure");
    };
    // A sixteenth of the bar, capped, and never taller than the bar itself.
    const edge: u32 = @min(image.height / 16, 8);
    const bands: [3]Band = .{
        .{
            .offset = .{ 0, 0 },
            .size = .{ image.width, image.height },
            .color = clearValue(bar_body),
        },
        .{
            .offset = .{ 8, 8 },
            .size = .{ image.width / 8, image.height / 2 },
            .color = clearValue(bar_marker),
        },
        .{
            .offset = .{ 0, image.height - edge },
            .size = .{ image.width, edge },
            .color = clearValue(bar_edge),
        },
    };
    content.drawBands(&bands);
    const presented = try content.presentFrame();
    try report.emit(
        "buffer committed: output_size={d}x{d} configured_size={d}x{d}" ++
            " bar_bottom_band=y{d}..{d} swapchain_recreated={} present_out_of_date={}\n",
        .{
            image.width,
            image.height,
            width,
            height,
            image.height - edge,
            image.height,
            presented.swapchain_recreated,
            presented.present_out_of_date,
        },
    );
    try layer.commit();
    try report.emit("commit delivered: committed_count={d} state={s}\n", .{
        layer.machine.committed_count,
        @tagName(layer.machine.state),
    });
}

/// What one live zone update actually did, on the wire and against the
/// machine. Every field is an observation, and a refused update is reported
/// instead of retried: a role the compositor already finished has no second
/// answer to give.
const Updated = struct {
    /// The requests were refused; nothing reached the wire.
    refused: bool = false,
    /// A commit carried the new zone and the new size to the compositor.
    delivered: bool = false,
    /// The compositor answered that commit with a fresh configure.
    reconfigured: bool = false,
    /// That configure was acknowledged.
    acknowledged: bool = false,
    /// A buffer at the configured size was committed afterwards.
    new_buffer: bool = false,
    roundtrips: u32 = 0,
};

/// The live update: a different reserved zone and a different desired size on
/// a mapped surface.
///
/// `set_exclusive_zone` and `set_size` take effect at the NEXT commit, so the
/// update is delivered by a commit of its own rather than by the two requests:
/// until it is committed the compositor has no reason to answer anything. That
/// commit carries no new buffer, so the surface keeps the buffer it has, and a
/// compositor that agrees answers with a fresh configure — acknowledged, and
/// given a new buffer at the new size. A compositor that answers with nothing
/// is reported as answering nothing, and the last configured buffer goes back
/// up, so the bar is on screen either way and the reservation it made is still
/// measurable from the probe window.
fn updateReservation(run: *LayerRun, api: WaylandApi, report: *Reporter) !Updated {
    const layer = run.layer;
    var updated: Updated = .{};
    if (updateOptions(layer)) |_| {
        try report.emit("options update live: <accepted>\n", .{});
    } else |err| {
        // A compositor `closed` during the run finished the role, and then
        // there is nothing left to answer a new option.
        updated.refused = true;
        try report.emit("options update live: {s}\n", .{@errorName(err)});
        return updated;
    }
    try report.emit(
        "options recorded: exclusive_zone={d} on_the_wire={d} reserved_zone={d}" ++
            " margins=t{},r{},b{},l{} desired={d}x{d}\n",
        .{
            layer.machine.options.exclusive_zone,
            layer.exclusiveZoneRequest(),
            layer.machine.reservedZone(),
            layer.machine.options.margins.top,
            layer.machine.options.margins.right,
            layer.machine.options.margins.bottom,
            layer.machine.options.margins.left,
            layer.machine.options.desired_width,
            layer.machine.options.desired_height,
        },
    );
    // The toplevel probe can dispatch a layer configure while measuring its
    // geometry. Ack that configure before the state-only options commit.
    if (layer.machine.state == .configured) try layer.ackLatestConfigure();
    const configured_before = layer.machine.configured_count;
    try layer.commit();
    updated.delivered = true;
    try report.emit("zone update delivered by commit: committed_count={d} state={s}\n", .{
        layer.machine.committed_count,
        @tagName(layer.machine.state),
    });
    var roundtrips: u32 = 0;
    while (layer.machine.configured_count == configured_before and roundtrips < 32) {
        roundtrips += 1;
        if (api.display_roundtrip(run.display) < 0) return error.RoundtripFailed;
    }
    updated.roundtrips = roundtrips;
    updated.reconfigured = layer.machine.configured_count != configured_before;
    try report.emit(
        "compositor answer to the update: new_configure={} configured={d} roundtrips={d}\n",
        .{ updated.reconfigured, layer.machine.configured_count, roundtrips },
    );
    if (updated.reconfigured) {
        try layer.ackLatestConfigure();
        updated.acknowledged = true;
        try report.emit("re-ack: acked_count={d} state={s}\n", .{
            layer.machine.acked_count,
            @tagName(layer.machine.state),
        });
    }
    try presentConfigured(layer, run.window, &run.content, report);
    updated.new_buffer = true;
    return updated;
}

/// The two requests the update is made of. Both are live surface requests, so
/// both are refused by the same finished-role check, and neither of them is a
/// second renderer, a second connection or a second surface: the same surface,
/// the same compositor.
fn updateOptions(layer: *real.LayerSurface) !void {
    try layer.setExclusiveZone(updated_zone);
    try layer.setDesiredSize(0, @intCast(updated_zone));
}

/// Report one request path's answer by name and by the ending it answers
/// against, and fail when a finished surface accepted it. A printed
/// observation that a refusal is missing would be worthless, so each one is a
/// gate and not a line of output.
fn reportRefusal(
    report: *Reporter,
    scope: []const u8,
    label: []const u8,
    result: anyerror!void,
) !void {
    if (result) |_| {
        try report.emit("{s}: {s}=<accepted>\n", .{ scope, label });
        return error.RequestAcceptedAfterClose;
    } else |err| {
        try report.emit("{s}: {s}={s}\n", .{ scope, label, @errorName(err) });
    }
}

/// The client-side close: one teardown is claimed, a second is refused, and
/// every request against the finished surface is refused too. The wire-level
/// destroy is sent by `retireNative` afterwards, which is a separate step
/// because the role is still the compositor's until that request is on the
/// wire.
fn closeMachine(report: *Reporter, layer: *real.LayerSurface) !void {
    // A compositor `closed` during the run has already claimed the teardown.
    // Asking for a client close then has to report that rather than abort,
    // because both endings are correct and the difference is the observation.
    const client_close = layer.close();
    if (client_close) |_| {
        try report.emit("client close: claimed={} state={s}\n", .{
            true,
            @tagName(layer.machine.state),
        });
    } else |err| {
        try report.emit("client close: claimed={} state={s} outcome={s}\n", .{
            false,
            @tagName(layer.machine.state),
            @errorName(err),
        });
        if (err != error.DoubleTeardown) return err;
    }
    // The listener is released before the machine is consumed, so a configure
    // the compositor had already queued has nowhere to land. The role proxy
    // itself stays until the destructor goes out, which `attached` records.
    try report.emit("client close: attached={} teardown_performed={}\n", .{
        layer.isAttached(),
        layer.machine.teardown_performed,
    });

    try reportRefusal(report, "after close", "close", layer.close());
    try reportRefusal(report, "after close", "setAnchor", layer.setAnchor(.bottom_dock));
    try reportRefusal(report, "after close", "setMargins", layer.setMargins(.{ .top = 3 }));
    try reportRefusal(report, "after close", "setExclusiveZone", layer.setExclusiveZone(0));
    try reportRefusal(
        report,
        "after close",
        "setKeyboardInteractivity",
        layer.setKeyboardInteractivity(.exclusive),
    );
    try reportRefusal(report, "after close", "setDesiredSize", layer.setDesiredSize(320, 40));
    try reportRefusal(report, "after close", "setInputRegion", layer.setInputRegion(.{}));
    try reportRefusal(report, "after close", "applyOptions", layer.applyOptions());
    try reportRefusal(report, "after close", "ackConfigure", layer.ackConfigure(0));
    try reportRefusal(report, "after close", "commit", layer.commit());
    // A refused update recorded nothing, so what the options still report is
    // what the wire carries.
    try report.emit(
        "after close: exclusive_zone={d} on_the_wire={d} reserved_zone={d}" ++
            " margins=t{},r{},b{},l{}\n",
        .{
            layer.machine.options.exclusive_zone,
            layer.exclusiveZoneRequest(),
            layer.machine.reservedZone(),
            layer.machine.options.margins.top,
            layer.machine.options.margins.right,
            layer.machine.options.margins.bottom,
            layer.machine.options.margins.left,
        },
    );
}

/// Retire the real role on the wire, which is a step of its own.
///
/// `close` claims the single teardown on this side and deliberately leaves the
/// role bound: the compositor still holds it until a destructor reaches it, so
/// `isAttached` answers true after a close and nothing is claimed before the
/// request that earns it. `releaseNative` is that request — it sends
/// `zwlr_layer_surface_v1.destroy`, releases the output, shell and compositor
/// bindings and flushes them — and only then does the role read as detached.
/// The value stays readable afterwards, so every request made past the wire
/// retirement can still be asked for its refusal rather than assumed.
fn retireNative(report: *Reporter, layer: *real.LayerSurface) !void {
    layer.releaseNative();
    const attached = layer.isAttached();
    try report.emit(
        "wire retirement: zwlr_layer_surface_v1.destroy sent, output, shell and" ++
            " compositor bindings released, attached={}\n",
        .{attached},
    );
    if (attached) return error.RoleStillAttachedAfterRetirement;

    try reportRefusal(report, "after retirement", "close", layer.close());
    try reportRefusal(report, "after retirement", "setAnchor", layer.setAnchor(.bottom_dock));
    try reportRefusal(report, "after retirement", "setMargins", layer.setMargins(.{ .top = 3 }));
    try reportRefusal(report, "after retirement", "setExclusiveZone", layer.setExclusiveZone(0));
    try reportRefusal(
        report,
        "after retirement",
        "setKeyboardInteractivity",
        layer.setKeyboardInteractivity(.exclusive),
    );
    try reportRefusal(report, "after retirement", "setDesiredSize", layer.setDesiredSize(320, 40));
    try reportRefusal(report, "after retirement", "setInputRegion", layer.setInputRegion(.{}));
    try reportRefusal(report, "after retirement", "applyOptions", layer.applyOptions());
    try reportRefusal(report, "after retirement", "ackConfigure", layer.ackConfigure(0));
    try reportRefusal(report, "after retirement", "commit", layer.commit());
    try report.emit(
        "after retirement: teardown_performed={} state={s} exclusive_zone={d}\n",
        .{
            layer.machine.teardown_performed,
            @tagName(layer.machine.state),
            layer.machine.options.exclusive_zone,
        },
    );
}

/// One painted probe frame: what went on screen and where, in device pixels,
/// so a capture can be read against the same numbers this process read.
const Frame = struct {
    logical: [2]u32 = .{ 0, 0 },
    pixels: [2]u32 = .{ 0, 0 },
    output: [2]u32 = .{ 0, 0 },
    top_band: u32 = 0,
    bottom_band: u32 = 0,
    device_scale: f32 = 0,
};

/// What the probe window was at one settled moment.
///
/// Every field is a number the platform or the compositor reported about an
/// ordinary surface. None of them is a value this process requested for the
/// layer surface, and none of them is read from the layer surface at all.
const Probe = struct {
    logical: [2]u32 = .{ 0, 0 },
    pixels: [2]u32 = .{ 0, 0 },
    output: [2]u32 = .{ 0, 0 },
    device_scale: f32 = 0,
    display_scale: f32 = 0,
    visible: bool = false,
    occluded: bool = false,
    focused: bool = false,
    top_band: u32 = 0,
    bottom_band: u32 = 0,
    /// How many samples the settle loop took, and how many of them in a row
    /// repeated the size before it. A window that never came to rest is
    /// reported as unsettled, with both counts.
    samples: u32 = 0,
    stable: u32 = 0,
    settled: bool = false,
};

/// Device pixels per logical pixel, from the two sizes the platform reports. A
/// zero in either is no measurement, so it reads as no scale rather than as a
/// division this run performed.
fn deviceScale(logical: [2]u32, pixels: [2]u32) f32 {
    if (logical[1] == 0 or pixels[1] == 0) return 0;
    return @as(f32, @floatFromInt(pixels[1])) / @as(f32, @floatFromInt(logical[1]));
}

/// Whole device rows for a band authored in logical pixels. The bands are the
/// probe window's own edges, so they are counted in the device rows a capture
/// can see rather than in a unit that scales under it.
fn bandRows(logical_rows: u32, scale: f32) u32 {
    if (scale <= 0) return logical_rows;
    return @intFromFloat(@round(@as(f32, @floatFromInt(logical_rows)) * scale));
}

/// The ordinary path, in the same process, while the layer surface is up, and
/// the only source of the reserved extent that is not this process's request.
///
/// An ordinary toplevel must still open, map, report its observed state and
/// close, and its surface must never be acceptable as a layer surface. On top
/// of that it carries real content: a compositor takes an exclusive zone out
/// of the area it hands to managed windows, so a window with a buffer in it
/// reports that reservation in the size the compositor configured for it. That
/// size is a number this process neither requested for the panel nor can set
/// for the panel from here, which is what makes it an independent effect.
const ToplevelControl = struct {
    gpa: std.mem.Allocator,
    application: *host.Application,
    handle: contract.WindowHandle,
    /// The `wl_display` SDL handed out for this window: the one connection
    /// every surface in this run shares, so a pump through it is a pump for the
    /// layer surface too.
    display: ?DisplayPtr = null,
    /// Present only on a driver that can put a buffer on a screen. The
    /// windowless driver opens the window and reports the same facts about it
    /// with no content, and a surface the compositor was never given anything
    /// to map is never counted as a measurement. On Wayland it is mandatory:
    /// the reservation this run measures only means something against a probe
    /// the compositor actually mapped and filled.
    content: ?GpuContent = null,
    frames: u32 = 0,
    paint_refused: bool = false,

    /// The wire id of this ordinary toplevel's own `wl_surface`, printed beside
    /// the layer surface's so a reader can prove the two are different objects
    /// on one connection and that no layer request went to this one.
    wire_surface: ?u32 = null,

    fn open(
        gpa: std.mem.Allocator,
        io: Io,
        report: *Reporter,
        application: *host.Application,
        api: WaylandApi,
        dyn: *DynLoader,
        gpu: ?*noapi.Gpu,
    ) !ToplevelControl {
        const handle = try application.openWindow(.{
            .title = toplevel_title,
            .width = 420,
            .height = 260,
            .visible = true,
            // The canonical seam for a window that presents through noapi: the
            // host asks SDL for `SDL_WINDOW_VULKAN`, which is what
            // `SDL_Vulkan_CreateSurface` requires below. No SDL renderer is
            // ever created on this window.
            .gpu_surface = gpu != null,
        });
        errdefer _ = application.closeWindow(handle) catch |err| {
            report.emit("toplevel open teardown close: {s}\n", .{@errorName(err)}) catch
                @panic("W22 layer shell smoke could not report the teardown close failure");
        };
        const managed = try application.getWindow(handle);
        const props = try managed.native.sdl.getProperties();
        const handles: real.Handles = .{
            .display = if (props.wayland_display) |value| value.value else null,
            .surface = if (props.wayland_surface) |value| value.value else null,
            .xdg_toplevel = if (props.wayland_xdg_toplevel) |value| value.value else null,
            .driver_name = sdl3.video.getCurrentDriverName(),
            .roleless = false,
        };
        try report.emit(
            "toplevel opened: title=\"{s}\" xdg_toplevel_role={} usable_as_layer={}\n",
            .{ toplevel_title, handles.xdg_toplevel != null, handles.usable() },
        );
        try report.emit(
            "probe on a live xdg_toplevel surface: capability={s}" ++
                " (an ordinary toplevel is never relabelled as a layer surface)\n",
            .{@tagName(real.probe(api, handles))},
        );

        var control: ToplevelControl = .{
            .gpa = gpa,
            .application = application,
            // The live handle, not a copy of the open call's argument: every
            // later lookup in this struct goes back through the host, so a
            // stale handle here would resolve a window that is gone.
            .handle = handle,
            .display = if (handles.display) |value| @as(DisplayPtr, @ptrCast(value)) else null,
            .wire_surface = dyn.wireId(handles.surface),
        };
        // The content presents into this window, so it is released before the
        // host destroys the window. The error path below releases it in the
        // same order.
        errdefer control.releaseContent();
        if (sdl3.video.getCurrentDriverName()) |driver_name| {
            if (std.mem.eql(u8, driver_name, "wayland")) {
                // The same device-side surface the layer bar is presented
                // through, on this window, on the same device. It is
                // mandatory for the same reason it is mandatory there: a probe
                // the compositor never mapped proves nothing about a
                // reservation. A refusal here is this run's original error,
                // propagated unchanged.
                const current = try application.getWindow(handle);
                const pixels = try current.native.pixelExtent();
                const extent: noapi.Extent2D = .{ .width = pixels.width, .height = pixels.height };
                const device = gpu orelse return error.NoGpuDevice;
                const content = try GpuContent.open(device, current.native.sdl, extent);
                // No `errdefer` of its own: `control.releaseContent` is
                // registered in this function's scope above and already
                // releases this surface once, from inside the value. A second
                // registration here would fire beside it on the same error
                // return and release the same surface twice.
                control.content = content;
                try report.emit(
                    "probe content: noapi gpu surface on the toplevel" ++
                        " extent={d}x{d} device=shared\n",
                    .{ extent.width, extent.height },
                );
            } else {
                try report.emit(
                    "probe content: none, the {s} driver cannot put a buffer on this toplevel\n",
                    .{driver_name},
                );
            }
        }
        const first = try control.settle(io, report, api, "toplevel");
        const settled = try application.getWindow(handle);
        try report.emit(
            "toplevel observed: requested={d}x{d} observed={d}x{d} pixels={d}x{d}" ++
                " visible={} occluded={} focused={}\n",
            .{
                settled.requested.size.width,
                settled.requested.size.height,
                first.logical[0],
                first.logical[1],
                first.pixels[0],
                first.pixels[1],
                first.visible,
                first.occluded,
                first.focused,
            },
        );
        return control;
    }

    /// Present the probe window's content at the size the compositor gave it.
    ///
    /// Every band is laid out in DEVICE pixels on the swapchain image the
    /// driver handed out, so one drawing unit is one output pixel: the two
    /// bands land on exact device rows and the bounds this returns are the
    /// bounds a capture has. The top band is the edge a top dock's reservation
    /// moves, which is why it is drawn thick enough to survive a compositor
    /// that draws a border.
    fn paint(self: *ToplevelControl, content: *GpuContent) !Frame {
        const managed = try self.application.getWindow(self.handle);
        const native = managed.native.sdl;
        const logical_raw = try native.getSize();
        const pixel_raw = try native.getSizeInPixels();
        const logical: [2]u32 = .{ @intCast(logical_raw[0]), @intCast(logical_raw[1]) };
        const pixels: [2]u32 = .{ @intCast(pixel_raw[0]), @intCast(pixel_raw[1]) };
        const scale = deviceScale(logical, pixels);
        // The swapchain follows the window's own pixel extent, so a configure
        // that resizes this toplevel is a resized swapchain rather than a
        // stretched image. The compositor's configured extent is what a buffer
        // has to match, so the image the driver hands out is what is drawn on.
        content.resize(.{ .width = pixels[0], .height = pixels[1] });
        const image = try content.beginFrame();
        // A rollback that fails leaves the recording abandoned with the driver
        // still holding the image, and this path has no reporter to name that
        // through, so the run stops here instead of going on to report a
        // geometry it can no longer draw into.
        errdefer content.abortFrame() catch
            @panic("W22 probe window could not return the abandoned image");
        const output: [2]u32 = .{ image.width, image.height };
        if (output[0] == 0 or output[1] == 0) return error.EmptyProbeSurface;
        const top_band: u32 = @max(6, bandRows(8, scale));
        const bottom_band: u32 = @max(3, bandRows(4, scale));
        if (top_band + bottom_band >= output[1]) return error.ProbeSurfaceTooSmall;
        const bands: [3]Band = .{
            .{
                .offset = .{ 0, 0 },
                .size = .{ output[0], output[1] },
                .color = clearValue(probe_body),
            },
            .{
                .offset = .{ 0, 0 },
                .size = .{ output[0], top_band },
                .color = clearValue(probe_top_band),
            },
            .{
                .offset = .{ 0, output[1] - bottom_band },
                .size = .{ output[0], bottom_band },
                .color = clearValue(probe_bottom_band),
            },
        };
        content.drawBands(&bands);
        _ = try content.presentFrame();
        self.frames += 1;
        return .{
            .logical = logical,
            .pixels = pixels,
            .output = output,
            .top_band = top_band,
            .bottom_band = bottom_band,
            .device_scale = scale,
        };
    }

    /// Put one frame of content on the window, and report a frame that cannot
    /// be drawn exactly once. A settle loop that ended on a refused frame would
    /// otherwise report a geometry it drew nothing into.
    fn paintOnce(self: *ToplevelControl, report: *Reporter) !void {
        if (self.content) |*content| {
            if (self.paint(content)) |_| {} else |err| {
                if (self.paint_refused) return;
                self.paint_refused = true;
                try report.emit("probe frame refused: {s}\n", .{@errorName(err)});
            }
        }
    }

    /// One nonblocking pass over everything the compositor may have sent: the
    /// shared display queue first, then the host's own event batch.
    fn pump(self: *ToplevelControl, api: WaylandApi) !bool {
        if (self.display) |display| _ = api.display_dispatch_pending(display);
        return self.application.step();
    }

    /// Pump until this window stops moving, or the bound runs out.
    ///
    /// A compositor can animate a reservation change and a tile layout settles
    /// a frame or two after its configure, so one sample would be a guess. The
    /// bound is what keeps an unsettled window an honest observation: the
    /// samples taken and the identical ones in a row are printed with it, and
    /// `settled` says whether the loop watched it come to rest.
    fn settle(
        self: *ToplevelControl,
        io: Io,
        report: *Reporter,
        api: WaylandApi,
        label: []const u8,
    ) !Probe {
        var probe: Probe = .{};
        var previous: ?[2]u32 = null;
        const deadline = sdl3.timer.getMillisecondsSinceInit() + settle_bound_ms;
        while (probe.samples < settle_max_samples) {
            if (sdl3.timer.getMillisecondsSinceInit() >= deadline) break;
            try self.paintOnce(report);
            _ = try self.pump(api);
            const managed = try self.application.getWindow(self.handle);
            try managed.refresh();
            probe.samples += 1;
            const current: [2]u32 = .{ managed.observed.size.width, managed.observed.size.height };
            probe.stable = if (previous) |was|
                (if (was[0] == current[0] and was[1] == current[1]) probe.stable + 1 else 0)
            else
                0;
            previous = current;
            probe.logical = current;
            probe.pixels = .{ managed.observed.pixels.width, managed.observed.pixels.height };
            probe.device_scale = deviceScale(probe.logical, probe.pixels);
            probe.display_scale = managed.observed.display_scale;
            probe.visible = managed.observed.visible;
            probe.occluded = managed.observed.occluded;
            probe.focused = managed.observed.focused;
            if (probe.samples >= settle_min_samples and probe.stable >= settle_stable_samples) {
                probe.settled = true;
                break;
            }
            try Io.sleep(io, Io.Duration.fromMilliseconds(poll_ms), .real);
        }
        if (self.content) |*content| {
            if (self.paint(content)) |frame| {
                probe.output = frame.output;
                probe.top_band = frame.top_band;
                probe.bottom_band = frame.bottom_band;
            } else |_| {}
        }
        try report.emit(
            "{s} probe: logical={d}x{d} pixels={d}x{d} output={d}x{d} device_scale={d:.3}" ++
                " display_scale={d:.3} visible={} occluded={} focused={} samples={d}" ++
                " stable={d} settled={} frames={d} top_band=y0..{d} bottom_band=y{d}..{d}\n",
            .{
                label,
                probe.logical[0],
                probe.logical[1],
                probe.pixels[0],
                probe.pixels[1],
                probe.output[0],
                probe.output[1],
                probe.device_scale,
                probe.display_scale,
                probe.visible,
                probe.occluded,
                probe.focused,
                probe.samples,
                probe.stable,
                probe.settled,
                self.frames,
                probe.top_band,
                probe.output[1] -| probe.bottom_band,
                probe.output[1],
            },
        );
        return probe;
    }

    /// Release the content surface while the platform window is still alive.
    ///
    /// The platform surface noapi made from this window references the window,
    /// so it goes first on every path including an early return. The device it
    /// lives on is NOT released here: both windows in this run present through
    /// it and `main` owns it.
    fn releaseContent(self: *ToplevelControl) void {
        if (self.content) |*content| {
            content.release();
            self.content = null;
        }
    }

    /// Close the ordinary window, content first. The value is poisoned
    /// afterwards, so a caller that uses it again is reading storage this run
    /// no longer owns.
    fn close(self: *ToplevelControl, report: *Reporter) !void {
        self.releaseContent();
        const application = self.application;
        const closed = try application.closeWindow(self.handle);
        _ = try application.step();
        const stale = application.getWindow(self.handle);
        try report.emit("toplevel closed: closeWindow={} getWindow={s} window_count={d}\n", .{
            closed,
            if (stale) |_| "<live>" else |err| @errorName(err),
            application.window_count,
        });
        // SAFETY: `releaseContent` destroyed the GPU surface and `closeWindow`
        // dropped the window, so every field here is already dead; a read
        // after this line is storage this run no longer owns.
        self.* = undefined;
    }
};

/// The reserved extent, measured from the only source that is not this
/// process's own request.
///
/// A compositor takes a top dock's exclusive zone out of the area it hands to
/// managed windows, so the probe window's configured height is that area minus
/// the reservation. Both heights below were configured by the compositor for
/// an ordinary surface; the zone this run asked for is not an input to the
/// comparison, and neither is the size the panel's own configure carried. With
/// `--verify-reservation`, a run whose two heights do not differ by the
/// requested zone delta fails instead of reporting a pass.
fn measureReservation(
    io: Io,
    verdict: *Verdict,
    control: *ToplevelControl,
    run: *LayerRun,
    report: *Reporter,
    api: WaylandApi,
    options: Options,
) !void {
    const before = try control.settle(io, report, api, "reservation before");
    const updated = try updateReservation(run, api, report);
    const after = try control.settle(io, report, api, "reservation after");

    const expected_logical: i64 = -(@as(i64, updated_zone) - @as(i64, baseline_zone));
    const observed_logical: i64 = @as(i64, after.logical[1]) - @as(i64, before.logical[1]);
    const observed_width: i64 = @as(i64, after.logical[0]) - @as(i64, before.logical[0]);
    const observed_device: i64 = @as(i64, after.pixels[1]) - @as(i64, before.pixels[1]);
    // The device-pixel delta is evidence next to the logical one, not the gate,
    // so the scale it multiplies is bounded to a range a real output can have.
    // A delta computed from an absurd scale would be a number this run invented.
    const scale_rows: i64 = if (before.device_scale > 0 and before.device_scale <= 8)
        @intFromFloat(@round(before.device_scale))
    else
        0;
    const expected_device: i64 = expected_logical * scale_rows;
    const matched = observed_logical == expected_logical;
    const measurable = before.settled and after.settled and before.visible and
        after.visible and before.logical[1] > 0 and after.logical[1] > 0 and !updated.refused;
    try report.emit(
        "reservation effect: zone_requested={d}->{d} update_committed={} new_configure={}" ++
            " new_buffer={} probe_logical_height={d}->{d} logical_delta={d}" ++
            " expected_logical_delta={d} match={} probe_logical_width={d}->{d} width_delta={d}" ++
            " probe_pixel_height={d}->{d} device_height_delta={d}" ++
            " expected_device_height_delta={d}" ++
            " device_scale={d:.3}->{d:.3} measurable={}\n",
        .{
            baseline_zone,
            updated_zone,
            updated.delivered,
            updated.reconfigured,
            updated.new_buffer,
            before.logical[1],
            after.logical[1],
            observed_logical,
            expected_logical,
            matched,
            before.logical[0],
            after.logical[0],
            observed_width,
            before.pixels[1],
            after.pixels[1],
            observed_device,
            expected_device,
            before.device_scale,
            after.device_scale,
            measurable,
        },
    );
    try report.emit(
        "reservation effect source: both heights above are configure-driven geometry for" ++
            " an ordinary toplevel on this display; the zone this run requested and the" ++
            " size the panel was configured with are not inputs to that comparison\n",
        .{},
    );
    if (options.verify_reservation) {
        verdict.require(measurable, error.ReservationNotMeasured);
        verdict.require(matched, error.ReservationEffectNotObserved);
    }
    try report.emit(
        "reservation verdict: measurable={} match={} requested_verification={} failure={?s}\n",
        .{
            measurable,
            matched,
            options.verify_reservation,
            if (verdict.failure) |failure| @errorName(failure) else null,
        },
    );
}

/// Keep both surfaces up for a bounded time, pumping while it runs, so an
/// external capture sees the state this run last committed and not a surface
/// that has gone quiet. The probe window keeps its content fresh for the same
/// reason: a capture of a window that stopped presenting is a capture of
/// whatever the compositor kept.
fn holdOpen(
    io: Io,
    run: *LayerRun,
    control: *ToplevelControl,
    report: *Reporter,
    api: WaylandApi,
    hold_ms: u64,
) !void {
    if (hold_ms == 0) return;
    try report.emit("HOLD-BEGIN layer-up {d}ms\n", .{hold_ms});
    const until = sdl3.timer.getMillisecondsSinceInit() + hold_ms;
    while (sdl3.timer.getMillisecondsSinceInit() < until) {
        _ = api.display_dispatch_pending(run.display);
        _ = try control.application.step();
        try control.paintOnce(report);
        try Io.sleep(io, Io.Duration.fromMilliseconds(poll_ms), .real);
    }
    try report.emit("HOLD-END layer-up\n", .{});
}

/// The state of the live layer surface at one named point in the run.
///
/// A compositor `closed` is the only event that can move a live surface out of
/// the mapped state, so this is where the run says whether it witnessed one. A
/// healthy compositor does not close a healthy layer surface on demand, so
/// `compositor_closed=false` is the expected observation and is never a claim
/// that the compositor drove the close path.
fn reportSurfaceState(report: *Reporter, run: *LayerRun, label: []const u8) !void {
    const layer = run.layer;
    try report.emit(
        "{s}: state={s} compositor_closed={} attached={} configured={d}" ++
            " acked={d} committed={d} output_attached={} teardown_performed={}\n",
        .{
            label,
            @tagName(layer.machine.state),
            layer.machine.state == .closed or layer.machine.state == .destroyed,
            layer.isAttached(),
            layer.machine.configured_count,
            layer.machine.acked_count,
            layer.machine.committed_count,
            layer.machine.output_attached,
            layer.machine.teardown_performed,
        },
    );
}

/// The wire identity of both surfaces this run owns, on the one connection they
/// share.
///
/// A `WAYLAND_DEBUG` log names every object by the id the client library gave
/// it, so these two numbers are what lets a reader prove that an input-region
/// request went to this layer's own surface and not to the ordinary toplevel
/// open beside it on the same display. `distinct` is the claim that they are
/// two objects at all, and a libwayland without `wl_proxy_get_id` reports `@`
/// for both rather than a number this run invented.
fn reportWireIds(report: *Reporter, run: *LayerRun, control: *ToplevelControl) !void {
    const layer_surface = run.wire_surface;
    const toplevel_surface = control.wire_surface;
    const distinct = if (layer_surface != null and toplevel_surface != null)
        layer_surface.? != toplevel_surface.?
    else
        false;
    const layer_text = WireText.of(layer_surface);
    const toplevel_text = WireText.of(toplevel_surface);
    try report.emit(
        "wire ids: layer_surface={s} toplevel_surface={s} distinct={} source=wl_proxy_get_id\n",
        .{ layer_text.slice(), toplevel_text.slice(), distinct },
    );
    if (!distinct) {
        try report.emit(
            "wire ids unavailable: without two distinct wire ids no protocol log can be" ++
                " attributed to this layer rather than to the toplevel beside it\n",
            .{},
        );
    }
}

/// One reading of the output the layer surface is placed on.
const OutputReading = struct {
    /// `done` events the compositor has sent for it.
    done: u32 = 0,
    scale: i32 = 1,
    width: u32 = 0,
    height: u32 = 0,
    /// Mode batches that were pushed onto the surface. A scale change under an
    /// unchanged mode is an event this run records without treating it as a
    /// resize of the surface, because no resize happened.
    applied: u32 = 0,
    state: real.SurfaceState = .uninitialized,

    fn sameAs(self: OutputReading, other: OutputReading) bool {
        return self.done == other.done and self.scale == other.scale and
            self.width == other.width and self.height == other.height and
            self.applied == other.applied and self.state == other.state;
    }
};

/// What one bounded watch saw.
const OutputWatch = struct {
    baseline: OutputReading = .{},
    latest: OutputReading = .{},
    events: u32 = 0,
    printed: u32 = 0,
    reconfigured: bool = false,
    acknowledged: bool = false,
    new_buffer: bool = false,
    followed_ms: u64 = 0,
    /// How many follow-ups this watch started: one per applied mode batch it
    /// had not yet answered.
    follow_attempts: u32 = 0,
    /// Why the watch ended before its bound, when something ended it.
    stopped: ?[]const u8 = null,
};

/// Read the live output state the adapter keeps for this surface.
fn readOutput(layer: *real.LayerSurface) OutputReading {
    const geometry = layer.outputGeometry();
    return .{
        .done = geometry.done_count,
        .scale = geometry.scale,
        .width = geometry.width,
        .height = geometry.height,
        .applied = layer.machine.output_change_count,
        .state = layer.machine.state,
    };
}

/// Why the watch must stop, or null while the surface and its output are both
/// still there. A removed output and a compositor `closed` are the two endings
/// a watch has to survive, and neither is worth another request on the wire.
fn watchEndReason(layer: *real.LayerSurface) ?[]const u8 {
    if (layer.outputDisconnected()) return "the output was removed";
    return switch (layer.machine.state) {
        .closed => "the compositor closed the layer surface",
        .destroyed => "the layer surface was destroyed",
        else => null,
    };
}

/// Watch the real output the layer surface is on, for a bounded window.
///
/// This process never touches a compositor. It prints when the window is open,
/// and an operator changes that output's scale or mode while the watch runs;
/// every event that comes back is recorded, and an applied mode change is
/// answered the way the protocol requires — the surface is back in `attached`
/// after one, so a commit is refused until the configure that decided the new
/// size is acknowledged and given a new buffer. `--verify-output` fails the run
/// when nothing at all was observed, or when a mode change was applied and not
/// followed.
fn watchOutput(
    io: Io,
    verdict: *Verdict,
    run: *LayerRun,
    control: *ToplevelControl,
    probe: Probe,
    report: *Reporter,
    api: WaylandApi,
    options: Options,
) !void {
    const layer = run.layer;
    var watch: OutputWatch = .{};
    watch.baseline = readOutput(layer);
    watch.latest = watch.baseline;
    try report.emit(
        "OUTPUT-WATCH-READY bound_ms={d} done_batches={d} scale={d} mode={d}x{d}" ++
            " applied_mode_batches={d} state={s} probe_logical={d}x{d} probe_pixels={d}x{d}\n",
        .{
            options.output_watch_ms,
            watch.latest.done,
            watch.latest.scale,
            watch.latest.width,
            watch.latest.height,
            watch.latest.applied,
            @tagName(watch.latest.state),
            probe.logical[0],
            probe.logical[1],
            probe.pixels[0],
            probe.pixels[1],
        },
    );
    const started = sdl3.timer.getMillisecondsSinceInit();
    const deadline = started + options.output_watch_ms;
    // The applied mode batch this watch has already answered. A batch above it
    // is one this run still owes a follow-up to, so the cursor is the count and
    // not a boolean: one watch can owe more than one.
    var followed_up_to = watch.baseline.applied;
    while (sdl3.timer.getMillisecondsSinceInit() < deadline) {
        if (watchEndReason(layer)) |why| {
            watch.stopped = why;
            break;
        }
        _ = try control.pump(api);
        try control.paintOnce(report);
        const reading = readOutput(layer);
        if (!reading.sameAs(watch.latest)) {
            watch.events += 1;
            if (watch.printed < watch_print_limit) {
                watch.printed += 1;
                try report.emit(
                    "output watch event {d}: elapsed_ms={d} done_batches={d} scale={d}" ++
                        " mode={d}x{d} applied_mode_batches={d} state={s}\n",
                    .{
                        watch.events,
                        sdl3.timer.getMillisecondsSinceInit() - started,
                        reading.done,
                        reading.scale,
                        reading.width,
                        reading.height,
                        reading.applied,
                        @tagName(reading.state),
                    },
                );
            }
            watch.latest = reading;
        }
        // One follow-up per applied mode batch, not one per watch: a second
        // batch can arrive while the first follow-up is still waiting, and each
        // of them is owed its own configure, acknowledgement and buffer.
        if (watch.latest.applied > followed_up_to) {
            watch.follow_attempts += 1;
            try followOutputChange(io, run, control, report, api, &watch, deadline);
            followed_up_to = watch.latest.applied;
            watch.latest = readOutput(layer);
        }
        try Io.sleep(io, Io.Duration.fromMilliseconds(poll_ms), .real);
    }
    if (watchEndReason(layer)) |why| watch.stopped = why;
    try report.emit(
        "output watch verdict: events={d} printed={d} done_batches={d}->{d} scale={d}->{d}" ++
            " mode={d}x{d}->{d}x{d} applied_mode_batches={d}->{d} follow_attempts={d}" ++
            " new_configure={} re_acked={} new_buffer={} follow_up_ms={d} stopped_early={?s}\n",
        .{
            watch.events,
            watch.printed,
            watch.baseline.done,
            watch.latest.done,
            watch.baseline.scale,
            watch.latest.scale,
            watch.baseline.width,
            watch.baseline.height,
            watch.latest.width,
            watch.latest.height,
            watch.baseline.applied,
            watch.latest.applied,
            watch.follow_attempts,
            watch.reconfigured,
            watch.acknowledged,
            watch.new_buffer,
            watch.followed_ms,
            watch.stopped,
        },
    );
    if (options.verify_output) {
        const mode_changed = watch.latest.applied > watch.baseline.applied;
        const change_followed = watch.reconfigured and watch.acknowledged and watch.new_buffer;
        verdict.require(watch.stopped == null, error.OutputWatchStoppedEarly);
        verdict.require(watch.events > 0, error.OutputEventNotObserved);
        verdict.require(!mode_changed or change_followed, error.OutputChangeNotFollowed);
    }
}

/// Whether a layer surface is holding a configure it has not acknowledged.
///
/// A mode batch puts the surface back in `attached` with its last
/// acknowledgement still in place; the configure that answers the batch puts it
/// in `configured` with nothing acknowledged. That configure can already be on
/// the connection before this run notices the batch, because the batch and the
/// configure are one compositor round trip and this run samples every few
/// milliseconds. So the condition to wait for is a configure being PENDING, not
/// a new configure arriving: the pending one is the answer to this batch, and
/// waiting for a second one waits for an event the compositor has no reason to
/// send, and then reports a mode change that was in fact answered.
fn configurePending(layer: *real.LayerSurface) bool {
    return layer.machine.state == .configured and layer.machine.last_acked_serial == null;
}

/// Answer the mode change the surface just took.
///
/// After a mode batch the surface is back in `attached`: its size is decided at
/// the next commit, and the adapter refuses a commit until the configure that
/// decided it is acknowledged. So this is the wait, the acknowledgement and
/// the new buffer, and each of them is reported by what it actually did.
///
/// The wait is bounded by two things and by nothing else: the end of the watch
/// window this follow-up belongs to, and the standalone reconfigure bound. A
/// compositor that answers a mode change after a few seconds is waited for
/// instead of written off, and a compositor that never answers is reported as
/// one that never answered, with the milliseconds it was given.
fn followOutputChange(
    io: Io,
    run: *LayerRun,
    control: *ToplevelControl,
    report: *Reporter,
    api: WaylandApi,
    watch: *OutputWatch,
    deadline: u64,
) !void {
    const layer = run.layer;
    const configured_before = layer.machine.configured_count;
    const started = sdl3.timer.getMillisecondsSinceInit();
    // The watch's own end bounds this wait, and never below the standalone
    // bound: a batch that lands in the last milliseconds of a watch is still
    // owed the same wait a batch in the first ones gets, so the wait is
    // `max(watch end, standalone bound)` and never the shorter of the two.
    const wait_until = @max(deadline, started + reconfigure_bound_ms);
    while (!configurePending(layer) and layer.machine.configured_count == configured_before and
        sdl3.timer.getMillisecondsSinceInit() < wait_until)
    {
        _ = try control.pump(api);
        try control.paintOnce(report);
        try Io.sleep(io, Io.Duration.fromMilliseconds(poll_ms), .real);
    }
    watch.followed_ms = sdl3.timer.getMillisecondsSinceInit() - started;
    const arrived = layer.machine.configured_count != configured_before;
    watch.reconfigured = arrived or configurePending(layer);
    if (!watch.reconfigured) {
        try report.emit(
            "output watch follow-up: no configure for the new mode within {d}ms," ++
                " configured={d} state={s} output={d}x{d}\n",
            .{
                watch.followed_ms,
                layer.machine.configured_count,
                @tagName(layer.machine.state),
                layer.machine.output_width,
                layer.machine.output_height,
            },
        );
        return;
    }
    try layer.ackLatestConfigure();
    watch.acknowledged = true;
    try presentConfigured(layer, run.window, &run.content, report);
    watch.new_buffer = true;
    // `size_at_configure` is the surface's own size at the moment the configure
    // was counted, and `output` is what the same machine computed from the mode
    // batch. They are printed together and neither is claimed as the other: the
    // state machine recomputes an edge-anchored width from the output on every
    // batch, so a width that already reads right proves nothing about which of
    // the two wrote it.
    try report.emit(
        "output watch follow-up: new_configure=true re_acked=true new_buffer=true" ++
            " waited_ms={d} configure={s} size_at_configure={d}x{d} output={d}x{d}" ++
            " configured={d} acked={d} state={s}\n",
        .{
            watch.followed_ms,
            if (arrived) "arrived" else "already-pending",
            layer.machine.current_width,
            layer.machine.current_height,
            layer.machine.output_width,
            layer.machine.output_height,
            layer.machine.configured_count,
            layer.machine.acked_count,
            @tagName(layer.machine.state),
        },
    );
}

/// The terminal arm: a bounded window in which this process does nothing but
/// pump, so that something outside it can end this role while the role is still
/// live and mapped.
///
/// The run names the end it is waiting for and reports the one it saw. It
/// reports the two possible endings SEPARATELY and never reports one as the
/// other, because it cannot tell them apart on its own: a compositor-delivered
/// `closed` and the removal of the output under the role both leave this state
/// machine finished, both arrive on the connection this process owns, and the
/// adapter records one teardown for both. What the run can say is that the role
/// ended while it was live, and whether the registry reported the output gone.
/// Whether a `zwlr_layer_surface_v1.closed` EVENT arrived is a question about
/// the wire, and it is left to a reader of the protocol log.
///
/// Nothing here asks the compositor for anything. The compositor change is made
/// by whoever is driving this run, after the `TERMINAL-ARM-READY` line, and the
/// arm only reports what came back.
fn runTerminalArm(
    io: Io,
    verdict: *Verdict,
    run: *LayerRun,
    control: *ToplevelControl,
    report: *Reporter,
    api: WaylandApi,
    options: Options,
) !void {
    const layer = run.layer;
    try report.emit(
        "TERMINAL-ARM-READY expect={s} bound_ms={d} state={s} configured={d} acked={d}" ++
            " committed={d} output_attached={} output=\"{s}\"\n",
        .{
            options.terminal_expect.text(),
            options.terminal_arm_ms,
            @tagName(layer.machine.state),
            layer.machine.configured_count,
            layer.machine.acked_count,
            layer.machine.committed_count,
            layer.machine.output_attached,
            layer.outputName(),
        },
    );
    const started = sdl3.timer.getMillisecondsSinceInit();
    const deadline = started + options.terminal_arm_ms;
    var polls: u32 = 0;
    var ended: ?[]const u8 = null;
    // A pump error here is recorded once and the arm keeps watching: what this
    // arm measures is the layer role's own connection, and a compositor that has
    // just taken the only output away may well have taken the probe window with
    // it. Losing the probe is not this arm's failure, and a run that aborted on
    // it would report no terminal evidence at all.
    var pump_error: ?[]const u8 = null;
    while (sdl3.timer.getMillisecondsSinceInit() < deadline) {
        polls += 1;
        if (control.pump(api)) |_| {} else |err| {
            if (pump_error == null) {
                pump_error = @errorName(err);
                try report.emit(
                    "terminal arm: the probe pump reported {s} once; the arm kept watching this" ++
                        " role's own connection\n",
                    .{pump_error.?},
                );
            }
        }
        if (watchEndReason(layer)) |why| {
            ended = why;
            break;
        }
        try Io.sleep(io, Io.Duration.fromMilliseconds(poll_ms), .real);
    }
    // The other of the two endings, when a compositor sends both, gets the grace
    // window rather than the next run. The order is the compositor's and not
    // this process's, so a report that printed only the first thing observed
    // would leave the other unrecorded.
    if (ended != null) {
        const grace = sdl3.timer.getMillisecondsSinceInit() + terminal_grace_ms;
        while (sdl3.timer.getMillisecondsSinceInit() < grace) {
            polls += 1;
            if (control.pump(api)) |_| {} else |err| {
                if (pump_error == null) {
                    pump_error = @errorName(err);
                    try report.emit("terminal grace: probe pump failed: {s}\n", .{pump_error.?});
                }
            }
            try Io.sleep(io, Io.Duration.fromMilliseconds(poll_ms), .real);
        }
    }
    const state = layer.machine.state;
    const finished = state == .closed or state == .destroyed;
    const removed = layer.outputDisconnected();
    try report.emit(
        "terminal arm verdict: expect={s} elapsed_ms={d} polls={d} ended={?s}" ++
            " role_finished={} output_removed={} output_attached={} teardown_performed={}" ++
            " state={s} configured={d} acked={d} committed={d}\n",
        .{
            options.terminal_expect.text(),
            sdl3.timer.getMillisecondsSinceInit() - started,
            polls,
            ended,
            finished,
            removed,
            layer.machine.output_attached,
            layer.machine.teardown_performed,
            @tagName(state),
            layer.machine.configured_count,
            layer.machine.acked_count,
            layer.machine.committed_count,
        },
    );
    // The end this run was asked for, judged by what this process can see: the
    // role finished while it was live, or the registry reported the output this
    // role was placed on gone. A run asked for one and given the other fails
    // here, and the failure is the run's own: the caller gets a non-zero exit
    // and every line above it, rather than a pass from the end it did get.
    const observed = switch (options.terminal_expect) {
        .none => return error.MissingTerminalExpect,
        .closed => finished,
        .output_removed => removed,
    };
    verdict.require(observed, error.TerminalEventNotObserved);
}

/// What one bounded observation window saw on the owned layer surface.
///
/// Every counter here is an event the compositor sent on the connection this
/// process owns. Nothing in this run synthesizes a pointer event, and
/// `delivered` counts only the events whose target window is the layer
/// surface's own roleless window, so an event the compositor delivered to the
/// ordinary toplevel beside it is never counted as pointer input to this
/// layer. A window that saw nothing reports zeros, which is an observation and
/// not a pass.
const PointerSample = struct {
    polled: u32 = 0,
    delivered: u32 = 0,
    enter: u32 = 0,
    motion: u32 = 0,
    button: u32 = 0,
    left: u32 = 0,
    other_window: u32 = 0,
};

/// Count the pointer events already queued for `id`.
fn countLayerPointer(id: sdl3.video.WindowId, sample: *PointerSample) void {
    while (sdl3.events.poll()) |raw| {
        sample.polled += 1;
        switch (raw) {
            .window_mouse_enter => |event| {
                if (event.id == id) {
                    sample.delivered += 1;
                    sample.enter += 1;
                } else sample.other_window += 1;
            },
            .window_mouse_leave => |event| {
                // A leave is counted on its own and never as delivery: the
                // pointer leaving the surface is the opposite of the surface
                // accepting input, and folding the two together would let a
                // click-through and a bounded region look the same.
                if (event.id == id) sample.left += 1 else sample.other_window += 1;
            },
            .mouse_motion => |event| {
                if (event.window_id) |target| {
                    if (target == id) {
                        sample.delivered += 1;
                        sample.motion += 1;
                    } else sample.other_window += 1;
                }
            },
            .mouse_button_down, .mouse_button_up => |event| {
                if (event.window_id) |target| {
                    if (target == id) {
                        sample.delivered += 1;
                        sample.button += 1;
                    } else sample.other_window += 1;
                }
            },
            else => {},
        }
    }
}

/// One pump that counts what the layer surface was delivered before the host's
/// own event step consumes the rest of the queue.
///
/// The shared `wl_display` is pumped, then SDL's own queue is drained straight
/// into the counters. The host's own event step is deliberately not run here:
/// that step polls the very same queue, so a pointer event for this surface
/// would be taken by the loop that has no window for it and would never reach
/// these counters. Nothing else needs servicing inside a bounded observation
/// window, and the panel's own buffer was committed before the window opened.
fn pumpAndCount(
    control: *ToplevelControl,
    api: WaylandApi,
    id: sdl3.video.WindowId,
    sample: *PointerSample,
) void {
    if (control.display) |display| _ = api.display_dispatch_pending(display);
    sdl3.events.pump();
    countLayerPointer(id, sample);
}

/// The three regions the live arm puts on the wire, in the order the protocol
/// makes them distinguishable from one another.
const RegionStep = enum {
    /// An empty `wl_region`. A null `wl_region` means "accept input
    /// everywhere", so click-through is a region that exists and carries no
    /// rectangle: never the absence of a request.
    click_through,
    /// One rectangle in the middle of the panel. This is the only one of the
    /// three that can tell "some of it accepts input" from "all of it" and from
    /// "none of it".
    bounded,
    /// The compositor's infinite default again, restored by the explicit null
    /// request that a region already on the wire never replaces on its own.
    restored,

    fn label(self: RegionStep) []const u8 {
        return switch (self) {
            .click_through => "click-through",
            .bounded => "bounded",
            .restored => "restored",
        };
    }

    fn mode(self: RegionStep) machine_state.InputRegionMode {
        return switch (self) {
            .click_through => .passthrough,
            .bounded => .rects,
            .restored => .inherit,
        };
    }
};

/// The rectangle the bounded step uses, and the two points every step is
/// observed from.
///
/// Both points are in the panel's own surface-local pixels, which is the space
/// a `wl_region` rectangle lives in. `accept` is inside the bounded rectangle
/// and `outside` is not, and the same two points are probed during all three
/// steps, so the only thing that differs between those windows is the region
/// the compositor hit-tests against.
const RegionProbe = struct {
    surface: [2]i32 = .{ 0, 0 },
    accept: [2]i32 = .{ 0, 0 },
    outside: [2]i32 = .{ 0, 0 },
    rect: machine_state.InputRect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
};

/// Derive the probe points from the surface the compositor configured. The
/// surface is read, not assumed: a panel with no pixels has no region a
/// compositor could hit-test, and this refuses rather than reporting one.
fn regionProbe(window: *sdl3.video.Window) !RegionProbe {
    const pixels = try window.getSizeInPixels();
    if (pixels[0] == 0 or pixels[1] == 0) return error.EmptyPanelSurface;
    const w: i32 = @intCast(pixels[0]);
    const h: i32 = @intCast(pixels[1]);
    const rect_w = @max(1, @divTrunc(w, 4));
    const rect_h = @max(1, @divTrunc(h, 2));
    return .{
        .surface = .{ w, h },
        .accept = .{ @divTrunc(w, 2), @divTrunc(h, 2) },
        .outside = .{ @max(1, @divTrunc(w, 8)), @max(1, @divTrunc(h, 8)) },
        .rect = .{
            .x = @divTrunc(w - rect_w, 2),
            .y = @divTrunc(h - rect_h, 2),
            .width = @intCast(rect_w),
            .height = @intCast(rect_h),
        },
    };
}

/// Whether a surface-local point falls inside a region rectangle, using the
/// half-open box a `wl_region` hit-test uses. The arithmetic is widened so a
/// rectangle near the edge of the panel cannot wrap the comparison.
fn regionContains(rect: machine_state.InputRect, point: [2]i32) bool {
    const x: i64 = point[0];
    const y: i64 = point[1];
    const left: i64 = rect.x;
    const top: i64 = rect.y;
    return x >= left and x < left + @as(i64, rect.width) and
        y >= top and y < top + @as(i64, rect.height);
}

/// Whether the rectangle on the wire is the one this run asked for, read from
/// the plan rather than from the request that produced it.
fn regionMatches(got: machine_state.InputRect, want: machine_state.InputRect) bool {
    return got.x == want.x and got.y == want.y and
        got.width == want.width and got.height == want.height;
}

/// One step's own record: what was asked for, what the adapter recorded, and
/// what this process was delivered while the step was live.
const RegionReport = struct {
    accepted: bool = false,
    refusal: ?[]const u8 = null,
    recorded: machine_state.InputRegionMode = .inherit,
    recorded_rects: u32 = 0,
    send_region: bool = false,
    committed: u32 = 0,
    reconfigured: bool = false,
    sample: PointerSample = .{},
};

/// One pointer observation window on the owned layer surface.
///
/// The samples are printed so that a reader which aims a pointer of its own can
/// bracket its own request between two of them and read what this surface was
/// delivered in between. The window ends on its bound, never on the first
/// event, so a surface that is delivered nothing is reported as a complete
/// window with nothing in it.
fn watchLayerPointer(
    io: Io,
    run: *LayerRun,
    control: *ToplevelControl,
    report: *Reporter,
    api: WaylandApi,
    scope: []const u8,
    step: []const u8,
    step_ms: u64,
) !PointerSample {
    const id = try run.window.getId();
    var sample: PointerSample = .{};
    const started = sdl3.timer.getMillisecondsSinceInit();
    const deadline = started + step_ms;
    var printed: u32 = 0;
    var next_print = started;
    while (sdl3.timer.getMillisecondsSinceInit() < deadline) {
        pumpAndCount(control, api, id, &sample);
        const now = sdl3.timer.getMillisecondsSinceInit();
        if (now >= next_print and printed < pointer_sample_limit) {
            printed += 1;
            next_print = now + pointer_sample_ms;
            try report.emit(
                "pointer sample: scope=\"{s}\" step=\"{s}\" elapsed_ms={d} delivered={d}" ++
                    " enter={d} motion={d} button={d} left={d} other_window={d} polled={d}\n",
                .{
                    scope,
                    step,
                    now - started,
                    sample.delivered,
                    sample.enter,
                    sample.motion,
                    sample.button,
                    sample.left,
                    sample.other_window,
                    sample.polled,
                },
            );
        }
        try Io.sleep(io, Io.Duration.fromMilliseconds(poll_ms), .real);
    }
    return sample;
}

/// Answer a configure that one arm's own request may have provoked.
///
/// A surface that is sitting on an unacknowledged configure refuses every later
/// commit, so an arm cannot end on one: a configure that arrives is
/// acknowledged and given a new buffer, and one that does not is reported as
/// not arriving rather than waited for.
fn settleArmConfigure(
    io: Io,
    run: *LayerRun,
    control: *ToplevelControl,
    report: *Reporter,
    api: WaylandApi,
) !bool {
    const layer = run.layer;
    const configured_before = layer.machine.configured_count;
    const deadline = sdl3.timer.getMillisecondsSinceInit() + arm_settle_ms;
    while (layer.machine.configured_count == configured_before and
        sdl3.timer.getMillisecondsSinceInit() < deadline)
    {
        _ = try control.pump(api);
        try Io.sleep(io, Io.Duration.fromMilliseconds(poll_ms), .real);
    }
    if (layer.machine.configured_count == configured_before) return false;
    try layer.ackLatestConfigure();
    try presentConfigured(layer, run.window, &run.content, report);
    return true;
}

/// Put one live input region on this surface and report every part of it.
///
/// The request, the commit that carries it and the observation window are kept
/// apart on purpose: a request that never reached the compositor, a request the
/// compositor took and a window it delivered nothing into are three different
/// outcomes, and only one of them is an input region in effect.
fn runRegionStep(
    io: Io,
    verdict: *Verdict,
    run: *LayerRun,
    control: *ToplevelControl,
    report: *Reporter,
    api: WaylandApi,
    step: RegionStep,
    region: machine_state.InputRegion,
    probe: RegionProbe,
    step_ms: u64,
) !RegionReport {
    const layer = run.layer;
    const wire = WireText.of(run.wire_surface);
    var outcome: RegionReport = .{};
    if (layer.setInputRegion(region)) |_| {
        outcome.accepted = true;
    } else |err| {
        // A finished role has no second answer to give and a refused request
        // leaves the recorded region describing what the compositor actually
        // has, so the step is reported by name instead of being counted.
        outcome.refusal = @errorName(err);
        verdict.require(false, error.InputRegionStepRefused);
    }
    const plan = layer.machine.inputRegionPlan();
    outcome.recorded = layer.machine.options.input_region.mode;
    outcome.recorded_rects = layer.machine.options.input_region.count;
    outcome.send_region = plan.send_region;
    // The plan is a view of the recorded region rather than a copy of it, so
    // what it reports is what the request just carried. The bounded step is
    // held to the exact rectangle this run intended, the two empty steps to
    // carrying none, and every step to the send-or-not choice the protocol
    // makes: a plan that read anything else would leave all three windows
    // measuring the same thing and reporting it as an observation.
    const expected_rects: usize = if (step == .bounded) 1 else 0;
    const rects_exact = plan.rects.len == expected_rects and
        (step != .bounded or regionMatches(plan.rects[0], probe.rect));
    verdict.require(outcome.recorded == step.mode(), error.InputRegionModeMismatch);
    verdict.require(
        plan.send_region == (step.mode() != .inherit),
        error.InputRegionSendFlagMismatch,
    );
    verdict.require(rects_exact, error.InputRegionRectMismatch);
    try report.emit(
        "input region request: step=\"{s}\" requested={s} recorded={s}" ++
            " recorded_rects={d} send_region={d} rects_on_the_wire={d}" ++
            " exact={} surface={s} outcome={s}\n",
        .{
            step.label(),
            @tagName(step.mode()),
            @tagName(outcome.recorded),
            outcome.recorded_rects,
            @intFromBool(outcome.send_region),
            plan.rects.len,
            rects_exact,
            wire.slice(),
            if (outcome.refusal) |name| name else "<accepted>",
        },
    );
    if (step == .bounded) {
        try report.emit(
            "input region rectangle: step=\"{s}\" intended={d},{d} {d}x{d}" ++
                " accepted_inside={} outside_inside={}\n",
            .{
                step.label(),
                probe.rect.x,
                probe.rect.y,
                probe.rect.width,
                probe.rect.height,
                regionContains(probe.rect, probe.accept),
                regionContains(probe.rect, probe.outside),
            },
        );
    }
    if (!outcome.accepted) return outcome;
    // A configure that arrived while the previous window was open has to be
    // answered before this step can commit at all, so the drain comes first.
    const drained = try settleArmConfigure(io, run, control, report, api);
    // `set_input_region` is pending state, so the commit below is what puts it
    // in effect. The panel keeps a real buffer on screen across the commit,
    // which is why the content and its window are still alive here.
    presentConfigured(layer, run.window, &run.content, report) catch |err| {
        try report.emit(
            "input region commit: step=\"{s}\" outcome={s}\n",
            .{ step.label(), @errorName(err) },
        );
        verdict.require(false, error.InputRegionCommitRefused);
        return outcome;
    };
    outcome.committed = layer.machine.committed_count;
    outcome.reconfigured = try settleArmConfigure(io, run, control, report, api);
    try report.emit(
        "input region commit: step=\"{s}\" configure_drained={} committed_count={d}" ++
            " new_configure={} state={s} surface={s}\n",
        .{
            step.label(),
            drained,
            outcome.committed,
            outcome.reconfigured,
            @tagName(layer.machine.state),
            wire.slice(),
        },
    );

    try report.emit(
        "INPUT-REGION-STEP-READY step=\"{s}\" bound_ms={d} surface={s}" ++
            " surface_pixels={d}x{d} accept={d},{d} outside={d},{d}" ++
            " committed_count={d} state={s}\n",
        .{
            step.label(),
            step_ms,
            wire.slice(),
            probe.surface[0],
            probe.surface[1],
            probe.accept[0],
            probe.accept[1],
            probe.outside[0],
            probe.outside[1],
            outcome.committed,
            @tagName(layer.machine.state),
        },
    );
    outcome.sample = try watchLayerPointer(
        io,
        run,
        control,
        report,
        api,
        "input-region",
        step.label(),
        step_ms,
    );
    try report.emit(
        "input region step: step=\"{s}\" bound_ms={d} outcome={s} recorded={s}" ++
            " recorded_rects={d} send_region={d} delivered={d} enter={d} motion={d}" ++
            " button={d} left={d} other_window={d} polled={d} committed_count={d} state={s}\n",
        .{
            step.label(),
            step_ms,
            "<accepted>",
            @tagName(outcome.recorded),
            outcome.recorded_rects,
            @intFromBool(outcome.send_region),
            outcome.sample.delivered,
            outcome.sample.enter,
            outcome.sample.motion,
            outcome.sample.button,
            outcome.sample.left,
            outcome.sample.other_window,
            outcome.sample.polled,
            outcome.committed,
            @tagName(layer.machine.state),
        },
    );
    return outcome;
}

/// Drive the three live input regions on this layer surface, and report each
/// one separately.
///
/// The run owns what it can own here: the request, the commit that carries it
/// and the buffer underneath it are all this process's, so a step that cannot
/// be delivered fails the run instead of being reported as an observation. What
/// it does not own is the pointer: `delivered` is what the compositor chose to
/// send this surface, and a window that saw nothing says so.
fn runInputRegionArm(
    io: Io,
    verdict: *Verdict,
    run: *LayerRun,
    control: *ToplevelControl,
    report: *Reporter,
    api: WaylandApi,
    step_ms: u64,
) !void {
    const probe = try regionProbe(run.window);
    // The two probe points only mean something if one is inside the rectangle
    // the bounded step sets and the other is outside it. A panel too small to
    // tell them apart would make all three windows report the same thing, so
    // that is refused here instead of being read as an observation.
    verdict.require(regionContains(probe.rect, probe.accept), error.RegionProbeInsideFailed);
    verdict.require(!regionContains(probe.rect, probe.outside), error.RegionProbeOutsideFailed);
    const wire = WireText.of(run.wire_surface);
    try report.emit(
        "INPUT-REGION-READY bound_ms={d} steps=3 surface={s} surface_pixels={d}x{d}" ++
            " rect_origin={d},{d} rect_size={d}x{d} accept={d},{d} outside={d},{d} state={s}\n",
        .{
            step_ms,
            wire.slice(),
            probe.surface[0],
            probe.surface[1],
            probe.rect.x,
            probe.rect.y,
            probe.rect.width,
            probe.rect.height,
            probe.accept[0],
            probe.accept[1],
            probe.outside[0],
            probe.outside[1],
            @tagName(run.layer.machine.state),
        },
    );
    try report.emit(
        "input region probe: accept and outside are this panel's own surface-local" ++
            " pixels and both are probed at every step, so only the region differs\n",
        .{},
    );

    var empty: machine_state.InputRegion = .{};
    empty.setPassthrough();
    var bounded: machine_state.InputRegion = .{};
    bounded.addRect(probe.rect);
    var restored: machine_state.InputRegion = .{};
    restored.inherit();

    const reports = [_]RegionReport{
        try runRegionStep(io, verdict, run, control, report, api, .click_through, empty, probe, step_ms),
        try runRegionStep(io, verdict, run, control, report, api, .bounded, bounded, probe, step_ms),
        try runRegionStep(io, verdict, run, control, report, api, .restored, restored, probe, step_ms),
    };

    var accepted: u32 = 0;
    for (reports) |step| {
        if (step.accepted) accepted += 1;
    }
    try report.emit(
        "input region source: send_region, recorded and recorded_rects are this" ++
            " process's own options; delivered counts only events whose window is" ++
            " this layer's own roleless surface, and no pointer event is synthesized\n",
        .{},
    );
    try report.emit(
        "INPUT-REGION-VERDICT steps=3 accepted={d} refused={d} click_through_delivered={d}" ++
            " bounded_delivered={d} restored_delivered={d} surface={s} state={s}\n",
        .{
            accepted,
            3 - accepted,
            reports[0].sample.delivered,
            reports[1].sample.delivered,
            reports[2].sample.delivered,
            wire.slice(),
            @tagName(run.layer.machine.state),
        },
    );
    verdict.require(accepted == 3, error.InputRegionStepRefused);
}

/// The interactivity values the keyboard arm drives, in order.
const KeyboardStep = enum {
    none,
    on_demand,
    none_again,

    fn label(self: KeyboardStep) []const u8 {
        return switch (self) {
            .none => "none",
            .on_demand => "on-demand",
            .none_again => "none-again",
        };
    }

    fn value(self: KeyboardStep) real.KeyboardInteractivity {
        return switch (self) {
            .none, .none_again => .none,
            .on_demand => .on_demand,
        };
    }
};

/// Drive `none`, `on-demand`, `none` on this surface, and report each one by
/// name with its own readiness point.
///
/// `zwlr_layer_surface_v1.set_keyboard_interactivity` is double-buffered state:
/// the compositor applies it at the next `wl_surface.commit`, so a request that
/// is marshalled and never committed changes nothing the compositor acts on.
/// Each step therefore commits the request like the input-region steps do, and
/// the commit count this process read back is its own witness that the request
/// was carried. What the compositor then does with it is not in this line: no
/// request reads keyboard interactivity back, so a compositor that grants
/// nothing is read from outside, and the printed value is what such a reader
/// compares against.
///
/// `on_demand` arrived in layer-shell version 4, and the adapter refuses it by
/// name below that rather than substituting something else. No step here takes
/// the keyboard: `exclusive` is never requested, no seat serial is invented,
/// and a compositor that grabs the keyboard for this surface is a
/// display-server decision this run does not provoke.
fn runKeyboardArm(
    io: Io,
    verdict: *Verdict,
    run: *LayerRun,
    control: *ToplevelControl,
    report: *Reporter,
    api: WaylandApi,
    step_ms: u64,
) !void {
    const layer = run.layer;
    const wire = WireText.of(run.wire_surface);
    try report.emit(
        "KEYBOARD-ARM-READY bound_ms={d} steps=3 surface={s} shell_version={d}" ++
            " initial={s} on_demand_min_version=4 state={s}\n",
        .{
            step_ms,
            wire.slice(),
            run.shell_version,
            @tagName(layer.machine.options.keyboard_interactivity),
            @tagName(layer.machine.state),
        },
    );
    try report.emit(
        "keyboard interactivity source: recorded and marshalled are this process's" ++
            " own values; the compositor's account of this surface's keyboard" ++
            " interactivity is read by the driver, and no step here takes the keyboard\n",
        .{},
    );

    const order = [_]KeyboardStep{ .none, .on_demand, .none_again };
    var accepted: u32 = 0;
    var committed: u32 = 0;
    for (order) |step| {
        const marshalled: u32 = @backingInt(step.value());
        const before_commit = layer.machine.committed_count;
        const refusal: ?[]const u8 = if (layer.setKeyboardInteractivity(step.value())) |_|
            null
        else |err|
            @errorName(err);
        if (refusal != null) {
            verdict.require(false, error.KeyboardArmStepRefused);
        } else {
            accepted += 1;
        }
        const recorded = layer.machine.options.keyboard_interactivity;
        try report.emit(
            "keyboard interactivity request: step=\"{s}\" requested={s} recorded={s}" ++
                " marshalled={d} surface={s} outcome={s}\n",
            .{
                step.label(),
                @tagName(step.value()),
                @tagName(recorded),
                marshalled,
                wire.slice(),
                refusal orelse "<accepted>",
            },
        );
        if (refusal != null) continue;
        // A configure that arrived while the previous window was open has to be
        // answered before this step can commit at all, so the drain comes first.
        const drained = try settleArmConfigure(io, run, control, report, api);
        // This commit is the request's own half: it is what carries the
        // double-buffered interactivity to the compositor, and a step that
        // cannot commit is reported as one rather than counted as accepted.
        presentConfigured(layer, run.window, &run.content, report) catch |err| {
            try report.emit(
                "keyboard interactivity commit: step=\"{s}\" outcome={s}\n",
                .{ step.label(), @errorName(err) },
            );
            verdict.require(false, error.KeyboardArmCommitRefused);
            continue;
        };
        const reconfigured = try settleArmConfigure(io, run, control, report, api);
        const committed_count = layer.machine.committed_count;
        const carried = committed_count > before_commit;
        if (carried) committed += 1;
        verdict.require(carried, error.KeyboardArmStepNotCommitted);
        try report.emit(
            "keyboard interactivity commit: step=\"{s}\" configure_drained={}" ++
                " committed_count={d} carried={} new_configure={} state={s}\n",
            .{
                step.label(),
                drained,
                committed_count,
                carried,
                reconfigured,
                @tagName(layer.machine.state),
            },
        );
        try report.emit(
            "KEYBOARD-STEP-READY step=\"{s}\" bound_ms={d} surface={s} requested={s}" ++
                " recorded={s} marshalled={d} committed_count={d} configure_drained={}" ++
                " new_configure={} state={s}\n",
            .{
                step.label(),
                step_ms,
                wire.slice(),
                @tagName(step.value()),
                @tagName(recorded),
                marshalled,
                committed_count,
                drained,
                reconfigured,
                @tagName(layer.machine.state),
            },
        );
        const sample = try watchLayerPointer(
            io,
            run,
            control,
            report,
            api,
            "keyboard",
            step.label(),
            step_ms,
        );
        try report.emit(
            "keyboard interactivity step: step=\"{s}\" bound_ms={d} outcome={s}" ++
                " requested={s} recorded={s} marshalled={d} committed_count={d}" ++
                " new_configure={} delivered={d} state={s}\n",
            .{
                step.label(),
                step_ms,
                "<accepted>",
                @tagName(step.value()),
                @tagName(recorded),
                marshalled,
                committed_count,
                reconfigured,
                sample.delivered,
                @tagName(layer.machine.state),
            },
        );
    }
    try report.emit(
        "KEYBOARD-ARM-VERDICT steps=3 accepted={d} refused={d} committed={d}" ++
            " sequence=none,on-demand,none shell_version={d} surface={s} state={s}\n",
        .{
            accepted,
            3 - accepted,
            committed,
            run.shell_version,
            wire.slice(),
            @tagName(layer.machine.state),
        },
    );
    verdict.require(accepted == 3, error.KeyboardArmStepRefused);
    verdict.require(committed == 3, error.KeyboardArmStepNotCommitted);
}

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var options: Options = .{};
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    _ = args_it.next();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--hold-ms")) {
            const value = args_it.next() orelse return error.MissingHoldMs;
            options.hold_ms = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--output-watch-ms")) {
            const value = args_it.next() orelse return error.MissingOutputWatchMs;
            options.output_watch_ms = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--input-region-ms")) {
            const value = args_it.next() orelse return error.MissingInputRegionMs;
            options.input_region_ms = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--keyboard-arm-ms")) {
            const value = args_it.next() orelse return error.MissingKeyboardArmMs;
            options.keyboard_arm_ms = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--terminal-arm-ms")) {
            const value = args_it.next() orelse return error.MissingTerminalArmMs;
            options.terminal_arm_ms = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--terminal-expect")) {
            const value = args_it.next() orelse return error.MissingTerminalExpect;
            options.terminal_expect = TerminalEvent.parse(value) orelse {
                std.log.err(
                    "--terminal-expect is one of closed, output-removed; got {s}",
                    .{value},
                );
                return error.UnknownTerminalExpect;
            };
        } else if (std.mem.eql(u8, arg, "--native")) {
            // Opt-in because it is the only path that reaches a display server
            // at all: it leaves the video driver hint alone, so the requested
            // environment — this session's own compositor — decides.
            options.native = true;
        } else if (std.mem.eql(u8, arg, "--verify-reservation")) {
            options.verify_reservation = true;
        } else if (std.mem.eql(u8, arg, "--verify-output")) {
            options.verify_output = true;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }
    // A requested measurement that no window could satisfy would be a run that
    // reports a limitation as a result, so it is refused before SDL starts
    // rather than answered after.
    if (!options.native and
        (options.verify_reservation or options.verify_output or options.output_watch_ms > 0 or
            options.input_region_ms > 0 or options.keyboard_arm_ms > 0 or options.terminal_arm_ms > 0))
    {
        std.log.err(
            "a reservation, output, live-arm or terminal measurement needs --native: without it" ++
                " this run opens no window and reaches no compositor",
            .{},
        );
        return error.VerificationNeedsNative;
    }

    // The arm and the end it waits for name one measurement. An arm with no end
    // named is a run that waits for something it never said it wanted, and an end
    // with no arm is a run that never looks for it, so either half alone is
    // refused here rather than answered after.
    if ((options.terminal_arm_ms > 0) != (options.terminal_expect != .none)) {
        std.log.err(
            "--terminal-arm-ms and --terminal-expect name one measurement: give both or neither",
            .{},
        );
        return error.TerminalArmIncomplete;
    }

    var report: Reporter = .{ .io = io };
    try report.emit("W22 Wayland layer-shell smoke\n", .{});

    // The CPU framebuffer policy is set here, before SDL video is initialized
    // and therefore before any window in this process exists.
    //
    // `SDL_FRAMEBUFFER_ACCELERATION` decides what sits UNDER the software
    // renderer, not what the renderer is: `SW_CreateRenderer` always asks the
    // video backend for the window's framebuffer surface, and with
    // acceleration left on that surface is a 3D-accelerated texture on a
    // renderer SDL builds by itself (`SDL_CreateWindowTexture`, gated by
    // `ShouldAttemptTextureFramebuffer`). Naming `vulkan` here put an NVIDIA
    // Vulkan renderer under every window in this run, and destroying the
    // software renderer tore it down through `SW_DestroyRenderer` ->
    // `SDL_DestroyWindowSurface` -> `SDL_DestroyWindowTexture` ->
    // `SDL_DestroyRenderer_REAL` -> `VULKAN_DestroyRenderer` ->
    // `VULKAN_DestroyAll`, where the driver called through a null entry point
    // and the process died at address 0 before one wire request could be sent.
    //
    // "0" is the one value that makes SDL build no accelerated framebuffer at
    // all, so what this run draws into is a CPU buffer it owns and what it
    // destroys on the way out is that buffer and nothing else.
    //
    // `override`, not the default priority, because this has to be a policy
    // rather than a preference: at `normal` an inherited `SDL_FRAMEBUFFER_
    // ACCELERATION` from the environment, or anything else that writes the
    // hint later, could put an accelerated framebuffer back under a window
    // and the crash would return with it. Nothing in this binary writes the
    // hint again — this is the only setter — and nothing resets it before the
    // last renderer is destroyed: `application.deinit` and `session.deinit`
    // are the ordered shutdown at the end of this function, and every
    // `SDL_DestroyRenderer` this run makes happens inside `retireLayerRun`
    // before them. So the policy is in force from before the first window
    // exists until after the last renderer is gone.
    try sdl3.hints.setWithPriority(.framebuffer_acceleration, "0", .override);

    // The host owns SDL: it is initialized here so the layer surface and the
    // toplevel control share one display connection.
    var session = try nogui.Session.init(gpa);
    var session_live = true;
    defer if (session_live) session.deinit() catch
        @panic("W22 layer smoke error path left the Session live");
    var application = try host.Application.init(gpa, &session, .{
        .app_id = "dev.nogui.w22layersmoke",
        .restart = .never,
        // The driver is chosen BEFORE SDL video is initialized, and that is
        // what makes the default safe: without `--native` the host is told to
        // take the windowless driver, so a run on a machine with a desktop
        // session never reaches the user's display server and never opens a
        // window.
        .video_driver = if (options.native) null else "dummy",
    });
    var application_live = true;
    defer if (application_live) application.deinit();

    var dyn: DynLoader = .{};
    var api = try WaylandApi.load(dyn.loader());
    defer api.deinit();
    try report.emit("libwayland-client: soname={s}\n", .{dyn.soname});

    // One device for both windows in this run: the layer bar and the probe
    // toplevel present through surfaces made on it, so the driver, the
    // instance and the loader are opened once and shared.
    //
    // It is opened here, after SDL video is up and before any window exists:
    // `SDL_Vulkan_CreateSurface` needs the library loaded, and it is what noapi
    // hands to the platform.
    //
    // Only `--native` opens one. Without it the host was told to take the
    // windowless driver, that driver opens no window and reaches no compositor,
    // and no surface is ever asked for — so a machine with no GPU at all still
    // runs this binary. With `--native` a device that will not open is the
    // run's own error and is propagated unchanged.
    var gpu: ?noapi.Gpu = null;
    if (options.native) gpu = try openDevice(gpa, io, "w22-layer-shell-smoke");
    var gpu_live = gpu != null;
    // Registered after the Application's own defer, so on an error return this
    // runs BEFORE the host quits SDL. That order is not cosmetic: quitting SDL
    // unloads the Vulkan loader, and a device still alive would dispatch
    // through an unmapped page.
    defer if (gpu_live) gpu.?.deinit();
    const device: ?*noapi.Gpu = if (gpu_live) &gpu.? else null;
    if (gpu_live) try report.emit("native device: opened, shared by both windows\n", .{});

    // The layer surface is closed last: its teardown is the request the
    // compositor answers, and everything the run still needs — the hold, the
    // reserved extent and the output watch — happens while it is up, with the
    // ordinary toplevel up beside it.
    const run = try driveLayerSurface(gpa, &report, api, &dyn, device);
    // A live run owns a window, a GPU surface and a real role from here on, so
    // every error return before the ordered shutdown below has to retire it
    // instead of leaving it up behind the failure. Retiring frees the run even
    // when it reports a failure, so the flag is what says the run still owns
    // something: the ordered shutdown clears it before it can propagate, and
    // no path reaches this one twice with the same run.
    var run_live = run != null;
    errdefer if (run_live) retireLayerRun(run.?, &report) catch
        @panic("W22 layer smoke error path retired the live layer run into a failure");
    if (run == null) {
        try report.emit(
            "layer-shell verdict: not advertised, explicit unavailable path reported\n",
            .{},
        );
    }
    const needs_layer = options.verify_reservation or options.verify_output or
        options.output_watch_ms > 0 or options.input_region_ms > 0 or
        options.keyboard_arm_ms > 0 or options.terminal_arm_ms > 0;
    if (run == null and needs_layer) {
        try report.emit(
            "layer-shell verdict: no layer surface, so no reservation, output event," ++
                " live-arm step or terminal ending can be measured; the requested verification" ++
                " cannot run\n",
            .{},
        );
        return error.VerificationNeedsLayerSurface;
    }

    // The ordinary path, and the source of the reserved extent. It is opened
    // before the layer surface changes anything, so the measurement has a
    // baseline, and it stays up through the hold and the watch.
    var verdict: Verdict = .{};
    var control = try ToplevelControl.open(gpa, io, &report, &application, api, &dyn, device);
    // The probe toplevel is the other half that holds native resources, and it
    // is released before the layer run above so the two windows come down in
    // the order they were opened.
    var control_live = true;
    errdefer if (control_live) control.close(&report) catch
        @panic("W22 layer smoke error path left the probe toplevel open");
    if (run) |layer_run| {
        try measureReservation(io, &verdict, &control, layer_run, &report, api, options);
        try reportSurfaceState(&report, layer_run, "after reservation");
        try reportWireIds(&report, layer_run, &control);
        if (options.input_region_ms > 0) {
            try runInputRegionArm(
                io,
                &verdict,
                layer_run,
                &control,
                &report,
                api,
                options.input_region_ms,
            );
            try reportSurfaceState(&report, layer_run, "after input region arm");
        }
        if (options.keyboard_arm_ms > 0) {
            try runKeyboardArm(
                io,
                &verdict,
                layer_run,
                &control,
                &report,
                api,
                options.keyboard_arm_ms,
            );
            try reportSurfaceState(&report, layer_run, "after keyboard arm");
        }
        try holdOpen(io, layer_run, &control, &report, api, options.hold_ms);
        if (options.hold_ms > 0) try reportSurfaceState(&report, layer_run, "after hold");
        if (options.output_watch_ms > 0) {
            const before = try control.settle(io, &report, api, "before output watch");
            try watchOutput(io, &verdict, layer_run, &control, before, &report, api, options);
            if (options.terminal_arm_ms > 0) {
                // The probe window is measured against an output, and this run
                // was asked to watch the role end. There may be no output left to
                // measure the probe against once the arm is over, so the "after"
                // probe is not taken — and says so here rather than leaving the
                // measurement quietly out of the report.
                try report.emit(
                    "output watch effect: not measured, because this run was asked to watch the" ++
                        " role end and the probe is measured against the output it ended on;" ++
                        " see `terminal arm verdict:`\n",
                    .{},
                );
            } else {
                const after = try control.settle(io, &report, api, "after output watch");
                try report.emit(
                    "output watch effect: probe_logical={d}x{d}->{d}x{d}" ++
                        " probe_pixels={d}x{d}->{d}x{d} device_scale={d:.3}->{d:.3}" ++
                        " device_height_delta={d} logical_height_delta={d}\n",
                    .{
                        before.logical[0],
                        before.logical[1],
                        after.logical[0],
                        after.logical[1],
                        before.pixels[0],
                        before.pixels[1],
                        after.pixels[0],
                        after.pixels[1],
                        before.device_scale,
                        after.device_scale,
                        @as(i64, after.pixels[1]) - @as(i64, before.pixels[1]),
                        @as(i64, after.logical[1]) - @as(i64, before.logical[1]),
                    },
                );
                try reportSurfaceState(&report, layer_run, "after output watch");
            }
        }
        // The terminal arm is last: everything the run measures against a live
        // output — the reservation, the input regions, the keyboard steps, the
        // hold, the output watch — happens before it, because a role the
        // compositor has ended is a role none of those can be measured on.
        if (options.terminal_arm_ms > 0) {
            try runTerminalArm(io, &verdict, layer_run, &control, &report, api, options);
            try reportSurfaceState(&report, layer_run, "after terminal arm");
        }
        try report.emit("layer-shell verdict: advertised and driven on this connection\n", .{});
        try control.close(&report);
        control_live = false;
        try closeMachine(&report, layer_run.layer);
        // Ownership of the run ends at the retirement call, not at its result:
        // the run releases its GPU surface, window, role and own storage
        // whether or not it reports a failure, so the flag is cleared before
        // that failure is allowed to propagate. Otherwise the `errdefer` above
        // would reach this same run a second time and release an
        // already-released surface, which is a crash rather than a failed run.
        const run_retired = retireLayerRun(layer_run, &report);
        run_live = false;
        try run_retired;
    } else {
        try control.close(&report);
        control_live = false;
    }

    // The device goes next, and it is the outermost owner left. Both GPU
    // surfaces are already gone: the probe's in `control.close` above, the
    // layer bar's in `retireLayerRun`. A device that outlived SDL would
    // dispatch through an unmapped Vulkan loader, and one that still carried a
    // surface would have outlived the window that surface was made from.
    if (gpu_live) {
        gpu.?.deinit();
        gpu_live = false;
        try report.emit("native device: released\n", .{});
    }

    // Ordered shutdown: the host still owns the Session's task wake, so it goes
    // first and releases SDL with it.
    application.deinit();
    application_live = false;
    const released = session.deinit();
    session_live = false;
    try report.emit("shutdown: Application.deinit ok, Session.deinit={s}\n", .{
        outcomeText(void, released),
    });
    // A requested verification that could not be satisfied ends the run only
    // here: every observation above, including the close path, is printed
    // before the exit code says the run failed.
    if (verdict.failure) |failure| {
        try report.emit("run failed a requested verification: {s}\n", .{@errorName(failure)});
        return failure;
    }
    try report.emit("W22 Wayland layer-shell smoke done\n", .{});
}
