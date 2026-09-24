//! W12 contract: one focused text endpoint, owned selection and preedit, edit
//! actions over the shared clipboard, and caret geometry that follows layout.
const std = @import("std");

const text_input = @import("text_input.zig");
const Utf16Range = text_input.Utf16Range;
const Selection = text_input.Selection;
const Session = @import("session.zig").Session;
const model_type = @import("model.zig");
const WidgetId = @import("id.zig").WidgetId;
const geometry = @import("geometry.zig");
const event = @import("event.zig");

/// A test-double cluster rule: one codepoint per cluster, except that a Latin
/// combining mark and a ZWJ-joined continuation stay attached to the codepoint
/// before them. It is deliberately small; the shipped field uses the W11 text
/// layout. It only has to be non-trivial enough to catch a protocol that hands
/// a model a range splitting one user-perceived character.
fn isAttaching(value: u21) bool {
    return switch (value) {
        0x0300...0x036f => true,
        else => false,
    };
}

fn isJoiner(value: u21) bool {
    return value == 0x200d;
}

fn decodeAt(bytes: []const u8, index: usize) u21 {
    if (index >= bytes.len) return 0;
    const size = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return 0;
    return std.unicode.utf8Decode(bytes[index..][0..size]) catch 0;
}

fn startAt(bytes: []const u8, index: usize) usize {
    var start = index;
    while (start > 0 and bytes[start] & 0xc0 == 0x80) start -= 1;
    return start;
}

fn sizeAt(bytes: []const u8, index: usize) usize {
    if (index >= bytes.len) return 1;
    return std.unicode.utf8ByteSequenceLength(bytes[index]) catch 1;
}

/// True when the codepoint at `index` continues the cluster before it: a
/// combining mark, a zero-width joiner, or what follows a joiner.
fn continuesCluster(bytes: []const u8, index: usize) bool {
    if (index == 0) return false;
    const value = decodeAt(bytes, index);
    if (isAttaching(value) or isJoiner(value)) return true;
    return isJoiner(decodeAt(bytes, startAt(bytes, index - 1)));
}

/// The first cluster boundary at or after `from`.
fn clusterForward(bytes: []const u8, from: usize) usize {
    var index: usize = 0;
    while (index < bytes.len) {
        if (index >= from and !continuesCluster(bytes, index)) return index;
        index += sizeAt(bytes, index);
    }
    return bytes.len;
}

/// The last cluster boundary at or before `from`.
fn clusterBackward(bytes: []const u8, from: usize) usize {
    var index: usize = 0;
    var last: usize = 0;
    while (index <= from and index < bytes.len) {
        if (index == 0 or !continuesCluster(bytes, index)) last = index;
        index += sizeAt(bytes, index);
    }
    return last;
}

/// The start of the cluster that ends at `at`: one step back from a caret
/// that already sits on a boundary.
fn clusterBefore(bytes: []const u8, at: usize) usize {
    if (at == 0) return 0;
    if (!continuesCluster(bytes, at)) return clusterBackward(bytes, startAt(bytes, at - 1));
    return clusterBackward(bytes, at);
}

/// Snap a caret to a cluster start. A byte that already starts a cluster is
/// kept: a caret between two characters is a valid position.
fn snapCaret(bytes: []const u8, byte: usize) usize {
    if (byte >= bytes.len) return bytes.len;
    if (!continuesCluster(bytes, byte)) return byte;
    return clusterBackward(bytes, byte);
}

