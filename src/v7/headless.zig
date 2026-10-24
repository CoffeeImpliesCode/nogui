//! v7 headless output — FrameOutput + JSON serialization.
//!
//! The JSON document produced by `treeToJson` is a **top-level array** of
//! node objects, one per tree node in append (post-order) order. An empty
//! tree serializes as `[]`.
//!
//! Node objects include kind-specific fields only when present:
//!   {"id":N,"kind":"column","parent":N,"rect":{"x":..,"y":..,"w":..,"h":..},
//!    "children":[ids],"gap":{"length":..}}
//!   - column/row: "children" and typed "gap"
//!   - label/button: "label"; buttons can include "accessible_label"
//!   - slider: "label", "value", and optional "visual_label"
//!   - checkbox/switch: "label", "checked"; radio: "label", "selected", "choice"
//!   - progress: "label", "value", "min", "max"; separator: "axis"
//!   - spacer: no extra fields
//! Optional diagnostics add "abs_rect" and "vis_rect". All strings are
//! JSON-escaped; user text is never emitted raw.

const std = @import("std");
const tracy = @import("tracy");

const FrameNodeId = @import("id.zig").FrameNodeId;
const WidgetId = @import("id.zig").WidgetId;
const widget = @import("widget.zig");
const Rect = widget.Rect;
const Size = @import("widget.zig").Size;
const WidgetTree = @import("widget.zig").WidgetTree;
const WidgetNode = @import("widget.zig").WidgetNode;
const DrawCtx = @import("drawctx.zig").DrawCtx;
const layout = @import("layout/root.zig");
const MeasureSource = layout.MeasureSource;
const event = @import("event.zig");
const Event = event.Event;
const Key = event.Key;
const KeyEvent = event.KeyEvent;
const MouseButton = event.MouseButton;
const input = @import("input.zig");

const semantics = @import("semantics.zig");
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
    /// This committed tree stays valid during the next frame attempt, even
    /// if that attempt fails. Once a newer frame commits, a subsequent frame
    /// attempt may reset this tree's arena.
    tree: *const WidgetTree,
    /// The previous committed frame's tree. Dense node IDs may differ after
    /// insertions or reordering; use each tree's stable widget lookup for
    /// identity across frames. Valid only until the next frame attempt starts,
    /// whether that attempt succeeds or fails.
    prev_tree: ?*const WidgetTree,
    /// Published with this tree when App.semantic_publication is configured.
    /// Borrows the publisher and tree storage for the same frame lifetime.
    semantic_snapshot: ?*const semantics.Snapshot = null,
    /// Stable identity of the node under the driver's cursor.
    hover: ?WidgetId,
    /// Stable keyboard-focus identity for the focus ring.
    focus: ?WidgetId,
    /// Stable identity of the held button.
    pressed: ?WidgetId,
    /// Visual targets may outlive pointer hover/press for the exit transition.
    visual_pressed: ?WidgetId = null,
    visual_hover: ?WidgetId = null,
    /// Registry-sampled 0..1 visual states; semantic pressed/hover remain
    /// immediate and the renderer alone consumes the eased values.
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
        try writeNode(allocator, w, tree, node, options);
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

/// Owns the parsed JSON backing all borrowed event text, including IME and
/// logical key strings. Call deinit only after the routed event returns.
pub const ParsedEvent = struct {
    event: Event,
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *ParsedEvent) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub fn parseEvent(allocator: std.mem.Allocator, line: []const u8) !ParsedEvent {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    return .{ .event = try eventFromValue(parsed.value), .parsed = parsed };
}

fn eventFromValue(value: std.json.Value) !Event {
    const obj = switch (value) {
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
            .x = @floatCast(try objNumber(obj, "x")),
            .y = @floatCast(try objNumber(obj, "y")),
            .buttons = try parseButtons(obj),
            .modifiers = try parseModifiers(obj),
        } };
    }
    if (std.mem.eql(u8, kind, "mouse_wheel")) {
        return .{ .mouse_wheel = .{
            .x = @floatCast(try objNumber(obj, "x")),
            .y = @floatCast(try objNumber(obj, "y")),
            .delta_x = @floatCast(try objNumber(obj, "delta_x")),
            .delta_y = @floatCast(try objNumber(obj, "delta_y")),
            .unit = try optionalEnum(event.ScrollUnit, obj, "unit", .line),
            .phase = try optionalEnum(event.ScrollPhase, obj, "phase", .update),
            .natural = try optionalBool(obj, "natural", false),
            .modifiers = try parseModifiers(obj),
        } };
    }
    if (std.mem.eql(u8, kind, "mouse_leave")) return .mouse_leave;
    if (std.mem.eql(u8, kind, "window_focus_lost")) return .window_focus_lost;
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
        else if (std.mem.eql(u8, key_name, "unidentified"))
            .unidentified
        else
            return error.UnknownKey;
        const shift = if (obj.get("shift")) |s| s == .bool and s.bool else false;
        const ev: KeyEvent = .{
            .key = key,
            .shift = shift,
            .modifiers = try parseModifiers(obj),
            .physical = if (obj.get("physical") != null)
                .{ .code = try objUint(u32, obj, "physical") }
            else
                null,
            .logical = if (obj.get("logical") != null)
                .{ .character = try objString(obj, "logical") }
            else
                .{ .named = key },
            .repeat = try optionalBool(obj, "repeat", false),
        };
        return if (std.mem.eql(u8, kind, "key_down"))
            .{ .key_down = ev }
        else
            .{ .key_up = ev };
    }
    if (std.mem.eql(u8, kind, "mouse_down") or
        std.mem.eql(u8, kind, "mouse_up") or
        std.mem.eql(u8, kind, "mouse_cancel"))
    {
        const button_name = try objString(obj, "button");
        const button: MouseButton = if (std.mem.eql(u8, button_name, "left"))
            .left
        else if (std.mem.eql(u8, button_name, "right"))
            .right
        else if (std.mem.eql(u8, button_name, "middle"))
            .middle
        else if (std.mem.eql(u8, button_name, "back"))
            .back
        else if (std.mem.eql(u8, button_name, "forward"))
            .forward
        else
            return error.UnknownEvent;
        const pointer: event.PointerEvent = .{
            .button = button,
            .x = @floatCast(try objNumber(obj, "x")),
            .y = @floatCast(try objNumber(obj, "y")),
            .click_count = try optionalUint(u8, obj, "click_count", 1),
            .modifiers = try parseModifiers(obj),
        };
        if (std.mem.eql(u8, kind, "mouse_down")) return .{ .mouse_down = pointer };
        if (std.mem.eql(u8, kind, "mouse_up")) return .{ .mouse_up = pointer };
        return .{ .mouse_cancel = pointer };
    }
    if (std.mem.eql(u8, kind, "touch_start") or std.mem.eql(u8, kind, "touch_move") or
        std.mem.eql(u8, kind, "touch_end") or std.mem.eql(u8, kind, "touch_cancel"))
    {
        const device = try objIdentifier(obj, "device_id");
        const finger = try objIdentifier(obj, "finger_id");
        const touch: event.TouchEvent = .{
            .id = (@as(u128, device) << 64) | finger,
            .x = @floatCast(try objNumber(obj, "x")),
            .y = @floatCast(try objNumber(obj, "y")),
            .pressure = @floatCast(try optionalNumber(obj, "pressure", 0)),
        };
        if (std.mem.eql(u8, kind, "touch_start")) return .{ .touch_start = touch };
        if (std.mem.eql(u8, kind, "touch_move")) return .{ .touch_move = touch };
        if (std.mem.eql(u8, kind, "touch_end")) return .{ .touch_end = touch };
        return .{ .touch_cancel = touch };
    }
    if (std.mem.eql(u8, kind, "text_input")) {
        return .{ .text_input = .{ .text = try objString(obj, "text") } };
    }
    if (std.mem.eql(u8, kind, "composition")) {
        const phase_name = try objString(obj, "phase");
        const phase: event.CompositionPhase = if (std.mem.eql(u8, phase_name, "start"))
            .start
        else if (std.mem.eql(u8, phase_name, "update"))
            .update
        else if (std.mem.eql(u8, phase_name, "end"))
            .end
        else
            return error.UnknownEvent;
        return .{ .composition = .{
            .phase = phase,
            .text = try objString(obj, "text"),
            .selection_start = try optionalUint(usize, obj, "selection_start", 0),
            .selection_end = try optionalUint(usize, obj, "selection_end", 0),
        } };
    }
    if (std.mem.eql(u8, kind, "activate")) {
        const source = try optionalEnum(
            event.ActivationSource,
            obj,
            "source",
            .accessibility,
        );
        return .{ .activate = .{
            .target_id = try objWidgetId(obj, "target"),
            .source = source,
            .click_count = try optionalUint(u8, obj, "click_count", 1),
        } };
    }
    if (std.mem.eql(u8, kind, "focus_in") or std.mem.eql(u8, kind, "focus_out")) {
        const target_id = try objWidgetId(obj, "target");
        const related: ?WidgetId = if (obj.get("related") != null)
            try objWidgetId(obj, "related")
        else
            null;
        if (std.mem.eql(u8, kind, "focus_in")) {
            return .{ .focus_in = .{ .target_id = target_id, .related = related } };
        }
        return .{ .focus_out = .{ .target_id = target_id, .related = related } };
    }
    if (std.mem.eql(u8, kind, "capture_lost")) {
        const pointer_type = try objString(obj, "pointer");
        const pointer: event.PointerId =
            if (std.mem.eql(u8, pointer_type, "touch"))
                .{ .touch = (@as(u128, try objIdentifier(obj, "device_id")) << 64) |
                    try objIdentifier(obj, "finger_id") }
            else if (std.mem.eql(u8, pointer_type, "mouse"))
                .{ .mouse = try optionalEnum(MouseButton, obj, "button", .left) }
            else
                return error.UnknownEvent;
        return .{ .capture_lost = .{
            .target_id = try objWidgetId(obj, "target"),
            .pointer = pointer,
        } };
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
    return std.math.cast(T, i) orelse error.BadNumber;
}

