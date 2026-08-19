//! v7 headless output — FrameOutput + JSON serialization.
//! Per the prototype spec (notes/v7-prototype-spec.md §8).
//!
//! The JSON document produced by `treeToJson` is a **top-level array** of
//! node objects, one per tree node in append (post-order) order. An empty
//! tree serializes as `[]`.
//!
//! Node object shape — kind-specific fields are omitted when absent:
//!   {"id":N,"kind":"column","parent":N,"rect":{"x":..,"y":..,"w":..,"h":..},
//!    "children":[ids],"gap":..,"label":..,"value":..}
//!   - column/row:   "children" (array of child ids) and "gap"
//!   - label/button: "label"
//!   - slider:       "label" and "value"
//!   - spacer:       no extra fields
//! All strings are JSON-escaped (\" \\ \n \r \t \uXXXX for control chars);
//! user text is never emitted raw.

const std = @import("std");
const tracy = @import("tracy");

const Id = @import("id.zig").Id;
const widget = @import("widget.zig");
const Rect = widget.Rect;
const Size = @import("widget.zig").Size;
const WidgetTree = @import("widget.zig").WidgetTree;
const WidgetNode = @import("widget.zig").WidgetNode;
const DrawCtx = @import("drawctx.zig").DrawCtx;
const MeasureFn = @import("flex.zig").MeasureFn;
const layoutWith = @import("flex.zig").layoutWith;
const Event = @import("event.zig").Event;
const Key = @import("event.zig").Key;
const KeyEvent = @import("event.zig").KeyEvent;
const MouseButton = @import("event.zig").MouseButton;
const input = @import("input.zig");

/// One frame of output: the frame index plus the serialized widget tree.
pub const FrameOutput = struct {
    frame_number: u32,
    /// The driver's clock at this frame (from the .frame event).
    time_ms: u64,
    /// JSON document, allocated with the allocator passed to `treeToJson`
    /// (App uses the gpa). Null when the App's serialize_json flag is off
    /// (the windowed/frames modes don't need it). Caller frees it with
    /// that allocator.
    json: ?[]const u8 = null,
    /// This frame's widget tree. App double-buffers its frame arenas: the
    /// pointer stays valid until the frame AFTER next (the arena is reset
    /// by the frame after that), so the presented tree can be read while
    /// the next frame is being built.
    tree: *const WidgetTree,
    /// The previous frame's tree, same node ids (same draw order). Valid
    /// until the next frame() call; null on the first frame. Enables
    /// id-keyed diffing: dirty flags, retained layout, hitbox carry-over.
    prev_tree: ?*const WidgetTree,
    /// The node under the driver's cursor (the hover outline target).
    hover: ?Id,
    /// The keyboard-focus target (focus ring) — from the driver's keys.
    focus: ?Id,
    /// The button currently held down (pressed visual state).
    pressed: ?Id,
    /// Eased 0..1 visual states, driven by the driver clock: press_alpha
    /// ramps up while a button is held (eased press-in), hover_alpha
    /// ramps toward 1 while the cursor is over a node. Renderer-only —
    /// the headless dump ignores them.
    press_alpha: f32 = 0,
    hover_alpha: f32 = 0,
};

/// Serialize the tree as a JSON array of node objects (see the file doc
/// comment for the shape). The returned slice is allocator-owned; the
/// caller frees it with `allocator`.
/// Optional geometry diagnostics for headless tree JSON.
pub const TreeJsonOptions = struct {
    include_absolute: bool = false,
    include_visual: bool = false,
};

/// Serialize the tree with optional absolute and visual border rectangles.
pub fn treeToJsonWith(
    allocator: std.mem.Allocator,
    tree: *const WidgetTree,
    options: TreeJsonOptions,
) ![]u8 {
    const zone = tracy.Zone.begin(.{ .name = "treeToJsonWith", .src = @src() });
    defer zone.end();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    try w.writeByte('[');
    for (tree.nodes.items, 0..) |*node, i| {
        if (i != 0) try w.writeByte(',');
        try writeNode(w, tree, node, options);
    }
    try w.writeByte(']');
    return out.toOwnedSlice();
}

/// Serialize the tree as JSON without optional geometry diagnostics.
pub fn treeToJson(allocator: std.mem.Allocator, tree: *const WidgetTree) ![]u8 {
    return treeToJsonWith(allocator, tree, .{});
}

/// Parse one event from the headless driver's JSON-lines protocol
/// (`--sim`). Shapes:
///   {"type":"frame","tick":1,"time_ms":0}
///   {"type":"resize","width":900,"height":700}
///   {"type":"mouse_move","x":12.5,"y":30.0}
///   {"type":"mouse_wheel","x":12.5,"y":30.0,"delta_x":-1,"delta_y":2}
///   {"type":"mouse_leave"}
///   {"type":"mouse_down","button":"left","x":..,"y":..}
///   {"type":"mouse_up","button":"left","x":..,"y":..}
///
/// Never panics on malformed input: every field access is checked and
/// returns an `EventParseError` (MissingField / WrongType / BadNumber /
/// UnknownEvent / UnknownKey) instead of unwrapping. JSON syntax errors
/// from the parser itself propagate as-is.
pub const EventParseError = error{
    /// A required field (e.g. "type", "tick", "x") is absent.
    MissingField,
    /// A field is present but holds the wrong JSON type (e.g. a float
    /// where an integer was required, or a string where a number was).
    WrongType,
    /// A numeric field holds a number out of range for its target (e.g.
    /// a negative tick, or a non-numeric value where a number was
    /// required).
    BadNumber,
    /// The "type" value matches no known event.
    UnknownEvent,
    /// A key event names an unknown key.
    UnknownKey,
};

pub fn eventFromJson(allocator: std.mem.Allocator, line: []const u8) !Event {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    // Never unwrap: a non-object line (array, string, number) is a
    // malformed event, not a crash.
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.WrongType,
    };
    const kind = try objString(obj, "type");

    if (std.mem.eql(u8, kind, "frame")) {
        return .{ .frame = .{
            .tick = try objUint(u32, obj, "tick"),
            .time_ms = try objUint(u64, obj, "time_ms"),
        } };
    }
    if (std.mem.eql(u8, kind, "resize")) {
        return .{ .resize = .{
            .width = @as(f32, @floatCast(try objNumber(obj, "width"))),
            .height = @as(f32, @floatCast(try objNumber(obj, "height"))),
        } };
    }
    if (std.mem.eql(u8, kind, "mouse_move")) {
        return .{ .mouse_move = .{
            .x = @as(f32, @floatCast(try objNumber(obj, "x"))),
            .y = @as(f32, @floatCast(try objNumber(obj, "y"))),
        } };
    }
    if (std.mem.eql(u8, kind, "mouse_wheel")) {
        return .{ .mouse_wheel = .{
            .x = @as(f32, @floatCast(try objNumber(obj, "x"))),
            .y = @as(f32, @floatCast(try objNumber(obj, "y"))),
            .delta_x = @as(f32, @floatCast(try objNumber(obj, "delta_x"))),
            .delta_y = @as(f32, @floatCast(try objNumber(obj, "delta_y"))),
        } };
    }
    if (std.mem.eql(u8, kind, "mouse_leave")) return .mouse_leave;
    if (std.mem.eql(u8, kind, "key_down") or std.mem.eql(u8, kind, "key_up")) {
        const key_name = try objString(obj, "key");
        const key: Key = if (std.mem.eql(u8, key_name, "tab"))
            .tab
        else if (std.mem.eql(u8, key_name, "enter"))
            .enter
        else if (std.mem.eql(u8, key_name, "space"))
            .space
        else if (std.mem.eql(u8, key_name, "escape"))
            .escape
        else if (std.mem.eql(u8, key_name, "left"))
            .left
        else if (std.mem.eql(u8, key_name, "right"))
            .right
        else if (std.mem.eql(u8, key_name, "up"))
            .up
        else if (std.mem.eql(u8, key_name, "down"))
            .down
        else if (std.mem.eql(u8, key_name, "home"))
            .home
        else if (std.mem.eql(u8, key_name, "end"))
            .end
        else
            return error.UnknownKey;
        // A missing or non-bool "shift" is treated as false (lenient), so
        // key events never crash on an optional field.
        const shift = if (obj.get("shift")) |s| s == .bool and s.bool else false;
        const ev: KeyEvent = .{ .key = key, .shift = shift };
        return if (std.mem.eql(u8, kind, "key_down"))
            .{ .key_down = ev }
        else
            .{ .key_up = ev };
    }
    if (std.mem.eql(u8, kind, "mouse_down") or std.mem.eql(u8, kind, "mouse_up")) {
        const button_name = try objString(obj, "button");
        const button: MouseButton = if (std.mem.eql(u8, button_name, "right"))
            .right
        else if (std.mem.eql(u8, button_name, "middle"))
            .middle
        else
            .left;
        const x: f32 = @floatCast(try objNumber(obj, "x"));
        const y: f32 = @floatCast(try objNumber(obj, "y"));
        return if (std.mem.eql(u8, kind, "mouse_down"))
            .{ .mouse_down = .{ .button = button, .x = x, .y = y } }
        else
            .{ .mouse_up = .{ .button = button, .x = x, .y = y } };
    }
    return error.UnknownEvent;
}

