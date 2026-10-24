//! W10: App shortcuts dispatch actions only after routed input and replay
//! unmatched chords through the normal default path exactly once.
const std = @import("std");
const App = @import("app.zig").App;
const DrawCtx = @import("drawctx.zig").DrawCtx;
const Session = @import("session.zig").Session;
const Clock = @import("clock.zig").Clock;
const action = @import("action.zig");
const keymap = @import("keymap.zig");
const overlay = @import("overlay.zig");
const widget = @import("widget.zig");
const element = @import("element.zig");

const Increase = action.Action(void, "counter.increase");
const Bonus = action.Action(void, "counter.bonus");
const Controller = struct {
    count: u32 = 0,

    fn increase(self: *Controller, _: *const void, _: *Session) !void {
        self.count += 1;
    }

    fn bonus(self: *Controller, _: *const void, _: *Session) !void {
        self.count += 10;
    }
};
const Root = struct {
    clicks: u32 = 0,

    pub fn draw(_: *Root, ctx: *DrawCtx) !void {
        _ = try ctx.column(.{ .gap = 8 });
        defer ctx.pop();
        _ = try ctx.button(.{
            .key = .{ .static = "first" },
            .label = "First",
            .on_click = onClick,
        });
        _ = try ctx.button(.{
            .key = .{ .static = "second" },
            .label = "Second",
            .on_click = onClick,
        });
    }

    fn onClick(self: *Root) void {
        self.clicks += 1;
    }
};
const FakeClock = struct {
    now_ns: i96 = 0,

    fn now(raw: *anyopaque) i96 {
        const self: *FakeClock = @ptrCast(@alignCast(raw));
        return self.now_ns;
    }

    fn clock(self: *FakeClock) Clock {
        return .injected(self, now);
    }
};
const ctrl_g: keymap.Stroke = .{
    .key = .{ .physical = 44 },
    .modifiers = .{ .control = true },
};
const ctrl_h: keymap.Stroke = .{
    .key = .{ .physical = 45 },
    .modifiers = .{ .control = true },
};

fn press(app: *App, code: u32) !void {
    _ = try app.handle(.{ .key_down = .{
        .physical = .{ .code = code },
        .logical = .{ .character = if (code == 44) "g" else "h" },
        .modifiers = .{ .control = true },
    } });
}

fn expectCount(session: *Session, weak: anytype, expected: u32) !void {
    const Check = struct {
        fn run(value: *const Controller, want: u32) !void {
            try std.testing.expectEqual(want, value.count);
        }
    };
    try session.read(Controller, weak, expected, Check.run);
}

test "api-w10 App applies user override and disabled binding before key defaults" {
    const gpa = std.testing.allocator;
    var session = try Session.init(gpa);
    defer session.deinit() catch unreachable;
    var initial: Controller = .{};
    var controller = try session.create(Controller, &initial);
    defer session.release(Controller, &controller) catch unreachable;
    var registry = try action.Registry.init(gpa, &session);
    defer registry.deinit();
    try registry.register(Increase);
    try registry.register(Bonus);
    _ = try registry.bind(Increase, Controller, Controller.increase, null, .app, controller.weak());
    _ = try registry.bind(Bonus, Controller, Controller.bonus, null, .app, controller.weak());

    var time: FakeClock = .{};
    var shortcuts = try keymap.Keymap.init(gpa, time.clock(), 50);
    defer shortcuts.deinit();
    _ = try shortcuts.add(.{ .sequence = &.{ctrl_g}, .action = Increase.name }, .{
        .user = &time,
        .on_replay = noopReplay,
        .on_action = noopAction,
    });
    _ = try shortcuts.add(.{ .source = .user, .sequence = &.{ctrl_g}, .action = Bonus.name }, .{
        .user = &time,
        .on_replay = noopReplay,
        .on_action = noopAction,
    });

    var app = try App.init(gpa, &session);
    defer app.deinit();
    var root: Root = .{};
    try app.mountRoot(Root, &root);
    try app.attachShortcuts(&shortcuts, &registry);
    const output = try app.frame(1, .{ .width = 320, .height = 160 });
    defer if (output.json) |json| gpa.free(json);

    try press(&app, 44);
    try expectCount(&session, controller.weak(), 10);
    const disabled = try shortcuts.add(.{
        .source = .user,
        .sequence = &.{ctrl_g},
        .action = null,
    }, .{ .user = &time, .on_replay = noopReplay, .on_action = noopAction });
    try press(&app, 44);
    try expectCount(&session, controller.weak(), 10);
    try std.testing.expect(shortcuts.remove(disabled, .{
        .user = &time,
        .on_replay = noopReplay,
        .on_action = noopAction,
    }));
    try press(&app, 44);
    try expectCount(&session, controller.weak(), 20);
    _ = try app.handle(.{ .key_down = .{ .key = .tab } });
    try std.testing.expect(app.focus_manager.current != null);
    _ = try app.handle(.{ .key_down = .{ .key = .space } });
    try std.testing.expectEqual(@as(u32, 1), root.clicks);
}

