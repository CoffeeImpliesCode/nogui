//! v7 demo window backend — SDL3 + noapi Vulkan rendering for the v7 tree,
//! through v4's text/glyph pipeline: the Renderer scene facade + FreeType
//! glyph materials, rendered into an offscreen Oklab float target, then
//! blitted to the swapchain with the Oklab→sRGB conversion shader.
//!
//! Demo-side code (imports std, sdl3, noapi AND the pure v7 module via the
//! `v7` symlink in this directory — same convention as ui.zig, so this file
//! stays standalone-compilable). The v7 module itself never sees sdl3/noapi.
//!
//! Flow per frame: the window begins the Surface frame and obtains its
//! command buffer; app.frameWithGpuAtTime builds + lays out the tree and
//! dispatches component GPU hooks; collectDrawCmds flattens the tree into
//! paint-ordered DrawCmds; buildSliceRects turns each cmd into a SceneRect —
//! solid cmds use material slot 0, radius-bearing fills and border rings use
//! per-cmd rounded-rect materials (type 2) written into the engine's material
//! buffer; label-bearing nodes additionally emit one glyph SceneRect per
//! character via TextEngine (FreeType); Renderer prepares the stable GPU sort
//! and records one indexed draw into the offscreen Oklab target; a barrier
//! transitions the target to shader-read; the blit pass samples it and writes
//! sRGB to the swapchain. Mouse clicks hit-test the same frame's tree and
//! dispatch back into the app (mutations apply on the next frame).
//!
//! `runShot` renders a single frame into the offscreen target, copies it back
//! to a readback buffer and writes a P6 PPM — the text-renders proof.

const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const vk = noapi.vk;
const Io = std.Io;

const v7_options = @import("v7_options");
const nogui = @import("nogui");
const App = nogui.App;
const Event = nogui.Event;
const tracy = @import("tracy");
const perf = @import("perf.zig");
const calculator_ui = @import("calculator.zig");
const FramePacer = @import("FramePacer.zig").FramePacer;
const Id = nogui.Id;
const DrawCmd = nogui.drawcmd.DrawCmd;
const WidgetTree = nogui.WidgetTree;
const Rect = nogui.Rect;
const ClipRect = nogui.widget.ClipRect;
const visualBorderRect = nogui.visualBorderRect;
const sliderThumbRect = nogui.widget.sliderThumbRect;
const sliderVisualLabel = nogui.widget.sliderVisualLabel;
const contentRect = nogui.widget.contentRect;
const visualContentRect = nogui.visualContentRect;
const IconId = nogui.widget.IconId;
const collectDrawCmdsInto = nogui.drawcmd.collectDrawCmdsInto;
const MouseButton = nogui.event.MouseButton;
const Key = nogui.event.Key;
const hitTest = nogui.hitTest; // runShot's forced --hover
const renderer = @import("v7_render");
const Renderer = renderer.Renderer;
const RenderScene = renderer.Scene;
const RenderOptions = renderer.Options;

/// The offscreen Oklab render target format (the GUI pass's workspace).
/// RGBA16F halves the blend ROP traffic vs RGBA32F: the Oklab values
/// (L in [0,1], a/b in [-0.4,0.4]) need only 2^-11 relative precision —
/// 8-20x headroom over the 8-bit sRGB output step. The fragment shader
/// objects MUST be created with this format (the shader-object output
/// override) or the attachment mismatch renders black.
// The offscreen Oklab render target format. RGBA16F would halve the blend
// ROP traffic, but it is BLOCKED on this stack: the shader-object output
// override is unsupported (Vulkan 341 headers reject the flag/pNext) and
// the half4 SPIR-V output needs shaderFloat16/storageInputOutput16, which
// this GTX 1660 Ti driver does not expose (FeatureNotPresent). 32F stays.
const render_target_format: noapi.Texture.TextureFormat = .rgba32_float;
const SceneRect = renderer.SceneRect;
comptime {
    std.debug.assert(@sizeOf(ClipRect) == @sizeOf(renderer.ClipRect));
    std.debug.assert(@alignOf(ClipRect) == @alignOf(renderer.ClipRect));
    std.debug.assert(@offsetOf(ClipRect, "x") == @offsetOf(renderer.ClipRect, "x"));
    std.debug.assert(@offsetOf(ClipRect, "y") == @offsetOf(renderer.ClipRect, "y"));
    std.debug.assert(@offsetOf(ClipRect, "w") == @offsetOf(renderer.ClipRect, "w"));
    std.debug.assert(@offsetOf(ClipRect, "h") == @offsetOf(renderer.ClipRect, "h"));
}
const TextEngine = @import("text.zig").TextEngine;
const text_mod = @import("text.zig");
const svg_xml = @import("svg_xml.zig");
const SvgView = @import("svg_view.zig").SvgView;
const max_materials = @import("text.zig").max_materials;
const font_size_px = @import("text.zig").font_size_px;
const srgbToOklab = @import("text.zig").srgbToOklab;
const ui = @import("ui.zig"); // for the demo texture index (texture_idx)
const AudioPlayer = @import("audio_player.zig").AudioPlayer;
const ffmpeg_decoder = @import("ffmpeg_decoder.zig");
const LocalTrack = @import("spotify_data.zig").LocalTrack;
const spotify_ui = @import("spotify.zig");

/// SDL3 extension list copy. Gpu.init's loader callback can't be a closure,
/// so the dupe lives here for the duration of run()/runShot().
var exts_copy_global: []const [*:0]const u8 = &.{};

const GpuRemountSmokePhase = enum {
    initial_visible,
    hidden,
    remounted,
    complete,
};

const GpuRemountSmokeObservation = struct {
    slot: ?u32 = null,
    init_count: u32 = 0,
    deinit_count: u32 = 0,
    last_unregistered_slot: ?u32 = null,
    ready: bool = false,
};

fn setGpuRemountSmokeVisibility(comptime T: type, root: *T, visible: bool) void {
    if (comptime T == ui.TodoApp) root.setMandelbrotVisible(visible);
}

fn gpuRemountSmokeObservation(comptime T: type, root: *T) GpuRemountSmokeObservation {
    if (comptime T == ui.TodoApp) {
        return .{
            .slot = root.mandelbrot.bindlessSlot(),
            .init_count = root.mandelbrot.gpuInitCount(),
            .deinit_count = root.mandelbrot.gpuDeinitCount(),
            .last_unregistered_slot = root.mandelbrot.lastUnregisteredSlot(),
            .ready = root.mandelbrot.isGpuReady(),
        };
    }
    return .{};
}

fn getExts() []const [*:0]const u8 {
    return exts_copy_global;
}

/// Map an SDL keycode to the core Key set (navigation/activation only).
fn mapSdlKey(kc: sdl3.keycode.Keycode) ?Key {
    return switch (kc) {
        .tab => .tab,
        .return_key, .return_key2 => .enter,
        .space => .space,
        .escape => .escape,
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
        .home => .home,
        .end => .end,
        else => null,
    };
}

fn dispatchRootEvent(comptime T: type, root: *T, event: Event) void {
    if (comptime @hasDecl(T, "onEvent")) root.onEvent(&event);
}

fn dispatchRootFrame(comptime T: type, root: *T, time_ms: u64) void {
    if (comptime @hasDecl(T, "onFrame")) root.onFrame(time_ms);
}

fn configureGpuComponents(comptime T: type, root: *T, heap: noapi.DescriptorHeap) void {
    if (comptime @hasDecl(T, "setGpuDescriptorHeap")) root.setGpuDescriptorHeap(heap);
}

fn dispatchRootPrecisionKey(comptime T: type, root: *T) bool {
    if (comptime @hasDecl(T, "onPrecisionKey")) {
        root.onPrecisionKey();
        return true;
    }
    return false;
}

/// The SVG showcase's reserved box (the node the ui stores in
/// ui.svg_box_id): the tiger's scene rects are injected at its content
/// rect. The CONTENT rect (not the border box) — the drawing area the
/// box's padding/border define — plus the card's paint layer (the
/// injected SVG rects must sort ON TOP of the card's fill, not at the
/// default z=0 behind every box).
const SvgCard = struct { rect: Rect, layer: u32 };

fn svgCardRect(tree: *const WidgetTree) error{InvalidStyle}!SvgCard {
    if (ui.svg_box_id) |id_raw| {
        const id: Id = @enumFromInt(id_raw);
        for (tree.nodes.items) |n| {
            if (n.id == id) {
                return .{ .rect = try contentRect(tree, id), .layer = n.paint.layer };
            }
        }
    }
    return .{ .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .layer = 0 };
}

/// Parse the embedded tiger + convert it into the renderer's SvgView
/// (per-path conics + glyph materials + scene rects). The materials are
/// written into the shared text-engine buffer at the SVG region — Renderer
/// draws everything with that one material BDA.
fn initSvgView(gpa: std.mem.Allocator, gpu: *noapi.Gpu, text_engine: *TextEngine) !SvgView {
    const tiger_xml = @embedFile("tiger.svg");
    var doc = try svg_xml.parseSvg(gpa, tiger_xml);
    defer doc.deinit();
    const v = try SvgView.init(gpa, gpu, &doc, text_engine.materials, text_engine.materialBda(), svg_material_base);
    return v;
}

/// The stroke test scene: curved thin strokes at increasing widths. The
/// stroke algo + oversize sliders drive the shader; the scale slider
/// zooms the whole scene.
fn initStrokeView(gpa: std.mem.Allocator, gpu: *noapi.Gpu, text_engine: *TextEngine) !SvgView {
    const strokes_xml =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 500 500">
        \\  <path d="M 50 60 C 150 220, 350 -80, 450 60" stroke="#fff" stroke-width="0.1" fill="none"/>
        \\  <path d="M 50 120 C 150 280, 350 -20, 450 120" stroke="#fff" stroke-width="0.25" fill="none"/>
        \\  <path d="M 50 180 C 150 340, 350 40, 450 180" stroke="#fff" stroke-width="0.5" fill="none"/>
        \\  <path d="M 50 240 C 150 400, 350 100, 450 240" stroke="#fff" stroke-width="1" fill="none"/>
        \\  <path d="M 50 300 C 150 460, 350 160, 450 300" stroke="#fff" stroke-width="2" fill="none"/>
        \\  <path d="M 50 360 C 150 520, 350 220, 450 360" stroke="#fff" stroke-width="4" fill="none"/>
        \\</svg>
    ;
    var doc = try svg_xml.parseSvg(gpa, strokes_xml);
    defer doc.deinit();
    const v = try SvgView.init(gpa, gpu, &doc, text_engine.materials, text_engine.materialBda(), svg_material_base);
    return v;
}

const icon_count = @typeInfo(IconId).@"enum".fields.len;
const icon_material_base: u32 = svg_material_base + 384;

/// Compact 16px SVG paths, indexed in exact `IconId` declaration order.
/// Every path stays within the view box so cached bounds center consistently.
const icon_svg = [_][]const u8{
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">
    \\  <path
    \\    d="M8 14.25 L2.2 8.55 C0.45 6.82 1.04 3.5 3.75 3.5
    \\       C5.48 3.5 6.89 4.45 8 5.74 C9.11 4.45 10.52 3.5 12.25 3.5 C14.96 3.5 15.55 6.82 13.8 8.55 Z"
    \\    fill="none" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"
    \\  />
    \\</svg>
    ,
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">
    \\  <path
    \\    d="M8 14.25 L2.2 8.55 C0.45 6.82 1.04 3.5 3.75 3.5
    \\       C5.48 3.5 6.89 4.45 8 5.74 C9.11 4.45 10.52 3.5 12.25 3.5 C14.96 3.5 15.55 6.82 13.8 8.55 Z"
    \\  />
    \\</svg>
    ,
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">
    \\  <path
    \\    d="M1 3 L5 3 L5 1 L9 5 L5 9 L5 7 L3 7 L3 9 L1 9 L1 5 L1 5 Z
    \\       M15 7 L11 7 L11 9 L7 5 L11 1 L11 3 L13 3 L13 1 L15 1 L15 5 L15 5 Z
    \\       M1 11 L5 11 L5 9 L9 13 L5 15 L5 15 L1 15 L1 11 Z
    \\       M15 11 L15 15 L11 15 L11 15 L7 13 L11 9 L11 11 Z"
    \\  />
    \\</svg>
    ,
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">
    \\  <path
    \\    d="M2 2 L4 2 L4 6 L13 1 L13 15 L4 10 L4 14 L2 14 Z"
    \\  />
    \\</svg>
    ,
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">
    \\  <path
    \\    d="M3 1 L14 8 L3 15 Z"
    \\  />
    \\</svg>
    ,
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">
    \\  <path
    \\    d="M3 2 L6 2 L6 14 L3 14 Z M10 2 L13 2 L13 14 L10 14 Z"
    \\  />
    \\</svg>
    ,
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">
    \\  <path
    \\    d="M3 1 L12 6 L12 2 L14 2 L14 14 L12 14 L12 10 L3 15 Z"
    \\  />
    \\</svg>
    ,
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">
    \\  <path
    \\    d="M3 2 L12 2 L12 1 L15 3.5 L12 6 L12 4 L5 4 L5 7 L3 7 Z
    \\       M13 9 L13 14 L4 14 L4 15 L1 12.5 L4 10 L4 12 L11 12 L11 9 Z"
    \\  />
    \\</svg>
    ,
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">
    \\  <path
    \\    d="M2 2 L14 2 L14 5 L2 5 Z M2 7 L14 7 L14 10 L2 10 Z M2 12 L10 12 L10 15 L2 15 Z"
    \\  />
    \\</svg>
    ,
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">
    \\  <path
    \\    d="M2 3 L14 3 L14 12 L2 12 Z M4 5 L12 5 L12 10 L4 10 Z M6 13 L10 13 L10 15 L6 15 Z"
    \\  />
    \\</svg>
    ,
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">
    \\  <path
    \\    d="M1 6 L4 6 L8 3 L8 13 L4 10 L1 10 Z M10 5 C13 7 13 9 10 11 L11 13 C16 10 16 6 11 3 Z"
    \\  />
    \\</svg>
    ,
};
comptime {
    std.debug.assert(icon_svg.len == icon_count);
}

const IconCache = struct {
    views: [icon_count]SvgView,

    fn init(gpa: std.mem.Allocator, gpu: *noapi.Gpu, text_engine: *TextEngine) !IconCache {
        comptime std.debug.assert(icon_material_base + icon_count * 2 <= max_materials);
        var views: [icon_count]SvgView = undefined;
        var initialized: usize = 0;
        errdefer for (views[0..initialized]) |*view| view.deinit(gpu);
        for (icon_svg, 0..) |xml, i| {
            var doc = try svg_xml.parseSvg(gpa, xml);
            defer doc.deinit();
            views[i] = try SvgView.init(
                gpa,
                gpu,
                &doc,
                text_engine.materials,
                text_engine.materialBda(),
                icon_material_base + @as(u32, @intCast(i * 2)),
            );
            views[i].setScale(1);
            initialized += 1;
        }
        return .{ .views = views };
    }

    fn deinit(self: *IconCache, gpu: *noapi.Gpu) void {
        for (&self.views) |*view| view.deinit(gpu);
        self.* = undefined;
    }

    fn get(self: *const IconCache, icon: IconId) *const SvgView {
        return &self.views[@intFromEnum(icon)];
    }
};

/// Convert window-logical mouse coordinates (SDL event space) to surface
/// pixels (the layout space): scale by the surface/window size ratio.
/// Identity when the window is not scaled; correct on HiDPI displays.
fn toSurfacePoint(sdl_win: sdl3.video.Window, gw: *noapi.Surface, p: [2]f32) ![2]f32 {
    const win_size = try sdl_win.getSize();
    const surface_size = gw.surfaceSize();
    const sw: f32 = @floatFromInt(@min(surface_size.width, 1 << 24));
    const sh: f32 = @floatFromInt(@min(surface_size.height, 1 << 24));
    const ww: f32 = @floatFromInt(@min(win_size[0], 1 << 24));
    const wh: f32 = @floatFromInt(@min(win_size[1], 1 << 24));
    return .{
        p[0] * sw / ww,
        p[1] * sh / wh,
    };
}

/// The modern dark canvas: the Oklab L≈0.20 neutral with a whisper of blue
/// (b < 0) — the deepest surface the cards sit on. Clears the offscreen
/// target.
const oklab_gray = [4]f32{ 0.20, 0.0, -0.008, 1.0 };

/// The SVG view's material slots own the TOP region of the shared
/// material buffer: [svg_material_base, MAX_MATERIALS). The tiger has
/// ≤240 fill paths + up to 78 stroked paths (a slot each); the per-frame
/// decorations descend from svg_material_base. The glyphs (from slot 1
/// upward) must stay below svg_material_base — the demo's ~620 glyphs
/// fit with headroom.
const svg_material_base: u32 = max_materials - 512;

