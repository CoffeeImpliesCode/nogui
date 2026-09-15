//! GPU memory arena — bump allocator atop a pre-allocated GpuPtr block.
//! Caller owns the allocation and must free it after arena destruction.
const std = @import("std");
const GpuPtr = @import("GpuPtr.zig");
const GpuSlice = @import("GpuPtr.zig").GpuSlice;
const GpuArena = @This();

base: GpuPtr = undefined,
offset: usize = 0,
size: usize = 0,

pub fn create(base: GpuPtr, size: usize) GpuArena {
    return .{ .base = base, .offset = 0, .size = size };
}

pub fn destroy(self: *GpuArena) void {
    self.* = undefined;
}

/// Bytes consumed by allocations so far (bump cursor).
pub fn used(self: *const GpuArena) usize {
    return self.offset;
}

/// Bytes left from the bump cursor to the end of the block.
pub fn remaining(self: *const GpuArena) usize {
    return self.size - self.offset;
}

/// Non-panicking bump allocation. Returns null when `size` bytes at
/// `alignment` do not fit; the arena is left unchanged.
pub fn tryAlloc(self: *GpuArena, size: usize, alignment: u29) ?GpuPtr {
    const aligned = std.mem.alignForward(usize, self.offset, alignment);
    const end = aligned + size;
    if (end > self.size) return null;
    self.offset = end;
    return self.base.offset(aligned);
}

/// Bump allocation. Panics when the request does not fit; use `tryAlloc`
/// for a nullable variant.
pub fn alloc(self: *GpuArena, size: usize, alignment: u29) GpuPtr {
    return self.tryAlloc(size, alignment) orelse @panic("GpuArena: allocation exceeds arena size");
}

/// Non-panicking typed bump allocation. Returns null when `count` elements
/// of `T` do not fit; the arena is left unchanged.
pub fn tryAllocT(self: *GpuArena, comptime T: type, count: usize) ?GpuSlice(T) {
    const byte_size = count * @sizeOf(T);
    const aligned = std.mem.alignForward(usize, self.offset, @alignOf(T));
    const end = aligned + byte_size;
    if (end > self.size) return null;
    self.offset = end;
    const base: [*]T = @ptrCast(@alignCast(self.base.cpu + aligned));
    return .{ .cpu = base[0..count], .gpu = self.base.gpu + @as(u64, @intCast(aligned)) };
}

/// Typed bump allocation. Panics when the request does not fit; use
/// `tryAllocT` for a nullable variant.
pub fn allocT(self: *GpuArena, comptime T: type, count: usize) GpuSlice(T) {
    return self.tryAllocT(T, count) orelse @panic("GpuArena: allocation exceeds arena size");
}

pub fn reset(self: *GpuArena) void {
    self.offset = 0;
}

test "GpuArena tryAlloc null past end" {
    var buf: [16]u8 = undefined;
    var arena = GpuArena.create(.{ .cpu = buf[0..].ptr, .gpu = 0x1000 }, buf.len);
    _ = arena.tryAlloc(16, 1) orelse return error.TestExpectedOk;
    try std.testing.expect(arena.tryAlloc(1, 1) == null);
    try std.testing.expect(arena.tryAllocT(u8, 1) == null);
    try std.testing.expectEqual(@as(usize, 16), arena.used());
}

test "GpuArena remaining+used invariant" {
    var buf: [64]u8 = undefined;
    var arena = GpuArena.create(.{ .cpu = buf[0..].ptr, .gpu = 0x1000 }, buf.len);
    try std.testing.expectEqual(@as(usize, 64), arena.remaining() + arena.used());
    _ = arena.alloc(8, 8);
    try std.testing.expectEqual(@as(usize, 64), arena.remaining() + arena.used());
    _ = arena.allocT(u32, 4);
    try std.testing.expectEqual(@as(usize, 64), arena.remaining() + arena.used());
}

test "GpuArena reset restores remaining" {
    var buf: [32]u8 = undefined;
    var arena = GpuArena.create(.{ .cpu = buf[0..].ptr, .gpu = 0x1000 }, buf.len);
    _ = arena.alloc(16, 8);
    try std.testing.expect(arena.remaining() < buf.len);
    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.used());
    try std.testing.expectEqual(@as(usize, buf.len), arena.remaining());
}

test {
    std.testing.refAllDecls(@This());
}
