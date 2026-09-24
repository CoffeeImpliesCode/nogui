//! SDL display enumeration and compositor-reported logical desktop geometry.
const std = @import("std");
const sdl3 = @import("sdl3");
const contract = @import("nogui").window_contract;

pub const Id = contract.DisplayId;
pub const Info = struct {
    id: Id,
    primary: bool,
    full_bounds: contract.Bounds,
    work_bounds: contract.Bounds,
    content_scale: f32,
};

pub fn primary() !Id {
    return fromNative(try sdl3.video.Display.getPrimaryDisplay());
}

/// Caller frees the returned slice with its allocator; SDL's temporary list is freed here.
pub fn list(gpa: std.mem.Allocator) ![]Info {
    const native = try sdl3.video.getDisplays();
    defer sdl3.free(native);
    const result = try gpa.alloc(Info, native.len);
    errdefer gpa.free(result);
    const primary_id = try primary();
    for (native, result) |id, *info| {
        info.* = try describe(id, primary_id);
    }
    return result;
}

pub fn query(id: Id) !Info {
    const primary_id = try primary();
    return describe(toNative(id), primary_id);
}

pub fn forWindow(window: sdl3.video.Window) !Info {
    const native = try window.getDisplayForWindow();
    return query(fromNative(native));
}

pub fn fromNative(native: sdl3.video.Display) Id {
    return @enumFromInt(native.value);
}

pub fn toNative(id: Id) sdl3.video.Display {
    return .{ .value = @intFromEnum(id) };
}

/// Neither Wayland nor the SDL dummy backend provides global desktop placement.
pub fn hasGlobalPosition() bool {
    const driver = sdl3.video.getCurrentDriverName() orelse return false;
    return !std.mem.eql(u8, driver, "wayland") and !std.mem.eql(u8, driver, "dummy");
}

/// True when the platform can report whether a window is minimized. SDL's
/// Wayland backend only ever raises `SDL_WINDOW_MINIMIZED` itself, and only
/// when the compositor advertises the xdg-shell minimize capability; the dummy
/// and offscreen backends install no minimize path at all. SDL exposes no
/// query for this, so the driver it reports at runtime is the only platform
/// signal available, exactly as for `hasGlobalPosition`.
pub fn hasWindowMinimized() bool {
    const driver = sdl3.video.getCurrentDriverName() orelse return false;
    return !std.mem.eql(u8, driver, "wayland") and
        !std.mem.eql(u8, driver, "dummy") and
        !std.mem.eql(u8, driver, "offscreen");
}

/// True when the driver keeps a parent/child window hierarchy, which is what
/// makes a `menu` or `tooltip` window a popup of its parent. The headless
/// backends create windows with no relationship between them, so a popup's
/// parent is accepted and then unobservable. A client-size request has no such
/// gate: SDL forwards it on every backend and the compositor still decides the
/// observed size, which is why requested and observed size stay separate
/// values. As with `hasWindowMinimized`, SDL exposes no query, so the driver
/// it reports at runtime is the only platform signal available.
pub fn hasWindowHierarchy() bool {
    const driver = sdl3.video.getCurrentDriverName() orelse return false;
    return !std.mem.eql(u8, driver, "dummy") and !std.mem.eql(u8, driver, "offscreen");
}

/// What one display event actually changed, measured against the previous
/// reading of the same display. Every field defaults to false, so a caller
/// can treat a delta as the set of reasons it re-armed frame demand.
pub const Delta = struct {
    added: bool = false,
    removed: bool = false,
    primary_changed: bool = false,
    full_bounds_changed: bool = false,
    work_bounds_changed: bool = false,
    scale_changed: bool = false,

    /// True when the display can move or resize a window's client area.
    pub fn geometry(self: Delta) bool {
        return self.full_bounds_changed or self.work_bounds_changed;
    }

    pub fn none(self: Delta) bool {
        return !self.added and !self.removed and !self.primary_changed and
            !self.full_bounds_changed and !self.work_bounds_changed and
            !self.scale_changed;
    }
};

/// Compare two readings of one display. A missing `before` makes the display
/// new, a missing `after` makes it gone, and two `null` readings are the one
/// case that reports nothing at all.
pub fn diff(before: ?Info, after: ?Info) Delta {
    if (before == null and after == null) return .{};
    if (before == null) return .{ .added = true };
    if (after == null) return .{ .removed = true };
    const old = before.?;
    const new = after.?;
    return .{
        .primary_changed = old.primary != new.primary,
        .full_bounds_changed = !std.meta.eql(old.full_bounds, new.full_bounds),
        .work_bounds_changed = !std.meta.eql(old.work_bounds, new.work_bounds),
        .scale_changed = old.content_scale != new.content_scale,
    };
}

/// The displays one host currently knows about. A host diffs each incoming
/// display event against this reading, so a scale or bounds change is
/// reported as a measurement instead of a bare notification, and a caller can
/// enumerate the desktop without asking SDL again.
pub const Snapshot = struct {
    gpa: std.mem.Allocator,
    infos: std.ArrayListUnmanaged(Info) = .empty,

    pub fn empty(gpa: std.mem.Allocator) Snapshot {
        return .{ .gpa = gpa };
    }

    /// Query every display SDL currently enumerates. A platform with no
    /// display at all yields an empty snapshot rather than an error, so a
    /// headless host still starts.
    pub fn capture(gpa: std.mem.Allocator) !Snapshot {
        var snapshot: Snapshot = .{ .gpa = gpa };
        errdefer snapshot.deinit();
        // `appendSlice` copies, so the listing this reads has to be released
        // here; keeping it would leak one allocation per host construction.
        const listed = try list(gpa);
        defer gpa.free(listed);
        try snapshot.infos.appendSlice(gpa, listed);
        return snapshot;
    }

    pub fn deinit(self: *Snapshot) void {
        self.infos.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn get(self: *const Snapshot, id: Id) ?Info {
        for (self.infos.items) |info| {
            if (info.id == id) return info;
        }
        return null;
    }

    pub fn primary(self: *const Snapshot) ?Id {
        for (self.infos.items) |info| {
            if (info.primary) return info.id;
        }
        return null;
    }

    /// Replace one reading, or add it. The old entry is replaced in place
    /// when the display is already present, so an unchanged display count
    /// never reallocates.
    pub fn put(self: *Snapshot, info: Info) !void {
        for (self.infos.items, 0..) |existing, index| {
            if (existing.id == info.id) {
                self.infos.items[index] = info;
                return;
            }
        }
        try self.infos.append(self.gpa, info);
    }

    pub fn remove(self: *Snapshot, id: Id) void {
        for (self.infos.items, 0..) |existing, index| {
            if (existing.id == id) {
                _ = self.infos.orderedRemove(index);
                return;
            }
        }
    }
};

fn describe(native: sdl3.video.Display, primary_id: Id) !Info {
    const bounds = try native.getBounds();
    const usable = try native.getUsableBounds();
    return .{
        .id = fromNative(native),
        .primary = fromNative(native) == primary_id,
        .full_bounds = makeBounds(bounds),
        .work_bounds = makeBounds(usable),
        .content_scale = try native.getContentScale(),
    };
}

fn makeBounds(rect: sdl3.rect.IRect) contract.Bounds {
    return .{
        .position = if (hasGlobalPosition()) .{ .x = rect.x, .y = rect.y } else null,
        .size = .{ .width = @intCast(rect.w), .height = @intCast(rect.h) },
    };
}
