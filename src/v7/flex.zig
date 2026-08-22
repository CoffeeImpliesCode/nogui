//! v7 layout dispatcher — flexbox and block/absolute positioning.
//!
//! The flex path supports nowrap and wrapped line layout. Block containers
//! use normal-flow vertical stacking; absolute children are removed from flow
//! and resolve against their parent's content box. Every node rect remains a
//! relative BORDER box (see widget.zig's Rect doc).
//!
//! Flex pipeline: a bottom-up pass sizes every node and positions children
//! relative to their container's CONTENT box; placeRoot places root-level
//! nodes relative to the surface; top-down finalization forms lines, freezes
//! and distributes main-axis free space, resolves auto margins, distributes
//! line cross space, applies item alignment, and handles reverse directions.
//! Block finalization then resolves normal flow and absolute descendants.
//! No allocation: only in-place `WidgetNode.rect` writes.
//! Per the prototype spec (notes/v7-prototype-spec.md §6).
const std = @import("std");

const Id = @import("id.zig").Id;
const widget = @import("widget.zig");
const style = @import("style.zig");

const WidgetTree = widget.WidgetTree;
const WidgetNode = widget.WidgetNode;
const WidgetKind = widget.WidgetKind;
const Rect = widget.Rect;
const Size = widget.Size;

/// Main axis direction of a container.
pub const Direction = style.FlexDirection;

/// Line formation mode.
pub const FlexWrap = style.FlexWrap;

/// Distribution of free space between a container's children on the main axis.
pub const Justify = style.Justify;

/// Cross-axis sizing and positioning of a container's children.
pub const Align = style.Align;
pub const AlignContent = style.AlignContent;
pub const AlignSelf = style.AlignSelf;
/// text: the label; font_size: the node's px size (0 = host default).
pub const MeasureFn = *const fn (text: []const u8, font_size: f32, font_id: u8) Size;

/// Flex layout. Fills `WidgetNode.rect` for all nodes.
/// Root-level nodes (parent == .root) are laid out as a column against
/// `available` (the root pseudo-container, styled like `Style{}`:
/// justify=start, align=stretch, gap=0); children recurse per their
/// container's `Style`.
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
/// container's real content box is only final once ITS parent was sized,
/// top-down finalization uses main/cross/main/cross/main passes and ends with
/// a final main-axis distribution against the FINAL content box. No allocation.
pub fn layout(tree: *WidgetTree, available: Size) void {
    layoutWith(tree, available, null);
}

/// layout() with a host-supplied text measurer. The v7 core stays pure: the
/// measurer (demo-side FreeType metrics) returns CONTENT size (pure text
/// advances); measureLeaf adds the node's border + padding on top to form
/// its border box. Without it, leaves use the baked approximation below.
pub fn layoutWith(tree: *WidgetTree, available: Size, measure: ?MeasureFn) void {
    for (tree.nodes.items) |*node| {
        node.resolveTypedStyle(null, .{ .width = 0, .height = 0 });
    }
    // Bottom-up pass: leaves get natural sizes; containers compute their own
    // size and position children relative to the container's content box.
    for (tree.nodes.items) |*node| {
        switch (node.kind) {
            .column, .row, .button => if (node.style.display == .grid)
                layoutGridContainer(tree, node, available)
            else
                placeContainer(tree, node, available),
            else => measureLeaf(node, measure),
        }
    }
    // Root pseudo-container pass: place root-level nodes against `available`,
    // relative to the surface (rects are already relative, no offset folding).
    placeRoot(tree, available);
    // First final-main pass: nested containers never distribute space
    // bottom-up, their parent allocates it later. finalizeCross then
    // re-stretches every stretch-aligned child to the parent's FINAL content
    // cross, recursing so the propagation reaches nested containers (a
    // 776px grown card must stretch its slider to 758px, not leave it at
    // the 125px hug width). The first main pass runs before the first cross
    // pass: the stretch pass must see the container's grown main, or grown
    // cards never fill their stretched children.
    finalizeMain(tree, .root, available);
    finalizeCross(tree, .root, available);
    // The first cross pass can change a row's final width when the row is
    // nested inside a stretched column. Re-run main-axis distribution against
    // those final cross dimensions, then re-run cross sizing against any
    // container dimensions changed by that second main pass. The final main
    // pass propagates those cross allocations into same-axis descendants,
    // such as a row button whose ellipsized label may shrink below its natural
    // width. Update scroll offsets only after all five passes.
    finalizeMain(tree, .root, available);
    finalizeCross(tree, .root, available);
    finalizeMain(tree, .root, available);
    finalizeSpecialRoots(tree, available);
    for (tree.nodes.items) |*node| updateScrollOffset(tree, node);
}

fn updateScrollOffset(tree: *WidgetTree, node: *WidgetNode) void {
    if (node.scroll == null) return;
    const resolved = node.style;
    const container_content_w = @max(
        0,
        node.rect.w - resolved.border.left - resolved.border.right -
            resolved.padding.left - resolved.padding.right,
    );
    const container_content_h = @max(
        0,
        node.rect.h - resolved.border.top - resolved.border.bottom -
            resolved.padding.top - resolved.padding.bottom,
    );
    var content_w: f32 = 0;
    var content_h: f32 = 0;
    for (node.children.items[0..node.children.len]) |child_id| {
        const child = tree.node(child_id) orelse continue;
        const margin = child.style.margin;
        content_w = @max(content_w, child.rect.x + child.rect.w + margin.right);
        content_h = @max(content_h, child.rect.y + child.rect.h + margin.bottom);
    }
    node.scroll.?.state.max_offset = .{
        @max(0, content_w - container_content_w),
        @max(0, content_h - container_content_h),
    };
}

fn directionIsColumn(direction: Direction) bool {
    return style.directionIsColumn(direction);
}

fn directionIsReverse(direction: Direction) bool {
    return style.directionIsReverse(direction);
}

fn resolvedMainDimension(node: *const WidgetNode, direction: Direction) ?f32 {
    return if (directionIsColumn(direction))
        node.resolved_dimensions.height
    else
        node.resolved_dimensions.width;
}

fn resolvedCrossDimension(node: *const WidgetNode, direction: Direction) ?f32 {
    return if (directionIsColumn(direction))
        node.resolved_dimensions.width
    else
        node.resolved_dimensions.height;
}

fn resolvedMainMinimum(node: *const WidgetNode, direction: Direction) ?f32 {
    return if (directionIsColumn(direction))
        node.resolved_constraints.min_height orelse node.style.min_main
    else
        node.resolved_constraints.min_width orelse node.style.min_main;
}

fn resolvedMainFloor(node: *const WidgetNode, direction: Direction, natural: f32) f32 {
    return resolvedMainMinimum(node, direction) orelse natural;
}

/// Legacy flex basis is resolved on the parent's main axis, not the child's
/// own container direction. An indefinite parent leaves percentages unresolved.
fn resolvedFlexBasis(
    node: *const WidgetNode,
    containing_main: ?f32,
    intrinsic_main: f32,
) ?f32 {
    return node.style.flex_basis.resolve(containing_main, intrinsic_main) orelse
        if (node.style.basis > 0) node.style.basis else null;
}

fn clampMain(node: *const WidgetNode, direction: Direction, value: f32) f32 {
    const clamped = if (directionIsColumn(direction))
        node.resolved_style.clampHeight(value)
    else
        node.resolved_style.clampWidth(value);
    return if (resolvedMainMinimum(node, direction)) |minimum|
        @max(clamped, minimum)
    else
        clamped;
}

fn clampCross(node: *const WidgetNode, direction: Direction, value: f32) f32 {
    return if (directionIsColumn(direction))
        node.resolved_style.clampWidth(value)
    else
        node.resolved_style.clampHeight(value);
}

const MarginValue = struct {
    size: f32 = 0,
    auto: bool = false,
};

const AxisMargins = struct {
    leading: MarginValue,
    trailing: MarginValue,
};

fn effectiveWrap(node: *const WidgetNode) style.FlexWrap {
    return if (node.style.flex_wrap != .nowrap) node.style.flex_wrap else node.style.wrap;
}

fn effectiveMarginInset(
    value: style.LengthPercentageAuto,
    legacy: f32,
) style.LengthPercentageAuto {
    return switch (value) {
        .length => |length| if (length == legacy) value else .{ .length = legacy },
        .auto, .percent => if (legacy != 0) .{ .length = legacy } else value,
    };
}

fn resolvedMarginValue(
    value: style.LengthPercentageAuto,
    containing: ?f32,
    legacy: f32,
) MarginValue {
    return switch (value) {
        .auto => .{ .auto = true },
        .length => |length| .{ .size = length },
        .percent => |fraction| .{
            .size = if (containing) |size| size * fraction else legacy,
        },
    };
}

fn marginAxes(
    node: *const WidgetNode,
    direction: Direction,
    wrap: style.FlexWrap,
    containing: Size,
) struct { main: AxisMargins, cross: AxisMargins } {
    const margin = node.style.margin;
    const inset = node.style.margin_inset;
    const main_is_column = directionIsColumn(direction);
    const main_reverse = directionIsReverse(direction);
    const cross_reverse = wrap == .wrap_reverse;
    const main_containing: ?f32 = if (main_is_column) containing.height else containing.width;
    const cross_containing: ?f32 = if (main_is_column) containing.width else containing.height;
    const top = resolvedMarginValue(
        effectiveMarginInset(inset.top, margin.top),
        if (main_is_column) main_containing else cross_containing,
        margin.top,
    );
    const right = resolvedMarginValue(
        effectiveMarginInset(inset.right, margin.right),
        if (main_is_column) cross_containing else main_containing,
        margin.right,
    );
    const bottom = resolvedMarginValue(
        effectiveMarginInset(inset.bottom, margin.bottom),
        if (main_is_column) main_containing else cross_containing,
        margin.bottom,
    );
    const left = resolvedMarginValue(
        effectiveMarginInset(inset.left, margin.left),
        if (main_is_column) cross_containing else main_containing,
        margin.left,
    );
    if (main_is_column) {
        return .{
            .main = if (main_reverse)
                .{ .leading = bottom, .trailing = top }
            else
                .{ .leading = top, .trailing = bottom },
            .cross = if (cross_reverse)
                .{ .leading = right, .trailing = left }
            else
                .{ .leading = left, .trailing = right },
        };
    }
    return .{
        .main = if (main_reverse)
            .{ .leading = right, .trailing = left }
        else
            .{ .leading = left, .trailing = right },
        .cross = if (cross_reverse)
            .{ .leading = bottom, .trailing = top }
        else
            .{ .leading = top, .trailing = bottom },
    };
}

fn alignSelfAsAlign(value: style.AlignSelf, parent_align: style.Align) style.Align {
    return switch (value) {
        .auto => parent_align,
        .stretch => .stretch,
        .start => .start,
        .center => .center,
        .end => .end,
    };
}

fn childHasAutoMargin(node: *const WidgetNode) bool {
    return switch (node.style.margin_inset.top) {
        .auto => true,
        else => switch (node.style.margin_inset.right) {
            .auto => true,
            else => switch (node.style.margin_inset.bottom) {
                .auto => true,
                else => switch (node.style.margin_inset.left) {
                    .auto => true,
                    else => false,
                },
            },
        },
    };
}
fn childHasTypedMargin(node: *const WidgetNode) bool {
    const margin = node.style.margin;
    const fixed: style.Insets = .{
        .top = .{ .length = margin.top },
        .right = .{ .length = margin.right },
        .bottom = .{ .length = margin.bottom },
        .left = .{ .length = margin.left },
    };
    return !std.meta.eql(node.style.margin_inset, fixed);
}

