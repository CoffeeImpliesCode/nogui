//! Glyph test — load a font with FreeType, extract glyph outlines,
//! prepare data for the scanline-sweeper GPU rasterizer.
//!
//! Run with: zig build glyph

const std = @import("std");
const c = @cImport({
    @cDefine("FT2_BUILD_LIBRARY", "1");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftoutln.h");
    @cInclude("freetype/ftglyph.h");
});

const QuadCurve = struct { ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32 };

fn cubicToQuads(p0x: f32, p0y: f32, p1x: f32, p1y: f32, p2x: f32, p2y: f32, p3x: f32, p3y: f32, out: []QuadCurve) usize {
    const t: f32 = 0.5;
    const mt: f32 = 1.0 - t;
    const b0x = mt * p0x + t * p1x;
    const b0y = mt * p0y + t * p1y;
    const b1x = mt * p1x + t * p2x;
    const b1y = mt * p1y + t * p2y;
    const b2x = mt * p2x + t * p3x;
    const b2y = mt * p2y + t * p3y;
    const c0x = mt * b0x + t * b1x;
    const c0y = mt * b0y + t * b1y;
    const c1x = mt * b1x + t * b2x;
    const c1y = mt * b1y + t * b2y;
    const dx = mt * c0x + t * c1x;
    const dy = mt * c0y + t * c1y;
    out[0] = .{ .ax = p0x, .ay = p0y, .bx = b0x, .by = b0y, .cx = dx, .cy = dy };
    out[1] = .{ .ax = dx, .ay = dy, .bx = c1x, .by = c1y, .cx = p3x, .cy = p3y };
    return 2;
}

fn isYMonotonic(q: QuadCurve) bool {
    const denom = q.ay + q.cy - 2.0 * q.by;
    if (@abs(denom) < 1e-6) return true;
    const t0 = (q.ay - q.by) / denom;
    return t0 <= 0.0 or t0 >= 1.0;
}

fn isXMonotonic(q: QuadCurve) bool {
    const denom = q.ax + q.cx - 2.0 * q.bx;
    if (@abs(denom) < 1e-6) return true;
    const t0 = (q.ax - q.bx) / denom;
    return t0 <= 0.0 or t0 >= 1.0;
}

fn subdivide(q: QuadCurve, t: f32) [2]QuadCurve {
    const mt = 1.0 - t;
    const mid_x = mt * (mt * q.ax + t * q.bx) + t * (mt * q.bx + t * q.cx);
    const mid_y = mt * (mt * q.ay + t * q.by) + t * (mt * q.by + t * q.cy);
    const b1x = mt * q.ax + t * q.bx;
    const b1y = mt * q.ay + t * q.by;
    const b2x = mt * q.bx + t * q.cx;
    const b2y = mt * q.by + t * q.cy;
    return .{
        .{ .ax = q.ax, .ay = q.ay, .bx = b1x, .by = b1y, .cx = mid_x, .cy = mid_y },
        .{ .ax = mid_x, .ay = mid_y, .bx = b2x, .by = b2y, .cx = q.cx, .cy = q.cy },
    };
}

fn ensureMonotonic(q: QuadCurve, out: *[2]QuadCurve) usize {
    if (isXMonotonic(q) and isYMonotonic(q)) {
        out[0] = q;
        return 1;
    }
    const halves = subdivide(q, 0.5);
    out[0] = halves[0];
    out[1] = halves[1];
    return 2;
}

const MAX_CURVES = 4096;

const OutlineCollector = struct {
    curves: [MAX_CURVES]QuadCurve = undefined,
    count: usize = 0,
    first_x: f32 = 0,
    first_y: f32 = 0,
    last_x: f32 = 0,
    last_y: f32 = 0,

    fn push(self: *OutlineCollector, q: QuadCurve) void {
        if (self.count < self.curves.len) {
            self.curves[self.count] = q;
            self.count += 1;
        }
    }
    fn moveTo(self: *OutlineCollector, to_x: f32, to_y: f32) void {
        self.first_x = to_x;
        self.first_y = to_y;
        self.last_x = to_x;
        self.last_y = to_y;
    }
    fn lineTo(self: *OutlineCollector, to_x: f32, to_y: f32) void {
        const mx = (self.last_x + to_x) * 0.5;
        const my = (self.last_y + to_y) * 0.5;
        self.push(.{ .ax = self.last_x, .ay = self.last_y, .bx = mx, .by = my, .cx = to_x, .cy = to_y });
        self.last_x = to_x;
        self.last_y = to_y;
    }
    fn conicTo(self: *OutlineCollector, cx: f32, cy: f32, to_x: f32, to_y: f32) void {
        self.push(.{ .ax = self.last_x, .ay = self.last_y, .bx = cx, .by = cy, .cx = to_x, .cy = to_y });
        self.last_x = to_x;
        self.last_y = to_y;
    }
    fn cubicTo(self: *OutlineCollector, cx1: f32, cy1: f32, cx2: f32, cy2: f32, to_x: f32, to_y: f32) void {
        var quads: [2]QuadCurve = undefined;
        for (quads[0..cubicToQuads(self.last_x, self.last_y, cx1, cy1, cx2, cy2, to_x, to_y, &quads)]) |q| self.push(q);
        self.last_x = to_x;
        self.last_y = to_y;
    }
    fn close(self: *OutlineCollector) void {
        if (@abs(self.last_x - self.first_x) > 0.001 or @abs(self.last_y - self.first_y) > 0.001) self.lineTo(self.first_x, self.first_y);
    }
};

