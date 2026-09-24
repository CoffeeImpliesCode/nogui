//! Runtime libwayland-client binding and Wayland interface descriptors.
//!
//! SDL loads libwayland-client itself (`SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC`) and
//! hands out its `wl_display` and `wl_surface` through documented window
//! properties. Those proxies must only be driven by the *same* library copy
//! that created them, so nogui resolves the client entry points through SDL's
//! own loader with the same soname. The dynamic loader refcounts the object and
//! hands back the identical mapping, which keeps one copy in the process.
//!
//! `sdlLoader` below is the production answer to that: it resolves the client
//! through SDL's own `SDL_LoadObject`. The vtable itself stays injectable, so a
//! test can still drive a table with no SDL in the process.
const std = @import("std");
const sdl3 = @import("sdl3");

pub const Proxy = opaque {};
pub const Display = opaque {};
pub const Surface = opaque {};
pub const Seat = opaque {};
pub const Output = opaque {};
pub const Registry = opaque {};

/// An event queue. Opaque here: libwayland creates one with
/// `wl_display_create_queue` and releases it with `wl_event_queue_destroy`.
pub const EventQueue = opaque {};

/// C layout of `struct wl_message` from wayland-util.h.
pub const Message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: [*]const ?*const Interface,
};

/// C layout of `struct wl_interface` from wayland-util.h.
pub const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: [*]const Message,
    event_count: c_int,
    events: [*]const Message,
};

pub const marshal_destroy: u32 = 1 << 0;

/// Shorthand for the optional interface argument of a variadic C entry point.
const MaybeIface = ?*const Interface;

/// `wl_proxy_marshal_flags`, the one variadic C entry point in this table.
/// `zig fmt` always joins a variadic fn pointer onto one line, so the
/// parameter names are short on purpose to stay inside the line limit.
pub const MarshalFlagsFn = *const fn (p: *Proxy, op: u32, i: MaybeIface, v: u32, f: u32, ...) callconv(.c) ?*Proxy;

/// `wl_display_create_queue` from `wayland-client-core.h`: the public way to get
/// a queue that is not the display's default one. The older
/// `wl_event_queue_create` is private API and appears in no public header.
pub const DisplayCreateQueueFn = *const fn (display: *Display) callconv(.c) ?*EventQueue;

/// `wl_proxy_set_queue` from `wayland-client-core.h`: every later event of
/// `proxy` is queued in `queue`.
pub const ProxySetQueueFn = *const fn (proxy: *Proxy, queue: *EventQueue) callconv(.c) void;

/// `wl_display_roundtrip_queue` from `wayland-client-core.h`: blocks until the
/// server has answered, dispatching only what `queue` received. A null queue
/// would mean the default queue, which belongs to whoever pumps the display.
pub const DisplayRoundtripQueueFn = *const fn (display: *Display, queue: *EventQueue) callconv(.c) c_int;

/// `wl_display_dispatch_queue_pending` from `wayland-client-core.h`: dispatches
/// the events already read into `queue` and touches nothing else. It never
/// reads the socket, so a caller that only wants its own queue cannot take an
/// event out of the default queue the host dispatches, and it never blocks, so
/// pumping costs a dispatch and no round trip.
pub const DisplayDispatchQueuePendingFn = *const fn (display: *Display, queue: *EventQueue) callconv(.c) c_int;

/// `wl_display_get_error` from `wayland-client-core.h`: zero while the display is
/// usable, non-zero once the connection is dead.
pub const DisplayGetErrorFn = *const fn (display: *Display) callconv(.c) c_int;

/// `wl_event_queue_destroy` from `wayland-client-core.h`. Pending events on the
/// queue are discarded, and the display must outlive every queue made from it.
pub const EventQueueDestroyFn = *const fn (queue: *EventQueue) callconv(.c) void;

/// `wl_proxy_create_wrapper` from `wayland-client-core.h`. The header declares
/// its parameter as `void *`, so this does too: what comes back wraps whatever
/// proxy was handed in and is itself a `struct wl_proxy *`.
pub const ProxyCreateWrapperFn = *const fn (proxy: *anyopaque) callconv(.c) ?*Proxy;

/// `wl_proxy_wrapper_destroy` from `wayland-client-core.h`.
pub const ProxyWrapperDestroyFn = *const fn (wrapper: *Proxy) callconv(.c) void;

