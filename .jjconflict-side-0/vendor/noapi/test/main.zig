//! noapi test application — animated grid + triangle demo.
//! Spawns each window's render loop in its own thread.

const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const vk = noapi.vk;
const Io = std.Io;
pub const tracy_impl = @import("tracy_impl");
pub const tracy = @import("tracy");
pub const tracy_options: tracy.Options = .{
    .on_demand = false,
    .no_broadcast = false,
    .only_localhost = false,
    .only_ipv4 = false,
    .delayed_init = false,
    .manual_lifetime = false,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 3 and std.mem.eql(u8, args[1], "--submission-lifecycle-test")) {
        const submission_count = try std.fmt.parseInt(u32, args[2], 10);
        return submissionLifecycleTest(init, submission_count);
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "--presentation-feedback-test")) {
        return presentationFeedbackTest(init, args[2]);
    }

    try sdl3.hints.set(.video_driver, "wayland");
    try sdl3.hints.set(.render_driver, "vulkan");
    try sdl3.init(.{ .video = true, .events = true });
    defer sdl3.quit(.{ .video = true, .events = true });

    const sdl_win = try sdl3.video.Window.init("noapi", 800, 600, .{ .resizable = true });
    try sdl_win.show();

    // ── Vulkan loader via SDL3 ───────────────────────────
    try sdl3.vulkan.loadLibrary(null);
    const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();

    const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
    const exts_copy = try init.arena.allocator().dupe([*:0]const u8, sdl_exts);
    exts_copy_global = exts_copy;

    // ── Load shader SPIR-V
    const grid_vert_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/grid_vert.spv", gpa, .unlimited);
    defer gpa.free(grid_vert_bytes);
    const grid_frag_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/grid_frag.spv", gpa, .unlimited);
    defer gpa.free(grid_frag_bytes);
    const grid_vert_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, grid_vert_bytes));
    const grid_frag_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, grid_frag_bytes));

    // ── GPU init
    var gpu = try noapi.Gpu.init(.{
        .frames_in_flight = 2,
        .app_name = "noapi test",
        .validation = true,
        .loader = .{
            .get_instance_proc_addr = @ptrCast(get_proc_addr),
            .get_instance_extensions = &getExts,
        },
        .io = io,
        .allocator = gpa,
    });
    defer gpu.deinit();

    // ── Windows + surfaces
    const sdl_surface = try sdl3.vulkan.Surface.init(sdl_win, @ptrFromInt(@intFromEnum(gpu.instanceHandle())), null);
    const surface: vk.SurfaceKHR = @enumFromInt(@intFromPtr(sdl_surface.surface));
    var surf1 = try noapi.Surface.init(&gpu, surface, .{ .extent = .{ .width = 800, .height = 600 } });
    try presentTimingCapabilitySmoke(&surf1);

    const sdl_win2 = try sdl3.video.Window.init("noapi-2", 400, 300, .{ .resizable = true });
    try sdl_win2.show();
    const sdl_surface2 = try sdl3.vulkan.Surface.init(sdl_win2, @ptrFromInt(@intFromEnum(gpu.instanceHandle())), null);
    const surface2: vk.SurfaceKHR = @enumFromInt(@intFromPtr(sdl_surface2.surface));
    var surf2 = try noapi.Surface.init(&gpu, surface2, .{ .extent = .{ .width = 400, .height = 300 } });

    const win1_id = try sdl_win.getId();
    const win2_id = try sdl_win2.getId();

    // ── Compute shader + texture ──────────────────────────
    const comp_spv_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/compute_comp.spv", gpa, .unlimited);
    defer gpa.free(comp_spv_bytes);
    const comp_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, comp_spv_bytes));
    const comp_shader = try gpu.shaderCreate(comp_spirv, .compute, "main", "compute");
    defer gpu.shaderDestroy(comp_shader);

    const compute_tex = try gpu.textureCreate(.{
        .dimensions = .{ 256, 256, 1 },
        .format = .rgba8_unorm,
        .usage = .{ .storage = true, .transfer_src = true, .sampled = true },
    });
    defer gpu.textureDestroy(compute_tex);

    // ── Graphics shaders
    const grid_vert = try gpu.shaderCreate(grid_vert_spirv, .vertex, "main", "grid_vert");
    defer gpu.shaderDestroy(grid_vert);
    const grid_frag = try gpu.shaderCreate(grid_frag_spirv, .fragment, "main", "grid_frag");
    defer gpu.shaderDestroy(grid_frag);

    // ── Buffer-based indexed triangle shaders ──────────────
    const btri_vert_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/buf_tri_vert.spv", gpa, .unlimited);
    defer gpa.free(btri_vert_bytes);
    const btri_frag_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/buf_tri_frag.spv", gpa, .unlimited);
    defer gpa.free(btri_frag_bytes);
    const btri_vert_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, btri_vert_bytes));
    const btri_frag_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, btri_frag_bytes));

    const btri_vert = try gpu.shaderCreate(btri_vert_spirv, .vertex, "main", "btri_vert");
    defer gpu.shaderDestroy(btri_vert);
    const btri_frag = try gpu.shaderCreate(btri_frag_spirv, .fragment, "main", "btri_frag");
    defer gpu.shaderDestroy(btri_frag);

    // ── Vertex + index buffers
    const vertex_size = 20;
    const vert_buf = try gpu.gpuMalloc(vertex_size * 6, 64, .default);

    const vert_data: [*]f32 = @ptrCast(@alignCast(vert_buf.cpu));
    vert_data[0] = 0.0;
    vert_data[1] = -0.5;
    vert_data[2] = 1.0;
    vert_data[3] = 0.0;
    vert_data[4] = 0.0;
    vert_data[5] = 0.5;
    vert_data[6] = 0.5;
    vert_data[7] = 0.0;
    vert_data[8] = 1.0;
    vert_data[9] = 0.0;
    vert_data[10] = -0.5;
    vert_data[11] = 0.5;
    vert_data[12] = 0.0;
    vert_data[13] = 0.0;
    vert_data[14] = 1.0;
    vert_data[15] = -0.5;
    vert_data[16] = -0.7;
    vert_data[17] = 0.0;
    vert_data[18] = 1.0;
    vert_data[19] = 1.0;
    vert_data[20] = 0.5;
    vert_data[21] = -0.7;
    vert_data[22] = 1.0;
    vert_data[23] = 0.0;
    vert_data[24] = 1.0;
    vert_data[25] = 0.0;
    vert_data[26] = 0.1;
    vert_data[27] = 1.0;
    vert_data[28] = 1.0;
    vert_data[29] = 0.0;

    const idx_buf = try gpu.gpuMalloc(@sizeOf(u32) * 6, 16, .default);
    const idx_data: [*]u32 = @ptrCast(@alignCast(idx_buf.cpu));
    idx_data[0] = 0;
    idx_data[1] = 1;
    idx_data[2] = 2;
    idx_data[3] = 3;
    idx_data[4] = 4;
    idx_data[5] = 5;

    const scratch_buf = try gpu.gpuMalloc(64, 16, .default);

    const test_sem = try gpu.semaphoreCreate(0);
    defer gpu.semaphoreDestroy(test_sem);

    const test_heap = try gpu.descHeapCreate(65536, 65536, 256);
    defer gpu.descHeapDestroy(test_heap);

    // Bind compute texture as storage image at slot 0 in the RW descriptor set
    {
        const comp_desc = gpu.textureRwViewDescriptor(compute_tex, .{ .format = .default });
        gpu.descHeapSetTexturesRw(test_heap, 0, &.{comp_desc});
    }

    const rt_tex = try gpu.textureCreate(.{
        .dimensions = .{ 256, 256, 1 },
        .format = .rgba8_unorm,
        .usage = .{ .color_attachment = true, .transfer_src = true },
    });
    defer gpu.textureDestroy(rt_tex);

    // ── Shared state for window threads ───────────────────
    var w1: SharedW1 = .{
        .sdl = &sdl_win,
        .grid_vert = grid_vert,
        .grid_frag = grid_frag,
        .btri_vert = btri_vert,
        .btri_frag = btri_frag,
        .vert_buf = vert_buf,
        .idx_buf = idx_buf,
        .vertex_size = vertex_size,
        .rt_tex = rt_tex,
        .compute_tex = compute_tex,
        .comp_shader = comp_shader,
        .test_heap = test_heap,
        .scratch_buf = scratch_buf,
        .test_sem = test_sem,
    };
    var w2: SharedW2 = .{
        .sdl = &sdl_win2,
        .grid_vert = grid_vert,
        .grid_frag = grid_frag,
        .compute_tex = compute_tex,
    };

    // ── Spawn window render threads ───────────────────────
    const thread1 = try std.Thread.spawn(.{}, window1, .{ &surf1, &w1 });
    const thread2 = try std.Thread.spawn(.{}, window2, .{ &surf2, &w2 });

    // ── Main thread: event loop only ─────────────────────
    while (!w1.should_close or !w2.should_close) {
        while (sdl3.events.poll()) |ev| {
            switch (ev) {
                .quit => {
                    w1.should_close = true;
                    w2.should_close = true;
                },
                .window_close_requested => |we| {
                    const wid = we.id;
                    if (wid == win1_id) w1.should_close = true else if (wid == win2_id) w2.should_close = true;
                },
                .key_down => |ke| {
                    if (ke.key == .escape) {
                        w1.should_close = true;
                        w2.should_close = true;
                    }
                    if (ke.key == .space) w1.time_sec = 0;
                },
                .window_resized => |we| {
                    const wid = we.id;
                    if (wid == win1_id) {
                        surf1.notifyResize(.{ .width = @intCast(we.width), .height = @intCast(we.height) });
                    } else if (wid == win2_id) {
                        surf2.notifyResize(.{ .width = @intCast(we.width), .height = @intCast(we.height) });
                    }
                },
                else => {},
            }
        }
    }

    w1.should_close = true;
    w2.should_close = true;

    thread1.join();
    thread2.join();

    try gpu.waitIdle();
}

