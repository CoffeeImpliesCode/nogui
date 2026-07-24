//! Window — owns the SDL window, the GPU window, the ping-pong
//! frame arenas, the event loop, and the 9-slice batch renderer.
//!
//! PROTOTYPE — throwaway design exploration.

const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const vk = noapi.vk;

const Widget = @import("widget.zig").Widget;
const DrawCtx = @import("drawctx.zig").DrawCtx;
const Size = @import("widget.zig").Size;
const Context = @import("context.zig").Context;
const Batch9Slice = @import("render_9slice.zig").Batch9Slice;
const SliceRect = @import("render_9slice.zig").SliceRect;
const GlyphSweeper = @import("sweeper.zig").GlyphSweeper;
const Curve = @import("sweeper.zig").Curve;
const MATERIAL_SIZE = @import("sweeper.zig").MATERIAL_SIZE;

const FRAME_ARENAS = 2;
const MAX_MATERIALS = 128;
const NUM_GLYPH_SLOTS = 95; // ASCII printable 32-126

/// Glyph atlas: maps ASCII char → sweeper + metrics.
const GlyphEntry = struct {
    sweeper: ?*GlyphSweeper = null,
    material_slot: u32 = 0,
    advance: f32 = 0,
    bearing_x: f32 = 0,
    bearing_y: f32 = 0,
    glyph_w: f32 = 0,
    glyph_h: f32 = 0,
};

