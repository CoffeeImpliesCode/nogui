//! A mixed-height virtualized feed over `nogui.virtual_list`.
//!
//! A chat log, a mail list, a search result page: thousands of records, wildly
//! different row heights, and a viewport that only ever builds what it shows.
//! The consumer side is:
//!
//!   * `nogui.list.State` — the application's persistent geometry. It is NOT
//!     frame-local; it survives every frame and every scroll.
//!   * `nogui.uniform_list.Keys` — how a row index maps to a stable model key.
//!     A list indexes records by KEY, never by position, so a splice above the
//!     viewport cannot silently repaint the wrong record.
//!   * A `Builder` — one `build(item, ctx)` call per *materialized* row.
//!
//! The properties this example proves, all of them consumer-visible:
//!
//!   1. Frame cost is bounded by the VIEWPORT, not the model: 2,000 rows and
//!      20,000 rows build the same handful of rows.
//!   2. `reveal` scrolls a specific item into view and it really is built.
//!   3. An edit ABOVE the viewport (a taller measurement, or an insertion)
//!      preserves the anchor: the same key stays at the same screen offset.
//!   4. `followEnd` keeps the newest row in view across appends.
//!   5. Built rows and the BYTES a frame asks for both track the viewport.
//!      A counting allocator measures the bytes; nothing is inferred from
//!      stored height metadata.
//!   6. The stable scroll handle (`App.scrollHandle` and friends) is how an
//!      app moves the list. Every offset below travels through it.
//!
//! Run it: `zig build run-parity-virtual-feed`. Headless, no window.
const std = @import("std");

const nogui = @import("nogui");
const list = nogui.list;
const uniform_list = nogui.uniform_list;
const virtual_list = nogui.virtual_list;
const App = nogui.App;
const DrawCtx = nogui.DrawCtx;
const Session = nogui.Session;
const ScrollState = nogui.ScrollState;
const AllocationCounter = nogui.virtual_list.AllocationCounter;

const Item = uniform_list.Item;
const Keys = uniform_list.Keys;

/// The model: a count and the base index of its first record. Rows are
/// generated, so a million-row model costs one usize.
pub const Feed = struct {
    count: usize = 0,
    /// The key of row 0. Inserting above the viewport bumps it, which is
    /// exactly the mutation that must not disturb the anchor.
    first_key: u64 = 1,

    pub fn keyAt(self: *const Feed, index: usize) u64 {
        return self.first_key + @as(u64, @intCast(index));
    }

    pub fn find(self: *const Feed, key: u64) ?usize {
        if (key < self.first_key) return null;
        const index = key - self.first_key;
        return if (index < self.count) @intCast(index) else null;
    }

    pub fn keys(self: *const Feed) Keys {
        return .{ .context = @constCast(self), .at = keyAtCallback, .find = findCallback };
    }

    /// The real height of a row. Rows alternate between a one-line summary and
    /// a three-line preview, so the list is genuinely mixed-height.
    pub fn naturalHeight(self: *const Feed, index: usize) f64 {
        return if (self.keyAt(index) % 2 == 0) 20 else 52;
    }
};

fn keyAtCallback(raw: *anyopaque, index: usize) u64 {
    const self: *const Feed = @ptrCast(@alignCast(raw));
    return self.keyAt(index);
}

fn findCallback(raw: *anyopaque, key: u64) ?usize {
    const self: *const Feed = @ptrCast(@alignCast(raw));
    return self.find(key);
}

