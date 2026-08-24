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
