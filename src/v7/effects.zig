//! Persistent FIFO effects; frame arenas never own these records or payloads.
const std = @import("std");
const model = @import("model.zig");
const subscription = @import("subscription.zig");

pub const Payload = struct {
    ptr: *anyopaque,
    destroy: *const fn (*anyopaque, *anyopaque) void,

    pub fn drop(self: Payload, session: *anyopaque) void {
        self.destroy(self.ptr, session);
    }
};

pub const Event = struct {
    source: model.ErasedWeakModel,
    marker: *const u8,
    payload: Payload,
};

pub const Deferred = struct {
    owner: model.ErasedWeakModel,
    strong_owner: ?model.ErasedModel = null,
    payload: Payload,
    invoke: subscription.Handler,
};
pub const Effect = union(enum) {
    changed: model.ErasedWeakModel,
    released: model.ErasedWeakModel,
    global_changed: *const u8,
    event: Event,
    deferred: Deferred,

    pub fn drop(self: Effect, session: *anyopaque) void {
        switch (self) {
            .event => |event| event.payload.drop(session),
            .deferred => |deferred| deferred.payload.drop(session),
            else => {},
        }
    }
};

/// `head` advances while callbacks append at the tail. The active effect is
/// copied before a callback may reallocate `items`; reset only after draining.
pub const Queue = struct {
    items: std.ArrayListUnmanaged(Effect) = .empty,
    head: usize = 0,
    draining: bool = false,

    pub fn deinit(self: *Queue, gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
        self.* = undefined;
    }
};
