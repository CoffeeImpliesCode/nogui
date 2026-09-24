//! E01: macOS native windows — tab groups, titlebar control, and document
//! metadata.
//!
//! What AppKit actually offers, and what this module therefore does with it:
//!
//!   * TABS. The public API is `addTabbedWindow:ordered:` to merge,
//!     `selectNextTab:` / `selectPreviousTab:` to navigate, `mergeAllWindows:`
//!     to fold every window in, and `moveTabToNewWindow:` to detach. There is
//!     no public way to reorder a tab in place and no public `selectedTab`, so
//!     the selected tab is read the way AppKit itself defines it: the key
//!     window, or the main window when no key window exists. A detach of a
//!     window that is not the selected tab is refused rather than quietly
//!     moving the wrong one.
//!   * TITLEBAR. `titleVisibility`, `titlebarAppearsTransparent` and the three
//!     standard buttons are public. The titlebar separator is a public *style*
//!     from macOS 11; the colour property that shares its name is not in the
//!     public headers, so an older system reports `unsupported` instead of
//!     pretending to have changed something.
//!   * DOCUMENT. `isDocumentEdited` is the flag a close confirmation reads and
//!     `representedURL` is the proxy icon plus its menu. Both are the window's
//!     own state, so this module reads them back rather than caching a value
//!     that the user can change in the titlebar.
//!
//! Every window here is borrowed from SDL: the caller owns the
//! `sdl3.video.Window` and the `NSWindow` behind it, and the registry below
//! only remembers the pairing so a platform callback can be named with the
//! SDL window id its model already uses.
const std = @import("std");
const sdl3 = @import("sdl3");
const native = @import("native.zig");

const Error = native.Error;
const Status = native.Status;

/// One window the host has registered, and the platform handle behind it.
pub const Entry = struct {
    id: sdl3.video.WindowId,
    window: native.NativeWindow,
};

/// Which end of a tab group a merge places a window at.
pub const Order = enum {
    above,
    below,
};

/// The tabbing policy a window asks for before it is shown.
pub const TabbingMode = enum {
    /// Let the system decide, from the user's preference and the grouping
    /// identifier. This is AppKit's default.
    automatic,
    /// Prefer to open in a tab. The host asks for this when it is the kind of
    /// window a person expects to file beside its siblings.
    preferred,
    /// Never open in a tab.
    disallowed,
};

/// The user's own tabbing preference, as System Settings has it.
pub const UserPreference = enum {
    manual,
    always,
    in_full_screen,
};

/// A window in a tab group, in the order its tab is shown.
pub const TabbedWindow = struct {
    id: sdl3.video.WindowId,
    handle: *anyopaque,
};

/// The group a window belongs to, read back from AppKit after every change.
///
/// `unmapped` counts tabs whose window the host never registered. It is
/// reported rather than dropped, because a group that silently loses a tab is
/// worse than one that says it could not name it.
pub const TabGroup = struct {
    windows: []const TabbedWindow = &.{},
    /// The selected tab, or null when the group is not the focused one.
    selected: ?sdl3.video.WindowId = null,
    /// The group has more tabs than `windows` holds.
    truncated: bool = false,
    /// Tabs AppKit reported that this registry could not name.
    unmapped: usize = 0,

    pub fn count(self: TabGroup) usize {
        return self.windows.len;
    }

    pub fn indexOf(self: TabGroup, id: sdl3.video.WindowId) ?usize {
        for (self.windows, 0..) |entry, index| {
            if (entry.id == id) return index;
        }
        return null;
    }

    pub fn isEmpty(self: TabGroup) bool {
        return self.windows.len == 0;
    }
};

