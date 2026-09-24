//! Stable keyboard focus and per-pointer capture over committed frame trees.
//! No frame-local node ID survives a frame transition; every owner is a WidgetId.
const std = @import("std");
const FrameNodeId = @import("id.zig").FrameNodeId;
const WidgetId = @import("id.zig").WidgetId;
const WidgetTree = @import("widget.zig").WidgetTree;
const WidgetNode = @import("widget.zig").WidgetNode;
const input = @import("input.zig");
const event = @import("event.zig");

pub const TabStop = struct {
    /// Positive indices precede zero in ascending order; negative skips Tab.
    index: i32 = 0,
    group: u32 = 0,
};

/// Built-ins participate by default. Custom leaves opt in explicitly and
/// must have a stable key; an explicit false excludes even a built-in.
pub fn defaultDescribe(tree: *const WidgetTree, node: *const WidgetNode) ?TabStop {
    if (node.widget_id == null or node.rect.w <= 0 or node.rect.h <= 0) return null;
    if (!input.isEnabled(tree, node.id)) return null;
    const builtin = switch (node.kind) {
        .button, .slider, .checkbox, .switch_control, .radio => true,
        else => false,
    };
    if (!(node.interaction.focusable orelse builtin)) return null;
    return .{
        .index = node.interaction.tab_index orelse 0,
        .group = node.interaction.tab_group orelse 0,
    };
}

/// An optional per-App descriptor hook for kinds with external focus metadata.
/// Visibility, disabled ancestry, geometry and explicit focusable=false still
/// take precedence over the hook.
pub const Policy = struct {
    user: ?*anyopaque = null,
    describe: ?*const fn (*anyopaque, *const WidgetNode) ?TabStop = null,

    fn stop(self: Policy, tree: *const WidgetTree, node: *const WidgetNode) ?TabStop {
        if (self.describe) |describe| {
            if (node.widget_id == null or node.rect.w <= 0 or node.rect.h <= 0) return null;
            if (!input.isEnabled(tree, node.id)) return null;
            if (node.interaction.focusable == false) return null;
            const metadata = describe(self.user orelse return null, node) orelse return null;
            return .{
                .index = node.interaction.tab_index orelse metadata.index,
                .group = node.interaction.tab_group orelse metadata.group,
            };
        }
        return defaultDescribe(tree, node);
    }
};

pub const Direction = enum { forward, backward };
pub const Reason = enum { explicit, blur, tab, removed };
pub const Change = struct {
    previous: ?WidgetId,
    current: ?WidgetId,
    reason: Reason,
};

/// The event layer owns pointer identity; capture uses that exact type.
pub const PointerId = event.PointerId;
pub const Cancellation = struct { pointer: PointerId, target: WidgetId };
pub const Observer = struct {
    user: *anyopaque,
    on_focus: ?*const fn (*anyopaque, Change) void = null,
    on_cancel: ?*const fn (*anyopaque, Cancellation) void = null,
};
pub const Release = struct {
    target: ?WidgetId = null,
    /// True only for an enabled target released over its original stable ID.
    activate: bool = false,
};
const Capture = struct { pointer: PointerId, target: WidgetId };
const Candidate = struct { id: WidgetId, order: usize, rank: u32 };