test "api-w10 App resolves chord deadline and replays unmatched Tab once" {
    const gpa = std.testing.allocator;
    var session = try Session.init(gpa);
    defer session.deinit() catch unreachable;
    var initial: Controller = .{};
    var controller = try session.create(Controller, &initial);
    defer session.release(Controller, &controller) catch unreachable;
    var registry = try action.Registry.init(gpa, &session);
    defer registry.deinit();
    try registry.register(Increase);
    _ = try registry.bind(Increase, Controller, Controller.increase, null, .app, controller.weak());

    var time: FakeClock = .{};
    var shortcuts = try keymap.Keymap.init(gpa, time.clock(), 50);
    defer shortcuts.deinit();
    const sink: keymap.Sink = .{ .user = &time, .on_replay = noopReplay, .on_action = noopAction };
    _ = try shortcuts.add(.{ .sequence = &.{ctrl_g}, .action = Increase.name }, sink);
    _ = try shortcuts.add(.{ .sequence = &.{ ctrl_g, ctrl_h }, .action = Increase.name }, sink);

    var app = try App.init(gpa, &session);
    defer app.deinit();
    var root: Root = .{};
    try app.mountRoot(Root, &root);
    try app.attachShortcuts(&shortcuts, &registry);
    const output = try app.frame(1, .{ .width = 320, .height = 160 });
    defer if (output.json) |json| gpa.free(json);
    const first = app.widgetIdForKey(.root, .{ .static = "first" }) orelse return error.FirstButtonMissing;
    const second = app.widgetIdForKey(.root, .{ .static = "second" }) orelse return error.SecondButtonMissing;
    try std.testing.expect(!first.eql(second));

    try press(&app, 44);
    try expectCount(&session, controller.weak(), 0);
    try std.testing.expectEqual(@as(?i96, 50), app.nextShortcutDeadline());
    time.now_ns = 50;
    try app.tickShortcuts();
    try expectCount(&session, controller.weak(), 1);
    try std.testing.expectEqual(@as(?i96, null), app.nextShortcutDeadline());

    try press(&app, 44);
    try std.testing.expectEqual(@as(?i96, 100), app.nextShortcutDeadline());
    _ = try app.handle(.{ .key_down = .{ .key = .tab } });
    try std.testing.expect(first.eql(app.focus_manager.current orelse return error.MissingFocus));
    _ = try app.handle(.{ .key_down = .{ .key = .space } });
    try std.testing.expectEqual(@as(u32, 1), root.clicks);
}

// ── Focused field harness ────────────────────────
// A held chord owns a real key press and the platform commit that follows
// it. These tests count what each field actually receives, because "replayed
// once" is only a claim a consumer can check.

const event = @import("event.zig");
const text_input = @import("text_input.zig");
const Utf16Range = text_input.Utf16Range;
const Selection = text_input.Selection;
const geometry = @import("geometry.zig");
const WidgetId = @import("id.zig").WidgetId;
const FrameNodeId = @import("id.zig").FrameNodeId;
const Model = @import("model.zig").Model;
const model = @import("model.zig");

/// Scancodes are opaque identities here; the chord pair binds these two.
const g_key: u32 = 34;
const h_key: u32 = 35;

/// An ASCII field: one byte is one UTF-16 unit, which keeps the probe honest
/// about counts without reimplementing cluster segmentation.
const Field = struct {
    bytes: [48]u8 = @splat(0),
    len: usize = 0,
    caret: usize = 0,
    marked: ?Utf16Range = null,
    replaces: u32 = 0,

    fn slice(self: *const Field) []const u8 {
        return self.bytes[0..self.len];
    }

    fn clamp(self: *const Field, value: usize) usize {
        return @min(value, self.len);
    }
};

fn splice(field: *Field, low: usize, high: usize, text: []const u8) !void {
    const tail = field.len - high;
    if (text.len > field.bytes.len - low - tail) return error.FieldCapacityExceeded;
    @memmove(field.bytes[low + text.len ..][0..tail], field.bytes[high..][0..tail]);
    @memcpy(field.bytes[low..][0..text.len], text);
    field.len = low + text.len + tail;
}

fn fieldText(
    allocator: std.mem.Allocator,
    field: *const Field,
    _: *anyopaque,
    range: Utf16Range,
    served: *Utf16Range,
) anyerror!?[]u8 {
    const low = field.clamp(@min(range.start, range.end));
    const high = field.clamp(@max(range.start, range.end));
    served.* = .{ .start = low, .end = high };
    const value = try allocator.dupe(u8, field.slice()[low..high]);
    return value;
}

