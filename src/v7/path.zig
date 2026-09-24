//! Frame-owned paths. The builder owns commands; tessellation writes into caller storage.
const std = @import("std");

pub const Point = struct { x: f32, y: f32 };
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
pub const Affine = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,

    pub fn apply(self: Affine, point: Point) Point {
        return .{
            .x = self.a * point.x + self.c * point.y + self.tx,
            .y = self.b * point.x + self.d * point.y + self.ty,
        };
    }
};

pub const FillRule = enum { nonzero, even_odd };
pub const Command = union(enum) {
    move: Point,
    line: Point,
    quadratic: struct { control: Point, end: Point },
    cubic: struct { first: Point, second: Point, end: Point },
    arc: struct { center: Point, radii: Point, start: f32, sweep: f32 },
    close: void,
};
pub const Path = struct { commands: []const Command };
pub const Quadratic = struct { p0: Point, p1: Point, p2: Point };
pub const Error = error{ PathCapacity, TessellationCapacity, InvalidPath } || std.mem.Allocator.Error;
pub const BuildError = error{ PathCapacity, InvalidPath } || std.mem.Allocator.Error;

pub const Builder = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(Command) = .empty,
    max_commands: usize,
    current: ?Point = null,
    start: ?Point = null,

    pub fn init(allocator: std.mem.Allocator, max_commands: usize) Builder {
        return .{ .allocator = allocator, .max_commands = max_commands };
    }

    pub fn deinit(self: *Builder) void {
        self.commands.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn path(self: *const Builder) Path {
        return .{ .commands = self.commands.items };
    }

    fn append(self: *Builder, command: Command) BuildError!void {
        if (self.commands.items.len >= self.max_commands) return error.PathCapacity;
        try self.commands.append(self.allocator, command);
    }

    pub fn moveTo(self: *Builder, point: Point) BuildError!void {
        if (!valid(point)) return error.InvalidPath;
        try self.append(.{ .move = point });
        self.current = point;
        self.start = point;
    }

    pub fn lineTo(self: *Builder, point: Point) BuildError!void {
        if (!valid(point) or self.current == null) return error.InvalidPath;
        try self.append(.{ .line = point });
        self.current = point;
    }

    pub fn quadraticTo(self: *Builder, control: Point, end: Point) BuildError!void {
        if (!valid(control) or !valid(end) or self.current == null) return error.InvalidPath;
        try self.append(.{ .quadratic = .{ .control = control, .end = end } });
        self.current = end;
    }

    pub fn cubicTo(self: *Builder, first: Point, second: Point, end: Point) BuildError!void {
        if (!valid(first) or !valid(second) or !valid(end) or self.current == null) {
            return error.InvalidPath;
        }
        try self.append(.{ .cubic = .{ .first = first, .second = second, .end = end } });
        self.current = end;
    }

    pub fn arc(
        self: *Builder,
        center: Point,
        radii: Point,
        angles: struct { start: f32, sweep: f32 },
    ) BuildError!void {
        if (!valid(center) or !valid(radii) or radii.x <= 0 or radii.y <= 0 or
            !std.math.isFinite(angles.start) or !std.math.isFinite(angles.sweep) or
            @abs(angles.sweep) > 2 * std.math.pi or self.current == null)
        {
            return error.InvalidPath;
        }
        if (angles.sweep == 0) return;
        const angle = angles.start + angles.sweep;
        const end: Point = .{
            .x = center.x + radii.x * @cos(angle),
            .y = center.y + radii.y * @sin(angle),
        };
        if (!valid(end)) return error.InvalidPath;
        try self.append(.{ .arc = .{
            .center = center,
            .radii = radii,
            .start = angles.start,
            .sweep = angles.sweep,
        } });
        self.current = end;
    }

    pub fn close(self: *Builder) BuildError!void {
        if (self.current == null or self.start == null) return error.InvalidPath;
        try self.append(.{ .close = {} });
        self.current = self.start;
    }
};

pub const Stroke = struct { width: f32, dash: []const f32 = &.{}, phase: f32 = 0 };
pub const Tessellation = struct {
    transform: Affine = .{},
    tolerance: f32 = 0.25,
    close_open: bool = false,
    stroke: ?Stroke = null,
};
pub const Geometry = struct {
    curves: []const Quadratic,
    bounds: Rect,
    pub fn len(self: Geometry) usize {
        return self.curves.len;
    }
};

