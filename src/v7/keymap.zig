//! Configurable shortcut matching after routed input has had a chance to prevent its default.
//! Replays go only to the deferred default-input path, never back through event dispatch.
const std = @import("std");
const event = @import("event.zig");
const Clock = @import("clock.zig").Clock;

pub const max_steps = 8;
pub const max_pending_events = 32;
pub const max_input_bytes = 256;

pub const BindingId = enum(u64) { _ };
pub const Source = enum { builtin, user };
pub const Identity = union(enum) {
    physical: u32,
    logical: event.LogicalKey,
};
pub const Stroke = struct {
    key: Identity,
    /// Shift/control/alt/super match exactly; requested side and lock flags
    /// must also be present. Unspecified side/lock flags are ignored.
    modifiers: event.Modifiers = .{},
};
pub const Binding = struct {
    source: Source = .builtin,
    /// Empty is the application context, considered after all caller contexts.
    context: []const u8 = "",
    sequence: []const Stroke,
    /// Null disables this binding and suppresses any lower-ranked default.
    action: ?[]const u8,
    /// Presentation only. Layout changes can replace it without affecting matching.
    label: []const u8 = "",
    /// Only a single-step binding may fire from a native key repeat.
    allow_repeat: bool = false,
};
pub const Scope = struct {
    /// Nearest eligible context first; omit the implicit application context.
    contexts: []const []const u8 = &.{},
    /// Stable focus identity. Replays keep the original value after focus changes.
    focus_token: u64 = 0,
    /// Increment when eligibility or context ordering changes without a focus change.
    context_token: u64 = 0,
};
pub const Replay = struct {
    input: event.Event,
    focus_token: u64,
};
pub const Action = struct {
    name: []const u8,
    binding_id: BindingId,
    focus_token: u64,
};

/// Callbacks are synchronous and receive borrowed input/name slices. Do not
/// call back into this keymap from a callback. Keep dispatch errors in user
/// state and propagate them after the keymap call returns.
pub const Sink = struct {
    user: *anyopaque,
    on_replay: *const fn (*anyopaque, Replay) void,
    on_action: *const fn (*anyopaque, Action) void,
};
pub const Decision = enum {
    /// The current event was emitted to the deferred default-input path.
    passed,
    /// Input is held pending a longer chord; schedule nextDeadline().
    waiting,
    /// An action fired or a disabled binding suppressed the default.
    handled,
    /// Routing prevented default; this event does not reach shortcut matching.
    prevented,
    /// Bounded buffering cannot hold this event, so it was passed through intact.
    capacity_passthrough,
};
pub const Error = error{
    InvalidTimeout,
    EmptySequence,
    TooManySteps,
    InvalidKey,
    InvalidModifiers,
    InvalidAction,
    EmptyAction,
    RepeatChordUnsupported,
    BindingTooLarge,
    BindingIdsExhausted,
} || std.mem.Allocator.Error;

const Entry = struct {
    id: BindingId,
    source: Source,
    context: []const u8,
    strokes: [max_steps]Stroke,
    length: u8,
    action: ?[]const u8,
    label_owned: []u8,
    allow_repeat: bool,
    storage: []u8,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.label_owned);
        allocator.free(self.storage);
        self.* = undefined;
    }
};

const Buffered = struct {
    input: event.Event,
    focus_token: u64,
    // SAFETY: only bytes before bytes_len are read; the buffer copies them in.
    bytes: [max_input_bytes]u8 = undefined,
    bytes_len: u16 = 0,

    fn replay(self: *const Buffered) Replay {
        var copied = self.input;
        switch (copied) {
            .key_down => |*pressed| switch (pressed.logical) {
                .character => pressed.logical = .{ .character = self.bytes[0..self.bytes_len] },
                else => {},
            },
            .key_up => |*released| switch (released.logical) {
                .character => released.logical = .{ .character = self.bytes[0..self.bytes_len] },
                else => {},
            },
            .text_input => |*text| text.text = self.bytes[0..self.bytes_len],
            else => unreachable,
        }
        return .{ .input = copied, .focus_token = self.focus_token };
    }

    fn keyEvent(self: *const Buffered) event.KeyEvent {
        const value = self.replay().input;
        return value.key_down;
    }
};

