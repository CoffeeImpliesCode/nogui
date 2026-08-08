//! HarfBuzz-shaped text engine for the v7 demo.
//!
//! EXPERIMENT: the per-codepoint FreeType iteration (FT_Get_Char_Index +
//! advance sums, no kerning) is replaced with HarfBuzz shaping (hb_shape:
//! kerning, ligatures, mark positioning). FreeType remains as the rasterizer
//! backend ONLY — the hb-ft font delegates outline extraction to it, and we
//! load the shaped glyph ids from the shared face. All layout decisions
//! (glyph selection, advances, offsets) come from HarfBuzz.
//!
//! Demo-side only: the v7 CORE (src/v7/) stays pure; this file MAY import
//! noapi.

const std = @import("std");
const noapi = @import("noapi");
const proto = @import("proto/sweeper.zig");
const SliceRect = @import("proto/render_9slice.zig").SliceRect;
const WidgetSize = @import("v7/widget.zig").Size;

// One C import, owned by the HarfBuzz binding: hb.h + hb-ft.h pull in
// freetype.h, so this exposes the full FreeType API we still need for
// outline extraction.
const hb = @import("harfbuzz");
const c = hb.c; // the binding's single C import: hb.h + hb-ft.h + freetype.h

pub const MAX_MATERIALS: u32 = 128; // slot 0 = solid; glyphs start at 1
pub const FONT_SIZE_PX: u32 = 20;

pub const GlyphEntry = struct {
    gid: u32, // shaped glyph id (the shaper resolved the codepoint)
    slot: u32, // material slot
    advance: f32,
    bearing_x: f32,
    bearing_y: f32,
    glyph_w: f32,
    glyph_h: f32,
    curve_left: f32, // from sweeper glyphExtent
    curve_bottom: f32,
    curve_w: f32,
    curve_h: f32,
};

