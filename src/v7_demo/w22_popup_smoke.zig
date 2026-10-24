//! W22 native popup smoke — one real OS popup surface on the display server
//! this process is actually connected to.
//!
//! The two display servers are driven differently, and the difference is the
//! point of the binary rather than a fallback:
//!
//!  * X11: `SDL_WINDOW_POPUP_MENU` is an override-redirect window, so the role
//!    exists when the window does and `show` is the whole mapping step.
//!  * Wayland: there is no such window to ask for, so the role is assigned on
//!    SDL's own display connection, in the order the protocol states — role,
//!    optional grab, initial commit, configure, acknowledgement, commit — and
//!    a compositor that will not take one is reported, never faked with a
//!    toplevel.
//!
//! Two modes, and the default opens nothing at all.
//!
//! Without `--native` the host is told to take SDL's windowless driver before
//! video is initialized. There is no display server behind that driver, so the
//! adapter refuses by name — `HeadlessDisplayServer` — and the run stops there
//! having opened no window, no device and no GPU surface. This is the default
//! so that a run on a machine with a desktop session never reaches that
//! session, and so that a headless machine gets the refusal rather than a
//! crash.
//!
//! With `--native` the driver hint is left alone, so the requested
//! environment decides: the session's own Wayland compositor, or a private X
//! server. The role is then driven for real and a real device-backed buffer is
//! attached to the popup's own surface and presented, because a popup with no
//! buffer cannot prove that anything was mapped. A display server or a device
//! that does not arrive ends the run non-zero, AFTER the role and configure
//! evidence has printed: the evidence stands, and the requested proof did not
//! happen.
//!
//!
//! A grab is a point of risk, so it is a separate opt-in: `--private-native-grab`
//! is the operator saying that this run may latch a REAL press on its own parent
//! window and hand that press's serial to the adapter, and `--private-grab-arm-ms`
//! is the bounded window each wait gets. Neither is implied by `--native`, and
//! the second is refused without the first, so the default run opens nothing,
//! grabs nothing and proves nothing it was not asked for. With the pair, the run
//! waits for the display server to deliver a real press, attaches the role,
//! grabs with that press, maps, presents, and then waits for the compositor's
//! OWN dismissal of a grabbed popup from a second real press outside it.
//!
//! Run it: `zig build w22-popup-smoke -- [--hold-ms 6000] [--native]` or, with
//! the operator's approval, `[--native --private-native-grab --private-grab-arm-ms 6000]`.
const std = @import("std");
const Io = std.Io;
const sdl3 = @import("sdl3");

const noapi = @import("noapi");

const nogui = @import("nogui");
const host = @import("nogui_host");

const popup_real = host.linux.popup_real;
const popup = host.linux.popup;
const wayland = host.linux.wayland;

// The host exports the Wayland protocol table, so these are named directly
// rather than recovered from the adapter's own signatures.
const WaylandApi = wayland.Api;
const WaylandLoader = wayland.Loader;
const WaylandObject = wayland.Object;

/// Values that belong to this scenario alone: a 480x360 parent and a 180x120
/// popup, so the resolved rectangle cannot be confused with a unit-test
/// fixture or with the layer-shell scenario's numbers.
const parent_title = "w22-popup-smoke-parent";
const parent_width: u32 = 480;
const parent_height: u32 = 360;
const popup_width: u32 = 180;
const popup_height: u32 = 120;
/// The token this run hands to `xdg_popup.reposition`, so the `repositioned`
/// event that comes back can be attributed to this request and not to
/// something else on the connection.
const reposition_token: u32 = 0x7717;

/// The button strip, as fractions of the parent's OWN observed size. A strip
/// in fixed pixels would land wherever the window manager put this window, and
/// on a display where the parent happens to sit well inside the work area the
/// popup would fit without the constraint solver doing anything at all, which
/// is the one outcome that proves nothing about the solver. A strip measured
/// from the parent cannot be placed like that.
const strip_width_divisor: u32 = 4;
const strip_height_divisor: u32 = 8;

/// Which vertical edge of the parent the strip is against. The two positions
/// this run asks for differ in this and in nothing else, so a compositor that
/// answers the reposition has to report a different rectangle, and the
/// difference can never be a size or a rounding.
const Strip = enum { right_edge, left_edge };

/// The strip, as a rectangle inside the parent's own window coordinates, near
/// its bottom edge.
fn deriveAnchorRect(parent: popup.Rect, strip: Strip) popup.Rect {
    const width: i32 = @intCast(@max(parent.width / strip_width_divisor, 1));
    const height: i32 = @intCast(@max(parent.height / strip_height_divisor, 1));
    return .{
        .x = switch (strip) {
            .left_edge => 0,
            .right_edge => @as(i32, @intCast(parent.width)) - width,
        },
        .y = @as(i32, @intCast(parent.height)) - height,
        .width = @intCast(width),
        .height = @intCast(height),
    };
}

/// The positioner this run asks for, derived from what the display server
/// reported about the parent and about the work area.
///
/// The offset is the whole point. The strip is measured from the parent, and
/// the popup is then asked for with its left edge exactly ON the work area's
/// right edge and its top edge one popup-height below the work area's bottom
/// edge. It therefore hangs off the work area by its own width on one axis and
/// by its own height on the other, and that request cannot be granted as it
/// stands: `resolvePlacement` has to bring the rectangle back onto the work
/// area, and whichever way it does that, one of `flipped_x`, `flipped_y`,
/// `slid_x`, `slid_y`, `resized_x` or `resized_y` is the branch that fired and
/// the run says which. A static offset that already fits leaves all six false.
///
/// Every number here comes out of the two reported rectangles: the slack
/// between the parent's own right and bottom edges and the work area's is the
/// work area talking, so the request lands on the work area corner from any
/// parent position at all. Which branch fires still depends on where the parent
/// is — with room to its left the popup flips, against the left edge of the
/// work area it slides — so no driver exercises the same branch by accident and
/// neither of them gets there by luck. Where the backend reported no global
/// position for the parent, the origin in `parent_bounds` is the one this run
/// supplied and the geometry line says so; the size, the strip and the work
/// area are real either way.
fn derivePositioner(parent: popup.Rect, work_area: popup.Rect, strip: Strip) popup.Positioner {
    const size: popup.Size = .{ .width = popup_width, .height = popup_height };
    const corner = switch (strip) {
        .left_edge => popup.Anchor.bottom_left,
        .right_edge => popup.Anchor.bottom_right,
    };
    return .{
        .anchor_rect = deriveAnchorRect(parent, strip),
        .anchor = corner,
        .gravity = switch (strip) {
            .left_edge => popup.Gravity.bottom_left,
            .right_edge => popup.Gravity.bottom_right,
        },
        .constraint_adjustment = popup.ConstraintAdjustment.all,
        .offset = .{
            .x = (work_area.right() - parent.right()) + @as(i32, @intCast(size.width)),
            .y = (work_area.bottom() - parent.bottom()) + @as(i32, @intCast(size.height)),
        },
        .size = size,
    };
}

/// The two requests this run makes, printed in full so the request the solver
/// answered, the request the create and refusal paths sent and the request the
/// reposition sent are visibly the same object and not three constants that
/// happen to agree today.
fn emitRequest(report: *Reporter, label: []const u8, requester: popup.Positioner) !void {
    try report.emit(
        "derived request: {s} anchor_rect={d},{d} {d}x{d} anchor={s} gravity={s}" ++
            " constraint_adjustment={d} offset={d},{d} size={d}x{d}\n",
        .{
            label,
            requester.anchor_rect.x,
            requester.anchor_rect.y,
            requester.anchor_rect.width,
            requester.anchor_rect.height,
            @tagName(requester.anchor),
            @tagName(requester.gravity),
            popup.constraintAdjustmentBits(requester.constraint_adjustment),
            requester.offset.x,
            requester.offset.y,
            requester.size.width,
            requester.size.height,
        },
    );
}

/// What the solver answered for one of those requests, with the two facts a
/// reader cannot recompute from the rectangle alone: whether the answer is
/// inside the work area, and whether a constraint branch is what put it there.
/// The answer is parent-relative, so containment is decided against the work
/// area with the parent's own origin taken off it — the two are in the same
/// frame only after that subtraction.
fn emitResolved(
    report: *Reporter,
    label: []const u8,
    resolved: popup.ResolvedPlacement,
    parent_bounds: popup.Rect,
    work_area: popup.Rect,
) !void {
    const left = work_area.x - parent_bounds.x;
    const top = work_area.y - parent_bounds.y;
    const width: i32 = @intCast(resolved.rect.width);
    const height: i32 = @intCast(resolved.rect.height);
    const inside = resolved.rect.x >= left and resolved.rect.y >= top and
        resolved.rect.x + width <= left + @as(i32, @intCast(work_area.width)) and
        resolved.rect.y + height <= top + @as(i32, @intCast(work_area.height));
    const constrained = resolved.flipped_x or resolved.flipped_y or
        resolved.slid_x or resolved.slid_y or
        resolved.resized_x or resolved.resized_y;
    try report.emit(
        "resolved: {s} rect={d},{d} {d}x{d} absolute={d},{d} {d}x{d}" ++
            " parent_relative_work_area={d},{d} {d}x{d} inside_work_area={}" ++
            " constrained={}\n",
        .{
            label,
            resolved.rect.x,
            resolved.rect.y,
            resolved.rect.width,
            resolved.rect.height,
            resolved.rect.x + parent_bounds.x,
            resolved.rect.y + parent_bounds.y,
            width,
            height,
            left,
            top,
            work_area.width,
            work_area.height,
            inside,
            constrained,
        },
    );
}

