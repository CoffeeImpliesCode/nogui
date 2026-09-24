//! 7_deferred_async_load — multi-pass deferred shading.
//! Port of the upstream 7_deferred_async_load Odin example.
//! Demonstrates:
//!   - G-buffer pass: render geometry to multiple color attachments (albedo, normal, metallic/roughness)
//!   - Deferred pass: composite from G-buffer textures via fullscreen quad
//!   - Multiple render targets and render passes
//! Simplified: uses a hardcoded cube instead of glTF scene loading.

const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const DescriptorPool = noapi.DescriptorPool;
const Io = std.Io;
const common = @import("common");

pub const tracy_impl = common.tracy_impl;
pub const tracy = common.tracy;
pub const tracy_options = common.tracy_options;

const start_width = 1000;
const start_height = 1000;
const frames_in_flight = 3;

// G-buffer texture indices in the descriptor heap
var gbuffer_albedo_idx: u32 = 0;
var gbuffer_normal_idx: u32 = 0;
var gbuffer_metallic_roughness_idx: u32 = 0;
var gbuffer_depth_idx: u32 = 0;
var env_map_idx: u32 = 0;

// Selected G-buffer texture type to display (toggled by left click)
var selected_texture_type: u32 = 0;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var app = try common.App.init("7_deferred_async_load", gpa, io, start_width, start_height, frames_in_flight, false);
    defer app.deinit();
    try app.sdl_win.show();

    // ── Shaders ────────────────────────────────
    const vert_gbuffer = try noapi.Shader.createFromPath(
        gpa,
        io,
        app.gpu,
        "shaders/gbuffer_vert.spv",
        .vertex,
        "main",
        "gbuffer_vert",
    );
    defer vert_gbuffer.destroy();
    const frag_gbuffer = try noapi.Shader.createFromPath(
        gpa,
        io,
        app.gpu,
        "shaders/gbuffer_frag.spv",
        .fragment,
        "main",
        "gbuffer_frag",
    );
    defer frag_gbuffer.destroy();
    const vert_final = try noapi.Shader.createFromPath(
        gpa,
        io,
        app.gpu,
        "shaders/final_pass_vert.spv",
        .vertex,
        "main",
        "final_pass_vert",
    );
    defer vert_final.destroy();
    const frag_final = try noapi.Shader.createFromPath(
        gpa,
        io,
        app.gpu,
        "shaders/final_pass_frag.spv",
        .fragment,
        "main",
        "final_pass_frag",
    );
    defer frag_final.destroy();

    // ── Descriptor pool ──────────────────────────────
    var pool = try DescriptorPool.init(app.gpu, 8, 0, 8);
    defer pool.deinit();

    // Create a default 1x1 white texture
    const default_tex = try createSolidColorTexture(app.gpu, &[_]u8{ 255, 255, 255, 255 });
    defer app.gpu.textureDestroy(default_tex.handle);

    // Create a sampler handle (shared across all allocTexture calls)
    const samp_handle = app.gpu.samplerDescriptor(.{ .max_anisotropy = 1.0 });

    // Allocate default texture at slot 3
    _ = pool.allocTexture(default_tex.handle, samp_handle, .@"2d");

    // ── Load environment map ────────────────────────────
    const env_map_idx_val = try loadEnvMap(gpa, io, app.gpu, &pool, samp_handle);
    env_map_idx = env_map_idx_val;

    // ── Upload geometry (cube) ───────────────────────────
    const cube_data = createCubeData(gpa);
    defer {
        gpa.free(cube_data.positions);
        gpa.free(cube_data.normals);
        gpa.free(cube_data.uvs);
        gpa.free(cube_data.indices);
    }

    const cube_pos_gpu = try common.gpuCreate([4]f32, app.gpu, cube_data.positions, 64);
    defer app.gpu.gpuFree(cube_pos_gpu);

    const cube_norm_gpu = try common.gpuCreate([4]f32, app.gpu, cube_data.normals, 64);
    defer app.gpu.gpuFree(cube_norm_gpu);

    const cube_uv_gpu = try common.gpuCreate([2]f32, app.gpu, cube_data.uvs, 64);
    defer app.gpu.gpuFree(cube_uv_gpu);

    const cube_idx_gpu = try common.gpuCreate(u32, app.gpu, cube_data.indices, 64);
    defer app.gpu.gpuFree(cube_idx_gpu);

    // ── Fullscreen quad ──────────────────────────────
    const fsq = createFullscreenQuad(gpa);
    defer {
        gpa.free(fsq.vertices);
        gpa.free(fsq.indices);
    }

    const fsq_vert_gpu = try common.gpuCreate(FullscreenVertex, app.gpu, fsq.vertices, 64);
    defer app.gpu.gpuFree(fsq_vert_gpu);

    const fsq_idx_gpu = try common.gpuCreate(u32, app.gpu, fsq.indices, 64);
    defer app.gpu.gpuFree(fsq_idx_gpu);

    // ── G-buffer textures ─────────────────────────────
    var window_w: i32 = start_width;
    var window_h: i32 = start_height;
    var gb_albedo: noapi.Texture.OwnedTexture = undefined;
    var gb_normal: noapi.Texture.OwnedTexture = undefined;
    var gb_mr: noapi.Texture.OwnedTexture = undefined;
    var gb_depth: noapi.Texture.OwnedTexture = undefined;
    try createGbufferTextures(
        app.gpu,
        &pool,
        @intCast(window_w),
        @intCast(window_h),
        &gb_albedo,
        &gb_normal,
        &gb_mr,
        &gb_depth,
        samp_handle,
    );
    defer {
        gb_albedo.deinit();
        gb_normal.deinit();
        gb_mr.deinit();
        gb_depth.deinit();
    }

    // ── Push constant structs ─────────────────────────
    const VertData = extern struct {
        positions: u64,
        normals: u64,
        uvs: u64,
        // std430 requires 16-byte alignment for mat4 (vec4 columns),
        // but C struct only gives 4-byte alignment for [16]f32.
        // Add padding to match the shader's std430 layout.
        _pad: u64 = undefined,
        model_to_world: [16]f32,
        model_to_world_normal: [16]f32,
        world_to_view: [16]f32,
        view_to_proj: [16]f32,
    };

    const FragData = extern struct {
        base_color_map: u32,
        base_color_map_sampler: u32,
        metallic_roughness_map: u32,
        metallic_roughness_map_sampler: u32,
        normal_map: u32,
        normal_map_sampler: u32,
    };

    const FsqFragData = extern struct {
        // Align-16 fields first (matches std430 vec4/vec3 alignment)
        v2w_right: [4]f32,
        v2w_up: [4]f32,
        v2w_fwd: [4]f32,
        cam_pos: [3]f32,
        // Align-4 fields (naturally packed, no gaps)
        gbuffer_albedo: u32,
        gbuffer_albedo_sampler: u32,
        gbuffer_normal: u32,
        gbuffer_normal_sampler: u32,
        gbuffer_metallic_roughness: u32,
        gbuffer_metallic_roughness_sampler: u32,
        gbuffer_depth: u32,
        gbuffer_depth_sampler: u32,
        env_map: u32,
        tan_half_fov: f32,
        tan_half_fov_x: f32,
        selected_texture_type: i32,
    };

    const vert_data_size = @sizeOf(VertData);
    const frag_data_size = @sizeOf(FragData);
    const total_size = vert_data_size + frag_data_size;
    const fsq_push_size = @sizeOf(FsqFragData);

    // Persistent push-constant buffer (allocated once, reused each frame)
    const push_buf = try app.gpu.gpuMalloc(total_size + fsq_push_size, 64, .default);
    defer app.gpu.gpuFree(push_buf);

    // ── Render loop ───────────────────────────────
    const win_id = try app.sdl_win.getId();
    var should_close = false;
    var timer = common.FrameTimer.init();
    while (!should_close) {
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
                    if (me.button == .left) {
                        selected_texture_type = (selected_texture_type + 1) % 4;
                        const names = [_][*:0]const u8{ "Albedo", "Normal", "Metallic/Roughness", "Shaded" };
                        var buf: [128]u8 = undefined;
                        const title = std.fmt.bufPrintZ(
                            &buf,
                            "Deferred Shading — {s}",
                            .{names[selected_texture_type]},
                        ) catch "Deferred Shading";
                        app.sdl_win.setTitle(title) catch |err| std.log.warn("setTitle failed: {}", .{err});
                    }
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

        const flags = app.sdl_win.getFlags();
        if (flags.minimized) {
            sdl3.timer.delayMilliseconds(16);
            continue;
        }

        // ── Delta time ──────────────────────────────
        // DIAG: check device on first frame
        if (timer.fps_count == 0) try app.gpu.waitIdle();
        timer.report();

        // ── Render frame ─────────────────────────────
        const schedule = app.surf.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };

        // ── Recreate g-buffer if surface size changed ──────
        const surface_size = app.surf.surfaceSize();
        if (surface_size.width != window_w or surface_size.height != window_h) {
            window_w = @as(i32, @intCast(surface_size.width));
            window_h = @as(i32, @intCast(surface_size.height));
            try app.gpu.waitIdle();

            gb_albedo.deinit();
            gb_normal.deinit();
            gb_mr.deinit();
            gb_depth.deinit();
            try createGbufferTextures(
                app.gpu,
                &pool,
                @intCast(window_w),
                @intCast(window_h),
                &gb_albedo,
                &gb_normal,
                &gb_mr,
                &gb_depth,
                samp_handle,
            );
        }

        // ── Camera ──────────────────────────────
        const aspect: f32 = @floatCast(@as(f64, @floatFromInt(window_w)) / @as(f64, @floatFromInt(window_h)));
        const view = common.lookAt(.{ 3.0, 2.0, 3.0 }, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 });
        const proj = common.perspective(59.0 * std.math.pi / 180.0, aspect, 0.1, 1000.0);

        var cmd = app.surf.commandsBegin();

        // ── Pass 1: G-buffer ────────────────────────────
        cmd.beginRendering(.{
            .color_attachments = &.{
                .{
                    .texture = gb_albedo.texture.handle,
                    .load_op = .clear,
                    .store_op = .store,
                    .clear_color = .{ 0, 0, 0, 1 },
                },
                .{
                    .texture = gb_normal.texture.handle,
                    .load_op = .clear,
                    .store_op = .store,
                    .clear_color = .{ 0.5, 0.5, 1.0, 1.0 },
                },
                .{
                    .texture = gb_mr.texture.handle,
                    .load_op = .clear,
                    .store_op = .store,
                    .clear_color = .{ 0, 0, 0, 1 },
                },
            },
            .depth_attachment = noapi.RenderingAttachment{
                .texture = gb_depth.texture.handle,
                .load_op = .clear,
                .store_op = .store,
                .clear_depth = 1.0,
            },
            .render_area_size = .{ surface_size.width, surface_size.height },
        });

        cmd.setShaders(vert_gbuffer, frag_gbuffer);
        cmd.setDepthState(.{ .mode = .{ .read = true, .write = true }, .compare = .less });
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .back, .front_face = .clockwise });

        const model = common.id();
        const model_normal = common.transpose(common.inv(model));

        const vert_data_ptr: *VertData = @ptrCast(@alignCast(push_buf.cpu));
        const frag_data_ptr: *FragData = @ptrCast(@alignCast(push_buf.cpu + vert_data_size));

        vert_data_ptr.* = .{
            .positions = cube_pos_gpu.gpu,
            .normals = cube_norm_gpu.gpu,
            .uvs = cube_uv_gpu.gpu,
            .model_to_world = model,
            .model_to_world_normal = model_normal,
            .world_to_view = view,
            .view_to_proj = proj,
        };

        frag_data_ptr.* = .{
            .base_color_map = 0,
            .base_color_map_sampler = 0,
            .metallic_roughness_map = 0,
            .metallic_roughness_map_sampler = 0,
            .normal_map = 0,
            .normal_map_sampler = 0,
        };

        cmd.bindDescriptorSets(pool.heap);
        cmd.drawIndexed(
            .{
                .vert_data = push_buf.gpu,
                .frag_data = push_buf.gpu + vert_data_size,
                .indirect = 0,
            },
            cube_idx_gpu,
            .u32,
            @intCast(cube_data.indices.len),
            1,
            0,
            0,
        );

        cmd.endRendering();

        // Barrier: G-buffer color attachments → fragment shader reads
        cmd.barrier(.{ .color_output = true }, .{ .fragment = true }, .{});

        // ── Pass 2: Deferred shading ────────────────────────
        const sc = app.surf.currentImage();
        cmd.beginRendering(.{
            .color_attachments = &.{
                .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = .{ 0.7, 0.7, 0.7, 1.0 } },
            },
            .render_area_size = .{ surface_size.width, surface_size.height },
        });

        cmd.setShaders(vert_final, frag_final);
        cmd.setDepthState(.{ .mode = .{}, .compare = .always });
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });

        const fsq_frag_ptr: *FsqFragData = @ptrCast(@alignCast(push_buf.cpu + total_size));

        // Extract view→world basis vectors from the view matrix
        const v2w_r0 = view[0];
        const v2w_r1 = view[4];
        const v2w_r2 = view[8];
        const v2w_u0 = view[1];
        const v2w_u1 = view[5];
        const v2w_u2 = view[9];
        const v2w_f0 = -view[2];
        const v2w_f1 = -view[6];
        const v2w_f2 = -view[10];

        const w_f: f32 = @floatFromInt(surface_size.width);
        const h_f: f32 = @floatFromInt(surface_size.height);
        const aspect_ratio = w_f / h_f;
        const tan_half_fov = @tan(59.0 * std.math.pi / 180.0 * 0.5);

        fsq_frag_ptr.* = .{
            .v2w_right = .{ v2w_r0, v2w_r1, v2w_r2, 0 },
            .v2w_up = .{ v2w_u0, v2w_u1, v2w_u2, 0 },
            .v2w_fwd = .{ v2w_f0, v2w_f1, v2w_f2, 0 },
            .cam_pos = .{ 3.0, 2.0, 3.0 },
            .gbuffer_albedo = gbuffer_albedo_idx,
            .gbuffer_albedo_sampler = gbuffer_albedo_idx,
            .gbuffer_normal = gbuffer_normal_idx,
            .gbuffer_normal_sampler = gbuffer_normal_idx,
            .gbuffer_metallic_roughness = gbuffer_metallic_roughness_idx,
            .gbuffer_metallic_roughness_sampler = gbuffer_metallic_roughness_idx,
            .gbuffer_depth = gbuffer_depth_idx,
            .gbuffer_depth_sampler = gbuffer_depth_idx,
            .env_map = env_map_idx,
            .tan_half_fov = tan_half_fov,
            .tan_half_fov_x = tan_half_fov * aspect_ratio,
            .selected_texture_type = @as(i32, @intCast(selected_texture_type)),
        };

        cmd.bindDescriptorSets(pool.heap);
        cmd.draw(
            .{
                .vert_data = push_buf.gpu,
                .frag_data = push_buf.gpu + total_size,
                .indirect = 0,
            },
            3,
            1,
        );

        cmd.endRendering();

        _ = try app.surf.endFrame(.{ .blit_to_swapchain = true });

        if (schedule.next_vblank_us > 1000) {
            try std.Io.sleep(io, .fromMicroseconds(schedule.next_vblank_us - 1000), .awake);
        }
    }

    try app.gpu.waitIdle();
}

