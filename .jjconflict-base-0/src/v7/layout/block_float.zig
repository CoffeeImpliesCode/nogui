const std = @import("std");
const Id = @import("../id.zig").Id;
const layout_context = @import("context.zig");
const overflow = @import("overflow.zig");
const style = @import("../style.zig");
const sizing = @import("sizing.zig");
const widget = @import("../widget.zig");

const PhysicalSide = enum { none, left, right };

const BoxEdges = struct {
    border: style.Sides,
    padding: style.Sides,
    scrollbar_gutter: style.Sides,
    box_horizontal: f32,
    box_vertical: f32,
    horizontal: f32,
    vertical: f32,
};
const Natural = struct {
    content: widget.Size,
    border: widget.Size,
    edge_vertical: f32 = 0,
    content_inset: [2]f32 = .{ 0, 0 },
    margin_collapse: ?MarginCollapseResult = null,
    bfc: BfcState = .{},
};
const NaturalBlockContent = struct {
    size: widget.Size,
    margin_collapse: MarginCollapseResult,
    bfc: BfcState = .{},
};
const ScratchFloat = struct {
    side: PhysicalSide,
    intrinsic_width: f32,
    outer: widget.Rect,
};
const NaturalScratch = struct {
    floats: []ScratchFloat,
    context: *layout_context.LayoutContext,
    count: usize = 0,

    fn slice(self: *const NaturalScratch, start: usize) sizing.Error![]const ScratchFloat {
        if (start > self.count or self.count > self.floats.len) {
            return error.InvalidStyle;
        }
        return self.floats[start..self.count];
    }

    fn append(self: *NaturalScratch, float: ScratchFloat) sizing.Error!void {
        if (self.count >= self.floats.len) return error.InvalidStyle;
        const next = std.math.add(usize, self.count, 1) catch return error.InvalidStyle;
        try self.context.setBlockScratchCount(ScratchFloat, next);
        self.floats[self.count] = float;
        self.count = next;
    }

    fn truncate(self: *NaturalScratch, count: usize) sizing.Error!void {
        if (count > self.count) return error.InvalidStyle;
        try self.context.setBlockScratchCount(ScratchFloat, count);
        self.count = count;
    }

    fn translate(
        self: *NaturalScratch,
        start: usize,
        x: f32,
        y: f32,
    ) sizing.Error!void {
        if (start > self.count or self.count > self.floats.len) {
            return error.InvalidStyle;
        }
        const checked_x = try finite(x);
        const checked_y = try finite(y);
        for (self.floats[start..self.count]) |*float| {
            float.outer.x = try addFinite(float.outer.x, checked_x);
            float.outer.y = try addFinite(float.outer.y, checked_y);
        }
    }
};

const Slot = struct {
    left: f32,
    right: f32,
    next_y: f32,
    occupied: bool,
    has_float: [2]bool = .{ false, false },
};
const OccupiedState = struct {
    slot: *Slot,
    candidate_y: f32,
    candidate_height: f32,
};

const Placement = struct {
    x: f32,
    y: f32,
    slot_width: f32,
};
const BfcPlacement = struct {
    x: f32,
    y: f32,
    slot_width: f32,
    stretch_width: f32,
};
const BfcAutoPlacement = struct {
    x: f32,
    y: f32,
    border_width: f32,
    slot_width: f32,
};
const ClearanceState = struct {
    clear: style.Clear,
    direction: style.Direction,
    bottom: f32 = 0,
};
const FloatQuery = union(enum) {
    slot: *OccupiedState,
    clearance: *ClearanceState,
};
const ContainerInitialSize = struct {
    border_width: f32,
    border_height: ?f32,
};

const CollapsibleMarginSet = struct {
    positive: f32 = 0,
    negative: f32 = 0,

    fn fromMargin(margin: f32) CollapsibleMarginSet {
        return if (margin >= 0)
            .{ .positive = margin }
        else
            .{ .negative = margin };
    }

    fn collapse(self: CollapsibleMarginSet, other: CollapsibleMarginSet) CollapsibleMarginSet {
        return .{
            .positive = @max(self.positive, other.positive),
            .negative = @min(self.negative, other.negative),
        };
    }

    fn resolve(self: CollapsibleMarginSet) f32 {
        return self.positive + self.negative;
    }
};
const MarginCollapseResult = struct {
    top: CollapsibleMarginSet = .{},
    bottom: CollapsibleMarginSet = .{},
    through: bool = false,
};
const BfcState = struct {
    /// The greatest content-relative bottom reached by floats in this BFC.
    float_content_contribution: f32 = 0,

    fn addFloat(self: *BfcState, y: f32, height: f32) sizing.Error!void {
        const contribution = try addFinite(y, height);
        self.float_content_contribution = @max(
            self.float_content_contribution,
            contribution,
        );
    }

    fn mergeChild(
        self: *BfcState,
        child: BfcState,
        child_content_origin_y: f32,
    ) sizing.Error!void {
        if (child.float_content_contribution <= 0) return;
        const contribution = try addFinite(
            child_content_origin_y,
            child.float_content_contribution,
        );
        self.float_content_contribution = @max(
            self.float_content_contribution,
            contribution,
        );
    }
};
const BlockLayoutResult = struct {
    margins: MarginCollapseResult = .{},
    bfc: BfcState = .{},
};

/// A prepared block-layout pass for one widget tree.
///
/// Initialization classifies hidden layout once. Every container call then uses
/// those prepared markers without repeating the full-tree traversal. Callers
/// must create a new pass after changing display or parent relationships.
pub const LayoutPass = struct {
    tree: *widget.WidgetTree,

    pub fn init(tree: *widget.WidgetTree) sizing.Error!LayoutPass {
        try classifyHiddenLayout(tree);
        return .{ .tree = tree };
    }
    pub fn prepared(tree: *widget.WidgetTree) LayoutPass {
        return .{ .tree = tree };
    }
    pub fn layoutContainer(
        self: *const LayoutPass,
        container_id: Id,
        context: sizing.SizingContext,
        measure: ?layout_context.MeasureFn,
    ) sizing.Error!void {
        _ = try layoutPreparedContainerUnchecked(
            self.tree,
            container_id,
            context,
            measure,
            null,
            null,
            true,
            null,
        );
    }

    /// Lay out a validated, already-prepared subtree through the mixed-layout
    /// callback bridge.
    pub fn layoutPreparedContainer(
        self: *const LayoutPass,
        container_id: Id,
        context: sizing.SizingContext,
        measure: ?layout_context.MeasureFn,
        layout_ctx: ?*layout_context.LayoutContext,
        forced_border: ?widget.Size,
    ) sizing.Error!void {
        _ = try layoutPreparedContainerUnchecked(
            self.tree,
            container_id,
            context,
            measure,
            if (forced_border) |border| border.width else null,
            if (forced_border) |border| border.height else null,

            forced_border == null,
            layout_ctx,
        );
    }
};
/// Measure a block container's natural content and border size without placing it.
///
/// Auto widths remain content-driven during the query. The parent layout
/// engine owns any later used-width override and final placement.
pub fn measureNatural(
    tree: *widget.WidgetTree,
    node: *const widget.WidgetNode,
    request: layout_context.Request,
    context: *layout_context.LayoutContext,
) sizing.Error!layout_context.Measured {
    const index = tree.nodeIndex(node.id) orelse return error.InvalidStyle;
    if (&tree.nodes.items[index] != node) return error.InvalidStyle;
    try layout_context.validateNaturalRequest(tree, node, request);
    const scratch_floats = try context.acquireBlockScratch(ScratchFloat, tree.nodes.items.len);
    defer context.releaseBlockScratch();
    var scratch: NaturalScratch = .{ .floats = scratch_floats, .context = context };
    const natural = try measureNaturalNode(
        tree,
        index,
        request,
        context,
        tree.nodes.items.len,
        &scratch,
    );
    return .{
        .content = natural.content,
        .border = natural.border,
    };
}

fn measureNaturalNode(
    tree: *widget.WidgetTree,
    index: usize,
    request: layout_context.Request,
    context: *layout_context.LayoutContext,
    depth: usize,
    scratch: *NaturalScratch,
) sizing.Error!Natural {
    if (depth == 0 or index >= tree.nodes.items.len) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    if (node.layout_hidden or node.style.display == .none) return .{
        .content = .{ .width = 0, .height = 0 },
        .border = .{ .width = 0, .height = 0 },
    };

    var effective_request = request;
    const inline_available_definite = naturalAxisAvailableDefiniteForRequest(
        node.style.size.width,
        request.width_mode,
        request.percentage_basis.width,
        request.sizing_mode,
        request.known_border.width,
    );
    if (!inline_available_definite and node.style.position != .absolute) {
        effective_request.percentage_basis.width = null;
    }
    const edges = try resolveBoxEdges(
        node.style,
        effective_request.percentage_basis.width,
    );
    var margin_collapse: ?MarginCollapseResult = null;
    var bfc: BfcState = .{};
    const content = if (node.children.items.len == 0)
        try measureNaturalLeaf(node, edges, effective_request, context.measure)
    else switch (node.style.display) {
        .block, .flow_root => blk: {
            const block_content = try measureNaturalBlockContent(
                tree,
                index,
                effective_request,
                edges,
                context,
                depth - 1,
                scratch,
                scratch.count,
            );
            margin_collapse = block_content.margin_collapse;
            bfc = block_content.bfc;
            break :blk block_content.size;
        },
        .flex, .grid => return error.InvalidStyle,
        .none => unreachable,
    };
    const sizing_context: sizing.SizingContext = .{
        .available = .{
            .width = .{ .definite = effective_request.available.width },
            .height = .{ .definite = effective_request.available.height },
        },
        .percentage_basis = effective_request.percentage_basis,
    };
    const resolved = try resolveChildSizeForRequest(
        node.style,
        sizing_context,
        content,
        edges,
        effective_request,
    );
    return .{
        .content = content,
        .border = .{ .width = resolved.width, .height = resolved.height },
        .edge_vertical = edges.vertical,
        .content_inset = .{
            try addFinite(edges.border.left, edges.padding.left),
            try addFinite(edges.border.top, edges.padding.top),
        },
        .margin_collapse = margin_collapse,
        .bfc = bfc,
    };
}

