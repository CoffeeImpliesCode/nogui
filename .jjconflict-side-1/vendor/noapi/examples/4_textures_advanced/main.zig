//! 3D textures advanced example — procedural cloud volume with FBM noise.
//! Demonstrates 3D texture creation, upload, and volume raymarching.
//! No external assets required.

const std = @import("std");
const common = @import("common");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const DescriptorPool = noapi.DescriptorPool;
pub const tracy_impl = common.tracy_impl;
pub const tracy = common.tracy;
pub const tracy_options = common.tracy_options;

const volume_res: u32 = 128;
const window_width: u32 = 1000;
const window_height: u32 = 1000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var app = try common.App.init("noapi textures_advanced", gpa, io, window_width, window_height, 2, false);
    defer app.deinit();
    try app.sdl_win.show();

    // ── Shaders ────────────────────────────────
    const cloud_vert = try noapi.Shader.createFromPath(
        gpa,
        io,
        app.gpu,
        "shaders/cloud_vert.spv",
        .vertex,
        "main",
        "cloud_vert",
    );
    defer cloud_vert.destroy();
    const cloud_frag = try noapi.Shader.createFromPath(
        gpa,
        io,
        app.gpu,
        "shaders/cloud_frag.spv",
        .fragment,
        "main",
        "cloud_frag",
    );
    defer cloud_frag.destroy();

    // ── 3D cloud texture ─────────────────────────────
    // Generate procedural FBM noise volume on CPU
    const volume_bytes = volume_res * volume_res * volume_res;
    const cloud_data = try gpa.alloc(u8, volume_bytes);
    defer gpa.free(cloud_data);
    generateCloudVolume(cloud_data);

    // Create 3D texture on GPU
    var cloud_tex = try noapi.Texture.OwnedTexture.allocAndCreate(app.gpu, .{
        .type = .@"3d",
        .dimensions = .{ volume_res, volume_res, volume_res },
        .format = .r8_unorm,
        .usage = .{ .sampled = true },
    });
    defer cloud_tex.deinit();

    // Upload cloud data via staging buffer
    {
        const staging = try common.gpuCreate(u8, app.gpu, cloud_data, 16);
        defer app.gpu.gpuFree(staging);

        var cmd = try app.gpu.commandsBegin();
        cmd.copyToTexture(cloud_tex.texture, staging, .{
            .size = .{ volume_res, volume_res, volume_res },
            .layer_count = 1,
        });
        cmd.barrier(.{ .transfer = true }, .{ .fragment = true }, .{});
        // Submit and wait for upload to complete
        // queueSubmit internally ends the CB, then submits
        try app.gpu.queueSubmit(&.{cmd});
        try app.gpu.waitIdle();
    }

    // ── Descriptor pool ─────────────────────────────
    var pool = try DescriptorPool.init(app.gpu, 1, 0, 1);
    defer pool.deinit();

    _ = pool.allocTexture(cloud_tex.texture.handle, app.gpu.samplerDescriptor(.{
        .min_filter = .linear,
        .mag_filter = .linear,
        .mip_filter = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
    }), .@"3d");

    // ── Render loop ───────────────────────────────
    const win_id = try app.sdl_win.getId();
    var should_close = false;
    var sem_val: u64 = 0;
    const test_sem = try app.gpu.semaphoreCreate(0);
    defer app.gpu.semaphoreDestroy(test_sem);
    var timer = common.FrameTimer.init();

    while (!should_close) {
        // Process events
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

        timer.tick();
        const schedule = app.surf.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };

        const surface_size = app.surf.surfaceSize();
        var cmd = app.surf.commandsBegin();

        const sc = app.surf.currentImage();
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = .{ 0.05, 0.05, 0.1, 1.0 } },
        }, .render_area_size = .{ surface_size.width, surface_size.height } });

        // Orbit camera around the cloud (Z-up: XY horizontal, Z vertical)
        const radius: f32 = 2.5;
        const cam_x = @sin(timer.elapsed * 0.3) * radius;
        const cam_y = @cos(timer.elapsed * 0.3) * radius;
        const cam_z = @sin(timer.elapsed * 0.15) * 0.5;

        // Pack push constant data: cloud_texture=0, cloud_sampler=0, camera_pos.
        // The legacy cloud shaders read a 24-byte block {u32,u32,f32,f32,f32,u32} at
        // offsets 0-23; map it onto the new 48-byte PushData by byte offset:
        //   0-7:  cloud_texture/cloud_sampler -> vert_data (both 0: bindless slots)
        //   8-15: camera_x, camera_y         -> frag_data
        //   16-23: camera_z, _pad             -> indirect
        const push: noapi.PushData = .{
            .vert_data = 0,
            .frag_data = (@as(u64, @as(u32, @bitCast(cam_y))) << 32) | @as(u64, @as(u32, @bitCast(cam_x))),
            .indirect = @as(u64, @as(u32, @bitCast(cam_z))),
        };

        cmd.setViewport(.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(surface_size.width),
            .height = @floatFromInt(surface_size.height),
        });
        cmd.setScissor(.{ .x = 0, .y = 0, .width = surface_size.width, .height = surface_size.height });
        cmd.setShaders(cloud_vert, cloud_frag);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .back });
        cmd.setBlendState(.{
            .enable = true,
            .color_op = .add,
            .src_color_factor = .src_alpha,
            .dst_color_factor = .one_minus_src_alpha,
            .alpha_op = .add,
            .src_alpha_factor = .one,
            .dst_alpha_factor = .one_minus_src_alpha,
        });
        cmd.bindDescriptorSets(pool.heap);
        cmd.draw(push, 36, 1);

        cmd.endRendering();

        sem_val += 1;
        cmd.addWaitSemaphore(app.surf.index, test_sem, sem_val - 1);
        cmd.addSignalSemaphore(app.surf.index, test_sem, sem_val);

        _ = try app.surf.endFrame(.{ .blit_to_swapchain = true });

        timer.report();
        if (schedule.next_vblank_us > 1000) try std.Io.sleep(io, .fromMicroseconds(schedule.next_vblank_us - 1000), .awake);
    }

    try app.gpu.waitIdle();
}

