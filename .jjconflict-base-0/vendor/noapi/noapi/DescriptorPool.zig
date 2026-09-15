//! Descriptor pool — freelist allocator for descriptor heap slots.
//! Wraps a single DescriptorHeap created at init time.
//! Per-type freelists for textures, textures_rw, and samplers.
const std = @import("std");
const Gpu = @import("Gpu.zig");
const DescriptorHeap = @import("DescriptorHeap.zig");
const TextureHandle = @import("TextureHandle.zig");
const TextureType = @import("Texture.zig").TextureType;

const log = std.log.scoped(.desc_pool);

const DescriptorPool = @This();

gpu: *Gpu,
heap: DescriptorHeap,
texture_freelist: std.ArrayList(u32),
texture_rw_freelist: std.ArrayList(u32),
sampler_freelist: std.ArrayList(u32),
texture_count: u32,
texture_rw_count: u32,
sampler_count: u32,

/// Create a descriptor pool with per-type capacity.
/// Internally creates a DescriptorHeap via gpu.descHeapCreate.
pub fn init(gpu: *Gpu, texture_count: u32, texture_rw_count: u32, sampler_count: u32) !DescriptorPool {
    const heap = try gpu.descHeapCreate(texture_count, texture_rw_count, sampler_count);
    return .{
        .gpu = gpu,
        .heap = heap,
        .texture_freelist = .empty,
        .texture_rw_freelist = .empty,
        .sampler_freelist = .empty,
        .texture_count = 0,
        .texture_rw_count = 0,
        .sampler_count = 0,
    };
}

/// Destroy the pool, freeing the underlying descriptor heap and freelists.
pub fn deinit(self: *DescriptorPool) void {
    self.gpu.descHeapDestroy(self.heap);
    const allocator = self.gpu.backend.allocator;
    self.texture_freelist.deinit(allocator);
    self.texture_rw_freelist.deinit(allocator);
    self.sampler_freelist.deinit(allocator);
    self.* = undefined;
}

/// Allocate a texture+sampler slot. Pops from freelist if available,
/// otherwise bumps the counter. Writes both descriptors to the heap.
pub fn allocTexture(self: *DescriptorPool, texture: TextureHandle, sampler: u64, view_type: TextureType) u32 {
    const idx = if (self.texture_freelist.pop()) |i| i else blk: {
        const i = self.texture_count;
        self.texture_count += 1;
        break :blk i;
    };
    const tex_desc = self.gpu.textureViewDescriptor(texture, .{ .type = view_type });
    if (tex_desc == 0) {
        log.err("textureViewDescriptor returned 0 for texture {} — createImageView may have failed", .{texture});
    }
    self.gpu.descHeapSetTextures(self.heap, idx, &.{tex_desc});
    self.gpu.descHeapSetSamplers(self.heap, idx, &.{sampler});
    return idx;
}

/// Allocate a storage texture slot. Pops from freelist if available,
/// otherwise bumps the counter. Writes the RW descriptor to the heap.
pub fn allocTextureRw(self: *DescriptorPool, texture: TextureHandle, view_type: TextureType) u32 {
    const idx = if (self.texture_rw_freelist.pop()) |i| i else blk: {
        const i = self.texture_rw_count;
        self.texture_rw_count += 1;
        break :blk i;
    };
    const tex_desc = self.gpu.textureRwViewDescriptor(texture, .{ .type = view_type });
    self.gpu.descHeapSetTexturesRw(self.heap, idx, &.{tex_desc});
    return idx;
}

/// Allocate a sampler-only slot. Pops from freelist if available,
/// otherwise bumps the counter. Writes the sampler descriptor to the heap.
pub fn allocSampler(self: *DescriptorPool, sampler: u64) u32 {
    const idx = if (self.sampler_freelist.pop()) |i| i else blk: {
        const i = self.sampler_count;
        self.sampler_count += 1;
        break :blk i;
    };
    self.gpu.descHeapSetSamplers(self.heap, idx, &.{sampler});
    return idx;
}

/// Return a texture slot to the freelist for reuse.
pub fn freeTexture(self: *DescriptorPool, idx: u32) void {
    const allocator = self.gpu.backend.allocator;
    self.texture_freelist.append(allocator, idx) catch |err| log.warn("freeTexture: append failed: {}", .{err});
}

/// Return a storage texture slot to the freelist for reuse.
pub fn freeTextureRw(self: *DescriptorPool, idx: u32) void {
    const allocator = self.gpu.backend.allocator;
    self.texture_rw_freelist.append(allocator, idx) catch |err| log.warn("freeTextureRw: append failed: {}", .{err});
}

/// Return a sampler slot to the freelist for reuse.
pub fn freeSampler(self: *DescriptorPool, idx: u32) void {
    const allocator = self.gpu.backend.allocator;
    self.sampler_freelist.append(allocator, idx) catch |err| log.warn("freeSampler: append failed: {}", .{err});
}

/// Reset all freelists and counters. Does not destroy the underlying heap.
pub fn freeAll(self: *DescriptorPool) void {
    self.texture_freelist.clearRetainingCapacity();
    self.texture_rw_freelist.clearRetainingCapacity();
    self.sampler_freelist.clearRetainingCapacity();
    self.texture_count = 0;
    self.texture_rw_count = 0;
    self.sampler_count = 0;
}

test {
    std.testing.refAllDecls(@This());
}
