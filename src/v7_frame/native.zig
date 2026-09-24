//! Reusable native frame support: one presented frame through the public
//! scene lowering, glyph rasterizer and Oklab→sRGB blit.
//!
//! `offscreen.zig` is the surface-free half of this path. It makes no window
//! and no swapchain, and it reads its own target back. This file is the other
//! half: it owns everything a PRESENTED frame needs on the device — the text
//! engine and the one `TextService` behind it, the scene renderer, the
//! bindless GUI texture heap, the blit shader pair, and the Oklab target pass
//! one writes — and it presents a `noapi.Surface` the caller made.
//!
//! It is deliberately SDL-free and window-free. The caller creates the
//! `noapi.Gpu` (from whatever Vulkan loader it has) and the `noapi.Surface`
//! (from whatever platform surface it has, through that platform's own public
//! surface-creation callback), and hands both to `beginFrame`. No backend
//! handle is extracted here and no raw graphics call is made: the two passes
//! are the public `scene.recordFrameScene` and `scene.recordBlit`.
//!
//! Shaping and glyph rasterization share `textService()` and `textEngine()`.
//! A downstream text consumer must use this service for its layout and this
//! engine for its painted glyphs, caret and candidate rectangle.
//!
//! ORDERING: between `buildScene` and `recordScene`, append non-tree glyphs,
//! selection boxes and carets to `sceneScratch().rects`.
//! These rects share the tree's lowering and the `(z, order)` sort key.
//! The caller's `z` places them above or below the tree's paint.
//!
//! TEARDOWN, which the caller also owns: `App.detachGpu` (or `App.deinit`)
//! first, then `deinit` here, then the `noapi.Surface`, then the `noapi.Gpu`.
//! Every resource in this struct calls into the device, so the device has to
//! outlive it and a live recording must never span `deinit`.
const std = @import("std");
const noapi = @import("noapi");
const nogui = @import("nogui");
const cpu = @import("nogui_text");
const renderer = @import("v7_render");
const heap = @import("heap.zig");
const scene = @import("scene.zig");
const text_gpu = @import("text_gpu.zig");

const BindlessHeap = heap.BindlessHeap;
const Renderer = renderer.Renderer;
const SceneScratch = scene.SceneScratch;
const FramePaint = scene.FramePaint;
const TextEngine = text_gpu.TextEngine;
const WindowSize = nogui.geometry.WindowSize;

// Re-exported so a consumer of this adapter can name what it paints with
// without taking a second module import for the types alone.
pub const TextService = cpu.TextService;
pub const TextLayout = cpu.TextLayout;
pub const LayoutLine = cpu.LayoutLine;
pub const FontSource = cpu.FontSource;
pub const FontHandle = nogui.text.FontHandle;
pub const LayoutRequest = nogui.text.LayoutRequest;
pub const SceneRect = renderer.SceneRect;
pub const SceneOptions = scene.SceneOptions;
pub const PixelScale = nogui.geometry.PixelScale;
pub const render_target_format = scene.render_target_format;
pub const oklab_clear = scene.oklab_clear;
pub const srgbToOklab = text_gpu.srgbToOklab;
pub const no_clip = scene.no_clip;

