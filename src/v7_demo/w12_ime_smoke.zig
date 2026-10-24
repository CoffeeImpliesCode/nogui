//! W12 native IME smoke — one ordinary text field, painted, on a real SDL
//! window, with no Neovim anywhere in the process.
//!
//! What this run proves, and what it does not, is the point of the file, so it
//! comes before the code.
//!
//! THREE MODES, and they do not claim each other's results:
//!   * default (no flag): every SDL event is SYNTHETIC. This binary builds it
//!     and pushes it through the same dispatch a real event takes. No input
//!     method produced it and no person typed it. The window is hidden on the
//!     dummy driver, no GPU is created, no font engine is created, and the
//!     field's geometry is a fixed-advance grid. The assertions are about the
//!     protocol and the host path, not about pixels.
//!   * `--native`: a real window on the session's own driver, the real GPU,
//!     and REAL PAINTED PIXELS — the field's box, its text, a selection, a
//!     preedit and a caret all go through the public scene lowering and the
//!     Oklab→sRGB blit into the swapchain image. Its events are still
//!     synthetic and BUILT BY THIS BINARY, so it proves the graphical path
//!     and says in its own output that it observed no input method.
//!   * `--interactive`: the same real window and the same real pixels, driven
//!     by a person with an installed input method. It FAILS when no real
//!     composition arrived, because a program cannot assert a composition it
//!     did not receive.
//!
//! Proved, through the production host path and nothing else:
//!   * `Application.dispatch` routes an `sdl3.events.Event`, `Window.translate`
//!     converts it, and the focused `nogui.App` applies it to an
//!     application-owned model registered with `App.registerTextEndpoint`.
//!   * Native text input really starts and stops. `Window.nativeTextInput`
//!     calls `SDL_StartTextInput` / `SDL_StopTextInput` on the window this
//!     process owns, and `Window.textInputActive` is read back from SDL.
//!   * A physical key inserts nothing and its commit inserts once; a preedit
//!     commit replaces its own marked text once and never appends after it;
//!     focus loss cancels an open preedit and stops native input; the candidate
//!     rectangle follows a wrapped and a scrolled caret and is never published
//!     for a caret that is scrolled out of the field.
//!   * In the default run one copy, one cut and one paste reach the W18
//!     clipboard the host bound, through `Manager.copy`/`cut`/`paste` and
//!     SDL's own offer: the bytes are gone from and back in the model, which
//!     is the whole round trip.
//!   * In the native modes the glyphs on screen, the caret bar and the
//!     candidate rectangle come from ONE `TextService`: the same layout
//!     rasterizes the runs, answers the grapheme motions and produces the
//!     rectangle handed to SDL, and the pixels are read back out of the
//!     Oklab target the presented passes wrote.
//!   * The scale this window is actually running at, printed wherever the run
//!     reports a driver: `display_scale` is what the platform says it draws
//!     this window at (`SDL_GetWindowDisplayScale`), and `pixel_scale` is what
//!     THIS run measured by dividing its own pixel extent by its own logical
//!     one. They are printed separately and beside the candidate rectangle on
//!     purpose. A backend can report a non-1× content scale and still hand the
//!     window 1:1 pixels — SDL3's X11 backend does exactly that — and a
//!     controller that read one number where there are two would place its
//!     candidate probe against a scale nothing drew with.
//!
//! Not proved, and not claimed anywhere below:
//!   * No candidate WINDOW is observed, in any mode. What is observed is the
//!     rectangle handed to `SDL_StartTextInputArea` — the endpoint's line box,
//!     rounded by `Window.candidateArea` — and, in a `--requests` run, the
//!     rectangle SDL itself is holding. Neither is a window an input method
//!     opened, and this file does not claim one was.
//!   * A clipboard SHARED WITH OTHER APPLICATIONS is proved ONLY by the
//!     authorized mode named at the end of this header, on a private X display
//!     with a second process as the source. The default run does drive one
//!     real copy, cut and paste through the port the host bound, but the dummy
//!     driver keeps its offer inside this process, so no other program can see
//!     it and no other program can be the source. Every other run keeps a
//!     refusing guard in the port, and the run fails if anything reaches it.
//!     The authorized mode needs a CONTROLLER as well: the second process that
//!     owns the source offer, and the second process that reads this run's own
//!     copy and cut back, are the controller's. So this file's own output names
//!     only the half it can see and never claims the half it cannot.
//!   * CJK glyphs are NOT in the pinned face. A composition this font cannot
//!     shape is painted as the layout's own missing-glyph boxes, and the run
//!     reports the missing-glyph count instead of calling it text.
//!
//! Run it: `zig build w12-ime-smoke`. Add `-- --native --frames 8` for the
//! bounded graphical run (it needs a display server and a GPU), or
//! `-- --interactive` for the person-at-the-keyboard run. `-- --native --ppm
//! <path>` also writes the last presented frame's Oklab readback as a PPM, so
//! the pixels can be inspected without trusting this report.
//!
//! `-- --interactive --requests` adds a line channel on stdin for an external
//! controller that owns a pipe: `state`, `targets`, `scroll <lines>` and
//! `quit`, each answered with one `ack` line of readback. It exists because
//! the interactive mode otherwise reports only at the END of the hold, so a
//! controller cannot learn the composed bytes, the published rectangle or
//! SDL's stored rectangle at the moment it caused them, and cannot move the
//! field's scroll at all.
//! `state` carries two more measured values for exactly that reason: `window=`,
//! this window's own position and size read back from SDL, because a candidate
//! window is placed at the stored rectangle plus that origin and a controller
//! cannot derive the origin from a window manager's frame without guessing;
// `state` carries `selection=<start>:<end>` beside `caret_unit` and `marked`
// for exactly the reason a caret position is not enough: `caret_unit` is the
// cursor of a range that may still be a range, so a commit that left a
// selection behind reads exactly like one that collapsed it. A controller
// cannot derive the range from the cursor, so the model states it.
//!
//! `targets` answers with this run's own two focus targets - the field's
//! button and the second one - as rectangles in this window's logical units,
//! beside that window's own origin, both read out of the tree the frame that
//! request presents first committed. It exists because the keyboard cannot
//! move the focus while this process owns it: while the field is focused the
//! window has native text input active, and SDL's X11 path hands EVERY key to
//! the input method before the application is offered one
//! (`X11_HandleKeyEvent`: `SDL_TextInputActive` gates `X11_XFilterEvent`, and
//! a filter that consumes the event skips `SDL_SendKeyboardKeyIgnoreModifiers`
//! altogether). So a controller that has to move the focus does it the way a
//! person does - a real pointer press on a real control - and needs the
//! control's own rectangle to press on instead of a guessed point. `state`
//! carries `keys=`, the number of key events that actually reached this App,
//! so a run can show that a key press it sent was taken by the input method
//! instead of arriving here.
//!
//! The channel is off unless asked for, because at the keyboard stdin is the
//! terminal this run is waiting on. It builds no event and writes no model
//! byte, so what it reports is still what the input method produced.
//!
//! `-- --interactive --requests --native-clipboard --clipboard-scope <literal>`
//! is the ONE authorized way to let this field's clipboard port reach a
//! platform clipboard, and it exists because the acceptance that matters here
//! cannot be met by one process offering bytes to itself: a paste has to
//! consume an offer SOME OTHER PROCESS owns, and a copy has to land where that
//! other process can read it back. The scope literal names the private
//! display AND the restore, because approving this run is approving exactly
//! those two things, and all three of them are checked before a byte moves:
//! the literal has to match character for character, `DISPLAY` has to be the
//! display the literal names, and the video driver has to be `x11`. No flag
//! combination loosens this on a session display, and `--native` alone never
//! does.
//!
//! In that mode four verbs join `state`, `targets`, `scroll` and `quit` on the
//! controller's pipe, and every one of them refuses BY NAME outside it:
//! `copy`, `cut` and `paste` run the shared W18 actions against the port the
//! host bound and answer with the service's own outcome, the bytes it moved,
//! the model's own counters, the selection it left and the model's bytes in
//! hex; `clipboard-restore` puts this private display's CLIPBOARD back and
//! answers with what the platform holds afterwards. The refusing guard is not
//! switched off for the mode: it is swapped out for the length of one action
//! and swapped straight back, so a key, a composition or a focus round trip
//! that reaches the port at any other moment still gets refused and still
//! counts.
//!
//! That mode answers the controller's pipe while it is still WAITING for the
//! real focus, because a controller cannot move the keyboard's focus with a
//! key (see `targets` above) and so has to aim a real pointer press at one of
//! this run's own controls — the very event that wait is blocked on. So
//! `targets`, `state`, `clipboard-restore` and `quit` are answered in that
//! wait; the verbs that act on a field nothing has focused refuse by name
//! there instead of being left unanswered. Nothing is focused, assumed or
//! built to answer a request, and the interactive mode WITHOUT this flag keeps
//! the wait it always had.
//!
//! The restore is exact about what it owes that display. The two selections
//! are MEASURED before the first authorized action and their bytes are OWNED
//! at full length, so a selection longer than any buffer here is put back whole
//! rather than clipped. An absent PRIMARY selection is left absent: the only
//! release SDL offers for it sets the primary selection to an empty string,
//! which on X11 is this process becoming the owner of nothing rather than the
//! previous owner being released, so writing it would trade one wrong state
//! for another. The answer beside the restore says which of the two happened.
//!
//! The SELECTION is not one of those verbs. It is made the way a person makes
//! one - real Home, arrow and Shift+arrow keys over XTEST on the private
//! display - and read back out of the model afterwards, because a selection is
//! not bytes and the bytes this run pastes still have to come from the
//! platform's own answer to another process's offer.
//!
//! That mode installs NO input method on the display and asks for none, so it
//! cannot pass by inheriting a composition. It therefore does not require one,
//! and it says in its own output that it proves the clipboard and not the IME.
//! The IME acceptance above is a different mode driven by a different
//! controller and is not weakened by this one: an interactive run WITHOUT this
//! flag behaves exactly as it did, including its refusal when no composition
//! arrives.
const std = @import("std");
const Io = std.Io;
const sdl3 = @import("sdl3");
const noapi = @import("noapi");

const nogui = @import("nogui");
const host = @import("nogui_host");
const frame_api = @import("v7_frame");
const ink = @import("w12_ime_ink.zig");

const text_input = nogui.text_input;
const Utf16Range = text_input.Utf16Range;
const Selection = text_input.Selection;
const Session = nogui.Session;
const geometry = nogui.geometry;

const window_title = "w12-ime-smoke";
const window_width: u32 = 640;
const window_height: u32 = 360;

const Reporter = struct {
    io: Io,
    buffer: [4096]u8 = @splat(0),
    checks: u32 = 0,
    failures: u32 = 0,

    /// A smoke whose whole product is its report cannot continue once stdout is
    /// gone: there is no evidence left to fail against, and no way to say so.
    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.buffer, fmt, args) catch
            @panic("W12 IME smoke could not format its own report");
        Io.File.stdout().writeStreamingAll(self.io, text) catch
            @panic("W12 IME smoke could not write its report");
    }

    /// One hard check. A failing check is printed with its observed values and
    /// counted; the run stops at the end rather than at the first failure, so
    /// one report names everything that broke.
    fn expectTrue(self: *Reporter, label: []const u8, ok: bool) void {
        self.checks += 1;
        if (!ok) self.failures += 1;
        self.emit("check {s}: {s}\n", .{ label, if (ok) "pass" else "FAIL" });
    }

    fn expectUsize(self: *Reporter, label: []const u8, expected: usize, actual: usize) void {
        self.checks += 1;
        const ok = expected == actual;
        if (!ok) self.failures += 1;
        self.emit("check {s}: expected={d} observed={d} {s}\n", .{
            label,
            expected,
            actual,
            if (ok) "pass" else "FAIL",
        });
    }

    fn expectCount(self: *Reporter, label: []const u8, expected: u32, actual: u32) void {
        self.checks += 1;
        const ok = expected == actual;
        if (!ok) self.failures += 1;
        self.emit("check {s}: expected={d} observed={d} {s}\n", .{
            label,
            expected,
            actual,
            if (ok) "pass" else "FAIL",
        });
    }

    fn expectText(self: *Reporter, label: []const u8, expected: []const u8, actual: []const u8) void {
        self.checks += 1;
        const ok = std.mem.eql(u8, expected, actual);
        if (!ok) self.failures += 1;
        self.emit("check {s}: expected=\"{s}\" observed=\"{s}\" {s}\n", .{
            label,
            expected,
            actual,
            if (ok) "pass" else "FAIL",
        });
    }

    fn expectRect(self: *Reporter, label: []const u8, expected: geometry.WindowRect, actual: geometry.WindowRect) void {
        self.checks += 1;
        const ok = expected.x == actual.x and expected.y == actual.y and
            expected.w == actual.w and expected.h == actual.h;
        if (!ok) self.failures += 1;
        self.emit(
            "check {s}: expected=({d:.1},{d:.1} {d:.1}x{d:.1}) observed=({d:.1},{d:.1} {d:.1}x{d:.1}) {s}\n",
            .{
                label,
                expected.x,
                expected.y,
                expected.w,
                expected.h,
                actual.x,
                actual.y,
                actual.w,
                actual.h,
                if (ok) "pass" else "FAIL",
            },
        );
    }
};

/// A minimal cluster rule: one codepoint per character, except that a
/// combining mark or a zero-width joiner continues the character before it.
/// A production field asks its W11 text layout for real grapheme boundaries;
/// this keeps the smoke free of a font dependency while still refusing to
/// split a character a person sees as one.
fn decodeAt(bytes: []const u8, index: usize) u21 {
    if (index >= bytes.len) return 0;
    // The variable-length decode is not used: a wrong length is silent
    // corruption, so the length is dispatched on explicitly.
    return switch (std.unicode.utf8ByteSequenceLength(bytes[index]) catch return 0) {
        1 => bytes[index],
        2 => std.unicode.utf8Decode2(bytes[index..][0..2].*) catch 0,
        3 => std.unicode.utf8Decode3(bytes[index..][0..3].*) catch 0,
        4 => std.unicode.utf8Decode4(bytes[index..][0..4].*) catch 0,
        else => 0,
    };
}

fn continuesCluster(bytes: []const u8, index: usize) bool {
    if (index == 0 or index >= bytes.len) return false;
    if (attaches(decodeAt(bytes, index))) return true;
    var previous = index - 1;
    while (previous > 0 and bytes[previous] & 0xc0 == 0x80) previous -= 1;
    return decodeAt(bytes, previous) == 0x200d;
}

fn attaches(value: u21) bool {
    return (value >= 0x0300 and value <= 0x036f) or value == 0x200d;
}

fn sizeAt(bytes: []const u8, index: usize) usize {
    if (index >= bytes.len) return 1;
    return std.unicode.utf8ByteSequenceLength(bytes[index]) catch 1;
}

fn clusterEnd(bytes: []const u8, from: usize) usize {
    var index: usize = 0;
    while (index < bytes.len) {
        if (index >= from and !continuesCluster(bytes, index)) return index;
        index += sizeAt(bytes, index);
    }
    return bytes.len;
}

fn clusterStartBefore(bytes: []const u8, at: usize) usize {
    if (at == 0) return 0;
    if (!continuesCluster(bytes, at)) {
        var previous = at - 1;
        while (previous > 0 and bytes[previous] & 0xc0 == 0x80) previous -= 1;
        var scan: usize = 0;
        var best: usize = 0;
        while (scan < previous and scan < bytes.len) {
            if (scan == 0 or !continuesCluster(bytes, scan)) best = scan;
            scan += sizeAt(bytes, scan);
        }
        return best;
    }
    var index: usize = 0;
    var last: usize = 0;
    while (index < at and index < bytes.len) {
        if (index == 0 or !continuesCluster(bytes, index)) last = index;
        index += sizeAt(bytes, index);
    }
    return last;
}

