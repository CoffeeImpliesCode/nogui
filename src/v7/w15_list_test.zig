const std = @import("std");
const uniform_list = @import("uniform_list.zig");
const list = @import("list.zig");
const ScrollState = @import("widget.zig").ScrollState;

const VirtualKeys = struct {
    prefix: usize = 0,

    fn at(raw: *anyopaque, index: usize) u64 {
        const self: *VirtualKeys = @ptrCast(@alignCast(raw));
        return if (index < self.prefix)
            @as(u64, @intCast(index + 1))
        else
            @as(u64, @intCast(index - self.prefix + 1_000));
    }

    fn find(raw: *anyopaque, key: u64) ?usize {
        const self: *VirtualKeys = @ptrCast(@alignCast(raw));
        if (key >= 1_000) return self.prefix + @as(usize, @intCast(key - 1_000));
        if (key == 0 or key > self.prefix) return null;
        return @intCast(key - 1);
    }

    fn source(self: *VirtualKeys) uniform_list.Keys {
        return .{ .context = self, .at = at, .find = find };
    }
};

const Visits = struct {
    count: usize = 0,
    first: ?u64 = null,
    last: ?u64 = null,
    first_y: f64 = 0,

    fn append(self: *Visits, item: uniform_list.Item) !void {
        if (self.first == null) {
            self.first = item.key;
            self.first_y = item.viewport_y;
        }
        self.last = item.key;
        self.count += 1;
    }
};

// A million modeled records must not create a million widget callbacks or height records.
test "api-w15 uniform million-item range is viewport bounded and reveals all alignments" {
    var keys: VirtualKeys = .{};
    var state = try uniform_list.State.init(.{
        .count = 1_000_000,
        .item_height = 20,
        .viewport_height = 100,
        .overdraw_items = 2,
    });
    try state.setOffset(10_000_003, keys.source());
    var visits: Visits = .{};
    try std.testing.expectEqual(
        @as(usize, 10),
        try state.visit(keys.source(), &visits, Visits.append),
    );
    try std.testing.expectEqual(@as(usize, 10), visits.count);
    try std.testing.expectEqual(@as(?u64, 500_998), visits.first);
    try std.testing.expectEqual(@as(f64, -43), visits.first_y);
    try std.testing.expectEqual(@as(f64, 20_000_000), state.contentExtent());

    try state.reveal(500_020, .top, keys.source());
    try std.testing.expectEqual(@as(f64, 10_000_400), state.offset);
    try state.reveal(500_020, .center, keys.source());
    try std.testing.expectEqual(@as(f64, 10_000_360), state.offset);
    try state.reveal(500_020, .bottom, keys.source());
    try std.testing.expectEqual(@as(f64, 10_000_320), state.offset);
    try state.reveal(500_020, .nearest, keys.source());
    try std.testing.expectEqual(@as(f64, 10_000_320), state.offset);
    try state.reveal(500_025, .nearest, keys.source());
    try std.testing.expectEqual(@as(f64, 10_000_420), state.offset);
}

// Sparse revisions above the viewport change its numeric offset, not its top visible key.
test "api-w15 variable million-item list anchors through measures and splices" {
    var keys: VirtualKeys = .{};
    var state = try list.State.init(std.testing.allocator, .{
        .count = 1_000_000,
        .estimated_height = 20,
        .viewport_height = 100,
        .overdraw_items = 2,
    });
    defer state.deinit();
    try state.setOffset(10_000_005, keys.source());
    const anchor_key = state.anchor.?.key;
    const anchor_y = state.offset - state.itemTop(500_000);
    try std.testing.expect(try state.measure(499_999, 35, 1, keys.source()));
    try std.testing.expectEqual(@as(f64, 10_000_020), state.offset);
    try std.testing.expectEqual(anchor_key, state.anchor.?.key);
    try std.testing.expectEqual(anchor_y, state.offset - state.itemTop(500_000));

    keys.prefix = 3;
    try state.splice(0, 0, 3, keys.source());
    try std.testing.expectEqual(anchor_key, state.anchor.?.key);
    try std.testing.expectEqual(@as(usize, 500_003), state.anchor.?.index);
    try std.testing.expectEqual(@as(f64, 10_000_080), state.offset);
    try std.testing.expectEqual(@as(usize, 1), state.measuredCount());
    var visits: Visits = .{};
    try std.testing.expect((try state.visit(keys.source(), &visits, Visits.append)) <= 10);
    try std.testing.expect(visits.count <= 10);
    try std.testing.expectEqual(
        anchor_key,
        keys.source().keyAt(state.anchor.?.index),
    );
    try std.testing.expect(state.storedHeightEntryCount() < 64);

    keys.prefix = 0;
    try state.splice(0, 3, 0, keys.source());
    try std.testing.expectEqual(@as(usize, 500_000), state.anchor.?.index);
    try std.testing.expectEqual(@as(f64, 10_000_020), state.offset);
    try std.testing.expectEqual(@as(f64, 35), state.itemHeight(499_999));
    try std.testing.expect(!try state.measure(499_999, 60, 0, keys.source()));
    try std.testing.expectError(
        error.RevisionConflict,
        state.measure(499_999, 36, 1, keys.source()),
    );
}

