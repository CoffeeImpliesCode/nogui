//! Frame-bounded list widgets over persistent uniform or sparse-height state.
//! The application owns State, Keys and Builder through the frame and next-frame diff.
const std = @import("std");
const widget = @import("widget.zig");
const element = @import("element.zig");
const DrawCtx = @import("drawctx.zig").DrawCtx;
const FrameNodeId = @import("id.zig").FrameNodeId;
const ComponentId = @import("key.zig").ComponentId;
const ComponentKey = @import("key.zig").ComponentKey;
const uniform = @import("uniform_list.zig");
const variable = @import("list.zig");

pub const Options = struct {
    key: ComponentKey,
    scroll_state: *widget.ScrollState,
    height: widget.Dimension,
    width: widget.Dimension = .auto,
};

/// Row callback context. Hoisted to file scope so `append` can name its own
/// type; a nested struct could only spell it `@This()`.
fn RowVisitor(comptime State: type, comptime Builder: type) type {
    return struct {
        const Self = @This();

        staged: *State,
        builder: *Builder,
        ctx: *DrawCtx,
        size: widget.Size,

        pub fn append(visitor: *Self, item: uniform.Item) !void {
            if (!std.math.isFinite(item.height) or item.height > std.math.floatMax(f32))
                return error.ExtentOverflow;
            const absolute_top = visitor.staged.offset + item.viewport_y;
            if (!std.math.isFinite(absolute_top) or @abs(absolute_top) > std.math.floatMax(f32))
                return error.ExtentOverflow;
            _ = try visitor.ctx.column(.{
                .key = ComponentKey{ .u64 = item.key },
                .position = .absolute,
                .inset = .{ .top = @as(f32, @floatCast(absolute_top)), .left = @as(f32, 0) },
                .width = visitor.size.width,
                .height = @as(f32, @floatCast(item.height)),
                .focusable = true,
            });
            defer visitor.ctx.pop();
            try Builder.build(visitor.builder, item, visitor.ctx);
        }
    };
}

fn Payload(comptime State: type, comptime Builder: type) type {
    return struct {
        const Self = @This();
        pub const PhaseState = struct {};

        state: *State,
        staged: *State,
        keys: uniform.Keys,
        builder: *Builder,
        scroll_state: *widget.ScrollState,
        key: ComponentKey,
        requested_offset: f64,
        built: *bool,

        pub fn measure(_: *const Self, input: element.MeasureInput) element.Error!widget.Size {
            return .{
                .width = input.known_dimensions.width orelse switch (input.available_space.width) {
                    .definite => |available| available,
                    .min_content, .max_content => 0,
                },
                .height = input.known_dimensions.height orelse 0,
            };
        }

        pub fn buildLate(self: *const Self, size: widget.Size, ctx: *DrawCtx) anyerror!void {
            try self.staged.setViewport(size.height, self.keys);
            if (@abs(self.requested_offset - self.state.offset) > 0.5) {
                try self.staged.setOffset(self.requested_offset, self.keys);
            }
            const previous_identity = ctx.component_identity;
            ctx.component_identity = ComponentId.child(previous_identity, self.key);
            defer ctx.component_identity = previous_identity;
            const Visitor = RowVisitor(State, Builder);
            var visitor: Visitor = .{
                .staged = self.staged,
                .builder = self.builder,
                .ctx = ctx,
                .size = size,
            };
            // Only rows in the viewport plus overdraw receive widget nodes, and
            // the visit comes FIRST: building a row is what MEASURES it, so the
            // extent is settled only once every built row has reported. A
            // spacer sized before the visit would publish an extent that is
            // always one measurement behind the geometry state, and a consumer
            // following the end would aim at an offset the committed content
            // cannot reach.
            _ = try self.staged.visit(self.keys, &visitor, Visitor.append);

            const extent = self.staged.contentExtent();
            if (!std.math.isFinite(extent) or extent > std.math.floatMax(f32))
                return error.ExtentOverflow;
            // This one layout node establishes the full scrollable extent.
            _ = try ctx.spacer(.{ .width = size.width, .height = @as(f32, @floatCast(extent)), .shrink = 0 });
            self.scroll_state.offset[1] = @floatCast(self.staged.offset);
            self.built.* = true;
        }

        pub fn commit(self: *const Self, _: *const PhaseState) void {
            if (self.built.*) self.state.* = self.staged.*;
        }
    };
}

