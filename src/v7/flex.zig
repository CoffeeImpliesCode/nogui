//! v7 flexbox — nowrap layout.
//!
//! Pipeline: a bottom-up pass sizes every node and positions children
//! relative to their container's CONTENT box; placeRoot places root-level
//! nodes relative to the surface; two top-down passes (finalizeCross,
//! finalizeMain) re-fit children against each container's FINAL content box —
//! the cross axis (stretch/center/end) and the main axis (grow/shrink/justify),
//! which can only be known once the container itself was sized. Node rects
//! are RELATIVE BORDER boxes (see widget.zig's Rect doc): each rect = content
//! + border + padding, positioned against its parent's content box; margins
//! are handled by the parent when positioning. Absolute positions are
//! resolved on demand via widget.absoluteRect — no offset folding. No
//! allocation: only in-place `WidgetNode.rect` writes, byte-exact for the
//! same input.
//!
//! Per the prototype spec (notes/v7-prototype-spec.md §6).
const std = @import("std");

const Id = @import("id.zig").Id;
const widget = @import("widget.zig");

const WidgetTree = widget.WidgetTree;
const WidgetNode = widget.WidgetNode;
const WidgetKind = widget.WidgetKind;
const Rect = widget.Rect;
const Size = widget.Size;
const FlexChild = widget.FlexChild;

/// Main axis direction of a container.
pub const Direction = enum { column, row };

/// Distribution of free space between a container's children on the main axis.
pub const Justify = enum { start, center, end, space_between };

/// Cross-axis sizing and positioning of a container's children.
pub const Align = enum { stretch, start, center, end };

/// Layout parameters of a container.
///
/// `layout` derives `direction` and `gap` from the node's kind (the
/// `column`/`row` payload) and reads `justify`/`align` from the node's
/// `style` field; the `direction`/`gap` fields exist for a complete style
/// value but are not consulted for the layout of a concrete node.
pub const FlexStyle = struct {
    direction: Direction = .column,
    justify: Justify = .start,
    @"align": Align = .stretch,
    gap: f32 = 0,
};

/// Optional text measurement hook injected by the host (e.g. FreeType
/// advance sums). When null, leaves use the baked approximation below.
/// text: the label; font_size: the node's px size (0 = host default).
pub const MeasureFn = *const fn (text: []const u8, font_size: f32, font_id: u8) Size;

/// Nowrap layout. Fills `WidgetNode.rect` for all nodes.
///
/// Root-level nodes (parent == .root) are laid out as a column against
/// `available` (the root pseudo-container, styled like `FlexStyle{}`:
/// justify=start, align=stretch, gap=0); children recurse per their
/// container's FlexStyle.
///
/// Node order is post-order: children already have final rects when the
/// container is placed, so the bottom-up pass can size containers from their
/// children. A container's main size is the sum of its children's MARGIN-box
/// main sizes (border box + both margins) plus gaps, unless a child grows
/// into free space, children are shrunk on overflow, or justify distributes
/// free space — then it takes the available size. Its cross size is the
/// largest child cross size plus its own border + padding, or the available
/// cross size under `align = .stretch`. Children live in the container's
/// CONTENT box (its border box inset by its own border + padding). Because a
/// container's real content box is only final once ITS parent was sized, two
/// top-down passes (finalizeCross, finalizeMain) re-place every child against
/// the FINAL content box. No allocation.
pub fn layout(tree: *WidgetTree, available: Size) void {
    layoutWith(tree, available, null);
}

/// layout() with a host-supplied text measurer. The v7 core stays pure: the
/// measurer (demo-side FreeType metrics) returns CONTENT size (pure text
/// advances); measureLeaf adds the node's border + padding on top to form
/// its border box. Without it, leaves use the baked approximation below.
pub fn layoutWith(tree: *WidgetTree, available: Size, measure: ?MeasureFn) void {
    // Bottom-up pass: leaves get natural sizes; containers compute their own
    // size and position children relative to the container's content box.
    for (tree.nodes.items) |*node| {
        switch (node.kind) {
            .column, .row, .button => placeContainer(tree, node, available),
            else => measureLeaf(node, measure),
        }
    }
    // Root pseudo-container pass: place root-level nodes against `available`,
    // relative to the surface (rects are already relative, no offset folding).
    placeRoot(tree, available);
    // Top-down passes: a container's content box is only final once ITS
    // parent was sized, so the bottom-up pass placed children against the
    // container's hug box. finalizeCross re-stretches every stretch-aligned
    // child to the parent's FINAL content cross, recursing so the propagation
    // reaches nested containers (a 776px card must stretch its slider to
    // 758px, not leave it at the 125px hug width). finalizeMain then re-runs
    // grow/shrink/justify against the FINAL content main — nested containers
    // never distribute space bottom-up, their parent allocates it later.
    finalizeCross(tree, .root, available);
    finalizeMain(tree, .root, available);
}