const Ranked = struct {
    index: usize,
    context_rank: usize,
    source: Source,
    id: BindingId,

    fn outranks(self: Ranked, other: Ranked) bool {
        if (self.context_rank != other.context_rank) {
            return self.context_rank < other.context_rank;
        }
        if (self.source != other.source) return self.source == .user;
        return @backingInt(self.id) > @backingInt(other.id);
    }
};

pub const Keymap = struct {
    allocator: std.mem.Allocator,
    clock: Clock,
    timeout_ns: u64,
    entries: std.ArrayList(Entry) = .empty,
    next_id: u64 = 1,
    // SAFETY: only entries before pending_len are read; textInput fills them.
    pending: [max_pending_events]Buffered = undefined,
    pending_len: u8 = 0,
    // SAFETY: only entries before key_len are read; the chord matcher fills them.
    key_indices: [max_steps]u8 = undefined,
    key_len: u8 = 0,
    focus_token: u64 = 0,
    context_token: u64 = 0,
    fallback: ?BindingId = null,
    deadline_ns: ?i96 = null,
    suppress_text: bool = false,
    // SAFETY: only bytes before suppress_len are read; the suppressor fills them.
    suppress_bytes: [max_input_bytes]u8 = undefined,
    suppress_len: u16 = 0,
    last_key_has_text: bool = false,
    last_key_is_up: bool = false,

    pub fn init(allocator: std.mem.Allocator, clock: Clock, timeout_ns: u64) Error!Keymap {
        if (timeout_ns == 0) return error.InvalidTimeout;
        return .{ .allocator = allocator, .clock = clock, .timeout_ns = timeout_ns };
    }

    pub fn deinit(self: *Keymap) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Configuration changes replay a pending chord before changing its meaning.
    /// Binding/action names and labels remain owned until this map is changed or freed.
    pub fn add(self: *Keymap, binding: Binding, sink: Sink) Error!BindingId {
        if (binding.sequence.len == 0) return error.EmptySequence;
        if (binding.sequence.len > max_steps) return error.TooManySteps;
        if (binding.allow_repeat and binding.sequence.len != 1) return error.RepeatChordUnsupported;
        if (binding.action) |name| {
            if (name.len == 0) return error.EmptyAction;
            if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidAction;
        }
        if (self.next_id == std.math.maxInt(u64)) return error.BindingIdsExhausted;
        var size = try addSize(binding.context.len, if (binding.action) |name| name.len else 0);
        for (binding.sequence) |stroke| {
            if (@as(u16, @bitCast(stroke.modifiers)) & 0xfc00 != 0) {
                return error.InvalidModifiers;
            }
            switch (stroke.key) {
                .physical => |code| if (code == 0) return error.InvalidKey,
                .logical => |logical| switch (logical) {
                    .named => |named| if (named == .unidentified) return error.InvalidKey,
                    .character => |text| {
                        if (text.len == 0) return error.InvalidKey;
                        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidKey;
                        size = try addSize(size, text.len);
                    },
                    .codepoint => |codepoint| {
                        if (!std.unicode.utf8ValidCodepoint(codepoint)) return error.InvalidKey;
                    },
                    .unidentified => return error.InvalidKey,
                },
            }
        }
        const storage = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(storage);
        const label_owned = try self.allocator.dupe(u8, binding.label);
        errdefer self.allocator.free(label_owned);
        var cursor: usize = 0;
        var entry: Entry = .{
            .id = @fromBackingInt(@intCast(self.next_id)),
            .source = binding.source,
            .context = copyString(storage, &cursor, binding.context),
            // SAFETY: the loop below writes entry.strokes[0..length].
            .strokes = undefined,
            .length = @intCast(binding.sequence.len),
            .action = null,
            .label_owned = label_owned,
            .allow_repeat = binding.allow_repeat,
            .storage = storage,
        };
        if (binding.action) |name| entry.action = copyString(storage, &cursor, name);
        for (binding.sequence, 0..) |stroke, index| {
            entry.strokes[index] = stroke;
            switch (stroke.key) {
                .logical => |logical| switch (logical) {
                    .character => |text| entry.strokes[index].key = .{
                        .logical = .{ .character = copyString(storage, &cursor, text) },
                    },
                    else => {},
                },
                else => {},
            }
        }
        std.debug.assert(cursor == storage.len);
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        self.focusChanged(sink);
        self.entries.appendAssumeCapacity(entry);
        self.next_id += 1;
        return entry.id;
    }

    pub fn remove(self: *Keymap, id: BindingId, sink: Sink) bool {
        for (self.entries.items, 0..) |*entry, index| {
            if (entry.id != id) continue;
            self.focusChanged(sink);
            self.entries.items[index].deinit(self.allocator);
            _ = self.entries.orderedRemove(index);
            return true;
        }
        return false;
    }

    pub fn clearSource(self: *Keymap, source: Source, sink: Sink) void {
        self.focusChanged(sink);
        var index: usize = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            if (self.entries.items[index].source != source) continue;
            self.entries.items[index].deinit(self.allocator);
            _ = self.entries.orderedRemove(index);
        }
    }

    pub fn setLabel(self: *Keymap, id: BindingId, label_text: []const u8) !void {
        for (self.entries.items) |*entry| {
            if (entry.id != id) continue;
            const owned = try self.allocator.dupe(u8, label_text);
            self.allocator.free(entry.label_owned);
            entry.label_owned = owned;
            return;
        }
        return error.BindingNotFound;
    }

    pub fn label(self: *const Keymap, id: BindingId) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (entry.id == id) return entry.label_owned;
        }
        return null;
    }

    pub fn nextDeadline(self: *const Keymap) ?i96 {
        return self.deadline_ns;
    }

    /// Call at the W05 clock deadline even without input; not earlier.
    pub fn tick(self: *Keymap, sink: Sink) void {
        const deadline = self.deadline_ns orelse return;
        if (self.clock.now() >= deadline) self.finish(sink, true);
    }

    /// Route the original event once before calling this method. A prevented
    /// default is neither matched nor replayed. Replay is for deferred default
    /// handling only, not a second routed delivery to focused event handlers.
    pub fn keyDown(
        self: *Keymap,
        key: event.KeyEvent,
        scope: Scope,
        default_prevented: bool,
        sink: Sink,
    ) Decision {
        const now_ns = self.clock.now();
        self.expire(now_ns, sink);
        if (self.key_len != 0) {
            if (self.focus_token != scope.focus_token or
                self.context_token != scope.context_token)
            {
                self.finish(sink, false);
            }
        }
        self.suppress_text = false;
        if (default_prevented) {
            self.finish(sink, false);
            return .prevented;
        }
        if (key.logical == .character and key.logical.character.len > max_input_bytes) {
            self.finish(sink, false);
            sink.on_replay(sink.user, .{
                .input = .{ .key_down = key },
                .focus_token = scope.focus_token,
            });
            return .capacity_passthrough;
        }
        if (key.repeat and self.key_len != 0) {
            self.finish(sink, true);
            self.suppress_text = false;
        }
        if (self.key_len == max_steps or self.pending_len == max_pending_events) {
            self.finish(sink, false);
            self.suppress_text = false;
        }
        var candidates = self.select(key, scope.contexts);
        if (self.key_len != 0 and candidates.exact == null and candidates.longer == null) {
            self.finish(sink, true);
            self.suppress_text = false;
            candidates = self.select(key, scope.contexts);
        }
        if (candidates.exact) |exact| {
            if (candidates.longer) |longer| {
                if (exact.context_rank < longer.context_rank or
                    (exact.context_rank == longer.context_rank and
                        exact.source == .user and longer.source == .builtin))
                {
                    return self.activate(exact.index, key, scope.focus_token, sink);
                }
            } else {
                return self.activate(exact.index, key, scope.focus_token, sink);
            }
        }
        if (candidates.longer) |_| {
            if (!self.buffer(.{ .key_down = key }, scope.focus_token)) {
                self.finish(sink, false);
                sink.on_replay(sink.user, .{
                    .input = .{ .key_down = key },
                    .focus_token = scope.focus_token,
                });
                return .capacity_passthrough;
            }
            self.key_indices[self.key_len] = self.pending_len - 1;
            self.key_len += 1;
            self.focus_token = scope.focus_token;
            self.context_token = scope.context_token;
            self.fallback = if (candidates.exact) |exact|
                self.entries.items[exact.index].id
            else
                null;
            self.deadline_ns = std.math.add(i96, now_ns, self.timeout_ns) catch
                std.math.maxInt(i96);
            self.last_key_has_text = false;
            self.last_key_is_up = false;
            return .waiting;
        }
        sink.on_replay(sink.user, .{
            .input = .{ .key_down = key },
            .focus_token = scope.focus_token,
        });
        return .passed;
    }

    /// Preserve key-up even if the matching down was consumed by an action.
    pub fn keyUp(self: *Keymap, key: event.KeyEvent, focus_token: u64, sink: Sink) void {
        self.expire(self.clock.now(), sink);
        self.suppress_text = false;
        if (self.key_len != 0 and self.focus_token != focus_token) self.finish(sink, false);
        if (self.key_len != 0) {
            if (self.buffer(.{ .key_up = key }, focus_token)) {
                self.last_key_is_up = true;
                return;
            }
            self.finish(sink, false);
        }
        sink.on_replay(sink.user, .{
            .input = .{ .key_up = key },
            .focus_token = focus_token,
        });
    }

    /// Text is never synthesized from key downs. A commit matching the pending
    /// key is held; unrelated text flushes the chord before delivery.
    pub fn textInput(
        self: *Keymap,
        text: []const u8,
        focus_token: u64,
        default_prevented: bool,
        sink: Sink,
    ) void {
        self.expire(self.clock.now(), sink);
        if (self.key_len != 0 and self.focus_token != focus_token) self.finish(sink, false);
        if (default_prevented) {
            self.finish(sink, false);
            self.suppress_text = false;
            return;
        }
        if (self.key_len != 0) {
            const last = self.pending[self.key_indices[self.key_len - 1]].keyEvent();
            if (keyTextMatches(last, text)) |associated| {
                if (!associated) self.finish(sink, false);
            }
            if (self.key_len != 0) {
                if (self.buffer(.{ .text_input = .{ .text = text } }, focus_token)) {
                    self.last_key_has_text = true;
                    return;
                }
                self.finish(sink, false);
            }
        }
        if (self.suppress_text) {
            self.suppress_text = false;
            if (std.mem.eql(u8, self.suppress_bytes[0..self.suppress_len], text)) return;
        }
        sink.on_replay(sink.user, .{
            .input = .{ .text_input = .{ .text = text } },
            .focus_token = focus_token,
        });
    }

    /// Call before switching the focused consumer; no old-context action fires.
    pub fn focusChanged(self: *Keymap, sink: Sink) void {
        self.finish(sink, false);
        self.suppress_text = false;
    }

    const Candidates = struct { exact: ?Ranked = null, longer: ?Ranked = null };

    fn select(self: *const Keymap, key: event.KeyEvent, contexts: []const []const u8) Candidates {
        var selected: Candidates = .{};
        for (self.entries.items, 0..) |*entry, index| {
            const rank = contextRank(entry.context, contexts) orelse continue;
            if (key.repeat and !(entry.allow_repeat and entry.length == 1)) continue;
            if (@as(usize, entry.length) <= self.key_len) continue;
            var matches = true;
            for (self.key_indices[0..self.key_len], 0..) |buffer_index, step| {
                const old = self.pending[buffer_index].keyEvent();
                if (!strokeMatches(entry.strokes[step], old)) {
                    matches = false;
                    break;
                }
            }
            if (!matches) continue;
            if (!strokeMatches(entry.strokes[self.key_len], key)) continue;
            const candidate: Ranked = .{
                .index = index,
                .context_rank = rank,
                .source = entry.source,
                .id = entry.id,
            };
            const previous = if (@as(usize, entry.length) == self.key_len + 1)
                &selected.exact
            else
                &selected.longer;
            if (previous.*) |prior| {
                if (!candidate.outranks(prior)) continue;
            }
            previous.* = candidate;
        }
        return selected;
    }

    fn activate(
        self: *Keymap,
        index: usize,
        key: event.KeyEvent,
        focus_token: u64,
        sink: Sink,
    ) Decision {
        const entry = &self.entries.items[index];
        // Key-up is observable even when the shortcut consumes its key-down.
        for (self.pending[0..self.pending_len]) |*buffered| {
            if (buffered.input == .key_up) sink.on_replay(sink.user, buffered.replay());
        }
        self.pending_len = 0;
        self.key_len = 0;
        self.fallback = null;
        self.deadline_ns = null;
        self.armTextSuppression(key);
        if (entry.action) |name| {
            sink.on_action(sink.user, .{
                .name = name,
                .binding_id = entry.id,
                .focus_token = focus_token,
            });
        }
        return .handled;
    }
    fn expire(self: *Keymap, now_ns: i96, sink: Sink) void {
        const deadline = self.deadline_ns orelse return;
        if (now_ns >= deadline) self.finish(sink, true);
    }

    fn finish(self: *Keymap, sink: Sink, resolve: bool) void {
        if (self.key_len == 0) return;
        const chosen = if (resolve) self.fallback else null;
        const focus_token = self.focus_token;
        const last_key = self.pending[self.key_indices[self.key_len - 1]].keyEvent();
        const suppress_next_text = !self.last_key_has_text and !self.last_key_is_up;
        const count = self.pending_len;
        self.pending_len = 0;
        self.key_len = 0;
        self.fallback = null;
        self.deadline_ns = null;
        if (chosen) |id| {
            if (suppress_next_text) self.armTextSuppression(last_key);
            for (self.pending[0..count]) |*buffered| {
                if (buffered.input == .key_up) sink.on_replay(sink.user, buffered.replay());
            }
            for (self.entries.items) |entry| {
                if (entry.id != id) continue;
                if (entry.action) |name| {
                    sink.on_action(sink.user, .{
                        .name = name,
                        .binding_id = id,
                        .focus_token = focus_token,
                    });
                }
                return;
            }
            unreachable;
        }
        for (self.pending[0..count]) |*buffered| {
            sink.on_replay(sink.user, buffered.replay());
        }
    }

    fn armTextSuppression(self: *Keymap, key: event.KeyEvent) void {
        const expected: []const u8 = switch (key.logical) {
            .character => |text| text,
            .codepoint => |codepoint| {
                const len = std.unicode.utf8Encode(codepoint, &self.suppress_bytes) catch return;
                self.suppress_len = len;
                self.suppress_text = true;
                return;
            },
            .named => |named| namedText(named) orelse return,
            .unidentified => namedText(key.key) orelse return,
        };
        if (expected.len > self.suppress_bytes.len) return;
        @memcpy(self.suppress_bytes[0..expected.len], expected);
        self.suppress_len = @intCast(expected.len);
        self.suppress_text = true;
    }

    fn buffer(self: *Keymap, input: event.Event, focus_token: u64) bool {
        if (self.pending_len == max_pending_events) return false;
        const bytes = switch (input) {
            .key_down => |key| switch (key.logical) {
                .character => |text| text,
                else => "",
            },
            .key_up => |key| switch (key.logical) {
                .character => |text| text,
                else => "",
            },
            .text_input => |text| text.text,
            else => unreachable,
        };
        if (bytes.len > max_input_bytes) return false;
        const next = &self.pending[self.pending_len];
        next.input = input;
        next.focus_token = focus_token;
        next.bytes_len = @intCast(bytes.len);
        @memcpy(next.bytes[0..bytes.len], bytes);
        self.pending_len += 1;
        return true;
    }
};

