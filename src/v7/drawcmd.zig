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
//! Bordered nodes (any box.border side > 0) emit a ring cmd first (the
//! full absolute border box, box.border_color, ring = true), then the
//! fill cmd (border box inset by the border, palette color, ring = false).
//! A bordered label emits only the ring; a spacer emits nothing.
//!
//! Painted nodes with box.shadow > 0 emit a shadow cmd FIRST — the
//! absolute border box dropped (+2, +3) px in soft black (alpha 0.28),
//! feathered by box.shadow — so the shadow paints behind the ring and
//! fill. `shadow > 0` marks the cmd as a shadow cmd to the renderer.
//! Every cmd a node emits carries its box's paint-only `shadow` /
//! `gradient` fields.
//!
//! Nodes whose rect has w == 0 or h == 0 are skipped: nothing to paint.

const std = @import("std");

const Id = @import("id.zig").Id;
const Rect = @import("widget.zig").Rect;
const Box = @import("widget.zig").Box;
const WidgetTree = @import("widget.zig").WidgetTree;
const absoluteRect = @import("widget.zig").absoluteRect;

/// One paint command: a solid fill (`ring = false`) or a border ring
/// (`ring = true`). `box` carries the node's box model so the renderer can
/// derive corner radii per axis.
pub const DrawCmd = struct {
    rect: Rect,
    color: [4]f32, // sRGB, alpha 1
    kind: enum { solid },
    box: Box = .{},
    ring: bool = false,
    /// Paint-only: drop-shadow softness in px (0 = none). A cmd with
    /// `shadow > 0` is a shadow cmd: the renderer feathers it into a
    /// rounded-rect shadow behind the node (the box radius feeds the
    /// corner radius).
    shadow: f32 = 0,
    /// Paint-only: the gradient's bottom color in Oklab (all-zero = flat
    /// fill). Copied from the node's box onto every cmd the node emits.
    gradient: [4]f32 = .{ 0, 0, 0, 0 },
};

const palette = struct {
    const container: [4]f32 = .{ 0.13, 0.14, 0.16, 1 };
    const button: [4]f32 = .{ 0.25, 0.35, 0.55, 1 };
    const button_pressed: [4]f32 = .{ 0.17, 0.25, 0.42, 1 };
    const slider: [4]f32 = .{ 0.2, 0.2, 0.22, 1 };
};

