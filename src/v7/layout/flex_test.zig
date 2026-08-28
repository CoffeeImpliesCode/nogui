//! Specifies the direct-tree contract for the modular flex layout engine.

const std = @import("std");
const Id = @import("../id.zig").Id;
const style = @import("../style.zig");
const widget = @import("../widget.zig");
const flex = @import("flex.zig");
const dispatch = @import("dispatch.zig");

const Rect = widget.Rect;
const Style = style.Style;
const WidgetKind = widget.WidgetKind;
const WidgetTree = widget.WidgetTree;

fn appendNode(tree: *WidgetTree, id: Id, parent: Id, node_style: Style) !void {
    const kind: WidgetKind = switch (node_style.display) {
        .flex => .{ .row = .{} },
        .block, .flow_root, .grid => .{ .column = .{} },
        .none => .{ .spacer = .{} },
    };
    try tree.appendNode(.{
        .id = id,
        .kind = kind,
        .parent = parent,
        .style = node_style,
    });
}

fn fixedItem(width: f32, height: f32) Style {
    return .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = width },
            .height = .{ .length = height },
        },
    };
}

fn growingItem(basis: f32, height: f32) Style {
    return .{
        .display = .block,
        .grow = 1,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .{ .length = height } },
        .flex_basis = .{ .length = basis },
    };
}

fn layoutContainer(
    tree: *WidgetTree,
    container_id: Id,
    available: widget.Size,
) !void {
    try flex.layoutContainer(tree, container_id, .{
        .allocator = std.testing.allocator,
        .available = available,
        .measure = null,
    });
}

fn expectRect(expected: Rect, actual: Rect) !void {
    const tolerance: f32 = 0.001;
    try std.testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
    try std.testing.expectApproxEqAbs(expected.w, actual.w, tolerance);
    try std.testing.expectApproxEqAbs(expected.h, actual.h, tolerance);
}

fn expectRelative(tree: *const WidgetTree, id: Id, expected: Rect) !void {
    try expectRect(expected, tree.nodeConst(id).?.rect);
}

const CountedLeafMeasure = struct {
    var calls: usize = 0;

    fn measure(_: []const u8, _: f32, _: u8) widget.Size {
        calls += 1;
        return .{ .width = 10, .height = 10 };
    }
};

test "fixed row distributes space around and evenly" {
    const scenarios = [_]struct {
        justify: style.Justify,
        expected_x: [2]f32,
    }{
        .{ .justify = .space_around, .expected_x = .{ 15, 65 } },
        .{ .justify = .space_evenly, .expected_x = .{ 20, 60 } },
    };

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const first_id: Id = @enumFromInt(1);
        const second_id: Id = @enumFromInt(2);
        const container_id: Id = @enumFromInt(3);

        try appendNode(&tree, first_id, container_id, fixedItem(20, 10));
        try appendNode(&tree, second_id, container_id, fixedItem(20, 10));
        try appendNode(&tree, container_id, .root, .{
            .display = .flex,
            .direction = .row,
            .justify = scenario.justify,
            .@"align" = .start,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 20 },
            },
        });
        try tree.appendChild(container_id, first_id);
        try tree.appendChild(container_id, second_id);

        try layoutContainer(&tree, container_id, .{ .width = 100, .height = 20 });

        try expectRelative(
            &tree,
            first_id,
            .{ .x = scenario.expected_x[0], .y = 0, .w = 20, .h = 10 },
        );
        try expectRelative(
            &tree,
            second_id,
            .{ .x = scenario.expected_x[1], .y = 0, .w = 20, .h = 10 },
        );
    }
}

test "grow redistribution honors minimum and maximum clamps" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const capped_id: Id = @enumFromInt(1);
    const floored_id: Id = @enumFromInt(2);
    const flexible_id: Id = @enumFromInt(3);
    const container_id: Id = @enumFromInt(4);

    var capped = growingItem(20, 10);
    capped.max_size.width = .{ .length = 30 };
    var floored = growingItem(20, 10);
    floored.min_size.width = .{ .length = 70 };

    try appendNode(&tree, capped_id, container_id, capped);
    try appendNode(&tree, floored_id, container_id, floored);
    try appendNode(&tree, flexible_id, container_id, growingItem(20, 10));
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 150 },
            .height = .{ .length = 20 },
        },
    });
    try tree.appendChild(container_id, capped_id);
    try tree.appendChild(container_id, floored_id);
    try tree.appendChild(container_id, flexible_id);

    try layoutContainer(&tree, container_id, .{ .width = 150, .height = 20 });

    try expectRelative(&tree, capped_id, .{ .x = 0, .y = 0, .w = 30, .h = 10 });
    try expectRelative(&tree, floored_id, .{ .x = 30, .y = 0, .w = 70, .h = 10 });
    try expectRelative(&tree, flexible_id, .{ .x = 100, .y = 0, .w = 50, .h = 10 });
}

test "wrapped RTL row reverse applies align content between lines" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const third_id: Id = @enumFromInt(3);
    const container_id: Id = @enumFromInt(4);

    try appendNode(&tree, first_id, container_id, fixedItem(40, 20));
    try appendNode(&tree, second_id, container_id, fixedItem(40, 20));
    try appendNode(&tree, third_id, container_id, fixedItem(40, 20));
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row_reverse,
        .writing_direction = .rtl,
        .wrap = .wrap,
        .flex_wrap = .wrap,
        .@"align" = .start,
        .align_content = .space_between,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);
    try tree.appendChild(container_id, third_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 40, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 40, .y = 0, .w = 40, .h = 20 });
    try expectRelative(&tree, third_id, .{ .x = 0, .y = 80, .w = 40, .h = 20 });
}

test "nested wrapping row uses its definite width for auto cross size" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const nested_id: Id = @enumFromInt(3);
    const parent_id: Id = @enumFromInt(4);

    try appendNode(&tree, first_id, nested_id, fixedItem(60, 10));
    try appendNode(&tree, second_id, nested_id, fixedItem(60, 10));
    try appendNode(&tree, nested_id, parent_id, .{
        .display = .flex,
        .direction = .row,
        .wrap = .wrap,
        .flex_wrap = .wrap,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .auto,
        },
    });
    try appendNode(&tree, parent_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 500 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(nested_id, first_id);
    try tree.appendChild(nested_id, second_id);
    try tree.appendChild(parent_id, nested_id);

    try layoutContainer(&tree, parent_id, .{ .width = 500, .height = 100 });

    try expectRelative(&tree, nested_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 10, .w = 60, .h = 10 });
}

test "nested wrapping row uses max width for auto cross size" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const nested_id: Id = @enumFromInt(3);
    const parent_id: Id = @enumFromInt(4);

    try appendNode(&tree, first_id, nested_id, fixedItem(60, 10));
    try appendNode(&tree, second_id, nested_id, fixedItem(60, 10));
    try appendNode(&tree, nested_id, parent_id, .{
        .display = .flex,
        .direction = .row,
        .wrap = .wrap,
        .flex_wrap = .wrap,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .auto,
            .height = .auto,
        },
        .max_size = .{
            .width = .{ .length = 100 },
            .height = .auto,
        },
    });
    try appendNode(&tree, parent_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 500 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(nested_id, first_id);
    try tree.appendChild(nested_id, second_id);
    try tree.appendChild(parent_id, nested_id);

    try layoutContainer(&tree, parent_id, .{ .width = 500, .height = 100 });

    try expectRelative(&tree, nested_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 10, .w = 60, .h = 10 });
}

