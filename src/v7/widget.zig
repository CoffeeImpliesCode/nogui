//! v7 widget types — geometry, per-child flex data, kind union, and the
//! per-frame widget tree.
//! Per the prototype spec (notes/v7-prototype-spec.md §2).
const std = @import("std");

const Id = @import("id.zig").Id;
const FlexStyle = @import("flex.zig").FlexStyle;

/// Axis-aligned rectangle in layout space.
///
/// RELATIVE semantics: a node's rect is its BORDER box, positioned relative
/// to its PARENT'S CONTENT box (root-level nodes: relative to the surface).
/// Absolute positions are resolved on demand via `absoluteRect` /
/// `absoluteBorderOrigin` (a parent walk). Keeping rects relative lets a
/// subtree move as a unit and makes the double-buffered prev_tree diff
/// meaningful (a parent offset change does not invalidate child rects).
pub const Rect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };

/// Available / required space.
pub const Size = struct { width: f32, height: f32 };

/// Per-side box extents (CSS: margin, border width, padding, radius).
/// Order: top, right, bottom, left.
pub const Sides = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,
};

/// CSS box-sizing. With auto (natural) sizing both modes produce the same
/// border box (content + border + padding); the mode matters once fixed
/// sizes arrive (a specified border-box width includes padding+border, a
/// specified content-box width does not). Inert today, part of the model.
pub const BoxSizing = enum { content_box, border_box };

/// The CSS box model for one node: margin (outside, handled by the parent
/// when positioning), border + radius (painted as a ring), padding (inside,
/// separating the border from the content). `node.rect` is the BORDER box;
/// the content box = rect inset by border + padding.
pub const Box = struct {
    margin: Sides = .{},
    border: Sides = .{}, // widths only; color/radius are paint
    border_color: [4]f32 = .{ 0, 0, 0, 1 },
    /// Per-axis corner radii (l/r/t/b) of the OUTER border edge, matching
    /// SliceRect's corner_l/r/t/b geometry (each corner = l|r x t|b). The
    /// inner (fill) radius = max(0, radius - border) per axis.
    radius: Sides = .{},
    padding: Sides = .{},
    box_sizing: BoxSizing = .content_box,
    /// Paint-only: drop-shadow softness/offset in px (0 = none). Never
    /// affects layout; excluded from the layout fingerprint.
    shadow: f32 = 0,
    /// Paint-only: the gradient's bottom color in Oklab (all-zero = flat
    /// fill). The vertex color is the gradient's top. Excluded from the
    /// layout fingerprint.
    gradient: [4]f32 = .{ 0, 0, 0, 0 },
};

/// Horizontal+vertical sums of a Sides (for content-box derivation).
pub fn sidesSum(s: Sides) struct { w: f32, h: f32 } {
    return .{ .w = s.left + s.right, .h = s.top + s.bottom };
}

/// Per-child flexbox sizing parameters (main axis).
pub const FlexChild = struct {
    grow: f32 = 0,
    shrink: f32 = 1,
    basis: f32 = 0,
};

/// What a widget node is. Payload differs per kind; fields with defaults
/// may be omitted at construction.
pub const WidgetKind = union(enum) {
    column: struct { gap: f32 = 0 },
    row: struct { gap: f32 = 0 },
    label: struct { text: []const u8 },
    button: struct {
        label: []const u8,
        on_click: ?*const fn (*anyopaque) void = null, // set via callback.wrap()
        owner: Id = .root, // component_id at creation time
    },
    slider: struct { label: []const u8, value: *f32, min: f32, max: f32 },
    spacer: struct { size: f32 = 0 },
};

/// One node in the tree.
pub const WidgetNode = struct {
    id: Id,
    kind: WidgetKind,
    parent: Id,
    // SAFETY: items is filled by flex before any read; len tracks the filled count.
    children: struct { items: [32]Id = undefined, len: u8 = 0 } = .{}, // fixed cap, prototype
    /// BORDER box, positioned relative to the parent's CONTENT box (see
    /// Rect's doc). Filled by flex.layout().
    rect: Rect = .{},
    /// CSS box model: margin/border/padding/radius. Set at creation from
    /// the DrawCtx opts; flex and the renderer read it.
    box: Box = .{},
    flex: FlexChild = .{}, // per-child sizing
    style: FlexStyle = .{}, // per-container layout style (justify/align); direction+gap come from kind
};

