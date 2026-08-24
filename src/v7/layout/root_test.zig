//! Specifies the checked layout facade before the production module exists.

const std = @import("std");
const Id = @import("../id.zig").Id;
const style = @import("../style.zig");
const widget = @import("../widget.zig");
const layout = @import("root.zig");

fn layoutTreeMeasure(text: []const u8, _: f32, _: u8) widget.Size {
    return .{
        .width = @floatFromInt(text.len * 5),
        .height = 12,
    };
}

test "layoutTree preserves legacy relative column geometry" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try tree.appendNode(.{
        .id = first_id,
        .kind = .{ .label = .{ .text = "one" } },
        .parent = root_id,
    });
    try tree.appendNode(.{
        .id = second_id,
        .kind = .{ .label = .{ .text = "second" } },
        .parent = root_id,
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{ .gap = 4 } },
        .parent = .root,
        .style = .{ .@"align" = .start, .gap = 4 },
    });
    try tree.appendChild(root_id, first_id);
    try tree.appendChild(root_id, second_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 80 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 100, .h = 28 },
        tree.node(root_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 15, .h = 12 },
        tree.node(first_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 16, .w = 30, .h = 12 },
        tree.node(second_id).?.rect,
    );
}

test "layoutTree dispatches a single flow root through block float layout" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const float_id: Id = @enumFromInt(1);
    const normal_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);

    try tree.appendNode(.{
        .id = float_id,
        .kind = .{ .column = .{} },
        .parent = root_id,
        .style = .{
            .display = .block,
            .float = .left,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .length = 30 }, .height = .{ .length = 20 } },
        },
    });
    try tree.appendNode(.{
        .id = normal_id,
        .kind = .{ .column = .{} },
        .parent = root_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .length = 40 }, .height = .{ .length = 10 } },
        },
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .flow_root,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .length = 100 }, .height = .auto },
        },
    });
    try tree.appendChild(root_id, float_id);
    try tree.appendChild(root_id, normal_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 100 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 30, .h = 20 },
        tree.node(float_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 40, .h = 10 },
        tree.node(normal_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 100, .h = 20 },
        tree.node(root_id).?.rect,
    );
}

test "layoutTree keeps a leaf root on the legacy measurement path" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: Id = @enumFromInt(1);
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .label = .{ .text = "leaf" } },
        .parent = .root,
        .style = .{ .display = .flow_root },
    });

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 100 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 100, .h = 12 },
        tree.node(root_id).?.rect,
    );
}

test "layoutTree keeps nested block trees on the legacy path" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const label_id: Id = @enumFromInt(1);
    const nested_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try tree.appendNode(.{
        .id = label_id,
        .kind = .{ .label = .{ .text = "nested" } },
        .parent = nested_id,
        .style = .{ .display = .block },
    });
    try tree.appendNode(.{
        .id = nested_id,
        .kind = .{ .column = .{} },
        .parent = root_id,
        .style = .{ .display = .block },
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .flow_root,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .length = 100 }, .height = .auto },
        },
    });
    try tree.appendChild(nested_id, label_id);
    try tree.appendChild(root_id, nested_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 100 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 100, .h = 12 },
        tree.node(label_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 100, .h = 12 },
        tree.node(nested_id).?.rect,
    );
}

test "layoutTree keeps scroll roots on the legacy offset path" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var scroll_state: widget.ScrollState = .{};
    const child_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);
    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .spacer = .{} },
        .parent = root_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 20 } },
        },
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .flow_root,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 10 } },
        },
        .scroll = .{ .state = &scroll_state, .axis = .vertical },
    });
    try tree.appendChild(root_id, child_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 100 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual([2]f32{ 0, 10 }, scroll_state.max_offset);
}

test "layoutTree falls back for a direct auto-sized slider" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var value: f32 = 0.5;
    const slider_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);
    try tree.appendNode(.{
        .id = slider_id,
        .kind = .{ .slider = .{
            .label = "volume",
            .value = &value,
            .min = 0,
            .max = 1,
        } },
        .parent = root_id,
        .style = .{ .display = .block },
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .flow_root,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 100 },
            },
        },
    });
    try tree.appendChild(root_id, slider_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 100 },
        .measure = layoutTreeMeasure,
    });

    const slider_rect = tree.node(slider_id).?.rect;
    try std.testing.expect(slider_rect.w > 0);
    try std.testing.expect(slider_rect.h > 0);
}

test "layoutTree keeps capped direct labels on the legacy path" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const label_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);
    try tree.appendNode(.{
        .id = label_id,
        .kind = .{ .label = .{ .text = "too wide" } },
        .parent = root_id,
        .style = .{ .display = .block, .position = .absolute },
        .text_overflow = .clip,
        .text_max_width = 20,
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .flow_root,
            .@"align" = .start,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 100 },
            },
        },
    });
    try tree.appendChild(root_id, label_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 100 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(@as(f32, 20), tree.node(label_id).?.rect.w);
}

test "layoutTree preserves legacy root flex-item growth" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);
    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .column = .{} },
        .parent = root_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 10 },
                .height = .{ .length = 10 },
            },
        },
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .flow_root,
            .grow = 1,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .length = 100 }, .height = .auto },
        },
    });
    try tree.appendChild(root_id, child_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 100 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(@as(f32, 100), tree.node(root_id).?.rect.h);
}