/// The application-owned field. The core never sees this buffer.
const Field = struct {
    gpa: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    selection: Selection = .{},
    marked: ?Utf16Range = null,
    /// Caret metrics; a real field reads these from its shaped layout.
    advance: f32 = 8,
    line_height: f32 = 16,
    wrap_width: f32 = 1e9,
    origin: geometry.WindowRect = .{ .x = 20, .y = 30, .w = 200, .h = 32 },
    scroll: f32 = 0,
    read_only: bool = false,
    caret_reads: u32 = 0,
    replaces: u32 = 0,
    erases: u32 = 0,

    pub fn deinit(self: *Field, _: *Session) void {
        self.text.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn slice(self: *const Field) []const u8 {
        return self.text.items;
    }

    /// Snap a UTF-16 range outward to the clusters around it.
    fn byteRange(self: *const Field, range: Utf16Range) !struct { start: usize, end: usize } {
        const bytes = self.slice();
        const low = @min(range.start, range.end);
        const high = @max(range.start, range.end);
        // A range start is a caret position, so it only moves when it would
        // land inside a cluster; a range end always clears the cluster.
        return .{
            .start = snapCaret(bytes, try text_input.utf16ToUtf8(bytes, low)),
            .end = clusterForward(bytes, try text_input.utf16ToUtf8(bytes, high)),
        };
    }

    fn unitAt(self: *Field, byte: usize) !usize {
        return text_input.utf8ToUtf16(self.slice(), byte);
    }

    /// The unit the caret sits on, snapped to a cluster start.
    fn caret(self: *Field) !usize {
        const bytes = self.slice();
        const raw = try text_input.utf16ToUtf8(bytes, self.selection.cursor());
        return self.unitAt(snapCaret(bytes, raw));
    }

    fn replaceBytes(self: *Field, start: usize, end: usize, text: []const u8) !void {
        const bytes = self.slice();
        var next: std.ArrayList(u8) = .empty;
        errdefer next.deinit(self.gpa);
        try next.appendSlice(self.gpa, bytes[0..start]);
        try next.appendSlice(self.gpa, text);
        try next.appendSlice(self.gpa, bytes[end..]);
        self.text.deinit(self.gpa);
        self.text = next;
    }

    /// The protocol target: an explicit range, else the marked range, else the
    /// selection. This order is what keeps a preedit commit from duplicating.
    fn target(self: *Field, range: ?Utf16Range) !Utf16Range {
        return range orelse self.marked orelse self.selection.range;
    }
};

fn textOf(
    allocator: std.mem.Allocator,
    field: *const Field,
    _: *anyopaque,
    range: Utf16Range,
    served: *Utf16Range,
) anyerror!?[]u8 {
    const region = try field.byteRange(range);
    served.* = .{
        .start = try text_input.utf8ToUtf16(field.slice(), region.start),
        .end = try text_input.utf8ToUtf16(field.slice(), region.end),
    };
    const value = try allocator.dupe(u8, field.slice()[region.start..region.end]);
    return value;
}

fn selectionOf(field: *const Field, _: *anyopaque) anyerror!Selection {
    return field.selection;
}

fn markedOf(field: *const Field, _: *anyopaque) anyerror!?Utf16Range {
    return field.marked;
}

fn moveCaret(field: *Field, _: *anyopaque, request: text_input.Move) anyerror!Selection {
    const bytes = field.slice();
    if (request.offset) |offset| {
        field.selection = .{ .range = .{ .start = offset, .end = offset } };
        return field.selection;
    }
    const cursor = try field.caret();
    const at = (try field.byteRange(.{ .start = cursor, .end = cursor })).start;
    const target: usize = switch (request.unit) {
        .document => if (request.direction == .forward) bytes.len else 0,
        .grapheme => switch (request.direction) {
            .forward => clusterForward(bytes, at + sizeAt(bytes, at)),
            .backward => clusterBefore(bytes, at),
        },
        .word, .line => blk: {
            const forward = request.direction == .forward;
            var index = at;
            if (forward) {
                while (index < bytes.len and bytes[index] == ' ') index += 1;
            } else {
                while (index > 0 and bytes[index - 1] == ' ') index -= 1;
            }
            break :blk index;
        },
    };
    const next = try field.unitAt(target);
    if (request.extend) {
        const anchor = field.selection.anchor();
        field.selection = .{
            .range = .{ .start = @min(anchor, next), .end = @max(anchor, next) },
            .reversed = next < anchor,
        };
    } else {
        field.selection = .{ .range = .{ .start = next, .end = next } };
    }
    return field.selection;
}

fn eraseText(field: *Field, _: *anyopaque, request: text_input.Erase) anyerror!void {
    if (field.read_only) return;
    const bytes = field.slice();
    const cursor = try field.caret();
    const at = (try field.byteRange(.{ .start = cursor, .end = cursor })).start;
    const range = if (request.extend)
        field.selection.range
    else if (!field.selection.range.isEmpty())
        field.selection.range
    else if (request.backward)
        Utf16Range{
            .start = try field.unitAt(clusterBefore(bytes, at)),
            .end = cursor,
        }
    else
        Utf16Range{
            .start = cursor,
            .end = try field.unitAt(clusterForward(bytes, at)),
        };
    const region = try field.byteRange(range);
    const keep = field.selection;
    try field.replaceBytes(region.start, region.end, "");
    field.marked = null;
    const caret = try field.unitAt(region.start);
    field.selection = if (request.extend)
        keep
    else
        .{ .range = .{ .start = caret, .end = caret } };
    field.erases += 1;
}

fn replaceText(
    field: *Field,
    _: *anyopaque,
    range: ?Utf16Range,
    text: []const u8,
) anyerror!void {
    if (field.read_only) return;
    const region = try field.byteRange(try field.target(range));
    try field.replaceBytes(region.start, region.end, text);
    const caret = try field.unitAt(region.start + text.len);
    field.marked = null;
    field.selection = .{ .range = .{ .start = caret, .end = caret } };
    field.replaces += 1;
}

fn replaceAndMark(
    field: *Field,
    _: *anyopaque,
    range: ?Utf16Range,
    text: []const u8,
    inside: ?Utf16Range,
) anyerror!void {
    if (field.read_only) return;
    const region = try field.byteRange(try field.target(range));
    try field.replaceBytes(region.start, region.end, text);
    const base = try field.unitAt(region.start);
    const length = try text_input.utf16Length(text);
    field.marked = if (text.len == 0) null else Utf16Range{ .start = base, .end = base + length };
    const caret = if (inside) |value| base + @min(value.end, length) else base + length;
    field.selection = .{ .range = .{ .start = caret, .end = caret } };
    field.replaces += 1;
}

fn unmarkText(field: *Field, _: *anyopaque) anyerror!void {
    field.marked = null;
}

/// One unit per advance, wrapping at `wrap_width`, shifted by the element
/// origin and the current scroll. Enough to prove the candidate rectangle
/// tracks layout, scroll and scale instead of a stale frame.
fn caretOf(field: *Field, _: *anyopaque, range: Utf16Range) anyerror!?text_input.Caret {
    field.caret_reads += 1;
    if (field.wrap_width <= 0) return null;
    const per_line: usize = @max(
        @as(usize, 1),
        @as(usize, @intFromFloat(field.wrap_width / field.advance)),
    );
    const units = range.end;
    const line = units / per_line;
    const column = units % per_line;
    const x = field.origin.x + field.advance * @as(f32, @floatFromInt(column));
    const y = field.origin.y - field.scroll + field.line_height * @as(f32, @floatFromInt(line));
    return .{ .area = .{ .x = x, .y = y, .w = 0, .h = field.line_height }, .cursor = 0 };
}

fn indexAt(field: *const Field, _: *anyopaque, point: geometry.WindowPoint) anyerror!?usize {
    if (point.y < field.origin.y - field.scroll) return 0;
    const column: f32 = @floor((point.x - field.origin.x) / field.advance + 0.5);
    if (column <= 0) return 0;
    return @min(@as(usize, @intFromFloat(column)), try text_input.utf16Length(field.slice()));
}

const Handlers = text_input.Adapter(Field).Handlers;

fn fieldHandlers() Handlers {
    return .{
        .text = textOf,
        .selection = selectionOf,
        .marked = markedOf,
        .move = moveCaret,
        .erase = eraseText,
        .replace = replaceText,
        .replace_and_mark = replaceAndMark,
        .unmark = unmarkText,
        .caret = caretOf,
        .index_at = indexAt,
    };
}

const Clipboard = struct {
    stored: std.ArrayList(u8) = .empty,
    /// What the next read reports; `.text` bytes are copied per read.
    payload: text_input.ClipboardRead = .empty,
    write_failure: bool = false,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Clipboard) void {
        self.stored.deinit(self.gpa);
        self.* = undefined;
    }

    /// Set a text payload; the bytes are copied on every read, so the caller
    /// keeps ownership of the source.
    fn setText(self: *Clipboard, value: []const u8) void {
        self.payload = .{ .text = @constCast(value) };
    }

    fn port(self: *Clipboard) text_input.Clipboard {
        return .{ .user = self, .read = readPort, .write = write };
    }

    fn readPort(allocator: std.mem.Allocator, user: *anyopaque) text_input.ClipboardRead {
        const self: *Clipboard = @ptrCast(@alignCast(user));
        return switch (self.payload) {
            .text => |bytes| .{ .text = allocator.dupe(u8, bytes) catch return .failed },
            else => self.payload,
        };
    }

    fn write(user: *anyopaque, bytes: []const u8) text_input.ClipboardWrite {
        const self: *Clipboard = @ptrCast(@alignCast(user));
        if (self.write_failure) return .failed;
        self.stored.clearRetainingCapacity();
        self.stored.appendSlice(self.gpa, bytes) catch return .failed;
        return .written;
    }
};

