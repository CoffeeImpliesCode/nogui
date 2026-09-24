//! W24 inspector interaction smoke — one mounted specimen, real committed
//! frames, real pointer routing, real rendered pixels.
//!
//! Two modes, one gate. HEADLESS is the default: SDL's dummy video driver, no
//! compositor, no native window surface, no swapchain and no presentation. The
//! frame's final sRGB image is an offscreen texture this binary owns, and the
//! pixels it reads back are pixels the real pipeline produced. `--native` is
//! the opt-in windowed mode that presents the same frame to a real Vulkan
//! swapchain; it needs a display server and is never the default.
//!
//! What it observes, all against the LIVE tree of the mounted specimen:
//!   1. `Inspector.pickAt` against a frame committed through
//!      `Application.updateFrames` -> resolved identity, role, label, bounds.
//!   2. The routed pick compared against `nogui.input.hitTest` on the same
//!      point, so agreement is measured, not assumed.
//!   3. `App.handle` with a `mouse_move` / `mouse_down` / `mouse_up` at the
//!      same coordinates, compared against the focus target the press
//!      produced. These are SYNTHETIC `Event` values handed to the app: the
//!      report labels them, and no claim is made that the compositor
//!      delivered them.
//!   4. A model update that changes a label: the same handle must resolve to a
//!      node whose reported label changed.
//!   5. A model update that replaces a keyed node: the earlier handle must fail
//!      with `error.StaleHandle` instead of resolving to the replacement.
//!   6. A REAL overlay on the mounted specimen. The view builds a keyed
//!      content subtree, this binary registers it in a real `overlay.Frame`
//!      and resolves it against the committed tree, and the resolved
//!      placement is what gets painted and read back. Two points are chosen
//!      out of that resolved placement rather than hard-coded: one where the
//!      placement is painted over a control input still routes to, and one
//!      where the overlay's own laid-out box is under the pointer as well. At
//!      both, the topmost painted node, the core overlay hit test, the
//!      inspector's pick and the engine's routed input are reported side by
//!      side, in the Oklab intermediate every mode can read back and — in
//!      headless — in the final sRGB image a compositor would have been
//!      shown. The overlay's label change and its removal are driven through
//!      the model, so its handle's identity is observed across both.
//!   7. Bounded frame / task / action collectors at fixed capacities.
//!   8. The inspection round trip. Styles, clipping, focus, capture and the
//!      semantic relationships are mounted content of the SAME specimen,
//!      read back through the SAME public snapshot / pick / resolve path.
//!      Every value asserted is one this run authored and every transition
//!      is one this run performed: a real press captures the pointer, a real
//!      release lets it go, a second press moves focus to another control,
//!      and a model change replaces an authored style value on the handle
//!      that already carried the old one. Clipping is observed as BEHAVIOUR:
//!      a point inside a child's box but outside the clip that constrains it
//!      is refused by the inspector's pick and by the engine's own routing
//!      alike, while a point inside the intersection names the child.
//!   9. Opt-in `--gpu-timing`. Real timestamps from the device's own query
//!      pool, bracketing the work each submitted frame actually did, and
//!      attached to the frame record the host already kept for that frame.
//!      Off by default and inert when off. A device whose queue has no
//!      timestamp queries is refused, and then no timing is reported at all.
//!  10. Opt-in `--ppm PATH`. The final rendered image, byte for byte, as a
//!      binary PPM. Off by default.
//! It drives the host as an EXTERNAL loop: `Application.step()` is called
//! here, never `Application.run()`.
//!
//! `--ppm` writes the offscreen final image. A presented swapchain image is
//! created without transfer-source usage, so a compositor's image cannot be
//! copied back: `--ppm` is refused under `--native` instead of writing a
//! stand-in, and the offscreen final-sRGB probe stays the honest proof.
//!
//! Run it: `zig build w24-inspector-smoke` (headless) or
//! `zig build w24-inspector-smoke -- --native [--hold-ms 4000]`, plus
//! `--gpu-timing` for the timestamp path and `--ppm PATH` for the dump.
const std = @import("std");
const Io = std.Io;
const sdl3 = @import("sdl3");
const noapi = @import("noapi");

const nogui = @import("nogui");
const render = @import("v7_render");
const frame = @import("v7_frame");
const host = @import("nogui_host");

const Session = nogui.Session;
const App = nogui.App;
const WidgetId = nogui.WidgetId;
const contract = host.window_contract;
const Application = host.Application;
const Inspector = host.inspector.Inspector;
const inspection = nogui.inspection;
const FrameSnapshot = inspection.FrameSnapshot;
const NodeSnapshot = inspection.NodeSnapshot;
const overlay = nogui.overlay;
const FrameNodeId = nogui.FrameNodeId;

/// The window the mounted specimen is laid out in. Its height leaves room for
/// the overlay content in the flow BELOW the control the overlay is anchored
/// to, so one resolved placement covers both that control and the overlay's
/// own laid-out box.
const window_width: u32 = 520;
const window_height: u32 = 520;

/// The host module does not re-export `ManagedWindow`; every hook that receives
/// one is typed against it. Recover the pointer type from the hook's own
/// function-pointer type instead of touching production exports.
const OnFrameFn = @typeInfo(@FieldType(Application.Hooks, "on_frame")).optional.child;
const managed_window_ptr =
    @typeInfo(@typeInfo(OnFrameFn).pointer.child).@"fn".params[2].type.?;

/// Fixed capacities for the three bounded collectors. Chosen small on purpose:
/// the run must show retention saturating, not merely filling.
const frame_capacity: usize = 8;
const task_capacity: usize = 4;
const action_capacity: usize = 4;
/// Frames driven explicitly so the frame ring is provably over-subscribed.
const bounded_frames: u32 = 12;
const bounded_tasks: u32 = 4;
const bounded_actions: u32 = 6;

// ── GPU timestamp instrumentation ─────

/// Query pairs in the device pool, one pair per frame slot. A slot is reused
/// only after the frame that owns it was read back at a queue-idle boundary,
/// so a reset never races work that has not finished.
const timing_slots: u32 = 4;
/// One write at each end of the frame's command buffer.
const timing_queries_per_frame: u32 = 2;
/// Measured spans kept for the report. Bounded like every other collector.
const timing_span_capacity: usize = 16;

// ── Authored values the inspection round trip reads back ─────

/// The style values the styled control is authored with. Each one is a
/// deliberate departure from a default, so a snapshot that reports the
/// default has not reported the authored value.
const audit_gap: f32 = 6;
const audit_grow: f32 = 0.25;
/// Authored per side, because the paint option reads sides rather than one
/// scalar: a single number would resolve to four zero corners.
const audit_radius: nogui.style.Sides = .{ .top = 9, .right = 9, .bottom = 9, .left = 9 };
const audit_opacity: f32 = 0.75;
const audit_layer: u32 = 5;
const audit_tab_index: i32 = 7;
const audit_tab_group: u32 = 3;
const audit_font_size: f32 = 21;
/// Distinct from the visible label on purpose: an accessible name that
/// merely repeated the label would prove nothing.
const audit_accessible_label = "Styled target, audited";
const audit_label_a = "Styled Target A";
const audit_label_b = "Styled Target B";
const audit_fill_a: [4]f32 = .{ 0.51, 0.19, 0.62, 0.8 };
const audit_fill_b: [4]f32 = .{ 0.11, 0.57, 0.44, 0.35 };
const audit_shadows = [_]nogui.paint.Shadow{.{
    .color = .{ .srgb = .{ .r = 0.1, .g = 0.1, .b = 0.12 } },
    .offset = .{ .x = 2, .y = 3 },
    .blur = 5,
    .spread = 1,
}};

/// Registered against the styled control's own stable id, then read back out
/// of the snapshot. Authored here, so a snapshot that reported some other
/// location would not be reporting this registration.
const audit_source_file = "src/v7_demo/w24_inspector_smoke.zig";
const audit_source_line: u32 = 4242;
const audit_source_column: u32 = 7;
const audit_source_component = "PanelView.styledNode";

// ── Rendering the inspector's own overlay ─────