fn fieldSelection(field: *const Field, _: *anyopaque) anyerror!Selection {
    return .{ .range = .{ .start = field.caret, .end = field.caret } };
}

fn fieldMarked(field: *const Field, _: *anyopaque) anyerror!?Utf16Range {
    return field.marked;
}

fn fieldMove(field: *Field, _: *anyopaque, request: text_input.Move) anyerror!Selection {
    if (request.offset) |offset| {
        field.caret = field.clamp(offset);
    } else switch (request.unit) {
        .grapheme, .word => {
            field.caret = switch (request.direction) {
                .forward => @min(field.len, field.caret + 1),
                .backward => if (field.caret == 0) 0 else field.caret - 1,
            };
        },
        .line, .document => {
            field.caret = if (request.direction == .forward) field.len else 0;
        },
    }
    return .{ .range = .{ .start = field.caret, .end = field.caret } };
}

fn fieldErase(field: *Field, _: *anyopaque, request: text_input.Erase) anyerror!void {
    const at = field.clamp(field.caret);
    const low = if (request.backward) (if (at == 0) 0 else at - 1) else at;
    const high = if (request.backward) at else @min(field.len, at + 1);
    try splice(field, low, high, "");
    field.caret = low;
}

fn fieldReplace(field: *Field, _: *anyopaque, range: ?Utf16Range, text: []const u8) anyerror!void {
    const target = range orelse field.marked orelse Utf16Range{
        .start = field.caret,
        .end = field.caret,
    };
    const low = field.clamp(@min(target.start, target.end));
    const high = field.clamp(@max(target.start, target.end));
    try splice(field, low, high, text);
    field.marked = null;
    field.caret = low + text.len;
    field.replaces += 1;
}

fn fieldReplaceMark(
    field: *Field,
    _: *anyopaque,
    range: ?Utf16Range,
    text: []const u8,
    inside: ?Utf16Range,
) anyerror!void {
    const target = range orelse field.marked orelse Utf16Range{
        .start = field.caret,
        .end = field.caret,
    };
    const low = field.clamp(@min(target.start, target.end));
    const high = field.clamp(@max(target.start, target.end));
    try splice(field, low, high, text);
    const length = try text_input.utf16Length(text);
    field.marked = if (text.len == 0) null else Utf16Range{ .start = low, .end = low + length };
    field.caret = if (inside) |value| low + @min(value.end, length) else low + length;
    field.replaces += 1;
}

fn fieldUnmark(field: *Field, _: *anyopaque) anyerror!void {
    field.marked = null;
}

fn fieldCaret(field: *const Field, _: *anyopaque, range: Utf16Range) anyerror!?text_input.Caret {
    _ = field;
    return .{ .area = .{ .x = 8, .y = 0, .w = 0, .h = 18 }, .cursor = @floatFromInt(range.end) };
}

fn fieldIndexAt(field: *const Field, _: *anyopaque, point: geometry.WindowPoint) anyerror!?usize {
    _ = field;
    _ = point;
    return 0;
}

fn fieldOps() text_input.Ops {
    return text_input.Adapter(Field).ops(.{
        .text = fieldText,
        .selection = fieldSelection,
        .marked = fieldMarked,
        .move = fieldMove,
        .erase = fieldErase,
        .replace = fieldReplace,
        .replace_and_mark = fieldReplaceMark,
        .unmark = fieldUnmark,
        .caret = fieldCaret,
        .index_at = fieldIndexAt,
    });
}

/// The root view under test: two focusable buttons, each of which publishes
/// its own text endpoint when it takes the keyboard.
const Probe = struct {
    app: *App,
    first: ?text_input.Endpoint = null,
    second: ?text_input.Endpoint = null,
    hide_first: bool = false,
    clear_on_focus_out: bool = false,
    focus_outs: u32 = 0,

    pub fn draw(self: *Probe, ctx: *DrawCtx) !void {
        _ = try ctx.column(.{ .gap = 8 });
        defer ctx.pop();
        if (!self.hide_first) {
            _ = try ctx.button(.{
                .key = .{ .static = "first" },
                .label = "First",
            });
        }
        _ = try ctx.button(.{
            .key = .{ .static = "second" },
            .label = "Second",
        });
    }

    /// Publishing on focus_in is the whole wiring contract: a widget that
    /// never took the keyboard never owns the endpoint, so nothing reaches a
    /// consumer that lost focus.
    ///
    /// `clear_on_focus_out` is the legitimate cleanup a text field performs
    /// when the keyboard leaves it: it drops the registration it owns. Input
    /// the publication already handed that endpoint must survive it, so the
    /// App routes focus_out only after the deferred delivery.
    pub fn onRoutedEvent(self: *Probe, context: *event.DispatchContext) void {
        if (context.phase != .target) return;
        switch (context.event.*) {
            .focus_out => {
                self.focus_outs += 1;
                if (self.clear_on_focus_out) self.app.textInputManager().clear();
            },
            .focus_in => |change| {
                for ([_]?text_input.Endpoint{ self.first, self.second }) |endpoint| {
                    const value = endpoint orelse continue;
                    if (value.id.eql(change.target_id)) {
                        self.app.registerTextEndpoint(value);
                    }
                }
            },
            else => {},
        }
    }
};