// End follow uses the new extent; reset finds the stable anchor rather than reusing an index.
test "api-w15 variable reset and end follow survive revised estimates" {
    var keys: VirtualKeys = .{};
    var state = try list.State.init(std.testing.allocator, .{
        .count = 1_000_000,
        .estimated_height = 12,
        .viewport_height = 60,
        .overdraw_items = 1,
    });
    defer state.deinit();
    try state.setOffset(1_200_004, keys.source());
    const key_before = state.anchor.?.key;
    keys.prefix = 4;
    try state.reset(1_000_004, keys.source());
    try std.testing.expectEqual(key_before, state.anchor.?.key);
    try std.testing.expectEqual(@as(f64, 1_200_052), state.offset);
    try std.testing.expectEqual(@as(usize, 0), state.measuredCount());

    state.followEnd(true, keys.source());
    try std.testing.expectEqual(state.contentExtent() - 60, state.offset);
    _ = try state.measure(1_000_003, 42, 2, keys.source());
    try std.testing.expectEqual(state.contentExtent() - 60, state.offset);
    keys.prefix = 6;
    try state.splice(0, 0, 2, keys.source());
    try std.testing.expectEqual(state.contentExtent() - 60, state.offset);
    try state.reveal(2, .top, keys.source());
    try std.testing.expect(!state.end_follow);
}

const SmallKeys = struct {
    values: [8]u64 = .{ 11, 22, 33, 44, 55, 0, 0, 0 },

    fn at(raw: *anyopaque, index: usize) u64 {
        const self: *SmallKeys = @ptrCast(@alignCast(raw));
        return self.values[index];
    }

    fn find(raw: *anyopaque, key: u64) ?usize {
        const self: *SmallKeys = @ptrCast(@alignCast(raw));
        for (self.values, 0..) |candidate, index| {
            if (candidate == key) return index;
        }
        return null;
    }

    fn source(self: *SmallKeys) uniform_list.Keys {
        return .{ .context = self, .at = at, .find = find };
    }
};

// A removed focused key moves to the successor; an offscreen focused key blurs explicitly.
test "api-w15 focused list item tracks stable key, removal and materialization" {
    var keys: SmallKeys = .{};
    var state = try list.State.init(std.testing.allocator, .{
        .count = 5,
        .estimated_height = 10,
        .viewport_height = 10,
        .overdraw_items = 0,
        .removed_focus = .focus_nearest,
    });
    defer state.deinit();
    try state.setFocused(2, keys.source());
    try state.reveal(2, .top, keys.source());
    var visits: Visits = .{};
    _ = try state.visit(keys.source(), &visits, Visits.append);
    try std.testing.expectEqual(@as(?u64, 33), visits.first);
    @memmove(keys.values[2..4], keys.values[3..5]);
    keys.values[4] = 0;
    try state.splice(2, 1, 0, keys.source());
    const moved = state.takeFocusChange().?;
    switch (moved) {
        .focus => |key| try std.testing.expectEqual(@as(u64, 44), key),
        .blur => return error.UnexpectedFocusChange,
    }
    try std.testing.expectEqual(@as(?u64, 44), state.focusedKey());
    try state.setOffset(0, keys.source());
    visits = .{};
    _ = try state.visit(keys.source(), &visits, Visits.append);
    const blurred = state.takeFocusChange().?;
    switch (blurred) {
        .blur => {},
        .focus => return error.UnexpectedFocusChange,
    }
    try std.testing.expectEqual(@as(?u64, null), state.focusedKey());
}

test "api-w15 invalid list geometry and splice counts return errors before mutation" {
    try std.testing.expectError(error.InvalidHeight, uniform_list.State.init(.{
        .count = 10,
        .item_height = 0,
        .viewport_height = 50,
    }));
    try std.testing.expectError(error.InvalidHeight, list.State.init(std.testing.allocator, .{
        .count = 10,
        .estimated_height = std.math.inf(f64),
        .viewport_height = 50,
    }));
    var keys: SmallKeys = .{};
    var state = try list.State.init(std.testing.allocator, .{
        .count = 5,
        .estimated_height = 10,
        .viewport_height = 10,
    });
    defer state.deinit();
    try std.testing.expectError(error.InvalidSplice, state.splice(4, 2, 0, keys.source()));
    try std.testing.expectEqual(@as(usize, 5), state.count);
    try std.testing.expectError(error.InvalidHeight, state.measure(0, -1, 1, keys.source()));
    try std.testing.expectEqual(@as(usize, 0), state.measuredCount());
}

