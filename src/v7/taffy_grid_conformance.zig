//! Geometry conformance cases selected from Taffy's upstream grid fixtures.
//!
//! `main/test_fixtures/grid/grid_out_of_order_items.html` and
//! `main/test_fixtures/grid/grid_placement_definite_primary.html` are not
//! included because their partial explicit placement is not supported.
const std = @import("std");

const flex = @import("flex.zig");
const Id = @import("id.zig").Id;
const style = @import("style.zig");
const widget = @import("widget.zig");

const Rect = widget.Rect;
const Style = style.Style;
const PaintStyle = widget.PaintStyle;
const WidgetNode = widget.WidgetNode;
const WidgetTree = widget.WidgetTree;
const testing = std.testing;

const epsilon: f32 = 0.01;

const Fixture = struct {
    tree: WidgetTree,
    root: Id,
    children: std.ArrayList(Id),

    fn init(grid_style: Style, child_styles: []const Style) !Fixture {
        const root: Id = @enumFromInt(@as(u32, @intCast(child_styles.len + 1)));
        var fixture: Fixture = .{
            .tree = WidgetTree.init(testing.allocator),
            .root = root,
            .children = .empty,
        };
        errdefer {
            fixture.children.deinit(testing.allocator);
            fixture.tree.deinit();
        }

        for (child_styles, 0..) |child_style, index| {
            const child: Id = @enumFromInt(@as(u32, @intCast(index + 1)));
            try fixture.children.append(testing.allocator, child);
            try fixture.tree.nodes.append(fixture.tree.allocator, WidgetNode{
                .id = child,
                .kind = .{ .spacer = .{} },
                .parent = root,
                .style = child_style,
                .paint = PaintStyle{},
            });
        }
        try fixture.tree.nodes.append(fixture.tree.allocator, WidgetNode{
            .id = root,
            .kind = .{ .column = .{} },
            .parent = .root,
            .style = grid_style,
            .paint = PaintStyle{},
        });

        for (fixture.children.items) |child| {
            try fixture.tree.appendChild(fixture.root, child);
        }
        return fixture;
    }

    fn deinit(fixture: *Fixture) void {
        fixture.children.deinit(testing.allocator);
        fixture.tree.deinit();
        // SAFETY: fixture owns deinitialized storage; poison state to prevent reuse.
        fixture.* = undefined;
    }

    fn run(fixture: *Fixture, available: widget.Size) void {
        flex.layout(&fixture.tree, available);
    }

    fn rootRect(fixture: *const Fixture) Rect {
        return fixture.tree.nodeConst(fixture.root).?.rect;
    }

    fn childRect(fixture: *const Fixture, index: usize) Rect {
        std.debug.assert(index < fixture.children.items.len);
        return fixture.tree.nodeConst(fixture.children.items[index]).?.rect;
    }

    fn childAbsoluteRect(fixture: *const Fixture, index: usize) Rect {
        std.debug.assert(index < fixture.children.items.len);
        return widget.absoluteRect(&fixture.tree, fixture.children.items[index]);
    }
};

fn expectRect(expected: Rect, actual: Rect) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, epsilon);
    try testing.expectApproxEqAbs(expected.y, actual.y, epsilon);
    try testing.expectApproxEqAbs(expected.w, actual.w, epsilon);
    try testing.expectApproxEqAbs(expected.h, actual.h, epsilon);
}

fn expectFixture(
    fixture: *const Fixture,
    expected_root: Rect,
    expected_children: []const Rect,
) !void {
    try testing.expectEqual(expected_children.len, fixture.children.items.len);
    try expectRect(expected_root, fixture.rootRect());
    for (expected_children, 0..) |expected, index| {
        try expectRect(expected, fixture.childRect(index));
    }
}

fn fixedGridStyle(width: f32, height: f32) Style {
    return .{
        .display = .grid,
        .size = .{
            .width = .{ .length = width },
            .height = .{ .length = height },
        },
    };
}