/// Resolved libwayland-client entry points. Every field is non-null only after
/// `Api.load` succeeded, so a partial table can never be used.
pub const Api = struct {
    /// The loader mapping remains owned until deinit, after all proxies are gone.
    object: ?Object = null,
    proxy_marshal_flags: MarshalFlagsFn,
    proxy_destroy: *const fn (proxy: *Proxy) callconv(.c) void,
    proxy_add_listener: *const fn (
        proxy: *Proxy,
        implementation: [*]const ?*const anyopaque,
        data: ?*anyopaque,
    ) callconv(.c) c_int,
    proxy_set_user_data: *const fn (proxy: *Proxy, data: ?*anyopaque) callconv(.c) void,
    proxy_get_version: *const fn (proxy: *Proxy) callconv(.c) u32,
    display_roundtrip: *const fn (display: *Display) callconv(.c) c_int,
    display_flush: *const fn (display: *Display) callconv(.c) c_int,
    display_dispatch_pending: *const fn (display: *Display) callconv(.c) c_int,

    /// The private-queue entry points. They are required like the rest of the
    /// table: a discovery that must not disturb the display's default queue has
    /// no other way to run, so a library that cannot do it is refused by name
    /// rather than returned with a hole in it.
    display_create_queue: DisplayCreateQueueFn,
    proxy_set_queue: ProxySetQueueFn,
    display_roundtrip_queue: DisplayRoundtripQueueFn,
    display_get_error: DisplayGetErrorFn,
    event_queue_destroy: EventQueueDestroyFn,
    /// A wrapper is how a borrowed proxy gets its own queue without the queue
    /// being set on the borrowed proxy itself.
    proxy_create_wrapper: ProxyCreateWrapperFn,
    proxy_wrapper_destroy: ProxyWrapperDestroyFn,

    /// A caller that listens for events of its own has to drain them without
    /// waiting for the compositor and without dispatching the host's queue.
    /// `display_roundtrip_queue` does the first and not the second, and the
    /// default queue belongs to whoever pumps the display, so this entry is
    /// required like the rest of the table: a library that cannot drain one
    /// private queue without draining the host's has no way to run at all.
    display_dispatch_queue_pending: DisplayDispatchQueuePendingFn,

    pub fn displayGetRegistry(self: Api, display: *Display) ?*Registry {
        const proxy: *Proxy = @ptrCast(display);
        const registry = self.proxy_marshal_flags(
            proxy,
            1,
            &wl_registry_interface,
            self.proxy_get_version(proxy),
            0,
            @as(?*Proxy, null),
        ) orelse return null;
        return @ptrCast(registry);
    }

    pub fn registryBind(
        self: Api,
        registry: *Registry,
        name: u32,
        interface: *const Interface,
        version: u32,
    ) ?*Proxy {
        return self.proxy_marshal_flags(
            @ptrCast(registry),
            0,
            interface,
            version,
            0,
            name,
            interface.name,
            version,
            @as(?*Proxy, null),
        );
    }

    /// The sonames SDL may have used, in the order SDL itself tries them.
    pub const candidate_sonames = [_][:0]const u8{
        "libwayland-client.so.0",
        "libwayland-client.so",
    };

    pub const Missing = error{
        /// No candidate soname resolved; the Wayland client is not installed.
        WaylandClientMissing,
        /// The library loaded but a required entry point is absent.
        WaylandClientIncomplete,
    };

    /// Resolve through a caller-supplied loader so no SDL import is required.
    pub fn load(loader: Loader) !Api {
        var last: ?anyerror = null;
        for (candidate_sonames) |soname| {
            const object = loader.loadObject(soname) catch |err| {
                last = err;
                continue;
            };
            var api = fromObject(object) catch |err| {
                object.unload();
                last = err;
                continue;
            };
            api.object = object;
            return api;
        }
        return last orelse error.WaylandClientMissing;
    }

    /// Release the loader mapping and poison the value.
    ///
    /// Calling `deinit` a second time is a caller error, not a supported
    /// operation: this method ends by writing `undefined` over the whole
    /// value, including the `object` optional it just read, so a repeat call
    /// would read an uninitialised optional. Every `deinit` in this tree owns
    /// that same once-only contract.
    pub fn deinit(self: *Api) void {
        if (self.object) |object| {
            object.unload();
            self.object = null;
        }
        self.* = undefined;
    }

    const ProxyDestroyFn = *const fn (proxy: *Proxy) callconv(.c) void;
    const ProxyAddListenerFn = *const fn (
        proxy: *Proxy,
        implementation: [*]const ?*const anyopaque,
        data: ?*anyopaque,
    ) callconv(.c) c_int;
    const ProxySetUserDataFn = *const fn (proxy: *Proxy, data: ?*anyopaque) callconv(.c) void;
    const ProxyGetVersionFn = *const fn (proxy: *Proxy) callconv(.c) u32;
    const DisplayRoundtripFn = *const fn (display: *Display) callconv(.c) c_int;
    const DisplayFlushFn = *const fn (display: *Display) callconv(.c) c_int;
    const DisplayDispatchPendingFn = *const fn (display: *Display) callconv(.c) c_int;

    fn fromObject(object: Object) !Api {
        const name_marshal = "wl_proxy_marshal_flags";
        const name_destroy = "wl_proxy_destroy";
        const name_add_listener = "wl_proxy_add_listener";
        const name_set_user_data = "wl_proxy_set_user_data";
        const name_get_version = "wl_proxy_get_version";
        const name_roundtrip = "wl_display_roundtrip";
        const name_flush = "wl_display_flush";
        const name_dispatch = "wl_display_dispatch_pending";

        const marshal: MarshalFlagsFn = try symbol(MarshalFlagsFn, object, name_marshal);
        const destroy: ProxyDestroyFn = try symbol(ProxyDestroyFn, object, name_destroy);
        const add_listener: ProxyAddListenerFn = try symbol(
            ProxyAddListenerFn,
            object,
            name_add_listener,
        );
        const set_user_data: ProxySetUserDataFn = try symbol(
            ProxySetUserDataFn,
            object,
            name_set_user_data,
        );
        const get_version: ProxyGetVersionFn = try symbol(ProxyGetVersionFn, object, name_get_version);
        const roundtrip: DisplayRoundtripFn = try symbol(
            DisplayRoundtripFn,
            object,
            name_roundtrip,
        );
        const flush: DisplayFlushFn = try symbol(DisplayFlushFn, object, name_flush);
        const dispatch: DisplayDispatchPendingFn = try symbol(
            DisplayDispatchPendingFn,
            object,
            name_dispatch,
        );

        const create_queue: DisplayCreateQueueFn = try symbol(
            DisplayCreateQueueFn,
            object,
            "wl_display_create_queue",
        );
        const set_queue: ProxySetQueueFn = try symbol(ProxySetQueueFn, object, "wl_proxy_set_queue");
        const roundtrip_queue: DisplayRoundtripQueueFn = try symbol(
            DisplayRoundtripQueueFn,
            object,
            "wl_display_roundtrip_queue",
        );
        const dispatch_queue: DisplayDispatchQueuePendingFn = try symbol(
            DisplayDispatchQueuePendingFn,
            object,
            "wl_display_dispatch_queue_pending",
        );
        const get_error: DisplayGetErrorFn = try symbol(
            DisplayGetErrorFn,
            object,
            "wl_display_get_error",
        );
        const destroy_queue: EventQueueDestroyFn = try symbol(
            EventQueueDestroyFn,
            object,
            "wl_event_queue_destroy",
        );
        const create_wrapper: ProxyCreateWrapperFn = try symbol(
            ProxyCreateWrapperFn,
            object,
            "wl_proxy_create_wrapper",
        );
        const destroy_wrapper: ProxyWrapperDestroyFn = try symbol(
            ProxyWrapperDestroyFn,
            object,
            "wl_proxy_wrapper_destroy",
        );
        return .{
            .proxy_marshal_flags = marshal,
            .proxy_destroy = destroy,
            .proxy_add_listener = add_listener,
            .proxy_set_user_data = set_user_data,
            .proxy_get_version = get_version,
            .display_roundtrip = roundtrip,
            .display_flush = flush,
            .display_dispatch_pending = dispatch,
            .display_create_queue = create_queue,
            .proxy_set_queue = set_queue,
            .display_roundtrip_queue = roundtrip_queue,
            .display_get_error = get_error,
            .display_dispatch_queue_pending = dispatch_queue,
            .event_queue_destroy = destroy_queue,
            .proxy_create_wrapper = create_wrapper,
            .proxy_wrapper_destroy = destroy_wrapper,
        };
    }

    /// Look one C symbol up and verify the declared prototype is C-ABI plain.
    ///
    /// A mismatched prototype must fail at load time, never crash later.
    fn symbol(comptime Proto: type, object: Object, name: [:0]const u8) !Proto {
        const child = switch (@typeInfo(Proto)) {
            .pointer => |ptr| ptr.child,
            else => return error.WaylandClientIncomplete,
        };
        const proto = switch (@typeInfo(child)) {
            .@"fn" => |value| value,
            else => return error.WaylandClientIncomplete,
        };
        const want_tag = std.meta.activeTag(std.builtin.CallingConvention.c);
        if (std.meta.activeTag(proto.calling_convention) != want_tag) {
            return error.WaylandClientIncomplete;
        }
        if (proto.is_generic) return error.WaylandClientIncomplete;
        if (proto.return_type == null) return error.WaylandClientIncomplete;
        inline for (proto.params) |param| {
            if (param.type == null) return error.WaylandClientIncomplete;
        }
        const raw = object.loadFunction(name) catch return error.WaylandClientIncomplete;
        return @ptrCast(@alignCast(raw));
    }
};