/// The application-owned field. The core never holds these bytes: the endpoint
/// borrows the model for the length of one call and resolves everything here.
///
/// The layout is a fixed-advance grid because that is enough to make wrapping
/// and scrolling observable, which is the only thing the candidate rectangle is
/// checked against. A production field reads the same values from its shaped
/// W11 layout.
const Field = struct {
    gpa: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    selection: Selection = .{},
    marked: ?Utf16Range = null,
    advance: f32 = 8,
    line_height: f32 = 16,
    /// UTF-16 units on one visual line before the field wraps.
    wrap_columns: usize = 8,
    /// Visual lines the field shows. A caret outside them has no candidate
    /// rectangle, because a candidate window anchored to a caret nobody can see
    /// is worse than no window.
    visible_lines: usize = 3,
    /// Visual lines scrolled off the top of the field.
    scroll_lines: usize = 0,
    origin: geometry.WindowRect = .{ .x = 24, .y = 40, .w = 0, .h = 0 },
    /// Every replacement and every mark, counted in the model. Byte equality
    /// alone cannot prove a commit replaced its own preedit once; a second
    /// insertion that happened to produce the same bytes would still be
    /// counted here.
    replacements: u32 = 0,
    marks: u32 = 0,
    caret_reads: u32 = 0,

    pub fn deinit(self: *Field, _: *Session) void {
        self.text.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn slice(self: *const Field) []const u8 {
        return self.text.items;
    }

    fn byteRange(self: *const Field, range: Utf16Range) !struct { start: usize, end: usize } {
        const bytes = self.slice();
        const low = @min(range.start, range.end);
        const high = @max(range.start, range.end);
        return .{
            .start = try text_input.utf16ToUtf8(bytes, low),
            .end = try text_input.utf16ToUtf8(bytes, high),
        };
    }

    fn unitAt(self: *Field, byte: usize) !usize {
        return text_input.utf8ToUtf16(self.slice(), byte);
    }

    fn caret(self: *Field) !usize {
        const raw = try text_input.utf16ToUtf8(self.slice(), self.selection.cursor());
        return self.unitAt(clusterStartBefore(self.slice(), raw));
    }

    fn splice(self: *Field, start: usize, end: usize, text: []const u8) !void {
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
    /// selection. This order is the rule that keeps a platform commit from
    /// duplicating the preedit it is committing.
    fn target(self: *Field, range: ?Utf16Range) Utf16Range {
        return range orelse self.marked orelse self.selection.range;
    }
};

fn readText(
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
    const bytes = try allocator.dupe(u8, field.slice()[region.start..region.end]);
    return bytes;
}

fn readSelection(field: *const Field, _: *anyopaque) anyerror!Selection {
    return field.selection;
}

fn readMarked(field: *const Field, _: *anyopaque) anyerror!?Utf16Range {
    return field.marked;
}

fn moveCaret(field: *Field, _: *anyopaque, request: text_input.Move) anyerror!Selection {
    if (request.offset) |offset| {
        field.selection = .{ .range = .{ .start = offset, .end = offset } };
        return field.selection;
    }
    const bytes = field.slice();
    const forward = request.direction == .forward;
    const cursor = try field.caret();
    const at = (try field.byteRange(.{ .start = cursor, .end = cursor })).start;
    // Every arm answers in bytes, and the conversion to the protocol's unit
    // happens once, below.
    const target: usize = switch (request.unit) {
        .grapheme => if (forward)
            clusterEnd(bytes, at + sizeAt(bytes, at))
        else
            clusterStartBefore(bytes, at),
        // A word is a run of non-whitespace plus the whitespace after it. This
        // is a fixture rule, not a language tokenizer, and it is only ever
        // asked for by the protocol's own word motion.
        .word => if (forward) wordEnd(bytes, at) else wordStart(bytes, at),
        // A line is one visual line of the wrapping field, so line motion and
        // the candidate geometry read the same grid.
        .line => blk: {
            const unit = try field.unitAt(at);
            const total = try text_input.utf16Length(bytes);
            const line = unit / field.wrap_columns;
            const edge = if (forward)
                @min(total, (line + 1) * field.wrap_columns)
            else
                line * field.wrap_columns;
            break :blk try text_input.utf16ToUtf8(bytes, edge);
        },
        .document => if (forward) bytes.len else 0,
    };
    const next = try field.unitAt(target);
    const anchor = field.selection.anchor();
    field.selection = if (request.extend)
        .{
            .range = .{ .start = @min(anchor, next), .end = @max(anchor, next) },
            .reversed = next < anchor,
        }
    else
        .{ .range = .{ .start = next, .end = next } };
    return field.selection;
}

fn isSpaceByte(value: u8) bool {
    return value == ' ' or value == '\t' or value == '\n' or value == '\r';
}

/// The next word boundary after `at`: past the current word, then past the
/// whitespace that follows it.
fn wordEnd(bytes: []const u8, at: usize) usize {
    var index = at;
    while (index < bytes.len and !isSpaceByte(bytes[index])) index += sizeAt(bytes, index);
    while (index < bytes.len and isSpaceByte(bytes[index])) index += 1;
    return index;
}

/// The start of the word before `at`.
fn wordStart(bytes: []const u8, at: usize) usize {
    if (at == 0) return 0;
    var best: usize = 0;
    var index: usize = 0;
    while (index < at and index < bytes.len) {
        if (index > 0 and isSpaceByte(bytes[index]) != isSpaceByte(bytes[index - 1])) best = index;
        index += sizeAt(bytes, index);
    }
    return best;
}

fn eraseText(field: *Field, _: *anyopaque, request: text_input.Erase) anyerror!void {
    const bytes = field.slice();
    const cursor = try field.caret();
    const at = (try field.byteRange(.{ .start = cursor, .end = cursor })).start;
    const range = if (request.extend or !field.selection.range.isEmpty())
        field.selection.range
    else if (request.backward)
        Utf16Range{ .start = try field.unitAt(clusterStartBefore(bytes, at)), .end = cursor }
    else
        Utf16Range{ .start = cursor, .end = try field.unitAt(clusterEnd(bytes, at + sizeAt(bytes, at))) };
    const region = try field.byteRange(range);
    try field.splice(region.start, region.end, "");
    const caret = try field.unitAt(region.start);
    field.marked = null;
    field.selection = .{ .range = .{ .start = caret, .end = caret } };
}

fn replaceText(field: *Field, _: *anyopaque, range: ?Utf16Range, text: []const u8) anyerror!void {
    const region = try field.byteRange(field.target(range));
    try field.splice(region.start, region.end, text);
    const caret = try field.unitAt(region.start + text.len);
    field.marked = null;
    field.selection = .{ .range = .{ .start = caret, .end = caret } };
    field.replacements += 1;
}

fn replaceAndMark(
    field: *Field,
    _: *anyopaque,
    range: ?Utf16Range,
    text: []const u8,
    inside: ?Utf16Range,
) anyerror!void {
    const region = try field.byteRange(field.target(range));
    try field.splice(region.start, region.end, text);
    const base = try field.unitAt(region.start);
    const length = try text_input.utf16Length(text);
    field.marked = if (text.len == 0) null else Utf16Range{ .start = base, .end = base + length };
    const caret = if (inside) |value| base + @min(value.end, length) else base + length;
    field.selection = .{ .range = .{ .start = caret, .end = caret } };
    field.marks += 1;
}

fn unmarkText(field: *Field, _: *anyopaque) anyerror!void {
    field.marked = null;
}

fn caretGeometry(field: *Field, _: *anyopaque, range: Utf16Range) anyerror!?text_input.Caret {
    field.caret_reads += 1;
    const line = range.end / field.wrap_columns;
    // A caret scrolled above the field, or below its last visible line, has no
    // place to anchor a candidate window.
    if (line < field.scroll_lines) return null;
    if (line - field.scroll_lines >= field.visible_lines) return null;
    const column = range.end % field.wrap_columns;
    return .{ .area = .{
        .x = field.origin.x + field.advance * @as(f32, @floatFromInt(column)),
        .y = field.origin.y + field.line_height * @as(f32, @floatFromInt(line - field.scroll_lines)),
        .w = 0,
        .h = field.line_height,
    }, .cursor = 0 };
}

fn indexAtPoint(field: *const Field, _: *anyopaque, point: geometry.WindowPoint) anyerror!?usize {
    const row = @floor((point.y - field.origin.y) / field.line_height);
    if (row < 0) return 0;
    const line = @as(usize, @intFromFloat(row)) + field.scroll_lines;
    const column: f32 = @floor((point.x - field.origin.x) / field.advance + 0.5);
    const units = line * field.wrap_columns + @as(usize, @intFromFloat(@max(column, 0)));
    return @min(units, try text_input.utf16Length(field.slice()));
}

fn fieldOps() text_input.Ops {
    return text_input.Adapter(Field).ops(.{
        .text = readText,
        .selection = readSelection,
        .marked = readMarked,
        .move = moveCaret,
        .erase = eraseText,
        .replace = replaceText,
        .replace_and_mark = replaceAndMark,
        .unmark = unmarkText,
        .caret = caretGeometry,
        .index_at = indexAtPoint,
    });
}

/// A read of everything the report asserts about the model, copied out of the
/// Session borrow. Nothing here keeps a pointer into the model: the borrow ends
/// when `read` returns.
const FieldState = struct {
    // SAFETY: the field snapshot fills buffer[0..len] before any text read.
    buffer: [256]u8 = undefined,
    len: usize = 0,
    selection: Selection = .{},
    marked: ?Utf16Range = null,
    replacements: u32 = 0,
    marks: u32 = 0,
    caret_reads: u32 = 0,
    scroll_lines: usize = 0,

    fn read(field: *const Field, context: *anyopaque) anyerror!void {
        const typed: *FieldState = @ptrCast(@alignCast(context));
        const bytes = field.slice();
        if (bytes.len > typed.buffer.len) return error.FieldTooLongForProbe;
        @memcpy(typed.buffer[0..bytes.len], bytes);
        typed.len = bytes.len;
        typed.selection = field.selection;
        typed.marked = field.marked;
        typed.replacements = field.replacements;
        typed.marks = field.marks;
        typed.caret_reads = field.caret_reads;
        typed.scroll_lines = field.scroll_lines;
    }

    fn text(self: *const FieldState) []const u8 {
        return self.buffer[0..self.len];
    }
};

const SetScroll = struct {
    lines: usize,
    fn apply(field: *Field, context: *anyopaque) anyerror!void {
        const typed: *SetScroll = @ptrCast(@alignCast(context));
        field.scroll_lines = typed.lines;
    }
};

/// Select a UTF-16 range in the model, the way a pointer press over the text
/// would. The clipboard actions below need a real selection, and a selection
/// the model owns is the one the protocol reads.
const SetSelection = struct {
    range: Utf16Range,

    fn apply(field: *Field, context: *anyopaque) anyerror!void {
        const typed: *SetSelection = @ptrCast(@alignCast(context));
        field.selection = .{
            .range = typed.range,
            .reversed = typed.range.start > typed.range.end,
        };
    }
};

/// The byte count an edit action reported. An action that reports no count is
/// zero here, which fails every count below rather than quietly passing one.
fn outcomeBytes(outcome: text_input.EditOutcome) usize {
    return switch (outcome) {
        .copied => |bytes| bytes,
        .cut => |bytes| bytes,
        .pasted => |bytes| bytes,
        else => 0,
    };
}

/// The host's own native text-input port, wrapped so every call the core makes
/// is observable, and every call still reaches SDL. Nothing is faked here: the
/// inner port is `Window.nativeTextInput`, and the counters count what the core
/// asked the platform to do.
const NativeTrace = struct {
    // SAFETY: main assigns the host port before installing this trace.
    inner: text_input.Native = undefined,
    starts: u32 = 0,
    stops: u32 = 0,
    clears: u32 = 0,
    areas: u32 = 0,
    start_error: ?anyerror = null,
    last: ?text_input.Caret = null,

    fn port(self: *NativeTrace) text_input.Native {
        return .{
            .user = self,
            .start = start,
            .stop = stop,
            .set_area = setArea,
            .clear_composition = clearComposition,
        };
    }

    fn start(user: *anyopaque) anyerror!void {
        const self: *NativeTrace = @ptrCast(@alignCast(user));
        self.inner.start(self.inner.user) catch |err| {
            self.start_error = err;
            return err;
        };
        self.starts += 1;
    }

    fn stop(user: *anyopaque) anyerror!void {
        const self: *NativeTrace = @ptrCast(@alignCast(user));
        self.inner.stop(self.inner.user) catch |err| {
            self.start_error = err;
            return err;
        };
        self.stops += 1;
    }

    fn setArea(user: *anyopaque, area: geometry.WindowRect, cursor: f32) anyerror!void {
        const self: *NativeTrace = @ptrCast(@alignCast(user));
        const publish = self.inner.set_area orelse return error.NativeCandidateUnavailable;
        try publish(self.inner.user, area, cursor);
        self.areas += 1;
        self.last = .{ .area = area, .cursor = cursor };
    }

    fn clearComposition(user: *anyopaque) void {
        const self: *NativeTrace = @ptrCast(@alignCast(user));
        const dismiss = self.inner.clear_composition orelse return;
        dismiss(self.inner.user);
        self.clears += 1;
    }
};

/// The refusing guard that owns the clipboard port for the whole scripted
/// run. The host binds the real W18 service when the window opens, so this
/// REPLACES that port with one that counts an edit action, answers
/// `unavailable`/`failed` and writes nothing to the user's clipboard. The run
/// fails if the count is not zero, so "the scripted run touched no clipboard"
/// is checked rather than assumed. The default run's own clipboard section
/// puts the real port back for the round trip it names, and puts the guard
/// back before the run ends.
const ClipboardGuard = struct {
    attempts: u32 = 0,

    fn port(self: *ClipboardGuard) text_input.Clipboard {
        return .{ .user = self, .read = refuseRead, .write = refuseWrite };
    }

    fn refuseRead(_: std.mem.Allocator, user: *anyopaque) text_input.ClipboardRead {
        const self: *ClipboardGuard = @ptrCast(@alignCast(user));
        self.attempts += 1;
        return .unavailable;
    }

    fn refuseWrite(user: *anyopaque, _: []const u8) text_input.ClipboardWrite {
        const self: *ClipboardGuard = @ptrCast(@alignCast(user));
        self.attempts += 1;
        return .failed;
    }
};

/// The private display's two text selections, MEASURED before the authorized
/// mode is allowed to touch either one.
///
/// A restore has to put back what was there, and "what was there" is a
/// measurement rather than an assumption: a private X server usually holds
/// neither selection, but "usually" is not "always", and clearing a selection
/// somebody had would be exactly the damage this mode exists to avoid. A
/// selection this platform cannot report is recorded as unreadable and then
/// left alone, because a restore that acts on an unreadable selection is a
/// guess.
///
/// The two texts are OWNED rather than measured into a fixed buffer: a
/// baseline longer than any buffer would otherwise be restored clipped, and
/// half of somebody's selection is not the state anybody found. `capture`
/// copies whatever the platform holds onto the heap in full, `deinit` gives
/// both copies back, and the restore writes the same bytes the measurement
/// read, so the length of a selection this run puts back is never this file's
/// business to decide.
const PrivateSelections = struct {
    /// The allocator the two owned texts live on. `capture` sets it and
    /// `deinit` reads it, so there is nothing owned before a capture and
    /// nothing owned after a deinit.
    gpa: ?std.mem.Allocator = null,
    clipboard_present: bool = false,
    /// Null unless `clipboard_present`: a present selection always owns the
    /// bytes it was measured holding, at their measured length.
    clipboard_text: ?[]u8 = null,
    primary_present: bool = false,
    /// Null unless `primary_present`, on the same note as `clipboard_text`.
    primary_text: ?[]u8 = null,
    /// False when this platform cannot report the primary selection at all, so
    /// "absent" would name something this run never looked at.
    primary_readable: bool = true,
    /// True once this run's restore WROTE the primary selection back because
    /// it held something. An absent primary is never written into: setting the
    /// primary selection to an empty string is an offer of nothing BY THIS
    /// PROCESS, not a release of what the display held, so writing it would
    /// hand the selection to a process that is about to exit.
    primary_written: bool = false,

    /// The measured length of the clipboard text, or zero when nothing was
    /// there. It is printed beside the readback so a hex this line had to clip
    /// shows up as a count that does not match it.
    fn clipboardBytes(self: *const PrivateSelections) usize {
        return if (self.clipboard_text) |bytes| bytes.len else 0;
    }

    /// The same measurement for the primary selection.
    fn primaryBytes(self: *const PrivateSelections) usize {
        return if (self.primary_text) |bytes| bytes.len else 0;
    }

    fn capture(self: *PrivateSelections, gpa: std.mem.Allocator) !void {
        // A second capture would orphan the first one's copies, and this is a
        // MEASUREMENT: taking it twice must not leak what taking it once owned.
        self.deinit();
        self.* = .{ .gpa = gpa };
        if (host.clipboard.hasText()) {
            if (try host.clipboard.readText(gpa)) |bytes| {
                defer gpa.free(bytes);
                // Copied at FULL length. A copy clipped to a buffer would be
                // restored clipped, and this runs before the first authorized
                // action, so refusing to own the bytes here would refuse the
                // mode before it had changed anything at all.
                self.clipboard_text = try gpa.dupe(u8, bytes);
                self.clipboard_present = true;
            }
        }
        if (!host.clipboard.supportsPrimarySelection()) {
            self.primary_readable = false;
            return;
        }
        if (host.clipboard.getPrimaryText(gpa)) |maybe| {
            const bytes = maybe orelse return;
            defer gpa.free(bytes);
            self.primary_text = try gpa.dupe(u8, bytes);
            self.primary_present = true;
        } else |_| {
            self.primary_readable = false;
        }
    }

    /// Give both measured copies back. It runs after the scenario in every
    /// outcome, so a run that refused half way through still releases what it
    /// copied out of the display.
    fn deinit(self: *PrivateSelections) void {
        const gpa = self.gpa orelse return;
        if (self.clipboard_text) |bytes| gpa.free(bytes);
        if (self.primary_text) |bytes| gpa.free(bytes);
        self.* = undefined;
    }

    /// Put the CLIPBOARD selection back, only when it was MEASURED before the
    /// run touched it, and through the SAME shared W18 port every other action
    /// on this run uses rather than through a clipboard this file implements.
    ///
    /// PRIMARY is put back only when it held something. An absent primary is
    /// LEFT EXACTLY AS IT IS: the only release SDL offers for it is
    /// `SDL_SetPrimarySelectionText("")`, which on X11 is this process
    /// becoming the owner of an empty primary rather than the previous owner
    /// being released. Nothing was taken from a primary that held nothing, so
    /// nothing is written into one, and the answer beside this call says the
    /// selection was left untouched rather than claiming it was restored.
    fn restore(self: *PrivateSelections, gpa: std.mem.Allocator, port: text_input.Clipboard) !void {
        if (self.clipboard_present) {
            const write = port.write orelse return error.HostClipboardHasNoWrite;
            const measured = self.clipboard_text orelse return error.BaselineTextMissing;
            if (write(port.user, measured) == .failed) {
                return error.ClipboardRestoreFailed;
            }
        } else {
            // Nothing was there, so OWNERSHIP is what has to go rather than
            // text: a clear releases this process's offer and ends it, which is
            // what "the selection was empty" means to the next process that
            // asks. The throwaway service holds no offer, so it releases
            // nothing of its own.
            var service = host.clipboard.Clipboard.init(gpa);
            defer service.deinit();
            try service.clear();
        }
        if (!self.primary_readable) return;
        if (!self.primary_present) return;
        try host.clipboard.setPrimaryText(gpa, self.primary_text orelse return error.BaselineTextMissing);
        self.primary_written = true;
    }
};

/// The ink palette's defaults, named once. The view's placeholder box below is
/// the painter's padding around an empty field box, so it reads the padding
/// from the same palette the painter pads with rather than from a literal.
const ink_palette: ink.Palette = .{};

/// The root view: two focus targets, so a focus switch has somewhere to go. The
/// first is the field's focus identity; the field itself is a model behind the
/// W12 protocol, not a widget, so the view is also where the field's CLIP
/// comes from: the painted glyphs and boxes are cut to the field's own box,
/// exactly as a scroll container's content is cut to the container.
const View = struct {
    /// Mirrors what the App's text-input manager holds, so an interactive run
    /// shows on the window which target owns the keyboard. The headless run
    /// reads it back out of the tree instead of trusting its own bookkeeping.
    field_holds_keyboard: bool = false,
    /// The frame clip id covering the field's painted box, pushed by this
    /// view every frame. Copied out by the run and handed to the field's
    /// painter, so a scrolled line is cut by the field and not by the window.
    /// `frame_api.scene.no_clip` until the first frame draws.
    field_clip: u32 = frame_api.scene.no_clip,
    /// Where the field's own box is, in window-logical units. The run copies
    /// the shaped field's geometry in before each frame, so the clip and the
    /// painted pixels cannot be two different boxes.
    field_box: geometry.WindowRect = ink.paintBox(.{}, ink_palette.padding),
    /// What the model holds, copied in by the run after each event. The label
    /// is duplicated into the frame arena, so a borrowed slice is safe here and
    /// an interactive person sees the field's own text rather than this
    /// binary's account of it.
    // SAFETY: draw reads only status[0..status_len], which the reporter fills.
    status: [192]u8 = undefined,
    status_len: usize = 0,

    pub fn draw(self: *View, ctx: *nogui.DrawCtx) !void {
        // The field is painted by the run at this box, so the clip is the
        // field's own bounds and the buttons start below it.
        self.field_clip = try ctx.pushClip(
            self.field_box.x,
            self.field_box.y,
            self.field_box.w,
            self.field_box.h,
        );
        defer ctx.popClip();
        _ = try ctx.column(.{
            .padding = .{
                .top = self.field_box.y + self.field_box.h + 16,
                .left = @max(self.field_box.x, 16),
                .right = 16,
                .bottom = 16,
            },
            .gap = 8,
        });
        defer ctx.pop();
        const label: []const u8 = if (self.status_len == 0)
            "Ordinary text field"
        else
            self.status[0..self.status_len];
        _ = try ctx.button(.{
            .key = @as(nogui.ComponentKey, .{ .static = "field" }),
            .label = label,
        });
        _ = try ctx.button(.{
            .key = @as(nogui.ComponentKey, .{ .static = "other" }),
            .label = "Second focus target",
        });
    }
};

const Options = struct {
    /// A real window, the real GPU and real painted pixels, driven by
    /// synthetic events. Proves the graphical path; observes no input method.
    native: bool = false,
    /// A real window and real painted pixels, driven by a person. Fails when
    /// no real composition arrives.
    interactive: bool = false,
    /// Serve line requests on this process's stdin while the interactive loop
    /// runs. OFF by default, and it has to stay off for a person: at the
    /// keyboard this process's stdin is the terminal, and a run that read it
    /// would swallow the very keys whose arrival it is waiting for. An
    /// external controller owns a pipe instead and turns this on.
    requests: bool = false,
    hold_ms: u64 = 120_000,
    /// Bounded frame budget for `--native`. Zero means `native_frame_budget`.
    frames: u32 = 0,
    /// Optional PPM of the last presented frame's Oklab readback.
    ppm: ?[]const u8 = null,
    /// The authorized native clipboard consumer mode. It asks for a real
    /// window, the controller's pipe and the scope literal below all at once,
    /// and it is refused outright without all three, so there is no flag
    /// combination that reaches a platform clipboard without a name attached
    /// to the request.
    native_clipboard: bool = false,
    /// The point-of-risk authorization literal, character for character. It is
    /// checked here rather than trusted, and an absent one is a refusal rather
    /// than a default.
    clipboard_scope: ?[]const u8 = null,
    /// The DISPLAY this process was started on, read out of its own
    /// environment before anything else runs. It is a measurement, and the
    /// authorized mode refuses unless the measurement is the private display
    /// the scope literal names.
    display: ?[]const u8 = null,

    /// The default budget for `--native`: short enough to watch, long enough
    /// to see a resize and a scale sync inside it.
    pub const native_frame_budget: u32 = 20;

    /// The scripted graphical run presents this many frames by itself. A
    /// smaller `--frames` is refused rather than silently truncating the
    /// script and reporting fewer checks than the script claims.
    pub const minimum_native_frames: u32 = 12;

    /// How long the interactive mode waits for a real key or click to give
    /// something the focus before it refuses. Long enough for a person to
    /// reach for the mouse; short enough that an unattended run fails with a
    /// named reason instead of waiting on a window nobody will ever click.
    pub const interactive_focus_wait_ms: u64 = 30_000;

    /// The ONE authorization literal the native clipboard consumer mode
    /// accepts, character for character. It names the display AND the restore
    /// because approving this run is approving exactly those two things:
    /// reading and replacing the two text selections of one private X server,
    /// and putting them back before it ends. It is deliberately not a general
    /// "go native" switch: `--native` alone reaches the graphical path and
    /// never reaches a clipboard.
    pub const native_clipboard_scope =
        "nogui-w12-native-clipboard-private-display-:4-restore-clipboard-and-primary";

    /// The ONLY display the authorized mode accepts. The scope literal names
    /// the same display and both have to hold: a display taken from the
    /// environment alone would let a run somebody pointed at their own session
    /// paste into it, and a run pointed at one private server is refused when
    /// it lands on another.
    pub const native_clipboard_display = ":4";

    /// True when this run opens a real window, creates a device and paints.
    fn paints(self: Options) bool {
        return self.native or self.interactive;
    }

    fn frameBudget(self: Options) u32 {
        return if (self.frames == 0) native_frame_budget else self.frames;
    }
};

fn parseOptions(gpa: std.mem.Allocator, init: std.process.Init) !Options {
    var options: Options = .{};
    // The display is MEASURED here, from this process's own environment, and
    // never taken from an argument: a run that could be told which display to
    // use could be pointed at a session's clipboard.
    options.display = init.environ_map.get("DISPLAY");
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--native")) {
            options.native = true;
        } else if (std.mem.eql(u8, arg, "--interactive")) {
            options.interactive = true;
        } else if (std.mem.eql(u8, arg, "--requests")) {
            options.requests = true;
        } else if (std.mem.eql(u8, arg, "--hold-ms")) {
            const value = args.next() orelse return error.MissingHoldMs;
            options.hold_ms = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--frames")) {
            const value = args.next() orelse return error.MissingFrames;
            options.frames = try std.fmt.parseInt(u32, value, 10);
            if (options.frames == 0) return error.ZeroFrameBudget;
        } else if (std.mem.eql(u8, arg, "--ppm")) {
            options.ppm = args.next() orelse return error.MissingPpmPath;
        } else if (std.mem.eql(u8, arg, "--native-clipboard")) {
            options.native_clipboard = true;
        } else if (std.mem.eql(u8, arg, "--clipboard-scope")) {
            options.clipboard_scope = args.next() orelse return error.MissingClipboardScope;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }
    if (options.native and options.interactive) return error.ConflictingModes;
    if (options.requests and !options.interactive) return error.RequestsNeedInteractive;
    if (options.frames != 0 and !options.native) return error.FramesNeedNative;
    if (options.ppm != null and !options.paints()) return error.PpmNeedsNative;
    if (options.native_clipboard) {
        const scope = options.clipboard_scope orelse return error.NativeClipboardNeedsScope;
        if (!std.mem.eql(u8, scope, Options.native_clipboard_scope)) {
            std.log.err(
                "--native-clipboard was refused: the scope literal is not the one this binary accepts",
                .{},
            );
            return error.UnauthorizedNativeClipboardScope;
        }
        if (!options.interactive) return error.NativeClipboardNeedsInteractive;
        if (!options.requests) return error.NativeClipboardNeedsRequests;
        const display = options.display orelse "<unset>";
        if (!std.mem.eql(u8, display, Options.native_clipboard_display)) {
            std.log.err(
                "--native-clipboard was refused: DISPLAY is \"{s}\", not the private display {s}",
                .{ display, Options.native_clipboard_display },
            );
            return error.NativeClipboardDisplayNotPrivate;
        }
    }
    if (options.clipboard_scope != null and !options.native_clipboard) {
        return error.ClipboardScopeNeedsNativeClipboard;
    }
    if (options.frames != 0 and options.frames < Options.minimum_native_frames) {
        std.log.err("--frames {d} is below the scripted run's own {d} frames", .{
            options.frames,
            Options.minimum_native_frames,
        });
        return error.FrameBudgetTooSmall;
    }
    return options;
}

/// Synthetic SDL events. These are built here and pushed through the host's own
/// dispatch; nothing downstream of `Application.dispatch` can tell the
/// difference, which is exactly why this proves the translation and not the
/// IME.
fn keyEvent(window_id: sdl3.video.WindowId, native: sdl3.keycode.Keycode, shifted: bool) sdl3.events.Event {
    return .{ .key_down = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .window_id = window_id,
        .id = null,
        .scancode = null,
        .key = native,
        .mod = .{ .left_shift = shifted },
        .raw = 0,
        .down = true,
        .repeat = false,
    } };
}