test "Fixture.init records eleven child IDs" {
    const child_styles = [_]Style{.{}} ** 11;

    var fixture = try Fixture.init(fixedGridStyle(1, 1), &child_styles);
    defer fixture.deinit();

    try testing.expectEqual(child_styles.len, fixture.children.items.len);
    for (fixture.children.items, 0..) |child, index| {
        const expected_child: Id = @enumFromInt(@as(u32, @intCast(index + 1)));
        try testing.expectEqual(expected_child, child);
        try testing.expect(fixture.tree.nodeConst(child) != null);
    }
}

test "main/test_fixtures/grid/grid_basic.html" {
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };
    const rows = columns;
    var grid_style = fixedGridStyle(120, 120);
    grid_style.grid_template_columns = &columns;
    grid_style.grid_template_rows = &rows;
    const child_styles = [_]Style{.{}} ** 9;

    var fixture = try Fixture.init(grid_style, &child_styles);
    defer fixture.deinit();
    fixture.run(.{ .width = 120, .height = 120 });

    try expectFixture(&fixture, .{ .w = 120, .h = 120 }, &.{
        .{ .x = 0, .y = 0, .w = 40, .h = 40 },
        .{ .x = 40, .y = 0, .w = 40, .h = 40 },
        .{ .x = 80, .y = 0, .w = 40, .h = 40 },
        .{ .x = 0, .y = 40, .w = 40, .h = 40 },
        .{ .x = 40, .y = 40, .w = 40, .h = 40 },
        .{ .x = 80, .y = 40, .w = 40, .h = 40 },
        .{ .x = 0, .y = 80, .w = 40, .h = 40 },
        .{ .x = 40, .y = 80, .w = 40, .h = 40 },
        .{ .x = 80, .y = 80, .w = 40, .h = 40 },
    });
}

test "main/test_fixtures/grid/grid_gap.html" {
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };
    const rows = columns;
    var grid_style = fixedGridStyle(200, 200);
    grid_style.grid_template_columns = &columns;
    grid_style.grid_template_rows = &rows;
    grid_style.grid_column_gap = 40;
    grid_style.grid_row_gap = 40;
    const child_styles = [_]Style{.{}} ** 9;

    var fixture = try Fixture.init(grid_style, &child_styles);
    defer fixture.deinit();
    fixture.run(.{ .width = 200, .height = 200 });

    try expectFixture(&fixture, .{ .w = 200, .h = 200 }, &.{
        .{ .x = 0, .y = 0, .w = 40, .h = 40 },
        .{ .x = 80, .y = 0, .w = 40, .h = 40 },
        .{ .x = 160, .y = 0, .w = 40, .h = 40 },
        .{ .x = 0, .y = 80, .w = 40, .h = 40 },
        .{ .x = 80, .y = 80, .w = 40, .h = 40 },
        .{ .x = 160, .y = 80, .w = 40, .h = 40 },
        .{ .x = 0, .y = 160, .w = 40, .h = 40 },
        .{ .x = 80, .y = 160, .w = 40, .h = 40 },
        .{ .x = 160, .y = 160, .w = 40, .h = 40 },
    });
}

test "main/test_fixtures/grid/grid_percent_tracks_definite_overflow.html" {
    const columns = [_]style.GridTrack{
        .{ .percent = 0.4 },
        .{ .percent = 0.4 },
        .{ .percent = 0.4 },
    };
    const rows = [_]style.GridTrack{
        .{ .percent = 0.5 },
        .{ .percent = 0.8 },
    };
    var grid_style = fixedGridStyle(120, 60);
    grid_style.grid_template_columns = &columns;
    grid_style.grid_template_rows = &rows;
    const child_styles = [_]Style{.{}} ** 6;

    var fixture = try Fixture.init(grid_style, &child_styles);
    defer fixture.deinit();
    fixture.run(.{ .width = 120, .height = 60 });

    try expectFixture(&fixture, .{ .w = 120, .h = 60 }, &.{
        .{ .x = 0, .y = 0, .w = 48, .h = 30 },
        .{ .x = 48, .y = 0, .w = 48, .h = 30 },
        .{ .x = 96, .y = 0, .w = 48, .h = 30 },
        .{ .x = 0, .y = 30, .w = 48, .h = 48 },
        .{ .x = 48, .y = 30, .w = 48, .h = 48 },
        .{ .x = 96, .y = 30, .w = 48, .h = 48 },
    });
}