/// Minimal loader contract so tests can inject a table without SDL.
pub const Loader = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        loadObject: *const fn (context: *anyopaque, soname: [:0]const u8) anyerror!Object,
    };

    pub fn loadObject(self: Loader, soname: [:0]const u8) anyerror!Object {
        return self.vtable.loadObject(self.context, soname);
    }
};

/// Opaque loaded library handle with a symbol lookup hook.
pub const Object = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        loadFunction: *const fn (context: *anyopaque, name: [:0]const u8) anyerror!*const anyopaque,
        unload: *const fn (context: *anyopaque) void,
    };

    pub fn loadFunction(self: Object, name: [:0]const u8) anyerror!*const anyopaque {
        return self.vtable.loadFunction(self.context, name);
    }

    pub fn unload(self: Object) void {
        self.vtable.unload(self.context);
    }
};

/// SDL's own shared-object loader, as a `Loader`.
///
/// The proxies this file drives were created by libwayland through SDL's
/// loader, so every entry point that touches one must come from that same
/// mapping. `SDL_LoadObject` refcounts the soname, so asking for the library
/// SDL already mapped hands back the identical mapping and the process keeps
/// one copy of it.
pub fn sdlLoader() Loader {
    return .{ .context = @ptrCast(&sdl_loader_context), .vtable = &sdl_loader_vtable };
}

/// `Loader.context` is handed straight to `loadObject`, and SDL's loader keeps
/// no state of its own, so this is the one address it is given and nothing ever
/// reads it.
var sdl_loader_context: u8 = 0;

const sdl_loader_vtable: Loader.VTable = .{ .loadObject = sdlLoadObject };
const sdl_object_vtable: Object.VTable = .{
    .loadFunction = sdlLoadFunction,
    .unload = sdlUnload,
};

fn sdlLoadObject(_: *anyopaque, soname: [:0]const u8) anyerror!Object {
    const shared = try sdl3.SharedObject.load(soname);
    // The SDL handle IS the object's context, so both callbacks below recover
    // the library from it and neither needs a side table.
    return .{ .context = @ptrCast(shared.value), .vtable = &sdl_object_vtable };
}

fn sdlLoadFunction(context: *anyopaque, name: [:0]const u8) anyerror!*const anyopaque {
    return sdlSharedObject(context).loadFunction(name);
}

fn sdlUnload(context: *anyopaque) void {
    sdlSharedObject(context).unload();
}

fn sdlSharedObject(context: *anyopaque) sdl3.SharedObject {
    return .{ .value = @ptrCast(@alignCast(context)) };
}

/// C layout of `struct wl_registry_listener`.
pub const RegistryListener = extern struct {
    global: *const fn (
        data: ?*anyopaque,
        registry: *Registry,
        name: u32,
        interface: [*:0]const u8,
        version: u32,
    ) callconv(.c) void,
    global_remove: *const fn (
        data: ?*anyopaque,
        registry: *Registry,
        name: u32,
    ) callconv(.c) void,
};

/// Protocol since-versions for the requests this tree may only send on a high
/// enough binding, and the predicates the adapters guard with.
///
/// `struct wl_message` carries no since-version: libwayland keeps that table
/// on the server, so a local descriptor can only be truthful about the wire
/// signature. These constants are the single place the since-version of such a
/// request is recorded, so a guard and the descriptor it protects cannot drift.
/// The values come from the generated `wayland-client-protocol.h` (wayland
/// 1.26.0) and each one names the macro that settles it.
pub const since_version = struct {
    /// `WL_COMPOSITOR_RELEASE_SINCE_VERSION`, header line 1319.
    pub const wl_compositor_release: u32 = 7;
    /// `WL_OUTPUT_RELEASE_SINCE_VERSION`, header line 6308.
    pub const wl_output_release: u32 = 3;
    /// `zwlr_layer_shell_v1.destroy`, `since="3"` in
    /// `wlr-layer-shell-unstable-v1.xml` line 94. The wlr protocols ship no
    /// generated header, so the XML is the authority for this one.
    pub const zwlr_layer_shell_v1_destroy: u32 = 3;
    /// `xdg_popup.reposition`, `since="3"` in `xdg-shell.xml` line 1368. The
    /// request is the THIRD in the list, so its opcode is 2 and its since
    /// version is 3; those are different facts and only one of them belongs in
    /// `opcode`.
    pub const xdg_popup_reposition: u32 = 3;
    /// `xdg_positioner.set_reactive`, `since="3"` in `xdg-shell.xml` line 366.
    /// It is the EIGHTH request in the list, so its opcode is 7 and its since
    /// version is 3; those are different facts and only one of them belongs in
    /// `opcode`. A reactive positioner is what makes a popup follow a parent
    /// that moves, so this one is on the popup's critical path.
    pub const xdg_positioner_set_reactive: u32 = 3;
};

/// `WL_COMPOSITOR_RELEASE`, header line 1305.
pub const wl_compositor_release_opcode: u32 = 2;
/// `WL_OUTPUT_RELEASE`, header line 6278.
pub const wl_output_release_opcode: u32 = 0;

/// Destructor opcodes and the guards that keep them behind their since-version.
///
/// Each of these is a `type="destructor"` request: sending it with
/// `WL_MARSHAL_FLAG_DESTROY` releases the local proxy atomically with the wire
/// message. Sending one to a binding older than its since-version is a fatal
/// protocol error, so every such request has a guard here rather than a number
/// typed at the call site.
pub const destructor = struct {
    /// `wl_seat.release`, `wayland.xml` line 2129.
    pub const wl_seat_release: u32 = 3;
    /// `WL_SEAT_RELEASE_SINCE_VERSION`, generated header line 6226.
    pub const wl_seat_release_since: u32 = 5;
};

/// True when a `wl_seat` binding may send `wl_seat.release`.
///
/// A binding older than version 5 has no destructor to send, and sending one
/// anyway makes the server answer `invalid version for wl_seat.release` and close
/// the display connection. The local proxy is dropped instead.
pub fn seatCanRelease(bound_version: u32) bool {
    return bound_version >= destructor.wl_seat_release_since;
}

/// `WL_POINTER_RELEASE_SINCE_VERSION`, generated header line 3961.
pub const wl_pointer_release_since: u32 = 3;

/// True when a `wl_pointer` binding may send `wl_pointer.release`.
///
/// `release` arrived in version 3. A version 2 binding has no destructor to
/// send, and sending one anyway makes the server answer `invalid version for
/// wl_pointer.release` and close the display connection, so the local proxy
/// is dropped instead.
pub fn pointerCanRelease(bound_version: u32) bool {
    return bound_version >= wl_pointer_release_since;
}

