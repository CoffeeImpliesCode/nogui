//! E05: the Windows accessibility adapter.
//!
//! The semantic tree, the action queue, the character/byte offset conversion and
//! the diffing are the SHARED adapter's, in `../accessibility.zig`, and this
//! module reuses them rather than reimplementing them. What it owns is the part
//! that is Windows:
//!
//!   * ATTACHING. UI Automation is built around a window: the bridge subclasses
//!     the window procedure to receive `WM_GETOBJECT`, so a handle from
//!     `nogui_accesskit_bridge_new` is valid and inert until this module hands it
//!     the window. The `HWND` comes from SDL's own window property through
//!     `window_interop`, which is the one place in this directory that reads a
//!     native window handle, and the window is borrowed for the whole lifetime of
//!     the attachment.
//!   * THREAD AND VISIBILITY. The subclass has to be installed on the thread
//!     that owns the window and before that window is first shown, because
//!     `SubclassingAdapter::new` refuses a window that is already visible. The
//!     bridge reports both refusals as a failed attach, so a host learns the
//!     answer from `error.Refused` rather than from a tree that never appears.
//!   * SCALE. The shared adapter publishes physical pixels and is told the
//!     logical-to-physical factor by its host. On Windows that factor is the
//!     window's own DPI, and UI Automation derives its rectangles from the
//!     physical pixels the window procedure is handed, so the two agree only
//!     when the tree is scaled by the same number.
//!   * FOCUS AND BOUNDS. Both are facts the window procedure already carries:
//!     `accesskit_windows` turns `WM_SETFOCUS` and `WM_KILLFOCUS` into its own
//!     focus state, and there is no X11-style outer/client split to hand it. So
//!     this module forwards neither. A second copy of a fact the platform already
//!     holds is a value nothing reads.
//!
//! WHAT THE ADAPTER ITSELF TRANSLATES. Nothing, and that is the audited
//! answer rather than an accident. Role, name, value, range, states and
//! actions are all built by the shared encoder and reach UI Automation
//! through it unchanged, so there is no second place on this target where a
//! published field can be dropped: `attach` subclasses a window and nothing
//! else, and every field a caller reads back through `lastRole`,
//! `lastLabel`, `lastValue`, `lastNumericValue`, `lastFlags` and `lastActions`
//! is the value the bridge received. `Error` names the three absences apart —
//! `NotWindows`, `Unsupported` and `NoNativeWindow` are all "there is nothing
//! to attach", and `Refused` is a live platform that said no — so a missing
//! capability is never reported as an empty successful one.
//!
//! TRUST. There is no Windows counterpart to macOS's `AXIsProcessTrusted`: a
//! process serves a UI Automation tree to whoever asks for it, in its own
//! session, with no per-application grant to read. So there is nothing here to
//! read and nothing a host has to be told to go and ask for. What it can be
//! told is `screenReaderAsked`, and that is a different fact from a live
//! adapter no screen reader is currently reading.
//!
//! Target gating follows `win32.zig`: every call into the platform is behind
//! `if (comptime !is_windows)`, so a build without Windows never emits a
//! reference to `user32` and reports a named refusal instead of pretending.
const std = @import("std");
const sdl3 = @import("sdl3");
const win = @import("win32.zig");
const window_interop = @import("window_interop.zig");
const shared = @import("../accessibility.zig");

/// The AccessKit C ABI, opened here rather than through a shim.
///
/// Every host adapter uses the same translated canonical bridge header.
const bridge = @import("nogui_accesskit_c");

/// The shared adapter. Its semantics, its action queue, its offsets and its
/// tree diffing are the ones every target uses, unchanged.
pub const Adapter = shared.Adapter;
pub const State = shared.State;
pub const Capability = shared.Capability;
pub const Bell = shared.Bell;
pub const NodeId = shared.NodeId;
/// The shared tree-publication errors, named apart from the native ones so a
/// caller can tell a capacity failure from a platform refusal.
pub const TreeError = shared.Error;
pub const max_nodes = shared.max_nodes;
pub const max_queue = shared.max_queue;
pub const characterIndexOf = shared.characterIndexOf;
pub const byteOffsetOf = shared.byteOffsetOf;

