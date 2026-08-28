//! 9-slice rectangle renderer using noapi vertex buffers — V1b: the
//! GPU z-sort (CS1) + the sorted-permutation draw.
//!
//! The batch owns the DRAWABLE BAG (the v1 spec §2): a host-visible
//! SceneRect array, ONE record per rect (112 B, 16-aligned stride),
//! uploaded once per frame in any order. CS1 (shaders/sort.comp.slang)
//! runs a stable LSD radix on the 64-bit key (z << 32) | order and writes
//! a sorted permutation (u32 bag indices, device-local, per-frame ×2
//! ring, ping-pong A/B). The ONE indirect draw
//! (drawIndexedIndirectMulti, the shared 6-index quad
//! {0,1,2,0,2,3} × instance_count = rects.len * 9) then renders through
//! the permutation: the vertex shader (quad_vert.slang) fetches
//! bag[perm[instance / 9]] via the physical-storage-buffer BDAs in the
//! push constant (scene_bda + perm_bda) and builds the 3×3 9-slice grid
//! from SV_VertexID + SV_InstanceID — no vertex buffer, no instance
//! attributes, zero descriptor sets at draw time. The grid/UV/clip-space
//! arithmetic is the CPU emitSceneRect math verbatim, so on the
//! paint-ordered bag (the sort = the identity) the pixels are
//! byte-identical to the pre-V1b pipeline.
//!
//! Recording order matters: CS1 dispatches cannot run inside dynamic
//! rendering, so the frame is recorded as sort() OUTSIDE the render pass
//! (host uploads + 17 dispatches + the compute→graphics barrier) and
//! draw() INSIDE it (the one indirect draw). The CS-written buffers
//! (permutation/scratch) plus the CPU-rewritten bag/params are per-frame
//! rings ×2 — the beginFrame fence only gates CPU recording, not the
//! previous frame's GPU execution.
//!
//! Active v7 renderer primitive.

const std = @import("std");
const noapi = @import("noapi");
/// GPU-facing clip rect. An extent of -1 disables that axis.
/// The widget core keeps the same 16-byte field layout and sentinel.
pub const ClipRect = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// GPU clip-rect buffer cap (matches the widget core's per-frame list;
/// the fragment shader indexes it by clip_id).
pub const max_clip_rects = 64;

/// One 9-slice rectangle to render. Compact scene record — the DRAWABLE
/// of the v1 bag contract: the CPU appends in ANY order, the GPU sort
/// establishes the paint order from (z, order). 112 B (the trailing pad
/// makes the bag stride 16-aligned, so the shaders' physical-storage-
/// buffer loads are naturally aligned — verified against the Slang
/// struct in sort.comp.slang/quad_vert.slang).
pub const SceneRect = extern struct {
    dst: [4]f32, // dst_x, dst_y, dst_w, dst_h
    src: [4]f32, // src_u, src_v, src_w, src_h
    corners: [4]f32, // corner_l, corner_r, corner_t, corner_b
    color: [4]f32,
    curve: [4]f32, // curve_left, curve_bottom, curve_w, curve_h
    material_index: u32, // 0 = solid (per-vertex color), >0 = material buf index
    clip_id: u32 = 0xFFFFFFFF, // index into the clip-rect buffer; ~0 = no clip (P1)
    z: u32 = 0, // layer key: the SORT KEY (v1); 0 = the base tree
    origin: [2]f32 = .{ 0, 0 }, // the vertex origin: the glyph pen OR the rect top-left
    tex_idx: u32 = 0xFFFFFFFF, // bindless texture heap index; ~0 = no texture (P3)
    order: u32 = 0, // submission counter: the stable tiebreaker (v1)
    _pad: [4]u8 = .{ 0, 0, 0, 0 }, // 108 → 112 (the 16-aligned bag stride)
};