/// Finalize every child's CROSS size and position against the parent's
/// FINAL content box. The bottom-up pass placed children against the
/// container's hug cross; a container's real cross is only known once ITS
/// parent was sized (root stretch, nested stretch). This top-down pass:
///   - stretch:  child cross = parent content cross - child cross margins
///   - center/end: child keeps its natural cross, positioned within the
///     parent content cross (margins respected)
/// Main sizes and main positions are untouched.
fn finalizeCross(tree: *WidgetTree, parent_id: Id, available: Size) void {
    const parent = if (parent_id == .root) null else tree.node(parent_id).?;
    if (parent) |p| {
        if (p.kind != .column and p.kind != .row and p.kind != .button) return;
        const b = p.box;
        const content_w = @max(0, p.rect.w - b.border.left - b.border.right - b.padding.left - b.padding.right);
        const content_h = @max(0, p.rect.h - b.border.top - b.border.bottom - b.padding.top - b.padding.bottom);
        const @"align" = p.style.@"align";
        const is_col = p.kind == .column;
        for (p.children.items[0..p.children.len]) |cid| {
            const child = tree.node(cid).?;
            const m = child.box.margin;
            const natural = if (is_col) child.rect.w else child.rect.h;
            const extent = if (is_col) content_w else content_h;
            const margin_lead = if (is_col) m.left else m.top;
            const margin_trail = if (is_col) m.right else m.bottom;
            const size: f32 = if (@"align" == .stretch)
                @max(0, extent - margin_lead - margin_trail)
            else
                natural;
            const free = @max(0, extent - size - margin_lead - margin_trail);
            const pos: f32 = switch (@"align") {
                .stretch, .start => margin_lead,
                .center => margin_lead + free / 2,
                .end => margin_lead + free,
            };
            if (is_col) {
                child.rect.w = size;
                child.rect.x = pos;
            } else {
                child.rect.h = size;
                child.rect.y = pos;
            }
            finalizeCross(tree, cid, available);
        }
    } else {
        // Root pseudo-container: root-level nodes take the available width
        // minus their own cross margins (align = stretch at the root).
        for (tree.nodes.items) |*n| {
            if (n.parent != .root) continue;
            const m = n.box.margin;
            n.rect.w = @max(0, available.width - m.left - m.right);
            finalizeCross(tree, n.id, available);
        }
    }
}

/// Finalize every container's MAIN-axis layout against its FINAL main size.
/// The bottom-up pass gave nested containers their hug main (their parent
/// distributes space only later), so grow/shrink/justify never fired below
/// the root. This top-down pass re-computes each container's content main
/// from its children's FINAL border-box mains + margins + gaps, distributes
/// the free space in the container's FINAL content box (grow, or shrink
/// clamped at 0), and re-places the children's main positions (justify
/// included: start/center/end/space_between). The container's own rect is
/// already final. Cross sizes/positions are untouched.
fn finalizeMain(tree: *WidgetTree, parent_id: Id, available: Size) void {
    const parent = if (parent_id == .root) null else tree.node(parent_id).?;
    if (parent) |p| {
        if (p.kind != .column and p.kind != .row and p.kind != .button) return;
        const dir: Direction = switch (p.kind) {
            .column => .column,
            .row => .row,
            .button => .row,
            else => unreachable,
        };
        const gap: f32 = switch (p.kind) {
            .column => |c| c.gap,
            .row => |r| r.gap,
            .button => 0,
            else => unreachable,
        };
        const justify = p.style.justify;

        // The container's own box insets its content box on the main axis.
        const box = p.box;
        const own_border_main = if (dir == .column) box.border.top + box.border.bottom else box.border.left + box.border.right;
        const own_padding_main = if (dir == .column) box.padding.top + box.padding.bottom else box.padding.left + box.padding.right;
        const inset_main = own_border_main + own_padding_main;

        // Children's FINAL border-box mains + margins + gaps.
        const count = p.children.len;
        var mains: [32]f32 = undefined;
        var content: f32 = 0;
        var total_grow: f32 = 0;
        var total_shrink: f32 = 0;
        for (0..count) |i| {
            const child = tree.node(p.children.items[i]) orelse continue;
            mains[i] = if (dir == .column) child.rect.h else child.rect.w;
            content += mains[i] + child.box.margin.left + child.box.margin.right;
            if (child.flex.grow > 0) total_grow += child.flex.grow;
            if (child.flex.shrink > 0) total_shrink += child.flex.shrink;
        }
        if (count > 1) content += gap * @as(f32, @floatFromInt(count - 1));

        // Free space in the container's FINAL content box.
        const container_main = if (dir == .column) p.rect.h else p.rect.w;
        const free = (container_main - inset_main) - content;
        const grew = free > 0 and total_grow > 0;
        const shrank = free < 0 and total_shrink > 0;
        if (grew) {
            for (0..count) |i| {
                const child = tree.node(p.children.items[i]) orelse continue;
                if (child.flex.grow > 0) mains[i] += free * child.flex.grow / total_grow;
            }
        } else if (shrank) {
            const overflow = -free;
            for (0..count) |i| {
                const child = tree.node(p.children.items[i]) orelse continue;
                // Canonical automatic minimum (CSS flexbox §4.5): a flex
                // item's default min-main is its CONTENT-based minimum —
                // shrink can never cross the item's natural size, or the
                // text spills out of the box. The container then overflows
                // visibly instead of crushing its content.
                const natural = mains[i]; // the measured natural main
                if (child.flex.shrink > 0)
                    mains[i] = @max(natural, mains[i] - overflow * child.flex.shrink / total_shrink);
            }
        }

        // Justify distributes the remaining free space (grow/shrink consumed
        // it all, so nothing is left when either ran).
        const spread = count > 0 and free > 0 and justify != .start;
        const fitted = content + (if (grew or shrank) free else 0);
        const free_for_justify = if (grew or shrank or spread)
            @max(0, container_main - inset_main - fitted)
        else
            0;
        var main_offset: f32 = 0;
        var extra_gap: f32 = 0;
        switch (justify) {
            .start => {},
            .center => main_offset = free_for_justify / 2,
            .end => main_offset = free_for_justify,
            .space_between => if (count > 1) {
                extra_gap = free_for_justify / @as(f32, @floatFromInt(count - 1));
            },
        }

        var main_pos = main_offset;
        for (0..count) |i| {
            const child = tree.node(p.children.items[i]) orelse continue;
            const m = child.box.margin;
            if (dir == .column) {
                child.rect.h = mains[i];
                child.rect.y = m.top + main_pos;
            } else {
                child.rect.w = mains[i];
                child.rect.x = m.left + main_pos;
            }
            main_pos += mains[i] + m.left + m.right + (if (i + 1 < count) gap + extra_gap else 0);
        }

        // Recurse so nested containers distribute against their FINAL mains.
        for (0..count) |i| finalizeMain(tree, p.children.items[i], available);
    } else {
        // Root pseudo-container: re-run the root grow/shrink against the
        // available main (root justify is the FlexStyle{} default: start).
        var content: f32 = 0;
        var total_grow: f32 = 0;
        var total_shrink: f32 = 0;
        for (tree.nodes.items) |*n| {
            if (n.parent != .root) continue;
            content += n.rect.h + n.box.margin.top + n.box.margin.bottom;
            if (n.flex.grow > 0) total_grow += n.flex.grow;
            if (n.flex.shrink > 0) total_shrink += n.flex.shrink;
        }
        const free = available.height - content;
        const grew = free > 0 and total_grow > 0;
        const shrank = free < 0 and total_shrink > 0;
        var y: f32 = 0;
        for (tree.nodes.items) |*n| {
            if (n.parent != .root) continue;
            const m = n.box.margin;
            var main = n.rect.h;
            if (grew and n.flex.grow > 0) {
                main += free * n.flex.grow / total_grow;
            } else if (shrank and n.flex.shrink > 0) {
                // Canonical automatic minimum (§4.5): never below the
                // natural main (the content-based floor).
                main = @max(main, main - (-free) * n.flex.shrink / total_shrink);
            }
            n.rect.h = main;
            n.rect.y = y + m.top;
            y += main + m.top + m.bottom;
            finalizeMain(tree, n.id, available);
        }
    }
}

