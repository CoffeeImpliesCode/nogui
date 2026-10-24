//! v7 input hit testing — map a pointer position to the widget under it.
//! Pure geometry over the laid-out tree (widget.zig): no allocation, no side
//! effects. Node rects are RELATIVE border boxes (relative to the parent's
//! CONTENT box; root-level nodes relative to the surface), so each
//! candidate's visual rect is resolved once and reused for containment and
//! clipping; ancestor clip rectangles are resolved as the chain is walked.

const std = @import("std");

const FrameNodeId = @import("id.zig").FrameNodeId;
const WidgetId = @import("id.zig").WidgetId;
const widget = @import("widget.zig");
const style = @import("style.zig");
const WidgetTree = widget.WidgetTree;
const Rect = widget.Rect;
const geometry = @import("geometry.zig");

/// Topmost node containing `pos`. Post-order: children before parents, so
/// scanning from the START of the array returns the deepest/topmost hit
/// first (a button inside a column hits the button, not the column).
///
/// A DORMANT overlay subtree is skipped: it is a registered record no anchor
/// resolved, so its content is laid out and visible but belongs to no popup
/// on screen. Routing falls through it to whatever the frame really drew
/// there, which is the same answer the painter's exclusion implies.
pub fn hitTest(tree: *const WidgetTree, pos: [2]f32) ?FrameNodeId {
    for (tree.nodes.items) |n| {
        if (!widget.isVisible(tree, n.id)) continue;
        if (n.overlay_dormant) continue;
        const visual_rect = widget.visualBorderRect(tree, n.id);
        if (pointInClipChainFromRect(tree, n.id, pos, visual_rect) and
            contains(visual_rect, pos))
        {
            return n.id;
        }
    }
    return null;
}

/// Resolve the topmost hit to its nearest actionable ancestor. Disabled
/// overlays block clicks instead of letting them fall through to a sibling.
pub fn hitActionable(tree: *const WidgetTree, pos: [2]f32) ?FrameNodeId {
    var current = hitTest(tree, pos) orelse return null;
    if (!isEnabled(tree, current)) return null;
    var remaining = tree.nodes.items.len;
    while (current != .root and remaining > 0) : (remaining -= 1) {
        const node = tree.nodeConst(current) orelse return null;
        switch (node.kind) {
            .button, .checkbox, .switch_control, .radio => return current,
            else => current = node.parent,
        }
    }
    return null;
}

/// An unkeyed leaf can route through its nearest keyed ancestor. The result
/// is a stable handle, not the dense frame ID at this position.
pub fn hitStable(tree: *const WidgetTree, pos: [2]f32) ?WidgetId {
    var current = hitTest(tree, pos) orelse return null;
    if (!isEnabled(tree, current)) return null;
    var remaining = tree.nodes.items.len;
    while (current != .root and remaining > 0) : (remaining -= 1) {
        const node = tree.nodeConst(current) orelse return null;
        if (node.widget_id) |id| return id;
        current = node.parent;
    }
    return null;
}

/// Interactive eligibility includes every ancestor. It is not a paint test:
/// disabled boxes remain laid out and visible while hidden boxes do not hit.
/// A DORMANT overlay subtree is not interactive either — nothing painted it,
/// so a press must reach the control underneath — and because tab order and
/// focus assignment both read this one predicate, a dismissed popup's
/// controls leave the keyboard order with it.
///
/// Dormancy is read from the node ITSELF, never from its ancestors: `stage`
/// marks a whole unplaced subtree, so a node's own flag already covers every
/// ancestor it has. The one node inside a dormant subtree that is not dormant
/// is a PLACED record nested inside it, and that one is on screen, so it must
/// be painted, hittable, pressable and focusable together.
pub fn isEnabled(tree: *const WidgetTree, id: FrameNodeId) bool {
    if (!widget.isVisible(tree, id)) return false;
    if ((tree.nodeConst(id) orelse return false).overlay_dormant) return false;
    var current = id;
    var remaining = tree.nodes.items.len;
    while (current != .root and remaining > 0) : (remaining -= 1) {
        const node = tree.nodeConst(current) orelse return false;
        if (node.interaction.disabled) return false;
        current = node.parent;
    }
    return current == .root;
}