// ── Geometry helpers ───────────────────────────────

const CubeData = struct {
    positions: []const [4]f32,
    normals: []const [4]f32,
    uvs: []const [2]f32,
    indices: []const u32,
};

fn createCubeData(allocator: std.mem.Allocator) CubeData {
    const positions = allocator.dupe(
        [4]f32,
        &[_][4]f32{
            .{ -0.5, -0.5, 0.5, 1.0 },  .{ 0.5, -0.5, 0.5, 1.0 },
            .{ 0.5, 0.5, 0.5, 1.0 },    .{ -0.5, 0.5, 0.5, 1.0 },
            .{ 0.5, -0.5, -0.5, 1.0 },  .{ -0.5, -0.5, -0.5, 1.0 },
            .{ -0.5, 0.5, -0.5, 1.0 },  .{ 0.5, 0.5, -0.5, 1.0 },
            .{ 0.5, -0.5, 0.5, 1.0 },   .{ 0.5, -0.5, -0.5, 1.0 },
            .{ 0.5, 0.5, -0.5, 1.0 },   .{ 0.5, 0.5, 0.5, 1.0 },
            .{ -0.5, -0.5, -0.5, 1.0 }, .{ -0.5, -0.5, 0.5, 1.0 },
            .{ -0.5, 0.5, 0.5, 1.0 },   .{ -0.5, 0.5, -0.5, 1.0 },
            .{ -0.5, 0.5, 0.5, 1.0 },   .{ 0.5, 0.5, 0.5, 1.0 },
            .{ 0.5, 0.5, -0.5, 1.0 },   .{ -0.5, 0.5, -0.5, 1.0 },
            .{ -0.5, -0.5, -0.5, 1.0 }, .{ 0.5, -0.5, -0.5, 1.0 },
            .{ 0.5, -0.5, 0.5, 1.0 },   .{ -0.5, -0.5, 0.5, 1.0 },
        },
    ) catch |err| blk: {
        std.log.warn("alloc failed: {}", .{err});
        break :blk &.{};
    };

    const normals = allocator.dupe(
        [4]f32,
        &[_][4]f32{
            .{ 0, 0, 1, 0 },  .{ 0, 0, 1, 0 },  .{ 0, 0, 1, 0 },  .{ 0, 0, 1, 0 },
            .{ 0, 0, -1, 0 }, .{ 0, 0, -1, 0 }, .{ 0, 0, -1, 0 }, .{ 0, 0, -1, 0 },
            .{ 1, 0, 0, 0 },  .{ 1, 0, 0, 0 },  .{ 1, 0, 0, 0 },  .{ 1, 0, 0, 0 },
            .{ -1, 0, 0, 0 }, .{ -1, 0, 0, 0 }, .{ -1, 0, 0, 0 }, .{ -1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },  .{ 0, 1, 0, 0 },  .{ 0, 1, 0, 0 },  .{ 0, 1, 0, 0 },
            .{ 0, -1, 0, 0 }, .{ 0, -1, 0, 0 }, .{ 0, -1, 0, 0 }, .{ 0, -1, 0, 0 },
        },
    ) catch |err| blk: {
        std.log.warn("alloc failed: {}", .{err});
        break :blk &.{};
    };

    const uvs = allocator.dupe(
        [2]f32,
        &[_][2]f32{
            .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 },
            .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 },
            .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 },
            .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 },
            .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 },
            .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 },
        },
    ) catch |err| blk: {
        std.log.warn("alloc failed: {}", .{err});
        break :blk &.{};
    };

    const indices = allocator.dupe(
        u32,
        &[_]u32{
            0,  1,  2,  0,  2,  3,
            4,  5,  6,  4,  6,  7,
            8,  9,  10, 8,  10, 11,
            12, 13, 14, 12, 14, 15,
            16, 17, 18, 16, 18, 19,
            20, 21, 22, 20, 22, 23,
        },
    ) catch |err| blk: {
        std.log.warn("alloc failed: {}", .{err});
        break :blk &.{};
    };

    return .{ .positions = positions, .normals = normals, .uvs = uvs, .indices = indices };
}

