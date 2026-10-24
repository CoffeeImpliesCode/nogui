//! Convert visual border boxes into renderer-neutral paint in tree paint order.
//! Layout and hit boxes remain untransformed. A node paints before its children.
//! Its own content clip applies to descendants and custom content, not its border.
//! Every emitted layer is `widget.effectiveLayer`: the authored local layer,
//! plus a custom record's own bump, raised by the band overlay placement
//! assigned the node. The addition is checked, never clamped, and the
//! authored `paint.layer` itself is left alone so it stays inspectable.
//! Each rectangle retains its authored colors until PaintList resolves the palette.

const std = @import("std");
const tracy = @import("tracy");
const perf_counters = @import("perf_counters.zig");
const v7_options = @import("v7_options");
const frame_paint = @import("paint.zig");

const FrameNodeId = @import("id.zig").FrameNodeId;
const WidgetId = @import("id.zig").WidgetId;
const Rect = @import("widget.zig").Rect;
const Sides = @import("widget.zig").Sides;
const ClipRect = @import("widget.zig").ClipRect;
const Style = @import("widget.zig").Style;
const PaintStyle = @import("widget.zig").PaintStyle;
const WidgetTree = @import("widget.zig").WidgetTree;
const ScrollState = @import("widget.zig").ScrollState;
const visualBorderRect = @import("widget.zig").visualBorderRect;
const contentBoxRect = @import("widget.zig").contentBoxRect;
const geometryBoxEdges = @import("widget.zig").geometryBoxEdges;
const Overflow = @import("style.zig").Overflow;

const widget = @import("widget.zig");
/// One node background or custom element rectangle. `rect_paint` is the
/// renderer-neutral source of truth; PaintList copies borrowed shadow slices
/// into the frame arena and resolves colors before GPU submission.
pub const DrawCmd = struct {
    rect: Rect,
    rect_paint: frame_paint.RectPaint,
    path_paint: ?frame_paint.PathPaint = null,
    image_paint: ?frame_paint.ImagePaint = null,
    /// The clip this command paints under: the node's inherited content clip,
    /// or `no_clip` outside every enclosing clip. The paint records repeat it
    /// as their own `clip_id`, so the GPU clip ABI is unchanged.
    clip_id: u32 = no_clip,
};

const palette = struct {
    const container: [4]f32 = .{ 0.13, 0.14, 0.16, 1 };
    const button: [4]f32 = .{ 0.25, 0.35, 0.55, 1 };
    const button_pressed: [4]f32 = .{ 0.17, 0.25, 0.42, 1 };
    const slider: [4]f32 = .{ 0.2, 0.2, 0.22, 1 };
};

/// One content-clip stack entry: a node that is currently open
/// (its subtree is being walked) and the clip id stamped on its cmds.
const ClipStackEntry = struct { container: FrameNodeId, clip_id: u32 };

/// The no-clip sentinel (matches the shader's `vClipId != 0xFFFFFFFFu`).
const no_clip: u32 = 0xFFFFFFFF;

