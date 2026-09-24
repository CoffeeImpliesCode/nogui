//! Native window interop through the window handle SDL owns.
//!
//! SDL creates the window and the renderer creates the swapchain, so this
//! adapter asks SDL for the window's own native handle and drives Win32 and
//! DWM through it. It never looks at a GPU surface and never extracts a
//! Vulkan handle: a title bar, a window style and a taskbar identity belong to
//! the `HWND`, and a `VkSurfaceKHR` names none of them. The window stays SDL's
//! and the surface stays the renderer's.
//!
//! Target gating follows `win32.zig`. `is_windows` is comptime-known and every
//! call into the platform is behind `if (comptime !is_windows)`, so a Linux,
//! macOS or mobile build never emits a reference to `user32` or `dwmapi` and
//! reports a named refusal instead of pretending.
//!
//! This is the one place a Windows adapter reads a native window handle.
//! `windows/menus.zig` has its own `hwndOf` doing the same property read; it
//! should call `getHwnd` here instead, so there is one definition of where a
//! handle comes from and one place that knows a handle can be dead.
const std = @import("std");
const sdl3 = @import("sdl3");
const win = @import("win32.zig");

pub const Hwnd = win.Hwnd;
pub const is_windows = win.is_windows;

pub const Error = error{
    /// This build has no Windows window to drive.
    NotWindows,
    /// The SDL window published no native window handle.
    NoNativeWindow,
    /// The window manager refused the title.
    TitleRejected,
    /// The window manager refused the style change.
    StyleRefused,
    /// This build of Windows has neither dark title bar attribute.
    DarkModeUnsupported,
    /// The handle is not a window. Both readers below answer a handle that
    /// names nothing, and a window with an empty title is a real value rather
    /// than a refusal, so "there is no window here" has to be its own answer
    /// instead of an empty string.
    NotAWindow,
    /// The window manager declined to answer the attribute. A failing
    /// `HRESULT` is a real answer about this build of Windows: it is neither a
    /// dead window nor a feature that is absent, and folding it into
    /// `DarkModeUnsupported` would report a capability nobody observed.
    AttributeRefused,
    /// The title is not valid UTF-8, so it cannot be widened for
    /// `SetWindowTextW`. A window carrying a mangled version of the title the
    /// caller asked for is a different window state from one carrying it.
    InvalidUtf8,
} || std.mem.Allocator.Error;

/// The native handles SDL publishes for one window.
pub const Handles = struct {
    hwnd: ?Hwnd = null,
    driver_name: ?[]const u8 = null,

    /// True when SDL opened the `windows` driver. A handle is only meaningful
    /// on that driver, so a window on any other driver is reported as having
    /// no native window even if a property is present.
    pub fn usesWin32(self: Handles) bool {
        const name = self.driver_name orelse return false;
        return std.mem.eql(u8, name, "windows");
    }

    /// Whether the native calls in this file can act on this window.
    pub fn canDrive(self: Handles) bool {
        return self.usesWin32() and self.hwnd != null;
    }

    /// The handle, or a named refusal. `error.NoNativeWindow` is what a window
    /// on a non-Windows driver reports, and it is not the same answer as a
    /// handle that is present but dead; that one is `isWindow` answering false.
    pub fn require(self: Handles) Error!Hwnd {
        if (comptime !win.is_windows) return error.NotWindows;
        if (!self.usesWin32()) return error.NoNativeWindow;
        return self.hwnd orelse error.NoNativeWindow;
    }
};

/// Read the handles SDL publishes for one window.
///
/// Only the window property store is read. `SDL_PROP_WINDOW_WIN32_HWND_POINTER`
/// is the one property that names the window SDL created, and it is the only
/// handle this adapter needs.
pub fn readHandles(window: sdl3.video.Window) Handles {
    if (comptime !win.is_windows) return .{};
    const properties = window.getProperties() catch return .{};
    const raw: ?*anyopaque = if (properties.win32_hwnd) |value| value.value else null;
    return .{
        .hwnd = if (raw) |handle| @ptrCast(handle) else null,
        .driver_name = sdl3.video.getCurrentDriverName(),
    };
}

