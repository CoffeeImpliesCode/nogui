//! v7 demo window backend — SDL3 + noapi Vulkan rendering for the v7 tree,
//! through v4's text/glyph pipeline: the Renderer scene facade + FreeType
//! glyph materials, rendered into an offscreen Oklab float target, then
//! blitted to the swapchain with the Oklab→sRGB conversion shader.
//!
//! The reusable host owns SDL video, windows, and input translation. This
//! demo owns GPU presentation, scene construction, audio, and perf policy.
//!
//! Flow per frame: the window begins the Surface frame and obtains its
//! command buffer; app.frameWithGpuAtTime builds + lays out the tree and
//! dispatches component GPU hooks; collectDrawCmds flattens the tree into
//! paint-ordered commands. PaintList resolves authored colors into Oklab and
//! Renderer lowers effects and paths into the same sorted quad scene as
//! controls, glyphs, and cached SVGs. Each in-flight frame owns disjoint
//! material slots. The GUI pass draws once into the Oklab target; the blit
//! pass converts it to sRGB. Input routes to the committed tree.
//!
//! `runShot` renders a single frame into the offscreen target, copies it back
//! to a readback buffer and writes a P6 PPM — the text-renders proof.

const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const Io = std.Io;

const nogui = @import("nogui");
const host = @import("nogui_host");
const HostApplication = host.Application;
const host_preferences = host.preferences;
const v7_options = nogui.options;
const App = nogui.App;
const Event = nogui.Event;
const tracy = @import("tracy");
const perf = @import("perf.zig");
const calculator_ui = @import("calculator.zig");
const FramePacer = @import("FramePacer.zig").FramePacer;
const FrameNodeId = nogui.FrameNodeId;
const WindowSize = nogui.geometry.WindowSize;
const Rect = nogui.Rect;
const IconId = nogui.widget.IconId;
const hitTest = nogui.hitTest; // runShot's forced --hover
const renderer = @import("v7_render");
const Renderer = renderer.Renderer;
const RenderOptions = renderer.Options;
const SceneRect = renderer.SceneRect;
const paint = nogui.paint;

// The reusable frame module: the graphics text engine, the frame scene
// lowering, the GPU scene recording, and the bindless texture heap. The
// Oklab constants, the material partition, and the two sentinels live
// there; this file owns only the demo's assets, its raster caches, and its
// perf policy. `v7_frame` re-exports `scene`, `heap`, and `text_gpu`.
const v7_frame_mod = @import("v7_frame");
const frame_scene = v7_frame_mod.scene;
const frame_heap = v7_frame_mod.heap;
const TextEngine = v7_frame_mod.TextEngine;
const srgbToOklab = v7_frame_mod.srgbToOklab;
const debug_state_mod = @import("debug_state.zig");
const no_texture = frame_scene.no_texture;
const render_target_format = frame_scene.render_target_format;
const glyph_material_ceiling = frame_scene.glyph_material_ceiling;
const BindlessHeap = frame_heap.BindlessHeap;
const recordColorConversion = frame_scene.recordBlit;
const devicePixels = frame_scene.devicePixels;
const svg_mod = @import("svg.zig");
const ui = @import("ui.zig"); // for the demo texture index (texture_idx)
const AudioPlayer = @import("audio_player.zig").AudioPlayer;
const ffmpeg_decoder = @import("ffmpeg_decoder.zig");
const LocalTrack = @import("spotify_data.zig").LocalTrack;
const spotify_ui = @import("spotify.zig");

/// The demo's palette: the resolution table for authored `.palette = n`
/// colors. Application theme data, passed to the public lowering by pointer
/// and read only for the frame's duration.
const demo_palette = [_]paint.Srgb{
    .{ .r = 0.25, .g = 0.35, .b = 0.55 },
    .{ .r = 0.13, .g = 0.14, .b = 0.16 },
};

fn cancelSurfaceRecording(context: *anyopaque, _: *noapi.CommandBuffer) !void {
    const surface: *noapi.Surface = @ptrCast(@alignCast(context));
    try surface.abortFrame();
}

fn cancelOffscreenRecording(context: *anyopaque, command: *noapi.CommandBuffer) !void {
    const gpu: *noapi.Gpu = @ptrCast(@alignCast(context));
    try gpu.commandsCancel(command);
}

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

fn logicalWindowSize(sdl_window: sdl3.video.Window) !WindowSize {
    const size = try sdl_window.getSize();
    return .{ .width = @floatFromInt(size[0]), .height = @floatFromInt(size[1]) };
}

fn deviceSurfaceExtent(sdl_window: sdl3.video.Window) !noapi.Extent2D {
    const pixels = try sdl_window.getSizeInPixels();
    return .{ .width = @intCast(pixels[0]), .height = @intCast(pixels[1]) };
}

fn setScenePixelScale(
    text_engine: *TextEngine,
    svg_scene: *SvgScene,
    icon_cache: *IconCache,
    logical_size: WindowSize,
    device_extent: noapi.Extent2D,
) !void {
    const scale = try nogui.geometry.PixelScale.init(logical_size, .{
        .width = device_extent.width,
        .height = device_extent.height,
    });
    text_engine.setPixelScale(scale);
    svg_scene.setPixelScale(scale);
    icon_cache.setPixelScale(scale);
}

fn configureGpuComponents(comptime T: type, root: *T, heap: noapi.DescriptorHeap) void {
    if (comptime @hasDecl(T, "setGpuDescriptorHeap")) root.setGpuDescriptorHeap(heap);
}

/// The showcase documents. Both are rendered by librsvg through the
/// reusable host adapter (`svg_mod`): groups, transforms, curves, gradients
/// and viewBox all come from the real renderer. The demo keeps no parser.
const tiger_svg = @embedFile("tiger.svg");

/// The stroke test scene: curved thin strokes at increasing widths. The
/// viewBox covers the curves' FULL ink — the 0.1-wide curve's control
/// points reach y = -80 and the 4-wide one y = 520 — so librsvg's
/// preserveAspectRatio fit shows every stroke instead of cropping the
/// overflow, which is what the old bounds-fit view had to special-case.
const stroke_scene_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="40 -90 420 620">
    \\  <path d="M 50 60 C 150 220, 350 -80, 450 60" stroke="#fff" stroke-width="0.1" fill="none"/>
    \\  <path d="M 50 120 C 150 280, 350 -20, 450 120" stroke="#fff" stroke-width="0.25" fill="none"/>
    \\  <path d="M 50 180 C 150 340, 350 40, 450 180" stroke="#fff" stroke-width="0.5" fill="none"/>
    \\  <path d="M 50 240 C 150 400, 350 100, 450 240" stroke="#fff" stroke-width="1" fill="none"/>
    \\  <path d="M 50 300 C 150 460, 350 160, 450 300" stroke="#fff" stroke-width="2" fill="none"/>
    \\  <path d="M 50 360 C 150 520, 350 220, 450 360" stroke="#fff" stroke-width="4" fill="none"/>
    \\</svg>
;

/// The stroke test scene (the TestStrokesApp root) loads the curved
/// thin-stroke set; everything else loads the tiger.
fn sceneDocument(comptime T: type) []const u8 {
    return if (comptime T == ui.TestStrokesApp) stroke_scene_svg else tiger_svg;
}

/// The showcase box's declared edge in logical window units, declared once
/// by the UI and echoed here so the scene can report its raster before the
/// first measured one exists.
fn sceneDocumentBox(comptime T: type) f32 {
    return if (comptime T == ui.TestStrokesApp)
        ui.stroke_scene_box_size
    else
        ui.tiger_scene_box_size;
}

const icon_count = @typeInfo(IconId).@"enum".field_names.len;

/// The icon box in logical window units. Every icon document uses a
/// 16-unit viewBox, so one square quad at this size samples the whole
/// raster and the set keeps a uniform optical weight.
const icon_logical_size: f32 = 16;

/// Compact 16-unit SVG documents, indexed in exact `IconId` declaration
/// order. They upload as white coverage masks: the scene rect's Oklab tint
/// supplies the color, so one raster per icon serves every button color.
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

/// A rasterized SVG document bound to one device-pixel viewport and
/// registered in the GUI texture heap. The raster is rebuilt ONLY when the
/// destination's device size or the display scale changes: a steady frame
/// reuses the registered heap index with no upload and no allocation.
const SvgTexture = struct {
    gpa: std.mem.Allocator,
    gpu: *noapi.Gpu,
    registry: *BindlessHeap,
    document: []const u8,
    /// Coverage-mask upload: the raster keeps only its alpha and the scene
    /// rect's Oklab tint supplies the color.
    mask: bool,
    viewport: [2]u32 = .{ 0, 0 },
    scale: f32 = 0,
    texture: noapi.TextureHandle = .{},
    index: u32 = no_texture,

    fn init(
        gpa: std.mem.Allocator,
        gpu: *noapi.Gpu,
        registry: *BindlessHeap,
        document: []const u8,
        mask: bool,
    ) SvgTexture {
        return .{
            .gpa = gpa,
            .gpu = gpu,
            .registry = registry,
            .document = document,
            .mask = mask,
        };
    }

    fn deinit(self: *SvgTexture) void {
        self.release();
        self.* = undefined;
    }

    /// Drop the raster and give its heap slot back to the registry's shared
    /// free list. A viewport change re-rasterizes rather than keeping a
    /// stale surface alive beside the new one.
    fn release(self: *SvgTexture) void {
        if (self.texture.texture.id == 0) return;
        self.registry.release(self.gpa, self.texture);
        self.gpu.textureDestroy(self.texture);
        self.texture = .{};
        self.index = no_texture;
        self.viewport = .{ 0, 0 };
        self.scale = 0;
    }

    /// Rasterize and upload for an exact device-pixel viewport. A no-op
    /// when the live raster already covers it.
    fn ensure(self: *SvgTexture, width: u32, height: u32, scale: f32) !void {
        if (self.texture.texture.id != 0 and self.viewport[0] == width and
            self.viewport[1] == height and self.scale == scale) return;
        self.release();
        var image = try svg_mod.rasterize(self.gpa, self.document, width, height, scale);
        defer image.deinit();
        const texture = try createSurfaceTexture(self.gpu, &image, self.mask);
        errdefer self.gpu.textureDestroy(texture);
        self.index = try self.registry.register(self.gpa, texture);
        self.texture = texture;
        self.viewport = .{ width, height };
        self.scale = scale;
    }
};

