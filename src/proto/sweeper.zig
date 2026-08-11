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
/// Layout matches GLSL GlyphMaterial (int + 6×float + uint64_t + vec4).
pub const GlyphMaterial = extern struct {
    type: u32, // 0=SOLID, 1=GLYPH, 2=ROUNDED_RECT, 3=SHADOW
    bearing_y: f32, // FreeType bearing Y / corner radius / border / feather
    curve_w: f32, // glyph extent / x radius
    curve_h: f32, // glyph extent / y radius
    win_w: f32, // pixel window width / rect width
    win_h: f32, // pixel window height / rect height
    curve_bda: u64, // BDA to curve buffer (0 for rounded/shadow)
    /// Gradient bottom color (Oklab); all-zero = flat fill. The vertex
    /// color is the gradient's top.
    gradient_to: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const MATERIAL_SIZE = @sizeOf(GlyphMaterial); // 48 bytes

pub const TYPE_SOLID: u32 = 0;
pub const TYPE_GLYPH: u32 = 1;
pub const TYPE_ROUNDED_RECT: u32 = 2;
pub const TYPE_SHADOW: u32 = 3;
pub const TYPE_STROKE: u32 = 4; // a path stroked at width bearing_y (the distance branch)
pub const TYPE_SWEEP: u32 = 5; // an SVG fill: the SDF-based sweep AA (no subpixel)

/// Compute the AABB extent of a set of curves.
pub fn glyphExtent(curves: []const Curve) struct { min_x: f32, min_y: f32, w: f32, h: f32 } {
    if (curves.len == 0) return .{ .min_x = 0, .min_y = 0, .w = 20, .h = 20 };
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
    return .{ .min_x = min_x, .min_y = min_y, .w = max_x - min_x, .h = max_y - min_y };
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
        std.debug.assert(curves.len <= std.math.maxInt(u32));
        @as(*u32, @ptrCast(@alignCast(dst))).* = @intCast(curves.len);
        @as(*u32, @ptrCast(@alignCast(dst + 4))).* = 0;
        const curve_dst: [*]Curve = @ptrCast(@alignCast(dst + 8));
        @memcpy(curve_dst[0..curves.len], curves);

        const ext = glyphExtent(curves);
        std.debug.assert(curves.len <= std.math.maxInt(u32));
        return .{
            .gpu = gpu,
            .curve_buf = curve_buf,
            .curve_buf_bda = curve_buf.gpu,
            .curve_left = ext.min_x,
            .curve_bottom = ext.min_y,
            .curve_w = ext.w,
            .curve_h = ext.h,
            .bearing_y = ext.h,
            .num_curves = @intCast(curves.len),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.gpu.gpuFree(self.curve_buf);
    }

    /// Grow the curve buffer to hold `extra` additional bytes after the
    /// curve array (used by the demo to append a coverage bitmap). The BDA
    /// may change; callers must re-write materials after growing.
    pub fn growCurveBuffer(self: *@This(), extra: usize) !void {
        const base = @sizeOf(u32) * 2 + @as(usize, self.num_curves) * @sizeOf(Curve);
        const padded = (extra + 3) & ~@as(usize, 3);
        const new_size = base + padded;
        const new_buf = try self.gpu.gpuMalloc(new_size, 16, .default);
        @memcpy(@as([*]u8, @ptrCast(@alignCast(new_buf.cpu)))[0..base], @as([*]const u8, @ptrCast(@alignCast(self.curve_buf.cpu)))[0..base]);
        self.gpu.gpuFree(self.curve_buf);
        self.curve_buf = new_buf;
        self.curve_buf_bda = new_buf.gpu;
    }

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

    /// Write a stroke material (type 4): the same curve BDA as the fill,
    /// with the stroke width in bearing_y (user units; the SvgView scales
    /// it with the view). The fragment's TYPE_STROKE branch computes the
    /// distance to the curves instead of the sweep coverage.
    pub fn writeStrokeMaterial(
        curve_bda: u64,
        material_buf: noapi.GpuPtr,
        slot: u32,
        width: f32,
    ) void {
        const mat = GlyphMaterial{
            .type = TYPE_STROKE,
            .bearing_y = width,
            .curve_w = 0,
            .curve_h = 0,
            .win_w = 0,
            .win_h = 0,
            .curve_bda = curve_bda,
        };
        const offset = slot * MATERIAL_SIZE;
        const dst: [*]u8 = @ptrCast(@alignCast(material_buf.cpu));
        @as(*GlyphMaterial, @ptrCast(@alignCast(dst + offset))).* = mat;
    }

    /// Write an SVG fill material (type 5): the same curve BDA + extent
    /// as TYPE_GLYPH, but the fragment uses the SDF-based sweep AA (the
    /// fwidth band + gamma) and — crucially — NOT the subpixel branch:
    /// the tiger's colored fills must never be RGB-striped. The text's
    /// glyphs keep TYPE_GLYPH, so the two render independently.
    pub fn writeSweepMaterial(
        curve_bda: u64,
        material_buf: noapi.GpuPtr,
        slot: u32,
        curve_w: f32,
        curve_h: f32,
    ) void {
        const mat = GlyphMaterial{
            .type = TYPE_SWEEP,
            .bearing_y = 0,
            .curve_w = curve_w,
            .curve_h = curve_h,
            .win_w = curve_w,
            .win_h = curve_h,
            .curve_bda = curve_bda,
        };
        const offset = slot * MATERIAL_SIZE;
        const dst: [*]u8 = @ptrCast(@alignCast(material_buf.cpu));
        @as(*GlyphMaterial, @ptrCast(@alignCast(dst + offset))).* = mat;
    }

    /// Write a rounded-rect material (type 2) for a fill or ring into the
    /// GPU material buffer at the given slot. win_w/win_h = the rect size
    /// in framebuffer px (the border box for rings, the border-inset rect
    /// for fills); curve_w/curve_h = the corner radii (x/y); bearing_y =
    /// the border width (0 for a plain fill). gradient_to = the gradient
    /// bottom color (all-zero = flat fill; vColor is the gradient top).
    pub fn writeRoundedRectMaterial(
        material_buf: noapi.GpuPtr,
        slot: u32,
        x_radius: f32,
        y_radius: f32,
        border: f32,
        rect_w: f32,
        rect_h: f32,
        gradient_to: [4]f32,
    ) void {
        const mat = GlyphMaterial{
            .type = TYPE_ROUNDED_RECT,
            .bearing_y = border,
            .curve_w = x_radius,
            .curve_h = y_radius,
            .win_w = rect_w,
            .win_h = rect_h,
            .curve_bda = 0,
            .gradient_to = gradient_to,
        };
        const offset = slot * MATERIAL_SIZE;
        const dst: [*]u8 = @ptrCast(@alignCast(material_buf.cpu));
        @as(*GlyphMaterial, @ptrCast(@alignCast(dst + offset))).* = mat;
    }

    /// Write a feathered shadow material (type 3) into the GPU material
    /// buffer at the given slot. win_w/win_h = the shadow rect size in
    /// framebuffer px; curve_w/curve_h = the widget's corner radii (x/y);
    /// bearing_y = the feather (px, soft-edge width).
    pub fn writeShadowMaterial(
        material_buf: noapi.GpuPtr,
        slot: u32,
        x_radius: f32,
        y_radius: f32,
        feather: f32,
        rect_w: f32,
        rect_h: f32,
    ) void {
        const mat = GlyphMaterial{
            .type = TYPE_SHADOW,
            .bearing_y = feather,
            .curve_w = x_radius,
            .curve_h = y_radius,
            .win_w = rect_w,
            .win_h = rect_h,
            .curve_bda = 0,
        };
        const offset = slot * MATERIAL_SIZE;
        const dst: [*]u8 = @ptrCast(@alignCast(material_buf.cpu));
        @as(*GlyphMaterial, @ptrCast(@alignCast(dst + offset))).* = mat;
    }
};

const testing = std.testing;

test "glyphExtent: empty array returns default" {
    const ext = glyphExtent(&.{});
    try testing.expectEqual(@as(f32, 0), ext.min_x);
    try testing.expectEqual(@as(f32, 0), ext.min_y);
    try testing.expectEqual(@as(f32, 20), ext.w);
    try testing.expectEqual(@as(f32, 20), ext.h);
}

test "glyphExtent: single curve" {
    const curves = [_]Curve{
        .{ .p0x = 0, .p0y = 0, .p1x = 10, .p1y = 5, .p2x = 20, .p2y = 10 },
    };
    const ext = glyphExtent(&curves);
    try testing.expectEqual(@as(f32, 0), ext.min_x);
    try testing.expectEqual(@as(f32, 0), ext.min_y);
    try testing.expectEqual(@as(f32, 20), ext.w);
    try testing.expectEqual(@as(f32, 10), ext.h);
}

test "glyphExtent: multiple curves" {
    const curves = [_]Curve{
        .{ .p0x = -5, .p0y = -5, .p1x = 0, .p1y = 0, .p2x = 10, .p2y = 10 },
        .{ .p0x = 10, .p0y = 10, .p1x = 20, .p1y = 20, .p2x = 30, .p2y = 30 },
    };
    const ext = glyphExtent(&curves);
    try testing.expectEqual(@as(f32, -5), ext.min_x);
    try testing.expectEqual(@as(f32, -5), ext.min_y);
    try testing.expectEqual(@as(f32, 35), ext.w);
    try testing.expectEqual(@as(f32, 35), ext.h);
}
