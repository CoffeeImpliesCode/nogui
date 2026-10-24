//! Routed v7 input. The driver supplies values; the tree supplies ancestry.
//! Dispatch never allocates and keeps propagation separate from default actions.
const std = @import("std");

const FrameNodeId = @import("id.zig").FrameNodeId;
const WidgetId = @import("id.zig").WidgetId;
const WidgetTree = @import("widget.zig").WidgetTree;
const Rect = @import("widget.zig").Rect;
const widget = @import("widget.zig");
const visualBorderRect = widget.visualBorderRect;
const input = @import("input.zig");
const callback = @import("callback.zig");
const Component = @import("component.zig").Component;
const DrawCtx = @import("drawctx.zig").DrawCtx;

/// Mouse buttons use native ordering only at the driver boundary.
pub const MouseButton = enum(u8) { left, right, middle, back, forward, _ };

/// A mouse button or a device-qualified touch contact.
pub const PointerId = union(enum) {
    mouse: MouseButton,
    touch: u128,
};

pub const PointerButtons = packed struct(u8) {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    back: bool = false,
    forward: bool = false,
    reserved: u3 = 0,
};

/// Navigation keys known to the core; unidentified keys still route with
/// physical and logical identities so text consumers need no private path.
pub const Key = enum {
    unidentified,
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

pub const Modifiers = packed struct(u16) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    left_shift: bool = false,
    right_shift: bool = false,
    left_control: bool = false,
    right_control: bool = false,
    reserved: u6 = 0,
};

/// HID/scancode identity is physical and never inferred from translated text.
pub const PhysicalKey = struct { code: u32 };
pub const LogicalKey = union(enum) {
    named: Key,
    character: []const u8,
    /// A Unicode scalar from a native keycode needs no temporary UTF-8 slice.
    codepoint: u21,
    unidentified,
};
pub const KeyEvent = struct {
    key: Key = .unidentified,
    /// Compatible with existing callers; new drivers also set modifiers.shift.
    shift: bool = false,
    modifiers: Modifiers = .{},
    physical: ?PhysicalKey = null,
    logical: LogicalKey = .unidentified,
    repeat: bool = false,

    pub fn shifted(self: KeyEvent) bool {
        return self.shift or self.modifiers.shift;
    }
};

pub const PointerEvent = struct {
    button: MouseButton = .left,
    x: f32 = 0,
    y: f32 = 0,
    click_count: u8 = 1,
    modifiers: Modifiers = .{},
};
pub const TouchEvent = struct {
    /// Device ID in the high 64 bits, finger ID in the low 64 bits.
    id: u128,
    x: f32,
    y: f32,
    pressure: f32 = 0,
};
pub const ScrollUnit = enum { line, pixel, page };
pub const ScrollPhase = enum { begin, update, end, momentum };
pub const WheelEvent = struct {
    x: f32,
    y: f32,
    delta_x: f32,
    delta_y: f32,
    unit: ScrollUnit = .line,
    phase: ScrollPhase = .update,
    /// Native natural/flipped direction is preserved; deltas are not re-inverted.
    natural: bool = false,
    modifiers: Modifiers = .{},
};
pub const CompositionPhase = enum { start, update, end };
pub const CompositionEvent = struct {
    phase: CompositionPhase,
    /// Borrowed UTF-8 preedit; selection offsets count bytes into text.
    text: []const u8 = "",
    selection_start: usize = 0,
    selection_end: usize = 0,
};
pub const ActivationSource = enum { pointer, keyboard, accessibility };
pub const Activation = struct {
    target_id: WidgetId,
    source: ActivationSource,
    click_count: u8 = 1,
};

