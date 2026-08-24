//! v7 draw command list — bridge from the laid-out tree to a flat,
//! paint-ordered list of DrawCmds (the FrameData boundary; v6 lineage).
//!
//! Node rects are RELATIVE (border boxes, positioned relative to the
//! parent's CONTENT box); every node is resolved to its ABSOLUTE border
//! box via widget.absoluteRect before emitting.
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
//!
//! Bordered nodes (any Style.border side > 0) emit a ring cmd first (the
//! full absolute border box, PaintStyle.border_color, ring = true), then the
//! fill cmd (border box inset by the border, palette color, ring = false).
//! A bordered label emits only the ring; a spacer emits nothing.
//!
//! Painted nodes with PaintStyle.shadow > 0 emit a shadow cmd FIRST — the
//! absolute border box dropped (+2, +3) px in soft black (alpha 0.28),
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
const Style = @import("widget.zig").Style;
const PaintStyle = @import("widget.zig").PaintStyle;
const WidgetTree = @import("widget.zig").WidgetTree;
const absoluteRect = @import("widget.zig").absoluteRect;

/// One paint command: a solid fill (`ring = false`) or a border ring
/// (`ring = true`). Typed `style` and `paint` values carry the geometry and
/// visual data required by the renderer.
pub const DrawCmd = struct {
    rect: Rect,
    color: [4]f32, // sRGB, alpha 1
    kind: enum { solid },
    style: Style = .{},
    paint: PaintStyle = .{},
    ring: bool = false,
    /// Clip id: index into the frame's clip-rect list (WidgetTree.
    /// clip_rects); 0xFFFFFFFF = no clip. Stamped by collectDrawCmds from
    /// the enclosing `.clip` containers.
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

/// One clip-stack entry: a `.clip` container that is currently open
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
        if (cur == container) return true;
        const n = tree.nodeConst(cur) orelse return false;
        cur = n.parent;
    }
    return false;
}