/// The per-frame widget tree.
///
/// Invariant: node order is **post-order** — a node's children are appended
/// before the node itself. A container therefore appears after all of its
/// descendants, so flex.layout() can run bottom-up in one pass.
///
/// Storage is owned by the caller (the frame arena, see drawctx.zig); the
/// tree must be re-created per frame, never reused across a reset.
pub const WidgetTree = struct {
    nodes: std.ArrayListUnmanaged(WidgetNode) = .empty,
    allocator: std.mem.Allocator,
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) WidgetTree {
        return .{ .allocator = allocator };
    }

    /// Linear scan by id. Null if absent.
    pub fn node(self: *WidgetTree, id: Id) ?*WidgetNode {
        for (self.nodes.items) |*n| {
            if (n.id == id) return n;
        }
        return null;
    }

    /// Const-safe linear scan by id. Null if absent.
    pub fn nodeConst(self: *const WidgetTree, id: Id) ?*const WidgetNode {
        for (self.nodes.items) |*n| {
            if (n.id == id) return n;
        }
        return null;
    }

    /// All nodes whose parent == .root (top-level).
    /// Fills `buf` (caller provides, cap 64) up to `buf.len` entries and
    /// returns the total count — truncation-safe: a too-small `buf` never
    /// overflows, the caller just gets the count that would have been written.
    pub fn roots(self: *WidgetTree, buf: []*WidgetNode) usize {
        var count: usize = 0;
        for (self.nodes.items) |*n| {
            if (n.parent != .root) continue;
            if (count < buf.len) buf[count] = n;
            count += 1;
        }
        return count;
    }
};

/// Resolve a node's absolute border-box origin by walking parents: each
/// ancestor contributes its own (relative) offset plus the step into its
/// CONTENT box (border + padding). The surface origin is (0,0).
pub fn absoluteBorderOrigin(tree: *const WidgetTree, id: Id) [2]f32 {
    var ox: f32 = 0;
    var oy: f32 = 0;
    var cur = id;
    while (cur != .root) {
        const n = tree.nodeConst(cur) orelse break;
        ox += n.rect.x;
        oy += n.rect.y;
        const parent = tree.nodeConst(n.parent) orelse break;
        ox += parent.box.border.left + parent.box.padding.left;
        oy += parent.box.border.top + parent.box.padding.top;
        cur = n.parent;
    }
    return .{ ox, oy };
}

/// Absolute border box of a node (origin + its own w/h).
pub fn absoluteRect(tree: *const WidgetTree, id: Id) Rect {
    const origin = absoluteBorderOrigin(tree, id);
    const n = tree.nodeConst(id) orelse return .{ .x = origin[0], .y = origin[1] };
    return .{ .x = origin[0], .y = origin[1], .w = n.rect.w, .h = n.rect.h };
}

/// Absolute CONTENT box of a node: the absolute border box inset by the
/// node's own border + padding. Where children live and text draws.
pub fn contentRect(tree: *const WidgetTree, id: Id) Rect {
    const r = absoluteRect(tree, id);
    const b = tree.nodeConst(id).?.box;
    return .{
        .x = r.x + b.border.left + b.padding.left,
        .y = r.y + b.border.top + b.padding.top,
        .w = @max(0, r.w - b.border.left - b.border.right - b.padding.left - b.padding.right),
        .h = @max(0, r.h - b.border.top - b.border.bottom - b.padding.top - b.padding.bottom),
    };
}

test "WidgetTree: node() finds pushed ids, null for unknown" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    try tree.nodes.append(std.testing.allocator, .{
        .id = id1,
        .kind = .{ .label = .{ .text = "a" } },
        .parent = .root,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = id2,
        .kind = .{ .spacer = .{} },
        .parent = id1,
    });

    const found = tree.node(id2).?;
    try std.testing.expectEqual(id2, found.id);
    try std.testing.expectEqual(id1, found.parent);
    try std.testing.expectEqual(@as(?*WidgetNode, null), tree.node(@enumFromInt(99)));
}

