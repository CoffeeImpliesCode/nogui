const std = @import("std");
const App = @import("app.zig").App;
const Session = @import("session.zig").Session;
const DrawCtx = @import("drawctx.zig").DrawCtx;
const WidgetId = @import("id.zig").WidgetId;
const ComponentKey = @import("key.zig").ComponentKey;
const widget = @import("widget.zig");
const event = @import("event.zig");
const Rect = widget.Rect;

const Controls = struct {
    checked: bool = false,
    enabled: bool = false,
    selected: ?u32 = null,

    pub fn draw(self: *Controls, ctx: *DrawCtx) !void {
        _ = try ctx.column(.{ .gap = 8 });
        defer ctx.pop();
        _ = try ctx.checkbox(.{
            .key = ComponentKey{ .static = "store-drafts" },
            .label = "Store drafts",
            .value = &self.checked,
        });
        _ = try ctx.switchControl(.{
            .key = ComponentKey{ .static = "live-preview" },
            .label = "Live preview",
            .value = &self.enabled,
        });
        _ = try ctx.radio(.{
            .key = ComponentKey{ .static = "theme-light" },
            .label = "Light",
            .selected = &self.selected,
            .option = 1,
        });
        _ = try ctx.radio(.{
            .key = ComponentKey{ .static = "theme-dark" },
            .label = "Dark",
            .selected = &self.selected,
            .option = 2,
        });
        _ = try ctx.progress(.{ .label = "Import", .value = 0.25, .min = 0, .max = 1 });
        _ = try ctx.separator(.{ .axis = .horizontal });
        _ = try ctx.progress(.{ .value = 0.5, .min = 0, .max = 1 });
    }
};

fn center(rect: Rect) struct { x: f32, y: f32 } {
    return .{ .x = rect.x + rect.w / 2, .y = rect.y + rect.h / 2 };
}