fn measureNaturalBlockContent(
    tree: *widget.WidgetTree,
    index: usize,
    request: layout_context.Request,
    edges: BoxEdges,
    context: *layout_context.LayoutContext,
    depth: usize,
    scratch: *NaturalScratch,
    float_start: usize,
) sizing.Error!NaturalBlockContent {
    if (depth == 0) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    const parent_is_flex_or_grid = if (tree.nodeConst(node.parent)) |parent|
        parent.style.display == .flex or parent.style.display == .grid
    else
        false;
    const container_establishes_bfc = node.parent == .root or
        establishesBfc(node.style) or
        (node.style.display == .block and parent_is_flex_or_grid);
    const sizing_context: sizing.SizingContext = .{
        .available = .{
            .width = .{ .definite = request.available.width },
            .height = .{ .definite = request.available.height },
        },
        .percentage_basis = request.percentage_basis,
    };
    const box_model = try sizing.resolveBoxModel(
        naturalRootBoxModelStyle(node.style, request),
        sizing_context,
    );
    const provisional_border = try naturalProvisionalBorder(
        node.style,
        sizing_context,
        box_model,
        request,
        edges,
    );
    const child_available: widget.Size = .{
        .width = @max(0, try subtractFinite(provisional_border.width, edges.horizontal)),
        .height = @max(0, try subtractFinite(provisional_border.height, edges.vertical)),
    };
    const width_available_definite = naturalAxisAvailableDefiniteForRequest(
        node.style.size.width,
        request.width_mode,
        request.percentage_basis.width,
        request.sizing_mode,
        request.known_border.width,
    );
    const height_available_definite = naturalAxisAvailableDefiniteForRequest(
        node.style.size.height,
        request.height_mode,
        request.percentage_basis.height,
        request.sizing_mode,
        request.known_border.height,
    );
    const width_basis_definite = width_available_definite;
    const height_basis_definite = naturalAxisBasisDefiniteForRequest(
        node.style.size.height,
        request.percentage_basis.height,
        request.sizing_mode,
        request.known_border.height,
    );
    const root_height_definite = request.known_border.height != null or
        (request.sizing_mode != .content and box_model.border_box.height != null);
    const margins_collapse_with_children = node.style.display == .block and
        node.style.position == .relative and
        !container_establishes_bfc and
        !root_height_definite;
    const top_margin_collapses_with_children = margins_collapse_with_children and
        edges.border.top == 0 and
        edges.padding.top == 0;
    const bottom_margin_collapses_with_children = margins_collapse_with_children and
        edges.border.bottom == 0 and
        edges.padding.bottom == 0;

    var flow_y: f32 = 0;
    var in_flow_bottom: f32 = 0;
    var float_bottom: f32 = 0;
    var bfc_state: BfcState = .{};
    var float_ceiling: f32 = 0;
    var content_width_natural: f32 = 0;
    var float_intrinsic_total: f32 = 0;
    var float_intrinsic_widest: f32 = 0;
    var pending_bottom: ?CollapsibleMarginSet = null;
    var first_child_top: CollapsibleMarginSet = .{};
    var last_child_bottom: ?CollapsibleMarginSet = null;
    var top_collapse_open = top_margin_collapses_with_children;
    var all_in_flow_children_collapse_through = true;
    var bottom_margin_barrier = false;

    for (node.children.items) |child_id| {
        const child = tree.nodeConst(child_id) orelse return error.InvalidStyle;
        if (child.layout_hidden or child.style.position == .absolute) continue;
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        const child_request: layout_context.Request = .{
            .available = child_available,
            .percentage_basis = .{
                .width = if (width_basis_definite)
                    @as(?f32, child_available.width)
                else
                    request.percentage_basis.width,
                .height = if (height_basis_definite)
                    @as(?f32, child_available.height)
                else
                    null,
            },
            .width_mode = if (width_available_definite)
                .definite
            else if (request.width_mode == .min_content)
                .min_content
            else if (request.width_mode == .max_content or
                dimensionAuto(child.style.size.width) or
                isIntrinsicDimension(child.style.size.width))
                .max_content
            else
                .definite,
            .height_mode = if (height_available_definite)
                .definite
            else if (request.height_mode == .min_content)
                .min_content
            else if (request.height_mode == .max_content or
                dimensionAuto(child.style.size.height) or
                isIntrinsicDimension(child.style.size.height))
                .max_content
            else
                .definite,
            .sizing_mode = .inherent,
            .known_border = .{ .width = null, .height = null },
        };
        const child_establishes_bfc = establishesIndependentFormattingContext(child.style);
        const float_side = physicalFloat(child.style.float, child.style.writing_direction);
        const child_float_begin = scratch.count;
        const clear_y = try scratchClearBottom(
            try scratch.slice(float_start),
            child.style.clear,
            child.style.writing_direction,
        );
        var natural = if (child.children.items.len == 0 or
            child.style.display == .block or
            child.style.display == .flow_root)
        blk: {
            try layout_context.validateNaturalRequest(tree, child, child_request);
            break :blk try measureNaturalNode(
                tree,
                child_index,
                child_request,
                context,
                depth,
                scratch,
            );
        } else switch (child.style.display) {
            .flex, .grid => blk: {
                const measured = try context.measure_node(
                    context,
                    tree,
                    child,
                    child_request,
                );
                const child_edges = try resolveBoxEdges(
                    child.style,
                    child_request.percentage_basis.width,
                );
                break :blk Natural{
                    .content = measured.content,
                    .border = measured.border,
                    .edge_vertical = child_edges.vertical,
                };
            },
            .none => Natural{
                .content = .{ .width = 0, .height = 0 },
                .border = .{ .width = 0, .height = 0 },
            },
            .block, .flow_root => unreachable,
        };
        if (child_establishes_bfc) {
            try scratch.truncate(child_float_begin);
        }
        const margins = try resolveMargins(child.style, child_request.percentage_basis.width);
        if (width_available_definite and
            child.style.size.width == .auto and
            child.style.position == .relative and
            child.style.float == .none and
            !establishesIndependentFormattingContext(child.style))
        {
            const child_edges = try resolveBoxEdges(
                child.style,
                child_request.percentage_basis.width,
            );
            const child_sizing_context: sizing.SizingContext = .{
                .available = .{
                    .width = .{ .definite = child_request.available.width },
                    .height = .{ .definite = child_request.available.height },
                },
                .percentage_basis = child_request.percentage_basis,
            };
            const used_border = try resolveChildSize(
                child.style,
                child_sizing_context,
                natural.content,
                child_edges,
                @max(
                    0,
                    try subtractFinite(
                        try subtractFinite(child_available.width, margins.left),
                        margins.right,
                    ),
                ),
                null,
                false,
            );
            natural.border.width = used_border.width;
            natural.border.height = used_border.height;
        }
        const intrinsic_margin_left = try resolveMargin(
            child.style.margin_inset.left,
            null,
        );
        const intrinsic_margin_right = try resolveMargin(
            child.style.margin_inset.right,
            null,
        );
        const intrinsic_outer_width = try addFinite(
            try addFinite(natural.border.width, intrinsic_margin_left),
            intrinsic_margin_right,
        );
        content_width_natural = @max(content_width_natural, intrinsic_outer_width);

        const outer_width = @max(
            0,
            try addFinite(
                try addFinite(natural.border.width, margins.left),
                margins.right,
            ),
        );
        const outer_height = @max(
            0,
            try addFinite(
                try addFinite(natural.border.height, margins.top),
                margins.bottom,
            ),
        );
        if (float_side != .none) {
            const margin_cursor_y = if (pending_bottom) |bottom_margin|
                try addFinite(flow_y, bottom_margin.resolve())
            else
                flow_y;
            const float_start_y = @max(@max(margin_cursor_y, clear_y), float_ceiling);
            const placement = try findScratchSlot(
                try scratch.slice(float_start),
                child_available.width,
                outer_width,
                outer_height,
                float_start_y,
                float_side,
            );
            const placed_float: ScratchFloat = .{
                .side = float_side,
                .intrinsic_width = intrinsic_outer_width,
                .outer = .{
                    .x = placement.x,
                    .y = placement.y,
                    .w = outer_width,
                    .h = outer_height,
                },
            };
            try scratch.append(placed_float);
            float_intrinsic_total = try addFinite(
                float_intrinsic_total,
                intrinsic_outer_width,
            );
            float_intrinsic_widest = @max(
                float_intrinsic_widest,
                intrinsic_outer_width,
            );
            if (request.width_mode != .min_content) {
                content_width_natural = @max(
                    content_width_natural,
                    try scratchFloatRunWidth(
                        try scratch.slice(float_start),
                        placement.y,
                    ),
                );
            }
            float_ceiling = @max(float_ceiling, placement.y);
            float_bottom = @max(
                float_bottom,
                try addFinite(placement.y, outer_height),
            );
            try bfc_state.addFloat(placement.y, outer_height);
            continue;
        }

        const child_top_margin = CollapsibleMarginSet.fromMargin(margins.top).collapse(
            if (natural.margin_collapse) |result| result.top else .{},
        );
        const child_bottom_margin = CollapsibleMarginSet.fromMargin(margins.bottom).collapse(
            if (natural.margin_collapse) |result| result.bottom else .{},
        );
        var child_collapses_through = if (child.style.aspect_ratio != null)
            false
        else if (natural.margin_collapse) |result|
            result.through
        else
            natural.border.height == 0 and
                natural.edge_vertical == 0 and
                !establishesIndependentFormattingContext(child.style) and
                !hasLineBox(child);

        const hypothetical_margin = if (top_collapse_open and !child_establishes_bfc)
            @as(f32, 0)
        else if (pending_bottom) |bottom_margin|
            bottom_margin.collapse(child_top_margin).resolve()
        else
            child_top_margin.resolve();
        const hypothetical_y = try addFinite(flow_y, hypothetical_margin);
        const forced_clearance = top_collapse_open and clear_y > 0;
        const has_clearance = clear_y > 0 and
            (forced_clearance or hypothetical_y < clear_y);
        const self_collapsing_with_clearance = has_clearance and child_collapses_through;
        if (has_clearance) child_collapses_through = false;

        const effective_start_y = if (has_clearance) clear_y else flow_y;
        const vertical_margin = if (has_clearance)
            if (top_collapse_open and !child_establishes_bfc)
                @as(f32, 0)
            else
                child_top_margin.resolve()
        else
            hypothetical_margin;
        var child_y = try addFinite(effective_start_y, vertical_margin);
        if (child_establishes_bfc) {
            const bfc_start_y = try addFinite(
                effective_start_y,
                vertical_margin,
            );
            const placement = try findNaturalBfcSlot(
                try scratch.slice(float_start),
                child_available.width,
                natural.border.width,
                outer_height,
                bfc_start_y,
                node.style.writing_direction,
                margins,
                child.style.size.width == .auto,
            );
            child_y = placement.y;
        }
        if (!child_establishes_bfc and scratch.count > child_float_begin) {
            const child_border_x = if (node.style.writing_direction == .ltr)
                margins.left
            else
                try subtractFinite(
                    try subtractFinite(child_available.width, natural.border.width),
                    margins.right,
                );
            const child_content_origin_x = try addFinite(
                child_border_x,
                natural.content_inset[0],
            );
            const child_content_origin_y = try addFinite(
                child_y,
                natural.content_inset[1],
            );
            try scratch.translate(
                child_float_begin,
                child_content_origin_x,
                child_content_origin_y,
            );
            try bfc_state.mergeChild(natural.bfc, child_content_origin_y);
        }

        if (top_collapse_open and !child_establishes_bfc and !has_clearance) {
            first_child_top = first_child_top.collapse(child_top_margin);
            if (child_collapses_through) {
                first_child_top = first_child_top.collapse(child_bottom_margin);
            } else {
                top_collapse_open = false;
            }
        } else if (top_collapse_open) {
            top_collapse_open = false;
        }
        all_in_flow_children_collapse_through =
            all_in_flow_children_collapse_through and child_collapses_through;

        if (self_collapsing_with_clearance) {
            const collapsed_margin = child_top_margin.collapse(child_bottom_margin);
            flow_y = try subtractFinite(child_y, child_top_margin.resolve());
            pending_bottom = collapsed_margin;
            last_child_bottom = collapsed_margin;
            in_flow_bottom = @max(
                in_flow_bottom,
                try addFinite(flow_y, collapsed_margin.resolve()),
            );
            bottom_margin_barrier = true;
        } else if (child_collapses_through) {
            const child_self_collapsed = child_top_margin.collapse(child_bottom_margin);
            const combined_bottom = if (pending_bottom) |previous|
                previous.collapse(child_self_collapsed)
            else
                child_self_collapsed;
            pending_bottom = combined_bottom;
            last_child_bottom = combined_bottom;
        } else {
            flow_y = try addFinite(child_y, natural.border.height);
            pending_bottom = child_bottom_margin;
            last_child_bottom = child_bottom_margin;
            in_flow_bottom = @max(in_flow_bottom, flow_y);
            bottom_margin_barrier = false;
        }
    }

    if (float_intrinsic_total > 0) {
        const float_intrinsic_width = switch (request.width_mode) {
            .max_content => float_intrinsic_total,
            .min_content => float_intrinsic_widest,
            .definite => @max(
                @min(float_intrinsic_total, @max(0, child_available.width)),
                float_intrinsic_widest,
            ),
        };
        content_width_natural = @max(
            content_width_natural,
            float_intrinsic_width,
        );
    }

    const bottom_collapses = bottom_margin_collapses_with_children and
        !bottom_margin_barrier and
        last_child_bottom != null;
    const bottom_margin_for_height = if (bottom_collapses or bottom_margin_barrier)
        0
    else if (pending_bottom) |bottom_margin|
        bottom_margin.resolve()
    else
        0;
    const normal_bottom = try addFinite(in_flow_bottom, bottom_margin_for_height);
    const auto_content_height = if (container_establishes_bfc)
        @max(
            @max(normal_bottom, float_bottom),
            bfc_state.float_content_contribution,
        )
    else
        normal_bottom;
    return .{
        .size = .{
            .width = content_width_natural,
            .height = @max(0, auto_content_height),
        },
        .margin_collapse = .{
            .top = if (top_margin_collapses_with_children) first_child_top else .{},
            .bottom = if (bottom_collapses) last_child_bottom.? else .{},
            .through = top_margin_collapses_with_children and
                bottom_margin_collapses_with_children and
                all_in_flow_children_collapse_through,
        },
        .bfc = bfc_state,
    };
}

fn naturalAxisDefinite(
    dimension: style.Dimension,
    mode: layout_context.MeasureMode,
    percentage_basis: ?f32,
) bool {
    return switch (dimension) {
        .length => true,
        .percent => percentage_basis != null,
        .auto => mode == .definite,
        .min_content, .max_content, .fit_content => false,
    };
}

fn naturalAxisAvailableDefiniteForRequest(
    dimension: style.Dimension,
    mode: layout_context.MeasureMode,
    percentage_basis: ?f32,
    sizing_mode: layout_context.SizingMode,
    known_border: ?f32,
) bool {
    if (known_border != null) return true;
    if (sizing_mode == .content) return mode == .definite;
    return naturalAxisDefinite(dimension, mode, percentage_basis);
}

fn naturalAxisBasisDefiniteForRequest(
    dimension: style.Dimension,
    percentage_basis: ?f32,
    sizing_mode: layout_context.SizingMode,
    known_border: ?f32,
) bool {
    if (known_border != null) return true;
    if (sizing_mode == .content) return false;
    return switch (dimension) {
        .length => true,
        .percent => percentage_basis != null,
        .auto, .min_content, .max_content, .fit_content => false,
    };
}

fn naturalProvisionalBorder(
    input_style: style.Style,
    context: sizing.SizingContext,
    box_model: sizing.BoxModelResult,
    request: layout_context.Request,
    edges: BoxEdges,
) sizing.Error!widget.Size {
    var provisional_box_model = box_model;
    if (request.sizing_mode == .inherent and
        (request.known_border.width != null or request.known_border.height != null))
    {
        provisional_box_model = try sizing.resolveBoxModel(
            try styleWithKnownBorder(input_style, request.known_border, edges),
            context,
        );
    }
    const width = request.known_border.width orelse
        if (request.sizing_mode == .content)
            request.available.width
        else
            provisional_box_model.border_box.width orelse request.available.width;
    const height = request.known_border.height orelse
        if (request.sizing_mode == .content)
            request.available.height
        else
            provisional_box_model.border_box.height orelse request.available.height;
    return .{
        .width = @max(try finite(width), edges.horizontal),
        .height = @max(try finite(height), edges.vertical),
    };
}

fn naturalRootBoxModelStyle(
    input_style: style.Style,
    request: layout_context.Request,
) style.Style {
    if (request.sizing_mode != .content) return input_style;
    var result = input_style;
    result.size = .{ .width = .auto, .height = .auto };
    result.min_size = .{ .width = .auto, .height = .auto };
    result.max_size = .{ .width = .auto, .height = .auto };
    result.aspect_ratio = null;
    return result;
}

fn dimensionAuto(dimension: style.Dimension) bool {
    return dimension == .auto;
}

fn isIntrinsicDimension(dimension: style.Dimension) bool {
    return switch (dimension) {
        .min_content, .max_content, .fit_content => true,
        .auto, .length, .percent => false,
    };
}

fn measureNaturalLeaf(
    node: *const widget.WidgetNode,
    edges: BoxEdges,
    request: layout_context.Request,
    measure: ?layout_context.MeasureFn,
) sizing.Error!widget.Size {
    const font_size = try finite(node.font_size);
    if (font_size < 0) return error.InvalidStyle;
    const available_border: sizing.AvailableSize = .{
        .width = .{ .definite = try finite(request.available.width) },
        .height = .{ .definite = try finite(request.available.height) },
    };
    const known_dimensions = try measureKnownDimensionsForRequest(
        node.style,
        available_border,
        request,
        edges,
    );
    const available_space: sizing.AvailableSize = .{
        .width = try measureAvailableSpaceForRequest(
            node.style.size.width,
            known_dimensions.width,
            available_border.width,
            edges.horizontal,
            request.width_mode,
            request.sizing_mode,
            request.known_border.width,
        ),
        .height = try measureAvailableSpaceForRequest(
            node.style.size.height,
            known_dimensions.height,
            available_border.height,
            edges.vertical,
            request.height_mode,
            request.sizing_mode,
            request.known_border.height,
        ),
    };
    const measured = try measureLeafContent(
        node,
        measure,
        known_dimensions,
        available_space,
        font_size,
        .{ .width = 0, .height = 0 },
    );
    var result = measured;
    result.width = try finite(result.width);
    result.height = try finite(result.height);
    if (result.width < 0 or result.height < 0) return error.InvalidStyle;
    return result;
}

fn measureLeafContent(
    node: *const widget.WidgetNode,
    measure: ?layout_context.MeasureFn,
    known_dimensions: sizing.OptionalSize,
    available_space: sizing.AvailableSize,
    font_size: f32,
    fallback: widget.Size,
) sizing.Error!widget.Size {
    return switch (node.kind) {
        .label => |label| layout_context.measureText(
            measure,
            label.text,
            .{
                .known_dimensions = known_dimensions,
                .available_space = available_space,
                .font_size = font_size,
                .font_id = node.font_id,
            },
            node.text_overflow,
            node.text_max_width,
        ),
        .spacer => |spacer| .{ .width = spacer.size, .height = spacer.size },
        .button => |button| .{
            .width = if (button.visual_label) |text|
                if (text.len == 0) 100 else @floatFromInt(text.len * 10 + 16)
            else
                100,
            .height = 32,
        },
        .slider => try layout_context.measureSliderContent(measure, node, .{
            .known_dimensions = known_dimensions,
            .available_space = available_space,
            .font_size = font_size,
            .font_id = node.font_id,
        }),
        .row, .column => fallback,
    };
}

fn measureKnownDimensions(
    input_style: style.Style,
    available_space: sizing.AvailableSize,
    percentage_basis: sizing.OptionalSize,
    edges: BoxEdges,
) sizing.Error!sizing.OptionalSize {
    const width = try measureKnownDimension(
        input_style.size.width,
        available_space.width,
        percentage_basis.width,
        edges.box_horizontal,
        edges.horizontal,
        input_style.box_sizing,
    );
    const height = try measureKnownDimension(
        input_style.size.height,
        available_space.height,
        percentage_basis.height,
        edges.box_vertical,
        edges.vertical,
        input_style.box_sizing,
    );
    return .{ .width = width, .height = height };
}

