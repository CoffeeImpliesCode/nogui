//! Authoritative X11 XKB keyboard-layout identity, read through SDL.
//!
//! SDL 3.4 exposes keymap conversion but has no keyboard-layout name or
//! identifier call, and a keyboard *device* name is not a layout name. The
//! X11 server SDL is already connected to is the authority, so this module
//! asks it through two documented routes and invents nothing:
//!
//!   * SDL publishes the X11 `Display` behind a window as
//!     `SDL_PROP_WINDOW_X11_DISPLAY_POINTER`, which the bindings expose as
//!     `Window.Properties.x11_display`. Every XKB reply below therefore comes
//!     from the same connection the window lives on, and no second connection
//!     (and no XAUTH handling) is needed.
//!   * The XKB extension on that connection answers the two facts a layout
//!     identity is made of: `XkbGetState` reports the core keyboard's active
//!     group, and `XkbGetNames` returns the atoms the server gave its
//!     keymap. The `symbols` atom names the compiled symbols component
//!     ("pc+us+inet(evdev)"), and the layout symbol of the active group is
//!     that group's entry in the list.
//!
//! libX11 is resolved through SDL's own loader (`SDL_LoadObject`) with the
//! soname the X11 video driver already mapped, so this code and SDL drive one
//! copy of the library. libxkbcommon is deliberately not used: its X11 module
//! needs an `xcb_connection_t`, which SDL does not publish and which no
//! libxkbcommon on this host exports, so it could only answer with a second
//! connection.
const std = @import("std");
const sdl3 = @import("sdl3");

/// Opaque X11 `Display *`. Only libX11 ever dereferences it.
pub const Display = opaque {};

/// The XKB core keyboard device spec, `XkbUseCoreKbd` from `XKB.h`.
pub const use_core_keyboard: u32 = 0x0100;
/// `XkbSymbolsNameMask` from `XKB.h`: the compiled symbols component.
pub const symbols_name_mask: u32 = 1 << 2;

/// Bytes kept for each reported string. An XKB component name is short; a
/// longer server answer is truncated rather than dropped, and the truncation
/// is visible because the reported name stops mid-component.
pub const buffer_len = 96;

/// What the X11 XKB extension could tell this process.
pub const Status = enum {
    /// No X11 display connection was offered, or libX11 could not be resolved
    /// through SDL's loader. Nothing here knows what the layout is.
    no_native_access,
    /// The connection exists, but its XKB extension did not answer. The
    /// layout stays unknown instead of being guessed.
    xkb_unavailable,
    /// The XKB extension answered. `name` and `identifier` hold what it
    /// reported; either may still be absent if the server named nothing.
    x11_xkb,
};

/// The reported identity, owned by the caller so the reported slices stay
/// valid for as long as this value lives.
pub const Identity = struct {
    status: Status = .no_native_access,
    /// The core keyboard's active XKB group, as `XkbGetState` reported it.
    group: u8 = 0,
    name_buffer: [buffer_len]u8 = [_]u8{0} ** buffer_len,
    name_len: usize = 0,
    identifier_buffer: [buffer_len]u8 = [_]u8{0} ** buffer_len,
    identifier_len: usize = 0,

    /// The `symbols` component name the server compiled, for example
    /// "pc+us+inet(evdev)". Null unless XKB answered with one.
    pub fn name(self: *const Identity) ?[]const u8 {
        if (self.status != .x11_xkb or self.name_len == 0) return null;
        return self.name_buffer[0..self.name_len];
    }

    /// The layout symbol of the active group, for example "us" or "de(neo)".
    /// Null when XKB named nothing, or when the symbols name leaves the
    /// layout component ambiguous: a two-component name like "us+intl" is a
    /// layout with a variant or a base with a layout, and this must not pick.
    pub fn identifier(self: *const Identity) ?[]const u8 {
        if (self.status != .x11_xkb or self.identifier_len == 0) return null;
        return self.identifier_buffer[0..self.identifier_len];
    }
};

