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
//! DrawCmds; buildSliceRects turns each cmd into a SliceRect — solid cmds
//! use material slot 0, radius-bearing fills and border rings use per-cmd
//! rounded-rect materials (type 2) written into the engine's material
//! buffer; label-bearing nodes additionally emit one glyph SliceRect per
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
const Id = @import("v7/id.zig").Id;
const DrawCmd = @import("v7/drawcmd.zig").DrawCmd;
const WidgetTree = @import("v7/widget.zig").WidgetTree;
const absoluteRect = @import("v7/widget.zig").absoluteRect;
const contentRect = @import("v7/widget.zig").contentRect;
const collectDrawCmds = @import("v7/drawcmd.zig").collectDrawCmds;
const MouseButton = @import("v7/event.zig").MouseButton;
const Key = @import("v7/event.zig").Key;
const hitTest = @import("v7/input.zig").hitTest; // runShot's forced --hover
const Batch9Slice = @import("proto/render_9slice.zig").Batch9Slice;
const SliceRect = @import("proto/render_9slice.zig").SliceRect;
const TextEngine = @import("text.zig").TextEngine;
const text_mod = @import("text.zig");
const MAX_MATERIALS = @import("text.zig").MAX_MATERIALS;
const FONT_SIZE_PX = @import("text.zig").FONT_SIZE_PX;
const proto = @import("proto/sweeper.zig");
const srgbToOklab = @import("text.zig").srgbToOklab;

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

/// v4's Oklab gray: L = 0.516395, a = 0, b = 0. Clears the offscreen target.
const OKLAB_GRAY = [4]f32{ 0.516395, 0.0, 0.0, 1.0 };

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

/// Flatten the frame's draw commands + widget text into SliceRects:
/// 1. Every DrawCmd rect becomes a SliceRect. Ring cmds (borders) get a
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
///    SliceRect per character at the node's ABSOLUTE content box
///    (x = content.x, baseline = the font-derived baseline), appended
///    LAST so text paints on top of every widget decoration.
fn buildSliceRects(
    text_engine: *TextEngine,
    cmds: []const DrawCmd,
    tree: *const WidgetTree,
    hover_id: ?Id,
    hover_alpha: f32,
    focus_id: ?Id,
    out: *std.ArrayList(SliceRect),
    gpa: std.mem.Allocator,
) !void {
    // Rounded-rect material slots, allocated from the top of the buffer
    // downward (glyphs own slots 1..next_slot-1 from the bottom; the
    // assert in text.zig caps glyphs well below the top).
    var material_slot: u32 = MAX_MATERIALS;
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
            // Shadow cmd: feathered rounded-rect material (type 3).
            slice_corner_l = b.radius.left;
            slice_corner_r = b.radius.right;
            slice_corner_t = b.radius.top;
            slice_corner_b = b.radius.bottom;
            const shadow_rx: f32 = @max(b.radius.left, b.radius.right);
            const shadow_ry: f32 = @max(b.radius.top, b.radius.bottom);
            std.debug.assert(material_slot > glyph_slots); // never reach the live glyph slots
            material_slot -= 1;
            proto.GlyphSweeper.writeShadowMaterial(text_engine.materials, material_slot, shadow_rx, shadow_ry, cmd.shadow, cmd.rect.w, cmd.rect.h);
            material_index = material_slot;
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
            .dst_x = cmd.rect.x,
            .dst_y = cmd.rect.y,
            .dst_w = cmd.rect.w,
            .dst_h = cmd.rect.h,
            .corner_l = slice_corner_l,
            .corner_r = slice_corner_r,
            .corner_t = slice_corner_t,
            .corner_b = slice_corner_b,
            .color = srgbToOklab(cmd.color),
            .material_index = material_index,
        });
    }

    // Slider thumbs: a rounded bar at the value fraction, painted BEFORE
    // the glyphs so the thumb never covers the slider's own label.
    for (tree.nodes.items) |*n| {
        if (n.kind != .slider) continue;
        const s = n.kind.slider;
        const r = absoluteRect(tree, n.id);
        if (r.w <= 0 or r.h <= 0) continue;
        const frac = std.math.clamp((s.value.* - s.min) / (s.max - s.min), 0, 1);
        const thumb_w: f32 = 10;
        const thumb_x = r.x + frac * @max(0, r.w - thumb_w);
        const thumb_radius: f32 = 3;
        std.debug.assert(material_slot > glyph_slots);
        material_slot -= 1;
        proto.GlyphSweeper.writeRoundedRectMaterial(text_engine.materials, material_slot, thumb_radius, thumb_radius, 0, thumb_w, r.h, .{ 0, 0, 0, 0 });
        try out.append(gpa, .{
            .dst_x = thumb_x,
            .dst_y = r.y,
            .dst_w = thumb_w,
            .dst_h = r.h,
            .corner_l = thumb_radius,
            .corner_r = thumb_radius,
            .corner_t = thumb_radius,
            .corner_b = thumb_radius,
            .color = srgbToOklab(.{ 0.82, 0.82, 0.85, 1 }),
            .material_index = material_slot,
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
                .dst_x = r.x,
                .dst_y = r.y,
                .dst_w = r.w,
                .dst_h = r.h,
                .corner_l = n.box.radius.left,
                .corner_r = n.box.radius.right,
                .corner_t = n.box.radius.top,
                .corner_b = n.box.radius.bottom,
                // Amber ring fades in by hover_alpha (the core eases it);
                // hover_alpha 1 reproduces the solid ring.
                .color = srgbToOklab(.{ 1.0, 0.8, 0.2, hover_alpha }),
                .material_index = material_slot,
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
                .dst_x = r.x,
                .dst_y = r.y,
                .dst_w = r.w,
                .dst_h = r.h,
                .corner_l = n.box.radius.left,
                .corner_r = n.box.radius.right,
                .corner_t = n.box.radius.top,
                .corner_b = n.box.radius.bottom,
                .color = srgbToOklab(.{ 0.25, 0.85, 0.85, 1 }),
                .material_index = material_slot,
            });
            break;
        }
    }

    for (tree.nodes.items) |*n| {
        const text: ?[]const u8 = switch (n.kind) {
            .label => |l| l.text,
            .button => |b| b.label,
            .slider => |s| s.label,
            else => null,
        };
        const t = text orelse continue;
        if (t.len == 0) continue;
        const content = contentRect(tree, n.id);
        if (content.w == 0 or content.h == 0) continue;
        const size: u32 = if (n.font_size > 0) @intFromFloat(@round(n.font_size)) else FONT_SIZE_PX;
        const baseline_y = text_engine.baselineIn(content.y, content.h, size, n.font_id);
        try text_engine.emitText(t, content.x, baseline_y, size, n.font_id, out);
    }
}

