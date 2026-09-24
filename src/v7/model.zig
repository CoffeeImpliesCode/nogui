//! Persistent model identities and explicit ownership tokens.
//!
//! Copying a strong handle copies its ticket bits, not its ownership. Call
//! `Session.retain` for an independent ticket; pass a strong handle by pointer
//! to `release` or `erase` to consume that ticket. Weak handles are copyable.
//!
//! A reservation is not a handle. It is a distinct type from `Model(T)` so
//! every strong-handle parameter rejects it at comptime; only `Session.insert`
//! or `Session.cancel` consumes one, and its weak view stays unreadable until
//! `insert` publishes the value.

pub const ModelKey = struct {
    store: u64 = 0,
    slot: u32 = 0,
    generation: u32 = 0,
};

pub fn Model(comptime T: type) type {
    return struct {
        const Self = @This();
        key: ModelKey = .{},
        ticket: u64 = 0,

        pub fn weak(self: Self) WeakModel(T) {
            return .{ .key = self.key };
        }

        /// Move this ownership ticket into a type-checked erased handle.
        pub fn erase(self: *Self) ErasedModel {
            const result: ErasedModel = .{
                .key = self.key,
                .ticket = self.ticket,
                .type_marker = marker(T),
            };
            self.* = .{};
            return result;
        }
    };
}

pub fn WeakModel(comptime T: type) type {
    return struct {
        const Self = @This();
        key: ModelKey = .{},

        pub fn erase(self: Self) ErasedWeakModel {
            return .{ .key = self.key, .type_marker = marker(T) };
        }
    };
}

pub fn Reservation(comptime T: type) type {
    return struct {
        const Self = @This();
        key: ModelKey = .{},
        ticket: u64 = 0,
        /// A reservation is a pre-publication token, never a value-bearing
        /// handle. This tag keeps `Reservation(T)` a type of its own instead of
        /// leaving the distinction to whatever the compiler infers for two
        /// equal layouts, so a reservation is rejected wherever a strong
        /// handle is required and only `insert`/`cancel` can consume one.
        pending: enum { reservation } = .reservation,

        pub fn weak(self: Self) WeakModel(T) {
            return .{ .key = self.key };
        }
    };
}

pub const ErasedModel = struct {
    key: ModelKey = .{},
    ticket: u64 = 0,
    type_marker: *const u8 = marker(void),
};

pub const ErasedWeakModel = struct {
    key: ModelKey = .{},
    type_marker: *const u8,
};

/// A mutable per-type symbol provides exact identity, even for equal-layout
/// structs. Its address is only compared; model data remains separately owned.
pub fn marker(comptime T: type) *const u8 {
    return &struct {
        const ModelType = T;
        var identity: u8 = 0;
    }.identity;
}
