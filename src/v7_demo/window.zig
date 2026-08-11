//! v7 demo window backend — SDL3 + noapi Vulkan rendering for the v7 tree,
//! through v4's text/glyph pipeline: Batch9Slice + FreeType glyph materials,
//! rendered into an offscreen Oklab float target, then blitted to the
//! swapchain with the Oklab→sRGB conversion shader.
//!
//! Demo-side code (imports std, sdl3, noapi AND the pure v7 module via the
//! `v7` symlink in this directory — same convention as ui.zig, so this file
//! stays standalone-compilable). The v7 module itself never sees sdl3/noapi.
//!
//! Flow per frame: app.frame builds + lays out the tree and serializes it to
//! JSON (freed here); collectDrawCmds flattens the tree into paint-ordered
//! DrawCmds; buildSliceRects turns each cmd into a SceneRect — solid cmds
//! use material slot 0, radius-bearing fills and border rings use per-cmd
//! rounded-rect materials (type 2) written into the engine's material
//! buffer; label-bearing nodes additionally emit one glyph SceneRect per
//! character via TextEngine (FreeType); Batch9Slice expands the rects into
//! one indexed draw into the offscreen Oklab target; a barrier transitions
//! the target to shader-read; the blit pass samples it and writes sRGB to
//! the swapchain. Mouse clicks hit-test the same frame's tree and dispatch
//! back into the app (mutations apply on the next frame).
//!
//! `runShot` renders a single frame into the offscreen target, copies it back
//! to a readback buffer and writes a P6 PPM — the text-renders proof.

const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const vk = noapi.vk;
const Io = std.Io;

const App = @import("v7/app.zig").App;
const tracy = @import("tracy");
const Id = @import("v7/id.zig").Id;
const DrawCmd = @import("v7/drawcmd.zig").DrawCmd;
const WidgetTree = @import("v7/widget.zig").WidgetTree;
const Rect = @import("v7/widget.zig").Rect;
const ClipRect = @import("v7/widget.zig").ClipRect;
const absoluteRect = @import("v7/widget.zig").absoluteRect;
const contentRect = @import("v7/widget.zig").contentRect;
const collectDrawCmds = @import("v7/drawcmd.zig").collectDrawCmds;
const MouseButton = @import("v7/event.zig").MouseButton;
const Key = @import("v7/event.zig").Key;
const hitTest = @import("v7/input.zig").hitTest; // runShot's forced --hover
const Batch9Slice = @import("proto/render_9slice.zig").Batch9Slice;
const SceneRect = @import("proto/render_9slice.zig").SceneRect;
const BatchClipRect = @import("proto/render_9slice.zig").ClipRect;
const TextEngine = @import("text.zig").TextEngine;
const text_mod = @import("text.zig");
const svg_xml = @import("svg_xml.zig");
const SvgView = @import("svg_view.zig").SvgView;
const MAX_MATERIALS = @import("text.zig").MAX_MATERIALS;
const FONT_SIZE_PX = @import("text.zig").FONT_SIZE_PX;
const proto = @import("proto/sweeper.zig");
const srgbToOklab = @import("text.zig").srgbToOklab;
const ui = @import("ui.zig"); // for the demo texture index (texture_idx)

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

/// The mandelbrot box's absolute border rect (the node whose fill carries the
/// mandelbrot texture). The driver hit-tests it for the pan/zoom interaction.
fn mandelbrotRect(tree: *const WidgetTree, idx: ?u32) Rect {
    for (tree.nodes.items) |n| {
        if (idx != null and n.box.texture == idx) return absoluteRect(tree, n.id);
    }
    return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
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
            if (n.id == id) return .{ .rect = contentRect(tree, id), .layer = n.box.layer };
        }
    }
    return .{ .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .layer = 0 };
}

/// Parse the embedded tiger + convert it into the renderer's SvgView
/// (per-path conics + glyph materials + scene rects). The materials are
/// written into the shared text-engine buffer at the SVG region — the
/// batch draws everything with that one material BDA.
fn initSvgView(gpu: *noapi.Gpu, gpa: std.mem.Allocator, text_engine: *TextEngine) !SvgView {
    const tiger_xml = @embedFile("tiger.svg");
    var doc = try svg_xml.parseSvg(gpa, tiger_xml);
    defer doc.deinit();
    const v = try SvgView.init(gpu, gpa, &doc, text_engine.materials, text_engine.materialBda(), SVG_MATERIAL_BASE);
    return v;
}

/// The stroke test scene: curved thin strokes at increasing widths. The
/// stroke algo + oversize sliders drive the shader; the scale slider
/// zooms the whole scene.
fn initStrokeView(gpu: *noapi.Gpu, gpa: std.mem.Allocator, text_engine: *TextEngine) !SvgView {
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
    const v = try SvgView.init(gpu, gpa, &doc, text_engine.materials, text_engine.materialBda(), SVG_MATERIAL_BASE);
    return v;
}

/// In-flight pan (drag) state: the mouse position + the center at the grab.
const MandelDrag = struct {
    mouse: [2]f32,
    center: [2]f64,
};

/// Pan/zoom the mandelbrot by a mouse drag + wheel. The pan divides by the
/// DISPLAYED pixels-per-unit (the texture_scale scaled by the box/texture
/// ratio — the 512px texture is drawn in a narrower box, so the texture's
/// own scale would make the content lag the mouse); the wheel zooms the
/// texture_scale exponentially (no maximum — the user can zoom arbitrarily
/// deep), clamped only at a small minimum so the view can't invert.
fn applyMandelbrot(drag: ?*?MandelDrag, pos: [2]f32, wheel_y: f32, rect: Rect, scale: f64) void {
    if (drag) |d| {
        if (d.*) |st| {
            // Grab the content 1:1 in SCREEN space: the complex-plane delta
            // per pixel differs per axis because the mandelbrot texture is
            // 4:3 (512x384) but its box may be a different aspect — a single
            // width-derived scale makes the y pan wrong. Each axis divides
            // by ITS OWN display scale (px-per-unit: rect.{w,h} shows
            // MANDEL_{W,H}/scale units).
            const s_x = scale * @as(f64, rect.w / @as(f32, MANDEL_W));
            const s_y = scale * @as(f64, rect.h / @as(f32, MANDEL_H));
            ui.mandelbrot_center[0] = st.center[0] - @as(f64, pos[0] - st.mouse[0]) / s_x;
            ui.mandelbrot_center[1] = st.center[1] - @as(f64, pos[1] - st.mouse[1]) / s_y;
        }
    }
    if (wheel_y != 0) {
        const k: f64 = 0.05;
        ui.mandelbrot_scale = @max(ui.mandelbrot_scale * @exp(@as(f64, wheel_y) * k), 10);
    }
}

