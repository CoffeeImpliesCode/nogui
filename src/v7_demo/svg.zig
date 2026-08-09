//! XML-independent SVG parsing core for the v7 demo.
//!
//! Consumes only the *content* of an SVG `d` attribute (a `[]const u8`),
//! so the module has no XML dependency: an XML layer (TBD, see
//! notes/research/svg2-spec.html §Path Data) extracts the attribute and
//! hands the string to `parsePath`.
//!
//! Implements the SVG 2 path-data grammar: the command letters, the
//! whitespace/comma separators (comma-wsp), the signed numbers with
//! exponents, the mandatory leading moveto (every command group starts
//! with M/m; after Z/z only a new moveto may follow), the implicit-lineto
//! repetition after moveto, the per-command
//! argument repetition, the single-digit arc flags (no separator between
//! them), the relative variants, and Z/z with no arguments. Malformed
//! input returns `error.InvalidPathData` — this module never panics.
//!
//! Separator policy (per the grammar's comma-wsp, which only ever sits
//! BETWEEN elements): trailing whitespace is fine; a trailing comma is a
//! grammar violation ("M10 10," and "M10 10, L5 5" error), matching the
//! SVG 2 EBNF. A decimal point must be followed by a digit ("23." errors,
//! ".5" is fine). Numbers that overflow f32 are rejected, and resolved or
//! reflected coordinates that overflow f32 are skipped by the bounding
//! box, so it stays finite.
//!
//! Everything the parser produces lives in an arena owned by `SvgPath`:
//! `deinit` releases the whole document in one free.
//!
//! Demo-side only: like text.zig, this file MAY import the v7 core.

const std = @import("std");
const Rect = @import("v7/widget.zig").Rect;

/// A point in user space.
const Point = struct { x: f32 = 0, y: f32 = 0 };