/// Is `container` an ancestor of `node_id` (or `node_id` itself)? Walks
/// the parent chain — the clip stack pops a container once the walk
/// leaves its subtree (reversed post-order visits a container before its
/// descendants, so the pop is detected on the first node outside it).
fn clipContains(tree: *const WidgetTree, container: FrameNodeId, node_id: FrameNodeId) bool {
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
fn textLeadingInset(kind: widget.WidgetKind) f32 {
    return widget.textInsets(kind).leading;
}

/// Preflight one record per painted node and one per custom painted rectangle.
/// This conservative bound avoids allocation in the hot collector, and it
/// counts exactly the nodes the collector emits: hidden ones and the DORMANT
/// overlay subtrees a record registered but nothing placed.
pub fn requiredCapacity(tree: *const WidgetTree) error{OutOfMemory}!usize {
    var visible_nodes: usize = 0;
    var records: usize = 0;
    for (tree.nodes.items) |node| {
        if (node.paint_hidden or node.overlay_dormant) continue;
        visible_nodes += 1;
        if (node.kind == .element) {
            records = std.math.add(usize, records, node.kind.element.paint_records.items.len) catch
                return error.OutOfMemory;
        }
    }
    const capacity = std.math.add(usize, visible_nodes, records) catch
        return error.OutOfMemory;
    if (capacity > std.math.maxInt(u32)) return error.OutOfMemory;
    return capacity;
}

fn intersectRect(rect: Rect, bounds: Rect) Rect {
    const x = @max(rect.x, bounds.x);
    const y = @max(rect.y, bounds.y);
    return .{
        .x = x,
        .y = y,
        .w = @max(0, @min(rect.x + rect.w, bounds.x + bounds.w) - x),
        .h = @max(0, @min(rect.y + rect.h, bounds.y + bounds.h) - y),
    };
}

/// Convert a laid-out tree into paint-ordered DrawCmds. The returned slice is
/// allocated from `allocator`; caller frees.
///
/// A DORMANT overlay subtree is authored visible and laid out, and emits
/// nothing: it is a record the consumer registered that no anchor resolved,
/// so painting it would show a dismissed popup. The exclusion is the node's
/// own `overlay_dormant` flag, the same one `input.hitTest` and
/// `widget.maximumPaintLayer` read, so paint and routing cannot disagree.
pub fn collectDrawCmds(
    allocator: std.mem.Allocator,
    tree: *WidgetTree,
    pressed_id: ?WidgetId,
    press_alpha: f32,
) ![]DrawCmd {
    var list: std.ArrayList(DrawCmd) = .empty;
    errdefer list.deinit(allocator);
    const capacity = try requiredCapacity(tree);
    try list.ensureTotalCapacity(allocator, capacity);
    try collectDrawCmdsInto(tree, pressed_id, press_alpha, &list);
    return list.toOwnedSlice(allocator);
}

/// Convert a laid-out tree into paint-ordered DrawCmds in caller-owned storage.
/// The caller must reserve enough capacity before entering a measured loop.
pub fn collectDrawCmdsInto(
    tree: *WidgetTree,
    pressed_id: ?WidgetId,
    press_alpha: f32,
    list: *std.ArrayList(DrawCmd),
) !void {
    const zone = tracy.Zone.begin(.{ .name = "collectDrawCmds", .src = @src() });
    defer zone.end();
    const required_capacity = try requiredCapacity(tree);
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

        while (clip_len > 0 and
            !clipContains(tree, clip_stack[clip_len - 1].container, node.id))
        {
            clip_len -= 1;
        }
        if (node.paint_hidden or node.overlay_dormant) continue;
        const visual_border = visualBorderRect(tree, node.id);
        // A clip imposed by overlay placement constrains this node's OWN fill
        // and every descendant, and it never resizes the node. It intersects
        // into the same inherited stack the tree's own overflow clips use, so
        // `WidgetNode.paint_clip_id` and `clip_id` keep their meaning and the
        // GPU clip ABI is unchanged.
        const inherited_clip_id = if (clip_len > 0) clip_stack[clip_len - 1].clip_id else no_clip;
        const placed_clip_id: u32 = if (node.placement_clip) |imposed|
            try tree.pushClipRect(intersectInherited(
                tree,
                imposed,
                inherited_clip_id,
            ))
        else
            inherited_clip_id;
        if (placed_clip_id != inherited_clip_id) {
            std.debug.assert(clip_len < clip_stack.len);
            clip_stack[clip_len] = .{ .container = node.id, .clip_id = placed_clip_id };
            clip_len += 1;
        }
        node.paint_clip_id = placed_clip_id;
        var content_clip_id = placed_clip_id;
        const content_clip_axes = node.contentClipAxes();
        if (content_clip_axes.any()) {
            const content_clip = intersectInherited(
                tree,
                ClipRect.fromRect(visual_border, content_clip_axes),
                content_clip_id,
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
            .label, .slider, .checkbox, .switch_control, .radio, .progress => true,
            else => false,
        };
        if (text_bearing and node.text_overflow == .clip and
            visual_border.w > 0 and visual_border.h > 0)
        {
            const visual_content = contentBoxRect(visual_border, node);
            const leading_inset = textLeadingInset(node.kind);
            var text_clip: ClipRect = .{
                .x = visual_content.x + leading_inset,
                .y = visual_content.y,
                .w = @max(0, visual_content.w - leading_inset),
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

        const authored = node.paint;
        if (authored.texture != null and authored.paint_fill != null) return error.InvalidStyle;
        const explicit_fill = authored.fill[3] > 0 or
            authored.paint_fill != null or authored.texture != null;
        const base_color: ?[4]f32 = switch (node.kind) {
            .column, .row => if (authored.transparent) null else if (explicit_fill)
                authored.fill
            else
                palette.container,
            .button => if (authored.transparent) null else if (explicit_fill)
                authored.fill
            else
                palette.button,
            .slider => if (explicit_fill) authored.fill else palette.slider,
            .element,
            .checkbox,
            .switch_control,
            .radio,
            .progress,
            .separator,
            .label,
            .spacer,
            => if (explicit_fill) authored.fill else null,
        };
        const pressed_button = if (node.kind == .button) blk: {
            const pressed = pressed_id orelse break :blk false;
            const widget_id = node.widget_id orelse break :blk false;
            break :blk pressed.eql(widget_id);
        } else false;
        const color: ?[4]f32 = if (base_color) |base|
            if (pressed_button and authored.paint_fill == null and authored.texture == null)
                lerp4(base, palette.button_pressed, press_alpha)
            else
                base
        else
            null;
        const fill: ?frame_paint.Fill = if (authored.texture) |texture|
            .{ .image_pattern = .{
                .texture_index = texture,
                .tile = .{ .x = visual_border.w, .y = visual_border.h },
            } }
        else if (authored.paint_fill) |rich|
            rich
        else if (color) |solid|
            .{ .solid = srgb(solid) }
        else
            null;

        const widths = [_]f32{ border.top, border.right, border.bottom, border.left };
        // SAFETY: the loop assigns all four sides before any read.
        var sides: frame_paint.Borders = undefined;
        var bordered = false;
        for (&sides, widths, authored.border_styles, 0..) |*side, width, border_style, index| {
            const resolved_width = if (border_style == .none) 0 else width;
            side.* = .{
                .width = resolved_width,
                .color = if (authored.border_colors) |colors|
                    colors[index]
                else
                    srgb(authored.border_color),
                .style = border_style,
            };
            bordered = bordered or resolved_width > 0;
        }
        if (fill != null or bordered or authored.shadows.len > 0) {
            const rect_paint: frame_paint.RectPaint = .{
                .bounds = .{
                    .x = visual_border.x,
                    .y = visual_border.y,
                    .w = visual_border.w,
                    .h = visual_border.h,
                },
                .fill = fill,
                .borders = sides,
                .radii = authored.resolvedRadii(),
                .shadows = authored.shadows,
                .opacity = authored.opacity,
                .transform = authored.transform,
                .clip_id = inherited_clip_id,
                .layer = try widget.effectiveLayer(node, 0),
                .order = @intCast(list.items.len),
            };
            list.appendAssumeCapacity(.{
                .rect = visual_border,
                .rect_paint = rect_paint,
                .clip_id = inherited_clip_id,
            });
        }

        // Custom paint is above its node background and below its children.
        if (node.kind == .element) {
            const bounds = widget.visualContentRect(tree, node.id);
            // Element records are authored against the content box, so they
            // clip to it. The node's own content clip covers the border box
            // and is already on the stack for descendants; push a distinct
            // one only when padding or border actually insets the box.
            const record_clip_id: u32 = if (content_clip_axes.any() and
                (bounds.x != visual_border.x or bounds.y != visual_border.y or
                    bounds.w != visual_border.w or bounds.h != visual_border.h))
                try tree.pushClipRect(intersectInherited(
                    tree,
                    ClipRect.fromRect(bounds, content_clip_axes),
                    inherited_clip_id,
                ))
            else
                content_clip_id;
            for (node.kind.element.paint_records.items) |record| {
                switch (record) {
                    .rect => |rect_spec| {
                        const rect_bounds: Rect = .{
                            .x = bounds.x + rect_spec.bounds.x,
                            .y = bounds.y + rect_spec.bounds.y,
                            .w = rect_spec.bounds.w,
                            .h = rect_spec.bounds.h,
                        };
                        const layer: u32 = try widget.effectiveLayer(node, rect_spec.layer);
                        const opacity = authored.opacity * rect_spec.opacity;
                        const transform = multiplyAffine(authored.transform, rect_spec.transform);
                        const order: u32 = rect_spec.order orelse @intCast(list.items.len);
                        var rp = rect_spec;
                        rp.bounds = .{
                            .x = rect_bounds.x,
                            .y = rect_bounds.y,
                            .w = rect_bounds.w,
                            .h = rect_bounds.h,
                        };
                        rp.layer = layer;
                        rp.opacity = opacity;
                        rp.transform = transform;
                        rp.clip_id = record_clip_id;
                        rp.order = order;
                        list.appendAssumeCapacity(.{
                            .rect = rect_bounds,
                            .rect_paint = rp,
                            .path_paint = null,
                            .clip_id = record_clip_id,
                        });
                    },
                    .path => |path_spec| {
                        const path_bounds: Rect = .{
                            .x = bounds.x + path_spec.bounds.x,
                            .y = bounds.y + path_spec.bounds.y,
                            .w = path_spec.bounds.w,
                            .h = path_spec.bounds.h,
                        };
                        const layer: u32 = try widget.effectiveLayer(node, path_spec.layer);
                        const opacity = authored.opacity * path_spec.opacity;
                        const transform = multiplyAffine(authored.transform, path_spec.transform);
                        const order: u32 = path_spec.order orelse @intCast(list.items.len);
                        var pp = path_spec;
                        pp.bounds = .{
                            .x = path_bounds.x,
                            .y = path_bounds.y,
                            .w = path_bounds.w,
                            .h = path_bounds.h,
                        };
                        pp.layer = layer;
                        pp.opacity = opacity;
                        pp.transform = transform;
                        pp.clip_id = record_clip_id;
                        pp.order = order;
                        list.appendAssumeCapacity(.{
                            .rect = path_bounds,
                            .rect_paint = .{
                                .bounds = .{
                                    .x = path_bounds.x,
                                    .y = path_bounds.y,
                                    .w = path_bounds.w,
                                    .h = path_bounds.h,
                                },
                                .opacity = opacity,
                                .transform = transform,
                                .clip_id = record_clip_id,
                                .layer = layer,
                                .order = order,
                            },
                            .path_paint = pp,
                            .clip_id = record_clip_id,
                        });
                    },
                    .image => |image_spec| {
                        const image_bounds: Rect = .{
                            .x = bounds.x + image_spec.bounds.x,
                            .y = bounds.y + image_spec.bounds.y,
                            .w = image_spec.bounds.w,
                            .h = image_spec.bounds.h,
                        };
                        const layer: u32 = try widget.effectiveLayer(node, image_spec.layer);
                        const order: u32 = image_spec.order orelse @intCast(list.items.len);
                        var ip = image_spec;
                        ip.bounds = .{
                            .x = image_bounds.x,
                            .y = image_bounds.y,
                            .w = image_bounds.w,
                            .h = image_bounds.h,
                        };
                        ip.layer = layer;
                        ip.opacity = authored.opacity * image_spec.opacity;
                        ip.clip_id = record_clip_id;
                        ip.order = order;
                        list.appendAssumeCapacity(.{
                            .rect = image_bounds,
                            .rect_paint = .{
                                .bounds = ip.bounds,
                                .opacity = ip.opacity,
                                .clip_id = ip.clip_id,
                                .layer = layer,
                                .order = order,
                            },
                            .image_paint = ip,
                            .clip_id = record_clip_id,
                        });
                    },
                }
            }
        }
    }
    return;
}

test "draw command collection counters record node comparisons" {
    var counters: perf_counters.Counters = .{};
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    tree.setCounterSink(&counters);
    const node_id: FrameNodeId = @fromBackingInt(@intCast(1));
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
    if (comptime v7_options.perf_counters) {
        try std.testing.expect(snapshot.value(.node_comparisons) > 0);
    } else {
        try std.testing.expectEqual(@as(u64, 0), snapshot.value(.node_comparisons));
    }
}

fn srgb(channels: [4]f32) frame_paint.Color {
    return .{ .srgb = .{
        .r = channels[0],
        .g = channels[1],
        .b = channels[2],
        .a = channels[3],
    } };
}

fn multiplyAffine(p: frame_paint.Affine, l: frame_paint.Affine) frame_paint.Affine {
    return .{
        .a = p.a * l.a + p.c * l.b,
        .b = p.b * l.a + p.d * l.b,
        .c = p.a * l.c + p.c * l.d,
        .d = p.b * l.c + p.d * l.d,
        .tx = p.a * l.tx + p.c * l.ty + p.tx,
        .ty = p.b * l.tx + p.d * l.ty + p.ty,
    };
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

test "collectDrawCmds: paint order — container before children, spacer skipped" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const col: FrameNodeId = @fromBackingInt(@intCast(1));
    const l1: FrameNodeId = @fromBackingInt(@intCast(2));
    const l2: FrameNodeId = @fromBackingInt(@intCast(3));
    const btn: FrameNodeId = @fromBackingInt(@intCast(4));
    const sp: FrameNodeId = @fromBackingInt(@intCast(5));

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

test "collectDrawCmds: zero-size nodes are skipped" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const col: FrameNodeId = @fromBackingInt(@intCast(1));
    const btn: FrameNodeId = @fromBackingInt(@intCast(2));
    const zero_w: FrameNodeId = @fromBackingInt(@intCast(3));
    const zero_h: FrameNodeId = @fromBackingInt(@intCast(4));

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

    const zero_width: FrameNodeId = @fromBackingInt(@intCast(1));
    const negative_height: FrameNodeId = @fromBackingInt(@intCast(2));
    const clip: FrameNodeId = @fromBackingInt(@intCast(3));
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
        .shadows = &.{.{ .color = srgb(.{ 0, 0, 0, 0.28 }), .blur = 3 }},
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
}

test "collectDrawCmds: clipped text intersects its content box with the parent clip" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const label_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const clip_id: FrameNodeId = @fromBackingInt(@intCast(2));
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

test "collectDrawCmds: bordered button keeps fill and physical sides in one paint rectangle" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const btn: FrameNodeId = @fromBackingInt(@intCast(1));
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

    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    const output = cmds[0].rect_paint;
    try std.testing.expectEqual(
        frame_paint.Rect{ .x = 10, .y = 10, .w = 80, .h = 30 },
        output.bounds,
    );
    try std.testing.expectEqual(@as(f32, 1), output.borders[0].width);
    try std.testing.expectEqual(@as(f32, 2), output.borders[1].width);
    try std.testing.expectEqual(@as(f32, 3), output.borders[2].width);
    try std.testing.expectEqual(@as(f32, 4), output.borders[3].width);
    try std.testing.expectEqual(@as(f32, 1), output.borders[0].color.srgb.r);
    try std.testing.expectEqual(@as(f32, palette.button[0]), output.fill.?.solid.srgb.r);
}

test "collectDrawCmds: resolved physical border edges reach paint without re-resolving CSS" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const btn: FrameNodeId = @fromBackingInt(@intCast(1));
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

    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    const sides = cmds[0].rect_paint.borders;
    try std.testing.expectEqual(@as(f32, 1), sides[0].width);
    try std.testing.expectEqual(@as(f32, 2), sides[1].width);
    try std.testing.expectEqual(@as(f32, 3), sides[2].width);
    try std.testing.expectEqual(@as(f32, 4), sides[3].width);
}

test "collectDrawCmds: nested node under a column resolves to its absolute rect" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const col: FrameNodeId = @fromBackingInt(@intCast(1));
    const btn: FrameNodeId = @fromBackingInt(@intCast(2));

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

test "collectDrawCmds: authored shadow keeps its offset, color, blur, and inset" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const btn: FrameNodeId = @fromBackingInt(@intCast(1));
    const paint_style: PaintStyle = .{ .shadows = &.{.{
        .color = srgb(.{ 0.2, 0.3, 0.4, 0.5 }),
        .offset = .{ .x = 2, .y = 3 },
        .blur = 3,
        .spread = 1,
        .inset = true,
    }} };
    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 30 },
        .paint = paint_style,
    });

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);

    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    const output = cmds[0].rect_paint;
    try std.testing.expectEqual(
        frame_paint.Rect{ .x = 10, .y = 10, .w = 80, .h = 30 },
        output.bounds,
    );
    try std.testing.expectEqual(@as(usize, 1), output.shadows.len);
    try std.testing.expectEqual(@as(f32, 2), output.shadows[0].offset.x);
    try std.testing.expectEqual(@as(f32, 3), output.shadows[0].offset.y);
    try std.testing.expectEqual(@as(f32, 3), output.shadows[0].blur);
    try std.testing.expectEqual(@as(f32, 1), output.shadows[0].spread);
    try std.testing.expect(output.shadows[0].inset);
    try std.testing.expectEqual(@as(f32, 0.5), output.shadows[0].color.srgb.a);
    try std.testing.expectEqual(@as(f32, palette.button[0]), output.fill.?.solid.srgb.r);
}