/// The outcome of one tab operation, always read back from the platform.
///
/// Every arm here is a fact the caller can act on. A refused merge and an
/// unmerged group are different answers, and neither is reported as success.
pub const TabOutcome = union(enum) {
    /// The change took effect, and this is the group as AppKit now reports it.
    applied: TabGroup,
    /// The window shows no tab bar, so the operation had no target.
    not_tabbed,
    /// The window is not the selected tab of its group, and only the selected
    /// tab can be detached.
    not_selected,
    /// The group holds fewer than two tabs, so there is no next or previous.
    single_tab,
    /// AppKit refused: mismatched grouping identifiers, for example.
    refused,
    /// This system does not offer the operation.
    unsupported,
    /// The window is not registered here, so it has no platform handle.
    unknown_window,
};

/// The windows the host has borrowed, and the handles behind them.
///
/// A `Registry` is a set of pairings, not an owner: it holds the
/// `sdl3.video.Window` value the host already owns, and its `deinit` releases
/// nothing native.
pub const Registry = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    /// Borrow the NSWindow behind `window` and remember the pairing. A window
    /// that is already registered is replaced, because a re-attach means SDL
    /// handed back the same id for a new window.
    pub fn attach(self: *Registry, window: sdl3.video.Window) !Error!void {
        const borrowed = (try native.NativeWindow.borrow(window)) orelse return error.Unsupported;
        for (self.entries.items) |*entry| {
            if (entry.id == borrowed.id) {
                entry.* = .{ .id = borrowed.id, .window = borrowed };
                return;
            }
        }
        self.entries.append(self.gpa, .{ .id = borrowed.id, .window = borrowed }) catch
            return error.OutOfMemory;
    }

    /// Forget a window the host closed. A later platform callback that names
    /// it finds nothing, which is what a closed window should look like.
    pub fn detach(self: *Registry, id: sdl3.video.WindowId) void {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.id != id) continue;
            _ = self.entries.swapRemove(index);
            return;
        }
    }

    pub fn find(self: *const Registry, id: sdl3.video.WindowId) ?native.NativeWindow {
        for (self.entries.items) |entry| {
            if (entry.id == id) return entry.window;
        }
        return null;
    }

    pub fn idOf(self: *const Registry, handle: *anyopaque) ?sdl3.video.WindowId {
        for (self.entries.items) |entry| {
            if (entry.window.handle == handle) return entry.id;
        }
        return null;
    }

    pub fn count(self: *const Registry) usize {
        return self.entries.items.len;
    }

    /// Read the tab group of one window.
    ///
    /// The `windows` slice is owned by the caller through `gpa` and released
    /// with `TabGroup.deinit`, because the group is a reading of the platform
    /// and not a view into a longer-lived structure.
    pub fn group(
        self: *const Registry,
        gpa: std.mem.Allocator,
        id: sdl3.video.WindowId,
    ) Error!TabGroup {
        if (!native.available) return error.ShimUnavailable;
        const window = self.find(id) orelse return error.BadArgument;
        return self.groupOf(gpa, window);
    }

    pub fn groupOf(
        self: *const Registry,
        gpa: std.mem.Allocator,
        window: native.NativeWindow,
    ) Error!TabGroup {
        if (!native.available) return error.ShimUnavailable;
        // SAFETY: the shim fills this whole record before it returns, and a
        // status other than `.unavailable` below only reads what it wrote.
        var raw: native.shim.nogui_macos_tabs = undefined;
        const status = Status.of(native.shim.nogui_macos_tab_group(window.handle, &raw));
        if (status == .unavailable) return .{};
        if (!status.isOk()) return native.fail(status);

        const tab_count: usize = @intCast(raw.count);
        const windows = gpa.alloc(TabbedWindow, tab_count) catch return error.OutOfMemory;
        var mapped: usize = 0;
        var unmapped: usize = 0;
        for (0..tab_count) |index| {
            const handle = raw.windows[index];
            if (self.idOf(handle)) |found| {
                windows[mapped] = .{ .id = found, .handle = handle };
                mapped += 1;
            } else {
                unmapped += 1;
            }
        }
        const selected: ?sdl3.video.WindowId = if (raw.selected) |handle| self.idOf(handle) else null;
        return .{
            .windows = gpa.realloc(TabbedWindow, windows[0..mapped], mapped) catch windows[0..mapped],
            .selected = selected,
            .truncated = raw.truncated != 0,
            .unmapped = unmapped,
        };
    }

    /// Release a group's window slice. Every other field is a value.
    pub fn releaseGroup(_: *const Registry, gpa: std.mem.Allocator, reading: TabGroup) void {
        gpa.free(reading.windows);
    }
};