/// A `.changed` listener that injects one commit while the App settles. The
/// commit's destination names the ordering: after the focus change completes
/// it belongs to the endpoint this publication registered, and during the
/// delivery it would belong to the endpoint that owns the keyboard and is
/// about to retire. The listener is called through a const payload, so its
/// observable count lives in a test-owned box.
const Mover = struct {
    app: *App,
    counter: *MoverCounter,

    fn onChanged(self: *const Mover, _: model.WeakModel(Field), _: *Session) void {
        self.counter.fired += 1;
        _ = self.app.handle(.{ .text_input = .{ .text = "y" } }) catch @panic("commit refused");
    }
};

const MoverCounter = struct { fired: u32 = 0 };

/// Which chords a test binds. A held `g` only has a shorter action in the
/// first case; the second forces a resolution to replay plain input.
const Chord = enum { with_shorter_action, longer_only };

const Ids = struct { first: WidgetId, second: WidgetId };

/// One App, two real fields and the keymap under test. The App keeps a
/// `*Session` and the keymap keeps this fixture's address, so the fixture is
/// initialized in place and never copied.
const Fields = struct {
    // SAFETY: init assigns every handle before any read.
    session: Session = undefined,
    // SAFETY: init assigns every handle before any read.
    app: App = undefined,
    // SAFETY: init assigns every handle before any read.
    registry: action.Registry = undefined,
    // SAFETY: init assigns every handle before any read.
    shortcuts: keymap.Keymap = undefined,
    // SAFETY: init assigns every handle before any read.
    controller: Model(Controller) = undefined,
    // SAFETY: init assigns every handle before any read.
    first: Model(Field) = undefined,
    // SAFETY: init assigns every handle before any read.
    second: Model(Field) = undefined,
    // SAFETY: init assigns the handle before observe reads it.
    mover: Model(Mover) = undefined,
    /// The listener payload is const, so the count it reports lives here.
    mover_count: MoverCounter = .{},
    time: FakeClock = .{},
    // SAFETY: init assigns every handle before any read.
    root: Probe = undefined,
    // SAFETY: replaceRoot mounts it; bind reads it only after that.
    replacement: Probe = undefined,
    /// Always one of the two views this fixture owns, so no test keeps a
    /// pointer to a root the App already retired.
    // SAFETY: init points it at `root` before any read, and every later
    // assignment names one of the two roots above.
    mounted: *Probe = undefined,

    fn init(self: *Fields, chord: Chord) !void {
        const gpa = std.testing.allocator;
        self.* = .{};
        self.session = try Session.init(gpa);
        self.app = try App.init(gpa, &self.session);
        var controller: Controller = .{};
        self.controller = try self.session.create(Controller, &controller);
        var first: Field = .{};
        self.first = try self.session.create(Field, &first);
        var second: Field = .{};
        self.second = try self.session.create(Field, &second);
        var mover: Mover = .{ .app = &self.app, .counter = &self.mover_count };
        self.mover = try self.session.create(Mover, &mover);
        self.registry = try action.Registry.init(gpa, &self.session);
        try self.registry.register(Increase);
        _ = try self.registry.bind(
            Increase,
            Controller,
            Controller.increase,
            null,
            .app,
            self.controller.weak(),
        );
        self.shortcuts = try keymap.Keymap.init(gpa, self.time.clock(), 50);
        const sink: keymap.Sink = .{
            .user = &self.time,
            .on_replay = noopReplay,
            .on_action = noopAction,
        };
        const g: keymap.Stroke = .{ .key = .{ .physical = g_key } };
        const h: keymap.Stroke = .{ .key = .{ .physical = h_key } };
        _ = try self.shortcuts.add(
            .{ .sequence = &.{ g, h }, .action = Increase.name },
            sink,
        );
        if (chord == .with_shorter_action) {
            _ = try self.shortcuts.add(
                .{ .sequence = &.{g}, .action = Increase.name },
                sink,
            );
        }
        self.root = .{ .app = &self.app };
        self.replacement = .{ .app = &self.app };
        self.mounted = &self.root;
        try self.app.mountRoot(Probe, &self.root);
        try self.app.attachShortcuts(&self.shortcuts, &self.registry);
    }

    fn deinit(self: *Fields) void {
        self.app.deinit();
        self.registry.deinit();
        self.shortcuts.deinit();
        self.session.release(Controller, &self.controller) catch @panic("controller release failed");
        self.session.release(Field, &self.first) catch @panic("first field release failed");
        self.session.release(Field, &self.second) catch @panic("second field release failed");
        self.session.release(Mover, &self.mover) catch @panic("mover release failed");
        self.session.deinit() catch @panic("session deinit failed");
        // SAFETY: every handle above is released, and no test reads the
        // fixture after its deferred deinit returns.
        self.* = undefined;
    }

    /// Publish one frame and release the JSON snapshot it owns.
    fn publish(self: *Fields, frame_number: u32) !void {
        const output = try self.app.frame(frame_number, .{ .width = 320, .height = 160 });
        if (output.json) |json| std.testing.allocator.free(json);
    }

    /// Publish one frame and give both buttons a real text endpoint over
    /// their own model, the wiring an application owns for the widget that
    /// takes the keyboard.
    fn bind(self: *Fields, frame_number: u32) !Ids {
        try self.publish(frame_number);
        const first = self.app.widgetIdForKey(.root, .{ .static = "first" }) orelse
            return error.MissingFirst;
        const second = self.app.widgetIdForKey(.root, .{ .static = "second" }) orelse
            return error.MissingSecond;
        self.mounted.first = .{
            .id = first,
            .owner = self.first.weak().erase(),
            .ops = fieldOps(),
            .user = &self.time,
        };
        self.mounted.second = .{
            .id = second,
            .owner = self.second.weak().erase(),
            .ops = fieldOps(),
            .user = &self.time,
        };
        return .{ .first = first, .second = second };
    }

    /// A successful root replacement revokes the old view. The fixture
    /// follows it, so later bindings reach the tree the App really publishes.
    fn replaceRoot(self: *Fields) !void {
        try self.app.replaceRoot(Probe, &self.replacement);
        self.mounted = &self.replacement;
    }

    /// One keystroke as a host delivers it: the key, then its commit.
    fn typeKey(self: *Fields, code: u32, text: []const u8) !void {
        _ = try self.app.handle(.{ .key_down = .{
            .physical = .{ .code = code },
            .logical = .{ .character = text },
        } });
        _ = try self.app.handle(.{ .text_input = .{ .text = text } });
    }

    fn expectField(
        self: *Fields,
        owner: Model(Field),
        text: []const u8,
        replaces: u32,
    ) !void {
        var seen: Field = .{};
        try self.session.read(Field, owner, &seen, struct {
            fn copy(field: *const Field, target: *Field) void {
                target.* = field.*;
            }
        }.copy);
        try std.testing.expectEqualStrings(text, seen.slice());
        try std.testing.expectEqual(replaces, seen.replaces);
    }

    fn expectCount(self: *Fields, expected: u32) !void {
        var seen: Controller = .{};
        try self.session.read(Controller, self.controller, &seen, struct {
            fn copy(value: *const Controller, target: *Controller) void {
                target.* = value.*;
            }
        }.copy);
        try std.testing.expectEqual(expected, seen.count);
    }

    fn expectFocus(self: *Fields, expected: ?WidgetId) !void {
        try std.testing.expectEqual(expected, self.app.focus_manager.current);
    }

    fn expectEndpoint(self: *Fields, expected: WidgetId) !void {
        try std.testing.expectEqual(
            expected,
            self.app.textInputManager().focusedId() orelse return error.MissingEndpoint,
        );
    }

    /// A `.changed` listener on the first field that injects one commit. It
    /// runs while the App settles the frame, so its destination names whether
    /// the deferred input reached the endpoint before or after that delivery.
    fn observeFirstWithMover(self: *Fields) !void {
        _ = try self.session.observe(
            Field,
            Mover,
            self.first.weak(),
            self.mover.weak(),
            Mover.onChanged,
        );
    }

    fn expectMoverFired(self: *Fields, expected: u32) !void {
        try std.testing.expectEqual(expected, self.mover_count.fired);
    }
};

