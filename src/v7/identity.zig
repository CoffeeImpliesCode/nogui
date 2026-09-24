//! Persistent keyed widget identities, scoped by component paths.
const std = @import("std");
const ComponentId = @import("key.zig").ComponentId;
const ComponentKey = @import("key.zig").ComponentKey;
const WidgetId = @import("id.zig").WidgetId;

/// Owns keyed identities across successful frames. Failed frames only discard
/// staged mounts; live entries are marked by an epoch, not copied per frame.
pub const IdentityRegistry = struct {
    gpa: std.mem.Allocator,
    owner: u64,
    epoch: u64 = 0,
    in_frame: bool = false,

    components: std.ArrayListUnmanaged(ComponentEntry) = .empty,
    component_by_digest: std.AutoHashMapUnmanaged(ComponentId, u32) = .empty,
    live_components: std.ArrayListUnmanaged(u32) = .empty,
    free_component: ?u32 = null,
    staged_component: ?u32 = null,
    staged_component_count: usize = 0,

    widgets: std.ArrayListUnmanaged(WidgetEntry) = .empty,
    widget_by_digest: std.AutoHashMapUnmanaged(ComponentId, u32) = .empty,
    live_widgets: std.ArrayListUnmanaged(u32) = .empty,
    free_widget: ?u32 = null,
    staged_widget: ?u32 = null,
    staged_widget_count: usize = 0,

    pub const Error = error{
        DuplicateComponentIdentity,
        DuplicateWidgetKey,
        IdentityCollision,
        FrameAlreadyActive,
        FrameNotActive,
        IdentityExhausted,
    } || std.mem.Allocator.Error;

    pub fn init(gpa: std.mem.Allocator) IdentityRegistry {
        const nonce = next_owner.fetchAdd(1, .monotonic);
        if (nonce == 0 or nonce == std.math.maxInt(u64)) {
            @panic("identity registry owner exhausted");
        }
        return .{ .gpa = gpa, .owner = nonce };
    }

    pub fn deinit(self: *IdentityRegistry) void {
        if (self.in_frame) self.abortFrame();
        for (self.components.items) |entry| {
            if (entry.live) freeKey(self.gpa, entry.key);
        }
        for (self.widgets.items) |entry| {
            if (entry.live) freeKey(self.gpa, entry.key);
        }
        self.components.deinit(self.gpa);
        self.component_by_digest.deinit(self.gpa);
        self.live_components.deinit(self.gpa);
        self.widgets.deinit(self.gpa);
        self.widget_by_digest.deinit(self.gpa);
        self.live_widgets.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn beginFrame(self: *IdentityRegistry) Error!void {
        if (self.in_frame) return error.FrameAlreadyActive;
        if (self.epoch == std.math.maxInt(u64)) return error.IdentityExhausted;
        std.debug.assert(self.staged_component == null);
        std.debug.assert(self.staged_widget == null);
        self.epoch += 1;
        self.in_frame = true;
    }

    /// Register one exact path within its parent component scope.
    pub fn component(
        self: *IdentityRegistry,
        parent: ComponentId,
        key: ComponentKey,
    ) Error!ComponentId {
        if (!self.in_frame) return error.FrameNotActive;
        const digest = ComponentId.child(parent, key);
        if (std.meta.eql(digest, ComponentId.root)) return error.IdentityCollision;
        if (self.component_by_digest.get(digest)) |index| {
            const entry = &self.components.items[index];
            if (!std.meta.eql(entry.parent, parent) or !entry.key.eql(key)) {
                return error.IdentityCollision;
            }
            if (entry.seen_epoch == self.epoch) return error.DuplicateComponentIdentity;
            entry.seen_epoch = self.epoch;
            return digest;
        }

        try self.live_components.ensureUnusedCapacity(self.gpa, self.staged_component_count + 1);
        const owned_key = try copyKey(self.gpa, key);
        errdefer freeKey(self.gpa, owned_key);
        const reused = self.free_component != null;
        const index = try self.reserveComponent();
        errdefer self.undoComponentReservation(index, reused);
        try self.component_by_digest.put(self.gpa, digest, index);
        self.components.items[index] = .{
            .parent = parent,
            .key = owned_key,
            .digest = digest,
            .seen_epoch = self.epoch,
            .next = self.staged_component,
        };
        self.staged_component = index;
        self.staged_component_count += 1;
        return digest;
    }

    /// Reserve a stable handle in the component scope for this frame.
    pub fn widget(
        self: *IdentityRegistry,
        scope: ComponentId,
        key: ComponentKey,
    ) Error!WidgetId {
        if (!self.in_frame) return error.FrameNotActive;
        const digest = ComponentId.child(scope, key);
        if (self.widget_by_digest.get(digest)) |index| {
            const entry = &self.widgets.items[index];
            if (!std.meta.eql(entry.scope, scope) or !entry.key.eql(key)) {
                return error.IdentityCollision;
            }
            if (entry.seen_epoch == self.epoch) return error.DuplicateWidgetKey;
            entry.seen_epoch = self.epoch;
            return .{ .owner = self.owner, .slot = index, .generation = entry.generation };
        }

        try self.live_widgets.ensureUnusedCapacity(self.gpa, self.staged_widget_count + 1);
        const owned_key = try copyKey(self.gpa, key);
        errdefer freeKey(self.gpa, owned_key);
        const reused = self.free_widget != null;
        const index = try self.reserveWidget();
        errdefer self.undoWidgetReservation(index, reused);
        const generation: u32 = if (reused) self.widgets.items[index].generation else 1;
        try self.widget_by_digest.put(self.gpa, digest, index);
        self.widgets.items[index] = .{
            .scope = scope,
            .key = owned_key,
            .digest = digest,
            .generation = generation,
            .seen_epoch = self.epoch,
            .next = self.staged_widget,
        };
        self.staged_widget = index;
        self.staged_widget_count += 1;
        return .{ .owner = self.owner, .slot = index, .generation = generation };
    }

    /// Publish staged mounts, then retire only committed entries not seen.
    pub fn commitFrame(self: *IdentityRegistry) void {
        std.debug.assert(self.in_frame);

        var component_index: usize = 0;
        while (component_index < self.live_components.items.len) {
            const index = self.live_components.items[component_index];
            const entry = &self.components.items[index];
            if (entry.seen_epoch == self.epoch) {
                component_index += 1;
                continue;
            }
            const removed = self.component_by_digest.remove(entry.digest);
            std.debug.assert(removed);
            freeKey(self.gpa, entry.key);
            const removed_index = self.live_components.swapRemove(component_index);
            std.debug.assert(removed_index == index);
            entry.live = false;
            entry.next = self.free_component;
            self.free_component = index;
        }

        var staged_component = self.staged_component;
        while (staged_component) |index| {
            const entry = &self.components.items[index];
            staged_component = entry.next;
            entry.next = null;
            entry.live = true;
            self.live_components.appendAssumeCapacity(index);
        }
        self.staged_component = null;
        self.staged_component_count = 0;

        var widget_index: usize = 0;
        while (widget_index < self.live_widgets.items.len) {
            const index = self.live_widgets.items[widget_index];
            const entry = &self.widgets.items[index];
            if (entry.seen_epoch == self.epoch) {
                widget_index += 1;
                continue;
            }
            const removed = self.widget_by_digest.remove(entry.digest);
            std.debug.assert(removed);
            freeKey(self.gpa, entry.key);
            const removed_index = self.live_widgets.swapRemove(widget_index);
            std.debug.assert(removed_index == index);
            self.recycleWidget(index);
        }

        var staged_widget = self.staged_widget;
        while (staged_widget) |index| {
            const entry = &self.widgets.items[index];
            staged_widget = entry.next;
            entry.next = null;
            entry.live = true;
            self.live_widgets.appendAssumeCapacity(index);
        }
        self.staged_widget = null;
        self.staged_widget_count = 0;
        self.in_frame = false;
    }

    /// Leave all committed memberships and generations unchanged.
    pub fn abortFrame(self: *IdentityRegistry) void {
        std.debug.assert(self.in_frame);
        var staged_component = self.staged_component;
        while (staged_component) |index| {
            const entry = &self.components.items[index];
            staged_component = entry.next;
            const removed = self.component_by_digest.remove(entry.digest);
            std.debug.assert(removed);
            freeKey(self.gpa, entry.key);
            entry.next = self.free_component;
            self.free_component = index;
        }
        self.staged_component = null;
        self.staged_component_count = 0;

        var staged_widget = self.staged_widget;
        while (staged_widget) |index| {
            const entry = &self.widgets.items[index];
            staged_widget = entry.next;
            const removed = self.widget_by_digest.remove(entry.digest);
            std.debug.assert(removed);
            freeKey(self.gpa, entry.key);
            self.recycleWidget(index);
        }
        self.staged_widget = null;
        self.staged_widget_count = 0;
        self.in_frame = false;
    }

    /// Uncommitted reservations do not count as live.
    pub fn isLive(self: *const IdentityRegistry, id: WidgetId) bool {
        if (id.owner != self.owner) return false;
        if (@as(usize, id.slot) >= self.widgets.items.len) return false;
        const entry = self.widgets.items[id.slot];
        return entry.live and entry.generation == id.generation;
    }

    /// Find a committed component path without registering it for this frame.
    pub fn lookupComponent(
        self: *const IdentityRegistry,
        parent: ComponentId,
        key: ComponentKey,
    ) ?ComponentId {
        const digest = ComponentId.child(parent, key);
        const index = self.component_by_digest.get(digest) orelse return null;
        const entry = self.components.items[index];
        if (!entry.live) return null;
        if (!std.meta.eql(entry.parent, parent)) return null;
        if (!entry.key.eql(key)) return null;
        return digest;
    }

    /// Find a committed widget without marking it seen or changing its generation.
    pub fn lookupWidget(
        self: *const IdentityRegistry,
        scope: ComponentId,
        key: ComponentKey,
    ) ?WidgetId {
        const digest = ComponentId.child(scope, key);
        const index = self.widget_by_digest.get(digest) orelse return null;
        const entry = self.widgets.items[index];
        if (!entry.live) return null;
        if (!std.meta.eql(entry.scope, scope)) return null;
        if (!entry.key.eql(key)) return null;
        return .{ .owner = self.owner, .slot = index, .generation = entry.generation };
    }

    /// Resolve a reservation seen in the active frame without making it live.
    /// The caller must still resolve the returned handle in its candidate tree.
    pub fn lookupFrameWidget(
        self: *const IdentityRegistry,
        scope: ComponentId,
        key: ComponentKey,
    ) ?WidgetId {
        if (!self.in_frame) return null;
        const index = self.widget_by_digest.get(ComponentId.child(scope, key)) orelse return null;
        const entry = self.widgets.items[index];
        if (entry.seen_epoch != self.epoch) return null;
        if (!std.meta.eql(entry.scope, scope) or !entry.key.eql(key)) return null;
        return .{ .owner = self.owner, .slot = index, .generation = entry.generation };
    }

    fn reserveComponent(self: *IdentityRegistry) Error!u32 {
        if (self.free_component) |index| {
            self.free_component = self.components.items[index].next;
            return index;
        }
        if (self.components.items.len >= std.math.maxInt(u32)) return error.IdentityExhausted;
        const index: u32 = @intCast(self.components.items.len);
        // SAFETY: The caller fills this slot before publication; on failure
        // its errdefer removes the uninitialized tail without reading it.
        try self.components.append(self.gpa, undefined);
        return index;
    }

    fn undoComponentReservation(self: *IdentityRegistry, index: u32, reused: bool) void {
        if (reused) {
            self.components.items[index].next = self.free_component;
            self.free_component = index;
        } else {
            self.components.items.len -= 1;
        }
    }

    fn reserveWidget(self: *IdentityRegistry) Error!u32 {
        if (self.free_widget) |index| {
            self.free_widget = self.widgets.items[index].next;
            return index;
        }
        if (self.widgets.items.len >= std.math.maxInt(u32)) return error.IdentityExhausted;
        const index: u32 = @intCast(self.widgets.items.len);
        // SAFETY: The caller fills this slot before publication; on failure
        // its errdefer removes the uninitialized tail without reading it.
        try self.widgets.append(self.gpa, undefined);
        return index;
    }

    fn undoWidgetReservation(self: *IdentityRegistry, index: u32, reused: bool) void {
        if (reused) {
            self.widgets.items[index].next = self.free_widget;
            self.free_widget = index;
        } else {
            self.widgets.items.len -= 1;
        }
    }

    fn recycleWidget(self: *IdentityRegistry, index: u32) void {
        const entry = &self.widgets.items[index];
        entry.live = false;
        // A saturated generation is quarantined rather than wrapped into an old handle.
        if (entry.generation == std.math.maxInt(u32)) return;
        entry.generation += 1;
        entry.next = self.free_widget;
        self.free_widget = index;
    }
};

const ComponentEntry = struct {
    parent: ComponentId,
    key: ComponentKey,
    digest: ComponentId,
    seen_epoch: u64,
    live: bool = false,
    next: ?u32 = null,
};

const WidgetEntry = struct {
    scope: ComponentId,
    key: ComponentKey,
    digest: ComponentId,
    generation: u32,
    seen_epoch: u64,
    live: bool = false,
    next: ?u32 = null,
};

var next_owner: std.atomic.Value(u64) = .init(1);

fn copyKey(gpa: std.mem.Allocator, key: ComponentKey) std.mem.Allocator.Error!ComponentKey {
    return switch (key) {
        .static => |text| .{ .static = try gpa.dupe(u8, text) },
        .u64 => |value| .{ .u64 = value },
    };
}

fn freeKey(gpa: std.mem.Allocator, key: ComponentKey) void {
    switch (key) {
        .static => |text| gpa.free(text),
        .u64 => {},
    }
}

test "api-w02 identity survives sibling reordering and separates component scopes" {
    var registry = IdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.beginFrame();
    const one = try registry.component(.root, .{ .static = "one" });
    const two = try registry.component(.root, .{ .static = "two" });
    const a = try registry.widget(one, .{ .static = "a" });
    const b = try registry.widget(one, .{ .static = "b" });
    const scoped = try registry.widget(two, .{ .static = "a" });
    try std.testing.expect(!a.eql(scoped));
    try std.testing.expect(!registry.isLive(a));
    registry.commitFrame();

    try registry.beginFrame();
    try std.testing.expectEqual(one, try registry.component(.root, .{ .static = "one" }));
    try std.testing.expect(b.eql(try registry.widget(one, .{ .static = "b" })));
    try std.testing.expect(a.eql(try registry.widget(one, .{ .static = "a" })));
    try std.testing.expectEqual(two, try registry.component(.root, .{ .static = "two" }));
    try std.testing.expect(scoped.eql(try registry.widget(two, .{ .static = "a" })));
    registry.commitFrame();
    try std.testing.expect(registry.isLive(a));
    try std.testing.expect(registry.isLive(b));
    try std.testing.expect(registry.isLive(scoped));
}

test "api-w02 identity retires missing widgets and remounts with a fresh generation" {
    var registry = IdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.beginFrame();
    const old = try registry.widget(.root, .{ .u64 = 42 });
    registry.commitFrame();
    try std.testing.expect(registry.isLive(old));

    try registry.beginFrame();
    registry.commitFrame();
    try std.testing.expect(!registry.isLive(old));

    try registry.beginFrame();
    const aborted = try registry.widget(.root, .{ .u64 = 42 });
    registry.abortFrame();
    try std.testing.expect(!registry.isLive(aborted));

    try registry.beginFrame();
    const remount = try registry.widget(.root, .{ .u64 = 42 });
    registry.commitFrame();
    try std.testing.expect(!old.eql(remount));
    try std.testing.expect(!aborted.eql(remount));
    try std.testing.expect(!registry.isLive(old));
    try std.testing.expect(!registry.isLive(aborted));
    try std.testing.expect(registry.isLive(remount));
}

test "api-w02 identity rejects duplicate widget and component keys per frame" {
    var registry = IdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.beginFrame();
    const scope = try registry.component(.root, .{ .static = "panel" });
    try std.testing.expectError(error.DuplicateComponentIdentity, registry.component(
        .root,
        .{ .static = "panel" },
    ));
    const widget = try registry.widget(scope, .{ .u64 = 3 });
    try std.testing.expectError(error.DuplicateWidgetKey, registry.widget(scope, .{ .u64 = 3 }));
    try std.testing.expect(!registry.isLive(widget));
    registry.abortFrame();

    try registry.beginFrame();
    try std.testing.expectEqual(scope, try registry.component(.root, .{ .static = "panel" }));
    const fresh = try registry.widget(scope, .{ .u64 = 3 });
    registry.commitFrame();
    try std.testing.expect(!widget.eql(fresh));
}

test "api-w02 identity requires a single active frame" {
    var registry = IdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try std.testing.expectError(error.FrameNotActive, registry.widget(.root, .{ .u64 = 1 }));
    try registry.beginFrame();
    try std.testing.expectError(error.FrameAlreadyActive, registry.beginFrame());
    registry.abortFrame();
    try std.testing.expectError(
        error.FrameNotActive,
        registry.component(.root, .{ .static = "panel" }),
    );
}

test "api-w02 identity abort preserves committed widgets and discards new reservations" {
    var first = IdentityRegistry.init(std.testing.allocator);
    defer first.deinit();
    var second = IdentityRegistry.init(std.testing.allocator);
    defer second.deinit();

    try first.beginFrame();
    const scope = try first.component(.root, .{ .static = "screen" });
    const retained = try first.widget(scope, .{ .static = "retained" });
    first.commitFrame();
    try std.testing.expect(!second.isLive(retained));

    try first.beginFrame();
    try std.testing.expect(retained.eql(try first.widget(scope, .{ .static = "retained" })));
    const discarded = try first.widget(.root, .{ .static = "new" });
    first.abortFrame();
    try std.testing.expect(first.isLive(retained));
    try std.testing.expect(!first.isLive(discarded));

    try first.beginFrame();
    try std.testing.expectEqual(scope, try first.component(.root, .{ .static = "screen" }));
    try std.testing.expect(retained.eql(try first.widget(scope, .{ .static = "retained" })));
    const replacement = try first.widget(.root, .{ .static = "new" });
    first.commitFrame();
    try std.testing.expect(!discarded.eql(replacement));
    try std.testing.expect(first.isLive(retained));
    try std.testing.expect(first.isLive(replacement));
}

test "api-w02 identity owns component and widget key bytes beyond caller scratch" {
    var registry = IdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var component_bytes = [_]u8{ 'c', 'a', 'r', 'd' };
    var widget_bytes = [_]u8{ 's', 'a', 'v', 'e' };

    try registry.beginFrame();
    const scope = try registry.component(.root, .{ .static = &component_bytes });
    const saved = try registry.widget(scope, .{ .static = &widget_bytes });
    registry.commitFrame();
    component_bytes[0] = 'b';
    widget_bytes[0] = 'w';

    try registry.beginFrame();
    try std.testing.expectEqual(scope, try registry.component(.root, .{ .static = "card" }));
    try std.testing.expect(saved.eql(try registry.widget(scope, .{ .static = "save" })));
    registry.commitFrame();
    try std.testing.expect(registry.isLive(saved));
}

// Reverse the keyed digest to build distinct, exact paths with the same digest.
fn collidingParent(digest: ComponentId, key: ComponentKey) ComponentId {
    const hash = key.hash();
    const hi = reverseMixWord(digest.hi, hash) ^ 0x9e3779b97f4a7c15;
    const lo = reverseMixWord(digest.lo, hash ^ hi) ^ 0xc2b2ae3d27d4eb4f;
    return .{ .hi = hi, .lo = lo };
}

fn reverseMixWord(digest: u64, word: u64) u64 {
    var bits = word;
    var bytes: [8]u8 = undefined;
    for (&bytes) |*byte| {
        byte.* = @truncate(bits);
        bits >>= 8;
    }
    var hash = digest;
    var index: usize = bytes.len;
    while (index > 0) {
        index -= 1;
        hash = (hash *% 0xce965057aff6957b) ^ bytes[index];
    }
    return hash;
}

test "api-w02 identity rejects distinct paths with the same digest" {
    var registry = IdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const first_key: ComponentKey = .{ .u64 = 1 };
    const second_key: ComponentKey = .{ .u64 = 2 };
    const widget_scope = collidingParent(ComponentId.child(.root, first_key), second_key);
    try std.testing.expectEqual(
        ComponentId.child(.root, first_key),
        ComponentId.child(widget_scope, second_key),
    );

    try registry.beginFrame();
    _ = try registry.widget(.root, first_key);
    try std.testing.expectError(error.IdentityCollision, registry.widget(widget_scope, second_key));
    _ = try registry.component(.root, first_key);
    try std.testing.expectError(
        error.IdentityCollision,
        registry.component(widget_scope, second_key),
    );
    registry.abortFrame();
}

test "api-w02 committed lookup survives reorder, retirement, and a failed frame" {
    var registry = IdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const scope_key: ComponentKey = .{ .static = "panel" };
    const first_key: ComponentKey = .{ .static = "first" };
    const second_key: ComponentKey = .{ .static = "second" };

    try registry.beginFrame();
    const scope = try registry.component(.root, scope_key);
    const first = try registry.widget(scope, first_key);
    const second = try registry.widget(scope, second_key);
    try std.testing.expect(registry.lookupComponent(.root, scope_key) == null);
    try std.testing.expect(registry.lookupWidget(scope, first_key) == null);
    registry.commitFrame();
    try std.testing.expectEqual(
        @as(?ComponentId, scope),
        registry.lookupComponent(.root, scope_key),
    );
    try std.testing.expectEqual(@as(?WidgetId, first), registry.lookupWidget(scope, first_key));
    try std.testing.expect(registry.lookupWidget(.root, first_key) == null);

    // Equal digests must not let a different exact path find a live handle.
    const alternate_key: ComponentKey = .{ .u64 = 9 };
    const forged_scope = collidingParent(ComponentId.child(scope, first_key), alternate_key);
    try std.testing.expect(registry.lookupWidget(forged_scope, alternate_key) == null);
    const forged_parent = collidingParent(ComponentId.child(.root, scope_key), alternate_key);
    try std.testing.expect(registry.lookupComponent(forged_parent, alternate_key) == null);

    try registry.beginFrame();
    try std.testing.expectEqual(@as(?WidgetId, second), registry.lookupWidget(scope, second_key));
    try std.testing.expectEqual(scope, try registry.component(.root, scope_key));
    try std.testing.expect(second.eql(try registry.widget(scope, second_key)));
    try std.testing.expect(first.eql(try registry.widget(scope, first_key)));
    registry.commitFrame();

    try registry.beginFrame();
    const staged_scope = try registry.component(.root, .{ .static = "staged" });
    const staged = try registry.widget(staged_scope, .{ .static = "new" });
    try std.testing.expect(registry.lookupComponent(.root, .{ .static = "staged" }) == null);
    try std.testing.expect(registry.lookupWidget(staged_scope, .{ .static = "new" }) == null);
    try std.testing.expectEqual(@as(?WidgetId, first), registry.lookupWidget(scope, first_key));
    registry.abortFrame();
    try std.testing.expect(registry.lookupWidget(staged_scope, .{ .static = "new" }) == null);
    try std.testing.expect(!registry.isLive(staged));
    try std.testing.expectEqual(@as(?WidgetId, second), registry.lookupWidget(scope, second_key));

    try registry.beginFrame();
    try std.testing.expectEqual(scope, try registry.component(.root, scope_key));
    try std.testing.expect(first.eql(try registry.widget(scope, first_key)));
    registry.commitFrame();
    try std.testing.expect(registry.lookupWidget(scope, second_key) == null);
    try std.testing.expectEqual(@as(?WidgetId, first), registry.lookupWidget(scope, first_key));
}

test "api-w02 identity refuses a duplicate key instead of letting the later call win" {
    var registry = IdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.beginFrame();
    const scope = try registry.component(.root, .{ .static = "row" });
    try std.testing.expectError(
        error.DuplicateComponentIdentity,
        registry.component(.root, .{ .static = "row" }),
    );
    const first = try registry.widget(scope, .{ .static = "cell" });
    try std.testing.expectError(
        error.DuplicateWidgetKey,
        registry.widget(scope, .{ .static = "cell" }),
    );
    // The refusal published nothing: the first reservation is the only handle.
    try std.testing.expectEqual(
        @as(?WidgetId, first),
        registry.lookupFrameWidget(scope, .{ .static = "cell" }),
    );
    registry.commitFrame();

    try registry.beginFrame();
    try std.testing.expectEqual(scope, try registry.component(.root, .{ .static = "row" }));
    try std.testing.expect(first.eql(try registry.widget(scope, .{ .static = "cell" })));
    try std.testing.expectError(
        error.DuplicateWidgetKey,
        registry.widget(scope, .{ .static = "cell" }),
    );
    try std.testing.expectEqual(
        @as(?WidgetId, first),
        registry.lookupWidget(scope, .{ .static = "cell" }),
    );
    registry.commitFrame();
    try std.testing.expect(registry.isLive(first));
}

test "api-w02 identity refuses a forged scope that shares a committed widget digest" {
    var registry = IdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const real_key: ComponentKey = .{ .static = "cell" };
    const forged_key: ComponentKey = .{ .u64 = 77 };

    try registry.beginFrame();
    const scope = try registry.component(.root, .{ .static = "panel" });
    const real = try registry.widget(scope, real_key);
    registry.commitFrame();

    const forged_scope = collidingParent(ComponentId.child(scope, real_key), forged_key);
    try std.testing.expectEqual(
        ComponentId.child(scope, real_key),
        ComponentId.child(forged_scope, forged_key),
    );

    try registry.beginFrame();
    _ = try registry.component(.root, .{ .static = "panel" });
    _ = try registry.widget(scope, real_key);
    try std.testing.expectError(error.IdentityCollision, registry.widget(forged_scope, forged_key));
    registry.commitFrame();

    try std.testing.expect(registry.isLive(real));
    try std.testing.expect(registry.lookupWidget(forged_scope, forged_key) == null);
    try std.testing.expectEqual(@as(?WidgetId, real), registry.lookupWidget(scope, real_key));
}

test "api-w02 identity reuses a retired slot only at a strictly newer generation" {
    var registry = IdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.beginFrame();
    const first = try registry.widget(.root, .{ .static = "row" });
    registry.commitFrame();
    try std.testing.expect(registry.isLive(first));

    // A frame that never names the key retires it and returns its slot.
    try registry.beginFrame();
    registry.commitFrame();
    try std.testing.expect(!registry.isLive(first));

    try registry.beginFrame();
    const second = try registry.widget(.root, .{ .static = "other" });
    registry.commitFrame();
    try std.testing.expectEqual(first.slot, second.slot);
    try std.testing.expect(second.generation > first.generation);
    try std.testing.expect(!first.eql(second));
    try std.testing.expect(!registry.isLive(first));
    try std.testing.expect(registry.isLive(second));

    // The same slot cycling twice never hands the retired handle back.
    try registry.beginFrame();
    registry.commitFrame();
    try std.testing.expect(!registry.isLive(second));

    try registry.beginFrame();
    const third = try registry.widget(.root, .{ .static = "row" });
    registry.commitFrame();
    try std.testing.expectEqual(first.slot, third.slot);
    try std.testing.expect(third.generation > second.generation);
    try std.testing.expect(!first.eql(third));
    try std.testing.expect(!registry.isLive(first));
    try std.testing.expect(!registry.isLive(second));
    try std.testing.expect(registry.isLive(third));
}

test "api-w02 identity rejects a stale handle whose slot backs a live replacement" {
    var registry = IdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const stale_key: ComponentKey = .{ .static = "slot-a" };
    const replacement_key: ComponentKey = .{ .static = "slot-b" };

    try registry.beginFrame();
    const stale = try registry.widget(.root, stale_key);
    registry.commitFrame();

    try registry.beginFrame();
    registry.commitFrame();
    try std.testing.expect(!registry.isLive(stale));

    try registry.beginFrame();
    const replacement = try registry.widget(.root, replacement_key);
    registry.commitFrame();
    try std.testing.expectEqual(stale.slot, replacement.slot);
    try std.testing.expect(!stale.eql(replacement));

    // The slot is live again, yet the retired handle stays dead and its key
    // resolves to nothing rather than to the replacement.
    try std.testing.expect(!registry.isLive(stale));
    try std.testing.expect(registry.isLive(replacement));
    try std.testing.expect(registry.lookupWidget(.root, stale_key) == null);
    try std.testing.expectEqual(
        @as(?WidgetId, replacement),
        registry.lookupWidget(.root, replacement_key),
    );

    try registry.beginFrame();
    _ = try registry.widget(.root, replacement_key);
    try std.testing.expect(registry.lookupFrameWidget(.root, stale_key) == null);
    try std.testing.expectEqual(
        @as(?WidgetId, replacement),
        registry.lookupFrameWidget(.root, replacement_key),
    );
    registry.commitFrame();
    try std.testing.expect(!registry.isLive(stale));
}
