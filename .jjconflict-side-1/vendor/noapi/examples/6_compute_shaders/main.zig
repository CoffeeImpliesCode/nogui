//! 6_compute_shaders — compute shader + indirect dispatch demo.
//! Port of the upstream 6_compute_shaders Odin example.
//! Demonstrates compute shaders writing to a texture, then rendering it
//! as a fullscreen quad (shadertoy-style). Supports both direct dispatch
//! and indirect dispatch via GPU buffer.

const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const common = @import("common");
const DescriptorPool = noapi.DescriptorPool;
pub const tracy_impl = common.tracy_impl;
pub const tracy = common.tracy;
pub const tracy_options = common.tracy_options;

const start_width = 1000;
const start_height = 1000;
const frames_in_flight = 3;
const use_indirect = true;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var app = try common.App.init("6_compute_shaders", gpa, io, start_width, start_height, frames_in_flight, true);
    defer app.deinit();
    try app.sdl_win.show();
    const win_id = try app.sdl_win.getId();

    // ── Shaders ────────────────────────────────
    const comp_shader = try noapi.Shader.createFromPath(
        gpa,
        io,
        app.gpu,
        "shaders/compute_comp.spv",
        .compute,
        "main",
        "compute",
    );
    defer comp_shader.destroy();
    const vert_shader = try noapi.Shader.createFromPath(
        gpa,
        io,
        app.gpu,
        "shaders/fullscreen_quad_vert.spv",
        .vertex,
        "main",
        "fullscreen_quad",
    );
    defer vert_shader.destroy();
    const frag_shader = try noapi.Shader.createFromPath(
        gpa,
        io,
        app.gpu,
        "shaders/tex_sample_frag.spv",
        .fragment,
        "main",
        "tex_sample",
    );
    defer frag_shader.destroy();

    // ── Descriptor pool ──────────────────────────────
    var pool = try DescriptorPool.init(app.gpu, 1, 1, 1);
    defer pool.deinit();

    // ── Compute output texture (storage + sampled) ─────────
    var surface_size = app.surf.surfaceSize();
    var output_tex = try app.gpu.textureCreate(.{
        .dimensions = .{ surface_size.width, surface_size.height, 1 },
        .format = .rgba8_unorm,
        .usage = .{ .storage = true, .sampled = true },
    });
    defer app.gpu.textureDestroy(output_tex);

    // ── Allocate descriptor slots ──────────────────────────
    var tex_idx = pool.allocTexture(output_tex, app.gpu.samplerDescriptor(.{}), .@"2d");
    var tex_rw_idx = pool.allocTextureRw(output_tex, .@"2d");

    // ── Indirect dispatch buffer ───────────────────────────
    const indirect_buf = try app.gpu.gpuMalloc(@sizeOf(noapi.DispatchIndirectCommand), 4, .default);
    defer app.gpu.gpuFree(indirect_buf);

    // ── Frame pacing semaphore ───────────────────────────
    const frame_sem = try app.gpu.semaphoreCreate(0);
    defer app.gpu.semaphoreDestroy(frame_sem);
    var next_frame: u64 = 1;

    // ── Main loop ────────────────────────────────
    var should_close = false;
    var timer = common.FrameTimer.initMax(1.0 / 10.0);
    while (!should_close) {
        // Event handling
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

        // Skip if minimized
        const flags = app.sdl_win.getFlags();
        if (flags.minimized) {
            sdl3.timer.delayMilliseconds(16);
            continue;
        }

        // Frame pacing
        if (next_frame > frames_in_flight) {
            try app.gpu.semaphoreWait(frame_sem, next_frame - frames_in_flight);
        }

        // Begin frame (triggers swapchain recreation if resized)
        _ = app.surf.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };

        // Handle resize
        const new_size = app.surf.surfaceSize();
        if (new_size.width != surface_size.width or new_size.height != surface_size.height) {
            surface_size = new_size;
            try app.gpu.waitIdle();
            pool.freeTexture(tex_idx);
            pool.freeTextureRw(tex_rw_idx);
            app.gpu.textureDestroy(output_tex);
            output_tex = try app.gpu.textureCreate(.{
                .dimensions = .{ surface_size.width, surface_size.height, 1 },
                .format = .rgba8_unorm,
                .usage = .{ .storage = true, .sampled = true },
            });
            tex_idx = pool.allocTexture(output_tex, app.gpu.samplerDescriptor(.{}), .@"2d");
            tex_rw_idx = pool.allocTextureRw(output_tex, .@"2d");
        }

        timer.tick();

        // ── Compute dispatch ────────────────────────────
        const group_size_x: u32 = 8;
        const group_size_y: u32 = 8;
        const num_groups_x = (surface_size.width + group_size_x - 1) / group_size_x;
        const num_groups_y = (surface_size.height + group_size_y - 1) / group_size_y;

        var cmd = app.surf.commandsBegin();
        cmd.beginZone(.{ .name = "compute pass", .src = @src(), .color = .green });
        cmd.bindDescriptorSets(pool.heap);
        cmd.setComputeShader(comp_shader);

        // Push constant: the compute shader expects float time at offset 0.
        // The noapi API pushes a u64; the shader reads the first 4 bytes as float.
        const push_u32: u32 = @bitCast(timer.elapsed);
        const push_data: u64 = push_u32;

        if (use_indirect) {
            // Write indirect dispatch command to GPU-visible buffer
            const indirect_cmd: *noapi.DispatchIndirectCommand = @ptrCast(@alignCast(indirect_buf.cpu));
            indirect_cmd.* = .{
                .num_groups_x = num_groups_x,
                .num_groups_y = num_groups_y,
                .num_groups_z = 1,
            };
            cmd.beginZone(.{ .name = "dispatch indirect", .src = @src(), .color = .yellow_green });
            cmd.dispatchIndirect(push_data, indirect_buf);
            cmd.endZone();
        } else {
            cmd.beginZone(.{ .name = "dispatch", .src = @src(), .color = .yellow_green });
            cmd.dispatch(push_data, num_groups_x, num_groups_y, 1);
            cmd.endZone();
        }
        cmd.endZone(); // compute pass

        // Barrier: ensure compute shader finishes before fragment shader reads
        cmd.barrier(.{ .compute = true }, .{ .fragment = true }, .{});

        // ── Render compute output as fullscreen quad ────────
        const sc = app.surf.currentImage();
        cmd.beginZone(.{ .name = "quad draw", .src = @src(), .color = .sky_blue });
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = .{ 0, 0, 0, 1 } },
        }, .render_area_size = .{ surface_size.width, surface_size.height } });

        cmd.setShaders(vert_shader, frag_shader);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.draw(.{}, 6, 1);

        cmd.endRendering();
        cmd.endZone(); // quad draw

        // Signal semaphore and present
        cmd.addSignalSemaphore(0, frame_sem, next_frame);
        _ = try app.surf.endFrame(.{ .blit_to_swapchain = true });
        next_frame += 1;

        timer.report();
    }

    try app.gpu.waitIdle();
}