test "api-w10 App delivers a held chord to the field a publication retires" {
    var fields: Fields = undefined;
    try fields.init(.with_shorter_action);
    defer fields.deinit();
    const ids = try fields.bind(1);

    _ = try fields.app.handle(.{ .key_down = .{ .key = .tab } });
    try fields.expectFocus(ids.first);
    try fields.expectEndpoint(ids.first);
    try fields.typeKey(g_key, "g");
    try std.testing.expectEqual(@as(?i96, 50), fields.app.nextShortcutDeadline());
    try fields.expectField(fields.first, "", 0);

    // The next publication removes the focused button. A frame may not write
    // a model, so the held key cannot be delivered while it builds.
    fields.mounted.hide_first = true;
    try fields.publish(2);

    // The field that owned the keyboard and its model are both still alive,
    // and the held key reached them exactly once: one insert, no action, and
    // nothing at all for the consumer that took the keyboard.
    try fields.expectField(fields.first, "g", 1);
    try fields.expectField(fields.second, "", 0);
    try fields.expectCount(0);
    try fields.expectFocus(ids.second);
    try fields.expectEndpoint(ids.second);
    try std.testing.expectEqual(@as(?i96, null), fields.app.nextShortcutDeadline());

    // The next commit belongs to the new focus alone: the retired endpoint
    // is gone, so the old field cannot receive a second copy.
    _ = try fields.app.handle(.{ .text_input = .{ .text = "x" } });
    try fields.expectField(fields.first, "g", 1);
    try fields.expectField(fields.second, "x", 1);
}