const Reporter = struct {
    io: Io,
    buffer: [4096]u8 = @splat(0),

    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.buffer, fmt, args);
        try Io.File.stdout().writeStreamingAll(self.io, text);
    }
};

/// An error union reports its error; a delivered success reports as itself.
fn outcomeText(comptime T: type, result: anyerror!T) []const u8 {
    if (result) |_| return "<accepted>" else |err| return @errorName(err);
}

/// A refusal the adapter must produce in so many words. A run that sees any
/// other outcome has proved the opposite of what this line claims, so it is an
/// error and not a printed observation.
fn expectRefusal(
    comptime T: type,
    comptime expected: []const u8,
    report: *Reporter,
    label: []const u8,
    result: anyerror!T,
) !void {
    const text = outcomeText(T, result);
    try report.emit("{s}: {s} (expected {s})\n", .{ label, text, expected });
    if (!std.mem.eql(u8, text, expected)) return error.UnexpectedPopupOutcome;
}

/// The request list a phase was built from, named the way its union fields are,
/// so the printed order is the order that reached the wire.
fn emitPlan(report: *Reporter, label: []const u8, plan: popup_real.Plan) !void {
    try report.emit("{s}: [", .{label});
    for (plan.slice(), 0..) |op, index| {
        if (index > 0) try report.emit(",", .{});
        try report.emit("{s}", .{@tagName(op)});
    }
    try report.emit("]\n", .{});
}

/// `std.DynLib` behind the adapter's loader contract. The smoke resolves
/// libwayland-client the way the tree resolves its other optional native
/// libraries, and the loader hands back the copy SDL already mapped, so the
/// popup is created on the very connection the parent window lives on.
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
    fn loadObject(context: *anyopaque, soname: [:0]const u8) anyerror!WaylandObject {
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

    fn unload(context: *anyopaque) void {
        const self: *DynLoader = @ptrCast(@alignCast(context));
        if (self.lib) |*lib| lib.close();
        self.lib = null;
    }
};

const Work = struct {
    io: Io,
    report: *Reporter,
    application: *host.Application,

    fn pump(self: *Work, rounds: u32) !void {
        var settled: u32 = 0;
        while (settled < rounds) : (settled += 1) {
            _ = try self.application.step();
            try Io.sleep(self.io, Io.Duration.fromMilliseconds(8), .real);
        }
    }

    /// Keep the parent and the popup up for an external capture. Rounds are
    /// not bounded by a round count: the hold is a wall-clock duration.
    fn hold(self: *Work, millis: u64) !void {
        const until = sdl3.timer.getMillisecondsSinceInit() + millis;
        while (sdl3.timer.getMillisecondsSinceInit() < until) {
            _ = try self.application.step();
            try Io.sleep(self.io, Io.Duration.fromMilliseconds(8), .real);
        }
    }
};

/// What the run was asked to do. Both driver arms take it, so a new switch does
/// not become another argument on each of them.
const Options = struct {
    hold_ms: u64 = 0,
    /// Drive the display server this run is actually connected to: open a
    /// window, create the popup role for real, and attach a device-backed
    /// buffer that is presented, because a popup with no buffer cannot prove
    /// anything was mapped. Without it the host takes SDL's windowless driver,
    /// the adapter refuses by name, and nothing at all is opened, so this smoke
    /// is safe to run anywhere by default. With it, the requested environment
    /// picks the driver and a missing device or display server ends the run
    /// non-zero rather than quietly reducing it.
    native: bool = false,
    /// The operator's explicit approval for the real native grab arm. False by
    /// default and never implied by `native`: a grab takes input away from
    /// every other client on the display server for as long as it holds, which
    /// is a world change and not an observation, so it is approved by name.
    private_grab: bool = false,
    /// The bounded window each wait in that arm gets: one for the real press
    /// that fills the grab's serial, one for the compositor's own dismissal.
    /// Zero means the arm did not run, and asking for a window without the
    /// approval is refused rather than ignored.
    private_grab_arm_ms: u64 = 0,
};

/// The instance extensions the device asked for. `Gpu.init` takes a plain
/// function, so the storage it reads has to outlive the call; the copy is
/// released as soon as init returns and this is emptied, so nothing is left
/// pointing at freed bytes.
var instance_extensions: [][*:0]const u8 = &.{};

fn currentInstanceExtensions() []const [*:0]const u8 {
    return instance_extensions;
}

/// Open a device through the public SDL loader, the same path every other
/// window in this tree takes: noapi asks SDL for the instance entry points and
/// for the extensions SDL's own backend needs, so the device and every surface
/// it makes are created on the one loader the session already has.
///
/// The caller owns the result and must destroy it BEFORE the host quits SDL:
/// quitting SDL unloads the Vulkan loader, and a live device would then
/// dispatch through an unmapped page.
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
    });
}

/// The device-backed surface a popup's content is presented through.
///
/// Ownership is the whole point of this type. The popup creates the platform
/// surface and hands over a noapi `Surface` that already owns it, on the
/// success path and the failure path alike, so this value holds no wrapper to
/// destroy and there is no second release to get wrong. What is left here is
/// device-side state, and it has to be released BEFORE the popup is, on every
/// path including an early return, because the popup's teardown destroys the
/// window, its proxies and any platform surface it still owns.
const Content = struct {
    surface: noapi.Surface,
    released: bool = false,

    /// What one presented frame actually did. The image is the swapchain's,
    /// which the driver is free to clamp, so it is reported next to the size
    /// that was asked for instead of replacing it.
    const Presented = struct {
        image: noapi.Extent2D,
        swapchain_recreated: bool,
        present_out_of_date: bool,
    };

    /// Ask the popup for a GPU surface on its own native window.
    ///
    /// The extent is the size the display server configured, not a measured
    /// window size: a hidden Wayland window has no size of its own to measure,
    /// and the compositor's answer is the one a buffer has to match. The
    /// popup refuses without a live window or a native popup role, so this
    /// call is itself the guard that the role is real.
    fn open(gpu: *noapi.Gpu, live: *popup_real.NativePopup, size: popup.Size) !Content {
        return .{
            .surface = try live.createGpuSurface(gpu, .{
                .width = size.width,
                .height = size.height,
            }),
        };
    }

    /// Release the device-side surface. Idempotent, because the release has to
    /// happen on the way out as well as at the end of a successful run.
    fn release(self: *Content) void {
        if (self.released) return;
        self.released = true;
        self.surface.deinit();
    }

    /// Present one cleared frame: acquire an image, clear it, submit, present.
    ///
    /// The clear is what makes this a real buffer rather than a commit. The
    /// image is what is cleared, never the requested surface size, because the
    /// driver clamps the image to the surface capabilities.
    fn presentOnce(self: *Content, clear_color: [4]f32) !Presented {
        const schedule = try self.surface.beginFrame();
        const image = self.surface.surfaceSize();
        if (image.width == 0 or image.height == 0) return error.SwapchainImageEmpty;
        var cmd = self.surface.commandsBegin();
        cmd.beginRendering(.{
            .render_area_size = .{ image.width, image.height },
            .color_attachments = &.{.{
                .texture = self.surface.currentImage(),
                .load_op = .clear,
                .store_op = .store,
                .clear_color = clear_color,
            }},
        });
        cmd.endRendering();
        const result = try self.surface.endFrame(.{});
        return .{
            .image = image,
            .swapchain_recreated = schedule.swapchain_recreated,
            .present_out_of_date = result.present_out_of_date,
        };
    }
};