const NativeCalls = struct {
    starts: u32 = 0,
    stops: u32 = 0,
    clears: u32 = 0,
    areas: u32 = 0,
    last: ?text_input.Caret = null,
    fail_start: bool = false,
    fail_area: bool = false,
    unsupported: bool = false,

    fn port(self: *NativeCalls) text_input.Native {
        return .{
            .user = self,
            .start = start,
            .stop = stop,
            .set_area = setArea,
            .clear_composition = clearComposition,
        };
    }

    fn start(user: *anyopaque) anyerror!void {
        const self: *NativeCalls = @ptrCast(@alignCast(user));
        if (self.unsupported) return error.UnsupportedCapability;
        if (self.fail_start) return error.NativeTextInputFailed;
        self.starts += 1;
    }

    fn stop(user: *anyopaque) anyerror!void {
        const self: *NativeCalls = @ptrCast(@alignCast(user));
        self.stops += 1;
    }

    fn setArea(user: *anyopaque, area: geometry.WindowRect, cursor: f32) anyerror!void {
        const self: *NativeCalls = @ptrCast(@alignCast(user));
        if (self.fail_area) return error.NativeCandidateRefused;
        self.areas += 1;
        self.last = .{ .area = area, .cursor = cursor };
    }

    fn clearComposition(user: *anyopaque) void {
        const self: *NativeCalls = @ptrCast(@alignCast(user));
        self.clears += 1;
    }
};

const field_id: WidgetId = .{ .owner = 9, .slot = 1, .generation = 1 };
const other_id: WidgetId = .{ .owner = 9, .slot = 2, .generation = 1 };

/// A session, one field model, one endpoint and the two ports, so each test
/// exercises the same wiring a real App uses.
const Harness = struct {
    gpa: std.mem.Allocator,
    session: Session,
    manager: text_input.Manager,
    owner: model_type.Model(Field),
    clipboard: Clipboard,
    native: NativeCalls,
    policy: text_input.Policy = .{},

    /// Init in place: the manager holds a pointer to this session, so the
    /// harness must not be returned by value.
    fn init(self: *Harness, gpa: std.mem.Allocator, policy: text_input.Policy) !void {
        var session = try Session.init(gpa);
        errdefer session.deinit() catch |err|
            std.debug.panic("fresh session deinit: {s}", .{@errorName(err)});
        var initial: Field = .{ .gpa = gpa, .read_only = policy.read_only };
        const owner = try session.create(Field, &initial);
        self.* = .{
            .gpa = gpa,
            .session = session,
            // SAFETY: text_input.Manager.init assigns it right after this literal.
            .manager = undefined,
            .owner = owner,
            .clipboard = .{ .gpa = gpa },
            .native = .{},
            .policy = policy,
        };
        self.manager = text_input.Manager.init(gpa, &self.session);
        self.manager.clipboard = self.clipboard.port();
        self.manager.native = self.native.port();
    }

    fn deinit(self: *Harness) void {
        self.manager.clear();
        // A test may release the model itself to prove the endpoint notices,
        // so a repeated release is expected here.
        self.session.release(Field, &self.owner) catch |err| switch (err) {
            error.AlreadyReleased, error.StaleModel => {},
            else => {},
        };
        self.clipboard.deinit();
        self.session.deinit() catch |err|
            std.debug.panic("harness session deinit: {s}", .{@errorName(err)});
        self.* = undefined;
    }

    fn setText(self: *Harness, value: []const u8) !void {
        try self.session.update(Field, self.owner, &value, struct {
            fn run(field: *Field, payload: *const []const u8) anyerror!void {
                field.text.clearRetainingCapacity();
                try field.text.appendSlice(field.gpa, payload.*);
            }
        }.run);
    }

    fn select(self: *Harness, range: Utf16Range) !void {
        try self.session.update(Field, self.owner, &range, struct {
            fn run(field: *Field, requested: *const Utf16Range) anyerror!void {
                field.selection = .{
                    .range = requested.ordered(),
                    .reversed = requested.start > requested.end,
                };
            }
        }.run);
    }

    fn placeCaret(self: *Harness, unit: usize) !void {
        try self.select(.{ .start = unit, .end = unit });
    }

    fn text(self: *Harness, buffer: []u8) ![]const u8 {
        const borrowed = self.readBorrowed();
        if (borrowed.len > buffer.len) return error.BufferTooSmall;
        @memcpy(buffer[0..borrowed.len], borrowed);
        return buffer[0..borrowed.len];
    }

    /// Borrowed for the rest of the test: the field owns the bytes and the
    /// next Session borrow does not free them.
    fn readBorrowed(self: *Harness) []const u8 {
        var borrowed: []const u8 = "";
        self.session.read(Field, self.owner, &borrowed, struct {
            fn run(field: *const Field, out: *[]const u8) anyerror!void {
                out.* = field.slice();
            }
        }.run) catch |err| std.debug.panic("field read: {s}", .{@errorName(err)});
        return borrowed;
    }

    fn snapshot(self: *Harness) Snapshot {
        var state: Snapshot = .{};
        self.session.read(Field, self.owner, &state, struct {
            fn run(field: *const Field, out: *Snapshot) anyerror!void {
                out.text = field.slice();
                out.selection = field.selection;
                out.marked = field.marked;
                out.caret_reads = field.caret_reads;
                out.replaces = field.replaces;
                out.erases = field.erases;
            }
        }.run) catch |err| std.debug.panic("field snapshot: {s}", .{@errorName(err)});
        return state;
    }

    fn focus(self: *Harness) void {
        self.manager.register(.{
            .id = field_id,
            .owner = self.owner.weak().erase(),
            .policy = self.policy,
            .ops = text_input.Adapter(Field).ops(fieldHandlers()),
            .user = self,
        });
    }
};

