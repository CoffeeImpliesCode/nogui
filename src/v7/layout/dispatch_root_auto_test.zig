//! Locks root pseudo placement for mixed flex/grid trees with auto dimensions.
//!
//! The direct dispatcher tests exercise the natural-measurement bridge and the
//! forced border passed back into the selected layout engine. The facade test
//! verifies that the public root chooses this path instead of its legacy
//! fallback.

const std = @import("std");
const Id = @import("../id.zig").Id;
const dispatch = @import("dispatch.zig");
const facade = @import("root.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");

const Rect = widget.Rect;
const Style = style.Style;
const WidgetKind = widget.WidgetKind;
const WidgetTree = widget.WidgetTree;

fn fixedStyle(display: style.Display, width: f32, height: f32) Style {
    return .{
        .display = display,
        .box_sizing = .border_box,
        .size = .{
            .width = .{ .length = width },
            .height = .{ .length = height },
        },
    };
}

fn autoStyle(display: style.Display) Style {
    return .{
        .display = display,
        .box_sizing = .border_box,
        .size = .{ .width = .auto, .height = .auto },
    };
}

fn appendNode(
    tree: *WidgetTree,
    id: Id,
    parent: Id,
    node_style: Style,
    kind: WidgetKind,
) !void {
    try tree.appendNode(.{
        .id = id,
        .kind = kind,
        .parent = parent,
        .style = node_style,
    });
}

fn layoutDispatch(tree: *WidgetTree, available: widget.Size) !void {
    try dispatch.layoutTree(tree, .{
        .allocator = std.testing.allocator,
        .available = available,
        .measure = null,
    });
}

fn layoutFacade(tree: *WidgetTree, available: widget.Size) !void {
    try facade.layoutTree(tree, .{
        .allocator = std.testing.allocator,
        .available = available,
        .measure = null,
    });
}

fn expectRect(tree: *const WidgetTree, id: Id, expected: Rect) !void {
    try std.testing.expectEqual(expected, tree.nodeConst(id).?.rect);
}

test "dispatcher gives an auto-height mixed flex root its natural grid height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const grid_id: Id = @enumFromInt(3);
    const root_id: Id = @enumFromInt(4);
    const columns = [_]style.GridTrack{.{ .fixed = 30 }};
    const rows = [_]style.GridTrack{ .{ .fixed = 12 }, .{ .fixed = 8 } };

    try appendNode(&tree, first_id, grid_id, fixedStyle(.block, 30, 12), .{ .spacer = .{} });
    try appendNode(&tree, second_id, grid_id, fixedStyle(.block, 30, 8), .{ .spacer = .{} });

    var grid_style = autoStyle(.grid);
    grid_style.grid_template_columns = columns[0..];
    grid_style.grid_template_rows = rows[0..];
    grid_style.grid_row_gap = .{ .length = 4 };
    grid_style.grid_justify_content = .start;
    grid_style.grid_align_content = .start;
    grid_style.grid_justify_items = .start;
    grid_style.grid_align_items = .start;
    try appendNode(&tree, grid_id, root_id, grid_style, .{ .column = .{} });

    var root_style = fixedStyle(.flex, 100, 80);
    root_style.size.height = .auto;
    root_style.direction = .row;
    root_style.@"align" = .start;
    try appendNode(&tree, root_id, .root, root_style, .{ .row = .{} });

    try tree.appendChild(grid_id, first_id);
    try tree.appendChild(grid_id, second_id);
    try tree.appendChild(root_id, grid_id);

    try layoutDispatch(&tree, .{ .width = 100, .height = 80 });

    try expectRect(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 24 });
    try expectRect(&tree, grid_id, .{ .x = 0, .y = 0, .w = 30, .h = 24 });
    try expectRect(&tree, first_id, .{ .x = 0, .y = 0, .w = 30, .h = 12 });
    try expectRect(&tree, second_id, .{ .x = 0, .y = 16, .w = 30, .h = 8 });
}

