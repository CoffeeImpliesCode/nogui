//! Public scene facade for the v7 9-slice renderer.
//!
//! The facade owns the GPU batch and keeps its storage, sort ring, and draw
//! state private. Callers borrow scene slices for prepare(), then draw() in
//! the render pass.

const noapi = @import("noapi");
const batch_module = @import("render_9slice.zig");
const std = @import("std");
const paint = @import("nogui").paint;
const paint_path = @import("nogui").path;
const sweeper = @import("sweeper.zig");
const Batch9Slice = batch_module.Batch9Slice;

/// GPU-facing clip-rect type used by the scene submission protocol.
pub const ClipRect = batch_module.ClipRect;
/// One borrowed 9-slice rectangle in the scene submission protocol.
pub const SceneRect = batch_module.SceneRect;
pub const max_clip_rects = batch_module.max_clip_rects;
pub const type_path_fill: u32 = 6;
pub const type_paint_rect: u32 = 7;
pub const type_paint_shadow: u32 = 8;
pub const type_path_stroke: u32 = 9;

/// GPU paint payload; every member is one 16-byte vector in shader order.
pub const PaintExtra = extern struct {
    transform_x: [4]f32 = .{ 1, 0, 0, 0 },
    transform_y: [4]f32 = .{ 0, 1, 0, 0 },
    size: [4]f32 = .{ 0, 0, 0, 0 },
    radii: [4]f32 = .{ 0, 0, 0, 0 },
    border_width: [4]f32 = .{ 0, 0, 0, 0 },
    border_color: [4][4]f32 = .{.{0} ** 4} ** 4,
    border_styles: [4]u32 = .{ 0, 0, 0, 0 },
    from: [4]f32 = .{ 0, 0, 0, 0 },
    to: [4]f32 = .{ 0, 0, 0, 0 },
    gradient: [4]f32 = .{ 0, 1, 0, 1 },
    pattern: [4]f32 = .{ 1, 1, 0, 0 },
    shadow: [4]f32 = .{ 0, 0, 0, 0 },
    mode: [4]u32 = .{ 0, 0xFFFFFFFF, 0, 0 },
};
comptime {
    std.debug.assert(@sizeOf(PaintExtra) == 256);
    std.debug.assert(@offsetOf(PaintExtra, "border_color") == 80);
    std.debug.assert(@offsetOf(PaintExtra, "border_styles") == 144);
    std.debug.assert(@offsetOf(PaintExtra, "mode") == 240);
}

pub const PaintMaterial = struct {
    material: sweeper.GlyphMaterial,
    extra: PaintExtra,
    curve_offset: u32 = 0,
    curve_count: u32 = 0,
};
pub const MaterialRange = struct { first: u32, end: u32 };
pub const PaintError = paint_path.Error || error{
    MaterialCapacity,
    MaterialOverlap,
    SceneCapacity,
    PaintBufferCapacity,
    InvalidClip,
    InvalidFrameSlot,
    InvalidPaint,
};
pub const Lowered = struct {
    rects: []const SceneRect,
    materials: []const PaintMaterial,
    curves: []const paint_path.Quadratic,
};
pub const PaintScene = struct {
    legacy_rects: []const SceneRect = &.{},
    records: []const paint.PaintRecord,
    clips: []const ClipRect,
};
pub const PaintTarget = struct {
    rects: []SceneRect,
    curves: []paint_path.Quadratic,
    materials: []PaintMaterial,
    material_buffer: noapi.GpuPtr,
    material_slots: u32,
    range: MaterialRange,
    /// Must match Renderer.nextFrameSlot(); separate material regions per in-flight slot.
    frame_slot: u32,
};

/// Borrowed scene data submitted to one prepare/draw pair.
pub const Scene = struct {
    rects: []const SceneRect,
    clips: []const ClipRect,
};

/// Material and pixel-path configuration for the renderer.
pub const Options = struct {
    material_bda: u64 = 0,
    subpixel: bool = false,
    quad_debug: bool = false,
    bgr_order: bool = false,
    damp_chroma: bool = true,
};