/// Borrowed view of the field valid until the next Session call in the test.
const Snapshot = struct {
    text: []const u8 = "",
    selection: Selection = .{},
    marked: ?Utf16Range = null,
    caret_reads: u32 = 0,
    replaces: u32 = 0,
    erases: u32 = 0,
};

fn expectText(harness: *Harness, expected: []const u8) !void {
    var buffer: [128]u8 = undefined;
    const actual = try harness.text(&buffer);
    try std.testing.expectEqualStrings(expected, actual);
}

test "api-w12 a physical key inserts nothing and its commit inserts once" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    try harness.setText("ab");
    try harness.placeCaret(2);
    harness.focus();
    try std.testing.expect(harness.manager.focusedId().?.eql(field_id));
    try std.testing.expectEqual(@as(u32, 1), harness.native.starts);

    // A printable key press is a stroke for the IME, not an insertion.
    const stroke: event.Event = .{ .key_down = .{
        .key = .unidentified,
        .logical = .{ .codepoint = 'x' },
        .physical = .{ .code = 45 },
    } };
    try std.testing.expectEqual(text_input.Outcome.ignored, try harness.manager.handle(&stroke));
    try expectText(&harness, "ab");

    try std.testing.expectEqual(
        text_input.Outcome.handled,
        try harness.manager.handle(&.{ .text_input = .{ .text = "x" } }),
    );
    try expectText(&harness, "abx");
    // A key repeat plus its commit still inserts exactly one character.
    try std.testing.expectEqual(
        text_input.Outcome.handled,
        try harness.manager.handle(&.{ .text_input = .{ .text = "x" } }),
    );
    try expectText(&harness, "abxx");
    try std.testing.expectEqual(field_id, harness.manager.focusedId().?);

    // Backspace erases one cluster, not one byte.
    const backspace: event.Event = .{ .key_down = .{
        .key = .unidentified,
        .logical = .{ .codepoint = 0x08 },
    } };
    try std.testing.expectEqual(text_input.Outcome.handled, try harness.manager.handle(&backspace));
    try expectText(&harness, "abx");
}

test "api-w12 paste replaces a multibyte selection exactly once" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    try harness.setText("\xce\xb1\xce\xb2\xce\xb3"); // αβγ
    try harness.select(.{ .start = 1, .end = 2 }); // β
    harness.focus();
    harness.clipboard.setText("Z");

    const outcome = try harness.manager.paste();
    try std.testing.expectEqual(@as(usize, 1), outcome.pasted);
    try expectText(&harness, "\xce\xb1Z\xce\xb3");
    const state = harness.snapshot();
    try std.testing.expectEqual(@as(?Utf16Range, null), state.marked);
    try std.testing.expectEqual(@as(usize, 2), state.selection.range.start);
    try std.testing.expectEqual(@as(usize, 1), state.replaces);

    // Cutting copies the selected bytes and removes them once.
    try harness.setText("\xce\xb1\xce\xb2\xce\xb3");
    try harness.select(.{ .start = 1, .end = 2 });
    const cut = try harness.manager.cut();
    try std.testing.expectEqual(@as(usize, 2), cut.cut);
    try expectText(&harness, "\xce\xb1\xce\xb3");
    try std.testing.expectEqualStrings("\xce\xb2", harness.clipboard.stored.items);
}

test "api-w12 a preedit commit replaces its own marked text" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    try harness.setText("ab");
    try harness.placeCaret(2);
    harness.focus();

    // The IME replaces the caret with a preedit and marks it.
    try std.testing.expectEqual(
        text_input.Outcome.handled,
        try harness.manager.handle(&.{
            .composition = .{
                .phase = .update,
                .text = "\xe3\x81\x82", // だ
            },
        }),
    );
    try expectText(&harness, "ab\xe3\x81\x82");
    var state = harness.snapshot();
    try std.testing.expectEqual(Utf16Range{ .start = 2, .end = 3 }, state.marked.?);

    // A second update replaces the preedit instead of growing it.
    _ = try harness.manager.handle(&.{
        .composition = .{
            .phase = .update,
            .text = "\xe3\x81\x82\xe3\x81\x84", // だい
        },
    });
    try expectText(&harness, "ab\xe3\x81\x82\xe3\x81\x84");
    state = harness.snapshot();
    try std.testing.expectEqual(Utf16Range{ .start = 2, .end = 4 }, state.marked.?);

    // The session ends, then the commit arrives: it replaces the marked
    // range, so the preedit is not inserted a second time.
    _ = try harness.manager.handle(&.{ .composition = .{ .phase = .end } });
    _ = try harness.manager.handle(&.{ .text_input = .{ .text = "\xe3\x81\x82" } });
    try expectText(&harness, "ab\xe3\x81\x82");
    state = harness.snapshot();
    try std.testing.expectEqual(@as(?Utf16Range, null), state.marked);
    try std.testing.expectEqual(@as(usize, 3), state.selection.range.start);
}

test "api-w12 a partial preedit selection counts UTF-16 units, not bytes" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    try harness.setText("ab");
    try harness.select(.{ .start = 1, .end = 2 }); // replace b
    harness.focus();

    // "あい" is 6 bytes and 2 UTF-16 code units. The event counts BYTES of
    // the preedit, so bytes 0..3 are the first character alone and the caret
    // belongs one unit into the marked range. Reading those bytes as units
    // would clamp to the end of the preedit and report no selection at all.
    _ = try harness.manager.handle(&.{
        .composition = .{
            .phase = .update,
            .text = "\xe3\x81\x82\xe3\x81\x84",
            .selection_start = 0,
            .selection_end = 3,
        },
    });
    try expectText(&harness, "a\xe3\x81\x82\xe3\x81\x84");
    var state = harness.snapshot();
    try std.testing.expectEqual(Utf16Range{ .start = 1, .end = 3 }, state.marked.?);
    // One unit past the base: inside the marked text, not after it.
    try std.testing.expectEqual(@as(usize, 2), state.selection.range.start);

    // A collapsed preedit selection is no selection, so the caret sits at the
    // end of the preedit whichever character the byte offset names.
    _ = try harness.manager.handle(&.{
        .composition = .{
            .phase = .update,
            .text = "\xe3\x81\x82\xe3\x81\x84",
            .selection_start = 3,
            .selection_end = 3,
        },
    });
    state = harness.snapshot();
    try std.testing.expectEqual(@as(usize, 3), state.selection.range.start);

    // The whole preedit selected is the case the old reading also got right,
    // and it must stay right: the caret is the end of the marked range.
    _ = try harness.manager.handle(&.{
        .composition = .{
            .phase = .update,
            .text = "\xe3\x81\x82\xe3\x81\x84",
            .selection_start = 0,
            .selection_end = 6,
        },
    });
    state = harness.snapshot();
    try std.testing.expectEqual(Utf16Range{ .start = 1, .end = 3 }, state.marked.?);
    try std.testing.expectEqual(@as(usize, 3), state.selection.range.start);
}

