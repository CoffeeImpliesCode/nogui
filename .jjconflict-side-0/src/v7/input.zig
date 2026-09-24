//! v7 input hit testing — map a pointer position to the widget under it.
//! Pure geometry over the laid-out tree (widget.zig): no allocation, no side
//! effects. Node rects are RELATIVE border boxes (relative to the parent's
//! CONTENT box; root-level nodes relative to the surface), so each
//! candidate's visual rect is resolved once and reused for containment and
//! clipping; ancestor clip rectangles are resolved as the chain is walked.

const std = @import("std");

const Id = @import("id.zig").Id;
const widget = @import("widget.zig");
const style = @import("style.zig");
const WidgetTree = widget.WidgetTree;
const Rect = widget.Rect;

/// Topmost node containing `pos`. Post-order: children before parents, so
/// scanning from the START of the array returns the deepest/topmost hit
/// first (a button inside a column hits the button, not the column).
pub fn hitTest(tree: *const WidgetTree, pos: [2]f32) ?Id {
    for (tree.nodes.items) |n| {
        const visual_rect = widget.visualBorderRect(tree, n.id);
        if (pointInClipChainFromRect(tree, n.id, pos, visual_rect) and
            contains(visual_rect, pos))
        {
            return n.id;
        }
    }
    return null;
}

/// hitTest restricted to .button nodes (for click dispatch).
pub fn hitButton(tree: *const WidgetTree, pos: [2]f32) ?Id {
    for (tree.nodes.items) |n| {
        if (n.kind != .button) continue;
        const visual_rect = widget.visualBorderRect(tree, n.id);
        if (pointInClipChainFromRect(tree, n.id, pos, visual_rect) and
            contains(visual_rect, pos))
        {
            return n.id;
        }
    }
    return null;
}

/// Check clipping while reusing the candidate's already-resolved rectangle.
fn pointInClipChainFromRect(
    tree: *const WidgetTree,
    id: Id,
    pos: [2]f32,
    candidate_rect: Rect,
) bool {
    var cur = id;
    var current_rect = candidate_rect;
    while (cur != .root) {
        const n = tree.nodeConst(cur) orelse break;
        if (!widget.pointInClipAxes(current_rect, n.contentClipAxes(), pos)) return false;
        cur = n.parent;
        if (cur != .root) current_rect = widget.visualBorderRect(tree, cur);
    }
    return true;
}

/// Rect containment: pos.x >= rect.x and pos.x < rect.x + rect.w, same for y.
/// The left/top edges are inclusive, right/bottom exclusive; a zero-size
/// rect can never contain anything.
fn contains(rect: Rect, pos: [2]f32) bool {
    return pos[0] >= rect.x and pos[0] < rect.x + rect.w and
        pos[1] >= rect.y and pos[1] < rect.y + rect.h;
}

// --- tests ---------------------------------------------------------------

test "hitTest: point inside a leaf inside a container returns the leaf" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const column_id: Id = @enumFromInt(1);
    const label_id: Id = @enumFromInt(2);

    // Post-order: children before containers.
    try tree.nodes.append(std.testing.allocator, .{
        .id = label_id,
        .kind = .{ .label = .{ .text = "leaf" } },
        .parent = column_id,
        .rect = .{ .x = 10, .y = 10, .w = 20, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = column_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
    });
    try tree.appendChild(column_id, label_id);

    // Inside the label (hence inside the column too): deepest hit wins.
    try std.testing.expectEqual(label_id, hitTest(&tree, .{ 15, 12 }).?);
}

test "hitTest: point in container but outside all children hits the container" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const column_id: Id = @enumFromInt(1);
    const label_id: Id = @enumFromInt(2);

    try tree.nodes.append(std.testing.allocator, .{
        .id = label_id,
        .kind = .{ .label = .{ .text = "leaf" } },
        .parent = column_id,
        .rect = .{ .x = 10, .y = 10, .w = 20, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = column_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
    });
    try tree.appendChild(column_id, label_id);

    // In the column, not in the label (label spans x 10..30, y 10..20).
    try std.testing.expectEqual(column_id, hitTest(&tree, .{ 5, 50 }).?);
}

test "hitTest: point outside everything returns null" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const column_id: Id = @enumFromInt(1);
    const label_id: Id = @enumFromInt(2);

    try tree.nodes.append(std.testing.allocator, .{
        .id = label_id,
        .kind = .{ .label = .{ .text = "leaf" } },
        .parent = column_id,
        .rect = .{ .x = 10, .y = 10, .w = 20, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = column_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
    });
    try tree.appendChild(column_id, label_id);

    try std.testing.expectEqual(@as(?Id, null), hitTest(&tree, .{ 150, 150 }));
    try std.testing.expectEqual(@as(?Id, null), hitTest(&tree, .{ -1, -1 }));
}