fn optionalUint(
    comptime T: type,
    obj: std.json.ObjectMap,
    name: []const u8,
    default: T,
) !T {
    if (obj.get(name) == null) return default;
    return objUint(T, obj, name);
}

fn objIdentifier(obj: std.json.ObjectMap, name: []const u8) !u64 {
    return switch (try objField(obj, name)) {
        .integer => |value| std.math.cast(u64, value) orelse error.BadNumber,
        .number_string, .string => |value| std.fmt.parseInt(u64, value, 10) catch error.BadNumber,
        else => error.WrongType,
    };
}

fn objWidgetId(obj: std.json.ObjectMap, name: []const u8) !WidgetId {
    const value = try objObject(obj, name);
    return .{
        .owner = try objIdentifier(value, "owner"),
        .slot = try objUint(u32, value, "slot"),
        .generation = try objUint(u32, value, "generation"),
    };
}

fn optionalNumber(obj: std.json.ObjectMap, name: []const u8, default: f64) !f64 {
    if (obj.get(name) == null) return default;
    return objNumber(obj, name);
}

fn optionalBool(obj: std.json.ObjectMap, name: []const u8, default: bool) !bool {
    return switch (obj.get(name) orelse return default) {
        .bool => |value| value,
        else => error.WrongType,
    };
}

fn optionalEnum(
    comptime E: type,
    obj: std.json.ObjectMap,
    name: []const u8,
    default: E,
) !E {
    if (obj.get(name) == null) return default;
    const value = try objString(obj, name);
    return std.meta.stringToEnum(E, value) orelse error.UnknownEvent;
}

fn parseModifiers(obj: std.json.ObjectMap) !event.Modifiers {
    const raw = obj.get("modifiers") orelse return .{};
    const fields = switch (raw) {
        .object => |value| value,
        else => return error.WrongType,
    };
    return .{
        .shift = try optionalBool(fields, "shift", false),
        .control = try optionalBool(fields, "control", false),
        .alt = try optionalBool(fields, "alt", false),
        .super = try optionalBool(fields, "super", false),
        .caps_lock = try optionalBool(fields, "caps_lock", false),
        .num_lock = try optionalBool(fields, "num_lock", false),
        .left_shift = try optionalBool(fields, "left_shift", false),
        .right_shift = try optionalBool(fields, "right_shift", false),
        .left_control = try optionalBool(fields, "left_control", false),
        .right_control = try optionalBool(fields, "right_control", false),
    };
}

fn parseButtons(obj: std.json.ObjectMap) !event.PointerButtons {
    const raw = obj.get("buttons") orelse return .{};
    const fields = switch (raw) {
        .object => |value| value,
        else => return error.WrongType,
    };
    return .{
        .left = try optionalBool(fields, "left", false),
        .right = try optionalBool(fields, "right", false),
        .middle = try optionalBool(fields, "middle", false),
        .back = try optionalBool(fields, "back", false),
        .forward = try optionalBool(fields, "forward", false),
    };
}

/// Number field (int or float); a non-numeric value is `error.BadNumber`
/// (via `num` — which never hits `unreachable`).
fn objNumber(obj: std.json.ObjectMap, name: []const u8) !f64 {
    return num(try objField(obj, name));
}

fn objObject(obj: std.json.ObjectMap, name: []const u8) !std.json.ObjectMap {
    return switch (try objField(obj, name)) {
        .object => |value| value,
        else => error.WrongType,
    };
}

fn objArray(obj: std.json.ObjectMap, name: []const u8) ![]const std.json.Value {
    return switch (try objField(obj, name)) {
        .array => |value| value.items,
        else => error.WrongType,
    };
}

const LengthPercentageView = struct {
    length: ?f32 = null,
    percent: ?f32 = null,
};

const NodeView = struct {
    id: u32,
    kind: []const u8,
    parent: u32,
    rect: RectView,
    abs_rect: ?RectView = null,
    vis_rect: ?RectView = null,
    children: ?[]const u32 = null, // containers
    gap: ?LengthPercentageView = null, // column/row
    label: ?[]const u8 = null, // text-bearing nodes
    accessible_label: ?[]const u8 = null, // button semantic label
    visual_label: ?[]const u8 = null, // slider visible label override
    value: ?f32 = null, // slider/progress
    min: ?f32 = null, // progress
    max: ?f32 = null, // progress
    checked: ?bool = null, // checkbox/switch
    selected: ?bool = null, // radio
    choice: ?u32 = null, // radio
    axis: ?[]const u8 = null, // separator
    visibility: ?[]const u8 = null,
    visible: ?bool = null,
    revision: ?u64 = null,
    semantic_role: ?[]const u8 = null,
    semantic_label: ?[]const u8 = null,
};

const RectView = struct { x: f32, y: f32, w: f32, h: f32 };

fn writeNode(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    tree: *const WidgetTree,
    node: *const WidgetNode,
    options: TreeJsonOptions,
) !void {
    const is_container = switch (node.kind) {
        .column, .row => true,
        .element => node.children.items.len != 0 or node.kind.element.late_scope != .none,
        else => false,
    };
    const child_ids: ?[]u32 = if (is_container) child_ids: {
        const ids = try allocator.alloc(u32, node.children.items.len);
        for (node.children.items, ids) |child_id, *id| {
            id.* = child_id.index();
        }
        break :child_ids ids;
    } else null;
    defer if (child_ids) |ids| allocator.free(ids);
    const abs_rect = if (options.include_absolute)
        rectView(widget.absoluteRect(tree, node.id))
    else
        null;
    const vis_rect = if (options.include_visual)
        rectView(widget.visualBorderRect(tree, node.id))
    else
        null;
    const visible = widget.isVisible(tree, node.id);
    const view: NodeView = .{
        .id = node.id.index(),
        .kind = @tagName(node.kind),
        .parent = node.parent.index(),
        .rect = .{ .x = node.rect.x, .y = node.rect.y, .w = node.rect.w, .h = node.rect.h },
        .abs_rect = abs_rect,
        .vis_rect = vis_rect,
        .children = child_ids,
        .visibility = if (node.style.visibility == .hidden) "hidden" else null,
        .visible = if (visible) null else false,
        .revision = if (node.kind == .element) node.kind.element.revision else null,
        .semantic_role = if (node.kind == .element and visible)
            if (node.kind.element.semantic) |semantic| @tagName(semantic.role) else null
        else
            null,
        .semantic_label = if (node.kind == .element and visible)
            if (node.kind.element.semantic) |semantic| semantic.label else null
        else
            null,
        .gap = switch (node.kind) {
            .column, .row => lengthPercentageView(node.style.gap),
            else => null,
        },
        .label = if (visible) switch (node.kind) {
            .label => |l| l.text,
            .button => |b| b.label,
            .slider => |s| s.label,
            .checkbox => |c| c.label,
            .switch_control => |s| s.label,
            .radio => |r| r.label,
            .progress => |p| p.label,
            else => null,
        } else null,
        .accessible_label = if (visible) switch (node.kind) {
            .button => |b| b.accessible_label,
            else => null,
        } else null,
        .visual_label = if (visible) switch (node.kind) {
            .slider => |s| s.visual_label,
            else => null,
        } else null,
        .value = switch (node.kind) {
            .slider => |s| s.value.*,
            .progress => |p| p.value,
            else => null,
        },
        .min = switch (node.kind) {
            .progress => |p| p.min,
            else => null,
        },
        .max = switch (node.kind) {
            .progress => |p| p.max,
            else => null,
        },
        .checked = switch (node.kind) {
            .checkbox => |c| c.value.*,
            .switch_control => |s| s.value.*,
            else => null,
        },
        .selected = switch (node.kind) {
            .radio => |r| r.selected.* == r.option,
            else => null,
        },
        .choice = switch (node.kind) {
            .radio => |r| r.option,
            else => null,
        },
        .axis = switch (node.kind) {
            .separator => |s| @tagName(s.axis),
            else => null,
        },
    };
    try std.json.Stringify.value(view, .{ .emit_null_optional_fields = false }, w);
}