fn textInputEvent(window_id: ?sdl3.video.WindowId, text: [:0]const u8) sdl3.events.Event {
    return .{ .text_input = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .window_id = window_id,
        .text = text,
    } };
}

fn textEditingEvent(
    window_id: ?sdl3.video.WindowId,
    text: [:0]const u8,
    start: ?usize,
    length: ?usize,
) sdl3.events.Event {
    return .{ .text_editing = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .window_id = window_id,
        .text = text,
        .start = start,
        .length = length,
    } };
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var found: usize = 0;
    var index: usize = 0;
    while (std.mem.findPos(u8, haystack, index, needle)) |at| {
        found += 1;
        index = at + needle.len;
    }
    return found;
}

/// The endpoint's rectangle, formatted into a caller-owned buffer. A null
/// rectangle is a real observation — a caret scrolled out of the field — so it
/// is named rather than omitted.
fn rectText(buffer: []u8, value: ?geometry.WindowRect) []const u8 {
    const rect = value orelse return "<none>";
    return std.fmt.bufPrint(buffer, "({d:.1},{d:.1} {d:.1}x{d:.1})", .{
        rect.x, rect.y, rect.w, rect.h,
    }) catch "<rect>";
}

/// The whole-pixel rectangle SDL actually receives, through the host's own
/// conversion. This is what an input method anchors its candidate window to,
/// and it is still not a candidate window.
fn sdlRectText(buffer: []u8, value: ?geometry.WindowRect) []const u8 {
    const rect = value orelse return "<none>";
    const pixels = host.Window.candidateArea(rect);
    return std.fmt.bufPrint(buffer, "({d},{d} {d}x{d})", .{
        pixels.x, pixels.y, pixels.w, pixels.h,
    }) catch "<rect>";
}

/// One control's own border box in the committed tree, addressed by the stable
/// identity that holds it there, in window-logical units. Null when nothing
/// holds that identity in this frame, and null for an empty box: a control
/// nothing can be pressed on is not reported as a place to press.
fn widgetRect(tree: *const nogui.widget.WidgetTree, id: ?nogui.WidgetId) ?geometry.WindowRect {
    const widget_id = id orelse return null;
    const node = tree.frameNode(widget_id) orelse return null;
    const box = nogui.widget.absoluteRect(tree, node);
    if (box.w <= 0 or box.h <= 0) return null;
    return .{ .x = box.x, .y = box.y, .w = box.w, .h = box.h };
}

/// One KEYED control's box: the keys are the ones `View.draw` gives this run's
/// two buttons, so a controller is handed the names the layout itself was
/// built from rather than a list it has to interpret.
fn targetRect(
    app: *const nogui.App,
    tree: *const nogui.widget.WidgetTree,
    key: []const u8,
) ?geometry.WindowRect {
    return widgetRect(tree, app.widgetIdForKey(.root, .{ .static = key }));
}

/// The line protocol an external controller drives `--requests` with. It is
/// NOT a test seam and it builds no event: every value it answers with comes
/// from the App, the endpoint, the painted scene or SDL's own stored
/// rectangle, and it can only ask for a state readback, ask where this run's
/// own focus targets are, move the scroll and end the run. The loop stays in
/// charge of the event pump.
///
/// stdin is polled with a zero timeout and drained a chunk at a time, so a
/// request never blocks the poll that would deliver the composition the
/// controller is waiting for. One line in, one `ack` line out; every other
/// line on stdout is this run's own report and a controller skips those.
const Requests = struct {
    gpa: std.mem.Allocator,
    /// Bytes read but not yet terminated by a newline. This is the only
    /// allocation the reader makes and it is freed by `deinit`.
    pending: std.ArrayList(u8) = .empty,
    /// The line `poll` handed out, without its newline. `take` borrows it.
    /// `init` is what makes it a value: see the SAFETY note there.
    line: [128]u8,
    line_len: usize = 0,
    /// Set when the pipe reached end of file. A closed pipe is not an error:
    /// a controller that died simply stops being answered.
    eof: bool = false,

    /// Lines longer than this are refused rather than truncated: a truncated
    /// `scroll` argument would be a DIFFERENT scroll.
    pub const max_line = 128;

    /// Bytes a controller may leave unterminated before the reader refuses.
    /// It is many whole lines, so a burst of requests in one read is fine and
    /// only a writer that never sends a newline is stopped.
    pub const max_pending = 4096;

    fn init(self: *Requests, gpa: std.mem.Allocator) void {
        self.* = .{
            .gpa = gpa,
            // SAFETY: nothing reads `line` before `splitLine` has written
            // `line[0..at]` and set `line_len = at`, and `take` borrows
            // exactly `line[0..line_len]`. The bytes past that length are
            // never read, so leaving them undefined costs nothing and no
            // 128-byte buffer is zeroed to say so.
            .line = undefined,
        };
    }

    fn deinit(self: *Requests) void {
        self.pending.deinit(self.gpa);
        self.* = undefined;
    }

    /// Move whatever stdin has into the pending buffer. `true` means one whole
    /// line is ready in `line`; `false` means not yet, and is not a failure. A
    /// closed pipe answers no line either, which is how a controller that died
    /// stops being answered without failing the run.
    fn poll(self: *Requests) !bool {
        if (self.eof) return false;
        try self.readChunk();
        return self.splitLine();
    }

    /// One bounded read of whatever the pipe already holds. The poll above is
    /// what makes this a non-blocking read: with nothing pending the pipe is
    /// never asked for bytes the writer has not sent.
    fn readChunk(self: *Requests) !void {
        var fds = [_]std.posix.pollfd{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&fds, 0) == 0) return;
        // SAFETY: `read` fills `chunk[0..got]` or fails, only that prefix is
        // appended below, and the buffer lives and dies inside this call.
        var chunk: [1024]u8 = undefined;
        const got = try std.posix.read(std.posix.STDIN_FILENO, &chunk);
        if (got == 0) {
            self.eof = true;
            return;
        }
        try self.pending.appendSlice(self.gpa, chunk[0..got]);
        // A writer that never terminates a line must not grow this buffer for
        // ever, so an over-long unterminated run is refused like a long line.
        if (self.pending.items.len > max_pending) return error.RequestTooLong;
    }

    /// Drop everything before the first newline into `line`. Erroneous
    /// lengths are refused; a partial line is simply left in `pending`.
    fn splitLine(self: *Requests) error{RequestTooLong}!bool {
        const at = std.mem.indexOfScalar(u8, self.pending.items, '\n') orelse return false;
        if (at > max_line) return error.RequestTooLong;
        @memcpy(self.line[0..at], self.pending.items[0..at]);
        self.line_len = at;
        const rest = self.pending.items[at + 1 ..];
        // The tail still pending overlaps the front it moves into, so this is
        // a move rather than a copy: the bytes behind the newline have to
        // survive being shifted down over the line that is being served.
        @memmove(self.pending.items[0..rest.len], rest);
        self.pending.shrinkRetainingCapacity(rest.len);
        return true;
    }

    /// The line `poll` handed out. A trailing carriage return is stripped so a
    /// controller may use a normal line discipline.
    fn take(self: *const Requests) []const u8 {
        var line = self.line[0..self.line_len];
        if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return line;
    }
};