/// Convert window-logical mouse coordinates (SDL event space) to surface
/// pixels (the layout space): scale by the surface/window size ratio.
/// Identity when the window is not scaled; correct on HiDPI displays.
fn toSurfacePoint(sdl_win: sdl3.video.Window, gw: *noapi.Surface, p: [2]f32) ![2]f32 {
    const win_size = try sdl_win.getSize();
    const surface_size = gw.surfaceSize();
    return .{
        p[0] * @as(f32, @floatFromInt(surface_size.width)) / @as(f32, @floatFromInt(win_size[0])),
        p[1] * @as(f32, @floatFromInt(surface_size.height)) / @as(f32, @floatFromInt(win_size[1])),
    };
}

/// The modern dark canvas: the Oklab L≈0.20 neutral with a whisper of blue
/// (b < 0) — the deepest surface the cards sit on. Clears the offscreen
/// target.
const OKLAB_GRAY = [4]f32{ 0.20, 0.0, -0.008, 1.0 };

/// The SVG view's material slots own the TOP region of the shared
/// material buffer: [SVG_MATERIAL_BASE, MAX_MATERIALS). The tiger has
/// ≤240 fill paths + up to 78 stroked paths (a slot each); the per-frame
/// decorations descend from SVG_MATERIAL_BASE. The glyphs (from slot 1
/// upward) must stay below SVG_MATERIAL_BASE — the demo's ~620 glyphs
/// fit with headroom.
const SVG_MATERIAL_BASE: u32 = MAX_MATERIALS - 512;

/// A shader file read from disk: owns the byte buffer, exposes the SPIR-V
/// word slice (shaderCreate copies the module, so the bytes only need to
/// outlive shaderCreate).
const ShaderFile = struct {
    bytes: []u8,
    spv: []const u32,

    fn load(io: Io, gpa: std.mem.Allocator, path: []const u8) !ShaderFile {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        errdefer gpa.free(bytes);
        const spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, bytes));
        return .{ .bytes = bytes, .spv = spv };
    }

    fn deinit(self: *ShaderFile, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
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
        .format = .rgba32_float,
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
/// binds the heap with ONE cmd.bindDescriptorSets before batch.draw —
/// bindings are not draws, so the one-draw invariant holds. The fragment
/// shader samples textures[NonUniformResourceIndex(tex_idx)] (set 0
/// binding 0) with samplers[0] (set 2 binding 0); descHeapSetTextures
/// writes each registration's image-view descriptor at its index.
/// descHeapCreate's requested counts are capacity hints — the backend
/// forces the pool to max_textures/max_samplers either way.
const TextureRegistry = struct {
    gpu: *noapi.Gpu,
    heap: noapi.DescriptorHeap,
    /// Next free heap slot (the registry is append-only this pass).
    next_idx: u32 = 0,
    /// The app's texture handle → heap index.
    map: std.AutoHashMapUnmanaged(noapi.TextureHandle, u32) = .empty,

    fn init(gpu: *noapi.Gpu, gpa: std.mem.Allocator) !@This() {
        _ = gpa; // the unmanaged map allocates lazily at register time
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
        return .{ .gpu = gpu, .heap = heap };
    }

    fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        // The registry owns the registered textures (created by the demo
        // setup, alive for the whole run).
        var it = self.map.keyIterator();
        while (it.next()) |h| self.gpu.textureDestroy(h.*);
        self.map.deinit(gpa);
        self.gpu.descHeapDestroy(self.heap);
    }

    /// Register a texture: write its view descriptor into the heap at a
    /// stable index (returned) — descHeapSetTextures, once per texture.
    /// Idempotent: a handle already registered returns its index.
    fn register(self: *@This(), gpa: std.mem.Allocator, tex: noapi.TextureHandle) !u32 {
        if (self.map.get(tex)) |idx| return idx;
        const idx = self.next_idx;
        self.next_idx += 1;
        const desc = self.gpu.textureViewDescriptor(tex, .{ .format = .default });
        self.gpu.descHeapSetTextures(self.heap, idx, &.{desc});
        try self.map.put(gpa, tex, idx);
        return idx;
    }

    /// Register a STORAGE-capable texture for both bindless paths: the
    /// sampled view (set 0, for the GUI fragment shader) via register(),
    /// plus the storage view (set 1, for the compute shader) via
    /// descHeapSetTexturesRw. Returns the SAMPLED index (the one the GUI
    /// draws with). The storage descriptor goes at FIXED set-1 index 0:
    /// mandelbrot.comp.slang declares a non-arrayed RWTexture2D at set 1
    /// binding 0 (the same convention as the sweep compute demo), so it
    /// sees element 0 only — set-1 indices are independent of the set-0
    /// indices. Plain register() textures (the demo stripe) are NOT
    /// storage-capable and never write a set-1 descriptor.
    fn registerWithStorage(self: *@This(), gpa: std.mem.Allocator, tex: noapi.TextureHandle) !u32 {
        const idx = try self.register(gpa, tex);
        const rw_desc = self.gpu.textureRwViewDescriptor(tex, .{ .format = .default });
        self.gpu.descHeapSetTexturesRw(self.heap, 0, &.{rw_desc});
        return idx;
    }
};

/// Mandelbrot compute pass (Part A): a 512x384 rgba32_float render target
/// written by mandelbrot.comp.slang (storage view) and sampled by the GUI
/// (sampled view). Created once per run()/runShot(); the texture is
/// registered in the GUI heap for BOTH bindless paths and is then OWNED by
/// the registry (destroyed with it). The params buffer is host-visible
/// (.default = host_coherent, like the material buffers) and rewritten
/// every frame before the dispatch — same pattern as the per-frame
/// material writes, so no flush is needed.
const MANDEL_W: u32 = 512;
const MANDEL_H: u32 = 384;
const MANDEL_MAX_ITER: u32 = 256;

