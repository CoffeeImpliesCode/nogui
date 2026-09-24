const std = @import("std");
const event = @import("event.zig");
const clock_module = @import("clock.zig");
const keymap = @import("keymap.zig");

const Scope = keymap.Scope;
const Keymap = keymap.Keymap;
const Stroke = keymap.Stroke;

const FakeClock = struct {
    now_ns: i96 = 0,

    fn now(raw: *anyopaque) i96 {
        const self: *FakeClock = @ptrCast(@alignCast(raw));
        return self.now_ns;
    }

    fn clock(self: *FakeClock) clock_module.Clock {
        return .injected(self, now);
    }
};

const Received = union(enum) {
    down: struct { code: ?u32, repeat: bool, owner: u64 },
    up: u64,
    text: struct { bytes: [64]u8, len: usize, owner: u64 },
    action: struct { name: []const u8, owner: u64 },
};

const Items = struct {
    // SAFETY: only entries before len are read.
    values: [64]Received = undefined,
    len: usize = 0,

    fn append(self: *Items, value: Received) void {
        // A dropped entry would silently shift the index-based expectations.
        std.debug.assert(self.len < self.values.len);
        self.values[self.len] = value;
        self.len += 1;
    }

    fn constSlice(self: *const Items) []const Received {
        return self.values[0..self.len];
    }
};

const Recorder = struct {
    items: Items = .{},

    fn sink(self: *Recorder) keymap.Sink {
        return .{ .user = self, .on_replay = replay, .on_action = action };
    }

    fn replay(raw: *anyopaque, value: keymap.Replay) void {
        const self: *Recorder = @ptrCast(@alignCast(raw));
        const item: Received = switch (value.input) {
            .key_down => |key| .{ .down = .{
                .code = if (key.physical) |code| code.code else null,
                .repeat = key.repeat,
                .owner = value.focus_token,
            } },
            .key_up => .{ .up = value.focus_token },
            .text_input => |text| blk: {
                std.debug.assert(text.text.len <= 64);
                var bytes: [64]u8 = undefined;
                @memcpy(bytes[0..text.text.len], text.text);
                break :blk .{ .text = .{
                    .bytes = bytes,
                    .len = text.text.len,
                    .owner = value.focus_token,
                } };
            },
            else => unreachable,
        };
        self.items.append(item);
    }

    fn action(raw: *anyopaque, value: keymap.Action) void {
        const self: *Recorder = @ptrCast(@alignCast(raw));
        self.items.append(.{ .action = .{
            .name = value.name,
            .owner = value.focus_token,
        } });
    }

    fn expectAction(self: *const Recorder, index: usize, name: []const u8) !void {
        const item = self.items.constSlice()[index];
        try std.testing.expect(item == .action);
        try std.testing.expectEqualStrings(name, item.action.name);
    }

    fn expectText(self: *const Recorder, index: usize, text: []const u8) !void {
        const item = self.items.constSlice()[index];
        try std.testing.expect(item == .text);
        try std.testing.expectEqualStrings(text, item.text.bytes[0..item.text.len]);
    }
};

fn logical(character: []const u8) event.KeyEvent {
    return .{ .logical = .{ .character = character } };
}

fn physical(code: u32, character: []const u8) event.KeyEvent {
    return .{ .physical = .{ .code = code }, .logical = .{ .character = character } };
}

const document: Scope = .{ .contexts = &.{"document"}, .focus_token = 10 };
const g: Stroke = .{ .key = .{ .logical = .{ .character = "g" } } };
const x: Stroke = .{ .key = .{ .logical = .{ .character = "x" } } };

