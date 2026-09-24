const std = @import("std");
const FrameNodeId = @import("../id.zig").FrameNodeId;
const block_float = @import("block_float.zig");
const context = @import("context.zig");
const flex = @import("flex.zig");
const grid = @import("grid.zig");
const overflow = @import("overflow.zig");
const sizing = @import("sizing.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");
const text = @import("../text.zig");

pub const Options = struct {
    allocator: std.mem.Allocator,
    available: widget.Size,
    measure: ?context.MeasureSource,
    width_mode: context.MeasureMode = .definite,
    height_mode: context.MeasureMode = .definite,
    storage: ?*context.LayoutStorage = null,
};
pub const LayoutError = context.LayoutError;

/// Resolve every node's text request exactly once, immediately before layout.
///
/// Parent inheritance is folded here rather than at draw time, so a directly
/// assembled tree inherits exactly like a `DrawCtx` one. A node whose authored
/// input and inherited base are unchanged keeps its existing immutable record:
/// a repeated `layoutTree` publishes nothing new, and a re-parented node — whose
/// inherited base changed — publishes a different one.
///
/// Records come from the tree's own arena, never from the caller's. The caller
/// owns storage whose lifetime is its own, so a record published there had no
/// owner to release it: a tree laid out repeatedly on the plain allocator leaked
/// both its current and its superseded records. The tree arena holds every
/// record, published or replaced, until `deinit` releases the set once.
fn resolveTextRequests(tree: *widget.WidgetTree) LayoutError!void {
    const records = tree.textRecordAllocator();
    // Node order is post-order, so a reverse walk visits a parent before any of
    // its children and every node resolves against an already published base.
    var index = tree.nodes.items.len;
    while (index > 0) {
        index -= 1;
        const node = &tree.nodes.items[index];
        const inherited: ?*const text.NodeText = if (node.parent == .root)
            null
        else blk: {
            const parent = tree.nodeConst(node.parent) orelse return error.InvalidStyle;
            break :blk parent.text_request;
        };
        if (node.text_input == null and inherited == null) {
            node.text_request = null;
            continue;
        }
        const resolved = text.resolveNodeText(
            inherited,
            node.text_input,
            style.textAlign(node.style.text_align),
        );
        if (node.text_request) |record| {
            if (text.nodeTextMatches(record, resolved)) continue;
        }
        node.text_request = try text.publishNodeText(records, resolved);
    }
}

fn validateScrollbarWidths(tree: *const widget.WidgetTree) LayoutError!void {
    for (tree.nodes.items) |*node| {
        const width = node.style.scrollbar_width;
        if (!std.math.isFinite(width) or width < 0) return error.InvalidStyle;
    }
}

const Edges = struct {
    border: style.Sides,
    padding: style.Sides,
    box_padding: style.Sides,
    gutter: style.Sides,
    box_horizontal: f32,
    box_vertical: f32,
    horizontal: f32,
    vertical: f32,
};
const RootMeasurement = struct {
    natural: context.Measured,
    width: f32,
};
pub fn layoutTree(tree: *widget.WidgetTree, options: Options) LayoutError!void {
    if (options.storage) |storage| storage.clearRetainingCapacity();
    defer if (options.storage) |storage| storage.clearRetainingCapacity();
    try validateScrollbarWidths(tree);
    try validateAvailable(options.available);
    try tree.prepareIdLookup();
    var roots = try validateTree(options.allocator, tree);
    defer roots.deinit(options.allocator);
    try resolveTextRequests(tree);
    resetDerivedState(tree);
    for (roots.items) |root_index| {
        try markHidden(tree, root_index, false, tree.nodes.items.len + 1);
    }
    // Postorder reversed visits parents first, so hidden paint state
    // propagates without removing hidden nodes from layout.
    var node_index = tree.nodes.items.len;
    while (node_index > 0) {
        node_index -= 1;
        const node = &tree.nodes.items[node_index];
        const parent_hidden = if (node.parent == .root)
            false
        else
            (tree.nodeConst(node.parent) orelse return error.InvalidStyle).paint_hidden;
        node.paint_hidden = node.layout_hidden or node.style.visibility == .hidden or parent_hidden;
    }
    tree.visibility_prepared = true;

    var layout_context: context.LayoutContext = .{
        .allocator = options.allocator,
        .measure = options.measure,
        .measure_node = measureNodeCallback,
        .layout_node = layoutNodeCallback,
        .storage = options.storage,
    };
    defer layout_context.deinit();
    if (options.width_mode != .definite or options.height_mode != .definite) {
        try layoutIntrinsicRoots(
            &layout_context,
            tree,
            roots.items,
            options,
        );
        return;
    }
    var items: std.ArrayList(RootItem) = .empty;
    defer items.deinit(options.allocator);
    for (roots.items) |root_index| {
        const node = &tree.nodes.items[root_index];
        if (node.layout_hidden) continue;
        const margins = try resolveRootMargins(node.style, options.available.width);
        const absolute = node.style.position == .absolute;
        const measured_root: RootMeasurement = if (absolute) blk: {
            const natural = try layout_context.measure_node(
                &layout_context,
                tree,
                node,
                .{
                    .available = options.available,
                    .percentage_basis = .{
                        .width = options.available.width,
                        .height = options.available.height,
                    },
                },
            );
            break :blk .{
                .natural = natural,
                .width = try rootWidth(
                    node.style,
                    natural,
                    options.available,
                    margins,
                ),
            };
        } else blk: {
            const width = try rootSizeFromInsets(
                options.available.width,
                0,
                0,
                margins.left,
                margins.right,
            );
            const natural = try layout_context.measure_node(
                &layout_context,
                tree,
                node,
                .{
                    .available = .{
                        .width = width,
                        .height = options.available.height,
                    },
                    .percentage_basis = .{
                        .width = width,
                        .height = options.available.height,
                    },
                    .width_mode = .definite,
                    .height_mode = .definite,
                },
            );
            break :blk .{
                .natural = natural,
                .width = width,
            };
        };
        const natural = measured_root.natural;
        const used_width = measured_root.width;
        const edge_basis = if (absolute) options.available.width else used_width;
        const edges = try resolveEdges(node.style, edge_basis);
        const base_height = if (absolute)
            try absoluteRootBaseHeight(
                node.style,
                natural,
                options.available,
                edges,
            )
        else
            try rootBaseHeight(
                node.style,
                natural,
                options.available,
                edges,
            );
        const min_height = if (absolute)
            try absoluteRootMinHeight(
                node.style,
                natural,
                options.available,
                edges,
            )
        else
            try rootMinHeight(
                node.style,
                natural,
                options.available,
                edges,
            );
        const max_height = try rootMaxHeight(
            node.style,
            natural,
            options.available,
            edges,
        );
        if (!std.math.isFinite(node.style.grow) or node.style.grow < 0) {
            return error.InvalidStyle;
        }
        if (!std.math.isFinite(node.style.shrink) or node.style.shrink < 0) {
            return error.InvalidStyle;
        }
        try items.append(options.allocator, .{
            .index = root_index,
            .natural = natural,
            .margins = margins,
            .width = used_width,
            .base_height = base_height,
            .height = clampRoot(base_height, min_height, max_height),
            .min_height = min_height,
            .shrink_floor = if (absolute)
                min_height
            else
                rootShrinkFloor(node.style, natural, min_height),
            .max_height = max_height,
            .grow = node.style.grow,
            .shrink = node.style.shrink,
            .absolute = absolute,
            .frozen = false,
        });
    }

    try resolveRootHeights(&items, options.available.height);
    var flow_cursor: f32 = 0;
    for (items.items) |*item| {
        const node = &tree.nodes.items[item.index];
        if (item.absolute) {
            try placeAbsoluteRoot(
                &layout_context,
                tree,
                node,
                item,
                options.available,
                false,
            );
        } else {
            try placeFlowRoot(
                &layout_context,
                tree,
                node,
                item,
                options.available,
                &flow_cursor,
                false,
            );
        }
    }
}