/// The window handle the attach binds to, named here so a caller does not have
/// to reach into `window_interop` for it.
pub const Hwnd = window_interop.Hwnd;

/// Whether this build has the AccessKit bridge linked. Without it the shared
/// adapter reports `State.unavailable` and every call here refuses.
pub const linked = shared.linked;

pub const Error = error{
    /// This build has no Windows platform to ask.
    NotWindows,
    /// The build does not link the AccessKit bridge, or the shared adapter
    /// never got one. There is no adapter to attach, which is not the same
    /// answer as a platform that refused the window.
    Unsupported,
    /// The window published no native window handle. SDL was not on the `windows`
    /// driver, so there is no window for the bridge to subclass.
    NoNativeWindow,
    /// The platform refused the attachment: a null handle, a window that is
    /// already visible, an adapter that is already attached, or a panic the
    /// bridge caught at its own boundary.
    Refused,
};

/// Attach the shared adapter to the window SDL owns.
///
/// The window is borrowed: the bridge subclasses its window procedure, and that
/// subclass lives as long as the bridge. So the caller must `detach` before
/// destroying the window, and the attach has to happen on the thread that owns
/// the window and before it is first shown.
pub fn attach(adapter: *Adapter, window: sdl3.video.Window) Error!void {
    if (comptime !win.is_windows) return error.NotWindows;
    if (comptime !linked) return error.Unsupported;
    // One definition of where a window handle comes from: an SDL window property
    // on the `windows` driver, and nothing else. A handle on any other driver is
    // not a window on this system, whatever the property store holds.
    const handles = window_interop.readHandles(window);
    if (!handles.usesWin32()) return error.NoNativeWindow;
    const hwnd = handles.hwnd orelse return error.NoNativeWindow;
    // The shared adapter holds its bridge privately and hands it out through
    // `bridgeHandle`, because a target adapter has to attach a native window to
    // a bridge the shared adapter owns. The handle is opaque on both sides: it
    // is the same pointer, and the C ABI is the only thing that names its type.
    const bridge_ptr: *bridge.nogui_accesskit_bridge =
        @ptrCast(adapter.bridgeHandle() orelse return error.Unsupported);
    if (bridge.nogui_accesskit_bridge_windows_attach(bridge_ptr, hwnd) == false) {
        return error.Refused;
    }
    // The shared adapter publishes physical pixels, and UI Automation reads them
    // as physical, so the tree is scaled by this window's own factor. A window
    // that is not at 100% scaling would otherwise publish a tree every box of
    // which is the wrong size.
    const scale = window_interop.dpiScaleOf(hwnd);
    adapter.setScale(scale, scale);
}

/// Detach before the window goes away.
///
/// The bridge owns the subclassed window procedure, and dropping the bridge
/// restores the window's own, so a window destroyed with the bridge still
/// attached would keep a window procedure pointing at freed Rust.
pub fn detach(adapter: *Adapter) void {
    adapter.deinit();
}

/// Whether a screen reader has asked this adapter for the tree.
///
/// This is a fact about the platform and not about this module, and it is worth
/// being exact about: UI Automation does not report a client leaving the way
/// AT-SPI does, so the bridge latches this once a client has asked and it stays
/// true. `true` therefore means "something has been published to a client", not
/// "a client is listening at this instant", and there is no honest way to answer
/// the second question from here.
///
/// Whether a window is bound at all is a fact the caller already has: it is
/// whether `attach` returned, and the window it borrowed.
pub fn screenReaderAsked(adapter: *Adapter) bool {
    return adapter.stateOf() == .active;
}

test "api-w23 a windows accessibility attach is a named refusal off windows" {
    // Off Windows there is no window procedure to subclass and no UI Automation
    // client to answer, so the attach refuses by name instead of binding
    // something that cannot serve a tree.
    if (comptime !win.is_windows) {
        const gpa = std.testing.allocator;
        var adapter: Adapter = undefined;
        adapter.initWithoutBridge(gpa, std.testing.io);
        defer adapter.deinit();
        try std.testing.expect(!screenReaderAsked(&adapter));
        try std.testing.expectError(
            error.NotWindows,
            attach(&adapter, .{ .value = @ptrFromInt(0x1234) }),
        );
    }
}