test "automatic horizontal margin consumes free space before justify" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);

    var first = fixedItem(20, 10);
    first.margin_inset = .{
        .top = .{ .length = 0 },
        .right = .auto,
        .bottom = .{ .length = 0 },
        .left = .{ .length = 0 },
    };

    try appendNode(&tree, first_id, container_id, first);
    try appendNode(&tree, second_id, container_id, fixedItem(20, 10));
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .justify = .center,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 20 },
        },
    });
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 20 });

    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 80, .y = 0, .w = 20, .h = 10 });
}

test "border and padding preserve relative geometry and exclude absolute child" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const absolute_id: Id = @enumFromInt(2);
    const second_id: Id = @enumFromInt(3);
    const container_id: Id = @enumFromInt(4);

    var absolute = fixedItem(10, 8);
    absolute.position = .absolute;
    absolute.inset = .{
        .top = .{ .length = 9 },
        .right = .auto,
        .bottom = .auto,
        .left = .{ .length = 7 },
    };

    try appendNode(&tree, first_id, container_id, fixedItem(20, 10));
    try appendNode(&tree, absolute_id, container_id, absolute);
    try appendNode(&tree, second_id, container_id, fixedItem(20, 10));
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .justify = .space_between,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 120 },
            .height = .{ .length = 60 },
        },
        .border = .{ .top = 2, .right = 5, .bottom = 4, .left = 3 },
        .padding = .{ .top = 13, .right = 11, .bottom = 5, .left = 7 },
        .border_inset = .{
            .top = .{ .length = 2 },
            .right = .{ .length = 5 },
            .bottom = .{ .length = 4 },
            .left = .{ .length = 3 },
        },
        .padding_inset = .{
            .top = .{ .length = 13 },
            .right = .{ .length = 11 },
            .bottom = .{ .length = 5 },
            .left = .{ .length = 7 },
        },
    });
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, absolute_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 120, .height = 60 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 120, .h = 60 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 74, .y = 0, .w = 20, .h = 10 });
    try expectRelative(&tree, absolute_id, .{ .x = 0, .y = -4, .w = 10, .h = 8 });
    try expectRect(.{ .x = 10, .y = 15, .w = 20, .h = 10 }, widget.absoluteRect(&tree, first_id));
    try expectRect(.{ .x = 84, .y = 15, .w = 20, .h = 10 }, widget.absoluteRect(&tree, second_id));
    try expectRect(
        .{ .x = 10, .y = 11, .w = 10, .h = 8 },
        widget.absoluteRect(&tree, absolute_id),
    );
}

test "non-finite available size returns InvalidStyle" {
    const invalid_sizes = [_]widget.Size{
        .{ .width = std.math.nan(f32), .height = 20 },
        .{ .width = 100, .height = std.math.inf(f32) },
    };

    for (invalid_sizes) |available| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const container_id: Id = @enumFromInt(1);
        try appendNode(&tree, container_id, .root, .{
            .display = .flex,
            .direction = .row,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 20 },
            },
        });

        try std.testing.expectError(error.InvalidStyle, flex.layoutContainer(
            &tree,
            container_id,
            .{
                .allocator = std.testing.allocator,
                .available = available,
                .measure = null,
            },
        ));
    }
}

test "absolute auto insets use row justify center" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    var absolute = fixedItem(60, 40);
    absolute.position = .absolute;
    absolute.inset = .{
        .top = .auto,
        .right = .auto,
        .bottom = .auto,
        .left = .auto,
    };
    try appendNode(&tree, absolute_id, container_id, absolute);
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .justify = .center,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 110 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(container_id, absolute_id);

    try layoutContainer(&tree, container_id, .{ .width = 110, .height = 100 });

    try expectRelative(&tree, absolute_id, .{ .x = 25, .y = 0, .w = 60, .h = 40 });
}

test "absolute auto insets use row cross-axis alignment" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    var absolute = fixedItem(60, 40);
    absolute.position = .absolute;
    absolute.inset = .{
        .top = .auto,
        .right = .auto,
        .bottom = .auto,
        .left = .auto,
    };
    try appendNode(&tree, absolute_id, container_id, absolute);
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .justify = .start,
        .@"align" = .center,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 110 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(container_id, absolute_id);

    try layoutContainer(&tree, container_id, .{ .width = 110, .height = 100 });

    try expectRelative(&tree, absolute_id, .{ .x = 0, .y = 30, .w = 60, .h = 40 });
}

test "indefinite flex percentages collapse while definite percentages resolve" {
    {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: Id = @enumFromInt(1);
        const container_id: Id = @enumFromInt(2);

        var child = fixedItem(0, 0);
        child.size = .{
            .width = .{ .percent = 0.5 },
            .height = .{ .percent = 0.5 },
        };
        try appendNode(&tree, child_id, container_id, child);
        try appendNode(&tree, container_id, .root, .{
            .display = .flex,
            .direction = .row,
            .@"align" = .start,
            .box_sizing = .border_box,
            .size = .{ .width = .auto, .height = .auto },
        });
        try tree.appendChild(container_id, child_id);

        try flex.layoutContainer(&tree, container_id, .{
            .allocator = std.testing.allocator,
            .available = .{ .width = 100, .height = 100 },
            .measure = null,
            .intrinsic_width = true,
            .intrinsic_height = true,
        });

        try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 0, .h = 0 });
        try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 0, .h = 0 });
    }

    {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: Id = @enumFromInt(1);
        const container_id: Id = @enumFromInt(2);

        var child = fixedItem(0, 0);
        child.size = .{
            .width = .{ .percent = 0.5 },
            .height = .{ .percent = 0.5 },
        };
        try appendNode(&tree, child_id, container_id, child);
        try appendNode(&tree, container_id, .root, .{
            .display = .flex,
            .direction = .row,
            .@"align" = .start,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 100 },
            },
        });
        try tree.appendChild(container_id, child_id);

        try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 });

        try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
        try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 50, .h = 50 });
    }
}

test "absolute aspect ratio reflows after max-width clamp" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    try tree.appendNode(.{
        .id = absolute_id,
        .kind = .{ .spacer = .{ .size = 100 } },
        .parent = container_id,
        .style = .{
            .display = .block,
            .position = .absolute,
            .box_sizing = .border_box,
            .size = .{ .width = .auto, .height = .auto },
            .max_size = .{ .width = .{ .length = 50 }, .height = .auto },
            .aspect_ratio = 3,
            .inset = .{
                .top = .auto,
                .right = .auto,
                .bottom = .auto,
                .left = .auto,
            },
        },
    });
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(container_id, absolute_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 });

    try expectRelative(
        &tree,
        absolute_id,
        .{ .x = 0, .y = 0, .w = 50, .h = 50.0 / 3.0 },
    );
}

test "automatic flex minimum follows overflow visibility" {
    const scenarios = [_]struct {
        overflow: style.Overflow,
        expected_width: f32,
    }{
        .{ .overflow = .visible, .expected_width = 100 },
        .{ .overflow = .hidden, .expected_width = 50 },
        .{ .overflow = .scroll, .expected_width = 50 },
    };

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: Id = @enumFromInt(1);
        const container_id: Id = @enumFromInt(2);

        try tree.appendNode(.{
            .id = child_id,
            .kind = .{ .spacer = .{ .size = 100 } },
            .parent = container_id,
            .style = .{
                .display = .block,
                .box_sizing = .border_box,
                .shrink = 1,
                .overflow = .{ .width = scenario.overflow, .height = .visible },
                .size = .{
                    .width = .auto,
                    .height = .{ .length = 10 },
                },
            },
        });
        try appendNode(&tree, container_id, .root, .{
            .display = .flex,
            .direction = .row,
            .@"align" = .start,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 50 },
                .height = .{ .length = 50 },
            },
        });
        try tree.appendChild(container_id, child_id);

        try layoutContainer(&tree, container_id, .{ .width = 50, .height = 50 });

        try expectRelative(
            &tree,
            child_id,
            .{ .x = 0, .y = 0, .w = scenario.expected_width, .h = 10 },
        );
    }
}