/// The native window handle SDL owns for this window, or null when there is
/// none. The handle is borrowed from SDL and stays valid until the window is
/// destroyed.
pub fn getHwnd(window: sdl3.video.Window) ?Hwnd {
    return readHandles(window).hwnd;
}

/// Whether the handle is still a window.
///
/// This is the check that separates a dead window from a live one, and it is
/// the only handle check the other adapters in this directory need before
/// they touch a window.
pub fn isWindow(hwnd: Hwnd) bool {
    if (comptime !win.is_windows) return false;
    return win.IsWindow(hwnd) != 0;
}

/// The window's own logical-to-physical factor, from its DPI.
///
/// UI Automation takes its rectangles from the physical pixels the window
/// procedure is handed, so a tree published in the host's logical units is only
/// the right size when it is scaled by this factor. A display that is not at
/// 100% is the ordinary case on Windows, not an edge case, so this is read from
/// the window rather than assumed.
///
/// A handle that is not a window answers zero, which is reported as the factor
/// that changes nothing. A zero would be rejected by `setScale` and leave the
/// adapter on whatever it had, and "unchanged" is the honest reading of a handle
/// with no DPI: there is no window to be wrong about.
pub fn dpiScaleOf(hwnd: Hwnd) f32 {
    if (comptime !win.is_windows) return 1;
    const dpi = win.GetDpiForWindow(hwnd);
    if (dpi == 0) return 1;
    return @as(f32, @floatFromInt(dpi)) / @as(f32, @floatFromInt(win.default_dpi));
}

/// Set the window title through the native window.
///
/// A title the SDK will not store is a named refusal, not a silent success:
/// `SetWindowTextW` returns zero and the last error says why, and a window
/// whose title did not change is a different window state from one that did.
pub fn setWindowTitle(
    gpa: std.mem.Allocator,
    hwnd: Hwnd,
    title: []const u8,
) Error!void {
    if (comptime !win.is_windows) return error.NotWindows;
    const wide_title = try win.wide(gpa, title);
    // The title is not a secret, but it is caller data in this process and
    // every wide string this directory makes leaves through the same wipe.
    defer {
        win.wipe(std.mem.sliceAsBytes(wide_title));
        gpa.free(wide_title);
    }
    if (win.SetWindowTextW(hwnd, wide_title.ptr) == 0) return error.TitleRejected;
}

/// The window's own style bits.
pub fn styleOf(hwnd: Hwnd) u32 {
    if (comptime !win.is_windows) return 0;
    const value = win.GetWindowLongPtrW(hwnd, win.gwl_style);
    // The value round-trips through a pointer-sized integer because the style
    // is 32 bits on every architecture while `LONG_PTR` is not.
    const bits: usize = @bitCast(value);
    return @truncate(bits);
}

/// Whether the window's frame advertises a resize grip.
pub fn hasResizableFrame(hwnd: Hwnd) bool {
    if (comptime !win.is_windows) return false;
    return styleOf(hwnd) & win.ws_thickframe != 0;
}

/// Turn the resize grip on or off through the window's own style.
///
/// `WS_THICKFRAME` is what the window manager reads to decide whether a window
/// can be sized, and it does not stand alone: a window with no frame has no
/// caption, so a borderless window would grow a title bar to stay resizable.
/// The caption bits are therefore held in step with the frame. The style is
/// read back afterwards and the result is returned, because a request is not a
/// fact.
///
/// The frame is not repainted by this call. `SetWindowLongPtrW` changes the
/// style, and the window manager redraws the frame on the next move, resize or
/// activation, which is the host's own window request. SDL's `setResizable`
/// is the supported way to ask for that repaint, and this is the native half
/// that keeps the two from disagreeing about the same window.
pub fn setResizableFrame(hwnd: Hwnd, resizable: bool) Error!bool {
    if (comptime !win.is_windows) return error.NotWindows;
    const current = styleOf(hwnd);
    const frame_bits = win.ws_thickframe | win.ws_caption | win.ws_sysmenu | win.ws_minimizebox;
    const wanted = if (resizable) current | frame_bits else current & ~frame_bits;
    if (wanted == current) return true;
    // A zero previous style is ambiguous, because zero is a legal style, so
    // the SDK reports a failure through the last error instead.
    const previous = win.SetWindowLongPtrW(hwnd, win.gwl_style, @bitCast(@as(usize, wanted)));
    if (previous == 0 and win.lastError() != win.error_success) return error.StyleRefused;
    return styleOf(hwnd) == wanted;
}

