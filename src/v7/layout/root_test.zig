//! Specifies the checked layout facade before the production module exists.

const std = @import("std");
const Id = @import("../id.zig").Id;
const style = @import("../style.zig");
const widget = @import("../widget.zig");
const layout = @import("root.zig");

fn layoutTreeMeasure(text: []const u8, _: layout.MeasureInput) widget.Size {
    return .{
        .width = @floatFromInt(text.len * 5),
        .height = 12,
    };
}

test "layoutTree preserves relative column geometry" {
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
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{ .@"align" = .start, .gap = .{ .length = 4 } },
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

test "layoutTree measures a leaf root intrinsically" {
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

test "layoutTree routes nested block trees" {
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

test "layoutTree preserves scroll root offsets" {
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

test "layoutTree uses visible slider label height" {
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

    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 100, .h = 12 },
        tree.node(slider_id).?.rect,
    );
}

test "layoutTree caps direct label intrinsic width" {
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

test "layoutTree preserves root flex-item growth" {
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

test "layoutTree clears hidden grid subtree geometry" {
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

test "layoutTree dispatches an eligible multi-root forest through the facade" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_leaf_id: Id = @enumFromInt(1);
    const first_flex_id: Id = @enumFromInt(2);
    const first_root_id: Id = @enumFromInt(3);
    const second_leaf_id: Id = @enumFromInt(4);
    const second_flex_id: Id = @enumFromInt(5);
    const second_root_id: Id = @enumFromInt(6);
    for ([_]struct {
        id: Id,
        parent: Id,
        kind: widget.WidgetKind,
        node_style: style.Style,
    }{
        .{
            .id = first_leaf_id,
            .parent = first_flex_id,
            .kind = .{ .spacer = .{} },
            .node_style = .{
                .display = .block,
                .box_sizing = .border_box,
                .size = .{
                    .width = .{ .length = 12 },
                    .height = .{ .length = 8 },
                },
            },
        },
        .{
            .id = first_flex_id,
            .parent = first_root_id,
            .kind = .{ .row = .{} },
            .node_style = .{
                .display = .flex,
                .direction = .row,
                .@"align" = .start,
                .box_sizing = .border_box,
                .size = .{
                    .width = .{ .length = 40 },
                    .height = .{ .length = 10 },
                },
            },
        },
        .{
            .id = first_root_id,
            .parent = .root,
            .kind = .{ .column = .{} },
            .node_style = .{
                .display = .flow_root,
                .box_sizing = .border_box,
                .size = .{
                    .width = .{ .length = 100 },
                    .height = .{ .length = 20 },
                },
            },
        },
        .{
            .id = second_leaf_id,
            .parent = second_flex_id,
            .kind = .{ .spacer = .{} },
            .node_style = .{
                .display = .block,
                .box_sizing = .border_box,
                .size = .{
                    .width = .{ .length = 12 },
                    .height = .{ .length = 8 },
                },
            },
        },
        .{
            .id = second_flex_id,
            .parent = second_root_id,
            .kind = .{ .row = .{} },
            .node_style = .{
                .display = .flex,
                .direction = .row,
                .@"align" = .start,
                .box_sizing = .border_box,
                .size = .{
                    .width = .{ .length = 40 },
                    .height = .{ .length = 10 },
                },
            },
        },
        .{
            .id = second_root_id,
            .parent = .root,
            .kind = .{ .column = .{} },
            .node_style = .{
                .display = .flow_root,
                .box_sizing = .border_box,
                .size = .{
                    .width = .{ .length = 100 },
                    .height = .{ .length = 20 },
                },
            },
        },
    }) |entry| {
        try tree.appendNode(.{
            .id = entry.id,
            .kind = entry.kind,
            .parent = entry.parent,
            .style = entry.node_style,
        });
    }
    try tree.appendChild(first_flex_id, first_leaf_id);
    try tree.appendChild(first_root_id, first_flex_id);
    try tree.appendChild(second_flex_id, second_leaf_id);
    try tree.appendChild(second_root_id, second_flex_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 100 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 100, .h = 20 },
        tree.node(first_root_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 20, .w = 100, .h = 20 },
        tree.node(second_root_id).?.rect,
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

test "layoutTree reserves RTL vertical scrollbar gutter" {
    // Exercise RTL scrollbar gutter sizing through the public facade.
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
            .size = .{
                .width = .{ .percent = 1 },
                .height = .auto,
            },
        },
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .flow_root,
            .writing_direction = .rtl,
            .@"align" = .start,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 100 },
            },
            .overflow = .{ .width = .visible, .height = .scroll },
            .scrollbar_width = 15,
        },
        .scroll = .{ .state = &scroll_state, .axis = .vertical },
    });
    try tree.appendChild(root_id, child_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 100 },
        .measure = layoutTreeMeasure,
    });

    const root_rect = tree.node(root_id).?.rect;
    const child_rect = tree.node(child_id).?.rect;
    const child_absolute = widget.absoluteRect(&tree, child_id);
    try std.testing.expectEqual(@as(f32, 100), root_rect.w);
    try std.testing.expectEqual(@as(f32, 0), child_rect.x);
    try std.testing.expectEqual(@as(f32, 85), child_rect.w);
    try std.testing.expectEqual(@as(f32, 15), child_absolute.x);
}

