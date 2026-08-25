//! Specifies the direct-tree contract for the modular flex layout engine.

const std = @import("std");
const Id = @import("../id.zig").Id;
const style = @import("../style.zig");
const widget = @import("../widget.zig");
const flex = @import("flex.zig");

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
    try expectRelative(&tree, absolute_id, .{ .x = 7, .y = 9, .w = 10, .h = 8 });
    try expectRect(.{ .x = 10, .y = 15, .w = 20, .h = 10 }, widget.absoluteRect(&tree, first_id));
    try expectRect(.{ .x = 84, .y = 15, .w = 20, .h = 10 }, widget.absoluteRect(&tree, second_id));
    try expectRect(
        .{ .x = 17, .y = 24, .w = 10, .h = 8 },
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