/// Public scene renderer. The raw batch and its GPU storage remain private.
pub const Renderer = struct {
    batch: Batch9Slice,
    paint_buffers: [3]?noapi.GpuPtr = .{null} ** 3,
    /// Fixed GPU scratch is three-way ringed with noapi's in-flight frame slots.
    pub const paint_buffer_bytes = 1024 * 1024;

    /// Creates the renderer and its shader objects.
    pub fn init(
        gpu: *noapi.Gpu,
        vert_spv: []const u32,
        frag_spv: []const u32,
        sort_spv: []const u32,
    ) !Renderer {
        return .{ .batch = try Batch9Slice.init(gpu, vert_spv, frag_spv, sort_spv) };
    }

    /// Releases the owned shaders and GPU buffers.
    pub fn deinit(self: *Renderer) void {
        for (self.paint_buffers) |buffer| {
            if (buffer) |owned| self.batch.gpu.gpuFree(owned);
        }
        self.batch.deinit();
        self.* = undefined;
    }

    /// Applies material-buffer and pixel-path configuration.
    pub fn configure(self: *Renderer, options: Options) void {
        self.batch.material_buf_bda = options.material_bda;
        self.batch.subpixel = options.subpixel;
        self.batch.quad_debug = options.quad_debug;
        self.batch.bgr_order = options.bgr_order;
        self.batch.damp_chroma = options.damp_chroma;
    }

    /// Uploads the borrowed scene and records the stable GPU sort.
    ///
    /// This call belongs outside dynamic rendering. The same scene remains
    /// borrowed by the caller only for this call; the batch copies its data.
    pub fn prepare(self: *Renderer, cmd: anytype, scene: Scene) !void {
        try self.batch.sort(cmd, scene.rects, scene.clips);
    }
    /// Caller-owned material slots must be partitioned by in-flight frame.
    pub fn nextFrameSlot(self: *const Renderer) u32 {
        return self.batch.frame;
    }

    /// Lower and submit on the existing sorted quad path, outside dynamic rendering.
    pub fn preparePaint(
        self: *Renderer,
        cmd: anytype,
        scene: PaintScene,
        target: PaintTarget,
    ) !void {
        if (target.frame_slot != self.nextFrameSlot()) return error.InvalidFrameSlot;
        if (target.range.first == 0 or target.range.end > target.material_slots or
            target.range.first > target.range.end) return error.MaterialCapacity;
        if (scene.clips.len > max_clip_rects) return error.InvalidClip;
        for (scene.legacy_rects) |*rect| {
            if (rect.material_index >= target.material_slots) return error.MaterialCapacity;
            if (rect.clip_id != 0xFFFFFFFF and rect.clip_id >= scene.clips.len) {
                return error.InvalidClip;
            }
        }
        for (scene.records) |*record| {
            if (record.clip_id != 0xFFFFFFFF and record.clip_id >= scene.clips.len) {
                return error.InvalidClip;
            }
        }
        const lowered = try lowerPaint(
            scene.legacy_rects,
            scene.records,
            target.rects,
            target.curves,
            target.materials,
            target.range,
        );
        const extra_bytes = std.math.mul(usize, lowered.materials.len, @sizeOf(PaintExtra)) catch
            return error.PaintBufferCapacity;
        var cursor = std.mem.alignForward(usize, extra_bytes, 8);
        for (lowered.materials) |entry| {
            if (entry.curve_count == 0) continue;
            const curve_bytes = std.math.mul(usize, entry.curve_count, @sizeOf(sweeper.Curve)) catch
                return error.PaintBufferCapacity;
            cursor = std.math.add(usize, cursor, 8 + curve_bytes) catch
                return error.PaintBufferCapacity;
        }
        if (cursor > paint_buffer_bytes) return error.PaintBufferCapacity;
        if (lowered.materials.len == 0) {
            self.batch.material_buf_bda = target.material_buffer.gpu;
            try self.batch.sort(cmd, lowered.rects, scene.clips);
            return;
        }
        if (self.paint_buffers[0] == null) {
            var new_buffers: [3]noapi.GpuPtr = undefined;
            var initialized: usize = 0;
            errdefer for (new_buffers[0..initialized]) |buffer| self.batch.gpu.gpuFree(buffer);
            while (initialized < new_buffers.len) : (initialized += 1) {
                new_buffers[initialized] = try self.batch.gpu.gpuMalloc(
                    paint_buffer_bytes,
                    64,
                    .default,
                );
            }
            for (new_buffers, 0..) |buffer, index| self.paint_buffers[index] = buffer;
        }

        const gpu_paint = self.paint_buffers[target.frame_slot].?;
        const bytes: [*]u8 = @ptrCast(@alignCast(gpu_paint.cpu));
        const materials: [*]sweeper.GlyphMaterial =
            @ptrCast(@alignCast(target.material_buffer.cpu));
        cursor = std.mem.alignForward(usize, extra_bytes, 8);
        for (lowered.materials, 0..) |entry, index| {
            const extra_offset = index * @sizeOf(PaintExtra);
            const extra: *PaintExtra = @ptrCast(@alignCast(bytes + extra_offset));
            extra.* = entry.extra;
            var material = entry.material;
            if (entry.curve_count > 0) {
                material.curve_bda = gpu_paint.gpu + cursor;
                const count: *u32 = @ptrCast(@alignCast(bytes + cursor));
                count.* = entry.curve_count;
                const padding: *u32 = @ptrCast(@alignCast(bytes + cursor + 4));
                padding.* = 0;
                const curves: [*]sweeper.Curve = @ptrCast(@alignCast(bytes + cursor + 8));
                const first: usize = entry.curve_offset;
                const last = first + entry.curve_count;
                for (lowered.curves[first..last], 0..) |curve, curve_index| {
                    curves[curve_index] = .{
                        .p0x = curve.p0.x,
                        .p0y = -curve.p0.y,
                        .p1x = curve.p1.x,
                        .p1y = -curve.p1.y,
                        .p2x = curve.p2.x,
                        .p2y = -curve.p2.y,
                    };
                }
                cursor += 8 + @as(usize, entry.curve_count) * @sizeOf(sweeper.Curve);
                if (material.type == type_path_fill) {
                    material.band_bda = gpu_paint.gpu + extra_offset;
                }
            } else if (material.type == type_paint_rect or material.type == type_paint_shadow) {
                material.curve_bda = gpu_paint.gpu + extra_offset;
            }
            materials[@as(usize, target.range.first) + index] = material;
        }
        self.batch.material_buf_bda = target.material_buffer.gpu;
        try self.batch.sort(cmd, lowered.rects, scene.clips);
    }

    /// Records the GUI draw with logical scene coordinates on a device-pixel surface.
    pub fn draw(self: *Renderer, cmd: anytype, logical_w: f32, logical_h: f32, device_w: f32, device_h: f32) void {
        self.batch.draw(cmd, logical_w, logical_h, device_w, device_h);
    }

    /// Returns the current sorted permutation for the bounded debug readback.
    pub fn permutationBuffer(self: *const Renderer) noapi.GpuPtr {
        return self.batch.perm_a[self.batch.cur_slot];
    }
};