/// The shim's bindings, reached through the one import that opened them.
fn nativeShim() @TypeOf(native.shim) {
    return native.shim;
}

/// Merge `guest` into the group `host` shows, before or after it.
pub fn merge(
    registry: *const Registry,
    gpa: std.mem.Allocator,
    host: sdl3.video.WindowId,
    guest: sdl3.video.WindowId,
    order: Order,
) Error!TabOutcome {
    if (!native.available) return error.ShimUnavailable;
    const host_window = registry.find(host) orelse return .unknown_window;
    const guest_window = registry.find(guest) orelse return .unknown_window;
    const shim = nativeShim();
    // AppKit refuses when the two windows disagree about the grouping
    // identifier, and it refuses a worker thread by being AppKit. Those used to
    // arrive as the same NULL parent, so a caller off the main thread was told
    // the windows were incompatible and never hopped the thread. The shim
    // reports them apart.
    //
    // The shim writes back the parent AppKit chose, which names the window
    // that ends up hosting the bar. That is not a membership fact, so nothing
    // is read from it: the group below is read from the window the caller
    // named, because every tab of a group answers `tabbedWindows` alike.
    var parent: ?*anyopaque = null;
    const status = Status.of(shim.nogui_macos_tab_merge(
        host_window.handle,
        guest_window.handle,
        if (order == .above) 1 else 0,
        &parent,
    ));
    if (status == .refused) return .refused;
    if (!status.isOk()) return native.fail(status);
    const group = try registry.group(gpa, host);
    return .{ .applied = group };
}

/// Fold every window this application shows into one tabbed window.
pub fn mergeAll(registry: *const Registry, gpa: std.mem.Allocator, id: sdl3.video.WindowId) Error!TabOutcome {
    if (!native.available) return error.ShimUnavailable;
    const window = registry.find(id) orelse return .unknown_window;
    const status = Status.of(nativeShim().nogui_macos_tab_merge_all(window.handle));
    if (status == .unavailable) return .not_tabbed;
    if (!status.isOk()) return native.fail(status);
    return .{ .applied = try registry.group(gpa, id) };
}

/// Select the next tab in the trailing direction.
pub fn selectNext(registry: *const Registry, gpa: std.mem.Allocator, id: sdl3.video.WindowId) Error!TabOutcome {
    return navigate(registry, gpa, id, true);
}

/// Select the previous tab in the leading direction.
pub fn selectPrevious(registry: *const Registry, gpa: std.mem.Allocator, id: sdl3.video.WindowId) Error!TabOutcome {
    return navigate(registry, gpa, id, false);
}

fn navigate(
    registry: *const Registry,
    gpa: std.mem.Allocator,
    id: sdl3.video.WindowId,
    forward: bool,
) Error!TabOutcome {
    if (!native.available) return error.ShimUnavailable;
    const window = registry.find(id) orelse return .unknown_window;
    const shim = nativeShim();
    const status = Status.of(if (forward)
        shim.nogui_macos_tab_select_next(window.handle)
    else
        shim.nogui_macos_tab_select_previous(window.handle));
    if (status == .unavailable) {
        // The shim cannot tell "this group holds no next tab" from "this
        // system offers no such selector", and it answers both the same way.
        // They are two different facts a caller acts on differently, so the
        // group is read here instead of reporting the wrong one.
        const group = try registry.group(gpa, id);
        defer registry.releaseGroup(gpa, group);
        return refusedNavigation(group);
    }
    if (!status.isOk()) return native.fail(status);
    return .{ .applied = try registry.group(gpa, id) };
}

/// The arm a refused navigation names.
///
/// One tab has neither a next nor a previous, and a system with no such
/// selector cannot navigate at all however many tabs it holds. Only the group
/// separates the two, so it decides which of them the caller is told.
fn refusedNavigation(group: TabGroup) TabOutcome {
    return if (group.count() < 2) .single_tab else .unsupported;
}