test "api-w10 App keeps a held chord across a publication that keeps its focus" {
    var fields: Fields = undefined;
    try fields.init(.with_shorter_action);
    defer fields.deinit();
    const ids = try fields.bind(1);

    _ = try fields.app.handle(.{ .key_down = .{ .key = .tab } });
    try fields.expectFocus(ids.first);
    try fields.typeKey(g_key, "g");
    try std.testing.expectEqual(@as(?i96, 50), fields.app.nextShortcutDeadline());

    // Nothing about the field changed, so its chord is still held.
    try fields.publish(2);
    try fields.expectFocus(ids.first);
    try fields.expectEndpoint(ids.first);
    try std.testing.expectEqual(@as(?i96, 50), fields.app.nextShortcutDeadline());
    try fields.expectField(fields.first, "", 0);

    // The second key still completes the chord across that publication, and
    // the action consumes both the held key and its commit.
    try fields.typeKey(h_key, "h");
    try fields.expectCount(1);
    try std.testing.expectEqual(@as(?i96, null), fields.app.nextShortcutDeadline());
    try fields.expectField(fields.first, "", 0);
}

test "api-w10 App replays a held chord under the endpoint a root swap retires" {
    var fields: Fields = undefined;
    try fields.init(.with_shorter_action);
    defer fields.deinit();
    const ids = try fields.bind(1);

    _ = try fields.app.handle(.{ .key_down = .{ .key = .tab } });
    try fields.expectFocus(ids.first);
    try fields.typeKey(g_key, "g");
    try std.testing.expectEqual(@as(?i96, 50), fields.app.nextShortcutDeadline());

    // A root replacement runs outside a frame, so the held key reaches the
    // field that owned the keyboard before that endpoint retires. No old
    // action fires, and the retired endpoint leaves nothing registered.
    try fields.replaceRoot();
    try fields.expectField(fields.first, "g", 1);
    try fields.expectField(fields.second, "", 0);
    try fields.expectCount(0);
    try std.testing.expectEqual(@as(?i96, null), fields.app.nextShortcutDeadline());
    try std.testing.expectEqual(@as(?WidgetId, null), fields.app.textInputManager().focusedId());
    try fields.expectFocus(null);

    // The replacement tree publishes the same model under a new identity:
    // the next commit lands once, next to the text the swap replayed.
    const fresh = try fields.bind(2);
    _ = try fields.app.handle(.{ .key_down = .{ .key = .tab } });
    try fields.expectFocus(fresh.first);
    try fields.expectEndpoint(fresh.first);
    _ = try fields.app.handle(.{ .text_input = .{ .text = "x" } });
    try fields.expectField(fields.first, "gx", 2);
    try fields.expectField(fields.second, "", 0);
}

test "api-w10 App replays a held chord under the field that Tab leaves" {
    var fields: Fields = undefined;
    try fields.init(.longer_only);
    defer fields.deinit();
    const ids = try fields.bind(1);

    _ = try fields.app.handle(.{ .key_down = .{ .key = .tab } });
    try fields.expectFocus(ids.first);
    try fields.expectEndpoint(ids.first);
    try fields.typeKey(g_key, "g");
    try std.testing.expectEqual(@as(?i96, 50), fields.app.nextShortcutDeadline());
    try fields.expectField(fields.first, "", 0);

    // Tab resolves the chord before the focus moves, so the held key and its
    // commit reach the field that still owns the keyboard.
    _ = try fields.app.handle(.{ .key_down = .{ .key = .tab } });
    try fields.expectFocus(ids.second);
    try fields.expectEndpoint(ids.second);
    try std.testing.expectEqual(@as(?i96, null), fields.app.nextShortcutDeadline());
    try fields.expectField(fields.first, "g", 1);
    try fields.expectField(fields.second, "", 0);
    try fields.expectCount(0);

    // The next commit belongs to the new focus alone.
    _ = try fields.app.handle(.{ .text_input = .{ .text = "x" } });
    try fields.expectField(fields.first, "g", 1);
    try fields.expectField(fields.second, "x", 1);
}

