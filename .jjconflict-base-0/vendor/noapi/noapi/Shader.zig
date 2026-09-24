//! Shader — GPU shader object.
const std = @import("std");
const Io = std.Io;
const Gpu = @import("Gpu.zig");
const Shader = @This();

gpu: *Gpu,
handle: Gpu.ShaderHandle = .null_handle,
stage: ShaderStage = .vertex,

pub const ShaderStage = enum(u2) {
    vertex,
    fragment,
    compute,
};

pub fn create(gpu: *Gpu, spv: []const u32, stage: ShaderStage, entry: [:0]const u8, name: [:0]const u8) !Shader {
    const handle = try gpu.backend.shaderCreate(spv, @intFromEnum(stage), entry);
    if (comptime @hasDecl(@TypeOf(gpu.backend.*), "setDebugName")) {
        gpu.backend.setDebugName(.shader_ext, @intFromEnum(handle), name);
    }
    return .{ .gpu = gpu, .handle = handle, .stage = stage };
}

pub fn createFromPath(
    alloc: std.mem.Allocator,
    io: Io,
    gpu: *Gpu,
    spirv_path: []const u8,
    stage: ShaderStage,
    entry: [:0]const u8,
    name: [:0]const u8,
) !Shader {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, spirv_path, alloc, .unlimited);
    defer alloc.free(bytes);
    const spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, bytes));
    return create(gpu, spirv, stage, entry, name);
}

pub fn destroy(self: *const Shader) void {
    self.gpu.backend.shaderDestroy(self.handle);
}

test {
    std.testing.refAllDecls(@This());
}