/// Drive the display server this process is connected to.
///
/// A driver with no display server behind it returns before a window exists:
/// the refusals it cannot be given are the ones the adapter names, and a run
/// that has to open a window to learn that is not a headless-safe run.
fn run(
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    application: *host.Application,
    driver: popup_real.Driver,
    driver_name: []const u8,
    options: Options,
) !void {
    if (driver != .wayland and driver != .x11) {
        const refusal: []const u8 = if (driver == .headless)
            "HeadlessDisplayServer"
        else
            "NativeRoleUnavailable";
        try report.emit(
            "create(.os_surface): {s} (driver={s} has no display server, no window opened)\n",
            .{ refusal, driver_name },
        );
        // A caller that asked for a mapped buffer and got no display server has
        // not had its request satisfied. That is not the same outcome as the
        // default run, which opened nothing and therefore promised nothing.
        if (options.native) return error.NativeDisplayServerUnavailable;
        try report.emit(
            "popup verdict: this connection has no display server, refusal reported by name\n",
            .{},
        );
        return;
    }

    // A real buffer needs a device. The device is brought up only when the
    // caller asks for one, and a device that will not open does not stop the
    // run: the role, the configure and the protocol commit are separate claims
    // and none of them is evidence about the GPU. What it does do is leave the
    // request unfulfilled, so the run ends on it AFTER that evidence prints.
    // The device is released before this function returns, which is before the
    // host quits SDL and unloads the loader it dispatches through.
    var gpu: ?noapi.Gpu = null;
    var device_refused: ?[]const u8 = null;
    if (options.native) {
        gpu = openDevice(gpa, io, "w22-popup-smoke") catch |err| refused: {
            try report.emit(
                "native device: {s} (the popup role path still runs; no buffer is attached)\n",
                .{@errorName(err)},
            );
            device_refused = @errorName(err);
            break :refused null;
        };
        if (gpu != null) try report.emit("native device: opened\n", .{});
    } else {
        try report.emit("native device: not requested, no buffer is attached\n", .{});
    }
    defer if (gpu) |*device| device.deinit();

    // The driver arms below READ the device; it never owns it. They therefore
    // take a pointer into the optional that holds it rather than a copy, and
    // that pointer stays valid for the whole run: the release is the deferred
    // `deinit` above, which runs last.
    const opened_device: ?*noapi.Gpu = if (gpu) |*opened| opened else null;

    var work: Work = .{ .io = io, .report = report, .application = application };

    const handle = try application.openWindow(.{
        .title = parent_title,
        .width = parent_width,
        .height = parent_height,
        .visible = true,
        .gpu_surface = opened_device != null,
    });
    var parent_open = true;
    // A close that fails here leaves the window alive, so the error must not
    // be discarded: a run that swallowed it would go on to report a clean
    // shutdown it never had. The Reporter is in scope, so the failure is
    // printed like every other observation. A `defer` cannot propagate an
    // error, and a failed print would leave the process no way to report at
    // all, so that case panics rather than passing unnoticed.
    defer if (parent_open) {
        _ = application.closeWindow(handle) catch |err| {
            report.emit("teardown close of parent: {s}\n", .{@errorName(err)}) catch
                @panic("W22 popup smoke could not report the teardown close failure");
        };
    };

    const managed = try application.getWindow(handle);
    // An xdg_toplevel is not mapped until it has a real buffer. SDL's visible
    // flag alone gives the controller no parent surface to hit-test.
    var parent_content: ?Content = null;
    defer if (parent_content) |*held| held.release();
    if (opened_device) |device| {
        const pixels = try managed.native.pixelExtent();
        parent_content = .{
            .surface = try noapi.Surface.initSdl(
                device,
                @ptrCast(managed.native.sdl.value),
                @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
                .{ .extent = .{ .width = pixels.width, .height = pixels.height } },
            ),
        };
        const presented = try parent_content.?.presentOnce(.{ 0.10, 0.22, 0.40, 1.0 });
        try report.emit(
            "parent content: presented image={d}x{d} out_of_date={}\n",
            .{ presented.image.width, presented.image.height, presented.present_out_of_date },
        );
    }
    try work.pump(40);
    try managed.refresh();
    try report.emit(
        "parent observed: requested={d}x{d} observed={d}x{d} pixels={d}x{d} visible={}\n",
        .{
            managed.requested.size.width,
            managed.requested.size.height,
            managed.observed.size.width,
            managed.observed.size.height,
            managed.observed.pixels.width,
            managed.observed.pixels.height,
            managed.observed.visible,
        },
    );

    // The parent bounds come from what the display server actually granted,
    // including the global position when the backend reports one. The work
    // area is the usable area of the display this window is really on, so the
    // constraint solver has real edges to slide, flip and resize against.
    const parent = managed.native.sdl;
    const display = try parent.getDisplayForWindow();
    const usable = try display.getUsableBounds();
    const position = managed.observed.position orelse
        nogui.window_contract.Point{ .x = 0, .y = 0 };
    const parent_bounds: popup.Rect = .{
        .x = position.x,
        .y = position.y,
        .width = managed.observed.size.width,
        .height = managed.observed.size.height,
    };
    const work_area: popup.Rect = .{
        .x = usable.x,
        .y = usable.y,
        .width = @intCast(usable.w),
        .height = @intCast(usable.h),
    };
    try report.emit(
        "geometry: parent_bounds={d},{d} {d}x{d} work_area={d},{d} {d}x{d}" ++
            " parent_global_position_reported={}\n",
        .{
            parent_bounds.x,
            parent_bounds.y,
            parent_bounds.width,
            parent_bounds.height,
            work_area.x,
            work_area.y,
            work_area.width,
            work_area.height,
            managed.observed.position != null,
        },
    );

    // The request is DERIVED from the two rectangles above, so the popup is
    // asked for where the display server actually put this window and the
    // solver has a real edge to answer. Both requests come from the same
    // function and differ only in which edge the strip is against.
    const positioner = derivePositioner(parent_bounds, work_area, .right_edge);
    const moved_positioner = derivePositioner(parent_bounds, work_area, .left_edge);
    try emitRequest(report, "create", positioner);
    try emitRequest(report, "reposition", moved_positioner);

    const placement = popup.resolvePlacement(positioner, parent_bounds, work_area);
    try report.emit(
        "resolvePlacement: rect={d},{d} {d}x{d} flipped_x={} flipped_y={}" ++
            " slid_x={} slid_y={} resized_x={} resized_y={}\n",
        .{
            placement.rect.x,
            placement.rect.y,
            placement.rect.width,
            placement.rect.height,
            placement.flipped_x,
            placement.flipped_y,
            placement.slid_x,
            placement.slid_y,
            placement.resized_x,
            placement.resized_y,
        },
    );
    try emitResolved(report, "create", placement, parent_bounds, work_area);

    // ── refusals, in gate order; none of these allocates a native surface ──
    // `create` takes the allocator, the kind, the parent window and ONE
    // request. A grab is no longer part of creation: it is `requestGrab` on a
    // live popup, because the protocol allows it only while unmapped and the
    // adapter has to place it between the role and the first commit.
    const request: popup_real.Request = .{
        .positioner = positioner,
        .predicted = placement,
    };
    try expectRefusal(
        popup_real.NativePopup,
        "InAppOverlayHasNoNativeSurface",
        report,
        "create(.in_app_overlay)",
        popup_real.NativePopup.create(gpa, .in_app_overlay, parent, request),
    );
    var zero_size = positioner;
    zero_size.size = .{ .width = 0, .height = 0 };
    try expectRefusal(
        popup_real.NativePopup,
        "InvalidSize",
        report,
        "create(zero size)",
        popup_real.NativePopup.create(gpa, .os_surface, parent, .{
            .positioner = zero_size,
            .predicted = placement,
        }),
    );
    var zero_anchor = positioner;
    zero_anchor.anchor_rect.width = 0;
    // A zero anchor rect is a different refusal from a zero size: the size is
    // what the positioner sets, and the anchor rect is what the protocol
    // requires to be non-empty. Both are refusals, and they are named
    // separately so a caller can tell them apart.
    try expectRefusal(
        popup_real.NativePopup,
        "PositionerIncomplete",
        report,
        "create(zero anchor rect)",
        popup_real.NativePopup.create(gpa, .os_surface, parent, .{
            .positioner = zero_anchor,
            .predicted = placement,
        }),
    );
    // A reactive positioner is a protocol request, so it can only be sent where
    // a positioner exists. The X11 popup window is placed once by SDL and has
    // no request that would move it to a new anchor, so that create is refused
    // by name; the Wayland role sends `set_reactive`, which
    // `probeReactiveRole` drives on the live connection below.
    var reactive = positioner;
    reactive.reactive = true;
    if (driver == .x11) {
        try expectRefusal(
            popup_real.NativePopup,
            "ReactivePositionerUnsupported",
            report,
            "create(reactive positioner)",
            popup_real.NativePopup.create(gpa, .os_surface, parent, .{
                .positioner = reactive,
                .predicted = placement,
            }),
        );
    } else {
        var probe = popup_real.NativePopup.create(gpa, .os_surface, parent, .{
            .positioner = reactive,
            .predicted = placement,
        }) catch |err| {
            try report.emit("create(reactive positioner): {s}\n", .{@errorName(err)});
            return error.PopupCreateRefused;
        };
        // The window is live here and the role is not, so the probe has to
        // release it rather than leave a surface behind for a claim it never
        // makes.
        probe.deinit();
        try report.emit(
            "create(reactive positioner): <accepted>, set_reactive is sent by attachRole\n",
            .{},
        );
    }

    // The reposition request is built from the second derived positioner and
    // printed here, so the rectangle it asks the compositor for is on the
    // record next to the rectangle the create asked for, and the two can be
    // told apart before either is sent.
    const moved_request = movedRequest(moved_positioner, parent_bounds, work_area);
    try emitResolved(report, "reposition", moved_request.predicted, parent_bounds, work_area);

    switch (driver) {
        .x11 => try driveX11Popup(&work, gpa, parent, request, opened_device, options),
        .wayland => try driveWaylandPopup(
            &work,
            gpa,
            parent,
            request,
            moved_request,
            opened_device,
            options,
        ),
        // `run` returned above for anything that is neither of these.
        else => return error.UnexpectedDriver,
    }

    // A popup that outlived its parent's close is the last refusal, and it is
    // proved on a fresh popup because the value above has been released.
    {
        var second = popup_real.NativePopup.create(gpa, .os_surface, parent, request) catch |err| {
            try report.emit("second create(.os_surface): {s}\n", .{@errorName(err)});
            return error.PopupCreateRefused;
        };
        // The parent close dismisses the popup but does not free it, so the
        // teardown below is unconditional: skipping it leaks the role. This
        // popup carries no content, so it owns no device-side surface and the
        // release order is the adapter's own. A popup that HAD taken one would
        // release it here, before this line, because that order belongs to
        // whoever attached it.
        defer second.deinit();
        if (driver == .x11 and options.private_grab) {
            try report.emit("PARENT-CLOSE-OPEN-PRESS-READY window_id={d}\n", .{try parent.getId()});
            _ = try waitForSdlPress(&work, parent, options.private_grab_arm_ms);
            try second.show();
            try second.grab(.{ .approval = .{ .confirmed = true } });
            try report.emit(
                "parent-close grab: has_grab={} x11_grab_held={} x11_grab_status={?s}\n",
                .{
                    second.machine().has_grab,
                    second.grabHeld(),
                    if (second.grabStatus()) |status| @tagName(status) else null,
                },
            );
        }
        second.onParentClose();
        try report.emit(
            "parent close path: state={s} dismiss_reason={?s} has_grab={} x11_grab_held={}\n",
            .{
                @tagName(second.machine().state),
                if (second.machine().dismiss_reason) |reason| @tagName(reason) else null,
                second.machine().has_grab,
                second.grabHeld(),
            },
        );
        if (driver == .x11 and options.private_grab) {
            try report.emit("PARENT-CLOSE-RELEASE-PRESS-READY window_id={d}\n", .{try parent.getId()});
            const press = try waitForSdlPress(&work, parent, options.private_grab_arm_ms);
            try report.emit(
                "parent-close pointer released: delivered_window_id={d} parent_window_id={d}" ++
                    " popup_window_alive={} x11_grab_held={}\n",
                .{ press.window_id, try parent.getId(), second.window_alive, second.grabHeld() },
            );
            if (second.grabHeld()) return error.ParentCloseStillHoldsPointer;
        }
        try expectRefusal(
            popup_real.Plan,
            "AlreadyClosed",
            report,
            "dismiss after parent close",
            second.dismiss(),
        );
        // The role survives a dismissal it was told about, so the deferred
        // `deinit` is what releases it and it has to run exactly once.
    }
    try report.emit("after parent close: deinit released the role\n", .{});

    if (parent_content) |*held| held.release();
    const closed = try application.closeWindow(handle);
    _ = try application.step();
    parent_open = false;
    const stale = application.getWindow(handle);
    try report.emit(
        "parent closed: closeWindow={} getWindow={s} window_count={d}\n",
        .{
            closed,
            if (stale) |_| "<live>" else |err| @errorName(err),
            application.window_count,
        },
    );

    // Everything above is the evidence, and it stands on its own. What it does
    // not do is satisfy a device that was asked for and did not open, so the
    // run ends there: a missing device means the requested mapped-buffer proof
    // was never produced, and reporting success on the strength of the role
    // alone would be reporting something this run was not asked for.
    if (device_refused) |name| {
        try report.emit(
            "native device: {s} (unfulfilled: a mapped buffer was requested and none was shown)\n",
            .{name},
        );
        return error.NativeDeviceUnavailable;
    }
}