fn rectView(r: Rect) RectView {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

fn lengthPercentageView(value: widget.LengthPercentage) LengthPercentageView {
    return switch (value) {
        .length => |length| .{ .length = length },
        .percent => |percent| .{ .percent = percent },
    };
}

/// ── Offscreen layout verification (CPU only — no GPU, no display) ────────
///
/// renderAscii paints the laid-out tree into a character map (2px per char,
/// both axes) and verifyLayout checks structural invariants. Together with
/// treeToJson (which already carries every rect) this is the full headless
/// verification path: layout → inspect → assert, deterministically.
///
/// Map glyphs: containers '.' fill, buttons '#' fill, checkbox '[x]'/'[ ]',
/// radio '(*)'/'(o)', switches show a movable 'O' thumb, progress uses '='
/// over '-', separators use horizontal/vertical lines, text is drawn at its
/// layout position, spacer draws nothing, and hover uses '@' on the border.
/// Scale: map chars per layout pixel (2px per char both axes).
const map_px = 2;
fn asciiContentRect(
    tree: *const WidgetTree,
    id: FrameNodeId,
    min_x: f32,
    min_y: f32,
) Rect {
    var rect = widget.visualContentRect(tree, id);
    rect.x -= min_x;
    rect.y -= min_y;
    return rect;
}

/// Render the layout as an ASCII map, `hover` gets an '@' border. The
/// returned slice is allocator-owned (caller frees). Bounds = the union of
/// all node visual border rects, so scroll offsets are reflected in the map.
pub fn renderAscii(allocator: std.mem.Allocator, tree: *const WidgetTree, hover: ?FrameNodeId) ![]u8 {
    // Bounds from the union of all VISUAL border rects. Visual origins
    // resolve relative boxes and subtract ancestor scroll offsets.
    var min_x: f32 = std.math.inf(f32);
    var min_y: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    var max_y: f32 = -std.math.inf(f32);
    for (tree.nodes.items) |*n| {
        if (!widget.isVisible(tree, n.id)) continue;
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
            const cell_x = @floor(x / map_px);
            const cell_y = @floor(y / map_px);
            if (cell_x < 0 or cell_y < 0) return;
            const cx: usize = @intFromFloat(cell_x);
            const cy: usize = @intFromFloat(cell_y);
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
        if (!widget.isVisible(tree, n.id)) continue;
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
                // A button paints NO text of its own: the scene emits a
                // caption only through the label child DrawCtx generates
                // (see visualText), so drawing the kind's visual label here
                // duplicated the caption one baseline lower. A directly
                // assembled button has no such child, so it keeps the
                // fallback; an empty visual label draws nothing either way.
                if (n.children.items.len == 0) {
                    drawText(grid, cols, widget.buttonVisualLabel(n.kind), r, 0);
                }
            },
            .label => |l| drawText(grid, cols, l.text, r, 0),
            .slider => |s| {
                const y: f32 = r.y + r.h / 2;
                var x: f32 = r.x;
                while (x < r.x + r.w) : (x += map_px) put(grid, cols, x, y, '-');
                const frac = progressFraction(s.value.*, s.min, s.max);
                put(grid, cols, r.x + frac * r.w, y, 'O');
            },
            .checkbox => |c| {
                const content = asciiContentRect(tree, n.id, min_x, min_y);
                if (content.w <= 0 or content.h <= 0) continue;
                const size = @min(
                    widget.control_indicator_size,
                    @min(content.w, content.h),
                );
                const x = content.x;
                const y = content.y + (content.h - size) / 2;
                put(grid, cols, x, y + size / 2, '[');
                put(grid, cols, x + @max(0, size - map_px), y + size / 2, ']');
                if (c.value.*) put(grid, cols, x + size / 2, y + size / 2, 'x');
                drawText(grid, cols, c.label, content, controlLabelOffset(n.kind));
            },
            .switch_control => |s| {
                const content = asciiContentRect(tree, n.id, min_x, min_y);
                if (content.w <= 0 or content.h <= 0) continue;
                const track_width = @min(widget.switch_track_width, content.w);
                const size = @min(
                    widget.control_indicator_size,
                    @min(content.w, content.h),
                );
                const y = content.y + content.h / 2;
                var x = content.x;
                while (x < content.x + track_width) : (x += map_px) put(grid, cols, x, y, '-');
                const thumb_x = content.x + (if (s.value.*)
                    @max(0, track_width - size / 2)
                else
                    @min(size / 2, track_width));
                put(grid, cols, thumb_x, y, 'O');
                drawText(grid, cols, s.label, content, controlLabelOffset(n.kind));
            },
            .radio => |radio| {
                const content = asciiContentRect(tree, n.id, min_x, min_y);
                if (content.w <= 0 or content.h <= 0) continue;
                const size = @min(
                    widget.control_indicator_size,
                    @min(content.w, content.h),
                );
                const x = content.x;
                const y = content.y + content.h / 2;
                put(grid, cols, x, y, '(');
                put(grid, cols, x + @max(0, size - map_px), y, ')');
                put(grid, cols, x + size / 2, y, if (radio.selected.* == radio.option) '*' else 'o');
                drawText(grid, cols, radio.label, content, controlLabelOffset(n.kind));
            },
            .progress => |p| {
                const content = asciiContentRect(tree, n.id, min_x, min_y);
                if (content.w <= 0 or content.h <= 0) continue;
                const caption_h = @max(0, content.h - 14);
                if (p.label.len > 0 and caption_h > 0) {
                    drawText(grid, cols, p.label, .{
                        .x = content.x,
                        .y = content.y,
                        .w = content.w,
                        .h = caption_h,
                    }, 0);
                }
                const y = content.y + @max(0, content.h - 4);
                var x = content.x;
                while (x < content.x + content.w) : (x += map_px) put(grid, cols, x, y, '-');
                const fraction = progressFraction(p.value, p.min, p.max);
                x = content.x;
                while (x < content.x + fraction * content.w) : (x += map_px) put(grid, cols, x, y, '=');
            },
            .separator => |s| {
                const content = asciiContentRect(tree, n.id, min_x, min_y);
                if (content.w <= 0 or content.h <= 0) continue;
                switch (s.axis) {
                    .horizontal => {
                        const y = content.y + content.h / 2;
                        var x = content.x;
                        while (x < content.x + content.w) : (x += map_px) put(grid, cols, x, y, '-');
                    },
                    .vertical => {
                        const x = content.x + content.w / 2;
                        var y = content.y;
                        while (y < content.y + content.h) : (y += map_px) put(grid, cols, x, y, '|');
                    },
                }
            },
            .element => |frame| {
                const content = asciiContentRect(tree, n.id, min_x, min_y);
                for (frame.paint_records.items) |record| {
                    // ASCII is a box-extent inspection view, not a path rasterizer.
                    const bounds = switch (record) {
                        .rect => |spec| spec.bounds,
                        .path => |spec| spec.bounds,
                        .image => |spec| spec.bounds,
                    };
                    const start_x = @max(content.x, content.x + bounds.x);
                    const start_y = @max(content.y, content.y + bounds.y);
                    const end_x = @min(content.x + content.w, content.x + bounds.x + bounds.w);
                    const end_y = @min(content.y + content.h, content.y + bounds.y + bounds.h);
                    var y = start_y;
                    while (y < end_y) : (y += map_px) {
                        var x = start_x;
                        while (x < end_x) : (x += map_px) put(grid, cols, x, y, '*');
                    }
                }
            },
            .spacer => {},
        }
    }

    // Hover border: '@' along the 4 edges.
    if (hover) |hid| {
        for (tree.nodes.items) |*n| {
            if (n.id != hid) continue;
            if (!widget.isVisible(tree, n.id)) break;
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

/// Draw label text at the layout position: byte i at x+6+i*10 (the
/// fallback advance estimate), baseline at y + h*0.75. `leading_inset`
/// leaves room for a control's indicator before its caption.
fn drawText(
    grid: []u8,
    cols: usize,
    text: []const u8,
    r: Rect,
    leading_inset: f32,
) void {
    const put = struct {
        fn f(g: []u8, c: usize, x: f32, y: f32, ch: u8) void {
            const cell_x = @floor(x / map_px);
            const cell_y = @floor(y / map_px);
            if (cell_x < 0 or cell_y < 0) return;
            const cx: usize = @intFromFloat(cell_x);
            const cy: usize = @intFromFloat(cell_y);
            if (cx >= c) return;
            const line = cy * (c + 1);
            if (line + cx >= g.len - 1) return;
            g[line + cx] = ch;
        }
    }.f;
    const baseline = r.y + r.h * 0.75;
    for (text, 0..) |ch, k| {
        const k_f: f32 = @floatFromInt(@min(k, 1 << 24));
        put(grid, cols, r.x + leading_inset + 6 + k_f * 10, baseline, ch);
    }
}

fn controlLabelOffset(kind: widget.WidgetKind) f32 {
    return widget.textInsets(kind).leading;
}

fn progressFraction(value: f32, min: f32, max: f32) f32 {
    const range = max - min;
    if (!std.math.isFinite(value) or !std.math.isFinite(min) or
        !std.math.isFinite(max) or !std.math.isFinite(range) or range <= 0)
    {
        return 0;
    }
    return std.math.clamp((value - min) / range, 0, 1);
}

/// Const-safe node lookup (widget.zig's node() needs a mutable tree).
fn findNodeConst(tree: *const WidgetTree, id: FrameNodeId) ?*const WidgetNode {
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
        .checkbox => |c| c.label,
        .switch_control => |s| s.label,
        .radio => |r| r.label,
        .progress => |p| p.label,
        else => null,
    };
}

/// Write one length-percentage edge with its union tag and payload.
fn writeLengthPercentageEdge(
    w: *std.Io.Writer,
    name: []const u8,
    value: widget.LengthPercentage,
) !void {
    switch (value) {
        .length => |number| try w.print(
            ",\"{s}\":{{\"length\":{d:.2}}}",
            .{ name, number },
        ),
        .percent => |number| try w.print(
            ",\"{s}\":{{\"percent\":{d:.2}}}",
            .{ name, number },
        ),
    }
}

fn writeLengthPercentageAutoEdge(
    w: *std.Io.Writer,
    name: []const u8,
    value: widget.LengthPercentageAuto,
) !void {
    switch (value) {
        .auto => try w.print(",\"{s}\":{{\"auto\":null}}", .{name}),
        .length => |number| try w.print(
            ",\"{s}\":{{\"length\":{d:.2}}}",
            .{ name, number },
        ),
        .percent => |number| try w.print(
            ",\"{s}\":{{\"percent\":{d:.2}}}",
            .{ name, number },
        ),
    }
}

/// Deterministic layout fingerprint for golden comparisons: one compact
/// JSON object per node — id, kind, the four rect values, and each canonical
/// typed margin, border, and padding edge. The union tag is part of the
/// fingerprint, so equal numeric payloads with different CSS meanings do not
/// collide (for example, `length: 0.5` and `percent: 0.5`).
///
/// Rects are the RAW RELATIVE border boxes (parent-content-relative, see
/// widget.zig Rect), so the fingerprint is stable when a subtree moves as a
/// unit — a parent offset change does not invalidate child rects.
/// PaintStyle fields are intentionally omitted: two frames with the same
/// layout but different paint hash identically. No labels, values, or frame
/// counters are included.
pub fn layoutFingerprint(allocator: std.mem.Allocator, tree: *const WidgetTree) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeByte('[');
    for (tree.nodes.items, 0..) |*n, i| {
        if (i != 0) try w.writeByte(',');
        try w.print(
            "{{\"id\":{d},\"kind\":\"{s}\"," ++
                "\"x\":{d:.2},\"y\":{d:.2},\"w\":{d:.2},\"h\":{d:.2}",
            .{
                n.id.index(),
                @tagName(n.kind),
                n.rect.x,
                n.rect.y,
                n.rect.w,
                n.rect.h,
            },
        );
        try writeLengthPercentageAutoEdge(w, "margin_top", n.style.margin_inset.top);
        try writeLengthPercentageAutoEdge(w, "margin_right", n.style.margin_inset.right);
        try writeLengthPercentageAutoEdge(w, "margin_bottom", n.style.margin_inset.bottom);
        try writeLengthPercentageAutoEdge(w, "margin_left", n.style.margin_inset.left);
        try writeLengthPercentageEdge(w, "border_top", n.style.border_inset.top);
        try writeLengthPercentageEdge(w, "border_right", n.style.border_inset.right);
        try writeLengthPercentageEdge(w, "border_bottom", n.style.border_inset.bottom);
        try writeLengthPercentageEdge(w, "border_left", n.style.border_inset.left);
        try writeLengthPercentageEdge(w, "padding_top", n.style.padding_inset.top);
        try writeLengthPercentageEdge(w, "padding_right", n.style.padding_inset.right);
        try writeLengthPercentageEdge(w, "padding_bottom", n.style.padding_inset.bottom);
        try writeLengthPercentageEdge(w, "padding_left", n.style.padding_inset.left);
        try w.writeByte('}');
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
fn isLayered(tree: *const WidgetTree, id: FrameNodeId) bool {
    var cur: ?FrameNodeId = id;
    while (cur) |cid| {
        const n = tree.nodeConst(cid) orelse return false;
        if (n.paint.layer != 0) return true;
        cur = if (n.parent == .root) null else n.parent;
    }
    return false;
}

fn isAncestor(tree: *const WidgetTree, ancestor: FrameNodeId, descendant: FrameNodeId) layout.LayoutError!bool {
    var current_id = descendant;
    while (current_id != .root) {
        const current = tree.nodeConst(current_id) orelse return error.InvalidStyle;
        if (current.parent == ancestor) return true;
        current_id = current.parent;
    }
    return false;
}

pub fn verifyLayout(
    allocator: std.mem.Allocator,
    tree: *const WidgetTree,
    measure: ?MeasureSource,
    surface: ?Size,
) ![]u8 {
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
        const box_edges = n.resolved_box_edges orelse
            widget.geometryBoxEdges(n, r.w);
        // Resolved border and padding must not be negative. Margins may be
        // negative (legal CSS — the layer badge's -44 bottom margin is a
        // deliberate layout trick).
        const side_vals = [_]f32{
            box_edges.border.top,
            box_edges.border.right,
            box_edges.border.bottom,
            box_edges.border.left,
            box_edges.padding.top,
            box_edges.padding.right,
            box_edges.padding.bottom,
            box_edges.padding.left,
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
            const parent_edges = p.resolved_box_edges orelse
                widget.geometryBoxEdges(p, p.rect.w);
            const pw = @max(
                0,
                p.rect.w - parent_edges.border.left - parent_edges.border.right -
                    parent_edges.padding.left - parent_edges.padding.right,
            );
            const ph = @max(
                0,
                p.rect.h - parent_edges.border.top - parent_edges.border.bottom -
                    parent_edges.padding.top - parent_edges.padding.bottom,
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
        const kids = n.children.items;
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
                const insets = widget.textInsets(n.kind);
                const ms = if (t.len == 0)
                    Size{ .width = 0, .height = 0 }
                else blk: {
                    const measured = try m.callback(m.context, t, .{
                        .known_dimensions = .{ .width = null, .height = null },
                        .available_space = .{ .width = .max_content, .height = .max_content },
                        .text = n.text_request,
                        .writing_mode = n.writing_mode,
                    });
                    break :blk Size{ .width = measured.width, .height = measured.height };
                };
                // The canonical dispatcher measures content only; add the
                // node's actual border, padding and control indicator below.
                const box_insets = widget.sidesSum(box_edges.border);
                const pads = widget.sidesSum(box_edges.padding);
                const need_w = ms.width + insets.horizontal() + box_insets.w + pads.w;
                const need_h = switch (n.kind) {
                    .checkbox, .switch_control, .radio => @max(
                        widget.control_indicator_size,
                        ms.height,
                    ) + insets.vertical() + box_insets.h + pads.h,
                    .progress => (if (t.len == 0) @as(f32, 8) else ms.height + 14) +
                        box_insets.h + pads.h,
                    else => ms.height + insets.vertical() + box_insets.h + pads.h,
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
                if (t.len != 0 and !text_width_is_bounded and r.w + 0.001 < need_w) {
                    try add(
                        "text overflow: id {d} '{s}' needs {d:.1} wide, rect {d:.1}",
                        w,
                        &problems,
                        .{ n.id.index(), t, need_w, r.w },
                    );
                }
                if (t.len != 0 and r.h + 0.001 < need_h) {
                    try add(
                        "text overflow: id {d} '{s}' needs {d:.1} tall, rect {d:.1}",
                        w,
                        &problems,
                        .{ n.id.index(), t, need_h, r.h },
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
        const TextBox = struct { id: FrameNodeId, rect: Rect };
        var boxes: std.ArrayList(TextBox) = .empty;
        defer boxes.deinit(allocator);
        for (nodes) |*n| {
            const text = visualText(n) orelse continue;
            if (text.len == 0) continue;
            if (n.rect.w <= 0 or n.rect.h <= 0) continue;
            try boxes.append(allocator, .{
                .id = n.id,
                .rect = try widget.contentRect(tree, n.id),
            });
        }
        // Strictly-ordered pairs (i < j): each overlap is reported once.
        // Ancestor-descendant pairs are skipped: nested text nodes can
        // intentionally share a content box without colliding.
        for (0..boxes.items.len) |i| {
            for (i + 1..boxes.items.len) |j| {
                const a = boxes.items[i].rect;
                const b = boxes.items[j].rect;
                const overlap_x = a.x < b.x + b.w - 0.001 and b.x < a.x + a.w - 0.001;
                const overlap_y = a.y < b.y + b.h - 0.001 and b.y < a.y + a.h - 0.001;
                if (!(overlap_x and overlap_y)) continue;
                if ((try isAncestor(tree, boxes.items[i].id, boxes.items[j].id)) or
                    (try isAncestor(tree, boxes.items[j].id, boxes.items[i].id)))
                {
                    continue;
                }
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
    defer tree.deinit();

    const col: FrameNodeId = @fromBackingInt(@intCast(2));
    const label_text = "say \"hi\" \\ yo\nnext\tline";
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .label = .{ .text = label_text } },
        .parent = col,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = col,
        .kind = .{ .column = .{} },
        .parent = .root,
    });
    // Wire the container's children after the appends (post-order).
    try tree.appendChild(col, @fromBackingInt(@intCast(1)));

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
    try std.testing.expectEqualStrings("label", try objString(label_node, "kind"));
    try std.testing.expectEqualStrings(label_text, try objString(label_node, "label"));

    const col_node = arr.items[1].object;
    try std.testing.expectEqualStrings("column", try objString(col_node, "kind"));
    const col_children = try objArray(col_node, "children");
    try std.testing.expectEqual(@as(usize, 1), col_children.len);
    try std.testing.expectEqual(@as(i64, 1), col_children[0].integer);
}

test "treeToJson: kind-specific fields appear only for their kinds" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var vol: f32 = 0.5;
    const row_id: FrameNodeId = @fromBackingInt(@intCast(3));
    const col_id: FrameNodeId = @fromBackingInt(@intCast(4));

    // Post-order: children before their containers.
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .slider = .{ .label = "vol", .value = &vol, .min = 0, .max = 1 } },
        .parent = row_id,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(2)),
        .kind = .{ .button = .{ .label = "go" } },
        .parent = row_id,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = row_id,
        .kind = .{ .row = .{} },
        .parent = col_id,
        .style = .{ .gap = .{ .length = 3 } },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = col_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{ .gap = .{ .length = 5 } },
    });
    try tree.appendChild(row_id, @fromBackingInt(@intCast(1)));
    try tree.appendChild(row_id, @fromBackingInt(@intCast(2)));
    try tree.appendChild(col_id, row_id);

    const json = try treeToJson(std.testing.allocator, &tree);
    defer std.testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 4), arr.items.len);

    // Slider: label + value, no container fields.
    const slider_node = arr.items[0].object;
    try std.testing.expectEqualStrings("slider", try objString(slider_node, "kind"));
    try std.testing.expectEqualStrings("vol", try objString(slider_node, "label"));
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.5),
        try objNumber(slider_node, "value"),
        1e-9,
    );
    try std.testing.expect(slider_node.get("gap") == null);
    try std.testing.expect(slider_node.get("children") == null);

    // Button: label only.
    const button_node = arr.items[1].object;
    try std.testing.expectEqualStrings("button", try objString(button_node, "kind"));
    try std.testing.expectEqualStrings("go", try objString(button_node, "label"));
    try std.testing.expect(button_node.get("value") == null);
    try std.testing.expect(button_node.get("gap") == null);

    // Row container: gap + children.
    const row_node = arr.items[2].object;
    try std.testing.expectEqualStrings("row", try objString(row_node, "kind"));
    const row_gap = try objObject(row_node, "gap");
    try std.testing.expectApproxEqAbs(@as(f64, 3), try objNumber(row_gap, "length"), 1e-9);
    try std.testing.expect(row_gap.get("percent") == null);
    const row_children = try objArray(row_node, "children");
    try std.testing.expectEqual(@as(usize, 2), row_children.len);
    try std.testing.expectEqual(@as(i64, 1), row_children[0].integer);
    try std.testing.expectEqual(@as(i64, 2), row_children[1].integer);

    // Column container: gap + children, no label.
    const col_node = arr.items[3].object;
    try std.testing.expectEqualStrings("column", try objString(col_node, "kind"));
    const col_gap = try objObject(col_node, "gap");
    try std.testing.expectApproxEqAbs(@as(f64, 5), try objNumber(col_gap, "length"), 1e-9);
    try std.testing.expect(col_gap.get("percent") == null);
    const col_children = try objArray(col_node, "children");
    try std.testing.expectEqual(@as(usize, 1), col_children.len);
    try std.testing.expectEqual(@as(i64, 3), col_children[0].integer);
    try std.testing.expect(col_node.get("label") == null);
}
test "treeToJson: native controls expose their state and value fields" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var checked = true;
    var switched = false;
    var selected: ?u32 = 42;
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .checkbox = .{ .label = "enabled", .value = &checked } },
        .parent = .root,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(2)),
        .kind = .{ .switch_control = .{ .label = "dark mode", .value = &switched } },
        .parent = .root,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(3)),
        .kind = .{ .radio = .{ .label = "large", .selected = &selected, .option = 42 } },
        .parent = .root,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(4)),
        .kind = .{ .progress = .{ .label = "download", .value = 13, .min = 2, .max = 12 } },
        .parent = .root,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(5)),
        .kind = .{ .separator = .{ .axis = .vertical } },
        .parent = .root,
    });

    const json = try treeToJson(std.testing.allocator, &tree);
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const nodes = parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 5), nodes.len);

    const checkbox = nodes[0].object;
    try std.testing.expectEqualStrings("checkbox", try objString(checkbox, "kind"));
    try std.testing.expect((try objField(checkbox, "checked")).bool);
    try std.testing.expect(checkbox.get("value") == null);
    const switch_control = nodes[1].object;
    try std.testing.expectEqualStrings("switch_control", try objString(switch_control, "kind"));
    try std.testing.expect(!(try objField(switch_control, "checked")).bool);

    const radio = nodes[2].object;
    try std.testing.expect((try objField(radio, "selected")).bool);
    try std.testing.expectEqual(@as(i64, 42), try objInteger(radio, "choice"));

    const progress = nodes[3].object;
    try std.testing.expectApproxEqAbs(@as(f64, 13), try objNumber(progress, "value"), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 2), try objNumber(progress, "min"), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 12), try objNumber(progress, "max"), 1e-6);

    const separator = nodes[4].object;
    try std.testing.expectEqualStrings("vertical", try objString(separator, "axis"));
}

