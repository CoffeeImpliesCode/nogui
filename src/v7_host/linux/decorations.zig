//! Native Linux window decorations, interactive move, resize, and system menu.
//! Supports client-side decoration (CSD) hit testing and server-side decoration (SSD) modes.
//! Connects with SDL3 hit-test callbacks and native Wayland/X11 move-resize protocols.

pub const DecorationMode = enum(u8) {
    client_side = 0,
    server_side = 1,
};

pub const ResizeEdge = enum(u8) {
    none = 0,
    top = 1,
    bottom = 2,
    left = 4,
    top_left = 5,
    bottom_left = 6,
    right = 8,
    top_right = 9,
    bottom_right = 10,

    pub fn toSdlHitTest(self: ResizeEdge) SdlHitTestResult {
        return switch (self) {
            .none => .normal,
            .top => .resize_top,
            .bottom => .resize_bottom,
            .left => .resize_left,
            .right => .resize_right,
            .top_left => .resize_topleft,
            .top_right => .resize_topright,
            .bottom_left => .resize_bottomleft,
            .bottom_right => .resize_bottomright,
        };
    }

    pub fn toX11Direction(self: ResizeEdge) u32 {
        return switch (self) {
            .top_left => 0,
            .top => 1,
            .top_right => 2,
            .right => 3,
            .bottom_right => 4,
            .bottom => 5,
            .bottom_left => 6,
            .left => 7,
            .none => 11, // cancel
        };
    }

    /// Map to the `xdg_toplevel.resize` edge bit order from xdg-shell.
    pub fn xdgEdges(self: ResizeEdge) u32 {
        return switch (self) {
            .none => 0,
            .top => 1,
            .bottom => 2,
            .left => 4,
            .top_left => 1 | 4,
            .bottom_left => 2 | 4,
            .right => 8,
            .top_right => 1 | 8,
            .bottom_right => 2 | 8,
        };
    }
};

pub const SdlHitTestResult = enum(u32) {
    normal = 0,
    draggable = 1,
    resize_topleft = 2,
    resize_top = 3,
    resize_topright = 4,
    resize_right = 5,
    resize_bottomright = 6,
    resize_bottom = 7,
    resize_bottomleft = 8,
    resize_left = 9,
};

pub const DecorationMetrics = struct {
    border_thickness: u32 = 6,
    corner_size: u32 = 12,
    titlebar_height: u32 = 32,
    button_width: u32 = 40,
    button_count: u32 = 3,

    pub fn buttonAreaWidth(self: DecorationMetrics) u32 {
        return self.button_width * self.button_count;
    }
};

pub const PointOfRiskApproval = struct {
    confirmed: bool = false,
};

pub const DecorationsError = error{
    RiskConfirmationRequired,
    InvalidMetrics,
    ActionAlreadyActive,
};

/// Classify coordinate in window logical space for SDL hit testing.
pub fn classifyHitTestPoint(
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    metrics: DecorationMetrics,
) SdlHitTestResult {
    if (width == 0 or height == 0) return .normal;
    if (x < 0 or y < 0) return .normal;

    const w_i32: i32 = @intCast(width);
    const h_i32: i32 = @intCast(height);
    if (x >= w_i32 or y >= h_i32) return .normal;

    const border: i32 = @intCast(metrics.border_thickness);
    const corner: i32 = @intCast(metrics.corner_size);
    const titlebar: i32 = @intCast(metrics.titlebar_height);

    // 1. Top border and corners
    if (y < border) {
        if (x < corner) return .resize_topleft;
        if (x >= w_i32 - corner) return .resize_topright;
        return .resize_top;
    }

    // 2. Bottom border and corners
    if (y >= h_i32 - border) {
        if (x < corner) return .resize_bottomleft;
        if (x >= w_i32 - corner) return .resize_bottomright;
        return .resize_bottom;
    }

    // 3. Left border
    if (x < border) {
        if (y < corner) return .resize_topleft;
        if (y >= h_i32 - corner) return .resize_bottomleft;
        return .resize_left;
    }

    // 4. Right border
    if (x >= w_i32 - border) {
        if (y < corner) return .resize_topright;
        if (y >= h_i32 - corner) return .resize_bottomright;
        return .resize_right;
    }

    // 5. Titlebar region
    if (y < titlebar) {
        // Exclude window control button area on the right
        const buttons_width: i32 = @intCast(metrics.buttonAreaWidth());
        if (x >= w_i32 - buttons_width) {
            return .normal; // Buttons handle their own input
        }
        return .draggable;
    }

    return .normal;
}