/// A SPIR-V module read from the build's `shaders/` directory. The bytes stay
/// owned for as long as `shaderCreate` and `Renderer.init` need them.
const Spv = struct {
    bytes: []u8,
    words: []const u32,

    fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) !Spv {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        if (bytes.len == 0 or bytes.len % @sizeOf(u32) != 0) {
            gpa.free(bytes);
            return error.ShaderModuleMalformed;
        }
        return .{ .bytes = bytes, .words = @alignCast(std.mem.bytesAsSlice(u32, bytes)) };
    }

    fn deinit(self: *Spv, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// sRGB channel to linear, the same transfer `paint.zig` applies before it
/// builds an Oklab colour.
fn srgbToLinear(value: f32) f32 {
    return if (value <= 0.04045) value / 12.92 else std.math.pow(f32, (value + 0.055) / 1.055, 2.4);
}

/// sRGB to Oklab, the pipeline's intermediate colour space. The render target
/// is Oklab and the final blit converts to sRGB, so every colour the smoke
/// paints goes through here.
fn srgbToOklab(rgb: [3]f32, alpha: f32) [4]f32 {
    const r = srgbToLinear(rgb[0]);
    const g = srgbToLinear(rgb[1]);
    const b = srgbToLinear(rgb[2]);
    const l = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return .{
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
        alpha,
    };
}

/// The colours the smoke paints. They are deliberately far apart in hue so a
/// readback cannot confuse one for another.
const palette_background = [3]f32{ 0.07, 0.08, 0.11 };
const palette_target = [3]f32{ 0.10, 0.62, 0.36 };
const palette_overlay = [3]f32{ 0.95, 0.55, 0.05 };

/// The overlay sheet gets its own hue so a pixel read back under a resolved
/// placement cannot be confused with the selection frame or the probe marker,
/// which share `palette_overlay`.
const palette_sheet = [3]f32{ 0.62, 0.18, 0.80 };

/// Paints the inspector's own view of the frame: the inspected target, the
/// selection overlay around it, and a resolved overlay placement. Everything
/// goes through the public `v7_render` renderer into an Oklab render target
/// and is blitted to the destination image, exactly as the demo's own path
/// does. Nothing here renders the widget tree: the gate under test is what
/// the inspector reports and where it puts it on screen.
const Painter = struct {
    gpu: *noapi.Gpu,
    gpa: std.mem.Allocator,
    renderer: render.Renderer,
    blit_vert: noapi.Shader,
    blit_frag: noapi.Shader,
    blit_heap: noapi.DescriptorHeap,
    gui_heap: noapi.DescriptorHeap,
    target: noapi.TextureHandle = .{},
    target_extent: noapi.Extent2D = .{ .width = 0, .height = 0 },
    readback: ?noapi.GpuPtr = null,
    rects: std.ArrayList(render.SceneRect) = .empty,

    fn init(
        gpa: std.mem.Allocator,
        gpu: *noapi.Gpu,
        quad_vert: *Spv,
        quad_frag: *Spv,
        sort_comp: *Spv,
        fullscreen_vert: *Spv,
        blit_oklab: *Spv,
    ) !Painter {
        var painter: Painter = .{
            .gpu = gpu,
            .gpa = gpa,
            .renderer = try render.Renderer.init(gpu, quad_vert.words, quad_frag.words, sort_comp.words),
            .blit_vert = try gpu.shaderCreate(fullscreen_vert.words, .vertex, "main", "w24_fullscreen"),
            .blit_frag = try gpu.shaderCreate(blit_oklab.words, .fragment, "main", "w24_blit_oklab"),
            // SAFETY: the blit heap is assigned before any frame runs.
            .blit_heap = undefined,
            // SAFETY: the GUI heap is assigned before any frame runs.
            .gui_heap = undefined,
        };
        errdefer painter.renderer.deinit();
        errdefer gpu.shaderDestroy(painter.blit_vert);
        errdefer gpu.shaderDestroy(painter.blit_frag);

        painter.blit_heap = try gpu.descHeapCreate(8, 0, 1);
        errdefer gpu.descHeapDestroy(painter.blit_heap);
        const linear_sampler = gpu.samplerDescriptor(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mip_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        gpu.descHeapSetSamplers(painter.blit_heap, 0, &.{linear_sampler});

        // The GUI shader samples the bindless texture heap even for solid
        // quads, so it is bound every frame exactly as the demo binds it.
        painter.gui_heap = try gpu.descHeapCreate(8, 0, 1);
        errdefer gpu.descHeapDestroy(painter.gui_heap);
        gpu.descHeapSetSamplers(painter.gui_heap, 0, &.{linear_sampler});
        return painter;
    }

    fn deinit(self: *Painter) void {
        if (self.readback) |buffer| self.gpu.gpuFree(buffer);
        if (self.target.texture.id != 0) self.gpu.textureDestroy(self.target);
        self.gpu.descHeapDestroy(self.gui_heap);
        self.gpu.descHeapDestroy(self.blit_heap);
        self.gpu.shaderDestroy(self.blit_frag);
        self.gpu.shaderDestroy(self.blit_vert);
        self.renderer.deinit();
        self.rects.deinit(self.gpa);
        self.* = undefined;
    }

    /// (Re)create the Oklab render target and its readback buffer.
    fn ensureTarget(self: *Painter, extent: noapi.Extent2D) !void {
        if (self.target_extent.width == extent.width and
            self.target_extent.height == extent.height) return;
        if (self.target.texture.id != 0) self.gpu.textureDestroy(self.target);
        if (self.readback) |buffer| self.gpu.gpuFree(buffer);
        self.target = try self.gpu.textureCreate(.{
            .dimensions = .{ extent.width, extent.height, 1 },
            .format = .rgba32_float,
            .usage = .{ .color_attachment = true, .sampled = true, .transfer_src = true },
        });
        const view = self.gpu.textureViewDescriptor(self.target, .{ .format = .default });
        self.gpu.descHeapSetTextures(self.blit_heap, 0, &.{view});
        const pixel_bytes: u64 = @as(u64, extent.width) * extent.height * 4 * @sizeOf(f32);
        self.readback = try self.gpu.gpuMalloc(pixel_bytes, 64, .readback);
        self.target_extent = extent;
    }

    /// One solid rectangle in the scene, in logical window coordinates.
    fn addRect(
        self: *Painter,
        rect: nogui.Rect,
        color: [4]f32,
        layer: u32,
    ) !void {
        if (rect.w <= 0 or rect.h <= 0) return;
        try self.rects.append(self.gpa, .{
            .dst = .{ rect.x, rect.y, rect.w, rect.h },
            .src = .{ 0, 0, 0, 0 },
            .corners = .{ 0, 0, 0, 0 },
            .color = color,
            .curve = .{ 0, 0, 0, 0 },
            .material_index = 0,
            .clip_id = 0xFFFFFFFF,
            .z = layer,
            .origin = .{ 0, 0 },
            .tex_idx = 0xFFFFFFFF,
            .order = @intCast(self.rects.items.len),
        });
    }

    /// Four thin rectangles forming a border of `thickness` around `rect` at
    /// `layer`. The layer is a parameter, not a constant, because a border
    /// drawn UNDER the fill it outlines is never a pixel: the placement
    /// border has to sit above its own fill and below the probe marker.
    fn addFrame(
        self: *Painter,
        rect: nogui.Rect,
        color: [4]f32,
        layer: u32,
        thickness: f32,
    ) !void {
        try self.addRect(
            .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = thickness },
            color,
            layer,
        );
        try self.addRect(.{
            .x = rect.x,
            .y = rect.y + rect.h - thickness,
            .w = rect.w,
            .h = thickness,
        }, color, layer);
        try self.addRect(.{
            .x = rect.x,
            .y = rect.y + thickness,
            .w = thickness,
            .h = @max(0, rect.h - 2 * thickness),
        }, color, layer);
        try self.addRect(.{
            .x = rect.x + rect.w - thickness,
            .y = rect.y + thickness,
            .w = thickness,
            .h = @max(0, rect.h - 2 * thickness),
        }, color, layer);
    }

    /// Record the GUI scene into the Oklab target, then blit it into
    /// `destination`. The upload happens outside the render pass, as the
    /// renderer's contract requires.
    fn submit(
        self: *Painter,
        cmd: *noapi.CommandBuffer,
        destination: noapi.TextureHandle,
        extent: noapi.Extent2D,
        logical: [2]f32,
    ) !void {
        try self.ensureTarget(extent);
        try self.renderer.prepare(cmd, .{
            .rects = self.rects.items,
            .clips = &.{},
        });

        cmd.beginRendering(.{
            .render_area_size = .{ extent.width, extent.height },
            .color_attachments = &.{.{
                .texture = self.target,
                .load_op = .clear,
                .store_op = .store,
                .clear_color = srgbToOklab(palette_background, 1),
            }},
        });
        cmd.setBlendState(.{
            .enable = true,
            .color_op = .add,
            .src_color_factor = .src_alpha,
            .dst_color_factor = .one_minus_src_alpha,
            .alpha_op = .add,
            .src_alpha_factor = .one,
            .dst_alpha_factor = .one_minus_src_alpha,
        });
        cmd.bindDescriptorSets(self.gui_heap);
        self.renderer.draw(
            cmd,
            logical[0],
            logical[1],
            @floatFromInt(extent.width),
            @floatFromInt(extent.height),
        );
        cmd.setBlendEnable(false);
        cmd.endRendering();

        // Oklab -> sRGB is the final blit; the swapchain is an sRGB image.
        cmd.beginRendering(.{
            .render_area_size = .{ extent.width, extent.height },
            .color_attachments = &.{.{
                .texture = destination,
                .load_op = .clear,
                .store_op = .store,
                .clear_color = .{ 0, 0, 0, 1 },
            }},
        });
        cmd.setShaders(self.blit_vert, self.blit_frag);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.bindDescriptorSets(self.blit_heap);
        cmd.setBlendEnable(false);
        cmd.draw(noapi.PushData{}, 3, 1);
        cmd.endRendering();
    }

    /// Record one copy of the whole Oklab target into the host-visible buffer.
    /// Every armed probe is then read out of that single copy.
    fn readPixel(self: *Painter, cmd: *noapi.CommandBuffer) !void {
        const extent = self.target_extent;
        const texture: noapi.Texture = .{
            .gpu = self.gpu,
            .handle = self.target,
            .dimensions = .{ extent.width, extent.height, 1 },
            .format = .rgba32_float,
        };
        // The copy is only RECORDED here. It is submitted with the frame, so
        // the host-visible bytes are the PREVIOUS frame's until the queue is
        // idle; reading them in the same frame reported zeroes.
        cmd.barrier(.{ .color_output = true }, .{ .transfer = true }, .{});
        cmd.copyFromTexture(texture, self.readback.?, .{
            .size = .{ extent.width, extent.height, 1 },
        });
    }

    /// The host-visible Oklab copy of the last submitted frame. The copy is a
    /// whole-image one, so one recording serves every armed probe.
    fn readbackImage(self: *const Painter) error{NoReadback}![]const f32 {
        if (self.readback == null) return error.NoReadback;
        const extent = self.target_extent;
        const count = @as(usize, extent.width) * extent.height * 4;
        const base: [*]const f32 = @ptrCast(@alignCast(self.readback.?.cpu));
        return base[0..count];
    }

    /// One already-submitted frame's pixel at `point`, as Oklab channels.
    /// `readPixel` must have recorded the copy in that frame.
    fn readIdle(self: *const Painter, point: [2]f32) error{NoReadback}![4]f32 {
        const extent = self.target_extent;
        const x: u32 = @intFromFloat(@min(@max(point[0], 0), @as(f32, @floatFromInt(extent.width)) - 1));
        const y: u32 = @intFromFloat(@min(@max(point[1], 0), @as(f32, @floatFromInt(extent.height)) - 1));
        const base = try self.readbackImage();
        const offset = (@as(usize, y) * extent.width + x) * 4;
        return .{ base[offset], base[offset + 1], base[offset + 2], base[offset + 3] };
    }
};

// ── Where the frame's final sRGB image goes ─────

/// The headless destination: a colour target this binary owns, blitted into
/// by the same Oklab -> sRGB pass the windowed mode presents, and copied back
/// for the pixel probes. Nothing is ever presented from it and no compositor
/// ever sees it; the pixels read out of it are the ones the pipeline produced.
const Offscreen = struct {
    gpu: *noapi.Gpu,
    texture: noapi.TextureHandle = .{},
    extent: noapi.Extent2D = .{ .width = 0, .height = 0 },
    readback: ?noapi.GpuPtr = null,

    fn init(gpu: *noapi.Gpu, extent: noapi.Extent2D) !Offscreen {
        var image: Offscreen = .{ .gpu = gpu };
        errdefer image.deinit();
        try image.ensure(extent);
        return image;
    }

    fn ensure(self: *Offscreen, extent: noapi.Extent2D) !void {
        if (self.texture.texture.id != 0 and self.extent.width == extent.width and
            self.extent.height == extent.height) return;
        if (self.texture.texture.id != 0) self.gpu.textureDestroy(self.texture);
        if (self.readback) |buffer| self.gpu.gpuFree(buffer);
        self.readback = null;
        // The blit writes LINEAR sRGB and the destination performs the
        // encode, exactly as a presented swapchain image does. A plain unorm
        // target would store linear bytes and the final readback would be a
        // linear image wearing an sRGB name.
        self.texture = try self.gpu.textureCreate(.{
            .dimensions = .{ extent.width, extent.height, 1 },
            .format = .rgba8_srgb,
            .usage = .{ .color_attachment = true, .transfer_src = true },
        });
        const pixels: u64 = @as(u64, extent.width) * extent.height * 4;
        self.readback = try self.gpu.gpuMalloc(pixels, 64, .readback);
        self.extent = extent;
    }

    fn deinit(self: *Offscreen) void {
        if (self.readback) |buffer| self.gpu.gpuFree(buffer);
        if (self.texture.texture.id != 0) self.gpu.textureDestroy(self.texture);
        self.* = undefined;
    }

    /// Record one copy of the final sRGB image into the host-visible buffer.
    fn readPixel(self: *Offscreen, cmd: *noapi.CommandBuffer) !void {
        const texture: noapi.Texture = .{
            .gpu = self.gpu,
            .handle = self.texture,
            .dimensions = .{ self.extent.width, self.extent.height, 1 },
            .format = .rgba8_srgb,
        };
        cmd.barrier(.{ .color_output = true }, .{ .transfer = true }, .{});
        cmd.copyFromTexture(texture, self.readback.?, .{
            .size = .{ self.extent.width, self.extent.height, 1 },
        });
    }

    /// The final sRGB pixel at `point`, as four normalised channels. Only
    /// meaningful once the recorded copy has been submitted and the queue is
    /// idle.
    fn readPixelIdle(self: *const Offscreen, point: [2]f32) error{NoReadback}![4]f32 {
        const buffer = self.readback orelse return error.NoReadback;
        const x: u32 = @intFromFloat(@min(@max(point[0], 0), @as(f32, @floatFromInt(self.extent.width)) - 1));
        const y: u32 = @intFromFloat(@min(@max(point[1], 0), @as(f32, @floatFromInt(self.extent.height)) - 1));
        const base: [*]const u8 = @ptrCast(@alignCast(buffer.cpu));
        const offset = (@as(usize, y) * self.extent.width + x) * 4;
        return .{
            @as(f32, @floatFromInt(base[offset])) / 255.0,
            @as(f32, @floatFromInt(base[offset + 1])) / 255.0,
            @as(f32, @floatFromInt(base[offset + 2])) / 255.0,
            @as(f32, @floatFromInt(base[offset + 3])) / 255.0,
        };
    }

    fn submit(self: *Offscreen, cmd: *noapi.CommandBuffer) !void {
        var buffers = [1]noapi.CommandBuffer{cmd.*};
        try self.gpu.queueSubmit(&buffers);
    }
};

fn cancelOffscreenRecording(context: *anyopaque, command: *noapi.CommandBuffer) !void {
    const gpu: *noapi.Gpu = @ptrCast(@alignCast(context));
    try gpu.commandsCancel(command);
}

/// The frame's destination. `.swapchain` presents to a real window surface;
/// `.image` submits to an owned offscreen target and presents nothing.
const Target = union(enum) {
    swapchain: noapi.Surface,
    image: Offscreen,

    /// True when a compositor is actually shown the frame.
    fn presents(self: *const Target) bool {
        return self.* == .swapchain;
    }

    fn deinit(self: *Target) void {
        switch (self.*) {
            .swapchain => |*surface| surface.deinit(),
            .image => |*image| image.deinit(),
        }
        self.* = undefined;
    }

    /// Begin the frame's recording. False asks for a retry after a resize.
    fn begin(self: *Target, extent: noapi.Extent2D) !bool {
        switch (self.*) {
            .swapchain => |*surface| {
                _ = try surface.beginFrame();
                return true;
            },
            .image => |*image| {
                try image.ensure(extent);
                return true;
            },
        }
    }

    fn commands(self: *Target) !noapi.CommandBuffer {
        return switch (self.*) {
            .swapchain => |*surface| surface.commandsBegin(),
            .image => |*image| image.gpu.commandsBegin(),
        };
    }

    /// The image the Oklab -> sRGB blit writes into.
    fn color(self: *const Target) noapi.TextureHandle {
        return switch (self.*) {
            .swapchain => |surface| surface.currentImage(),
            .image => |image| image.texture,
        };
    }

    fn submit(self: *Target, cmd: *noapi.CommandBuffer) !void {
        switch (self.*) {
            .swapchain => |*surface| {
                _ = try surface.endFrame(.{});
            },
            .image => |*image| try image.submit(cmd),
        }
    }

    fn notifyResize(self: *Target, extent: noapi.Extent2D) void {
        switch (self.*) {
            .swapchain => |*surface| surface.notifyResize(extent),
            // The image path re-derives its own extent from the window every
            // frame, so there is nothing to record for a later swapchain.
            .image => {},
        }
    }

    /// The one cancellation record the runtime's own `GpuFrame.recording`
    /// carries, so the value a target hands over IS the value the runtime
    /// aborts through.
    fn cancellation(self: *Target) nogui.GpuFrame.Cancellation {
        return switch (self.*) {
            .swapchain => |*surface| .{
                .context = surface,
                .abort = cancelSurfaceRecording,
            },
            .image => |*image| .{ .context = image.gpu, .abort = cancelOffscreenRecording },
        };
    }

    /// Record one copy of the FINAL sRGB image, the one a compositor would be
    /// shown. Only the offscreen target is owned here, so only it can be read
    /// back; the swapchain image belongs to the compositor and is left alone.
    fn readFinal(self: *Target, cmd: *noapi.CommandBuffer) !void {
        switch (self.*) {
            .swapchain => {},
            .image => |*image| try image.readPixel(cmd),
        }
    }
};

/// How close an Oklab channel must be before a readback counts as a match.
const pixel_epsilon: f32 = 0.004;

fn oklabMatches(observed: [4]f32, expected: [4]f32) bool {
    inline for (0..4) |channel| {
        if (@abs(observed[channel] - expected[channel]) > pixel_epsilon) return false;
    }
    return true;
}

/// The final image is eight bits per channel, so half a code is the floor a
/// readback of it can be held to.
const srgb_epsilon: f32 = 0.004;

fn srgbMatches(observed: [4]f32, expected: [4]f32) bool {
    inline for (0..4) |channel| {
        if (@abs(observed[channel] - expected[channel]) > srgb_epsilon) return false;
    }
    return true;
}

/// How a final-image readback is reported. A swapchain image belongs to the
/// compositor, so the windowed mode has no honest value to print there.
fn finalReadText(presents: bool, matched: bool) []const u8 {
    if (presents) return "n/a";
    return if (matched) "ok" else "MISMATCH";
}

// ── Model ──────────────────────────────

/// The inspected model. `target` is the label a pick must report; changing it
/// is the label-change observation. `spare` doubles as the widget KEY, so
/// changing it replaces the node instead of relabelling it. `sheet_open` and
/// `sheet_label` drive the overlay: the label change must keep the overlay's
/// identity, and closing it must retire that identity. The `audit_*` fields
/// mount and restyle the content the inspection round trip reads, so the
/// geometry the earlier sections probe is never perturbed by it.
pub const Panel = struct {
    target: []const u8 = "Inspect Target A",
    spare: []const u8 = "Spare One",
    sheet_open: bool = true,
    sheet_label: []const u8 = "Overlay Sheet A",
    /// Mounts the style / clip / focus specimen. Opened only once the overlay
    /// section is finished, so the flow every earlier probe reads is
    /// unchanged by its presence.
    audit_open: bool = false,
    audit_label: []const u8 = audit_label_a,
    audit_fill: [4]f32 = audit_fill_a,
    variant: u32 = 0,
    dispatched: u32 = 0,
    tasks_done: u32 = 0,
    pub fn deinit(self: *Panel, _: *Session) void {
        self.* = undefined;
    }

    fn onDispatch(self: *Panel, _: *const void, _: *Session) anyerror!void {
        self.dispatched += 1;
    }

    fn onWorkDone(self: *Panel, _: *const Work, _: *Session) void {
        self.tasks_done += 1;
    }
};

const c_text: [4]f32 = .{ 0.92, 0.94, 1.0, 1 };
const c_target: [4]f32 = .{ 0.18, 0.34, 0.55, 1 };
const c_sheet: [4]f32 = .{ 0.32, 0.12, 0.42, 1 };
const c_spare: [4]f32 = .{ 0.45, 0.24, 0.19, 1 };
const c_clip_box: [4]f32 = .{ 0.14, 0.16, 0.22, 1 };
const c_clip_child: [4]f32 = .{ 0.72, 0.31, 0.09, 1 };
const c_audit_text: [4]f32 = .{ 0.98, 0.97, 0.9, 1 };

/// The inspected view. Two keyed buttons: one whose key is constant (its label
/// changes), one whose key IS the model string (its node is replaced). After
/// them sits the overlay's content subtree: a keyed container whose size is
/// fixed, so one resolved placement below the target button covers BOTH the
/// spare control and the content's own laid-out box.
pub const PanelView = struct {
    drawn: u32 = 0,
    /// Real clicks that reached this control's own handler.
    clicks: u32 = 0,
    /// The node the overlay is anchored to, as this frame's draw created it.
    anchor_node: ?FrameNodeId = null,
    /// Root of the overlay content subtree this frame built, or null while the
    /// model has it closed.
    sheet_node: ?FrameNodeId = null,
    sheet_draws: u32 = 0,
    /// Real clicks that reached the spare control's own handler. A press that
    /// the overlay is painted over must leave this at zero.
    spare_clicks: u32 = 0,
    /// Real clicks that reached the OVERLAY's own control. A press on the
    /// painted overlay must land here, and exactly here.
    overlay_clicks: u32 = 0,
    /// Root of the clipping container the inspection round trip reads, or
    /// null while the model has the audit specimen closed.
    clip_node: ?FrameNodeId = null,
    /// The child whose own box is wider than the container that clips it.
    clip_child: ?FrameNodeId = null,
    /// The styled control the resolved-style, focus and capture round trips
    /// read.
    styled_node: ?FrameNodeId = null,
    /// The label carrying an authored font size.
    audit_label_node: ?FrameNodeId = null,
    /// Real clicks that reached the clipped child's own handler.
    clip_clicks: u32 = 0,
    /// Real clicks that reached the styled control's own handler.
    styled_clicks: u32 = 0,

    pub fn draw(self: *PanelView, panel: *const Panel, ctx: *nogui.DrawCtx) !void {
        self.drawn += 1;
        _ = try ctx.column(.{ .gap = 16, .padding = 20 });
        _ = try ctx.label(.{ .text = "W24 inspector smoke" });
        self.anchor_node = try ctx.button(.{
            .key = .{ .static = "inspect-target" },
            .label = panel.target,
            .on_click_with_data = nogui.bind(PanelView.onClick, 0),
            .width = 360,
            .height = 72,
            .fill = c_target,
            .color = c_text,
        });
        _ = try ctx.button(.{
            .key = .{ .static = panel.spare },
            .label = panel.spare,
            .on_click_with_data = nogui.bind(PanelView.onSpareClick, 0),
            .width = 360,
            .height = 56,
            .fill = c_spare,
            .color = c_text,
        });
        if (panel.sheet_open) {
            self.sheet_draws += 1;
            self.sheet_node = try ctx.column(.{
                .key = .{ .static = "overlay-sheet" },
                .width = 320,
                .height = 240,
                .gap = 8,
                .padding = 12,
            });
            // The overlay's own control: a keyed button inside the content
            // subtree, so a press on the painted placement has a real model
            // action to reach instead of a decorative label.
            _ = try ctx.button(.{
                .key = .{ .static = "overlay-action" },
                .label = "Overlay Action",
                .on_click_with_data = nogui.bind(PanelView.onOverlayClick, 0),
                .width = 280,
                .height = 48,
                .fill = c_sheet,
                .color = c_text,
            });
            _ = try ctx.label(.{ .text = panel.sheet_label });
            _ = try ctx.label(.{ .text = "overlay body" });
            _ = try ctx.label(.{ .text = "overlay tail" });
            ctx.pop();
            // Placement is authored HERE, in the draw that built the content.
            // The App resolves it after layout, before any custom paint, and
            // the same resolved frame is what paint, the inspector pick and
            // pointer routing all read.
            try ctx.place(.{
                .anchor = ctx.widgetIdOf(self.anchor_node.?) orelse
                    return error.OverlayAnchorUnkeyed,
                .content = ctx.widgetIdOf(self.sheet_node.?) orelse
                    return error.OverlayContentUnkeyed,
                .side = .below,
                .gap = 0,
                .margin = 0,
                .clip = .inherit,
            });
        } else {
            self.sheet_node = null;
        }
        if (panel.audit_open) {
            // A container that CLIPS its own content, holding a child whose
            // box is wider than the container. The overflow is the claim: the
            // child's box reaches past the clip, and the clip is what the
            // inspector reports as that node's constraint.
            self.clip_node = try ctx.column(.{
                .key = .{ .static = "clip-box" },
                .width = 300,
                .height = 120,
                .gap = 4,
                .padding = 6,
                // A paint clip rather than an overflow value, so the clip
                // chain the snapshot reports has exactly one authored cause.
                .clip = true,
                .transparent = true,
                .fill = c_clip_box,
            });
            self.clip_child = try ctx.button(.{
                .key = .{ .static = "clip-child" },
                .label = "Clip Child",
                .on_click_with_data = nogui.bind(PanelView.onClipClick, 0),
                // Unshrinkable, so the child box really does reach past the
                // container instead of being squeezed back inside it.
                .width = 420,
                .height = 40,
                .grow = 0,
                .shrink = 0,
                .fill = c_clip_child,
                .color = c_text,
            });
            ctx.pop();
            // Every style field below is authored here and read back from the
            // snapshot by the round trip; each one is a departure from the
            // default a snapshot would report instead.
            self.styled_node = try ctx.button(.{
                .key = .{ .static = "styled-target" },
                .label = panel.audit_label,
                .accessible_label = audit_accessible_label,
                .on_click_with_data = nogui.bind(PanelView.onStyledClick, 0),
                .width = 320,
                .height = 48,
                .gap = audit_gap,
                .grow = audit_grow,
                .shrink = 0,
                .box_sizing = .border_box,
                // The styled control clips its own label child, which is a
                // second, independent clip relationship to read back.
                .overflow = .{ .width = .hidden, .height = .hidden },
                .fill = panel.audit_fill,
                .radius = audit_radius,
                .opacity = audit_opacity,
                .layer = audit_layer,
                .border_color = c_spare,
                .shadows = &audit_shadows,
                .tab_index = audit_tab_index,
                .tab_group = audit_tab_group,
                .color = c_audit_text,
            });
            self.audit_label_node = try ctx.label(.{
                .text = "audit label",
                .font_size = audit_font_size,
                .color = c_audit_text,
            });
        } else {
            self.clip_node = null;
            self.clip_child = null;
            self.styled_node = null;
            self.audit_label_node = null;
        }
        ctx.pop();
    }

    /// The target control's own activation path. A pointer event that only
    /// reached the hit-test would not move this counter.
    pub fn onClick(self: *PanelView, _: usize) void {
        self.clicks += 1;
    }

    /// The spare control's own activation path. A press the overlay is
    /// painted over must never move this.
    pub fn onSpareClick(self: *PanelView, _: usize) void {
        self.spare_clicks += 1;
    }

    /// The overlay's own activation path, on a node inside the placement.
    pub fn onOverlayClick(self: *PanelView, _: usize) void {
        self.overlay_clicks += 1;
    }

    /// The clipped child's own activation path. A press the inspector and the
    /// engine both name must land here; a press on the part of its box the
    /// clip hides must not reach it at all.
    pub fn onClipClick(self: *PanelView, _: usize) void {
        self.clip_clicks += 1;
    }

    /// The styled control's own activation path.
    pub fn onStyledClick(self: *PanelView, _: usize) void {
        self.styled_clicks += 1;
    }
};

// ── Bounded-collector bridging ─────────

/// Forwards the REAL task service observer facts into the inspector's task
/// collector. `Application` does not wire these hooks itself, so the smoke owns
/// that wiring; the facts themselves are produced by the real service.
const TaskBridge = struct {
    inspector: *Inspector,
    queued_facts: u32 = 0,
    finished_facts: u32 = 0,

    fn observer(self: *TaskBridge) nogui.task.Observer {
        return .{ .user = self, .on_queued = onQueued, .on_finished = onFinished };
    }

    fn onQueued(context: *anyopaque, fact: nogui.task.QueuedTask) void {
        const self: *TaskBridge = @ptrCast(@alignCast(context));
        self.queued_facts += 1;
        self.inspector.onTaskQueued(
            fact.id,
            fact.priority,
            fact.queued_ns,
            fact.name,
            fact.window,
        );
    }

    fn onFinished(context: *anyopaque, fact: nogui.task.FinishedTask) void {
        const self: *TaskBridge = @ptrCast(@alignCast(context));
        self.finished_facts += 1;
        self.inspector.onTaskFinished(
            fact.id,
            fact.priority,
            fact.queued_ns,
            fact.start_ns,
            fact.end_ns,
            fact.name,
            fact.window,
        );
    }
};

/// Real worker payload: a real sleep on the service's private thread pool.
const Work = struct {
    sleep_ns: i96 = 0,

    fn run(self: *Work, io: std.Io) void {
        std.Io.sleep(io, .fromNanoseconds(self.sleep_ns), .real) catch |err| switch (err) {
            // Shutdown may cancel the wait; the span is measured either way.
            error.Canceled => {},
        };
    }
};

const Dispatch = nogui.action.Action(void, "smoke.dispatch");

// ── Reporting ──────────────────────────

const Reporter = struct {
    io: Io,
    buffer: [8192]u8 = [_]u8{0} ** 8192,

    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.buffer, fmt, args);
        try Io.File.stdout().writeStreamingAll(self.io, text);
    }
};

fn deviceExtent(managed: managed_window_ptr) !noapi.Extent2D {
    const pixels = try managed.native.sdl.getSizeInPixels();
    return .{ .width = @intCast(pixels[0]), .height = @intCast(pixels[1]) };
}

fn widgetIdText(id: WidgetId, out: []u8) []const u8 {
    return std.fmt.bufPrint(out, "owner=0x{x}/slot={d}/gen={d}", .{
        id.owner,
        id.slot,
        id.generation,
    }) catch "<overflow>";
}

fn rectText(r: nogui.Rect, out: []u8) []const u8 {
    return std.fmt.bufPrint(out, "x={d:.1} y={d:.1} w={d:.1} h={d:.1}", .{
        r.x,
        r.y,
        r.w,
        r.h,
    }) catch "<overflow>";
}

fn inside(r: nogui.Rect, p: [2]f32) bool {
    return p[0] >= r.x and p[0] < r.x + r.w and p[1] >= r.y and p[1] < r.y + r.h;
}

/// Two boxes the same to within a hundredth of a logical pixel. The snapshot
/// copies the rects the engine computed rather than recomputing them, so an
/// exact match is expected; the slack covers nothing but a formatting round.
fn rectSame(a: nogui.Rect, b: nogui.Rect) bool {
    return @abs(a.x - b.x) <= 0.01 and @abs(a.y - b.y) <= 0.01 and
        @abs(a.w - b.w) <= 0.01 and @abs(a.h - b.h) <= 0.01;
}