fn create(
    comptime State: type,
    comptime Builder: type,
    ctx: *DrawCtx,
    state: *State,
    keys: uniform.Keys,
    builder: *Builder,
    options: Options,
) !FrameNodeId {
    if (@typeInfo(Builder) != .@"struct" or !@hasDecl(Builder, "build"))
        @compileError("virtual list builder must declare build(self, Item, DrawCtx)");
    const staged = try ctx.arena.create(State);
    staged.* = state.*;
    const built = try ctx.arena.create(bool);
    built.* = false;
    const stable_key = switch (options.key) {
        .static => |key| ComponentKey{ .static = try ctx.arena.dupe(u8, key) },
        .u64 => options.key,
    };
    const id = try ctx.elementContainer(Payload(State, Builder), .{
        .state = state,
        .staged = staged,
        .keys = keys,
        .builder = builder,
        .scroll_state = options.scroll_state,
        .key = stable_key,
        .requested_offset = options.scroll_state.offset[1],
        .built = built,
    }, .{
        .key = stable_key,
        .late_scope = element.LateScope.list,
        .width = options.width,
        .height = options.height,
        .display = widget.Display.flex,
        .overflow = .{ .width = .hidden, .height = .scroll },
        .scroll_state = options.scroll_state,
        .scroll_axis = widget.ScrollAxis.vertical,
    });
    ctx.pop();
    return id;
}

/// Build only visible uniform rows. Every row uses its model key, never its index.
pub fn uniformList(
    comptime Builder: type,
    ctx: *DrawCtx,
    state: *uniform.State,
    keys: uniform.Keys,
    builder: *Builder,
    options: Options,
) !FrameNodeId {
    return create(uniform.State, Builder, ctx, state, keys, builder, options);
}

/// One closed measurement window. Hoisted to file scope because `totals`
/// hands this type to callers: nested in `AllocationCounter` a caller could
/// receive it without ever being able to name it.
pub const AllocationTotals = struct {
    calls: usize,
    bytes: usize,
    frees: usize,
    grown: usize,

    /// `calls - frees` is the net number of live blocks over the window.
    pub fn live(self: AllocationTotals) usize {
        return self.calls - self.frees;
    }
};