/// Ask the desktop window manager for a dark title bar.
///
/// Windows 10 1809 and later take the request through
/// `DWMWA_USE_IMMERSIVE_DARK_MODE`, and the build before it through the
/// attribute with the next number down. Both are tried and the first the window
/// manager accepts wins, because a build of Windows that has neither is a
/// real answer about this machine and not a failure worth inventing a name
/// for.
pub fn setDarkTitleBar(hwnd: Hwnd, dark: bool) Error!void {
    if (comptime !win.is_windows) return error.NotWindows;
    const enabled: win.Bool = if (dark) 1 else 0;
    const size: win.Dword = @sizeOf(win.Bool);
    const hr = win.DwmSetWindowAttribute(
        hwnd,
        win.dwma_use_immersive_dark_mode_20,
        @ptrCast(&enabled),
        size,
    );
    if (win.succeeded(hr)) return;
    const legacy = win.DwmSetWindowAttribute(
        hwnd,
        win.dwma_use_immersive_dark_mode_19,
        @ptrCast(&enabled),
        size,
    );
    if (win.succeeded(legacy)) return;
    return error.DarkModeUnsupported;
}

/// The title the window itself holds, read back through the window procedure.
///
/// `setWindowTitle` asked for a title; this is what the window is carrying, and
/// it is deliberately NOT the copy SDL keeps. SDL's title is what the
/// application asked for, this is what `GetWindowTextW` answers for the live
/// handle, and a window manager that stored something else — or a window
/// procedure that answers its own title — has to be visible as a difference
/// rather than folded into the request's return code.
///
/// The returned slice is owned UTF-8; the caller frees it with `gpa`.
pub fn windowTitle(gpa: std.mem.Allocator, hwnd: Hwnd) Error![]const u8 {
    if (comptime !win.is_windows) return error.NotWindows;
    // `GetWindowTextLengthW` answers zero for a window with an empty title and
    // for a handle that names nothing, so the liveness check has to run first
    // or the two answers are indistinguishable.
    if (!isWindow(hwnd)) return error.NotAWindow;
    const length = win.GetWindowTextLengthW(hwnd);
    if (length <= 0) return gpa.dupe(u8, "");
    // The window procedure is asked for its own title, and a window may answer
    // with more than the length it reported, so the buffer is sized from that
    // report plus the terminator and the answer is truncated to what came
    // back rather than to what was asked for.
    const wide_title = try gpa.alloc(u16, @intCast(length + 1));
    defer gpa.free(wide_title);
    const written = win.GetWindowTextW(hwnd, wide_title.ptr, length + 1);
    if (written <= 0) return error.TitleRejected;
    const answer = wide_title[0..@intCast(written)];
    // Unpaired surrogates are refused rather than replaced: a title this
    // adapter cannot spell is a different title, and a replacement character
    // would make it compare equal to the one that was asked for.
    const owned = try win.narrow(gpa, std.mem.sliceTo(answer, 0));
    return owned;
}

/// Whether this window's frame is drawn dark, read back from the window
/// manager that was asked for it.
///
/// `setDarkTitleBar` returns the window manager's answer to the REQUEST. This
/// returns the window manager's answer to the STATE, which is the only thing
/// that distinguishes "the request was accepted" from "the caption is dark".
/// Both attributes are tried, in the same order and for the same reason as the
/// setter; a build of Windows that answers neither is `AttributeRefused`, not
/// a false.
pub fn darkTitleBar(hwnd: Hwnd) Error!bool {
    if (comptime !win.is_windows) return error.NotWindows;
    if (!isWindow(hwnd)) return error.NotAWindow;
    const size: win.Dword = @sizeOf(win.Bool);
    var enabled: win.Bool = 0;
    const hr = win.DwmGetWindowAttribute(
        hwnd,
        win.dwma_use_immersive_dark_mode_20,
        @ptrCast(&enabled),
        size,
    );
    if (win.succeeded(hr)) return enabled != 0;
    const legacy = win.DwmGetWindowAttribute(
        hwnd,
        win.dwma_use_immersive_dark_mode_19,
        @ptrCast(&enabled),
        size,
    );
    if (win.succeeded(legacy)) return enabled != 0;
    return error.AttributeRefused;
}

