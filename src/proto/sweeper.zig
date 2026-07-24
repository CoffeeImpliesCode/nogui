//! Scanline sweeper — per-glyph curve data and GPU material.
//! GlyphMaterial is written to a GPU buffer and referenced by
//! the quad fragment shader via material_idx + BDA push constant.
//!
//! PROTOTYPE — throwaway design exploration.

const std = @import("std");
const noapi = @import("noapi");

pub const Curve = extern struct {
    p0x: f32,
    p0y: f32,
    p1x: f32,
    p1y: f32,
    p2x: f32,
    p2y: f32,
};

/// GPU material for glyph rendering. Written into material buffer.
/// Layout matches GLSL GlyphMaterial (int + 6×float + uint64_t).
pub const GlyphMaterial = extern struct {
    type: u32, // 0=SOLID, 1=GLYPH, 2=ROUNDED_RECT
    bearing_y: f32, // FreeType bearing Y / corner radius for ROUNDED_RECT
    curve_w: f32, // glyph extent in curve-space px / rect width for ROUNDED_RECT
    curve_h: f32, // glyph extent in curve-space px / rect height for ROUNDED_RECT
    win_w: f32, // pixel window width in curve-space units
    win_h: f32, // pixel window height in curve-space units
    curve_bda: u64, // BDA to curve buffer
};

pub const MATERIAL_SIZE = @sizeOf(GlyphMaterial); // 40 bytes

pub const TYPE_SOLID: u32 = 0;
pub const TYPE_GLYPH: u32 = 1;
pub const TYPE_ROUNDED_RECT: u32 = 2;

/// Compute the AABB extent of a set of curves.
pub fn glyphExtent(curves: []const Curve) struct { w: f32, h: f32 } {
    if (curves.len == 0) return .{ .w = 20, .h = 20 };
    var min_x = curves[0].p0x;
    var min_y = curves[0].p0y;
    var max_x = curves[0].p0x;
    var max_y = curves[0].p0y;
    for (curves) |c| {
        if (c.p0x < min_x) min_x = c.p0x;
        if (c.p0y < min_y) min_y = c.p0y;
        if (c.p1x < min_x) min_x = c.p1x;
        if (c.p1y < min_y) min_y = c.p1y;
        if (c.p2x < min_x) min_x = c.p2x;
        if (c.p2y < min_y) min_y = c.p2y;
        if (c.p0x > max_x) max_x = c.p0x;
        if (c.p0y > max_y) max_y = c.p0y;
        if (c.p1x > max_x) max_x = c.p1x;
        if (c.p1y > max_y) max_y = c.p1y;
        if (c.p2x > max_x) max_x = c.p2x;
        if (c.p2y > max_y) max_y = c.p2y;
    }
    return .{ .w = max_x - min_x, .h = max_y - min_y };
}

pub const GlyphSweeper = struct {
    gpu: *noapi.Gpu,
    curve_buf: noapi.GpuPtr,
    curve_buf_bda: u64,
    curve_left: f32, // min x of AABB
    curve_bottom: f32, // min y of AABB (can be negative)
    curve_w: f32,
    curve_h: f32,
    bearing_y: f32,
    num_curves: u32,

    pub fn init(gpu: *noapi.Gpu, curves: []const Curve) !@This() {
        const buf_size = @max(@as(u64, @sizeOf(Curve) * curves.len + 16), 64);
        const curve_buf = try gpu.gpuMalloc(buf_size, 16, .default);
        const dst: [*]u8 = @ptrCast(@alignCast(curve_buf.cpu));
        @as(*u32, @ptrCast(@alignCast(dst))).* = @intCast(curves.len);
        @as(*u32, @ptrCast(@alignCast(dst + 4))).* = 0;
        const curve_dst: [*]Curve = @ptrCast(@alignCast(dst + 8));
        @memcpy(curve_dst[0..curves.len], curves);

        const ext = glyphExtent(curves);
        var n_min_x: f32 = 1e10;
        var n_min_y: f32 = 1e10;
        for (curves) |cv| {
            if (cv.p0x < n_min_x) n_min_x = cv.p0x;
            if (cv.p0y < n_min_y) n_min_y = cv.p0y;
            if (cv.p1x < n_min_x) n_min_x = cv.p1x;
            if (cv.p1y < n_min_y) n_min_y = cv.p1y;
            if (cv.p2x < n_min_x) n_min_x = cv.p2x;
            if (cv.p2y < n_min_y) n_min_y = cv.p2y;
        }
        return .{
            .gpu = gpu,
            .curve_buf = curve_buf,
            .curve_buf_bda = curve_buf.gpu,
            .curve_left = n_min_x,
            .curve_bottom = n_min_y,
            .curve_w = ext.w,
            .curve_h = ext.h,
            .bearing_y = ext.h,
            .num_curves = @intCast(curves.len),
        };
    }

    pub fn deinit(_: *@This()) void {}

    /// Write a GlyphMaterial into the GPU material buffer at the given slot.
    pub fn writeMaterial(
        curve_bda: u64,
        material_buf: noapi.GpuPtr,
        slot: u32,
        bearing_y: f32,
        curve_w: f32,
        curve_h: f32,
        win_w: f32,
        win_h: f32,
    ) void {
        const mat = GlyphMaterial{
            .type = 1,
            .bearing_y = bearing_y,
            .curve_w = curve_w,
            .curve_h = curve_h,
            .win_w = win_w,
            .win_h = win_h,
            .curve_bda = curve_bda,
        };
        const offset = slot * MATERIAL_SIZE;
        const dst: [*]u8 = @ptrCast(@alignCast(material_buf.cpu));
        @as(*GlyphMaterial, @ptrCast(@alignCast(dst + offset))).* = mat;
    }
};
