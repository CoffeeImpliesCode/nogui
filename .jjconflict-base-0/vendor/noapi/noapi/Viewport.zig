// zlint-disable unused-decls -- public API type, re-exported via root.zig
//! Viewport and scissor state.
const std = @import("std");
const Viewport = @This();

x: f32 = 0,
y: f32 = 0,
width: f32 = 800,
height: f32 = 600,
depth_min: f32 = 0,
depth_max: f32 = 1,

pub const Scissor = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 800,
    height: u32 = 600,
};

test {
    std.testing.refAllDecls(@This());
}