/// Check clipping while reusing the candidate's already-resolved rectangle.
fn pointInClipChainFromRect(
    tree: *const WidgetTree,
    id: FrameNodeId,
    pos: [2]f32,
    candidate_rect: Rect,
) bool {
    var cur = id;
    var current_rect = candidate_rect;
    while (cur != .root) {
        const n = tree.nodeConst(cur) orelse break;
        if (n.style.visibility == .hidden or n.style.display == .none) return false;
        if (n.placement_clip) |imposed| {
            if (!widget.pointInClipAxes(
                widget.clipRectToRect(current_rect, imposed),
                .{ .x = imposed.clipsX(), .y = imposed.clipsY() },
                pos,
            )) return false;
        }
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

    const column_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const label_id: FrameNodeId = @fromBackingInt(@intCast(2));

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

    const column_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const label_id: FrameNodeId = @fromBackingInt(@intCast(2));

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

    const column_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const label_id: FrameNodeId = @fromBackingInt(@intCast(2));

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

    try std.testing.expectEqual(@as(?FrameNodeId, null), hitTest(&tree, .{ 150, 150 }));
    try std.testing.expectEqual(@as(?FrameNodeId, null), hitTest(&tree, .{ -1, -1 }));
}

test "hitActionable: returns button id over a button, null over a label" {
    // Same point over a button: its id comes back.
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const button_id: FrameNodeId = @fromBackingInt(@intCast(1));
    try tree.nodes.append(std.testing.allocator, .{
        .id = button_id,
        .kind = .{ .button = .{ .label = "Go" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 20 },
    });

    try std.testing.expectEqual(button_id, hitActionable(&tree, .{ 20, 10 }).?);

    // Same point, same rect, but the node is a label: no button hit.
    var tree2 = WidgetTree.init(std.testing.allocator);
    defer tree2.deinit();

    const label_id: FrameNodeId = @fromBackingInt(@intCast(2));
    try tree2.nodes.append(std.testing.allocator, .{
        .id = label_id,
        .kind = .{ .label = .{ .text = "plain" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 20 },
    });

    try std.testing.expectEqual(@as(?FrameNodeId, null), hitActionable(&tree2, .{ 20, 10 }));
}

test "hitActionable: button inside a column hits the button, not the column" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const button_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const column_id: FrameNodeId = @fromBackingInt(@intCast(2));

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
    try std.testing.expectEqual(button_id, hitActionable(&tree, .{ 20, 15 }).?);
    try std.testing.expectEqual(button_id, hitTest(&tree, .{ 20, 15 }).?);
}

test "hitTest: rect edges inclusive at x/y, exclusive at x+w/y+h" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const id: FrameNodeId = @fromBackingInt(@intCast(1));
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
    try std.testing.expectEqual(@as(?FrameNodeId, null), hitTest(&tree, .{ 15, 5 }));
    try std.testing.expectEqual(@as(?FrameNodeId, null), hitTest(&tree, .{ 5, 15 }));
}

test "hitTest: resolves absolute rect through parent padding + border" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const column_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const label_id: FrameNodeId = @fromBackingInt(@intCast(2));

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

    const id: FrameNodeId = @fromBackingInt(@intCast(1));
    try tree.nodes.append(std.testing.allocator, .{
        .id = id,
        .kind = .{ .spacer = .{} },
        .parent = .root,
        .rect = .{ .x = 5, .y = 5, .w = 0, .h = 0 },
    });

    // Even exactly on the degenerate rect's corner, nothing is hit.
    try std.testing.expectEqual(@as(?FrameNodeId, null), hitTest(&tree, .{ 5, 5 }));
    try std.testing.expectEqual(@as(?FrameNodeId, null), hitTest(&tree, .{ 6, 6 }));
}
test "hitTest: clipped child outside parent clip returns null" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const parent_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const child_id: FrameNodeId = @fromBackingInt(@intCast(2));
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
    try std.testing.expectEqual(@as(?FrameNodeId, null), hitTest(&tree, .{ 25, 10 }));
}

test "hitActionable: clipped child outside parent clip returns null" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const parent_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const button_id: FrameNodeId = @fromBackingInt(@intCast(2));
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

    try std.testing.expectEqual(@as(?FrameNodeId, null), hitActionable(&tree, .{ 25, 10 }));
}

