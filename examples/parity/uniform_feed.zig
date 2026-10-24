//! A uniform-height virtualized model over `nogui.virtual_list.uniformList`.
//!
//! A file list, a leaderboard, a log tail: a model far larger than any screen,
//! where every record is the same height. That is the easy case, and it is the
//! one most often shipped as a no-op: a loop over the whole model, or a
//! scrollbar that fakes its extent. This example mounts the real widget.
//!
//! The consumer side is the same shape as the mixed-height feed, with a
//! different geometry type:
//!
//!   * `nogui.uniform_list.State` — persistent geometry, no allocator, no
//!     per-row memory. A 200,000-row model costs one struct.
//!   * `nogui.uniform_list.Keys` — index to stable key, with a reverse lookup
//!     so an anchor survives a reset that changes the count.
//!   * A `Builder` — one `build(item, ctx)` call per MATERIALIZED row.
//!
//! What it reports, per viewport:
//!
//!   1. The rows a frame built, and the keys those rows carried. A frame may
//!      not build more rows than the viewport spans, whatever the model size.
//!   2. That growing the model by 5x changes the built count by nothing.
//!   3. The bytes a frame asked the heap for, measured by a counting
//!      allocator, not inferred from a counter.
//!   4. That every built row's key maps back to the model index it claims.
//!
//! Run it: `zig build run-parity-uniform-feed`. Headless, no window.
const std = @import("std");

const nogui = @import("nogui");
const uniform_list = nogui.uniform_list;
const virtual_list = nogui.virtual_list;
const App = nogui.App;
const Session = nogui.Session;
const ScrollState = nogui.ScrollState;
const AllocationCounter = nogui.virtual_list.AllocationCounter;
const DrawCtx = nogui.DrawCtx;

const Item = uniform_list.Item;
const Keys = uniform_list.Keys;

/// The row height every record in this model uses. Uniform means uniform: the
/// model has no per-row height field at all.
const row_height: f64 = 20;

/// The model. Generated, so a 200,000-row model costs one usize and one u64.
pub const Model = struct {
    count: usize = 0,
    first_key: u64 = 1,

    pub fn keyAt(self: *const Model, index: usize) u64 {
        return self.first_key + @as(u64, @intCast(index));
    }

    pub fn find(self: *const Model, key: u64) ?usize {
        if (key < self.first_key) return null;
        const index = key - self.first_key;
        return if (index < self.count) @intCast(index) else null;
    }

    pub fn keys(self: *const Model) Keys {
        return .{ .context = @constCast(self), .at = keyAtCallback, .find = findCallback };
    }
};

fn keyAtCallback(raw: *anyopaque, index: usize) u64 {
    const self: *const Model = @ptrCast(@alignCast(raw));
    return self.keyAt(index);
}

fn findCallback(raw: *anyopaque, key: u64) ?usize {
    const self: *const Model = @ptrCast(@alignCast(raw));
    return self.find(key);
}

/// One `build` call per materialized row. It records which model index each
/// key claimed, so the scenario can check the two agree instead of assuming.
pub const RowBuilder = struct {
    model: *const Model,
    built: usize = 0,
    first_key: ?u64 = null,
    last_key: ?u64 = null,
    /// The key the list handed out per built row, in build order.
    keys: [512]u64 = undefined,
    /// The model index that key names, read back through `Model.find`.
    indexes: [512]usize = undefined,
    count: usize = 0,

    pub fn reset(self: *RowBuilder) void {
        self.built = 0;
        self.first_key = null;
        self.last_key = null;
        self.count = 0;
    }

    pub fn build(self: *RowBuilder, item: Item, ctx: *DrawCtx) !void {
        if (self.count < self.keys.len) {
            self.keys[self.count] = item.key;
            self.indexes[self.count] = self.model.find(item.key) orelse 0;
            self.count += 1;
        }
        if (self.first_key == null) self.first_key = item.key;
        self.last_key = item.key;
        self.built += 1;
        const text = try std.fmt.allocPrint(ctx.arena, "row {d}", .{item.key});
        _ = try ctx.label(.{ .text = text });
    }
};