const Run = struct {
    gpa: std.mem.Allocator,
    report: *Reporter,
    session: *Session,
    application: *host.Application,
    app: *nogui.App,
    /// The real shaped field, present only in the modes that create a device
    /// and a text engine. Its absence is what makes the headless geometry
    /// synthetic and the headless run GPU-free, and the report says which of
    /// the two ran.
    ink: ?*ink.Ink = null,
    /// The device, the surface that presents into the real window and the
    /// public frame adapter, present only in the painting modes.
    native: ?*Native = null,
    /// What the field's painter recorded in the last presented frame. Read
    /// back out after every frame so the report names scene rects rather than
    /// the text it meant to draw.
    painted: ink.Painted = .{},
    /// Frames the swapchain refused, and the last image the driver handed out.
    retries: u32 = 0,
    last_image: noapi.Extent2D = .{ .width = 0, .height = 0 },
    managed: *host.ManagedWindow,
    handle: nogui.window_contract.WindowHandle,
    field_owner: *nogui.Model(Field),
    trace: *NativeTrace,
    /// The mounted root view. Its badge is read back after every publication,
    /// so the report states what the App holds rather than what this binary
    /// intended to hold.
    view: *View,
    clipboard_guard: *ClipboardGuard,
    /// The clipboard port the host bound when the window opened, kept so one
    /// section of the headless run can use the real W18 service while the
    /// guard owns the port for everything else.
    host_clipboard: ?text_input.Clipboard = null,
    tick: u32 = 0,
    // SAFETY: the first committed frame supplies field_id before event delivery.
    field_id: nogui.WidgetId = undefined,
    probe: FieldState = .{},
    hold_ms: u64,
    window_open: bool = true,
    /// Optional PPM of the last presented frame's Oklab readback, so the
    /// pixels can be inspected without trusting this report.
    ppm: ?[]const u8 = null,
    /// The controller's line channel, present only under `--requests`. It can
    /// ask for a state readback, ask where this run's own focus targets are,
    /// move the field's scroll and end the run; it cannot inject an event, and
    /// it is null for every other mode.
    requests: ?*Requests = null,
    /// Real compositions and real commits this run received, kept on the run
    /// so a request readback and the closing report count the same numbers.
    compositions: u32 = 0,
    commits: u32 = 0,
    /// Key events the HOST translated and this run routed to the App. It is
    /// the honest count of what arrived at the application on the keyboard:
    /// a key the input method consumed never becomes one of these, so the
    /// difference between this number and the keys a controller sent is the
    /// size of that hole rather than a thing this run could not see.
    keys: u32 = 0,
    /// The focus targets' own rectangles, copied out of the tree the last
    /// PRESENTED frame committed, in the window-logical units the host
    /// translates pointer events into. They are the layout's own numbers: a
    /// controller that pressed anywhere else would be pressing a point it
    /// made up. `focused_target` is the box of the identity the App actually
    /// holds the focus on, so a controller can see whether the keyed `field`
    /// box really IS where its keyboard went instead of assuming it.
    /// Null until a frame has committed them.
    field_target: ?geometry.WindowRect = null,
    other_target: ?geometry.WindowRect = null,
    focused_target: ?geometry.WindowRect = null,

    /// The DISPLAY this process was started on, read out of its own
    /// environment. It is reported by name in every authorized answer so a
    /// readback says which display's clipboard it is talking about.
    display: ?[]const u8 = null,
    /// True only under the exact authorized `--native-clipboard` scope, and
    /// only after the mode has measured the private display's own selections.
    /// Every clipboard verb on the controller's pipe reads this one field, so
    /// an unauthorized run cannot reach a clipboard even by naming a verb.
    clipboard_authorized: bool = false,
    /// The private display's two text selections as they were BEFORE the first
    /// authorized action, OWNED at their measured lengths. The run puts the
    /// clipboard back exactly, on request and again at the end of the
    /// scenario, and writes the primary selection back only when it held
    /// something: a private display is still somebody's display for as long as
    /// it exists, and an absent selection is left absent.
    clipboard_baseline: PrivateSelections = .{},
    /// Authorized actions this run actually performed against the host's own
    /// W18 port. It is printed beside the guard's refusal count so a readback
    /// shows the two paths apart instead of asking anyone to trust that the
    /// real port was the one that answered.
    clipboard_actions: u32 = 0,

    /// True once the private display's CLIPBOARD has been put back through the
    /// host's own port. It is a MEASURED outcome rather than a flag set beside
    /// the call that tried, so a restore that failed is reported as a failed
    /// one. The primary selection is not in it: a selection that held nothing
    /// is never written into, so what it owes that display is nothing at all.
    clipboard_restored: bool = false,

    /// True when a controller's `quit` was answered while this run was still
    /// waiting for a REAL focus. The wait then ends without the "nothing took
    /// the focus" failure, which is a statement about a run nobody is watching
    /// any more rather than about a run that failed.
    requests_quit: bool = false,
    /// Controller lines answered while no target held the focus. It is printed
    /// so a reader can see that the controller had a way to AIM the real press
    /// that brings the focus instead of having to guess a point.
    focus_wait_requests: u32 = 0,

    /// True when the field holds the keyboard, read back out of the App: the
    /// App drops the endpoint on blur, so a non-null focused id IS the field
    /// holding it, and this binary's own bookkeeping is not consulted.
    fn fieldFocused(self: *const Run) bool {
        return self.app.textInputManager().focusedId() != null;
    }

    /// One publication. This is where the App reconciles focus against the
    /// registered endpoint and invalidates cached candidate geometry, so a
    /// frame is how a real application observes both.
    fn frame(self: *Run) !void {
        self.tick += 1;
        const output = try self.app.handle(.{ .frame = .{
            .tick = self.tick,
            .time_ms = self.tick * 16,
        } });
        if (output) |value| {
            if (value.json) |bytes| self.gpa.free(bytes);
        }
        // The tree is rebuilt from the view on every publication, so the badge
        // follows the App's own keyboard ownership instead of this run's.
        self.view.field_holds_keyboard = self.app.textInputManager().focusedId() != null;
    }

    /// One PRESENTED frame for the painting modes: the App's tree, the
    /// field's own scene rects, the Oklab pass, the blit and the present are
    /// ONE event, so a frame this run calls committed is a frame whose pixels
    /// reached the swapchain image. The headless mode calls `frame` instead
    /// and never touches a device.
    ///
    /// A swapchain that is out of date is not a failure: the adapter asks for
    /// the window's real pixel size and the frame is retried, bounded, so a
    /// driver that never settles fails the run instead of spinning.
    fn presentFrame(self: *Run) !void {
        const native = self.native orelse return error.NoNativeSurface;
        const ink_field = self.ink orelse return error.NoShapedField;
        const managed = self.managed;
        const logical: nogui.geometry.WindowSize = .{
            .width = @floatFromInt(managed.observed.size.width),
            .height = @floatFromInt(managed.observed.size.height),
        };
        // The field's box is the shaped field's own, copied in BEFORE the App
        // frame so the clip the view pushes and the box the field paints into
        // are one number, not two that happen to agree.
        if (try ink.state(ink_field)) |current| {
            self.view.field_box = ink.paintBox(current.geometry, ink_field.palette.padding);
        }
        const viewport: frame_api.NativeFrame.Viewport = .{
            .logical = logical,
            .device = try deviceExtent(managed),
            .scale = try managed.observed.pixelScale(),
        };
        var attempts: u32 = 0;
        while (attempts < 8) : (attempts += 1) {
            // SAFETY: beginFrame fills surface_frame before recording or cancellation.
            var surface_frame: frame_api.NativeFrame.Frame = undefined;
            if (!try native.adapter.beginFrame(&native.surface, viewport, &surface_frame)) {
                self.retries += 1;
                continue;
            }
            var recording = true;
            errdefer if (recording) native.adapter.cancelFrame(&surface_frame) catch
                @panic("surface recording cancellation failed");
            const time_ms = sdl3.timer.getMillisecondsSinceInit();
            self.app.dispatchRootFrame(time_ms);
            const out = try self.app.frameWithGpuAtTime(
                self.tick + 1,
                time_ms,
                .{ .width = logical.width, .height = logical.height },
                &surface_frame.gpu_frame,
            );
            defer if (out.json) |json| self.gpa.free(json);
            self.tick += 1;
            // Out of the tree THIS frame committed, before the next frame
            // attempt may reset its arena: where this run's own focus targets
            // are, in the units a pointer event arrives in.
            self.recordTargets(out.tree);
            var frame_paint = try native.adapter.buildScene(.{}, &out);
            defer frame_paint.deinit();
            // The field's own rects join the same lowering, above the tree,
            // and carry the clip the view pushed for the field's box.
            self.painted = try ink_field.paint(&native.adapter.sceneScratch().rects, .{
                .focused = self.fieldFocused(),
                .clip = self.view.field_clip,
            });
            try native.adapter.recordScene(&native.surface, &surface_frame, &out, &frame_paint);
            // `present` closes the recording itself, so the guard is dropped
            // BEFORE the call: a present that fails must propagate its own
            // error, not reach a cancellation of a recording that is gone.
            recording = false;
            try native.adapter.present(&native.surface, &surface_frame);
            self.last_image = surface_frame.image;
            self.view.field_holds_keyboard = self.app.textInputManager().focusedId() != null;
            managed.markPresented();
            return;
        }
        return error.SwapchainNeverSettled;
    }

    /// Where this run's two focus targets are, read out of the tree the last
    /// presented frame committed. This is a MEASUREMENT of the layout, not a
    /// request to move anything: nothing here dispatches an event, and a
    /// controller that wants a real pointer press asks for these numbers and
    /// sends the press itself through the display.
    fn recordTargets(self: *Run, tree: *const nogui.widget.WidgetTree) void {
        self.field_target = targetRect(self.app, tree, "field");
        self.other_target = targetRect(self.app, tree, "other");
        self.focused_target = widgetRect(tree, self.app.focus_manager.current);
    }

    /// One step of a painting run: present a frame, re-bind the endpoint if
    /// focus round-tripped, publish the candidate rectangle the endpoint now
    /// reports, and mirror the field's own state into the view.
    fn nativeStep(self: *Run, label: []const u8) !void {
        try self.presentFrame();
        self.rebindIfFocused();
        if (self.app.textInputManager().focusedId() != null) {
            if (try self.publishCaret()) |caret| {
                if (caret.area.h <= 0) return error.CandidateAreaWithoutHeight;
            }
        }
        try self.noteInkGeometry(label);
    }

    /// Pixels the presented passes actually wrote, counted in the Oklab
    /// readback of this run's own target: a pixel is INKED when its Lab triple
    /// differs from the scene's clear colour by more than the antialiasing
    /// noise floor. This is readback, not a re-render and not a model read.
    fn countInked(self: *Run, native: *Native) !struct { total: u32, inside_field: u32 } {
        const pixels = try native.adapter.readTarget();
        const extent = native.adapter.targetExtent();
        const box = self.view.field_box;
        const scale_x = @as(f32, @floatFromInt(extent.width)) /
            @as(f32, @floatFromInt(self.managed.observed.size.width));
        const scale_y = @as(f32, @floatFromInt(extent.height)) /
            @as(f32, @floatFromInt(self.managed.observed.size.height));
        var total: u32 = 0;
        var inside: u32 = 0;
        for (0..extent.height) |y| {
            for (0..extent.width) |x| {
                const at = (y * extent.width + x) * 4;
                if (@abs(pixels[at] - frame_api.scene.oklab_clear[0]) < 0.004 and
                    @abs(pixels[at + 1] - frame_api.scene.oklab_clear[1]) < 0.004 and
                    @abs(pixels[at + 2] - frame_api.scene.oklab_clear[2]) < 0.004) continue;
                total += 1;
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                if (px >= box.x * scale_x and px <= (box.x + box.w) * scale_x and
                    py >= box.y * scale_y and py <= (box.y + box.h) * scale_y) inside += 1;
            }
        }
        return .{ .total = total, .inside_field = inside };
    }

    /// Write the last presented frame's Oklab readback as a P6 PPM, so the
    /// pixels can be inspected without believing this binary's own report. It
    /// is the SAME buffer `countInked` measured, not a second render.
    fn writePpm(self: *Run, native: *Native, path: []const u8) !void {
        const pixels = try native.adapter.readTarget();
        try frame_api.writePpm(self.gpa, self.report.io, path, pixels, native.adapter.targetExtent());
    }

    /// Push one raw SDL event through the host exactly as an event loop does,
    /// and hand the translated core event to the App.
    fn route(self: *Run, raw: *const sdl3.events.Event) !?nogui.Event {
        const host_event = (try self.application.dispatch(raw)) orelse return null;
        const routed = switch (host_event) {
            .window => |value| value,
            .drop => return null,
            .display, .system_wake => return null,
        };
        if (!std.meta.eql(routed.handle, self.handle)) return null;
        return switch (routed.translated orelse return null) {
            .close => null,
            .resize => |resize| resize.core,
            .input => |event| event,
            .key_down => |key| key.core,
        };
    }

    /// `true` when the event reached the App. `false` means the host dropped
    /// it, which several checks below treat as the observation it is.
    fn deliver(self: *Run, raw: *const sdl3.events.Event) !bool {
        const core = (try self.route(raw)) orelse return false;
        _ = try self.app.handle(core);
        return true;
    }

    fn field(self: *Run) !FieldState {
        self.probe = .{};
        try self.session.read(Field, self.field_owner.*, &self.probe, FieldState.read);
        return self.probe;
    }

    fn setScroll(self: *Run, lines: usize) !void {
        var request: SetScroll = .{ .lines = lines };
        try self.session.update(Field, self.field_owner.*, &request, SetScroll.apply);
    }

    /// Select a UTF-16 range in the model, the way a pointer press over the
    /// field would.
    fn select(self: *Run, range: Utf16Range) !void {
        var request: SetSelection = .{ .range = range };
        try self.session.update(Field, self.field_owner.*, &request, SetSelection.apply);
    }

    /// Focus the field. This is the only thing that starts native text input:
    /// the App refuses an endpoint whose identity is not the focused widget.
    fn registerField(self: *Run) void {
        self.app.registerTextEndpoint(.{
            .id = self.field_id,
            .owner = self.field_owner.weak().erase(),
            .ops = fieldOps(),
            .user = self,
        });
    }

    /// Register the field this mode actually has. The headless mode's geometry
    /// is the synthetic grid above; the interactive mode's is the shared W11
    /// layout. Registering the wrong one would publish a rectangle that does
    /// not match the field it belongs to.
    fn registerEndpoint(self: *Run) void {
        if (self.ink) |ink_field| {
            self.app.registerTextEndpoint(ink_field.endpoint(self.field_id));
            return;
        }
        self.registerField();
    }

    /// The candidate rectangle the endpoint currently reports, published to SDL
    /// through the host port exactly as a real composition would publish it.
    fn publishCaret(self: *Run) !?text_input.Caret {
        return self.app.textInputManager().caretGeometry();
    }

    fn noteCaret(self: *Run, label: []const u8) !void {
        const caret = (try self.publishCaret()) orelse {
            self.report.emit("caret {s}: none (no rectangle published)\n", .{label});
            return;
        };
        const pixels = host.Window.candidateArea(caret.area);
        self.report.emit(
            "caret {s}: area=({d:.1},{d:.1} {d:.1}x{d:.1}) cursor={d:.1}" ++
                " sdl_rect=({d},{d} {d}x{d}) published={d}\n",
            .{
                label,
                caret.area.x,
                caret.area.y,
                caret.area.w,
                caret.area.h,
                caret.cursor,
                pixels.x,
                pixels.y,
                pixels.w,
                pixels.h,
                self.trace.areas,
            },
        );
    }

    /// Compare the native candidate with the field's painted caret geometry,
    /// then mirror its state into the view's label.
    fn noteInkGeometry(self: *Run, label: []const u8) !void {
        const ink_field = self.ink orelse return;
        var measured = (try ink.measure(ink_field)) orelse return;
        defer measured.deinit(self.gpa);
        if (self.fieldFocused()) {
            const published = try self.publishCaret();
            if (measured.caret) |expected| {
                const actual = published orelse return error.PaintedCaretWithoutCandidate;
                if (!std.meta.eql(expected, actual.area)) return error.CandidateDiffersFromPaintedCaret;
                if (self.managed.native.textInputActive()) {
                    const stored = try sdl3.keyboard.getTextInputArea(self.managed.native.sdl);
                    if (!std.meta.eql(stored[0], host.Window.candidateArea(actual.area)) or
                        stored[1] != host.Window.candidateCursor(actual.cursor))
                    {
                        return error.NativeCandidateDiffersFromPublishedCaret;
                    }
                }
            } else if (published != null) {
                return error.CandidateForUnpaintedCaret;
            }
        }
        var caret_buffer: [64]u8 = undefined;
        var sdl_buffer: [64]u8 = undefined;
        self.report.emit(
            "field {s}: lines={d} text=\"{s}\" marked={any} caret_unit={d}\n" ++
                "  caret_rect={s} sdl_rect={s} preedit_boxes={d}\n",
            .{
                label,
                measured.state.lines,
                measured.state.text(),
                measured.state.marked,
                measured.state.selection.cursor(),
                rectText(&caret_buffer, measured.caret),
                sdlRectText(&sdl_buffer, measured.caret),
                measured.preedit.len,
            },
        );
        const text = std.fmt.bufPrint(self.view.status[0..], "lines {d} bytes {d}{s} caret {d}", .{
            measured.state.lines,
            measured.state.text().len,
            if (measured.state.marked == null) "" else " [preedit]",
            measured.state.selection.cursor(),
        }) catch return error.StatusTooLongForView;
        self.view.status_len = text.len;
    }

    /// Re-bind after a focus round trip. Focus loss drops the endpoint and
    /// stops native text input, exactly as it does for any consumer, so a
    /// field that takes focus again has to bind itself again.
    fn rebindIfFocused(self: *Run) void {
        if (self.app.textInputManager().focusedId() != null) return;
        const current = self.app.focus_manager.current orelse return;
        if (!current.eql(self.field_id)) return;
        self.registerEndpoint();
    }

    /// Wait for a REAL key or a REAL click to give some target the focus.
    ///
    /// This pumps the same loop the rest of the interactive run uses, so the
    /// event that focuses is dispatched by the host exactly as any other is.
    /// Nothing is pushed into SDL and no focus is assumed; the wait ends when
    /// the App itself names a target, or when the caller runs out of time. The
    /// identity is recorded BEFORE the next publication, so nothing can
    /// compare against an unset field identity on the way there.
    ///
    /// In the AUTHORIZED clipboard mode the controller's pipe is served here as
    /// well, and that is not a convenience: a controller cannot move the
    /// keyboard's focus with a key while this process owns it (see
    /// `ackTargets`), so it has to aim a REAL pointer press at one of this
    /// run's own controls — and that press is the very event this wait is
    /// blocked on. The read-only verbs answer out of the frames this loop
    /// presents, so a controller can learn where to press; nothing is focused,
    /// assumed or fabricated to answer them. Every other mode leaves this wait
    /// exactly as it was, so the interactive IME acceptance is never served a
    /// line it did not ask for in a run that did not ask for this mode.
    fn focusFromOutside(self: *Run, timeout_ms: u64) !?nogui.WidgetId {
        const deadline = sdl3.timer.getMillisecondsSinceInit() + timeout_ms;
        while (sdl3.timer.getMillisecondsSinceInit() < deadline) {
            if (self.app.focus_manager.current) |target| return target;
            if (self.clipboard_authorized) {
                if (self.requests) |requests| {
                    if (try requests.poll()) {
                        if (!try self.serveFocusWaitRequest(requests.take())) {
                            self.requests_quit = true;
                            return null;
                        }
                    }
                }
            }
            if (self.application.pollEvent()) |raw| {
                if (try self.route(&raw)) |core| {
                    // Counted here as well as in the hold loop: a key that
                    // arrives BEFORE anything is focused is the whole reason
                    // the same key cannot move the focus once text input is
                    // active, so the number has to cover both halves of the
                    // run to be worth reading.
                    switch (core) {
                        .key_down => self.keys += 1,
                        else => {},
                    }
                    _ = try self.app.handle(core);
                }
                if (self.app.focus_manager.current) |target| {
                    self.field_id = target;
                    return target;
                }
            }
            try self.nativeStep("await-focus");
            try Io.sleep(self.report.io, Io.Duration.fromMilliseconds(8), .real);
        }
        return self.app.focus_manager.current;
    }

    /// Which widget the App itself names. `field` is this run's field, and
    /// anything else is the second focus target or nothing at all. Both
    /// answers are read out of the App, never out of this binary's own
    /// bookkeeping.
    fn focusName(self: *Run, id: ?nogui.WidgetId) []const u8 {
        const current = id orelse return "none";
        return if (current.eql(self.field_id)) "field" else "other";
    }

    /// The rectangle SDL ITSELF is holding for this window right now. This is
    /// the anchor an input method would use, read back from the platform
    /// rather than from this binary's account of it. It is not a candidate
    /// window: nothing has been observed to open one.
    fn sdlStoredText(self: *Run, buffer: []u8) []const u8 {
        if (!self.managed.native.textInputActive()) return "<inactive>";
        const stored = sdl3.keyboard.getTextInputArea(self.managed.native.sdl) catch {
            return "<unreadable>";
        };
        return std.fmt.bufPrint(buffer, "({d},{d} {d}x{d})@{d}", .{
            stored[0].x, stored[0].y, stored[0].w, stored[0].h, stored[1],
        }) catch "<rect>";
    }

    /// This window's own position and size, read back from SDL. The rectangle
    /// SDL is holding for text input is in WINDOW coordinates, and an input
    /// method places a candidate window at that rectangle PLUS this origin,
    /// so the origin is what turns the stored rectangle into an anchor on the
    /// display at all. It is read here rather than derived, because the window
    /// a window manager decorated and the client area SDL measures are not the
    /// same rectangle, and only SDL knows which one its own stored rectangle is
    /// relative to. A controller that guesses it guesses wrong in silence.
    fn windowRectText(self: *Run, buffer: []u8) []const u8 {
        const origin = self.managed.native.sdl.getPosition() catch return "<unreadable>";
        const extent = self.managed.native.sdl.getSize() catch return "<unreadable>";
        return std.fmt.bufPrint(buffer, "({d},{d} {d}x{d})", .{
            origin[0],
            origin[1],
            extent[0],
            extent[1],
        }) catch "<rect>";
    }

    /// Glyphs the pinned face cannot shape, counted out of the ONE layout the
    /// field painted from. Every report below prints the model's own bytes, so
    /// a composition this face has no glyph for has to be named as unpainted
    /// instead of being left to read as rendered text.
    fn glyphCounts(self: *Run) struct { total: u32, missing: u32 } {
        const ink_field = self.ink orelse return .{ .total = 0, .missing = 0 };
        const shaped = ink_field.shaped orelse return .{ .total = 0, .missing = 0 };
        var total: u32 = 0;
        var missing: u32 = 0;
        for (shaped.layout.runs) |run| {
            const count: u32 = @intCast(run.glyphs.len);
            total += count;
            if (run.missing_glyph) missing += count;
        }
        return .{ .total = total, .missing = missing };
    }

    /// The model's own bytes as hex. A multibyte commit is only provable at byte
    /// level, and a raw byte string would put a newline out of a pasted commit
    /// into the middle of one report line.
    fn hexBytes(out: []u8, bytes: []const u8) []const u8 {
        const digits = "0123456789abcdef";
        const count = @min(bytes.len, out.len / 2);
        for (bytes[0..count], 0..) |byte, at| {
            out[at * 2] = digits[byte >> 4];
            out[at * 2 + 1] = digits[byte & 0x0f];
        }
        return out[0 .. count * 2];
    }

    /// One machine-readable line of readback. Every value in it is measured:
    /// the App's focus and keyboard ownership, the endpoint's rectangle, SDL's
    /// own stored rectangle, the presented scene's counters and the model's
    /// bytes. Nothing here is a claim about what a request intended to do.
    fn ackState(self: *Run, areas_before_request: u64) !void {
        const native = self.native orelse return error.NoNativeSurface;
        const ink_field = self.ink orelse return error.NoShapedField;
        var measured = (try ink.measure(ink_field)) orelse return error.FieldModelReleased;
        defer measured.deinit(self.gpa);
        const published = try self.publishCaret();
        const glyphs = self.glyphCounts();
        // MEASURED here, from the host's own observed extents, rather than
        // read out of the platform a second time. It is the same division the
        // renderer measures against, so the rectangle printed beside it and
        // the scale printed beside that are two numbers a controller can
        // actually check against each other.
        const observed = try self.managed.observed.pixelScale();
        var caret_buffer: [64]u8 = undefined;
        var sdl_buffer: [64]u8 = undefined;
        var stored_buffer: [64]u8 = undefined;
        var window_buffer: [64]u8 = undefined;
        var first_buffer: [64]u8 = undefined;
        var last_buffer: [64]u8 = undefined;
        var marked_buffer: [32]u8 = undefined;
        var selection_buffer: [32]u8 = undefined;
        var byte_buffer: [1024]u8 = undefined;
        // The scale this window is DRAWN at beside the scale this run
        // MEASURED from its own two extents. Both are printed because on a
        // backend that reports a display scale and hands the window 1:1
        // pixels the two are different numbers, and a candidate rectangle
        // read against the wrong one looks correct against the right one.
        var scale_buffer: [96]u8 = undefined;
        const scale_text = std.fmt.bufPrint(&scale_buffer, "{d:.4}x{d:.4}@{d:.4}({d}x{d})", .{
            self.managed.observed.display_scale,
            observed.x,
            observed.y,
            self.managed.observed.pixels.width,
            self.managed.observed.pixels.height,
        }) catch "<scale>";
        self.report.emit(
            "ack state focus={s} keyboard={s} text_input_active={} starts={d} stops={d}" ++
                " clears={d} areas={d} areas_before_request={d}" ++
                " compositions={d} commits={d} keys={d} caret_unit={d}" ++
                " selection={s}" ++
                " caret_rect={s} sdl_rect={s} sdl_stored={s} window={s} preedit_boxes={d}" ++
                " scale={s} preedit_first={s} preedit_last={s} lines={d} scroll_px={d:.1}" ++
                " glyphs={d} missing_glyphs={d} painted_rects={d} painted_glyphs={d}" ++
                " painted_preedit={d} painted_caret={} frames_presented={d}" ++
                " marked={s} bytes={s}\n",
            .{
                self.focusName(self.app.focus_manager.current),
                self.focusName(self.app.textInputManager().focusedId()),
                self.managed.native.textInputActive(),
                self.trace.starts,
                self.trace.stops,
                self.trace.clears,
                self.trace.areas,
                areas_before_request,
                self.compositions,
                self.commits,
                // How many key events reached the App at all. A controller
                // that pressed keys this number did not grow sent them to an
                // input method, not to this application.
                self.keys,
                measured.state.selection.cursor(),
                // The whole selection, in the same document units as
                // `caret_unit` and `marked`. `caret_unit` alone cannot say
                // whether a commit collapsed the selection or left a range
                // behind it, because a range has a cursor too.
                std.fmt.bufPrint(&selection_buffer, "{d}:{d}", .{
                    measured.state.selection.range.start,
                    measured.state.selection.range.end,
                }) catch "<range>",
                rectText(&caret_buffer, if (published) |caret| caret.area else measured.caret),
                sdlRectText(&sdl_buffer, if (published) |caret| caret.area else measured.caret),
                self.sdlStoredText(&stored_buffer),
                self.windowRectText(&window_buffer),
                measured.preedit.len,
                // The whole scale story as ONE token, because this report is
                // already at Zig's 32-argument format ceiling and a controller
                // parses exactly one line per request, so it cannot be split
                // across two. It is formatted here rather than inline so the
                // line stays parseable and the measurement is still whole.
                scale_text,
                rectText(&first_buffer, if (measured.preedit.len == 0) null else measured.preedit[0]),
                rectText(&last_buffer, if (measured.preedit.len == 0)
                    null
                else
                    measured.preedit[measured.preedit.len - 1]),
                measured.state.lines,
                measured.state.geometry.scroll_px,
                glyphs.total,
                glyphs.missing,
                self.painted.rects,
                self.painted.glyphs,
                self.painted.preedit,
                self.painted.caret,
                native.adapter.stats.frames_presented,
                if (measured.state.marked) |marked|
                    std.fmt.bufPrint(&marked_buffer, "{d}:{d}", .{ marked.start, marked.end }) catch "<range>"
                else
                    "none",
                hexBytes(&byte_buffer, measured.state.text()),
            },
        );
    }

    /// Where this run's two focus targets are, in this window's own logical
    /// units, beside this window's own origin on the display. Both come from
    /// the frame the request presents first, so they describe the layout the
    /// controller is about to press on and not the one it saw last time.
    ///
    /// A controller that has to move the keyboard's focus while this process
    /// owns the keyboard CANNOT reach it with a key: while the field holds it,
    /// SDL hands every key to the input method (see the module's own note on
    /// the key route), so the answer is a real pointer press on a real
    /// control, and the numbers for it are read here rather than guessed.
    fn ackTargets(self: *Run) !void {
        try self.nativeStep("targets");
        var field_buffer: [64]u8 = undefined;
        var other_buffer: [64]u8 = undefined;
        var focused_buffer: [64]u8 = undefined;
        var window_buffer: [64]u8 = undefined;
        self.report.emit(
            "ack targets field={s} other={s} focused={s} window={s} focus={s}\n",
            .{
                rectText(&field_buffer, self.field_target),
                rectText(&other_buffer, self.other_target),
                rectText(&focused_buffer, self.focused_target),
                self.windowRectText(&window_buffer),
                self.focusName(self.app.focus_manager.current),
            },
        );
    }

    /// Refuse a clipboard verb by name when this run was not authorized for
    /// one. The refusal names the flag that would authorize it, so a
    /// controller that sent the wrong thing is told what was MISSING instead
    /// of being handed a bare "unavailable" it could not tell apart from a
    /// platform with no clipboard.
    fn refuseUnauthorizedClipboard(self: *Run, verb: []const u8) bool {
        if (self.clipboard_authorized) return false;
        self.report.emit(
            "ack err=clipboard_not_authorized verb={s} scope={s}\n",
            .{ verb, Options.native_clipboard_scope },
        );
        return true;
    }

    /// Run one shared W18 edit action against the port the HOST bound, with the
    /// refusing guard back in the port before this returns.
    ///
    /// The guard is not switched off for the authorized mode; it is swapped out
    /// for the length of one call and swapped straight back. So a key event, a
    /// composition or a focus round trip that reaches the port while this run is
    /// NOT inside one of these calls is still refused and still counted, which
    /// is the difference between a scope and a switch.
    fn withHostClipboard(
        self: *Run,
        comptime action: fn (*text_input.Manager) anyerror!text_input.EditOutcome,
    ) !text_input.EditOutcome {
        const manager = self.app.textInputManager();
        const real = self.host_clipboard orelse return error.HostDidNotBindClipboard;
        const guard = self.clipboard_guard.port();
        manager.clipboard = real;
        defer manager.clipboard = guard;
        return action(manager);
    }

    /// One authorized action, answered with everything a controller needs to
    /// decide whether it did what it names: the shared service's OWN outcome
    /// tag, the bytes it moved, the model's own replacement and mark counters,
    /// the selection it left behind and the model's bytes in hex.
    ///
    /// There is NO field here that names the port which answered, and that is
    /// deliberate. Only this emitter's caller can reach it, and that caller
    /// has just run the shared action with the host's own port swapped in, so
    /// a token printed here would be a constant beside its own print statement
    /// and could only ever be checked against itself. What a readback gets
    /// instead are the two counts beside it: `actions=` is how many authorized
    /// actions have run against the host's port in this process, and `guard=`
    /// is the refusing guard's OWN refusal count, which the run fails on when it
    /// is not zero. Which port served a given answer is therefore shown by
    /// what the answer CONTAINS — a paste whose bytes another process wrote and
    /// a copy another process read back — and not asserted by a word.
    ///
    /// `state` is a POINTER to whichever model this run's endpoint is really
    /// bound to: the shaped field's own model in the painting modes, the fixed
    /// grid above in the headless one. Both publish the same fields, so the
    /// answer is the same shape either way, and answering out of the wrong one
    /// would report bytes the endpoint never saw.
    fn emitClipboardAck(
        self: *Run,
        verb: []const u8,
        outcome: text_input.EditOutcome,
        state: anytype,
    ) void {
        var selection_buffer: [32]u8 = undefined;
        var marked_buffer: [32]u8 = undefined;
        var byte_buffer: [1024]u8 = undefined;
        self.report.emit(
            "ack clipboard verb={s} outcome={s} bytes={d} replaces={d} marks={d}" ++
                " selection={s} marked={s} model={s} actions={d} guard={d} display={s}\n",
            .{
                verb,
                @tagName(outcome),
                outcomeBytes(outcome),
                state.replacements,
                state.marks,
                std.fmt.bufPrint(&selection_buffer, "{d}:{d}", .{
                    state.selection.range.start,
                    state.selection.range.end,
                }) catch "<range>",
                if (state.marked) |marked|
                    std.fmt.bufPrint(&marked_buffer, "{d}:{d}", .{ marked.start, marked.end }) catch "<range>"
                else
                    "none",
                hexBytes(&byte_buffer, state.text()),
                self.clipboard_actions,
                self.clipboard_guard.attempts,
                self.display orelse "<unset>",
            },
        );
    }

    /// `copy`, `cut` and `paste`, on the controller's pipe and ONLY under the
    /// authorized scope. Each is the shared service's own action: this run
    /// implements no clipboard of its own and reaches no platform call that the
    /// service would not have made itself.
    fn serveClipboardAction(self: *Run, verb: []const u8) !bool {
        if (self.refuseUnauthorizedClipboard(verb)) return true;
        const outcome = if (std.mem.eql(u8, verb, "copy"))
            try self.withHostClipboard(copyAction)
        else if (std.mem.eql(u8, verb, "cut"))
            try self.withHostClipboard(cutAction)
        else
            try self.withHostClipboard(pasteAction);
        self.clipboard_actions += 1;
        // The frame the controller looks at next is presented AFTER the action,
        // so the pixels it inspects and the bytes in this answer are the same
        // model state rather than two frames apart.
        try self.nativeStep("clipboard");
        if (self.ink) |ink_field| {
            var measured = (try ink.measure(ink_field)) orelse return error.FieldModelReleased;
            defer measured.deinit(self.gpa);
            self.emitClipboardAck(verb, outcome, &measured.state);
        } else {
            const state = try self.field();
            self.emitClipboardAck(verb, outcome, &state);
        }
        return true;
    }

    /// One of the private display's own text selections, read back as hex
    /// BESIDE its own byte count. A restore that is only CLAIMED is not a
    /// restore, so every answer about a selection names what the platform holds
    /// afterwards rather than what was asked for, and a hex this line had to
    /// clip shows up as a count that does not match it rather than as a short
    /// answer that reads complete.
    ///
    /// A selection the platform reports as holding nothing is `<absent>` and
    /// one it cannot report at all is `<unreadable>`: those are different
    /// states, and naming one of them the other is the guess this mode exists
    /// to avoid.
    fn selectionReadback(self: *Run, out: []u8, primary: bool) struct { hex: []const u8, bytes: usize } {
        const read: anyerror!?[]u8 = if (primary)
            (host.clipboard.getPrimaryText(self.gpa))
        else
            (host.clipboard.readText(self.gpa));
        const answer = read catch return .{ .hex = "<unreadable>", .bytes = 0 };
        const owned = answer orelse return .{ .hex = "<absent>", .bytes = 0 };
        defer self.gpa.free(owned);
        return .{ .hex = hexBytes(out, owned), .bytes = owned.len };
    }

    /// Measure the private display's two text selections, once, before any
    /// authorized action is allowed to touch either one.
    fn capturePrivateBaseline(self: *Run) !void {
        // It deliberately does NOT set `clipboard_authorized`: that flag is the
        // scope `parseOptions` already accepted, and a second place that could
        // raise it would be a second way in.
        try self.clipboard_baseline.capture(self.gpa);
    }

    /// Put the private display's selections back through the host's own W18
    /// port. This runs at the end of the authorized scenario whether or not a
    /// controller asked for it: the mode reached out to a display, so it owes
    /// that display its own state back, and a controller that never got to ask
    /// is not a reason to leave an offer behind.
    fn restorePrivateSelections(self: *Run) !void {
        // The restore writes through the host's OWN port directly, so the
        // manager's port is never consulted here and is left holding the
        // refusing guard exactly as it does everywhere else in this run.
        const real = self.host_clipboard orelse return error.HostDidNotBindClipboard;
        try self.clipboard_baseline.restore(self.gpa, real);
    }

    /// `clipboard-restore`, answered with what each selection HOLDS after it,
    /// what it HELD before the first authorized action, and — for the primary
    /// selection — whether this run wrote into it at all. An absent primary is
    /// left alone rather than set to an empty string, so `primary_written`
    /// says false and the readback beside it is the untouched state, not a
    /// restore that took the selection over and left it empty.
    fn serveClipboardRestore(self: *Run) !bool {
        if (self.refuseUnauthorizedClipboard("clipboard-restore")) return true;
        var clipboard_buffer: [1024]u8 = undefined;
        var primary_buffer: [1024]u8 = undefined;
        const failure: ?anyerror = if (self.restorePrivateSelections()) |_| null else |err| err;
        const clipboard_after = self.selectionReadback(&clipboard_buffer, false);
        const primary_after = self.selectionReadback(&primary_buffer, true);
        self.report.emit(
            "ack clipboard verb=clipboard-restore result={s} clipboard={s} clipboard_bytes={d}" ++
                " was_present={} was_bytes={d} primary={s} primary_bytes={d}" ++
                " primary_was_present={} primary_was_bytes={d} primary_written={}" ++
                " primary_readable={} display={s}\n",
            .{
                if (failure) |err| @errorName(err) else "ok",
                clipboard_after.hex,
                clipboard_after.bytes,
                self.clipboard_baseline.clipboard_present,
                self.clipboard_baseline.clipboardBytes(),
                primary_after.hex,
                primary_after.bytes,
                self.clipboard_baseline.primary_present,
                self.clipboard_baseline.primaryBytes(),
                self.clipboard_baseline.primary_written,
                self.clipboard_baseline.primary_readable,
                self.display orelse "<unset>",
            },
        );
        return true;
    }

    /// Serve one controller line. It is a CONTROL and never an event: the only
    /// inputs it can change are the field's scroll and whether the run keeps
    /// going. Everything else it can ask for is a readback of what the App,
    /// the layout or SDL already holds. It builds nothing, routes nothing and
    /// pushes nothing into SDL, so no request can produce a composition the
    /// report would then call real. `false` ends the interactive loop.
    fn serveRequest(self: *Run, line: []const u8) !bool {
        const areas_before_request = self.trace.areas;
        var args = std.mem.tokenizeAny(u8, line, " \t");
        const verb = args.next() orelse {
            self.report.emit("ack err=empty\n", .{});
            return true;
        };
        if (std.mem.eql(u8, verb, "state")) {
            // A readback has to describe the frame a controller is about to
            // look at, so one frame is presented first and every number below
            // is taken after it.
            try self.nativeStep("state");
            try self.ackState(areas_before_request);
            return true;
        }
        if (std.mem.eql(u8, verb, "targets")) {
            try self.ackTargets();
            return true;
        }
        if (std.mem.eql(u8, verb, "scroll")) {
            const raw = args.next() orelse {
                self.report.emit("ack err=scroll_needs_lines\n", .{});
                return true;
            };
            const lines = std.fmt.parseInt(usize, raw, 10) catch {
                self.report.emit("ack err=scroll_needs_lines\n", .{});
                return true;
            };
            const ink_field = self.ink orelse return error.NoShapedField;
            try ink_field.setScroll(@as(f32, @floatFromInt(lines)) * ink.line_height);
            try self.nativeStep("scroll");
            try self.ackState(areas_before_request);
            return true;
        }
        if (std.mem.eql(u8, verb, "copy") or
            std.mem.eql(u8, verb, "cut") or
            std.mem.eql(u8, verb, "paste"))
        {
            return self.serveClipboardAction(verb);
        }
        if (std.mem.eql(u8, verb, "clipboard-restore")) {
            return self.serveClipboardRestore();
        }
        if (std.mem.eql(u8, verb, "quit")) {
            self.report.emit("ack quit\n", .{});
            return false;
        }
        self.report.emit("ack err=unknown_verb\n", .{});
        return true;
    }

    /// One controller line served while this run is still WAITING for a real
    /// focus, and only in the authorized clipboard mode.
    ///
    /// A controller that has to move the keyboard's focus cannot do it with a
    /// key (see `ackTargets`), so it needs this run's own focus targets to aim
    /// a REAL pointer press at — and that press is the event this wait is
    /// blocked on. So the READ-ONLY verbs are answered here, out of the frames
    /// this loop presents: `targets` names the rectangles to press on, `state`
    /// reports what the App holds so far, `clipboard-restore` puts the private
    /// display back even for a run that never got as far as a key, and `quit`
    /// ends the run cleanly.
    ///
    /// Nothing else is answered, because nothing else means anything before a
    /// target holds the keyboard: `copy`, `cut` and `paste` would run shared
    /// actions against a field nothing has focused, and `scroll` would move a
    /// field no controller has selected anything in. Each refuses BY NAME
    /// instead of being left unanswered, so a controller waits for an answer
    /// and gets one. `false` ends the run, exactly as in `serveRequest`.
    fn serveFocusWaitRequest(self: *Run, line: []const u8) !bool {
        const areas_before_request = self.trace.areas;
        var args = std.mem.tokenizeAny(u8, line, " \t");
        const verb = args.next() orelse {
            self.report.emit("ack err=empty\n", .{});
            return true;
        };
        self.focus_wait_requests += 1;
        if (std.mem.eql(u8, verb, "state")) {
            try self.nativeStep("state");
            try self.ackState(areas_before_request);
            return true;
        }
        if (std.mem.eql(u8, verb, "targets")) {
            try self.ackTargets();
            return true;
        }
        if (std.mem.eql(u8, verb, "clipboard-restore")) {
            return self.serveClipboardRestore();
        }
        if (std.mem.eql(u8, verb, "quit")) {
            self.report.emit("ack quit\n", .{});
            return false;
        }
        if (std.mem.eql(u8, verb, "copy") or
            std.mem.eql(u8, verb, "cut") or
            std.mem.eql(u8, verb, "paste") or
            std.mem.eql(u8, verb, "scroll"))
        {
            self.report.emit(
                "ack err=needs_focused_target verb={s} focus=none served_while_waiting={d}\n",
                .{ verb, self.focus_wait_requests },
            );
            return true;
        }
        self.report.emit("ack err=unknown_verb\n", .{});
        return true;
    }

    /// Give the measured baseline's owned bytes back. It runs after the
    /// scenario in every outcome, so a run that refused half way through still
    /// releases what it copied out of the display.
    fn releaseClipboardBaseline(self: *Run) void {
        self.clipboard_baseline.deinit();
    }

    /// Close the window. The host retires the session window, cancels any open
    /// composition, stops native text input and detaches the ports, so this
    /// runs before the App and the field model are destroyed.
    fn teardown(self: *Run) void {
        if (!self.window_open) return;
        self.window_open = false;
        _ = self.application.closeWindow(self.handle) catch |err| {
            self.report.emit("teardown: closeWindow failed: {s}\n", .{@errorName(err)});
        };
    }
};

