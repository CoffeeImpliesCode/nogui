//! Sparse variable-height list geometry. Fenwick buckets exist only for measured items.
const std = @import("std");
const uniform = @import("uniform_list.zig");

pub const Keys = uniform.Keys;
pub const Item = uniform.Item;
pub const Range = uniform.Range;
pub const Anchor = uniform.Anchor;
pub const Reveal = uniform.Reveal;
pub const FocusChange = uniform.FocusChange;
pub const FocusPolicy = uniform.FocusPolicy;
pub const RemovedFocus = uniform.RemovedFocus;
pub const Options = struct {
    count: usize,
    estimated_height: f64,
    viewport_height: f64,
    overdraw_items: usize = 1,
    focus_policy: FocusPolicy = .blur_when_unbuilt,
    removed_focus: RemovedFocus = .blur,
};
pub const Error = uniform.Error || error{
    OutOfMemory,
    RevisionConflict,
    EstimateRevisionConflict,
    MutationNotReported,
};

const Measured = struct {
    key: u64,
    height: f64,
    revision: u64,
};
const Heights = std.AutoHashMapUnmanaged(usize, Measured);
const Buckets = std.AutoHashMapUnmanaged(usize, f64);

pub const State = struct {
    allocator: std.mem.Allocator,
    count: usize,
    estimated_height: f64,
    estimate_revision: u64 = 0,
    viewport_height: f64,
    overdraw_items: usize,
    offset: f64 = 0,
    anchor: ?Anchor = null,
    end_follow: bool = false,
    focus_policy: FocusPolicy,
    removed_focus: RemovedFocus,
    focused: ?Anchor = null,
    focus_change: ?FocusChange = null,
    extent: f64,
    measured: Heights = .empty,
    buckets: Buckets = .empty,

    pub fn init(allocator: std.mem.Allocator, options: Options) Error!State {
        const extent = try uniform.checkedExtent(options.count, options.estimated_height);
        try uniform.checkViewport(options.viewport_height);
        return .{
            .allocator = allocator,
            .count = options.count,
            .estimated_height = options.estimated_height,
            .viewport_height = options.viewport_height,
            .overdraw_items = options.overdraw_items,
            .focus_policy = options.focus_policy,
            .removed_focus = options.removed_focus,
            .extent = extent,
        };
    }

    pub fn deinit(self: *State) void {
        self.measured.deinit(self.allocator);
        self.buckets.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn measuredCount(self: *const State) usize {
        return self.measured.count();
    }

    /// Fenwick memory grows with measured records, never with the model's count.
    pub fn storedHeightEntryCount(self: *const State) usize {
        return self.measured.count() + self.buckets.count();
    }

    pub fn contentExtent(self: *const State) f64 {
        return self.extent;
    }

    pub fn maxOffset(self: *const State) f64 {
        return @max(0, self.extent - self.viewport_height);
    }

    pub fn itemHeight(self: *const State, index: usize) f64 {
        std.debug.assert(index < self.count);
        return if (self.measured.get(index)) |entry| entry.height else self.estimated_height;
    }

    pub fn itemTop(self: *const State, index: usize) f64 {
        std.debug.assert(index <= self.count);
        var correction: f64 = 0;
        var node = index;
        while (node != 0) : (node &= node - 1) {
            correction += self.buckets.get(node) orelse 0;
        }
        return @as(f64, @floatFromInt(index)) * self.estimated_height + correction;
    }

    pub fn setOffset(self: *State, requested: f64, keys: Keys) Error!void {
        self.offset = try uniform.clampOffset(requested, self.extent, self.viewport_height);
        self.end_follow = false;
        self.recordAnchor(keys);
    }

    pub fn setViewport(self: *State, viewport_height: f64, keys: Keys) Error!void {
        try uniform.checkViewport(viewport_height);
        self.viewport_height = viewport_height;
        self.restoreAnchor(self.anchor, keys);
    }

    pub fn followEnd(self: *State, enabled: bool, keys: Keys) void {
        self.end_follow = enabled;
        if (enabled) self.offset = self.maxOffset();
        self.recordAnchor(keys);
    }

    pub fn reveal(self: *State, index: usize, alignment: Reveal, keys: Keys) Error!void {
        if (index >= self.count) return error.InvalidIndex;
        self.offset = uniform.revealOffset(
            self.offset,
            self.viewport_height,
            self.extent,
            self.itemTop(index),
            self.itemHeight(index),
            alignment,
        );
        self.end_follow = false;
        self.recordAnchor(keys);
    }

    /// Prefix search uses only logarithmically many sparse buckets.
    pub fn visible(self: *const State) Range {
        if (self.count == 0 or self.viewport_height == 0) return .{ .first = 0, .end = 0 };
        const first_visible = @min(self.prefixBound(self.offset, true), self.count - 1);
        const last_y = @min(self.extent, self.offset + self.viewport_height);
        const end_visible = if (last_y >= self.extent)
            self.count
        else
            @min(self.prefixBound(last_y, false) + 1, self.count);
        const first = first_visible - @min(first_visible, self.overdraw_items);
        const end = end_visible + @min(self.count - end_visible, self.overdraw_items);
        return .{ .first = first, .end = end };
    }

    /// Callback receives viewport-relative geometry and a stable key, never a prior frame node.
    pub fn visit(self: *State, keys: Keys, context: anytype, comptime build: anytype) !usize {
        var range = self.visible();
        if (self.focused) |focus| {
            if (focus.index < range.first or focus.index >= range.end) {
                switch (self.focus_policy) {
                    .blur_when_unbuilt => self.clearFocused(),
                    .reveal_when_unbuilt => {
                        try self.reveal(focus.index, .nearest, keys);
                        range = self.visible();
                        if (focus.index < range.first or focus.index >= range.end) {
                            self.clearFocused();
                        }
                    },
                }
            }
        }
        for (range.first..range.end) |index| {
            const key = keys.keyAt(index);
            if (self.measured.get(index)) |entry| {
                if (entry.key != key) return error.MutationNotReported;
            }
            try build(context, Item{
                .index = index,
                .key = key,
                .viewport_y = self.itemTop(index) - self.offset,
                .height = self.itemHeight(index),
            });
        }
        return range.end - range.first;
    }

    /// Revisions are monotone per stable key. A stale measurement cannot move an anchor.
    pub fn measure(self: *State, index: usize, height: f64, revision: u64, keys: Keys) Error!bool {
        if (index >= self.count) return error.InvalidIndex;
        if (!std.math.isFinite(height) or height <= 0) return error.InvalidHeight;
        const key = keys.keyAt(index);
        const previous = self.measured.get(index);
        if (previous) |old| {
            if (old.key != key) return error.MutationNotReported;
            if (revision < old.revision) return false;
            if (revision == old.revision) {
                if (height != old.height) return error.RevisionConflict;
                return false;
            }
        }
        const previous_height = if (previous) |old| old.height else self.estimated_height;
        const delta = height - previous_height;
        const next_extent = self.extent + delta;
        if (!std.math.isFinite(next_extent) or next_extent < 0 or
            next_extent > uniform.exact_coordinate_limit) return error.ExtentOverflow;
        if (previous == null) try self.measured.ensureUnusedCapacity(self.allocator, 1);
        if (delta != 0) {
            var missing: usize = 0;
            var node = index + 1;
            while (node <= self.count) {
                if (!self.buckets.contains(node)) missing += 1;
                node = nextNode(node, self.count) orelse break;
            }
            try self.buckets.ensureUnusedCapacity(self.allocator, @intCast(missing));
        }
        self.measured.putAssumeCapacity(index, .{
            .key = key,
            .height = height,
            .revision = revision,
        });
        if (delta != 0) self.addMeasuredDelta(index, delta);
        self.extent = next_extent;
        self.restoreAnchor(self.anchor, keys);
        return true;
    }

    /// Caller mutates the model first, then reports the exact edit. Rebuild cost is per cached
    /// measurement, not per modeled record. Failure leaves this state unchanged for a retry.
    pub fn splice(
        self: *State,
        start: usize,
        removed: usize,
        inserted: usize,
        keys: Keys,
    ) Error!void {
        if (start > self.count or removed > self.count - start) return error.InvalidSplice;
        const next_count = std.math.add(usize, self.count - removed, inserted) catch
            return error.InvalidSplice;
        var next_extent = try uniform.checkedExtent(next_count, self.estimated_height);
        var next_heights: Heights = .empty;
        errdefer next_heights.deinit(self.allocator);
        var next_buckets: Buckets = .empty;
        errdefer next_buckets.deinit(self.allocator);
        try next_heights.ensureTotalCapacity(self.allocator, self.measured.count());
        var entries = self.measured.iterator();
        while (entries.next()) |entry| {
            const old_index = entry.key_ptr.*;
            if (old_index >= start and old_index - start < removed) continue;
            const index = uniform.adjustedIndex(
                old_index,
                start,
                removed,
                inserted,
                next_count,
            ) orelse continue;
            const measured = entry.value_ptr.*;
            if (keys.keyAt(index) != measured.key) continue;
            const delta = measured.height - self.estimated_height;
            next_extent += delta;
            next_heights.putAssumeCapacity(index, measured);
            if (delta != 0) try addDelta(self.allocator, &next_buckets, next_count, index, delta);
        }
        if (!std.math.isFinite(next_extent) or next_extent < 0 or
            next_extent > uniform.exact_coordinate_limit) return error.ExtentOverflow;
        const old_anchor = self.anchor;
        const old_focus = self.focused;
        self.measured.deinit(self.allocator);
        self.buckets.deinit(self.allocator);
        self.measured = next_heights;
        self.buckets = next_buckets;
        self.count = next_count;
        self.extent = next_extent;
        self.anchor = remapAnchor(old_anchor, start, removed, inserted, next_count, keys);
        self.remapFocused(old_focus, start, removed, inserted, keys);
        self.restoreAnchor(self.anchor, keys);
    }

    /// Reset invalidates all measured heights. A key lookup preserves the former top item.
    pub fn reset(self: *State, count: usize, keys: Keys) Error!void {
        const next_extent = try uniform.checkedExtent(count, self.estimated_height);
        if (!self.end_follow and self.anchor != null and count > 0 and keys.find == null) {
            return error.KeyLookupRequired;
        }
        const old_anchor = self.anchor;
        const old_focus = self.focused;
        self.measured.clearRetainingCapacity();
        self.buckets.clearRetainingCapacity();
        self.count = count;
        self.extent = next_extent;
        self.anchor = remapAnchor(old_anchor, 0, 0, 0, count, keys);
        self.remapFocused(old_focus, 0, 0, 0, keys);
        self.restoreAnchor(self.anchor, keys);
    }

    /// Change the estimate without discarding measured heights or their per-key revisions.
    pub fn reviseEstimate(self: *State, height: f64, revision: u64, keys: Keys) Error!bool {
        const baseline = try uniform.checkedExtent(self.count, height);
        if (revision < self.estimate_revision) return false;
        if (revision == self.estimate_revision) {
            if (height != self.estimated_height) return error.EstimateRevisionConflict;
            return false;
        }
        var rebuilt: Buckets = .empty;
        errdefer rebuilt.deinit(self.allocator);
        var next_extent = baseline;
        var entries = self.measured.iterator();
        while (entries.next()) |entry| {
            const delta = entry.value_ptr.height - height;
            next_extent += delta;
            if (delta != 0) {
                try addDelta(self.allocator, &rebuilt, self.count, entry.key_ptr.*, delta);
            }
        }
        if (!std.math.isFinite(next_extent) or next_extent < 0 or
            next_extent > uniform.exact_coordinate_limit) return error.ExtentOverflow;
        self.buckets.deinit(self.allocator);
        self.buckets = rebuilt;
        self.estimated_height = height;
        self.estimate_revision = revision;
        self.extent = next_extent;
        self.restoreAnchor(self.anchor, keys);
        return true;
    }

    pub fn setFocused(self: *State, index: usize, keys: Keys) Error!void {
        if (index >= self.count) return error.InvalidIndex;
        self.focused = .{ .index = index, .key = keys.keyAt(index), .within = 0 };
        self.focus_change = null;
    }

    pub fn focusedKey(self: *const State) ?u64 {
        return if (self.focused) |focus| focus.key else null;
    }

    pub fn takeFocusChange(self: *State) ?FocusChange {
        const change = self.focus_change;
        self.focus_change = null;
        return change;
    }

    fn prefixBound(self: *const State, target: f64, inclusive: bool) usize {
        var step: usize = 1;
        while (step <= self.count / 2) : (step *= 2) {}
        var index: usize = 0;
        var correction: f64 = 0;
        while (step != 0) : (step >>= 1) {
            if (step > self.count - index) continue;
            const candidate = index + step;
            const bucket = self.buckets.get(candidate) orelse 0;
            const next_height = @as(f64, @floatFromInt(candidate)) *
                self.estimated_height + correction + bucket;
            if (if (inclusive) next_height <= target else next_height < target) {
                index = candidate;
                correction += bucket;
            }
        }
        return index;
    }

    fn addMeasuredDelta(self: *State, index: usize, delta: f64) void {
        var node = index + 1;
        while (node <= self.count) {
            if (self.buckets.getPtr(node)) |value| {
                value.* += delta;
            } else {
                self.buckets.putAssumeCapacity(node, delta);
            }
            node = nextNode(node, self.count) orelse break;
        }
    }

    fn clearFocused(self: *State) void {
        self.focused = null;
        self.focus_change = .blur;
    }

    fn remapFocused(
        self: *State,
        previous: ?Anchor,
        start: usize,
        removed: usize,
        inserted: usize,
        keys: Keys,
    ) void {
        const focus = previous orelse return;
        const hint = uniform.adjustedIndex(focus.index, start, removed, inserted, self.count);
        if (uniform.survivingIndex(keys, focus.key, hint, self.count)) |index| {
            self.focused = .{ .index = index, .key = focus.key, .within = 0 };
        } else if (self.removed_focus == .focus_nearest) {
            if (hint) |index| {
                const key = keys.keyAt(index);
                self.focused = .{ .key = key, .index = index, .within = 0 };
                self.focus_change = .{ .focus = key };
                return;
            }
            self.clearFocused();
        } else {
            self.clearFocused();
        }
    }

    fn recordAnchor(self: *State, keys: Keys) void {
        if (self.count == 0) {
            self.anchor = null;
            return;
        }
        const index = @min(self.prefixBound(self.offset, true), self.count - 1);
        self.anchor = .{
            .index = index,
            .key = keys.keyAt(index),
            .within = @max(0, self.offset - self.itemTop(index)),
        };
    }

    fn restoreAnchor(self: *State, previous: ?Anchor, keys: Keys) void {
        if (self.end_follow) {
            self.offset = self.maxOffset();
        } else if (previous) |anchor| {
            self.offset = @min(self.maxOffset(), self.itemTop(anchor.index) + @min(
                anchor.within,
                self.itemHeight(anchor.index),
            ));
        } else {
            self.offset = @min(self.offset, self.maxOffset());
        }
        self.recordAnchor(keys);
    }
};

fn nextNode(node: usize, count: usize) ?usize {
    const bit = node & (~node +% 1);
    return if (bit <= count - node) node + bit else null;
}

fn addDelta(
    allocator: std.mem.Allocator,
    buckets: *Buckets,
    count: usize,
    index: usize,
    delta: f64,
) error{OutOfMemory}!void {
    var node = index + 1;
    while (node <= count) {
        if (buckets.getPtr(node)) |value| {
            value.* += delta;
        } else {
            try buckets.put(allocator, node, delta);
        }
        node = nextNode(node, count) orelse break;
    }
}

fn remapAnchor(
    previous: ?Anchor,
    start: usize,
    removed: usize,
    inserted: usize,
    count: usize,
    keys: Keys,
) ?Anchor {
    const old = previous orelse return null;
    const hint = uniform.adjustedIndex(old.index, start, removed, inserted, count);
    if (uniform.survivingIndex(keys, old.key, hint, count)) |index| {
        return .{ .index = index, .key = old.key, .within = old.within };
    }
    if (hint) |index| {
        return .{ .index = index, .key = keys.keyAt(index), .within = 0 };
    }
    return null;
}