/// Bytes an allocator actually handed out, and how often it was asked.
///
/// "Frame cost is bounded by the viewport, not the model" is a claim about
/// memory, so a consumer needs to state it in memory. Wrap the allocator the
/// App, the Session and the list State are built on, publish a frame, and
/// read `totals()`. Nothing is inferred from a stored-metadata counter: these
/// are the real `alloc` calls that reached the heap.
///
/// Every call passes straight through to `inner`, so a `DebugAllocator` below
/// still reports leaks and a `std.testing.allocator` still fails on them.
pub const AllocationCounter = struct {
    inner: std.mem.Allocator,
    /// Successful `alloc` and `remap` calls since the last `reset`.
    calls: usize = 0,
    /// Bytes those calls requested, summed.
    bytes: usize = 0,
    /// `free` calls since the last `reset`.
    frees: usize = 0,
    /// Extra bytes `resize` and `remap` added on top of what was already held.
    grown: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn init(inner: std.mem.Allocator) AllocationCounter {
        return .{ .inner = inner };
    }

    /// The allocator to hand to a Session, an App or a list State.
    pub fn allocator(self: *AllocationCounter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Start a new measurement window. Memory already handed out stays held;
    /// only the counters move, so a window reports one frame's cost.
    pub fn reset(self: *AllocationCounter) void {
        self.calls = 0;
        self.bytes = 0;
        self.frees = 0;
        self.grown = 0;
    }

    pub fn totals(self: *const AllocationCounter) AllocationTotals {
        return .{
            .calls = self.calls,
            .bytes = self.bytes,
            .frees = self.frees,
            .grown = self.grown,
        };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *AllocationCounter = @ptrCast(@alignCast(context));
        const memory = self.inner.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.calls += 1;
        self.bytes += len;
        return memory;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *AllocationCounter = @ptrCast(@alignCast(context));
        if (!self.inner.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.growBy(memory.len, new_len);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *AllocationCounter = @ptrCast(@alignCast(context));
        const moved = self.inner.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.growBy(memory.len, new_len);
        self.calls += 1;
        self.bytes += new_len;
        return moved;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *AllocationCounter = @ptrCast(@alignCast(context));
        self.frees += 1;
        self.inner.rawFree(memory, alignment, ret_addr);
    }

    /// Only growth is volume; a shrink hands memory back.
    fn growBy(self: *AllocationCounter, previous: usize, next: usize) void {
        if (next > previous) self.grown += next - previous;
    }
};

/// Build only visible variable-height rows. Measurements remain in persistent State.
pub fn variableList(
    comptime Builder: type,
    ctx: *DrawCtx,
    state: *variable.State,
    keys: uniform.Keys,
    builder: *Builder,
    options: Options,
) !FrameNodeId {
    return create(variable.State, Builder, ctx, state, keys, builder, options);
}

// ── tests ─────────────────────────────────
// The geometry in uniform_list.zig and list.zig has its own coverage. What
// these check is the WIDGET: where a row lands in the committed tree, what a
// refused build leaves behind, and how two lists and the scroll handle
// interact on one root.

const App = @import("app.zig").App;
const Session = @import("session.zig").Session;
const scroll = @import("scroll.zig");

const TestModel = struct {
    count: usize = 1_000,
    first_key: u64 = 1,

    pub fn keyAt(self: *const TestModel, index: usize) u64 {
        return self.first_key + @as(u64, @intCast(index));
    }

    pub fn find(self: *const TestModel, key: u64) ?usize {
        if (key < self.first_key) return null;
        const index = key - self.first_key;
        return if (index < self.count) @intCast(index) else null;
    }

    pub fn keys(self: *const TestModel) uniform.Keys {
        return .{ .context = @constCast(self), .at = atCallback, .find = findCallback };
    }

    fn atCallback(raw: *anyopaque, index: usize) u64 {
        return @as(*const TestModel, @ptrCast(@alignCast(raw))).keyAt(index);
    }

    fn findCallback(raw: *anyopaque, key: u64) ?usize {
        return @as(*const TestModel, @ptrCast(@alignCast(raw))).find(key);
    }
};

/// Records the node each row got, so a test can read the row's geometry back
/// out of the committed tree instead of trusting the list's own numbers.
const TestBuilder = struct {
    count: usize = 0,
    first_key: ?u64 = null,
    fail_at: ?usize = null,
    // SAFETY: only the first `used` entries are ever read, and `used` counts
    // up only as `note` writes each one.
    nodes: [64]FrameNodeId = undefined,
    // SAFETY: as `nodes` above.
    keys: [64]u64 = undefined,
    used: usize = 0,

    pub fn reset(self: *TestBuilder) void {
        self.count = 0;
        self.used = 0;
        self.fail_at = null;
        self.first_key = null;
    }

    pub fn build(self: *TestBuilder, item: uniform.Item, ctx: *DrawCtx) !void {
        if (self.fail_at) |limit| {
            if (self.count == limit) return error.RowRefused;
        }
        const text = try std.fmt.allocPrint(ctx.arena, "r{d}", .{item.key});
        const node = try ctx.label(.{ .text = text, .height = @as(f32, @floatCast(item.height)) });
        if (self.first_key == null) self.first_key = item.key;
        if (self.used < self.nodes.len) {
            self.nodes[self.used] = node;
            self.keys[self.used] = item.key;
            self.used += 1;
        }
        self.count += 1;
    }
};

const TestView = struct {
    uniform_model: *TestModel,
    variable_model: *TestModel,
    uniform_scroll: *widget.ScrollState,
    variable_scroll: *widget.ScrollState,
    uniform_builder: *TestBuilder,
    variable_builder: *TestBuilder,
    uniform_state: ?*uniform.State = null,
    variable_state: ?*variable.State = null,
    height: f32 = 100,

    pub fn draw(self: *TestView, ctx: *DrawCtx) !void {
        if (self.uniform_state) |state| {
            _ = try uniformList(TestBuilder, ctx, state, self.uniform_model.keys(), self.uniform_builder, .{
                .key = .{ .static = "uniform" },
                .scroll_state = self.uniform_scroll,
                .height = .{ .length = self.height },
            });
        }
        if (self.variable_state) |state| {
            _ = try variableList(TestBuilder, ctx, state, self.variable_model.keys(), self.variable_builder, .{
                .key = .{ .static = "variable" },
                .scroll_state = self.variable_scroll,
                .height = .{ .length = self.height },
            });
        }
    }
};

const Fixture = struct {
    const FixtureOptions = struct {
        uniform: bool = true,
        variable: bool = true,
        count: usize = 1_000,
        height: f32 = 100,
    };

    gpa: std.mem.Allocator,
    session: Session,
    app: App,
    model: TestModel,
    other: TestModel,
    uniform_state: uniform.State,
    variable_state: variable.State,
    uniform_scroll: widget.ScrollState = .{},
    variable_scroll: widget.ScrollState = .{},
    uniform_builder: TestBuilder = .{},
    variable_builder: TestBuilder = .{},
    // SAFETY: `init` assigns the whole struct before anything reads it.
    view: TestView = undefined,

    /// The fixture is filled in place: the mounted component holds `&self.view`,
    /// so the fixture must never be moved after this returns.
    fn init(self: *Fixture, gpa: std.mem.Allocator, options: FixtureOptions) !void {
        self.* = .{
            .gpa = gpa,
            .session = try Session.init(gpa),
            // SAFETY: `App.init` assigns the whole struct below.
            .app = undefined,
            .model = .{ .count = options.count },
            .other = .{ .count = options.count },
            .uniform_state = try uniform.State.init(.{
                .count = options.count,
                .item_height = 20,
                .viewport_height = options.height,
                .overdraw_items = 1,
            }),
            .variable_state = try variable.State.init(gpa, .{
                .count = options.count,
                .estimated_height = 20,
                .viewport_height = options.height,
                .overdraw_items = 1,
            }),
        };
        errdefer self.variable_state.deinit();
        errdefer self.session.deinit() catch
            @panic("virtual list fixture left the Session with live models");
        self.app = try App.init(gpa, &self.session);
        self.view = .{
            .uniform_model = &self.model,
            .variable_model = &self.other,
            .uniform_scroll = &self.uniform_scroll,
            .variable_scroll = &self.variable_scroll,
            .uniform_builder = &self.uniform_builder,
            .variable_builder = &self.variable_builder,
            .uniform_state = if (options.uniform) &self.uniform_state else null,
            .variable_state = if (options.variable) &self.variable_state else null,
            .height = options.height,
        };
        try self.app.mountRoot(TestView, &self.view);
    }

    fn deinit(self: *Fixture) void {
        self.app.deinit();
        self.variable_state.deinit();
        self.session.deinit() catch
            @panic("virtual list fixture left the Session with live models");
        self.* = undefined;
    }

    /// Reset both builders, then run one frame. The counts afterwards belong to
    /// this frame alone.
    fn frame(self: *Fixture, tick: u32) !void {
        self.uniform_builder.reset();
        self.variable_builder.reset();
        try self.runFrame(tick);
    }

    /// Run one frame with the builders as the caller left them, so a test can
    /// arm a refusal and then watch what a refused row does to the commit.
    fn runFrame(self: *Fixture, tick: u32) !void {
        _ = try self.app.handle(.{ .resize = .{ .width = 200, .height = 140 } });
        const output = (try self.app.handle(.{ .frame = .{ .tick = tick, .time_ms = tick * 16 } })) orelse
            return error.MissingFrameOutput;
        if (output.json) |json| self.app.gpa.free(json);
    }

    fn handle(self: *Fixture, key: []const u8) !scroll.Handle {
        const component_key: ComponentKey = .{ .static = key };
        const id = self.app.widgetIdForKey(ComponentId.root, component_key) orelse
            return error.MissingListIdentity;
        return self.app.scrollHandle(id) orelse error.MissingScrollHandle;
    }
};

// A row node sits at its content-space top with the height the geometry state
// reported. An index-times-height estimate, or an offset applied twice, fails.
test "api-w15 virtual list places every built row at its content top" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator, .{ .count = 10_000 });
    defer fixture.deinit();
    try fixture.frame(1);
    _ = try fixture.app.scrollBy(try fixture.handle("uniform"), .{ 0, 3_333 });
    try fixture.frame(2);

    const state = &fixture.uniform_state;
    const builder = &fixture.uniform_builder;
    try std.testing.expect(builder.count > 1);
    const range = state.visible();
    try std.testing.expectEqual(range.end - range.first, builder.count);
    for (builder.nodes[0..builder.used], 0..) |node_id, slot| {
        const tree = fixture.app.tree_ptr.?;
        const node = tree.nodeConst(node_id) orelse return error.MissingRowNode;
        // `node` is the row's own content, so its rect is relative to the ROW
        // the visitor created for it. The row's placement is that parent's
        // rect: reading the child's rect would only ever restate the row's own
        // internal geometry and pass whatever the list did.
        const row = tree.nodeConst(node.parent) orelse return error.MissingRowContainer;
        // The visitor places the row for model index N at itemTop(N): the
        // viewport offset the geometry state subtracted is the one it adds
        // back, so a row's content top is independent of where it is scrolled.
        const index = range.first + slot;
        const expected: f64 = @as(f64, @floatFromInt(index)) * 20;
        if (@abs(@as(f64, row.rect.y) - expected) > 0.01) return error.RowNotAtItsContentTop;
        if (row.rect.h != 20) return error.RowHeightIsNotTheItemHeight;
        // The key the row was given is the key the model maps to that index.
        if (builder.keys[slot] != fixture.model.keyAt(index)) return error.RowKeyIsNotThatRecord;
    }
    // The range was taken from the offset the handle set: the row the offset
    // lands in is the first built row plus exactly one row of overdraw.
    const offset_row: usize = @intFromFloat(@floor(state.offset / 20));
    try std.testing.expect(state.offset > 0);
    try std.testing.expectEqual(offset_row, range.first + 1);
}