/// Reads the XKB layout identity from an X11 display connection.
///
/// Never fails: a connection without XKB, a server that refuses, and a
/// missing library all land in `Identity.status`, because "unknown" is a
/// result this host has to be able to report.
pub fn probe(display: *Display, out: *Identity) void {
    out.* = .{};
    const api = Api.load() orelse return;
    defer api.deinit();

    const connection: ?*anyopaque = @ptrCast(display);
    var opcode: c_int = 0;
    var event_base: c_int = 0;
    var error_base: c_int = 0;
    var major: c_int = 0;
    var minor: c_int = 0;
    if (api.xkb_query_extension(connection, &opcode, &event_base, &error_base, &major, &minor) == 0) {
        out.status = .xkb_unavailable;
        return;
    }
    // XKBlib sends the extension's own requests, and it requires the client
    // to have asked for the extension first. This is idempotent, so it is
    // also fine when SDL already did it for its own keyboard handling.
    var used_major: c_int = 0;
    var used_minor: c_int = 0;
    if (api.xkb_use_extension(connection, &used_major, &used_minor) == 0) {
        out.status = .xkb_unavailable;
        return;
    }

    var state: State = std.mem.zeroes(State);
    if (api.xkb_get_state(connection, use_core_keyboard, &state) != 0) {
        out.status = .xkb_unavailable;
        return;
    }
    out.group = state.group;

    // `XkbGetNames` takes the device from the descriptor, not from its own
    // argument list, so an unset device spec makes the server answer
    // BadValue instead of the names.
    // `XkbGetNames` fills only the masks it was asked for and takes the device
    // from the descriptor, so the three fields this request does not set stay
    // zero rather than undefined.
    var desc: Desc = .{
        .dpy = connection,
        .flags = 0,
        .device_spec = @intCast(use_core_keyboard),
        .min_key_code = 0,
        .max_key_code = 0,
        .ctrls = null,
        .server = null,
        .map = null,
        .indicators = null,
        .names = null,
        .compat = null,
        .geom = null,
    };
    defer api.xkb_free_names(&desc, symbols_name_mask, 1);
    if (api.xkb_alloc_names(&desc, symbols_name_mask, 0, 0) != 0) {
        out.status = .xkb_unavailable;
        return;
    }
    if (api.xkb_get_names(connection, symbols_name_mask, &desc) != 0) {
        out.status = .xkb_unavailable;
        return;
    }
    const names_ptr = desc.names orelse {
        out.status = .xkb_unavailable;
        return;
    };
    const names: *NamesRecord = @ptrCast(@alignCast(names_ptr));
    if (names.symbols == 0) {
        out.status = .xkb_unavailable;
        return;
    }
    const server_name = api.x_get_atom_name(connection, names.symbols) orelse {
        out.status = .xkb_unavailable;
        return;
    };
    defer _ = api.x_free(@ptrCast(@constCast(server_name)));

    const text = std.mem.span(server_name);
    out.name_len = @min(text.len, buffer_len);
    @memcpy(out.name_buffer[0..out.name_len], text[0..out.name_len]);
    if (layoutSymbol(text, state.group)) |identifier| {
        out.identifier_len = @min(identifier.len, buffer_len);
        @memcpy(out.identifier_buffer[0..out.identifier_len], identifier[0..out.identifier_len]);
    }
    out.status = .x11_xkb;
}

