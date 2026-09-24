//! Programmatic scrolling against a window's current committed widget tree.
const std = @import("std");
const widget = @import("widget.zig");
const WidgetId = @import("id.zig").WidgetId;
const WidgetTree = widget.WidgetTree;

/// Store this value across frames, never a pointer to a per-frame node or tree.
pub const Handle = struct {
    window: u64,
    widget: WidgetId,
};

/// Laid-out sizes and bounded scroll position in logical pixels, x then y.
/// Viewport is the client box (border and reserved scrollbar gutter excluded);
/// content includes padding. Reading a snapshot does not change ScrollState.
pub const Snapshot = struct {
    viewport: [2]f32,
    content: [2]f32,
    offset: [2]f32,
    max_offset: [2]f32,
};

/// On x, top/bottom mean left/right. Nearest keeps an already visible rect still.
pub const Alignment = enum { top, center, bottom, nearest };

const Target = struct {
    node: *const widget.WidgetNode,
    state: *widget.ScrollState,
    max_offset: [2]f32,
};

/// The caller must pass the current *committed* tree and its App.window.
/// Missing, retired, foreign-window, hidden, and non-scroll handles fail closed.
pub fn resolve(tree: *const WidgetTree, current_window: u64, handle: Handle) ?Snapshot {
    const target = resolveCurrent(tree, current_window, handle) orelse return null;
    const viewport = clientViewport(target.node) orelse return null;
    const content: [2]f32 = .{
        target.node.layout_content_size.width,
        target.node.layout_content_size.height,
    };
    if (!finitePair(content) or content[0] < 0 or content[1] < 0) return null;
    return .{
        .viewport = viewport,
        .content = content,
        .offset = boundedOffset(target),
        .max_offset = target.max_offset,
    };
}

/// Set a logical pixel offset. Disabled axes are fixed at zero. Returns true
/// only when ScrollState changes, so the App can request a frame on demand.
pub fn scrollTo(
    tree: *WidgetTree,
    current_window: u64,
    handle: Handle,
    offset: [2]f32,
) bool {
    if (!finitePair(offset)) return false;
    const target = resolveCurrent(tree, current_window, handle) orelse return false;
    return setOffsets(target, .{ offset[0], offset[1] });
}

/// Add a logical pixel delta to the clamped current position. Use f64 for the
/// sum before clamping so even two finite f32 values cannot overflow.
pub fn scrollBy(
    tree: *WidgetTree,
    current_window: u64,
    handle: Handle,
    delta: [2]f32,
) bool {
    if (!finitePair(delta)) return false;
    const target = resolveCurrent(tree, current_window, handle) orelse return false;
    const offset = boundedOffset(target);
    return setOffsets(target, .{
        @as(f64, offset[0]) + @as(f64, delta[0]),
        @as(f64, offset[1]) + @as(f64, delta[1]),
    });
}

/// Reveal a rectangle in this scroller's *unscrolled client coordinates*.
/// The rectangle is not a screen-space box and must have finite, nonnegative
/// dimensions. It does not scroll any ancestors or descendant scrollers.
pub fn revealRect(
    tree: *WidgetTree,
    current_window: u64,
    handle: Handle,
    rect: widget.Rect,
    alignment: Alignment,
) bool {
    if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or
        !std.math.isFinite(rect.w) or !std.math.isFinite(rect.h) or
        rect.w < 0 or rect.h < 0) return false;
    const target = resolveCurrent(tree, current_window, handle) orelse return false;
    const viewport = clientViewport(target.node) orelse return false;
    const offset = boundedOffset(target);
    return setOffsets(target, .{
        alignedOffset(rect.x, rect.w, viewport[0], offset[0], alignment),
        alignedOffset(rect.y, rect.h, viewport[1], offset[1], alignment),
    });
}

fn resolveCurrent(tree: *const WidgetTree, current_window: u64, handle: Handle) ?Target {
    if (handle.window != current_window) return null;
    const id = tree.frameNode(handle.widget) orelse return null;
    const node = tree.nodeConst(id) orelse return null;
    if (node.layout_hidden or !widget.isVisible(tree, id)) return null;
    const spec = node.scroll orelse return null;
    if (!finitePair(spec.state.max_offset)) return null;
    const max_offset: [2]f32 = switch (spec.axis) {
        .horizontal => .{ @max(0, spec.state.max_offset[0]), 0 },
        .vertical => .{ 0, @max(0, spec.state.max_offset[1]) },
        .both => .{ @max(0, spec.state.max_offset[0]), @max(0, spec.state.max_offset[1]) },
    };
    return .{
        .node = node,
        .state = spec.state,
        .max_offset = max_offset,
    };
}

fn clientViewport(node: *const widget.WidgetNode) ?[2]f32 {
    if (!std.math.isFinite(node.rect.w) or !std.math.isFinite(node.rect.h) or
        node.rect.w < 0 or node.rect.h < 0) return null;
    if (!std.math.isFinite(node.style.scrollbar_width) or
        node.style.scrollbar_width < 0) return null;
    const edges = widget.geometryBoxEdges(node, node.rect.w);
    const gutter = node.style.scrollbarGutter();
    const viewport: [2]f32 = .{
        @max(0, node.rect.w - edges.border.left - edges.border.right -
            gutter.left - gutter.right),
        @max(0, node.rect.h - edges.border.top - edges.border.bottom -
            gutter.top - gutter.bottom),
    };
    if (!finitePair(viewport)) return null;
    return viewport;
}

fn boundedOffset(target: Target) [2]f32 {
    return .{
        clampOffset(target.state.offset[0], target.max_offset[0]),
        clampOffset(target.state.offset[1], target.max_offset[1]),
    };
}

fn finitePair(values: [2]f32) bool {
    return std.math.isFinite(values[0]) and std.math.isFinite(values[1]);
}

fn clampOffset(value: f32, maximum: f32) f32 {
    if (!std.math.isFinite(value)) return 0;
    return std.math.clamp(value, 0, maximum);
}

fn setOffsets(target: Target, desired: [2]f64) bool {
    const bounds = target.max_offset;
    const offset: [2]f32 = .{
        @floatCast(std.math.clamp(desired[0], 0, @as(f64, bounds[0]))),
        @floatCast(std.math.clamp(desired[1], 0, @as(f64, bounds[1]))),
    };
    const old = target.state.offset;
    if (old[0] == offset[0] and old[1] == offset[1]) return false;
    target.state.offset = offset;
    return true;
}

fn alignedOffset(start: f32, length: f32, viewport: f32, offset: f32, alignment: Alignment) f64 {
    const first: f64 = start;
    const last = first + @as(f64, length);
    const visible: f64 = offset;
    const extent: f64 = viewport;
    return switch (alignment) {
        .top => first,
        .center => first + (@as(f64, length) - extent) / 2,
        .bottom => last - extent,
        .nearest => if (first < visible and last > visible + extent)
            visible
        else if (first < visible)
            first
        else if (last > visible + extent)
            last - extent
        else
            visible,
    };
}
