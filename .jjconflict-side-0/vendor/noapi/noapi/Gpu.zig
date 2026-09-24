//! Gpu — the "no graphics API" graphics context.
//! Follows mr_gpu's pattern: plain struct, opaque-handle resource types,
//! all resource methods take *Gpu.

const std = @import("std");
const vk = @import("vk.zig");
const VkBackend = @import("VkBackend.zig").VkBackend;

const Shader = @import("Shader.zig");
const Semaphore = @import("Semaphore.zig");
const Buffer = @import("Buffer.zig");
const CommandBuffer = @import("CommandBuffer.zig");
const TimestampQuerySet = @import("TimestampQuerySet.zig");
const Texture = @import("Texture.zig");
const DescriptorHeap = @import("DescriptorHeap.zig");

// Imports for types used internally (no longer re-exported — root.zig handles that)
const TextureHandle = @import("TextureHandle.zig");
const DeviceLimits = @import("DeviceLimits.zig");
const GpuPtr = @import("GpuPtr.zig");
const GpuError = @import("GpuError.zig").GpuError;
const MemoryType = @import("GpuError.zig").MemoryType;
const ShaderStage = @import("Shader.zig").ShaderStage;
const BufferDesc = @import("Buffer.zig").BufferDesc;
const TextureDesc = @import("Texture.zig").TextureDesc;
const TextureViewDesc = @import("Texture.zig").TextureViewDesc;
const SamplerDesc = @import("Texture.zig").SamplerDesc;

const tracy = @import("tracy");

const log = std.log.scoped(.gpu);

pub const Gpu = @This();

pub const Backend = VkBackend;
pub const CommandBufferHandle = VkBackend.CommandBufferHandle;
pub const ShaderHandle = VkBackend.ShaderHandle;
pub const SemaphoreHandle = VkBackend.SemaphoreHandle;
pub const BufferHandle = VkBackend.BufferHandle;
pub const QueueHandle = VkBackend.QueueHandle;
pub const TimestampQueryHandle = VkBackend.TimestampQueryHandle;
pub const DeviceIdentity = VkBackend.DeviceIdentity;

pub fn deviceIdentity(self: *const Gpu) DeviceIdentity {
    return self.backend.deviceIdentity();
}

backend: *VkBackend,
frames_in_flight: u5,
frame_index: u5 = 0,
allocator: std.mem.Allocator = std.heap.page_allocator,

pub const Options = struct {
    frames_in_flight: u5 = 2,
    validation: bool = false,
    app_name: [:0]const u8 = "noapi",
    loader: VkBackend.Options.Loader = .{},
    io: std.Io,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    enable_debug_utils: bool = false,
    enable_nv_checkpoints: bool = false,
    enable_nv_diagnostics: bool = false,
    enable_device_fault: bool = false,
    timestamp_queries: bool = false,
};

pub fn init(options: Options) !Gpu {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    return .{
        .backend = try VkBackend.init(.{
            .app_name = options.app_name,
            .validation = options.validation,
            .frames_in_flight = options.frames_in_flight,
            .loader = options.loader,
            .io = options.io,
            .allocator = options.allocator,
            .enable_debug_utils = options.enable_debug_utils,
            .enable_nv_checkpoints = options.enable_nv_checkpoints,
            .enable_nv_diagnostics = options.enable_nv_diagnostics,
            .enable_device_fault = options.enable_device_fault,
            .timestamp_queries = options.timestamp_queries,
        }),
        .frames_in_flight = options.frames_in_flight,
        .allocator = options.allocator,
    };
}

pub fn deinit(self: *Gpu) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.backend.flushPendingFrees() catch |err| log.warn("flushPendingFrees failed: {}", .{err});
    self.backend.deinit();
    self.allocator.destroy(self.backend);
    self.* = undefined;
}

pub fn flushPendingFrees(self: *Gpu) !void {
    try self.backend.flushPendingFrees();
}

pub fn waitIdle(self: *Gpu) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    try self.backend.waitIdle();
}

pub fn commandsBegin(self: *Gpu) !CommandBuffer {
    const handle = try self.backend.commandsBegin();
    return .{ .gpu = self, .handle = handle };
}

pub fn numSurfaces(self: *const Gpu) u32 {
    return self.backend.numWindows();
}
pub fn deviceLimits(self: *const Gpu) DeviceLimits {
    return self.backend.deviceLimits();
}
pub fn timestampInfo(self: *const Gpu) ?TimestampQuerySet.TimestampInfo {
    return self.backend.timestampInfo();
}

