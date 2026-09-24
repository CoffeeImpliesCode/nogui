//! Coordinate values for widget-local, window-logical, and device-pixel spaces.
//! Apply the pixel scale at the window/device boundary, not during layout walks.

const std = @import("std");

/// A widget-local point in logical window units. The caller defines its origin.
pub const LocalPoint = struct { x: f32, y: f32 };

/// A point in logical window units, relative to the window's client origin.
pub const WindowPoint = struct { x: f32, y: f32 };

/// A point in device pixels, relative to the render surface origin.
pub const DevicePoint = struct { x: f32, y: f32 };

/// A window's client width and height in logical window units.
pub const WindowSize = struct { width: f32, height: f32 };

/// A render surface's width and height in whole device pixels.
pub const DeviceSize = struct { width: u32, height: u32 };

/// A window-relative rectangle in logical window units.
pub const WindowRect = struct { x: f32, y: f32, w: f32, h: f32 };

/// A surface-relative rectangle in device pixels; positions and extents can be fractional.
pub const DeviceRect = struct { x: f32, y: f32, w: f32, h: f32 };

pub const Error = error{InvalidGeometry};

/// Device pixels per logical window unit on each axis.
/// Use `init` with finite, positive window dimensions and nonzero device dimensions.
/// Conversion methods require finite, positive x and y scale factors.
pub const PixelScale = struct {
    x: f32,
    y: f32,

    pub fn init(window: WindowSize, pixels: DeviceSize) Error!PixelScale {
        if (!std.math.isFinite(window.width) or window.width <= 0) return error.InvalidGeometry;
        if (!std.math.isFinite(window.height) or window.height <= 0) return error.InvalidGeometry;
        if (pixels.width == 0 or pixels.height == 0) return error.InvalidGeometry;

        const x: f32 = @as(f32, @floatFromInt(pixels.width)) / window.width;
        const y: f32 = @as(f32, @floatFromInt(pixels.height)) / window.height;
        if (!std.math.isFinite(x) or x <= 0) return error.InvalidGeometry;
        if (!std.math.isFinite(y) or y <= 0) return error.InvalidGeometry;
        return .{ .x = x, .y = y };
    }

    pub fn windowToDevice(self: PixelScale, point: WindowPoint) DevicePoint {
        return .{ .x = point.x * self.x, .y = point.y * self.y };
    }

    pub fn deviceToWindow(self: PixelScale, point: DevicePoint) WindowPoint {
        return .{ .x = point.x / self.x, .y = point.y / self.y };
    }

    pub fn windowRectToDevice(self: PixelScale, rect: WindowRect) DeviceRect {
        return .{
            .x = rect.x * self.x,
            .y = rect.y * self.y,
            .w = rect.w * self.x,
            .h = rect.h * self.y,
        };
    }

    pub fn deviceRectToWindow(self: PixelScale, rect: DeviceRect) WindowRect {
        return .{
            .x = rect.x / self.x,
            .y = rect.y / self.y,
            .w = rect.w / self.x,
            .h = rect.h / self.y,
        };
    }
};

test "api-w02 point and rectangle round trips at 1x 1.25x and 2x" {
    // Exact binary fractions show that no conversion rounds to whole pixels.
    const window_point: WindowPoint = .{ .x = 1.5, .y = -2.25 };
    const window_rect: WindowRect = .{ .x = -1.5, .y = 2.25, .w = 9.5, .h = 4.25 };
    const cases = [_]struct {
        pixels: DeviceSize,
        factor: f32,
        point: DevicePoint,
        rect: DeviceRect,
    }{
        .{
            .pixels = .{ .width = 80, .height = 64 },
            .factor = 1,
            .point = .{ .x = 1.5, .y = -2.25 },
            .rect = .{ .x = -1.5, .y = 2.25, .w = 9.5, .h = 4.25 },
        },
        .{
            .pixels = .{ .width = 100, .height = 80 },
            .factor = 1.25,
            .point = .{ .x = 1.875, .y = -2.8125 },
            .rect = .{ .x = -1.875, .y = 2.8125, .w = 11.875, .h = 5.3125 },
        },
        .{
            .pixels = .{ .width = 160, .height = 128 },
            .factor = 2,
            .point = .{ .x = 3, .y = -4.5 },
            .rect = .{ .x = -3, .y = 4.5, .w = 19, .h = 8.5 },
        },
    };

    for (cases) |case| {
        const scale = try PixelScale.init(.{ .width = 80, .height = 64 }, case.pixels);
        try std.testing.expectEqual(case.factor, scale.x);
        try std.testing.expectEqual(case.factor, scale.y);

        const point = scale.windowToDevice(window_point);
        try std.testing.expectEqual(case.point.x, point.x);
        try std.testing.expectEqual(case.point.y, point.y);
        const restored_point = scale.deviceToWindow(point);
        try std.testing.expectEqual(window_point.x, restored_point.x);
        try std.testing.expectEqual(window_point.y, restored_point.y);

        const rect = scale.windowRectToDevice(window_rect);
        try std.testing.expectEqual(case.rect.x, rect.x);
        try std.testing.expectEqual(case.rect.y, rect.y);
        try std.testing.expectEqual(case.rect.w, rect.w);
        try std.testing.expectEqual(case.rect.h, rect.h);
        const restored_rect = scale.deviceRectToWindow(rect);
        try std.testing.expectEqual(window_rect.x, restored_rect.x);
        try std.testing.expectEqual(window_rect.y, restored_rect.y);
        try std.testing.expectEqual(window_rect.w, restored_rect.w);
        try std.testing.expectEqual(window_rect.h, restored_rect.h);
    }
}

