//! v7 draw command list — bridge from the laid-out tree to a flat,
//! paint-ordered list of DrawCmds (the FrameData boundary; v6 lineage).
//!
//! Node rects are RELATIVE (border boxes, positioned relative to the
//! parent's CONTENT box); every node is resolved to its VISUAL border
//! box via widget.visualBorderRect before emitting.
//!
//! Paint order: parents BEFORE children. `WidgetTree` stores nodes in
//! post-order (descendants first, containers last), so iterating the node
//! array in REVERSE yields parents-before-children order directly. Within
//! one node the border ring paints BEFORE its fill (ring behind fill).
//!
//! Color palette (sRGB, alpha = 1):
//!   column / row (container)  {0.13, 0.14, 0.16}   dim background
//!   button                    {0.25, 0.35, 0.55}   accent blue
//!   slider (track)            {0.20, 0.20, 0.22}   dark track
//!   label                     — not painted (glyph strokes carry it)
//!   spacer                    — not painted (skipped entirely)
//! Bordered nodes (any resolved physical border side > 0) emit a ring cmd
//! first (the full visual border box, PaintStyle.border_color, ring = true),
//! then the fill cmd (border box inset by the border, palette color,
//! ring = false). A bordered label emits only the ring; a spacer emits
//! nothing.
//!
//! Painted nodes with PaintStyle.shadow > 0 emit a shadow cmd FIRST — the
//! visual border box dropped (+2, +3) px in soft black (alpha 0.28),
//! feathered by PaintStyle.shadow — so the shadow paints behind the ring and
//! fill. Every cmd a node emits carries its typed style and paint values.
//!
//! Nodes whose rect has w == 0 or h == 0 are skipped: nothing to paint.
//!
//! A node with the `.texture` PaintStyle option emits its FILL with its
//! bindless heap index: the fragment shader's TYPE_TEXTURE branch samples
//! the texture before the material dispatch, so the fill ignores the flat
//! color (painted white = identity tint) and the gradient. The ring and
//! shadow cmds stay untextured.
//!

const std = @import("std");
const tracy = @import("tracy");

const Id = @import("id.zig").Id;
const Rect = @import("widget.zig").Rect;
const Sides = @import("widget.zig").Sides;
const ClipRect = @import("widget.zig").ClipRect;
const Style = @import("widget.zig").Style;
const PaintStyle = @import("widget.zig").PaintStyle;
const WidgetTree = @import("widget.zig").WidgetTree;
const ScrollState = @import("widget.zig").ScrollState;
const visualBorderRect = @import("widget.zig").visualBorderRect;
const visualContentRect = @import("widget.zig").visualContentRect;
const geometryBoxEdges = @import("widget.zig").geometryBoxEdges;
const Overflow = @import("style.zig").Overflow;

/// One paint command: a solid fill (`ring = false`) or a border ring
/// (`ring = true`). Typed `style` and `paint` values carry the geometry and
/// visual data required by the renderer. `border` is the physical border
/// resolved for this node's containing block; it is kept at the render
/// boundary so consumers do not resolve CSS values a second time.
pub const DrawCmd = struct {
    rect: Rect,
    color: [4]f32, // sRGB, alpha 1
    kind: enum { solid },
    style: Style = .{},
    paint: PaintStyle = .{},
    border: Sides = .{},
    ring: bool = false,
    /// Clip id: index into the frame's clip-rect list (WidgetTree.
    /// clip_rects); 0xFFFFFFFF = no clip. Stamped by collectDrawCmds from
    /// the enclosing content-clip containers.
    clip_id: u32 = 0xFFFFFFFF,
    /// Bindless texture heap index. 0xFFFFFFFF = flat fill. Only the FILL
    /// cmd carries it.
    tex_idx: u32 = 0xFFFFFFFF,
};

const palette = struct {
    const container: [4]f32 = .{ 0.13, 0.14, 0.16, 1 };
    const button: [4]f32 = .{ 0.25, 0.35, 0.55, 1 };
    const button_pressed: [4]f32 = .{ 0.17, 0.25, 0.42, 1 };
    const slider: [4]f32 = .{ 0.2, 0.2, 0.22, 1 };
};

/// One content-clip stack entry: a node that is currently open
/// (its subtree is being walked) and the clip id stamped on its cmds.
const ClipStackEntry = struct { container: Id, clip_id: u32 };

/// The no-clip sentinel (matches the shader's `vClipId != 0xFFFFFFFFu`).
const no_clip: u32 = 0xFFFFFFFF;

/// Is `container` an ancestor of `node_id` (or `node_id` itself)? Walks
/// the parent chain — the clip stack pops a container once the walk
/// leaves its subtree (reversed post-order visits a container before its
/// descendants, so the pop is detected on the first node outside it).
fn clipContains(tree: *const WidgetTree, container: Id, node_id: Id) bool {
    var cur = node_id;
    while (cur != .root) {
        tree.addCounter(.ancestor_reads, 1);
        tree.addCounter(.node_comparisons, 1);
        if (cur == container) return true;
        const n = tree.nodeConst(cur) orelse return false;
        cur = n.parent;
    }
    return false;
}
const ClipAxis = struct {
    start: f32,
    extent: f32,
};