test "automatic flex minimum is capped by preferred width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .spacer = .{ .size = 100 } },
        .parent = container_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .shrink = 1,
            .overflow = .{ .width = .visible, .height = .visible },
            .size = .{
                .width = .{ .length = 50 },
                .height = .{ .length = 10 },
            },
        },
    });
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 50 },
        },
    });
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 50, .height = 50 });

    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
}

test "automatic flex minimum is capped by max width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .spacer = .{ .size = 100 } },
        .parent = container_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .shrink = 1,
            .overflow = .{ .width = .visible, .height = .visible },
            .size = .{
                .width = .auto,
                .height = .{ .length = 10 },
            },
            .max_size = .{
                .width = .{ .length = 50 },
                .height = .auto,
            },
        },
    });
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 50 },
        },
    });
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 50, .height = 50 });

    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
}

test "absolute auto insets resolve auto margins to zero" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    var absolute = fixedItem(20, 20);
    absolute.position = .absolute;
    absolute.inset = .{
        .top = .auto,
        .right = .auto,
        .bottom = .auto,
        .left = .auto,
    };
    absolute.margin_inset = .{
        .top = .auto,
        .right = .auto,
        .bottom = .auto,
        .left = .auto,
    };
    try appendNode(&tree, absolute_id, container_id, absolute);
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(container_id, absolute_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, absolute_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
}

test "clip overflow keeps the visible automatic flex minimum" {
    const scenarios = [_]struct {
        overflow: style.Overflow,
        expected_width: f32,
    }{
        .{ .overflow = .visible, .expected_width = 100 },
        .{ .overflow = .clip, .expected_width = 100 },
        .{ .overflow = .hidden, .expected_width = 50 },
        .{ .overflow = .scroll, .expected_width = 50 },
    };

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: Id = @enumFromInt(1);
        const container_id: Id = @enumFromInt(2);

        try tree.appendNode(.{
            .id = child_id,
            .kind = .{ .spacer = .{ .size = 100 } },
            .parent = container_id,
            .style = .{
                .display = .block,
                .box_sizing = .border_box,
                .shrink = 1,
                .overflow = .{ .width = scenario.overflow, .height = .visible },
                .size = .{
                    .width = .auto,
                    .height = .{ .length = 10 },
                },
            },
        });
        try appendNode(&tree, container_id, .root, .{
            .display = .flex,
            .direction = .row,
            .@"align" = .start,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 50 },
                .height = .{ .length = 50 },
            },
        });
        try tree.appendChild(container_id, child_id);

        try layoutContainer(&tree, container_id, .{ .width = 50, .height = 50 });

        try expectRelative(
            &tree,
            child_id,
            .{ .x = 0, .y = 0, .w = scenario.expected_width, .h = 10 },
        );
    }
}

test "vertical scrollbar gutter reduces row flex space" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);

    try appendNode(&tree, first_id, container_id, growingItem(0, 20));
    try appendNode(&tree, second_id, container_id, growingItem(0, 20));
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 20 },
        },
        .overflow = .{ .width = .visible, .height = .scroll },
        .scrollbar_width = 15,
    });
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 20 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 42.5, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 42.5, .y = 0, .w = 42.5, .h = 20 });
    try expectRect(.{ .x = 0, .y = 0, .w = 42.5, .h = 20 }, widget.absoluteRect(&tree, first_id));
    try expectRect(
        .{ .x = 42.5, .y = 0, .w = 42.5, .h = 20 },
        widget.absoluteRect(&tree, second_id),
    );
}

test "horizontal scrollbar gutter reduces stretched cross size" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    try appendNode(&tree, child_id, container_id, .{
        .display = .block,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 10 },
            .height = .auto,
        },
    });
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .stretch,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
        .overflow = .{ .width = .scroll, .height = .visible },
        .scrollbar_width = 15,
    });
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 10, .h = 85 });
    try expectRect(.{ .x = 0, .y = 0, .w = 10, .h = 85 }, widget.absoluteRect(&tree, child_id));
}

test "non-scroll overflow modes do not reserve a gutter" {
    const overflow_modes = [_]style.Overflow{ .hidden, .visible, .clip, .auto };

    for (overflow_modes) |overflow_mode| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: Id = @enumFromInt(1);
        const container_id: Id = @enumFromInt(2);

        try appendNode(&tree, child_id, container_id, growingItem(0, 20));
        try appendNode(&tree, container_id, .root, .{
            .display = .flex,
            .direction = .row,
            .@"align" = .start,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 20 },
            },
            .overflow = .{ .width = .visible, .height = overflow_mode },
            .scrollbar_width = 15,
        });
        try tree.appendChild(container_id, child_id);

        try layoutContainer(&tree, container_id, .{ .width = 100, .height = 20 });

        try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
        try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
        try expectRect(
            .{ .x = 0, .y = 0, .w = 100, .h = 20 },
            widget.absoluteRect(&tree, child_id),
        );
    }
}

test "content-box vertical scrollbar gutter reduces flex content width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    try appendNode(&tree, child_id, container_id, .{
        .display = .block,
        .grow = 1,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
        .flex_basis = .{ .length = 0 },
    });
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .stretch,
        .box_sizing = .content_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 20 },
        },
        .overflow = .{ .width = .visible, .height = .scroll },
        .scrollbar_width = 15,
    });
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 20 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 85, .h = 20 });
    try expectRect(
        .{ .x = 0, .y = 0, .w = 85, .h = 20 },
        widget.absoluteRect(&tree, child_id),
    );
}

test "auto border-box intrinsic size adds scrollbar gutters" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .spacer = .{ .size = 40 } },
        .parent = container_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .auto, .height = .auto },
        },
    });
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .stretch,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
        .overflow = .{ .width = .scroll, .height = .scroll },
        .scrollbar_width = 15,
    });
    try tree.appendChild(container_id, child_id);

    try flex.layoutContainer(&tree, container_id, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 100 },
        .measure = null,
        .intrinsic_width = true,
        .intrinsic_height = true,
    });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 55, .h = 55 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 40, .h = 40 });
    try expectRect(
        .{ .x = 0, .y = 0, .w = 40, .h = 40 },
        widget.absoluteRect(&tree, child_id),
    );
}

test "explicit intrinsic widths add vertical scrollbar gutter" {
    const widths = [_]style.Dimension{ .max_content, .{ .fit_content = 100 } };

    for (widths) |width| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: Id = @enumFromInt(1);
        const container_id: Id = @enumFromInt(2);

        try tree.appendNode(.{
            .id = child_id,
            .kind = .{ .spacer = .{ .size = 40 } },
            .parent = container_id,
            .style = .{
                .display = .block,
                .box_sizing = .border_box,
                .size = .{ .width = .auto, .height = .auto },
            },
        });
        try appendNode(&tree, container_id, .root, .{
            .display = .flex,
            .direction = .row,
            .@"align" = .stretch,
            .box_sizing = .border_box,
            .size = .{
                .width = width,
                .height = .{ .length = 40 },
            },
            .overflow = .{ .width = .visible, .height = .scroll },
            .scrollbar_width = 15,
        });
        try tree.appendChild(container_id, child_id);

        try layoutContainer(&tree, container_id, .{ .width = 100, .height = 40 });

        try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 55, .h = 40 });
        try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 40, .h = 40 });
        try expectRect(
            .{ .x = 0, .y = 0, .w = 40, .h = 40 },
            widget.absoluteRect(&tree, child_id),
        );
    }
}