/// Drivers feed one complete input value at a time. A key repeat is not text:
/// only text_input carries committed UTF-8; composition carries preedit.
pub const Event = union(enum) {
    frame: struct { tick: u32, time_ms: u64 },
    resize: struct { width: f32, height: f32 },
    mouse_move: struct {
        x: f32,
        y: f32,
        buttons: PointerButtons = .{},
        modifiers: Modifiers = .{},
    },
    mouse_wheel: WheelEvent,
    /// Leaving clears hover; it does not release a pointer captured in-window.
    mouse_leave: void,
    /// Losing window focus revokes all captures and blurs keyboard focus.
    window_focus_lost: void,
    mouse_down: PointerEvent,
    mouse_up: PointerEvent,
    mouse_cancel: PointerEvent,
    touch_start: TouchEvent,
    touch_move: TouchEvent,
    touch_end: TouchEvent,
    touch_cancel: TouchEvent,
    key_down: KeyEvent,
    key_up: KeyEvent,
    text_input: struct { text: []const u8 },
    composition: CompositionEvent,
    /// Routed semantic action, shared by pointer, keyboard and accessibility.
    activate: Activation,
    focus_in: struct { target_id: WidgetId, related: ?WidgetId = null },
    focus_out: struct { target_id: WidgetId, related: ?WidgetId = null },
    /// Capture was revoked without a native position (removal/window blur).
    /// Raw mouse_cancel/touch_cancel remain reserved for actual host input.
    capture_lost: struct { target_id: WidgetId, pointer: PointerId },
};

pub const Phase = enum { capture, target, bubble };

pub const DispatchContext = struct {
    event: *const Event,
    target: FrameNodeId,
    current_target: FrameNodeId,
    phase: Phase,
    propagation_stopped: bool = false,
    default_prevented: bool = false,
    /// Set by a successful wheel default; null if no scroller consumed it.
    default_target: ?FrameNodeId = null,

    pub fn stopPropagation(self: *DispatchContext) void {
        self.propagation_stopped = true;
    }

    pub fn preventDefault(self: *DispatchContext) void {
        self.default_prevented = true;
    }
};

pub const Handlers = struct {
    user: *anyopaque,
    /// The owner chooses which widget/component callback handles each node.
    on_event: *const fn (*anyopaque, *DispatchContext) void,
    /// Called once for non-wheel events unless the default was prevented.
    on_default: ?*const fn (*anyopaque, *DispatchContext) void = null,
};

/// One route against the committed tree. Ancestor capture walks from the
/// outermost node without building a path; bubble walks parent pointers.
/// Callers must not replace the tree from a routing callback.
pub fn dispatch(
    tree: *const WidgetTree,
    target: FrameNodeId,
    ev: *const Event,
    handlers: Handlers,
) ?DispatchContext {
    switch (ev.*) {
        .activate => |action| {
            if ((tree.frameNode(action.target_id) orelse return null) != target) return null;
        },
        .focus_in => |change| {
            if ((tree.frameNode(change.target_id) orelse return null) != target) return null;
        },
        .focus_out => |change| {
            if ((tree.frameNode(change.target_id) orelse return null) != target) return null;
        },
        .capture_lost => |lost| {
            if ((tree.frameNode(lost.target_id) orelse return null) != target) return null;
        },
        else => {},
    }
    if (!widget.isVisible(tree, target)) return null;
    const target_node = tree.nodeConst(target) orelse return null;
    var depth: usize = 0;
    var ancestor = target_node.parent;
    var inline_ancestors: [64]FrameNodeId = undefined;
    while (ancestor != .root) {
        if (depth >= tree.nodes.items.len) return null;
        if (depth < inline_ancestors.len) inline_ancestors[depth] = ancestor;
        const node = tree.nodeConst(ancestor) orelse return null;
        ancestor = node.parent;
        depth += 1;
    }
    var context: DispatchContext = .{
        .event = ev,
        .target = target,
        .current_target = target,
        .phase = .capture,
    };
    var remaining = depth;
    while (remaining > 0) : (remaining -= 1) {
        if (remaining <= inline_ancestors.len) {
            ancestor = inline_ancestors[remaining - 1];
        } else {
            ancestor = target_node.parent;
            var hops: usize = 1;
            while (hops < remaining) : (hops += 1) {
                ancestor = tree.nodeConst(ancestor).?.parent;
            }
        }
        context.current_target = ancestor;
        handlers.on_event(handlers.user, &context);
        if (context.propagation_stopped) break;
    }
    if (!context.propagation_stopped) {
        context.phase = .target;
        context.current_target = target;
        handlers.on_event(handlers.user, &context);
    }
    if (!context.propagation_stopped) {
        context.phase = .bubble;
        ancestor = target_node.parent;
        remaining = depth;
        while (remaining > 0) : (remaining -= 1) {
            context.current_target = ancestor;
            handlers.on_event(handlers.user, &context);
            if (context.propagation_stopped) break;
            ancestor = tree.nodeConst(ancestor).?.parent;
        }
    }
    context.current_target = target;
    context.phase = .target;
    if (!context.default_prevented) {
        switch (ev.*) {
            .mouse_wheel => |wheel| context.default_target = scrollNearest(tree, target, wheel),
            else => {
                if (handlers.on_default) |on_default| on_default(handlers.user, &context);
            },
        }
    }
    return context;
}

