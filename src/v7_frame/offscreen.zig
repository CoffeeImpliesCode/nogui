//! Surface-free noapi rendering and readback. The caller owns shaders, fonts,
//! scene lowering, and App lifetime; this context owns only GPU resources.
const std = @import("std");
const noapi = @import("noapi");
const nogui = @import("nogui");
const BindlessHeap = @import("heap.zig").BindlessHeap;
const scene = @import("scene.zig");

pub const Offscreen = struct {
    // noapi and the core endpoint retain pointers into State. Never move it.
    state: *State,

    const State = struct {
        allocator: std.mem.Allocator,
        gpu: noapi.Gpu,
        heap: BindlessHeap,
        registry: nogui.TextureRegistry,
        endpoint: nogui.GpuEndpoint,
        target: noapi.TextureHandle,
        readback: noapi.GpuPtr,
        extent: noapi.Extent2D,
        recording: bool = false,
    };

    pub const Options = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        loader: noapi.VkBackend.Options.Loader,
        extent: noapi.Extent2D,
        app_name: [:0]const u8 = "nogui-offscreen",
        validation: bool = false,
    };

    /// The loader must outlive this context. No window or Vulkan surface is made.
    pub fn init(options: Options) !Offscreen {
        if (options.extent.width == 0 or options.extent.height == 0) return error.InvalidExtent;
        const state = try options.allocator.create(State);
        errdefer options.allocator.destroy(state);
        state.allocator = options.allocator;
        state.gpu = try noapi.Gpu.init(.{
            .frames_in_flight = scene.frames_in_flight,
            .app_name = options.app_name,
            .validation = options.validation,
            .loader = options.loader,
            .io = options.io,
            .allocator = options.allocator,
        });
        errdefer state.gpu.deinit();
        state.heap = try BindlessHeap.init(options.allocator, &state.gpu);
        errdefer state.heap.deinit(options.allocator);
        state.registry = state.heap.runtimeRegistry();
        state.endpoint = .{ .gpu = &state.gpu, .textures = &state.registry };
        state.extent = options.extent;
        state.target = try createTarget(&state.gpu, options.extent);
        errdefer state.gpu.textureDestroy(state.target);
        state.readback = try createReadback(&state.gpu, options.extent);
        return .{ .state = state };
    }

    pub fn deinit(self: *Offscreen) void {
        const state = self.state;
        std.debug.assert(!state.recording);
        state.gpu.gpuFree(state.readback);
        state.gpu.textureDestroy(state.target);
        state.heap.deinit(state.allocator);
        state.gpu.deinit();
        state.allocator.destroy(state);
        self.* = undefined;
    }

    pub fn gpu(self: *Offscreen) *noapi.Gpu {
        return &self.state.gpu;
    }

    pub fn heap(self: *Offscreen) *BindlessHeap {
        return &self.state.heap;
    }

    pub fn endpoint(self: *Offscreen) *nogui.GpuEndpoint {
        return &self.state.endpoint;
    }

    pub fn target(self: *const Offscreen) noapi.TextureHandle {
        return self.state.target;
    }

    pub fn extent(self: *const Offscreen) noapi.Extent2D {
        return self.state.extent;
    }

    /// Resize only between recordings. Keep the old target on allocation errors.
    pub fn resize(self: *Offscreen, extent_new: noapi.Extent2D) !void {
        const state = self.state;
        if (state.recording) return error.FrameAlreadyRecording;
        if (extent_new.width == 0 or extent_new.height == 0) return error.InvalidExtent;
        if (state.extent.width == extent_new.width and state.extent.height == extent_new.height) return;
        const target_new = try createTarget(&state.gpu, extent_new);
        errdefer state.gpu.textureDestroy(target_new);
        const readback_new = try createReadback(&state.gpu, extent_new);
        errdefer state.gpu.gpuFree(readback_new);
        try state.gpu.waitIdle();
        state.gpu.gpuFree(state.readback);
        state.gpu.textureDestroy(state.target);
        state.target = target_new;
        state.readback = readback_new;
        state.extent = extent_new;
    }

    /// `cmd` and `frame` are caller-owned stack values and must stay in place
    /// until `submitRead` or `frame.cancelRecording` ends this recording.
    pub fn beginFrame(
        self: *Offscreen,
        frame_index: u32,
        cmd: *noapi.CommandBuffer,
        frame: *nogui.GpuFrame,
    ) !void {
        const state = self.state;
        if (state.recording) return error.FrameAlreadyRecording;
        cmd.* = try state.gpu.commandsBegin();
        frame.* = .{
            .endpoint = &state.endpoint,
            .command_buffer = cmd,
            .extent = state.extent,
            .frame_index = frame_index,
            .recording = .{ .active = .{ .context = state, .abort = cancelRecording } },
        };
        state.recording = true;
    }

    /// Copy the GUI pass's Oklab target in the SAME command buffer, then wait
    /// for its submission before returning pixels. The slice dies on resize,
    /// the next submission, or deinit. No raw Vulkan handle or surface escapes.
    pub fn submitRead(self: *Offscreen, frame: *nogui.GpuFrame) ![]const f32 {
        const state = self.state;
        if (!state.recording or frame.endpoint != &state.endpoint or
            frame.extent.width != state.extent.width or frame.extent.height != state.extent.height or
            frame.recording != .active) return error.InvalidFrame;
        errdefer frame.cancelRecording() catch @panic("offscreen recording cancellation failed");
        const cmd = frame.command_buffer;
        cmd.barrier(.{ .color_output = true }, .{ .transfer = true }, .{});
        const tex: noapi.Texture = .{
            .gpu = &state.gpu,
            .handle = state.target,
            .dimensions = .{ state.extent.width, state.extent.height, 1 },
            .format = scene.render_target_format,
        };
        cmd.copyFromTexture(tex, state.readback, .{
            .size = .{ state.extent.width, state.extent.height, 1 },
        });
        try state.gpu.queueSubmit(&.{cmd.*});
        frame.finishRecording();
        state.recording = false;
        try state.gpu.waitIdle();
        const count = try pixelCount(state.extent);
        const pixels: [*]const f32 = @ptrCast(@alignCast(state.readback.cpu));
        return pixels[0..count];
    }

    fn cancelRecording(raw: *anyopaque, cmd: *noapi.CommandBuffer) !void {
        const state: *State = @ptrCast(@alignCast(raw));
        try state.gpu.commandsCancel(cmd);
        state.recording = false;
    }
};

