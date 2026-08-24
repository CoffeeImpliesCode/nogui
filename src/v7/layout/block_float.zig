const std = @import("std");
const Id = @import("../id.zig").Id;
const flex = @import("../flex.zig");
const style = @import("../style.zig");
const sizing = @import("sizing.zig");
const widget = @import("../widget.zig");

const PhysicalSide = enum { none, left, right };

const BoxEdges = struct {
    border: style.Sides,
    padding: style.Sides,
    horizontal: f32,
    vertical: f32,
};

const Slot = struct {
    left: f32,
    right: f32,
    next_y: f32,
    occupied: bool,
};

const Placement = struct {
    x: f32,
    y: f32,
    slot_width: f32,
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

    pub fn layoutContainer(
        self: *const LayoutPass,
        container_id: Id,
        context: sizing.SizingContext,
        measure: ?flex.MeasureFn,
    ) sizing.Error!void {
        try validateContext(context);
        return layoutPreparedContainerUnchecked(
            self.tree,
            container_id,
            context,
            measure,
            null,
        );
    }
};

/// Layout one container through a fresh pass for direct one-container callers.
pub fn layoutContainer(
    tree: *widget.WidgetTree,
    container_id: Id,
    context: sizing.SizingContext,
    measure: ?flex.MeasureFn,
) sizing.Error!void {
    try validateContext(context);
    const pass = try LayoutPass.init(tree);
    return layoutPreparedContainerUnchecked(
        pass.tree,
        container_id,
        context,
        measure,
        null,
    );
}