/// A wheel has one default consumer, the nearest scrolling ancestor. Stopping
/// propagation alone does not suppress this action.
fn scrollNearest(tree: *const WidgetTree, target: FrameNodeId, wheel: WheelEvent) ?FrameNodeId {
    var current = target;
    var remaining = tree.nodes.items.len;
    while (current != .root and remaining > 0) : (remaining -= 1) {
        const node = tree.nodeConst(current) orelse return null;
        if (node.scroll) |spec| {
            const rect = widget.visualBorderRect(tree, current);
            const scale_x: f32 = switch (wheel.unit) {
                .pixel => 1,
                .line => 20,
                .page => rect.w,
            };
            const scale_y: f32 = switch (wheel.unit) {
                .pixel => 1,
                .line => 20,
                .page => rect.h,
            };
            switch (spec.axis) {
                .horizontal, .both => {
                    spec.state.offset[0] = std.math.clamp(
                        spec.state.offset[0] - wheel.delta_x * scale_x,
                        0,
                        spec.state.max_offset[0],
                    );
                },
                .vertical => {},
            }
            switch (spec.axis) {
                .vertical, .both => {
                    spec.state.offset[1] = std.math.clamp(
                        spec.state.offset[1] - wheel.delta_y * scale_y,
                        0,
                        spec.state.max_offset[1],
                    );
                },
                .horizontal => {},
            }
            return current;
        }
        current = node.parent;
    }
    return null;
}

/// Semantic activation is identical for pointer release, keyboard and
/// accessibility. A stale/disabled/hidden handle cannot mutate a control.
pub fn activate(
    tree: *const WidgetTree,
    target: WidgetId,
    components: *std.AutoHashMapUnmanaged(FrameNodeId, Component),
) bool {
    const id = tree.frameNode(target) orelse return false;
    return activateNode(tree, id, components);
}