/// The overlap of two boxes, or null when they do not overlap.
fn rectOverlap(a: nogui.Rect, b: nogui.Rect) ?nogui.Rect {
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    const right = @min(a.x + a.w, b.x + b.w);
    const bottom = @min(a.y + a.h, b.y + b.h);
    if (right <= x or bottom <= y) return null;
    return .{ .x = x, .y = y, .w = right - x, .h = bottom - y };
}

/// Every channel equal, to the precision a copied float keeps.
fn colorSame(a: [4]f32, b: [4]f32) bool {
    inline for (0..4) |channel| {
        if (@abs(a[channel] - b[channel]) > 0.000_001) return false;
    }
    return true;
}

/// Whether the snapshot's own child list of `parent` names `child`. Both
/// sides of the same relationship, read from the public hierarchy rather
/// than from the tree the snapshot was taken from.
fn childContains(
    snap: *const FrameSnapshot,
    parent: *const NodeSnapshot,
    child: *const NodeSnapshot,
) bool {
    for (snap.children(parent)) |index| {
        if (index == child.index) return true;
    }
    return false;
}

/// The resolved style and semantic fields one node reports, in one line.
fn styleText(node: *const NodeSnapshot, out: []u8) []const u8 {
    return std.fmt.bufPrint(
        out,
        "role={s} label=\"{s}\" accessible=\"{s}\" " ++
            "fill=[{d:.3} {d:.3} {d:.3} {d:.3}] radius=[{d:.1} {d:.1} {d:.1} {d:.1}] " ++
            "opacity={d:.2} layer={d} gap={d:.1} grow={d:.2} shrink={d:.1} " ++
            "box_sizing={s} overflow=[{s} {s}] clips_content={} has_shadow={} " ++
            "text_size={d:.1} visible={} enabled={}",
        .{
            @tagName(node.semantics.role),
            node.semantics.label orelse "<none>",
            node.semantics.accessible_label orelse "<none>",
            node.style.fill[0],
            node.style.fill[1],
            node.style.fill[2],
            node.style.fill[3],
            node.style.radius.top,
            node.style.radius.right,
            node.style.radius.bottom,
            node.style.radius.left,
            node.style.opacity,
            node.style.layer,
            node.style.gap,
            node.style.grow,
            node.style.shrink,
            @tagName(node.style.box_sizing),
            @tagName(node.style.overflow.width),
            @tagName(node.style.overflow.height),
            node.style.clips_content,
            node.style.has_shadow,
            node.style.text_size,
            node.is_visible,
            node.is_enabled,
        },
    ) catch "<overflow>";
}

/// The focus and capture fields one node reports, in one line.
fn focusText(node: *const NodeSnapshot, out: []u8) []const u8 {
    var id_buf: [96]u8 = undefined;
    return std.fmt.bufPrint(
        out,
        "is_focused={} contains_focus={} can_focus={} tab_index={?d} tab_group={?d} " ++
            "captured={} pointers={d} id={s}",
        .{
            node.focus.is_focused,
            node.focus.contains_focus,
            node.focus.can_focus,
            node.focus.tab_index,
            node.focus.tab_group,
            node.capture.is_captured,
            node.capture.pointer_count,
            widgetIdText(node.id, &id_buf),
        },
    ) catch "<overflow>";
}

fn nodeText(node: *const NodeSnapshot, out: []u8) []const u8 {
    var id_buf: [96]u8 = undefined;
    var vis_buf: [96]u8 = undefined;
    var lay_buf: [96]u8 = undefined;
    return std.fmt.bufPrint(
        out,
        "index={d} role={s} id={s} handle_gen={d} label=\"{s}\" visual=[{s}] layout=[{s}]" ++
            " visible={} enabled={} overlay={}",
        .{
            node.index,
            @tagName(node.semantics.role),
            widgetIdText(node.id, &id_buf),
            node.handle.generation,
            node.semantics.label orelse "<none>",
            rectText(node.visual_bounds, &vis_buf),
            rectText(node.layout_bounds, &lay_buf),
            node.is_visible,
            node.is_enabled,
            node.is_overlay,
        },
    ) catch "<overflow>";
}

/// First node in snapshot order with the given semantic role and label prefix.
fn findNode(
    snap: *const FrameSnapshot,
    role: inspection.Role,
    label_prefix: []const u8,
) ?*const NodeSnapshot {
    for (snap.nodes) |*node| {
        if (node.semantics.role != role) continue;
        const label = node.semantics.label orelse continue;
        if (std.mem.startsWith(u8, label, label_prefix)) return node;
    }
    return null;
}

/// A point inside `node` but outside every one of its children, chosen from a
/// fixed candidate order. A control paints its own label as a child, so this
/// is the point at which the CONTROL is the deepest node — which is what makes
/// "pick target == input target" a one-to-one comparison instead of a walk up
/// the ancestor chain. Returns null when the control has no such padding.
fn probeOnControl(
    snap: *const FrameSnapshot,
    node: *const NodeSnapshot,
    /// A resolved box the point must NOT fall inside: the overlay's own
    /// placement, when the control is painted over. A probe under an overlay
    /// measures the OVERLAY's routing, not the control underneath it, so a
    /// covered control needs a point the placement does not reach.
    avoid: ?nogui.Rect,
) ?[2]f32 {
    const r = node.visual_bounds;
    const candidates = [_][2]f32{
        .{ r.x + r.w / 2, r.y + 1 },
        .{ r.x + 1, r.y + r.h / 2 },
        .{ r.x + r.w - 2, r.y + r.h / 2 },
        .{ r.x + r.w / 2, r.y + r.h - 2 },
    };
    for (candidates) |candidate| {
        if (!inside(r, candidate)) continue;
        if (avoid) |box| {
            if (inside(box, candidate)) continue;
        }
        var covered = false;
        for (snap.children(node)) |child_index| {
            if (inside(snap.nodes[child_index].visual_bounds, candidate)) {
                covered = true;
                break;
            }
        }
        if (!covered) return candidate;
    }
    return null;
}

/// The stable target the engine's PUBLIC routing would activate at `point`:
/// the overlay-aware total hit test, falling back to the plain tree walk when
/// no overlay covers the point. `nogui.input.hitStable` on its own answers
/// only the unranked tree, which is deliberately not what input routes under
/// an overlay — so it is the wrong reference for a focus claim.
fn routedStableTarget(
    tree: *const nogui.WidgetTree,
    overlay_frame: *const overlay.Frame,
    point: [2]f32,
) ?WidgetId {
    return overlay_frame.hitStableTotal(tree, point) orelse
        nogui.input.hitStable(tree, point);
}

/// A model takes its value at create time, so the read-side copy lives here.
const PanelFacts = struct {
    target: []const u8 = "",
    spare: []const u8 = "",
    sheet_open: bool = false,
    sheet_label: []const u8 = "",
    audit_open: bool = false,
    audit_label: []const u8 = "",
    variant: u32 = 0,
    dispatched: u32 = 0,
    tasks_done: u32 = 0,
};

fn readPanel(panel: *const Panel, out: *PanelFacts) void {
    out.* = .{
        .target = panel.target,
        .spare = panel.spare,
        .sheet_open = panel.sheet_open,
        .sheet_label = panel.sheet_label,
        .audit_open = panel.audit_open,
        .audit_label = panel.audit_label,
        .variant = panel.variant,
        .dispatched = panel.dispatched,
        .tasks_done = panel.tasks_done,
    };
}

/// One stable word for a resolve outcome: `ok` or the error name. A resolve
/// that silently succeeds on a replaced node must not print as a flat pass.
fn resolveOutcome(result: inspection.InspectError!*const NodeSnapshot) []const u8 {
    if (result) |_| return "ok" else |err| return @errorName(err);
}

fn childBoundsText(snap: *const FrameSnapshot, node: *const NodeSnapshot, out: []u8) []const u8 {
    var writer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer writer.deinit();
    for (snap.children(node), 0..) |child_index, position| {
        const child = snap.nodes[child_index];
        var id_buf: [96]u8 = undefined;
        var rect_buf: [96]u8 = undefined;
        writer.writer.print(
            "{s}[{d}] role={s} id={s} visual=[{s}]",
            .{
                if (position == 0) "" else " ",
                child.index,
                @tagName(child.semantics.role),
                widgetIdText(child.id, &id_buf),
                rectText(child.visual_bounds, &rect_buf),
            },
        ) catch break;
    }
    return std.fmt.bufPrint(out, "{s}", .{writer.written()}) catch "<overflow>";
}

// ── The smoke ──────────────────────────

/// One probed pixel: where it is, what the frame was told to paint there, and
/// what the readback actually produced. `expected` is in the Oklab
/// intermediate the scene is recorded in; `final` is the sRGB image the blit
/// produced from it, which only the offscreen target can be copied back from.
const Probe = struct {
    point: [2]f32 = .{ 0, 0 },
    expected: [4]f32 = .{ 0, 0, 0, 0 },
    observed: [4]f32 = .{ 0, 0, 0, 0 },
    final: [4]f32 = .{ 0, 0, 0, 0 },
    final_expected: [4]f32 = .{ 0, 0, 0, 0 },
    /// Armed probes are recorded in the next committed frame and read back
    /// once that frame is submitted and the queue is idle.
    armed: bool = false,

    fn matched(self: *const Probe) bool {
        return oklabMatches(self.observed, self.expected);
    }

    fn finalMatched(self: *const Probe) bool {
        return srgbMatches(self.final, self.final_expected);
    }
};

const probe_pick = 0;
const probe_sheet = 1;
const probe_agree = 2;
const probe_background = 3;
const probe_count = 4;

// ── GPU timestamp instrumentation ─────

/// One measured span: the two raw query values the device wrote, the frame
/// the work belonged to, and the nanoseconds those ticks are worth at the
/// device's own period. Every field past the raw values stays zero until a
/// read produced two real timestamps, so a refused read can never be
/// mistaken for a frame that took no time.
const TimingSpan = struct {
    frame_number: u64 = 0,
    first_query: u32 = 0,
    start_tick: u64 = 0,
    end_tick: u64 = 0,
    ticks: u64 = 0,
    elapsed_ns: u64 = 0,
    valid: bool = false,
    /// The span has been offered to the frame collector. Kept apart from
    /// `attached` so an unattributable span is counted once, not once per
    /// flush.
    offered: bool = false,
    attached: bool = false,
};