fn measureKnownDimension(
    dimension: style.Dimension,
    available_space: sizing.AvailableSpace,
    percentage_basis: ?f32,
    box_edge_sum: f32,
    content_edge_sum: f32,
    box_sizing: style.BoxSizing,
) sizing.Error!?f32 {
    const sizing_value = switch (dimension) {
        .auto, .min_content, .max_content, .fit_content => return null,
        .length, .percent => try sizing.resolveDimension(
            dimension,
            available_space,
            percentage_basis,
        ),
    } orelse return null;
    if (sizing_value < 0) return error.InvalidStyle;
    const border = switch (box_sizing) {
        .content_box => try addFinite(sizing_value, box_edge_sum),
        .border_box => sizing_value,
    };
    return @max(0, try subtractFinite(border, content_edge_sum));
}

fn measureAvailableSpace(
    dimension: style.Dimension,
    known: ?f32,
    available_space: sizing.AvailableSpace,
    content_edge_sum: f32,
    mode: layout_context.MeasureMode,
) sizing.Error!sizing.AvailableSpace {
    if (known) |value| return .{ .definite = try finite(value) };
    const available_content = switch (available_space) {
        .definite => |value| @max(0, try subtractFinite(value, content_edge_sum)),
        .min_content => 0,
        .max_content => 0,
    };
    return switch (dimension) {
        .min_content => .min_content,
        .max_content => .max_content,
        .fit_content => |limit| switch (available_space) {
            .definite => .{ .definite = if (limit) |value| blk: {
                const checked_limit = try finite(value);
                if (checked_limit < 0) return error.InvalidStyle;
                break :blk @min(available_content, checked_limit);
            } else available_content },
            .min_content => .min_content,
            .max_content => .max_content,
        },
        .auto, .length, .percent => switch (mode) {
            .definite => switch (available_space) {
                .definite => .{ .definite = available_content },
                .min_content => .min_content,
                .max_content => .max_content,
            },
            .min_content => .min_content,
            .max_content => .max_content,
        },
    };
}

fn measureKnownDimensionsForRequest(
    input_style: style.Style,
    available_space: sizing.AvailableSize,
    request: layout_context.Request,
    edges: BoxEdges,
) sizing.Error!sizing.OptionalSize {
    const width = if (request.known_border.width) |border|
        try borderToContentKnownDimension(border, edges.horizontal)
    else if (request.sizing_mode == .content)
        null
    else
        try measureKnownDimension(
            input_style.size.width,
            available_space.width,
            request.percentage_basis.width,
            edges.box_horizontal,
            edges.horizontal,
            input_style.box_sizing,
        );
    const height = if (request.known_border.height) |border|
        try borderToContentKnownDimension(border, edges.vertical)
    else if (request.sizing_mode == .content)
        null
    else
        try measureKnownDimension(
            input_style.size.height,
            available_space.height,
            request.percentage_basis.height,
            edges.box_vertical,
            edges.vertical,
            input_style.box_sizing,
        );
    return .{ .width = width, .height = height };
}

fn borderToContentKnownDimension(border: f32, content_edge_sum: f32) sizing.Error!f32 {
    return @max(0, try subtractFinite(try finite(border), content_edge_sum));
}

fn measureAvailableSpaceForRequest(
    dimension: style.Dimension,
    known: ?f32,
    available_space: sizing.AvailableSpace,
    content_edge_sum: f32,
    mode: layout_context.MeasureMode,
    sizing_mode: layout_context.SizingMode,
    known_border: ?f32,
) sizing.Error!sizing.AvailableSpace {
    if (known_border == null and sizing_mode == .content) {
        return measureAvailableSpace(
            .auto,
            known,
            available_space,
            content_edge_sum,
            mode,
        );
    }
    return measureAvailableSpace(
        dimension,
        known,
        available_space,
        content_edge_sum,
        mode,
    );
}

/// Layout one container through a fresh pass for direct one-container callers.
pub fn layoutContainer(
    tree: *widget.WidgetTree,
    container_id: Id,
    context: sizing.SizingContext,
    measure: ?layout_context.MeasureFn,
) sizing.Error!void {
    try validateContext(context);
    const pass = try LayoutPass.init(tree);
    _ = try layoutPreparedContainerUnchecked(
        pass.tree,
        container_id,
        context,
        measure,
        null,
        null,
        true,
        null,
    );
}