test "layoutTree grows capped minmax track to natural width" {
    // Exercise capped minmax intrinsic track growth through the public facade.
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var scroll_state: widget.ScrollState = .{};
    const child_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);
    const columns = [_]style.GridTrack{.{ .minmax = .{
        .min = .{ .fixed = 10 },
        .max = .{ .fit_content = .{ .percent = 0.5 } },
    } }};
    const rows = [_]style.GridTrack{.{ .fixed = 12 }};

    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .label = .{ .text = "12345678" } },
        .parent = root_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .auto, .height = .auto },
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
                .width = .{ .length = 100 },
                .height = .{ .length = 12 },
            },
            .grid_template_columns = columns[0..],
            .grid_template_rows = rows[0..],
        },
        .scroll = .{ .state = &scroll_state, .axis = .vertical },
    });
    try tree.appendChild(root_id, child_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 12 },
        .measure = layoutTreeMeasure,
    });

    const root_rect = tree.node(root_id).?.rect;
    const child_rect = tree.node(child_id).?.rect;
    try std.testing.expectEqual(@as(f32, 100), root_rect.w);
    try std.testing.expectEqual(@as(f32, 40), child_rect.w);
    try std.testing.expect(child_rect.w <= 50);
}

test "layoutTree floors fit-content maximum at fixed minimum" {
    // The fixed minimum must win when the percentage fit-content cap resolves smaller.
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var scroll_state: widget.ScrollState = .{};
    const child_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);
    const columns = [_]style.GridTrack{.{ .minmax = .{
        .min = .{ .fixed = 60 },
        .max = .{ .fit_content = .{ .percent = 0.5 } },
    } }};
    const rows = [_]style.GridTrack{.{ .fixed = 12 }};

    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .label = .{ .text = "12345678" } },
        .parent = root_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .auto, .height = .auto },
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
                .width = .{ .length = 100 },
                .height = .{ .length = 12 },
            },
            .grid_template_columns = columns[0..],
            .grid_template_rows = rows[0..],
        },
        .scroll = .{ .state = &scroll_state, .axis = .vertical },
    });
    try tree.appendChild(root_id, child_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 12 },
        .measure = layoutTreeMeasure,
    });

    const root_rect = tree.node(root_id).?.rect;
    const child_rect = tree.node(child_id).?.rect;
    try std.testing.expectEqual(@as(f32, 100), root_rect.w);
    try std.testing.expectEqual(@as(f32, 60), child_rect.w);
}

test "layoutTree rejects invalid scrollbar width" {
    // The public facade must validate styles before layout.
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var scroll_state: widget.ScrollState = .{};
    const root_id: Id = @enumFromInt(1);
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .flow_root,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 20 },
            },
            .overflow = .{ .width = .visible, .height = .scroll },
            .scrollbar_width = -1,
        },
        .scroll = .{ .state = &scroll_state, .axis = .vertical },
    });

    try std.testing.expectError(
        error.InvalidStyle,
        layout.layoutTree(&tree, .{
            .allocator = std.testing.allocator,
            .available = .{ .width = 100, .height = 20 },
            .measure = layoutTreeMeasure,
        }),
    );
}