test "api-w10 App delivers held input before a listener injects a commit" {
    var fields: Fields = undefined;
    try fields.init(.with_shorter_action);
    defer fields.deinit();
    const ids = try fields.bind(1);
    try fields.observeFirstWithMover();

    _ = try fields.app.handle(.{ .key_down = .{ .key = .tab } });
    try fields.expectFocus(ids.first);
    try fields.expectEndpoint(ids.first);
    try fields.typeKey(g_key, "g");
    try std.testing.expectEqual(@as(?i96, 50), fields.app.nextShortcutDeadline());
    try fields.expectField(fields.first, "", 0);

    // The publication retires the focused field, so the held key waits for
    // the frame to close. Writing it queues a `.changed` observation, and
    // the listener behind that observation injects one commit. Delivery is
    // suspended until the whole focus change completes, so that commit
    // belongs to the endpoint this publication registered — not to the
    // endpoint that owned the keyboard and has just been retired.
    fields.mounted.hide_first = true;
    try fields.publish(2);
    try fields.expectMoverFired(1);
    try fields.expectField(fields.first, "g", 1);
    try fields.expectField(fields.second, "y", 1);
    try fields.expectCount(0);
    try fields.expectFocus(ids.second);
    try fields.expectEndpoint(ids.second);
    try std.testing.expectEqual(@as(?i96, null), fields.app.nextShortcutDeadline());
}

/// A root whose element hook fails on demand, so a frame can be made to fail
/// AFTER the overlay frame has been staged and before the tree is published.
const FailingElement = struct {
    fail: bool = false,

    pub fn measure(_: *const FailingElement, input: element.MeasureInput) element.Error!widget.Size {
        _ = input;
        return .{ .width = 40, .height = 20 };
    }

    pub const PhaseState = struct {};

    /// `PaintCapacityExceeded` is a member of the element error set, so a hook
    /// can refuse with a real one: this element declines to produce its paint.
    pub fn prepaint(self: *const FailingElement, _: *PhaseState, _: element.Geometry) element.Error!void {
        if (self.fail) return error.PaintCapacityExceeded;
    }

    pub fn draw(self: *FailingElement, ctx: *DrawCtx) !void {
        _ = try ctx.elementLeaf(FailingElement, self.*, .{});
    }
};

/// A root with two keyed buttons and a custom element, over one App and one
/// real overlay frame, so a frame can be failed after the overlay is staged.
const OverlayProbe = struct {
    app: *App,
    frame: overlay.Frame,
    element: FailingElement = .{},
    open: bool = true,
    clicks: u32 = 0,

    pub fn draw(self: *OverlayProbe, ctx: *DrawCtx) !void {
        _ = try ctx.column(.{ .gap = 4 });
        const anchor_node = try ctx.button(.{
            .key = .{ .static = "anchor" },
            .label = "Anchor",
            .on_click = onClick,
            .width = 60,
            .height = 20,
        });
        var popup_node: ?FrameNodeId = null;
        if (self.open) {
            popup_node = try ctx.button(.{
                .key = .{ .static = "popup" },
                .label = "Popup",
                .on_click = onClick,
                .width = 60,
                .height = 20,
                .position = .absolute,
            });
        }
        ctx.pop();
        try ctx.component(FailingElement, .{ .key = .{ .static = "hook" } }, &self.element);
        if (popup_node) |popup| {
            // Placement is authored in the draw that built the content, and
            // the App resolves it after layout.
            try ctx.place(.{
                .anchor = ctx.widgetIdOf(anchor_node) orelse return error.UnkeyedAnchor,
                .content = ctx.widgetIdOf(popup) orelse return error.UnkeyedPopup,
                .side = .below,
                .clip = .window_escape,
            });
        }
    }

    fn onClick(self: *OverlayProbe) void {
        self.clicks += 1;
    }
};