test "api-w10 ambiguous prefix waits, then exact chord consumes key text once" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    _ = try map.add(.{ .source = .builtin, .context = "document", .sequence = &.{g}, .action = "open" }, record.sink());
    _ = try map.add(
        .{ .source = .builtin, .context = "document", .sequence = &.{ g, g }, .action = "open-all" },
        record.sink(),
    );

    try std.testing.expectEqual(keymap.Decision.waiting, map.keyDown(logical("g"), document, false, record.sink()));
    map.textInput("g", document.focus_token, false, record.sink());
    try std.testing.expectEqual(@as(usize, 0), record.items.len);
    try std.testing.expectEqual(@as(?i96, 50), map.nextDeadline());
    time.now_ns = 49;
    map.tick(record.sink());
    try std.testing.expectEqual(@as(usize, 0), record.items.len);
    try std.testing.expectEqual(keymap.Decision.handled, map.keyDown(logical("g"), document, false, record.sink()));
    map.textInput("g", document.focus_token, false, record.sink());
    try std.testing.expectEqual(@as(usize, 1), record.items.len);
    try record.expectAction(0, "open-all");
    try std.testing.expectEqual(@as(?i96, null), map.nextDeadline());
}

test "api-w10 timeout commits ambiguous shorter action at the exact deadline" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    _ = try map.add(.{ .source = .builtin, .context = "document", .sequence = &.{g}, .action = "open" }, record.sink());
    _ = try map.add(
        .{ .source = .builtin, .context = "document", .sequence = &.{ g, g }, .action = "open-all" },
        record.sink(),
    );
    _ = map.keyDown(logical("g"), document, false, record.sink());
    map.textInput("g", document.focus_token, false, record.sink());
    time.now_ns = 50;
    map.tick(record.sink());
    try std.testing.expectEqual(@as(usize, 1), record.items.len);
    try record.expectAction(0, "open");
    map.tick(record.sink());
    try std.testing.expectEqual(@as(usize, 1), record.items.len);
}

test "api-w10 unmatched suffix replays buffered key and text before new key" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    _ = try map.add(
        .{ .source = .builtin, .context = "document", .sequence = &.{ g, g }, .action = "open-all" },
        record.sink(),
    );
    _ = map.keyDown(physical(34, "g"), document, false, record.sink());
    map.textInput("g", document.focus_token, false, record.sink());
    try std.testing.expectEqual(keymap.Decision.passed, map.keyDown(physical(45, "x"), document, false, record.sink()));
    map.textInput("x", document.focus_token, false, record.sink());
    try std.testing.expectEqual(@as(usize, 4), record.items.len);
    try std.testing.expectEqual(@as(?u32, 34), record.items.constSlice()[0].down.code);
    try record.expectText(1, "g");
    try std.testing.expectEqual(@as(?u32, 45), record.items.constSlice()[2].down.code);
    try record.expectText(3, "x");
    time.now_ns = 100;
    map.tick(record.sink());
    try std.testing.expectEqual(@as(usize, 4), record.items.len);
}

test "api-w10 timeout with no complete prefix replays key text and key-up in order" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    _ = try map.add(
        .{ .source = .builtin, .context = "document", .sequence = &.{ g, g }, .action = "open-all" },
        record.sink(),
    );
    _ = map.keyDown(physical(34, "g"), document, false, record.sink());
    map.textInput("g", document.focus_token, false, record.sink());
    map.keyUp(physical(34, "g"), document.focus_token, record.sink());
    time.now_ns = 50;
    map.tick(record.sink());
    try std.testing.expectEqual(@as(usize, 3), record.items.len);
    try std.testing.expect(record.items.constSlice()[0] == .down);
    try record.expectText(1, "g");
    try std.testing.expect(record.items.constSlice()[2] == .up);
}