/// One sort-dispatch parameter entry (48 B — layout MUST match SortParams
/// in shaders/sort.comp.slang). The batch writes sort_dispatches entries
/// per frame; the push constant of each dispatch is the BDA of its entry
/// (the mandelbrot u64-BDA precedent).
pub const SortParams = extern struct {
    bag_bda: u64, // the drawable bag
    perm_a_bda: u64, // permutation A (identity input, final result)
    perm_b_bda: u64, // permutation B (the ping-pong target)
    hist_bda: u64, // per-group histogram scratch (groups × 256 u32)
    count: u32, // drawable count
    mode: u32, // 0 identity, 1 histogram, 2 scatter
    pass: u32, // the key byte (0..7; 0-3 = order, 4-7 = z)
    _pad: u32 = 0,
};

/// Radix passes: the 8 key bytes (order×4 first — the LSD — then z×4).
pub const sort_passes = 8;
/// Dispatches per frame: the identity init + histogram + scatter per pass.
pub const sort_dispatches = 1 + 2 * sort_passes;
/// Workgroup size of the sort (one element per thread).
const sort_group = 256;
/// Sort scratch histogram entries per group (one per radix digit).
const sort_buckets = 256;

/// Manages GPU buffers for 9-slice rendering.
pub const Batch9Slice = struct {
    gpu: *noapi.Gpu,

    /// Growing GPU buffers, reallocated when capacity is exceeded.
    /// The V1b set: the bag + the CS1 permutation/scratch are per-frame
    /// rings ×3 (indexed by self.frame % 3 — the demo runs THREE frames
    /// in flight, so a ×2 ring would let frame N+2 overwrite the slot
    /// frame N's GPU is still reading: the GPU driver crash); the shared
    /// quad, the indirect/count buffers and the clip buffer are
    /// frame-agnostic.
    bag_buf: [3]noapi.GpuPtr = .{noapi.GpuPtr{ .cpu = undefined, .gpu = 0 }} ** 3, // host: N × SceneRect (112 B)
    perm_a: [3]noapi.GpuPtr = .{noapi.GpuPtr{ .cpu = undefined, .gpu = 0 }} ** 3, // gpu: N × u32 (even passes)
    perm_b: [3]noapi.GpuPtr = .{noapi.GpuPtr{ .cpu = undefined, .gpu = 0 }} ** 3, // gpu: N × u32 (odd passes)
    hist_buf: [3]noapi.GpuPtr = .{noapi.GpuPtr{ .cpu = undefined, .gpu = 0 }} ** 3, // gpu: groups × 256 u32 scratch
    params_buf: [3]noapi.GpuPtr = .{noapi.GpuPtr{ .cpu = undefined, .gpu = 0 }} ** 3, // host: sort dispatch params
    idx_buf: noapi.GpuPtr = .{ .cpu = undefined, .gpu = 0 },
    capacity: u32 = 0,

    /// Indirect-command buffer (one DrawIndexedIndirectCommand per
    /// capacity rect; the draw uses a single command) + the count buffer
    /// (the draw's command count, always 1). Host-visible, grown with
    /// the rest. The one indirect draw replaces cmd.drawIndexed: same
    /// indices, same pixels — the plumbing the P1 pipeline builds on.
    indirect_buf: noapi.GpuPtr = .{ .cpu = undefined, .gpu = 0 },
    count_buf: noapi.GpuPtr = .{ .cpu = undefined, .gpu = 0 },

    /// GPU clip-rect buffer (fixed cap max_clip_rects, host-visible):
    /// the fragment shader's clip test reads it via push.indirect (the
    /// PushData field the noapi surface reserves at offset 16). The batch
    /// rewrites it from the frame's clip list before every draw.
    clip_buf: noapi.GpuPtr = .{ .cpu = undefined, .gpu = 0 },

    /// Shaders for quad rendering + the CS1 sort.
    vert_shader: noapi.Shader,
    frag_shader: noapi.Shader,
    sort_shader: noapi.Shader,

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

    /// ×2 ring index (the sort's outputs + the CPU-rewritten buffers are
    /// per-frame: the beginFrame fence does not gate the previous frame's
    /// GPU execution). Incremented per sort().
    frame: u32 = 0,
    /// The ring slot of the current frame's sort (sort() stores it for
    /// draw()).
    cur_slot: u32 = 0,
    /// The draw's instance count (set by sort(), consumed by draw()).
    draw_instance_count: u32 = 0,

    /// The SHARED quad: 6 indices (TL,TR,BR / TL,BR,BL) reused by every
    /// instance. Base vertex 0 — each instance's corners come from
    /// gl_VertexIndex (0-3), not from a vertex buffer.
    const quad_indices: [6]u32 = .{ 0, 1, 2, 0, 2, 3 };
    /// Sub-quads per rect (the 3×3 grid) — one instance per sub-quad.
    const sub_quads_per_rect = 9;

    pub fn init(gpu: *noapi.Gpu, vert_spv: []const u32, frag_spv: []const u32, sort_spv: []const u32) !Batch9Slice {
        const vert = try gpu.shaderCreate(vert_spv, .vertex, "main", "quad_vert");
        errdefer gpu.shaderDestroy(vert);
        const frag = try gpu.shaderCreate(frag_spv, .fragment, "main", "quad_frag");
        errdefer gpu.shaderDestroy(frag);
        const sort_sh = try gpu.shaderCreate(sort_spv, .compute, "main", "sort_comp");
        return .{
            .gpu = gpu,
            .vert_shader = vert,
            .frag_shader = frag,
            .sort_shader = sort_sh,
        };
    }

    pub fn deinit(self: *Batch9Slice) void {
        if (self.capacity > 0) {
            for (&self.bag_buf) |b| self.gpu.gpuFree(b);
            for (&self.perm_a) |b| self.gpu.gpuFree(b);
            for (&self.perm_b) |b| self.gpu.gpuFree(b);
            for (&self.hist_buf) |b| self.gpu.gpuFree(b);
            for (&self.params_buf) |b| self.gpu.gpuFree(b);
            self.gpu.gpuFree(self.idx_buf);
            self.gpu.gpuFree(self.indirect_buf);
            self.gpu.gpuFree(self.count_buf);
            self.gpu.gpuFree(self.clip_buf);
        }
        self.gpu.shaderDestroy(self.vert_shader);
        self.gpu.shaderDestroy(self.frag_shader);
        self.gpu.shaderDestroy(self.sort_shader);
        self.* = undefined;
    }

    fn ensureCapacity(self: *Batch9Slice, rect_count: u32) !void {
        const needed = @max(rect_count, 1);
        if (needed <= self.capacity) return;

        const groups = (needed + sort_group - 1) / sort_group;
        const bag_bytes = needed * @sizeOf(SceneRect);
        const perm_bytes = needed * @sizeOf(u32);
        const hist_bytes = groups * sort_buckets * @sizeOf(u32);
        const params_bytes = sort_dispatches * @sizeOf(SortParams);
        const idx_bytes = quad_indices.len * @sizeOf(u32);
        const indirect_bytes = needed * @sizeOf(noapi.DrawIndexedIndirectCommand);

        // Free old buffers before allocating new ones.
        if (self.capacity > 0) {
            for (&self.bag_buf) |b| self.gpu.gpuFree(b);
            for (&self.perm_a) |b| self.gpu.gpuFree(b);
            for (&self.perm_b) |b| self.gpu.gpuFree(b);
            for (&self.hist_buf) |b| self.gpu.gpuFree(b);
            for (&self.params_buf) |b| self.gpu.gpuFree(b);
            self.gpu.gpuFree(self.idx_buf);
            self.gpu.gpuFree(self.indirect_buf);
            self.gpu.gpuFree(self.count_buf);
            self.gpu.gpuFree(self.clip_buf);
        }

        for (&self.bag_buf) |*b| b.* = try self.gpu.gpuMalloc(bag_bytes, 64, .default);
        for (&self.perm_a) |*b| b.* = try self.gpu.gpuMalloc(perm_bytes, 64, .gpu);
        for (&self.perm_b) |*b| b.* = try self.gpu.gpuMalloc(perm_bytes, 64, .gpu);
        for (&self.hist_buf) |*b| b.* = try self.gpu.gpuMalloc(hist_bytes, 64, .gpu);
        for (&self.params_buf) |*b| b.* = try self.gpu.gpuMalloc(params_bytes, 64, .default);
        self.idx_buf = try self.gpu.gpuMalloc(idx_bytes, 16, .default);
        self.indirect_buf = try self.gpu.gpuMalloc(indirect_bytes, 16, .default);
        self.count_buf = try self.gpu.gpuMalloc(@sizeOf(u32), 4, .default);
        self.clip_buf = try self.gpu.gpuMalloc(max_clip_rects * @sizeOf(ClipRect), 64, .default);
        self.capacity = needed;

        // The shared 6-index quad, written once at allocation — every
        // instance draws corners 0-3 of its own sub-quad via
        // gl_VertexIndex (base vertex 0).
        const idxs: [*]u32 = @ptrCast(@alignCast(self.idx_buf.cpu));
        for (quad_indices, 0..) |ix, i| idxs[i] = ix;
    }

    /// CS1 — record the GPU z-sort OUTSIDE the render pass: upload the
    /// bag (ONE SceneRect per drawable — the 9-copies-per-rect instance
    /// buffer is gone; the VS builds all 9 sub-quads from the single
    /// record) + the clip rects, write the sort_dispatches parameter
    /// entries, dispatch the stable radix (identity, then 8 passes ×
    /// histogram + scatter), and barrier compute → graphics so the draw
    /// sees the permutation. The permutation ends in perm_a[slot] (pass 7
    /// writes A) — draw() reads it through the push constant.
    pub fn sort(self: *Batch9Slice, cmd: anytype, rects: []const SceneRect, clip_rects: []const ClipRect) !void {
        if (rects.len == 0) {
            self.draw_instance_count = 0;
            return;
        }
        std.debug.assert(rects.len <= std.math.maxInt(u32) / sub_quads_per_rect);
        try self.ensureCapacity(@intCast(rects.len));
        const n: u32 = @intCast(rects.len);
        self.draw_instance_count = n * sub_quads_per_rect;
        const slot = self.frame % 3;
        self.cur_slot = slot;
        self.frame +%= 1;

        // The bag: ONE copy per rect (the v1 bag contract — the CPU may
        // emit in any order; the sort establishes the paint order).
        const bag: [*]SceneRect = @ptrCast(@alignCast(self.bag_buf[slot].cpu));
        @memcpy(bag[0..rects.len], rects);

        // Clip rects → the host-visible clip buffer. The fragment shader
        // reads 16-byte entries and treats a -1 extent as an unclipped axis.
        const clips: [*]ClipRect = @ptrCast(@alignCast(self.clip_buf.cpu));
        std.debug.assert(clip_rects.len <= max_clip_rects);
        for (clip_rects, 0..) |c, i| clips[i] = c;

        // Sort params: one 48 B entry per dispatch; the push constant of
        // each dispatch is its entry's BDA (the mandelbrot u64 pattern).
        const groups: u32 = (n + sort_group - 1) / sort_group;
        const base: SortParams = .{
            .bag_bda = self.bag_buf[slot].gpu,
            .perm_a_bda = self.perm_a[slot].gpu,
            .perm_b_bda = self.perm_b[slot].gpu,
            .hist_bda = self.hist_buf[slot].gpu,
            .count = n,
            .mode = 0,
            .pass = 0,
        };
        const params: [*]SortParams = @ptrCast(@alignCast(self.params_buf[slot].cpu));
        params[0] = base;
        for (0..sort_passes) |p| {
            params[1 + 2 * p] = .{
                .bag_bda = base.bag_bda,
                .perm_a_bda = base.perm_a_bda,
                .perm_b_bda = base.perm_b_bda,
                .hist_bda = base.hist_bda,
                .count = base.count,
                .mode = 1,
                .pass = @intCast(p),
            };
            params[2 + 2 * p] = .{
                .bag_bda = base.bag_bda,
                .perm_a_bda = base.perm_a_bda,
                .perm_b_bda = base.perm_b_bda,
                .hist_bda = base.hist_bda,
                .count = base.count,
                .mode = 2,
                .pass = @intCast(p),
            };
        }

        cmd.setComputeShader(self.sort_shader);
        var d: usize = 0;
        while (d < sort_dispatches) : (d += 1) {
            // Explicit compute→compute barrier BEFORE every dispatch after
            // the first: dispatch-to-dispatch visibility is NOT reliable on
            // this stack (verified: the histogram's writes were invisible to
            // the scatter's reads without it — the identity/scatter ran on
            // stale zeros). The spec's CS1→CS2 chain is the same barrier.
            if (d > 0) cmd.barrier(.{ .compute = true }, .{ .compute = true }, .{});
            cmd.dispatch(self.params_buf[slot].gpu + @as(u64, d) * @sizeOf(SortParams), groups, 1, 1);
        }
        // CS1 wrote the permutation; the draw reads it in the VS (BDA
        // shader read) + the indirect buffer (draw_arguments hazard —
        // CPU-written this frame, but the chain is the spec's CS1→GFX
        // contract for when CS3 moves it GPU-side).
        cmd.barrier(.{ .compute = true }, .{ .vertex = true, .fragment = true }, .{});
        cmd.barrier(.{ .compute = true }, .{ .vertex = true }, .{ .draw_arguments = true });
    }

    /// The ONE indirect draw, recorded INSIDE the render pass: the
    /// shared 6-index quad × (rects.len * 9) instances, the vertex shader
    /// fetching bag[perm[instance / 9]] through the push-constant BDAs.
    /// Must follow sort() in the same frame.
    pub fn draw(self: *Batch9Slice, cmd: anytype, screen_w: f32, screen_h: f32) void {
        const instance_count = self.draw_instance_count;
        if (instance_count == 0) return;
        const slot = self.cur_slot;

        // Bind and draw
        cmd.setShaders(self.vert_shader, self.frag_shader);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        // Vertex input: NONE — the rect data travels as BDAs in the push
        // constant (scene_bda + perm_bda); the corners come from
        // gl_VertexIndex, the rect from bag[perm[instance / 9]].
        cmd.setVertexInput(&.{}, &.{});
        // Pass material buffer BDA in vert_data push constant field; the
        // subpixel-AA toggle (bit 0) and the quad-debug tint (bit 1) in
        // frag_data; the clip-rect buffer BDA in indirect; the framebuffer
        // size (px) in screen; the bag + sorted permutation BDAs in
        // scene_bda/perm_bda (V1b).
        const push: noapi.PushData = .{
            .vert_data = self.material_buf_bda,
            .frag_data = (if (self.subpixel) @as(u64, 1) else 0) |
                (if (self.quad_debug) @as(u64, 2) else 0) |
                (if (self.bgr_order) @as(u64, 4) else 0) |
                (if (self.damp_chroma) @as(u64, 8) else 0),
            .indirect = self.clip_buf.gpu,
            .screen = .{ screen_w, screen_h },
            .scene_bda = self.bag_buf[slot].gpu,
            .perm_bda = self.perm_a[slot].gpu,
        };
        // One indirect command drawing the shared 6-index quad ×
        // instance_count (one sub-quad per instance; base vertex 0 — the
        // VS builds every corner from gl_VertexIndex + gl_InstanceIndex).
        // Same pixels as the old CPU-expanded draw (count buffer = 1
        // command), through the indirect path the GPU-driven pipeline
        // builds on.
        const indirect: [*]noapi.DrawIndexedIndirectCommand = @ptrCast(@alignCast(self.indirect_buf.cpu));
        const count: [*]u32 = @ptrCast(@alignCast(self.count_buf.cpu));
        indirect[0] = .{
            .index_count = quad_indices.len,
            .instance_count = instance_count,
            .first_index = 0,
            .vertex_offset = 0,
            .first_instance = 0,
        };
        count[0] = 1;
        cmd.drawIndexedIndirectMulti(
            push,
            self.idx_buf,
            self.indirect_buf,
            @sizeOf(noapi.DrawIndexedIndirectCommand),
            self.count_buf,
            0,
            1,
        );
    }
};
