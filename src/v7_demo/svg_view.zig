//! SVG view module: converts a parsed SvgDoc (svg_xml.zig's SvgDoc +
//! svg.zig's SvgPath/Command) into the renderer's per-path conic curves,
//! glyph materials and scene rects. The conversion runs ONCE in `init` —
//! the tiger document is static, so the rects are the per-frame draw
//! input with zero per-frame work.
//!
//! The pipeline per path:
//!   1. CONVERSION — walk the commands (the parser's own resolution
//!      rules: relative values resolve against the current point, the
//!      smooth-cubic first control reflects the previous cubic's second
//!      control about the current point) and emit conics in the path's
//!      OWN coordinate space (SVG user space, y-down like the
//!      framebuffer): lines become degenerate conics (p0, midpoint, p2),
//!      cubics split into two conics at t = 0.5 (the exact de Casteljau
//!      midpoint math of text.zig's glyph extraction).
//!   2. REBASE — the renderer's sweep space is the glyph space: the
//!      shader's TYPE_GLYPH branch computes the sweep cell as
//!      (fragPos.x - vOrigin.x, vOrigin.y - fragPos.y) - 0.5 and compares
//!      the curves against it directly, so the curves must be bbox-
//!      relative with y UP about the origin (the pen for glyphs, the
//!      bbox top-left here). The user-space conics are rebased to
//!      (x - bbox.x, bbox.y - y); without the y flip the SVG renders
//!      vertically mirrored. The rebased extent is exactly the path's
//!      bbox: (0, -h) .. (w, 0).
//!   3. GPU — one GlyphSweeper (the GPU curve buffer) + one
//!      GlyphMaterial slot per path (TYPE_GLYPH, the curve BDA, the bbox
//!      extent, bearing_y = 0 — SVG has no bearing), the fill color
//!      converted sRGB → Oklab (srgbToOklab, the pipeline's color space;
//!      the material's gradient_to stays all-zero = flat fill — the
//!      shader composites vColor, the rect's color, over the gradient,
//!      the text-glyph precedent).
//!   4. RECT — one SceneRect per path: dst = the bbox + the 2px surround
//!      (the same quad padding as the glyph precedent, so the AA fringe
//!      resolves fully inside the quad), origin = the bbox top-left (the
//!      sweep anchor), clip_id = ~0, color = the Oklab fill.
//!
//! The material's win_w/win_h carry the bbox extent, but the current
//! shader's glyph branch sweeps a fixed 1x1 px window and ignores them
//! (verified in quad_frag.slang + lib/coverage.slang — the text engine
//! writes 1.0); they are informational for the future windowed sweep.
//!
//! UNSUPPORTED COMMANDS: quadratic_to / smooth_quadratic_to / arc_to
//! have no conic form here (the tiger reference has none). A path using
//! any of them is SKIPPED gracefully: convertPath returns null, init
//! drops the path (no curves, no sweeper, no rect, no material slot —
//! the slots stay dense) and counts it in `skipped`. Everything else
//! (M/m L/l H/h V/v C/c S/s Z/z) is fully converted.
//!
//! Paths with no draw commands (a bare moveto) or a zero-extent curve
//! set render nothing and are skipped the same way.
//!
//! Demo-side only: like text.zig, this file MAY import the v7 core.

const std = @import("std");
const noapi = @import("noapi");
const svg = @import("svg.zig");
const svg_xml = @import("svg_xml.zig");
const proto = @import("proto/sweeper.zig");
const SceneRect = @import("proto/render_9slice.zig").SceneRect;
const Rect = @import("v7/widget.zig").Rect;
const srgbToOklab = @import("text.zig").srgbToOklab;

const Curve = proto.Curve;
const GlyphSweeper = proto.GlyphSweeper;

/// A point in user space.
const Point = struct { x: f32 = 0, y: f32 = 0 };

/// Resolve a (possibly relative) coordinate pair against the current
/// point — svg.zig's own resolution rule, mirrored so the walker lands
/// exactly where parsePath's bbox walker did.
fn resolve(raw: Point, cur: Point, abs: bool) Point {
    return if (abs) raw else Point{ .x = cur.x + raw.x, .y = cur.y + raw.y };
}

/// Reflect `p` about `about` — the implicit first control point of a
/// smooth curve command (SVG 2 §8.3.8).
fn reflect(p: Point, about: Point) Point {
    return .{ .x = 2 * about.x - p.x, .y = 2 * about.y - p.y };
}

/// The walker's per-command state — a mirror of svg.zig's ParseState:
/// the current point, the subpath start, and the last cubic's second
/// control point (for the smooth-cubic reflection). A non-cubic command
/// resets the reflection state, exactly as the parser does.
const WalkState = struct {
    cur: Point = .{},
    subpath_start: Point = .{},
    prev_cubic: bool = false,
    prev_cp2: Point = .{},
};

/// Append a conic, splitting it at its y-extremum first: the shader's
/// sweepIntersect returns ONE root per window edge, which is exact only
/// when the curve crosses each edge at most once — i.e. y-monotonic.
/// The glyph outlines' curves are small enough to never matter; the
/// tiger's curves span hundreds of pixels, so an extremum lands in SOME
/// 1×1 window and the dropped second crossing corrupts the signed area
/// (the "flipped coverage" streaks). De Casteljau at the extremum t.
fn pushCurve(a: std.mem.Allocator, curves: *std.ArrayList(Curve), c: Curve) !void {
    const denom = c.p0y - 2 * c.p1y + c.p2y;
    if (denom == 0) {
        try curves.append(a, c); // linear in y: no extremum
        return;
    }
    const t = (c.p0y - c.p1y) / denom;
    if (t <= 0 or t >= 1) {
        try curves.append(a, c); // the extremum is outside the segment
        return;
    }
    const mt = 1 - t;
    // The two de Casteljau halves share the split point B(t).
    const b0x = mt * c.p0x + t * c.p1x;
    const b0y = mt * c.p0y + t * c.p1y;
    const b1x = mt * c.p1x + t * c.p2x;
    const b1y = mt * c.p1y + t * c.p2y;
    const dx = mt * b0x + t * b1x;
    const dy = mt * b0y + t * b1y;
    try curves.append(a, .{ .p0x = c.p0x, .p0y = c.p0y, .p1x = b0x, .p1y = b0y, .p2x = dx, .p2y = dy });
    try curves.append(a, .{ .p0x = dx, .p0y = dy, .p1x = b1x, .p1y = b1y, .p2x = c.p2x, .p2y = c.p2y });
}

/// Append the degenerate conic for a straight segment (p0, midpoint, p2)
/// — the same form as the glyph extraction's line callback.
fn appendLine(a: std.mem.Allocator, curves: *std.ArrayList(Curve), from: Point, to: Point) !void {
    try pushCurve(a, curves, .{
        .p0x = from.x,
        .p0y = from.y,
        .p1x = (from.x + to.x) * 0.5,
        .p1y = (from.y + to.y) * 0.5,
        .p2x = to.x,
        .p2y = to.y,
    });
}

/// Approximate a cubic with error-controlled conics. The old midpoint
/// split (2 conics per cubic, no error check) bent shallow curves — the
/// conic's control point deviates from the cubic by the full bulge. The
/// midpoint-MATCHING conic (Q1 = (3P1+3P2−P0−P3)/4, which shares the
/// cubic's B(0.5)) is instead emitted when the cubic is flat enough, and
/// the cubic is split at t=0.5 otherwise. `tol` is in user units; the
/// rendered deviation is tol × the view scale (≈ 0.1-0.3 px for the
/// tiger).
fn appendCubic(a: std.mem.Allocator, curves: *std.ArrayList(Curve), p0: Point, c1: Point, c2: Point, p3: Point) !void {
    try flattenCubic(a, curves, p0, c1, c2, p3, 0.5);
}

/// Distance from `p` to the segment `a0`→`a1` (the flatness test).
fn distToSegment(p: Point, a0: Point, a1: Point) f32 {
    const dx = a1.x - a0.x;
    const dy = a1.y - a0.y;
    const len2 = dx * dx + dy * dy;
    if (len2 == 0) return @sqrt((p.x - a0.x) * (p.x - a0.x) + (p.y - a0.y) * (p.y - a0.y));
    const t = std.math.clamp(((p.x - a0.x) * dx + (p.y - a0.y) * dy) / len2, 0, 1);
    const qx = a0.x + t * dx;
    const qy = a0.y + t * dy;
    return @sqrt((p.x - qx) * (p.x - qx) + (p.y - qy) * (p.y - qy));
}