const RootItem = struct {
    index: usize,
    natural: context.Measured,
    margins: style.Sides,
    width: f32,
    base_height: f32,
    height: f32,
    min_height: f32,
    shrink_floor: f32,
    max_height: ?f32,
    grow: f32,
    shrink: f32,
    absolute: bool,
    frozen: bool,
};
const RootInsets = struct {
    top: ?f32,
    right: ?f32,
    bottom: ?f32,
    left: ?f32,
};

fn layoutIntrinsicRoots(
    self: *context.LayoutContext,
    tree: *widget.WidgetTree,
    roots: []const usize,
    options: Options,
) LayoutError!void {
    var flow_cursor: f32 = 0;
    for (roots) |root_index| {
        const node = &tree.nodes.items[root_index];
        if (node.layout_hidden) continue;

        const margins = try resolveRootMargins(
            node.style,
            if (options.width_mode == .definite)
                @as(?f32, options.available.width)
            else
                null,
        );
        const size = try measureIntrinsicRootSize(
            self,
            tree,
            node,
            options,
            margins,
        );
        const absolute = node.style.position == .absolute;
        try placeIntrinsicRoot(
            self,
            tree,
            node,
            size.width,
            size.height,
            if (absolute) 0 else flow_cursor,
            options,
        );
        if (!absolute) {
            flow_cursor = try finiteAdd(node.rect.y, node.rect.h);
        }
    }
}

fn measureIntrinsicRootSize(
    self: *context.LayoutContext,
    tree: *widget.WidgetTree,
    node: *const widget.WidgetNode,
    options: Options,
    margins: style.Sides,
) LayoutError!widget.Size {
    const percentage_basis: style.Size(?f32) = .{
        .width = if (options.width_mode == .definite) options.available.width else null,
        .height = if (options.height_mode == .definite) options.available.height else null,
    };
    var natural = try self.measure_node(
        self,
        tree,
        node,
        .{
            .available = .{
                .width = if (options.width_mode == .definite) options.available.width else 0,
                .height = if (options.height_mode == .definite) options.available.height else 0,
            },
            .percentage_basis = percentage_basis,
            .width_mode = options.width_mode,
            .height_mode = options.height_mode,
        },
    );
    var width = try intrinsicRootWidth(node, natural, options, margins);
    const edges = try resolveEdges(node.style, percentage_basis.width);
    width = try clampIntrinsicRootWidth(node.style, natural, width, percentage_basis.width, edges);

    if (options.width_mode != .definite) {
        natural = try self.measure_node(
            self,
            tree,
            node,
            .{
                .available = .{
                    .width = width,
                    .height = if (options.height_mode == .definite) options.available.height else 0,
                },
                .percentage_basis = percentage_basis,
                .width_mode = .definite,
                .height_mode = options.height_mode,
            },
        );
    }
    return .{
        .width = width,
        .height = try clampIntrinsicRootHeight(
            node.style,
            natural,
            natural.border.height,
            percentage_basis.height,
            edges,
        ),
    };
}

fn clampIntrinsicRootWidth(
    input: style.Style,
    natural: context.Measured,
    candidate: f32,
    percentage_basis: ?f32,
    edges: Edges,
) LayoutError!f32 {
    const minimum = (try rootDimensionBorder(
        input.min_size.width,
        percentage_basis,
        natural.content.width,
        edges.box_horizontal,
        edges.horizontal,
        input.box_sizing,
    )) orelse 0;
    const maximum = try rootDimensionBorder(
        input.max_size.width,
        percentage_basis,
        natural.content.width,
        edges.box_horizontal,
        edges.horizontal,
        input.box_sizing,
    );
    return clampRootFinite(candidate, minimum, maximum);
}

fn clampIntrinsicRootHeight(
    input: style.Style,
    natural: context.Measured,
    candidate: f32,
    percentage_basis: ?f32,
    edges: Edges,
) LayoutError!f32 {
    const minimum = (try rootDimensionBorder(
        input.min_size.height,
        percentage_basis,
        natural.content.height,
        edges.box_vertical,
        edges.vertical,
        input.box_sizing,
    )) orelse 0;
    const maximum = try rootDimensionBorder(
        input.max_size.height,
        percentage_basis,
        natural.content.height,
        edges.box_vertical,
        edges.vertical,
        input.box_sizing,
    );
    return clampRootFinite(candidate, minimum, maximum);
}

fn intrinsicRootWidth(
    node: *const widget.WidgetNode,
    natural: context.Measured,
    options: Options,
    margins: style.Sides,
) LayoutError!f32 {
    if (options.width_mode != .definite) {
        return finiteNonNegative(natural.border.width);
    }
    const block_root_stretches = node.style.position != .absolute and
        (node.style.display == .block or node.style.display == .flow_root) and
        node.style.size.width == .auto;
    if (block_root_stretches) {
        return rootSizeFromInsets(
            options.available.width,
            0,
            0,
            margins.left,
            margins.right,
        );
    }
    return finiteNonNegative(natural.border.width);
}

fn placeIntrinsicRoot(
    self: *context.LayoutContext,
    tree: *widget.WidgetTree,
    node: *widget.WidgetNode,
    width: f32,
    height: f32,
    y: f32,
    options: Options,
) LayoutError!void {
    const x = if (options.width_mode == .definite and
        node.style.writing_direction == .rtl)
        try finiteSubtract(options.available.width, width)
    else
        0;
    node.rect = .{
        .x = x,
        .y = y,
        .w = width,
        .h = height,
    };
    try validateRootRect(node.rect);
    try self.layout_node(
        self,
        tree,
        node,
        .{
            .available = .{ .width = width, .height = height },
            .percentage_basis = .{
                .width = if (options.width_mode == .definite) options.available.width else null,
                .height = if (options.height_mode == .definite) options.available.height else null,
            },
            .border = .{ .width = width, .height = height },
        },
    );
}

