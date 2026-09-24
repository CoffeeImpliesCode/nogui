//! Stable action scopes along the focused widget's committed-tree ancestry.
const std = @import("std");
const WidgetId = @import("id.zig").WidgetId;
const FrameNodeId = @import("id.zig").FrameNodeId;
const WidgetTree = @import("widget.zig").WidgetTree;
const input = @import("input.zig");

/// `.app` is the last scope; a widget scope uses its persistent identity,
/// never a frame-local node ID. A missing, hidden, or disabled focus falls
/// straight through to the application scope.
pub const Scope = union(enum) {
    app,
    widget: WidgetId,

    pub fn eql(a: Scope, b: Scope) bool {
        return switch (a) {
            .app => b == .app,
            .widget => |id| switch (b) {
                .app => false,
                .widget => |other| id.eql(other),
            },
        };
    }
};

/// A bounded, allocation-free walk over the committed tree.
pub const Path = struct {
    tree: *const WidgetTree,
    next_node: ?FrameNodeId,
    remaining: usize,
    app_pending: bool = true,

    pub fn init(tree: *const WidgetTree, focused: ?WidgetId) Path {
        var next_node: ?FrameNodeId = null;
        if (focused) |id| {
            if (tree.frameNode(id)) |node| {
                if (input.isEnabled(tree, node)) next_node = node;
            }
        }
        return .{ .tree = tree, .next_node = next_node, .remaining = tree.nodes.items.len };
    }

    pub fn next(self: *Path) ?Scope {
        while (self.next_node) |node_id| {
            if (self.remaining == 0) {
                self.next_node = null;
                break;
            }
            self.remaining -= 1;
            const node = self.tree.nodeConst(node_id) orelse {
                self.next_node = null;
                break;
            };
            self.next_node = if (node.parent == .root) null else node.parent;
            if (node.widget_id) |id| return .{ .widget = id };
        }
        if (!self.app_pending) return null;
        self.app_pending = false;
        return .app;
    }
};

test "api-w10 scope equality compares stable identity" {
    const one: Scope = .{ .widget = .{ .owner = 1, .slot = 2, .generation = 3 } };
    const same: Scope = .{ .widget = .{ .owner = 1, .slot = 2, .generation = 3 } };
    const other: Scope = .{ .widget = .{ .owner = 1, .slot = 2, .generation = 4 } };
    try std.testing.expect(one.eql(same));
    try std.testing.expect(!one.eql(other));
    try std.testing.expect(!one.eql(.app));
    try std.testing.expect((@as(Scope, .app)).eql(.app));
}