/// Pure lowering stage. Every material and scene slot is preflighted before output writes.
pub fn lowerPaint(
    legacy: []const SceneRect,
    records: []const paint.PaintRecord,
    rect_scratch: []SceneRect,
    curve_scratch: []paint_path.Quadratic,
    material_scratch: []PaintMaterial,
    range: MaterialRange,
) PaintError!Lowered {
    if (range.first == 0 or range.first > range.end) return error.MaterialCapacity;
    for (legacy) |*rect| {
        if (rect.material_index >= range.first and
            rect.material_index < range.end) return error.MaterialOverlap;
    }
    var needed_materials: usize = 0;
    var needed_rects: usize = legacy.len;
    for (records) |*record| {
        var primitive_count: usize = 0;
        var flat = false;
        switch (record.shape) {
            .rect => |*rect| {
                if (record.bounds.w <= 0 or record.bounds.h <= 0) continue;
                flat = isFlatSolid(record, rect);
                const filled: usize = @intFromBool(rect.fill != null);
                primitive_count = std.math.add(usize, rect.shadows.len, filled) catch
                    return error.SceneCapacity;
                const bordered: usize = @intFromBool(hasBorder(&rect.borders));
                primitive_count = std.math.add(usize, primitive_count, bordered) catch
                    return error.SceneCapacity;
            },
            .path => |*shape| {
                primitive_count = @as(usize, @intFromBool(shape.fill != null)) +
                    @as(usize, @intFromBool(shape.stroke != null));
            },
            .image => {
                if (record.bounds.w <= 0 or record.bounds.h <= 0) continue;
                primitive_count = 1;
                flat = true;
            },
        }
        needed_rects = std.math.add(usize, needed_rects, primitive_count) catch
            return error.SceneCapacity;
        needed_materials = std.math.add(usize, needed_materials, primitive_count - @as(usize, @intFromBool(flat))) catch
            return error.MaterialCapacity;
    }
    if (needed_materials > @as(usize, range.end - range.first) or
        needed_materials > material_scratch.len) return error.MaterialCapacity;
    if (needed_rects > rect_scratch.len or needed_rects > std.math.maxInt(u32) / 9) {
        return error.SceneCapacity;
    }
    @memcpy(rect_scratch[0..legacy.len], legacy);
    var output: Lowering = .{
        .rects = rect_scratch,
        .curves = curve_scratch,
        .materials = material_scratch,
        .range = range,
        .rect_count = legacy.len,
    };
    for (records) |*record| {
        switch (record.shape) {
            .rect => |*rect| try output.rect(record, rect),
            .path => |*shape| try output.path(record, shape),
            .image => |*image| output.image(record, image),
        }
    }
    return .{
        .rects = rect_scratch[0..output.rect_count],
        .materials = material_scratch[0..output.material_count],
        .curves = curve_scratch[0..output.curve_count],
    };
}