fn placeFlowRoot(
    self: *context.LayoutContext,
    tree: *widget.WidgetTree,
    node: *widget.WidgetNode,
    item: *RootItem,
    available: widget.Size,
    cursor: *f32,
    use_internal_basis: bool,
) LayoutError!void {
    const y = try finiteAdd(cursor.*, item.margins.top);
    node.rect = .{
        .x = item.margins.left,
        .y = y,
        .w = item.width,
        .h = item.height,
    };
    try applyRelativeRootInset(node, available);
    try validateRootRect(node.rect);
    const layout_available: widget.Size = if (use_internal_basis)
        .{ .width = item.width, .height = item.height }
    else
        available;
    try self.layout_node(
        self,
        tree,
        node,
        .{
            .available = layout_available,
            .percentage_basis = .{
                .width = layout_available.width,
                .height = layout_available.height,
            },
            .border = .{ .width = item.width, .height = item.height },
        },
    );
    const next_cursor = try finiteAdd(y, item.height);
    cursor.* = try finiteAdd(next_cursor, item.margins.bottom);
}

fn placeAbsoluteRoot(
    self: *context.LayoutContext,
    tree: *widget.WidgetTree,
    node: *widget.WidgetNode,
    item: *RootItem,
    available: widget.Size,
    use_internal_basis: bool,
) LayoutError!void {
    const insets = try resolveRootInsets(node.style, available);
    if (use_internal_basis) {
        const width = item.width;
        const height = item.height;
        const x = if (insets.left) |left|
            try finiteAdd(left, item.margins.left)
        else if (insets.right) |right| blk: {
            const after_right = try finiteSubtract(available.width, right);
            const after_margin = try finiteSubtract(after_right, item.margins.right);
            break :blk try finiteSubtract(after_margin, width);
        } else item.margins.left;
        const y = if (insets.top) |top|
            try finiteAdd(top, item.margins.top)
        else if (insets.bottom) |bottom| blk: {
            const after_bottom = try finiteSubtract(available.height, bottom);
            const after_margin = try finiteSubtract(after_bottom, item.margins.bottom);
            break :blk try finiteSubtract(after_margin, height);
        } else item.margins.top;
        node.rect = .{ .x = x, .y = y, .w = width, .h = height };
        try validateRootRect(node.rect);
        try self.layout_node(
            self,
            tree,
            node,
            .{
                .available = .{ .width = width, .height = height },
                .percentage_basis = .{ .width = width, .height = height },
                .border = .{ .width = width, .height = height },
            },
        );
        return;
    }
    const edges = try resolveEdges(node.style, available.width);
    const min_width = (try rootDimensionBorder(
        node.style.min_size.width,
        available.width,
        item.natural.content.width,
        edges.box_horizontal,
        edges.horizontal,
        node.style.box_sizing,
    )) orelse 0;
    const max_width = try rootDimensionBorder(
        node.style.max_size.width,
        available.width,
        item.natural.content.width,
        edges.box_horizontal,
        edges.horizontal,
        node.style.box_sizing,
    );
    const width_from_insets = node.style.size.width == .auto and
        insets.left != null and insets.right != null;
    const height_from_insets = node.style.size.height == .auto and
        insets.top != null and insets.bottom != null;
    var width = if (width_from_insets) blk: {
        const left = insets.left orelse return error.InvalidStyle;
        const right = insets.right orelse return error.InvalidStyle;
        break :blk try rootSizeFromInsets(
            available.width,
            left,
            right,
            item.margins.left,
            item.margins.right,
        );
    } else if (node.style.size.width == .auto)
        item.natural.border.width
    else
        item.width;
    if (width_from_insets and
        !hasIntrinsicRootConstraint(node.style.min_size.width) and
        !hasIntrinsicRootConstraint(node.style.max_size.width))
    {
        width = try clampRootFinite(width, min_width, max_width);
        item.natural = try self.measure_node(
            self,
            tree,
            node,
            .{
                .available = .{
                    .width = width,
                    .height = available.height,
                },
                .percentage_basis = .{
                    .width = width,
                    .height = available.height,
                },
                .width_mode = .definite,
                .height_mode = .definite,
            },
        );
    }
    const base_height = try absoluteRootBaseHeight(
        node.style,
        item.natural,
        available,
        edges,
    );
    const min_height = try absoluteRootMinHeight(
        node.style,
        item.natural,
        available,
        edges,
    );
    const max_height = try rootMaxHeight(
        node.style,
        item.natural,
        available,
        edges,
    );
    var height = if (height_from_insets) blk: {
        const top = insets.top orelse return error.InvalidStyle;
        const bottom = insets.bottom orelse return error.InvalidStyle;
        break :blk try rootSizeFromInsets(
            available.height,
            top,
            bottom,
            item.margins.top,
            item.margins.bottom,
        );
    } else base_height;

    if (node.style.aspect_ratio) |ratio| {
        if (!std.math.isFinite(ratio) or ratio <= 0) return error.InvalidStyle;
        const width_definite = node.style.size.width != .auto;
        const height_definite = node.style.size.height != .auto;
        if ((width_definite or width_from_insets) and
            !height_definite and
            !height_from_insets)
        {
            const width_for_ratio = try borderToContent(
                width,
                edges.horizontal,
                node.style.box_sizing,
            );
            const height_for_ratio = try finiteDivide(width_for_ratio, ratio);
            height = try sizingToBorder(
                height_for_ratio,
                edges.box_vertical,
                node.style.box_sizing,
            );
        } else if (!width_definite and
            (height_definite or height_from_insets) and
            !width_from_insets)
        {
            const height_for_ratio = try borderToContent(
                height,
                edges.vertical,
                node.style.box_sizing,
            );
            const width_for_ratio = try finiteMultiply(height_for_ratio, ratio);
            width = try sizingToBorder(
                width_for_ratio,
                edges.box_horizontal,
                node.style.box_sizing,
            );
        }
    }

    width = try clampRootFinite(width, min_width, max_width);
    height = try clampRootFinite(height, min_height, max_height);
    item.width = width;
    item.height = height;
    const x = if (insets.left) |left|
        try finiteAdd(left, item.margins.left)
    else if (insets.right) |right| blk: {
        const after_right = try finiteSubtract(available.width, right);
        const after_margin = try finiteSubtract(after_right, item.margins.right);
        break :blk try finiteSubtract(after_margin, width);
    } else item.margins.left;
    const y = if (insets.top) |top|
        try finiteAdd(top, item.margins.top)
    else if (insets.bottom) |bottom| blk: {
        const after_bottom = try finiteSubtract(available.height, bottom);
        const after_margin = try finiteSubtract(after_bottom, item.margins.bottom);
        break :blk try finiteSubtract(after_margin, height);
    } else item.margins.top;
    node.rect = .{ .x = x, .y = y, .w = width, .h = height };
    try validateRootRect(node.rect);
    try self.layout_node(
        self,
        tree,
        node,
        .{
            .available = available,
            .percentage_basis = .{
                .width = available.width,
                .height = available.height,
            },
            .border = .{ .width = width, .height = height },
        },
    );
}