/// The layout symbol of `group` inside an XKB `symbols` component name.
///
/// The name is a '+'-separated component list: a base, then the layout list,
/// then the options. One component is the whole layout list ("de(neo)"), two
/// leave base and layout indistinguishable ("us+intl"), and three or more put
/// the layout list in the middle ("pc+us+inet(evdev)"). Inside the list the
/// groups are comma separated, and a group past the end of the list is the one
/// XKB keeps the pointer in.
pub fn layoutSymbol(symbols_name: []const u8, group: u8) ?[]const u8 {
    var rest = symbols_name;
    var first: []const u8 = "";
    var second: []const u8 = "";
    var count: usize = 0;
    while (count < 3) {
        const end = std.mem.indexOfScalar(u8, rest, '+') orelse rest.len;
        if (count == 0) first = rest[0..end];
        if (count == 1) second = rest[0..end];
        count += 1;
        if (end == rest.len) break;
        rest = rest[end + 1 ..];
    }
    const layouts: []const u8 = switch (count) {
        0 => return null,
        1 => first,
        2 => return null,
        else => second,
    };
    if (layouts.len == 0) return null;

    // The layout list holds one comma-separated entry per group, and an entry
    // ends at the next comma or at the end of the list. A group past the end
    // of the list is the entry XKB keeps the pointer in, so the walk stops
    // there instead of running past it.
    var entry = layouts;
    var index: u8 = 0;
    while (index < group) : (index += 1) {
        const comma = std.mem.indexOfScalar(u8, entry, ',') orelse break;
        entry = entry[comma + 1 ..];
    }
    const end = std.mem.indexOfScalar(u8, entry, ',') orelse entry.len;
    // An empty entry names no layout, so it is as unreportable as no name.
    if (end == 0) return null;
    return entry[0..end];
}

/// C layout of `XkbStateRec` from `XKBstr.h`.
const State = extern struct {
    group: u8,
    locked_group: u8,
    base_group: u16,
    latched_group: u16,
    mods: u8,
    base_mods: u8,
    latched_mods: u8,
    locked_mods: u8,
    compat_state: u8,
    grab_mods: u8,
    compat_grab_mods: u8,
    lookup_mods: u8,
    compat_lookup_mods: u8,
    ptr_buttons: u16,
};

/// C layout of `XkbDescRec` from `XKBstr.h`.
const Desc = extern struct {
    dpy: ?*anyopaque,
    flags: u16,
    device_spec: u16,
    min_key_code: u8,
    max_key_code: u8,
    ctrls: ?*anyopaque,
    server: ?*anyopaque,
    map: ?*anyopaque,
    indicators: ?*anyopaque,
    names: ?*anyopaque,
    compat: ?*anyopaque,
    geom: ?*anyopaque,
};

/// The leading `XkbNamesRec` atoms from `XKBstr.h`. `XkbGetNames` fills the
/// record, and only `symbols` is asked for, so the other atoms stay zero.
const NamesRecord = extern struct {
    keycodes: c_ulong,
    geometry: c_ulong,
    symbols: c_ulong,
    types: c_ulong,
};

const XkbQueryExtensionFn = *const fn (
    ?*anyopaque,
    *c_int,
    *c_int,
    *c_int,
    *c_int,
    *c_int,
) callconv(.c) c_int;
const XkbUseExtensionFn = *const fn (?*anyopaque, *c_int, *c_int) callconv(.c) c_int;
const XkbGetStateFn = *const fn (?*anyopaque, u32, *State) callconv(.c) c_int;
const XkbAllocNamesFn = *const fn (*Desc, u32, c_int, c_int) callconv(.c) c_int;
const XkbGetNamesFn = *const fn (?*anyopaque, u32, *Desc) callconv(.c) c_int;
const XkbFreeNamesFn = *const fn (*Desc, u32, c_int) callconv(.c) void;
const XGetAtomNameFn = *const fn (?*anyopaque, c_ulong) callconv(.c) ?[*:0]const u8;
const XFreeFn = *const fn (?*anyopaque) callconv(.c) c_int;

