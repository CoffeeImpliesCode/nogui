//! v7 event dispatch — inject clicks from app.zig into widget handlers.
//! Per the prototype spec (notes/v7-prototype-spec.md §7).
//!
//! A click names a button node id. dispatchClick finds that node, reads the
//! button's `owner` component id, and calls its bound callback (or legacy
//! `on_click`) with the component pointer stored in the registry.
const std = @import("std");

const Id = @import("id.zig").Id;
const WidgetTree = @import("widget.zig").WidgetTree;
const WidgetNode = @import("widget.zig").WidgetNode;
const visualBorderRect = @import("widget.zig").visualBorderRect;
const callback = @import("callback.zig");
const Component = @import("component.zig").Component;
const DrawCtx = @import("drawctx.zig").DrawCtx;

/// Mouse buttons (the driver normalizes platform buttons to these).
pub const MouseButton = enum { left, right, middle };

/// Keys the core understands (the driver maps platform scancodes here).
/// Navigation + activation only — text input is out of scope for now.
pub const Key = enum {
    tab,
    enter,
    space,
    escape,
    left,
    right,
    up,
    down,
    home,
    end,
};

pub const KeyEvent = struct {
    key: Key,
    shift: bool,
};

/// The complete input surface, injected by a DRIVER — the core never reads
/// a clock or polls input itself. Time arrives as data: every `.frame`
/// event carries the driver's tick and clock, so a headless driver can
/// replay a session deterministically (TigerBeetle-style full testing).
///
/// Drivers: the SDL window (OS events + vsync frames), the headless JSON
/// driver (`--sim`, events from a script), and the test harness (scripted
/// event sequences). The demo's interaction surface — clicks, sliders,
/// hover — is implemented entirely on these events in App.handle.
pub const Event = union(enum) {
    /// One rendered frame. `tick` = the driver's frame counter, `time_ms` =
    /// the driver's clock (monotonic). The core's only notion of time.
    frame: struct { tick: u32, time_ms: u64 },
    /// The surface size changed (the driver re-created its swapchain).
    resize: struct { width: f32, height: f32 },
    mouse_move: struct { x: f32, y: f32 },
    mouse_wheel: struct { x: f32, y: f32, delta_x: f32, delta_y: f32 },
    /// The cursor left the window (hover clears).
    mouse_leave: void,
    mouse_down: struct { button: MouseButton, x: f32, y: f32 },
    mouse_up: struct { button: MouseButton, x: f32, y: f32 },
    key_down: KeyEvent,
    key_up: KeyEvent,
    /// Internal dispatch target (buttons); produced by App.handle when a
    /// mouse_down hits a button.
    click: struct { button_id: Id },
};

/// Find the button node; look up its owner in `components`; call a bound
/// `user_callback` when present, otherwise call the legacy `on_click`.
/// `components` is *std.AutoHashMapUnmanaged(Id, *Component).
///
/// No-op (return) if: node missing, not a button, no callback, owner not
/// registered.
pub fn dispatchClick(
    tree: *const WidgetTree,
    event: Event,
    components: *std.AutoHashMapUnmanaged(Id, Component),
) void {
    switch (event) {
        .click => |click| {
            const node = findNode(tree, click.button_id) orelse return;
            if (node.kind != .button) return;
            const comp = components.get(node.kind.button.owner) orelse return;
            if (node.kind.button.user_callback) |user_callback| {
                user_callback.invoke(comp.ptr);
            } else {
                const on_click = node.kind.button.on_click orelse return;
                on_click(comp.ptr);
            }
        },
        else => {}, // input events route through App.handle, not dispatchClick
    }
}

/// Linear scan by id. widget.zig's `node()` takes a mutable tree; dispatch
/// receives a `*const WidgetTree`, so scan the const node slice directly.
fn findNode(tree: *const WidgetTree, id: Id) ?*const WidgetNode {
    for (tree.nodes.items) |*n| {
        if (n.id == id) return n;
    }
    return null;
}

/// Set a slider's value from a pointer position (x in visual surface pixels).
/// The slider rect is relative to its parent's content box, so it is resolved
/// into visual space via widget.visualBorderRect first; ancestor scroll
/// offsets therefore affect the mapping. The mapping is linear across that
/// rect, clamped to [min, max]. Returns false (and changes nothing) when the
/// node is missing or not a slider — the caller can use that to distinguish
/// slider hits from other widgets.
pub fn sliderSet(tree: *const WidgetTree, id: Id, x: f32) bool {
    const node = findNode(tree, id) orelse return false;
    const s = switch (node.kind) {
        .slider => |s| s,
        else => return false,
    };
    const r = visualBorderRect(tree, id);
    if (r.w <= 0) return false;
    const t = std.math.clamp((x - r.x) / r.w, 0.0, 1.0);
    s.value.* = s.min + t * (s.max - s.min);
    return true;
}