/// The compute params, written verbatim into the host-visible buffer.
/// Layout MUST match MandelParams in shaders/mandelbrot.comp.slang
/// (std430 — vk::BufferPointer target): float2 center @0, scale @8,
/// time @12, max_iter @16, then uint2 size at @24 (std430 aligns vec2 to
/// 8 bytes, so there is a 4-byte pad after max_iter — mirrored here as an
/// explicit field). 32 bytes total.
const MandelParams = extern struct {
    size: [2]u32, // @0 — the uint2 first so it is 8-aligned (the std430 block layout)
    center: [2]f64, // @8 — f64 for the deep-zoom precision + the runtime switch
    scale: f64, // @24
    time: f32, // @32
    max_iter: u32, // @36
    precision: u32, // @40 — 0 f32, 1 f64, 2 adaptive
};

const MandelbrotPass = struct {
    shader: noapi.Shader,
    params_buf: noapi.GpuPtr,
    params_bda: u64,

    fn init(gpu: *noapi.Gpu, io: Io, gpa: std.mem.Allocator, registry: *TextureRegistry) !MandelbrotPass {
        // Storage + sampled usage: the compute writes it (set 1 storage
        // view), the GUI samples it (set 0 sampled view). textureCreate
        // forces transfer_dst and transitions to GENERAL — the layout both
        // descriptor types use.
        const tex = try gpu.textureCreate(.{
            .dimensions = .{ MANDEL_W, MANDEL_H, 1 },
            .format = .rgba32_float,
            .usage = .{ .sampled = true, .storage = true },
        });
        errdefer gpu.textureDestroy(tex);

        var shader_f = try ShaderFile.load(io, gpa, "shaders/mandelbrot_comp.spv");
        defer shader_f.deinit(gpa);
        const shader = try gpu.shaderCreate(shader_f.spv, .compute, "main", "mandelbrot_comp");
        errdefer gpu.shaderDestroy(shader);

        const params_buf = try gpu.gpuMalloc(@sizeOf(MandelParams), 64, .default);
        errdefer gpu.gpuFree(params_buf);

        // Register LAST: after this the registry owns the texture (its
        // deinit destroys it), so no errdefer may fire past this point.
        ui.mandelbrot_idx = try registry.registerWithStorage(gpa, tex);
        return .{ .shader = shader, .params_buf = params_buf, .params_bda = params_buf.gpu };
    }

    fn deinit(self: *MandelbrotPass, gpu: *noapi.Gpu) void {
        gpu.gpuFree(self.params_buf);
        gpu.shaderDestroy(self.shader);
    }
};

/// Record the mandelbrot compute pass into `cmd`, BEFORE the GUI pass:
/// rewrite the params (center/scale from the demo globals — the
/// pan/zoom/animation knobs — plus the frame time for the hue shift),
/// bind the GUI texture heap (set 1 = the storage image at fixed index 0),
/// dispatch MANDEL_W/8 x MANDEL_H/8 groups, then a compute→fragment
/// barrier so the GUI pass's sampled read sees the fresh fractal. The
/// image stays in GENERAL layout throughout (textureCreate + the heap
/// descriptors), so the barrier is access-only — no layout transition.
fn recordMandelbrot(cmd: *noapi.CommandBuffer, pass: *const MandelbrotPass, heap: noapi.DescriptorHeap, time_ms: u64) void {
    const zone = tracy.Zone.begin(.{ .name = "mandelbrot", .src = @src() });
    defer zone.end();
    const params: *MandelParams = @ptrCast(@alignCast(pass.params_buf.cpu));
    params.* = .{
        .size = .{ MANDEL_W, MANDEL_H },
        .center = ui.mandelbrot_center,
        .scale = ui.mandelbrot_scale,
        .time = @as(f32, @floatFromInt(time_ms)) / 1000.0,
        .max_iter = MANDEL_MAX_ITER,
        .precision = ui.mandelbrot_precision,
    };
    cmd.setComputeShader(pass.shader);
    cmd.bindDescriptorSets(heap);
    cmd.dispatch(pass.params_bda, MANDEL_W / 8, MANDEL_H / 8, 1);
    cmd.barrier(.{ .compute = true }, .{ .fragment = true }, .{});
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
const DEMO_TEX_SIZE = 64;

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
    for (0..DEMO_TEX_SIZE) |y| {
        for (0..DEMO_TEX_SIZE) |x| {
            const c = stripes[x / stripe_w];
            pixels[(y * DEMO_TEX_SIZE + x) * 4 + 0] = c[0];
            pixels[(y * DEMO_TEX_SIZE + x) * 4 + 1] = c[1];
            pixels[(y * DEMO_TEX_SIZE + x) * 4 + 2] = c[2];
            pixels[(y * DEMO_TEX_SIZE + x) * 4 + 3] = c[3];
        }
    }
}

/// Create the demo texture (64x64 rgba32_float, one-shot upload via the
/// noapi path: textureCreate + cmdCopyToTexture from a host-visible
/// staging buffer), register it in the GUI texture heap and return its
/// heap index (tex_idx). The texture's OWNED by the registry (destroyed
/// with it).
fn uploadDemoTexture(gpu: *noapi.Gpu, registry: *TextureRegistry, gpa: std.mem.Allocator) !u32 {
    const tex = try gpu.textureCreate(.{
        .dimensions = .{ DEMO_TEX_SIZE, DEMO_TEX_SIZE, 1 },
        .format = .rgba32_float,
        .usage = .{ .sampled = true },
    });
    errdefer gpu.textureDestroy(tex);

    const bytes: u64 = DEMO_TEX_SIZE * DEMO_TEX_SIZE * 4 * @sizeOf(f32);
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
        .dimensions = .{ DEMO_TEX_SIZE, DEMO_TEX_SIZE, 1 },
        .format = .rgba32_float,
    }, buf, .{ .size = .{ DEMO_TEX_SIZE, DEMO_TEX_SIZE, 1 } });
    try gpu.queueSubmit(&.{cmd});
    gpu.commandsEnd(cmd);
    try gpu.waitIdle();

    return registry.register(gpa, tex);
}

