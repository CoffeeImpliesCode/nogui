const std = @import("std");
const overlay = @import("overlay.zig");
const widget = @import("widget.zig");
const focus = @import("focus.zig");
const element = @import("element.zig");
const drawcmd = @import("drawcmd.zig");
const input = @import("input.zig");
const semantics = @import("semantics.zig");
const id_mod = @import("id.zig");
const FrameNodeId = id_mod.FrameNodeId;
const WidgetId = id_mod.WidgetId;

const anchor_id: WidgetId = .{ .owner = 7, .slot = 1, .generation = 1 };
const popup_id: WidgetId = .{ .owner = 7, .slot = 2, .generation = 1 };
const back_id: WidgetId = .{ .owner = 7, .slot = 3, .generation = 1 };
/// The ordinary control no overlay record names, and the one the published
/// semantics tree must keep while a dismissed popup's own node goes.
const ordinary_id: WidgetId = .{ .owner = 7, .slot = 4, .generation = 1 };
const scroll_node: FrameNodeId = @fromBackingInt(@intCast(4));
const anchor_node: FrameNodeId = @fromBackingInt(@intCast(1));
const popup_node: FrameNodeId = @fromBackingInt(@intCast(2));
const back_node: FrameNodeId = @fromBackingInt(@intCast(3));
const inner_node: FrameNodeId = @fromBackingInt(@intCast(9));
const ordinary_node: FrameNodeId = @fromBackingInt(@intCast(7));
/// The two nested topologies' own identities: an outer popup and a record
/// inside it, so both directions of the nesting rule can be built.
const outer_id: WidgetId = .{ .owner = 7, .slot = 5, .generation = 1 };
const inner_nested_id: WidgetId = .{ .owner = 7, .slot = 6, .generation = 1 };
/// A handle no frame in this file ever publishes, so a record naming it
/// resolves to nothing: that is the whole "unplaced" half of both cases.
const absent_id: WidgetId = .{ .owner = 7, .slot = 9, .generation = 1 };
const outer_node: FrameNodeId = @fromBackingInt(@intCast(10));
const inner_nested_node: FrameNodeId = @fromBackingInt(@intCast(11));
/// The nested records' priorities, and they are INVERTED on purpose: the
/// unplaced child is the weaker record and the placed child is the weaker one
/// too, so neither case can be decided by priority.
const ancestor_priority: u31 = 5;
const child_priority: u31 = 1;

fn treeWithPopup(gpa: std.mem.Allocator, scroll: *widget.ScrollState) !widget.WidgetTree {
    return buildTree(gpa, scroll, anchor_id.generation, false);
}

/// A later frame that dropped the anchor and published everything else.
fn treeWithoutAnchor(gpa: std.mem.Allocator, scroll: *widget.ScrollState) !widget.WidgetTree {
    return buildTree(gpa, scroll, null, false);
}

/// One frame of the REAL lifecycle: the consumer registers this frame's
/// popups while it draws, and the frame is resolved against the tree that
/// frame published. Records describe one frame, never a frame's leftovers, so
/// a caller that owns its whole frame registers what it draws every frame —
/// the same `beginFrame`, draw, `resolve` sequence the App runs per publish.
fn resolveFrame(
    frame: *overlay.Frame,
    tree: *widget.WidgetTree,
    view: widget.Rect,
    records: []const overlay.Record,
) !void {
    frame.beginFrame();
    for (records) |record| try frame.add(record);
    try frame.resolve(tree, view);
}