/// Lay out one container after context validation and hidden-state preparation.
fn layoutPreparedContainerUnchecked(
    tree: *widget.WidgetTree,
    container_id: Id,
    context: sizing.SizingContext,
    measure: ?layout_context.MeasureFn,
    forced_border_width: ?f32,
    forced_border_height: ?f32,
    is_layout_root: bool,
    layout_ctx: ?*layout_context.LayoutContext,
) sizing.Error!BlockLayoutResult {
    const container_index = tree.nodeIndex(container_id) orelse return error.InvalidStyle;
    tree.nodes.items[container_index].first_baseline = null;
    if (tree.nodes.items[container_index].layout_hidden) return .{};

    const container_node = &tree.nodes.items[container_index];
    const container_style = container_node.style;
    const parent_is_flex_or_grid = if (tree.nodeConst(container_node.parent)) |parent|
        parent.style.display == .flex or parent.style.display == .grid
    else
        false;
    // Structural roots and explicit BFC styles contain descendant floats.
    // Nested ordinary blocks leave floats to their containing formatting context.
    const container_establishes_bfc = is_layout_root or
        container_node.parent == .root or
        establishesBfc(container_style) or
        (container_style.display == .block and parent_is_flex_or_grid);
    const initial_edges = try resolveBoxEdges(
        container_style,
        context.percentage_basis.width,
    );
    const initial_size = try resolveContainerInitialSize(
        container_style,
        context,
        initial_edges,
    );
    const container_width = if (forced_border_width) |width|
        try finite(width)
    else
        initial_size.border_width;
    // CSS percentages on padding and borders resolve against the final
    // containing block width during the child layout pass. The initial
    // resolution above is only for choosing an auto outer size.
    var container_edges = try resolveBoxEdges(
        container_style,
        @as(?f32, container_width),
    );
    container_edges = try clampScrollbarGutter(
        container_edges,
        container_width,
        forced_border_height orelse initial_size.border_height,
    );
    tree.nodes.items[container_index].resolved_box_edges = .{
        .border = container_edges.border,
        .padding = container_edges.padding,
    };
    tree.nodes.items[container_index].layout_content_size = .{ .width = 0, .height = 0 };
    const content_width = @max(0, container_width - container_edges.horizontal);
    const forced_height = if (forced_border_height) |height| try finite(height) else null;
    const content_height_fixed = if (forced_height) |height|
        @max(0, height - container_edges.vertical)
    else if (initial_size.border_height) |height|
        @max(0, height - container_edges.vertical)
    else
        null;
    const margins_collapse_with_children = container_style.display == .block and
        container_style.position == .relative and
        !container_establishes_bfc and
        content_height_fixed == null;
    const top_margin_collapses_with_children = margins_collapse_with_children and
        container_edges.border.top == 0 and
        container_edges.padding.top == 0;
    const bottom_margin_collapses_with_children = margins_collapse_with_children and
        container_edges.border.bottom == 0 and
        container_edges.padding.bottom == 0;
    const child_context: sizing.SizingContext = .{
        .available = .{
            .width = .{ .definite = content_width },
            .height = if (content_height_fixed) |height|
                .{ .definite = height }
            else
                .max_content,
        },
        .percentage_basis = .{
            .width = content_width,
            .height = content_height_fixed,
        },
    };

    tree.nodes.items[container_index].rect.w = container_width;
    tree.nodes.items[container_index].rect.h = forced_height orelse initial_size.border_height orelse 0;

    const child_ids = tree.nodes.items[container_index].children.items;
    var flow_y: f32 = 0;
    var in_flow_bottom: f32 = 0;
    var float_bottom: f32 = 0;
    var bfc_state: BfcState = .{};
    var float_ceiling: f32 = 0;
    var pending_bottom: ?CollapsibleMarginSet = null;
    var first_child_top: CollapsibleMarginSet = .{};
    var last_child_bottom: ?CollapsibleMarginSet = null;
    var top_collapse_open = top_margin_collapses_with_children;
    var all_in_flow_children_collapse_through = true;
    var bottom_margin_barrier = false;

    for (child_ids, 0..) |child_id, child_index| {
        const child = tree.node(child_id) orelse return error.InvalidStyle;
        child.first_baseline = null;
        if (child.layout_hidden) continue;
        const child_style = child.style;
        float_bottom = @max(
            float_bottom,
            try clearBottom(
                tree,
                child_ids,
                child_index,
                .both,
                container_style.writing_direction,
                child_context.percentage_basis.width,
            ),
        );
        if (child_style.position == .absolute) {
            child.rect.x = inlineStartX(container_style.writing_direction, content_width, 0);
            child.rect.y = flow_y;
            continue;
        }

        const child_edges = try resolveBoxEdges(
            child_style,
            child_context.percentage_basis.width,
        );
        child.resolved_box_edges = .{
            .border = child_edges.border,
            .padding = child_edges.padding,
        };
        var margins = try resolveMargins(
            child_style,
            child_context.percentage_basis.width,
        );
        const float_side = physicalFloat(child_style.float, child_style.writing_direction);
        const child_needs_intrinsic_width = isIntrinsicDimension(child_style.size.width) or
            (float_side != .none and child_style.size.width == .auto);
        const float_shrink_to_fit =
            float_side != .none and child_style.size.width == .auto;
        var intrinsic = if (float_shrink_to_fit)
            try shrinkToFitContentSizeWithContext(
                tree,
                child,
                child_edges,
                measure,
                layout_ctx,
                child_context,
            )
        else
            try intrinsicContentSizeWithContext(
                tree,
                child,
                child_edges,
                measure,
                layout_ctx,
                child_context,
                child_needs_intrinsic_width,
            );
        const clear_y = try clearBottom(
            tree,
            child_ids,
            child_index,
            child_style.clear,
            child_style.writing_direction,
            child_context.percentage_basis.width,
        );
        const child_establishes_bfc = establishesIndependentFormattingContext(child_style);
        const normal_auto_width = child_style.size.width == .auto and
            float_side == .none and
            !child_establishes_bfc;
        const normal_auto_width_border = if (normal_auto_width)
            @max(
                0,
                try subtractFinite(
                    try subtractFinite(content_width, margins.left),
                    margins.right,
                ),
            )
        else
            null;
        const width_is_auto = child_style.size.width == .auto;
        var used_auto_width_border = normal_auto_width_border;
        var child_size = try resolveChildSize(
            child_style,
            child_context,
            intrinsic,
            child_edges,
            used_auto_width_border,
            null,
            false,
        );
        var child_width = child_size.width;
        var child_height = child_size.height;

        if (float_side != .none) {
            const nested_result = try layoutNestedBlockAtWidth(
                tree,
                child_id,
                child_context,
                child_width,
                measure,
                null,
                null,
                layout_ctx,
            );
            if (nested_result != null) {
                intrinsic = if (float_shrink_to_fit)
                    try shrinkToFitContentSizeWithContext(
                        tree,
                        child,
                        child_edges,
                        measure,
                        layout_ctx,
                        child_context,
                    )
                else
                    try intrinsicContentSizeWithContext(
                        tree,
                        child,
                        child_edges,
                        measure,
                        layout_ctx,
                        child_context,
                        child_needs_intrinsic_width,
                    );
                child_size = try resolveChildSize(
                    child_style,
                    child_context,
                    intrinsic,
                    child_edges,
                    used_auto_width_border,
                    null,
                    false,
                );
                child_width = child_size.width;
                child_height = child_size.height;
            }
            const float_width = try addFinite(
                try addFinite(child_width, margins.left),
                margins.right,
            );
            const float_height = try addFinite(
                try addFinite(child_height, margins.top),
                margins.bottom,
            );
            const margin_cursor_y = if (pending_bottom) |bottom_margin|
                try addFinite(flow_y, bottom_margin.resolve())
            else
                flow_y;
            const float_start_y = @max(@max(margin_cursor_y, clear_y), float_ceiling);
            const placement = try findSlot(
                tree,
                child_ids,
                child_index,
                content_width,
                float_width,
                float_height,
                float_start_y,
                float_side,
                child_context.percentage_basis.width,
            );
            child.rect = .{
                .x = try addFinite(placement.x, margins.left),
                .y = try addFinite(placement.y, margins.top),
                .w = child_width,
                .h = child_height,
            };
            try layoutMixedChild(tree, child, layout_ctx, child_context);
            float_ceiling = @max(float_ceiling, placement.y);
            float_bottom = @max(
                float_bottom,
                try addFinite(placement.y, float_height),
            );
            try bfc_state.addFloat(placement.y, float_height);
            continue;
        }

        if (!child_establishes_bfc) {
            try resolveNormalAutoMargins(
                child_style,
                content_width,
                child_width,
                &margins,
            );
        }
        var nested_result: ?BlockLayoutResult = null;
        if (!child_establishes_bfc) {
            nested_result = try layoutNestedBlockAtWidth(
                tree,
                child_id,
                child_context,
                child_width,
                measure,
                null,
                null,
                layout_ctx,
            );
            if (nested_result != null) {
                intrinsic = try intrinsicContentSizeWithContext(
                    tree,
                    child,
                    child_edges,
                    measure,
                    layout_ctx,
                    child_context,
                    child_needs_intrinsic_width,
                );
                child_size = try resolveChildSize(
                    child_style,
                    child_context,
                    intrinsic,
                    child_edges,
                    used_auto_width_border,
                    null,
                    false,
                );
                child_width = child_size.width;
                child_height = child_size.height;
            }
        }
        const child_top_margin = CollapsibleMarginSet.fromMargin(margins.top).collapse(
            if (nested_result) |result| result.margins.top else .{},
        );
        var child_bottom_margin = CollapsibleMarginSet.fromMargin(margins.bottom).collapse(
            if (nested_result) |result| result.margins.bottom else .{},
        );
        var child_collapses_through = if (child_style.aspect_ratio != null)
            false
        else if (nested_result) |result|
            result.margins.through
        else
            child_height == 0 and
                child_edges.vertical == 0 and
                !child_establishes_bfc and
                !hasLineBox(child);

        const hypothetical_margin = if (top_collapse_open and !child_establishes_bfc)
            @as(f32, 0)
        else if (pending_bottom) |bottom_margin|
            bottom_margin.collapse(child_top_margin).resolve()
        else
            child_top_margin.resolve();
        const hypothetical_y = try addFinite(flow_y, hypothetical_margin);
        const forced_clearance = top_collapse_open and clear_y > 0;
        const has_clearance = clear_y > 0 and
            (forced_clearance or hypothetical_y < clear_y);
        const self_collapsing_with_clearance = has_clearance and child_collapses_through;

        if (has_clearance) {
            child_collapses_through = false;
        }

        const effective_start_y = if (has_clearance) clear_y else flow_y;
        const vertical_margin = if (has_clearance)
            if (top_collapse_open and !child_establishes_bfc)
                @as(f32, 0)
            else
                child_top_margin.resolve()
        else
            hypothetical_margin;
        var child_x = inlineStartX(
            container_style.writing_direction,
            content_width,
            child_width,
        );
        var child_y = try addFinite(effective_start_y, vertical_margin);
        if (container_style.writing_direction == .ltr) {
            child_x = try addFinite(child_x, margins.left);
        } else {
            child_x = try subtractFinite(child_x, margins.right);
        }
        if (child_style.position != .absolute and
            float_side == .none and
            !child_establishes_bfc and
            !isAutoMargin(child_style.margin_inset.left) and
            !isAutoMargin(child_style.margin_inset.right))
        {
            const alignment_y = try subtractFinite(child_y, margins.top);
            const alignment_height = try addFinite(
                try addFinite(child_height, margins.top),
                margins.bottom,
            );
            const alignment_slot = try occupiedSlot(
                tree,
                child_ids,
                child_index,
                content_width,
                alignment_y,
                alignment_height,
                child_context.percentage_basis.width,
            );
            if (!alignment_slot.occupied and
                alignment_slot.left == 0 and
                alignment_slot.right == content_width)
            {
                if (try physicalTextAlignX(
                    content_width,
                    child_width,
                    margins,
                    container_style.text_align,
                )) |aligned_x| {
                    child_x = aligned_x;
                }
            }
        }
        if (child_establishes_bfc) {
            const bfc_start_y = try addFinite(
                effective_start_y,
                vertical_margin,
            );
            var placement: BfcPlacement = .{
                .x = 0,
                .y = 0,
                .slot_width = 0,
                .stretch_width = 0,
            };
            var auto_placement: ?BfcAutoPlacement = null;
            if (width_is_auto) {
                var attempt: usize = 0;
                while (attempt <= child_index) : (attempt += 1) {
                    const next_auto = try findAutoBfcPlacement(
                        tree,
                        child_ids,
                        child_index,
                        content_width,
                        child_width,
                        child_height,
                        bfc_start_y,
                        container_style.writing_direction,
                        margins,
                        child_context.percentage_basis.width,
                        attempt != 0,
                    );
                    used_auto_width_border = next_auto.border_width;
                    child_size = try resolveChildSize(
                        child_style,
                        child_context,
                        intrinsic,
                        child_edges,
                        used_auto_width_border,
                        null,
                        false,
                    );
                    child_width = child_size.width;
                    child_height = child_size.height;
                    const stable_slot = if (auto_placement) |previous|
                        next_auto.y == previous.y and
                            next_auto.border_width == previous.border_width and
                            next_auto.slot_width == previous.slot_width
                    else
                        false;
                    auto_placement = next_auto;
                    placement = .{
                        .x = next_auto.x,
                        .y = next_auto.y,
                        .slot_width = next_auto.slot_width,
                        .stretch_width = 0,
                    };
                    if (stable_slot) break;
                }
            } else {
                placement = try findBfcSlot(
                    tree,
                    child_ids,
                    child_index,
                    content_width,
                    child_width,
                    child_height,
                    bfc_start_y,
                    container_style.writing_direction,
                    margins,
                    child_context.percentage_basis.width,
                );
            }
            if (auto_placement) |auto| {
                child_x = if (container_style.writing_direction == .rtl)
                    try addFinite(
                        auto.x,
                        try subtractFinite(auto.border_width, child_width),
                    )
                else
                    auto.x;
                child_y = auto.y;
            } else {
                child_x = placement.x;
                child_y = placement.y;
            }
        }
        if (child_establishes_bfc) {
            nested_result = try layoutNestedBlockAtWidth(
                tree,
                child_id,
                child_context,
                child_width,
                measure,
                null,
                null,
                layout_ctx,
            );
            if (nested_result) |result| {
                intrinsic = try intrinsicContentSizeWithContext(
                    tree,
                    child,
                    child_edges,
                    measure,
                    layout_ctx,
                    child_context,
                    child_needs_intrinsic_width,
                );
                child_size = try resolveChildSize(
                    child_style,
                    child_context,
                    intrinsic,
                    child_edges,
                    used_auto_width_border,
                    null,
                    false,
                );
                child_width = child_size.width;
                child_height = child_size.height;
                child_bottom_margin = CollapsibleMarginSet.fromMargin(margins.bottom).collapse(
                    result.margins.bottom,
                );
                child_collapses_through = result.margins.through;
            }
        }
        var mixed_child_context = child_context;
        if (child_establishes_bfc) {
            const bfc_start_y = try addFinite(
                effective_start_y,
                vertical_margin,
            );
            var final_slot_width = content_width;
            var final_slot_border_width = child_width;
            if (child_style.size.width == .auto) {
                const final_auto = try findAutoBfcPlacement(
                    tree,
                    child_ids,
                    child_index,
                    content_width,
                    child_width,
                    child_height,
                    bfc_start_y,
                    container_style.writing_direction,
                    margins,
                    child_context.percentage_basis.width,
                    true,
                );
                final_slot_width = final_auto.slot_width;
                final_slot_border_width = final_auto.border_width;
                used_auto_width_border = final_slot_border_width;
                const left_auto = isAutoMargin(child_style.margin_inset.left);
                const right_auto = isAutoMargin(child_style.margin_inset.right);
                try resolveStretchAutoMargins(
                    child_style,
                    final_auto.border_width,
                    child_width,
                    &margins,
                );
                child_x = if (container_style.writing_direction == .rtl)
                    if (right_auto)
                        try subtractFinite(final_auto.x, margins.right)
                    else
                        final_auto.x
                else if (left_auto)
                    try addFinite(final_auto.x, margins.left)
                else
                    final_auto.x;
                child_y = final_auto.y;
            } else {
                const final_placement = try findBfcSlot(
                    tree,
                    child_ids,
                    child_index,
                    content_width,
                    child_width,
                    child_height,
                    bfc_start_y,
                    container_style.writing_direction,
                    margins,
                    child_context.percentage_basis.width,
                );
                final_slot_width = final_placement.slot_width;
                final_slot_border_width = child_width;
                const left_auto = isAutoMargin(child_style.margin_inset.left);
                const right_auto = isAutoMargin(child_style.margin_inset.right);
                try resolveStretchAutoMargins(
                    child_style,
                    final_placement.stretch_width,
                    child_width,
                    &margins,
                );
                child_x = if (container_style.writing_direction == .rtl)
                    if (right_auto)
                        try subtractFinite(final_placement.x, margins.right)
                    else
                        final_placement.x
                else if (left_auto)
                    try addFinite(final_placement.x, margins.left)
                else
                    final_placement.x;
                child_y = final_placement.y;
            }
            if (layout_ctx != null and
                child.children.items.len != 0 and
                child_style.display != .block and
                child_style.display != .flow_root)
            {
                if (child_style.size.width == .auto) {
                    used_auto_width_border = final_slot_border_width;
                }
                mixed_child_context.available.width = .{
                    .definite = final_slot_border_width,
                };
                mixed_child_context.percentage_basis.width = @as(?f32, final_slot_border_width);

                intrinsic = try intrinsicContentSizeWithContext(
                    tree,
                    child,
                    child_edges,
                    measure,
                    layout_ctx,
                    mixed_child_context,
                    child_needs_intrinsic_width,
                );
                child_size = try resolveChildSize(
                    child_style,
                    child_context,
                    intrinsic,
                    child_edges,
                    used_auto_width_border,
                    null,
                    false,
                );
                child_width = child_size.width;
                child_height = child_size.height;
            }
            if (child_style.size.width == .auto and
                container_style.writing_direction == .rtl)
            {
                child_x = try addFinite(
                    child_x,
                    try subtractFinite(final_slot_border_width, child_width),
                );
            }
            if (!isAutoMargin(child_style.margin_inset.left) and
                !isAutoMargin(child_style.margin_inset.right) and
                final_slot_width == content_width)
            {
                if (try physicalTextAlignX(
                    content_width,
                    child_width,
                    margins,
                    container_style.text_align,
                )) |aligned_x| {
                    child_x = aligned_x;
                }
            }
        }
        if (child.children.items.len == 0 and child_style.size.height == .auto) {
            child_height = try remeasureLeafAutoHeight(
                tree,
                child,
                child_edges,
                measure,
                layout_ctx,
                child_context,
                child_width,
                child_height,
            );
        }
        if (!child_establishes_bfc) {
            if (nested_result) |result| {
                const resolved_child_edges = child.resolved_box_edges orelse
                    return error.InvalidStyle;
                const child_content_inset_top = try addFinite(
                    resolved_child_edges.border.top,
                    resolved_child_edges.padding.top,
                );
                const child_content_origin_y = try addFinite(
                    child_y,
                    child_content_inset_top,
                );
                try bfc_state.mergeChild(result.bfc, child_content_origin_y);
            }
        }
        child.rect = .{
            .x = child_x,
            .y = child_y,
            .w = child_width,
            .h = child_height,
        };
        try applyRelativeInsets(
            child,
            content_width,
            0,
        );
        try layoutMixedChild(tree, child, layout_ctx, mixed_child_context);
        if (top_collapse_open and !child_establishes_bfc and !has_clearance) {
            first_child_top = first_child_top.collapse(child_top_margin);
            if (child_collapses_through) {
                first_child_top = first_child_top.collapse(child_bottom_margin);
            } else {
                top_collapse_open = false;
            }
        } else if (top_collapse_open) {
            top_collapse_open = false;
        }
        all_in_flow_children_collapse_through = all_in_flow_children_collapse_through and
            child_collapses_through;

        if (self_collapsing_with_clearance) {
            const collapsed_margin = child_top_margin.collapse(child_bottom_margin);
            flow_y = try subtractFinite(child_y, child_top_margin.resolve());
            pending_bottom = collapsed_margin;
            last_child_bottom = collapsed_margin;
            in_flow_bottom = @max(
                in_flow_bottom,
                try addFinite(flow_y, collapsed_margin.resolve()),
            );
            bottom_margin_barrier = true;
        } else if (child_collapses_through) {
            const child_self_collapsed = child_top_margin.collapse(child_bottom_margin);
            const combined_bottom = if (pending_bottom) |prev|
                prev.collapse(child_self_collapsed)
            else
                child_self_collapsed;
            pending_bottom = combined_bottom;
            last_child_bottom = combined_bottom;
        } else {
            flow_y = try addFinite(child_y, child_height);
            pending_bottom = child_bottom_margin;
            last_child_bottom = child_bottom_margin;
            in_flow_bottom = @max(in_flow_bottom, flow_y);
            bottom_margin_barrier = false;
        }
    }
    const bottom_collapses = bottom_margin_collapses_with_children and
        !bottom_margin_barrier and
        last_child_bottom != null;
    const bottom_margin_for_height = if (bottom_collapses or bottom_margin_barrier)
        0
    else if (pending_bottom) |bottom_margin|
        bottom_margin.resolve()
    else
        0;
    const normal_bottom = try addFinite(in_flow_bottom, bottom_margin_for_height);
    const content_height = content_height_fixed orelse blk: {
        const auto_content_height = if (container_establishes_bfc)
            @max(
                @max(normal_bottom, float_bottom),
                bfc_state.float_content_contribution,
            )
        else
            normal_bottom;
        const final_border_height = try resolveContainerAutoHeight(
            container_style,
            context,
            container_edges,
            container_width,
            auto_content_height,
        );
        tree.nodes.items[container_index].rect.h = final_border_height;
        break :blk @max(0, final_border_height - container_edges.vertical);
    };
    try alignBlockChildren(
        tree,
        child_ids,
        content_height,
        normal_bottom,
        container_style.align_content,
    );

    const area_width = @max(
        0,
        try subtractFinite(
            container_width,
            try addFinite(
                try addFinite(container_edges.border.left, container_edges.border.right),
                try addFinite(
                    container_edges.scrollbar_gutter.left,
                    container_edges.scrollbar_gutter.right,
                ),
            ),
        ),
    );
    const container_height = tree.nodes.items[container_index].rect.h;
    const area_height = @max(
        0,
        try subtractFinite(
            container_height,
            try addFinite(
                try addFinite(container_edges.border.top, container_edges.border.bottom),
                try addFinite(
                    container_edges.scrollbar_gutter.top,
                    container_edges.scrollbar_gutter.bottom,
                ),
            ),
        ),
    );
    const area_origin: [2]f32 = .{
        try addFinite(container_edges.border.left, container_edges.scrollbar_gutter.left),
        try addFinite(container_edges.border.top, container_edges.scrollbar_gutter.top),
    };
    const content_origin: [2]f32 = .{
        try addFinite(container_edges.border.left, container_edges.padding.left),
        try addFinite(container_edges.border.top, container_edges.padding.top),
    };

    try layoutAbsoluteChildren(
        tree,
        child_ids,
        area_width,
        area_height,
        area_origin,
        content_origin,
        container_style.writing_direction,
        measure,
        layout_ctx,
    );
    try writeScrollOffset(
        tree,
        container_index,
        child_ids,
        .{ .width = area_width, .height = area_height },
        container_edges,
        container_style.writing_direction,
    );
    try writeFirstBaseline(tree, container_index, child_ids);
    return .{
        .margins = .{
            .top = if (top_margin_collapses_with_children) first_child_top else .{},
            .bottom = if (bottom_collapses) last_child_bottom.? else .{},
            .through = top_margin_collapses_with_children and
                bottom_margin_collapses_with_children and
                all_in_flow_children_collapse_through,
        },
        .bfc = bfc_state,
    };
}

fn alignBlockChildren(
    tree: *widget.WidgetTree,
    child_ids: []const Id,
    content_height: f32,
    in_flow_content_height: f32,
    alignment: style.AlignContent,
) sizing.Error!void {
    const occupied_height = @max(0, try finite(in_flow_content_height));
    const free_height = try subtractFinite(content_height, occupied_height);
    const offset = try resolveBlockContentOffset(alignment, free_height);
    if (offset == 0) return;

    for (child_ids) |child_id| {
        const child = tree.node(child_id) orelse return error.InvalidStyle;
        if (child.layout_hidden or child.style.position == .absolute) continue;
        if (physicalFloat(child.style.float, child.style.writing_direction) != .none) continue;

        child.rect.y = try addFinite(child.rect.y, offset);
    }
}

fn resolveBlockContentOffset(
    alignment: style.AlignContent,
    free_height: f32,
) sizing.Error!f32 {
    const checked_free_height = try finite(free_height);
    const safe_free_height = @max(0, checked_free_height);

    // A block's in-flow contents form one alignment subject, so distributed
    // values use their single-subject fallback and never add child gaps.
    return switch (alignment) {
        .stretch, .start, .flex_start, .space_between => 0,
        .center, .unsafe_center => try finite(checked_free_height / 2),
        .safe_center, .space_around, .space_evenly => try finite(
            safe_free_height / 2,
        ),
        .end, .flex_end, .unsafe_end => checked_free_height,
        .safe_end => safe_free_height,
    };
}

fn layoutNestedBlockAtWidth(
    tree: *widget.WidgetTree,
    child_id: Id,
    parent_context: sizing.SizingContext,
    used_width: f32,
    measure: ?layout_context.MeasureFn,
    forced_border_width: ?f32,
    forced_border_height: ?f32,
    layout_ctx: ?*layout_context.LayoutContext,
) sizing.Error!?BlockLayoutResult {
    const child = tree.node(child_id) orelse return error.InvalidStyle;
    if (child.children.items.len == 0) return null;
    switch (child.style.display) {
        .block, .flow_root => {},
        else => return null,
    }
    const nested_width = try finite(used_width);
    const nested_edges = try resolveBoxEdges(child.style, nested_width);
    const nested_content_width = @max(
        0,
        try subtractFinite(nested_width, nested_edges.horizontal),
    );
    var nested_context = parent_context;
    nested_context.available.width = .{ .definite = nested_width };
    nested_context.percentage_basis.width = nested_content_width;
    const result = try layoutPreparedContainerUnchecked(
        tree,
        child_id,
        nested_context,
        measure,
        forced_border_width,
        forced_border_height,
        false,
        layout_ctx,
    );
    return result;
}