/// True when an `xdg_positioner` binding may send `xdg_positioner.set_reactive`.
///
/// The request arrived in version 3, and a binding older than that has no such
/// request to send. Sending one anyway makes the server answer `invalid version
/// for xdg_positioner.set_reactive` and close the display connection, so a
/// reactive positioner is refused by name on that path instead of sent.
pub fn positionerCanReact(bound_version: u32) bool {
    return bound_version >= since_version.xdg_positioner_set_reactive;
}

/// Request opcodes the adapters in this tree send by number, so the constant
/// that guards a request and the table entry it names cannot drift apart. Every
/// value is the index of that request in the interface's own method list, taken
/// from the protocol XML the table below transcribes.
pub const opcode = struct {
    /// `wl_seat.get_pointer`, request 0 of `wl_seat`, `wayland.xml` line 2079.
    /// It is a `new_id` request, so the argument is the `wl_pointer` the seat
    /// hands back, and its opcode is 0 because it is the first request.
    pub const wl_seat_get_pointer: u32 = 0;

    /// `wl_pointer.release`, request 1 of `wl_pointer`, `since="3"`. It
    /// carries `type="destructor"`, so sending it releases the local proxy
    /// with the message; see `pointerCanRelease`.
    pub const wl_pointer_release: u32 = 1;

    /// `wl_surface.attach`, `wayland.xml` line 1612.
    pub const wl_surface_attach: u32 = 1;
    /// `wl_surface.damage`, `wayland.xml` line 1630.
    pub const wl_surface_damage: u32 = 2;
    /// `wl_surface.set_opaque_region`, `wayland.xml` line 1666.
    pub const wl_surface_set_opaque_region: u32 = 4;
    /// `wl_surface.set_input_region`, `wayland.xml` line 1697.
    pub const wl_surface_set_input_region: u32 = 5;
    /// `wl_surface.commit`, `wayland.xml` line 2074. Surface state becomes
    /// effective only here, so every role in this tree reaches the wire through
    /// this one request.
    pub const wl_surface_commit: u32 = 6;
    /// `wl_surface.damage_buffer`, `wayland.xml` line 1806, since version 4.
    pub const wl_surface_damage_buffer: u32 = 9;

    /// `wl_compositor.create_surface`, `wayland.xml` line 1224.
    pub const wl_compositor_create_surface: u32 = 0;
    /// `wl_compositor.create_region`, `wayland.xml` line 1243.
    pub const wl_compositor_create_region: u32 = 1;

    /// `wl_region.add`, `wayland.xml` line 1930.
    pub const wl_region_add: u32 = 1;

    /// `xdg_wm_base.destroy`, `xdg-shell.xml` line 57.
    pub const xdg_wm_base_destroy: u32 = 0;
    /// `xdg_wm_base.create_positioner`, `xdg-shell.xml` line 67.
    pub const xdg_wm_base_create_positioner: u32 = 1;
    /// `xdg_wm_base.get_xdg_surface`, `xdg-shell.xml` line 76.
    pub const xdg_wm_base_get_xdg_surface: u32 = 2;
    /// `xdg_wm_base.pong`, `xdg-shell.xml` line 95. Answering the ping is what
    /// keeps `xdg_wm_base.unresponsive` from ending the connection.
    pub const xdg_wm_base_pong: u32 = 3;

    /// `xdg_positioner.destroy`, `xdg-shell.xml` line 151.
    pub const xdg_positioner_destroy: u32 = 0;
    /// `xdg_positioner.set_size`, `xdg-shell.xml` line 157.
    pub const xdg_positioner_set_size: u32 = 1;
    /// `xdg_positioner.set_anchor_rect`, `xdg-shell.xml` line 169.
    pub const xdg_positioner_set_anchor_rect: u32 = 2;
    /// `xdg_positioner.set_anchor`, `xdg-shell.xml` line 200.
    pub const xdg_positioner_set_anchor: u32 = 3;
    /// `xdg_positioner.set_gravity`, `xdg-shell.xml` line 225.
    pub const xdg_positioner_set_gravity: u32 = 4;
    /// `xdg_positioner.set_constraint_adjustment`, `xdg-shell.xml` line 330.
    pub const xdg_positioner_set_constraint_adjustment: u32 = 5;
    /// `xdg_positioner.set_offset`, `xdg-shell.xml` line 350.
    pub const xdg_positioner_set_offset: u32 = 6;
    /// `xdg_positioner.set_reactive`, `xdg-shell.xml` line 366, since version 3.
    /// The version 3 descriptor carries it, so the table can reach it.
    pub const xdg_positioner_set_reactive: u32 = 7;

    /// `xdg_surface.destroy`, `xdg-shell.xml` line 476.
    pub const xdg_surface_destroy: u32 = 0;
    /// `xdg_surface.get_popup`, `xdg-shell.xml` line 495.
    pub const xdg_surface_get_popup: u32 = 2;
    /// `xdg_surface.set_window_geometry`, `xdg-shell.xml` line 511.
    pub const xdg_surface_set_window_geometry: u32 = 3;
    /// `xdg_surface.ack_configure`, `xdg-shell.xml` line 560.
    pub const xdg_surface_ack_configure: u32 = 4;

    /// `xdg_popup.destroy`, `xdg-shell.xml` line 1280. Destroying the role
    /// object is also how a client dismisses its own popup.
    pub const xdg_popup_destroy: u32 = 0;
    /// `xdg_popup.grab`, `xdg-shell.xml` line 1290.
    pub const xdg_popup_grab: u32 = 1;
    /// `xdg_popup.reposition`, `xdg-shell.xml` line 1368, since version 3.
    pub const xdg_popup_reposition: u32 = 2;

    /// `xdg_system_bell_v1.destroy`, request 0 of `xdg-system-bell-v1.xml`. It
    /// carries `type="destructor"`, so the local proxy goes with the message
    /// and nothing has to drop it afterwards.
    pub const xdg_system_bell_destroy: u32 = 0;
    /// `xdg_system_bell_v1.ring`, request 1: the only request that does
    /// anything.
    pub const xdg_system_bell_ring: u32 = 1;
};

/// The one layer-surface request this tree sends by number rather than through
/// an inline table of its own, so the number and the descriptor entry it names
/// cannot drift apart.
pub const layer_surface_ack_configure_opcode: u32 = 6;

/// `zwlr_layer_surface_v1.destroy`, `wlr-layer-shell-unstable-v1.xml` line 321.
/// It has no since-version, so any binding may send it.
pub const layer_surface_destroy_opcode: u32 = 7;
/// `zwlr_layer_shell_v1.destroy`, `wlr-layer-shell-unstable-v1.xml` line 94.
/// It arrived in version 3, so `layerShellCanDestroy` guards it.
pub const layer_shell_destroy_opcode: u32 = 1;