/// Everything the renderer needs to draw one presented frame.
pub const NativeFrame = struct {
    const Self = NativeFrame;

    /// SPIR-V words. The caller owns the bytes; `init` copies them into
    /// shader objects, so they need not outlive this call. These are the same
    /// five modules the demo pipeline uses: the quad pair and the sort
    /// compute for `v7_render.Renderer`, plus the fullscreen vertex stage and
    /// the Oklab→sRGB fragment stage for `scene.recordBlit`.
    pub const Shaders = struct {
        quad_vert: []const u32,
        quad_frag: []const u32,
        sort_comp: []const u32,
        fullscreen_vert: []const u32,
        blit_oklab: []const u32,
    };

    pub const Options = struct {
        allocator: std.mem.Allocator,
        /// The device. OWNED BY THE CALLER: this module never creates or
        /// destroys it, and it must outlive `deinit`.
        gpu: *noapi.Gpu,
        /// Registered with the engine's one `TextService` in order. A layout
        /// made from `service()` and painted with `text()` names one of these
        /// by handle, so shaping and rasterizing cannot drift apart.
        fonts: []const cpu.FontSource,
        shaders: Shaders,
        /// Names the pipeline's shader objects in a driver capture.
        name: [:0]const u8 = "nogui-native-frame",
    };

    /// What the caller knows about the window this frame presents to. The
    /// device extent is a REQUEST: the driver clamps the swapchain image to
    /// the surface capabilities, so both passes size themselves to the image
    /// `beginFrame` acquired and never to `viewport.device`.
    pub const Viewport = struct {
        /// The size the App lays out in, in window-logical units.
        logical: WindowSize,
        /// The window's current pixel extent.
        device: noapi.Extent2D,
        /// Observed device pixels per logical unit. A change re-rasterizes the
        /// glyph atlas instead of reusing the previous scale's rasters.
        scale: PixelScale = .{ .x = 1, .y = 1 },
    };

    /// Caller-owned storage for one recording. Declare it in place, do not
    /// move it, and keep it alive until `present` or `cancelFrame` ends the
    /// recording: the cancellation path holds `&cmd` and a context pointer.
    pub const Frame = struct {
        cmd: noapi.CommandBuffer,
        gpu_frame: nogui.GpuFrame,
        /// The acquired swapchain image: the render area of BOTH passes.
        image: noapi.Extent2D = .{ .width = 0, .height = 0 },
        /// The schedule rebuilt the swapchain on this acquire.
        swapchain_recreated: bool = false,
    };

    /// Presentation accounting. Every number is measured from what the
    /// surface and this module actually did, so a run that failed can be
    /// compared against one that did not.
    pub const Stats = struct {
        frames_committed: u32 = 0,
        frames_presented: u32 = 0,
        /// Acquires refused because the swapchain was out of date.
        resizes_requested: u32 = 0,
        swapchains_recreated: u32 = 0,
        /// Frames whose image was not the window pixel size this frame had
        /// already asked for. `beginFrame` notifies before it acquires, so
        /// what is left here is the driver clamping the image to the surface
        /// capabilities. What must never happen is a draw outside the image,
        /// and both passes size themselves to the image.
        extent_mismatches: u32 = 0,
        present_out_of_date: u32 = 0,
        /// Glyph re-rasterizations caused by an observed scale change.
        scale_changes: u32 = 0,
        last_slop_ns: u64 = 0,
    };

    gpa: std.mem.Allocator,
    gpu: *noapi.Gpu,
    /// The text engine that rasterizes glyphs AND owns the one text service.
    text: TextEngine,
    renderer: Renderer,
    textures: BindlessHeap,
    registry: nogui.TextureRegistry,
    /// Hand to `nogui.App.attachGpu` for the whole graphical lifetime.
    endpoint: nogui.GpuEndpoint,
    blit_vert: noapi.Shader,
    blit_frag: noapi.Shader,
    blit_heap: noapi.DescriptorHeap,
    /// The Oklab target pass one writes and the blit samples. Recreated
    /// whenever the acquired image changes size.
    target: noapi.TextureHandle = .{},
    target_extent: noapi.Extent2D = .{ .width = 0, .height = 0 },
    /// Host-visible copy target, allocated on the first `readTarget`.
    readback: ?noapi.GpuPtr = null,
    /// The scale the glyph rasters were produced at.
    scale: ?PixelScale = null,
    /// The surface whose frame is recording. The cancellation callback is
    /// reached with `context = self`, so it needs this.
    active: ?*noapi.Surface = null,
    viewport: ?Viewport = null,
    recording: bool = false,
    stats: Stats = .{},
    /// Retained per-frame lowering lists. They hold a pointer into
    /// `renderer`, so this value must be created in place and must not be
    /// copied afterwards.
    scratch: SceneScratch,
    /// `self` must be storage the caller keeps in place for the adapter's
    /// whole life (see the header). The device and every surface made from
    /// it must outlive `deinit`.
    pub fn init(self: *Self, options: Options) !void {
        // SAFETY: every field left `undefined` below is written by a later
        // statement of this function before anything reads it, and the
        // errdefers unwind only the fields already assigned. A failure
        // returns with the storage half-built and no deinit owed: the caller
        // may not touch `self` until init has returned successfully.
        self.* = .{
            .gpa = options.allocator,
            .gpu = options.gpu,
            .text = try TextEngine.init(options.allocator, options.gpu, options.fonts),
            .renderer = undefined,
            .textures = undefined,
            .registry = undefined,
            .endpoint = .{ .gpu = options.gpu },
            .blit_vert = undefined,
            .blit_frag = undefined,
            .blit_heap = undefined,
            .scratch = undefined,
        };
        errdefer self.text.deinit();
        self.renderer = try Renderer.init(
            options.gpu,
            options.shaders.quad_vert,
            options.shaders.quad_frag,
            options.shaders.sort_comp,
        );
        errdefer self.renderer.deinit();
        self.blit_vert = try options.gpu.shaderCreate(
            options.shaders.fullscreen_vert,
            .vertex,
            "main",
            "nogui_native_fullscreen",
        );
        errdefer options.gpu.shaderDestroy(self.blit_vert);
        self.blit_frag = try options.gpu.shaderCreate(
            options.shaders.blit_oklab,
            .fragment,
            "main",
            options.name,
        );
        errdefer options.gpu.shaderDestroy(self.blit_frag);
        self.blit_heap = try options.gpu.descHeapCreate(8, 0, 1);
        errdefer options.gpu.descHeapDestroy(self.blit_heap);
        options.gpu.descHeapSetSamplers(self.blit_heap, 0, &.{options.gpu.samplerDescriptor(.{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .mip_filter = .nearest,
        })});
        self.textures = try BindlessHeap.init(options.allocator, options.gpu);
        errdefer self.textures.deinit(options.allocator);
        // Glyph materials live in the bottom of the buffer; the tree's own
        // frame materials descend from the top. Reserving the split here is
        // what keeps a later frame's decoration from displacing a glyph.
        try self.text.setGlyphSlotLimit(scene.glyph_material_ceiling);
        self.renderer.configure(.{
            .material_bda = self.text.materialBda(),
            .damp_chroma = true,
        });
        self.registry = self.textures.runtimeRegistry();
        self.endpoint.textures = &self.registry;
        self.scratch = SceneScratch.init(options.allocator, &self.renderer);
    }

    /// No recording may be open. The App must already have detached.
    /// Complete submitted work before destroying its shaders and descriptors.
    /// A failed GPU drain is fatal: retirement must not free in-use resources.
    pub fn deinit(self: *Self) void {
        std.debug.assert(!self.recording);
        self.gpu.waitIdle() catch |err|
            std.debug.panic("NativeFrame GPU retirement failed: {s}", .{@errorName(err)});
        if (self.readback) |buffer| self.gpu.gpuFree(buffer);
        if (self.target.texture.id != 0) self.gpu.textureDestroy(self.target);
        self.scratch.deinit();
        self.textures.deinit(self.gpa);
        self.gpu.descHeapDestroy(self.blit_heap);
        self.gpu.shaderDestroy(self.blit_frag);
        self.gpu.shaderDestroy(self.blit_vert);
        self.renderer.deinit();
        self.text.deinit();
        self.* = undefined;
    }

    /// The device this adapter presents through. The caller still owns it.
    pub fn device(self: *Self) *noapi.Gpu {
        return self.gpu;
    }

    /// The rasterizer AND its text service. A layout made from `textService`
    /// belongs to this engine.
    pub fn textEngine(self: *Self) *TextEngine {
        return &self.text;
    }

    /// The core measure hook for this frame's text service. The App keeps
    /// this value, so it stays valid exactly as long as the frame does.
    pub fn measurer(self: *Self) nogui.layout.MeasureSource {
        return self.text.measurer();
    }

    /// The ONE service. Shape here, paint with `textEngine`.
    pub fn textService(self: *Self) *TextService {
        return &self.text.service;
    }

    /// The persistent endpoint for `nogui.App.attachGpu`.
    pub fn gpuEndpoint(self: *Self) *nogui.GpuEndpoint {
        return &self.endpoint;
    }

    /// The bindless GUI texture heap, for a consumer that registers its own
    /// textures instead of going through the endpoint.
    pub fn textureHeap(self: *Self) *BindlessHeap {
        return &self.textures;
    }

    /// The scene renderer, for a caller with its own lowering.
    pub fn sceneRenderer(self: *Self) *Renderer {
        return &self.renderer;
    }

    /// The retained per-frame scene lists. Append this frame's own rects
    /// here, after `beginFrame` and before `recordScene`.
    pub fn sceneScratch(self: *Self) *SceneScratch {
        return &self.scratch;
    }

    /// The Oklab target the most recent recorded frame wrote.
    pub fn targetTexture(self: *const Self) noapi.TextureHandle {
        return self.target;
    }

    /// The target's size, or 0x0 before the first frame.
    pub fn targetExtent(self: *const Self) noapi.Extent2D {
        return self.target_extent;
    }

    /// Acquire this surface's next image, retarget the Oklab pass to it, tell
    /// the text engine the observed scale, and open the recording.
    ///
    /// The device extent is NOTIFIED BEFORE the acquire, not after it. A
    /// `notifyResize` that follows an acquire asks for a swapchain one frame
    /// too late: this frame draws into an image sized for the previous
    /// window extent, which is exactly the stale-extent presentation the
    /// caller is trying to avoid. Asking first lets `beginFrame` rebuild the
    /// chain and return an image that already matches, so the first frame
    /// after a resize or a display-scale change is drawn at the new size.
    ///
    /// Returns false when the swapchain was out of date: nothing was acquired
    /// and the caller should come back next frame. An empty acquired image is
    /// `error.SwapchainImageEmpty`, because there is nowhere to draw and no
    /// honest way to report a frame. The frame's scene lists are dropped
    /// here, so call this before building anything.
    pub fn beginFrame(
        self: *Self,
        surface: *noapi.Surface,
        viewport: Viewport,
        frame: *Frame,
    ) !bool {
        if (self.recording) return error.FrameAlreadyRecording;
        if (viewport.logical.width <= 0 or viewport.logical.height <= 0) return error.InvalidExtent;
        if (viewport.device.width > 0 and viewport.device.height > 0) {
            surface.notifyResize(viewport.device);
        }
        const schedule = surface.beginFrame() catch |err| {
            if (err == error.OutOfDateKHR) {
                self.stats.resizes_requested += 1;
                return false;
            }
            return err;
        };
        errdefer surface.abortFrame() catch
            @panic("Native frame acquisition rollback failed");
        if (schedule.swapchain_recreated) self.stats.swapchains_recreated += 1;
        const image = surface.surfaceSize();
        // Asked for the window's pixels and still got something else, so the
        // driver clamped the image to the surface capabilities. That is
        // legitimate and the draw is sized to the image either way; only a
        // draw outside the image would be a fault.
        if (image.width != viewport.device.width or image.height != viewport.device.height) {
            self.stats.extent_mismatches += 1;
        }
        if (image.width == 0 or image.height == 0) return error.SwapchainImageEmpty;
        self.syncScale(viewport.scale);
        try self.ensureTarget(image);
        frame.cmd = surface.commandsBegin();
        frame.gpu_frame = .{
            .endpoint = &self.endpoint,
            .command_buffer = &frame.cmd,
            .extent = image,
            .frame_index = self.stats.frames_committed,
            .recording = .{ .active = .{ .context = self, .abort = abortRecording } },
        };
        frame.image = image;
        frame.swapchain_recreated = schedule.swapchain_recreated;
        self.active = surface;
        self.viewport = viewport;
        self.recording = true;
        self.scratch.beginFrame();
        return true;
    }

    /// Lower the committed tree into this frame's paint list. The returned
    /// value owns the converted paint; release it with `FramePaint.deinit`
    /// before the recording ends.
    pub fn buildScene(
        self: *Self,
        options: SceneOptions,
        out: *const nogui.FrameOutput,
    ) !FramePaint {
        return scene.buildFrameScene(&self.scratch, &self.text, options, out, false);
    }

    /// Pass one: the tree's paint plus every scene rect the caller appended,
    /// lowered and rasterized into this frame's Oklab target. Pass two:
    /// `scene.recordBlit` converts that target into the acquired image, so
    /// the window shows final sRGB rather than Oklab. Both passes are
    /// recorded into the frame's ONE command buffer, which the surface
    /// submits; nothing is drawn straight into the image first.
    pub fn recordScene(
        self: *Self,
        surface: *noapi.Surface,
        frame: *Frame,
        out: *const nogui.FrameOutput,
        frame_paint: *const FramePaint,
    ) !void {
        if (!self.recording) return error.FrameNotRecording;
        if (frame.image.width == 0 or frame.image.height == 0) return error.SwapchainImageEmpty;
        const viewport = self.viewport orelse return error.FrameNotRecording;
        _ = try scene.recordFrameScene(&.{
            .arena = out.tree.allocator,
            .renderer = &self.renderer,
            .text = &self.text,
            .logical = viewport.logical,
            .device = frame.image,
            .texture_heap = self.textures.handle,
            .clips = out.tree.clip_rects[0..out.tree.clip_count],
        }, &frame.cmd, &self.scratch, self.scratch.rects.items, frame_paint, self.target);
        // Pass one's colour output is sampled by pass two's fragment shader,
        // and both live in this one command buffer.
        frame.cmd.barrier(.{ .color_output = true }, .{ .fragment = true }, .{});
        scene.recordBlit(
            &frame.cmd,
            surface.currentImage(),
            frame.image,
            self.blit_vert,
            self.blit_frag,
            self.blit_heap,
        );
    }

    /// Submit the recorded passes and present. Ends the recording.
    pub fn present(self: *Self, surface: *noapi.Surface, frame: *Frame) !void {
        if (!self.recording) return error.FrameNotRecording;
        defer self.closeRecording();
        const result = surface.endFrame(.{}) catch |err| {
            // Submission can fail after the backend ended the command buffer.
            // Poison it against cancellation or retry; deinit drains the GPU
            // before retiring any resources it may still reference.
            frame.gpu_frame.recording = .failed;
            return err;
        };
        frame.gpu_frame.finishRecording();
        self.stats.frames_committed += 1;
        if (!result.present_out_of_date) self.stats.frames_presented += 1;
        if (result.present_out_of_date) self.stats.present_out_of_date += 1;
        self.stats.last_slop_ns = surface.slopNs();
    }

    /// Abandon the recording without submitting it. The surface discards the
    /// acquired image; the caller must not release anything the unfinished
    /// recording referenced, and must not reuse this surface afterwards
    /// without a fresh `beginFrame`.
    ///
    /// `error.FrameNotRecording` is this layer's refusal for "no frame began".
    /// The surface cannot report that: it treats an idle frame as an
    /// already-discarded frame and reports success, because hosts cancel from
    /// an `errdefer`. The remaining errors come from
    /// `GpuFrame.cancelRecording`: no cancellation is attached, an earlier
    /// cancellation or a failed submission already poisoned the recording, or
    /// it was already submitted.
    pub fn cancelFrame(self: *Self, frame: *Frame) !void {
        if (!self.recording) return error.FrameNotRecording;
        try frame.gpu_frame.cancelRecording();
        self.closeRecording();
    }

    /// The pixels of the last recorded frame, copied out of the Oklab target
    /// and waited for. This is real readback of what the presented passes
    /// drew, not a re-render and not a model read: the slice holds one rgba32
    /// float quad per pixel in Oklab. It dies at the next `readTarget`, at
    /// the next target resize, and at `deinit`.
    pub fn readTarget(self: *Self) ![]const f32 {
        if (self.target.texture.id == 0) return error.NoRenderedTarget;
        try self.ensureReadback();
        const buffer = self.readback.?;
        var cmd = try self.gpu.commandsBegin();
        const texture: noapi.Texture = .{
            .gpu = self.gpu,
            .handle = self.target,
            .dimensions = .{ self.target_extent.width, self.target_extent.height, 1 },
            .format = render_target_format,
        };
        cmd.barrier(.{ .color_output = true }, .{ .transfer = true }, .{});
        cmd.copyFromTexture(texture, buffer, .{
            .size = .{ self.target_extent.width, self.target_extent.height, 1 },
        });
        try self.gpu.queueSubmit(&.{cmd});
        try self.gpu.waitIdle();
        const count = try pixelCount(self.target_extent);
        const pixels: [*]const f32 = @ptrCast(@alignCast(buffer.cpu));
        return pixels[0..count];
    }

    /// Tell the text engine about an observed scale, re-rasterizing glyphs
    /// when it changed. A caller that never scales still pays one compare.
    pub fn setPixelScale(self: *Self, scale: PixelScale) void {
        self.syncScale(scale);
    }

    fn syncScale(self: *Self, scale: PixelScale) void {
        if (self.scale) |previous| {
            if (previous.x == scale.x and previous.y == scale.y) return;
        }
        self.text.setPixelScale(scale);
        self.scale = scale;
        self.stats.scale_changes += 1;
    }

    fn closeRecording(self: *Self) void {
        self.recording = false;
        self.active = null;
        self.viewport = null;
    }

    /// The Oklab target, and the blit heap's view descriptor pointing at it.
    /// Without the descriptor a resized or re-scaled window would blit the
    /// previous frame's target into a larger image.
    fn ensureTarget(self: *Self, extent: noapi.Extent2D) !void {
        if (self.target.texture.id != 0 and
            self.target_extent.width == extent.width and
            self.target_extent.height == extent.height) return;
        const created = try self.gpu.textureCreate(.{
            .dimensions = .{ extent.width, extent.height, 1 },
            .format = render_target_format,
            .usage = .{ .color_attachment = true, .sampled = true, .transfer_src = true },
        });
        errdefer self.gpu.textureDestroy(created);
        if (self.target.texture.id != 0) {
            // Keep the previous target and descriptors intact on allocation
            // or retirement failure. Retire only before the successful swap.
            try self.gpu.waitIdle();
            self.gpu.textureDestroy(self.target);
            if (self.readback) |buffer| {
                self.gpu.gpuFree(buffer);
                self.readback = null;
            }
        }
        self.target = created;
        self.target_extent = extent;
        const view = self.gpu.textureViewDescriptor(self.target, .{ .format = .default });
        self.gpu.descHeapSetTextures(self.blit_heap, 0, &.{view});
    }

    fn ensureReadback(self: *Self) !void {
        if (self.readback != null) return;
        const bytes = try std.math.mul(u64, try pixelCount(self.target_extent), @sizeOf(f32));
        self.readback = try self.gpu.gpuMalloc(bytes, 64, .readback);
    }
};

/// Reached from `nogui.GpuFrame.cancelRecording`. The surface releases the
/// acquired image; the recorded commands are never submitted. Cancellation is
/// once-only, so this guard is a backstop rather than a second state machine:
/// `error.FrameNotRecording` names the one thing the surface will not report
/// for itself.
fn abortRecording(context: *anyopaque, _: *noapi.CommandBuffer) anyerror!void {
    const self: *NativeFrame = @ptrCast(@alignCast(context));
    const surface = self.active orelse return error.FrameNotRecording;
    try surface.abortFrame();
    self.closeRecording();
}

fn pixelCount(extent: noapi.Extent2D) !usize {
    const pixels = try std.math.mul(usize, extent.width, extent.height);
    return std.math.mul(usize, pixels, 4);
}

test {
    std.testing.refAllDecls(@This());
}