// --- tests ---------------------------------------------------------------

const TestCounter = struct {
    const Self = TestCounter;
    clicks: u32 = 0,
    data: usize = 0,

    pub fn draw(self: *Self, ctx: *DrawCtx) !void {
        _ = self;
        _ = ctx;
    }

    pub fn onClick(self: *Self) void {
        self.clicks += 1;
    }

    pub fn onData(self: *Self, data: usize) void {
        self.data = data;
    }
};

const button_id: Id = @enumFromInt(10); // button, owner = owner_id, has a handler
const label_id: Id = @enumFromInt(11); // not a button
const no_handler_id: Id = @enumFromInt(12); // button, on_click == null
const orphan_button_id: Id = @enumFromInt(13); // button, owner never registered
const missing_id: Id = @enumFromInt(999); // no node
const owner_id: Id = @enumFromInt(1); // registered component
const orphan_owner_id: Id = @enumFromInt(99); // never registered

/// Tree covering every no-op path plus one live button; `components` maps
/// owner_id → the counter component.
const Harness = struct {
    tree: WidgetTree,
    components: std.AutoHashMapUnmanaged(Id, Component),

    fn init(counter: *TestCounter) !Harness {
        var tree = WidgetTree.init(std.testing.allocator);
        errdefer tree.deinit();

        try tree.nodes.append(std.testing.allocator, .{
            .id = button_id,
            .kind = .{ .button = .{
                .label = "Go",
                .on_click = callback.wrap(TestCounter.onClick),
                .owner = owner_id,
            } },
            .parent = .root,
        });
        try tree.nodes.append(std.testing.allocator, .{
            .id = label_id,
            .kind = .{ .label = .{ .text = "plain" } },
            .parent = .root,
        });
        try tree.nodes.append(std.testing.allocator, .{
            .id = no_handler_id,
            .kind = .{ .button = .{ .label = "Dead", .owner = owner_id } },
            .parent = .root,
        });
        try tree.nodes.append(std.testing.allocator, .{
            .id = orphan_button_id,
            .kind = .{ .button = .{
                .label = "Orphan",
                .on_click = callback.wrap(TestCounter.onClick),
                .owner = orphan_owner_id,
            } },
            .parent = .root,
        });

        var components: std.AutoHashMapUnmanaged(Id, Component) = .empty;
        errdefer components.deinit(std.testing.allocator);
        try components.put(std.testing.allocator, owner_id, Component.make(TestCounter, counter));

        return .{ .tree = tree, .components = components };
    }

    fn deinit(self: *Harness) void {
        self.components.deinit(std.testing.allocator);
        self.tree.deinit();
        self.* = undefined;
    }
};

test "dispatchClick: calls the wrapped handler on the registered owner" {
    var counter: TestCounter = .{};
    var h = try Harness.init(&counter);
    defer h.deinit();

    dispatchClick(&h.tree, .{ .click = .{ .button_id = button_id } }, &h.components);

    try std.testing.expectEqual(@as(u32, 1), counter.clicks);
}

test "dispatchClick: invokes a button on_click_with_data callback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
    var counter: TestCounter = .{};
    var components: std.AutoHashMapUnmanaged(Id, Component) = .empty;
    defer components.deinit(std.testing.allocator);
    try components.put(std.testing.allocator, Id.root, Component.make(TestCounter, &counter));

    const button = try ctx.button(.{
        .label = "Data",
        .on_click_with_data = callback.bind(TestCounter.onData, @as(usize, 42)),
    });
    dispatchClick(&tree, .{ .click = .{ .button_id = button } }, &components);

    try std.testing.expectEqual(@as(usize, 42), counter.data);
    try std.testing.expectEqual(@as(u32, 0), counter.clicks);
}

test "dispatchClick: missing button id is a no-op" {
    var counter: TestCounter = .{};
    var h = try Harness.init(&counter);
    defer h.deinit();

    dispatchClick(&h.tree, .{ .click = .{ .button_id = missing_id } }, &h.components);

    try std.testing.expectEqual(@as(u32, 0), counter.clicks);
}

test "dispatchClick: non-button node is a no-op" {
    var counter: TestCounter = .{};
    var h = try Harness.init(&counter);
    defer h.deinit();

    dispatchClick(&h.tree, .{ .click = .{ .button_id = label_id } }, &h.components);

    try std.testing.expectEqual(@as(u32, 0), counter.clicks);
}