/// The row builder. It receives only materialized rows and reports the height
/// it actually laid out, so the list learns real geometry instead of guesses.
pub const RowBuilder = struct {
    feed: *const Feed,
    state: *list.State,
    keys_source: Keys,
    /// Row count this frame, and the first/last key built. A regression in
    /// virtualization shows up here as a runaway count.
    built: usize = 0,
    first_key: ?u64 = null,
    last_key: ?u64 = null,
    /// The index and height this builder reported for each built row. The
    /// index is captured at build time, so a later splice cannot make a
    /// pending report name the wrong record.
    measured_index: [64]usize = undefined,
    measured: [64]f64 = undefined,
    /// The revision each row was reported with, so a test can replay the exact
    /// (index, height, revision) triple the list already accepted.
    measured_revision: [64]u64 = undefined,
    measured_count: usize = 0,
    /// Monotone per key. A stale measurement must never move the anchor.
    revision: u64 = 0,

    pub fn reset(self: *RowBuilder) void {
        self.built = 0;
        self.first_key = null;
        self.last_key = null;
        self.measured_count = 0;
    }

    pub fn build(self: *RowBuilder, item: Item, ctx: *DrawCtx) !void {
        if (self.measured_count < self.measured.len) {
            const slot = self.measured_count;
            self.measured_index[slot] = item.index;
            self.measured[slot] = self.feed.naturalHeight(item.index);
            self.measured_count += 1;
        }
        if (self.first_key == null) self.first_key = item.key;
        self.last_key = item.key;
        self.built += 1;
        const text = try std.fmt.allocPrint(ctx.arena, "row {d}", .{item.key});
        _ = try ctx.label(.{ .text = text });
    }

    /// The key this frame actually built for one model index, or null when
    /// that row was not materialized. `measured_index` is the built row set.
    pub fn keyFor(self: *const RowBuilder, index: usize) ?u64 {
        for (self.measured_index[0..self.measured_count]) |built| {
            if (built == index) return self.feed.keyAt(index);
        }
        return null;
    }

    /// Report every height this frame's rows actually needed. The caller runs
    /// this OUTSIDE the draw, because `measure` mutates persistent state.
    pub fn reportHeights(self: *RowBuilder) !void {
        for (self.measured[0..self.measured_count], self.measured_index[0..self.measured_count], 0..) |height, index, slot| {
            self.revision += 1;
            self.measured_revision[slot] = self.revision;
            _ = try self.state.measure(index, height, self.revision, self.keys_source);
        }
    }
};

/// The root view: one virtualized list filling the window.
///
/// The list box is the SCROLL VIEWPORT, so the sweep moves `list_height` and
/// `list_width` rather than the window surface. That is the parameter that
/// decides how many rows a frame builds.
pub const FeedView = struct {
    const Self = @This();
    feed: *Feed,
    state: *list.State,
    scroll: *ScrollState,
    builder: *RowBuilder,
    list_width: f32 = 160,
    list_height: f32 = 100,

    pub fn draw(self: *Self, ctx: *DrawCtx) !void {
        _ = try virtual_list.variableList(
            RowBuilder,
            ctx,
            self.state,
            self.feed.keys(),
            self.builder,
            .{
                .key = @as(nogui.ComponentKey, .{ .static = "feed" }),
                .scroll_state = self.scroll,
                .height = .{ .length = self.list_height },
                .width = .{ .length = self.list_width },
            },
        );
    }
};

/// The two boxes a frame is drawn against: the window surface, and the list
/// inside it. The list box IS the scroll viewport, so the sweep moves it.
/// How many frames following the end may take before the scenario calls the
/// model unsettled. Every round must strictly extend or reach the end, so a
/// model of stable heights settles on the first or second.
const follow_end_rounds = 8;

pub const Viewport = struct {
    surface_width: f32 = 200,
    surface_height: f32 = 140,
    list_width: f32 = 160,
    list_height: f32 = 100,
};

pub const Options = struct {
    gpa: std.mem.Allocator,
    count: usize,
    estimated_height: f64 = 20,
    viewport_height: f64 = 100,
    overdraw_items: usize = 1,
    viewport: Viewport = .{},
};

