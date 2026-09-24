//! Persistent uniform-height list geometry. The model owns records; a frame visits only its range.
const std = @import("std");

/// The caller must supply unique keys. `find` is required to retain an anchor across reset/reorder.
/// Neither pointer is retained by a list; the model must remain valid for the duration of the call.
pub const Keys = struct {
    context: *anyopaque,
    at: *const fn (*anyopaque, usize) u64,
    find: ?*const fn (*anyopaque, u64) ?usize = null,

    pub fn keyAt(self: Keys, index: usize) u64 {
        return self.at(self.context, index);
    }
};

pub const Reveal = enum { top, center, bottom, nearest };
pub const FocusPolicy = enum { blur_when_unbuilt, reveal_when_unbuilt };
pub const RemovedFocus = enum { blur, focus_nearest };
pub const FocusChange = union(enum) { blur, focus: u64 };
pub const Anchor = struct { key: u64, index: usize, within: f64 };
pub const Item = struct {
    index: usize,
    key: u64,
    /// Relative to the viewport; convert this small value to f32 for widget layout.
    viewport_y: f64,
    height: f64,
};
pub const Range = struct { first: usize, end: usize };
pub const Options = struct {
    count: usize,
    item_height: f64,
    viewport_height: f64,
    overdraw_items: usize = 1,
    focus_policy: FocusPolicy = .blur_when_unbuilt,
    removed_focus: RemovedFocus = .blur,
};
pub const Error = error{
    InvalidHeight,
    InvalidViewport,
    InvalidOffset,
    ExtentOverflow,
    InvalidIndex,
    InvalidSplice,
    KeyLookupRequired,
};

// A f64 represents every integral item index and every integral pixel up to this bound.
pub const exact_coordinate_limit: f64 = 4_503_599_627_370_496;

pub fn checkedExtent(count: usize, height: f64) Error!f64 {
    if (!std.math.isFinite(height) or height <= 0) return error.InvalidHeight;
    if (@bitSizeOf(usize) > 52) {
        if (count > @as(usize, @intFromFloat(exact_coordinate_limit))) {
            return error.ExtentOverflow;
        }
    }
    const extent = @as(f64, @floatFromInt(count)) * height;
    if (!std.math.isFinite(extent) or extent > exact_coordinate_limit) {
        return error.ExtentOverflow;
    }
    return extent;
}

pub fn checkViewport(height: f64) Error!void {
    if (!std.math.isFinite(height) or height < 0) return error.InvalidViewport;
}

pub fn clampOffset(requested: f64, extent: f64, viewport: f64) Error!f64 {
    if (!std.math.isFinite(requested)) return error.InvalidOffset;
    const maximum = @max(0, extent - viewport);
    return @max(0, @min(requested, maximum));
}

pub fn revealOffset(
    current: f64,
    viewport: f64,
    extent: f64,
    top: f64,
    height: f64,
    alignment: Reveal,
) f64 {
    const bottom = top + height;
    const requested = switch (alignment) {
        .top => top,
        .center => top - (viewport - height) / 2,
        .bottom => bottom - viewport,
        .nearest => if (height > viewport)
            (if (top < current) top else if (bottom > current + viewport) top else current)
        else if (top < current)
            top
        else if (bottom > current + viewport)
            bottom - viewport
        else
            current,
    };
    return @max(0, @min(requested, @max(0, extent - viewport)));
}

/// Computes a plausible successor without reading a removed model record.
pub fn adjustedIndex(
    old_index: usize,
    start: usize,
    removed: usize,
    inserted: usize,
    new_count: usize,
) ?usize {
    if (new_count == 0) return null;
    const end = start + removed;
    if (old_index < start) return old_index;
    if (old_index < end) return @min(start + inserted, new_count - 1);
    return @min(old_index - removed + inserted, new_count - 1);
}

/// Validate a stable key after a mutation. A stale/invalid lookup never indexes the model.
pub fn survivingIndex(keys: Keys, key: u64, hint: ?usize, count: usize) ?usize {
    if (keys.find) |find| {
        if (find(keys.context, key)) |candidate| {
            if (candidate < count and keys.keyAt(candidate) == key) return candidate;
        }
    }
    if (hint) |candidate| {
        if (candidate < count and keys.keyAt(candidate) == key) return candidate;
    }
    return null;
}