fn intersectClipAxis(
    start: f32,
    extent: f32,
    inherited_start: f32,
    inherited_extent: f32,
) ClipAxis {
    const enabled = extent != ClipRect.disabled_extent;
    const inherited_enabled = inherited_extent != ClipRect.disabled_extent;
    if (!enabled and !inherited_enabled) {
        return .{ .start = 0, .extent = ClipRect.disabled_extent };
    }
    if (!enabled) return .{ .start = inherited_start, .extent = inherited_extent };
    if (!inherited_enabled) return .{ .start = start, .extent = extent };

    const intersection_start = @max(start, inherited_start);
    const intersection_end = @min(start + extent, inherited_start + inherited_extent);
    return .{
        .start = intersection_start,
        .extent = @max(0, intersection_end - intersection_start),
    };
}

fn intersectClip(rect: ClipRect, inherited: ClipRect) ClipRect {
    const x = intersectClipAxis(rect.x, rect.w, inherited.x, inherited.w);
    const y = intersectClipAxis(rect.y, rect.h, inherited.y, inherited.h);
    return .{ .x = x.start, .y = y.start, .w = x.extent, .h = y.extent };
}

fn intersectInherited(tree: *const WidgetTree, rect: ClipRect, inherited_id: u32) ClipRect {
    if (inherited_id == no_clip) return rect;
    std.debug.assert(inherited_id < tree.clip_count);
    return intersectClip(rect, tree.clip_rects[inherited_id]);
}

/// Convert a laid-out tree into paint-ordered DrawCmds. The returned slice is
/// allocated from `allocator`; caller frees.
pub fn collectDrawCmds(
    allocator: std.mem.Allocator,
    tree: *WidgetTree,
    pressed_id: ?Id,
    press_alpha: f32,
) ![]DrawCmd {
    var list: std.ArrayList(DrawCmd) = .empty;
    errdefer list.deinit(allocator);
    const capacity = std.math.mul(usize, tree.nodes.items.len, 3) catch return error.OutOfMemory;
    try list.ensureTotalCapacity(allocator, capacity);
    try collectDrawCmdsInto(tree, pressed_id, press_alpha, &list);
    return list.toOwnedSlice(allocator);
}