/// A shader file read from disk: owns the byte buffer, exposes the SPIR-V
/// word slice (shaderCreate copies the module, so the bytes only need to
/// outlive shaderCreate).
const ShaderFile = struct {
    bytes: []u8,
    spv: []const u32,

    fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) !ShaderFile {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        errdefer gpa.free(bytes);
        const spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, bytes));
        return .{ .bytes = bytes, .spv = spv };
    }

    fn deinit(self: *ShaderFile, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// Create (or recreate on resize) the offscreen R32G32B32A32_SFLOAT render
/// target that the GUI renders into in Oklab space. The blit heap's texture
/// descriptor is (re)pointed at it every time it changes.
fn ensureRenderTarget(
    gpu: *noapi.Gpu,
    rt: *noapi.TextureHandle,
    rt_w: *u32,
    rt_h: *u32,
    w: u32,
    h: u32,
    blit_heap: noapi.DescriptorHeap,
) !void {
    if (rt.texture.id != 0 and w == rt_w.* and h == rt_h.*) return;
    if (rt.texture.id != 0) gpu.textureDestroy(rt.*);
    rt.* = try gpu.textureCreate(.{
        .dimensions = .{ w, h, 1 },
        .format = render_target_format,
        .usage = .{ .color_attachment = true, .sampled = true, .transfer_src = true },
    });
    rt_w.* = w;
    rt_h.* = h;
    const rt_desc = gpu.textureViewDescriptor(rt.*, .{ .format = .default });
    gpu.descHeapSetTextures(blit_heap, 0, &.{rt_desc});
}

/// The GUI texture heap + registry (spec §5 phase 1 — the bindless path):
/// a persistent descriptor heap created once (set 0 = the app-registered
/// textures, set 2 = one shared linear/clamp sampler at index 0) plus a
/// map from the app's texture handle to its stable heap index. The frame
/// binds the heap with ONE cmd.bindDescriptorSets before renderer.draw —
/// bindings are not draws, so the one-draw invariant holds. The fragment
/// shader samples textures[NonUniformResourceIndex(tex_idx)] (set 0
/// binding 0) with samplers[0] (set 2 binding 0); descHeapSetTextures
/// writes each registration's image-view descriptor at its index.
/// descHeapCreate's requested counts are capacity hints — the backend
/// forces the pool to max_textures/max_samplers either way.
const ExternalTextureSlots = struct {
    const Self = ExternalTextureSlots;

    /// Indices freed by external component textures are reusable by any
    /// subsequent registration, including ordinary map-owned textures.
    next_idx: u32 = 0,
    reusable_indices: std.ArrayListUnmanaged(u32) = .empty,
    live_indices: std.AutoHashMapUnmanaged(u32, void) = .empty,

    fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        self.reusable_indices.deinit(gpa);
        self.live_indices.deinit(gpa);
        self.* = undefined;
    }

    fn take(self: *Self) u32 {
        if (self.reusable_indices.pop()) |idx| return idx;
        const idx = self.next_idx;
        self.next_idx += 1;
        return idx;
    }

    fn restore(self: *Self, gpa: std.mem.Allocator, idx: u32) void {
        self.reusable_indices.append(gpa, idx) catch
            @panic("external texture slot free-list allocation failed");
    }

    fn register(self: *Self, gpa: std.mem.Allocator) !u32 {
        const idx = self.take();
        errdefer self.restore(gpa, idx);
        try self.live_indices.put(gpa, idx, {});
        return idx;
    }

    fn unregister(self: *Self, gpa: std.mem.Allocator, idx: u32) bool {
        if (self.live_indices.fetchRemove(idx) == null) return false;
        self.reusable_indices.append(gpa, idx) catch
            @panic("external texture slot free-list allocation failed");
        return true;
    }
};

const TextureRegistry = struct {
    const Self = TextureRegistry;

    gpu: *noapi.Gpu,
    gpa: std.mem.Allocator,
    heap: noapi.DescriptorHeap,
    /// Global descriptor slot allocation. External ownership is tracked
    /// separately by `external_slots`; map entries remain registry-owned.
    external_slots: ExternalTextureSlots = .{},
    /// The app's texture handle → heap index.
    map: std.AutoHashMapUnmanaged(noapi.TextureHandle, u32) = .empty,
    /// The storage-image table has one active slot for the Mandelbrot shader.
    storage_owner: ?u32 = null,

    fn init(gpa: std.mem.Allocator, gpu: *noapi.Gpu) !Self {
        const heap = try gpu.descHeapCreate(16, 0, 1);
        errdefer gpu.descHeapDestroy(heap);
        const sampler = gpu.samplerDescriptor(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mip_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        gpu.descHeapSetSamplers(heap, 0, &.{sampler});
        return .{ .gpu = gpu, .gpa = gpa, .heap = heap };
    }

    fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        // Ordinary window-owned textures remain registry-owned. Component
        // textures use registerExternalWithStorage() and free themselves
        // during deinitGpu; only their descriptor slots are cleared here.
        var it = self.map.keyIterator();
        while (it.next()) |h| self.gpu.textureDestroy(h.*);
        self.map.deinit(gpa);
        self.external_slots.deinit(gpa);
        self.gpu.descHeapDestroy(self.heap);
        self.* = undefined;
    }

    /// Register a texture: write its view descriptor into the heap at a
    /// stable index (returned) — descHeapSetTextures, once per texture.
    /// Idempotent: a handle already registered returns its index.
    fn register(self: *Self, gpa: std.mem.Allocator, tex: noapi.TextureHandle) !u32 {
        if (self.map.get(tex)) |idx| return idx;
        const idx = self.external_slots.take();
        errdefer self.external_slots.restore(gpa, idx);
        const desc = self.gpu.textureViewDescriptor(tex, .{ .format = .default });
        self.gpu.descHeapSetTextures(self.heap, idx, &.{desc});
        try self.map.put(gpa, tex, idx);
        return idx;
    }

    /// Register a component-owned storage texture without putting its handle
    /// in the registry's destruction map. Its sampled and storage descriptors
    /// are cleared by unregisterExternalWithStorage().
    fn registerExternalWithStorage(self: *Self, tex: noapi.TextureHandle) !u32 {
        const idx = try self.external_slots.register(self.gpa);
        const desc = self.gpu.textureViewDescriptor(tex, .{ .format = .default });
        self.gpu.descHeapSetTextures(self.heap, idx, &.{desc});
        const rw_desc = self.gpu.textureRwViewDescriptor(tex, .{ .format = .default });
        self.gpu.descHeapSetTexturesRw(self.heap, idx, &.{rw_desc});
        self.gpu.descHeapSetTexturesRw(self.heap, 0, &.{rw_desc});
        self.storage_owner = idx;
        return idx;
    }

    /// Unregister a component-owned texture. The live-index set makes this
    /// callback idempotent, so a repeated deinit cannot reuse a slot twice.
    fn unregisterExternalWithStorage(self: *Self, idx: u32) void {
        if (!self.external_slots.unregister(self.gpa, idx)) return;
        const null_desc: u64 = 0;
        self.gpu.descHeapSetTextures(self.heap, idx, &.{null_desc});
        self.gpu.descHeapSetTexturesRw(self.heap, idx, &.{null_desc});
        if (self.storage_owner) |owner| {
            if (owner == idx) {
                self.gpu.descHeapSetTexturesRw(self.heap, 0, &.{null_desc});
                self.storage_owner = null;
            }
        }
    }
};

fn registerRuntimeTexture(ptr: *anyopaque, texture: noapi.TextureHandle) anyerror!u32 {
    const registry: *TextureRegistry = @ptrCast(@alignCast(ptr));
    return registry.registerExternalWithStorage(texture);
}

fn unregisterRuntimeTexture(ptr: *anyopaque, index: u32) void {
    const registry: *TextureRegistry = @ptrCast(@alignCast(ptr));
    registry.unregisterExternalWithStorage(index);
}

test "TextureRegistry: external slots reuse released indices" {
    var slots: ExternalTextureSlots = .{};
    defer slots.deinit(std.testing.allocator);

    const first = try slots.register(std.testing.allocator);
    const second = try slots.register(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), first);
    try std.testing.expectEqual(@as(u32, 1), second);
    try std.testing.expect(slots.unregister(std.testing.allocator, first));

    const reused = try slots.register(std.testing.allocator);
    try std.testing.expectEqual(first, reused);
}

test "TextureRegistry: double external unregister is idempotent" {
    var slots: ExternalTextureSlots = .{};
    defer slots.deinit(std.testing.allocator);

    const index = try slots.register(std.testing.allocator);
    try std.testing.expect(slots.unregister(std.testing.allocator, index));
    try std.testing.expect(!slots.unregister(std.testing.allocator, index));

    const reused = try slots.register(std.testing.allocator);
    try std.testing.expectEqual(index, reused);
    const next = try slots.register(std.testing.allocator);
    try std.testing.expectEqual(index + 1, next);
}

/// Demo texture pixels: a 64x64 procedural Oklab stripe pattern — eight
/// 8px-wide vertical stripes of distinct saturated colors. The demo card
/// is a full-width, ~16px-tall strip (the root column stretches it), so
/// any horizontal texture detail would collapse under the 4x vertical
/// downscale; vertical stripes survive at full height and read as eight
/// wide color bands — distinctive pixels proving the texture path end to
/// end. Written as rgba32_float in the pipeline's Oklab space (the blit
/// pass converts to sRGB like every other color; rgba8 UNORM could not
/// hold negative Oklab ab chroma).
const demo_tex_size = 64;

fn writeDemoTexturePixels(pixels: [*]f32) void {
    const stripe_w: usize = 8;
    // Eight stripes: magenta, cyan, yellow, green, orange, blue, pink, lime.
    const stripes = [_][4]f32{
        srgbToOklab(.{ 0.9, 0.2, 0.5, 1 }),
        srgbToOklab(.{ 0.1, 0.8, 0.9, 1 }),
        srgbToOklab(.{ 0.95, 0.8, 0.2, 1 }),
        srgbToOklab(.{ 0.2, 0.75, 0.35, 1 }),
        srgbToOklab(.{ 0.95, 0.5, 0.15, 1 }),
        srgbToOklab(.{ 0.25, 0.4, 0.85, 1 }),
        srgbToOklab(.{ 0.9, 0.4, 0.7, 1 }),
        srgbToOklab(.{ 0.6, 0.85, 0.25, 1 }),
    };
    for (0..demo_tex_size) |y| {
        for (0..demo_tex_size) |x| {
            const c = stripes[x / stripe_w];
            pixels[(y * demo_tex_size + x) * 4 + 0] = c[0];
            pixels[(y * demo_tex_size + x) * 4 + 1] = c[1];
            pixels[(y * demo_tex_size + x) * 4 + 2] = c[2];
            pixels[(y * demo_tex_size + x) * 4 + 3] = c[3];
        }
    }
}

/// Create the demo texture (64x64 rgba32_float, one-shot upload via the
/// noapi path: textureCreate + cmdCopyToTexture from a host-visible
/// staging buffer), register it in the GUI texture heap and return its
/// heap index (tex_idx). The texture's OWNED by the registry (destroyed
/// with it).
fn uploadDemoTexture(gpa: std.mem.Allocator, gpu: *noapi.Gpu, registry: *TextureRegistry) !u32 {
    const tex = try gpu.textureCreate(.{
        .dimensions = .{ demo_tex_size, demo_tex_size, 1 },
        .format = .rgba32_float,
        .usage = .{ .sampled = true },
    });
    errdefer gpu.textureDestroy(tex);

    const bytes: u64 = demo_tex_size * demo_tex_size * 4 * @sizeOf(f32);
    const buf = try gpu.gpuMalloc(bytes, 64, .default);
    defer gpu.gpuFree(buf);
    writeDemoTexturePixels(@ptrCast(@alignCast(buf.cpu)));

    // One-shot upload: copy the staging buffer into the texture (GENERAL
    // layout — textureCreate transitions it there; the heap's descriptors
    // use .general too), then idle before the first GUI frame.
    var cmd = try gpu.commandsBegin();
    cmd.copyToTexture(.{
        .gpu = gpu,
        .handle = tex,
        .dimensions = .{ demo_tex_size, demo_tex_size, 1 },
        .format = .rgba32_float,
    }, buf, .{ .size = .{ demo_tex_size, demo_tex_size, 1 } });
    try gpu.queueSubmit(&.{cmd});
    try gpu.waitIdle();

    return registry.register(gpa, tex);
}

/// Decode and upload one local track's artwork during window setup. The
/// registry owns the sampled texture after registration; no frame allocates.
fn uploadArtworkTexture(
    gpa: std.mem.Allocator,
    gpu: *noapi.Gpu,
    registry: *TextureRegistry,
    artwork: ffmpeg_decoder.Artwork,
) !u32 {
    var decoded = try ffmpeg_decoder.decodeArtwork(gpa, artwork);
    defer decoded.deinit(gpa);

    const pixel_count = try std.math.mul(
        usize,
        @as(usize, decoded.width),
        @as(usize, decoded.height),
    );
    const float_count = try std.math.mul(usize, pixel_count, 4);
    const staging_bytes: u64 = @intCast(float_count * @sizeOf(f32));

    const texture = try gpu.textureCreate(.{
        .dimensions = .{ decoded.width, decoded.height, 1 },
        .format = .rgba32_float,
        .usage = .{ .sampled = true },
    });
    errdefer gpu.textureDestroy(texture);

    const staging = try gpu.gpuMalloc(staging_bytes, 64, .default);
    defer gpu.gpuFree(staging);
    const destination: [*]f32 = @ptrCast(@alignCast(staging.cpu));
    for (0..pixel_count) |pixel_index| {
        const source_offset = pixel_index * 4;
        const color = srgbToOklab(.{
            @as(f32, @floatFromInt(decoded.pixels[source_offset])) / 255.0,
            @as(f32, @floatFromInt(decoded.pixels[source_offset + 1])) / 255.0,
            @as(f32, @floatFromInt(decoded.pixels[source_offset + 2])) / 255.0,
            @as(f32, @floatFromInt(decoded.pixels[source_offset + 3])) / 255.0,
        });
        const destination_offset = pixel_index * 4;
        destination[destination_offset + 0] = color[0];
        destination[destination_offset + 1] = color[1];
        destination[destination_offset + 2] = color[2];
        destination[destination_offset + 3] = color[3];
    }

    var command = try gpu.commandsBegin();
    command.copyToTexture(.{
        .gpu = gpu,
        .handle = texture,
        .dimensions = .{ decoded.width, decoded.height, 1 },
        .format = .rgba32_float,
    }, staging, .{ .size = .{ decoded.width, decoded.height, 1 } });
    try gpu.queueSubmit(&.{command});
    try gpu.waitIdle();

    return registry.register(gpa, texture);
}

fn uploadLocalArtwork(
    comptime T: type,
    gpa: std.mem.Allocator,
    root: *T,
    gpu: *noapi.Gpu,
    registry: *TextureRegistry,
    tracks: []const LocalTrack,
) void {
    if (comptime T != spotify_ui.SpotifyApp) return;

    for (tracks, 0..) |track, index| {
        const artwork = track.artwork orelse continue;
        const texture_index = uploadArtworkTexture(gpa, gpu, registry, artwork) catch |err| {
            std.log.warn(
                "embedded artwork upload failed for track {d}: {s}",
                .{ index, @errorName(err) },
            );
            continue;
        };
        root.setArtworkTextureIndex(index, texture_index);
    }
}

