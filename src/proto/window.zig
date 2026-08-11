//! Window — owns the SDL window, the GPU window, the ping-pong
//! frame arenas, the event loop, and the 9-slice batch renderer.
//!
//! Rendering pipeline:
//!   1. collectWidgetRects(RectCollectCtx) → []RenderCommand
//!   2. processRenderCommands() → SceneRect[] + GPU material writes
//!   3. Batch9Slice.draw() → GPU indexed draw
//!   4. Blit pass: Oklab → sRGB
//!
//! PROTOTYPE — throwaway design exploration but the pipeline contract
//! (RenderCommand enum → processRenderCommands → Batch9Slice) is final.

const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const vk = noapi.vk;

const Widget = @import("widget.zig").Widget;
const DrawCtx = @import("drawctx.zig").DrawCtx;
const Context = @import("context.zig").Context;
const Batch9Slice = @import("render_9slice.zig").Batch9Slice;
const Event = @import("event.zig").Event;
const dispatchEvents = @import("event.zig").dispatchEvents;
const SceneRect = @import("render_9slice.zig").SceneRect;
const GlyphSweeper = @import("sweeper.zig").GlyphSweeper;
const GlyphMaterial = @import("sweeper.zig").GlyphMaterial;
const MATERIAL_SIZE = @import("sweeper.zig").MATERIAL_SIZE;
const RenderCommand = @import("render_command.zig").RenderCommand;
const RenderCommandList = @import("render_command.zig").RenderCommandList;
const RectCollectCtx = @import("render_command.zig").RectCollectCtx;
const processRenderCommands = @import("render_command.zig").processRenderCommands;

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

// ─── SDL3 → nogui event translation helpers ──────────

const kc = sdl3.keycode;
const mouse = sdl3.mouse;

/// Translate SDL3 keycode (nullable) to our Key enum.
fn sdlKey(sdl_key: ?kc.Keycode) @import("widget.zig").Key {
    const k = sdl_key orelse return .unknown;
    return switch (k) {
        .escape => .escape,
        .return_key => .enter,
        .tab => .tab,
        .backspace => .backspace,
        .delete => .delete,
        .home => .home,
        .end => .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
        .space => .space,
        .a => .a,
        .b => .b,
        .c => .c,
        .d => .d,
        .e => .e,
        .f => .f,
        .g => .g,
        .h => .h,
        .i => .i,
        .j => .j,
        .k => .k,
        .l => .l,
        .m => .m,
        .n => .n,
        .o => .o,
        .p => .p,
        .q => .q,
        .r => .r,
        .s => .s,
        .t => .t,
        .u => .u,
        .v => .v,
        .w => .w,
        .x => .x,
        .y => .y,
        .z => .z,
        .zero => .k0,
        .one => .k1,
        .two => .k2,
        .three => .k3,
        .four => .k4,
        .five => .k5,
        .six => .k6,
        .seven => .k7,
        .eight => .k8,
        .nine => .k9,
        .func1 => .f1,
        .func2 => .f2,
        .func3 => .f3,
        .func4 => .f4,
        .func5 => .f5,
        .func6 => .f6,
        .func7 => .f7,
        .func8 => .f8,
        .func9 => .f9,
        .func10 => .f10,
        .func11 => .f11,
        .func12 => .f12,
        .func13 => .f13,
        .func14 => .f14,
        .func15 => .f15,
        .func16 => .f16,
        .func17 => .f17,
        .func18 => .f18,
        .func19 => .f19,
        .func20 => .f20,
        .func21 => .f21,
        .func22 => .f22,
        .func23 => .f23,
        .func24 => .f24,
        .left_shift => .lshift,
        .right_shift => .rshift,
        .left_ctrl => .lctrl,
        .right_ctrl => .rctrl,
        .left_alt => .lalt,
        .right_alt => .ralt,
        .left_gui => .lgui,
        .right_gui => .rgui,
        .minus => .minus,
        .equals => .equals,
        .left_bracket => .left_bracket,
        .right_bracket => .right_bracket,
        .semicolon => .semicolon,
        .apostrophe => .quote,
        .comma => .comma,
        .period => .period,
        .slash => .slash,
        .backslash => .backslash,
        .grave => .grave,
        .insert => .insert,
        .print_screen => .print_screen,
        .pause => .pause,
        .caps_lock => .caps_lock,
        else => .unknown,
    };
}

