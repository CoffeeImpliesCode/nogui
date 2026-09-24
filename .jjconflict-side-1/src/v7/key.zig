//! Stable component keys and hierarchical identities.
const std = @import("std");

pub const ComponentKey = union(enum) {
    static: []const u8,
    u64: u64,

    pub fn hash(self: ComponentKey) u64 {
        var h: u64 = 0xcbf29ce484222325;
        switch (self) {
            .static => |text| {
                h = mix(h, 0);
                for (text) |byte| h = mix(h, byte);
            },
            .u64 => |value| {
                h = mix(h, 1);
                var bits = value;
                for (0..8) |_| {
                    h = mix(h, @truncate(bits));
                    bits >>= 8;
                }
            },
        }
        return h;
    }
};

pub const ComponentId = struct {
    hi: u64,
    lo: u64,

    pub const root: ComponentId = .{
        .hi = 0x6e6f6775692d7637,
        .lo = 0x726f6f742d6b6579,
    };

    pub fn child(parent: ComponentId, key: ComponentKey) ComponentId {
        const key_hash = key.hash();
        return .{
            .hi = mixWord(parent.hi ^ 0x9e3779b97f4a7c15, key_hash),
            .lo = mixWord(parent.lo ^ 0xc2b2ae3d27d4eb4f, key_hash ^ parent.hi),
        };
    }
};

fn mix(hash: u64, byte: u8) u64 {
    return (hash ^ byte) *% 0x100000001b3;
}

fn mixWord(seed: u64, word: u64) u64 {
    var hash = seed;
    var bits = word;
    for (0..8) |_| {
        hash = mix(hash, @truncate(bits));
        bits >>= 8;
    }
    return hash;
}

test "component identity is stable across equal keys" {
    const a = ComponentId.child(.root, .{ .static = "volume" });
    const b = ComponentId.child(.root, .{ .static = "volume" });
    try std.testing.expectEqual(a, b);
}

test "component identity distinguishes parent and key" {
    const root_child = ComponentId.child(.root, .{ .u64 = 7 });
    const nested = ComponentId.child(root_child, .{ .u64 = 7 });
    const other_key = ComponentId.child(.root, .{ .u64 = 8 });
    try std.testing.expect(!std.meta.eql(root_child, nested));
    try std.testing.expect(!std.meta.eql(root_child, other_key));
}
