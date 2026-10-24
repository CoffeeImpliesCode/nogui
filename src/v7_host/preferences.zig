//! Observed desktop appearance, button layout, scrollbar, thermal, and compositor preferences.
//! System path and auxiliary executable lookup utilities.
//! Unsupported preferences are optional (null) rather than fabricated defaults.
const std = @import("std");
const sdl3 = @import("sdl3");
const builtin = @import("builtin");
const c = sdl3.c;
const portal = @import("linux/portal.zig");
const nogui = @import("nogui");
const macos_preferences = @import("macos/preferences.zig");

fn environmentVariable(name: [:0]const u8) ?[]const u8 {
    const process = sdl3.getEnvironment() catch return null;
    return process.getVariable(name);
}

pub const SystemTheme = enum {
    light,
    dark,
};

pub const MotionPreference = enum {
    no_preference,
    reduce,
};

/// The observed desktop signal for this process, not the running gate. It
/// becomes an App's motion gate only through `applyReducedMotion`.
var application_reduced_motion: ?MotionPreference = null;

/// Get system appearance theme.
/// Returns null if the platform host or desktop environment does not specify a theme.
pub fn getSystemTheme() ?SystemTheme {
    const raw = c.SDL_GetSystemTheme();
    switch (raw) {
        c.SDL_SYSTEM_THEME_LIGHT => return .light,
        c.SDL_SYSTEM_THEME_DARK => return .dark,
        else => {},
    }

    if (comptime builtin.target.os.tag != .linux or builtin.target.abi.isAndroid()) return null;
    // A desktop portal is the only other observed appearance source.
    if (portal.readAppearanceTheme(std.heap.c_allocator) catch null) |theme| {
        return switch (theme) {
            .light => .light,
            .dark => .dark,
        };
    }

    return null;
}

/// Get reduced motion preference.
/// Returns the application-configured override if set, or null if no backend
/// signal exists. This is the observed desktop *signal*, not the running
/// gate: the value an App actually animates under lives in the App, and this
/// module reaches it only through `applyReducedMotion`.
pub fn getReducedMotion() ?MotionPreference {
    return application_reduced_motion;
}

/// Set application-level reduced motion preference override.
/// The override is an input to the desktop signal, not a second switch that
/// runs beside it. It has no effect on any App until a host calls
/// `applyReducedMotion`, so a caller that sets it and never bridges has
/// changed nothing that is on screen.
pub fn setApplicationReducedMotion(preference: ?MotionPreference) void {
    application_reduced_motion = preference;
}

/// The gate an observed motion signal resolves to. A desktop that expresses
/// no preference at all (`null`) and one that explicitly declines to reduce
/// both leave authored motion alone; only `reduce` suppresses it.
pub fn reducedMotionRequested() bool {
    return switch (getReducedMotion() orelse return false) {
        .reduce => true,
        .no_preference => false,
    };
}

/// The single bridge from the observed desktop preference into a running
/// App. No other function in the host layer writes an App's motion gate, and
/// `App.reducedMotion` is the only reader, so the desktop signal and the
/// animation registry can never report two different answers.
///
/// Call it on every host frame: the App ignores an unchanged value, so the
/// steady-state cost is one comparison, and a preference that changes at
/// runtime takes effect on the next call with no other wiring.
pub fn applyReducedMotion(app: *nogui.App, now_ms: u64) !void {
    try app.setReducedMotion(reducedMotionRequested(), now_ms);
}

pub const TitlebarButton = enum {
    close,
    minimize,
    maximize,
    app_menu,
};

pub const TitlebarButtonLayout = struct {
    left: []const TitlebarButton,
    right: []const TitlebarButton,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *TitlebarButtonLayout) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Parse a titlebar button layout string (e.g. "close,minimize,maximize:" or ":minimize,maximize,close").
/// The colon separates the left-hand side buttons from the right-hand side buttons.
pub fn parseButtonLayout(allocator: std.mem.Allocator, raw: []const u8) !TitlebarButtonLayout {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var left_list: std.ArrayList(TitlebarButton) = .empty;
    var right_list: std.ArrayList(TitlebarButton) = .empty;

    const colon_idx = std.mem.findScalar(u8, raw, ':');
    const left_part = if (colon_idx) |idx| raw[0..idx] else raw;
    const right_part = if (colon_idx) |idx| raw[idx + 1 ..] else "";

    var left_iter = std.mem.splitScalar(u8, left_part, ',');
    while (left_iter.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " ");
        if (mapButton(trimmed)) |btn| {
            try left_list.append(alloc, btn);
        }
    }

    var right_iter = std.mem.splitScalar(u8, right_part, ',');
    while (right_iter.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " ");
        if (mapButton(trimmed)) |btn| {
            try right_list.append(alloc, btn);
        }
    }

    return .{
        .left = try left_list.toOwnedSlice(alloc),
        .right = try right_list.toOwnedSlice(alloc),
        .arena = arena,
    };
}