/// The tiger demo's reference render: the rsvg-rendered tiger (a raw
/// RGBA8 blob, 512×512, generated at build time from tiger.svg) uploaded
/// as an rgba32_float texture and registered (ui.tiger_ref_idx) for the
/// sampler-only TYPE_TEXTURE path.
const tiger_ref_size = 512;
fn uploadReferenceTexture(gpa: std.mem.Allocator, gpu: *noapi.Gpu, registry: *TextureRegistry) !void {
    const tex = try gpu.textureCreate(.{
        .dimensions = .{ tiger_ref_size, tiger_ref_size, 1 },
        .format = .rgba32_float,
        .usage = .{ .sampled = true },
    });
    errdefer gpu.textureDestroy(tex);

    const bytes: u64 = tiger_ref_size * tiger_ref_size * 4 * @sizeOf(f32);
    const buf = try gpu.gpuMalloc(bytes, 64, .default);
    defer gpu.gpuFree(buf);
    const src = @embedFile("tiger_ref.rgba");
    // The pipeline outputs Oklab (the blit converts to sRGB), so the
    // texture's pixels must be Oklab — the sRGB RGBA8 reference converts
    // per pixel here, exactly like the procedural demo texture's authoring.
    for (0..tiger_ref_size * tiger_ref_size) |pix| {
        const o = pix * 4;
        const ok = srgbToOklab(.{
            @as(f32, @floatFromInt(src[o])) / 255.0,
            @as(f32, @floatFromInt(src[o + 1])) / 255.0,
            @as(f32, @floatFromInt(src[o + 2])) / 255.0,
            @as(f32, @floatFromInt(src[o + 3])) / 255.0, // the reference's alpha (transparent bg)
        });
        const out: [*]f32 = @as([*]f32, @ptrCast(@alignCast(buf.cpu))) + pix * 4;
        out[0] = ok[0];
        out[1] = ok[1];
        out[2] = ok[2];
        out[3] = ok[3];
    }

    var cmd = try gpu.commandsBegin();
    cmd.copyToTexture(.{
        .gpu = gpu,
        .handle = tex,
        .dimensions = .{ tiger_ref_size, tiger_ref_size, 1 },
        .format = .rgba32_float,
    }, buf, .{ .size = .{ tiger_ref_size, tiger_ref_size, 1 } });
    try gpu.queueSubmit(&.{cmd});
    try gpu.waitIdle();

    ui.tiger_ref_idx = try registry.register(gpa, tex);
}
/// 1. Every DrawCmd rect becomes a SceneRect. Ring cmds (borders) get a
///    rounded-rect ring material (type 2, full box radius + border width +
///    border-box size); radius-bearing fill cmds get a rounded-rect fill
///    material (type 2, radius minus border, border 0, inset rect size);
///    solid cmds (no radius) stay material 0. Materials are written into
///    slots allocated downward from the top of the engine's material
///    buffer (rewritten every frame; glyph slots live at the bottom, so
///    there is never a collision). Each cmd gets its own slot because the
///    material carries per-rect geometry.
/// 2. Slider thumbs paint next (rounded bar, before the glyphs so it never
///    occludes the slider's own label).
/// 3. Hover + focus outlines paint after the fills (before the glyphs, so
///    they never overdraw text at the box edges).
/// 4. Every text-bearing node (labels and visible slider labels) emits one
///    glyph SceneRect per character at its ABSOLUTE content box. SVG icon
///    buttons append their cached path rects after glyph emission, with no
///    text fallback.
fn buildSliceRects(
    gpa: std.mem.Allocator,
    text_engine: *TextEngine,
    svg_view: ?*SvgView,
    icon_cache: ?*const IconCache,
    cmds: []const DrawCmd,
    tree: *const WidgetTree,
    hover_id: ?Id,
    hover_alpha: f32,
    focus_id: ?Id,
    out: *std.ArrayList(SceneRect),
) !void {
    const zone = tracy.Zone.begin(.{ .name = "buildSliceRects", .src = @src() });
    defer zone.end();
    // Rounded-rect material slots, allocated from the top of the buffer
    // downward (glyphs own slots 1..next_slot-1 from the bottom; the
    // assert in text.zig caps glyphs well below the top). The SVG view's
    // materials own the TOP region [svg_material_base, MAX_MATERIALS) —
    // the decorations descend from svg_material_base, never into the
    // tiger's slots.
    var material_slot: u32 = svg_material_base;
    // Guard the decoration writes against the LIVE glyph count: glyph
    // slots ascend from slot 1 as the frame's text is rasterized, so the
    // headroom below is next_slot, not 1. With `> 1` a burst of
    // decorations could silently write into in-flight glyph material;
    // with the live count the assert fires instead.
    const glyph_slots = text_engine.glyphSlotCount();

    for (cmds) |cmd| {
        const paint = cmd.paint;
        const corner_l: f32 = if (cmd.ring)
            paint.radius.left
        else
            @max(0, paint.radius.left - cmd.border.left);
        const corner_r: f32 = if (cmd.ring)
            paint.radius.right
        else
            @max(0, paint.radius.right - cmd.border.right);
        const corner_t: f32 = if (cmd.ring)
            paint.radius.top
        else
            @max(0, paint.radius.top - cmd.border.top);
        const corner_b: f32 = if (cmd.ring)
            paint.radius.bottom
        else
            @max(0, paint.radius.bottom - cmd.border.bottom);

        // Rounded-rect material geometry: one radius per axis (the SDF
        // rounds all four corners; demo boxes use uniform radii). Rings
        // always need the ring material (their interior is punched out);
        // fills need one only when they carry a radius.
        const rx: f32 = @max(corner_l, corner_r);
        const ry: f32 = @max(corner_t, corner_b);
        const border: f32 = if (cmd.ring)
            @max(
                @max(cmd.border.left, cmd.border.right),
                @max(cmd.border.top, cmd.border.bottom),
            )
        else
            0;

        var material_index: u32 = 0;
        // The shadow cmd's rect is the border box plus the core's
        // drop-shadow offset, so its corners are the box's radii (not the
        // border-inset radii used for fills).
        var slice_corner_l: f32 = corner_l;
        var slice_corner_r: f32 = corner_r;
        var slice_corner_t: f32 = corner_t;
        var slice_corner_b: f32 = corner_b;
        if (cmd.paint.shadow > 0) {
            // Shadow cmd: feathered rounded-rect material (type 3). The
            // shader fades the coverage over feather/2 px BEYOND the SDF
            // edge — so the quad must be expanded by the feather on every
            // side or the fade is clipped at the quad boundary (the old
            // quad was exactly the widget's rect: shadows rendered as a
            // ~1px line). The material's win_w/h stay the WIDGET's size
            // (the SDF's rect) and the origin stays its top-left; only the
            // rasterized quad grows.
            slice_corner_l = paint.radius.left;
            slice_corner_r = paint.radius.right;
            slice_corner_t = paint.radius.top;
            slice_corner_b = paint.radius.bottom;
            const shadow_rx: f32 = @max(paint.radius.left, paint.radius.right);
            const shadow_ry: f32 = @max(paint.radius.top, paint.radius.bottom);
            const feather = cmd.paint.shadow;
            std.debug.assert(material_slot > glyph_slots); // never reach the live glyph slots
            material_slot -= 1;
            renderer.GlyphSweeper.writeShadowMaterial(
                text_engine.materials,
                material_slot,
                shadow_rx,
                shadow_ry,
                feather,
                cmd.rect.w,
                cmd.rect.h,
            );
            material_index = material_slot;
            try out.append(gpa, .{
                .dst = .{
                    cmd.rect.x - feather,
                    cmd.rect.y - feather,
                    cmd.rect.w + 2 * feather,
                    cmd.rect.h + 2 * feather,
                },
                .src = .{ 0, 0, 1, 1 },
                .corners = .{ slice_corner_l, slice_corner_r, slice_corner_t, slice_corner_b },
                .color = srgbToOklab(cmd.color),
                .curve = .{ 0, 0, 0, 0 },
                .material_index = material_index,
                .clip_id = cmd.clip_id,
                .origin = .{ cmd.rect.x, cmd.rect.y },
                .tex_idx = cmd.tex_idx,
                .z = cmd.paint.layer,
            });
            continue;
        } else if (cmd.ring or rx > 0 or ry > 0) {
            std.debug.assert(material_slot > glyph_slots); // never reach the live glyph slots
            material_slot -= 1;
            // Ring materials always carry the ring's gradient (the demo sets
            // none); fills carry one only when the gradient flag is set.
            const gradient: [4]f32 = if (cmd.ring or cmd.paint.gradient[3] > 0) cmd.paint.gradient else .{ 0, 0, 0, 0 };
            renderer.GlyphSweeper.writeRoundedRectMaterial(
                text_engine.materials,
                material_slot,
                rx,
                ry,
                border,
                cmd.rect.w,
                cmd.rect.h,
                gradient,
            );
            material_index = material_slot;
        }

        try out.append(gpa, .{
            .dst = .{ cmd.rect.x, cmd.rect.y, cmd.rect.w, cmd.rect.h },
            .src = .{ 0, 0, 1, 1 },
            .corners = .{ slice_corner_l, slice_corner_r, slice_corner_t, slice_corner_b },
            // The drawcmd colors are sRGB-authored EXCEPT the textured
            // fill's identity tint: the tint must stay (1,1,1) in the
            // Oklab space the shader multiplies in — converting it through
            // srgbToOklab yields Oklab white (1,0,0), which zeroes the
            // sample's a/b chroma (every texture renders grayscale).
            .color = if (cmd.tex_idx != 0xFFFFFFFF) cmd.color else srgbToOklab(cmd.color),
            .curve = .{ 0, 0, 0, 0 },
            .material_index = material_index,
            .clip_id = cmd.clip_id,
            .origin = .{ cmd.rect.x, cmd.rect.y },
            .tex_idx = cmd.tex_idx,
            .z = cmd.paint.layer,
        });
    }

    // Slider progress and thumbs paint before glyphs so a thumb never covers
    // the slider's own visible label.
    for (tree.nodes.items) |*n| {
        if (n.kind != .slider) continue;
        const s = n.kind.slider;
        const r = visualBorderRect(tree, n.id);
        if (r.w <= 0 or r.h <= 0) continue;
        // A max <= min slider has no valid range: 0/0 (or overflow) would
        // yield NaN/inf and poison the progress or thumb rect. Center both.
        const range = s.max - s.min;
        const frac = std.math.clamp(if (range <= 0) 0.5 else (s.value.* - s.min) / range, 0, 1);
        const progress_w = frac * r.w;
        if (progress_w > 0) {
            const progress_radius: f32 = @min(2, r.h / 2);
            std.debug.assert(material_slot > glyph_slots);
            material_slot -= 1;
            renderer.GlyphSweeper.writeRoundedRectMaterial(
                text_engine.materials,
                material_slot,
                progress_radius,
                progress_radius,
                0,
                progress_w,
                r.h,
                .{ 0, 0, 0, 0 },
            );
            try out.append(gpa, .{
                .dst = .{ r.x, r.y, progress_w, r.h },
                .src = .{ 0, 0, 1, 1 },
                .corners = .{ progress_radius, progress_radius, progress_radius, progress_radius },
                .color = srgbToOklab(s.color),
                .curve = .{ 0, 0, 0, 0 },
                .material_index = material_slot,
                .clip_id = n.paint_clip_id,
                .origin = .{ r.x, r.y },
            });
        }

        const thumb = sliderThumbRect(r, frac);
        if (thumb.w <= 0 or thumb.h <= 0) continue;
        const thumb_radius: f32 = @min(3, @min(thumb.w, thumb.h) / 2);
        std.debug.assert(material_slot > glyph_slots);
        material_slot -= 1;
        renderer.GlyphSweeper.writeRoundedRectMaterial(
            text_engine.materials,
            material_slot,
            thumb_radius,
            thumb_radius,
            0,
            thumb.w,
            thumb.h,
            .{ 0, 0, 0, 0 },
        );
        try out.append(gpa, .{
            .dst = .{ thumb.x, thumb.y, thumb.w, thumb.h },
            .src = .{ 0, 0, 1, 1 },
            .corners = .{ thumb_radius, thumb_radius, thumb_radius, thumb_radius },
            .color = srgbToOklab(.{ 0.82, 0.82, 0.85, 1 }),
            .curve = .{ 0, 0, 0, 0 },
            .material_index = material_slot,
            .clip_id = n.paint_clip_id,
            .origin = .{ thumb.x, thumb.y },
        });
    }

    // Hover outline: a 2px rounded ring around the hovered node (type-2
    // ring material — the SDF punches the interior), painted before the
    // glyphs so it never overdraws the text at the box edges.
    if (hover_id) |hid| {
        for (tree.nodes.items) |*n| {
            if (n.id != hid) continue;
            const r = visualBorderRect(tree, n.id);
            if (r.w <= 0 or r.h <= 0) break;
            const ring_rx: f32 = @max(n.paint.radius.left, n.paint.radius.right);
            const ring_ry: f32 = @max(n.paint.radius.top, n.paint.radius.bottom);
            std.debug.assert(material_slot > glyph_slots);
            material_slot -= 1;
            renderer.GlyphSweeper.writeRoundedRectMaterial(
                text_engine.materials,
                material_slot,
                ring_rx,
                ring_ry,
                2,
                r.w,
                r.h,
                .{ 0, 0, 0, 0 },
            );
            try out.append(gpa, .{
                .dst = .{ r.x, r.y, r.w, r.h },
                .src = .{ 0, 0, 1, 1 },
                .corners = .{
                    n.paint.radius.left,
                    n.paint.radius.right,
                    n.paint.radius.top,
                    n.paint.radius.bottom,
                },
                // Amber ring fades in by hover_alpha (the core eases it);
                // hover_alpha 1 reproduces the solid ring.
                .color = srgbToOklab(.{ 1.0, 0.8, 0.2, hover_alpha }),
                .curve = .{ 0, 0, 0, 0 },
                .material_index = material_slot,
                .clip_id = n.paint_clip_id,
                .origin = .{ r.x, r.y },
            });
            break;
        }
    }

    // Focus ring: a 2px cyan rounded ring around the keyboard-focused node.
    if (focus_id) |fid| {
        for (tree.nodes.items) |*n| {
            if (n.id != fid) continue;
            const r = visualBorderRect(tree, n.id);
            if (r.w <= 0 or r.h <= 0) break;
            const ring_rx: f32 = @max(n.paint.radius.left, n.paint.radius.right);
            const ring_ry: f32 = @max(n.paint.radius.top, n.paint.radius.bottom);
            std.debug.assert(material_slot > glyph_slots);
            material_slot -= 1;
            renderer.GlyphSweeper.writeRoundedRectMaterial(
                text_engine.materials,
                material_slot,
                ring_rx,
                ring_ry,
                2,
                r.w,
                r.h,
                .{ 0, 0, 0, 0 },
            );
            try out.append(gpa, .{
                .dst = .{ r.x, r.y, r.w, r.h },
                .src = .{ 0, 0, 1, 1 },
                .corners = .{
                    n.paint.radius.left,
                    n.paint.radius.right,
                    n.paint.radius.top,
                    n.paint.radius.bottom,
                },
                .color = srgbToOklab(.{ 0.25, 0.85, 0.85, 1 }),
                .curve = .{ 0, 0, 0, 0 },
                .material_index = material_slot,
                .clip_id = n.paint_clip_id,
                .origin = .{ r.x, r.y },
            });
            break;
        }
    }

    for (tree.nodes.items) |*n| {
        const text: ?[]const u8 = switch (n.kind) {
            // Buttons emit through their child label node — one text path.
            .label => |l| l.text,
            .slider => sliderVisualLabel(n.kind),
            else => null,
        };
        const t = text orelse continue;
        if (t.len == 0) continue;
        const content = visualContentRect(tree, n.id);
        if (content.w == 0 or content.h == 0) continue;
        const size: u32 = if (n.font_size > 0) @intFromFloat(@round(n.font_size)) else font_size_px;
        const text_color: [4]f32 = switch (n.kind) {
            .label => |l| l.color,
            .slider => |s| s.color,
            else => unreachable,
        };
        // The node's clip id (stamped by collectDrawCmds): glyphs inside
        // a `.clip` container are clipped to its rect like any other cmd.
        // The node's layer key stamps the glyphs' z: a layered node's text
        // must ride its OWN layer (the layer-1 badge's caption would
        // otherwise sort below the badge's z=1 fill and vanish behind it).
        const before = out.items.len;
        switch (n.text_overflow) {
            .ellipsis => {
                const baseline_y = text_engine.baselineIn(content.y, content.h, size, n.font_id);
                const max_width: f32 = @min(content.w, n.text_max_width orelse content.w);
                try text_engine.emitTextWithWidth(
                    t,
                    content.x,
                    baseline_y,
                    size,
                    n.font_id,
                    n.clip_id,
                    srgbToOklab(text_color),
                    max_width,
                    out,
                );
            },
            .clip => if (n.text_max_width != null) {
                const baseline_y = text_engine.baselineIn(content.y, content.h, size, n.font_id);
                try text_engine.emitText(
                    t,
                    content.x,
                    baseline_y,
                    size,
                    n.font_id,
                    n.clip_id,
                    srgbToOklab(text_color),
                    out,
                );
            } else {
                try text_engine.emitTextFlow(
                    t,
                    content.x,
                    content.y,
                    content.w,
                    content.h,
                    size,
                    n.font_id,
                    n.clip_id,
                    srgbToOklab(text_color),
                    out,
                );
            },
            .visible => try text_engine.emitTextFlow(
                t,
                content.x,
                content.y,
                content.w,
                content.h,
                size,
                n.font_id,
                n.clip_id,
                srgbToOklab(text_color),
                out,
            ),
        }
        if (n.paint.layer > 0) {
            for (out.items[before..]) |*r| r.z = n.paint.layer;
        }
    }

    // SVG icon buttons use the cache initialized by both `run` and
    // `runShot`. The fixed 16px sweep space means this frame loop only
    // copies cached SceneRects.
    if (icon_cache) |cache| {
        for (tree.nodes.items) |*n| {
            const button = switch (n.kind) {
                .button => |b| b,
                else => continue,
            };
            const icon = button.icon orelse continue;
            const content = visualContentRect(tree, n.id);
            if (content.w <= 0 or content.h <= 0) continue;
            const view = cache.get(icon);
            const bounds = view.boundsRect();
            if (bounds.w <= 0 or bounds.h <= 0) continue;
            const ox = content.x + (content.w - bounds.w) / 2 - bounds.x;
            const oy = content.y + (content.h - bounds.h) / 2 - bounds.y;
            for (view.rects()) |r| {
                try out.append(gpa, .{
                    .dst = .{ ox + r.dst[0], oy + r.dst[1], r.dst[2], r.dst[3] },
                    .src = r.src,
                    .corners = r.corners,
                    .color = srgbToOklab(button.color),
                    .curve = r.curve,
                    .material_index = r.material_index,
                    .clip_id = n.clip_id,
                    .origin = .{ ox + r.origin[0], oy + r.origin[1] },
                    .tex_idx = r.tex_idx,
                    .z = n.paint.layer,
                });
            }
        }
    }

    // The SVG showcase: inject the tiger's cached scene rects, scaled +
    // translated into the reserved card's content rect (the tiger's
    // viewBox is 900×900 — an aspect-fit into the square box). The rects
    // are the glyph-style quads with the per-path materials from the
    // shared buffer's SVG region.
    if (svg_view) |sv| {
        const card = try svgCardRect(tree);
        const card_rect = card.rect;
        const vb = sv.boundsRect();
        if (card_rect.w > 0 and card_rect.h > 0 and vb.w > 0 and vb.h > 0) {
            // The stroke test scene's algo + oversize sliders, applied to
            // the stroke materials each frame (the tiger's defaults: algo
            // 0, oversize 1).
            sv.setStrokeStyle(@intFromFloat(@min(@max(ui.stroke_algo, 0), 2)), ui.stroke_oversize);
            // Fit the paths' ACTUAL union bounds (the tiger's paths extend
            // beyond its viewBox with negative coords — the viewBox fit
            // would land them off-card), translated so the bounds' origin
            // maps into the card. The stroke test scene multiplies the fit
            // by its scale slider (the tiger's default 1.0).
            const scale: f32 = @min(card_rect.w / vb.w, card_rect.h / vb.h) * ui.stroke_scale;
            const ox = card_rect.x + (card_rect.w - vb.w * scale) / 2 - vb.x * scale;
            const oy = card_rect.y + (card_rect.h - vb.h * scale) / 2 - vb.y * scale;
            // The curves are swept in pixel space (the glyph branch's 1x1
            // window) — bake the fit scale into the GPU curve buffers.
            sv.setScale(scale);
            // std.log.info("svg: card=({d:.0},{d:.0},{d:.0},{d:.0}) scale={d:.3}", .{
            //     card_rect.x, card_rect.y, card_rect.w, card_rect.h, scale
            // });
            for (sv.rects()) |r| {
                try out.append(gpa, .{
                    .dst = .{ ox + r.dst[0] * scale, oy + r.dst[1] * scale, r.dst[2] * scale, r.dst[3] * scale },
                    .src = .{ 0, 0, 1, 1 },
                    .corners = .{ 0, 0, 0, 0 },
                    .color = r.color,
                    .curve = .{ r.curve[0] * scale, r.curve[1] * scale, r.curve[2] * scale, r.curve[3] * scale },
                    .material_index = r.material_index,
                    .clip_id = r.clip_id,
                    .origin = .{ ox + r.origin[0] * scale, oy + r.origin[1] * scale },
                    .tex_idx = r.tex_idx,
                    // Paint ON the card: the default z=0 would sort the
                    // rects BEHIND the card's fill (every box layer > 0).
                    .z = card.layer,
                });
            }
        }
    }

    // The v1 bag contract: stamp the submission counter — the stable
    // tiebreaker the CS1 sort keys on. The paint order IS the append
    // order; reversing the bag (--gpu-sort-verify) changes the buffer
    // positions but not the counters, so the sort restores the paint
    // order. Stamped at the END so the SVG injection's rects (appended
    // after the tree pass) get their true positions too.
    for (out.items, 0..) |*r, i| r.order = @intCast(i);
}
/// Collect one frame's draw commands and convert them into renderer scene rects.
/// The caller owns the temporary draw-command storage.
fn buildFrameScene(
    gpa: std.mem.Allocator,
    text_engine: *TextEngine,
    svg_view: ?*SvgView,
    icon_cache: ?*const IconCache,
    frame: *const nogui.FrameOutput,
    out: *std.ArrayList(SceneRect),
    gpu_sort_verify: bool,
) !void {
    var draw_cmds: std.ArrayList(DrawCmd) = .empty;
    defer draw_cmds.deinit(gpa);
    const capacity = std.math.mul(usize, frame.tree.nodes.items.len, 3) catch return error.OutOfMemory;
    try draw_cmds.ensureTotalCapacity(gpa, capacity);
    try buildFrameSceneInto(
        gpa,
        text_engine,
        svg_view,
        icon_cache,
        frame,
        out,
        &draw_cmds,
        gpu_sort_verify,
    );
}

