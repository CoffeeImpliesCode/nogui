//! 9-slice rectangle renderer using noapi vertex buffers.
//!
//! Expands 9-slice specs into quads on the CPU and draws them
//! as a single indexed draw call. Vertex format matches
//! quad_vert.glsl: position (vec2) + uv (vec2) + color (vec4).
//!
//! PROTOTYPE — throwaway design exploration.

const std = @import("std");
const noapi = @import("noapi");

pub const VERTS_PER_RECT = 36; // 9 quads × 4 verts
pub const IDX_PER_RECT = 54; // 9 quads × 6 indices
pub const VERTEX_STRIDE = @sizeOf(Vertex);

pub const Vertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    color: [4]f32,
    material_idx: u32 = 0,
    origin: [2]f32 = .{ 0, 0 }, // screen top-left of rect (for glyph local coords)
};

/// One 9-slice rectangle to render.
pub const SliceRect = struct {
    dst_x: f32,
    dst_y: f32,
    dst_w: f32,
    dst_h: f32,
    src_u: f32 = 0,
    src_v: f32 = 0,
    src_w: f32 = 1,
    src_h: f32 = 1,
    corner_l: f32 = 0,
    corner_r: f32 = 0,
    corner_t: f32 = 0,
    corner_b: f32 = 0,
    color: [4]f32 = .{ 1, 1, 1, 1 },
    material_index: u32 = 0, // 0 = solid (per-vertex color), >0 = material buf index
    curve_left: f32 = 0, // glyph curve-space left edge (min x)
    curve_bottom: f32 = 0, // glyph curve-space bottom (min y, can be negative)
    curve_w: f32 = 0, // glyph curve-space width (extent); 0 = use corner UV
    curve_h: f32 = 0, // glyph curve-space height (max_y - min_y)
    /// Glyph pen (the outline origin) in framebuffer px. When set, the
    /// vertex origin is the pen, so the shader's sweep windows land in
    /// the SAME space as the curves (the old quad-anchored windows were
    /// off by the quad's offset from the pen). Null = the SDF rects,
    /// whose shader branch needs the rect's top-left.
    glyph_pen: ?[2]f32 = null,
};

