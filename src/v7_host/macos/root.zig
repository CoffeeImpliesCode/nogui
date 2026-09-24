//! macOS target adapters for W23 slices E01, E02 and E05.
//!
//! Everything here is target-specific and nothing here is a second runtime:
//! layout, input, focus and the Session stay platform neutral, and every
//! adapter here routes back into the shared services the rest of the host
//! already uses.
//!
//!   * `window` — E01. Native tab groups (merge, navigate, detach), the
//!     titlebar's own controls, and the document-edited and represented-path
//!     metadata AppKit keeps on a window.
//!   * `application` — E01. Activation, hiding, the reopen action, and the
//!     delegate events AppKit delivers, forwarded without displacing SDL's own
//!     delegate.
//!   * `services` — E01. The Services menu the system published, sending one,
//!     and registering this process as a service provider.
//!   * `text` — E02. The find pasteboard the system Find panel shares, and the
//!     character palette, through a mirror of the focused edit.
//!   * `menus` — E02. The AppKit menu bar, the Dock menu, and the
//!     recent-documents store, all built from the host's own menu model.
//!   * `keychain` — E02. The data-protection keychain as the shared
//!     credential service's provider.
//!   * `notifications` — E02. UserNotifications as the shared notification
//!     service's provider, with authorization reported separately from
//!     acceptance.
//!   * `dialogs` — E02. The decision to reuse SDL's dialogs, which on macOS
//!     are AppKit's own panels, and the per-option coverage that decision
//!     rests on.
//!   * `pixel_buffer` — E02. A CoreVideo pixel buffer as a frame descriptor,
//!     borrowed or copied, with no GPU import.
//!   * `accessibility` — E05. The shared accessibility adapter attached to a
//!     real window, with the focus forwarder and the trust fact.
//!
//! `native` is the one module that reaches the platform, through the shim in
//! `shim/nogui_macos.m`. The shim owns every Objective-C object; nothing in
//! this directory holds one.

pub const native = @import("native.zig");
pub const window = @import("window.zig");
pub const application = @import("application.zig");
pub const services = @import("services.zig");
pub const text = @import("text.zig");
pub const menus = @import("menus.zig");
pub const keychain = @import("keychain.zig");
pub const notifications = @import("notifications.zig");
pub const dialogs = @import("dialogs.zig");
pub const pixel_buffer = @import("pixel_buffer.zig");
pub const accessibility = @import("accessibility.zig");
pub const preferences = @import("preferences.zig");

/// True on the target these adapters are written for.
///
/// The module still compiles elsewhere, so a host that supports several
/// targets can decide at run time; every entry point reports a typed
/// unavailability off macOS rather than pretending to work.
pub const available = native.available;

/// The shim's own directory, which a build needs on the include path for
/// `@cImport` and on the source list for `zig cc`.
pub const shim_include = "macos/shim";
pub const shim_source = "macos/shim/nogui_macos.m";

/// The frameworks the shim links against. `zig build` has to name them for a
/// macOS target; the Objective-C source cannot resolve AppKit,
/// ApplicationServices, CoreVideo, Security or UserNotifications without
/// them.
pub const frameworks = [_][]const u8{
    "AppKit",
    "ApplicationServices",
    "Foundation",
    "CoreVideo",
    "CoreGraphics",
    "Security",
    "UserNotifications",
};

/// What this build of the target offers, so a host can report one place.
///
/// Every flag defaults to FALSE and every reading to NULL. A field that
/// claimed a macOS capability merely because the type compiled would be a lie
/// on any other target: the module deliberately builds everywhere so a
/// multi-target host can choose at run time, and off macOS every one of these
/// adapters reports a typed unavailability. `capabilities` is the only place
/// that fills them in.
pub const Capabilities = struct {
    /// Native window tabs, titlebar control and document metadata.
    window_tabs: bool = false,
    /// Application activation, hiding, reopening and the delegate events.
    application_lifecycle: bool = false,
    /// The system Services menu and service provisioning.
    services: bool = false,
    /// The find pasteboard and the character palette.
    text_services: bool = false,
    /// The AppKit menu bar, the Dock menu and recent documents.
    native_menus: bool = false,
    /// The data-protection keychain.
    keychain: bool = false,
    /// UserNotifications.
    user_notifications: bool = false,
    /// Whether the AppKit panels are reachable, which the video driver decides
    /// on top of the target.
    native_dialogs: bool = false,
    /// The per-option coverage of one request against the AppKit panels, or
    /// NULL off this target. A coverage is not a boolean: it names the parts
    /// of a request the panel cannot express, so a host reads the limit
    /// instead of discovering it after the panel opened. Absent is not the
    /// same as whole — a target that is not here expresses nothing at all.
    ///
    /// On target this is the coverage of a request that asked for NOTHING: no
    /// part served and no part dropped, which is `isFull` and a zero counter,
    /// not a claim that the panel serves nothing. A host reads a real answer
    /// out of `dialogs.coverage` with its own request in hand; this field only
    /// says the platform has a coverage to give.
    dialog_coverage: ?dialogs.Coverage = null,
    pixel_buffer_frames: bool = false,
    /// Native scrollbar visibility and OS thermal pressure observations.
    native_preferences: bool = false,
    /// Accessibility, and whether the bridge is linked into this build.
    accessibility: bool = false,
    /// Whether this process is trusted to serve an accessibility tree. macOS
    /// only lets a trusted process answer accessibility requests, and a
    /// process cannot grant itself that.
    accessibility_trusted: bool = false,
};

/// One reading of what this target offers. It contacts nothing that could
/// prompt: the trust fact is read, never requested.
///
/// Off macOS every capability is false, because the adapters behind them are
/// not present and each would report a typed unavailability if called.
pub fn capabilities() Capabilities {
    if (!available) return .{};
    return .{
        .window_tabs = true,
        .application_lifecycle = true,
        .services = true,
        .text_services = true,
        .native_menus = true,
        .keychain = true,
        .user_notifications = true,
        .native_dialogs = dialogs.isNativeBackend(),
        .dialog_coverage = .{},
        .pixel_buffer_frames = true,
        .native_preferences = true,
        .accessibility = accessibility.linked,
        .accessibility_trusted = accessibility.isTrusted(),
    };
}

test {
    _ = @import("native.zig");
    _ = @import("window.zig");
    _ = @import("application.zig");
    _ = @import("services.zig");
    _ = @import("text.zig");
    _ = @import("menus.zig");
    _ = @import("keychain.zig");
    _ = @import("notifications.zig");
    _ = @import("dialogs.zig");
    _ = @import("pixel_buffer.zig");
    _ = @import("accessibility.zig");
    _ = @import("preferences.zig");
}