pub const TextEngine = struct {
    /// The flex measure hook target: the demo sets this after init and
    /// points App.measure at measureForFlex, so layout sizes leaves to the
    /// real text extent instead of the baked len*10 approximation.
    pub var measure_engine: ?*TextEngine = null;

    /// Host-side measure callback for flex.layoutWith.
    pub fn measureForFlex(text: []const u8) WidgetSize {
        return measure_engine.?.measureText(text);
    }
    gpu: *noapi.Gpu,
    gpa: std.mem.Allocator,
    ft_lib: c.FT_Library,
    face: c.FT_Face,
    /// HarfBuzz font over the shared FT face (hb_ft_font_create_referenced).
    /// The shaper owns all glyph selection/positioning; FT only rasterizes.
    hb_font: hb.Font,
    // Parallel arrays, one element per rasterized glyph:
    // sweepers[i] owns the GPU curve buffer backing entries[i].
    sweepers: std.ArrayList(proto.GlyphSweeper) = .empty, // per glyph
    entries: std.ArrayList(GlyphEntry) = .empty, // per glyph
    materials: noapi.GpuPtr, // MAX_MATERIALS * MATERIAL_SIZE, .default
    next_slot: u32 = 1,
    material_bda: u64 = 0,

    /// Init FreeType, load the embedded Inter font at FONT_SIZE_PX, wrap it
    /// in a HarfBuzz font, and allocate the material buffer. Returns errors
    /// (not panics) on FT/HB failures; on partial failure everything
    /// allocated so far is released.
    pub fn init(gpu: *noapi.Gpu, gpa: std.mem.Allocator) !TextEngine {
        // SAFETY: assigned by FT_Init/FT_New before any use; failures return errors.
        var ft_lib: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&ft_lib) != 0) return error.FreeTypeInitFailed;
        errdefer _ = c.FT_Done_FreeType(ft_lib);

        const font_data = @embedFile("InterVariable.ttf");
        // SAFETY: assigned by FT_Init/FT_New before any use; failures return errors.
        var face: c.FT_Face = undefined;
        std.debug.assert(font_data.len <= std.math.maxInt(u32));
        if (c.FT_New_Memory_Face(ft_lib, font_data.ptr, @as(c.FT_Long, @intCast(font_data.len)), 0, &face) != 0)
            return error.FreeTypeFaceFailed;
        errdefer _ = c.FT_Done_Face(face);
        if (c.FT_Set_Pixel_Sizes(face, 0, FONT_SIZE_PX) != 0) return error.FreeTypeSetPixelSizesFailed;

        // hb-ft over the shared FT face. NOTE: we build the Font directly
        // from the binding's `c` (hb.c) rather than hb.freetype.createFont —
        // the binding's freetype.zig uses the freetype PACKAGE's separate
        // translate-c of freetype.h, whose FT_Face type is incompatible with
        // the one in hb.c (two cimport instances of the same header).
        const hb_handle = hb.c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed;
        var hb_font = hb.Font{ .handle = hb_handle };
        hb.c.hb_ft_font_set_funcs(hb_handle);
        errdefer hb_font.destroy();

        const materials = try gpu.gpuMalloc(MAX_MATERIALS * proto.MATERIAL_SIZE, 64, .default);
        errdefer gpu.gpuFree(materials);

        return .{
            .gpu = gpu,
            .gpa = gpa,
            .ft_lib = ft_lib,
            .face = face,
            .hb_font = hb_font,
            .materials = materials,
            .material_bda = materials.gpu,
        };
    }

    pub fn deinit(self: *TextEngine) void {
        for (self.sweepers.items) |*s| s.deinit(); // frees each GPU curve buffer
        self.sweepers.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        self.hb_font.destroy();
        self.gpu.gpuFree(self.materials);
        _ = c.FT_Done_Face(self.face);
        _ = c.FT_Done_FreeType(self.ft_lib);
    }

    pub fn materialBda(self: *const TextEngine) u64 {
        return self.material_bda;
    }

    /// Shape a UTF-8 run with HarfBuzz, returning the owning buffer. The
    /// caller reads getGlyphInfos()/getGlyphPositions() and MUST destroy the
    /// buffer when done. hb's addUTF8 never panics on invalid bytes (it
    /// substitutes .notdef, which the gid-0 skip drops) — the old tolerant
    /// iterator is gone.
    fn shapeRun(self: *TextEngine, text: []const u8) !hb.Buffer {
        var buf = try hb.Buffer.create();
        errdefer buf.destroy();
        buf.addUTF8(text);
        buf.setDirection(.ltr);
        buf.setScript(.latin);
        hb.shape(self.hb_font, buf, null);
        return buf;
    }

    /// Rasterize glyph `gid` on demand: extract curves → sweeper (GPU curve
    /// buffer) → glyph material → entry. Glyph id 0 (.notdef, from chars
    /// absent in the font) and glyphs whose outline extraction fails are
    /// skipped (no entry, no error). Returns error.TooManyGlyphs once the
    /// MAX_MATERIALS slot budget is exhausted (checked only for glyphs that
    /// would actually consume a new slot).
    fn ensureGlyph(self: *TextEngine, gid: u32) !void {
        if (gid == 0) return; // .notdef: missing glyph, skip
        for (self.entries.items) |e| {
            if (e.gid == gid) return; // already rasterized
        }

        // Slot budget exhausted: fail with a real error instead of writing
        // OOB into the GPU material heap — a debug-only assert would compile
        // out in ReleaseFast. The assert stays as belt-and-suspenders.
        std.debug.assert(self.next_slot < MAX_MATERIALS); // slot 0 reserved for solid
        if (self.next_slot >= MAX_MATERIALS) return error.TooManyGlyphs;

        // Extraction failures (missing outline, draw error) → skip glyph.
        const curves = extractGlyphCurves(self.gpa, self.hb_font, gid) catch return;
        defer self.gpa.free(curves);

        var sweeper = try proto.GlyphSweeper.init(self.gpu, curves);

        // Metrics from HarfBuzz (the same 26.6 fixed-point scale as the
        // shaped positions; /64.0 → pixels). No FreeType in our code.
        const advance = @as(f32, @floatFromInt(c.hb_font_get_glyph_h_advance(self.hb_font.handle, gid))) / 64.0;
        // SAFETY: assigned by hb_font_get_glyph_extents before any read; a
        // zero return (no ink) skips the glyph.
        var ext: c.hb_glyph_extents_t = undefined;
        if (c.hb_font_get_glyph_extents(self.hb_font.handle, gid, &ext) == 0) return; // no ink
        const bearing_x = @as(f32, @floatFromInt(ext.x_bearing)) / 64.0;
        const bearing_y = @as(f32, @floatFromInt(ext.y_bearing)) / 64.0;
        const glyph_w = @as(f32, @floatFromInt(ext.width)) / 64.0;
        // hb extents: height is NEGATIVE for y-up fonts (the box extends
        // downward from the top bearing) — the magnitude is the ink height.
        const glyph_h = @as(f32, @floatFromInt(@abs(ext.height))) / 64.0;

        // Rasterize the coverage bitmap (per-pixel sweep — provably correct,
        // see the sweep tests) and append it to the curve buffer. The shader
        // samples this bitmap instead of sweeping per fragment.
        const bmp_w: u32 = @intFromFloat(@ceil(@max(glyph_w, 1)));
        const bmp_h: u32 = @intFromFloat(@ceil(@max(glyph_h, 1)));
        const win = [2]f32{ sweeper.curve_w / @max(glyph_w, 0.5), sweeper.curve_h / @max(glyph_h, 0.5) };
        const bitmap = try self.gpa.alloc(u8, bmp_w * bmp_h);
        defer self.gpa.free(bitmap);
        for (0..bmp_h) |py| {
            for (0..bmp_w) |px| {
                const off = [2]f32{
                    sweeper.curve_left + sweeper.curve_w * @as(f32, @floatFromInt(px)) / @max(glyph_w, 0.5),
                    sweeper.curve_bottom + sweeper.curve_h * @as(f32, @floatFromInt(py)) / @max(glyph_h, 0.5),
                };
                var total: f32 = 0;
                for (curves) |cv| {
                    total += sweepSegment(win, off, .{ cv.p0x, cv.p0y }, .{ cv.p1x, cv.p1y }, .{ cv.p2x, cv.p2y });
                }
                const cov = std.math.clamp(total / (win[0] * win[1]), 0.0, 1.0);
                // Row 0 = glyph TOP (py = bmp_h-1 maps to off.y = curve top;
                // py = 0 maps to the bottom). The shader reads row = cell.y
                // with no flip: framebuffer y is down, matching this layout.
                bitmap[(bmp_h - 1 - py) * bmp_w + px] = @intFromFloat(cov * 255.0);
            }
        }
        try sweeper.growCurveBuffer(bitmap.len);
        const base = @sizeOf(u32) * 2 + curves.len * @sizeOf(proto.Curve);
        @memcpy(@as([*]u8, @ptrCast(@alignCast(sweeper.curve_buf.cpu)))[base .. base + bitmap.len], bitmap);

        const slot = self.next_slot;
        proto.GlyphSweeper.writeMaterial(
            sweeper.curve_buf_bda,
            self.materials,
            slot,
            bearing_y,
            sweeper.curve_w,
            sweeper.curve_h,
            @floatFromInt(bmp_w),
            @floatFromInt(bmp_h),
        );
        self.next_slot += 1;

        // Transfer the sweeper into the parallel list. On any append failure
        // free the GPU curve buffer so nothing leaks and the two lists stay
        // index-aligned.
        self.sweepers.append(self.gpa, sweeper) catch |e| {
            sweeper.deinit();
            return e;
        };
        self.entries.append(self.gpa, .{
            .gid = gid,
            .slot = slot,
            .advance = advance,
            .bearing_x = bearing_x,
            .bearing_y = bearing_y,
            .glyph_w = glyph_w,
            .glyph_h = glyph_h,
            .curve_left = sweeper.curve_left,
            .curve_bottom = sweeper.curve_bottom,
            .curve_w = sweeper.curve_w,
            .curve_h = sweeper.curve_h,
        }) catch |e| {
            var orphan = self.sweepers.pop().?;
            orphan.deinit();
            return e;
        };
    }

    /// Shape `text` (kerning/ligatures included), ensure the glyphs exist
    /// (lazy), then append one SliceRect per glyph to `out` at (x,
    /// baseline_y). `baseline_y` is the font baseline (the caller computes
    /// it from the widget rect). Advances and per-glyph offsets come from
    /// the shaper (26.6 fixed-point, /64.0 → px; y offsets are y-up, so the
    /// y-down framebuffer subtracts them). Glyph id 0 (.notdef: chars
    /// missing from the font or invalid UTF-8) is skipped WITHOUT advancing,
    /// matching the pre-shaping behavior. Propagates error.TooManyGlyphs if
    /// the material slot budget is exhausted.
    pub fn emitText(self: *TextEngine, text: []const u8, x: f32, baseline_y: f32, out: *std.ArrayList(SliceRect)) !void {
        var buf = try self.shapeRun(text);
        defer buf.destroy();
        const infos = buf.getGlyphInfos();
        const positions = buf.getGlyphPositions() orelse &.{};
        var cursor = x;
        for (infos, positions) |info, pos| {
            try self.ensureGlyph(info.codepoint);
            const entry = self.entryFor(info.codepoint) orelse continue; // gid 0 → skip
            // Canonical HarfBuzz placement: the glyph sits at the pen plus
            // its x/y offsets, then the pen advances by x_advance. No
            // snapping — the shader bilinearly filters the coverage bitmap
            // at the fractional positions, so sub-pixel kerning survives
            // and moving text stays smooth. (y offsets are y-up font
            // units; the framebuffer is y-down, hence the minus.)
            const ch_x = cursor + @as(f32, @floatFromInt(pos.x_offset)) / 64.0 + entry.bearing_x;
            const ch_y = baseline_y - entry.bearing_y - @as(f32, @floatFromInt(pos.y_offset)) / 64.0;
            if (entry.glyph_w <= 0 or entry.glyph_h <= 0) {
                cursor += @as(f32, @floatFromInt(pos.x_advance)) / 64.0; // zero-size glyph (e.g. space): advance only
                continue;
            }
            try out.append(self.gpa, .{
                .dst_x = ch_x,
                .dst_y = ch_y,
                // The quad must cover the full bitmap (ceil'd): a
                // fractional glyph_h would leave the bottom bitmap row —
                // the ink's tip (descenders) — sampled at a reduced
                // weight, visually clipping the glyph's low part.
                .dst_w = @ceil(entry.glyph_w),
                .dst_h = @ceil(entry.glyph_h),
                .src_u = 0,
                .src_v = 0,
                .src_w = 1,
                .src_h = 1,
                .corner_l = 0,
                .corner_r = 0,
                .corner_t = 0,
                .corner_b = 0,
                .color = .{ 1, 0, 0, 1 }, // OKLAB white (L=1, a=0, b=0)
                .material_index = entry.slot,
                .curve_left = entry.curve_left,
                .curve_bottom = entry.curve_bottom,
                .curve_w = entry.curve_w,
                .curve_h = entry.curve_h,
            });
            cursor += @as(f32, @floatFromInt(pos.x_advance)) / 64.0;
        }
    }

    /// Measure a text run's content size only: the SHAPED width (the sum of
    /// the shaper's advances — kerning and ligatures included), 24px tall
    /// (20px cap height + descender room); padding and border come from the
    /// widget box (flex), not from the measurement. Shapes only — no glyph
    /// rasterization (unlike the pre-shaping measure, which forced the
    /// atlas to fill). On shape failure falls back to the baked estimate.
    pub fn measureText(self: *TextEngine, text: []const u8) WidgetSize {
        var buf = self.shapeRun(text) catch return .{
            .width = @as(f32, @floatFromInt(text.len)) * 10,
            .height = 24,
        };
        defer buf.destroy();
        var w: f32 = 0;
        for (buf.getGlyphPositions() orelse &.{}) |pos| {
            w += @as(f32, @floatFromInt(pos.x_advance)) / 64.0;
        }
        return .{ .width = w, .height = 24 };
    }

    fn entryFor(self: *const TextEngine, gid: u32) ?GlyphEntry {
        for (self.entries.items) |e| {
            if (e.gid == gid) return e;
        }
        return null;
    }
};

