//! Two-phase layout engine — measure then position.
//!
//! Phase 1 (measure): bottom-up. Each widget computes its
//!   minimum/preferred size given the available space.
//!   Containers aggregate child sizes.
//!
//! Phase 2 (position): top-down. Each widget receives its
//!   final position and size. Containers distribute space
//!   among children.
//!
//! PROTOTYPE — throwaway design exploration.

const std = @import("std");
const Widget = @import("widget.zig").Widget;
const Sizing = @import("widget.zig").Sizing;
const Size = @import("widget.zig").Size;
const Rect = @import("widget.zig").Rect;
const Pos = @import("widget.zig").Pos;
const Direction = @import("widget.zig").Direction;
const SizingAxis = @import("widget.zig").SizingAxis;

/// Fully resolved layout: measured sizes + final positions.
pub const LayoutResult = struct {
    size: Size,
};

/// ── Phase 1: Measure ─────────────────────────────────────────
/// Measure a widget tree and return the total size.
/// `available` is the space the parent has for this widget.
pub fn measure(root: *Widget, available: Size) LayoutResult {
    return measureNode(root, available);
}

fn measureNode(w: *Widget, available: Size) LayoutResult {
    const sz = switch (w.kind) {
        .button => |b| measureButton(b, w.sizing, available),
        .label => |l| measureLabel(l, w.sizing, available),
        .slider => |s| measureSlider(s, w.sizing, available),
        .column => |c| measureColumn(c, w.sizing, available),
        .row => |r| measureRow(r, w.sizing, available),
    };

    // Clamp to sizing min/max
    const clamped = Size{
        .width = clampToSizing(w.sizing, sz.width, .x),
        .height = clampToSizing(w.sizing, sz.height, .y),
    };

    // For grow, we take the available space minus padding
    // (handled by parent distribution). For the measure pass,
    // we report our minimum content size + clamp.
    // Write measured size into rect so position pass can read it.
    w.rect.w = clamped.width;
    w.rect.h = clamped.height;
    return .{ .size = clamped };
}

fn clampToSizing(sizing: anytype, value: f32, axis: enum { x, y }) f32 {
    const min = if (axis == .x) sizing.x_min else sizing.y_min;
    const max = if (axis == .x) sizing.x_max else sizing.y_max;
    return @max(min, @min(value, max));
}

fn measureButton(b: anytype, sizing: Sizing, available: Size) Size {
    _ = available;
    // Rough: 8px per char + 16px horizontal padding
    const text_w: f32 = @max(30, @as(f32, @floatFromInt(b.label.len)) * 8 + 16);
    const text_h: f32 = 24;
    return clampToAxis(sizing, text_w, text_h);
}

fn measureLabel(l: anytype, sizing: Sizing, available: Size) Size {
    _ = available;
    const text_w: f32 = @max(20, @as(f32, @floatFromInt(l.text.len)) * 8 + 8);
    const text_h: f32 = 12;
    return clampToAxis(sizing, text_w, text_h);
}

fn measureSlider(s: anytype, sizing: Sizing, available: Size) Size {
    _ = available;
    // Label + slider thumb space
    const label_w: f32 = @as(f32, @floatFromInt(s.label.len)) * 8 + 16;
    const text_w: f32 = @max(120, label_w + 40);
    const text_h: f32 = 24;
    return clampToAxis(sizing, text_w, text_h);
}

fn measureColumn(c: anytype, sizing: Sizing, available: Size) Size {
    // For a column: children stack vertically.
    // We measure children with the available width (minus padding).
    // Height is the sum of child heights + gaps + padding.
    const inner_w = available.width - 2 * c.padding;
    var total_h: f32 = 2 * c.padding;
    var max_w: f32 = 0;
    var grow_count: u32 = 0;

    for (c.children) |child| {
        if (child.sizing.y == .grow) grow_count += 1;
        const child_available = Size{ .width = inner_w, .height = std.math.floatMax(f32) };
        const result = measureNode(child, child_available);
        total_h += result.size.height;
        max_w = @max(max_w, result.size.width);
    }

    total_h += c.gap * @max(0, @as(f32, @floatFromInt(c.children.len)) - 1);

    // If we have grow children, the height might expand
    // (handled in position phase). Report content size.
    return clampToAxis(sizing, max_w + 2 * c.padding, total_h);
}