const FullscreenVertex = extern struct {
    pos: [4]f32,
    uv: [2]f32,
};

const FullscreenQuad = struct {
    vertices: []const FullscreenVertex,
    indices: []const u32,
};

fn createFullscreenQuad(allocator: std.mem.Allocator) FullscreenQuad {
    const vertices = allocator.dupe(
        FullscreenVertex,
        &[_]FullscreenVertex{
            .{ .pos = .{ -1, 1, 0, 1 }, .uv = .{ 0, 1 } },
            .{ .pos = .{ 1, -1, 0, 1 }, .uv = .{ 1, 0 } },
            .{ .pos = .{ 1, 1, 0, 1 }, .uv = .{ 1, 1 } },
            .{ .pos = .{ -1, -1, 0, 1 }, .uv = .{ 0, 0 } },
        },
    ) catch |err| blk: {
        std.log.warn("alloc failed: {}", .{err});
        break :blk &.{};
    };

    const indices = allocator.dupe(
        u32,
        &[_]u32{ 0, 2, 1, 0, 1, 3 },
    ) catch |err| blk: {
        std.log.warn("alloc failed: {}", .{err});
        break :blk &.{};
    };

    return .{ .vertices = vertices, .indices = indices };
}

// ── G-buffer texture creation ─────────────────────────