/// The whole scenario. `main` prints its trace; the test asserts on it.
///
/// The App retains a `*Session` and a `*FeedView`, and the builder retains
/// `*Feed` and `*list.State`, so all of them are heap-owned: returning this
/// struct by value would leave the mounted component pointing at a dead copy.
pub const Scenario = struct {
    /// The allocator this Scenario was built on. It owns the Scenario itself.
    gpa: std.mem.Allocator,
    /// Counts every allocation the Session, the App and the list State make.
    /// It passes through to `gpa`, so the SafeAllocator leak check still runs.
    counter: AllocationCounter,
    session: *Session,
    app: *App,
    feed: *Feed,
    state: *list.State,
    scroll: ScrollState,
    builder: RowBuilder,
    view: *FeedView,
    viewport: Viewport,
    /// The tick of the last published frame. An edit that has to commit a
    /// frame of its own continues the sequence from here.
    last_tick: u32 = 0,

    pub fn init(options: Options) !*Scenario {
        const gpa = options.gpa;
        const self = try gpa.create(Scenario);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .counter = .init(gpa),
            .session = undefined,
            .app = undefined,
            .feed = undefined,
            .state = undefined,
            .scroll = .{},
            .builder = undefined,
            .view = undefined,
            .viewport = options.viewport,
            .last_tick = 0,
        };
        const counted = self.counter.allocator();
        self.session = try counted.create(Session);
        errdefer counted.destroy(self.session);
        self.session.* = try Session.init(counted);
        self.app = try counted.create(App);
        errdefer counted.destroy(self.app);
        self.app.* = try App.init(counted, self.session);
        self.feed = try counted.create(Feed);
        errdefer counted.destroy(self.feed);
        self.feed.* = .{ .count = options.count };
        self.state = try counted.create(list.State);
        errdefer counted.destroy(self.state);
        self.state.* = try list.State.init(counted, .{
            .count = options.count,
            .estimated_height = options.estimated_height,
            .viewport_height = options.viewport_height,
            .overdraw_items = options.overdraw_items,
        });
        self.builder = .{ .feed = self.feed, .state = self.state, .keys_source = undefined };
        self.builder.keys_source = self.feed.keys();
        self.view = try counted.create(FeedView);
        errdefer counted.destroy(self.view);
        self.view.* = .{
            .feed = self.feed,
            .state = self.state,
            .scroll = &self.scroll,
            .builder = &self.builder,
            .list_width = options.viewport.list_width,
            .list_height = options.viewport.list_height,
        };
        try self.app.mountRoot(FeedView, self.view);
        // Baseline: everything above is setup, not a frame.
        self.counter.reset();
        return self;
    }

    pub fn deinit(self: *Scenario) void {
        const counted = self.counter.allocator();
        self.app.deinit();
        counted.destroy(self.view);
        self.state.deinit();
        counted.destroy(self.state);
        counted.destroy(self.feed);
        self.session.deinit() catch unreachable;
        counted.destroy(self.session);
        counted.destroy(self.app);
        self.gpa.destroy(self);
    }

    /// The stable handle for the list. It names the KEYED widget, so it keeps
    /// resolving after the frame that created it has been replaced. It is null
    /// before the first frame publishes, and null again if the list stops
    /// being a scroller.
    pub fn scrollHandle(self: *const Scenario) !nogui.scroll.Handle {
        const id = self.app.widgetIdForKey(
            nogui.ComponentId.root,
            @as(nogui.ComponentKey, .{ .static = "feed" }),
        ) orelse return error.MissingListIdentity;
        return self.app.scrollHandle(id) orelse error.MissingScrollHandle;
    }

    /// One frame at the current viewport. The builder is reset first so
    /// `built` counts THIS frame.
    pub fn publish(self: *Scenario, tick: u32) !void {
        self.last_tick = tick;
        self.view.list_width = self.viewport.list_width;
        self.view.list_height = self.viewport.list_height;
        _ = try self.app.handle(.{
            .resize = .{
                .width = self.viewport.surface_width,
                .height = self.viewport.surface_height,
            },
        });
        self.builder.reset();
        const output = (try self.app.handle(.{ .frame = .{ .tick = tick, .time_ms = tick * 16 } })) orelse
            return error.MissingFrameOutput;
        if (output.json) |json| self.session.gpa.free(json);
        try self.builder.reportHeights();
    }

    /// Tell the window where the list now is, through the stable handle.
    ///
    /// The list reads its offset from `ScrollState` at the start of a frame and
    /// writes it back at the end, so an app that moves the list outside a
    /// frame (measure, reveal, splice, followEnd) has to publish the resulting
    /// offset. `App.scrollTo` is that call: it clamps to the committed maximum
    /// and asks for a redraw, which is what the raw write did not.
    ///
    /// The committed maximum belongs to the LAST published frame. When an edit
    /// grew the content past it, the position is not reachable yet: commit one
    /// frame to publish the new extent, then set the offset against it. An app
    /// asking for a position beyond the old end was already at the end, so the
    /// new end is the position it gets.
    pub fn syncScroll(self: *Scenario) !void {
        const handle = try self.scrollHandle();
        const snapshot = self.app.scrollSnapshot(handle) orelse
            return error.MissingScrollSnapshot;
        const desired: f32 = @floatCast(self.state.offset);
        if (desired <= snapshot.max_offset[1]) {
            _ = try self.app.scrollTo(handle, .{ 0, desired });
            return;
        }
        const was_following = self.state.end_follow;
        try self.publish(self.last_tick + 1);
        if (was_following) {
            // Following the end is not one step. Building a row is what
            // MEASURES it, so the geometry state runs ahead of the frame that
            // is committed: each follow scrolls further, builds different rows,
            // and can extend the content again. The test is against the APP's
            // COMMITTED maximum, not the geometry state's, because that is the
            // bound a scroll host will actually serve. Bounded, so a model
            // whose heights never settle reports that instead of spinning.
            var rounds: usize = 0;
            while (rounds < follow_end_rounds) : (rounds += 1) {
                self.state.followEnd(true, self.feed.keys());
                // The frame reads its starting offset from the caller's
                // ScrollState, not from the geometry state, so a position the
                // app moved outside a frame has to be published through that
                // transport or the next frame adopts the PREVIOUS one back.
                self.scroll.offset[1] = @floatCast(self.state.offset);
                try self.publish(self.last_tick + 1);
                const current = try self.scrollHandle();
                const committed = self.app.scrollSnapshot(current) orelse
                    return error.MissingScrollSnapshot;
                if (self.state.offset <= committed.max_offset[1]) {
                    _ = try self.app.scrollTo(current, .{ 0, @floatCast(self.state.offset) });
                    return;
                }
            }
            return error.FollowEndDidNotSettle;
        }
        const rebuilt = try self.scrollHandle();
        const refreshed = self.app.scrollSnapshot(rebuilt) orelse
            return error.MissingScrollSnapshot;
        const target: f32 = @floatCast(self.state.offset);
        if (target > refreshed.max_offset[1]) return error.ScrollTargetBeyondCommittedMaximum;
        _ = try self.app.scrollTo(rebuilt, .{ 0, target });
    }

    /// Run one edit step. Each step publishes its own resulting offset through
    /// the stable handle; a step that needs no context is called with
    /// `edit(insertAtTop, {})`.
    pub fn edit(self: *Scenario, comptime step: anytype, context: anytype) !void {
        const Context = @TypeOf(context);
        if (Context == void) {
            try step(self);
        } else {
            try step(self, context);
        }
    }

    /// The viewport-bounded built set for the current scroll position.
    pub fn builtRange(self: *const Scenario) nogui.list.Range {
        return self.state.visible();
    }

    /// Move to one viewport and measure what a frame there costs: the rows it
    /// built, and the bytes it asked the heap for.
    ///
    /// Two frames, because the frame arena retains its capacity. The FIRST
    /// frame at a viewport has to obtain backing memory for the whole tree
    /// (`cold`); the next one reuses it (`warm`). Both numbers come from the
    /// counting allocator, not from a stored-metadata counter.
    pub fn measureViewport(self: *Scenario, viewport: Viewport) !Measurement {
        self.viewport = viewport;
        self.counter.reset();
        try self.publish(self.last_tick + 1);
        const cold = self.counter.totals();
        self.counter.reset();
        try self.publish(self.last_tick + 1);
        const warm = self.counter.totals();
        return .{
            .viewport = viewport,
            .built = self.builder.built,
            .first_key = self.builder.first_key,
            .last_key = self.builder.last_key,
            .range = self.state.visible(),
            .stored = self.state.storedHeightEntryCount(),
            .cold = cold,
            .warm = warm,
        };
    }
};

