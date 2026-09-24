//! Type-erased weak owner binding shared by the notification and credential
//! services.
//!
//! A native callback may arrive long after the model that asked for it was
//! dropped. The host stores only this borrowed identity plus a liveness probe;
//! every delivery re-checks liveness, so a delayed action for a dead owner is
//! dropped instead of resurrecting a dead `Session`.
//!
//! The probe must be cheap, must not retain or resurrect the owner, and must
//! be callable from the host thread that pumps completions. A v7 owner binds
//! it by upgrading its weak model key against the live `Session`.
const std = @import("std");

pub const WeakOwner = struct {
    context: ?*const anyopaque = null,
    is_alive_fn: ?*const fn (context: *const anyopaque) bool = null,

    /// An unbound owner. Every delivery to it is dropped.
    pub fn none() WeakOwner {
        return .{};
    }

    /// True when the owner is still live. A missing probe with a present
    /// context means the host vouches for the owner for the process lifetime.
    pub fn isAlive(self: WeakOwner) bool {
        const context = self.context orelse return false;
        const check = self.is_alive_fn orelse return true;
        return check(context);
    }
};

test "api-w19 unbound weak owner is never alive" {
    try std.testing.expect(!WeakOwner.none().isAlive());
}

test "api-w19 weak owner probe observes owner release" {
    const Owner = struct {
        const Self = @This();

        alive: bool = true,
        fn probe(context: *const anyopaque) bool {
            const self: *const Self = @ptrCast(@alignCast(context));
            return self.alive;
        }
    };

    var owner: Owner = .{};
    const bound: WeakOwner = .{ .context = &owner, .is_alive_fn = Owner.probe };
    try std.testing.expect(bound.isAlive());
    owner.alive = false;
    try std.testing.expect(!bound.isAlive());
}