test "controls: mouse and keyboard update bound state; read-only leaves stay inert" {
    var controls: Controls = .{};
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    app.serialize_json = true;
    try app.mountRoot(Controls, &controls);
    _ = try app.handle(.{ .resize = .{ .width = 320, .height = 320 } });
    const first = (try app.handle(.{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
        return error.MissingFrameOutput;
    defer if (first.json) |json| std.testing.allocator.free(json);

    const Slot = struct { widget_id: ?WidgetId, rect: Rect };
    var slots: [7]Slot = undefined;
    var found: usize = 0;
    for (first.tree.nodes.items) |node| {
        const slot: usize = switch (node.kind) {
            .checkbox => 0,
            .switch_control => 1,
            .radio => |radio| if (radio.option == 1) @as(usize, 2) else 3,
            .progress => |progress| if (progress.label.len == 0) @as(usize, 6) else 4,
            .separator => 5,
            else => continue,
        };
        slots[slot] = .{
            .widget_id = node.widget_id,
            .rect = widget.absoluteRect(first.tree, node.id),
        };
        found += 1;
    }
    try std.testing.expectEqual(@as(usize, slots.len), found);
    for (slots) |slot| {
        try std.testing.expect(slot.rect.w > 0 and slot.rect.h > 0);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 8), slots[6].rect.h, 0.001);
    try std.testing.expect(slots[6].rect.w >= 100);
    const checkbox_id = slots[0].widget_id orelse return error.MissingCheckboxIdentity;
    const dark_radio_id = slots[3].widget_id orelse return error.MissingRadioIdentity;

    const checkbox = center(slots[0].rect);
    _ = try app.handle(.{ .mouse_down = .{ .button = .right, .x = checkbox.x, .y = checkbox.y } });
    try std.testing.expect(!controls.checked);
    _ = try app.handle(.{ .mouse_down = .{ .button = .left, .x = checkbox.x, .y = checkbox.y } });
    try std.testing.expect(!controls.checked);
    _ = try app.handle(.{ .mouse_up = .{ .button = .left, .x = checkbox.x, .y = checkbox.y } });
    try std.testing.expect(controls.checked);
    try std.testing.expectEqual(@as(?WidgetId, checkbox_id), app.focus_manager.current);

    const toggle = center(slots[1].rect);
    _ = try app.handle(.{ .mouse_down = .{ .button = .left, .x = toggle.x, .y = toggle.y } });
    try std.testing.expect(!controls.enabled);
    _ = try app.handle(.{ .mouse_up = .{ .button = .left, .x = toggle.x, .y = toggle.y } });
    try std.testing.expect(controls.enabled);

    const first_radio = center(slots[2].rect);
    _ = try app.handle(.{
        .mouse_down = .{ .button = .left, .x = first_radio.x, .y = first_radio.y },
    });
    try std.testing.expectEqual(@as(?u32, null), controls.selected);
    _ = try app.handle(.{
        .mouse_up = .{ .button = .left, .x = first_radio.x, .y = first_radio.y },
    });
    try std.testing.expectEqual(@as(?u32, 1), controls.selected);
    _ = try app.handle(.{ .key_down = .{ .key = .right, .shift = false } });
    try std.testing.expectEqual(@as(?u32, 2), controls.selected);
    try std.testing.expectEqual(@as(?WidgetId, dark_radio_id), app.focus_manager.current);

    for (slots[4..]) |slot| {
        const pos = center(slot.rect);
        _ = try app.handle(.{ .mouse_down = .{ .button = .left, .x = pos.x, .y = pos.y } });
        _ = try app.handle(.{ .mouse_up = .{ .button = .left, .x = pos.x, .y = pos.y } });
        try std.testing.expectEqual(@as(?WidgetId, dark_radio_id), app.focus_manager.current);
        try std.testing.expectEqual(@as(?u32, 2), controls.selected);
    }
    _ = try app.handle(.{ .key_down = .{ .key = .tab, .shift = false } });
    try std.testing.expectEqual(@as(?WidgetId, checkbox_id), app.focus_manager.current);
    _ = try app.handle(.{ .key_down = .{ .key = .space, .shift = false } });
    try std.testing.expect(!controls.checked);
    _ = try app.handle(.{ .key_down = .{ .key = .enter, .shift = false } });
    try std.testing.expect(controls.checked);

    const second = (try app.handle(.{ .frame = .{ .tick = 2, .time_ms = 16 } })) orelse
        return error.MissingFrameOutput;
    defer if (second.json) |json| std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        second.json orelse return error.MissingJson,
        .{},
    );
    defer parsed.deinit();
    var checked_count: usize = 0;
    var selected_count: usize = 0;
    for (parsed.value.array.items) |entry| {
        const obj = entry.object;
        const kind = (obj.get("kind") orelse continue).string;
        if (std.mem.eql(u8, kind, "checkbox") or std.mem.eql(u8, kind, "switch_control")) {
            try std.testing.expect((obj.get("checked") orelse return error.MissingChecked).bool);
            checked_count += 1;
        } else if (std.mem.eql(u8, kind, "radio")) {
            if ((obj.get("selected") orelse return error.MissingSelected).bool) selected_count += 1;
        } else if (std.mem.eql(u8, kind, "separator")) {
            try std.testing.expectEqualStrings("horizontal", (obj.get("axis") orelse return error.MissingAxis).string);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), checked_count);
    try std.testing.expectEqual(@as(usize, 1), selected_count);
}

test "api-w09 App routes release activation, cancellation and focused keys" {
    const Root = struct {
        const Self = @This();
        clicks: u32 = 0,
        activations: u32 = 0,
        cancellations: u32 = 0,
        key_ups: u32 = 0,
        text_commits: u32 = 0,
        prevent_activation: bool = false,
        disabled: bool = false,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.button(.{
                .key = .{ .static = "go" },
                .label = "Go",
                .width = 100,
                .height = 36,
                .disabled = self.disabled,
                .on_click = Self.clicked,
            });
        }

        fn clicked(self: *Self) void {
            self.clicks += 1;
        }

        pub fn onRoutedEvent(self: *Self, ctx: *event.DispatchContext) void {
            if (ctx.phase != .target) return;
            switch (ctx.event.*) {
                .activate => {
                    self.activations += 1;
                    if (self.prevent_activation) ctx.preventDefault();
                },
                .mouse_cancel => self.cancellations += 1,
                .key_up => self.key_ups += 1,
                .text_input => self.text_commits += 1,
                else => {},
            }
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var root: Root = .{};
    try app.mountRoot(Root, &root);
    const first = try app.frame(1, .{ .width = 160, .height = 80 });
    const id = app.widgetIdForKey(.root, .{ .static = "go" }) orelse
        return error.MissingButtonIdentity;
    const node = first.tree.frameNode(id) orelse return error.MissingButton;
    const rect = widget.absoluteRect(first.tree, node);
    const x = rect.x + rect.w / 2;
    const y = rect.y + rect.h / 2;

    _ = try app.handle(.{ .mouse_down = .{ .button = .left, .x = x, .y = y } });
    try std.testing.expectEqual(@as(u32, 0), root.clicks);
    _ = try app.handle(.{ .mouse_move = .{ .x = 300, .y = 300 } });
    _ = try app.handle(.{ .mouse_move = .{ .x = x, .y = y } });
    _ = try app.handle(.{ .mouse_up = .{ .button = .left, .x = x, .y = y } });
    try std.testing.expectEqual(@as(u32, 1), root.clicks);
    try std.testing.expectEqual(@as(u32, 1), root.activations);

    _ = try app.handle(.{ .mouse_down = .{ .button = .left, .x = x, .y = y } });
    _ = try app.handle(.{ .mouse_cancel = .{ .button = .left, .x = x, .y = y } });
    _ = try app.handle(.{ .mouse_up = .{ .button = .left, .x = x, .y = y } });
    try std.testing.expectEqual(@as(u32, 1), root.cancellations);
    try std.testing.expectEqual(@as(u32, 1), root.clicks);

    _ = try app.handle(.{ .key_down = .{ .key = .enter, .repeat = true } });
    try std.testing.expectEqual(@as(u32, 1), root.clicks);
    _ = try app.handle(.{ .key_up = .{ .key = .enter } });
    try std.testing.expectEqual(@as(u32, 1), root.key_ups);
    _ = try app.handle(.{ .text_input = .{ .text = "é" } });
    try std.testing.expectEqual(@as(u32, 1), root.text_commits);
    _ = try app.handle(.{ .key_down = .{ .key = .enter } });
    try std.testing.expectEqual(@as(u32, 2), root.clicks);

    root.prevent_activation = true;
    _ = try app.handle(.{ .activate = .{ .target_id = id, .source = .accessibility } });
    try std.testing.expect(app.last_input_default_prevented);
    try std.testing.expectEqual(@as(u32, 2), root.clicks);

    root.prevent_activation = false;
    root.disabled = true;
    const second = try app.frame(2, .{ .width = 160, .height = 80 });
    try std.testing.expect(app.focus_manager.current == null);
    _ = try app.handle(.{ .mouse_down = .{ .button = .left, .x = x, .y = y } });
    _ = try app.handle(.{ .mouse_up = .{ .button = .left, .x = x, .y = y } });
    app.activate(second.tree, id);
    try std.testing.expectEqual(@as(u32, 2), root.clicks);
}