fn ftMoveTo(to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
    const col: *OutlineCollector = @ptrCast(@alignCast(user));
    col.moveTo(@as(f32, @floatFromInt(to.*.x)) / 64.0, @as(f32, @floatFromInt(to.*.y)) / 64.0);
    return 0;
}
fn ftLineTo(to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
    const col: *OutlineCollector = @ptrCast(@alignCast(user));
    col.lineTo(@as(f32, @floatFromInt(to.*.x)) / 64.0, @as(f32, @floatFromInt(to.*.y)) / 64.0);
    return 0;
}
fn ftConicTo(control: [*c]const c.FT_Vector, to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
    const col: *OutlineCollector = @ptrCast(@alignCast(user));
    col.conicTo(@as(f32, @floatFromInt(control.*.x)) / 64.0, @as(f32, @floatFromInt(control.*.y)) / 64.0, @as(f32, @floatFromInt(to.*.x)) / 64.0, @as(f32, @floatFromInt(to.*.y)) / 64.0);
    return 0;
}
fn ftCubicTo(c1: [*c]const c.FT_Vector, c2: [*c]const c.FT_Vector, to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
    const col: *OutlineCollector = @ptrCast(@alignCast(user));
    col.cubicTo(@as(f32, @floatFromInt(c1.*.x)) / 64.0, @as(f32, @floatFromInt(c1.*.y)) / 64.0, @as(f32, @floatFromInt(c2.*.x)) / 64.0, @as(f32, @floatFromInt(c2.*.y)) / 64.0, @as(f32, @floatFromInt(to.*.x)) / 64.0, @as(f32, @floatFromInt(to.*.y)) / 64.0);
    return 0;
}

pub fn main() !void {
    var ft_lib: c.FT_Library = undefined;
    if (c.FT_Init_FreeType(&ft_lib) != 0) {
        std.debug.print("Failed FreeType init\n", .{});
        return;
    }
    defer _ = c.FT_Done_FreeType(ft_lib);

    @setEvalBranchQuota(10000);
    const font_data = @embedFile("DejaVuSans.ttf");
    std.debug.print("Font: {d} bytes\n", .{font_data.len});

    var face: c.FT_Face = undefined;
    if (c.FT_New_Memory_Face(ft_lib, font_data.ptr, @as(c.FT_Long, @intCast(font_data.len)), 0, &face) != 0) {
        std.debug.print("Failed to load face\n", .{});
        return;
    }
    defer _ = c.FT_Done_Face(face);
    _ = c.FT_Set_Pixel_Sizes(face, 0, 64);

    std.debug.print("Face: {s} ({s}), {d} glyphs\n", .{
        @as([*:0]const u8, @ptrCast(face.*.family_name)),
        @as([*:0]const u8, @ptrCast(face.*.style_name)),
        face.*.num_glyphs,
    });

    const glyph_index = c.FT_Get_Char_Index(face, 'A');
    if (glyph_index == 0) {
        std.debug.print("Glyph 'A' not found\n", .{});
        return;
    }
    _ = c.FT_Load_Glyph(face, glyph_index, c.FT_LOAD_NO_BITMAP);

    const outline = &face.*.glyph.*.outline;
    std.debug.print("\n=== 'A' contours={d} points={d} ===\n", .{ outline.*.n_contours, outline.*.n_points });

    var col = OutlineCollector{};
    var funcs = c.FT_Outline_Funcs{
        .move_to = ftMoveTo,
        .line_to = ftLineTo,
        .conic_to = ftConicTo,
        .cubic_to = ftCubicTo,
        .shift = 0,
        .delta = 0,
    };
    _ = c.FT_Outline_Decompose(outline, &funcs, &col);

    std.debug.print("Curves: {d}\n", .{col.count});
    for (col.curves[0..@min(col.count, 8)], 0..) |q, i|
        std.debug.print("  [{d}] ({d:.1},{d:.1})->({d:.1},{d:.1})->({d:.1},{d:.1})\n", .{ i, q.ax, q.ay, q.bx, q.by, q.cx, q.cy });
    if (col.count > 8) std.debug.print("  ...\n", .{});

    var mono: [8192]QuadCurve = undefined;
    var mc: usize = 0;
    for (col.curves[0..col.count]) |q| {
        var buf: [2]QuadCurve = undefined;
        for (buf[0..ensureMonotonic(q, &buf)]) |mq| {
            if (mc < mono.len) {
                mono[mc] = mq;
                mc += 1;
            }
        }
    }
    std.debug.print("Monotonic: {d}\n", .{mc});

    var min_x: f32 = 1e9;
    var min_y: f32 = 1e9;
    var max_x: f32 = -1e9;
    var max_y: f32 = -1e9;
    for (mono[0..mc]) |q| {
        for ([_]f32{ q.ax, q.cx }) |x| {
            min_x = @min(min_x, x);
            max_x = @max(max_x, x);
        }
        for ([_]f32{ q.ay, q.cy }) |y| {
            min_y = @min(min_y, y);
            max_y = @max(max_y, y);
        }
    }
    std.debug.print("AABB: ({d:.1},{d:.1})->({d:.1},{d:.1})\n", .{ min_x, min_y, max_x, max_y });
    std.debug.print("Advance: {d:.1}px\n", .{@as(f32, @floatFromInt(face.*.glyph.*.metrics.horiAdvance)) / 64.0});
}
