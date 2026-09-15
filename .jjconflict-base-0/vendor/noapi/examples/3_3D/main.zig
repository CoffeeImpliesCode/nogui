//! 3D cube demo — first-person camera with WASD + mouse look.
//! Port of the upstream 3_3D example, simplified from Sponza glTF to a colored cube.

const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const common = @import("common");
pub const tracy_impl = common.tracy_impl;
pub const tracy = common.tracy;
pub const tracy_options = common.tracy_options;

const win_width: u32 = 1000;
const win_height: u32 = 1000;
const frames_in_flight: u5 = 3;

// Cube geometry: 6 faces × 4 verts = 24 verts, 6 faces × 6 indices = 36 indices.
const cube_verts: u32 = 24;
const cube_indices: u32 = 36;

// Per-frame data buffer layout (matches shader struct).
// std430 alignment: vec4 = 16, mat4 = 16 (column-major).
const PerFrameData = extern struct {
    positions: [cube_verts][4]f32 align(16),
    colors: [cube_verts][4]f32 align(16),
    model_to_world: [16]f32 align(16),
    world_to_view: [16]f32 align(16),
    view_to_proj: [16]f32 align(16),
};

// Cube vertex positions (centered at origin, side length 1).
const cube_positions: [cube_verts][4]f32 = .{
    // Front (z = +0.5)
    .{ -0.5, -0.5, 0.5, 1.0 },
    .{ 0.5, -0.5, 0.5, 1.0 },
    .{ 0.5, 0.5, 0.5, 1.0 },
    .{ -0.5, 0.5, 0.5, 1.0 },
    // Back (z = -0.5)
    .{ 0.5, -0.5, -0.5, 1.0 },
    .{ -0.5, -0.5, -0.5, 1.0 },
    .{ -0.5, 0.5, -0.5, 1.0 },
    .{ 0.5, 0.5, -0.5, 1.0 },
    // Top (y = +0.5)
    .{ -0.5, 0.5, 0.5, 1.0 },
    .{ 0.5, 0.5, 0.5, 1.0 },
    .{ 0.5, 0.5, -0.5, 1.0 },
    .{ -0.5, 0.5, -0.5, 1.0 },
    // Bottom (y = -0.5)
    .{ -0.5, -0.5, -0.5, 1.0 },
    .{ 0.5, -0.5, -0.5, 1.0 },
    .{ 0.5, -0.5, 0.5, 1.0 },
    .{ -0.5, -0.5, 0.5, 1.0 },
    // Right (x = +0.5)
    .{ 0.5, -0.5, 0.5, 1.0 },
    .{ 0.5, -0.5, -0.5, 1.0 },
    .{ 0.5, 0.5, -0.5, 1.0 },
    .{ 0.5, 0.5, 0.5, 1.0 },
    // Left (x = -0.5)
    .{ -0.5, -0.5, -0.5, 1.0 },
    .{ -0.5, -0.5, 0.5, 1.0 },
    .{ -0.5, 0.5, 0.5, 1.0 },
    .{ -0.5, 0.5, -0.5, 1.0 },
};

// Cube vertex colors (one per face, repeated 4×).
const cube_colors: [cube_verts][4]f32 = .{
    // Front: red
    .{ 1.0, 0.0, 0.0, 1.0 }, .{ 1.0, 0.0, 0.0, 1.0 }, .{ 1.0, 0.0, 0.0, 1.0 }, .{ 1.0, 0.0, 0.0, 1.0 },
    // Back: green
    .{ 0.0, 1.0, 0.0, 1.0 }, .{ 0.0, 1.0, 0.0, 1.0 }, .{ 0.0, 1.0, 0.0, 1.0 }, .{ 0.0, 1.0, 0.0, 1.0 },
    // Top: blue
    .{ 0.0, 0.0, 1.0, 1.0 }, .{ 0.0, 0.0, 1.0, 1.0 }, .{ 0.0, 0.0, 1.0, 1.0 }, .{ 0.0, 0.0, 1.0, 1.0 },
    // Bottom: yellow
    .{ 1.0, 1.0, 0.0, 1.0 }, .{ 1.0, 1.0, 0.0, 1.0 }, .{ 1.0, 1.0, 0.0, 1.0 }, .{ 1.0, 1.0, 0.0, 1.0 },
    // Right: magenta
    .{ 1.0, 0.0, 1.0, 1.0 }, .{ 1.0, 0.0, 1.0, 1.0 }, .{ 1.0, 0.0, 1.0, 1.0 }, .{ 1.0, 0.0, 1.0, 1.0 },
    // Left: cyan
    .{ 0.0, 1.0, 1.0, 1.0 }, .{ 0.0, 1.0, 1.0, 1.0 }, .{ 0.0, 1.0, 1.0, 1.0 }, .{ 0.0, 1.0, 1.0, 1.0 },
};

