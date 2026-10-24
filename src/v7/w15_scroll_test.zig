//! Stable programmatic scroll behavior against the current frame tree.
const std = @import("std");
const layout = @import("layout/root.zig");
const scroll = @import("scroll.zig");
const widget = @import("widget.zig");
const FrameNodeId = @import("id.zig").FrameNodeId;
const WidgetId = @import("id.zig").WidgetId;

const outer_id: FrameNodeId = @fromBackingInt(@intCast(1));
const inner_id: FrameNodeId = @fromBackingInt(@intCast(2));
const outer_key: WidgetId = .{ .owner = 10, .slot = 1, .generation = 1 };
const inner_key: WidgetId = .{ .owner = 10, .slot = 2, .generation = 1 };
const window: u64 = 42;

fn handle(key: WidgetId) scroll.Handle {
    return .{ .window = window, .widget = key };
}

fn appendScroller(
    tree: *widget.WidgetTree,
    id: FrameNodeId,
    parent: FrameNodeId,
    key: WidgetId,
    state: *widget.ScrollState,
    axis: widget.ScrollAxis,
    viewport: [2]f32,
    content: [2]f32,
) !void {
    try tree.appendNode(.{
        .id = id,
        .widget_id = key,
        .kind = .{ .column = .{} },
        .parent = parent,
        .rect = .{ .w = viewport[0], .h = viewport[1] },
        .layout_content_size = .{ .width = content[0], .height = content[1] },
        .scroll = .{ .state = state, .axis = axis },
    });
}

// Commands clamp to layout limits, ignore disabled axes, and report only actual changes.
test "api-w15 scroll commands clamp and report changes" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    var state: widget.ScrollState = .{ .max_offset = .{ 0, 200 } };
    try appendScroller(&tree, outer_id, .root, outer_key, &state, .vertical, .{ 100, 60 }, .{ 100, 260 });

    const target = handle(outer_key);
    try std.testing.expect(scroll.scrollTo(&tree, window, target, .{ 75, 500 }));
    try std.testing.expectEqual([2]f32{ 0, 200 }, state.offset);
    try std.testing.expect(!scroll.scrollTo(&tree, window, target, .{ 75, 500 }));
    try std.testing.expect(scroll.scrollBy(&tree, window, target, .{ 25, -80 }));
    try std.testing.expectEqual([2]f32{ 0, 120 }, state.offset);
    try std.testing.expect(scroll.scrollBy(&tree, window, target, .{ 0, -1000 }));
    try std.testing.expectEqual([2]f32{ 0, 0 }, state.offset);
    try std.testing.expect(!scroll.scrollBy(&tree, window, target, .{ 0, -1 }));
    try std.testing.expect(!scroll.scrollTo(&tree, window, target, .{ 0, std.math.nan(f32) }));
    try std.testing.expectEqual([2]f32{ 0, 0 }, state.offset);

    state.offset = .{ 20, 500 }; // A later layout can shrink the maximum.
    const snapshot = scroll.resolve(&tree, window, target).?;
    try std.testing.expectEqual([2]f32{ 0, 200 }, snapshot.offset);
    try std.testing.expectEqual([2]f32{ 20, 500 }, state.offset);
    try std.testing.expect(scroll.scrollTo(&tree, window, target, snapshot.offset));
    try std.testing.expectEqual(snapshot.offset, state.offset);
}

// Finite deltas can overflow f32 when added, but the bounded result stays finite.
test "api-w15 scrollBy saturates without intermediate float overflow" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    const maximum = std.math.floatMax(f32);
    var state: widget.ScrollState = .{
        .offset = .{ 0, maximum * 0.75 },
        .max_offset = .{ 0, maximum },
    };
    try appendScroller(&tree, outer_id, .root, outer_key, &state, .vertical, .{ 80, 80 }, .{ 80, maximum });
    try std.testing.expect(scroll.scrollBy(&tree, window, handle(outer_key), .{ 0, maximum * 0.75 }));
    try std.testing.expectEqual([2]f32{ 0, maximum }, state.offset);
    try std.testing.expect(!scroll.scrollBy(&tree, window, handle(outer_key), .{ 0, maximum }));
}