const SharedW1 = struct {
    should_close: bool = false,
    sdl: *const sdl3.video.Window,
    time_sec: f32 = 0,
    sem_val: u64 = 0,

    grid_vert: noapi.Shader,
    grid_frag: noapi.Shader,
    btri_vert: noapi.Shader,
    btri_frag: noapi.Shader,
    vert_buf: noapi.GpuPtr,
    idx_buf: noapi.GpuPtr,
    vertex_size: u32,
    rt_tex: noapi.TextureHandle,
    compute_tex: noapi.TextureHandle,
    comp_shader: noapi.Shader,
    test_heap: noapi.DescriptorHeap,
    scratch_buf: noapi.GpuPtr,
    test_sem: noapi.Semaphore,
};

fn window1(win: *noapi.Surface, s: *SharedW1) void {
    defer {
        win.deinit();
        s.sdl.deinit();
    }
    while (!s.should_close) {
        s.time_sec += 1.0 / 60.0;
        const tu32: u32 = @bitCast(s.time_sec);
        const time_bits: u64 = tu32;

        const schedule = win.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };
        _ = schedule;

        const surface_size = win.surfaceSize();
        const push: noapi.PushData = .{ .frag_data = time_bits };
        var cmd = win.commandsBegin();

        // ── Pass 1: render grid to offscreen texture ─────────
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = s.rt_tex, .load_op = .clear, .store_op = .store, .clear_color = .{ 1.0, 0.0, 1.0, 1.0 } },
        }, .render_area_size = .{ 256, 256 } });
        cmd.setShaders(s.grid_vert, s.grid_frag);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.draw(push, 384, 1);
        cmd.endRendering();

        // ── Pass 2: main scene to swapchain ───────────────────
        const sc = win.currentImage();
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = .{
                0.1 + @sin(s.time_sec * 0.5) * 0.05,
                0.1 + @cos(s.time_sec * 0.7) * 0.05,
                0.2 + @sin(s.time_sec * 0.3) * 0.05,
                1.0,
            } },
        }, .render_area_size = .{ surface_size.width, surface_size.height } });

        cmd.setShaders(s.grid_vert, s.grid_frag);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.draw(push, 384, 1);

        // Draw: indexed triangle RGB (top-right)
        {
            const ox = surface_size.width / 4;
            const oy = surface_size.height / 4;
            cmd.beginDebugLabel("tri-RGB", .{ 1, 0, 0, 1 });
            cmd.setViewport(.{
                .x = @floatFromInt(surface_size.width - ox - 10),
                .y = 10,
                .width = @floatFromInt(ox),
                .height = @floatFromInt(oy),
            });
            cmd.setScissor(.{ .x = @intCast(surface_size.width - ox - 10), .y = 10, .width = ox, .height = oy });
            cmd.setShaders(s.btri_vert, s.btri_frag);
            cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
            cmd.setVertexInput(
                &.{.{ .binding = 0, .stride = s.vertex_size, .input_rate = 0 }},
                &.{
                    .{ .location = 0, .binding = 0, .format = @intFromEnum(vk.Format.r32g32_sfloat), .offset = 0 },
                    .{ .location = 1, .binding = 0, .format = @intFromEnum(vk.Format.r32g32b32_sfloat), .offset = 8 },
                },
            );
            cmd.bindVertexBuffer(0, s.vert_buf, 0);
            cmd.drawIndexed(.{}, s.idx_buf, 3, 1, 0, 0);
            cmd.endDebugLabel();
        }

        // Draw: indexed triangle CMY (bottom-right)
        {
            const ox = surface_size.width / 4;
            const oy = surface_size.height / 4;
            cmd.beginDebugLabel("tri-CMY", .{ 1, 1, 0, 1 });
            cmd.setViewport(.{
                .x = @floatFromInt(surface_size.width - ox - 10),
                .y = @floatFromInt(surface_size.height - oy - 10),
                .width = @floatFromInt(ox),
                .height = @floatFromInt(oy),
            });
            cmd.setScissor(.{
                .x = @intCast(surface_size.width - ox - 10),
                .y = @intCast(surface_size.height - oy - 10),
                .width = ox,
                .height = oy,
            });
            cmd.setShaders(s.btri_vert, s.btri_frag);
            cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
            cmd.setVertexInput(
                &.{.{ .binding = 0, .stride = s.vertex_size, .input_rate = 0 }},
                &.{
                    .{ .location = 0, .binding = 0, .format = @intFromEnum(vk.Format.r32g32_sfloat), .offset = 0 },
                    .{ .location = 1, .binding = 0, .format = @intFromEnum(vk.Format.r32g32b32_sfloat), .offset = 8 },
                },
            );
            cmd.bindVertexBuffer(0, s.vert_buf, 0);
            cmd.drawIndexed(.{}, s.idx_buf, 3, 1, 3, 0);
            cmd.endDebugLabel();
        }

        cmd.endRendering();

        // Blit rt_tex to top-left
        {
            const blit_sz: u32 = @min(256, @min(surface_size.width, surface_size.height));
            cmd.blitTextureHandle(
                sc,
                .{
                    .offset_a = .{ 0, 0, 0 },
                    .offset_b = .{ @as(i32, @intCast(blit_sz)), @as(i32, @intCast(blit_sz)), 1 },
                },
                s.rt_tex,
                .{
                    .offset_a = .{ 0, 0, 0 },
                    .offset_b = .{ @as(i32, @intCast(blit_sz)), @as(i32, @intCast(blit_sz)), 1 },
                },
                .linear,
            );
        }

        // Compute: fill compute_tex, then blit to bottom-right
        {
            cmd.beginDebugLabel("compute", .{ 0, 1, 1, 1 });
            cmd.setComputeShader(s.comp_shader);
            cmd.bindDescriptorSets(s.test_heap);
            cmd.dispatch(time_bits, 256 / 8, 256 / 8, 1);
            cmd.barrier(.{ .compute = true }, .{ .transfer = true }, .{});
            cmd.endDebugLabel();
        }
        {
            const blit_sz: u32 = @min(256, @min(surface_size.width, surface_size.height));
            const sx: i32 = @intCast(surface_size.width -| blit_sz);
            const sy: i32 = @intCast(surface_size.height -| blit_sz);
            cmd.blitTextureHandle(
                sc,
                .{
                    .offset_a = .{ sx, sy, 0 },
                    .offset_b = .{ sx + @as(i32, @intCast(blit_sz)), sy + @as(i32, @intCast(blit_sz)), 1 },
                },
                s.compute_tex,
                .{
                    .offset_a = .{ 0, 0, 0 },
                    .offset_b = .{ @as(i32, @intCast(blit_sz)), @as(i32, @intCast(blit_sz)), 1 },
                },
                .linear,
            );
        }

        // memCopy + barrier
        {
            cmd.beginDebugLabel("memcpy", .{ 0, 1, 0, 1 });
            cmd.memCopy(s.scratch_buf, s.vert_buf, 16);
            cmd.barrier(.{ .transfer = true }, .{ .compute = true }, .{});
            cmd.endDebugLabel();
        }

        s.sem_val += 1;
        cmd.addWaitSemaphore(win.index, s.test_sem, s.sem_val - 1);
        cmd.addSignalSemaphore(win.index, s.test_sem, s.sem_val);

        _ = win.endFrame(.{ .blit_to_swapchain = true }) catch |err| std.log.warn(
            "endFrame failed: {s}",
            .{@errorName(err)},
        );
    }
}