// Cube index buffer (2 triangles per face, 6 faces).
const cube_index_data: [cube_indices]u32 = .{
    0, 1, 2, 0, 2, 3, // front
    4, 5, 6, 4, 6, 7, // back
    8, 9, 10, 8, 10, 11, // top
    12, 13, 14, 12, 14, 15, // bottom
    16, 17, 18, 16, 18, 19, // right
    20, 21, 22, 20, 22, 23, // left
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var app = try common.App.init("3D Cube", gpa, io, win_width, win_height, @intCast(frames_in_flight), true);
    app.surf.gpu = app.gpu; // fix dangling ptr: surf.gpu captured &local_gpu before App reached final stack addr
    defer app.deinit();
    try app.sdl_win.show();
    const win_id = try app.sdl_win.getId();

    // ── Shaders ─────────────────────────────
    const vert_shader = try noapi.Shader.createFromPath(
        gpa,
        io,
        app.gpu,
        "shaders/cube_vert.spv",
        .vertex,
        "main",
        "cube_vert",
    );
    defer vert_shader.destroy();
    const frag_shader = try noapi.Shader.createFromPath(
        gpa,
        io,
        app.gpu,
        "shaders/cube_frag.spv",
        .fragment,
        "main",
        "cube_frag",
    );
    defer frag_shader.destroy();

    // ── Depth texture ────────────────────────────
    var depth_handle = try app.gpu.textureCreate(.{
        .dimensions = .{ win_width, win_height, 1 },
        .format = .d32_float,
        .usage = .{ .sampled = false, .depth_stencil_attachment = true },
    });
    defer app.gpu.textureDestroy(depth_handle);
    var depth_size = [2]u32{ win_width, win_height };

    // ── GPU buffers ─────────────────────────────
    // Per-frame data buffer (positions + colors + matrices).
    const frame_data_size = @sizeOf(PerFrameData);
    const frame_data_buf = try app.gpu.gpuMalloc(frame_data_size, 64, .default);
    defer app.gpu.gpuFree(frame_data_buf);

    // Index buffer.
    const idx_buf_size = @sizeOf(u32) * cube_indices;
    const idx_buf = try app.gpu.gpuMalloc(idx_buf_size, 64, .default);
    defer app.gpu.gpuFree(idx_buf);

    // Fill index buffer.
    @memcpy(idx_buf.cpu[0..idx_buf_size], std.mem.sliceAsBytes(&cube_index_data));

    // ── Semaphore for frame pacing ─────────────────────────
    const frame_sem = try app.gpu.semaphoreCreate(0);
    defer app.gpu.semaphoreDestroy(frame_sem);

    // ── Camera state ────────────────────────────
    var cam_pos: [3]f32 = .{ -1, 0, 0 };
    var cam_yaw: f32 = 0;
    var cam_pitch: f32 = 0;
    var mouse_dx: f32 = 0;
    var mouse_dy: f32 = 0;
    var right_click_pressed = false;

    // ── Frame pacing ────────────────────────────
    var frame_counter: u64 = 0;
    var timer = common.FrameTimer.initMax(1.0 / 10.0);

    // ── Main loop ──────────────────────────────
    var should_close = false;
    while (!should_close) {
        // ── Events ─────────────────────────────
        while (sdl3.events.poll()) |ev| {
            switch (ev) {
                .quit => should_close = true,
                .window_close_requested => |we| {
                    if (we.id == win_id) should_close = true;
                },
                .key_down => |ke| {
                    if (ke.key == .escape) should_close = true;
                },
                .mouse_button_down => |me| {
                    if (me.button == .right) {
                        right_click_pressed = true;
                        try sdl3.mouse.setWindowRelativeMode(app.sdl_win, true);
                    }
                },
                .mouse_button_up => |me| {
                    if (me.button == .right) {
                        right_click_pressed = false;
                        try sdl3.mouse.setWindowRelativeMode(app.sdl_win, false);
                    }
                },
                .mouse_motion => |mm| {
                    if (right_click_pressed) {
                        mouse_dx += mm.x_rel;
                        mouse_dy -= mm.y_rel;
                    }
                },
                .window_resized => |we| {
                    if (we.id == win_id) {
                        app.surf.notifyResize(.{ .width = @intCast(we.width), .height = @intCast(we.height) });
                    }
                },
                else => {},
            }
        }

        // ── Begin frame ───────────────────────────
        _ = app.surf.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };

        const sz = app.surf.surfaceSize();
        if (sz.width == 0 or sz.height == 0) {
            _ = try app.surf.endFrame(.{ .blit_to_swapchain = true });
            continue;
        }
        const surf_w = sz.width;
        const surf_h = sz.height;

        // ── Resize depth texture if needed ─────────────────
        if (depth_size[0] != surf_w or depth_size[1] != surf_h) {
            try app.gpu.waitIdle();
            app.gpu.textureDestroy(depth_handle);
            depth_handle = try app.gpu.textureCreate(.{
                .dimensions = .{ surf_w, surf_h, 1 },
                .format = .d32_float,
                .usage = .{ .sampled = false, .depth_stencil_attachment = true },
            });
            depth_size = .{ surf_w, surf_h };
        }

        timer.tick();
        // ── Camera update ─────────────────────────
        const mouse_sens: f32 = 0.002;
        if (right_click_pressed) {
            cam_yaw += mouse_dx * mouse_sens;
            cam_pitch += mouse_dy * mouse_sens;
            cam_pitch = std.math.clamp(cam_pitch, -std.math.pi / 2.0 + 0.01, std.math.pi / 2.0 - 0.01);
        }
        mouse_dx = 0;
        mouse_dy = 0;

        // Keyboard movement: X=forward, Y=left, Z=up.
        const key_state = sdl3.keyboard.getState();
        var move_dir: [3]f32 = .{ 0, 0, 0 };
        if (right_click_pressed) {
            if (key_state[@intFromEnum(sdl3.Scancode.w)]) move_dir[0] += 1; // forward  +X
            if (key_state[@intFromEnum(sdl3.Scancode.s)]) move_dir[0] -= 1; // backward -X
            if (key_state[@intFromEnum(sdl3.Scancode.a)]) move_dir[1] += 1; // left     +Y
            if (key_state[@intFromEnum(sdl3.Scancode.d)]) move_dir[1] -= 1; // right    -Y
            if (key_state[@intFromEnum(sdl3.Scancode.e)]) move_dir[2] += 1; // up       +Z
            if (key_state[@intFromEnum(sdl3.Scancode.q)]) move_dir[2] -= 1; // down     -Z
        }

        // Normalize horizontal movement (XY plane).
        const horiz_len = @sqrt(move_dir[0] * move_dir[0] + move_dir[1] * move_dir[1]);
        if (horiz_len > 1.0) {
            move_dir[0] /= horiz_len;
            move_dir[1] /= horiz_len;
        }
        if (@abs(move_dir[2]) > 1.0) move_dir[2] = std.math.sign(move_dir[2]);

        // Rotate movement by camera yaw (around Z axis).
        const yaw_cos = @cos(cam_yaw);
        const yaw_sin = @sin(cam_yaw);
        const world_move: [3]f32 = .{
            move_dir[0] * yaw_cos - move_dir[1] * yaw_sin,
            move_dir[0] * yaw_sin + move_dir[1] * yaw_cos,
            move_dir[2],
        };

        const move_speed: f32 = 4.0;
        cam_pos[0] += world_move[0] * move_speed * timer.delta;
        cam_pos[1] += world_move[1] * move_speed * timer.delta;
        cam_pos[2] += world_move[2] * move_speed * timer.delta;

        // ── Build view matrix ─────────────────────
        // Camera forward direction from yaw/pitch.
        const fwd: [3]f32 = .{
            @cos(cam_yaw) * @cos(cam_pitch),
            @sin(cam_yaw) * @cos(cam_pitch),
            @sin(cam_pitch),
        };
        const world_up: [3]f32 = .{ 0, 0, 1 };
        const right = common.cross(fwd, world_up);
        const up = common.cross(right, fwd);

        // View matrix: inverse of camera transform.
        // Column-major 4x4.
        var view: [16]f32 = .{
            right[0],                    up[0],                    -fwd[0],                  0,
            right[1],                    up[1],                    -fwd[1],                  0,
            right[2],                    up[2],                    -fwd[2],                  0,
            -common.dot(right, cam_pos), -common.dot(up, cam_pos), common.dot(fwd, cam_pos), 1,
        };

        // ── Build projection matrix ────────────────────────
        const w_f: f32 = @floatFromInt(surf_w);
        const h_f: f32 = @floatFromInt(surf_h);
        const aspect = w_f / h_f;
        const fov_y: f32 = std.math.pi / 3.0; // 60°
        const near_z: f32 = 0.1;
        const far_z: f32 = 100.0;
        var proj = common.perspective(fov_y, aspect, near_z, far_z);

        const s: f32 = 0.3;
        const model: [16]f32 = .{
            s, 0, 0, 0,
            0, s, 0, 0,
            0, 0, s, 0,
            0, 0, 0, 1,
        };

        // ── Fill per-frame data buffer ─────────────────────
        const pfd: *PerFrameData = @ptrCast(@alignCast(frame_data_buf.cpu));
        @memcpy(&pfd.positions, &cube_positions);
        @memcpy(&pfd.colors, &cube_colors);
        @memcpy(&pfd.model_to_world, &model);
        @memcpy(&pfd.world_to_view, &view);
        @memcpy(&pfd.view_to_proj, &proj);

        // ── Render ─────────────────────────────
        const sc = app.surf.currentImage();
        var cmd = app.surf.commandsBegin();

        cmd.beginZone(.{ .name = "cube render", .src = @src(), .color = .cornflower_blue });
        cmd.beginRendering(.{
            .color_attachments = &.{
                .{
                    .texture = sc,
                    .load_op = .clear,
                    .store_op = .store,
                    .clear_color = .{ 0.2, 0.2, 0.3, 1.0 },
                },
            },
            .render_area_size = .{ surf_w, surf_h },
            .depth_attachment = .{
                .texture = depth_handle,
                .load_op = .clear,
                .store_op = .store,
                .clear_depth = 1.0,
            },
        });

        cmd.setViewport(.{ .x = 0, .y = 0, .width = @floatFromInt(surf_w), .height = @floatFromInt(surf_h) });
        cmd.setScissor(.{ .x = 0, .y = 0, .width = surf_w, .height = surf_h });
        cmd.setShaders(vert_shader, frag_shader);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.setDepthState(.{ .mode = .{ .read = true, .write = true }, .compare = .less_equal });

        // Draw indexed cube: pass buffer device address via vert_data push constant.
        cmd.beginZone(.{ .name = "draw cube", .src = @src(), .color = .orange });
        cmd.drawIndexed(.{ .vert_data = frame_data_buf.gpu }, idx_buf, cube_indices, 1, 0, 0);
        cmd.endZone();

        cmd.endRendering();
        cmd.endZone();

        frame_counter += 1;
        cmd.addSignalSemaphore(app.surf.index, frame_sem, frame_counter);

        _ = try app.surf.endFrame(.{ .blit_to_swapchain = true });

        // Frame pacing: wait if GPU is N frames ahead.
        if (frame_counter >= frames_in_flight) {
            try app.gpu.semaphoreWait(frame_sem, frame_counter - frames_in_flight + 1);
        }

        timer.report();
    }

    try app.gpu.waitIdle();
}
