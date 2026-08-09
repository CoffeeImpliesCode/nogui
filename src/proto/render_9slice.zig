//! 9-slice rectangle renderer using noapi vertex buffers.
//!
//! Per-rect instancing (P2b): the batch uploads ONE SceneRect per sub-quad
//! instance (9 copies per rect) into an INSTANCE buffer (binding 1,
//! input_rate = instance) and draws every sub-quad with the SHARED 6-index
//! quad {0,1,2,0,2,3} — index_count 6, instance_count = rects.len*9, base
//! vertex 0. The vertex shader (quad_vert.slang) builds the 3×3 9-slice
//! grid from SV_VertexID (corner 0-3) + SV_InstanceID (sub-quad 0-8; the
//! rect is instance/9 — the 9× layout makes the hardware instance fetch
//! deliver rects[instance/9] directly), reproducing the old CPU
//! emitSceneRect arithmetic exactly: same clip-space positions, same UVs,
//! same per-corner color/material/origin/clip → byte-identical pixels.
//! P3 adds the flat tex_idx attribute (location 9) — the bindless texture
//! heap index the fragment shader's TYPE_TEXTURE branch samples; rects
//! without a texture carry 0xFFFFFFFF, so their output is unchanged. The
//! framebuffer size travels in the push constant's screen field (offset
//! 24) for the clip-space conversion.
//!
//! Drawn as ONE indirect indexed draw (drawIndexedIndirectMulti with a
//! single command + count buffer — the P1 plumbing; same indices → same
//! pixels).
//!
//! PROTOTYPE — throwaway design exploration.

const std = @import("std");
const noapi = @import("noapi");
/// GPU-facing clip rect (the batch's own type — the widget core's ClipRect
/// is a distinct module identity; the window converts between them).
pub const ClipRect = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// GPU clip-rect buffer cap (matches the widget core's per-frame list;
/// the fragment shader indexes it by clip_id).
pub const MAX_CLIP_RECTS = 64;

/// One 9-slice rectangle to render. Compact scene record — the vertex
/// shader reads the fields as per-instance attributes (binding 1) and
/// builds the 3×3 grid; no CPU geometry expansion.
pub const SceneRect = extern struct {
    dst: [4]f32, // dst_x, dst_y, dst_w, dst_h
    src: [4]f32, // src_u, src_v, src_w, src_h
    corners: [4]f32, // corner_l, corner_r, corner_t, corner_b
    color: [4]f32,
    curve: [4]f32, // curve_left, curve_bottom, curve_w, curve_h
    material_index: u32, // 0 = solid (per-vertex color), >0 = material buf index
    clip_id: u32 = 0xFFFFFFFF, // NEW: index into the clip-rect buffer; ~0 = no clip (P1)
    z: u32 = 0, // NEW: layer key (P1 uses it); 0 for now
    origin: [2]f32 = .{ 0, 0 }, // the vertex origin: the glyph pen OR the rect top-left
    tex_idx: u32 = 0xFFFFFFFF, // NEW: bindless texture heap index; ~0 = no texture (P3)
};