/// Move this tab out into a window of its own.
///
/// Only the selected tab can be detached, because `moveTabToNewWindow:` acts
/// on the selection and AppKit publishes no way to select an arbitrary tab.
/// A request for another tab is refused instead of detaching the wrong one.
pub fn detach(registry: *const Registry, gpa: std.mem.Allocator, id: sdl3.video.WindowId) Error!TabOutcome {
    if (!native.available) return error.ShimUnavailable;
    const window = registry.find(id) orelse return .unknown_window;
    const shim = nativeShim();
    const status = Status.of(shim.nogui_macos_tab_detach(window.handle));
    if (status == .unavailable) return .not_tabbed;
    if (status == .refused) return .not_selected;
    if (!status.isOk()) return native.fail(status);
    const group = try registry.group(gpa, id);
    // Read back like every other outcome, so this is the group AppKit holds
    // AFTER the move, and a lone tab reads as an empty group. The group the
    // tab left is not what this reports: `applied` names the group as AppKit
    // now reports it for every arm of this union, and after the move there is
    // no group of its own to report.
    return .{ .applied = group };
}

/// Ask for a window's tabbing policy. This is a before-show setting, exactly
/// as AppKit documents it.
pub fn setTabbingMode(window: native.NativeWindow, mode: TabbingMode) Error!void {
    if (!native.available) return error.ShimUnavailable;
    const wire: c_int = switch (mode) {
        .automatic => 0,
        .preferred => 1,
        .disallowed => 2,
    };
    try native.check(Status.of(nativeShim().nogui_macos_tab_set_mode(window.handle, wire)));
}

/// The tabbing policy AppKit currently holds for a window.
///
/// 0 automatic, 1 preferred, 2 disallowed. A negative return is a
/// NOGUI_MACOS_ERR_* refusal; a value outside the set is a policy this
/// adapter cannot report, which is the same answer as a system with no
/// tabbing at all.
pub fn tabbingMode(window: native.NativeWindow) Error!TabbingMode {
    if (!native.available) return error.ShimUnavailable;
    const raw = nativeShim().nogui_macos_tab_mode(window.handle);
    if (raw < 0) return native.fail(Status.of(raw));
    return switch (raw) {
        0 => .automatic,
        1 => .preferred,
        2 => .disallowed,
        else => error.Unsupported,
    };
}

/// Windows sharing a grouping identifier may tab together automatically.
pub fn setGroupingIdentifier(window: native.NativeWindow, identifier: []const u8) Error!void {
    if (!native.available) return error.ShimUnavailable;
    var scratch = native.Scratch.init(std.heap.page_allocator);
    defer scratch.deinit();
    const owned = (try scratch.nul(identifier)) orelse return error.BadArgument;
    try native.check(Status.of(nativeShim().nogui_macos_tab_set_identifier(window.handle, owned)));
}

/// Whether this application lets the system organize windows into tabs.
pub fn setAllowsAutomaticGrouping(enabled: bool) Error!void {
    if (!native.available) return error.ShimUnavailable;
    try native.check(Status.of(nativeShim().nogui_macos_tab_allows_automatic(
        if (enabled) 1 else 0,
    )));
}

/// The user's tabbing preference. A host reads this before it shows a window
/// so it can honour what the person actually chose in System Settings.
///
/// 0 manual, 1 always, 2 in full screen, or a refusal.
pub fn userTabbingPreference() Error!UserPreference {
    if (!native.available) return error.ShimUnavailable;
    const raw = nativeShim().nogui_macos_tab_user_preference();
    if (raw < 0) return native.fail(Status.of(raw));
    return switch (raw) {
        0 => .manual,
        1 => .always,
        2 => .in_full_screen,
        else => error.Unsupported,
    };
}

/// Whether the title and the titlebar buttons are drawn.
pub const TitleVisibility = enum {
    visible,
    hidden,
};