/// Extract glyph curves for a specific SHAPED glyph id via HarfBuzz's
/// draw API (hb_font_draw_glyph — the hb-ft backend emits the outline in
/// the font's scale, 26.6 fixed-point px; /64 → px). No FreeType calls in
/// our code: the face exists only as the hb-ft backend. Callbacks fill a
/// 4096-curve stack buffer (cubic segments split into two conics at
/// t=0.5), then the caller-owned slice is dupe'd via `alloc`.
fn extractGlyphCurves(alloc: std.mem.Allocator, font: hb.Font, gid: u32) ![]proto.Curve {
    if (gid == 0) return error.GlyphNotFound;

    var buf: [4096]proto.Curve = undefined;
    var count: u32 = 0;
    var first_x: f32 = 0;
    var first_y: f32 = 0;
    var last_x: f32 = 0;
    var last_y: f32 = 0;

    const Ctx = struct {
        curves: *[4096]proto.Curve,
        count: *u32,
        first_x: *f32,
        first_y: *f32,
        last_x: *f32,
        last_y: *f32,
    };

    var ctx = Ctx{
        .curves = &buf,
        .count = &count,
        .first_x = &first_x,
        .first_y = &first_y,
        .last_x = &last_x,
        .last_y = &last_y,
    };

    const move_cb = struct {
        fn cb(dfuncs: ?*c.hb_draw_funcs_t, draw_data: ?*anyopaque, st: ?*c.hb_draw_state_t, to_x: f32, to_y: f32, user_data: ?*anyopaque) callconv(.c) void {
            _ = dfuncs;
            _ = draw_data;
            _ = st;
            const p: *Ctx = @ptrCast(@alignCast(user_data));
            p.first_x.* = to_x / 64;
            p.first_y.* = to_y / 64;
            p.last_x.* = p.first_x.*;
            p.last_y.* = p.first_y.*;
        }
    }.cb;
    const line_cb = struct {
        fn cb(dfuncs: ?*c.hb_draw_funcs_t, draw_data: ?*anyopaque, st: ?*c.hb_draw_state_t, to_x: f32, to_y: f32, user_data: ?*anyopaque) callconv(.c) void {
            _ = dfuncs;
            _ = draw_data;
            _ = st;
            const p: *Ctx = @ptrCast(@alignCast(user_data));
            const tx = to_x / 64;
            const ty = to_y / 64;
            if (p.count.* < 4096) {
                p.curves[p.count.*] = .{ .p0x = p.last_x.*, .p0y = p.last_y.*, .p1x = (p.last_x.* + tx) * 0.5, .p1y = (p.last_y.* + ty) * 0.5, .p2x = tx, .p2y = ty };
                p.count.* += 1;
            }
            p.last_x.* = tx;
            p.last_y.* = ty;
        }
    }.cb;
    const quad_cb = struct {
        fn cb(dfuncs: ?*c.hb_draw_funcs_t, draw_data: ?*anyopaque, st: ?*c.hb_draw_state_t, control_x: f32, control_y: f32, to_x: f32, to_y: f32, user_data: ?*anyopaque) callconv(.c) void {
            _ = dfuncs;
            _ = draw_data;
            _ = st;
            const p: *Ctx = @ptrCast(@alignCast(user_data));
            const cx = control_x / 64;
            const cy = control_y / 64;
            const tx = to_x / 64;
            const ty = to_y / 64;
            if (p.count.* < 4096) {
                p.curves[p.count.*] = .{ .p0x = p.last_x.*, .p0y = p.last_y.*, .p1x = cx, .p1y = cy, .p2x = tx, .p2y = ty };
                p.count.* += 1;
            }
            p.last_x.* = tx;
            p.last_y.* = ty;
        }
    }.cb;
    const cubic_cb = struct {
        fn cb(dfuncs: ?*c.hb_draw_funcs_t, draw_data: ?*anyopaque, st: ?*c.hb_draw_state_t, c1x: f32, c1y: f32, c2x: f32, c2y: f32, to_x: f32, to_y: f32, user_data: ?*anyopaque) callconv(.c) void {
            _ = dfuncs;
            _ = draw_data;
            _ = st;
            const p: *Ctx = @ptrCast(@alignCast(user_data));
            const c1x_px = c1x / 64;
            const c1y_px = c1y / 64;
            const c2x_px = c2x / 64;
            const c2y_px = c2y / 64;
            const tx = to_x / 64;
            const ty = to_y / 64;
            if (p.count.* + 1 < 4096) {
                const t: f32 = 0.5;
                const mt = 1 - t;
                const b0x = mt * p.last_x.* + t * c1x_px;
                const b0y = mt * p.last_y.* + t * c1y_px;
                const b1x = mt * c1x_px + t * c2x_px;
                const b1y = mt * c1y_px + t * c2y_px;
                const b2x = mt * c2x_px + t * tx;
                const b2y = mt * c2y_px + t * ty;
                const cx1 = mt * b0x + t * b1x;
                const cy1 = mt * b0y + t * b1y;
                const cx2 = mt * b1x + t * b2x;
                const cy2 = mt * b1y + t * b2y;
                const dx = mt * cx1 + t * cx2;
                const dy = mt * cy1 + t * cy2;
                p.curves[p.count.*] = .{ .p0x = p.last_x.*, .p0y = p.last_y.*, .p1x = b0x, .p1y = b0y, .p2x = dx, .p2y = dy };
                p.count.* += 1;
                p.curves[p.count.*] = .{ .p0x = dx, .p0y = dy, .p1x = cx2, .p1y = cy2, .p2x = tx, .p2y = ty };
                p.count.* += 1;
            }
            p.last_x.* = tx;
            p.last_y.* = ty;
        }
    }.cb;

    const funcs = c.hb_draw_funcs_create();
    if (funcs == null) return error.GlyphDrawFailed;
    defer _ = c.hb_draw_funcs_destroy(funcs);
    c.hb_draw_funcs_set_move_to_func(funcs, move_cb, &ctx, null);
    c.hb_draw_funcs_set_line_to_func(funcs, line_cb, &ctx, null);
    c.hb_draw_funcs_set_quadratic_to_func(funcs, quad_cb, &ctx, null);
    c.hb_draw_funcs_set_cubic_to_func(funcs, cubic_cb, &ctx, null);
    c.hb_font_draw_glyph(font.handle, gid, funcs, &ctx);

    return alloc.dupe(proto.Curve, buf[0..count]);
}