/// Checked field access: a missing field is an error, never an unwrap.
fn objField(obj: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return obj.get(name) orelse error.MissingField;
}

/// String field; a non-string value is `error.WrongType`.
fn objString(obj: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const v = try objField(obj, name);
    return switch (v) {
        .string => |s| s,
        else => error.WrongType,
    };
}

/// Integer field; a non-integer value (e.g. a float tick) is
/// `error.WrongType`.
fn objInteger(obj: std.json.ObjectMap, name: []const u8) !i64 {
    const v = try objField(obj, name);
    return switch (v) {
        .integer => |i| i,
        else => error.WrongType,
    };
}

/// Unsigned integer field with a range check: negative or over-max values
/// are `error.BadNumber`, so the `@intCast` below can never panic.
fn objUint(comptime T: type, obj: std.json.ObjectMap, name: []const u8) !T {
    const i = try objInteger(obj, name);
    if (i < 0 or i > std.math.maxInt(T)) return error.BadNumber;
    return @intCast(i);
}

/// Number field (int or float); a non-numeric value is `error.BadNumber`
/// (via `num` — which never hits `unreachable`).
fn objNumber(obj: std.json.ObjectMap, name: []const u8) !f64 {
    return num(try objField(obj, name));
}

const NodeView = struct {
    id: u32,
    kind: []const u8,
    parent: u32,
    rect: RectView,
    abs_rect: ?RectView = null,
    vis_rect: ?RectView = null,
    children: ?[]const u32 = null, // containers
    gap: ?f32 = null, // column/row
    label: ?[]const u8 = null, // label/button/slider
    accessible_label: ?[]const u8 = null, // button semantic label
    visual_label: ?[]const u8 = null, // slider visible label override
    value: ?f32 = null, // slider
};

const RectView = struct { x: f32, y: f32, w: f32, h: f32 };

fn writeNode(
    w: *std.Io.Writer,
    tree: *const WidgetTree,
    node: *const WidgetNode,
    options: TreeJsonOptions,
) !void {
    // WidgetNode.children holds a fixed [32]Id slot array (widget.zig cap);
    // project it to a plain u32 slice for the view.
    var child_ids: [32]u32 = undefined;
    var child_count: usize = 0;
    for (node.children.items[0..node.children.len]) |cid| {
        child_ids[child_count] = cid.index();
        child_count += 1;
    }

    const is_container = switch (node.kind) {
        .column, .row => true,
        else => false,
    };
    const abs_rect = if (options.include_absolute)
        rectView(widget.absoluteRect(tree, node.id))
    else
        null;
    const vis_rect = if (options.include_visual)
        rectView(widget.visualBorderRect(tree, node.id))
    else
        null;
    const view: NodeView = .{
        .id = node.id.index(),
        .kind = @tagName(node.kind),
        .parent = node.parent.index(),
        .rect = .{ .x = node.rect.x, .y = node.rect.y, .w = node.rect.w, .h = node.rect.h },
        .abs_rect = abs_rect,
        .vis_rect = vis_rect,
        .children = if (is_container) child_ids[0..child_count] else null,
        .gap = switch (node.kind) {
            .column => |c| c.gap,
            .row => |r| r.gap,
            else => null,
        },
        .label = switch (node.kind) {
            .label => |l| l.text,
            .button => |b| b.label,
            .slider => |s| s.label,
            else => null,
        },
        .accessible_label = switch (node.kind) {
            .button => |b| b.accessible_label,
            else => null,
        },
        .visual_label = switch (node.kind) {
            .slider => |s| s.visual_label,
            else => null,
        },
        .value = switch (node.kind) {
            .slider => |s| s.value.*,
            else => null,
        },
    };
    try std.json.Stringify.value(view, .{ .emit_null_optional_fields = false }, w);
}

