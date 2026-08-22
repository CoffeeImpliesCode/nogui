//! v7 transient state — per-component inter-frame state (useState-like),
//! stored ENTIRELY in the frame arenas.
//!
//! The double-buffered arenas do the persistence: the previous frame's T
//! still lives in the other arena while the current frame builds, so
//! `ctx.state(name, T, init)` can memcpy the last version straight out of
//! it. The only bookkeeping is a per-frame directory of (key -> pointer)
//! entries — itself arena-allocated, swapped like the arenas:
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
//! Keys are (component identity, name hash): the name is component-local,
//! and only the hash is stored — the name slice never outlives its frame.

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

/// One live state value: where the caller's *T lives (a frame arena) and
/// its key. The pointer stays valid as long as its arena does.
pub const StateRef = struct {
    key: Key,
    ptr: *anyopaque,
};

/// Per-frame directory of live state values. Allocated from the frame
/// arena by App; the App swaps `state_prev` to it at the end of the frame,
/// so next frame's state() can seed from these pointers while the arena is
/// still alive.
pub const StateDir = std.ArrayList(StateRef);

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// Scan a directory for the first ref matching `key`.
fn find(dir: *const StateDir, key: Key) ?*anyopaque {
    for (dir.items) |sr| {
        if (sr.key.eql(key)) return sr.ptr;
    }
    return null;
}

test "StateDir: same key twice in one frame resolves to the same pointer" {
    var dir: StateDir = .empty;
    defer dir.deinit(testing.allocator);
    const key: Key = .{ .component = ComponentId.root, .name_hash = 7 };

    var a: u32 = 0;
    var b: u32 = 0;
    try dir.append(testing.allocator, .{ .key = key, .ptr = &a });
    try dir.append(testing.allocator, .{ .key = key, .ptr = &b });

    // The FIRST ref wins — a later state() call in the same frame must
    // return the same copy, not a second one.
    try testing.expectEqual(@as(*anyopaque, @ptrCast(&a)), find(&dir, key).?);
    try testing.expectEqual(@as(usize, 2), dir.items.len);
}

test "StateDir: keys are component-local — same name, different components, no clash" {
    var dir: StateDir = .empty;
    defer dir.deinit(testing.allocator);
    const name_hash = hashName("count");

    const component_a: Key = .{ .component = ComponentId.root, .name_hash = name_hash };
    const child_identity = ComponentId.child(ComponentId.root, .{ .static = "child" });
    const component_b: Key = .{ .component = child_identity, .name_hash = name_hash };
    var a: u32 = 1;
    var b: u32 = 2;
    try dir.append(testing.allocator, .{ .key = component_a, .ptr = &a });
    try dir.append(testing.allocator, .{ .key = component_b, .ptr = &b });

    try testing.expectEqual(@as(*anyopaque, @ptrCast(&a)), find(&dir, component_a).?);
    try testing.expectEqual(@as(*anyopaque, @ptrCast(&b)), find(&dir, component_b).?);
    const missing = ComponentId.child(ComponentId.root, .{ .static = "missing" });
    try testing.expectEqual(
        @as(?*anyopaque, null),
        find(&dir, .{ .component = missing, .name_hash = name_hash }),
    );
}

test "StateDir: seeding copies the previous frame's bytes" {
    var prev: StateDir = .empty;
    defer prev.deinit(testing.allocator);
    const key: Key = .{ .component = ComponentId.root, .name_hash = 9 };

    var stored: f32 = 2.5;
    try prev.append(testing.allocator, .{ .key = key, .ptr = &stored });

    // The previous frame's pointer still lives (its arena is double-
    // buffered), so a fresh copy seeds from it byte-for-byte.
    var copy: f32 = 0;
    const found = find(&prev, key).?;
    @memcpy(std.mem.asBytes(&copy), @as([*]const u8, @ptrCast(found))[0..@sizeOf(f32)]);
    try testing.expectEqual(@as(f32, 2.5), copy);
}