test "main/test_fixtures/grid/grid_auto_single_item.html" {
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .auto,
        .{ .fixed = 40 },
    };
    const rows = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };
    const grid_style: Style = .{
        .display = .grid,
        .grid_template_columns = &columns,
        .grid_template_rows = &rows,
    };
    const child_styles = [_]Style{
        .{},
        .{ .size = .{ .width = .{ .length = 100 }, .height = .auto } },
        .{},
        .{},
        .{},
        .{},
        .{},
        .{},
        .{},
    };

    var fixture = try Fixture.init(grid_style, &child_styles);
    defer fixture.deinit();
    fixture.run(.{ .width = 180, .height = 120 });

    try expectFixture(&fixture, .{ .w = 180, .h = 120 }, &.{
        .{ .x = 0, .y = 0, .w = 40, .h = 40 },
        .{ .x = 40, .y = 0, .w = 100, .h = 40 },
        .{ .x = 140, .y = 0, .w = 40, .h = 40 },
        .{ .x = 0, .y = 40, .w = 40, .h = 40 },
        .{ .x = 40, .y = 40, .w = 100, .h = 40 },
        .{ .x = 140, .y = 40, .w = 40, .h = 40 },
        .{ .x = 0, .y = 80, .w = 40, .h = 40 },
        .{ .x = 40, .y = 80, .w = 100, .h = 40 },
        .{ .x = 140, .y = 80, .w = 40, .h = 40 },
    });
}

test "main/test_fixtures/grid/grid_minmax_column_fixed_width_below_range.html" {
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .minmax = .{ .min = .{ .fixed = 20 }, .max = .{ .fixed = 40 } } },
        .{ .fixed = 40 },
    };
    const rows = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };
    var grid_style = fixedGridStyle(90, 120);
    grid_style.grid_template_columns = &columns;
    grid_style.grid_template_rows = &rows;
    const child_styles = [_]Style{.{}} ** 9;

    var fixture = try Fixture.init(grid_style, &child_styles);
    defer fixture.deinit();
    fixture.run(.{ .width = 90, .height = 120 });

    try expectFixture(&fixture, .{ .w = 90, .h = 120 }, &.{
        .{ .x = 0, .y = 0, .w = 40, .h = 40 },
        .{ .x = 40, .y = 0, .w = 20, .h = 40 },
        .{ .x = 60, .y = 0, .w = 40, .h = 40 },
        .{ .x = 0, .y = 40, .w = 40, .h = 40 },
        .{ .x = 40, .y = 40, .w = 20, .h = 40 },
        .{ .x = 60, .y = 40, .w = 40, .h = 40 },
        .{ .x = 0, .y = 80, .w = 40, .h = 40 },
        .{ .x = 40, .y = 80, .w = 20, .h = 40 },
        .{ .x = 60, .y = 80, .w = 40, .h = 40 },
    });
}

test "main/test_fixtures/grid/grid_minmax_column_fixed_width_within_range.html" {
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .minmax = .{ .min = .{ .fixed = 20 }, .max = .{ .fixed = 40 } } },
        .{ .fixed = 40 },
    };
    const rows = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };
    var grid_style = fixedGridStyle(110, 120);
    grid_style.grid_template_columns = &columns;
    grid_style.grid_template_rows = &rows;
    const child_styles = [_]Style{.{}} ** 9;

    var fixture = try Fixture.init(grid_style, &child_styles);
    defer fixture.deinit();
    fixture.run(.{ .width = 110, .height = 120 });

    try expectFixture(&fixture, .{ .w = 110, .h = 120 }, &.{
        .{ .x = 0, .y = 0, .w = 40, .h = 40 },
        .{ .x = 40, .y = 0, .w = 20, .h = 40 },
        .{ .x = 60, .y = 0, .w = 40, .h = 40 },
        .{ .x = 0, .y = 40, .w = 40, .h = 40 },
        .{ .x = 40, .y = 40, .w = 20, .h = 40 },
        .{ .x = 60, .y = 40, .w = 40, .h = 40 },
        .{ .x = 0, .y = 80, .w = 40, .h = 40 },
        .{ .x = 40, .y = 80, .w = 20, .h = 40 },
        .{ .x = 60, .y = 80, .w = 40, .h = 40 },
    });
}

