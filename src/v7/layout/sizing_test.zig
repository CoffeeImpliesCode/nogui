//! Specifies pure sizing behavior before the production module exists.

const std = @import("std");
const style = @import("../style.zig");
const sizing = @import("sizing.zig");

const Dimension = style.Dimension;
const Style = style.Style;

test "resolveDimension resolves a length and a definite percentage" {
    try std.testing.expectEqual(
        @as(?f32, 37.5),
        try sizing.resolveDimension(
            @as(Dimension, .{ .length = 37.5 }),
            .min_content,
        ),
    );
    try std.testing.expectEqual(
        @as(?f32, 80),
        try sizing.resolveDimension(
            @as(Dimension, .{ .percent = 0.4 }),
            .{ .definite = 200 },
        ),
    );
}

test "resolveDimension rejects percentages in intrinsic available space" {
    const dimension: Dimension = .{ .percent = 0.25 };

    try std.testing.expectError(
        error.IndefinitePercentage,
        sizing.resolveDimension(dimension, .min_content),
    );
    try std.testing.expectError(
        error.IndefinitePercentage,
        sizing.resolveDimension(dimension, .max_content),
    );
}

test "resolveBoxModel distinguishes content-box and border-box sizes" {
    const content_box = try sizing.resolveBoxModel(
        Style{
            .size = .{
                .width = .{ .length = 200 },
                .height = .{ .length = 150 },
            },
            .padding_inset = .{
                .top = .{ .length = 3 },
                .right = .{ .length = 5 },
                .bottom = .{ .length = 7 },
                .left = .{ .length = 11 },
            },
            .border_inset = .{
                .top = .{ .length = 13 },
                .right = .{ .length = 17 },
                .bottom = .{ .length = 19 },
                .left = .{ .length = 23 },
            },
            .box_sizing = .content_box,
        },
        .{
            .width = .{ .definite = 1_000 },
            .height = .{ .definite = 1_000 },
        },
    );
    try std.testing.expectEqual(
        @as(?f32, 200),
        @as(?f32, content_box.content_box.width),
    );
    try std.testing.expectEqual(
        @as(?f32, 150),
        @as(?f32, content_box.content_box.height),
    );
    try std.testing.expectEqual(
        @as(?f32, 256),
        @as(?f32, content_box.border_box.width),
    );
    try std.testing.expectEqual(
        @as(?f32, 192),
        @as(?f32, content_box.border_box.height),
    );

    const border_box = try sizing.resolveBoxModel(
        Style{
            .size = .{
                .width = .{ .length = 200 },
                .height = .{ .length = 150 },
            },
            .padding_inset = .{
                .top = .{ .length = 3 },
                .right = .{ .length = 5 },
                .bottom = .{ .length = 7 },
                .left = .{ .length = 11 },
            },
            .border_inset = .{
                .top = .{ .length = 13 },
                .right = .{ .length = 17 },
                .bottom = .{ .length = 19 },
                .left = .{ .length = 23 },
            },
            .box_sizing = .border_box,
        },
        .{
            .width = .{ .definite = 1_000 },
            .height = .{ .definite = 1_000 },
        },
    );
    try std.testing.expectEqual(
        @as(?f32, 144),
        @as(?f32, border_box.content_box.width),
    );
    try std.testing.expectEqual(
        @as(?f32, 108),
        @as(?f32, border_box.content_box.height),
    );
    try std.testing.expectEqual(
        @as(?f32, 200),
        @as(?f32, border_box.border_box.width),
    );
    try std.testing.expectEqual(
        @as(?f32, 150),
        @as(?f32, border_box.border_box.height),
    );
}

test "resolveBoxModel keeps auto preferred axes indefinite" {
    const result = try sizing.resolveBoxModel(
        Style{},
        .{
            .width = .{ .definite = 800 },
            .height = .{ .definite = 600 },
        },
    );

    try std.testing.expectEqual(
        @as(?f32, null),
        @as(?f32, result.content_box.width),
    );
    try std.testing.expectEqual(
        @as(?f32, null),
        @as(?f32, result.content_box.height),
    );
    try std.testing.expectEqual(
        @as(?f32, null),
        @as(?f32, result.border_box.width),
    );
    try std.testing.expectEqual(
        @as(?f32, null),
        @as(?f32, result.border_box.height),
    );
}

test "clampSize adjusts content-box ratio minimum before clamping" {
    const clamped_border_box = try sizing.clampSize(
        Style{
            .min_size = .{
                .width = .{ .length = 100 },
                .height = .auto,
            },
            .aspect_ratio = 2,
            .padding_inset = .{
                .top = .{ .length = 1 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 2 },
                .left = .{ .length = 0 },
            },
            .border_inset = .{
                .top = .{ .length = 3 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 4 },
                .left = .{ .length = 0 },
            },
            .box_sizing = .content_box,
        },
        .{ .width = 40, .height = 20 },
        .{
            .width = .{ .definite = 800 },
            .height = .{ .definite = 600 },
        },
    );

    try std.testing.expectEqual(@as(f32, 100), clamped_border_box.width);
    try std.testing.expectEqual(@as(f32, 60), clamped_border_box.height);
}

test "clampSize gives a conflicting minimum precedence over maximum" {
    const result = try sizing.clampSize(
        Style{
            .min_size = .{
                .width = .{ .length = 90 },
                .height = .{ .length = 80 },
            },
            .max_size = .{
                .width = .{ .length = 40 },
                .height = .{ .length = 120 },
            },
        },
        .{ .width = 20, .height = 140 },
        .{
            .width = .{ .definite = 500 },
            .height = .{ .definite = 500 },
        },
    );

    try std.testing.expectEqual(@as(f32, 90), result.width);
    try std.testing.expectEqual(@as(f32, 120), result.height);
}

test "applyAspectRatio derives a missing height from a known width" {
    const result = try sizing.applyAspectRatio(
        Style{ .aspect_ratio = 2 },
        .{ .width = 120, .height = null },
    );

    try std.testing.expectEqual(@as(?f32, 120), result.width);
    try std.testing.expectEqual(@as(?f32, 60), result.height);
}

test "resolveDimension rejects non-finite input" {
    try std.testing.expectError(
        error.InvalidStyle,
        sizing.resolveDimension(
            @as(Dimension, .{ .length = std.math.nan(f32) }),
            .{ .definite = 100 },
        ),
    );
    try std.testing.expectError(
        error.InvalidStyle,
        sizing.resolveDimension(
            @as(Dimension, .{ .percent = std.math.inf(f32) }),
            .{ .definite = 100 },
        ),
    );
    try std.testing.expectError(
        error.InvalidStyle,
        sizing.resolveDimension(
            @as(Dimension, .{ .percent = 0.5 }),
            .{ .definite = -std.math.inf(f32) },
        ),
    );
}