test "dispatcher stretches an auto-sized grid root and keeps natural height" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const first_id: Id = @enumFromInt(1);
    const second_id: Id = @enumFromInt(2);
    const flex_id: Id = @enumFromInt(3);
    const root_id: Id = @enumFromInt(4);
    const columns = [_]style.GridTrack{.{ .fixed = 40 }};
    const rows = [_]style.GridTrack{.auto};

    try appendNode(&tree, first_id, flex_id, fixedStyle(.block, 40, 10), .{ .spacer = .{} });
    try appendNode(&tree, second_id, flex_id, fixedStyle(.block, 40, 5), .{ .spacer = .{} });

    var flex_style = autoStyle(.flex);
    flex_style.direction = .column;
    flex_style.@"align" = .start;
    try appendNode(&tree, flex_id, root_id, flex_style, .{ .column = .{} });

    var root_style = autoStyle(.grid);
    root_style.grid_template_columns = columns[0..];
    root_style.grid_template_rows = rows[0..];
    root_style.grid_justify_content = .start;
    root_style.grid_align_content = .start;
    root_style.grid_justify_items = .start;
    root_style.grid_align_items = .start;
    try appendNode(&tree, root_id, .root, root_style, .{ .column = .{} });

    try tree.appendChild(flex_id, first_id);
    try tree.appendChild(flex_id, second_id);
    try tree.appendChild(root_id, flex_id);

    try layoutDispatch(&tree, .{ .width = 120, .height = 80 });

    try expectRect(&tree, root_id, .{ .x = 0, .y = 0, .w = 120, .h = 15 });
    try expectRect(&tree, flex_id, .{ .x = 0, .y = 0, .w = 40, .h = 15 });
    try expectRect(&tree, first_id, .{ .x = 0, .y = 0, .w = 40, .h = 10 });
    try expectRect(&tree, second_id, .{ .x = 0, .y = 10, .w = 40, .h = 5 });
}

test "dispatcher preserves concrete root height and stretches root pseudo width" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: Id = @enumFromInt(1);
    const grid_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    const columns = [_]style.GridTrack{.{ .fixed = 24 }};
    const rows = [_]style.GridTrack{.{ .fixed = 10 }};

    try appendNode(&tree, leaf_id, grid_id, fixedStyle(.block, 24, 10), .{ .spacer = .{} });

    var grid_style = autoStyle(.grid);
    grid_style.grid_template_columns = columns[0..];
    grid_style.grid_template_rows = rows[0..];
    grid_style.grid_justify_content = .start;
    grid_style.grid_align_content = .start;
    grid_style.grid_justify_items = .start;
    grid_style.grid_align_items = .start;
    try appendNode(&tree, grid_id, root_id, grid_style, .{ .column = .{} });

    var root_style = fixedStyle(.flex, 90, 30);
    root_style.direction = .row;
    root_style.@"align" = .start;
    try appendNode(&tree, root_id, .root, root_style, .{ .row = .{} });

    try tree.appendChild(grid_id, leaf_id);
    try tree.appendChild(root_id, grid_id);

    try layoutDispatch(&tree, .{ .width = 120, .height = 80 });

    try expectRect(&tree, root_id, .{ .x = 0, .y = 0, .w = 120, .h = 30 });
    try expectRect(&tree, grid_id, .{ .x = 0, .y = 0, .w = 24, .h = 10 });
    try expectRect(&tree, leaf_id, .{ .x = 0, .y = 0, .w = 24, .h = 10 });
}

test "layoutTree dispatches a mixed auto flex root through the public facade" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaf_id: Id = @enumFromInt(1);
    const grid_id: Id = @enumFromInt(2);
    const root_id: Id = @enumFromInt(3);
    const columns = [_]style.GridTrack{.{ .fixed = 36 }};
    const rows = [_]style.GridTrack{.{ .fixed = 18 }};

    try appendNode(&tree, leaf_id, grid_id, fixedStyle(.block, 36, 18), .{ .spacer = .{} });

    var grid_style = autoStyle(.grid);
    grid_style.grid_template_columns = columns[0..];
    grid_style.grid_template_rows = rows[0..];
    grid_style.grid_justify_content = .start;
    grid_style.grid_align_content = .start;
    grid_style.grid_justify_items = .start;
    grid_style.grid_align_items = .start;
    try appendNode(&tree, grid_id, root_id, grid_style, .{ .column = .{} });

    var root_style = autoStyle(.flex);
    root_style.direction = .row;
    root_style.@"align" = .start;
    try appendNode(&tree, root_id, .root, root_style, .{ .row = .{} });

    try tree.appendChild(grid_id, leaf_id);
    try tree.appendChild(root_id, grid_id);

    try layoutFacade(&tree, .{ .width = 100, .height = 80 });

    try expectRect(&tree, root_id, .{ .x = 0, .y = 0, .w = 100, .h = 18 });
    try expectRect(&tree, grid_id, .{ .x = 0, .y = 0, .w = 36, .h = 18 });
    try expectRect(&tree, leaf_id, .{ .x = 0, .y = 0, .w = 36, .h = 18 });
}