test "api-w12 a preedit selection over a surrogate pair counts two units" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    try harness.setText("ab");
    try harness.select(.{ .start = 1, .end = 2 });
    harness.focus();

    // "👩👧" is 8 bytes and 4 UTF-16 code units: each character is a
    // surrogate pair. The first character is bytes 0..4 and units 0..2, so
    // selecting it puts the caret two units in. Reading the bytes as units
    // would clamp 4 to the preedit's own length and lose the selection.
    _ = try harness.manager.handle(&.{
        .composition = .{
            .phase = .update,
            .text = "\xf0\x9f\x91\xa9\xf0\x9f\x91\xa7",
            .selection_start = 0,
            .selection_end = 4,
        },
    });
    try expectText(&harness, "a\xf0\x9f\x91\xa9\xf0\x9f\x91\xa7");
    var state = harness.snapshot();
    try std.testing.expectEqual(Utf16Range{ .start = 1, .end = 5 }, state.marked.?);
    try std.testing.expectEqual(@as(usize, 3), state.selection.range.start);

    // The second character selected is the other half of the same range.
    _ = try harness.manager.handle(&.{
        .composition = .{
            .phase = .update,
            .text = "\xf0\x9f\x91\xa9\xf0\x9f\x91\xa7",
            .selection_start = 4,
            .selection_end = 8,
        },
    });
    state = harness.snapshot();
    try std.testing.expectEqual(@as(usize, 5), state.selection.range.start);

    // A byte offset inside a character is still refused: it has no unit. The
    // field is then exactly what the last accepted preedit left it - the same
    // mark, the caret after the second character, the same text - and the
    // refused update never reached the model at all.
    const writes_before = state.replaces;
    try std.testing.expectEqual(
        text_input.Outcome.rejected,
        try harness.manager.handle(&.{ .composition = .{
            .phase = .update,
            .text = "\xf0\x9f\x91\xa9\xf0\x9f\x91\xa7",
            .selection_start = 0,
            .selection_end = 2,
        } }),
    );
    state = harness.snapshot();
    try std.testing.expectEqual(Utf16Range{ .start = 1, .end = 5 }, state.marked.?);
    try std.testing.expectEqual(@as(usize, 5), state.selection.range.start);
    try std.testing.expectEqual(writes_before, state.replaces);
    try expectText(&harness, "a\xf0\x9f\x91\xa9\xf0\x9f\x91\xa7");
}

test "api-w12 focus loss cancels the preedit and stops native input" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    try harness.setText("ab");
    try harness.placeCaret(2);
    harness.focus();
    _ = try harness.manager.handle(&.{ .composition = .{
        .phase = .update,
        .text = "\xe3\x81\x82",
    } });
    try expectText(&harness, "ab\xe3\x81\x82");

    harness.manager.reconcile(other_id);
    try expectText(&harness, "ab");
    try std.testing.expectEqual(@as(?WidgetId, null), harness.manager.focusedId());
    try std.testing.expectEqual(@as(u32, 1), harness.native.stops);
    try std.testing.expectEqual(@as(u32, 1), harness.native.clears);
    try std.testing.expectEqual(text_input.NativeStatus.stopped, harness.manager.native_status);

    // A commit that arrives after focus loss edits nothing.
    try std.testing.expectEqual(
        text_input.Outcome.ignored,
        try harness.manager.handle(&.{ .text_input = .{ .text = "x" } }),
    );
    try expectText(&harness, "ab");
}

test "api-w12 a cancelled preedit leaves no partial text" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    try harness.setText("hello");
    try harness.select(.{ .start = 1, .end = 4 }); // ell
    harness.focus();
    _ = try harness.manager.handle(&.{ .composition = .{
        .phase = .update,
        .text = "\xce\xb2",
    } });
    try expectText(&harness, "h\xce\xb2o");
    try harness.manager.cancelComposition();
    try expectText(&harness, "hello");
    const state = harness.snapshot();
    try std.testing.expectEqual(@as(?Utf16Range, null), state.marked);
    try std.testing.expectEqual(@as(usize, 1), state.selection.range.start);
}

test "api-w12 a cancelled composition at a collapsed multibyte caret restores the caret" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    // The caret sits between two multibyte characters, so a restore that
    // landed on a byte offset, or on the start of the document, is visible in
    // the text rather than only in a number.
    try harness.setText("a\xe3\x81\x82\xe3\x81\x84b");
    try harness.placeCaret(2);
    harness.focus();

    _ = try harness.manager.handle(&.{ .composition = .{
        .phase = .update,
        .text = "\xce\xb2",
    } });
    // A collapsed caret has nothing to replace, so the preedit is inserted
    // after the first multibyte character rather than over it.
    try expectText(&harness, "a\xe3\x81\x82\xce\xb2\xe3\x81\x84b");

    try harness.manager.cancelComposition();
    try expectText(&harness, "a\xe3\x81\x82\xe3\x81\x84b");
    var state = harness.snapshot();
    try std.testing.expectEqual(@as(?Utf16Range, null), state.marked);
    // The caret is the UTF-16 unit the composition began at, not the start of
    // the document and not a byte offset inside the multibyte characters.
    try std.testing.expectEqual(Utf16Range{ .start = 2, .end = 2 }, state.selection.range);
    try std.testing.expect(!state.selection.reversed);

    // The commit after the cancel goes to that caret, once. One replacement
    // covers the commit; a second would insert the character twice.
    const before_commit = state.replaces;
    try std.testing.expectEqual(
        text_input.Outcome.handled,
        try harness.manager.handle(&.{ .text_input = .{ .text = "!" } }),
    );
    try expectText(&harness, "a\xe3\x81\x82!\xe3\x81\x84b");
    state = harness.snapshot();
    try std.testing.expectEqual(before_commit + 1, state.replaces);
    try std.testing.expectEqual(Utf16Range{ .start = 3, .end = 3 }, state.selection.range);
}