const Sink = struct {
    output: []Quadratic,
    len: usize = 0,
    transform: Affine,
    stroke: ?Stroke,
    dash_index: usize = 0,
    dash_remaining: f32 = 0,
    dash_on: bool = true,
    min: Point = .{ .x = std.math.inf(f32), .y = std.math.inf(f32) },
    max: Point = .{ .x = -std.math.inf(f32), .y = -std.math.inf(f32) },

    fn add(self: *Sink, q: Quadratic) Error!void {
        if (self.len == self.output.len) return error.TessellationCapacity;
        const transformed: Quadratic = .{
            .p0 = self.transform.apply(q.p0),
            .p1 = self.transform.apply(q.p1),
            .p2 = self.transform.apply(q.p2),
        };
        for ([_]Point{ transformed.p0, transformed.p1, transformed.p2 }) |p| {
            if (!valid(p)) return error.InvalidPath;
            self.min.x = @min(self.min.x, p.x);
            self.min.y = @min(self.min.y, p.y);
            self.max.x = @max(self.max.x, p.x);
            self.max.y = @max(self.max.y, p.y);
        }
        self.output[self.len] = transformed;
        self.len += 1;
    }

    fn segment(self: *Sink, start: Point, end: Point) Error!void {
        const stroke = self.stroke orelse {
            try self.add(.{ .p0 = start, .p1 = midpoint(start, end), .p2 = end });
            return;
        };
        if (stroke.dash.len == 0) {
            try self.add(.{ .p0 = start, .p1 = midpoint(start, end), .p2 = end });
            return;
        }
        const delta = sub(end, start);
        const length = @sqrt(delta.x * delta.x + delta.y * delta.y);
        if (!std.math.isFinite(length)) return error.InvalidPath;
        if (length == 0) return;
        var position: f32 = 0;
        const intervals = std.math.mul(usize, self.output.len, 4) catch
            return error.TessellationCapacity;
        const skipped = std.math.mul(usize, stroke.dash.len, 2) catch
            return error.TessellationCapacity;
        const interval_limit = std.math.add(usize, intervals, skipped +| 16) catch
            return error.TessellationCapacity;
        var iterations: usize = 0;
        while (position < length) {
            if (iterations >= interval_limit) return error.TessellationCapacity;
            iterations += 1;
            const step = @min(self.dash_remaining, length - position);
            if (self.dash_on) {
                const from = mix(start, end, position / length);
                const to = mix(start, end, (position + step) / length);
                try self.add(.{ .p0 = from, .p1 = midpoint(from, to), .p2 = to });
            }
            const next = position + step;
            if (next <= position) return error.TessellationCapacity;
            position = next;
            self.dash_remaining -= step;
            if (self.dash_remaining <= 0) self.advanceDash(stroke.dash);
        }
    }

    fn advanceDash(self: *Sink, dash: []const f32) void {
        self.dash_index = (self.dash_index + 1) % dash.len;
        self.dash_on = !self.dash_on;
        self.dash_remaining = dash[self.dash_index];
    }
};

