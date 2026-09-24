//! SDL keyboard layout notifications and layout-derived shortcut presentation.
const std = @import("std");
const sdl3 = @import("sdl3");
const keyboard_layout = @import("linux/keyboard_layout.zig");

pub const Keyboard = struct {
    generation: u64 = 0,
    observer: ?Observer = null,
    /// The window whose display connection answers layout queries. Null until
    /// `attachDisplay`, and null forever on a driver that publishes no native
    /// display, which is every non-X11 driver here.
    window: ?sdl3.video.Window = null,
    identity: keyboard_layout.Identity = .{},
    status: LayoutStatus = .unsupported_by_sdl,

    pub const LayoutStatus = enum {
        /// Nothing this process can read names the layout: no window is
        /// attached, the driver publishes no native display, or libX11 is
        /// absent. A keyboard device name is not a layout name, so this
        /// reports unknown instead of borrowing one.
        unsupported_by_sdl,
        /// An X11 display connection was found and its XKB extension did not
        /// answer, so the layout is still unknown.
        xkb_unavailable,
        /// The XKB extension on SDL's own X11 connection answered, and the
        /// name and identifier below are what it reported.
        x11_xkb,
    };
    pub const Layout = struct {
        /// The `symbols` component name the XKB extension reported, for
        /// example "pc+us+inet(evdev)". Borrowed from this Keyboard, so it
        /// stays valid until the next layout change or attached window.
        name: ?[]const u8 = null,
        /// The layout symbol of the active group, for example "us" or
        /// "de(neo)". Null when the server named nothing or the name leaves
        /// the layout component ambiguous; never an empty string.
        identifier: ?[]const u8 = null,
        status: LayoutStatus = .unsupported_by_sdl,
        generation: u64,
    };
    pub const LayoutChange = struct {
        layout: Layout,
        generation: u64,
    };
    pub const Observer = struct {
        context: *anyopaque,
        callback: *const fn (*anyopaque, LayoutChange) void,
    };

    /// Initialize on the SDL video/event thread. SDL remains caller-owned.
    /// Without an attached window the layout stays `unsupported_by_sdl`.
    pub fn init() Keyboard {
        return .{};
    }

    /// Read the layout from the display connection behind `window`.
    ///
    /// SDL publishes that connection only per window, so this is what turns
    /// `unsupported_by_sdl` into a reported layout on X11. The window must
    /// outlive this Keyboard, the same rule `Cursor` follows.
    pub fn attachDisplay(self: *Keyboard, window: sdl3.video.Window) void {
        self.window = window;
        self.refresh();
    }

    /// The last probed layout. Nothing is cached across a layout change: a
    /// KEYMAP_CHANGED re-probes before it notifies, so this is authoritative
    /// once the event that carried the change has been handled.
    pub fn layout(self: *const Keyboard) Layout {
        return .{
            .name = self.identity.name(),
            .identifier = self.identity.identifier(),
            .status = self.status,
            .generation = self.generation,
        };
    }

    /// Observer context must outlive registration. Callback runs synchronously
    /// on the SDL event thread and may request fresh shortcut labels.
    pub fn setOnLayoutChanged(self: *Keyboard, observer: ?Observer) void {
        self.observer = observer;
    }

    /// Feed each native event once, before the host's other input consumers.
    /// KEYMAP_CHANGED is process-wide, not associated with a window.
    pub fn handleEvent(self: *Keyboard, raw: *const sdl3.events.Event) bool {
        switch (raw.*) {
            .keymap_changed => {
                self.generation +%= 1;
                self.refresh();
                if (self.observer) |observer| observer.callback(observer.context, .{
                    .layout = self.layout(),
                    .generation = self.generation,
                });
                return true;
            },
            else => return false,
        }
    }

    /// Physical code is event.PhysicalKey.code (an SDL scancode). The result
    /// comes from the current SDL keymap, including shift/layout modifiers;
    /// there is no US-layout table. SDL owns the UTF-8 bytes: consume or copy
    /// them before the next SDL_GetKeyName call or layout change.
    /// Unknown/unmapped keys have no label, rather than a fabricated fallback.
    pub fn shortcutLabel(
        self: *const Keyboard,
        physical_code: u32,
        modifiers: sdl3.keycode.KeyModifier,
    ) ?[:0]const u8 {
        _ = self;
        const scan = std.enums.fromInt(sdl3.Scancode, physical_code) orelse return null;
        const logical = sdl3.keyboard.getKeyFromScancode(scan, modifiers, false) orelse return null;
        return sdl3.keyboard.getKeyName(logical);
    }

    /// Re-reads the identity from the attached window. A window whose driver
    /// published no X11 display, a window that is already gone, and a missing
    /// libX11 all land on `unsupported_by_sdl` rather than on an error.
    fn refresh(self: *Keyboard) void {
        self.identity = .{};
        self.status = .unsupported_by_sdl;
        const window = self.window orelse return;
        const props = window.getProperties() catch return;
        const display: ?*anyopaque = if (props.x11_display) |value| value.value else null;
        const connection = display orelse return;
        keyboard_layout.probe(@ptrCast(connection), &self.identity);
        self.status = switch (self.identity.status) {
            .no_native_access => .unsupported_by_sdl,
            .xkb_unavailable => .xkb_unavailable,
            .x11_xkb => .x11_xkb,
        };
    }
};