/// One viewport's frame cost. `cold` and `warm` are the same frame measured
/// with and without a retained frame arena.
pub const Measurement = struct {
    viewport: Viewport,
    built: usize,
    first_key: ?u64,
    last_key: ?u64,
    range: nogui.list.Range,
    stored: usize,
    cold: nogui.virtual_list.AllocationTotals,
    warm: nogui.virtual_list.AllocationTotals,

    /// A frame may not build more rows than the viewport spans, and it may not
    /// build a whole model. The overdraw is the only slack. The shortest row
    /// bounds the visible count, so a mixed-height list can never need more
    /// than `list_height / shortest_row` of them.
    pub fn checkBounded(
        self: Measurement,
        count: usize,
        shortest_row: f64,
        overdraw_items: usize,
    ) !void {
        if (self.built == 0) return error.NoRowsBuilt;
        if (self.built != self.range.end - self.range.first) return error.BuiltRangeMismatch;
        if (self.built * 8 >= count) return error.FrameCostTracksModel;
        const ceiling = self.viewport.list_height / @as(f32, @floatCast(shortest_row)) +
            2 * @as(f32, @floatFromInt(overdraw_items)) + 2;
        if (@as(f32, @floatFromInt(self.built)) > ceiling) return error.TooManyRowsForViewport;
    }
};

