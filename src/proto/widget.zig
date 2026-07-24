//! Widget tree types — arena-allocated widget nodes.
//!
//! PROTOTYPE — throwaway design exploration.

const std = @import("std");

/// Widget identity. In production this would be a u64 hash of
/// @src() + optional scope. For the prototype we use a plain u64.
pub const Id = u64;

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