/// The three shared W18 edit actions, named as plain functions so a caller
/// installs the host's port around a CALL rather than around a copy of the
/// manager: `Manager.copy`/`cut`/`paste` are the only clipboard code on this
/// path, and this file adds none.
fn copyAction(manager: *text_input.Manager) anyerror!text_input.EditOutcome {
    return manager.copy();
}

fn cutAction(manager: *text_input.Manager) anyerror!text_input.EditOutcome {
    return manager.cut();
}

fn pasteAction(manager: *text_input.Manager) anyerror!text_input.EditOutcome {
    return manager.paste();
}

/// A SPIR-V module read from the build's `shaders/` directory, the same
/// source the demo pipeline and the other smokes read. The bytes stay owned
/// for as long as `NativeFrame.init` and `Renderer.init` need them.
const Spv = struct {
    bytes: []u8,
    words: []const u32,

    fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) !Spv {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        if (bytes.len == 0 or bytes.len % @sizeOf(u32) != 0) {
            gpa.free(bytes);
            return error.ShaderModuleMalformed;
        }
        return .{ .bytes = bytes, .words = @alignCast(std.mem.bytesAsSlice(u32, bytes)) };
    }

    fn deinit(self: *Spv, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// The Vulkan instance extensions the platform asked for. The loader reads
/// this through the function pointer below while `Gpu.init` builds the
/// instance, and not after, so the storage is released as soon as it returns.
var vulkan_extensions: [][*:0]const u8 = &.{};

fn instanceExtensions() []const [*:0]const u8 {
    return vulkan_extensions;
}

/// The native half of a painting run: the device, the surface that presents
/// into the real window, and the public frame adapter that owns the text
/// engine, the renderer and the blit.
///
/// TEARDOWN ORDER, which the caller owns and which is why this is one value
/// with one `deinit`: the App detaches from the endpoint, then the field
/// model and the adapter go, then the surface, then the device, and only then
/// does SDL quit. Quitting SDL unloads the Vulkan loader, and a live device
/// would then dispatch through an unmapped page.
const Native = struct {
    gpu: noapi.Gpu,
    /// The window's own platform surface, created and ADOPTED inside noapi
    /// from the native window and SDL's constructor. This binary holds no
    /// Vulkan instance or surface handle: `Surface.deinit` destroys the
    /// surface with `vkDestroySurfaceKHR`, and no second owner exists.
    surface: noapi.Surface,
    adapter: frame_api.NativeFrame,
    /// The five SPIR-V modules the pipeline records with.
    quad_vert: Spv,
    quad_frag: Spv,
    sort_comp: Spv,
    fullscreen_vert: Spv,
    blit_oklab: Spv,

    fn init(
        self: *Native,
        gpa: std.mem.Allocator,
        io: Io,
        managed: *host.ManagedWindow,
    ) !void {
        self.* = .{
            // SAFETY: Gpu.init assigns gpu before its first use.
            .gpu = undefined,
            // SAFETY: Surface.initSdl assigns surface before its first use.
            .surface = undefined,
            // SAFETY: adapter.init assigns adapter before its first use.
            .adapter = undefined,
            // SAFETY: Spv.load assigns quad_vert before module creation.
            .quad_vert = undefined,
            // SAFETY: Spv.load assigns quad_frag before module creation.
            .quad_frag = undefined,
            // SAFETY: Spv.load assigns sort_comp before module creation.
            .sort_comp = undefined,
            // SAFETY: Spv.load assigns fullscreen_vert before module creation.
            .fullscreen_vert = undefined,
            // SAFETY: Spv.load assigns blit_oklab before module creation.
            .blit_oklab = undefined,
        };
        try sdl3.vulkan.loadLibrary(null);
        const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();
        const requested = try sdl3.vulkan.getInstanceExtensions();
        const exts = try gpa.dupe([*:0]const u8, requested);
        defer gpa.free(exts);
        // The loader reads the extension list while the instance is built and
        // not after, so the storage is released as soon as `Gpu.init`
        // returns, on both the success and the failure path.
        vulkan_extensions = exts;
        defer vulkan_extensions = &.{};
        self.gpu = try noapi.Gpu.init(.{
            // Three, not two: the renderer rings its per-frame paint buffers
            // over three slots, one per in-flight frame.
            .frames_in_flight = frame_api.scene.frames_in_flight,
            .app_name = "w12-ime-smoke",
            .validation = false,
            .loader = .{
                .get_instance_proc_addr = @ptrCast(get_proc_addr),
                .get_instance_extensions = &instanceExtensions,
            },
            .io = io,
            .allocator = gpa,
        });
        errdefer self.gpu.deinit();
        // A platform call, so it can fail; the open is refused rather than
        // built on an unmeasured size. The surface is created and adopted in
        // one step, so a failed create cannot leave a live surface behind.
        self.surface = try noapi.Surface.initSdl(
            &self.gpu,
            @ptrCast(managed.native.sdl.value),
            @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
            .{ .extent = try deviceExtent(managed) },
        );
        errdefer self.surface.deinit();
        self.quad_vert = try Spv.load(gpa, io, "shaders/quad_vert.spv");
        errdefer self.quad_vert.deinit(gpa);
        self.quad_frag = try Spv.load(gpa, io, "shaders/quad_frag.spv");
        errdefer self.quad_frag.deinit(gpa);
        self.sort_comp = try Spv.load(gpa, io, "shaders/sort_comp.spv");
        errdefer self.sort_comp.deinit(gpa);
        self.fullscreen_vert = try Spv.load(gpa, io, "shaders/fullscreen_vert.spv");
        errdefer self.fullscreen_vert.deinit(gpa);
        self.blit_oklab = try Spv.load(gpa, io, "shaders/blit_oklab.spv");
        errdefer self.blit_oklab.deinit(gpa);
        try self.adapter.init(.{
            .allocator = gpa,
            .gpu = &self.gpu,
            // The field's face. It carries Latin; a composition it cannot
            // shape is painted as the layout's own missing-glyph boxes, and
            // the run reports the count instead of calling that text.
            .fonts = &.{.{ .family = "InterVariable", .bytes = @embedFile("InterVariable.ttf") }},
            .shaders = .{
                .quad_vert = self.quad_vert.words,
                .quad_frag = self.quad_frag.words,
                .sort_comp = self.sort_comp.words,
                .fullscreen_vert = self.fullscreen_vert.words,
                .blit_oklab = self.blit_oklab.words,
            },
            .name = "w12_ime_blit_oklab",
        });
    }

    /// The App must already have detached from `adapter.gpuEndpoint()`.
    fn deinit(self: *Native, gpa: std.mem.Allocator) void {
        self.adapter.deinit();
        self.surface.deinit();
        // After the surface: the swapchain lives on this device.
        self.gpu.deinit();
        self.blit_oklab.deinit(gpa);
        self.fullscreen_vert.deinit(gpa);
        self.sort_comp.deinit(gpa);
        self.quad_frag.deinit(gpa);
        self.quad_vert.deinit(gpa);
        self.* = undefined;
    }
};

/// The window's own pixel extent. This is what the swapchain is asked for;
/// the driver may clamp the image it hands back, and both passes size
/// themselves to the image instead.
fn deviceExtent(managed: *host.ManagedWindow) !noapi.Extent2D {
    const pixels = try managed.native.sdl.getSizeInPixels();
    return .{ .width = @intCast(pixels[0]), .height = @intCast(pixels[1]) };
}

/// The default run: every event is synthetic, the window is hidden on the dummy
/// driver, and the assertions are about the host path rather than about a
/// person typing.
fn headlessScenario(self: *Run) !void {
    const report = self.report;
    report.emit(
        "\nmode: HEADLESS. SDL events below are SYNTHETIC — built by this binary\n" ++
            "and pushed through Application.dispatch. No input method produced them.\n" ++
            "The candidate rectangle is the value handed to SDL_StartTextInputArea;\n" ++
            "no candidate window is observed, because none exists on this driver.\n" ++
            "The clipboard section near the end is the one place the real W18 port\n" ++
            "is used: on the dummy driver its offer lives in this process.\n",
        .{},
    );

    try self.frame();
    report.emit(
        "driver: {s} window={d} visible={} observed={d}x{d}\n",
        .{
            sdl3.video.getCurrentDriverName() orelse "<null>",
            self.managed.native.id,
            self.managed.observed.visible,
            self.managed.observed.size.width,
            self.managed.observed.size.height,
        },
    );
    report.expectTrue("the window is not shown on any display server", !self.managed.observed.visible);

    // ── focus drives native text input ──
    const tabbed = try self.deliver(&keyEvent(self.managed.native.id, .tab, false));
    report.expectTrue("Tab reached the App through SDL translation", tabbed);
    try self.frame();
    const focused = self.app.focus_manager.current orelse {
        report.emit("focus: none after Tab\n", .{});
        return error.NoFocusTarget;
    };
    self.field_id = focused;
    report.emit("focus: owner={d} slot={d} generation={d}\n", .{
        focused.owner, focused.slot, focused.generation,
    });

    self.registerField();
    report.expectTrue(
        "SDL text input is active after focus registered the endpoint",
        self.managed.native.textInputActive(),
    );
    report.expectCount("native starts after the first focus", 1, self.trace.starts);
    // Re-registering the same identity refreshes the endpoint; it must not
    // restart an open native session.
    self.registerField();
    report.expectCount("native starts after re-registering the same field", 1, self.trace.starts);
    report.expectTrue(
        "SDL text input stays active across a re-registration",
        self.managed.native.textInputActive(),
    );

    var state = try self.field();
    report.expectText("initial field text", "hello world", state.text());
    report.expectTrue("the marked range starts empty", state.marked == null);

    // ── a physical key inserts nothing; its commit inserts once ──
    const stroke = try self.deliver(&keyEvent(self.managed.native.id, codepoint('d'), false));
    report.expectTrue("the physical key reached the App", stroke);
    state = try self.field();
    report.expectText("text after the physical key", "hello world", state.text());
    report.expectCount("model replacements after the physical key", 0, state.replacements);

    report.expectTrue("the commit reached the App", try self.deliver(&textInputEvent(self.managed.native.id, "d")));
    state = try self.field();
    report.expectText("text after the commit", "hello worldd", state.text());
    report.expectCount("model replacements after one commit", 1, state.replacements);

    // The SDL layer drops an event for another window; that is a real property
    // of the translation, not a shortcut around it.
    const foreign_id: sdl3.video.WindowId = self.managed.native.id +% 1_000;
    const foreign = try self.deliver(&textInputEvent(foreign_id, "Z"));
    report.expectTrue("an event for a foreign window is dropped", !foreign);
    state = try self.field();
    report.expectText("text after a foreign-window commit", "hello worldd", state.text());
    report.expectCount("model replacements after a foreign-window commit", 1, state.replacements);

    // ── candidate geometry on a wrapped caret ──
    // "hello worldd" is 12 UTF-16 units and the field wraps every 8, so the
    // caret sits on the second visual line.
    try self.noteCaret("after the commit");
    const wrapped = (try self.publishCaret()) orelse return error.NoCaretGeometry;
    report.expectRect("wrapped caret rectangle", .{
        .x = 24 + 8 * 4,
        .y = 40 + 16,
        .w = 0,
        .h = 16,
    }, wrapped.area);
    report.expectCount("rectangles published for the wrapped caret", 1, self.trace.areas);
    if (self.trace.last) |last| {
        report.expectRect("the rectangle handed to SDL", wrapped.area, last.area);
    } else {
        report.expectTrue("the wrapped caret published a rectangle", false);
    }
    // A second read in the same generation must not re-measure or republish.
    _ = try self.publishCaret();
    // The generation cache is checked on the model side too: a cached read must
    // not ask the endpoint to measure the caret again.
    state = try self.field();
    report.expectCount("caret measurements after the cached second read", 1, state.caret_reads);
    report.expectCount("rectangles after a cached second read", 1, self.trace.areas);

    // ── preedit: marked once, committed once ──
    const preedit = textEditingEvent(self.managed.native.id, "あい", 0, 2);
    report.expectTrue("the preedit reached the App", try self.deliver(&preedit));
    // SDL counts the preedit selection in codepoints; the protocol counts its
    // bytes. This asserts the conversion, not the model.
    if ((try self.route(&preedit))) |core| {
        switch (core) {
            .composition => |composition| {
                report.expectTrue("the preedit arrives as a composition update", composition.phase == .update);
                report.expectUsize("preedit selection start in bytes", 0, composition.selection_start);
                report.expectUsize("preedit selection end in bytes", 6, composition.selection_end);
            },
            else => report.expectTrue("the preedit translates to a composition", false),
        }
    } else {
        report.expectTrue("the preedit translated", false);
    }
    state = try self.field();
    report.expectText("text under an open preedit", "hello worlddあい", state.text());
    if (state.marked) |marked| {
        report.expectTrue("the marked range covers the preedit once", marked.start == 12 and marked.end == 14);
    } else {
        report.expectTrue("the preedit left a marked range", false);
    }
    report.expectCount("model marks after one preedit", 1, state.marks);
    report.expectUsize("occurrences of the preedit text", 1, countOccurrences(state.text(), "あい"));

    // While composing, the caret follows the marked range, not the old caret.
    try self.noteCaret("while composing");
    const composing = (try self.publishCaret()) orelse return error.NoCaretGeometry;
    report.expectRect("composing caret rectangle", .{
        .x = 24 + 8 * 6,
        .y = 40 + 16,
        .w = 0,
        .h = 16,
    }, composing.area);
    report.expectCount("rectangles published for the composing caret", 2, self.trace.areas);

    // A selection inside a preedit crosses three units on its way to the
    // model: SDL counts CODEPOINTS, the host's translation counts BYTES of the
    // preedit, and the protocol speaks UTF-16 code units. Half of "あい"
    // selected is therefore a caret one unit INTO the marked range, not at
    // its end: bytes read as units would clamp to the end of the preedit and
    // report no selection at all.
    report.expectTrue(
        "the half-selected preedit reached the App",
        try self.deliver(&textEditingEvent(self.managed.native.id, "あい", 0, 1)),
    );
    state = try self.field();
    report.expectText("text under the half-selected preedit", "hello worlddあい", state.text());
    report.expectUsize("caret unit with half the preedit selected", 13, state.selection.range.start);
    if (state.marked) |marked| {
        report.expectTrue(
            "the marked range still covers the preedit once",
            marked.start == 12 and marked.end == 14,
        );
    } else {
        report.expectTrue("the half-selected preedit left a marked range", false);
    }
    try self.noteCaret("with half the preedit selected");
    const partial = (try self.publishCaret()) orelse return error.NoCaretGeometry;
    report.expectRect("caret rectangle with half the preedit selected", .{
        .x = 24 + 8 * 5,
        .y = 40 + 16,
        .w = 0,
        .h = 16,
    }, partial.area);
    report.expectCount("rectangles published for the half-selected preedit", 3, self.trace.areas);

    // A longer preedit replaces the shorter one instead of appending to it.
    report.expectTrue(
        "the extended preedit reached the App",
        try self.deliver(&textEditingEvent(self.managed.native.id, "あいう", null, null)),
    );
    state = try self.field();
    report.expectText("text under the extended preedit", "hello worlddあいう", state.text());
    report.expectCount("model marks after the extended preedit", 3, state.marks);

    // An empty preedit ends the composition; the commit that follows replaces
    // the marked text.
    report.expectTrue(
        "the composition end reached the App",
        try self.deliver(&textEditingEvent(self.managed.native.id, "", null, null)),
    );
    report.expectTrue(
        "the commit reached the App",
        try self.deliver(&textInputEvent(self.managed.native.id, "愛")),
    );
    state = try self.field();
    report.expectText("text after the preedit commit", "hello worldd愛", state.text());
    report.expectTrue("the commit cleared the marked range", state.marked == null);
    report.expectCount("model replacements after the commit", 2, state.replacements);
    report.expectUsize("occurrences of the committed character", 1, countOccurrences(state.text(), "愛"));
    report.expectUsize("occurrences of the discarded preedit", 0, countOccurrences(state.text(), "あい"));

    // ── the candidate rectangle follows a scrolled caret ──
    try self.setScroll(1);
    try self.frame();
    state = try self.field();
    report.expectUsize("scroll lines the model holds", 1, state.scroll_lines);
    try self.noteCaret("after scrolling one line");
    const scrolled = (try self.publishCaret()) orelse return error.NoCaretGeometry;
    report.expectRect("scrolled caret rectangle", .{
        .x = 24 + 8 * 5,
        .y = 40,
        .w = 0,
        .h = 16,
    }, scrolled.area);
    report.expectCount("rectangles published after the scroll", 4, self.trace.areas);

    // A caret scrolled out of the field has no anchor, so nothing is published.
    try self.setScroll(2);
    try self.frame();
    report.expectTrue("a caret scrolled out of the field reports no rectangle", try self.publishCaret() == null);
    report.expectCount("rectangles published for an off-screen caret", 4, self.trace.areas);

    try self.setScroll(0);
    try self.frame();
    const restored = (try self.publishCaret()) orelse return error.NoCaretGeometry;
    report.expectRect("caret rectangle after scrolling back", .{
        .x = 24 + 8 * 5,
        .y = 40 + 16,
        .w = 0,
        .h = 16,
    }, restored.area);

    // ── a focus switch cancels the composition and stops native input ──
    report.expectTrue(
        "a new preedit reached the App",
        try self.deliver(&textEditingEvent(self.managed.native.id, "あい", null, null)),
    );
    state = try self.field();
    report.expectText("text under the cancelled preedit", "hello worldd愛あい", state.text());
    report.expectCount("model marks before the focus switch", 4, state.marks);

    report.expectTrue(
        "the focus-moving key reached the App",
        try self.deliver(&keyEvent(self.managed.native.id, .tab, false)),
    );
    try self.frame();
    report.expectTrue("the field no longer owns the keyboard", self.app.textInputManager().focusedId() == null);
    report.expectTrue(
        "the mounted view no longer shows the field holding the keyboard",
        !self.view.field_holds_keyboard,
    );
    report.expectTrue("SDL text input is stopped after the focus switch", !self.managed.native.textInputActive());
    report.expectCount("native stops after the focus switch", 1, self.trace.stops);
    report.expectCount("compositions dismissed with the native session", 1, self.trace.clears);

    state = try self.field();
    report.expectText("text after the cancelled composition", "hello worldd愛", state.text());
    report.expectTrue("the cancelled composition left no marked range", state.marked == null);
    report.expectUsize("occurrences of the cancelled preedit", 0, countOccurrences(state.text(), "あい"));
    // Cancelling drops the preedit text, which is a replacement like any other.
    report.expectCount("model replacements after the cancelled composition", 3, state.replacements);
    // A preedit that began at a collapsed caret must leave the caret where the
    // composition started. A cancel that parks it anywhere else — the start of
    // the document, for instance — is a real defect, and the next commit lands
    // in the wrong place because of it, so this check is not cosmetic.
    report.expectUsize("caret unit after the cancelled composition", 13, state.selection.range.start);

    // Committed text with no focused endpoint must not reach any model.
    report.expectTrue(
        "a commit after the focus switch reached the App",
        try self.deliver(&textInputEvent(self.managed.native.id, "X")),
    );
    state = try self.field();
    report.expectText("text after an unfocused commit", "hello worldd愛", state.text());
    report.expectCount("model replacements after an unfocused commit", 3, state.replacements);

    // ── the field still works after a focus round trip ──
    report.expectTrue(
        "the focus-returning key reached the App",
        try self.deliver(&keyEvent(self.managed.native.id, .tab, true)),
    );
    try self.frame();
    const returned = self.app.focus_manager.current orelse return error.NoFocusTarget;
    report.expectTrue("focus returned to the field", returned.eql(self.field_id));
    self.registerField();
    report.expectCount("native starts after the field takes focus again", 2, self.trace.starts);
    report.expectTrue("SDL text input is active again", self.managed.native.textInputActive());
    try self.frame();
    report.expectTrue("the mounted view shows the field holding the keyboard", self.view.field_holds_keyboard);

    report.expectTrue(
        "the commit after the focus round trip reached the App",
        try self.deliver(&textInputEvent(self.managed.native.id, "!")),
    );
    state = try self.field();
    report.expectText("text after the focus round trip", "hello worldd愛!", state.text());
    report.expectCount("model replacements after the focus round trip", 4, state.replacements);

    // ── one real SDL clipboard round trip through the manager ──
    // Everything above ran with a refusing guard in the port, so no edit
    // action could reach the user's clipboard. This section puts back the
    // port the host bound when the window opened: the dummy driver keeps its
    // offer inside this process, so the copy, the cut and the paste below are
    // real calls to SDL's own clipboard against a clipboard no other program
    // can see. The guard goes back before the run ends.
    const manager = self.app.textInputManager();
    const real = self.host_clipboard orelse return error.HostDidNotBindClipboard;
    manager.clipboard = real;
    report.emit(
        "clipboard: the W18 port the host bound is back for one round trip\n",
        .{},
    );

    // Copy the six bytes of " world" at UTF-16 units 5..11.
    try self.select(.{ .start = 5, .end = 11 });
    report.expectUsize(
        "bytes the real clipboard took in a copy",
        6,
        outcomeBytes(try manager.copy()),
    );
    report.expectText("text after the copy", "hello worldd愛!", (try self.field()).text());

    // Paste them at the end of the field. Those bytes can only come from the
    // clipboard, so a paste that lands them is a read the platform answered.
    try self.select(.{ .start = 14, .end = 14 });
    report.expectUsize(
        "bytes the real clipboard gave back in a paste",
        6,
        outcomeBytes(try manager.paste()),
    );
    state = try self.field();
    report.expectText("text after the paste", "hello worldd愛! world", state.text());

    // Cut the pasted text out again: the copy lands in the clipboard and the
    // selection leaves the field, which is the pair a cut owes.
    try self.select(.{ .start = 14, .end = 20 });
    report.expectUsize(
        "bytes the real clipboard took in a cut",
        6,
        outcomeBytes(try manager.cut()),
    );
    state = try self.field();
    report.expectText("text after the cut", "hello worldd愛!", state.text());
    // The paste and the cut are the only two replacements the clipboard
    // actions made, on top of the four the commits above produced.
    report.expectUsize("model replacements after the clipboard round trip", 6, state.replacements);

    manager.clipboard = self.clipboard_guard.port();

    // ── window teardown stops the native session ──
    const before_close = self.trace.stops;
    _ = try self.application.closeWindow(self.handle);
    self.window_open = false;
    report.expectCount("native stops after the window closes", before_close + 1, self.trace.stops);
    report.expectCount("clipboard calls that reached the refusing guard", 0, self.clipboard_guard.attempts);
}

/// The authorized clipboard mode's own ending: this mode reached out to one
/// private display's selections, so it owes them back, and it says in its own
/// report what it ran against the host's port, what the refusing guard
/// refused, what it answered while nothing held the focus, and what it did NOT
/// prove about input methods.
///
/// It is one function because it has to run from BOTH ends of the scenario: a
/// controller can end the run from the focus wait, before the hold loop exists,
/// and a run that ends there still owes that display the same thing.
fn finishAuthorizedClipboard(self: *Run) !void {
    const report = self.report;
    // A refusal to restore is reported by name and still lets the rest of this
    // report print, so a display left changed is named rather than hidden.
    self.clipboard_restored = restored: {
        self.restorePrivateSelections() catch |err| {
            report.emit(
                "clipboard: the restore FAILED with {s}. This private display keeps\n" ++
                    "whatever the run left on it.\n",
                .{@errorName(err)},
            );
            break :restored false;
        };
        break :restored true;
    };
    report.emit(
        "clipboard: {d} authorized action(s) ran against the host's own W18\n" ++
            "port; the refusing guard answered {d} call(s); {d} request(s) were\n" ++
            "answered while no target held the focus\n",
        .{ self.clipboard_actions, self.clipboard_guard.attempts, self.focus_wait_requests },
    );
    report.emit(
        "clipboard: the baseline this run put back was {d} byte(s) of clipboard\n" ++
            "text and {d} byte(s) of primary text; the primary selection was\n" ++
            "written only when it held something (written={})\n",
        .{
            self.clipboard_baseline.clipboardBytes(),
            self.clipboard_baseline.primaryBytes(),
            self.clipboard_baseline.primary_written,
        },
    );
    report.emit(
        "ime: NOT OBSERVED AND NOT REQUIRED IN THIS RUN. No input method is\n" ++
            "installed on this display by design, so this run claims no\n" ++
            "composition and fails for none. The IME acceptance is the\n" ++
            "interactive run WITHOUT --native-clipboard, which this mode does not\n" ++
            "replace: it still fails when no composition arrives.\n",
        .{},
    );
    report.expectTrue(
        "the private display's CLIPBOARD is back at its own pre-run state and its " ++
            "PRIMARY selection was left exactly as it was measured",
        self.clipboard_restored,
    );
}

/// The opt-in person-at-the-keyboard mode: a real window on the session's own
/// driver, real painted pixels, and real events from a real input method. The
/// program cannot assert a composition it did not receive, so it reports what
/// arrived and FAILS when nothing did.
fn interactiveScenario(self: *Run) !void {
    const report = self.report;
    const native = self.native orelse return error.NoNativeSurface;
    report.emit(
        "\nmode: INTERACTIVE. A real window is open on the driver below and every\n" ++
            "event from here on is a real event from a real input method.\n" ++
            "This mode PAINTS. The field's box, its text, a selection, a preedit and\n" ++
            "the caret go through the public scene lowering, the shared W11\n" ++
            "TextService and the Oklab-to-sRGB blit into the real swapchain image,\n" ++
            "and the last frame's pixels are read back out of that image's Oklab\n" ++
            "target so the numbers below are pixels and not intentions.\n" ++
            "The caret and preedit boxes are shaped by the SAME service the glyphs\n" ++
            "were rasterized with, so the rectangle handed to SDL and the bar on\n" ++
            "screen are one measurement.\n" ++
            "What to do: click the field, switch to your input method (the exact\n" ++
            "command depends on your desktop), compose, and watch this report name the\n" ++
            "caret and preedit your IME actually produced. Move the focus with the\n" ++
            "POINTER, not with Tab: while the field holds the keyboard the window has\n" ++
            "native text input active, and SDL hands every key to the input method\n" ++
            "before this process is offered one, so a Tab typed over an open preedit\n" ++
            "never arrives here. Click \"Second focus target\" to cancel and click the\n" ++
            "field to return, then close the window or wait out the hold.\n",
        .{},
    );
    if (self.requests != null) {
        report.emit(
            "requests: ON. stdin is a controller's pipe and is read between polls, so\n" ++
                "no request can stall the event pump. The verbs are `state` (present\n" ++
                "one frame and answer with the App's focus, the endpoint's rectangle,\n" ++
                "SDL's own stored rectangle, the marked range, the whole selection as\n" ++
                "start:end in document units, the painted counters and the model's\n" ++
                "bytes in hex), `targets` (present one frame and answer with this run's\n" ++
                "own two focus targets and this window's origin, read out of the tree\n" ++
                "that frame committed), `scroll <lines>` (move the field's own scroll\n" ++
                "offset) and `quit`. Each answers with one `ack` line; every other line on" ++
                "stdout is this report. A request builds no event and pushes nothing\n" ++
                "into SDL, so nothing here can manufacture a composition.\n",
            .{},
        );
    }
    if (self.clipboard_authorized) {
        report.emit(
            "requests: the clipboard verbs join the list above in this run ONLY, and\n" ++
                "every one of them refuses by name without the scope literal below:\n" ++
                "`copy`, `cut` and `paste` run the shared W18 actions against the\n" ++
                "port the host bound and answer with the service's own outcome, the\n" ++
                "bytes it moved, the model's replacement and mark counters, the\n" ++
                "selection it left and the model's bytes in hex; `clipboard-restore`\n" ++
                "puts this private display's CLIPBOARD back and answers with what the\n" ++
                "platform holds afterwards, leaving an absent PRIMARY selection\n" ++
                "absent. While this run is still WAITING for the real focus it\n" ++
                "answers `state`, `targets`, `clipboard-restore` and `quit` only,\n" ++
                "because the verbs that act on a focused field mean nothing until\n" ++
                "one holds the keyboard; they refuse by name there. There is no\n" ++
                "verb that makes a selection: a selection is made with real Home,\n" ++
                "arrow and Shift+arrow keys on this display and read back out of\n" ++
                "the model.\n",
            .{},
        );
    }

    try self.nativeStep("open");
    // The same two measured scales the bounded graphical run prints, here
    // where a real input method is the thing being observed. Without them a
    // scaled interactive run could not tell a platform scale from an applied
    // one, and its candidate placement would be unreadable.
    const observed_scale = try self.managed.observed.pixelScale();
    report.emit(
        "driver: {s} window={d} visible={} observed={d}x{d} pixels={d}x{d}" ++
            " display_scale={d:.4} pixel_scale={d:.4}x{d:.4} image={d}x{d}\n",
        .{
            sdl3.video.getCurrentDriverName() orelse "<null>",
            self.managed.native.id,
            self.managed.observed.visible,
            self.managed.observed.size.width,
            self.managed.observed.size.height,
            self.managed.observed.pixels.width,
            self.managed.observed.pixels.height,
            self.managed.observed.display_scale,
            observed_scale.x,
            observed_scale.y,
            self.last_image.width,
            self.last_image.height,
        },
    );
    if (self.clipboard_authorized) {
        const driver = sdl3.video.getCurrentDriverName() orelse "<null>";
        if (!std.mem.eql(u8, driver, "x11")) {
            report.emit(
                "the authorized clipboard scope needs the x11 driver and this run\n" ++
                    "opened {s}. No clipboard was read or written.\n",
                .{driver},
            );
            return error.NativeClipboardNeedsX11;
        }
        const display = self.display orelse "<unset>";
        if (!std.mem.eql(u8, display, Options.native_clipboard_display)) {
            report.emit(
                "the authorized clipboard scope names display {s} and this process\n" ++
                    "was started on {s}. No clipboard was read or written.\n",
                .{ Options.native_clipboard_display, display },
            );
            return error.NativeClipboardDisplayNotPrivate;
        }
        // Measured BEFORE any authorized action and before the pipe serves a
        // line, so a controller cannot have a verb answered before the state it
        // has to be put back into is known.
        try self.capturePrivateBaseline();
        report.emit(
            "\nclipboard: AUTHORIZED on display {s} under the exact scope literal\n" ++
                "below. The refusing guard is still in the port for every event on\n" ++
                "this run; the host's own W18 port is swapped in for the length of\n" ++
                "one `copy`, `cut` or `paste` a controller asks for, and the guard\n" ++
                "is back before that call returns.\n" ++
                "scope: {s}\n" ++
                "measured before the first authorized action: clipboard_present={}\n" ++
                "clipboard_bytes={d} primary_present={} primary_bytes={d}\n" ++
                "primary_readable={} — both texts are owned at their measured\n" ++
                "lengths, and an absent primary selection is left absent rather\n" ++
                "than set to an empty string, which would take the selection over\n" ++
                "instead of releasing it.\n" ++
                "input method: NONE on this display, by design. This run proves the\n" ++
                "clipboard and not the IME, so it does not require a composition and\n" ++
                "does not claim one; the IME acceptance is a different mode driven\n" ++
                "by a different controller, and nothing here weakens it.\n",
            .{
                display,
                Options.native_clipboard_scope,
                self.clipboard_baseline.clipboard_present,
                self.clipboard_baseline.clipboardBytes(),
                self.clipboard_baseline.primary_present,
                self.clipboard_baseline.primaryBytes(),
                self.clipboard_baseline.primary_readable,
            },
        );
    } else {
        report.emit(
            "no clipboard is read or written in this mode; the W18 port is a guard.\n",
            .{},
        );
    }

    // Focus the field so native text input is started on the real window.
    //
    // NO synthetic Tab here. This mode's whole claim is that every event in it
    // came from a real input method, so it may not reach into the path it
    // reports on and manufacture the one event that would have made the rest
    // possible. Focus has to arrive from outside this process.
    const target = (try self.focusFromOutside(Options.interactive_focus_wait_ms)) orelse {
        if (self.requests_quit) {
            // A controller that was answered in the focus wait (see
            // `serveFocusWaitRequest`) can end the run from there. Nothing took
            // the focus and nothing was built to make it, so this is not the
            // failure below: it is a run that was told to stop and obeyed.
            report.emit(
                "requests: the controller ended this run while it was still waiting for\n" ++
                    "a real focus. {d} request(s) were answered in that wait and no\n" ++
                    "target was focused, because no event was made to focus one.\n",
                .{self.focus_wait_requests},
            );
            if (self.clipboard_authorized) try finishAuthorizedClipboard(self);
            return;
        }
        report.emit(
            "nothing took the focus in {d} ms. The window is real and the keyboard\n" ++
                "is real, so this run will not focus the field for you: press Tab, or\n" ++
                "click the field's button, and the composition that follows is the one\n" ++
                "this report will name. NO INPUT METHOD OBSERVED.\n",
            .{Options.interactive_focus_wait_ms},
        );
        return error.NoFocusTarget;
    };
    self.field_id = target;
    self.registerEndpoint();
    report.emit(
        "native starts={d} sdl_text_input_active={} status={s} start_error={s}\n",
        .{
            self.trace.starts,
            self.managed.native.textInputActive(),
            @tagName(self.app.textInputManager().native_status),
            if (self.trace.start_error) |err| @errorName(err) else "<none>",
        },
    );

    var closed = false;
    const deadline = sdl3.timer.getMillisecondsSinceInit() + self.hold_ms;
    // The host's own contract for an externally driven loop: pollEvent plus
    // dispatch. `step` is not called, so no event is dispatched twice.
    while (!closed and sdl3.timer.getMillisecondsSinceInit() < deadline) {
        // A controller's line is served HERE, before the next poll, so a
        // readback describes the frame that was just presented and a scroll
        // lands before the next composition is routed. Serving it never ends
        // the loop on its own: `closed` is set only after the request that
        // asked for it has been answered.
        if (self.requests) |requests| {
            if (try requests.poll()) {
                if (!try self.serveRequest(requests.take())) closed = true;
            }
        }
        if (closed) break;
        const raw = self.application.pollEvent() orelse {
            try self.nativeStep("idle");
            try Io.sleep(self.report.io, Io.Duration.fromMilliseconds(8), .real);
            continue;
        };
        switch (raw) {
            .window_close_requested => |value| {
                if (value.id == self.managed.native.id) closed = true;
            },
            .quit => closed = true,
            else => {},
        }
        // The close request is this run's own signal to stop. It is not routed:
        // the host would destroy the window, and the report below still reads
        // the window it observed.
        if (closed) break;
        const core = (try self.route(&raw)) orelse continue;
        // The counters the interactive acceptance turns on. A real
        // composition is a `composition` the host translated out of an input
        // method and a real commit is a `text_input` one; nothing else moves
        // them, and no request can. A key is counted where it is routed, in
        // this loop and in the focus wait before it, because a key the input
        // method took never reaches either switch: that is how a run says
        // "that key press never arrived at the application" without having to
        // guess about where it went.
        switch (core) {
            .composition => self.compositions += 1,
            .text_input => self.commits += 1,
            .key_down => self.keys += 1,
            else => {},
        }
        _ = try self.app.handle(core);
        // The presentation settles keyboard ownership; the model is read
        // after it, because a Session borrow must not overlap a frame. A real
        // composition is where the candidate rectangle has to be right, so
        // the shaped geometry is published and reported on every one.
        try self.nativeStep("event");
    }

    const inked = try self.countInked(native);
    var measured = (try ink.measure(self.ink.?)) orelse {
        report.emit("the shaped field is gone; nothing left to report\n", .{});
        return error.FieldModelReleased;
    };
    defer measured.deinit(self.gpa);
    var caret_buffer: [64]u8 = undefined;
    var sdl_buffer: [64]u8 = undefined;
    const glyphs = self.glyphCounts();
    report.emit(
        "real events: compositions={d} commits={d} rectangles_published={d}\n" ++
            "shaped field: lines={d} width={d:.1} text=\"{s}\" caret_unit={d}\n" ++
            "marked={any} marks={d} replacements={d}\n" ++
            "caret rect={s} sdl_rect={s} preedit_boxes={d}\n" ++
            "native starts={d} stops={d} sdl_text_input_active={} clipboard_calls={d}\n" ++
            "glyphs: laid_out={d} missing_from_pinned_face={d}\n",
        .{
            self.compositions,
            self.commits,
            self.trace.areas,
            measured.state.lines,
            measured.state.width,
            measured.state.text(),
            measured.state.selection.range.start,
            measured.state.marked,
            measured.state.marks,
            measured.state.replacements,
            rectText(&caret_buffer, measured.caret),
            sdlRectText(&sdl_buffer, measured.caret),
            measured.preedit.len,
            self.trace.starts,
            self.trace.stops,
            self.managed.native.textInputActive(),
            self.clipboard_guard.attempts,
            glyphs.total,
            glyphs.missing,
        },
    );
    report.expectCount("clipboard calls that reached the refusing guard", 0, self.clipboard_guard.attempts);
    report.emit(
        "pixels: inked_total={d} inked_in_field={d} image={d}x{d} target={d}x{d}\n" ++
            "painted last frame: rects={d} glyphs={d} selection={d} preedit={d} caret={}\n" ++
            "present: committed={d} presented={d} retries={d} resizes={d} " ++
            "swapchains={d} extent_mismatches={d} present_out_of_date={d} scale_changes={d}\n",
        .{
            inked.total,
            inked.inside_field,
            self.last_image.width,
            self.last_image.height,
            native.adapter.targetExtent().width,
            native.adapter.targetExtent().height,
            self.painted.rects,
            self.painted.glyphs,
            self.painted.selection,
            self.painted.preedit,
            self.painted.caret,
            native.adapter.stats.frames_committed,
            native.adapter.stats.frames_presented,
            self.retries,
            native.adapter.stats.resizes_requested,
            native.adapter.stats.swapchains_recreated,
            native.adapter.stats.extent_mismatches,
            native.adapter.stats.present_out_of_date,
            native.adapter.stats.scale_changes,
        },
    );
    report.expectTrue("at least one frame reached the swapchain image", native.adapter.stats.frames_presented > 0);
    report.expectTrue("the field's own glyphs were painted", self.painted.glyphs > 0);
    report.expectTrue("pixels were written inside the field's own box", inked.inside_field > 0);
    if (self.ppm) |path| {
        try self.writePpm(native, path);
        report.emit("ppm: wrote the last presented frame to {s}\n", .{path});
    }
    if (self.clipboard_authorized) {
        try finishAuthorizedClipboard(self);
        return;
    }
    if (self.compositions == 0) {
        report.emit(
            "no real composition reached the field. An input method was not composing,\n" ++
                "so this run proved nothing about native IME behaviour and is a failure.\n",
            .{},
        );
        return error.InteractiveImeNotObserved;
    }
    if (self.commits == 0) {
        report.emit(
            "a real preedit arrived but no real commit did. The composition was not\n" ++
                "confirmed, so the commit path is still unproven on this session.\n",
            .{},
        );
        return error.InteractiveCommitNotObserved;
    }
    report.emit("a real composition and a real commit both reached the field.\n", .{});
    if (glyphs.missing != 0) {
        report.emit(
            "the commit above is real and its bytes are in the model, but the pinned\n" ++
                "face shaped {d} of the {d} glyphs as notdef. They are painted as the\n" ++
                "layout's own missing-glyph boxes: the bytes are proved, the PICTURE\n" ++
                "of those characters is not, and this run does not claim it.\n",
            .{ glyphs.missing, glyphs.total },
        );
    }
}

/// The bounded graphical run: a real window, the real GPU and REAL PAINTED
/// PIXELS, driven by synthetic events this binary builds and labels. It
/// proves the graphical path — the field's box, text, selection, preedit and
/// caret through the public scene lowering and the Oklab→sRGB blit — and it
/// says in its own output that it observed no input method, so it is never
/// mistaken for IME acceptance.
fn nativeScenario(self: *Run, options: Options) !void {
    const report = self.report;
    const native = self.native orelse return error.NoNativeSurface;
    const budget = options.frameBudget();
    report.emit(
        "\nmode: NATIVE (graphical smoke, bounded to {d} frames). A real window is\n" ++
            "open on the driver below, the real device painted into it, and every\n" ++
            "SDL event below is SYNTHETIC — built by this binary and pushed through\n" ++
            "Application.dispatch. NO INPUT METHOD OBSERVED, and this run does not\n" ++
            "claim one: it is a rendering and geometry run. Use --interactive for a\n" ++
            "person and a real composition, and that mode fails when none arrives.\n",
        .{budget},
    );

    // A frame before anything else, so the window is showing the field's own
    // text with no input at all. The field is not focused yet, so no caret is
    // painted: the caret is the focus indicator.
    try self.nativeStep("open");
    const empty_caret = self.painted.caret;
    const base_glyphs = self.painted.glyphs;
    // MEASURED by this run from its own two extents, not taken from the
    // platform: `PixelScale.init` refuses a window and a pixel extent that do
    // not describe the same rectangle, so a scale that cannot be measured
    // fails here rather than being printed as a plausible number.
    const observed = try self.managed.observed.pixelScale();
    report.emit(
        "driver: {s} window={d} visible={} observed={d}x{d} pixels={d}x{d}" ++
            " display_scale={d:.4} pixel_scale={d:.4}x{d:.4} image={d}x{d}\n",
        .{
            sdl3.video.getCurrentDriverName() orelse "<null>",
            self.managed.native.id,
            self.managed.observed.visible,
            self.managed.observed.size.width,
            self.managed.observed.size.height,
            self.managed.observed.pixels.width,
            self.managed.observed.pixels.height,
            // The two scales a scaled run has to be able to tell apart. The
            // display scale is what the PLATFORM says this window is drawn
            // at (SDL_GetWindowDisplayScale), and the pixel scale is what
            // THIS run measures by dividing its own pixel extent by its own
            // logical one. A run that prints only the first would let a
            // platform scale and an applied scale look like one fact, and a
            // candidate window anchored against one of them would then read
            // as correct against the other.
            self.managed.observed.display_scale,
            observed.x,
            observed.y,
            self.last_image.width,
            self.last_image.height,
        },
    );
    report.expectTrue("the window is visible on a real driver", self.managed.observed.visible);
    report.expectTrue("the field's own text was painted before any input", base_glyphs > 0);
    report.expectTrue("an unfocused field paints no caret", !empty_caret);

    // Focus the field, which is what starts native text input.
    report.expectTrue(
        "the focus key reached the App",
        try self.deliver(&keyEvent(self.managed.native.id, .tab, false)),
    );
    try self.nativeStep("focus");
    const target = self.app.focus_manager.current orelse return error.NoFocusTarget;
    self.field_id = target;
    self.registerEndpoint();
    try self.nativeStep("focused");
    report.expectTrue(
        "SDL text input is active on the real window",
        self.managed.native.textInputActive(),
    );
    report.expectTrue("a focused field paints its caret", self.painted.caret);

    // A commit: the field's own text grows, and the painted glyphs with it.
    report.expectTrue(
        "the synthetic commit reached the App",
        try self.deliver(&textInputEvent(self.managed.native.id, "!")),
    );
    try self.nativeStep("commit");
    const after_commit = self.painted.glyphs;
    report.expectTrue("the commit added a painted glyph", after_commit > base_glyphs);

    // A preedit: the composition's own boxes appear under its glyphs and the
    // underline is painted over them. The pinned face has no CJK, so the
    // composition is Latin here and the missing-glyph path is not exercised
    // by this step; a real IME's own characters are what report it.
    report.expectTrue(
        "the synthetic preedit reached the App",
        try self.deliver(&textEditingEvent(self.managed.native.id, "com", null, null)),
    );
    try self.nativeStep("preedit");
    report.expectTrue("the open preedit painted its own boxes", self.painted.preedit > 0);

    // The commit that ends it: the marked text is replaced once.
    report.expectTrue(
        "the composition end reached the App",
        try self.deliver(&textEditingEvent(self.managed.native.id, "", null, null)),
    );
    report.expectTrue(
        "the preedit's commit reached the App",
        try self.deliver(&textInputEvent(self.managed.native.id, "c")),
    );
    try self.nativeStep("commit-preedit");
    const committed = (try ink.state(self.ink.?)) orelse return error.FieldModelReleased;
    report.expectTrue("the committed preedit left no marked range", committed.marked == null);
    report.expectTrue("the preedit was committed once", countOccurrences(committed.text(), "c") == 1);

    // A selection: shift-arrow through the core's own text-input manager,
    // which is what a person's shift-arrow does.
    report.expectTrue(
        "the selection key reached the App",
        try self.deliver(&keyEvent(self.managed.native.id, .left, true)),
    );
    try self.nativeStep("select");
    report.expectTrue("the selection painted its own boxes", self.painted.selection > 0);
    const selected = (try ink.state(self.ink.?)) orelse return error.FieldModelReleased;
    report.expectTrue("the selection is not collapsed", !selected.selection.range.isEmpty());

    // A scroll: the candidate rectangle and the painted caret both follow the
    // field's own offset, and a caret scrolled out of the field has neither.
    try self.ink.?.setScroll(ink.line_height * 2);
    try self.nativeStep("scroll");
    const scrolled = (try ink.state(self.ink.?)) orelse return error.FieldModelReleased;
    report.expectTrue("the model holds the scroll offset", scrolled.geometry.scroll_px > 0);
    report.expectTrue(
        "a caret scrolled out of the field publishes no rectangle",
        try self.publishCaret() == null,
    );
    report.expectTrue("a caret scrolled out of the field paints no caret", !self.painted.caret);
    try self.ink.?.setScroll(0);
    try self.nativeStep("unscroll");
    report.expectTrue("the caret came back with the scroll offset", self.painted.caret);

    // A resize: the App is told through the host's own translation, the Oklab
    // target follows the image the driver hands out, and the glyph rasters are
    // redone when the observed scale changed.
    const before_extent = self.last_image;
    try self.managed.requestSize(.{ .width = window_width + 160, .height = window_height + 80 });
    var resize_frames: u32 = 0;
    // Bounded twice: by the compositor's own patience and by the frame
    // budget, so a run given a small budget truncates the WAIT rather than
    // overshooting the bound it was asked for.
    while (resize_frames < 4 and native.adapter.stats.frames_presented < budget) : (resize_frames += 1) {
        try self.nativeStep("resize");
        if (self.managed.observed.pixels.width != window_width) break;
        try Io.sleep(self.report.io, Io.Duration.fromMilliseconds(20), .real);
    }
    report.emit(
        "resize: requested={d}x{d} observed_logical={d}x{d} observed_pixels={d}x{d} image={d}x{d}\n",
        .{
            window_width + 160,
            window_height + 80,
            self.managed.observed.size.width,
            self.managed.observed.size.height,
            self.managed.observed.pixels.width,
            self.managed.observed.pixels.height,
            self.last_image.width,
            self.last_image.height,
        },
    );
    report.expectTrue(
        "the window's pixel extent is what the swapchain image is measured against",
        self.managed.observed.pixels.width > 0 and self.managed.observed.pixels.height > 0,
    );
    if (before_extent.width != self.last_image.width or before_extent.height != self.last_image.height) {
        report.emit(
            "  the image changed size: swapchain_recreated={d} extent_mismatches={d} scale_changes={d}\n",
            .{
                native.adapter.stats.swapchains_recreated,
                native.adapter.stats.extent_mismatches,
                native.adapter.stats.scale_changes,
            },
        );
    }

    // Focus loss cancels the composition and stops native input, and the
    // caret goes with the focus.
    report.expectTrue(
        "the preedit before the focus switch reached the App",
        try self.deliver(&textEditingEvent(self.managed.native.id, "com", null, null)),
    );
    try self.nativeStep("cancel-preedit");
    report.expectTrue("the open preedit painted its boxes again", self.painted.preedit > 0);
    report.expectTrue(
        "the focus-moving key reached the App",
        try self.deliver(&keyEvent(self.managed.native.id, .tab, false)),
    );
    try self.nativeStep("blur");
    report.expectTrue("the field no longer owns the keyboard", self.app.textInputManager().focusedId() == null);
    report.expectTrue("an unfocused field paints no caret again", !self.painted.caret);
    report.expectTrue("SDL text input is stopped after the focus switch", !self.managed.native.textInputActive());
    const cancelled = (try ink.state(self.ink.?)) orelse return error.FieldModelReleased;
    report.expectTrue("the cancelled composition left no marked range", cancelled.marked == null);
    report.expectUsize("occurrences of the cancelled preedit", 0, countOccurrences(cancelled.text(), "com"));

    // The pixels: what the presented passes actually wrote, read back out of
    // this run's own Oklab target. Nothing here re-renders anything.
    const inked = try self.countInked(native);
    report.emit(
        "pixels: inked_total={d} inked_in_field={d} image={d}x{d} target={d}x{d}\n" ++
            "present: committed={d} presented={d} retries={d} resizes={d} swapchains={d} " ++
            "extent_mismatches={d} present_out_of_date={d} scale_changes={d}\n",
        .{
            inked.total,
            inked.inside_field,
            self.last_image.width,
            self.last_image.height,
            native.adapter.targetExtent().width,
            native.adapter.targetExtent().height,
            native.adapter.stats.frames_committed,
            native.adapter.stats.frames_presented,
            self.retries,
            native.adapter.stats.resizes_requested,
            native.adapter.stats.swapchains_recreated,
            native.adapter.stats.extent_mismatches,
            native.adapter.stats.present_out_of_date,
            native.adapter.stats.scale_changes,
        },
    );
    report.expectTrue("every presented frame carried a field", native.adapter.stats.frames_presented > 0);
    report.expectTrue("the run stayed inside its frame budget", native.adapter.stats.frames_presented <= budget);
    report.expectTrue("the field's own text is painted", self.painted.glyphs > 0);
    report.expectTrue("pixels were written inside the field's own box", inked.inside_field > 0);
    report.expectTrue("pixels were written outside the field's box as well", inked.total > inked.inside_field);
    report.expectCount("clipboard calls that reached the refusing guard", 0, self.clipboard_guard.attempts);
    if (self.ppm) |path| {
        try self.writePpm(native, path);
        report.emit("ppm: wrote the last presented frame to {s}\n", .{path});
    }
    report.emit(
        "\nime: NOT OBSERVED. This mode builds its own events and observed no input\n" ++
            "method, so it proves the graphical path and nothing about native IME\n" ++
            "behaviour. Run --interactive for that, which fails without a real\n" ++
            "composition.\n",
        .{},
    );
}

fn codepoint(value: u21) sdl3.keycode.Keycode {
    return @fromBackingInt(@intCast(@as(u32, value)));
}

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer if (gpa_state.deinit() != 0) @panic("W12 IME smoke leaked");
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    const options = try parseOptions(gpa, init);

    var report: Reporter = .{ .io = io };
    report.emit("W12 native IME smoke\n", .{});
    report.emit(
        "consumer: one ordinary application-owned text field. No Neovim process is\n" ++
            "started and none is needed: the W12 protocol is a core, host-bound API.\n",
        .{},
    );

    var session = try nogui.Session.init(gpa);
    defer session.deinit() catch @panic("W12 IME smoke left the Session live");

    // Teardown order is the reverse of this registration order: the window is
    // closed first (below), then the field model, then the host, then the App,
    // then the Session. A released model is exactly what the weak endpoint is
    // designed to survive, so no step here can borrow a destroyed buffer.
    var app = try nogui.App.init(gpa, &session);
    defer app.deinit();

    var application = try host.Application.init(gpa, &session, .{
        .app_id = "dev.nogui.w12imesmoke",
        .restart = .never,
        // The default run asks a display server for nothing: the dummy driver
        // keeps the window object inside this process and shows nothing. The
        // painting modes need a REAL driver, because a Vulkan surface cannot
        // be created for a hidden dummy window.
        .video_driver = if (options.paints()) null else "dummy",
    });
    defer application.deinit();

    // The window is opened after the App and the model exist, so the App can
    // be mounted and the model bound to it.
    var view: View = .{};
    try app.mountRoot(View, &view);
    var field: Field = .{ .gpa = gpa };
    const initial = "hello world";
    try field.text.appendSlice(gpa, initial);
    const initial_units = try text_input.utf16Length(initial);
    field.selection = .{ .range = .{ .start = initial_units, .end = initial_units } };
    var owner = try session.create(Field, &field);
    defer session.release(Field, &owner) catch @panic("W12 IME smoke could not release the field model");

    const handle = try application.openWindowWithApp(&app, .{
        .title = window_title,
        .width = window_width,
        .height = window_height,
        .visible = options.paints(),
        // A real window the platform will give a Vulkan surface for. The
        // handle is created by the platform's own public callback below; this
        // only asks for a window that can have one.
        .gpu_surface = options.paints(),
    });
    const managed = try application.getWindow(handle);

    // The painting modes get a device, a surface and the public frame adapter
    // that owns the text engine. The headless mode creates NONE of them, so it
    // asks no display server for a GPU and links no font engine into its run.
    // SAFETY: native_live becomes true only after Native.init succeeds.
    var native: Native = undefined;
    var native_live = false;
    if (options.paints()) {
        try native.init(gpa, io, managed);
        native_live = true;
        // The App measures its layout through the engine that rasterizes the
        // glyphs, so a measured label and a painted glyph are one measurement.
        app.measure = native.adapter.measurer();
        try app.attachGpu(native.adapter.gpuEndpoint());
    }
    // The App detaches from the endpoint (through `deinit` or explicitly) and
    // the field model goes before the adapter, the surface and the device: the
    // engine borrows the service that borrows the font bytes, and the
    // service's layouts are pinned by the model.
    defer if (native_live) {
        app.detachGpu();
        native.deinit(gpa);
    };

    // The shaped field: its caret, its preedit boxes AND its painted glyphs all
    // come from the engine's own service, reached as `&engine.service`. It
    // lives in THIS frame, not in a copied optional, because the endpoint's
    // `user` pointer is the field's own address.
    // SAFETY: shaped_live becomes true only after Ink.init succeeds.
    var shaped_field: ink.Ink = undefined;
    var shaped_live = false;
    if (options.paints()) {
        try shaped_field.init(gpa, native.adapter.textEngine(), &session, initial);
        shaped_live = true;
    }
    defer if (shaped_live) shaped_field.deinit();

    // The host bound the real W18 clipboard when the window opened. It is
    // captured before the guard replaces it, because one section of the
    // headless run puts it back for a real round trip on the dummy driver.
    const host_clipboard = app.textInputManager().clipboard;

    var trace: NativeTrace = .{};
    var clipboard_guard: ClipboardGuard = .{};
    // The controller's channel lives in this frame, like the shaped field, so
    // its buffer outlives every read and is released before the reporter.
    // SAFETY: `requests.init` writes every field before `requests_live`
    // becomes true, nothing reads this value until then, and `deinit` runs
    // only under the same flag, so the bytes between the declaration and the
    // init are never read and none of them are zeroed to say so.
    var requests: Requests = undefined;
    var requests_live = false;
    if (options.requests) {
        requests.init(gpa);
        requests_live = true;
    }
    defer if (requests_live) requests.deinit();
    var run: Run = .{
        .gpa = gpa,
        .report = &report,
        .session = &session,
        .application = &application,
        .app = &app,
        .managed = managed,
        .handle = handle,
        .field_owner = &owner,
        .trace = &trace,
        .view = &view,
        .clipboard_guard = &clipboard_guard,
        .host_clipboard = host_clipboard,
        .display = options.display,
        .clipboard_authorized = options.native_clipboard,
        .hold_ms = options.hold_ms,
        .ink = if (shaped_live) &shaped_field else null,
        .native = if (native_live) &native else null,
        .ppm = options.ppm,
        .requests = if (requests_live) &requests else null,
    };
    defer run.teardown();
    // The measured baseline OWNS its bytes once the authorized mode has
    // captured them, so they are released on every outcome — including a run
    // that refused half way through — rather than only on the path that got
    // as far as the restore.
    defer run.releaseClipboardBaseline();

    // The host bound its own native port and the real W18 clipboard when the
    // window opened. The trace wraps the native port so every call the core
    // makes is observable and still reaches SDL; the guard replaces the
    // clipboard port so the scripted run cannot touch the user's clipboard;
    // the headless run's clipboard section puts the real port back for the
    // round trip it names.
    trace.inner = managed.native.nativeTextInput();
    app.textInputManager().native = trace.port();
    app.textInputManager().clipboard = clipboard_guard.port();

    // The outcome is captured rather than propagated straight away: a run that
    // ends early still has to print what it observed and what it did not prove.
    const outcome: ?anyerror = run_outcome: {
        if (options.interactive) {
            interactiveScenario(&run) catch |err| break :run_outcome err;
        } else if (options.native) {
            nativeScenario(&run, options) catch |err| break :run_outcome err;
        } else {
            headlessScenario(&run) catch |err| break :run_outcome err;
        }
        break :run_outcome null;
    };

    report.emit("\nsummary: {d} checks, {d} failed\n", .{ report.checks, report.failures });
    report.emit(
        "not proven by this run:\n" ++
            "  - a real IME composition: needs an input method and a person\n" ++
            "  - candidate-window placement: only the rectangle handed to SDL is observed\n" ++
            "  - CJK glyphs: the pinned face has none, so such a composition is painted\n" ++
            "    as the layout's own missing-glyph boxes and is reported as such\n",
        .{},
    );
    if (options.native_clipboard) {
        report.emit(
            "  - a clipboard shared with other applications: this run is the half a\n" ++
                "    CONTROLLER proves on the private display {s} under the exact scope\n" ++
                "    above — it ran {d} authorized action(s) against the host's own port\n" ++
                "    and put the measured selections back. The second process that owns\n" ++
                "    the source offer, and the second process that reads this run's own\n" ++
                "    copy and cut back, are that controller's, and this run reports\n" ++
                "    neither of them. No other display and no session clipboard was read\n" ++
                "    or written.\n",
            .{ Options.native_clipboard_display, run.clipboard_actions },
        );
    } else if (options.paints()) {
        report.emit(
            "  - a clipboard round trip: the W18 port is a refusing guard in this mode\n",
            .{},
        );
    } else {
        report.emit(
            "  - a clipboard shared with other applications: the round trip above ran\n" ++
                "    through SDL's own offer on the dummy driver, inside this process\n",
            .{},
        );
    }
    if (report.failures != 0) return error.SmokeCheckFailed;
    if (outcome) |err| return err;
}
