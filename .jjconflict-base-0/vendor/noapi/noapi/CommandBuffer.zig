//! Command buffer — GPU command recording.
const std = @import("std");
const Gpu = @import("Gpu.zig");
const TimestampQuerySet = @import("TimestampQuerySet.zig");
const SamplerDesc = @import("Texture.zig").SamplerDesc;
const tracy = @import("tracy");
const CommandBuffer = @This();

gpu: *Gpu,
handle: Gpu.CommandBufferHandle = .null_handle,

tex_heap: ?DescriptorHeap = null,
tex_count: u32 = 0,
tex_samp_count: u32 = 0,

pub const PushData = extern struct {
    vert_data: u64 = 0,
    frag_data: u64 = 0,
    indirect: u64 = 0,
    /// Framebuffer size (px) — the vertex shader's clip-space conversion
    /// (P2b: the 9-slice grid moves into the VS, which needs sw/sh).
    screen: [2]f32 = .{ 0, 0 },
    /// The drawable bag (the SceneRect array) — the VS reads rects
    /// through it after the CS1 permutation (V1b).
    scene_bda: u64 = 0,
    /// The sorted permutation (u32 bag indices, CS1's output) — the VS
    /// fetches bag[perm[instance / 9]] (V1b).
    perm_bda: u64 = 0,
};

pub const IndexFormat = enum(u32) {
    u16 = 0,
    u32 = 1,
    u8 = 1000265000,
    none = 1000165000,
};

pub const DrawIndexedIndirectCommand = extern struct {
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
    first_instance: u32,
};

pub const DispatchIndirectCommand = extern struct {
    num_groups_x: u32,
    num_groups_y: u32,
    num_groups_z: u32,
};

pub fn barrier(self: *CommandBuffer, before: Stage, after: Stage, hazards: Hazard) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdBarrier(self.handle, before, after, hazards);
}
pub fn timestampReset(
    self: *CommandBuffer,
    set: TimestampQuerySet.TimestampQuerySet,
    first: u32,
    count: u32,
) !void {
    try TimestampQuerySet.validateQueryRange(set.count, first, count);
    try self.gpu.backend.cmdTimestampReset(self.handle, set.handle, first, count);
}

pub fn timestampWrite(
    self: *CommandBuffer,
    set: TimestampQuerySet.TimestampQuerySet,
    index: u32,
    stage: TimestampQuerySet.TimestampStage,
) !void {
    if (index >= set.count) return error.InvalidTimestampRange;
    try self.gpu.backend.cmdTimestampWrite(self.handle, set.handle, index, stage);
}

/// Begin a Tracy GPU zone — recorded as a Vulkan timestamp query pair into
/// the current frame's query pool; shows as a span on the GPU track.
pub fn beginZone(self: *CommandBuffer, comptime loc: tracy.SourceLocation.InitOptions) void {
    self.gpu.backend.cmdBufBeginZone(self.handle, tracy.SourceLocation.init(loc));
}

/// End the most recently begun GPU zone on this command buffer.
pub fn endZone(self: *CommandBuffer) void {
    self.gpu.backend.cmdBufEndZone(self.handle);
}
pub fn draw(self: *CommandBuffer, data: PushData, vertex_count: u32, instance_count: u32) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdPushConstantsGraphics(self.handle, data);
    self.gpu.backend.cmdDraw(self.handle, vertex_count, instance_count);
}

pub fn drawIndexed(
    self: *CommandBuffer,
    data: PushData,
    indices: GpuPtr,
    format: IndexFormat,
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdPushConstantsGraphics(self.handle, data);
    self.gpu.backend.cmdBindIndexBuffer(self.handle, @enumFromInt(indices.vk_buffer), 0, format);
    self.gpu.backend.cmdDrawIndexed(self.handle, index_count, instance_count, first_index, vertex_offset);
}

pub fn drawIndexedIndirect(
    self: *CommandBuffer,
    data: PushData,
    indices: GpuPtr,
    format: IndexFormat,
    arguments: GpuPtr,
    max_draws: u32,
) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdPushConstantsGraphics(self.handle, data);
    self.gpu.backend.cmdBindIndexBuffer(self.handle, @enumFromInt(indices.vk_buffer), 0, format);
    self.gpu.backend.cmdDrawIndexedIndirect(
        self.handle,
        @enumFromInt(arguments.vk_buffer),
        0,
        max_draws,
        @sizeOf(DrawIndexedIndirectCommand),
    );
}