/// The reposition request, built from the positioner `run` derived rather than
/// from a constant of its own, with this tree's prediction of where that
/// lands. The xdg-shell path compares the prediction with the compositor's
/// answer; the X11 path has no positioner to send.
fn movedRequest(
    requester: popup.Positioner,
    parent_bounds: popup.Rect,
    work_area: popup.Rect,
) popup_real.Request {
    return .{
        .positioner = requester,
        .predicted = popup.resolvePlacement(requester, parent_bounds, work_area),
    };
}

/// A real press, as the display server delivered it to one of THIS run's own
/// windows.
///
/// SDL publishes no server-side event time: an SDL event's timestamp is this
/// library's own clock reading at delivery. What is latched here is therefore
/// the event and where it landed — which window the display server named, which
/// button, and the delivery time — and nothing here turns that into a protocol
/// serial. On the xdg-shell path the serial is a `wl_pointer.button` of its own,
/// and on the X11 path the X server takes no serial for a pointer grab at all.
const RealPress = struct {
    window_id: sdl3.video.WindowId,
    button: u8,
    timestamp_ns: u64,
};

/// Pump SDL until a real press lands on `target`, or the bound expires.
///
/// The host's own event step is deliberately NOT run inside this window. It
/// polls the very same SDL queue, so a press for the window under test would be
/// taken by a loop that has no window for it and would never reach here. Nothing
/// else needs servicing inside a bounded input window, and the host's step runs
/// again as soon as this returns.
///
/// Every other event in the queue is dropped, which is the one cost of reading
/// SDL's queue directly. It is paid only in the opt-in arm, over a window in
/// which this run has nothing else to do but wait for the press it asked for.
fn waitForSdlPress(
    work: *Work,
    target: sdl3.video.Window,
    bound_ms: u64,
) !RealPress {
    const id = try target.getId();
    const until = sdl3.timer.getMillisecondsSinceInit() + bound_ms;
    while (sdl3.timer.getMillisecondsSinceInit() < until) {
        sdl3.events.pump();
        while (sdl3.events.poll()) |raw| {
            switch (raw) {
                .mouse_button_down => |event| {
                    if (event.window_id == id and event.down) {
                        return .{
                            .window_id = id,
                            .button = @backingInt(event.button),
                            .timestamp_ns = event.common.timestamp,
                        };
                    }
                },
                else => {},
            }
        }
        try Io.sleep(work.io, Io.Duration.fromMilliseconds(8), .real);
    }
    return error.NoRealPress;
}

/// SDL may change mouse focus while this separate client retains the grab.
fn waitForX11Press(
    work: *Work,
    live: *popup_real.NativePopup,
    bound_ms: u64,
) !popup_real.X11Press {
    const until = sdl3.timer.getMillisecondsSinceInit() + bound_ms;
    while (sdl3.timer.getMillisecondsSinceInit() < until) {
        _ = try work.application.step();
        if (try live.takeX11Press()) |press| return press;
        try Io.sleep(work.io, Io.Duration.fromMilliseconds(8), .real);
    }
    return error.NoRealPress;
}

/// Pump the parent listener's own queue until a real press arrives on the
/// parent's surface, or the bound expires.
///
/// The host pumps the borrowed display socket; the listener dispatches only its
/// private queue. A compositor decides which surface has pointer focus, so
/// what arrives is what the compositor sent to
/// THIS parent's own `wl_surface`, and a press that went anywhere else is not a
/// serial this run may use.
fn waitForParentPress(
    work: *Work,
    input: *popup_real.ParentInput,
    bound_ms: u64,
) !u32 {
    _ = try work.application.step();
    // libdecor's synchronized shadow input region can change after the one
    // GPU presentation. Commit that pending native state without repainting
    // or replacing the parent's existing buffer; otherwise the shadow still
    // receives presses over the visible client content.
    _ = input.api.proxy_marshal_flags(
        input.parent_surface,
        wayland.opcode.wl_surface_commit,
        null,
        input.api.proxy_get_version(input.parent_surface),
        0,
    );
    _ = input.api.display_flush(input.display);
    if (input.api.display_get_error(input.display) != 0) return error.ConnectionFailed;
    const until = sdl3.timer.getMillisecondsSinceInit() + bound_ms;
    while (sdl3.timer.getMillisecondsSinceInit() < until) {
        _ = try work.application.step();
        try input.pump();
        if (input.takePress()) |serial| return serial;
        try Io.sleep(work.io, Io.Duration.fromMilliseconds(8), .real);
    }
    return error.NoRealParentPress;
}