test "treeToJson: percentage gap retains its canonical tag" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{ .gap = .{ .percent = 0.25 } },
    });

    const json = try treeToJson(std.testing.allocator, &tree);
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const gap = try objObject(parsed.value.array.items[0].object, "gap");
    try std.testing.expect(gap.get("length") == null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), try objNumber(gap, "percent"), 1e-9);
}

test "treeToJsonWith: more than 32 child ids serialize in append order" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const child_count: usize = 33;
    const parent: FrameNodeId = @fromBackingInt(@intCast(@as(u32, @intCast(child_count + 1))));
    for (0..child_count) |child_index| {
        const child: FrameNodeId = @fromBackingInt(@intCast(@as(u32, @intCast(child_index + 1))));
        try tree.nodes.append(std.testing.allocator, .{
            .id = child,
            .kind = .{ .spacer = .{} },
            .parent = parent,
        });
    }
    try tree.nodes.append(std.testing.allocator, .{
        .id = parent,
        .kind = .{ .column = .{} },
        .parent = .root,
    });
    for (0..child_count) |child_index| {
        const child: FrameNodeId = @fromBackingInt(@intCast(@as(u32, @intCast(child_index + 1))));
        try tree.appendChild(parent, child);
    }

    const json = try treeToJsonWith(std.testing.allocator, &tree, .{});
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const children = try objArray(
        parsed.value.array.items[child_count].object,
        "children",
    );
    try std.testing.expectEqual(child_count, children.len);
    for (children, 0..) |child, child_index| {
        try std.testing.expectEqual(@as(i64, @intCast(child_index + 1)), child.integer);
    }
}