fn createGbufferTextures(
    gpu: *noapi.Gpu,
    pool: *DescriptorPool,
    width: u32,
    height: u32,
    out_albedo: *noapi.Texture.OwnedTexture,
    out_normal: *noapi.Texture.OwnedTexture,
    out_mr: *noapi.Texture.OwnedTexture,
    out_depth: *noapi.Texture.OwnedTexture,
    samp_handle: u64,
) !void {
    const gb_desc: noapi.TextureDesc = .{
        .dimensions = .{ width, height, 1 },
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true, .color_attachment = true, .storage = false },
    };

    const depth_desc: noapi.TextureDesc = .{
        .dimensions = .{ width, height, 1 },
        .format = .d32_float,
        .usage = .{ .depth_stencil_attachment = true, .sampled = true },
    };

    {
        const tex = try noapi.Texture.OwnedTexture.allocAndCreate(gpu, gb_desc);
        out_albedo.* = tex;
        gbuffer_albedo_idx = pool.allocTexture(tex.texture.handle, samp_handle, .@"2d");
    }

    {
        const tex = try noapi.Texture.OwnedTexture.allocAndCreate(gpu, gb_desc);
        out_normal.* = tex;
        gbuffer_normal_idx = pool.allocTexture(tex.texture.handle, samp_handle, .@"2d");
    }

    {
        const tex = try noapi.Texture.OwnedTexture.allocAndCreate(gpu, gb_desc);
        out_mr.* = tex;
        gbuffer_metallic_roughness_idx = pool.allocTexture(tex.texture.handle, samp_handle, .@"2d");
    }

    {
        const tex = try noapi.Texture.OwnedTexture.allocAndCreate(gpu, depth_desc);
        out_depth.* = tex;
        gbuffer_depth_idx = pool.allocTexture(tex.texture.handle, samp_handle, .@"2d");
    }
}