fn resolveRootHeights(items: *std.ArrayList(RootItem), available: f32) LayoutError!void {
    var used: f32 = 0;
    for (items.items) |*item| {
        if (item.absolute) continue;
        item.height = clampRoot(item.base_height, item.min_height, item.max_height);
        item.frozen = false;
        used += item.height + item.margins.top + item.margins.bottom;
    }
    if (!std.math.isFinite(used)) return error.InvalidStyle;
    var iteration: usize = 0;
    while (iteration <= items.items.len) : (iteration += 1) {
        used = 0;
        for (items.items) |item| {
            if (item.absolute) continue;
            used += item.height + item.margins.top + item.margins.bottom;
        }
        if (!std.math.isFinite(used)) return error.InvalidStyle;
        const free = available - used;
        if (!std.math.isFinite(free) or free == 0) return;
        const growing = free > 0;
        for (items.items) |*item| {
            if (item.absolute) continue;
            if (growing) {
                if (item.max_height) |maximum| {
                    if (item.height >= maximum) item.frozen = true;
                }
            } else if (item.height <= item.shrink_floor) {
                item.frozen = true;
            }
        }
        var weight_sum: f32 = 0;
        for (items.items) |item| {
            if (item.absolute or item.frozen) continue;
            weight_sum += if (growing) item.grow else item.shrink * item.base_height;
        }
        if (!std.math.isFinite(weight_sum) or weight_sum <= 0) return;
        var clamped_any = false;
        for (items.items) |*item| {
            if (item.absolute or item.frozen) continue;
            const weight = if (growing) item.grow else item.shrink * item.base_height;
            const proposed = item.height + free * weight / weight_sum;
            if (!std.math.isFinite(proposed)) return error.InvalidStyle;
            var target = clampRoot(proposed, item.min_height, item.max_height);
            if (!growing and item.height > item.shrink_floor) {
                target = @max(target, item.shrink_floor);
            }
            if (target != proposed) {
                item.height = target;
                item.frozen = true;
                clamped_any = true;
            } else {
                item.height = proposed;
            }
        }
        if (!clamped_any) return;
    }
}

fn clampRoot(value: f32, minimum: f32, maximum: ?f32) f32 {
    var result = value;
    if (maximum) |limit| result = @min(result, limit);
    return @max(result, minimum);
}
fn clampRootFinite(value: f32, minimum: f32, maximum: ?f32) LayoutError!f32 {
    const finite_value = try finiteNonNegative(value);
    const finite_minimum = try finiteNonNegative(minimum);
    const finite_maximum = if (maximum) |limit|
        try finiteNonNegative(limit)
    else
        null;
    return finiteNonNegative(clampRoot(finite_value, finite_minimum, finite_maximum));
}

fn borderToContent(
    value: f32,
    edges: f32,
    box_sizing: style.BoxSizing,
) LayoutError!f32 {
    const finite_value = try finiteNonNegative(value);
    return switch (box_sizing) {
        .content_box => blk: {
            const difference = try finiteSubtract(finite_value, edges);
            break :blk finiteNonNegative(@max(0, difference));
        },
        .border_box => finite_value,
    };
}

fn rootSizeFromInsets(
    available: f32,
    leading: f32,
    trailing: f32,
    margin_leading: f32,
    margin_trailing: f32,
) LayoutError!f32 {
    var result = try finiteSubtract(available, leading);
    result = try finiteSubtract(result, trailing);
    result = try finiteSubtract(result, margin_leading);
    result = try finiteSubtract(result, margin_trailing);
    return finiteNonNegative(@max(0, result));
}

fn finiteAdd(lhs: f32, rhs: f32) LayoutError!f32 {
    return finiteSigned(lhs + rhs);
}

fn finiteSubtract(lhs: f32, rhs: f32) LayoutError!f32 {
    return finiteSigned(lhs - rhs);
}

fn finiteMultiply(lhs: f32, rhs: f32) LayoutError!f32 {
    return finiteSigned(lhs * rhs);
}

fn finiteDivide(lhs: f32, rhs: f32) LayoutError!f32 {
    return finiteSigned(lhs / rhs);
}

fn validateRootRect(rect: widget.Rect) LayoutError!void {
    _ = try finiteSigned(rect.x);
    _ = try finiteSigned(rect.y);
    _ = try finiteNonNegative(rect.w);
    _ = try finiteNonNegative(rect.h);
}

fn rootWidth(
    input: style.Style,
    natural: context.Measured,
    available: widget.Size,
    margins: style.Sides,
) LayoutError!f32 {
    return switch (input.size.width) {
        .auto => rootSizeFromInsets(
            available.width,
            0,
            0,
            margins.left,
            margins.right,
        ),
        .length, .percent, .min_content, .max_content, .fit_content => finiteNonNegative(
            natural.border.width,
        ),
    };
}

fn rootBaseHeight(
    input: style.Style,
    natural: context.Measured,
    available: widget.Size,
    edges: Edges,
) LayoutError!f32 {
    const basis = switch (input.flex_basis) {
        .auto => null,
        .length => |value| @as(?f32, value),
        .percent => |fraction| @as(?f32, try finiteMultiply(fraction, available.height)),
        .min_content, .max_content => @as(?f32, natural.content.height),
        .fit_content => |limit| @as(?f32, if (limit) |value|
            @min(natural.content.height, value)
        else
            natural.content.height),
    };
    if (basis) |value| {
        const edge_sum = switch (input.flex_basis) {
            .length, .percent => edges.box_vertical,
            .min_content, .max_content, .fit_content => edges.vertical,
            .auto => unreachable,
        };
        return sizingToBorder(value, edge_sum, input.box_sizing);
    }
    return finiteNonNegative(natural.border.height);
}
fn rootMinHeight(
    input: style.Style,
    natural: context.Measured,
    available: widget.Size,
    edges: Edges,
) LayoutError!f32 {
    var result: f32 = 0;
    if (try rootDimensionBorder(
        input.min_size.height,
        available.height,
        natural.content.height,
        edges.box_vertical,
        edges.vertical,
        input.box_sizing,
    )) |minimum| {
        result = @max(result, minimum);
    }
    return result;
}

fn absoluteRootBaseHeight(
    input: style.Style,
    natural: context.Measured,
    available: widget.Size,
    edges: Edges,
) LayoutError!f32 {
    return (try rootDimensionBorder(
        input.size.height,
        available.height,
        natural.content.height,
        edges.box_vertical,
        edges.vertical,
        input.box_sizing,
    )) orelse finiteNonNegative(natural.border.height);
}