test "hitButton: returns button id over a button, null over a label" {
    // Same point over a button: its id comes back.
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const button_id: Id = @enumFromInt(1);
    try tree.nodes.append(std.testing.allocator, .{
        .id = button_id,
        .kind = .{ .button = .{ .label = "Go" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 20 },
    });

    try std.testing.expectEqual(button_id, hitButton(&tree, .{ 20, 10 }).?);

    // Same point, same rect, but the node is a label: no button hit.
    var tree2 = WidgetTree.init(std.testing.allocator);
    defer tree2.deinit();

    const label_id: Id = @enumFromInt(2);
    try tree2.nodes.append(std.testing.allocator, .{
        .id = label_id,
        .kind = .{ .label = .{ .text = "plain" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 20 },
    });

    try std.testing.expectEqual(@as(?Id, null), hitButton(&tree2, .{ 20, 10 }));
}

test "hitButton: button inside a column hits the button, not the column" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const button_id: Id = @enumFromInt(1);
    const column_id: Id = @enumFromInt(2);

    try tree.nodes.append(std.testing.allocator, .{
        .id = button_id,
        .kind = .{ .button = .{ .label = "Go" } },
        .parent = column_id,
        .rect = .{ .x = 10, .y = 10, .w = 30, .h = 20 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = column_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
    });
    try tree.appendChild(column_id, button_id);

    // Point inside the button: both hit tests return the button, never the
    // enclosing column.
    try std.testing.expectEqual(button_id, hitButton(&tree, .{ 20, 15 }).?);
    try std.testing.expectEqual(button_id, hitTest(&tree, .{ 20, 15 }).?);
}

test "hitTest: rect edges inclusive at x/y, exclusive at x+w/y+h" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const id: Id = @enumFromInt(1);
    try tree.nodes.append(std.testing.allocator, .{
        .id = id,
        .kind = .{ .label = .{ .text = "box" } },
        .parent = .root,
        .rect = .{ .x = 5, .y = 5, .w = 10, .h = 10 },
    });

    // Inclusive: exactly on the left/top edge hits.
    try std.testing.expectEqual(id, hitTest(&tree, .{ 5, 5 }).?);
    try std.testing.expectEqual(id, hitTest(&tree, .{ 5, 14 }).?);
    try std.testing.expectEqual(id, hitTest(&tree, .{ 14, 5 }).?);
    // Exclusive: exactly at x+w / y+h misses.
    try std.testing.expectEqual(@as(?Id, null), hitTest(&tree, .{ 15, 5 }));
    try std.testing.expectEqual(@as(?Id, null), hitTest(&tree, .{ 5, 15 }));
}

test "hitTest: resolves absolute rect through parent padding + border" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const column_id: Id = @enumFromInt(1);
    const label_id: Id = @enumFromInt(2);

    // Post-order: child label first, then its container. The column sits at
    // the surface origin with padding left/top 8 and border left/top
    // 2/1, so its content box starts at (10, 9).
    try tree.nodes.append(std.testing.allocator, .{
        .id = label_id,
        .kind = .{ .label = .{ .text = "nested" } },
        .parent = column_id,
        .rect = .{ .x = 0, .y = 0, .w = 20, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = column_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .style = .{
            .padding_inset = .{
                .top = .{ .length = 8 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 8 },
            },
            .border_inset = .{
                .top = .{ .length = 1 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 2 },
            },
        },
    });
    try tree.appendChild(column_id, label_id);

    // Label's absolute border box: column content origin (8+2, 8+1) plus its
    // own relative rect (0,0) = (10, 9). Exactly on that origin: hit.
    try std.testing.expectEqual(label_id, hitTest(&tree, .{ 10, 9 }).?);
    // 1px outside the label (still inside the column): misses the label,
    // falls through to the column.
    try std.testing.expectEqual(column_id, hitTest(&tree, .{ 9, 9 }).?);
    try std.testing.expectEqual(column_id, hitTest(&tree, .{ 10, 8 }).?);
    // 1px beyond the label's far edge: also the column, not the label.
    try std.testing.expectEqual(column_id, hitTest(&tree, .{ 30, 9 }).?);
}

test "hitTest: zero-size rect never hits" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const id: Id = @enumFromInt(1);
    try tree.nodes.append(std.testing.allocator, .{
        .id = id,
        .kind = .{ .spacer = .{} },
        .parent = .root,
        .rect = .{ .x = 5, .y = 5, .w = 0, .h = 0 },
    });

    // Even exactly on the degenerate rect's corner, nothing is hit.
    try std.testing.expectEqual(@as(?Id, null), hitTest(&tree, .{ 5, 5 }));
    try std.testing.expectEqual(@as(?Id, null), hitTest(&tree, .{ 6, 6 }));
}
test "hitTest: clipped child outside parent clip returns null" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const parent_id: Id = @enumFromInt(1);
    const child_id: Id = @enumFromInt(2);
    try tree.nodes.append(std.testing.allocator, .{
        .id = child_id,
        .kind = .{ .label = .{ .text = "child" } },
        .parent = parent_id,
        .rect = .{ .x = 10, .y = 5, .w = 20, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = parent_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .paint = .{ .clip = true },
    });
    try tree.appendChild(parent_id, child_id);

    // The child's visual border box contains this point, but the parent's
    // clip border box does not.
    try std.testing.expectEqual(@as(?Id, null), hitTest(&tree, .{ 25, 10 }));
}

