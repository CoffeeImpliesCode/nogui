//! Renderer-neutral frame paint. Convert authored colors once when records are appended.
const std = @import("std");
pub const path = @import("path.zig");

pub const Srgb = struct { r: f32, g: f32, b: f32, a: f32 = 1 };
pub const Oklab = struct { l: f32, a: f32, b: f32, alpha: f32 };
pub const Color = union(enum) { srgb: Srgb, oklab: Oklab, palette: usize };
pub const Error = error{ PaintCapacity, PaletteOutOfRange, InvalidPaint } || std.mem.Allocator.Error;
pub const Rect = path.Rect;
pub const Point = path.Point;
pub const Affine = path.Affine;
pub const FillRule = path.FillRule;

pub const Stop = struct { color: Color, position: f32 };
pub const Gradient = struct {
    first: Stop,
    second: Stop,
    /// Zero points right; pi/2 points down. Positions are fractions of the box projection.
    angle: f32 = std.math.pi / 2.0,
};
pub const PatternKind = enum { checker, stripes };
pub const Pattern = struct {
    first: Color,
    second: Color,
    cell: Point,
    kind: PatternKind = .checker,
};

/// Tile a host texture whose RGB channels already contain intermediate Oklab.
pub const ImagePattern = struct { texture_index: u32, tile: Point };
pub const Fill = union(enum) {
    solid: Color,
    gradient: Gradient,
    pattern: Pattern,
    image_pattern: ImagePattern,
};
pub const SceneStop = struct { color: Oklab, position: f32 };
pub const SceneGradient = struct { first: SceneStop, second: SceneStop, angle: f32 };
pub const ScenePattern = struct {
    first: Oklab,
    second: Oklab,
    cell: Point,
    kind: PatternKind,
};
pub const SceneFill = union(enum) {
    solid: Oklab,
    gradient: SceneGradient,
    pattern: ScenePattern,
    image_pattern: ImagePattern,
};

pub const BorderStyle = enum { none, solid, dashed, dotted };
pub const BorderSide = struct {
    width: f32 = 0,
    color: Color = .{ .srgb = .{ .r = 0, .g = 0, .b = 0 } },
    style: BorderStyle = .solid,
};
pub const SceneBorderSide = struct {
    width: f32,
    color: Oklab,
    style: BorderStyle,
};
/// Corner order: top-left, top-right, bottom-right, bottom-left.
pub const Radii = [4]f32;
/// Border order: top, right, bottom, left.
pub const Borders = [4]BorderSide;
pub const SceneBorders = [4]SceneBorderSide;

pub const Shadow = struct {
    color: Color,
    offset: Point = .{ .x = 0, .y = 0 },
    blur: f32 = 0,
    spread: f32 = 0,
    inset: bool = false,
};
pub const SceneShadow = struct {
    color: Oklab,
    offset: Point,
    blur: f32,
    spread: f32,
    inset: bool,
};
/// Width is in logical window units; dash lengths and phase are path-local units.
pub const Stroke = struct {
    color: Color,
    width: f32,
    dash: []const f32 = &.{},
    phase: f32 = 0,
};
pub const SceneStroke = struct {
    color: Oklab,
    width: f32,
    dash: []const f32,
    phase: f32,
};
/// The affine maps window coordinates after layout. The window clip applies afterward.
/// Neither the affine nor the clip changes a widget's layout or hit box.
/// Opacity multiplies each primitive's alpha, not an isolated group's alpha.
pub const RectPaint = struct {
    bounds: Rect,
    fill: ?Fill = null,
    borders: Borders = .{ .{}, .{}, .{}, .{} },
    radii: Radii = .{ 0, 0, 0, 0 },
    shadows: []const Shadow = &.{},
    opacity: f32 = 1,
    transform: Affine = .{},
    clip_id: u32 = 0xFFFFFFFF,
    layer: u32 = 0,
    /// Absolute sort key shared with legacy SceneRect.order when a scene mixes both.
    order: ?u32 = null,
};
/// Path commands start at the final prepaint bounds origin before the affine maps them.
pub const PathPaint = struct {
    /// Final prepaint bounds; command points are local to this rectangle's origin.
    bounds: Rect,
    path: path.Path,
    fill: ?Fill = null,
    fill_rule: FillRule = .nonzero,
    stroke: ?Stroke = null,
    opacity: f32 = 1,
    transform: Affine = .{},
    clip_id: u32 = 0xFFFFFFFF,
    layer: u32 = 0,
    order: ?u32 = null,
};

