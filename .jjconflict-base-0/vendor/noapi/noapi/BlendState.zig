// zlint-disable unused-decls -- public API type, re-exported via root.zig
//! Blend state object.
const std = @import("std");
const BlendState = @This();

pub const BlendOp = enum(u3) {
    add = 0,
    subtract = 1,
    reverse_subtract = 2,
    min = 3,
    max = 4,
};
pub const BlendFactor = enum(u4) {
    zero = 0,
    one = 1,
    src_color = 2,
    one_minus_src_color = 3,
    dst_color = 4,
    one_minus_dst_color = 5,
    src_alpha = 6,
    one_minus_src_alpha = 7,
    dst_alpha = 8,
    one_minus_dst_alpha = 9,
};

pub const ColorComponents = packed struct { r: bool = true, g: bool = true, b: bool = true, a: bool = true };

enable: bool = false,
color_op: BlendOp = .add,
src_color_factor: BlendFactor = .one,
dst_color_factor: BlendFactor = .zero,
alpha_op: BlendOp = .add,
src_alpha_factor: BlendFactor = .one,
dst_alpha_factor: BlendFactor = .zero,
color_write_mask: ColorComponents = .{},

test {
    std.testing.refAllDecls(@This());
}