fn validateContext(context: sizing.SizingContext) sizing.Error!void {
    try validateAvailable(context.available.width);
    try validateAvailable(context.available.height);
    try validateOptionalFinite(context.percentage_basis.width);
    try validateOptionalFinite(context.percentage_basis.height);
}

fn validateAvailable(value: sizing.AvailableSpace) sizing.Error!void {
    switch (value) {
        .definite => |number| _ = try finite(number),
        .min_content, .max_content => {},
    }
}

fn validateOptionalFinite(value: ?f32) sizing.Error!void {
    if (value) |number| {
        _ = try finite(number);
    }
}

fn definite(value: sizing.AvailableSpace) sizing.Error!?f32 {
    return switch (value) {
        .definite => |number| try finite(number),
        .min_content, .max_content => null,
    };
}

fn resolveContainerInitialSize(
    input_style: style.Style,
    context: sizing.SizingContext,
    edges: BoxEdges,
) sizing.Error!ContainerInitialSize {
    const box_model = try sizing.resolveBoxModel(input_style, context);
    var candidate: sizing.OptionalSize = switch (input_style.box_sizing) {
        .content_box => box_model.content_box,
        .border_box => box_model.border_box,
    };

    if (candidate.width == null) {
        const auto_width_border = (try definite(context.available.width)) orelse edges.horizontal;
        candidate.width = try borderToSizingValue(
            auto_width_border,
            edges.box_horizontal,
            input_style.box_sizing,
        );
    }
    candidate = try sizing.applyAspectRatio(input_style, candidate);
    const height_is_fixed = candidate.height != null;
    if (candidate.height == null) {
        candidate.height = 0;
    }
    const candidate_width = candidate.width orelse return error.InvalidStyle;
    const candidate_height = candidate.height orelse return error.InvalidStyle;

    const resolved = try sizing.clampSize(
        input_style,
        .{
            .width = candidate_width,
            .height = candidate_height,
        },
        context,
    );
    return .{
        .border_width = @max(0, resolved.width),
        .border_height = if (height_is_fixed) @max(0, resolved.height) else null,
    };
}

fn resolveContainerAutoHeight(
    input_style: style.Style,
    context: sizing.SizingContext,
    edges: BoxEdges,
    border_width: f32,
    content_height: f32,
) sizing.Error!f32 {
    // Reuse the normal sizing clamp, but make its box adjustment use the
    // final-width edge resolution. Dimension percentages still use the
    // containing block supplied by `context`.
    const resolved_style = try styleWithResolvedEdges(input_style, edges);
    const box_model = try sizing.resolveBoxModel(resolved_style, context);
    var candidate: sizing.OptionalSize = switch (input_style.box_sizing) {
        .content_box => box_model.content_box,
        .border_box => box_model.border_box,
    };
    if (candidate.width == null) {
        candidate.width = try borderToSizingValue(
            border_width,
            edges.box_horizontal,
            input_style.box_sizing,
        );
    }
    candidate.height = try borderToSizingValue(
        try addFinite(content_height, edges.vertical),
        edges.box_vertical,
        input_style.box_sizing,
    );
    const candidate_width = candidate.width orelse return error.InvalidStyle;
    const candidate_height = candidate.height orelse return error.InvalidStyle;
    const resolved = try sizing.clampSize(
        resolved_style,
        .{
            .width = candidate_width,
            .height = candidate_height,
        },
        context,
    );
    return @max(0, resolved.height);
}

fn resolveChildSizeForRequest(
    input_style: style.Style,
    context: sizing.SizingContext,
    intrinsic: widget.Size,
    edges: BoxEdges,
    request: layout_context.Request,
) sizing.Error!sizing.ResolvedSize {
    return switch (request.sizing_mode) {
        .content => resolveContentRootSize(intrinsic, edges, request.known_border),
        .inherent => resolveInherentRootSize(
            input_style,
            context,
            intrinsic,
            edges,
            request.known_border,
        ),
    };
}

fn resolveContentRootSize(
    intrinsic: widget.Size,
    edges: BoxEdges,
    known_border: sizing.OptionalSize,
) sizing.Error!sizing.ResolvedSize {
    return .{
        .width = try contentRootAxisSize(known_border.width, intrinsic.width, edges.horizontal),
        .height = try contentRootAxisSize(known_border.height, intrinsic.height, edges.vertical),
    };
}

fn styleWithKnownBorder(
    input_style: style.Style,
    known_border: sizing.OptionalSize,
    edges: BoxEdges,
) sizing.Error!style.Style {
    var result = input_style;
    if (known_border.width) |border| {
        const width = try borderToSizingValue(
            border,
            edges.box_horizontal,
            input_style.box_sizing,
        );
        result.size.width = .{ .length = width };
        result.min_size.width = .auto;
        result.max_size.width = .auto;
    }
    if (known_border.height) |border| {
        const height = try borderToSizingValue(
            border,
            edges.box_vertical,
            input_style.box_sizing,
        );
        result.size.height = .{ .length = height };
        result.min_size.height = .auto;
        result.max_size.height = .auto;
    }
    return result;
}

fn contentRootAxisSize(
    known_border: ?f32,
    intrinsic: f32,
    edge_floor: f32,
) sizing.Error!f32 {
    const candidate = known_border orelse try addFinite(try finite(intrinsic), edge_floor);
    return @max(try finite(candidate), try finite(edge_floor));
}

fn resolveInherentRootSize(
    input_style: style.Style,
    context: sizing.SizingContext,
    intrinsic: widget.Size,
    edges: BoxEdges,
    known_border: sizing.OptionalSize,
) sizing.Error!sizing.ResolvedSize {
    const known_style = try styleWithKnownBorder(input_style, known_border, edges);
    var resolved = try resolveChildSize(
        known_style,
        context,
        intrinsic,
        edges,
        null,
        null,
        false,
    );
    if (known_border.width) |border| {
        resolved.width = @max(try finite(border), edges.horizontal);
    }
    if (known_border.height) |border| {
        resolved.height = @max(try finite(border), edges.vertical);
    }
    return resolved;
}

fn resolveChildSize(
    input_style: style.Style,
    context: sizing.SizingContext,
    intrinsic: widget.Size,
    edges: BoxEdges,
    auto_width_border: ?f32,
    auto_height_border: ?f32,
    full_inset_aspect_ratio: bool,
) sizing.Error!sizing.ResolvedSize {
    const box_model = try sizing.resolveBoxModel(input_style, context);
    var candidate: sizing.OptionalSize = switch (input_style.box_sizing) {
        .content_box => box_model.content_box,
        .border_box => box_model.border_box,
    };

    if (full_inset_aspect_ratio) {
        const width = auto_width_border orelse return error.InvalidStyle;
        candidate.width = try borderToSizingValue(
            width,
            edges.box_horizontal,
            input_style.box_sizing,
        );
        candidate.height = null;
    } else {
        if (candidate.width == null) {
            if (auto_width_border) |width| {
                candidate.width = try borderToSizingValue(
                    width,
                    edges.box_horizontal,
                    input_style.box_sizing,
                );
            }
        }
        if (candidate.height == null) {
            if (auto_height_border) |height| {
                candidate.height = try borderToSizingValue(
                    height,
                    edges.box_vertical,
                    input_style.box_sizing,
                );
            }
        }
    }
    candidate = try sizing.applyAspectRatio(input_style, candidate);
    if (candidate.width == null) {
        var w = intrinsic.width;
        switch (input_style.size.width) {
            .fit_content => |limit_opt| {
                var avail = if (context.available.width == .definite)
                    context.available.width.definite
                else if (context.percentage_basis.width) |pb|
                    pb
                else
                    w;
                if (limit_opt) |lim| avail = @min(avail, lim);
                w = @min(w, avail);
            },
            else => {},
        }
        candidate.width = try contentToSizingValue(
            w,
            edges.horizontal,
            edges.box_horizontal,
            input_style.box_sizing,
        );
    }
    candidate = try sizing.applyAspectRatio(input_style, candidate);
    if (candidate.height == null) {
        candidate.height = try contentToSizingValue(
            intrinsic.height,
            edges.vertical,
            edges.box_vertical,
            input_style.box_sizing,
        );
    }

    const candidate_width = candidate.width orelse return error.InvalidStyle;
    const candidate_height = candidate.height orelse return error.InvalidStyle;
    const resolved = try sizing.clampSize(
        input_style,
        .{
            .width = candidate_width,
            .height = candidate_height,
        },
        context,
    );
    const reclamped = try reclampAspectRatio(
        input_style,
        resolved,
        input_style.position == .absolute and auto_width_border != null,
        input_style.position == .absolute and auto_height_border != null,
        context,
    );
    return .{
        .width = @max(0, reclamped.width),
        .height = @max(0, reclamped.height),
    };
}
fn remeasureLeafAutoHeight(
    tree: *widget.WidgetTree,
    node: *const widget.WidgetNode,
    edges: BoxEdges,
    measure: ?layout_context.MeasureFn,
    layout_ctx: ?*layout_context.LayoutContext,
    containing: sizing.SizingContext,
    border_width: f32,
    border_height: f32,
) sizing.Error!f32 {
    var measurement_context = containing;
    const finite_border_width = try finite(border_width);
    measurement_context.available.width = .{ .definite = finite_border_width };
    const measured = try intrinsicContentSizeWithContextAndAxes(
        tree,
        node,
        edges,
        measure,
        layout_ctx,
        measurement_context,
        false,
        true,
        null,
    );
    const gutter_horizontal = try subtractFinite(
        edges.horizontal,
        edges.box_horizontal,
    );
    const gutter_vertical = try subtractFinite(
        edges.vertical,
        edges.box_vertical,
    );
    const sizing_width = try borderToSizingValue(
        @max(0, try subtractFinite(border_width, gutter_horizontal)),
        edges.box_horizontal,
        node.style.box_sizing,
    );
    const current_height = try borderToSizingValue(
        @max(0, try subtractFinite(border_height, gutter_vertical)),
        edges.box_vertical,
        node.style.box_sizing,
    );
    const measured_height = try borderToSizingValue(
        try addFinite(measured.height, edges.box_vertical),
        edges.box_vertical,
        node.style.box_sizing,
    );
    var clamp_style = node.style;
    if (node.style.max_size.width != .auto) clamp_style.aspect_ratio = null;
    const resolved = try sizing.clampSize(
        clamp_style,
        .{
            .width = sizing_width,
            .height = @max(current_height, measured_height),
        },
        containing,
    );
    return addFinite(resolved.height, gutter_vertical);
}

/// Reapply the aspect ratio after the first constraint clamp makes an auto
/// axis definite, then run both constraints again.
fn reclampAspectRatio(
    input_style: style.Style,
    candidate: sizing.ResolvedSize,
    width_from_inset: bool,
    height_from_inset: bool,
    context: sizing.SizingContext,
) sizing.Error!sizing.ResolvedSize {
    const ratio = input_style.aspect_ratio orelse return candidate;
    const width_auto = input_style.size.width == .auto;
    const height_auto = input_style.size.height == .auto;
    if (!width_auto and !height_auto) return candidate;
    if (width_auto and height_auto and
        input_style.position != .absolute and
        !width_from_inset and
        !height_from_inset)
    {
        return candidate;
    }

    // A paired inset is itself the definite size for that auto axis. Keep it
    // as the anchor rather than replacing it from the other axis. When both
    // axes are intrinsic, the axis that was limited by min/max is the anchor
    // for the transferred size.
    var transferred: sizing.OptionalSize = .{
        .width = candidate.width,
        .height = candidate.height,
    };
    if (height_auto and !height_from_inset) {
        const use_height_anchor = width_auto and
            !width_from_inset and
            try finite(candidate.height * ratio) < candidate.width;
        if (use_height_anchor) {
            transferred = try sizing.applyAspectRatio(input_style, .{
                .width = null,
                .height = candidate.height,
            });
        } else {
            transferred = try sizing.applyAspectRatio(input_style, .{
                .width = candidate.width,
                .height = null,
            });
        }
    } else if (width_auto and !width_from_inset) {
        transferred = try sizing.applyAspectRatio(input_style, .{
            .width = null,
            .height = candidate.height,
        });
    }

    return sizing.clampSize(input_style, .{
        .width = transferred.width orelse candidate.width,
        .height = transferred.height orelse candidate.height,
    }, context);
}

fn contentToSizingValue(
    content: f32,
    content_inset: f32,
    box_adjustment: f32,
    box_sizing: style.BoxSizing,
) sizing.Error!f32 {
    return borderToSizingValue(
        try addFinite(content, content_inset),
        box_adjustment,
        box_sizing,
    );
}

fn borderToSizingValue(
    border: f32,
    box_adjustment: f32,
    box_sizing: style.BoxSizing,
) sizing.Error!f32 {
    const checked_border = try finite(border);
    return switch (box_sizing) {
        .content_box => @max(0, try finite(checked_border - box_adjustment)),
        .border_box => checked_border,
    };
}
fn styleWithResolvedEdges(
    input_style: style.Style,
    edges: BoxEdges,
) sizing.Error!style.Style {
    var resolved = input_style;
    resolved.border_inset = .{
        .top = .{ .length = edges.border.top },
        .right = .{ .length = edges.border.right },
        .bottom = .{ .length = edges.border.bottom },
        .left = .{ .length = edges.border.left },
    };
    resolved.padding_inset = .{
        .top = .{ .length = try subtractFinite(edges.padding.top, edges.scrollbar_gutter.top) },
        .right = .{ .length = try subtractFinite(edges.padding.right, edges.scrollbar_gutter.right) },
        .bottom = .{ .length = try subtractFinite(edges.padding.bottom, edges.scrollbar_gutter.bottom) },
        .left = .{ .length = try subtractFinite(edges.padding.left, edges.scrollbar_gutter.left) },
    };
    return resolved;
}