/// Lay out one container after context validation and hidden-state preparation.
fn layoutPreparedContainerUnchecked(
    tree: *widget.WidgetTree,
    container_id: Id,
    context: sizing.SizingContext,
    measure: ?flex.MeasureFn,
    forced_border_height: ?f32,
) sizing.Error!void {
    const container_index = tree.nodeIndex(container_id) orelse return error.InvalidStyle;
    if (tree.nodes.items[container_index].layout_hidden) return;

    const container_style = tree.nodes.items[container_index].style;
    const container_establishes_bfc = establishesBfc(container_style) or
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
    const container_width = initial_size.border_width;
    const content_width = @max(0, container_width - container_edges.horizontal);
    const forced_height = if (forced_border_height) |height| try finite(height) else null;
    const content_height_fixed = if (forced_height) |height|
        @max(0, height - container_edges.vertical)
    else if (initial_size.border_height) |height|
        @max(0, height - container_edges.vertical)
    else
        null;
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
        var intrinsic = try intrinsicContentSize(child, child_edges, measure);
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
            if (try layoutNestedBlockAtWidth(
                tree,
                child_id,
                child_context,
                child_width,
                measure,
                null,
            )) {
                intrinsic = try intrinsicContentSize(child, child_edges, measure);
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
        var child_x = inlineStartX(
            container_style.writing_direction,
            content_width,
            child_width,
        );
        const top_margin = CollapsibleMarginSet.fromMargin(margins.top);
        const vertical_margin = if (clear_y <= flow_y)
            if (pending_bottom) |bottom_margin|
                bottom_margin.collapse(top_margin).resolve()
            else
                top_margin.resolve()
        else
            top_margin.resolve();
        var child_y = try addFinite(start_y, vertical_margin);
        if (container_style.writing_direction == .ltr) {
            child_x = try addFinite(child_x, margins.left);
        } else {
            child_x = try subtractFinite(child_x, margins.right);
        }
        if (child_establishes_bfc) {
            const width_is_auto = child_style.size.width == .auto;
            const inline_side = physicalInlineStart(container_style.writing_direction);
            var placement = try findSlot(
                tree,
                child_ids,
                child_index,
                content_width,
                if (width_is_auto)
                    0
                else
                    try addFinite(
                        try addFinite(child_width, margins.left),
                        margins.right,
                    ),
                try addFinite(
                    try addFinite(child_height, margins.top),
                    margins.bottom,
                ),
                start_y,
                inline_side,
                child_context.percentage_basis.width,
            );
            if (width_is_auto) {
                var attempt: usize = 0;
                while (attempt <= child_index) : (attempt += 1) {
                    used_auto_width_border = @max(
                        0,
                        try subtractFinite(
                            try subtractFinite(
                                placement.slot_width,
                                margins.left,
                            ),
                            margins.right,
                        ),
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
                    const next_placement = try findSlot(
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
                        start_y,
                        inline_side,
                        child_context.percentage_basis.width,
                    );
                    const stable_slot = next_placement.y == placement.y and
                        next_placement.slot_width == placement.slot_width;
                    placement = next_placement;
                    if (stable_slot) break;
                }
            }
            child_x = try addFinite(placement.x, margins.left);
            child_y = try addFinite(placement.y, margins.top);
        }

        if (try layoutNestedBlockAtWidth(
            tree,
            child_id,
            child_context,
            child_width,
            measure,
            null,
        )) {
            intrinsic = try intrinsicContentSize(child, child_edges, measure);
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
        if (child_establishes_bfc) {
            const inline_side = physicalInlineStart(container_style.writing_direction);
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
                start_y,
                inline_side,
                child_context.percentage_basis.width,
            );
            child_x = try addFinite(final_placement.x, margins.left);
            child_y = try addFinite(final_placement.y, margins.top);
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
        flow_y = try addFinite(static_y, child_height);
        pending_bottom = CollapsibleMarginSet.fromMargin(margins.bottom);
        in_flow_bottom = @max(in_flow_bottom, flow_y);
    }

    const content_height = content_height_fixed orelse blk: {
        const normal_bottom = try addFinite(
            in_flow_bottom,
            if (pending_bottom) |bottom_margin| bottom_margin.resolve() else 0,
        );
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
    );
    try writeScrollOffset(
        tree,
        container_index,
        child_ids,
        content_width,
        content_height,
        child_context.percentage_basis.width,
    );
}

fn layoutNestedBlockAtWidth(
    tree: *widget.WidgetTree,
    child_id: Id,
    parent_context: sizing.SizingContext,
    used_width: f32,
    measure: ?flex.MeasureFn,
    forced_border_height: ?f32,
) sizing.Error!bool {
    const child = tree.node(child_id) orelse return error.InvalidStyle;
    if (child.children.items.len == 0) return false;
    switch (child.style.display) {
        .block, .flow_root => {},
        else => return false,
    }
    var nested_context = parent_context;
    nested_context.available.width = .{ .definite = try finite(used_width) };
    try layoutPreparedContainerUnchecked(
        tree,
        child_id,
        nested_context,
        measure,
        forced_border_height,
    );
    return true;
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
            edges.horizontal,
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
            edges.horizontal,
            input_style.box_sizing,
        );
    }
    candidate.height = try borderToSizingValue(
        try addFinite(content_height, edges.vertical),
        edges.vertical,
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
        candidate.width = if (auto_width_border) |width|
            try borderToSizingValue(width, edges.horizontal, input_style.box_sizing)
        else
            try contentToSizingValue(
                intrinsic.width,
                edges.horizontal,
                input_style.box_sizing,
            );
    }
    candidate = try sizing.applyAspectRatio(normalized_style, candidate);
    if (candidate.height == null) {
        candidate.height = if (auto_height_border) |height|
            try borderToSizingValue(height, edges.vertical, input_style.box_sizing)
        else
            try contentToSizingValue(
                intrinsic.height,
                edges.vertical,
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
    edges: f32,
    box_sizing: style.BoxSizing,
) sizing.Error!f32 {
    return switch (box_sizing) {
        .content_box => finite(content),
        .border_box => addFinite(content, edges),
    };
}

fn borderToSizingValue(
    border: f32,
    edges: f32,
    box_sizing: style.BoxSizing,
) sizing.Error!f32 {
    const checked_border = try finite(border);
    return switch (box_sizing) {
        .content_box => @max(0, try finite(checked_border - edges)),
        .border_box => checked_border,
    };
}

fn layoutAbsoluteChildren(
    tree: *widget.WidgetTree,
    child_ids: []const Id,
    content_width: f32,
    content_height: f32,
    direction: style.Direction,
    measure: ?flex.MeasureFn,
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
        var intrinsic = try intrinsicContentSize(child, child_edges, measure);
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
        var child_size = try resolveChildSize(
            child_style,
            absolute_context,
            intrinsic,
            child_edges,
            auto_width_border,
            auto_height_border,
        );
        if (try layoutNestedBlockAtWidth(
            tree,
            child_id,
            absolute_context,
            child_size.width,
            measure,
            auto_height_border,
        )) {
            intrinsic = try intrinsicContentSize(child, child_edges, measure);
            child_size = try resolveChildSize(
                child_style,
                absolute_context,
                intrinsic,
                child_edges,
                auto_width_border,
                auto_height_border,
            );
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
    const padding: style.Sides = .{
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
    return .{
        .border = border,
        .padding = padding,
        .horizontal = try addFinite(
            try addFinite(border.left, border.right),
            try addFinite(padding.left, padding.right),
        ),
        .vertical = try addFinite(
            try addFinite(border.top, border.bottom),
            try addFinite(padding.top, padding.bottom),
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
    const free_space = @max(
        0,
        try subtractFinite(
            try subtractFinite(
                try subtractFinite(
                    try subtractFinite(
                        available,
                        start_inset orelse 0,
                    ),
                    end_inset orelse 0,
                ),
                border_size,
            ),
            start_margin.*,
        ),
        end_margin.*,
    );
    const share = free_space / @as(f32, @floatFromInt(auto_count));
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

fn intrinsicContentSize(
    node: *const widget.WidgetNode,
    edges: BoxEdges,
    measure: ?flex.MeasureFn,
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
    return input_style.overflow.width == .scroll or
        input_style.overflow.width == .auto or
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
    var bottom: f32 = 0;
    for (child_ids[0..prior_count]) |child_id| {
        const child = tree.nodeConst(child_id) orelse return error.InvalidStyle;
        if (child.layout_hidden or child.style.position == .absolute) continue;

        const side = physicalFloat(child.style.float, child.style.writing_direction);
        if (!clears(clear, direction, side)) continue;
        const margins = try resolveMargins(child.style, percentage_basis);
        bottom = @max(
            bottom,
            try addFinite(
                try addFinite(child.rect.y, child.rect.h),
                margins.bottom,
            ),
        );
    }
    return bottom;
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
    while (attempt <= prior_count) : (attempt += 1) {
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

    for (child_ids[0..prior_count]) |child_id| {
        const child = tree.nodeConst(child_id) orelse return error.InvalidStyle;
        if (child.layout_hidden or child.style.position == .absolute) continue;
        const side = physicalFloat(child.style.float, child.style.writing_direction);
        if (side == .none) continue;
        const margins = try resolveMargins(child.style, percentage_basis);
        const outer: widget.Rect = .{
            .x = try subtractFinite(child.rect.x, margins.left),
            .y = try subtractFinite(child.rect.y, margins.top),
            .w = try addFinite(
                try addFinite(child.rect.w, margins.left),
                margins.right,
            ),
            .h = try addFinite(
                try addFinite(child.rect.h, margins.top),
                margins.bottom,
            ),
        };
        if (!verticalOverlap(outer, candidate_y, candidate_height)) continue;

        result.occupied = true;
        if (side == .left) {
            result.left = @max(result.left, try addFinite(outer.x, outer.w));
        } else {
            result.right = @min(result.right, outer.x);
        }
        result.next_y = @min(result.next_y, try addFinite(outer.y, outer.h));
    }
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
