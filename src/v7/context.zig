//! The window identity and read-only model access available while drawing.
const Session = @import("session.zig").Session;
const model = @import("model.zig");
const Size = @import("widget.zig").Size;

pub const FrameInfo = struct {
    tick: u32,
    time_ms: u64,
    generation: u64,
    surface: Size,
};

pub const Context = struct {
    session: *Session,
    window: u64,
    root_model: ?model.ErasedWeakModel = null,

    pub fn root(self: *const Context, comptime T: type) !model.WeakModel(T) {
        const weak = self.root_model orelse return error.NoRootModel;
        return self.session.castWeak(T, weak);
    }

    /// Track this window only when its scoped borrow succeeds. The dependency
    /// publishes after its App commits the entire frame, not after draw alone.
    pub fn read(
        self: *const Context,
        comptime T: type,
        ref: anytype,
        user: anytype,
        comptime callback: anytype,
    ) !void {
        try self.session.readWindow(T, self.window, ref, user, callback);
    }

    /// Read a typed Session global with the same staged dependency semantics.
    pub fn global(
        self: *const Context,
        comptime T: type,
        user: anytype,
        comptime callback: anytype,
    ) !void {
        try self.session.readGlobalWindow(T, self.window, user, callback);
    }
};

test "root context checks type and invalidates weak identity after final release" {
    const std = @import("std");
    const First = struct { value: u8 };
    const Second = struct { value: u8 };
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var value: First = .{ .value = 8 };
    var owner = try session.create(First, &value);
    var context: Context = .{ .session = &session, .window = 1 };
    try std.testing.expectError(error.NoRootModel, context.root(First));
    context.root_model = owner.weak().erase();
    try std.testing.expectError(error.WrongType, context.root(Second));
    const weak = try context.root(First);
    try std.testing.expectEqual(owner.key.slot, weak.key.slot);
    try session.release(First, &owner);
    try std.testing.expectError(error.StaleModel, context.root(First));
}