test "treeToJson: empty tree serializes as []" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const json = try treeToJson(std.testing.allocator, &tree);
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings("[]", json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.array.items.len);
}

test "parseEvent owns input and preserves native event payloads" {
    const testing = std.testing;

    var frame = try parseEvent(testing.allocator, "{\"type\":\"frame\",\"tick\":42,\"time_ms\":1234}");
    defer frame.deinit();
    try testing.expectEqual(@as(u32, 42), frame.event.frame.tick);
    try testing.expectEqual(@as(u64, 1234), frame.event.frame.time_ms);

    var resize = try parseEvent(testing.allocator, "{\"type\":\"resize\",\"width\":900,\"height\":700}");
    defer resize.deinit();
    try testing.expectEqual(@as(f32, 900), resize.event.resize.width);
    try testing.expectEqual(@as(f32, 700), resize.event.resize.height);

    var move = try parseEvent(testing.allocator, "{\"type\":\"mouse_move\",\"x\":12.5,\"y\":30.0}");
    defer move.deinit();
    try testing.expectEqual(@as(f32, 12.5), move.event.mouse_move.x);
    try testing.expectEqual(@as(f32, 30), move.event.mouse_move.y);

    var leave = try parseEvent(testing.allocator, "{\"type\":\"mouse_leave\"}");
    defer leave.deinit();
    try testing.expect(leave.event == .mouse_leave);

    var down = try parseEvent(testing.allocator, "{\"type\":\"mouse_down\",\"button\":\"left\",\"x\":1,\"y\":2}");
    defer down.deinit();
    try testing.expectEqual(MouseButton.left, down.event.mouse_down.button);
    var up = try parseEvent(testing.allocator, "{\"type\":\"mouse_up\",\"button\":\"right\",\"x\":3,\"y\":4}");
    defer up.deinit();
    try testing.expectEqual(MouseButton.right, up.event.mouse_up.button);

    try testing.expectError(error.UnknownEvent, parseEvent(testing.allocator, "{\"type\":\"nope\"}"));
}

