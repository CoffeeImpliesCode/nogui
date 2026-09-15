// zlint-disable unused-decls -- public API type, re-exported via root.zig
//! Single vertex format: position + UV + packed-color, 20 bytes.
const std = @import("std");
const Vertex = @This();

position: [2]f32 = .{ 0, 0 },
uv: [2]f32 = .{ 0, 0 },
color: [4]u8 = .{ 255, 255, 255, 255 },

test {
    std.testing.refAllDecls(@This());
}