// ── sweep validation (port of quad_frag scanlineSweep) ─────────────
fn sweepIntersect(qa: f32, c0: f32, c1: f32, c2: f32, target: f32) f32 {
    if (@abs(qa) < 1e-3) return (target - c0) / (c2 - c0);
    const qb = 2.0 * (c1 - c0);
    const qc = c0 - target;
    const d = qb * qb - 4.0 * qa * qc;
    const sqrt_d: f32 = if (d < 0.0) 0.0 else @sqrt(d);
    const inv_2a = 0.5 / qa;
    const sgn: f32 = if (c2 - c0 > 0) 1.0 else -1.0;
    return -qb * inv_2a + sgn * sqrt_d * inv_2a;
}

fn sweepEval(p0: [2]f32, p1: [2]f32, p2: [2]f32, t: f32) [2]f32 {
    const mt = 1.0 - t;
    return .{ mt * mt * p0[0] + 2.0 * mt * t * p1[0] + t * t * p2[0], mt * mt * p0[1] + 2.0 * mt * t * p1[1] + t * t * p2[1] };
}

fn sweepSegment(size: [2]f32, offset: [2]f32, p0: [2]f32, p1: [2]f32, p2: [2]f32) f32 {
    if (@max(p0[1], p2[1]) <= offset[1] or @min(p0[1], p2[1]) >= offset[1] + size[1]) return 0.0;
    const delta = [2]f32{ p2[0] - p0[0], p2[1] - p0[1] };
    const t0 = [2]f32{ p0[0] - offset[0], p0[1] - offset[1] };
    const t1 = [2]f32{ p1[0] - offset[0], p1[1] - offset[1] };
    const t2 = [2]f32{ p2[0] - offset[0], p2[1] - offset[1] };
    if (t0[0] == t1[0] and t0[0] == t2[0]) {
        if (t0[0] >= size[0]) return 0.0;
        const top = @min(@max(t0[1], t2[1]), size[1]);
        const bottom = @max(@min(t0[1], t2[1]), 0.0);
        const b = @min(size[0], size[0] - t0[0]);
        const sgn: f32 = if (delta[1] > 0) 1 else -1;
        return sgn * b * (top - bottom);
    }
    const qa_y = t0[1] + t2[1] - 2.0 * t1[1];
    const bt = sweepIntersect(qa_y, t0[1], t1[1], t2[1], 0.0);
    const tt = sweepIntersect(qa_y, t0[1], t1[1], t2[1], size[1]);
    const v_min_t: f32 = if (delta[1] > 0.0) bt else tt;
    const v_max_t: f32 = if (delta[1] > 0.0) tt else bt;
    const v_min = sweepEval(t0, t1, t2, std.math.clamp(v_min_t, 0.0, 1.0));
    const v_max = sweepEval(t0, t1, t2, std.math.clamp(v_max_t, 0.0, 1.0));
    if (@max(v_min[0], v_max[0]) <= 0.0) return (v_max[1] - v_min[1]) * size[0];
    if (@min(v_min[0], v_max[0]) >= size[0]) return 0.0;
    const qa_x = t0[0] + t2[0] - 2.0 * t1[0];
    var h_min_t: f32 = 0;
    var h_max_t: f32 = 0;
    var h_check = if (delta[0] > 0.0) [4]f32{ t0[0], t2[0], 0.0, 0.0 } else [4]f32{ t2[0], t0[0], size[0], 1.0 };
    if (h_check[0] >= h_check[2]) {
        h_min_t = h_check[3];
    } else if (h_check[1] <= h_check[2]) {
        h_min_t = 1.0 - h_check[3];
    } else {
        h_min_t = sweepIntersect(qa_x, t0[0], t1[0], t2[0], h_check[2]);
    }
    h_check[2] = size[0] - h_check[2];
    if (h_check[0] >= h_check[2]) {
        h_max_t = h_check[3];
    } else if (h_check[1] <= h_check[2]) {
        h_max_t = 1.0 - h_check[3];
    } else {
        h_max_t = sweepIntersect(qa_x, t0[0], t1[0], t2[0], h_check[2]);
    }
    const min_t = std.math.clamp(@max(v_min_t, h_min_t), 0.0, 1.0);
    const max_t = std.math.clamp(@min(v_max_t, h_max_t), 0.0, 1.0);
    if (min_t >= max_t) return 0.0;
    const q0 = if (v_min_t >= h_min_t) v_min else sweepEval(t0, t1, t2, min_t);
    const q1 = if (v_max_t <= h_max_t) v_max else sweepEval(t0, t1, t2, max_t);
    var area: f32 = 0.0;
    const sgn_y: f32 = if (delta[1] > 0) 1 else -1;
    if (min_t > 0.0 and delta[0] > 0.0) {
        const h_: f32 = if (delta[1] > 0.0) q0[1] - @max(0.0, t0[1]) else @min(size[1], t0[1]) - q0[1];
        area += sgn_y * h_ * size[0];
    }
    if (max_t < 1.0 and delta[0] < 0.0) {
        const h_: f32 = if (delta[1] > 0.0) @min(size[1], t2[1]) - q1[1] else q1[1] - @max(0.0, t2[1]);
        area += sgn_y * h_ * size[0];
    }
    const h_trap = q1[1] - q0[1];
    const b_trap = size[0] - 0.5 * (q0[0] + q1[0]);
    area += b_trap * h_trap;
    return area;
}