/// One frame's tree: the popup over a scroller, and the anchor the frame
/// published with `generation`. Null is a frame that published no anchor at
/// all; a different generation is the same node id behind a recycled handle.
/// `with_inner` adds one control inside the popup, for the subtree test.
///
/// Storage is POST-ORDER, the tree's documented invariant: a node's children
/// come before the node itself, which is what every hit walk in the core
/// assumes when it scans forward for the deepest node under a point.
fn buildTree(
    gpa: std.mem.Allocator,
    scroll: *widget.ScrollState,
    generation: ?u32,
    with_inner: bool,
) !widget.WidgetTree {
    var tree = widget.WidgetTree.init(gpa);
    errdefer tree.deinit();
    if (generation) |value| {
        try tree.appendNode(.{
            .id = anchor_node,
            .widget_id = .{
                .owner = anchor_id.owner,
                .slot = anchor_id.slot,
                .generation = value,
            },
            .kind = .{ .button = .{ .label = "Anchor" } },
            .parent = scroll_node,
            .rect = .{ .x = 10, .y = 70, .w = 25, .h = 10 },
        });
    }
    try tree.appendNode(.{
        .id = scroll_node,
        .kind = .{ .column = .{} },
        .parent = .root,
        .scroll = .{ .state = scroll },
        .rect = .{ .w = 100, .h = 85 },
        .style = .{ .overflow = .{ .width = .visible, .height = .scroll } },
    });
    if (with_inner) {
        // A control inside the popup, laid out inside it. Its absolute
        // position before placement is the popup's own flow position.
        try tree.appendNode(.{
            .id = inner_node,
            .kind = .{ .label = .{ .text = "Item" } },
            .parent = popup_node,
            .rect = .{ .x = 4, .y = 5, .w = 20, .h = 10 },
        });
    }
    try tree.appendNode(.{
        .id = popup_node,
        .widget_id = popup_id,
        .kind = .{ .button = .{ .label = "Popup" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 70, .h = 30 },
    });
    return tree;
}

// Anchoring must read each current visual position, not capture the first layout's coordinates.
test "api-w16 popup follows scroll-moving anchor and flips at viewport edge" {
    var scroll: widget.ScrollState = .{};
    var tree = try treeWithPopup(std.testing.allocator, &scroll);
    defer tree.deinit();
    var frame = overlay.Frame.init(std.testing.allocator);
    defer frame.deinit();
    const records = [_]overlay.Record{.{
        .anchor = anchor_id,
        .content = popup_id,
        .margin = 5,
        .gap = 2,
    }};
    try resolveFrame(&frame, &tree, .{ .x = 0, .y = 0, .w = 100, .h = 100 }, &records);
    const first = frame.placement(&tree, popup_id).?;
    try std.testing.expectEqual(@as(f32, 38), first.rect.y);
    try std.testing.expectEqual(@as(f32, 10), first.rect.x);
    try std.testing.expectEqual(popup_node, frame.hitTest(&tree, .{ 26, 55 }).?);

    // The next frame draws the same popup, so it registers it again: the
    // anchor has scrolled, and the placement is resolved from the CURRENT
    // visual position rather than the first layout's coordinates.
    scroll.offset[1] = 50;
    try resolveFrame(&frame, &tree, .{ .x = 0, .y = 0, .w = 100, .h = 100 }, &records);
    const moved = frame.placement(&tree, popup_id).?;
    try std.testing.expectEqual(@as(f32, 32), moved.rect.y);
    try std.testing.expectEqual(@as(f32, 10), moved.rect.x);
    try std.testing.expectEqual(popup_node, frame.hitTest(&tree, .{ 26, 33 }).?);
    try std.testing.expect(frame.hitTest(&tree, .{ 26, 65 }) == null);
}

// An edge-anchored horizontal popup flips; oversized content snaps to the safe inset.
test "api-w16 horizontal flip and oversized viewport snap preserve margins" {
    var scroll: widget.ScrollState = .{};
    var tree = try treeWithPopup(std.testing.allocator, &scroll);
    defer tree.deinit();
    tree.node(anchor_node).?.rect.x = 90;
    tree.node(anchor_node).?.rect.y = 20;
    var frame = overlay.Frame.init(std.testing.allocator);
    defer frame.deinit();
    const records = [_]overlay.Record{.{
        .anchor = anchor_id,
        .content = popup_id,
        .side = .right,
        .gap = 2,
        .margin = 5,
        .clip = .window_escape,
    }};
    try resolveFrame(&frame, &tree, .{ .w = 100, .h = 100 }, &records);
    try std.testing.expectEqual(@as(f32, 18), frame.placement(&tree, popup_id).?.rect.x);
    tree.node(popup_node).?.rect.w = 120;
    try resolveFrame(&frame, &tree, .{ .w = 100, .h = 100 }, &records);
    try std.testing.expectEqual(@as(f32, 5), frame.placement(&tree, popup_id).?.rect.x);
}

// An owner removed from a later frame must not keep stale geometry or an input target.
test "api-w16 a vanished anchor dismisses its overlay" {
    var scroll: widget.ScrollState = .{};
    var tree = try treeWithPopup(std.testing.allocator, &scroll);
    defer tree.deinit();
    var frame = overlay.Frame.init(std.testing.allocator);
    defer frame.deinit();
    const records = [_]overlay.Record{.{ .anchor = anchor_id, .content = popup_id }};
    try resolveFrame(&frame, &tree, .{ .w = 100, .h = 100 }, &records);
    try std.testing.expect(frame.placement(&tree, popup_id) != null);
    // The next frame still draws the menu, so it registers the same record —
    // and its tree published no anchor at all. The record resolves to nothing
    // and the overlay is dismissed rather than keeping stale geometry.
    var next_scroll: widget.ScrollState = .{};
    var next = try treeWithoutAnchor(std.testing.allocator, &next_scroll);
    defer next.deinit();
    try resolveFrame(&frame, &next, .{ .w = 100, .h = 100 }, &records);
    try std.testing.expect(frame.placement(&next, popup_id) == null);
    try std.testing.expect(frame.hitTest(&next, .{ 12, 90 }) == null);
    // The content is still an overlay subtree: the ordinary paint and hit
    // walks must keep excluding it even with nothing placed.
    try std.testing.expect(frame.isOverlayNode(&next, popup_node));
}

/// The ordinary control every dormant claim is measured against: a keyed
/// button that no record names, placed below everything the placement and hit
/// probes look at so it changes no other answer in the frame.
fn appendOrdinary(tree: *widget.WidgetTree) !void {
    try tree.appendNode(.{
        .id = ordinary_node,
        .widget_id = ordinary_id,
        .kind = .{ .button = .{ .label = "Ordinary" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 90, .w = 40, .h = 20 },
    });
}

/// An outer popup with a record's content inside it. POST-ORDER, the tree's
/// documented storage invariant: the child is appended before the parent that
/// contains it, which is what every hit walk in the core assumes.
fn appendNested(tree: *widget.WidgetTree) !void {
    try tree.appendNode(.{
        .id = inner_nested_node,
        .widget_id = inner_nested_id,
        .kind = .{ .button = .{ .label = "Inner" } },
        .parent = outer_node,
        .rect = .{ .x = 4, .y = 4, .w = 24, .h = 12 },
    });
    try tree.appendNode(.{
        .id = outer_node,
        .widget_id = outer_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 40, .w = 60, .h = 40 },
    });
}

/// Whether the canonical collector emitted a command for exactly this box.
/// The one painter, asked the one question: did this committed box reach the
/// GPU at all.
fn collectedBox(tree: *widget.WidgetTree, box: widget.Rect) !bool {
    var commands: std.ArrayList(drawcmd.DrawCmd) = .empty;
    defer commands.deinit(std.testing.allocator);
    try commands.ensureTotalCapacity(std.testing.allocator, try drawcmd.requiredCapacity(tree));
    try drawcmd.collectDrawCmdsInto(tree, null, 0, &commands);
    for (commands.items) |cmd| {
        if (std.meta.eql(cmd.rect, box)) return true;
    }
    return false;
}

// A REGISTERED record whose anchor left the tree leaves its content laid out,
// filled and authored visible with nothing placing it. Painting it would show
// a dismissed popup over whatever the frame really drew, and routing to it
// would swallow the press meant for the control underneath, so the ordinary
// walks must exclude it — and the same record must come back the moment an
// anchor places it.
// NESTING, both directions, closes the same question: a record inside another
// record's content is decided by the DEEPEST claim, never by priority, and a
// placed child of a dismissed popup is on screen in every sense at once.
test "api-w16 a record with no anchor paints nothing and routes nothing" {
    const records = [_]overlay.Record{.{ .anchor = anchor_id, .content = popup_id }};
    var frame = overlay.Frame.init(std.testing.allocator);
    defer frame.deinit();

    var scroll: widget.ScrollState = .{};
    var next = try treeWithoutAnchor(std.testing.allocator, &scroll);
    defer next.deinit();
    // One ordinary keyed control that is NOT overlay content, so the claims
    // below are about what a dismissal took away and not about an empty tree.
    try appendOrdinary(&next);
    try resolveFrame(&frame, &next, .{ .w = 100, .h = 100 }, &records);
    try std.testing.expect(frame.placement(&next, popup_id) == null);
    try std.testing.expect(next.nodeConst(popup_node).?.overlay_dormant);

    // Nothing painted it: the collector emits no command for the dismissed
    // content's own box, so what the frame shows there is the frame.
    const box = widget.visualBorderRect(&next, popup_node);
    var commands: std.ArrayList(drawcmd.DrawCmd) = .empty;
    defer commands.deinit(std.testing.allocator);
    try commands.ensureTotalCapacity(std.testing.allocator, try drawcmd.requiredCapacity(&next));
    try drawcmd.collectDrawCmdsInto(&next, null, 0, &commands);
    for (commands.items) |cmd| {
        try std.testing.expect(!std.meta.eql(cmd.rect, box));
    }

    // And nothing routed it: the point inside the dismissed box belongs to
    // the frame's own container, through the tree walk and through the App's
    // total routing answer alike.
    const point: [2]f32 = .{ box.x + box.w / 2, box.y + box.h / 2 };
    try std.testing.expectEqual(scroll_node, input.hitTest(&next, point).?);
    try std.testing.expectEqual(scroll_node, frame.hitTestTotal(&next, point).?);

    // The published semantics tree agrees with the frame. The ordinary
    // control is still there, and the dismissed popup's own STABLE node — the
    // identity an accessibility client addresses, and the target its click
    // would carry — is absent, so nothing outside the frame can activate it.
    var publisher = semantics.Publisher.init(std.testing.allocator);
    defer publisher.deinit();
    try publisher.stage(.{ .tree = &next, .surface = .{ .width = 100, .height = 100 } });
    publisher.commit();
    const dismissed = publisher.snapshot() orelse return error.NoSemanticSnapshot;
    try std.testing.expect(dismissed.node(semantics.nodeId(ordinary_id, .self_node)) != null);
    try std.testing.expect(dismissed.node(semantics.nodeId(popup_id, .self_node)) == null);

    // A frame that published its anchor places the very same record again,
    // and the very same walks answer for it: the exclusion is the anchor's
    // doing, not the content's identity.
    var live_scroll: widget.ScrollState = .{};
    var live = try treeWithPopup(std.testing.allocator, &live_scroll);
    defer live.deinit();
    // The same ordinary control, so both frames are compared over the same
    // published tree.
    try appendOrdinary(&live);
    try resolveFrame(&frame, &live, .{ .w = 100, .h = 100 }, &records);
    try std.testing.expect(!live.nodeConst(popup_node).?.overlay_dormant);
    const placed = frame.placement(&live, popup_id).?.rect;
    const placed_hit_box = widget.placedContentRect(&live, popup_node) orelse
        return error.MissingPlacedRect;
    var placed_commands: std.ArrayList(drawcmd.DrawCmd) = .empty;
    defer placed_commands.deinit(std.testing.allocator);
    try placed_commands.ensureTotalCapacity(
        std.testing.allocator,
        try drawcmd.requiredCapacity(&live),
    );
    try drawcmd.collectDrawCmdsInto(&live, null, 0, &placed_commands);
    var painted = false;
    for (placed_commands.items) |cmd| {
        if (std.meta.eql(cmd.rect, placed)) painted = true;
    }
    try std.testing.expect(painted);
    try std.testing.expectEqual(popup_node, frame.hitTestTotal(&live, .{
        placed_hit_box.x + placed_hit_box.w / 2,
        placed_hit_box.y + placed_hit_box.h / 2,
    }).?);

    // Reactivation restores it. The same stable semantic node is published
    // again because the anchor came back, not because the content changed
    // identity — and the ordinary control never left.
    try publisher.stage(.{ .tree = &live, .surface = .{ .width = 100, .height = 100 } });
    publisher.commit();
    const restored = publisher.snapshot() orelse return error.NoSemanticSnapshot;
    try std.testing.expect(restored.node(semantics.nodeId(popup_id, .self_node)) != null);
    try std.testing.expect(restored.node(semantics.nodeId(ordinary_id, .self_node)) != null);

    // NESTED, direction one: the record inside the PLACED one resolved to
    // nothing, and it is the WEAKER of the two. The child is hidden at any
    // priority, and the popup around it is untouched.
    var weak_child: [2]overlay.Record = .{
        .{ .anchor = anchor_id, .content = outer_id, .priority = ancestor_priority },
        .{
            .anchor = absent_id,
            .content = inner_nested_id,
            .side = .above,
            .priority = child_priority,
        },
    };
    var hidden_scroll: widget.ScrollState = .{};
    var hidden = try treeWithPopup(std.testing.allocator, &hidden_scroll);
    defer hidden.deinit();
    try appendNested(&hidden);
    // A dismissed child's own valid layer cannot exhaust its ancestor's band.
    hidden.node(inner_nested_node).?.paint.layer = std.math.maxInt(u32);
    try resolveFrame(&frame, &hidden, .{ .w = 100, .h = 100 }, &weak_child);
    try std.testing.expect(frame.placement(&hidden, outer_id) != null);
    try std.testing.expect(frame.placement(&hidden, inner_nested_id) == null);
    try std.testing.expect(hidden.nodeConst(inner_nested_node).?.placement_paint == null);
    const outer_box = frame.placement(&hidden, outer_id).?.rect;
    const hidden_child_box = widget.visualBorderRect(&hidden, inner_nested_node);
    const hidden_point: [2]f32 = .{
        hidden_child_box.x + hidden_child_box.w / 2,
        hidden_child_box.y + hidden_child_box.h / 2,
    };
    try std.testing.expect(try collectedBox(&hidden, outer_box));
    try std.testing.expect(!try collectedBox(&hidden, hidden_child_box));
    try std.testing.expectEqual(scroll_node, input.hitTest(&hidden, hidden_point).?);
    try std.testing.expectEqual(outer_node, frame.hitTestTotal(&hidden, hidden_point).?);
    try std.testing.expect(!input.isEnabled(&hidden, inner_nested_node));
    try std.testing.expect(input.isEnabled(&hidden, outer_node));

    // NESTED, direction two: the record inside the UNPLACED one placed, at
    // the lower priority again. The child is the whole visible content there,
    // so it paints, routes, presses AND is published to accessibility — all
    // four, because a subtree that is on screen in one and absent in another
    // is the divergence this rule exists to prevent.
    var strong_child: [2]overlay.Record = .{
        .{ .anchor = absent_id, .content = outer_id, .priority = ancestor_priority },
        .{
            .anchor = anchor_id,
            .content = inner_nested_id,
            .side = .above,
            .priority = child_priority,
        },
    };
    var shown_scroll: widget.ScrollState = .{};
    var shown = try treeWithPopup(std.testing.allocator, &shown_scroll);
    defer shown.deinit();
    try appendNested(&shown);
    try resolveFrame(&frame, &shown, .{ .w = 100, .h = 100 }, &strong_child);
    try std.testing.expect(frame.placement(&shown, outer_id) == null);
    const child_box = frame.placement(&shown, inner_nested_id).?.rect;
    const child_point: [2]f32 = .{ child_box.x + child_box.w / 2, child_box.y + child_box.h / 2 };
    try std.testing.expect(try collectedBox(&shown, child_box));
    try std.testing.expect(!try collectedBox(&shown, widget.visualBorderRect(&shown, outer_node)));
    try std.testing.expectEqual(inner_nested_node, frame.hitTest(&shown, child_point).?);
    try std.testing.expectEqual(
        inner_nested_node,
        frame.hitTestTotal(&shown, child_point).?,
    );
    try std.testing.expect(input.isEnabled(&shown, inner_nested_node));
    try publisher.stage(.{ .tree = &shown, .surface = .{ .width = 100, .height = 100 } });
    publisher.commit();
    const nested = publisher.snapshot() orelse return error.NoSemanticSnapshot;
    try std.testing.expect(nested.node(semantics.nodeId(inner_nested_id, .self_node)) != null);
    try std.testing.expect(nested.node(semantics.nodeId(outer_id, .self_node)) == null);
}

// An inherited clip is IMPOSED on the content root: its laid-out SIZE is
// untouched — placement is what moves the origin — and the tree's own clip
// chain, which paint, hit and inspection all read, is what excludes the part
// the scroller hides.
test "api-w16 inherited clip blocks outside scroller while window escape reaches it" {
    var scroll: widget.ScrollState = .{};
    var tree = try treeWithPopup(std.testing.allocator, &scroll);
    defer tree.deinit();
    const layout_size = tree.node(popup_node).?.rect;
    var frame = overlay.Frame.init(std.testing.allocator);
    defer frame.deinit();
    const records = [_]overlay.Record{.{
        .anchor = anchor_id,
        .content = popup_id,
        .gap = 0,
        .clip = .inherit,
    }};
    try resolveFrame(&frame, &tree, .{ .w = 100, .h = 140 }, &records);
    try std.testing.expect(frame.hitTest(&tree, .{ 11, 91 }) == null);

    // Clipping must not relayout the content. Placement is the one mutation
    // that moves the root, so the SIZE the popup was laid out with is the
    // size it occupies once the scroller's clip excludes the rest of it.
    const placed_box = tree.node(popup_node).?.rect;
    try std.testing.expectEqual(layout_size.w, placed_box.w);
    try std.testing.expectEqual(layout_size.h, placed_box.h);
    const imposed = tree.node(popup_node).?.placement_clip orelse
        return error.MissingPlacementClip;
    try std.testing.expect(imposed.y + imposed.h <= 85);
    // The same field is what the painter folds into its clip stack, so the
    // visible part of the placed box is bounded by the same rect.
    const placed = widget.placedContentRect(&tree, popup_node) orelse
        return error.MissingPlacedRect;
    try std.testing.expect(placed.y + placed.h <= 85);
    try std.testing.expect(!widget.pointInClipChain(&tree, popup_node, .{ 11, 91 }));

    // The imposed clip belongs to the placement, not to the node: a second
    // frame that escapes the window REPLACES it, so the same content root
    // cannot keep a clip that its own policy no longer asks for.
    var escape = overlay.Frame.init(std.testing.allocator);
    defer escape.deinit();
    const escaped = [_]overlay.Record{.{
        .anchor = anchor_id,
        .content = popup_id,
        .clip = .window_escape,
    }};
    try resolveFrame(&escape, &tree, .{ .w = 100, .h = 140 }, &escaped);
    try std.testing.expectEqual(popup_node, escape.hitTest(&tree, .{ 11, 91 }).?);
    // Window escape adds no clip of its own; the popup's own ancestry still
    // applies, because that is the tree's single rule.
    try std.testing.expectEqual(
        @as(?widget.ClipRect, null),
        tree.node(popup_node).?.placement_clip,
    );
}

// Placement is one geometry: the content root's relative box moves, every
// descendant inherits it, and nothing stores a second copy of the offset.
test "api-w16 placed content moves the subtree, not one node" {
    var scroll: widget.ScrollState = .{};
    var tree = try buildTree(std.testing.allocator, &scroll, anchor_id.generation, true);
    defer tree.deinit();
    const before_inner = widget.visualBorderRect(&tree, inner_node);
    const before_root = widget.visualBorderRect(&tree, popup_node);

    var frame = overlay.Frame.init(std.testing.allocator);
    defer frame.deinit();
    const records = [_]overlay.Record{.{
        .anchor = anchor_id,
        .content = popup_id,
        .clip = .window_escape,
    }};
    try resolveFrame(&frame, &tree, .{ .w = 100, .h = 140 }, &records);
    const placement = frame.placement(&tree, popup_id) orelse return error.UnplacedPopup;

    // The root sits where the frame said, and the child moved by exactly the
    // same delta: the parent walk is the only thing that carried it.
    try std.testing.expectEqual(placement.rect, widget.visualBorderRect(&tree, popup_node));
    const after_inner = widget.visualBorderRect(&tree, inner_node);
    try std.testing.expectEqual(placement.rect.x - before_root.x, after_inner.x - before_inner.x);
    try std.testing.expectEqual(placement.rect.y - before_root.y, after_inner.y - before_inner.y);
    // Input reads that one geometry: a point over the child reaches the child,
    // not the root it is drawn inside.
    try std.testing.expectEqual(
        inner_node,
        frame.hitTest(&tree, .{
            after_inner.x + after_inner.w / 2,
            after_inner.y + after_inner.h / 2,
        }).?,
    );
}

// Paint order must use the same priority and insertion tie-break as hit order.
test "api-w16 topmost painted overlay owns overlapping input" {
    var scroll: widget.ScrollState = .{};
    var tree = try treeWithPopup(std.testing.allocator, &scroll);
    defer tree.deinit();
    try tree.appendNode(.{
        .id = back_node,
        .widget_id = back_id,
        .kind = .{ .button = .{ .label = "Back" } },
        .parent = .root,
        .rect = .{ .w = 70, .h = 30 },
    });
    var frame = overlay.Frame.init(std.testing.allocator);
    defer frame.deinit();
    const records = [_]overlay.Record{
        .{ .anchor = anchor_id, .content = popup_id, .priority = 4, .clip = .window_escape },
        .{ .anchor = anchor_id, .content = back_id, .priority = 9, .clip = .window_escape },
    };
    try resolveFrame(&frame, &tree, .{ .w = 100, .h = 140 }, &records);
    try std.testing.expectEqual(back_node, frame.hitTest(&tree, .{ 15, 91 }).?);
    // The band the painter reads now: the higher priority popup paints above
    // the lower one, and its key is the one hit routing scanned.
    const back_band = (tree.nodeConst(back_node) orelse return error.MissingBackPopup)
        .placement_paint orelse return error.MissingBackBand;
    const popup_band = (tree.nodeConst(popup_node) orelse return error.MissingPopup)
        .placement_paint orelse return error.MissingPopupBand;
    try std.testing.expect(back_band.order > popup_band.order);
    try std.testing.expect(back_band.layer > popup_band.layer);
    try std.testing.expect(try widget.effectiveLayer(
        tree.nodeConst(back_node) orelse return error.MissingBackPopup,
        0,
    ) > try widget.effectiveLayer(
        tree.nodeConst(popup_node) orelse return error.MissingPopup,
        0,
    ));
}

// Modal closure restores a live previous key, never a recycled generation.
test "api-w16 modal focus restores only surviving prior focus" {
    var scroll: widget.ScrollState = .{};
    var tree = try treeWithPopup(std.testing.allocator, &scroll);
    defer tree.deinit();
    var manager: focus.Manager = .{};
    var modal: overlay.ModalFocus = .{};
    try std.testing.expect(manager.set(&tree, anchor_id, null));
    try std.testing.expect(modal.open(&manager, &tree, popup_id, null));
    try std.testing.expectEqual(popup_id, manager.current.?);
    modal.close(&manager, &tree, null);
    try std.testing.expectEqual(anchor_id, manager.current.?);
    try std.testing.expect(modal.open(&manager, &tree, popup_id, null));
    // The next frame published the anchor behind a recycled handle
    // generation, so the focus the modal remembers is retired.
    var later_scroll: widget.ScrollState = .{};
    var later = try buildTree(std.testing.allocator, &later_scroll, anchor_id.generation + 1, false);
    defer later.deinit();
    modal.close(&manager, &later, null);
    try std.testing.expect(manager.current == null);
}

// --- paint bands ---------------------------------------------------------
//
// A band is the CONSUMER-VISIBLE contract: `widget.effectiveLayer` is what
// the painter emits, so these regressions read emitted layers and never the
// stored base on its own.

/// One custom leaf whose paint record carries its own layer bump, so a test
/// can separate the layer a node authored from the one its element adds.
const BumpElement = struct {
    bump: u32 = 0,

    pub fn measure(_: *const BumpElement, request: element.MeasureInput) element.Error!widget.Size {
        return .{
            .width = request.known_dimensions.width orelse 20,
            .height = request.known_dimensions.height orelse 10,
        };
    }

    pub const PhaseState = struct {};

    pub fn paint(
        self: *const BumpElement,
        _: *PhaseState,
        geometry: element.Geometry,
        canvas: *element.PaintWriter,
    ) element.Error!void {
        try canvas.addRect(.{
            .bounds = .{ .x = 0, .y = 0, .w = geometry.content.w, .h = geometry.content.h },
            .fill = .{ .solid = .{ .srgb = .{ .r = 0.2, .g = 0.8, .b = 0.4 } } },
            .layer = self.bump,
        });
    }
};

/// Append the custom leaf `payload` describes, with the paint records its
/// hook emits for `rect`, as a child of `parent`. The hook runs through the
/// element's own ops table, so the records are the ones `finishFrame` would
/// have produced.
fn appendBumpElement(
    arena: std.mem.Allocator,
    tree: *widget.WidgetTree,
    id: FrameNodeId,
    parent: FrameNodeId,
    rect: widget.Rect,
    authored: u32,
    payload: BumpElement,
) !void {
    const frame = try element.make(BumpElement, arena, payload, .none);
    var writer: element.PaintWriter = .{ .allocator = arena, .records = &frame.paint_records };
    try frame.ops.paint.?(
        frame.payload,
        frame.phase,
        .{ .border = rect, .content = rect },
        &writer,
    );
    try tree.appendNode(.{
        .id = id,
        .kind = .{ .element = frame },
        .parent = parent,
        .rect = rect,
        .paint = .{ .layer = authored, .fill = .{ 0.1, 0.1, 0.1, 1 } },
    });
}

/// The topmost painted layer covering `probe`: the painter emits in tree
/// order, so the highest layer there is what a sorter puts on top.
fn topLayerAt(gpa: std.mem.Allocator, tree: *widget.WidgetTree, probe: [2]f32) !u32 {
    const commands = try drawcmd.collectDrawCmds(gpa, tree, null, 0);
    defer gpa.free(commands);
    var top: ?u32 = null;
    for (commands) |command| {
        const box = command.rect;
        if (probe[0] < box.x or probe[0] >= box.x + box.w) continue;
        if (probe[1] < box.y or probe[1] >= box.y + box.h) continue;
        const layer = command.rect_paint.layer;
        top = if (top) |current| @max(current, layer) else layer;
    }
    return top orelse error.MissingPaintedBox;
}

/// The ordinary application card a popup has to cover: a real authored
/// layer with an identifying fill.
fn appendCard(tree: *widget.WidgetTree, layer: u32) !void {
    try tree.appendNode(.{
        .id = card_node,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 140, .h = 140 },
        .paint = .{ .layer = layer, .fill = .{ 0.2, 0.4, 0.9, 1 } },
    });
}