// Revising the estimate keeps measured rows fixed and remaps the viewport's stable item.
test "api-w15 variable estimate revisions and measured reveal preserve geometry" {
    var keys: SmallKeys = .{};
    var state = try list.State.init(std.testing.allocator, .{
        .count = 5,
        .estimated_height = 10,
        .viewport_height = 30,
        .overdraw_items = 0,
    });
    defer state.deinit();
    try std.testing.expect(try state.measure(2, 40, 1, keys.source()));
    try state.reveal(2, .top, keys.source());
    try std.testing.expectEqual(@as(f64, 20), state.offset);
    try state.reveal(2, .center, keys.source());
    try std.testing.expectEqual(@as(f64, 25), state.offset);
    try state.reveal(2, .bottom, keys.source());
    try std.testing.expectEqual(@as(f64, 30), state.offset);
    try state.reveal(2, .nearest, keys.source());
    try std.testing.expectEqual(@as(f64, 20), state.offset);
    try state.reveal(4, .nearest, keys.source());
    try std.testing.expectEqual(@as(f64, 50), state.offset);
    try state.reveal(2, .top, keys.source());
    try std.testing.expect(try state.reviseEstimate(20, 1, keys.source()));
    try std.testing.expectEqual(@as(f64, 40), state.offset);
    try std.testing.expectEqual(@as(f64, 40), state.itemHeight(2));
    try std.testing.expectEqual(@as(f64, 120), state.contentExtent());
    try std.testing.expect(!try state.reviseEstimate(100, 0, keys.source()));
    try std.testing.expectError(
        error.EstimateRevisionConflict,
        state.reviseEstimate(25, 1, keys.source()),
    );
}

// Uniform splices preserve logical position and end-follow while modeled records stay external.
test "api-w15 uniform prepend, reset and end follow keep stable keys" {
    var keys: VirtualKeys = .{};
    var state = try uniform_list.State.init(.{
        .count = 1_000_000,
        .item_height = 20,
        .viewport_height = 100,
        .overdraw_items = 1,
    });
    try state.setOffset(10_005, keys.source());
    const key_before = state.anchor.?.key;
    keys.prefix = 2;
    try state.splice(0, 0, 2, keys.source());
    try std.testing.expectEqual(key_before, state.anchor.?.key);
    try std.testing.expectEqual(@as(f64, 10_045), state.offset);
    keys.prefix = 3;
    try state.reset(1_000_003, keys.source());
    try std.testing.expectEqual(key_before, state.anchor.?.key);
    try std.testing.expectEqual(@as(f64, 10_065), state.offset);
    state.followEnd(true, keys.source());
    keys.prefix = 4;
    try state.splice(0, 0, 1, keys.source());
    try std.testing.expectEqual(state.maxOffset(), state.offset);
}

test "api-w15 list rejects nonfinite offsets and unrepresentable extents" {
    try std.testing.expectError(error.ExtentOverflow, uniform_list.State.init(.{
        .count = std.math.maxInt(usize),
        .item_height = 1,
        .viewport_height = 10,
    }));
    var keys: SmallKeys = .{};
    var state = try list.State.init(std.testing.allocator, .{
        .count = 5,
        .estimated_height = 10,
        .viewport_height = 10,
    });
    defer state.deinit();
    try std.testing.expectError(
        error.InvalidOffset,
        state.setOffset(std.math.nan(f64), keys.source()),
    );
    try std.testing.expectError(
        error.ExtentOverflow,
        state.measure(0, uniform_list.exact_coordinate_limit, 1, keys.source()),
    );
    try std.testing.expectEqual(@as(usize, 0), state.measuredCount());
    try std.testing.expectEqual(@as(f64, 50), state.contentExtent());
}

// A zero-height viewport cannot keep a focused widget that was not materialized.
test "api-w15 focused item in zero viewport blurs even under reveal policy" {
    var keys: SmallKeys = .{};
    var state = try list.State.init(std.testing.allocator, .{
        .count = 5,
        .estimated_height = 10,
        .viewport_height = 0,
        .focus_policy = .reveal_when_unbuilt,
    });
    defer state.deinit();
    try state.setFocused(2, keys.source());
    var visits: Visits = .{};
    try std.testing.expectEqual(
        @as(usize, 0),
        try state.visit(keys.source(), &visits, Visits.append),
    );
    try std.testing.expectEqual(@as(usize, 0), visits.count);
    const change = state.takeFocusChange().?;
    switch (change) {
        .blur => {},
        .focus => return error.UnexpectedFocusChange,
    }
    try std.testing.expectEqual(@as(?u64, null), state.focusedKey());
}