fn rectView(r: Rect) RectView {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

/// ── Offscreen layout verification (CPU only — no GPU, no display) ────────
///
/// renderAscii paints the laid-out tree into a character map (2px per char,
/// both axes) and verifyLayout checks structural invariants. Together with
/// treeToJson (which already carries every rect) this is the full headless
/// verification path: layout → inspect → assert, deterministically.
///
/// Map glyphs: containers '.' fill, buttons '#' fill, label/button text is
/// drawn as its characters at the layout positions, sliders '-' with the
/// thumb 'O' at the value fraction, spacer nothing, hover '@' border.
/// Scale: map chars per layout pixel (2px per char both axes).
const map_px = 2;

/// Render the layout as an ASCII map, `hover` gets an '@' border. The
/// returned slice is allocator-owned (caller frees). Bounds = the union of
/// all node visual border rects, so scroll offsets are reflected in the map.
pub fn renderAscii(allocator: std.mem.Allocator, tree: *const WidgetTree, hover: ?Id) ![]u8 {
    // Bounds from the union of all VISUAL border rects. Visual origins
    // resolve relative boxes and subtract ancestor scroll offsets.
    var min_x: f32 = std.math.inf(f32);
    var min_y: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    var max_y: f32 = -std.math.inf(f32);
    for (tree.nodes.items) |*n| {
        const r = widget.visualBorderRect(tree, n.id);
        if (r.w <= 0 or r.h <= 0) continue;
        min_x = @min(min_x, r.x);
        min_y = @min(min_y, r.y);
        max_x = @max(max_x, r.x + r.w);
        max_y = @max(max_y, r.y + r.h);
    }
    if (std.math.isInf(min_x)) return allocator.dupe(u8, "");
    const cols: usize = @as(usize, @intFromFloat(@floor((max_x - min_x) / map_px))) + 1;
    const rows: usize = @as(usize, @intFromFloat(@floor((max_y - min_y) / map_px))) + 1;

    var grid = try allocator.alloc(u8, rows * (cols + 1)); // +1 for '\n'
    @memset(grid, ' ');
    for (0..rows) |r| grid[r * (cols + 1) + cols] = '\n';

    const put = struct {
        fn f(g: []u8, c: usize, x: f32, y: f32, ch: u8) void {
            const cx: usize = @intFromFloat(@floor(x / map_px));
            const cy: usize = @intFromFloat(@floor(y / map_px));
            if (cx >= c) return;
            const line = cy * (c + 1);
            if (line + cx >= g.len - 1) return;
            g[line + cx] = ch;
        }
    }.f;

    // Paint order: parents before children (post-order array reversed).
    var i: usize = tree.nodes.items.len;
    while (i > 0) {
        i -= 1;
        const n = &tree.nodes.items[i];
        const visual = widget.visualBorderRect(tree, n.id);
        var r = visual;
        r.x -= min_x;
        r.y -= min_y;
        if (r.w <= 0 or r.h <= 0) continue;

        switch (n.kind) {
            .column, .row => {
                // Container fill: '.'.
                var y: f32 = r.y;
                while (y < r.y + r.h) : (y += map_px) {
                    var x: f32 = r.x;
                    while (x < r.x + r.w) : (x += map_px) put(grid, cols, x, y, '.');
                }
            },
            .button => {
                var y: f32 = r.y;
                while (y < r.y + r.h) : (y += map_px) {
                    var x: f32 = r.x;
                    while (x < r.x + r.w) : (x += map_px) put(grid, cols, x, y, '#');
                }
                drawText(grid, cols, n.kind.button.label, r);
            },
            .label => |l| drawText(grid, cols, l.text, r),
            .slider => |s| {
                const y: f32 = r.y + r.h / 2;
                var x: f32 = r.x;
                while (x < r.x + r.w) : (x += map_px) put(grid, cols, x, y, '-');
                const frac = std.math.clamp((s.value.* - s.min) / (s.max - s.min), 0, 1);
                put(grid, cols, r.x + frac * r.w, y, 'O');
            },
            .spacer => {},
        }
    }

    // Hover border: '@' along the 4 edges.
    if (hover) |hid| {
        for (tree.nodes.items) |*n| {
            if (n.id != hid) continue;
            const visual = widget.visualBorderRect(tree, n.id);
            var r = visual;
            r.x -= min_x;
            r.y -= min_y;
            // A node smaller than one map cell (2px/char) cannot draw a
            // 4-edge border: the inner edge offsets (r.y + r.h - map_px,
            // r.x + r.w - map_px) would go negative and @intFromFloat
            // would panic (UB in ReleaseFast). Skip it — no border.
            if (r.w < map_px or r.h < map_px) break;
            var x: f32 = r.x;
            while (x < r.x + r.w) : (x += map_px) {
                put(grid, cols, x, r.y, '@');
                put(grid, cols, x, r.y + r.h - map_px, '@');
            }
            var y: f32 = r.y;
            while (y < r.y + r.h) : (y += map_px) {
                put(grid, cols, r.x, y, '@');
                put(grid, cols, r.x + r.w - map_px, y, '@');
            }
            break;
        }
    }

    return grid;
}

/// Draw label text at the layout position: char i at x+6+i*10 (the flex
/// advance estimate), baseline at y + h*0.75 — matching the demo's emitText
/// placement for the map's purpose (rects are the ground truth).
fn drawText(grid: []u8, cols: usize, text: []const u8, r: Rect) void {
    const put = struct {
        fn f(g: []u8, c: usize, x: f32, y: f32, ch: u8) void {
            const cx: usize = @intFromFloat(@floor(x / map_px));
            const cy: usize = @intFromFloat(@floor(y / map_px));
            if (cx >= c) return;
            const line = cy * (c + 1);
            if (line + cx >= g.len - 1) return;
            g[line + cx] = ch;
        }
    }.f;
    const baseline = r.y + r.h * 0.75;
    for (text, 0..) |ch, k| {
        const k_f: f32 = @floatFromInt(@min(k, 1 << 24));
        put(grid, cols, r.x + 6 + k_f * 10, baseline, ch);
    }
}

/// Const-safe node lookup (widget.zig's node() needs a mutable tree).
fn findNodeConst(tree: *const WidgetTree, id: Id) ?*const WidgetNode {
    for (tree.nodes.items) |*n| {
        if (n.id == id) return n;
    }
    return null;
}

fn visualText(node: *const WidgetNode) ?[]const u8 {
    return switch (node.kind) {
        .label => |l| l.text,
        // Button labels are retained only for semantic JSON/hit testing.
        // DrawCtx emits visible text through the generated label child.
        .button => null,
        .slider => widget.sliderVisualLabel(node.kind),
        else => null,
    };
}

/// Deterministic layout fingerprint for golden comparisons: one compact
/// JSON object per node — id, kind, the four rect values, and the box's
/// layout-relevant sides (margin/border/padding, four floats each). The
/// rects are the RAW RELATIVE border boxes (parent-content-relative, see
/// widget.zig Rect), so the fingerprint is stable when a subtree moves as
/// a unit — a parent offset change does not invalidate child rects.
/// border_color and radius are paint-only (they change nothing about the
/// layout), so they are intentionally omitted: two frames with the same
/// geometry but different paint flags hash identically, which is what a
/// golden LAYOUT comparison wants. No labels, no values, no frame
/// counters — two runs with the same layout always produce the same
/// bytes, so it is safe to check in and diff.
pub fn layoutFingerprint(allocator: std.mem.Allocator, tree: *const WidgetTree) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeByte('[');
    for (tree.nodes.items, 0..) |*n, i| {
        if (i != 0) try w.writeByte(',');
        try w.print(
            "{{\"id\":{d},\"kind\":\"{s}\"," ++
                "\"x\":{d:.2},\"y\":{d:.2},\"w\":{d:.2},\"h\":{d:.2}," ++
                "\"margin_top\":{d:.2},\"margin_right\":{d:.2},\"margin_bottom\":{d:.2},\"margin_left\":{d:.2}," ++
                "\"border_top\":{d:.2},\"border_right\":{d:.2},\"border_bottom\":{d:.2},\"border_left\":{d:.2}," ++
                "\"padding_top\":{d:.2},\"padding_right\":{d:.2},\"padding_bottom\":{d:.2},\"padding_left\":{d:.2}}}",
            .{
                n.id.index(),         @tagName(n.kind),
                n.rect.x,             n.rect.y,
                n.rect.w,             n.rect.h,
                n.box.margin.top,     n.box.margin.right,
                n.box.margin.bottom,  n.box.margin.left,
                n.box.border.top,     n.box.border.right,
                n.box.border.bottom,  n.box.border.left,
                n.box.padding.top,    n.box.padding.right,
                n.box.padding.bottom, n.box.padding.left,
            },
        );
    }
    try w.writeByte(']');
    return out.toOwnedSlice();
}

/// Verify layout invariants. Returns a human-readable report: "OK" or one
/// line per violation. `measure` (optional) enables the visual text-fit check —
/// labels, generated button labels, and sliders must fit their measured text extent.
/// `surface` (optional) is the surface size: when non-null, root-level nodes that
/// extend past it are flagged; null skips the bounds check (old behavior).
/// True when the node or any ancestor is layered (z > 0): a layered node
/// paints over siblings by design (the GPU z-sort decides the order), so
/// its overlaps are intentional, not collisions.
fn isLayered(tree: *const WidgetTree, id: Id) bool {
    var cur: ?Id = id;
    while (cur) |cid| {
        const n = tree.nodeConst(cid) orelse return false;
        if (n.box.layer != 0) return true;
        cur = if (n.parent == .root) null else n.parent;
    }
    return false;
}