/// Size a container node from its children and position the children
/// relative to the container's CONTENT box (its border box inset by its own
/// border + padding). The container's own rect is set by its parent (or the
/// root pseudo-container).
fn placeContainer(tree: *WidgetTree, node: *WidgetNode, available: Size) void {
    const dir: Direction = switch (node.kind) {
        .column => .column,
        .row => .row,
        .button => .row, // the label child is centered on the button's main axis
        else => unreachable,
    };
    const gap: f32 = switch (node.kind) {
        .column => |c| c.gap,
        .row => |r| r.gap,
        .button => 0,
        else => unreachable,
    };
    const justify = node.style.justify;
    const cross = node.style.@"align";

    // The container's own box insets its content box on both axes.
    const box = node.box;
    const own_border_main = if (dir == .column) box.border.top + box.border.bottom else box.border.left + box.border.right;
    const own_padding_main = if (dir == .column) box.padding.top + box.padding.bottom else box.padding.left + box.padding.right;
    const own_border_cross = if (dir == .column) box.border.left + box.border.right else box.border.top + box.border.bottom;
    const own_padding_cross = if (dir == .column) box.padding.left + box.padding.right else box.padding.top + box.padding.bottom;
    const inset_main = own_border_main + own_padding_main;
    const inset_cross = own_border_cross + own_padding_cross;

    const count = node.children.len;
    var mains: [32]f32 = undefined;
    var crosses: [32]f32 = undefined;
    // Sum of children's MARGIN-box mains (border box + both margins) + gaps.
    var content: f32 = 0;
    var max_cross: f32 = 0;
    var total_grow: f32 = 0;
    var total_shrink: f32 = 0;

    for (0..count) |i| {
        const child = tree.node(node.children.items[i]) orelse continue;
        const natural = if (dir == .column) child.rect.h else child.rect.w;
        const main = if (child.flex.basis > 0) child.flex.basis else natural;
        mains[i] = main;
        const child_cross = if (dir == .column) child.rect.w else child.rect.h;
        crosses[i] = child_cross;
        if (child_cross > max_cross) max_cross = child_cross;
        if (child.flex.grow > 0) total_grow += child.flex.grow;
        if (child.flex.shrink > 0) total_shrink += child.flex.shrink;
        content += main + child.box.margin.left + child.box.margin.right;
    }
    if (count > 1) content += gap * @as(f32, @floatFromInt(count - 1));

    // Root-level containers lay out against `available`; nested containers
    // fit their own content — their parent allocates space later.
    const root_level = node.parent == .root;
    const avail_main: f32 = if (root_level)
        (if (dir == .column) available.height else available.width)
    else
        content;
    const avail_cross: f32 = if (root_level)
        (if (dir == .column) available.width else available.height)
    else
        max_cross;

    // Free space in the CONTENT box: the available main minus the container's
    // own border + padding, minus the children's margin-box extent. Nested
    // containers hug their content in the bottom-up pass (their parent sizes
    // them), so they have no free space; the top-down finalizeMain pass
    // re-runs grow/shrink/justify against the FINAL main.
    const free: f32 = if (root_level) avail_main - inset_main - content else 0;
    const grew = free > 0 and total_grow > 0;
    const shrank = free < 0 and total_shrink > 0;
    if (grew) {
        for (0..count) |i| {
            const child = tree.node(node.children.items[i]) orelse continue;
            if (child.flex.grow > 0) mains[i] += free * child.flex.grow / total_grow;
        }
    } else if (shrank) {
        const overflow = -free;
        for (0..count) |i| {
            const child = tree.node(node.children.items[i]) orelse continue;
            // Canonical automatic minimum (§4.5): never shrink below the
            // item's natural main (the content-based floor).
            const natural = mains[i];
            if (child.flex.shrink > 0)
                mains[i] = @max(natural, mains[i] - overflow * child.flex.shrink / total_shrink);
        }
    }

    // The container takes the available main size when space was distributed
    // (grow, shrink) or when justify spreads children across it; otherwise
    // it hugs its content (children's margin boxes + gaps) plus its own
    // border + padding.
    const spread = count > 0 and free > 0 and justify != .start;
    const container_main: f32 = if (grew or shrank or spread) avail_main else content + inset_main;
    // Border-box cross: stretch fills the available cross, otherwise it hugs
    // the largest child cross plus its own border + padding.
    const container_cross: f32 = if (cross == .stretch) avail_cross else max_cross + inset_cross;
    // The cross extent children are placed within: the container's OWN
    // CONTENT box cross (container_cross minus its border + padding).
    // Root-level containers may fill the available cross under stretch, but
    // with align = center/end the container hugs its content — centering
    // against the AVAILABLE cross would float children outside the box.
    const place_cross: f32 = @max(0, container_cross - inset_cross);

    if (dir == .column) {
        node.rect.w = container_cross;
        node.rect.h = container_main;
    } else {
        node.rect.w = container_main;
        node.rect.h = container_cross;
    }

    // Free space remaining for justify, after grow/shrink filled the
    // container. Children live in the content box, so the free extent is the
    // content box main minus their fitted margin-box extent.
    const fitted = content + (if (grew or shrank) free else 0);
    const free_for_justify = if (grew or shrank or spread)
        @max(0, container_main - inset_main - fitted)
    else
        0;
    var main_offset: f32 = 0;
    var extra_gap: f32 = 0;
    switch (justify) {
        .start => {},
        .center => main_offset = free_for_justify / 2,
        .end => main_offset = free_for_justify,
        .space_between => if (count > 1) {
            extra_gap = free_for_justify / @as(f32, @floatFromInt(count - 1));
        },
    }

    var main_pos = main_offset;
    for (0..count) |i| {
        const child = tree.node(node.children.items[i]) orelse continue;
        // Cross size: stretch fills the content-box cross minus the child's
        // own cross margins, otherwise the child keeps its natural cross.
        const cross_margin = if (dir == .column)
            child.box.margin.left + child.box.margin.right
        else
            child.box.margin.top + child.box.margin.bottom;
        const child_cross = if (cross == .stretch) @max(0, place_cross - cross_margin) else crosses[i];
        // Cross position per align, within the content-box cross extent.
        var cross_pos: f32 = 0;
        switch (cross) {
            .stretch, .start => {},
            .center => cross_pos = (place_cross - child_cross) / 2,
            .end => cross_pos = place_cross - child_cross,
        }
        const m = child.box.margin;
        if (dir == .column) {
            child.rect.w = child_cross;
            child.rect.h = mains[i];
            child.rect.x = m.left + cross_pos;
            child.rect.y = m.top + main_pos;
        } else {
            child.rect.h = child_cross;
            child.rect.w = mains[i];
            child.rect.y = m.top + cross_pos;
            child.rect.x = m.left + main_pos;
        }
        main_pos += mains[i] + m.left + m.right + (if (i + 1 < count) gap + extra_gap else 0);
    }
}

