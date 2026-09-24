//! Windows application identity: the AppUserModelID that groups the app.
//!
//! Windows has no bundle identifier. What it has is a process-wide
//! `AppUserModelID`, a caller-chosen string that the shell uses for four
//! things at once: the taskbar grouping, the Start menu entry a toast is
//! attributed to, the jump list that belongs to this app, and the identity a
//! `ShellLink` must carry to land in that jump list. Set it and all four agree;
//! leave it unset and the shell falls back to the executable path, which puts
//! a development build in a group of its own and makes a toast show up as an
//! unidentified sender.
//!
//! So this is not a cosmetic call. It is the first thing E03 needs and the one
//! ordering constraint that matters:
//!
//!   1. `SetCurrentProcessExplicitAppUserModelID` runs before any window is
//!      created. SDL creates the window, and the shell reads the process
//!      identity when the window appears, so a later call leaves the first
//!      window grouped under the fallback identity.
//!   2. The jump list in `jump_list.zig` reads the same value back with
//!      `GetCurrentProcessExplicitAppUserModelID` and refuses to build a list
//!      for an identity the process does not hold.
//!   3. A toast in `notifications.zig` asks `CreateToastNotifier` for this
//!      identity, and the shell drops the toast if it does not match a Start
//!      menu entry with a matching `System.AppUserModel.ID` COM activator.
//!      That activator is a packaging fact, not something an adapter can
//!      fabricate, and it is listed as a runtime prerequisite.
//!
//! The identity is validated here, not merely passed through. Windows accepts
//! any non-empty string up to 128 characters including a period, and the
//! documented grammar is a dot-separated sequence of alphanumeric groups and
//! dashes. A trailing or doubled dot, a non-ASCII character or an over-long
//! string is refused by name, because the shell's own behaviour for a malformed
//! AUMID is to group nothing and say nothing.
const std = @import("std");
const win = @import("win32.zig");

pub const Identity = struct {
    /// The caller-chosen `AppUserModelID`, owned UTF-8. NUL is not a legal
    /// character in it, so a stored identity can always be widened to a
    /// `PCWSTR` without an extra terminator rule.
    app_id: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Identity) void {
        self.allocator.free(self.app_id);
        self.app_id = &.{};
        self.* = undefined;
    }
};

/// Longest identity the shell documents, in UTF-16 code units.
pub const max_app_id: usize = 128;

pub const Error = error{
    /// The identity is empty, longer than `max_app_id`, holds a NUL, or breaks
    /// the documented dot-separated alphanumeric-and-dash grammar.
    InvalidAppId,
    /// The identity is not valid UTF-8, so it cannot be widened for the shell.
    /// A mangled identity is a different app group, so it is refused rather
    /// than stored with replacement characters in it.
    InvalidUtf8,
};

/// The documented grammar: dot-separated groups of ASCII alphanumerics and
/// dashes, neither the first nor the last character a dot, no empty group.
pub fn isWellFormed(app_id: []const u8) bool {
    if (app_id.len == 0 or app_id.len > max_app_id) return false;
    var at_group_start = true;
    for (app_id) |c| {
        switch (c) {
            '.' => {
                if (at_group_start) return false;
                at_group_start = true;
            },
            '0'...'9', 'a'...'z', 'A'...'Z', '-' => at_group_start = false,
            else => return false,
        }
    }
    return !at_group_start;
}

/// Set the process-wide identity. Call this before the first window exists.
///
/// Returns the identity the process holds afterwards, so a caller can assert
/// the shell took the value it was given instead of trusting the return code
/// alone. `GetCurrentProcessExplicitAppUserModelID` allocates the readback with
/// `CoTaskMemAlloc`, so the readback is freed with `CoTaskMemFree`; the SDK has
/// no other release for it.
pub fn setProcessIdentity(allocator: std.mem.Allocator, app_id: []const u8) Error!Identity {
    if (comptime !win.is_windows) return error.InvalidAppId;
    if (!isWellFormed(app_id)) return error.InvalidAppId;

    const wide_id = try win.wide(allocator, app_id);
    defer allocator.free(wide_id);

    const set = win.SetCurrentProcessExplicitAppUserModelID(wide_id.ptr);
    // `SetCurrentProcessExplicitAppUserModelID` documents `S_OK` only. A
    // negative result is a real refusal by the shell, and `E_INVALIDARG` for a
    // value it will not store is worth naming rather than folding into
    // "unsupported", because the caller's own string is the thing to fix.
    if (win.failed(set)) return error.InvalidAppId;

    const readback = try currentProcessIdentity(allocator);
    // The shell accepted the call but reports something else. That is a real
    // divergence and it would silently mis-group every window, so it is a
    // distinct refusal rather than a success with a caveat.
    if (!std.mem.eql(u8, readback.app_id, app_id)) {
        readback.deinit();
        return error.InvalidAppId;
    }
    return readback;
}

/// The identity this process currently holds, or null when it holds none.
///
/// A process that never called `SetCurrentProcessExplicitAppUserModelID` has
/// no explicit identity, and the shell's fallback is not a value this function
/// may invent: the jump list needs the string the app chose, not the path the
/// shell fell back to.
pub fn currentProcessIdentity(allocator: std.mem.Allocator) !?Identity {
    if (comptime !win.is_windows) return null;
    var slot: ?[*:0]const u16 = null;
    const hr = win.GetCurrentProcessExplicitAppUserModelID(&slot);
    if (win.failed(hr)) return null;
    const owned = slot orelse return null;
    // The readback comes from `CoTaskMemAlloc`, and `CoTaskMemFree` is the only
    // release the SDK documents for it.
    defer win.CoTaskMemFree(@ptrCast(@constCast(owned)));
    return .{
        .app_id = try win.narrow(allocator, std.mem.span(owned)),
        .allocator = allocator,
    };
}

/// True when this build can name an identity at all. A build that cannot is
/// not a build whose toasts are unsupported; it is a build with no platform to
/// ask, and the callers say so by name.
pub fn isApplicable() bool {
    return comptime win.is_windows;
}

test "api-w23 windows app id grammar follows the documented shell rules" {
    // The identity shape Windows documents: dot-separated alphanumeric groups.
    try std.testing.expect(isWellFormed("nogui.app"));
    try std.testing.expect(isWellFormed("com.7Games.nogui"));
    try std.testing.expect(isWellFormed("a"));
    try std.testing.expect(isWellFormed("com.example-app"));

    // A leading, doubled or trailing dot leaves an empty group.
    try std.testing.expect(!isWellFormed(".com.example"));
    try std.testing.expect(!isWellFormed("com..example"));
    try std.testing.expect(!isWellFormed("com.example."));
    try std.testing.expect(!isWellFormed(""));
    // A group separator that is not a period, and a non-ASCII character,
    // which the shell's grammar does not admit.
    try std.testing.expect(!isWellFormed("com/example"));
    try std.testing.expect(!isWellFormed("com.exämple"));
    // Over the documented length.
    var long_id: [max_app_id + 1]u8 = undefined;
    @memset(&long_id, 'a');
    try std.testing.expect(!isWellFormed(&long_id));
}

test "api-w23 windows app id refuses to be set off windows" {
    // The identity setter is a Windows-only call. On any other target it is a
    // named refusal, never a value that pretends the shell accepted it.
    if (comptime !win.is_windows) {
        try std.testing.expectError(
            error.InvalidAppId,
            setProcessIdentity(std.testing.allocator, "com.7games.nogui"),
        );
        try std.testing.expect(!isApplicable());
    }
}