fn activateNode(
    tree: *const WidgetTree,
    id: FrameNodeId,
    components: *std.AutoHashMapUnmanaged(FrameNodeId, Component),
) bool {
    const node = tree.nodeConst(id) orelse return false;
    if (!input.isEnabled(tree, id)) return false;
    switch (node.kind) {
        .button => |button| {
            const comp = components.get(button.owner) orelse return false;
            if (button.user_callback) |user_callback| {
                user_callback.invoke(comp.ptr);
            } else {
                const on_click = button.on_click orelse return false;
                on_click(comp.ptr);
            }
        },
        .checkbox => |checkbox| checkbox.value.* = !checkbox.value.*,
        .switch_control => |switch_control| switch_control.value.* = !switch_control.value.*,
        .radio => |radio| radio.selected.* = radio.option,
        else => return false,
    }
    return true;
}
/// Set a slider's value from a pointer position (x in visual surface pixels).
/// `rect` is the slider's box where the pointer can see it: its laid-out
/// border rect, translated by the overlay placement that covers it. Passing
/// the resolved rect keeps a slider inside a popover mapped against the box
/// it is painted in, and the caller owns that resolution. The mapping is
/// linear across that rect, clamped to [min, max]. Returns false (and changes
/// nothing) when the node is missing or not a slider — the caller can use that
/// to distinguish slider hits from other widgets.
pub fn sliderSet(tree: *const WidgetTree, id: FrameNodeId, x: f32, rect: Rect) bool {
    const node = tree.nodeConst(id) orelse return false;
    if (!input.isEnabled(tree, id)) return false;
    const s = switch (node.kind) {
        .slider => |s| s,
        else => return false,
    };
    if (rect.w <= 0) return false;
    const t = std.math.clamp((x - rect.x) / rect.w, 0.0, 1.0);
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

const button_id: FrameNodeId = @fromBackingInt(@intCast(10));
const label_id: FrameNodeId = @fromBackingInt(@intCast(11));
const no_handler_id: FrameNodeId = @fromBackingInt(@intCast(12));
const orphan_button_id: FrameNodeId = @fromBackingInt(@intCast(13));
const owner_id: FrameNodeId = @fromBackingInt(@intCast(1));
const orphan_owner_id: FrameNodeId = @fromBackingInt(@intCast(99));
const button_key: WidgetId = .{ .owner = 42, .slot = 10, .generation = 1 };
const label_key: WidgetId = .{ .owner = 42, .slot = 11, .generation = 1 };
const no_handler_key: WidgetId = .{ .owner = 42, .slot = 12, .generation = 1 };
const orphan_button_key: WidgetId = .{ .owner = 42, .slot = 13, .generation = 1 };
const missing_key: WidgetId = .{ .owner = 42, .slot = 999, .generation = 1 };

/// Tree covering every no-op path plus one live button; `components` maps
/// owner_id → the counter component.
const Harness = struct {
    tree: WidgetTree,
    components: std.AutoHashMapUnmanaged(FrameNodeId, Component),

    fn init(counter: *TestCounter) !Harness {
        var tree = WidgetTree.init(std.testing.allocator);
        errdefer tree.deinit();

        try tree.nodes.append(std.testing.allocator, .{
            .id = button_id,
            .widget_id = button_key,
            .kind = .{ .button = .{
                .label = "Go",
                .on_click = callback.wrap(TestCounter.onClick),
                .owner = owner_id,
            } },
            .parent = .root,
        });
        try tree.nodes.append(std.testing.allocator, .{
            .id = label_id,
            .widget_id = label_key,
            .kind = .{ .label = .{ .text = "plain" } },
            .parent = .root,
        });
        try tree.nodes.append(std.testing.allocator, .{
            .id = no_handler_id,
            .widget_id = no_handler_key,
            .kind = .{ .button = .{ .label = "Dead", .owner = owner_id } },
            .parent = .root,
        });
        try tree.nodes.append(std.testing.allocator, .{
            .id = orphan_button_id,
            .widget_id = orphan_button_key,
            .kind = .{ .button = .{
                .label = "Orphan",
                .on_click = callback.wrap(TestCounter.onClick),
                .owner = orphan_owner_id,
            } },
            .parent = .root,
        });

        var components: std.AutoHashMapUnmanaged(FrameNodeId, Component) = .empty;
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

test "semantic activate invokes the registered button owner" {
    var counter: TestCounter = .{};
    var h = try Harness.init(&counter);
    defer h.deinit();

    try std.testing.expect(activate(&h.tree, button_key, &h.components));

    try std.testing.expectEqual(@as(u32, 1), counter.clicks);
}

test "semantic activate invokes a button's data callback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
    var counter: TestCounter = .{};
    var components: std.AutoHashMapUnmanaged(FrameNodeId, Component) = .empty;
    defer components.deinit(std.testing.allocator);
    try components.put(std.testing.allocator, FrameNodeId.root, Component.make(TestCounter, &counter));

    const button = try ctx.button(.{
        .label = "Data",
        .on_click_with_data = callback.bind(TestCounter.onData, @as(usize, 42)),
    });
    const data_key: WidgetId = .{ .owner = 42, .slot = 20, .generation = 1 };
    try tree.bindWidget(button, data_key);
    try std.testing.expect(activate(&tree, data_key, &components));

    try std.testing.expectEqual(@as(usize, 42), counter.data);
    try std.testing.expectEqual(@as(u32, 0), counter.clicks);
}

test "semantic activate ignores a stale widget handle" {
    var counter: TestCounter = .{};
    var h = try Harness.init(&counter);
    defer h.deinit();

    try std.testing.expect(!activate(&h.tree, missing_key, &h.components));

    try std.testing.expectEqual(@as(u32, 0), counter.clicks);
}

test "semantic activate does not act on a display node" {
    var counter: TestCounter = .{};
    var h = try Harness.init(&counter);
    defer h.deinit();

    try std.testing.expect(!activate(&h.tree, label_key, &h.components));

    try std.testing.expectEqual(@as(u32, 0), counter.clicks);
}

test "semantic activate ignores a button without a handler" {
    var counter: TestCounter = .{};
    var h = try Harness.init(&counter);
    defer h.deinit();

    try std.testing.expect(!activate(&h.tree, no_handler_key, &h.components));

    try std.testing.expectEqual(@as(u32, 0), counter.clicks);
}

test "sliderSet: maps a click x linearly and clamps" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var volume: f32 = 0.5;
    const slider_id: FrameNodeId = @fromBackingInt(@intCast(20));
    try tree.nodes.append(std.testing.allocator, .{
        .id = slider_id,
        .kind = .{ .slider = .{ .label = "vol", .value = &volume, .min = 0, .max = 1 } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 0, .w = 100, .h = 20 },
    });

    // Left edge → min, right edge → max, middle → 0.5, beyond → clamped.
    try std.testing.expect(sliderSet(&tree, slider_id, 10, visualBorderRect(&tree, slider_id)));
    try std.testing.expectEqual(@as(f32, 0), volume);
    try std.testing.expect(sliderSet(&tree, slider_id, 110, visualBorderRect(&tree, slider_id)));
    try std.testing.expectEqual(@as(f32, 1), volume);
    try std.testing.expect(sliderSet(&tree, slider_id, 60, visualBorderRect(&tree, slider_id)));
    try std.testing.expectEqual(@as(f32, 0.5), volume);
    try std.testing.expect(sliderSet(&tree, slider_id, -50, visualBorderRect(&tree, slider_id)));
    try std.testing.expectEqual(@as(f32, 0), volume);
    try std.testing.expect(sliderSet(&tree, slider_id, 999, visualBorderRect(&tree, slider_id)));
    try std.testing.expectEqual(@as(f32, 1), volume);
}

test "sliderSet: maps through a non-zero [min, max] range" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var gain: f32 = 0;
    const slider_id: FrameNodeId = @fromBackingInt(@intCast(21));
    try tree.nodes.append(std.testing.allocator, .{
        .id = slider_id,
        .kind = .{ .slider = .{ .label = "gain", .value = &gain, .min = 2, .max = 6 } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 50, .h = 20 },
    });

    try std.testing.expect(sliderSet(&tree, slider_id, 25, visualBorderRect(&tree, slider_id)));
    try std.testing.expectEqual(@as(f32, 4), gain);
    try std.testing.expect(sliderSet(&tree, slider_id, 50, visualBorderRect(&tree, slider_id)));
    try std.testing.expectEqual(@as(f32, 6), gain);
}