fn needsAdvancedFlex(tree: *WidgetTree, parent: *const WidgetNode) bool {
    if (effectiveWrap(parent) != .nowrap) return true;
    if (directionIsReverse(parent.style.direction)) return true;
    for (parent.children.items[0..parent.children.len]) |child_id| {
        const child = tree.nodeConst(child_id) orelse continue;
        if (child.style.align_self != .auto) return true;
        if (childHasAutoMargin(child)) return true;
        if (childHasTypedMargin(child)) return true;
    }
    return false;
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
        if (p.style.display == .block or p.style.display == .grid) return;
        const resolved = p.style;
        if (needsAdvancedFlex(tree, p)) {
            for (p.children.items[0..p.children.len]) |child_id|
                finalizeCross(tree, child_id, available);
            return;
        }
        const content_w = @max(
            0,
            p.rect.w - resolved.border.left - resolved.border.right -
                resolved.padding.left - resolved.padding.right,
        );
        const content_h = @max(
            0,
            p.rect.h - resolved.border.top - resolved.border.bottom -
                resolved.padding.top - resolved.padding.bottom,
        );
        const @"align" = resolved.@"align";
        const is_col = directionIsColumn(p.style.direction);
        for (p.children.items[0..p.children.len]) |cid| {
            const child = tree.node(cid).?;
            if (child.style.position == .absolute) continue;
            const m = child.style.margin;
            child.resolveTypedStyle(
                .{ .width = content_w, .height = content_h },
                .{ .width = child.rect.w, .height = child.rect.h },
            );
            const natural = if (is_col) child.rect.w else child.rect.h;
            const child_direction: Direction = if (is_col) .column else .row;
            const explicit_cross = resolvedCrossDimension(child, child_direction);
            const extent = if (is_col) content_w else content_h;
            const margin_lead = if (is_col) m.left else m.top;
            const margin_trail = if (is_col) m.right else m.bottom;
            const size: f32 = if (explicit_cross) |value|
                clampCross(child, child_direction, value)
            else if (@"align" == .stretch)
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
            if (n.style.position == .absolute) continue;
            const m = n.style.margin;
            n.resolveTypedStyle(
                .{ .width = available.width, .height = available.height },
                .{ .width = n.rect.w, .height = n.rect.h },
            );
            n.rect.w = if (n.resolved_dimensions.width) |width|
                n.resolved_style.clampWidth(width)
            else
                @max(0, available.width - m.left - m.right);
            finalizeCross(tree, n.id, available);
        }
    }
}
/// The bottom-up pass gave nested containers their hug main (their parent
/// distributes space only later), so grow/shrink/justify never fired below
/// the root. This top-down pass re-computes each container's content main
/// from its children's FINAL border-box mains + margins + gaps, distributes
/// the free space in the container's FINAL content box (grow, or shrink via
/// scaled factors floored at each item's natural content main), and
/// re-places the children's main positions (justify included:
/// start/center/end/space_between). The container's own rect is already
/// final. Cross sizes/positions are untouched.
fn finalizeMainLegacy(tree: *WidgetTree, parent_id: Id, available: Size) void {
    const parent = if (parent_id == .root) null else tree.node(parent_id).?;
    if (parent) |p| {
        if (p.kind != .column and p.kind != .row and p.kind != .button) return;
        if (p.style.display == .block or p.style.display == .grid) return;
        const dir: Direction = p.style.direction;
        const gap: f32 = p.style.gap;
        const justify = p.style.justify;

        // The container's own box insets its content box on the main axis.
        const box = p.style;
        const own_border_main = if (directionIsColumn(dir))
            box.border.top + box.border.bottom
        else
            box.border.left + box.border.right;
        const own_padding_main = if (directionIsColumn(dir))
            box.padding.top + box.padding.bottom
        else
            box.padding.left + box.padding.right;
        const inset_main = own_border_main + own_padding_main;
        const parent_content: Size = .{
            .width = @max(0, p.rect.w - box.border.left - box.border.right -
                box.padding.left - box.padding.right),
            .height = @max(0, p.rect.h - box.border.top - box.border.bottom -
                box.padding.top - box.padding.bottom),
        };

        const count = p.children.len;
        var mains: [32]f32 = undefined;
        var content: f32 = 0;
        var total_grow: f32 = 0;
        var total_shrink: f32 = 0;
        var flow_count: usize = 0;
        // Children's FINAL border-box mains + margins + gaps.
        for (0..count) |i| {
            const child = tree.node(p.children.items[i]) orelse continue;
            if (child.style.position == .absolute) {
                mains[i] = 0;
                continue;
            }
            flow_count += 1;
            child.resolveTypedStyle(
                parent_content,
                .{ .width = child.rect.w, .height = child.rect.h },
            );
            mains[i] = if (directionIsColumn(dir)) child.rect.h else child.rect.w;
            if (resolvedMainDimension(child, dir)) |dimension| {
                mains[i] = clampMain(child, dir, dimension);
            } else if (resolvedFlexBasis(
                child,
                if (directionIsColumn(dir)) parent_content.height else parent_content.width,
                if (directionIsColumn(dir)) child.rect.h else child.rect.w,
            )) |basis| {
                mains[i] = clampMain(child, dir, basis);
            }
            // Main-axis margins: top+bottom in a column, left+right in a row.
            const m = child.style.margin;
            content += mains[i] + (if (directionIsColumn(dir)) m.top + m.bottom else m.left + m.right);
            if (child.style.grow > 0) total_grow += child.style.grow;
            if (child.style.shrink > 0) total_shrink += child.style.shrink;
        }
        if (flow_count > 1) content += gap * @as(f32, @floatFromInt(flow_count - 1));

        // Free space in the container's FINAL content box.
        const container_main = if (directionIsColumn(dir)) p.rect.h else p.rect.w;
        const free = (container_main - inset_main) - content;
        const grew = free > 0 and total_grow > 0;
        const shrank = free < 0 and total_shrink > 0;
        if (grew) {
            for (0..count) |i| {
                const child = tree.node(p.children.items[i]) orelse continue;
                if (child.style.position == .absolute) continue;
                if (child.style.grow > 0) mains[i] += free * child.style.grow / total_grow;
            }
        } else if (shrank) {
            // Scaled flex-shrink (CSS flexbox §9.7) with a content floor:
            // reduction_i = overflow × shrink_i × base_i / Σ(shrink × base)
            // over the shrinkable items, never below the item's natural
            // content main (natural_main — the canonical automatic minimum,
            // §4.5, so shrink never crushes the text out of the box). An
            // item that would clamp at its floor FREEZES there; the
            // remaining overflow is redistributed over the unfrozen items
            // until nothing new clamps.
            var remaining = -free;
            var frozen: [32]bool = [_]bool{false} ** 32;
            for (0..count) |_| {
                var total_scaled: f32 = 0;
                for (0..count) |i| {
                    if (frozen[i]) continue;
                    const child = tree.node(p.children.items[i]) orelse continue;
                    if (child.style.position == .absolute) continue;
                    if (child.style.shrink > 0) total_scaled += child.style.shrink * mains[i];
                }
                if (total_scaled <= 0) break;
                var any_frozen = false;
                for (0..count) |i| {
                    const child = tree.node(p.children.items[i]) orelse continue;
                    if (child.style.position == .absolute) continue;
                    if (frozen[i] or child.style.shrink <= 0) continue;
                    const base = mains[i];
                    const target = base - remaining * child.style.shrink * base / total_scaled;
                    const floor = resolvedMainFloor(child, dir, child.natural_main);
                    const clamped = @max(floor, target);
                    mains[i] = clamped;
                    if (clamped != target) {
                        frozen[i] = true;
                        any_frozen = true;
                    }
                }
                if (!any_frozen) break;
                // Recompute the overflow left after the freeze: frozen items
                // can no longer absorb any of it.
                var fitted: f32 = 0;
                for (0..count) |i| {
                    const child = tree.node(p.children.items[i]) orelse continue;
                    if (child.style.position == .absolute) continue;
                    const m = child.style.margin;
                    fitted += mains[i] + (if (directionIsColumn(dir)) m.top + m.bottom else m.left + m.right);
                }
                if (flow_count > 1) fitted += gap * @as(f32, @floatFromInt(flow_count - 1));
                remaining = @max(0, fitted - (container_main - inset_main));
                if (remaining <= 0) break;
            }
        }
        for (0..count) |i| {
            const child = tree.node(p.children.items[i]) orelse continue;
            if (child.style.position == .absolute) continue;
            mains[i] = clampMain(child, dir, mains[i]);
        }

        // Justify distributes the remaining free space (grow/shrink consumed
        // it all, so nothing is left when either ran).
        const spread = flow_count > 0 and free > 0 and justify != .start;
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
            .space_between => if (flow_count > 1) {
                extra_gap = free_for_justify / @as(f32, @floatFromInt(flow_count - 1));
            },
        }

        var main_pos = main_offset;
        var flow_index: usize = 0;
        for (0..count) |i| {
            const child = tree.node(p.children.items[i]) orelse continue;
            if (child.style.position == .absolute) continue;
            const m = child.style.margin;
            if (directionIsColumn(dir)) {
                child.rect.h = mains[i];
                child.rect.y = m.top + main_pos;
            } else {
                child.rect.w = mains[i];
                child.rect.x = m.left + main_pos;
            }
            // Advance by the border box + the MAIN-axis margins (top+bottom
            // in a column, left+right in a row).
            const m_main = if (directionIsColumn(dir)) m.top + m.bottom else m.left + m.right;
            flow_index += 1;
            main_pos += mains[i] + m_main +
                (if (flow_index < flow_count) gap + extra_gap else 0);
        }
        // Recurse so nested containers distribute against their FINAL mains.
        for (0..count) |i| finalizeMain(tree, p.children.items[i], available);
    } else {
        // Root pseudo-container: re-run the root grow/shrink against the
        // available main (root justify is the Style{} default: start).
        var content: f32 = 0;
        var total_grow: f32 = 0;
        var total_shrink: f32 = 0;
        for (tree.nodes.items) |*n| {
            if (n.style.position == .absolute) continue;
            if (n.parent != .root) continue;
            const margin = n.style.margin;
            content += n.rect.h + margin.top + margin.bottom;
            if (n.style.grow > 0) total_grow += n.style.grow;
            if (n.style.shrink > 0) total_shrink += n.style.shrink;
        }
        const free = available.height - content;
        const grew = free > 0 and total_grow > 0;
        const shrank = free < 0 and total_shrink > 0;
        var y: f32 = 0;
        for (tree.nodes.items) |*n| {
            if (n.style.position == .absolute) continue;
            if (n.parent != .root) continue;
            const m = n.style.margin;
            var main = n.rect.h;
            if (grew and n.style.grow > 0) {
                main += free * n.style.grow / total_grow;
            } else if (shrank and n.style.shrink > 0) {
                const floor = resolvedMainFloor(n, .column, n.natural_main);
                main = @max(floor, main - (-free) * n.style.shrink / total_shrink);
            }
            main = clampMain(n, .column, main);
            n.rect.h = main;
            n.rect.y = y + m.top;
            y += main + m.top + m.bottom;
            finalizeMain(tree, n.id, available);
        }
    }
}

const FlexLine = struct {
    first_flow: usize = 0,
    flow_count: usize = 0,
    cross_size: f32 = 0,
};

fn lineFitted(
    line: FlexLine,
    mains: *const [32]f32,
    main_leads: *const [32]f32,
    main_trails: *const [32]f32,
    gap: f32,
) f32 {
    var result: f32 = 0;
    for (0..line.flow_count) |offset| {
        const flow_index = line.first_flow + offset;
        result += mains[flow_index] + main_leads[flow_index] + main_trails[flow_index];
        if (offset + 1 < line.flow_count) result += gap;
    }
    return result;
}

fn shouldRecomputeAdvancedCross(
    tree: *WidgetTree,
    node: *const WidgetNode,
    direction: Direction,
) bool {
    if (node.parent == .root) {
        if (resolvedCrossDimension(node, direction) != null) return false;
        return !directionIsColumn(direction);
    }
    const parent = tree.nodeConst(node.parent) orelse return true;
    if (directionIsColumn(parent.style.direction) != directionIsColumn(direction)) return false;
    const item_align = alignSelfAsAlign(node.style.align_self, parent.style.@"align");
    if (item_align == .stretch) return false;
    if (childHasAutoMargin(node)) return false;
    return resolvedCrossDimension(node, direction) == null;
}

fn distributeAdvancedLine(
    tree: *WidgetTree,
    parent: *const WidgetNode,
    line: FlexLine,
    direction: Direction,
    available_main: f32,
    gap: f32,
    flow_indices: *const [32]usize,
    mains: *[32]f32,
    main_leads: *const [32]f32,
    main_trails: *const [32]f32,
) void {
    var frozen: [32]bool = [_]bool{false} ** 32;
    for (0..32) |_| {
        const fitted = lineFitted(line, mains, main_leads, main_trails, gap);
        const free = available_main - fitted;
        if (free == 0) break;
        var factor_total: f32 = 0;
        for (0..line.flow_count) |offset| {
            const flow_index = line.first_flow + offset;
            if (frozen[flow_index]) continue;
            const child = tree.node(parent.children.items[flow_indices[flow_index]]) orelse continue;
            if (free > 0) {
                if (child.style.grow > 0) factor_total += child.style.grow;
            } else if (child.style.shrink > 0) {
                factor_total += child.style.shrink * mains[flow_index];
            }
        }
        if (factor_total <= 0) break;
        var any_frozen = false;
        for (0..line.flow_count) |offset| {
            const flow_index = line.first_flow + offset;
            if (frozen[flow_index]) continue;
            const child = tree.node(parent.children.items[flow_indices[flow_index]]) orelse continue;
            const factor = if (free > 0)
                child.style.grow
            else
                child.style.shrink * mains[flow_index];
            if (factor <= 0) continue;
            const target = if (free > 0)
                mains[flow_index] + free * factor / factor_total
            else
                mains[flow_index] - (-free) * factor / factor_total;
            const floor = if (free < 0)
                resolvedMainFloor(child, direction, child.natural_main)
            else
                0;
            const clamped = if (free < 0)
                @max(floor, clampMain(child, direction, target))
            else
                clampMain(child, direction, target);
            mains[flow_index] = clamped;
            if (clamped != target) {
                frozen[flow_index] = true;
                any_frozen = true;
            }
        }
        if (!any_frozen) break;
    }
    for (0..line.flow_count) |offset| {
        const flow_index = line.first_flow + offset;
        const child = tree.node(parent.children.items[flow_indices[flow_index]]) orelse continue;
        mains[flow_index] = clampMain(child, direction, mains[flow_index]);
    }
}

fn layoutAdvancedFlexContainer(
    tree: *WidgetTree,
    node: *WidgetNode,
    _: Size,
) void {
    const direction = node.style.direction;
    const main_is_column = directionIsColumn(direction);
    const main_reverse = directionIsReverse(direction);
    const wrap = effectiveWrap(node);
    const cross_reverse = wrap == .wrap_reverse;
    const gap = @max(0, node.style.gap);
    const box = node.style;
    const inset_cross = if (main_is_column)
        box.border.left + box.border.right + box.padding.left + box.padding.right
    else
        box.border.top + box.border.bottom + box.padding.top + box.padding.bottom;
    const content: Size = .{
        .width = @max(0, node.rect.w - box.border.left - box.border.right -
            box.padding.left - box.padding.right),
        .height = @max(0, node.rect.h - box.border.top - box.border.bottom -
            box.padding.top - box.padding.bottom),
    };
    const available_main = if (main_is_column) content.height else content.width;
    var available_cross = if (main_is_column) content.width else content.height;

    var flow_indices: [32]usize = undefined;
    var item_mains: [32]f32 = undefined;
    var item_crosses: [32]f32 = undefined;
    var main_leads: [32]f32 = undefined;
    var main_trails: [32]f32 = undefined;
    var cross_leads: [32]f32 = undefined;
    var cross_trails: [32]f32 = undefined;
    var main_auto_leads: [32]bool = [_]bool{false} ** 32;
    var main_auto_trails: [32]bool = [_]bool{false} ** 32;
    var cross_auto_leads: [32]bool = [_]bool{false} ** 32;
    var cross_auto_trails: [32]bool = [_]bool{false} ** 32;
    var lines: [32]FlexLine = [_]FlexLine{.{}} ** 32;
    var flow_count: usize = 0;
    var line_count: usize = 0;

    for (0..node.children.len) |child_index| {
        const child = tree.node(node.children.items[child_index]) orelse continue;
        if (child.style.position == .absolute) continue;
        const natural_main = if (main_is_column) child.rect.h else child.rect.w;
        const natural_cross = if (main_is_column) child.rect.w else child.rect.h;
        child.natural_main = natural_main;
        child.resolveTypedStyle(content, .{ .width = child.rect.w, .height = child.rect.h });
        var main = if (child.style.basis > 0)
            child.style.basis
        else if (resolvedMainDimension(child, direction)) |dimension|
            dimension
        else if (resolvedFlexBasis(child, available_main, natural_main)) |basis|
            basis
        else
            natural_main;
        if (child.style.basis > 0 and child.style.box_sizing == .content_box) {
            main += if (main_is_column)
                child.style.border.top + child.style.border.bottom +
                    child.style.padding.top + child.style.padding.bottom
            else
                child.style.border.left + child.style.border.right +
                    child.style.padding.left + child.style.padding.right;
        }
        main = clampMain(child, direction, main);
        const cross = clampCross(
            child,
            direction,
            resolvedCrossDimension(child, direction) orelse natural_cross,
        );
        const margins = marginAxes(child, direction, wrap, content);
        flow_indices[flow_count] = child_index;
        item_mains[flow_count] = main;
        item_crosses[flow_count] = cross;
        main_leads[flow_count] = margins.main.leading.size;
        main_trails[flow_count] = margins.main.trailing.size;
        cross_leads[flow_count] = margins.cross.leading.size;
        cross_trails[flow_count] = margins.cross.trailing.size;
        main_auto_leads[flow_count] = margins.main.leading.auto;
        main_auto_trails[flow_count] = margins.main.trailing.auto;
        cross_auto_leads[flow_count] = margins.cross.leading.auto;
        cross_auto_trails[flow_count] = margins.cross.trailing.auto;

        const item_extent = main + margins.main.leading.size + margins.main.trailing.size;
        if (line_count == 0) {
            lines[0] = .{ .first_flow = 0, .flow_count = 0 };
            line_count = 1;
        }
        var line = &lines[line_count - 1];
        if (wrap != .nowrap and line.flow_count > 0 and
            lineFitted(line.*, &item_mains, &main_leads, &main_trails, gap) +
                gap + item_extent > available_main)
        {
            lines[line_count] = .{ .first_flow = flow_count, .flow_count = 0 };
            line_count += 1;
            line = &lines[line_count - 1];
        }
        line.flow_count += 1;
        line.cross_size = @max(
            line.cross_size,
            cross + margins.cross.leading.size + margins.cross.trailing.size,
        );
        flow_count += 1;
    }

    if (flow_count == 0) {
        updateScrollOffset(tree, node);
        return;
    }

    for (0..line_count) |line_index| {
        distributeAdvancedLine(
            tree,
            node,
            lines[line_index],
            direction,
            available_main,
            gap,
            &flow_indices,
            &item_mains,
            &main_leads,
            &main_trails,
        );
    }

    var line_cross_total: f32 = 0;
    for (0..line_count) |line_index| {
        line_cross_total += lines[line_index].cross_size;
        if (line_index + 1 < line_count) line_cross_total += gap;
    }
    const recompute_cross = shouldRecomputeAdvancedCross(tree, node, direction);
    if (recompute_cross and line_cross_total > available_cross) {
        available_cross = line_cross_total;
        if (main_is_column) {
            node.rect.w = available_cross + inset_cross;
        } else {
            node.rect.h = available_cross + inset_cross;
        }
    }
    // A nowrap line in a container with a final cross size uses that content
    // extent even when an item's cross margins overflow it. Stretch then
    // subtracts those margins without enlarging margin-free siblings.
    if (!recompute_cross and wrap == .nowrap) {
        lines[0].cross_size = available_cross;
        line_cross_total = available_cross;
    }

    var cross_free = @max(0, available_cross - line_cross_total);
    var line_offset: f32 = 0;
    var line_gap = gap;
    if (node.style.align_content == .stretch and line_count > 0) {
        const extra = cross_free / @as(f32, @floatFromInt(line_count));
        for (0..line_count) |line_index| lines[line_index].cross_size += extra;
        cross_free = 0;
    } else {
        switch (node.style.align_content) {
            .start, .stretch => {},
            .center => line_offset = cross_free / 2,
            .end => line_offset = cross_free,
            .space_between => if (line_count > 1) {
                line_gap += cross_free / @as(f32, @floatFromInt(line_count - 1));
                cross_free = 0;
            },
            .space_around => {
                line_gap += cross_free / @as(f32, @floatFromInt(line_count));
                line_offset = (line_gap - gap) / 2;
                cross_free = 0;
            },
        }
    }

    for (0..line_count) |line_index| {
        const line = lines[line_index];
        var main_free = @max(0, available_main - lineFitted(
            line,
            &item_mains,
            &main_leads,
            &main_trails,
            gap,
        ));
        var auto_main_count: usize = 0;
        for (0..line.flow_count) |offset| {
            const flow_index = line.first_flow + offset;
            if (main_auto_leads[flow_index]) auto_main_count += 1;
            if (main_auto_trails[flow_index]) auto_main_count += 1;
        }
        if (auto_main_count > 0 and main_free > 0) {
            const auto_size = main_free / @as(f32, @floatFromInt(auto_main_count));
            for (0..line.flow_count) |offset| {
                const flow_index = line.first_flow + offset;
                if (main_auto_leads[flow_index]) main_leads[flow_index] = auto_size;
                if (main_auto_trails[flow_index]) main_trails[flow_index] = auto_size;
            }
            main_free = 0;
        }
        var main_offset: f32 = 0;
        var extra_gap: f32 = 0;
        switch (node.style.justify) {
            .start => {},
            .center => main_offset = main_free / 2,
            .end => main_offset = main_free,
            .space_between => if (line.flow_count > 1) {
                extra_gap = main_free / @as(f32, @floatFromInt(line.flow_count - 1));
            },
        }

        const logical_cross = line_offset;
        for (0..line.flow_count) |offset| {
            const flow_index = line.first_flow + offset;
            const child_index = flow_indices[flow_index];
            const child = tree.node(node.children.items[child_index]) orelse continue;
            const item_align = alignSelfAsAlign(child.style.align_self, node.style.@"align");
            const cross_margin_total = cross_leads[flow_index] + cross_trails[flow_index];
            const explicit_cross = resolvedCrossDimension(child, direction) != null;
            var auto_cross_count: usize = 0;
            if (cross_auto_leads[flow_index]) auto_cross_count += 1;
            if (cross_auto_trails[flow_index]) auto_cross_count += 1;
            var child_cross = item_crosses[flow_index];
            if (item_align == .stretch and !explicit_cross and auto_cross_count == 0) {
                child_cross = clampCross(
                    child,
                    direction,
                    @max(0, line.cross_size - cross_margin_total),
                );
            }
            var cross_item_free = @max(0, line.cross_size - child_cross - cross_margin_total);
            var cross_lead = cross_leads[flow_index];
            if (auto_cross_count > 0 and cross_item_free > 0) {
                const auto_size = cross_item_free / @as(f32, @floatFromInt(auto_cross_count));
                if (cross_auto_leads[flow_index]) cross_lead = auto_size;
                cross_item_free = 0;
            }
            var cross_item_offset = cross_lead;
            if (auto_cross_count == 0) {
                cross_item_offset = switch (item_align) {
                    .stretch, .start => cross_lead,
                    .center => cross_lead + cross_item_free / 2,
                    .end => cross_lead + cross_item_free,
                };
            }

            const main_position = main_offset + main_leads[flow_index];
            const cross_position = logical_cross + cross_item_offset;
            if (main_is_column) {
                child.rect.h = item_mains[flow_index];
                child.rect.w = child_cross;
                child.rect.y = if (main_reverse)
                    available_main - main_position - item_mains[flow_index]
                else
                    main_position;
                child.rect.x = if (cross_reverse)
                    available_cross - cross_position - child_cross
                else
                    cross_position;
            } else {
                child.rect.w = item_mains[flow_index];
                child.rect.h = child_cross;
                child.rect.x = if (main_reverse)
                    available_main - main_position - item_mains[flow_index]
                else
                    main_position;
                child.rect.y = if (cross_reverse)
                    available_cross - cross_position - child_cross
                else
                    cross_position;
            }
            main_offset = main_position + item_mains[flow_index] + main_trails[flow_index] +
                if (offset + 1 < line.flow_count) gap + extra_gap else 0;
        }
        line_offset += line.cross_size + line_gap;
    }
    updateScrollOffset(tree, node);
}