/// Translate SDL3 key modifier mask.
fn sdlMods(sdl_mod: kc.KeyModifier) @import("widget.zig").KeyMods {
    return .{
        .shift = sdl_mod.left_shift or sdl_mod.right_shift,
        .ctrl = sdl_mod.left_control or sdl_mod.right_control,
        .alt = sdl_mod.left_alt or sdl_mod.right_alt,
        .gui = sdl_mod.left_gui or sdl_mod.right_gui,
    };
}

/// Translate SDL3 mouse button.
fn sdlMouseButton(sdl_btn: mouse.Button) @import("widget.zig").MouseButton {
    return switch (sdl_btn) {
        .left => .left,
        .right => .right,
        .middle => .middle,
        .x1 => .x1,
        .x2 => .x2,
        else => .left,
    };
}

/// Represents a single OS window with its own GPU swapchain.
pub const Window = struct {
    context: *Context,
    sdl_window: sdl3.video.Window,
    gpu_window: noapi.Surface,
    sdl_win_id: u32,
    sdl_vk_surface: sdl3.vulkan.Surface,
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

    /// Per-frame event queue. Populated by pollEvents(), consumed by
    /// dispatchEvents() after layout. Cleared each frame.
    event_queue: std.ArrayListUnmanaged(Event) = .empty,

    /// Offscreen R32G32B32A32_SFLOAT render target for Oklab rendering.
    render_target: noapi.TextureHandle = .{},
    rt_width: u32 = 0,
    rt_height: u32 = 0,

    // Blit shaders: fullscreen vertex + Oklab→sRGB fragment.
    blit_vert: noapi.Shader,
    blit_frag: noapi.Shader,
    blit_heap: noapi.DescriptorHeap,

    /// Per-frame RenderCommand buffer (frame-arena allocated).
    cmd_buf: RenderCommandList = undefined,

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

    pub fn init(context: *Context, title: [:0]const u8, w: u32, h: u32, vert_spv: []const u32, frag_spv: []const u32, sort_spv: []const u32, blit_vert_spv: []const u32, blit_frag_spv: []const u32) !@This() {
        const sdl_win = try sdl3.video.Window.init(title, w, h, .{ .resizable = true });
        try sdl_win.show();

        var sdl_surface = try sdl3.vulkan.Surface.init(
            sdl_win,
            @ptrFromInt(@intFromEnum(context.gpu.instanceHandle())),
            null,
        );
        const surface: noapi.vk.SurfaceKHR = @enumFromInt(@intFromPtr(sdl_surface.surface));
        sdl_surface.surface = null;
        const gpu_window = try noapi.Surface.init(&context.gpu, surface, .{ .extent = .{ .width = w, .height = h } });
        const win_id = try sdl_win.getId();

        var arenas: [FRAME_ARENAS]std.heap.ArenaAllocator = undefined;
        for (&arenas) |*a| {
            a.* = std.heap.ArenaAllocator.init(context.gpa);
        }

        // Material buffer: room for 64 materials
        const mat_buf = try context.gpu.gpuMalloc(MAX_MATERIALS * MATERIAL_SIZE, 16, .default);
        const mat_bda = mat_buf.gpu;

        var batch = try Batch9Slice.init(&context.gpu, vert_spv, frag_spv, sort_spv);
        batch.material_buf_bda = mat_bda;

        // Blit shaders + descriptor heap
        const bv = try context.gpu.shaderCreate(blit_vert_spv, .vertex, "main", "fullscreen_vert");
        const bf = try context.gpu.shaderCreate(blit_frag_spv, .fragment, "main", "blit_oklab");
        const bh = try context.gpu.descHeapCreate(8, 0, 1);

        const blit_sampler = context.gpu.samplerDescriptor(.{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .mip_filter = .nearest,
        });
        context.gpu.descHeapSetSamplers(bh, 0, &.{blit_sampler});

        var self = @This(){
            .context = context,
            .sdl_window = sdl_win,
            .sdl_vk_surface = sdl_surface,
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
        self.event_queue.deinit(self.context.gpa);
        self.context.gpu.waitIdle() catch {};
        self.gpu_window.deinit();
        self.sdl_vk_surface.deinit();
        self.sdl_window.deinit();
        self.context.gpu.gpuFree(self.material_buf);
        self.batch.deinit();
        self.context.gpu.shaderDestroy(self.blit_vert);
        self.context.gpu.shaderDestroy(self.blit_frag);
        self.context.gpu.descHeapDestroy(self.blit_heap);
        if (self.render_target.texture.id != 0) self.context.gpu.textureDestroy(self.render_target);
        for (&self.arenas) |*a| a.deinit();
    }

    pub fn pollEvents(self: *@This()) void {
        self.event_queue.clearRetainingCapacity();
        const alloc = self.context.gpa;

        while (sdl3.events.poll()) |ev| {
            switch (ev) {
                .quit => self.should_close = true,
                .window_close_requested => |we| {
                    if (we.id == self.sdl_win_id) self.should_close = true;
                },
                .window_resized => |we| {
                    if (we.id == self.sdl_win_id) {
                        self.gpu_window.notifyResize(.{
                            .width = @intCast(@max(0, we.width)),
                            .height = @intCast(@max(0, we.height)),
                        });
                    }
                    self.event_queue.append(alloc, .{ .window_resized = .{
                        .win_id = we.id,
                        .width = @intCast(@max(0, we.width)),
                        .height = @intCast(@max(0, we.height)),
                    } }) catch {};
                },
                .mouse_motion => |mm| {
                    self.event_queue.append(alloc, .{ .mouse_move = .{
                        .x = mm.x,
                        .y = mm.y,
                        .rel_x = mm.x_rel,
                        .rel_y = mm.y_rel,
                    } }) catch {};
                },
                .mouse_button_down => |mb| {
                    self.event_queue.append(alloc, .{ .mouse_button_down = .{
                        .button = sdlMouseButton(mb.button),
                        .x = mb.x,
                        .y = mb.y,
                        .clicks = mb.clicks,
                    } }) catch {};
                },
                .mouse_button_up => |mb| {
                    self.event_queue.append(alloc, .{ .mouse_button_up = .{
                        .button = sdlMouseButton(mb.button),
                        .x = mb.x,
                        .y = mb.y,
                        .clicks = mb.clicks,
                    } }) catch {};
                },
                .mouse_wheel => |mw| {
                    self.event_queue.append(alloc, .{ .mouse_wheel = .{
                        .scroll_x = mw.x,
                        .scroll_y = mw.y,
                    } }) catch {};
                },
                .key_down => |ke| {
                    if (ke.key == .escape) {
                        self.should_close = true;
                    } else {
                        self.event_queue.append(alloc, .{ .key_down = .{
                            .key = sdlKey(ke.key),
                            .mods = sdlMods(ke.mod),
                            .repeat = ke.repeat,
                        } }) catch {};
                    }
                },
                .key_up => |ke| {
                    self.event_queue.append(alloc, .{ .key_up = .{
                        .key = sdlKey(ke.key),
                        .mods = sdlMods(ke.mod),
                    } }) catch {};
                },
                .window_focus_gained => |we| {
                    if (we.id == self.sdl_win_id) {
                        self.event_queue.append(alloc, .{ .window_focus = .{
                            .win_id = we.id,
                            .focused = true,
                        } }) catch {};
                    }
                },
                .window_focus_lost => |we| {
                    if (we.id == self.sdl_win_id) {
                        self.event_queue.append(alloc, .{ .window_focus = .{
                            .win_id = we.id,
                            .focused = false,
                        } }) catch {};
                    }
                },
                else => {},
            }
        }
    }

    pub fn beginFrame(self: *@This()) !DrawCtx {
        self.current_arena = (self.current_arena + 1) % FRAME_ARENAS;
        @import("drawctx.zig").resetTempId();
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
        try self.createRenderTarget(surface_size.width, surface_size.height);

        // Allocate RenderCommand buffer from frame arena
        const cmd_buf_slice = try arena.allocator().alloc(RenderCommand, 2048);
        self.cmd_buf = RenderCommandList.init(cmd_buf_slice);

        return DrawCtx{
            .allocator = arena.allocator(),
            .surface_size = .{ .width = @floatFromInt(surface_size.width), .height = @floatFromInt(surface_size.height) },
        };
    }

    /// End the frame: collect RenderCommands → process → draw → blit.
    pub fn endFrame(self: *@This(), root: *Widget) !void {
        const surface_size = self.gpu_window.surfaceSize();
        const sw = @as(f32, @floatFromInt(surface_size.width));
        const sh = @as(f32, @floatFromInt(surface_size.height));

        // ── Phase 1: Collect RenderCommands from widget tree ──
        const ctx = RectCollectCtx{ .windowed = .{
            .window_ptr = @ptrCast(self),
            .material_buf_cpu = @ptrCast(self.material_buf.cpu),
        } };
        collectWidgetRects(self, root, &self.cmd_buf, &ctx);

        // Always end with a blit command
        self.cmd_buf.push(.blit_oklab);

        // ── Phase 2: Process RenderCommands → SceneRects ──
        var slice_rects: [4096]SceneRect = undefined;
        const rect_count = processRenderCommands(
            self.cmd_buf.slice(),
            &slice_rects,
            self.material_buf_bda,
            @as(?[]u8, @ptrCast(@alignCast(self.material_buf.cpu[0 .. MAX_MATERIALS * MATERIAL_SIZE]))),
            &self.next_material_slot,
            self,
        );

        // ── Phase 3: GPU render ──
        var cmd = self.gpu_window.commandsBegin();

        // CS1 (V1b) FIRST, outside the render pass: the bag upload + the
        // GPU z-sort + the compute→graphics barrier.
        try self.batch.sort(&cmd, slice_rects[0..rect_count], &.{});

        // Pass 1: render GUI to offscreen R32G32B32A32_SFLOAT (Oklab space)
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = self.render_target, .load_op = .clear, .store_op = .store, .clear_color = .{ 0.516395, 0.0, 0.0, 1.0 } },
        }, .render_area_size = .{ surface_size.width, surface_size.height } });

        cmd.setBlendEnable(true);
        // The prototype driver has no clip stack — pass an empty clip list
        // (all SceneRect clip_ids are ~0 → the shader test is a no-op).
        self.batch.draw(&cmd, sw, sh);
        cmd.setBlendEnable(false);
        cmd.endRendering();

        // Barrier: transition render target from GENERAL to SHADER_READ_ONLY_OPTIMAL
        cmd.barrier(.{ .color_output = true }, .{ .fragment = true }, .{});

        // Pass 2: blit render target → swapchain with Oklab→sRGB
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

        _ = try self.gpu_window.endFrame(.{ .blit_to_swapchain = true });
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

            dispatchEvents(self.context, root, self.event_queue.items);

            if (@import("builtin").mode == .Debug) {
                debugPrintTree(root, 0);
            }

            try self.endFrame(root);
            self.context.frame_count += 1;
        }
    }
};