test "api-w12 movement and erase snap to grapheme clusters" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    // "áb": the combining acute is a second codepoint of one character.
    try harness.setText("a\xcc\x81b");
    try harness.placeCaret(0);
    harness.focus();

    // "a" and the combining acute are one character: the first step leaves
    // both of them behind and lands on unit 2, in front of "b".
    _ = try harness.manager.handle(&.{ .key_down = .{ .key = .right } });
    var state = harness.snapshot();
    try std.testing.expectEqual(@as(usize, 2), state.selection.range.start);
    _ = try harness.manager.handle(&.{ .key_down = .{ .key = .right } });
    state = harness.snapshot();
    try std.testing.expectEqual(@as(usize, 3), state.selection.range.start);
    // At the end of the text the caret stays put.
    _ = try harness.manager.handle(&.{ .key_down = .{ .key = .right } });
    state = harness.snapshot();
    try std.testing.expectEqual(@as(usize, 3), state.selection.range.start);

    // Shift extends from the anchor, and the direction is kept.
    _ = try harness.manager.handle(&.{ .key_down = .{ .key = .left, .modifiers = .{ .shift = true } } });
    state = harness.snapshot();
    try std.testing.expectEqual(Utf16Range{ .start = 2, .end = 3 }, state.selection.range);
    try std.testing.expect(state.selection.reversed);
    try std.testing.expectEqual(@as(usize, 2), state.selection.cursor());
    try std.testing.expectEqual(@as(usize, 3), state.selection.anchor());

    // Backspace before the combining mark removes the whole cluster.
    try harness.placeCaret(2);
    _ = try harness.manager.handle(&.{ .key_down = .{
        .key = .unidentified,
        .logical = .{ .codepoint = 0x08 },
    } });
    try expectText(&harness, "b");
    state = harness.snapshot();
    try std.testing.expectEqual(@as(usize, 1), state.erases);
}

test "api-w12 a read-only field copies and refuses every mutation" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{ .read_only = true });
    defer harness.deinit();
    try harness.setText("fixed");
    try harness.select(.{ .start = 0, .end = 2 });
    harness.focus();
    harness.clipboard.setText("x");

    const copied = try harness.manager.copy();
    try std.testing.expectEqual(@as(usize, 2), copied.copied);
    try std.testing.expectEqualStrings("fi", harness.clipboard.stored.items);
    try std.testing.expectEqual(text_input.EditOutcome.read_only, try harness.manager.cut());
    try std.testing.expectEqual(text_input.EditOutcome.read_only, try harness.manager.paste());
    harness.manager.clipboard = null;
    try std.testing.expectEqual(text_input.EditOutcome.read_only, try harness.manager.cut());
    try std.testing.expectEqual(text_input.EditOutcome.read_only, try harness.manager.paste());
    harness.manager.clipboard = .{ .user = &harness };
    try std.testing.expectEqual(text_input.EditOutcome.read_only, try harness.manager.cut());
    try std.testing.expectEqual(text_input.EditOutcome.read_only, try harness.manager.paste());
    harness.manager.clipboard = harness.clipboard.port();
    try std.testing.expectEqual(
        text_input.Outcome.rejected,
        try harness.manager.handle(&.{ .text_input = .{ .text = "x" } }),
    );
    try std.testing.expectEqual(
        text_input.Outcome.rejected,
        try harness.manager.handle(&.{ .key_down = .{
            .key = .unidentified,
            .logical = .{ .codepoint = 0x08 },
        } }),
    );
    try std.testing.expectEqual(
        text_input.Outcome.rejected,
        try harness.manager.handle(&.{ .composition = .{ .phase = .update, .text = "x" } }),
    );
    try expectText(&harness, "fixed");
    try std.testing.expectEqualStrings("fi", harness.clipboard.stored.items);
}

test "api-w12 clipboard unavailable empty and failed stay distinct" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    try harness.setText("ab");
    try harness.placeCaret(2);
    harness.focus();

    harness.manager.clipboard = .{ .user = &harness };
    try std.testing.expectEqual(
        text_input.EditOutcome.unavailable,
        try harness.manager.paste(),
    );
    harness.manager.clipboard = harness.clipboard.port();

    harness.clipboard.payload = .empty;
    try std.testing.expectEqual(text_input.EditOutcome.empty, try harness.manager.paste());
    harness.clipboard.payload = .failed;
    try std.testing.expectEqual(text_input.EditOutcome.failed, try harness.manager.paste());
    try expectText(&harness, "ab");

    // A write failure is reported, not silently swallowed.
    harness.clipboard.write_failure = true;
    try harness.select(.{ .start = 0, .end = 2 });
    try std.testing.expectEqual(text_input.EditOutcome.failed, try harness.manager.copy());
    try expectText(&harness, "ab");
}

test "api-w12 empty or control-only clipboard payloads preserve the selection" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    try harness.setText("ab");
    try harness.select(.{ .start = 0, .end = 2 });
    harness.focus();
    for ([_][]const u8{ "", "\x01", "\x01\x02\x03\x7f" }) |payload| {
        harness.clipboard.setText(payload);
        const outcome = try harness.manager.paste();
        try expectText(&harness, "ab");
        try std.testing.expectEqual(text_input.EditOutcome.empty, outcome);
    }
    try harness.placeCaret(1);
    try std.testing.expectEqual(text_input.EditOutcome.no_selection, try harness.manager.copy());
    try std.testing.expectEqual(text_input.EditOutcome.no_selection, try harness.manager.cut());
    try expectText(&harness, "ab");
}

test "api-w12 a single-line field folds newlines and keeps Enter" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    try harness.setText("");
    harness.focus();
    harness.clipboard.setText("a\nb\r\nc");

    const pasted = try harness.manager.paste();
    try std.testing.expectEqual(@as(usize, 5), pasted.pasted);
    try expectText(&harness, "a b c");
    // Enter is consumed without editing a single-line field.
    try std.testing.expectEqual(
        text_input.Outcome.handled,
        try harness.manager.handle(&.{ .key_down = .{ .key = .enter } }),
    );
    try expectText(&harness, "a b c");
    // A NUL and a control byte never enter a field.
    _ = try harness.manager.handle(&.{ .text_input = .{ .text = "d\x00\x07e" } });
    try expectText(&harness, "a b cde");

    var multiline: Harness = undefined;
    try multiline.init(std.testing.allocator, .{ .multiline = true });
    defer multiline.deinit();
    try multiline.setText("");
    multiline.focus();
    try std.testing.expectEqual(
        text_input.Outcome.handled,
        try multiline.manager.handle(&.{ .key_down = .{ .key = .enter } }),
    );
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\n", try multiline.text(&buffer));
}