test "api-w02 nonuniform scale preserves independent fractional axes" {
    // Different axis scales must apply to rectangle extents as well as positions.
    const scale = try PixelScale.init(
        .{ .width = 100, .height = 80 },
        .{ .width = 125, .height = 160 },
    );
    try std.testing.expectEqual(@as(f32, 1.25), scale.x);
    try std.testing.expectEqual(@as(f32, 2), scale.y);

    const point = scale.windowToDevice(.{ .x = -3.5, .y = 2.75 });
    try std.testing.expectEqual(@as(f32, -4.375), point.x);
    try std.testing.expectEqual(@as(f32, 5.5), point.y);
    const rect = scale.windowRectToDevice(.{ .x = -3.5, .y = 2.75, .w = 8.5, .h = 4.25 });
    try std.testing.expectEqual(@as(f32, -4.375), rect.x);
    try std.testing.expectEqual(@as(f32, 5.5), rect.y);
    try std.testing.expectEqual(@as(f32, 10.625), rect.w);
    try std.testing.expectEqual(@as(f32, 8.5), rect.h);

    const window_point = scale.deviceToWindow(.{ .x = 5.625, .y = -7 });
    try std.testing.expectEqual(@as(f32, 4.5), window_point.x);
    try std.testing.expectEqual(@as(f32, -3.5), window_point.y);
    const window_rect = scale.deviceRectToWindow(
        .{ .x = 5.625, .y = -7, .w = 1.875, .h = 9 },
    );
    try std.testing.expectEqual(@as(f32, 4.5), window_rect.x);
    try std.testing.expectEqual(@as(f32, -3.5), window_rect.y);
    try std.testing.expectEqual(@as(f32, 1.5), window_rect.w);
    try std.testing.expectEqual(@as(f32, 4.5), window_rect.h);
}

test "api-w02 pixel scale rejects invalid geometry" {
    // Either window axis must be finite and strictly positive.
    const invalid_windows = [_]WindowSize{
        .{ .width = 0, .height = 80 },
        .{ .width = -0.0, .height = 80 },
        .{ .width = -1, .height = 80 },
        .{ .width = std.math.nan(f32), .height = 80 },
        .{ .width = std.math.inf(f32), .height = 80 },
        .{ .width = -std.math.inf(f32), .height = 80 },
        .{ .width = 100, .height = 0 },
        .{ .width = 100, .height = -0.0 },
        .{ .width = 100, .height = -1 },
        .{ .width = 100, .height = std.math.nan(f32) },
        .{ .width = 100, .height = std.math.inf(f32) },
        .{ .width = 100, .height = -std.math.inf(f32) },
    };
    for (invalid_windows) |window| {
        try std.testing.expectError(
            error.InvalidGeometry,
            PixelScale.init(window, .{ .width = 125, .height = 160 }),
        );
    }

    // Either device axis must have at least one whole pixel.
    const invalid_pixels = [_]DeviceSize{
        .{ .width = 0, .height = 160 },
        .{ .width = 125, .height = 0 },
        .{ .width = 0, .height = 0 },
    };
    for (invalid_pixels) |pixels| {
        try std.testing.expectError(
            error.InvalidGeometry,
            PixelScale.init(.{ .width = 100, .height = 80 }, pixels),
        );
    }

    // A positive window size can still produce an infinite scale.
    const tiny_window_axis: f32 = 1e-40;
    try std.testing.expectError(
        error.InvalidGeometry,
        PixelScale.init(
            .{ .width = tiny_window_axis, .height = 80 },
            .{ .width = std.math.maxInt(u32), .height = 160 },
        ),
    );
    try std.testing.expectError(
        error.InvalidGeometry,
        PixelScale.init(
            .{ .width = 100, .height = tiny_window_axis },
            .{ .width = 125, .height = std.math.maxInt(u32) },
        ),
    );
}