fn addSize(a: usize, b: usize) error{BindingTooLarge}!usize {
    return std.math.add(usize, a, b) catch error.BindingTooLarge;
}

fn copyString(storage: []u8, cursor: *usize, text: []const u8) []const u8 {
    const end = cursor.* + text.len;
    const copy = storage[cursor.*..end];
    @memcpy(copy, text);
    cursor.* = end;
    return copy;
}

fn contextRank(context: []const u8, contexts: []const []const u8) ?usize {
    if (context.len == 0) return contexts.len;
    for (contexts, 0..) |candidate, index| {
        if (std.mem.eql(u8, context, candidate)) return index;
    }
    return null;
}

fn strokeMatches(stroke: Stroke, key: event.KeyEvent) bool {
    const wanted = stroke.modifiers;
    const actual = key.modifiers;
    const shifted = wanted.shift or wanted.left_shift or wanted.right_shift;
    const controlled = wanted.control or wanted.left_control or wanted.right_control;
    if (shifted != key.shifted()) return false;
    if (controlled != actual.control) return false;
    if (wanted.alt != actual.alt) return false;
    if (wanted.super != actual.super) return false;
    if (wanted.caps_lock and !actual.caps_lock) return false;
    if (wanted.num_lock and !actual.num_lock) return false;
    if (wanted.left_shift and !actual.left_shift) return false;
    if (wanted.right_shift and !actual.right_shift) return false;
    if (wanted.left_control and !actual.left_control) return false;
    if (wanted.right_control and !actual.right_control) return false;
    return switch (stroke.key) {
        .physical => |code| if (key.physical) |physical| physical.code == code else false,
        .logical => |wanted_key| logicalMatches(wanted_key, key),
    };
}