/// `zwlr_layer_shell_v1.get_layer_surface`,
/// `wlr-layer-shell-unstable-v1.xml` line 39. It is opcode 0 and has no
/// since-version, so every binding this tree accepts may send it.
pub const layer_shell_get_layer_surface_opcode: u32 = 0;

/// The `zwlr_layer_surface_v1` requests this tree sends by number, so the
/// number and the descriptor entry it names cannot drift apart. Each is the
/// request's index in the interface's own method list, from
/// `wlr-layer-shell-unstable-v1.xml`.
pub const layer_surface_opcode = struct {
    /// `set_size`, line 122.
    pub const set_size: u32 = 0;
    /// `set_anchor`, line 139.
    pub const set_anchor: u32 = 1;
    /// `set_exclusive_zone`, line 152.
    pub const set_exclusive_zone: u32 = 2;
    /// `set_margin`, line 190.
    pub const set_margin: u32 = 3;
    /// `set_keyboard_interactivity`, line 269.
    pub const set_keyboard_interactivity: u32 = 4;
    /// `get_popup`, line 287.
    pub const get_popup: u32 = 5;
};

/// The `wl_output` events, in protocol opcode order, with the C listener
/// signature each one dispatches through. A layer surface listens to the output
/// it is placed on, so a mode change arrives as an event instead of a poll.
/// The slot order is the protocol's own: `geometry` is event 0 and `description`
/// is event 5, and libwayland dispatches by index.
pub const OutputListener = extern struct {
    geometry: *const fn (
        data: ?*anyopaque,
        output: *Proxy,
        x: i32,
        y: i32,
        physical_width: i32,
        physical_height: i32,
        subpixel: i32,
        transform: i32,
        make: [*:0]const u8,
        model: [*:0]const u8,
    ) callconv(.c) void,
    mode: *const fn (
        data: ?*anyopaque,
        output: *Proxy,
        flags: u32,
        width: i32,
        height: i32,
        refresh: i32,
    ) callconv(.c) void,
    done: *const fn (data: ?*anyopaque, output: *Proxy) callconv(.c) void,
    scale: *const fn (data: ?*anyopaque, output: *Proxy, factor: i32) callconv(.c) void,
    name: *const fn (data: ?*anyopaque, output: *Proxy, name: [*:0]const u8) callconv(.c) void,
    description: *const fn (
        data: ?*anyopaque,
        output: *Proxy,
        description: [*:0]const u8,
    ) callconv(.c) void,
};

/// `xdg_wm_base` version 3 requests and events in protocol opcode order.
///
/// The protocol is version 7 and no request or event arrived after version 1,
/// so a version 3 descriptor names exactly the whole interface. `ping` is the
/// event a client must answer with `pong`; a binding that ignores it earns
/// `xdg_wm_base.unresponsive`.
pub const xdg_wm_base_interface: Interface = .{
    .name = "xdg_wm_base",
    .version = 3,
    .method_count = 4,
    .methods = &.{
        .{ .name = "destroy", .signature = "", .types = &.{} },
        .{ .name = "create_positioner", .signature = "n", .types = &.{&xdg_positioner_interface} },
        .{ .name = "get_xdg_surface", .signature = "no", .types = &.{ &xdg_surface_interface, null } },
        .{ .name = "pong", .signature = "u", .types = &.{} },
    },
    .event_count = 1,
    .events = &.{
        .{ .name = "ping", .signature = "u", .types = &.{} },
    },
};

/// True when a `wl_compositor` binding may send `wl_compositor.release`.
///
/// The request arrived in version 7, so a version 6 binding — what niri
/// advertises — has no destructor to send. Asking for one anyway is a fatal
/// protocol error: the server answers `invalid version for
/// wl_compositor.release` and closes the display connection.
pub fn compositorCanRelease(bound_version: u32) bool {
    return bound_version >= since_version.wl_compositor_release;
}

/// True when a `wl_output` binding may send `wl_output.release`.
pub fn outputCanRelease(bound_version: u32) bool {
    return bound_version >= since_version.wl_output_release;
}

/// True when a `zwlr_layer_shell_v1` binding may send `destroy`.
pub fn layerShellCanDestroy(bound_version: u32) bool {
    return bound_version >= since_version.zwlr_layer_shell_v1_destroy;
}

/// Core registry descriptor used by the inline libwayland request wrappers.
pub const wl_registry_interface: Interface = .{
    .name = "wl_registry",
    .version = 1,
    .method_count = 1,
    .methods = &.{.{ .name = "bind", .signature = "usun", .types = &.{ null, null, null, null } }},
    .event_count = 2,
    .events = &.{
        .{ .name = "global", .signature = "usu", .types = &.{ null, null, null } },
        .{ .name = "global_remove", .signature = "u", .types = &.{null} },
    },
};

/// `xdg_positioner` version 3 requests in protocol opcode order.
///
/// The order is the protocol's own, from `xdg-shell.xml`: `destroy` is opcode 0
/// (line 151) through `set_offset` opcode 6 (line 350). An opcode is the index
/// into this table, so an entry at the wrong index is sent under the wrong wire
/// name. Version 3 adds exactly three requests, `set_reactive` (line 370),
/// `set_parent_size` (line 381) and `set_parent_configure` (line 397), each
/// `since="3"`, so a version 3 descriptor carries all ten. A popup is placed by
/// the rules the compositor copies out of this object at `xdg_surface.get_popup`,
/// so the table is on the popup's critical path rather than documentation.
pub const xdg_positioner_interface: Interface = .{
    .name = "xdg_positioner",
    .version = 3,
    .method_count = 10,
    .methods = &.{
        .{ .name = "destroy", .signature = "", .types = &.{} },
        .{ .name = "set_size", .signature = "ii", .types = &.{} },
        .{ .name = "set_anchor_rect", .signature = "iiii", .types = &.{} },
        .{ .name = "set_anchor", .signature = "u", .types = &.{} },
        .{ .name = "set_gravity", .signature = "u", .types = &.{} },
        .{ .name = "set_constraint_adjustment", .signature = "u", .types = &.{} },
        .{ .name = "set_offset", .signature = "ii", .types = &.{} },
        .{ .name = "set_reactive", .signature = "", .types = &.{} },
        .{ .name = "set_parent_size", .signature = "ii", .types = &.{} },
        .{ .name = "set_parent_configure", .signature = "u", .types = &.{} },
    },
    .event_count = 0,
    .events = &.{},
};

