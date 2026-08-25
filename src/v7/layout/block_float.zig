const std = @import("std");
const Id = @import("../id.zig").Id;
const layout_context = @import("context.zig");
const style = @import("../style.zig");
const sizing = @import("sizing.zig");
const widget = @import("../widget.zig");

const PhysicalSide = enum { none, left, right };

const BoxEdges = struct {
    border: style.Sides,
    padding: style.Sides,
    box_horizontal: f32,
    box_vertical: f32,
    horizontal: f32,
    vertical: f32,
};
const Natural = struct {
    content: widget.Size,
    border: widget.Size,
};

const Slot = struct {
    left: f32,
    right: f32,
    next_y: f32,
    occupied: bool,
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
    const natural = try measureNaturalNode(
        tree,
        index,
        request,
        context,
        tree.nodes.items.len,
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
) sizing.Error!Natural {
    if (depth == 0 or index >= tree.nodes.items.len) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    if (node.layout_hidden or node.style.display == .none) return .{
        .content = .{ .width = 0, .height = 0 },
        .border = .{ .width = 0, .height = 0 },
    };

    const edges = try resolveBoxEdges(node.style, request.percentage_basis.width);
    const content = if (node.children.items.len == 0)
        try measureNaturalLeaf(node, context.measure)
    else switch (node.style.display) {
        .block, .flow_root => try measureNaturalBlockContent(
            tree,
            index,
            request,
            edges,
            context,
            depth - 1,
        ),
        .flex, .grid => return error.InvalidStyle,
        .none => unreachable,
    };
    const sizing_context: sizing.SizingContext = .{
        .available = .{
            .width = .{ .definite = request.available.width },
            .height = .{ .definite = request.available.height },
        },
        .percentage_basis = request.percentage_basis,
    };
    const resolved = try resolveChildSize(
        node.style,
        sizing_context,
        content,
        edges,
        null,
        null,
    );
    return .{
        .content = content,
        .border = .{ .width = resolved.width, .height = resolved.height },
    };
}

fn measureNaturalBlockContent(
    tree: *widget.WidgetTree,
    index: usize,
    request: layout_context.Request,
    edges: BoxEdges,
    context: *layout_context.LayoutContext,
    depth: usize,
) sizing.Error!widget.Size {
    if (depth == 0) return error.InvalidStyle;
    const node = &tree.nodes.items[index];
    const sizing_context: sizing.SizingContext = .{
        .available = .{
            .width = .{ .definite = request.available.width },
            .height = .{ .definite = request.available.height },
        },
        .percentage_basis = request.percentage_basis,
    };
    const box_model = try sizing.resolveBoxModel(
        styleForSizing(node.style),
        sizing_context,
    );
    const provisional_border: widget.Size = .{
        .width = box_model.border_box.width orelse request.available.width,
        .height = box_model.border_box.height orelse request.available.height,
    };
    const child_available: widget.Size = .{
        .width = @max(0, try subtractFinite(provisional_border.width, edges.horizontal)),
        .height = @max(0, try subtractFinite(provisional_border.height, edges.vertical)),
    };
    const width_definite = naturalAxisDefinite(
        node.style.size.width,
        request.intrinsic_width,
        request.percentage_basis.width,
    );
    const height_definite = naturalAxisDefinite(
        node.style.size.height,
        request.intrinsic_height,
        request.percentage_basis.height,
    );
    var content_height: f32 = 0;
    var content_width_natural: f32 = 0;
    for (node.children.items) |child_id| {
        const child = tree.nodeConst(child_id) orelse return error.InvalidStyle;
        if (child.layout_hidden or child.style.position == .absolute) continue;
        const child_index = tree.nodeIndex(child_id) orelse return error.InvalidStyle;
        const child_request: layout_context.Request = .{
            .available = child_available,
            .percentage_basis = .{
                .width = if (width_definite)
                    @as(?f32, child_available.width)
                else
                    request.percentage_basis.width,
                .height = if (height_definite) @as(?f32, child_available.height) else null,
            },
            .intrinsic_width = !width_definite and
                (dimensionAuto(child.style.size.width) or isIntrinsicDimension(child.style.size.width)),
            .intrinsic_height = !height_definite and
                (dimensionAuto(child.style.size.height) or isIntrinsicDimension(child.style.size.height)),
        };
        const natural = if (child.children.items.len == 0 or
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
            );
        } else switch (child.style.display) {
            .flex, .grid => blk: {
                const measured = try context.measure_node(
                    context,
                    tree,
                    child,
                    child_request,
                );
                break :blk Natural{
                    .content = measured.content,
                    .border = measured.border,
                };
            },
            .none => Natural{
                .content = .{ .width = 0, .height = 0 },
                .border = .{ .width = 0, .height = 0 },
            },
            .block, .flow_root => unreachable,
        };
        const margins = try resolveMargins(child.style, child_request.percentage_basis.width);
        const intrinsic_margin_left = try resolveMargin(
            child.style.margin_inset.left,
            child.style.margin.left,
            null,
        );
        const intrinsic_margin_right = try resolveMargin(
            child.style.margin_inset.right,
            child.style.margin.right,
            null,
        );
        content_width_natural = @max(
            content_width_natural,
            try addFinite(
                try addFinite(natural.border.width, intrinsic_margin_left),
                intrinsic_margin_right,
            ),
        );
        content_height = try addFinite(
            content_height,
            try addFinite(
                try addFinite(natural.border.height, margins.top),
                margins.bottom,
            ),
        );
    }
    return .{
        .width = content_width_natural,
        .height = content_height,
    };
}