test "api-w12 adjacent independent line breaks are not CRLF" {
    for ([_]bool{ false, true }) |multiline| {
        var harness: Harness = undefined;
        try harness.init(std.testing.allocator, .{ .multiline = multiline });
        defer harness.deinit();
        harness.focus();
        for ([_][]const u8{ "a\r\x0bb", "a\r\x0cb", "a\n\rb", "a\r\rb" }) |raw| {
            try harness.setText("");
            try harness.placeCaret(0);
            harness.clipboard.setText(raw);
            const pasted = try harness.manager.paste();
            try std.testing.expectEqual(@as(usize, 4), pasted.pasted);
            try expectText(&harness, if (multiline) "a\n\nb" else "a  b");
        }
    }
}

test "api-w12 invalid committed text and out-of-range preedit are refused" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    try harness.setText("ab");
    try harness.placeCaret(2);
    harness.focus();

    try std.testing.expectEqual(
        text_input.Outcome.rejected,
        try harness.manager.handle(&.{ .text_input = .{ .text = "a\xffb" } }),
    );
    try std.testing.expectEqual(
        text_input.Outcome.rejected,
        try harness.manager.handle(&.{ .text_input = .{ .text = "" } }),
    );
    // A preedit selection that is not a codepoint boundary of the preedit
    // cannot be applied to the document.
    try std.testing.expectEqual(
        text_input.Outcome.rejected,
        try harness.manager.handle(&.{ .composition = .{
            .phase = .update,
            .text = "\xe3\x81\x82",
            .selection_start = 1,
            .selection_end = 3,
        } }),
    );
    try std.testing.expectEqual(
        text_input.Outcome.rejected,
        try harness.manager.handle(&.{ .composition = .{
            .phase = .update,
            .text = "\xe3\x81\x82",
            .selection_start = 0,
            .selection_end = 9,
        } }),
    );
    try expectText(&harness, "ab");
}

test "api-w12 candidate geometry is cached per generation and follows layout" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    try harness.setText("wrap this text over two lines");
    try harness.placeCaret(14);
    harness.focus();

    const first = (try harness.manager.caretGeometry()).?;
    var state = harness.snapshot();
    try std.testing.expectEqual(@as(u32, 1), state.caret_reads);
    // A second read in the same generation does not re-measure.
    const again = (try harness.manager.caretGeometry()).?;
    try std.testing.expectEqual(first.area.x, again.area.x);
    state = harness.snapshot();
    try std.testing.expectEqual(@as(u32, 1), state.caret_reads);
    try std.testing.expectEqual(@as(u32, 1), harness.native.areas);
    try std.testing.expectEqual(first.area.x, harness.native.last.?.area.x);

    // A wrapped caret sits on the second line.
    try std.testing.expect(first.area.y > 0);
    harness.session.update(Field, harness.owner, &harness.session, struct {
        fn run(field: *Field, _: *Session) anyerror!void {
            field.wrap_width = 60;
        }
    }.run) catch unreachable;
    harness.manager.invalidateGeometry();
    const wrapped = (try harness.manager.caretGeometry()).?;
    state = harness.snapshot();
    try std.testing.expectEqual(@as(u32, 2), state.caret_reads);
    try std.testing.expect(wrapped.area.y > first.area.y);

    // Scrolling moves the rectangle without a new measurement request.
    harness.session.update(Field, harness.owner, &harness.session, struct {
        fn run(field: *Field, _: *Session) anyerror!void {
            field.scroll = 16;
        }
    }.run) catch unreachable;
    harness.manager.invalidateGeometry();
    const scrolled = (try harness.manager.caretGeometry()).?;
    try std.testing.expectEqual(wrapped.area.y - 16, scrolled.area.y);

    // Every edit invalidates the rectangle, so a moved caret is re-measured.
    _ = try harness.manager.handle(&.{ .text_input = .{ .text = "!" } });
    const moved = (try harness.manager.caretGeometry()).?;
    try std.testing.expect(moved.area.x > scrolled.area.x);
    try std.testing.expectEqual(@as(u32, 4), harness.snapshot().caret_reads);
    try std.testing.expectEqual(moved.area.x, harness.native.last.?.area.x);

    // A key movement must republish the caret before another frame commits.
    _ = try harness.manager.handle(&.{ .key_down = .{ .key = .left } });
    const walked = (try harness.manager.caretGeometry()).?;
    try std.testing.expectEqual(scrolled.area.x, walked.area.x);
    try std.testing.expectEqual(walked.area.x, harness.native.last.?.area.x);
    try std.testing.expectEqual(walked.area.y, harness.native.last.?.area.y);
}

test "api-w12 a refused candidate is observable and never cached as published" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    try harness.setText("abcd");
    try harness.placeCaret(1);
    harness.focus();
    _ = try harness.manager.caretGeometry();
    const accepted = harness.native.last.?;

    try harness.placeCaret(3);
    harness.manager.invalidateGeometry();
    harness.native.fail_area = true;
    try std.testing.expectError(error.NativeCandidateRefused, harness.manager.caretGeometry());
    try std.testing.expectEqualDeep(accepted, harness.native.last.?);

    harness.native.fail_area = false;
    const published = (try harness.manager.caretGeometry()).?;
    try std.testing.expect(published.area.x > accepted.area.x);
    try std.testing.expectEqualDeep(published, harness.native.last.?);
    try std.testing.expectEqual(@as(u32, 3), harness.snapshot().caret_reads);
}

test "api-w12 composing geometry follows the marked range" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    try harness.setText("abcd");
    try harness.placeCaret(1);
    harness.focus();

    const idle = (try harness.manager.caretGeometry()).?;
    try std.testing.expectEqual(@as(f32, 28), idle.area.x);
    _ = try harness.manager.handle(&.{ .composition = .{
        .phase = .update,
        .text = "\xe3\x81\x82\xe3\x81\x84\xe3\x81\x86",
    } });
    const composing = (try harness.manager.caretGeometry()).?;
    // Caret 1 + three preedit codepoints, not the old caret.
    try std.testing.expectEqual(@as(f32, 52), composing.area.x);
}