/// The tiger demo's reference render: the rsvg-rendered tiger (a raw
/// RGBA8 blob, 512×512, generated at build time from tiger.svg) uploaded
/// as an rgba32_float texture and registered (ui.tiger_ref_idx) for the
/// sampler-only TYPE_TEXTURE path.
const TIGER_REF_SIZE = 512;
fn uploadReferenceTexture(gpu: *noapi.Gpu, registry: *TextureRegistry, gpa: std.mem.Allocator) !void {
    const tex = try gpu.textureCreate(.{
        .dimensions = .{ TIGER_REF_SIZE, TIGER_REF_SIZE, 1 },
        .format = .rgba32_float,
        .usage = .{ .sampled = true },
    });
    errdefer gpu.textureDestroy(tex);

    const bytes: u64 = TIGER_REF_SIZE * TIGER_REF_SIZE * 4 * @sizeOf(f32);
    const buf = try gpu.gpuMalloc(bytes, 64, .default);
    defer gpu.gpuFree(buf);
    const src = @embedFile("tiger_ref.rgba");
    // The pipeline outputs Oklab (the blit converts to sRGB), so the
    // texture's pixels must be Oklab — the sRGB RGBA8 reference converts
    // per pixel here, exactly like the procedural demo texture's authoring.
    for (0..TIGER_REF_SIZE * TIGER_REF_SIZE) |pix| {
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
        .dimensions = .{ TIGER_REF_SIZE, TIGER_REF_SIZE, 1 },
        .format = .rgba32_float,
    }, buf, .{ .size = .{ TIGER_REF_SIZE, TIGER_REF_SIZE, 1 } });
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
/// 4. Every label-bearing node (label/button/slider) emits one glyph
///    SceneRect per character at the node's ABSOLUTE content box
///    (x = content.x, baseline = the font-derived baseline), appended
///    LAST so text paints on top of every widget decoration.
fn buildSliceRects(
    text_engine: *TextEngine,
    svg_view: ?*SvgView,
    cmds: []const DrawCmd,
    tree: *const WidgetTree,
    hover_id: ?Id,
    hover_alpha: f32,
    focus_id: ?Id,
    out: *std.ArrayList(SceneRect),
    gpa: std.mem.Allocator,
) !void {
    const zone = tracy.Zone.begin(.{ .name = "buildSliceRects", .src = @src() });
    defer zone.end();
    // Rounded-rect material slots, allocated from the top of the buffer
    // downward (glyphs own slots 1..next_slot-1 from the bottom; the
    // assert in text.zig caps glyphs well below the top). The SVG view's
    // materials own the TOP region [SVG_MATERIAL_BASE, MAX_MATERIALS) —
    // the decorations descend from SVG_MATERIAL_BASE, never into the
    // tiger's slots.
    var material_slot: u32 = SVG_MATERIAL_BASE;
    // Guard the decoration writes against the LIVE glyph count: glyph
    // slots ascend from slot 1 as the frame's text is rasterized, so the
    // headroom below is next_slot, not 1. With `> 1` a burst of
    // decorations could silently write into in-flight glyph material;
    // with the live count the assert fires instead.
    const glyph_slots = text_engine.glyphSlotCount();

    for (cmds) |cmd| {
        const b = cmd.box;
        const corner_l: f32 = if (cmd.ring) b.radius.left else @max(0, b.radius.left - b.border.left);
        const corner_r: f32 = if (cmd.ring) b.radius.right else @max(0, b.radius.right - b.border.right);
        const corner_t: f32 = if (cmd.ring) b.radius.top else @max(0, b.radius.top - b.border.top);
        const corner_b: f32 = if (cmd.ring) b.radius.bottom else @max(0, b.radius.bottom - b.border.bottom);

        // Rounded-rect material geometry: one radius per axis (the SDF
        // rounds all four corners; demo boxes use uniform radii). Rings
        // always need the ring material (their interior is punched out);
        // fills need one only when they carry a radius.
        const rx: f32 = @max(corner_l, corner_r);
        const ry: f32 = @max(corner_t, corner_b);
        const border: f32 = if (cmd.ring)
            @max(@max(b.border.left, b.border.right), @max(b.border.top, b.border.bottom))
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
        if (cmd.shadow > 0) {
            // Shadow cmd: feathered rounded-rect material (type 3). The
            // shader fades the coverage over feather/2 px BEYOND the SDF
            // edge — so the quad must be expanded by the feather on every
            // side or the fade is clipped at the quad boundary (the old
            // quad was exactly the widget's rect: shadows rendered as a
            // ~1px line). The material's win_w/h stay the WIDGET's size
            // (the SDF's rect) and the origin stays its top-left; only the
            // rasterized quad grows.
            slice_corner_l = b.radius.left;
            slice_corner_r = b.radius.right;
            slice_corner_t = b.radius.top;
            slice_corner_b = b.radius.bottom;
            const shadow_rx: f32 = @max(b.radius.left, b.radius.right);
            const shadow_ry: f32 = @max(b.radius.top, b.radius.bottom);
            const feather = cmd.shadow;
            std.debug.assert(material_slot > glyph_slots); // never reach the live glyph slots
            material_slot -= 1;
            proto.GlyphSweeper.writeShadowMaterial(text_engine.materials, material_slot, shadow_rx, shadow_ry, feather, cmd.rect.w, cmd.rect.h);
            material_index = material_slot;
            try out.append(gpa, .{
                .dst = .{ cmd.rect.x - feather, cmd.rect.y - feather, cmd.rect.w + 2 * feather, cmd.rect.h + 2 * feather },
                .src = .{ 0, 0, 1, 1 },
                .corners = .{ slice_corner_l, slice_corner_r, slice_corner_t, slice_corner_b },
                .color = srgbToOklab(cmd.color),
                .curve = .{ 0, 0, 0, 0 },
                .material_index = material_index,
                .clip_id = cmd.clip_id,
                .origin = .{ cmd.rect.x, cmd.rect.y },
                .tex_idx = cmd.tex_idx,
                .z = cmd.layer,
            });
            continue;
        } else if (cmd.ring or rx > 0 or ry > 0) {
            std.debug.assert(material_slot > glyph_slots); // never reach the live glyph slots
            material_slot -= 1;
            // Ring materials always carry the ring's gradient (the demo sets
            // none); fills carry one only when the gradient flag is set.
            const gradient: [4]f32 = if (cmd.ring or cmd.gradient[3] > 0) cmd.gradient else .{ 0, 0, 0, 0 };
            proto.GlyphSweeper.writeRoundedRectMaterial(text_engine.materials, material_slot, rx, ry, border, cmd.rect.w, cmd.rect.h, gradient);
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
            .z = cmd.layer,
        });
    }

    // Slider thumbs: a rounded bar at the value fraction, painted BEFORE
    // the glyphs so the thumb never covers the slider's own label.
    for (tree.nodes.items) |*n| {
        if (n.kind != .slider) continue;
        const s = n.kind.slider;
        const r = absoluteRect(tree, n.id);
        if (r.w <= 0 or r.h <= 0) continue;
        // A max <= min slider has no valid range: 0/0 (or overflow) would
        // yield NaN/inf and poison the thumb rect. Center the thumb instead.
        const range = s.max - s.min;
        const frac = std.math.clamp(if (range <= 0) 0.5 else (s.value.* - s.min) / range, 0, 1);
        const thumb_w: f32 = 10;
        const thumb_x = r.x + frac * @max(0, r.w - thumb_w);
        const thumb_radius: f32 = 3;
        std.debug.assert(material_slot > glyph_slots);
        material_slot -= 1;
        proto.GlyphSweeper.writeRoundedRectMaterial(text_engine.materials, material_slot, thumb_radius, thumb_radius, 0, thumb_w, r.h, .{ 0, 0, 0, 0 });
        try out.append(gpa, .{
            .dst = .{ thumb_x, r.y, thumb_w, r.h },
            .src = .{ 0, 0, 1, 1 },
            .corners = .{ thumb_radius, thumb_radius, thumb_radius, thumb_radius },
            .color = srgbToOklab(.{ 0.82, 0.82, 0.85, 1 }),
            .curve = .{ 0, 0, 0, 0 },
            .material_index = material_slot,
            .clip_id = n.clip_id,
            .origin = .{ thumb_x, r.y },
        });
    }

    // Hover outline: a 2px rounded ring around the hovered node (type-2
    // ring material — the SDF punches the interior), painted before the
    // glyphs so it never overdraws the text at the box edges.
    if (hover_id) |hid| {
        for (tree.nodes.items) |*n| {
            if (n.id != hid) continue;
            const r = absoluteRect(tree, n.id);
            if (r.w <= 0 or r.h <= 0) break;
            const ring_rx: f32 = @max(n.box.radius.left, n.box.radius.right);
            const ring_ry: f32 = @max(n.box.radius.top, n.box.radius.bottom);
            std.debug.assert(material_slot > glyph_slots);
            material_slot -= 1;
            proto.GlyphSweeper.writeRoundedRectMaterial(text_engine.materials, material_slot, ring_rx, ring_ry, 2, r.w, r.h, .{ 0, 0, 0, 0 });
            try out.append(gpa, .{
                .dst = .{ r.x, r.y, r.w, r.h },
                .src = .{ 0, 0, 1, 1 },
                .corners = .{ n.box.radius.left, n.box.radius.right, n.box.radius.top, n.box.radius.bottom },
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
            const r = absoluteRect(tree, n.id);
            if (r.w <= 0 or r.h <= 0) break;
            const ring_rx: f32 = @max(n.box.radius.left, n.box.radius.right);
            const ring_ry: f32 = @max(n.box.radius.top, n.box.radius.bottom);
            std.debug.assert(material_slot > glyph_slots);
            material_slot -= 1;
            proto.GlyphSweeper.writeRoundedRectMaterial(text_engine.materials, material_slot, ring_rx, ring_ry, 2, r.w, r.h, .{ 0, 0, 0, 0 });
            try out.append(gpa, .{
                .dst = .{ r.x, r.y, r.w, r.h },
                .src = .{ 0, 0, 1, 1 },
                .corners = .{ n.box.radius.left, n.box.radius.right, n.box.radius.top, n.box.radius.bottom },
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
            .slider => |s| s.label,
            else => null,
        };
        const t = text orelse continue;
        if (t.len == 0) continue;
        const content = contentRect(tree, n.id);
        if (content.w == 0 or content.h == 0) continue;
        const size: u32 = if (n.font_size > 0) @intFromFloat(@round(n.font_size)) else FONT_SIZE_PX;
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
        const before = out.items.len;
        try text_engine.emitText(t, content.x, baseline_y, size, n.font_id, n.clip_id, srgbToOklab(text_color), out);
        if (n.box.layer > 0) {
            for (out.items[before..]) |*r| r.z = n.box.layer;
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
            sv.setStrokeStyle(@intFromFloat(ui.stroke_algo), ui.stroke_oversize);
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
            // std.log.info("svg: card=({d:.0},{d:.0},{d:.0},{d:.0}) scale={d:.3}", .{ card_rect.x, card_rect.y, card_rect.w, card_rect.h, scale });
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
/// fragment shader samples) — bound ONCE per frame before the batch draw;
/// the blit pass binds its own heap later.
fn renderPass1(
    batch: *Batch9Slice,
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

    // CS1 (V1b) FIRST, outside the render pass: upload the drawable bag,
    // dispatch the stable radix sort, barrier compute → graphics. Compute
    // cannot run inside dynamic rendering, so the batch's sort/draw split
    // mirrors the pass structure.
    const proto_rects: []const BatchClipRect = @ptrCast(clip_rects);
    try batch.sort(cmd, slice_rects, proto_rects);

    cmd.beginRendering(.{ .color_attachments = &.{
        .{ .texture = render_target, .load_op = .clear, .store_op = .store, .clear_color = OKLAB_GRAY },
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
    // The tree's ClipRect and the batch's are layout-identical (4 f32);
    // the batch defines its own to avoid the module-identity split.
    batch.draw(cmd, sw, sh);
    cmd.setBlendEnable(false);
    cmd.endRendering();
}

/// Run the graphical demo. Blocks until the window closes.
/// Generic over the root component (any type with pub draw(self, ctx) !void).
pub fn run(app: *App, comptime T: type, root: *T, subpixel: bool, quad_debug: bool, bgr: bool, damp: bool, gpu_sort_verify: bool, max_frames: ?u32) !void {
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

    // Vulkan loader via SDL3.
    try sdl3.vulkan.loadLibrary(null);
    const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();
    const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
    exts_copy_global = try gpa.dupe([*:0]const u8, sdl_exts);
    defer gpa.free(exts_copy_global);

    // Io for shader file reads (no process.Init here — own a Threaded).
    var io_impl = std.Io.Threaded.init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    // Load SPIR-V: quad_vert/quad_frag for the 9-slice batch, the CS1
    // sort compute (V1b), plus the fullscreen blit pass (Oklab → sRGB).
    var quad_vert_f = try ShaderFile.load(io, gpa, "shaders/quad_vert.spv");
    defer quad_vert_f.deinit(gpa);
    var quad_frag_f = try ShaderFile.load(io, gpa, "shaders/quad_frag.spv");
    defer quad_frag_f.deinit(gpa);
    var sort_comp_f = try ShaderFile.load(io, gpa, "shaders/sort_comp.spv");
    defer sort_comp_f.deinit(gpa);
    var fullscreen_vert_f = try ShaderFile.load(io, gpa, "shaders/fullscreen_vert.spv");
    defer fullscreen_vert_f.deinit(gpa);
    var blit_oklab_f = try ShaderFile.load(io, gpa, "shaders/blit_oklab.spv");
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

    // Text engine (owns FreeType + the glyph material buffer) and the
    // 9-slice batch renderer (owns the quad shaders + vertex/index buffers).
    // Text engine (owns FreeType + the per-size font states + the glyph
    // material buffer) and the 9-slice batch renderer (owns the quad
    // shaders + vertex/index buffers). One engine serves every font size.
    var text_engine = try TextEngine.init(&gpu, gpa);
    defer text_engine.deinit();
    TextEngine.measure_engine = &text_engine;
    app.measure = TextEngine.measureForFlex;
    var batch = try Batch9Slice.init(&gpu, quad_vert_f.spv, quad_frag_f.spv, sort_comp_f.spv);
    defer batch.deinit();
    batch.material_buf_bda = text_engine.materialBda();
    batch.subpixel = subpixel;
    batch.quad_debug = quad_debug;
    batch.bgr_order = bgr;
    batch.damp_chroma = damp;

    // GUI texture heap + registry: persistent bindless heap (set 0 =
    // registered textures, set 2 = the shared linear/clamp sampler), bound
    // once per frame before the batch draw. The demo registers one
    // procedural texture and the UI draws it via `.texture = idx`.
    var tex_registry = try TextureRegistry.init(&gpu, gpa);
    defer tex_registry.deinit(gpa);
    ui.texture_idx = try uploadDemoTexture(&gpu, &tex_registry, gpa);
    try uploadReferenceTexture(&gpu, &tex_registry, gpa);

    // Mandelbrot compute pass: render target + compute shader + params
    // buffer, registered into the GUI heap (set 0 sampled + set 1 storage).
    var mandelbrot = try MandelbrotPass.init(&gpu, io, gpa, &tex_registry);
    defer mandelbrot.deinit(&gpu);

    // SVG showcase: the tiger, parsed + converted once (the paths →
    // conics → glyph materials + cached scene rects).
    // The stroke test scene (the TestStrokesApp root) loads the curved
    // thin-stroke set; everything else loads the tiger.
    var svg_view = if (comptime T == ui.TestStrokesApp)
        try initStrokeView(&gpu, gpa, &text_engine)
    else
        try initSvgView(&gpu, gpa, &text_engine);
    defer svg_view.deinit(&gpu);

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

    // Main loop — the WINDOW DRIVER: translate OS events into core Events
    // (the core never polls input or reads a clock itself), then emit one
    // .frame event per iteration with the driver's tick + clock.
    var tick: u32 = 1;
    var last_frame_ms: u64 = 0;
    var should_close = false;
    var mandel_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var mandel_drag: ?MandelDrag = null;
    while (!should_close) {
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
                        _ = try app.handle(T, root, .{ .resize = .{
                            .width = @floatFromInt(pix[0]),
                            .height = @floatFromInt(pix[1]),
                        } });
                    }
                },
                .window_resized => |we| {
                    if (we.id == win_id) {
                        const pix = try sdl_win.getSizeInPixels();
                        gw.notifyResize(.{ .width = @intCast(pix[0]), .height = @intCast(pix[1]) });
                        _ = try app.handle(T, root, .{ .resize = .{
                            .width = @floatFromInt(pix[0]),
                            .height = @floatFromInt(pix[1]),
                        } });
                    }
                },
                .mouse_motion => |mm| {
                    const pos = try toSurfacePoint(sdl_win, &gw, .{ mm.x, mm.y });
                    if (mandel_drag != null) {
                        // Panning the mandelbrot: consume the motion (the
                        // core never sees the drag).
                        applyMandelbrot(&mandel_drag, pos, 0, mandel_rect, ui.mandelbrot_scale);
                        continue;
                    }
                    _ = try app.handle(T, root, .{ .mouse_move = .{ .x = pos[0], .y = pos[1] } });
                },
                .window_mouse_leave => |we| {
                    if (we.id == win_id) _ = try app.handle(T, root, .mouse_leave);
                },
                .mouse_button_down => |mb| {
                    const pos = try toSurfacePoint(sdl_win, &gw, .{ mb.x, mb.y });
                    const button: MouseButton = if (mb.button == .left)
                        .left
                    else if (mb.button == .right)
                        .right
                    else
                        .middle;
                    // Grab the mandelbrot for a pan drag if the press lands
                    // inside its box (consumed by the driver).
                    if (button == .left and mandel_rect.w > 0 and pos[0] >= mandel_rect.x and pos[0] < mandel_rect.x + mandel_rect.w and pos[1] >= mandel_rect.y and pos[1] < mandel_rect.y + mandel_rect.h) {
                        mandel_drag = .{ .mouse = pos, .center = ui.mandelbrot_center };
                        continue;
                    }
                    _ = try app.handle(T, root, .{ .mouse_down = .{ .button = button, .x = pos[0], .y = pos[1] } });
                },
                .mouse_button_up => |mb| {
                    const pos = try toSurfacePoint(sdl_win, &gw, .{ mb.x, mb.y });
                    const button: MouseButton = if (mb.button == .left)
                        .left
                    else if (mb.button == .right)
                        .right
                    else
                        .middle;
                    if (mandel_drag != null) {
                        mandel_drag = null; // release the pan
                        continue;
                    }
                    _ = try app.handle(T, root, .{ .mouse_up = .{ .button = button, .x = pos[0], .y = pos[1] } });
                },
                .mouse_wheel => |mw| {
                    const pos = try toSurfacePoint(sdl_win, &gw, .{ mw.x, mw.y });
                    _ = pos; // the wheel zooms at the cursor; the pan is mouse-driven
                    // Zoom the mandelbrot (consumed — no core wheel event yet).
                    // mw.scroll_y: positive away (up) = zoom in, negative
                    // toward (down) = zoom out. The old code read mw.y (the
                    // mouse Y position) as the delta — a large constant that
                    // always exploded the scale to the zoom-in clamp.
                    applyMandelbrot(null, .{ 0, 0 }, mw.scroll_y, mandel_rect, ui.mandelbrot_scale);
                    continue;
                },
                .key_down => |kd| {
                    if (kd.key) |kc| {
                        if (kc == .s) {
                            batch.subpixel = !batch.subpixel;
                            std.log.info("subpixel AA: {s}", .{if (batch.subpixel) "on" else "off"});
                            continue;
                        }
                        if (kc == .d) {
                            batch.quad_debug = !batch.quad_debug;
                            std.log.info("quad debug: {s}", .{if (batch.quad_debug) "on" else "off"});
                            continue;
                        }
                        if (kc == .a) {
                            // Cycle the stroke algo: 0 = naive SDF, 1 =
                            // marching quads, 2 = the spec'd marching quads.
                            ui.stroke_algo = @floatFromInt((@as(u32, @intFromFloat(ui.stroke_algo)) + 1) % 3);
                            std.log.info("stroke algo: {d} ({s})", .{ ui.stroke_algo, switch (@as(u32, @intFromFloat(ui.stroke_algo))) {
                                0 => "naive SDF",
                                1 => "marching quads",
                                else => "spec'd marching quads",
                            } });
                            continue;
                        }
                        if (kc == .o) {
                            batch.bgr_order = !batch.bgr_order;
                            std.log.info("subpixel order: {s}", .{if (batch.bgr_order) "BGR" else "RGB"});
                            continue;
                        }
                        if (kc == .c) {
                            batch.damp_chroma = !batch.damp_chroma;
                            std.log.info("chroma damping: {s}", .{if (batch.damp_chroma) "on" else "off"});
                            continue;
                        }
                        if (kc == .p) {
                            // Cycle the mandelbrot precision: 0 f32, 1 f64, 2 adaptive.
                            ui.mandelbrot_precision = (ui.mandelbrot_precision + 1) % 3;
                            std.log.info("mandelbrot precision: {s}", .{switch (ui.mandelbrot_precision) {
                                0 => "f32",
                                1 => "f64",
                                else => "adaptive",
                            }});
                            continue;
                        }
                    }
                    const core_key = mapSdlKey(kd.key orelse continue) orelse continue;
                    const shift = kd.mod.left_shift or kd.mod.right_shift;
                    _ = try app.handle(T, root, .{ .key_down = .{ .key = core_key, .shift = shift } });
                },
                else => {},
            }
        }
        if (should_close) break;

        // Apply the header pill clicks (the UI sets a request; the window
        // owns the batch). The keys flip the batch directly above; the
        // request path flips it the same way so both routes agree.
        if (ui.toggle_request) |req| {
            switch (req) {
                .subpixel => batch.subpixel = !batch.subpixel,
                .bgr => batch.bgr_order = !batch.bgr_order,
                .damp => batch.damp_chroma = !batch.damp_chroma,
                .debug => batch.quad_debug = !batch.quad_debug,
            }
            ui.toggle_request = null;
        }

        // Sync the toggle state for the UI's header line (the UI cannot
        // import the window; the debug_state lives in text.zig).
        text_mod.debug_state = .{
            .subpixel = batch.subpixel,
            .bgr = batch.bgr_order,
            .damp = batch.damp_chroma,
            .quad_debug = batch.quad_debug,
        };

        // Frame event: the core draws + lays out + presents; the output's
        // hover comes from the core's cursor state.
        const time_ms: u64 = sdl3.timer.getMillisecondsSinceInit();
        const out = (try app.handle(T, root, .{ .frame = .{ .tick = tick, .time_ms = time_ms } })).?;
        defer if (out.json) |j| gpa.free(j);
        mandel_rect = mandelbrotRect(out.tree, ui.mandelbrot_idx);

        // Slice rects: draw commands → solid rects, then glyphs on top.
        // The clip-stack walk appends the frame's clip rects to the tree
        // (the tree is const-typed in FrameOutput; the per-frame clip list
        // is the renderer's legitimate scratch — collectDrawCmds extends it
        // and stamps clip ids, never touches layout state).
        const base_cmds = try collectDrawCmds(@constCast(out.tree), out.pressed, gpa, out.press_alpha);
        defer gpa.free(base_cmds);
        var slice_rects = std.ArrayList(SceneRect).empty;
        defer slice_rects.deinit(gpa);
        try buildSliceRects(&text_engine, &svg_view, base_cmds, out.tree, out.hover, out.hover_alpha, out.focus, &slice_rects, gpa);
        // --gpu-sort-verify: submit the bag in REVERSE paint order — the
        // CS1 sort (stable on (z, order)) must restore the paint order,
        // so the frame renders byte-identical to the ordered submission.
        if (gpu_sort_verify) std.mem.reverse(SceneRect, slice_rects.items);

        // Acquire the swapchain image (recreates the swapchain on resize).
        // OutOfDateKHR consumed the frame event: sleep ~16ms before the
        // retry so a resize storm doesn't spin the loop at 100% CPU.
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

        // Mandelbrot compute pass BEFORE the GUI pass: the compute writes
        // the fractal into the storage texture (set 1 of the GUI heap),
        // then the barrier makes it visible to the GUI pass's sampled read.
        cmd.beginZone(.{ .name = "mandelbrot_gpu", .src = @src() });
        recordMandelbrot(&cmd, &mandelbrot, tex_registry.heap, time_ms);
        cmd.endZone();

        // Pass 1: GUI into the offscreen Oklab target.
        cmd.beginZone(.{ .name = "renderPass1_gpu", .src = @src() });
        try renderPass1(&batch, &cmd, slice_rects.items, out.tree.clip_rects[0..out.tree.clip_count], render_target, size, tex_registry.heap);
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

        // Rolling FPS (an EMA over the frame deltas) for the demo header.
        // The unconditional 16ms sleep is GONE — it doubled the vsync pacing
        // and added latency; the swapchain's FIFO/MAILBOX mode paces now.
        const now_ms = sdl3.timer.getMillisecondsSinceInit();
        if (last_frame_ms != 0) {
            const dt: f32 = @as(f32, @floatFromInt(now_ms -| last_frame_ms)) / 1000.0;
            if (dt > 0) ui.fps = ui.fps * 0.9 + (1.0 / dt) * 0.1;
        }
        last_frame_ms = now_ms;
        tick += 1;
        // Mark the frame boundary — without this the tracy profiler thread
        // stays gated on its futex and never processes the connection.
        tracy.frameMark(null);
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
fn writePpm(io: Io, path: []const u8, pixels: [*]const f32, w: u32, h: u32, gpa: std.mem.Allocator) !void {
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
pub fn runShot(app: *App, comptime T: type, root: *T, path: []const u8, hover: ?[2]f32, subpixel: bool, quad_debug: bool, bgr: bool, damp: bool, gpu_sort_verify: bool) !void {
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

    var quad_vert_f = try ShaderFile.load(io, gpa, "shaders/quad_vert.spv");
    defer quad_vert_f.deinit(gpa);
    var quad_frag_f = try ShaderFile.load(io, gpa, "shaders/quad_frag.spv");
    defer quad_frag_f.deinit(gpa);
    var sort_comp_f = try ShaderFile.load(io, gpa, "shaders/sort_comp.spv");
    defer sort_comp_f.deinit(gpa);
    var fullscreen_vert_f = try ShaderFile.load(io, gpa, "shaders/fullscreen_vert.spv");
    defer fullscreen_vert_f.deinit(gpa);
    var blit_oklab_f = try ShaderFile.load(io, gpa, "shaders/blit_oklab.spv");
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

    // Text engine (owns FreeType + the per-size font states + the glyph
    // material buffer) and the 9-slice batch renderer (owns the quad
    // shaders + vertex/index buffers). One engine serves every font size.
    var text_engine = try TextEngine.init(&gpu, gpa);
    defer text_engine.deinit();
    TextEngine.measure_engine = &text_engine;
    app.measure = TextEngine.measureForFlex;
    var batch = try Batch9Slice.init(&gpu, quad_vert_f.spv, quad_frag_f.spv, sort_comp_f.spv);
    defer batch.deinit();
    batch.material_buf_bda = text_engine.materialBda();
    batch.subpixel = subpixel;
    batch.quad_debug = quad_debug;
    batch.bgr_order = bgr;
    batch.damp_chroma = damp;

    // GUI texture heap + registry + the demo's procedural texture — the
    // shot renders it like run() (the texture card is part of the frame).
    var tex_registry = try TextureRegistry.init(&gpu, gpa);
    defer tex_registry.deinit(gpa);
    ui.texture_idx = try uploadDemoTexture(&gpu, &tex_registry, gpa);
    try uploadReferenceTexture(&gpu, &tex_registry, gpa);

    // Mandelbrot compute pass (Part A) — the shot renders it like run().
    var mandelbrot = try MandelbrotPass.init(&gpu, io, gpa, &tex_registry);
    defer mandelbrot.deinit(&gpu);

    // The stroke test scene (the TestStrokesApp root) loads the curved
    // thin-stroke set; everything else loads the tiger.
    var svg_view = if (comptime T == ui.TestStrokesApp)
        try initStrokeView(&gpu, gpa, &text_engine)
    else
        try initSvgView(&gpu, gpa, &text_engine);
    defer svg_view.deinit(&gpu);

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

    // Sync the toggle state BEFORE the frame builds the tree: the shot's
    // header status line reads debug_state, so a late sync would stamp the
    // PREVIOUS frame's toggles onto this shot. Same order as run()'s loop.
    text_mod.debug_state = .{
        .subpixel = batch.subpixel,
        .bgr = batch.bgr_order,
        .damp = batch.damp_chroma,
        .quad_debug = batch.quad_debug,
    };

    // One frame: fresh tree + layout at the fixed window size.
    const surface_size = gw.surfaceSize();
    const out = try app.frame(T, root, 1, .{
        .width = @floatFromInt(surface_size.width),
        .height = @floatFromInt(surface_size.height),
    });
    defer if (out.json) |j| gpa.free(j);

    const base_cmds = try collectDrawCmds(@constCast(out.tree), null, gpa, 0);
    defer gpa.free(base_cmds);
    var slice_rects = std.ArrayList(SceneRect).empty;
    defer slice_rects.deinit(gpa);
    const hover_id = if (hover) |p| hitTest(out.tree, p) else null;
    // Static shot: the hover ring renders at full alpha when a node is
    // hovered (no easing in a one-frame shot); 0 otherwise.
    const hover_alpha: f32 = if (hover_id != null) 1 else 0;
    try buildSliceRects(&text_engine, &svg_view, base_cmds, out.tree, hover_id, hover_alpha, null, &slice_rects, gpa);
    // --gpu-sort-verify: submit the bag in REVERSE paint order — the CS1
    // sort must restore it, so the shot stays byte-identical.
    if (gpu_sort_verify) std.mem.reverse(SceneRect, slice_rects.items);

    try ensureRenderTarget(&gpu, &render_target, &rt_w, &rt_h, surface_size.width, surface_size.height, blit_heap);

    // Readback buffer: one rgba32_float pixel per screen pixel.
    const pixel_bytes: u64 = @as(u64, surface_size.width) * surface_size.height * 4 * @sizeOf(f32);
    const readback = try gpu.gpuMalloc(pixel_bytes, 64, .readback);
    defer gpu.gpuFree(readback);

    // One-shot command buffer: mandelbrot compute pass first (the shot
    // uses the init time — one frame, so the hue phase is static), then
    // render pass 1 into the offscreen target, then copy the target into
    // the readback buffer.
    var cmd = try gpu.commandsBegin();
    // The shot's mandelbrot hue phase is PINNED to a natural-range value
    // (1200 ms) instead of the live init timer: the live timer varied by
    // ±250 ms between runs (the fractal hue shifts with process timing),
    // which made runShot unreproducible at the byte level. The pinned
    // phase renders the same fractal as a typical interactive start.
    recordMandelbrot(&cmd, &mandelbrot, tex_registry.heap, 1200);
    try renderPass1(&batch, &cmd, slice_rects.items, out.tree.clip_rects[0..out.tree.clip_count], render_target, surface_size, tex_registry.heap);
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
        cmd2.memCopy(perm_rb, batch.perm_a[batch.cur_slot], @as(u64, n) * @sizeOf(u32));
        try gpu.queueSubmit(&.{cmd2});
        gpu.commandsEnd(cmd2);
        try gpu.waitIdle();
        const got: [*]const u32 = @ptrCast(@alignCast(perm_rb.cpu));
        const RectSort = struct {
            rects: []const SceneRect,
            fn lessThan(ctx: @This(), a: u32, b: u32) bool {
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
            std.log.err("gpu-sort-verify FAILED: perm[{d}] = {d}, want {d} (z={d} order={d})", .{ i, got[i], ref[i], slice_rects.items[ref[i]].z, slice_rects.items[ref[i]].order });
            return error.GpuSortVerifyMismatch;
        }
        std.log.info("gpu-sort-verify: permutation matches the stable (z, order) reference ({d} drawables)", .{n});
    }

    // Convert Oklab floats → sRGB bytes and write the PPM.
    const pixels: [*]const f32 = @ptrCast(@alignCast(readback.cpu));
    try writePpm(io, path, pixels, surface_size.width, surface_size.height, gpa);
}