/// Measure a leaf node's natural BORDER-box size: the measure hook (or the
/// baked fallback) yields the CONTENT size; the node's border + padding are
/// added on top. Margins are not part of the node's rect — the parent
/// consumes them when positioning.
fn measureLeaf(node: *WidgetNode, measure: ?MeasureFn) void {
    const border = widget.sidesSum(node.box.border);
    const padding = widget.sidesSum(node.box.padding);
    switch (node.kind) {
        .label => |l| {
            const s = if (measure) |m|
                m(l.text, node.font_size, node.font_id)
            else
                // Approximate FreeType text at 20px: ~10px advance, 20px tall.
                Size{ .width = @as(f32, @floatFromInt(l.text.len)) * 10, .height = 20 };
            node.rect.w = s.width + border.w + padding.w;
            node.rect.h = s.height + border.h + padding.h;
        },
        .slider => |s| {
            const ms = if (measure) |m|
                m(s.label, node.font_size, node.font_id)
            else
                Size{ .width = 84, .height = 20 };
            const content_w = @max(0, ms.width);
            node.rect.w = @max(100, content_w + border.w + padding.w);
            node.rect.h = ms.height + border.h + padding.h;
        },
        .spacer => |s| {
            node.rect.w = s.size + border.w + padding.w;
            node.rect.h = s.size + border.h + padding.h;
        },
        else => unreachable,
    }
}