fn finalizeMain(tree: *WidgetTree, parent_id: Id, available: Size) void {
    if (parent_id != .root) {
        const parent = tree.node(parent_id) orelse return;
        if (parent.kind != .column and parent.kind != .row and parent.kind != .button) return;
        if (parent.style.display == .block or parent.style.display == .grid) return;
        if (needsAdvancedFlex(tree, parent)) {
            layoutAdvancedFlexContainer(tree, parent, available);
            for (parent.children.items[0..parent.children.len]) |child_id|
                finalizeMain(tree, child_id, available);
            return;
        }
    }
    finalizeMainLegacy(tree, parent_id, available);
}

/// Size a container node from its children and position the children
/// relative to the container's CONTENT box (its border box inset by its own
/// border + padding). The container's own rect is set by its parent (or the
/// root pseudo-container).
fn blockInsetWidth(node: *const WidgetNode) f32 {
    return node.style.border.left + node.style.border.right +
        node.style.padding.left + node.style.padding.right;
}

fn blockInsetHeight(node: *const WidgetNode) f32 {
    return node.style.border.top + node.style.border.bottom +
        node.style.padding.top + node.style.padding.bottom;
}

fn blockDimension(
    node: *const WidgetNode,
    dimension: style.Dimension,
    containing: ?f32,
    intrinsic: f32,
    horizontal: bool,
) ?f32 {
    const resolved = dimension.resolve(containing, intrinsic) orelse return null;
    return if (node.style.box_sizing == .content_box)
        resolved + if (horizontal) blockInsetWidth(node) else blockInsetHeight(node)
    else
        resolved;
}

fn blockConstraint(
    node: *const WidgetNode,
    dimension: style.Dimension,
    containing: ?f32,
    intrinsic: f32,
    horizontal: bool,
) ?f32 {
    return blockDimension(node, dimension, containing, intrinsic, horizontal);
}

fn clampBlockAxis(
    node: *const WidgetNode,
    value: f32,
    containing: ?f32,
    intrinsic: f32,
    horizontal: bool,
) f32 {
    const minimum = blockConstraint(
        node,
        if (horizontal) node.style.min_size.width else node.style.min_size.height,
        containing,
        intrinsic,
        horizontal,
    );
    const maximum = blockConstraint(
        node,
        if (horizontal) node.style.max_size.width else node.style.max_size.height,
        containing,
        intrinsic,
        horizontal,
    );
    var result = @max(0, value);
    if (minimum) |min_value| result = @max(result, min_value);
    if (maximum) |max_value| {
        if (minimum) |min_value| {
            if (max_value >= min_value) result = @min(result, max_value);
        } else {
            result = @min(result, max_value);
        }
    }
    return result;
}

fn styleDimensionIsDefinite(dimension: style.Dimension, containing_definite: bool) bool {
    return switch (dimension) {
        .length, .min_content, .max_content => true,
        .percent => containing_definite,
        .auto => false,
    };
}

fn applyRelativeInsets(
    node: *WidgetNode,
    containing: Size,
    width_definite: bool,
    height_definite: bool,
) void {
    const left = node.style.inset.left.resolve(if (width_definite) containing.width else null);
    const right = node.style.inset.right.resolve(if (width_definite) containing.width else null);
    const top = node.style.inset.top.resolve(if (height_definite) containing.height else null);
    const bottom = node.style.inset.bottom.resolve(if (height_definite) containing.height else null);
    if (left) |value| {
        node.rect.x += value;
    } else if (right) |value| {
        node.rect.x -= value;
    }
    if (top) |value| {
        node.rect.y += value;
    } else if (bottom) |value| {
        node.rect.y -= value;
    }
}

fn placeBlockContainer(tree: *WidgetTree, node: *WidgetNode, available: Size) void {
    const inset_width = blockInsetWidth(node);
    const inset_height = blockInsetHeight(node);
    var content_height: f32 = 0;
    var max_child_width: f32 = 0;

    for (node.children.items[0..node.children.len]) |child_id| {
        const child = tree.node(child_id) orelse continue;
        if (child.style.position == .absolute) continue;
        const margin = child.style.margin;
        content_height += child.rect.h + margin.top + margin.bottom;
        max_child_width = @max(
            max_child_width,
            child.rect.w + margin.left + margin.right,
        );
    }

    const intrinsic: Size = .{
        .width = max_child_width + inset_width,
        .height = content_height + inset_height,
    };
    node.resolveTypedStyle(null, intrinsic);
    const explicit_width = blockDimension(
        node,
        node.style.size.width,
        null,
        intrinsic.width,
        true,
    );
    const explicit_height = blockDimension(
        node,
        node.style.size.height,
        null,
        intrinsic.height,
        false,
    );
    node.rect.w = clampBlockAxis(
        node,
        explicit_width orelse intrinsic.width,
        null,
        intrinsic.width,
        true,
    );
    node.rect.h = clampBlockAxis(
        node,
        explicit_height orelse intrinsic.height,
        null,
        intrinsic.height,
        false,
    );

    var cursor_y: f32 = 0;
    for (node.children.items[0..node.children.len]) |child_id| {
        const child = tree.node(child_id) orelse continue;
        if (child.style.position == .absolute) continue;
        const margin = child.style.margin;
        child.rect.x = margin.left;
        child.rect.y = cursor_y + margin.top;
        cursor_y += child.rect.h + margin.top + margin.bottom;
    }
    _ = available;
}

fn placeAbsoluteChild(
    child: *WidgetNode,
    containing: Size,
    width_definite: bool,
    height_definite: bool,
) void {
    const width_containing = if (width_definite) containing.width else null;
    const height_containing = if (height_definite) containing.height else null;
    const intrinsic: Size = .{ .width = child.rect.w, .height = child.rect.h };
    const raw_width = child.style.size.width.resolve(width_containing, intrinsic.width);
    const raw_height = child.style.size.height.resolve(height_containing, intrinsic.height);
    const left = child.style.inset.left.resolve(width_containing);
    const right = child.style.inset.right.resolve(width_containing);
    const top = child.style.inset.top.resolve(height_containing);
    const bottom = child.style.inset.bottom.resolve(height_containing);
    child.resolveTypedStyleAxes(
        width_containing,
        height_containing,
        intrinsic,
    );
    const margin = child.style.margin;
    const width_from_insets = raw_width == null and left != null and right != null;
    const height_from_insets = raw_height == null and top != null and bottom != null;
    var width = if (width_from_insets)
        @max(0, containing.width - left.? - right.? - margin.left - margin.right)
    else
        blockDimension(child, child.style.size.width, width_containing, intrinsic.width, true) orelse
            intrinsic.width;
    var height = if (height_from_insets)
        @max(0, containing.height - top.? - bottom.? - margin.top - margin.bottom)
    else
        blockDimension(child, child.style.size.height, height_containing, intrinsic.height, false) orelse
            intrinsic.height;

    if (child.style.aspect_ratio) |ratio| {
        if (ratio > 0) {
            if ((raw_width != null or width_from_insets) and
                raw_height == null and !height_from_insets)
            {
                height = width / ratio;
            } else if (raw_width == null and
                (raw_height != null or height_from_insets) and
                !width_from_insets)
            {
                width = height * ratio;
            }
        }
    }
    width = clampBlockAxis(child, width, width_containing, intrinsic.width, true);
    height = clampBlockAxis(child, height, height_containing, intrinsic.height, false);
    child.rect.w = width;
    child.rect.h = height;

    if (left) |value| {
        child.rect.x = value + margin.left;
    } else if (right) |value| {
        child.rect.x = containing.width - value - width - margin.right;
    } else {
        child.rect.x = margin.left;
    }
    if (top) |value| {
        child.rect.y = value + margin.top;
    } else if (bottom) |value| {
        child.rect.y = containing.height - value - height - margin.bottom;
    } else {
        child.rect.y = margin.top;
    }
}
fn reflowFlexContainer(tree: *WidgetTree, node: *WidgetNode, available: Size) void {
    if (node.kind != .column and node.kind != .row and node.kind != .button) return;
    if (node.style.display != .flex) return;
    finalizeMain(tree, node.id, available);
    finalizeCross(tree, node.id, available);
}

fn finalizeBlockChildren(
    tree: *WidgetTree,
    parent: *WidgetNode,
    available: Size,
    width_definite: bool,
    height_definite: bool,
) void {
    const containing: Size = .{
        .width = @max(
            0,
            parent.rect.w - parent.style.border.left - parent.style.border.right -
                parent.style.padding.left - parent.style.padding.right,
        ),
        .height = @max(
            0,
            parent.rect.h - parent.style.border.top - parent.style.border.bottom -
                parent.style.padding.top - parent.style.padding.bottom,
        ),
    };
    var cursor_y: f32 = 0;
    for (parent.children.items[0..parent.children.len]) |child_id| {
        const child = tree.node(child_id) orelse continue;
        if (child.style.position == .absolute) {
            placeAbsoluteChild(child, containing, width_definite, height_definite);
            reflowFlexContainer(tree, child, available);
            continue;
        }
        const margin = child.style.margin;
        const width_containing = if (width_definite) containing.width else null;
        const height_containing = if (height_definite) containing.height else null;
        child.resolveTypedStyleAxes(
            width_containing,
            height_containing,
            .{ .width = child.rect.w, .height = child.rect.h },
        );
        const width = blockDimension(
            child,
            child.style.size.width,
            width_containing,
            child.rect.w,
            true,
        ) orelse if (width_definite)
            @max(0, containing.width - margin.left - margin.right)
        else
            child.rect.w;
        const height = blockDimension(
            child,
            child.style.size.height,
            height_containing,
            child.rect.h,
            false,
        ) orelse child.rect.h;
        child.rect.w = clampBlockAxis(child, width, width_containing, child.rect.w, true);
        child.rect.h = clampBlockAxis(child, height, height_containing, child.rect.h, false);
        child.rect.x = margin.left;
        child.rect.y = cursor_y + margin.top;
        applyRelativeInsets(child, containing, width_definite, height_definite);
        cursor_y += child.rect.h + margin.top + margin.bottom;
        reflowFlexContainer(tree, child, available);
    }
}

fn finalizeSpecialNode(
    tree: *WidgetTree,
    node: *WidgetNode,
    available: Size,
    width_definite: bool,
    height_definite: bool,
) void {
    if (node.kind != .column and node.kind != .row and node.kind != .button) return;
    if (node.style.display == .block) {
        finalizeBlockChildren(tree, node, available, width_definite, height_definite);
    } else if (node.style.display == .grid) {
        layoutGridContainer(tree, node, available);
        const containing: Size = .{
            .width = @max(
                0,
                node.rect.w - node.style.border.left - node.style.border.right -
                    node.style.padding.left - node.style.padding.right,
            ),
            .height = @max(
                0,
                node.rect.h - node.style.border.top - node.style.border.bottom -
                    node.style.padding.top - node.style.padding.bottom,
            ),
        };
        for (node.children.items[0..node.children.len]) |child_id| {
            const child = tree.node(child_id) orelse continue;
            if (child.style.position == .absolute) {
                placeAbsoluteChild(child, containing, width_definite, height_definite);
            } else {
                applyRelativeInsets(child, containing, true, true);
            }
        }
    } else {
        const containing: Size = .{
            .width = @max(
                0,
                node.rect.w - node.style.border.left - node.style.border.right -
                    node.style.padding.left - node.style.padding.right,
            ),
            .height = @max(
                0,
                node.rect.h - node.style.border.top - node.style.border.bottom -
                    node.style.padding.top - node.style.padding.bottom,
            ),
        };
        for (node.children.items[0..node.children.len]) |child_id| {
            const child = tree.node(child_id) orelse continue;
            if (child.style.position == .absolute) {
                placeAbsoluteChild(child, containing, width_definite, height_definite);
                reflowFlexContainer(tree, child, available);
            } else {
                applyRelativeInsets(child, containing, true, true);
            }
        }
    }

    for (node.children.items[0..node.children.len]) |child_id| {
        const child = tree.node(child_id) orelse continue;
        const child_width_definite = true;
        const child_height_definite = if (node.style.display == .block)
            styleDimensionIsDefinite(
                child.style.size.height,
                height_definite,
            )
        else
            true;
        finalizeSpecialNode(
            tree,
            child,
            available,
            child_width_definite,
            child_height_definite,
        );
    }
}
fn finalizeSpecialRoots(tree: *WidgetTree, available: Size) void {
    for (tree.nodes.items) |*node| {
        if (node.parent != .root) continue;
        if (node.style.position == .absolute) {
            placeAbsoluteChild(node, available, true, true);
            reflowFlexContainer(tree, node, available);
        } else if (node.style.display == .grid) {
            const intrinsic: Size = .{ .width = node.rect.w, .height = node.rect.h };
            node.resolveTypedStyleAxes(available.width, available.height, intrinsic);
            const width = blockDimension(
                node,
                node.style.size.width,
                available.width,
                intrinsic.width,
                true,
            ) orelse node.rect.w;
            const height = blockDimension(
                node,
                node.style.size.height,
                available.height,
                intrinsic.height,
                false,
            ) orelse node.rect.h;
            node.rect.w = clampBlockAxis(node, width, available.width, intrinsic.width, true);
            node.rect.h = clampBlockAxis(node, height, available.height, intrinsic.height, false);
            layoutGridContainer(tree, node, available);
        } else if (node.style.display == .block) {
            const intrinsic: Size = .{ .width = node.rect.w, .height = node.rect.h };
            node.resolveTypedStyleAxes(
                available.width,
                available.height,
                intrinsic,
            );
            const width = blockDimension(
                node,
                node.style.size.width,
                available.width,
                intrinsic.width,
                true,
            ) orelse node.rect.w;
            const height = blockDimension(
                node,
                node.style.size.height,
                available.height,
                intrinsic.height,
                false,
            ) orelse node.rect.h;
            node.rect.w = clampBlockAxis(node, width, available.width, intrinsic.width, true);
            node.rect.h = clampBlockAxis(node, height, available.height, intrinsic.height, false);
        }
        if (node.style.position == .relative) {
            const relative_height_definite = if (node.style.display == .block)
                styleDimensionIsDefinite(node.style.size.height, true)
            else
                true;
            applyRelativeInsets(node, available, true, relative_height_definite);
        }
        const width_definite = true;
        const height_definite = if (node.style.display == .block)
            styleDimensionIsDefinite(node.style.size.height, true)
        else
            true;
        finalizeSpecialNode(tree, node, available, width_definite, height_definite);
    }
}