/// Convert a laid-out tree into paint-ordered DrawCmds in caller-owned storage.
/// The caller must reserve enough capacity before entering a measured loop.
pub fn collectDrawCmdsInto(
    tree: *WidgetTree,
    pressed_id: ?Id,
    press_alpha: f32,
    list: *std.ArrayList(DrawCmd),
) !void {
    const zone = tracy.Zone.begin(.{ .name = "collectDrawCmds", .src = @src() });
    defer zone.end();
    const required_capacity = std.math.mul(usize, tree.nodes.items.len, 3) catch return error.OutOfMemory;
    if (list.capacity < required_capacity) return error.OutOfMemory;
    list.clearRetainingCapacity();
    // Clip stack: mirrors enclosing content clips. Text-overflow clips are
    // appended separately and never enter this stack because they constrain
    // only the current node's glyphs, not its commands or descendants.
    var clip_stack: [64]ClipStackEntry = undefined;
    var clip_len: usize = 0;

    const nodes = tree.nodes.items;
    var i: usize = nodes.len;
    while (i > 0) {
        i -= 1;
        const node = &nodes[i];
        const visual_border = visualBorderRect(tree, node.id);

        while (clip_len > 0 and
            !clipContains(tree, clip_stack[clip_len - 1].container, node.id))
        {
            clip_len -= 1;
        }
        const inherited_clip_id = if (clip_len > 0) clip_stack[clip_len - 1].clip_id else no_clip;
        node.paint_clip_id = inherited_clip_id;
        var content_clip_id = inherited_clip_id;
        const content_clip_axes = node.contentClipAxes();
        if (content_clip_axes.any()) {
            const content_clip = intersectInherited(
                tree,
                ClipRect.fromRect(visual_border, content_clip_axes),
                inherited_clip_id,
            );
            content_clip_id = try tree.pushClipRect(content_clip);
            std.debug.assert(clip_len < clip_stack.len);
            clip_stack[clip_len] = .{ .container = node.id, .clip_id = content_clip_id };
            clip_len += 1;
        }

        const border = (node.resolved_box_edges orelse
            geometryBoxEdges(node, visual_border.w)).border;
        node.clip_id = content_clip_id;
        const text_bearing = switch (node.kind) {
            .label, .slider => true,
            else => false,
        };
        if (text_bearing and node.text_overflow == .clip and
            visual_border.w > 0 and visual_border.h > 0)
        {
            const visual_content = visualContentRect(tree, node.id);
            var text_clip: ClipRect = .{
                .x = visual_content.x,
                .y = visual_content.y,
                .w = visual_content.w,
                .h = visual_content.h,
            };
            if (node.text_max_width) |maximum| {
                if (!std.math.isFinite(maximum) or maximum < 0) return error.InvalidStyle;
                text_clip.w = @min(text_clip.w, maximum);
            }
            text_clip = intersectInherited(tree, text_clip, content_clip_id);
            node.clip_id = try tree.pushClipRect(text_clip);
        }
        if (visual_border.w <= 0 or visual_border.h <= 0) continue;

        const style = node.style;
        const paint = node.paint;
        const base_color: ?[4]f32 = switch (node.kind) {
            .column, .row => palette.container,
            // Transparent buttons retain their hit target without a painted slab.
            .button => if (paint.transparent) null else if (paint.fill[3] > 0) paint.fill else palette.button,
            .slider => palette.slider,
            .label => null, // no fill — the glyph strokes carry the label
            .spacer => null, // spacer paints nothing
        };
        const painted = base_color != null;

        // Shadow first — paints behind everything else for this node: the
        // visual border box dropped (+2, +3) px, soft black at 28% alpha,
        // feathered by PaintStyle.shadow. Only painted nodes cast shadows;
        // `shadow > 0` marks a shadow cmd for the renderer.
        if (painted and paint.shadow > 0) {
            list.appendAssumeCapacity(.{
                .rect = Rect{
                    .x = visual_border.x + 2,
                    .y = visual_border.y + 3,
                    .w = visual_border.w,
                    .h = visual_border.h,
                },
                .color = .{ 0, 0, 0, 0.28 },
                .kind = .solid,
                .style = style,
                .paint = paint,
                .border = border,
                .ring = false,
                .clip_id = inherited_clip_id,
            });
        }

        const bordered = border.top > 0 or border.right > 0 or
            border.bottom > 0 or border.left > 0;

        // Ring next (paints behind the fill and the children).
        if (bordered and node.kind != .spacer) {
            list.appendAssumeCapacity(.{
                .rect = visual_border,
                .color = paint.border_color,
                .kind = .solid,
                .style = style,
                .paint = paint,
                .border = border,
                .ring = true,
                .clip_id = inherited_clip_id,
            });
        }

        const c = base_color orelse continue;
        // A textured fill shows the texture's own pixels: the fragment
        // branch multiplies the sample by vColor (the tint). The
        // MULTIPLICATIVE identity for the Oklab channels is (1,1,1) —
        // Oklab "white" (1,0,0) would zero the sample's a/b chroma and
        // render every texture desaturated. The texture rect carries the
        // registered heap index.
        const tex_idx: u32 = paint.texture orelse 0xFFFFFFFF;
        // The held-down button eases from its normal fill to the darker
        // pressed palette color by press_alpha (1 = fully pressed; the
        // core drives the eased value, so the fill tracks the press-in
        // animation instead of snapping).
        const color: [4]f32 = if (tex_idx != 0xFFFFFFFF)
            .{ 1, 1, 1, 1 } // the identity tint — the texture's own Oklab pixels
        else if (pressed_id != null and pressed_id.? == node.id and node.kind == .button)
            lerp4(c, palette.button_pressed, press_alpha)
        else
            c;

        // Fill = border box inset by the border (ring area stays clear).
        // Skip fills the border fully consumes (zero/negative size).
        const fill_rect: Rect = .{
            .x = visual_border.x + border.left,
            .y = visual_border.y + border.top,
            .w = @max(0, visual_border.w - border.left - border.right),
            .h = @max(0, visual_border.h - border.top - border.bottom),
        };
        if (fill_rect.w <= 0 or fill_rect.h <= 0) continue;
        list.appendAssumeCapacity(.{
            .rect = fill_rect,
            .color = color,
            .kind = .solid,
            .style = style,
            .paint = paint,
            .border = border,
            .ring = false,
            .clip_id = inherited_clip_id,
            .tex_idx = tex_idx,
        });
    }
    return;
}

test "draw command collection counters record node comparisons" {
    var counters: @import("perf_counters.zig").Counters = .{};
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    tree.setCounterSink(&counters);
    const node_id: Id = @enumFromInt(1);
    try tree.appendNode(.{
        .id = node_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .w = 20, .h = 20 },
    });
    var list: std.ArrayList(DrawCmd) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.ensureTotalCapacity(std.testing.allocator, 3);
    try collectDrawCmdsInto(&tree, null, 0, &list);
    try std.testing.expect(tree.nodeConst(node_id) != null);
    const snapshot = try counters.snapshot();
    if (comptime @import("v7_options").perf_counters) {
        try std.testing.expect(snapshot.value(.node_comparisons) > 0);
    } else {
        try std.testing.expectEqual(@as(u64, 0), snapshot.value(.node_comparisons));
    }
}

/// Linear interpolation between two RGBA colors: a + (b - a) * t.
fn lerp4(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    return .{
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3] + (b[3] - a[3]) * t,
    };
}

fn indexOfRect(cmds: []const DrawCmd, r: Rect) ?usize {
    for (cmds, 0..) |cmd, i| {
        if (cmd.rect.x == r.x and cmd.rect.y == r.y and cmd.rect.w == r.w and cmd.rect.h == r.h) return i;
    }
    return null;
}

fn expectColor(actual: [4]f32, expected: [4]f32) !void {
    try std.testing.expectEqualSlices(f32, &expected, &actual);
}

