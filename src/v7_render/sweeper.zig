//! Scanline sweeper — per-glyph curve data and GPU material.
//! GlyphMaterial is written to a GPU buffer and referenced by
//! the quad fragment shader via material_idx + BDA push constant.
//!
//! Active v7 renderer primitive.

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

/// One edge of the stroke's offset-outline polygon (the mode-2 type_stroke
/// reference): a straight segment (x0,y0) -> (x1,y1) in the sweep space.
/// The GPU buffer layout is the shader's Edge/EdgeBuf: a u32 count + u32
/// pad header, then 16-byte Edges. (The SvgView aliases this type for its
/// stroke edge buffers.)
pub const StrokeEdge = extern struct { x0: f32, y0: f32, x1: f32, y1: f32 };

/// GPU material for glyph rendering. Written into material buffer.
/// Layout matches GLSL GlyphMaterial (int + 6×float + 2×uint64_t + vec4,
/// 56 bytes): type @0, bearing_y/curve_w/curve_h/win_w/win_h @4..24,
/// curve_bda @24 (8B → 32), band_bda @32 (8B → 40), gradient_to @40 (16B
/// → 56). The implicit padding is identical in the shader copy.
pub const GlyphMaterial = extern struct {
    type: u32, // 0=SOLID, 1=GLYPH, 2=ROUNDED_RECT, 3=SHADOW, 4=STROKE, 5=SWEEP
    bearing_y: f32, // FreeType bearing Y / corner radius / border / feather
    curve_w: f32, // glyph extent / x radius
    curve_h: f32, // glyph extent / y radius
    win_w: f32, // pixel window width / rect width
    win_h: f32, // pixel window height / rect height
    curve_bda: u64, // BDA to curve buffer (0 for rounded/shadow)
    /// BDA to the path's fill-band buffer (the type_sweep optimization:
    /// the interior box + the per-pixel-row curve runs); 0 = no band
    /// data → the fragment sweeps the full curve loop.
    band_bda: u64 = 0,
    /// Gradient bottom color (Oklab); all-zero = flat fill. The vertex
    /// color is the gradient's top.
    gradient_to: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const material_size = @sizeOf(GlyphMaterial); // 56 bytes

pub const type_solid: u32 = 0;
pub const type_glyph: u32 = 1;
pub const type_rounded_rect: u32 = 2;
pub const type_shadow: u32 = 3;
pub const type_stroke: u32 = 4; // a path stroked at width bearing_y (the distance branch)
pub const type_sweep: u32 = 5; // an SVG fill: the SDF-based sweep AA (no subpixel)

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

    pub fn init(gpu: *noapi.Gpu, curves: []const Curve) !GlyphSweeper {
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

    pub fn deinit(self: *GlyphSweeper) void {
        self.gpu.gpuFree(self.curve_buf);
        self.* = undefined;
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
        const mat: GlyphMaterial = .{
            .type = 1,
            .bearing_y = bearing_y,
            .curve_w = curve_w,
            .curve_h = curve_h,
            .win_w = win_w,
            .win_h = win_h,
            .curve_bda = curve_bda,
            .band_bda = 0,
        };
        const offset = slot * material_size;
        const dst: [*]u8 = @ptrCast(@alignCast(material_buf.cpu));
        @as(*GlyphMaterial, @ptrCast(@alignCast(dst + offset))).* = mat;
    }

    /// Write a stroke material (type 4): the same curve BDA as the fill,
    /// with the stroke width in bearing_y (user units; the SvgView scales
    /// it with the view). The fragment's type_stroke branch computes the
    /// distance to the curves instead of the sweep coverage.
    pub fn writeStrokeMaterial(
        curve_bda: u64,
        material_buf: noapi.GpuPtr,
        slot: u32,
        width: f32,
    ) void {
        const mat: GlyphMaterial = .{
            .type = type_stroke,
            .bearing_y = width,
            .curve_w = 0,
            .curve_h = 0,
            .win_w = 0,
            .win_h = 0,
            .curve_bda = curve_bda,
            .band_bda = 0,
        };
        const offset = slot * material_size;
        const dst: [*]u8 = @ptrCast(@alignCast(material_buf.cpu));
        @as(*GlyphMaterial, @ptrCast(@alignCast(dst + offset))).* = mat;
    }

    /// Write an SVG fill material (type 5): the same curve BDA + extent
    /// as type_glyph, but the fragment uses the SDF-based sweep AA (the
    /// fwidth band + gamma) and — crucially — NOT the subpixel branch:
    /// the tiger's colored fills must never be RGB-striped. The text's
    /// glyphs keep type_glyph, so the two render independently.
    /// `band_bda` points at the path's fill-band buffer (the interior
    /// box + the per-row curve runs — see buildFillBands); 0 = no band
    /// data → the fragment sweeps the full curve loop.
    pub fn writeSweepMaterial(
        curve_bda: u64,
        band_bda: u64,
        material_buf: noapi.GpuPtr,
        slot: u32,
        curve_w: f32,
        curve_h: f32,
    ) void {
        const mat: GlyphMaterial = .{
            .type = type_sweep,
            .bearing_y = 0,
            .curve_w = curve_w,
            .curve_h = curve_h,
            .win_w = curve_w,
            .win_h = curve_h,
            .curve_bda = curve_bda,
            .band_bda = band_bda,
        };
        const offset = slot * material_size;
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
        const mat: GlyphMaterial = .{
            .type = type_rounded_rect,
            .bearing_y = border,
            .curve_w = x_radius,
            .curve_h = y_radius,
            .win_w = rect_w,
            .win_h = rect_h,
            .curve_bda = 0,
            .band_bda = 0,
            .gradient_to = gradient_to,
        };
        const offset = slot * material_size;
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
        const mat: GlyphMaterial = .{
            .type = type_shadow,
            .bearing_y = feather,
            .curve_w = x_radius,
            .curve_h = y_radius,
            .win_w = rect_w,
            .win_h = rect_h,
            .curve_bda = 0,
            .band_bda = 0,
        };
        const offset = slot * material_size;
        const dst: [*]u8 = @ptrCast(@alignCast(material_buf.cpu));
        @as(*GlyphMaterial, @ptrCast(@alignCast(dst + offset))).* = mat;
    }
};

// ─── The fill-band optimization (type_sweep) ─────────────────
// The per-path band buffer holds (1) a conservative interior box — the
// pixels whose whole 2x2 sweep window is inside the shape render at full
// coverage without sweeping any curve — and (2) per-pixel-row runs of the
// curve indices the row's fragments can actually see, so a fragment
// sweeps a handful of curves instead of all n. Both are built by pure
// CPU functions here (buildFillBands — no GPU) and serialized into a GPU
// buffer by the SvgView at setScale (the bands live in the scaled sweep
// space like the curves).

/// The epsilon margin the interior-rect shrink keeps past every curve
/// hull (curve units). The rect's sides are pulled INWARD past the hulls
/// by at least this much, so no curve can touch the rect's boundary: a
/// degenerate hull (a straight line) has zero thickness and would sit
/// exactly ON the rect edge, where a boundary window would still include
/// its area — breaking the interior early-out.
const band_eps: f32 = 1e-3;

/// The axis-aligned hull (bbox) of a quadratic's three control points.
/// The curve itself lies inside this hull, so a hull disjoint from a box
/// means the curve cannot cross the box.
fn hullOf(c: Curve) [4]f32 {
    return .{
        @min(@min(c.p0x, c.p1x), c.p2x),
        @min(@min(c.p0y, c.p1y), c.p2y),
        @max(@max(c.p0x, c.p1x), c.p2x),
        @max(@max(c.p0y, c.p1y), c.p2y),
    };
}

/// The CPU winding of a curve set at (x, y) — the nonzero fill rule, the
/// same math the sweep uses: each curve's y-crossing with the horizontal
/// line through the point solved by the quadratic formula (the linear
/// case for the degenerate lines), the crossing counted when it lies
/// right of the point (+x ray), with the crossing direction = the sign
/// of delta.y like sweepSegment. 0 = outside.
fn windingAt(curves: []const Curve, x: f32, y: f32) i32 {
    var w: i32 = 0;
    for (curves) |c| {
        const sgn: i32 = if (c.p2y - c.p0y > 0) 1 else -1;
        const qa = c.p0y + c.p2y - 2.0 * c.p1y;
        if (@abs(qa) < 1e-3) {
            // Linear in y (a line curve, or a curve whose y is collinear):
            // one crossing at t = (y - p0y) / (p2y - p0y).
            const denom = c.p2y - c.p0y;
            if (denom == 0) continue; // horizontal: no crossing
            const t = (y - c.p0y) / denom;
            if (t <= 0 or t >= 1) continue;
            const mt = 1 - t;
            const px = mt * mt * c.p0x + 2.0 * mt * t * c.p1x + t * t * c.p2x;
            if (px > x) w += sgn;
            continue;
        }
        // The two y-roots of qa·t² + qb·t + qc = 0 (qc = p0y - y); count
        // every crossing in (0, 1) — the pipeline's y-monotonic split
        // keeps it to at most one, but this stays correct regardless.
        const qb = 2.0 * (c.p1y - c.p0y);
        const qc = c.p0y - y;
        const d = qb * qb - 4.0 * qa * qc;
        if (d < 0) continue;
        const sd = @sqrt(d);
        const inv_2a = 0.5 / qa;
        const t0 = (-qb - sd) * inv_2a;
        const t1 = (-qb + sd) * inv_2a;
        if (t0 > 0 and t0 < 1) {
            const mt = 1 - t0;
            const px = mt * mt * c.p0x + 2.0 * mt * t0 * c.p1x + t0 * t0 * c.p2x;
            if (px > x) w += sgn;
        }
        if (t1 > 0 and t1 < 1) {
            const mt = 1 - t1;
            const px = mt * mt * c.p0x + 2.0 * mt * t1 * c.p1x + t1 * t1 * c.p2x;
            if (px > x) w += sgn;
        }
    }
    return w;
}

/// The conservative interior box of a curve set: the AABB of the control
/// points, shrunk by a fixed point over the curve hulls (at most n+2
/// passes — each side's value comes from a finite set, so the iteration
/// converges). Each pass pulls a side inward past every hull that pokes
/// through exactly one side of that axis (hulls spanning the full axis
/// are separated on the other one); hulls fully inside the rect (holes,
/// self-intersections) can never be excluded and fail the verification
/// below. Returns null when no valid interior exists.
///
/// The result is verified before it is trusted: (a) no curve hull may
/// intersect the final rect (strict — the eps pulls left a margin, so a
/// hit here means a curve actually crosses the rect, and the winding
/// would not be constant inside it); (b) the winding at the rect's
/// center must be nonzero — the shader takes |total|, so any nonzero
/// winding renders at full coverage (the contract's == 1 is a special
/// case; -1 and the overlapping-subpath ±2, ±3, … are equally valid).
fn interiorRect(curves: []const Curve) ?[4]f32 {
    if (curves.len == 0) return null;
    var x0 = curves[0].p0x;
    var y0 = curves[0].p0y;
    var x1 = curves[0].p0x;
    var y1 = curves[0].p0y;
    for (curves) |c| {
        const h = hullOf(c);
        x0 = @min(x0, h[0]);
        y0 = @min(y0, h[1]);
        x1 = @max(x1, h[2]);
        y1 = @max(y1, h[3]);
    }
    for (0..curves.len + 2) |_| {
        var changed = false;
        for (curves) |c| {
            const h = hullOf(c);
            const hx0 = h[0];
            const hy0 = h[1];
            const hx1 = h[2];
            const hy1 = h[3];
            // Loose intersection with the current rect (touching counts —
            // a degenerate hull sits exactly on the boundary).
            if (hx1 < x0 or hx0 > x1 or hy1 < y0 or hy0 > y1) continue;
            const pokes_left = hx0 <= x0;
            const pokes_right = hx1 >= x1;
            if (pokes_left and !pokes_right) {
                x0 = @max(x0, hx1 + band_eps);
                changed = true;
            } else if (pokes_right and !pokes_left) {
                x1 = @min(x1, hx0 - band_eps);
                changed = true;
            } else {
                // The hull spans the rect's full x-range (or sits inside
                // it): it must be separated on y instead.
                const pokes_bottom = hy0 <= y0;
                const pokes_top = hy1 >= y1;
                if (pokes_bottom and !pokes_top) {
                    y0 = @max(y0, hy1 + band_eps);
                    changed = true;
                } else if (pokes_top and !pokes_bottom) {
                    y1 = @min(y1, hy0 - band_eps);
                    changed = true;
                }
            }
        }
        if (!changed) break;
    }
    if (x0 >= x1 or y0 >= y1) return null; // empty/inverted: no interior
    for (curves) |c| {
        const h = hullOf(c);
        if (h[2] > x0 and h[0] < x1 and h[3] > y0 and h[1] < y1) return null;
    }
    const cx = 0.5 * (x0 + x1);
    const cy = 0.5 * (y0 + y1);
    if (windingAt(curves, cx, cy) == 0) return null;
    return .{ x0, y0, x1 - x0, y1 - y0 };
}

/// The per-path fill-band layout (built by buildFillBands, serialized
/// into a GPU buffer by the SvgView):
///   header 32B: float4 interior @0 (x0,y0,w,h — w<=0 or h<=0 disables
///     the interior early-out), i32 row_base @16, u32 row_count @20,
///     u32 pairs_base @24, u32 indices_base @28 (u32 offsets into the
///     same buffer),
///   then row_count (offset, count) u32 pairs at pairs_base,
///   then the concatenated curve indices at indices_base.
/// The shader maps the fragment's pixel row to `row = floor(cell.y) -
/// row_base` and sweeps only the run's curves.
pub const FillBands = struct {
    /// x0, y0, w, h in the curves' space; w <= 0 or h <= 0 = disabled.
    interior: [4]f32,
    /// The first band row (the shader's row = floor(cell.y) - row_base).
    row_base: i32,
    row_count: u32,
    /// 2 * row_count u32s: per row, (offset, count) — offset into
    /// `indices`.
    pairs: []u32,
    /// The concatenated curve indices per row, ascending curve order
    /// (the shader sums the same floats in the same order as the full
    /// loop, so the banded coverage is bit-identical).
    indices: []u32,
};

/// Build the per-row curve runs + the interior box for a fill path. The
/// bands' rows are the integer pixel rows (in the curves' space) where a
/// curve's y-span can overlap the sweep window of a fragment in that
/// row: a fragment with floor(cell.y) == r sweeps the window
/// [cell.y - 0.5, cell.y + 1.5) with cell.y in [r, r + 1), so the union
/// over the row is [r - 0.5, r + 2.5) — a curve participates in row r
/// iff min(p0.y, p2.y) < r + 2.5 AND max(p0.y, p2.y) > r - 0.5. This is
/// the exact sweepSegment first-line predicate at cell.y == r (modulo
/// the floor on the upper edge) — a SUPERSET of the contributing curves
/// for any fragment in the row, which is what the shader needs: every
/// curve that can contribute non-zero is in the run, and the extra
/// zero-contributors are harmless (the sums stay bit-identical; the
/// indices are appended in ascending curve order).
pub fn buildFillBands(a: std.mem.Allocator, curves: []const Curve) !FillBands {
    const interior = interiorRect(curves) orelse .{ 0, 0, -1, -1 };
    var row_min: i32 = std.math.maxInt(i32);
    var row_max: i32 = std.math.minInt(i32);
    for (curves) |c| {
        const lo = @min(c.p0y, c.p2y);
        const hi = @max(c.p0y, c.p2y);
        row_min = @min(row_min, @as(i32, @intFromFloat(@floor(lo - 2.5))) + 1);
        row_max = @max(row_max, @as(i32, @intFromFloat(@floor(hi + 0.5))));
    }
    if (row_min > row_max) {
        // No curve participates in any row (an empty set): no band data.
        const pairs = try a.alloc(u32, 0);
        errdefer a.free(pairs);
        const indices = try a.alloc(u32, 0);
        errdefer a.free(indices);
        return .{
            .interior = interior,
            .row_base = 0,
            .row_count = 0,
            .pairs = pairs,
            .indices = indices,
        };
    }
    const row_count: u32 = @intCast(row_max - row_min + 1);
    const counts = try a.alloc(u32, row_count);
    defer a.free(counts);
    @memset(counts, 0);
    for (curves) |c| {
        const lo = @min(c.p0y, c.p2y);
        const hi = @max(c.p0y, c.p2y);
        const r0 = @as(i32, @intFromFloat(@floor(lo - 2.5))) + 1;
        const r1: i32 = @intFromFloat(@floor(hi + 0.5));
        const r0i: usize = @intCast(r0 - row_min);
        const r1i: usize = @intCast(r1 - row_min);
        for (r0i..r1i + 1) |ri| counts[ri] += 1;
    }
    const pairs = try a.alloc(u32, 2 * row_count);
    // `counts` is released by its unconditional defer. `pairs` is a
    // separate allocation whose ownership transfers in the successful
    // return and is released here only if a later allocation fails.
    errdefer a.free(pairs);
    var total: u32 = 0;
    for (0..row_count) |i| {
        pairs[2 * i] = total;
        pairs[2 * i + 1] = counts[i];
        total += counts[i];
    }
    const indices = try a.alloc(u32, total);
    errdefer a.free(indices);
    // Fill the runs in curve order → every row's indices stay ascending.
    const cursor = try a.alloc(u32, row_count);
    defer a.free(cursor);
    for (0..row_count) |i| cursor[i] = pairs[2 * i];
    for (curves, 0..) |c, ci| {
        const lo = @min(c.p0y, c.p2y);
        const hi = @max(c.p0y, c.p2y);
        const r0 = @as(i32, @intFromFloat(@floor(lo - 2.5))) + 1;
        const r1: i32 = @intFromFloat(@floor(hi + 0.5));
        const r0i: usize = @intCast(r0 - row_min);
        const r1i: usize = @intCast(r1 - row_min);
        for (r0i..r1i + 1) |ri| {
            indices[cursor[ri]] = @intCast(ci);
            cursor[ri] += 1;
        }
    }
    return .{
        .interior = interior,
        .row_base = row_min,
        .row_count = row_count,
        .pairs = pairs,
        .indices = indices,
    };
}

// ─── The stroke-band optimization (type_stroke mode 2) ─────────────────
// The mode-2 stroke integrates the offset-outline polygon's edges over
// the pixel via Cairo's running-cover model. Like the fill bands, the
// per-path band buffer holds per-pixel-row runs of the EDGE indices, so
// a fragment accumulates a handful of edges instead of all n. Built by
// the pure buildStrokeBands (no GPU) and serialized into a GPU buffer by
// the SvgView at setScale (the bands live in the scaled sweep space like
// the scaled edges).

/// The per-path stroke-band layout (built by buildStrokeBands, serialized
/// into a GPU buffer by the SvgView — the SAME 32-byte header as the fill
/// bands):
///   header 32B: float4 interior @0 (always {0,0,-1,-1} — the stroke
///     band has NO interior early-out), i32 row_base @16, u32 row_count
///     @20, u32 pairs_base @24, u32 indices_base @28 (u32 offsets into
///     the same buffer),
///   then row_count (offset, count) u32 pairs at pairs_base,
///   then the concatenated u32 edge indices at indices_base.
pub const StrokeBands = struct {
    /// Always {0, 0, -1, -1}: the shader's stroke branch has no interior
    /// early-out, so w <= 0 keeps it disabled by construction.
    interior: [4]f32,
    /// The first band row (the shader's row = int(floor(py)) - row_base,
    /// with py the pixel's integration-window bottom).
    row_base: i32,
    row_count: u32,
    /// 2 * row_count u32s: per row, (offset, count) — offset into
    /// `indices`.
    pairs: []u32,
    /// The concatenated edge indices per row, ascending edge order (the
    /// shader accumulates the same floats in the same order as the full
    /// loop, so the banded coverage is bit-identical).
    indices: []u32,
};

/// Build the per-row edge runs for a stroke path. The bands' rows are the
/// integer pixel rows of the fragment's sweep coordinate: the shader maps
/// the fragment to row = int(floor(py)) - row_base, where py is the
/// integration window's bottom and the mode-2 loop integrates over the
/// 1x1 window [py, py + 1). An edge with y-span [ymin, ymax] participates
/// in row r iff its span overlaps the row's WINDOW UNION
/// [r, r + 1 + window) (window = 1.0 for the stroke): ymin < r + 1 +
/// window AND ymax > r — equivalently r in [floor(ymin - window),
/// ceil(ymax) - 1]. This is the SUPERSET of the edges that pass the
/// shader's y-clip (ymax <= py || ymin >= py + 1.0) for any fragment in
/// the row, which is exactly what bit-identity needs: every edge that can
/// contribute non-zero is in the run, and every edge the run excludes
/// fails the clip for ALL py in [r, r + 1) (it would contribute exactly
/// 0.0 in the full loop too — the clip returns before any accumulation).
/// The indices are appended in ascending edge order, so the banded sum
/// accumulates the same floats in the same order as the full loop.
/// `window` = the y-extent of the integration window (1.0 for the
/// stroke: the window is exactly the pixel).
pub fn buildStrokeBands(a: std.mem.Allocator, edges: []const StrokeEdge, window: f32) !StrokeBands {
    var row_min: i32 = std.math.maxInt(i32);
    var row_max: i32 = std.math.minInt(i32);
    for (edges) |e| {
        const ymin = @min(e.y0, e.y1);
        const ymax = @max(e.y0, e.y1);
        const r0: i32 = @intFromFloat(@floor(ymin - window));
        const r1 = @as(i32, @intFromFloat(@ceil(ymax))) - 1;
        if (r0 > r1) continue; // degenerate: no row's window can overlap
        row_min = @min(row_min, r0);
        row_max = @max(row_max, r1);
    }
    if (row_min > row_max) {
        // No edge participates in any row (an empty set): no band data.
        const pairs = try a.alloc(u32, 0);
        errdefer a.free(pairs);
        const indices = try a.alloc(u32, 0);
        errdefer a.free(indices);
        return .{
            .interior = .{ 0, 0, -1, -1 },
            .row_base = 0,
            .row_count = 0,
            .pairs = pairs,
            .indices = indices,
        };
    }
    const row_count: u32 = @intCast(row_max - row_min + 1);
    const counts = try a.alloc(u32, row_count);
    defer a.free(counts);
    @memset(counts, 0);
    for (edges) |e| {
        const ymin = @min(e.y0, e.y1);
        const ymax = @max(e.y0, e.y1);
        const r0: i32 = @intFromFloat(@floor(ymin - window));
        const r1 = @as(i32, @intFromFloat(@ceil(ymax))) - 1;
        if (r0 > r1) continue;
        const r0i: usize = @intCast(r0 - row_min);
        const r1i: usize = @intCast(r1 - row_min);
        for (r0i..r1i + 1) |ri| counts[ri] += 1;
    }
    const pairs = try a.alloc(u32, 2 * row_count);
    // `counts` is released by its unconditional defer. `pairs` is a
    // separate allocation whose ownership transfers in the successful
    // return and is released here only if a later allocation fails.
    errdefer a.free(pairs);
    var total: u32 = 0;
    for (0..row_count) |i| {
        pairs[2 * i] = total;
        pairs[2 * i + 1] = counts[i];
        total += counts[i];
    }
    const indices = try a.alloc(u32, total);
    errdefer a.free(indices);
    // Fill the runs in edge order → every row's indices stay ascending.
    const cursor = try a.alloc(u32, row_count);
    defer a.free(cursor);
    for (0..row_count) |i| cursor[i] = pairs[2 * i];
    for (edges, 0..) |e, ei| {
        const ymin = @min(e.y0, e.y1);
        const ymax = @max(e.y0, e.y1);
        const r0: i32 = @intFromFloat(@floor(ymin - window));
        const r1 = @as(i32, @intFromFloat(@ceil(ymax))) - 1;
        if (r0 > r1) continue;
        const r0i: usize = @intCast(r0 - row_min);
        const r1i: usize = @intCast(r1 - row_min);
        for (r0i..r1i + 1) |ri| {
            indices[cursor[ri]] = @intCast(ei);
            cursor[ri] += 1;
        }
    }
    return .{
        .interior = .{ 0, 0, -1, -1 },
        .row_base = row_min,
        .row_count = row_count,
        .pairs = pairs,
        .indices = indices,
    };
}

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

test "buildFillBands: 20x20 square outline" {
    // A 20x20 square outline as 4 line-quadratics in the sweep space
    // (y-up, (0,0) = the bbox top-left; the ink spans y in [-20, 0]).
    const curves = [_]Curve{
        .{ .p0x = 0, .p0y = -20, .p1x = 10, .p1y = -20, .p2x = 20, .p2y = -20 }, // bottom
        .{ .p0x = 20, .p0y = -20, .p1x = 20, .p1y = -10, .p2x = 20, .p2y = 0 }, // right
        .{ .p0x = 20, .p0y = 0, .p1x = 10, .p1y = 0, .p2x = 0, .p2y = 0 }, // top
        .{ .p0x = 0, .p0y = 0, .p1x = 0, .p1y = -10, .p2x = 0, .p2y = -20 }, // left
    };
    const bands = try buildFillBands(testing.allocator, &curves);
    defer {
        testing.allocator.free(bands.pairs);
        testing.allocator.free(bands.indices);
    }

    // (a) The interior rect exists and contains the square's center
    // (10, -10).
    try testing.expect(bands.interior[0] < 10 and 10 < bands.interior[0] + bands.interior[2]);
    try testing.expect(bands.interior[1] < -10 and -10 < bands.interior[1] + bands.interior[3]);

    // (b) The winding at the interior rect's center is nonzero (== +1 for
    // the CCW square).
    const cx = bands.interior[0] + 0.5 * bands.interior[2];
    const cy = bands.interior[1] + 0.5 * bands.interior[3];
    try testing.expectEqual(@as(i32, 1), windingAt(&curves, cx, cy));

    // (c) Every curve appears in exactly the rows where the row-bucket
    // predicate holds: the curve's y-span [min(p0.y,p2.y), max(p0.y,p2.y)]
    // overlaps the row's window union [r - 0.5, r + 2.5). Rebuild the
    // membership from the pairs and compare row by row (expectEqualSlices
    // also checks the ascending curve order).
    try testing.expect(bands.row_count > 0);
    for (0..bands.row_count) |rr| {
        const r: i32 = bands.row_base + @as(i32, @intCast(rr));
        const off = bands.pairs[2 * rr];
        const count = bands.pairs[2 * rr + 1];
        const in_band = bands.indices[off .. off + count];
        var expected = std.ArrayList(u32).empty;
        defer expected.deinit(testing.allocator);
        for (curves, 0..) |c, i| {
            const lo = @min(c.p0y, c.p2y);
            const hi = @max(c.p0y, c.p2y);
            const rf: f32 = @floatFromInt(r);
            if (lo < rf + 2.5 and hi > rf - 0.5) {
                try expected.append(testing.allocator, @intCast(i));
            }
        }
        try testing.expectEqualSlices(u32, expected.items, in_band);
    }

    // The band's rows span the square's full sweep extent: the bottom
    // edge participates from floor(-20 - 2.5) + 1 = -22 down to
    // floor(-20 + 0.5) = -20; the top edge from -2 to 0 — so the global
    // range is [-22, 0] (23 rows) and every curve appears somewhere.
    try testing.expectEqual(@as(i32, -22), bands.row_base);
    try testing.expectEqual(@as(u32, 23), bands.row_count);
    var saw = [_]bool{false} ** 4;
    for (bands.indices) |ci| saw[ci] = true;
    for (saw) |s| try testing.expect(s);
}

test "buildStrokeBands: 3-edge set" {
    // A vertical edge (y 0..10 at x=0), a horizontal edge (y=5, x 0..10)
    // and a sloped edge (0,2)->(10,8) in the sweep space (y-up). The band
    // membership (window = 1.0, the mode-2 integration window [py, py+1)):
    // an edge with y-span [ymin, ymax] participates in row r iff
    // ymin < r + 2 AND ymax > r — the union over the row's fragments of
    // the shader's y-clip. Hand-computed: the vertical edge spans rows
    // [floor(0 - 1), ceil(10) - 1] = [-1, 9]; the horizontal edge (a
    // degenerate span, always h == 0) sits in row 4; the sloped edge
    // spans [floor(2 - 1), ceil(8) - 1] = [1, 7]. Union: [-1, 9].
    const edges = [_]StrokeEdge{
        .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 10 }, // vertical: rows -1..9
        .{ .x0 = 0, .y0 = 5, .x1 = 10, .y1 = 5 }, // horizontal: row 4
        .{ .x0 = 0, .y0 = 2, .x1 = 10, .y1 = 8 }, // sloped: rows 1..7
    };
    const bands = try buildStrokeBands(testing.allocator, &edges, 1.0);
    defer {
        testing.allocator.free(bands.pairs);
        testing.allocator.free(bands.indices);
    }

    // (c) row_base/row_count + the interior is always disabled for strokes.
    try testing.expectEqual(@as(i32, -1), bands.row_base);
    try testing.expectEqual(@as(u32, 11), bands.row_count);
    try testing.expectEqual([4]f32{ 0, 0, -1, -1 }, bands.interior);

    // (a) + (b): every edge appears in exactly the rows where the
    // membership predicate holds, in ascending edge order per row
    // (expectEqualSlices checks the order too).
    for (0..bands.row_count) |rr| {
        const r: i32 = bands.row_base + @as(i32, @intCast(rr));
        const off = bands.pairs[2 * rr];
        const count = bands.pairs[2 * rr + 1];
        const in_band = bands.indices[off .. off + count];
        var expected = std.ArrayList(u32).empty;
        defer expected.deinit(testing.allocator);
        for (edges, 0..) |e, i| {
            const ymin = @min(e.y0, e.y1);
            const ymax = @max(e.y0, e.y1);
            const rf: f32 = @floatFromInt(r);
            if (ymin < rf + 2.0 and ymax > rf) {
                try expected.append(testing.allocator, @intCast(i));
            }
        }
        try testing.expectEqualSlices(u32, expected.items, in_band);
    }

    // Spot-check the hand-computed runs: row -1 (rr 0) holds only the
    // vertical edge; row 4 (rr 5) holds all three (the horizontal edge's
    // only row); row 9 (rr 10) holds only the vertical edge.
    const rr0: usize = 0;
    const off0 = bands.pairs[2 * rr0];
    const cnt0 = bands.pairs[2 * rr0 + 1];
    try testing.expectEqualSlices(u32, &[_]u32{0}, bands.indices[off0 .. off0 + cnt0]);
    const rr4: usize = @intCast(4 - bands.row_base);
    const off4 = bands.pairs[2 * rr4];
    const cnt4 = bands.pairs[2 * rr4 + 1];
    try testing.expectEqualSlices(u32, &[_]u32{ 0, 1, 2 }, bands.indices[off4 .. off4 + cnt4]);
    const rr9: usize = @intCast(9 - bands.row_base);
    const off9 = bands.pairs[2 * rr9];
    const cnt9 = bands.pairs[2 * rr9 + 1];
    try testing.expectEqualSlices(u32, &[_]u32{0}, bands.indices[off9 .. off9 + cnt9]);
}

test "buildStrokeBands: empty input" {
    const bands = try buildStrokeBands(testing.allocator, &[_]StrokeEdge{}, 1.0);
    defer {
        testing.allocator.free(bands.pairs);
        testing.allocator.free(bands.indices);
    }
    // (d) No edges → no band data (row_count 0; the caller skips the
    // buffer and the material keeps band_bda = 0 → the full edge loop).
    try testing.expectEqual(@as(i32, 0), bands.row_base);
    try testing.expectEqual(@as(u32, 0), bands.row_count);
    try testing.expectEqual([4]f32{ 0, 0, -1, -1 }, bands.interior);
}