fn absoluteRootMinHeight(
    input: style.Style,
    natural: context.Measured,
    available: widget.Size,
    edges: Edges,
) LayoutError!f32 {
    return (try rootDimensionBorder(
        input.min_size.height,
        available.height,
        natural.content.height,
        edges.box_vertical,
        edges.vertical,
        input.box_sizing,
    )) orelse 0;
}

fn rootMaxHeight(
    input: style.Style,
    natural: context.Measured,
    available: widget.Size,
    edges: Edges,
) LayoutError!?f32 {
    return rootDimensionBorder(
        input.max_size.height,
        available.height,
        natural.content.height,
        edges.box_vertical,
        edges.vertical,
        input.box_sizing,
    );
}

fn rootDimensionBorder(
    value: style.Dimension,
    basis: ?f32,
    intrinsic: f32,
    box_edges: f32,
    content_edges: f32,
    box_sizing: style.BoxSizing,
) LayoutError!?f32 {
    const content = switch (value) {
        .auto => return null,
        .length => |number| number,
        .percent => |fraction| if (basis) |resolved_basis|
            try finiteMultiply(fraction, resolved_basis)
        else
            return null,
        .min_content, .max_content => intrinsic,
        .fit_content => |limit_opt| if (limit_opt) |limit| @min(limit, intrinsic) else intrinsic,
    };
    const edge_sum = switch (value) {
        .length, .percent => box_edges,
        .min_content, .max_content, .fit_content => content_edges,
        .auto => unreachable,
    };
    return @as(?f32, try sizingToBorder(content, edge_sum, box_sizing));
}

fn rootShrinkFloor(
    input: style.Style,
    natural: context.Measured,
    minimum: f32,
) f32 {
    const explicit_minimum = input.min_size.height != .auto;
    return if (explicit_minimum) minimum else natural.border.height;
}
fn sizingToBorder(value: f32, edges: f32, box_sizing: style.BoxSizing) LayoutError!f32 {
    const non_negative = try finiteNonNegative(value);
    return switch (box_sizing) {
        .content_box => try finiteAdd(non_negative, edges),
        .border_box => finiteNonNegative(@max(edges, non_negative)),
    };
}

fn resolveRootMargins(input: style.Style, basis: ?f32) LayoutError!style.Sides {
    return .{
        .top = try resolveRootMargin(input.margin_inset.top, basis),
        .right = try resolveRootMargin(input.margin_inset.right, basis),
        .bottom = try resolveRootMargin(input.margin_inset.bottom, basis),
        .left = try resolveRootMargin(input.margin_inset.left, basis),
    };
}

fn resolveRootMargin(
    value: style.LengthPercentageAuto,
    basis: ?f32,
) LayoutError!f32 {
    const result = switch (value) {
        .auto => 0,
        .length => |number| number,
        .percent => |fraction| if (basis) |percentage_basis|
            try finiteMultiply(fraction, percentage_basis)
        else
            0,
    };
    return finiteSigned(result);
}
fn resolveRootInsets(input: style.Style, available: widget.Size) LayoutError!RootInsets {
    return .{
        .top = try resolveRootInset(input.inset.top, available.height),
        .right = try resolveRootInset(input.inset.right, available.width),
        .bottom = try resolveRootInset(input.inset.bottom, available.height),
        .left = try resolveRootInset(input.inset.left, available.width),
    };
}

fn resolveRootInset(value: style.LengthPercentageAuto, basis: f32) LayoutError!?f32 {
    return switch (value) {
        .auto => null,
        .length => |number| blk: {
            const resolved = try finiteSigned(number);
            break :blk @as(?f32, resolved);
        },
        .percent => |fraction| blk: {
            const resolved = try finiteMultiply(fraction, basis);
            break :blk @as(?f32, resolved);
        },
    };
}
fn finiteSigned(value: f32) LayoutError!f32 {
    if (!std.math.isFinite(value)) return error.InvalidStyle;
    return value;
}

fn applyRelativeRootInset(
    node: *widget.WidgetNode,
    available: widget.Size,
) LayoutError!void {
    if (node.style.position != .relative) return;
    const insets = try resolveRootInsets(node.style, available);
    if (insets.left) |left| {
        node.rect.x = try finiteAdd(node.rect.x, left);
    } else if (insets.right) |right| {
        node.rect.x = try finiteSubtract(node.rect.x, right);
    }
    if (insets.top) |top| {
        node.rect.y = try finiteAdd(node.rect.y, top);
    } else if (insets.bottom) |bottom| {
        node.rect.y = try finiteSubtract(node.rect.y, bottom);
    }
}

fn measureNodeCallback(
    self: *context.LayoutContext,
    tree: *widget.WidgetTree,
    node: *const widget.WidgetNode,
    request: context.Request,
) LayoutError!context.Measured {
    if (requestForcedSizing(request) or widget.isLateQuery(node) or
        (node.children.items.len != 0 and needsNaturalMeasurement(node, request)))
    {
        return switch (node.style.display) {
            .block, .flow_root => block_float.measureNatural(
                tree,
                node,
                request,
                self,
            ),
            .flex => flex.measureNatural(tree, node, request, self),
            .grid => grid.measureNatural(tree, node, request, self),
            .none => .{
                .content = .{ .width = 0, .height = 0 },
                .border = .{ .width = 0, .height = 0 },
            },
        };
    }
    return measureNode(
        tree,
        node,
        request,
        tree.nodes.items.len + 1,
        self.measure,
        self,
    );
}

fn needsNaturalMeasurement(
    node: *const widget.WidgetNode,
    request: context.Request,
) bool {
    return request.width_mode != .definite or
        request.height_mode != .definite or
        isIntrinsicDimension(node.style.size.width) or
        isIntrinsicDimension(node.style.size.height);
}

fn requestForcedSizing(request: context.Request) bool {
    return request.sizing_mode == .content or
        request.known_border.width != null or
        request.known_border.height != null;
}
fn isIntrinsicDimension(value: style.Dimension) bool {
    return switch (value) {
        .auto, .min_content, .max_content, .fit_content => true,
        .length, .percent => false,
    };
}
fn hasIntrinsicRootConstraint(value: style.Dimension) bool {
    return switch (value) {
        .min_content, .max_content, .fit_content => true,
        .auto, .length, .percent => false,
    };
}