/// Convert a laid-out tree into paint-ordered DrawCmds (parents BEFORE
/// children — iterate the post-order array REVERSED). Each node's RELATIVE
/// rect is resolved to its ABSOLUTE border box first. Bordered nodes emit
/// their ring before their fill. Returns a slice allocated from
/// `allocator`; caller frees.
pub fn collectDrawCmds(tree: *const WidgetTree, pressed_id: ?Id, allocator: std.mem.Allocator, press_alpha: f32) ![]DrawCmd {
    var list: std.ArrayList(DrawCmd) = .empty;
    defer list.deinit(allocator);

    const nodes = tree.nodes.items;
    var i: usize = nodes.len;
    while (i > 0) {
        i -= 1;
        const node = &nodes[i];

        // Node rects are parent-relative; resolve to surface space. Skip
        // non-positive rects (negative rects are rare — the shrink-clamp
        // fix upstream — but the renderer must never emit them).
        const abs = absoluteRect(tree, node.id);
        if (abs.w <= 0 or abs.h <= 0) continue;

        const b = node.box;
        const base_color: ?[4]f32 = switch (node.kind) {
            .column, .row => palette.container,
            .button => palette.button,
            .slider => palette.slider,
            .label => null, // no fill — the glyph strokes carry the label
            .spacer => null, // spacer paints nothing
        };
        const painted = base_color != null;

        // Shadow first — paints behind everything else for this node: the
        // absolute border box dropped (+2, +3) px, soft black at 28%
        // alpha, feathered by box.shadow (the box's radius feeds the
        // shadow's corner radius). Only painted nodes cast shadows;
        // `shadow > 0` marks the cmd as a shadow cmd to the renderer.
        if (painted and b.shadow > 0) {
            try list.append(allocator, .{
                .rect = Rect{ .x = abs.x + 2, .y = abs.y + 3, .w = abs.w, .h = abs.h },
                .color = .{ 0, 0, 0, 0.28 },
                .kind = .solid,
                .box = b,
                .ring = false,
                .shadow = b.shadow,
                .gradient = b.gradient,
            });
        }

        const bordered = b.border.top > 0 or b.border.right > 0 or
            b.border.bottom > 0 or b.border.left > 0;

        // Ring next (paints behind the fill and the children).
        if (bordered and node.kind != .spacer) {
            try list.append(allocator, .{
                .rect = abs,
                .color = b.border_color,
                .kind = .solid,
                .box = b,
                .ring = true,
                .shadow = b.shadow,
                .gradient = b.gradient,
            });
        }

        const c = base_color orelse continue;
        // The held-down button eases from its normal fill to the darker
        // pressed palette color by press_alpha (1 = fully pressed; the
        // core drives the eased value, so the fill tracks the press-in
        // animation instead of snapping).
        const color: [4]f32 = if (pressed_id != null and pressed_id.? == node.id and node.kind == .button)
            lerp4(c, palette.button_pressed, press_alpha)
        else
            c;

        // Fill = border box inset by the border (ring area stays clear).
        // Skip fills the border fully consumes (zero/negative size).
        const fill_rect = Rect{
            .x = abs.x + b.border.left,
            .y = abs.y + b.border.top,
            .w = @max(0, abs.w - b.border.left - b.border.right),
            .h = @max(0, abs.h - b.border.top - b.border.bottom),
        };
        if (fill_rect.w <= 0 or fill_rect.h <= 0) continue;
        try list.append(allocator, .{
            .rect = fill_rect,
            .color = color,
            .kind = .solid,
            .box = b,
            .ring = false,
            .shadow = b.shadow,
            .gradient = b.gradient,
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
    defer tree.nodes.deinit(std.testing.allocator);

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

    const cmds = try collectDrawCmds(&tree, null, std.testing.allocator, 0);
    defer std.testing.allocator.free(cmds);

    // column + button; labels and spacer produce no cmd.
    try std.testing.expectEqual(@as(usize, 2), cmds.len);

    const col_rect = Rect{ .x = 0, .y = 0, .w = 100, .h = 200 };
    const l1_rect = Rect{ .x = 10, .y = 10, .w = 80, .h = 20 };
    const l2_rect = Rect{ .x = 10, .y = 40, .w = 80, .h = 20 };
    const btn_rect = Rect{ .x = 10, .y = 70, .w = 80, .h = 30 };

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
    defer tree.nodes.deinit(std.testing.allocator);

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

    const cmds = try collectDrawCmds(&tree, null, std.testing.allocator, 0);
    defer std.testing.allocator.free(cmds);

    const col_rect = Rect{ .x = 0, .y = 0, .w = 100, .h = 200 };
    const btn_rect = Rect{ .x = 10, .y = 70, .w = 80, .h = 30 };

    const col_idx = indexOfRect(cmds, col_rect) orelse return error.MissingColumnCmd;
    const btn_idx = indexOfRect(cmds, btn_rect) orelse return error.MissingButtonCmd;

    try expectColor(cmds[col_idx].color, palette.container);
    try expectColor(cmds[btn_idx].color, palette.button);
}

test "collectDrawCmds: pressed button fill eases to the pressed color at press_alpha 1" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const btn: Id = @enumFromInt(1);
    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 30 },
    });

    // press_alpha 1: the old instant-swap behavior, fully pressed color.
    const cmds = try collectDrawCmds(&tree, btn, std.testing.allocator, 1);
    defer std.testing.allocator.free(cmds);

    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    try expectColor(cmds[0].color, palette.button_pressed);
}

test "collectDrawCmds: pressed button fill is the midpoint at press_alpha 0.5" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const btn: Id = @enumFromInt(1);
    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 30 },
    });

    const cmds = try collectDrawCmds(&tree, btn, std.testing.allocator, 0.5);
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
    defer tree.nodes.deinit(std.testing.allocator);

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

    const cmds = try collectDrawCmds(&tree, null, std.testing.allocator, 0);
    defer std.testing.allocator.free(cmds);

    // Only the column and the full-size button remain.
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 200 }, cmds[0].rect);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 80, .h = 20 }, cmds[1].rect);
}