fn flattenCubic(
    a: std.mem.Allocator,
    curves: *std.ArrayList(Curve),
    p0: Point,
    c1: Point,
    c2: Point,
    p3: Point,
    tol: f32,
) !void {
    // Flatness: the control points' deviation from the chord. A flat
    // cubic is within ~3/4 of this of its midpoint-matching conic, so the
    // tolerance here is the final curve error's ceiling.
    const flat = @max(distToSegment(c1, p0, p3), distToSegment(c2, p0, p3));
    if (flat <= tol) {
        // The conic through the endpoints whose midpoint equals the
        // cubic's B(0.5): Q1 = (3P1 + 3P2 - P0 - P3) / 4.
        try pushCurve(a, curves, .{
            .p0x = p0.x,
            .p0y = p0.y,
            .p1x = (3 * c1.x + 3 * c2.x - p0.x - p3.x) * 0.25,
            .p1y = (3 * c1.y + 3 * c2.y - p0.y - p3.y) * 0.25,
            .p2x = p3.x,
            .p2y = p3.y,
        });
        return;
    }
    // Split at t = 0.5 (de Casteljau) and recurse on the halves.
    const b0x = (p0.x + c1.x) * 0.5;
    const b0y = (p0.y + c1.y) * 0.5;
    const b1x = (c1.x + c2.x) * 0.5;
    const b1y = (c1.y + c2.y) * 0.5;
    const b2x = (c2.x + p3.x) * 0.5;
    const b2y = (c2.y + p3.y) * 0.5;
    const cx1x = (b0x + b1x) * 0.5;
    const cx1y = (b0y + b1y) * 0.5;
    const cx2x = (b1x + b2x) * 0.5;
    const cx2y = (b1y + b2y) * 0.5;
    const dx = (cx1x + cx2x) * 0.5;
    const dy = (cx1y + cx2y) * 0.5;
    try flattenCubic(a, curves, p0, .{ .x = b0x, .y = b0y }, .{ .x = cx1x, .y = cx1y }, .{ .x = dx, .y = dy }, tol);
    try flattenCubic(a, curves, .{ .x = dx, .y = dy }, .{ .x = cx2x, .y = cx2y }, .{ .x = b2x, .y = b2y }, p3, tol);
}

/// Convert one path's commands into conic curves in the path's own
/// coordinate space (SVG user space, y-down like the framebuffer). The
/// result is arena-allocated (`a`). Returns null when the path uses a
/// command the module does not support (quadratic_to / smooth_quadratic_to
/// / arc_to — absent from the tiger reference): the path is skipped
/// gracefully. An empty result means the path drew nothing (a bare
/// moveto, or a closepath with no segments).
fn convertPath(a: std.mem.Allocator, path: *const svg.SvgPath) !?[]Curve {
    var curves = std.ArrayList(Curve).empty;
    var st: WalkState = .{};
    for (path.commands) |cmd| {
        switch (cmd) {
            .move_to => |m| {
                const r = resolve(.{ .x = m.x, .y = m.y }, st.cur, m.abs);
                st.cur = r;
                st.subpath_start = r;
                st.prev_cubic = false;
            },
            .line_to => |l| {
                const to = resolve(.{ .x = l.x, .y = l.y }, st.cur, l.abs);
                try appendLine(a, &curves, st.cur, to);
                st.cur = to;
                st.prev_cubic = false;
            },
            .horizontal_to => |h| {
                const to = Point{ .x = if (h.abs) h.x else st.cur.x + h.x, .y = st.cur.y };
                try appendLine(a, &curves, st.cur, to);
                st.cur = to;
                st.prev_cubic = false;
            },
            .vertical_to => |v| {
                const to = Point{ .x = st.cur.x, .y = if (v.abs) v.y else st.cur.y + v.y };
                try appendLine(a, &curves, st.cur, to);
                st.cur = to;
                st.prev_cubic = false;
            },
            .cubic_to => |c| {
                const c1 = resolve(.{ .x = c.x1, .y = c.y1 }, st.cur, c.abs);
                const c2 = resolve(.{ .x = c.x2, .y = c.y2 }, st.cur, c.abs);
                const end = resolve(.{ .x = c.x, .y = c.y }, st.cur, c.abs);
                try appendCubic(a, &curves, st.cur, c1, c2, end);
                st.cur = end;
                st.prev_cubic = true;
                st.prev_cp2 = c2;
            },
            .smooth_cubic_to => |s| {
                // The implicit first control: the previous cubic's second
                // control reflected about the current point; without a
                // preceding cubic, the current point itself (SVG 2 §8.3.8).
                const c1 = if (st.prev_cubic) reflect(st.prev_cp2, st.cur) else st.cur;
                const c2 = resolve(.{ .x = s.x2, .y = s.y2 }, st.cur, s.abs);
                const end = resolve(.{ .x = s.x, .y = s.y }, st.cur, s.abs);
                try appendCubic(a, &curves, st.cur, c1, c2, end);
                st.cur = end;
                st.prev_cubic = true;
                st.prev_cp2 = c2;
            },
            .quadratic_to, .smooth_quadratic_to, .arc_to => return null, // unsupported: skip the path
            .close_path => {
                try appendLine(a, &curves, st.cur, st.subpath_start);
                st.cur = st.subpath_start;
                st.prev_cubic = false;
            },
        }
    }
    const owned = try curves.toOwnedSlice(a);
    return owned;
}

/// Rebase a user-space (y-down) curve set into the renderer's sweep
/// space: bbox-relative with y UP (a glyph outline relative to its pen).
/// The shader's TYPE_GLYPH branch computes the sweep cell as
/// (fragPos.x - vOrigin.x, vOrigin.y - fragPos.y) - 0.5 and sweeps the
/// curves against the cell directly, so y must flip to keep the SVG
/// right-side-up. The sweep's signed coverage for a closed path is
/// invariant under the y-flip (the sign of each crossing flips, and so
/// does the traversal direction), so the endpoints stay in order — the
/// nonzero fill survives. The path bbox is the conservative
/// control-point hull the parser computed, so the rebased extent is
/// exactly (0, -bbox.h) .. (bbox.w, 0).
fn rebaseToBbox(curves: []const Curve, bbox: Rect, out: []Curve) void {
    std.debug.assert(out.len == curves.len);
    for (curves, out) |src, *dst| {
        dst.* = .{
            .p0x = src.p0x - bbox.x,
            .p0y = bbox.y - src.p0y,
            .p1x = src.p1x - bbox.x,
            .p1y = bbox.y - src.p1y,
            .p2x = src.p2x - bbox.x,
            .p2y = bbox.y - src.p2y,
        };
    }
}

/// One edge of the stroke's offset-outline polygon: a straight segment
/// (x0,y0) -> (x1,y1) in the sweep space. Cairo's reference rasterizes
/// these edges exactly (the trapezoid coverage), never sampling a field.
/// (The extern layout lives with the band builder in proto/sweeper.zig.)
const StrokeEdge = proto.StrokeEdge;

/// The left perpendicular of the chord a0→a1, normalized; null when the
/// chord is degenerate (zero length).
fn normalOf(a0: [2]f32, a1: [2]f32) ?[2]f32 {
    var tx = a1[0] - a0[0];
    var ty = a1[1] - a0[1];
    const len = @sqrt(tx * tx + ty * ty);
    if (len < 1e-9) return null;
    tx /= len;
    ty /= len;
    return .{ -ty, tx };
}