pub fn tessellate(shape: Path, output: []Quadratic, options: Tessellation) Error!Geometry {
    if (!std.math.isFinite(options.tolerance) or options.tolerance <= 0) return error.InvalidPath;
    const transform = [_]f32{
        options.transform.a,
        options.transform.b,
        options.transform.c,
        options.transform.d,
        options.transform.tx,
        options.transform.ty,
    };
    for (transform) |v| {
        if (!std.math.isFinite(v)) return error.InvalidPath;
    }
    const scale_squared = options.transform.a * options.transform.a +
        options.transform.b * options.transform.b +
        options.transform.c * options.transform.c +
        options.transform.d * options.transform.d;
    if (!std.math.isFinite(scale_squared)) return error.InvalidPath;
    const local_tolerance = options.tolerance / @max(@sqrt(scale_squared), 0.0001);
    var sink: Sink = .{ .output = output, .transform = options.transform, .stroke = options.stroke };
    if (options.stroke) |stroke| {
        if (!std.math.isFinite(stroke.width) or stroke.width <= 0 or
            !std.math.isFinite(stroke.phase) or stroke.phase < 0)
        {
            return error.InvalidPath;
        }
        for (stroke.dash) |dash| {
            if (!std.math.isFinite(dash) or dash <= 0) return error.InvalidPath;
        }
        if (stroke.dash.len > 0) {
            sink.dash_remaining = stroke.dash[0];
            var phase = stroke.phase;
            var period: f32 = 0;
            for (stroke.dash) |dash| period += dash;
            if (!std.math.isFinite(period)) return error.InvalidPath;
            if (stroke.dash.len % 2 == 1) period *= 2;
            if (!std.math.isFinite(period)) return error.InvalidPath;
            phase = @mod(phase, period);
            const limit = std.math.mul(usize, stroke.dash.len, 2) catch
                return error.TessellationCapacity;
            var steps: usize = 0;
            while (phase >= sink.dash_remaining) {
                if (steps >= limit) return error.TessellationCapacity;
                const next = phase - sink.dash_remaining;
                if (next >= phase) return error.TessellationCapacity;
                phase = next;
                sink.advanceDash(stroke.dash);
                steps += 1;
            }
            sink.dash_remaining -= phase;
        }
    }
    var current: ?Point = null;
    var start: ?Point = null;
    for (shape.commands) |command| {
        switch (command) {
            .move => |p| {
                if (current) |from| {
                    if (options.close_open and start != null and !equal(from, start.?)) {
                        try sink.segment(from, start.?);
                    }
                }
                if (!valid(p)) return error.InvalidPath;
                current = p;
                start = p;
            },
            .line => |p| {
                if (current == null or !valid(p)) return error.InvalidPath;
                try sink.segment(current.?, p);
                current = p;
            },
            .quadratic => |curve| {
                if (current == null or !valid(curve.control) or !valid(curve.end)) {
                    return error.InvalidPath;
                }
                if (options.stroke != null and options.stroke.?.dash.len > 0) {
                    try flattenQuadratic(&sink, .{
                        .p0 = current.?,
                        .p1 = curve.control,
                        .p2 = curve.end,
                    }, local_tolerance);
                } else {
                    try sink.add(.{ .p0 = current.?, .p1 = curve.control, .p2 = curve.end });
                }
                current = curve.end;
            },
            .arc => |arc_command| {
                if (current == null or !valid(arc_command.center) or
                    !valid(arc_command.radii) or arc_command.radii.x <= 0 or
                    arc_command.radii.y <= 0 or !std.math.isFinite(arc_command.start) or
                    !std.math.isFinite(arc_command.sweep) or
                    @abs(arc_command.sweep) > 2 * std.math.pi) return error.InvalidPath;
                const radius = @max(arc_command.radii.x, arc_command.radii.y) *
                    @sqrt(scale_squared);
                if (!std.math.isFinite(radius)) return error.InvalidPath;
                const angle_step = @min(0.5, @sqrt(8 * options.tolerance / @max(radius, 0.001)));
                const count_f = @ceil(@abs(arc_command.sweep) / @max(angle_step, 0.00001));
                if (!std.math.isFinite(count_f) or
                    count_f > @as(f32, @floatFromInt(sink.output.len - sink.len)))
                {
                    return error.TessellationCapacity;
                }
                const count: usize = @intFromFloat(count_f);
                const first: Point = .{
                    .x = arc_command.center.x + arc_command.radii.x * @cos(arc_command.start),
                    .y = arc_command.center.y + arc_command.radii.y * @sin(arc_command.start),
                };
                if (!equal(current.?, first)) try sink.segment(current.?, first);
                var previous = first;
                for (1..count + 1) |i| {
                    const angle = arc_command.start + arc_command.sweep *
                        @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
                    const point: Point = .{
                        .x = arc_command.center.x + arc_command.radii.x * @cos(angle),
                        .y = arc_command.center.y + arc_command.radii.y * @sin(angle),
                    };
                    if (!valid(point)) return error.InvalidPath;
                    try sink.segment(previous, point);
                    previous = point;
                }
                current = previous;
            },
            .cubic => |curve| {
                if (current == null or !valid(curve.first) or !valid(curve.second) or
                    !valid(curve.end)) return error.InvalidPath;
                try flattenCubic(&sink, .{
                    current.?, curve.first, curve.second, curve.end,
                }, local_tolerance);
                current = curve.end;
            },
            .close => {
                if (current == null or start == null) return error.InvalidPath;
                if (!equal(current.?, start.?)) try sink.segment(current.?, start.?);
                current = start;
            },
        }
    }
    if (options.close_open and current != null and start != null and
        !equal(current.?, start.?)) try sink.segment(current.?, start.?);
    const bounds: Rect = if (sink.len == 0) .{ .x = 0, .y = 0, .w = 0, .h = 0 } else .{
        .x = sink.min.x,
        .y = sink.min.y,
        .w = sink.max.x - sink.min.x,
        .h = sink.max.y - sink.min.y,
    };
    return .{ .curves = output[0..sink.len], .bounds = bounds };
}