fn naturalAxisDefinite(
    dimension: style.Dimension,
    intrinsic: bool,
    percentage_basis: ?f32,
) bool {
    return switch (dimension) {
        .length => true,
        .percent => percentage_basis != null,
        .auto => !intrinsic,
        .min_content, .max_content, .fit_content => false,
    };
}

fn dimensionAuto(dimension: style.Dimension) bool {
    return switch (dimension) {
        .auto => true,
        .length, .percent, .min_content, .max_content, .fit_content => false,
    };
}

fn isIntrinsicDimension(dimension: style.Dimension) bool {
    return switch (dimension) {
        .min_content, .max_content, .fit_content => true,
        .auto, .length, .percent => false,
    };
}

fn measureNaturalLeaf(
    node: *const widget.WidgetNode,
    measure: ?layout_context.MeasureFn,
) sizing.Error!widget.Size {
    var result: widget.Size = switch (node.kind) {
        .label => |label| if (measure) |callback|
            callback(label.text, node.font_size, node.font_id)
        else blk: {
            const font_size = try finite(node.font_size);
            if (font_size < 0) return error.InvalidStyle;
            const scale: f32 = if (font_size > 0) font_size / 20 else 1;
            const length: f32 = @floatFromInt(@min(label.text.len, 1 << 24));
            break :blk .{ .width = length * 10 * scale, .height = 20 * scale };
        },
        .spacer => |spacer| .{ .width = spacer.size, .height = spacer.size },
        .button => |button| .{
            .width = if (button.visual_label) |text|
                if (text.len == 0) 100 else @floatFromInt(text.len * 10 + 16)
            else
                100,
            .height = 32,
        },
        .slider => .{ .width = 100, .height = widget.slider_rail_height },
        .row, .column => .{ .width = 0, .height = 0 },
    };
    result.width = try finite(result.width);
    result.height = try finite(result.height);
    if (result.width < 0 or result.height < 0) return error.InvalidStyle;
    if (node.text_max_width) |maximum| {
        if (node.text_overflow != .visible) {
            const maximum_width = try finite(maximum);
            if (maximum_width < 0) return error.InvalidStyle;
            result.width = @min(result.width, maximum_width);
        }
    }
    return result;
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
) sizing.Error!MarginCollapseResult {
    const container_index = tree.nodeIndex(container_id) orelse return error.InvalidStyle;
    if (tree.nodes.items[container_index].layout_hidden) return .{};

    const container_style = tree.nodes.items[container_index].style;
    const container_establishes_bfc = is_layout_root or
        establishesBfc(container_style) or
        tree.nodes.items[container_index].parent == .root;
    const container_edges = try resolveBoxEdges(
        container_style,
        context.percentage_basis.width,
    );
    tree.nodes.items[container_index].resolved_box_edges = .{
        .border = container_edges.border,
        .padding = container_edges.padding,
    };
    const initial_size = try resolveContainerInitialSize(
        container_style,
        context,
        container_edges,
    );
    const container_width = if (forced_border_width) |width|
        try finite(width)
    else
        initial_size.border_width;
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
    var float_ceiling: f32 = 0;
    var pending_bottom: ?CollapsibleMarginSet = null;
    var first_child_top: CollapsibleMarginSet = .{};
    var last_child_bottom: ?CollapsibleMarginSet = null;
    var top_collapse_open = top_margin_collapses_with_children;
    var all_in_flow_children_collapse_through = true;

    for (child_ids, 0..) |child_id, child_index| {
        const child = tree.node(child_id) orelse return error.InvalidStyle;
        if (child.layout_hidden) continue;

        const child_style = child.style;
        if (child_style.position == .absolute) {
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
        const child_needs_intrinsic_width = isIntrinsicDimension(child_style.size.width);
        var intrinsic = try intrinsicContentSizeWithContext(
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
        const start_y = @max(flow_y, clear_y);
        const float_side = physicalFloat(child_style.float, child_style.writing_direction);
        const child_establishes_bfc = establishesBfc(child_style);
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
        var used_auto_width_border = normal_auto_width_border;
        var child_size = try resolveChildSize(
            child_style,
            child_context,
            intrinsic,
            child_edges,
            used_auto_width_border,
            null,
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
            const float_start_y = @max(start_y, float_ceiling);
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
            pending_bottom = null;
            continue;
        }

        try resolveNormalAutoMargins(
            child_style,
            content_width,
            child_width,
            &margins,
        );
        var nested_result: ?MarginCollapseResult = null;
        if (!child_establishes_bfc) {
            nested_result = try layoutNestedBlockAtWidth(
                tree,
                child_id,
                child_context,
                child_width,
                measure,
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
                );
                child_width = child_size.width;
                child_height = child_size.height;
            }
        }
        const child_top_margin = CollapsibleMarginSet.fromMargin(margins.top).collapse(
            if (nested_result) |result| result.top else .{},
        );
        var child_bottom_margin = CollapsibleMarginSet.fromMargin(margins.bottom).collapse(
            if (nested_result) |result| result.bottom else .{},
        );
        var child_collapses_through = if (nested_result) |result|
            result.through
        else
            child_height == 0 and
                child_edges.vertical == 0 and
                !child_establishes_bfc;

        const hypothetical_margin = if (top_collapse_open and !child_establishes_bfc)
            @as(f32, 0)
        else if (pending_bottom) |bottom_margin|
            bottom_margin.collapse(child_top_margin).resolve()
        else
            child_top_margin.resolve();
        const hypothetical_y = try addFinite(flow_y, hypothetical_margin);
        const has_clearance = (clear_y > 0) and (hypothetical_y < clear_y);

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
        if (child_establishes_bfc) {
            const width_is_auto = child_style.size.width == .auto;
            const inline_side = physicalInlineStart(container_style.writing_direction);
            var placement: Placement = .{
                .x = 0,
                .y = 0,
                .slot_width = 0,
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
                        try addFinite(
                            try addFinite(child_height, margins.top),
                            margins.bottom,
                        ),
                        effective_start_y,
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
                    };
                    if (stable_slot) break;
                }
            } else {
                placement = try findSlot(
                    tree,
                    child_ids,
                    child_index,
                    content_width,
                    try addFinite(
                        try addFinite(child_width, margins.left),
                        margins.right,
                    ),
                    try addFinite(
                        try addFinite(child_height, margins.top),
                        margins.bottom,
                    ),
                    effective_start_y,
                    inline_side,
                    child_context.percentage_basis.width,
                );
            }
            if (auto_placement) |auto| {
                child_x = auto.x;
                child_y = try addFinite(auto.y, margins.top);
            } else {
                child_x = try addFinite(placement.x, margins.left);
                child_y = try addFinite(placement.y, margins.top);
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
                );
                child_width = child_size.width;
                child_height = child_size.height;
                child_bottom_margin = CollapsibleMarginSet.fromMargin(margins.bottom).collapse(
                    result.bottom,
                );
                child_collapses_through = result.through;
            }
        }
        var mixed_child_context = child_context;
        if (child_establishes_bfc) {
            const inline_side = physicalInlineStart(container_style.writing_direction);
            var final_slot_border_width = child_width;
            if (child_style.size.width == .auto) {
                const final_auto = try findAutoBfcPlacement(
                    tree,
                    child_ids,
                    child_index,
                    content_width,
                    child_width,
                    try addFinite(
                        try addFinite(child_height, margins.top),
                        margins.bottom,
                    ),
                    effective_start_y,
                    container_style.writing_direction,
                    margins,
                    child_context.percentage_basis.width,
                    true,
                );
                final_slot_border_width = final_auto.border_width;
                used_auto_width_border = final_slot_border_width;
                child_x = final_auto.x;
                child_y = try addFinite(final_auto.y, margins.top);
            } else {
                const final_placement = try findSlot(
                    tree,
                    child_ids,
                    child_index,
                    content_width,
                    try addFinite(
                        try addFinite(child_width, margins.left),
                        margins.right,
                    ),
                    try addFinite(
                        try addFinite(child_height, margins.top),
                        margins.bottom,
                    ),
                    effective_start_y,
                    inline_side,
                    child_context.percentage_basis.width,
                );
                child_x = try addFinite(final_placement.x, margins.left);
                child_y = try addFinite(final_placement.y, margins.top);
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

                const measured_child_width = child_width;
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
                );
                child_width = child_size.width;
                child_height = child_size.height;
                if (physicalInlineStart(container_style.writing_direction) == .right) {
                    child_x = try addFinite(
                        child_x,
                        try subtractFinite(measured_child_width, child_width),
                    );
                }
            }
        }
        const static_y = child_y;
        child.rect = .{
            .x = child_x,
            .y = static_y,
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

        if (child_collapses_through) {
            const child_self_collapsed = child_top_margin.collapse(child_bottom_margin);
            const combined_bottom = if (pending_bottom) |prev|
                prev.collapse(child_self_collapsed)
            else
                child_self_collapsed;
            pending_bottom = combined_bottom;
            last_child_bottom = combined_bottom;
        } else {
            flow_y = try addFinite(static_y, child_height);
            pending_bottom = child_bottom_margin;
            last_child_bottom = child_bottom_margin;
            in_flow_bottom = @max(in_flow_bottom, flow_y);
        }
    }
    const bottom_collapses = bottom_margin_collapses_with_children and
        last_child_bottom != null;
    const content_height = content_height_fixed orelse blk: {
        const bottom_margin_for_height = if (bottom_collapses)
            0
        else if (pending_bottom) |bottom_margin|
            bottom_margin.resolve()
        else
            0;
        const normal_bottom = try addFinite(in_flow_bottom, bottom_margin_for_height);
        const auto_content_height = if (container_establishes_bfc)
            @max(normal_bottom, float_bottom)
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

    try layoutAbsoluteChildren(
        tree,
        child_ids,
        content_width,
        content_height,
        container_style.writing_direction,
        measure,
        layout_ctx,
    );
    try writeScrollOffset(
        tree,
        container_index,
        child_ids,
        content_width,
        content_height,
        child_context.percentage_basis.width,
    );
    return .{
        .top = if (top_margin_collapses_with_children) first_child_top else .{},
        .bottom = if (bottom_collapses) last_child_bottom.? else .{},
        .through = top_margin_collapses_with_children and
            bottom_margin_collapses_with_children and
            all_in_flow_children_collapse_through,
    };
}