test "layoutTree keeps content-box scrollbar outer width fixed" {
    // The gutter reduces content space without increasing a specified content-box width.
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
            .size = .{
                .width = .{ .percent = 1 },
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
            .box_sizing = .content_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 20 },
            },
            .overflow = .{ .width = .visible, .height = .scroll },
            .scrollbar_width = 15,
        },
        .scroll = .{ .state = &scroll_state, .axis = .vertical },
    });
    try tree.appendChild(root_id, child_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 20 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(@as(f32, 100), tree.node(root_id).?.rect.w);
    try std.testing.expectEqual(@as(f32, 85), tree.node(child_id).?.rect.w);
}

test "layoutTree keeps flex content-box scrollbar outer width fixed" {
    // Exercise growing percentage sizing through the public facade.
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
            .grow = 1,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .percent = 1 },
                .height = .auto,
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
            .@"align" = .stretch,
            .box_sizing = .content_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 20 },
            },
            .overflow = .{ .width = .visible, .height = .scroll },
            .scrollbar_width = 15,
        },
        .scroll = .{ .state = &scroll_state, .axis = .vertical },
    });
    try tree.appendChild(root_id, child_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 20 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(@as(f32, 100), tree.node(root_id).?.rect.w);
    try std.testing.expectEqual(@as(f32, 85), tree.node(child_id).?.rect.w);
}

test "layoutTree keeps grid content-box scrollbar outer width fixed" {
    // Exercise fractional track sizing through the public facade.
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var scroll_state: widget.ScrollState = .{};
    const child_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);
    const columns = [_]style.GridTrack{.{ .fr = 1 }};
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};

    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .spacer = .{} },
        .parent = root_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .auto, .height = .auto },
        },
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .grid,
            .box_sizing = .content_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 20 },
            },
            .grid_template_columns = columns[0..],
            .grid_template_rows = rows[0..],
            .overflow = .{ .width = .visible, .height = .scroll },
            .scrollbar_width = 15,
        },
        .scroll = .{ .state = &scroll_state, .axis = .vertical },
    });
    try tree.appendChild(root_id, child_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 20 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(@as(f32, 100), tree.node(root_id).?.rect.w);
    try std.testing.expectEqual(@as(f32, 85), tree.node(child_id).?.rect.w);
}

test "layoutTree contains scrollbar gutter inside content-box flex basis" {
    // Reserve the scrollbar inside the specified outer flex basis, not in addition to it.
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
            .grow = 0,
            .shrink = 0,
            .flex_basis = .{ .length = 20 },
            .box_sizing = .content_box,
            .size = .{
                .width = .auto,
                .height = .{ .length = 20 },
            },
            .overflow = .{ .width = .visible, .height = .scroll },
            .scrollbar_width = 15,
        },
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
        .scroll = .{ .state = &scroll_state, .axis = .vertical },
    });
    try tree.appendChild(root_id, child_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 20 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(@as(f32, 100), tree.node(root_id).?.rect.w);
    try std.testing.expectEqual(@as(f32, 20), tree.node(child_id).?.rect.w);
}

