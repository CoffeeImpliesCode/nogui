const std = @import("std");
const sizing = @import("sizing.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");

/// Compute the content extent a child contributes to its parent's content box.
pub fn contentContribution(
    rect: widget.Rect,
    child_content: widget.Size,
    child_overflow: style.OverflowAxes,
) sizing.Error!widget.Size {
    const size = try contributionSize(rect, child_content, child_overflow);
    if (size.width == 0.0 or size.height == 0.0) {
        return .{ .width = 0, .height = 0 };
    }
    return .{
        .width = try axisContribution(rect.x, size.width),
        .height = try axisContribution(rect.y, size.height),
    };
}

/// Compute an absolutely positioned flex child's contribution to the logical
/// end of its parent's content box. Overflow before the RTL logical-start edge
/// does not enlarge the scrollable extent.
pub fn absoluteFlexContribution(
    rect: widget.Rect,
    child_content: widget.Size,
    child_overflow: style.OverflowAxes,
    direction: style.Direction,
) sizing.Error!widget.Size {
    const size = try contributionSize(rect, child_content, child_overflow);
    if (size.width == 0.0 or size.height == 0.0) {
        return .{ .width = 0, .height = 0 };
    }
    const horizontal = if (direction == .rtl)
        try rtlAbsoluteAxisContribution(rect.x, rect.w, size.width)
    else
        try trailingAxisContribution(rect.x, size.width);
    return .{
        .width = horizontal,
        .height = try trailingAxisContribution(rect.y, size.height),
    };
}

fn contributionSize(
    rect: widget.Rect,
    child_content: widget.Size,
    child_overflow: style.OverflowAxes,
) sizing.Error!widget.Size {
    try validateLocation(rect.x);
    try validateLocation(rect.y);
    try validateSize(rect.w, rect.h);
    try validateSize(child_content.width, child_content.height);
    return .{
        .width = if (child_overflow.width == .visible)
            @max(rect.w, child_content.width)
        else
            rect.w,
        .height = if (child_overflow.height == .visible)
            @max(rect.h, child_content.height)
        else
            rect.h,
    };
}
/// Add resolved padding to a content extent without including border or gutters.
pub fn contentExtent(
    content: widget.Size,
    padding: style.Sides,
) sizing.Error!widget.Size {
    try validateSize(content.width, content.height);
    try validateSides(padding);
    const width = try finite(content.width + padding.left + padding.right);
    const height = try finite(content.height + padding.top + padding.bottom);
    return .{
        .width = try nonNegative(width),
        .height = try nonNegative(height),
    };
}

/// Compute the scroll client box from a border box and physical gutters.
pub fn clientSize(
    border_box: widget.Size,
    border: style.Sides,
    gutter: style.Sides,
) sizing.Error!widget.Size {
    try validateSize(border_box.width, border_box.height);
    try validateSides(border);
    try validateSides(gutter);
    const border_width = try horizontalSum(border);
    const border_height = try verticalSum(border);
    const gutter_width = try horizontalSum(gutter);
    const gutter_height = try verticalSum(gutter);
    return .{
        .width = try nonNegative(@max(
            0,
            try finite(border_box.width - border_width - gutter_width),
        )),
        .height = try nonNegative(@max(
            0,
            try finite(border_box.height - border_height - gutter_height),
        )),
    };
}

fn validateSides(sides: style.Sides) sizing.Error!void {
    _ = try nonNegative(sides.top);
    _ = try nonNegative(sides.right);
    _ = try nonNegative(sides.bottom);
    _ = try nonNegative(sides.left);
}

fn horizontalSum(sides: style.Sides) sizing.Error!f32 {
    return finite(sides.left + sides.right);
}

fn verticalSum(sides: style.Sides) sizing.Error!f32 {
    return finite(sides.top + sides.bottom);
}

/// Compute non-negative scroll offsets for the requested axes.
pub fn maxOffset(
    content: widget.Size,
    client: widget.Size,
    axis: widget.ScrollAxis,
) sizing.Error![2]f32 {
    try validateSize(content.width, content.height);
    try validateSize(client.width, client.height);

    const horizontal = try offset(content.width, client.width);
    const vertical = try offset(content.height, client.height);

    return switch (axis) {
        .horizontal => .{ horizontal, 0 },
        .vertical => .{ 0, vertical },
        .both => .{ horizontal, vertical },
    };
}

fn axisContribution(location: f32, size: f32) sizing.Error!f32 {
    const trailing = try finite(location + size);
    const max_extent = @max(trailing, 0.0);
    const min_extent = @min(location, 0.0);
    return nonNegative(max_extent - min_extent);
}

fn trailingAxisContribution(location: f32, size: f32) sizing.Error!f32 {
    return nonNegative(@max(try finite(location + size), 0.0));
}

fn rtlAbsoluteAxisContribution(
    location: f32,
    border_size: f32,
    contribution_size: f32,
) sizing.Error!f32 {
    const border_end = @max(try finite(location + border_size), 0.0);
    const overflow_extra = @max(try finite(contribution_size - border_size), 0.0);
    return nonNegative(try finite(border_end + overflow_extra));
}

fn offset(content: f32, client: f32) sizing.Error!f32 {
    const difference = try finite(content - client);
    return nonNegative(@max(difference, 0.0));
}

fn validateLocation(value: f32) sizing.Error!void {
    _ = try finite(value);
}

fn validateSize(width: f32, height: f32) sizing.Error!void {
    _ = try nonNegative(width);
    _ = try nonNegative(height);
}

fn finite(value: f32) sizing.Error!f32 {
    if (!std.math.isFinite(value)) return error.InvalidStyle;
    return value;
}

fn nonNegative(value: f32) sizing.Error!f32 {
    const checked = try finite(value);
    if (checked < 0.0) return error.InvalidStyle;
    return checked;
}