test "hit tests: style overflow modes reject descendants outside parent" {
    const overflow_modes = [_]style.Overflow{ .hidden, .clip };

    for (overflow_modes) |overflow_mode| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const parent_id: FrameNodeId = @fromBackingInt(@intCast(1));
        const button_id: FrameNodeId = @fromBackingInt(@intCast(2));
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
        try std.testing.expectEqual(@as(?FrameNodeId, null), hitActionable(&tree, .{ 60, 45 }));
        try std.testing.expectEqual(@as(?FrameNodeId, null), hitTest(&tree, .{ 60, 45 }));
        try std.testing.expect(!widget.pointInClipChain(&tree, button_id, .{ 60, 45 }));
    }
}

test "hit tests: mixed overflow axes clip independently" {
    const parent_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const button_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const cases = [_]struct {
        overflow: style.OverflowAxes,
        horizontal_hit: ?FrameNodeId,
        vertical_hit: ?FrameNodeId,
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
        try std.testing.expectEqual(case.horizontal_hit, hitActionable(&tree, horizontal_overflow));
        try std.testing.expectEqual(case.horizontal_hit, hitTest(&tree, horizontal_overflow));
        try std.testing.expectEqual(
            case.horizontal_hit != null,
            widget.pointInClipChain(&tree, button_id, horizontal_overflow),
        );
        try std.testing.expectEqual(case.vertical_hit, hitActionable(&tree, vertical_overflow));
        try std.testing.expectEqual(case.vertical_hit, hitTest(&tree, vertical_overflow));
        try std.testing.expectEqual(
            case.vertical_hit != null,
            widget.pointInClipChain(&tree, button_id, vertical_overflow),
        );
    }
}
test "hitActionable: returns every bound control but excludes zero-area controls" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var checked = false;
    var enabled = false;
    var selected: ?u32 = null;
    const checkbox_id: FrameNodeId = @fromBackingInt(@intCast(51));
    const switch_id: FrameNodeId = @fromBackingInt(@intCast(52));
    const radio_id: FrameNodeId = @fromBackingInt(@intCast(53));
    const zero_id: FrameNodeId = @fromBackingInt(@intCast(54));

    try tree.nodes.append(std.testing.allocator, .{
        .id = checkbox_id,
        .kind = .{ .checkbox = .{ .label = "check", .value = &checked } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = switch_id,
        .kind = .{ .switch_control = .{ .label = "switch", .value = &enabled } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 0, .w = 10, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = radio_id,
        .kind = .{ .radio = .{ .label = "radio", .selected = &selected, .option = 7 } },
        .parent = .root,
        .rect = .{ .x = 20, .y = 0, .w = 10, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = zero_id,
        .kind = .{ .checkbox = .{ .label = "zero", .value = &checked } },
        .parent = .root,
        .rect = .{ .x = 30, .y = 0, .w = 0, .h = 10 },
    });

    try std.testing.expectEqual(checkbox_id, hitActionable(&tree, .{ 5, 5 }).?);
    try std.testing.expectEqual(switch_id, hitActionable(&tree, .{ 15, 5 }).?);
    try std.testing.expectEqual(radio_id, hitActionable(&tree, .{ 25, 5 }).?);
    try std.testing.expectEqual(@as(?FrameNodeId, null), hitActionable(&tree, .{ 30, 5 }));
}

test "hitActionable: a clipped bound control cannot be hit outside its ancestor" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var checked = false;
    const parent_id: FrameNodeId = @fromBackingInt(@intCast(61));
    const checkbox_id: FrameNodeId = @fromBackingInt(@intCast(62));
    try tree.nodes.append(std.testing.allocator, .{
        .id = checkbox_id,
        .kind = .{ .checkbox = .{ .label = "clipped", .value = &checked } },
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
    try tree.appendChild(parent_id, checkbox_id);

    try std.testing.expectEqual(@as(?FrameNodeId, null), hitActionable(&tree, .{ 25, 10 }));
}

test "api-w02 nested border padding and scroll hit targets at three pixel scales" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const outer: FrameNodeId = @fromBackingInt(@intCast(1));
    const middle: FrameNodeId = @fromBackingInt(@intCast(2));
    const button: FrameNodeId = @fromBackingInt(@intCast(3));
    var outer_scroll: widget.ScrollState = .{ .offset = .{ 1.5, 2.5 } };
    var middle_scroll: widget.ScrollState = .{ .offset = .{ 2, 1 } };
    try tree.appendNode(.{
        .id = button,
        .kind = .{ .button = .{ .label = "Nested" } },
        .parent = middle,
        .rect = .{ .x = 22, .y = 16, .w = 24, .h = 12 },
    });
    try tree.appendNode(.{
        .id = middle,
        .kind = .{ .column = .{} },
        .parent = outer,
        .rect = .{ .x = 10, .y = 8, .w = 40, .h = 32 },
        .style = .{
            .border_inset = .{
                .top = .{ .length = 2 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 1 },
            },
            .padding_inset = .{
                .top = .{ .length = 3 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 2 },
            },
            .overflow = .{ .width = .clip, .height = .clip },
        },
        .scroll = .{ .state = &middle_scroll, .axis = .both },
    });
    try tree.appendNode(.{
        .id = outer,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 8, .y = 12, .w = 80, .h = 60 },
        .style = .{
            .border_inset = .{
                .top = .{ .length = 3 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 2 },
            },
            .padding_inset = .{
                .top = .{ .length = 5 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 4 },
            },
        },
        .scroll = .{ .state = &outer_scroll, .axis = .both },
    });
    try tree.appendChild(middle, button);
    try tree.appendChild(outer, middle);

    const visual = widget.visualBorderRect(&tree, button);
    const clip = widget.visualBorderRect(&tree, middle);
    try std.testing.expectEqual(
        Rect{ .x = 49, .y = 49, .w = 24, .h = 12 },
        widget.absoluteRect(&tree, button),
    );
    try std.testing.expectEqual(Rect{ .x = 45.5, .y = 45.5, .w = 24, .h = 12 }, visual);
    try std.testing.expectEqual(Rect{ .x = 22.5, .y = 25.5, .w = 40, .h = 32 }, clip);

    const pixel_sizes = [_]geometry.DeviceSize{
        .{ .width = 160, .height = 120 },
        .{ .width = 200, .height = 150 },
        .{ .width = 320, .height = 240 },
    };
    for (pixel_sizes) |pixels| {
        const scale = try geometry.PixelScale.init(.{ .width = 160, .height = 120 }, pixels);
        const button_pixels = scale.windowRectToDevice(.{
            .x = visual.x,
            .y = visual.y,
            .w = visual.w,
            .h = visual.h,
        });
        const clip_pixels = scale.windowRectToDevice(.{
            .x = clip.x,
            .y = clip.y,
            .w = clip.w,
            .h = clip.h,
        });
        const cases = [_]struct {
            device: geometry.DevicePoint,
            actionable: ?FrameNodeId,
            topmost: ?FrameNodeId,
        }{
            // The child's visual corner is inclusive, even with two scroll offsets.
            .{
                .device = .{ .x = button_pixels.x, .y = button_pixels.y },
                .actionable = button,
                .topmost = button,
            },
            .{
                .device = .{
                    .x = clip_pixels.x + clip_pixels.w - scale.x * 0.25,
                    .y = button_pixels.y,
                },
                .actionable = button,
                .topmost = button,
            },
            .{
                .device = .{ .x = clip_pixels.x + clip_pixels.w, .y = button_pixels.y },
                .actionable = null,
                .topmost = outer,
            },
            .{
                .device = .{
                    .x = button_pixels.x + scale.x,
                    .y = clip_pixels.y + clip_pixels.h - scale.y * 0.25,
                },
                .actionable = button,
                .topmost = button,
            },
            .{
                .device = .{
                    .x = button_pixels.x + scale.x,
                    .y = clip_pixels.y + clip_pixels.h,
                },
                .actionable = null,
                .topmost = outer,
            },
            .{
                .device = .{
                    .x = button_pixels.x - scale.x * 0.25,
                    .y = button_pixels.y,
                },
                .actionable = null,
                .topmost = middle,
            },
        };
        for (cases) |case| {
            const window_point = scale.deviceToWindow(case.device);
            const pos = [2]f32{ window_point.x, window_point.y };
            try std.testing.expectEqual(case.actionable, hitActionable(&tree, pos));
            try std.testing.expectEqual(case.topmost, hitTest(&tree, pos));
        }
    }
}