const Lowering = struct {
    rects: []SceneRect,
    curves: []paint_path.Quadratic,
    materials: []PaintMaterial,
    range: MaterialRange,
    rect_count: usize = 0,
    material_count: usize = 0,
    curve_count: usize = 0,

    fn add(
        self: *Lowering,
        record: *const paint.PaintRecord,
        bounds: paint.Rect,
        origin: paint_path.Point,
        kind: u32,
        color: [4]f32,
        extra: *const PaintExtra,
        curve_offset: u32,
        curve_count: u32,
    ) void {
        std.debug.assert(self.material_count < self.materials.len);
        const slot = self.range.first + @as(u32, @intCast(self.material_count));
        self.materials[self.material_count] = .{
            .material = .{
                .type = kind,
                .bearing_y = if (kind == type_path_stroke) extra.shadow[0] else 0,
                .curve_w = 0,
                .curve_h = 0,
                .win_w = if (kind == type_path_stroke) 0 else bounds.w,
                .win_h = if (kind == type_path_stroke) 0.5 else bounds.h,
                .curve_bda = 0,
            },
            .extra = extra.*,
            .curve_offset = curve_offset,
            .curve_count = curve_count,
        };
        self.material_count += 1;
        self.emitRect(record, bounds, origin, kind, color, slot);
    }

    fn emitRect(
        self: *Lowering,
        record: *const paint.PaintRecord,
        bounds: paint.Rect,
        origin: paint_path.Point,
        kind: u32,
        color: [4]f32,
        material_index: u32,
    ) void {
        std.debug.assert(self.rect_count < self.rects.len);
        self.rects[self.rect_count] = .{
            .dst = .{ bounds.x, bounds.y, bounds.w, bounds.h },
            .src = .{ 0, 0, 1, 1 },
            .corners = .{ 0, 0, 0, 0 },
            .color = color,
            .curve = if (kind == type_paint_rect or kind == type_paint_shadow)
                .{ 1e31, 0, 0, 0 }
            else
                .{ 0, 0, 0, 0 },
            .material_index = material_index,
            .clip_id = record.clip_id,
            .z = record.layer,
            .origin = .{ origin.x, origin.y },
            .order = record.order,
        };
        self.rect_count += 1;
    }

    /// TYPE_TEXTURE multiplies Oklab channels by the vertex tint. Desaturation
    /// needs no texture copy or material and preserves lightness and alpha.
    fn image(self: *Lowering, record: *const paint.PaintRecord, shape: *const paint.SceneImage) void {
        if (record.bounds.w <= 0 or record.bounds.h <= 0) return;
        const chroma = 1 - shape.grayscale;
        self.emitRect(record, record.bounds, .{
            .x = record.bounds.x,
            .y = record.bounds.y,
        }, 0, .{ 1, chroma, chroma, record.opacity }, 0);
        const quad = &self.rects[self.rect_count - 1];
        quad.src = .{ shape.src.x, shape.src.y, shape.src.w, shape.src.h };
        quad.tex_idx = shape.texture_index;
    }

    fn rect(
        self: *Lowering,
        record: *const paint.PaintRecord,
        shape: *const paint.SceneRect,
    ) PaintError!void {
        if (record.bounds.w <= 0 or record.bounds.h <= 0) return;
        if (isFlatSolid(record, shape)) {
            self.emitRect(record, record.bounds, .{
                .x = record.bounds.x,
                .y = record.bounds.y,
            }, 0, lab(shape.fill.?.solid), 0);
            return;
        }
        const base = rectExtra(record, shape);
        for (shape.shadows) |shadow| {
            if (shadow.inset) continue;
            self.addShadow(record, &base, shadow);
        }
        if (shape.fill) |fill| {
            var extra = base;
            const color = fillExtra(&extra, fill);
            if (fill == .image_pattern) extra.from[3] = record.opacity;
            self.add(record, record.bounds, .{
                .x = record.bounds.x,
                .y = record.bounds.y,
            }, type_paint_rect, color, &extra, 0, 0);
        }
        for (shape.shadows) |shadow| {
            if (!shadow.inset) continue;
            self.addShadow(record, &base, shadow);
        }
        if (hasBorder(&shape.borders)) {
            var extra = base;
            extra.mode[0] = 1;
            const color = extra.border_color[0];
            self.add(record, record.bounds, .{
                .x = record.bounds.x,
                .y = record.bounds.y,
            }, type_paint_rect, color, &extra, 0, 0);
        }
    }

    fn addShadow(
        self: *Lowering,
        record: *const paint.PaintRecord,
        base: *const PaintExtra,
        shadow: paint.SceneShadow,
    ) void {
        var extra = base.*;
        extra.mode[0] = 2;
        extra.mode[2] = @intFromBool(shadow.inset);
        extra.shadow = .{ shadow.blur, shadow.spread, shadow.offset.x, shadow.offset.y };
        const spread = if (shadow.inset) 0 else @max(shadow.spread, 0);
        const pad = if (shadow.inset) 0 else shadow.blur + spread;
        // An inset shadow only paints inside the box, and the shader already
        // shifts it by shadow.zw in box-local space. Only the outset quad
        // grows by the blur and spread and translates by the offset.
        const offset_x = if (shadow.inset) 0 else shadow.offset.x;
        const offset_y = if (shadow.inset) 0 else shadow.offset.y;
        const bounds: paint.Rect = .{
            .x = record.bounds.x + offset_x - pad,
            .y = record.bounds.y + offset_y - pad,
            .w = record.bounds.w + 2 * pad,
            .h = record.bounds.h + 2 * pad,
        };
        self.add(record, bounds, .{
            .x = record.bounds.x,
            .y = record.bounds.y,
        }, type_paint_shadow, lab(shadow.color), &extra, 0, 0);
    }

    fn path(
        self: *Lowering,
        record: *const paint.PaintRecord,
        shape: *const paint.ScenePath,
    ) PaintError!void {
        const transform: paint_path.Affine = .{
            .a = record.transform.a,
            .b = record.transform.b,
            .c = record.transform.c,
            .d = record.transform.d,
            .tx = record.transform.tx + record.transform.a * record.bounds.x +
                record.transform.c * record.bounds.y,
            .ty = record.transform.ty + record.transform.b * record.bounds.x +
                record.transform.d * record.bounds.y,
        };
        if (shape.fill) |fill| {
            const offset = self.curve_count;
            const geometry = try paint_path.tessellate(shape.path, self.curves[offset..], .{
                .transform = transform,
                .close_open = true,
            });
            self.curve_count += geometry.len();
            if (geometry.len() > 0) {
                var extra: PaintExtra = .{};
                extra.size = .{ record.bounds.w, record.bounds.h, 0, 0 };
                if (fill != .solid) {
                    const determinant = transform.a * transform.d - transform.b * transform.c;
                    if (!std.math.isFinite(determinant) or @abs(determinant) < 1e-8) {
                        return error.InvalidPaint;
                    }
                    const inverse = 1 / determinant;
                    extra.transform_x = .{
                        transform.d * inverse,                                               -transform.c * inverse,
                        (transform.c * transform.ty - transform.d * transform.tx) * inverse, 0,
                    };
                    extra.transform_y = .{
                        -transform.b * inverse,                                              transform.a * inverse,
                        (transform.b * transform.tx - transform.a * transform.ty) * inverse, 0,
                    };
                    for (extra.transform_x[0..3]) |coefficient| {
                        if (!std.math.isFinite(coefficient)) return error.InvalidPaint;
                    }
                    for (extra.transform_y[0..3]) |coefficient| {
                        if (!std.math.isFinite(coefficient)) return error.InvalidPaint;
                    }
                }
                extra.mode[2] = @intFromEnum(shape.fill_rule);
                const color = fillExtra(&extra, fill);
                if (fill == .image_pattern) extra.from[3] = record.opacity;
                const pad: f32 = 1;
                self.add(record, expand(geometry.bounds, pad), .{
                    .x = geometry.bounds.x,
                    .y = geometry.bounds.y,
                }, type_path_fill, color, &extra, @intCast(offset), @intCast(geometry.len()));
            }
        }
        if (shape.stroke) |stroke| {
            const offset = self.curve_count;
            const geometry = try paint_path.tessellate(shape.path, self.curves[offset..], .{
                .transform = transform,
                .stroke = .{ .width = stroke.width, .dash = stroke.dash, .phase = stroke.phase },
            });
            self.curve_count += geometry.len();
            if (geometry.len() > 0) {
                var extra: PaintExtra = .{};
                extra.shadow[0] = stroke.width;
                const pad = stroke.width * 0.5 + 1;
                self.add(record, expand(geometry.bounds, pad), .{
                    .x = 0,
                    .y = 0,
                }, type_path_stroke, lab(stroke.color), &extra, @intCast(offset), @intCast(geometry.len()));
            }
        }
    }
};