test "api-w23 a windows accessibility adapter with no bridge serves nothing" {
    // A build without the bridge, or an adapter that never got one, has nothing
    // to attach: the handle is null and the state is unavailable. That is what a
    // host sees before `init`, and it is not a live adapter waiting for a
    // window.
    const gpa = std.testing.allocator;
    var adapter: Adapter = undefined;
    adapter.initWithoutBridge(gpa, std.testing.io);
    defer adapter.deinit();

    try std.testing.expect(adapter.bridgeHandle() == null);
    try std.testing.expectEqual(State.unavailable, adapter.stateOf());
    try std.testing.expect(!screenReaderAsked(&adapter));
}

test "api-w23 a windows adapter reports an absent capability as absent, not as an empty one" {
    // The distinction the audit turns on: a capability this build does not have
    // is a FALSE, and an empty but successful tree would be a platform that
    // served nothing and said so. Every field of the report is false here, so
    // no caller can read "attached, nothing to say" out of it.
    const gpa = std.testing.allocator;
    var adapter: Adapter = undefined;
    adapter.initWithoutBridge(gpa, std.testing.io);
    defer adapter.deinit();

    const capability = adapter.capability();
    try std.testing.expect(!capability.adapter);
    try std.testing.expect(!capability.screen_reader);
    // A bell is a separate fact from an accessibility bus, and a build with
    // neither reports this one absent rather than assuming it.
    try std.testing.expect(!capability.bell);
    try std.testing.expect(!adapter.systemBellAvailable());
}

test "api-w23 a windows accessibility refusal names the target before the build" {
    // Three absences and one refusal are four answers, and collapsing any two
    // of them would tell a host that a platform it cannot reach said no. The
    // order is part of that: `attach` checks the TARGET first, so a build that
    // has no bridge still names the target, which is the fact that outranks
    // every other one.
    if (comptime !win.is_windows) {
        const gpa = std.testing.allocator;
        var adapter: Adapter = undefined;
        adapter.initWithoutBridge(gpa, std.testing.io);
        defer adapter.deinit();

        // `NotWindows`, not `Unsupported`: the target is missing even though
        // this build also has no bridge to attach, and reporting the lesser
        // absence would send a host looking for a link that is not the problem.
        try std.testing.expectError(
            error.NotWindows,
            attach(&adapter, .{ .value = @ptrFromInt(0x1234) }),
        );
    }
}

test "api-w23 a windows adapter with no bridge answers every read-back with absence" {
    // The adapter has no tree of its own to read, and a read-back that
    // invented one would be a field the bridge never received. Every accessor
    // returns null rather than a zero that reads like a published fact.
    const gpa = std.testing.allocator;
    var adapter: Adapter = undefined;
    adapter.initWithoutBridge(gpa, std.testing.io);
    defer adapter.deinit();

    // An identity no publication ever carried, which is what every read-back
    // below is asked about.
    const absent: NodeId = 0;
    try std.testing.expect(adapter.lastRole(absent) == null);
    try std.testing.expect(adapter.lastLabel(absent) == null);
    try std.testing.expect(adapter.lastValue(absent) == null);
    try std.testing.expect(adapter.lastNumericValue(absent) == null);
    try std.testing.expect(adapter.lastFlags(absent) == null);
    try std.testing.expect(adapter.lastActions(absent) == null);
    try std.testing.expect(adapter.lastSetPosition(absent) == null);
    try std.testing.expect(adapter.lastMemberOf(absent) == null);
    try std.testing.expect(adapter.lastCharacterLengths(absent) == null);
    try std.testing.expect(adapter.lastTextSelection(absent) == null);
    try std.testing.expect(adapter.lastTextSelectionOwner(absent) == null);
    // Nothing was published, so no update claimed to be a declaration.
    try std.testing.expect(!adapter.lastWasFullTree());
    var ids: [4]NodeId = undefined;
    try std.testing.expectEqual(@as(usize, 0), adapter.lastNodes(&ids).len);
}