const SharedW2 = struct {
    should_close: bool = false,
    sdl: *const sdl3.video.Window,
    time_sec: f32 = 0,

    grid_vert: noapi.Shader,
    grid_frag: noapi.Shader,
    compute_tex: noapi.TextureHandle,
};

fn window2(win: *noapi.Surface, s: *SharedW2) void {
    defer {
        win.deinit();
        s.sdl.deinit();
    }
    while (!s.should_close) {
        s.time_sec += 1.0 / 60.0;
        const tu32: u32 = @bitCast(s.time_sec);
        const time_bits: u64 = tu32;

        _ = win.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };
        const sz2 = win.surfaceSize();
        var cmd = win.commandsBegin();

        const sc = win.currentImage();
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = .{ 0.1, 0.2, 0.3, 1.0 } },
        }, .render_area_size = .{ sz2.width, sz2.height } });
        cmd.setShaders(s.grid_vert, s.grid_frag);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.draw(.{ .frag_data = time_bits }, 384, 1);
        cmd.endRendering();

        // Blit compute texture to bottom-right
        {
            const blit_sz: u32 = @min(256, @min(sz2.width, sz2.height));
            const sx: i32 = @intCast(sz2.width -| blit_sz);
            const sy: i32 = @intCast(sz2.height -| blit_sz);
            cmd.blitTextureHandle(sc, .{
                .offset_a = .{ sx, sy, 0 },
                .offset_b = .{
                    sx + @as(i32, @intCast(blit_sz)),
                    sy + @as(i32, @intCast(blit_sz)),
                    1,
                },
            }, s.compute_tex, .{
                .offset_a = .{ 0, 0, 0 },
                .offset_b = .{
                    @as(i32, @intCast(blit_sz)),
                    @as(i32, @intCast(blit_sz)),
                    1,
                },
            }, .linear);
        }

        _ = win.endFrame(.{ .blit_to_swapchain = true }) catch |err| std.log.warn(
            "endFrame failed: {s}",
            .{@errorName(err)},
        );
    }
}

