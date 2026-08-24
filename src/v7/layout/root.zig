const std = @import("std");
const Id = @import("../id.zig").Id;
const block_float = @import("block_float.zig");
const modular_flex = @import("flex.zig");
const modular_grid = @import("grid.zig");
const flex = @import("../flex.zig");
const sizing = @import("sizing.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");

pub const Options = struct {
    allocator: std.mem.Allocator,
    available: widget.Size,
    measure: ?flex.MeasureFn,
};

pub const LayoutError = sizing.Error;

pub fn validateAvailable(available: widget.Size) LayoutError!void {
    if (!std.math.isFinite(available.width)) return error.InvalidStyle;
    if (!std.math.isFinite(available.height)) return error.InvalidStyle;
}
fn isAutoInset(value: style.LengthPercentageAuto) bool {
    return switch (value) {
        .auto => true,
        else => false,
    };
}

fn isZeroMarginInset(value: style.LengthPercentageAuto) bool {
    return switch (value) {
        .auto => false,
        .length => |length| length == 0,
        .percent => |percent| percent == 0,
    };
}

fn hasDefaultMargins(node_style: style.Style) bool {
    return node_style.margin.top == 0 and
        node_style.margin.right == 0 and
        node_style.margin.bottom == 0 and
        node_style.margin.left == 0 and
        isZeroMarginInset(node_style.margin_inset.top) and
        isZeroMarginInset(node_style.margin_inset.right) and
        isZeroMarginInset(node_style.margin_inset.bottom) and
        isZeroMarginInset(node_style.margin_inset.left);
}

fn hasAutomaticInsets(node_style: style.Style) bool {
    return isAutoInset(node_style.inset.top) and
        isAutoInset(node_style.inset.right) and
        isAutoInset(node_style.inset.bottom) and
        isAutoInset(node_style.inset.left);
}

fn hasDefaultRootFlexItem(node_style: style.Style) bool {
    if (node_style.grow != 0 or node_style.shrink != 1 or node_style.basis != 0) {
        return false;
    }
    if (node_style.min_main != null) return false;
    return switch (node_style.flex_basis) {
        .auto => true,
        else => false,
    };
}

fn hasDefaultSurfacePlacement(node: *const widget.WidgetNode) bool {
    const node_style = node.style;
    return node_style.position == .relative and
        node_style.float == .none and
        node_style.clear == .none and
        hasDefaultMargins(node_style) and
        hasAutomaticInsets(node_style) and
        hasDefaultRootFlexItem(node_style);
}

fn isConcreteBlockFloatDimension(value: style.Dimension) bool {
    return switch (value) {
        .length, .percent => true,
        .auto, .min_content, .max_content => false,
    };
}

fn isFlatBlockLeaf(node: *const widget.WidgetNode, root_id: Id) bool {
    if (node.parent != root_id or node.children.items.len != 0 or node.scroll != null) {
        return false;
    }
    const node_style = node.style;
    if (!hasDefaultMargins(node_style)) return false;
    if (node_style.position == .relative and !hasAutomaticInsets(node_style)) return false;
    if (node_style.display == .none) return true;
    const kind_eligible = switch (node.kind) {
        .label => node.text_max_width == null and node.text_overflow == .visible,
        .spacer => true,
        .column, .row => isConcreteBlockFloatDimension(node_style.size.width) and
            isConcreteBlockFloatDimension(node_style.size.height),
        .button, .slider => false,
    };
    if (!kind_eligible) return false;
    return switch (node_style.display) {
        .block, .flow_root => true,
        .flex, .grid, .none => false,
    };
}

fn eligibleBlockRootIndex(tree: *const widget.WidgetTree) ?usize {
    var root_index: ?usize = null;
    for (tree.nodes.items, 0..) |node, node_index| {
        if (node.parent != .root) continue;
        if (root_index != null) return null;
        if (node.scroll != null or !hasDefaultSurfacePlacement(&node)) return null;
        switch (node.kind) {
            .column, .row => {},
            else => return null,
        }
        switch (node.style.display) {
            .block, .flow_root, .none => root_index = node_index,
            .flex, .grid => return null,
        }
    }
    const index = root_index orelse return null;
    const root = &tree.nodes.items[index];
    var direct_child_count: usize = 0;
    for (tree.nodes.items, 0..) |node, node_index| {
        if (node_index == index) continue;
        if (!isFlatBlockLeaf(&node, root.id)) return null;
        direct_child_count += 1;
    }
    if (root.children.items.len != direct_child_count) return null;
    for (root.children.items) |child_id| {
        const child = tree.nodeConst(child_id) orelse return null;
        if (!isFlatBlockLeaf(child, root.id)) return null;
    }
    return index;
}