// A durable key resolves in this tree only; dense frame IDs and retired generations do not.
test "api-w15 scroll handle rejects cross-window retired and non-scroll nodes" {
    var old_tree = widget.WidgetTree.init(std.testing.allocator);
    defer old_tree.deinit();
    var state: widget.ScrollState = .{ .max_offset = .{ 0, 120 } };
    try appendScroller(&old_tree, outer_id, .root, outer_key, &state, .vertical, .{ 80, 80 }, .{ 80, 200 });
    var cross = handle(outer_key);
    cross.window = 43;
    try std.testing.expect(scroll.resolve(&old_tree, window, cross) == null);
    try std.testing.expect(!scroll.scrollBy(&old_tree, window, cross, .{ 0, 20 }));

    var current = widget.WidgetTree.init(std.testing.allocator);
    defer current.deinit();
    const recycled: WidgetId = .{ .owner = 10, .slot = 1, .generation = 2 };
    try appendScroller(&current, outer_id, .root, recycled, &state, .vertical, .{ 80, 80 }, .{ 80, 200 });
    try std.testing.expect(scroll.resolve(&current, window, handle(outer_key)) == null);
    try std.testing.expect(!scroll.scrollTo(&current, window, handle(outer_key), .{ 0, 50 }));
    try std.testing.expectEqual([2]f32{ 0, 0 }, state.offset);

    try current.appendNode(.{
        .id = inner_id,
        .widget_id = inner_key,
        .kind = .{ .spacer = .{} },
        .parent = outer_id,
    });
    try std.testing.expect(scroll.resolve(&current, window, handle(inner_key)) == null);
    try std.testing.expect(!scroll.scrollBy(&current, window, handle(inner_key), .{ 0, 10 }));

    current.node(outer_id).?.style.visibility = .hidden;
    try std.testing.expect(scroll.resolve(&current, window, handle(recycled)) == null);
    try std.testing.expect(!scroll.scrollBy(&current, window, handle(recycled), .{ 0, 10 }));
    current.node(outer_id).?.style.visibility = .visible;
    current.node(outer_id).?.style.display = .none;
    try std.testing.expect(scroll.resolve(&current, window, handle(recycled)) == null);
}

// Reveal uses unscrolled client coordinates; nearest avoids unnecessary motion.
test "api-w15 scroll reveal aligns both axes and clamps oversized targets" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    var state: widget.ScrollState = .{ .max_offset = .{ 300, 240 } };
    try appendScroller(&tree, outer_id, .root, outer_key, &state, .both, .{ 100, 60 }, .{ 400, 300 });
    const target = handle(outer_key);
    const rect: widget.Rect = .{ .x = 120, .y = 160, .w = 20, .h = 20 };
    try std.testing.expect(scroll.revealRect(&tree, window, target, rect, .nearest));
    try std.testing.expectEqual([2]f32{ 40, 120 }, state.offset);
    try std.testing.expect(!scroll.revealRect(&tree, window, target, rect, .nearest));
    try std.testing.expect(scroll.revealRect(&tree, window, target, rect, .center));
    try std.testing.expectEqual([2]f32{ 80, 140 }, state.offset);
    try std.testing.expect(scroll.revealRect(&tree, window, target, rect, .bottom));
    try std.testing.expectEqual([2]f32{ 40, 120 }, state.offset);
    try std.testing.expect(scroll.revealRect(&tree, window, target, rect, .top));
    try std.testing.expectEqual([2]f32{ 120, 160 }, state.offset);
    try std.testing.expect(!scroll.revealRect(&tree, window, target, .{ .x = 0, .y = 0, .w = -1, .h = 10 }, .top));
    try std.testing.expectEqual([2]f32{ 120, 160 }, state.offset);
    try std.testing.expect(!scroll.revealRect(
        &tree,
        window,
        target,
        .{ .x = 0, .y = 0, .w = 400, .h = 300 },
        .nearest,
    ));
    try std.testing.expect(scroll.revealRect(
        &tree,
        window,
        target,
        .{ .x = 1000, .y = 1000, .w = 30, .h = 30 },
        .bottom,
    ));
    try std.testing.expectEqual([2]f32{ 300, 240 }, state.offset);
}

// Real layout computes content (including padding) independently of its client box.
test "api-w15 scroll snapshot reflects laid-out content and scrollbar viewport" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    var state: widget.ScrollState = .{};
    try tree.appendNode(.{
        .id = inner_id,
        .kind = .{ .spacer = .{} },
        .parent = outer_id,
        .style = .{
            .display = .block,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .length = 120 }, .height = .{ .length = 200 } },
        },
    });
    try tree.appendNode(.{
        .id = outer_id,
        .widget_id = outer_key,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{
            .display = .flow_root,
            .box_sizing = .border_box,
            .size = .{ .width = .{ .length = 100 }, .height = .{ .length = 60 } },
            .border_inset = .{
                .top = .{ .length = 4 },
                .right = .{ .length = 3 },
                .bottom = .{ .length = 1 },
                .left = .{ .length = 2 },
            },
            .padding_inset = .{
                .top = .{ .length = 3 },
                .right = .{ .length = 7 },
                .bottom = .{ .length = 6 },
                .left = .{ .length = 5 },
            },
            .overflow = .{ .width = .visible, .height = .scroll },
            .scrollbar_width = 12,
        },
        .scroll = .{ .state = &state, .axis = .vertical },
    });
    try tree.appendChild(outer_id, inner_id);
    try layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 100, .height = 60 },
        .measure = null,
    });
    const snapshot = scroll.resolve(&tree, window, handle(outer_key)).?;
    try std.testing.expectEqual([2]f32{ 83, 55 }, snapshot.viewport);
    try std.testing.expectEqual([2]f32{ 132, 209 }, snapshot.content);
    try std.testing.expectEqual([2]f32{ 0, 154 }, snapshot.max_offset);
    try std.testing.expectEqual([2]f32{ 0, 0 }, snapshot.offset);
}