fn placeContainer(tree: *WidgetTree, node: *WidgetNode, available: Size) void {
    if (node.style.display == .block) {
        placeBlockContainer(tree, node, available);
        return;
    }
    const dir: Direction = node.style.direction;
    const gap: f32 = node.style.gap;
    const justify = node.style.justify;
    const cross = node.style.@"align";
    const advanced = needsAdvancedFlex(tree, node);
    // The container's own box insets its content box on both axes.
    const box = node.style;
    const own_border_main = if (directionIsColumn(dir))
        box.border.top + box.border.bottom
    else
        box.border.left + box.border.right;
    const own_padding_main = if (directionIsColumn(dir))
        box.padding.top + box.padding.bottom
    else
        box.padding.left + box.padding.right;
    const own_border_cross = if (directionIsColumn(dir))
        box.border.left + box.border.right
    else
        box.border.top + box.border.bottom;
    const own_padding_cross = if (directionIsColumn(dir))
        box.padding.left + box.padding.right
    else
        box.padding.top + box.padding.bottom;
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
    var flow_count: usize = 0;

    for (0..count) |i| {
        const child = tree.node(node.children.items[i]) orelse continue;
        if (child.style.position == .absolute) {
            mains[i] = 0;
            crosses[i] = 0;
            continue;
        }
        flow_count += 1;
        const natural = if (directionIsColumn(dir)) child.rect.h else child.rect.w;
        // The natural (pre-basis) main is the flex-shrink floor.
        child.natural_main = natural;
        child.resolveTypedStyle(null, .{ .width = child.rect.w, .height = child.rect.h });
        // Basis remains content-box under the legacy option. Typed sizes and
        // flex basis are resolved values and therefore use border-box extents.
        var main = if (child.style.basis > 0)
            child.style.basis
        else if (resolvedMainDimension(child, dir)) |dimension|
            dimension
        else if (resolvedFlexBasis(child, null, natural)) |basis|
            basis
        else
            natural;
        if (child.style.basis > 0 and child.style.box_sizing == .content_box) {
            const cb = child.style;
            main += if (directionIsColumn(dir))
                cb.border.top + cb.border.bottom + cb.padding.top + cb.padding.bottom
            else
                cb.border.left + cb.border.right + cb.padding.left + cb.padding.right;
        }
        main = clampMain(child, dir, main);
        mains[i] = main;
        const natural_cross = if (directionIsColumn(dir)) child.rect.w else child.rect.h;
        const child_cross = resolvedCrossDimension(child, dir) orelse natural_cross;
        crosses[i] = clampCross(child, dir, child_cross);
        if (crosses[i] > max_cross) max_cross = crosses[i];
        if (child.style.grow > 0) total_grow += child.style.grow;
        if (child.style.shrink > 0) total_shrink += child.style.shrink;
        // Main-axis margins: top+bottom in a column, left+right in a row.
        const cm = child.style.margin;
        content += main + (if (directionIsColumn(dir)) cm.top + cm.bottom else cm.left + cm.right);
    }
    if (flow_count > 1) content += gap * @as(f32, @floatFromInt(flow_count - 1));

    // Root-level containers lay out against `available`; nested containers
    // fit their own content — their parent allocates space later.
    const root_level = node.parent == .root;
    const avail_main: f32 = if (root_level)
        (if (directionIsColumn(dir)) available.height else available.width)
    else
        content;
    const avail_cross: f32 = if (root_level)
        (if (directionIsColumn(dir)) available.width else available.height)
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
            if (child.style.position == .absolute) continue;
            if (child.style.grow > 0) mains[i] += free * child.style.grow / total_grow;
        }
    } else if (shrank) {
        // Scaled flex-shrink (CSS flexbox §9.7) with a content floor:
        // reduction_i = overflow × shrink_i × base_i / Σ(shrink × base) over
        // the shrinkable items, never below the item's natural content main
        // (the canonical automatic minimum, §4.5). An item that would clamp
        // at its floor FREEZES there; the remaining overflow is
        // redistributed over the unfrozen items until nothing new clamps.
        var remaining = -free;
        var frozen: [32]bool = [_]bool{false} ** 32;
        for (0..count) |_| {
            var total_scaled: f32 = 0;
            for (0..count) |i| {
                if (frozen[i]) continue;
                const child = tree.node(node.children.items[i]) orelse continue;
                if (child.style.position == .absolute) continue;
                if (child.style.shrink > 0) total_scaled += child.style.shrink * mains[i];
            }
            if (total_scaled <= 0) break;
            var any_frozen = false;
            for (0..count) |i| {
                const child = tree.node(node.children.items[i]) orelse continue;
                if (frozen[i] or child.style.shrink <= 0) continue;
                if (child.style.position == .absolute) continue;
                const base = mains[i];
                const target = base - remaining * child.style.shrink * base / total_scaled;
                const floor = resolvedMainFloor(child, dir, child.natural_main);
                const clamped = @max(floor, target);
                mains[i] = clamped;
                if (clamped != target) {
                    frozen[i] = true;
                    any_frozen = true;
                }
            }
            if (!any_frozen) break;
            // Recompute the overflow left after the freeze: frozen items can
            // no longer absorb any of it.
            var fitted: f32 = 0;
            for (0..count) |i| {
                const child = tree.node(node.children.items[i]) orelse continue;
                if (child.style.position == .absolute) continue;
                const m = child.style.margin;
                fitted += mains[i] + (if (directionIsColumn(dir)) m.top + m.bottom else m.left + m.right);
            }
            if (flow_count > 1) fitted += gap * @as(f32, @floatFromInt(flow_count - 1));
            remaining = @max(0, fitted - (avail_main - inset_main));
            if (remaining <= 0) break;
        }
    }

    for (0..count) |i| {
        const child = tree.node(node.children.items[i]) orelse continue;
        if (child.style.position == .absolute) continue;
        mains[i] = clampMain(child, dir, mains[i]);
    }
    // The container takes the available main size when space was distributed
    // (grow, shrink) or when justify spreads children across it; otherwise
    // it hugs its content (children's margin boxes + gaps) plus its own
    const spread = flow_count > 0 and free > 0 and justify != .start;
    const container_main: f32 = if (grew or shrank or spread) avail_main else content + inset_main;
    // Border-box cross: a ROOT-LEVEL stretch fills the available cross; a
    // NESTED stretch hugs its content (largest child cross + its own border
    // + padding) — the parent's final cross is unknown bottom-up, and the
    // top-down finalizeCross pass re-stretches it against that. Non-stretch
    // always hugs.
    const container_cross: f32 = if (cross == .stretch and root_level) avail_cross else max_cross + inset_cross;
    // The cross extent children are placed within: the container's OWN
    // CONTENT box cross (container_cross minus its border + padding).
    // Root-level containers may fill the available cross under stretch, but
    // with align = center/end the container hugs its content — centering
    // against the AVAILABLE cross would float children outside the box.
    const place_cross: f32 = @max(0, container_cross - inset_cross);

    if (directionIsColumn(dir)) {
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
        .space_between => if (flow_count > 1) {
            extra_gap = free_for_justify / @as(f32, @floatFromInt(flow_count - 1));
        },
    }

    var main_pos = main_offset;
    var flow_index: usize = 0;
    for (0..count) |i| {
        const child = tree.node(node.children.items[i]) orelse continue;
        if (child.style.position == .absolute) continue;
        // Cross size: stretch fills the content-box cross minus the child's
        // own cross margins, otherwise the child keeps its natural cross.
        const cross_margin = if (directionIsColumn(dir))
            child.style.margin.left + child.style.margin.right
        else
            child.style.margin.top + child.style.margin.bottom;
        const child_cross = if (!advanced and cross == .stretch)
            @max(0, place_cross - cross_margin)
        else
            crosses[i];
        // Cross position per align, within the content-box cross extent.
        var cross_pos: f32 = 0;
        switch (cross) {
            .stretch, .start => {},
            .center => cross_pos = (place_cross - child_cross) / 2,
            .end => cross_pos = place_cross - child_cross,
        }
        const m = child.style.margin;
        if (directionIsColumn(dir)) {
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
        // Advance by the border box + the MAIN-axis margins (top+bottom in a
        // column, left+right in a row).
        const m_main = if (directionIsColumn(dir)) m.top + m.bottom else m.left + m.right;
        flow_index += 1;
        main_pos += mains[i] + m_main +
            (if (flow_index < flow_count) gap + extra_gap else 0);
    }
    updateScrollOffset(tree, node);
}

/// Cap a measured text width when clipped or ellipsized text opts into a positive maximum.
fn capTextWidth(node: *const WidgetNode, width: f32) f32 {
    if (node.text_overflow == .visible) return width;
    if (node.text_max_width) |max_width| {
        if (max_width > 0) return @min(width, max_width);
    }
    return width;
}

/// Measure a leaf node's natural BORDER-box size: the measure hook (or the
/// baked fallback) yields the CONTENT size; the node's border + padding are
/// added on top. Margins are not part of the node's rect — the parent
/// consumes them when positioning.
fn measureLeaf(node: *WidgetNode, measure: ?MeasureFn) void {
    const border = widget.sidesSum(node.style.border);
    const padding = widget.sidesSum(node.style.padding);
    switch (node.kind) {
        .label => |l| {
            const s = if (measure) |m|
                m(l.text, node.font_size, node.font_id)
            else blk: {
                // Approximate FreeType text at 20px: ~10px advance, 20px
                // tall; an explicit font_size scales both dims (0 = the
                // baked 20px default).
                const scale: f32 = if (node.font_size > 0) node.font_size / 20 else 1;
                const len_f: f32 = @floatFromInt(@min(l.text.len, 1 << 24));
                break :blk Size{ .width = len_f * 10 * scale, .height = 20 * scale };
            };
            const content_w = capTextWidth(node, s.width);
            node.rect.w = content_w + border.w + padding.w;
            node.rect.h = s.height + border.h + padding.h;
        },
        .slider => {
            const visual_label = widget.sliderVisualLabel(node.kind);
            const ms = if (visual_label.len == 0)
                Size{ .width = 0, .height = 0 }
            else if (measure) |m|
                m(visual_label, node.font_size, node.font_id)
            else
                Size{ .width = 84, .height = 20 };
            const content_w = @max(0, capTextWidth(node, ms.width));
            node.rect.w = @max(100, content_w + border.w + padding.w);
            node.rect.h = @max(widget.slider_rail_height, ms.height) + border.h + padding.h;
        },
        .spacer => |s| {
            node.rect.w = s.size + border.w + padding.w;
            node.rect.h = s.size + border.h + padding.h;
        },
        else => unreachable,
    }
    const intrinsic: Size = .{ .width = node.rect.w, .height = node.rect.h };
    node.resolveTypedStyle(null, intrinsic);
    node.rect.w = node.resolved_dimensions.width orelse intrinsic.width;
    node.rect.h = node.resolved_dimensions.height orelse intrinsic.height;
    node.rect.w = node.resolved_style.clampWidth(node.rect.w);
    node.rect.h = node.resolved_style.clampHeight(node.rect.h);
}

/// The root-level main after the basis override: `basis` when set, else the
/// natural main. Under `.content_box` a fixed basis is a CONTENT size, so
/// the node's own main-axis border + padding are added on top to form its
/// border-box main (the root pseudo-container is a column: top + bottom).
fn rootBasisMain(n: *const WidgetNode, containing_main: f32) f32 {
    var main = n.style.basis;
    if (n.style.basis > 0) {
        if (n.style.box_sizing == .content_box) {
            const b = n.style;
            main += b.border.top + b.border.bottom + b.padding.top + b.padding.bottom;
        }
    } else if (resolvedFlexBasis(n, containing_main, n.rect.h)) |basis| {
        main = basis;
    } else if (n.resolved_dimensions.height) |height| {
        main = height;
    } else {
        main = n.rect.h;
    }
    return clampMain(n, .column, main);
}

/// Place root-level nodes against `available` as a column: the root
/// pseudo-container with `Style{}` defaults (justify=start, align=stretch,
/// gap=0), including grow/shrink on root-level nodes. Root nodes get the
/// available size as their border box and are positioned at (0,0) relative
/// to the surface — their rects are already relative, so no offset folding.
/// Margins are honored: a node's margin box is the unit of the main-axis
/// advance, and stretch fills the available width minus its cross margins.
fn placeRoot(tree: *WidgetTree, available: Size) void {
    // No fixed buffer: root-level nodes are iterated directly over the nodes
    // slice (append order) — first count/sum, then shrink, then place.
    var root_count: usize = 0;
    var content: f32 = 0;
    var total_grow: f32 = 0;
    var total_shrink: f32 = 0;
    for (tree.nodes.items) |*n| {
        if (n.parent != .root) continue;
        if (n.style.position == .absolute) continue;
        root_count += 1;
        // The natural (pre-basis) main is the flex-shrink floor.
        n.natural_main = n.rect.h;
        n.resolveTypedStyle(available, .{ .width = n.rect.w, .height = n.rect.h });
        const main = rootBasisMain(n, available.height);
        content += main + n.style.margin.top + n.style.margin.bottom;
        if (n.style.grow > 0) total_grow += n.style.grow;
        if (n.style.shrink > 0) total_shrink += n.style.shrink;
    }

    // The root pseudo-container has no border or padding, so its content box
    // main equals the available main: free = available.height - content.
    const free = available.height - content;
    const grew = free > 0 and total_grow > 0;
    const shrank = free < 0 and total_shrink > 0;

    // Scaled flex-shrink with content floors — the same freeze-and-
    // redistribute as finalizeMain/placeContainer. No fixed buffer here
    // (root counts are unbounded), so the frozen state lives in the mains
    // themselves: an item is frozen exactly when it sits at its floor, and
    // only non-frozen shrinkable items share the remaining overflow. This
    // yields the same final sizes as the flag version whenever no basis is
    // smaller than its content (the degenerate raise case).
    if (shrank) {
        for (tree.nodes.items) |*n| {
            if (n.style.position == .absolute) continue;
            if (n.parent != .root) continue;
            n.rect.h = rootBasisMain(n, available.height);
        }
        var remaining = -free;
        for (0..root_count) |_| {
            var total_scaled: f32 = 0;
            for (tree.nodes.items) |*n| {
                if (n.parent != .root) continue;
                if (n.style.position == .absolute) continue;
                const floor = resolvedMainFloor(n, .column, n.natural_main);
                if (n.style.shrink > 0 and n.rect.h > floor)
                    total_scaled += n.style.shrink * n.rect.h;
            }
            if (total_scaled <= 0) break;
            var changed = false;
            for (tree.nodes.items) |*n| {
                if (n.style.position == .absolute) continue;
                if (n.parent != .root) continue;
                const floor = resolvedMainFloor(n, .column, n.natural_main);
                if (n.style.shrink <= 0 or n.rect.h <= floor) continue;
                const base = n.rect.h;
                const target = base - remaining * n.style.shrink * base / total_scaled;
                const clamped = @max(floor, target);
                if (clamped != n.rect.h) {
                    n.rect.h = clamped;
                    changed = true;
                }
            }
            if (!changed) break;
            var fitted: f32 = 0;
            for (tree.nodes.items) |*n| {
                if (n.parent != .root) continue;
                if (n.style.position == .absolute) continue;
                fitted += n.rect.h + n.style.margin.top + n.style.margin.bottom;
            }
            remaining = @max(0, fitted - available.height);
            if (remaining <= 0) break;
        }
    }

    var y: f32 = 0;
    for (tree.nodes.items) |*n| {
        if (n.parent != .root) continue;
        if (n.style.position == .absolute) continue;
        const m = n.style.margin;
        // After the shrink pass rect.h already holds the basis-applied (and
        // shrunk) main; otherwise derive it from the untouched natural.
        var main = if (shrank) n.rect.h else rootBasisMain(n, available.height);
        if (grew and n.style.grow > 0) {
            main += free * n.style.grow / total_grow;
        }
        // Root align = stretch: fill the available width minus cross margins.
        n.rect.w = @max(0, available.width - m.left - m.right);
        n.rect.h = main;
        n.rect.x = m.left;
        n.rect.y = y + m.top;
        y += main + m.top + m.bottom;
    }
}

const GridTrack = style.GridTrack;
const GridTrackBreadth = style.GridTrackBreadth;
const GridPlacement = style.GridPlacement;

fn gridTrackMin(track: GridTrack, containing: ?f32) f32 {
    return switch (track) {
        .fixed => |value| @max(0, value),
        .percent => |fraction| if (containing) |size| @max(0, size * fraction) else 0,
        .auto, .min_content, .max_content, .fr => 0,
        .minmax => |value| gridBreadthMin(value.min, containing),
    };
}

fn gridBreadthMin(breadth: GridTrackBreadth, containing: ?f32) f32 {
    return switch (breadth) {
        .fixed => |value| @max(0, value),
        .percent => |fraction| if (containing) |size| @max(0, size * fraction) else 0,
        .auto, .min_content, .max_content, .fr => 0,
    };
}

fn gridTrackFr(track: GridTrack) f32 {
    return switch (track) {
        .fr => |weight| @max(0, weight),
        .minmax => |value| switch (value.max) {
            .fr => |weight| @max(0, weight),
            else => 0,
        },
        else => 0,
    };
}

