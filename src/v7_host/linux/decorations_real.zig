//! Native decoration requests using SDL and compositor-owned toplevels.
//! SDL supplies the system menu. Direct Wayland move/resize requires an
//! external seat and input serial; SDL does not expose a seat here. X11
//! move/resize is unavailable unless the host installs an SDL hit-test
//! callback. The geometry classifier alone does not install that callback.
const std = @import("std");
const sdl3 = @import("sdl3");
const wayland = @import("wayland.zig");
const state = @import("decorations.zig");

pub const DecorationMode = state.DecorationMode;
pub const ResizeEdge = state.ResizeEdge;
pub const SdlHitTestResult = state.SdlHitTestResult;
pub const DecorationMetrics = state.DecorationMetrics;
pub const PointOfRiskApproval = state.PointOfRiskApproval;
pub const DecorationsError = state.DecorationsError;

pub const Error = error{
    /// The active SDL video driver is not Wayland.
    NotWayland,
    /// SDL exposes no compositor toplevel proxy for this window.
    MissingToplevel,
    /// SDL exposes no compositor seat proxy for interactive input.
    MissingSeat,
    /// The compositor rejected the request.
    CompositorRefused,
    NativeActionUnavailable,
    InvalidSerial,
} || DecorationsError;

/// Native handles SDL exposes for a decorated toplevel window.
pub const Handles = struct {
    display: ?*anyopaque = null,
    xdg_toplevel: ?*anyopaque = null,
    wl_seat: ?*anyopaque = null,
    driver_name: ?[]const u8 = null,

    pub fn isWayland(self: Handles) bool {
        const name = self.driver_name orelse return false;
        return std.mem.eql(u8, name, "wayland");
    }

    /// Interactive move and resize need a real compositor toplevel.
    pub fn canDrive(self: Handles) bool {
        if (!self.isWayland()) return false;
        return self.display != null and self.xdg_toplevel != null;
    }
};

/// Read the handles SDL publishes for one window.
pub fn readHandles(window: sdl3.video.Window) Handles {
    const props = window.getProperties() catch return .{};
    return .{
        .display = if (props.wayland_display) |v| v.value else null,
        .xdg_toplevel = if (props.wayland_xdg_toplevel) |v| v.value else null,
        .wl_seat = null,
        .driver_name = sdl3.video.getCurrentDriverName(),
    };
}

/// Live decoration controller bound to one SDL window.
pub const Decorations = struct {
    machine: state.DecorationsManager,
    window: sdl3.video.Window,
    handles: Handles,
    api: ?wayland.Api = null,
    last_width: u32 = 0,
    last_height: u32 = 0,

    pub fn init(
        window: sdl3.video.Window,
        mode: DecorationMode,
        metrics: DecorationMetrics,
    ) !Decorations {
        const size = window.getSize() catch return error.InvalidMetrics;
        return .{
            .machine = try state.DecorationsManager.init(mode, metrics),
            .window = window,
            .handles = readHandles(window),
            .last_width = @intCast(size[0]),
            .last_height = @intCast(size[1]),
        };
    }

    /// Install the resolved Wayland table used for interactive requests.
    pub fn setApi(self: *Decorations, api: ?wayland.Api) void {
        self.api = api;
    }

    /// Ask the compositor to start an interactive move of this window.
    ///
    /// The seat serial must come from the compositor's own input event, and the
    /// caller must supply an explicit approval for the OS-level action.
    pub fn startMove(self: *Decorations, serial: u32, approval: PointOfRiskApproval) !void {
        if (!approval.confirmed) return error.RiskConfirmationRequired;
        if (!self.handles.canDrive()) return error.NativeActionUnavailable;
        if (serial == 0) return error.InvalidSerial;
        const api = self.api orelse return error.NotWayland;
        const seat = self.handles.wl_seat orelse return error.MissingSeat;
        try self.machine.startMove(approval, serial);
        const proxy = self.handles.xdg_toplevel.?;
        _ = api.proxy_marshal_flags(
            @ptrCast(proxy),
            5,
            null,
            0,
            0,
            @as(*wayland.Proxy, @ptrCast(seat)),
            serial,
        );
    }

    /// Ask the compositor to start an interactive resize on one edge.
    pub fn startResize(
        self: *Decorations,
        edge: ResizeEdge,
        serial: u32,
        approval: PointOfRiskApproval,
    ) !void {
        if (!approval.confirmed) return error.RiskConfirmationRequired;
        if (edge == .none) return error.InvalidMetrics;
        if (!self.handles.canDrive()) return error.NativeActionUnavailable;
        if (serial == 0) return error.InvalidSerial;
        const api = self.api orelse return error.NotWayland;
        const seat = self.handles.wl_seat orelse return error.MissingSeat;
        try self.machine.startResize(approval, edge, serial);
        const proxy = self.handles.xdg_toplevel.?;
        _ = api.proxy_marshal_flags(
            @ptrCast(proxy),
            6,
            null,
            0,
            0,
            @as(*wayland.Proxy, @ptrCast(seat)),
            serial,
            edge.xdgEdges(),
        );
    }

    /// Show the compositor window menu, which owns minimize/maximize/close.
    pub fn showSystemMenu(self: *Decorations, x: i32, y: i32, serial: u32) !void {
        // SDL supplies the supported system-menu request for both backends;
        // do not send a second request with a missing compositor seat.
        _ = serial;
        try self.window.showSystemMenu(x, y);
        self.machine.showSystemMenu(x, y);
    }

    /// Classify a window point and hand the result to SDL.
    pub fn hitTest(self: *Decorations, x: i32, y: i32) SdlHitTestResult {
        var extent: [2]u32 = .{ self.last_width, self.last_height };
        if (self.window.getSize()) |current| {
            extent = .{ @intCast(current[0]), @intCast(current[1]) };
        } else |_| {}
        self.last_width = extent[0];
        self.last_height = extent[1];
        return self.machine.hitTest(x, y, extent[0], extent[1]);
    }

    /// Tell SDL whether the window manager should draw the frame.
    pub fn setServerSideDecorations(self: *Decorations, enabled: bool) !void {
        try self.window.setBordered(enabled);
        self.machine.setMode(if (enabled) .server_side else .client_side);
    }

    /// End any interactive move or resize the compositor is running.
    pub fn endInteractiveAction(self: *Decorations) void {
        self.machine.endInteractiveAction();
    }
};