/// The one-line AppKit draws between the titlebar and the content.
pub const SeparatorStyle = enum {
    /// Follow the system's own appearance.
    automatic,
    none,
    line,
    shadow,
};

/// The three window buttons, plus the full-screen one a tabbed window adds.
pub const Button = enum {
    close,
    miniaturize,
    zoom,
    full_screen,
};

/// Titlebar control. Every read reports what AppKit holds after the change,
/// because a window's style mask can make a control unavailable.
pub const Titlebar = struct {
    window: native.NativeWindow,

    fn shim() @TypeOf(native.shim) {
        return native.shim;
    }

    /// 0 visible, 1 hidden; a negative return is a NOGUI_MACOS_ERR_* refusal.
    /// A value outside the set is a visibility this adapter cannot report.
    fn visibilityOf(raw: c_int) Error!TitleVisibility {
        if (raw < 0) return native.fail(Status.of(raw));
        return switch (raw) {
            0 => .visible,
            1 => .hidden,
            else => error.Unsupported,
        };
    }

    /// Set the title. AppKit draws an empty title as no title at all, which is
    /// a legitimate state and not a failed write.
    pub fn setTitle(self: Titlebar, value: []const u8) Error!void {
        if (!native.available) return error.ShimUnavailable;
        var scratch = native.Scratch.init(std.heap.page_allocator);
        defer scratch.deinit();
        const owned = (try scratch.nul(value)) orelse return error.BadArgument;
        try native.check(Status.of(shim().nogui_macos_window_set_title(self.window.handle, owned)));
    }

    /// The title AppKit is showing.
    pub fn title(self: Titlebar, gpa: std.mem.Allocator) Error![]u8 {
        return native.readString(gpa, .window_title, 0, self.window.handle);
    }

    /// Show or hide the title and the standard buttons. `null` reads.
    ///
    /// AppKit's own answer is read back rather than assumed, so a window whose
    /// style mask ignores the request reports what it actually draws.
    pub fn setVisibility(self: Titlebar, next: ?TitleVisibility) Error!TitleVisibility {
        if (!native.available) return error.ShimUnavailable;
        const wire: c_int = switch (next orelse return error.BadArgument) {
            .visible => 0,
            .hidden => 1,
        };
        return visibilityOf(shim().nogui_macos_window_title_visibility(self.window.handle, wire));
    }

    /// The visibility AppKit holds, without changing it.
    pub fn visibility(self: Titlebar) Error!TitleVisibility {
        if (!native.available) return error.ShimUnavailable;
        return visibilityOf(shim().nogui_macos_window_title_visibility(self.window.handle, -1));
    }

    /// Make the titlebar draw no background of its own, so a client can paint
    /// under it. `null` reads.
    pub fn setTransparent(self: Titlebar, next: ?bool) Error!bool {
        if (!native.available) return error.ShimUnavailable;
        const wire: c_int = switch (next orelse return error.BadArgument) {
            false => 0,
            true => 1,
        };
        return native.fact(shim().nogui_macos_window_titlebar_transparent(self.window.handle, wire));
    }

    pub fn transparent(self: Titlebar) Error!bool {
        if (!native.available) return error.ShimUnavailable;
        return native.fact(shim().nogui_macos_window_titlebar_transparent(self.window.handle, -1));
    }

    /// The separator style. A system older than macOS 11 has no public
    /// separator control at all and reports `unsupported`.
    ///
    /// 0 automatic, 1 none, 2 line, 3 shadow; a negative return is a
    /// NOGUI_MACOS_ERR_* refusal and a value outside the set is a style this
    /// adapter cannot report.
    pub fn setSeparator(self: Titlebar, style: SeparatorStyle) Error!SeparatorStyle {
        if (!native.available) return error.ShimUnavailable;
        const wire: c_int = switch (style) {
            .automatic => 0,
            .none => 1,
            .line => 2,
            .shadow => 3,
        };
        const raw = shim().nogui_macos_window_titlebar_separator(self.window.handle, wire);
        if (raw < 0) return native.fail(Status.of(raw));
        return switch (raw) {
            0 => .automatic,
            1 => .none,
            2 => .line,
            3 => .shadow,
            else => error.Unsupported,
        };
    }

    /// Show or hide one standard button. `null` reads. A window whose style
    /// mask has no such button reports `unsupported` instead of changing
    /// something that is not there.
    pub fn setButtonVisible(self: Titlebar, button: Button, visible: ?bool) Error!bool {
        if (!native.available) return error.ShimUnavailable;
        const kind: c_int = switch (button) {
            .close => 0,
            .miniaturize => 1,
            .zoom => 2,
            .full_screen => 3,
        };
        // Null is a READ. The shim's read sentinel is -1 for every reader on
        // this window, buttons included, and refusing here would make this
        // reader fail on every call and no caller could learn whether the
        // button is shown.
        const wire: c_int = if (visible) |value| (if (value) 1 else 0) else -1;
        return native.fact(shim().nogui_macos_window_button_visible(
            self.window.handle,
            kind,
            wire,
        ));
    }

    pub fn buttonVisible(self: Titlebar, button: Button) Error!bool {
        return self.setButtonVisible(button, null);
    }
};

