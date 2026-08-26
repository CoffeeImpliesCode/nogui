//! Public scene facade for the v7 9-slice renderer.
//!
//! The facade owns the GPU batch and keeps its storage, sort ring, and draw
//! state private. Callers borrow scene slices for prepare(), then draw() in
//! the render pass.

const noapi = @import("noapi");
const batch_module = @import("render_9slice.zig");
const Batch9Slice = batch_module.Batch9Slice;

/// GPU-facing clip-rect type used by the scene submission protocol.
pub const ClipRect = batch_module.ClipRect;
/// One borrowed 9-slice rectangle in the scene submission protocol.
pub const SceneRect = batch_module.SceneRect;
pub const max_clip_rects = batch_module.max_clip_rects;

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

    /// Creates the renderer and its shader objects.
    pub fn init(
        gpu: *noapi.Gpu,
        vert_spv: []const u32,
        frag_spv: []const u32,
        sort_spv: []const u32,
    ) !Renderer {
        return .{
            .batch = try Batch9Slice.init(gpu, vert_spv, frag_spv, sort_spv),
        };
    }

    /// Releases the owned shaders and GPU buffers.
    pub fn deinit(self: *Renderer) void {
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

    /// Records the one indirect GUI draw inside dynamic rendering.
    pub fn draw(self: *Renderer, cmd: anytype, screen_w: f32, screen_h: f32) void {
        self.batch.draw(cmd, screen_w, screen_h);
    }

    /// Returns the current sorted permutation for the bounded debug readback.
    pub fn permutationBuffer(self: *const Renderer) noapi.GpuPtr {
        return self.batch.perm_a[self.batch.cur_slot];
    }
};