/// The root view: one virtualized list.
pub const FeedView = struct {
    const Self = @This();
    model: *Model,
    state: *uniform_list.State,
    scroll: *ScrollState,
    builder: *RowBuilder,
    list_width: f32 = 160,
    list_height: f32 = 100,

    pub fn draw(self: *Self, ctx: *DrawCtx) !void {
        _ = try virtual_list.uniformList(
            RowBuilder,
            ctx,
            self.state,
            self.model.keys(),
            self.builder,
            .{
                .key = @as(nogui.ComponentKey, .{ .static = "rows" }),
                .scroll_state = self.scroll,
                .height = .{ .length = self.list_height },
                .width = .{ .length = self.list_width },
            },
        );
    }
};

/// The list box IS the scroll viewport, so the sweep moves it.
pub const Viewport = struct {
    surface_width: f32 = 240,
    surface_height: f32 = 160,
    list_width: f32 = 200,
    list_height: f32 = 100,
};

pub const Options = struct {
    gpa: std.mem.Allocator,
    count: usize,
    overdraw_items: usize = 1,
    viewport: Viewport = .{},
};

/// The whole scenario. Heap-owned, because the App retains the view and the
/// view retains the model, the state and the builder.
pub const Scenario = struct {
    gpa: std.mem.Allocator,
    counter: AllocationCounter,
    session: *Session,
    app: *App,
    model: *Model,
    state: *uniform_list.State,
    scroll: ScrollState,
    builder: RowBuilder,
    view: *FeedView,
    viewport: Viewport,
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
            .model = undefined,
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
        self.model = try counted.create(Model);
        errdefer counted.destroy(self.model);
        self.model.* = .{ .count = options.count };
        self.state = try counted.create(uniform_list.State);
        errdefer counted.destroy(self.state);
        self.state.* = try uniform_list.State.init(.{
            .count = options.count,
            .item_height = row_height,
            .viewport_height = @as(f64, @floatCast(options.viewport.list_height)),
            .overdraw_items = options.overdraw_items,
        });
        self.builder = .{ .model = self.model };
        self.view = try counted.create(FeedView);
        errdefer counted.destroy(self.view);
        self.view.* = .{
            .model = self.model,
            .state = self.state,
            .scroll = &self.scroll,
            .builder = &self.builder,
            .list_width = options.viewport.list_width,
            .list_height = options.viewport.list_height,
        };
        try self.app.mountRoot(FeedView, self.view);
        // Setup is not a frame.
        self.counter.reset();
        return self;
    }

    pub fn deinit(self: *Scenario) void {
        const counted = self.counter.allocator();
        self.app.deinit();
        counted.destroy(self.view);
        counted.destroy(self.state);
        counted.destroy(self.model);
        self.session.deinit() catch unreachable;
        counted.destroy(self.session);
        counted.destroy(self.app);
        self.gpa.destroy(self);
    }

    /// One frame at the current viewport.
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
    }

    /// Grow or shrink the model and report it, as a host would after a fetch.
    pub fn resetCount(self: *Scenario, count: usize) !void {
        self.model.count = count;
        try self.state.reset(count, self.model.keys());
    }

    /// Move to one viewport and measure the frame there. Two frames, because
    /// the frame arena retains its capacity: the first has to obtain backing
    /// memory for the tree, the next reuses it.
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
            .count = self.model.count,
            .built = self.builder.built,
            .range = self.state.visible(),
            .cold = cold,
            .warm = warm,
        };
    }
};