fn layoutNodeCallback(
    self: *context.LayoutContext,
    tree: *widget.WidgetTree,
    node: *widget.WidgetNode,
    request: context.LayoutRequest,
) LayoutError!void {
    try validateLayoutRequest(request);
    if (node.layout_hidden) return;
    const node_index = tree.nodeIndex(node.id) orelse return error.InvalidStyle;
    if (&tree.nodes.items[node_index] != node) return error.InvalidStyle;
    if (node.children.items.len == 0) {
        try layoutLeaf(self, node, node_index, request);
        return;
    }
    const sizing_context: sizing.SizingContext = .{
        .available = .{
            .width = .{ .definite = request.available.width },
            .height = .{ .definite = request.available.height },
        },
        .percentage_basis = request.percentage_basis,
    };
    switch (node.style.display) {
        .none => return,
        .block, .flow_root => {
            var pass = block_float.LayoutPass.prepared(tree);
            try pass.layoutPreparedContainer(
                node.id,
                sizing_context,
                self.measure,
                self,
                request.border,
            );
        },
        .flex => try flex.layoutPreparedContainer(tree, node.id, .{
            .allocator = self.allocator,
            .available = request.available,
            .measure = self.measure,
            .context = self,
        }, request.border),
        .grid => try grid.layoutPreparedContainer(tree, node.id, .{
            .allocator = self.allocator,
            .available = request.available,
            .measure = self.measure,
            .context = self,
        }, request.border),
    }
}

fn measureNode(
    tree: *const widget.WidgetTree,
    node: *const widget.WidgetNode,
    request: context.Request,
    depth: usize,
    measure: ?context.MeasureSource,
    layout_ctx: *context.LayoutContext,
) LayoutError!context.Measured {
    if (depth == 0) return error.InvalidStyle;
    try validateRequest(request);
    if (node.layout_hidden or node.style.display == .none) return .{
        .content = .{ .width = 0, .height = 0 },
        .border = .{ .width = 0, .height = 0 },
    };
    const node_index = tree.nodeIndex(node.id) orelse return error.InvalidStyle;
    if (&tree.nodes.items[node_index] != node) return error.InvalidStyle;
    const edges = try resolveEdges(node.style, request.percentage_basis.width);
    const intrinsic: widget.Size = if (node.children.items.len == 0 or widget.isLateQuery(node))
        try measureLeaf(node, request, edges, measure, false, layout_ctx, node_index)
    else
        .{ .width = 0, .height = 0 };
    const width = try resolveConcreteDimension(
        node.style.size.width,
        request.percentage_basis.width,
        if (node.children.items.len == 0 or widget.isLateQuery(node)) intrinsic.width else null,
    );
    const height = try resolveConcreteDimension(
        node.style.size.height,
        request.percentage_basis.height,
        if (node.children.items.len == 0 or widget.isLateQuery(node)) intrinsic.height else null,
    );
    if (width == null or height == null) return error.InvalidStyle;
    const unclamped_border = try borderSize(
        node.style,
        .{ .width = width.?, .height = height.? },
        edges,
        request.percentage_basis,
    );
    const border = try clampBorderSize(
        node.style,
        unclamped_border,
        intrinsic,
        edges,
        request.percentage_basis,
    );
    return .{
        .content = .{
            .width = @max(0, border.width - edges.horizontal),
            .height = @max(0, border.height - edges.vertical),
        },
        .border = border,
    };
}

fn layoutLeaf(
    self: *context.LayoutContext,
    node: *widget.WidgetNode,
    node_index: usize,
    request: context.LayoutRequest,
) LayoutError!void {
    const edges = try resolveEdges(node.style, request.percentage_basis.width);
    node.resolved_box_edges = .{ .border = edges.border, .padding = edges.padding };
    const leaf_request: context.Request = .{
        .available = .{ .width = node.rect.w, .height = node.rect.h },
        .percentage_basis = request.percentage_basis,
    };
    const content = try measureLeaf(
        node,
        leaf_request,
        edges,
        self.measure,
        true,
        self,
        node_index,
    );
    node.layout_content_size = try overflow.contentExtent(content, edges.box_padding);
    // The leaf is already laid out here, so the text it paints can be measured
    // under the box it actually got. The pass cache holds that measurement, so
    // the baseline costs no shaping.
    const measured: ?context.TextMeasurement = if (context.visibleNodeText(node).len != 0)
        try self.measureVisibleNodeTextCached(node_index, node, .{
            .known_dimensions = .{
                .width = @max(0, node.rect.w - edges.horizontal),
                .height = @max(0, node.rect.h - edges.vertical),
            },
            .available_space = .{
                .width = .{ .definite = @max(0, node.rect.w - edges.horizontal) },
                .height = .{ .definite = @max(0, node.rect.h - edges.vertical) },
            },
            .text = node.text_request,
            .writing_mode = node.writing_mode,
        })
    else
        null;
    node.first_baseline = try context.textNodeBaseline(
        node,
        try finiteAdd(edges.border.top, edges.padding.top),
        measured,
    );
    if (node.scroll) |scroll| {
        scroll.state.max_offset = try overflow.maxOffset(
            node.layout_content_size,
            try overflow.clientSize(
                .{ .width = node.rect.w, .height = node.rect.h },
                edges.border,
                edges.gutter,
            ),
            scroll.axis,
        );
    }
}

fn measureLeaf(
    node: *const widget.WidgetNode,
    request: context.Request,
    edges: Edges,
    measure: ?context.MeasureSource,
    ignore_known: bool,
    layout_ctx: ?*context.LayoutContext,
    node_index: usize,
) LayoutError!widget.Size {
    const known_dimensions = if (ignore_known)
        sizing.OptionalSize{ .width = null, .height = null }
    else
        try measureKnownDimensions(node, request, edges);
    const available_space: sizing.AvailableSize = .{
        .width = try measureAvailableSpace(
            node.style.size.width,
            known_dimensions.width,
            request.available.width,
            edges.horizontal,
            request.width_mode,
        ),
        .height = try measureAvailableSpace(
            node.style.size.height,
            known_dimensions.height,
            request.available.height,
            edges.vertical,
            request.height_mode,
        ),
    };
    try context.validateLeafGeometry(node.kind);
    // The resolved, frame-owned text request rides along on every call. A
    // provider reads it instead of guessing from a scalar selector, and the
    // same record is what the paint path builds its request from.
    const measure_input: context.MeasureInput = .{
        .known_dimensions = known_dimensions,
        .available_space = available_space,
        .text = node.text_request,
        .writing_mode = node.writing_mode,
    };
    const result: widget.Size = switch (node.kind) {
        .label => |label| if (layout_ctx) |cached_context| try cached_context.measureTextSizeCached(
            node_index,
            label.text,
            measure_input,
            node.text_overflow,
            node.text_max_width,
        ) else try context.measureTextSize(
            measure,
            label.text,
            measure_input,
            node.text_overflow,
            node.text_max_width,
        ),
        .element => try context.measureElement(node, measure_input),
        .spacer => |spacer| .{ .width = spacer.size, .height = spacer.size },
        .button => .{ .width = 100, .height = 32 },
        .slider => if (layout_ctx) |cached_context| try cached_context.measureSliderContentCached(
            node_index,
            node,
            measure_input,
        ) else try context.measureSliderContent(measure, node, measure_input),
        .checkbox, .radio, .switch_control, .progress => try measureDecoratedLeaf(
            layout_ctx,
            node_index,
            node,
            context.controlCaption(node),
            measure_input,
            context.textDecoration(node.kind),
            measure,
        ),
        .separator => |separator| switch (separator.axis) {
            .horizontal => .{ .width = 100, .height = separator.thickness },
            .vertical => .{ .width = separator.thickness, .height = 100 },
        },
        .row, .column => .{ .width = 0, .height = 0 },
    };
    return .{
        .width = try finiteNonNegative(result.width),
        .height = try finiteNonNegative(result.height),
    };
}