/// Recursively sample the conic p0,p1,p2 by flatness: subdivide while the
/// control point's deviation from the chord exceeds `tol`, capped at 2^depth
/// segments. Appends the leaf endpoints (the caller appends p0).
fn sampleConic(
    a: std.mem.Allocator,
    pts: *std.ArrayList([2]f32),
    p0: [2]f32,
    p1: [2]f32,
    p2: [2]f32,
    tol: f32,
    depth: u8,
) !void {
    if (depth == 0 or distToSegment(
        .{ .x = p1[0], .y = p1[1] },
        .{ .x = p0[0], .y = p0[1] },
        .{ .x = p2[0], .y = p2[1] },
    ) <= tol) {
        try pts.append(a, p2);
        return;
    }
    const b0: [2]f32 = .{ (p0[0] + p1[0]) * 0.5, (p0[1] + p1[1]) * 0.5 };
    const b1: [2]f32 = .{ (p1[0] + p2[0]) * 0.5, (p1[1] + p2[1]) * 0.5 };
    const mid: [2]f32 = .{ (b0[0] + b1[0]) * 0.5, (b0[1] + b1[1]) * 0.5 };
    try sampleConic(a, pts, p0, b0, mid, tol, depth - 1);
    try sampleConic(a, pts, mid, b1, p2, tol, depth - 1);
}

/// Build the stroke's offset-outline polygon edges from the conics: sample
/// each conic adaptively, offset each sample by ±`half` perpendicular to
/// the tangent, and emit the band's boundary — the outer (+half) run, a
/// cap to the inner, the inner (−half) run reversed, a cap back. The exact
/// Cairo reference integrates this polygon per pixel. `closed` selects the
/// wiring: a closed path wraps with loop-closing chords (the start/end caps
/// are the tiny seams at the coincident point); an open path emits NO
/// closing chords and gets butt caps at its free ends.
fn buildStrokeOutline(a: std.mem.Allocator, curves: []const Curve, half: f32, closed: bool) ![]const StrokeEdge {
    // Adaptive sampling: subdivide each conic until its control point's
    // deviation from the chord falls below the tolerance — half/8, floored
    // at a small px — capped at 128 segments (depth 7) and floored at 8
    // (a uniform fallback for flat conics).
    const tol = @max(half * 0.125, 0.25);
    var pts = std.ArrayList([2]f32).empty;
    for (curves) |c| {
        const p0: [2]f32 = .{ c.p0x, c.p0y };
        const p1: [2]f32 = .{ c.p1x, c.p1y };
        const p2: [2]f32 = .{ c.p2x, c.p2y };
        const start = pts.items.len;
        try pts.append(a, p0);
        try sampleConic(a, &pts, p0, p1, p2, tol, 7);
        if (pts.items.len - start < 9) { // fewer than 8 segments: uniform fallback
            pts.shrinkRetainingCapacity(start);
            for (0..9) |k| {
                const k_f: f32 = @floatFromInt(@min(k, 1 << 24));
                const t = k_f / 8.0;
                const mt = 1 - t;
                try pts.append(a, .{
                    mt * mt * p0[0] + 2 * mt * t * p1[0] + t * t * p2[0],
                    mt * mt * p0[1] + 2 * mt * t * p1[1] + t * t * p2[1],
                });
            }
        }
    }

    // Deduplicate the junction points: consecutive conics both sample their
    // shared endpoint, and a join's two faces come from the two incident
    // chords at that one sample.
    var samples = std.ArrayList([2]f32).empty;
    for (pts.items) |p| {
        if (samples.items.len > 0) {
            const q = samples.items[samples.items.len - 1];
            if (@abs(p[0] - q[0]) < 1e-4 and @abs(p[1] - q[1]) < 1e-4) continue;
        }
        try samples.append(a, p);
    }
    const n = samples.items.len;
    if (n < 2) return a.alloc(StrokeEdge, 0);

    var outer = std.ArrayList([2]f32).empty;
    var inner = std.ArrayList([2]f32).empty;
    var last_n: ?[2]f32 = null; // the last good normal: the degenerate-tangent fallback
    for (0..n) |i| {
        const p = samples.items[i];
        const has_prev = closed or i > 0;
        const has_next = closed or i + 1 < n;
        const n_prev = if (has_prev) normalOf(samples.items[if (closed) (i + n - 1) % n else i - 1], p) else null;
        const n_next = if (has_next) normalOf(p, samples.items[if (closed) (i + 1) % n else i + 1]) else null;
        if (n_prev) |n1| {
            if (n_next) |n2| {
                // Both incident chords are alive: two faces where the
                // tangent is discontinuous (the normals differ materially),
                // the bisector (miter point) where it is smooth.
                const dot = n1[0] * n2[0] + n1[1] * n2[1];
                if (dot < 0.98) {
                    // A corner: emit both faces. The outer run connects the
                    // two points (a bevel); the inner run connects its two
                    // (a self-intersecting fold the fill rule cancels).
                    try outer.append(a, .{ p[0] + n1[0] * half, p[1] + n1[1] * half });
                    try outer.append(a, .{ p[0] + n2[0] * half, p[1] + n2[1] * half });
                    try inner.append(a, .{ p[0] - n1[0] * half, p[1] - n1[1] * half });
                    try inner.append(a, .{ p[0] - n2[0] * half, p[1] - n2[1] * half });
                    last_n = n2;
                } else {
                    var mx = n1[0] + n2[0];
                    var my = n1[1] + n2[1];
                    const ml = @sqrt(mx * mx + my * my);
                    if (ml > 1e-9) {
                        mx /= ml;
                        my /= ml;
                    } else {
                        mx = n1[0];
                        my = n1[1];
                    }
                    try outer.append(a, .{ p[0] + mx * half, p[1] + my * half });
                    try inner.append(a, .{ p[0] - mx * half, p[1] - my * half });
                    last_n = .{ mx, my };
                }
            } else {
                // Only the previous chord (a free end, or the next chord is
                // degenerate): a single face from its normal.
                try outer.append(a, .{ p[0] + n1[0] * half, p[1] + n1[1] * half });
                try inner.append(a, .{ p[0] - n1[0] * half, p[1] - n1[1] * half });
                last_n = n1;
            }
        } else if (n_next) |n2| {
            // Only the next chord (a free end): a single face from its normal.
            try outer.append(a, .{ p[0] + n2[0] * half, p[1] + n2[1] * half });
            try inner.append(a, .{ p[0] - n2[0] * half, p[1] - n2[1] * half });
            last_n = n2;
        } else if (last_n) |ln| {
            // Both chords degenerate: reuse the previous sample's normal
            // rather than notching the band.
            try outer.append(a, .{ p[0] + ln[0] * half, p[1] + ln[1] * half });
            try inner.append(a, .{ p[0] - ln[0] * half, p[1] - ln[1] * half });
        }
    }
    const m = outer.items.len;
    if (m < 2) return a.alloc(StrokeEdge, 0);

    var edges = std.ArrayList(StrokeEdge).empty;
    const add = struct {
        fn f(alloc: std.mem.Allocator, list: *std.ArrayList(StrokeEdge), aa: [2]f32, bb: [2]f32) !void {
            try list.append(alloc, .{ .x0 = aa[0], .y0 = aa[1], .x1 = bb[0], .y1 = bb[1] });
        }
    }.f;
    if (closed) {
        for (0..m) |i| try add(a, &edges, outer.items[i], outer.items[(i + 1) % m]);
        try add(a, &edges, outer.items[m - 1], inner.items[m - 1]);
        // the inner (−half) run reversed:
        for (0..m) |i| {
            const j = m - 1 - i;
            try add(a, &edges, inner.items[j], inner.items[(j + m - 1) % m]);
        }
        try add(a, &edges, inner.items[0], outer.items[0]);
    } else {
        // The outer run in order — no loop-closing chord for an open path:
        for (0..m - 1) |i| try add(a, &edges, outer.items[i], outer.items[i + 1]);
        // The end cap at the last end (a butt cap): outer.last -> inner.last
        try add(a, &edges, outer.items[m - 1], inner.items[m - 1]);
        // The inner (−half) run reversed, no closing chord:
        var j = m - 1;
        while (j >= 1) : (j -= 1) {
            try add(a, &edges, inner.items[j], inner.items[j - 1]);
        }
        // The leading cap: inner.first -> outer.first (a butt cap)
        try add(a, &edges, inner.items[0], outer.items[0]);
    }
    const owned = try edges.toOwnedSlice(a);
    return owned;
}

