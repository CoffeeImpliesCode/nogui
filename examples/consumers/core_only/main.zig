//! Core-only external consumer of the `nogui` package.
//!
//! Headless, dependency-free proof that a downstream package can drive the
//! canonical App through its public API alone: mount a component, produce a
//! frame, click a widget, observe the state change, tear everything down.
//! No window, no font, no GPU, no SDL, no repository-relative demo file.
const std = @import("std");
const nogui = @import("nogui");

const DrawCtx = nogui.DrawCtx;
const FrameNodeId = nogui.FrameNodeId;
const WidgetKind = nogui.WidgetKind;

/// Surface every consumer has to satisfy: the exact node budget of a frame and
/// a click that a user would recognise.
const surface = struct {
    const width: f32 = 320;
    const height: f32 = 200;
    /// Frame root, column container, label, button.
    const node_count: usize = 4;
};

const Counter = struct {
    count: u32 = 0,
    label_text: [32]u8 = @splat(0),
    button_node: FrameNodeId = .root,

    pub fn draw(self: *Counter, ctx: *DrawCtx) anyerror!void {
        const text = try std.fmt.bufPrint(&self.label_text, "Count: {d}", .{self.count});
        _ = try ctx.column(.{ .gap = 8 });
        defer ctx.pop();
        _ = try ctx.label(.{ .text = text });
        self.button_node = try ctx.button(.{
            .key = .{ .static = "increment" },
            .label = "Increment",
            .on_click = Counter.onClick,
        });
    }

    pub fn onClick(self: *Counter) void {
        self.count += 1;
    }

    fn label(self: *const Counter) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.label_text, 0) orelse self.label_text.len;
        return self.label_text[0..end];
    }
};

fn findNode(tree: *const nogui.WidgetTree, kind: std.meta.Tag(nogui.WidgetKind)) ?FrameNodeId {
    for (tree.nodes.items) |*node| {
        if (std.meta.activeTag(node.kind) == kind) return node.id;
    }
    return null;
}

fn click(app: *nogui.App, tree: *const nogui.WidgetTree, node: FrameNodeId) !void {
    // A widget without a stable identity cannot be hit-tested reliably.
    _ = (tree.nodeConst(node) orelse return error.MissingButtonNode)
        .widget_id orelse return error.ButtonWithoutIdentity;
    const rect = nogui.widget.visualBorderRect(tree, node);
    const x = rect.x + rect.w / 2;
    const y = rect.y + rect.h / 2;
    _ = try app.handle(.{ .mouse_down = .{ .button = .left, .x = x, .y = y } });
    _ = try app.handle(.{ .mouse_up = .{ .button = .left, .x = x, .y = y } });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var session = try nogui.Session.init(gpa);
    defer session.deinit() catch unreachable;

    var app = try nogui.App.init(gpa, &session);
    defer app.deinit();
    app.serialize_json = true;

    var counter: Counter = .{};
    try app.mountRoot(Counter, &counter);

    const first = try app.frame(1, .{ .width = surface.width, .height = surface.height });
    defer if (first.json) |json| gpa.free(json);
    if (first.json == null) return error.MissingFrameJson;

    if (first.tree.nodes.items.len != surface.node_count) {
        std.debug.print("frame 1 node count {d}, expected {d}\n", .{
            first.tree.nodes.items.len,
            surface.node_count,
        });
        return error.UnexpectedNodeCount;
    }
    if (findNode(first.tree, .button) == null) return error.MissingButtonNode;
    if (findNode(first.tree, .label) == null) return error.MissingLabelNode;
    if (!std.mem.startsWith(u8, counter.label(), "Count: 0")) return error.UnexpectedInitialLabel;

    const button_node = findNode(first.tree, .button).?;
    try click(&app, first.tree, button_node);
    if (counter.count != 1) {
        std.debug.print("count after click {d}, expected 1\n", .{counter.count});
        return error.ClickDidNotLand;
    }

    const second = try app.frame(2, .{ .width = surface.width, .height = surface.height });
    defer if (second.json) |json| gpa.free(json);
    if (second.tree.nodes.items.len != surface.node_count) return error.UnexpectedNodeCount;

    try std.Io.File.stdout().writeStreamingAll(init.io, "core_only: OK\n");
}