// Each stable handle mutates its own state even when scrollers are nested.
test "api-w15 nested scrollers move independently" {
    var tree = widget.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    var outer_state: widget.ScrollState = .{ .max_offset = .{ 0, 350 } };
    var inner_state: widget.ScrollState = .{ .max_offset = .{ 0, 150 } };
    try appendScroller(&tree, inner_id, outer_id, inner_key, &inner_state, .vertical, .{ 80, 50 }, .{ 80, 200 });
    try appendScroller(&tree, outer_id, .root, outer_key, &outer_state, .vertical, .{ 100, 100 }, .{ 100, 450 });
    try tree.appendChild(outer_id, inner_id);
    try std.testing.expect(scroll.scrollBy(&tree, window, handle(inner_key), .{ 0, 60 }));
    try std.testing.expectEqual([2]f32{ 0, 60 }, inner_state.offset);
    try std.testing.expectEqual([2]f32{ 0, 0 }, outer_state.offset);
    try std.testing.expect(scroll.revealRect(
        &tree,
        window,
        handle(outer_key),
        .{ .x = 0, .y = 300, .w = 40, .h = 20 },
        .nearest,
    ));
    try std.testing.expectEqual([2]f32{ 0, 220 }, outer_state.offset);
    try std.testing.expectEqual([2]f32{ 0, 60 }, inner_state.offset);
}

// The same key resolves after publication even when its dense ID and state change.
test "api-w15 stable scroll handle targets the rebuilt committed tree" {
    var retired = widget.WidgetTree.init(std.testing.allocator);
    defer retired.deinit();
    var current = widget.WidgetTree.init(std.testing.allocator);
    defer current.deinit();
    var prior_state: widget.ScrollState = .{ .max_offset = .{ 0, 100 } };
    var next_state: widget.ScrollState = .{ .max_offset = .{ 0, 300 } };
    try appendScroller(&retired, outer_id, .root, outer_key, &prior_state, .vertical, .{ 100, 80 }, .{ 100, 180 });
    const rebuilt_id: FrameNodeId = @fromBackingInt(@intCast(99));
    try appendScroller(&current, rebuilt_id, .root, outer_key, &next_state, .vertical, .{ 100, 80 }, .{ 100, 380 });
    const stable = handle(outer_key);
    try std.testing.expectEqual([2]f32{ 0, 300 }, scroll.resolve(&current, window, stable).?.max_offset);
    try std.testing.expect(scroll.scrollBy(&current, window, stable, .{ 0, 250 }));
    try std.testing.expectEqual([2]f32{ 0, 250 }, next_state.offset);
    try std.testing.expectEqual([2]f32{ 0, 0 }, prior_state.offset);

    const hidden_parent: FrameNodeId = @fromBackingInt(@intCast(100));
    try current.appendNode(.{
        .id = hidden_parent,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{ .visibility = .hidden },
    });
    current.node(rebuilt_id).?.parent = hidden_parent;
    try std.testing.expect(scroll.resolve(&current, window, stable) == null);
    try std.testing.expect(!scroll.scrollTo(&current, window, stable, .{ 0, 0 }));
    try std.testing.expectEqual([2]f32{ 0, 250 }, next_state.offset);
}

test "api-w15 App scrolls a keyed viewport across committed frames" {
    const App = @import("app.zig").App;
    const Session = @import("session.zig").Session;
    const DrawCtx = @import("drawctx.zig").DrawCtx;
    const ComponentId = @import("key.zig").ComponentId;
    const ComponentKey = @import("key.zig").ComponentKey;
    const View = struct {
        const Self = @This();
        state: *widget.ScrollState,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{
                .key = ComponentKey{ .static = "viewport" },
                .width = 100,
                .height = 60,
                .scroll_state = self.state,
                .overflow = .{ .width = .hidden, .height = .scroll },
            });
            _ = try ctx.spacer(.{ .width = 100, .height = 260, .shrink = 0 });
            ctx.pop();
        }
    };
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var state: widget.ScrollState = .{};
    var view: View = .{ .state = &state };
    try app.mountRoot(View, &view);
    _ = (try app.handle(.{ .frame = .{ .tick = 1, .time_ms = 0 } })).?;
    _ = try session.takeRedraw(app.window);
    const id = app.widgetIdForKey(ComponentId.root, .{ .static = "viewport" }) orelse
        return error.MissingScrollIdentity;
    const stable = app.scrollHandle(id) orelse return error.MissingScrollViewport;
    try std.testing.expectEqual(@as(f32, 200), app.scrollSnapshot(stable).?.max_offset[1]);
    try std.testing.expect(try app.scrollTo(stable, .{ 0, 80 }));
    try std.testing.expectEqual(@as(f32, 80), state.offset[1]);
    try std.testing.expect(try session.takeRedraw(app.window));
    try std.testing.expect(!try app.scrollTo(stable, .{ 0, 80 }));
    try std.testing.expect(!(try session.takeRedraw(app.window)));
    _ = (try app.handle(.{ .frame = .{ .tick = 2, .time_ms = 16 } })).?;
    try std.testing.expectEqual(@as(f32, 80), app.scrollSnapshot(stable).?.offset[1]);
}