// A row the builder refuses must leave the committed frame and the persistent
// state exactly as the previous successful frame left them.
test "api-w15 a refused row build commits nothing" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator, .{ .variable = true, .uniform = false });
    defer fixture.deinit();
    try fixture.frame(1);
    const committed = fixture.app.tree_ptr.?;
    const committed_nodes = committed.nodes.items.len;
    const offset_before = fixture.variable_state.offset;
    const extent_before = fixture.variable_state.contentExtent();
    try std.testing.expect(committed_nodes > 0);

    // Arm the refusal AFTER the last good frame, then refuse the third row.
    // The counter has to start from zero for the refused frame, which is what
    // the next frame's own reset does; arming it on top of the previous
    // frame's count would never reach row three.
    fixture.variable_builder.reset();
    fixture.variable_builder.fail_at = 2;
    try std.testing.expectError(error.RowRefused, fixture.runFrame(2));

    // The committed tree is still the one the last good frame published.
    try std.testing.expect(fixture.app.tree_ptr.? == committed);
    try std.testing.expectEqual(committed_nodes, committed.nodes.items.len);
    // The staged offset never reached the persistent state.
    try std.testing.expectEqual(offset_before, fixture.variable_state.offset);
    try std.testing.expectEqual(extent_before, fixture.variable_state.contentExtent());
    try std.testing.expectEqual(@as(usize, 2), fixture.variable_builder.count);

    // And the next good frame commits normally.
    try fixture.frame(3);
    try std.testing.expect(fixture.app.tree_ptr.? != committed);
    try std.testing.expect(fixture.variable_builder.count > 0);
}