fn submissionLifecycleTest(init: std.process.Init, submission_count: u32) !void {
    if (submission_count == 0) return error.InvalidSubmissionCount;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (debug_allocator.deinit() != .ok) @panic("submission lifecycle allocator leak");
    }
    const allocator = debug_allocator.allocator();
    const io = init.io;

    // The lifecycle check is window-free: video init is required only so SDL
    // can resolve the Vulkan loader; no surface or swapchain is created.
    try sdl3.init(.{ .video = true });
    defer sdl3.quit(.{ .video = true });

    try sdl3.vulkan.loadLibrary(null);
    const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();
    const extensions = try sdl3.vulkan.getInstanceExtensions();
    const extension_copy = try allocator.dupe([*:0]const u8, extensions);
    defer allocator.free(extension_copy);
    exts_copy_global = extension_copy;
    defer exts_copy_global = &.{};

    var gpu = try noapi.Gpu.init(.{
        .frames_in_flight = 3,
        .app_name = "noapi submission lifecycle",
        .loader = .{
            .get_instance_proc_addr = @ptrCast(get_proc_addr),
            .get_instance_extensions = &getExts,
        },
        .io = io,
        .allocator = allocator,
        .timestamp_queries = true,
    });
    defer gpu.deinit();

    var queue: noapi.Queue = .{ .gpu = &gpu };
    const semaphore = try gpu.semaphoreCreate(0);
    defer gpu.semaphoreDestroy(semaphore);

    const timestamp_info = gpu.timestampInfo();
    const timestamp_set = if (timestamp_info != null)
        try gpu.timestampQuerySetCreate(2)
    else
        null;
    defer if (timestamp_set) |set| gpu.timestampQuerySetDestroy(set);

    var slot_values = [_]u64{0} ** 3;
    var wrote_timestamps = false;
    var signal_value: u64 = 1;
    while (signal_value <= submission_count) : (signal_value += 1) {
        const slot: usize = @intCast((signal_value - 1) % slot_values.len);
        if (slot_values[slot] != 0) {
            try gpu.semaphoreWait(semaphore, slot_values[slot]);
        }

        var command_buffer = try gpu.commandsBegin();
        if (!wrote_timestamps) {
            if (timestamp_set) |set| {
                try command_buffer.timestampReset(set, 0, 2);
                try command_buffer.timestampWrite(set, 0, .all_commands_start);
                try command_buffer.timestampWrite(set, 1, .all_commands_end);
            }
            wrote_timestamps = true;
        }
        try queue.submitSignal(&.{command_buffer}, semaphore, signal_value);
        if (gpu.backend.submitted_work.items.len == 0) {
            return error.SignalSubmissionNotTracked;
        }
        slot_values[slot] = signal_value;
    }

    try gpu.semaphoreWait(semaphore, submission_count);
    try gpu.waitIdle();
    if (gpu.backend.submitted_work.items.len != 0) {
        return error.SubmittedWorkNotReclaimed;
    }

    if (timestamp_set) |set| {
        var timestamps: [2]u64 = undefined;
        try gpu.timestampQuerySetRead(set, 0, &timestamps);
        const info = timestamp_info.?;
        const mask = info.mask();
        const start = timestamps[0] & mask;
        const end = timestamps[1] & mask;
        const span = info.spanTicks(start, end);
        if (span == 0 or span > mask) return error.InvalidTimestampSpan;
    }
}