/// The document a window represents: its edited flag and its path.
///
/// Both live in the window, so a person can change either one from the
/// titlebar. Everything here reads the window's own state back rather than
/// trusting a value the caller sent earlier.
pub const Document = struct {
    window: native.NativeWindow,

    fn shim() @TypeOf(native.shim) {
        return native.shim;
    }

    /// The flag macOS uses to decide whether closing needs a confirmation.
    pub fn setEdited(self: Document, edited: bool) Error!bool {
        if (!native.available) return error.ShimUnavailable;
        return native.fact(shim().nogui_macos_window_document_edited(
            self.window.handle,
            if (edited) 1 else 0,
        ));
    }

    pub fn isEdited(self: Document) Error!bool {
        if (!native.available) return error.ShimUnavailable;
        return native.fact(shim().nogui_macos_window_document_edited(self.window.handle, -1));
    }

    /// Set the proxy icon's path. A null path clears it, which is how a window
    /// stops claiming to represent a file.
    pub fn setPath(self: Document, value: ?[]const u8) Error!void {
        if (!native.available) return error.ShimUnavailable;
        var owned = try OwnedPath.init(value);
        defer owned.deinit();
        try native.check(Status.of(shim().nogui_macos_window_set_represented_path(
            self.window.handle,
            owned.bytes,
        )));
    }

    /// The NUL-terminated copy one proxy-icon write needs.
    ///
    /// The shim reads the path while the call runs and copies what it keeps,
    /// so the buffer has to be alive for the whole call and no longer. A
    /// scratch built inside the expression that produced the pointer is
    /// released the moment that expression ends, which is before the shim has
    /// read a byte of it, so the copy is owned by a value the call site holds
    /// across the call instead.
    const OwnedPath = struct {
        scratch: native.Scratch,
        bytes: ?[*:0]const u8,

        fn init(value: ?[]const u8) Error!OwnedPath {
            var owned: OwnedPath = .{
                .scratch = native.Scratch.init(std.heap.page_allocator),
                .bytes = null,
            };
            errdefer owned.scratch.deinit();
            owned.bytes = if (value) |text| try owned.scratch.nul(text) else null;
            return owned;
        }

        fn deinit(self: *OwnedPath) void {
            self.scratch.deinit();
            self.* = undefined;
        }
    };

    /// The path the window currently represents, or an empty slice when it
    /// represents nothing.
    pub fn path(self: Document, gpa: std.mem.Allocator) Error![]u8 {
        return native.readString(gpa, .window_represented_path, 0, self.window.handle);
    }
};

test "api-w23 macos title visibility is read as a value, not as a status" {
    try std.testing.expectEqual(TitleVisibility.visible, try Titlebar.visibilityOf(0));
    try std.testing.expectEqual(TitleVisibility.hidden, try Titlebar.visibilityOf(1));
    // A window with no titled style mask, and a system that has no titlebar
    // control at all, are two different refusals. Both are facts about the
    // platform; neither is a framework fault.
    try std.testing.expectError(Error.Unsupported, Titlebar.visibilityOf(-5));
    try std.testing.expectError(Error.BadArgument, Titlebar.visibilityOf(-2));
}