/// Round-trip the shared connection until the compositor ends the grabbed
/// popup, or the bound expires. Whether it did is the answer, never a decision:
/// nothing in this function dismisses anything.
///
/// The popup's own events are on SDL's display's default queue, so a roundtrip
/// dispatches them; the parent listener's queue is pumped beside it, because a
/// press that arrived in the meantime is what ends a grabbed popup. Both are
/// borrowed — the display from this run's own parent window, the listener from
/// the grab arm — and neither outlives the call.
fn awaitCompositorDismiss(
    work: *Work,
    live: *popup_real.NativePopup,
    api: WaylandApi,
    parent_handles: popup_real.ParentHandles,
    input: ?*popup_real.ParentInput,
    bound_ms: u64,
) bool {
    const raw = parent_handles.display orelse return false;
    const display: *wayland.Display = @ptrCast(raw);
    const until = sdl3.timer.getMillisecondsSinceInit() + bound_ms;
    while (live.machine().popup_done_count == 0 and
        sdl3.timer.getMillisecondsSinceInit() < until)
    {
        if (input) |held| held.pump() catch break;
        if (api.display_roundtrip(display) < 0) break;
        _ = work.application.step() catch break;
        Io.sleep(work.io, Io.Duration.fromMilliseconds(8), .real) catch break;
    }
    return live.machine().popup_done_count > 0;
}

/// Drive the X11 half.
///
/// SDL creates the override-redirect window inside `SDL_CreatePopupWindow`, so
/// the role exists when the window does and `show` is the whole mapping step.
/// The role is confirmed from the window's own SDL properties, read back
/// through the public SDL surface rather than taken from the adapter's verdict.
fn driveX11Popup(
    work: *Work,
    gpa: std.mem.Allocator,
    parent: sdl3.video.Window,
    request: popup_real.Request,
    gpu: ?*noapi.Gpu,
    options: Options,
) !void {
    const report = work.report;
    var live = popup_real.NativePopup.create(gpa, .os_surface, parent, request) catch |err| {
        try report.emit("create(.os_surface): {s}\n", .{@errorName(err)});
        return error.PopupCreateRefused;
    };
    // The role is observable from the window's own properties, not just the
    // adapter's verdict, so the value stays alive until the smoke is finished
    // with it. The deferred `deinit` is the only teardown, and it runs once.
    defer live.deinit();
    try report.emit(
        "create(.os_surface): <accepted> driver={s} has_role_before_show={} state={s}\n",
        .{ @tagName(live.driver()), live.hasNativeRole(), @tagName(live.machine().state) },
    );

    // ── the two refusals, asked while the popup window is still hidden ──
    //
    // Both are refusals that never reach a display server, so they cost no
    // world change on any path and are proved whether or not the operator
    // approved the grab arm below.
    //
    // The approval gate is asked first and on its own, because it is the claim
    // that matters: a grab takes input away from every other client on this
    // display server, and an unapproved request must be refused before the
    // adapter looks at anything else.
    try expectRefusal(
        void,
        "RiskConfirmationRequired",
        report,
        "grab(unapproved)",
        live.grab(.{}),
    );
    // The order this driver insists on, asked as a refusal. The X11 grab is
    // taken against the popup's OWN window, and a window that is not on screen
    // cannot be one: the server has already answered `NotViewable` to this
    // request in practice, so asking first would send a request whose only
    // possible answer is a refusal. No serial is sent with it either — the X
    // server names an X timestamp for a pointer grab and there is no
    // user-event serial on this driver to send at all.
    try expectRefusal(
        void,
        "GrabBeforeMap",
        report,
        "grab(approved, before show)",
        live.grab(.{ .approval = .{ .confirmed = true } }),
    );
    try report.emit(
        "after grab refusals: has_grab={} pending_serial={?d} seat_serial={?d}" ++
            " state={s} window_alive={}\n",
        .{
            live.machine().has_grab,
            live.machine().pending_grab_serial,
            live.machine().seat_serial,
            @tagName(live.machine().state),
            live.window_alive,
        },
    );

    // Read the opening press while only the parent is mapped. A press outside
    // an already-shown SDL popup can dismiss that popup before our grab.
    var grab_arm: ?RealPress = null;
    if (options.private_grab) {
        try report.emit(
            "PARENT-PRESS-READY window_id={d} title=\"{s}\" bound_ms={d}" ++
                " press=any button, on this run's own parent window\n",
            .{ try parent.getId(), parent_title, options.private_grab_arm_ms },
        );
        grab_arm = try waitForSdlPress(work, parent, options.private_grab_arm_ms);
        try report.emit(
            "parent press: button={d} timestamp_ns={d} window_id={d}" ++
                " provenance=SDL mouse_button_down on this run's own X11 parent window\n",
            .{ grab_arm.?.button, grab_arm.?.timestamp_ns, grab_arm.?.window_id },
        );
    }

    // `show` releases the role on every failure path, so its error is terminal
    // for this popup and the value must not be used as a live one afterwards.
    const shown = live.show();
    try report.emit("show: {s}\n", .{outcomeText(void, shown)});
    if (!live.window_alive) {
        try report.emit(
            "the SDL window was released by the adapter, no popup role on this driver\n",
            .{},
        );
        return error.PopupRoleNotObtainable;
    }
    try shown;
    try emitPlan(report, "show plan", live.plan);
    try report.emit(
        "show: <accepted> driver={s} has_native_role={}" ++
            " x11_display={any} x11_window={any}" ++
            " xdg_popup={any} xdg_positioner={any} wayland_surface={any}\n",
        .{
            @tagName(live.driver()),
            live.hasNativeRole(),
            live.handles.x11_display,
            live.handles.x11_window,
            live.handles.xdg_popup,
            live.handles.xdg_positioner,
            live.handles.surface,
        },
    );
    if (!live.hasNativeRole()) return error.PopupRoleNotObtainable;

    {
        const props = try live.window().getProperties();
        try report.emit(
            "SDL readback: x11_display_pointer={any} x11_window_number={any}" ++
                " x11_screen={any} wayland_xdg_popup={any}\n",
            .{
                props.x11_display,
                props.x11_window,
                props.x11_screen,
                props.wayland_xdg_popup,
            },
        );
    }

    // There is no `activate` on this driver: the role IS the SDL popup window,
    // so `show` is the whole mapping step, and the grab that names that window
    // is a separate request against a window that is already on screen.
    try report.emit(
        "after show: state={s} has_grab={} seat_serial={?d} dismiss_reason={?s}\n",
        .{
            @tagName(live.machine().state),
            live.machine().has_grab,
            live.machine().seat_serial,
            if (live.machine().dismiss_reason) |reason| @tagName(reason) else null,
        },
    );

    // ── the real press and the real grab, and only with the approval ──
    //
    // The opening press was read before show; the server grab needs the popup
    // window mapped. No event timestamp is substituted for a Wayland serial.
    if (options.private_grab) {
        const grabbed = live.grab(.{ .approval = .{ .confirmed = true } });
        try report.emit("grab(real press, approved): {s}\n", .{outcomeText(void, grabbed)});
        try emitPlan(report, "grab plan", live.plan);
        // The X server's own status for `GrabPointer`, and whether it says the
        // grab is still held. A refused grab leaves `has_grab` false, so the
        // status is the reason, and this line is where it is readable.
        const status = live.grabStatus();
        try report.emit(
            "after grab: has_grab={} seat_serial={?d} pending_serial={?d} state={s}" ++
                " x11_grab_held={} x11_grab_status={?s}\n",
            .{
                live.machine().has_grab,
                live.machine().seat_serial,
                live.machine().pending_grab_serial,
                @tagName(live.machine().state),
                live.grabHeld(),
                if (status) |value| @tagName(value) else null,
            },
        );
        try grabbed;
        // A grab is taken once. A second approved grab on a live popup is
        // refused, and what has to survive that refusal is the grab that IS
        // held: the server keeps it, the popup stays mapped and the window is
        // still there. The refusal's own name belongs to the adapter's error
        // set, so what is checked here is the state it left behind.
        const repeated = live.grab(.{ .approval = .{ .confirmed = true } });
        try report.emit("grab(approved, second time): {s}\n", .{outcomeText(void, repeated)});
        try report.emit(
            "after the repeated grab: has_grab={} x11_grab_held={} state={s} window_alive={}\n",
            .{
                live.machine().has_grab,
                live.grabHeld(),
                @tagName(live.machine().state),
                live.window_alive,
            },
        );
    }

    // A real buffer on the popup's own window, through the public noapi
    // surface. It is attached after every refusal above, so the role evidence
    // is printed whether or not the device opens, and it is released before
    // the popup is: the adapter's teardown destroys the window and any
    // platform surface it still owns, and this one is gone by then.
    var content: ?Content = null;
    defer if (content) |*held| held.release();
    // The device is captured by pointer: a copy would be a second device, and
    // the surface has to belong to the one this run tears down.
    if (gpu) |device| {
        const mapped = live.machine().mapped_size;
        content = Content.open(device, &live, mapped) catch |err| {
            try report.emit(
                "native content: {s} (no buffer attached; the role evidence above stands)\n",
                .{@errorName(err)},
            );
            return error.PopupContentRefused;
        };
        const presented = content.?.presentOnce(.{ 0.16, 0.55, 0.35, 1.0 }) catch |err| {
            try report.emit(
                "native present: {s} (the surface was attached; the frame was not)\n",
                .{@errorName(err)},
            );
            return error.PopupPresentRefused;
        };
        try report.emit(
            "native content: attached {d}x{d}, presented image={d}x{d}" ++
                " swapchain_recreated={} out_of_date={}\n",
            .{
                mapped.width,
                mapped.height,
                presented.image.width,
                presented.image.height,
                presented.swapchain_recreated,
                presented.present_out_of_date,
            },
        );
    } else {
        try report.emit(
            "native content: no device, so this run proves the role and nothing about a buffer\n",
            .{},
        );
    }

    if (options.hold_ms > 0) {
        try report.emit("HOLD-BEGIN popup-up {d}ms\n", .{options.hold_ms});
        try work.hold(options.hold_ms);
        try report.emit("HOLD-END popup-up\n", .{});
    }

    // ── the press that ends a grabbed popup on this driver ──
    //
    // The X server routes pointer input to the window that holds the grab, so
    // a press anywhere on this private display now arrives on the POPUP's own
    // window. That press is the entire dismissal on this driver: there is no
    // `popup_done` here, and a client that took the user's input dismisses when
    // the user presses outside. The press belongs to another process — this run
    // neither sends nor fakes one, it only reads what the X server delivered.
    var dismissal_press: ?popup_real.X11Press = null;
    if (grab_arm != null) {
        const properties = try live.window().getProperties();
        const popup_window_id = properties.x11_window orelse return error.NativeHandleUnavailable;
        try report.emit(
            "POPUP-DISMISS-PRESS-READY window_id={d} bound_ms={d}\n",
            .{ popup_window_id, options.private_grab_arm_ms },
        );
        dismissal_press = waitForX11Press(work, &live, options.private_grab_arm_ms) catch |err| refusal: {
            try report.emit("press while the grab was held: {s}\n", .{@errorName(err)});
            break :refusal null;
        };
        if (dismissal_press) |press| {
            try report.emit(
                "press while the grab was held: button={d} timestamp_ms={d} window_xid={d}" ++
                    " popup_window_xid={d} x={d} y={d} routed_by=the X server, to the window holding the grab\n",
                .{ press.button, press.timestamp_ms, press.window, popup_window_id, press.x, press.y },
            );
        }
    }

    // Released here as well as in the defer above, because on the successful
    // path the order has to be explicit: the device-side surface dies before
    // the popup's dismissal, not after it.
    if (content) |*held| {
        held.release();
        content = null;
    }

    try report.emit(
        "before dismiss: state={s} dismiss_reason={?s} teardown_performed={} window_alive={}\n",
        .{
            @tagName(live.machine().state),
            if (live.machine().dismiss_reason) |reason| @tagName(reason) else null,
            live.machine().teardown_performed,
            live.window_alive,
        },
    );
    const plan = live.dismiss() catch |err| {
        try report.emit("dismiss: {s}\n", .{@errorName(err)});
        return error.PopupDismissRefused;
    };
    // The plan is empty on this driver and that is the result: the X11 role IS
    // the SDL popup window, so there is no protocol object to destroy and the
    // release is the window the adapter drops.
    try emitPlan(report, "teardown plan", plan);
    try report.emit("dismiss: SDL window released by the adapter\n", .{});
    if (live.grabHeld()) return error.DismissedPopupStillHoldsPointer;
    // A second dismissal on the same value must be refused rather than
    // releasing the role twice. The value is closed and readable, so this is
    // proved on the popup that was just dismissed.
    try expectRefusal(
        popup_real.Plan,
        "AlreadyClosed",
        report,
        "second dismiss",
        live.dismiss(),
    );
    try report.emit("second dismiss: refused, the role was released once\n", .{});
    // The arm was asked for and the press that ends a grabbed popup on this
    // driver never arrived. Everything above stands and the role is already
    // released, so this is the claim that did not happen and not a cleanup
    // problem: a run that was told to watch for a press cannot report success
    // because it ran out of window.
    if (options.private_grab and dismissal_press == null) {
        return error.NoRealDismissalPress;
    }
}