test "layoutTree preserves padded nested scroll grid content origins" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var grid_scroll_state: widget.ScrollState = .{};
    const first_leaf_id: Id = @enumFromInt(1);
    const second_leaf_id: Id = @enumFromInt(2);
    const grid_id: Id = @enumFromInt(3);
    const flex_id: Id = @enumFromInt(4);
    const root_id: Id = @enumFromInt(5);
    const columns = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };
    const rows = [_]style.GridTrack{.{ .fixed = 100 }};

    try tree.appendNode(.{
        .id = first_leaf_id,
        .kind = .{ .spacer = .{} },
        .parent = grid_id,
        .style = .{
            .display = .block,
            .writing_direction = .rtl,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 10 },
                .height = .{ .length = 100 },
            },
            .grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } },
            .grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } },
        },
    });
    try tree.appendNode(.{
        .id = second_leaf_id,
        .kind = .{ .spacer = .{} },
        .parent = grid_id,
        .style = .{
            .display = .block,
            .writing_direction = .rtl,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 10 },
                .height = .{ .length = 100 },
            },
            .grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } },
            .grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } },
            .grid_justify_self = .start,
        },
    });
    try tree.appendNode(.{
        .id = grid_id,
        .kind = .{ .column = .{} },
        .parent = flex_id,
        .style = .{
            .display = .grid,
            .writing_direction = .rtl,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 110 },
                .height = .{ .length = 60 },
            },
            .border_inset = .{
                .top = .{ .length = 2 },
                .right = .{ .length = 2 },
                .bottom = .{ .length = 2 },
                .left = .{ .length = 2 },
            },
            .padding_inset = .{
                .top = .{ .length = 3 },
                .right = .{ .length = 3 },
                .bottom = .{ .length = 3 },
                .left = .{ .length = 3 },
            },
            .grid_template_columns = columns[0..],
            .grid_template_rows = rows[0..],
            .grid_justify_content = .center,
            .grid_align_content = .start,
            .grid_justify_items = .end,
            .grid_align_items = .start,
            .overflow = .{ .width = .visible, .height = .scroll },
        },
        .scroll = .{ .state = &grid_scroll_state, .axis = .vertical },
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
                .width = .{ .length = 130 },
                .height = .{ .length = 80 },
            },
            .border_inset = .{
                .top = .{ .length = 1 },
                .right = .{ .length = 1 },
                .bottom = .{ .length = 1 },
                .left = .{ .length = 1 },
            },
            .padding_inset = .{
                .top = .{ .length = 4 },
                .right = .{ .length = 4 },
                .bottom = .{ .length = 4 },
                .left = .{ .length = 4 },
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
                .width = .{ .length = 150 },
                .height = .{ .length = 100 },
            },
            .border_inset = .{
                .top = .{ .length = 2 },
                .right = .{ .length = 2 },
                .bottom = .{ .length = 2 },
                .left = .{ .length = 2 },
            },
            .padding_inset = .{
                .top = .{ .length = 5 },
                .right = .{ .length = 5 },
                .bottom = .{ .length = 5 },
                .left = .{ .length = 5 },
            },
        },
    });
    try tree.appendChild(grid_id, first_leaf_id);
    try tree.appendChild(grid_id, second_leaf_id);
    try tree.appendChild(flex_id, grid_id);
    try tree.appendChild(root_id, flex_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 150, .height = 100 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 130, .h = 80 },
        tree.node(flex_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 110, .h = 60 },
        tree.node(grid_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 50, .y = 0, .w = 10, .h = 100 },
        tree.node(first_leaf_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 40, .y = 0, .w = 10, .h = 100 },
        tree.node(second_leaf_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 67, .y = 17, .w = 10, .h = 100 },
        widget.absoluteRect(&tree, first_leaf_id),
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 57, .y = 17, .w = 10, .h = 100 },
        widget.absoluteRect(&tree, second_leaf_id),
    );
    try std.testing.expectEqual([2]f32{ 0, 50 }, grid_scroll_state.max_offset);
}

test "layoutTree measures negative RTL flex overflow from both border edges" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var scroll_state: widget.ScrollState = .{};
    const child_id: Id = @enumFromInt(1);
    const root_id: Id = @enumFromInt(2);

    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .column = .{} },
        .parent = root_id,
        .style = .{
            .display = .block,
            .writing_direction = .rtl,
            .shrink = 0,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 100 },
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
            .writing_direction = .rtl,
            .justify = .start,
            .@"align" = .start,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 50 },
                .height = .{ .length = 50 },
            },
            .overflow = .{ .width = .scroll, .height = .scroll },
            .scrollbar_width = 15,
        },
        .scroll = .{ .state = &scroll_state, .axis = .both },
    });
    try tree.appendChild(root_id, child_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 50, .height = 50 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 50, .h = 50 },
        tree.node(root_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = -65, .y = 0, .w = 100, .h = 100 },
        tree.node(child_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = -50, .y = 0, .w = 100, .h = 100 },
        widget.absoluteRect(&tree, child_id),
    );
    try std.testing.expectEqual([2]f32{ 65, 65 }, scroll_state.max_offset);
}