test "api-w10 nearest context wins before layer; user, latest and disabled override ties" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    const modal: Scope = .{ .contexts = &.{ "modal", "document" }, .focus_token = 12 };
    _ = try map.add(
        .{ .source = .builtin, .context = "modal", .sequence = &.{g}, .action = "close-modal" },
        record.sink(),
    );
    _ = try map.add(
        .{ .source = .user, .context = "document", .sequence = &.{g}, .action = "document-user" },
        record.sink(),
    );
    _ = map.keyDown(logical("g"), modal, false, record.sink());
    try record.expectAction(0, "close-modal");
    const previous = try map.add(
        .{ .source = .user, .context = "modal", .sequence = &.{g}, .action = "modal-user" },
        record.sink(),
    );
    _ = map.keyDown(logical("g"), modal, false, record.sink());
    try record.expectAction(1, "modal-user");
    _ = try map.add(.{ .source = .user, .context = "modal", .sequence = &.{g}, .action = "latest" }, record.sink());
    _ = map.keyDown(logical("g"), modal, false, record.sink());
    try record.expectAction(2, "latest");
    const disabled = try map.add(
        .{ .source = .user, .context = "modal", .sequence = &.{g}, .action = null },
        record.sink(),
    );
    try std.testing.expectEqual(keymap.Decision.handled, map.keyDown(logical("g"), modal, false, record.sink()));
    try std.testing.expectEqual(@as(usize, 3), record.items.len);
    try std.testing.expect(map.remove(disabled, record.sink()));
    _ = map.keyDown(logical("g"), modal, false, record.sink());
    try record.expectAction(3, "latest");
    try std.testing.expect(map.remove(previous, record.sink()));
}

test "api-w10 physical and logical identities remain distinct from mutable labels" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    const physical_id = try map.add(
        .{
            .source = .user,
            .context = "document",
            .sequence = &.{.{ .key = .{ .physical = 34 } }},
            .action = "physical",
            .label = "G",
        },
        record.sink(),
    );
    _ = try map.add(
        .{ .source = .builtin, .context = "document", .sequence = &.{g}, .action = "logical" },
        record.sink(),
    );
    try map.setLabel(physical_id, "É");
    try std.testing.expectEqualStrings("É", map.label(physical_id).?);
    _ = map.keyDown(physical(34, "é"), document, false, record.sink());
    try record.expectAction(0, "physical");
    _ = map.keyDown(physical(21, "g"), document, false, record.sink());
    try record.expectAction(1, "logical");
    _ = map.keyDown(.{ .logical = .{ .codepoint = 'g' } }, document, false, record.sink());
    try record.expectAction(2, "logical");
}

test "api-w10 repeat never advances a chord and preserves repeat text once" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    _ = try map.add(
        .{ .source = .builtin, .context = "document", .sequence = &.{ g, g }, .action = "open-all" },
        record.sink(),
    );
    _ = map.keyDown(physical(34, "g"), document, false, record.sink());
    map.textInput("g", document.focus_token, false, record.sink());
    var repeated = physical(34, "g");
    repeated.repeat = true;
    try std.testing.expectEqual(keymap.Decision.passed, map.keyDown(repeated, document, false, record.sink()));
    map.textInput("g", document.focus_token, false, record.sink());
    try std.testing.expectEqual(@as(usize, 4), record.items.len);
    try std.testing.expect(record.items.constSlice()[2].down.repeat);
    try record.expectText(1, "g");
    try record.expectText(3, "g");
}

test "api-w10 focus changes replay to old owner and prevented routed keys never shortcut" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    _ = try map.add(
        .{ .source = .builtin, .context = "document", .sequence = &.{ g, g }, .action = "open-all" },
        record.sink(),
    );
    _ = map.keyDown(physical(34, "g"), document, false, record.sink());
    map.textInput("g", document.focus_token, false, record.sink());
    map.focusChanged(record.sink());
    try std.testing.expectEqual(@as(usize, 2), record.items.len);
    try std.testing.expectEqual(@as(u64, 10), record.items.constSlice()[0].down.owner);
    try std.testing.expectEqual(@as(u64, 10), record.items.constSlice()[1].text.owner);
    const next: Scope = .{ .contexts = &.{"document"}, .focus_token = 11 };
    try std.testing.expectEqual(keymap.Decision.prevented, map.keyDown(logical("g"), next, true, record.sink()));
    try std.testing.expectEqual(@as(usize, 2), record.items.len);
}