/// Drive the xdg-shell half.
///
/// SDL has no popup window to hand out on this driver, so the role is assigned
/// on SDL's own connection and followed through the protocol.
///
/// The grab is the one request that needs a user event, and inventing the serial
/// a grab names is the one thing a grab must never be. So the two refusals are
/// always proved, and the grab itself is asked for only when the operator
/// approved the arm AND the display server has really delivered a press to this
/// parent's own surface: that press is the serial, and it is consumed exactly
/// once between the role and the initial commit, which is the only window the
/// protocol allows.
fn driveWaylandPopup(
    work: *Work,
    gpa: std.mem.Allocator,
    parent: sdl3.video.Window,
    request: popup_real.Request,
    moved: popup_real.Request,
    gpu: ?*noapi.Gpu,
    options: Options,
) !void {
    const report = work.report;
    // libwayland-client is resolved through the same loader contract the
    // adapter takes, so the popup is created on the very connection SDL made.
    // It is loaded before the popup and released after it: a popup still
    // holding proxies must never outlive the library they point into.
    var dyn: DynLoader = .{};
    var api = WaylandApi.load(dyn.loader()) catch |err| {
        try report.emit(
            "libwayland-client: {s} (no xdg_popup role can be assigned)\n",
            .{@errorName(err)},
        );
        return error.PopupRoleNotObtainable;
    };
    defer api.deinit();
    try report.emit("libwayland-client: soname={s}\n", .{dyn.soname});

    var live = popup_real.NativePopup.create(gpa, .os_surface, parent, request) catch |err| {
        try report.emit("create(.os_surface): {s}\n", .{@errorName(err)});
        return error.PopupCreateRefused;
    };
    defer live.deinit();
    try report.emit(
        "create(.os_surface): <accepted> driver={s} has_role_before_attach={} state={s}\n",
        .{ @tagName(live.driver()), live.hasNativeRole(), @tagName(live.machine().state) },
    );

    const parent_handles = try popup_real.ParentHandles.read(parent);
    try report.emit(
        "parent handles: wayland={} has_xdg_surface={} has_xdg_toplevel={} usable_as_parent={}\n",
        .{
            parent_handles.isWayland(),
            parent_handles.xdg_surface != null,
            parent_handles.xdg_toplevel != null,
            parent_handles.usableAsPopupParent(),
        },
    );

    // A role may only go on a surface that has none. If the backend gave this
    // window a role anyway, `get_xdg_surface` is `xdg_wm_base.role` and the
    // connection goes down with it, so the adapter refuses instead.
    const attached = live.attachRole(api, parent_handles, request);
    try report.emit("attachRole: {s}\n", .{outcomeText(void, attached)});
    try emitPlan(report, "attachRole plan", live.plan);
    try attached;

    const scan = live.advertisement();
    try report.emit(
        "advertisement: globals={d} xdg_wm_base_name={d} xdg_wm_base_version={d}" ++
            " seat_name={d} seat_version={d} shell_removed={}\n",
        .{
            scan.globals,
            scan.wm_base_name,
            scan.wm_base_version,
            scan.seat_name,
            scan.seat_version,
            scan.wm_base_removed,
        },
    );
    try report.emit(
        "role attached: has_native_role={} pings_answered={d}\n",
        .{ live.hasNativeRole(), live.pingsAnswered() },
    );
    if (!live.hasNativeRole()) return error.PopupRoleNotObtainable;

    // The role is on the connection, so SDL's own properties name the surface
    // and nothing else. That is expected here and is printed so a reader can
    // see which half owns the role.
    {
        const props = try live.window().getProperties();
        try report.emit(
            "SDL readback: wayland_surface={any} wayland_xdg_surface={any}" ++
                " wayland_xdg_popup={any} (the role is on the connection, not in SDL)\n",
            .{ props.wayland_surface, props.wayland_xdg_surface, props.wayland_xdg_popup },
        );
    }

    try expectRefusal(
        void,
        "RiskConfirmationRequired",
        report,
        "grab(unapproved)",
        live.grab(.{}),
    );
    try expectRefusal(
        void,
        "MissingSeatSerial",
        report,
        "grab(approved, no user-event serial)",
        live.grab(.{ .approval = .{ .confirmed = true } }),
    );
    try report.emit(
        "after grab refusals: has_grab={} pending_serial={?d} state={s}\n",
        .{
            live.machine().has_grab,
            live.machine().pending_grab_serial,
            @tagName(live.machine().state),
        },
    );

    // ── the real press, and the real grab, and only with the approval ──
    //
    // A grab carries the serial of the user event that asked for the popup, so
    // there is exactly one honest way to fill it: latched off a real
    // `wl_pointer.button` delivered to THIS parent's own surface. The listener
    // that latches it borrows SDL's display and this window, owns its own
    // queue, and is released after the grab consumed the serial. It also has to
    // be alive across the whole arm: a press that arrives while the popup is up
    // and outside it is the compositor's cue to send `popup_done`, and a
    // listener released early could not tell that press from the one that
    // filled the serial.
    var input: ?*popup_real.ParentInput = null;
    defer if (input) |held| {
        // Released before the popup above it and long before SDL: it borrows
        // both, and a listener still dispatching into a destroyed window is
        // the use-after-free this order exists to prevent.
        held.deinit();
    };
    var grab_serial: ?u32 = null;
    if (options.private_grab) {
        // The seat is the one the popup's own registry scan found on THIS
        // connection, so the identity printed with the readiness line is the
        // compositor's answer and not a name this run chose.
        const seat = live.advertisement();
        input = popup_real.ParentInput.create(gpa, api, parent) catch |err| {
            try report.emit(
                "parent input: {s} (no press can be latched, so no grab is asked for)\n",
                .{@errorName(err)},
            );
            return error.PrivateInputUnavailable;
        };
        try report.emit(
            "PARENT-PRESS-READY window_id={d} title=\"{s}\" parent_surface={}" ++
                " parent_role={} seat_name={d} seat_version={d} bound_ms={d}" ++
                " press=any button, on this parent's own surface only\n",
            .{
                try parent.getId(),
                parent_title,
                parent_handles.surface != null,
                parent_handles.xdg_toplevel != null,
                seat.seat_name,
                seat.seat_version,
                options.private_grab_arm_ms,
            },
        );
        const serial = waitForParentPress(work, input.?, options.private_grab_arm_ms) catch |err| {
            try report.emit(
                "parent press: {s} (no real press, so no grab was asked for and the run ends here)\n",
                .{@errorName(err)},
            );
            return error.NoRealParentPress;
        };
        try report.emit(
            "parent press: serial={d} provenance=wl_pointer.button on this parent's wl_surface\n",
            .{serial},
        );
        const grabbed = live.grab(.{
            .serial = serial,
            .approval = .{ .confirmed = true },
        });
        try report.emit("grab(real press, approved): {s}\n", .{outcomeText(void, grabbed)});
        try emitPlan(report, "grab plan", live.plan);
        try grabbed;
        grab_serial = serial;
        try report.emit(
            "after grab: has_grab={} seat_serial={?d} pending_serial={?d} state={s}\n",
            .{
                live.machine().has_grab,
                live.machine().seat_serial,
                live.machine().pending_grab_serial,
                @tagName(live.machine().state),
            },
        );
    }

    // The initial commit carries no buffer: it is what asks the compositor for
    // the first configure, and it is the only place a grab could still land.
    try report.emit("initialCommit: {s}\n", .{outcomeText(void, live.initialCommit())});
    try emitPlan(report, "initialCommit plan", live.plan);

    const configure = live.waitForConfigure(4) catch |err| {
        try report.emit("waitForConfigure: {s} (the compositor placed nothing)\n", .{@errorName(err)});
        return error.PopupConfigureRefused;
    };
    const predicted = live.machine().placement.rect;
    // Two witnesses exist at two different stages, and neither may be read at
    // the other one's stage.
    //
    // The compositor's POSITION is available the moment the configure arrives:
    // xdg-shell states it relative to the parent's window geometry, and this
    // tree's own prediction is parent-relative too, so the two are in one frame
    // and comparing them is a real cross-check.
    //
    // The compositor's SIZE is not. `mapped_size` is 0x0 until a configure has
    // been acknowledged, so a size comparison taken here would be this run's
    // default measured against the compositor's answer and would report a
    // divergence for a popup that was placed exactly as asked. The pre-ack
    // default is therefore printed as what it is, and the size witness is
    // reported after the acknowledgement, where one exists.
    const position_diverges = configure.x != predicted.x or configure.y != predicted.y;
    try report.emit(
        "configure from the compositor: serial={d} x={d} y={d} {d}x{d}" ++
            " predicted_rect={d},{d} {d}x{d} position_diverges={}" ++
            " size_witness=absent mapped_size_pre_ack={d}x{d}\n",
        .{
            configure.serial,
            configure.x,
            configure.y,
            configure.width,
            configure.height,
            predicted.x,
            predicted.y,
            predicted.width,
            predicted.height,
            position_diverges,
            live.machine().mapped_size.width,
            live.machine().mapped_size.height,
        },
    );

    const size = try live.ackLatestConfigure();
    try report.emit(
        "ack: acked_serial={?d} configure_count={d} size={d}x{d}" ++
            " mapped_size={d}x{d} size_diverges={}\n",
        .{
            live.machine().acked_serial,
            live.machine().configure_count,
            size.width,
            size.height,
            live.machine().mapped_size.width,
            live.machine().mapped_size.height,
            live.machine().placementDiverges(),
        },
    );
    try emitPlan(report, "ack plan", live.plan);

    // This records the acknowledged role state without attaching a buffer.
    // The noapi presentation below attaches the real buffer and maps the
    // surface. A model state of `mapped` alone is not a visibility witness.
    try report.emit(
        "commit({d}x{d}): {s}\n",
        .{ size.width, size.height, outcomeText(void, live.commit(size)) },
    );
    try emitPlan(report, "commit plan", live.plan);
    try report.emit(
        "after commit: state={s} commit_count={d} mapped_size={d}x{d}\n",
        .{
            @tagName(live.machine().state),
            live.machine().commit_count,
            live.machine().mapped_size.width,
            live.machine().mapped_size.height,
        },
    );
    if (live.machine().state != .mapped) return error.PopupNotMapped;

    // A real buffer on the popup's own surface. Here the present IS what maps
    // the popup: the protocol commit above recorded the state, and the buffer
    // the device attaches and commits through the presentation engine is the
    // one the compositor turns into a visible popup. The extent is the size the
    // compositor configured, because a hidden roleless window has no size of
    // its own to measure.
    var content: ?Content = null;
    defer if (content) |*held| held.release();
    if (gpu) |device| {
        content = Content.open(device, &live, size) catch |err| {
            try report.emit(
                "native content: {s} (no buffer attached; the role evidence above stands)\n",
                .{@errorName(err)},
            );
            return error.PopupContentRefused;
        };
        const presented = content.?.presentOnce(.{ 0.55, 0.35, 0.16, 1.0 }) catch |err| {
            try report.emit(
                "native present: {s} (the surface was attached; the frame was not)\n",
                .{@errorName(err)},
            );
            return error.PopupPresentRefused;
        };
        try report.emit(
            "native content: attached {d}x{d}, presented image={d}x{d}" ++
                " swapchain_recreated={} out_of_date={}\n",
            .{
                size.width,
                size.height,
                presented.image.width,
                presented.image.height,
                presented.swapchain_recreated,
                presented.present_out_of_date,
            },
        );
    } else {
        try report.emit(
            "native content: no device, so this run proves the role and nothing about a buffer\n",
            .{},
        );
    }

    // A mapped popup follows a moving anchor with `xdg_popup.reposition`, which
    // exists only from xdg_popup version 3. The binding version decides, and a
    // compositor below it is reported by name rather than worked around.
    const asked = live.reposition(moved, reposition_token);
    try report.emit("reposition(token={d}): {s}\n", .{ reposition_token, outcomeText(void, asked) });
    try emitPlan(report, "reposition plan", live.plan);
    if (asked) |_| {
        const after = live.waitForConfigure(4) catch |err| {
            try report.emit("reposition configure: {s}\n", .{@errorName(err)});
            return error.PopupConfigureRefused;
        };
        try report.emit(
            "repositioned: requested={d} answered={d} configure serial={d} x={d} y={d} {d}x{d}\n",
            .{
                live.machine().reposition_count,
                live.repositionedCount(),
                after.serial,
                after.x,
                after.y,
                after.width,
                after.height,
            },
        );
        const resized = try live.ackLatestConfigure();
        try live.commit(resized);
        try report.emit(
            "after reposition: state={s} configure_count={d} size={d}x{d}\n",
            .{
                @tagName(live.machine().state),
                live.machine().configure_count,
                resized.width,
                resized.height,
            },
        );
    } else |err| {
        // A binding older than `xdg_popup` version 3 carries no `reposition`
        // request, and nothing else may place a mapped popup on its behalf.
        // The refusal is the result, not something to work around.
        try report.emit("reposition declined by this binding: {s}\n", .{@errorName(err)});
    }

    if (options.hold_ms > 0) {
        try report.emit("HOLD-BEGIN popup-up {d}ms\n", .{options.hold_ms});
        try work.hold(options.hold_ms);
        try report.emit("HOLD-END popup-up\n", .{});
    }

    // Released here as well as in the defer above: the device-side surface
    // dies before the popup's dismissal, and the dismissal is what destroys the
    // window, the proxies and anything the popup still owns.
    if (content) |*held| {
        held.release();
        content = null;
    }

    // ── the compositor's own dismissal, and only while a real grab is held ──
    //
    // A grabbed popup ends when the compositor says so: the user pressed
    // outside it, and `xdg_popup.popup_done` is the event that says the popup
    // held their input and gave it up. Nothing in this run decides to dismiss —
    // the press that causes it belongs to another process, and the only thing
    // decided here is whether the compositor's own event arrived.
    if (grab_serial != null) {
        const shown = live.machine().configure orelse configure;
        try report.emit(
            "POPUP-UP-WITH-GRAB seat_serial={?d} size={d}x{d} popup_rect={d},{d} {d}x{d}" ++
                " parent_relative bound_ms={d} press=outside this popup\n",
            .{
                live.machine().seat_serial,
                size.width,
                size.height,
                shown.x,
                shown.y,
                shown.width,
                shown.height,
                options.private_grab_arm_ms,
            },
        );
        const compositor_ended = awaitCompositorDismiss(
            work,
            &live,
            api,
            parent_handles,
            input,
            options.private_grab_arm_ms,
        );
        try report.emit(
            "popup_done from the compositor: count={d} dismiss_reason={?s} state={s}" ++
                " teardown_performed={} window_alive={} has_grab={} observed={}\n",
            .{
                live.machine().popup_done_count,
                if (live.machine().dismiss_reason) |reason| @tagName(reason) else null,
                @tagName(live.machine().state),
                live.machine().teardown_performed,
                live.window_alive,
                live.machine().has_grab,
                compositor_ended,
            },
        );
        if (compositor_ended) {
            // The protocol says the client destroys the role object when this
            // event arrives, and the single teardown is already claimed, so a
            // client dismissal now has nothing left to do: it is refused, and
            // the release happens exactly once, in `deinit` below it.
            try expectRefusal(
                popup_real.Plan,
                "AlreadyClosed",
                report,
                "dismiss after popup_done",
                live.dismiss(),
            );
            try report.emit(
                "teardown: the compositor's dismissal claimed the one teardown; the role," ++
                    " its surface, the seat and the shell are released in that order by deinit\n",
                .{},
            );
            return;
        }
        try report.emit(
            "no compositor dismissal within {d}ms; the grab was never ended by the user and" ++
                " this run dismisses the popup itself below\n",
            .{options.private_grab_arm_ms},
        );
    }

    try report.emit(
        "before dismiss: state={s} dismiss_reason={?s} teardown_performed={} window_alive={}\n",
        .{
            @tagName(live.machine().state),
            if (live.machine().dismiss_reason) |reason| @tagName(reason) else null,
            live.machine().teardown_performed,
            live.window_alive,
        },
    );
    const plan = live.dismiss() catch |err| {
        try report.emit("dismiss: {s}\n", .{@errorName(err)});
        return error.PopupDismissRefused;
    };
    // The teardown order is the evidence that the role object went before the
    // `xdg_surface` that carried it and the shell that made both.
    try emitPlan(report, "teardown plan", plan);
    try report.emit("dismiss: role, xdg_surface and shell released in that order\n", .{});
    try expectRefusal(
        popup_real.Plan,
        "AlreadyClosed",
        report,
        "second dismiss",
        live.dismiss(),
    );
    try report.emit("second dismiss: refused, the role was released once\n", .{});
    try probeReactiveRole(report, gpa, parent, request, api, parent_handles);
}

