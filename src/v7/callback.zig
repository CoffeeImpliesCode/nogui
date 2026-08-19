//! Comptime method → type-erased callback adapter.
//! Per the prototype spec (notes/v7-prototype-spec.md §3).
//!
//! User code never writes type-erased handlers: a plain method
//! `fn (*T) void` is wrapped here, and the `*anyopaque` argument is
//! supplied by the event system at dispatch time from the widget's
//! `owner` component id.
const std = @import("std");

/// A type-erased callback with a caller-owned integer payload.
pub const UserCallback = struct {
    invoke_fn: *const fn (*anyopaque, usize) void,
    user_data: usize,

    pub fn invoke(self: UserCallback, owner: *anyopaque) void {
        self.invoke_fn(owner, self.user_data);
    }
};

/// Bind a method taking a typed owner and an integer payload.
pub fn bind(comptime F: anytype, user_data: usize) UserCallback {
    const function_info = @typeInfo(@TypeOf(F)).@"fn";
    comptime {
        if (function_info.params.len != 2) {
            @compileError("callback.bind expects a function with two parameters");
        }
        const owner_type = function_info.params[0].type orelse
            @compileError("callback.bind owner parameter must have a type");
        if (@typeInfo(owner_type) != .pointer) {
            @compileError("callback.bind owner parameter must be a pointer");
        }
        const user_data_type = function_info.params[1].type orelse
            @compileError("callback.bind user-data parameter must have a type");
        if (user_data_type != usize and user_data_type != u32 and user_data_type != u64) {
            @compileError("callback.bind user-data must be usize, u32, or u64");
        }
    }

    return .{
        .invoke_fn = struct {
            fn invoke(owner: *anyopaque, data: usize) void {
                const owner_type = function_info.params[0].type.?;
                const user_data_type = function_info.params[1].type.?;
                const typed_owner: owner_type = @ptrCast(@alignCast(owner));
                const typed_data: user_data_type = @intCast(data);
                @call(.auto, F, .{ typed_owner, typed_data });
            }
        }.invoke,
        .user_data = user_data,
    };
}

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

test "UserCallback.invoke: forwards owner and user data" {
    const Counter = struct {
        value: usize = 0,
    };
    const invoke_fn = struct {
        fn invoke(owner: *anyopaque, user_data: usize) void {
            const counter: *Counter = @ptrCast(@alignCast(owner));
            counter.value = user_data;
        }
    }.invoke;

    var counter: Counter = .{};
    const user_callback: UserCallback = .{
        .invoke_fn = invoke_fn,
        .user_data = 41,
    };
    user_callback.invoke(@ptrCast(&counter));

    try std.testing.expectEqual(@as(usize, 41), counter.value);
}

test "bind: adapts usize u32 and u64 user data callbacks" {
    const Counter = struct {
        const Self = @This();

        usize_value: usize = 0,
        u32_value: u32 = 0,
        u64_value: u64 = 0,

        fn setUsize(self: *Self, value: usize) void {
            self.usize_value = value;
        }

        fn setU32(self: *Self, value: u32) void {
            self.u32_value = value;
        }

        fn setU64(self: *Self, value: u64) void {
            self.u64_value = value;
        }
    };

    var counter: Counter = .{};
    bind(Counter.setUsize, 11).invoke(@ptrCast(&counter));
    bind(Counter.setU32, 22).invoke(@ptrCast(&counter));
    bind(Counter.setU64, 33).invoke(@ptrCast(&counter));

    try std.testing.expectEqual(@as(usize, 11), counter.usize_value);
    try std.testing.expectEqual(@as(u32, 22), counter.u32_value);
    try std.testing.expectEqual(@as(u64, 33), counter.u64_value);
}