test "collectDrawCmds: paint order — container before children, spacer skipped" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const col: Id = @enumFromInt(1);
    const l1: Id = @enumFromInt(2);
    const l2: Id = @enumFromInt(3);
    const btn: Id = @enumFromInt(4);
    const sp: Id = @enumFromInt(5);

    // Post-order append: children first, container last.
    try tree.nodes.append(std.testing.allocator, .{
        .id = l1,
        .kind = .{ .label = .{ .text = "a" } },
        .parent = col,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 20 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = l2,
        .kind = .{ .label = .{ .text = "b" } },
        .parent = col,
        .rect = .{ .x = 10, .y = 40, .w = 80, .h = 20 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = col,
        .rect = .{ .x = 10, .y = 70, .w = 80, .h = 30 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = sp,
        .kind = .{ .spacer = .{} },
        .parent = col,
        .rect = .{ .x = 10, .y = 120, .w = 80, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = col,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 200 },
    });

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);

    // column + button; labels and spacer produce no cmd.
    try std.testing.expectEqual(@as(usize, 2), cmds.len);

    const col_rect: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 200 };
    const l1_rect: Rect = .{ .x = 10, .y = 10, .w = 80, .h = 20 };
    const l2_rect: Rect = .{ .x = 10, .y = 40, .w = 80, .h = 20 };
    const btn_rect: Rect = .{ .x = 10, .y = 70, .w = 80, .h = 30 };

    const col_idx = indexOfRect(cmds, col_rect) orelse return error.MissingColumnCmd;
    const btn_idx = indexOfRect(cmds, btn_rect) orelse return error.MissingButtonCmd;

    // Parents paint before their children.
    try std.testing.expect(col_idx < btn_idx);

    // Labels are unpainted (glyph strokes carry them); spacer is skipped.
    try std.testing.expectEqual(@as(?usize, null), indexOfRect(cmds, l1_rect));
    try std.testing.expectEqual(@as(?usize, null), indexOfRect(cmds, l2_rect));
}

test "collectDrawCmds: colors — button accent, container dim" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const col: Id = @enumFromInt(1);
    const btn: Id = @enumFromInt(2);

    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = col,
        .rect = .{ .x = 10, .y = 70, .w = 80, .h = 30 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = col,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 200 },
    });

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);

    const col_rect: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 200 };
    const btn_rect: Rect = .{ .x = 10, .y = 70, .w = 80, .h = 30 };

    const col_idx = indexOfRect(cmds, col_rect) orelse return error.MissingColumnCmd;
    const btn_idx = indexOfRect(cmds, btn_rect) orelse return error.MissingButtonCmd;

    try expectColor(cmds[col_idx].color, palette.container);
    try expectColor(cmds[btn_idx].color, palette.button);
}

test "collectDrawCmds: pressed button fill eases to the pressed color at press_alpha 1" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const btn: Id = @enumFromInt(1);
    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 30 },
    });

    // press_alpha 1: the old instant-swap behavior, fully pressed color.
    const cmds = try collectDrawCmds(std.testing.allocator, &tree, btn, 1);
    defer std.testing.allocator.free(cmds);

    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    try expectColor(cmds[0].color, palette.button_pressed);
}

test "collectDrawCmds: pressed button fill is the midpoint at press_alpha 0.5" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const btn: Id = @enumFromInt(1);
    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 30 },
    });

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, btn, 0.5);
    defer std.testing.allocator.free(cmds);

    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    // Each channel = (button[i] + button_pressed[i]) / 2.
    const mid: [4]f32 = .{
        (palette.button[0] + palette.button_pressed[0]) / 2,
        (palette.button[1] + palette.button_pressed[1]) / 2,
        (palette.button[2] + palette.button_pressed[2]) / 2,
        (palette.button[3] + palette.button_pressed[3]) / 2,
    };
    for (cmds[0].color, mid) |got, want| {
        try std.testing.expect(std.math.approxEqAbs(f32, want, got, 1e-5));
    }
}

test "collectDrawCmds: zero-size nodes are skipped" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const col: Id = @enumFromInt(1);
    const btn: Id = @enumFromInt(2);
    const zero_w: Id = @enumFromInt(3);
    const zero_h: Id = @enumFromInt(4);

    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = col,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 20 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = zero_w,
        .kind = .{ .button = .{ .label = "x" } },
        .parent = col,
        .rect = .{ .x = 10, .y = 40, .w = 0, .h = 20 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = zero_h,
        .kind = .{ .button = .{ .label = "y" } },
        .parent = col,
        .rect = .{ .x = 10, .y = 40, .w = 80, .h = 0 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = col,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 200 },
    });

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);

    // Only the column and the full-size button remain.
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 200 }, cmds[0].rect);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 80, .h = 20 }, cmds[1].rect);
}

test "collectDrawCmds: nonpositive nodes keep clip ids but emit no decorations or fills" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const zero_width: Id = @enumFromInt(1);
    const negative_height: Id = @enumFromInt(2);
    const clip: Id = @enumFromInt(3);
    const decorated_style: Style = .{
        .border_inset = .{
            .top = .{ .length = 1 },
            .right = .{ .length = 1 },
            .bottom = .{ .length = 1 },
            .left = .{ .length = 1 },
        },
    };
    const decorated_paint: PaintStyle = .{
        .border_color = .{ 1, 0, 0, 1 },
        .shadow = 3,
    };

    try tree.nodes.append(std.testing.allocator, .{
        .id = zero_width,
        .kind = .{ .button = .{ .label = "zero" } },
        .parent = clip,
        .rect = .{ .x = 4, .y = 4, .w = 0, .h = 20 },
        .style = decorated_style,
        .paint = decorated_paint,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = negative_height,
        .kind = .{ .button = .{ .label = "negative" } },
        .parent = clip,
        .rect = .{ .x = 4, .y = 28, .w = 20, .h = -1 },
        .style = decorated_style,
        .paint = decorated_paint,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = clip,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .paint = .{ .clip = true },
    });
    try tree.appendChild(clip, zero_width);
    try tree.appendChild(clip, negative_height);

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);

    try std.testing.expectEqual(@as(u32, 1), tree.clip_count);
    try std.testing.expectEqual(@as(f32, 0), tree.clip_rects[0].x);
    try std.testing.expectEqual(@as(f32, 0), tree.clip_rects[0].y);
    try std.testing.expectEqual(@as(f32, 100), tree.clip_rects[0].w);
    try std.testing.expectEqual(@as(f32, 100), tree.clip_rects[0].h);
    try std.testing.expectEqual(@as(u32, 0), tree.node(zero_width).?.clip_id);
    try std.testing.expectEqual(@as(u32, 0), tree.node(negative_height).?.clip_id);
    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, cmds[0].rect);
    try std.testing.expect(!cmds[0].ring);
}