test "grow factors below one leave proportional free space unallocated" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const third_id: Id = @enumFromInt(3);
    const container_id: Id = @enumFromInt(4);

    var first = growingItem(40, 10);
    first.grow = 0.2;
    var second = growingItem(0, 10);
    second.grow = 0.2;
    var third = growingItem(0, 10);
    third.grow = 0.4;

    try appendNode(&tree, first_id, container_id, first);
    try appendNode(&tree, second_id, container_id, second);
    try appendNode(&tree, third_id, container_id, third);
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 500 },
            .height = .{ .length = 10 },
        },
    });
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);
    try tree.appendChild(container_id, third_id);

    try layoutContainer(&tree, container_id, .{ .width = 500, .height = 10 });

    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 132, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 132, .y = 0, .w = 92, .h = 10 });
    try expectRelative(&tree, third_id, .{ .x = 224, .y = 0, .w = 184, .h = 10 });
}

test "wrapped cross overflow preserves signed positional alignment" {
    const scenarios = [_]struct {
        align_content: style.AlignContent,
        expected_y: [3]f32,
    }{
        .{ .align_content = .center, .expected_y = .{ -25, -5, 15 } },
        .{ .align_content = .end, .expected_y = .{ -50, -30, -10 } },
        .{ .align_content = .space_between, .expected_y = .{ 0, 20, 40 } },
        .{ .align_content = .space_around, .expected_y = .{ 0, 20, 40 } },
        .{ .align_content = .space_evenly, .expected_y = .{ 0, 20, 40 } },
    };

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const first_id: Id = @enumFromInt(1);
        const second_id: Id = @enumFromInt(2);
        const third_id: Id = @enumFromInt(3);
        const container_id: Id = @enumFromInt(4);

        try appendNode(&tree, first_id, container_id, fixedItem(20, 20));
        try appendNode(&tree, second_id, container_id, fixedItem(20, 20));
        try appendNode(&tree, third_id, container_id, fixedItem(20, 20));
        try appendNode(&tree, container_id, .root, .{
            .display = .flex,
            .direction = .row,
            .wrap = .wrap,
            .flex_wrap = .wrap,
            .@"align" = .start,
            .align_content = scenario.align_content,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 20 },
                .height = .{ .length = 10 },
            },
        });
        try tree.appendChild(container_id, first_id);
        try tree.appendChild(container_id, second_id);
        try tree.appendChild(container_id, third_id);

        try layoutContainer(&tree, container_id, .{ .width = 20, .height = 10 });

        try expectRelative(
            &tree,
            first_id,
            .{ .x = 0, .y = scenario.expected_y[0], .w = 20, .h = 20 },
        );
        try expectRelative(
            &tree,
            second_id,
            .{ .x = 0, .y = scenario.expected_y[1], .w = 20, .h = 20 },
        );
        try expectRelative(
            &tree,
            third_id,
            .{ .x = 0, .y = scenario.expected_y[2], .w = 20, .h = 20 },
        );
    }
}

test "column main overflow preserves signed justify offsets" {
    const scenarios = [_]struct {
        justify: style.Justify,
        expected_y: f32,
    }{
        .{ .justify = .center, .expected_y = -25 },
        .{ .justify = .end, .expected_y = -50 },
    };

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: Id = @enumFromInt(1);
        const container_id: Id = @enumFromInt(2);

        var child = fixedItem(10, 100);
        child.shrink = 0;

        try appendNode(&tree, child_id, container_id, child);
        try appendNode(&tree, container_id, .root, .{
            .display = .flex,
            .direction = .column,
            .justify = scenario.justify,
            .@"align" = .start,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 20 },
                .height = .{ .length = 50 },
            },
        });
        try tree.appendChild(container_id, child_id);

        try layoutContainer(&tree, container_id, .{ .width = 20, .height = 50 });

        try expectRelative(
            &tree,
            child_id,
            .{ .x = 0, .y = scenario.expected_y, .w = 10, .h = 100 },
        );
    }
}

test "cross-axis overflow preserves signed item alignment" {
    const scenarios = [_]struct {
        alignment: style.Align,
        margin_top: f32,
        margin_bottom: f32,
        expected_y: f32,
    }{
        .{ .alignment = .center, .margin_top = 0, .margin_bottom = 0, .expected_y = -10 },
        .{ .alignment = .end, .margin_top = 0, .margin_bottom = 0, .expected_y = -20 },
        .{ .alignment = .center, .margin_top = 10, .margin_bottom = 20, .expected_y = -15 },
        .{ .alignment = .end, .margin_top = 10, .margin_bottom = 20, .expected_y = -40 },
    };

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: Id = @enumFromInt(1);
        const container_id: Id = @enumFromInt(2);

        var child = fixedItem(10, 70);
        child.margin_inset = .{
            .top = .{ .length = scenario.margin_top },
            .right = .{ .length = 0 },
            .bottom = .{ .length = scenario.margin_bottom },
            .left = .{ .length = 0 },
        };

        try appendNode(&tree, child_id, container_id, child);
        try appendNode(&tree, container_id, .root, .{
            .display = .flex,
            .direction = .row,
            .justify = .start,
            .@"align" = scenario.alignment,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 20 },
                .height = .{ .length = 50 },
            },
        });
        try tree.appendChild(container_id, child_id);

        try layoutContainer(&tree, container_id, .{ .width = 20, .height = 50 });

        try expectRelative(
            &tree,
            child_id,
            .{ .x = 0, .y = scenario.expected_y, .w = 10, .h = 70 },
        );
    }
}

test "negative main free space distinguishes safe and unsafe center" {
    const scenarios = [_]struct {
        justify: style.Justify,
        expected_x: f32,
    }{
        .{ .justify = .safe_center, .expected_x = 0 },
        .{ .justify = .unsafe_center, .expected_x = -25 },
        .{ .justify = .center, .expected_x = -25 },
    };

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: Id = @enumFromInt(1);
        const container_id: Id = @enumFromInt(2);

        var child = fixedItem(100, 10);
        child.shrink = 0;

        try appendNode(&tree, child_id, container_id, child);
        try appendNode(&tree, container_id, .root, .{
            .display = .flex,
            .direction = .row,
            .justify = scenario.justify,
            .@"align" = .start,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 50 },
                .height = .{ .length = 20 },
            },
        });
        try tree.appendChild(container_id, child_id);

        try layoutContainer(&tree, container_id, .{ .width = 50, .height = 20 });

        try expectRelative(
            &tree,
            child_id,
            .{ .x = scenario.expected_x, .y = 0, .w = 100, .h = 10 },
        );
    }
}