/// Grow or shrink the model, report the reset, and publish the offset.
fn resetCount(scenario: *Scenario, count: usize) !void {
    scenario.feed.count = count;
    try scenario.state.reset(count, scenario.feed.keys());
    try scenario.syncScroll();
}

/// Bring one row into view through the stable handle.
///
/// The rectangle is in the list's unscrolled client coordinates: the row's
/// content-space top and its real height. The handle turns that into an
/// offset, clamps it, and asks for a redraw. The list reads the new offset
/// from `ScrollState` at the start of the next frame and adopts it, so the
/// app never writes the offset itself.
fn revealItem(scenario: *Scenario, index: usize) !void {
    if (index >= scenario.state.count) return error.InvalidIndex;
    const handle = try scenario.scrollHandle();
    const snapshot = scenario.app.scrollSnapshot(handle) orelse
        return error.MissingScrollSnapshot;
    const rect: nogui.Rect = .{
        .x = 0,
        .y = @floatCast(scenario.state.itemTop(index)),
        .w = snapshot.viewport[0],
        .h = @floatCast(scenario.state.itemHeight(index)),
    };
    if (!try scenario.app.revealRect(handle, rect, .center)) return error.RevealRejected;
}

/// One pending measurement: which row, and how tall it turned out.
const RowEdit = struct { index: usize, height: f64 };

/// Report a measured height for a row, then publish the restored offset.
fn measureRow(scenario: *Scenario, edit_row: RowEdit) !void {
    scenario.builder.revision += 1;
    _ = try scenario.state.measure(
        edit_row.index,
        edit_row.height,
        scenario.builder.revision,
        scenario.feed.keys(),
    );
    try scenario.syncScroll();
}

/// Insert one record at the top of the model, then report the splice. The new
/// record takes the key the old row 0 had; every other key keeps its record.
fn insertAtTop(scenario: *Scenario) !void {
    scenario.feed.first_key -= 1;
    try scenario.state.splice(0, 0, 1, scenario.feed.keys());
    try scenario.syncScroll();
}

/// Append `added` records to the model, then report the splice.
fn appendRows(scenario: *Scenario, added: usize) !void {
    const start = scenario.feed.count;
    scenario.feed.count += added;
    try scenario.state.splice(start, 0, added, scenario.feed.keys());
    try scenario.syncScroll();
}

/// Keep the newest row in view across future growth.
fn followEnd(scenario: *Scenario) !void {
    scenario.state.followEnd(true, scenario.feed.keys());
    try scenario.syncScroll();
}

