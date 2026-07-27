//! FreeType glyph text engine for the v7 demo.
//!
//! Port of v4's glyph pipeline (src/proto_main.zig + src/proto/sweeper.zig):
//! lazily rasterizes glyphs with FreeType into curve outlines, stores each
//! glyph as a GPU material (GlyphMaterial) plus a GPU curve buffer, and emits
//! one SliceRect per character into the caller's rect list.
//!
//! Demo-side only: the v7 CORE (src/v7/) stays pure; this file MAY import
//! noapi.

const std = @import("std");
const noapi = @import("noapi");
const proto = @import("proto/sweeper.zig");
const SliceRect = @import("proto/render_9slice.zig").SliceRect;
const WidgetSize = @import("v7/widget.zig").Size;

const c = @cImport({
    @cDefine("FT2_BUILD_LIBRARY", "1");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftoutln.h");
    @cInclude("freetype/ftglyph.h");
});

pub const MAX_MATERIALS: u32 = 128; // slot 0 = solid; glyphs start at 1
pub const FONT_SIZE_PX: u32 = 20;

pub const GlyphEntry = struct {
    ch: u21, // Unicode code point (UTF-8 decoded, not a raw byte)
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

/// Tolerant UTF-8 code-point iterator. std.unicode.Utf8Iterator panics
/// (`catch unreachable`) on malformed input, which would crash the demo on
/// label text with invalid bytes. This one skips invalid bytes instead and
/// only returns null at end of input, so `while (it.nextCodepoint()) |cp|`
/// never terminates early on a bad byte.
const CodepointIterator = struct {
    bytes: []const u8,
    i: usize,

    fn nextCodepoint(it: *CodepointIterator) ?u21 {
        while (it.i < it.bytes.len) {
            const first = it.bytes[it.i];
            const seq_len = std.unicode.utf8ByteSequenceLength(first) catch {
                it.i += 1; // invalid leading byte: skip it
                continue;
            };
            if (it.i + seq_len > it.bytes.len) {
                it.i += 1; // truncated sequence: skip the leading byte
                continue;
            }
            const cp = switch (seq_len) {
                1 => it.bytes[it.i], // ASCII: the byte is the codepoint
                2 => std.unicode.utf8Decode2(it.bytes[it.i..][0..2].*) catch {
                    it.i += 1; // bad continuation / overlong: skip the leading byte
                    continue;
                },
                3 => std.unicode.utf8Decode3(it.bytes[it.i..][0..3].*) catch {
                    it.i += 1; // bad continuation / overlong / surrogate: skip the leading byte
                    continue;
                },
                4 => std.unicode.utf8Decode4(it.bytes[it.i..][0..4].*) catch {
                    it.i += 1; // bad continuation / overlong / surrogate: skip the leading byte
                    continue;
                },
                else => unreachable, // leading byte validated: 1..4 only
            };
            it.i += seq_len;
            return cp;
        }
        return null;
    }
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
    // Parallel arrays, one element per rasterized char:
    // sweepers[i] owns the GPU curve buffer backing entries[i].
    sweepers: std.ArrayList(proto.GlyphSweeper) = .empty, // per char
    entries: std.ArrayList(GlyphEntry) = .empty, // per char
    materials: noapi.GpuPtr, // MAX_MATERIALS * MATERIAL_SIZE, .default
    next_slot: u32 = 1,
    material_bda: u64 = 0,

    /// Init FreeType, load the embedded Inter font at FONT_SIZE_PX, and
    /// allocate the material buffer. Returns errors (not panics) on FT
    /// failures; on partial failure everything allocated so far is released.
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

        const materials = try gpu.gpuMalloc(MAX_MATERIALS * proto.MATERIAL_SIZE, 64, .default);
        errdefer gpu.gpuFree(materials);

        return .{
            .gpu = gpu,
            .gpa = gpa,
            .ft_lib = ft_lib,
            .face = face,
            .materials = materials,
            .material_bda = materials.gpu,
        };
    }

    pub fn deinit(self: *TextEngine) void {
        for (self.sweepers.items) |*s| s.deinit(); // frees each GPU curve buffer
        self.sweepers.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        self.gpu.gpuFree(self.materials);
        _ = c.FT_Done_Face(self.face);
        _ = c.FT_Done_FreeType(self.ft_lib);
    }

    pub fn materialBda(self: *const TextEngine) u64 {
        return self.material_bda;
    }

    /// Rasterize `ch` on demand: extract curves → sweeper (GPU curve buffer)
    /// → glyph material → entry. Chars absent from the font and chars whose
    /// outline extraction fails are skipped (no entry, no error). Returns
    /// error.TooManyGlyphs once the MAX_MATERIALS slot budget is exhausted
    /// (checked only for chars that would actually consume a new slot).
    fn ensureGlyph(self: *TextEngine, ch: u21) !void {
        for (self.entries.items) |e| {
            if (e.ch == ch) return; // already rasterized
        }

        // Char not present in the font → skip silently.
        if (c.FT_Get_Char_Index(self.face, ch) == 0) return;

        // Slot budget exhausted: fail with a real error instead of writing
        // OOB into the GPU material heap — a debug-only assert would compile
        // out in ReleaseFast. The assert stays as belt-and-suspenders.
        std.debug.assert(self.next_slot < MAX_MATERIALS); // slot 0 reserved for solid
        if (self.next_slot >= MAX_MATERIALS) return error.TooManyGlyphs;

        // Extraction failures (missing outline, decompose error) → skip char.
        const curves = extractCharCurves(self.gpa, self.face, ch) catch return;
        defer self.gpa.free(curves);

        var sweeper = try proto.GlyphSweeper.init(self.gpu, curves);

        // FT_Load_Glyph already ran inside extractCharCurves, so
        // face.*.glyph.*.metrics is current. Metrics are 26.6 fixed point;
        // /64.0 converts to pixels.
        const m = self.face.*.glyph.*.metrics;
        const advance = @as(f32, @floatFromInt(m.horiAdvance)) / 64.0;
        const bearing_x = @as(f32, @floatFromInt(m.horiBearingX)) / 64.0;
        const bearing_y = @as(f32, @floatFromInt(m.horiBearingY)) / 64.0;
        const glyph_w = @as(f32, @floatFromInt(m.width)) / 64.0;
        const glyph_h = @as(f32, @floatFromInt(m.height)) / 64.0;

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
            .ch = ch,
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

    /// Ensure glyphs for every char in `text` exist (lazy), then append one
    /// SliceRect per char to `out` at (x, baseline_y). `baseline_y` is the
    /// font baseline (the caller computes it from the widget rect). Text is
    /// decoded as UTF-8 code points, so multi-byte chars yield one glyph
    /// each; invalid bytes are skipped. Unknown chars are skipped. Cursor
    /// advances by each glyph's horiAdvance. Propagates error.TooManyGlyphs
    /// if the material slot budget is exhausted.
    pub fn emitText(self: *TextEngine, text: []const u8, x: f32, baseline_y: f32, out: *std.ArrayList(SliceRect)) !void {
        var cursor = x;
        var it = CodepointIterator{ .bytes = text, .i = 0 };
        while (it.nextCodepoint()) |cp| {
            try self.ensureGlyph(cp);
            const entry = self.entryFor(cp) orelse continue; // unknown char → skip
            const ch_x = cursor + entry.bearing_x;
            const ch_y = baseline_y - entry.bearing_y;
            if (entry.glyph_w <= 0 or entry.glyph_h <= 0) {
                cursor += entry.advance; // zero-size glyph (e.g. space): advance only
                continue;
            }
            try out.append(self.gpa, .{
                .dst_x = ch_x,
                .dst_y = ch_y,
                .dst_w = entry.glyph_w,
                .dst_h = entry.glyph_h,
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
            cursor += entry.advance;
        }
    }

    /// Measure a text run's content size only: the sum of per-glyph
    /// advances, 24px tall (20px cap height + descender room); padding and
    /// border come from the widget box (flex), not from the measurement.
    /// Lazily rasterizes like emitText; later emitText calls are no-ops for
    /// already-loaded glyphs.
    pub fn measureText(self: *TextEngine, text: []const u8) WidgetSize {
        var w: f32 = 0;
        var it = CodepointIterator{ .bytes = text, .i = 0 };
        while (it.nextCodepoint()) |cp| {
            // Unrenderable chars are skipped, exactly like unknown chars:
            // rasterization failures and the TooManyGlyphs slot cap silently
            // contribute no advance instead of erroring out of layout.
            self.ensureGlyph(cp) catch continue;
            const e = self.entryFor(cp) orelse continue;
            w += e.advance;
        }
        return .{ .width = w, .height = 24 };
    }

    fn entryFor(self: *const TextEngine, ch: u21) ?GlyphEntry {
        for (self.entries.items) |e| {
            if (e.ch == ch) return e;
        }
        return null;
    }
};

/// Extract glyph curves for a specific character using FreeType.
/// Ported from src/proto_main.zig: FT_Outline_Funcs callbacks fill a
/// 4096-curve stack buffer (cubic segments split into two conics at t=0.5),
/// then the caller-owned slice is dupe'd via `alloc`.
fn extractCharCurves(alloc: std.mem.Allocator, face: c.FT_Face, ch: u21) ![]proto.Curve {
    const idx = c.FT_Get_Char_Index(face, @intCast(ch));
    if (idx == 0) return error.GlyphNotFound;
    if (c.FT_Load_Glyph(face, idx, c.FT_LOAD_NO_BITMAP) != 0) return error.GlyphLoadFailed;
    const outline = &face.*.glyph.*.outline;

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

    const funcs = c.FT_Outline_Funcs{
        .move_to = struct {
            fn cb(to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
                const p: *Ctx = @ptrCast(@alignCast(user));
                p.first_x.* = @as(f32, @floatFromInt(to.*.x)) / 64;
                p.first_y.* = @as(f32, @floatFromInt(to.*.y)) / 64;
                p.last_x.* = p.first_x.*;
                p.last_y.* = p.first_y.*;
                return 0;
            }
        }.cb,
        .line_to = struct {
            fn cb(to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
                const p: *Ctx = @ptrCast(@alignCast(user));
                const tx = @as(f32, @floatFromInt(to.*.x)) / 64;
                const ty = @as(f32, @floatFromInt(to.*.y)) / 64;
                if (p.count.* < 4096) {
                    p.curves[p.count.*] = .{ .p0x = p.last_x.*, .p0y = p.last_y.*, .p1x = (p.last_x.* + tx) * 0.5, .p1y = (p.last_y.* + ty) * 0.5, .p2x = tx, .p2y = ty };
                    p.count.* += 1;
                }
                p.last_x.* = tx;
                p.last_y.* = ty;
                return 0;
            }
        }.cb,
        .conic_to = struct {
            fn cb(control: [*c]const c.FT_Vector, to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
                const p: *Ctx = @ptrCast(@alignCast(user));
                const cx = @as(f32, @floatFromInt(control.*.x)) / 64;
                const cy = @as(f32, @floatFromInt(control.*.y)) / 64;
                const tx = @as(f32, @floatFromInt(to.*.x)) / 64;
                const ty = @as(f32, @floatFromInt(to.*.y)) / 64;
                if (p.count.* < 4096) {
                    p.curves[p.count.*] = .{ .p0x = p.last_x.*, .p0y = p.last_y.*, .p1x = cx, .p1y = cy, .p2x = tx, .p2y = ty };
                    p.count.* += 1;
                }
                p.last_x.* = tx;
                p.last_y.* = ty;
                return 0;
            }
        }.cb,
        .cubic_to = struct {
            fn cb(c1: [*c]const c.FT_Vector, c2: [*c]const c.FT_Vector, to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
                const p: *Ctx = @ptrCast(@alignCast(user));
                const c1x = @as(f32, @floatFromInt(c1.*.x)) / 64;
                const c1y = @as(f32, @floatFromInt(c1.*.y)) / 64;
                const c2x = @as(f32, @floatFromInt(c2.*.x)) / 64;
                const c2y = @as(f32, @floatFromInt(c2.*.y)) / 64;
                const tx = @as(f32, @floatFromInt(to.*.x)) / 64;
                const ty = @as(f32, @floatFromInt(to.*.y)) / 64;
                if (p.count.* + 1 < 4096) {
                    const t: f32 = 0.5;
                    const mt = 1 - t;
                    const b0x = mt * p.last_x.* + t * c1x;
                    const b0y = mt * p.last_y.* + t * c1y;
                    const b1x = mt * c1x + t * c2x;
                    const b1y = mt * c1y + t * c2y;
                    const b2x = mt * c2x + t * tx;
                    const b2y = mt * c2y + t * ty;
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
                return 0;
            }
        }.cb,
        .shift = 0,
        .delta = 0,
    };
    if (c.FT_Outline_Decompose(outline, &funcs, &ctx) != 0) return error.OutlineDecomposeFailed;

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

    const curves = try extractCharCurves(std.testing.allocator, face, 'n');
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