/// Oklab GPU texture sample. Source coordinates are normalized within the
/// uploaded texture, and bounds are logical window units after collection.
pub const ImagePaint = struct {
    bounds: Rect,
    src: Rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    texture_index: u32,
    /// Removes Oklab chroma without changing lightness or alpha. Range: 0–1.
    grayscale: f32 = 0,
    opacity: f32 = 1,
    clip_id: u32 = 0xFFFFFFFF,
    layer: u32 = 0,
    order: ?u32 = null,
};

pub fn validImage(spec: ImagePaint) bool {
    const uv = spec.src;
    return spec.texture_index != 0xFFFFFFFF and
        std.math.isFinite(spec.grayscale) and spec.grayscale >= 0 and spec.grayscale <= 1 and
        std.math.isFinite(uv.x) and std.math.isFinite(uv.y) and
        std.math.isFinite(uv.w) and std.math.isFinite(uv.h) and
        uv.x >= 0 and uv.y >= 0 and uv.w > 0 and uv.h > 0 and
        uv.x + uv.w <= 1 and uv.y + uv.h <= 1;
}
pub const SceneRect = struct {
    fill: ?SceneFill,
    borders: SceneBorders,
    radii: Radii,
    shadows: []const SceneShadow,
};
pub const ScenePath = struct {
    path: path.Path,
    fill: ?SceneFill,
    fill_rule: FillRule,
    stroke: ?SceneStroke,
};
pub const SceneImage = struct {
    src: Rect,
    texture_index: u32,
    grayscale: f32 = 0,
};
pub const PaintRecord = struct {
    bounds: Rect,
    transform: Affine,
    clip_id: u32,
    layer: u32,
    opacity: f32,
    order: u32,
    shape: union(enum) { rect: SceneRect, path: ScenePath, image: SceneImage },
};