pub fn verifyLayout(allocator: std.mem.Allocator, tree: *const WidgetTree, measure: ?MeasureFn, surface: ?Size) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    var problems: usize = 0;

    const add = struct {
        fn f(comptime fmt: []const u8, writer: *std.Io.Writer, count: *usize, args: anytype) !void {
            count.* += 1;
            try writer.print(fmt ++ "\n", args);
        }
    }.f;

    const nodes = tree.nodes.items;
    for (nodes) |*n| {
        const r = n.rect;
        if (r.w < 0 or r.h < 0) {
            try add("negative size: id {d} {d}x{d}", w, &problems, .{ n.id.index(), r.w, r.h });
        }

        // Box sides: borders and paddings must not be negative. Margins may
        // be negative (legal CSS — the layer badge's -44 bottom margin is a
        // deliberate layout trick).
        const side_vals = [_]f32{
            n.box.border.top,  n.box.border.right,  n.box.border.bottom,  n.box.border.left,
            n.box.padding.top, n.box.padding.right, n.box.padding.bottom, n.box.padding.left,
        };
        for (side_vals) |v| {
            if (v < -0.001) {
                try add("negative box side: id {d} value {d:.1}", w, &problems, .{ n.id.index(), v });
                break;
            }
        }

        // Children inside their parent's CONTENT box. Node rects are
        // RELATIVE (see widget.zig Rect): a child's rect is positioned
        // against the parent's content box, so only the content size
        // constrains it — the border box does not.
        if (n.parent != .root) {
            const p = findNodeConst(tree, n.parent) orelse {
                try add("missing parent: id {d}", w, &problems, .{n.id.index()});
                continue;
            };
            const pw = @max(
                0,
                p.rect.w - p.box.border.left - p.box.border.right - p.box.padding.left - p.box.padding.right,
            );
            const ph = @max(
                0,
                p.rect.h - p.box.border.top - p.box.border.bottom - p.box.padding.top - p.box.padding.bottom,
            );
            if (r.x < -0.001 or r.y < -0.001 or
                r.x + r.w > pw + 0.001 or r.y + r.h > ph + 0.001)
            {
                try add(
                    "child outside parent: id {d} rect {d:.1},{d:.1} {d:.1}x{d:.1} vs parent content {d:.1}x{d:.1}",
                    w,
                    &problems,
                    .{ n.id.index(), r.x, r.y, r.w, r.h, pw, ph },
                );
            }
        }

        // Sibling overlap (within each container). Strictly-ordered pairs
        // (cid before oid in the children array): each overlap is reported
        // once, not once per ordering.
        const kids = n.children.items[0..n.children.len];
        for (kids, 0..) |cid, ci| {
            const child = findNodeConst(tree, cid) orelse continue;
            if (child.rect.w <= 0 or child.rect.h <= 0) continue;
            for (kids[ci + 1 ..]) |oid| {
                const other = findNodeConst(tree, oid) orelse continue;
                if (other.rect.w <= 0 or other.rect.h <= 0) continue;
                const a = child.rect;
                const b = other.rect;
                const overlap_x = a.x < b.x + b.w - 0.001 and b.x < a.x + a.w - 0.001;
                const overlap_y = a.y < b.y + b.h - 0.001 and b.y < a.y + a.h - 0.001;
                if (overlap_x and overlap_y) {
                    try add(
                        "sibling overlap in id {d}: {d} and {d}",
                        w,
                        &problems,
                        .{ n.id.index(), cid.index(), oid.index() },
                    );
                }
            }
        }

        // Text fits its measured extent.
        if (measure) |m| {
            const text = visualText(n);
            if (text) |t| {
                if (t.len == 0) continue;
                const ms = m(t, n.font_size, n.font_id);
                // flex.zig's measureLeaf adds the node's ACTUAL border +
                // padding (widget.sidesSum) to the content measure; the old
                // +16 baked approximation disagrees whenever they sum to
                // anything else.
                const insets = widget.sidesSum(n.box.border);
                const pads = widget.sidesSum(n.box.padding);
                const need_w = switch (n.kind) {
                    .button => ms.width + insets.w + pads.w,
                    .slider => @max(100, ms.width + insets.w + pads.w),
                    else => ms.width,
                };
                // A positive cap plus clipped rendering intentionally permits
                // measured text to exceed the rect; geometry checks stay
                // independent.
                const text_width_is_bounded = if (n.text_max_width) |max_width|
                    max_width > 0 and (switch (n.text_overflow) {
                        .visible => false,
                        .clip, .ellipsis => true,
                    })
                else
                    false;
                if (!text_width_is_bounded and r.w + 0.001 < need_w) {
                    try add(
                        "text overflow: id {d} '{s}' needs {d:.1} wide, rect {d:.1}",
                        w,
                        &problems,
                        .{ n.id.index(), t, need_w, r.w },
                    );
                }
                if (r.h + 0.001 < ms.height) {
                    try add(
                        "text overflow: id {d} '{s}' needs {d:.1} tall, rect {d:.1}",
                        w,
                        &problems,
                        .{ n.id.index(), t, ms.height, r.h },
                    );
                }
            }
        }

        // Slider value in range.
        switch (n.kind) {
            .slider => |s| {
                if (s.value.* < s.min or s.value.* > s.max) {
                    try add(
                        "slider value out of range: id {d} value {d:.1} not in [{d:.1}, {d:.1}]",
                        w,
                        &problems,
                        .{ n.id.index(), s.value.*, s.min, s.max },
                    );
                }
            },
            else => {},
        }
    }

    // Root-level sibling overlap: the per-node loop above only checks the
    // children of containers, and the root pseudo-container has no node —
    // so root-level siblings were never overlap-checked. A root-level
    // rect is relative to the surface, i.e. already absolute.
    for (nodes, 0..) |*a, ai| {
        if (a.parent != .root) continue;
        if (a.rect.w <= 0 or a.rect.h <= 0) continue;
        for (nodes[ai + 1 ..]) |*b| {
            if (b.parent != .root) continue;
            if (b.rect.w <= 0 or b.rect.h <= 0) continue;
            const ra = widget.absoluteRect(tree, a.id);
            const rb = widget.absoluteRect(tree, b.id);
            const overlap_x = ra.x < rb.x + rb.w - 0.001 and rb.x < ra.x + ra.w - 0.001;
            const overlap_y = ra.y < rb.y + rb.h - 0.001 and rb.y < ra.y + ra.h - 0.001;
            if (overlap_x and overlap_y and !isLayered(tree, a.id) and !isLayered(tree, b.id)) {
                try add("root overlap: {d} and {d}", w, &problems, .{ a.id.index(), b.id.index() });
            }
        }
    }

    // Root-level bounds: a root-level node must fit inside the surface
    // (its rect is relative to the surface). Skipped when surface is null.
    if (surface) |s| {
        for (nodes) |*n| {
            if (n.parent != .root) continue;
            if (n.rect.w <= 0 or n.rect.h <= 0) continue;
            const r = widget.absoluteRect(tree, n.id);
            if (r.x < -0.001 or r.y < -0.001 or
                r.x + r.w > s.width + 0.001 or r.y + r.h > s.height + 0.001)
            {
                try add(
                    "root outside surface: id {d} rect {d:.1},{d:.1} {d:.1}x{d:.1} vs surface {d:.1}x{d:.1}",
                    w,
                    &problems,
                    .{ n.id.index(), r.x, r.y, r.w, r.h, s.width, s.height },
                );
            }
        }
    }

    // Cross-node text overlap: every text-bearing node's text box is its
    // ABSOLUTE CONTENT box (widget.contentRect) — the pure-content measure
    // matches the content box exactly, so that box is where the text draws.
    // Two intersecting boxes are a real collision. Catches the
    // squished-title class — two labels' text colliding even when their
    // rects do not.
    if (measure) |_| {
        const TextBox = struct { id: Id, box: Rect };
        var boxes: std.ArrayList(TextBox) = .empty;
        defer boxes.deinit(allocator);
        for (nodes) |*n| {
            const text = visualText(n);
            if (text == null) continue;
            if (text.?.len == 0) continue;
            if (n.rect.w <= 0 or n.rect.h <= 0) continue;
            try boxes.append(allocator, .{ .id = n.id, .box = widget.contentRect(tree, n.id) });
        }
        // Strictly-ordered pairs (i < j): each overlap is reported once.
        // Ancestor-descendant pairs are skipped: nested text nodes can
        // intentionally share a content box without colliding.
        for (0..boxes.items.len) |i| {
            for (i + 1..boxes.items.len) |j| {
                const a = boxes.items[i].box;
                const b = boxes.items[j].box;
                const overlap_x = a.x < b.x + b.w - 0.001 and b.x < a.x + a.w - 0.001;
                const overlap_y = a.y < b.y + b.h - 0.001 and b.y < a.y + a.h - 0.001;
                if (!(overlap_x and overlap_y)) continue;
                // Ancestor-descendant: walk desc's parent chain up to anc.
                var skip = false;
                var cur = tree.nodeConst(boxes.items[j].id).?.parent;
                while (cur != .root) {
                    if (cur == boxes.items[i].id) {
                        skip = true;
                        break;
                    }
                    cur = tree.nodeConst(cur).?.parent;
                }
                if (!skip) {
                    cur = tree.nodeConst(boxes.items[i].id).?.parent;
                    while (cur != .root) {
                        if (cur == boxes.items[j].id) {
                            skip = true;
                            break;
                        }
                        cur = tree.nodeConst(cur).?.parent;
                    }
                }
                if (skip) continue;
                if (isLayered(tree, boxes.items[i].id) or isLayered(tree, boxes.items[j].id)) continue;
                try add(
                    "text overlap: id {d} and id {d}",
                    w,
                    &problems,
                    .{ boxes.items[i].id.index(), boxes.items[j].id.index() },
                );
            }
        }
    }

    if (problems == 0) {
        try w.writeAll("OK\n");
    } else {
        try w.print("{d} problem(s)\n", .{problems});
    }
    return out.toOwnedSlice();
}