fn mapButton(name: []const u8) ?TitlebarButton {
    if (std.mem.eql(u8, name, "close")) return .close;
    if (std.mem.eql(u8, name, "minimize")) return .minimize;
    if (std.mem.eql(u8, name, "maximize")) return .maximize;
    if (std.mem.eql(u8, name, "appmenu") or std.mem.eql(u8, name, "menu")) return .app_menu;
    return null;
}

/// Query desktop titlebar button layout. Returns null if unsupported or unobserved.
pub fn getTitlebarButtonLayout(_: std.mem.Allocator) ?TitlebarButtonLayout {
    // No supported backend currently observes this desktop preference.
    return null;
}

pub const ScrollbarPreferences = struct {
    jump_to_click: ?bool = null,
    auto_hide: ?bool = null,
};

/// Get scrollbar preferences. Fields are null when unsupported by desktop backend.
pub fn getScrollbarPreferences() ScrollbarPreferences {
    if (comptime macos_preferences.available) {
        const style = macos_preferences.preferredScrollerStyle() catch null;
        return .{
            .jump_to_click = null,
            .auto_hide = if (style) |value| value.autoHide() else null,
        };
    }
    return .{
        .jump_to_click = null,
        .auto_hide = null,
    };
}

pub const ThermalState = enum {
    nominal,
    fair,
    serious,
    critical,
};

/// Query system thermal state.
/// A raw hardware zone sensor reading is not an observed OS thermal state.
/// Returns null unless a genuine native OS thermal pressure signal exists.
pub fn getThermalState() ?ThermalState {
    if (comptime macos_preferences.available) {
        const state = macos_preferences.thermalState() catch return null;
        return switch (state orelse return null) {
            .nominal => .nominal,
            .fair => .fair,
            .serious => .serious,
            .critical => .critical,
        };
    }
    return null;
}

pub const CompositorType = enum {
    wayland,
    x11,
    dummy,
    other,
};

pub const CompositorInfo = struct {
    compositor_type: CompositorType,
    name: ?[]const u8 = null,
    vrr_supported: ?bool = null,
    direct_scanout: ?bool = null,
};

/// Query display server and compositor information.
pub fn getCompositorInfo() CompositorInfo {
    const driver = sdl3.video.getCurrentDriverName() orelse "unknown";

    if (std.mem.eql(u8, driver, "wayland")) {
        const desktop_name = environmentVariable("XDG_CURRENT_DESKTOP");
        return .{
            .compositor_type = .wayland,
            .name = desktop_name,
            .vrr_supported = null,
            .direct_scanout = null,
        };
    } else if (std.mem.eql(u8, driver, "x11")) {
        return .{
            .compositor_type = .x11,
            .name = "X11",
            .vrr_supported = null,
            .direct_scanout = null,
        };
    } else if (std.mem.eql(u8, driver, "dummy")) {
        return .{
            .compositor_type = .dummy,
            .name = "Dummy",
            .vrr_supported = false,
            .direct_scanout = false,
        };
    }

    return .{
        .compositor_type = .other,
        .name = driver,
        .vrr_supported = null,
        .direct_scanout = null,
    };
}

pub const SystemFolder = enum {
    home,
    desktop,
    documents,
    downloads,
    music,
    pictures,
    templates,
    videos,
    config,
    data,
    cache,
    temp,
};

/// Retrieve an absolute system directory path.
/// Caller owns returned allocated slice.
pub fn getUserFolder(allocator: std.mem.Allocator, folder: SystemFolder) !?[]u8 {
    switch (folder) {
        .config => {
            if (environmentVariable("XDG_CONFIG_HOME")) |cfg| {
                return try allocator.dupe(u8, cfg);
            }
            if (environmentVariable("HOME")) |home| {
                return try std.fs.path.join(allocator, &[_][]const u8{ home, ".config" });
            }
            return null;
        },
        .data => {
            if (environmentVariable("XDG_DATA_HOME")) |d| {
                return try allocator.dupe(u8, d);
            }
            if (environmentVariable("HOME")) |home| {
                return try std.fs.path.join(allocator, &[_][]const u8{ home, ".local", "share" });
            }
            return null;
        },
        .cache => {
            if (environmentVariable("XDG_CACHE_HOME")) |c_dir| {
                return try allocator.dupe(u8, c_dir);
            }
            if (environmentVariable("HOME")) |home| {
                return try std.fs.path.join(allocator, &[_][]const u8{ home, ".cache" });
            }
            return null;
        },
        .temp => {
            if (environmentVariable("TMPDIR")) |tmp| {
                return try allocator.dupe(u8, tmp);
            }
            return try allocator.dupe(u8, "/tmp");
        },
        else => {
            // Standard SDL user folders
            const sdl_folder: c.SDL_Folder = switch (folder) {
                .home => c.SDL_FOLDER_HOME,
                .desktop => c.SDL_FOLDER_DESKTOP,
                .documents => c.SDL_FOLDER_DOCUMENTS,
                .downloads => c.SDL_FOLDER_DOWNLOADS,
                .music => c.SDL_FOLDER_MUSIC,
                .pictures => c.SDL_FOLDER_PICTURES,
                .templates => c.SDL_FOLDER_TEMPLATES,
                .videos => c.SDL_FOLDER_VIDEOS,
                else => unreachable,
            };
            const raw = c.SDL_GetUserFolder(sdl_folder);
            if (raw == null) return null;
            return try allocator.dupe(u8, std.mem.span(raw));
        },
    }
}