/// Drive a reactive popup role on the live connection and report what the
/// compositor was actually asked for.
///
/// This is a separate popup because the two claims are separate: a working role
/// is proven by a plain positioner that every shell since version 1 can carry,
/// while `set_reactive` arrived in version 3. A binding that cannot carry it is
/// refused by name here, which says nothing about the role and must not be
/// allowed to look as though it did.
fn probeReactiveRole(
    report: *Reporter,
    gpa: std.mem.Allocator,
    parent: sdl3.video.Window,
    request: popup_real.Request,
    api: WaylandApi,
    parent_handles: popup_real.ParentHandles,
) !void {
    var reactive_request = request;
    reactive_request.positioner.reactive = true;
    var probe = popup_real.NativePopup.create(gpa, .os_surface, parent, reactive_request) catch |err| {
        try report.emit("reactive probe create: {s}\n", .{@errorName(err)});
        return;
    };
    defer probe.deinit();

    const attached = probe.attachRole(api, parent_handles, reactive_request);
    try report.emit("reactive probe attachRole: {s}\n", .{outcomeText(void, attached)});
    try emitPlan(report, "reactive probe plan", probe.plan);
    if (attached) |_| {
        const scan = probe.advertisement();
        try report.emit(
            "reactive probe: xdg_wm_base_version={d} set_reactive_reached_the_wire={}\n",
            .{ scan.wm_base_version, probe.plan.countOf(.positioner_set_reactive) > 0 },
        );
    } else |err| {
        try report.emit(
            "reactive probe: {s}, this binding predates set_reactive; the role is unaffected\n",
            .{@errorName(err)},
        );
    }
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
        } else if (std.mem.eql(u8, arg, "--native")) {
            // Opt-in because it is the only path that opens a GPU device and
            // attaches a buffer to a window on the session's display server.
            options.native = true;
        } else if (std.mem.eql(u8, arg, "--private-native-grab")) {
            // A point of risk, so it is approved by name and never implied by
            // anything else on this command line.
            options.private_grab = true;
        } else if (std.mem.eql(u8, arg, "--private-grab-arm-ms")) {
            const value = args_it.next() orelse return error.MissingPrivateGrabArmMs;
            options.private_grab_arm_ms = try std.fmt.parseInt(u64, value, 10);
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }
    // The window and the approval are one decision. A window without the
    // approval is a measurement of nothing and is refused rather than
    // ignored, and the approval without a window is an arm that would wait
    // forever for a press, so that is refused too.
    if (options.private_grab_arm_ms > 0 and !options.private_grab) {
        std.log.err(
            "--private-grab-arm-ms is the window of a grab arm that was never approved",
            .{},
        );
        return error.MissingPrivateGrabApproval;
    }
    if (options.private_grab and options.private_grab_arm_ms == 0) {
        std.log.err(
            "--private-native-grab needs --private-grab-arm-ms N: a grab arm with no window " ++
                "never sees the press that fills the serial",
            .{},
        );
        return error.MissingPrivateGrabArmWindow;
    }

    var report: Reporter = .{ .io = io };
    try report.emit("W22 native popup smoke\n", .{});

    // The host owns SDL, so the parent toplevel and the popup share one
    // display connection and the run owns both teardowns.
    //
    // The driver is chosen BEFORE SDL video is initialized, and that is what
    // makes the default safe: without `--native` the host is told to take the
    // windowless driver, so a run on a machine with a desktop session never
    // reaches the user's display server and never opens a window. With
    // `--native` the hint is left alone, so the requested environment — the
    // session's own Wayland compositor or a private X server — decides.
    var session = try nogui.Session.init(gpa);
    var session_live = true;
    defer if (session_live) session.deinit() catch
        @panic("W22 popup smoke error path left the Session live");
    var application = try host.Application.init(gpa, &session, .{
        .app_id = "dev.nogui.w22popupsmoke",
        .restart = .never,
        .video_driver = if (options.native) null else "dummy",
    });
    var application_live = true;
    defer if (application_live) application.deinit();

    const driver_name = sdl3.video.getCurrentDriverName() orelse "<null>";
    const driver = popup_real.currentDriver();
    try report.emit("video driver: {s}\n", .{driver_name});
    try report.emit("popup_real.currentDriver: {s}\n", .{@tagName(driver)});
    // Printed before anything is opened, so a reader can tell from the record
    // whether a grab could ever have been asked for in this run.
    try report.emit(
        "private grab arm: approved={} arm_ms={d}\n",
        .{ options.private_grab, options.private_grab_arm_ms },
    );

    try run(gpa, io, &report, &application, driver, driver_name, options);
    if (driver == .wayland or driver == .x11) {
        try report.emit(
            "popup verdict: the popup role path was driven on driver {s}, buffer={s}\n",
            .{ driver_name, if (options.native) "requested" else "not requested" },
        );
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
    try report.emit("W22 native popup smoke done\n", .{});
}