test "negative wrapped cross free space distinguishes safe and unsafe center" {
    const scenarios = [_]struct {
        align_content: style.AlignContent,
        expected_y: [3]f32,
    }{
        .{ .align_content = .safe_center, .expected_y = .{ 0, 20, 40 } },
        .{ .align_content = .unsafe_center, .expected_y = .{ -25, -5, 15 } },
        .{ .align_content = .center, .expected_y = .{ -25, -5, 15 } },
    };

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const first_id: Id = @enumFromInt(1);
        const second_id: Id = @enumFromInt(2);
        const third_id: Id = @enumFromInt(3);
        const container_id: Id = @enumFromInt(4);

        try appendNode(&tree, first_id, container_id, fixedItem(20, 20));
        try appendNode(&tree, second_id, container_id, fixedItem(20, 20));
        try appendNode(&tree, third_id, container_id, fixedItem(20, 20));
        try appendNode(&tree, container_id, .root, .{
            .display = .flex,
            .direction = .row,
            .wrap = .wrap,
            .flex_wrap = .wrap,
            .@"align" = .start,
            .align_content = scenario.align_content,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 20 },
                .height = .{ .length = 10 },
            },
        });
        try tree.appendChild(container_id, first_id);
        try tree.appendChild(container_id, second_id);
        try tree.appendChild(container_id, third_id);

        try layoutContainer(&tree, container_id, .{ .width = 20, .height = 10 });

        try expectRelative(
            &tree,
            first_id,
            .{ .x = 0, .y = scenario.expected_y[0], .w = 20, .h = 20 },
        );
        try expectRelative(
            &tree,
            second_id,
            .{ .x = 0, .y = scenario.expected_y[1], .w = 20, .h = 20 },
        );
        try expectRelative(
            &tree,
            third_id,
            .{ .x = 0, .y = scenario.expected_y[2], .w = 20, .h = 20 },
        );
    }
}

test "oversized cross item distinguishes safe and unsafe alignment" {
    const scenarios = [_]struct {
        align_items: style.Align,
        align_self: style.AlignSelf,
        expected_y: f32,
    }{
        .{ .align_items = .safe_center, .align_self = .auto, .expected_y = 0 },
        .{ .align_items = .unsafe_center, .align_self = .auto, .expected_y = -10 },
        .{ .align_items = .center, .align_self = .auto, .expected_y = -10 },
        .{ .align_items = .start, .align_self = .safe_center, .expected_y = 0 },
        .{ .align_items = .start, .align_self = .unsafe_center, .expected_y = -10 },
        .{ .align_items = .start, .align_self = .center, .expected_y = -10 },
    };

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: Id = @enumFromInt(1);
        const container_id: Id = @enumFromInt(2);

        var child = fixedItem(10, 70);
        child.align_self = scenario.align_self;

        try appendNode(&tree, child_id, container_id, child);
        try appendNode(&tree, container_id, .root, .{
            .display = .flex,
            .direction = .row,
            .justify = .start,
            .@"align" = scenario.align_items,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 20 },
                .height = .{ .length = 50 },
            },
        });
        try tree.appendChild(container_id, child_id);

        try layoutContainer(&tree, container_id, .{ .width = 20, .height = 50 });

        try expectRelative(
            &tree,
            child_id,
            .{ .x = 0, .y = scenario.expected_y, .w = 10, .h = 70 },
        );
    }
}

test "positive free space makes all center safety variants equivalent" {
    const scenarios = [_]struct {
        justify: style.Justify,
        align_items: style.Align,
        align_content: style.AlignContent,
        align_self: style.AlignSelf,
    }{
        .{
            .justify = .safe_center,
            .align_items = .safe_center,
            .align_content = .safe_center,
            .align_self = .safe_center,
        },
        .{
            .justify = .unsafe_center,
            .align_items = .unsafe_center,
            .align_content = .unsafe_center,
            .align_self = .unsafe_center,
        },
        .{
            .justify = .center,
            .align_items = .center,
            .align_content = .center,
            .align_self = .center,
        },
    };

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const first_id: Id = @enumFromInt(1);
        const second_id: Id = @enumFromInt(2);
        const third_id: Id = @enumFromInt(3);
        const fourth_id: Id = @enumFromInt(4);
        const container_id: Id = @enumFromInt(5);

        var third = fixedItem(40, 10);
        third.align_self = scenario.align_self;

        try appendNode(&tree, first_id, container_id, fixedItem(40, 10));
        try appendNode(&tree, second_id, container_id, fixedItem(40, 20));
        try appendNode(&tree, third_id, container_id, third);
        try appendNode(&tree, fourth_id, container_id, fixedItem(40, 20));
        try appendNode(&tree, container_id, .root, .{
            .display = .flex,
            .direction = .row,
            .wrap = .wrap,
            .flex_wrap = .wrap,
            .justify = scenario.justify,
            .@"align" = scenario.align_items,
            .align_content = scenario.align_content,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 100 },
            },
        });
        try tree.appendChild(container_id, first_id);
        try tree.appendChild(container_id, second_id);
        try tree.appendChild(container_id, third_id);
        try tree.appendChild(container_id, fourth_id);

        try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 });

        try expectRelative(&tree, first_id, .{ .x = 10, .y = 35, .w = 40, .h = 10 });
        try expectRelative(&tree, second_id, .{ .x = 50, .y = 30, .w = 40, .h = 20 });
        try expectRelative(&tree, third_id, .{ .x = 10, .y = 55, .w = 40, .h = 10 });
        try expectRelative(&tree, fourth_id, .{ .x = 50, .y = 50, .w = 40, .h = 20 });
    }
}

test "fractional grow clamp preserves initial free-space scale" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);

    var first = growingItem(0, 10);
    first.grow = 0.2;
    first.max_size.width = .{ .length = 10 };
    var second = growingItem(0, 10);
    second.grow = 0.2;

    try appendNode(&tree, first_id, container_id, first);
    try appendNode(&tree, second_id, container_id, second);
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .justify = .start,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 10 },
        },
    });
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 10 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 10, .y = 0, .w = 20, .h = 10 });

    const container_rect = tree.nodeConst(container_id).?.rect;
    const second_rect = tree.nodeConst(second_id).?.rect;
    try std.testing.expectApproxEqAbs(
        @as(f32, 70),
        container_rect.w - second_rect.x - second_rect.w,
        0.001,
    );
}

test "initial minimum freeze preserves initial free-space scale" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);

    var first = growingItem(0, 10);
    first.grow = 0.2;
    first.min_size.width = .{ .length = 20 };
    var second = growingItem(0, 10);
    second.grow = 0.2;

    try appendNode(&tree, first_id, container_id, first);
    try appendNode(&tree, second_id, container_id, second);
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .justify = .start,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 10 },
        },
    });
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 10 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 20, .y = 0, .w = 20, .h = 10 });

    const container_rect = tree.nodeConst(container_id).?.rect;
    const second_rect = tree.nodeConst(second_id).?.rect;
    try std.testing.expectApproxEqAbs(
        @as(f32, 60),
        container_rect.w - second_rect.x - second_rect.w,
        0.001,
    );
}

test "grow violation selection freezes only the dominant minimum" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const third_id: Id = @enumFromInt(3);
    const container_id: Id = @enumFromInt(4);

    var first = growingItem(0, 10);
    first.grow = 0.2;
    first.max_size.width = .{ .length = 10 };
    var second = growingItem(0, 10);
    second.grow = 0.2;
    second.min_size.width = .{ .length = 90 };
    var third = growingItem(0, 10);
    third.grow = 0.2;

    try appendNode(&tree, first_id, container_id, first);
    try appendNode(&tree, second_id, container_id, second);
    try appendNode(&tree, third_id, container_id, third);
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .justify = .start,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 10 },
        },
    });
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);
    try tree.appendChild(container_id, third_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 10 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 5, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 5, .y = 0, .w = 90, .h = 10 });
    try expectRelative(&tree, third_id, .{ .x = 95, .y = 0, .w = 5, .h = 10 });

    const container_rect = tree.nodeConst(container_id).?.rect;
    const third_rect = tree.nodeConst(third_id).?.rect;
    try std.testing.expectApproxEqAbs(
        @as(f32, 0),
        container_rect.w - third_rect.x - third_rect.w,
        0.001,
    );
}