test "api-w23 macos document path copy is owned across the call that reads it" {
    // The shim reads the path while the call runs, so the copy has to outlive
    // the expression that made it. The test reads the same bytes, out of the
    // same owner the call site hands them from.
    var owned = try Document.OwnedPath.init("/tmp/nogui/notes.txt");
    defer owned.deinit();
    try std.testing.expectEqualStrings("/tmp/nogui/notes.txt", std.mem.span(owned.bytes.?));

    // A window that stops representing a file clears its proxy icon with a
    // NULL path. That is a different answer from an empty string, which the
    // shim would take for a path and hand to NSURL.
    var cleared = try Document.OwnedPath.init(null);
    defer cleared.deinit();
    try std.testing.expectEqual(@as(?[*:0]const u8, null), cleared.bytes);

    // The copy is the caller's bytes and not a view into them: a caller that
    // reuses its buffer after handing the path over must not change what the
    // window is told it represents.
    var source = [_]u8{ '/', 'a' };
    var borrowed = try Document.OwnedPath.init(&source);
    defer borrowed.deinit();
    source[1] = 'z';
    try std.testing.expectEqualStrings("/a", std.mem.span(borrowed.bytes.?));

    // A path longer than the shim copies is refused here, before a buffer is
    // built for it.
    try std.testing.expectError(Error.BadArgument, Document.OwnedPath.init("x" ** (native.max_text + 1)));
}

test "api-w23 macos a refused navigation names the fact the shim could not" {
    // One tab has neither a next nor a previous. Two tabs on a system that
    // offers no `selectNextTab:` cannot navigate either, and telling the
    // caller its group is a single tab sends it looking for a group problem
    // it does not have.
    //
    // SAFETY: no handle below is dereferenced. `refusedNavigation` counts the
    // windows it was handed and reads nothing inside them.
    const one: [1]TabbedWindow = .{.{ .id = 1, .handle = @ptrFromInt(0x1000) }};
    const two: [2]TabbedWindow = .{
        .{ .id = 1, .handle = @ptrFromInt(0x1000) },
        .{ .id = 2, .handle = @ptrFromInt(0x2000) },
    };
    try std.testing.expectEqual(TabOutcome.single_tab, refusedNavigation(.{}));
    try std.testing.expectEqual(
        TabOutcome.single_tab,
        refusedNavigation(.{ .windows = one[0..] }),
    );
    try std.testing.expectEqual(
        TabOutcome.unsupported,
        refusedNavigation(.{ .windows = two[0..] }),
    );
}

test "api-w23 macos tab operations refuse a build with no shim" {
    if (comptime native.available) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var registry = Registry.init(gpa);
    defer registry.deinit();
    // An empty registry, so every one of these would otherwise answer
    // `unknown_window` and send a caller looking for a registry problem. A
    // build with no AppKit has no tab to name at all, which is a different
    // fact and the one that has to come first.
    try std.testing.expectError(error.ShimUnavailable, registry.group(gpa, 1));
    try std.testing.expectError(error.ShimUnavailable, registry.groupOf(gpa, .{
        .handle = @ptrFromInt(0x1234),
        .id = 1,
        .window = .{ .value = @ptrFromInt(0x1234) },
    }));
    try std.testing.expectError(error.ShimUnavailable, merge(&registry, gpa, 1, 2, .above));
    try std.testing.expectError(error.ShimUnavailable, mergeAll(&registry, gpa, 1));
    try std.testing.expectError(error.ShimUnavailable, selectNext(&registry, gpa, 1));
    try std.testing.expectError(error.ShimUnavailable, selectPrevious(&registry, gpa, 1));
    try std.testing.expectError(error.ShimUnavailable, detach(&registry, gpa, 1));
}