fn measureRow(r: anytype, sizing: Sizing, available: Size) Size {
    const inner_h = available.height - 2 * r.padding;
    var total_w: f32 = 2 * r.padding;
    var max_h: f32 = 0;
    var grow_count: u32 = 0;

    for (r.children) |child| {
        if (child.sizing.x == .grow) grow_count += 1;
        const child_available = Size{ .width = std.math.floatMax(f32), .height = inner_h };
        const result = measureNode(child, child_available);
        total_w += result.size.width;
        max_h = @max(max_h, result.size.height);
    }

    total_w += r.gap * @max(0, @as(f32, @floatFromInt(r.children.len)) - 1);

    return clampToAxis(sizing, total_w, max_h + 2 * r.padding);
}

fn clampToAxis(sizing: Sizing, w: f32, h: f32) Size {
    return .{
        .width = clampToSizing(sizing, w, .x),
        .height = clampToSizing(sizing, h, .y),
    };
}

/// ── Phase 2: Position ─────────────────────────────────────────
/// Layout a widget tree at the given position within the given size.
pub fn layout(root: *Widget, pos: Pos, size: Size) void {
    root.rect = .{ .x = pos.x, .y = pos.y, .w = size.width, .h = size.height };
    switch (root.kind) {
        .column => |c| layoutColumn(c, root, pos, size),
        .row => |r| layoutRow(r, root, pos, size),
        else => {},
    }
}

fn layoutColumn(c: anytype, w: *Widget, pos: Pos, size: Size) void {
    _ = w;
    const inner_x = pos.x + c.padding;
    const inner_y = pos.y + c.padding;
    const inner_w = size.width - 2 * c.padding;
    const inner_h = size.height - 2 * c.padding;

    // Sum non-grow heights
    var content_h: f32 = 0;
    var grow_count: u32 = 0;
    for (c.children) |child| {
        if (child.sizing.y == .grow) {
            grow_count += 1;
        } else {
            content_h += child.rect.h;
        }
    }
    const gap_total = c.gap * @max(0, @as(f32, @floatFromInt(c.children.len)) - 1);

    // Distribute remaining space to grow children
    const remain = @max(0, inner_h - content_h - gap_total);
    const grow_h = if (grow_count > 0) remain / @as(f32, @floatFromInt(grow_count)) else 0;

    var y_pos = inner_y;
    for (c.children) |child| {
        const child_h = if (child.sizing.y == .grow) grow_h else child.rect.h;
        const child_w = if (child.sizing.x == .grow) inner_w else @min(child.rect.w, inner_w);
        layout(child, .{ .x = inner_x, .y = y_pos }, .{ .width = child_w, .height = child_h });
        y_pos += child_h + c.gap;
    }
}

fn layoutRow(r: anytype, w: *Widget, pos: Pos, size: Size) void {
    _ = w;
    const inner_x = pos.x + r.padding;
    const inner_y = pos.y + r.padding;
    const inner_w = size.width - 2 * r.padding;
    const inner_h = size.height - 2 * r.padding;

    var content_w: f32 = 0;
    var grow_count: u32 = 0;
    for (r.children) |child| {
        if (child.sizing.x == .grow) {
            grow_count += 1;
        } else {
            content_w += child.rect.w;
        }
    }
    const gap_total = r.gap * @max(0, @as(f32, @floatFromInt(r.children.len)) - 1);

    const remain = @max(0, inner_w - content_w - gap_total);
    const grow_w = if (grow_count > 0) remain / @as(f32, @floatFromInt(grow_count)) else 0;

    var x_pos = inner_x;
    for (r.children) |child| {
        const child_w = if (child.sizing.x == .grow) grow_w else child.rect.w;
        const child_h = if (child.sizing.y == .grow) inner_h else @min(child.rect.h, inner_h);
        layout(child, .{ .x = x_pos, .y = inner_y }, .{ .width = child_w, .height = child_h });
        x_pos += child_w + r.gap;
    }
}