test "fractional shrink factors preserve raw negative free space" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);

    var first = growingItem(50, 10);
    first.grow = 0;
    first.shrink = 0.2;
    var second = growingItem(50, 10);
    second.grow = 0;
    second.shrink = 0.2;

    try appendNode(&tree, first_id, container_id, first);
    try appendNode(&tree, second_id, container_id, second);
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .justify = .start,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 80 },
            .height = .{ .length = 10 },
        },
    });
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 80, .height = 10 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 80, .h = 10 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 46, .h = 10 });
    try expectRelative(&tree, second_id, .{ .x = 46, .y = 0, .w = 46, .h = 10 });

    const container_rect = tree.nodeConst(container_id).?.rect;
    const second_rect = tree.nodeConst(second_id).?.rect;
    try std.testing.expectApproxEqAbs(
        @as(f32, 12),
        second_rect.x + second_rect.w - container_rect.w,
        0.001,
    );
}

test "baseline aligns direct row items by their synthesized baselines" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const container_id: Id = @enumFromInt(3);

    try appendNode(&tree, first_id, container_id, fixedItem(50, 50));
    try appendNode(&tree, second_id, container_id, fixedItem(50, 20));
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .baseline,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 50, .h = 50 });
    try expectRelative(&tree, second_id, .{ .x = 50, .y = 30, .w = 50, .h = 20 });
}

test "baseline propagates through nested flex columns" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const inner_first_id: Id = @enumFromInt(2);
    const inner_second_id: Id = @enumFromInt(3);
    const inner_id: Id = @enumFromInt(4);
    const wrapper_id: Id = @enumFromInt(5);
    const container_id: Id = @enumFromInt(6);

    try appendNode(&tree, first_id, container_id, fixedItem(50, 60));
    try appendNode(&tree, inner_first_id, inner_id, .{
        .display = .flex,
        .direction = .column,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 30 },
        },
    });
    try appendNode(&tree, inner_second_id, inner_id, .{
        .display = .flex,
        .direction = .column,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 40 },
        },
    });
    try appendNode(&tree, inner_id, wrapper_id, .{
        .display = .flex,
        .direction = .column,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 80 },
        },
    });
    try appendNode(&tree, wrapper_id, container_id, .{
        .display = .flex,
        .direction = .column,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    });
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .baseline,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(inner_id, inner_first_id);
    try tree.appendChild(inner_id, inner_second_id);
    try tree.appendChild(wrapper_id, inner_id);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, wrapper_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 50, .h = 60 });
    try expectRelative(&tree, wrapper_id, .{ .x = 50, .y = 30, .w = 50, .h = 80 });
    try expectRelative(&tree, inner_id, .{ .x = 0, .y = 0, .w = 50, .h = 80 });
    try expectRelative(&tree, inner_first_id, .{ .x = 0, .y = 0, .w = 50, .h = 30 });
    try expectRelative(&tree, inner_second_id, .{ .x = 0, .y = 30, .w = 50, .h = 40 });
}

test "wrapped baseline lines include their maximum ascent and descent" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_child_id: Id = @enumFromInt(2);
    const second_id: Id = @enumFromInt(3);
    const third_child_id: Id = @enumFromInt(4);
    const third_id: Id = @enumFromInt(5);
    const fourth_id: Id = @enumFromInt(6);
    const container_id: Id = @enumFromInt(7);

    try appendNode(&tree, first_id, container_id, fixedItem(50, 50));
    try appendNode(&tree, second_child_id, second_id, fixedItem(50, 10));
    try appendNode(&tree, second_id, container_id, .{
        .display = .flex,
        .direction = .column,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 20 },
        },
    });
    try appendNode(&tree, third_child_id, third_id, fixedItem(50, 10));
    try appendNode(&tree, third_id, container_id, .{
        .display = .flex,
        .direction = .column,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 20 },
        },
    });
    try appendNode(&tree, fourth_id, container_id, fixedItem(50, 50));
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .wrap = .wrap,
        .flex_wrap = .wrap,
        .@"align" = .baseline,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(second_id, second_child_id);
    try tree.appendChild(third_id, third_child_id);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);
    try tree.appendChild(container_id, third_id);
    try tree.appendChild(container_id, fourth_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 50, .h = 50 });
    try expectRelative(&tree, second_id, .{ .x = 50, .y = 40, .w = 50, .h = 20 });
    try expectRelative(&tree, second_child_id, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
    try expectRelative(&tree, third_id, .{ .x = 0, .y = 100, .w = 50, .h = 20 });
    try expectRelative(&tree, third_child_id, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
    try expectRelative(&tree, fourth_id, .{ .x = 50, .y = 60, .w = 50, .h = 50 });
}

test "deep nested baseline measurement stays linear" {
    const depths = [_]usize{ 8, 10 };
    for (depths) |depth| {
        CountedLeafMeasure.calls = 0;

        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const leaf_id: Id = @enumFromInt(1);
        const root_id: Id = @enumFromInt(@as(u32, @intCast(depth + 1)));
        try tree.appendNode(.{
            .id = leaf_id,
            .kind = .{ .label = .{ .text = "counted" } },
            .parent = @enumFromInt(2),
            .style = .{
                .display = .block,
                .box_sizing = .border_box,
                .size = .{ .width = .auto, .height = .auto },
            },
        });

        var level: usize = 0;
        while (level < depth) : (level += 1) {
            const id: Id = @enumFromInt(@as(u32, @intCast(level + 2)));
            const parent: Id = if (level + 1 == depth)
                .root
            else
                @enumFromInt(@as(u32, @intCast(level + 3)));
            var node_style = fixedItem(100, 100);
            node_style.display = .flex;
            node_style.direction = if (level + 1 == depth) .row else .column;
            node_style.@"align" = .baseline;
            try appendNode(&tree, id, parent, node_style);
        }

        var child_id = leaf_id;
        level = 0;
        while (level < depth) : (level += 1) {
            const parent_id: Id = @enumFromInt(@as(u32, @intCast(level + 2)));
            try tree.appendChild(parent_id, child_id);
            child_id = parent_id;
        }

        try flex.layoutContainer(&tree, root_id, .{
            .allocator = std.testing.allocator,
            .available = .{ .width = 100, .height = 100 },
            .measure = CountedLeafMeasure.measure,
        });

        try expectRelative(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
        level = 0;
        while (level < depth) : (level += 1) {
            const id: Id = @enumFromInt(@as(u32, @intCast(level + 2)));
            try expectRelative(&tree, id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
        }
        try expectRelative(&tree, leaf_id, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
        try std.testing.expect(CountedLeafMeasure.calls <= 2 * depth + 8);
    }
}

test "column reverse baseline propagates from first source child" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const sibling_id: Id = @enumFromInt(1);
    const first_id: Id = @enumFromInt(2);
    const second_id: Id = @enumFromInt(3);
    const column_id: Id = @enumFromInt(4);
    const container_id: Id = @enumFromInt(5);

    try appendNode(&tree, sibling_id, container_id, fixedItem(50, 70));
    try appendNode(&tree, first_id, column_id, fixedItem(50, 30));
    try appendNode(&tree, second_id, column_id, fixedItem(50, 40));
    try appendNode(&tree, column_id, container_id, .{
        .display = .flex,
        .direction = .column_reverse,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 70 },
        },
    });
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .baseline,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(column_id, first_id);
    try tree.appendChild(column_id, second_id);
    try tree.appendChild(container_id, sibling_id);
    try tree.appendChild(container_id, column_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, sibling_id, .{ .x = 0, .y = 0, .w = 50, .h = 70 });
    try expectRelative(&tree, column_id, .{ .x = 50, .y = 0, .w = 50, .h = 70 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 40, .w = 50, .h = 30 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 0, .w = 50, .h = 40 });
}

test "wrap reverse baseline uses physical margins" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_child_id: Id = @enumFromInt(2);
    const second_id: Id = @enumFromInt(3);
    const container_id: Id = @enumFromInt(4);

    var first = fixedItem(20, 20);
    first.margin_inset = .{
        .top = .{ .length = 100 },
        .right = .{ .length = 0 },
        .bottom = .{ .length = 0 },
        .left = .{ .length = 0 },
    };
    var second: Style = .{
        .display = .flex,
        .direction = .column,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 20 },
            .height = .{ .length = 20 },
        },
    };
    second.margin_inset = .{
        .top = .{ .length = 0 },
        .right = .{ .length = 0 },
        .bottom = .{ .length = 50 },
        .left = .{ .length = 0 },
    };
    try appendNode(&tree, first_id, container_id, first);
    try appendNode(&tree, second_child_id, second_id, fixedItem(20, 10));
    try appendNode(&tree, second_id, container_id, second);
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .wrap = .wrap_reverse,
        .flex_wrap = .wrap_reverse,
        .@"align" = .baseline,
        .align_content = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 40 },
            .height = .{ .length = 180 },
        },
    });
    try tree.appendChild(second_id, second_child_id);
    try tree.appendChild(container_id, first_id);
    try tree.appendChild(container_id, second_id);

    try layoutContainer(&tree, container_id, .{ .width = 40, .height = 180 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 40, .h = 180 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 100, .w = 20, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 20, .y = 110, .w = 20, .h = 20 });
    try expectRelative(&tree, second_child_id, .{ .x = 0, .y = 0, .w = 20, .h = 10 });
}