fn gridTrackAllowsIntrinsic(track: GridTrack) bool {
    return switch (track) {
        .auto, .min_content, .max_content => true,
        .minmax => |value| switch (value.min) {
            .auto, .min_content, .max_content => true,
            else => false,
        },
        else => false,
    };
}

fn gridTrackMax(track: GridTrack, containing: ?f32) ?f32 {
    return switch (track) {
        .fixed => |value| @max(0, value),
        .percent => |fraction| if (containing) |size| @max(0, size * fraction) else null,
        .auto, .min_content, .max_content, .fr => null,
        .minmax => |value| switch (value.max) {
            .fixed => |size| @max(0, size),
            .percent => |fraction| if (containing) |size| @max(0, size * fraction) else null,
            .auto, .min_content, .max_content, .fr => null,
        },
    };
}

fn gridLineIndex(value: GridPlacement, explicit_count: usize) ?usize {
    return switch (value) {
        .auto, .span => null,
        .line => |line| if (line > 0)
            @as(usize, @intCast(line - 1))
        else if (line < 0 and explicit_count > 0)
            @as(usize, @intCast(@as(i32, @intCast(explicit_count)) + @as(i32, line)))
        else
            null,
    };
}

fn gridSpan(value: GridPlacement) usize {
    return switch (value) {
        .span => |span| @max(@as(usize, 1), @as(usize, span)),
        else => 1,
    };
}

fn gridPlacementFor(
    line: style.GridLine,
    explicit_count: usize,
) struct { start: usize, end: usize, explicit: bool } {
    var start = gridLineIndex(line.start, explicit_count);
    var end = gridLineIndex(line.end, explicit_count);
    if (start) |value| {
        if (end == null) end = value + gridSpan(line.end);
    } else if (end) |value| {
        start = if (value >= gridSpan(line.start)) value - gridSpan(line.start) else 0;
    }
    if (start) |start_value| {
        const end_value = end orelse start_value + 1;
        if (end_value > start_value) {
            return .{
                .start = start_value,
                .end = end_value,
                .explicit = true,
            };
        }
    }
    return .{ .start = 0, .end = 1, .explicit = false };
}

fn gridAreaFree(
    occupied: *const [32 * 32]bool,
    row: usize,
    column: usize,
    row_span: usize,
    column_span: usize,
) bool {
    if (row + row_span > 32 or column + column_span > 32) return false;
    for (row..row + row_span) |row_index| {
        for (column..column + column_span) |column_index| {
            if (occupied[row_index * 32 + column_index]) return false;
        }
    }
    return true;
}

fn gridMarkArea(
    occupied: *[32 * 32]bool,
    row: usize,
    column: usize,
    row_span: usize,
    column_span: usize,
) void {
    for (row..row + row_span) |row_index| {
        for (column..column + column_span) |column_index| {
            occupied[row_index * 32 + column_index] = true;
        }
    }
}

fn gridAlign(value: style.AlignSelf, fallback: style.Align) style.Align {
    return switch (value) {
        .auto => fallback,
        .stretch => .stretch,
        .start => .start,
        .center => .center,
        .end => .end,
    };
}

fn gridContentOffset(
    mode: style.Justify,
    free: f32,
    count: usize,
) struct { offset: f32, extra_gap: f32 } {
    if (free <= 0 or count == 0) return .{ .offset = 0, .extra_gap = 0 };
    return switch (mode) {
        .start => .{ .offset = 0, .extra_gap = 0 },
        .center => .{ .offset = free / 2, .extra_gap = 0 },
        .end => .{ .offset = free, .extra_gap = 0 },
        .space_between => .{
            .offset = 0,
            .extra_gap = if (count > 1) free / @as(f32, @floatFromInt(count - 1)) else 0,
        },
    };
}

fn gridAlignContentOffset(
    mode: style.AlignContent,
    free: f32,
    count: usize,
) struct { offset: f32, extra_gap: f32, stretch: f32 } {
    if (free <= 0 or count == 0) return .{ .offset = 0, .extra_gap = 0, .stretch = 0 };
    return switch (mode) {
        .start => .{ .offset = 0, .extra_gap = 0, .stretch = 0 },
        .center => .{ .offset = free / 2, .extra_gap = 0, .stretch = 0 },
        .end => .{ .offset = free, .extra_gap = 0, .stretch = 0 },
        .space_between => .{
            .offset = 0,
            .extra_gap = if (count > 1) free / @as(f32, @floatFromInt(count - 1)) else 0,
            .stretch = 0,
        },
        .space_around => .{
            .offset = free / @as(f32, @floatFromInt(count * 2)),
            .extra_gap = free / @as(f32, @floatFromInt(count)),
            .stretch = 0,
        },
        .stretch => .{
            .offset = 0,
            .extra_gap = 0,
            .stretch = free / @as(f32, @floatFromInt(count)),
        },
    };
}

/// Place one grid container with bounded stack storage. Explicit tracks are
/// resolved first, intrinsic contributions grow auto tracks, and `fr` tracks
/// receive the remaining definite content-box space.
fn layoutGridContainer(tree: *WidgetTree, node: *WidgetNode, available: Size) void {
    const inset_width = blockInsetWidth(node);
    const inset_height = blockInsetHeight(node);
    var flow_ids: [32]Id = undefined;
    var flow_count: usize = 0;
    for (node.children.items[0..node.children.len]) |child_id| {
        const child = tree.node(child_id) orelse continue;
        if (child.style.position == .absolute) continue;
        if (flow_count < flow_ids.len) {
            flow_ids[flow_count] = child_id;
            flow_count += 1;
        }
    }

    var columns: [32]GridTrack = [_]GridTrack{.auto} ** 32;
    var rows: [32]GridTrack = [_]GridTrack{.auto} ** 32;
    var column_count: usize = @min(node.style.grid_template_columns.len, columns.len);
    var row_count: usize = @min(node.style.grid_template_rows.len, rows.len);
    for (0..column_count) |index| columns[index] = node.style.grid_template_columns[index];
    for (0..row_count) |index| rows[index] = node.style.grid_template_rows[index];
    if (column_count == 0) column_count = 1;
    if (row_count == 0) row_count = 1;
    const explicit_column_count = column_count;
    const explicit_row_count = row_count;
    for (explicit_column_count..columns.len) |index| columns[index] = node.style.grid_auto_columns;
    for (explicit_row_count..rows.len) |index| rows[index] = node.style.grid_auto_rows;

    var column_start: [32]usize = [_]usize{0} ** 32;
    var column_end: [32]usize = [_]usize{1} ** 32;
    var row_start: [32]usize = [_]usize{0} ** 32;
    var row_end: [32]usize = [_]usize{1} ** 32;
    var occupied: [32 * 32]bool = [_]bool{false} ** (32 * 32);

    // First reserve fully explicit items. This makes auto placement stable
    // even when the source order interleaves explicit and automatic items.
    for (0..flow_count) |index| {
        const child = tree.node(flow_ids[index]) orelse continue;
        const column_line: style.GridLine = if (!std.meta.eql(child.style.grid_column, style.GridLine{}))
            child.style.grid_column
        else
            .{ .start = child.style.grid_column_start, .end = child.style.grid_column_end };
        const row_line: style.GridLine = if (!std.meta.eql(child.style.grid_row, style.GridLine{}))
            child.style.grid_row
        else
            .{ .start = child.style.grid_row_start, .end = child.style.grid_row_end };
        const column_place = gridPlacementFor(column_line, column_count);
        const row_place = gridPlacementFor(row_line, row_count);
        if (!column_place.explicit or !row_place.explicit) continue;
        if (column_place.start >= 32 or row_place.start >= 32) continue;
        column_start[index] = column_place.start;
        column_end[index] = @min(32, column_place.end);
        row_start[index] = row_place.start;
        row_end[index] = @min(32, row_place.end);
        column_count = @max(column_count, column_end[index]);
        row_count = @max(row_count, row_end[index]);
        if (column_count > 32) column_count = 32;
        if (row_count > 32) row_count = 32;
        if (gridAreaFree(
            &occupied,
            row_start[index],
            column_start[index],
            row_end[index] - row_start[index],
            column_end[index] - column_start[index],
        )) {
            gridMarkArea(
                &occupied,
                row_start[index],
                column_start[index],
                row_end[index] - row_start[index],
                column_end[index] - column_start[index],
            );
        }
    }

    const dense = node.style.grid_auto_flow == .row_dense or
        node.style.grid_auto_flow == .column_dense;
    const column_flow = node.style.grid_auto_flow == .column or
        node.style.grid_auto_flow == .column_dense;
    var cursor_row: usize = 0;
    var cursor_column: usize = 0;
    for (0..flow_count) |index| {
        if (column_end[index] > column_start[index] and row_end[index] > row_start[index]) {
            const child = tree.node(flow_ids[index]) orelse continue;
            const column_line: style.GridLine = if (!std.meta.eql(child.style.grid_column, style.GridLine{}))
                child.style.grid_column
            else
                .{ .start = child.style.grid_column_start, .end = child.style.grid_column_end };
            const row_line: style.GridLine = if (!std.meta.eql(child.style.grid_row, style.GridLine{}))
                child.style.grid_row
            else
                .{ .start = child.style.grid_row_start, .end = child.style.grid_row_end };
            if (gridPlacementFor(column_line, column_count).explicit and
                gridPlacementFor(row_line, row_count).explicit) continue;
        }
        const child = tree.node(flow_ids[index]) orelse continue;
        const column_line: style.GridLine = if (!std.meta.eql(child.style.grid_column, style.GridLine{}))
            child.style.grid_column
        else
            .{ .start = child.style.grid_column_start, .end = child.style.grid_column_end };
        const row_line: style.GridLine = if (!std.meta.eql(child.style.grid_row, style.GridLine{}))
            child.style.grid_row
        else
            .{ .start = child.style.grid_row_start, .end = child.style.grid_row_end };
        const column_place = gridPlacementFor(column_line, column_count);
        const row_place = gridPlacementFor(row_line, row_count);
        const column_span = gridSpan(column_line.start);
        const row_span = gridSpan(row_line.start);
        var placed = false;
        var attempts: usize = 0;
        var candidate_row = if (dense) 0 else cursor_row;
        var candidate_column = if (dense) 0 else cursor_column;
        while (attempts < 1024 and !placed) : (attempts += 1) {
            var candidate_column_span = column_span;
            var candidate_row_span = row_span;
            if (column_place.explicit) {
                candidate_column = column_place.start;
                candidate_column_span = @max(1, column_place.end - column_place.start);
            }
            if (row_place.explicit) {
                candidate_row = row_place.start;
                candidate_row_span = @max(1, row_place.end - row_place.start);
            }
            if (candidate_column + candidate_column_span > 32 or
                candidate_row + candidate_row_span > 32)
            {
                break;
            }
            if (candidate_column + candidate_column_span > column_count) {
                if (column_flow or row_place.explicit) {
                    column_count = @min(32, candidate_column + candidate_column_span);
                } else {
                    candidate_column = 0;
                    candidate_row += 1;
                    continue;
                }
            }
            if (candidate_row + candidate_row_span > row_count) {
                if (!column_flow or column_place.explicit) {
                    row_count = @min(32, candidate_row + candidate_row_span);
                } else {
                    candidate_row = 0;
                    candidate_column += 1;
                    continue;
                }
            }
            if (gridAreaFree(
                &occupied,
                candidate_row,
                candidate_column,
                candidate_row_span,
                candidate_column_span,
            )) {
                column_start[index] = candidate_column;
                column_end[index] = candidate_column + candidate_column_span;
                row_start[index] = candidate_row;
                row_end[index] = candidate_row + candidate_row_span;
                gridMarkArea(
                    &occupied,
                    candidate_row,
                    candidate_column,
                    candidate_row_span,
                    candidate_column_span,
                );
                placed = true;
                if (!dense) {
                    if (column_flow) {
                        cursor_column = candidate_column;
                        cursor_row = candidate_row + 1;
                    } else {
                        cursor_row = candidate_row;
                        cursor_column = candidate_column + 1;
                    }
                }
            } else if (column_flow) {
                candidate_row += 1;
                if (candidate_row >= row_count) {
                    candidate_row = 0;
                    candidate_column += 1;
                }
            } else {
                candidate_column += 1;
                if (candidate_column >= column_count) {
                    candidate_column = 0;
                    candidate_row += 1;
                }
            }
        }
    }

    const intrinsic_width = blk: {
        var result: f32 = 0;
        for (0..flow_count) |index| result = @max(result, tree.node(flow_ids[index]).?.rect.w);
        break :blk result;
    };
    const intrinsic_height = blk: {
        var result: f32 = 0;
        for (0..flow_count) |index| result = @max(result, tree.node(flow_ids[index]).?.rect.h);
        break :blk result;
    };
    node.resolveTypedStyle(null, .{ .width = intrinsic_width, .height = intrinsic_height });
    const explicit_width = blockDimension(
        node,
        node.style.size.width,
        null,
        intrinsic_width,
        true,
    );
    const explicit_height = blockDimension(
        node,
        node.style.size.height,
        null,
        intrinsic_height,
        false,
    );
    const existing_width = if (node.rect.w > inset_width) node.rect.w - inset_width else null;
    const existing_height = if (node.rect.h > inset_height) node.rect.h - inset_height else null;
    const width_containing = if (explicit_width) |value| value - inset_width else existing_width;
    const height_containing = if (explicit_height) |value| value - inset_height else existing_height;
    var column_sizes: [32]f32 = [_]f32{0} ** 32;
    var row_sizes: [32]f32 = [_]f32{0} ** 32;
    for (0..column_count) |index| column_sizes[index] = gridTrackMin(columns[index], width_containing);
    for (0..row_count) |index| row_sizes[index] = gridTrackMin(rows[index], height_containing);

    const intrinsic_column_gap = if (node.style.grid_column_gap != 0)
        node.style.grid_column_gap
    else if (node.style.column_gap != 0)
        node.style.column_gap
    else
        node.style.gap;
    const intrinsic_row_gap = if (node.style.grid_row_gap != 0)
        node.style.grid_row_gap
    else if (node.style.row_gap != 0)
        node.style.row_gap
    else
        node.style.gap;
    for (0..flow_count) |index| {
        const child = tree.node(flow_ids[index]) orelse continue;
        const margin = child.style.margin;
        const need_width = child.rect.w + margin.left + margin.right;
        const need_height = child.rect.h + margin.top + margin.bottom;
        const column_span = @max(1, column_end[index] - column_start[index]);
        const row_span = @max(1, row_end[index] - row_start[index]);
        if (column_span == 1 and gridTrackAllowsIntrinsic(columns[column_start[index]])) {
            column_sizes[column_start[index]] = @max(column_sizes[column_start[index]], need_width);
        } else if (column_span > 1) {
            var current: f32 = 0;
            for (column_start[index]..column_end[index]) |track_index| current += column_sizes[track_index];
            const extra = @max(0, need_width - current -
                @max(0, @as(f32, @floatFromInt(column_span - 1)) * @max(0, intrinsic_column_gap)));
            if (extra > 0) {
                const addition = extra / @as(f32, @floatFromInt(column_span));
                for (column_start[index]..column_end[index]) |track_index| {
                    column_sizes[track_index] += addition;
                }
            }
        }
        if (row_span == 1 and gridTrackAllowsIntrinsic(rows[row_start[index]])) {
            row_sizes[row_start[index]] = @max(row_sizes[row_start[index]], need_height);
        } else if (row_span > 1) {
            var current: f32 = 0;
            for (row_start[index]..row_end[index]) |track_index| current += row_sizes[track_index];
            const extra = @max(0, need_height - current -
                @max(0, @as(f32, @floatFromInt(row_span - 1)) * @max(0, intrinsic_row_gap)));
            if (extra > 0) {
                const addition = extra / @as(f32, @floatFromInt(row_span));
                for (row_start[index]..row_end[index]) |track_index| row_sizes[track_index] += addition;
            }
        }
    }
    for (0..column_count) |index| {
        if (gridTrackMax(columns[index], width_containing)) |maximum|
            column_sizes[index] = @min(column_sizes[index], maximum);
    }
    for (0..row_count) |index| {
        if (gridTrackMax(rows[index], height_containing)) |maximum|
            row_sizes[index] = @min(row_sizes[index], maximum);
    }

    const column_gap = @max(0, if (node.style.grid_column_gap != 0)
        node.style.grid_column_gap
    else if (node.style.column_gap != 0)
        node.style.column_gap
    else
        node.style.gap);
    const row_gap = @max(0, if (node.style.grid_row_gap != 0)
        node.style.grid_row_gap
    else if (node.style.row_gap != 0)
        node.style.row_gap
    else
        node.style.gap);
    const column_gap_total = if (column_count > 1)
        column_gap * @as(f32, @floatFromInt(column_count - 1))
    else
        0;
    const row_gap_total = if (row_count > 1)
        row_gap * @as(f32, @floatFromInt(row_count - 1))
    else
        0;
    const column_sum = blk: {
        var result: f32 = 0;
        for (0..column_count) |index| result += column_sizes[index];
        break :blk result;
    };
    const row_sum = blk: {
        var result: f32 = 0;
        for (0..row_count) |index| result += row_sizes[index];
        break :blk result;
    };
    const content_width = @max(0, width_containing orelse column_sum + column_gap_total);
    const content_height = @max(0, height_containing orelse row_sum + row_gap_total);
    const width_free = content_width - column_sum - column_gap_total;
    const height_free = content_height - row_sum - row_gap_total;
    var total_column_fr: f32 = 0;
    var total_row_fr: f32 = 0;
    for (0..column_count) |index| total_column_fr += gridTrackFr(columns[index]);
    for (0..row_count) |index| total_row_fr += gridTrackFr(rows[index]);
    if (width_free > 0 and total_column_fr > 0) {
        for (0..column_count) |index| {
            const weight = gridTrackFr(columns[index]);
            if (weight > 0) column_sizes[index] += width_free * weight / total_column_fr;
        }
    }
    if (height_free > 0 and total_row_fr > 0) {
        for (0..row_count) |index| {
            const weight = gridTrackFr(rows[index]);
            if (weight > 0) row_sizes[index] += height_free * weight / total_row_fr;
        }
    }
    const final_column_sum = blk: {
        var result: f32 = 0;
        for (0..column_count) |index| result += column_sizes[index];
        break :blk result;
    };
    const final_row_sum = blk: {
        var result: f32 = 0;
        for (0..row_count) |index| result += row_sizes[index];
        break :blk result;
    };
    const grid_justify_content = if (node.style.grid_justify_content == .start and node.style.justify != .start)
        node.style.justify
    else
        node.style.grid_justify_content;
    const grid_align_content = if (node.style.grid_align_content == .stretch and node.style.align_content != .stretch)
        node.style.align_content
    else
        node.style.grid_align_content;
    const grid_justify_items = if (node.style.grid_justify_items == .stretch and node.style.@"align" != .stretch)
        node.style.@"align"
    else
        node.style.grid_justify_items;
    const grid_align_items = if (node.style.grid_align_items == .stretch and node.style.@"align" != .stretch)
        node.style.@"align"
    else
        node.style.grid_align_items;
    const justify_offset = gridContentOffset(
        grid_justify_content,
        @max(0, content_width - final_column_sum - column_gap_total),
        column_count,
    );
    const align_offset = gridAlignContentOffset(
        grid_align_content,
        @max(0, content_height - final_row_sum - row_gap_total),
        row_count,
    );
    var column_offsets: [32]f32 = [_]f32{0} ** 32;
    var row_offsets: [32]f32 = [_]f32{0} ** 32;
    var cursor: f32 = justify_offset.offset;
    for (0..column_count) |index| {
        column_offsets[index] = cursor;
        cursor += column_sizes[index] + column_gap + justify_offset.extra_gap;
    }
    cursor = align_offset.offset;
    for (0..row_count) |index| {
        row_offsets[index] = cursor;
        cursor += row_sizes[index] + row_gap + align_offset.extra_gap + align_offset.stretch;
        if (align_offset.stretch > 0) row_sizes[index] += align_offset.stretch;
    }

    const final_width = explicit_width orelse
        if (existing_width) |value| value + inset_width else content_width + inset_width;
    const final_height = explicit_height orelse
        if (existing_height) |value| value + inset_height else content_height + inset_height;
    node.rect.w = clampBlockAxis(node, final_width, available.width, intrinsic_width, true);
    node.rect.h = clampBlockAxis(node, final_height, available.height, intrinsic_height, false);

    for (0..flow_count) |index| {
        const child = tree.node(flow_ids[index]) orelse continue;
        if (column_start[index] >= column_count or row_start[index] >= row_count) continue;
        const column_span = @min(column_count, column_end[index]) - column_start[index];
        const row_span = @min(row_count, row_end[index]) - row_start[index];
        var area_width: f32 = 0;
        var area_height: f32 = 0;
        for (column_start[index]..column_start[index] + column_span) |track_index|
            area_width += column_sizes[track_index];
        for (row_start[index]..row_start[index] + row_span) |track_index|
            area_height += row_sizes[track_index];
        if (column_span > 1) area_width += column_gap * @as(f32, @floatFromInt(column_span - 1));
        if (row_span > 1) area_height += row_gap * @as(f32, @floatFromInt(row_span - 1));
        child.resolveTypedStyleAxes(
            area_width,
            area_height,
            .{ .width = child.rect.w, .height = child.rect.h },
        );
        const margin = child.style.margin;
        const explicit_child_width = child.resolved_dimensions.width;
        const explicit_child_height = child.resolved_dimensions.height;
        var child_width = if (explicit_child_width) |value|
            child.resolved_style.clampWidth(value)
        else if (gridAlign(child.style.grid_justify_self, grid_justify_items) == .stretch)
            @max(0, area_width - margin.left - margin.right)
        else
            child.rect.w;
        var child_height = if (explicit_child_height) |value|
            child.resolved_style.clampHeight(value)
        else if (gridAlign(child.style.grid_align_self, grid_align_items) == .stretch)
            @max(0, area_height - margin.top - margin.bottom)
        else
            child.rect.h;
        child_width = child.resolved_style.clampWidth(child_width);
        child_height = child.resolved_style.clampHeight(child_height);
        const justify_self = gridAlign(child.style.grid_justify_self, grid_justify_items);
        const align_self = gridAlign(child.style.grid_align_self, grid_align_items);
        const free_width = @max(0, area_width - child_width - margin.left - margin.right);
        const free_height = @max(0, area_height - child_height - margin.top - margin.bottom);
        const child_x = column_offsets[column_start[index]] + margin.left + switch (justify_self) {
            .stretch, .start => 0,
            .center => free_width / 2,
            .end => free_width,
        };
        const child_y = row_offsets[row_start[index]] + margin.top + switch (align_self) {
            .stretch, .start => 0,
            .center => free_height / 2,
            .end => free_height,
        };
        child.rect = .{
            .x = child_x,
            .y = child_y,
            .w = child_width,
            .h = child_height,
        };
    }
}