/// The cached SVG view: the per-path conics, GPU curve buffers, glyph
/// materials and scene rects, built once in `init` (the tiger is static).
pub const SvgView = struct {
    /// Owns `curves`, `sweepers` and `rects_storage` (the sweepers' GPU
    /// buffers are freed individually in deinit).
    arena: std.heap.ArenaAllocator,
    /// The per-path conics in the SWEEP space (rebaseToBbox: y-up,
    /// bbox-relative, SVG units) — the source the sweepers' GPU buffers
    /// are (re)written from at the current `scale`.
    curves: [][]const Curve,
    /// One GPU curve buffer per rendered path.
    sweepers: []GlyphSweeper,
    /// The last scale baked into the sweepers' GPU buffers (setScale
    /// no-ops when the fit scale is unchanged — the injection runs
    /// every frame, the curves only change on a resize).
    scale: f32,
    /// The GPU material buffer: one GlyphMaterial slot per rendered path.
    materials: noapi.GpuPtr,
    /// The material buffer's GPU address (the batch's material_buf_bda).
    material_bda: u64,
    /// The cached per-frame draw input.
    rects_storage: []SceneRect,
    /// The view size: the doc's viewBox extent, or the union of the path
    /// bboxes when there is no viewBox.
    view_size: [2]f32,
    /// The union of the path bboxes (the ACTUAL drawing extent — the
    /// tiger's paths extend beyond its viewBox with negative coords).
    bounds: Rect,
    /// Paths skipped for unsupported commands (quadratic/arc) or for
    /// drawing nothing.
    skipped: usize,
    /// The caller's base slot (the setScale rewrites the stroke widths
    /// into the materials at base + paths_len + j).
    base_slot: u32,
    paths_len: usize,
    /// The per-stroke widths (user units, unscaled) + the count.
    stroke_widths: []const f32,
    stroke_count: usize,
    /// The stroke's offset-outline edge buffers (mode 2 — the exact Cairo
    /// reference): one GPU buffer per stroked path holding the band's
    /// boundary edges, plus their BDAs and the curve BDAs (to restore the
    /// material when the algo is not 2).
    stroke_edge_bufs: []noapi.GpuPtr,
    stroke_edge_bdas: []u64,
    stroke_curve_bdas: []u64,
    /// The PRISTINE (unscaled) offset-outline edges: buildStrokeOutline's
    /// init-time output per stroked path, in the sweep space — the
    /// source the GPU edge buffers are (re)written from at the current
    /// `scale`, the `self.curves` pattern (setScale re-derives pristine *
    /// scale, never scales the buffer in place: the in-place `*= scale`
    /// compounded across setScale calls). Arena-owned alongside `curves`.
    stroke_edges_pristine: [][]const StrokeEdge,
    /// The per-path fill-band GPU buffers (the TYPE_SWEEP optimization:
    /// the interior box + the per-pixel-row curve runs, see
    /// buildFillBands) + their BDAs, parallel to `sweepers`. Built in
    /// setScale — the bands live in the SCALED sweep space like the
    /// curves, and the fit scale is unknown at init — and freed in
    /// deinit. null = no band data for the path (the material's band_bda
    /// stays 0 → the full sweep loop).
    band_bufs: []?noapi.GpuPtr,
    band_bdas: []u64,
    /// The per-stroke band GPU buffers (the mode-2 TYPE_STROKE
    /// optimization: the per-pixel-row edge runs, see buildStrokeBands)
    /// + their BDAs, parallel to `stroke_edge_bufs`. Built in setScale —
    /// the bands live in the SCALED sweep space like the scaled edges —
    /// and freed in deinit. null = no band data for the stroke (the
    /// material's band_bda stays 0 → the full edge loop).
    stroke_band_bufs: []?noapi.GpuPtr,
    stroke_band_bdas: []u64,
    /// The GPU handle (the band buffers are built at setScale).
    gpu: *noapi.Gpu,
    /// The init-time allocator, reused for the band builders' temporary
    /// arrays at setScale.
    gpa: std.mem.Allocator,

    /// Convert the document and create all GPU data once. `doc` must
    /// outlive the view (the view owns nothing of the doc). The materials
    /// are written into the CALLER'S material buffer (the batch draws
    /// with ONE material BDA — the text engine's) at `base_slot + index`;
    /// the caller reserves the slot range (see the window's
    /// SVG_MATERIAL_BASE).
    pub fn init(
        gpa: std.mem.Allocator,
        gpu: *noapi.Gpu,
        doc: *const svg_xml.SvgDoc,
        materials: noapi.GpuPtr,
        material_bda: u64,
        base_slot: u32,
    ) !SvgView {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        var curves_list = std.ArrayList([]const Curve).empty;
        var sweepers = std.ArrayList(GlyphSweeper).empty;
        var rect_list = std.ArrayList(SceneRect).empty;
        errdefer {
            for (sweepers.items) |*s| s.deinit();
        }

        var skipped: usize = 0;
        var stroke_count: usize = 0;
        var stroke_widths = std.ArrayList(f32).empty;
        var stroke_edge_bufs = std.ArrayList(noapi.GpuPtr).empty;
        var stroke_edge_bdas = std.ArrayList(u64).empty;
        var stroke_curve_bdas = std.ArrayList(u64).empty;
        var stroke_edges_pristine = std.ArrayList([]const StrokeEdge).empty;
        var stroke_band_bufs = std.ArrayList(?noapi.GpuPtr).empty;
        var stroke_band_bdas = std.ArrayList(u64).empty;
        errdefer {
            for (stroke_edge_bufs.items) |*b| gpu.gpuFree(b.*);
            for (stroke_band_bufs.items) |*b| if (b.*) |bb| gpu.gpuFree(bb);
        }
        // The fill-band buffers are built at setScale (they live in the
        // scaled sweep space); here we only track the per-path slots.
        var band_bufs = std.ArrayList(?noapi.GpuPtr).empty;
        var band_bdas = std.ArrayList(u64).empty;
        for (doc.paths) |*path| {
            const user_curves = (try convertPath(a, path)) orelse {
                skipped += 1; // unsupported command (quadratic/arc)
                continue;
            };
            if (user_curves.len == 0) {
                skipped += 1; // no draw commands: nothing to render
                continue;
            }

            // The sweep space: rebase the user-space (y-down) conics to
            // bbox-relative y-up (the shader's cell flips y — see
            // rebaseToBbox).
            const sweep_curves = try a.alloc(Curve, user_curves.len);
            rebaseToBbox(user_curves, path.bbox, sweep_curves);

            var sweeper = try GlyphSweeper.init(gpu, sweep_curves);
            curves_list.append(a, sweep_curves) catch |e| {
                sweeper.deinit();
                return e;
            };
            sweepers.append(a, sweeper) catch |e| {
                sweeper.deinit();
                return e;
            };
            const slot: u32 = base_slot + @as(u32, @intCast(sweepers.items.len - 1));

            // A zero-extent curve set (a single point) has no ink: skip
            // the path like the glyph engine skips zero-size glyphs.
            if (sweeper.curve_w == 0 and sweeper.curve_h == 0) {
                var orphan = sweepers.pop().?;
                orphan.deinit();
                _ = curves_list.pop();
                skipped += 1;
                continue;
            }

            // The path's fill-band slot: the buffer is built at setScale
            // (the bands live in the scaled sweep space); the material's
            // band_bda is written there too.
            try band_bufs.append(a, null);
            try band_bdas.append(a, 0);

            // The glyph material: type GLYPH, the curve BDA, the bbox
            // extent (the rebased curves span exactly the bbox), zero
            // bearing — SVG has no bearing; the ink's top edge is the
            // bbox's top edge (curve_bottom = -h in sweep space). The
            // window fields carry the bbox extent; the current shader's
            // glyph branch sweeps a fixed 1x1 px window and ignores them
            // (verified in quad_frag.slang + lib/coverage.slang).
            // The fill's material: TYPE_SWEEP (not TYPE_GLYPH) — the SDF
            // sweep AA with NO subpixel branch. The text's glyphs keep
            // TYPE_GLYPH; the two render independently (the S toggle must
            // never stripe or blur the tiger).
            GlyphSweeper.writeSweepMaterial(
                sweeper.curve_buf_bda,
                0, // band_bda: built + written at setScale
                materials,
                slot,
                sweeper.curve_w,
                sweeper.curve_h,
            );

            // The fill: sRGB (the path's fill attribute, default black)
            // → Oklab, the pipeline's color space. The material's
            // gradient_to stays all-zero (flat fill): the shader
            // composites vColor — this rect's color — over the gradient,
            // the text-glyph precedent.
            const color = srgbToOklab(path.fill);
            const bbox = path.bbox;
            rect_list.append(a, .{
                // The 2px surround on all sides (the glyph precedent): the
                // ink's edge lands within ceil(w)-w of the bbox boundary
                // and the outermost pixel ring must resolve its AA fully
                // inside the quad.
                .dst = .{ bbox.x - 2, bbox.y - 2, @ceil(bbox.w) + 4, @ceil(bbox.h) + 4 },
                .src = .{ 0, 0, 1, 1 },
                .corners = .{ 0, 0, 0, 0 },
                .color = color,
                .material_index = slot,
                // The curve extent in sweep space (the CPU-side preview
                // convention: curve_left/bottom/w/h).
                .curve = .{ sweeper.curve_left, sweeper.curve_bottom, sweeper.curve_w, sweeper.curve_h },
                .clip_id = std.math.maxInt(u32), // ~0: no clip
                // The sweep anchor: the bbox's top-left (the curves are
                // bbox-relative; fragPos - vOrigin locates the fragment
                // in sweep space).
                .origin = .{ bbox.x, bbox.y },
            }) catch |e| {
                var orphan = sweepers.pop().?;
                orphan.deinit();
                return e;
            };

            // The stroke: an ADDITIONAL rect (painted after the fill) with
            // the TYPE_STROKE material — the shader's distance branch. The
            // quad expands by the stroke half-width so the band's AA lands
            // inside it; the origin stays the bbox's top-left (the cell is
            // bbox-relative, same as the fill). The stroke's slots sit
            // above the fills: base + paths_len + stroke_index.
            if (path.stroke) |stroke| {
                const stroke_slot: u32 = base_slot + @as(u32, @intCast(doc.paths.len)) +
                    @as(u32, @intCast(stroke_count));
                GlyphSweeper.writeStrokeMaterial(sweeper.curve_buf_bda, materials, stroke_slot, path.stroke_width);
                try stroke_widths.append(a, path.stroke_width);
                // The offset-outline polygon for mode 2 (the exact Cairo
                // reference): sample the conics, offset by ±half, upload
                // the band's boundary edges to a GPU buffer. The material's
                // curve_bda is pointed at it when the algo is 2. A trailing
                // close_path command closes the loop (the runs wrap with
                // closing chords); otherwise the subpath is open and the
                // band gets butt caps and no loop-closing chords.
                const closed = path.commands.len > 0 and std.meta.activeTag(
                    path.commands[path.commands.len - 1],
                ) == .close_path;
                const edge_list = try buildStrokeOutline(a, sweep_curves, path.stroke_width / 2, closed);
                const edge_buf_size: u64 = @sizeOf(StrokeEdge) * edge_list.len + 16;
                const edge_buf = try gpu.gpuMalloc(edge_buf_size, 16, .default);
                errdefer gpu.gpuFree(edge_buf);
                const edge_dst: [*]u8 = @ptrCast(@alignCast(edge_buf.cpu));
                @as(*u32, @ptrCast(@alignCast(edge_dst))).* = @intCast(edge_list.len);
                @as(*u32, @ptrCast(@alignCast(edge_dst + 4))).* = 0;
                if (edge_list.len > 0) {
                    const edges_src: [*]const StrokeEdge = edge_list.ptr;
                    const edges_out: [*]StrokeEdge = @ptrCast(@alignCast(edge_dst + 8));
                    @memcpy(edges_out[0..edge_list.len], edges_src[0..edge_list.len]);
                }
                try stroke_edge_bufs.append(a, edge_buf);
                try stroke_edge_bdas.append(a, edge_buf.gpu);
                try stroke_curve_bdas.append(a, sweeper.curve_buf_bda);
                // Keep the PRISTINE edges (the buildStrokeOutline output,
                // arena-owned) — setScale re-derives the scaled GPU
                // buffer from them, the curves' `self.curves` pattern.
                try stroke_edges_pristine.append(a, edge_list);
                // The stroke's band slot: the buffer is built at setScale
                // (the bands live in the scaled sweep space); the
                // material's band_bda is written there too.
                try stroke_band_bufs.append(a, null);
                try stroke_band_bdas.append(a, 0);
                const w = path.stroke_width;
                rect_list.append(a, .{
                    .dst = .{ bbox.x - w / 2 - 2, bbox.y - w / 2 - 2, @ceil(bbox.w) + w + 4, @ceil(bbox.h) + w + 4 },
                    .src = .{ 0, 0, 1, 1 },
                    .corners = .{ 0, 0, 0, 0 },
                    .color = srgbToOklab(stroke),
                    .material_index = stroke_slot,
                    .curve = .{ sweeper.curve_left, sweeper.curve_bottom, sweeper.curve_w, sweeper.curve_h },
                    .clip_id = std.math.maxInt(u32), // ~0: no clip
                    .origin = .{ bbox.x, bbox.y },
                }) catch |e| {
                    var orphan = sweepers.pop().?;
                    orphan.deinit();
                    return e;
                };
                stroke_count += 1;
            }
        }

        // The paths' ACTUAL union bounds — ALWAYS (the tiger's paths
        // extend beyond its 900x900 viewBox, with negative coordinates).
        // The demo's injection fits this box, not the viewBox, or the
        // off-viewBox paths land outside the card.
        var min_x: f32 = std.math.inf(f32);
        var min_y: f32 = std.math.inf(f32);
        var max_x: f32 = -std.math.inf(f32);
        var max_y: f32 = -std.math.inf(f32);
        for (doc.paths) |p| {
            if (p.bbox.w == 0 and p.bbox.h == 0) continue;
            min_x = @min(min_x, p.bbox.x);
            min_y = @min(min_y, p.bbox.y);
            max_x = @max(max_x, p.bbox.x + p.bbox.w);
            max_y = @max(max_y, p.bbox.y + p.bbox.h);
        }
        const bounds = if (min_x <= max_x)
            Rect{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y }
        else
            Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };

        // The view size: the root viewBox's extent when present, else the
        // paths' union extent (the doc's width/height attributes are
        // intentionally ignored — the naive reader applies no viewBox
        // transform, so the viewBox is the natural framing reference).
        const view_size = if (doc.view_box) |vb|
            .{ vb[2], vb[3] }
        else
            .{ bounds.w, bounds.h };

        // Own each toOwnedSlice allocation with an errdefer before the
        // struct literal — a failure mid-literal would leak the slices
        // already converted (errdefer can't appear inside a literal).
        const curves_owned = try curves_list.toOwnedSlice(a);
        errdefer a.free(curves_owned);
        const sweepers_owned = try sweepers.toOwnedSlice(a);
        errdefer {
            for (sweepers_owned) |*s| s.deinit();
        }
        const rects_owned = try rect_list.toOwnedSlice(a);
        errdefer a.free(rects_owned);
        const stroke_widths_owned = try stroke_widths.toOwnedSlice(a);
        errdefer a.free(stroke_widths_owned);
        const stroke_edge_bufs_owned = try stroke_edge_bufs.toOwnedSlice(a);
        errdefer {
            for (stroke_edge_bufs_owned) |b| gpu.gpuFree(b);
        }
        const stroke_edge_bdas_owned = try stroke_edge_bdas.toOwnedSlice(a);
        errdefer a.free(stroke_edge_bdas_owned);
        const stroke_curve_bdas_owned = try stroke_curve_bdas.toOwnedSlice(a);
        errdefer a.free(stroke_curve_bdas_owned);
        const stroke_edges_pristine_owned = try stroke_edges_pristine.toOwnedSlice(a);
        errdefer a.free(stroke_edges_pristine_owned);
        const stroke_band_bufs_owned = try stroke_band_bufs.toOwnedSlice(a);
        errdefer {
            for (stroke_band_bufs_owned) |b| if (b) |bb| gpu.gpuFree(bb);
        }
        const stroke_band_bdas_owned = try stroke_band_bdas.toOwnedSlice(a);
        errdefer a.free(stroke_band_bdas_owned);
        const band_bufs_owned = try band_bufs.toOwnedSlice(a);
        errdefer {
            for (band_bufs_owned) |b| if (b) |bb| gpu.gpuFree(bb);
        }
        const band_bdas_owned = try band_bdas.toOwnedSlice(a);
        errdefer a.free(band_bdas_owned);

        return .{
            .arena = arena,
            .curves = curves_owned,
            .sweepers = sweepers_owned,
            .materials = materials,
            .material_bda = material_bda,
            .rects_storage = rects_owned,
            .view_size = view_size,
            .bounds = bounds,
            .skipped = skipped,
            .base_slot = base_slot,
            .paths_len = doc.paths.len,
            .stroke_widths = stroke_widths_owned,
            .stroke_count = stroke_count,
            .stroke_edge_bufs = stroke_edge_bufs_owned,
            .stroke_edge_bdas = stroke_edge_bdas_owned,
            .stroke_curve_bdas = stroke_curve_bdas_owned,
            .stroke_edges_pristine = stroke_edges_pristine_owned,
            .stroke_band_bufs = stroke_band_bufs_owned,
            .stroke_band_bdas = stroke_band_bdas_owned,
            .band_bufs = band_bufs_owned,
            .band_bdas = band_bdas_owned,
            .gpu = gpu,
            .gpa = gpa,
            .scale = 0,
        };
    }

    /// Bake the fit scale into the GPU curve buffers. The shader's
    /// TYPE_GLYPH branch sweeps the 1x1 px window against the curves in
    /// PIXEL space (the glyph outlines are extracted at the pixel size),
    /// so the SVG-unit sweep curves must be scaled by the injection's
    /// aspect-fit factor before any draw that uses them. No-op when the
    /// scale is unchanged (the injection runs every frame; the curves
    /// only change on a resize).
    /// Set the stroke rendering parameters: `algo` (0 = naive SDF, 1 =
    /// marching quads) and `oversize` (the AA band / marching-quad
    /// half-extent in px), written into the stroke materials' win_w/win_h
    /// fields (unused by the shader otherwise). Per-frame tunable for the
    /// stroke test scene.
    pub fn setStrokeStyle(self: *SvgView, algo: u32, oversize: f32) void {
        const dst: [*]u8 = @ptrCast(@alignCast(self.materials.cpu));
        for (0..self.stroke_widths.len) |j| {
            const slot = self.base_slot + @as(u32, @intCast(self.paths_len)) + @as(u32, @intCast(j));
            const offset = slot * proto.material_size + @offsetOf(proto.GlyphMaterial, "win_w");
            @as(*f32, @ptrCast(@alignCast(dst + offset))).* = @floatFromInt(algo);
            @as(*f32, @ptrCast(@alignCast(dst + offset + @sizeOf(f32)))).* = oversize;
            // Mode 2 reads the EDGE buffer (the offset outline) through the
            // material's curve_bda slot; modes 0/1 read the curves. Point
            // the BDA at the right buffer.
            const bda_off = slot * proto.material_size + @offsetOf(proto.GlyphMaterial, "curve_bda");
            const bda = if (algo == 2) self.stroke_edge_bdas[j] else self.stroke_curve_bdas[j];
            @as(*u64, @ptrCast(@alignCast(dst + bda_off))).* = bda;
        }
    }

    pub fn setScale(self: *SvgView, scale: f32) void {
        if (self.scale == scale) return;
        self.scale = scale;
        // The stroke widths live in user units like the curves; scale the
        // materials' bearing_y fields (offset 4 = after the type u32).
        for (self.stroke_widths, 0..) |w, j| {
            const slot = self.base_slot + @as(u32, @intCast(self.paths_len)) + @as(u32, @intCast(j));
            const offset = slot * proto.material_size + @offsetOf(proto.GlyphMaterial, "bearing_y");
            const dst: [*]u8 = @ptrCast(@alignCast(self.materials.cpu));
            @as(*f32, @ptrCast(@alignCast(dst + offset))).* = w * scale;
        }
        for (self.sweepers, self.curves, 0..) |*s, curves, i| {
            const dst: [*]u8 = @ptrCast(@alignCast(s.curve_buf.cpu));
            const curve_dst: [*]Curve = @ptrCast(@alignCast(dst + 8));
            for (curves, 0..) |c, j| {
                curve_dst[j] = .{
                    .p0x = c.p0x * scale,
                    .p0y = c.p0y * scale,
                    .p1x = c.p1x * scale,
                    .p1y = c.p1y * scale,
                    .p2x = c.p2x * scale,
                    .p2y = c.p2y * scale,
                };
            }
            // The fill bands (the TYPE_SWEEP optimization), rebuilt from
            // the SCALED curves (the band rows + the interior box live in
            // the sweep's pixel space). The scaled curves are already in
            // the GPU buffer above — read them straight back out.
            const scaled_curves: [*]const Curve = @ptrCast(@alignCast(curve_dst));
            const scaled: []const Curve = scaled_curves[0..curves.len];
            self.buildBands(i, scaled);
        }
        // The offset-outline edges (mode 2) scale uniformly too: the
        // offsets (±half) and the sample positions both scale linearly.
        // The stroke bands (the mode-2 TYPE_STROKE optimization) are then
        // rebuilt from the SCALED edges (the band rows live in the sweep's
        // pixel space like the fill bands) — the scaled edges are read
        // straight back out of the GPU buffer, the fill-band pattern.
        for (self.stroke_edge_bufs, self.stroke_edges_pristine, 0..) |eb, pristine, j| {
            const edst: [*]u8 = @ptrCast(@alignCast(eb.cpu));
            const count: u32 = @as(*const u32, @ptrCast(@alignCast(edst))).*;
            const edges: [*]StrokeEdge = @ptrCast(@alignCast(edst + 8));
            std.debug.assert(count == pristine.len);
            for (0..count) |i| {
                // RE-DERIVE from the pristine edges (the curves' pattern)
                // — the `*= scale` in-place form compounded across
                // setScale calls: the buffer held the PREVIOUS scale's
                // values, so scale 1.0 -> 2.0 -> 1.0 left the edges at
                // 2x instead of back at 1x.
                edges[i].x0 = pristine[i].x0 * scale;
                edges[i].y0 = pristine[i].y0 * scale;
                edges[i].x1 = pristine[i].x1 * scale;
                edges[i].y1 = pristine[i].y1 * scale;
            }
            self.buildStrokeBands(j, edges[0..count]);
        }
    }

    /// Build + upload one path's fill-band buffer (buildFillBands →
    /// serialize into a GPU buffer) and point the path's sweep material
    /// at it. `scaled` is the path's curve set in the SCALED sweep space
    /// (the same space the shader sweeps). Called from setScale; a no-op
    /// band (row_count == 0 and no interior) leaves band_bda = 0 — the
    /// material keeps the full-loop path. Any previous band buffer is
    /// freed and the material's band_bda is ALWAYS rewritten (a stale
    /// pointer would render the wrong scale's rows).
    fn buildBands(self: *SvgView, i: usize, scaled: []const Curve) void {
        const bands = proto.buildFillBands(self.gpa, scaled) catch {
            // OOM: drop any stale band, fall back to the full loop.
            if (self.band_bufs[i]) |old| self.gpu.gpuFree(old);
            self.band_bufs[i] = null;
            self.band_bdas[i] = 0;
            self.writeBandBda(i, 0);
            return;
        };
        defer self.gpa.free(bands.pairs);
        defer self.gpa.free(bands.indices);
        const has_interior = bands.interior[2] > 0 and bands.interior[3] > 0;
        var bda: u64 = 0;
        if (bands.row_count > 0 or has_interior) {
            const band_size: u64 = 32 + 8 * @as(u64, bands.row_count) + 4 * @as(u64, bands.indices.len);
            const maybe_buf = self.gpu.gpuMalloc(band_size, 16, .default) catch null;
            if (maybe_buf) |new_buf| {
                if (self.band_bufs[i]) |old| self.gpu.gpuFree(old);
                self.band_bufs[i] = new_buf;
                self.band_bdas[i] = new_buf.gpu;
                bda = new_buf.gpu;
                // The 32-byte header: float4 interior @0, i32 row_base
                // @16, u32 row_count @20, u32 pairs_base @24, u32
                // indices_base @28, then the (offset, count) pairs, then
                // the curve indices.
                const hdr: [*]u32 = @ptrCast(@alignCast(new_buf.cpu));
                @as(*[4]f32, @ptrCast(@alignCast(hdr))).* = bands.interior;
                hdr[4] = @bitCast(bands.row_base);
                hdr[5] = bands.row_count;
                hdr[6] = 8; // pairs_base: 32 header bytes / 4
                hdr[7] = 8 + 2 * bands.row_count; // indices_base
                @memcpy(hdr[8 .. 8 + 2 * @as(usize, bands.row_count)], bands.pairs);
                @memcpy(hdr[8 + 2 * @as(usize, bands.row_count) ..][0..bands.indices.len], bands.indices);
            } else {
                // Allocation failure: fall back to the full loop.
                if (self.band_bufs[i]) |old| self.gpu.gpuFree(old);
                self.band_bufs[i] = null;
                self.band_bdas[i] = 0;
            }
        } else {
            // No band data at all: keep the full-loop material.
            if (self.band_bufs[i]) |old| self.gpu.gpuFree(old);
            self.band_bufs[i] = null;
            self.band_bdas[i] = 0;
        }
        self.writeBandBda(i, bda);
    }

    /// Write a path's band_bda into its sweep material slot.
    fn writeBandBda(self: *SvgView, i: usize, bda: u64) void {
        const slot = self.base_slot + @as(u32, @intCast(i));
        const dst: [*]u8 = @ptrCast(@alignCast(self.materials.cpu));
        const bda_off = slot * proto.material_size + @offsetOf(proto.GlyphMaterial, "band_bda");
        @as(*u64, @ptrCast(@alignCast(dst + bda_off))).* = bda;
    }

    /// Build + upload one stroke path's band buffer (buildStrokeBands →
    /// serialize into a GPU buffer) and point the stroke's material at it
    /// (slot = base_slot + paths_len + j). Mirrors buildBands for the
    /// fills; the stroke band has NO interior (the interior is always
    /// disabled), so a no-op band (row_count == 0) leaves band_bda = 0 —
    /// the material keeps the full edge loop. Any previous band buffer is
    /// freed and the material's band_bda is ALWAYS rewritten (a stale
    /// pointer would render the wrong scale's rows).
    fn buildStrokeBands(self: *SvgView, j: usize, scaled: []const StrokeEdge) void {
        const bands = proto.buildStrokeBands(self.gpa, scaled, 1.0) catch {
            // OOM: drop any stale band, fall back to the full loop.
            if (self.stroke_band_bufs[j]) |old| self.gpu.gpuFree(old);
            self.stroke_band_bufs[j] = null;
            self.stroke_band_bdas[j] = 0;
            self.writeStrokeBandBda(j, 0);
            return;
        };
        defer self.gpa.free(bands.pairs);
        defer self.gpa.free(bands.indices);
        var bda: u64 = 0;
        if (bands.row_count > 0) {
            const band_size: u64 = 32 + 8 * @as(u64, bands.row_count) + 4 * @as(u64, bands.indices.len);
            const maybe_buf = self.gpu.gpuMalloc(band_size, 16, .default) catch null;
            if (maybe_buf) |new_buf| {
                if (self.stroke_band_bufs[j]) |old| self.gpu.gpuFree(old);
                self.stroke_band_bufs[j] = new_buf;
                self.stroke_band_bdas[j] = new_buf.gpu;
                bda = new_buf.gpu;
                // The 32-byte header: float4 interior @0 (always
                // {0,0,-1,-1} — the stroke branch has no interior test),
                // i32 row_base @16, u32 row_count @20, u32 pairs_base
                // @24, u32 indices_base @28, then the (offset, count)
                // pairs, then the edge indices.
                const hdr: [*]u32 = @ptrCast(@alignCast(new_buf.cpu));
                @as(*[4]f32, @ptrCast(@alignCast(hdr))).* = bands.interior;
                hdr[4] = @bitCast(bands.row_base);
                hdr[5] = bands.row_count;
                hdr[6] = 8; // pairs_base: 32 header bytes / 4
                hdr[7] = 8 + 2 * bands.row_count; // indices_base
                @memcpy(hdr[8 .. 8 + 2 * @as(usize, bands.row_count)], bands.pairs);
                @memcpy(hdr[8 + 2 * @as(usize, bands.row_count) ..][0..bands.indices.len], bands.indices);
            } else {
                // Allocation failure: fall back to the full loop.
                if (self.stroke_band_bufs[j]) |old| self.gpu.gpuFree(old);
                self.stroke_band_bufs[j] = null;
                self.stroke_band_bdas[j] = 0;
            }
        } else {
            // No band data at all: keep the full-loop material.
            if (self.stroke_band_bufs[j]) |old| self.gpu.gpuFree(old);
            self.stroke_band_bufs[j] = null;
            self.stroke_band_bdas[j] = 0;
        }
        self.writeStrokeBandBda(j, bda);
    }

    /// Write a stroke path's band_bda into its stroke material slot
    /// (base_slot + paths_len + j).
    fn writeStrokeBandBda(self: *SvgView, j: usize, bda: u64) void {
        const slot = self.base_slot + @as(u32, @intCast(self.paths_len)) + @as(u32, @intCast(j));
        const dst: [*]u8 = @ptrCast(@alignCast(self.materials.cpu));
        const bda_off = slot * proto.material_size + @offsetOf(proto.GlyphMaterial, "band_bda");
        @as(*u64, @ptrCast(@alignCast(dst + bda_off))).* = bda;
    }

    /// Release the GPU curve buffers; the CPU side (curves, sweepers,
    /// rects) lives in the arena. The MATERIAL buffer is the caller's
    /// (the shared text-engine buffer) — never freed here.
    pub fn deinit(self: *SvgView, gpu: *noapi.Gpu) void {
        for (self.sweepers) |*s| s.deinit();
        for (self.stroke_edge_bufs) |b| gpu.gpuFree(b);
        for (self.stroke_band_bufs) |b| if (b) |bb| gpu.gpuFree(bb);
        for (self.band_bufs) |b| if (b) |bb| gpu.gpuFree(bb);
        self.arena.deinit();
        self.* = undefined;
    }

    /// The cached per-frame draw input: one SceneRect per rendered path.
    pub fn rects(self: *const SvgView) []const SceneRect {
        return self.rects_storage;
    }

    /// The view size: the doc's viewBox extent, or the union of the path
    /// bboxes when there is no viewBox.
    pub fn size(self: *const SvgView) [2]f32 {
        return self.view_size;
    }

    /// The GPU material buffer's address (the batch's material_buf_bda).
    pub fn materialBda(self: *const SvgView) u64 {
        return self.material_bda;
    }

    /// The paths' actual union bounds (the drawing extent — fit this,
    /// not the viewBox: the tiger's paths extend beyond its viewBox).
    pub fn boundsRect(self: *const SvgView) Rect {
        return self.bounds;
    }
};