test "baseline uses first in-flow child of a block item" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const sibling_id: Id = @enumFromInt(1);
    const block_child_id: Id = @enumFromInt(2);
    const block_id: Id = @enumFromInt(3);
    const container_id: Id = @enumFromInt(4);

    try appendNode(&tree, sibling_id, container_id, fixedItem(50, 50));
    try appendNode(&tree, block_child_id, block_id, fixedItem(50, 10));
    try appendNode(&tree, block_id, container_id, fixedItem(50, 50));
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .baseline,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(block_id, block_child_id);
    try tree.appendChild(container_id, sibling_id);
    try tree.appendChild(container_id, block_id);

    try dispatch.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 100 },
        .measure = null,
    });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, sibling_id, .{ .x = 0, .y = 0, .w = 50, .h = 50 });
    try expectRelative(&tree, block_id, .{ .x = 50, .y = 40, .w = 50, .h = 50 });
    try expectRelative(&tree, block_child_id, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
}

test "wrapped flex baseline includes align-content line offset" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const nested_id: Id = @enumFromInt(3);
    const sibling_id: Id = @enumFromInt(4);
    const container_id: Id = @enumFromInt(5);

    try appendNode(&tree, first_id, nested_id, fixedItem(100, 20));
    try appendNode(&tree, second_id, nested_id, fixedItem(100, 20));
    try appendNode(&tree, nested_id, container_id, .{
        .display = .flex,
        .direction = .row,
        .wrap = .wrap,
        .flex_wrap = .wrap,
        .@"align" = .start,
        .align_content = .end,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try appendNode(&tree, sibling_id, container_id, fixedItem(100, 80));
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .baseline,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 200 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(nested_id, first_id);
    try tree.appendChild(nested_id, second_id);
    try tree.appendChild(container_id, sibling_id);
    try tree.appendChild(container_id, nested_id);

    try layoutContainer(&tree, container_id, .{ .width = 200, .height = 100 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 200, .h = 100 });
    try expectRelative(&tree, sibling_id, .{ .x = 0, .y = 0, .w = 100, .h = 80 });
    try expectRelative(&tree, nested_id, .{ .x = 100, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 60, .w = 100, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 80, .w = 100, .h = 20 });
}

test "post-flexing column baseline propagates the grown first child" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const sibling_id: Id = @enumFromInt(1);
    const first_id: Id = @enumFromInt(2);
    const second_id: Id = @enumFromInt(3);
    const nested_id: Id = @enumFromInt(4);
    const container_id: Id = @enumFromInt(5);

    try appendNode(&tree, sibling_id, container_id, fixedItem(50, 80));
    var first = fixedItem(50, 0);
    first.grow = 1;
    try appendNode(&tree, first_id, nested_id, first);
    try appendNode(&tree, second_id, nested_id, fixedItem(50, 20));
    try appendNode(&tree, nested_id, container_id, .{
        .display = .flex,
        .direction = .column,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 100 },
        },
    });
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .baseline,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(nested_id, first_id);
    try tree.appendChild(nested_id, second_id);
    try tree.appendChild(container_id, sibling_id);
    try tree.appendChild(container_id, nested_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, sibling_id, .{ .x = 0, .y = 0, .w = 50, .h = 80 });
    try expectRelative(&tree, nested_id, .{ .x = 50, .y = 0, .w = 50, .h = 100 });
    try expectRelative(&tree, first_id, .{ .x = 0, .y = 0, .w = 50, .h = 80 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 80, .w = 50, .h = 20 });
}

test "wrap reverse column baseline uses the cross-start-most line" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const sibling_id: Id = @enumFromInt(1);
    const first_id: Id = @enumFromInt(2);
    const second_id: Id = @enumFromInt(3);
    const nested_id: Id = @enumFromInt(4);
    const container_id: Id = @enumFromInt(5);

    try appendNode(&tree, sibling_id, container_id, fixedItem(20, 20));
    try appendNode(&tree, first_id, nested_id, fixedItem(10, 20));
    try appendNode(&tree, second_id, nested_id, fixedItem(10, 10));
    try appendNode(&tree, nested_id, container_id, .{
        .display = .flex,
        .direction = .column,
        .wrap = .wrap_reverse,
        .flex_wrap = .wrap_reverse,
        .@"align" = .start,
        .align_content = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 20 },
            .height = .{ .length = 20 },
        },
    });
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .baseline,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 40 },
            .height = .{ .length = 40 },
        },
    });
    try tree.appendChild(nested_id, first_id);
    try tree.appendChild(nested_id, second_id);
    try tree.appendChild(container_id, sibling_id);
    try tree.appendChild(container_id, nested_id);

    try layoutContainer(&tree, container_id, .{ .width = 40, .height = 40 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 40, .h = 40 });
    try expectRelative(&tree, sibling_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
    try expectRelative(&tree, nested_id, .{ .x = 20, .y = 10, .w = 20, .h = 20 });
    try expectRelative(&tree, first_id, .{ .x = 10, .y = 0, .w = 10, .h = 20 });
    try expectRelative(&tree, second_id, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
}

test "paired insets size auto axis on absolute child" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    var absolute = fixedItem(10, 0);
    absolute.position = .absolute;
    absolute.size.height = .auto;
    absolute.inset = .{
        .top = .{ .percent = 0.1 },
        .right = .auto,
        .bottom = .{ .percent = 0.1 },
        .left = .auto,
    };
    try appendNode(&tree, absolute_id, container_id, absolute);
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 200 },
        },
    });
    try tree.appendChild(container_id, absolute_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 200 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 200 });
    try expectRelative(&tree, absolute_id, .{ .x = 0, .y = 20, .w = 10, .h = 160 });
}

test "percentage insets resolve against containing padding box" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    var absolute = fixedItem(10, 10);
    absolute.position = .absolute;
    absolute.inset = .{
        .top = .auto,
        .right = .auto,
        .bottom = .{ .percent = 0.5 },
        .left = .auto,
    };
    try appendNode(&tree, absolute_id, container_id, absolute);
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 200 },
        },
    });
    try tree.appendChild(container_id, absolute_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 200 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 200 });
    try expectRelative(&tree, absolute_id, .{ .x = 0, .y = 90, .w = 10, .h = 10 });
}