/// Rasterize real glyph curves at a pixel; returns coverage.
fn glyphCoverage(curves: []const proto.Curve, curve_left: f32, curve_bottom: f32, curve_w: f32, curve_h: f32, px: [2]f32, win: [2]f32) f32 {
    // map pixel → curve space (the shader's uv mapping):
    // window size in curve units = win (curve_w/dst_w etc.), offset = pixel's curve pos
    const offset = [2]f32{ curve_left + curve_w * (px[0] + 0.5 - px[0]), curve_bottom + curve_h * (px[1] + 0.5 - px[1]) };
    _ = offset;
    // The shader: win_size = dFdx(vUv) = curve_w/dst_w; offset = vUv - 0.5*win_size.
    // For a pixel at curve position c: window = [c - win/2, c + win/2].

    var total: f32 = 0;
    for (curves) |cv| {
        total += sweepSegment(win, .{ curve_left + curve_w * px[0] / 200, curve_bottom + curve_h * px[1] / 200 }, .{ cv.p0x, cv.p0y }, .{ cv.p1x, cv.p1y }, .{ cv.p2x, cv.p2y });
    }
    return total / (win[0] * win[1]);
}

/// sRGB (0..1) → Oklab; alpha passes through. a/b may be negative.
/// L is in 0..1 (v4's color convention — never scaled by 100).
pub fn srgbToOklab(rgb: [4]f32) [4]f32 {
    const to_linear = struct {
        fn f(v: f32) f32 {
            if (v <= 0.04045) return v / 12.92;
            return std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
        }
    }.f;
    const r = to_linear(rgb[0]);
    const g = to_linear(rgb[1]);
    const b = to_linear(rgb[2]);

    // LMS cone response (standard Oklab matrix).
    const l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
    const m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
    const s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;

    const lp = std.math.cbrt(l);
    const mp = std.math.cbrt(m);
    const sp = std.math.cbrt(s);

    const L = 0.2104542553 * lp + 0.7936177850 * mp - 0.0040720468 * sp;
    const a = 1.9779984951 * lp - 2.4285922050 * mp + 0.4505937099 * sp;
    const bb = 0.0259040371 * lp + 0.7827717662 * mp - 0.8086757660 * sp;
    return .{ L, a, bb, rgb[3] };
}