/// The measured span in nanoseconds, or null when the device's period cannot
/// turn its own tick count into one. Nothing here estimates: a span that
/// cannot be converted is refused rather than rounded into a guess.
fn elapsedNs(info: noapi.TimestampInfo, start_ticks: u64, end_ticks: u64) ?u64 {
    const ticks = info.spanTicks(start_ticks, end_ticks);
    const scaled = @as(f64, @floatFromInt(ticks)) * info.period_ns;
    if (!std.math.isFinite(scaled) or scaled < 0) return null;
    if (scaled >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return null;
    return @intFromFloat(scaled);
}

/// Opt-in GPU timestamps, taken on the device and read back only after the
/// work that wrote them has finished.
///
/// Off is the default and is genuinely inert: no query set is created, every
/// call site is one predictable branch on `enabled`, and nothing is allocated
/// per frame. On, the span is recorded into the frame's OWN command buffer —
/// reset at the top, written at the top and after the last copy — so it
/// brackets exactly the work that frame submitted, and the read happens at a
/// queue-idle boundary after that submission. The span is then joined to the
/// frame record the host already kept for that frame.
const GpuTiming = struct {
    gpu: *noapi.Gpu,
    /// True when the run asked for measurement, whatever the device then said.
    requested: bool = false,
    /// Why the instrumentation is inert despite being requested, if it is.
    refusal: ?[]const u8 = null,
    set: ?noapi.TimestampQuerySet = null,
    info: ?noapi.TimestampInfo = null,
    cursor: u32 = 0,
    pending_first: ?u32 = null,
    pending_frame: u64 = 0,
    /// Bounded ring of measured spans: the newest `span_count` of them, oldest
    /// first when read out.
    spans: [timing_span_capacity]TimingSpan = @splat(.{}),
    span_cursor: usize = 0,
    span_count: usize = 0,
    frames_written: u32 = 0,
    frames_read: u32 = 0,
    reads_refused: u32 = 0,
    attached: u32 = 0,
    unattached: u32 = 0,

    /// Ask the device once, before the first frame. A queue with no timestamp
    /// queries, or a query set the device refuses, leaves the instrumentation
    /// inert and records why: no timing is then reported at all.
    fn init(gpu: *noapi.Gpu, requested: bool) GpuTiming {
        var self: GpuTiming = .{ .gpu = gpu, .requested = requested };
        if (!requested) return self;
        self.info = gpu.timestampInfo() orelse {
            self.refusal = "the device queue reports no timestamp queries";
            return self;
        };
        self.set = gpu.timestampQuerySetCreate(timing_slots * timing_queries_per_frame) catch |err| switch (err) {
            error.TimestampQueriesUnsupported => {
                self.refusal = "the device refuses timestamp queries";
                self.info = null;
                return self;
            },
            else => {
                self.refusal = "the device could not create a timestamp query set";
                self.info = null;
                return self;
            },
        };
        return self;
    }

    fn deinit(self: *GpuTiming) void {
        if (self.set) |set| self.gpu.timestampQuerySetDestroy(set);
        // The query set is the device's own storage and it is gone above. The
        // owner drops this pointer in the same breath, so a later read is a
        // bug rather than a null check that happens to pass.
        self.* = undefined;
    }

    /// The one branch every call site pays. False means this run records,
    /// reads and reports nothing.
    fn enabled(self: *const GpuTiming) bool {
        return self.set != null and self.info != null;
    }

    /// Reserve this frame's query pair and open its span, or null when the
    /// instrumentation is inert. The reset and the opening write go into the
    /// frame's command buffer, so both belong to work that is submitted.
    fn beginFrame(self: *GpuTiming, cmd: *noapi.CommandBuffer) ?u32 {
        if (!self.enabled()) return null;
        const set = self.set.?;
        const first = self.cursor * timing_queries_per_frame;
        self.cursor = (self.cursor + 1) % timing_slots;
        cmd.timestampReset(set, first, timing_queries_per_frame) catch return null;
        cmd.timestampWrite(set, first, .all_commands_start) catch return null;
        self.frames_written += 1;
        return first;
    }

    /// Close the span after the frame's last recorded command. `frame_number`
    /// is the generation the host will stamp on the record it writes once this
    /// callback returns, so the span and the record name the same frame.
    fn endFrame(
        self: *GpuTiming,
        cmd: *noapi.CommandBuffer,
        first: ?u32,
        frame_number: u64,
    ) void {
        const query = first orelse return;
        if (!self.enabled()) return;
        cmd.timestampWrite(self.set.?, query + 1, .all_commands_end) catch return;
        self.pending_first = query;
        self.pending_frame = frame_number;
    }

    /// Wait for the queue, then read the pair this frame just submitted. This
    /// is the safe completion boundary: nothing is read while the work that
    /// wrote the timestamps may still be in flight, and nothing is read for a
    /// frame that was never submitted.
    fn readFrame(self: *GpuTiming) void {
        const first = self.pending_first orelse return;
        const frame_number = self.pending_frame;
        self.pending_first = null;
        if (!self.enabled()) return;
        self.gpu.waitIdle() catch {
            self.reads_refused += 1;
            return;
        };
        var ticks: [timing_queries_per_frame]u64 = undefined;
        self.gpu.timestampQuerySetRead(self.set.?, first, &ticks) catch {
            self.reads_refused += 1;
            return;
        };
        // A pool that was reset and never written reads back as zeroes. That
        // is not a frame that took no time, so it is refused rather than
        // reported.
        if (ticks[0] == 0 or ticks[1] == 0) {
            self.reads_refused += 1;
            return;
        }
        const info = self.info.?;
        const elapsed = elapsedNs(info, ticks[0], ticks[1]) orelse {
            self.reads_refused += 1;
            return;
        };
        self.frames_read += 1;
        self.push(.{
            .frame_number = frame_number,
            .first_query = first,
            .start_tick = ticks[0],
            .end_tick = ticks[1],
            .ticks = info.spanTicks(ticks[0], ticks[1]),
            .elapsed_ns = elapsed,
            .valid = true,
        });
    }

    /// Store one measured span, overwriting the oldest.
    fn push(self: *GpuTiming, span: TimingSpan) void {
        self.spans[self.span_cursor] = span;
        self.span_cursor = (self.span_cursor + 1) % self.spans.len;
        if (self.span_count < self.spans.len) self.span_count += 1;
    }

    /// Join every measured span to the frame record the host wrote for it,
    /// newest first: the record for a just-measured frame is the one still at
    /// the head of the bounded ring. A span no retained record names is
    /// counted, never dropped silently.
    fn flush(self: *GpuTiming, inspector: *Inspector) void {
        if (!self.enabled()) return;
        var walked: usize = 0;
        while (walked < self.span_count) : (walked += 1) {
            const slot = (self.span_cursor + self.spans.len - 1 - walked) % self.spans.len;
            const span = &self.spans[slot];
            if (!span.valid or span.offered) continue;
            span.offered = true;
            if (inspector.attachGpuExecute(span.frame_number, span.elapsed_ns)) {
                span.attached = true;
                self.attached += 1;
            } else {
                self.unattached += 1;
            }
        }
    }
};

const Smoke = struct {
    io: Io,
    application: *Application,
    app: *App,
    handle: contract.WindowHandle,
    target: *Target,
    cleanup: *Cleanup,
    endpoint: *nogui.GpuEndpoint,
    inspector: *Inspector,
    bridge: *TaskBridge,
    view: *PanelView,

    painter: *Painter,
    /// The painted selection, copied BY VALUE. The inspector frees the
    /// snapshot it came from two captures later, so a pointer here would
    /// dangle as soon as the run drives more frames; only the bounds are
    /// read back out of it, and those own no memory.
    selection: ?NodeSnapshot = null,
    probe: [2]f32 = .{ 0, 0 },
    probes: [probe_count]Probe = @splat(.{}),
    /// Opt-in GPU timestamps. Borrowed, and owned by the run that asked the
    /// device for them; inert unless `--gpu-timing` did, and then paid for by
    /// one branch per frame.
    timing: *GpuTiming,
    /// Set while a frame must copy its FINAL sRGB image back, so an image
    /// dump reads a real submitted frame rather than whatever the buffer
    /// happened to hold.
    ppm_armed: bool = false,
    /// The frame's real overlay registration, resolved against the tree the
    /// frame just committed and handed to the inspector before it captures.
    overlay: overlay.Frame,
    /// The placement the last resolve produced, copied by value so the scene
    /// keeps painting it after the frame's records move on.
    placement: ?overlay.Placement = null,
    anchor_id: ?WidgetId = null,
    sheet_id: ?WidgetId = null,
    overlays_resolved: u32 = 0,
    /// Observed logical window size, refreshed every frame.
    logical_size: struct { width: u32, height: u32 } = .{ .width = 0, .height = 0 },

    tick: u32 = 1,
    frames_committed: u32 = 0,
    frames_presented: u32 = 0,
    host_running: bool = true,

    fn deinitOverlay(self: *Smoke) void {
        self.overlay.deinit();
    }

    /// Rebuild the painted scene from the current inspection state.
    fn buildScene(self: *Smoke) !void {
        self.painter.rects.clearRetainingCapacity();
        try self.painter.addRect(.{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(self.logicalWidth()),
            .h = @floatFromInt(self.logicalHeight()),
        }, srgbToOklab(palette_background, 1), 0);

        // The inspected target, painted at the bounds the inspector reported
        // for the node it selected, not at any hard-coded geometry.
        if (self.selection) |node| {
            try self.painter.addRect(node.visual_bounds, srgbToOklab(palette_target, 1), 1);
            try self.painter.addFrame(
                node.visual_bounds,
                srgbToOklab(palette_overlay, 1),
                10,
                3,
            );
        }
        // The resolved overlay placement, painted where the engine put it.
        // With no placement there is nothing over a sheet probe, so the
        // expectation follows the scene instead of the run's intent: a frame
        // that stopped painting the sheet must be read back as background.
        const sheet_oklab = srgbToOklab(palette_sheet, 1);
        const sheet_srgb = [4]f32{ palette_sheet[0], palette_sheet[1], palette_sheet[2], 1 };
        const background_oklab = srgbToOklab(palette_background, 1);
        const background_srgb = [4]f32{
            palette_background[0],
            palette_background[1],
            palette_background[2],
            1,
        };
        if (self.placement) |placement| {
            // Above the selection fill and its frame, below the probe marker:
            // the placement is the topmost thing the frame paints anywhere it
            // covers, and the marker stays readable on top of it.
            try self.painter.addRect(placement.rect, sheet_oklab, 15);
            try self.painter.addFrame(placement.rect, sheet_oklab, 16, 2);
        }
        // The probe marker sits last, so the pixel under it is the marker's.
        try self.painter.addRect(.{
            .x = self.probe[0] - 4,
            .y = self.probe[1] - 4,
            .w = 8,
            .h = 8,
        }, srgbToOklab(palette_overlay, 1), 20);

        self.probes[probe_pick].point = self.probe;
        self.probes[probe_pick].expected = srgbToOklab(palette_overlay, 1);
        self.probes[probe_pick].final_expected = .{
            palette_overlay[0],
            palette_overlay[1],
            palette_overlay[2],
            1,
        };
        self.probes[probe_background].point = .{
            1,
            @as(f32, @floatFromInt(self.logicalHeight())) - 1,
        };
        self.probes[probe_background].expected = background_oklab;
        self.probes[probe_background].final_expected = background_srgb;
        inline for ([_]usize{ probe_sheet, probe_agree }) |slot_index| {
            const slot = &self.probes[slot_index];
            slot.expected = if (self.placement != null) sheet_oklab else background_oklab;
            slot.final_expected = if (self.placement != null) sheet_srgb else background_srgb;
        }
    }

    fn logicalWidth(self: *const Smoke) u32 {
        return self.logical_size.width;
    }

    fn logicalHeight(self: *const Smoke) u32 {
        return self.logical_size.height;
    }

    /// The device extent this frame records at. The offscreen target is
    /// 1:1 with the logical window, so it needs no display scale; the
    /// swapchain path asks the window.
    fn frameExtent(self: *const Smoke, managed: managed_window_ptr) noapi.Extent2D {
        return switch (self.target.*) {
            .swapchain => deviceExtent(managed) catch self.target.swapchain.surfaceSize(),
            .image => .{
                .width = self.logicalWidth(),
                .height = self.logicalHeight(),
            },
        };
    }

    /// Read the placement the App already resolved for the tree it published.
    /// Nothing is resolved here: the view registered the record during its draw
    /// and the App placed it after layout, so the host capture below, the
    /// pixels and the pointer events all name the SAME box.
    fn readResolvedPlacement(self: *Smoke) void {
        self.placement = null;
        const tree = self.app.tree_ptr orelse return;
        const anchor_frame_node = self.view.anchor_node orelse return;
        const sheet_frame_node = self.view.sheet_node orelse return;
        self.anchor_id = widgetIdAt(tree, anchor_frame_node);
        self.sheet_id = widgetIdAt(tree, sheet_frame_node);
        const content = self.sheet_id orelse return;
        self.placement = self.overlay.placement(tree, content);
        self.overlays_resolved += 1;
    }

    fn anyProbeArmed(self: *const Smoke) bool {
        for (self.probes) |slot| {
            if (slot.armed) return true;
        }
        return false;
    }

    /// True when this frame has to copy its FINAL sRGB image back into
    /// host-visible memory. An image dump needs the whole frame, the pixel
    /// probes need single pixels out of the same copy, and neither costs a
    /// copy when no probe and no dump asked for one.
    fn wantsFinalReadback(self: *const Smoke) bool {
        return self.anyProbeArmed() or self.ppm_armed;
    }

    /// One host step, then the measured spans are joined to the frame records
    /// that step produced. The host records a frame AFTER its callback
    /// returns, so the join cannot happen inside the frame that measured it.
    fn step(self: *Smoke) !bool {
        const running = try self.application.step();
        self.timing.flush(self.inspector);
        return running;
    }

    /// One committed frame plus, in windowed mode, one presented swapchain
    /// image.
    ///
    /// The window paints the inspector's own view: the inspected target, the
    /// selection frame, the resolved overlay placement and a probe marker,
    /// drawn through the public renderer into an Oklab target and blitted to
    /// the destination image. The widget tree itself is NOT rendered: the gate
    /// under test is what the inspector reports and where it puts it.
    fn render(self: *Smoke) !bool {
        const managed = try self.application.getWindow(self.handle);
        const logical = managed.observed.size;
        self.logical_size = .{ .width = logical.width, .height = logical.height };
        const extent = self.frameExtent(managed);
        const started = self.target.begin(extent) catch |err| {
            if (err == error.OutOfDateKHR) {
                self.target.notifyResize(extent);
                return false;
            }
            return err;
        };
        if (!started) return false;
        var cmd = try self.target.commands();
        // Opened before anything else is recorded, so the span brackets the
        // frame's whole recording. Null whenever the instrumentation is off.
        const timing_first = self.timing.beginFrame(&cmd);
        var gpu_frame: nogui.GpuFrame = .{
            .endpoint = self.endpoint,
            .command_buffer = &cmd,
            .extent = extent,
            .frame_index = self.frames_committed,
            .recording = .{ .active = self.target.cancellation() },
        };
        var recording_active = true;
        errdefer if (recording_active) gpu_frame.cancelRecording() catch
            @panic("W24 smoke frame recording cancellation failed");

        try self.buildScene();
        try self.painter.submit(
            &cmd,
            self.target.color(),
            extent,
            .{ @floatFromInt(logical.width), @floatFromInt(logical.height) },
        );
        // The readbacks are recorded AFTER the scene has been submitted and
        // the color output is available to a transfer; recorded before that,
        // each copy would read the cleared attachment.
        if (self.wantsFinalReadback()) {
            try self.target.readFinal(&cmd);
            try self.painter.readPixel(&cmd);
        }
        const time_ms = sdl3.timer.getMillisecondsSinceInit();
        self.app.dispatchRootFrame(time_ms);
        _ = try self.app.frameWithGpuAtTime(
            self.tick,
            time_ms,
            .{ .width = @floatFromInt(logical.width), .height = @floatFromInt(logical.height) },
            &gpu_frame,
        );
        // The overlay placements this frame reports are resolved against the
        // tree it just committed, before the host captures a snapshot from it.
        self.readResolvedPlacement();
        gpu_frame.finishRecording();
        recording_active = false;
        // Closed after the last recorded command and named with the
        // generation the host will stamp on this frame's own record.
        self.timing.endFrame(&cmd, timing_first, self.app.frame_generation);
        try self.target.submit(&cmd);
        self.frames_committed += 1;
        if (self.target.presents()) self.frames_presented += 1;
        self.tick += 1;
        // Only submitted work carries a measurable span, and it is read at a
        // queue-idle boundary after that submission.
        self.timing.readFrame();
        // The copies were recorded in the frame that produced them, and they
        // read host-visible buffers, so they are read back after that frame is
        // submitted and the queue is idle.
        if (self.wantsFinalReadback()) {
            try self.painter.gpu.waitIdle();
            for (&self.probes) |*slot| {
                if (!slot.armed) continue;
                slot.observed = try self.painter.readIdle(slot.point);
            }
            switch (self.target.*) {
                .image => |*image| {
                    for (&self.probes) |*slot| {
                        if (!slot.armed) continue;
                        slot.final = try image.readPixelIdle(slot.point);
                    }
                },
                .swapchain => {},
            }
        }
        return true;
    }

    fn onFrame(
        context: *anyopaque,
        _: *Application,
        _: managed_window_ptr,
        _: nogui.frame_demand.FrameDemand.Work,
    ) anyerror!bool {
        const self: *Smoke = @ptrCast(@alignCast(context));
        return self.render();
    }
    fn onBeforeClose(context: *anyopaque, _: managed_window_ptr) void {
        const self: *Smoke = @ptrCast(@alignCast(context));
        self.cleanup.releaseTarget();
    }

    fn onQuitRequest(_: *anyopaque, _: *Application, _: Application.QuitToken) Application.QuitDecision {
        return .approve;
    }
};

fn widgetIdAt(tree: *const nogui.WidgetTree, id: FrameNodeId) ?WidgetId {
    const node = tree.nodeConst(id) orelse return null;
    return node.widget_id;
}

/// One point chosen out of a resolved placement, with the node the engine's
/// own overlay hit test named there.
const ScanPoint = struct {
    point: [2]f32,
    node: FrameNodeId,
};

/// How finely a placement is walked. The walk only exists to pick a probe out
/// of geometry the engine resolved, so its resolution is fixed rather than
/// derived from a hard-coded coordinate.
const scan_samples: f32 = 96;

/// Walks a resolved placement and returns the first point that satisfies the
/// walk's rule. `cover` asks for a point the placement is painted over a
/// control input still routes to; without it, the point is the first one the
/// tree's own pointer hit test places inside the overlay's laid-out box.
const PlacementWalk = struct {
    tree: *const nogui.WidgetTree,
    frame: *const overlay.Frame,
    rect: nogui.Rect,
    /// The overlay content's laid-out box, before placement moved it.
    flow: nogui.Rect,
    cover: bool,

    fn first(self: *const PlacementWalk) ?ScanPoint {
        if (self.rect.w <= 0 or self.rect.h <= 0) return null;
        const step_x = @max(1, self.rect.w / scan_samples);
        const step_y = @max(1, self.rect.h / scan_samples);
        var y = self.rect.y + 1;
        while (y < self.rect.y + self.rect.h) : (y += step_y) {
            var x = self.rect.x + 1;
            while (x < self.rect.x + self.rect.w) : (x += step_x) {
                const point = [2]f32{ x, y };
                const overlay_hit = self.frame.hitTest(self.tree, point) orelse continue;
                const input_hit = nogui.input.hitTest(self.tree, point);
                if (self.cover) {
                    // The point has to be one where the overlay's OWN control
                    // is painted. The claim under test is that a press there
                    // reaches the overlay's action, so a point the overlay
                    // merely draws over is not evidence of anything.
                    const actionable = self.frame.hitActionableTotal(self.tree, point) orelse continue;
                    if (!self.frame.isOverlayNode(self.tree, actionable)) continue;
                    if (overlay_hit == input_hit) continue;
                } else {
                    const routed = input_hit orelse continue;
                    if (!inside(self.flow, point)) continue;
                    if (!self.frame.isOverlayNode(self.tree, routed)) continue;
                }
                return .{ .point = point, .node = overlay_hit };
            }
        }
        return null;
    }
};

fn cancelSurfaceRecording(context: *anyopaque, _: *noapi.CommandBuffer) !void {
    const surface: *noapi.Surface = @ptrCast(@alignCast(context));
    try surface.abortFrame();
}

var exts_storage: []const [*:0]const u8 = &.{};

fn getExts() []const [*:0]const u8 {
    return exts_storage;
}

/// State this window's frame demand, then take one host step.
///
/// The host only draws a window that says it wants frames, and it re-derives
/// that from the observed window state after every presented frame. The
/// offscreen target owns no mapped window at all — there is no display server
/// behind it to observe — so this run states its own demand for it instead of
/// asking a compositor that does not exist. The presented path keeps the
/// host's own visibility policy untouched.
fn stepWithDemand(smoke: *Smoke) !bool {
    const managed = try smoke.application.getWindow(smoke.handle);
    if (!smoke.target.presents()) managed.demand.setVisible(true);
    return smoke.step();
}

/// Pump the external loop until `predicate` holds, the host stops, or the
/// deadline passes. Returns whether the predicate settled.
fn pumpUntil(
    smoke: *Smoke,
    deadline_ms: u64,
    context: *const fn (*Smoke) bool,
) !bool {
    while (sdl3.timer.getMillisecondsSinceInit() < deadline_ms) {
        if (!try stepWithDemand(smoke)) {
            smoke.host_running = false;
            break;
        }
        if (context(smoke)) return true;
        try Io.sleep(smoke.io, Io.Duration.fromMilliseconds(2), .real);
    }
    return context(smoke);
}

/// The host draws only on demand. The window's first frame is the only one
/// that needs no request, so waiting for a second one here would spin until
/// the deadline and prove nothing.
fn framesSettled(smoke: *Smoke) bool {
    return smoke.frames_committed >= 1;
}

/// Drive exactly `count` further committed frames, one invalidation per host
/// step. The window is never told to re-present, so the only frames that can
/// commit are the ones requested here.
fn driveFrames(smoke: *Smoke, count: u32) !u64 {
    const start = smoke.app.frame_generation;
    const deadline = sdl3.timer.getMillisecondsSinceInit() + 10_000;
    while (smoke.app.frame_generation - start < count) {
        if (sdl3.timer.getMillisecondsSinceInit() > deadline) return error.FrameBudgetExpired;
        const managed = try smoke.application.getWindow(smoke.handle);
        if (!smoke.target.presents()) managed.demand.setVisible(true);
        managed.demand.invalidateLayout();
        _ = try smoke.step();
    }
    return smoke.app.frame_generation - start;
}

fn tasksSettled(smoke: *Smoke) bool {
    return smoke.bridge.finished_facts >= bounded_tasks;
}

/// One owner for everything `main` creates, released in ONE order on the
/// success path and on the failure path alike.
///
/// The target goes before its native window and SDL connection. The host then
/// closes while its borrowed App, view and inspector remain alive.
/// Each field is null until its resource exists, so a failure during
/// construction releases exactly what was built — one owner, one order, and no
/// second chain of teardown handlers racing the first.
const Cleanup = struct {
    gpa: std.mem.Allocator,
    application: ?*Application = null,
    /// The real task service forwards its observer facts into the inspector,
    /// so its observer is cleared before the inspector is destroyed.
    task_service: ?*nogui.task.Service = null,
    inspector: ?*Inspector = null,
    /// Borrowed by the inspector, which detaches its observer before this is
    /// destroyed.
    registry: ?*nogui.action.Registry = null,
    /// The overlay frame the App and the inspector both borrow.
    overlay_frame: ?*overlay.Frame = null,
    timing: ?*GpuTiming = null,
    target: ?*Target = null,
    painter: ?*Painter = null,
    app: ?*App = null,
    view: ?*PanelView = null,
    /// The model's session handle, released back to the owner that made it.
    panel: ?*nogui.Model(Panel) = null,
    gpu: ?*noapi.Gpu = null,
    /// The Vulkan code the device was resolved through: closed only after the
    /// device is gone.
    loader: ?*frame.SystemVulkanLoader = null,
    /// The session's own leak check, kept so the shutdown line can report it.
    session_deinit: ?anyerror = null,
    /// The model's release, recorded rather than swallowed: a release that
    /// fails is a teardown failure, not a detail.
    panel_release: ?anyerror = null,
    session: ?*Session = null,
    done: bool = false,
    fn releaseTarget(self: *Cleanup) void {
        const destination = self.target orelse return;
        self.target = null;
        destination.deinit();
    }

    /// Idempotent: the success path calls it directly, the single errdefer
    /// calls it on any failure, and `done` makes the second call a no-op.
    fn run(self: *Cleanup) void {
        if (self.done) return;
        self.done = true;
        if (self.task_service) |service| service.setObserver(null);
        // Surface destruction still needs SDL's live platform connection.
        // This also covers failure before the pre-close hook is installed.
        self.releaseTarget();
        // `deinit` is the force-close owner: it walks whatever windows are
        // still open and destroys each one itself, so the App, the view, the
        // inspector and the device it borrows are all whole while it runs.
        // `closeWindow` can be vetoed, and a veto here would be a teardown
        // failure this run must not swallow.
        if (self.application) |application| {
            application.deinit();
            self.gpa.destroy(application);
            self.application = null;
        }
        if (self.inspector) |active| {
            active.detachActionRegistry();
            active.deinit();
            self.inspector = null;
        }
        if (self.registry) |owned| {
            owned.deinit();
            self.registry = null;
        }
        // The App and the inspector both borrow the overlay frame, and the App
        // borrows the device, so both go before it.
        if (self.app) |mounted| {
            mounted.detachGpu();
            mounted.deinit();
            self.gpa.destroy(mounted);
            self.app = null;
        }
        if (self.view) |specimen| self.gpa.destroy(specimen);
        self.view = null;
        if (self.overlay_frame) |owned| owned.deinit();
        self.overlay_frame = null;
        if (self.timing) |instrument| instrument.deinit();
        self.timing = null;
        if (self.painter) |scene| scene.deinit();
        self.painter = null;
        if (self.gpu) |device| device.deinit();
        self.gpu = null;
        if (self.loader) |system| {
            system.close();
            self.loader = null;
        }
        if (self.panel) |model| {
            if (self.session) |owner| {
                if (owner.release(Panel, model)) |_| {} else |err| {
                    self.panel_release = err;
                }
            }
            self.panel = null;
        }
        if (self.session) |owner| {
            if (owner.deinit()) |_| {} else |err| {
                self.session_deinit = err;
            }
            // A session whose deinit failed still owns whatever it could not
            // release. Freeing it here would turn a reported leak into a
            // use-after-free; the owner is left standing so the allocator
            // reports exactly what is still live.
            if (self.session_deinit == null) self.gpa.destroy(owner);
            self.session = null;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var hold_ms: u64 = 0;
    // Headless is the default: no compositor, no native window surface, no
    // presentation. The windowed swapchain is opt-in through `--native`.
    var native = false;
    // Both instruments are opt-in and off by default: GPU timestamps ask
    // the device for its query pool, and `--ppm` writes a file.
    var gpu_timing = false;
    var ppm_path: ?[]const u8 = null;
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    _ = args_it.next();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--hold-ms")) {
            hold_ms = try std.fmt.parseInt(u64, args_it.next() orelse return error.MissingHoldMs, 10);
        } else if (std.mem.eql(u8, arg, "--native")) {
            native = true;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            native = false;
        } else if (std.mem.eql(u8, arg, "--gpu-timing")) {
            gpu_timing = true;
        } else if (std.mem.eql(u8, arg, "--ppm")) {
            ppm_path = args_it.next() orelse return error.MissingPpmPath;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }

    var report: Reporter = .{ .io = io };
    try report.emit("W24 inspector interaction smoke\n", .{});
    try report.emit("mode: {s} target={s} gpu_timing={} ppm={s}\n", .{
        if (native) "native" else "headless",
        if (native) "vulkan swapchain (presented)" else "offscreen image (nothing is presented)",
        gpu_timing,
        ppm_path orelse "<none>",
    });
    // The dump is the frame's own final image, and a presented swapchain
    // image is created without transfer-source usage, so it cannot be copied
    // back at all. Refusing is the honest answer: the offscreen final-sRGB
    // probe below stays the proof that the whole chain landed.
    if (ppm_path != null and native) {
        try report.emit("ppm: refused -- --native presents to a swapchain image the " ++
            "device cannot copy back; run headless to dump the same frame\n", .{});
        return error.PpmRequiresOffscreenTarget;
    }

    // One owner releases everything, on the failure path and the success path
    // alike, in the one order the borrows allow. Nothing below registers a
    // teardown handler of its own.
    var cleanup: Cleanup = .{ .gpa = gpa };
    errdefer cleanup.run();

    const session = blk: {
        const owned = try gpa.create(Session);
        errdefer gpa.destroy(owned);
        owned.* = try Session.init(gpa);
        break :blk owned;
    };
    cleanup.session = session;

    var initial: Panel = .{};
    var panel = try session.create(Panel, &initial);
    cleanup.panel = &panel;

    // The dummy driver creates no compositor surface.
    const application = blk: {
        const owned = try gpa.create(Application);
        errdefer gpa.destroy(owned);
        owned.* = try Application.init(gpa, session, .{
            .app_id = "dev.nogui.w24smoke",
            .restart = .never,
            .video_driver = if (native) null else "dummy",
        });
        break :blk owned;
    };
    cleanup.application = application;

    var system_loader = try frame.SystemVulkanLoader.open();
    cleanup.loader = &system_loader;
    // SDL only loads Vulkan when it will create a native surface. The dummy
    // video driver cannot load it, so headless GPU work uses the system loader.
    if (native) try sdl3.vulkan.loadLibrary(null);
    exts_storage = if (native) try sdl3.vulkan.getInstanceExtensions() else &.{};
    var loader = system_loader.options();
    loader.get_instance_extensions = &getExts;

    var gpu = try noapi.Gpu.init(.{
        .frames_in_flight = 2,
        .app_name = "w24-inspector-smoke",
        .validation = false,
        // Asked for at device creation, so the queue is selected and the
        // pool exists before the first frame; off is the default.
        .timestamp_queries = gpu_timing,
        .loader = loader,
        .io = io,
    });
    exts_storage = &.{};
    // Torn down by the one owner, after its surfaces and mounts and before
    // SDL and the system loader close.
    cleanup.gpu = &gpu;
    var endpoint: nogui.GpuEndpoint = .{ .gpu = &gpu };

    // Asked of the device once, here, so a refusal is known before the first
    // frame and no frame ever records a timing it cannot read back.
    var timing: GpuTiming = GpuTiming.init(&gpu, gpu_timing);
    cleanup.timing = &timing;
    try report.emit("gpu-timing: requested={} enabled={} period_ns={d} valid_bits={d} " ++
        "query_pairs={d} span_capacity={d} refusal={s}\n", .{
        timing.requested,
        timing.enabled(),
        if (timing.info) |info| info.period_ns else 0,
        if (timing.info) |info| info.valid_bits else 0,
        timing_slots,
        timing_span_capacity,
        timing.refusal orelse "<none>",
    });

    // The inspector's own view is drawn with the public renderer, so the
    // shader modules come from the same `shaders/` artifacts the demo uses.
    var quad_vert = try Spv.load(gpa, io, "shaders/quad_vert.spv");
    defer quad_vert.deinit(gpa);
    var quad_frag = try Spv.load(gpa, io, "shaders/quad_frag.spv");
    defer quad_frag.deinit(gpa);
    var sort_comp = try Spv.load(gpa, io, "shaders/sort_comp.spv");
    defer sort_comp.deinit(gpa);
    var fullscreen_vert = try Spv.load(gpa, io, "shaders/fullscreen_vert.spv");
    defer fullscreen_vert.deinit(gpa);
    var blit_oklab = try Spv.load(gpa, io, "shaders/blit_oklab.spv");
    defer blit_oklab.deinit(gpa);
    var painter = try Painter.init(
        gpa,
        &gpu,
        &quad_vert,
        &quad_frag,
        &sort_comp,
        &fullscreen_vert,
        &blit_oklab,
    );
    cleanup.painter = &painter;

    const app = blk: {
        const owned = try gpa.create(App);
        errdefer gpa.destroy(owned);
        owned.* = try App.init(gpa, session);
        break :blk owned;
    };
    cleanup.app = app;
    const view = try gpa.create(PanelView);
    cleanup.view = view;
    view.* = .{};
    try app.mountModelRoot(Panel, PanelView, panel, view);
    try app.attachGpu(&endpoint);

    const title: [:0]const u8 = "w24-inspector-smoke";
    // Headless opens a host window slot the App, the frame demand and the
    // inspector all need, but nothing is mapped to a desktop and no surface
    // is asked of SDL. `--native` asks for both.
    const handle = try application.openWindowWithApp(app, .{
        .title = title,
        .width = window_width,
        .height = window_height,
        .resizable = false,
        .visible = native,
        .gpu_surface = native,
    });
    const managed = try application.getWindow(handle);
    // The offscreen target is 1:1 with the logical window, so it never needs a
    // display scale. It is floored at one pixel because a zero-extent image is
    // not a texture; the first frame replaces this with the real extent.
    const window_extent: noapi.Extent2D = .{
        .width = @max(1, managed.observed.size.width),
        .height = @max(1, managed.observed.size.height),
    };
    var target: Target = if (native) blk: {
        // noapi creates the platform surface AND owns it from here, on the
        // success path and on the failure path alike. This file therefore
        // holds no SDL wrapper to destroy and never sees a Vulkan handle.
        const surface = try noapi.Surface.initSdl(
            &gpu,
            @ptrCast(managed.native.sdl.value),
            @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
            .{ .extent = try deviceExtent(managed) },
        );
        break :blk .{ .swapchain = surface };
    } else blk: {
        break :blk .{ .image = try Offscreen.init(&gpu, window_extent) };
    };
    // The smoke borrows this one target. Cleanup owns its release.
    cleanup.target = &target;

    try report.emit("window: title=\"{s}\" observed={d}x{d} pixels={d}x{d} video_driver={s} " ++
        "visible={} gpu_surface={} presents={}\n", .{
        title,
        managed.observed.size.width,
        managed.observed.size.height,
        managed.observed.pixels.width,
        managed.observed.pixels.height,
        sdl3.video.getCurrentDriverName() orelse "<null>",
        managed.observed.visible,
        native,
        target.presents(),
    });

    var inspector = try Inspector.initOwned(gpa, .{
        .frame_capacity = frame_capacity,
        .task_capacity = task_capacity,
        .action_capacity = action_capacity,
        .enable_collectors = true,
        .enable_picking = true,
    });
    cleanup.inspector = &inspector;
    try application.setInspector(handle, &inspector);
    try report.emit("inspector: pick_mode={} frame_cap={d} task_cap={d} " ++
        "action_cap={d} frame_enabled={} task_enabled={} action_enabled={}\n", .{
        inspector.isPickMode(),
        inspector.frame_collector.capacity(),
        inspector.task_collector.capacity(),
        inspector.action_collector.capacity(),
        inspector.frame_collector.enabled,
        inspector.task_collector.enabled,
        inspector.action_collector.enabled,
    });

    var registry = try nogui.action.Registry.init(gpa, session);
    cleanup.registry = &registry;
    try registry.register(Dispatch);
    _ = try registry.bind(Dispatch, Panel, Panel.onDispatch, null, .app, panel.weak());
    try inspector.attachActionRegistry(io, &registry);
    try report.emit("action registry: attached={} name=\"{s}\" scope=app\n", .{
        inspector.action_registry != null,
        Dispatch.name,
    });

    var bridge: TaskBridge = .{ .inspector = &inspector };

    var smoke: Smoke = .{
        .io = io,
        .application = application,
        .app = app,
        .handle = handle,
        .target = &target,
        .cleanup = &cleanup,
        .endpoint = &endpoint,
        .inspector = &inspector,
        .bridge = &bridge,
        .view = view,
        .painter = &painter,
        .timing = &timing,
        .overlay = overlay.Frame.init(gpa),
        .logical_size = .{
            .width = managed.observed.size.width,
            .height = managed.observed.size.height,
        },
    };
    cleanup.overlay_frame = &smoke.overlay;
    // The App owns placement: it resolves this frame against the tree it
    // publishes, after layout and before any custom paint. The inspector reads
    // the SAME frame, so every pick, every reported bound and every pixel come
    // from one resolved placement.
    app.setOverlayFrame(&smoke.overlay);
    inspector.setOverlayFrame(&smoke.overlay);
    try report.emit("overlay: registered_with_inspector={}\n", .{
        inspector.overlayFrame() != null,
    });
    application.setHooks(.{
        .context = &smoke,
        .on_frame = Smoke.onFrame,
        .on_before_close = Smoke.onBeforeClose,
        .on_quit_request = Smoke.onQuitRequest,
    });
    try application.start();
    const service = session.task_service orelse return error.TasksNotStarted;
    service.setObserver(bridge.observer());
    cleanup.task_service = service;

    // ── 1. real frames through the committed-frame path ──
    const first_frames = try pumpUntil(
        &smoke,
        sdl3.timer.getMillisecondsSinceInit() + 10_000,
        framesSettled,
    );
    const startup_snapshot_frame = if (inspector.latest_snapshot) |s| s.frame_number else 0;
    try report.emit("startup: committed={d} presented={d} settled={} host_running={} " ++
        "app.frame_generation={d} snapshot_frame={d} view_draws={d}\n", .{
        smoke.frames_committed,
        smoke.frames_presented,
        first_frames,
        smoke.host_running,
        app.frame_generation,
        startup_snapshot_frame,
        view.drawn,
    });

    // A second frame, driven explicitly: it is what gives the inspector a
    // previous snapshot to retain, and it proves the ring is demand-driven
    // rather than free-running.
    const second_frame = try driveFrames(&smoke, 1);
    try report.emit("startup: extra_frames_driven={d} committed={d} presented={d} " ++
        "app.frame_generation={d}\n", .{
        second_frame,
        smoke.frames_committed,
        smoke.frames_presented,
        app.frame_generation,
    });

    const snap1 = inspector.latestSnapshot() orelse return error.NoSnapshot;
    const previous_frame = if (inspector.previousSnapshot()) |p| p.frame_number else 0;
    try report.emit(
        "snapshot-1: frame={d} viewport={d}x{d} nodes={d} previous_frame={d} previous_present={}\n",
        .{
            snap1.frame_number,
            snap1.viewport.w,
            snap1.viewport.h,
            snap1.nodes.len,
            previous_frame,
            inspector.previousSnapshot() != null,
        },
    );

    // ── 2. pick the control on the LIVE tree ──
    const target1 = findNode(snap1, .button, "Inspect Target") orelse
        return error.TargetControlNotFound;
    const probe = probeOnControl(snap1, target1, null) orelse return error.NoControlPadding;
    const tree = app.tree_ptr orelse return error.NoCommittedTree;
    var target_text: [512]u8 = undefined;
    var child_text: [512]u8 = undefined;
    try report.emit("pick-1: probe=({d:.1},{d:.1}) tree_nodes={d}\n", .{
        probe[0],
        probe[1],
        tree.nodes.items.len,
    });
    try report.emit("pick-1 control: {s}\n", .{nodeText(target1, &target_text)});
    try report.emit("pick-1 children: {s}\n", .{childBoundsText(snap1, target1, &child_text)});

    const hit_frame = nogui.input.hitTest(tree, probe);
    const hit_stable = nogui.input.hitStable(tree, probe);
    var hit_stable_text: [96]u8 = undefined;
    var hit_frame_text: [96]u8 = undefined;
    try report.emit("pick-1 input hitTest: {s}\n", .{
        if (hit_frame) |f|
            std.fmt.bufPrint(&hit_frame_text, "frame_node={d}", .{@intFromEnum(f)}) catch "<overflow>"
        else
            "<none>",
    });
    try report.emit("pick-1 input hitStable: {s}\n", .{
        if (hit_stable) |id| widgetIdText(id, &hit_stable_text) else "<none>",
    });

    const pick1 = inspector.pickAt(probe);
    if (pick1.node == null) return error.PickMissed;
    const picked = inspector.pickHandleAt(probe) orelse return error.PickMissed;
    const resolved1 = try inspector.resolveHandle(picked);
    var resolved_text: [512]u8 = undefined;
    try report.emit("pick-1 resolved: {s}\n", .{nodeText(resolved1, &resolved_text)});
    try report.emit("pick-1 handle: owner=0x{x} slot={d} gen={d} frame={d}\n", .{
        picked.id.owner,
        picked.id.slot,
        picked.generation,
        picked.frame_number,
    });
    const pick_agrees_frame = hit_frame != null and
        @intFromEnum(hit_frame.?) == @intFromEnum(resolved1.frame_node_id);
    const pick_agrees_stable = hit_stable != null and hit_stable.?.eql(resolved1.id);
    try report.emit("pick-1 agreement: pick_node==input_hitTest={} pick_id==input_hitStable={}\n", .{
        pick_agrees_frame,
        pick_agrees_stable,
    });
    try report.emit("pick-1 routed: node={?d} tree_node={?d}\n", .{
        if (pick1.node) |n| @as(u32, @intFromEnum(n)) else null,
        if (pick1.tree_node) |n| @as(u32, @intFromEnum(n)) else null,
    });
    try report.emit("pick-1 selection: selected_handle_set={} resolveSelection_label=\"{s}\"\n", .{
        inspector.selected() != null,
        (inspector.resolveSelection() catch return error.SelectionUnresolvable)
            .semantics.label orelse "<none>",
    });
    try report.emit("pointer input: source=synthetic App.handle values; the compositor " ++
        "delivered no pointer event in this run\n", .{});

    // ── 2b. the inspector's own view, painted and read back ──
    // The frame now shows the picked node's reported bounds, a selection
    // frame around them, the resolved overlay placement and a probe marker,
    // drawn through the public renderer. The armed probes are recorded in the
    // frame that paints them, so the report can say the pixels landed where
    // the engine resolved them rather than only that something was submitted.
    smoke.probe = probe;
    smoke.selection = resolved1.*;
    _ = try driveFrames(&smoke, 1);
    const resnapshot = inspector.latestSnapshot() orelse return error.NoSnapshot;
    const node_id = pick1.node orelse return error.NoPickNode;
    // The bounds of the node the pick named are copied out, so the frame
    // paints where the inspector said even after its snapshot is retired.
    smoke.selection = (resnapshot.findByFrameNodeId(node_id) orelse
        return error.NoSelection).*;
    smoke.probes[probe_pick].armed = true;
    smoke.probes[probe_background].armed = true;
    const painted_frames = try driveFrames(&smoke, 1);
    smoke.probes[probe_pick].armed = false;
    smoke.probes[probe_background].armed = false;
    const painted_probe = smoke.probes[probe_pick];
    const painted_background = smoke.probes[probe_background];
    const probe_ok = painted_probe.matched();
    const background_ok = painted_background.matched();
    var painted_text: [512]u8 = undefined;
    var painted_vis: [96]u8 = undefined;
    try report.emit("paint: frames_driven={d} rects={d} target_visual=[{s}] probe=({d:.1},{d:.1})\n", .{
        painted_frames,
        painter.rects.items.len,
        rectText(smoke.selection.?.visual_bounds, &painted_vis),
        smoke.probe[0],
        smoke.probe[1],
    });
    try report.emit("paint: node={s}\n", .{nodeText(&smoke.selection.?, &painted_text)});
    try report.emit("paint readback (Oklab): probe_ok={} background_ok={} " ++
        "probe=[{d:.4} {d:.4} {d:.4} {d:.4}] background=[{d:.4} {d:.4} {d:.4} {d:.4}] " ++
        "expected_probe=[{d:.4} {d:.4} {d:.4} {d:.4}]\n", .{
        probe_ok,
        background_ok,
        painted_probe.observed[0],
        painted_probe.observed[1],
        painted_probe.observed[2],
        painted_probe.observed[3],
        painted_background.observed[0],
        painted_background.observed[1],
        painted_background.observed[2],
        painted_background.observed[3],
        painted_probe.expected[0],
        painted_probe.expected[1],
        painted_probe.expected[2],
        painted_probe.expected[3],
    });
    try report.emit("paint readback (final sRGB): source={s} probe={s} background={s} " ++
        "probe=[{d:.4} {d:.4} {d:.4} {d:.4}] expected_probe=[{d:.4} {d:.4} {d:.4} {d:.4}]\n", .{
        if (target.presents()) "swapchain (not copied back)" else "offscreen image",
        // The same verdict the overlay probes print, in the same words: a
        // presenting swapchain has no copied-back image to judge, so it says
        // so instead of claiming a match it never measured.
        finalReadText(target.presents(), painted_probe.finalMatched()),
        finalReadText(target.presents(), painted_background.finalMatched()),
        painted_probe.final[0],
        painted_probe.final[1],
        painted_probe.final[2],
        painted_probe.final[3],
        painted_probe.final_expected[0],
        painted_probe.final_expected[1],
        painted_probe.final_expected[2],
        painted_probe.final_expected[3],
    });
    if (!probe_ok) return error.ProbePixelMismatch;
    if (!background_ok) return error.BackgroundPixelMismatch;
    // The final sRGB image is the one a compositor would be shown. Only the
    // offscreen target can be copied back, so that check is the headless
    // gate's proof that the whole Oklab -> sRGB chain landed, not a windowed
    // one.
    if (!target.presents() and !painted_probe.finalMatched()) return error.FinalPixelMismatch;

    // ── 3. a synthetic pointer event at the same coordinates ──
    const before_focus = app.focus_manager.current;
    _ = try app.handle(.{ .mouse_move = .{ .x = probe[0], .y = probe[1] } });
    _ = try app.handle(.{ .mouse_down = .{
        .button = .left,
        .x = probe[0],
        .y = probe[1],
        .click_count = 1,
    } });
    const after_down = app.focus_manager.current;
    _ = try app.handle(.{ .mouse_up = .{
        .button = .left,
        .x = probe[0],
        .y = probe[1],
        .click_count = 1,
    } });
    const after_up = app.focus_manager.current;
    var focus_text: [96]u8 = undefined;
    try report.emit("pointer: focus_before={s} focus_after_mouse_down={s} focus_after_mouse_up={s}\n", .{
        if (before_focus) |id| widgetIdText(id, &focus_text) else "<none>",
        if (after_down) |id| widgetIdText(id, &focus_text) else "<none>",
        if (after_up) |id| widgetIdText(id, &focus_text) else "<none>",
    });
    var after_click: PanelFacts = .{};
    try session.read(Panel, panel, &after_click, readPanel);
    try report.emit("pointer: mouse_down_target==pick_handle_id={} target_handler_clicks={d} " ++
        "model_dispatched={d}\n", .{
        after_down != null and after_down.?.eql(picked.id),
        view.clicks,
        after_click.dispatched,
    });

    // The press must be visible in the NEXT committed frame's snapshot, which
    // is the only place the inspector learns about focus.
    const focus_frame = app.frame_generation;
    _ = try driveFrames(&smoke, 1);
    const snap2 = inspector.latestSnapshot() orelse return error.NoSnapshot;
    const focused_node = snap2.findNode(picked.id);
    var focused_text: [512]u8 = undefined;
    try report.emit("pointer: next_frame={d} focused_node_present={} focused={s}\n", .{
        snap2.frame_number,
        focused_node != null,
        if (focused_node) |n| nodeText(n, &focused_text) else "<none>",
    });
    try report.emit("pointer: focus_frame_before={d} focus_frame_after={d}\n", .{
        focus_frame,
        app.frame_generation,
    });

    // ── 4. the model label changes; the same handle must report it ──
    try session.update(Panel, panel, {}, struct {
        fn apply(value: *Panel, _: void) !void {
            value.target = "Inspect Target B";
            value.variant = 1;
        }
    }.apply);
    const redraw_pending = try session.takeRedraw(app.window);
    const label_frame = try driveFrames(&smoke, 1);
    const snap3 = inspector.latestSnapshot() orelse return error.NoSnapshot;
    const handle2 = inspector.pickHandleAt(probe) orelse return error.PickMissed;
    const resolved2 = try inspector.resolveHandle(handle2);
    var resolved2_text: [512]u8 = undefined;
    var resolved1_text: [512]u8 = undefined;
    try report.emit("label-change: session_redraw_pending={} frames_driven={d} frame={d}\n", .{
        redraw_pending,
        label_frame,
        snap3.frame_number,
    });
    try report.emit("label-change before: {s}\n", .{nodeText(resolved1, &resolved1_text)});
    try report.emit("label-change after: {s}\n", .{nodeText(resolved2, &resolved2_text)});
    const old_still_resolves = if (inspector.resolveHandle(picked)) |_| true else |_| false;
    try report.emit("label-change: label_before=\"{s}\" label_after=\"{s}\" changed={} " ++
        "identity_preserved={} old_handle_still_resolves={}\n", .{
        resolved1.semantics.label orelse "<none>",
        resolved2.semantics.label orelse "<none>",
        !std.mem.eql(
            u8,
            resolved1.semantics.label orelse "",
            resolved2.semantics.label orelse "\x00none",
        ),
        picked.id.eql(handle2.id) and picked.generation == handle2.generation,
        old_still_resolves,
    });

    // ── 5. the spare node is replaced; the old handle must fail ──
    const spare1 = findNode(snap3, .button, "Spare") orelse return error.SpareControlNotFound;
    // The spare control sits UNDER the overlay's resolved placement, so the
    // probe has to be a point the placement does not cover. Derived from the
    // two resolved boxes; a point under the placement would measure the
    // overlay's own routing instead of this control.
    const spare_probe = probeOnControl(snap3, spare1, if (smoke.placement) |p| p.rect else null) orelse
        return error.NoUncoveredSparePoint;
    const spare_handle = inspector.pickHandleAt(spare_probe) orelse return error.PickMissed;
    // The handle under test must BE this control before it is replaced. A
    // probe that landed on the overlay would make every stale answer below
    // about some other node entirely.
    if (!spare_handle.id.eql(spare1.id)) return error.StaleProbeNotOnSpare;
    if (inspector.pickAt(spare_probe).node == null) return error.StaleProbePickMissing;
    if (inspector.pickAt(spare_probe).node.? != spare1.frame_node_id) {
        return error.StaleProbePickWrongNode;
    }
    var spare_text: [512]u8 = undefined;
    try report.emit("stale before: probe=({d:.1},{d:.1}) handle=slot={d}/gen={d} node={s}\n", .{
        spare_probe[0],
        spare_probe[1],
        spare_handle.id.slot,
        spare_handle.generation,
        nodeText(spare1, &spare_text),
    });
    const spare_slot = spare_handle.id.slot;
    const spare_gen = spare_handle.generation;

    try session.update(Panel, panel, {}, struct {
        fn apply(value: *Panel, _: void) !void {
            value.spare = "Spare Two";
        }
    }.apply);
    _ = try driveFrames(&smoke, 1);
    const snap4 = inspector.latestSnapshot() orelse return error.NoSnapshot;
    const spare2 = findNode(snap4, .button, "Spare") orelse return error.SpareControlNotFound;
    try report.emit("stale-removed: frame={d} node={s} same_slot={} generation_bumped={}\n", .{
        snap4.frame_number,
        nodeText(spare2, &spare_text),
        spare2.id.slot == spare_slot,
        spare2.id.generation > spare_gen,
    });
    const removed_result = inspector.resolveHandle(spare_handle);
    if (removed_result) |node| {
        try report.emit("stale-removed: resolveHandle(old)={s} node={s}\n", .{
            resolveOutcome(removed_result),
            nodeText(node, &spare_text),
        });
    } else |_| {
        try report.emit("stale-removed: resolveHandle(old)={s} active_selection_was={s}\n", .{
            resolveOutcome(removed_result),
            resolveOutcome(inspector.resolveSelection()),
        });
    }

    // Removal must RETIRE the handle, not merely stop naming the old label,
    // and the replacement must be a different identity in the same tree.
    if (spare2.id.slot == spare_slot and spare2.id.generation == spare_gen) {
        return error.SpareIdentityUnchangedAfterRemoval;
    }
    if (inspector.resolveHandle(spare_handle)) |survivor| {
        var survivor_text: [512]u8 = undefined;
        try report.emit("stale-removed: old handle SURVIVED removal: {s}\n", .{
            nodeText(survivor, &survivor_text),
        });
        return error.StaleHandleSurvivedRemoval;
    } else |err| {
        if (err != error.StaleHandle) return err;
    }

    // The removed slot is only recycled by the NEXT frame, so a second
    // replacement is what puts a DIFFERENT node into the same slot. That is
    // the case a generation check has to catch: the handle finds a live node
    // with its own owner/slot and must still refuse it.
    try session.update(Panel, panel, {}, struct {
        fn apply(value: *Panel, _: void) !void {
            value.spare = "Spare Three";
        }
    }.apply);
    _ = try driveFrames(&smoke, 1);
    const snap5 = inspector.latestSnapshot() orelse return error.NoSnapshot;
    const spare3 = findNode(snap5, .button, "Spare") orelse return error.SpareControlNotFound;
    try report.emit("stale-replaced: frame={d} node={s} slot_reused={} generation_bumped={}\n", .{
        snap5.frame_number,
        nodeText(spare3, &spare_text),
        spare3.id.slot == spare_slot,
        spare3.id.generation > spare_gen,
    });
    const replaced_result = inspector.resolveHandle(spare_handle);
    if (replaced_result) |node| {
        try report.emit("stale-replaced: resolveHandle(old)={s} node={s}\n", .{
            resolveOutcome(replaced_result),
            nodeText(node, &spare_text),
        });
    } else |_| {
        try report.emit("stale-replaced: resolveHandle(old)={s} active_selection_was={s}\n", .{
            resolveOutcome(replaced_result),
            resolveOutcome(inspector.resolveSelection()),
        });
    }

    // The replacement must be a different identity: either a different slot
    // or a higher generation in the same one. Whether the engine recycles the
    // slot is measured and reported above, not assumed here — what must hold
    // either way is that the old handle refuses the node now in the tree.
    if (spare3.id.slot == spare_slot and spare3.id.generation <= spare_gen) {
        return error.SpareIdentityUnchangedAfterReuse;
    }
    if (inspector.resolveHandle(spare_handle)) |survivor| {
        var survivor_text: [512]u8 = undefined;
        try report.emit("stale-replaced: old handle SURVIVED slot reuse: {s}\n", .{
            nodeText(survivor, &survivor_text),
        });
        return error.StaleHandleSurvivedReuse;
    } else |err| {
        if (err != error.StaleHandle) return err;
    }
    inspector.select(spare_handle);
    try report.emit("stale: resolveSelection(old handle selected)={s} " ++
        "selected_handle_is_old={}\n", .{
        resolveOutcome(inspector.resolveSelection()),
        inspector.selected() != null and inspector.selected().?.eql(spare_handle),
    });

    // The selection path resolves through the same check, so a selected stale
    // handle must fail there too rather than resolve to the live node.
    if (inspector.resolveSelection()) |survivor| {
        var survivor_text: [512]u8 = undefined;
        try report.emit("stale: selection SURVIVED a stale handle: {s}\n", .{
            nodeText(survivor, &survivor_text),
        });
        return error.SelectionSurvivedStaleHandle;
    } else |err| {
        if (err != error.StaleHandle) return err;
    }

    // ── 6. the overlay on the mounted specimen ──
    // The placement is resolved at the end of a frame and painted by the next
    // one, so this drives a frame before it reads anything back.
    _ = try driveFrames(&smoke, 1);
    const placement = smoke.placement orelse return error.OverlayNotResolved;
    const sheet_frame_node = smoke.view.sheet_node orelse return error.OverlayContentMissing;
    // The tree the walk and the placement report below read. The frame that
    // PAINTS the two probes publishes another one, and the overlay bank is
    // selected by tree, so every routing query after that drive re-reads it.
    const walk_tree = app.tree_ptr orelse return error.NoCommittedTree;
    const flow = nogui.visualBorderRect(walk_tree, sheet_frame_node);
    var placement_text: [96]u8 = undefined;
    var flow_text: [96]u8 = undefined;
    var anchor_text: [96]u8 = undefined;
    var content_text: [96]u8 = undefined;
    try report.emit("overlay: resolved={d} frame={d} sheet_draws={d} " ++
        "anchor={s} content={s} order={d} placement=[{s}] moved_by=([{d:.1},{d:.1}]) flow=[{s}]\n", .{
        smoke.overlays_resolved,
        inspector.latestSnapshot().?.frame_number,
        view.sheet_draws,
        widgetIdText(smoke.anchor_id orelse return error.NoOverlayAnchor, &anchor_text),
        widgetIdText(smoke.sheet_id orelse return error.NoOverlayContent, &content_text),
        placement.order,
        rectText(placement.rect, &placement_text),
        placement.rect.x - flow.x,
        placement.rect.y - flow.y,
        rectText(flow, &flow_text),
    });
    // Exactly one placement, counted from the frame's OWN registrations for
    // THIS tree through its public query. A tree the frame never placed and a
    // tree holding two registrations are the same failure here: the run
    // claims one sheet and painted one.
    const placed = smoke.overlay.records(walk_tree) orelse return error.UnexpectedPlacementCount;
    if (placed.len != 1) return error.UnexpectedPlacementCount;

    // Both probe points are chosen out of the RESOLVED placement rather than
    // hard-coded: one where the placement is painted over a control input
    // still routes to, and one where the overlay's own laid-out box is under
    // the pointer as well.
    const cover_walk: PlacementWalk = .{
        .tree = walk_tree,
        .frame = &smoke.overlay,
        .rect = placement.rect,
        .flow = flow,
        .cover = true,
    };
    const cover = cover_walk.first() orelse return error.NoCoveredProbePoint;
    const agree_walk: PlacementWalk = .{
        .tree = walk_tree,
        .frame = &smoke.overlay,
        .rect = placement.rect,
        .flow = flow,
        .cover = false,
    };
    const agree = agree_walk.first() orelse return error.NoOverlayFlowProbePoint;

    // The frame that paints the placement is also the frame that copies the
    // two probe points back out of it.
    smoke.probes[probe_sheet].point = cover.point;
    smoke.probes[probe_agree].point = agree.point;
    smoke.probes[probe_sheet].armed = true;
    smoke.probes[probe_agree].armed = true;
    const overlay_frames = try driveFrames(&smoke, 1);
    // The frame that painted the probes is the frame the pixels and every
    // routing query below belong to, so the tree is read again here. Its
    // layout is the same one the walk measured: nothing changed in between,
    // and the containment checks re-prove that rather than assume it.
    const tree_now = app.tree_ptr orelse return error.NoCommittedTree;
    const painted = smoke.placement orelse return error.OverlayNotResolved;
    try report.emit("overlay paint: walk_tree_placement=[{s}] painted_placement=[{s}] " ++
        "same_rect={}\n", .{
        rectText(placement.rect, &placement_text),
        rectText(painted.rect, &flow_text),
        rectSame(placement.rect, painted.rect),
    });
    if (!rectSame(placement.rect, painted.rect)) return error.OverlayPlacementMovedUnderProbe;
    smoke.probes[probe_sheet].armed = false;
    smoke.probes[probe_agree].armed = false;
    const sheet_cover = smoke.probes[probe_sheet];
    const sheet_agree = smoke.probes[probe_agree];
    try report.emit("overlay paint: frames_driven={d} rects={d}\n", .{
        overlay_frames,
        painter.rects.items.len,
    });
    if (!inside(painted.rect, cover.point)) return error.CoverPointOutsidePlacement;
    if (!inside(painted.rect, agree.point)) return error.AgreePointOutsidePlacement;
    if (!inside(flow, agree.point)) return error.AgreePointOutsideOverlayFlow;

    // What the inspector reports at each probe, next to what the engine's own
    // hit tests and pointer routing resolve at the same point.
    const cover_pick = inspector.pickAt(cover.point);
    const cover_handle = inspector.pickHandleAt(cover.point) orelse return error.PickMissed;
    const cover_resolved = try inspector.resolveHandle(cover_handle);
    const cover_input = nogui.input.hitTest(tree_now, cover.point);
    const cover_stable = nogui.input.hitStable(tree_now, cover.point);
    const cover_routed = routedStableTarget(tree_now, &smoke.overlay, cover.point);
    const cover_overlay = smoke.overlay.hitTest(tree_now, cover.point);
    const agree_pick = inspector.pickAt(agree.point);
    const agree_input = nogui.input.hitTest(tree_now, agree.point);
    const agree_stable = nogui.input.hitStable(tree_now, agree.point);
    const agree_routed = routedStableTarget(tree_now, &smoke.overlay, agree.point);
    const agree_overlay = smoke.overlay.hitTest(tree_now, agree.point);
    // The overlay content's own handle, taken from the snapshot rather than
    // from a pick: a pick at a probe can name one of its unkeyed children,
    // and the identity claims below are about the content root.
    const sheet_snapshot = inspector.latestSnapshot() orelse return error.NoSnapshot;
    const sheet_node = sheet_snapshot.findNode(smoke.sheet_id orelse
        return error.NoOverlayContent) orelse return error.NoOverlaySnapshotNode;
    const sheet_handle = sheet_node.handle;
    // Snapshotted before the press: the overlay's own control must absorb it
    // exactly once, and the control underneath must not move at all.
    const cover_overlay_clicks = view.overlay_clicks;
    const cover_spare_clicks = view.spare_clicks;
    const cover_focus_before = app.focus_manager.current;
    _ = try app.handle(.{ .mouse_move = .{ .x = cover.point[0], .y = cover.point[1] } });
    _ = try app.handle(.{ .mouse_down = .{
        .button = .left,
        .x = cover.point[0],
        .y = cover.point[1],
        .click_count = 1,
    } });
    const cover_focus = app.focus_manager.current;
    _ = try app.handle(.{ .mouse_up = .{
        .button = .left,
        .x = cover.point[0],
        .y = cover.point[1],
        .click_count = 1,
    } });
    _ = try app.handle(.{ .mouse_move = .{ .x = agree.point[0], .y = agree.point[1] } });
    _ = try app.handle(.{ .mouse_down = .{
        .button = .left,
        .x = agree.point[0],
        .y = agree.point[1],
        .click_count = 1,
    } });
    const agree_focus = app.focus_manager.current;
    _ = try app.handle(.{ .mouse_up = .{
        .button = .left,
        .x = agree.point[0],
        .y = agree.point[1],
        .click_count = 1,
    } });
    var cover_node_text: [512]u8 = undefined;
    // One buffer per printed handle: a shared one would be overwritten by the
    // last argument before the first is ever read.
    var cover_before_text: [96]u8 = undefined;
    var cover_after_text: [96]u8 = undefined;
    var cover_stable_text: [96]u8 = undefined;
    var agree_focus_text: [96]u8 = undefined;
    var agree_stable_text: [96]u8 = undefined;
    try report.emit("overlay cover: probe=({d:.1},{d:.1}) painted_sheet={} final_srgb_sheet={s} " ++
        "topmost_pick_node={?d} overlay_hit_node={?d} tree_hit_node={?d} " ++
        "pick_tree_node={?d} pick_agrees_overlay_hit={} " ++
        "pick_reports_tree_hit={}\n", .{
        cover.point[0],
        cover.point[1],
        sheet_cover.matched(),
        finalReadText(target.presents(), sheet_cover.finalMatched()),
        if (cover_pick.node) |n| @as(u32, @intFromEnum(n)) else null,
        if (cover_overlay) |n| @as(u32, @intFromEnum(n)) else null,
        if (cover_input) |n| @as(u32, @intFromEnum(n)) else null,
        if (cover_pick.tree_node) |n| @as(u32, @intFromEnum(n)) else null,
        cover_pick.node != null and cover_overlay != null and
            cover_pick.node.? == cover_overlay.?,
        cover_pick.tree_node != null and cover_input != null and
            cover_pick.tree_node.? == cover_input.?,
    });
    try report.emit("overlay cover: topmost={s}\n", .{nodeText(cover_resolved, &cover_node_text)});
    var cover_routed_text: [96]u8 = undefined;
    try report.emit("overlay cover routed input: focus_before={s} focus_after={s} " ++
        "tree_hitStable={s} routed_target={s} focus_agrees_routed={} " ++
        "focus_agrees_tree_walk={} is_overlay_node={}\n", .{
        if (cover_focus_before) |id| widgetIdText(id, &cover_before_text) else "<none>",
        if (cover_focus) |id| widgetIdText(id, &cover_after_text) else "<none>",
        if (cover_stable) |id| widgetIdText(id, &cover_stable_text) else "<none>",
        if (cover_routed) |id| widgetIdText(id, &cover_routed_text) else "<none>",
        cover_focus != null and cover_routed != null and cover_focus.?.eql(cover_routed.?),
        cover_focus != null and cover_stable != null and cover_focus.?.eql(cover_stable.?),
        cover_overlay != null and smoke.overlay.isOverlayNode(tree_now, cover_overlay.?),
    });
    var agree_routed_text: [96]u8 = undefined;
    try report.emit("overlay flow: probe=({d:.1},{d:.1}) painted_sheet={} final_srgb_sheet={s} " ++
        "topmost_pick_node={?d} overlay_hit_node={?d} tree_hit_node={?d} tree_node={?d} " ++
        "tree_lands_in_overlay={} tree_hitStable={s} tree_hitStable_is_sheet={} " ++
        "focus_after={s} routed_target={s} focus_agrees_routed={}\n", .{
        agree.point[0],
        agree.point[1],
        sheet_agree.matched(),
        finalReadText(target.presents(), sheet_agree.finalMatched()),
        if (agree_pick.node) |n| @as(u32, @intFromEnum(n)) else null,
        if (agree_overlay) |n| @as(u32, @intFromEnum(n)) else null,
        if (agree_input) |n| @as(u32, @intFromEnum(n)) else null,
        if (agree_pick.tree_node) |n| @as(u32, @intFromEnum(n)) else null,
        agree_input != null and smoke.overlay.isOverlayNode(tree_now, agree_input.?),
        if (agree_stable) |id| widgetIdText(id, &agree_stable_text) else "<none>",
        agree_stable != null and smoke.sheet_id != null and agree_stable.?.eql(smoke.sheet_id.?),
        if (agree_focus) |id| widgetIdText(id, &agree_focus_text) else "<none>",
        if (agree_routed) |id| widgetIdText(id, &agree_routed_text) else "<none>",
        agree_focus != null and agree_routed != null and agree_focus.?.eql(agree_routed.?),
    });
    if (!sheet_cover.matched()) return error.SheetPixelMismatch;
    if (!sheet_agree.matched()) return error.SheetFlowPixelMismatch;
    if (!target.presents() and !sheet_cover.finalMatched()) return error.SheetFinalPixelMismatch;
    if (!target.presents() and !sheet_agree.finalMatched()) return error.SheetFlowFinalPixelMismatch;
    // The placement is the topmost PAINTED thing at the covered point, and
    // both the core's overlay hit test and the inspector's snapshot name the
    // same node there.
    if (cover_pick.node == null or cover_overlay == null) return error.CoverPickMissing;
    if (cover_pick.node.? != cover_overlay.?) return error.CoverOverlayDisagreement;
    if (!cover_resolved.is_overlay) return error.CoverPickNotOverlay;
    if (!inside(cover_resolved.visual_bounds, cover.point)) return error.CoverBoundsDisagree;
    if (cover_pick.tree_node == null or cover_input == null) return error.CoverTreeHitMissing;
    if (cover_pick.tree_node.? != cover_input.?) return error.CoverTreeHitDisagreement;
    if (cover_resolved.overlay_order == null) return error.CoverMissingOverlayOrder;
    // The consumer-visible claim: a press on the painted overlay reaches the
    // OVERLAY's own control, once, and leaves the control it is drawn over
    // untouched. Everything above only says where the placement is.
    const cover_actionable = smoke.overlay.hitActionableTotal(tree_now, cover.point) orelse
        return error.CoverNoOverlayAction;
    if (!smoke.overlay.isOverlayNode(tree_now, cover_actionable)) {
        return error.CoverActionOutsideOverlay;
    }
    if (smoke.overlay.hitTestTotal(tree_now, cover.point) != cover_overlay) {
        return error.RouteTargetDisagreement;
    }
    if (view.overlay_clicks != cover_overlay_clicks + 1) return error.OverlayActionNotRouted;
    if (view.spare_clicks != cover_spare_clicks) return error.UnderlyingControlActivated;
    // At the flow point input lands inside the overlay's own subtree and
    // resolves to the content's stable handle.
    if (agree_input == null or agree_overlay == null) return error.AgreePickMissing;
    if (!smoke.overlay.isOverlayNode(tree_now, agree_input.?)) return error.AgreeInputOutsideOverlay;
    if (agree_stable == null or smoke.sheet_id == null) return error.AgreeNoStableHandle;
    if (!agree_stable.?.eql(smoke.sheet_id.?)) return error.AgreeStableHandleMismatch;
    // The routed press is the ground truth for input: at the overlay's own
    // control it must land there, and only there.
    // Focus is the router's own report: it must name the overlay's control,
    // not the laid-out box the pointer happens to sit on.
    const cover_routed_stable = smoke.overlay.hitStableTotal(tree_now, cover.point) orelse
        return error.CoverNoRoutedTarget;
    if (cover_focus == null or !cover_focus.?.eql(cover_routed_stable)) {
        return error.CoverRoutedTargetMismatch;
    }

    // The walk chose its point with the same overlay hit test the pick uses,
    // so the two must name the same node; a difference would mean the probe
    // was picked against a different frame than it was read from.
    const walk_agrees = cover_pick.node.? == cover.node and
        agree_pick.node == @as(?FrameNodeId, agree.node);
    if (!walk_agrees) return error.WalkPickDisagreement;

    // ── 6b. the overlay's identity across a label change ──
    // The label is a node INSIDE the overlay's content, so the content's own
    // handle must survive the change while the frame reports the new text.
    try session.update(Panel, panel, {}, struct {
        fn apply(value: *Panel, _: void) !void {
            value.sheet_label = "Overlay Sheet B";
        }
    }.apply);
    const overlay_redraw = try session.takeRedraw(app.window);
    _ = try driveFrames(&smoke, 1);
    const after_label = inspector.latestSnapshot() orelse return error.NoSnapshot;
    const relabeled = after_label.findNode(sheet_handle.id) orelse
        return error.SheetIdentityLost;
    const new_label_node = findNode(after_label, .label, "Overlay Sheet B") orelse
        return error.SheetLabelNotReported;
    try report.emit("overlay label-change: redraw_pending={} frame={d} " ++
        "handle_identity_preserved={} is_overlay={} order_preserved={} " ++
        "new_label_in_overlay={}\n", .{
        overlay_redraw,
        after_label.frame_number,
        relabeled.handle.generation == sheet_handle.generation and
            relabeled.id.slot == sheet_handle.id.slot,
        relabeled.is_overlay,
        relabeled.overlay_order != null and cover_resolved.overlay_order.? ==
            relabeled.overlay_order.?,
        new_label_node.is_overlay,
    });
    var relabeled_text: [512]u8 = undefined;
    var new_label_text: [512]u8 = undefined;
    try report.emit("overlay label-change: content={s}\n", .{
        nodeText(relabeled, &relabeled_text),
    });
    try report.emit("overlay label-change: new_label_node={s}\n", .{
        nodeText(new_label_node, &new_label_text),
    });
    if (!relabeled.is_overlay) return error.SheetIdentityNotOverlay;
    if (!new_label_node.is_overlay) return error.SheetLabelOutsideOverlay;
    // The relabelled frame still resolved exactly ONE placement, asked for
    // through the frame's own public queries against the tree it committed:
    // one registered record, naming the content root, and that content's
    // placement is the box the run reads back.
    const label_tree = app.tree_ptr orelse return error.NoCommittedTree;
    const label_records = smoke.overlay.records(label_tree) orelse
        return error.OverlayRecordsLost;
    if (label_records.len != 1) return error.OverlayPlacementLost;
    const label_content = smoke.sheet_id orelse return error.NoOverlayContent;
    if (!label_records[0].content.eql(label_content)) return error.OverlayContentChanged;
    if (smoke.overlay.placement(label_tree, label_content) == null) {
        return error.OverlayPlacementLost;
    }
    // The placement is a different box every frame only if the content moved;
    // a relabel must not move it, so the probe point is still inside.
    if (!inside(smoke.placement.?.rect, cover.point)) return error.SheetPlacementMoved;

    // ── 6c. removal retires the overlay's identity and its pixels ──
    // The frame that stops building the content still PAINTS the placement it
    // inherited; the frame after it is the first with nothing there, so the
    // probe is armed only once that frame is the one about to be drawn.
    try session.update(Panel, panel, {}, struct {
        fn apply(value: *Panel, _: void) !void {
            value.sheet_open = false;
        }
    }.apply);
    _ = try session.takeRedraw(app.window);
    const removal_frames = try driveFrames(&smoke, 1);
    if (smoke.placement != null) return error.OverlayStillResolved;
    // The removal frame registered nothing, so the committed tree has no
    // record and no placement left: the content is not an overlay subtree
    // any more, through the same public queries.
    const removal_tree = app.tree_ptr orelse return error.NoCommittedTree;
    const removal_records = smoke.overlay.records(removal_tree) orelse
        return error.OverlayRecordsLost;
    if (removal_records.len != 0) return error.OverlayPlacementRetained;
    if (smoke.overlay.placement(removal_tree, sheet_handle.id) != null) {
        return error.OverlayPlacementRetained;
    }
    if (view.sheet_node != null) return error.OverlayStillBuilt;
    // `buildScene` derives the sheet probe's expectation from the frame it is
    // painting, so arming it here expects the background the placement-less
    // scene actually draws there.
    smoke.probes[probe_sheet].armed = true;
    const removal_paint_frames = try driveFrames(&smoke, 1);
    smoke.probes[probe_sheet].armed = false;
    const cleared = smoke.probes[probe_sheet];
    const after_removal = inspector.latestSnapshot() orelse return error.NoSnapshot;
    const removal_pick = inspector.pickAt(cover.point);
    const removal_result = inspector.resolveHandle(sheet_handle);
    const removal_result_2 = inspector.resolveHandle(cover_handle);
    var removal_text: [512]u8 = undefined;
    if (removal_result) |node| {
        try report.emit("overlay removed: resolveHandle(content)={s} node={s}\n", .{
            resolveOutcome(removal_result),
            nodeText(node, &removal_text),
        });
    } else |_| {
        try report.emit("overlay removed: resolveHandle(content)={s}\n", .{
            resolveOutcome(removal_result),
        });
    }
    try report.emit("overlay removed: frames_driven={d} paint_frames={d} frame={d} " ++
        "sheet_draws={d} placements={d} topmost_node={?d} tree_node={?d} " ++
        "resolveHandle(cover_pick)={s} " ++
        "pixel_cleared={} final_srgb_cleared={s}\n", .{
        removal_frames,
        removal_paint_frames,
        after_removal.frame_number,
        view.sheet_draws,
        removal_records.len,
        if (removal_pick.node) |n| @as(u32, @intFromEnum(n)) else null,
        if (removal_pick.tree_node) |n| @as(u32, @intFromEnum(n)) else null,
        resolveOutcome(removal_result_2),
        cleared.matched(),
        finalReadText(target.presents(), cleared.finalMatched()),
    });
    // Removal has to retire the identity, not merely stop painting it. Both
    // the content's own handle and the handle a pick returned must refuse to
    // resolve against the frame that no longer has the overlay.
    if (removal_result) |survivor| {
        var survivor_text: [512]u8 = undefined;
        try report.emit("overlay removed: content handle SURVIVED: {s}\n", .{
            nodeText(survivor, &survivor_text),
        });
        return error.OverlayIdentitySurvivedRemoval;
    } else |err| {
        if (err != error.StaleHandle) return err;
    }
    if (removal_result_2) |_| {
        return error.OverlayPickIdentitySurvivedRemoval;
    } else |err| {
        if (err != error.StaleHandle) return err;
    }
    // With no placement left, the pick reaches the remaining tree.
    if (removal_pick.node == null) return error.RemovalPickMissing;
    if (!cleared.matched()) return error.OverlayPixelNotCleared;
    if (!target.presents() and !cleared.finalMatched()) return error.OverlayFinalNotCleared;

    // ── 7. the inspection round trip ──
    // Styles, clipping, focus, capture and the semantic relationships are
    // mounted content of the SAME specimen, opened only now so the flow every
    // earlier probe read is unchanged by their presence. Every value below
    // was authored by this run's own view; every transition was performed by
    // this run's own events. Nothing here re-asserts a default.
    try session.update(Panel, panel, {}, struct {
        fn apply(value: *Panel, _: void) !void {
            value.audit_open = true;
        }
    }.apply);
    const audit_redraw = try session.takeRedraw(app.window);
    const audit_frames = try driveFrames(&smoke, 1);
    const audit_snap = inspector.latestSnapshot() orelse return error.NoSnapshot;
    const audit_tree = app.tree_ptr orelse return error.NoCommittedTree;

    const clip_container_id = widgetIdAt(audit_tree, smoke.view.clip_node orelse
        return error.ClipContainerMissing) orelse return error.ClipContainerUnkeyed;
    const clip_child_id = widgetIdAt(audit_tree, smoke.view.clip_child orelse
        return error.ClipChildMissing) orelse return error.ClipChildUnkeyed;
    const styled_id = widgetIdAt(audit_tree, smoke.view.styled_node orelse
        return error.StyledNodeMissing) orelse return error.StyledNodeUnkeyed;
    const font_label_id = smoke.view.audit_label_node orelse return error.AuditLabelMissing;
    const container = audit_snap.findNode(clip_container_id) orelse return error.NoClipContainer;
    const child = audit_snap.findNode(clip_child_id) orelse return error.NoClipChild;
    const styled = audit_snap.findNode(styled_id) orelse return error.NoStyledNode;
    const font_label = audit_snap.findByFrameNodeId(font_label_id) orelse return error.NoAuditLabel;

    // ── 7a. resolved clipping, as behaviour rather than as a flag ──
    const clip = child.clip_bounds orelse return error.ClipChildUnclipped;
    if (!container.style.clips_content) return error.ContainerDoesNotClip;
    if (!container.clip_axes.x or !container.clip_axes.y) return error.ContainerClipAxesMissing;
    // The container is the only authored clipper on this child's chain, so
    // the clip the snapshot reports must BE that container's painted box.
    if (!rectSame(clip, container.visual_bounds)) return error.ClipNotTheContainerBox;
    // And the child must really overflow it, or nothing above proves
    // anything about clipping.
    if (child.visual_bounds.w <= clip.w) return error.ChildDoesNotOverflow;
    const overlap = rectOverlap(child.visual_bounds, clip) orelse return error.ClipHasNoOverlap;
    const inside_point = [2]f32{ overlap.x + overlap.w / 2, overlap.y + overlap.h / 2 };
    const clip_right = clip.x + clip.w;
    const child_right = child.visual_bounds.x + child.visual_bounds.w;
    const outside_point = [2]f32{
        clip_right + (child_right - clip_right) / 2,
        child.visual_bounds.y + child.visual_bounds.h / 2,
    };
    if (!inside(child.visual_bounds, inside_point)) return error.InsidePointOutsideChild;
    if (!inside(clip, inside_point)) return error.InsidePointOutsideClip;
    if (!inside(child.visual_bounds, outside_point)) return error.OutsidePointOutsideChild;
    if (inside(clip, outside_point)) return error.OutsidePointInsideClip;

    // A press point on the child's own padding, inside the clip. Taken here
    // because the snapshot it comes from is retired by the next frame.
    const clip_probe = probeOnControl(audit_snap, child, null) orelse return error.NoClipPadding;
    if (!inside(clip, clip_probe)) return error.ClipProbeOutsideClip;
    const inside_pick = inspector.pickAt(inside_point);
    const inside_hit = nogui.input.hitTest(audit_tree, inside_point);
    const inside_stable = nogui.input.hitStable(audit_tree, inside_point);
    const outside_pick = inspector.pickAt(outside_point);
    const outside_hit = nogui.input.hitTest(audit_tree, outside_point);
    var node_buf: [512]u8 = undefined;
    var clip_buf: [96]u8 = undefined;
    var clip_overlap_buf: [96]u8 = undefined;
    try report.emit("round-trip clip: container={s} child_visual=[{s}] clip=[{s}] " ++
        "axes=({} {}) overflow={} child_shrink={d:.0}\n", .{
        nodeText(container, &node_buf),
        rectText(child.visual_bounds, &clip_buf),
        rectText(clip, &clip_overlap_buf),
        container.clip_axes.x,
        container.clip_axes.y,
        child.visual_bounds.w > clip.w,
        child.style.shrink,
    });
    try report.emit("round-trip clip: inside=({d:.1},{d:.1}) pick_node={?d} " ++
        "hit_node={?d} pick_agrees={} stable_is_child={}\n", .{
        inside_point[0],
        inside_point[1],
        if (inside_pick.node) |n| @as(u32, @intFromEnum(n)) else null,
        if (inside_hit) |n| @as(u32, @intFromEnum(n)) else null,
        inside_pick.node != null and inside_hit != null and inside_pick.node.? == inside_hit.?,
        inside_stable != null and inside_stable.?.eql(clip_child_id),
    });
    try report.emit("round-trip clip: outside=({d:.1},{d:.1}) inside_child_box={} " ++
        "pick_node={?d} hit_node={?d} pick_names_child={} hit_names_child={}\n", .{
        outside_point[0],
        outside_point[1],
        inside(child.visual_bounds, outside_point),
        if (outside_pick.node) |n| @as(u32, @intFromEnum(n)) else null,
        if (outside_hit) |n| @as(u32, @intFromEnum(n)) else null,
        outside_pick.node == @as(?FrameNodeId, child.frame_node_id),
        outside_hit == @as(?FrameNodeId, child.frame_node_id),
    });
    // Inside the intersection both the inspector and the engine name the
    // clipped child, and the pointer's stable target is its own handle.
    if (inside_pick.node == null or inside_hit == null) return error.InsideClipPickMissing;
    if (inside_pick.node.? != inside_hit.?) return error.InsideClipPickDisagreement;
    if (inside_stable == null or !inside_stable.?.eql(clip_child_id)) {
        return error.InsideClipWrongStableTarget;
    }
    // Outside the clip, with the point still inside the child's own box, the
    // inspector's pick and the engine's routing must both refuse the child.
    // The clip is what makes them refuse it: the box test alone would pass.
    if (outside_pick.node == @as(?FrameNodeId, child.frame_node_id)) {
        return error.ClipDidNotConstrainPick;
    }
    if (outside_hit == @as(?FrameNodeId, child.frame_node_id)) {
        return error.ClipDidNotConstrainRouting;
    }

    // ── 7b. the authored style, resolved ──
    var style_buf: [640]u8 = undefined;
    try report.emit("round-trip style: {s}\n", .{styleText(styled, &style_buf)});
    if (styled.semantics.role != .button) return error.StyledRoleWrong;
    if (!std.mem.eql(u8, styled.semantics.label orelse "", audit_label_a)) {
        return error.StyledLabelWrong;
    }
    if (!std.mem.eql(u8, styled.semantics.accessible_label orelse "", audit_accessible_label)) {
        return error.StyledAccessibleWrong;
    }
    if (!colorSame(styled.style.fill, audit_fill_a)) return error.StyledFillWrong;
    if (styled.style.radius.top != audit_radius.top or
        styled.style.radius.right != audit_radius.right or
        styled.style.radius.bottom != audit_radius.bottom or
        styled.style.radius.left != audit_radius.left)
    {
        return error.StyledRadiusWrong;
    }
    if (styled.style.opacity != audit_opacity) return error.StyledOpacityWrong;
    if (styled.style.layer != audit_layer) return error.StyledLayerWrong;
    if (styled.style.gap != audit_gap) return error.StyledGapWrong;
    if (styled.style.grow != audit_grow) return error.StyledGrowWrong;
    if (styled.style.shrink != 0) return error.StyledShrinkWrong;
    if (styled.style.box_sizing != .border_box) return error.StyledBoxSizingWrong;
    if (styled.style.overflow.width != .hidden or styled.style.overflow.height != .hidden) {
        return error.StyledOverflowWrong;
    }
    if (!styled.style.clips_content) return error.StyledDoesNotClip;
    if (!styled.style.has_shadow) return error.StyledShadowMissing;
    if (!styled.is_visible) return error.StyledNotVisible;
    if (!styled.is_enabled) return error.StyledNotEnabled;
    // The font size is authored on a plain label, so nothing about it comes
    // from a control's own defaults.
    if (font_label.style.text_size != audit_font_size) return error.AuditFontSizeWrong;

    // ── 7c. the relationships the hierarchy carries ──
    const styled_parent_index = styled.parent_index orelse return error.StyledParentMissing;
    const styled_parent = audit_snap.nodes[styled_parent_index];
    // The snapshot's parent link has to agree with the LIVE tree's own: two
    // independent hierarchies describing one mounted specimen.
    const styled_frame_node = audit_tree.nodeConst(styled.frame_node_id) orelse
        return error.StyledFrameNodeMissing;
    if (styled_frame_node.parent != styled_parent.frame_node_id) {
        return error.ParentDisagreesWithTree;
    }
    if (!childContains(audit_snap, &styled_parent, styled)) return error.ParentDoesNotListStyled;
    const child_parent_index = child.parent_index orelse return error.ChildParentMissing;
    if (audit_snap.nodes[child_parent_index].index != container.index) {
        return error.ChildParentNotContainer;
    }
    const child_frame_node = audit_tree.nodeConst(child.frame_node_id) orelse
        return error.ChildFrameNodeMissing;
    if (child_frame_node.parent != container.frame_node_id) {
        return error.ChildParentDisagreesWithTree;
    }
    // The control's own label is a child, and this control clips it: a second
    // clip relationship, on a different pair of nodes than the one above.
    const styled_children = audit_snap.children(styled);
    if (styled_children.len == 0) return error.StyledHasNoLabel;
    const styled_label = audit_snap.nodes[styled_children[0]];
    const styled_label_clip = styled_label.clip_bounds orelse return error.StyledLabelUnclipped;
    if (!rectSame(styled_label_clip, styled.visual_bounds)) return error.StyledLabelClipWrong;
    if (!styled_label.clip_axes.x or !styled_label.clip_axes.y) {
        return error.StyledLabelClipAxesMissing;
    }
    try report.emit("round-trip relations: styled_parent={d}/{s} parent_lists_child={} " ++
        "child_parent={d}/{s} styled_label={d}/{s} label_clip=[{s}]\n", .{
        styled_parent_index,
        @tagName(styled_parent.semantics.role),
        childContains(audit_snap, &styled_parent, styled),
        child_parent_index,
        @tagName(container.semantics.role),
        styled_label.index,
        @tagName(styled_label.semantics.role),
        rectText(styled_label_clip, &clip_buf),
    });

    // ── 7d. a state transition on the same identity ──
    // The pick at the control's own padding returns the CONTROL's handle,
    // because the label child does not cover that point. That handle is what
    // has to survive the transition.
    const styled_probe = probeOnControl(audit_snap, styled, null) orelse return error.NoStyledPadding;
    const styled_handle = inspector.pickHandleAt(styled_probe) orelse return error.PickMissed;
    if (!styled_handle.id.eql(styled_id)) return error.StyledPickWrongNode;
    try report.emit("round-trip restyle: redraw_pending={} frames={d} frame={d} " ++
        "probe=({d:.1},{d:.1}) handle=slot={d}/gen={d}\n", .{
        audit_redraw,
        audit_frames,
        audit_snap.frame_number,
        styled_probe[0],
        styled_probe[1],
        styled_handle.id.slot,
        styled_handle.generation,
    });
    const fill_before = styled.style.fill;
    const label_before = styled.semantics.label orelse "";
    try session.update(Panel, panel, {}, struct {
        fn apply(value: *Panel, _: void) !void {
            value.audit_fill = audit_fill_b;
            value.audit_label = audit_label_b;
        }
    }.apply);
    const restyle_redraw = try session.takeRedraw(app.window);
    const restyle_frames = try driveFrames(&smoke, 1);
    const restyled_snap = inspector.latestSnapshot() orelse return error.NoSnapshot;
    // Resolved through the public handle the pick handed out, not through a
    // fresh lookup of the id.
    const restyled = try inspector.resolveHandle(styled_handle);
    const restyled_by_id = restyled_snap.findNode(styled_id) orelse return error.StyledVanished;
    var restyled_buf: [640]u8 = undefined;
    try report.emit("round-trip restyle: redraw_pending={} frames={d} frame={d} {s}\n", .{
        restyle_redraw,
        restyle_frames,
        restyled_snap.frame_number,
        styleText(restyled, &restyled_buf),
    });
    try report.emit("round-trip restyle: fill_before=[{d:.3} {d:.3} {d:.3} {d:.3}] " ++
        "fill_after=[{d:.3} {d:.3} {d:.3} {d:.3}] label_before=\"{s}\" label_after=\"{s}\" " ++
        "handle_matches_snapshot={} identity_preserved={}\n", .{
        fill_before[0],
        fill_before[1],
        fill_before[2],
        fill_before[3],
        restyled.style.fill[0],
        restyled.style.fill[1],
        restyled.style.fill[2],
        restyled.style.fill[3],
        label_before,
        restyled.semantics.label orelse "<none>",
        restyled.index == restyled_by_id.index,
        restyled.id.slot == styled_id.slot and restyled.id.generation == styled_id.generation,
    });
    if (!colorSame(restyled.style.fill, audit_fill_b)) return error.RestyleFillWrong;
    if (colorSame(restyled.style.fill, audit_fill_a)) return error.RestyleFillUnchanged;
    if (!std.mem.eql(u8, restyled.semantics.label orelse "", audit_label_b)) {
        return error.RestyleLabelWrong;
    }
    if (restyled.id.slot != styled_id.slot or restyled.id.generation != styled_id.generation) {
        return error.RestyleReplacedIdentity;
    }
    if (restyled.index != restyled_by_id.index) return error.RestyleHandleDisagrees;
    // Every style field the transition did not author must survive it.
    if (restyled.style.opacity != audit_opacity) return error.RestyleOpacityLost;
    if (restyled.style.layer != audit_layer) return error.RestyleLayerLost;
    if (restyled.style.gap != audit_gap) return error.RestyleGapLost;
    if (!restyled.style.has_shadow) return error.RestyleShadowLost;
    if (!std.mem.eql(u8, restyled.semantics.accessible_label orelse "", audit_accessible_label)) {
        return error.RestyleAccessibleLost;
    }

    // ── 7e. the registered source location, round-tripped ──
    try inspector.registerSource(styled_id, .{
        .file = audit_source_file,
        .line = audit_source_line,
        .column = audit_source_column,
        .component_name = audit_source_component,
    });
    _ = try driveFrames(&smoke, 1);
    const sourced_snap = inspector.latestSnapshot() orelse return error.NoSnapshot;
    const sourced = sourced_snap.findNode(styled_id) orelse return error.StyledVanished;
    const source = sourced.source orelse return error.SourceNotReported;
    try report.emit("round-trip source: file=\"{s}\" line={d} column={d} component=\"{s}\" " ++
        "node_slot={d} handle_slot={d}\n", .{
        source.file,
        source.line,
        source.column,
        source.component_name,
        sourced.id.slot,
        restyled.id.slot,
    });
    if (!std.mem.eql(u8, source.file, audit_source_file)) return error.SourceFileWrong;
    if (source.line != audit_source_line) return error.SourceLineWrong;
    if (source.column != audit_source_column) return error.SourceColumnWrong;
    if (!std.mem.eql(u8, source.component_name, audit_source_component)) {
        return error.SourceComponentWrong;
    }

    // ── 7f. focus and capture through the real pointer path ──
    // A real press CAPTURES the pointer on the control under it, and a real
    // release lets it go. The snapshot is the only place the inspector can
    // learn either, so both are read from the frame committed after each.
    const sourced_probe = probeOnControl(sourced_snap, sourced, null) orelse return error.NoStyledPadding;
    var focus_buf: [256]u8 = undefined;
    try report.emit("round-trip focus: before {s}\n", .{focusText(sourced, &focus_buf)});
    if (!sourced.focus.can_focus) return error.StyledCannotFocus;
    if (sourced.focus.tab_index != audit_tab_index) return error.TabIndexWrong;
    if (sourced.focus.tab_group != audit_tab_group) return error.TabGroupWrong;
    if (sourced.focus.is_focused) return error.StyledFocusedBeforePress;
    if (sourced.capture.is_captured or sourced.capture.pointer_count != 0) {
        return error.CapturedBeforePress;
    }
    var press_buf: [96]u8 = undefined;
    var capture_buf: [96]u8 = undefined;
    const styled_clicks_before = view.styled_clicks;
    _ = try app.handle(.{ .mouse_move = .{ .x = sourced_probe[0], .y = sourced_probe[1] } });
    _ = try app.handle(.{ .mouse_down = .{
        .button = .left,
        .x = sourced_probe[0],
        .y = sourced_probe[1],
        .click_count = 1,
    } });
    // The CURRENT tree: driving a frame replaced the one the mount read.
    const pressed_target = app.focus_manager.captured(
        app.tree_ptr orelse return error.NoCommittedTree,
        .{ .mouse = .left },
        null,
    );
    const pressed_focus = app.focus_manager.current;
    _ = try driveFrames(&smoke, 1);
    const held_snap = inspector.latestSnapshot() orelse return error.NoSnapshot;
    const held = held_snap.findNode(styled_id) orelse return error.StyledVanished;
    const held_container = held_snap.findNode(clip_container_id) orelse return error.NoClipContainer;
    try report.emit("round-trip focus: pressed probe=({d:.1},{d:.1}) focus={s} " ++
        "captured={s} frame={d}\n", .{
        sourced_probe[0],
        sourced_probe[1],
        if (pressed_focus) |id| widgetIdText(id, &press_buf) else "<none>",
        if (pressed_target) |id| widgetIdText(id, &capture_buf) else "<none>",
        held_snap.frame_number,
    });
    try report.emit("round-trip focus: held {s}\n", .{focusText(held, &focus_buf)});
    if (pressed_target == null or !pressed_target.?.eql(styled_id)) {
        return error.PressDidNotCapture;
    }
    if (pressed_focus == null or !pressed_focus.?.eql(styled_id)) {
        return error.PressDidNotFocus;
    }
    if (!held.focus.is_focused) return error.HeldFrameNotFocused;
    if (!held.capture.is_captured or held.capture.pointer_count != 1) {
        return error.CaptureNotReported;
    }
    // The container is not an ancestor of the focused control, so its focus
    // scope must NOT claim the focus.
    if (held_container.focus.contains_focus) return error.NonAncestorReportsFocusScope;
    _ = try app.handle(.{ .mouse_up = .{
        .button = .left,
        .x = sourced_probe[0],
        .y = sourced_probe[1],
        .click_count = 1,
    } });
    _ = try driveFrames(&smoke, 1);
    const released_snap = inspector.latestSnapshot() orelse return error.NoSnapshot;
    const released = released_snap.findNode(styled_id) orelse return error.StyledVanished;
    try report.emit("round-trip focus: released frame={d} {s} handler_clicks={d}\n", .{
        released_snap.frame_number,
        focusText(released, &focus_buf),
        view.styled_clicks,
    });
    // Release ends the CAPTURE and nothing else: the press still activated
    // the control, and focus is not owned by the pointer.
    if (released.capture.is_captured or released.capture.pointer_count != 0) {
        return error.CaptureNotReleased;
    }
    if (!released.focus.is_focused) return error.ReleaseLostFocus;
    if (view.styled_clicks != styled_clicks_before + 1) return error.PressNotRouted;

    // Focus MOVES to the clipped child, and the container's focus scope
    // flips with it: a relationship that has to be read twice to mean
    // anything.
    const clip_clicks_before = view.clip_clicks;
    _ = try app.handle(.{ .mouse_move = .{ .x = clip_probe[0], .y = clip_probe[1] } });
    _ = try app.handle(.{ .mouse_down = .{
        .button = .left,
        .x = clip_probe[0],
        .y = clip_probe[1],
        .click_count = 1,
    } });
    const moved_focus = app.focus_manager.current;
    _ = try app.handle(.{ .mouse_up = .{
        .button = .left,
        .x = clip_probe[0],
        .y = clip_probe[1],
        .click_count = 1,
    } });
    _ = try driveFrames(&smoke, 1);
    const moved_snap = inspector.latestSnapshot() orelse return error.NoSnapshot;
    const moved_child = moved_snap.findNode(clip_child_id) orelse return error.NoClipChild;
    const moved_styled = moved_snap.findNode(styled_id) orelse return error.StyledVanished;
    const moved_container = moved_snap.findNode(clip_container_id) orelse return error.NoClipContainer;
    try report.emit("round-trip focus: moved probe=({d:.1},{d:.1}) focus={s} frame={d}\n", .{
        clip_probe[0],
        clip_probe[1],
        if (moved_focus) |id| widgetIdText(id, &clip_buf) else "<none>",
        moved_snap.frame_number,
    });
    try report.emit("round-trip focus: moved child {s}\n", .{focusText(moved_child, &focus_buf)});
    try report.emit("round-trip focus: moved styled {s}\n", .{focusText(moved_styled, &focus_buf)});
    try report.emit("round-trip focus: moved container {s} clip_clicks={d}\n", .{
        focusText(moved_container, &focus_buf),
        view.clip_clicks,
    });
    if (moved_focus == null or !moved_focus.?.eql(clip_child_id)) {
        return error.FocusDidNotMove;
    }
    if (!moved_child.focus.is_focused) return error.MovedChildNotFocused;
    if (moved_styled.focus.is_focused) return error.MovedStyledStillFocused;
    if (!moved_container.focus.contains_focus) return error.ContainerMissingFocusScope;
    if (moved_child.capture.is_captured) return error.ChildStillCaptured;
    if (view.clip_clicks != clip_clicks_before + 1) return error.ClipPressNotRouted;
    // The focus moved out of the styled control, which is a sibling of the
    // container, and into the container's own subtree.
    const moved_parent_index = moved_child.parent_index orelse
        return error.MovedChildParentMissing;
    try report.emit("round-trip focus: child_parent={d} container_index={d} same={}\n", .{
        moved_parent_index,
        moved_container.index,
        moved_parent_index == moved_container.index,
    });
    if (moved_parent_index != moved_container.index) return error.MovedChildParentChanged;

    // ── 7g. the final image, dumped from what the frame produced ──
    // The bytes are the frame's own final sRGB readback, copied out of a
    // frame that was submitted and then read at a queue-idle boundary. No
    // re-render, no second blit, no approximation of the image.
    if (ppm_path) |path| {
        // The public dump: the Oklab intermediate this binary already reads
        // back for its pixel probes, written by the same `frame.writePpm` the
        // frame pipeline uses, so the bytes are that pipeline's own Oklab ->
        // sRGB conversion rather than a second writer's opinion of it.
        smoke.ppm_armed = true;
        const dump_frames = try driveFrames(&smoke, 1);
        smoke.ppm_armed = false;
        const oklab = try painter.readbackImage();
        const extent = painter.target_extent;
        try frame.writePpm(gpa, io, path, oklab, extent);
        const pixels: usize = @as(usize, extent.width) * extent.height;
        try report.emit("ppm: path=\"{s}\" format=P6 size={d}x{d} frames_driven={d} " ++
            "pixels={d} source=frame.writePpm over the Oklab readback of a submitted frame\n", .{
            path,
            extent.width,
            extent.height,
            dump_frames,
            pixels,
        });
    }

    // ── 8. hold the window up for an external compositor capture ──
    // Only the windowed mode has a compositor to capture. Holding the headless
    // run would present nothing, so the flag is refused rather than counted.
    if (hold_ms > 0 and !native) return error.HoldRequiresNativeMode;
    if (hold_ms > 0) {
        try report.emit("HOLD-BEGIN {d}ms\n", .{hold_ms});
        const until = sdl3.timer.getMillisecondsSinceInit() + hold_ms;
        while (sdl3.timer.getMillisecondsSinceInit() < until) {
            const live = try application.getWindow(handle);
            live.requestPresentation();
            _ = try smoke.step();
            try Io.sleep(io, Io.Duration.fromMilliseconds(8), .real);
        }
        const live = try application.getWindow(handle);
        try report.emit("HOLD-END presented={d} observed={d}x{d} visible={} occluded={} focused={}\n", .{
            smoke.frames_presented,
            live.observed.size.width,
            live.observed.size.height,
            live.observed.visible,
            live.observed.occluded,
            live.observed.focused,
        });
    }

    // ── 9. bounded frame collector, and the GPU spans joined to it ──
    const frames_before = inspector.frame_collector.total_recorded;
    const driven = try driveFrames(&smoke, bounded_frames);
    const frames_after = inspector.frame_collector.total_recorded;
    try report.emit("collectors frame: capacity={d} reserved={d} requested={d} committed={d} " ++
        "recorded_before={d} recorded_after={d} retained={d} overruns={d} bounded={}\n", .{
        inspector.frame_collector.capacity(),
        inspector.frame_collector.reservedCapacity(),
        bounded_frames,
        driven,
        frames_before,
        frames_after,
        inspector.frame_collector.count,
        inspector.frame_collector.overruns,
        inspector.frame_collector.count <= inspector.frame_collector.capacity() and
            inspector.frame_collector.count == inspector.frame_collector.capacity(),
    });
    // Every retained frame record, oldest first, with the measured GPU span
    // when one was attached to that exact frame. One record per frame: the
    // span joins the record the host already wrote instead of adding one.
    for (0..inspector.frame_collector.count) |index| {
        const record = inspector.frame_collector.get(index) orelse continue;
        try report.emit("collectors frame[{d}]: frame_id={d} cpu_frame_ns={d} " ++
            "timestamp_ns={d} gpu_execute_ns={?d}\n", .{
            index,
            record.frame_number,
            record.cpu_frame_ns,
            record.timestamp_ns,
            record.gpu_execute_ns,
        });
    }

    // ── 9a. the measured GPU timestamps ──
    // Reported only when they were asked for AND the device offered them.
    // A refusal is printed as a refusal; nothing here is derived from wall
    // clock time or from a previous frame's numbers.
    try report.emit("gpu-timing: requested={} enabled={} frames_written={d} " ++
        "frames_read={d} reads_refused={d} spans={d}/{d} attached={d} " ++
        "unattached={d} refusal={s}\n", .{
        timing.requested,
        timing.enabled(),
        timing.frames_written,
        timing.frames_read,
        timing.reads_refused,
        timing.span_count,
        timing_span_capacity,
        timing.attached,
        timing.unattached,
        timing.refusal orelse "<none>",
    });
    if (timing.enabled()) {
        const info = timing.info.?;
        try report.emit("gpu-timing: period_ns={d} valid_bits={d} tick_mask=0x{x} " ++
            "query_pairs={d} pair_queries={d}\n", .{
            info.period_ns,
            info.valid_bits,
            info.mask(),
            timing_slots,
            timing_queries_per_frame,
        });
        const first = timing.span_count -| timing.spans.len;
        for (0..timing.span_count) |offset| {
            const span = timing.spans[first + offset];
            try report.emit("gpu-timing span[{d}]: frame={d} queries=[{d},{d}] " ++
                "start_tick={d} end_tick={d} ticks={d} elapsed_ns={d} attached={}\n", .{
                offset,
                span.frame_number,
                span.first_query,
                span.first_query + 1,
                span.start_tick,
                span.end_tick,
                span.ticks,
                span.elapsed_ns,
                span.attached,
            });
        }
    }

    // ── 10. bounded task collector over the REAL task service ──
    const tasks_before = inspector.task_collector.total_recorded;
    var payloads: [bounded_tasks]Work = undefined;
    for (&payloads) |*payload| {
        payload.* = .{ .sleep_ns = 3 * std.time.ns_per_ms };
        _ = try session.spawnWorker(
            Work,
            Panel,
            Work.run,
            Panel.onWorkDone,
            panel.weak(),
            payload,
            .{ .name = "w24-inspector-work" },
        );
    }
    const tasks_queued = inspector.task_collector.total_recorded - tasks_before;
    const tasks_done = try pumpUntil(
        &smoke,
        sdl3.timer.getMillisecondsSinceInit() + 10_000,
        tasksSettled,
    );
    try report.emit("collectors task: capacity={d} reserved={d} requested={d} drained={} " ++
        "queued_facts={d} finished_facts={d} recorded={d} retained={d} overruns={d} bounded={}\n", .{
        inspector.task_collector.capacity(),
        inspector.task_collector.reservedCapacity(),
        bounded_tasks,
        tasks_done,
        bridge.queued_facts,
        bridge.finished_facts,
        inspector.task_collector.total_recorded,
        inspector.task_collector.count,
        inspector.task_collector.overruns,
        inspector.task_collector.count <= inspector.task_collector.capacity(),
    });
    var after_tasks: PanelFacts = .{};
    try session.read(Panel, panel, &after_tasks, readPanel);
    try report.emit("collectors task: queued_facts_recorded={d} model.tasks_done={d}\n", .{
        tasks_queued,
        after_tasks.tasks_done,
    });
    for (0..inspector.task_collector.count) |index| {
        const record = inspector.task_collector.get(index) orelse continue;
        try report.emit("collectors task[{d}]: id={d} priority={s} name=\"{s}\" queued_ns={d} " ++
            "start_ns={d} end_ns={d} duration_ns={d} window={?d}\n", .{
            index,
            record.task_id,
            @tagName(record.priority),
            record.getName(),
            record.queued_ns,
            record.start_ns,
            record.end_ns,
            record.duration_ns,
            record.window_id,
        });
    }

    // ── 11. bounded action collector through the real registry ──
    const actions_before = inspector.action_collector.total_recorded;
    const live_tree = app.tree_ptr orelse return error.NoCommittedTree;
    for (0..bounded_actions) |index| {
        const result = try registry.dispatch(
            live_tree,
            app.focus_manager.current,
            Dispatch.name,
            null,
        );
        try report.emit("collectors action[{d}]: dispatch={s} result={s}\n", .{
            index,
            Dispatch.name,
            @tagName(result),
        });
    }
    var after_actions: PanelFacts = .{};
    try session.read(Panel, panel, &after_actions, readPanel);
    try report.emit("collectors action: capacity={d} reserved={d} requested={d} " ++
        "recorded={d} retained={d} overruns={d} bounded={} model_dispatched={d}\n", .{
        inspector.action_collector.capacity(),
        inspector.action_collector.reservedCapacity(),
        bounded_actions,
        inspector.action_collector.total_recorded - actions_before,
        inspector.action_collector.count,
        inspector.action_collector.overruns,
        inspector.action_collector.count <= inspector.action_collector.capacity(),
        after_actions.dispatched,
    });
    for (0..inspector.action_collector.count) |index| {
        const record = inspector.action_collector.get(index) orelse continue;
        var target_buf: [96]u8 = undefined;
        try report.emit("collectors action[{d}]: name=\"{s}\" result={s} duration_ns={d} " ++
            "depth={d} target={s}\n", .{
            index,
            record.getName(),
            @tagName(record.result),
            record.duration_ns,
            record.dispatch_depth,
            if (record.target) |id| widgetIdText(id, &target_buf) else "<none>",
        });
    }

    // ── 12. one JSON dump of the live frame, and a leak-checked shutdown ──
    var dump: Io.Writer.Allocating = .init(gpa);
    defer dump.deinit();
    try inspector.dumpSnapshotJson(&dump.writer);
    try report.emit("snapshot-json: bytes={d} head={s}\n", .{
        dump.written().len,
        dump.written()[0..@min(dump.written().len, 220)],
    });
    var jsonl: Io.Writer.Allocating = .init(gpa);
    defer jsonl.deinit();
    try inspector.writePerformanceJsonl(&jsonl.writer);
    try report.emit("performance-jsonl: lines={d}\n", .{
        std.mem.count(u8, jsonl.written(), "\n"),
    });

    var final_panel: PanelFacts = .{};
    try session.read(Panel, panel, &final_panel, readPanel);

    service.setObserver(null);
    const closed = try application.closeWindow(handle);
    _ = try application.step();
    try report.emit("close: released={} window_count={d} host_running={} " ++
        "snapshots_after_close={s}\n", .{
        closed,
        application.window_count,
        application.isRunning(),
        if (inspector.latest_snapshot == null) "<cleared>" else "<retained>",
    });

    // Scalars the final line reports, read while their owners are still whole:
    // the owner below frees the view and releases the App, so nothing below
    // may dereference either.
    const drawn = view.drawn;
    const sheet_draws = view.sheet_draws;
    const clip_clicks = view.clip_clicks;
    const styled_clicks = view.styled_clicks;
    const frames_committed = smoke.frames_committed;
    const frames_presented = smoke.frames_presented;
    const overlays_resolved = smoke.overlays_resolved;
    // The one owner, in the one order, on the success path too: the window
    // is closed and the host released while the App, the view, the inspector
    // and the device are all still alive, because `destroyWindow` and
    // `deinit` reach through each of them.
    cleanup.run();
    try report.emit("teardown: model_release={s}\n", .{
        if (cleanup.panel_release) |err| @errorName(err) else "ok",
    });
    try report.emit("shutdown: mode={s} session_deinit={s} model_dispatched={d} " ++
        "model_tasks_done={d} view_draws={d} sheet_draws={d} frames_committed={d} " ++
        "frames_presented={d} overlays_resolved={d} model_target=\"{s}\" " ++
        "model_spare=\"{s}\" model_sheet_open={} model_sheet_label=\"{s}\" " ++
        "model_variant={d} model_audit_open={} model_audit_label=\"{s}\" " ++
        "clip_clicks={d} styled_clicks={d}\n", .{
        if (native) "native" else "headless",
        if (cleanup.session_deinit) |err| @errorName(err) else "ok",
        final_panel.dispatched,
        final_panel.tasks_done,
        drawn,
        sheet_draws,
        frames_committed,
        frames_presented,
        overlays_resolved,
        final_panel.target,
        final_panel.spare,
        final_panel.sheet_open,
        final_panel.sheet_label,
        final_panel.variant,
        final_panel.audit_open,
        final_panel.audit_label,
        clip_clicks,
        styled_clicks,
    });
    // A teardown that reported a failure is not a successful run. Both lines
    // above already said what failed; this is what makes the exit code agree.
    if (cleanup.panel_release) |err| return err;
    if (cleanup.session_deinit) |err| return err;

    try report.emit("W24 inspector interaction smoke done\n", .{});
}
