//! Minimal noapi test — single window, animated clear + grid.
const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const vk = noapi.vk;
const Io = std.Io;

var exts_copy_global: []const [*:0]const u8 = &.{};

fn getExts() []const [*:0]const u8 {
    return exts_copy_global;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    try sdl3.hints.set(.video_driver, "wayland");
    try sdl3.hints.set(.render_driver, "vulkan");
    try sdl3.init(.{ .video = true, .events = true });
    defer sdl3.quit(.{ .video = true, .events = true });

    const sdl_win = try sdl3.video.Window.init("nogui", 800, 600, .{ .resizable = true });
    try sdl_win.show();

    // Vulkan loader via SDL3
    try sdl3.vulkan.loadLibrary(null);
    const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();

    const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
    exts_copy_global = try init.arena.allocator().dupe([*:0]const u8, sdl_exts);

    // Load shader SPIR-V
    const grid_vert_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/grid_vert.spv", gpa, .unlimited);
    defer gpa.free(grid_vert_bytes);
    const grid_frag_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/grid_frag.spv", gpa, .unlimited);
    defer gpa.free(grid_frag_bytes);
    const grid_vert_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, grid_vert_bytes));
    const grid_frag_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, grid_frag_bytes));

    // GPU init
    var gpu = try noapi.Gpu.init(.{
        .frames_in_flight = 2,
        .app_name = "nogui",
        .validation = true,
        .loader = .{
            .get_instance_proc_addr = @ptrCast(get_proc_addr),
            .get_instance_extensions = &getExts,
        },
        .io = io,
    });
    defer gpu.deinit();

    // Surface
    const sdl_surface = try sdl3.vulkan.Surface.init(sdl_win, @ptrFromInt(@intFromEnum(gpu.instanceHandle())), null);
    const surface: vk.SurfaceKHR = @enumFromInt(@intFromPtr(sdl_surface.surface));
    var gw = try noapi.Surface.init(&gpu, surface, .{ .extent = .{ .width = 800, .height = 600 } });
    const win_id = try sdl_win.getId();

    // Graphics shaders
    const grid_vert = try gpu.shaderCreate(grid_vert_spirv, .vertex, "main", "grid_vert");
    defer gpu.shaderDestroy(grid_vert);
    const grid_frag = try gpu.shaderCreate(grid_frag_spirv, .fragment, "main", "grid_frag");
    defer gpu.shaderDestroy(grid_frag);
    var time_sec: f32 = 0;

    // Main loop
    var should_close = false;
    while (!should_close) {
        time_sec += 1.0 / 60.0;

        // Event pump
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
                    if (we.id == win_id) gw.notifyResize(.{
                        .width = @intCast(@max(0, we.width)),
                        .height = @intCast(@max(0, we.height)),
                    });
                },
                else => {},
            }
        }

        const schedule = gw.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };
        _ = schedule;

        const surface_size = gw.surfaceSize();
        const tu32: u32 = @bitCast(time_sec);
        const time_bits: u64 = tu32;
        const push: noapi.PushData = .{ .frag_data = time_bits };
        var cmd = gw.commandsBegin();

        const sc = gw.currentImage();
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = .{
                0.1 + @sin(time_sec * 0.5) * 0.05,
                0.1 + @cos(time_sec * 0.7) * 0.05,
                0.2 + @sin(time_sec * 0.3) * 0.05,
                1.0,
            } },
        }, .render_area_size = .{ surface_size.width, surface_size.height } });

        cmd.setShaders(grid_vert, grid_frag);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.draw(push, 384, 1);

        cmd.endRendering();

        const frame_result = try gw.endFrame(.{ .blit_to_swapchain = true });
        _ = frame_result;
    }

    try gpu.waitIdle();
}