fn layoutAbsoluteChildren(
    tree: *widget.WidgetTree,
    child_ids: []const Id,
    area_width: f32,
    area_height: f32,
    area_origin: [2]f32,
    content_origin: [2]f32,
    direction: style.Direction,
    measure: ?layout_context.MeasureFn,
    layout_ctx: ?*layout_context.LayoutContext,
) sizing.Error!void {
    const area_to_content_x = try subtractFinite(area_origin[0], content_origin[0]);
    const area_to_content_y = try subtractFinite(area_origin[1], content_origin[1]);
    const absolute_context: sizing.SizingContext = .{
        .available = .{
            .width = .{ .definite = area_width },
            .height = .{ .definite = area_height },
        },
        .percentage_basis = .{
            .width = area_width,
            .height = area_height,
        },
    };

    for (child_ids) |child_id| {
        const child = tree.node(child_id) orelse return error.InvalidStyle;
        if (child.layout_hidden or child.style.position != .absolute) continue;

        const child_style = child.style;
        const static_x = try subtractFinite(child.rect.x, area_to_content_x);
        const static_y = try subtractFinite(child.rect.y, area_to_content_y);
        const child_edges = try resolveBoxEdges(child_style, area_width);
        child.resolved_box_edges = .{
            .border = child_edges.border,
            .padding = child_edges.padding,
        };
        var margins = try resolveMargins(child_style, area_width);
        const left = try resolveInset(child_style.inset.left, area_width);
        const right = try resolveInset(child_style.inset.right, area_width);
        const top = try resolveInset(child_style.inset.top, area_height);
        const bottom = try resolveInset(child_style.inset.bottom, area_height);
        const full_inset_aspect_ratio = child_style.size.width == .auto and
            child_style.size.height == .auto and
            child_style.aspect_ratio != null and
            left != null and
            right != null and
            top != null and
            bottom != null;
        const auto_width_border = if (child_style.size.width == .auto and
            left != null and right != null)
            @max(
                0,
                try subtractFinite(
                    try subtractFinite(
                        try subtractFinite(
                            try subtractFinite(area_width, left.?),
                            right.?,
                        ),
                        margins.left,
                    ),
                    margins.right,
                ),
            )
        else
            null;
        const auto_height_border = if (!full_inset_aspect_ratio and
            child_style.size.height == .auto and top != null and bottom != null)
            @max(
                0,
                try subtractFinite(
                    try subtractFinite(
                        try subtractFinite(
                            try subtractFinite(area_height, top.?),
                            bottom.?,
                        ),
                        margins.top,
                    ),
                    margins.bottom,
                ),
            )
        else
            null;
        const intrinsic_width =
            (child_style.size.width == .auto or isIntrinsicDimension(child_style.size.width)) and
            auto_width_border == null;
        const intrinsic_height =
            (child_style.size.height == .auto or isIntrinsicDimension(child_style.size.height)) and
            auto_height_border == null and
            !full_inset_aspect_ratio;
        const intrinsic = try intrinsicContentSizeWithContextAndAxes(
            tree,
            child,
            child_edges,
            measure,
            layout_ctx,
            absolute_context,
            intrinsic_width,
            intrinsic_height,
            null,
        );
        var child_size = try resolveChildSize(
            child_style,
            absolute_context,
            intrinsic,
            child_edges,
            auto_width_border,
            auto_height_border,
            full_inset_aspect_ratio,
        );
        const used_width = child_size.width;
        if (try layoutNestedBlockAtWidth(
            tree,
            child_id,
            absolute_context,
            used_width,
            measure,
            if (full_inset_aspect_ratio) child_size.width else null,
            if (auto_height_border != null or full_inset_aspect_ratio) child_size.height else null,
            layout_ctx,
        )) |_| {
            child_size = .{
                .width = child.rect.w,
                .height = child.rect.h,
            };
        }
        try resolveAbsoluteAutoMargins(
            child_style,
            area_width,
            area_height,
            child_size,
            left,
            right,
            top,
            bottom,
            &margins,
        );
        const horizontal_insets_auto = left == null and right == null;
        const child_x_area = if (horizontal_insets_auto)
            if (direction == .ltr)
                try addFinite(static_x, margins.left)
            else
                try subtractFinite(
                    try subtractFinite(static_x, child_size.width),
                    margins.right,
                )
        else if (direction == .rtl)
            if (right) |value|
                try subtractFinite(
                    try subtractFinite(
                        try subtractFinite(area_width, value),
                        margins.right,
                    ),
                    child_size.width,
                )
            else blk: {
                const value = left orelse return error.InvalidStyle;
                break :blk try addFinite(value, margins.left);
            }
        else if (left) |value|
            try addFinite(value, margins.left)
        else blk: {
            const value = right orelse return error.InvalidStyle;
            break :blk try subtractFinite(
                try subtractFinite(
                    try subtractFinite(area_width, value),
                    margins.right,
                ),
                child_size.width,
            );
        };
        const child_y_area = if (top) |value|
            try addFinite(value, margins.top)
        else if (bottom) |value|
            try subtractFinite(
                try subtractFinite(
                    try subtractFinite(area_height, value),
                    margins.bottom,
                ),
                child_size.height,
            )
        else
            try addFinite(static_y, margins.top);
        child.rect = .{
            .x = try addFinite(child_x_area, area_to_content_x),
            .y = try addFinite(child_y_area, area_to_content_y),
            .w = child_size.width,
            .h = child_size.height,
        };
        try layoutMixedChild(tree, child, layout_ctx, absolute_context);
    }
}

fn paddingBoxContributionRect(
    rect: widget.Rect,
    client_width: f32,
    raw_padding: style.Sides,
    direction: style.Direction,
) sizing.Error!widget.Rect {
    const physical_x = try addFinite(raw_padding.left, rect.x);
    const physical_right = try addFinite(physical_x, rect.w);
    return .{
        .x = if (direction == .ltr)
            physical_x
        else
            try subtractFinite(client_width, physical_right),
        .y = try addFinite(raw_padding.top, rect.y),
        .w = rect.w,
        .h = rect.h,
    };
}

fn writeScrollOffset(
    tree: *widget.WidgetTree,
    container_index: usize,
    child_ids: []const Id,
    client: widget.Size,
    edges: BoxEdges,
    direction: style.Direction,
) sizing.Error!void {
    const raw_padding: style.Sides = .{
        .top = try subtractFinite(edges.padding.top, edges.scrollbar_gutter.top),
        .right = try subtractFinite(edges.padding.right, edges.scrollbar_gutter.right),
        .bottom = try subtractFinite(edges.padding.bottom, edges.scrollbar_gutter.bottom),
        .left = try subtractFinite(edges.padding.left, edges.scrollbar_gutter.left),
    };
    var inflow_size: widget.Size = .{ .width = 0, .height = 0 };
    var absolute_size: widget.Size = .{ .width = 0, .height = 0 };
    for (child_ids) |child_id| {
        const child = tree.nodeConst(child_id) orelse return error.InvalidStyle;
        if (child.layout_hidden) continue;
        const contribution_rect = try paddingBoxContributionRect(
            child.rect,
            client.width,
            raw_padding,
            direction,
        );
        const contribution = try overflow.contentContribution(
            contribution_rect,
            child.layout_content_size,
            child.style.overflow,
        );
        const target = if (child.style.position == .absolute)
            &absolute_size
        else
            &inflow_size;
        target.width = @max(target.width, contribution.width);
        target.height = @max(target.height, contribution.height);
    }
    const content_with_padding = .{
        .width = try addFinite(
            inflow_size.width,
            if (direction == .ltr) raw_padding.right else raw_padding.left,
        ),
        .height = try addFinite(inflow_size.height, raw_padding.bottom),
    };
    const content_size: widget.Size = .{
        .width = @max(content_with_padding.width, absolute_size.width),
        .height = @max(content_with_padding.height, absolute_size.height),
    };
    tree.nodes.items[container_index].layout_content_size = content_size;

    const scroll = tree.nodes.items[container_index].scroll orelse return;
    scroll.state.max_offset = try overflow.maxOffset(
        content_size,
        client,
        scroll.axis,
    );
}

fn resolveBoxEdges(
    input_style: style.Style,
    percentage_basis: ?f32,
) sizing.Error!BoxEdges {
    const scrollbar_width = try finite(input_style.scrollbar_width);
    if (scrollbar_width < 0) return error.InvalidStyle;
    const scrollbar_gutter = input_style.scrollbarGutter();
    const border: style.Sides = .{
        .top = try resolveEdge(input_style.border_inset.top, percentage_basis),
        .right = try resolveEdge(input_style.border_inset.right, percentage_basis),
        .bottom = try resolveEdge(input_style.border_inset.bottom, percentage_basis),
        .left = try resolveEdge(input_style.border_inset.left, percentage_basis),
    };
    const resolved_padding: style.Sides = .{
        .top = try resolveEdge(input_style.padding_inset.top, percentage_basis),
        .right = try resolveEdge(input_style.padding_inset.right, percentage_basis),
        .bottom = try resolveEdge(input_style.padding_inset.bottom, percentage_basis),
        .left = try resolveEdge(input_style.padding_inset.left, percentage_basis),
    };
    const padding: style.Sides = .{
        .top = try addFinite(resolved_padding.top, scrollbar_gutter.top),
        .right = try addFinite(resolved_padding.right, scrollbar_gutter.right),
        .bottom = try addFinite(resolved_padding.bottom, scrollbar_gutter.bottom),
        .left = try addFinite(resolved_padding.left, scrollbar_gutter.left),
    };
    const box_horizontal = try addFinite(
        try addFinite(border.left, border.right),
        try addFinite(resolved_padding.left, resolved_padding.right),
    );
    const box_vertical = try addFinite(
        try addFinite(border.top, border.bottom),
        try addFinite(resolved_padding.top, resolved_padding.bottom),
    );
    return .{
        .border = border,
        .padding = padding,
        .scrollbar_gutter = scrollbar_gutter,
        .box_horizontal = box_horizontal,
        .box_vertical = box_vertical,
        .horizontal = try addFinite(
            box_horizontal,
            try addFinite(scrollbar_gutter.left, scrollbar_gutter.right),
        ),
        .vertical = try addFinite(
            box_vertical,
            try addFinite(scrollbar_gutter.top, scrollbar_gutter.bottom),
        ),
    };
}
fn clampScrollbarGutter(
    input: BoxEdges,
    border_width: f32,
    border_height: ?f32,
) sizing.Error!BoxEdges {
    var result = input;
    const available_width = @max(
        0,
        try subtractFinite(border_width, input.box_horizontal),
    );
    const available_height = if (border_height) |height|
        @max(
            0,
            try subtractFinite(try finite(height), input.box_vertical),
        )
    else
        null;
    const gutter: style.Sides = .{
        .left = @min(input.scrollbar_gutter.left, available_width),
        .right = @min(input.scrollbar_gutter.right, available_width),
        .top = if (available_height) |height|
            @min(input.scrollbar_gutter.top, height)
        else
            input.scrollbar_gutter.top,
        .bottom = if (available_height) |height|
            @min(input.scrollbar_gutter.bottom, height)
        else
            input.scrollbar_gutter.bottom,
    };
    const base_padding: style.Sides = .{
        .top = try subtractFinite(input.padding.top, input.scrollbar_gutter.top),
        .right = try subtractFinite(input.padding.right, input.scrollbar_gutter.right),
        .bottom = try subtractFinite(input.padding.bottom, input.scrollbar_gutter.bottom),
        .left = try subtractFinite(input.padding.left, input.scrollbar_gutter.left),
    };
    result.scrollbar_gutter = gutter;
    result.padding = .{
        .top = try addFinite(base_padding.top, gutter.top),
        .right = try addFinite(base_padding.right, gutter.right),
        .bottom = try addFinite(base_padding.bottom, gutter.bottom),
        .left = try addFinite(base_padding.left, gutter.left),
    };
    result.horizontal = try addFinite(
        input.box_horizontal,
        try addFinite(gutter.left, gutter.right),
    );
    result.vertical = try addFinite(
        input.box_vertical,
        try addFinite(gutter.top, gutter.bottom),
    );
    return result;
}

fn resolveEdge(
    value: style.LengthPercentage,
    percentage_basis: ?f32,
) sizing.Error!f32 {
    return switch (value) {
        .length => |number| try finite(number),
        .percent => |fraction| blk: {
            const checked_fraction = try finite(fraction);
            const basis = percentage_basis orelse break :blk 0;
            break :blk try finite(checked_fraction * try finite(basis));
        },
    };
}

fn resolveInset(
    value: style.LengthPercentageAuto,
    percentage_basis: ?f32,
) sizing.Error!?f32 {
    return switch (value) {
        .auto => null,
        .length => |number| try finite(number),
        .percent => |fraction| blk: {
            const checked_fraction = try finite(fraction);
            const basis = percentage_basis orelse break :blk null;
            break :blk try finite(checked_fraction * try finite(basis));
        },
    };
}

fn resolveMargins(
    input_style: style.Style,
    percentage_basis: ?f32,
) sizing.Error!style.Sides {
    return .{
        .top = try resolveMargin(input_style.margin_inset.top, percentage_basis),
        .right = try resolveMargin(input_style.margin_inset.right, percentage_basis),
        .bottom = try resolveMargin(input_style.margin_inset.bottom, percentage_basis),
        .left = try resolveMargin(input_style.margin_inset.left, percentage_basis),
    };
}

fn resolveMargin(
    value: style.LengthPercentageAuto,
    percentage_basis: ?f32,
) sizing.Error!f32 {
    return switch (value) {
        .auto => 0,
        .length => |number| try finite(number),
        .percent => |fraction| blk: {
            const checked_fraction = try finite(fraction);
            const basis = percentage_basis orelse break :blk 0;
            break :blk try finite(checked_fraction * try finite(basis));
        },
    };
}

fn isAutoMargin(value: style.LengthPercentageAuto) bool {
    return switch (value) {
        .auto => true,
        else => false,
    };
}

fn resolveNormalAutoMargins(
    input_style: style.Style,
    content_width: f32,
    border_width: f32,
    margins: *style.Sides,
) sizing.Error!void {
    const free_space = @max(
        0,
        try subtractFinite(
            try subtractFinite(
                try subtractFinite(content_width, border_width),
                margins.left,
            ),
            margins.right,
        ),
    );
    distributeAutoMargins(input_style, free_space, margins);
}

fn resolveStretchAutoMargins(
    input_style: style.Style,
    stretch_width: f32,
    border_width: f32,
    margins: *style.Sides,
) sizing.Error!void {
    const free_space = @max(0, try subtractFinite(stretch_width, border_width));
    distributeAutoMargins(input_style, free_space, margins);
}

fn distributeAutoMargins(
    input_style: style.Style,
    free_space: f32,
    margins: *style.Sides,
) void {
    const left_auto = isAutoMargin(input_style.margin_inset.left);
    const right_auto = isAutoMargin(input_style.margin_inset.right);
    const auto_count: u8 = @as(u8, @intFromBool(left_auto)) +
        @as(u8, @intFromBool(right_auto));
    if (auto_count == 0) return;
    const share = free_space / @as(f32, @floatFromInt(auto_count));
    if (left_auto) margins.left = share;
    if (right_auto) margins.right = share;
}

fn resolveAbsoluteAutoMargins(
    input_style: style.Style,
    content_width: f32,
    content_height: f32,
    child_size: sizing.ResolvedSize,
    left: ?f32,
    right: ?f32,
    top: ?f32,
    bottom: ?f32,
    margins: *style.Sides,
) sizing.Error!void {
    try resolveAbsoluteAutoMarginAxis(
        isAutoMargin(input_style.margin_inset.left) and left != null,
        isAutoMargin(input_style.margin_inset.right) and right != null,
        content_width,
        child_size.width,
        left,
        right,
        &margins.left,
        &margins.right,
    );
    try resolveAbsoluteAutoMarginAxis(
        isAutoMargin(input_style.margin_inset.top) and top != null,
        isAutoMargin(input_style.margin_inset.bottom) and bottom != null,
        content_height,
        child_size.height,
        top,
        bottom,
        &margins.top,
        &margins.bottom,
    );
}