const testing = std.testing;

/// Append a node to the tree. Post-order invariant: children are appended
/// before their container, so parents are wired up by `wireChildren` after
/// the whole tree is built.
fn appendNode(tree: *WidgetTree, id: Id, parent: Id, kind: WidgetKind) !void {
    var node: WidgetNode = .{
        .id = id,
        .kind = kind,
        .parent = parent,
    };
    switch (kind) {
        .column => |container| {
            node.style.direction = .column;
            node.style.gap = container.gap;
        },
        .row => |container| {
            node.style.direction = .row;
            node.style.gap = container.gap;
        },
        .button => {
            node.style.direction = .row;
        },
        else => {},
    }
    try tree.nodes.append(tree.allocator, node);
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
    tree.node(id1).?.style.grow = 1;

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
    tree.node(id1).?.style.shrink = 1;
    tree.node(id2).?.style.shrink = 1;
    tree.node(id3).?.style.shrink = 2;

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
    tree.node(id3).?.style.padding = .{ .left = 8, .top = 8 };

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
    tree.node(id1).?.style.margin = .{ .right = 6 };
    tree.node(id2).?.style.margin = .{ .left = 4 };

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
    tree.node(id1).?.style.margin = .{ .left = 5, .right = 5 };

    layout(&tree, .{ .width = 100, .height = 600 });

    // Content box cross = 100 (no border/padding); stretched border w =
    // 100 - 5 - 5 = 90, offset by the left margin.
    try testing.expectEqual(Rect{ .x = 5, .y = 0, .w = 90, .h = 20 }, tree.node(id1).?.rect);
    // Container natural h = child main (20) + the MAIN-axis margins
    // (top+bottom = 0 in a column) = 20 — the left/right margins are
    // cross-axis and never count toward the main-axis size.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 20 }, tree.node(id2).?.rect);
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
    tree.node(id3).?.style.border = .{ .top = 1, .right = 2, .bottom = 1, .left = 2 };
    tree.node(id3).?.style.padding = .{ .left = 4, .top = 3 };

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
    tree.node(label).?.style.grow = 1;
    // 12px top padding: the content box is 12px shorter than the border box.
    tree.node(col).?.style.padding = .{ .top = 12 };

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
    tree.node(id1).?.style.shrink = 1;
    tree.node(id2).?.style.shrink = 1;
    tree.node(id3).?.style.shrink = 8;

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
    tree.node(id1).?.style.margin = .{ .top = 20, .left = 10, .right = 10 };

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
    tree.node(inner).?.style.grow = 1;

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
    tree.node(label).?.style.grow = 1;
    // The outer column stretches the inner column to the available height and grows the inner
    // column along with it.
    tree.node(inner).?.style.grow = 1;

    layout(&tree, .{ .width = 800, .height = 600 });

    // Bottom-up, the label never grew below the root (it stayed 20px tall).
    // Top-down, the inner column's FINAL main is 600 (grown by the outer
    // column), so the label grows to fill the inner content box.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 800, .h = 600 }, tree.node(outer).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 800, .h = 600 }, tree.node(inner).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 800, .h = 600 }, tree.node(label).?.rect);
}

test "column main margins: top/bottom counted, left/right ignored" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const a: Id = @enumFromInt(1);
    const b: Id = @enumFromInt(2);
    const col: Id = @enumFromInt(3);
    try appendNode(&tree, a, col, .{ .label = .{ .text = "aaa" } });
    try appendNode(&tree, b, col, .{ .label = .{ .text = "bbb" } });
    try appendNode(&tree, col, .root, .{ .column = .{} });
    wireChildren(&tree);
    tree.node(a).?.style.margin = .{ .top = 10 };
    // Left/right margins are CROSS-axis for a column — they must neither
    // inflate the main-axis sum nor advance the next child.
    tree.node(b).?.style.margin = .{ .left = 99, .right = 99 };

    layout(&tree, .{ .width = 100, .height = 600 });

    // Main axis: A margin box = 20 + top 10 + bottom 0 = 30, B = 20; the
    // container hugs 50 (the 99px left/right margins are ignored).
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 50 }, tree.node(col).?.rect);
    // A.y = margin.top (10).
    try testing.expectEqual(Rect{ .x = 0, .y = 10, .w = 100, .h = 20 }, tree.node(a).?.rect);
    // B.y = A's margin box (main 20 + top 10 + bottom 0 = 30) — no
    // left/right margin in the advance.
    try testing.expectEqual(@as(f32, 30), tree.node(b).?.rect.y);
    try testing.expectEqual(@as(f32, 20), tree.node(b).?.rect.h);
}

test "shrink uses scaled factor + content floor" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const a: Id = @enumFromInt(1);
    const b: Id = @enumFromInt(2);
    const row: Id = @enumFromInt(3);
    try appendNode(&tree, a, row, .{ .label = .{ .text = "aa" } });
    try appendNode(&tree, b, row, .{ .label = .{ .text = "bb" } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    wireChildren(&tree);
    tree.node(a).?.style.basis = 80;
    tree.node(a).?.style.shrink = 1;
    tree.node(b).?.style.basis = 40;
    tree.node(b).?.style.shrink = 1;

    layout(&tree, .{ .width = 100, .height = 40 });

    // Content 120 vs 100, overflow 20: total_scaled = 1*80 + 1*40 = 120;
    // reduction_i = overflow * shrink_i * base_i / total_scaled:
    //   A: 80 - 20*80/120 = 66.67,  B: 40 - 20*40/120 = 33.33.
    // Both stay above their 20px content floors, so nothing freezes.
    try testing.expectApproxEqAbs(@as(f32, 66.67), tree.node(a).?.rect.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 33.33), tree.node(b).?.rect.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 66.67), tree.node(b).?.rect.x, 0.01);
    // The row takes the available main (shrink fired) and fits exactly.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 40 }, tree.node(row).?.rect);
}

test "shrink freezes at the floor and redistributes" {
    // Scenario 1: no item clamps — plain scaled reductions over 3 items.
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const a: Id = @enumFromInt(1);
    const b: Id = @enumFromInt(2);
    const c: Id = @enumFromInt(3);
    const row1: Id = @enumFromInt(4);
    try appendNode(&tree, a, row1, .{ .label = .{ .text = "aa" } });
    try appendNode(&tree, b, row1, .{ .label = .{ .text = "bb" } });
    try appendNode(&tree, c, row1, .{ .label = .{ .text = "cc" } });
    try appendNode(&tree, row1, .root, .{ .row = .{} });
    wireChildren(&tree);
    tree.node(a).?.style.basis = 60;
    tree.node(a).?.style.shrink = 1;
    tree.node(b).?.style.basis = 60;
    tree.node(b).?.style.shrink = 1;
    tree.node(c).?.style.basis = 60;
    tree.node(c).?.style.shrink = 1;

    layout(&tree, .{ .width = 100, .height = 40 });

    // Content 180, overflow 80, total_scaled = 180: reduction_i =
    // 80*60/180 = 26.67 — all land at 33.33, above the 20px floor, so
    // nothing freezes and the row fits exactly.
    try testing.expectApproxEqAbs(@as(f32, 33.33), tree.node(a).?.rect.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 33.33), tree.node(b).?.rect.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 33.33), tree.node(c).?.rect.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 33.33), tree.node(b).?.rect.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 66.67), tree.node(c).?.rect.x, 0.01);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 40 }, tree.node(row1).?.rect);

    // Scenario 2: B and C clamp at their 20px floors; the remaining
    // overflow redistributes to A alone.
    var tree2 = WidgetTree.init(testing.allocator);
    defer tree2.nodes.deinit(testing.allocator);

    const a2: Id = @enumFromInt(1);
    const b2: Id = @enumFromInt(2);
    const c2: Id = @enumFromInt(3);
    const row2: Id = @enumFromInt(4);
    try appendNode(&tree2, a2, row2, .{ .label = .{ .text = "aa" } });
    try appendNode(&tree2, b2, row2, .{ .label = .{ .text = "bb" } });
    try appendNode(&tree2, c2, row2, .{ .label = .{ .text = "cc" } });
    try appendNode(&tree2, row2, .root, .{ .row = .{} });
    wireChildren(&tree2);
    tree2.node(a2).?.style.basis = 80;
    tree2.node(a2).?.style.shrink = 1;
    tree2.node(b2).?.style.basis = 20;
    tree2.node(b2).?.style.shrink = 1;
    tree2.node(c2).?.style.basis = 20;
    tree2.node(c2).?.style.shrink = 1;

    layout(&tree2, .{ .width = 100, .height = 40 });

    // Pass 1: total_scaled = 1*80 + 1*20 + 1*20 = 120, overflow 20; A drops
    // to 66.67, B/C to 16.67 — both clamp at their 20px floor and freeze.
    // Pass 2: total_scaled = 66.67 (A only), remaining overflow 6.67 →
    // A = 60. Final: A=60, B=20, C=20, row fits 100 exactly.
    try testing.expectApproxEqAbs(@as(f32, 60), tree2.node(a2).?.rect.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20), tree2.node(b2).?.rect.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20), tree2.node(c2).?.rect.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 60), tree2.node(b2).?.rect.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 80), tree2.node(c2).?.rect.x, 0.01);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 40 }, tree2.node(row2).?.rect);
}

test "stretch-after-grow: stretch child fills the grown container" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const slider: Id = @enumFromInt(1);
    const card: Id = @enumFromInt(2);
    const row: Id = @enumFromInt(3);
    var value: f32 = 0.5;
    try appendNode(&tree, slider, card, .{ .slider = .{ .label = "s", .value = &value, .min = 0, .max = 1 } });
    try appendNode(&tree, card, row, .{ .column = .{} });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    wireChildren(&tree);
    tree.node(card).?.style.padding = .{ .left = 12, .right = 12 };
    tree.node(card).?.style.grow = 1;

    layout(&tree, .{ .width = 600, .height = 40 });

    // Bottom-up, the card hugged its slider at 100 + 12 + 12 = 124 wide;
    // the root row then grew it to the full 600. finalizeMain runs BEFORE
    // finalizeCross, so the stretch pass sees the card's FINAL (grown)
    // width and the slider fills its content box: 600 - 12 - 12 = 576.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 600, .h = 40 }, tree.node(card).?.rect);
    try testing.expectApproxEqAbs(@as(f32, 576), tree.node(slider).?.rect.w, 0.01);
}

test "nested stretch container keeps its own inset" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const label: Id = @enumFromInt(1);
    const col: Id = @enumFromInt(2);
    const row: Id = @enumFromInt(3);
    try appendNode(&tree, label, col, .{ .label = .{ .text = "aaa" } });
    try appendNode(&tree, col, row, .{ .column = .{} });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    wireChildren(&tree);
    tree.node(col).?.style.padding = .{ .left = 10, .right = 10 };

    layout(&tree, .{ .width = 200, .height = 40 });

    // The nested column hugs its content bottom-up: largest child cross (30)
    // + its own border+padding (10+10) = 50 — a nested stretch must NOT size
    // it to the pre-final hug (30), the top-down finalizeCross pass
    // re-stretches it against the row's FINAL content box instead.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 50, .h = 40 }, tree.node(col).?.rect);
    // The label fills the column's content box: 50 - 20 inset = 30.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 30, .h = 20 }, tree.node(label).?.rect);
}

