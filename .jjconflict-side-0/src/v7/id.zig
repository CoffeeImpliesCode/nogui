//! v7 widget identity — components and widgets share one Id space.
//! Per the prototype spec (notes/v7-prototype-spec.md §1).
const std = @import("std");

pub const Id = enum(u32) {
    root = 0,
    _,

    pub fn index(self: Id) u32 {
        return @intFromEnum(self);
    }
};

test "Id: index round-trips" {
    const id: Id = @enumFromInt(7);
    try std.testing.expectEqual(@as(u32, 7), id.index());
}

test "Id: root is zero" {
    try std.testing.expectEqual(@as(u32, 0), Id.root.index());
}