test "main/test_fixtures/grid/grid_minmax_column_with_fr_fixed.html" {
    const columns = [_]style.GridTrack{
        .{ .minmax = .{ .min = .{ .fixed = 20 }, .max = .{ .fixed = 40 } } },
        .{ .fr = 1 },
    };
    const rows = [_]style.GridTrack{.{ .fixed = 40 }};
    var grid_style = fixedGridStyle(60, 40);
    grid_style.grid_template_columns = &columns;
    grid_style.grid_template_rows = &rows;
    const child_styles = [_]Style{ .{}, .{} };

    var fixture = try Fixture.init(grid_style, &child_styles);
    defer fixture.deinit();
    fixture.run(.{ .width = 60, .height = 40 });

    try expectFixture(&fixture, .{ .w = 60, .h = 40 }, &.{
        .{ .x = 0, .y = 0, .w = 20, .h = 40 },
        .{ .x = 20, .y = 0, .w = 40, .h = 40 },
    });
}

test "main/test_fixtures/grid/grid_fr_fixed_size_single_item.html" {
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fr = 1 },
        .{ .fr = 1 },
    };
    const rows = columns;
    var grid_style = fixedGridStyle(200, 200);
    grid_style.grid_template_columns = &columns;
    grid_style.grid_template_rows = &rows;
    const child_styles = [_]Style{
        .{},
        .{},
        .{},
        .{},
        .{ .size = .{ .width = .{ .length = 100 }, .height = .auto } },
        .{},
        .{},
        .{},
        .{},
    };

    var fixture = try Fixture.init(grid_style, &child_styles);
    defer fixture.deinit();
    fixture.run(.{ .width = 200, .height = 200 });

    try expectFixture(&fixture, .{ .w = 200, .h = 200 }, &.{
        .{ .x = 0, .y = 0, .w = 40, .h = 40 },
        .{ .x = 40, .y = 0, .w = 80, .h = 40 },
        .{ .x = 120, .y = 0, .w = 80, .h = 40 },
        .{ .x = 0, .y = 40, .w = 40, .h = 80 },
        .{ .x = 40, .y = 40, .w = 100, .h = 80 },
        .{ .x = 120, .y = 40, .w = 80, .h = 80 },
        .{ .x = 0, .y = 120, .w = 40, .h = 80 },
        .{ .x = 40, .y = 120, .w = 80, .h = 80 },
        .{ .x = 120, .y = 120, .w = 80, .h = 80 },
    });
}

test "main/test_fixtures/grid/grid_fr_span_2_proportion.html" {
    const columns = [_]style.GridTrack{ .{ .fr = 1 }, .{ .fr = 2 } };
    const rows = [_]style.GridTrack{ .{ .fixed = 40 }, .{ .fixed = 40 } };
    const grid_style: Style = .{
        .display = .grid,
        .grid_template_columns = &columns,
        .grid_template_rows = &rows,
    };
    const child_styles = [_]Style{
        .{
            .size = .{ .width = .{ .length = 60 }, .height = .auto },
            .grid_column = .{ .start = .{ .span = 2 } },
        },
        .{},
        .{},
    };

    var fixture = try Fixture.init(grid_style, &child_styles);
    defer fixture.deinit();
    fixture.run(.{ .width = 60, .height = 80 });

    try expectFixture(&fixture, .{ .w = 60, .h = 80 }, &.{
        .{ .x = 0, .y = 0, .w = 60, .h = 40 },
        .{ .x = 0, .y = 40, .w = 30, .h = 40 },
        .{ .x = 30, .y = 40, .w = 30, .h = 40 },
    });
}