pub const State = struct {
    count: usize,
    item_height: f64,
    viewport_height: f64,
    overdraw_items: usize,
    offset: f64 = 0,
    anchor: ?Anchor = null,
    end_follow: bool = false,
    focus_policy: FocusPolicy,
    removed_focus: RemovedFocus,
    focused: ?Anchor = null,
    focus_change: ?FocusChange = null,

    pub fn init(options: Options) Error!State {
        _ = try checkedExtent(options.count, options.item_height);
        try checkViewport(options.viewport_height);
        return .{
            .count = options.count,
            .item_height = options.item_height,
            .viewport_height = options.viewport_height,
            .overdraw_items = options.overdraw_items,
            .focus_policy = options.focus_policy,
            .removed_focus = options.removed_focus,
        };
    }

    pub fn contentExtent(self: *const State) f64 {
        return @as(f64, @floatFromInt(self.count)) * self.item_height;
    }

    pub fn maxOffset(self: *const State) f64 {
        return @max(0, self.contentExtent() - self.viewport_height);
    }

    pub fn itemTop(self: *const State, index: usize) f64 {
        std.debug.assert(index <= self.count);
        return @as(f64, @floatFromInt(index)) * self.item_height;
    }

    pub fn setOffset(self: *State, requested: f64, keys: Keys) Error!void {
        self.offset = try clampOffset(requested, self.contentExtent(), self.viewport_height);
        self.end_follow = false;
        self.recordAnchor(keys);
    }

    pub fn setViewport(self: *State, viewport_height: f64, keys: Keys) Error!void {
        try checkViewport(viewport_height);
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
        self.offset = revealOffset(
            self.offset,
            self.viewport_height,
            self.contentExtent(),
            self.itemTop(index),
            self.item_height,
            alignment,
        );
        self.end_follow = false;
        self.recordAnchor(keys);
    }

    pub fn visible(self: *const State) Range {
        if (self.count == 0 or self.viewport_height == 0) return .{ .first = 0, .end = 0 };
        const first_visible: usize = @min(
            @as(usize, @intFromFloat(@floor(self.offset / self.item_height))),
            self.count - 1,
        );
        const last_y = @min(self.contentExtent(), self.offset + self.viewport_height);
        const end_visible: usize = @min(
            @as(usize, @intFromFloat(@ceil(last_y / self.item_height))),
            self.count,
        );
        const first = first_visible - @min(first_visible, self.overdraw_items);
        const end = end_visible + @min(self.count - end_visible, self.overdraw_items);
        return .{ .first = first, .end = end };
    }

    /// `build(context, Item)` is called once per materialized item; no list allocation occurs.
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
            try build(context, Item{
                .index = index,
                .key = keys.keyAt(index),
                .viewport_y = self.itemTop(index) - self.offset,
                .height = self.item_height,
            });
        }
        return range.end - range.first;
    }

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
        _ = try checkedExtent(next_count, self.item_height);
        const prior = self.anchor;
        const old_focus = self.focused;
        self.count = next_count;
        self.anchor = remapAnchor(prior, start, removed, inserted, next_count, keys);
        self.remapFocused(old_focus, start, removed, inserted, keys);
        self.restoreAnchor(self.anchor, keys);
    }

    pub fn reset(self: *State, count: usize, keys: Keys) Error!void {
        _ = try checkedExtent(count, self.item_height);
        if (!self.end_follow and self.anchor != null and count > 0 and keys.find == null) {
            return error.KeyLookupRequired;
        }
        const prior = self.anchor;
        const old_focus = self.focused;
        self.count = count;
        self.anchor = remapAnchor(prior, 0, 0, 0, count, keys);
        self.remapFocused(old_focus, 0, 0, 0, keys);
        self.restoreAnchor(self.anchor, keys);
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
        const hint = adjustedIndex(focus.index, start, removed, inserted, self.count);
        if (survivingIndex(keys, focus.key, hint, self.count)) |index| {
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
        const index = @min(
            @as(usize, @intFromFloat(@floor(self.offset / self.item_height))),
            self.count - 1,
        );
        self.anchor = .{
            .index = index,
            .key = keys.keyAt(index),
            .within = self.offset - self.itemTop(index),
        };
    }

    fn restoreAnchor(self: *State, previous: ?Anchor, keys: Keys) void {
        if (self.end_follow) {
            self.offset = self.maxOffset();
        } else if (previous) |anchor| {
            self.offset = @min(self.maxOffset(), self.itemTop(anchor.index) + @min(
                anchor.within,
                self.item_height,
            ));
        } else {
            self.offset = @min(self.offset, self.maxOffset());
        }
        self.recordAnchor(keys);
    }
};

fn remapAnchor(
    previous: ?Anchor,
    start: usize,
    removed: usize,
    inserted: usize,
    count: usize,
    keys: Keys,
) ?Anchor {
    const old = previous orelse return null;
    const hint = adjustedIndex(old.index, start, removed, inserted, count);
    if (survivingIndex(keys, old.key, hint, count)) |index| {
        return .{ .index = index, .key = old.key, .within = old.within };
    }
    if (hint) |index| {
        return .{ .index = index, .key = keys.keyAt(index), .within = 0 };
    }
    return null;
}
