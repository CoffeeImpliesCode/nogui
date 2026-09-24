//! E06: the preferences macOS publishes, for the shared W18 reads.
//!
//! TWO FACTS, each from a named Apple API, and nothing beside them:
//!
//!   * SCROLL BAR VISIBILITY, from `NSScroller.preferredScrollerStyle`. Apple
//!     documents that value as the Appearance panel's "Show scroll bars"
//!     setting for the current user and — when the user chose "Automatically
//!     based on input device" — as a function of the connected pointing devices
//!     and their scroll capability settings:
//!     https://developer.apple.com/documentation/appkit/nsscroller/preferredscrollerstyle
//!     `NSScrollerStyle` is exactly `legacy` or `overlay`:
//!     https://developer.apple.com/documentation/appkit/nscroller/style
//!   * THERMAL STATE, from `NSProcessInfo.thermalState`, which is the state the
//!     system reports rather than a sensor reading this module interpreted:
//!     https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property
//!     `NSProcessInfoThermalState` is nominal, fair, serious or critical:
//!     https://developer.apple.com/documentation/foundation/nsprocessinfothermalstate
//!
//! ONE FACT macOS DOES NOT PUBLISH: a scroll-to-click preference. AppKit's
//! scroller API has no selector for one — `NSScroller` exposes the knob, the
//! arrows, the style and the hit part, and nothing about what a click means —
//! and Apple documents no defaults key for it either. `pageScroll` is a
//! per-view scroll amount, not a user preference. So there is no entry point
//! here that could answer it, and the shared read keeps `jump_to_click` null:
//! reporting `false` would claim a click behaviour nothing here observed.
//!
//! NOTHING HERE IS DERIVED. The shim compares the SDK's own constants instead
//! of decoding ordinals, and a value this SDK does not name comes back as
//! NOGUI_MACOS_ERR_UNAVAILABLE rather than being rounded into the nearest
//! answer it does know. A temperature is not a thermal state, so no reading
//! here is built out of one.
//!
//! WHY `ScrollerStyle` AND `ThermalState` ARE DECLARED HERE. The shared
//! `../preferences.zig` is the module that routes into this one, so importing
//! it back would leave the two files importing each other. The names are the
//! SDK's own, so the route between them is a switch on the name.
//!
//! THREADS. Both shim entry points check `[NSThread isMainThread]`, like every
//! other entry point in this ABI, so each read below goes through
//! `native.onMain`: inline when the caller is already on the main thread, and
//! marshalled — blocking the calling thread — when it is not. A read on the
//! host's frame path is already on that thread and costs one call.
const native = @import("native.zig");
const std = @import("std");

const shim = native.shim;

pub const Error = native.Error;
pub const Status = native.Status;

/// True on the target these reads exist for. The module still compiles
/// elsewhere, so a host can branch on this instead of building a macOS read
/// into a binary for another target, and every read reports
/// `error.ShimUnavailable` when it is false.
pub const available = native.available;

/// The scroller style the user's "Show scroll bars" setting resolves to.
pub const ScrollerStyle = enum {
    /// `NSScrollerStyleLegacy`: legacy-style scrollers, as they were prior to
    /// macOS 10.7. A scroll view asks for the style when it computes its frame
    /// size, because a legacy scroller occupies layout space.
    legacy,
    /// `NSScrollerStyleOverlay`: overlay-style scrollers, in macOS 10.7 and
    /// later. Overlay scrollers are drawn over the content rather than taking
    /// layout space, which is why `NSScrollView` has both
    /// `scrollerKnobStyle`, documented for views in this style, and
    /// `flashScrollers`, which flashes them.
    overlay,

    /// Whether a scroller in this style keeps itself out of the way until the
    /// user scrolls, which is the answer `NSScrollView.autohidesScrollers`
    /// gives for a scroll view that uses it.
    ///
    /// Apple documents that flag as whether the scroll view "automatically
    /// hides its scroll bars when they are not needed", and ships
    /// `flashScrollers` to flash the overlay scrollers such a view draws:
    /// https://developer.apple.com/documentation/appkit/nsscrollview/autohidescrollers
    ///
    /// The user's "Show scroll bars" answer reaches this module as a style
    /// rather than as that flag, and the flag is the scroll view's own
    /// business, so how a host paints from this stays the host's decision.
    pub fn autoHide(self: ScrollerStyle) bool {
        return self == .overlay;
    }
};

