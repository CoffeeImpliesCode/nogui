//! v7 transient state — per-component inter-frame state (useState-like),
//! stored ENTIRELY in the frame arenas.
//!
//! The double-buffered arenas do the persistence: the previous frame's T
//! still lives in the other arena while the current frame builds, so
//! `ctx.state(T, name, init)` can copy the last version after validating its
//! metadata. The per-frame directory maps a component key and full state name
//! to a typed storage header. The directory itself is arena-allocated and
//! swapped:
//!
//!   - component live last frame -> the new frame copy is seeded from the
//!     previous frame's pointer (the "last version").
//!   - component new or unmounted -> seeded from `init`.
//!   - same component, same name, twice in ONE frame -> the SAME copy (the
//!     first call's mutations survive).
//!
//! An unmounted component needs no explicit prune: it is simply absent from
//! the current frame's directory, so when it reappears the "previous frame"
//! directory no longer mentions it and it starts from init again.
//!
//! The hashed key keeps lookup cheap; each entry also owns the full name so a
//! hash collision cannot merge two logical state values.
//!
//! T is shallow-copied. It is not deinitialized or owned by StateDir. Do not
//! put resource ownership here; use a Session model for persistent resources.
//! Any borrowed pointer or slice inside T must remain valid for the current
//! and previous readable frames, including a failed build attempt.

const std = @import("std");

const ComponentId = @import("key.zig").ComponentId;

/// Store key: the owning component's stable identity + a hash of its local
/// state name.
pub const Key = struct {
    component: ComponentId,
    name_hash: u64,

    pub fn eql(a: Key, b: Key) bool {
        return std.meta.eql(a.component, b.component) and a.name_hash == b.name_hash;
    }
};

pub fn hashName(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0, name);
}

/// Metadata and the type tag are validated before any pointer reconstruction
/// or value copy. This keeps type erasure local to the directory boundary.
pub const Error = error{StateTypeMismatch} || std.mem.Allocator.Error;

/// A distinct marker is emitted for every monomorphized T. The anchor field
/// keeps equal-layout types distinct while the marker address is allocation-
/// free and stable for the lifetime of the process.
fn TypeTag(comptime T: type) type {
    return struct {
        type_anchor: *const T,
        var marker: u8 = 0;
    };
}

fn typeTag(comptime T: type) *const anyopaque {
    return @ptrCast(&TypeTag(T).marker);
}

const StateHeader = struct {
    name: []const u8,
    type_tag: *const anyopaque,
    value_size: usize,
    value_alignment: usize,

    fn init(comptime T: type, name: []const u8) StateHeader {
        return .{
            .name = name,
            .type_tag = typeTag(T),
            .value_size = @sizeOf(T),
            .value_alignment = @alignOf(T),
        };
    }

    fn matchesType(self: StateHeader, comptime T: type) bool {
        if (self.type_tag != typeTag(T)) return false;
        if (self.value_size != @sizeOf(T)) return false;
        if (self.value_alignment != @alignOf(T)) return false;
        return true;
    }

    fn asValue(self: *StateHeader, comptime T: type) error{StateTypeMismatch}!*T {
        if (!self.matchesType(T)) return error.StateTypeMismatch;
        const storage: *StateStorage(T) = @fieldParentPtr("header", self);
        return &storage.value;
    }

    fn asValueConst(
        self: *const StateHeader,
        comptime T: type,
    ) error{StateTypeMismatch}!*const T {
        if (!self.matchesType(T)) return error.StateTypeMismatch;
        const storage: *const StateStorage(T) = @fieldParentPtr("header", self);
        return &storage.value;
    }
};

fn StateStorage(comptime T: type) type {
    return struct {
        header: StateHeader,
        value: T,
    };
}

const StateRef = struct {
    key: Key,
    header: *StateHeader,
};

/// Per-frame directory of live state values. Entries and their storage belong
/// to the frame arena. The full name, exact type tag, size, and alignment make
/// typed recovery independent of hash uniqueness and validate it first.
pub const StateDir = struct {
    entries: std.ArrayList(StateRef) = .empty,

    pub const empty: StateDir = .{ .entries = .empty };

    pub fn deinit(self: *StateDir, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    fn find(self: *const StateDir, key: Key, name: []const u8) ?*const StateRef {
        for (self.entries.items) |*state_ref| {
            if (!state_ref.key.eql(key)) continue;
            if (std.mem.eql(u8, state_ref.header.name, name)) return state_ref;
        }
        return null;
    }

    pub fn getOrCreate(
        self: *StateDir,
        comptime T: type,
        arena: std.mem.Allocator,
        previous: ?*const StateDir,
        key: Key,
        name: []const u8,
        init: T,
    ) Error!*T {
        if (self.find(key, name)) |state_ref| {
            return state_ref.header.asValue(T);
        }

        var previous_value: ?*const T = null;
        if (previous) |previous_dir| {
            if (previous_dir.find(key, name)) |state_ref| {
                previous_value = try state_ref.header.asValueConst(T);
            }
        }

        try self.entries.ensureUnusedCapacity(arena, 1);
        const owned_name = try arena.dupe(u8, name);
        const storage = try arena.create(StateStorage(T));
        storage.* = .{
            .header = .init(T, owned_name),
            .value = if (previous_value) |value| value.* else init,
        };
        self.entries.appendAssumeCapacity(.{
            .key = key,
            .header = &storage.header,
        });
        return &storage.value;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "StateDir: compatible retrieval preserves pointer identity and mutations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var current: StateDir = .empty;
    defer current.deinit(arena.allocator());
    const key: Key = .{ .component = ComponentId.root, .name_hash = hashName("count") };

    const first = try current.getOrCreate(u32, arena.allocator(), null, key, "count", 1);
    first.* = 7;
    const second = try current.getOrCreate(u32, arena.allocator(), null, key, "count", 99);

    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(u32, 7), second.*);
    try testing.expectEqual(@as(usize, 1), current.entries.items.len);
}

test "StateDir: component-local keys keep equal names independent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var current: StateDir = .empty;
    defer current.deinit(arena.allocator());
    const name = "count";
    const name_hash = hashName(name);
    const child = ComponentId.child(ComponentId.root, .{ .static = "child" });
    const root_key: Key = .{ .component = ComponentId.root, .name_hash = name_hash };
    const child_key: Key = .{ .component = child, .name_hash = name_hash };

    const root_value = try current.getOrCreate(
        u32,
        arena.allocator(),
        null,
        root_key,
        name,
        1,
    );
    const child_value = try current.getOrCreate(
        u32,
        arena.allocator(),
        null,
        child_key,
        name,
        2,
    );

    try testing.expect(root_value != child_value);
    try testing.expectEqual(@as(u32, 1), root_value.*);
    try testing.expectEqual(@as(u32, 2), child_value.*);
}