test "sliderSet: resolves the absolute rect through a padded+bordered parent" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var volume: f32 = 0.5;
    const col_id: FrameNodeId = @fromBackingInt(@intCast(40));
    const slider_id: FrameNodeId = @fromBackingInt(@intCast(41));
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
    try std.testing.expect(sliderSet(&tree, slider_id, 12, visualBorderRect(&tree, slider_id)));
    try std.testing.expectEqual(@as(f32, 0), volume);
    try std.testing.expect(sliderSet(&tree, slider_id, 112, visualBorderRect(&tree, slider_id)));
    try std.testing.expectEqual(@as(f32, 1), volume);
}

test "sliderSet: non-slider and missing nodes return false, value untouched" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var volume: f32 = 0.5;
    const nope_id: FrameNodeId = @fromBackingInt(@intCast(30));
    try tree.nodes.append(std.testing.allocator, .{
        .id = nope_id,
        .kind = .{ .label = .{ .text = "nope" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 50, .h = 20 },
    });

    try std.testing.expect(!sliderSet(&tree, nope_id, 25, visualBorderRect(&tree, nope_id)));
    try std.testing.expect(!sliderSet(&tree, @fromBackingInt(@intCast(999)), 25, .{ .w = 100 }));
    // And a slider with a zero-size rect never writes.
    const zero_id: FrameNodeId = @fromBackingInt(@intCast(31));
    try tree.nodes.append(std.testing.allocator, .{
        .id = zero_id,
        .kind = .{ .slider = .{ .label = "z", .value = &volume, .min = 0, .max = 1 } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    });
    try std.testing.expect(!sliderSet(&tree, zero_id, 25, visualBorderRect(&tree, zero_id)));
    try std.testing.expectEqual(@as(f32, 0.5), volume);
}

test "semantic activate ignores an unregistered button owner" {
    var counter: TestCounter = .{};
    var h = try Harness.init(&counter);
    defer h.deinit();

    try std.testing.expect(!activate(&h.tree, orphan_button_key, &h.components));

    try std.testing.expectEqual(@as(u32, 0), counter.clicks);
}
test "semantic activate toggles controls and selects radio options" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var checked = false;
    var enabled = false;
    var selected: ?u32 = null;
    const checkbox_id: FrameNodeId = @fromBackingInt(@intCast(51));
    const switch_id: FrameNodeId = @fromBackingInt(@intCast(52));
    const first_radio_id: FrameNodeId = @fromBackingInt(@intCast(53));
    const second_radio_id: FrameNodeId = @fromBackingInt(@intCast(54));
    try tree.nodes.append(std.testing.allocator, .{
        .id = checkbox_id,
        .widget_id = .{ .owner = 42, .slot = 51, .generation = 1 },
        .kind = .{ .checkbox = .{ .label = "check", .value = &checked } },
        .parent = .root,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = switch_id,
        .widget_id = .{ .owner = 42, .slot = 52, .generation = 1 },
        .kind = .{ .switch_control = .{ .label = "switch", .value = &enabled } },
        .parent = .root,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = first_radio_id,
        .widget_id = .{ .owner = 42, .slot = 53, .generation = 1 },
        .kind = .{ .radio = .{ .label = "first", .selected = &selected, .option = 1 } },
        .parent = .root,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = second_radio_id,
        .widget_id = .{ .owner = 42, .slot = 54, .generation = 1 },
        .kind = .{ .radio = .{ .label = "second", .selected = &selected, .option = 2 } },
        .parent = .root,
    });
    var components: std.AutoHashMapUnmanaged(FrameNodeId, Component) = .empty;
    defer components.deinit(std.testing.allocator);

    try std.testing.expect(activate(&tree, .{ .owner = 42, .slot = 51, .generation = 1 }, &components));
    try std.testing.expect(activate(&tree, .{ .owner = 42, .slot = 52, .generation = 1 }, &components));
    try std.testing.expect(activate(&tree, .{ .owner = 42, .slot = 54, .generation = 1 }, &components));
    try std.testing.expect(checked);
    try std.testing.expect(enabled);
    try std.testing.expectEqual(@as(?u32, 2), selected);

    try std.testing.expect(activate(&tree, .{ .owner = 42, .slot = 53, .generation = 1 }, &components));
    try std.testing.expect(activate(&tree, .{ .owner = 42, .slot = 51, .generation = 1 }, &components));
    try std.testing.expect(!checked);
    try std.testing.expectEqual(@as(?u32, 1), selected);
}