pub fn timestampQuerySetCreate(self: *Gpu, count: u32) !TimestampQuerySet.TimestampQuerySet {
    const handle = try self.backend.timestampQuerySetCreate(count);
    return .{ .gpu = self, .handle = handle, .count = count };
}

pub fn timestampQuerySetDestroy(self: *Gpu, set: TimestampQuerySet.TimestampQuerySet) void {
    self.backend.timestampQuerySetDestroy(set.handle);
}

pub fn timestampQuerySetRead(
    self: *Gpu,
    set: TimestampQuerySet.TimestampQuerySet,
    first: u32,
    out: []u64,
) !void {
    if (out.len > std.math.maxInt(u32)) return error.InvalidTimestampRange;
    try TimestampQuerySet.validateQueryRange(set.count, first, @intCast(out.len));
    try self.backend.timestampQuerySetRead(set.handle, first, out);
}

fn copyCommandBufferHandles(
    cmd_bufs: []const CommandBuffer,
    handles: *[64]CommandBufferHandle,
) ![]CommandBufferHandle {
    if (cmd_bufs.len > handles.len) return error.TooManyCommandBuffers;
    for (cmd_bufs, 0..) |cb, i| handles[i] = cb.handle;
    return handles[0..cmd_bufs.len];
}

// ── Handle types (opaque, mr_gpu style) ─────────────────────
// Handles are defined in their respective file-struct files.
// Gpu re-exports them via root.zig.

// Handle-based resource methods

pub fn shaderCreate(self: *Gpu, spv: []const u32, stage: ShaderStage, entry: [:0]const u8, name: [:0]const u8) !Shader {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    _ = name;
    const handle = try self.backend.shaderCreate(spv, @intFromEnum(stage), entry);
    return .{ .gpu = self, .handle = handle, .stage = stage };
}

pub fn shaderDestroy(self: *Gpu, shader: Shader) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.backend.shaderDestroy(shader.handle);
}

pub fn semaphoreCreate(self: *Gpu, initial: u64) !Semaphore {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    return .{ .gpu = self, .handle = try self.backend.semaphoreCreate(initial) };
}
pub fn semaphoreDestroy(self: *Gpu, sem: Semaphore) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.backend.semaphoreDestroy(sem.handle);
}

pub fn bufferCreate(self: *Gpu, desc: BufferDesc) !Buffer {
    const ptr = try self.gpuMalloc(desc.size, 64, .gpu);
    return .{ .gpu = self, .gpu_ptr = ptr };
}
pub fn bufferDestroy(self: *Gpu, buf: Buffer) void {
    self.gpuFree(buf.gpu_ptr);
}

pub fn textureSizeAndAlign(self: *Gpu, desc: TextureDesc) @TypeOf(self.backend.textureSizeAndAlign(desc)) {
    return self.backend.textureSizeAndAlign(desc);
}
pub fn textureCreate(self: *Gpu, desc: TextureDesc) !TextureHandle {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    return self.backend.textureCreate(desc, .{}, 0);
}
pub fn textureDestroy(self: *Gpu, tex: TextureHandle) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.backend.textureDestroy(tex);
}

pub fn textureViewDescriptor(self: *Gpu, tex: TextureHandle, view_desc: TextureViewDesc) u64 {
    return self.backend.textureViewDescriptor(tex, view_desc);
}
pub fn descHeapSetTexturesRw(self: *Gpu, heap: DescriptorHeap, start_idx: u32, descriptors: []const u64) void {
    self.backend.descHeapSetTexturesRw(heap.index, start_idx, descriptors);
}
pub fn descHeapSetTextures(self: *Gpu, heap: DescriptorHeap, start_idx: u32, descriptors: []const u64) void {
    self.backend.descHeapSetTextures(heap.index, start_idx, descriptors);
}
pub fn descHeapSetSamplers(self: *Gpu, heap: DescriptorHeap, start_idx: u32, descriptors: []const u64) void {
    self.backend.descHeapSetSamplers(heap.index, start_idx, descriptors);
}
pub fn textureRwViewDescriptor(self: *Gpu, tex: TextureHandle, view_desc: TextureViewDesc) u64 {
    return self.backend.textureRwViewDescriptor(tex, view_desc);
}
pub fn samplerDescriptor(self: *Gpu, desc: SamplerDesc) u64 {
    return self.backend.samplerDescriptor(desc);
}
pub fn semaphoreWait(self: *Gpu, sem: Semaphore, value: u64) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    try self.backend.semaphoreWait(sem.handle, value);
}