/// `xdg_surface` version 3 requests in protocol opcode order.
///
/// `set_window_geometry` is opcode 3 (`xdg-shell.xml` line 511) and pushes
/// `ack_configure` to opcode 4 (line 560). Dropping that entry would name the
/// wrong request at index 3.
///
/// `get_popup` takes three arguments and carries a type entry for each, so the
/// two `object` entries name null. libwayland reads a type entry only to name a
/// `new_id` object, never to check an `object` argument, and naming the parent
/// `xdg_surface` inside this value would make the descriptor depend on itself.
pub const xdg_surface_interface: Interface = .{
    .name = "xdg_surface",
    .version = 3,
    .method_count = 5,
    .methods = &.{
        .{ .name = "destroy", .signature = "", .types = &.{} },
        .{ .name = "get_toplevel", .signature = "n", .types = &.{&xdg_toplevel_interface} },
        .{ .name = "get_popup", .signature = "noo", .types = &.{ &xdg_popup_interface, null, null } },
        .{ .name = "set_window_geometry", .signature = "iiii", .types = &.{} },
        .{ .name = "ack_configure", .signature = "u", .types = &.{} },
    },
    .event_count = 1,
    .events = &.{
        .{ .name = "configure", .signature = "u", .types = &.{} },
    },
};

/// `xdg_popup` version 3 requests and events in protocol opcode order.
///
/// `reposition` (line 1368) and `repositioned` (line 1398) are `since="3"`, so
/// version 3 carries all three requests and all three events; nothing later
/// exists.
pub const xdg_popup_interface: Interface = .{
    .name = "xdg_popup",
    .version = 3,
    .method_count = 3,
    .methods = &.{
        .{ .name = "destroy", .signature = "", .types = &.{} },
        .{ .name = "grab", .signature = "ou", .types = &.{&wl_seat_interface} },
        .{ .name = "reposition", .signature = "ou", .types = &.{&xdg_positioner_interface} },
    },
    .event_count = 3,
    .events = &.{
        .{ .name = "configure", .signature = "iiii", .types = &.{} },
        .{ .name = "popup_done", .signature = "", .types = &.{} },
        .{ .name = "repositioned", .signature = "u", .types = &.{} },
    },
};

/// `xdg_toplevel` version 3 requests in protocol opcode order.
/// `set_parent` takes an existing object rather than a new id, so libwayland
/// never dereferences that type entry and a null placeholder breaks the cycle.
pub const xdg_toplevel_interface: Interface = .{
    .name = "xdg_toplevel",
    .version = 3,
    .method_count = 12,
    .methods = &.{
        .{ .name = "destroy", .signature = "", .types = &.{} },
        .{ .name = "set_parent", .signature = "?o", .types = &.{null} },
        .{ .name = "set_title", .signature = "s", .types = &.{} },
        .{ .name = "set_app_id", .signature = "s", .types = &.{} },
        .{ .name = "show_window_menu", .signature = "ouii", .types = &.{&wl_seat_interface} },
        .{ .name = "move", .signature = "ou", .types = &.{&wl_seat_interface} },
        .{ .name = "resize", .signature = "ouu", .types = &.{&wl_seat_interface} },
        .{ .name = "set_max_size", .signature = "ii", .types = &.{} },
        .{ .name = "set_min_size", .signature = "ii", .types = &.{} },
        .{ .name = "set_maximized", .signature = "", .types = &.{} },
        .{ .name = "unset_maximized", .signature = "", .types = &.{} },
        .{ .name = "set_fullscreen", .signature = "?o", .types = &.{&wl_output_interface} },
    },
    .event_count = 2,
    .events = &.{
        .{ .name = "configure", .signature = "iia", .types = &.{&wl_array_interface} },
        .{ .name = "close", .signature = "", .types = &.{} },
    },
};

// The interface below is transcribed from `xdg-system-bell-v1.xml`, the staging
// extension published at
// <https://github.com/cocasoftware/wayland-protocols/blob/main/staging/xdg-system-bell/xdg-system-bell-v1.xml>
/// and documented at <https://wayland.app/protocols/xdg-system-bell-v1>. That
// declaration is a substantial portion of the protocol, so its notice travels
// with it here, verbatim from the XML:
//
//     Copyright © 2016, 2023 Red Hat
//
//     Permission is hereby granted, free of charge, to any person obtaining a
//     copy of this software and associated documentation files (the "Software"),
//     to deal in the Software without restriction, including without limitation
//     the rights to use, copy, modify, merge, publish, distribute, sublicense,
//     and/or sell copies of the Software, and to permit persons to whom the
//     Software is furnished to do so, subject to the following conditions:
//
//     The above copyright notice and this permission notice (including the
//     next paragraph) shall be included in all copies or substantial portions
//     of the Software.
//
//     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
//     OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//     MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
//     NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
//     DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
//     OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
//     THE USE OR OTHER DEALINGS IN THE SOFTWARE.

/// `xdg_system_bell_v1` version 1 requests in protocol opcode order.
///
/// The interface is version 1 and declares no events at all, so this table is
/// the whole of what a binding can send or receive. `ring` takes one nullable
/// `wl_surface`, which is a `?o` on the wire; libwayland reads a type entry
/// only to name a `new_id` argument, never an `object` one, so the null
/// placeholder here is the truthful entry for a surface it must not dereference.
///
/// The protocol lets a compositor answer a ring with a sound, with a visual
/// cue, or with nothing at all, so a request that reached the compositor is
/// not evidence that anything was heard.
pub const system_bell_interface: Interface = .{
    .name = "xdg_system_bell_v1",
    .version = 1,
    .method_count = 2,
    .methods = &.{
        .{ .name = "destroy", .signature = "", .types = &.{} },
        .{ .name = "ring", .signature = "?o", .types = &.{null} },
    },
    .event_count = 0,
    .events = &.{},
};

/// `zwlr_layer_shell_v1` version 4 requests in protocol opcode order.
///
/// The protocol is version 5; version 4 covers every request below, the
/// highest since-version being `destroy` at version 3.
pub const layer_shell_interface: Interface = .{
    .name = "zwlr_layer_shell_v1",
    .version = 4,
    .method_count = 2,
    .methods = &.{
        .{ .name = "get_layer_surface", .signature = "no?ous", .types = &.{
            &layer_surface_interface, &wl_surface_interface, &wl_output_interface, null, null,
        } },
        // `destroy` exists since version 3; see `layerShellCanDestroy`.
        .{ .name = "destroy", .signature = "", .types = &.{} },
    },
    .event_count = 0,
    .events = &.{},
};

/// `zwlr_layer_surface_v1` version 4 requests and events in protocol order.
pub const layer_surface_interface: Interface = .{
    .name = "zwlr_layer_surface_v1",
    .version = 4,
    .method_count = 9,
    .methods = &.{
        .{ .name = "set_size", .signature = "uu", .types = &.{} },
        .{ .name = "set_anchor", .signature = "u", .types = &.{} },
        .{ .name = "set_exclusive_zone", .signature = "i", .types = &.{} },
        .{ .name = "set_margin", .signature = "iiii", .types = &.{} },
        .{ .name = "set_keyboard_interactivity", .signature = "u", .types = &.{} },
        .{ .name = "get_popup", .signature = "o", .types = &.{&xdg_popup_interface} },
        .{ .name = "ack_configure", .signature = "u", .types = &.{} },
        .{ .name = "destroy", .signature = "", .types = &.{} },
        .{ .name = "set_layer", .signature = "u", .types = &.{} },
    },
    .event_count = 2,
    .events = &.{
        .{ .name = "configure", .signature = "uuu", .types = &.{} },
        .{ .name = "closed", .signature = "", .types = &.{} },
    },
};