/// The reserved showcase box's document (tiger or stroke scene), rasterized
/// at the box's device-pixel size and sampled as one bindless quad.
const SvgScene = struct {
    texture: SvgTexture,
    /// The box edge the UI declares, reported until the first measured
    /// raster replaces it (the scene's panel reads the value during draw,
    /// one frame before the measured box is known).
    declared_box: f32,
    scale: nogui.geometry.PixelScale = .{ .x = 1, .y = 1 },
    /// librsvg is missing: reported once so the log names the cause instead
    /// of leaving an empty card unexplained.
    reported: bool = false,

    fn init(
        gpa: std.mem.Allocator,
        gpu: *noapi.Gpu,
        registry: *BindlessHeap,
        document: []const u8,
        declared_box: f32,
    ) SvgScene {
        return .{
            .texture = SvgTexture.init(gpa, gpu, registry, document, false),
            .declared_box = declared_box,
        };
    }

    fn deinit(self: *SvgScene) void {
        self.texture.deinit();
        self.* = undefined;
    }

    fn setPixelScale(self: *SvgScene, scale: nogui.geometry.PixelScale) void {
        self.scale = scale;
        if (ui.svg_raster[0] == 0) {
            ui.svg_raster = .{
                devicePixels(self.declared_box, scale.x),
                devicePixels(self.declared_box, scale.y),
            };
        }
        ui.svg_raster_scale = scale.x;
    }

    /// Rasterize the document for `box`'s device-pixel size and return its
    /// heap index. Null when the box is collapsed, the raster exceeds the
    /// host's viewport bound, or librsvg is unavailable.
    fn prepare(self: *SvgScene, box: Rect) !?u32 {
        if (box.w <= 0 or box.h <= 0) return null;
        if (!svg_mod.isAvailable()) {
            if (!self.reported) {
                self.reported = true;
                std.log.warn("SVG showcase disabled: librsvg and Cairo did not load", .{});
            }
            return null;
        }
        const width = devicePixels(box.w, self.scale.x);
        const height = devicePixels(box.h, self.scale.y);
        if (width == 0 or height == 0 or
            width > svg_mod.max_viewport_edge or height > svg_mod.max_viewport_edge) return null;
        try self.texture.ensure(width, height, self.scale.x);
        ui.svg_raster = .{ width, height };
        ui.svg_raster_scale = self.scale.x;
        return self.texture.index;
    }
};

/// The transport icons, rasterized by librsvg at the display's device
/// scale. Every icon shares one square device size, so the set
/// re-rasterizes together when the scale changes and never mid-frame.
const IconCache = struct {
    textures: [icon_count]SvgTexture,
    /// The device-pixel viewport the registered rasters were made for.
    raster: [2]u32 = .{ 0, 0 },
    scale: nogui.geometry.PixelScale = .{ .x = 1, .y = 1 },
    reported: bool = false,

    fn init(gpa: std.mem.Allocator, gpu: *noapi.Gpu, registry: *BindlessHeap) IconCache {
        var textures: [icon_count]SvgTexture = undefined;
        for (icon_svg, 0..) |document, slot| {
            textures[slot] = SvgTexture.init(gpa, gpu, registry, document, true);
        }
        return .{ .textures = textures };
    }

    fn deinit(self: *IconCache) void {
        for (&self.textures) |*texture| texture.deinit();
        self.* = undefined;
    }

    fn setPixelScale(self: *IconCache, scale: nogui.geometry.PixelScale) void {
        self.scale = scale;
    }

    /// Rasterize the whole set for the current display scale. False when
    /// librsvg is unavailable or a raster failed, in which case the scene
    /// draws no icons rather than stale ones.
    fn prepare(self: *IconCache) bool {
        if (!svg_mod.isAvailable()) {
            if (!self.reported) {
                self.reported = true;
                std.log.warn("transport icons disabled: librsvg and Cairo did not load", .{});
            }
            return false;
        }
        const width = devicePixels(icon_logical_size, self.scale.x);
        const height = devicePixels(icon_logical_size, self.scale.y);
        if (width == 0 or height == 0) return false;
        if (self.raster[0] == width and self.raster[1] == height) return true;
        for (&self.textures) |*texture| {
            texture.ensure(width, height, self.scale.x) catch |err| {
                std.log.warn(
                    "transport icon raster failed at {d}x{d}: {s}",
                    .{ width, height, @errorName(err) },
                );
                return false;
            };
        }
        self.raster = .{ width, height };
        return true;
    }

    /// The icon's bindless heap index, valid after a `prepare` that
    /// returned true.
    fn index(self: *const IconCache, icon: IconId) u32 {
        return self.textures[@backingInt(icon)].index;
    }
};

/// The public lowering's injection points, implemented over the demo's
/// librsvg-backed raster caches. The public module knows nothing about SVG
/// documents, viewports, or Cairo; it asks for a heap index for a box.
fn overlayPrepare(ctx: *anyopaque, box: Rect) anyerror!?u32 {
    const scene: *SvgScene = @ptrCast(@alignCast(ctx));
    return scene.prepare(box);
}

fn iconsPrepare(ctx: *anyopaque) bool {
    const cache: *IconCache = @ptrCast(@alignCast(ctx));
    return cache.prepare();
}

fn iconIndex(ctx: *anyopaque, icon: IconId) u32 {
    const cache: *const IconCache = @ptrCast(@alignCast(ctx));
    return cache.index(icon);
}

/// The demo's scene inputs for one frame. The showcase box comes from the
/// node the UI published during the frame's draw, which is why this is built
/// per frame and not cached beside the raster caches.
fn sceneOptions(
    svg_scene: *SvgScene,
    icon_cache: *IconCache,
) frame_scene.SceneOptions {
    return .{
        .palette = &demo_palette,
        .overlay = .{ .ctx = svg_scene, .prepare = overlayPrepare },
        .icons = .{
            .ctx = icon_cache,
            .prepare = iconsPrepare,
            .index = iconIndex,
        },
        .icon_logical_size = icon_logical_size,
        .showcase_box = if (ui.svg_box_id) |raw| @as(FrameNodeId, @fromBackingInt(@intCast(raw))) else null,
    };
}

/// The public recorder's inputs for one frame. `arena` is the frame tree's
/// own arena, so the lowering's scratch dies with the frame that owns the
/// tree — the demo never frees it separately.
fn recordContext(
    frame: *const nogui.FrameOutput,
    gui_renderer: *Renderer,
    text_engine: *const TextEngine,
    verify_sort: bool,
    logical_size: WindowSize,
    device_extent: noapi.Extent2D,
    texture_heap: noapi.DescriptorHeap,
) frame_scene.RecordContext {
    return .{
        .arena = frame.tree.allocator,
        .renderer = gui_renderer,
        .text = text_engine,
        .verify_sort = verify_sort,
        .logical = logical_size,
        .device = device_extent,
        .texture_heap = texture_heap,
        .clips = frame.tree.clip_rects[0..frame.tree.clip_count],
    };
}

// The Oklab clear colour and the material partition (glyph ceiling, the
// three per-frame decoration rings) live in the public scene module; this
// file aliases what it still needs. `frame_material_slots` and
// `frame_material_base` have no demo callers left: the lowering and the
// recording are their only consumers, and both live in `v7_frame/scene.zig`.

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
fn uploadDemoTexture(gpa: std.mem.Allocator, gpu: *noapi.Gpu, registry: *BindlessHeap) !u32 {
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
    var command_pending = true;
    errdefer if (command_pending) {
        gpu.commandsCancel(&cmd) catch @panic("upload recording cancellation failed");
    };
    cmd.copyToTexture(.{
        .gpu = gpu,
        .handle = tex,
        .dimensions = .{ demo_tex_size, demo_tex_size, 1 },
        .format = .rgba32_float,
    }, buf, .{ .size = .{ demo_tex_size, demo_tex_size, 1 } });
    try gpu.queueSubmit(&.{cmd});
    command_pending = false;
    try gpu.waitIdle();

    return registry.register(gpa, tex);
}