test "collectDrawCmds: clipped text intersects its content box with the parent clip" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const label_id: Id = @enumFromInt(1);
    const clip_id: Id = @enumFromInt(2);
    try tree.nodes.append(std.testing.allocator, .{
        .id = label_id,
        .kind = .{ .label = .{ .text = "clipped" } },
        .parent = clip_id,
        .rect = .{ .x = 20, .y = 0, .w = 30, .h = 10 },
        .text_overflow = .clip,
        .text_max_width = 20,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = clip_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 30, .h = 20 },
        .paint = .{ .clip = true },
    });
    try tree.appendChild(clip_id, label_id);

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);

    try std.testing.expectEqual(@as(u32, 2), tree.clip_count);
    try std.testing.expectEqual(
        ClipRect{ .x = 20, .y = 0, .w = 10, .h = 10 },
        tree.clip_rects[1],
    );
    try std.testing.expectEqual(@as(u32, 1), tree.node(label_id).?.clip_id);
    try std.testing.expectEqual(@as(u32, 0), tree.node(label_id).?.paint_clip_id);
    try std.testing.expectEqual(no_clip, tree.node(clip_id).?.paint_clip_id);
}

test "collectDrawCmds: empty tree yields zero cmds" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);

    try std.testing.expectEqual(@as(usize, 0), cmds.len);
}

test "collectDrawCmds: bordered button emits ring then fill with exact rects" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const btn: Id = @enumFromInt(1);
    const style: Style = .{
        .border_inset = .{
            .top = .{ .length = 1 },
            .right = .{ .length = 2 },
            .bottom = .{ .length = 3 },
            .left = .{ .length = 4 },
        },
    };
    const paint: PaintStyle = .{ .border_color = .{ 1, 0, 0, 1 } };
    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 30 },
        .style = style,
        .paint = paint,
    });

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);

    // Ring cmd first: the full absolute border box, border color.
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expect(cmds[0].ring);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 80, .h = 30 }, cmds[0].rect);
    try expectColor(cmds[0].color, .{ 1, 0, 0, 1 });
    try std.testing.expectEqual(style, cmds[0].style);
    try std.testing.expectEqual(Sides{ .top = 1, .right = 2, .bottom = 3, .left = 4 }, cmds[0].border);

    // Fill cmd second: the border box inset by the border, palette color.
    try std.testing.expect(!cmds[1].ring);
    try std.testing.expectEqual(Rect{ .x = 14, .y = 11, .w = 80 - 6, .h = 30 - 4 }, cmds[1].rect);
    try expectColor(cmds[1].color, palette.button);
    try std.testing.expectEqual(style, cmds[1].style);
    try std.testing.expectEqual(Sides{ .top = 1, .right = 2, .bottom = 3, .left = 4 }, cmds[1].border);
}

test "collectDrawCmds: resolved physical border edges drive fill geometry" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const btn: Id = @enumFromInt(1);
    const style: Style = .{
        .border_inset = .{
            .top = .{ .percent = 0.5 },
            .right = .{ .percent = 0.5 },
            .bottom = .{ .percent = 0.5 },
            .left = .{ .percent = 0.5 },
        },
    };
    const resolved_border: Sides = .{
        .top = 1,
        .right = 2,
        .bottom = 3,
        .left = 4,
    };
    const resolved_padding: Sides = .{};
    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 30 },
        .style = style,
        .resolved_box_edges = .{
            .border = resolved_border,
            .padding = resolved_padding,
        },
    });

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);

    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 80, .h = 30 }, cmds[0].rect);
    try std.testing.expectEqual(
        Rect{ .x = 14, .y = 11, .w = 74, .h = 26 },
        cmds[1].rect,
    );
    try std.testing.expectEqual(resolved_border, cmds[0].border);
    try std.testing.expectEqual(resolved_border, cmds[1].border);
}

test "collectDrawCmds: nested node under a column resolves to its absolute rect" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const col: Id = @enumFromInt(1);
    const btn: Id = @enumFromInt(2);

    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = col,
        .rect = .{ .x = 5, .y = 5, .w = 20, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = col,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 5, .y = 5, .w = 100, .h = 200 },
    });

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);

    // Column at absolute (5,5); the button's RELATIVE (5,5) resolves to
    // absolute (10,10) = input + the column offset.
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expectEqual(Rect{ .x = 5, .y = 5, .w = 100, .h = 200 }, cmds[0].rect);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 20, .h = 10 }, cmds[1].rect);
}

