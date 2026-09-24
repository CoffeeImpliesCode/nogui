//! Minimal noapi test — single window, animated clear + grid.
//!
//! Run with no arguments it opens a window and animates until it is closed or
//! Escape is pressed, which is what the `run` step is for. Two flags make the
//! same program scriptable, so a check does not have to sit and wait on a
//! window that will never close on its own:
//!
//!   --frames N   render N frames, then exit 0
//!   --shot PATH  render one frame, write it to PATH as a binary PPM, exit 0
//!
//! `--shot` writes the swapchain image back through the GPU rather than
//! screen-grabbing the window, so the result does not depend on what is
//! visible on the compositor or on the window being mapped.
const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const Io = std.Io;

var exts_copy_global: []const [*:0]const u8 = &.{};

fn getExts() []const [*:0]const u8 {
    return exts_copy_global;
}

/// What this run should do. `null` frames with a `null` path is the
/// interactive default.
const Mode = struct {
    frames: ?u32 = null,
    shot: ?[]const u8 = null,
};

fn parseArgs(args_it: *std.process.Args.Iterator) !Mode {
    _ = args_it.next(); // program name
    var mode: Mode = .{};
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--frames")) {
            const value = args_it.next() orelse return error.MissingFramesCount;
            mode.frames = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--shot")) {
            mode.shot = args_it.next() orelse return error.MissingShotPath;
        } else if (std.mem.eql(u8, arg, "--help")) {
            return error.HelpRequested;
        } else {
            // An unknown flag is a typo, not a reason to open a window and
            // leave it there.
            std.log.err("unrecognized argument: {s}", .{arg});
            return error.UnrecognizedArgument;
        }
    }
    if (mode.shot != null) mode.frames = 1;
    return mode;
}
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    const mode = parseArgs(&args_it) catch |err| switch (err) {
        error.HelpRequested => {
            try Io.File.stdout().writeStreamingAll(io, "usage: nogui [--frames N] [--shot PATH]\n");
            return;
        },
        else => |e| return e,
    };

    // try sdl3.hints.set(.video_driver, "wayland");
    try sdl3.hints.set(.render_driver, "vulkan");
    try sdl3.init(.{ .video = true, .events = true });
    defer sdl3.quit(.{ .video = true, .events = true });

    const sdl_win = try sdl3.video.Window.init("nogui", 800, 600, .{
        .resizable = true,
        .vulkan = true,
    });
    defer sdl_win.deinit();
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
    var gw = try noapi.Surface.initSdl(
        &gpu,
        @ptrCast(sdl_win.value),
        @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
        .{ .extent = .{ .width = 800, .height = 600 } },
    );
    defer gw.deinit();
    const win_id = try sdl_win.getId();

    // Graphics shaders
    const grid_vert = try gpu.shaderCreate(grid_vert_spirv, .vertex, "main", "grid_vert");
    defer gpu.shaderDestroy(grid_vert);
    const grid_frag = try gpu.shaderCreate(grid_frag_spirv, .fragment, "main", "grid_frag");
    defer gpu.shaderDestroy(grid_frag);
    // A capture cannot copy from the swapchain image: it is not created with
    // TRANSFER_SRC, and asking for it is a validation error (VUID
    // vkCmdCopyImageToBuffer-srcImage-00186). The frame is therefore rendered
    // into an offscreen target that IS a copy source, and that target is what
    // the readback copies.
    const capture_size = gw.surfaceSize();
    const capture_target: ?noapi.TextureHandle = if (mode.shot != null)
        try gpu.textureCreate(.{
            .dimensions = .{ capture_size.width, capture_size.height, 1 },
            .format = .rgba32_float,
            .usage = .{ .color_attachment = true, .sampled = true, .transfer_src = true },
        })
    else
        null;
    defer if (capture_target) |target| gpu.textureDestroy(target);

    // A shot needs the image back on the host. The buffer is allocated before
    // the loop so a capture is not a per-frame cost.
    const readback: ?noapi.GpuPtr = if (capture_target != null) blk: {
        const bytes = @as(u64, capture_size.width) * capture_size.height * 4 * @sizeOf(f32);
        break :blk try gpu.gpuMalloc(bytes, 64, .readback);
    } else null;
    defer if (readback) |buffer| gpu.gpuFree(buffer);
    // A frame budget ends the run on its own, so a check never has to wait on
    // a window that is never going to close.
    var rendered: u32 = 0;
    const frame_limit: ?u32 = mode.frames;
    var time_sec: f32 = 0;

    // Main loop
    // Main loop. It ends on a close, on Escape, or on the frame budget; with no
    // budget it runs until the window is closed, which is the interactive case.
    var should_close = false;
    while (!should_close) {
        if (frame_limit) |limit| {
            if (rendered >= limit) break;
        }
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
        // With a capture target the frame renders THERE, so the copy below has
        // a legal source; without one it renders straight to the swapchain as
        // it always has.
        // With a capture target the frame renders THERE, so the copy below has
        // a legal source; without one it renders straight to the swapchain as
        // it always has. The render area is the ATTACHMENT's size for the same
        // reason: a window that resized after setup left the swapchain larger
        // than the target, and a render area larger than its attachment is a
        // validation error.
        const render_target = capture_target orelse sc;
        const render_area: [2]u32 = if (capture_target != null)
            .{ capture_size.width, capture_size.height }
        else
            .{ surface_size.width, surface_size.height };
        const render_attachment: noapi.RenderingAttachment = .{
            .texture = render_target,
            .load_op = .clear,
            .store_op = .store,
            .clear_color = .{
                0.1 + @sin(time_sec * 0.5) * 0.05,
                0.1 + @cos(time_sec * 0.7) * 0.05,
                0.2 + @sin(time_sec * 0.3) * 0.05,
                1.0,
            },
        };
        cmd.beginRendering(.{
            .color_attachments = &.{render_attachment},
            .render_area_size = render_area,
        });

        cmd.setShaders(grid_vert, grid_frag);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.draw(push, 384, 1);

        cmd.endRendering();

        // The capture is recorded into the SAME command buffer as the frame,
        // so it copies what this frame rendered rather than the previous one,
        // and it is read only after the queue is idle.
        if (readback) |buffer| {
            const shot_texture: noapi.Texture = .{
                .gpu = &gpu,
                .handle = render_target,
                .dimensions = .{ capture_size.width, capture_size.height, 1 },
                .format = .rgba32_float,
            };
            cmd.barrier(.{ .color_output = true }, .{ .transfer = true }, .{});
            cmd.copyFromTexture(shot_texture, buffer, .{
                .size = .{ capture_size.width, capture_size.height, 1 },
            });
        }

        const frame_result = try gw.endFrame(.{ .blit_to_swapchain = true });
        _ = frame_result;
        rendered += 1;
    }

    try gpu.waitIdle();

    // The bytes are host-visible only once the copy above has been submitted
    // and the queue is idle, which is why this runs after `waitIdle`.
    if (mode.shot) |path| {
        // The capture size, not the swapchain size: the bytes came from the
        // offscreen target, and reading them with the wrong stride would
        // shear the image.
        const buffer = readback.?;
        const pixels: [*]const f32 = @ptrCast(@alignCast(buffer.cpu));
        try writePpm(io, gpa, path, pixels, capture_size.width, capture_size.height);
        const report = try std.fmt.allocPrint(gpa, "shot: {s} {d}x{d}\n", .{
            path, capture_size.width, capture_size.height,
        });
        defer gpa.free(report);
        try Io.File.stdout().writeStreamingAll(io, report);
    }
}