test "collectDrawCmds: layered shadow and border remain with their node's fill" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    // One paint record keeps every primitive of this node on one layer.
    const btn: FrameNodeId = @fromBackingInt(@intCast(1));
    const style: Style = .{
        .border_inset = .{
            .top = .{ .length = 1 },
            .right = .{ .length = 1 },
            .bottom = .{ .length = 1 },
            .left = .{ .length = 1 },
        },
    };
    const paint_style: PaintStyle = .{ .layer = 2, .shadows = &.{.{
        .color = srgb(.{ 0, 0, 0, 0.5 }),
        .blur = 3,
    }} };
    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 30 },
        .style = style,
        .paint = paint_style,
    });

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);

    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    try std.testing.expectEqual(@as(usize, 1), cmds[0].rect_paint.shadows.len);
    try std.testing.expectEqual(@as(f32, 1), cmds[0].rect_paint.borders[0].width);
    try std.testing.expect(cmds[0].rect_paint.fill != null);
    try std.testing.expectEqual(@as(u32, 2), cmds[0].rect_paint.layer);

    // A plain (unlayered) node's cmds default to layer 0.
    const plain: FrameNodeId = @fromBackingInt(@intCast(2));
    try tree.nodes.append(std.testing.allocator, .{
        .id = plain,
        .kind = .{ .button = .{ .label = "plain" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 60, .w = 80, .h = 30 },
    });
    const cmds2 = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds2);
    // Reversed post-order: the plain button (appended last) emits first.
    try std.testing.expectEqual(@as(usize, 2), cmds2.len);
    try std.testing.expectEqual(@as(u32, 0), cmds2[0].rect_paint.layer);
    try std.testing.expectEqual(@as(u32, 2), cmds2[1].rect_paint.layer);
}