fn expand(bounds: paint.Rect, pad: f32) paint.Rect {
    return .{
        .x = bounds.x - pad,
        .y = bounds.y - pad,
        .w = bounds.w + 2 * pad,
        .h = bounds.h + 2 * pad,
    };
}

/// A plain solid uses the existing vertex-color scene path and no GPU material.
fn isFlatSolid(record: *const paint.PaintRecord, shape: *const paint.SceneRect) bool {
    const affine = record.transform;
    if (affine.a != 1 or affine.b != 0 or affine.c != 0 or affine.d != 1 or
        affine.tx != 0 or affine.ty != 0 or shape.shadows.len != 0 or
        hasBorder(&shape.borders)) return false;
    for (shape.radii) |radius| {
        if (radius != 0) return false;
    }
    const fill = shape.fill orelse return false;
    return fill == .solid;
}

fn hasBorder(sides: *const paint.SceneBorders) bool {
    for (sides) |side| {
        if (side.width > 0 and side.style != .none) return true;
    }
    return false;
}

fn lab(color: paint.Oklab) [4]f32 {
    return .{ color.l, color.a, color.b, color.alpha };
}

fn rectExtra(record: *const paint.PaintRecord, shape: *const paint.SceneRect) PaintExtra {
    const affine = record.transform;
    var extra: PaintExtra = .{};
    extra.transform_x = .{ affine.a, affine.c, affine.tx, 0 };
    extra.transform_y = .{ affine.b, affine.d, affine.ty, 0 };
    extra.size = .{ record.bounds.w, record.bounds.h, 0, 0 };
    extra.radii = shape.radii;
    for (shape.borders, 0..) |side, index| {
        extra.border_width[index] = if (side.style == .none) 0 else side.width;
        extra.border_styles[index] = @intFromEnum(side.style);
        extra.border_color[index] = lab(side.color);
    }
    return extra;
}

