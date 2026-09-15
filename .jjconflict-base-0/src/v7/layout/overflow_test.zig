const std = @import("std");
const overflow = @import("overflow.zig");
const widget = @import("../widget.zig");

test "content contribution propagates visible overflow across negative origins" {
    const rect: widget.Rect = .{ .x = -20, .y = -5, .w = 10, .h = 10 };
    const child_content: widget.Size = .{ .width = 40, .height = 30 };

    try std.testing.expectEqual(
        widget.Size{ .width = 40, .height = 30 },
        try overflow.contentContribution(
            rect,
            child_content,
            .{ .width = .visible, .height = .visible },
        ),
    );
    try std.testing.expectEqual(
        widget.Size{ .width = 20, .height = 10 },
        try overflow.contentContribution(
            rect,
            child_content,
            .{ .width = .hidden, .height = .hidden },
        ),
    );
}

test "zero-area boxes do not contribute scrollable overflow" {
    try std.testing.expectEqual(
        widget.Size{ .width = 0, .height = 0 },
        try overflow.contentContribution(
            .{ .x = 0, .y = 0, .w = 40, .h = 0 },
            .{ .width = 40, .height = 0 },
            .{ .width = .visible, .height = .visible },
        ),
    );
    try std.testing.expectEqual(
        widget.Size{ .width = 0, .height = 0 },
        try overflow.contentContribution(
            .{ .x = 0, .y = 0, .w = 0, .h = 40 },
            .{ .width = 0, .height = 40 },
            .{ .width = .visible, .height = .visible },
        ),
    );
}

test "absolute flex contribution excludes overflow before RTL logical start" {
    const rect: widget.Rect = .{ .x = -50, .y = 0, .w = 100, .h = 100 };

    try std.testing.expectEqual(
        widget.Size{ .width = 50, .height = 100 },
        try overflow.absoluteFlexContribution(
            rect,
            .{ .width = 100, .height = 100 },
            .{ .width = .hidden, .height = .hidden },
            .rtl,
        ),
    );
    try std.testing.expectEqual(
        widget.Size{ .width = 70, .height = 100 },
        try overflow.absoluteFlexContribution(
            rect,
            .{ .width = 120, .height = 100 },
            .{ .width = .visible, .height = .hidden },
            .rtl,
        ),
    );
}

test "content extent adds padding once" {
    try std.testing.expectEqual(
        widget.Size{ .width = 17, .height = 9 },
        try overflow.contentExtent(
            .{ .width = 10, .height = 5 },
            .{ .top = 1, .right = 2, .bottom = 3, .left = 5 },
        ),
    );
}

test "scroll offset uses the client padding box" {
    const client = try overflow.clientSize(
        .{ .width = 200, .height = 200 },
        .{ .top = 20, .right = 20, .bottom = 20, .left = 20 },
        .{ .top = 0, .right = 15, .bottom = 15, .left = 0 },
    );
    try std.testing.expectEqual(widget.Size{ .width = 145, .height = 145 }, client);
    try std.testing.expectEqual(
        [2]f32{ 0, 0 },
        try overflow.maxOffset(.{ .width = 145, .height = 145 }, client, .both),
    );
    try std.testing.expectEqual(
        [2]f32{ 15, 0 },
        try overflow.maxOffset(.{ .width = 160, .height = 160 }, client, .horizontal),
    );
}