/// Create a sampled rgba32_float texture and fill it through the noapi
/// staging path: `write` receives the host-visible destination as one
/// float4 per pixel, row-major. rgba8 UNORM could not hold the negative
/// Oklab chroma the pipeline renders in, so every image the demo samples is
/// uploaded as floats. Callers run this outside the frame loop — it ends in
/// a queue idle. `write` may fail (a decoded surface can be shorter than its
/// own rows); the error surfaces before any command references the staging
/// buffer.
pub fn createFloatTexture(
    comptime write: fn (*const anyopaque, [*]f32, usize) anyerror!void,
    gpu: *noapi.Gpu,
    width: u32,
    height: u32,
    context: *const anyopaque,
) !noapi.TextureHandle {
    const pixel_count = std.math.mul(usize, width, height) catch
        return error.SurfaceCapacity;
    const float_count = std.math.mul(usize, pixel_count, 4) catch
        return error.SurfaceCapacity;
    const staging_bytes: u64 = @intCast(float_count * @sizeOf(f32));

    const texture = try gpu.textureCreate(.{
        .dimensions = .{ width, height, 1 },
        .format = .rgba32_float,
        .usage = .{ .sampled = true },
    });
    errdefer gpu.textureDestroy(texture);

    const staging = try gpu.gpuMalloc(staging_bytes, 64, .default);
    defer gpu.gpuFree(staging);
    try write(context, @ptrCast(@alignCast(staging.cpu)), pixel_count);

    var command = try gpu.commandsBegin();
    var command_pending = true;
    errdefer if (command_pending) {
        gpu.commandsCancel(&command) catch @panic("upload recording cancellation failed");
    };
    command.copyToTexture(.{
        .gpu = gpu,
        .handle = texture,
        .dimensions = .{ width, height, 1 },
        .format = .rgba32_float,
    }, staging, .{ .size = .{ width, height, 1 } });
    try gpu.queueSubmit(&.{command});
    command_pending = false;
    try gpu.waitIdle();
    return texture;
}

/// A decoded RGBA8 surface's pixels as pipeline floats: Oklab for full-color
/// art, a premultiplied WHITE coverage mask for tinted monochrome art (the
/// scene rect's Oklab tint then supplies the icon's color).
const SurfaceUpload = struct {
    image: *const svg_mod.DecodedImage,
    mask: bool,

    fn write(context: *const anyopaque, out: [*]f32, _: usize) !void {
        const self: *const SurfaceUpload = @ptrCast(@alignCast(context));
        if (self.mask) {
            try svg_mod.writeFloats(svg_mod.coverageMask, out, self.image);
            return;
        }
        try svg_mod.writeFloats(srgbToOklab, out, self.image);
    }
};

pub fn createSurfaceTexture(
    gpu: *noapi.Gpu,
    image: *const svg_mod.DecodedImage,
    mask: bool,
) !noapi.TextureHandle {
    var upload: SurfaceUpload = .{ .image = image, .mask = mask };
    return createFloatTexture(
        SurfaceUpload.write,
        gpu,
        image.width,
        image.height,
        &upload,
    );
}

/// Decode and upload one local track's artwork during window setup. The
/// registry owns the sampled texture after registration; no frame allocates.
fn uploadArtworkTexture(
    gpa: std.mem.Allocator,
    gpu: *noapi.Gpu,
    registry: *BindlessHeap,
    artwork: ffmpeg_decoder.Artwork,
) !u32 {
    var decoded = try ffmpeg_decoder.decodeArtwork(gpa, artwork);
    defer decoded.deinit(gpa);
    const texture = try createFloatTexture(
        struct {
            fn write(context: *const anyopaque, out: [*]f32, count: usize) !void {
                const pixels: *const ffmpeg_decoder.DecodedArtwork = @ptrCast(@alignCast(context));
                for (0..count) |pixel_index| {
                    const source = pixel_index * 4;
                    const color = srgbToOklab(.{
                        @as(f32, @floatFromInt(pixels.pixels[source + 0])) / 255.0,
                        @as(f32, @floatFromInt(pixels.pixels[source + 1])) / 255.0,
                        @as(f32, @floatFromInt(pixels.pixels[source + 2])) / 255.0,
                        @as(f32, @floatFromInt(pixels.pixels[source + 3])) / 255.0,
                    });
                    const destination = pixel_index * 4;
                    out[destination + 0] = color[0];
                    out[destination + 1] = color[1];
                    out[destination + 2] = color[2];
                    out[destination + 3] = color[3];
                }
            }
        }.write,
        gpu,
        decoded.width,
        decoded.height,
        &decoded,
    );
    return registry.register(gpa, texture);
}