test "collectDrawCmds: shadowed node emits one shadow cmd first with offset rect and shadow color" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const btn: Id = @enumFromInt(1);
    const paint: PaintStyle = .{ .shadow = 3 };
    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 30 },
        .paint = paint,
    });

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);

    // Shadow cmd first: the absolute border box translated (+2, +3), soft
    // black at 28% alpha, feathered by PaintStyle.shadow; then the plain fill.
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expect(!cmds[0].ring);
    try std.testing.expectEqual(@as(f32, 3), cmds[0].paint.shadow);
    try std.testing.expectEqual(Rect{ .x = 12, .y = 13, .w = 80, .h = 30 }, cmds[0].rect);
    try expectColor(cmds[0].color, .{ 0, 0, 0, 0.28 });
    try std.testing.expectEqual(paint, cmds[0].paint);

    // Fill second: the un-offset border box, palette color, and typed paint
    // fields carried over.
    try std.testing.expect(!cmds[1].ring);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 80, .h = 30 }, cmds[1].rect);
    try expectColor(cmds[1].color, palette.button);
    try std.testing.expectEqual(@as(f32, 3), cmds[1].paint.shadow);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, cmds[1].paint.gradient);
    try std.testing.expectEqual(paint, cmds[1].paint);
}

test "collectDrawCmds: shadow, ring, and fill share the node's layer" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    // A layered, bordered, shadowed button emits three cmds (shadow, ring,
    // fill) — every one must carry the node's layer key so the drawable
    // bag sorts the whole node as one unit onto its z level.
    const btn: Id = @enumFromInt(1);
    const style: Style = .{
        .border_inset = .{
            .top = .{ .length = 1 },
            .right = .{ .length = 1 },
            .bottom = .{ .length = 1 },
            .left = .{ .length = 1 },
        },
    };
    const paint: PaintStyle = .{ .layer = 2, .shadow = 3 };
    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 30 },
        .style = style,
        .paint = paint,
    });

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);

    try std.testing.expectEqual(@as(usize, 3), cmds.len);
    try std.testing.expectEqual(@as(f32, 3), cmds[0].paint.shadow); // shadow first
    try std.testing.expect(cmds[1].ring);
    try std.testing.expect(!cmds[2].ring);
    for (cmds) |c| try std.testing.expectEqual(@as(u32, 2), c.paint.layer);

    // A plain (unlayered) node's cmds default to layer 0.
    const plain: Id = @enumFromInt(2);
    try tree.nodes.append(std.testing.allocator, .{
        .id = plain,
        .kind = .{ .button = .{ .label = "plain" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 60, .w = 80, .h = 30 },
    });
    const cmds2 = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds2);
    // Reversed post-order: the plain button (appended last) emits first.
    try std.testing.expectEqual(@as(usize, 4), cmds2.len);
    try std.testing.expectEqual(@as(u32, 0), cmds2[0].paint.layer); // plain fill
    for (cmds2[1..]) |c| try std.testing.expectEqual(@as(u32, 2), c.paint.layer);
}

test "collectDrawCmds: bordered label emits exactly one ring cmd" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const lbl: Id = @enumFromInt(1);
    const style: Style = .{
        .border_inset = .{
            .top = .{ .length = 1 },
            .right = .{ .length = 1 },
            .bottom = .{ .length = 1 },
            .left = .{ .length = 1 },
        },
    };
    const paint: PaintStyle = .{ .border_color = .{ 0.42, 0.42, 0.48, 1 } };
    try tree.nodes.append(std.testing.allocator, .{
        .id = lbl,
        .kind = .{ .label = .{ .text = "hi" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 24 },
        .style = style,
        .paint = paint,
    });

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);

    // One ring, no fill: the label's own background is unpainted.
    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    try std.testing.expect(cmds[0].ring);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 40, .h = 24 }, cmds[0].rect);
    try expectColor(cmds[0].color, .{ 0.42, 0.42, 0.48, 1 });
    try std.testing.expectEqual(style, cmds[0].style);
    try std.testing.expectEqual(Sides{ .top = 1, .right = 1, .bottom = 1, .left = 1 }, cmds[0].border);
}

test "collectDrawCmds: a content clip stamps descendants, preserves own paint, then pops for siblings" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    // Post-order: children before containers. A clip-marked column holds
    // a button; a sibling button sits outside the clip.
    const inner_btn: Id = @enumFromInt(1);
    const card: Id = @enumFromInt(2);
    const sibling_btn: Id = @enumFromInt(3);

    try tree.nodes.append(std.testing.allocator, .{
        .id = inner_btn,
        .kind = .{ .button = .{ .label = "in" } },
        .parent = card,
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 20 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = card,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 60, .h = 40 },
        .paint = .{ .clip = true },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = sibling_btn,
        .kind = .{ .button = .{ .label = "out" } },
        .parent = .root,
        .rect = .{ .x = 100, .y = 10, .w = 40, .h = 20 },
    });

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);

    // The clip list holds the card's visual border box as id 0.
    try std.testing.expectEqual(@as(u32, 1), tree.clip_count);
    try std.testing.expectEqual(@as(f32, 10), tree.clip_rects[0].x);
    try std.testing.expectEqual(@as(f32, 10), tree.clip_rects[0].y);
    try std.testing.expectEqual(@as(f32, 60), tree.clip_rects[0].w);
    try std.testing.expectEqual(@as(f32, 40), tree.clip_rects[0].h);

    // Reverse post-order emits sibling, card, then inner button. The card's
    // own fill and the sibling are unclipped; only the descendant inherits
    // the card's content clip.
    try std.testing.expectEqual(@as(usize, 3), cmds.len);
    try std.testing.expectEqual(no_clip, cmds[0].clip_id);
    try std.testing.expectEqual(no_clip, cmds[1].clip_id);
    try std.testing.expectEqual(@as(u32, 0), cmds[2].clip_id);

    // Node clip ids (the glyph path reads these): inside = 0, sibling = ~0.
    try std.testing.expectEqual(@as(u32, 0), tree.node(inner_btn).?.clip_id);
    try std.testing.expectEqual(@as(u32, 0), tree.node(card).?.clip_id);
    try std.testing.expectEqual(no_clip, tree.node(sibling_btn).?.clip_id);
}