/// Convert a laid-out tree into scene rects using caller-owned draw commands.
/// The command list is cleared and filled without allocation or free.
fn buildFrameSceneInto(
    gpa: std.mem.Allocator,
    text_engine: *TextEngine,
    svg_view: ?*SvgView,
    icon_cache: ?*const IconCache,
    frame: *const nogui.FrameOutput,
    out: *std.ArrayList(SceneRect),
    draw_cmds: *std.ArrayList(DrawCmd),
    gpu_sort_verify: bool,
) !void {
    try collectDrawCmdsInto(
        @constCast(frame.tree),
        frame.pressed,
        frame.press_alpha,
        draw_cmds,
    );
    try buildSliceRects(
        gpa,
        text_engine,
        svg_view,
        icon_cache,
        draw_cmds.items,
        frame.tree,
        frame.hover,
        frame.hover_alpha,
        frame.focus,
        out,
    );
    // --gpu-sort-verify: submit the bag in REVERSE paint order — the
    // CS1 sort (stable on (z, order)) must restore the paint order.
    if (gpu_sort_verify) std.mem.reverse(SceneRect, out.items);
}

/// Render the current app frame into the offscreen Oklab target. Shared by
/// run() (presented via the blit pass) and runShot() (read back).
/// `texture_heap` is the GUI texture heap (the bindless textures the
/// fragment shader samples) — bound ONCE per frame before the renderer draw;
/// the blit pass binds its own heap later.
fn recordFrameScene(
    gui_renderer: *Renderer,
    cmd: *noapi.CommandBuffer,
    slice_rects: []const SceneRect,
    clip_rects: []const ClipRect,
    render_target: noapi.TextureHandle,
    surface_size: noapi.Extent2D,
    texture_heap: noapi.DescriptorHeap,
) !void {
    const zone = tracy.Zone.begin(.{ .name = "renderPass1", .src = @src() });
    defer zone.end();
    const sw: f32 = @floatFromInt(surface_size.width);
    const sh: f32 = @floatFromInt(surface_size.height);

    // CS1 (V1b) FIRST, outside the render pass: Renderer.prepare uploads
    // the borrowed scene, dispatches the stable radix sort, and records
    // the compute → graphics barriers. Compute cannot run inside dynamic
    // rendering, so the prepare/draw split mirrors the pass structure.
    const render_clip_rects: []const renderer.ClipRect = @ptrCast(clip_rects);
    const scene: RenderScene = .{
        .rects = slice_rects,
        .clips = render_clip_rects,
    };
    try gui_renderer.prepare(cmd, scene);

    cmd.beginRendering(.{ .color_attachments = &.{
        .{ .texture = render_target, .load_op = .clear, .store_op = .store, .clear_color = oklab_gray },
    }, .render_area_size = .{ surface_size.width, surface_size.height } });

    // The v1 general blending pipeline (spec §4): ONE uniform alpha blend
    // for every drawable — translucency is a material/color property,
    // never a pipeline switch. src_alpha/one_minus_src_alpha (the
    // straight-alpha convention: the blend scales the source rgb by the
    // source alpha, so the SDF branches' coverage × color and the solid
    // branch's straight output are both correct without shader-side
    // premultiplication).
    cmd.setBlendState(.{
        .enable = true,
        .color_op = .add,
        .src_color_factor = .src_alpha,
        .dst_color_factor = .one_minus_src_alpha,
        .alpha_op = .add,
        .src_alpha_factor = .one,
        .dst_alpha_factor = .one_minus_src_alpha,
    });
    // Bind the GUI texture heap (set 0 = app-registered textures, set 2 =
    // samplers) — ONE call; bindings are not draws, so the one-draw
    // invariant holds. The blit pass re-binds its own heap afterwards.
    cmd.bindDescriptorSets(texture_heap);
    // Renderer.draw records the one indirect GUI draw inside the pass.
    gui_renderer.draw(cmd, sw, sh);
    cmd.setBlendEnable(false);
    cmd.endRendering();
}

fn recordColorConversion(
    cmd: *noapi.CommandBuffer,
    destination: noapi.TextureHandle,
    surface_size: noapi.Extent2D,
    blit_vert: noapi.Shader,
    blit_frag: noapi.Shader,
    blit_heap: noapi.DescriptorHeap,
) void {
    cmd.beginRendering(.{ .color_attachments = &.{
        .{ .texture = destination, .load_op = .clear, .store_op = .store, .clear_color = .{ 0, 0, 0, 1 } },
    }, .render_area_size = .{ surface_size.width, surface_size.height } });

    cmd.setShaders(blit_vert, blit_frag);
    cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
    cmd.bindDescriptorSets(blit_heap);
    cmd.setBlendEnable(false);
    cmd.draw(noapi.PushData{}, 3, 1);
    cmd.endRendering();
}

const PerfResources = struct {
    gpa: std.mem.Allocator,
    io: Io,
    gpu: *noapi.Gpu,
    text_engine: *TextEngine,
    gui_renderer: *Renderer,
    tex_registry: *TextureRegistry,
    svg_view: *SvgView,
    icon_cache: *IconCache,
    gpu_endpoint: *nogui.GpuEndpoint,
    blit_vert: noapi.Shader,
    blit_frag: noapi.Shader,
    blit_sampler: u64,
};

pub const OffscreenSlots = struct {
    pub const count: usize = 3;
    pub const query_count: u32 = 6;

    gpu: *noapi.Gpu,
    oklab_targets: [count]noapi.TextureHandle = undefined,
    srgb_targets: [count]noapi.TextureHandle = undefined,
    blit_heaps: [count]noapi.DescriptorHeap = undefined,
    timeline: noapi.Semaphore = undefined,
    timestamp_queries: ?noapi.TimestampQuerySet = null,
    oklab_count: usize = 0,
    srgb_count: usize = 0,
    blit_heap_count: usize = 0,
    timeline_created: bool = false,

    pub fn init(gpu: *noapi.Gpu, blit_sampler: u64) !OffscreenSlots {
        var slots: OffscreenSlots = .{ .gpu = gpu };
        errdefer slots.deinit();

        while (slots.oklab_count < count) : (slots.oklab_count += 1) {
            slots.oklab_targets[slots.oklab_count] = try gpu.textureCreate(.{
                .dimensions = .{ perf_width, perf_height, 1 },
                .format = render_target_format,
                .usage = .{ .sampled = true, .color_attachment = true },
            });
        }
        while (slots.srgb_count < count) : (slots.srgb_count += 1) {
            slots.srgb_targets[slots.srgb_count] = try gpu.textureCreate(.{
                .dimensions = .{ perf_width, perf_height, 1 },
                .format = .rgba8_srgb,
                .usage = .{ .sampled = true, .color_attachment = true },
            });
        }
        slots.timeline = try gpu.semaphoreCreate(0);
        slots.timeline_created = true;

        while (slots.blit_heap_count < count) : (slots.blit_heap_count += 1) {
            const slot = slots.blit_heap_count;
            const heap = try gpu.descHeapCreate(1, 0, 1);
            slots.blit_heaps[slot] = heap;
            const source_descriptor = gpu.textureViewDescriptor(
                slots.oklab_targets[slot],
                .{},
            );
            gpu.descHeapSetTextures(heap, 0, &.{source_descriptor});
            gpu.descHeapSetSamplers(heap, 0, &.{blit_sampler});
        }

        if (comptime v7_options.gpu_timestamps) {
            if (gpu.timestampInfo() == null) return error.GpuTimestampUnavailable;
            slots.timestamp_queries = try gpu.timestampQuerySetCreate(query_count);
        }
        return slots;
    }

    pub fn deinit(self: *OffscreenSlots) void {
        if (self.timestamp_queries) |queries| {
            self.gpu.timestampQuerySetDestroy(queries);
        }
        if (self.timeline_created) self.gpu.semaphoreDestroy(self.timeline);
        var index = self.blit_heap_count;
        while (index > 0) {
            index -= 1;
            self.gpu.descHeapDestroy(self.blit_heaps[index]);
        }
        index = self.srgb_count;
        while (index > 0) {
            index -= 1;
            self.gpu.textureDestroy(self.srgb_targets[index]);
        }
        index = self.oklab_count;
        while (index > 0) {
            index -= 1;
            self.gpu.textureDestroy(self.oklab_targets[index]);
        }
        self.* = undefined;
    }
};

const perf_width: u32 = 954;
const perf_height: u32 = 1044;
const perf_extent: noapi.Extent2D = .{ .width = perf_width, .height = perf_height };
const perf_draw_cmd_capacity: usize = 16 * 1024;

pub const RunOptions = struct {
    subpixel: bool = false,
    quad_debug: bool = false,
    bgr_order: bool = false,
    damp_chroma: bool = true,
    gpu_sort_verify: bool = false,
    max_frames: ?u32 = null,
    audio_tracks: ?[]const LocalTrack = null,
    perf: ?perf.Config = null,

    pub fn validate(self: RunOptions) (error{
        PerfOptionConflict,
        InvalidPerfFrames,
        InvalidPerfOutput,
    } || perf.RecorderError)!RunOptions {
        if (self.perf) |config| {
            _ = try perf.Config.validate(config);
            if (self.subpixel) return error.PerfOptionConflict;
            if (self.quad_debug) return error.PerfOptionConflict;
            if (self.bgr_order) return error.PerfOptionConflict;
            if (!self.damp_chroma) return error.PerfOptionConflict;
            if (self.gpu_sort_verify) return error.PerfOptionConflict;
            if (self.max_frames != null) return error.PerfOptionConflict;
            if (self.audio_tracks != null) return error.PerfOptionConflict;
        }
        return self;
    }
};