test "api-w10 bounded pending storage bypasses large text without truncating it" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    _ = try map.add(
        .{ .source = .builtin, .context = "document", .sequence = &.{ g, g }, .action = "open-all" },
        record.sink(),
    );
    _ = map.keyDown(logical("g"), document, false, record.sink());
    const long_text = [_]u8{'p'} ** (keymap.max_input_bytes + 1);
    // This sink counts lengths without storing an oversized payload.
    const Counter = struct {
        const Self = @This();
        text_len: usize = 0,
        key_count: usize = 0,
        fn replay(raw: *anyopaque, value: keymap.Replay) void {
            const self: *Self = @ptrCast(@alignCast(raw));
            switch (value.input) {
                .key_down => self.key_count += 1,
                .text_input => |text| self.text_len = text.text.len,
                else => {},
            }
        }
        fn action(_: *anyopaque, _: keymap.Action) void {
            unreachable;
        }
    };
    var count: Counter = .{};
    map.textInput(&long_text, document.focus_token, false, .{
        .user = &count,
        .on_replay = Counter.replay,
        .on_action = Counter.action,
    });
    try std.testing.expectEqual(@as(usize, 1), count.key_count);
    try std.testing.expectEqual(long_text.len, count.text_len);
    try std.testing.expectEqual(@as(?i96, null), map.nextDeadline());
}

test "api-w10 configuration errors do not silently ignore options" {
    var time: FakeClock = .{};
    try std.testing.expectError(error.InvalidTimeout, Keymap.init(std.testing.allocator, time.clock(), 0));
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    try std.testing.expectError(
        error.EmptySequence,
        map.add(.{ .context = "document", .sequence = &.{}, .action = "x" }, record.sink()),
    );
    const too_many = [_]Stroke{g} ** (keymap.max_steps + 1);
    try std.testing.expectError(
        error.TooManySteps,
        map.add(.{ .context = "document", .sequence = &too_many, .action = "x" }, record.sink()),
    );
    try std.testing.expectError(
        error.EmptyAction,
        map.add(.{ .context = "document", .sequence = &.{g}, .action = "" }, record.sink()),
    );
}

test "api-w10 ambiguous prefix waits even when short binding was registered last" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    _ = try map.add(.{ .context = "document", .sequence = &.{ g, g }, .action = "long" }, record.sink());
    _ = try map.add(.{ .context = "document", .sequence = &.{g}, .action = "short" }, record.sink());
    try std.testing.expectEqual(keymap.Decision.waiting, map.keyDown(logical("g"), document, false, record.sink()));
    time.now_ns = 50;
    map.tick(record.sink());
    try std.testing.expectEqual(@as(usize, 1), record.items.len);
    try record.expectAction(0, "short");
}

test "api-w10 nearer exact beats distant chord and user exact beats builtin chord" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    _ = try map.add(.{ .context = "document", .sequence = &.{ g, g }, .action = "distant" }, record.sink());
    _ = try map.add(.{ .context = "modal", .sequence = &.{g}, .action = "near" }, record.sink());
    const modal: Scope = .{ .contexts = &.{ "modal", "document" }, .focus_token = 3 };
    try std.testing.expectEqual(keymap.Decision.handled, map.keyDown(logical("g"), modal, false, record.sink()));
    try record.expectAction(0, "near");
    _ = try map.add(
        .{ .source = .user, .context = "document", .sequence = &.{g}, .action = "user-short" },
        record.sink(),
    );
    try std.testing.expectEqual(keymap.Decision.handled, map.keyDown(logical("g"), document, false, record.sink()));
    try record.expectAction(1, "user-short");
}

test "api-w10 failed chord commits short action before unmatched suffix and its text" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    _ = try map.add(.{ .context = "document", .sequence = &.{g}, .action = "short" }, record.sink());
    _ = try map.add(.{ .context = "document", .sequence = &.{ g, g }, .action = "long" }, record.sink());
    _ = map.keyDown(logical("g"), document, false, record.sink());
    map.textInput("g", document.focus_token, false, record.sink());
    try std.testing.expectEqual(keymap.Decision.passed, map.keyDown(physical(45, "x"), document, false, record.sink()));
    map.textInput("x", document.focus_token, false, record.sink());
    try std.testing.expectEqual(@as(usize, 3), record.items.len);
    try record.expectAction(0, "short");
    try std.testing.expectEqual(@as(?u32, 45), record.items.constSlice()[1].down.code);
    try record.expectText(2, "x");
}

