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

const nogui = @import("nogui");
const App = nogui.App;
const Event = nogui.Event;
const tracy = @import("tracy");
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
const collectDrawCmds = nogui.drawcmd.collectDrawCmds;
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

fn svgCardRect(tree: *const WidgetTree) SvgCard {
    if (ui.svg_box_id) |id_raw| {
        const id: Id = @enumFromInt(id_raw);
        for (tree.nodes.items) |n| {
            if (n.id == id) return .{ .rect = contentRect(tree, id), .layer = n.paint.layer };
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
    gpu.commandsEnd(cmd);
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
    gpu.commandsEnd(command);
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
    gpu.commandsEnd(cmd);
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
        const style = cmd.style;
        const paint = cmd.paint;
        const corner_l: f32 = if (cmd.ring)
            paint.radius.left
        else
            @max(0, paint.radius.left - style.border.left);
        const corner_r: f32 = if (cmd.ring)
            paint.radius.right
        else
            @max(0, paint.radius.right - style.border.right);
        const corner_t: f32 = if (cmd.ring)
            paint.radius.top
        else
            @max(0, paint.radius.top - style.border.top);
        const corner_b: f32 = if (cmd.ring)
            paint.radius.bottom
        else
            @max(0, paint.radius.bottom - style.border.bottom);

        // Rounded-rect material geometry: one radius per axis (the SDF
        // rounds all four corners; demo boxes use uniform radii). Rings
        // always need the ring material (their interior is punched out);
        // fills need one only when they carry a radius.
        const rx: f32 = @max(corner_l, corner_r);
        const ry: f32 = @max(corner_t, corner_b);
        const border: f32 = if (cmd.ring)
            @max(
                @max(style.border.left, style.border.right),
                @max(style.border.top, style.border.bottom),
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
                .clip_id = n.clip_id,
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
            .clip_id = n.clip_id,
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
                .clip_id = n.clip_id,
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
                .clip_id = n.clip_id,
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
        const baseline_y = text_engine.baselineIn(content.y, content.h, size, n.font_id);
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
        const max_width: ?f32 = if (n.text_overflow == .ellipsis)
            @min(content.w, n.text_max_width orelse content.w)
        else
            null;
        const before = out.items.len;
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
        const card = svgCardRect(tree);
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

/// Render the current app frame into the offscreen Oklab target. Shared by
/// run() (presented via the blit pass) and runShot() (read back).
/// `texture_heap` is the GUI texture heap (the bindless textures the
/// fragment shader samples) — bound ONCE per frame before the renderer draw;
/// the blit pass binds its own heap later.
fn renderPass1(
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

/// Run the graphical demo. Blocks until the window closes.
/// Generic over the root component (any type with pub draw(self, ctx) !void).
pub fn run(
    comptime T: type,
    app: *App,
    root: *T,
    subpixel: bool,
    quad_debug: bool,
    bgr: bool,
    damp: bool,
    gpu_sort_verify: bool,
    max_frames: ?u32,
    audio_tracks: ?[]const LocalTrack,
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

    const sdl_win = try sdl3.video.Window.init("nogui v7 demo", 1100, 1160, .{ .resizable = true });
    defer sdl_win.deinit();
    try sdl_win.show();

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
        .timestamp_queries = true, // Tracy GPU zones (--frames profiling)
        .loader = .{
            .get_instance_proc_addr = @ptrCast(get_proc_addr),
            .get_instance_extensions = &getExts,
        },
        .io = io,
    });
    defer gpu.deinit();

    // Surface (the .extent wrapper is required by Surface.init).
    const sdl_surface = try sdl3.vulkan.Surface.init(sdl_win, @ptrFromInt(@intFromEnum(gpu.instanceHandle())), null);
    const surface: vk.SurfaceKHR = @enumFromInt(@intFromPtr(sdl_surface.surface));
    var gw = try noapi.Surface.init(&gpu, surface, .{ .extent = .{ .width = 1100, .height = 1160 } });
    defer gw.deinit();
    const win_id = try sdl_win.getId();

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

    // Blit pass: fullscreen triangle + Oklab→sRGB fragment shader, with a
    // descriptor heap holding the render-target texture + nearest sampler.
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
    var should_close = false;
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

        // Slice rects: draw commands → solid rects, then glyphs on top.
        // The clip-stack walk appends the frame's clip rects to the tree
        // (the tree is const-typed in FrameOutput; the per-frame clip list
        // is the renderer's legitimate scratch — collectDrawCmds extends it
        // and stamps clip ids, never touches layout state).
        const base_cmds = try collectDrawCmds(gpa, @constCast(out.tree), out.pressed, out.press_alpha);
        defer gpa.free(base_cmds);
        var slice_rects = std.ArrayList(SceneRect).empty;
        defer slice_rects.deinit(gpa);
        try buildSliceRects(
            gpa,
            &text_engine,
            &svg_view,
            &icon_cache,
            base_cmds,
            out.tree,
            out.hover,
            out.hover_alpha,
            out.focus,
            &slice_rects,
        );
        // --gpu-sort-verify: submit the bag in REVERSE paint order — the
        // CS1 sort (stable on (z, order)) must restore the paint order,
        // so the frame renders byte-identical to the ordered submission.
        if (gpu_sort_verify) std.mem.reverse(SceneRect, slice_rects.items);

        // Pass 1: GUI into the offscreen Oklab target.
        cmd.beginZone(.{ .name = "renderPass1_gpu", .src = @src() });
        try renderPass1(
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
        const sc = gw.currentImage();
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = .{ 0, 0, 0, 1 } },
        }, .render_area_size = .{ size.width, size.height } });

        cmd.setShaders(blit_vert, blit_frag);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.bindDescriptorSets(blit_heap);
        cmd.setBlendEnable(false);
        cmd.draw(noapi.PushData{}, 3, 1);
        cmd.endRendering();
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
        if (max_frames) |mf| {
            if (tick >= mf) break;
        }
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
    const out = try app.frameWithGpuAtTime(
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

    const base_cmds = try collectDrawCmds(gpa, @constCast(out.tree), null, 0);
    defer gpa.free(base_cmds);
    var slice_rects = std.ArrayList(SceneRect).empty;
    defer slice_rects.deinit(gpa);
    const hover_id = if (hover) |p| hitTest(out.tree, p) else null;
    // Static shot: the hover ring renders at full alpha when a node is
    // hovered (no easing in a one-frame shot); 0 otherwise.
    const hover_alpha: f32 = if (hover_id != null) 1 else 0;
    try buildSliceRects(
        gpa,
        &text_engine,
        &svg_view,
        &icon_cache,
        base_cmds,
        out.tree,
        hover_id,
        hover_alpha,
        null,
        &slice_rects,
    );
    // --gpu-sort-verify: submit the bag in REVERSE paint order — the CS1
    // sort must restore it, so the shot stays byte-identical.
    if (gpu_sort_verify) std.mem.reverse(SceneRect, slice_rects.items);

    // Readback buffer: one rgba32_float pixel per screen pixel.
    const pixel_bytes: u64 = @as(u64, surface_size.width) * surface_size.height * 4 * @sizeOf(f32);
    const readback = try gpu.gpuMalloc(pixel_bytes, 64, .readback);
    defer gpu.gpuFree(readback);

    try renderPass1(
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
    gpu.commandsEnd(cmd);
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
        gpu.commandsEnd(cmd2);
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
