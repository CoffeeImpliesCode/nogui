const std = @import("std");
const fixture = @import("fixture.zig");

test "runs the pinned leaf fixture" {
    const result = try fixture.runAll(
        std.testing.allocator,
        "leaf/leaf_with_content_and_border.html",
    );

    try std.testing.expectEqual(@as(usize, 1), result.passed);
    try std.testing.expectEqual(@as(usize, 0), result.failed);
    try std.testing.expectEqual(@as(usize, 0), result.unsupported);
}

test "runs one pinned fixture variant" {
    const result = try fixture.runVariant(
        std.testing.allocator,
        "leaf/leaf_with_content_and_border.html",
        "border_box_ltr",
    );

    try std.testing.expectEqual(@as(usize, 1), result.passed);
    try std.testing.expectEqual(@as(usize, 0), result.failed);
    try std.testing.expectEqual(@as(usize, 0), result.unsupported);
}

test "runs a pinned fixture range" {
    const result = try fixture.runRange(std.testing.allocator, 0, 1);

    try std.testing.expectEqual(@as(usize, 1), result.passed);
    try std.testing.expectEqual(@as(usize, 0), result.failed);
    try std.testing.expectEqual(@as(usize, 0), result.unsupported);
    const empty = try fixture.runRange(std.testing.allocator, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), empty.passed);
    try std.testing.expectEqual(@as(usize, 0), empty.failed);
    try std.testing.expectEqual(@as(usize, 0), empty.unsupported);
    try std.testing.expectError(
        error.FixtureNotFound,
        fixture.runRange(std.testing.allocator, 1, 1),
    );
}