fn measureDecoratedLeaf(
    layout_ctx: ?*context.LayoutContext,
    node_index: usize,
    node: *const widget.WidgetNode,
    content: []const u8,
    input: context.MeasureInput,
    decoration: context.TextDecoration,
    measure: ?context.MeasureSource,
) LayoutError!widget.Size {
    if (layout_ctx) |cached_context| {
        return cached_context.measureDecoratedTextSizeCached(
            node_index,
            content,
            input,
            node.text_overflow,
            node.text_max_width,
            decoration,
        );
    }
    return context.measureDecoratedTextSize(
        measure,
        content,
        input,
        node.text_overflow,
        node.text_max_width,
        decoration,
    );
}

fn measureKnownDimensions(
    node: *const widget.WidgetNode,
    request: context.Request,
    edges: Edges,
) LayoutError!sizing.OptionalSize {
    return .{
        .width = try knownDimensionForRequest(
            node.style.size.width,
            request.known_border.width,
            request.sizing_mode,
            request.percentage_basis.width,
            edges.box_horizontal,
            edges.horizontal,
            node.style.box_sizing,
        ),
        .height = try knownDimensionForRequest(
            node.style.size.height,
            request.known_border.height,
            request.sizing_mode,
            request.percentage_basis.height,
            edges.box_vertical,
            edges.vertical,
            node.style.box_sizing,
        ),
    };
}

fn knownDimensionForRequest(
    value: style.Dimension,
    known_border: ?f32,
    sizing_mode: context.SizingMode,
    basis: ?f32,
    box_edges: f32,
    content_edges: f32,
    box_sizing: style.BoxSizing,
) LayoutError!?f32 {
    if (known_border) |border| {
        return @as(?f32, try contentFromBorder(border, content_edges));
    }
    if (sizing_mode == .content) return null;
    return knownDimension(
        value,
        basis,
        box_edges,
        content_edges,
        box_sizing,
    );
}

fn knownDimension(
    value: style.Dimension,
    basis: ?f32,
    box_edges: f32,
    content_edges: f32,
    box_sizing: style.BoxSizing,
) LayoutError!?f32 {
    const sizing_value = switch (value) {
        .length => |number| try finiteNonNegative(number),
        .percent => |fraction| blk: {
            const percentage_basis = basis orelse return null;
            break :blk try finiteNonNegative(fraction * percentage_basis);
        },
        .auto, .min_content, .max_content, .fit_content => return null,
    };
    const border = switch (box_sizing) {
        .content_box => try finiteAdd(sizing_value, box_edges),
        .border_box => sizing_value,
    };
    return @as(?f32, try contentFromBorder(border, content_edges));
}

fn contentFromBorder(border: f32, edges: f32) LayoutError!f32 {
    const difference = try finiteSubtract(try finiteNonNegative(border), edges);
    return finiteNonNegative(@max(0, difference));
}

fn measureAvailableSpace(
    dimension: style.Dimension,
    known: ?f32,
    available_border: f32,
    edge_sum: f32,
    mode: context.MeasureMode,
) LayoutError!sizing.AvailableSpace {
    if (known) |value| return .{ .definite = try finiteNonNegative(value) };
    const available_content = @max(
        0,
        try finiteSubtract(try finiteNonNegative(available_border), edge_sum),
    );
    return switch (dimension) {
        .min_content => .min_content,
        .max_content => .max_content,
        .fit_content => |limit| .{
            .definite = if (limit) |value|
                @min(available_content, try finiteNonNegative(value))
            else
                available_content,
        },
        .auto, .length, .percent => switch (mode) {
            .definite => .{ .definite = available_content },
            .min_content => .min_content,
            .max_content => .max_content,
        },
    };
}

fn borderSize(
    input: style.Style,
    dimensions: widget.Size,
    edges: Edges,
    percentage_basis: style.Size(?f32),
) LayoutError!widget.Size {
    const width = if (dimensionUsesIntrinsic(
        input.size.width,
        percentage_basis.width,
    ))
        try finiteAdd(dimensions.width, edges.horizontal)
    else if (input.box_sizing == .content_box)
        try finiteAdd(dimensions.width, edges.box_horizontal)
    else
        dimensions.width;
    const height = if (dimensionUsesIntrinsic(
        input.size.height,
        percentage_basis.height,
    ))
        try finiteAdd(dimensions.height, edges.vertical)
    else if (input.box_sizing == .content_box)
        try finiteAdd(dimensions.height, edges.box_vertical)
    else
        dimensions.height;
    return .{
        .width = @max(edges.box_horizontal, try finiteNonNegative(width)),
        .height = @max(edges.box_vertical, try finiteNonNegative(height)),
    };
}

fn clampBorderSize(
    input: style.Style,
    candidate: widget.Size,
    intrinsic: widget.Size,
    edges: Edges,
    percentage_basis: style.Size(?f32),
) LayoutError!widget.Size {
    const minimum_width = (try rootDimensionBorder(
        input.min_size.width,
        percentage_basis.width,
        intrinsic.width,
        edges.box_horizontal,
        edges.horizontal,
        input.box_sizing,
    )) orelse 0;
    const maximum_width = try rootDimensionBorder(
        input.max_size.width,
        percentage_basis.width,
        intrinsic.width,
        edges.box_horizontal,
        edges.horizontal,
        input.box_sizing,
    );
    const minimum_height = (try rootDimensionBorder(
        input.min_size.height,
        percentage_basis.height,
        intrinsic.height,
        edges.box_vertical,
        edges.vertical,
        input.box_sizing,
    )) orelse 0;
    const maximum_height = try rootDimensionBorder(
        input.max_size.height,
        percentage_basis.height,
        intrinsic.height,
        edges.box_vertical,
        edges.vertical,
        input.box_sizing,
    );
    return .{
        .width = try clampRootFinite(candidate.width, minimum_width, maximum_width),
        .height = try clampRootFinite(candidate.height, minimum_height, maximum_height),
    };
}

fn resolveConcreteDimension(
    value: style.Dimension,
    percentage_basis: ?f32,
    intrinsic: ?f32,
) LayoutError!?f32 {
    return switch (value) {
        .length => |number| blk: {
            const resolved = try finiteNonNegative(number);
            break :blk @as(?f32, resolved);
        },
        .percent => |fraction| blk: {
            const basis = percentage_basis orelse return intrinsic;
            const resolved = try finiteNonNegative(fraction * basis);
            break :blk @as(?f32, resolved);
        },
        .auto, .min_content, .max_content, .fit_content => intrinsic,
    };
}

