//! 2_textures example — procedural checkerboard textures with cross-fade.
//! Port of the upstream no_gfx_api 2_textures example.
//! Generates two procedural checkerboard textures and renders a quad
//! with a time-varying lerp between them.

const std = @import("std");
const common = @import("common");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const vk = noapi.vk;
pub const tracy_impl = common.tracy_impl;
pub const tracy = common.tracy;
pub const tracy_options = common.tracy_options;

const tex_size: u32 = 256;
const checker_size: u32 = 32;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var app = try common.App.init("noapi 2_textures", gpa, io, 800, 600, 2, false);
    defer app.deinit();
    try app.sdl_win.show();
    win_id = try app.sdl_win.getId();

    // ── Shaders ────────────────────────────────
    const vert_shader = try noapi.Shader.createFromPath(
        gpa,
        io,
        app.gpu,
        "shaders/tex_vert.spv",
        .vertex,
        "main",
        "tex_vert",
    );
    defer vert_shader.destroy();
    const frag_shader = try noapi.Shader.createFromPath(
        gpa,
        io,
        app.gpu,
        "shaders/tex_frag.spv",
        .fragment,
        "main",
        "tex_frag",
    );
    defer frag_shader.destroy();

    // ── Vertex + index data ────────────────────────────
    // Quad: 4 vertices (position: vec2, uv: vec2), 6 indices
    const Vertex = extern struct { pos: [2]f32, uv: [2]f32 };
    const vertex_stride = @sizeOf(Vertex);

    const vert_buf = try app.gpu.gpuMalloc(vertex_stride * 4, 64, .default);
    defer app.gpu.gpuFree(vert_buf);

    const verts: [*]Vertex = @ptrCast(@alignCast(vert_buf.cpu));
    verts[0] = .{ .pos = .{ -0.5, 0.5 }, .uv = .{ 0.0, 0.0 } };
    verts[1] = .{ .pos = .{ 0.5, -0.5 }, .uv = .{ 1.0, 1.0 } };
    verts[2] = .{ .pos = .{ 0.5, 0.5 }, .uv = .{ 1.0, 0.0 } };
    verts[3] = .{ .pos = .{ -0.5, -0.5 }, .uv = .{ 0.0, 1.0 } };

    const idx_buf = try app.gpu.gpuMalloc(@sizeOf(u32) * 6, 16, .default);
    defer app.gpu.gpuFree(idx_buf);

    const indices: [*]u32 = @ptrCast(@alignCast(idx_buf.cpu));
    indices[0] = 0;
    indices[1] = 2;
    indices[2] = 1;
    indices[3] = 0;
    indices[4] = 1;
    indices[5] = 3;

    // ── Procedural textures ────────────────────────────
    // Generate two checkerboard patterns in CPU memory
    const pixel_count = tex_size * tex_size;
    const tex_bytes = pixel_count * 4; // RGBA8

    const pixels_a = try gpa.alloc(u8, tex_bytes);
    defer gpa.free(pixels_a);
    const pixels_b = try gpa.alloc(u8, tex_bytes);
    defer gpa.free(pixels_b);

    generateCheckerboard(pixels_a, tex_size, checker_size, .{ 255, 128, 0, 255 }, // orange
        .{ 0, 128, 255, 255 } // blue
    );
    generateCheckerboard(pixels_b, tex_size, checker_size / 2, .{ 0, 200, 100, 255 }, // green
        .{ 200, 0, 200, 255 } // magenta
    );

    // Staging buffers for texture upload
    const staging_a = try common.gpuCreate(u8, app.gpu, pixels_a, 64);
    defer app.gpu.gpuFree(staging_a);

    const staging_b = try common.gpuCreate(u8, app.gpu, pixels_b, 64);
    defer app.gpu.gpuFree(staging_b);

    // Create GPU textures
    const tex_desc: noapi.TextureDesc = .{
        .dimensions = .{ tex_size, tex_size, 1 },
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    };
    var tex_a = try noapi.Texture.create(app.gpu, tex_desc);
    defer tex_a.destroy();
    var tex_b = try noapi.Texture.create(app.gpu, tex_desc);
    defer tex_b.destroy();

    // ── Render state ───────────────────────────────
    const bindings = [_]noapi.VertexBinding{
        .{ .binding = 0, .stride = vertex_stride, .input_rate = 0 },
    };
    const attribs = [_]noapi.VertexAttribute{
        .{
            .location = 0,
            .binding = 0,
            .format = @backingInt(vk.Format.r32g32_sfloat),
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .location = 1,
            .binding = 0,
            .format = @backingInt(vk.Format.r32g32_sfloat),
            .offset = @offsetOf(Vertex, "uv"),
        },
    };

    // ── Main loop ────────────────────────────────
    var textures_uploaded = false;
    var fade: f32 = 0;
    var timer = common.FrameTimer.init();

    while (true) {
        // Event handling
        var should_close = false;
        while (sdl3.events.poll()) |ev| {
            switch (ev) {
                .quit => should_close = true,
                .window_close_requested => |we| {
                    if (we.id == win_id) should_close = true;
                },
                .key_down => |ke| {
                    if (ke.key == .escape) should_close = true;
                },
                .window_resized => |we| {
                    if (we.id == win_id) app.surf.notifyResize(.{
                        .width = @intCast(we.width),
                        .height = @intCast(we.height),
                    });
                },
                else => {},
            }
        }
        if (should_close) break;

        const schedule = app.surf.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };

        const surface_size = app.surf.surfaceSize();
        if (surface_size.width == 0 or surface_size.height == 0) {
            sdl3.timer.delayMilliseconds(16);
            continue;
        }

        var cmd = app.surf.commandsBegin();

        // Upload textures on first frame
        if (!textures_uploaded) {
            const region: noapi.TextureRegion = .{
                .size = .{ tex_size, tex_size, 1 },
            };
            cmd.copyToTexture(tex_a, staging_a, region);
            cmd.copyToTexture(tex_b, staging_b, region);
            cmd.barrier(.{ .transfer = true }, .{ .fragment = true }, .{});
            textures_uploaded = true;
        }

        // Animate fade
        fade += 0.02;
        if (fade > 1.0) fade = 0;

        // Render
        const sc = app.surf.currentImage();
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = .{ 0.3, 0.3, 0.3, 1.0 } },
        }, .render_area_size = .{ surface_size.width, surface_size.height } });

        cmd.setShaders(vert_shader, frag_shader);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.setVertexInput(&bindings, &attribs);
        cmd.bindVertexBuffer(0, vert_buf, 0);

        // Bind textures via new high-level API
        cmd.bindTexture(0, tex_a.handle, .{ .min_filter = .linear, .mag_filter = .linear, .mip_filter = .linear });
        cmd.bindTexture(1, tex_b.handle, .{ .min_filter = .linear, .mag_filter = .linear, .mip_filter = .linear });

        // Pack fragment data into push constants:
        //   frag_data: tex_a(u32) | tex_b(u32 << 32)
        //   indirect:  sampler_idx(u32) | fade(f32 bitcast << 32)
        const fade_bits: u32 = @bitCast(fade);
        const frag_data: u64 = (@as(u64, 1) << 32) | 0; // tex_b=1, tex_a=0
        const indirect: u64 = (@as(u64, fade_bits) << 32) | 0; // sampler=0
        const push: noapi.PushData = .{
            .vert_data = 0,
            .frag_data = frag_data,
            .indirect = indirect,
        };
        cmd.draw(push, 6, 1);

        cmd.endRendering();
        cmd.deinitTexHeap();

        _ = try app.surf.endFrame(.{ .blit_to_swapchain = true });

        timer.report();
        if (schedule.next_vblank_us > 1000) {
            try std.Io.sleep(io, .fromMicroseconds(schedule.next_vblank_us - 1000), .awake);
        }
    }

    try app.gpu.waitIdle();
}

fn generateCheckerboard(pixels: []u8, grid_size: u32, block_size: u32, color_a: [4]u8, color_b: [4]u8) void {
    for (0..grid_size) |y| {
        for (0..grid_size) |x| {
            const cx = @divTrunc(x, block_size);
            const cy = @divTrunc(y, block_size);
            const is_a = (cx + cy) % 2 == 0;
            const color = if (is_a) color_a else color_b;
            const idx = (y * grid_size + x) * 4;
            pixels[idx + 0] = color[0];
            pixels[idx + 1] = color[1];
            pixels[idx + 2] = color[2];
            pixels[idx + 3] = color[3];
        }
    }
}

var win_id: u32 = 0;
