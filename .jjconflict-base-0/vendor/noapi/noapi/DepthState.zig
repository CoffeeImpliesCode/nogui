// zlint-disable unused-decls -- public API type, re-exported via root.zig
//! Depth-stencil state object.
const std = @import("std");
const DepthState = @This();

pub const CompareOp = enum(u3) {
    never = 0,
    less = 1,
    equal = 2,
    less_equal = 3,
    greater = 4,
    not_equal = 5,
    greater_equal = 6,
    always = 7,
};
pub const DepthMode = packed struct { read: bool = false, write: bool = false };

mode: DepthMode = .{},
compare: CompareOp = .less,

test {
    std.testing.refAllDecls(@This());
}