/// `wl_seat` version 7 requests and events in protocol opcode order.
///
/// Version 7 is a subset of the protocol version 11 that covers every entry
/// below: `release` arrived in version 5 and `name` in version 2. `release`
/// follows three `get_*` requests and so is opcode 3, not opcode 0
/// (`wayland.xml` line 2129). All three are `new_id` requests. `get_pointer`
/// names a `wl_pointer` this tree does make, so that entry carries the
/// `wl_pointer` descriptor; `get_keyboard` and `get_touch` name objects this
/// tree never creates, so each of their type entries stays a null
/// placeholder: libwayland reads a type entry only to name a new object, and
/// none of those two is ever made.
pub const wl_seat_interface: Interface = .{
    .name = "wl_seat",
    .version = 7,
    .method_count = 4,
    .methods = &.{
        .{ .name = "get_pointer", .signature = "n", .types = &.{&wl_pointer_interface} },
        .{ .name = "get_keyboard", .signature = "n", .types = &.{null} },
        .{ .name = "get_touch", .signature = "n", .types = &.{null} },
        // `release` is valid only from version 5; callers gate its use.
        .{ .name = "release", .signature = "5", .types = &.{} },
    },
    .event_count = 2,
    .events = &.{
        .{ .name = "capabilities", .signature = "u", .types = &.{} },
        .{ .name = "name", .signature = "2s", .types = &.{} },
    },
};

/// `wl_pointer` version 4 requests and events in protocol opcode order.
///
/// `set_cursor` is request 0 and `release` request 1 (`since="3"`). The events
/// run from `enter` at 0 to `axis` at 4; `frame`, `axis_source`, `axis_stop`
/// and `axis_discrete` all arrived in version 5, so a version 4 descriptor
/// names exactly the five events a client of that version can be sent, and
/// libwayland dispatches an event by its index in this list.
///
/// Object type entries identify `wl_surface` at its actual argument index.
/// Serial numbers precede surface references; only the cursor surface is
/// nullable. A pointer inherits its seat's bound version, so callers must not
/// bind a seat newer than the pointer descriptor supports.
pub const wl_pointer_interface: Interface = .{
    .name = "wl_pointer",
    .version = 4,
    .method_count = 2,
    .methods = &.{
        .{ .name = "set_cursor", .signature = "u?oii", .types = &.{ null, &wl_surface_interface, null, null } },
        .{ .name = "release", .signature = "3", .types = &.{} },
    },
    .event_count = 5,
    .events = &.{
        .{ .name = "enter", .signature = "uoff", .types = &.{ null, &wl_surface_interface, null, null } },
        .{ .name = "leave", .signature = "uo", .types = &.{ null, &wl_surface_interface } },
        .{ .name = "motion", .signature = "uff", .types = &.{ null, null, null } },
        .{ .name = "button", .signature = "uuuu", .types = &.{ null, null, null, null } },
        .{ .name = "axis", .signature = "uuf", .types = &.{ null, null, null } },
    },
};

/// The `wl_pointer` events, in protocol opcode order, with the C listener
/// signature each one dispatches through. The slot order is the protocol's
/// own: `enter` is event 0 and `axis` is event 4, and libwayland dispatches by
/// index, so a table whose slots are in another order attributes every event
/// to the wrong handler.
pub const PointerListener = extern struct {
    enter: *const fn (
        data: ?*anyopaque,
        pointer: *Proxy,
        serial: u32,
        surface: *Proxy,
        surface_x: i32,
        surface_y: i32,
    ) callconv(.c) void,
    leave: *const fn (
        data: ?*anyopaque,
        pointer: *Proxy,
        serial: u32,
        surface: *Proxy,
    ) callconv(.c) void,
    motion: *const fn (
        data: ?*anyopaque,
        pointer: *Proxy,
        time: u32,
        surface_x: i32,
        surface_y: i32,
    ) callconv(.c) void,
    button: *const fn (
        data: ?*anyopaque,
        pointer: *Proxy,
        serial: u32,
        time: u32,
        button: u32,
        state: u32,
    ) callconv(.c) void,
    axis: *const fn (
        data: ?*anyopaque,
        pointer: *Proxy,
        time: u32,
        axis: u32,
        value: i32,
    ) callconv(.c) void,
};

/// The `wl_seat` events, in protocol opcode order. A seat answers its own
/// capabilities once and then whenever they change, and that event is what
/// says whether this connection is offered a pointer at all.
pub const SeatListener = extern struct {
    capabilities: *const fn (
        data: ?*anyopaque,
        seat: *Proxy,
        capabilities: u32,
    ) callconv(.c) void,
    name: *const fn (data: ?*anyopaque, seat: *Proxy, name: [*:0]const u8) callconv(.c) void,
};

/// The `wl_pointer` and `wl_seat` wire values this tree compares against, so a
/// listener and the guard that reads them cannot drift apart.
pub const pointer_wire = struct {
    /// `WL_SEAT_CAPABILITY_POINTER`, `wayland.xml` line 2091: the seat offers
    /// a pointer. Without this bit there is no `wl_pointer` to hear a button
    /// press on, so no serial this tree could send is a user-event serial.
    pub const seat_capability_pointer: u32 = 1;
    /// `WL_POINTER_BUTTON_STATE_PRESS`, `wayland.xml` line 1976: the button
    /// went down. This is the only button state whose serial `xdg_popup.grab`
    /// accepts.
    pub const button_state_press: u32 = 1;
    /// `WL_POINTER_BUTTON_STATE_RELEASE`, `wayland.xml` line 1973: the button
    /// came up. Its serial names an event no grab may be taken from.
    pub const button_state_release: u32 = 0;
};

/// `wl_compositor` requests in protocol opcode order.
///
/// The protocol is version 7 and `release` is the only request added after
/// version 1, so a truthful descriptor declares 7: declaring less would claim
/// a request its own version could never reach.
pub const wl_compositor_interface: Interface = .{
    .name = "wl_compositor",
    .version = 7,
    .method_count = 3,
    .methods = &.{
        .{ .name = "create_surface", .signature = "n", .types = &.{&wl_surface_interface} },
        .{ .name = "create_region", .signature = "n", .types = &.{&wl_region_interface} },
        // `release` exists since version 7; see `compositorCanRelease`.
        .{ .name = "release", .signature = "", .types = &.{} },
    },
    .event_count = 0,
    .events = &.{},
};

