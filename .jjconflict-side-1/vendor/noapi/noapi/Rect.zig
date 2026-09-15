// zlint-disable unused-decls -- public API type, re-exported via root.zig
//! Integer 2D rectangle.
const std = @import("std");
const Rect = @This();

x: i32 = 0,
y: i32 = 0,
w: u32 = 0,
h: u32 = 0,

test {
    std.testing.refAllDecls(@This());
}