test "api-w12 candidate follows the moving end of a reversed selection" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    try harness.setText("abcd");
    try harness.placeCaret(3);
    harness.focus();
    _ = try harness.manager.caretGeometry();

    _ = try harness.manager.handle(&.{ .key_down = .{
        .key = .left,
        .modifiers = .{ .shift = true },
    } });
    const selection = harness.snapshot().selection;
    try std.testing.expect(selection.reversed);
    try std.testing.expectEqual(@as(usize, 2), selection.cursor());
    const caret = (try harness.manager.caretGeometry()).?;
    try std.testing.expectEqual(@as(f32, 36), caret.area.x);
    try std.testing.expectEqual(caret.area.x, harness.native.last.?.area.x);
}

test "api-w12 candidate follows preedit focus before the marked text ends" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    try harness.setText("ab");
    try harness.placeCaret(1);
    harness.focus();

    _ = try harness.manager.handle(&.{ .composition = .{
        .phase = .update,
        .text = "\xf0\x9f\x91\xa9\xf0\x9f\x91\xa7",
        .selection_start = 0,
        .selection_end = 4,
    } });
    const state = harness.snapshot();
    try std.testing.expectEqual(@as(usize, 3), state.selection.cursor());
    try std.testing.expectEqual(@as(usize, 5), state.marked.?.end);
    const caret = (try harness.manager.caretGeometry()).?;
    try std.testing.expectEqual(@as(f32, 44), caret.area.x);
    try std.testing.expectEqual(caret.area.x, harness.native.last.?.area.x);
}

test "api-w12 an ime-preferring consumer keeps printable keys from keybindings" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{ .ime_printable_keys = true });
    defer harness.deinit();
    try harness.setText("");
    harness.focus();
    const stroke: event.Event = .{ .key_down = .{
        .key = .unidentified,
        .logical = .{ .codepoint = 'a' },
    } };
    try std.testing.expectEqual(text_input.Outcome.handled, try harness.manager.handle(&stroke));
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", try harness.text(&buffer));
    _ = try harness.manager.handle(&.{ .text_input = .{ .text = "a" } });
    try std.testing.expectEqualStrings("a", try harness.text(&buffer));

    // A control-modified stroke is a keybinding, not IME input.
    try std.testing.expectEqual(
        text_input.Outcome.ignored,
        try harness.manager.handle(&.{ .key_down = .{
            .key = .unidentified,
            .logical = .{ .codepoint = 'c' },
            .modifiers = .{ .control = true },
        } }),
    );
}

test "api-w12 native text input starts once per focus and stops on blur" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    harness.focus();
    try std.testing.expectEqual(@as(u32, 1), harness.native.starts);
    // Re-registering the same identity must not restart an open session.
    harness.focus();
    try std.testing.expectEqual(@as(u32, 1), harness.native.starts);

    harness.manager.clear();
    try std.testing.expectEqual(@as(u32, 1), harness.native.stops);
    harness.focus();
    try std.testing.expectEqual(@as(u32, 2), harness.native.starts);
    try std.testing.expectEqual(text_input.NativeStatus.running, harness.manager.native_status);
}

test "api-w12 a driver without text input still edits through committed text" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    harness.native.unsupported = true;
    harness.focus();
    try std.testing.expectEqual(text_input.NativeStatus.unsupported, harness.manager.native_status);
    _ = try harness.manager.handle(&.{ .text_input = .{ .text = "typed" } });
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("typed", try harness.text(&buffer));
    harness.manager.clear();
    try std.testing.expectEqual(@as(u32, 0), harness.native.starts);
}

test "api-w12 a released model drops the endpoint instead of editing freed text" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    try harness.setText("gone soon");
    try harness.placeCaret(2);
    harness.focus();
    try std.testing.expect(harness.manager.focusedId() != null);

    try harness.session.release(Field, &harness.owner);
    try std.testing.expectError(
        error.EndpointReleased,
        harness.manager.handle(&.{ .text_input = .{ .text = "x" } }),
    );
    try std.testing.expectEqual(@as(?WidgetId, null), harness.manager.focusedId());
    try std.testing.expectEqual(text_input.NativeStatus.stopped, harness.manager.native_status);
    // The next event has no endpoint and is simply not routed.
    try std.testing.expectEqual(
        text_input.Outcome.ignored,
        try harness.manager.handle(&.{ .text_input = .{ .text = "x" } }),
    );
}

test "api-w12 re-registering a released endpoint is a fresh session" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    harness.focus();
    const before = harness.manager.geometry;
    harness.session.release(Field, &harness.owner) catch unreachable;
    harness.focus();
    try std.testing.expect(harness.manager.focusedId().?.eql(field_id));
    try std.testing.expectEqual(before, harness.manager.geometry);
    // The model is gone, so the first edit reports a released endpoint.
    try std.testing.expectError(
        error.EndpointReleased,
        harness.manager.handle(&.{ .text_input = .{ .text = "x" } }),
    );
}

test "api-w12 the same widget id on another model is a new session" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    harness.focus();
    try std.testing.expectEqual(@as(u32, 1), harness.native.starts);

    // A recycled slot presents the same WidgetId with a different model; the
    // registration must follow the new owner instead of the old buffer.
    var replacement: Field = .{ .gpa = std.testing.allocator };
    var second = try harness.session.create(Field, &replacement);
    harness.manager.register(.{
        .id = field_id,
        .owner = second.weak().erase(),
        .ops = text_input.Adapter(Field).ops(fieldHandlers()),
        .user = &harness,
    });
    try std.testing.expectEqual(@as(u32, 2), harness.native.starts);
    try std.testing.expectEqual(@as(u32, 1), harness.native.stops);
    _ = try harness.manager.handle(&.{ .text_input = .{ .text = "x" } });

    var seen: []const u8 = "";
    harness.session.read(Field, second, &seen, struct {
        fn run(field: *const Field, out: *[]const u8) anyerror!void {
            out.* = field.slice();
        }
    }.run) catch unreachable;
    try std.testing.expectEqualStrings("x", seen);

    // The old model was never touched.
    var old: []const u8 = "";
    harness.session.read(Field, harness.owner, &old, struct {
        fn run(field: *const Field, out: *[]const u8) anyerror!void {
            out.* = field.slice();
        }
    }.run) catch unreachable;
    try std.testing.expectEqualStrings("", old);
    harness.session.release(Field, &second) catch unreachable;
}
