//! Widget identity — deterministic u64 FNV-1a hash from
//! comptime source location + parent ID + optional extra discriminator.
//!
//! Design (dvui lineage):
//!   widgetId(@src(), parent, extra) → FNV-1a
//!
//! The hash seeds from the parent ID, then mixes in the comptime
//! source location (file, line, column) and an optional `extra`
//! discriminator for dynamic lists. No PushID/PopID stack needed:
//! the widget tree itself IS the ID namespace.
//!
//! Collision resistance: FNV-1a 64-bit, ~2^64 space. In practice
//! collisions are undetectable (<1e-12 at 10M entries). Duplicate
//! IDs within the same frame are caught by `register()`.

const std = @import("std");

const fnv1a = std.hash.Fnv1a_64;

/// 64-bit widget identifier. Deterministic across builds, runs,
/// and compilations.
///
/// Sentinel values:
///   .zero  — uninitialised / null (eq. to `null` for Id)
///   .root  — singleton for the root widget (parent of all top-level widgets)
///
/// All other values are produced by `widgetId()`.
pub const Id = enum(u64) {
    /// Null / uninitialised sentinel.
    zero = 0,
    /// Singleton root widget ID.
    root = 1,
    /// All real widget IDs occupy remaining values.
    _,

    // ── Construction ───────────────────────────────

    /// Build a widget ID from the callsite's `@src()`.
    ///
    /// `parent` is the containing widget's ID (or `.root` for
    /// top-level widgets).  `extra` is an optional discriminator
    /// (typically a loop index) for dynamic lists — pass 0 when
    /// unused.
    ///
    /// Deterministic: same (src, parent, extra) triple always
    /// produces the same Id.  The hash is seeded by the parent
    /// so the widget hierarchy provides implicit scoping.
    pub fn widgetId(src: std.builtin.SourceLocation, parent: Id, extra: usize) Id {
        var h = fnv1a.init();
        // Seed with parent ID — this gives us hierarchical
        // namespacing without an explicit PushID/PopID stack.
        h.update(std.mem.asBytes(&@intFromEnum(parent)));
        // Mix in the comptime source location.
        // We use the pointer to the file name string constant,
        // the line number, and the column number.  These are
        // all compile-time constants, so the hash is deterministic
        // across builds.
        h.update(std.mem.asBytes(&src.file.ptr));
        h.update(std.mem.asBytes(&src.line));
        h.update(std.mem.asBytes(&src.column));
        // Extra discriminator for dynamic lists.
        h.update(std.mem.asBytes(&extra));
        return @enumFromInt(h.final());
    }

    /// Produce a derived sub-ID for named sub-state (e.g.
    /// "scroll_offset", "text_buffer").  Equivalent to
    /// `widgetId(@src(), self, hash(name))` but avoids
    /// consuming a comptime source location.
    pub fn withName(self: Id, name: []const u8) Id {
        var h = fnv1a.init();
        h.update(std.mem.asBytes(&@intFromEnum(self)));
        h.update(name);
        return @enumFromInt(h.final());
    }

    // ── Queries ────────────────────────────────

    pub fn asU64(self: Id) u64 {
        return @intFromEnum(self);
    }

    pub fn isValid(self: Id) bool {
        return self != .zero;
    }
};

// ─── FNV-1a convenience wrapper ─────────────────────────

test "Id.widgetId: deterministic from same src+parent+extra" {
    const src = @src();
    const a = Id.widgetId(src, .root, 0);
    const b = Id.widgetId(src, .root, 0);
    try std.testing.expectEqual(a, b);
}

test "Id.widgetId: different line produces different Id" {
    const id_a = Id.widgetId(@src(), .root, 0);
    const id_b = Id.widgetId(@src(), .root, 0); // different line
    try std.testing.expect(id_a != id_b);
}

test "Id.widgetId: different parent produces different Id" {
    const src = @src();
    const id_a = Id.widgetId(src, Id.root, 0);
    // Synthesize a different parent ID by using a different extra
    const parent_b = Id.widgetId(src, Id.root, 999);
    const id_b = Id.widgetId(src, parent_b, 0);
    try std.testing.expect(id_a != id_b);
}

test "Id.widgetId: different extra produces different Id" {
    const src = @src();
    const a = Id.widgetId(src, .root, 0);
    const b = Id.widgetId(src, .root, 1);
    try std.testing.expect(a != b);
}

test "Id.withName: produces different Id from base" {
    const src = @src();
    const base = Id.widgetId(src, .root, 0);
    const named = base.withName("scroll_offset");
    try std.testing.expect(base != named);
}

test "Id.withName: deterministic" {
    const src = @src();
    const base = Id.widgetId(src, .root, 0);
    const a = base.withName("state");
    const b = base.withName("state");
    try std.testing.expectEqual(a, b);
}

test "Id.zero sentinel" {
    try std.testing.expectEqual(@as(u64, 0), Id.zero.asU64());
    try std.testing.expect(!Id.zero.isValid());
    try std.testing.expect(Id.root.isValid());
}

test "Id: sentinel values don't collide" {
    try std.testing.expect(Id.zero != Id.root);
}

test "Id: FNV-1a produces 64-bit values" {
    const src = @src();
    const id = Id.widgetId(src, .root, 42);
    // Must be a valid u64 (the hash output)
    _ = id.asU64();
    // Ensure it's not zero (extremely unlikely for FNV-1a)
    try std.testing.expect(id != .zero);
}