test "dispatchClick: button with null on_click is a no-op" {
    var counter: TestCounter = .{};
    var h = try Harness.init(&counter);
    defer h.deinit();

    dispatchClick(&h.tree, .{ .click = .{ .button_id = no_handler_id } }, &h.components);

    try std.testing.expectEqual(@as(u32, 0), counter.clicks);
}

test "sliderSet: maps a click x linearly and clamps" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var volume: f32 = 0.5;
    const slider_id: Id = @enumFromInt(20);
    try tree.nodes.append(std.testing.allocator, .{
        .id = slider_id,
        .kind = .{ .slider = .{ .label = "vol", .value = &volume, .min = 0, .max = 1 } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 0, .w = 100, .h = 20 },
    });

    // Left edge → min, right edge → max, middle → 0.5, beyond → clamped.
    try std.testing.expect(sliderSet(&tree, slider_id, 10));
    try std.testing.expectEqual(@as(f32, 0), volume);
    try std.testing.expect(sliderSet(&tree, slider_id, 110));
    try std.testing.expectEqual(@as(f32, 1), volume);
    try std.testing.expect(sliderSet(&tree, slider_id, 60));
    try std.testing.expectEqual(@as(f32, 0.5), volume);
    try std.testing.expect(sliderSet(&tree, slider_id, -50));
    try std.testing.expectEqual(@as(f32, 0), volume);
    try std.testing.expect(sliderSet(&tree, slider_id, 999));
    try std.testing.expectEqual(@as(f32, 1), volume);
}

test "sliderSet: maps through a non-zero [min, max] range" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var gain: f32 = 0;
    const slider_id: Id = @enumFromInt(21);
    try tree.nodes.append(std.testing.allocator, .{
        .id = slider_id,
        .kind = .{ .slider = .{ .label = "gain", .value = &gain, .min = 2, .max = 6 } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 50, .h = 20 },
    });

    try std.testing.expect(sliderSet(&tree, slider_id, 25)); // t = 0.5
    try std.testing.expectEqual(@as(f32, 4), gain);
    try std.testing.expect(sliderSet(&tree, slider_id, 50));
    try std.testing.expectEqual(@as(f32, 6), gain);
}

test "sliderSet: resolves the absolute rect through a padded+bordered parent" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var volume: f32 = 0.5;
    const col_id: Id = @enumFromInt(40);
    const slider_id: Id = @enumFromInt(41);
    // Slider sits at (0,0) inside the column's content box; the column is
    // at the surface origin with border.left=2 and padding left/top=10.
    try tree.nodes.append(std.testing.allocator, .{
        .id = slider_id,
        .kind = .{ .slider = .{ .label = "vol", .value = &volume, .min = 0, .max = 1 } },
        .parent = col_id,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 24 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = col_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 200, .h = 200 },
        .style = .{
            .padding_inset = .{
                .top = .{ .length = 10 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 10 },
            },
            .border_inset = .{
                .top = .{ .length = 0 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 2 },
            },
        },
    });
    try tree.appendChild(col_id, slider_id);

    // Absolute slider box = (0 + 0 + 2 + 10, 0 + 0 + 0 + 10, 100, 24):
    // x=12 is the left edge → min, x=112 is the right edge → max. Using
    // the raw relative x (0/100) would give the wrong mapping.
    try std.testing.expect(sliderSet(&tree, slider_id, 12));
    try std.testing.expectEqual(@as(f32, 0), volume);
    try std.testing.expect(sliderSet(&tree, slider_id, 112));
    try std.testing.expectEqual(@as(f32, 1), volume);
}

test "sliderSet: non-slider and missing nodes return false, value untouched" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var volume: f32 = 0.5;
    const nope_id: Id = @enumFromInt(30);
    try tree.nodes.append(std.testing.allocator, .{
        .id = nope_id,
        .kind = .{ .label = .{ .text = "nope" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 50, .h = 20 },
    });

    try std.testing.expect(!sliderSet(&tree, nope_id, 25));
    try std.testing.expect(!sliderSet(&tree, @enumFromInt(999), 25));
    // And a slider with a zero-size rect never writes.
    const zero_id: Id = @enumFromInt(31);
    try tree.nodes.append(std.testing.allocator, .{
        .id = zero_id,
        .kind = .{ .slider = .{ .label = "z", .value = &volume, .min = 0, .max = 1 } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    });
    try std.testing.expect(!sliderSet(&tree, zero_id, 25));
    try std.testing.expectEqual(@as(f32, 0.5), volume);
}

test "dispatchClick: unregistered owner is a no-op" {
    var counter: TestCounter = .{};
    var h = try Harness.init(&counter);
    defer h.deinit();

    dispatchClick(&h.tree, .{ .click = .{ .button_id = orphan_button_id } }, &h.components);

    try std.testing.expectEqual(@as(u32, 0), counter.clicks);
}