/// Place root-level nodes against `available` as a column: the root
/// pseudo-container with `FlexStyle{}` defaults (justify=start, align=stretch,
/// gap=0), including grow/shrink on root-level nodes. Root nodes get the
/// available size as their border box and are positioned at (0,0) relative
/// to the surface — their rects are already relative, so no offset folding.
/// Margins are honored: a node's margin box is the unit of the main-axis
/// advance, and stretch fills the available width minus its cross margins.
fn placeRoot(tree: *WidgetTree, available: Size) void {
    // No fixed buffer: root-level nodes are iterated directly over the nodes
    // slice (append order) in two passes — first count/sum, then place.
    var content: f32 = 0;
    var total_grow: f32 = 0;
    var total_shrink: f32 = 0;
    for (tree.nodes.items) |*n| {
        if (n.parent != .root) continue;
        const main = if (n.flex.basis > 0) n.flex.basis else n.rect.h;
        content += main + n.box.margin.top + n.box.margin.bottom;
        if (n.flex.grow > 0) total_grow += n.flex.grow;
        if (n.flex.shrink > 0) total_shrink += n.flex.shrink;
    }

    // The root pseudo-container has no border or padding, so its content box
    // main equals the available main: free = available.height - content.
    const free = available.height - content;
    const grew = free > 0 and total_grow > 0;
    const shrank = free < 0 and total_shrink > 0;

    var y: f32 = 0;
    for (tree.nodes.items) |*n| {
        if (n.parent != .root) continue;
        const m = n.box.margin;
        var main = if (n.flex.basis > 0) n.flex.basis else n.rect.h;
        if (grew and n.flex.grow > 0) {
            main += free * n.flex.grow / total_grow;
        } else if (shrank and n.flex.shrink > 0) {
            // Clamp at 0 — never a negative main.
            main = @max(0, main - (-free) * n.flex.shrink / total_shrink);
        }
        // Root align = stretch: fill the available width minus cross margins.
        n.rect.w = @max(0, available.width - m.left - m.right);
        n.rect.h = main;
        n.rect.x = m.left;
        n.rect.y = y + m.top;
        y += main + m.top + m.bottom;
    }
}

const testing = std.testing;

/// Append a node to the tree. Post-order invariant: children are appended
/// before their container, so parents are wired up by `wireChildren` after
/// the whole tree is built.
fn appendNode(tree: *WidgetTree, id: Id, parent: Id, kind: WidgetKind) !void {
    try tree.nodes.append(tree.allocator, .{
        .id = id,
        .kind = kind,
        .parent = parent,
    });
}

/// Register every non-root node in its parent's children array, in array
/// order (which is creation order).
fn wireChildren(tree: *WidgetTree) void {
    for (tree.nodes.items) |*n| {
        if (n.parent == .root) continue;
        const p = tree.node(n.parent) orelse continue;
        if (p.children.len == p.children.items.len) continue;
        p.children.items[p.children.len] = n.id;
        p.children.len += 1;
    }
}

test "column stacks labels with gap, x=0, heights 20" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    const id3: Id = @enumFromInt(3);
    const id4: Id = @enumFromInt(4);
    try appendNode(&tree, id1, id4, .{ .label = .{ .text = "aaa" } });
    try appendNode(&tree, id2, id4, .{ .label = .{ .text = "bbb" } });
    try appendNode(&tree, id3, id4, .{ .label = .{ .text = "ccc" } });
    try appendNode(&tree, id4, .root, .{ .column = .{ .gap = 4 } });
    wireChildren(&tree);

    layout(&tree, .{ .width = 800, .height = 600 });

    // 3 * 20 + 2 * 4 = 68; stretch fills the available width.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 800, .h = 68 }, tree.node(id4).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 800, .h = 20 }, tree.node(id1).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 24, .w = 800, .h = 20 }, tree.node(id2).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 48, .w = 800, .h = 20 }, tree.node(id3).?.rect);
}

test "column grow: first child gets remaining height" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    const id3: Id = @enumFromInt(3);
    try appendNode(&tree, id1, id3, .{ .label = .{ .text = "aaa" } });
    try appendNode(&tree, id2, id3, .{ .label = .{ .text = "bbb" } });
    try appendNode(&tree, id3, .root, .{ .column = .{ .gap = 4 } });
    wireChildren(&tree);
    tree.node(id1).?.flex = FlexChild{ .grow = 1 };

    layout(&tree, .{ .width = 800, .height = 600 });

    // 600 - 20 (second) - 4 (gap) = 576.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 800, .h = 576 }, tree.node(id1).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 580, .w = 800, .h = 20 }, tree.node(id2).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 800, .h = 600 }, tree.node(id3).?.rect);
}

test "row justify space_between: left/center/right, centers equidistant" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    const id3: Id = @enumFromInt(3);
    const id4: Id = @enumFromInt(4);
    try appendNode(&tree, id1, id4, .{ .label = .{ .text = "aaa" } });
    try appendNode(&tree, id2, id4, .{ .label = .{ .text = "bbb" } });
    try appendNode(&tree, id3, id4, .{ .label = .{ .text = "ccc" } });
    try appendNode(&tree, id4, .root, .{ .row = .{} });
    wireChildren(&tree);
    tree.node(id4).?.style.justify = .space_between;

    layout(&tree, .{ .width = 300, .height = 40 });

    // Free = 300 - 3*30 = 210, split into 2 gaps of 105.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 30, .h = 40 }, tree.node(id1).?.rect);
    try testing.expectEqual(Rect{ .x = 135, .y = 0, .w = 30, .h = 40 }, tree.node(id2).?.rect);
    try testing.expectEqual(Rect{ .x = 270, .y = 0, .w = 30, .h = 40 }, tree.node(id3).?.rect);
    // Centers 15, 150, 285 are 135 apart; the row spans the available width.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 300, .h = 40 }, tree.node(id4).?.rect);
}

