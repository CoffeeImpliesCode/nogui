const std = @import("std");
const fixture = @import("fixture.zig");
const fixture_options = @import("fixture_options");

test "runs the complete pinned fixture corpus" {
    const filter: ?[]const u8 = if (fixture_options.filter.len == 0) null else fixture_options.filter;
    const result = try fixture.runAll(std.testing.allocator, filter);
    if (filter != null) {
        try std.testing.expectEqual(@as(usize, 0), result.failed);
        try std.testing.expectEqual(@as(usize, 0), result.unsupported);
        try std.testing.expect(result.passed > 0);
        return;
    }

    try std.testing.expectEqual(@as(usize, 5524), result.passed);
    try std.testing.expectEqual(@as(usize, 0), result.failed);
    try std.testing.expectEqual(@as(usize, 0), result.unsupported);
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("", &expected, .{});
    try std.testing.expectEqual(expected, result.unsupported_sha256);
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
    try std.testing.expectEqual(
        @as(usize, 0),
        empty.unsupported,
    );
    try std.testing.expectError(
        error.FixtureNotFound,
        fixture.runRange(std.testing.allocator, 5524, 1),
    );
}

test "runs all pinned vertical-lr fixture variants" {
    const source_ids = [_][]const u8{
        "flex/intrinsic_sizing_main_size_column.html",
        "flex/intrinsic_sizing_main_size_column_nested.html",
        "flex/intrinsic_sizing_main_size_column_wrap.html",
        "grid/grid_aspect_ratio_fill_child_max_height.html",
        "grid/grid_relayout_vertical_text.html",
    };

    for (source_ids) |source_id| {
        const result = try fixture.runAll(std.testing.allocator, source_id);
        try std.testing.expectEqual(@as(usize, 4), result.passed);
        try std.testing.expectEqual(@as(usize, 0), result.failed);
        try std.testing.expectEqual(@as(usize, 0), result.unsupported);
    }
}