/// True when this build can name a native window at all. A build that cannot
/// is not a build whose windows are unsupported; it is a build with no
/// platform to ask, and the callers say so by name.
pub fn isApplicable() bool {
    return comptime win.is_windows;
}

test "api-w23 native handles are only actionable on the win32 driver" {
    // A handle with no driver is a window the adapter must not act on: the
    // property store publishes one per platform and only one of them is a
    // window on this system.
    const unnamed: Handles = .{ .hwnd = @ptrFromInt(0x1000) };
    try std.testing.expect(!unnamed.usesWin32());
    try std.testing.expect(!unnamed.canDrive());
    if (comptime !win.is_windows) {
        try std.testing.expectError(error.NotWindows, unnamed.require());
    }

    const win32: Handles = .{ .hwnd = @ptrFromInt(0x1000), .driver_name = "windows" };
    try std.testing.expect(win32.usesWin32());
    try std.testing.expect(win32.canDrive());

    // A foreign driver with a handle is still not a window here.
    const wayland: Handles = .{ .hwnd = @ptrFromInt(0x1000), .driver_name = "wayland" };
    try std.testing.expect(!wayland.usesWin32());
    try std.testing.expect(!wayland.canDrive());

    // The win32 driver with no handle cannot be driven either.
    const headless: Handles = .{ .driver_name = "windows" };
    try std.testing.expect(headless.usesWin32());
    try std.testing.expect(!headless.canDrive());
}

test "api-w23 window style never reads a window that is not there" {
    // Off Windows there is no style to read and the helper says so with a
    // value rather than with a handle it made up.
    if (comptime !win.is_windows) {
        const hwnd: Hwnd = @ptrFromInt(0x2000);
        try std.testing.expect(!isWindow(hwnd));
        try std.testing.expect(!hasResizableFrame(hwnd));
        try std.testing.expectEqual(@as(u32, 0), styleOf(hwnd));
        try std.testing.expectError(
            error.NotWindows,
            setResizableFrame(hwnd, true),
        );
        try std.testing.expectError(
            error.NotWindows,
            setDarkTitleBar(hwnd, true),
        );
        try std.testing.expectError(
            error.NotWindows,
            setWindowTitle(std.testing.allocator, hwnd, "title"),
        );
        // The READ side is refused with the same build-level answer, and it is
        // a refusal rather than an empty title or a false: off Windows there
        // is no window for either reader to ask.
        try std.testing.expectError(
            error.NotWindows,
            windowTitle(std.testing.allocator, hwnd),
        );
        try std.testing.expectError(error.NotWindows, darkTitleBar(hwnd));
        // A handle that is not a window has no DPI either, and the factor that
        // reports one is the one that changes nothing.
        try std.testing.expectEqual(@as(f32, 1), dpiScaleOf(hwnd));
    }
}

test "api-w23 a dead handle is refused by name, not answered with a value" {
    // Only a Windows build has a window manager to ask, so this is the one
    // place `NotAWindow` is observable at all. It matters because both readers
    // would otherwise have a legal-looking answer for a handle that names
    // nothing: an empty title, or a dark frame that is really no frame.
    if (comptime win.is_windows) {
        const dead: Hwnd = @ptrFromInt(0x2000);
        try std.testing.expect(!isWindow(dead));
        try std.testing.expectError(error.NotAWindow, darkTitleBar(dead));
        try std.testing.expectError(
            error.NotAWindow,
            windowTitle(std.testing.allocator, dead),
        );
    }
}