test "column align center: children centered on x" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    const id3: Id = @enumFromInt(3);
    const id4: Id = @enumFromInt(4);
    try appendNode(&tree, id1, id4, .{ .label = .{ .text = "aa" } });
    try appendNode(&tree, id2, id4, .{ .label = .{ .text = "bb" } });
    try appendNode(&tree, id3, id4, .{ .label = .{ .text = "cc" } });
    try appendNode(&tree, id4, .root, .{ .column = .{} });
    wireChildren(&tree);
    tree.node(id4).?.style.@"align" = .center;

    layout(&tree, .{ .width = 100, .height = 600 });

    // x = (available.w - child.w) / 2 = (100 - 20) / 2 = 40.
    try testing.expectEqual(Rect{ .x = 40, .y = 0, .w = 20, .h = 20 }, tree.node(id1).?.rect);
    try testing.expectEqual(Rect{ .x = 40, .y = 20, .w = 20, .h = 20 }, tree.node(id2).?.rect);
    try testing.expectEqual(Rect{ .x = 40, .y = 40, .w = 20, .h = 20 }, tree.node(id3).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 60 }, tree.node(id4).?.rect);
}

test "column shrink: fixed children reduced proportionally to shrink weight" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    const id3: Id = @enumFromInt(3);
    const id4: Id = @enumFromInt(4);
    try appendNode(&tree, id1, id4, .{ .label = .{ .text = "aaa" } });
    try appendNode(&tree, id2, id4, .{ .label = .{ .text = "bbb" } });
    try appendNode(&tree, id3, id4, .{ .label = .{ .text = "ccc" } });
    try appendNode(&tree, id4, .root, .{ .column = .{} });
    wireChildren(&tree);
    tree.node(id1).?.flex = FlexChild{ .shrink = 1 };
    tree.node(id2).?.flex = FlexChild{ .shrink = 1 };
    tree.node(id3).?.flex = FlexChild{ .shrink = 2 };

    layout(&tree, .{ .width = 100, .height = 24 });

    // Content 60, overflow 36 over 24 — but the canonical automatic
    // minimum (§4.5) floors the shrink at each item's CONTENT size (the
    // labels' natural 20px), so nothing shrinks and the container
    // overflows visibly instead of crushing the text.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 20 }, tree.node(id1).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 20, .w = 100, .h = 20 }, tree.node(id2).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 40, .w = 100, .h = 20 }, tree.node(id3).?.rect);
    // The container still takes the available height.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 24 }, tree.node(id4).?.rect);
}

test "nested column: inner contains its labels, outer = inner + gap + sibling" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    const id3: Id = @enumFromInt(3);
    const id4: Id = @enumFromInt(4);
    const id5: Id = @enumFromInt(5);
    try appendNode(&tree, id1, id4, .{ .label = .{ .text = "aaa" } });
    try appendNode(&tree, id2, id4, .{ .label = .{ .text = "bbb" } });
    try appendNode(&tree, id4, id5, .{ .column = .{ .gap = 3 } });
    try appendNode(&tree, id3, id5, .{ .label = .{ .text = "ccc" } });
    try appendNode(&tree, id5, .root, .{ .column = .{ .gap = 4 } });
    wireChildren(&tree);
    tree.node(id5).?.style.@"align" = .start;

    layout(&tree, .{ .width = 400, .height = 600 });

    // All rects are RELATIVE: children of the inner column are positioned
    // against the inner column's content box (which, with zero box, coincides
    // with its border box), and the inner column itself against the outer
    // column's content box. Both containers sit at (0,0), so the values
    // coincide with absolute positions — but nothing is folded.

    // Inner: 20 + 3 + 20 = 43 tall, 30 wide (its own content).
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 30, .h = 43 }, tree.node(id4).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 30, .h = 20 }, tree.node(id1).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 23, .w = 30, .h = 20 }, tree.node(id2).?.rect);
    // Sibling after inner + outer gap.
    try testing.expectEqual(Rect{ .x = 0, .y = 47, .w = 30, .h = 20 }, tree.node(id3).?.rect);
    // Outer: 43 + 4 + 20 = 67; root stretch gives it the available width.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 400, .h = 67 }, tree.node(id5).?.rect);
}

test "column padding: children sit in the content box, natural h includes padding" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    const id3: Id = @enumFromInt(3);
    try appendNode(&tree, id1, id3, .{ .label = .{ .text = "aaa" } });
    try appendNode(&tree, id2, id3, .{ .label = .{ .text = "bbb" } });
    try appendNode(&tree, id3, .root, .{ .column = .{} });
    wireChildren(&tree);
    tree.node(id3).?.box.padding = .{ .left = 8, .top = 8 };

    layout(&tree, .{ .width = 800, .height = 600 });

    // Children are placed RELATIVE to the column's CONTENT box, which starts
    // at (8,8) inside the border box — visually the children sit at (8,8)
    // from the column's origin, but their rects are (0,0)-based. Content box
    // cross = 800 - padding.left (8) - padding.right (0) = 792.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 792, .h = 20 }, tree.node(id1).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 20, .w = 792, .h = 20 }, tree.node(id2).?.rect);
    // Natural height = 2*20 + padding top (8) + padding bottom (0) = 48.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 800, .h = 48 }, tree.node(id3).?.rect);
    // The content box sits at (8,8) inside the border box.
    try testing.expectEqual(Rect{ .x = 8, .y = 8, .w = 792, .h = 40 }, widget.contentRect(&tree, id3));
}