/// Run the graphical demo. Blocks until the window closes.
/// Generic over the root component (any type with pub draw(self, ctx) !void).
pub fn run(
    comptime T: type,
    app: *App,
    root: *T,
    options: RunOptions,
) !void {
    const validated_options = try options.validate();
    const subpixel = validated_options.subpixel;
    const quad_debug = validated_options.quad_debug;
    const bgr = validated_options.bgr_order;
    const damp = validated_options.damp_chroma;
    const gpu_sort_verify = validated_options.gpu_sort_verify;
    const max_frames = validated_options.max_frames;
    const audio_tracks = validated_options.audio_tracks;
    const perf_config = validated_options.perf;
    const finite_frames: ?u32 = if (perf_config) |config| blk: {
        const validated = try perf.Config.validate(config);
        break :blk switch (validated.mode) {
            .offscreen, .presented => validated.warmup_frames + validated.sample_frames,
        };
    } else max_frames;
    if (ui.gpu_remount_smoke) {
        if (comptime T != ui.TodoApp) return error.GpuRemountSmokeRequiresTodo;
    }

    const gpa = app.gpa;

    // OVERRIDE priority: the SDL gives env vars precedence over
    // default-priority hints, so a session-set SDL_VIDEODRIVER makes
    // plain hints.set fail with "An environment variable is taking
    // priority". The demo REQUIRES the wayland + vulkan drivers; its
    // choice must win.
    try sdl3.hints.setWithPriority(.video_driver, "wayland", .override);
    try sdl3.hints.setWithPriority(.render_driver, "vulkan", .override);
    try sdl3.init(.{ .video = true, .events = true });
    defer sdl3.quit(.{ .video = true, .events = true });

    // Io backs shader reads and the dedicated audio worker.
    var io_impl = std.Io.Threaded.init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var audio_initialized = false;
    if (audio_tracks) |tracks| {
        if (comptime T != spotify_ui.SpotifyApp) return error.AudioRequiresSpotify;
        if (tracks.len > 0) {
            if (sdl3.init(.{ .audio = true })) |_| {
                audio_initialized = true;
            } else |err| {
                std.log.err("SDL audio initialization failed: {s}", .{@errorName(err)});
            }
        }
    }
    defer if (audio_initialized) sdl3.quit(.{ .audio = true });

    var audio_player: ?AudioPlayer = null;
    if (audio_tracks) |tracks| {
        if (audio_initialized) {
            audio_player = AudioPlayer.init(gpa, io, tracks) catch |err| blk: {
                std.log.err("audio stream initialization failed: {s}", .{@errorName(err)});
                break :blk null;
            };
        }
    }
    defer if (audio_player) |*player| player.deinit();

    const AudioSeek = struct {
        selected_index: usize,
        position_sec: f32,
    };
    var audio_seek_sent: ?AudioSeek = null;

    const perf_window = perf_config != null;
    const perf_offscreen = if (perf_config) |config| config.mode == .offscreen else false;
    const window_width: u32 = if (perf_window) perf_width else 1100;
    const window_height: u32 = if (perf_window) perf_height else 1160;
    const sdl_win = try sdl3.video.Window.init("nogui v7 demo", window_width, window_height, .{
        .resizable = !perf_window,
        .hidden = perf_offscreen,
        .vulkan = true,
    });
    defer sdl_win.deinit();
    if (!perf_offscreen) try sdl_win.show();

    // Vulkan loader via SDL3.
    try sdl3.vulkan.loadLibrary(null);
    const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();
    const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
    exts_copy_global = try gpa.dupe([*:0]const u8, sdl_exts);
    defer gpa.free(exts_copy_global);

    // Load SPIR-V: quad_vert/quad_frag for Renderer, the CS1 sort
    // sort compute (V1b), plus the fullscreen blit pass (Oklab → sRGB).
    var quad_vert_f = try ShaderFile.load(gpa, io, "shaders/quad_vert.spv");
    defer quad_vert_f.deinit(gpa);
    var quad_frag_f = try ShaderFile.load(gpa, io, "shaders/quad_frag.spv");
    defer quad_frag_f.deinit(gpa);
    var sort_comp_f = try ShaderFile.load(gpa, io, "shaders/sort_comp.spv");
    defer sort_comp_f.deinit(gpa);
    var fullscreen_vert_f = try ShaderFile.load(gpa, io, "shaders/fullscreen_vert.spv");
    defer fullscreen_vert_f.deinit(gpa);
    var blit_oklab_f = try ShaderFile.load(gpa, io, "shaders/blit_oklab.spv");
    defer blit_oklab_f.deinit(gpa);

    // GPU init.
    var gpu = try noapi.Gpu.init(.{
        .frames_in_flight = 3,
        .app_name = "v7-demo",
        .validation = false,
        .timestamp_queries = v7_options.gpu_timestamps,
        .loader = .{
            .get_instance_proc_addr = @ptrCast(get_proc_addr),
            .get_instance_extensions = &getExts,
        },
        .io = io,
    });
    defer gpu.deinit();

    // Text engine owns FreeType, per-size font states, and the glyph
    // material buffer. Renderer owns the quad shaders and draw buffers.
    var text_engine = try TextEngine.init(gpa, &gpu);
    defer text_engine.deinit();
    TextEngine.measure_engine = &text_engine;
    app.measure = TextEngine.measureForFlex;
    var gui_renderer = try Renderer.init(&gpu, quad_vert_f.spv, quad_frag_f.spv, sort_comp_f.spv);
    defer gui_renderer.deinit();
    var render_options: RenderOptions = .{
        .material_bda = text_engine.materialBda(),
        .subpixel = subpixel,
        .quad_debug = quad_debug,
        .bgr_order = bgr,
        .damp_chroma = damp,
    };
    gui_renderer.configure(render_options);

    // GUI texture heap + registry: persistent bindless heap (set 0 =
    // registered textures, set 2 = the shared linear/clamp sampler), bound
    // once per frame before the renderer draw. The demo registers one
    // procedural texture and the UI draws it via `.texture = idx`.
    var tex_registry = try TextureRegistry.init(gpa, &gpu);
    defer tex_registry.deinit(gpa);
    ui.texture_idx = try uploadDemoTexture(gpa, &gpu, &tex_registry);
    try uploadReferenceTexture(gpa, &gpu, &tex_registry);
    if (audio_tracks) |tracks| {
        uploadLocalArtwork(T, gpa, root, &gpu, &tex_registry, tracks);
    }

    // SVG showcase: the tiger, parsed + converted once (the paths →
    // conics → glyph materials + cached scene rects).
    // The stroke test scene (the TestStrokesApp root) loads the curved
    // thin-stroke set; everything else loads the tiger.
    var svg_view = if (comptime T == ui.TestStrokesApp)
        try initStrokeView(gpa, &gpu, &text_engine)
    else
        try initSvgView(gpa, &gpu, &text_engine);
    defer svg_view.deinit(&gpu);
    // Transport icons share TextEngine's material buffer but are initialized
    // only in the interactive window. No parsing or GPU allocation occurs
    // in the frame loop.
    var icon_cache = try IconCache.init(gpa, &gpu, &text_engine);
    defer icon_cache.deinit(&gpu);

    // Blit shaders are common to both perf modes. Descriptor heaps are owned
    // by the active runner so offscreen owns exactly one heap per slot.
    const blit_vert = try gpu.shaderCreate(fullscreen_vert_f.spv, .vertex, "main", "fullscreen_vert");
    defer gpu.shaderDestroy(blit_vert);
    const blit_frag = try gpu.shaderCreate(blit_oklab_f.spv, .fragment, "main", "blit_oklab");
    defer gpu.shaderDestroy(blit_frag);
    const blit_sampler = gpu.samplerDescriptor(.{
        .min_filter = .nearest,
        .mag_filter = .nearest,
        .mip_filter = .nearest,
    });

    // Offscreen Oklab render target, recreated on resize.
    var render_target: noapi.TextureHandle = .{};
    var rt_w: u32 = 0;
    var rt_h: u32 = 0;
    defer if (render_target.texture.id != 0) gpu.textureDestroy(render_target);
    configureGpuComponents(T, root, tex_registry.heap);

    // The endpoint borrows the window-owned GPU and texture registry for the
    // graphical lifetime. Components initialize here, before the first
    // begun Surface frame, and detach while those resources are still alive.
    var gpu_texture_runtime: nogui.TextureRegistry = .{
        .ptr = &tex_registry,
        .register = registerRuntimeTexture,
        .unregister = unregisterRuntimeTexture,
    };
    var gpu_endpoint: nogui.GpuEndpoint = .{
        .gpu = &gpu,
        .textures = &gpu_texture_runtime,
    };
    try app.attachGpu(&gpu_endpoint);
    defer app.detachGpu();

    if (perf_config) |config| {
        const resources: PerfResources = .{
            .gpa = gpa,
            .io = io,
            .gpu = &gpu,
            .text_engine = &text_engine,
            .gui_renderer = &gui_renderer,
            .tex_registry = &tex_registry,
            .svg_view = &svg_view,
            .icon_cache = &icon_cache,
            .gpu_endpoint = &gpu_endpoint,
            .blit_vert = blit_vert,
            .blit_frag = blit_frag,
            .blit_sampler = blit_sampler,
        };
        var recorder = try perf.Recorder.init(gpa, try config.totalFrames());
        defer recorder.deinit();

        const metadata = switch (config.mode) {
            .offscreen => try runOffscreenPerf(T, app, root, &resources, config, &recorder),
            .presented => blk: {
                const sdl_surface = try sdl3.vulkan.Surface.init(
                    sdl_win,
                    @ptrFromInt(@intFromEnum(gpu.instanceHandle())),
                    null,
                );
                const surface: vk.SurfaceKHR = @enumFromInt(@intFromPtr(sdl_surface.surface));
                var gw = try noapi.Surface.init(&gpu, surface, .{
                    .extent = perf_extent,
                    .present_mode = .fifo,
                });
                defer gw.deinit();
                const refresh_hz: ?f32 = refresh: {
                    const disp = sdl_win.getDisplayForWindow() catch break :refresh null;
                    const display_mode = disp.getCurrentMode() catch break :refresh null;
                    const value = display_mode.refresh_rate orelse break :refresh null;
                    break :refresh if (value > 0.0) value else null;
                };
                const blit_heap = try gpu.descHeapCreate(8, 0, 1);
                defer gpu.descHeapDestroy(blit_heap);
                gpu.descHeapSetSamplers(blit_heap, 0, &.{blit_sampler});
                break :blk try runPresentedPerf(
                    T,
                    app,
                    root,
                    &resources,
                    config,
                    &recorder,
                    &gw,
                    blit_heap,
                    refresh_hz,
                );
            },
        };
        try writePerfArtifact(T, config, &recorder, metadata, io, gpa);
        return;
    }

    const blit_heap = try gpu.descHeapCreate(8, 0, 1);
    defer gpu.descHeapDestroy(blit_heap);
    gpu.descHeapSetSamplers(blit_heap, 0, &.{blit_sampler});
    const sdl_surface = try sdl3.vulkan.Surface.init(
        sdl_win,
        @ptrFromInt(@intFromEnum(gpu.instanceHandle())),
        null,
    );
    const surface: vk.SurfaceKHR = @enumFromInt(@intFromPtr(sdl_surface.surface));
    var gw = try noapi.Surface.init(&gpu, surface, .{ .extent = .{ .width = 1100, .height = 1160 } });
    defer gw.deinit();
    const win_id = try sdl_win.getId();

    // Frame pacer (Phase 2 — tier-2 frame pacing). The FIFO swapchain is
    // vsync-paced and blocks the CPU on the GPU once the image queue is
    // full; `Surface.slopNs()` reports that per-frame block. The pacer
    // turns it into a sleep BEFORE the input poll so the frame lands just
    // before the vblank instead of blocking after it. The refresh rate is
    // queried once from the window's display (cheap at startup; 0 =
    // unknown → the pacer's safe fallbacks). It is NOT polled per frame —
    // on some platforms that is surprisingly performance intensive.
    const refresh_hz: f32 = blk: {
        const disp = sdl_win.getDisplayForWindow() catch break :blk 0.0;
        const mode = disp.getCurrentMode() catch break :blk 0.0;
        break :blk mode.refresh_rate orelse 0.0;
    };
    var pacer = FramePacer.init(io, refresh_hz);
    var pacer_sleep_ns: u64 = 0;

    // Main loop — the WINDOW DRIVER: translate OS events into core Events
    // (the core never polls input or reads a clock itself), then emit one
    // .frame event per iteration with the driver's tick + clock.
    var tick: u32 = 1;
    // The single window's Surface frame slot advances only after a successful
    // present, matching noapi's command-buffer rotation.
    var frame_index: u32 = 0;
    var last_frame_ms: u64 = 0;
    var perf_frame_count: u32 = 0;
    var should_close = false;
    var remount_smoke_phase: GpuRemountSmokePhase = .initial_visible;
    var remount_smoke_initial_slot: ?u32 = null;

    while (!should_close) {
        // Frame pacer: sleep the recommended delay BEFORE polling input so
        // the frame lands just before the vblank instead of blocking after
        // it (the swapchain FIFO queue full). The sleep is gated — the
        // --frames benchmark measures raw throughput and must NOT be paced;
        // its pacer.update still runs below for the ds/slop telemetry. The
        // ui.frame_pacing toggle (OFF by default) parks the sleep while the
        // cadence verification is blocked by system load.
        if (ui.frame_pacing and max_frames == null and pacer_sleep_ns > 0) {
            pacer.beginSleep(io);
            try Io.sleep(io, Io.Duration.fromNanoseconds(pacer_sleep_ns), .real);
            pacer.endSleep(io);
        }
        // OS events -> core events. Input dispatches against the LAST
        // PRESENTED tree (valid — double-buffered); mutations show up on
        // the next frame.
        while (sdl3.events.poll()) |ev| {
            switch (ev) {
                .quit => should_close = true,
                .window_close_requested => |we| {
                    if (we.id == win_id) should_close = true;
                },
                .window_pixel_size_changed => |we| {
                    if (we.id == win_id) {
                        const pix = try sdl_win.getSizeInPixels();
                        gw.notifyResize(.{ .width = @intCast(pix[0]), .height = @intCast(pix[1]) });
                        const event: Event = .{ .resize = .{
                            .width = @floatFromInt(pix[0]),
                            .height = @floatFromInt(pix[1]),
                        } };
                        dispatchRootEvent(T, root, event);
                        _ = try app.handle(T, root, event);
                    }
                },
                .window_resized => |we| {
                    if (we.id == win_id) {
                        const pix = try sdl_win.getSizeInPixels();
                        gw.notifyResize(.{ .width = @intCast(pix[0]), .height = @intCast(pix[1]) });
                        const event: Event = .{ .resize = .{
                            .width = @floatFromInt(pix[0]),
                            .height = @floatFromInt(pix[1]),
                        } };
                        dispatchRootEvent(T, root, event);
                        _ = try app.handle(T, root, event);
                    }
                },
                .mouse_motion => |mm| {
                    const pos = try toSurfacePoint(sdl_win, &gw, .{ mm.x, mm.y });
                    const event: Event = .{ .mouse_move = .{ .x = pos[0], .y = pos[1] } };
                    dispatchRootEvent(T, root, event);
                    _ = try app.handle(T, root, event);
                },
                .window_mouse_leave => |we| {
                    if (we.id == win_id) {
                        const event: Event = .{ .mouse_leave = {} };
                        dispatchRootEvent(T, root, event);
                        _ = try app.handle(T, root, event);
                    }
                },
                .mouse_button_down => |mb| {
                    const pos = try toSurfacePoint(sdl_win, &gw, .{ mb.x, mb.y });
                    const button: MouseButton = if (mb.button == .left)
                        .left
                    else if (mb.button == .right)
                        .right
                    else
                        .middle;
                    const event: Event = .{ .mouse_down = .{
                        .button = button,
                        .x = pos[0],
                        .y = pos[1],
                    } };
                    dispatchRootEvent(T, root, event);
                    _ = try app.handle(T, root, event);
                },
                .mouse_button_up => |mb| {
                    const pos = try toSurfacePoint(sdl_win, &gw, .{ mb.x, mb.y });
                    const button: MouseButton = if (mb.button == .left)
                        .left
                    else if (mb.button == .right)
                        .right
                    else
                        .middle;
                    const event: Event = .{ .mouse_up = .{
                        .button = button,
                        .x = pos[0],
                        .y = pos[1],
                    } };
                    dispatchRootEvent(T, root, event);
                    _ = try app.handle(T, root, event);
                },
                .mouse_wheel => |mw| {
                    const pos = try toSurfacePoint(sdl_win, &gw, .{ mw.x, mw.y });
                    const event: Event = .{ .mouse_wheel = .{
                        .x = pos[0],
                        .y = pos[1],
                        .delta_x = mw.scroll_x,
                        .delta_y = mw.scroll_y,
                    } };
                    dispatchRootEvent(T, root, event);
                    _ = try app.handle(T, root, event);
                },
                .key_down => |kd| {
                    if (kd.key) |kc| {
                        if (kc == .s) {
                            render_options.subpixel = !render_options.subpixel;
                            gui_renderer.configure(render_options);
                            std.log.info("subpixel AA: {s}", .{if (render_options.subpixel) "on" else "off"});
                            continue;
                        }
                        if (kc == .d) {
                            render_options.quad_debug = !render_options.quad_debug;
                            gui_renderer.configure(render_options);
                            std.log.info("quad debug: {s}", .{if (render_options.quad_debug) "on" else "off"});
                            continue;
                        }
                        if (kc == .a) {
                            // Cycle the stroke algo: 0 = naive SDF, 1 =
                            // marching quads, 2 = the spec'd marching quads.
                            const algo_idx: u32 = @intFromFloat(@min(@max(ui.stroke_algo, 0), 2));
                            ui.stroke_algo = @floatFromInt((algo_idx + 1) % 3);
                            std.log.info("stroke algo: {d} ({s})", .{
                                ui.stroke_algo,
                                switch (@as(u32, @intFromFloat(@min(@max(ui.stroke_algo, 0), 2)))) {
                                    0 => "naive SDF",
                                    1 => "marching quads",
                                    else => "spec'd marching quads",
                                },
                            });
                            continue;
                        }
                        if (kc == .o) {
                            render_options.bgr_order = !render_options.bgr_order;
                            gui_renderer.configure(render_options);
                            std.log.info("subpixel order: {s}", .{if (render_options.bgr_order) "BGR" else "RGB"});
                            continue;
                        }
                        if (kc == .c) {
                            render_options.damp_chroma = !render_options.damp_chroma;
                            gui_renderer.configure(render_options);
                            std.log.info("chroma damping: {s}", .{if (render_options.damp_chroma) "on" else "off"});
                            continue;
                        }
                        if (kc == .p and dispatchRootPrecisionKey(T, root)) continue;
                    }
                    const core_key = mapSdlKey(kd.key orelse continue) orelse continue;
                    const shift = kd.mod.left_shift or kd.mod.right_shift;
                    const event: Event = .{ .key_down = .{ .key = core_key, .shift = shift } };
                    dispatchRootEvent(T, root, event);
                    _ = try app.handle(T, root, event);
                },
                else => {},
            }
        }
        if (should_close) break;
        if (ui.gpu_remount_smoke) {
            const visible = switch (remount_smoke_phase) {
                .initial_visible, .remounted => true,
                .hidden => false,
                .complete => return error.GpuRemountSmokeExtraFrame,
            };
            setGpuRemountSmokeVisibility(T, root, visible);
        }

        // Apply the header pill clicks (the UI sets a request; the window
        // owns the options). Keys and requests use the same configuration
        // path so both routes agree.
        if (ui.toggle_request) |req| {
            switch (req) {
                .subpixel => render_options.subpixel = !render_options.subpixel,
                .bgr => render_options.bgr_order = !render_options.bgr_order,
                .damp => render_options.damp_chroma = !render_options.damp_chroma,
                .debug => render_options.quad_debug = !render_options.quad_debug,
            }
            gui_renderer.configure(render_options);
            ui.toggle_request = null;
        }

        // Sync the toggle state for the UI's header line (the UI cannot
        // import the window; the debug_state lives in text.zig).
        text_mod.debug_state = .{
            .subpixel = render_options.subpixel,
            .bgr = render_options.bgr_order,
            .damp = render_options.damp_chroma,
            .quad_debug = render_options.quad_debug,
        };

        // Frame event: the driver clock is sampled before the Surface frame;
        // the begun frame is then borrowed by App for GPU lifecycle hooks.
        const time_ms: u64 = sdl3.timer.getMillisecondsSinceInit();
        const schedule = gw.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) {
                try Io.sleep(io, Io.Duration.fromMilliseconds(16), .real);
                continue;
            }
            @panic("beginFrame");
        };
        _ = schedule;
        const size = gw.surfaceSize();
        try ensureRenderTarget(&gpu, &render_target, &rt_w, &rt_h, size.width, size.height, blit_heap);
        var cmd = gw.commandsBegin();
        dispatchRootFrame(T, root, time_ms);
        var gpu_frame: nogui.GpuFrame = .{
            .endpoint = &gpu_endpoint,
            .command_buffer = &cmd,
            .extent = size,
            .frame_index = frame_index,
        };
        const out = try app.frameWithGpuAtTime(
            T,
            root,
            tick,
            time_ms,
            .{
                .width = @floatFromInt(size.width),
                .height = @floatFromInt(size.height),
            },
            &gpu_frame,
        );
        if (ui.gpu_remount_smoke) {
            const observed = gpuRemountSmokeObservation(T, root);
            switch (remount_smoke_phase) {
                .initial_visible => {
                    if (!observed.ready) return error.GpuRemountSmokeInitialNotReady;
                    if (observed.init_count != 1) return error.GpuRemountSmokeUnexpectedInitialInit;
                    if (observed.deinit_count != 0) return error.GpuRemountSmokeUnexpectedInitialDeinit;
                    remount_smoke_initial_slot = observed.slot orelse
                        return error.GpuRemountSmokeInitialSlotMissing;
                    remount_smoke_phase = .hidden;
                },
                .hidden => {
                    if (observed.ready) return error.GpuRemountSmokeUnmountStillReady;
                    if (observed.slot != null) return error.GpuRemountSmokeUnmountSlotStillLive;
                    if (observed.deinit_count != 1) return error.GpuRemountSmokeUnmountDidNotDeinit;
                    if (!std.meta.eql(observed.last_unregistered_slot, remount_smoke_initial_slot)) {
                        return error.GpuRemountSmokeUnregisterOrder;
                    }
                    remount_smoke_phase = .remounted;
                },
                .remounted => {
                    if (!observed.ready) return error.GpuRemountSmokeRemountNotReady;
                    if (observed.init_count != 2) return error.GpuRemountSmokeUnexpectedRemountInit;
                    if (observed.deinit_count != 1) return error.GpuRemountSmokeUnexpectedRemountDeinit;
                    const initial_slot = remount_smoke_initial_slot orelse
                        return error.GpuRemountSmokeInitialSlotMissing;
                    const remounted_slot = observed.slot orelse
                        return error.GpuRemountSmokeRemountSlotMissing;
                    if (remounted_slot != initial_slot or
                        !std.meta.eql(observed.last_unregistered_slot, remount_smoke_initial_slot))
                    {
                        return error.GpuRemountSmokeSlotNotReused;
                    }
                    remount_smoke_phase = .complete;
                    std.log.info(
                        "gpu-remount-smoke: Mandelbrot slot {d} reused after one hidden frame",
                        .{remounted_slot},
                    );
                },
                .complete => return error.GpuRemountSmokeExtraFrame,
            }
        }

        if (audio_player) |*player| {
            if (comptime T == spotify_ui.SpotifyApp) {
                const sync_result = player.sync(
                    root.current_track_idx,
                    root.is_playing,
                    root.repeat,
                    root.volume,
                ) catch |err| blk: {
                    std.log.err("audio playback disabled: {s}", .{@errorName(err)});
                    player.deinit();
                    audio_player = null;
                    break :blk .unchanged;
                };

                if (audio_player != null and sync_result == .request_next_track) {
                    root.advancePlaybackAtEnd();
                    if (root.currentTrackIndex()) |next_index| {
                        player.openTrack(next_index, root.is_playing) catch |err| {
                            std.log.err("audio playback disabled: {s}", .{@errorName(err)});
                            player.deinit();
                            audio_player = null;
                        };
                    }
                }

                if (audio_player != null) {
                    const seek_state: AudioSeek = .{
                        .selected_index = root.current_track_idx,
                        .position_sec = root.progress_sec,
                    };
                    const seek_changed = if (audio_seek_sent) |last_seek|
                        last_seek.selected_index != seek_state.selected_index or
                            last_seek.position_sec != seek_state.position_sec
                    else
                        true;
                    if (seek_changed) {
                        player.seek(
                            seek_state.selected_index,
                            seek_state.position_sec,
                        ) catch |err| {
                            std.log.err("audio playback disabled: {s}", .{@errorName(err)});
                            player.deinit();
                            audio_player = null;
                        };
                        if (audio_player != null) audio_seek_sent = seek_state;
                    }
                }
            }
        }
        defer if (out.json) |j| gpa.free(j);

        var slice_rects = std.ArrayList(SceneRect).empty;
        defer slice_rects.deinit(gpa);
        try buildFrameScene(
            gpa,
            &text_engine,
            &svg_view,
            &icon_cache,
            &out,
            &slice_rects,
            gpu_sort_verify,
        );

        // Pass 1: GUI into the offscreen Oklab target.
        cmd.beginZone(.{ .name = "renderPass1_gpu", .src = @src() });
        try recordFrameScene(
            &gui_renderer,
            &cmd,
            slice_rects.items,
            out.tree.clip_rects[0..out.tree.clip_count],
            render_target,
            size,
            tex_registry.heap,
        );
        cmd.endZone();

        // Barrier: render target color output → fragment shader read.
        cmd.barrier(.{ .color_output = true }, .{ .fragment = true }, .{});

        // Pass 2: blit the Oklab target to the swapchain (converts to sRGB).
        cmd.beginZone(.{ .name = "blit_gpu", .src = @src() });
        recordColorConversion(
            &cmd,
            gw.currentImage(),
            size,
            blit_vert,
            blit_frag,
            blit_heap,
        );
        cmd.endZone();

        const frame_result = try gw.endFrame(.{ .blit_to_swapchain = true });
        _ = frame_result;
        frame_index = (frame_index + 1) % @as(u32, gpu.frames_in_flight);

        // Rolling FPS (an EMA over the frame deltas) for the demo header.
        // The unconditional 16ms sleep is GONE — it doubled the vsync pacing
        // and added latency; the swapchain's FIFO/MAILBOX mode paces now.
        const now_ms = sdl3.timer.getMillisecondsSinceInit();
        if (last_frame_ms != 0) {
            const dt_ms: f32 = @floatFromInt(@min(now_ms -| last_frame_ms, 1 << 24));
            const dt: f32 = dt_ms / 1000.0;
            if (dt > 0) ui.fps = ui.fps * 0.9 + (1.0 / dt) * 0.1;
        }
        last_frame_ms = now_ms;
        tick += 1;
        // Mark the frame boundary — without this the tracy profiler thread
        // stays gated on its futex and never processes the connection.
        tracy.frameMark(null);
        // Frame pacer: feed the slop (CPU ns blocked on the GPU this frame)
        // and get the sleep recommendation for the next frame.
        pacer_sleep_ns = pacer.update(io, gw.slopNs());
        if (ui.gpu_remount_smoke and remount_smoke_phase == .complete) break;

        if (perf_config != null) {
            const frame_limit = finite_frames orelse return error.InvalidPerfFrames;
            perf_frame_count += 1;
            if (perf_frame_count >= frame_limit) break;
        } else if (max_frames) |mf| {
            if (tick >= mf) break;
        }
    }
    if (ui.gpu_remount_smoke and remount_smoke_phase != .complete) {
        return error.GpuRemountSmokeInterrupted;
    }

    try gpu.waitIdle();
}