fn resolveAbsoluteAutoMarginAxis(
    start_auto: bool,
    end_auto: bool,
    available: f32,
    border_size: f32,
    start_inset: ?f32,
    end_inset: ?f32,
    start_margin: *f32,
    end_margin: *f32,
) sizing.Error!void {
    const auto_count: u8 = @as(u8, @intFromBool(start_auto)) +
        @as(u8, @intFromBool(end_auto));
    if (auto_count == 0) return;

    // An auto margin only participates when its corresponding inset is set.
    // With one inset, the opposite edge is the static-size edge.
    const auto_space = if (end_inset) |value|
        try subtractFinite(
            try subtractFinite(available, value),
            start_inset orelse 0,
        )
    else
        border_size;
    const non_auto_start = if (start_inset != null) start_margin.* else 0;
    const non_auto_end = if (end_inset != null) end_margin.* else 0;
    const free_space = try subtractFinite(
        try subtractFinite(
            try subtractFinite(auto_space, border_size),
            non_auto_start,
        ),
        non_auto_end,
    );
    if (auto_count == 1) {
        if (start_auto) start_margin.* = free_space else end_margin.* = free_space;
    } else if (free_space > 0) {
        const share = free_space / 2;
        start_margin.* = share;
        end_margin.* = share;
    } else {
        start_margin.* = 0;
        end_margin.* = 0;
    }
}

fn applyRelativeInsets(
    node: *widget.WidgetNode,
    horizontal_basis: f32,
    vertical_basis: ?f32,
) sizing.Error!void {
    if (node.style.position != .relative) return;
    const left = try resolveInset(node.style.inset.left, horizontal_basis);
    const right = try resolveInset(node.style.inset.right, horizontal_basis);
    const top = try resolveInset(node.style.inset.top, vertical_basis);
    const bottom = try resolveInset(node.style.inset.bottom, vertical_basis);
    if (node.style.writing_direction == .rtl) {
        if (right) |value| {
            node.rect.x = try subtractFinite(node.rect.x, value);
        } else if (left) |value| {
            node.rect.x = try addFinite(node.rect.x, value);
        }
    } else if (left) |value| {
        node.rect.x = try addFinite(node.rect.x, value);
    } else if (right) |value| {
        node.rect.x = try subtractFinite(node.rect.x, value);
    }
    if (top) |value| {
        node.rect.y = try addFinite(node.rect.y, value);
    } else if (bottom) |value| {
        node.rect.y = try subtractFinite(node.rect.y, value);
    }
}

fn requestFromSizingContext(
    input: sizing.SizingContext,
    intrinsic_width: bool,
    intrinsic_height_override: ?bool,
) sizing.Error!layout_context.Request {
    const width = switch (input.available.width) {
        .definite => |value| try finite(value),
        .min_content, .max_content => return error.InvalidStyle,
    };
    const intrinsic_height = if (intrinsic_height_override) |value| value else switch (input.available.height) {
        .definite => false,
        .min_content, .max_content => true,
    };
    const height = switch (input.available.height) {
        .definite => |value| try finite(value),
        .min_content, .max_content => 0,
    };
    return .{
        .available = .{ .width = width, .height = height },
        .percentage_basis = input.percentage_basis,
        .width_mode = if (intrinsic_width) .max_content else .definite,
        .height_mode = if (intrinsic_height) .max_content else .definite,
        .sizing_mode = .inherent,
        .known_border = .{ .width = null, .height = null },
    };
}

fn rejectPureBlockMixedMeasure(
    _: *layout_context.LayoutContext,
    _: *widget.WidgetTree,
    _: *const widget.WidgetNode,
    _: layout_context.Request,
) layout_context.LayoutError!layout_context.Measured {
    return error.InvalidStyle;
}

fn rejectPureBlockMixedLayout(
    _: *layout_context.LayoutContext,
    _: *widget.WidgetTree,
    _: *widget.WidgetNode,
    _: layout_context.LayoutRequest,
) layout_context.LayoutError!void {
    return error.InvalidStyle;
}
fn intrinsicContentSizeWithContext(
    tree: *widget.WidgetTree,
    node: *const widget.WidgetNode,
    edges: BoxEdges,
    measure: ?layout_context.MeasureFn,
    layout_ctx: ?*layout_context.LayoutContext,
    containing: sizing.SizingContext,
    intrinsic_width: bool,
) sizing.Error!widget.Size {
    return intrinsicContentSizeWithContextAndAxes(
        tree,
        node,
        edges,
        measure,
        layout_ctx,
        containing,
        intrinsic_width,
        null,
        null,
    );
}

fn shrinkToFitContentSizeWithContext(
    tree: *widget.WidgetTree,
    node: *const widget.WidgetNode,
    edges: BoxEdges,
    measure: ?layout_context.MeasureFn,
    layout_ctx: ?*layout_context.LayoutContext,
    containing: sizing.SizingContext,
) sizing.Error!widget.Size {
    return intrinsicContentSizeWithContextAndAxes(
        tree,
        node,
        edges,
        measure,
        layout_ctx,
        containing,
        true,
        null,
        .definite,
    );
}

fn intrinsicContentSizeWithContextAndAxes(
    tree: *widget.WidgetTree,
    node: *const widget.WidgetNode,
    edges: BoxEdges,
    measure: ?layout_context.MeasureFn,
    layout_ctx: ?*layout_context.LayoutContext,
    containing: sizing.SizingContext,
    intrinsic_width: bool,
    intrinsic_height_override: ?bool,
    width_mode_override: ?layout_context.MeasureMode,
) sizing.Error!widget.Size {
    if (node.children.items.len != 0) {
        const block_container =
            node.style.display == .block or node.style.display == .flow_root;
        if (block_container and intrinsic_width) {
            var request = try requestFromSizingContext(
                containing,
                true,
                intrinsic_height_override,
            );
            if (width_mode_override) |mode| request.width_mode = mode;
            return measureNaturalBlockRequest(
                tree,
                node,
                measure,
                layout_ctx,
                request,
            );
        }
        if (!block_container) {
            if (layout_ctx) |context| {
                var request = try requestFromSizingContext(
                    containing,
                    intrinsic_width,
                    null,
                );
                if (width_mode_override) |mode| request.width_mode = mode;
                const measured = try context.measure_node(
                    context,
                    tree,
                    node,
                    request,
                );
                return measured.content;
            }
        }
    }
    const intrinsic_height = if (intrinsic_height_override) |value|
        value
    else switch (containing.available.height) {
        .definite => false,
        .min_content, .max_content => true,
    };
    return intrinsicContentSize(
        node,
        edges,
        measure,
        containing,
        intrinsic_width,
        intrinsic_height,
        width_mode_override,
    );
}

fn intrinsicContentSize(
    node: *const widget.WidgetNode,
    edges: BoxEdges,
    measure: ?layout_context.MeasureFn,
    containing: sizing.SizingContext,
    intrinsic_width: bool,
    intrinsic_height: bool,
    width_mode_override: ?layout_context.MeasureMode,
) sizing.Error!widget.Size {
    const font_size = try finite(node.font_size);
    if (font_size < 0) return error.InvalidStyle;
    const known_dimensions = try measureKnownDimensions(
        node.style,
        containing.available,
        containing.percentage_basis,
        edges,
    );
    const width_mode: layout_context.MeasureMode = if (width_mode_override) |mode|
        mode
    else if (!intrinsic_width)
        .definite
    else switch (containing.available.width) {
        .min_content => .min_content,
        .definite, .max_content => .max_content,
    };
    const height_mode: layout_context.MeasureMode = if (!intrinsic_height)
        .definite
    else switch (containing.available.height) {
        .min_content => .min_content,
        .definite, .max_content => .max_content,
    };
    const available_space: sizing.AvailableSize = .{
        .width = try measureAvailableSpace(
            node.style.size.width,
            known_dimensions.width,
            containing.available.width,
            edges.horizontal,
            width_mode,
        ),
        .height = try measureAvailableSpace(
            node.style.size.height,
            known_dimensions.height,
            containing.available.height,
            edges.vertical,
            height_mode,
        ),
    };
    const measured = try measureLeafContent(
        node,
        measure,
        known_dimensions,
        available_space,
        font_size,
        .{
            .width = @max(0, node.rect.w - edges.horizontal),
            .height = @max(0, node.rect.h - edges.vertical),
        },
    );
    return .{
        .width = @max(0, try finite(measured.width)),
        .height = @max(0, try finite(measured.height)),
    };
}

fn measureNaturalBlockRequest(
    tree: *widget.WidgetTree,
    node: *const widget.WidgetNode,
    measure: ?layout_context.MeasureFn,
    layout_ctx: ?*layout_context.LayoutContext,
    request: layout_context.Request,
) sizing.Error!widget.Size {
    if (layout_ctx) |context| {
        const measured = try context.measure_node(
            context,
            tree,
            node,
            request,
        );
        return measured.content;
    }

    var pure_context: layout_context.LayoutContext = .{
        .allocator = tree.allocator,
        .measure = measure,
        .measure_node = rejectPureBlockMixedMeasure,
        .layout_node = rejectPureBlockMixedLayout,
    };
    defer pure_context.deinit();
    const measured = try measureNatural(
        tree,
        node,
        request,
        &pure_context,
    );
    return measured.content;
}
fn scratchClearBottom(
    floats: []const ScratchFloat,
    clear: style.Clear,
    direction: style.Direction,
) sizing.Error!f32 {
    var state: ClearanceState = .{
        .clear = clear,
        .direction = direction,
    };
    var query: FloatQuery = .{ .clearance = &state };
    for (floats) |float| {
        try visitFloat(&query, float.side, float.outer);
    }
    return state.bottom;
}

fn findScratchSlot(
    floats: []const ScratchFloat,
    container_width: f32,
    child_width: f32,
    child_height: f32,
    start_y: f32,
    side: PhysicalSide,
) sizing.Error!Placement {
    const checked_container_width = try finite(container_width);
    const checked_child_width = try finite(child_width);
    const checked_child_height = try finite(child_height);
    var y = try finite(start_y);
    var attempt: usize = 0;
    while (attempt <= floats.len) : (attempt += 1) {
        const slot = try occupiedScratchSlot(
            floats,
            checked_container_width,
            y,
            checked_child_height,
        );
        const slot_width = @max(0, try subtractFinite(slot.right, slot.left));
        if (!slot.occupied or checked_child_width <= slot_width) {
            const x = if (side == .right)
                try subtractFinite(slot.right, checked_child_width)
            else
                slot.left;
            return .{
                .x = x,
                .y = y,
                .slot_width = slot_width,
            };
        }
        if (!std.math.isFinite(slot.next_y) or slot.next_y <= y) break;
        y = try finite(slot.next_y);
    }
    const x = if (side == .right)
        @max(0, try subtractFinite(checked_container_width, checked_child_width))
    else
        0;
    return .{
        .x = x,
        .y = y,
        .slot_width = checked_container_width,
    };
}
fn findNaturalBfcSlot(
    floats: []const ScratchFloat,
    container_width: f32,
    child_width: f32,
    child_height: f32,
    start_y: f32,
    direction: style.Direction,
    margins: style.Sides,
    auto_width: bool,
) sizing.Error!Placement {
    const checked_container_width = try finite(container_width);
    const checked_child_width = try finite(child_width);
    const checked_child_height = try finite(child_height);
    const margin_sum = try addFinite(margins.left, margins.right);
    const min_auto_width = @max(0, -margin_sum);
    var y = try finite(start_y);
    var attempt: usize = 0;
    while (attempt <= floats.len) : (attempt += 1) {
        const slot = try occupiedScratchSlot(
            floats,
            checked_container_width,
            y,
            checked_child_height,
        );
        const geometry = try bfcSlotGeometry(
            slot,
            checked_container_width,
            direction,
            margins,
        );
        const candidate_width = if (auto_width)
            @max(geometry.stretch_width, min_auto_width)
        else
            checked_child_width;
        if ((!slot.occupied or geometry.width > 0) and
            candidate_width <= geometry.width)
        {
            return .{
                .x = try bfcPlacementX(
                    geometry,
                    candidate_width,
                    direction,
                ),
                .y = y,
                .slot_width = geometry.width,
            };
        }
        if (!std.math.isFinite(slot.next_y) or slot.next_y <= y) break;
        y = try finite(slot.next_y);
    }
    const fallback_width = if (auto_width)
        @max(
            try subtractFinite(
                try subtractFinite(checked_container_width, margins.left),
                margins.right,
            ),
            min_auto_width,
        )
    else
        checked_child_width;
    return .{
        .x = if (direction == .rtl)
            try subtractFinite(
                try subtractFinite(checked_container_width, margins.right),
                fallback_width,
            )
        else
            margins.left,
        .y = y,
        .slot_width = checked_container_width,
    };
}

fn occupiedScratchSlot(
    floats: []const ScratchFloat,
    container_width: f32,
    candidate_y: f32,
    candidate_height: f32,
) sizing.Error!Slot {
    var result: Slot = .{
        .left = 0,
        .right = try finite(container_width),
        .next_y = std.math.inf(f32),
        .occupied = false,
    };
    var state: OccupiedState = .{
        .slot = &result,
        .candidate_y = try finite(candidate_y),
        .candidate_height = try finite(candidate_height),
    };
    var query: FloatQuery = .{ .slot = &state };
    for (floats) |float| {
        try visitFloat(&query, float.side, float.outer);
    }
    return result;
}

fn scratchFloatRunWidth(
    floats: []const ScratchFloat,
    candidate_y: f32,
) sizing.Error!f32 {
    const checked_y = try finite(candidate_y);
    var result: f32 = 0;
    for (floats) |float| {
        const top = try finite(float.outer.y);
        const height = try finite(float.outer.h);
        const bottom = try addFinite(top, height);
        const active = if (height == 0)
            top == checked_y
        else
            checked_y >= top and checked_y < bottom;

        if (active) {
            result = try addFinite(result, float.intrinsic_width);
        }
    }
    return result;
}

fn layoutMixedChild(
    tree: *widget.WidgetTree,
    child: *widget.WidgetNode,
    layout_ctx: ?*layout_context.LayoutContext,
    containing: sizing.SizingContext,
) sizing.Error!void {
    const context = layout_ctx orelse return;
    if (child.children.items.len != 0 and
        (child.style.display == .block or child.style.display == .flow_root))
    {
        return;
    }
    const request = try requestFromSizingContext(
        containing,
        false,
        null,
    );
    try context.layout_node(
        context,
        tree,
        child,
        .{
            .available = request.available,
            .percentage_basis = request.percentage_basis,
            .border = .{ .width = child.rect.w, .height = child.rect.h },
        },
    );
}

fn establishesBfc(input_style: style.Style) bool {
    if (input_style.display == .flow_root) return true;
    if (input_style.position == .absolute) return true;
    if (input_style.float != .none) return true;
    return input_style.overflow.width == .hidden or
        input_style.overflow.width == .scroll or
        input_style.overflow.width == .auto or
        input_style.overflow.height == .hidden or
        input_style.overflow.height == .scroll or
        input_style.overflow.height == .auto;
}

fn establishesIndependentFormattingContext(input_style: style.Style) bool {
    if (input_style.display == .flex or input_style.display == .grid) return true;
    return establishesBfc(input_style);
}