pub fn queueSubmit(self: *Gpu, cmd_bufs: []const CommandBuffer) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    var handles: [64]CommandBufferHandle = undefined;
    const copied_handles = try copyCommandBufferHandles(cmd_bufs, &handles);
    try self.backend.queueSubmit(copied_handles);
}

pub fn queueSubmitWaitSignal(
    self: *Gpu,
    cmd_bufs: []const CommandBuffer,
    wait_sem: Semaphore,
    wait_value: u64,
    signal_sem: Semaphore,
    signal_value: u64,
) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    var handles: [64]CommandBufferHandle = undefined;
    const copied_handles = try copyCommandBufferHandles(cmd_bufs, &handles);
    try self.backend.queueSubmitWaitSignal(
        copied_handles,
        wait_sem.handle,
        wait_value,
        signal_sem.handle,
        signal_value,
    );
}

pub fn descHeapCreate(self: *Gpu, texture_count: u32, texture_rw_count: u32, sampler_count: u32) !DescriptorHeap {
    const idx = try self.backend.descHeapCreate(texture_count, texture_rw_count, sampler_count);
    return .{ .index = idx };
}
pub fn descHeapDestroy(self: *Gpu, heap: DescriptorHeap) void {
    self.backend.descHeapDestroy(heap.index);
}
pub fn generateMipmaps(self: *Gpu, cmd: CommandBuffer, texture: Texture) void {
    // Ensure any prior writes to the texture are visible to the first blit
    self.backend.cmdBarrier(cmd.handle, .{ .transfer = true }, .{ .transfer = true }, .{});
    var mip: u32 = 1;
    while (mip < texture.mip_count) : (mip += 1) {
        if (mip > 1) {
            self.backend.cmdBarrier(cmd.handle, .{ .transfer = true }, .{ .transfer = true }, .{});
        }
        const src_rect: Texture.BlitRect = .{ .mip_level = mip - 1 };
        const dst_rect: Texture.BlitRect = .{ .mip_level = mip };
        self.backend.cmdBlitTexture(cmd.handle, texture.handle, dst_rect, texture.handle, src_rect, .linear);
    }
}

pub fn gpuMalloc(self: *Gpu, size: u64, alignment: u29, mem_type: MemoryType) GpuError!GpuPtr {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    if (self.backend.gpuMalloc(size, alignment, mem_type)) |ptr| return ptr else |_| return error.BackendError;
}
pub fn gpuFree(self: *Gpu, ptr: GpuPtr) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.backend.gpuFree(ptr);
}
pub fn gpuHostToDevicePointer(self: *Gpu, cpu_ptr: [*]u8) GpuPtr {
    return self.backend.gpuHostToDevicePointer(cpu_ptr);
}

pub fn instanceHandle(self: *const Gpu) vk.Instance {
    return self.backend.instance.handle;
}

// Basic types

pub const FrameSchedule = struct { next_vblank_us: u32, swapchain_recreated: bool };
pub const FrameResult = struct {
    gpu_blocked_ns: u64,
    present_out_of_date: bool = false,
};
pub const PresentInfo = struct {
    blit_to_swapchain: bool = true,
    timing_id: ?u64 = null,
};
pub const PresentFeedback = struct {
    present_id: u64,
    actual_present_ns: u64,
};

test "task4 FrameResult defaults to a normal present" {
    const result: FrameResult = .{ .gpu_blocked_ns = 0 };
    try std.testing.expect(!result.present_out_of_date);
}

test "task4 submission wrapper accepts 64 and rejects 65 command buffers" {
    var command_buffers: [65]CommandBuffer = undefined;
    for (&command_buffers, 0..) |*command_buffer, index| {
        command_buffer.* = .{
            .gpu = undefined,
            .handle = @enumFromInt(@as(u64, @intCast(index + 1))),
        };
    }

    var handles: [64]CommandBufferHandle = undefined;
    try std.testing.expectEqual(
        @as(usize, 64),
        (try copyCommandBufferHandles(command_buffers[0..64], &handles)).len,
    );
    try std.testing.expectError(
        error.TooManyCommandBuffers,
        copyCommandBufferHandles(command_buffers[0..65], &handles),
    );
}

test {
    std.testing.refAllDecls(@This());
}