/// Convert a laid-out tree into paint-ordered DrawCmds (parents BEFORE
/// children — iterate the post-order array REVERSED). Each node's RELATIVE
/// rect is resolved to its ABSOLUTE border box first. Bordered nodes emit
/// their ring before their fill. Returns a slice allocated from
/// `allocator`; caller frees.
///
/// The clip pass: `.clip` containers push their absolute border box onto
/// the tree's per-frame clip-rect list; every cmd emitted inside the
/// container (its own + its descendants') carries the container's clip id
/// (the deepest enclosing one for nesting). The tree must be mutable:
/// the walk appends clip rects and stamps each node's `clip_id` (the
/// renderer clips the node's glyphs with it).
pub fn collectDrawCmds(allocator: std.mem.Allocator, tree: *WidgetTree, pressed_id: ?Id, press_alpha: f32) ![]DrawCmd {
    const zone = tracy.Zone.begin(.{ .name = "collectDrawCmds", .src = @src() });
    defer zone.end();
    var list: std.ArrayList(DrawCmd) = .empty;
    const capacity = std.math.mul(usize, tree.nodes.items.len, 3) catch return error.OutOfMemory;
    try list.ensureTotalCapacity(allocator, capacity);
    defer list.deinit(allocator);
    // Clip stack: mirrors the enclosing clip-marked containers. The
    // reversed walk meets a container before its subtree, so a clip
    // container's entry is pushed when the container is reached and
    // popped once the walk leaves its subtree (the pop loop below).
    // SAFETY: entries are written before any read; clip_len tracks the
    // filled count.
    var clip_stack: [64]ClipStackEntry = undefined;
    var clip_len: u32 = 0;

    const nodes = tree.nodes.items;
    var i: usize = nodes.len;
    while (i > 0) {
        i -= 1;
        const node = &nodes[i];
        const abs = absoluteRect(tree, node.id);

        // Pop enclosing clip containers that no longer contain this node.
        while (clip_len > 0 and !clipContains(tree, clip_stack[clip_len - 1].container, node.id)) {
            clip_len -= 1;
        }
        // A clip-marked container opens a clip for itself and its subtree.
        if (node.paint.clip and abs.w > 0 and abs.h > 0) {
            if (tree.pushClipRect(.{ .x = abs.x, .y = abs.y, .w = abs.w, .h = abs.h })) |cid| {
                std.debug.assert(clip_len < clip_stack.len); // nesting beyond 64 clip containers
                clip_stack[clip_len] = .{ .container = node.id, .clip_id = cid };
                clip_len += 1;
            }
        }
        const clip_id: u32 = if (clip_len > 0) clip_stack[clip_len - 1].clip_id else no_clip;
        node.clip_id = clip_id;

        // Node rects are parent-relative; resolve to surface space. Skip
        // non-positive rects (negative rects are rare — the shrink-clamp
        // fix upstream — but the renderer must never emit them).
        if (abs.w <= 0 or abs.h <= 0) continue;

        const resolved_style = node.style;
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
        // absolute border box dropped (+2, +3) px, soft black at 28%
        // alpha, feathered by PaintStyle.shadow. Only painted nodes cast
        // shadows; `shadow > 0` marks a shadow cmd for the renderer.
        if (painted and paint.shadow > 0) {
            try list.append(allocator, .{
                .rect = Rect{ .x = abs.x + 2, .y = abs.y + 3, .w = abs.w, .h = abs.h },
                .color = .{ 0, 0, 0, 0.28 },
                .kind = .solid,
                .style = resolved_style,
                .paint = paint,
                .ring = false,
                .clip_id = clip_id,
            });
        }

        const bordered = resolved_style.border.top > 0 or resolved_style.border.right > 0 or
            resolved_style.border.bottom > 0 or resolved_style.border.left > 0;

        // Ring next (paints behind the fill and the children).
        if (bordered and node.kind != .spacer) {
            try list.append(allocator, .{
                .rect = abs,
                .color = paint.border_color,
                .kind = .solid,
                .style = resolved_style,
                .paint = paint,
                .ring = true,
                .clip_id = clip_id,
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
            .x = abs.x + resolved_style.border.left,
            .y = abs.y + resolved_style.border.top,
            .w = @max(0, abs.w - resolved_style.border.left - resolved_style.border.right),
            .h = @max(0, abs.h - resolved_style.border.top - resolved_style.border.bottom),
        };
        if (fill_rect.w <= 0 or fill_rect.h <= 0) continue;
        try list.append(allocator, .{
            .rect = fill_rect,
            .color = color,
            .kind = .solid,
            .style = resolved_style,
            .paint = paint,
            .ring = false,
            .clip_id = clip_id,
            .tex_idx = tex_idx,
        });
    }
    return list.toOwnedSlice(allocator);
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
    const resolved_style: Style = .{
        .border = .{ .top = 1, .right = 2, .bottom = 3, .left = 4 },
    };
    const paint: PaintStyle = .{ .border_color = .{ 1, 0, 0, 1 } };
    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 30 },
        .style = resolved_style,
        .paint = paint,
    });

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);

    // Ring cmd first: the full absolute border box, border color.
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expect(cmds[0].ring);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 80, .h = 30 }, cmds[0].rect);
    try expectColor(cmds[0].color, .{ 1, 0, 0, 1 });
    try std.testing.expectEqual(resolved_style, cmds[0].style);
    try std.testing.expectEqual(paint, cmds[0].paint);

    // Fill cmd second: the border box inset by the border, palette color.
    try std.testing.expect(!cmds[1].ring);
    try std.testing.expectEqual(Rect{ .x = 14, .y = 11, .w = 80 - 6, .h = 30 - 4 }, cmds[1].rect);
    try expectColor(cmds[1].color, palette.button);
    try std.testing.expectEqual(resolved_style, cmds[1].style);
    try std.testing.expectEqual(paint, cmds[1].paint);
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
    const resolved_style: Style = .{
        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
    };
    const paint: PaintStyle = .{ .layer = 2, .shadow = 3 };
    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 30 },
        .style = resolved_style,
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
    const resolved_style: Style = .{
        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
    };
    const paint: PaintStyle = .{ .border_color = .{ 0.42, 0.42, 0.48, 1 } };
    try tree.nodes.append(std.testing.allocator, .{
        .id = lbl,
        .kind = .{ .label = .{ .text = "hi" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 24 },
        .style = resolved_style,
        .paint = paint,
    });

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);

    // One ring, no fill: the label's own background is unpainted.
    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    try std.testing.expect(cmds[0].ring);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 40, .h = 24 }, cmds[0].rect);
    try expectColor(cmds[0].color, .{ 0.42, 0.42, 0.48, 1 });
    try std.testing.expectEqual(resolved_style, cmds[0].style);
    try std.testing.expectEqual(paint, cmds[0].paint);
}

test "collectDrawCmds: a .clip container stamps its clip id on its own and descendants' cmds, then pops for siblings" {
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

    // The clip list holds the card's absolute border box as id 0.
    try std.testing.expectEqual(@as(u32, 1), tree.clip_count);
    try std.testing.expectEqual(@as(f32, 10), tree.clip_rects[0].x);
    try std.testing.expectEqual(@as(f32, 10), tree.clip_rects[0].y);
    try std.testing.expectEqual(@as(f32, 60), tree.clip_rects[0].w);
    try std.testing.expectEqual(@as(f32, 40), tree.clip_rects[0].h);

    // Three fills: the card (at 10,10), the inner button (at 10,10 too —
    // the card's content origin), and the sibling (at 100). The card's own
    // fill and the inner button carry clip id 0; the sibling is ~0.
    try std.testing.expectEqual(@as(usize, 3), cmds.len);
    for (cmds) |c| {
        if (c.rect.x == 100) {
            try std.testing.expectEqual(no_clip, c.clip_id);
        } else {
            try std.testing.expectEqual(@as(u32, 0), c.clip_id);
        }
    }

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

    // The button's fill (absolute 5,5 — inside the inner clip) carries the
    // inner id; the outer's own fill (0,0) carries the outer id.
    for (cmds) |c| {
        if (c.rect.x == 5) {
            try std.testing.expectEqual(@as(u32, 1), c.clip_id);
        } else {
            try std.testing.expectEqual(@as(u32, 0), c.clip_id);
        }
    }
    try std.testing.expectEqual(@as(u32, 1), tree.node(btn).?.clip_id);
    try std.testing.expectEqual(@as(u32, 0), tree.node(outer).?.clip_id);
}