// ─── Tests (pure only — the GPU paths are smoke-verified by the demo) ───

const testing = std.testing;

/// A manually-built path for the conversion tests (the arena field is
/// never touched: convertPath only reads `commands`).
fn testPath(commands: []const svg.Command, bbox: Rect) svg.SvgPath {
    return .{
        .commands = @constCast(commands),
        .bbox = bbox,
        // SAFETY: the conversion tests never call deinit or the arena —
        // convertPath reads only `commands` + `bbox` + `fill`.
        .arena = undefined,
        .fill = .{ 0, 0, 0, 1 },
    };
}

fn expectCurve(curve: Curve, p0: [2]f32, p1: [2]f32, p2: [2]f32) !void {
    try testing.expectEqual(p0[0], curve.p0x);
    try testing.expectEqual(p0[1], curve.p0y);
    try testing.expectEqual(p1[0], curve.p1x);
    try testing.expectEqual(p1[1], curve.p1y);
    try testing.expectEqual(p2[0], curve.p2x);
    try testing.expectEqual(p2[1], curve.p2y);
}

test "line_to converts to the degenerate conic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = testPath(&.{
        .{ .move_to = .{ .abs = true, .x = 0, .y = 0 } },
        .{ .line_to = .{ .abs = true, .x = 10, .y = 0 } },
    }, .{ .x = 0, .y = 0, .w = 10, .h = 0 });
    const curves = (try convertPath(a, &path)).?;
    try testing.expectEqual(@as(usize, 1), curves.len);
    try expectCurve(curves[0], .{ 0, 0 }, .{ 5, 0 }, .{ 10, 0 });
}