test "hitButton: clipped child outside parent clip returns null" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const parent_id: Id = @enumFromInt(1);
    const button_id: Id = @enumFromInt(2);
    try tree.nodes.append(std.testing.allocator, .{
        .id = button_id,
        .kind = .{ .button = .{ .label = "child" } },
        .parent = parent_id,
        .rect = .{ .x = 10, .y = 5, .w = 20, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = parent_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .paint = .{ .clip = true },
    });
    try tree.appendChild(parent_id, button_id);

    try std.testing.expectEqual(@as(?Id, null), hitButton(&tree, .{ 25, 10 }));
}

test "hit tests: style overflow modes reject descendants outside parent" {
    const overflow_modes = [_]style.Overflow{ .hidden, .clip };

    for (overflow_modes) |overflow_mode| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const parent_id: Id = @enumFromInt(1);
        const button_id: Id = @enumFromInt(2);
        try tree.nodes.append(std.testing.allocator, .{
            .id = button_id,
            .kind = .{ .button = .{ .label = "overflowed" } },
            .parent = parent_id,
            .rect = .{ .x = 25, .y = 20, .w = 30, .h = 20 },
        });
        try tree.nodes.append(std.testing.allocator, .{
            .id = parent_id,
            .kind = .{ .column = .{} },
            .parent = .root,
            .rect = .{ .x = 10, .y = 10, .w = 40, .h = 30 },
            .style = .{
                .overflow = .{ .width = overflow_mode, .height = overflow_mode },
            },
        });
        try tree.appendChild(parent_id, button_id);

        try std.testing.expect(tree.node(parent_id).?.scroll == null);
        try std.testing.expect(!tree.node(parent_id).?.paint.clip);
        // The point is inside the button's visual rect but outside the
        // overflow parent's border box.
        try std.testing.expectEqual(@as(?Id, null), hitButton(&tree, .{ 60, 45 }));
        try std.testing.expectEqual(@as(?Id, null), hitTest(&tree, .{ 60, 45 }));
        try std.testing.expect(!widget.pointInClipChain(&tree, button_id, .{ 60, 45 }));
    }
}

test "hit tests: mixed overflow axes clip independently" {
    const parent_id: Id = @enumFromInt(1);
    const button_id: Id = @enumFromInt(2);
    const cases = [_]struct {
        overflow: style.OverflowAxes,
        horizontal_hit: ?Id,
        vertical_hit: ?Id,
    }{
        .{
            .overflow = .{ .width = .clip, .height = .visible },
            .horizontal_hit = null,
            .vertical_hit = button_id,
        },
        .{
            .overflow = .{ .width = .visible, .height = .hidden },
            .horizontal_hit = button_id,
            .vertical_hit = null,
        },
    };

    for (cases) |case| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        try tree.nodes.append(std.testing.allocator, .{
            .id = button_id,
            .kind = .{ .button = .{ .label = "overflowed" } },
            .parent = parent_id,
            .rect = .{ .x = 25, .y = 20, .w = 30, .h = 30 },
        });
        try tree.nodes.append(std.testing.allocator, .{
            .id = parent_id,
            .kind = .{ .column = .{} },
            .parent = .root,
            .rect = .{ .x = 10, .y = 10, .w = 40, .h = 30 },
            .style = .{ .overflow = case.overflow },
        });
        try tree.appendChild(parent_id, button_id);

        const horizontal_overflow = [2]f32{ 60, 35 };
        const vertical_overflow = [2]f32{ 40, 50 };
        try std.testing.expectEqual(case.horizontal_hit, hitButton(&tree, horizontal_overflow));
        try std.testing.expectEqual(case.horizontal_hit, hitTest(&tree, horizontal_overflow));
        try std.testing.expectEqual(
            case.horizontal_hit != null,
            widget.pointInClipChain(&tree, button_id, horizontal_overflow),
        );
        try std.testing.expectEqual(case.vertical_hit, hitButton(&tree, vertical_overflow));
        try std.testing.expectEqual(case.vertical_hit, hitTest(&tree, vertical_overflow));
        try std.testing.expectEqual(
            case.vertical_hit != null,
            widget.pointInClipChain(&tree, button_id, vertical_overflow),
        );
    }
}