fn presentTimingCapabilitySmoke(surface: *noapi.Surface) !void {
    var feedback: [1]noapi.PresentFeedback = undefined;
    const count = surface.pollPresentFeedback(&feedback) catch |err| {
        if (!surface.supportsPresentTiming() and err == error.PresentTimingUnsupported) return;
        return err;
    };
    if (!surface.supportsPresentTiming()) return error.PresentTimingCapabilityMismatch;
    if (count != 0) return error.UnexpectedPresentFeedback;
}

fn presentationFeedbackTest(init: std.process.Init, requested_mode: []const u8) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (debug_allocator.deinit() != .ok) @panic("presentation feedback allocator leak");
    }
    const allocator = debug_allocator.allocator();
    const io = init.io;

    try sdl3.init(.{ .video = true, .events = true });
    defer sdl3.quit(.{ .video = true, .events = true });

    const sdl_window = try sdl3.video.Window.init(
        "noapi presentation feedback",
        954,
        1044,
        .{},
    );
    defer sdl_window.deinit();
    try sdl_window.show();

    try sdl3.vulkan.loadLibrary(null);
    const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();
    const extensions = try sdl3.vulkan.getInstanceExtensions();
    const extension_copy = try allocator.dupe([*:0]const u8, extensions);
    defer allocator.free(extension_copy);
    exts_copy_global = extension_copy;
    defer exts_copy_global = &.{};

    var gpu = try noapi.Gpu.init(.{
        .frames_in_flight = 2,
        .app_name = "noapi presentation feedback",
        .validation = true,
        .loader = .{
            .get_instance_proc_addr = @ptrCast(get_proc_addr),
            .get_instance_extensions = &getExts,
        },
        .io = io,
        .allocator = allocator,
    });
    defer gpu.deinit();

    const sdl_surface = try sdl3.vulkan.Surface.init(
        sdl_window,
        @ptrFromInt(@intFromEnum(gpu.instanceHandle())),
        null,
    );
    const vk_surface: vk.SurfaceKHR = @enumFromInt(@intFromPtr(sdl_surface.surface));
    var surface = try noapi.Surface.init(
        &gpu,
        vk_surface,
        .{
            .extent = .{ .width = 954, .height = 1044 },
            .present_mode = .fifo,
        },
    );
    defer surface.deinit();
    const backend_window = &gpu.backend.windows.items[surface.index];

    const force_google = std.mem.eql(u8, requested_mode, "google");
    if (force_google) {
        if (!gpu.backend.has_google_present_timing) {
            return error.GooglePresentTimingUnsupported;
        }
        backend_window.timing_mode = .google;
    } else if (std.mem.eql(u8, requested_mode, "selected")) {
        if (!surface.supportsPresentTiming()) return error.PresentTimingUnsupported;
    } else {
        return error.InvalidPresentationFeedbackMode;
    }
    defer {
        const diagnostics = gpu.backend.windows.items[surface.index].present_timing_diagnostics;
        std.log.info(
            "presentation-feedback diagnostics mode={s} swapchain=0x{x} " ++
                "generation={d} stage=0x{x} domain={d} valid={} " ++
                "chain=(id2={},timings={},google={}) " ++
                "present=(attempts={},submitted={},last_id={},result={s}) " ++
                "outstanding={}",
            .{
                @tagName(diagnostics.mode),
                diagnostics.swapchain_id,
                diagnostics.swapchain_generation,
                diagnostics.present_stage_bits,
                diagnostics.time_domain_id,
                diagnostics.time_domain_valid,
                diagnostics.last_present_chain_id2,
                diagnostics.last_present_chain_timings,
                diagnostics.last_present_chain_google,
                diagnostics.timed_present_attempts,
                diagnostics.timed_present_submitted,
                diagnostics.last_present_id,
                @tagName(diagnostics.last_present_queue_result),
                diagnostics.outstanding_timed_presents,
            },
        );
        std.log.info(
            "presentation-feedback query diagnostics " ++
                "ext_probe=(calls={},result={s},count={},empty={},counters={d}/{d}) " ++
                "ext_retrieve=(calls={},result={s},count={},counters={d}/{d}," ++
                "record=(id={},stages={},stage=0x{x},time={},complete={},totals={}/{})) " ++
                "google=(probe_calls={},probe_result={s},probe_count={},retrieve_calls={}," ++
                "retrieve_result={s},retrieve_count={},record_id={},time={}) " ++
                "poll={}",
            .{
                diagnostics.ext_probe_calls,
                @tagName(diagnostics.ext_probe_result),
                diagnostics.ext_probe_count,
                diagnostics.ext_empty_probe_polls,
                diagnostics.ext_probe_timing_properties_counter,
                diagnostics.ext_probe_time_domains_counter,
                diagnostics.ext_retrieve_calls,
                @tagName(diagnostics.ext_retrieve_result),
                diagnostics.ext_retrieve_count,
                diagnostics.ext_retrieve_timing_properties_counter,
                diagnostics.ext_retrieve_time_domains_counter,
                diagnostics.ext_last_record_id,
                diagnostics.ext_last_record_stage_count,
                diagnostics.ext_last_record_stage_bits,
                diagnostics.ext_last_record_time,
                diagnostics.ext_last_record_complete,
                diagnostics.ext_complete_records,
                diagnostics.ext_positive_records,
                diagnostics.google_probe_calls,
                @tagName(diagnostics.google_probe_result),
                diagnostics.google_probe_count,
                diagnostics.google_retrieve_calls,
                @tagName(diagnostics.google_retrieve_result),
                diagnostics.google_retrieve_count,
                diagnostics.google_last_record_id,
                diagnostics.google_last_record_time,
                diagnostics.last_poll_returned,
            },
        );
        std.log.info(
            "presentation-feedback watchdog start={} now={} elapsed={} " ++
                "triggered={} google_empty={} google_records={}/{}",
            .{
                diagnostics.first_timed_present_start_ns,
                diagnostics.watchdog_last_now_ns,
                diagnostics.watchdog_elapsed_ns,
                diagnostics.watchdog_triggered,
                diagnostics.google_empty_probe_polls,
                diagnostics.google_complete_records,
                diagnostics.google_positive_records,
            },
        );
    }

    if (backend_window.timing_mode == .unsupported) {
        if (force_google) return error.GooglePresentTimingUnsupported;
        std.log.info("presentation-feedback unsupported capability is honest", .{});
        return;
    }
    if (backend_window.timing_mode == .google) {
        var feedback: [64]noapi.PresentFeedback = undefined;
        var timing_id: u64 = 0;
        var submitted = false;
        for (0..3) |_| {
            timing_id += 1;
            while (sdl3.events.poll()) |_| {}
            _ = try surface.beginFrame();
            const frame_result = try surface.endFrame(.{
                .blit_to_swapchain = true,
                .timing_id = timing_id,
            });
            const queue_out_of_date =
                backend_window.present_timing_diagnostics.last_present_queue_result == .out_of_date;
            if (frame_result.present_out_of_date != queue_out_of_date) {
                return error.PresentationQueueUnavailable;
            }
            if (backend_window.present_timing_diagnostics.last_present_queue_result != .out_of_date) {
                submitted = true;
                break;
            }
        }
        if (!submitted) return error.PresentationQueueUnavailable;
        try gpu.waitIdle();
        const drain_start = std.Io.Timestamp.now(io, .awake);
        while (true) {
            while (sdl3.events.poll()) |_| {}
            const count = surface.pollPresentFeedback(&feedback) catch |err| {
                if (err == error.PresentTimingDataUnavailable and !surface.supportsPresentTiming()) return;
                return err;
            };
            if (count != 0) {
                std.log.info(
                    "presentation-feedback mode=google id={d} actual_ns={d}",
                    .{ feedback[0].present_id, feedback[0].actual_present_ns },
                );
                return;
            }
            const elapsed = std.Io.Timestamp.now(io, .awake).nanoseconds - drain_start.nanoseconds;
            if (elapsed >= 5_000_000_000) break;
            sdl3.timer.delayMilliseconds(1);
        }
        if (!surface.supportsPresentTiming()) return;
        return error.MissingPresentFeedback;
    }

    if (backend_window.timing_mode != .ext) return error.PresentTimingUnsupported;

    const stage_support_bits: u32 = @bitCast(backend_window.present_stage_support);
    const domain_count: usize = @intCast(backend_window.present_time_domain_count);
    if (stage_support_bits == 0 or domain_count == 0) return error.PresentTimingUnsupported;
    var saved_domains: [8]vk.TimeDomainKHR = undefined;
    var saved_domain_ids: [8]u64 = undefined;
    @memcpy(saved_domains[0..domain_count], backend_window.present_time_domains[0..domain_count]);
    @memcpy(saved_domain_ids[0..domain_count], backend_window.present_time_domain_ids[0..domain_count]);
    const saved_stage_support = backend_window.present_stage_support;
    const total_pairs = @as(usize, @popCount(stage_support_bits)) * domain_count;
    var pair_number: usize = 0;
    var timing_id: u64 = 0;
    var feedback: [64]noapi.PresentFeedback = undefined;

    for (0..32) |stage_index| {
        const stage_bit: u32 = @as(u32, 1) << @intCast(stage_index);
        if ((stage_support_bits & stage_bit) == 0) continue;
        const stage: vk.PresentStageFlagsEXT = @bitCast(stage_bit);
        for (0..domain_count) |domain_index| {
            pair_number += 1;
            std.log.info(
                "presentation-feedback pair {}/{} stage=0x{x} domain_kind={} domain_id={d}",
                .{
                    pair_number,
                    total_pairs,
                    stage_bit,
                    @intFromEnum(saved_domains[domain_index]),
                    saved_domain_ids[domain_index],
                },
            );

            var submitted = false;
            for (0..3) |_| {
                backend_window.timing_mode = .ext;
                backend_window.present_stage_support = saved_stage_support;
                backend_window.present_stage_queries = stage;
                backend_window.present_time_domain_count = @intCast(domain_count);
                @memcpy(
                    backend_window.present_time_domains[0..domain_count],
                    saved_domains[0..domain_count],
                );
                @memcpy(
                    backend_window.present_time_domain_ids[0..domain_count],
                    saved_domain_ids[0..domain_count],
                );
                backend_window.time_domain_id = saved_domain_ids[domain_index];
                backend_window.time_domain_valid = true;
                timing_id += 1;
                while (sdl3.events.poll()) |_| {}
                _ = try surface.beginFrame();
                const frame_result = try surface.endFrame(.{
                    .blit_to_swapchain = true,
                    .timing_id = timing_id,
                });
                const queue_out_of_date =
                    backend_window.present_timing_diagnostics.last_present_queue_result == .out_of_date;
                if (frame_result.present_out_of_date != queue_out_of_date) {
                    return error.PresentationQueueUnavailable;
                }
                if (backend_window.present_timing_diagnostics.last_present_queue_result != .out_of_date) {
                    submitted = true;
                    break;
                }
            }
            if (!submitted) continue;
            try gpu.waitIdle();

            var drain_start = std.Io.Timestamp.now(io, .awake);
            while (true) {
                while (sdl3.events.poll()) |_| {}
                const count = surface.pollPresentFeedback(&feedback) catch |err| {
                    if (err == error.PresentTimingDataUnavailable) {
                        if (!surface.supportsPresentTiming()) break;
                        if (backend_window.timing_mode == .google) {
                            timing_id += 1;
                            _ = try surface.beginFrame();
                            _ = try surface.endFrame(.{
                                .blit_to_swapchain = true,
                                .timing_id = timing_id,
                            });
                            try gpu.waitIdle();
                            drain_start = std.Io.Timestamp.now(io, .awake);
                            continue;
                        }
                    }
                    return err;
                };
                if (count != 0) {
                    std.log.info(
                        "presentation-feedback mode={s} id={d} actual_ns={d}",
                        .{
                            @tagName(backend_window.timing_mode),
                            feedback[0].present_id,
                            feedback[0].actual_present_ns,
                        },
                    );
                    return;
                }
                const elapsed = std.Io.Timestamp.now(io, .awake).nanoseconds - drain_start.nanoseconds;
                if (elapsed >= 5_000_000_000) break;
                sdl3.timer.delayMilliseconds(1);
            }
            const pair_diagnostics = backend_window.present_timing_diagnostics;
            std.log.info(
                "presentation-feedback pair result stage=0x{x} domain_id={} " ++
                    "mode={s} queue={s} attempts={} submitted={} outstanding={} " ++
                    "ext_empty={} ext_records={}/{} last_record=({},{}) " ++
                    "watchdog_elapsed={} triggered={}",
                .{
                    stage_bit,
                    saved_domain_ids[domain_index],
                    @tagName(backend_window.timing_mode),
                    @tagName(pair_diagnostics.last_present_queue_result),
                    pair_diagnostics.timed_present_attempts,
                    pair_diagnostics.timed_present_submitted,
                    pair_diagnostics.outstanding_timed_presents,
                    pair_diagnostics.ext_empty_probe_polls,
                    pair_diagnostics.ext_complete_records,
                    pair_diagnostics.ext_positive_records,
                    pair_diagnostics.ext_last_record_id,
                    pair_diagnostics.ext_last_record_time,
                    pair_diagnostics.watchdog_elapsed_ns,
                    pair_diagnostics.watchdog_triggered,
                },
            );
            if (pair_number == total_pairs and !surface.supportsPresentTiming()) return;
        }
    }

    if (!surface.supportsPresentTiming()) return;
    return error.MissingPresentFeedback;
}

var exts_copy_global: []const [*:0]const u8 = &.{};

fn getExts() []const [*:0]const u8 {
    return exts_copy_global;
}