/// Retrieve the application base / executable bundle path.
/// Caller owns returned allocated slice.
pub fn getBasePath(allocator: std.mem.Allocator) !?[]u8 {
    // SDL owns its cached path. The caller owns only this copy.
    const raw = sdl3.filesystem.getBasePath() catch null;
    if (raw) |base| {
        const owned = try allocator.dupe(u8, base);
        return owned;
    }
    // Fallback to the directory of the running executable.
    if (comptime builtin.target.os.tag != .linux or builtin.target.abi.isAndroid()) return null;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const read = std.os.linux.readlink("/proc/self/exe", &buffer, buffer.len);
    if (std.os.linux.errno(read) != .SUCCESS) return null;
    const dir = std.fs.path.dirname(buffer[0..read]) orelse return null;
    const owned = try allocator.dupe(u8, dir);
    return owned;
}

/// Lookup companion / auxiliary executable relative to application binary first,
/// then through system PATH. Validates that the file exists and is executable.
/// Caller owns returned path slice.
pub fn findAuxiliaryExecutable(
    allocator: std.mem.Allocator,
    io: std.Io,
    exe_name: []const u8,
) !?[]u8 {
    if (exe_name.len == 0) return null;

    // 1. Search in base path (adjacent to binary)
    if (try getBasePath(allocator)) |base| {
        defer allocator.free(base);
        const adjacent = try std.fs.path.join(allocator, &[_][]const u8{ base, exe_name });
        errdefer allocator.free(adjacent);

        if (isExecutable(io, adjacent)) {
            return adjacent;
        }
        allocator.free(adjacent);
    }

    // 2. Search in system PATH
    const env_path = environmentVariable("PATH") orelse return null;
    var iter = std.mem.splitScalar(u8, env_path, std.fs.path.delimiter);
    while (iter.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &[_][]const u8{ dir, exe_name });
        errdefer allocator.free(candidate);

        if (isExecutable(io, candidate)) {
            return candidate;
        }
        allocator.free(candidate);
    }

    return null;
}

fn isExecutable(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    const status = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return status.kind == .file;
}

pub const ThemeChangeCallback = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, ?SystemTheme) void,
};

pub const PreferencesObserver = struct {
    theme_callback: ?ThemeChangeCallback = null,

    pub fn init() PreferencesObserver {
        return .{};
    }

    pub fn setOnThemeChanged(self: *PreferencesObserver, cb: ?ThemeChangeCallback) void {
        self.theme_callback = cb;
    }

    /// Report the observed theme. Returns true only for a theme change event.
    pub fn handleEvent(self: *PreferencesObserver, raw: *const sdl3.events.Event) bool {
        switch (raw.*) {
            .system_theme_changed => {},
            else => return false,
        }
        const callback = self.theme_callback orelse return true;
        callback.callback(callback.context, getSystemTheme());
        return true;
    }
};

test "preferences parse titlebar button layout" {
    // macOS style: left close, minimize, maximize; right empty
    var mac_layout = try parseButtonLayout(std.testing.allocator, "close,minimize,maximize:");
    defer mac_layout.deinit();

    try std.testing.expectEqual(@as(usize, 3), mac_layout.left.len);
    try std.testing.expectEqual(TitlebarButton.close, mac_layout.left[0]);
    try std.testing.expectEqual(TitlebarButton.minimize, mac_layout.left[1]);
    try std.testing.expectEqual(TitlebarButton.maximize, mac_layout.left[2]);
    try std.testing.expectEqual(@as(usize, 0), mac_layout.right.len);

    // Windows / GNOME style: left empty; right minimize, maximize, close
    var win_layout = try parseButtonLayout(std.testing.allocator, ":minimize,maximize,close");
    defer win_layout.deinit();

    try std.testing.expectEqual(@as(usize, 0), win_layout.left.len);
    try std.testing.expectEqual(@as(usize, 3), win_layout.right.len);
    try std.testing.expectEqual(TitlebarButton.minimize, win_layout.right[0]);
    try std.testing.expectEqual(TitlebarButton.maximize, win_layout.right[1]);
    try std.testing.expectEqual(TitlebarButton.close, win_layout.right[2]);
}

test "preferences button layout drops unknown tokens and an absent separator" {
    var without_separator = try parseButtonLayout(std.testing.allocator, "close,menu,unknown");
    defer without_separator.deinit();
    try std.testing.expectEqual(@as(usize, 2), without_separator.left.len);
    try std.testing.expectEqual(TitlebarButton.close, without_separator.left[0]);
    try std.testing.expectEqual(TitlebarButton.app_menu, without_separator.left[1]);
    try std.testing.expectEqual(@as(usize, 0), without_separator.right.len);
}