test "layoutTree dispatches an eligible flex root through modular flex" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try tree.appendNode(.{
        .id = first_id,
        .kind = .{ .column = .{} },
        .parent = root_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 20 },
                .height = .{ .length = 10 },
            },
        },
    });
    try tree.appendNode(.{
        .id = second_id,
        .kind = .{ .column = .{} },
        .parent = root_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 20 },
                .height = .{ .length = 10 },
            },
        },
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .row = .{} },
        .parent = .root,
        .style = .{
            .display = .flex,
            .direction = .row,
            .justify = .space_evenly,
            .@"align" = .start,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 20 },
            },
        },
    });
    try tree.appendChild(root_id, first_id);
    try tree.appendChild(root_id, second_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 20 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(
        widget.Rect{ .x = 20, .y = 0, .w = 20, .h = 10 },
        tree.node(first_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 60, .y = 0, .w = 20, .h = 10 },
        tree.node(second_id).?.rect,
    );
}

test "layoutTree falls back for a hidden unsupported grid subtree" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: Id = @enumFromInt(1);
    const grid_id: Id = @enumFromInt(2);
    const hidden_id: Id = @enumFromInt(3);
    const root_id: Id = @enumFromInt(4);
    try tree.appendNode(.{
        .id = leaf_id,
        .kind = .{ .label = .{ .text = "hidden" } },
        .parent = grid_id,
        .style = .{ .display = .block },
    });
    try tree.appendNode(.{
        .id = grid_id,
        .kind = .{ .column = .{} },
        .parent = hidden_id,
        .style = .{ .display = .grid },
    });
    try tree.appendNode(.{
        .id = hidden_id,
        .kind = .{ .column = .{} },
        .parent = root_id,
        .style = .{ .display = .none },
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .row = .{} },
        .parent = .root,
        .style = .{
            .display = .flex,
            .direction = .row,
            .@"align" = .start,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 20 },
            },
        },
    });
    try tree.appendChild(grid_id, leaf_id);
    try tree.appendChild(hidden_id, grid_id);
    try tree.appendChild(root_id, hidden_id);

    tree.node(hidden_id).?.rect = .{ .x = 1, .y = 2, .w = 30, .h = 40 };
    tree.node(grid_id).?.rect = .{ .x = 3, .y = 4, .w = 20, .h = 10 };
    tree.node(leaf_id).?.rect = .{ .x = 5, .y = 6, .w = 10, .h = 8 };

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 20 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(widget.Rect{}, tree.node(hidden_id).?.rect);
    try std.testing.expectEqual(widget.Rect{}, tree.node(grid_id).?.rect);
    try std.testing.expectEqual(widget.Rect{}, tree.node(leaf_id).?.rect);
}

test "layoutTree dispatches an eligible grid root through modular grid" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    const columns = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };
    const rows = [_]style.GridTrack{.{ .fixed = 10 }};
    try tree.appendNode(.{
        .id = first_id,
        .kind = .{ .spacer = .{} },
        .parent = root_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 20 },
                .height = .{ .length = 10 },
            },
        },
    });
    try tree.appendNode(.{
        .id = second_id,
        .kind = .{ .spacer = .{} },
        .parent = root_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 20 },
                .height = .{ .length = 10 },
            },
        },
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .grid,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 40 },
                .height = .{ .length = 10 },
            },
            .grid_template_columns = columns[0..],
            .grid_template_rows = rows[0..],
        },
    });
    try tree.appendChild(root_id, first_id);
    try tree.appendChild(root_id, second_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 40, .height = 10 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 20, .h = 10 },
        tree.node(first_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 20, .y = 0, .w = 20, .h = 10 },
        tree.node(second_id).?.rect,
    );
}

test "layoutTree dispatches a mixed fixed tree through the public facade" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: Id = @enumFromInt(1);
    const flex_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try tree.appendNode(.{
        .id = leaf_id,
        .kind = .{ .spacer = .{} },
        .parent = flex_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 12 },
                .height = .{ .length = 8 },
            },
        },
    });
    try tree.appendNode(.{
        .id = flex_id,
        .kind = .{ .row = .{} },
        .parent = root_id,
        .style = .{
            .display = .flex,
            .direction = .row,
            .@"align" = .start,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 40 },
                .height = .{ .length = 20 },
            },
        },
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .flow_root,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 80 },
                .height = .{ .length = 30 },
            },
        },
    });
    try tree.appendChild(flex_id, leaf_id);
    try tree.appendChild(root_id, flex_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 80, .height = 30 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 40, .h = 20 },
        tree.node(flex_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 12, .h = 8 },
        tree.node(leaf_id).?.rect,
    );
}

test "layoutTree dispatches a mixed auto-height block root" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: Id = @enumFromInt(1);
    const flex_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    try tree.appendNode(.{
        .id = leaf_id,
        .kind = .{ .spacer = .{} },
        .parent = flex_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 12 },
                .height = .{ .length = 8 },
            },
        },
    });
    try tree.appendNode(.{
        .id = flex_id,
        .kind = .{ .row = .{} },
        .parent = root_id,
        .style = .{
            .display = .flex,
            .direction = .row,
            .@"align" = .start,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 40 },
                .height = .{ .length = 20 },
            },
        },
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .flow_root,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 80 },
                .height = .auto,
            },
        },
    });
    try tree.appendChild(flex_id, leaf_id);
    try tree.appendChild(root_id, flex_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 80, .height = 30 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 80, .h = 20 },
        tree.node(root_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 40, .h = 20 },
        tree.node(flex_id).?.rect,
    );
}

test "layoutTree rejects non-finite available width" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expectError(
        error.InvalidStyle,
        layout.layoutTree(&tree, .{
            .allocator = std.testing.allocator,
            .available = .{ .width = std.math.inf(f32), .height = 80 },
            .measure = layoutTreeMeasure,
        }),
    );
}