/// Oklab → linear sRGB, ported from shaders/blit_oklab.frag.
fn oklabToLinearSrgb(lab: [3]f32) [3]f32 {
    const l_ = lab[0] + 0.3963377774 * lab[1] + 0.2158037573 * lab[2];
    const m_ = lab[0] - 0.1055613458 * lab[1] - 0.0638541728 * lab[2];
    const s_ = lab[0] - 0.0894841775 * lab[1] - 1.2914855480 * lab[2];
    const lms = [_]f32{ l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_ };
    return .{
        4.0767416621 * lms[0] - 3.3077115913 * lms[1] + 0.2309699292 * lms[2],
        -1.2684380046 * lms[0] + 2.6097574011 * lms[1] - 0.3413193965 * lms[2],
        -0.0041960863 * lms[0] - 0.7034186147 * lms[1] + 1.7076147010 * lms[2],
    };
}

/// Linear sRGB → gamma-encoded 8-bit channel (PPM stores sRGB bytes).
fn linearToSrgbByte(v: f32) u8 {
    const c = std.math.clamp(v, 0.0, 1.0);
    const enc = if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
    const scaled = std.math.clamp(enc, 0.0, 1.0) * 255.0;
    return @intFromFloat(@round(scaled));
}

/// Write a P6 PPM of the offscreen Oklab target's pixels (rgba32_float,
/// tightly packed rows): header + one gamma-encoded sRGB byte per channel.
fn writePpm(gpa: std.mem.Allocator, io: Io, path: []const u8, pixels: [*]const f32, w: u32, h: u32) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(gpa);

    try buf.print(gpa, "P6\n{d} {d}\n255\n", .{ w, h });

    const row = try gpa.alloc(u8, @as(usize, w) * 3);
    defer gpa.free(row);
    const row_px: usize = w;
    for (0..h) |y| {
        for (0..w) |x| {
            const lab = pixels[(y * row_px + x) * 4 ..][0..4];
            const lin = oklabToLinearSrgb(.{ lab[0], lab[1], lab[2] });
            row[x * 3 + 0] = linearToSrgbByte(lin[0]);
            row[x * 3 + 1] = linearToSrgbByte(lin[1]);
            row[x * 3 + 2] = linearToSrgbByte(lin[2]);
        }
        try buf.appendSlice(gpa, row);
    }

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items });
}

/// Render exactly ONE frame into the offscreen Oklab target, copy it back
/// to a readback buffer and write the result as a P6 PPM at `path`. Same
/// init as run(), minus the event loop and the swapchain blit. FreeType
/// glyphs render into the shot — this is the text-renders proof.
const PerfRunMetadata = struct {
    present_feedback: bool,
    refresh_hz: ?f32,
};

fn perfNow(io: Io) Io.Timestamp {
    return Io.Timestamp.now(io, .awake);
}

fn perfElapsed(start: Io.Timestamp, end: Io.Timestamp) perf.RecorderError!u64 {
    const delta = end.toNanoseconds() - start.toNanoseconds();
    if (delta < 0) return error.TimestampUnderflow;
    return std.math.cast(u64, delta) orelse error.TimestampOverflow;
}

fn perfFrameTimeMs(frame_id: u64) perf.RecorderError!u64 {
    const product = @mulWithOverflow(frame_id, @as(u64, 1000));
    if (product[1] != 0) return error.TimestampOverflow;
    return product[0] / 120;
}

fn beginPerfRoot(phase: perf.Phase) tracy.Zone {
    return switch (phase) {
        .warmup => tracy.Zone.begin(.{ .name = "perfWarmupFrame", .src = @src() }),
        .sample => tracy.Zone.begin(.{ .name = "perfSampleFrame", .src = @src() }),
    };
}

fn drainPerfSetupEvents() void {
    while (sdl3.events.poll()) |_| {}
}

fn isPerfEventRejected(name: []const u8) bool {
    const window_event = std.mem.startsWith(u8, name, "window_");
    const display_event = std.mem.startsWith(u8, name, "display_");
    if (display_event) return false;
    return !window_event or
        std.mem.eql(u8, name, "window_resized") or
        std.mem.eql(u8, name, "window_pixel_size_changed") or
        std.mem.eql(u8, name, "window_minimized") or
        std.mem.eql(u8, name, "window_close_requested") or
        std.mem.eql(u8, name, "window_mouse_leave");
}

fn rejectPerfEvents() !void {
    while (sdl3.events.poll()) |event| {
        if (isPerfEventRejected(@tagName(event))) {
            return error.PerfUnexpectedEvent;
        }
    }
}

test "perf event classifier rejects mouse leave input" {
    try std.testing.expect(isPerfEventRejected("mouse_motion"));
    try std.testing.expect(isPerfEventRejected("window_mouse_leave"));
    try std.testing.expect(isPerfEventRejected("window_resized"));
    try std.testing.expect(!isPerfEventRejected("window_focus_gained"));
    try std.testing.expect(!isPerfEventRejected("display_current_mode_changed"));
}
const perf_first_recorded_present_id: u64 = 2;

fn stabilizePerfSurface(
    io: Io,
    surface: *noapi.Surface,
    submitted_gpu_work: *bool,
    start: Io.Timestamp,
) !void {
    while (true) {
        drainPerfSetupEvents();
        const schedule = surface.beginFrame() catch |err| switch (err) {
            error.OutOfDateKHR => {
                if (try perfElapsed(start, perfNow(io)) >= 5_000_000_000) {
                    return error.PerfSurfaceUnstable;
                }
                sdl3.timer.delayMilliseconds(1);
                continue;
            },
            else => return err,
        };
        _ = schedule;
        if (!std.meta.eql(surface.surfaceSize(), perf_extent)) return error.PerfExtentChanged;
        _ = surface.commandsBegin();
        submitted_gpu_work.* = true;
        const frame_result = try surface.endFrame(.{ .blit_to_swapchain = true });
        if (!frame_result.present_out_of_date) {
            drainPerfSetupEvents();
            return;
        }
        if (try perfElapsed(start, perfNow(io)) >= 5_000_000_000) {
            return error.PerfSurfaceUnstable;
        }
        sdl3.timer.delayMilliseconds(1);
    }
}

const PerfPreflightPoll = enum {
    feedback,
    retry,
    unsupported,
    timeout,
};

fn pollPerfPreflightFeedback(
    io: Io,
    surface: *noapi.Surface,
    feedback_buffer: []noapi.PresentFeedback,
    start: Io.Timestamp,
    expected_present_id: u64,
) !PerfPreflightPoll {
    while (true) {
        drainPerfSetupEvents();
        const feedback_count = surface.pollPresentFeedback(feedback_buffer) catch |err| switch (err) {
            error.PresentTimingDataUnavailable => {
                return if (surface.supportsPresentTiming()) .retry else .unsupported;
            },
            else => return err,
        };
        const elapsed = try perfElapsed(start, perfNow(io));
        if (perf.presentPreflightDeadlineExpired(elapsed)) return .timeout;
        if (feedback_count != 0) {
            if (feedback_count != 1 or feedback_buffer[0].present_id != expected_present_id) {
                return error.InvalidPresentationId;
            }
            if (feedback_buffer[0].actual_present_ns == 0) return error.InvalidTimestamp;
            return .feedback;
        }
        sdl3.timer.delayMilliseconds(1);
    }
}

fn preflightPerfPresentation(
    io: Io,
    surface: *noapi.Surface,
    submitted_gpu_work: *bool,
) !?u64 {
    if (!surface.supportsPresentTiming()) return null;
    var preflight_state: perf.PresentPreflightState = .{};
    var mode_start = perfNow(io);
    var feedback_buffer: [64]noapi.PresentFeedback = undefined;
    while (true) {
        if (preflight_state.deadlineExpired(try perfElapsed(mode_start, perfNow(io)))) {
            return error.PerfTimingFeedbackTimeout;
        }
        drainPerfSetupEvents();
        const schedule = surface.beginFrame() catch |err| switch (err) {
            error.OutOfDateKHR => {
                try stabilizePerfSurface(io, surface, submitted_gpu_work, mode_start);
                continue;
            },
            else => return err,
        };
        _ = schedule;
        if (!std.meta.eql(surface.surfaceSize(), perf_extent)) return error.PerfExtentChanged;
        _ = surface.commandsBegin();
        submitted_gpu_work.* = true;
        const timing_id = preflight_state.reservedId();
        const frame_result = surface.endFrame(.{
            .blit_to_swapchain = true,
            .timing_id = timing_id,
        }) catch |err| switch (err) {
            error.OutOfDateKHR => {
                try stabilizePerfSurface(io, surface, submitted_gpu_work, mode_start);
                continue;
            },
            else => return err,
        };
        if (frame_result.present_out_of_date) {
            try stabilizePerfSurface(io, surface, submitted_gpu_work, mode_start);
            continue;
        }

        const feedback_start = perfNow(io);
        switch (try pollPerfPreflightFeedback(
            io,
            surface,
            feedback_buffer[0..],
            feedback_start,
            timing_id,
        )) {
            .feedback => {
                drainPerfSetupEvents();
                return try preflight_state.recordedBase();
            },
            .retry => {
                const fallback_id = (try preflight_state.afterUnavailable(true)) orelse unreachable;
                _ = fallback_id;
                mode_start = perfNow(io);
            },
            .unsupported => {
                drainPerfSetupEvents();
                return null;
            },
            .timeout => return error.PerfTimingFeedbackTimeout,
        }
    }
}

const PerfFeedbackQueue = struct {
    records: [64]noapi.PresentFeedback = undefined,
    count: usize = 0,
    last_observed_id: u64 = 0,

    fn lessThan(_: void, lhs: noapi.PresentFeedback, rhs: noapi.PresentFeedback) bool {
        return lhs.present_id < rhs.present_id;
    }

    fn push(
        self: *PerfFeedbackQueue,
        feedback: []const noapi.PresentFeedback,
        total_frames: u64,
        present_id_base: u64,
    ) perf.RecorderError!void {
        for (feedback) |record| {
            _ = try perf.frameIdForPresentId(record.present_id, present_id_base, total_frames);
            if (record.present_id <= self.last_observed_id) {
                if (record.present_id == self.last_observed_id) {
                    return error.DuplicatePresentationId;
                }
                return error.NonMonotonicPresentationId;
            }
            for (self.records[0..self.count]) |queued| {
                if (queued.present_id == record.present_id) {
                    return error.DuplicatePresentationId;
                }
            }
            if (self.count == self.records.len) return error.TooManySamples;
            self.records[self.count] = record;
            self.count += 1;
            self.last_observed_id = record.present_id;
        }
        std.sort.insertion(noapi.PresentFeedback, self.records[0..self.count], {}, lessThan);
    }

    fn attachReady(
        self: *PerfFeedbackQueue,
        recorder: *perf.Recorder,
        next_frame_id: *u64,
        present_id_base: u64,
    ) perf.RecorderError!void {
        while (self.count > 0) {
            const expected_id = try perf.presentIdForFrame(present_id_base, next_frame_id.*);
            const record = self.records[0];
            if (record.present_id < expected_id) return error.DuplicatePresentationId;
            if (record.present_id > expected_id) break;
            try recorder.attachPresent(next_frame_id.*, record.actual_present_ns);
            next_frame_id.* = try perf.checkedAdd(next_frame_id.*, 1);
            self.count -= 1;
            if (self.count > 0) {
                std.mem.copyForwards(
                    noapi.PresentFeedback,
                    self.records[0..self.count],
                    self.records[1 .. self.count + 1],
                );
            }
        }
    }
};

fn pollPerfPresentFeedback(
    surface: *noapi.Surface,
    feedback_queue: *PerfFeedbackQueue,
    feedback_buffer: []noapi.PresentFeedback,
    recorder: *perf.Recorder,
    total_frames: u64,
    next_present_frame_id: *u64,
    present_id_base: u64,
) !bool {
    const feedback_count = surface.pollPresentFeedback(feedback_buffer) catch |err| switch (err) {
        error.PresentTimingDataUnavailable => {
            if (next_present_frame_id.* != 0 or feedback_queue.count != 0) {
                return error.PartialPresentFeedback;
            }
            if (surface.supportsPresentTiming()) return error.PresentTimingCapabilityChanged;
            return false;
        },
        else => return err,
    };
    if (feedback_count == 0) return true;
    try feedback_queue.push(feedback_buffer[0..feedback_count], total_frames, present_id_base);
    try feedback_queue.attachReady(recorder, next_present_frame_id, present_id_base);
    return true;
}

const PerfMachine = struct {
    cpu_model: []u8 = &.{},
    online_cpu_set: []u8 = &.{},
    requested_affinity: []u32 = &.{},
    process_affinity: []u32 = &.{},
    kernel: []u8 = &.{},
    cpu_governor: ?[]u8 = null,
    gpu: []u8 = &.{},
    driver: []u8 = &.{},

    fn deinit(self: *PerfMachine, gpa: std.mem.Allocator) void {
        if (self.cpu_model.len != 0) gpa.free(self.cpu_model);
        if (self.online_cpu_set.len != 0) gpa.free(self.online_cpu_set);
        if (self.process_affinity.len != 0) gpa.free(self.process_affinity);
        if (self.kernel.len != 0) gpa.free(self.kernel);
        if (self.cpu_governor) |governor| gpa.free(governor);
        if (self.gpu.len != 0) gpa.free(self.gpu);
        if (self.driver.len != 0) gpa.free(self.driver);
        self.* = .{};
    }
};

const PerfReportedRefresh = struct {
    refresh_hz: f32,
};

const PerfRuntimeHeader = struct {
    scene: []const u8,
    mode: []const u8,
    instrumentation_flags: struct {
        tracy: bool,
        gpu_timestamps: bool,
        perf_counters: bool,
    },
    child_argv: []const []const u8,
    cpu_model: []const u8,
    online_cpu_set: []const u8,
    requested_affinity: []const u32,
    process_affinity: []const u32,
    kernel: []const u8,
    cpu_governor: ?[]const u8,
    gpu: []const u8,
    driver: []const u8,
    extent: struct {
        width: u32,
        height: u32,
    },
    present_mode: []const u8,
    reported_refresh_data: ?PerfReportedRefresh,
    present_feedback: bool,
    warmup_frames: u32,
    sample_count: u32,
};

fn readPerfAbsolute(gpa: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    const result = try std.process.run(gpa, io, .{ .argv = &.{ "/run/current-system/sw/bin/cat", path } });
    gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                gpa.free(result.stdout);
                return error.PerfMetadataUnavailable;
            }
        },
        else => {
            gpa.free(result.stdout);
            return error.PerfMetadataUnavailable;
        },
    }
    return result.stdout;
}

fn dupeTrimmed(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return gpa.dupe(u8, std.mem.trim(u8, bytes, " \t\r\n"));
}

fn queryPerfGpu(gpa: std.mem.Allocator, io: Io) !struct { gpu: []u8, driver: []u8 } {
    const result = try std.process.run(gpa, io, .{ .argv = &.{ "/run/current-system/sw/bin/lspci", "-nnk" } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.PerfMetadataUnavailable,
        else => return error.PerfMetadataUnavailable,
    }

    var device: ?[]const u8 = null;
    var driver: ?[]const u8 = null;
    var in_display_device = false;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.indexOf(u8, trimmed, "VGA compatible controller") != null or
            std.mem.indexOf(u8, trimmed, "3D controller") != null)
        {
            device = trimmed;
            in_display_device = true;
            continue;
        }
        if (in_display_device and std.mem.startsWith(u8, trimmed, "Kernel driver in use:")) {
            driver = std.mem.trim(u8, trimmed["Kernel driver in use:".len..], " \t\r");
            break;
        }
        if (trimmed.len != 0 and line.len == trimmed.len) in_display_device = false;
    }
    const gpu_name = try gpa.dupe(u8, device orelse return error.PerfMetadataUnavailable);
    errdefer gpa.free(gpu_name);
    const driver_name = try gpa.dupe(u8, driver orelse return error.PerfMetadataUnavailable);
    return .{ .gpu = gpu_name, .driver = driver_name };
}