// ─── Shared widget tree → RenderCommand collector ──────────────

/// Walk the widget tree and emit RenderCommands via the provided context.
/// This is the SINGLE shared collector — used by both Window (GPU) and
/// HeadlessWindow (JSON capture). The RectCollectCtx union parameterizes
/// the material write path without code duplication.
///
/// DFS order ensures parents are emitted before children (back-to-front
/// for opaque widgets, though the 9-slice batcher doesn't sort).
pub fn collectWidgetRects(
    win: *Window,
    root: *Widget,
    cmds: *RenderCommandList,
    ctx: *const RectCollectCtx,
) void {
    var stack: [512]*Widget = undefined;
    var sp: u32 = 0;
    stack[sp] = root;
    sp += 1;

    while (sp > 0) {
        sp -= 1;
        const w = stack[sp];

        // Emit background rect if widget has a color or border
        if (w.color[3] > 0 or w.border > 0) {
            cmds.push(.{ .solid_rect = .{
                .rect = .{ .x = w.rect.x, .y = w.rect.y, .w = w.rect.w, .h = w.rect.h },
                .color = w.color,
                .border = w.border,
                .border_color = w.border_color,
                .corner_l = w.corner_radius,
                .corner_r = w.corner_radius,
                .corner_t = w.corner_radius,
                .corner_b = w.corner_radius,
            } });
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
                .button => |btn| emitGlyphCommands(win, btn.label, w.rect, cmds, ctx),
                .slider => |s| {
                    const frac = if (s.max == s.min) @as(f32, 0.5) else @max(0, @min(1, (s.value.* - s.min) / (s.max - s.min)));
                    const fill_w = @max(4, w.rect.w * frac);
                    const b = w.border;
                    cmds.push(.{ .solid_rect = .{
                        .rect = .{ .x = w.rect.x + b, .y = w.rect.y + b, .w = fill_w - 2 * b, .h = w.rect.h - 2 * b },
                        .color = .{ 0.824501, -0.095832, 0.068573, 1.0 },
                    } });
                },
                .label => |lbl| emitGlyphCommands(win, lbl.text, w.rect, cmds, ctx),
                else => {},
            }
        }
    }
}