/// Drive the scenario the way a host would, and print the result.
pub fn main() !void {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const scenario = try Scenario.init(.{ .gpa = gpa, .count = 2_000 });
    defer scenario.deinit();

    try scenario.publish(1);
    std.debug.print("2000 rows: built {d} (keys {d}..{d})\n", .{
        scenario.builder.built,
        scenario.builder.first_key.?,
        scenario.builder.last_key.?,
    });

    // Growing the model by 10x must not change the frame cost.
    try scenario.edit(resetCount, 20_000);
    try scenario.publish(2);
    std.debug.print("20000 rows: built {d} (keys {d}..{d}) stored={d}\n", .{
        scenario.builder.built,
        scenario.builder.first_key.?,
        scenario.builder.last_key.?,
        scenario.state.storedHeightEntryCount(),
    });

    // Scroll-to-item: reveal row 1500 and prove the row was really built.
    try scenario.edit(revealItem, 1_500);
    try scenario.publish(3);
    const range = scenario.builtRange();
    std.debug.print("reveal 1500: range {d}..{d} built {d} offset {d:.0}\n", .{
        range.first,
        range.end,
        scenario.builder.built,
        scenario.state.offset,
    });

    // An edit ABOVE the viewport: row 900 grows. The anchor must not move.
    const anchor_key = scenario.state.anchor.?.key;
    try scenario.edit(measureRow, RowEdit{ .index = 900, .height = 96 });
    std.debug.print("edit above: anchor {d} (was {d})\n", .{
        scenario.state.anchor.?.key,
        anchor_key,
    });

    // End follow keeps the newest row in view while the model grows.
    try scenario.edit(followEnd, {});
    const before = scenario.state.offset;
    try scenario.edit(appendRows, 3);
    try scenario.publish(4);
    std.debug.print("follow end: {d:.0} -> {d:.0} (max {d:.0}) built {d}\n", .{
        before,
        scenario.state.offset,
        scenario.state.maxOffset(),
        scenario.builder.built,
    });

    // The stable handle. Everything above moved the list through it; here it
    // is read back, so the window's own view of the scroll is on the record.
    const handle = try scenario.scrollHandle();
    const snapshot = scenario.app.scrollSnapshot(handle) orelse
        return error.MissingScrollSnapshot;
    std.debug.print("handle: viewport {d:.0}x{d:.0} content {d:.0}x{d:.0} offset {d:.0} max {d:.0}\n", .{
        snapshot.viewport[0],
        snapshot.viewport[1],
        snapshot.content[0],
        snapshot.content[1],
        snapshot.offset[1],
        snapshot.max_offset[1],
    });

    // Back to the top first, so a scroll past the end is observable.
    if (!try scenario.app.scrollTo(handle, .{ 0, 0 })) return error.ScrollToOriginRejected;
    try scenario.publish(6);

    // A scroll-to far past the end is clamped to the committed maximum, and a
    // scroll-by is relative to the clamped position.
    if (!try scenario.app.scrollTo(handle, .{ 0, snapshot.content[1] * 4 })) {
        return error.ScrollToPastEndRejected;
    }
    const clamped = scenario.app.scrollSnapshot(handle) orelse
        return error.MissingScrollSnapshot;
    if (clamped.offset[1] != clamped.max_offset[1]) return error.ScrollToNotClamped;
    if (!try scenario.app.scrollBy(handle, .{ 0, -60 })) return error.ScrollByRejected;
    const moved = scenario.app.scrollSnapshot(handle) orelse
        return error.MissingScrollSnapshot;
    std.debug.print("clamped: {d:.0} -> {d:.0} (max {d:.0})\n", .{
        clamped.offset[1],
        moved.offset[1],
        moved.max_offset[1],
    });
    try scenario.publish(7);

    // A reveal through the handle, deep in the model, must be built by the
    // next frame: the handle moved the committed offset, the frame read it
    // back from ScrollState, and the list materialised that row.
    try revealItem(scenario, 900);
    try scenario.publish(8);
    const revealed = scenario.builtRange();
    if (revealed.first > 900 or 900 >= revealed.end) return error.RevealDidNotBuildRow;
    std.debug.print("handle reveal 900: range {d}..{d} built {d}\n", .{
        revealed.first,
        revealed.end,
        scenario.builder.built,
    });

    try reportViewportSweep(gpa);
}