test "collectDrawCmds: empty tree yields zero cmds" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const cmds = try collectDrawCmds(&tree, null, std.testing.allocator, 0);
    defer std.testing.allocator.free(cmds);

    try std.testing.expectEqual(@as(usize, 0), cmds.len);
}

test "collectDrawCmds: bordered button emits ring then fill with exact rects" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const btn: Id = @enumFromInt(1);
    const box = Box{
        .border = .{ .top = 1, .right = 2, .bottom = 3, .left = 4 },
        .border_color = .{ 1, 0, 0, 1 },
    };
    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 30 },
        .box = box,
    });

    const cmds = try collectDrawCmds(&tree, null, std.testing.allocator, 0);
    defer std.testing.allocator.free(cmds);

    // Ring cmd first: the full absolute border box, border color.
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expect(cmds[0].ring);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 80, .h = 30 }, cmds[0].rect);
    try expectColor(cmds[0].color, .{ 1, 0, 0, 1 });
    try std.testing.expectEqual(box, cmds[0].box);

    // Fill cmd second: the border box inset by the border, palette color.
    try std.testing.expect(!cmds[1].ring);
    try std.testing.expectEqual(Rect{ .x = 14, .y = 11, .w = 80 - 6, .h = 30 - 4 }, cmds[1].rect);
    try expectColor(cmds[1].color, palette.button);
    try std.testing.expectEqual(box, cmds[1].box);
}

test "collectDrawCmds: nested node under a column resolves to its absolute rect" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

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

    const cmds = try collectDrawCmds(&tree, null, std.testing.allocator, 0);
    defer std.testing.allocator.free(cmds);

    // Column at absolute (5,5); the button's RELATIVE (5,5) resolves to
    // absolute (10,10) = input + the column offset.
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expectEqual(Rect{ .x = 5, .y = 5, .w = 100, .h = 200 }, cmds[0].rect);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 20, .h = 10 }, cmds[1].rect);
}

test "collectDrawCmds: shadowed node emits one shadow cmd first with offset rect and shadow color" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const btn: Id = @enumFromInt(1);
    const box = Box{ .shadow = 3 };
    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 30 },
        .box = box,
    });

    const cmds = try collectDrawCmds(&tree, null, std.testing.allocator, 0);
    defer std.testing.allocator.free(cmds);

    // Shadow cmd first: the absolute border box translated (+2, +3), soft
    // black at 28% alpha, feathered by box.shadow; then the plain fill.
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expect(!cmds[0].ring);
    try std.testing.expectEqual(@as(f32, 3), cmds[0].shadow);
    try std.testing.expectEqual(Rect{ .x = 12, .y = 13, .w = 80, .h = 30 }, cmds[0].rect);
    try expectColor(cmds[0].color, .{ 0, 0, 0, 0.28 });
    try std.testing.expectEqual(box, cmds[0].box);

    // Fill second: the un-offset border box, palette color, and the box's
    // paint-only fields carried over.
    try std.testing.expect(!cmds[1].ring);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 80, .h = 30 }, cmds[1].rect);
    try expectColor(cmds[1].color, palette.button);
    try std.testing.expectEqual(@as(f32, 3), cmds[1].shadow);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, cmds[1].gradient);
}

test "collectDrawCmds: bordered label emits exactly one ring cmd" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const lbl: Id = @enumFromInt(1);
    const box = Box{
        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
        .border_color = .{ 0.42, 0.42, 0.48, 1 },
    };
    try tree.nodes.append(std.testing.allocator, .{
        .id = lbl,
        .kind = .{ .label = .{ .text = "hi" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 24 },
        .box = box,
    });

    const cmds = try collectDrawCmds(&tree, null, std.testing.allocator, 0);
    defer std.testing.allocator.free(cmds);

    // One ring, no fill: the label's own background is unpainted.
    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    try std.testing.expect(cmds[0].ring);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 40, .h = 24 }, cmds[0].rect);
    try expectColor(cmds[0].color, .{ 0.42, 0.42, 0.48, 1 });
    try std.testing.expectEqual(box, cmds[0].box);
}