fn pixelCount(extent: noapi.Extent2D) !usize {
    const pixels = try std.math.mul(usize, extent.width, extent.height);
    return std.math.mul(usize, pixels, 4);
}

fn createTarget(gpu: *noapi.Gpu, extent: noapi.Extent2D) !noapi.TextureHandle {
    return gpu.textureCreate(.{
        .dimensions = .{ extent.width, extent.height, 1 },
        .format = scene.render_target_format,
        .usage = .{ .color_attachment = true, .sampled = true, .transfer_src = true },
    });
}

fn createReadback(gpu: *noapi.Gpu, extent: noapi.Extent2D) !noapi.GpuPtr {
    const bytes = try std.math.mul(u64, try pixelCount(extent), @sizeOf(f32));
    return gpu.gpuMalloc(bytes, 64, .readback);
}

/// Oklab → linear sRGB; matches the final blit in shaders/lib/color.slang.
pub fn oklabToLinearSrgb(lab: [3]f32) [3]f32 {
    const l_ = lab[0] + 0.3963377774 * lab[1] + 0.2158037573 * lab[2];
    const m_ = lab[0] - 0.1055613458 * lab[1] - 0.0638541728 * lab[2];
    const s_ = lab[0] - 0.0894841775 * lab[1] - 1.2914855480 * lab[2];
    const lms = [_]f32{ l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_ };
    return .{
        4.0767416621 * lms[0] - 3.3077115913 * lms[1] + 0.2309699292 * lms[2],
        -1.2684380046 * lms[0] + 2.6097574011 * lms[1] - 0.3413193965 * lms[2],
        -0.0041960863 * lms[0] - 0.7034186147 * lms[1] + 1.7076147010 * lms[2],
    };
}

/// Linear sRGB → gamma-encoded 8-bit channel (PPM stores sRGB bytes).
pub fn linearToSrgbByte(v: f32) u8 {
    const c = std.math.clamp(v, 0.0, 1.0);
    const enc = if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
    const scaled = std.math.clamp(enc, 0.0, 1.0) * 255.0;
    return @intFromFloat(@round(scaled));
}

/// P6 PPM of the offscreen rgba32_float Oklab target, with sRGB bytes.
pub fn writePpm(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    pixels: []const f32,
    extent: noapi.Extent2D,
) !void {
    const count = try pixelCount(extent);
    if (pixels.len < count) return error.InsufficientPixels;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(gpa);
    try buf.print(gpa, "P6\n{d} {d}\n255\n", .{ extent.width, extent.height });
    const w: usize = extent.width;
    const row = try gpa.alloc(u8, w * 3);
    defer gpa.free(row);
    for (0..extent.height) |y| {
        for (0..w) |x| {
            const lab = pixels[(y * w + x) * 4 ..][0..4];
            const lin = oklabToLinearSrgb(.{ lab[0], lab[1], lab[2] });
            row[x * 3 + 0] = linearToSrgbByte(lin[0]);
            row[x * 3 + 1] = linearToSrgbByte(lin[1]);
            row[x * 3 + 2] = linearToSrgbByte(lin[2]);
        }
        try buf.appendSlice(gpa, row);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items });
}