fn capturePerfMachine(gpa: std.mem.Allocator, io: Io) !PerfMachine {
    var machine: PerfMachine = .{};
    errdefer machine.deinit(gpa);

    const cpuinfo = try readPerfAbsolute(gpa, io, "/proc/cpuinfo");
    defer gpa.free(cpuinfo);
    const model_marker = "model name";
    const model_start = std.mem.indexOf(u8, cpuinfo, model_marker) orelse
        return error.PerfMetadataUnavailable;
    const model_line_start = model_start + model_marker.len;
    const model_line_end = std.mem.indexOfScalarPos(u8, cpuinfo, model_line_start, '\n') orelse cpuinfo.len;
    const model_line = std.mem.trim(u8, cpuinfo[model_line_start..model_line_end], " \t\r:");
    if (model_line.len == 0) return error.PerfMetadataUnavailable;
    machine.cpu_model = try gpa.dupe(u8, model_line);

    const online = try readPerfAbsolute(gpa, io, "/sys/devices/system/cpu/online");
    defer gpa.free(online);
    machine.online_cpu_set = try dupeTrimmed(gpa, online);

    const cpu_set = try std.posix.sched_getaffinity(0);
    const affinity_count: usize = @intCast(std.posix.CPU_COUNT(cpu_set));
    if (affinity_count == 0) return error.PerfMetadataUnavailable;
    machine.process_affinity = try gpa.alloc(u32, affinity_count);
    var index: usize = 0;
    const word_bits = @bitSizeOf(@TypeOf(cpu_set[0]));
    for (cpu_set, 0..) |word, word_index| {
        var bits = word;
        while (bits != 0) {
            const bit: usize = @intCast(@ctz(bits));
            machine.process_affinity[index] = @intCast(word_index * word_bits + bit);
            index += 1;
            bits &= bits - 1;
        }
    }
    if (index != affinity_count) return error.PerfMetadataUnavailable;
    machine.requested_affinity = machine.process_affinity;

    const uts = std.posix.uname();
    machine.kernel = try gpa.dupe(u8, std.mem.sliceTo(&uts.release, 0));
    machine.cpu_governor = if (readPerfAbsolute(gpa, io, "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")) |governor| blk: {
        defer gpa.free(governor);
        break :blk try dupeTrimmed(gpa, governor);
    } else |_| null;
    const gpu = try queryPerfGpu(gpa, io);
    machine.gpu = gpu.gpu;
    machine.driver = gpu.driver;
    return machine;
}

fn perfSceneName(comptime T: type) []const u8 {
    if (comptime T == spotify_ui.SpotifyApp) return "spotify";
    if (comptime T == calculator_ui.CalculatorApp) return "calculator";
    if (comptime T == ui.TigerApp) return "tiger";
    if (comptime T == ui.TestStrokesApp) return "strokes";
    return "todo";
}