/// The thermal state the system reported. Same names as the SDK's
/// `NSProcessInfoThermalState`, in the same order.
pub const ThermalState = enum {
    nominal,
    fair,
    serious,
    critical,
};

/// The scroller style read, with the shim status the read came back with.
const ScrollerRead = struct {
    style: ?ScrollerStyle = null,
    status: Status = .ok,
};

/// 0 legacy, 1 overlay. A negative return is a NOGUI_MACOS_ERR_* code.
fn readScrollerStyleOnMain(call: *ScrollerRead) void {
    const raw = shim.nogui_macos_preferred_scroller_style();
    if (raw < 0) {
        call.status = Status.of(raw);
        return;
    }
    switch (raw) {
        0 => call.style = .legacy,
        1 => call.style = .overlay,
        // `Status.of` would read a wire value it does not name as a fault. It
        // is not a fault: it is an observation this module cannot report.
        else => call.status = .unavailable,
    }
}

/// The thermal state read, with the shim status the read came back with.
const ThermalRead = struct {
    state: ?ThermalState = null,
    status: Status = .ok,
};

/// 0 nominal, 1 fair, 2 serious, 3 critical. A negative return is a
/// NOGUI_MACOS_ERR_* code.
fn readThermalStateOnMain(call: *ThermalRead) void {
    const raw = shim.nogui_macos_thermal_state();
    if (raw < 0) {
        call.status = Status.of(raw);
        return;
    }
    switch (raw) {
        0 => call.state = .nominal,
        1 => call.state = .fair,
        2 => call.state = .serious,
        3 => call.state = .critical,
        // The same rule as the scroller style: a wire value this module does
        // not name is an observation it cannot report, not a fault.
        else => call.status = .unavailable,
    }
}

/// The user's scroller style, or null when this system did not name one.
///
/// Null and a failure are different answers: null is a system that reported
/// nothing this module can map, while a failure is the typed reason the read
/// did not happen. Off macOS every call reports `error.ShimUnavailable`.
pub fn preferredScrollerStyle() Error!?ScrollerStyle {
    if (!native.available) return error.ShimUnavailable;
    var call: ScrollerRead = .{};
    native.onMain(ScrollerRead, readScrollerStyleOnMain, &call) catch return error.NotOnMainThread;
    const style = call.style orelse return native.fail(call.status);
    return style;
}

/// The system's reported thermal state, or null when there is none.
///
/// This is a reading and not a poll: it starts nothing, subscribes to nothing,
/// allocates nothing and costs one call. A host that wants to act on a change
/// reads again when its own policy says to. No host in this repository has
/// observed the value, because none of them runs on macOS.
pub fn thermalState() Error!?ThermalState {
    if (!native.available) return error.ShimUnavailable;
    var call: ThermalRead = .{};
    native.onMain(ThermalRead, readThermalStateOnMain, &call) catch return error.NotOnMainThread;
    const state = call.state orelse return native.fail(call.status);
    return state;
}

/// One reading of everything this module observes, for a host that reports
/// them in one place.
pub const Observation = struct {
    /// The user's scroller style, or null when this system named none.
    scroller_style: ?ScrollerStyle,
    /// The system's thermal state, or null when there is none.
    thermal_state: ?ThermalState,

    /// Whether scroll bars keep themselves out of the way until the user
    /// scrolls, or null when this system named no scroller style.
    pub fn autoHide(self: Observation) ?bool {
        const style = self.scroller_style orelse return null;
        return style.autoHide();
    }
};

/// Both facts at once, each standing on its own.
///
/// The reads are independent: one missing answer says nothing about the other,
/// so a failure on one leaves the other as it was instead of emptying both.
pub fn observe() Observation {
    return .{
        .scroller_style = preferredScrollerStyle() catch null,
        .thermal_state = thermalState() catch null,
    };
}

test "api-w23 macos auto-hide follows the overlay meaning the SDK documents" {
    // Overlay scrollers are drawn over the content and revealed by scrolling;
    // legacy ones sit in the layout and are drawn either way. Inverting this
    // would show a macOS host the wrong scroll bar with nothing on this target
    // able to notice.
    try std.testing.expect(ScrollerStyle.overlay.autoHide());
    try std.testing.expect(!ScrollerStyle.legacy.autoHide());

    const unobserved: Observation = .{ .scroller_style = null, .thermal_state = .nominal };
    try std.testing.expect(unobserved.autoHide() == null);
}