/// Represents a single OS window with its own GPU swapchain.
pub const Window = struct {
    context: *Context,
    sdl_window: sdl3.video.Window,
    gpu_window: noapi.Surface,
    sdl_win_id: u32,
    batch: Batch9Slice,
    sweeper: ?*GlyphSweeper = null, // 'A' background glyph
    should_close: bool = false,

    /// Glyph atlas: per-character sweepers and material slots.
    glyphs: [NUM_GLYPH_SLOTS]GlyphEntry = .{GlyphEntry{}} ** NUM_GLYPH_SLOTS,

    /// GPU buffer for materials (solid, glyph, etc.).
    material_buf: noapi.GpuPtr = .{ .cpu = undefined, .gpu = 0 },
    material_buf_bda: u64 = 0,
    next_material_slot: u32 = 1, // slot 0 = background 'A'

    /// Ping-pong frame arenas.
    arenas: [FRAME_ARENAS]std.heap.ArenaAllocator,
    current_arena: usize = 0,

    /// Offscreen R32G32B32A32_SFLOAT render target for Oklab rendering.
    render_target: noapi.TextureHandle = .{},
    rt_width: u32 = 0,
    rt_height: u32 = 0,

    // Blit shaders: fullscreen vertex + Oklab→sRGB fragment.
    blit_vert: noapi.Shader,
    blit_frag: noapi.Shader,
    blit_heap: noapi.DescriptorHeap,

    /// Register a glyph sweeper for an ASCII character.
    pub fn addGlyph(self: *@This(), char: u8, sweeper: *GlyphSweeper, advance: f32, bearing_x: f32, bearing_y: f32, glyph_w: f32, glyph_h: f32) void {
        const idx = char -% 32;
        if (idx < NUM_GLYPH_SLOTS) {
            self.glyphs[idx] = .{
                .sweeper = sweeper,
                .material_slot = self.next_material_slot,
                .advance = advance,
                .bearing_x = bearing_x,
                .bearing_y = bearing_y,
                .glyph_w = glyph_w,
                .glyph_h = glyph_h,
            };
            self.next_material_slot += 1;
        }
    }

    fn createRenderTarget(self: *@This(), w: u32, h: u32) !void {
        if (self.render_target.texture.id != 0 and w == self.rt_width and h == self.rt_height) return;
        if (self.render_target.texture.id != 0) {
            self.context.gpu.textureDestroy(self.render_target);
        }
        self.render_target = try self.context.gpu.textureCreate(.{
            .dimensions = .{ w, h, 1 },
            .format = .rgba32_float,
            .usage = .{ .color_attachment = true, .sampled = true },
        });
        self.rt_width = w;
        self.rt_height = h;

        // Update blit descriptor heap
        const rt_desc = self.context.gpu.textureViewDescriptor(self.render_target, .{ .format = .default });
        self.context.gpu.descHeapSetTextures(self.blit_heap, 0, &.{rt_desc});
    }

    pub fn init(context: *Context, title: [:0]const u8, w: u32, h: u32, vert_spv: []const u32, frag_spv: []const u32, blit_vert_spv: []const u32, blit_frag_spv: []const u32) !@This() {
        const sdl_win = try sdl3.video.Window.init(title, w, h, .{ .resizable = true });
        try sdl_win.show();

        const sdl_surface = try sdl3.vulkan.Surface.init(
            sdl_win,
            @ptrFromInt(@intFromEnum(context.gpu.instanceHandle())),
            null,
        );
        const surface: noapi.vk.SurfaceKHR = @enumFromInt(@intFromPtr(sdl_surface.surface));
        const gpu_window = try noapi.Surface.init(&context.gpu, surface, .{ .width = w, .height = h });
        const win_id = try sdl_win.getId();

        var arenas: [FRAME_ARENAS]std.heap.ArenaAllocator = undefined;
        for (&arenas) |*a| {
            a.* = std.heap.ArenaAllocator.init(context.gpa);
        }

        // Material buffer: room for 64 materials
        const mat_buf = try context.gpu.gpuMalloc(MAX_MATERIALS * MATERIAL_SIZE, 16, .default);
        const mat_bda = mat_buf.gpu;

        var batch = try Batch9Slice.init(&context.gpu, vert_spv, frag_spv);
        batch.material_buf_bda = mat_bda;

        // Blit shaders + descriptor heap
        const bv = try context.gpu.shaderCreate(blit_vert_spv, .vertex, "main", "fullscreen_vert");
        const bf = try context.gpu.shaderCreate(blit_frag_spv, .fragment, "main", "blit_oklab");
        const bh = try context.gpu.descHeapCreate(8, 0, 1);

        // Create a sampler for the blit (texelFetch doesn't use filter modes)
        const blit_sampler = context.gpu.samplerDescriptor(.{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .mip_filter = .nearest,
        });
        context.gpu.descHeapSetSamplers(bh, 0, &.{blit_sampler});

        var self = @This(){
            .context = context,
            .sdl_window = sdl_win,
            .gpu_window = gpu_window,
            .sdl_win_id = win_id,
            .batch = batch,
            .material_buf = mat_buf,
            .material_buf_bda = mat_bda,
            .arenas = arenas,
            .blit_vert = bv,
            .blit_frag = bf,
            .blit_heap = bh,
        };
        try self.createRenderTarget(w, h);
        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.context.gpu.waitIdle();
        self.batch.deinit();
        self.context.gpu.shaderDestroy(self.blit_vert);
        self.context.gpu.shaderDestroy(self.blit_frag);
        self.context.gpu.descHeapDestroy(self.blit_heap);
        if (self.render_target.texture.id != 0) self.context.gpu.textureDestroy(self.render_target);
        for (&self.arenas) |*a| a.deinit();
    }

    pub fn pollEvents(self: *@This()) void {
        while (sdl3.events.poll()) |ev| {
            switch (ev) {
                .quit => self.should_close = true,
                .window_close_requested => |we| {
                    if (we.id == self.sdl_win_id) self.should_close = true;
                },
                .key_down => |ke| {
                    if (ke.key == .escape) self.should_close = true;
                },
                .window_resized => |we| {
                    if (we.id == self.sdl_win_id) {
                        self.gpu_window.notifyResize(.{
                            .width = @intCast(we.width),
                            .height = @intCast(we.height),
                        });
                    }
                },
                else => {},
            }
        }
    }

    pub fn beginFrame(self: *@This()) !DrawCtx {
        self.current_arena = (self.current_arena + 1) % FRAME_ARENAS;
        const arena = &self.arenas[self.current_arena];
        _ = arena.reset(.retain_capacity);

        // Reset material slots each frame
        self.next_material_slot = 0;

        const schedule = self.gpu_window.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) {
                return DrawCtx{
                    .allocator = arena.allocator(),
                    .surface_size = .{ .width = 0, .height = 0 },
                };
            }
            return e;
        };
        _ = schedule;

        const surface_size = self.gpu_window.surfaceSize();
        // Recreate render target if size changed
        try self.createRenderTarget(surface_size.width, surface_size.height);

        return DrawCtx{
            .allocator = arena.allocator(),
            .surface_size = .{ .width = @floatFromInt(surface_size.width), .height = @floatFromInt(surface_size.height) },
        };
    }

    /// End the frame: render to offscreen Oklab target, then blit to swapchain with Oklab→sRGB.
    pub fn endFrame(self: *@This(), root: *Widget) void {
        const surface_size = self.gpu_window.surfaceSize();
        const sw = @as(f32, @floatFromInt(surface_size.width));
        const sh = @as(f32, @floatFromInt(surface_size.height));
        var cmd = self.gpu_window.commandsBegin();

        // ── Pass 1: render GUI to offscreen R32G32B32A32_SFLOAT (Oklab space) ──
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = self.render_target, .load_op = .clear, .store_op = .store, .clear_color = .{ 0.516395, 0.0, 0.0, 1.0 } },
        }, .render_area_size = .{ surface_size.width, surface_size.height } });

        // Material + widget rects
        var mat_slot: u32 = 0;
        if (self.sweeper) |s| {
            const glyph_size = @min(sw, sh) * 0.5;
            GlyphSweeper.writeMaterial(s.curve_buf_bda, self.material_buf, mat_slot, s.bearing_y, glyph_size, glyph_size, glyph_size, glyph_size);
            mat_slot += 1;
        }
        self.next_material_slot = mat_slot;

        var all_rects: [1024]SliceRect = undefined;
        const widget_count = collectWidgetRects(self, root, &all_rects, sw, sh);
        var total_rects = widget_count;

        var bg_cl: f32 = 0;
        var bg_cw: f32 = 0;
        var bg_ch: f32 = 0;
        if (self.sweeper) |s| {
            bg_cl = s.curve_left;
            bg_cw = s.curve_w;
            bg_ch = s.curve_h;
        }
        if (self.sweeper != null) {
            const glyph_size = @min(sw, sh) * 0.5;
            const rx = sw - glyph_size;
            const ry = sh - glyph_size;
            all_rects[total_rects] = .{
                .dst_x = rx,
                .dst_y = ry,
                .dst_w = glyph_size,
                .dst_h = glyph_size,
                .color = .{ 0.516395, 0.0, 0.0, 1.0 },
                .material_index = 1,
                .curve_left = bg_cl,
                .curve_bottom = if (self.sweeper) |s| s.curve_bottom else 0,
                .curve_w = bg_cw,
                .curve_h = bg_ch,
            };
            total_rects += 1;
        }

        cmd.setBlendEnable(true);
        self.batch.draw(&cmd, all_rects[0..total_rects], sw, sh);
        cmd.setBlendEnable(false);
        cmd.endRendering();

        // Barrier: transition render target from GENERAL to SHADER_READ_ONLY_OPTIMAL
        cmd.barrier(.{ .color_output = true }, .{ .fragment = true }, .{});

        // ── Pass 2: blit render target → swapchain with Oklab→sRGB ──
        const sc = self.gpu_window.currentImage();
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = .{ 0, 0, 0, 1 } },
        }, .render_area_size = .{ surface_size.width, surface_size.height } });

        cmd.setShaders(self.blit_vert, self.blit_frag);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.bindDescriptorSets(self.blit_heap);
        cmd.setBlendEnable(false);
        cmd.draw(noapi.PushData{}, 3, 1);
        cmd.endRendering();

        _ = self.gpu_window.endFrame(.{ .blit_to_swapchain = true });
    }

    /// Run the event loop.
    pub fn run(self: *@This(), gui: anytype) !void {
        self.context.frame_count = 0;
        while (!self.should_close) {
            self.pollEvents();

            var dc = try self.beginFrame();
            if (dc.surface_size.width == 0 or dc.surface_size.height == 0) {
                continue;
            }

            const root = try gui.draw(&dc);
            dc.layoutAndRender(root);

            if (@import("builtin").mode == .Debug) {
                debugPrintTree(root, 0);
            }

            self.endFrame(root);
            self.context.frame_count += 1;
        }
    }
};