/// Parse a JSON number (int or float) back to f64 for comparisons. A
/// non-numeric value is `error.BadNumber` — never `unreachable`.
fn num(v: std.json.Value) !f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => error.BadNumber,
    };
}

test "treeToJson: label text with quotes and backslashes round-trips" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const col: Id = @enumFromInt(2);
    const label_text = "say \"hi\" \\ yo\nnext\tline";
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .kind = .{ .label = .{ .text = label_text } },
        .parent = col,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = col,
        .kind = .{ .column = .{} },
        .parent = .root,
    });
    // Wire the container's children after the appends (post-order).
    tree.node(col).?.children.items[0] = @enumFromInt(1);
    tree.node(col).?.children.len = 1;

    const json = try treeToJson(std.testing.allocator, &tree);
    defer std.testing.allocator.free(json);

    // No raw quote-backslash-quote sequence may appear in the document:
    // the text's quotes must be escaped.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"hi\"") == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);

    const label_node = arr.items[0].object;
    try std.testing.expectEqualStrings("label", label_node.get("kind").?.string);
    try std.testing.expectEqualStrings(label_text, label_node.get("label").?.string);

    const col_node = arr.items[1].object;
    try std.testing.expectEqualStrings("column", col_node.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), col_node.get("children").?.array.items[0].integer);
}

test "treeToJson: kind-specific fields appear only for their kinds" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    var vol: f32 = 0.5;
    const row_id: Id = @enumFromInt(3);
    const col_id: Id = @enumFromInt(4);

    // Post-order: children before their containers.
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .kind = .{ .slider = .{ .label = "vol", .value = &vol, .min = 0, .max = 1 } },
        .parent = row_id,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(2),
        .kind = .{ .button = .{ .label = "go" } },
        .parent = row_id,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = row_id,
        .kind = .{ .row = .{ .gap = 3 } },
        .parent = col_id,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = col_id,
        .kind = .{ .column = .{ .gap = 5 } },
        .parent = .root,
    });
    tree.node(row_id).?.children.items[0] = @enumFromInt(1);
    tree.node(row_id).?.children.items[1] = @enumFromInt(2);
    tree.node(row_id).?.children.len = 2;
    tree.node(col_id).?.children.items[0] = row_id;
    tree.node(col_id).?.children.len = 1;

    const json = try treeToJson(std.testing.allocator, &tree);
    defer std.testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 4), arr.items.len);

    // Slider: label + value, no container fields.
    const slider_node = arr.items[0].object;
    try std.testing.expectEqualStrings("slider", slider_node.get("kind").?.string);
    try std.testing.expectEqualStrings("vol", slider_node.get("label").?.string);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), try num(slider_node.get("value").?), 1e-9);
    try std.testing.expect(slider_node.get("gap") == null);
    try std.testing.expect(slider_node.get("children") == null);

    // Button: label only.
    const button_node = arr.items[1].object;
    try std.testing.expectEqualStrings("button", button_node.get("kind").?.string);
    try std.testing.expectEqualStrings("go", button_node.get("label").?.string);
    try std.testing.expect(button_node.get("value") == null);
    try std.testing.expect(button_node.get("gap") == null);

    // Row container: gap + children.
    const row_node = arr.items[2].object;
    try std.testing.expectEqualStrings("row", row_node.get("kind").?.string);
    try std.testing.expectApproxEqAbs(@as(f64, 3), try num(row_node.get("gap").?), 1e-9);
    const row_children = row_node.get("children").?.array;
    try std.testing.expectEqual(@as(usize, 2), row_children.items.len);
    try std.testing.expectEqual(@as(i64, 1), row_children.items[0].integer);
    try std.testing.expectEqual(@as(i64, 2), row_children.items[1].integer);

    // Column container: gap + children, no label.
    const col_node = arr.items[3].object;
    try std.testing.expectEqualStrings("column", col_node.get("kind").?.string);
    try std.testing.expectApproxEqAbs(@as(f64, 5), try num(col_node.get("gap").?), 1e-9);
    const col_children = col_node.get("children").?.array;
    try std.testing.expectEqual(@as(usize, 1), col_children.items.len);
    try std.testing.expectEqual(@as(i64, 3), col_children.items[0].integer);
    try std.testing.expect(col_node.get("label") == null);
}

test "treeToJson: empty tree serializes as []" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const json = try treeToJson(std.testing.allocator, &tree);
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings("[]", json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.array.items.len);
}

test "eventFromJson: every event shape parses and round-trips its fields" {
    const testing = std.testing;

    const frame = try eventFromJson(testing.allocator, "{\"type\":\"frame\",\"tick\":42,\"time_ms\":1234}");
    try testing.expectEqual(@as(u32, 42), frame.frame.tick);
    try testing.expectEqual(@as(u64, 1234), frame.frame.time_ms);

    const resize = try eventFromJson(testing.allocator, "{\"type\":\"resize\",\"width\":900,\"height\":700}");
    try testing.expectEqual(@as(f32, 900), resize.resize.width);
    try testing.expectEqual(@as(f32, 700), resize.resize.height);

    const move = try eventFromJson(testing.allocator, "{\"type\":\"mouse_move\",\"x\":12.5,\"y\":30.0}");
    try testing.expectEqual(@as(f32, 12.5), move.mouse_move.x);
    try testing.expectEqual(@as(f32, 30), move.mouse_move.y);

    const leave = try eventFromJson(testing.allocator, "{\"type\":\"mouse_leave\"}");
    try testing.expect(leave == .mouse_leave);

    const down = try eventFromJson(testing.allocator, "{\"type\":\"mouse_down\",\"button\":\"left\",\"x\":1,\"y\":2}");
    try testing.expectEqual(MouseButton.left, down.mouse_down.button);
    const up = try eventFromJson(testing.allocator, "{\"type\":\"mouse_up\",\"button\":\"right\",\"x\":3,\"y\":4}");
    try testing.expectEqual(MouseButton.right, up.mouse_up.button);

    try testing.expectError(error.UnknownEvent, eventFromJson(testing.allocator, "{\"type\":\"nope\"}"));
}