test "api-w10 App keeps overlays through failed publication and root replacement" {
    const gpa = std.testing.allocator;
    var session = try Session.init(gpa);
    defer session.deinit() catch unreachable;
    var app = try App.init(gpa, &session);
    var view: OverlayProbe = .{ .app = &app, .frame = overlay.Frame.init(gpa) };
    defer view.frame.deinit();
    defer app.deinit();
    app.setOverlayFrame(&view.frame);
    try app.mountRoot(OverlayProbe, &view);

    // Frame one publishes. The popup sits below its anchor and the App routes
    // the point in the POPUP, not the anchor it covers.
    _ = try app.frame(1, .{ .width = 200, .height = 200 });
    const committed = app.tree_ptr orelse return error.NoCommittedTree;
    const anchor = app.widgetIdForKey(.root, .{ .static = "anchor" }) orelse
        return error.MissingAnchor;
    const popup = app.widgetIdForKey(.root, .{ .static = "popup" }) orelse
        return error.MissingPopup;
    const placement = view.frame.placement(committed, popup) orelse return error.UnplacedPopup;
    const anchor_node = committed.frameNode(anchor) orelse return error.MissingAnchorNode;
    try std.testing.expectEqual(
        placement.rect.x,
        widget.visualBorderRect(committed, anchor_node).x,
    );
    // A mounted child cannot also become the root. Rejecting that replacement
    // must leave the current overlay usable, not just its tree pointer.
    try std.testing.expectError(
        error.ComponentAlreadyMounted,
        app.replaceRoot(FailingElement, &view.element),
    );
    try std.testing.expectEqual(@as(?*const widget.WidgetTree, committed), app.tree_ptr);
    const retained = view.frame.placement(committed, popup) orelse
        return error.LostRejectedRootPlacement;
    try std.testing.expectEqual(placement.rect, retained.rect);

    // Frame two fails in an element hook: AFTER the overlay frame staged its
    // placement, BEFORE the tree is published. The committed frame keeps
    // routing and keeps its placements.
    view.element.fail = true;
    try std.testing.expectError(error.PaintCapacityExceeded, app.frame(2, .{
        .width = 200,
        .height = 200,
    }));
    view.element.fail = false;

    // The committed tree is untouched, and the frame still answers for IT —
    // not for the failed attempt, and not with no answer at all.
    try std.testing.expectEqual(@as(?*const widget.WidgetTree, committed), app.tree_ptr);
    const after = view.frame.placement(app.tree_ptr.?, popup) orelse
        return error.LostOverlayPlacement;
    try std.testing.expectEqual(placement.rect, after.rect);
    // A press at the placed popup reaches the popup: routing survived the
    // failure instead of falling back to the anchor underneath it.
    _ = try app.handle(.{ .mouse_down = .{
        .x = placement.rect.x + 1,
        .y = placement.rect.y + 1,
        .button = .left,
    } });
    _ = try app.handle(.{ .mouse_up = .{
        .x = placement.rect.x + 1,
        .y = placement.rect.y + 1,
        .button = .left,
    } });
    try std.testing.expectEqual(@as(u32, 1), view.clicks);
    try std.testing.expectEqual(@as(?WidgetId, popup), app.focus_manager.current);
}

test "api-w10 App keeps delivered input when focus_out releases the endpoint" {
    var fields: Fields = undefined;
    try fields.init(.with_shorter_action);
    defer fields.deinit();
    const ids = try fields.bind(1);

    _ = try fields.app.handle(.{ .key_down = .{ .key = .tab } });
    try fields.expectFocus(ids.first);
    try fields.expectEndpoint(ids.first);
    try fields.typeKey(g_key, "g");
    try std.testing.expectEqual(@as(?i96, 50), fields.app.nextShortcutDeadline());

    // The retiring field drops its registration when it hears focus_out,
    // which is what a text field does when the keyboard leaves it. The held
    // key reached that endpoint first, so the text is already written when
    // the cleanup runs.
    fields.mounted.hide_first = true;
    fields.mounted.clear_on_focus_out = true;
    try fields.publish(2);
    try std.testing.expectEqual(@as(u32, 1), fields.mounted.focus_outs);
    try fields.expectField(fields.first, "g", 1);
    try fields.expectField(fields.second, "", 0);
    try fields.expectCount(0);
    try fields.expectFocus(ids.second);
    try std.testing.expectEqual(@as(?i96, null), fields.app.nextShortcutDeadline());
}

fn noopReplay(_: *anyopaque, _: keymap.Replay) void {}
fn noopAction(_: *anyopaque, _: keymap.Action) void {}

test "api-w10 detaching releases borrowed shortcuts even when the field refuses held text" {
    var fields: Fields = undefined;
    try fields.init(.longer_only);
    defer fields.deinit();
    const ids = try fields.bind(1);
    _ = try fields.app.handle(.{ .key_down = .{ .key = .tab } });
    try fields.expectFocus(ids.first);
    const Fill = struct {
        fn run(field: *Field, _: void) void {
            @memset(&field.bytes, 'x');
            field.len = field.bytes.len;
            field.caret = field.len;
        }
    };
    try fields.session.update(Field, fields.first, {}, Fill.run);
    try fields.typeKey(g_key, "g");
    try std.testing.expect(fields.app.nextShortcutDeadline() != null);

    try std.testing.expectError(error.FieldCapacityExceeded, fields.app.detachShortcuts());
    try std.testing.expect(fields.app.shortcuts == null);
    try std.testing.expect(fields.app.nextShortcutDeadline() == null);
    try fields.expectField(fields.first, &@as([48]u8, @splat('x')), 0);

    _ = try fields.app.handle(.{ .key_down = .{ .key = .tab } });
    try fields.expectFocus(ids.second);
    try fields.typeKey(g_key, "g");
    try fields.expectField(fields.second, "g", 1);
}