test "text_max_width caps clipped text but not visible text" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const clipped_label: Id = @enumFromInt(1);
    const visible_label: Id = @enumFromInt(2);
    const row: Id = @enumFromInt(3);
    try appendNode(&tree, clipped_label, row, .{ .label = .{ .text = "abcdef" } });
    try appendNode(&tree, visible_label, row, .{ .label = .{ .text = "abcdef" } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    wireChildren(&tree);
    tree.node(clipped_label).?.text_overflow = .clip;
    tree.node(clipped_label).?.text_max_width = 25;
    tree.node(clipped_label).?.style.padding = .{ .left = 2, .right = 3 };
    tree.node(visible_label).?.text_max_width = 25;

    layout(&tree, .{ .width = 200, .height = 40 });

    // The 60px fallback measurement is capped to 25px before box insets.
    try testing.expectEqual(@as(f32, 30), tree.node(clipped_label).?.rect.w);
    try testing.expectEqual(@as(f32, 30), tree.node(clipped_label).?.natural_main);
    // A visible label ignores text_max_width and retains its natural width.
    try testing.expectEqual(@as(f32, 60), tree.node(visible_label).?.rect.w);
    try testing.expectEqual(@as(f32, 60), tree.node(visible_label).?.natural_main);
}

test "min_main overrides the natural shrink floor in a row" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const a: Id = @enumFromInt(1);
    const b: Id = @enumFromInt(2);
    const row: Id = @enumFromInt(3);
    try appendNode(&tree, a, row, .{ .label = .{ .text = "aa" } });
    try appendNode(&tree, b, row, .{ .label = .{ .text = "bb" } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    wireChildren(&tree);
    tree.node(a).?.style.basis = 80;
    tree.node(a).?.style.shrink = 1;
    tree.node(a).?.style.min_main = 70;
    tree.node(b).?.style.basis = 40;
    tree.node(b).?.style.shrink = 1;

    layout(&tree, .{ .width = 100, .height = 40 });

    // A freezes at its explicit 70px floor; B absorbs the remaining overflow.
    try testing.expectApproxEqAbs(@as(f32, 70), tree.node(a).?.rect.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 30), tree.node(b).?.rect.w, 0.01);
}

test "min_main overrides the natural shrink floor at the root" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const a: Id = @enumFromInt(1);
    const b: Id = @enumFromInt(2);
    try appendNode(&tree, a, .root, .{ .label = .{ .text = "aa" } });
    try appendNode(&tree, b, .root, .{ .label = .{ .text = "bb" } });
    tree.node(a).?.style.basis = 80;
    tree.node(a).?.style.shrink = 1;
    tree.node(a).?.style.min_main = 70;
    tree.node(b).?.style.basis = 40;
    tree.node(b).?.style.shrink = 1;

    layout(&tree, .{ .width = 100, .height = 100 });

    try testing.expectApproxEqAbs(@as(f32, 70), tree.node(a).?.rect.h, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 30), tree.node(b).?.rect.h, 0.01);
}

test "shared column row redistributes after ancestor cross stretch" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const a: Id = @enumFromInt(1);
    const b: Id = @enumFromInt(2);
    const row: Id = @enumFromInt(3);
    const inner: Id = @enumFromInt(4);
    const outer: Id = @enumFromInt(5);
    try appendNode(&tree, a, row, .{ .label = .{ .text = "aa" } });
    try appendNode(&tree, b, row, .{ .label = .{ .text = "bb" } });
    try appendNode(&tree, row, inner, .{ .row = .{} });
    try appendNode(&tree, inner, outer, .{ .column = .{} });
    try appendNode(&tree, outer, .root, .{ .column = .{} });
    wireChildren(&tree);

    const tracks = [_]widget.ColumnTrack{
        .{ .grow = 1, .basis = 40 },
        .{ .grow = 1, .basis = 60 },
    };
    const shared_columns: widget.SharedColumns = .{ .tracks = &tracks };
    tree.node(row).?.shared_columns = &shared_columns;
    tree.node(a).?.style.grow = tracks[0].grow;
    tree.node(a).?.style.basis = tracks[0].basis;
    tree.node(b).?.style.grow = tracks[1].grow;
    tree.node(b).?.style.basis = tracks[1].basis;

    layout(&tree, .{ .width = 200, .height = 40 });

    // The row starts as a 100px hug, then its ancestors stretch it to 200px.
    // Its two equal grow factors must share the new 100px of free space.
    try testing.expectEqual(@as(f32, 200), tree.node(row).?.rect.w);
    try testing.expectApproxEqAbs(@as(f32, 90), tree.node(a).?.rect.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 110), tree.node(b).?.rect.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 90), tree.node(b).?.rect.x, 0.01);
}

test "nested column button label stays within final content width" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const button_label: Id = @enumFromInt(1);
    const button: Id = @enumFromInt(2);
    const column: Id = @enumFromInt(3);
    const row: Id = @enumFromInt(4);
    const outer: Id = @enumFromInt(5);
    try appendNode(&tree, button_label, button, .{ .label = .{ .text = "button" } });
    try appendNode(&tree, button, column, .{ .button = .{ .label = "button" } });
    try appendNode(&tree, column, row, .{ .column = .{} });
    try appendNode(&tree, row, outer, .{ .row = .{} });
    try appendNode(&tree, outer, .root, .{ .column = .{} });
    wireChildren(&tree);

    // Model a generated button label with ellipsis and a natural width wider
    // than the nested column's final cross size.
    tree.node(button_label).?.text_overflow = .ellipsis;
    tree.node(button_label).?.text_max_width = 184;
    tree.node(button_label).?.style.min_main = 0;
    tree.node(button).?.style.justify = .start;
    tree.node(button).?.style.@"align" = .center;
    tree.node(column).?.style.min_main = 0;
    tree.node(row).?.style.@"align" = .center;

    const wideText = struct {
        fn measure(_: []const u8, _: f32, _: u8) Size {
            return .{ .width = 300, .height = 20 };
        }
    }.measure;
    layoutWith(&tree, .{ .width = 84, .height = 80 }, wideText);

    // The final cross pass narrows the button after the preceding main pass.
    // The terminal main pass must then apply that width to the generated
    // ellipsized label instead of leaving its stale natural width.
    const column_content_width = widget.contentRect(&tree, column).w;
    const button_content_width = widget.contentRect(&tree, button).w;
    try testing.expectEqual(@as(f32, 84), column_content_width);
    try testing.expect(tree.node(button_label).?.rect.w <= button_content_width);
}

test "scroll max_offset uses child margin-box extent" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const child: Id = @enumFromInt(1);
    const scroll: Id = @enumFromInt(2);
    try appendNode(&tree, child, scroll, .{ .spacer = .{ .size = 200 } });
    try appendNode(&tree, scroll, .root, .{ .column = .{} });
    wireChildren(&tree);

    var state: widget.ScrollState = .{};
    tree.node(scroll).?.scroll = .{ .state = &state, .axis = .both };
    tree.node(scroll).?.style.@"align" = .start;
    tree.node(scroll).?.style.border = .{ .left = 2, .right = 3, .top = 2, .bottom = 3 };
    tree.node(scroll).?.style.padding = .{ .left = 3, .right = 2, .top = 3, .bottom = 2 };
    tree.node(child).?.style.margin = .{ .left = 3, .right = 7, .top = 4, .bottom = 9 };

    layout(&tree, .{ .width = 100, .height = 80 });

    // Content box = 90x70. The child margin-box ends at (210, 213).
    try testing.expectEqual([2]f32{ 120, 143 }, state.max_offset);
}

test "typed minimum precedes the legacy flex shrink floor" {
    const node: WidgetNode = .{
        .id = .root,
        .kind = .{ .label = .{ .text = "typed" } },
        .parent = .root,
        .style = .{ .min_main = 12 },
        .resolved_constraints = .{ .min_width = 28 },
    };

    try testing.expectEqual(@as(f32, 28), resolvedMainFloor(&node, .row, 40));
    try testing.expectEqual(@as(f32, 12), resolvedMainFloor(&node, .column, 40));
}

test "block flow stacks in-flow children and excludes absolute children" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const first: Id = @enumFromInt(1);
    const second: Id = @enumFromInt(2);
    const absolute: Id = @enumFromInt(3);
    const block: Id = @enumFromInt(4);
    try appendNode(&tree, first, block, .{ .label = .{ .text = "a" } });
    try appendNode(&tree, second, block, .{ .label = .{ .text = "b" } });
    try appendNode(&tree, absolute, block, .{ .spacer = .{ .size = 50 } });
    try appendNode(&tree, block, .root, .{ .column = .{} });
    wireChildren(&tree);

    tree.node(block).?.style.display = .block;
    tree.node(block).?.style.size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
    };
    tree.node(absolute).?.style.position = .absolute;
    tree.node(absolute).?.style.inset = .{
        .top = .{ .length = 5 },
        .right = .auto,
        .bottom = .auto,
        .left = .{ .length = 10 },
    };

    layout(&tree, .{ .width = 100, .height = 100 });

    try testing.expectEqual(@as(f32, 0), tree.node(first).?.rect.y);
    try testing.expectEqual(@as(f32, 20), tree.node(second).?.rect.y);
    try testing.expectEqual(@as(f32, 100), tree.node(block).?.rect.h);
    try testing.expectEqual(@as(f32, 10), tree.node(absolute).?.rect.x);
    try testing.expectEqual(@as(f32, 5), tree.node(absolute).?.rect.y);
}

test "absolute insets resolve start end both and static placement" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const left: Id = @enumFromInt(1);
    const right: Id = @enumFromInt(2);
    const both: Id = @enumFromInt(3);
    const static: Id = @enumFromInt(4);
    const block: Id = @enumFromInt(5);
    try appendNode(&tree, left, block, .{ .spacer = .{ .size = 20 } });
    try appendNode(&tree, right, block, .{ .spacer = .{ .size = 20 } });
    try appendNode(&tree, both, block, .{ .spacer = .{ .size = 1 } });
    try appendNode(&tree, static, block, .{ .spacer = .{ .size = 15 } });
    try appendNode(&tree, block, .root, .{ .column = .{} });
    wireChildren(&tree);

    tree.node(block).?.style.display = .block;
    tree.node(block).?.style.size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 80 },
    };
    for ([_]Id{ left, right, both, static }) |id| {
        tree.node(id).?.style.position = .absolute;
    }
    tree.node(left).?.style.size = .{
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
    };
    tree.node(left).?.style.inset = .{
        .top = .{ .length = 5 },
        .right = .auto,
        .bottom = .auto,
        .left = .{ .length = 10 },
    };
    tree.node(right).?.style.size = .{
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
    };
    tree.node(right).?.style.inset = .{
        .top = .auto,
        .right = .{ .length = 10 },
        .bottom = .{ .length = 5 },
        .left = .auto,
    };
    tree.node(both).?.style.size.height = .{ .length = 10 };
    tree.node(both).?.style.inset = .{
        .top = .auto,
        .right = .{ .length = 10 },
        .bottom = .auto,
        .left = .{ .length = 10 },
    };

    layout(&tree, .{ .width = 100, .height = 80 });

    try testing.expectEqual(Rect{ .x = 10, .y = 5, .w = 20, .h = 10 }, tree.node(left).?.rect);
    try testing.expectEqual(Rect{ .x = 70, .y = 65, .w = 20, .h = 10 }, tree.node(right).?.rect);
    try testing.expectEqual(@as(f32, 10), tree.node(both).?.rect.x);
    try testing.expectEqual(@as(f32, 80), tree.node(both).?.rect.w);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 15, .h = 15 }, tree.node(static).?.rect);
}

test "absolute percentages require definite containing axes" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const definite: Id = @enumFromInt(1);
    const indefinite: Id = @enumFromInt(2);
    const block: Id = @enumFromInt(3);
    try appendNode(&tree, definite, block, .{ .spacer = .{ .size = 8 } });
    try appendNode(&tree, indefinite, block, .{ .spacer = .{ .size = 8 } });
    try appendNode(&tree, block, .root, .{ .column = .{} });
    wireChildren(&tree);

    tree.node(block).?.style.display = .block;
    tree.node(block).?.style.size.width = .{ .length = 200 };
    tree.node(definite).?.style.position = .absolute;
    tree.node(definite).?.style.size.width = .{ .percent = 0.5 };
    tree.node(definite).?.style.inset.left = .{ .percent = 0.25 };
    tree.node(indefinite).?.style.position = .absolute;
    tree.node(indefinite).?.style.size.height = .{ .percent = 0.5 };
    tree.node(indefinite).?.style.inset.top = .{ .percent = 0.25 };

    layout(&tree, .{ .width = 200, .height = 100 });

    try testing.expectEqual(@as(f32, 100), tree.node(definite).?.rect.w);
    try testing.expectEqual(@as(f32, 50), tree.node(definite).?.rect.x);
    // The block's auto height is indefinite: the percentage height and inset
    // fall back to the spacer's intrinsic size and static origin.
    try testing.expectEqual(@as(f32, 8), tree.node(indefinite).?.rect.h);
    try testing.expectEqual(@as(f32, 0), tree.node(indefinite).?.rect.y);
}

test "absolute content-box and border-box constraints use border-box rects" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const content: Id = @enumFromInt(1);
    const border: Id = @enumFromInt(2);
    const constrained: Id = @enumFromInt(3);
    const block: Id = @enumFromInt(4);
    try appendNode(&tree, content, block, .{ .spacer = .{ .size = 1 } });
    try appendNode(&tree, border, block, .{ .spacer = .{ .size = 1 } });
    try appendNode(&tree, constrained, block, .{ .spacer = .{ .size = 1 } });
    try appendNode(&tree, block, .root, .{ .column = .{} });
    wireChildren(&tree);

    tree.node(block).?.style.display = .block;
    tree.node(block).?.style.size = .{
        .width = .{ .length = 120 },
        .height = .{ .length = 80 },
    };
    for ([_]Id{ content, border, constrained }) |id| {
        tree.node(id).?.style.position = .absolute;
        tree.node(id).?.style.border = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 };
        tree.node(id).?.style.padding = .{ .left = 3, .right = 3, .top = 3, .bottom = 3 };
    }
    tree.node(content).?.style.size = .{
        .width = .{ .length = 30 },
        .height = .{ .length = 20 },
    };
    tree.node(border).?.style.box_sizing = .border_box;
    tree.node(border).?.style.size = .{
        .width = .{ .length = 30 },
        .height = .{ .length = 20 },
    };
    tree.node(constrained).?.style.size.width = .{ .length = 10 };
    tree.node(constrained).?.style.min_size.width = .{ .length = 20 };

    layout(&tree, .{ .width = 120, .height = 80 });

    try testing.expectEqual(@as(f32, 40), tree.node(content).?.rect.w);
    try testing.expectEqual(@as(f32, 30), tree.node(border).?.rect.w);
    try testing.expectEqual(@as(f32, 30), tree.node(constrained).?.rect.w);
}

test "wrapped row forms lines and applies cross gap" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const first: Id = @enumFromInt(1);
    const second: Id = @enumFromInt(2);
    const third: Id = @enumFromInt(3);
    const row: Id = @enumFromInt(4);
    try appendNode(&tree, first, row, .{ .spacer = .{ .size = 30 } });
    try appendNode(&tree, second, row, .{ .spacer = .{ .size = 30 } });
    try appendNode(&tree, third, row, .{ .spacer = .{ .size = 30 } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    wireChildren(&tree);
    tree.node(row).?.style.wrap = .wrap;
    tree.node(row).?.style.gap = 10;
    tree.node(row).?.style.size = .{
        .width = .{ .length = 70 },
        .height = .{ .length = 70 },
    };
    layout(&tree, .{ .width = 70, .height = 70 });

    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 30, .h = 30 }, tree.node(first).?.rect);
    try testing.expectEqual(Rect{ .x = 40, .y = 0, .w = 30, .h = 30 }, tree.node(second).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 40, .w = 30, .h = 30 }, tree.node(third).?.rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 70, .h = 70 }, tree.node(row).?.rect);
}

test "row reverse places source order from the main-end edge" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const first: Id = @enumFromInt(1);
    const second: Id = @enumFromInt(2);
    const row: Id = @enumFromInt(3);
    try appendNode(&tree, first, row, .{ .spacer = .{ .size = 20 } });
    try appendNode(&tree, second, row, .{ .spacer = .{ .size = 20 } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    wireChildren(&tree);
    tree.node(row).?.style.direction = .row_reverse;
    tree.node(row).?.style.size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 30 },
    };

    layout(&tree, .{ .width = 100, .height = 30 });

    try testing.expectEqual(@as(f32, 80), tree.node(first).?.rect.x);
    try testing.expectEqual(@as(f32, 60), tree.node(second).?.rect.x);
}