/// Parsing/ownership failures from `parsePath`.
pub const ParseError = error{
    /// The path data does not match the SVG 2 path-data grammar.
    InvalidPathData,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Document model
// ---------------------------------------------------------------------------

pub const MoveTo = struct { abs: bool, x: f32, y: f32 };
pub const LineTo = struct { abs: bool, x: f32, y: f32 };
pub const HorizontalTo = struct { abs: bool, x: f32 };
pub const VerticalTo = struct { abs: bool, y: f32 };
pub const CubicTo = struct { abs: bool, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32 };
pub const SmoothCubicTo = struct { abs: bool, x2: f32, y2: f32, x: f32, y: f32 };
pub const QuadraticTo = struct { abs: bool, x1: f32, y1: f32, x: f32, y: f32 };
pub const SmoothQuadraticTo = struct { abs: bool, x: f32, y: f32 };
pub const ArcTo = struct {
    abs: bool,
    rx: f32,
    ry: f32,
    x_axis_rotation: f32,
    large_arc_flag: bool,
    sweep_flag: bool,
    x: f32,
    y: f32,
};

/// One path-data command. Coordinate values are stored exactly as written
/// (raw, relative values for the lowercase variants); `abs` says which
/// variant produced the command. A consumer resolves relative values
/// against the current point, advancing it exactly as `parsePath` does
/// (see the bbox code here for the resolution rules).
pub const Command = union(enum) {
    move_to: MoveTo,
    line_to: LineTo,
    horizontal_to: HorizontalTo,
    vertical_to: VerticalTo,
    cubic_to: CubicTo,
    smooth_cubic_to: SmoothCubicTo,
    quadratic_to: QuadraticTo,
    smooth_quadratic_to: SmoothQuadraticTo,
    arc_to: ArcTo,
    close_path: void,
};

/// A parsed path: arena-owned command list plus a conservative bounding
/// box in user space (house `Rect`: x/y = top-left, w/h = extents).
pub const SvgPath = struct {
    commands: []Command, // owned by `arena`
    bbox: Rect, // conservative bounds over the whole path; (0,0,0,0) when empty
    arena: std.heap.ArenaAllocator, // owns `commands` and any future doc data

    /// Release everything the path owns.
    pub fn deinit(self: *SvgPath) void {
        self.arena.deinit();
    }
};

// ---------------------------------------------------------------------------
// Bounding box
// ---------------------------------------------------------------------------

/// Accumulator over the path's resolved (absolute) geometry.
const BBox = struct {
    x0: f32 = std.math.inf(f32),
    y0: f32 = std.math.inf(f32),
    x1: f32 = -std.math.inf(f32),
    y1: f32 = -std.math.inf(f32),

    fn isEmpty(self: BBox) bool {
        return self.x0 > self.x1;
    }

    fn includePoint(self: *BBox, x: f32, y: f32) void {
        // Resolving relative coordinates and reflecting smooth control
        // points can overflow f32 (e.g. 2*about - p) even when every input
        // was finite; skip the non-finite values so the bbox stays finite.
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return;
        self.x0 = @min(self.x0, x);
        self.y0 = @min(self.y0, y);
        self.x1 = @max(self.x1, x);
        self.y1 = @max(self.y1, y);
    }

    fn include(self: *BBox, p: Point) void {
        self.includePoint(p.x, p.y);
    }

    fn toRect(self: BBox) Rect {
        if (self.isEmpty()) return .{};
        return .{ .x = self.x0, .y = self.y0, .w = self.x1 - self.x0, .h = self.y1 - self.y0 };
    }
};

/// Resolve a (possibly relative) coordinate pair against the current point.
fn resolve(raw: Point, cur: Point, abs: bool) Point {
    return if (abs) raw else Point{ .x = cur.x + raw.x, .y = cur.y + raw.y };
}

/// Reflect `p` about `about` — the implicit first control point of a smooth
/// curve command (SVG 2 §8.3.8/§8.3.9).
fn reflect(p: Point, about: Point) Point {
    return .{ .x = 2 * about.x - p.x, .y = 2 * about.y - p.y };
}

/// State the parser must carry across commands.
const ParseState = struct {
    cur: Point = .{}, // current point (absolute, resolved)
    subpath_start: Point = .{}, // initial point of the current subpath
    prev: PrevCurve = .{}, // last curve's control point, for smooth reflection
};

const PrevCurve = struct {
    kind: enum { none, cubic, quad } = .none,
    cp2: Point = .{}, // last cubic/smooth-cubic second control point (resolved)
    cp: Point = .{}, // last quadratic/smooth-quadratic control point (resolved)
};

/// Add the arc's contribution to the bbox.
///
/// APPROXIMATION: the arc lies on an ellipse with semi-axes rx/ry rotated
/// by `x_axis_rotation`, but which arc (short/long, clockwise/ccw) is
/// selected by the flags. Instead of the flag-dependent endpoint-to-center
/// disambiguation plus the angular-span check against the ellipse extrema,
/// we take the union of the bounding boxes of BOTH candidate ellipses
/// (the two centers the endpoint-to-center conversion yields). That union
/// is always a superset of the true arc and needs only the endpoints, the
/// radii, and the rotation. Out-of-range radii are scaled up exactly as
/// the spec's rendering correction does (F.6.6.2/F.6.6.4), so the box
/// still covers the arc the renderer will actually draw.
fn includeArc(bbox: *BBox, p0: Point, p1: Point, rx: f32, ry: f32, rot_deg: f32) void {
    bbox.include(p0);
    bbox.include(p1);
    // F.6.6.1: identical endpoints — the arc is omitted entirely.
    if (p0.x == p1.x and p0.y == p1.y) return;
    // F.6.6.2: a zero radius degenerates the arc into a straight line.
    if (rx == 0 or ry == 0) return;

    const phi = rot_deg * std.math.pi / 180.0;
    const cos_p = @cos(phi);
    const sin_p = @sin(phi);
    const x1p = cos_p * (p0.x - p1.x) / 2 + sin_p * (p0.y - p1.y) / 2;
    const y1p = -sin_p * (p0.x - p1.x) / 2 + cos_p * (p0.y - p1.y) / 2;
    const rx2 = rx * rx;
    const ry2 = ry * ry;
    var rxx = rx;
    var ryy = ry;
    // F.6.6.4: radii too small for the chord — scale up uniformly.
    const lam = x1p * x1p / rx2 + y1p * y1p / ry2;
    if (lam > 1) {
        const k = @sqrt(lam);
        rxx = rx * k;
        ryy = ry * k;
    }
    const rxx2 = rxx * rxx;
    const ryy2 = ryy * ryy;
    // Ellipse extents around its center (max |x-cx|, max |y-cy|).
    const hw_x = @sqrt(rxx2 * cos_p * cos_p + ryy2 * sin_p * sin_p);
    const hw_y = @sqrt(rxx2 * sin_p * sin_p + ryy2 * cos_p * cos_p);
    // Endpoint-to-center conversion (F.6.5.2): the ± solution yields the
    // two candidate centers; both are unioned below.
    const denom = rxx2 * y1p * y1p + ryy2 * x1p * x1p;
    const radicand = (rxx2 * ryy2 - rxx2 * y1p * y1p - ryy2 * x1p * x1p) / denom;
    const c = @sqrt(@max(radicand, 0));
    const cx_off = cos_p * (rxx * y1p / ryy) * c - sin_p * (-(ryy * x1p / rxx) * c);
    const cy_off = sin_p * (rxx * y1p / ryy) * c + cos_p * (-(ryy * x1p / rxx) * c);
    const mx = (p0.x + p1.x) / 2;
    const my = (p0.y + p1.y) / 2;
    const min_cx = @min(mx + cx_off, mx - cx_off);
    const max_cx = @max(mx + cx_off, mx - cx_off);
    const min_cy = @min(my + cy_off, my - cy_off);
    const max_cy = @max(my + cy_off, my - cy_off);
    bbox.includePoint(min_cx - hw_x, min_cy - hw_y);
    bbox.includePoint(max_cx + hw_x, max_cy + hw_y);
}

// ---------------------------------------------------------------------------
// Grammar primitives
// ---------------------------------------------------------------------------

fn isWsp(c: u8) bool {
    // wsp: space, tab, line feed, form feed, carriage return (SVG 2 §8.3.1).
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0c or c == '\r';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// A token that can begin a number: digit, '.', '+' or '-'. Everything
/// else is either a command letter, a separator, or the end of the data.
fn isNumberStart(c: u8) bool {
    return isDigit(c) or c == '.' or c == '+' or c == '-';
}

/// Byte cursor over the path data. Never panics: every scan validates
/// against the grammar and returns `error.InvalidPathData`.
const Parser = struct {
    data: []const u8,
    i: usize = 0,

    fn peek(self: *const Parser) ?u8 {
        return if (self.i < self.data.len) self.data[self.i] else null;
    }

    /// Consume `wsp*` (no commas allowed here — a comma right after a
    /// command letter is a grammar violation).
    fn skipWsp(self: *Parser) void {
        while (self.peek()) |c| {
            if (!isWsp(c)) break;
            self.i += 1;
        }
    }

    /// Consume one comma-wsp: `(wsp+ comma? wsp*) | (comma wsp*)`.
    fn skipCommaWsp(self: *Parser) void {
        while (self.peek()) |c| {
            if (!isWsp(c)) break;
            self.i += 1;
        }
        if (self.peek() == ',') {
            self.i += 1;
            while (self.peek()) |c| {
                if (!isWsp(c)) break;
                self.i += 1;
            }
        }
    }

    /// Scan one `number` (sign allowed) or `nonnegative-number` (no sign),
    /// per the grammar:
    ///   number: sign? floating-point-constant
    ///   floating-point-constant: fractional-constant exponent? | digit-sequence exponent
    /// Maximal munch: "M10-10" is (10, -10), "M0.6.5" is (0.6, 0.5), both
    /// matching browser behavior.
    fn scanNumber(self: *Parser, allow_sign: bool) !f32 {
        const start = self.i;
        if (allow_sign) {
            if (self.peek()) |c| {
                if (c == '+' or c == '-') self.i += 1;
            }
        }
        var int_digits: usize = 0;
        while (self.peek()) |c| {
            if (!isDigit(c)) break;
            int_digits += 1;
            self.i += 1;
        }
        var frac_digits: usize = 0;
        var dot_consumed = false;
        if (self.peek() == '.') {
            dot_consumed = true;
            self.i += 1;
            while (self.peek()) |c| {
                if (!isDigit(c)) break;
                frac_digits += 1;
                self.i += 1;
            }
        }
        var exp_consumed = false;
        var exp_digits: usize = 0;
        if (self.peek()) |c| {
            if (c == 'e' or c == 'E') {
                exp_consumed = true;
                self.i += 1;
                if (self.peek()) |s| {
                    if (s == '+' or s == '-') self.i += 1;
                }
                while (self.peek()) |d| {
                    if (!isDigit(d)) break;
                    exp_digits += 1;
                    self.i += 1;
                }
            }
        }
        if (int_digits == 0 and frac_digits == 0) return error.InvalidPathData;
        // A decimal point must be followed by a digit: "23." and "." are
        // invalid (per the WPT number-error-trailing-decimal tests), while
        // ".5" and "23.5" are fine.
        if (dot_consumed and frac_digits == 0) return error.InvalidPathData;
        if (exp_consumed and exp_digits == 0) return error.InvalidPathData;
        const v = std.fmt.parseFloat(f32, self.data[start..self.i]) catch return error.InvalidPathData;
        // Reject values that overflow f32: a non-finite coordinate would
        // poison the bounding box (NaN extents) and every consumer of it.
        if (!std.math.isFinite(v)) return error.InvalidPathData;
        return v;
    }

    fn parseNumber(self: *Parser) !f32 {
        return self.scanNumber(true);
    }

    fn parseNonnegativeNumber(self: *Parser) !f32 {
        return self.scanNumber(false);
    }

    /// A flag is exactly one digit: "0" or "1". The two arc flags may be
    /// written adjacent ("01") — no separator between them — or with a
    /// comma-wsp, per the grammar `flag comma-wsp? flag`.
    fn parseFlag(self: *Parser) !bool {
        const c = self.peek() orelse return error.InvalidPathData;
        switch (c) {
            '0' => {
                self.i += 1;
                return false;
            },
            '1' => {
                self.i += 1;
                return true;
            },
            else => return error.InvalidPathData,
        }
    }

    /// coordinate-pair: coordinate comma-wsp? coordinate
    fn parseCoordinatePair(self: *Parser) !Point {
        const x = try self.parseNumber();
        self.skipCommaWsp();
        const y = try self.parseNumber();
        return .{ .x = x, .y = y };
    }
};

// ---------------------------------------------------------------------------
// Command parsing
// ---------------------------------------------------------------------------

const Ctx = struct {
    list: *std.ArrayList(Command),
    alloc: std.mem.Allocator,
    st: *ParseState,
    bbox: *BBox,
};

/// Whether the next token starts another repeated argument group.
///
/// A separator is only consumed when a number actually follows it. A
/// trailing comma or a comma before a command letter is then left in the
/// stream for the main loop, which rejects it: comma-wsp exists only
/// BETWEEN elements of the grammar, so "M10 10," and "M10 10, L5 5" are
/// path-data errors.
fn moreArguments(p: *Parser) bool {
    const save = p.i;
    p.skipCommaWsp();
    if (p.peek()) |c| {
        if (isNumberStart(c)) return true;
    }
    p.i = save;
    return false;
}

fn parseMoveto(p: *Parser, ctx: Ctx, abs: bool) !void {
    // moveto: ("M" | "m") wsp* moveto-argument-sequence
    p.skipWsp();
    var pair = try p.parseCoordinatePair();
    var r = resolve(pair, ctx.st.cur, abs);
    try ctx.list.append(ctx.alloc, .{ .move_to = .{ .abs = abs, .x = pair.x, .y = pair.y } });
    ctx.st.cur = r;
    ctx.st.subpath_start = r;
    ctx.st.prev = .{};
    ctx.bbox.include(r);
    // Implicit repetition: the coordinate pairs following a moveto are
    // lineto commands on the same path (SVG 2 §8.3.3), sharing its abs/rel
    // variant. Each pair is relative to the point the previous pair moved to.
    while (moreArguments(p)) {
        pair = try p.parseCoordinatePair();
        r = resolve(pair, ctx.st.cur, abs);
        try ctx.list.append(ctx.alloc, .{ .line_to = .{ .abs = abs, .x = pair.x, .y = pair.y } });
        ctx.bbox.include(ctx.st.cur);
        ctx.bbox.include(r);
        ctx.st.cur = r;
    }
}

fn parseLineto(p: *Parser, ctx: Ctx, abs: bool) !void {
    // lineto: ("L" | "l") wsp* lineto-argument-sequence
    p.skipWsp();
    while (true) {
        const pair = try p.parseCoordinatePair();
        const r = resolve(pair, ctx.st.cur, abs);
        try ctx.list.append(ctx.alloc, .{ .line_to = .{ .abs = abs, .x = pair.x, .y = pair.y } });
        ctx.bbox.include(ctx.st.cur);
        ctx.bbox.include(r);
        ctx.st.cur = r;
        ctx.st.prev = .{};
        if (!moreArguments(p)) break;
    }
}

fn parseHorizontal(p: *Parser, ctx: Ctx, abs: bool) !void {
    // horizontal-lineto: ("H" | "h") wsp* horizontal-lineto-argument-sequence
    p.skipWsp();
    while (true) {
        const x = try p.parseNumber();
        const rx = if (abs) x else ctx.st.cur.x + x;
        try ctx.list.append(ctx.alloc, .{ .horizontal_to = .{ .abs = abs, .x = x } });
        ctx.bbox.include(ctx.st.cur);
        ctx.bbox.includePoint(rx, ctx.st.cur.y);
        ctx.st.cur.x = rx;
        ctx.st.prev = .{};
        if (!moreArguments(p)) break;
    }
}

fn parseVertical(p: *Parser, ctx: Ctx, abs: bool) !void {
    // vertical-lineto: ("V" | "v") wsp* vertical-lineto-argument-sequence
    p.skipWsp();
    while (true) {
        const y = try p.parseNumber();
        const ry = if (abs) y else ctx.st.cur.y + y;
        try ctx.list.append(ctx.alloc, .{ .vertical_to = .{ .abs = abs, .y = y } });
        ctx.bbox.include(ctx.st.cur);
        ctx.bbox.includePoint(ctx.st.cur.x, ry);
        ctx.st.cur.y = ry;
        ctx.st.prev = .{};
        if (!moreArguments(p)) break;
    }
}

fn parseCubic(p: *Parser, ctx: Ctx, abs: bool) !void {
    // curveto: ("C" | "c") wsp* curveto-argument-sequence; each argument is
    // three coordinate pairs: control 1, control 2, endpoint.
    p.skipWsp();
    while (true) {
        const c1 = try p.parseCoordinatePair();
        p.skipCommaWsp();
        const c2 = try p.parseCoordinatePair();
        p.skipCommaWsp();
        const end = try p.parseCoordinatePair();
        const r1 = resolve(c1, ctx.st.cur, abs);
        const r2 = resolve(c2, ctx.st.cur, abs);
        const rend = resolve(end, ctx.st.cur, abs);
        try ctx.list.append(ctx.alloc, .{ .cubic_to = .{
            .abs = abs,
            .x1 = c1.x,
            .y1 = c1.y,
            .x2 = c2.x,
            .y2 = c2.y,
            .x = end.x,
            .y = end.y,
        } });
        // Conservative: the curve lies inside the convex hull of its control
        // points, so the four points bound it. The exact bbox would require
        // solving the derivative for the extrema; the control-point hull is
        // cheap and always valid.
        ctx.bbox.include(ctx.st.cur);
        ctx.bbox.include(r1);
        ctx.bbox.include(r2);
        ctx.bbox.include(rend);
        ctx.st.cur = rend;
        ctx.st.prev = .{ .kind = .cubic, .cp2 = r2 };
        if (!moreArguments(p)) break;
    }
}

fn parseSmoothCubic(p: *Parser, ctx: Ctx, abs: bool) !void {
    // smooth-curveto: ("S" | "s") wsp* smooth-curveto-argument-sequence;
    // each argument is two coordinate pairs: control 2, endpoint.
    p.skipWsp();
    while (true) {
        const c2 = try p.parseCoordinatePair();
        p.skipCommaWsp();
        const end = try p.parseCoordinatePair();
        const r2 = resolve(c2, ctx.st.cur, abs);
        const rend = resolve(end, ctx.st.cur, abs);
        // Control 1 is the reflection of the previous curve's control 2
        // about the current point; without a preceding cubic, it is the
        // current point itself (SVG 2 §8.3.8).
        const r1 = if (ctx.st.prev.kind == .cubic) reflect(ctx.st.prev.cp2, ctx.st.cur) else ctx.st.cur;
        try ctx.list.append(ctx.alloc, .{ .smooth_cubic_to = .{ .abs = abs, .x2 = c2.x, .y2 = c2.y, .x = end.x, .y = end.y } });
        // The reflected control point can lie outside the hull of the other
        // three points, so include it explicitly to keep the bound valid.
        ctx.bbox.include(ctx.st.cur);
        ctx.bbox.include(r1);
        ctx.bbox.include(r2);
        ctx.bbox.include(rend);
        ctx.st.cur = rend;
        ctx.st.prev = .{ .kind = .cubic, .cp2 = r2 };
        if (!moreArguments(p)) break;
    }
}

fn parseQuadratic(p: *Parser, ctx: Ctx, abs: bool) !void {
    // quadratic-bezier-curveto: ("Q" | "q") wsp*
    // quadratic-bezier-curveto-argument-sequence; each argument is two
    // coordinate pairs: control, endpoint.
    p.skipWsp();
    while (true) {
        const c = try p.parseCoordinatePair();
        p.skipCommaWsp();
        const end = try p.parseCoordinatePair();
        const rc = resolve(c, ctx.st.cur, abs);
        const rend = resolve(end, ctx.st.cur, abs);
        try ctx.list.append(ctx.alloc, .{ .quadratic_to = .{ .abs = abs, .x1 = c.x, .y1 = c.y, .x = end.x, .y = end.y } });
        ctx.bbox.include(ctx.st.cur);
        ctx.bbox.include(rc);
        ctx.bbox.include(rend);
        ctx.st.cur = rend;
        ctx.st.prev = .{ .kind = .quad, .cp = rc };
        if (!moreArguments(p)) break;
    }
}

fn parseSmoothQuadratic(p: *Parser, ctx: Ctx, abs: bool) !void {
    // smooth-quadratic-bezier-curveto: ("T" | "t") wsp*
    // smooth-quadratic-bezier-curveto-argument-sequence; each argument is
    // one coordinate pair: the endpoint.
    p.skipWsp();
    while (true) {
        const end = try p.parseCoordinatePair();
        const rend = resolve(end, ctx.st.cur, abs);
        // Control is the reflection of the previous quadratic's control
        // about the current point; without a preceding quadratic it is the
        // current point itself (SVG 2 §8.3.9).
        const rc = if (ctx.st.prev.kind == .quad) reflect(ctx.st.prev.cp, ctx.st.cur) else ctx.st.cur;
        try ctx.list.append(ctx.alloc, .{ .smooth_quadratic_to = .{ .abs = abs, .x = end.x, .y = end.y } });
        ctx.bbox.include(ctx.st.cur);
        ctx.bbox.include(rc);
        ctx.bbox.include(rend);
        ctx.st.cur = rend;
        ctx.st.prev = .{ .kind = .quad, .cp = rc };
        if (!moreArguments(p)) break;
    }
}

fn parseArc(p: *Parser, ctx: Ctx, abs: bool) !void {
    // elliptical-arc: ("A" | "a") wsp* elliptical-arc-argument-sequence;
    // each argument: rx ry x-axis-rotation large-arc-flag sweep-flag x y.
    // rx/ry are nonnegative (a sign is a grammar violation); the flags are
    // single digits written with no separator between them ("01") or with a
    // comma-wsp.
    p.skipWsp();
    while (true) {
        const rx = try p.parseNonnegativeNumber();
        p.skipCommaWsp();
        const ry = try p.parseNonnegativeNumber();
        p.skipCommaWsp();
        const rot = try p.parseNumber();
        p.skipCommaWsp();
        const large = try p.parseFlag();
        p.skipCommaWsp();
        const sweep = try p.parseFlag();
        p.skipCommaWsp();
        const end = try p.parseCoordinatePair();
        const rend = resolve(end, ctx.st.cur, abs);
        try ctx.list.append(ctx.alloc, .{ .arc_to = .{
            .abs = abs,
            .rx = rx,
            .ry = ry,
            .x_axis_rotation = rot,
            .large_arc_flag = large,
            .sweep_flag = sweep,
            .x = end.x,
            .y = end.y,
        } });
        includeArc(ctx.bbox, ctx.st.cur, rend, rx, ry, rot);
        ctx.st.cur = rend;
        ctx.st.prev = .{};
        if (!moreArguments(p)) break;
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Parse SVG path data (`d` attribute content) into an arena-owned command
/// list plus a conservative bounding box. See the module doc for the
/// grammar coverage; malformed input yields `error.InvalidPathData`.
pub fn parsePath(allocator: std.mem.Allocator, data: []const u8) ParseError!SvgPath {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var list = std.ArrayList(Command).empty;
    var bbox = BBox{};
    var st = ParseState{};
    var p = Parser{ .data = data };
    const ctx = Ctx{ .list = &list, .alloc = a, .st = &st, .bbox = &bbox };

    p.skipWsp();
    // Every command group starts with a moveto (SVG 2 §8.3.1): the first
    // command must be M/m, and a closepath ends the group, so the command
    // after Z/z must be a moveto too. `moveto_seen` tracks that.
    var moveto_seen = false;
    while (true) {
        const c = p.peek() orelse break;
        // A non-moveto command with no moveto before it (including after a
        // closepath) is a grammar violation, never an implicit (0,0) start.
        if (c != 'M' and c != 'm' and !moveto_seen) return error.InvalidPathData;
        switch (c) {
            'M' => {
                p.i += 1;
                try parseMoveto(&p, ctx, true);
                moveto_seen = true;
            },
            'm' => {
                p.i += 1;
                try parseMoveto(&p, ctx, false);
                moveto_seen = true;
            },
            'L' => {
                p.i += 1;
                try parseLineto(&p, ctx, true);
            },
            'l' => {
                p.i += 1;
                try parseLineto(&p, ctx, false);
            },
            'H' => {
                p.i += 1;
                try parseHorizontal(&p, ctx, true);
            },
            'h' => {
                p.i += 1;
                try parseHorizontal(&p, ctx, false);
            },
            'V' => {
                p.i += 1;
                try parseVertical(&p, ctx, true);
            },
            'v' => {
                p.i += 1;
                try parseVertical(&p, ctx, false);
            },
            'C' => {
                p.i += 1;
                try parseCubic(&p, ctx, true);
            },
            'c' => {
                p.i += 1;
                try parseCubic(&p, ctx, false);
            },
            'S' => {
                p.i += 1;
                try parseSmoothCubic(&p, ctx, true);
            },
            's' => {
                p.i += 1;
                try parseSmoothCubic(&p, ctx, false);
            },
            'Q' => {
                p.i += 1;
                try parseQuadratic(&p, ctx, true);
            },
            'q' => {
                p.i += 1;
                try parseQuadratic(&p, ctx, false);
            },
            'T' => {
                p.i += 1;
                try parseSmoothQuadratic(&p, ctx, true);
            },
            't' => {
                p.i += 1;
                try parseSmoothQuadratic(&p, ctx, false);
            },
            'A' => {
                p.i += 1;
                try parseArc(&p, ctx, true);
            },
            'a' => {
                p.i += 1;
                try parseArc(&p, ctx, false);
            },
            'Z', 'z' => {
                // closepath takes no arguments; the current point returns
                // to the initial point of the current subpath.
                p.i += 1;
                st.cur = st.subpath_start;
                st.prev = .{};
                try list.append(a, .close_path);
                // The next command must start a new subpath with a moveto.
                moveto_seen = false;
            },
            else => return error.InvalidPathData,
        }
        p.skipWsp();
    }

    return .{
        .commands = try list.toOwnedSlice(a),
        .bbox = bbox.toRect(),
        .arena = arena,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "M10 10 L20 20 Z: command types and bounding box" {
    const t = std.testing;
    var path = try parsePath(t.allocator, "M10 10 L20 20 Z");
    defer path.deinit();
    try t.expectEqual(@as(usize, 3), path.commands.len);
    try t.expectEqual(Command{ .move_to = .{ .abs = true, .x = 10, .y = 10 } }, path.commands[0]);
    try t.expectEqual(Command{ .line_to = .{ .abs = true, .x = 20, .y = 20 } }, path.commands[1]);
    try t.expectEqual(Command.close_path, path.commands[2]);
    try t.expectEqual(Rect{ .x = 10, .y = 10, .w = 10, .h = 10 }, path.bbox);
}

test "implicit lineto repetition after moveto" {
    const t = std.testing;
    var path = try parsePath(t.allocator, "M0 0 10 10 20 0");
    defer path.deinit();
    try t.expectEqual(@as(usize, 3), path.commands.len);
    try t.expectEqual(Command{ .move_to = .{ .abs = true, .x = 0, .y = 0 } }, path.commands[0]);
    try t.expectEqual(Command{ .line_to = .{ .abs = true, .x = 10, .y = 10 } }, path.commands[1]);
    try t.expectEqual(Command{ .line_to = .{ .abs = true, .x = 20, .y = 0 } }, path.commands[2]);
    try t.expectEqual(Rect{ .x = 0, .y = 0, .w = 20, .h = 10 }, path.bbox);
}

test "arc flags without separators" {
    const t = std.testing;
    // The path must start with a moveto (the grammar); the arc follows it.
    var path = try parsePath(t.allocator, "M0 0 A 5 5 0 0 1 10 10");
    defer path.deinit();
    try t.expectEqual(@as(usize, 2), path.commands.len);
    try t.expectEqual(Command{ .move_to = .{ .abs = true, .x = 0, .y = 0 } }, path.commands[0]);
    try t.expectEqual(Command{ .arc_to = .{
        .abs = true,
        .rx = 5,
        .ry = 5,
        .x_axis_rotation = 0,
        .large_arc_flag = false,
        .sweep_flag = true,
        .x = 10,
        .y = 10,
    } }, path.commands[1]);
    // The chord (0,0)->(10,10) is longer than the diameter (10), so the
    // radii are scaled up by sqrt(2) (F.6.6.4) and the arc bulges to
    // y = 5 - 5*sqrt(2) ~= -2.071. The conservative box is the scaled
    // ellipse's: center (5,5) +- 5*sqrt(2) on both axes.
    try t.expectApproxEqAbs(-2.0710678, path.bbox.x, 1e-4);
    try t.expectApproxEqAbs(-2.0710678, path.bbox.y, 1e-4);
    try t.expectApproxEqAbs(14.142136, path.bbox.w, 1e-4);
    try t.expectApproxEqAbs(14.142136, path.bbox.h, 1e-4);

    var adj = try parsePath(t.allocator, "M0 10 A 5 5 0 0110 20");
    defer adj.deinit();
    try t.expectEqual(Command{ .arc_to = .{
        .abs = true,
        .rx = 5,
        .ry = 5,
        .x_axis_rotation = 0,
        .large_arc_flag = false,
        .sweep_flag = true,
        .x = 10,
        .y = 20,
    } }, adj.commands[1]);
}

test "relative, smooth and quadratic commands" {
    const t = std.testing;
    var path = try parsePath(t.allocator, "m10 10 c 5 5 10 0 15 5 s 5 5 10 0 q 5 5 10 0 t 10 0");
    defer path.deinit();
    try t.expectEqual(@as(usize, 5), path.commands.len);
    try t.expectEqual(Command{ .move_to = .{ .abs = false, .x = 10, .y = 10 } }, path.commands[0]);
    try t.expectEqual(Command{ .cubic_to = .{ .abs = false, .x1 = 5, .y1 = 5, .x2 = 10, .y2 = 0, .x = 15, .y = 5 } }, path.commands[1]);
    try t.expectEqual(Command{ .smooth_cubic_to = .{ .abs = false, .x2 = 5, .y2 = 5, .x = 10, .y = 0 } }, path.commands[2]);
    try t.expectEqual(Command{ .quadratic_to = .{ .abs = false, .x1 = 5, .y1 = 5, .x = 10, .y = 0 } }, path.commands[3]);
    try t.expectEqual(Command{ .smooth_quadratic_to = .{ .abs = false, .x = 10, .y = 0 } }, path.commands[4]);
    // Bounds of the resolved geometry: min (10,10), max (55,20).
    try t.expectEqual(Rect{ .x = 10, .y = 10, .w = 45, .h = 10 }, path.bbox);
}

test "malformed input returns InvalidPathData" {
    const t = std.testing;
    try t.expectError(error.InvalidPathData, parsePath(t.allocator, "M 10 10 L"));
    // Trailing separators: comma-wsp only exists between elements, so a
    // trailing comma is a grammar violation (trailing whitespace is fine).
    try t.expectError(error.InvalidPathData, parsePath(t.allocator, "M10 10,"));
    try t.expectError(error.InvalidPathData, parsePath(t.allocator, "M10 10, L5 5"));
    // A decimal point must be followed by a digit (WPT-verified behavior).
    try t.expectError(error.InvalidPathData, parsePath(t.allocator, "M 10 10 L 23. 100"));
    // Values that overflow f32 would poison the bbox; reject them.
    try t.expectError(error.InvalidPathData, parsePath(t.allocator, "M 1e999 0"));
    // A comma right after the command letter is not part of the grammar
    // ("M" wsp* sequence — wsp only).
    try t.expectError(error.InvalidPathData, parsePath(t.allocator, "M,10 10"));
}

test "comma and whitespace separators" {
    const t = std.testing;
    var path = try parsePath(t.allocator, "M10,10 L20 20");
    defer path.deinit();
    try t.expectEqual(@as(usize, 2), path.commands.len);
    try t.expectEqual(Command{ .move_to = .{ .abs = true, .x = 10, .y = 10 } }, path.commands[0]);
    try t.expectEqual(Command{ .line_to = .{ .abs = true, .x = 20, .y = 20 } }, path.commands[1]);
    try t.expectEqual(Rect{ .x = 10, .y = 10, .w = 10, .h = 10 }, path.bbox);
}

test "scientific notation" {
    const t = std.testing;
    var path = try parsePath(t.allocator, "M 1.5e-3 0 L 0 1E2");
    defer path.deinit();
    try t.expectEqual(@as(usize, 2), path.commands.len);
    try t.expectEqual(Command{ .move_to = .{ .abs = true, .x = 0.0015, .y = 0 } }, path.commands[0]);
    try t.expectEqual(Command{ .line_to = .{ .abs = true, .x = 0, .y = 100 } }, path.commands[1]);
    try t.expectApproxEqAbs(0.0015, path.bbox.w, 1e-7);
    try t.expectApproxEqAbs(100.0, path.bbox.h, 1e-6);
}

test "empty path data is valid" {
    const t = std.testing;
    var path = try parsePath(t.allocator, "");
    defer path.deinit();
    try t.expectEqual(@as(usize, 0), path.commands.len);
    try t.expectEqual(Rect{}, path.bbox);
}

test "first command must be a moveto" {
    const t = std.testing;
    // Every command group starts with a moveto (SVG 2 §8.3.1): a drawto
    // command or a closepath without one is invalid, and after a closepath
    // only a new moveto may start the next subpath.
    try t.expectError(error.InvalidPathData, parsePath(t.allocator, "L 5 5"));
    try t.expectError(error.InvalidPathData, parsePath(t.allocator, "A 5 5 0 0 1 10 10"));
    try t.expectError(error.InvalidPathData, parsePath(t.allocator, "Z"));
    try t.expectError(error.InvalidPathData, parsePath(t.allocator, "M0 0 L5 5 Z L10 10"));
    try t.expectError(error.InvalidPathData, parsePath(t.allocator, "M0 0 Z Z"));
    // A closepath may be followed by a new moveto (a new subpath).
    var path = try parsePath(t.allocator, "M0 0 L5 5 Z M10 10 L20 20");
    defer path.deinit();
    try t.expectEqual(@as(usize, 5), path.commands.len);
    try t.expectEqual(Rect{ .x = 0, .y = 0, .w = 20, .h = 20 }, path.bbox);
}

test "form feed is path whitespace" {
    const t = std.testing;
    // wsp includes the form feed (SVG 2 §8.3.1), as a separator between
    // commands and between a command letter and its arguments.
    var path = try parsePath(t.allocator, "M0 0\x0cL5 5");
    defer path.deinit();
    try t.expectEqual(@as(usize, 2), path.commands.len);
    try t.expectEqual(Rect{ .x = 0, .y = 0, .w = 5, .h = 5 }, path.bbox);
    var mid = try parsePath(t.allocator, "M0 0 L\x0c5 5");
    defer mid.deinit();
    try t.expectEqual(@as(usize, 2), mid.commands.len);
}

test "resolved coordinates overflowing f32 stay out of the bbox" {
    const t = std.testing;
    // Every input is finite, but the resolved sum overflows f32 (6e38);
    // the bbox skips the non-finite point and stays finite.
    var path = try parsePath(t.allocator, "m 3e38 0 l 3e38 0");
    defer path.deinit();
    try t.expectEqual(@as(usize, 2), path.commands.len);
    try t.expect(std.math.isFinite(path.bbox.x));
    try t.expect(std.math.isFinite(path.bbox.y));
    try t.expect(std.math.isFinite(path.bbox.w));
    try t.expect(std.math.isFinite(path.bbox.h));
    try t.expectEqual(Rect{ .x = 3e38, .y = 0, .w = 0, .h = 0 }, path.bbox);
    // The smooth reflection 2*about - p can overflow the same way.
    var smooth = try parsePath(t.allocator, "m 3e38 0 q 0 0 0 0 t 3e38 0");
    defer smooth.deinit();
    try t.expectEqual(@as(usize, 3), smooth.commands.len);
    try t.expect(std.math.isFinite(smooth.bbox.x));
    try t.expect(std.math.isFinite(smooth.bbox.y));
    try t.expect(std.math.isFinite(smooth.bbox.w));
    try t.expect(std.math.isFinite(smooth.bbox.h));
}