/// A popup content root: it authors `authored` itself, and the band is added
/// to that rather than replacing it.
fn appendPopup(tree: *widget.WidgetTree, id: FrameNodeId, handle: WidgetId, authored: u32) !void {
    try tree.appendNode(.{
        .id = id,
        .widget_id = handle,
        .kind = .{ .button = .{ .label = "Popup" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 60, .h = 40 },
        .paint = .{ .layer = authored, .fill = .{ 0.2, 0.22, 0.3, 1 } },
    });
}

const card_node: FrameNodeId = @fromBackingInt(@intCast(10));
const high_id: WidgetId = .{ .owner = 9, .slot = 1, .generation = 1 };
const low_id: WidgetId = .{ .owner = 9, .slot = 2, .generation = 1 };
const high_node: FrameNodeId = @fromBackingInt(@intCast(11));
const low_node: FrameNodeId = @fromBackingInt(@intCast(12));

/// One band-test frame: an anchor, a card, and two popups built in the
/// requested order. Storage stays post-order, the tree's invariant.
fn bandTree(
    arena: std.mem.Allocator,
    high_first: bool,
) !widget.WidgetTree {
    var tree = widget.WidgetTree.init(arena);
    errdefer tree.deinit();
    try tree.appendNode(.{
        .id = anchor_node,
        .widget_id = anchor_id,
        .kind = .{ .button = .{ .label = "Anchor" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 80, .w = 25, .h = 10 },
    });
    try appendCard(&tree, 5);
    if (high_first) {
        try appendPopup(&tree, high_node, high_id, 1);
        try appendPopup(&tree, low_node, low_id, 1);
    } else {
        try appendPopup(&tree, low_node, low_id, 1);
        try appendPopup(&tree, high_node, high_id, 1);
    }
    return tree;
}

const low_then_high = [_]overlay.Record{
    .{ .anchor = anchor_id, .content = low_id, .priority = 1, .clip = .window_escape },
    .{ .anchor = anchor_id, .content = high_id, .priority = 7, .clip = .window_escape },
};
const high_then_low = [_]overlay.Record{
    .{ .anchor = anchor_id, .content = high_id, .priority = 7, .clip = .window_escape },
    .{ .anchor = anchor_id, .content = low_id, .priority = 1, .clip = .window_escape },
};

// Priority decides the band. Registration order and node build order must
// not: the defect this covers painted an ordinary card over a placed popup
// because neither ever reached a physical layer.
test "api-w16 higher priority paints above a lower popup in both registration and build orders" {
    const gpa = std.testing.allocator;
    for ([_]bool{ false, true }) |high_first| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var tree = try bandTree(arena.allocator(), high_first);
        defer tree.deinit();
        var frame = overlay.Frame.init(gpa);
        defer frame.deinit();

        for ([_][]const overlay.Record{ &low_then_high, &high_then_low }) |records| {
            try resolveFrame(&frame, &tree, .{ .w = 200, .h = 200 }, records);
            // Both popups cover the card over the anchor, so the topmost
            // painted layer at that point is the higher-priority popup.
            const top = try topLayerAt(gpa, &tree, .{ 20, 100 });
            const high = try widget.effectiveLayer(
                tree.nodeConst(high_node) orelse return error.MissingHighPopup,
                0,
            );
            const low = try widget.effectiveLayer(
                tree.nodeConst(low_node) orelse return error.MissingLowPopup,
                0,
            );
            try std.testing.expectEqual(high, top);
            try std.testing.expect(high > low);
            // Disjoint bands, both strictly above the card's own layer.
            try std.testing.expect(low > 5);
            try std.testing.expectEqual(high_node, frame.hitTest(&tree, .{ 20, 100 }).?);
        }
    }
}

// Equal priority has no tie-break of its own, so the later registration owns
// the topmost band — the same key hit routing already used.
test "api-w16 equal priority gives the later registration the topmost band" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var tree = try bandTree(arena.allocator(), false);
    defer tree.deinit();
    var frame = overlay.Frame.init(gpa);
    defer frame.deinit();
    const records = [_]overlay.Record{
        .{ .anchor = anchor_id, .content = low_id, .clip = .window_escape },
        .{ .anchor = anchor_id, .content = high_id, .clip = .window_escape },
    };
    try resolveFrame(&frame, &tree, .{ .w = 200, .h = 200 }, &records);
    const high = try widget.effectiveLayer(
        tree.nodeConst(high_node) orelse return error.MissingHighPopup,
        0,
    );
    const low = try widget.effectiveLayer(
        tree.nodeConst(low_node) orelse return error.MissingLowPopup,
        0,
    );
    try std.testing.expect(high > low);
    try std.testing.expectEqual(high, try topLayerAt(gpa, &tree, .{ 20, 100 }));
    try std.testing.expectEqual(high_node, frame.hitTest(&tree, .{ 20, 100 }).?);
}