test "wrap reverse reverses the cross-axis line stack" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const first: Id = @enumFromInt(1);
    const second: Id = @enumFromInt(2);
    const third: Id = @enumFromInt(3);
    const row: Id = @enumFromInt(4);
    try appendNode(&tree, first, row, .{ .spacer = .{ .size = 30 } });
    try appendNode(&tree, second, row, .{ .spacer = .{ .size = 30 } });
    try appendNode(&tree, third, row, .{ .spacer = .{ .size = 30 } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    wireChildren(&tree);
    tree.node(row).?.style.wrap = .wrap_reverse;
    tree.node(row).?.style.gap = 10;
    tree.node(row).?.style.size = .{
        .width = .{ .length = 70 },
        .height = .{ .length = 70 },
    };

    layout(&tree, .{ .width = 70, .height = 70 });

    try testing.expectEqual(@as(f32, 40), tree.node(first).?.rect.y);
    try testing.expectEqual(@as(f32, 40), tree.node(second).?.rect.y);
    try testing.expectEqual(@as(f32, 0), tree.node(third).?.rect.y);
}

test "align-content center offsets the single flex line" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const child: Id = @enumFromInt(1);
    const row: Id = @enumFromInt(2);
    try appendNode(&tree, child, row, .{ .spacer = .{ .size = 20 } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    wireChildren(&tree);
    tree.node(row).?.style.wrap = .wrap;
    tree.node(row).?.style.align_content = .center;
    tree.node(row).?.style.size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
    };

    layout(&tree, .{ .width = 100, .height = 100 });

    try testing.expectEqual(@as(f32, 40), tree.node(child).?.rect.y);
    try testing.expectEqual(@as(f32, 20), tree.node(child).?.rect.h);
}

test "align-self overrides align-items per flex item" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const end_child: Id = @enumFromInt(1);
    const center_child: Id = @enumFromInt(2);
    const row: Id = @enumFromInt(3);
    try appendNode(&tree, end_child, row, .{ .spacer = .{ .size = 20 } });
    try appendNode(&tree, center_child, row, .{ .spacer = .{ .size = 20 } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    wireChildren(&tree);
    tree.node(row).?.style.size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
    };
    tree.node(end_child).?.style.align_self = .end;
    tree.node(center_child).?.style.align_self = .center;

    layout(&tree, .{ .width = 100, .height = 100 });

    try testing.expectEqual(@as(f32, 80), tree.node(end_child).?.rect.y);
    try testing.expectEqual(@as(f32, 40), tree.node(center_child).?.rect.y);
}

test "main-axis auto margin absorbs positive free space" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const child: Id = @enumFromInt(1);
    const row: Id = @enumFromInt(2);
    try appendNode(&tree, child, row, .{ .spacer = .{ .size = 20 } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    wireChildren(&tree);
    tree.node(row).?.style.size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 40 },
    };
    tree.node(child).?.style.margin_inset = .{
        .top = .{ .length = 0 },
        .right = .{ .length = 0 },
        .bottom = .{ .length = 0 },
        .left = .auto,
    };

    layout(&tree, .{ .width = 100, .height = 40 });

    try testing.expectEqual(@as(f32, 80), tree.node(child).?.rect.x);
}

test "cross-axis auto margin absorbs positive line space" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const child: Id = @enumFromInt(1);
    const row: Id = @enumFromInt(2);
    try appendNode(&tree, child, row, .{ .spacer = .{ .size = 20 } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    wireChildren(&tree);
    tree.node(row).?.style.size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
    };
    tree.node(child).?.style.margin_inset = .{
        .top = .auto,
        .right = .{ .length = 0 },
        .bottom = .{ .length = 0 },
        .left = .{ .length = 0 },
    };

    layout(&tree, .{ .width = 100, .height = 100 });

    try testing.expectEqual(@as(f32, 80), tree.node(child).?.rect.y);
    try testing.expectEqual(@as(f32, 20), tree.node(child).?.rect.h);
}

test "wrapped lines distribute grow independently" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const first: Id = @enumFromInt(1);
    const second: Id = @enumFromInt(2);
    const third: Id = @enumFromInt(3);
    const row: Id = @enumFromInt(4);
    try appendNode(&tree, first, row, .{ .spacer = .{ .size = 40 } });
    try appendNode(&tree, second, row, .{ .spacer = .{ .size = 40 } });
    try appendNode(&tree, third, row, .{ .spacer = .{ .size = 40 } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    wireChildren(&tree);
    tree.node(row).?.style.wrap = .wrap;
    tree.node(row).?.style.gap = 10;
    tree.node(row).?.style.size = .{
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
    };
    for ([_]Id{ first, second, third }) |id| tree.node(id).?.style.grow = 1;

    layout(&tree, .{ .width = 100, .height = 100 });

    try testing.expectEqual(@as(f32, 45), tree.node(first).?.rect.w);
    try testing.expectEqual(@as(f32, 55), tree.node(second).?.rect.x);
    try testing.expectEqual(@as(f32, 100), tree.node(third).?.rect.w);
    try testing.expectEqual(@as(f32, 55), tree.node(third).?.rect.y);
}

test "wrapped flex excludes absolute children from line formation" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const first: Id = @enumFromInt(1);
    const absolute: Id = @enumFromInt(2);
    const second: Id = @enumFromInt(3);
    const row: Id = @enumFromInt(4);
    try appendNode(&tree, first, row, .{ .spacer = .{ .size = 30 } });

    try appendNode(&tree, absolute, row, .{ .spacer = .{ .size = 90 } });
    try appendNode(&tree, second, row, .{ .spacer = .{ .size = 30 } });
    try appendNode(&tree, row, .root, .{ .row = .{} });
    wireChildren(&tree);
    tree.node(row).?.style.wrap = .wrap;
    tree.node(row).?.style.gap = 10;
    tree.node(row).?.style.size = .{
        .width = .{ .length = 70 },
        .height = .{ .length = 40 },
    };
    tree.node(absolute).?.style.position = .absolute;
    tree.node(absolute).?.style.size = .{
        .width = .{ .length = 90 },
        .height = .{ .length = 10 },
    };

    layout(&tree, .{ .width = 70, .height = 40 });

    try testing.expectEqual(@as(f32, 0), tree.node(first).?.rect.x);
    try testing.expectEqual(@as(f32, 40), tree.node(second).?.rect.x);
    try testing.expectEqual(@as(f32, 0), tree.node(second).?.rect.y);
    try testing.expectEqual(@as(f32, 90), tree.node(absolute).?.rect.w);
}
test "grid fixed and percentage tracks resolve against definite content" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);
    const first: Id = @enumFromInt(1);
    const second: Id = @enumFromInt(2);
    const grid: Id = @enumFromInt(3);
    try appendNode(&tree, first, grid, .{ .spacer = .{ .size = 8 } });
    try appendNode(&tree, second, grid, .{ .spacer = .{ .size = 8 } });
    try appendNode(&tree, grid, .root, .{ .column = .{} });
    wireChildren(&tree);
    const columns = [_]style.GridTrack{ .{ .fixed = 40 }, .{ .percent = 0.5 } };
    const rows = [_]style.GridTrack{.{ .fixed = 20 }};
    tree.node(grid).?.style = .{
        .display = .grid,
        .size = .{
            .width = .{ .length = 200 },
            .height = .{ .length = 80 },
        },
        .grid_template_columns = columns[0..],
        .grid_template_rows = rows[0..],
        .grid_column = .{},
        .grid_row = .{},
    };
    tree.node(first).?.style.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    tree.node(second).?.style.grid_column = .{
        .start = .{ .line = 2 },
        .end = .{ .line = 3 },
    };
    layout(&tree, .{ .width = 300, .height = 200 });
    try testing.expectEqual(@as(f32, 40), tree.node(first).?.rect.w);
    try testing.expectEqual(@as(f32, 100), tree.node(second).?.rect.w);
    try testing.expectEqual(@as(f32, 40), tree.node(second).?.rect.x);
}

test "grid explicit placement and spans cover the requested cells" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);
    const spanning: Id = @enumFromInt(1);
    const grid: Id = @enumFromInt(2);
    try appendNode(&tree, spanning, grid, .{ .spacer = .{ .size = 8 } });
    try appendNode(&tree, grid, .root, .{ .column = .{} });
    wireChildren(&tree);
    const columns = [_]style.GridTrack{
        .{ .fixed = 20 },
        .{ .fixed = 30 },
        .{ .fixed = 40 },
    };
    tree.node(grid).?.style = .{
        .display = .grid,
        .size = .{
            .width = .{ .length = 90 },
            .height = .{ .length = 40 },
        },
        .grid_template_columns = columns[0..],
        .grid_template_rows = &[_]style.GridTrack{.{ .fixed = 20 }},
    };
    tree.node(spanning).?.style.grid_column = .{
        .start = .{ .line = 1 },
        .end = .{ .span = 2 },
    };
    tree.node(spanning).?.style.grid_row = .{
        .start = .{ .line = 1 },
        .end = .{ .line = 2 },
    };
    layout(&tree, .{ .width = 120, .height = 80 });
    try testing.expectEqual(@as(f32, 50), tree.node(spanning).?.rect.w);
    try testing.expectEqual(@as(f32, 0), tree.node(spanning).?.rect.x);
}

test "grid row auto flow advances to the next free row" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);
    const first: Id = @enumFromInt(1);
    const second: Id = @enumFromInt(2);
    const third: Id = @enumFromInt(3);
    const grid: Id = @enumFromInt(4);
    for ([_]Id{ first, second, third }) |id|
        try appendNode(&tree, id, grid, .{ .spacer = .{ .size = 8 } });
    try appendNode(&tree, grid, .root, .{ .column = .{} });
    wireChildren(&tree);
    const columns = [_]style.GridTrack{ .{ .fixed = 10 }, .{ .fixed = 10 } };
    tree.node(grid).?.style = .{
        .display = .grid,
        .size = .{
            .width = .{ .length = 20 },
            .height = .{ .length = 30 },
        },
        .grid_template_columns = columns[0..],
        .grid_template_rows = &[_]style.GridTrack{.{ .fixed = 10 }},
        .grid_auto_flow = .row,
    };
    layout(&tree, .{ .width = 40, .height = 40 });
    try testing.expectEqual(@as(f32, 0), tree.node(first).?.rect.x);
    try testing.expectEqual(@as(f32, 10), tree.node(second).?.rect.x);
    try testing.expectEqual(@as(f32, 11.5), tree.node(third).?.rect.y);
    try testing.expectEqual(@as(f32, 0), tree.node(third).?.rect.x);
}

test "grid gaps separate tracks without changing item border sizes" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);
    const first: Id = @enumFromInt(1);
    const second: Id = @enumFromInt(2);
    const grid: Id = @enumFromInt(3);
    try appendNode(&tree, first, grid, .{ .spacer = .{ .size = 8 } });
    try appendNode(&tree, second, grid, .{ .spacer = .{ .size = 8 } });
    try appendNode(&tree, grid, .root, .{ .column = .{} });
    wireChildren(&tree);
    const columns = [_]style.GridTrack{ .{ .fixed = 20 }, .{ .fixed = 20 } };
    tree.node(grid).?.style = .{
        .display = .grid,
        .size = .{
            .width = .{ .length = 45 },
            .height = .{ .length = 20 },
        },
        .grid_template_columns = columns[0..],
        .grid_template_rows = &[_]style.GridTrack{.{ .fixed = 10 }},
        .grid_column_gap = 5,
    };
    layout(&tree, .{ .width = 60, .height = 40 });
    try testing.expectEqual(@as(f32, 20), tree.node(first).?.rect.w);
    try testing.expectEqual(@as(f32, 25), tree.node(second).?.rect.x);
}

test "grid item typed min and max constraints clamp the cell size" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);
    const item: Id = @enumFromInt(1);
    const grid: Id = @enumFromInt(2);
    try appendNode(&tree, item, grid, .{ .spacer = .{ .size = 4 } });
    try appendNode(&tree, grid, .root, .{ .column = .{} });
    wireChildren(&tree);
    tree.node(grid).?.style = .{
        .display = .grid,
        .size = .{
            .width = .{ .length = 50 },
            .height = .{ .length = 20 },
        },
        .grid_template_columns = &[_]style.GridTrack{.{ .fixed = 50 }},
        .grid_template_rows = &[_]style.GridTrack{.{ .fixed = 10 }},
    };
    tree.node(item).?.style.min_size.width = .{ .length = 60 };
    tree.node(item).?.style.max_size.width = .{ .length = 70 };
    layout(&tree, .{ .width = 70, .height = 30 });
    try testing.expectEqual(@as(f32, 60), tree.node(item).?.rect.w);
}

test "grid intrinsic auto tracks use child natural sizes" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);
    const first: Id = @enumFromInt(1);
    const second: Id = @enumFromInt(2);
    const grid: Id = @enumFromInt(3);
    try appendNode(&tree, first, grid, .{ .spacer = .{ .size = 18 } });
    try appendNode(&tree, second, grid, .{ .spacer = .{ .size = 26 } });
    try appendNode(&tree, grid, .root, .{ .column = .{} });
    wireChildren(&tree);
    tree.node(grid).?.style = .{
        .display = .grid,
        .size = .{
            .width = .{ .length = 44 },
            .height = .{ .length = 20 },
        },
        .grid_template_columns = &[_]style.GridTrack{
            .auto,
            .auto,
        },
        .grid_template_rows = &[_]style.GridTrack{
            .{ .fixed = 10 },
        },
    };
    layout(&tree, .{ .width = 60, .height = 40 });
    try testing.expectEqual(@as(f32, 18), tree.node(first).?.rect.w);
    try testing.expectEqual(@as(f32, 26), tree.node(second).?.rect.w);
}

test "grid fr tracks distribute remaining definite space" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);
    const first: Id = @enumFromInt(1);
    const second: Id = @enumFromInt(2);
    const grid: Id = @enumFromInt(3);
    try appendNode(&tree, first, grid, .{ .spacer = .{ .size = 4 } });
    try appendNode(&tree, second, grid, .{ .spacer = .{ .size = 4 } });
    try appendNode(&tree, grid, .root, .{ .column = .{} });
    wireChildren(&tree);
    tree.node(grid).?.style = .{
        .display = .grid,
        .size = .{
            .width = .{ .length = 100 },
            .height = .{ .length = 20 },
        },
        .grid_template_columns = &[_]style.GridTrack{ .{ .fr = 1 }, .{ .fr = 2 } },
        .grid_template_rows = &[_]style.GridTrack{.{ .fixed = 10 }},
    };
    layout(&tree, .{ .width = 120, .height = 40 });
    try testing.expectEqual(@as(f32, 100.0 / 3.0), tree.node(first).?.rect.w);
    try testing.expectEqual(@as(f32, 200.0 / 3.0), tree.node(second).?.rect.w);
}

test "grid excludes absolute children from auto flow" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);
    const normal: Id = @enumFromInt(1);
    const absolute: Id = @enumFromInt(2);
    const second: Id = @enumFromInt(3);
    const grid: Id = @enumFromInt(4);
    try appendNode(&tree, normal, grid, .{ .spacer = .{ .size = 10 } });
    try appendNode(&tree, absolute, grid, .{ .spacer = .{ .size = 50 } });
    try appendNode(&tree, second, grid, .{ .spacer = .{ .size = 10 } });
    try appendNode(&tree, grid, .root, .{ .column = .{} });
    wireChildren(&tree);
    tree.node(grid).?.style = .{
        .display = .grid,
        .size = .{
            .width = .{ .length = 20 },
            .height = .{ .length = 20 },
        },
        .grid_template_columns = &[_]style.GridTrack{ .{ .fixed = 10 }, .{ .fixed = 10 } },
        .grid_template_rows = &[_]style.GridTrack{.{ .fixed = 10 }},
    };
    tree.node(absolute).?.style.position = .absolute;
    tree.node(absolute).?.style.size = .{
        .width = .{ .length = 50 },
        .height = .{ .length = 10 },
    };
    layout(&tree, .{ .width = 50, .height = 30 });
    try testing.expectEqual(@as(f32, 10), tree.node(second).?.rect.x);
    try testing.expectEqual(@as(f32, 50), tree.node(absolute).?.rect.w);
}

test "column reverse places source order from the main-end edge" {
    var tree = WidgetTree.init(testing.allocator);
    defer tree.nodes.deinit(testing.allocator);

    const first: Id = @enumFromInt(1);
    const second: Id = @enumFromInt(2);
    const column: Id = @enumFromInt(3);
    try appendNode(&tree, first, column, .{ .spacer = .{ .size = 20 } });
    try appendNode(&tree, second, column, .{ .spacer = .{ .size = 20 } });
    try appendNode(&tree, column, .root, .{ .column = .{} });
    wireChildren(&tree);
    tree.node(column).?.style.direction = .column_reverse;
    tree.node(column).?.style.size = .{
        .width = .{ .length = 30 },
        .height = .{ .length = 100 },
    };

    layout(&tree, .{ .width = 30, .height = 100 });

    try testing.expectEqual(@as(f32, 80), tree.node(first).?.rect.y);
    try testing.expectEqual(@as(f32, 60), tree.node(second).?.rect.y);
}