test "WidgetTree: roots() returns only top-level nodes in append order" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    const id3: Id = @enumFromInt(3);
    const id4: Id = @enumFromInt(4);
    const id5: Id = @enumFromInt(5);

    // Post-order: children first, then their containers.
    try tree.nodes.append(std.testing.allocator, .{ .id = id4, .kind = .{ .label = .{ .text = "c" } }, .parent = id1 });
    try tree.nodes.append(std.testing.allocator, .{ .id = id5, .kind = .{ .label = .{ .text = "d" } }, .parent = id2 });
    try tree.nodes.append(std.testing.allocator, .{ .id = id1, .kind = .{ .column = .{} }, .parent = .root });
    try tree.nodes.append(std.testing.allocator, .{ .id = id2, .kind = .{ .row = .{} }, .parent = .root });
    try tree.nodes.append(std.testing.allocator, .{ .id = id3, .kind = .{ .spacer = .{} }, .parent = .root });

    var buf: [8]*WidgetNode = undefined;
    const count = tree.roots(&buf);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(id1, buf[0].id);
    try std.testing.expectEqual(id2, buf[1].id);
    try std.testing.expectEqual(id3, buf[2].id);
}

test "WidgetTree: roots() with a too-small buf returns the full count, no overflow" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    for (0..5) |i| {
        try tree.nodes.append(std.testing.allocator, .{
            .id = @enumFromInt(@as(u32, @intCast(i + 1))),
            .kind = .{ .spacer = .{} },
            .parent = .root,
        });
    }

    var small: [2]*WidgetNode = undefined;
    const count = tree.roots(&small);
    // Count reflects everything that would have been written.
    try std.testing.expectEqual(@as(usize, 5), count);
    // The first entries still land, in append order.
    try std.testing.expectEqual(@as(Id, @enumFromInt(1)), small[0].id);
    try std.testing.expectEqual(@as(Id, @enumFromInt(2)), small[1].id);
    // Writing past buf.len would trip the slice bounds check under `zig test`.
}

test "absoluteRect: walks parent content boxes through border+padding" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    // root-level column with padding, holding a row with a border, holding
    // a label offset relative to the row's content box.
    const col: Id = @enumFromInt(1);
    const row: Id = @enumFromInt(2);
    const label: Id = @enumFromInt(3);

    try tree.nodes.append(std.testing.allocator, .{
        .id = label,
        .kind = .{ .label = .{ .text = "x" } },
        .parent = row,
        .rect = .{ .x = 5, .y = 3, .w = 20, .h = 24 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = row,
        .kind = .{ .row = .{} },
        .parent = col,
        .rect = .{ .x = 10, .y = 10, .w = 100, .h = 40 },
        .box = .{ .border = .{ .top = 1, .right = 2, .bottom = 3, .left = 4 } },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = col,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 200, .h = 200 },
        .box = .{ .padding = .{ .top = 8, .left = 8 } },
    });

    // Label absolute border box: col content origin (8,8) + row rect
    // (10,10) + row border (4,1) + label rect (5,3).
    const r = absoluteRect(&tree, label);
    try std.testing.expectEqual(Rect{ .x = 8 + 10 + 4 + 5, .y = 8 + 10 + 1 + 3, .w = 20, .h = 24 }, r);

    // Label content box: its own border+padding are zero, so identical.
    const c = contentRect(&tree, label);
    try std.testing.expectEqual(r, c);

    // Row content box: absolute border box (18,18,100,40) inset by its
    // border (4,1,2,3).
    const rc = contentRect(&tree, row);
    try std.testing.expectEqual(Rect{ .x = 18 + 4, .y = 18 + 1, .w = 100 - 6, .h = 40 - 4 }, rc);
}

test "absoluteRect: root-level node is relative to the surface (0,0)" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const col: Id = @enumFromInt(1);
    try tree.nodes.append(std.testing.allocator, .{
        .id = col,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
    });

    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, absoluteRect(&tree, col));
}

test "WidgetNode: defaults are zero-valued" {
    const n = WidgetNode{
        .id = .root,
        .kind = .{ .label = .{ .text = "x" } },
        .parent = .root,
    };

    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, n.rect);
    try std.testing.expectEqual(Box{}, n.box);
    try std.testing.expectEqual(@as(u8, 0), n.children.len);
    try std.testing.expectEqual(@as(f32, 0), n.flex.grow);
    try std.testing.expectEqual(@as(f32, 1), n.flex.shrink);
    try std.testing.expectEqual(@as(f32, 0), n.flex.basis);
}
