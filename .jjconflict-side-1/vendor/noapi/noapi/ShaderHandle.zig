// zlint-disable unused-decls -- public API type, re-exported via root.zig
//! Shader handle + stage enum.
const ShaderHandle = @This();

id: u32 = 0,
stage: ShaderStage = .vertex,

pub const ShaderStage = enum(u2) { vertex, fragment, compute };

const std = @import("std");
test {
    std.testing.refAllDecls(@This());
}