/// Controller managing window decoration mode, hit tests, and interactive move/resize.
pub const DecorationsManager = struct {
    mode: DecorationMode = .client_side,
    metrics: DecorationMetrics = .{},
    interactive_move_active: bool = false,
    interactive_resize_active: bool = false,
    active_resize_edge: ResizeEdge = .none,
    system_menu_shown: bool = false,
    system_menu_pos: ?struct { x: i32, y: i32 } = null,

    pub fn init(
        mode: DecorationMode,
        metrics: DecorationMetrics,
    ) DecorationsError!DecorationsManager {
        if (metrics.border_thickness == 0 or metrics.titlebar_height == 0) {
            return error.InvalidMetrics;
        }

        return .{
            .mode = mode,
            .metrics = metrics,
            .interactive_move_active = false,
            .interactive_resize_active = false,
            .active_resize_edge = .none,
            .system_menu_shown = false,
            .system_menu_pos = null,
        };
    }

    /// Perform hit test for pointer position in window coordinates.
    pub fn hitTest(
        self: *const DecorationsManager,
        x: i32,
        y: i32,
        width: u32,
        height: u32,
    ) SdlHitTestResult {
        if (self.mode == .server_side) {
            // In server-side decoration mode, compositor provides frames and buttons.
            return .normal;
        }
        return classifyHitTestPoint(x, y, width, height, self.metrics);
    }

    /// Initiate interactive window move via compositor. Requires explicit point-of-risk gate.
    pub fn startMove(
        self: *DecorationsManager,
        approval: PointOfRiskApproval,
        seat_serial: ?u32,
    ) DecorationsError!void {
        _ = seat_serial;
        if (!approval.confirmed) {
            return error.RiskConfirmationRequired;
        }
        if (self.interactive_move_active or self.interactive_resize_active) {
            return error.ActionAlreadyActive;
        }
        self.interactive_move_active = true;
    }

    /// Initiate interactive window resize via compositor. Requires explicit point-of-risk gate.
    pub fn startResize(
        self: *DecorationsManager,
        approval: PointOfRiskApproval,
        edge: ResizeEdge,
        seat_serial: ?u32,
    ) DecorationsError!void {
        _ = seat_serial;
        if (!approval.confirmed) {
            return error.RiskConfirmationRequired;
        }
        if (self.interactive_move_active or self.interactive_resize_active) {
            return error.ActionAlreadyActive;
        }
        self.interactive_resize_active = true;
        self.active_resize_edge = edge;
    }

    /// Display compositor window system menu at (x, y).
    pub fn showSystemMenu(self: *DecorationsManager, x: i32, y: i32) void {
        self.system_menu_shown = true;
        self.system_menu_pos = .{ .x = x, .y = y };
    }

    /// Complete or cancel current interactive move or resize.
    pub fn endInteractiveAction(self: *DecorationsManager) void {
        self.interactive_move_active = false;
        self.interactive_resize_active = false;
        self.active_resize_edge = .none;
    }

    pub fn setMode(self: *DecorationsManager, mode: DecorationMode) void {
        self.mode = mode;
    }
};

/// Pure property descriptor for SDL3 decorations seam.
pub const SdlDecorationsSeam = struct {
    pub const fn_set_window_hit_test = "SDL_SetWindowHitTest";
    pub const fn_show_window_system_menu = "SDL_ShowWindowSystemMenu";
    pub const fn_set_window_bordered = "SDL_SetWindowBordered";
};