test "collectDrawCmds: nested clip containers stamp the deepest enclosing clip" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    // outer (clip) → inner (clip) → button. The button's cmds carry the
    // INNER clip id; both rects are appended (outer id 0, inner id 1).
    const btn: Id = @enumFromInt(1);
    const inner: Id = @enumFromInt(2);
    const outer: Id = @enumFromInt(3);

    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = inner,
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 20 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = inner,
        .kind = .{ .column = .{} },
        .parent = outer,
        .rect = .{ .x = 5, .y = 5, .w = 60, .h = 40 },
        .paint = .{ .clip = true },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = outer,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .paint = .{ .clip = true },
    });

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);

    try std.testing.expectEqual(@as(u32, 2), tree.clip_count);
    try std.testing.expectEqual(@as(f32, 0), tree.clip_rects[0].x);
    try std.testing.expectEqual(@as(f32, 5), tree.clip_rects[1].x);

    // Outer paint is unclipped. Inner paint inherits only the outer clip.
    // The button inherits the inner content clip.
    try std.testing.expectEqual(@as(usize, 3), cmds.len);
    try std.testing.expectEqual(no_clip, cmds[0].clip_id);
    try std.testing.expectEqual(@as(u32, 0), cmds[1].clip_id);
    try std.testing.expectEqual(@as(u32, 1), cmds[2].clip_id);
    try std.testing.expectEqual(@as(u32, 1), tree.node(btn).?.clip_id);
    try std.testing.expectEqual(@as(u32, 0), tree.node(outer).?.clip_id);
}

test "collectDrawCmds: scrolled descendants use visual paint and text clip coordinates" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const label_id: Id = @enumFromInt(1);
    const button_id: Id = @enumFromInt(2);
    const scroll_id: Id = @enumFromInt(3);
    var scroll_state: ScrollState = .{ .offset = .{ 7, 9 } };

    try tree.nodes.append(std.testing.allocator, .{
        .id = label_id,
        .kind = .{ .label = .{ .text = "scrolled text" } },
        .parent = scroll_id,
        .rect = .{ .x = 25, .y = 25, .w = 50, .h = 35 },
        .style = .{
            .border_inset = .{
                .top = .{ .length = 1 },
                .right = .{ .length = 2 },
                .bottom = .{ .length = 3 },
                .left = .{ .length = 4 },
            },
            .padding_inset = .{
                .top = .{ .length = 5 },
                .right = .{ .length = 6 },
                .bottom = .{ .length = 7 },
                .left = .{ .length = 8 },
            },
        },
        .text_overflow = .clip,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = button_id,
        .kind = .{ .button = .{ .label = "inside" } },
        .parent = scroll_id,
        .rect = .{ .x = 15, .y = 10, .w = 10, .h = 8 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = scroll_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 10, .y = 20, .w = 50, .h = 40 },
        .paint = .{ .clip = true },
        .scroll = .{ .state = &scroll_state },
    });
    try tree.appendChild(scroll_id, label_id);
    try tree.appendChild(scroll_id, button_id);

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);
    try std.testing.expectEqual(@as(usize, 3), cmds.len);

    try std.testing.expectEqual(@as(u32, 2), tree.clip_count);
    try std.testing.expectEqual(
        ClipRect{ .x = 10, .y = 20, .w = 50, .h = 40 },
        tree.clip_rects[0],
    );
    // The button's border box moves with the scroll offset before painting.
    try std.testing.expectEqual(
        Rect{ .x = 18, .y = 21, .w = 10, .h = 8 },
        cmds[1].rect,
    );
    try std.testing.expectEqual(@as(u32, 0), cmds[1].clip_id);
    // The label content box is visual (28,36)+(4,1)+(8,5), then intersected
    // with the scrolled ancestor's visual clip (10,20)-(60,60).
    try std.testing.expectEqual(
        ClipRect{ .x = 40, .y = 42, .w = 20, .h = 18 },
        tree.clip_rects[1],
    );
    try std.testing.expectEqual(@as(u32, 1), tree.node(label_id).?.clip_id);
}