fn layoutNestedBlockAtWidth(
    tree: *widget.WidgetTree,
    child_id: Id,
    parent_context: sizing.SizingContext,
    used_width: f32,
    measure: ?layout_context.MeasureFn,
    forced_border_height: ?f32,
    layout_ctx: ?*layout_context.LayoutContext,
) sizing.Error!?MarginCollapseResult {
    const child = tree.node(child_id) orelse return error.InvalidStyle;
    if (child.children.items.len == 0) return null;
    switch (child.style.display) {
        .block, .flow_root => {},
        else => return null,
    }
    var nested_context = parent_context;
    nested_context.available.width = .{ .definite = try finite(used_width) };
    const result = try layoutPreparedContainerUnchecked(
        tree,
        child_id,
        nested_context,
        measure,
        null,
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
    const normalized_style = styleForSizing(input_style);
    const box_model = try sizing.resolveBoxModel(normalized_style, context);
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
    candidate = try sizing.applyAspectRatio(normalized_style, candidate);
    const height_is_fixed = candidate.height != null;
    if (candidate.height == null) {
        candidate.height = 0;
    }

    const resolved = try sizing.clampSize(
        normalized_style,
        .{
            .width = candidate.width.?,
            .height = candidate.height.?,
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
    const normalized_style = styleForSizing(input_style);
    const box_model = try sizing.resolveBoxModel(normalized_style, context);
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
    const resolved = try sizing.clampSize(
        normalized_style,
        .{
            .width = candidate.width.?,
            .height = candidate.height.?,
        },
        context,
    );
    return @max(0, resolved.height);
}

fn resolveChildSize(
    input_style: style.Style,
    context: sizing.SizingContext,
    intrinsic: widget.Size,
    edges: BoxEdges,
    auto_width_border: ?f32,
    auto_height_border: ?f32,
) sizing.Error!sizing.ResolvedSize {
    const normalized_style = styleForSizing(input_style);
    const box_model = try sizing.resolveBoxModel(normalized_style, context);
    var candidate: sizing.OptionalSize = switch (input_style.box_sizing) {
        .content_box => box_model.content_box,
        .border_box => box_model.border_box,
    };

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
    candidate = try sizing.applyAspectRatio(normalized_style, candidate);
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
    candidate = try sizing.applyAspectRatio(normalized_style, candidate);
    if (candidate.height == null) {
        candidate.height = try contentToSizingValue(
            intrinsic.height,
            edges.vertical,
            edges.box_vertical,
            input_style.box_sizing,
        );
    }

    const resolved = try sizing.clampSize(
        normalized_style,
        .{
            .width = candidate.width.?,
            .height = candidate.height.?,
        },
        context,
    );
    return .{
        .width = @max(0, resolved.width),
        .height = @max(0, resolved.height),
    };
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

fn layoutAbsoluteChildren(
    tree: *widget.WidgetTree,
    child_ids: []const Id,
    content_width: f32,
    content_height: f32,
    direction: style.Direction,
    measure: ?layout_context.MeasureFn,
    layout_ctx: ?*layout_context.LayoutContext,
) sizing.Error!void {
    const absolute_context: sizing.SizingContext = .{
        .available = .{
            .width = .{ .definite = content_width },
            .height = .{ .definite = content_height },
        },
        .percentage_basis = .{
            .width = content_width,
            .height = content_height,
        },
    };

    for (child_ids) |child_id| {
        const child = tree.node(child_id) orelse return error.InvalidStyle;
        if (child.layout_hidden or child.style.position != .absolute) continue;

        const child_style = child.style;
        const static_y = child.rect.y;
        const child_edges = try resolveBoxEdges(child_style, content_width);
        child.resolved_box_edges = .{
            .border = child_edges.border,
            .padding = child_edges.padding,
        };
        var margins = try resolveMargins(child_style, content_width);
        const left = try resolveInset(child_style.inset.left, content_width);
        const right = try resolveInset(child_style.inset.right, content_width);
        const top = try resolveInset(child_style.inset.top, content_height);
        const bottom = try resolveInset(child_style.inset.bottom, content_height);
        const auto_width_border = if (child_style.size.width == .auto and
            left != null and right != null)
            @max(
                0,
                try subtractFinite(
                    try subtractFinite(
                        try subtractFinite(
                            try subtractFinite(content_width, left.?),
                            right.?,
                        ),
                        margins.left,
                    ),
                    margins.right,
                ),
            )
        else
            null;
        const auto_height_border = if (child_style.size.height == .auto and
            top != null and bottom != null)
            @max(
                0,
                try subtractFinite(
                    try subtractFinite(
                        try subtractFinite(
                            try subtractFinite(content_height, top.?),
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
            auto_height_border == null;
        const intrinsic = try intrinsicContentSizeWithContextAndAxes(
            tree,
            child,
            child_edges,
            measure,
            layout_ctx,
            absolute_context,
            intrinsic_width,
            intrinsic_height,
        );
        var child_size = try resolveChildSize(
            child_style,
            absolute_context,
            intrinsic,
            child_edges,
            auto_width_border,
            auto_height_border,
        );
        const used_width = child_size.width;
        if (try layoutNestedBlockAtWidth(
            tree,
            child_id,
            absolute_context,
            used_width,
            measure,
            if (auto_height_border != null) child_size.height else null,
            layout_ctx,
        )) |_| {
            child_size = .{
                .width = child.rect.w,
                .height = child.rect.h,
            };
        }
        try resolveAbsoluteAutoMargins(
            child_style,
            content_width,
            content_height,
            child_size,
            left,
            right,
            top,
            bottom,
            &margins,
        );
        const horizontal_insets_auto = left == null and right == null;
        const child_x = if (horizontal_insets_auto)
            if (direction == .ltr)
                margins.left
            else
                try subtractFinite(
                    try subtractFinite(content_width, margins.right),
                    child_size.width,
                )
        else if (direction == .rtl)
            if (right) |value|
                try subtractFinite(
                    try subtractFinite(
                        try subtractFinite(content_width, value),
                        margins.right,
                    ),
                    child_size.width,
                )
            else
                try addFinite(left.?, margins.left)
        else if (left) |value|
            try addFinite(value, margins.left)
        else
            try subtractFinite(
                try subtractFinite(
                    try subtractFinite(content_width, right.?),
                    margins.right,
                ),
                child_size.width,
            );
        const child_y = if (top) |value|
            try addFinite(value, margins.top)
        else if (bottom) |value|
            try subtractFinite(
                try subtractFinite(
                    try subtractFinite(content_height, value),
                    margins.bottom,
                ),
                child_size.height,
            )
        else
            try addFinite(static_y, margins.top);
        child.rect = .{
            .x = child_x,
            .y = child_y,
            .w = child_size.width,
            .h = child_size.height,
        };
        try layoutMixedChild(tree, child, layout_ctx, absolute_context);
    }
}

fn writeScrollOffset(
    tree: *widget.WidgetTree,
    container_index: usize,
    child_ids: []const Id,
    content_width: f32,
    content_height: f32,
    percentage_basis: ?f32,
) sizing.Error!void {
    const scroll = tree.nodes.items[container_index].scroll orelse return;
    var max_width: f32 = 0;
    var max_height: f32 = 0;
    for (child_ids) |child_id| {
        const child = tree.nodeConst(child_id) orelse return error.InvalidStyle;
        if (child.layout_hidden) continue;
        const margins = try resolveMargins(child.style, percentage_basis);
        const right = try addFinite(
            try addFinite(child.rect.x, child.rect.w),
            margins.right,
        );
        const bottom = try addFinite(
            try addFinite(child.rect.y, child.rect.h),
            margins.bottom,
        );
        max_width = @max(max_width, right);
        max_height = @max(max_height, bottom);
    }
    scroll.state.max_offset = .{
        @max(0, try subtractFinite(max_width, content_width)),
        @max(0, try subtractFinite(max_height, content_height)),
    };
}

fn resolveBoxEdges(
    input_style: style.Style,
    percentage_basis: ?f32,
) sizing.Error!BoxEdges {
    const scrollbar_width = try finite(input_style.scrollbar_width);
    if (scrollbar_width < 0) return error.InvalidStyle;
    const scrollbar_gutter = input_style.scrollbarGutter();
    const border: style.Sides = .{
        .top = try resolveEdge(
            input_style.border_inset.top,
            input_style.border.top,
            percentage_basis,
        ),
        .right = try resolveEdge(
            input_style.border_inset.right,
            input_style.border.right,
            percentage_basis,
        ),
        .bottom = try resolveEdge(
            input_style.border_inset.bottom,
            input_style.border.bottom,
            percentage_basis,
        ),
        .left = try resolveEdge(
            input_style.border_inset.left,
            input_style.border.left,
            percentage_basis,
        ),
    };
    const resolved_padding: style.Sides = .{
        .top = try resolveEdge(
            input_style.padding_inset.top,
            input_style.padding.top,
            percentage_basis,
        ),
        .right = try resolveEdge(
            input_style.padding_inset.right,
            input_style.padding.right,
            percentage_basis,
        ),
        .bottom = try resolveEdge(
            input_style.padding_inset.bottom,
            input_style.padding.bottom,
            percentage_basis,
        ),
        .left = try resolveEdge(
            input_style.padding_inset.left,
            input_style.padding.left,
            percentage_basis,
        ),
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

fn resolveEdge(
    value: style.LengthPercentage,
    legacy: f32,
    percentage_basis: ?f32,
) sizing.Error!f32 {
    return switch (value) {
        .length => |number| if (number == 0) try finite(legacy) else try finite(number),
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
        .top = try resolveMargin(
            input_style.margin_inset.top,
            input_style.margin.top,
            percentage_basis,
        ),
        .right = try resolveMargin(
            input_style.margin_inset.right,
            input_style.margin.right,
            percentage_basis,
        ),
        .bottom = try resolveMargin(
            input_style.margin_inset.bottom,
            input_style.margin.bottom,
            percentage_basis,
        ),
        .left = try resolveMargin(
            input_style.margin_inset.left,
            input_style.margin.left,
            percentage_basis,
        ),
    };
}

fn resolveMargin(
    value: style.LengthPercentageAuto,
    legacy: f32,
    percentage_basis: ?f32,
) sizing.Error!f32 {
    return switch (value) {
        .auto => 0,
        .length => |number| if (number == 0) try finite(legacy) else try finite(number),
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
    const left_auto = isAutoMargin(input_style.margin_inset.left);
    const right_auto = isAutoMargin(input_style.margin_inset.right);
    const auto_count: u8 = @as(u8, @intFromBool(left_auto)) +
        @as(u8, @intFromBool(right_auto));
    if (auto_count == 0) return;
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
    if (start_inset == null or end_inset == null) return;
    const free_space = try subtractFinite(
        try subtractFinite(
            try subtractFinite(
                try subtractFinite(
                    try subtractFinite(
                        available,
                        start_inset.?,
                    ),
                    end_inset.?,
                ),
                border_size,
            ),
            start_margin.*,
        ),
        end_margin.*,
    );
    if (auto_count == 1) {
        if (start_auto) {
            start_margin.* = free_space;
        } else {
            end_margin.* = free_space;
        }
        return;
    }
    const share = @max(0, free_space) / @as(f32, @floatFromInt(auto_count));
    if (start_auto) start_margin.* = share;
    if (end_auto) end_margin.* = share;
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
    if (left) |value| {
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

fn styleForSizing(input_style: style.Style) style.Style {
    var result = input_style;
    result.border_inset = .{
        .top = legacyCompatibleEdge(input_style.border_inset.top, input_style.border.top),
        .right = legacyCompatibleEdge(input_style.border_inset.right, input_style.border.right),
        .bottom = legacyCompatibleEdge(
            input_style.border_inset.bottom,
            input_style.border.bottom,
        ),
        .left = legacyCompatibleEdge(input_style.border_inset.left, input_style.border.left),
    };
    result.padding_inset = .{
        .top = legacyCompatibleEdge(input_style.padding_inset.top, input_style.padding.top),
        .right = legacyCompatibleEdge(input_style.padding_inset.right, input_style.padding.right),
        .bottom = legacyCompatibleEdge(
            input_style.padding_inset.bottom,
            input_style.padding.bottom,
        ),
        .left = legacyCompatibleEdge(input_style.padding_inset.left, input_style.padding.left),
    };
    return result;
}

fn legacyCompatibleEdge(value: style.LengthPercentage, legacy: f32) style.LengthPercentage {
    return switch (value) {
        .length => |number| if (number == 0)
            .{ .length = legacy }
        else
            .{ .length = number },
        .percent => |fraction| .{ .percent = fraction },
    };
}

fn requestFromSizingContext(
    input: sizing.SizingContext,
    forced_border: ?widget.Size,
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
        .forced_border = forced_border,
        .intrinsic_width = intrinsic_width,
        .intrinsic_height = intrinsic_height,
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
    _: layout_context.Request,
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
) sizing.Error!widget.Size {
    if (node.children.items.len != 0) {
        const block_container =
            node.style.display == .block or node.style.display == .flow_root;
        if (block_container and intrinsic_width) {
            const request = try requestFromSizingContext(
                containing,
                null,
                true,
                intrinsic_height_override,
            );
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
                const measured = try context.measure_node(
                    context,
                    tree,
                    node,
                    try requestFromSizingContext(
                        containing,
                        null,
                        intrinsic_width,
                        null,
                    ),
                );
                return measured.content;
            }
        }
    }
    return intrinsicContentSize(node, edges, measure);
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
    const measured = try measureNatural(
        tree,
        node,
        request,
        &pure_context,
    );
    return measured.content;
}

fn layoutMixedChild(
    tree: *widget.WidgetTree,
    child: *widget.WidgetNode,
    layout_ctx: ?*layout_context.LayoutContext,
    containing: sizing.SizingContext,
) sizing.Error!void {
    const context = layout_ctx orelse return;
    if (child.children.items.len == 0) return;
    if (child.style.display == .block or child.style.display == .flow_root) return;
    try context.layout_node(
        context,
        tree,
        child,
        try requestFromSizingContext(
            containing,
            .{ .width = child.rect.w, .height = child.rect.h },
            false,
            null,
        ),
    );
}

fn intrinsicContentSize(
    node: *const widget.WidgetNode,
    edges: BoxEdges,
    measure: ?layout_context.MeasureFn,
) sizing.Error!widget.Size {
    const measured: widget.Size = switch (node.kind) {
        .label => |label| if (measure) |measure_text|
            measure_text(label.text, node.font_size, node.font_id)
        else blk: {
            const scale: f32 = if (node.font_size > 0) node.font_size / 20 else 1;
            const length: f32 = @floatFromInt(@min(label.text.len, 1 << 24));
            break :blk .{ .width = length * 10 * scale, .height = 20 * scale };
        },
        .spacer => |spacer| .{ .width = spacer.size, .height = spacer.size },
        else => .{
            .width = @max(0, node.rect.w - edges.horizontal),
            .height = @max(0, node.rect.h - edges.vertical),
        },
    };
    const finite_width = try finite(measured.width);
    const finite_height = try finite(measured.height);
    return .{
        .width = @max(0, finite_width),
        .height = @max(0, finite_height),
    };
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

fn physicalInlineStart(direction: style.Direction) PhysicalSide {
    return if (direction == .ltr) .left else .right;
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
        node.rect = .{};
        node.resolved_box_edges = null;
        node.natural_main = 0;
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
                state.slot.left = @max(state.slot.left, try addFinite(outer.x, outer.w));
            } else {
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
        const left_float = slot.left > 0;
        const right_float = slot.right < container_width;

        if (!slot.occupied or (!left_float and !right_float)) {
            const border_width = try autoBorderWidth(container_width, margins);
            const x = try autoBorderX(
                container_width,
                border_width,
                margins,
                direction,
            );
            return .{
                .x = x,
                .y = y,
                .border_width = border_width,
                .slot_width = slot_width,
            };
        }

        const border_width = if (left_float and right_float)
            slot_width
        else if (left_float)
            @max(0, try subtractFinite(slot_width, margins.right))
        else
            @max(0, try subtractFinite(slot_width, margins.left));
        const provisional_outer_width = try addFinite(
            try addFinite(border_width, margins.left),
            margins.right,
        );
        const border_x = if (left_float and !right_float)
            if (direction == .ltr)
                slot.left
            else
                try subtractFinite(
                    try subtractFinite(slot.right, margins.right),
                    border_width,
                )
        else if (right_float and !left_float)
            try addFinite(slot.left, margins.left)
        else if (direction == .ltr)
            slot.left
        else
            try subtractFinite(slot.right, border_width);
        const border_right = try addFinite(border_x, border_width);
        const border_contained = border_x >= slot.left and border_right <= slot.right;
        if ((!enforce_candidate_fit or checked_candidate_width <= border_width) and
            provisional_outer_width > 0 and
            border_contained)
        {
            return .{
                .x = border_x,
                .y = y,
                .border_width = border_width,
                .slot_width = slot_width,
            };
        }
        if (!std.math.isFinite(slot.next_y) or slot.next_y <= y) break;
        y = slot.next_y;
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
