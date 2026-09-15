// zlint-disable unused-decls -- public API type, re-exported via root.zig
//! Rasterization state object.
const std = @import("std");
const RasterState = @This();

pub const Topology = enum(u4) {
    point_list = 0,
    line_list = 1,
    line_strip = 2,
    triangle_list = 3,
    triangle_strip = 4,
    triangle_fan = 5,
    line_list_with_adjacency = 6,
    line_strip_with_adjacency = 7,
    triangle_list_with_adjacency = 8,
    triangle_strip_with_adjacency = 9,
    patch_list = 10,
};
pub const CullMode = enum(u2) {
    none = 0,
    front = 1,
    back = 2,
    all = 3,
};
pub const FrontFace = enum(u1) {
    counter_clockwise = 0,
    clockwise = 1,
};

topology: Topology = .triangle_list,
cull_mode: CullMode = .back,
front_face: FrontFace = .counter_clockwise,
alpha_to_coverage: bool = false,

test {
    std.testing.refAllDecls(@This());
}