test "renderAscii: label text, button fill, slider thumb, hover border" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    var vol: f32 = 0.5;
    const label_id: Id = @enumFromInt(1);
    const button_id: Id = @enumFromInt(2);
    const slider_id: Id = @enumFromInt(3);

    try tree.nodes.append(std.testing.allocator, .{
        .id = label_id,
        .kind = .{ .label = .{ .text = "hi" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 24 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = button_id,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 30, .w = 56, .h = 32 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = slider_id,
        .kind = .{ .slider = .{ .label = "vol", .value = &vol, .min = 0, .max = 1 } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 70, .w = 100, .h = 24 },
    });

    const map = try renderAscii(std.testing.allocator, &tree, button_id);
    defer std.testing.allocator.free(map);

    // Text chars at their layout positions (glyphs are spaced 5 map chars
    // apart — 10px advance at 2px/char — so check chars individually).
    try std.testing.expect(std.mem.indexOf(u8, map, "h") != null);
    try std.testing.expect(std.mem.indexOf(u8, map, "g") != null);
    try std.testing.expect(std.mem.indexOf(u8, map, "o") != null);
    // Button fill.
    try std.testing.expect(std.mem.indexOf(u8, map, "####") != null);
    // Slider thumb at the middle (x = 50px -> char 25).
    const thumb_row = std.mem.indexOf(u8, map, "O") orelse return error.NoThumb;
    const row_start = std.mem.lastIndexOfScalar(u8, map[0..thumb_row], '\n') orelse 0;
    try std.testing.expectEqual(@as(usize, 25), thumb_row - row_start - 1);
    // Hover border on the button's top edge.
    const at = std.mem.indexOf(u8, map, "@") orelse return error.NoHover;
    try std.testing.expect(at > 0);
}

test "renderAscii: empty tree yields an empty map" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const map = try renderAscii(std.testing.allocator, &tree, null);
    defer std.testing.allocator.free(map);
    try std.testing.expectEqual(@as(usize, 0), map.len);
}

test "verifyLayout: clean tree reports OK" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const col: Id = @enumFromInt(10);
    const a: Id = @enumFromInt(11);
    const b: Id = @enumFromInt(12);

    try tree.nodes.append(std.testing.allocator, .{
        .id = a,
        .kind = .{ .label = .{ .text = "a" } },
        .parent = col,
        .rect = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = b,
        .kind = .{ .label = .{ .text = "b" } },
        .parent = col,
        .rect = .{ .x = 0, .y = 20, .w = 20, .h = 20 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = col,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 40 },
    });

    const report = try verifyLayout(std.testing.allocator, &tree, null, null);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.startsWith(u8, report, "OK"));
}

test "verifyLayout: overlap, escape, and out-of-range value are reported" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    var vol: f32 = 5; // out of [0, 1]
    const col: Id = @enumFromInt(20);
    const a: Id = @enumFromInt(21);
    const b: Id = @enumFromInt(22);
    const s: Id = @enumFromInt(23);

    try tree.nodes.append(std.testing.allocator, .{
        .id = a,
        .kind = .{ .label = .{ .text = "a" } },
        .parent = col,
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 20 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = b,
        .kind = .{ .label = .{ .text = "b" } },
        .parent = col,
        .rect = .{ .x = 20, .y = 0, .w = 40, .h = 20 }, // overlaps a
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = s,
        .kind = .{ .slider = .{ .label = "s", .value = &vol, .min = 0, .max = 1 } },
        .parent = col,
        .rect = .{ .x = -5, .y = 100, .w = 100, .h = 24 }, // outside the column
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = col,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
    });
    tree.node(col).?.children.items[0] = a;
    tree.node(col).?.children.items[1] = b;
    tree.node(col).?.children.items[2] = s;
    tree.node(col).?.children.len = 3;

    const report = try verifyLayout(std.testing.allocator, &tree, null, null);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "sibling overlap") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "child outside parent") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "slider value out of range") != null);
    try std.testing.expect(!std.mem.startsWith(u8, report, "OK"));
}

test "layoutFingerprint: deterministic, rects only" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .kind = .{ .label = .{ .text = "dynamic counter: 7" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 148.25, .h = 24 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(2),
        .kind = .{ .button = .{ .label = "go" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 30, .w = 56, .h = 32 },
    });

    const fp = try layoutFingerprint(std.testing.allocator, &tree);
    defer std.testing.allocator.free(fp);

    // Rects only — no label text anywhere in the fingerprint.
    try std.testing.expect(std.mem.indexOf(u8, fp, "dynamic counter") == null);
    try std.testing.expect(std.mem.indexOf(u8, fp, "148.25") != null);
    try std.testing.expect(std.mem.indexOf(u8, fp, "\"kind\":\"button\"") != null);

    // Deterministic: two runs produce identical bytes.
    const fp2 = try layoutFingerprint(std.testing.allocator, &tree);
    defer std.testing.allocator.free(fp2);
    try std.testing.expectEqualStrings(fp, fp2);
}

const fakeMeasure = struct {
    fn f(_: []const u8, _: f32, _: u8) Size {
        return .{ .width = 40, .height = 24 };
    }
}.f;

test "verifyLayout: bounded ellipsis and clip text do not report overflow" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .kind = .{ .label = .{ .text = "ellipsized" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 20, .h = 24 },
        .text_overflow = .ellipsis,
        .text_max_width = 20,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(2),
        .kind = .{ .label = .{ .text = "clipped" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 30, .w = 20, .h = 24 },
        .text_overflow = .clip,
        .text_max_width = 20,
    });

    const report = try verifyLayout(std.testing.allocator, &tree, fakeMeasure, null);
    defer std.testing.allocator.free(report);
    try std.testing.expectEqualStrings("OK\n", report);
}

test "verifyLayout: overlapping text boxes are reported, adjacent are not" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    // Two labels whose text boxes (absolute content boxes) collide: A's
    // box spans [0, 52], B at x 20 spans [20, 72] — the interior overlap
    // is real even though both texts are short.
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .kind = .{ .label = .{ .text = "aaaa" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 52, .h = 24 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(2),
        .kind = .{ .label = .{ .text = "bbbb" } },
        .parent = .root,
        .rect = .{ .x = 20, .y = 0, .w = 52, .h = 24 }, // boxes collide
    });

    const report = try verifyLayout(std.testing.allocator, &tree, fakeMeasure, null);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "text overlap") != null);
}

test "verifyLayout: text boxes that merely touch are not an overlap" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    // A's text box ends at x 52; B starts at x 52 — touching edges are
    // not an interior intersection.
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .kind = .{ .label = .{ .text = "aaaa" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 52, .h = 24 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(2),
        .kind = .{ .label = .{ .text = "bbbb" } },
        .parent = .root,
        .rect = .{ .x = 52, .y = 0, .w = 52, .h = 24 },
    });

    const report = try verifyLayout(std.testing.allocator, &tree, fakeMeasure, null);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.startsWith(u8, report, "OK"));
}