fn eligibleFlexSubtree(
    tree: *const widget.WidgetTree,
    node_id: Id,
    expected_parent: Id,
    depth: usize,
) bool {
    if (depth == 0) return false;
    const node = tree.nodeConst(node_id) orelse return false;
    if (node.parent != expected_parent or node.scroll != null) return false;
    if (node.style.display == .none) {
        for (node.children.items, 0..) |child_id, child_index| {
            for (node.children.items[0..child_index]) |prior_id| {
                if (child_id == prior_id) return false;
            }
            if (!eligibleFlexSubtree(tree, child_id, node.id, depth - 1)) return false;
        }
        return true;
    }
    if (node.children.items.len == 0) return true;
    if (node.style.display != .flex) return false;
    switch (node.kind) {
        .row, .column => {},
        else => return false,
    }
    for (node.children.items, 0..) |child_id, child_index| {
        for (node.children.items[0..child_index]) |prior_id| {
            if (child_id == prior_id) return false;
        }
        if (!eligibleFlexSubtree(tree, child_id, node.id, depth - 1)) return false;
    }
    return true;
}

fn eligibleFlexRootIndex(tree: *const widget.WidgetTree) ?usize {
    var root_index: ?usize = null;
    for (tree.nodes.items, 0..) |node, node_index| {
        if (node.parent != .root) continue;
        if (root_index != null) return null;
        if (!hasDefaultSurfacePlacement(&node) or node.scroll != null) return null;
        if (node.style.display != .flex) return null;
        if (!isConcreteBlockFloatDimension(node.style.size.width) or
            !isConcreteBlockFloatDimension(node.style.size.height))
        {
            return null;
        }
        switch (node.kind) {
            .row, .column => {},
            else => return null,
        }
        root_index = node_index;
    }
    const index = root_index orelse return null;
    if (!eligibleFlexSubtree(tree, tree.nodes.items[index].id, .root, tree.nodes.items.len)) {
        return null;
    }
    return index;
}

fn eligibleGridSubtree(
    tree: *const widget.WidgetTree,
    node_id: Id,
    expected_parent: Id,
    depth: usize,
) bool {
    if (depth == 0) return false;
    const node = tree.nodeConst(node_id) orelse return false;
    if (node.parent != expected_parent or node.scroll != null) return false;
    if (node.style.display == .none) {
        for (node.children.items, 0..) |child_id, child_index| {
            for (node.children.items[0..child_index]) |prior_id| {
                if (child_id == prior_id) return false;
            }
            if (!eligibleGridSubtree(tree, child_id, node.id, depth - 1)) return false;
        }
        return true;
    }
    if (node.children.items.len == 0) return true;
    if (node.style.display != .grid) return false;
    switch (node.kind) {
        .row, .column => {},
        else => return false,
    }
    for (node.children.items, 0..) |child_id, child_index| {
        for (node.children.items[0..child_index]) |prior_id| {
            if (child_id == prior_id) return false;
        }
        if (!eligibleGridSubtree(tree, child_id, node.id, depth - 1)) return false;
    }
    return true;
}

fn eligibleGridRootIndex(tree: *const widget.WidgetTree) ?usize {
    var root_index: ?usize = null;
    for (tree.nodes.items, 0..) |node, node_index| {
        if (node.parent != .root) continue;
        if (root_index != null) return null;
        if (!hasDefaultSurfacePlacement(&node) or node.scroll != null) return null;
        if (node.style.display != .grid) return null;
        if (!isConcreteBlockFloatDimension(node.style.size.width) or
            !isConcreteBlockFloatDimension(node.style.size.height))
        {
            return null;
        }
        switch (node.kind) {
            .row, .column => {},
            else => return null,
        }
        root_index = node_index;
    }
    const index = root_index orelse return null;
    if (!eligibleGridSubtree(tree, tree.nodes.items[index].id, .root, tree.nodes.items.len)) {
        return null;
    }
    return index;
}

pub fn layoutTree(tree: *widget.WidgetTree, options: Options) LayoutError!void {
    try validateAvailable(options.available);

    if (eligibleBlockRootIndex(tree)) |root_index| {
        const pass = try block_float.LayoutPass.init(tree);
        return pass.layoutContainer(
            tree.nodes.items[root_index].id,
            .{
                .available = .{
                    .width = .{ .definite = options.available.width },
                    .height = .{ .definite = options.available.height },
                },
                .percentage_basis = .{
                    .width = options.available.width,
                    .height = options.available.height,
                },
            },
            options.measure,
        );
    }

    if (eligibleFlexRootIndex(tree)) |root_index| {
        const measure: ?modular_flex.MeasureFn = options.measure;
        return modular_flex.layoutContainer(tree, tree.nodes.items[root_index].id, .{
            .allocator = options.allocator,
            .available = options.available,
            .measure = measure,
        });
    }

    if (eligibleGridRootIndex(tree)) |root_index| {
        const measure: ?modular_grid.MeasureFn = options.measure;
        return modular_grid.layoutContainer(tree, tree.nodes.items[root_index].id, .{
            .allocator = options.allocator,
            .available = options.available,
            .measure = measure,
        });
    }

    flex.layoutWith(tree, options.available, options.measure);
}