/// Flatten the widget tree into 9-slice rects (stack-based DFS).
/// Labels emit per-character glyph rects referencing label_slot material.
fn collectWidgetRects(win: *Window, root: *Widget, rects: []SliceRect, sw: f32, sh: f32) u32 {
    _ = sw;
    _ = sh;
    var ri: u32 = 0;
    var stack: [512]*Widget = undefined;
    var sp: u32 = 0;
    stack[sp] = root;
    sp += 1;

    while (sp > 0 and ri < 1024) {
        sp -= 1;
        const w = stack[sp];

        // Emit background rect if widget has a color or border
        if (w.color[3] > 0 or w.border > 0) {
            if (w.border > 0) {
                // Border rect (behind fill)
                rects[ri] = .{
                    .dst_x = w.rect.x,
                    .dst_y = w.rect.y,
                    .dst_w = w.rect.w,
                    .dst_h = w.rect.h,
                    .color = w.border_color,
                };
                ri += 1;
            }
            // Fill rect (inset by border if present)
            const b = w.border;
            rects[ri] = .{
                .dst_x = w.rect.x + b,
                .dst_y = w.rect.y + b,
                .dst_w = w.rect.w - 2 * b,
                .dst_h = w.rect.h - 2 * b,
                .color = w.color,
            };
            ri += 1;
        }

        if (w.isContainer()) {
            if (w.children()) |kids| {
                var i: usize = kids.len;
                while (i > 0) {
                    i -= 1;
                    stack[sp] = kids[i];
                    sp += 1;
                }
            }
        } else {
            switch (w.kind) {
                .button => |btn| {
                    // Glyph rendering for button label
                    const baseline_y = w.rect.y + w.rect.h * 0.75;
                    var cursor_x = w.rect.x + 8;
                    for (btn.label) |ch| {
                        const idx = ch -% 32;
                        if (idx >= NUM_GLYPH_SLOTS) continue;
                        const entry = &win.glyphs[idx];
                        const gs = entry.sweeper orelse continue;
                        const ch_x = cursor_x + entry.bearing_x;
                        const ch_y = baseline_y - entry.bearing_y;
                        const ch_w = entry.glyph_w;
                        const ch_h = entry.glyph_h;
                        GlyphSweeper.writeMaterial(gs.curve_buf_bda, win.material_buf, entry.material_slot, gs.bearing_y, gs.curve_w, gs.curve_h, ch_w, ch_h);
                        if (ch_w > 0 and ch_h > 0) {
                            rects[ri] = .{
                                .dst_x = ch_x,
                                .dst_y = ch_y,
                                .dst_w = ch_w,
                                .dst_h = ch_h,
                                .color = .{ 0, 0, 0, 0 },
                                .material_index = entry.material_slot + 1,
                                .curve_left = gs.curve_left,
                                .curve_bottom = gs.curve_bottom,
                                .curve_w = gs.curve_w,
                                .curve_h = gs.curve_h,
                            };
                            ri += 1;
                            if (ri >= rects.len) break;
                        }
                        cursor_x += entry.advance;
                    }
                },
                .slider => |s| {
                    // Slider track already rendered as background rect above
                    const frac = @max(0, @min(1, (s.value.* - s.min) / (s.max - s.min)));
                    const fill_w = @max(4, w.rect.w * frac);
                    const b = w.border;
                    rects[ri] = .{
                        .dst_x = w.rect.x + b,
                        .dst_y = w.rect.y + b,
                        .dst_w = fill_w - 2 * b,
                        .dst_h = w.rect.h - 2 * b,
                        .color = .{ 0.824501, -0.095832, 0.068573, 1.0 },
                    };
                    ri += 1;
                },
                .label => |lbl| {
                    // Render each character with proper metrics
                    // Baseline at ~3/4 of label height (rough typographic baseline)
                    const baseline_y = w.rect.y + w.rect.h * 0.75;
                    var cursor_x = w.rect.x;
                    for (lbl.text) |ch| {
                        const idx = ch -% 32;
                        if (idx >= NUM_GLYPH_SLOTS) continue;
                        const entry = &win.glyphs[idx];
                        const gs = entry.sweeper orelse continue;

                        // Glyph rect positioned by metrics
                        const ch_x = cursor_x + entry.bearing_x;
                        const ch_y = baseline_y - entry.bearing_y;
                        const ch_w = entry.glyph_w;
                        const ch_h = entry.glyph_h;

                        GlyphSweeper.writeMaterial(gs.curve_buf_bda, win.material_buf, entry.material_slot, gs.bearing_y, gs.curve_w, gs.curve_h, ch_w, ch_h);

                        if (ch_w > 0 and ch_h > 0) {
                            rects[ri] = .{
                                .dst_x = ch_x,
                                .dst_y = ch_y,
                                .dst_w = ch_w,
                                .dst_h = ch_h,
                                .color = .{ 0, 0, 0, 0 },
                                .material_index = entry.material_slot + 1,
                                .curve_left = gs.curve_left,
                                .curve_bottom = gs.curve_bottom,
                                .curve_w = gs.curve_w,
                                .curve_h = gs.curve_h,
                            };
                            ri += 1;
                            if (ri >= rects.len) break;
                        }
                        cursor_x += entry.advance;
                    }
                },
                else => {
                    // No extra rendering beyond background rect
                },
            }
        }
    }
    return ri;
}

fn debugPrintTree(w: *Widget, depth: u32) void {
    const indent = "  " ** 10;
    const off = @min(2 * depth, @as(u32, 10));
    const prefix = indent[0..off];
    const name = switch (w.kind) {
        .column => "column",
        .row => "row",
        .button => "button",
        .slider => "slider",
        .label => "label",
    };
    std.debug.print("{s}{s} rect=({d:.0},{d:.0} {d:.0}x{d:.0})\n", .{ prefix, name, w.rect.x, w.rect.y, w.rect.w, w.rect.h });
    if (w.children()) |kids| {
        for (kids) |child| {
            debugPrintTree(child, depth + 1);
        }
    }
}