test "collectDrawCmds: style overflow modes clip descendants without scroll state" {
    const overflow_modes = [_]Overflow{ .hidden, .clip };

    for (overflow_modes) |overflow_mode| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: Id = @enumFromInt(1);
        const parent_id: Id = @enumFromInt(2);
        try tree.nodes.append(std.testing.allocator, .{
            .id = child_id,
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
        try tree.appendChild(parent_id, child_id);

        try std.testing.expect(!tree.node(parent_id).?.paint.clip);
        try std.testing.expect(tree.node(parent_id).?.scroll == null);
        const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
        defer std.testing.allocator.free(cmds);
        try std.testing.expectEqual(@as(usize, 2), cmds.len);

        try std.testing.expectEqual(@as(u32, 1), tree.clip_count);
        try std.testing.expectEqual(
            ClipRect{ .x = 10, .y = 10, .w = 40, .h = 30 },
            tree.clip_rects[0],
        );
        try std.testing.expectEqual(@as(u32, 0), tree.node(parent_id).?.clip_id);
        try std.testing.expectEqual(@as(u32, 0), tree.node(child_id).?.clip_id);
        try std.testing.expectEqual(@as(u32, 0), cmds[1].clip_id);
    }
}

test "collectDrawCmds: mixed overflow axes retain independent GPU clips" {
    const cases = [_]struct {
        width: Overflow,
        height: Overflow,
        rect: Rect,
        expected: ClipRect,
    }{
        .{
            .width = .clip,
            .height = .visible,
            .rect = .{ .x = 10, .y = 10, .w = 40, .h = 0 },
            .expected = .{ .x = 10, .y = 0, .w = 40, .h = -1 },
        },
        .{
            .width = .visible,
            .height = .hidden,
            .rect = .{ .x = 10, .y = 10, .w = 0, .h = 30 },
            .expected = .{ .x = 0, .y = 10, .w = -1, .h = 30 },
        },
        .{
            .width = .clip,
            .height = .visible,
            .rect = .{ .x = 10, .y = 10, .w = 0, .h = 30 },
            .expected = .{ .x = 10, .y = 0, .w = 0, .h = -1 },
        },
        .{
            .width = .visible,
            .height = .hidden,
            .rect = .{ .x = 10, .y = 10, .w = 40, .h = 0 },
            .expected = .{ .x = 0, .y = 10, .w = -1, .h = 0 },
        },
    };

    for (cases) |case| {
        var tree = WidgetTree.init(std.testing.allocator);
        defer tree.deinit();

        const child_id: Id = @enumFromInt(1);
        const parent_id: Id = @enumFromInt(2);
        try tree.nodes.append(std.testing.allocator, .{
            .id = child_id,
            .kind = .{ .button = .{ .label = "overflowed" } },
            .parent = parent_id,
            .rect = .{ .x = 25, .y = 20, .w = 30, .h = 30 },
        });
        try tree.nodes.append(std.testing.allocator, .{
            .id = parent_id,
            .kind = .{ .column = .{} },
            .parent = .root,
            .rect = case.rect,
            .style = .{
                .overflow = .{ .width = case.width, .height = case.height },
            },
        });
        try tree.appendChild(parent_id, child_id);

        const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
        defer std.testing.allocator.free(cmds);
        try std.testing.expectEqual(@as(u32, 1), tree.clip_count);
        try std.testing.expectEqual(case.expected, tree.clip_rects[0]);
        try std.testing.expectEqual(@as(usize, 1), cmds.len);
        try std.testing.expectEqual(@as(u32, 0), cmds[0].clip_id);
    }
}

test "collectDrawCmds: content overflow does not clip own decorations" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_id: Id = @enumFromInt(1);
    const parent_id: Id = @enumFromInt(2);
    try tree.nodes.append(std.testing.allocator, .{
        .id = child_id,
        .kind = .{ .button = .{ .label = "child" } },
        .parent = parent_id,
        .rect = .{ .x = 5, .y = 5, .w = 10, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = parent_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 40, .h = 30 },
        .style = .{
            .overflow = .{ .width = .hidden, .height = .hidden },
        },
        .paint = .{ .shadow = 4 },
    });
    try tree.appendChild(parent_id, child_id);

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);
    try std.testing.expectEqual(@as(usize, 3), cmds.len);
    try std.testing.expectEqual(no_clip, cmds[0].clip_id);
    try std.testing.expectEqual(no_clip, cmds[1].clip_id);
    try std.testing.expectEqual(@as(u32, 0), cmds[2].clip_id);
    try std.testing.expectEqual(@as(u32, 0), tree.node(parent_id).?.clip_id);
}

test "collectDrawCmdsInto reuses caller-owned storage" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
    });

    var commands: std.ArrayList(DrawCmd) = .empty;
    defer commands.deinit(std.testing.allocator);
    try commands.ensureTotalCapacity(std.testing.allocator, 3);
    const storage = commands.allocatedSlice().ptr;
    const capacity = commands.capacity;

    try collectDrawCmdsInto(&tree, null, 0, &commands);
    try std.testing.expectEqual(@as(usize, 1), commands.items.len);
    try collectDrawCmdsInto(&tree, null, 0, &commands);
    try std.testing.expectEqual(@as(usize, 1), commands.items.len);
    try std.testing.expectEqual(storage, commands.allocatedSlice().ptr);
    try std.testing.expectEqual(capacity, commands.capacity);

    var too_small: std.ArrayList(DrawCmd) = .empty;
    defer too_small.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.OutOfMemory,
        collectDrawCmdsInto(&tree, null, 0, &too_small),
    );
}