test "collectDrawCmds: a border-only label emits exactly one command" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const lbl: FrameNodeId = @fromBackingInt(@intCast(1));
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

    // The label authors no fill, so its four border sides are the only reason
    // it emits anything: exactly one command, on the full border box.
    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 40, .h = 24 }, cmds[0].rect);
}

test "collectDrawCmds: a content clip stamps descendants, preserves own paint, then pops for siblings" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    // Post-order: children before containers. A clip-marked column holds
    // a button; a sibling button sits outside the clip.
    const inner_btn: FrameNodeId = @fromBackingInt(@intCast(1));
    const card: FrameNodeId = @fromBackingInt(@intCast(2));
    const sibling_btn: FrameNodeId = @fromBackingInt(@intCast(3));

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
    const btn: FrameNodeId = @fromBackingInt(@intCast(1));
    const inner: FrameNodeId = @fromBackingInt(@intCast(2));
    const outer: FrameNodeId = @fromBackingInt(@intCast(3));

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

    const label_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const button_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const scroll_id: FrameNodeId = @fromBackingInt(@intCast(3));
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

        const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
        const parent_id: FrameNodeId = @fromBackingInt(@intCast(2));
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

        const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
        const parent_id: FrameNodeId = @fromBackingInt(@intCast(2));
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

    const child_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const parent_id: FrameNodeId = @fromBackingInt(@intCast(2));
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
        .paint = .{ .shadows = &.{.{
            .color = srgb(.{ 0, 0, 0, 0.5 }),
            .blur = 4,
        }} },
    });
    try tree.appendChild(parent_id, child_id);

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expectEqual(no_clip, cmds[0].rect_paint.clip_id);
    try std.testing.expectEqual(@as(u32, 0), cmds[1].rect_paint.clip_id);
    try std.testing.expectEqual(@as(u32, 0), tree.node(parent_id).?.clip_id);
}