/// Write the read-back image as a binary PPM. The swapchain is sRGB, so the
/// stored bytes are already display-encoded and are written as they are.
fn writePpm(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    pixels: [*]const f32,
    width: u32,
    height: u32,
) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer = &out.writer;
    try writer.print("P6\n{d} {d}\n255\n", .{ width, height });
    // A binary PPM is THREE bytes per pixel, so the row is packed, not
    // strided: writing the four source channels per pixel produces a file
    // with a valid header and a sheared image.
    const row = try gpa.alloc(u8, @as(usize, width) * 3);
    defer gpa.free(row);
    for (0..height) |y| {
        for (0..width) |x| {
            const texel = pixels[(y * width + x) * 4 ..][0..4];
            // The swapchain is BGRA8 sRGB and a copy into an rgba32_float buffer
            // keeps the component order, so red comes from the third channel.
            row[x * 3 + 0] = channelToByte(texel[2]);
            row[x * 3 + 1] = channelToByte(texel[1]);
            row[x * 3 + 2] = channelToByte(texel[0]);
        }
        try writer.writeAll(row);
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

fn channelToByte(value: f32) u8 {
    const scaled = value * 255.0;
    if (!(scaled > 0)) return 0;
    if (scaled > 255) return 255;
    return @intFromFloat(scaled + 0.5);
}