test "row margins: advance includes margin.l+r, gap sits between margin boxes" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    const id3: Id = @enumFromInt(3);
    try appendNode(&tree, id1, id3, .{ .label = .{ .text = "aaa" } });
    try appendNode(&tree, id2, id3, .{ .label = .{ .text = "bbb" } });
    try appendNode(&tree, id3, .root, .{ .row = .{ .gap = 3 } });
    wireChildren(&tree);
    tree.node(id1).?.box.margin = .{ .right = 6 };
    tree.node(id2).?.box.margin = .{ .left = 4 };

    layout(&tree, .{ .width = 300, .height = 40 });

    // B.rect.x = A.rect.w + A.margin.l + A.margin.r + gap + B.margin.l
    //          = 30 + 0 + 6 + 3 + 4 = 43. The gap sits between the two
    // MARGIN boxes; each margin pushes the border box in from there.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 30, .h = 40 }, tree.node(id1).?.rect);
    try testing.expectEqual(Rect{ .x = 43, .y = 0, .w = 30, .h = 40 }, tree.node(id2).?.rect);
    // Root row spans the available width (stretch); h hugs the children.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 300, .h = 40 }, tree.node(id3).?.rect);
}

test "column stretch subtracts child margins" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    try appendNode(&tree, id1, id2, .{ .label = .{ .text = "aaa" } });
    try appendNode(&tree, id2, .root, .{ .column = .{} });
    wireChildren(&tree);
    tree.node(id1).?.box.margin = .{ .left = 5, .right = 5 };

    layout(&tree, .{ .width = 100, .height = 600 });

    // Content box cross = 100 (no border/padding); stretched border w =
    // 100 - 5 - 5 = 90, offset by the left margin.
    try testing.expectEqual(Rect{ .x = 5, .y = 0, .w = 90, .h = 20 }, tree.node(id1).?.rect);
    // Container natural h = child main (20) + child margins (5+5) = 30.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 30 }, tree.node(id2).?.rect);
}

test "bordered container: children sit inside border + padding" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    const id3: Id = @enumFromInt(3);
    try appendNode(&tree, id1, id3, .{ .label = .{ .text = "aaa" } });
    try appendNode(&tree, id2, id3, .{ .label = .{ .text = "bbb" } });
    try appendNode(&tree, id3, .root, .{ .column = .{} });
    wireChildren(&tree);
    tree.node(id3).?.box.border = .{ .top = 1, .right = 2, .bottom = 1, .left = 2 };
    tree.node(id3).?.box.padding = .{ .left = 4, .top = 3 };

    layout(&tree, .{ .width = 800, .height = 600 });

    // Inset cross = border l+r (4) + padding l+r (4+0) = 8 -> children
    // stretch to 800 - 8 = 792 wide at x=0 relative to the content box
    // (visually 2+4 = 6 from the border-box origin).
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 792, .h = 20 }, tree.node(id1).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 20, .w = 792, .h = 20 }, tree.node(id2).?.rect);
    // Natural h = 2*20 + border t/b (2) + padding t/b (3+0) = 45.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 800, .h = 45 }, tree.node(id3).?.rect);
    // Content box inset by border (2,1) + padding (4,3) = (6,4).
    try testing.expectEqual(Rect{ .x = 6, .y = 4, .w = 792, .h = 40 }, widget.contentRect(&tree, id3));
}

test "nested row at nonzero offset: descendants stay parent-relative" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    const id3: Id = @enumFromInt(3);
    const id4: Id = @enumFromInt(4);
    const id5: Id = @enumFromInt(5);
    try appendNode(&tree, id1, id3, .{ .label = .{ .text = "aaa" } });
    try appendNode(&tree, id2, id3, .{ .label = .{ .text = "bbb" } });
    try appendNode(&tree, id5, id4, .{ .spacer = .{ .size = 40 } });
    try appendNode(&tree, id3, id4, .{ .row = .{} });
    try appendNode(&tree, id4, .root, .{ .column = .{} });
    wireChildren(&tree);

    layout(&tree, .{ .width = 400, .height = 600 });

    // The row sits at y=40 inside the column, but its labels keep
    // PARENT-RELATIVE rects (y=0 against the row's content box) — the 40px
    // offset is not folded into descendants.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 30, .h = 20 }, tree.node(id1).?.rect);
    try testing.expectEqual(Rect{ .x = 30, .y = 0, .w = 30, .h = 20 }, tree.node(id2).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 40, .w = 400, .h = 20 }, tree.node(id3).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 400, .h = 40 }, tree.node(id5).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 400, .h = 60 }, tree.node(id4).?.rect);
}

test "root column grow with padding: child ends at the content box bottom" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const label: Id = @enumFromInt(1);
    const col: Id = @enumFromInt(2);
    try appendNode(&tree, label, col, .{ .label = .{ .text = "aaa" } });
    try appendNode(&tree, col, .root, .{ .column = .{} });
    wireChildren(&tree);
    tree.node(label).?.flex = FlexChild{ .grow = 1 };
    // 12px top padding: the content box is 12px shorter than the border box.
    tree.node(col).?.box.padding = .{ .top = 12 };

    layout(&tree, .{ .width = 800, .height = 600 });

    // Free = 600 - 12 (inset) - 20 (content) = 568; the label grows to
    // 20 + 568 = 588 and ends exactly at the content box bottom (12 + 588).
    // Without the inset subtraction it would grow to 600 and overflow the
    // content box by 12px.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 800, .h = 588 }, tree.node(label).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 800, .h = 600 }, tree.node(col).?.rect);
    // The label fills the content box exactly.
    try testing.expectEqual(tree.node(label).?.rect.h, widget.contentRect(&tree, col).h);
}