test "renderAscii: label text, button fill, slider thumb, hover border" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var vol: f32 = 0.5;
    const label_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const button_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const slider_id: FrameNodeId = @fromBackingInt(@intCast(3));

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

test "renderAscii: visible button caption never exposes its semantic label" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .button = .{ .label = "SECRET", .visual_label = "VIEW" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 24 },
    });

    const visible = try renderAscii(std.testing.allocator, &tree, null);
    defer std.testing.allocator.free(visible);
    try std.testing.expect(std.mem.indexOfScalar(u8, visible, 'V') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, visible, 'S') == null);

    tree.nodes.items[0].kind.button.visual_label = "";
    const hidden = try renderAscii(std.testing.allocator, &tree, null);
    defer std.testing.allocator.free(hidden);
    try std.testing.expect(std.mem.indexOfScalar(u8, hidden, '#') != null);
    for (hidden) |character| {
        try std.testing.expect(!std.ascii.isAlphabetic(character));
    }
    const json = try treeToJson(std.testing.allocator, &tree);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "SECRET") != null);
}

/// Two authored caption shapes through the real button path: a semantic
/// label with a visible override, and a semantic label whose visible text
/// is suppressed.
const CaptionButtons = struct {
    const Self = CaptionButtons;

    pub fn draw(self: *Self, ctx: *DrawCtx) !void {
        _ = self;
        _ = try ctx.column(.{ .gap = 8 });
        defer ctx.pop();
        _ = try ctx.button(.{
            .key = .{ .static = "shown" },
            .label = "SEMANTIC_OVERRIDE",
            .visual_label = "VIEWONLY",
        });
        _ = try ctx.button(.{
            .key = .{ .static = "hidden" },
            .label = "SEMANTIC_HIDDEN",
            .visual_label = "",
        });
    }
};

test "renderAscii: a button caption paints once, never its semantic name" {
    const App = @import("app.zig").App;
    const Session = @import("session.zig").Session;
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    app.serialize_json = true;
    var view: CaptionButtons = .{};
    try app.mountRoot(CaptionButtons, &view);

    const out = try app.frame(1, .{ .width = 240, .height = 120 });
    defer if (out.json) |bytes| std.testing.allocator.free(bytes);
    const json = out.json orelse return error.MissingFrameJson;

    const map = try renderAscii(std.testing.allocator, out.tree, null);
    defer std.testing.allocator.free(map);

    // Every alphabetic glyph the map holds, in order, is the visible
    // override of the first button and nothing else. A second copy, either
    // semantic name or the suppressed button's caption each add glyphs here,
    // and a caption that stopped painting removes them all.
    var glyphs: [64]u8 = undefined;
    var count: usize = 0;
    for (map) |character| {
        if (!std.ascii.isAlphabetic(character)) continue;
        if (count == glyphs.len) return error.TooManyGlyphs;
        glyphs[count] = character;
        count += 1;
    }
    try std.testing.expectEqualStrings("VIEWONLY", glyphs[0..count]);

    // The semantic names stay machine-readable in the same frame.
    try std.testing.expect(std.mem.indexOf(u8, json, "SEMANTIC_OVERRIDE") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "SEMANTIC_HIDDEN") != null);
}

test "renderAscii: controls show checked, selected, progress, and axis marks" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    var checked = true;
    var switched = false;
    var selected: ?u32 = 3;
    const nodes = [_]WidgetNode{
        .{
            .id = @fromBackingInt(@intCast(1)),
            .kind = .{ .checkbox = .{ .label = "check", .value = &checked } },
            .parent = .root,
            .rect = .{ .x = 0, .y = 0, .w = 90, .h = 24 },
        },
        .{
            .id = @fromBackingInt(@intCast(2)),
            .kind = .{ .switch_control = .{ .label = "switch", .value = &switched } },
            .parent = .root,
            .rect = .{ .x = 0, .y = 30, .w = 90, .h = 24 },
        },
        .{
            .id = @fromBackingInt(@intCast(3)),
            .kind = .{ .radio = .{ .label = "radio", .selected = &selected, .option = 3 } },
            .parent = .root,
            .rect = .{ .x = 0, .y = 60, .w = 90, .h = 24 },
        },
        .{
            .id = @fromBackingInt(@intCast(4)),
            .kind = .{ .progress = .{ .label = "load", .value = 15, .min = 0, .max = 10 } },
            .parent = .root,
            .rect = .{ .x = 0, .y = 90, .w = 90, .h = 40 },
        },
        .{
            .id = @fromBackingInt(@intCast(5)),
            .kind = .{ .separator = .{ .axis = .horizontal } },
            .parent = .root,
            .rect = .{ .x = 0, .y = 140, .w = 90, .h = 1 },
        },
        .{
            .id = @fromBackingInt(@intCast(6)),
            .kind = .{ .separator = .{ .axis = .vertical } },
            .parent = .root,
            .rect = .{ .x = 100, .y = 0, .w = 1, .h = 100 },
        },
    };
    for (nodes) |node| try tree.nodes.append(std.testing.allocator, node);

    const map = try renderAscii(std.testing.allocator, &tree, null);
    defer std.testing.allocator.free(map);
    try std.testing.expect(std.mem.indexOfScalar(u8, map, 'x') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, map, 'O') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, map, '*') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, map, '=') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, map, '-') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, map, '|') != null);
}

test "progressFraction clamps both bounds and handles an empty range" {
    try std.testing.expectEqual(@as(f32, 0), progressFraction(-1, 0, 10));
    try std.testing.expectEqual(@as(f32, 1), progressFraction(15, 0, 10));
    try std.testing.expectEqual(@as(f32, 0.5), progressFraction(4, 2, 6));
    try std.testing.expectEqual(@as(f32, 0), progressFraction(4, 4, 4));
}

test "renderAscii: empty tree yields an empty map" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const map = try renderAscii(std.testing.allocator, &tree, null);
    defer std.testing.allocator.free(map);
    try std.testing.expectEqual(@as(usize, 0), map.len);
}

test "verifyLayout: clean tree reports OK" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const col: FrameNodeId = @fromBackingInt(@intCast(10));
    const a: FrameNodeId = @fromBackingInt(@intCast(11));
    const b: FrameNodeId = @fromBackingInt(@intCast(12));

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
    defer tree.deinit();

    var vol: f32 = 5; // out of [0, 1]
    const col: FrameNodeId = @fromBackingInt(@intCast(20));
    const a: FrameNodeId = @fromBackingInt(@intCast(21));
    const b: FrameNodeId = @fromBackingInt(@intCast(22));
    const s: FrameNodeId = @fromBackingInt(@intCast(23));

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
    try tree.appendChild(col, a);
    try tree.appendChild(col, b);
    try tree.appendChild(col, s);

    const report = try verifyLayout(std.testing.allocator, &tree, null, null);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "sibling overlap") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "child outside parent") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "slider value out of range") != null);
    try std.testing.expect(!std.mem.startsWith(u8, report, "OK"));
}

test "layoutFingerprint: deterministic geometry and typed edges" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .label = .{ .text = "dynamic counter: 7" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 148.25, .h = 24 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(2)),
        .kind = .{ .button = .{ .label = "go" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 30, .w = 56, .h = 32 },
    });

    const fp = try layoutFingerprint(std.testing.allocator, &tree);
    defer std.testing.allocator.free(fp);

    // Geometry and typed edge values are present; label text is omitted.
    try std.testing.expect(std.mem.indexOf(u8, fp, "dynamic counter") == null);
    try std.testing.expect(std.mem.indexOf(u8, fp, "148.25") != null);
    try std.testing.expect(std.mem.indexOf(u8, fp, "\"kind\":\"button\"") != null);

    // Deterministic: two runs produce identical bytes.
    const fp2 = try layoutFingerprint(std.testing.allocator, &tree);
    defer std.testing.allocator.free(fp2);
    try std.testing.expectEqualStrings(fp, fp2);
}

const fake_measure: MeasureSource = .{
    .callback = struct {
        fn f(
            _: ?*anyopaque,
            _: []const u8,
            _: layout.MeasureInput,
        ) layout.LayoutError!layout.TextMeasurement {
            return .{ .width = 40, .height = 24 };
        }
    }.f,
};