pub fn drawIndexedIndirectMulti(
    self: *CommandBuffer,
    data: PushData,
    indices: GpuPtr,
    format: IndexFormat,
    arguments: GpuPtr,
    stride: u32,
    count_buffer: GpuPtr,
    count_offset: u64,
    max_draws: u32,
) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdPushConstantsGraphics(self.handle, data);
    self.gpu.backend.cmdBindIndexBuffer(self.handle, @enumFromInt(indices.vk_buffer), 0, format);
    self.gpu.backend.cmdDrawIndexedIndirectMulti(
        self.handle,
        @enumFromInt(arguments.vk_buffer),
        0,
        stride,
        @enumFromInt(count_buffer.vk_buffer),
        count_offset,
        max_draws,
    );
}
pub fn dispatch(self: *CommandBuffer, data: u64, group_x: u32, group_y: u32, group_z: u32) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdPushConstantsCompute(self.handle, data);
    self.gpu.backend.cmdDispatch(self.handle, group_x, group_y, group_z);
}
pub fn dispatchIndirect(self: *CommandBuffer, data: u64, arguments: GpuPtr) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdPushConstantsCompute(self.handle, data);
    self.gpu.backend.cmdDispatchIndirect(self.handle, @enumFromInt(arguments.vk_buffer), 0);
}
pub fn bindIndexBuffer(self: *CommandBuffer, indices: GpuPtr, format: IndexFormat) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdBindIndexBuffer(self.handle, @enumFromInt(indices.vk_buffer), 0, format);
}
pub fn bindVertexBuffer(self: *CommandBuffer, binding: u32, buf: GpuPtr, offset: u64) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdBindVertexBuffer(self.handle, binding, @enumFromInt(buf.vk_buffer), offset);
}
pub fn setShaders(self: *CommandBuffer, vert: Shader, frag: Shader) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdSetShaders(self.handle, vert.handle, frag.handle);
}
pub fn setComputeShader(self: *CommandBuffer, shader: Shader) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdSetComputeShader(self.handle, shader.handle);
}
pub fn setDepthState(self: *CommandBuffer, state: DepthState) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdSetDepthState(self.handle, state);
}
pub fn setRasterState(self: *CommandBuffer, state: RasterState) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdSetRasterState(self.handle, state);
}
pub fn setBlendState(self: *CommandBuffer, state: BlendState) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdSetBlendState(self.handle, state);
}
pub fn setBlendEnable(self: *CommandBuffer, enable: bool) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdSetBlendEnable(self.handle, enable);
}
pub fn setViewport(self: *CommandBuffer, vp: Viewport) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdSetViewport(self.handle, vp);
}
pub fn setScissor(self: *CommandBuffer, sc: Scissor) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdSetScissor(self.handle, sc);
}
pub fn bindDescriptorSets(self: *CommandBuffer, heap: DescriptorHeap) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdBindDescriptorSets(self.handle, heap.index);
}
/// Bind a texture into this command buffer's private descriptor heap (slot 0-7; slot >= 8 ignored).
/// Creates the heap lazily on first use and binds it once. Call deinitTexHeap
/// before command buffer reuse or the heap leaks.
pub fn bindTexture(self: *CommandBuffer, slot: u32, texture: TextureHandle, sampler: ?SamplerDesc) void {
    if (slot >= 8) return;
    if (self.tex_heap == null) {
        self.tex_heap = self.gpu.descHeapCreate(8, 0, 8) catch return;
        self.tex_count = 0;
        self.tex_samp_count = 0;
        self.gpu.backend.cmdBindDescriptorSets(self.handle, self.tex_heap.?.index);
    }
    const heap = self.tex_heap.?;
    if (self.tex_count <= slot) self.tex_count = slot + 1;
    const tex_desc = self.gpu.textureViewDescriptor(texture, .{});
    self.gpu.descHeapSetTextures(heap, slot, &.{tex_desc});
    if (sampler) |s| {
        const samp_desc = self.gpu.samplerDescriptor(s);
        self.gpu.descHeapSetSamplers(heap, slot, &.{samp_desc});
        if (self.tex_samp_count <= slot) self.tex_samp_count = slot + 1;
    }
}
pub fn bindSampler(self: *CommandBuffer, slot: u32, sampler: SamplerDesc) void {
    if (slot >= 8) return;
    if (self.tex_heap == null) return;
    const heap = self.tex_heap.?;
    const samp_desc = self.gpu.samplerDescriptor(sampler);
    self.gpu.descHeapSetSamplers(heap, slot, &.{samp_desc});
    if (self.tex_samp_count <= slot) self.tex_samp_count = slot + 1;
}
/// Destroy this command buffer's private texture heap. Call before command buffer reuse.
pub fn deinitTexHeap(self: *CommandBuffer) void {
    if (self.tex_heap) |heap| {
        self.gpu.descHeapDestroy(heap);
        self.tex_heap = null;
    }
}
pub fn beginRendering(self: *CommandBuffer, desc: Rendering) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdBeginRendering(self.handle, desc);
}
pub fn endRendering(self: *CommandBuffer) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdEndRendering(self.handle);
}
pub fn memCopy(self: *CommandBuffer, dst: GpuPtr, src: GpuPtr, bytes: u64) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdMemCopy(self.handle, @enumFromInt(src.vk_buffer), @enumFromInt(dst.vk_buffer), bytes);
}
pub fn setVertexInput(self: *CommandBuffer, bindings: []const VertexBinding, attributes: []const VertexAttribute) void {
    self.gpu.backend.cmdSetVertexInput(self.handle, bindings, attributes);
}
pub fn copyToTexture(self: *CommandBuffer, tex: Texture, src: GpuPtr, region: TextureRegion) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdCopyToTexture(self.handle, tex.handle, @enumFromInt(src.vk_buffer), region);
}
pub fn copyFromTexture(self: *CommandBuffer, tex: Texture, dst: GpuPtr, region: TextureRegion) void {
    self.gpu.backend.cmdCopyFromTexture(self.handle, tex.handle, @enumFromInt(dst.vk_buffer), region);
}