// ─── Tests (pure only — GPU paths are smoke-verified by the orchestrator) ───

const testing = std.testing;

test "srgbToOklab: white → L=1, a=0, b=0" {
    const lab = srgbToOklab(.{ 1, 1, 1, 1 });
    try testing.expectApproxEqAbs(@as(f32, 1.0), lab[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), lab[1], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), lab[2], 0.0001);
    try testing.expectEqual(@as(f32, 1.0), lab[3]); // alpha passes through
}

test "srgbToOklab: black → L=0, a=0, b=0" {
    const lab = srgbToOklab(.{ 0, 0, 0, 0.5 });
    try testing.expectApproxEqAbs(@as(f32, 0.0), lab[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), lab[1], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), lab[2], 0.0001);
    try testing.expectEqual(@as(f32, 0.5), lab[3]); // alpha passes through
}

test "srgbToOklab: mid-gray sanity" {
    // Standard Oklab of sRGB (0.5, 0.5, 0.5) is L ≈ 0.598, a ≈ b ≈ 0
    // (verified against the standard matrix; the 0.5-0.55 estimate in the
    // port spec was slightly low).
    const lab = srgbToOklab(.{ 0.5, 0.5, 0.5, 1.0 });
    try testing.expect(lab[0] > 0.55 and lab[0] < 0.65);
    try testing.expectApproxEqAbs(@as(f32, 0.0), lab[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), lab[2], 0.001);
    try testing.expectEqual(@as(f32, 1.0), lab[3]);
}