/// Emit glyph RenderCommands for each character in text.
/// In windowed mode, writes GPU material via GlyphSweeper.writeMaterial.
/// In headless mode, records material_refs for JSON serialization.
fn emitGlyphCommands(
    win: *Window,
    text: []const u8,
    widget_rect: @import("widget.zig").Rect,
    cmds: *RenderCommandList,
    ctx: *const RectCollectCtx,
) void {
    const baseline_y = widget_rect.y + widget_rect.h * 0.75;
    var cursor_x = widget_rect.x;

    for (text) |ch| {
        const idx = ch -% 32;
        if (idx >= NUM_GLYPH_SLOTS) continue;
        const entry = &win.glyphs[idx];
        const gs = entry.sweeper orelse continue;

        const ch_x = cursor_x + entry.bearing_x;
        const ch_y = baseline_y - entry.bearing_y;
        const ch_w = entry.glyph_w;
        const ch_h = entry.glyph_h;

        // Context-specific material write
        switch (ctx.*) {
            .windowed => |wc| {
                const mat_buf: noapi.GpuPtr = .{ .cpu = wc.material_buf_cpu, .gpu = 0 };
                GlyphSweeper.writeMaterial(
                    gs.curve_buf_bda,
                    mat_buf,
                    entry.material_slot,
                    gs.bearing_y,
                    gs.curve_w,
                    gs.curve_h,
                    ch_w,
                    ch_h,
                );
            },
            .headless => |hc| {
                hc.material_refs.append(hc.gpa, .{
                    .mat_type = "glyph",
                    .slot = entry.material_slot + 1,
                    .curve_ref = &.{ch},
                }) catch {};
            },
        }

        if (ch_w > 0 and ch_h > 0) {
            cmds.push(.{ .glyph = .{
                .rect = .{ .x = ch_x, .y = ch_y, .w = ch_w, .h = ch_h },
                .color = .{ 0, 0, 0, 0 },
                .material_index = entry.material_slot + 1,
                .curve_left = gs.curve_left,
                .curve_bottom = gs.curve_bottom,
                .curve_w = gs.curve_w,
                .curve_h = gs.curve_h,
            } });
        }
        cursor_x += entry.advance;
    }
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