fn uploadLocalArtwork(
    comptime T: type,
    gpa: std.mem.Allocator,
    root: *T,
    gpu: *noapi.Gpu,
    registry: *BindlessHeap,
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
fn uploadReferenceTexture(gpa: std.mem.Allocator, gpu: *noapi.Gpu, registry: *BindlessHeap) !void {
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
    var command_pending = true;
    errdefer if (command_pending) {
        gpu.commandsCancel(&cmd) catch @panic("upload recording cancellation failed");
    };
    cmd.copyToTexture(.{
        .gpu = gpu,
        .handle = tex,
        .dimensions = .{ tiger_ref_size, tiger_ref_size, 1 },
        .format = .rgba32_float,
    }, buf, .{ .size = .{ tiger_ref_size, tiger_ref_size, 1 } });
    try gpu.queueSubmit(&.{cmd});
    command_pending = false;
    try gpu.waitIdle();

    ui.tiger_ref_idx = try registry.register(gpa, tex);
}
// The tree-to-scene lowering (`buildSliceRects`, the `FramePaint` paint
// list, the material partition) and the GPU recording (`recordFrameScene`,
// the Oklab blit) now live in the reusable `v7_frame/scene.zig`. The demo
// keeps only what makes its frames demo-shaped: the librsvg documents, the
// raster caches, the palette, and the perf policy. Every callsite below
// goes through `frame_scene` with a caller-owned `SceneScratch` whose two
// lists retain their capacity across frames, so the hot path allocates
// nothing.

const PerfResources = struct {
    host_app: *HostApplication,
    logical_size: WindowSize,
    gpa: std.mem.Allocator,
    io: Io,
    gpu: *noapi.Gpu,
    text_engine: *TextEngine,
    gui_renderer: *Renderer,
    tex_registry: *BindlessHeap,
    svg_scene: *SvgScene,
    icon_cache: *IconCache,
    gpu_endpoint: *nogui.GpuEndpoint,
    blit_vert: noapi.Shader,
    blit_frag: noapi.Shader,
    blit_sampler: u64,
    counters: if (v7_options.perf_counters) *nogui.Counters else void,
};

pub const OffscreenSlots = struct {
    pub const count: usize = 3;
    pub const query_count: u32 = 6;

    gpu: *noapi.Gpu,
    oklab_targets: [count]noapi.TextureHandle,
    srgb_targets: [count]noapi.TextureHandle,
    blit_heaps: [count]noapi.DescriptorHeap,
    timeline: noapi.Semaphore,
    timestamp_queries: ?noapi.TimestampQuerySet = null,
    oklab_count: usize = 0,
    srgb_count: usize = 0,
    blit_heap_count: usize = 0,
    timeline_created: bool = false,

    pub fn init(gpu: *noapi.Gpu, blit_sampler: u64) !OffscreenSlots {
        var slots: OffscreenSlots = .{
            .gpu = gpu,
            // SAFETY: oklab_count bounds the initialized texture prefix.
            .oklab_targets = undefined,
            // SAFETY: srgb_count bounds the initialized texture prefix.
            .srgb_targets = undefined,
            // SAFETY: blit_heap_count bounds the initialized heap prefix.
            .blit_heaps = undefined,
            // SAFETY: timeline_created stays false until semaphore creation succeeds.
            .timeline = undefined,
        };
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
const perf_device_extent: noapi.Extent2D = .{ .width = perf_width, .height = perf_height };
const perf_draw_cmd_capacity: usize = 16 * 1024;

const FrameDemand = nogui.frame_demand.FrameDemand;
const taskDeadlineWaitMilliseconds = nogui.frame_demand.taskDeadlineWaitMilliseconds;

fn nextWaitMilliseconds(
    demand: *const FrameDemand,
    now_ms: u64,
    now_ns: i96,
    task_deadline_ns: ?i96,
    shortcut_wait: ?u31,
) ?u31 {
    const frame_timeout = demand.waitMilliseconds(now_ms);
    const task_deadline = task_deadline_ns orelse return earliest(frame_timeout, shortcut_wait);
    const task_timeout = taskDeadlineWaitMilliseconds(now_ns, task_deadline);
    const waited: ?u31 = if (frame_timeout) |ms| @min(ms, task_timeout) else task_timeout;
    return earliest(waited, shortcut_wait);
}

fn earliest(a: ?u31, b: ?u31) ?u31 {
    if (a) |ms| {
        if (b) |other| return @min(ms, other);
        return ms;
    }
    return b;
}

pub const RunOptions = struct {
    subpixel: bool = false,
    quad_debug: bool = false,
    bgr_order: bool = false,
    damp_chroma: bool = true,
    gpu_sort_verify: bool = false,
    uncapped: bool = false,
    max_frames: ?u32 = null,
    audio_tracks: ?[]const LocalTrack = null,
    perf: ?perf.Config = null,
    /// Appended to the window title. A benchmark that shares a display with
    /// other tools sets it so an operator can tell the windows apart.
    window_title_suffix: []const u8 = "",

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
            if (self.uncapped) return error.PerfOptionConflict;
            if (self.max_frames != null) return error.PerfOptionConflict;
            if (self.audio_tracks != null) return error.PerfOptionConflict;
        }
        return self;
    }
};

fn windowCanRender(flags: sdl3.video.Window.Flags, has_presented: bool) bool {
    // Some compositors report a new surface occluded until its first buffer.
    return !flags.hidden and !flags.minimized and (!has_presented or !flags.occluded);
}

fn needsContinuous(comptime T: type, root: *T, options: RunOptions, audio_active: bool) bool {
    if (options.uncapped or options.max_frames != null or options.perf != null or ui.gpu_remount_smoke) return true;
    if (comptime T == ui.TodoApp) return root.mandelbrot_visible;
    if (comptime T == spotify_ui.SpotifyApp) return audio_active and root.is_playing;
    return false;
}

test "api-w05 continuous policy keeps Mandelbrot and finite or uncapped frames advancing" {
    const old_smoke = ui.gpu_remount_smoke;
    defer ui.gpu_remount_smoke = old_smoke;
    ui.gpu_remount_smoke = false;
    var todo: ui.TodoApp = .{};
    try std.testing.expect(needsContinuous(ui.TodoApp, &todo, .{}, false));
    todo.setMandelbrotVisible(false);
    try std.testing.expect(!needsContinuous(ui.TodoApp, &todo, .{}, false));
    try std.testing.expect(needsContinuous(ui.TodoApp, &todo, .{ .max_frames = 3 }, false));
    try std.testing.expect(needsContinuous(ui.TodoApp, &todo, .{ .uncapped = true }, false));
    ui.gpu_remount_smoke = true;
    try std.testing.expect(needsContinuous(ui.TodoApp, &todo, .{}, false));
}

test "api-w05 idle roots stop continuous frames while active audio can opt in" {
    var calc: calculator_ui.CalculatorApp = .{};
    try std.testing.expect(!needsContinuous(calculator_ui.CalculatorApp, &calc, .{}, false));
    var spotify: spotify_ui.SpotifyApp = .{};
    try std.testing.expect(!needsContinuous(spotify_ui.SpotifyApp, &spotify, .{}, false));
    try std.testing.expect(needsContinuous(spotify_ui.SpotifyApp, &spotify, .{}, true));
    spotify.is_playing = false;
    try std.testing.expect(!needsContinuous(spotify_ui.SpotifyApp, &spotify, .{}, true));
}

test "api-w05 hidden frame deadline does not mask an earlier task or chord deadline" {
    var demand: FrameDemand = .{};
    _ = demand.take(0).?;
    demand.finish(true);
    demand.setDeadline(500);
    demand.setVisible(false);
    try std.testing.expectEqual(
        @as(?u31, 4),
        nextWaitMilliseconds(&demand, 100, 100_000_000, 103_000_001, null),
    );
    try std.testing.expectEqual(
        @as(?u31, 2),
        nextWaitMilliseconds(&demand, 100, 100_000_000, 103_000_001, 2),
    );
    try std.testing.expectEqual(
        @as(?u31, null),
        nextWaitMilliseconds(&demand, 500, 500_000_000, null, null),
    );
    demand.setVisible(true);
    _ = demand.take(500).?;
    demand.finish(true);
    demand.setDeadline(600);
    try std.testing.expectEqual(
        @as(?u31, 2),
        nextWaitMilliseconds(&demand, 501, 501_000_000, 503_000_000, null),
    );
    // A chord deadline is the earliest wait even with no task deadline and
    // no frame work: the loop must wake to resolve it.
    try std.testing.expectEqual(
        @as(?u31, 0),
        nextWaitMilliseconds(&demand, 501, 501_000_000, null, 0),
    );
}

test "api-w05 startup presents once before trusting compositor occlusion" {
    var flags: sdl3.video.Window.Flags = .{ .occluded = true };
    try std.testing.expect(windowCanRender(flags, false));
    try std.testing.expect(!windowCanRender(flags, true));
    flags.occluded = false;
    try std.testing.expect(windowCanRender(flags, true));
    flags.minimized = true;
    try std.testing.expect(!windowCanRender(flags, false));
    flags.minimized = false;
    flags.hidden = true;
    try std.testing.expect(!windowCanRender(flags, false));
}

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
    const uncapped = validated_options.uncapped;
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

    // The demo overrides session hints; the reusable host leaves driver
    // selection to SDL unless the caller requests a driver explicitly.
    var host_app = try HostApplication.init(gpa, app.session, .{
        .render_driver = "vulkan",
    });
    defer host_app.deinit();

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
    const window_logical_width: u32 = if (perf_window) perf_width else 1100;
    const window_logical_height: u32 = if (perf_window) perf_height else 1160;
    var title_storage: [128]u8 = undefined;
    const window_title: [:0]const u8 = if (validated_options.window_title_suffix.len == 0)
        "nogui v7 demo"
    else
        try std.fmt.bufPrintSentinel(
            &title_storage,
            "nogui v7 demo{s}",
            .{validated_options.window_title_suffix},
            0,
        );
    const window_handle = try host_app.openWindowWithApp(app, .{
        .title = window_title,
        .width = window_logical_width,
        .height = window_logical_height,
        .resizable = !perf_window,
        .visible = !perf_offscreen,
        .gpu_surface = true,
    });
    const managed = try host_app.getWindow(window_handle);
    const sdl_win = managed.native.sdl;
    var logical_size = try logicalWindowSize(sdl_win);
    try host_app.start();

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
    // The font bytes stay in the demo; the engine borrows nothing and
    // embeds nothing. The first registered family is the one a node that
    // names no family resolves to.
    var text_engine = try TextEngine.init(gpa, &gpu, &.{
        .{ .family = "InterVariable", .bytes = @embedFile("InterVariable.ttf") },
        .{ .family = "Fira Code Nerd Font", .bytes = @embedFile("FiraCodeNerdFont-Regular.ttf") },
    });
    defer text_engine.deinit();
    try text_engine.setGlyphSlotLimit(glyph_material_ceiling);
    // The App measures through this engine's own `MeasureSource`: a measured
    // label and the glyphs the frame rasterizes are one measurement, and the
    // source is a value the App holds, not a thread-local a scope sets.
    app.measure = text_engine.measurer();
    var gui_renderer = try Renderer.init(&gpu, quad_vert_f.spv, quad_frag_f.spv, sort_comp_f.spv);
    defer gui_renderer.deinit();
    // One retained scratch for the whole run: the scene rects and the draw
    // commands keep their capacity, so no frame allocates.
    var scene_scratch = frame_scene.SceneScratch.init(gpa, &gui_renderer);
    defer scene_scratch.deinit();
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
    var tex_registry = try BindlessHeap.init(gpa, &gpu);
    defer tex_registry.deinit(gpa);
    ui.texture_idx = try uploadDemoTexture(gpa, &gpu, &tex_registry);
    try uploadReferenceTexture(gpa, &gpu, &tex_registry);
    if (audio_tracks) |tracks| {
        uploadLocalArtwork(T, gpa, root, &gpu, &tex_registry, tracks);
    }

    // SVG showcase: the reserved box's document, rasterized by librsvg
    // through the reusable host adapter and uploaded as one Oklab texture.
    // The stroke test scene (the TestStrokesApp root) loads the curved
    // thin-stroke set; everything else loads the tiger.
    var svg_scene = SvgScene.init(gpa, &gpu, &tex_registry, sceneDocument(T), sceneDocumentBox(T));
    defer svg_scene.deinit();
    var perf_counters_storage: if (v7_options.perf_counters) nogui.Counters else void =
        if (v7_options.perf_counters) .{} else {};
    if (comptime v7_options.perf_counters) {
        app.setCounterSink(&perf_counters_storage);
        text_engine.setCounterSink(&perf_counters_storage);
    }
    // Transport icons rasterize on their first frame and re-rasterize only
    // when the display scale changes. No frame uploads or allocates.
    var icon_cache = IconCache.init(gpa, &gpu, &tex_registry);
    defer icon_cache.deinit();

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
    configureGpuComponents(T, root, tex_registry.handle);

    // The endpoint borrows the window-owned GPU and bindless heap for the
    // graphical lifetime. Components initialize here, before the first
    // begun Surface frame, and detach while those resources are still alive.
    var gpu_texture_runtime = tex_registry.runtimeRegistry();
    var gpu_endpoint: nogui.GpuEndpoint = .{
        .gpu = &gpu,
        .textures = &gpu_texture_runtime,
    };
    try app.attachGpu(&gpu_endpoint);
    defer app.detachGpu();
    const initial_resize: Event = .{ .resize = .{
        .width = logical_size.width,
        .height = logical_size.height,
    } };
    _ = try app.handle(initial_resize);

    if (perf_config) |config| {
        try setScenePixelScale(
            &text_engine,
            &svg_scene,
            &icon_cache,
            logical_size,
            perf_device_extent,
        );
        const resources: PerfResources = .{
            .host_app = &host_app,
            .logical_size = logical_size,
            .gpa = gpa,
            .io = io,
            .gpu = &gpu,
            .text_engine = &text_engine,
            .gui_renderer = &gui_renderer,
            .tex_registry = &tex_registry,
            .svg_scene = &svg_scene,
            .icon_cache = &icon_cache,
            .gpu_endpoint = &gpu_endpoint,
            .blit_vert = blit_vert,
            .blit_frag = blit_frag,
            .blit_sampler = blit_sampler,
            .counters = if (comptime v7_options.perf_counters) &perf_counters_storage else {},
        };
        var recorder = try perf.Recorder.init(gpa, try config.totalFrames());
        defer recorder.deinit();

        const metadata = switch (config.mode) {
            .offscreen => try runOffscreenPerf(app, &resources, config, &recorder),
            .presented => blk: {
                // noapi creates and owns the platform surface; this caller
                // never sees a Vulkan instance or surface handle.
                var gw = try noapi.Surface.initSdl(
                    &gpu,
                    @ptrCast(sdl_win.value),
                    @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
                    .{
                        .extent = try deviceSurfaceExtent(sdl_win),
                        .present_mode = .fifo,
                    },
                );
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
                    app,
                    &resources,
                    config,
                    &recorder,
                    &gw,
                    blit_heap,
                    refresh_hz,
                );
            },
        };
        try writePerfArtifact(T, gpa, io, config, &gpu, &recorder, metadata);
        return;
    }

    const blit_heap = try gpu.descHeapCreate(8, 0, 1);
    defer gpu.descHeapDestroy(blit_heap);
    gpu.descHeapSetSamplers(blit_heap, 0, &.{blit_sampler});
    var gw = try noapi.Surface.initSdl(
        &gpu,
        @ptrCast(sdl_win.value),
        @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
        .{
            .extent = try deviceSurfaceExtent(sdl_win),
            .present_mode = if (uncapped) .immediate else .fifo,
        },
    );
    defer gw.deinit();
    var last_scene_scale: ?struct { logical: WindowSize, device: noapi.Extent2D } = null;

    // Frame pacer (Phase 2 — tier-2 frame pacing). The default FIFO swapchain
    // is vsync-paced and blocks the CPU on the GPU once the image queue is
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

    // The host polls and translates input before each frame. The demo applies
    // shortcuts and sends one frame tick with its own clock.
    var tick: u32 = 1;
    // The single window's Surface frame slot advances only after a successful
    // present, matching noapi's command-buffer rotation.
    var frame_index: u32 = 0;
    var last_frame_ms: u64 = 0;
    var perf_frame_count: u32 = 0;
    var should_close = false;
    var remount_smoke_phase: GpuRemountSmokePhase = .initial_visible;
    var remount_smoke_initial_slot: ?u32 = null;

    const demand = &managed.demand;
    try managed.refresh();

    while (!should_close) {
        try host_app.checkWakeFailure();
        _ = try app.session.drainTasks();
        if (ui.gpu_remount_smoke and !app.currentRootMatches(T, root))
            return error.GpuRemountSmokeRootReplaced;
        demand.setContinuous(app.currentRootMatches(T, root) and
            needsContinuous(T, root, validated_options, audio_player != null));
        const demand_time_ms = sdl3.timer.getMillisecondsSinceInit();
        try host_preferences.applyReducedMotion(app, demand_time_ms);
        demand.setDeadline(app.animationDemand(demand_time_ms, 16).deadline_ms);
        var session_redraw = false;
        defer if (session_redraw) app.session.requestRedraw(app.window) catch
            @panic("failed to rearm session redraw");
        var frame_claimed = false;
        defer if (frame_claimed) demand.finish(false);
        if (demand.visible and try app.session.takeRedraw(app.window)) {
            demand.invalidateLayout();
            session_redraw = true;
        }

        // A published completion stays queued even if it races the last
        // drain and arrives just before SDL_WaitEvent.
        var first_event: ?sdl3.events.Event = null;
        if (!demand.pending(sdl3.timer.getMillisecondsSinceInit())) {
            const timeout = nextWaitMilliseconds(
                demand,
                sdl3.timer.getMillisecondsSinceInit(),
                Io.Timestamp.now(io, .awake).toNanoseconds(),
                try app.session.nextTaskDeadline(),
                app.nextShortcutWaitMilliseconds(),
            );
            first_event = if (timeout) |ms|
                sdl3.events.waitAndPopTimeout(ms)
            else
                try sdl3.events.waitAndPop();
        } else if (demand.visible and demand.continuous and
            !uncapped and ui.frame_pacing and max_frames == null and pacer_sleep_ns > 0)
        {
            // FramePacer is for continuous GPU frames, not idle demand.
            pacer.beginSleep(io);
            try Io.sleep(io, Io.Duration.fromNanoseconds(pacer_sleep_ns), .real);
            pacer.endSleep(io);
        }

        // Translate SDL input against the last presented tree. Registered
        // task-wake events fall through translation; drainTasks runs below.
        while (true) {
            const raw = blk: {
                if (first_event) |queued| {
                    first_event = null;
                    break :blk queued;
                }
                break :blk host_app.pollEvent() orelse break;
            };
            switch (raw) {
                .quit => {
                    should_close = true;
                    break;
                },
                .window_close_requested => |closing| {
                    if (closing.id == managed.native.id) {
                        should_close = true;
                        break;
                    }
                },
                else => {},
            }
            const host_event = (try host_app.dispatch(&raw)) orelse continue;
            const routed = switch (host_event) {
                .window => |value| value,
                .drop => continue,
                .display, .system_wake => continue,
            };
            if (!std.meta.eql(routed.handle, window_handle)) continue;
            const translated = routed.translated orelse continue;
            switch (translated) {
                .close => should_close = true,
                .resize => |resize| {
                    demand.invalidateLayout();
                    // Layout and input use window units; only the swapchain uses pixels.
                    logical_size = .{
                        .width = resize.core.resize.width,
                        .height = resize.core.resize.height,
                    };
                    gw.notifyResize(.{
                        .width = resize.pixels.width,
                        .height = resize.pixels.height,
                    });
                    _ = try app.handle(resize.core);
                },
                .input => |event| {
                    demand.invalidateLayout();
                    // One route: the App resolves the committed tree, the
                    // phase and the owning component for this event.
                    _ = try app.handle(event);
                },
                .key_down => |key| {
                    demand.invalidateLayout();
                    _ = try app.handle(key.core);
                    if (app.last_input_default_prevented) continue;
                    if (key.repeat) continue;
                    const kc = key.native;
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
                    if (kc == .p and app.dispatchRootPrecisionKey()) continue;
                },
            }
        }
        _ = try app.session.drainTasks();
        try host_app.checkWakeFailure();
        if (should_close) break;
        if (ui.gpu_remount_smoke and !app.currentRootMatches(T, root))
            return error.GpuRemountSmokeRootReplaced;
        demand.setContinuous(app.currentRootMatches(T, root) and
            needsContinuous(T, root, validated_options, audio_player != null));
        if (demand.visible and try app.session.takeRedraw(app.window)) {
            demand.invalidateLayout();
            session_redraw = true;
        }
        const time_ms: u64 = sdl3.timer.getMillisecondsSinceInit();
        try host_preferences.applyReducedMotion(app, time_ms);
        demand.setDeadline(app.animationDemand(time_ms, 16).deadline_ms);
        // A pending chord deadline has to resolve with no SDL input at all:
        // the wait above already counted it, so a deadline that is due here
        // is the one thing this iteration still owes the keymap.
        if (app.nextShortcutWaitMilliseconds() == 0) {
            try app.tickShortcuts();
            demand.invalidateLayout();
        }
        const frame_work = demand.take(time_ms) orelse continue;
        frame_claimed = true;
        if (ui.gpu_remount_smoke) {
            if (!app.currentRootMatches(T, root)) return error.GpuRemountSmokeRootReplaced;
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
        // import the window; the debug_state lives in debug_state.zig).
        debug_state_mod.debug_state = .{
            .subpixel = render_options.subpixel,
            .bgr = render_options.bgr_order,
            .damp = render_options.damp_chroma,
            .quad_debug = render_options.quad_debug,
        };

        // The host clock was sampled at the demand claim. The Surface
        // frame now begins, then App borrows its GPU recording.
        const schedule = gw.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) {
                try Io.sleep(io, Io.Duration.fromMilliseconds(16), .real);
                continue;
            }
            @panic("beginFrame");
        };
        _ = schedule;
        const device_extent = gw.surfaceSize();
        var cmd = gw.commandsBegin();
        var gpu_frame: nogui.GpuFrame = .{
            .endpoint = &gpu_endpoint,
            .command_buffer = &cmd,
            .extent = device_extent,
            .frame_index = frame_index,
            .recording = .{ .active = .{ .context = &gw, .abort = cancelSurfaceRecording } },
        };
        var recording_active = true;
        errdefer if (recording_active) {
            gpu_frame.cancelRecording() catch @panic("surface recording cancellation failed");
        };
        if (last_scene_scale == null or
            !std.meta.eql(last_scene_scale.?.logical, logical_size) or
            !std.meta.eql(last_scene_scale.?.device, device_extent))
        {
            try setScenePixelScale(&text_engine, &svg_scene, &icon_cache, logical_size, device_extent);
            last_scene_scale = .{ .logical = logical_size, .device = device_extent };
        }
        try ensureRenderTarget(
            &gpu,
            &render_target,
            &rt_w,
            &rt_h,
            device_extent.width,
            device_extent.height,
            blit_heap,
        );
        app.dispatchRootFrame(time_ms);
        const out = try app.frameWithGpuAtTime(
            tick,
            time_ms,
            .{ .width = logical_size.width, .height = logical_size.height },
            &gpu_frame,
        );
        if (ui.gpu_remount_smoke) {
            if (!app.currentRootMatches(T, root)) return error.GpuRemountSmokeRootReplaced;
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
            if (!app.currentRootMatches(T, root)) {
                player.deinit();
                audio_player = null;
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

        // The retained scene scratch: an allocation-free lowering per frame,
        // the same lists the perf runner reuses.
        scene_scratch.beginFrame();
        var frame_paint = try frame_scene.buildFrameScene(
            &scene_scratch,
            &text_engine,
            sceneOptions(&svg_scene, &icon_cache),
            &out,
            gpu_sort_verify,
        );
        defer frame_paint.deinit();

        // Pass 1: GUI into the offscreen Oklab target.
        const record_ctx = recordContext(
            &out,
            &gui_renderer,
            &text_engine,
            false,
            logical_size,
            device_extent,
            tex_registry.handle,
        );
        cmd.beginZone(.{ .name = "renderPass1_gpu", .src = @src() });
        _ = try frame_scene.recordFrameScene(
            &record_ctx,
            &cmd,
            &scene_scratch,
            scene_scratch.rects.items,
            &frame_paint,
            render_target,
        );
        cmd.endZone();

        // Barrier: render target color output → fragment shader read.
        cmd.barrier(.{ .color_output = true }, .{ .fragment = true }, .{});

        // Pass 2: blit the Oklab target to the swapchain (converts to sRGB).
        cmd.beginZone(.{ .name = "blit_gpu", .src = @src() });
        recordColorConversion(
            &cmd,
            gw.currentImage(),
            device_extent,
            blit_vert,
            blit_frag,
            blit_heap,
        );
        cmd.endZone();

        const frame_result = try gw.endFrame(.{ .blit_to_swapchain = true });
        gpu_frame.finishRecording();
        recording_active = false;
        _ = frame_result;
        frame_index = (frame_index + 1) % @as(u32, gpu.frames_in_flight);
        managed.markPresented();
        app.framePresented(sdl3.timer.getMillisecondsSinceInit());
        demand.finish(true);
        frame_claimed = false;
        session_redraw = false;

        // Rolling FPS (an EMA over the frame deltas) for the demo header.
        // The unconditional 16ms sleep is GONE. The selected swapchain
        // present mode determines whether presentation waits for a vblank.
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
        // FIFO pacing only measures continuous runs, never a long idle gap.
        if (!uncapped and frame_work.continuous) {
            pacer_sleep_ns = pacer.update(io, gw.slopNs());
        } else {
            pacer_sleep_ns = 0;
        }
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

/// Whether a presented perf run received timing feedback and a refresh estimate.
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

fn drainPerfSetupEvents(host_app: *HostApplication) void {
    while (host_app.pollEvent()) |_| {}
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

fn rejectPerfEvents(host_app: *HostApplication) !void {
    while (host_app.pollEvent()) |event| {
        if (isPerfEventRejected(@tagName(event))) {
            std.log.err("performance run interrupted by {s}", .{@tagName(event)});
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
    host_app: *HostApplication,
    surface: *noapi.Surface,
    submitted_gpu_work: *bool,
    start: Io.Timestamp,
) !void {
    while (true) {
        drainPerfSetupEvents(host_app);
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
        var frame_active = true;
        errdefer if (frame_active) {
            surface.abortFrame() catch @panic("surface recording cancellation failed");
            submitted_gpu_work.* = true;
        };
        if (!std.meta.eql(surface.surfaceSize(), perf_device_extent)) return error.PerfExtentChanged;
        _ = surface.commandsBegin();
        submitted_gpu_work.* = true;
        const frame_result = try surface.endFrame(.{ .blit_to_swapchain = true });
        frame_active = false;
        if (!frame_result.present_out_of_date) {
            drainPerfSetupEvents(host_app);
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
    host_app: *HostApplication,
    surface: *noapi.Surface,
    feedback_buffer: []noapi.PresentFeedback,
    start: Io.Timestamp,
    expected_present_id: u64,
) !PerfPreflightPoll {
    while (true) {
        drainPerfSetupEvents(host_app);
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
    host_app: *HostApplication,
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
        drainPerfSetupEvents(host_app);
        const schedule = surface.beginFrame() catch |err| switch (err) {
            error.OutOfDateKHR => {
                try stabilizePerfSurface(io, host_app, surface, submitted_gpu_work, mode_start);
                continue;
            },
            else => return err,
        };
        _ = schedule;
        var frame_active = true;
        errdefer if (frame_active) {
            surface.abortFrame() catch @panic("surface recording cancellation failed");
            submitted_gpu_work.* = true;
        };
        if (!std.meta.eql(surface.surfaceSize(), perf_device_extent)) return error.PerfExtentChanged;
        _ = surface.commandsBegin();
        submitted_gpu_work.* = true;
        const timing_id = preflight_state.reservedId();
        const frame_result = surface.endFrame(.{
            .blit_to_swapchain = true,
            .timing_id = timing_id,
        }) catch |err| switch (err) {
            error.OutOfDateKHR => {
                try surface.abortFrame();
                frame_active = false;
                try stabilizePerfSurface(io, host_app, surface, submitted_gpu_work, mode_start);
                continue;
            },
            else => return err,
        };
        frame_active = false;
        if (frame_result.present_out_of_date) {
            try stabilizePerfSurface(io, host_app, surface, submitted_gpu_work, mode_start);
            continue;
        }

        const feedback_start = perfNow(io);
        switch (try pollPerfPreflightFeedback(
            io,
            host_app,
            surface,
            feedback_buffer[0..],
            feedback_start,
            timing_id,
        )) {
            .feedback => {
                drainPerfSetupEvents(host_app);
                return try preflight_state.recordedBase();
            },
            .retry => {
                const fallback_id = (try preflight_state.afterUnavailable(true)) orelse unreachable;
                _ = fallback_id;
                mode_start = perfNow(io);
            },
            .unsupported => {
                drainPerfSetupEvents(host_app);
                return null;
            },
            .timeout => return error.PerfTimingFeedbackTimeout,
        }
    }
}

const PerfFeedbackQueue = struct {
    records: [64]noapi.PresentFeedback,
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
                @memmove(
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
    gpu_vendor_id: u32 = 0,
    gpu_device_id: u32 = 0,
    driver: []u8 = &.{},

    fn deinit(self: *PerfMachine, gpa: std.mem.Allocator) void {
        if (self.cpu_model.len != 0) gpa.free(self.cpu_model);
        if (self.online_cpu_set.len != 0) gpa.free(self.online_cpu_set);
        if (self.process_affinity.len != 0) gpa.free(self.process_affinity);
        if (self.kernel.len != 0) gpa.free(self.kernel);
        if (self.cpu_governor) |governor| gpa.free(governor);
        if (self.gpu.len != 0) gpa.free(self.gpu);
        if (self.driver.len != 0) gpa.free(self.driver);
        self.* = undefined;
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
    gpu_vendor_id: u32,
    gpu_device_id: u32,
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

fn capturePerfMachine(
    gpa: std.mem.Allocator,
    io: Io,
    gpu: *const noapi.Gpu,
) !PerfMachine {
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
    machine.cpu_governor = if (readPerfAbsolute(
        gpa,
        io,
        "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor",
    )) |governor| blk: {
        defer gpa.free(governor);
        break :blk try dupeTrimmed(gpa, governor);
    } else |_| null;
    const gpu_identity = gpu.deviceIdentity();
    if (gpu_identity.name.len == 0) return error.PerfMetadataUnavailable;
    if (gpu_identity.driver.len == 0) return error.PerfMetadataUnavailable;
    machine.gpu = try gpa.dupe(u8, gpu_identity.name);
    machine.gpu_vendor_id = gpu_identity.vendor_id;
    machine.gpu_device_id = gpu_identity.device_id;
    machine.driver = try gpa.dupe(u8, gpu_identity.driver);
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
    gpa: std.mem.Allocator,
    io: Io,
    config: perf.Config,
    gpu: *const noapi.Gpu,
    recorder: *const perf.Recorder,
    metadata: PerfRunMetadata,
) !void {
    var machine = try capturePerfMachine(gpa, io, gpu);
    defer machine.deinit(gpa);
    const executable = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(executable);
    var warmup_buffer: [32]u8 = undefined;
    var sample_buffer: [32]u8 = undefined;
    const warmup_text = try std.fmt.bufPrint(&warmup_buffer, "{d}", .{config.warmup_frames});
    const sample_text = try std.fmt.bufPrint(&sample_buffer, "{d}", .{config.sample_frames});
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
        .gpu_vendor_id = machine.gpu_vendor_id,
        .gpu_device_id = machine.gpu_device_id,
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
    app: *App,
    resources: *const PerfResources,
    gpu_frame: *nogui.GpuFrame,
    frame_id: u64,
) !PerfAppFrame {
    ui.fps = 120.0;
    const time_ms = try perfFrameTimeMs(frame_id);
    app.dispatchRootFrame(time_ms);
    const out = try app.frameWithGpuAtTime(
        @intCast(frame_id + 1),
        time_ms,
        .{ .width = resources.logical_size.width, .height = resources.logical_size.height },
        gpu_frame,
    );
    return .{ .out = out };
}

/// The perf runner's per-frame lowering. The scratch is the runner's own
/// retained state: its rects are cleared (capacity kept) and its draw
/// commands keep the reservation `perf_draw_cmd_capacity` set up front, so
/// no sampled frame allocates.
fn buildPerfScene(
    resources: *const PerfResources,
    scratch: *frame_scene.SceneScratch,
    out: *const nogui.FrameOutput,
) !frame_scene.FramePaint {
    scratch.beginFrame();
    return frame_scene.buildFrameScene(
        scratch,
        resources.text_engine,
        sceneOptions(resources.svg_scene, resources.icon_cache),
        out,
        false,
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
    app: *App,
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
    var scene_scratch = frame_scene.SceneScratch.init(resources.gpa, resources.gui_renderer);
    defer scene_scratch.deinit();
    try scene_scratch.draw_cmds.ensureTotalCapacity(resources.gpa, perf_draw_cmd_capacity);

    drainPerfSetupEvents(resources.host_app);
    var frame_id: u64 = 0;
    while (frame_id < total_frames) : (frame_id += 1) {
        try rejectPerfEvents(resources.host_app);
        const phase: perf.Phase = if (frame_id < config.warmup_frames) .warmup else .sample;
        var root_zone = beginPerfRoot(phase);
        defer root_zone.end();

        const slot: usize = @intCast(frame_id % OffscreenSlots.count);
        const slot_reuse_value = perf.slotWaitValue(frame_id, OffscreenSlots.count);
        const slot_wait_start: ?Io.Timestamp = if (slot_reuse_value) |value| blk: {
            const start = perfNow(resources.io);
            try resources.gpu.semaphoreWait(slots.timeline, value);
            break :blk start;
        } else null;
        const app_start = perfNow(resources.io);
        if (comptime v7_options.gpu_timestamps) {
            if (try query_slots.begin(frame_id)) |completed_frame| {
                const query_set = slots.timestamp_queries orelse return error.GpuTimestampUnavailable;
                try attachGpuQueries(resources.gpu, query_set, recorder, completed_frame);
            }
        }
        var cmd = try resources.gpu.commandsBegin();
        var gpu_frame: nogui.GpuFrame = .{
            .endpoint = resources.gpu_endpoint,
            .command_buffer = &cmd,
            .extent = perf_device_extent,
            .frame_index = @intCast(frame_id % OffscreenSlots.count),
            .recording = .{
                .active = .{ .context = resources.gpu, .abort = cancelOffscreenRecording },
            },
        };
        var recording_active = true;
        errdefer if (recording_active) {
            gpu_frame.cancelRecording() catch @panic("offscreen recording cancellation failed");
        };
        if (comptime v7_options.gpu_timestamps) {
            const query_set = slots.timestamp_queries orelse return error.GpuTimestampUnavailable;
            const first: u32 = @intCast(slot * 2);
            try cmd.timestampReset(query_set, first, 2);
            try cmd.timestampWrite(query_set, first, .all_commands_start);
        }
        if (comptime v7_options.perf_counters) resources.counters.reset();
        var app_frame = try buildPerfAppFrame(app, resources, &gpu_frame, frame_id);
        defer if (app_frame.out.json) |json| resources.gpa.free(json);
        const scene_start = perfNow(resources.io);
        var frame_paint = try buildPerfScene(resources, &scene_scratch, &app_frame.out);
        defer frame_paint.deinit();
        const record_start = perfNow(resources.io);
        const mechanism_snapshot = if (comptime v7_options.perf_counters)
            try resources.counters.snapshot()
        else {};
        const perf_record_ctx = recordContext(
            &app_frame.out,
            resources.gui_renderer,
            resources.text_engine,
            false,
            resources.logical_size,
            perf_device_extent,
            resources.tex_registry.handle,
        );
        _ = try frame_scene.recordFrameScene(
            &perf_record_ctx,
            &cmd,
            &scene_scratch,
            scene_scratch.rects.items,
            &frame_paint,
            slots.oklab_targets[slot],
        );
        cmd.barrier(.{ .color_output = true }, .{ .fragment = true }, .{});
        recordColorConversion(
            &cmd,
            slots.srgb_targets[slot],
            perf_device_extent,
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
        const timeline = try perf.submissionTimeline(frame_id);
        if (timeline.wait_value) |wait_value| {
            try queue.submitWaitSignal(
                &.{cmd},
                slots.timeline,
                wait_value,
                slots.timeline,
                timeline.signal_value,
            );
        } else {
            try queue.submitSignal(&.{cmd}, slots.timeline, timeline.signal_value);
        }
        gpu_frame.finishRecording();
        recording_active = false;
        const submit_end = perfNow(resources.io);
        highest_submitted_timeline = timeline.signal_value;

        var sample = perf.FrameSample.empty(phase, frame_id);
        sample.cpu_app_layout_ns = try perfElapsed(app_start, scene_start);
        if (comptime v7_options.perf_counters) sample.mechanisms = mechanism_snapshot;
        sample.cpu_scene_ns = try perfElapsed(scene_start, record_start);
        sample.cpu_record_ns = try perfElapsed(record_start, submit_start);
        sample.cpu_submit_present_ns = try perfElapsed(submit_start, submit_end);
        const slot_wait_ns = if (slot_wait_start) |start|
            try perfElapsed(start, app_start)
        else
            0;
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
    app: *App,
    resources: *const PerfResources,
    config: perf.Config,
    recorder: *perf.Recorder,
    gw: *noapi.Surface,
    blit_heap: noapi.DescriptorHeap,
    refresh_hz: ?f32,
) !PerfRunMetadata {
    const total_frames = try config.totalFrames();
    if (!std.meta.eql(gw.surfaceSize(), perf_device_extent)) return error.PerfExtentChanged;
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
    drainPerfSetupEvents(resources.host_app);
    sdl3.timer.delayMilliseconds(10);
    try stabilizePerfSurface(resources.io, resources.host_app, gw, &submitted_gpu_work, perfNow(resources.io));
    var present_id_base = perf_first_recorded_present_id;
    const preflight_base = try preflightPerfPresentation(
        resources.io,
        resources.host_app,
        gw,
        &submitted_gpu_work,
    );
    var present_feedback_live = false;
    if (preflight_base) |base| {
        present_id_base = base;
        present_feedback_live = true;
    }
    if (!present_feedback_live) {
        try stabilizePerfSurface(resources.io, resources.host_app, gw, &submitted_gpu_work, perfNow(resources.io));
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

    var scene_scratch = frame_scene.SceneScratch.init(resources.gpa, resources.gui_renderer);
    defer scene_scratch.deinit();
    try scene_scratch.draw_cmds.ensureTotalCapacity(resources.gpa, perf_draw_cmd_capacity);
    var query_slots: perf.QuerySlotScheduler = .{};
    var feedback_queue: PerfFeedbackQueue = .{
        // SAFETY: count starts at zero and grows only after each record is written.
        .records = undefined,
    };
    var feedback_buffer: [64]noapi.PresentFeedback = undefined;
    var next_present_frame_id: u64 = 0;
    var frame_id: u64 = 0;
    while (frame_id < total_frames) : (frame_id += 1) {
        if (frame_id == 0) {
            drainPerfSetupEvents(resources.host_app);
        } else {
            try rejectPerfEvents(resources.host_app);
        }
        const phase: perf.Phase = if (frame_id < config.warmup_frames) .warmup else .sample;
        var root_zone = beginPerfRoot(phase);
        defer root_zone.end();

        const acquire_start = perfNow(resources.io);
        _ = try gw.beginFrame();
        var cmd = gw.commandsBegin();
        var gpu_frame: nogui.GpuFrame = .{
            .endpoint = resources.gpu_endpoint,
            .command_buffer = &cmd,
            .extent = perf_device_extent,
            .frame_index = @intCast(frame_id % 3),
            .recording = .{ .active = .{ .context = gw, .abort = cancelSurfaceRecording } },
        };
        var recording_active = true;
        errdefer if (recording_active) {
            gpu_frame.cancelRecording() catch @panic("surface recording cancellation failed");
        };
        if (!std.meta.eql(gw.surfaceSize(), perf_device_extent)) return error.PerfExtentChanged;
        const app_start = perfNow(resources.io);
        if (comptime v7_options.gpu_timestamps) {
            if (try query_slots.begin(frame_id)) |completed_frame| {
                const query_set = timestamp_queries orelse return error.GpuTimestampUnavailable;
                try attachGpuQueries(resources.gpu, query_set, recorder, completed_frame);
            }
        }
        if (comptime v7_options.gpu_timestamps) {
            const query_set = timestamp_queries orelse return error.GpuTimestampUnavailable;
            const first: u32 = @intCast((frame_id % 3) * 2);
            try cmd.timestampReset(query_set, first, 2);
            try cmd.timestampWrite(query_set, first, .all_commands_start);
        }
        if (comptime v7_options.perf_counters) resources.counters.reset();
        var app_frame = try buildPerfAppFrame(app, resources, &gpu_frame, frame_id);
        defer if (app_frame.out.json) |json| resources.gpa.free(json);
        const scene_start = perfNow(resources.io);
        var frame_paint = try buildPerfScene(resources, &scene_scratch, &app_frame.out);
        defer frame_paint.deinit();
        const record_start = perfNow(resources.io);
        const mechanism_snapshot = if (comptime v7_options.perf_counters)
            try resources.counters.snapshot()
        else {};
        const perf_record_ctx = recordContext(
            &app_frame.out,
            resources.gui_renderer,
            resources.text_engine,
            false,
            resources.logical_size,
            perf_device_extent,
            resources.tex_registry.handle,
        );
        _ = try frame_scene.recordFrameScene(
            &perf_record_ctx,
            &cmd,
            &scene_scratch,
            scene_scratch.rects.items,
            &frame_paint,
            render_target,
        );
        cmd.barrier(.{ .color_output = true }, .{ .fragment = true }, .{});
        recordColorConversion(
            &cmd,
            gw.currentImage(),
            perf_device_extent,
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
        gpu_frame.finishRecording();
        recording_active = false;
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
        if (comptime v7_options.perf_counters) sample.mechanisms = mechanism_snapshot;
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
            try rejectPerfEvents(resources.host_app);
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

    // These logical and device extents were captured from the native
    // 2026-09-30 Todo/Spotify shot (both 954x1044 at scale 1). A shot is
    // independent of the compositor and opens no native window.
    const logical_size: nogui.geometry.WindowSize = .{ .width = 954, .height = 1044 };
    const device_extent: noapi.Extent2D = .{ .width = 954, .height = 1044 };

    var io_impl = std.Io.Threaded.init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var quad_vert_f = try ShaderFile.load(gpa, io, "shaders/quad_vert.spv");
    defer quad_vert_f.deinit(gpa);
    var quad_frag_f = try ShaderFile.load(gpa, io, "shaders/quad_frag.spv");
    defer quad_frag_f.deinit(gpa);
    var sort_comp_f = try ShaderFile.load(gpa, io, "shaders/sort_comp.spv");
    defer sort_comp_f.deinit(gpa);
    var system_loader = try v7_frame_mod.SystemVulkanLoader.open();
    defer system_loader.close();
    var offscreen = try v7_frame_mod.Offscreen.init(.{
        .allocator = gpa,
        .io = io,
        .loader = system_loader.options(),
        .extent = device_extent,
        .app_name = "v7-demo",
    });
    defer offscreen.deinit();
    const gpu = offscreen.gpu();

    // Text engine owns FreeType, per-size font states, and the glyph
    // material buffer. Renderer owns the quad shaders and draw buffers.
    // The font bytes stay in the demo; the engine borrows nothing and
    // embeds nothing. The first registered family is the one a node that
    // names no family resolves to.
    var text_engine = try TextEngine.init(gpa, gpu, &.{
        .{ .family = "InterVariable", .bytes = @embedFile("InterVariable.ttf") },
        .{ .family = "Fira Code Nerd Font", .bytes = @embedFile("FiraCodeNerdFont-Regular.ttf") },
    });
    defer text_engine.deinit();
    try text_engine.setGlyphSlotLimit(glyph_material_ceiling);
    app.measure = text_engine.measurer();
    var gui_renderer = try Renderer.init(gpu, quad_vert_f.spv, quad_frag_f.spv, sort_comp_f.spv);
    defer gui_renderer.deinit();
    // The shot lowers exactly one frame; the scratch exists for that frame
    // and dies with it.
    var scene_scratch = frame_scene.SceneScratch.init(gpa, &gui_renderer);
    defer scene_scratch.deinit();
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
    const tex_registry = offscreen.heap();
    ui.texture_idx = try uploadDemoTexture(gpa, gpu, tex_registry);
    try uploadReferenceTexture(gpa, gpu, tex_registry);

    // The reserved showcase box's document (the stroke scene for the
    // TestStrokesApp root, the tiger otherwise) and the transport icons.
    // Both rasterize through librsvg on their first frame, so the one-shot
    // frame records them like every later frame.
    var svg_scene = SvgScene.init(gpa, gpu, tex_registry, sceneDocument(T), sceneDocumentBox(T));
    defer svg_scene.deinit();
    var icon_cache = IconCache.init(gpa, gpu, tex_registry);
    defer icon_cache.deinit();

    configureGpuComponents(T, root, tex_registry.handle);
    try app.attachGpu(offscreen.endpoint());
    defer app.detachGpu();
    const initial_resize: Event = .{ .resize = .{
        .width = logical_size.width,
        .height = logical_size.height,
    } };
    _ = try app.handle(initial_resize);

    // Sync the toggle state BEFORE the frame builds the tree: the shot's
    // header status line reads debug_state, so a late sync would stamp the
    // PREVIOUS frame's toggles onto this shot. Same order as run()'s loop.
    debug_state_mod.debug_state = .{
        .subpixel = render_options.subpixel,
        .bgr = render_options.bgr_order,
        .damp = render_options.damp_chroma,
        .quad_debug = render_options.quad_debug,
    };

    // The shot lays out in window units, then reads back physical pixels.
    std.log.info("shot dimensions: logical={d}x{d} device={d}x{d}", .{
        logical_size.width,
        logical_size.height,
        device_extent.width,
        device_extent.height,
    });
    try setScenePixelScale(&text_engine, &svg_scene, &icon_cache, logical_size, device_extent);
    // SAFETY: `beginFrame` writes both out-parameters before either is read,
    // and the recording guard below reads only what it filled in.
    var cmd: noapi.CommandBuffer = undefined;
    // SAFETY: the same out-parameter, filled by the same `beginFrame` call.
    var gpu_frame: nogui.GpuFrame = undefined;
    try offscreen.beginFrame(0, &cmd, &gpu_frame);
    errdefer if (gpu_frame.recording == .active) {
        gpu_frame.cancelRecording() catch @panic("offscreen recording cancellation failed");
    };
    app.dispatchRootFrame(1200);
    var out = try app.frameWithGpuAtTime(
        1,
        1200,
        .{ .width = logical_size.width, .height = logical_size.height },
        &gpu_frame,
    );
    defer if (out.json) |j| gpa.free(j);

    // Static shot: the hover ring renders at full alpha when a node is
    // hovered (no easing in a one-frame shot); 0 otherwise.
    out.pressed = null;
    out.press_alpha = 0;
    out.hover = if (hover) |p| blk: {
        var frame_id = hitTest(out.tree, p) orelse break :blk null;
        for (0..out.tree.nodes.items.len) |_| {
            const node = out.tree.nodeConst(frame_id) orelse break :blk null;
            if (node.widget_id) |widget_id| break :blk widget_id;
            if (frame_id == .root) break :blk null;
            frame_id = node.parent;
        }
        break :blk null;
    } else null;
    out.hover_alpha = if (out.hover != null) 1 else 0;
    out.focus = null;

    scene_scratch.beginFrame();
    var frame_paint = try frame_scene.buildFrameScene(
        &scene_scratch,
        &text_engine,
        sceneOptions(&svg_scene, &icon_cache),
        &out,
        gpu_sort_verify,
    );
    defer frame_paint.deinit();

    const shot_record_ctx = recordContext(
        &out,
        &gui_renderer,
        &text_engine,
        gpu_sort_verify,
        logical_size,
        device_extent,
        tex_registry.handle,
    );
    const verified_rects = try frame_scene.recordFrameScene(
        &shot_record_ctx,
        &cmd,
        &scene_scratch,
        scene_scratch.rects.items,
        &frame_paint,
        offscreen.target(),
    );
    const pixels = try offscreen.submitRead(&gpu_frame);

    // --gpu-sort-verify: the REVERSED bag must produce the paint-order
    // permutation. Read the sort's output back and check it against a
    // CPU-side stable (z, order) reference — the assertion the flag is
    // about (the runShot itself is the pixel-level check).
    if (gpu_sort_verify) {
        const n = verified_rects.len;
        const perm_rb = try gpu.gpuMalloc(@as(u64, n) * @sizeOf(u32), 64, .readback);
        defer gpu.gpuFree(perm_rb);
        var cmd2 = try gpu.commandsBegin();
        var command_pending = true;
        errdefer if (command_pending) {
            gpu.commandsCancel(&cmd2) catch @panic("offscreen recording cancellation failed");
        };
        cmd2.memCopy(perm_rb, gui_renderer.permutationBuffer(), @as(u64, n) * @sizeOf(u32));
        try gpu.queueSubmit(&.{cmd2});
        command_pending = false;
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
        std.sort.insertion(u32, ref, RectSort{ .rects = verified_rects }, RectSort.lessThan);
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
                .{ i, got[i], ref[i], verified_rects[ref[i]].z, verified_rects[ref[i]].order },
            );
            return error.GpuSortVerifyMismatch;
        }
        std.log.info("gpu-sort-verify: permutation matches the stable (z, order) reference ({d} drawables)", .{n});
    }

    // Convert Oklab floats → sRGB bytes and write the PPM.
    try v7_frame_mod.writePpm(gpa, io, path, pixels, device_extent);
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
    var queue: PerfFeedbackQueue = .{
        .records = undefined,
    };
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