test "glyph sweep: real 'n' curves give full coverage at stroke centers" {
    // Load the real font, extract 'n' at 20px, rasterize with the ported sweep.
    var ft_lib: c.FT_Library = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Init_FreeType(&ft_lib));
    defer _ = c.FT_Done_FreeType(ft_lib);
    const font_data = @embedFile("InterVariable.ttf");
    var face: c.FT_Face = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_New_Memory_Face(ft_lib, font_data.ptr, @intCast(font_data.len), 0, &face));
    defer _ = c.FT_Done_Face(face);
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Set_Pixel_Sizes(face, 0, 20));

    const n_idx = c.FT_Get_Char_Index(face, 'n');
    const h = c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed;
    const curves = try extractGlyphCurves(std.testing.allocator, .{ .handle = h }, n_idx);
    defer std.testing.allocator.free(curves);
    // curve extent
    var min_x: f32 = 1e9;
    var min_y: f32 = 1e9;
    var max_x: f32 = -1e9;
    var max_y: f32 = -1e9;
    for (curves) |cv| {
        min_x = @min(min_x, @min(@min(cv.p0x, cv.p1x), cv.p2x));
        min_y = @min(min_y, @min(@min(cv.p0y, cv.p1y), cv.p2y));
        max_x = @max(max_x, @max(@max(cv.p0x, cv.p1x), cv.p2x));
        max_y = @max(max_y, @max(@max(cv.p0y, cv.p1y), cv.p2y));
    }
    // rasterize the glyph cell at 1px per sample: window per pixel ≈ 1 curve unit.
    const win = [2]f32{ 1.0, 1.0 };
    var max_cov: f32 = 0;
    var ink: f32 = 0;
    var n: usize = 0;
    for (0..20) |row| {
        for (0..20) |col| {
            const px = [2]f32{ @floatFromInt(col), @floatFromInt(row) };
            const total: f32 = blk: {
                var t: f32 = 0;
                for (curves) |cv| {
                    t += sweepSegment(win, px, .{ cv.p0x - min_x, cv.p0y - min_y }, .{ cv.p1x - min_x, cv.p1y - min_y }, .{ cv.p2x - min_x, cv.p2y - min_y });
                }
                break :blk t;
            };
            const cov = total / (win[0] * win[1]);
            if (cov > max_cov) max_cov = cov;
            if (cov > 0.5) {
                ink += cov;
                n += 1;
            }
        }
    }
    // A 20px 'n' stem center must be nearly solid.
    try std.testing.expect(max_cov > 0.8);
    // Ink: a 20px 'n' covers ~45 px of stroke.
    try std.testing.expect(ink > 30);
}

test "shaping: the hb-ft font scale is 26.6 fixed-point pixels" {
    // Standalone FT + hb setup (no GPU): a shaped 'A' at 20px must advance
    // ~13px = 832 in 26.6 units — the shaper positions are /64.0 → px.
    var ft_lib: c.FT_Library = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Init_FreeType(&ft_lib));
    defer _ = c.FT_Done_FreeType(ft_lib);
    const font_data = @embedFile("InterVariable.ttf");
    var face: c.FT_Face = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_New_Memory_Face(ft_lib, font_data.ptr, @intCast(font_data.len), 0, &face));
    defer _ = c.FT_Done_Face(face);
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Set_Pixel_Sizes(face, 0, FONT_SIZE_PX));
    const handle = c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed;
    var font = hb.Font{ .handle = handle };
    defer font.destroy();

    var buf = try hb.Buffer.create();
    defer buf.destroy();
    buf.addUTF8("A");
    buf.setDirection(.ltr);
    buf.setScript(.latin);
    hb.shape(font, buf, null);
    const positions = buf.getGlyphPositions() orelse return error.NoPositions;
    try std.testing.expectEqual(@as(usize, 1), positions.len);
    // 20px Inter 'A': horiAdvance ≈ 13px → 26.6 units ≈ 800-900.
    try std.testing.expect(positions[0].x_advance > 700 and positions[0].x_advance < 1000);
}

