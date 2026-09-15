// zlint-disable unused-decls -- public API type, re-exported via root.zig
//! 2D extent — width × height.
const std = @import("std");
const Extent2D = @This();

width: u32 = 0,
height: u32 = 0,

test {
    std.testing.refAllDecls(@This());
}