// Two lists on one root: each has its own handle, and moving one leaves the
// other's offset, anchor and built set untouched.
test "api-w15 two lists on one root scroll through their own handles" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator, .{ .count = 5_000 });
    defer fixture.deinit();
    try fixture.frame(1);
    _ = try fixture.app.scrollBy(try fixture.handle("variable"), .{ 0, 2_000 });
    try fixture.frame(2);

    // Everything the mixed list did before the uniform list moved.
    const variable_offset = fixture.variable_state.offset;
    const variable_first = fixture.variable_builder.first_key;
    const variable_built = fixture.variable_builder.count;
    try std.testing.expect(variable_offset >= 2_000);
    try std.testing.expect(variable_first != null);

    _ = try fixture.app.scrollBy(try fixture.handle("uniform"), .{ 0, 1_000 });
    try fixture.frame(3);
    try std.testing.expect(fixture.uniform_state.offset >= 1_000);
    try std.testing.expect(fixture.uniform_builder.count > 0);
    // The mixed list did not move, and rebuilt the very same rows.
    try std.testing.expectEqual(variable_offset, fixture.variable_state.offset);
    try std.testing.expectEqual(variable_first, fixture.variable_builder.first_key);
    try std.testing.expectEqual(variable_built, fixture.variable_builder.count);
}

// The list publishes its committed offset into the caller's ScrollState, which
// is the transport an app mutating State outside a frame depends on.
test "api-w15 the list publishes its committed offset to the scroll state" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator, .{ .variable = true, .uniform = false });
    defer fixture.deinit();
    try fixture.frame(1);
    try std.testing.expectEqual(@as(f32, 0), fixture.variable_scroll.offset[1]);

    // A reveal outside a frame moves the persistent state; the next frame has
    // to honour it, which only works if the caller can publish the offset.
    try fixture.variable_state.reveal(400, .center, fixture.other.keys());
    _ = try fixture.app.scrollTo(try fixture.handle("variable"), .{
        0,
        @as(f32, @floatCast(fixture.variable_state.offset)),
    });
    try fixture.frame(2);
    const published = fixture.variable_scroll.offset[1];
    try std.testing.expect(published > 0);
    // The list adopted the published offset rather than reverting to 0, and
    // wrote the same number back out.
    try std.testing.expectEqual(published, @as(f32, @as(f32, @floatCast(fixture.variable_state.offset))));
    const range = fixture.variable_state.visible();
    try std.testing.expect(range.first <= 400 and 400 < range.end);
}