test "treeToJson: rect values round-trip exactly" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const rect: Rect = .{ .x = 12.5, .y = -3.25, .w = 100, .h = 200.75 };
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .kind = .{ .label = .{ .text = "a" } },
        .parent = .root,
        .rect = rect,
    });

    const json = try treeToJson(std.testing.allocator, &tree);
    defer std.testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const r = parsed.value.array.items[0].object.get("rect").?.object;
    try std.testing.expectEqual(@as(f64, 12.5), try num(r.get("x").?));
    try std.testing.expectEqual(@as(f64, -3.25), try num(r.get("y").?));
    try std.testing.expectEqual(@as(f64, 100), try num(r.get("w").?));
    try std.testing.expectEqual(@as(f64, 200.75), try num(r.get("h").?));
}

test "treeToJsonWith: absolute and visual geometry are optional diagnostics" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const parent: Id = @enumFromInt(1);
    const child: Id = @enumFromInt(2);
    try tree.nodes.append(std.testing.allocator, .{
        .id = child,
        .kind = .{ .label = .{ .text = "nested" } },
        .parent = parent,
        .rect = .{ .x = 7, .y = 11, .w = 30, .h = 12 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = parent,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 10, .y = 20, .w = 100, .h = 80 },
        .box = .{
            .border = .{ .left = 2, .top = 3 },
            .padding = .{ .left = 4, .top = 5 },
        },
    });
    tree.node(parent).?.children.items[0] = child;
    tree.node(parent).?.children.len = 1;

    const compact = try treeToJson(std.testing.allocator, &tree);
    defer std.testing.allocator.free(compact);
    var compact_parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        compact,
        .{},
    );
    defer compact_parsed.deinit();
    const compact_child = compact_parsed.value.array.items[0].object;
    try std.testing.expect(compact_child.get("abs_rect") == null);
    try std.testing.expect(compact_child.get("vis_rect") == null);

    const diagnostic = try treeToJsonWith(
        std.testing.allocator,
        &tree,
        .{ .include_absolute = true, .include_visual = true },
    );
    defer std.testing.allocator.free(diagnostic);
    var diagnostic_parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        diagnostic,
        .{},
    );
    defer diagnostic_parsed.deinit();

    const child_view = diagnostic_parsed.value.array.items[0].object;
    const absolute = child_view.get("abs_rect").?.object;
    try std.testing.expectEqual(@as(f64, 23), try num(absolute.get("x").?));
    try std.testing.expectEqual(@as(f64, 39), try num(absolute.get("y").?));
    try std.testing.expectEqual(@as(f64, 30), try num(absolute.get("w").?));
    try std.testing.expectEqual(@as(f64, 12), try num(absolute.get("h").?));

    const visual = child_view.get("vis_rect").?.object;
    try std.testing.expectEqual(@as(f64, 23), try num(visual.get("x").?));
    try std.testing.expectEqual(@as(f64, 39), try num(visual.get("y").?));
    try std.testing.expectEqual(@as(f64, 30), try num(visual.get("w").?));
    try std.testing.expectEqual(@as(f64, 12), try num(visual.get("h").?));
}

test "renderAscii: nested node renders at its absolute position" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    // Root column with padding; button nested at a relative offset. Its
    // absolute origin = col (0,0) + padding (8,8) + rect (5,5) = (13,13).
    const col: Id = @enumFromInt(1);
    const btn: Id = @enumFromInt(2);

    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = col,
        .rect = .{ .x = 5, .y = 5, .w = 40, .h = 24 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = col,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .box = .{ .padding = .{ .left = 8, .top = 8 } },
    });
    tree.node(col).?.children.items[0] = btn;
    tree.node(col).?.children.len = 1;

    const map = try renderAscii(std.testing.allocator, &tree, null);
    defer std.testing.allocator.free(map);

    // Bounds = union of absolute rects (0,0)-(100,100): cols = 100/2+1 =
    // 51, rows = 51. Cell (r,c) sits at r*(51+1)+c.
    const stride: usize = 51 + 1;
    // Button fill begins at absolute (13,13) -> char cell (6,6).
    try std.testing.expectEqual(@as(u8, '#'), map[6 * stride + 6]);
    // The un-offset origin cell (0,0) still holds the column's '.' fill —
    // the button did not paint there.
    try std.testing.expectEqual(@as(u8, '.'), map[0]);
}

test "verifyLayout: nested tree with padding and border verifies OK" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    // Column with border+padding; button fills the content box exactly
    // (content w = 100-4-2-8-6 = 80, h = 60-1-3-8-7 = 41).
    const col: Id = @enumFromInt(1);
    const btn: Id = @enumFromInt(2);

    try tree.nodes.append(std.testing.allocator, .{
        .id = btn,
        .kind = .{ .button = .{ .label = "go" } },
        .parent = col,
        .rect = .{ .x = 0, .y = 0, .w = 80, .h = 40 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = col,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 60 },
        .box = .{
            .border = .{ .top = 1, .right = 2, .bottom = 3, .left = 4 },
            .padding = .{ .top = 8, .right = 6, .bottom = 7, .left = 8 },
        },
    });
    tree.node(col).?.children.items[0] = btn;
    tree.node(col).?.children.len = 1;

    const report = try verifyLayout(std.testing.allocator, &tree, null, null);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.startsWith(u8, report, "OK"));
}

test "verifyLayout: child outside the parent's content box is flagged" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    // Child sits inside the border box (x+w = 95 <= 100) but past the
    // content box (content w = 100-8-8 = 84): the content box constrains.
    const col: Id = @enumFromInt(1);
    const child: Id = @enumFromInt(2);

    try tree.nodes.append(std.testing.allocator, .{
        .id = child,
        .kind = .{ .label = .{ .text = "x" } },
        .parent = col,
        .rect = .{ .x = 85, .y = 0, .w = 10, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = col,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .box = .{ .padding = .{ .left = 8, .right = 8 } },
    });
    tree.node(col).?.children.items[0] = child;
    tree.node(col).?.children.len = 1;

    const report = try verifyLayout(std.testing.allocator, &tree, null, null);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "child outside parent") != null);
    try std.testing.expect(!std.mem.startsWith(u8, report, "OK"));
}

test "verifyLayout: negative box sides are reported" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .kind = .{ .label = .{ .text = "x" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .box = .{ .padding = .{ .top = -2 } },
    });

    const report = try verifyLayout(std.testing.allocator, &tree, null, null);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "negative box side") != null);
    try std.testing.expect(!std.mem.startsWith(u8, report, "OK"));
}

test "eventFromJson: mouse wheel preserves position and signed deltas" {
    const event = try eventFromJson(
        std.testing.allocator,
        "{\"type\":\"mouse_wheel\",\"x\":12.5,\"y\":30,\"delta_x\":-2,\"delta_y\":3.25}",
    );
    const wheel = switch (event) {
        .mouse_wheel => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(f32, 12.5), wheel.x);
    try std.testing.expectEqual(@as(f32, 30), wheel.y);
    try std.testing.expectEqual(@as(f32, -2), wheel.delta_x);
    try std.testing.expectEqual(@as(f32, 3.25), wheel.delta_y);
}