test "api-w10 bindings own configured strings across caller changes" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    var label_bytes = [_]u8{ 'O', 'l', 'd' };
    var name_bytes = [_]u8{ 'r', 'u', 'n' };
    var context_bytes = [_]u8{ 'd', 'o', 'c' };
    var key_bytes = [_]u8{'g'};
    const id = try map.add(
        .{
            .source = .user,
            .context = &context_bytes,
            .sequence = &.{.{ .key = .{ .logical = .{ .character = &key_bytes } } }},
            .action = &name_bytes,
            .label = &label_bytes,
        },
        record.sink(),
    );
    @memset(&label_bytes, 'x');
    @memset(&name_bytes, 'x');
    @memset(&context_bytes, 'x');
    @memset(&key_bytes, 'x');
    try std.testing.expectEqualStrings("Old", map.label(id).?);
    const scope: Scope = .{ .contexts = &.{"doc"}, .focus_token = 2 };
    _ = map.keyDown(logical("g"), scope, false, record.sink());
    try record.expectAction(0, "run");
}

test "api-w10 unrelated text after handled key is not silently discarded" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    _ = try map.add(.{ .context = "document", .sequence = &.{g}, .action = "open" }, record.sink());
    _ = map.keyDown(logical("g"), document, false, record.sink());
    map.textInput("paste", document.focus_token, false, record.sink());
    try std.testing.expectEqual(@as(usize, 2), record.items.len);
    try record.expectAction(0, "open");
    try record.expectText(1, "paste");
}

test "api-w10 unrelated text interrupts pending chord and replays both inputs" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    _ = try map.add(.{ .context = "document", .sequence = &.{ g, g }, .action = "long" }, record.sink());
    _ = map.keyDown(logical("g"), document, false, record.sink());
    map.textInput("paste", document.focus_token, false, record.sink());
    try std.testing.expectEqual(@as(usize, 2), record.items.len);
    try std.testing.expect(record.items.constSlice()[0] == .down);
    try record.expectText(1, "paste");
    try std.testing.expectEqual(@as(?i96, null), map.nextDeadline());
}

test "api-w10 exact shortcut consumes only its matching committed text" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    _ = try map.add(.{ .context = "document", .sequence = &.{g}, .action = "open" }, record.sink());
    _ = map.keyDown(logical("g"), document, false, record.sink());
    map.textInput("g", document.focus_token, false, record.sink());
    map.textInput("other", document.focus_token, false, record.sink());
    try std.testing.expectEqual(@as(usize, 2), record.items.len);
    try record.expectAction(0, "open");
    try record.expectText(1, "other");
}

test "api-w10 a three-step chord resets its deadline after each valid stroke" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    const third: Stroke = .{ .key = .{ .logical = .{ .character = "z" } } };
    _ = try map.add(.{ .context = "document", .sequence = &.{ g, x, third }, .action = "three" }, record.sink());
    _ = map.keyDown(logical("g"), document, false, record.sink());
    map.textInput("g", document.focus_token, false, record.sink());
    time.now_ns = 49;
    try std.testing.expectEqual(keymap.Decision.waiting, map.keyDown(logical("x"), document, false, record.sink()));
    map.textInput("x", document.focus_token, false, record.sink());
    try std.testing.expectEqual(@as(?i96, 99), map.nextDeadline());
    time.now_ns = 98;
    try std.testing.expectEqual(keymap.Decision.handled, map.keyDown(logical("z"), document, false, record.sink()));
    map.textInput("z", document.focus_token, false, record.sink());
    try std.testing.expectEqual(@as(usize, 1), record.items.len);
    try record.expectAction(0, "three");
}

test "api-w10 pending text storage copies source bytes and flushes at capacity" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    _ = try map.add(.{ .context = "document", .sequence = &.{ g, g }, .action = "long" }, record.sink());
    var original_key = [_]u8{'g'};
    _ = map.keyDown(logical(&original_key), document, false, record.sink());
    original_key[0] = 'x';
    var original_text = [_]u8{'g'};
    for (0..keymap.max_pending_events) |_| {
        map.textInput(&original_text, document.focus_token, false, record.sink());
    }
    original_text[0] = 'x';
    try std.testing.expectEqual(@as(usize, keymap.max_pending_events + 1), record.items.len);
    try std.testing.expect(record.items.constSlice()[0] == .down);
    try record.expectText(1, "g");
    try record.expectText(keymap.max_pending_events - 1, "g");
    try record.expectText(keymap.max_pending_events, "g");
    try std.testing.expectEqual(@as(?i96, null), map.nextDeadline());
}

