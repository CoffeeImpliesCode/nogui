//! SDL platform host for an externally driven nogui application.
pub const Application = @import("application.zig").Application;
/// The per-window state a host passes to a frame callback. It is named in the
/// callback's own signature, so a consumer cannot write one without being able
/// to name it.
pub const ManagedWindow = @import("application.zig").ManagedWindow;
pub const Window = @import("window.zig").Window;
pub const display = @import("display.zig");
pub const keyboard = @import("keyboard.zig");
pub const cursor = @import("cursor.zig");
pub const clipboard = @import("clipboard.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const assets = @import("assets.zig");
pub const image = @import("image.zig");
pub const svg = @import("svg.zig");
pub const frame_source = @import("frame_source.zig");
pub const capture = @import("capture.zig");
pub const linux_capture = @import("linux/capture.zig");
pub const dialogs = @import("dialogs.zig");
pub const menus = @import("menus.zig");
pub const open_url = @import("open_url.zig");
pub const preferences = @import("preferences.zig");
pub const portal = @import("linux/portal.zig");
pub const inspector = @import("inspector.zig");
/// Native accessibility uses the optional AccessKit bridge.
/// The adapter reports unavailable when the build disables the bridge.
pub const accessibility = @import("accessibility.zig");
pub const system_bell = @import("system_bell.zig");
pub const weak_owner = @import("weak_owner.zig");
pub const notifications = @import("notifications.zig");
pub const credentials = @import("credentials.zig");
const linux_popup = @import("linux/popup.zig");
const linux_layer_shell = @import("linux/layer_shell.zig");
const linux_decorations = @import("linux/decorations.zig");
const linux_popup_real = @import("linux/popup_real.zig");
const linux_layer_shell_real = @import("linux/layer_shell_real.zig");
const linux_wayland = @import("linux/wayland.zig");
const linux_decorations_real = @import("linux/decorations_real.zig");
const linux_keyboard_layout = @import("linux/keyboard_layout.zig");
const linux_notifications_dbus = @import("linux/notifications_dbus.zig");
const linux_credentials_secret_service = @import("linux/credentials_secret_service.zig");
pub const linux = struct {
    pub const popup = linux_popup;
    pub const layer_shell = linux_layer_shell;
    pub const decorations = linux_decorations;
    pub const popup_real = linux_popup_real;
    pub const layer_shell_real = linux_layer_shell_real;
    pub const decorations_real = linux_decorations_real;
    /// The Wayland protocol table itself. Public so an adapter consumer names
    /// these types directly instead of recovering them by reflection.
    pub const wayland = linux_wayland;
    pub const keyboard_layout = linux_keyboard_layout;
    pub const notifications_dbus = linux_notifications_dbus;
    pub const credentials_secret_service = linux_credentials_secret_service;
};
pub const macos = @import("macos/root.zig");
pub const windows = @import("windows/root.zig");
pub const mobile = @import("mobile/root.zig");
pub const window_contract = @import("nogui").window_contract;

test {
    _ = @import("window.zig");
    _ = @import("application.zig");
    _ = @import("w07_contract_test.zig");
    _ = @import("w10_services_test.zig");
    _ = @import("linux/keyboard_layout.zig");
    _ = @import("clipboard.zig");
    _ = @import("w14_contract_test.zig");
    _ = @import("w20_capture_test.zig");
    _ = @import("linux/capture_portal.zig");
    _ = @import("linux/capture_pipewire.zig");
    _ = @import("w18_services_test.zig");
    _ = @import("linux/portal.zig");
    _ = @import("w24_host_test.zig");
    _ = @import("w19_notifications_test.zig");
    _ = @import("w19_credentials_test.zig");
    _ = @import("linux/wayland.zig");
    _ = @import("linux/layer_shell_real.zig");
    _ = @import("linux/decorations_real.zig");
    _ = @import("w14_assets_test.zig");
    _ = @import("accessibility.zig");
    _ = @import("w21_accessibility_test.zig");
    _ = @import("linux/popup_real.zig");
    _ = @import("linux/w22_linux_surfaces_test.zig");
    _ = @import("macos/root.zig");
    _ = @import("windows/root.zig");
    _ = @import("mobile/root.zig");
}