pub const Manager = struct {
    /// This value may be read by paint; resolve it through the current tree.
    current: ?WidgetId = null,
    policy: Policy = .{},
    /// Fixed capacity bounds work and allocation across a frame boundary.
    captures: [16]?Capture = .{null} ** 16,

    pub const CaptureError = error{CaptureCapacityExceeded};

    /// Explicit focus accepts a negative tab index; traversal does not.
    pub fn set(
        self: *Manager,
        tree: *const WidgetTree,
        id: WidgetId,
        observer: ?Observer,
    ) bool {
        if (!self.eligible(tree, id)) return false;
        self.assign(id, .explicit, observer);
        return true;
    }

    pub fn blur(self: *Manager, observer: ?Observer) void {
        self.assign(null, .blur, observer);
    }

    /// Test whether the current focus lives at or below a dense tree node.
    pub fn contains(
        self: *const Manager,
        tree: *const WidgetTree,
        ancestor: FrameNodeId,
        id: WidgetId,
    ) bool {
        const current_id = self.current orelse return false;
        if (!current_id.eql(id)) return false;
        var node_id = tree.frameNode(id) orelse return false;
        if (!input.isEnabled(tree, node_id)) return false;
        if (ancestor == .root) return true;
        var remaining = tree.nodes.items.len;
        while (node_id != .root and remaining > 0) : (remaining -= 1) {
            if (node_id == ancestor) return true;
            node_id = (tree.nodeConst(node_id) orelse return false).parent;
        }
        return false;
    }

    /// Tab order uses positive indices, then index zero in frame order. A
    /// group filter constrains traversal without allocating/sorting a list.
    pub fn step(
        self: *Manager,
        tree: *const WidgetTree,
        direction: Direction,
        group: ?u32,
        observer: ?Observer,
    ) ?WidgetId {
        var active: ?Candidate = null;
        if (self.current) |id| {
            if (tree.frameNode(id)) |node_id| {
                if (tree.nodeIndex(node_id)) |order| {
                    const node = &tree.nodes.items[order];
                    if (self.policy.stop(tree, node)) |stop| {
                        if (stop.index >= 0 and (group == null or stop.group == group.?)) {
                            active = .{ .id = id, .order = order, .rank = tabRank(stop.index) };
                        }
                    }
                }
            }
        }
        var first: ?Candidate = null;
        var last: ?Candidate = null;
        var adjacent: ?Candidate = null;
        for (tree.nodes.items, 0..) |*node, order| {
            const stop = self.policy.stop(tree, node) orelse continue;
            if (stop.index < 0) continue;
            if (group) |selected| {
                if (stop.group != selected) continue;
            }
            const candidate: Candidate = .{
                .id = node.widget_id.?,
                .order = order,
                .rank = tabRank(stop.index),
            };
            if (first == null or before(candidate, first.?)) first = candidate;
            if (last == null or before(last.?, candidate)) last = candidate;
            if (active) |from| {
                switch (direction) {
                    .forward => {
                        if (before(from, candidate) and
                            (adjacent == null or before(candidate, adjacent.?))) adjacent = candidate;
                    },
                    .backward => {
                        if (before(candidate, from) and
                            (adjacent == null or before(adjacent.?, candidate))) adjacent = candidate;
                    },
                }
            }
        }
        const selected: Candidate = switch (direction) {
            .forward => if (adjacent) |next| next else first orelse return null,
            .backward => if (adjacent) |previous| previous else last orelse return null,
        };
        self.assign(selected.id, .tab, observer);
        return selected.id;
    }

    /// Capturing a repeated down does not replace its original target.
    pub fn press(
        self: *Manager,
        tree: *const WidgetTree,
        pointer: PointerId,
        target: WidgetId,
    ) CaptureError!bool {
        if (!enabled(tree, target)) return false;
        if (self.captureIndex(pointer) != null) return false;
        for (&self.captures) |*entry| {
            if (entry.* == null) {
                entry.* = .{ .pointer = pointer, .target = target };
                return true;
            }
        }
        return error.CaptureCapacityExceeded;
    }

    /// The original press target owns moves even when the pointer leaves its
    /// rectangle. An invalidated target emits one cancellation and retires.
    pub fn captured(
        self: *Manager,
        tree: *const WidgetTree,
        pointer: PointerId,
        observer: ?Observer,
    ) ?WidgetId {
        const slot = self.captureIndex(pointer) orelse return null;
        const target = self.captures[slot].?.target;
        if (enabled(tree, target)) return target;
        self.cancelSlot(slot, observer);
        return null;
    }

    /// A release clears capture even when it misses. Only a release over the
    /// original identity may activate, never a down, move or late touch end.
    pub fn release(
        self: *Manager,
        tree: *const WidgetTree,
        pointer: PointerId,
        release_hit: ?WidgetId,
        observer: ?Observer,
    ) Release {
        const slot = self.captureIndex(pointer) orelse return .{};
        const target = self.captures[slot].?.target;
        self.captures[slot] = null;
        if (!enabled(tree, target)) {
            notifyCancel(observer, .{ .pointer = pointer, .target = target });
            return .{};
        }
        const matching = if (release_hit) |hit| target.eql(hit) else false;
        return .{
            .target = target,
            .activate = matching and switch (pointer) {
                .mouse => |button| button == .left,
                .touch => true,
            },
        };
    }

    pub fn cancel(self: *Manager, pointer: PointerId, observer: ?Observer) void {
        const slot = self.captureIndex(pointer) orelse return;
        self.cancelSlot(slot, observer);
    }

    /// Call only after a successful frame, while the old tree is still live.
    /// Failed frame attempts leave focus and captures unchanged. Removed or
    /// disabled owners cancel; unchanged keyed owners survive any reorder.
    pub fn reconcile(
        self: *Manager,
        old_tree: ?*const WidgetTree,
        new_tree: *const WidgetTree,
        observer: ?Observer,
    ) void {
        for (&self.captures, 0..) |*entry, slot| {
            const capture = entry.* orelse continue;
            if (!enabled(new_tree, capture.target)) self.cancelSlot(slot, observer);
        }
        const focused = self.current orelse return;
        if (self.eligible(new_tree, focused)) return;
        const fallback = self.removalFallback(old_tree, new_tree, focused);
        self.assign(fallback, .removed, observer);
    }

    /// Root replacement revokes all captures before a new tree is published.
    pub fn reset(self: *Manager, observer: ?Observer) void {
        for (&self.captures, 0..) |*entry, slot| {
            if (entry.* != null) self.cancelSlot(slot, observer);
        }
        self.blur(observer);
    }

    fn assign(self: *Manager, next: ?WidgetId, reason: Reason, observer: ?Observer) void {
        const old = self.current;
        if (old == null and next == null) return;
        if (old != null and next != null and old.?.eql(next.?)) return;
        self.current = next;
        if (observer) |watch| {
            if (watch.on_focus) |callback| callback(watch.user, .{
                .previous = old,
                .current = next,
                .reason = reason,
            });
        }
    }

    fn eligible(self: *const Manager, tree: *const WidgetTree, id: WidgetId) bool {
        const node_id = tree.frameNode(id) orelse return false;
        const node = tree.nodeConst(node_id) orelse return false;
        return self.policy.stop(tree, node) != null;
    }

    fn removalFallback(
        self: *const Manager,
        old_tree: ?*const WidgetTree,
        new_tree: *const WidgetTree,
        removed: WidgetId,
    ) ?WidgetId {
        if (old_tree) |previous| {
            if (previous.frameNode(removed)) |node_id| {
                if (previous.nodeIndex(node_id)) |index| {
                    var offset: usize = 1;
                    while (offset < previous.nodes.items.len) : (offset += 1) {
                        const next_index = (index + offset) % previous.nodes.items.len;
                        const candidate = previous.nodes.items[next_index].widget_id orelse continue;
                        if (self.eligible(new_tree, candidate)) return candidate;
                    }
                }
            }
        }
        for (new_tree.nodes.items) |*node| {
            if (node.widget_id) |candidate| {
                if (self.eligible(new_tree, candidate)) return candidate;
            }
        }
        return null;
    }

    fn captureIndex(self: *const Manager, pointer: PointerId) ?usize {
        for (self.captures, 0..) |entry, slot| {
            if (entry) |capture| {
                if (std.meta.eql(capture.pointer, pointer)) return slot;
            }
        }
        return null;
    }

    fn cancelSlot(self: *Manager, slot: usize, observer: ?Observer) void {
        const capture = self.captures[slot] orelse return;
        self.captures[slot] = null;
        notifyCancel(observer, .{ .pointer = capture.pointer, .target = capture.target });
    }
};

fn enabled(tree: *const WidgetTree, target: WidgetId) bool {
    const node_id = tree.frameNode(target) orelse return false;
    return input.isEnabled(tree, node_id);
}

fn notifyCancel(observer: ?Observer, cancelled: Cancellation) void {
    if (observer) |watch| {
        if (watch.on_cancel) |callback| callback(watch.user, cancelled);
    }
}

fn tabRank(index: i32) u32 {
    return if (index == 0) std.math.maxInt(u32) else @intCast(index);
}

fn before(a: Candidate, b: Candidate) bool {
    return a.rank < b.rank or (a.rank == b.rank and a.order < b.order);
}