/// The sweep: the same model, the same builder, the same window, at four
/// viewport heights. Built rows and requested bytes are both reported per
/// viewport, and every entry is checked rather than assumed.
fn reportViewportSweep(gpa: std.mem.Allocator) !void {
    const count: usize = 20_000;
    const overdraw_items: usize = 1;
    const viewports = [_]Viewport{
        .{ .list_height = 40 },
        .{ .list_height = 100 },
        .{ .list_height = 260 },
        .{ .list_height = 600 },
    };
    const scenario = try Scenario.init(.{
        .gpa = gpa,
        .count = count,
        .overdraw_items = overdraw_items,
    });
    defer scenario.deinit();

    var previous_built: usize = 0;
    for (viewports) |viewport| {
        const measurement = try scenario.measureViewport(viewport);
        try measurement.checkBounded(count, 20, overdraw_items);
        if (measurement.built < previous_built) return error.ViewportShrankBuiltSet;
        previous_built = measurement.built;
        std.debug.print("viewport {d:.0}x{d:.0} in {d:.0}x{d:.0}: built {d} keys {d}..{d} range {d}..{d} stored={d}", .{
            measurement.viewport.list_width,
            measurement.viewport.list_height,
            measurement.viewport.surface_width,
            measurement.viewport.surface_height,
            measurement.built,
            measurement.first_key.?,
            measurement.last_key.?,
            measurement.range.first,
            measurement.range.end,
            measurement.stored,
        });
        std.debug.print(" cold {d}B in {d} allocs, warm {d}B in {d} allocs\n", .{
            measurement.cold.bytes,
            measurement.cold.calls,
            measurement.warm.bytes,
            measurement.warm.calls,
        });
    }
}