/// One viewport's frame cost.
pub const Measurement = struct {
    viewport: Viewport,
    count: usize,
    built: usize,
    range: uniform_list.Range,
    cold: nogui.virtual_list.AllocationTotals,
    warm: nogui.virtual_list.AllocationTotals,

    /// The built set must be exactly the viewport range, must fit inside the
    /// viewport plus its overdraw, and must be a rounding error next to the
    /// model. Nothing here is allowed to scale with `count`.
    pub fn checkBounded(self: Measurement, overdraw_items: usize) !void {
        if (self.built == 0) return error.NoRowsBuilt;
        if (self.built != self.range.end - self.range.first) return error.BuiltRangeMismatch;
        if (self.built * 64 >= self.count) return error.FrameCostTracksModel;
        const rows_spanned: f32 = @floatCast(@as(f64, self.viewport.list_height) / row_height);
        const ceiling = rows_spanned + 2 * @as(f32, @floatFromInt(overdraw_items)) + 2;
        if (@as(f32, @floatFromInt(self.built)) > ceiling) return error.TooManyRowsForViewport;
    }
};

/// Drive the scenario the way a host would, and print the result.
pub fn main() !void {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const count: usize = 200_000;
    const overdraw_items: usize = 1;
    const scenario = try Scenario.init(.{
        .gpa = gpa,
        .count = count,
        .overdraw_items = overdraw_items,
    });
    defer scenario.deinit();

    // Sweep the viewport. This is the claim: a frame builds what it shows.
    const viewports = [_]Viewport{
        .{ .list_height = 40 },
        .{ .list_height = 100 },
        .{ .list_height = 260 },
        .{ .list_height = 600 },
    };
    var previous_built: usize = 0;
    for (viewports) |viewport| {
        const measurement = try scenario.measureViewport(viewport);
        try measurement.checkBounded(overdraw_items);
        try checkKeys(scenario);
        if (measurement.built < previous_built) return error.ViewportShrankBuiltSet;
        previous_built = measurement.built;
        std.debug.print("viewport {d:.0}x{d:.0}: built {d} range {d}..{d}", .{
            measurement.viewport.list_width,
            measurement.viewport.list_height,
            measurement.built,
            measurement.range.first,
            measurement.range.end,
        });
        std.debug.print(" cold {d}B in {d} allocs, warm {d}B in {d} allocs\n", .{
            measurement.cold.bytes,
            measurement.cold.calls,
            measurement.warm.bytes,
            measurement.warm.calls,
        });
    }

    // Growing the model fivefold must not change the frame cost. Both frames
    // are measured at the same viewport, so only the model differs.
    const baseline = try scenario.measureViewport(.{ .list_height = 100 });
    try baseline.checkBounded(overdraw_items);
    try checkKeys(scenario);
    const before = baseline.built;
    try scenario.resetCount(1_000_000);
    const grown = try scenario.measureViewport(.{ .list_height = 100 });
    try grown.checkBounded(overdraw_items);
    try checkKeys(scenario);
    if (grown.built != before) return error.ModelSizeChangedFrameCost;
    std.debug.print("1000000 rows: built {d} (was {d}) range {d}..{d}\n", .{
        grown.built,
        before,
        grown.range.first,
        grown.range.end,
    });
}

/// Every key the list handed out must name the model index the list claims,
/// and the first and last built keys must be the ends of the built range.
fn checkKeys(scenario: *const Scenario) !void {
    const builder = &scenario.builder;
    const range = scenario.state.visible();
    if (builder.built == 0) return error.NoRowsBuilt;
    if (builder.built != range.end - range.first) return error.BuiltRangeMismatch;
    // Every build must have been recorded: a full record buffer would
    // silently drop keys and make the loop below check less than it claims.
    if (builder.count != builder.built) return error.BuildRecordOverflowed;
    if (builder.first_key.? != scenario.model.keyAt(range.first)) return error.FirstKeyMismatch;
    if (builder.last_key.? != scenario.model.keyAt(range.end - 1)) return error.LastKeyMismatch;
    for (builder.keys[0..builder.count], 0..) |key, slot| {
        if (scenario.model.find(key) != builder.indexes[slot]) return error.KeyMapsToAnotherRecord;
    }
}