/// Manages GPU buffers for 9-slice rendering.
pub const Batch9Slice = struct {
    gpu: *noapi.Gpu,

    /// Growing GPU buffers. Reallocated when capacity is exceeded.
    vert_buf: noapi.GpuPtr = .{ .cpu = undefined, .gpu = 0 },
    idx_buf: noapi.GpuPtr = .{ .cpu = undefined, .gpu = 0 },
    capacity: u32 = 0,

    /// Shaders for quad rendering.
    vert_shader: noapi.Shader,
    frag_shader: noapi.Shader,

    /// BDA to GPU material buffer. Written by Window before draw.
    material_buf_bda: u64 = 0,

    /// SUBPIXEL AA experiment: on = three 1/3-px column sweeps with the
    /// per-channel linear→Oklab assembly (frag_data bit 0); off = the
    /// single analytic sweep. Per-frame toggleable.
    subpixel: bool = false,
    /// QUAD DEBUG: tint every glyph quad's background (frag_data bit 1)
    /// so the quad bounds are visible against the ink — the cut-off check.
    quad_debug: bool = false,
    /// BGR subpixel order (frag_data bit 2): the panel's stripe order is
    /// often undeclared (BOE EDID) — the empirical left-stem-edge test
    /// decides; O toggles.
    bgr_order: bool = false,
    /// Subpixel chroma damping (frag_data bit 3): the one-line LCD-filter
    /// approximation (0.3); C toggles it off for the full-chroma test.
    damp_chroma: bool = true,

    const QUAD_INDICES: [6]u32 = .{ 0, 1, 2, 0, 2, 3 };

    pub fn init(gpu: *noapi.Gpu, vert_spv: []const u32, frag_spv: []const u32) !@This() {
        const vert = try gpu.shaderCreate(vert_spv, .vertex, "main", "quad_vert");
        errdefer gpu.shaderDestroy(vert);
        const frag = try gpu.shaderCreate(frag_spv, .fragment, "main", "quad_frag");
        return .{
            .gpu = gpu,
            .vert_shader = vert,
            .frag_shader = frag,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.capacity > 0) {
            self.gpu.gpuFree(self.vert_buf);
            self.gpu.gpuFree(self.idx_buf);
        }
        self.gpu.shaderDestroy(self.vert_shader);
        self.gpu.shaderDestroy(self.frag_shader);
    }

    fn ensureCapacity(self: *@This(), rect_count: u32) !void {
        const needed = @max(rect_count, 1);
        if (needed <= self.capacity) return;

        const vert_bytes = needed * VERTS_PER_RECT * VERTEX_STRIDE;
        const idx_bytes = needed * IDX_PER_RECT * @sizeOf(u32);

        // Free old buffers before allocating new ones
        if (self.capacity > 0) {
            self.gpu.gpuFree(self.vert_buf);
            self.gpu.gpuFree(self.idx_buf);
        }

        self.vert_buf = try self.gpu.gpuMalloc(vert_bytes, 64, .default);
        self.idx_buf = try self.gpu.gpuMalloc(idx_bytes, 16, .default);
        self.capacity = needed;
    }

    /// Expand slice rects into vertex/index buffers and draw.
    pub fn draw(self: *@This(), cmd: anytype, rects: []const SliceRect, screen_w: f32, screen_h: f32) !void {
        if (rects.len == 0) return;
        std.debug.assert(rects.len <= std.math.maxInt(u32));
        try self.ensureCapacity(@intCast(rects.len));

        // Write vertices and indices
        const verts: [*]Vertex = @ptrCast(@alignCast(self.vert_buf.cpu));
        const idxs: [*]u32 = @ptrCast(@alignCast(self.idx_buf.cpu));

        var vert_offset: u32 = 0;
        var idx_offset: u32 = 0;

        for (rects) |r| {
            self.emitSliceRect(verts[vert_offset .. vert_offset + VERTS_PER_RECT], idxs[idx_offset .. idx_offset + IDX_PER_RECT], &r, vert_offset, screen_w, screen_h);
            vert_offset += VERTS_PER_RECT;
            idx_offset += IDX_PER_RECT;
        }

        // Bind and draw
        cmd.setShaders(self.vert_shader, self.frag_shader);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.setVertexInput(
            &.{.{ .binding = 0, .stride = VERTEX_STRIDE, .input_rate = 0 }},
            &.{
                .{ .location = 0, .binding = 0, .format = @intFromEnum(noapi.vk.Format.r32g32_sfloat), .offset = @offsetOf(Vertex, "position") },
                .{ .location = 1, .binding = 0, .format = @intFromEnum(noapi.vk.Format.r32g32_sfloat), .offset = @offsetOf(Vertex, "uv") },
                .{ .location = 2, .binding = 0, .format = @intFromEnum(noapi.vk.Format.r32g32b32a32_sfloat), .offset = @offsetOf(Vertex, "color") },
                .{ .location = 3, .binding = 0, .format = @intFromEnum(noapi.vk.Format.r32_uint), .offset = @offsetOf(Vertex, "material_idx") },
                .{ .location = 4, .binding = 0, .format = @intFromEnum(noapi.vk.Format.r32g32_sfloat), .offset = @offsetOf(Vertex, "origin") },
            },
        );
        cmd.bindVertexBuffer(0, self.vert_buf, 0);
        // Pass material buffer BDA in vert_data push constant field; the
        // subpixel-AA toggle (bit 0) and the quad-debug tint (bit 1) in
        // frag_data.
        const push = noapi.PushData{
            .vert_data = self.material_buf_bda,
            .frag_data = (if (self.subpixel) @as(u64, 1) else 0) |
                (if (self.quad_debug) @as(u64, 2) else 0) |
                (if (self.bgr_order) @as(u64, 4) else 0) |
                (if (self.damp_chroma) @as(u64, 8) else 0),
        };
        const idx_count = rects.len * IDX_PER_RECT;
        std.debug.assert(idx_count <= std.math.maxInt(u32));
        cmd.drawIndexed(push, self.idx_buf, @intCast(idx_count), 1, 0, 0);
    }

    fn emitSliceRect(self: *@This(), verts: []Vertex, idxs: []u32, r: *const SliceRect, base_vert: u32, sw: f32, sh: f32) void {
        _ = self;
        // Compute the 3×3 grid in destination space
        const x0 = r.dst_x;
        const x1 = r.dst_x + r.corner_l;
        const x2 = r.dst_x + r.dst_w - r.corner_r;
        const x3 = r.dst_x + r.dst_w;

        const y0 = r.dst_y;
        const y1 = r.dst_y + r.corner_t;
        const y2 = r.dst_y + r.dst_h - r.corner_b;
        const y3 = r.dst_y + r.dst_h;

        // Clamp to prevent overlaps
        const x1c = @min(x1, x2);
        const x2c = @max(x1, x2);
        const y1c = @min(y1, y2);
        const y2c = @max(y1, y2);

        // Normalized corner sizes within source UV rect
        const cn_l = if (r.src_w > 0) r.corner_l / r.dst_w * r.src_w else 0;
        const cn_r = if (r.src_w > 0) r.corner_r / r.dst_w * r.src_w else 0;
        const cn_t = if (r.src_h > 0) r.corner_t / r.dst_h * r.src_h else 0;
        const cn_b = if (r.src_h > 0) r.corner_b / r.dst_h * r.src_h else 0;

        // Source UV grid
        const tu0 = r.src_u;
        const tu1 = r.src_u + cn_l;
        const tu2 = r.src_u + r.src_w - cn_r;
        const tu3 = r.src_u + r.src_w;

        const tv0 = r.src_v;
        const tv1 = r.src_v + cn_t;
        const tv2 = r.src_v + r.src_h - cn_b;
        const tv3 = r.src_v + r.src_h;

        // X segments: 3 positions × 3 Y segments = 9 quads
        const xs = [_]f32{ x0, x1c, x2c, x3 };
        const ys = [_]f32{ y0, y1c, y2c, y3 };
        const us = [_]f32{ tu0, tu1, tu2, tu3 };
        const vs = [_]f32{ tv0, tv1, tv2, tv3 };

        var vi: u32 = 0;
        var ii: u32 = 0;

        for (0..3) |row| {
            for (0..3) |col| {
                // 4 corners of this sub-quad
                const qv = comptime [_]struct { usize, usize }{
                    .{ 0, 0 }, // TL
                    .{ 1, 0 }, // TR
                    .{ 1, 1 }, // BR
                    .{ 0, 1 }, // BL
                };

                for (qv) |cv| {
                    const px = xs[col + cv[0]];
                    const py = ys[row + cv[1]];

                    // Convert to clip space (-1..1)
                    // Vulkan NDC: Y points down (top=-1, bottom=+1)
                    // Layout: Y points down (top=0, bottom=h)
                    // No flip needed — both conventions match.
                    const clip_x = (px / sw) * 2.0 - 1.0;
                    const clip_y = (py / sh) * 2.0 - 1.0;

                    // For glyph rects, UV = curve-space position (Y-up: 0=baseline at bottom)
                    const use_curve_uv = r.material_index > 0 and r.curve_w > 0 and r.curve_h > 0;
                    const uv_x = if (use_curve_uv)
                        r.curve_left + r.curve_w * (px - r.dst_x) / r.dst_w
                    else
                        us[col + cv[0]];
                    const uv_y = if (use_curve_uv)
                        (r.curve_h + r.curve_bottom) - r.curve_h * (py - r.dst_y) / r.dst_h
                    else
                        vs[row + cv[1]];

                    verts[vi] = .{
                        .position = .{ clip_x, clip_y },
                        .uv = .{ uv_x, uv_y },
                        .color = r.color,
                        .material_idx = r.material_index,
                        .origin = r.glyph_pen orelse .{ r.dst_x, r.dst_y },
                    };
                    vi += 1;
                }

                // 6 indices per quad
                const bv = base_vert + vi - 4;
                for (QUAD_INDICES) |qi| {
                    idxs[ii] = bv + qi;
                    ii += 1;
                }
            }
        }
    }
};