test "column shrink clamps at zero: no negative mains, no inverted rects" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    const id3: Id = @enumFromInt(3);
    const id4: Id = @enumFromInt(4);
    try appendNode(&tree, id1, id4, .{ .label = .{ .text = "aaa" } });
    try appendNode(&tree, id2, id4, .{ .label = .{ .text = "bbb" } });
    try appendNode(&tree, id3, id4, .{ .label = .{ .text = "ccc" } });
    try appendNode(&tree, id4, .root, .{ .column = .{} });
    wireChildren(&tree);
    tree.node(id1).?.flex = FlexChild{ .shrink = 1 };
    tree.node(id2).?.flex = FlexChild{ .shrink = 1 };
    tree.node(id3).?.flex = FlexChild{ .shrink = 8 };

    layout(&tree, .{ .width = 100, .height = 10 });

    // Content 60 vs 10 available: the canonical automatic minimum (§4.5)
    // floors the shrink at each item's CONTENT size (the labels' natural
    // 20px) — the items hold their content and the container overflows
    // visibly instead of crushing the text to zero.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 20 }, tree.node(id1).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 20, .w = 100, .h = 20 }, tree.node(id2).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 40, .w = 100, .h = 20 }, tree.node(id3).?.rect);
    // No negative mains, and positions never go backwards.
    try testing.expect(tree.node(id1).?.rect.h >= 0);
    try testing.expect(tree.node(id2).?.rect.h >= 0);
    try testing.expect(tree.node(id3).?.rect.h >= 0);
    try testing.expect(tree.node(id2).?.rect.y >= tree.node(id1).?.rect.y);
    try testing.expect(tree.node(id3).?.rect.y >= tree.node(id2).?.rect.y);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 10 }, tree.node(id4).?.rect);
}

test "root-level margins: node offset by margin, width minus cross margins, advance includes main margins" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    try appendNode(&tree, id1, .root, .{ .label = .{ .text = "aaa" } });
    try appendNode(&tree, id2, .root, .{ .label = .{ .text = "bbb" } });
    wireChildren(&tree);
    tree.node(id1).?.box.margin = .{ .top = 20, .left = 10, .right = 10 };

    layout(&tree, .{ .width = 800, .height = 600 });

    // id1's margin box is 20 (main) + 20 (top) + 0 (bottom) = 40 tall: it
    // sits at y=20, x=10, and its stretched width is 800 - 10 - 10 = 780.
    try testing.expectEqual(Rect{ .x = 10, .y = 20, .w = 780, .h = 20 }, tree.node(id1).?.rect);
    // The next root node starts after id1's MARGIN box: 20 + 20 = 40.
    try testing.expectEqual(Rect{ .x = 0, .y = 40, .w = 800, .h = 20 }, tree.node(id2).?.rect);
}

test "placeRoot places all root-level nodes: no 64-node cap" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    // 70 root-level spacers (1x1 each) — more than the old 64-node buffer.
    for (0..70) |i| {
        try appendNode(&tree, @enumFromInt(@as(u32, @intCast(i + 1))), .root, .{ .spacer = .{ .size = 1 } });
    }
    wireChildren(&tree);

    layout(&tree, .{ .width = 800, .height = 600 });

    // The 70th spacer is placed at the 70th row — not left at (0,0) as the
    // 64-node cap would leave it.
    try testing.expectEqual(Rect{ .x = 0, .y = 69, .w = 800, .h = 1 }, tree.node(@enumFromInt(70)).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 800, .h = 1 }, tree.node(@enumFromInt(1)).?.rect);
}

test "finalizeMain: nested justify=end re-placed against the FINAL main" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const label: Id = @enumFromInt(1);
    const inner: Id = @enumFromInt(2);
    const outer: Id = @enumFromInt(3);
    try appendNode(&tree, label, inner, .{ .label = .{ .text = "aaa" } });
    try appendNode(&tree, inner, outer, .{ .column = .{} });
    try appendNode(&tree, outer, .root, .{ .column = .{} });
    wireChildren(&tree);
    tree.node(inner).?.style.justify = .end;
    // The outer column grows the inner column to the available height.
    tree.node(inner).?.flex = FlexChild{ .grow = 1 };

    layout(&tree, .{ .width = 800, .height = 600 });

    // Bottom-up, the inner column hugged its 20px label at y=0 (justify
    // never fires below the root). Top-down, the inner column's FINAL main
    // is 600, so the label is pushed to the END of its content box.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 800, .h = 600 }, tree.node(inner).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 580, .w = 800, .h = 20 }, tree.node(label).?.rect);
}

test "finalizeMain: nested grow child fills the FINAL content main" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const label: Id = @enumFromInt(1);
    const inner: Id = @enumFromInt(2);
    const outer: Id = @enumFromInt(3);
    try appendNode(&tree, label, inner, .{ .label = .{ .text = "aaa" } });
    try appendNode(&tree, inner, outer, .{ .column = .{} });
    try appendNode(&tree, outer, .root, .{ .column = .{} });
    wireChildren(&tree);
    tree.node(label).?.flex = FlexChild{ .grow = 1 };
    // The outer column stretches to the available height and grows the inner
    // column along with it.
    tree.node(inner).?.flex = FlexChild{ .grow = 1 };

    layout(&tree, .{ .width = 800, .height = 600 });

    // Bottom-up, the label never grew below the root (it stayed 20px tall).
    // Top-down, the inner column's FINAL main is 600 (grown by the outer
    // column), so the label grows to fill the inner content box.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 800, .h = 600 }, tree.node(outer).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 800, .h = 600 }, tree.node(inner).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 800, .h = 600 }, tree.node(label).?.rect);
}