test "StateDir: previous frame seeds a typed current-frame copy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var previous: StateDir = .empty;
    defer previous.deinit(arena.allocator());
    var current: StateDir = .empty;
    defer current.deinit(arena.allocator());
    const key: Key = .{ .component = ComponentId.root, .name_hash = hashName("value") };

    const stored = try previous.getOrCreate(u32, arena.allocator(), null, key, "value", 1);
    stored.* = 42;
    const copy = try current.getOrCreate(
        u32,
        arena.allocator(),
        &previous,
        key,
        "value",
        0,
    );

    try testing.expect(copy != stored);
    try testing.expectEqual(@as(u32, 42), copy.*);
}

test "StateDir: equal-layout and previous-frame type mismatches are rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var previous: StateDir = .empty;
    defer previous.deinit(arena.allocator());
    var current: StateDir = .empty;
    defer current.deinit(arena.allocator());
    const key: Key = .{ .component = ComponentId.root, .name_hash = hashName("value") };

    _ = try previous.getOrCreate(u32, arena.allocator(), null, key, "value", 7);
    try testing.expectError(
        error.StateTypeMismatch,
        previous.getOrCreate(f32, arena.allocator(), null, key, "value", 0),
    );
    try testing.expectError(
        error.StateTypeMismatch,
        current.getOrCreate(u64, arena.allocator(), &previous, key, "value", 0),
    );
    try testing.expectEqual(@as(usize, 0), current.entries.items.len);
}

test "StateDir: same-frame type mismatches reject without replacing storage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var current: StateDir = .empty;
    defer current.deinit(arena.allocator());
    const key: Key = .{ .component = ComponentId.root, .name_hash = hashName("value") };

    const value = try current.getOrCreate(u32, arena.allocator(), null, key, "value", 7);
    try testing.expectError(
        error.StateTypeMismatch,
        current.getOrCreate(f32, arena.allocator(), null, key, "value", 0),
    );
    const value_again = try current.getOrCreate(u32, arena.allocator(), null, key, "value", 0);

    try testing.expectEqual(value, value_again);
    try testing.expectEqual(@as(usize, 1), current.entries.items.len);
}

test "StateDir: stored size and alignment metadata are validated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var current: StateDir = .empty;
    defer current.deinit(arena.allocator());
    const key: Key = .{ .component = ComponentId.root, .name_hash = hashName("value") };

    _ = try current.getOrCreate(u32, arena.allocator(), null, key, "value", 7);
    const header = current.entries.items[0].header;
    header.value_size += 1;
    try testing.expectError(
        error.StateTypeMismatch,
        current.getOrCreate(u32, arena.allocator(), null, key, "value", 0),
    );
    header.value_size = @sizeOf(u32);
    header.value_alignment += 1;
    try testing.expectError(
        error.StateTypeMismatch,
        current.getOrCreate(u32, arena.allocator(), null, key, "value", 0),
    );
}

test "StateDir: full names disambiguate a forced hash collision" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var current: StateDir = .empty;
    defer current.deinit(arena.allocator());
    const colliding_key: Key = .{ .component = ComponentId.root, .name_hash = 1 };

    const alpha = try current.getOrCreate(
        u32,
        arena.allocator(),
        null,
        colliding_key,
        "alpha",
        11,
    );
    const beta = try current.getOrCreate(
        u32,
        arena.allocator(),
        null,
        colliding_key,
        "beta",
        22,
    );

    const alpha_again = try current.getOrCreate(
        u32,
        arena.allocator(),
        null,
        colliding_key,
        "alpha",
        99,
    );
    try testing.expectEqual(alpha, alpha_again);
    try testing.expectEqual(@as(u32, 11), alpha_again.*);
    try testing.expect(alpha != beta);
    try testing.expectEqual(@as(u32, 11), alpha.*);
    try testing.expectEqual(@as(u32, 22), beta.*);
    try testing.expectEqual(@as(usize, 2), current.entries.items.len);
}
