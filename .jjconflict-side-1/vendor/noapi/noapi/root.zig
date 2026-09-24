//! noapi — Vulkan access library

pub const vk = @import("vk.zig");
pub const tracy = @import("tracy");

pub const Extent2D = @import("Extent2D.zig");
pub const DeviceLimits = @import("DeviceLimits.zig");
pub const GpuPtr = @import("GpuPtr.zig");
pub const GpuSlice = @import("GpuPtr.zig").GpuSlice;
pub const memSuballoc = @import("GpuPtr.zig").memSuballoc;
pub const TextureHandle = @import("TextureHandle.zig");
pub const ShaderHandle = @import("ShaderHandle.zig");
pub const ShaderStage = @import("ShaderHandle.zig").ShaderStage;
pub const Rect = @import("Rect.zig");
pub const Vertex = @import("Vertex.zig");
pub const GpuError = @import("GpuError.zig").GpuError;
pub const MemoryType = @import("GpuError.zig").MemoryType;
pub const PushData = @import("CommandBuffer.zig").PushData;
pub const IndexFormat = @import("CommandBuffer.zig").IndexFormat;
pub const DrawIndexedIndirectCommand = @import("CommandBuffer.zig").DrawIndexedIndirectCommand;
pub const DispatchIndirectCommand = @import("CommandBuffer.zig").DispatchIndirectCommand;
pub const GpuArena = @import("GpuArena.zig");
pub const DescriptorHeap = @import("DescriptorHeap.zig");
pub const DescriptorPool = @import("DescriptorPool.zig");
pub const TextureDescriptor = @import("DescriptorHeap.zig").TextureDescriptor;
pub const SamplerDescriptor = @import("DescriptorHeap.zig").SamplerDescriptor;
pub const Stage = @import("Barrier.zig").Stage;
pub const Hazard = @import("Barrier.zig").Hazard;
pub const Shader = @import("Shader.zig");
pub const Semaphore = @import("Semaphore.zig");
pub const Queue = @import("Queue.zig");
pub const Texture = @import("Texture.zig");
pub const TextureDesc = @import("Texture.zig").TextureDesc;
pub const TextureType = @import("Texture.zig").TextureType;
pub const TextureFormat = @import("Texture.zig").TextureFormat;
pub const TextureUsage = @import("Texture.zig").TextureUsage;
pub const TextureViewDesc = @import("Texture.zig").TextureViewDesc;
pub const TextureRegion = @import("Texture.zig").TextureRegion;
pub const BlitRect = @import("Texture.zig").BlitRect;
pub const SamplerDesc = @import("Texture.zig").SamplerDesc;
pub const Filter = @import("Texture.zig").Filter;
pub const AddressMode = @import("Texture.zig").AddressMode;

pub const Buffer = @import("Buffer.zig");
pub const DepthState = @import("DepthState.zig");
pub const CompareOp = @import("DepthState.zig").CompareOp;
pub const RasterState = @import("RasterState.zig");
pub const Topology = @import("RasterState.zig").Topology;
pub const CullMode = @import("RasterState.zig").CullMode;
pub const BlendState = @import("BlendState.zig");
pub const BlendOp = @import("BlendState.zig").BlendOp;
pub const BlendFactor = @import("BlendState.zig").BlendFactor;
pub const Viewport = @import("Viewport.zig");
pub const Scissor = @import("Viewport.zig").Scissor;
pub const LoadOp = @import("Rendering.zig").LoadOp;
pub const StoreOp = @import("Rendering.zig").StoreOp;
pub const RenderingAttachment = @import("Rendering.zig").RenderingAttachment;
pub const Rendering = @import("Rendering.zig");
pub const Surface = @import("Surface.zig");
pub const VkBackend = @import("VkBackend.zig").VkBackend;
pub const Gpu = @import("Gpu.zig").Gpu;
pub const FrameSchedule = @import("Gpu.zig").FrameSchedule;
pub const FrameResult = @import("Gpu.zig").FrameResult;
pub const PresentInfo = @import("Gpu.zig").PresentInfo;
pub const PresentFeedback = @import("Gpu.zig").PresentFeedback;
pub const TimestampStage = @import("TimestampQuerySet.zig").TimestampStage;
pub const TimestampInfo = @import("TimestampQuerySet.zig").TimestampInfo;
pub const TimestampQuerySet = @import("TimestampQuerySet.zig").TimestampQuerySet;
pub const validateTimestampQueryRange = @import("TimestampQuerySet.zig").validateQueryRange;
pub const CommandBuffer = @import("CommandBuffer.zig");
pub const VertexBinding = @import("VertexInput.zig").VertexBinding;
pub const VertexAttribute = @import("VertexInput.zig").VertexAttribute;

test "task4 timestamp masks and modular spans cover 1 32 and 64 valid bits" {
    const one_bit: TimestampInfo = .{ .period_ns = 1.0, .valid_bits = 1 };
    try std.testing.expectEqual(@as(u64, 0x1), one_bit.mask());
    try std.testing.expectEqual(@as(u64, 1), one_bit.spanTicks(1, 0));

    const thirty_two_bit: TimestampInfo = .{ .period_ns = 1.0, .valid_bits = 32 };
    try std.testing.expectEqual(@as(u64, 0xffff_ffff), thirty_two_bit.mask());
    try std.testing.expectEqual(@as(u64, 3), thirty_two_bit.spanTicks(0xffff_fffe, 1));

    const sixty_four_bit: TimestampInfo = .{ .period_ns = 1.0, .valid_bits = 64 };
    try std.testing.expectEqual(std.math.maxInt(u64), sixty_four_bit.mask());
    try std.testing.expectEqual(
        @as(u64, 3),
        sixty_four_bit.spanTicks(std.math.maxInt(u64) - 1, 1),
    );
}

test "task4 timestamp query spans reject zero overflow and out of range" {
    try std.testing.expectError(error.InvalidTimestampRange, validateTimestampQueryRange(4, 0, 0));
    try std.testing.expectError(
        error.InvalidTimestampRange,
        validateTimestampQueryRange(4, std.math.maxInt(u32), 2),
    );
    try std.testing.expectError(error.InvalidTimestampRange, validateTimestampQueryRange(4, 3, 2));
    try validateTimestampQueryRange(4, 1, 3);
}

const std = @import("std");
test {
    std.testing.refAllDecls(@This());
}
