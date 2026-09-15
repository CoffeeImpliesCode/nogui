//! Indirect triangles example.
//! Demonstrates cmdDrawIndexedIndirect and cmdDrawIndexedIndirectMulti.
//! Renders 32 animated triangles arranged in a circle using indirect draw commands.

const std = @import("std");
const common = @import("common");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const vk = noapi.vk;
pub const tracy_impl = common.tracy_impl;
pub const tracy = common.tracy;
pub const tracy_options = common.tracy_options;

const num_triangles: u32 = 32;
const window_width: u32 = 1000;
const window_height: u32 = 1000;
const frames_in_flight: u5 = 3;

// Per-draw data that follows DrawIndexedIndirectCommand in the indirect buffer.
const PerDrawData = extern struct {
    color: [3]f32,
    pos: [3]f32,
    size: f32,
};

// Full indirect draw entry: command + per-draw data.
// Must match the shader's DrawCommand struct layout.
const IndirectDraw = extern struct {
    cmd: noapi.DrawIndexedIndirectCommand,
    data: PerDrawData,
};

// Vertex data struct: pointer to vertex array (matches shader's VertexData).
const VertexData = extern struct {
    verts: u64,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var app = try common.App.init("Indirect Triangles", gpa, io, window_width, window_height, frames_in_flight, false);
    defer app.deinit();
    try app.sdl_win.show();

    // ── Shaders ────────────────────────────────
    const vert_shader = try noapi.Shader.createFromPath(
        gpa,
        io,
        app.gpu,
        "shaders/indirect_tri_vert.spv",
        .vertex,
        "main",
        "indirect_tri_vert",
    );
    defer vert_shader.destroy();
    const frag_shader = try noapi.Shader.createFromPath(
        gpa,
        io,
        app.gpu,
        "shaders/indirect_tri_frag.spv",
        .fragment,
        "main",
        "indirect_tri_frag",
    );
    defer frag_shader.destroy();

    // ── Vertex buffer (single triangle shared by all draws) ─
    const vert_buf = try app.gpu.gpuMalloc(@sizeOf([3]f32) * 3, 16, .default);
    defer app.gpu.gpuFree(vert_buf);
    const verts: [*][3]f32 = @ptrCast(@alignCast(vert_buf.cpu));
    verts[0] = .{ -0.5, 0.5, 0.0 };
    verts[1] = .{ 0.0, -0.5, 0.0 };
    verts[2] = .{ 0.5, 0.5, 0.0 };

    // ── Vertex data struct (pointer to vertex array) ───────
    const vert_data_buf = try app.gpu.gpuMalloc(@sizeOf(VertexData), 8, .default);
    defer app.gpu.gpuFree(vert_data_buf);
    const vert_data_ptr: *VertexData = @ptrCast(@alignCast(vert_data_buf.cpu));
    vert_data_ptr.* = .{ .verts = vert_buf.gpu };

    // ── Index buffer ──────────────────────────────
    const idx_buf = try app.gpu.gpuMalloc(@sizeOf(u32) * 3, 4, .default);
    defer app.gpu.gpuFree(idx_buf);
    const indices: [*]u32 = @ptrCast(@alignCast(idx_buf.cpu));
    indices[0] = 0;
    indices[1] = 2;
    indices[2] = 1;

    // ── Indirect data buffer (32 draws with per-draw data) ─
    const indirect_buf = try app.gpu.gpuMalloc(@sizeOf(IndirectDraw) * num_triangles, 16, .default);
    defer app.gpu.gpuFree(indirect_buf);
    const indirect_draws: [*]IndirectDraw = @ptrCast(@alignCast(indirect_buf.cpu));

    // ── Count buffer (separate buffer for draw count) ──────
    const draw_count_buf = try app.gpu.gpuMalloc(4, 4, .default);
    defer app.gpu.gpuFree(draw_count_buf);
    @as(*u32, @ptrCast(@alignCast(draw_count_buf.cpu))).* = num_triangles;

    const circle_radius: f32 = 0.6;
    for (0..num_triangles) |i| {
        const angle: f32 = @floatCast(@as(f64, @floatFromInt(i)) / @as(f64, num_triangles) * std.math.pi * 2.0);
        const x = @cos(angle) * circle_radius;
        const y = @sin(angle) * circle_radius;

        // HSL → RGB
        const hue = angle / (std.math.pi * 2.0);
        const rgb = hslToRgb(hue, 1.0, 0.5);

        indirect_draws[i] = .{
            .cmd = .{
                .index_count = 3,
                .instance_count = 1,
                .first_index = 0,
                .vertex_offset = 0,
                .first_instance = 0,
            },
            .data = .{
                .color = rgb,
                .pos = .{ x, y, 0.0 },
                .size = 0.1,
            },
        };
    }

    // ── Count buffer (for multi-draw) ──────────────────────
    const count_buf = try app.gpu.gpuMalloc(@sizeOf(u32), 4, .default);
    defer app.gpu.gpuFree(count_buf);
    const count_ptr: *u32 = @ptrCast(@alignCast(count_buf.cpu));
    count_ptr.* = num_triangles;

    // ── Semaphore for frame pacing ─────────────────────────
    const frame_sem = try app.gpu.semaphoreCreate(0);
    defer app.gpu.semaphoreDestroy(frame_sem);

    // ── Main loop ───────────────────────────────
    var next_frame: u64 = 1;
    var timer = common.FrameTimer.init();
    var should_close = false;

    while (!should_close) {
        // Handle events
        while (sdl3.events.poll()) |ev| {
            switch (ev) {
                .quit => should_close = true,
                .window_close_requested => |we| {
                    if (we.id == try app.sdl_win.getId()) should_close = true;
                },
                .key_down => |ke| {
                    if (ke.key == .escape) should_close = true;
                },
                .window_resized => |we| {
                    app.surf.notifyResize(.{ .width = @intCast(we.width), .height = @intCast(we.height) });
                },
                else => {},
            }
        }
        if (should_close) break;

        // Frame pacing
        if (next_frame > frames_in_flight) {
            try app.gpu.semaphoreWait(frame_sem, next_frame - frames_in_flight);
        }

        // Begin frame
        const schedule = app.surf.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };
        _ = schedule;

        timer.tick();
        const surface_size = app.surf.surfaceSize();

        // Animate: rotate triangles around the circle
        const rotation = timer.elapsed * 0.5;
        for (0..num_triangles) |i| {
            const angle: f32 = @floatCast(
                @as(f64, @floatFromInt(i)) / @as(f64, num_triangles) * std.math.pi * 2.0 + @as(f64, rotation),
            );
            const x = @cos(angle) * circle_radius;
            const y = @sin(angle) * circle_radius;
            indirect_draws[i].data.pos = .{ x, y, 0.0 };
        }

        // Record commands
        var cmd = app.surf.commandsBegin();
        const sc = app.surf.currentImage();

        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = .{
                0.1 + @sin(timer.elapsed * 0.5) * 0.05,
                0.1 + @cos(timer.elapsed * 0.7) * 0.05,
                0.2 + @sin(timer.elapsed * 0.3) * 0.05,
                1.0,
            } },
        }, .render_area_size = .{ surface_size.width, surface_size.height } });

        cmd.setShaders(vert_shader, frag_shader);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });

        // Set vertex input: one binding with position (vec3)
        cmd.setVertexInput(&.{.{ .binding = 0, .stride = @sizeOf([3]f32), .input_rate = 0 }}, &.{
            .{ .location = 0, .binding = 0, .format = @intFromEnum(vk.Format.r32g32b32_sfloat), .offset = 0 },
        });
        cmd.bindVertexBuffer(0, vert_buf, 0);

        // Push constants: vert_data = pointer to VertexData, indirect = pointer to indirect buffer
        const push: noapi.PushData = .{
            .vert_data = vert_data_buf.gpu,
            .indirect = indirect_buf.gpu,
        };

        // Draw 32 triangles using indirect multi-draw
        // stride = @sizeOf(IndirectDraw) so the GPU skips per-draw data between commands
        cmd.drawIndexedIndirectMulti(
            push,
            idx_buf,
            indirect_buf,
            @sizeOf(IndirectDraw),
            draw_count_buf,
            0,
            num_triangles,
        );

        cmd.endRendering();

        // Signal semaphore and present
        cmd.addSignalSemaphore(app.surf.index, frame_sem, next_frame);
        _ = try app.surf.endFrame(.{ .blit_to_swapchain = true });
        next_frame += 1;

        timer.report();
    }

    try app.gpu.waitIdle();
}

// Convert HSL to RGB (hue: 0-1, saturation: 0-1, lightness: 0-1)
fn hslToRgb(h: f32, s: f32, l: f32) [3]f32 {
    const c = (1.0 - @abs(2.0 * l - 1.0)) * s;
    const x = c * (1.0 - @abs(@mod(h * 6.0, 2.0) - 1.0));
    const m = l - c / 2.0;

    const rgb = if (h < 1.0 / 6.0)
        .{ c, x, 0.0 }
    else if (h < 2.0 / 6.0)
        .{ x, c, 0.0 }
    else if (h < 3.0 / 6.0)
        .{ 0.0, c, x }
    else if (h < 4.0 / 6.0)
        .{ 0.0, x, c }
    else if (h < 5.0 / 6.0)
        .{ x, 0.0, c }
    else
        .{ c, 0.0, x };

    return .{ rgb[0] + m, rgb[1] + m, rgb[2] + m };
}