/// Render the current app frame into the offscreen Oklab target. Shared by
/// run() (presented via the blit pass) and runShot() (read back).
fn renderPass1(
    batch: *Batch9Slice,
    cmd: *noapi.CommandBuffer,
    slice_rects: []const SliceRect,
    render_target: noapi.TextureHandle,
    surface_size: noapi.Extent2D,
) !void {
    const sw: f32 = @floatFromInt(surface_size.width);
    const sh: f32 = @floatFromInt(surface_size.height);

    cmd.beginRendering(.{ .color_attachments = &.{
        .{ .texture = render_target, .load_op = .clear, .store_op = .store, .clear_color = OKLAB_GRAY },
    }, .render_area_size = .{ surface_size.width, surface_size.height } });

    cmd.setBlendEnable(true);
    try batch.draw(cmd, slice_rects, sw, sh);
    cmd.setBlendEnable(false);
    cmd.endRendering();
}

/// Run the graphical demo. Blocks until the window closes.
/// Generic over the root component (any type with pub draw(self, ctx) !void).
pub fn run(app: *App, comptime T: type, root: *T, subpixel: bool, quad_debug: bool, bgr: bool, damp: bool) !void {
    const gpa = app.gpa;

    try sdl3.hints.set(.video_driver, "wayland");
    try sdl3.hints.set(.render_driver, "vulkan");
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

    // Load SPIR-V: quad_vert/quad_frag for the 9-slice batch, plus the
    // fullscreen blit pass (Oklab → sRGB).
    var quad_vert_f = try ShaderFile.load(io, gpa, "shaders/quad_vert.spv");
    defer quad_vert_f.deinit(gpa);
    var quad_frag_f = try ShaderFile.load(io, gpa, "shaders/quad_frag.spv");
    defer quad_frag_f.deinit(gpa);
    var fullscreen_vert_f = try ShaderFile.load(io, gpa, "shaders/fullscreen_vert.spv");
    defer fullscreen_vert_f.deinit(gpa);
    var blit_oklab_f = try ShaderFile.load(io, gpa, "shaders/blit_oklab.spv");
    defer blit_oklab_f.deinit(gpa);

    // GPU init.
    var gpu = try noapi.Gpu.init(.{
        .frames_in_flight = 2,
        .app_name = "v7-demo",
        .validation = false,
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
    var batch = try Batch9Slice.init(&gpu, quad_vert_f.spv, quad_frag_f.spv);
    defer batch.deinit();
    batch.material_buf_bda = text_engine.materialBda();
    batch.subpixel = subpixel;
    batch.quad_debug = quad_debug;
    batch.bgr_order = bgr;
    batch.damp_chroma = damp;

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
    var should_close = false;
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
                    _ = try app.handle(T, root, .{ .mouse_up = .{ .button = button, .x = pos[0], .y = pos[1] } });
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
                    }
                    const core_key = mapSdlKey(kd.key orelse continue) orelse continue;
                    const shift = kd.mod.left_shift or kd.mod.right_shift;
                    _ = try app.handle(T, root, .{ .key_down = .{ .key = core_key, .shift = shift } });
                },
                else => {},
            }
        }
        if (should_close) break;

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
        defer gpa.free(out.json);

        // Slice rects: draw commands → solid rects, then glyphs on top.
        const base_cmds = try collectDrawCmds(out.tree, out.pressed, gpa, out.press_alpha);
        defer gpa.free(base_cmds);
        var slice_rects = std.ArrayList(SliceRect).empty;
        defer slice_rects.deinit(gpa);
        try buildSliceRects(&text_engine, base_cmds, out.tree, out.hover, out.hover_alpha, out.focus, &slice_rects, gpa);

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

        // Pass 1: GUI into the offscreen Oklab target.
        try renderPass1(&batch, &cmd, slice_rects.items, render_target, size);

        // Barrier: render target color output → fragment shader read.
        cmd.barrier(.{ .color_output = true }, .{ .fragment = true }, .{});

        // Pass 2: blit the Oklab target to the swapchain (converts to sRGB).
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

        const frame_result = try gw.endFrame(.{ .blit_to_swapchain = true });
        _ = frame_result;

        // Frame pacing: ~60 fps.
        try Io.sleep(io, Io.Duration.fromMilliseconds(16), .real);
        tick += 1;
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
pub fn runShot(app: *App, comptime T: type, root: *T, path: []const u8, hover: ?[2]f32, subpixel: bool, quad_debug: bool, bgr: bool, damp: bool) !void {
    const gpa = app.gpa;

    try sdl3.hints.set(.video_driver, "wayland");
    try sdl3.hints.set(.render_driver, "vulkan");
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
    var fullscreen_vert_f = try ShaderFile.load(io, gpa, "shaders/fullscreen_vert.spv");
    defer fullscreen_vert_f.deinit(gpa);
    var blit_oklab_f = try ShaderFile.load(io, gpa, "shaders/blit_oklab.spv");
    defer blit_oklab_f.deinit(gpa);

    var gpu = try noapi.Gpu.init(.{
        .frames_in_flight = 2,
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
    var batch = try Batch9Slice.init(&gpu, quad_vert_f.spv, quad_frag_f.spv);
    defer batch.deinit();
    batch.material_buf_bda = text_engine.materialBda();
    batch.subpixel = subpixel;
    batch.quad_debug = quad_debug;
    batch.bgr_order = bgr;
    batch.damp_chroma = damp;

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
    defer gpa.free(out.json);

    const base_cmds = try collectDrawCmds(out.tree, null, gpa, 0);
    defer gpa.free(base_cmds);
    var slice_rects = std.ArrayList(SliceRect).empty;
    defer slice_rects.deinit(gpa);
    const hover_id = if (hover) |p| hitTest(out.tree, p) else null;
    // Static shot: the hover ring renders at full alpha when a node is
    // hovered (no easing in a one-frame shot); 0 otherwise.
    const hover_alpha: f32 = if (hover_id != null) 1 else 0;
    try buildSliceRects(&text_engine, base_cmds, out.tree, hover_id, hover_alpha, null, &slice_rects, gpa);

    try ensureRenderTarget(&gpu, &render_target, &rt_w, &rt_h, surface_size.width, surface_size.height, blit_heap);

    // Readback buffer: one rgba32_float pixel per screen pixel.
    const pixel_bytes: u64 = @as(u64, surface_size.width) * surface_size.height * 4 * @sizeOf(f32);
    const readback = try gpu.gpuMalloc(pixel_bytes, 64, .readback);
    defer gpu.gpuFree(readback);

    // One-shot command buffer: render pass 1 into the offscreen target,
    // then copy the target into the readback buffer.
    var cmd = try gpu.commandsBegin();
    try renderPass1(&batch, &cmd, slice_rects.items, render_target, surface_size);
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

    // Convert Oklab floats → sRGB bytes and write the PPM.
    const pixels: [*]const f32 = @ptrCast(@alignCast(readback.cpu));
    try writePpm(io, path, pixels, surface_size.width, surface_size.height, gpa);
}