fn writePerfArtifact(
    comptime T: type,
    config: perf.Config,
    recorder: *const perf.Recorder,
    metadata: PerfRunMetadata,
    io: Io,
    gpa: std.mem.Allocator,
) !void {
    var machine = try capturePerfMachine(gpa, io);
    defer machine.deinit(gpa);
    const executable = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(executable);
    var warmup_buffer: [32]u8 = undefined;
    var sample_buffer: [32]u8 = undefined;
    const warmup_text = std.fmt.bufPrint(&warmup_buffer, "{d}", .{config.warmup_frames}) catch unreachable;
    const sample_text = std.fmt.bufPrint(&sample_buffer, "{d}", .{config.sample_frames}) catch unreachable;
    var child_argv_storage: [11][]const u8 = undefined;
    var child_argc: usize = 0;
    child_argv_storage[child_argc] = executable;
    child_argc += 1;
    const scene = perfSceneName(T);
    if (!std.mem.eql(u8, scene, "todo")) {
        child_argv_storage[child_argc] =
            if (std.mem.eql(u8, scene, "spotify"))
                "--spotify"
            else if (std.mem.eql(u8, scene, "calculator"))
                "--calculator"
            else if (std.mem.eql(u8, scene, "tiger"))
                "--tiger"
            else if (std.mem.eql(u8, scene, "strokes"))
                "--strokes"
            else
                unreachable;
        child_argc += 1;
    }
    child_argv_storage[child_argc] = "--perf-mode";
    child_argc += 1;
    child_argv_storage[child_argc] = if (config.mode == .offscreen) "offscreen" else "presented";
    child_argc += 1;
    child_argv_storage[child_argc] = "--perf-warmup";
    child_argc += 1;
    child_argv_storage[child_argc] = warmup_text;
    child_argc += 1;
    child_argv_storage[child_argc] = "--perf-frames";
    child_argc += 1;
    child_argv_storage[child_argc] = sample_text;
    child_argc += 1;
    child_argv_storage[child_argc] = "--perf-out";
    child_argc += 1;
    child_argv_storage[child_argc] = config.output_path;
    child_argc += 1;

    const header: PerfRuntimeHeader = .{
        .scene = scene,
        .mode = if (config.mode == .offscreen) "offscreen" else "presented",
        .instrumentation_flags = .{
            .tracy = tracy.enabled,
            .gpu_timestamps = v7_options.gpu_timestamps,
            .perf_counters = v7_options.perf_counters,
        },
        .child_argv = child_argv_storage[0..child_argc],
        .cpu_model = machine.cpu_model,
        .online_cpu_set = machine.online_cpu_set,
        .requested_affinity = machine.requested_affinity,
        .process_affinity = machine.process_affinity,
        .kernel = machine.kernel,
        .cpu_governor = machine.cpu_governor,
        .gpu = machine.gpu,
        .driver = machine.driver,
        .extent = .{ .width = perf_width, .height = perf_height },
        .present_mode = "fifo",
        .reported_refresh_data = if (metadata.refresh_hz) |refresh_hz|
            .{ .refresh_hz = refresh_hz }
        else
            null,
        .present_feedback = metadata.present_feedback,
        .warmup_frames = config.warmup_frames,
        .sample_count = config.sample_frames,
    };

    var file = try Io.Dir.cwd().createFile(io, config.output_path, .{ .truncate = true });
    defer file.close(io);
    var backing: [16 * 1024]u8 = undefined;
    var writer = file.writer(io, &backing);
    try std.json.Stringify.value(header, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try recorder.writeJsonl(&writer.interface);
    try writer.interface.flush();
}

const PerfAppFrame = struct {
    out: nogui.FrameOutput,
};

fn buildPerfAppFrame(
    comptime T: type,
    app: *App,
    root: *T,
    resources: *const PerfResources,
    cmd: *noapi.CommandBuffer,
    frame_id: u64,
) !PerfAppFrame {
    ui.fps = 120.0;
    const time_ms = try perfFrameTimeMs(frame_id);
    dispatchRootFrame(T, root, time_ms);
    var gpu_frame: nogui.GpuFrame = .{
        .endpoint = resources.gpu_endpoint,
        .command_buffer = cmd,
        .extent = perf_extent,
        .frame_index = @intCast(frame_id % 3),
    };
    const out = try app.frameWithGpuAtTime(
        T,
        root,
        @intCast(frame_id + 1),
        time_ms,
        .{ .width = @floatFromInt(perf_width), .height = @floatFromInt(perf_height) },
        &gpu_frame,
    );
    return .{ .out = out };
}

fn buildPerfScene(
    resources: *const PerfResources,
    out: *const nogui.FrameOutput,
    rects: *std.ArrayList(SceneRect),
    draw_cmds: *std.ArrayList(DrawCmd),
    gpu_sort_verify: bool,
) !void {
    rects.clearRetainingCapacity();
    try buildFrameSceneInto(
        resources.gpa,
        resources.text_engine,
        resources.svg_view,
        resources.icon_cache,
        out,
        rects,
        draw_cmds,
        gpu_sort_verify,
    );
}

fn attachGpuQueries(
    gpu: *noapi.Gpu,
    query_set: noapi.TimestampQuerySet,
    recorder: *perf.Recorder,
    frame_id: u64,
) !void {
    if (comptime v7_options.gpu_timestamps) {
        const timestamp_info = gpu.timestampInfo() orelse return error.GpuTimestampUnavailable;
        var timestamps: [2]u64 = undefined;
        const first: u32 = @intCast((frame_id % 3) * 2);
        try gpu.timestampQuerySetRead(query_set, first, &timestamps);
        try recorder.attachGpu(
            frame_id,
            timestamps[0],
            timestamps[1],
            timestamp_info.period_ns,
            timestamp_info.valid_bits,
        );
    }
}

fn waitPerfTimelineOrPanic(gpu: *noapi.Gpu, timeline: noapi.Semaphore, value: u64) void {
    gpu.semaphoreWait(timeline, value) catch |err| {
        std.debug.panic("perf resource cleanup could not wait for timeline: {s}", .{@errorName(err)});
    };
}

fn runOffscreenPerf(
    comptime T: type,
    app: *App,
    root: *T,
    resources: *const PerfResources,
    config: perf.Config,
    recorder: *perf.Recorder,
) !PerfRunMetadata {
    const total_frames = try config.totalFrames();
    recorder.mode = .offscreen;
    recorder.presentation_timing_supported = false;
    var slots = try OffscreenSlots.init(resources.gpu, resources.blit_sampler);
    var highest_submitted_timeline: u64 = 0;
    var timeline_waited = false;
    defer {
        if (highest_submitted_timeline != 0 and !timeline_waited) {
            waitPerfTimelineOrPanic(resources.gpu, slots.timeline, highest_submitted_timeline);
        }
        slots.deinit();
    }
    var queue: noapi.Queue = .{ .gpu = resources.gpu };
    var query_slots: perf.QuerySlotScheduler = .{};
    var scene_rects = std.ArrayList(SceneRect).empty;
    defer scene_rects.deinit(resources.gpa);
    var draw_cmds: std.ArrayList(DrawCmd) = .empty;
    defer draw_cmds.deinit(resources.gpa);
    try draw_cmds.ensureTotalCapacity(resources.gpa, perf_draw_cmd_capacity);

    drainPerfSetupEvents();
    var frame_id: u64 = 0;
    while (frame_id < total_frames) : (frame_id += 1) {
        try rejectPerfEvents();
        const phase: perf.Phase = if (frame_id < config.warmup_frames) .warmup else .sample;
        var root_zone = beginPerfRoot(phase);
        defer root_zone.end();

        const slot: usize = @intCast(frame_id % OffscreenSlots.count);
        var slot_waited = false;
        var slot_wait_start: Io.Timestamp = undefined;
        var app_start: Io.Timestamp = undefined;
        if (perf.slotWaitValue(frame_id, OffscreenSlots.count)) |wait_value| {
            slot_wait_start = perfNow(resources.io);
            try resources.gpu.semaphoreWait(slots.timeline, wait_value);
            app_start = perfNow(resources.io);
            slot_waited = true;
        } else {
            app_start = perfNow(resources.io);
        }
        if (comptime v7_options.gpu_timestamps) {
            if (try query_slots.begin(frame_id)) |completed_frame| {
                const query_set = slots.timestamp_queries orelse return error.GpuTimestampUnavailable;
                try attachGpuQueries(resources.gpu, query_set, recorder, completed_frame);
            }
        }
        var cmd = try resources.gpu.commandsBegin();
        if (comptime v7_options.gpu_timestamps) {
            const query_set = slots.timestamp_queries orelse return error.GpuTimestampUnavailable;
            const first: u32 = @intCast(slot * 2);
            try cmd.timestampReset(query_set, first, 2);
            try cmd.timestampWrite(query_set, first, .all_commands_start);
        }
        var app_frame = try buildPerfAppFrame(T, app, root, resources, &cmd, frame_id);
        defer if (app_frame.out.json) |json| resources.gpa.free(json);
        const scene_start = perfNow(resources.io);
        try buildPerfScene(resources, &app_frame.out, &scene_rects, &draw_cmds, false);
        const record_start = perfNow(resources.io);
        try recordFrameScene(
            resources.gui_renderer,
            &cmd,
            scene_rects.items,
            app_frame.out.tree.clip_rects[0..app_frame.out.tree.clip_count],
            slots.oklab_targets[slot],
            perf_extent,
            resources.tex_registry.heap,
        );
        cmd.barrier(.{ .color_output = true }, .{ .fragment = true }, .{});
        recordColorConversion(
            &cmd,
            slots.srgb_targets[slot],
            perf_extent,
            resources.blit_vert,
            resources.blit_frag,
            slots.blit_heaps[slot],
        );
        if (comptime v7_options.gpu_timestamps) {
            const query_set = slots.timestamp_queries orelse return error.GpuTimestampUnavailable;
            const first: u32 = @intCast(slot * 2);
            try cmd.timestampWrite(query_set, first + 1, .all_commands_end);
            try query_slots.submitted(frame_id);
        }
        const submit_start = perfNow(resources.io);
        try queue.submitSignal(&.{cmd}, slots.timeline, frame_id + 1);
        const submit_end = perfNow(resources.io);
        highest_submitted_timeline = frame_id + 1;

        var sample = perf.FrameSample.empty(phase, frame_id);
        sample.cpu_app_layout_ns = try perfElapsed(app_start, scene_start);
        sample.cpu_scene_ns = try perfElapsed(scene_start, record_start);
        sample.cpu_record_ns = try perfElapsed(record_start, submit_start);
        sample.cpu_submit_present_ns = try perfElapsed(submit_start, submit_end);
        const slot_wait_ns = if (slot_waited) try perfElapsed(slot_wait_start, app_start) else 0;
        sample.cpu_slot_wait_ns = slot_wait_ns;
        sample.slop_ns = slot_wait_ns;
        sample.cpu_compute_ns = try perf.computeNs(&sample);
        try recorder.append(sample);
        tracy.frameMark(null);
    }

    try resources.gpu.semaphoreWait(slots.timeline, total_frames);
    timeline_waited = true;
    if (comptime v7_options.gpu_timestamps) {
        while (recorder.next_gpu_frame_id < @as(u64, total_frames)) {
            const frame = recorder.next_gpu_frame_id;
            const query_set = slots.timestamp_queries orelse return error.GpuTimestampUnavailable;
            try attachGpuQueries(resources.gpu, query_set, recorder, frame);
        }
    }
    return .{ .present_feedback = false, .refresh_hz = null };
}

fn runPresentedPerf(
    comptime T: type,
    app: *App,
    root: *T,
    resources: *const PerfResources,
    config: perf.Config,
    recorder: *perf.Recorder,
    gw: *noapi.Surface,
    blit_heap: noapi.DescriptorHeap,
    refresh_hz: ?f32,
) !PerfRunMetadata {
    const total_frames = try config.totalFrames();
    if (!std.meta.eql(gw.surfaceSize(), perf_extent)) return error.PerfExtentChanged;
    var render_target: noapi.TextureHandle = .{};
    var render_target_width: u32 = 0;
    var render_target_height: u32 = 0;
    var timestamp_queries: ?noapi.TimestampQuerySet = null;
    var submitted_gpu_work = false;
    var gpu_work_waited = false;
    defer {
        if (submitted_gpu_work and !gpu_work_waited) {
            resources.gpu.waitIdle() catch |err| {
                std.debug.panic("perf resource cleanup could not wait for GPU: {s}", .{@errorName(err)});
            };
        }
        if (timestamp_queries) |queries| resources.gpu.timestampQuerySetDestroy(queries);
        if (render_target.texture.id != 0) resources.gpu.textureDestroy(render_target);
    }
    drainPerfSetupEvents();
    sdl3.timer.delayMilliseconds(10);
    try stabilizePerfSurface(resources.io, gw, &submitted_gpu_work, perfNow(resources.io));
    var present_id_base = perf_first_recorded_present_id;
    const preflight_base = try preflightPerfPresentation(resources.io, gw, &submitted_gpu_work);
    var present_feedback_live = false;
    if (preflight_base) |base| {
        present_id_base = base;
        present_feedback_live = true;
    }
    if (!present_feedback_live) {
        try stabilizePerfSurface(resources.io, gw, &submitted_gpu_work, perfNow(resources.io));
    }

    recorder.mode = .presented;
    recorder.presentation_timing_supported = present_feedback_live;
    try ensureRenderTarget(
        resources.gpu,
        &render_target,
        &render_target_width,
        &render_target_height,
        perf_width,
        perf_height,
        blit_heap,
    );
    if (comptime v7_options.gpu_timestamps) {
        timestamp_queries = try resources.gpu.timestampQuerySetCreate(OffscreenSlots.query_count);
    }

    var scene_rects = std.ArrayList(SceneRect).empty;
    defer scene_rects.deinit(resources.gpa);
    var draw_cmds: std.ArrayList(DrawCmd) = .empty;
    defer draw_cmds.deinit(resources.gpa);
    try draw_cmds.ensureTotalCapacity(resources.gpa, perf_draw_cmd_capacity);
    var query_slots: perf.QuerySlotScheduler = .{};
    var feedback_queue = PerfFeedbackQueue{};
    var feedback_buffer: [64]noapi.PresentFeedback = undefined;
    var next_present_frame_id: u64 = 0;
    var frame_id: u64 = 0;
    while (frame_id < total_frames) : (frame_id += 1) {
        if (frame_id == 0) {
            drainPerfSetupEvents();
        } else {
            try rejectPerfEvents();
        }
        const phase: perf.Phase = if (frame_id < config.warmup_frames) .warmup else .sample;
        var root_zone = beginPerfRoot(phase);
        defer root_zone.end();

        const acquire_start = perfNow(resources.io);
        _ = try gw.beginFrame();
        if (!std.meta.eql(gw.surfaceSize(), perf_extent)) return error.PerfExtentChanged;
        const app_start = perfNow(resources.io);
        if (comptime v7_options.gpu_timestamps) {
            if (try query_slots.begin(frame_id)) |completed_frame| {
                const query_set = timestamp_queries orelse return error.GpuTimestampUnavailable;
                try attachGpuQueries(resources.gpu, query_set, recorder, completed_frame);
            }
        }
        var cmd = gw.commandsBegin();
        if (comptime v7_options.gpu_timestamps) {
            const query_set = timestamp_queries orelse return error.GpuTimestampUnavailable;
            const first: u32 = @intCast((frame_id % 3) * 2);
            try cmd.timestampReset(query_set, first, 2);
            try cmd.timestampWrite(query_set, first, .all_commands_start);
        }
        var app_frame = try buildPerfAppFrame(T, app, root, resources, &cmd, frame_id);
        defer if (app_frame.out.json) |json| resources.gpa.free(json);
        const scene_start = perfNow(resources.io);
        try buildPerfScene(resources, &app_frame.out, &scene_rects, &draw_cmds, false);
        const record_start = perfNow(resources.io);
        try recordFrameScene(
            resources.gui_renderer,
            &cmd,
            scene_rects.items,
            app_frame.out.tree.clip_rects[0..app_frame.out.tree.clip_count],
            render_target,
            perf_extent,
            resources.tex_registry.heap,
        );
        cmd.barrier(.{ .color_output = true }, .{ .fragment = true }, .{});
        recordColorConversion(
            &cmd,
            gw.currentImage(),
            perf_extent,
            resources.blit_vert,
            resources.blit_frag,
            blit_heap,
        );
        if (comptime v7_options.gpu_timestamps) {
            const query_set = timestamp_queries orelse return error.GpuTimestampUnavailable;
            const first: u32 = @intCast((frame_id % 3) * 2);
            try cmd.timestampWrite(query_set, first + 1, .all_commands_end);
            try query_slots.submitted(frame_id);
        }
        const submit_start = perfNow(resources.io);
        const slop_before = gw.slopNs();
        submitted_gpu_work = true;
        const frame_result = try gw.endFrame(.{
            .blit_to_swapchain = true,
            .timing_id = if (present_feedback_live)
                try perf.presentIdForFrame(present_id_base, frame_id)
            else
                null,
        });
        const slop_after = gw.slopNs();
        const submit_end = perfNow(resources.io);
        if (frame_result.present_out_of_date) return error.OutOfDateKHR;

        const acquire_ns = try perfElapsed(acquire_start, app_start);
        const app_layout_ns = try perfElapsed(app_start, scene_start);
        const scene_ns = try perfElapsed(scene_start, record_start);
        const record_ns = try perfElapsed(record_start, submit_start);
        const submit_ns = try perfElapsed(submit_start, submit_end);
        const present_slop_ns = try perf.presentSlopNs(slop_before, slop_after, submit_ns);

        var sample = perf.FrameSample.empty(phase, frame_id);
        sample.cpu_acquire_ns = acquire_ns;
        sample.cpu_app_layout_ns = app_layout_ns;
        sample.cpu_scene_ns = scene_ns;
        sample.cpu_record_ns = record_ns;
        sample.cpu_submit_present_ns = submit_ns;
        sample.cpu_present_slop_ns = present_slop_ns;
        sample.slop_ns = slop_after;
        sample.cpu_compute_ns = try perf.computeNs(&sample);
        try recorder.append(sample);

        if (present_feedback_live) {
            if (!try pollPerfPresentFeedback(
                gw,
                &feedback_queue,
                feedback_buffer[0..],
                recorder,
                total_frames,
                &next_present_frame_id,
                present_id_base,
            )) {
                present_feedback_live = false;
            }
        }
        tracy.frameMark(null);
    }

    if (present_feedback_live) {
        const drain_start = perfNow(resources.io);
        while (next_present_frame_id < @as(u64, total_frames)) {
            try rejectPerfEvents();
            if (!try pollPerfPresentFeedback(
                gw,
                &feedback_queue,
                feedback_buffer[0..],
                recorder,
                total_frames,
                &next_present_frame_id,
                present_id_base,
            )) {
                present_feedback_live = false;
                break;
            }
            if (try perfElapsed(drain_start, perfNow(resources.io)) >= 5_000_000_000) {
                return error.MissingFrameMetric;
            }
            sdl3.timer.delayMilliseconds(1);
        }
    }
    if (!present_feedback_live) {
        try recorder.markPresentTimingUnavailable();
    } else if (feedback_queue.count != 0) {
        return error.MissingFrameMetric;
    }

    if (submitted_gpu_work) {
        try resources.gpu.waitIdle();
        gpu_work_waited = true;
    }
    if (comptime v7_options.gpu_timestamps) {
        const query_set = timestamp_queries orelse return error.GpuTimestampUnavailable;
        while (recorder.next_gpu_frame_id < @as(u64, total_frames)) {
            try attachGpuQueries(resources.gpu, query_set, recorder, recorder.next_gpu_frame_id);
        }
    }
    return .{ .present_feedback = recorder.presentation_timing_supported, .refresh_hz = refresh_hz };
}

pub fn runShot(
    comptime T: type,
    app: *App,
    root: *T,
    path: []const u8,
    hover: ?[2]f32,
    subpixel: bool,
    quad_debug: bool,
    bgr: bool,
    damp: bool,
    gpu_sort_verify: bool,
) !void {
    const gpa = app.gpa;

    // OVERRIDE priority: the SDL gives env vars precedence over
    // default-priority hints, so a session-set SDL_VIDEODRIVER makes
    // plain hints.set fail with "An environment variable is taking
    // priority". The demo REQUIRES the wayland + vulkan drivers; its
    // choice must win.
    try sdl3.hints.setWithPriority(.video_driver, "wayland", .override);
    try sdl3.hints.setWithPriority(.render_driver, "vulkan", .override);
    try sdl3.init(.{ .video = true, .events = true });
    defer sdl3.quit(.{ .video = true, .events = true });
    const sdl_win = try sdl3.video.Window.init("nogui v7 demo", 1100, 1160, .{ .resizable = true });
    defer sdl_win.deinit();
    try sdl_win.show();

    try sdl3.vulkan.loadLibrary(null);
    const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();
    const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
    exts_copy_global = try gpa.dupe([*:0]const u8, sdl_exts);
    defer gpa.free(exts_copy_global);

    var io_impl = std.Io.Threaded.init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var quad_vert_f = try ShaderFile.load(gpa, io, "shaders/quad_vert.spv");
    defer quad_vert_f.deinit(gpa);
    var quad_frag_f = try ShaderFile.load(gpa, io, "shaders/quad_frag.spv");
    defer quad_frag_f.deinit(gpa);
    var sort_comp_f = try ShaderFile.load(gpa, io, "shaders/sort_comp.spv");
    defer sort_comp_f.deinit(gpa);
    var fullscreen_vert_f = try ShaderFile.load(gpa, io, "shaders/fullscreen_vert.spv");
    defer fullscreen_vert_f.deinit(gpa);
    var blit_oklab_f = try ShaderFile.load(gpa, io, "shaders/blit_oklab.spv");
    defer blit_oklab_f.deinit(gpa);

    var gpu = try noapi.Gpu.init(.{
        .frames_in_flight = 3,
        .app_name = "v7-demo",
        .validation = false,
        .loader = .{
            .get_instance_proc_addr = @ptrCast(get_proc_addr),
            .get_instance_extensions = &getExts,
        },
        .io = io,
    });
    defer gpu.deinit();

    const sdl_surface = try sdl3.vulkan.Surface.init(sdl_win, @ptrFromInt(@intFromEnum(gpu.instanceHandle())), null);
    const surface: vk.SurfaceKHR = @enumFromInt(@intFromPtr(sdl_surface.surface));
    var gw = try noapi.Surface.init(&gpu, surface, .{ .extent = .{ .width = 1100, .height = 1160 } });
    defer gw.deinit();

    // Text engine owns FreeType, per-size font states, and the glyph
    // material buffer. Renderer owns the quad shaders and draw buffers.
    var text_engine = try TextEngine.init(gpa, &gpu);
    defer text_engine.deinit();
    TextEngine.measure_engine = &text_engine;
    app.measure = TextEngine.measureForFlex;
    var gui_renderer = try Renderer.init(&gpu, quad_vert_f.spv, quad_frag_f.spv, sort_comp_f.spv);
    defer gui_renderer.deinit();
    const render_options: RenderOptions = .{
        .material_bda = text_engine.materialBda(),
        .subpixel = subpixel,
        .quad_debug = quad_debug,
        .bgr_order = bgr,
        .damp_chroma = damp,
    };
    gui_renderer.configure(render_options);

    // GUI texture heap + registry + the demo's procedural texture — the
    // shot renders it like run() (the texture card is part of the frame).
    var tex_registry = try TextureRegistry.init(gpa, &gpu);
    defer tex_registry.deinit(gpa);
    ui.texture_idx = try uploadDemoTexture(gpa, &gpu, &tex_registry);
    try uploadReferenceTexture(gpa, &gpu, &tex_registry);

    // The stroke test scene (the TestStrokesApp root) loads the curved
    // thin-stroke set; everything else loads the tiger.
    var svg_view = if (comptime T == ui.TestStrokesApp)
        try initStrokeView(gpa, &gpu, &text_engine)
    else
        try initSvgView(gpa, &gpu, &text_engine);
    defer svg_view.deinit(&gpu);
    // Transport icons share TextEngine's material buffer but are initialized
    // for the one-shot frame so icon-only controls render their cached paths.
    var icon_cache = try IconCache.init(gpa, &gpu, &text_engine);
    defer icon_cache.deinit(&gpu);

    const blit_vert = try gpu.shaderCreate(fullscreen_vert_f.spv, .vertex, "main", "fullscreen_vert");
    defer gpu.shaderDestroy(blit_vert);
    const blit_frag = try gpu.shaderCreate(blit_oklab_f.spv, .fragment, "main", "blit_oklab");
    defer gpu.shaderDestroy(blit_frag);
    const blit_heap = try gpu.descHeapCreate(8, 0, 1);
    defer gpu.descHeapDestroy(blit_heap);
    const blit_sampler = gpu.samplerDescriptor(.{
        .min_filter = .nearest,
        .mag_filter = .nearest,
        .mip_filter = .nearest,
    });
    gpu.descHeapSetSamplers(blit_heap, 0, &.{blit_sampler});

    var render_target: noapi.TextureHandle = .{};
    var rt_w: u32 = 0;
    var rt_h: u32 = 0;
    defer if (render_target.texture.id != 0) gpu.textureDestroy(render_target);
    configureGpuComponents(T, root, tex_registry.heap);
    var gpu_texture_runtime: nogui.TextureRegistry = .{
        .ptr = &tex_registry,
        .register = registerRuntimeTexture,
        .unregister = unregisterRuntimeTexture,
    };
    var gpu_endpoint: nogui.GpuEndpoint = .{
        .gpu = &gpu,
        .textures = &gpu_texture_runtime,
    };
    try app.attachGpu(&gpu_endpoint);
    defer app.detachGpu();

    // Sync the toggle state BEFORE the frame builds the tree: the shot's
    // header status line reads debug_state, so a late sync would stamp the
    // PREVIOUS frame's toggles onto this shot. Same order as run()'s loop.
    text_mod.debug_state = .{
        .subpixel = render_options.subpixel,
        .bgr = render_options.bgr_order,
        .damp = render_options.damp_chroma,
        .quad_debug = render_options.quad_debug,
    };

    // One frame: fresh tree + layout at the fixed window size.
    const surface_size = gw.surfaceSize();
    try ensureRenderTarget(&gpu, &render_target, &rt_w, &rt_h, surface_size.width, surface_size.height, blit_heap);
    var cmd = try gpu.commandsBegin();
    var gpu_frame: nogui.GpuFrame = .{
        .endpoint = &gpu_endpoint,
        .command_buffer = &cmd,
        .extent = surface_size,
        .frame_index = 0,
    };
    dispatchRootFrame(T, root, 1200);
    var out = try app.frameWithGpuAtTime(
        T,
        root,
        1,
        1200,
        .{
            .width = @floatFromInt(surface_size.width),
            .height = @floatFromInt(surface_size.height),
        },
        &gpu_frame,
    );
    defer if (out.json) |j| gpa.free(j);

    // Static shot: the hover ring renders at full alpha when a node is
    // hovered (no easing in a one-frame shot); 0 otherwise.
    out.pressed = null;
    out.press_alpha = 0;
    out.hover = if (hover) |p| hitTest(out.tree, p) else null;
    out.hover_alpha = if (out.hover != null) 1 else 0;
    out.focus = null;

    var slice_rects = std.ArrayList(SceneRect).empty;
    defer slice_rects.deinit(gpa);
    try buildFrameScene(
        gpa,
        &text_engine,
        &svg_view,
        &icon_cache,
        &out,
        &slice_rects,
        gpu_sort_verify,
    );

    // Readback buffer: one rgba32_float pixel per screen pixel.
    const pixel_bytes: u64 = @as(u64, surface_size.width) * surface_size.height * 4 * @sizeOf(f32);
    const readback = try gpu.gpuMalloc(pixel_bytes, 64, .readback);
    defer gpu.gpuFree(readback);

    try recordFrameScene(
        &gui_renderer,
        &cmd,
        slice_rects.items,
        out.tree.clip_rects[0..out.tree.clip_count],
        render_target,
        surface_size,
        tex_registry.heap,
    );
    cmd.barrier(.{ .color_output = true }, .{ .transfer = true }, .{});

    const tex: noapi.Texture = .{
        .gpu = &gpu,
        .handle = render_target,
        .dimensions = .{ surface_size.width, surface_size.height, 1 },
        .format = .rgba32_float,
    };
    cmd.copyFromTexture(tex, readback, .{
        .size = .{ surface_size.width, surface_size.height, 1 },
    });

    try gpu.queueSubmit(&.{cmd});
    try gpu.waitIdle();

    // --gpu-sort-verify: the REVERSED bag must produce the paint-order
    // permutation. Read the sort's output back and check it against a
    // CPU-side stable (z, order) reference — the assertion the flag is
    // about (the runShot itself is the pixel-level check).
    if (gpu_sort_verify) {
        const n = slice_rects.items.len;
        const perm_rb = try gpu.gpuMalloc(@as(u64, n) * @sizeOf(u32), 64, .readback);
        defer gpu.gpuFree(perm_rb);
        var cmd2 = try gpu.commandsBegin();
        cmd2.memCopy(perm_rb, gui_renderer.permutationBuffer(), @as(u64, n) * @sizeOf(u32));
        try gpu.queueSubmit(&.{cmd2});
        try gpu.waitIdle();
        const got: [*]const u32 = @ptrCast(@alignCast(perm_rb.cpu));
        const RectSort = struct {
            const Self = @This();

            rects: []const SceneRect,
            fn lessThan(ctx: Self, a: u32, b: u32) bool {
                const ra = ctx.rects[a];
                const rb = ctx.rects[b];
                if (ra.z != rb.z) return ra.z < rb.z;
                return ra.order < rb.order;
            }
        };
        var ref = try gpa.alloc(u32, n);
        defer gpa.free(ref);
        for (0..n) |i| ref[i] = @intCast(i);
        std.sort.insertion(u32, ref, RectSort{ .rects = slice_rects.items }, RectSort.lessThan);
        var bad: ?usize = null;
        for (ref, 0..) |want, i| {
            if (got[i] != want) {
                bad = i;
                break;
            }
        }
        if (bad) |i| {
            std.log.err(
                "gpu-sort-verify FAILED: perm[{d}] = {d}, want {d} (z={d} order={d})",
                .{ i, got[i], ref[i], slice_rects.items[ref[i]].z, slice_rects.items[ref[i]].order },
            );
            return error.GpuSortVerifyMismatch;
        }
        std.log.info("gpu-sort-verify: permutation matches the stable (z, order) reference ({d} drawables)", .{n});
    }

    // Convert Oklab floats → sRGB bytes and write the PPM.
    const pixels: [*]const f32 = @ptrCast(@alignCast(readback.cpu));
    try writePpm(gpa, io, path, pixels, surface_size.width, surface_size.height);
}

test "perf slot run options accept only fixed render defaults" {
    const config: perf.Config = .{
        .mode = .offscreen,
        .warmup_frames = 1,
        .sample_frames = 1,
        .output_path = "/tmp/nogui-perf.jsonl",
    };
    _ = try (RunOptions{ .perf = config }).validate();
    try std.testing.expectError(
        error.PerfOptionConflict,
        (RunOptions{ .subpixel = true, .perf = config }).validate(),
    );
    try std.testing.expectError(
        error.PerfOptionConflict,
        (RunOptions{ .quad_debug = true, .perf = config }).validate(),
    );
    try std.testing.expectError(
        error.PerfOptionConflict,
        (RunOptions{ .bgr_order = true, .perf = config }).validate(),
    );
    try std.testing.expectError(
        error.PerfOptionConflict,
        (RunOptions{ .damp_chroma = false, .perf = config }).validate(),
    );
    try std.testing.expectError(
        error.PerfOptionConflict,
        (RunOptions{ .gpu_sort_verify = true, .perf = config }).validate(),
    );
    try std.testing.expectError(
        error.PerfOptionConflict,
        (RunOptions{ .max_frames = 1, .perf = config }).validate(),
    );
    try std.testing.expectError(
        error.PerfOptionConflict,
        (RunOptions{ .audio_tracks = &.{}, .perf = config }).validate(),
    );
}

test "perf feedback queue reserves preflight ID and preserves gaps" {
    var queue = PerfFeedbackQueue{};
    const preflight = [_]noapi.PresentFeedback{
        .{ .present_id = 1, .actual_present_ns = 10 },
    };
    try std.testing.expectError(error.InvalidPresentationId, queue.push(preflight[0..], 2, 2));
    try std.testing.expectEqual(@as(usize, 0), queue.count);

    const gap = [_]noapi.PresentFeedback{
        .{ .present_id = 3, .actual_present_ns = 30 },
    };
    try queue.push(gap[0..], 2, 2);
    try std.testing.expectEqual(@as(usize, 1), queue.count);

    var recorder = try perf.Recorder.init(std.testing.allocator, 2);
    defer recorder.deinit();
    recorder.setMode(.presented);
    var first = perf.FrameSample.empty(.sample, 0);
    first.cpu_acquire_ns = 0;
    first.cpu_present_slop_ns = 0;
    try recorder.append(first);
    var second = perf.FrameSample.empty(.sample, 1);
    second.cpu_acquire_ns = 0;
    second.cpu_present_slop_ns = 0;
    try recorder.append(second);
    var next_frame_id: u64 = 0;
    try queue.attachReady(&recorder, &next_frame_id, 2);
    try std.testing.expectEqual(@as(u64, 0), next_frame_id);
    try std.testing.expectEqual(@as(usize, 1), queue.count);
}