fn logicalMatches(wanted: event.LogicalKey, key: event.KeyEvent) bool {
    const actual = switch (key.logical) {
        .unidentified => if (key.key != .unidentified)
            event.LogicalKey{ .named = key.key }
        else
            key.logical,
        else => key.logical,
    };
    return switch (wanted) {
        .named => |named| switch (actual) {
            .named => |value| value == named,
            else => false,
        },
        .character => |text| switch (actual) {
            .character => |value| std.mem.eql(u8, text, value),
            .codepoint => |codepoint| codepointMatches(text, codepoint),
            else => false,
        },
        .codepoint => |codepoint| switch (actual) {
            .codepoint => |value| value == codepoint,
            .character => |text| codepointMatches(text, codepoint),
            else => false,
        },
        .unidentified => false,
    };
}

fn namedText(named: event.Key) ?[]const u8 {
    return switch (named) {
        .space => " ",
        .enter => "\n",
        .tab => "\t",
        else => null,
    };
}

fn keyTextMatches(key: event.KeyEvent, text: []const u8) ?bool {
    return switch (key.logical) {
        .character => |character| std.mem.eql(u8, character, text),
        .codepoint => |codepoint| codepointMatches(text, codepoint),
        .named => |named| if (namedText(named)) |expected|
            std.mem.eql(u8, expected, text)
        else
            null,
        .unidentified => if (namedText(key.key)) |expected|
            std.mem.eql(u8, expected, text)
        else
            null,
    };
}

fn codepointMatches(text: []const u8, codepoint: u21) bool {
    var bytes: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &bytes) catch return false;
    return std.mem.eql(u8, text, bytes[0..len]);
}