fn physicalTextAlignX(
    container_width: f32,
    child_width: f32,
    margins: style.Sides,
    text_align: style.TextAlign,
) sizing.Error!?f32 {
    const free_space = @max(
        0,
        try subtractFinite(
            try subtractFinite(container_width, child_width),
            try addFinite(margins.left, margins.right),
        ),
    );
    return switch (text_align) {
        .start => null,
        .left => margins.left,
        .center => try addFinite(margins.left, free_space / 2),
        .right => try addFinite(margins.left, free_space),
    };
}
fn hasLineBox(node: *const widget.WidgetNode) bool {
    return switch (node.kind) {
        .label => |label| label.text.len != 0,
        else => false,
    };
}

fn writeFirstBaseline(
    tree: *widget.WidgetTree,
    container_index: usize,
    child_ids: []const Id,
) sizing.Error!void {
    var baseline: ?f32 = null;
    for (child_ids) |child_id| {
        const child = tree.nodeConst(child_id) orelse return error.InvalidStyle;
        if (child.layout_hidden or
            child.style.display == .none or
            child.style.position == .absolute or
            physicalFloat(child.style.float, child.style.writing_direction) != .none)
        {
            continue;
        }
        if (child.first_baseline) |child_baseline| {
            baseline = try addFinite(child.rect.y, child_baseline);
            break;
        }
    }
    tree.nodes.items[container_index].first_baseline = baseline;
}

fn inlineStartX(direction: style.Direction, content_width: f32, child_width: f32) f32 {
    return if (direction == .ltr)
        0
    else
        content_width - child_width;
}

/// Recompute hidden state once per node. Reverse post-order visits each parent
/// after all of its children, so a parent marker is ready for every child.
fn classifyHiddenLayout(tree: *widget.WidgetTree) sizing.Error!void {
    var node_index = tree.nodes.items.len;
    while (node_index > 0) {
        node_index -= 1;
        const node = &tree.nodes.items[node_index];
        var hidden = node.style.display == .none;

        if (node.parent != .root) {
            const parent_index = tree.nodeIndex(node.parent) orelse return error.InvalidStyle;
            if (parent_index <= node_index) return error.InvalidStyle;
            hidden = hidden or tree.nodes.items[parent_index].layout_hidden;
        }

        node.layout_hidden = hidden;
        if (!hidden) continue;
        node.first_baseline = null;
        node.rect = .{};
        node.resolved_box_edges = null;
        node.layout_content_size = .{ .width = 0, .height = 0 };
    }
}

fn physicalFloat(value: style.Float, direction: style.Direction) PhysicalSide {
    return switch (value) {
        .none => .none,
        .left => .left,
        .right => .right,
        .inline_start => if (direction == .ltr) .left else .right,
        .inline_end => if (direction == .ltr) .right else .left,
    };
}

fn clearBottom(
    tree: *const widget.WidgetTree,
    child_ids: []const Id,
    prior_count: usize,
    clear: style.Clear,
    direction: style.Direction,
    percentage_basis: ?f32,
) sizing.Error!f32 {
    var state: ClearanceState = .{
        .clear = clear,
        .direction = direction,
    };
    var query: FloatQuery = .{ .clearance = &state };
    try walkPriorFloats(
        tree,
        child_ids,
        prior_count,
        percentage_basis,
        &query,
    );
    return state.bottom;
}
fn walkPriorFloats(
    tree: *const widget.WidgetTree,
    child_ids: []const Id,
    prior_count: usize,
    percentage_basis: ?f32,
    query: *FloatQuery,
) sizing.Error!void {
    if (prior_count > child_ids.len) return error.InvalidStyle;
    const depth = tree.nodes.items.len;
    for (child_ids[0..prior_count]) |child_id| {
        try walkFloatSubtree(
            tree,
            child_id,
            0,
            0,
            percentage_basis,
            query,
            depth,
        );
    }
}

fn walkFloatSubtree(
    tree: *const widget.WidgetTree,
    node_id: Id,
    parent_origin_x: f32,
    parent_origin_y: f32,
    percentage_basis: ?f32,
    query: *FloatQuery,
    depth: usize,
) sizing.Error!void {
    if (depth == 0) return error.InvalidStyle;
    const node = tree.nodeConst(node_id) orelse return error.InvalidStyle;
    if (node.layout_hidden or node.style.position == .absolute) return;

    const node_x = try addFinite(parent_origin_x, node.rect.x);
    const node_y = try addFinite(parent_origin_y, node.rect.y);
    const side = physicalFloat(node.style.float, node.style.writing_direction);
    if (side != .none) {
        const margins = try resolveMargins(node.style, percentage_basis);
        const outer: widget.Rect = .{
            .x = try subtractFinite(node_x, margins.left),
            .y = try subtractFinite(node_y, margins.top),
            .w = try addFinite(
                try addFinite(node.rect.w, margins.left),
                margins.right,
            ),
            .h = try addFinite(
                try addFinite(node.rect.h, margins.top),
                margins.bottom,
            ),
        };
        try visitFloat(query, side, outer);
        return;
    }

    if (floatTraversalBoundary(node.style)) return;
    const edges = try resolveBoxEdges(node.style, percentage_basis);
    const content_origin_x = try addFinite(
        node_x,
        try addFinite(edges.border.left, edges.padding.left),
    );
    const content_origin_y = try addFinite(
        node_y,
        try addFinite(edges.border.top, edges.padding.top),
    );
    const content_width = @max(
        0,
        try subtractFinite(node.rect.w, edges.horizontal),
    );
    for (node.children.items) |child_id| {
        try walkFloatSubtree(
            tree,
            child_id,
            content_origin_x,
            content_origin_y,
            @as(?f32, content_width),
            query,
            depth - 1,
        );
    }
}

fn floatTraversalBoundary(input_style: style.Style) bool {
    if (establishesBfc(input_style)) return true;
    return input_style.display == .flex or input_style.display == .grid;
}

fn visitFloat(
    query: *FloatQuery,
    side: PhysicalSide,
    outer: widget.Rect,
) sizing.Error!void {
    switch (query.*) {
        .slot => |state| {
            if (!verticalOverlap(outer, state.candidate_y, state.candidate_height)) return;
            state.slot.occupied = true;
            if (side == .left) {
                state.slot.has_float[0] = true;
                state.slot.left = @max(state.slot.left, try addFinite(outer.x, outer.w));
            } else {
                state.slot.has_float[1] = true;
                state.slot.right = @min(state.slot.right, outer.x);
            }
            state.slot.next_y = @min(state.slot.next_y, try addFinite(outer.y, outer.h));
        },
        .clearance => |state| {
            if (!clears(state.clear, state.direction, side)) return;
            state.bottom = @max(state.bottom, try addFinite(outer.y, outer.h));
        },
    }
}

fn clears(clear: style.Clear, direction: style.Direction, side: PhysicalSide) bool {
    if (side == .none) return false;
    return switch (clear) {
        .none => false,
        .both => true,
        .left => side == .left,
        .right => side == .right,
        .inline_start => blk: {
            const clear_side: PhysicalSide = if (direction == .ltr) .left else .right;
            break :blk side == clear_side;
        },
        .inline_end => blk: {
            const clear_side: PhysicalSide = if (direction == .ltr) .right else .left;
            break :blk side == clear_side;
        },
    };
}

const BfcSlotGeometry = struct {
    left: f32,
    right: f32,
    width: f32,
    stretch_width: f32,
};

fn bfcSlotGeometry(
    slot: Slot,
    container_width: f32,
    direction: style.Direction,
    margins: style.Sides,
) sizing.Error!BfcSlotGeometry {
    const checked_container_width = try finite(container_width);
    const float_left = try finite(slot.left);
    const float_right = try subtractFinite(checked_container_width, slot.right);
    const lead: usize = if (direction == .ltr) 0 else 1;
    const trail = 1 - lead;
    const margin_insets = [_]f32{ margins.left, margins.right };
    const has_lead_float = slot.has_float[lead];
    const has_trail_float = slot.has_float[trail];
    var fit_insets = [_]f32{ 0, 0 };
    var stretch_insets = [_]f32{ 0, 0 };
    fit_insets[lead] = if (has_lead_float)
        @max(if (lead == 0) float_left else float_right, margin_insets[lead])
    else
        margin_insets[lead];
    stretch_insets[lead] = fit_insets[lead];
    fit_insets[trail] = if (has_trail_float)
        @max(if (trail == 0) float_left else float_right, 0)
    else
        @min(margin_insets[trail], 0);
    stretch_insets[trail] = if (has_trail_float)
        @max(if (trail == 0) float_left else float_right, margin_insets[trail])
    else
        margin_insets[trail];
    const right = try subtractFinite(checked_container_width, fit_insets[1]);
    return .{
        .left = fit_insets[0],
        .right = right,
        .width = try subtractFinite(right, fit_insets[0]),
        .stretch_width = try subtractFinite(
            try subtractFinite(checked_container_width, stretch_insets[0]),
            stretch_insets[1],
        ),
    };
}

fn bfcPlacementX(
    geometry: BfcSlotGeometry,
    border_width: f32,
    direction: style.Direction,
) sizing.Error!f32 {
    return if (direction == .rtl)
        try subtractFinite(geometry.right, border_width)
    else
        geometry.left;
}

fn findAutoBfcPlacement(
    tree: *const widget.WidgetTree,
    child_ids: []const Id,
    prior_count: usize,
    container_width: f32,
    candidate_border_width: f32,
    child_height: f32,
    start_y: f32,
    direction: style.Direction,
    margins: style.Sides,
    percentage_basis: ?f32,
    enforce_candidate_fit: bool,
) sizing.Error!BfcAutoPlacement {
    const checked_candidate_width = try finite(candidate_border_width);
    const margin_sum = try addFinite(margins.left, margins.right);
    const min_auto_width = @max(0, -margin_sum);
    const candidate_for_fit = @max(checked_candidate_width, min_auto_width);
    var y = try finite(start_y);
    var attempt: usize = 0;
    while (attempt <= tree.nodes.items.len) : (attempt += 1) {
        const slot = try occupiedSlot(
            tree,
            child_ids,
            prior_count,
            container_width,
            y,
            child_height,
            percentage_basis,
        );
        const geometry = try bfcSlotGeometry(slot, container_width, direction, margins);
        if ((!enforce_candidate_fit or candidate_for_fit <= geometry.width) and
            (!slot.occupied or geometry.width > 0))
        {
            const border_width = @max(geometry.stretch_width, min_auto_width);
            return .{
                .x = try bfcPlacementX(geometry, border_width, direction),
                .y = y,
                .border_width = border_width,
                .slot_width = geometry.width,
            };
        }
        if (!std.math.isFinite(slot.next_y) or slot.next_y <= y) break;
        y = try finite(slot.next_y);
    }

    const border_width = try autoBorderWidth(container_width, margins);
    return .{
        .x = try autoBorderX(
            container_width,
            border_width,
            margins,
            direction,
        ),
        .y = y,
        .border_width = border_width,
        .slot_width = container_width,
    };
}

fn findBfcSlot(
    tree: *const widget.WidgetTree,
    child_ids: []const Id,
    prior_count: usize,
    container_width: f32,
    child_width: f32,
    child_height: f32,
    start_y: f32,
    direction: style.Direction,
    margins: style.Sides,
    percentage_basis: ?f32,
) sizing.Error!BfcPlacement {
    const checked_width = try finite(child_width);
    var y = try finite(start_y);
    var attempt: usize = 0;
    while (attempt <= tree.nodes.items.len) : (attempt += 1) {
        const slot = try occupiedSlot(
            tree,
            child_ids,
            prior_count,
            container_width,
            y,
            child_height,
            percentage_basis,
        );
        const geometry = try bfcSlotGeometry(slot, container_width, direction, margins);
        if ((!slot.occupied or geometry.width > 0) and checked_width <= geometry.width) {
            return .{
                .x = try bfcPlacementX(geometry, checked_width, direction),
                .y = y,
                .slot_width = geometry.width,
                .stretch_width = geometry.stretch_width,
            };
        }
        if (!std.math.isFinite(slot.next_y) or slot.next_y <= y) break;
        y = try finite(slot.next_y);
    }
    return .{
        .x = if (direction == .rtl)
            try subtractFinite(
                try subtractFinite(container_width, margins.right),
                checked_width,
            )
        else
            margins.left,
        .y = y,
        .slot_width = container_width,
        .stretch_width = try subtractFinite(
            try subtractFinite(container_width, margins.left),
            margins.right,
        ),
    };
}

fn autoBorderWidth(container_width: f32, margins: style.Sides) sizing.Error!f32 {
    return @max(
        0,
        try subtractFinite(
            try subtractFinite(container_width, margins.left),
            margins.right,
        ),
    );
}

fn autoBorderX(
    container_width: f32,
    border_width: f32,
    margins: style.Sides,
    direction: style.Direction,
) sizing.Error!f32 {
    return if (direction == .ltr)
        try finite(margins.left)
    else
        try subtractFinite(
            try subtractFinite(container_width, margins.right),
            border_width,
        );
}

fn findSlot(
    tree: *const widget.WidgetTree,
    child_ids: []const Id,
    prior_count: usize,
    container_width: f32,
    child_width: f32,
    child_height: f32,
    start_y: f32,
    side: PhysicalSide,
    percentage_basis: ?f32,
) sizing.Error!Placement {
    var y = start_y;
    var attempt: usize = 0;
    while (attempt <= tree.nodes.items.len) : (attempt += 1) {
        const slot = try occupiedSlot(
            tree,
            child_ids,
            prior_count,
            container_width,
            y,
            child_height,
            percentage_basis,
        );
        const slot_width = @max(0, slot.right - slot.left);
        if (!slot.occupied or child_width <= slot_width) {
            const x = if (side == .right) slot.right - child_width else slot.left;
            return .{ .x = x, .y = y, .slot_width = slot_width };
        }
        if (!std.math.isFinite(slot.next_y) or slot.next_y <= y) break;
        y = slot.next_y;
    }

    const x = if (side == .right) @max(0, container_width - child_width) else 0;
    return .{ .x = x, .y = y, .slot_width = container_width };
}

fn occupiedSlot(
    tree: *const widget.WidgetTree,
    child_ids: []const Id,
    prior_count: usize,
    container_width: f32,
    candidate_y: f32,
    candidate_height: f32,
    percentage_basis: ?f32,
) sizing.Error!Slot {
    var result: Slot = .{
        .left = 0,
        .right = container_width,
        .next_y = std.math.inf(f32),
        .occupied = false,
    };
    var state: OccupiedState = .{
        .slot = &result,
        .candidate_y = candidate_y,
        .candidate_height = candidate_height,
    };
    var query: FloatQuery = .{ .slot = &state };
    try walkPriorFloats(
        tree,
        child_ids,
        prior_count,
        percentage_basis,
        &query,
    );
    return result;
}

fn verticalOverlap(rect: widget.Rect, candidate_y: f32, candidate_height: f32) bool {
    const rect_bottom = rect.y + rect.h;
    if (candidate_height == 0) return rect.y <= candidate_y and candidate_y < rect_bottom;
    return rect.y < candidate_y + candidate_height and candidate_y < rect_bottom;
}

fn subtractFinite(lhs: f32, rhs: f32) sizing.Error!f32 {
    return finite(lhs - rhs);
}

fn addFinite(lhs: f32, rhs: f32) sizing.Error!f32 {
    return finite(lhs + rhs);
}

fn finite(value: f32) sizing.Error!f32 {
    if (!std.math.isFinite(value)) return error.InvalidStyle;
    return value;
}