test "verifyLayout: bounded ellipsis and clip text do not report overflow" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .label = .{ .text = "ellipsized" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 20, .h = 24 },
        .text_overflow = .ellipsis,
        .text_max_width = 20,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(2)),
        .kind = .{ .label = .{ .text = "clipped" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 30, .w = 20, .h = 24 },
        .text_overflow = .clip,
        .text_max_width = 20,
    });

    const report = try verifyLayout(std.testing.allocator, &tree, fake_measure, null);
    defer std.testing.allocator.free(report);
    try std.testing.expectEqualStrings("OK\n", report);
}

test "verifyLayout: overlapping text boxes are reported, adjacent are not" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    // Two labels whose text boxes (absolute content boxes) collide: A's
    // box spans [0, 52], B at x 20 spans [20, 72] — the interior overlap
    // is real even though both texts are short.
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .label = .{ .text = "aaaa" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 52, .h = 24 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(2)),
        .kind = .{ .label = .{ .text = "bbbb" } },
        .parent = .root,
        .rect = .{ .x = 20, .y = 0, .w = 52, .h = 24 }, // boxes collide
    });

    const report = try verifyLayout(std.testing.allocator, &tree, fake_measure, null);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "text overlap") != null);
}

test "verifyLayout: text boxes that merely touch are not an overlap" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    // A's text box ends at x 52; B starts at x 52 — touching edges are
    // not an interior intersection.
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .label = .{ .text = "aaaa" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 52, .h = 24 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(2)),
        .kind = .{ .label = .{ .text = "bbbb" } },
        .parent = .root,
        .rect = .{ .x = 52, .y = 0, .w = 52, .h = 24 },
    });

    const report = try verifyLayout(std.testing.allocator, &tree, fake_measure, null);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.startsWith(u8, report, "OK"));
}

test "treeToJson: rect values round-trip exactly" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const rect: Rect = .{ .x = 12.5, .y = -3.25, .w = 100, .h = 200.75 };
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .label = .{ .text = "a" } },
        .parent = .root,
        .rect = rect,
    });

    const json = try treeToJson(std.testing.allocator, &tree);
    defer std.testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const r = try objObject(parsed.value.array.items[0].object, "rect");
    try std.testing.expectEqual(@as(f64, 12.5), try objNumber(r, "x"));
    try std.testing.expectEqual(@as(f64, -3.25), try objNumber(r, "y"));
    try std.testing.expectEqual(@as(f64, 100), try objNumber(r, "w"));
    try std.testing.expectEqual(@as(f64, 200.75), try objNumber(r, "h"));
}

test "treeToJsonWith: absolute and visual geometry are optional diagnostics" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const parent: FrameNodeId = @fromBackingInt(@intCast(1));
    const child: FrameNodeId = @fromBackingInt(@intCast(2));
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
        .style = .{
            .border_inset = .{
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 2 },
                .top = .{ .length = 3 },
            },
            .padding_inset = .{
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 4 },
                .top = .{ .length = 5 },
            },
        },
    });
    try tree.appendChild(parent, child);

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
    const absolute = try objObject(child_view, "abs_rect");
    try std.testing.expectEqual(@as(f64, 23), try objNumber(absolute, "x"));
    try std.testing.expectEqual(@as(f64, 39), try objNumber(absolute, "y"));
    try std.testing.expectEqual(@as(f64, 30), try objNumber(absolute, "w"));
    try std.testing.expectEqual(@as(f64, 12), try objNumber(absolute, "h"));

    const visual = try objObject(child_view, "vis_rect");
    try std.testing.expectEqual(@as(f64, 23), try objNumber(visual, "x"));
    try std.testing.expectEqual(@as(f64, 39), try objNumber(visual, "y"));
    try std.testing.expectEqual(@as(f64, 30), try objNumber(visual, "w"));
    try std.testing.expectEqual(@as(f64, 12), try objNumber(visual, "h"));
}

test "renderAscii: nested node renders at its absolute position" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    // Root column with padding; button nested at a relative offset. Its
    // absolute origin = col (0,0) + padding (8,8) + rect (5,5) = (13,13).
    const col: FrameNodeId = @fromBackingInt(@intCast(1));
    const btn: FrameNodeId = @fromBackingInt(@intCast(2));

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
        .style = .{
            .padding_inset = .{
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 8 },
                .top = .{ .length = 8 },
            },
        },
    });
    try tree.appendChild(col, btn);

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
    defer tree.deinit();

    // Column with border+padding; button fills the content box exactly
    // (content w = 100-4-2-8-6 = 80, h = 60-1-3-8-7 = 41).
    const col: FrameNodeId = @fromBackingInt(@intCast(1));
    const btn: FrameNodeId = @fromBackingInt(@intCast(2));

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
        .style = .{
            .border_inset = .{
                .top = .{ .length = 1 },
                .right = .{ .length = 2 },
                .bottom = .{ .length = 3 },
                .left = .{ .length = 4 },
            },
            .padding_inset = .{
                .top = .{ .length = 8 },
                .right = .{ .length = 6 },
                .bottom = .{ .length = 7 },
                .left = .{ .length = 8 },
            },
        },
    });
    try tree.appendChild(col, btn);

    const report = try verifyLayout(std.testing.allocator, &tree, null, null);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.startsWith(u8, report, "OK"));
}

test "verifyLayout: child outside the parent's content box is flagged" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const col: FrameNodeId = @fromBackingInt(@intCast(1));
    const child: FrameNodeId = @fromBackingInt(@intCast(2));
    // Child sits inside the border box (x+w = 95 <= 100) but past the
    // content box (content w = 100-8-8 = 84): the content box constrains.
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
        .style = .{
            .padding_inset = .{
                .top = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 8 },
                .right = .{ .length = 8 },
            },
        },
    });
    try tree.appendChild(col, child);

    const report = try verifyLayout(std.testing.allocator, &tree, null, null);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "child outside parent") != null);
    try std.testing.expect(!std.mem.startsWith(u8, report, "OK"));
}

test "verifyLayout: negative box sides are reported" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .label = .{ .text = "x" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .style = .{
            .padding_inset = .{
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 0 },
                .top = .{ .length = -2 },
            },
        },
    });

    const report = try verifyLayout(std.testing.allocator, &tree, null, null);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "negative box side") != null);
    try std.testing.expect(!std.mem.startsWith(u8, report, "OK"));
}

test "verifyLayout: negative width and height are reported" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const negative_width: FrameNodeId = @fromBackingInt(@intCast(1));
    const negative_height: FrameNodeId = @fromBackingInt(@intCast(2));
    try tree.nodes.append(std.testing.allocator, .{
        .id = negative_width,
        .kind = .{ .spacer = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = -1, .h = 20 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = negative_height,
        .kind = .{ .spacer = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 20, .w = 20, .h = -1 },
    });

    const report = try verifyLayout(std.testing.allocator, &tree, null, null);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "negative size: id 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "negative size: id 2") != null);
    try std.testing.expect(!std.mem.startsWith(u8, report, "OK"));
}

test "parseEvent preserves wheel position, deltas, phase and natural flag" {
    var parsed = try parseEvent(
        std.testing.allocator,
        "{\"type\":\"mouse_wheel\",\"x\":12.5,\"y\":30,\"delta_x\":-2,\"delta_y\":3.25," ++
            "\"unit\":\"pixel\",\"phase\":\"momentum\",\"natural\":true}",
    );
    defer parsed.deinit();
    const wheel = parsed.event.mouse_wheel;
    try std.testing.expectEqual(event.ScrollUnit.pixel, wheel.unit);
    try std.testing.expectEqual(event.ScrollPhase.momentum, wheel.phase);
    try std.testing.expect(wheel.natural);
    try std.testing.expectEqual(@as(f32, 12.5), wheel.x);
    try std.testing.expectEqual(@as(f32, 30), wheel.y);
    try std.testing.expectEqual(@as(f32, -2), wheel.delta_x);
    try std.testing.expectEqual(@as(f32, 3.25), wheel.delta_y);
}

test "parseEvent retains IME text and device-qualified touch IDs after line release" {
    const gpa = std.testing.allocator;
    const line = try gpa.dupe(
        u8,
        "{\"type\":\"composition\",\"phase\":\"update\",\"text\":\"caf\\u00e9\"," ++
            "\"selection_start\":1,\"selection_end\":3}",
    );
    var composition = parseEvent(gpa, line) catch |err| {
        gpa.free(line);
        return err;
    };
    gpa.free(line);
    defer composition.deinit();
    try std.testing.expectEqualStrings("café", composition.event.composition.text);
    try std.testing.expectEqual(@as(usize, 3), composition.event.composition.selection_end);

    var touch = try parseEvent(
        gpa,
        "{\"type\":\"touch_start\",\"device_id\":18446744073709551615,\"finger_id\":17," ++
            "\"x\":12,\"y\":24,\"pressure\":0.5}",
    );
    defer touch.deinit();
    try std.testing.expectEqual(
        (@as(u128, std.math.maxInt(u64)) << 64) | 17,
        touch.event.touch_start.id,
    );
    try std.testing.expectEqual(@as(f32, 0.5), touch.event.touch_start.pressure);
}

