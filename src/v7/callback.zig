//! Comptime method → type-erased callback adapter.
//! Per the prototype spec (notes/v7-prototype-spec.md §3).
//!
//! User code never writes type-erased handlers: a plain method
//! `fn (*T) void` is wrapped here, and the `*anyopaque` argument is
//! supplied by the event system at dispatch time from the widget's
//! `owner` component id.
const std = @import("std");

/// Wrap any `fn (*T) void` into a type-erased callback.
pub fn wrap(comptime F: anytype) *const fn (*anyopaque) void {
    return struct {
        fn call(ptr: *anyopaque) void {
            const P = @typeInfo(@TypeOf(F)).@"fn".params[0].type.?;
            @call(.auto, F, .{@as(P, @ptrCast(@alignCast(ptr)))});
        }
    }.call;
}

test "wrap: invokes the method with the correct receiver" {
    const Counter = struct {
        const Self = @This();

        n: u32 = 0,

        fn bump(self: *Self) void {
            self.n += 1;
        }
    };

    var c: Counter = .{};
    const cb = wrap(Counter.bump);
    cb(@ptrCast(&c));
    try std.testing.expectEqual(@as(u32, 1), c.n);
    cb(@ptrCast(&c));
    try std.testing.expectEqual(@as(u32, 2), c.n);
}

test "wrap: two types get independent receivers" {
    const A = struct {
        const Self = @This();

        v: u32 = 0,
        fn inc(self: *Self) void {
            self.v += 1;
        }
    };
    const B = struct {
        const Self = @This();

        v: u32 = 0,
        fn inc(self: *Self) void {
            self.v += 10;
        }
    };

    var a: A = .{};
    var b: B = .{};
    const ca = wrap(A.inc);
    const cb = wrap(B.inc);
    ca(@ptrCast(&a));
    cb(@ptrCast(&b));
    cb(@ptrCast(&b));
    try std.testing.expectEqual(@as(u32, 1), a.v);
    try std.testing.expectEqual(@as(u32, 20), b.v);
}