test "collectDrawCmdsInto reuses caller-owned storage" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
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

test "collectDrawCmds: control text clips leave room for each indicator" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    var checked = true;
    var switched = false;
    var selected: ?u32 = 9;
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .checkbox = .{ .label = "enabled", .value = &checked } },
        .parent = .root,
        .rect = .{ .x = 20, .y = 30, .w = 100, .h = 18 },
        .text_overflow = .clip,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(2)),
        .kind = .{ .switch_control = .{ .label = "active", .value = &switched } },
        .parent = .root,
        .rect = .{ .x = 200, .y = 30, .w = 100, .h = 18 },
        .text_overflow = .clip,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(3)),
        .kind = .{ .radio = .{ .label = "option", .selected = &selected, .option = 9 } },
        .parent = .root,
        .rect = .{ .x = 400, .y = 30, .w = 100, .h = 18 },
        .text_overflow = .clip,
    });

    const cmds = try collectDrawCmds(std.testing.allocator, &tree, null, 0);
    defer std.testing.allocator.free(cmds);
    try std.testing.expectEqual(@as(usize, 0), cmds.len);
    try std.testing.expectEqual(@as(u32, 3), tree.clip_count);
    // Reverse post-order assigns clips in radio, switch, checkbox order.
    try std.testing.expectEqual(
        ClipRect{ .x = 424, .y = 30, .w = 76, .h = 18 },
        tree.clip_rects[0],
    );
    try std.testing.expectEqual(
        ClipRect{ .x = 236, .y = 30, .w = 64, .h = 18 },
        tree.clip_rects[1],
    );
    try std.testing.expectEqual(
        ClipRect{ .x = 44, .y = 30, .w = 76, .h = 18 },
        tree.clip_rects[2],
    );
}