test "parseEvent rejects malformed input without a panic or leaked arena" {
    const testing = std.testing;

    // Non-object line (array).
    try testing.expectError(error.WrongType, parseEvent(testing.allocator, "[1,2]"));
    // Non-object line (string).
    try testing.expectError(error.WrongType, parseEvent(testing.allocator, "\"nope\""));
    // Missing type field.
    try testing.expectError(
        error.MissingField,
        parseEvent(testing.allocator, "{\"tick\":1}"),
    );
    // Float tick where an integer is required.
    try testing.expectError(
        error.WrongType,
        parseEvent(testing.allocator, "{\"type\":\"frame\",\"tick\":1.5,\"time_ms\":0}"),
    );
    // Negative tick is out of range for u32.
    try testing.expectError(
        error.BadNumber,
        parseEvent(testing.allocator, "{\"type\":\"frame\",\"tick\":-1,\"time_ms\":0}"),
    );
    // Missing required field (x).
    try testing.expectError(
        error.MissingField,
        parseEvent(testing.allocator, "{\"type\":\"mouse_move\",\"y\":1}"),
    );
    // Non-numeric where a number is required.
    try testing.expectError(
        error.BadNumber,
        parseEvent(testing.allocator, "{\"type\":\"mouse_move\",\"x\":\"abc\",\"y\":1}"),
    );
    // Unknown event type.
    try testing.expectError(
        error.UnknownEvent,
        parseEvent(testing.allocator, "{\"type\":\"nope\"}"),
    );
    // Unknown key name.
    try testing.expectError(
        error.UnknownKey,
        parseEvent(testing.allocator, "{\"type\":\"key_down\",\"key\":\"f5\"}"),
    );
    // Missing key on a key event.
    try testing.expectError(
        error.MissingField,
        parseEvent(testing.allocator, "{\"type\":\"key_down\"}"),
    );
}

test "verifyLayout: text-overlap pass handles more than 64 text nodes" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    // 70 labels in a non-overlapping column: previously the fixed [64]
    // TextBox array asserted (panicked) past 64 text-bearing nodes.
    for (0..70) |i| {
        const y_f: f32 = @floatFromInt(@min(i * 30, 1 << 24));
        try tree.nodes.append(std.testing.allocator, .{
            .id = @fromBackingInt(@intCast(@as(u32, @intCast(i + 1)))),
            .kind = .{ .label = .{ .text = "x" } },
            .parent = .root,
            .rect = .{ .x = 0, .y = y_f, .w = 50, .h = 24 },
        });
    }

    const report = try verifyLayout(std.testing.allocator, &tree, fake_measure, null);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.startsWith(u8, report, "OK"));
}

test "verifyLayout: root-level sibling overlap and surface bounds are flagged" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    // Two overlapping root-level labels (previously never checked — the
    // root pseudo-container has no node to iterate children of).
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .label = .{ .text = "a" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 20 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(2)),
        .kind = .{ .label = .{ .text = "b" } },
        .parent = .root,
        .rect = .{ .x = 20, .y = 0, .w = 40, .h = 20 }, // overlaps node 1
    });
    // A root-level node extending past the 300-wide surface.
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(3)),
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

test "layoutFingerprint: identical rects with different typed edges differ" {
    var tree_a = WidgetTree.init(std.testing.allocator);
    defer tree_a.deinit();
    var tree_b = WidgetTree.init(std.testing.allocator);
    defer tree_b.deinit();

    // Same ids, kinds, and rects — only the typed padding differs. The
    // fingerprint must include both each edge's tag and its numeric value.
    try tree_a.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .label = .{ .text = "a" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 40 },
    });
    try tree_b.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .label = .{ .text = "a" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 40 },
        .style = .{
            .padding_inset = .{
                .top = .{ .length = 4 },
                .right = .{ .length = 4 },
                .bottom = .{ .length = 4 },
                .left = .{ .length = 4 },
            },
        },
    });

    const fpa = try layoutFingerprint(std.testing.allocator, &tree_a);
    defer std.testing.allocator.free(fpa);
    const fpb = try layoutFingerprint(std.testing.allocator, &tree_b);
    defer std.testing.allocator.free(fpb);

    try std.testing.expect(!std.mem.eql(u8, fpa, fpb));
    // The padding sides actually appear in the output.
    try std.testing.expect(std.mem.indexOf(u8, fpb, "\"padding_top\":{\"length\":4.00}") != null);
    try std.testing.expect(std.mem.indexOf(u8, fpb, "\"padding_right\":{\"length\":4.00}") != null);
    try std.testing.expect(std.mem.indexOf(u8, fpb, "\"padding_bottom\":{\"length\":4.00}") != null);
    try std.testing.expect(std.mem.indexOf(u8, fpb, "\"padding_left\":{\"length\":4.00}") != null);
}

test "layoutFingerprint: typed edge tags remain distinct" {
    var tree_length = WidgetTree.init(std.testing.allocator);
    defer tree_length.deinit();
    var tree_percent = WidgetTree.init(std.testing.allocator);
    defer tree_percent.deinit();

    try tree_length.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .label = .{ .text = "a" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 40 },
        .style = .{
            .padding_inset = .{
                .top = .{ .length = 0.5 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 0 },
            },
        },
    });
    try tree_percent.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .label = .{ .text = "a" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 40 },
        .style = .{
            .padding_inset = .{
                .top = .{ .percent = 0.5 },
                .right = .{ .length = 0 },
                .bottom = .{ .length = 0 },
                .left = .{ .length = 0 },
            },
        },
    });

    const length_fingerprint = try layoutFingerprint(std.testing.allocator, &tree_length);
    defer std.testing.allocator.free(length_fingerprint);
    const percent_fingerprint = try layoutFingerprint(std.testing.allocator, &tree_percent);
    defer std.testing.allocator.free(percent_fingerprint);

    try std.testing.expect(!std.mem.eql(u8, length_fingerprint, percent_fingerprint));
    try std.testing.expect(
        std.mem.indexOf(u8, length_fingerprint, "\"padding_top\":{\"length\":0.50}") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, percent_fingerprint, "\"padding_top\":{\"percent\":0.50}") != null,
    );
}

test "layoutFingerprint: paint-only fields (layer) are excluded" {
    var tree_a = WidgetTree.init(std.testing.allocator);
    defer tree_a.deinit();
    var tree_b = WidgetTree.init(std.testing.allocator);
    defer tree_b.deinit();

    // Same ids, kinds, and rects — only PaintStyle.layer differs (a
    // paint-only field, like shadow/gradient/clip/texture). The golden LAYOUT
    // comparison must ignore it: two frames with the same geometry but
    // different layer keys hash identically.
    try tree_a.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .label = .{ .text = "a" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 40 },
        .paint = .{ .layer = 0 },
    });
    try tree_b.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .kind = .{ .label = .{ .text = "a" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 40 },
        .paint = .{ .layer = 5 },
    });

    const fpa = try layoutFingerprint(std.testing.allocator, &tree_a);
    defer std.testing.allocator.free(fpa);
    const fpb = try layoutFingerprint(std.testing.allocator, &tree_b);
    defer std.testing.allocator.free(fpb);

    try std.testing.expectEqualStrings(fpa, fpb);
}

test "renderAscii: hover on a sub-2px node draws no border and does not panic" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    // h = 1 < map_px (2): the hover border's inner edge offset
    // (r.y + r.h - map_px) would be negative and @intFromFloat would
    // panic; the guard must skip the border entirely.
    const tiny: FrameNodeId = @fromBackingInt(@intCast(1));
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
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const button = try ctx.button(.{
        .label = "A very long button label",
        .max_width = 20,
        .text_overflow = .ellipsis,
    });

    const measure: layout.MeasureSource = .{ .callback = struct {
        fn f(_: ?*anyopaque, content: []const u8, _: layout.MeasureInput) layout.LayoutError!layout.TextMeasurement {
            return .{ .width = @floatFromInt(content.len * 10), .height = 20 };
        }
    }.f };
    const surface: Size = .{ .width = 20, .height = 40 };
    try layout.layoutTree(&tree, .{
        .allocator = arena.allocator(),
        .available = surface,
        .measure = measure,
    });

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
    try std.testing.expectEqual(button, input.hitActionable(&tree, .{ 10, 10 }).?);
}

test "verifyLayout: slider text fit uses visual_label" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var value: f32 = 0.5;
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
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

    const measure: layout.MeasureSource = .{ .callback = struct {
        fn f(_: ?*anyopaque, content: []const u8, _: layout.MeasureInput) layout.LayoutError!layout.TextMeasurement {
            return .{ .width = @floatFromInt(content.len * 10), .height = 20 };
        }
    }.f };
    const report = try verifyLayout(std.testing.allocator, &tree, measure, null);
    defer std.testing.allocator.free(report);
    try std.testing.expectEqualStrings("OK\n", report);
}