test "main/test_fixtures/grid/grid_basic_implicit_tracks.html" {
    const columns = [_]style.GridTrack{.{ .fixed = 40 }};
    const rows = [_]style.GridTrack{.{ .fixed = 40 }};
    const grid_style: Style = .{
        .display = .grid,
        .grid_template_columns = &columns,
        .grid_template_rows = &rows,
    };
    const child_styles = [_]Style{
        .{},
        .{
            .size = .{
                .width = .{ .length = 35 },
                .height = .{ .length = 35 },
            },
        },
    };

    var fixture = try Fixture.init(grid_style, &child_styles);
    defer fixture.deinit();
    fixture.run(.{ .width = 40, .height = 75 });

    try expectFixture(&fixture, .{ .w = 40, .h = 75 }, &.{
        .{ .x = 0, .y = 0, .w = 40, .h = 40 },
        .{ .x = 0, .y = 40, .w = 35, .h = 35 },
    });
}

test "main/test_fixtures/grid/grid_align_content_center.html" {
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };
    const rows = columns;
    var grid_style = fixedGridStyle(200, 200);
    grid_style.grid_template_columns = &columns;
    grid_style.grid_template_rows = &rows;
    grid_style.grid_align_content = .center;
    const child_styles = [_]Style{.{}} ** 9;

    var fixture = try Fixture.init(grid_style, &child_styles);
    defer fixture.deinit();
    fixture.run(.{ .width = 200, .height = 200 });

    try expectFixture(&fixture, .{ .w = 200, .h = 200 }, &.{
        .{ .x = 0, .y = 40, .w = 40, .h = 40 },
        .{ .x = 40, .y = 40, .w = 40, .h = 40 },
        .{ .x = 80, .y = 40, .w = 40, .h = 40 },
        .{ .x = 0, .y = 80, .w = 40, .h = 40 },
        .{ .x = 40, .y = 80, .w = 40, .h = 40 },
        .{ .x = 80, .y = 80, .w = 40, .h = 40 },
        .{ .x = 0, .y = 120, .w = 40, .h = 40 },
        .{ .x = 40, .y = 120, .w = 40, .h = 40 },
        .{ .x = 80, .y = 120, .w = 40, .h = 40 },
    });
}

test "main/test_fixtures/grid/grid_align_content_end.html" {
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };
    const rows = columns;
    var grid_style = fixedGridStyle(200, 200);
    grid_style.grid_template_columns = &columns;
    grid_style.grid_template_rows = &rows;
    grid_style.grid_align_content = .end;
    const child_styles = [_]Style{.{}} ** 9;

    var fixture = try Fixture.init(grid_style, &child_styles);
    defer fixture.deinit();
    fixture.run(.{ .width = 200, .height = 200 });

    try expectFixture(&fixture, .{ .w = 200, .h = 200 }, &.{
        .{ .x = 0, .y = 80, .w = 40, .h = 40 },
        .{ .x = 40, .y = 80, .w = 40, .h = 40 },
        .{ .x = 80, .y = 80, .w = 40, .h = 40 },
        .{ .x = 0, .y = 120, .w = 40, .h = 40 },
        .{ .x = 40, .y = 120, .w = 40, .h = 40 },
        .{ .x = 80, .y = 120, .w = 40, .h = 40 },
        .{ .x = 0, .y = 160, .w = 40, .h = 40 },
        .{ .x = 40, .y = 160, .w = 40, .h = 40 },
        .{ .x = 80, .y = 160, .w = 40, .h = 40 },
    });
}