/// One paint list belongs to one of App's frame arenas. Borrowed inputs are copied before append.
pub const PaintList = struct {
    allocator: std.mem.Allocator,
    palette: []const Srgb,
    max_records: usize,
    records: std.ArrayList(PaintRecord) = .empty,

    pub fn init(allocator: std.mem.Allocator, palette: []const Srgb, max_records: usize) PaintList {
        return .{ .allocator = allocator, .palette = palette, .max_records = max_records };
    }

    pub fn deinit(self: *PaintList) void {
        for (self.records.items) |record| {
            switch (record.shape) {
                .rect => |rect| {
                    if (rect.shadows.len > 0) self.allocator.free(rect.shadows);
                },
                .path => |shape| {
                    self.allocator.free(shape.path.commands);
                    if (shape.stroke) |stroke| {
                        if (stroke.dash.len > 0) self.allocator.free(stroke.dash);
                    }
                },
                .image => {},
            }
        }
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addRect(self: *PaintList, spec: RectPaint) Error!void {
        try self.checkHeader(spec.bounds, spec.opacity, spec.transform);
        for (spec.radii) |radius| {
            if (!std.math.isFinite(radius) or radius < 0) return error.InvalidPaint;
        }
        // SAFETY: the loop assigns all four sides before any read.
        var sides: SceneBorders = undefined;
        for (spec.borders, 0..) |border, index| {
            if (!std.math.isFinite(border.width) or border.width < 0) return error.InvalidPaint;
            sides[index] = .{
                .width = border.width,
                .color = try self.convert(border.color, spec.opacity),
                .style = border.style,
            };
        }
        const fill: ?SceneFill = if (spec.fill) |value| try self.convertFill(value, spec.opacity) else null;
        const shadows: []const SceneShadow = if (spec.shadows.len == 0) &.{} else blk: {
            const owned = try self.allocator.alloc(SceneShadow, spec.shadows.len);
            errdefer self.allocator.free(owned);
            for (spec.shadows, 0..) |shadow, index| {
                if (!validPoint(shadow.offset) or !std.math.isFinite(shadow.blur) or
                    !std.math.isFinite(shadow.spread) or shadow.blur < 0) return error.InvalidPaint;
                const pad = shadow.blur + @max(shadow.spread, 0);
                if (!std.math.isFinite(pad) or
                    !std.math.isFinite(spec.bounds.x + shadow.offset.x - pad) or
                    !std.math.isFinite(spec.bounds.y + shadow.offset.y - pad) or
                    !std.math.isFinite(spec.bounds.w + 2 * pad) or
                    !std.math.isFinite(spec.bounds.h + 2 * pad)) return error.InvalidPaint;
                owned[index] = .{
                    .color = try self.convert(shadow.color, spec.opacity),
                    .offset = shadow.offset,
                    .blur = shadow.blur,
                    .spread = shadow.spread,
                    .inset = shadow.inset,
                };
            }
            break :blk owned;
        };
        errdefer if (shadows.len > 0) self.allocator.free(shadows);
        try self.records.append(self.allocator, .{
            .bounds = spec.bounds,
            .transform = spec.transform,
            .clip_id = spec.clip_id,
            .layer = spec.layer,
            .opacity = spec.opacity,
            .order = spec.order orelse @intCast(self.records.items.len),
            .shape = .{ .rect = .{
                .fill = fill,
                .borders = sides,
                .radii = spec.radii,
                .shadows = shadows,
            } },
        });
    }

    pub fn addPath(self: *PaintList, spec: PathPaint) Error!void {
        try self.checkHeader(spec.bounds, spec.opacity, spec.transform);
        if (spec.path.commands.len == 0) return error.InvalidPaint;
        const fill: ?SceneFill = if (spec.fill) |value| try self.convertFill(value, spec.opacity) else null;
        var stroke: ?SceneStroke = null;
        if (spec.stroke) |value| {
            if (!std.math.isFinite(value.width) or value.width <= 0 or
                !std.math.isFinite(value.phase) or value.phase < 0) return error.InvalidPaint;
            if (!std.math.isFinite(spec.bounds.w + value.width) or
                !std.math.isFinite(spec.bounds.h + value.width)) return error.InvalidPaint;
            for (value.dash) |dash| {
                if (!std.math.isFinite(dash) or dash <= 0) return error.InvalidPaint;
            }
            stroke = .{
                .color = try self.convert(value.color, spec.opacity),
                .width = value.width,
                .dash = if (value.dash.len == 0) &.{} else try self.allocator.dupe(f32, value.dash),
                .phase = value.phase,
            };
        }
        errdefer if (stroke) |value| {
            if (value.dash.len > 0) self.allocator.free(value.dash);
        };
        const commands = try self.allocator.dupe(path.Command, spec.path.commands);
        errdefer self.allocator.free(commands);
        try self.records.append(self.allocator, .{
            .bounds = spec.bounds,
            .transform = spec.transform,
            .clip_id = spec.clip_id,
            .layer = spec.layer,
            .opacity = spec.opacity,
            .order = spec.order orelse @intCast(self.records.items.len),
            .shape = .{ .path = .{
                .path = .{ .commands = commands },
                .fill = fill,
                .fill_rule = spec.fill_rule,
                .stroke = stroke,
            } },
        });
    }

    pub fn addImage(self: *PaintList, spec: ImagePaint) Error!void {
        try self.checkHeader(spec.bounds, spec.opacity, .{});
        if (!validImage(spec)) return error.InvalidPaint;
        try self.records.append(self.allocator, .{
            .bounds = spec.bounds,
            .transform = .{},
            .clip_id = spec.clip_id,
            .layer = spec.layer,
            .opacity = spec.opacity,
            .order = spec.order orelse @intCast(self.records.items.len),
            .shape = .{ .image = .{
                .src = spec.src,
                .texture_index = spec.texture_index,
                .grayscale = spec.grayscale,
            } },
        });
    }

    fn checkHeader(self: *const PaintList, bounds: Rect, opacity: f32, transform: Affine) Error!void {
        if (self.records.items.len >= self.max_records or
            self.records.items.len >= std.math.maxInt(u32)) return error.PaintCapacity;
        if (!validPoint(.{ .x = bounds.x, .y = bounds.y }) or
            !std.math.isFinite(bounds.w) or !std.math.isFinite(bounds.h) or
            bounds.w < 0 or bounds.h < 0 or
            !std.math.isFinite(opacity) or opacity < 0 or opacity > 1) return error.InvalidPaint;
        if (!std.math.isFinite(bounds.x + bounds.w) or
            !std.math.isFinite(bounds.y + bounds.h)) return error.InvalidPaint;
        for ([_]f32{ transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty }) |component| {
            if (!std.math.isFinite(component)) return error.InvalidPaint;
        }
        for ([_]Point{
            .{ .x = bounds.x, .y = bounds.y },
            .{ .x = bounds.x + bounds.w, .y = bounds.y },
            .{ .x = bounds.x, .y = bounds.y + bounds.h },
            .{ .x = bounds.x + bounds.w, .y = bounds.y + bounds.h },
        }) |corner| {
            if (!validPoint(transform.apply(corner))) return error.InvalidPaint;
        }
    }

    fn convert(self: *const PaintList, value: Color, opacity: f32) Error!Oklab {
        const color = switch (value) {
            .srgb => |srgb| srgb,
            .palette => |index| if (index < self.palette.len)
                self.palette[index]
            else
                return error.PaletteOutOfRange,
            .oklab => |lab| {
                if (!std.math.isFinite(lab.l) or !std.math.isFinite(lab.a) or
                    !std.math.isFinite(lab.b) or !std.math.isFinite(lab.alpha) or
                    lab.alpha < 0 or lab.alpha > 1) return error.InvalidPaint;
                return .{ .l = lab.l, .a = lab.a, .b = lab.b, .alpha = lab.alpha * opacity };
            },
        };
        for ([_]f32{ color.r, color.g, color.b, color.a }) |channel| {
            if (!std.math.isFinite(channel) or channel < 0 or channel > 1) {
                return error.InvalidPaint;
            }
        }
        const r = linear(color.r);
        const g = linear(color.g);
        const b = linear(color.b);
        const l = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
        const m = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
        const s = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
        return .{
            .l = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            .a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            .b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
            .alpha = color.a * opacity,
        };
    }

    fn convertFill(self: *const PaintList, fill: Fill, opacity: f32) Error!SceneFill {
        return switch (fill) {
            .solid => |color| .{ .solid = try self.convert(color, opacity) },
            .gradient => |gradient| blk: {
                if (!std.math.isFinite(gradient.angle) or
                    !std.math.isFinite(gradient.first.position) or
                    !std.math.isFinite(gradient.second.position) or
                    gradient.first.position < 0 or gradient.second.position > 1 or
                    gradient.first.position >= gradient.second.position)
                {
                    return error.InvalidPaint;
                }
                break :blk .{ .gradient = .{
                    .first = .{
                        .color = try self.convert(gradient.first.color, opacity),
                        .position = gradient.first.position,
                    },
                    .second = .{
                        .color = try self.convert(gradient.second.color, opacity),
                        .position = gradient.second.position,
                    },
                    .angle = gradient.angle,
                } };
            },
            .pattern => |pattern| blk: {
                if (!validPoint(pattern.cell) or pattern.cell.x <= 0 or pattern.cell.y <= 0) {
                    return error.InvalidPaint;
                }
                break :blk .{ .pattern = .{
                    .first = try self.convert(pattern.first, opacity),
                    .second = try self.convert(pattern.second, opacity),
                    .cell = pattern.cell,
                    .kind = pattern.kind,
                } };
            },
            .image_pattern => |image| blk: {
                if (!validPoint(image.tile) or image.tile.x <= 0 or image.tile.y <= 0 or
                    image.texture_index == 0xFFFFFFFF) return error.InvalidPaint;
                break :blk .{ .image_pattern = image };
            },
        };
    }
};

fn validPoint(point: Point) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.y);
}
fn linear(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}