test "api-w10 modifiers match physical side requirements without assuming layout" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    _ = try map.add(
        .{
            .context = "document",
            .sequence = &.{.{ .key = .{ .physical = 34 }, .modifiers = .{ .left_control = true } }},
            .action = "left",
        },
        record.sink(),
    );
    var right = physical(34, "q");
    right.modifiers = .{ .control = true, .right_control = true };
    try std.testing.expectEqual(keymap.Decision.passed, map.keyDown(right, document, false, record.sink()));
    var left = physical(34, "é");
    left.modifiers = .{ .control = true, .left_control = true };
    try std.testing.expectEqual(keymap.Decision.handled, map.keyDown(left, document, false, record.sink()));
    try std.testing.expectEqual(@as(usize, 2), record.items.len);
    try record.expectAction(1, "left");
}

test "api-w10 repeat is opt-in for single-step shortcut" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    var repeated = logical("g");
    repeated.repeat = true;
    _ = try map.add(.{ .context = "document", .sequence = &.{g}, .action = "once" }, record.sink());
    try std.testing.expectEqual(keymap.Decision.passed, map.keyDown(repeated, document, false, record.sink()));
    _ = try map.add(
        .{ .source = .user, .context = "document", .sequence = &.{g}, .action = "repeat", .allow_repeat = true },
        record.sink(),
    );
    try std.testing.expectEqual(keymap.Decision.handled, map.keyDown(repeated, document, false, record.sink()));
    try record.expectAction(1, "repeat");
    try std.testing.expectError(
        error.RepeatChordUnsupported,
        map.add(
            .{ .context = "document", .sequence = &.{ g, g }, .action = "bad", .allow_repeat = true },
            record.sink(),
        ),
    );
}

test "api-w10 binding replacement flushes pending input before changing meaning" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    _ = try map.add(.{ .context = "document", .sequence = &.{ g, g }, .action = "original" }, record.sink());
    _ = map.keyDown(logical("g"), document, false, record.sink());
    map.textInput("g", document.focus_token, false, record.sink());
    _ = try map.add(
        .{ .source = .user, .context = "document", .sequence = &.{ g, g }, .action = "replacement" },
        record.sink(),
    );
    try std.testing.expectEqual(@as(usize, 2), record.items.len);
    try std.testing.expect(record.items.constSlice()[0] == .down);
    try record.expectText(1, "g");
    _ = map.keyDown(logical("g"), document, false, record.sink());
    _ = map.keyDown(logical("g"), document, false, record.sink());
    try std.testing.expectEqual(@as(usize, 3), record.items.len);
    try record.expectAction(2, "replacement");
}

test "api-w10 context eligibility change cannot complete an old chord" {
    var time: FakeClock = .{};
    var map = try Keymap.init(std.testing.allocator, time.clock(), 50);
    defer map.deinit();
    var record: Recorder = .{};
    _ = try map.add(.{ .context = "document", .sequence = &.{ g, g }, .action = "old" }, record.sink());
    _ = map.keyDown(logical("g"), document, false, record.sink());
    const changed: Scope = .{
        .contexts = &.{"document"},
        .focus_token = document.focus_token,
        .context_token = 2,
    };
    try std.testing.expectEqual(keymap.Decision.waiting, map.keyDown(logical("g"), changed, false, record.sink()));
    try std.testing.expectEqual(@as(usize, 1), record.items.len);
    try std.testing.expect(record.items.constSlice()[0] == .down);
    time.now_ns = 50;
    map.tick(record.sink());
    try std.testing.expectEqual(@as(usize, 2), record.items.len);
    try std.testing.expect(record.items.constSlice()[1] == .down);
}