test "main/test_fixtures/grid/grid_align_content_space_between.html" {
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };
    const rows = columns;
    var grid_style = fixedGridStyle(200, 200);
    grid_style.grid_template_columns = &columns;
    grid_style.grid_template_rows = &rows;
    grid_style.grid_align_content = .space_between;
    const child_styles = [_]Style{.{}} ** 9;

    var fixture = try Fixture.init(grid_style, &child_styles);
    defer fixture.deinit();
    fixture.run(.{ .width = 200, .height = 200 });

    try expectFixture(&fixture, .{ .w = 200, .h = 200 }, &.{
        .{ .x = 0, .y = 0, .w = 40, .h = 40 },
        .{ .x = 40, .y = 0, .w = 40, .h = 40 },
        .{ .x = 80, .y = 0, .w = 40, .h = 40 },
        .{ .x = 0, .y = 80, .w = 40, .h = 40 },
        .{ .x = 40, .y = 80, .w = 40, .h = 40 },
        .{ .x = 80, .y = 80, .w = 40, .h = 40 },
        .{ .x = 0, .y = 160, .w = 40, .h = 40 },
        .{ .x = 40, .y = 160, .w = 40, .h = 40 },
        .{ .x = 80, .y = 160, .w = 40, .h = 40 },
    });
}

test "main/test_fixtures/grid/grid_align_items_sized_start.html" {
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };
    const rows = columns;
    var grid_style = fixedGridStyle(120, 120);
    grid_style.grid_template_columns = &columns;
    grid_style.grid_template_rows = &rows;
    grid_style.grid_align_items = .start;
    const child_styles = [_]Style{
        .{
            .size = .{
                .width = .{ .length = 20 },
                .height = .{ .length = 20 },
            },
            .grid_column = .{
                .start = .{ .line = 1 },
                .end = .{ .line = 2 },
            },
            .grid_row = .{
                .start = .{ .line = 1 },
                .end = .{ .line = 2 },
            },
        },
        .{
            .size = .{
                .width = .{ .length = 60 },
                .height = .{ .length = 60 },
            },
            .grid_column = .{
                .start = .{ .line = 3 },
                .end = .{ .line = 4 },
            },
            .grid_row = .{
                .start = .{ .line = 3 },
                .end = .{ .line = 4 },
            },
        },
    };

    var fixture = try Fixture.init(grid_style, &child_styles);
    defer fixture.deinit();
    fixture.run(.{ .width = 120, .height = 120 });

    try expectFixture(&fixture, .{ .w = 120, .h = 120 }, &.{
        .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .{ .x = 80, .y = 80, .w = 60, .h = 60 },
    });
}

test "main/test_fixtures/grid/grid_justify_items_sized_start.html" {
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };
    const rows = columns;
    var grid_style = fixedGridStyle(120, 120);
    grid_style.grid_template_columns = &columns;
    grid_style.grid_template_rows = &rows;
    grid_style.grid_justify_items = .start;
    const child_styles = [_]Style{
        .{
            .size = .{
                .width = .{ .length = 20 },
                .height = .{ .length = 20 },
            },
            .grid_column = .{
                .start = .{ .line = 1 },
                .end = .{ .line = 2 },
            },
            .grid_row = .{
                .start = .{ .line = 1 },
                .end = .{ .line = 2 },
            },
        },
        .{
            .size = .{
                .width = .{ .length = 60 },
                .height = .{ .length = 60 },
            },
            .grid_column = .{
                .start = .{ .line = 3 },
                .end = .{ .line = 4 },
            },
            .grid_row = .{
                .start = .{ .line = 3 },
                .end = .{ .line = 4 },
            },
        },
    };

    var fixture = try Fixture.init(grid_style, &child_styles);
    defer fixture.deinit();
    fixture.run(.{ .width = 120, .height = 120 });

    try expectFixture(&fixture, .{ .w = 120, .h = 120 }, &.{
        .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .{ .x = 80, .y = 80, .w = 60, .h = 60 },
    });
}