test "shaping: kerned AV pair is narrower than the advance sum" {
    var ft_lib: c.FT_Library = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Init_FreeType(&ft_lib));
    defer _ = c.FT_Done_FreeType(ft_lib);
    const font_data = @embedFile("InterVariable.ttf");
    var face: c.FT_Face = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_New_Memory_Face(ft_lib, font_data.ptr, @intCast(font_data.len), 0, &face));
    defer _ = c.FT_Done_Face(face);
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Set_Pixel_Sizes(face, 0, FONT_SIZE_PX));
    const handle = c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed;
    var font = hb.Font{ .handle = handle };
    defer font.destroy();

    const width = struct {
        fn w(fnt: hb.Font, text: []const u8) !f32 {
            var buf = try hb.Buffer.create();
            defer buf.destroy();
            buf.addUTF8(text);
            buf.setDirection(.ltr);
            buf.setScript(.latin);
            hb.shape(fnt, buf, null);
            var total: f32 = 0;
            for (buf.getGlyphPositions() orelse &.{}) |p| total += @as(f32, @floatFromInt(p.x_advance)) / 64.0;
            return total;
        }
    }.w;

    const av = try width(font, "AV");
    const a = try width(font, "A");
    const v = try width(font, "V");
    // The classic AV pair is GPOS-kerned in Inter: AV < A + V.
    try std.testing.expect(av < a + v - 0.5);
    // H-H is not kerned: the shaped width equals the naive sum.
    const hh = try width(font, "HH");
    const h = try width(font, "H");
    try std.testing.expectApproxEqAbs(hh, h + h, 0.01);
}

test "shaping: invalid UTF-8 substitutes .notdef, never panics" {
    var ft_lib: c.FT_Library = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Init_FreeType(&ft_lib));
    defer _ = c.FT_Done_FreeType(ft_lib);
    const font_data = @embedFile("InterVariable.ttf");
    var face: c.FT_Face = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_New_Memory_Face(ft_lib, font_data.ptr, @intCast(font_data.len), 0, &face));
    defer _ = c.FT_Done_Face(face);
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Set_Pixel_Sizes(face, 0, FONT_SIZE_PX));
    const handle = c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed;
    var font = hb.Font{ .handle = handle };
    defer font.destroy();

    var buf = try hb.Buffer.create();
    defer buf.destroy();
    buf.addUTF8("a\xFF\xFEb");
    hb.shape(font, buf, null);
    const infos = buf.getGlyphInfos();
    // Every input byte maps to a glyph (2 .notdef for the invalid pair);
    // the run stays bounded.
    try std.testing.expect(infos.len == 3 or infos.len == 4);
}

test "shaping: the kern feature applies GPOS pair adjustments in px" {
    // hb-ft runs with FT_LOAD_NO_HINTING: advances, extents and outlines
    // are the UNHINTED (true) values in the 26.6-px hb scale — consistent
    // with the shaped positions. The old pipeline mixed the shaper's
    // unhinted advances with the HINTED FT metrics, which is what made
    // "reset" look unevenly spaced.
    var ft_lib: c.FT_Library = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Init_FreeType(&ft_lib));
    defer _ = c.FT_Done_FreeType(ft_lib);
    const font_data = @embedFile("InterVariable.ttf");
    var face: c.FT_Face = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_New_Memory_Face(ft_lib, font_data.ptr, @intCast(font_data.len), 0, &face));
    defer _ = c.FT_Done_Face(face);
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Set_Pixel_Sizes(face, 0, FONT_SIZE_PX));
    const handle = c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed;
    var font = hb.Font{ .handle = handle };
    defer font.destroy();

    const kern_off = [_]hb.Feature{.{ .tag = 0x6b65726e, .value = 0, .start = 0, .end = std.math.maxInt(c_uint) }};

    const width = struct {
        fn w(fnt: hb.Font, text: []const u8, features: ?[]const hb.Feature) !f32 {
            var buf = try hb.Buffer.create();
            defer buf.destroy();
            buf.addUTF8(text);
            buf.setDirection(.ltr);
            buf.setScript(.latin);
            hb.shape(fnt, buf, features);
            var total: f32 = 0;
            for (buf.getGlyphPositions() orelse &.{}) |p| total += @as(f32, @floatFromInt(p.x_advance)) / 64.0;
            return total;
        }
    }.w;

    // The classic AV pair tightens by the font's real GPOS value.
    const av = try width(font, "AV", null);
    const av_off = try width(font, "AV", &kern_off);
    try std.testing.expect(av < av_off - 0.3);

    // Inter has NO s->e GPOS pair: the kern feature changes nothing.
    // ("res et" was a hinting artifact of the old pipeline, not kerning.)
    const se = try width(font, "se", null);
    const se_off = try width(font, "se", &kern_off);
    try std.testing.expectApproxEqAbs(se, se_off, 0.01);

    // The base advances are the UNHINTED ones — they differ from the
    // hinted FT metrics the old pipeline used for the bitmaps.
    const s_gid = c.FT_Get_Char_Index(face, 's');
    const e_gid = c.FT_Get_Char_Index(face, 'e');
    const s_adv = @as(f32, @floatFromInt(c.hb_font_get_glyph_h_advance(handle, s_gid))) / 64.0;
    const e_adv = @as(f32, @floatFromInt(c.hb_font_get_glyph_h_advance(handle, e_gid))) / 64.0;
    try std.testing.expectApproxEqAbs(se_off, s_adv + e_adv, 0.01);
    _ = c.FT_Load_Glyph(face, s_gid, c.FT_LOAD_DEFAULT);
    const ft_hinted = @as(f32, @floatFromInt(face.*.glyph.*.metrics.horiAdvance)) / 64.0;
    try std.testing.expect(@abs(s_adv - ft_hinted) > 0.1); // unhinted ≠ hinted
}