/// `wl_output` requests and events in protocol opcode order.
///
/// Version 4 is the protocol version: `name` and `description` arrived in 4
/// and nothing later exists.
pub const wl_output_interface: Interface = .{
    .name = "wl_output",
    .version = 4,
    .method_count = 1,
    .methods = &.{
        // `release` exists since version 3; see `outputCanRelease`.
        .{ .name = "release", .signature = "", .types = &.{} },
    },
    .event_count = 6,
    .events = &.{
        .{ .name = "geometry", .signature = "iiiiissi", .types = &.{ null, null, null, null, null, null, null, null } },
        .{ .name = "mode", .signature = "uiii", .types = &.{ null, null, null, null } },
        // `done` and `scale` arrived in version 2, `name` and `description` in 4.
        .{ .name = "done", .signature = "", .types = &.{} },
        .{ .name = "scale", .signature = "i", .types = &.{null} },
        .{ .name = "name", .signature = "s", .types = &.{null} },
        .{ .name = "description", .signature = "s", .types = &.{null} },
    },
};

/// `wl_surface` version 4 requests and events in protocol opcode order.
///
/// `set_opaque_region` is opcode 4 (`wayland.xml` line 1666), `set_input_region`
/// is opcode 5 (line 1697) and `commit` is opcode 6 (line 2074). The table runs
/// to the last request version 4 added, `damage_buffer` at opcode 9 (line
/// 1806, `since="4"`), and to both events that exist in version 4, `enter` and
/// `leave`. `commit` is on the critical path of every role in this tree: surface
/// state is double-buffered and takes effect only at the commit, which is why
/// the adapters send their opcode constants rather than typing the number.
pub const wl_surface_interface: Interface = .{
    .name = "wl_surface",
    .version = 4,
    .method_count = 10,
    .methods = &.{
        .{ .name = "destroy", .signature = "", .types = &.{} },
        .{ .name = "attach", .signature = "?oii", .types = &.{} },
        .{ .name = "damage", .signature = "iiii", .types = &.{} },
        .{ .name = "frame", .signature = "n", .types = &.{&wl_callback_interface} },
        .{ .name = "set_opaque_region", .signature = "?o", .types = &.{&wl_region_interface} },
        .{ .name = "set_input_region", .signature = "?o", .types = &.{&wl_region_interface} },
        .{ .name = "commit", .signature = "", .types = &.{} },
        // `set_buffer_transform` arrived in version 2, `set_buffer_scale` in 3
        // and `damage_buffer` in 4.
        .{ .name = "set_buffer_transform", .signature = "i", .types = &.{} },
        .{ .name = "set_buffer_scale", .signature = "i", .types = &.{} },
        .{ .name = "damage_buffer", .signature = "iiii", .types = &.{} },
    },
    .event_count = 2,
    .events = &.{
        .{ .name = "enter", .signature = "o", .types = &.{&wl_output_interface} },
        .{ .name = "leave", .signature = "o", .types = &.{&wl_output_interface} },
    },
};

/// `wl_region` version 4 requests in protocol opcode order.
///
/// The protocol is version 7 and all three requests exist since version 1, so a
/// version 4 descriptor names exactly the requests a client may send to a
/// region. The version matters because a region is created by
/// `wl_compositor.create_region` at the compositor's bound version, and a
/// descriptor that claimed version 1 for a proxy created at version 6 would
/// misreport the object it describes.
pub const wl_region_interface: Interface = .{
    .name = "wl_region",
    .version = 4,
    .method_count = 3,
    .methods = &.{
        .{ .name = "destroy", .signature = "", .types = &.{} },
        .{ .name = "add", .signature = "iiii", .types = &.{} },
        .{ .name = "subtract", .signature = "iiii", .types = &.{} },
    },
    .event_count = 0,
    .events = &.{},
};

pub const wl_callback_interface: Interface = .{
    .name = "wl_callback",
    .version = 1,
    .method_count = 0,
    .methods = &.{},
    .event_count = 1,
    .events = &.{
        .{ .name = "done", .signature = "u", .types = &.{} },
    },
};

pub const wl_array_interface: Interface = .{
    .name = "wl_array",
    .version = 1,
    .method_count = 0,
    .methods = &.{},
    .event_count = 0,
    .events = &.{},
};

test "api-w22 Wayland requests honor advertised version boundaries" {
    try std.testing.expect(!compositorCanRelease(4));
    try std.testing.expect(!compositorCanRelease(6));
    try std.testing.expect(compositorCanRelease(7));
    try std.testing.expect(compositorCanRelease(12));
    try std.testing.expect(!outputCanRelease(2));
    try std.testing.expect(outputCanRelease(3));
    try std.testing.expect(!layerShellCanDestroy(2));
    try std.testing.expect(layerShellCanDestroy(3));
    try std.testing.expect(!positionerCanReact(2));
    try std.testing.expect(positionerCanReact(3));
    try std.testing.expect(!pointerCanRelease(1));
    try std.testing.expect(!pointerCanRelease(2));
    try std.testing.expect(pointerCanRelease(3));
    try std.testing.expect(pointerCanRelease(4));
}

test "api-w22 wayland loader reports a missing client library distinctly" {
    const Fake = struct {
        var attempts: u32 = 0;
        fn loadObject(context: *anyopaque, soname: [:0]const u8) anyerror!Object {
            _ = context;
            _ = soname;
            attempts += 1;
            return error.LibraryNotFound;
        }
    };
    Fake.attempts = 0;
    var context: u8 = 0;
    const loader: Loader = .{
        .context = @ptrCast(&context),
        .vtable = &Loader.VTable{ .loadObject = Fake.loadObject },
    };
    try std.testing.expectError(error.LibraryNotFound, Api.load(loader));
    // Every candidate soname must be attempted before reporting failure.
    try std.testing.expectEqual(@as(u32, 2), Fake.attempts);
}

// The mapping is held for the whole lifetime of the `Api` and released exactly
// once by `deinit`. A second `deinit` is deliberately not exercised: like every
// `deinit` in this tree it poisons the value, so it is a once-only operation
// rather than an idempotent one.

test "api-w22 Wayland loader keeps its library mapped until proxy users release it" {
    const Fake = struct {
        const Self = @This();

        unloads: u32 = 0,

        fn loadObject(context: *anyopaque, _: [:0]const u8) anyerror!Object {
            return .{
                .context = context,
                .vtable = &Object.VTable{
                    .loadFunction = loadFunction,
                    .unload = unload,
                },
            };
        }

        fn loadFunction(_: *anyopaque, _: [:0]const u8) anyerror!*const anyopaque {
            // No entry point is called; only loader ownership is exercised.
            return @ptrFromInt(0x1000);
        }

        fn unload(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.unloads += 1;
        }
    };
    var fake: Fake = .{};
    var api = try Api.load(.{
        .context = &fake,
        .vtable = &Loader.VTable{ .loadObject = Fake.loadObject },
    });
    // Nothing has been released yet, so the mapping is still live.
    api.deinit();
    try std.testing.expectEqual(@as(u32, 1), fake.unloads);
}