test "layoutTree propagates visible nested overflow but clips hidden descendants" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var scroll_state: widget.ScrollState = .{};
    const visible_leaf_id: Id = @enumFromInt(1);
    const visible_container_id: Id = @enumFromInt(2);
    const hidden_leaf_id: Id = @enumFromInt(3);
    const hidden_container_id: Id = @enumFromInt(4);
    const root_id: Id = @enumFromInt(5);

    try tree.appendNode(.{
        .id = visible_leaf_id,
        .kind = .{ .spacer = .{} },
        .parent = visible_container_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 100 },
                .height = .{ .length = 10 },
            },
        },
    });
    try tree.appendNode(.{
        .id = visible_container_id,
        .kind = .{ .column = .{} },
        .parent = root_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 30 },
                .height = .{ .length = 20 },
            },
            .overflow = .{ .width = .visible, .height = .visible },
        },
    });
    try tree.appendNode(.{
        .id = hidden_leaf_id,
        .kind = .{ .spacer = .{} },
        .parent = hidden_container_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 120 },
                .height = .{ .length = 10 },
            },
        },
    });
    try tree.appendNode(.{
        .id = hidden_container_id,
        .kind = .{ .column = .{} },
        .parent = root_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 30 },
                .height = .{ .length = 20 },
            },
            .margin_inset = .{
                .top = .{ .length = 0 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 40 },
            },
            .overflow = .{ .width = .hidden, .height = .hidden },
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
                .height = .{ .length = 60 },
            },
            .overflow = .{ .width = .scroll, .height = .visible },
        },
        .scroll = .{ .state = &scroll_state, .axis = .horizontal },
    });
    try tree.appendChild(visible_container_id, visible_leaf_id);
    try tree.appendChild(hidden_container_id, hidden_leaf_id);
    try tree.appendChild(root_id, visible_container_id);
    try tree.appendChild(root_id, hidden_container_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 80, .height = 60 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 80, .h = 60 },
        tree.node(root_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 30, .h = 20 },
        tree.node(visible_container_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 40, .y = 20, .w = 30, .h = 20 },
        tree.node(hidden_container_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 100, .h = 10 },
        widget.absoluteRect(&tree, visible_leaf_id),
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 40, .y = 20, .w = 120, .h = 10 },
        widget.absoluteRect(&tree, hidden_leaf_id),
    );
    try std.testing.expectEqual([2]f32{ 20, 0 }, scroll_state.max_offset);
}

test "layoutTree retains measured content on clipped scroll leaves" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var hidden_state: widget.ScrollState = .{};
    var scroll_state: widget.ScrollState = .{};
    var root_state: widget.ScrollState = .{};
    const hidden_leaf_id: Id = @enumFromInt(1);
    const scroll_leaf_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    const text = "12345678901234567890";

    try tree.appendNode(.{
        .id = hidden_leaf_id,
        .kind = .{ .label = .{ .text = text } },
        .parent = root_id,
        .style = .{
            .display = .block,
            .shrink = 0,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 50 },
                .height = .{ .length = 20 },
            },
            .overflow = .{ .width = .hidden, .height = .hidden },
        },
        .scroll = .{ .state = &hidden_state, .axis = .horizontal },
    });
    try tree.appendNode(.{
        .id = scroll_leaf_id,
        .kind = .{ .label = .{ .text = text } },
        .parent = root_id,
        .style = .{
            .display = .block,
            .shrink = 0,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 50 },
                .height = .{ .length = 20 },
            },
            .overflow = .{ .width = .scroll, .height = .hidden },
            .scrollbar_width = 15,
        },
        .scroll = .{ .state = &scroll_state, .axis = .horizontal },
    });
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .row = .{} },
        .parent = .root,
        .style = .{
            .display = .flex,
            .direction = .row,
            .justify = .start,
            .@"align" = .start,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = 120 },
                .height = .{ .length = 30 },
            },
            .overflow = .{ .width = .scroll, .height = .visible },
        },
        .scroll = .{ .state = &root_state, .axis = .horizontal },
    });
    try tree.appendChild(root_id, hidden_leaf_id);
    try tree.appendChild(root_id, scroll_leaf_id);

    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 120, .height = 30 },
        .measure = layoutTreeMeasure,
    });

    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 50, .h = 20 },
        tree.node(hidden_leaf_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 50, .y = 0, .w = 50, .h = 20 },
        tree.node(scroll_leaf_id).?.rect,
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 0, .y = 0, .w = 50, .h = 20 },
        widget.absoluteRect(&tree, hidden_leaf_id),
    );
    try std.testing.expectEqual(
        widget.Rect{ .x = 50, .y = 0, .w = 50, .h = 20 },
        widget.absoluteRect(&tree, scroll_leaf_id),
    );
    try std.testing.expectEqual([2]f32{ 50, 0 }, hidden_state.max_offset);
    try std.testing.expectEqual([2]f32{ 50, 0 }, scroll_state.max_offset);
    try std.testing.expectEqual([2]f32{ 0, 0 }, root_state.max_offset);
}