test "main/test_fixtures/grid/grid_basic_with_padding.html" {
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };
    const rows = columns;
    const grid_style: Style = .{
        .display = .grid,
        .grid_template_columns = &columns,
        .grid_template_rows = &rows,
        .padding = .{ .top = 10, .right = 20, .bottom = 30, .left = 40 },
    };
    const child_styles = [_]Style{.{}} ** 9;

    var fixture = try Fixture.init(grid_style, &child_styles);
    defer fixture.deinit();
    fixture.run(.{ .width = 180, .height = 160 });

    try expectFixture(&fixture, .{ .w = 180, .h = 160 }, &.{
        .{ .x = 0, .y = 0, .w = 40, .h = 40 },
        .{ .x = 40, .y = 0, .w = 40, .h = 40 },
        .{ .x = 80, .y = 0, .w = 40, .h = 40 },
        .{ .x = 0, .y = 40, .w = 40, .h = 40 },
        .{ .x = 40, .y = 40, .w = 40, .h = 40 },
        .{ .x = 80, .y = 40, .w = 40, .h = 40 },
        .{ .x = 0, .y = 80, .w = 40, .h = 40 },
        .{ .x = 40, .y = 80, .w = 40, .h = 40 },
        .{ .x = 80, .y = 80, .w = 40, .h = 40 },
    });

    const expected_absolute = [_]Rect{
        .{ .x = 40, .y = 10, .w = 40, .h = 40 },
        .{ .x = 80, .y = 10, .w = 40, .h = 40 },
        .{ .x = 120, .y = 10, .w = 40, .h = 40 },
        .{ .x = 40, .y = 50, .w = 40, .h = 40 },
        .{ .x = 80, .y = 50, .w = 40, .h = 40 },
        .{ .x = 120, .y = 50, .w = 40, .h = 40 },
        .{ .x = 40, .y = 90, .w = 40, .h = 40 },
        .{ .x = 80, .y = 90, .w = 40, .h = 40 },
        .{ .x = 120, .y = 90, .w = 40, .h = 40 },
    };
    for (expected_absolute, 0..) |expected, index| {
        try expectRect(expected, fixture.childAbsoluteRect(index));
    }
}

test "main/test_fixtures/grid/grid_absolute_container_left_right.html" {
    const columns = [_]style.GridTrack{
        .{ .fixed = 40 },
        .{ .fixed = 40 },
        .{ .fixed = 40 },
    };
    const rows = columns;
    const grid_style: Style = .{
        .display = .grid,
        .grid_template_columns = &columns,
        .grid_template_rows = &rows,
        .padding = .{ .top = 10, .right = 20, .bottom = 30, .left = 40 },
    };
    const child_styles = [_]Style{
        .{
            .position = .absolute,
            .inset = .{
                .top = .auto,
                .right = .{ .length = 2 },
                .bottom = .auto,
                .left = .{ .length = 5 },
            },
        },
        .{},
        .{},
        .{},
        .{},
        .{},
        .{},
        .{},
        .{},
        .{},
    };

    var fixture = try Fixture.init(grid_style, &child_styles);
    defer fixture.deinit();
    fixture.run(.{ .width = 180, .height = 160 });

    try expectFixture(&fixture, .{ .w = 180, .h = 160 }, &.{
        .{ .x = 5, .y = 0, .w = 113, .h = 0 },
        .{ .x = 0, .y = 0, .w = 40, .h = 40 },
        .{ .x = 40, .y = 0, .w = 40, .h = 40 },
        .{ .x = 80, .y = 0, .w = 40, .h = 40 },
        .{ .x = 0, .y = 40, .w = 40, .h = 40 },
        .{ .x = 40, .y = 40, .w = 40, .h = 40 },
        .{ .x = 80, .y = 40, .w = 40, .h = 40 },
        .{ .x = 0, .y = 80, .w = 40, .h = 40 },
        .{ .x = 40, .y = 80, .w = 40, .h = 40 },
        .{ .x = 80, .y = 80, .w = 40, .h = 40 },
    });

    try expectRect(
        .{ .x = 45, .y = 10, .w = 113, .h = 0 },
        fixture.childAbsoluteRect(0),
    );
}