/// Manages GPU buffers for 9-slice rendering.
pub const Batch9Slice = struct {
    gpu: *noapi.Gpu,

    /// Growing GPU buffers. Reallocated when capacity is exceeded.
    /// inst_buf holds 9 SceneRects per rect (one per sub-quad instance);
    /// idx_buf holds the shared 6-index quad (reused by every instance).
    inst_buf: noapi.GpuPtr = .{ .cpu = undefined, .gpu = 0 },
    idx_buf: noapi.GpuPtr = .{ .cpu = undefined, .gpu = 0 },
    capacity: u32 = 0,

    /// Indirect-command buffer (one DrawIndexedIndirectCommand per
    /// capacity rect; the draw uses a single command) + the count buffer
    /// (the draw's command count, always 1). Host-visible, grown with
    /// inst_buf/idx_buf. The one indirect draw replaces cmd.drawIndexed:
    /// same indices, same pixels — the plumbing the P1 pipeline builds on.
    indirect_buf: noapi.GpuPtr = .{ .cpu = undefined, .gpu = 0 },
    count_buf: noapi.GpuPtr = .{ .cpu = undefined, .gpu = 0 },

    /// GPU clip-rect buffer (fixed cap MAX_CLIP_RECTS, host-visible):
    /// the fragment shader's clip test reads it via push.indirect (the
    /// PushData field the noapi surface reserves at offset 16). The batch
    /// rewrites it from the frame's clip list before every draw.
    clip_buf: noapi.GpuPtr = .{ .cpu = undefined, .gpu = 0 },

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

    /// The SHARED quad: 6 indices (TL,TR,BR / TL,BR,BL) reused by every
    /// instance. Base vertex 0 — each instance's corners come from
    /// gl_VertexIndex (0-3), not from a vertex buffer.
    const QUAD_INDICES: [6]u32 = .{ 0, 1, 2, 0, 2, 3 };
    /// Sub-quads per rect (the 3×3 grid) — one instance per sub-quad.
    const SUB_QUADS_PER_RECT = 9;

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
            self.gpu.gpuFree(self.inst_buf);
            self.gpu.gpuFree(self.idx_buf);
            self.gpu.gpuFree(self.indirect_buf);
            self.gpu.gpuFree(self.count_buf);
            self.gpu.gpuFree(self.clip_buf);
        }
        self.gpu.shaderDestroy(self.vert_shader);
        self.gpu.shaderDestroy(self.frag_shader);
    }

    fn ensureCapacity(self: *@This(), rect_count: u32) !void {
        const needed = @max(rect_count, 1);
        if (needed <= self.capacity) return;

        // 9 sub-quad instances per rect; the index buffer is the shared
        // 6-index quad, fixed regardless of capacity.
        const inst_bytes = needed * SUB_QUADS_PER_RECT * @sizeOf(SceneRect);
        const idx_bytes = QUAD_INDICES.len * @sizeOf(u32);
        const indirect_bytes = needed * @sizeOf(noapi.DrawIndexedIndirectCommand);

        // Free old buffers before allocating new ones
        if (self.capacity > 0) {
            self.gpu.gpuFree(self.inst_buf);
            self.gpu.gpuFree(self.idx_buf);
            self.gpu.gpuFree(self.indirect_buf);
            self.gpu.gpuFree(self.count_buf);
            self.gpu.gpuFree(self.clip_buf);
        }

        self.inst_buf = try self.gpu.gpuMalloc(inst_bytes, 64, .default);
        self.idx_buf = try self.gpu.gpuMalloc(idx_bytes, 16, .default);
        self.indirect_buf = try self.gpu.gpuMalloc(indirect_bytes, 16, .default);
        self.count_buf = try self.gpu.gpuMalloc(@sizeOf(u32), 4, .default);
        self.clip_buf = try self.gpu.gpuMalloc(MAX_CLIP_RECTS * @sizeOf(ClipRect), 64, .default);
        self.capacity = needed;

        // The shared 6-index quad, written once at allocation — every
        // instance draws corners 0-3 of its own sub-quad via
        // gl_VertexIndex (base vertex 0).
        const idxs: [*]u32 = @ptrCast(@alignCast(self.idx_buf.cpu));
        for (QUAD_INDICES, 0..) |ix, i| idxs[i] = ix;
    }

    /// Upload the scene rects (one instance per sub-quad) and draw.
    /// `clip_rects` is the frame's clip list (indices referenced by rects'
    /// clip_id); the batch copies it into the GPU clip buffer, whose BDA
    /// travels in the push constant's `indirect` field. With no clips (all
    /// clip_ids ~0) the shader test is a no-op and the output is
    /// byte-identical to a plain indexed draw. `screen_w/screen_h` are the
    /// framebuffer size (px) — the VS's clip-space conversion.
    pub fn draw(self: *@This(), cmd: anytype, rects: []const SceneRect, clip_rects: []const ClipRect, screen_w: f32, screen_h: f32) !void {
        if (rects.len == 0) return;
        std.debug.assert(rects.len <= std.math.maxInt(u32) / SUB_QUADS_PER_RECT);
        try self.ensureCapacity(@intCast(rects.len));

        // Instance buffer: one SceneRect per sub-quad instance — rect i
        // repeated SUB_QUADS_PER_RECT times. gl_InstanceIndex j fetches
        // rects[j / 9]'s data directly; the VS splits sub-quad = j % 9.
        const instances: [*]SceneRect = @ptrCast(@alignCast(self.inst_buf.cpu));
        for (rects, 0..) |r, i| {
            for (0..SUB_QUADS_PER_RECT) |k| instances[i * SUB_QUADS_PER_RECT + k] = r;
        }

        // Clip rects → the host-visible clip buffer (the shader's clip
        // test reads them via pc.indirect + 16 * clip_id).
        const clips: [*]ClipRect = @ptrCast(@alignCast(self.clip_buf.cpu));
        std.debug.assert(clip_rects.len <= MAX_CLIP_RECTS);
        for (clip_rects, 0..) |c, i| clips[i] = c;

        // Bind and draw
        cmd.setShaders(self.vert_shader, self.frag_shader);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        // Vertex input: binding 0 = NONE (the corners come from
        // gl_VertexIndex — no position buffer); binding 1 = the SceneRect
        // at INSTANCE rate, one rect per sub-quad instance.
        cmd.setVertexInput(
            &.{.{ .binding = 1, .stride = @sizeOf(SceneRect), .input_rate = 1 }},
            &.{
                .{ .location = 0, .binding = 1, .format = @intFromEnum(noapi.vk.Format.r32g32b32a32_sfloat), .offset = @offsetOf(SceneRect, "dst") },
                .{ .location = 1, .binding = 1, .format = @intFromEnum(noapi.vk.Format.r32g32b32a32_sfloat), .offset = @offsetOf(SceneRect, "src") },
                .{ .location = 2, .binding = 1, .format = @intFromEnum(noapi.vk.Format.r32g32b32a32_sfloat), .offset = @offsetOf(SceneRect, "corners") },
                .{ .location = 3, .binding = 1, .format = @intFromEnum(noapi.vk.Format.r32g32b32a32_sfloat), .offset = @offsetOf(SceneRect, "color") },
                .{ .location = 4, .binding = 1, .format = @intFromEnum(noapi.vk.Format.r32g32b32a32_sfloat), .offset = @offsetOf(SceneRect, "curve") },
                .{ .location = 5, .binding = 1, .format = @intFromEnum(noapi.vk.Format.r32_uint), .offset = @offsetOf(SceneRect, "material_index") },
                .{ .location = 6, .binding = 1, .format = @intFromEnum(noapi.vk.Format.r32_uint), .offset = @offsetOf(SceneRect, "clip_id") },
                .{ .location = 7, .binding = 1, .format = @intFromEnum(noapi.vk.Format.r32_uint), .offset = @offsetOf(SceneRect, "z") },
                .{ .location = 8, .binding = 1, .format = @intFromEnum(noapi.vk.Format.r32g32_sfloat), .offset = @offsetOf(SceneRect, "origin") },
                .{ .location = 9, .binding = 1, .format = @intFromEnum(noapi.vk.Format.r32_uint), .offset = @offsetOf(SceneRect, "tex_idx") },
            },
        );
        cmd.bindVertexBuffer(1, self.inst_buf, 0);
        // Pass material buffer BDA in vert_data push constant field; the
        // subpixel-AA toggle (bit 0) and the quad-debug tint (bit 1) in
        // frag_data; the clip-rect buffer BDA in indirect; the framebuffer
        // size (px) in screen — the VS's clip-space conversion.
        const push = noapi.PushData{
            .vert_data = self.material_buf_bda,
            .frag_data = (if (self.subpixel) @as(u64, 1) else 0) |
                (if (self.quad_debug) @as(u64, 2) else 0) |
                (if (self.bgr_order) @as(u64, 4) else 0) |
                (if (self.damp_chroma) @as(u64, 8) else 0),
            .indirect = self.clip_buf.gpu,
            .screen = .{ screen_w, screen_h },
        };
        const instance_count = @as(u32, @intCast(rects.len)) * SUB_QUADS_PER_RECT;
        // One indirect command drawing the shared 6-index quad ×
        // instance_count (one sub-quad per instance; base vertex 0 — the
        // VS builds every corner from gl_VertexIndex + gl_InstanceIndex).
        // Same pixels as the old CPU-expanded draw (count buffer = 1
        // command), through the indirect path the GPU-driven pipeline
        // builds on.
        const indirect: [*]noapi.DrawIndexedIndirectCommand = @ptrCast(@alignCast(self.indirect_buf.cpu));
        const count: [*]u32 = @ptrCast(@alignCast(self.count_buf.cpu));
        indirect[0] = .{
            .index_count = QUAD_INDICES.len,
            .instance_count = instance_count,
            .first_index = 0,
            .vertex_offset = 0,
            .first_instance = 0,
        };
        count[0] = 1;
        cmd.drawIndexedIndirectMulti(push, self.idx_buf, self.indirect_buf, @sizeOf(noapi.DrawIndexedIndirectCommand), self.count_buf, 0, 1);
    }
};