test "api-w22 real decorations require a compositor toplevel for interactive drag" {
    const x11: Handles = .{
        .display = @ptrFromInt(0x1000),
        .xdg_toplevel = @ptrFromInt(0x2000),
        .driver_name = "x11",
    };
    // An X11 window has no xdg_toplevel, so SDL's hit test drives the WM.
    try std.testing.expect(!x11.isWayland());
    try std.testing.expect(!x11.canDrive());

    const toplevel: Handles = .{
        .display = @ptrFromInt(0x1000),
        .xdg_toplevel = @ptrFromInt(0x2000),
        .wl_seat = @ptrFromInt(0x3000),
        .driver_name = "wayland",
    };
    try std.testing.expect(toplevel.canDrive());

    const seatless: Handles = .{
        .display = @ptrFromInt(0x1000),
        .xdg_toplevel = @ptrFromInt(0x2000),
        .driver_name = "wayland",
    };
    try std.testing.expect(seatless.canDrive());
    // Interactive requests still need a seat serial from the compositor.
    try std.testing.expect(seatless.wl_seat == null);
}

test "api-w22 real decorations gate move and resize behind approval" {
    var manager = try state.DecorationsManager.init(.client_side, .{});
    try std.testing.expectError(
        error.RiskConfirmationRequired,
        manager.startMove(.{ .confirmed = false }, 1),
    );
    try std.testing.expectError(
        error.RiskConfirmationRequired,
        manager.startResize(.{ .confirmed = false }, .top, 1),
    );
    try std.testing.expect(!manager.interactive_move_active);
    try std.testing.expect(!manager.interactive_resize_active);
}

test "api-w22 unsupported native move does not change interactive state" {
    var controller: Decorations = .{
        .machine = try state.DecorationsManager.init(.client_side, .{}),
        .window = undefined,
        .handles = .{ .driver_name = "x11" },
    };
    try std.testing.expectError(
        error.NativeActionUnavailable,
        controller.startMove(9, .{ .confirmed = true }),
    );
    try std.testing.expect(!controller.machine.interactive_move_active);
}

test "api-w22 zero Wayland serial cannot start native move" {
    var controller: Decorations = .{
        .machine = try state.DecorationsManager.init(.client_side, .{}),
        .window = undefined,
        .handles = .{
            .display = @ptrFromInt(0x1000),
            .xdg_toplevel = @ptrFromInt(0x2000),
            .wl_seat = @ptrFromInt(0x3000),
            .driver_name = "wayland",
        },
    };
    try std.testing.expectError(
        error.InvalidSerial,
        controller.startMove(0, .{ .confirmed = true }),
    );
    try std.testing.expect(!controller.machine.interactive_move_active);
}