test "cubic_to splits into two conics at t=0.5" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = testPath(&.{
        .{ .move_to = .{ .abs = true, .x = 0, .y = 0 } },
        .{ .cubic_to = .{ .abs = true, .x1 = 0, .y1 = 10, .x2 = 10, .y2 = 10, .x = 10, .y = 0 } },
    }, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
    const curves = (try convertPath(a, &path)).?;
    try testing.expectEqual(@as(usize, 2), curves.len);
    // The shared point is the curve's midpoint B(0.5) = (5, 7.5); the
    // conic controls are the de Casteljau midpoints (0,5) and (7.5,7.5).
    try expectCurve(curves[0], .{ 0, 0 }, .{ 0, 5 }, .{ 5, 7.5 });
    try expectCurve(curves[1], .{ 5, 7.5 }, .{ 7.5, 7.5 }, .{ 10, 0 });
}

test "smooth_cubic_to reflects the previous cubic's control" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = testPath(&.{
        .{ .move_to = .{ .abs = true, .x = 0, .y = 0 } },
        .{ .cubic_to = .{ .abs = true, .x1 = 0, .y1 = 10, .x2 = 10, .y2 = 10, .x = 10, .y = 0 } },
        // S: the implicit first control = 2*cur - prev_cp2 = 2*(10,0) -
        // (10,10) = (10,-10); the split's shared point = (15,-7.5).
        .{ .smooth_cubic_to = .{ .abs = true, .x2 = 20, .y2 = -10, .x = 20, .y = 0 } },
    }, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
    const curves = (try convertPath(a, &path)).?;
    try testing.expectEqual(@as(usize, 4), curves.len);
    try expectCurve(curves[2], .{ 10, 0 }, .{ 10, -5 }, .{ 15, -7.5 });
    try expectCurve(curves[3], .{ 15, -7.5 }, .{ 17.5, -7.5 }, .{ 20, 0 });
}