test "api-w25 virtualized mixed-height feed bounds frame cost and holds its anchor" {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(gpa_state.deinit() == 0) catch {};
    const gpa = gpa_state.allocator();

    const scenario = try Scenario.init(.{ .gpa = gpa, .count = 2_000, .overdraw_items = 1 });
    defer scenario.deinit();

    try scenario.publish(1);
    const small_built = scenario.builder.built;
    try std.testing.expect(small_built > 0);
    // A 100px viewport over 20px-52px rows can only need a handful.
    try std.testing.expect(small_built <= 8);

    // Growing the model tenfold must NOT change the frame cost, and must not
    // make the list keep a height record per modeled row. The measured
    // heights above survive the reset, so the extent is the count times the
    // estimate plus only the deltas this viewport actually measured.
    const extent_before = scenario.state.contentExtent();
    try scenario.edit(resetCount, 20_000);
    try scenario.publish(2);
    try std.testing.expectEqual(small_built, scenario.builder.built);
    try std.testing.expect(scenario.state.storedHeightEntryCount() < 64);
    // 20_000 rows at the 20px estimate, adjusted only by measured deltas.
    const baseline: f64 = 20_000 * 20;
    const extent_after = scenario.state.contentExtent();
    try std.testing.expect(extent_after >= baseline);
    try std.testing.expect(extent_after - baseline <= @as(f64, @floatFromInt(small_built)) * 32);
    try std.testing.expect(extent_before < baseline);

    // A reveal puts the requested row inside the built range. The anchor is
    // whatever record is at the top of the viewport, which for a centred
    // reveal is the row just above the target — but it must always be a key
    // the model still maps back to the same record.
    try scenario.edit(revealItem, 1_500);
    try scenario.publish(3);
    const range = scenario.builtRange();
    try std.testing.expect(range.first <= 1_500 and 1_500 < range.end);
    const anchor = scenario.state.anchor.?;
    try std.testing.expectEqual(
        scenario.feed.keyAt(anchor.index),
        anchor.key,
    );
    // The anchor sits at the very top of the viewport, so the target row is
    // at most one screen below it.
    try std.testing.expect(anchor.index <= 1_500);
    try std.testing.expect(1_500 - anchor.index <= scenario.state.visible().end - range.first);

    // An edit ABOVE the viewport: the anchor key stays put and its position
    // within the item is preserved; only the numeric offset moves.
    const anchor_key = scenario.state.anchor.?.key;
    const anchor_index = scenario.state.anchor.?.index;
    const screen_y = scenario.state.offset - scenario.state.itemTop(anchor_index);
    const offset_before = scenario.state.offset;
    try scenario.edit(measureRow, RowEdit{ .index = 900, .height = 96 });
    try std.testing.expect(scenario.state.offset > offset_before);
    try std.testing.expectEqual(anchor_key, scenario.state.anchor.?.key);
    try std.testing.expectEqual(
        screen_y,
        scenario.state.offset - scenario.state.itemTop(anchor_index),
    );
    // The next frame still builds around the same anchor, not around row 900.
    try scenario.publish(4);
    const after = scenario.builtRange();
    try std.testing.expect(after.first <= anchor_index and anchor_index < after.end);

    // An INSERTION above the viewport is the harder case: every index shifts,
    // but the anchor follows its KEY to its new index, and the key the anchor
    // held before the splice still names the same record afterwards.
    const old_top_key = scenario.feed.keyAt(0);
    try scenario.edit(insertAtTop, {});
    // The new row 0 has a fresh key, and the old row 0 kept its own.
    try std.testing.expect(scenario.feed.keyAt(0) != old_top_key);
    try std.testing.expectEqual(old_top_key, scenario.feed.keyAt(1));
    try std.testing.expectEqual(anchor_key, scenario.state.anchor.?.key);
    try std.testing.expectEqual(anchor_index + 1, scenario.state.anchor.?.index);
    try std.testing.expectEqual(anchor_key, scenario.feed.keyAt(anchor_index + 1));
    try scenario.publish(5);
    const shifted = scenario.builtRange();
    try std.testing.expect(shifted.first <= anchor_index + 1 and anchor_index + 1 < shifted.end);

    // End follow tracks appends: the newest row stays in view.
    try scenario.edit(followEnd, {});
    try std.testing.expectEqual(scenario.state.maxOffset(), scenario.state.offset);
    const extent_pre = scenario.state.contentExtent();
    try scenario.edit(appendRows, 3);
    try std.testing.expect(scenario.state.contentExtent() > extent_pre);
    try scenario.publish(6);
    try std.testing.expectEqual(scenario.state.maxOffset(), scenario.state.offset);
    try std.testing.expect(scenario.state.offset > 0);
    // End follow put the NEWEST record in view: it is inside the built range,
    // and only the configured overdraw reaches past it.
    const tail = scenario.builtRange();
    const last_index = scenario.feed.count - 1;
    try std.testing.expect(tail.first <= last_index and last_index < tail.end);
    try std.testing.expectEqual(
        scenario.feed.keyAt(last_index),
        scenario.builder.keyFor(last_index).?,
    );
    // The frame stayed bounded even at the very end of a 20k-row model.
    try std.testing.expect(scenario.builder.built <= 8);
    try std.testing.expect(tail.end - last_index <= 1 + 1);

    // Replaying a measurement the list already accepted is a no-op, and an
    // OLDER revision for the same key is refused outright. Together they mean
    // a late frame can never overwrite a newer height for the same record.
    const measured_index = scenario.builder.measured_index[0];
    const measured_height = scenario.builder.measured[0];
    const measured_revision = scenario.builder.measured_revision[0];
    try std.testing.expectEqual(
        measured_height,
        scenario.state.itemHeight(measured_index),
    );
    // The exact triple the list already accepted changes nothing.
    try std.testing.expect(!try scenario.state.measure(
        measured_index,
        measured_height,
        measured_revision,
        scenario.feed.keys(),
    ));
    // An older revision carrying a DIFFERENT height is refused, and the
    // stored height survives the attempt.
    try std.testing.expect(!try scenario.state.measure(
        measured_index,
        measured_height + 40,
        measured_revision - 1,
        scenario.feed.keys(),
    ));
    try std.testing.expectEqual(
        measured_height,
        scenario.state.itemHeight(measured_index),
    );
}