/// Generate a 128×128×128 cloud volume using FBM value noise.
fn generateCloudVolume(data: []u8) void {
    const size: usize = @intCast(volume_res);
    const size_f: f32 = @floatFromInt(size - 1);
    const inv: f32 = 1.0 / size_f;

    for (0..size) |z| {
        for (0..size) |y| {
            for (0..size) |x| {
                const x_f: f32 = @floatFromInt(x);
                const y_f: f32 = @floatFromInt(y);
                const z_f: f32 = @floatFromInt(z);
                const nx = x_f * inv;
                const ny = y_f * inv;
                const nz = z_f * inv;

                // FBM noise shaped into cloud density
                const n = fbm(nx * 3.0, ny * 3.0, nz * 3.0);
                const density = @max(0.0, @min(1.0, (n - 0.35) * 1.8));

                const idx = x + y * size + z * size * size;
                data[idx] = @intFromFloat(density * 255.0);
            }
        }
    }
}

fn smooth(t: f32) f32 {
    return 3.0 * t * t - 2.0 * t * t * t;
}

fn hash3(x: i32, y: i32, z: i32) f32 {
    const x_u32: u32 = @intCast(x);
    const y_u32: u32 = @intCast(y);
    const z_u32: u32 = @intCast(z);
    var h: u32 = x_u32 *% 73856093 ^ y_u32 *% 19349663 ^ z_u32 *% 83492791;
    h ^= h >> 13;
    h *%= 0x85ebca6b;
    h ^= h >> 16;
    const h_f: f32 = @floatFromInt(h);
    const max_f: f32 = @floatFromInt(std.math.maxInt(u32));
    return h_f / max_f;
}

fn valueNoise(x: f32, y: f32, z: f32) f32 {
    const xi: i32 = @intFromFloat(@floor(x));
    const yi: i32 = @intFromFloat(@floor(y));
    const zi: i32 = @intFromFloat(@floor(z));

    const xi_f: f32 = @floatFromInt(xi);
    const yi_f: f32 = @floatFromInt(yi);
    const zi_f: f32 = @floatFromInt(zi);
    const xf = smooth(x - xi_f);
    const yf = smooth(y - yi_f);
    const zf = smooth(z - zi_f);

    const c000 = hash3(xi + 0, yi + 0, zi + 0);
    const c100 = hash3(xi + 1, yi + 0, zi + 0);
    const c010 = hash3(xi + 0, yi + 1, zi + 0);
    const c110 = hash3(xi + 1, yi + 1, zi + 0);
    const c001 = hash3(xi + 0, yi + 0, zi + 1);
    const c101 = hash3(xi + 1, yi + 0, zi + 1);
    const c011 = hash3(xi + 0, yi + 1, zi + 1);
    const c111 = hash3(xi + 1, yi + 1, zi + 1);

    const x00 = lerp(c000, c100, xf);
    const x10 = lerp(c010, c110, xf);
    const x01 = lerp(c001, c101, xf);
    const x11 = lerp(c011, c111, xf);

    const y0 = lerp(x00, x10, yf);
    const y1 = lerp(x01, x11, yf);

    return lerp(y0, y1, zf);
}

fn fbm(x: f32, y: f32, z: f32) f32 {
    var v: f32 = 0.0;
    var amp: f32 = 0.5;
    var freq: f32 = 1.0;
    const damping: f32 = 0.6;
    const freq_growth: f32 = 2.3;

    comptime var i = 0;
    inline while (i < 4) : (i += 1) {
        v += amp * valueNoise(x * freq, y * freq, z * freq);
        amp *= damping;
        freq *= freq_growth;
    }

    return v;
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}