fn flattenQuadratic(sink: *Sink, q: Quadratic, tolerance: f32) Error!void {
    const c = sub(q.p1, midpoint(q.p0, q.p2));
    if (c.x * c.x + c.y * c.y <= tolerance * tolerance) {
        try sink.segment(q.p0, q.p2);
        return;
    }
    // Iterative subdivision has a hard depth limit, not an unbounded recursive path.
    var stack: [64]Quadratic = undefined;
    var depth: usize = 0;
    stack[depth] = q;
    depth += 1;
    while (depth > 0) {
        depth -= 1;
        const segment = stack[depth];
        const deviation = sub(segment.p1, midpoint(segment.p0, segment.p2));
        if (deviation.x * deviation.x + deviation.y * deviation.y <= tolerance * tolerance) {
            try sink.segment(segment.p0, segment.p2);
            continue;
        }
        if (depth + 2 > stack.len) return error.TessellationCapacity;
        const left = midpoint(segment.p0, segment.p1);
        const right = midpoint(segment.p1, segment.p2);
        const middle = midpoint(left, right);
        stack[depth] = .{ .p0 = middle, .p1 = right, .p2 = segment.p2 };
        stack[depth + 1] = .{ .p0 = segment.p0, .p1 = left, .p2 = middle };
        depth += 2;
    }
}

fn flattenCubic(sink: *Sink, points: [4]Point, tolerance: f32) Error!void {
    var stack: [64][4]Point = undefined;
    var depth: usize = 1;
    stack[0] = points;
    while (depth > 0) {
        depth -= 1;
        const segment = stack[depth];
        const chord = sub(segment[3], segment[0]);
        const chord_length = @sqrt(chord.x * chord.x + chord.y * chord.y);
        const first = sub(segment[1], segment[0]);
        const second = sub(segment[2], segment[0]);
        const limit = tolerance * @max(chord_length, tolerance);
        if (@abs(first.x * chord.y - first.y * chord.x) <= limit and
            @abs(second.x * chord.y - second.y * chord.x) <= limit and
            dot(first, chord) >= -limit and dot(second, chord) <= dot(chord, chord) + limit)
        {
            try sink.segment(segment[0], segment[3]);
            continue;
        }
        if (depth + 2 > stack.len) return error.TessellationCapacity;
        const a = midpoint(segment[0], segment[1]);
        const b = midpoint(segment[1], segment[2]);
        const c = midpoint(segment[2], segment[3]);
        const d = midpoint(a, b);
        const e = midpoint(b, c);
        const f = midpoint(d, e);
        stack[depth] = .{ f, e, c, segment[3] };
        stack[depth + 1] = .{ segment[0], a, d, f };
        depth += 2;
    }
}

/// A winding reference for geometry tests; the GPU evaluates the same quadratic crossings.
pub fn contains(curves: []const Quadratic, point: Point, rule: FillRule) bool {
    var winding: i32 = 0;
    for (curves) |q| {
        const a = q.p0.y - 2 * q.p1.y + q.p2.y;
        const b = 2 * (q.p1.y - q.p0.y);
        const c = q.p0.y - point.y;
        var roots: [2]f32 = undefined;
        var count: usize = 0;
        if (@abs(a) < 1e-6) {
            if (@abs(b) < 1e-6) continue;
            roots[0] = -c / b;
            count = 1;
        } else {
            const determinant = b * b - 4 * a * c;
            if (determinant < 0) continue;
            const root = @sqrt(determinant);
            roots = .{ (-b - root) / (2 * a), (-b + root) / (2 * a) };
            count = if (root == 0) 1 else 2;
        }
        for (roots[0..count]) |t| {
            if (t < 0 or t >= 1) continue;
            const x = (1 - t) * (1 - t) * q.p0.x + 2 * (1 - t) * t * q.p1.x +
                t * t * q.p2.x;
            if (x <= point.x) continue;
            const derivative = 2 * a * t + b;
            if (derivative > 0) winding += 1 else if (derivative < 0) winding -= 1;
        }
    }
    return switch (rule) {
        .nonzero => winding != 0,
        .even_odd => @mod(winding, 2) != 0,
    };
}

fn valid(p: Point) bool {
    return std.math.isFinite(p.x) and std.math.isFinite(p.y);
}
fn equal(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}
fn midpoint(a: Point, b: Point) Point {
    return .{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };
}
fn sub(a: Point, b: Point) Point {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}
fn dot(a: Point, b: Point) f32 {
    return a.x * b.x + a.y * b.y;
}
fn mix(a: Point, b: Point, t: f32) Point {
    return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
}