fn fillExtra(extra: *PaintExtra, fill: paint.SceneFill) [4]f32 {
    switch (fill) {
        .solid => |color| {
            extra.mode[0] = 0;
            extra.from = lab(color);
        },
        .gradient => |gradient| {
            extra.mode[0] = 3;
            extra.from = lab(gradient.first.color);
            extra.to = lab(gradient.second.color);
            extra.gradient = .{
                @cos(gradient.angle),    @sin(gradient.angle),
                gradient.first.position, gradient.second.position,
            };
        },
        .pattern => |pattern| {
            extra.mode[0] = if (pattern.kind == .checker) 4 else 5;
            extra.from = lab(pattern.first);
            extra.to = lab(pattern.second);
            extra.pattern = .{ pattern.cell.x, pattern.cell.y, 0, 0 };
        },
        .image_pattern => |image| {
            extra.mode[0] = 6;
            extra.mode[1] = image.texture_index;
            extra.pattern = .{ image.tile.x, image.tile.y, 0, 0 };
            extra.from = .{ 1, 0, 0, 1 };
        },
    }
    return extra.from;
}

test "api-w14 image lowering samples cropped Oklab texture without material and retains order" {
    var list = paint.PaintList.init(std.testing.allocator, &.{}, 2);
    defer list.deinit();
    try list.addRect(.{
        .bounds = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .fill = .{ .solid = .{ .srgb = .{ .r = 0.2, .g = 0.3, .b = 0.4 } } },
        .order = 3,
    });
    try list.addImage(.{
        .bounds = .{ .x = 2, .y = 3, .w = 10, .h = 8 },
        .src = .{ .x = 0.25, .y = 0.1, .w = 0.5, .h = 0.8 },
        .texture_index = 19,
        .opacity = 0.4,
        .clip_id = 7,
        .layer = 5,
        .order = 4,
    });
    var rects: [2]SceneRect = undefined;
    var materials: [0]PaintMaterial = .{};
    var curves: [0]paint_path.Quadratic = .{};
    const result = try lowerPaint(
        &.{},
        list.records.items,
        &rects,
        &curves,
        &materials,
        .{ .first = 1, .end = 1 },
    );
    try std.testing.expectEqual(@as(usize, 2), result.rects.len);
    try std.testing.expectEqual(@as(usize, 0), result.materials.len);
    const quad = result.rects[1];
    try std.testing.expectEqual([4]f32{ 2, 3, 10, 8 }, quad.dst);
    try std.testing.expectEqual([4]f32{ 0.25, 0.1, 0.5, 0.8 }, quad.src);
    try std.testing.expectEqual([4]f32{ 1, 1, 1, 0.4 }, quad.color);
    try std.testing.expectEqual(@as(u32, 19), quad.tex_idx);
    try std.testing.expectEqual(@as(u32, 0), quad.material_index);
    try std.testing.expectEqual(@as(u32, 7), quad.clip_id);
    try std.testing.expectEqual(@as(u32, 5), quad.z);
    try std.testing.expectEqual(@as(u32, 4), quad.order);
    try std.testing.expectEqual(@as(u32, 3), result.rects[0].order);
}