test "api-w08 hidden ancestor blocks semantic activation and slider mutation" {
    var counter: TestCounter = .{};
    var h = try Harness.init(&counter);
    defer h.deinit();
    const hidden_id: FrameNodeId = @fromBackingInt(@intCast(30));
    const slider_id: FrameNodeId = @fromBackingInt(@intCast(31));
    var slider_value: f32 = 0;
    try h.tree.appendNode(.{
        .id = hidden_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{ .visibility = .hidden },
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 40 },
    });
    h.tree.node(button_id).?.parent = hidden_id;
    try h.tree.appendNode(.{
        .id = slider_id,
        .kind = .{ .slider = .{
            .label = "hidden slider",
            .value = &slider_value,
            .min = 0,
            .max = 1,
        } },
        .parent = hidden_id,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 20 },
    });

    try std.testing.expect(!activate(&h.tree, button_key, &h.components));
    try std.testing.expect(!sliderSet(&h.tree, slider_id, 50, visualBorderRect(&h.tree, slider_id)));
    try std.testing.expectEqual(@as(u32, 0), counter.clicks);
    try std.testing.expectEqual(@as(f32, 0), slider_value);

    h.tree.node(hidden_id).?.style.visibility = .visible;
    try std.testing.expect(activate(&h.tree, button_key, &h.components));
    try std.testing.expect(sliderSet(&h.tree, slider_id, 50, visualBorderRect(&h.tree, slider_id)));
    try std.testing.expectEqual(@as(u32, 1), counter.clicks);
    try std.testing.expectEqual(@as(f32, 0.5), slider_value);
}