test "eventFromJson: malformed lines return errors, never panic" {
    const testing = std.testing;

    // Non-object line (array).
    try testing.expectError(error.WrongType, eventFromJson(testing.allocator, "[1,2]"));
    // Non-object line (string).
    try testing.expectError(error.WrongType, eventFromJson(testing.allocator, "\"nope\""));
    // Missing type field.
    try testing.expectError(
        error.MissingField,
        eventFromJson(testing.allocator, "{\"tick\":1}"),
    );
    // Float tick where an integer is required.
    try testing.expectError(
        error.WrongType,
        eventFromJson(testing.allocator, "{\"type\":\"frame\",\"tick\":1.5,\"time_ms\":0}"),
    );
    // Negative tick is out of range for u32.
    try testing.expectError(
        error.BadNumber,
        eventFromJson(testing.allocator, "{\"type\":\"frame\",\"tick\":-1,\"time_ms\":0}"),
    );
    // Missing required field (x).
    try testing.expectError(
        error.MissingField,
        eventFromJson(testing.allocator, "{\"type\":\"mouse_move\",\"y\":1}"),
    );
    // Non-numeric where a number is required.
    try testing.expectError(
        error.BadNumber,
        eventFromJson(testing.allocator, "{\"type\":\"mouse_move\",\"x\":\"abc\",\"y\":1}"),
    );
    // Unknown event type.
    try testing.expectError(
        error.UnknownEvent,
        eventFromJson(testing.allocator, "{\"type\":\"nope\"}"),
    );
    // Unknown key name.
    try testing.expectError(
        error.UnknownKey,
        eventFromJson(testing.allocator, "{\"type\":\"key_down\",\"key\":\"f5\"}"),
    );
    // Missing key on a key event.
    try testing.expectError(
        error.MissingField,
        eventFromJson(testing.allocator, "{\"type\":\"key_down\"}"),
    );
}

test "verifyLayout: text-overlap pass handles more than 64 text nodes" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    // 70 labels in a non-overlapping column: previously the fixed [64]
    // TextBox array asserted (panicked) past 64 text-bearing nodes.
    for (0..70) |i| {
        const y_f: f32 = @floatFromInt(@min(i * 30, 1 << 24));
        try tree.nodes.append(std.testing.allocator, .{
            .id = @enumFromInt(@as(u32, @intCast(i + 1))),
            .kind = .{ .label = .{ .text = "x" } },
            .parent = .root,
            .rect = .{ .x = 0, .y = y_f, .w = 50, .h = 24 },
        });
    }

    const report = try verifyLayout(std.testing.allocator, &tree, fakeMeasure, null);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.startsWith(u8, report, "OK"));
}

test "verifyLayout: root-level sibling overlap and surface bounds are flagged" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    // Two overlapping root-level labels (previously never checked — the
    // root pseudo-container has no node to iterate children of).
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .kind = .{ .label = .{ .text = "a" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 20 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(2),
        .kind = .{ .label = .{ .text = "b" } },
        .parent = .root,
        .rect = .{ .x = 20, .y = 0, .w = 40, .h = 20 }, // overlaps node 1
    });
    // A root-level node extending past the 300-wide surface.
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(3),
        .kind = .{ .label = .{ .text = "c" } },
        .parent = .root,
        .rect = .{ .x = 250, .y = 0, .w = 200, .h = 20 }, // 450 > 300
    });

    const report = try verifyLayout(std.testing.allocator, &tree, null, .{ .width = 300, .height = 200 });
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "root overlap") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "root outside surface") != null);
    try std.testing.expect(!std.mem.startsWith(u8, report, "OK"));
}

test "layoutFingerprint: identical rects with different box sides differ" {
    var tree_a = WidgetTree.init(std.testing.allocator);
    defer tree_a.nodes.deinit(std.testing.allocator);
    var tree_b = WidgetTree.init(std.testing.allocator);
    defer tree_b.nodes.deinit(std.testing.allocator);

    // Same ids, kinds, and rects — only the padding differs. The old
    // fingerprint (rects only) produced identical bytes for both.
    try tree_a.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .kind = .{ .label = .{ .text = "a" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 40 },
    });
    try tree_b.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .kind = .{ .label = .{ .text = "a" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 40 },
        .box = .{ .padding = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 } },
    });

    const fpa = try layoutFingerprint(std.testing.allocator, &tree_a);
    defer std.testing.allocator.free(fpa);
    const fpb = try layoutFingerprint(std.testing.allocator, &tree_b);
    defer std.testing.allocator.free(fpb);

    try std.testing.expect(!std.mem.eql(u8, fpa, fpb));
    // The padding sides actually appear in the output.
    try std.testing.expect(std.mem.indexOf(u8, fpb, "\"padding_top\":4.00") != null);
    try std.testing.expect(std.mem.indexOf(u8, fpb, "\"padding_right\":4.00") != null);
    try std.testing.expect(std.mem.indexOf(u8, fpb, "\"padding_bottom\":4.00") != null);
    try std.testing.expect(std.mem.indexOf(u8, fpb, "\"padding_left\":4.00") != null);
}

test "layoutFingerprint: paint-only box fields (layer) are excluded" {
    var tree_a = WidgetTree.init(std.testing.allocator);
    defer tree_a.nodes.deinit(std.testing.allocator);
    var tree_b = WidgetTree.init(std.testing.allocator);
    defer tree_b.nodes.deinit(std.testing.allocator);

    // Same ids, kinds, and rects — only box.layer differs (a paint-only
    // field, like shadow/gradient/clip/texture). The golden LAYOUT
    // comparison must ignore it: two frames with the same geometry but
    // different layer keys hash identically.
    try tree_a.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .kind = .{ .label = .{ .text = "a" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 40 },
        .box = .{ .layer = 0 },
    });
    try tree_b.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .kind = .{ .label = .{ .text = "a" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 40 },
        .box = .{ .layer = 5 },
    });

    const fpa = try layoutFingerprint(std.testing.allocator, &tree_a);
    defer std.testing.allocator.free(fpa);
    const fpb = try layoutFingerprint(std.testing.allocator, &tree_b);
    defer std.testing.allocator.free(fpb);

    try std.testing.expectEqualStrings(fpa, fpb);
}

test "renderAscii: hover on a sub-2px node draws no border and does not panic" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    // h = 1 < map_px (2): the hover border's inner edge offset
    // (r.y + r.h - map_px) would be negative and @intFromFloat would
    // panic; the guard must skip the border entirely.
    const tiny: Id = @enumFromInt(1);
    try tree.nodes.append(std.testing.allocator, .{
        .id = tiny,
        .kind = .{ .label = .{ .text = "x" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 20, .h = 1 },
    });

    const map = try renderAscii(std.testing.allocator, &tree, tiny);
    defer std.testing.allocator.free(map);
    try std.testing.expect(std.mem.indexOfScalar(u8, map, '@') == null);
}

test "verifyLayout: DrawCtx ellipsized button verifies its label child once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const button = try ctx.button(.{
        .label = "A very long button label",
        .max_width = 20,
        .text_overflow = .ellipsis,
    });

    const measure = struct {
        fn f(text: []const u8, _: f32, _: u8) widget.Size {
            return .{ .width = @floatFromInt(text.len * 10), .height = 20 };
        }
    }.f;
    const surface: Size = .{ .width = 20, .height = 40 };
    layoutWith(&tree, surface, measure);

    const report = try verifyLayout(
        std.testing.allocator,
        &tree,
        measure,
        surface,
    );
    defer std.testing.allocator.free(report);
    try std.testing.expectEqualStrings("OK\n", report);

    // The semantic payload remains available to JSON and click dispatch.
    const json = try treeToJson(std.testing.allocator, &tree);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"button\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "A very long button label") != null);
    try std.testing.expectEqualStrings(
        "A very long button label",
        tree.node(button).?.kind.button.label,
    );
    try std.testing.expectEqual(button, input.hitButton(&tree, .{ 10, 10 }).?);
}

test "verifyLayout: slider text fit uses visual_label" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    var value: f32 = 0.5;
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .kind = .{ .slider = .{
            .label = "semantic label that is much too long",
            .visual_label = "x",
            .value = &value,
            .min = 0,
            .max = 1,
        } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 20 },
    });

    const measure = struct {
        fn f(text: []const u8, _: f32, _: u8) Size {
            return .{ .width = @floatFromInt(text.len * 10), .height = 20 };
        }
    }.f;
    const report = try verifyLayout(std.testing.allocator, &tree, measure, null);
    defer std.testing.allocator.free(report);
    try std.testing.expectEqualStrings("OK\n", report);
}
