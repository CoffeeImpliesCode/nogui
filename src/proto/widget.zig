//! Widget tree types — arena-allocated widget nodes.
//!
//! PROTOTYPE — throwaway design exploration.

const std = @import("std");
const IdInner = @import("id.zig");

/// Widget identity — deterministic u64 FNV-1a hash of
/// @src() + parent ID + optional extra discriminator.
/// See `id.zig` for construction.
pub const Id = IdInner.Id;

// ─── Event types (shared across event.zig and context.zig) ──

/// Widget interaction state machine.
pub const InteractionState = enum(u8) {
    inactive = 0,
    hot = 1,
    active = 2,
    focused = 3,
};

/// Mouse buttons.
pub const MouseButton = enum(u8) {
    left = 1,
    middle = 2,
    right = 3,
    x1 = 4,
    x2 = 5,
};

/// Key codes — a subset of common keys.
pub const Key = enum(u32) {
    unknown = 0,
    lshift,
    rshift,
    lctrl,
    rctrl,
    lalt,
    ralt,
    lgui,
    rgui,
    escape,
    enter,
    tab,
    backspace,
    delete,
    home,
    end,
    page_up,
    page_down,
    left,
    right,
    up,
    down,
    space,
    caps_lock,
    insert,
    print_screen,
    pause,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    k0,
    k1,
    k2,
    k3,
    k4,
    k5,
    k6,
    k7,
    k8,
    k9,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    minus,
    equals,
    left_bracket,
    right_bracket,
    semicolon,
    quote,
    comma,
    period,
    slash,
    backslash,
    grave,
};

/// Keyboard modifier mask.
pub const KeyMods = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    gui: bool = false,
    _padding: u4 = 0,
};

/// 2D size.
pub const Size = struct {
    width: f32,
    height: f32,

    pub const zero: Size = .{ .width = 0, .height = 0 };

    pub fn max(a: Size, b: Size) Size {
        return .{
            .width = @max(a.width, b.width),
            .height = @max(a.height, b.height),
        };
    }
};

/// 2D position.
pub const Pos = struct {
    x: f32,
    y: f32,
};

/// Axis-aligned rectangle.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

/// Per-axis sizing behaviour.
pub const SizingAxis = enum(u2) {
    /// Shrink-wrap to content. The widget takes its natural size
    /// (text width, image size, etc). Optional min/max clamp.
    fit = 0,
    /// Expand to fill available space. Siblings with `grow` share
    /// the remaining space evenly. Optional min/max clamp.
    grow = 1,
    /// Exact pixel size. Ignores available space.
    fixed = 2,
};

/// Sizing configuration for a widget.
pub const Sizing = struct {
    x: SizingAxis = .grow,
    y: SizingAxis = .fit,
    x_min: f32 = 0,
    x_max: f32 = std.math.floatMax(f32),
    y_min: f32 = 0,
    y_max: f32 = std.math.floatMax(f32),
};

/// Layout direction.
pub const Direction = enum(u1) {
    column = 0, // top-to-bottom
    row = 1, // left-to-right

    pub fn isVertical(d: Direction) bool {
        return d == .column;
    }
    pub fn isHorizontal(d: Direction) bool {
        return d == .row;
    }
};

/// The widget tree node. Tagged union so every widget variant
/// is a single pointer-sized node in the arena.
pub const Widget = struct {
    id: Id,
    sizing: Sizing,
    /// Filled by the layout pass.
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    kind: Kind,

    /// Box model: border, corner radius, colors.
    border: f32 = 0,
    corner_radius: f32 = 0,
    color: [4]f32 = .{ 0, 0, 0, 0 },
    border_color: [4]f32 = .{ 0, 0, 0, 1 },

    pub const Kind = union(enum) {
        column: struct {
            children: []const *Widget,
            padding: f32 = 0,
            gap: f32 = 4,
        },
        row: struct {
            children: []const *Widget,
            padding: f32 = 0,
            gap: f32 = 4,
        },
        button: struct {
            label: []const u8,
        },
        slider: struct {
            label: []const u8,
            value: *f32,
            min: f32,
            max: f32,
        },
        label: struct {
            text: []const u8,
        },
    };

    pub fn isContainer(self: *const Widget) bool {
        return switch (self.kind) {
            .column, .row => true,
            else => false,
        };
    }

    pub fn children(self: *const Widget) ?[]const *Widget {
        return switch (self.kind) {
            .column => |c| c.children,
            .row => |c| c.children,
            else => null,
        };
    }
};

const testing = std.testing;

test "Size.max: returns max of each axis" {
    const a: Size = .{ .width = 10, .height = 20 };
    const b: Size = .{ .width = 30, .height = 5 };
    const result = Size.max(a, b);
    try testing.expectEqual(@as(f32, 30), result.width);
    try testing.expectEqual(@as(f32, 20), result.height);
}

test "Size.max: with zero" {
    const a: Size = .{ .width = 0, .height = 0 };
    const b: Size = .{ .width = 10, .height = 10 };
    const result = Size.max(a, b);
    try testing.expectEqual(@as(f32, 10), result.width);
    try testing.expectEqual(@as(f32, 10), result.height);
}

test "Direction.isVertical" {
    try testing.expect(Direction.column.isVertical());
    try testing.expect(!Direction.row.isVertical());
}

test "Direction.isHorizontal" {
    try testing.expect(Direction.row.isHorizontal());
    try testing.expect(!Direction.column.isHorizontal());
}

fn testId(n: usize) Id {
    return @enumFromInt(n + 100);
}

test "Widget.isContainer: container kinds" {
    const child_id = testId(0);
    const parent_id = testId(1);
    var child: Widget = .{ .id = child_id, .sizing = .{}, .kind = .{ .label = .{ .text = "" } } };
    var col: Widget = .{ .id = parent_id, .sizing = .{}, .kind = .{ .column = .{ .children = &.{&child} } } };
    var row: Widget = .{ .id = parent_id, .sizing = .{}, .kind = .{ .row = .{ .children = &.{&child} } } };
    try testing.expect(col.isContainer());
    try testing.expect(row.isContainer());
}

test "Widget.isContainer: leaf kinds" {
    const id0 = testId(2);
    const id1 = testId(3);
    var btn: Widget = .{ .id = id0, .sizing = .{}, .kind = .{ .button = .{ .label = "" } } };
    var lbl: Widget = .{ .id = id1, .sizing = .{}, .kind = .{ .label = .{ .text = "" } } };
    try testing.expect(!btn.isContainer());
    try testing.expect(!lbl.isContainer());
}

test "Widget.children" {
    const child_id = testId(4);
    const parent_id = testId(5);
    const btn_id = testId(6);
    var child: Widget = .{ .id = child_id, .sizing = .{}, .kind = .{ .label = .{ .text = "c" } } };
    var col: Widget = .{ .id = parent_id, .sizing = .{}, .kind = .{ .column = .{ .children = &.{&child} } } };
    var btn: Widget = .{ .id = btn_id, .sizing = .{}, .kind = .{ .button = .{ .label = "b" } } };

    const got = col.children();
    try testing.expect(got != null);
    try testing.expectEqual(@as(usize, 1), got.?.len);
    try testing.expect(got.?[0].id == child_id);

    try testing.expect(btn.children() == null);
}
