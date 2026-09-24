//! Value-only window identity, placement, and requested/observed state.
//! Native resources and the event loop belong to the host, not to App frames.
const geometry = @import("geometry.zig");
const paint = @import("paint.zig");

pub const WindowHandle = struct {
    /// Each host instance has a process-unique identity; a slot is never a window ID by itself.
    host: u64,
    slot: u32,
    generation: u32,
    /// The Session registration is distinct on every open, including reused host slots.
    session_window: u64,

    pub fn eql(a: WindowHandle, b: WindowHandle) bool {
        return a.host == b.host and a.slot == b.slot and
            a.generation == b.generation and a.session_window == b.session_window;
    }
};

pub const DisplayId = enum(u32) { _ };
pub const Point = struct {
    x: i32,
    y: i32,

    pub fn eql(a: Point, b: Point) bool {
        return a.x == b.x and a.y == b.y;
    }
};
pub const Size = struct {
    width: u32,
    height: u32,

    pub fn eql(a: Size, b: Size) bool {
        return a.width == b.width and a.height == b.height;
    }
};
pub const Bounds = struct {
    /// Wayland does not expose reliable global compositor coordinates.
    position: ?Point,
    size: Size,
};

pub const Kind = enum { normal, utility, tooltip, menu };

pub const WindowOptions = struct {
    title: [:0]const u8,
    width: u32,
    height: u32,
    minimum_size: ?Size = null,
    /// 0 from the platform means "no upper bound"; an explicit 0x0 here is
    /// rejected instead, so a typo cannot silently disable the limit.
    maximum_size: ?Size = null,
    position: ?Point = null,
    display: ?DisplayId = null,
    parent: ?WindowHandle = null,
    kind: Kind = .normal,
    resizable: bool = true,
    visible: bool = true,
    focusable: bool = true,
    decorated: bool = true,
    transparent: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    /// SDL creates a native Vulkan-compatible window. noapi surface ownership stays with the driver.
    gpu_surface: bool = false,
    /// The renderer uses this authored color as the window's clear color, if provided.
    background_srgb: ?paint.Srgb = null,
};

pub const RequestedState = struct {
    title: []const u8,
    size: Size,
    position: ?Point,
    visible: bool,
    focused: bool = false,
    minimized: bool = false,
    maximized: bool,
    fullscreen: bool,
    attention: bool = false,
    // The accepted configuration. A request that the platform refused never
    // reaches these fields, so they always describe what was asked for and
    // accepted, never what was merely typed at a call site.
    parent: ?WindowHandle = null,
    kind: Kind = .normal,
    display: ?DisplayId = null,
    minimum_size: ?Size = null,
    maximum_size: ?Size = null,
    resizable: bool = true,
    focusable: bool = true,
    decorated: bool = true,
    transparent: bool = false,
    background_srgb: ?paint.Srgb = null,
};

/// The one platform frame around a window, in pixels. A zero value on all four
/// sides is a borderless window, not a missing measurement; `null` is a
/// backend that has no border information to report.
pub const Borders = struct { top: u32, left: u32, bottom: u32, right: u32 };

/// The first requested/observed disagreement, in a fixed priority order, and
/// `null` when every comparable field agrees. A field the platform cannot
/// observe is never compared, so an absent capability cannot manufacture a
/// disagreement the caller never made.
pub const Divergence = enum {
    size,
    position,
    visible,
    minimized,
    maximized,
    fullscreen,
    focused,
};

pub const ObservedState = struct {
    size: Size,
    pixels: geometry.DeviceSize,
    display: DisplayId,
    display_scale: f32,
    /// Window global position is unavailable on compositors that do not provide it.
    position: ?Point,
    visible: bool,
    occluded: bool,
    focused: bool,
    /// Window minimized state is unavailable on backends that do not report it.
    minimized: ?bool,
    maximized: bool,
    fullscreen: bool,
    /// The platform frame around the client area; null where the backend has
    /// no border information. This is how a caller tells a borderless window
    /// from a decorated one the platform declined to measure.
    borders: ?Borders = null,

    pub fn pixelScale(self: ObservedState) geometry.Error!geometry.PixelScale {
        return geometry.PixelScale.init(
            .{ .width = @floatFromInt(self.size.width), .height = @floatFromInt(self.size.height) },
            self.pixels,
        );
    }
};

/// The first requested/observed disagreement, in the `Divergence` priority
/// order, or `null` when every comparable field agrees.
pub fn divergence(requested: RequestedState, observed: ObservedState) ?Divergence {
    if (!requested.size.eql(observed.size)) return .size;
    if (observed.position) |position| {
        if (requested.position) |asked| {
            if (!asked.eql(position)) return .position;
        }
    }
    if (requested.visible != observed.visible) return .visible;
    if (observed.minimized) |minimized| {
        if (requested.minimized != minimized) return .minimized;
    }
    if (requested.maximized != observed.maximized) return .maximized;
    if (requested.fullscreen != observed.fullscreen) return .fullscreen;
    if (requested.focused and !observed.focused) return .focused;
    return null;
}