/// Resolved libX11 entry points. Every field is filled from the object that
/// stays mapped until `deinit`, so no call can outlive its own library.
pub const Api = struct {
    object: sdl3.SharedObject,
    xkb_query_extension: XkbQueryExtensionFn,
    xkb_use_extension: XkbUseExtensionFn,
    xkb_get_state: XkbGetStateFn,
    xkb_alloc_names: XkbAllocNamesFn,
    xkb_get_names: XkbGetNamesFn,
    xkb_free_names: XkbFreeNamesFn,
    x_get_atom_name: XGetAtomNameFn,
    x_free: XFreeFn,

    /// The sonames the X11 driver may have mapped, in the order it tries them.
    pub const candidate_sonames = [_][:0]const u8{
        "libX11.so.6",
        "libX11.so",
    };

    /// Resolves through SDL's loader, so the mapping is the one the X11 video
    /// driver already holds. Null when libX11 is absent or lacks an entry
    /// point; a partially resolved table is never returned.
    pub fn load() ?Api {
        for (candidate_sonames) |soname| {
            const object = sdl3.SharedObject.load(soname) catch continue;
            const api: Api = .{
                .object = object,
                .xkb_query_extension = symbol(XkbQueryExtensionFn, object, "XkbQueryExtension") orelse {
                    object.unload();
                    continue;
                },
                .xkb_use_extension = symbol(XkbUseExtensionFn, object, "XkbUseExtension") orelse {
                    object.unload();
                    continue;
                },
                .xkb_get_state = symbol(XkbGetStateFn, object, "XkbGetState") orelse {
                    object.unload();
                    continue;
                },
                .xkb_alloc_names = symbol(XkbAllocNamesFn, object, "XkbAllocNames") orelse {
                    object.unload();
                    continue;
                },
                .xkb_get_names = symbol(XkbGetNamesFn, object, "XkbGetNames") orelse {
                    object.unload();
                    continue;
                },
                .xkb_free_names = symbol(XkbFreeNamesFn, object, "XkbFreeNames") orelse {
                    object.unload();
                    continue;
                },
                .x_get_atom_name = symbol(XGetAtomNameFn, object, "XGetAtomName") orelse {
                    object.unload();
                    continue;
                },
                .x_free = symbol(XFreeFn, object, "XFree") orelse {
                    object.unload();
                    continue;
                },
            };
            return api;
        }
        return null;
    }

    /// Releases the mapping SDL's loader opened. The prototype's pointers stop
    /// being valid here, which is why one probe owns its whole table.
    pub fn deinit(self: Api) void {
        self.object.unload();
    }
};

fn symbol(comptime Proto: type, object: sdl3.SharedObject, name: [:0]const u8) ?Proto {
    const raw = object.loadFunction(name) catch return null;
    return @ptrCast(@alignCast(raw));
}

test "layout symbol survives the shapes an XKB symbols name takes" {
    try std.testing.expectEqualStrings("us", layoutSymbol("us", 0).?);
    try std.testing.expectEqualStrings("de(neo)", layoutSymbol("de(neo)", 0).?);
    try std.testing.expectEqualStrings("us", layoutSymbol("pc+us+inet(evdev)", 0).?);
    try std.testing.expectEqualStrings("us", layoutSymbol("pc+us,de+inet(evdev)", 0).?);
    try std.testing.expectEqualStrings("de", layoutSymbol("pc+us,de+inet(evdev)", 1).?);
    // A group past the list is the entry XKB keeps pointing at.
    try std.testing.expectEqualStrings("de", layoutSymbol("pc+us,de+inet(evdev)", 5).?);
    // A trailing empty group names no layout.
    try std.testing.expect(layoutSymbol("pc+us,+inet(evdev)", 1) == null);
    // Two components are a layout with a variant or a base with a layout, so
    // neither reading may be reported as fact.
    try std.testing.expect(layoutSymbol("us+intl", 0) == null);
    try std.testing.expect(layoutSymbol("", 0) == null);
    try std.testing.expect(layoutSymbol("pc+", 0) == null);
}

test "identity reports nothing before XKB answered" {
    var identity: Identity = .{};
    try std.testing.expect(identity.name() == null);
    try std.testing.expect(identity.identifier() == null);
    try std.testing.expectEqual(Status.no_native_access, identity.status);
    // A name without a status is not a layout, so it stays unreportable.
    identity.name_len = 2;
    identity.name_buffer[0] = 'u';
    identity.name_buffer[1] = 's';
    try std.testing.expect(identity.name() == null);
    identity.status = .x11_xkb;
    try std.testing.expectEqualStrings("us", identity.name().?);
    try std.testing.expect(identity.identifier() == null);
}
