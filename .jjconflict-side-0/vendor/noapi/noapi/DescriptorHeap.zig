//! Descriptor heap — opaque handle to a GPU descriptor set group.
//! Created by Gpu.descHeapCreate, destroyed by Gpu.descHeapDestroy.
const std = @import("std");
const DescriptorHeap = @This();

index: u32 = 0, // index into VkBackend.desc_heaps pool

pub fn deinit(self: *DescriptorHeap) void {
    self.* = undefined;
}

pub const TextureDescriptor = u64;
pub const SamplerDescriptor = u64;

test {
    std.testing.refAllDecls(@This());
}