pub fn blitTextureHandle(
    self: *CommandBuffer,
    dst: TextureHandle,
    dst_rect: BlitRect,
    src: TextureHandle,
    src_rect: BlitRect,
    filter: Filter,
) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdBlitTexture(self.handle, dst, dst_rect, src, src_rect, filter);
}
pub fn addWaitSemaphore(self: *CommandBuffer, window_index: u32, sem: Semaphore, value: u64) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdAddWaitSemaphore(window_index, sem.handle, value);
}
pub fn addSignalSemaphore(self: *CommandBuffer, window_index: u32, sem: Semaphore, value: u64) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.gpu.backend.cmdAddSignalSemaphore(window_index, sem.handle, value);
}
pub fn beginDebugLabel(self: *CommandBuffer, name: [:0]const u8, color: [4]f32) void {
    self.gpu.backend.cmdBeginDebugLabel(self.handle, name, color);
}
pub fn endDebugLabel(self: *CommandBuffer) void {
    self.gpu.backend.cmdEndDebugLabel(self.handle);
}
pub fn insertDebugLabel(self: *CommandBuffer, name: [:0]const u8, color: [4]f32) void {
    self.gpu.backend.cmdInsertDebugLabel(self.handle, name, color);
}

const Stage = @import("Barrier.zig").Stage;
const Hazard = @import("Barrier.zig").Hazard;
const Shader = @import("Shader.zig");
const Semaphore = @import("Semaphore.zig");
const DepthState = @import("DepthState.zig");
const RasterState = @import("RasterState.zig");
const BlendState = @import("BlendState.zig");
const Viewport = @import("Viewport.zig");
const Scissor = @import("Viewport.zig").Scissor;
const DescriptorHeap = @import("DescriptorHeap.zig");
const Rendering = @import("Rendering.zig");
const Texture = @import("Texture.zig");
const TextureRegion = @import("Texture.zig").TextureRegion;
const BlitRect = @import("Texture.zig").BlitRect;
const Filter = @import("Texture.zig").Filter;
const GpuPtr = @import("GpuPtr.zig");
const TextureHandle = @import("TextureHandle.zig");
const VertexBinding = @import("VertexInput.zig").VertexBinding;
const VertexAttribute = @import("VertexInput.zig").VertexAttribute;

test {
    std.testing.refAllDecls(@This());
}
