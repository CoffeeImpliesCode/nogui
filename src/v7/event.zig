//! v7 event dispatch — inject clicks from app.zig into widget handlers.
//! Per the prototype spec (notes/v7-prototype-spec.md §7).
//!
//! A click names a button node id. dispatchClick finds that node, reads the
//! button's `owner` component id, and calls its type-erased `on_click` with
//! the component pointer stored in the registry.
const std = @import("std");

const Id = @import("id.zig").Id;
const WidgetTree = @import("widget.zig").WidgetTree;
const WidgetNode = @import("widget.zig").WidgetNode;
const absoluteRect = @import("widget.zig").absoluteRect;
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

/// Find the button node; look up its owner in `components`; call on_click.
/// `components` is *std.AutoHashMapUnmanaged(Id, *Component).
///
/// No-op (return) if: node missing, not a button, no on_click, owner not
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
            const on_click = node.kind.button.on_click orelse return;
            const comp = components.get(node.kind.button.owner) orelse return;
            on_click(comp.ptr);
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

/// Set a slider's value from a pointer position (x in absolute layout
/// pixels). The slider rect is RELATIVE (to its parent's content box), so
/// it is resolved to absolute space via widget.absoluteRect first; the
/// mapping is linear across that rect, clamped to [min, max]. Returns false
/// (and changes nothing) when the node is missing or not a slider — the
/// caller can use that to distinguish slider hits from other widgets.
pub fn sliderSet(tree: *const WidgetTree, id: Id, x: f32) bool {
    const node = findNode(tree, id) orelse return false;
    const s = switch (node.kind) {
        .slider => |s| s,
        else => return false,
    };
    const r = absoluteRect(tree, id);
    if (r.w <= 0) return false;
    const t = std.math.clamp((x - r.x) / r.w, 0.0, 1.0);
    s.value.* = s.min + t * (s.max - s.min);
    return true;
}

// --- tests ---------------------------------------------------------------

const TestCounter = struct {
    clicks: u32 = 0,

    pub fn draw(self: *@This(), ctx: *DrawCtx) !void {
        _ = self;
        _ = ctx;
    }

    pub fn onClick(self: *@This()) void {
        self.clicks += 1;
    }
};

const BUTTON_ID: Id = @enumFromInt(10); // button, owner = OWNER_ID, has a handler
const LABEL_ID: Id = @enumFromInt(11); // not a button
const NO_HANDLER_ID: Id = @enumFromInt(12); // button, on_click == null
const ORPHAN_BUTTON_ID: Id = @enumFromInt(13); // button, owner never registered
const MISSING_ID: Id = @enumFromInt(999); // no node
const OWNER_ID: Id = @enumFromInt(1); // registered component
const ORPHAN_OWNER_ID: Id = @enumFromInt(99); // never registered

/// Tree covering every no-op path plus one live button; `components` maps
/// OWNER_ID → the counter component.
const Harness = struct {
    tree: WidgetTree,
    components: std.AutoHashMapUnmanaged(Id, Component),

    fn init(counter: *TestCounter) !Harness {
        var tree = WidgetTree.init(std.testing.allocator);
        errdefer tree.nodes.deinit(std.testing.allocator);

        try tree.nodes.append(std.testing.allocator, .{
            .id = BUTTON_ID,
            .kind = .{ .button = .{
                .label = "Go",
                .on_click = callback.wrap(TestCounter.onClick),
                .owner = OWNER_ID,
            } },
            .parent = .root,
        });
        try tree.nodes.append(std.testing.allocator, .{
            .id = LABEL_ID,
            .kind = .{ .label = .{ .text = "plain" } },
            .parent = .root,
        });
        try tree.nodes.append(std.testing.allocator, .{
            .id = NO_HANDLER_ID,
            .kind = .{ .button = .{ .label = "Dead", .owner = OWNER_ID } },
            .parent = .root,
        });
        try tree.nodes.append(std.testing.allocator, .{
            .id = ORPHAN_BUTTON_ID,
            .kind = .{ .button = .{
                .label = "Orphan",
                .on_click = callback.wrap(TestCounter.onClick),
                .owner = ORPHAN_OWNER_ID,
            } },
            .parent = .root,
        });

        var components: std.AutoHashMapUnmanaged(Id, Component) = .empty;
        errdefer components.deinit(std.testing.allocator);
        try components.put(std.testing.allocator, OWNER_ID, Component.make(TestCounter, counter));

        return .{ .tree = tree, .components = components };
    }

    fn deinit(self: *Harness) void {
        self.components.deinit(std.testing.allocator);
        self.tree.nodes.deinit(std.testing.allocator);
    }
};

test "dispatchClick: calls the wrapped handler on the registered owner" {
    var counter = TestCounter{};
    var h = try Harness.init(&counter);
    defer h.deinit();

    dispatchClick(&h.tree, .{ .click = .{ .button_id = BUTTON_ID } }, &h.components);

    try std.testing.expectEqual(@as(u32, 1), counter.clicks);
}

test "dispatchClick: missing button id is a no-op" {
    var counter = TestCounter{};
    var h = try Harness.init(&counter);
    defer h.deinit();

    dispatchClick(&h.tree, .{ .click = .{ .button_id = MISSING_ID } }, &h.components);

    try std.testing.expectEqual(@as(u32, 0), counter.clicks);
}

test "dispatchClick: non-button node is a no-op" {
    var counter = TestCounter{};
    var h = try Harness.init(&counter);
    defer h.deinit();

    dispatchClick(&h.tree, .{ .click = .{ .button_id = LABEL_ID } }, &h.components);

    try std.testing.expectEqual(@as(u32, 0), counter.clicks);
}

test "dispatchClick: button with null on_click is a no-op" {
    var counter = TestCounter{};
    var h = try Harness.init(&counter);
    defer h.deinit();

    dispatchClick(&h.tree, .{ .click = .{ .button_id = NO_HANDLER_ID } }, &h.components);

    try std.testing.expectEqual(@as(u32, 0), counter.clicks);
}

test "sliderSet: maps a click x linearly and clamps" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

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
    defer tree.nodes.deinit(std.testing.allocator);

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
    defer tree.nodes.deinit(std.testing.allocator);

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
        .box = .{ .padding = .{ .left = 10, .top = 10 }, .border = .{ .left = 2 } },
    });

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
    defer tree.nodes.deinit(std.testing.allocator);

    var volume: f32 = 0.5;
    const label_id: Id = @enumFromInt(30);
    try tree.nodes.append(std.testing.allocator, .{
        .id = label_id,
        .kind = .{ .label = .{ .text = "nope" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 50, .h = 20 },
    });

    try std.testing.expect(!sliderSet(&tree, label_id, 25));
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
    var counter = TestCounter{};
    var h = try Harness.init(&counter);
    defer h.deinit();

    dispatchClick(&h.tree, .{ .click = .{ .button_id = ORPHAN_BUTTON_ID } }, &h.components);

    try std.testing.expectEqual(@as(u32, 0), counter.clicks);
}