fn createSolidColorTexture(gpu: *noapi.Gpu, rgba: *const [4]u8) !noapi.Texture {
    const desc: noapi.TextureDesc = .{
        .dimensions = .{ 1, 1, 1 },
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    };
    const tex = try noapi.Texture.create(gpu, desc);

    const pixel_size: u64 = 4;
    const staging = try gpu.gpuMalloc(pixel_size, 16, .default);
    defer gpu.gpuFree(staging);
    @memcpy(staging.cpu[0..pixel_size], rgba);

    var cmd = try gpu.commandsBegin();
    cmd.copyToTexture(tex, staging, .{ .size = .{ 1, 1, 1 } });
    cmd.barrier(.{ .transfer = true }, .{ .fragment = true }, .{});
    try gpu.queueSubmit(&.{cmd});

    return tex;
}

/// Load a PPM P6 file from disk and upload as a GPU texture.
/// Returns the descriptor heap index.
fn loadEnvMap(gpa: std.mem.Allocator, io: Io, gpu: *noapi.Gpu, pool: *DescriptorPool, samp_handle: u64) !u32 {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/env.ppm", gpa, .unlimited);
    defer gpa.free(bytes);

    // Parse P6 header with optional comment lines
    var pos: usize = 0;
    if (bytes.len < 3 or bytes[0] != 'P' or bytes[1] != '6') return error.InvalidPpm;
    pos = 3; // skip "P6\n"

    // Skip whitespace and comments
    const skipWhitespaceAndComments = struct {
        fn skip(p: *usize, buf: []const u8) void {
            outer: while (p.* < buf.len) {
                switch (buf[p.*]) {
                    '\n', ' ', '\t', '\r' => {
                        p.* += 1;
                    },
                    '#' => {
                        while (p.* < buf.len and buf[p.*] != '\n') p.* += 1;
                    },
                    else => break :outer,
                }
            }
        }
    }.skip;

    skipWhitespaceAndComments(&pos, bytes);

    // Parse width
    var width: u32 = 0;
    while (pos < bytes.len and bytes[pos] >= '0' and bytes[pos] <= '9') {
        width = width * 10 + (bytes[pos] - '0');
        pos += 1;
    }
    skipWhitespaceAndComments(&pos, bytes);

    // Parse height
    var height: u32 = 0;
    while (pos < bytes.len and bytes[pos] >= '0' and bytes[pos] <= '9') {
        height = height * 10 + (bytes[pos] - '0');
        pos += 1;
    }
    skipWhitespaceAndComments(&pos, bytes);

    // Parse maxval
    var maxval: u32 = 0;
    while (pos < bytes.len and bytes[pos] >= '0' and bytes[pos] <= '9') {
        maxval = maxval * 10 + (bytes[pos] - '0');
        pos += 1;
    }
    if (pos < bytes.len and bytes[pos] == '\n') pos += 1;

    // (maxval parsed above, always 255 for this file)

    // Remaining data is RGB pixels: width * height * 3 bytes
    const rgb_data = bytes[pos..];
    const expected_rgb = width * height * 3;
    if (rgb_data.len < expected_rgb) return error.InvalidPpm;

    // Create GPU texture (RGBA8, so convert RGB → RGBA)
    const tex = try noapi.Texture.create(gpu, .{
        .dimensions = .{ width, height, 1 },
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    });

    // Upload via staging buffer with RGB→RGBA conversion
    const pixel_count = width * height;
    const staging_size = pixel_count * 4;
    const staging = try gpu.gpuMalloc(staging_size, 16, .default);
    defer gpu.gpuFree(staging);

    const dst = staging.cpu[0..staging_size];
    for (0..pixel_count) |i| {
        dst[i * 4 + 0] = rgb_data[i * 3 + 0];
        dst[i * 4 + 1] = rgb_data[i * 3 + 1];
        dst[i * 4 + 2] = rgb_data[i * 3 + 2];
        dst[i * 4 + 3] = 255;
    }

    var cmd = try gpu.commandsBegin();
    cmd.copyToTexture(tex, staging, .{ .size = .{ width, height, 1 } });
    cmd.barrier(.{ .transfer = true }, .{ .fragment = true }, .{});
    try gpu.queueSubmit(&.{cmd});

    // Allocate in descriptor heap
    const idx = pool.allocTexture(tex.handle, samp_handle, .@"2d");
    return idx;
}