test "row reverse static position uses physical alignment" {
    const scenarios = [_]struct {
        justify: style.Justify,
        expected_x: f32,
    }{
        .{ .justify = .flex_start, .expected_x = 80 },
        .{ .justify = .start, .expected_x = 0 },
        .{ .justify = .end, .expected_x = 80 },
    };

    for (scenarios) |scenario| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const absolute_id: Id = @enumFromInt(1);
        const container_id: Id = @enumFromInt(2);

        var absolute = fixedItem(20, 20);
        absolute.position = .absolute;
        absolute.inset = .{
            .top = .auto,
            .right = .auto,
            .bottom = .auto,
            .left = .auto,
        };
        try appendNode(&tree, absolute_id, container_id, absolute);
        try appendNode(&tree, container_id, .root, .{
            .display = .flex,
            .direction = .row_reverse,
            .justify = scenario.justify,
            .@"align" = .start,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 20 },
            },
        });
        try tree.appendChild(container_id, absolute_id);

        try layoutContainer(&tree, container_id, .{ .width = 100, .height = 20 });

        try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
        try expectRelative(
            &tree,
            absolute_id,
            .{ .x = scenario.expected_x, .y = 0, .w = 20, .h = 20 },
        );
    }
}

test "wrap reverse static cross alignment uses physical start" {
    const scenarios = [_]style.AlignSelf{ .start, .baseline };

    for (scenarios) |align_self| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const absolute_id: Id = @enumFromInt(1);
        const container_id: Id = @enumFromInt(2);

        var absolute = fixedItem(20, 20);
        absolute.position = .absolute;
        absolute.align_self = align_self;
        absolute.inset = .{
            .top = .auto,
            .right = .auto,
            .bottom = .auto,
            .left = .auto,
        };
        try appendNode(&tree, absolute_id, container_id, absolute);
        try appendNode(&tree, container_id, .root, .{
            .display = .flex,
            .direction = .row,
            .wrap = .wrap_reverse,
            .flex_wrap = .wrap_reverse,
            .justify = .start,
            .@"align" = .end,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 20 },
                .height = .{ .length = 100 },
            },
        });
        try tree.appendChild(container_id, absolute_id);

        try layoutContainer(&tree, container_id, .{ .width = 20, .height = 100 });

        try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 20, .h = 100 });
        try expectRelative(&tree, absolute_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
    }
}

test "absolute child auto margins distribute within available inset space" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    var absolute = fixedItem(20, 20);
    absolute.position = .absolute;
    absolute.inset = .{
        .top = .{ .length = 0 },
        .right = .{ .length = 0 },
        .bottom = .{ .length = 0 },
        .left = .{ .length = 0 },
    };
    absolute.margin_inset = .{
        .top = .{ .length = 0 },
        .right = .auto,
        .bottom = .{ .length = 0 },
        .left = .auto,
    };
    try appendNode(&tree, absolute_id, container_id, absolute);
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(container_id, absolute_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, absolute_id, .{ .x = 40, .y = 0, .w = 20, .h = 20 });
}

test "paired horizontal insets respect absolute max width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    var absolute = fixedItem(0, 20);
    absolute.position = .absolute;
    absolute.size.width = .auto;
    absolute.max_size.width = .{ .length = 40 };
    absolute.inset = .{
        .top = .{ .length = 0 },
        .right = .{ .length = 10 },
        .bottom = .auto,
        .left = .{ .length = 10 },
    };
    try appendNode(&tree, absolute_id, container_id, absolute);
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(container_id, absolute_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, absolute_id, .{ .x = 10, .y = 0, .w = 40, .h = 20 });
}

test "paired absolute insets defer auto height to aspect ratio" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    var absolute = fixedItem(0, 0);
    absolute.position = .absolute;
    absolute.size = .{ .width = .auto, .height = .auto };
    absolute.aspect_ratio = 2;
    absolute.inset = .{
        .top = .{ .length = 10 },
        .right = .{ .length = 10 },
        .bottom = .{ .length = 10 },
        .left = .{ .length = 10 },
    };
    try appendNode(&tree, absolute_id, container_id, absolute);
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(container_id, absolute_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, absolute_id, .{ .x = 10, .y = 10, .w = 80, .h = 40 });
}

test "padding box inset writes a content frame relative rectangle" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    var absolute = fixedItem(20, 20);
    absolute.position = .absolute;
    absolute.inset = .{
        .top = .{ .length = 0 },
        .right = .auto,
        .bottom = .auto,
        .left = .{ .length = 0 },
    };
    try appendNode(&tree, absolute_id, container_id, absolute);
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
        .border = .{ .top = 10, .right = 10, .bottom = 10, .left = 10 },
        .padding = .{ .top = 10, .right = 10, .bottom = 10, .left = 10 },
        .border_inset = .{
            .top = .{ .length = 10 },
            .right = .{ .length = 10 },
            .bottom = .{ .length = 10 },
            .left = .{ .length = 10 },
        },
        .padding_inset = .{
            .top = .{ .length = 10 },
            .right = .{ .length = 10 },
            .bottom = .{ .length = 10 },
            .left = .{ .length = 10 },
        },
    });
    try tree.appendChild(container_id, absolute_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, absolute_id, .{ .x = -10, .y = -10, .w = 20, .h = 20 });
    const expected_origin = [2]f32{ 10, 10 };
    try std.testing.expectEqual(expected_origin, widget.absoluteBorderOrigin(&tree, absolute_id));
    try expectRect(
        .{ .x = 10, .y = 10, .w = 20, .h = 20 },
        widget.absoluteRect(&tree, absolute_id),
    );
}

test "absolute static center uses the flex content box" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    var absolute = fixedItem(20, 20);
    absolute.position = .absolute;
    absolute.inset = .{
        .top = .auto,
        .right = .auto,
        .bottom = .auto,
        .left = .auto,
    };
    try appendNode(&tree, absolute_id, container_id, absolute);
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .justify = .center,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
        .padding = .{ .right = 10, .left = 10 },
        .padding_inset = .{
            .top = .{ .length = 0 },
            .right = .{ .length = 10 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 10 },
        },
    });
    try tree.appendChild(container_id, absolute_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, absolute_id, .{ .x = 30, .y = 0, .w = 20, .h = 20 });
}

test "absolute safe end remains end during main axis overflow" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const absolute_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    var absolute = fixedItem(200, 20);
    absolute.position = .absolute;
    absolute.inset = .{
        .top = .auto,
        .right = .auto,
        .bottom = .auto,
        .left = .auto,
    };
    try appendNode(&tree, absolute_id, container_id, absolute);
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .justify = .safe_end,
        .@"align" = .start,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(container_id, absolute_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, absolute_id, .{ .x = -100, .y = 0, .w = 200, .h = 20 });
}

test "row cross axis self start ignores inline direction mismatch" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const container_id: Id = @enumFromInt(2);

    var child = fixedItem(20, 20);
    child.writing_direction = .rtl;
    child.align_self = .self_start;
    try appendNode(&tree, child_id, container_id, child);
    try appendNode(&tree, container_id, .root, .{
        .display = .flex,
        .direction = .row,
        .writing_direction = .ltr,
        .justify = .start,
        .@"align" = .end,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 100 },
        },
    });
    try tree.appendChild(container_id, child_id);

    try layoutContainer(&tree, container_id, .{ .width = 100, .height = 100 });

    try expectRelative(&tree, container_id, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expectRelative(&tree, child_id, .{ .x = 0, .y = 0, .w = 20, .h = 20 });
}
