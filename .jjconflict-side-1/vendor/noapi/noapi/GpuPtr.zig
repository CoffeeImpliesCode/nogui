//! GPU-mappable pointer: {cpu VA, gpu VA}.
const std = @import("std");
const GpuPtr = @This();

cpu: [*]u8 = undefined,
gpu: u64 = 0,
vk_buffer: u64 = 0,

pub fn offset(self: GpuPtr, bytes: usize) GpuPtr {
    const b: u64 = @intCast(bytes);
    return .{ .cpu = self.cpu + bytes, .gpu = self.gpu + b };
}

pub fn GpuSlice(comptime T: type) type {
    return struct { cpu: []T, gpu: u64 };
}

pub fn memSuballoc(ptr: GpuPtr, comptime T: type, byte_offset: usize, count: usize) GpuSlice(T) {
    const off = ptr.offset(byte_offset);
    const ptr_t: [*]T = @ptrCast(@alignCast(off.cpu));
    return .{ .cpu = ptr_t[0..count], .gpu = off.gpu };
}

test "GpuPtr offset" {
    const p: GpuPtr = .{ .cpu = @ptrFromInt(0x1000), .gpu = 0x2000 };
    const off = p.offset(16);
    try std.testing.expect(@intFromPtr(off.cpu) == 0x1010);
    try std.testing.expect(off.gpu == 0x2010);
}

test "GpuPtr size" {
    try std.testing.expect(@sizeOf(GpuPtr) == 24);
}