fn dimensionUsesIntrinsic(value: style.Dimension, percentage_basis: ?f32) bool {
    return isIntrinsicDimension(value) or
        (value == .percent and percentage_basis == null);
}

fn resolveEdges(input: style.Style, basis: ?f32) LayoutError!Edges {
    const width_basis = basis;
    _ = try finiteNonNegative(input.scrollbar_width);
    const border: style.Sides = .{
        .top = try resolveEdge(input.border_inset.top, width_basis),
        .right = try resolveEdge(input.border_inset.right, width_basis),
        .bottom = try resolveEdge(input.border_inset.bottom, width_basis),
        .left = try resolveEdge(input.border_inset.left, width_basis),
    };
    const resolved_padding: style.Sides = .{
        .top = try resolveEdge(input.padding_inset.top, width_basis),
        .right = try resolveEdge(input.padding_inset.right, width_basis),
        .bottom = try resolveEdge(input.padding_inset.bottom, width_basis),
        .left = try resolveEdge(input.padding_inset.left, width_basis),
    };
    const gutter = input.scrollbarGutter();
    const padding: style.Sides = .{
        .top = try finiteAdd(resolved_padding.top, gutter.top),
        .right = try finiteAdd(resolved_padding.right, gutter.right),
        .bottom = try finiteAdd(resolved_padding.bottom, gutter.bottom),
        .left = try finiteAdd(resolved_padding.left, gutter.left),
    };
    const box_horizontal = try finiteAdd(
        try finiteAdd(border.left, border.right),
        try finiteAdd(resolved_padding.left, resolved_padding.right),
    );
    const box_vertical = try finiteAdd(
        try finiteAdd(border.top, border.bottom),
        try finiteAdd(resolved_padding.top, resolved_padding.bottom),
    );
    return .{
        .border = border,
        .padding = padding,
        .box_padding = resolved_padding,
        .gutter = gutter,
        .box_horizontal = box_horizontal,
        .box_vertical = box_vertical,
        .horizontal = try finiteAdd(
            try finiteAdd(border.left, border.right),
            try finiteAdd(padding.left, padding.right),
        ),
        .vertical = try finiteAdd(
            try finiteAdd(border.top, border.bottom),
            try finiteAdd(padding.top, padding.bottom),
        ),
    };
}

fn resolveEdge(value: style.LengthPercentage, basis: ?f32) LayoutError!f32 {
    const result = switch (value) {
        .length => |number| number,
        .percent => |fraction| blk: {
            const percentage_basis = basis orelse break :blk 0;
            break :blk fraction * percentage_basis;
        },
    };
    return finiteNonNegative(result);
}

fn validateRequest(request: context.Request) LayoutError!void {
    try validateAvailable(request.available);
    if (request.percentage_basis.width) |width| _ = try finiteNonNegative(width);
    if (request.percentage_basis.height) |height| _ = try finiteNonNegative(height);
    if (request.known_border.width) |width| _ = try finiteNonNegative(width);
    if (request.known_border.height) |height| _ = try finiteNonNegative(height);
}

fn validateLayoutRequest(request: context.LayoutRequest) LayoutError!void {
    try validateAvailable(request.available);
    if (request.percentage_basis.width) |width| _ = try finiteNonNegative(width);
    if (request.percentage_basis.height) |height| _ = try finiteNonNegative(height);
    _ = try finiteNonNegative(request.border.width);
    _ = try finiteNonNegative(request.border.height);
}

fn validateAvailable(available: widget.Size) LayoutError!void {
    _ = try finiteNonNegative(available.width);
    _ = try finiteNonNegative(available.height);
}

fn finiteNonNegative(value: f32) LayoutError!f32 {
    if (!std.math.isFinite(value) or value < 0) return error.InvalidStyle;
    return value;
}

fn validateTree(
    allocator: std.mem.Allocator,
    tree: *const widget.WidgetTree,
) LayoutError!std.ArrayList(usize) {
    var roots: std.ArrayList(usize) = .empty;
    errdefer roots.deinit(allocator);
    var node_indices: std.AutoHashMapUnmanaged(FrameNodeId, u32) = .empty;
    defer node_indices.deinit(allocator);

    const node_count = std.math.cast(u32, tree.nodes.items.len) orelse
        return error.InvalidStyle;
    try node_indices.ensureTotalCapacity(allocator, node_count);
    for (tree.nodes.items, 0..) |*node, node_index| {
        if (node.id == .root) return error.InvalidStyle;
        const entry = node_indices.getOrPutAssumeCapacity(node.id);
        if (entry.found_existing) return error.InvalidStyle;
        entry.value_ptr.* = @intCast(node_index);
        if (node.parent == .root) {
            try roots.append(allocator, node_index);
        }
    }

    const incoming = try allocator.alloc(bool, tree.nodes.items.len);
    defer allocator.free(incoming);
    @memset(incoming, false);
    for (tree.nodes.items, 0..) |*parent, parent_index| {
        for (parent.children.items) |child_id| {
            if (child_id == .root) return error.InvalidStyle;
            const child_index: usize = @intCast(
                node_indices.get(child_id) orelse return error.InvalidStyle,
            );
            if (child_index >= parent_index) return error.InvalidStyle;
            const child = &tree.nodes.items[child_index];
            if (child.parent != parent.id) return error.InvalidStyle;
            if (incoming[child_index]) return error.InvalidStyle;
            incoming[child_index] = true;
        }
    }

    for (tree.nodes.items, incoming) |*node, has_incoming| {
        if (node.parent == .root) {
            if (has_incoming) return error.InvalidStyle;
        } else if (!has_incoming) {
            return error.InvalidStyle;
        }
    }
    return roots;
}

fn resetDerivedState(tree: *widget.WidgetTree) void {
    tree.visibility_prepared = false;
    for (tree.nodes.items) |*node| {
        node.layout_hidden = false;
        node.paint_hidden = false;
        node.first_baseline = null;
        node.layout_content_size = .{ .width = 0, .height = 0 };
        if (node.scroll) |scroll| {
            scroll.state.max_offset = .{ 0, 0 };
        }
    }
}

fn markHidden(
    tree: *widget.WidgetTree,
    index: usize,
    inherited: bool,
    depth: usize,
) LayoutError!void {
    if (depth == 0 or index >= tree.nodes.items.len) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    const hidden = inherited or node.style.display == .none;
    node.layout_hidden = hidden;
    if (hidden) {
        node.first_baseline = null;
        node.rect = .{};
        node.resolved_box_edges = null;
        node.layout_content_size = .{ .width = 0, .height = 0 };
        if (node.scroll) |scroll| {
            scroll.state.max_offset = .{ 0, 0 };
        }
    }
    for (node.children.items) |child_id| {
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        try markHidden(tree, child_index, hidden, depth - 1);
    }
}
