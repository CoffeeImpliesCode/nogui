//! Typed globals live in the Session, not in either App frame arena.
const std = @import("std");

pub const Entry = struct {
    marker: *const u8,
    payload: *anyopaque,
    destroy: *const fn (*anyopaque, *anyopaque) void,
    readers: u32 = 0,
    writer: bool = false,
};

pub const Store = struct {
    entries: std.ArrayListUnmanaged(*Entry) = .empty,

    pub fn find(self: *const Store, marker: *const u8) ?*Entry {
        for (self.entries.items) |entry| {
            if (entry.marker == marker) return entry;
        }
        return null;
    }

    pub fn deinit(self: *Store, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
        self.* = undefined;
    }
};