// Resetting to fewer items must never consult a stale index beyond the new model.
test "api-w15 reset to shorter model moves missing anchor and focused key safely" {
    var keys: SmallKeys = .{};
    var state = try list.State.init(std.testing.allocator, .{
        .count = 5,
        .estimated_height = 10,
        .viewport_height = 10,
        .removed_focus = .focus_nearest,
    });
    defer state.deinit();
    try state.setOffset(30, keys.source());
    try state.setFocused(3, keys.source());
    var no_lookup = keys.source();
    no_lookup.find = null;
    try std.testing.expectError(error.KeyLookupRequired, state.reset(2, no_lookup));
    try std.testing.expectEqual(@as(usize, 5), state.count);
    try state.reset(2, keys.source());
    try std.testing.expectEqual(@as(usize, 1), state.anchor.?.index);
    try std.testing.expectEqual(@as(u64, 22), state.anchor.?.key);
    try std.testing.expectEqual(@as(f64, 10), state.offset);
    const change = state.takeFocusChange().?;
    switch (change) {
        .focus => |key| try std.testing.expectEqual(@as(u64, 22), key),
        .blur => return error.UnexpectedFocusChange,
    }
    try std.testing.expectEqual(@as(?u64, 22), state.focusedKey());
}

test "api-w15 mounted million-item list builds viewport rows and follows a scroll handle" {
    const App = @import("app.zig").App;
    const Session = @import("session.zig").Session;
    const DrawCtx = @import("drawctx.zig").DrawCtx;
    const virtual_list = @import("virtual_list.zig");
    const ComponentId = @import("key.zig").ComponentId;
    var keys: VirtualKeys = .{};
    var state = try uniform_list.State.init(.{
        .count = 1_000_000,
        .item_height = 20,
        .viewport_height = 100,
        .overdraw_items = 2,
    });
    var scroll_state: ScrollState = .{
        .offset = .{ 0, 10_000_000 },
    };
    const Builder = struct {
        const Self = @This();
        count: usize = 0,
        first: ?u64 = null,
        pub fn build(self: *Self, item: uniform_list.Item, ctx: *DrawCtx) !void {
            if (self.first == null) self.first = item.key;
            self.count += 1;
            const label = try std.fmt.allocPrint(ctx.arena, "{d}", .{item.key});
            _ = try ctx.label(.{ .text = label });
        }
    };
    const View = struct {
        const Self = @This();
        state: *uniform_list.State,
        scroll_state: *ScrollState,
        keys: *VirtualKeys,
        builder: *Builder,
        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try virtual_list.uniformList(Builder, ctx, self.state, self.keys.source(), self.builder, .{
                .key = .{ .static = "feed" },
                .scroll_state = self.scroll_state,
                .height = .{ .length = 100 },
            });
        }
    };
    var builder: Builder = .{};
    var view: View = .{
        .state = &state,
        .scroll_state = &scroll_state,
        .keys = &keys,
        .builder = &builder,
    };
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    try app.mountRoot(View, &view);
    _ = try app.handle(.{ .resize = .{ .width = 120, .height = 100 } });
    const first = (try app.handle(.{ .frame = .{ .tick = 1, .time_ms = 0 } })).?;
    defer if (first.json) |json| std.testing.allocator.free(json);
    try std.testing.expectEqual(@as(f64, 10_000_000), state.offset);
    try std.testing.expect(builder.count <= 10);
    try std.testing.expect(first.tree.nodes.items.len < 32);
    const id = app.widgetIdForKey(ComponentId.root, .{ .static = "feed" }) orelse
        return error.MissingList;
    const handle = app.scrollHandle(id) orelse return error.MissingScrollHandle;
    try std.testing.expect(try app.scrollBy(handle, .{ 0, 40 }));
    const prior_first = builder.first;
    builder.first = null;
    builder.count = 0;
    const second = (try app.handle(.{ .frame = .{ .tick = 2, .time_ms = 16 } })).?;
    defer if (second.json) |json| std.testing.allocator.free(json);
    try std.testing.expectEqual(@as(f64, 10_000_040), state.offset);
    try std.testing.expect(builder.count <= 10);
    try std.testing.expect(builder.first.? != prior_first.?);
    try std.testing.expect(second.tree.nodes.items.len < 32);
}