test "smooth_cubic_to without a preceding cubic starts at the current point" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = testPath(&.{
        .{ .move_to = .{ .abs = true, .x = 5, .y = 5 } },
        // No preceding cubic: the implicit first control is the current
        // point (SVG 2 §8.3.8) — the first conic degenerates toward it.
        .{ .smooth_cubic_to = .{ .abs = true, .x2 = 15, .y2 = 15, .x = 15, .y = 5 } },
    }, .{ .x = 5, .y = 5, .w = 10, .h = 10 });
    const curves = (try convertPath(a, &path)).?;
    try testing.expectEqual(@as(usize, 2), curves.len);
    // The split's shared point is the curve's midpoint B(0.5) = (10, 8.75);
    // the second conic's control is the de Casteljau midpoint (12.5, 10).
    try expectCurve(curves[0], .{ 5, 5 }, .{ 5, 5 }, .{ 10, 8.75 });
    try expectCurve(curves[1], .{ 10, 8.75 }, .{ 12.5, 10 }, .{ 15, 5 });
}

test "relative horizontal/vertical and close_path resolve against the current point" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = testPath(&.{
        .{ .move_to = .{ .abs = false, .x = 1, .y = 1 } },
        .{ .horizontal_to = .{ .abs = false, .x = 5 } },
        .{ .vertical_to = .{ .abs = false, .y = -2 } },
        .{ .close_path = {} },
    }, .{ .x = 1, .y = -1, .w = 5, .h = 2 });
    const curves = (try convertPath(a, &path)).?;
    try testing.expectEqual(@as(usize, 3), curves.len);
    try expectCurve(curves[0], .{ 1, 1 }, .{ 3.5, 1 }, .{ 6, 1 });
    try expectCurve(curves[1], .{ 6, 1 }, .{ 6, 0 }, .{ 6, -1 });
    // close_path: the line back to the subpath start (1, 1).
    try expectCurve(curves[2], .{ 6, -1 }, .{ 3.5, 0 }, .{ 1, 1 });
}