const nested_id: WidgetId = .{ .owner = 9, .slot = 3, .generation = 1 };
const nested_node: FrameNodeId = @fromBackingInt(@intCast(13));
const nested_child_node: FrameNodeId = @fromBackingInt(@intCast(14));

/// An outer popup containing the inner popup, with an ordinary child beside
/// it so the inner band is compared against a node of the SAME subtree.
fn nestedBandTree(arena: std.mem.Allocator) !widget.WidgetTree {
    var tree = widget.WidgetTree.init(arena);
    errdefer tree.deinit();
    try tree.appendNode(.{
        .id = anchor_node,
        .widget_id = anchor_id,
        .kind = .{ .button = .{ .label = "Anchor" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 80, .w = 25, .h = 10 },
    });
    try tree.appendNode(.{
        .id = nested_child_node,
        .kind = .{ .button = .{ .label = "Item" } },
        .parent = nested_node,
        .rect = .{ .x = 4, .y = 4, .w = 20, .h = 10 },
        .paint = .{ .fill = .{ 0.3, 0.3, 0.35, 1 } },
    });
    try tree.appendNode(.{
        .id = nested_node,
        .widget_id = nested_id,
        .kind = .{ .button = .{ .label = "Outer" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 60, .h = 40 },
        .paint = .{ .fill = .{ 0.2, 0.22, 0.3, 1 } },
    });
    try tree.appendNode(.{
        .id = high_node,
        .widget_id = high_id,
        .kind = .{ .button = .{ .label = "Inner" } },
        .parent = nested_node,
        .rect = .{ .x = 4, .y = 20, .w = 20, .h = 10 },
        .paint = .{ .fill = .{ 0.5, 0.5, 0.6, 1 } },
    });
    return tree;
}

// A nested popup registered FIRST keeps its own band when a lower-priority
// ancestor places around it later. Last-registration overwrite would hand
// the inner subtree to the outer band and sink it below the popup it sits in.
test "api-w16 a nested higher-priority popup keeps its band over a later low-priority ancestor" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var tree = try nestedBandTree(arena.allocator());
    defer tree.deinit();
    var frame = overlay.Frame.init(gpa);
    defer frame.deinit();
    // The high-priority inner popup registers FIRST; the low-priority
    // ancestor registers after it and covers the same subtree.
    const records = [_]overlay.Record{
        .{ .anchor = anchor_id, .content = high_id, .priority = 9, .clip = .window_escape },
        .{ .anchor = anchor_id, .content = nested_id, .priority = 1, .clip = .window_escape },
    };
    try resolveFrame(&frame, &tree, .{ .w = 200, .h = 200 }, &records);
    const outer = try widget.effectiveLayer(
        tree.nodeConst(nested_node) orelse return error.MissingOuterPopup,
        0,
    );
    const inner = try widget.effectiveLayer(
        tree.nodeConst(high_node) orelse return error.MissingInnerPopup,
        0,
    );
    const sibling = try widget.effectiveLayer(
        tree.nodeConst(nested_child_node) orelse return error.MissingSibling,
        0,
    );
    try std.testing.expect(inner > outer);
    try std.testing.expect(inner > sibling);
    // The inner nodes kept the INNER record's band: last-registration
    // overwrite would have handed them the outer band instead.
    const inner_band = (tree.nodeConst(high_node) orelse return error.MissingInnerPopup)
        .placement_paint orelse return error.MissingInnerBand;
    const outer_band = (tree.nodeConst(nested_node) orelse return error.MissingOuterPopup)
        .placement_paint orelse return error.MissingOuterBand;
    try std.testing.expect(inner_band.order > outer_band.order);
    try std.testing.expect(inner_band.record_index != outer_band.record_index);
    const inner_placement = frame.placement(&tree, high_id) orelse
        return error.MissingInnerPlacement;
    try std.testing.expectEqual(inner_placement.record_index, inner_band.record_index);
    const outer_placement = frame.placement(&tree, nested_id) orelse
        return error.MissingOuterPlacement;
    try std.testing.expectEqual(outer_placement.record_index, outer_band.record_index);
}

// The band covers everything its subtree EMITS: authored layers, generated
// chrome and custom record bumps alike, and the next band starts above all
// of it.
test "api-w16 a band spans its own authored layers and custom record bumps" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tree = widget.WidgetTree.init(allocator);
    defer tree.deinit();
    try tree.appendNode(.{
        .id = anchor_node,
        .widget_id = anchor_id,
        .kind = .{ .button = .{ .label = "Anchor" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 80, .w = 25, .h = 10 },
    });
    try appendCard(&tree, 2);
    // A custom leaf INSIDE the low popup: its own authored layer plus its
    // record bump is the highest layer that band has to contain.
    try appendBumpElement(allocator, &tree, @fromBackingInt(@intCast(30)), low_node, .{
        .x = 2,
        .y = 2,
        .w = 16,
        .h = 8,
    }, 3, .{ .bump = 4 });
    // A custom leaf OUTSIDE every placement with a much higher local layer.
    // It contributes to the application maximum but gets no band of its own,
    // so the placed popups still clear it.
    try appendBumpElement(allocator, &tree, @fromBackingInt(@intCast(31)), .root, .{
        .x = 0,
        .y = 0,
        .w = 10,
        .h = 10,
    }, 40, .{ .bump = 30 });
    try appendPopup(&tree, low_node, low_id, 1);
    try appendPopup(&tree, high_node, high_id, 1);

    var frame = overlay.Frame.init(gpa);
    defer frame.deinit();
    try resolveFrame(&frame, &tree, .{ .w = 200, .h = 200 }, &low_then_high);

    const unplaced = try widget.effectiveLayer(
        tree.nodeConst(@fromBackingInt(@intCast(31))) orelse return error.MissingUnplacedCustom,
        30,
    );
    // Its own authored layer plus its record bump, unbanded.
    try std.testing.expectEqual(@as(u32, 70), unplaced);
    const low = try widget.effectiveLayer(
        tree.nodeConst(low_node) orelse return error.MissingLowPopup,
        0,
    );
    const custom_in_band = try widget.effectiveLayer(
        tree.nodeConst(@fromBackingInt(@intCast(30))) orelse return error.MissingBandedCustom,
        4,
    );
    const high = try widget.effectiveLayer(
        tree.nodeConst(high_node) orelse return error.MissingHighPopup,
        0,
    );
    // Both popups clear the unplaced custom record, and the banded custom
    // record stays inside its own band — above the low popup's own root and
    // below the next band.
    try std.testing.expect(low > unplaced);
    try std.testing.expect(custom_in_band > low);
    try std.testing.expect(high > custom_in_band);
    // The internal authored order survives inside one band.
    const low_root_own = try widget.effectiveLayer(
        tree.nodeConst(low_node) orelse return error.MissingLowPopup,
        3,
    );
    try std.testing.expectEqual(low + 3, low_root_own);
}

// An unplaced record is exactly an ordinary node: it has no band, so its own
// high local layer can never lift it above a placed popup.
test "api-w16 an unplaced high custom layer stays below the placed popup" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tree = widget.WidgetTree.init(allocator);
    defer tree.deinit();
    try tree.appendNode(.{
        .id = anchor_node,
        .widget_id = anchor_id,
        .kind = .{ .button = .{ .label = "Anchor" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 80, .w = 25, .h = 10 },
    });
    try appendBumpElement(allocator, &tree, @fromBackingInt(@intCast(32)), .root, .{
        .x = 0,
        .y = 0,
        .w = 20,
        .h = 20,
    }, 900, .{ .bump = 0 });
    try appendPopup(&tree, low_node, low_id, 0);

    var frame = overlay.Frame.init(gpa);
    defer frame.deinit();
    const records = [_]overlay.Record{.{
        .anchor = anchor_id,
        .content = low_id,
        .clip = .window_escape,
    }};
    try resolveFrame(&frame, &tree, .{ .w = 200, .h = 200 }, &records);
    const unplaced = tree.nodeConst(@fromBackingInt(@intCast(32))) orelse return error.MissingUnplacedCustom;
    try std.testing.expect(unplaced.placement_paint == null);
    const popup = try widget.effectiveLayer(
        tree.nodeConst(low_node) orelse return error.MissingPopup,
        0,
    );
    try std.testing.expect(popup > try widget.effectiveLayer(unplaced, 0));
}

// A layer that cannot hold its own band fails the frame. It never clamps and
// never wraps onto a layer that means something else, and the frame that was
// committed before it keeps its routing, its metadata and its pixels.
test "api-w16 a custom layer bump that overflows fails the frame and keeps the committed bands" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tree = widget.WidgetTree.init(allocator);
    defer tree.deinit();
    try tree.appendNode(.{
        .id = anchor_node,
        .widget_id = anchor_id,
        .kind = .{ .button = .{ .label = "Anchor" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 80, .w = 25, .h = 10 },
    });
    try appendPopup(&tree, low_node, low_id, 0);
    var frame = overlay.Frame.init(gpa);
    defer frame.deinit();
    const records = [_]overlay.Record{.{
        .anchor = anchor_id,
        .content = low_id,
        .clip = .window_escape,
    }};
    try resolveFrame(&frame, &tree, .{ .w = 200, .h = 200 }, &records);
    const committed_layer = try widget.effectiveLayer(
        tree.nodeConst(low_node) orelse return error.MissingPopup,
        0,
    );
    const committed_rect = widget.visualBorderRect(&tree, low_node);

    // The next frame's custom record asks for a layer the space cannot hold.
    var next_arena = std.heap.ArenaAllocator.init(gpa);
    defer next_arena.deinit();
    const next_allocator = next_arena.allocator();
    var next = widget.WidgetTree.init(next_allocator);
    defer next.deinit();
    try next.appendNode(.{
        .id = anchor_node,
        .widget_id = anchor_id,
        .kind = .{ .button = .{ .label = "Anchor" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 80, .w = 25, .h = 10 },
    });
    try appendBumpElement(next_allocator, &next, @fromBackingInt(@intCast(33)), .root, .{
        .x = 0,
        .y = 0,
        .w = 20,
        .h = 20,
    }, 4, .{ .bump = std.math.maxInt(u32) });
    try appendPopup(&next, low_node, low_id, 0);

    frame.beginFrame();
    for (records) |record| try frame.add(record);
    try frame.stage(&next, .{ .w = 200, .h = 200 });
    try std.testing.expectError(
        error.PaintLayerOverflow,
        frame.finalizePaintOrder(&next),
    );
    // The failed candidate answers for nothing, and the committed frame is
    // untouched: same routing, same metadata, same pixels.
    try std.testing.expect(frame.placement(&next, low_id) == null);
    try std.testing.expect(frame.placement(&tree, low_id) != null);
    try std.testing.expectEqual(committed_rect, widget.visualBorderRect(&tree, low_node));
    try std.testing.expectEqual(
        committed_layer,
        try widget.effectiveLayer(
            tree.nodeConst(low_node) orelse return error.MissingPopup,
            0,
        ),
    );
}

// A failed stage keeps the committed routing and its metadata exactly as
// they were; a placement that never resolved contributes no band.
test "api-w16 a failed stage leaves the committed bands untouched" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var tree = try bandTree(arena.allocator(), false);
    defer tree.deinit();
    var frame = overlay.Frame.init(gpa);
    defer frame.deinit();
    try resolveFrame(&frame, &tree, .{ .w = 200, .h = 200 }, &low_then_high);
    const committed_high = try widget.effectiveLayer(
        tree.nodeConst(high_node) orelse return error.MissingHighPopup,
        0,
    );

    var next_arena = std.heap.ArenaAllocator.init(gpa);
    defer next_arena.deinit();
    var next = try bandTree(next_arena.allocator(), false);
    defer next.deinit();
    frame.beginFrame();
    for (low_then_high) |record| try frame.add(record);
    // A negative extent is invalid geometry, so the stage fails before it
    // resolves anything.
    try std.testing.expectError(
        error.InvalidGeometry,
        frame.stage(&next, .{ .w = -1, .h = 200 }),
    );
    try std.testing.expect(frame.placement(&next, high_id) == null);
    try std.testing.expect(frame.placement(&tree, high_id) != null);
    try std.testing.expectEqual(
        committed_high,
        try widget.effectiveLayer(
            tree.nodeConst(high_node) orelse return error.MissingHighPopup,
            0,
        ),
    );
    // Nothing was tagged on the failed candidate, so it carries no band.
    try std.testing.expect((next.nodeConst(high_node) orelse return error.MissingHighPopup)
        .placement_paint == null);
}

// The previous tree keeps answering for its own popups after the next one
// publishes: the metadata travels with the tree by value.
test "api-w16 previous and current trees each keep their own bands" {
    const gpa = std.testing.allocator;
    var first_arena = std.heap.ArenaAllocator.init(gpa);
    defer first_arena.deinit();
    var first = try bandTree(first_arena.allocator(), false);
    defer first.deinit();
    var frame = overlay.Frame.init(gpa);
    defer frame.deinit();
    try resolveFrame(&frame, &first, .{ .w = 200, .h = 200 }, &low_then_high);
    const first_high = try widget.effectiveLayer(
        first.nodeConst(high_node) orelse return error.MissingHighPopup,
        0,
    );
    const first_band = (first.nodeConst(high_node) orelse return error.MissingHighPopup)
        .placement_paint orelse return error.MissingBand;

    var second_arena = std.heap.ArenaAllocator.init(gpa);
    defer second_arena.deinit();
    var second = try bandTree(second_arena.allocator(), false);
    defer second.deinit();
    // A different registration order assigns the same bands, so the new
    // tree's own values are the ones that moved.
    try resolveFrame(&frame, &second, .{ .w = 200, .h = 200 }, &high_then_low);
    const second_band = (second.nodeConst(high_node) orelse return error.MissingHighPopup)
        .placement_paint orelse return error.MissingBand;
    try std.testing.expectEqual(first_band.layer, second_band.layer);
    // The superseded tree's own nodes still read their band by value. The
    // FRAME answers only for the tree it resolved last — a placement never
    // names an id in a tree it did not resolve against — so routing follows
    // the current tree while the previous tree keeps its metadata.
    try std.testing.expectEqual(
        first_high,
        try widget.effectiveLayer(
            first.nodeConst(high_node) orelse return error.MissingHighPopup,
            0,
        ),
    );
    try std.testing.expectEqual(high_node, frame.hitTest(&second, .{ 20, 100 }).?);
    try std.testing.expect(frame.hitTest(&first, .{ 20, 100 }) == null);
    try std.testing.expect(frame.placement(&first, high_id) == null);
}

// The core W16 contract: paint order and hit order are ONE ordering. Both
// rank by the node's own `placement_paint.order`, so no topmost-painted
// overlay can lose input to the underlay it is drawn over.
test "api-w16 hit order is the painted order, so the topmost overlay owns the press" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tree = widget.WidgetTree.init(allocator);
    defer tree.deinit();
    try tree.appendNode(.{
        .id = anchor_node,
        .widget_id = anchor_id,
        .kind = .{ .button = .{ .label = "Anchor" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 80, .w = 25, .h = 10 },
    });
    try appendCard(&tree, 5);
    try appendPopup(&tree, low_node, low_id, 1);
    try appendPopup(&tree, high_node, high_id, 1);
    var frame = overlay.Frame.init(gpa);
    defer frame.deinit();
    try resolveFrame(&frame, &tree, .{ .w = 200, .h = 200 }, &low_then_high);

    // Sweep the whole overlap. At EVERY point the routed target must be the
    // node that PAINTS on top there, measured from the emitted draw commands
    // — the painter's own answer, not a restatement of the routing rule.
    var compared: usize = 0;
    for (0..60) |gx| {
        for (0..60) |gy| {
            const probe: [2]f32 = .{
                15 + @as(f32, @floatFromInt(gx)),
                95 + @as(f32, @floatFromInt(gy)),
            };
            const routed = frame.hitTest(&tree, probe) orelse continue;
            const node = tree.nodeConst(routed) orelse return error.MissingRoutedNode;
            // Nothing unplaced ever owns a press.
            _ = node.placement_paint orelse return error.UnbandedRoutedNode;
            try std.testing.expectEqual(
                try topLayerAt(gpa, &tree, probe),
                try widget.effectiveLayer(node, 0),
            );
            compared += 1;
        }
    }
    try std.testing.expect(compared > 0);

    // And the concrete case: at the overlap the HIGHER priority popup owns
    // the press, and its painted layer is above the lower popup's.
    const overlap: [2]f32 = .{ 20, 100 };
    try std.testing.expectEqual(high_node, frame.hitTest(&tree, overlap).?);
    try std.testing.expectEqual(
        try widget.effectiveLayer(tree.nodeConst(high_node) orelse return error.MissingHighPopup, 0),
        try topLayerAt(gpa, &tree, overlap),
    );
    try std.testing.expect(
        try widget.effectiveLayer(tree.nodeConst(high_node) orelse return error.MissingHighPopup, 0) >
            try widget.effectiveLayer(tree.nodeConst(low_node) orelse return error.MissingLowPopup, 0),
    );
}

// A placed subtree paints from its own nodes' boxes, so a child laid out
// OUTSIDE its content root's box paints in that band's layer like any other
// node. Gating the placement on `Placement.rect` — a box the painter never
// consults — handed that child to a lower-band popup drawn beneath it.
test "api-w16 a placed child overflowing its content root still owns the press" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tree = widget.WidgetTree.init(allocator);
    defer tree.deinit();
    // The two popups are placed at DIFFERENT heights so their boxes do not
    // coincide: the low popup sits at y 20..60, the high popup at y 60..100.
    try tree.appendNode(.{
        .id = anchor_node,
        .widget_id = anchor_id,
        .kind = .{ .button = .{ .label = "Anchor" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 25, .h = 10 },
    });
    try appendPopup(&tree, low_node, low_id, 1);
    // A child whose box starts ABOVE its content root and runs far below it,
    // so it covers the low popup's box while lying outside its own. The
    // popup's `overflow` stays visible, so the painter emits it unclipped.
    try tree.appendNode(.{
        .id = spill_node,
        .kind = .{ .label = .{ .text = "Spill" } },
        .parent = high_node,
        .rect = .{ .x = 0, .y = -60, .w = 60, .h = 260 },
        .paint = .{ .fill = .{ 0.5, 0.5, 0.6, 1 } },
    });
    try appendPopup(&tree, high_node, high_id, 1);
    var frame = overlay.Frame.init(gpa);
    defer frame.deinit();
    const spill_records = [_]overlay.Record{
        .{ .anchor = anchor_id, .content = low_id, .priority = 1, .clip = .window_escape },
        .{ .anchor = anchor_id, .content = high_id, .priority = 7, .gap = 40, .clip = .window_escape },
    };
    try resolveFrame(&frame, &tree, .{ .w = 200, .h = 200 }, &spill_records);

    const low_box = widget.visualBorderRect(&tree, low_node);
    const high_box = widget.visualBorderRect(&tree, high_node);
    const spill_box = widget.visualBorderRect(&tree, spill_node);
    // The probe is inside the spill child's box, inside the LOW popup's box,
    // and OUTSIDE the high popup's own placed rect.
    const probe: [2]f32 = .{ low_box.x + low_box.w / 2, low_box.y + low_box.h / 2 };
    try std.testing.expect(spill_box.x <= probe[0] and probe[0] < spill_box.x + spill_box.w);
    try std.testing.expect(spill_box.y <= probe[1] and probe[1] < spill_box.y + spill_box.h);
    try std.testing.expect(probe[1] < high_box.y or probe[1] >= high_box.y + high_box.h);
    try std.testing.expect(high_box.y >= low_box.y + low_box.h);

    // PAINT: the painter ranks the spill child by its own band's layer, so it
    // is the topmost thing at the probe — above the low popup it covers.
    const spill_layer = try widget.effectiveLayer(
        tree.nodeConst(spill_node) orelse return error.MissingSpill,
        0,
    );
    try std.testing.expectEqual(spill_layer, try topLayerAt(gpa, &tree, probe));
    try std.testing.expect(spill_layer > try widget.effectiveLayer(
        tree.nodeConst(low_node) orelse return error.MissingLowPopup,
        0,
    ));

    // INPUT: routing ranks by that same band, so the topmost-painted overlay
    // owns the press instead of falling through to the low popup beneath it.
    try std.testing.expectEqual(spill_node, frame.hitTest(&tree, probe).?);
    try std.testing.expectEqual(spill_node, frame.hitTestTotal(&tree, probe).?);
    // The plain tree walk knows nothing of bands and still names the low
    // popup's subtree, which is exactly why routing cannot delegate to it.
    try std.testing.expect(frame.hitTest(&tree, probe).? != input.hitTest(&tree, probe).?);
}

const spill_node: FrameNodeId = @fromBackingInt(@intCast(20));

// A DORMANT record is inert for PAINT and for TOTAL input, and the stable /
// actionable walks may not name it either: it is published to no
// accessibility client and painted nowhere, so no press and no accessibility
// action can address it.
test "api-w16 an unplaced record is inert for paint, total input and stable routing" {
    var scroll: widget.ScrollState = .{};
    var tree = try treeWithoutAnchor(std.testing.allocator, &scroll);
    defer tree.deinit();
    try appendOrdinary(&tree);
    var frame = overlay.Frame.init(std.testing.allocator);
    defer frame.deinit();
    // The record still names real, published, visible content — only its
    // anchor is gone, which is what makes the record unplaced.
    try resolveFrame(&frame, &tree, .{ .w = 100, .h = 100 }, &[_]overlay.Record{.{
        .anchor = anchor_id,
        .content = popup_id,
    }});

    const box = widget.visualBorderRect(&tree, popup_node);
    const point: [2]f32 = .{ box.x + box.w / 2, box.y + box.h / 2 };
    try std.testing.expect(tree.nodeConst(popup_node).?.overlay_dormant);
    try std.testing.expect(frame.placement(&tree, popup_id) == null);

    // PAINT: the dismissed box reaches no command list at all.
    var commands: std.ArrayList(drawcmd.DrawCmd) = .empty;
    defer commands.deinit(std.testing.allocator);
    try commands.ensureTotalCapacity(
        std.testing.allocator,
        try drawcmd.requiredCapacity(&tree),
    );
    try drawcmd.collectDrawCmdsInto(&tree, null, 0, &commands);
    for (commands.items) |cmd| {
        try std.testing.expect(!std.meta.eql(cmd.rect, box));
    }

    // TOTAL INPUT: the point belongs to the frame's own container, through
    // the tree walk and through the App's routing answer alike.
    try std.testing.expectEqual(scroll_node, input.hitTest(&tree, point).?);
    try std.testing.expectEqual(scroll_node, frame.hitTestTotal(&tree, point).?);
    try std.testing.expect(frame.hitTest(&tree, point) == null);
    // The dismissed popup's own stable node is not a press target, and the
    // stable walk cannot escape to a handle outside the point either.
    try std.testing.expect(!input.isEnabled(&tree, popup_node));
    const stable_at_point = frame.hitStableTotal(&tree, point);
    try std.testing.expect(stable_at_point == null or !stable_at_point.?.eql(popup_id));
    try std.testing.expect(frame.hitActionableTotal(&tree, point) != popup_node);
    // The ordinary control below it is untouched and still fully routable.
    const ordinary_box = widget.visualBorderRect(&tree, ordinary_node);
    const ordinary_point: [2]f32 = .{
        ordinary_box.x + ordinary_box.w / 2,
        ordinary_box.y + ordinary_box.h / 2,
    };
    try std.testing.expectEqual(
        ordinary_id,
        frame.hitStableTotal(&tree, ordinary_point).?,
    );
    try std.testing.expectEqual(
        ordinary_node,
        frame.hitActionableTotal(&tree, ordinary_point).?,
    );
}

// A press that lands on placed content must resolve its stable handle and its
// actionable node INSIDE that band. Walking the whole parent chain let a
// popup's unkeyed leaf name a handle outside the popup — the very target the
// frame drew something over — and activate it.
test "api-w16 a placed press resolves inside its own band, never the underlay" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tree = widget.WidgetTree.init(allocator);
    defer tree.deinit();
    try tree.appendNode(.{
        .id = anchor_node,
        .widget_id = anchor_id,
        .kind = .{ .button = .{ .label = "Anchor" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 25, .h = 10 },
    });
    // The ordinary keyed button the popup is placed OVER.
    try appendOrdinary(&tree);
    // The popup's content root is keyed; its child is not. A press on the
    // child must resolve to the popup's own handle, and must not walk past
    // the content root out to the application button underneath.
    try tree.appendNode(.{
        .id = nested_node,
        .kind = .{ .label = .{ .text = "Item" } },
        .parent = popup_node,
        .rect = .{ .x = 2, .y = 2, .w = 20, .h = 10 },
        .paint = .{ .fill = .{ 0.4, 0.4, 0.5, 1 } },
    });
    try tree.appendNode(.{
        .id = popup_node,
        .widget_id = popup_id,
        .kind = .{ .button = .{ .label = "Popup" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 60, .h = 40 },
        .paint = .{ .fill = .{ 0.2, 0.22, 0.3, 1 } },
    });
    var frame = overlay.Frame.init(gpa);
    defer frame.deinit();
    try resolveFrame(&frame, &tree, .{ .w = 200, .h = 200 }, &[_]overlay.Record{.{
        .anchor = anchor_id,
        .content = popup_id,
        .clip = .window_escape,
    }});

    const child_box = widget.visualBorderRect(&tree, nested_node);
    const child_point: [2]f32 = .{
        child_box.x + child_box.w / 2,
        child_box.y + child_box.h / 2,
    };
    // The routed node is the popup's own unkeyed child...
    try std.testing.expectEqual(nested_node, frame.hitTestTotal(&tree, child_point).?);
    // ...and the stable walk names the POPUP, the only keyed node in band.
    try std.testing.expectEqual(
        popup_id,
        frame.hitStableTotal(&tree, child_point).?,
    );
    // A label is not actionable, and the walk must not escape the band to
    // find the popup's button ancestor OR the application button below.
    try std.testing.expectEqual(
        popup_node,
        frame.hitActionableTotal(&tree, child_point).?,
    );
    try std.testing.expect(frame.hitActionableTotal(&tree, child_point).? != ordinary_node);

    // Outside the popup the ordinary button still answers, so the in-band
    // walk did not narrow ordinary routing.
    const ordinary_box = widget.visualBorderRect(&tree, ordinary_node);
    const ordinary_point: [2]f32 = .{
        ordinary_box.x + ordinary_box.w / 2,
        ordinary_box.y + ordinary_box.h / 2,
    };
    try std.testing.expectEqual(
        ordinary_id,
        frame.hitStableTotal(&tree, ordinary_point).?,
    );
    try std.testing.expectEqual(
        ordinary_node,
        frame.hitActionableTotal(&tree, ordinary_point).?,
    );
}