test "unsupported commands skip the path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A quadratic anywhere in the path skips the WHOLE path.
    const quad = testPath(&.{
        .{ .move_to = .{ .abs = true, .x = 0, .y = 0 } },
        .{ .quadratic_to = .{ .abs = true, .x1 = 5, .y1 = 5, .x = 10, .y = 0 } },
    }, .{ .x = 0, .y = 0, .w = 10, .h = 5 });
    try testing.expectEqual(@as(?[]Curve, null), try convertPath(a, &quad));
    const arc = testPath(&.{
        .{ .move_to = .{ .abs = true, .x = 0, .y = 0 } },
        .{ .arc_to = .{
            .abs = true,
            .rx = 5,
            .ry = 5,
            .x_axis_rotation = 0,
            .large_arc_flag = false,
            .sweep_flag = true,
            .x = 10,
            .y = 0,
        } },
    }, .{ .x = 0, .y = 0, .w = 10, .h = 5 });
    try testing.expectEqual(@as(?[]Curve, null), try convertPath(a, &arc));
}

test "rebaseToBbox flips y about the bbox top-left" {
    const src = [_]Curve{
        .{ .p0x = 2, .p0y = 3, .p1x = 5, .p1y = 7, .p2x = 8, .p2y = 3 },
    };
    var out: [1]Curve = undefined;
    // bbox (2, 3, 6, 4): top-left (2,3) → sweep (0,0); the bottom-right
    // (8,7) → (6, -4); y UP — the ink hangs below the origin.
    rebaseToBbox(&src, .{ .x = 2, .y = 3, .w = 6, .h = 4 }, &out);
    try expectCurve(out[0], .{ 0, 0 }, .{ 3, -4 }, .{ 6, 0 });
}

// The setScale stroke-edge regression: the mode-2 edge buffers must be
// RE-DERIVED from the pristine buildStrokeOutline output (the curves'
// `self.curves` pattern), never scaled in place — the in-place
// `*= scale` loop compounded across setScale calls (each frame's fit
// scale while the stroke-scale slider moves), over-scaling the mode-2
// strokes after any second scale change.
test "setScale re-derives the stroke edges from the pristine outline" {
    // buildStrokeOutline's sweep-space output at init: two vertical band
    // edges at x = 10 and x = 20.
    const pristine = [_]StrokeEdge{
        .{ .x0 = 10, .y0 = 0, .x1 = 10, .y1 = 100 },
        .{ .x0 = 20, .y0 = 0, .x1 = 20, .y1 = 100 },
    };
    // THE BUG (the old in-place loop): each setScale multiplies the
    // ALREADY-scaled buffer values, so successive calls compound —
    // [10, 20] *= 1.5 then *= 2.0 yields 30, 60 instead of the 20, 40
    // pristine * 2.0.
    var buf = pristine; // the GPU buffer starts as a copy of the pristine
    for ([_]f32{ 1.5, 2.0 }) |s| {
        for (&buf) |*e| {
            e.x0 *= s;
            e.y0 *= s;
            e.x1 *= s;
            e.y1 *= s;
        }
    }
    try testing.expectEqual(@as(f32, 30), buf[0].x0);
    try testing.expectEqual(@as(f32, 60), buf[1].x0);
    // THE FIX (the setScale loop): edges[i] = pristine[i] * scale — the
    // buffer is a pure function of the last scale, no accumulation.
    buf = pristine;
    for ([_]f32{ 1.5, 2.0 }) |s| {
        for (&buf, 0..) |*e, i| {
            e.x0 = pristine[i].x0 * s;
            e.y0 = pristine[i].y0 * s;
            e.x1 = pristine[i].x1 * s;
            e.y1 = pristine[i].y1 * s;
        }
    }
    try testing.expectEqual(@as(f32, 20), buf[0].x0);
    try testing.expectEqual(@as(f32, 40), buf[1].x0);
    // The round trip the stroke-scale slider produces (fit 1.0 -> 2.0 ->
    // 1.0): the fixed loop returns the edges to the ORIGINAL; the buggy
    // loop left them at 2x (20, 40).
    buf = pristine;
    for ([_]f32{ 1.0, 2.0, 1.0 }) |s| {
        for (&buf, 0..) |*e, i| {
            e.x0 = pristine[i].x0 * s;
            e.y0 = pristine[i].y0 * s;
            e.x1 = pristine[i].x1 * s;
            e.y1 = pristine[i].y1 * s;
        }
    }
    try testing.expectEqual(pristine[0].x0, buf[0].x0);
    try testing.expectEqual(pristine[1].x0, buf[1].x0);
}
