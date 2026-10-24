//! ONE application-owned editable field, TWO routes, one strict record.
//!
//! The field is a `Session` model, exactly like a real app's: the core
//! `Manager` never holds its bytes, its selection or its preedit. This example
//! wires the whole consumer side:
//!
//!   * `Field` owns UTF-8 text and a UTF-16 selection, and implements the ten
//!     protocol operations for a model. EVERY geometry answer — the caret
//!     rectangle, the hit test, the grapheme/line/word boundaries a motion
//!     walks, and the semantic character boxes — comes from ONE shaped layout
//!     of the model's CURRENT bytes, keyed on the model's own revision. There
//!     is no fixed-advance grid and no hand-rolled cluster rule in this file.
//!   * `focus` registers the endpoint on the App's OWN text manager, which is
//!     what an App does when the field takes keyboard focus; the App's own focus
//!     observer reconciles that manager from then on.
//!   * A `MemoryClipboard` stands in for the W18 system clipboard so the
//!     window-free route still answers a routed `copy`, `cut` or `paste`; the
//!     host binds the real service through `Window.nativeTextInput` and
//!     `nogui.text_input.Clipboard`, and a window that already carries one
//!     keeps it.
//!
//! BOTH routes shape with the SAME pinned face, `InterVariable.ttf`, through
//! the ONE text service each route owns, so a layout taken here describes the
//! very rules the route measured and rasterized with:
//!
//!   * DEFAULT: no window, no surface, no swapchain and NO GPU DEVICE AT ALL.
//!     The App's own measure seam and the field's layout both run through one
//!     `nogui_text.TextMeasurer` that owns the pinned face, so the caret, the
//!     selection mapping and the semantic character geometry are real shaped
//!     numbers with no display server in the process.
//!   * `--native`: the same App, the same model and the same protocol run
//!     inside a REAL `nogui_host.Application` window whose frames are
//!     PRESENTED by `v7_frame.NativeFrame` over `noapi.Surface.initSdl`. The
//!     rasterizer, the text service and the measure seam all come from that
//!     one frame adapter. Every scripted event is pushed onto SDL's queue and
//!     routed by `Application.dispatch`, which binds the window's real native
//!     text-input port. THOSE EVENTS ARE SYNTHETIC: they show the hosted path
//!     carries the same transitions; they are NOT real IME, NOT real
//!     keystrokes and NOT an external keyboard acceptance.
//!
//! Both routes lay out at the SAME logical target, so the geometry in a record
//! means the same thing twice. Each run prints exactly one `TEXT-FIELD` JSON
//! line and a controller diffs two of them. What two records may NOT agree on
//! is only what describes the platform: the mode name, the native text-input
//! status and the presentation counters. Everything else — the authored and
//! model values, the focus identity, both selection unit pairs, the semantic
//! role/state/range and every numeric geometry — must be equal.
//!
//! Run it: `zig build run-parity-text-field` for the real-font headless arm,
//! or `zig build run-parity-text-field-native` for the presented one. Both
//! read five SPIR-V modules from `shaders/`; see the build note at the end.
const std = @import("std");

const nogui = @import("nogui");
const host = @import("nogui_host");
const sdl3 = @import("sdl3");
/// The CPU text service, layout and the measure seam that owns them. This is
/// the window-free route's whole text stack, and it is what every test in this
/// file shapes through.
const cpu = @import("nogui_text");
/// The presented route's frame adapter, glyph engine and Oklab blit.
const v7_frame = @import("v7_frame");
/// The ONE pinned face. Both routes register it and nothing else.
const font_bytes = @import("font_bytes").bytes;

const text_input = nogui.text_input;
const semantics = nogui.semantics;
const Utf16Range = text_input.Utf16Range;
const Selection = text_input.Selection;
const Session = nogui.Session;
const MeasureSource = nogui.layout.MeasureSource;

const TextService = cpu.TextService;
const TextLayout = cpu.TextLayout;
const noapi = v7_frame.noapi;
const scene = v7_frame.scene;

/// The authored logical target. Both routes lay out in exactly this, so a
/// caret or a semantic box means the same number in either record.
const target: noapi.Extent2D = .{ .width = 320, .height = 200 };
const logical: nogui.geometry.WindowSize = .{
    .width = @floatFromInt(target.width),
    .height = @floatFromInt(target.height),
};

const app_id: [:0]const u8 = "dev.nogui.examples.parity.text-field";
const window_title = "nogui editable field";

/// The stable key this scene's editable control authors. The focus identity in
/// a record is this name resolved to a `WidgetId`, never a frame-local id.
const key_field = "field";

/// The bytes the model starts with: two Latin characters, so the scripted
/// commit and the scripted composition both land on real shaped runs.
const authored_field: []const u8 = "ab";

/// The size the field's own layout is shaped at. It is the SAME size the
/// route's measure seam falls back to, so the box the App laid the glyphs out
/// in and the box the field's own layout describes were measured by one rule.
const field_font_size: f32 = @floatFromInt(v7_frame.font_size_px);

/// The caret bar's own width in logical units. Its POSITION and its HEIGHT
/// come from the shaped line box, never from a character count. It is
/// POSITIVE: a candidate window anchored to a zero-width box has nothing to
/// sit on, and the host would have to invent a width before publishing it.
const caret_bar_width: f32 = 1;

/// Host event batches spent holding a presented frame, and the delay between
/// them. Bounds, not timeouts.
const readiness_polls: u32 = 32;
const hold_polls: u32 = 8;
const poll_delay_ms: i64 = 20;
/// Acquires spent waiting for a swapchain that was out of date.
const acquire_polls: u32 = 8;

// ── the route's own shaped layout ───────────────────────────────────────────────
/// ONE layout of the field's current bytes, shaped by the route's own text
/// service, plus the box the App laid that text into.
///
/// There is no second grapheme engine here and no fixed-advance grid. The
/// caret rectangle, the published character boxes, the selection mapping and
/// the boundaries a motion walks are all read from this one layout, so they
/// cannot describe bytes the model no longer holds and cannot disagree with
/// each other. The layout is keyed on the model's revision and is reshaped
/// only when the bytes change, so reading a caret costs no allocation.
const Shaped = struct {
    gpa: std.mem.Allocator,
    service: *TextService,
    font: nogui.text.FontHandle,
    /// Where the App laid the field's own bytes out. The committed tree is
    /// this run's own measurement, so the caret lands in the box that really
    /// holds the glyphs instead of in an authored guess.
    origin: nogui.geometry.WindowPoint = .{ .x = 0, .y = 0 },
    text: ?TextLayout = null,
    revision: u64 = 0,

    fn init(
        self: *Shaped,
        gpa: std.mem.Allocator,
        service: *TextService,
        font: nogui.text.FontHandle,
    ) void {
        self.* = .{ .gpa = gpa, .service = service, .font = font };
    }

    fn releaseLayout(self: *Shaped) void {
        if (self.text) |*layout| layout.deinit();
        self.text = null;
    }

    fn deinit(self: *Shaped) void {
        self.releaseLayout();
        self.* = undefined;
    }

    /// The one layout for `bytes` at the pinned size. Unchanged bytes keep
    /// their shaped runs, so a caret read is a cache hit and not a re-shape,
    /// and a changed value can never be described by the previous shape.
    fn ensure(self: *Shaped, bytes: []const u8, revision: u64) !*const TextLayout {
        if (self.text) |*current| {
            if (self.revision == revision and std.mem.eql(u8, current.content, bytes)) {
                return current;
            }
            current.deinit();
            self.text = null;
        }
        const shaped = try self.service.layout(self.gpa, .{
            .content = bytes,
            .content_generation = revision,
            .style = .{ .font = .{ .handle = self.font, .size = field_font_size } },
            .paragraph = .{ .wrap = .no_wrap },
        });
        self.revision = revision;
        self.text = shaped;
        return &self.text.?;
    }

    /// The current layout, BORROWED rather than copied: the stored value owns
    /// the shaped runs and the cache leases they pin, so a copy would be a
    /// second, unowned view of memory this run already has to release. Null
    /// before the first shaping.
    fn borrowedLayout(self: *const Shaped) ?*const TextLayout {
        if (self.text) |*current| return current;
        return null;
    }

    /// The byte a grapheme reaches forward to. A byte inside a grapheme moves
    /// to that grapheme's end; a byte already on a boundary stays put.
    fn snapForward(self: *const Shaped, byte: usize) usize {
        const layout = self.borrowedLayout() orelse return byte;
        for (layout.graphemes) |item| {
            if (byte > item.start and byte < item.end) return item.end;
        }
        return byte;
    }

    /// The byte a grapheme starts at, for a byte inside one.
    fn snapBackward(self: *const Shaped, byte: usize) usize {
        const layout = self.borrowedLayout() orelse return byte;
        for (layout.graphemes) |item| {
            if (byte > item.start and byte < item.end) return item.start;
        }
        return byte;
    }

    /// The start of the grapheme after `byte`, or the end of the text.
    fn nextCluster(self: *const Shaped, byte: usize) usize {
        const layout = self.borrowedLayout() orelse return byte;
        const next = layout.nextGrapheme(byte) catch return byte;
        return next orelse layout.content.len;
    }

    /// The start of the grapheme before `byte`, or zero.
    fn previousCluster(self: *const Shaped, byte: usize) usize {
        const layout = self.borrowedLayout() orelse return byte;
        const previous = layout.previousGrapheme(byte) catch return byte;
        return previous orelse 0;
    }

    /// The index of the grapheme `byte` sits at or inside. A byte on a shared
    /// boundary resolves to the grapheme BEFORE it, which is what a backward
    /// walk wants. Null for a byte the layout does not publish.
    fn clusterIndexAt(self: *const Shaped, byte: usize) ?usize {
        const layout = self.borrowedLayout() orelse return null;
        if (byte > layout.content.len) return null;
        for (layout.graphemes, 0..) |item, index| {
            if (byte >= item.start and byte <= item.end) return index;
        }
        if (byte == layout.content.len and layout.graphemes.len == 0) return 0;
        return null;
    }

    /// The index of the first grapheme that BEGINS at or after `byte`. A byte
    /// sitting at the trailing edge of a grapheme — the caret at a word's end —
    /// therefore resolves to the grapheme after it, which is what a forward walk
    /// needs: the grapheme the caret is already past must not be walked again.
    fn firstGraphemeAtOrAfter(self: *const Shaped, byte: usize) ?usize {
        const layout = self.borrowedLayout() orelse return null;
        if (byte > layout.content.len) return null;
        for (layout.graphemes, 0..) |item, index| {
            if (item.start >= byte) return index;
        }
        return layout.graphemes.len;
    }

    /// True when this grapheme is one of the separators a word boundary breaks
    /// on. `nextTextSegment` in the same module breaks on exactly these four
    /// bytes, so a word boundary this file walks and a wrap opportunity the
    /// layout took agree on what a separator is.
    fn isSpaceGrapheme(layout: *const TextLayout, index: usize) bool {
        if (index >= layout.graphemes.len) return false;
        return switch (layout.content[layout.graphemes[index].start]) {
            ' ', '\t', '\n', '\r' => true,
            else => false,
        };
    }

    /// The start of the next word, or the end of the text.
    ///
    /// THE LAYOUT HAS NO WORD API: `TextLayout` publishes graphemes and visual
    /// lines and nothing else, and there is no UAX#29 word segmentation in the
    /// text module, so a word boundary is an explicitly documented
    /// whitespace-run rule. What makes it a LAYOUT rule rather than a
    /// substitute one is that it walks the layout's OWN graphemes: a word move
    /// can never land inside a cluster, or inside a codepoint, however the
    /// face chose to shape a separator.
    fn wordForward(self: *const Shaped, byte: usize) usize {
        const layout = self.borrowedLayout() orelse return byte;
        var index = self.firstGraphemeAtOrAfter(byte) orelse return byte;
        while (index < layout.graphemes.len and !Shaped.isSpaceGrapheme(layout, index)) index += 1;
        while (index < layout.graphemes.len and Shaped.isSpaceGrapheme(layout, index)) index += 1;
        if (index >= layout.graphemes.len) return layout.content.len;
        return layout.graphemes[index].start;
    }

    /// The start of the word before `byte`, or zero.
    fn wordBackward(self: *const Shaped, byte: usize) usize {
        const layout = self.borrowedLayout() orelse return byte;
        var index = self.clusterIndexAt(byte) orelse return byte;
        // The whitespace run before the caret goes first, and then the word
        // before that. Each loop tests the grapheme it is ABOUT, not the one
        // before it, so a caret already sitting on a separator skips the
        // separator and lands on the word that precedes it.
        while (index > 0 and Shaped.isSpaceGrapheme(layout, index)) index -= 1;
        while (index > 0 and !Shaped.isSpaceGrapheme(layout, index - 1)) index -= 1;
        if (index >= layout.graphemes.len) return layout.content.len;
        return layout.graphemes[index].start;
    }

    /// The start of the visual line after the one `byte` sits on, or the end
    /// of the text. The layout's OWN line table answers this, so a wrapped
    /// caret and a wrapped line edge cannot disagree.
    fn nextLine(self: *const Shaped, byte: usize) usize {
        const layout = self.borrowedLayout() orelse return byte;
        const position = layout.byteToPosition(byte, .downstream) catch return byte;
        if (position.line + 1 >= layout.lines.len) return layout.content.len;
        return layout.lines[position.line + 1].start;
    }

    /// The start of the visual line `byte` sits on. A caret ALREADY sitting on
    /// a line start steps to the PREVIOUS line's start, so a line edge is not a
    /// dead end.
    fn previousLine(self: *const Shaped, byte: usize) usize {
        const layout = self.borrowedLayout() orelse return byte;
        const position = layout.byteToPosition(byte, .downstream) catch return byte;
        if (position.line >= layout.lines.len) return byte;
        const line = layout.lines[position.line];
        if (position.line > 0 and line.start == byte) return layout.lines[position.line - 1].start;
        return line.start;
    }

    /// The shaped box of one grapheme, in window coordinates.
    fn clusterBox(
        self: *const Shaped,
        layout: *const TextLayout,
        start: usize,
        end: usize,
    ) ?nogui.geometry.WindowRect {
        const from = layout.byteToPosition(start, .downstream) catch return null;
        const to = layout.byteToPosition(end, .downstream) catch return null;
        if (from.line != to.line or from.line >= layout.lines.len) return null;
        const line = layout.lines[from.line];
        return .{
            .x = self.origin.x + from.x,
            .y = self.origin.y + line.y,
            .w = to.x - from.x,
            .h = line.height,
        };
    }

    /// The caret bar at `byte`: its x is the shaped x of that byte, its height
    /// is the laid-out line box and its width is POSITIVE. Null only when the
    /// byte is not on a grapheme boundary this layout knows.
    fn caretRect(self: *const Shaped, byte: usize) ?nogui.geometry.WindowRect {
        const layout = self.borrowedLayout() orelse return null;
        const at = self.snapForward(byte);
        const position = layout.byteToPosition(at, .downstream) catch return null;
        if (position.line >= layout.lines.len) return null;
        const line = layout.lines[position.line];
        return .{
            .x = self.origin.x + position.x,
            .y = self.origin.y + line.y,
            .w = caret_bar_width,
            .h = line.height,
        };
    }

    /// The height of the line the field's text sits on, measured by the same
    /// layout the caret bar uses. Zero before the first shaping.
    fn lineHeight(self: *const Shaped) f32 {
        const layout = self.borrowedLayout() orelse return 0;
        if (layout.lines.len == 0) return 0;
        return layout.lines[0].height;
    }
};

// ── the application-owned model ─────────────────────────────────────────────────
/// The field the application owns. `deinit` is the Session destructor hook,
/// and the core `Manager` never holds its bytes, its selection or its
/// preedit: every operation below is answered from this value.
pub const Field = struct {
    allocator: std.mem.Allocator,
    /// This model's own layout of its current bytes. It is set once, before
    /// the model is handed to the Session, and never replaced.
    shape: ?*Shaped = null,
    text: std.ArrayList(u8) = .empty,
    selection: Selection = .{},
    marked: ?Utf16Range = null,
    /// Bumped by every change to the bytes. The layout is shaped on this
    /// counter, so a layout can never describe text this model no longer
    /// holds, and an unchanged value keeps its shaped runs.
    revision: u64 = 1,

    pub fn deinit(self: *Field, _: *Session) void {
        self.text.deinit(self.allocator);
    }

    pub fn slice(self: *const Field) []const u8 {
        return self.text.items;
    }

    /// This model's own layout, shaped for the bytes it holds right now. Every
    /// geometry answer below comes from this one value.
    fn shaped(self: *const Field) !*Shaped {
        const shape = self.shape orelse return error.NoTextLayout;
        _ = try shape.ensure(self.slice(), self.revision);
        return shape;
    }

    /// The byte span a UTF-16 range names, snapped to the layout's own
    /// grapheme boundaries at both ends, so a range never cuts a composed
    /// character in half. The layout is the authority on where a character
    /// begins, so this file owns no cluster rules of its own.
    fn region(self: *const Field, range: Utf16Range) !struct { start: usize, end: usize } {
        const value = self.slice();
        const low = @min(range.start, range.end);
        const high = @max(range.start, range.end);
        const start = try text_input.utf16ToUtf8(value, low);
        const end = try text_input.utf16ToUtf8(value, high);
        const shape = try self.shaped();
        return .{ .start = shape.snapBackward(start), .end = shape.snapForward(end) };
    }

    fn unit(self: *const Field, byte: usize) !usize {
        return text_input.utf8ToUtf16(self.slice(), byte);
    }

    /// The byte offset the selection's moving end names, snapped to a grapheme.
    fn caretByte(self: *Field) !usize {
        const cursor = self.selection.cursor();
        return (try self.region(.{ .start = cursor, .end = cursor })).start;
    }

    fn splice(self: *Field, start: usize, end: usize, text: []const u8) !void {
        const value = self.slice();
        var next: std.ArrayList(u8) = .empty;
        errdefer next.deinit(self.allocator);
        try next.appendSlice(self.allocator, value[0..start]);
        try next.appendSlice(self.allocator, text);
        try next.appendSlice(self.allocator, value[end..]);
        self.text.deinit(self.allocator);
        self.text = next;
        self.revision += 1;
    }

    /// Replace the model's whole value, the way an application loading a
    /// document would. The revision moves with the bytes, so the next read
    /// reshapes rather than describing the old string.
    pub fn setText(self: *Field, value: []const u8) !void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.allocator, value);
        self.marked = null;
        self.selection = .{};
        self.revision += 1;
    }

    /// A null range means the marked range, else the selection. This is the
    /// one rule that makes a platform commit replace its own preedit.
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
    const region = try field.region(range);
    served.* = .{
        .start = try text_input.utf8ToUtf16(field.slice(), region.start),
        .end = try text_input.utf8ToUtf16(field.slice(), region.end),
    };
    return try allocator.dupe(u8, field.slice()[region.start..region.end]);
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
    const shape = try field.shaped();
    const forward = request.direction == .forward;
    const at = try field.caretByte();
    // Every arm answers in BYTES off the layout, and the conversion to the
    // protocol's unit happens once, below. Home and End arrive as `.line`, so
    // a field that answered them with one grapheme would leave a person at the
    // end of the second character of a long line.
    const next_byte: usize = switch (request.unit) {
        .grapheme => if (forward) shape.nextCluster(at) else shape.previousCluster(at),
        .line => if (forward) shape.nextLine(at) else shape.previousLine(at),
        .word => if (forward) shape.wordForward(at) else shape.wordBackward(at),
        .document => if (forward) field.slice().len else 0,
    };
    const next = try field.unit(next_byte);
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

fn eraseText(field: *Field, _: *anyopaque, request: text_input.Erase) anyerror!void {
    const shape = try field.shaped();
    const at = try field.caretByte();
    const range = if (request.extend or !field.selection.range.isEmpty())
        field.selection.range
    else if (request.backward)
        Utf16Range{ .start = try field.unit(shape.previousCluster(at)), .end = try field.unit(at) }
    else
        Utf16Range{ .start = try field.unit(at), .end = try field.unit(shape.nextCluster(at)) };
    const region = try field.region(range);
    try field.splice(region.start, region.end, "");
    const caret = try field.unit(region.start);
    field.marked = null;
    field.selection = .{ .range = .{ .start = caret, .end = caret } };
}

fn replaceText(field: *Field, _: *anyopaque, range: ?Utf16Range, text: []const u8) anyerror!void {
    const region = try field.region(field.target(range));
    try field.splice(region.start, region.end, text);
    const caret = try field.unit(region.start + text.len);
    field.marked = null;
    field.selection = .{ .range = .{ .start = caret, .end = caret } };
}

fn replaceAndMark(
    field: *Field,
    _: *anyopaque,
    range: ?Utf16Range,
    text: []const u8,
    inside: ?Utf16Range,
) anyerror!void {
    const region = try field.region(field.target(range));
    try field.splice(region.start, region.end, text);
    const base = try field.unit(region.start);
    // `marked` is a UTF-16 range and `base` is a UTF-16 offset, so its end is
    // the inserted text's length IN ITS OWN UNITS. The UTF-8 byte count names
    // a different position for anything but ASCII.
    const length = try text_input.utf16Length(text);
    field.marked = if (text.len == 0) null else Utf16Range{ .start = base, .end = base + length };
    const caret = if (inside) |value| base + @min(value.end, length) else base + length;
    field.selection = .{ .range = .{ .start = caret, .end = caret } };
}

fn unmarkText(field: *Field, _: *anyopaque) anyerror!void {
    field.marked = null;
}

fn caretGeometry(field: *const Field, _: *anyopaque, range: Utf16Range) anyerror!?text_input.Caret {
    const shape = try field.shaped();
    const byte = try text_input.utf16ToUtf8(field.slice(), range.end);
    const area = shape.caretRect(byte) orelse return null;
    // The candidate window hangs at this caret's LEFT edge, so the whole shaped
    // x is already folded into the rectangle's origin and the offset inside it
    // is zero. It is the same layout, the same line box and the same byte the
    // painted caret came from.
    return .{ .area = area, .cursor = 0 };
}

/// The character a point names, measured by the layout's own hit test: the line
/// whose box holds the point's y, then the grapheme edge nearest to the point's
/// x on that line. A selection mapping over real shaped advances, not a column
/// count. A point outside every line clamps to the nearest one, which is what a
/// click above or below a single-line field should do.
fn indexAtPoint(field: *const Field, _: *anyopaque, point: nogui.geometry.WindowPoint) anyerror!?usize {
    const shape = try field.shaped();
    const layout = shape.borrowedLayout() orelse return null;
    if (layout.lines.len == 0) return 0;
    // The line whose box holds the point's y. A point in the gap between two
    // lines, or outside every box, takes the NEAREST line rather than failing:
    // a click above the first line lands at the start of the first, and a click
    // below the last lands at the end of the last, which is what a click in a
    // single-line field should do.
    var line_index: usize = 0;
    for (layout.lines, 0..) |line, index| {
        const top = shape.origin.y + line.y;
        if (point.y < top) break;
        if (point.y <= top + line.height) {
            line_index = index;
            break;
        }
        line_index = index;
    }
    const position = layout.positionToByte(line_index, point.x - shape.origin.x) catch return null;
    return layout.byteToUtf16(position.byte) catch null;
}

pub fn fieldOps() text_input.Ops {
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

/// An in-memory clipboard with the same port shape as the W18 system service.
pub const MemoryClipboard = struct {
    stored: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    /// Set to make the next read report an absent or failing service.
    unavailable: bool = false,
    failing: bool = false,

    pub fn deinit(self: *MemoryClipboard) void {
        self.stored.deinit(self.allocator);
    }

    pub fn port(self: *MemoryClipboard) text_input.Clipboard {
        return .{ .user = self, .read = read, .write = write };
    }

    pub fn set(self: *MemoryClipboard, value: []const u8) !void {
        self.stored.clearRetainingCapacity();
        try self.stored.appendSlice(self.allocator, value);
    }

    fn read(allocator: std.mem.Allocator, user: *anyopaque) text_input.ClipboardRead {
        const self: *MemoryClipboard = @ptrCast(@alignCast(user));
        if (self.unavailable) return .unavailable;
        if (self.failing) return .failed;
        if (self.stored.items.len == 0) return .empty;
        return .{ .text = allocator.dupe(u8, self.stored.items) catch return .failed };
    }

    fn write(user: *anyopaque, value: []const u8) text_input.ClipboardWrite {
        const self: *MemoryClipboard = @ptrCast(@alignCast(user));
        if (self.failing) return .failed;
        self.stored.clearRetainingCapacity();
        self.stored.appendSlice(self.allocator, value) catch return .failed;
        return .written;
    }
};

/// The consumer handle an App keeps next to its field model.
///
/// Every text operation below is asked of the App's OWN manager — the one
/// `App.registerTextEndpoint` binds the endpoint to, and the one both routes
/// route their events through. `manager` is that value BY REFERENCE: this file
/// builds no second text runtime, so there is no second runtime that could
/// agree with the routes today and disagree tomorrow. The App owns it, retires
/// it in `App.deinit`, and this consumer only borrows it for the whole run.
pub const Consumer = struct {
    gpa: std.mem.Allocator,
    session: *Session,
    /// The App's own text manager, borrowed. Never a manager of this file's
    /// making.
    manager: *text_input.Manager,
    clipboard: MemoryClipboard,
    field_id: nogui.WidgetId,
    owner: nogui.Model(Field),
    /// Choose before focus; registration copies the policy into the endpoint.
    policy: text_input.Policy = .{},
    /// The ONE shaped layout of the field's bytes. It lives here, not in the
    /// model, so the endpoint's `user` pointer is a stable address for the
    /// whole run.
    shape: Shaped = undefined,
    user: *anyopaque = undefined,

    /// `service` is the route's own text service and `font` the face it
    /// registered first, so every answer this field gives is measured by the
    /// rules that shaped or rasterized its glyphs. The service MUST outlive
    /// this consumer: the layout pins cache runs inside it.
    pub fn init(
        self: *Consumer,
        gpa: std.mem.Allocator,
        app: *nogui.App,
        service: *TextService,
        font: nogui.text.FontHandle,
        field_id: nogui.WidgetId,
        initial: []const u8,
    ) !void {
        self.* = .{
            .gpa = gpa,
            .session = app.session,
            .manager = app.textInputManager(),
            .clipboard = .{ .allocator = gpa },
            .field_id = field_id,
            .owner = undefined,
        };
        self.shape.init(gpa, service, font);
        var value: Field = .{ .allocator = gpa, .shape = &self.shape };
        errdefer value.text.deinit(gpa);
        try value.text.appendSlice(gpa, initial);
        // A fresh field has the caret at the end of its own text.
        const units = try text_input.utf16Length(value.slice());
        value.selection = .{ .range = .{ .start = units, .end = units } };
        self.owner = try self.session.create(Field, &value);
        self.user = self;
    }

    /// Give the App's own manager a clipboard if nothing else gave it one.
    ///
    /// A window the host opened already carries the real W18 service, and that
    /// service stays: this example never replaces a system clipboard with a
    /// stand-in. A window-free App bound nothing at all, so a routed `copy`,
    /// `cut` or `paste` would answer `unavailable` forever. This is where the
    /// in-memory service is installed, on the manager that holds the
    /// registered endpoint, so the routes and every caller reach one service
    /// instead of a clipboard that only a test could find.
    pub fn bindClipboard(self: *Consumer) void {
        if (self.manager.clipboard != null) return;
        self.manager.clipboard = self.clipboard.port();
    }

    /// Release the model, then the shaped layout that described it, then the
    /// clipboard. The layout holds leases in the ROUTE'S OWN text service, so
    /// this must run while that service is still alive. A session that refuses
    /// the model release is reported rather than swallowed, and the layout is
    /// released on that path too rather than pinned for good. The App's
    /// manager is NOT retired here: it belongs to the App, which clears its
    /// endpoint before this runs and destroys it right after.
    pub fn deinit(self: *Consumer) !void {
        errdefer {
            self.shape.deinit();
            self.clipboard.deinit();
        }
        try self.session.release(Field, &self.owner);
        self.shape.deinit();
        self.clipboard.deinit();
    }

    /// Focus the field on the App's own manager. This is the binding an
    /// application makes when its editable control takes focus, and it is what
    /// starts native text input on the route that has a native port.
    pub fn focus(self: *Consumer, app: *nogui.App) void {
        app.registerTextEndpoint(.{
            .id = self.field_id,
            .owner = self.owner.weak().erase(),
            .ops = fieldOps(),
            .user = self.user,
            .policy = self.policy,
        });
    }

    /// Read the field for painting or a test. `handler` runs inside the Session
    /// borrow and must not retain the model pointer.
    pub fn read(self: *Consumer, comptime handler: anytype, context: anytype) !void {
        try self.session.read(Field, self.owner, context, handler);
    }

    /// Update the field from application code. Programmatic edits go through
    /// the same borrow the protocol uses.
    pub fn update(self: *Consumer, comptime handler: anytype, context: anytype) !void {
        try self.session.update(Field, self.owner, context, handler);
        self.manager.invalidateGeometry();
    }

    /// Read the field while a frame is being built for `window`. This is the
    /// draw-scoped read: it records the model as a dependency of that window,
    /// so an edit through the protocol asks that window to repaint.
    pub fn readWindow(
        self: *Consumer,
        window: u64,
        comptime handler: anytype,
        context: anytype,
    ) !void {
        try self.session.readWindow(Field, window, self.owner, context, handler);
    }
};

/// Readers for the example's own drivers. A real view reads the model in `draw`.
const ReadText = struct {
    out: []const u8 = "",
    fn read(field: *const Field, context: *anyopaque) anyerror!void {
        const typed: *ReadText = @ptrCast(@alignCast(context));
        typed.out = field.slice();
    }
};

const SelectAll = struct {
    fn apply(field: *Field, _: *anyopaque) anyerror!void {
        const units = try text_input.utf16Length(field.slice());
        field.selection = .{ .range = .{ .start = 0, .end = units } };
    }
};

const Clear = struct {
    fn apply(field: *Field, _: *anyopaque) anyerror!void {
        try field.setText("");
    }
};

/// One scripted step, as an outside observer sees the field right after it.
/// The scenario records these in both routes, so the comparison is of
/// transitions and not only of the state the last step happened to leave.
pub const Step = struct {
    /// How much text one step can record. The scripted field stays far below
    /// this, and a value that would not fit is refused rather than compared as
    /// a truncated prefix.
    pub const value_capacity = 64;
    /// The step the script names, so a failure says which one diverged.
    name: []const u8 = "",
    value: [value_capacity]u8 = undefined,
    value_len: usize = 0,
    selection_start: usize = 0,
    selection_end: usize = 0,
    selection_reversed: bool = false,
    has_preedit: bool = false,
    focus_is_field: bool = false,

    pub fn valueSlice(self: *const Step) []const u8 {
        return self.value[0..self.value_len];
    }

    /// Everything but the name, so two steps of the same script compare by
    /// value and a difference never hides behind a matching label.
    pub fn sameState(self: *const Step, other: *const Step) bool {
        return std.mem.eql(u8, self.valueSlice(), other.valueSlice()) and
            self.selection_start == other.selection_start and
            self.selection_end == other.selection_end and
            self.selection_reversed == other.selection_reversed and
            self.has_preedit == other.has_preedit and
            self.focus_is_field == other.focus_is_field;
    }
};

/// The steps the editable script records. Both routes run the same script, so
/// both produce this many steps in this order.
pub const trace_capacity = 8;

/// One window's editable state, as an outside observer can see it. Both routes
/// produce this, and a controller compares the two records field by field.
pub const FieldReport = struct {
    /// The model text after the whole sequence.
    value: [64]u8 = undefined,
    value_len: usize = 0,
    /// The model's own selection, in the UTF-16 units the protocol uses.
    selection_start: usize = 0,
    selection_end: usize = 0,
    selection_reversed: bool = false,
    /// A preedit is still marked on the model.
    has_preedit: bool = false,
    /// The App's committed focus is the editable target.
    focus_is_field: bool = false,
    /// The App's own text manager holds the registered endpoint.
    endpoint_live: bool = false,
    /// Native text input is running through the window's own port. Only the
    /// presented route can report this, and saying so is part of the record.
    native_running: bool = false,
    /// The caret box the endpoint measured, in logical window units, plus the
    /// caret's own offset inside it. This is what the host hands SDL as the
    /// candidate rectangle, so the two can be compared to each other.
    caret: nogui.geometry.WindowRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    caret_cursor: f32 = 0,
    /// The candidate rectangle and caret offset SDL itself holds for this
    /// window, read back from the platform after the route published its frame.
    /// Null in the window-free run, which has no window to ask.
    sdl_area: ?sdl3.rect.IRect = null,
    sdl_cursor: i32 = 0,
    /// The line box the field's own text sits on, in window units. A
    /// controller compares these numbers, not a line count.
    line_box: nogui.geometry.WindowRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// How many graphemes the layout shaped and the shaped advance of the
    /// FIRST TWO of them. A fixed-advance grid reports the same advance for any
    /// two characters; a real face does not.
    grapheme_count: usize = 0,
    first_advance: f32 = 0,
    second_advance: f32 = 0,
    /// The ink width the layout measured for the field's own text, and the
    /// shaped x its last grapheme ends at. Both are measurements a grid cannot
    /// reproduce.
    ink_width: f32 = 0,
    /// The sum of every grapheme's shaped advance. The layout's own line width
    /// must equal it, so a report carries two readings of one measurement and a
    /// controller needs no arithmetic of its own.
    advance_sum: f32 = 0,
    last_grapheme_end_x: f32 = 0,
    /// Every recorded step, in script order.
    steps: [trace_capacity]Step = undefined,
    step_count: usize = 0,
    /// Events SDL delivered to this process that named none of this run's
    /// windows, and that the scenario therefore left alone. It describes the
    /// machine, not the field, so it is reported and never compared.
    ambient_events: usize = 0,
    /// Frames the presented route actually put on the swapchain. Zero on the
    /// window-free route, which created no device.
    frames_presented: u32 = 0,
    /// Semantic results: the field is published as an addressable text input.
    published_nodes: usize = 0,
    semantic_role: u8 = 0,
    semantic_name_len: usize = 0,
    semantic_value_len: usize = 0,
    /// The published selection, in UTF-8 byte offsets like the wire format.
    semantic_anchor: usize = 0,
    semantic_focus: usize = 0,
    semantic_name: [16]u8 = undefined,
    semantic_value: [64]u8 = undefined,
    semantic_addressable: bool = false,
    semantic_replaceable: bool = false,
    semantic_focusable: bool = false,
    semantic_focused: bool = false,

    pub fn valueSlice(self: *const FieldReport) []const u8 {
        return self.value[0..self.value_len];
    }

    pub fn semanticNameSlice(self: *const FieldReport) []const u8 {
        return self.semantic_name[0..self.semantic_name_len];
    }

    pub fn semanticValueSlice(self: *const FieldReport) []const u8 {
        return self.semantic_value[0..self.semantic_value_len];
    }

    /// The first recorded step whose state differs, or null when the two runs
    /// took the same transitions. The name it returns is the script's own.
    pub fn traceDiff(self: *const FieldReport, other: *const FieldReport) ?[]const u8 {
        if (self.step_count != other.step_count) return "recorded step count";
        for (self.steps[0..self.step_count], other.steps[0..other.step_count]) |a, b| {
            if (!a.sameState(&b)) return a.name;
        }
        return null;
    }

    /// Compare two reports, naming the FIRST field that differs. This is the
    /// controller's rule, kept beside the record it reads so a controller needs
    /// no rule of its own. Platform-only fields — the mode, the native port
    /// status, SDL's stored rectangle, the ambient count and the presented
    /// frame count — are deliberately NOT compared here.
    pub fn diff(self: *const FieldReport, other: *const FieldReport) ?[]const u8 {
        if (!std.mem.eql(u8, self.valueSlice(), other.valueSlice())) return "model value";
        if (self.selection_start != other.selection_start) return "selection start";
        if (self.selection_end != other.selection_end) return "selection end";
        if (self.selection_reversed != other.selection_reversed) return "selection direction";
        if (self.has_preedit != other.has_preedit) return "preedit state";
        if (self.focus_is_field != other.focus_is_field) return "committed focus";
        if (self.endpoint_live != other.endpoint_live) return "endpoint registration";
        if (self.caret.x != other.caret.x) return "caret x";
        if (self.caret.y != other.caret.y) return "caret y";
        if (self.caret.w != other.caret.w) return "caret width";
        if (self.caret.h != other.caret.h) return "caret height";
        if (self.caret_cursor != other.caret_cursor) return "caret offset";
        if (self.line_box.x != other.line_box.x) return "line box x";
        if (self.line_box.y != other.line_box.y) return "line box y";
        if (self.line_box.w != other.line_box.w) return "line box width";
        if (self.line_box.h != other.line_box.h) return "line box height";
        if (self.grapheme_count != other.grapheme_count) return "grapheme count";
        if (self.first_advance != other.first_advance) return "first glyph advance";
        if (self.second_advance != other.second_advance) return "second glyph advance";
        if (self.ink_width != other.ink_width) return "ink width";
        if (self.advance_sum != other.advance_sum) return "advance sum";
        if (self.last_grapheme_end_x != other.last_grapheme_end_x) return "last glyph end";
        if (self.traceDiff(other)) |step| return step;
        if (self.published_nodes != other.published_nodes) return "published node count";
        if (self.semantic_role != other.semantic_role) return "semantic role";
        if (!std.mem.eql(u8, self.semanticNameSlice(), other.semanticNameSlice())) return "semantic name";
        if (!std.mem.eql(u8, self.semanticValueSlice(), other.semanticValueSlice())) return "semantic value";
        if (self.semantic_anchor != other.semantic_anchor) return "semantic selection anchor";
        if (self.semantic_focus != other.semantic_focus) return "semantic selection focus";
        if (self.semantic_addressable != other.semantic_addressable) return "semantic addressability";
        if (self.semantic_replaceable != other.semantic_replaceable) return "semantic replace action";
        if (self.semantic_focusable != other.semantic_focusable) return "semantic focusable";
        if (self.semantic_focused != other.semantic_focused) return "semantic focused state";
        return null;
    }
};

/// The view a window mounts: the model's own bytes plus the keyed control that
/// owns the field's text endpoint. It is deliberately the same in both routes,
/// so any difference the comparison reports comes from the route and not from
/// the view.
const FieldView = struct {
    /// The window this view draws for. A model read during the frame is
    /// recorded as a dependency of THIS window; without it an edit would ask
    /// for no repaint and the route's demand loop would never run one.
    window: u64,
    /// Null only for the first frame, before the keyed identity exists and the
    /// model has been created.
    owner: ?*Consumer = null,
    /// The field text this window last painted, copied out of the borrow.
    text: [64]u8 = undefined,
    text_len: usize = 0,
    activations: u32 = 0,

    pub fn draw(self: *FieldView, ctx: *nogui.DrawCtx) !void {
        if (self.owner) |consumer| {
            var state: ReadState = .{};
            try consumer.readWindow(self.window, ReadState.read, &state);
            self.text_len = @min(state.slice.len, self.text.len);
            @memcpy(self.text[0..self.text_len], state.slice[0..self.text_len]);
        }
        // The field's own text is painted from the frame arena, so the window
        // shows the model rather than a placeholder. Its measured box is what
        // the field's own layout is anchored to, so the caret lands where the
        // glyphs really are.
        const painted = try ctx.arena.alloc(u8, self.text_len);
        @memcpy(painted, self.text[0..self.text_len]);
        _ = try ctx.label(.{ .text = painted });
        _ = try ctx.button(.{
            .key = @as(nogui.ComponentKey, .{ .static = key_field }),
            .label = "Editable field",
            .on_click = FieldView.activate,
        });
    }

    fn activate(self: *FieldView) void {
        self.activations += 1;
    }
};

/// The annotator that publishes the field's live value and selection onto its
/// control. The app supplies this, exactly as it would for a real accessibility
/// tree: the core knows the control, not the model behind it.
const FieldAnnotation = struct {
    field_id: nogui.WidgetId,
    /// The values the model held when the snapshot was staged. A snapshot
    /// borrows its slices, so the annotation copies rather than pointing at a
    /// model that a later keystroke will edit.
    value: [64]u8 = undefined,
    value_len: usize = 0,
    lengths: [64]u8 = undefined,
    count: usize = 0,
    positions: [64]f32 = undefined,
    widths: [64]f32 = undefined,
    anchor: usize = 0,
    focus: usize = 0,

    /// Copy the model into annotation-owned storage and record the selection in
    /// the UTF-8 byte offsets the semantic wire format uses.
    fn capture(self: *FieldAnnotation, field: *const Field) !void {
        const value = field.slice();
        if (value.len > self.value.len) return error.ModelValueTooLong;
        self.value_len = value.len;
        @memcpy(self.value[0..self.value_len], value[0..self.value_len]);
        // One entry per GRAPHEME the route's layout shaped: the byte length it
        // occupies, the x it starts at, and the advance it takes. These are the
        // runs the route rasterized, so a selection published against them is
        // addressable in the same coordinates the glyphs were drawn in.
        const shape = try field.shaped();
        const layout = shape.borrowedLayout() orelse return error.NoTextLayout;
        self.count = 0;
        for (layout.graphemes) |item| {
            if (self.count >= self.lengths.len) return error.ModelValueTooLong;
            const box = shape.clusterBox(layout, item.start, item.end) orelse
                return error.TextLayoutRejectedAGrapheme;
            self.lengths[self.count] = @intCast(item.end - item.start);
            self.positions[self.count] = box.x;
            self.widths[self.count] = box.w;
            self.count += 1;
        }
        self.anchor = try text_input.utf16ToUtf8(value, field.selection.anchor());
        self.focus = try text_input.utf16ToUtf8(value, field.selection.cursor());
    }

    fn annotate(raw: *anyopaque, node: *const nogui.WidgetNode, draft: *semantics.Draft) anyerror!void {
        const self: *FieldAnnotation = @ptrCast(@alignCast(raw));
        const id = node.widget_id orelse return;
        if (!id.eql(self.field_id)) return;
        // The control is an ordinary keyed widget; the application publishes
        // what the model behind it holds, exactly as it would for a real
        // accessibility tree.
        draft.role = .text_input;
        draft.name = "Editable field";
        draft.text = .{
            .value = self.value[0..self.value_len],
            .selection = .{ .anchor = self.anchor, .focus = self.focus },
            .character_lengths = self.lengths[0..self.count],
            .character_positions = self.positions[0..self.count],
            .character_widths = self.widths[0..self.count],
        };
    }
};

/// Read the model's own selection and text for a report.
const ReadState = struct {
    value_len: usize = 0,
    selection_start: usize = 0,
    selection_end: usize = 0,
    /// The selection as the protocol carries it, direction included.
    selection: Selection = .{},
    has_preedit: bool = false,
    slice: []const u8 = "",

    fn read(field: *const Field, context: *anyopaque) anyerror!void {
        const self: *ReadState = @ptrCast(@alignCast(context));
        self.slice = field.slice();
        self.value_len = field.slice().len;
        self.selection_start = field.selection.range.start;
        self.selection_end = field.selection.range.end;
        self.selection = field.selection;
        self.has_preedit = field.marked != null;
    }
};

/// True when the grapheme starting at `start` is a hard line break. The layout
/// excludes these from its own ink width, so an advance sum compared against
/// that width must exclude them the same way or the two readings disagree for a
/// reason that has nothing to do with the glyphs.
fn isHardBreakByte(content: []const u8, start: usize) bool {
    if (start >= content.len) return false;
    return content[start] == '\n' or content[start] == '\r';
}

/// How many graphemes the route's layout shaped, the shaped advance and box of
/// the first few of them, and the ink width the layout measured. A report
/// carries these numbers so a controller compares a real measurement rather
/// than recomputing one.
const ReadGeometry = struct {
    capacity: usize = 3,
    /// How many graphemes the layout shaped IN TOTAL. `recorded` is only how
    /// many of them fit in the fixed arrays below, so a report never truncates
    /// the count while it samples the first few advances.
    total: usize = 0,
    recorded: usize = 0,
    advances: [3]f32 = .{ 0, 0, 0 },
    lefts: [3]f32 = .{ 0, 0, 0 },
    rights: [3]f32 = .{ 0, 0, 0 },
    ink_width: f32 = 0,
    line_height: f32 = 0,
    line_top: f32 = 0,
    line_width: f32 = 0,
    /// The sum of EVERY grapheme's shaped advance, not only the recorded ones.
    /// The layout's own line width must equal this, so a report can compare two
    /// readings of one measurement without writing a rule of its own.
    advance_sum: f32 = 0,
    /// Where the shaped x of the LAST grapheme's trailing edge landed in window
    /// coordinates, over every grapheme and not only the recorded ones. A caret
    /// at the end of the text sits here.
    last_right: f32 = 0,
    ok: bool = false,

    fn read(field: *const Field, context: *anyopaque) anyerror!void {
        const self: *ReadGeometry = @ptrCast(@alignCast(context));
        const shape = try field.shaped();
        const layout = shape.borrowedLayout() orelse return;
        self.total = layout.graphemes.len;
        self.recorded = @min(self.total, self.capacity);
        for (0..self.recorded) |index| {
            const item = layout.graphemes[index];
            self.advances[index] = item.width;
            self.lefts[index] = shape.origin.x + item.x;
            self.rights[index] = self.lefts[index] + item.width;
        }
        self.ink_width = layout.inkWidth();
        // The same sum the layout's own ink probe reports: a hard-break grapheme
        // carries no ink and is excluded here exactly as the layout excludes it,
        // so this sum and the line width it is compared against are two readings
        // of one measurement rather than two different rules.
        for (layout.graphemes) |item| {
            if (isHardBreakByte(layout.content, item.start)) continue;
            self.advance_sum += item.width;
        }
        self.line_height = shape.lineHeight();
        if (layout.graphemes.len > 0) {
            const last = layout.graphemes[layout.graphemes.len - 1];
            self.last_right = shape.origin.x + last.x + last.width;
        }
        if (layout.lines.len > 0) {
            self.line_top = shape.origin.y + layout.lines[0].y;
            self.line_width = layout.lines[0].width;
        }
        self.ok = true;
    }
};

/// Fill a report from the live model, the App's focus, the manager's state and
/// the published snapshot. Both routes call this same function, so the
/// comparison cannot differ because it measured different things.
fn buildReport(
    app: *nogui.App,
    consumer: *Consumer,
    publisher: *semantics.Publisher,
) !FieldReport {
    var report: FieldReport = .{};
    var state: ReadState = .{};
    try consumer.read(ReadState.read, &state);
    const taken = @min(state.value_len, report.value.len);
    @memcpy(report.value[0..taken], state.slice[0..taken]);
    report.value_len = taken;
    report.selection_start = state.selection_start;
    report.selection_end = state.selection_end;
    report.selection_reversed = state.selection.reversed;
    report.has_preedit = state.has_preedit;

    const focus = app.focus_manager.current;
    report.focus_is_field = if (focus) |current| current.eql(consumer.field_id) else false;
    const manager = app.textInputManager();
    report.endpoint_live = manager.focusedId() != null;
    if (try manager.caretGeometry()) |caret| {
        report.caret = caret.area;
        report.caret_cursor = caret.cursor;
    }

    var geometry: ReadGeometry = .{};
    try consumer.read(ReadGeometry.read, &geometry);
    if (geometry.ok) {
        report.grapheme_count = geometry.total;
        report.first_advance = geometry.advances[0];
        report.second_advance = geometry.advances[1];
        report.ink_width = geometry.ink_width;
        report.advance_sum = geometry.advance_sum;
        report.last_grapheme_end_x = geometry.last_right;
        report.line_box = .{
            .x = consumer.shape.origin.x,
            .y = geometry.line_top,
            .w = geometry.line_width,
            .h = geometry.line_height,
        };
    }

    const snapshot = publisher.snapshot() orelse return error.MissingSemanticSnapshot;
    report.published_nodes = snapshot.count();
    const identity = semantics.nodeId(consumer.field_id, .self_node);
    const entry = snapshot.node(identity) orelse return error.MissingSemanticField;
    report.semantic_role = @backingInt(entry.role);
    report.semantic_name_len = @min(entry.name.len, report.semantic_name.len);
    @memcpy(report.semantic_name[0..report.semantic_name_len], entry.name[0..report.semantic_name_len]);
    const text = entry.text orelse return error.MissingSemanticText;
    report.semantic_value_len = @min(text.value.len, report.semantic_value.len);
    @memcpy(
        report.semantic_value[0..report.semantic_value_len],
        text.value[0..report.semantic_value_len],
    );
    if (text.selection) |selection| {
        report.semantic_anchor = selection.anchor;
        report.semantic_focus = selection.focus;
    }
    report.semantic_addressable = text.addressable();
    report.semantic_replaceable = entry.actions.has(.replace_selected_text);
    report.semantic_focusable = entry.states.focusable;
    report.semantic_focused = entry.states.focused;
    return report;
}

// ── the scenario ───────────────────────────────────────────────────────────────
/// One Session, one App, one view, one publisher, one model and one endpoint.
/// The two routes build exactly this and differ only in how a frame is drawn
/// and how an event is carried.
const Editable = struct {
    gpa: std.mem.Allocator,
    session: *Session,
    app: *nogui.App,
    view: FieldView,
    /// Null until `runSequence` creates the model from the identity the first
    /// frame produced, so the first frame publishes no field text. Heap-owned
    /// so the endpoint's user pointer stays valid for the whole run.
    consumer: ?*Consumer = null,
    publisher: semantics.Publisher,
    annotation: FieldAnnotation,
    tick: u32 = 0,
    field_id: nogui.WidgetId = .{ .owner = 0, .slot = 0, .generation = 0 },
    /// The steps the script has recorded, in order.
    steps: [trace_capacity]Step = undefined,
    step_count: usize = 0,

    /// Allocate the session, the App and the mounted view. The model needs the
    /// keyed identity the first frame produces, so it is created later.
    pub fn create(gpa: std.mem.Allocator) !*Editable {
        const self = try gpa.create(Editable);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .session = undefined,
            .app = undefined,
            .view = .{ .window = 0 },
            .consumer = null,
            .publisher = semantics.Publisher.init(gpa),
            .annotation = .{ .field_id = .{ .owner = 0, .slot = 0, .generation = 0 } },
        };
        errdefer self.publisher.deinit();
        self.session = try gpa.create(Session);
        errdefer gpa.destroy(self.session);
        self.session.* = try Session.init(gpa);
        self.app = try gpa.create(nogui.App);
        errdefer gpa.destroy(self.app);
        self.app.* = try nogui.App.init(gpa, self.session);
        // The view learns which window it draws for, so a model read during a
        // frame is recorded against that window and not a placeholder.
        self.view.window = self.app.window;
        try self.app.mountRoot(FieldView, &self.view);
        return self;
    }

    /// Commit one frame and publish that frame's semantics. `gpu` is the
    /// presented route's live recording; null on the window-free route, which
    /// has no device to record into. Both routes share this, so a snapshot
    /// always describes the frame it was staged from.
    fn commit(self: *Editable, gpu: ?*nogui.GpuFrame) !nogui.FrameOutput {
        self.tick += 1;
        const size: nogui.widget.Size = .{ .width = logical.width, .height = logical.height };
        const output = if (gpu) |frame|
            try self.app.frameWithGpuAtTime(self.tick, 0, size, frame)
        else
            try self.app.frame(self.tick, size);
        // The frame's own debug JSON belongs to this run's allocator; the
        // CALLER frees it, because a caller that renders the frame still needs
        // its tree after this returns.
        if (self.consumer) |consumer| {
            // The field's text box is the box the App laid THIS frame's model
            // bytes out into, so the shaped layout is anchored where the glyphs
            // really are instead of at an authored guess.
            const box = try self.textBox();
            consumer.shape.origin = .{ .x = box.x, .y = box.y };
            try self.capture(&self.annotation);
        }
        try self.publisher.stage(.{
            .tree = output.tree,
            .focus = output.focus,
            .generation = self.app.frame_generation,
            .surface = .{ .width = logical.width, .height = logical.height },
            .window_name = window_title,
            .annotator = .{
                .context = &self.annotation,
                .annotate = FieldAnnotation.annotate,
            },
        });
        self.publisher.commit();
        return output;
    }

    /// The box the model's own bytes were laid out into: the label whose text
    /// IS the model value, so this is the real text box the route measured, not
    /// a guess at which node it was.
    fn textBox(self: *Editable) !nogui.widget.Rect {
        const tree = self.app.tree_ptr orelse return error.NoCommittedTree;
        const value = self.view.text[0..self.view.text_len];
        for (tree.nodes.items) |node| {
            if (node.kind != .label) continue;
            if (!std.mem.eql(u8, node.kind.label.text, value)) continue;
            return nogui.widget.visualContentRect(tree, node.id);
        }
        return error.MissingValueNode;
    }

    /// Copy the model's live value and selection into annotation storage.
    pub fn capture(self: *Editable, annotation: *FieldAnnotation) !void {
        const consumer = self.consumer orelse return error.NoFieldModel;
        var bridge: CaptureAnnotation = .{ .annotation = annotation };
        try self.session.read(Field, consumer.owner, &bridge, CaptureAnnotation.read);
    }

    fn report(self: *Editable) !FieldReport {
        const consumer = self.consumer orelse return error.NoFieldModel;
        return buildReport(self.app, consumer, &self.publisher);
    }

    /// Record one scripted step as an outside observer sees the field: the
    /// model's own text, selection, direction and preedit, plus the App's
    /// committed focus. Both routes call this from the same script, so the two
    /// traces are step for step the same work and any difference is a difference
    /// in how the event was carried, not in what was asked for.
    fn record(self: *Editable, name: []const u8) !void {
        const consumer = self.consumer orelse return error.NoFieldModel;
        if (self.step_count >= self.steps.len) return error.TooManyTraceSteps;
        var state: ReadState = .{};
        try consumer.read(ReadState.read, &state);
        const focus = self.app.focus_manager.current;
        if (state.slice.len > Step.value_capacity) return error.TraceValueTooLong;
        var step: Step = .{
            .name = name,
            .value_len = state.slice.len,
            .selection_start = state.selection_start,
            .selection_end = state.selection_end,
            .selection_reversed = state.selection.reversed,
            .has_preedit = state.has_preedit,
            .focus_is_field = if (focus) |current| current.eql(self.field_id) else false,
        };
        @memcpy(step.value[0..step.value_len], state.slice[0..step.value_len]);
        self.steps[self.step_count] = step;
        self.step_count += 1;
    }

    /// Fold the recorded steps into a report. The steps were taken while the run
    /// was happening, so the report carries the transitions and the end state
    /// together and neither can be checked without the other.
    fn reportWithTrace(self: *Editable) !FieldReport {
        var result = try self.report();
        @memcpy(result.steps[0..self.step_count], self.steps[0..self.step_count]);
        result.step_count = self.step_count;
        return result;
    }

    /// Unregister the endpoint before releasing its model. The view, publisher
    /// and App retire before the Session. No callback may reach a dead model.
    ///
    /// A presented caller has already detached the App, released the field's
    /// layout leases and retired the device resources. A windowless caller
    /// keeps its text service alive through this release.
    fn release(self: *Editable) void {
        self.view.owner = null;
        self.app.detachGpu();
        self.app.textInputManager().clear();
        if (self.consumer) |consumer| {
            consumer.deinit() catch |err| std.debug.panic(
                "text-field teardown reported {s}",
                .{@errorName(err)},
            );
            self.gpa.destroy(consumer);
            self.consumer = null;
        }
        self.publisher.deinit();
        self.app.deinit();
        self.session.deinit() catch unreachable;
        self.gpa.destroy(self.app);
        self.gpa.destroy(self.session);
        self.gpa.destroy(self);
    }
};

/// `Session.read` calls a handler as `(*const Field, *anyopaque)`, while the
/// annotation wants its own receiver. This bridge is that one conversion.
const CaptureAnnotation = struct {
    annotation: *FieldAnnotation,

    fn read(field: *const Field, context: *anyopaque) anyerror!void {
        const self: *CaptureAnnotation = @ptrCast(@alignCast(context));
        try self.annotation.capture(field);
    }
};

/// How one route delivers a frame and one event. The sequence below is written
/// against this, so both routes execute the same steps.
const Driver = struct {
    context: *anyopaque,
    /// Commit one App frame, publish its semantics and DRAW it.
    frame: *const fn (*anyopaque, *Editable) anyerror!void,
    send: *const fn (*anyopaque, *Editable, nogui.Event) anyerror!void,
    /// Called once the control is focused, so the presented route can refuse
    /// before its endpoint is registered if its window bound no native
    /// text-input port.
    focus_ready: *const fn (*anyopaque, *Editable) anyerror!void,
    /// The route's ONE text service, and the face it registered first. The
    /// field's layout is shaped with these, so the geometry a route reports is
    /// the geometry that route's own engine measured.
    service: *const fn (*anyopaque, *Editable) *TextService,
    face: *const fn (*anyopaque, *Editable) nogui.text.FontHandle,
};

/// The editable sequence both routes run. It is written against the App
/// contract only: nothing here knows whether an event came from a caller or
/// from a real SDL queue.
///
/// Every step below is recorded, so the two runs are compared as transitions
/// and not only as the state the last step happened to leave. The names are the
/// script's own: a difference in the trace names the step that diverged.
fn runSequence(editable: *Editable, driver: Driver) !void {
    // The first frame builds the tree, so the keyed control resolves, and the
    // model is created against the identity that frame produced.
    try driver.frame(driver.context, editable);
    editable.field_id = editable.app.widgetIdForKey(.root, .{ .static = key_field }) orelse
        return error.MissingFieldIdentity;
    editable.annotation.field_id = editable.field_id;
    // From here the Editable owns the consumer and `release` frees it, so only
    // the window before `init` completes is undone here: `init` can fail before
    // the model exists, and `deinit` would touch an owner that never was.
    const consumer = try editable.gpa.create(Consumer);
    consumer.init(
        editable.gpa,
        editable.app,
        driver.service(driver.context, editable),
        driver.face(driver.context, editable),
        editable.field_id,
        authored_field,
    ) catch |err| {
        editable.gpa.destroy(consumer);
        return err;
    };
    editable.consumer = consumer;
    // The window now reads the model during every frame, so an edit through the
    // protocol asks this window to repaint and the route's own demand loop
    // produces the next frame without being told to.
    editable.view.owner = consumer;
    try editable.session.requestRedraw(editable.app.window);

    // One frame now, while the window reads the model. That is what records the
    // dependency, so every edit below asks this window to repaint and the
    // route's own demand loop produces the closing frame.
    try driver.frame(driver.context, editable);

    // Focus the control the way a user does: Tab reaches the only focusable.
    try driver.send(driver.context, editable, .{ .key_down = .{ .key = .tab } });
    const focus = editable.app.focus_manager.current orelse return error.MissingFocus;
    if (!focus.eql(editable.field_id)) return error.FocusIsNotTheField;
    try driver.focus_ready(driver.context, editable);
    // The App's own text manager now owns the endpoint. This is the binding a
    // real application makes when its editable control takes focus, and it is
    // the ONLY manager either route has: a manager of this file's own would be
    // a second runtime no event below ever reaches.
    consumer.focus(editable.app);
    // That same manager needs a clipboard. A window the host opened already
    // carries the real W18 service; the window-free route bound nothing, and
    // without this a routed copy, cut or paste would answer `unavailable` for
    // the whole run.
    consumer.bindClipboard();
    if (editable.app.textInputManager().focusedId() == null) return error.EndpointNotRegistered;
    try editable.record("focused");

    // A physical key inserts nothing; its commit inserts once.
    try driver.send(driver.context, editable, .{ .key_down = .{
        .key = .unidentified,
        .logical = .{ .codepoint = 'd' },
    } });
    try driver.send(driver.context, editable, .{ .text_input = .{ .text = "d" } });
    try editable.record("committed one key");

    // A preedit is marked, survives its own end phase, and is replaced once by
    // the platform commit.
    try driver.send(driver.context, editable, .{ .composition = .{
        .phase = .update,
        .text = "\xe3\x81\x82",
    } });
    try driver.send(driver.context, editable, .{ .composition = .{ .phase = .end } });
    try editable.record("preedit ended");
    try driver.send(driver.context, editable, .{ .text_input = .{ .text = "\xe3\x81\x84" } });
    try editable.record("committed preedit");

    // Shift+Left extends the selection one grapheme back, so the selection is a
    // real range in both routes rather than an empty caret.
    try driver.send(driver.context, editable, .{ .key_down = .{ .key = .left, .shift = true } });
    try editable.record("one grapheme back");

    // Home and End move by LINE. A field that answered them with one grapheme
    // would leave the end of the selection on the second character, so the end
    // state below is a selection covering the whole text, and only line motion
    // produces that on this field.
    try driver.send(driver.context, editable, .{ .key_down = .{ .key = .end, .shift = true } });
    try editable.record("line end");
    try driver.send(driver.context, editable, .{ .key_down = .{ .key = .home, .shift = true } });
    try editable.record("line start");

    try driver.frame(driver.context, editable);
    try editable.record("closing frame");
}

// ── the preedit unit conversion ────────────────────────────────────────────────
/// The preedit selection as SDL reports it: a codepoint index and a length in
/// codepoints. The core protocol counts the selection in BYTES of the preedit,
/// so a multibyte preedit is converted here instead of being handed to SDL as if
/// the two units were the same. No selection is SDL's absent pair.
fn sdlPreeditSelection(
    text: []const u8,
    start: usize,
    end: usize,
) struct { start: ?usize, length: ?usize } {
    if (start == end) return .{ .start = null, .length = null };
    const first = codepointIndex(text, start) orelse return .{ .start = null, .length = null };
    const last = codepointIndex(text, end) orelse return .{ .start = null, .length = null };
    if (last < first) return .{ .start = null, .length = null };
    return .{ .start = first, .length = last - first };
}

/// The codepoint index of a byte offset, or null when that byte is not a
/// codepoint boundary of `text`.
fn codepointIndex(text: []const u8, byte: usize) ?usize {
    if (byte > text.len) return null;
    var count: usize = 0;
    var index: usize = 0;
    while (index < byte) {
        index += std.unicode.utf8ByteSequenceLength(text[index]) catch return null;
        count += 1;
    }
    if (index != byte) return null;
    return count;
}

/// SDL types the window itself: the lifecycle events name it directly and the
/// input events name it optionally, because a device with no window to point at
/// — an evdev touchscreen, a trackpad gesture — delivers an event that names
/// none. The host reads such an event as belonging to its only live window,
/// which is right for a real display and wrong for a driver whose window is
/// synthetic, so the scenario's own input harness decides here.
fn deliveredToWindow(raw: *const sdl3.events.Event, native_id: sdl3.video.WindowId) bool {
    return switch (raw.*) {
        inline .window_shown,
        .window_hidden,
        .window_exposed,
        .window_moved,
        .window_resized,
        .window_pixel_size_changed,
        .window_minimized,
        .window_maximized,
        .window_restored,
        .window_focus_gained,
        .window_focus_lost,
        .window_mouse_enter,
        .window_mouse_leave,
        .window_display_changed,
        .window_display_scale_changed,
        .window_occluded,
        .window_enter_fullscreen,
        .window_leave_fullscreen,
        => |value| blk: {
            const id: ?sdl3.video.WindowId = value.id;
            break :blk if (id) |named| named == native_id else false;
        },
        inline .mouse_motion,
        .mouse_button_down,
        .mouse_button_up,
        .mouse_wheel,
        .key_down,
        .key_up,
        .text_input,
        .text_editing,
        .finger_down,
        .finger_motion,
        .finger_up,
        .finger_canceled,
        => |value| blk: {
            const id: ?sdl3.video.WindowId = value.window_id;
            break :blk if (id) |named| named == native_id else false;
        },
        // An event that names no window is the host's business and not the App's:
        // it is never routed into a window, so it cannot reach the model however
        // the host reads it.
        else => true,
    };
}

/// Release a frame's own debug JSON, which the App allocated with this run's
/// allocator. A frame that produced none frees nothing, and a frame output the
/// caller is still reading must be released only after that read.
fn releaseFrame(gpa: std.mem.Allocator, output: nogui.FrameOutput) void {
    if (output.json) |json| gpa.free(json);
}

// ── the window-free route ──────────────────────────────────────────────────────
/// The headless route: a real pinned face, real shaping, and the App's own
/// measure seam, with NO window, NO surface, NO swapchain and NO GPU DEVICE.
/// `nogui_text.TextMeasurer` owns the ONE `TextService` that both the measure
/// seam and the field's layout use, so the geometry in a record describes the
/// same rules the App laid the tree out with.
const Headless = struct {
    gpa: std.mem.Allocator,
    measurer: cpu.TextMeasurer,

    const fonts = [_]cpu.FontSource{.{ .family = "InterVariable", .bytes = font_bytes }};

    fn init(self: *Headless, gpa: std.mem.Allocator) !void {
        self.gpa = gpa;
        try self.measurer.init(gpa, &fonts, field_font_size);
    }

    fn deinit(self: *Headless) void {
        self.measurer.deinit();
        self.* = undefined;
    }

    fn service(self: *Headless) *TextService {
        return self.measurer.textService();
    }

    fn face(self: *Headless) nogui.text.FontHandle {
        return self.service().listFonts()[0].handle;
    }

    fn measure(self: *Headless) MeasureSource {
        return self.measurer.source();
    }

    /// Commit one App frame and publish its semantics. There is nothing to
    /// draw: this route created no device, and its record says so rather than
    /// claiming pixels.
    fn frame(_: *anyopaque, editable: *Editable) anyerror!void {
        const output = try editable.commit(null);
        releaseFrame(editable.gpa, output);
    }

    fn send(_: *anyopaque, editable: *Editable, ev: nogui.Event) anyerror!void {
        if (try editable.app.handle(ev)) |output| releaseFrame(editable.gpa, output);
    }

    fn focusReady(_: *anyopaque, _: *Editable) anyerror!void {}

    fn driverService(context: *anyopaque, _: *Editable) *TextService {
        const self: *Headless = @ptrCast(@alignCast(context));
        return self.service();
    }

    fn driverFace(context: *anyopaque, _: *Editable) nogui.text.FontHandle {
        const self: *Headless = @ptrCast(@alignCast(context));
        return self.face();
    }
};

/// Run the scenario on the window-free route with a real pinned face.
pub fn runHeadless(gpa: std.mem.Allocator) !FieldReport {
    const route = try gpa.create(Headless);
    defer gpa.destroy(route);
    try route.init(gpa);
    // The measurer's service outlives the model, because the model's layout
    // pins cache runs inside it. `editable` is created after it and released
    // before it.
    defer route.deinit();

    const editable = try Editable.create(gpa);
    // One teardown for both routes, and on every path: a sequence that fails
    // mid-run must still release the App, the model and the session it
    // allocated, or the comparison would report on a leaked field.
    defer editable.release();
    editable.app.measure = route.measure();
    try runSequence(editable, .{
        .context = route,
        .service = Headless.driverService,
        .face = Headless.driverFace,
        .frame = Headless.frame,
        .send = Headless.send,
        .focus_ready = Headless.focusReady,
    });
    return editable.reportWithTrace();
}

// ── the presented route ────────────────────────────────────────────────────────
/// The presented route: the SAME scene lowering, the SAME text service and the
/// SAME measure seam, over `v7_frame.NativeFrame`, into a real window's
/// swapchain image. The App mounts exactly one endpoint — this route's — and
/// detaches from it before any device-side resource goes.
const Presented = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    application: *host.Application,
    /// The frame module's own loader, the same one the device is built from. It
    /// stays open until that device is gone.
    loader: v7_frame.SystemVulkanLoader = undefined,
    gpu: noapi.Gpu = undefined,
    /// The platform surface `noapi.Surface.initSdl` created from the SDL window
    /// and adopted. It owns the `VkSurfaceKHR` on the way out, so no SDL
    /// wrapper is kept beside it.
    surface: noapi.Surface = undefined,
    adapter: v7_frame.NativeFrame = undefined,
    frame: v7_frame.NativeFrame.Frame = undefined,
    handle: nogui.window_contract.WindowHandle = undefined,
    managed: *host.ManagedWindow = undefined,
    native_id: sdl3.video.WindowId = 0,
    scale: nogui.geometry.PixelScale = .{ .x = 1, .y = 1 },
    /// Set once every device-side resource below exists, so `retire` releases
    /// exactly what `init` built.
    device_live: bool = false,
    adapter_live: bool = false,
    surface_live: bool = false,
    gpu_live: bool = false,
    loader_live: bool = false,
    /// The Oklab pixels of the last submission. The readback buffer is reused,
    /// so these die at the next render.
    pixels: []const f32 = &.{},

    /// The five SPIR-V modules this route records with: the quad pair and the
    /// sort compute for the scene renderer, plus the fullscreen vertex stage and
    /// the Oklab→sRGB fragment stage the blit samples the Oklab target through.
    const Shaders = struct {
        vert: []const u32,
        frag: []const u32,
        sort: []const u32,
        fullscreen: []const u32,
        oklab: []const u32,
    };

    /// The window's own pixel extent, read from the platform rather than
    /// assumed.
    fn deviceExtent(self: *const Presented) !noapi.Extent2D {
        const pixels = try self.managed.native.pixelExtent();
        return .{ .width = pixels.width, .height = pixels.height };
    }

    /// True when the window IS the authored target: the same logical size, the
    /// same device pixel size, and therefore a 1:1 scale. A window that answered
    /// with anything else is refused rather than measured against a target this
    /// run did not author.
    fn isAuthoredTarget(self: *const Presented) bool {
        const state = self.managed.observed;
        return state.size.width == target.width and state.size.height == target.height and
            state.pixels.width == target.width and state.pixels.height == target.height;
    }

    /// Pump the host until the window has SHOWN at the authored geometry,
    /// bounded, and report what it actually answered if it never does.
    fn awaitAuthoredTarget(self: *Presented) !void {
        var polls: u32 = 0;
        while (polls < readiness_polls) : (polls += 1) {
            _ = try self.application.step();
            try self.managed.refresh();
            if (!self.isAuthoredTarget()) {
                self.reportGeometry(polls);
                return error.NativeGeometryIsNotTheAuthoredTarget;
            }
            if (self.managed.observed.visible) {
                self.scale = try self.managed.observed.pixelScale();
                return;
            }
            try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(poll_delay_ms), .real);
        }
        self.reportGeometry(readiness_polls);
        return error.NativeWindowNeverBecameVisible;
    }

    /// The geometry the window ANSWERED, next to the one this run authored, so
    /// a refusal is never just a name.
    fn reportGeometry(self: *const Presented, polls: u32) void {
        const state = self.managed.observed;
        std.debug.print(
            "text_field: authored {d}x{d}, window logical {d}x{d}, device {d}x{d}," ++
                " visible={}, host_polls={d}\n",
            .{
                target.width,
                target.height,
                state.size.width,
                state.size.height,
                state.pixels.width,
                state.pixels.height,
                state.visible,
                polls,
            },
        );
    }

    /// Acquire the next image, retarget the Oklab pass to it and open the
    /// recording. A swapchain that is out of date is not a failure: the acquire
    /// is retried inside a bound, so a driver that never settles fails the run
    /// instead of spinning.
    fn beginFrame(self: *Presented) !void {
        var attempts: u32 = 0;
        while (attempts < acquire_polls) : (attempts += 1) {
            const viewport: v7_frame.NativeFrame.Viewport = .{
                .logical = logical,
                .device = try self.deviceExtent(),
                .scale = self.scale,
            };
            if (try self.adapter.beginFrame(&self.surface, viewport, &self.frame)) return;
            _ = try self.application.step();
        }
        return error.SwapchainNeverSettled;
    }

    /// The App's tree, the Oklab pass, the blit and the present are ONE event: a
    /// frame this route calls rendered is a frame whose pixels reached the
    /// swapchain image, and the readback below comes out of the Oklab target
    /// those same passes wrote.
    fn render(self: *Presented, output: *const nogui.FrameOutput) !void {
        var painted = try self.adapter.buildScene(.{}, output);
        defer painted.deinit();
        try self.adapter.recordScene(&self.surface, &self.frame, output, &painted);
        // `present` closes the recording itself, so a present that fails must
        // propagate rather than reach a cancellation of a recording that is gone.
        try self.adapter.present(&self.surface, &self.frame);
        self.managed.markPresented();
        self.pixels = try self.adapter.readTarget();
    }

    fn cancelFrame(self: *Presented) void {
        self.adapter.cancelFrame(&self.frame) catch |err| switch (err) {
            error.FrameNotRecording => {},
            else => @panic("text-field presented recording cancellation failed"),
        };
    }

    /// RETIRE every device-side resource, in the order this route owns: the
    /// adapter, then the surface, then the device, then the loader. The App has
    /// already detached and the window and SDL are still up, so nothing
    /// device-side may outlive the window it presents to, and nothing may be
    /// released after it either.
    fn retire(self: *Presented) void {
        if (self.adapter_live) {
            self.adapter.deinit();
            self.adapter_live = false;
        }
        if (self.surface_live) {
            self.surface.deinit();
            self.surface_live = false;
        }
        if (self.gpu_live) {
            self.gpu.deinit();
            self.gpu_live = false;
        }
        if (self.loader_live) {
            self.loader.close();
            self.loader_live = false;
        }
        self.device_live = false;
        self.pixels = &.{};
    }

    /// Hold the presented frame for a BOUNDED number of host steps, so the
    /// platform has processed the present and anything it asked for.
    fn hold(self: *Presented) !void {
        var polls: u32 = 0;
        while (polls < hold_polls) : (polls += 1) {
            _ = try self.application.step();
        }
        try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(poll_delay_ms), .real);
    }
};

/// Owns the field, host and presentation route. Drop layout leases and detach
/// the App before retiring the renderer; retire the surface before its window.
const PresentedRun = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    editable: *Editable = undefined,
    application: *host.Application = undefined,
    route: *Presented = undefined,
    pump: *Hosted = undefined,
    window_open: bool = false,
    host_live: bool = false,
    editable_live: bool = false,
    route_allocated: bool = false,
    pump_allocated: bool = false,
    application_allocated: bool = false,

    /// Open the window, build the device, the surface and the frame adapter, and
    /// mount them on the App. `init` builds in the reverse of `deinit`, and a
    /// failure part-way through still retires exactly what was built.
    fn init(
        self: *PresentedRun,
        gpa: std.mem.Allocator,
        io: std.Io,
        app: *Editable,
        shaders: Presented.Shaders,
    ) !void {
        self.gpa = gpa;
        self.io = io;
        self.editable = app;
        self.editable_live = true;

        self.route = try gpa.create(Presented);
        self.route_allocated = true;
        self.route.* = .{
            .gpa = gpa,
            .io = io,
            .application = undefined,
        };

        self.pump = try gpa.create(Hosted);
        self.pump_allocated = true;
        self.pump.* = .{
            .editable = app,
            .run = self,
            .window = undefined,
        };

        self.application = try gpa.create(host.Application);
        self.application_allocated = true;
        self.route.application = self.application;
        self.application.* = try host.Application.init(gpa, app.session, .{ .app_id = app_id });
        self.host_live = true;
        self.application.setHooks(.{
            .context = self,
            .on_before_close = beforeClose,
        });

        self.route.handle = try self.application.openWindowWithApp(app.app, .{
            .title = window_title,
            .width = target.width,
            .height = target.height,
            .resizable = false,
            .visible = true,
            .gpu_surface = true,
        });
        self.window_open = true;
        self.pump.window = self.route.handle;
        self.route.managed = try self.application.getWindow(self.route.handle);
        self.route.native_id = self.route.managed.native.id;
        try self.route.awaitAuthoredTarget();

        // The loader stays open until every GPU made from its options is gone.
        self.route.loader = try v7_frame.SystemVulkanLoader.open();
        self.route.loader_live = true;
        self.route.gpu = try noapi.Gpu.init(.{
            // Three, not two: the renderer rings its per-frame paint buffers over
            // three slots, one per in-flight frame.
            .frames_in_flight = scene.frames_in_flight,
            .app_name = "nogui_text_field",
            .validation = false,
            .loader = self.route.loader.options(),
            .io = io,
            .allocator = gpa,
        });
        self.route.gpu_live = true;
        // SDL's own Vulkan subsystem, for the platform surface call and nothing
        // else: on Wayland `SDL_Vulkan_CreateSurface` refuses with "Vulkan is
        // not loaded" unless this has run. The device above is built from the
        // frame module's loader, not from this one.
        try sdl3.vulkan.loadLibrary(null);
        // One call hands the window to the platform and takes the surface back:
        // the instance and the platform handle never leave noapi, and a failed
        // call destroys what the platform made. The surface is not built on an
        // unmeasured size.
        self.route.surface = try noapi.Surface.initSdl(
            &self.route.gpu,
            @ptrCast(self.route.managed.native.sdl.value),
            @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
            .{ .extent = try self.route.deviceExtent() },
        );
        self.route.surface_live = true;
        try self.route.adapter.init(.{
            .allocator = gpa,
            .gpu = &self.route.gpu,
            .fonts = &.{.{ .family = "InterVariable", .bytes = font_bytes }},
            .shaders = .{
                .quad_vert = shaders.vert,
                .quad_frag = shaders.frag,
                .sort_comp = shaders.sort,
                .fullscreen_vert = shaders.fullscreen,
                .blit_oklab = shaders.oklab,
            },
            .name = "nogui_text_field_blit_oklab",
        });
        self.route.adapter_live = true;
        self.route.device_live = true;

        // The App measures its layout through the engine that rasterizes the
        // glyphs, so a measured label and a painted glyph are one measurement,
        // and the field's own layout is shaped by the same service.
        app.app.measure = self.route.adapter.measurer();
        try app.app.attachGpu(self.route.adapter.gpuEndpoint());
    }

    fn retireDevice(self: *PresentedRun) void {
        if (!self.editable_live) return;
        self.editable.app.detachGpu();
        if (self.editable.consumer) |consumer| consumer.shape.releaseLayout();
        if (self.route_allocated) self.route.retire();
    }

    fn beforeClose(raw: *anyopaque, _: *host.ManagedWindow) void {
        const self: *PresentedRun = @ptrCast(@alignCast(raw));
        self.retireDevice();
        self.window_open = false;
    }

    /// Also owns partial construction: allocated storage is never destroyed by
    /// a competing errdefer while this cleanup path still addresses it.
    fn deinit(self: *PresentedRun) void {
        self.retireDevice();
        if (self.window_open) {
            const closed = self.application.closeWindow(self.route.handle) catch |err|
                std.debug.panic("text-field window teardown failed: {s}", .{@errorName(err)});
            if (!closed) @panic("text-field owned window close was rejected");
            self.window_open = false;
        }
        if (self.host_live) {
            self.application.deinit();
            self.host_live = false;
        }
        if (self.editable_live and self.editable.session.tasksStarted()) {
            self.editable.session.shutdownTasks(2_000 * std.time.ns_per_ms) catch |err|
                std.debug.panic("the presented field left its task service live: {s}", .{
                    @errorName(err),
                });
        }
        if (self.editable_live) {
            self.editable.release();
            self.editable_live = false;
        }
        if (self.pump_allocated) self.gpa.destroy(self.pump);
        if (self.route_allocated) self.gpa.destroy(self.route);
        if (self.application_allocated) self.gpa.destroy(self.application);
    }

    fn service(self: *const PresentedRun) *TextService {
        return self.route.adapter.textService();
    }

    fn face(self: *const PresentedRun) nogui.text.FontHandle {
        return self.service().listFonts()[0].handle;
    }
};

/// Everything the presented route needs to route an event through the HOST's own
/// SDL queue, and to publish and read back the candidate rectangle.
const Hosted = struct {
    editable: *Editable,
    /// The run that owns this driver, the window and the device. Holding the run
    /// rather than copies of its fields is what keeps the driver from naming a
    /// window the run has already retired.
    run: *PresentedRun,
    window: nogui.window_contract.WindowHandle = undefined,
    /// SDL event text is a sentinel-terminated slice while a core event's is not.
    /// The copy lives in this driver, which outlives both the push and the poll
    /// that reads the event back.
    text_buffer: [64]u8 = @splat(0),
    /// Events SDL delivered that named no window this run opened, counted and
    /// left alone. It is a fact about the machine the run happened on, so it is
    /// reported and never compared between two runs.
    ambient: usize = 0,

    fn sentinel(self: *Hosted, text: []const u8) ![:0]const u8 {
        const taken = @min(text.len, self.text_buffer.len - 1);
        @memcpy(self.text_buffer[0..taken], text[0..taken]);
        self.text_buffer[taken] = 0;
        return self.text_buffer[0..taken :0];
    }

    /// The route's own frame function: acquire, commit the App frame, publish
    /// its semantics, record, blit and present it, and then publish the
    /// candidate rectangle FOR THAT FRAME. A frame this route calls rendered is
    /// a frame whose pixels reached the swapchain image, and its candidate
    /// rectangle is the one the shaped layout it just committed produced.
    fn frame(context: *anyopaque, editable: *Editable) anyerror!void {
        const self: *Hosted = @ptrCast(@alignCast(context));
        const route = self.run.route;
        try route.beginFrame();
        errdefer route.cancelFrame();
        const output = try editable.commit(&route.frame.gpu_frame);
        // The frame's JSON is released only after the render has read the tree
        // it belongs to.
        defer releaseFrame(self.editable.gpa, output);
        try route.render(&output);
        // The host's own publication path never runs here: `updateFrames`
        // returns at the missing on_frame hook, and it would not drive these
        // frames in any case, because this route commits them itself. So the
        // candidate is published HERE, after the frame it describes was
        // committed and rendered — publishing before the commit would hand SDL
        // the previous frame's layout, whose origin was re-anchored by it.
        _ = try editable.app.textInputManager().caretGeometry();
    }

    /// This route's ONE text service, and the face it registered first. The
    /// field's layout is shaped with these, so the geometry this route reports
    /// is the geometry its own engine measured.
    fn service(self: *const Hosted) *TextService {
        return self.run.service();
    }

    fn face(self: *const Hosted) nogui.text.FontHandle {
        return self.run.face();
    }

    fn driverService(context: *anyopaque, _: *Editable) *TextService {
        const self: *Hosted = @ptrCast(@alignCast(context));
        return self.service();
    }

    fn driverFace(context: *anyopaque, _: *Editable) nogui.text.FontHandle {
        const self: *Hosted = @ptrCast(@alignCast(context));
        return self.face();
    }

    /// The host bound this window's own native text-input port to the App at
    /// open, which is what the endpoint that registers next will start. A host
    /// that did not bind it would silently type into nothing, so the run refuses
    /// rather than reporting a comparison it cannot back.
    fn focusReady(context: *anyopaque, _: *Editable) anyerror!void {
        const self: *Hosted = @ptrCast(@alignCast(context));
        const managed = try self.run.application.getWindow(self.window);
        if (managed.app.textInputManager().native == null) {
            return error.HostDidNotBindNativeTextInput;
        }
    }

    /// Turn one core event into the SDL event the platform would really deliver,
    /// push it onto SDL's queue, and route the host's own translated result back
    /// into the App. The core event never reaches the App directly.
    fn send(context: *anyopaque, _: *Editable, ev: nogui.Event) anyerror!void {
        const self: *Hosted = @ptrCast(@alignCast(context));
        const native_id = (try self.run.application.getWindow(self.window)).native.id;
        const stamp = sdl3.timer.getNanosecondsSinceInit();
        const raw: sdl3.events.Event = switch (ev) {
            .key_down => |key| .{ .key_down = .{
                .common = .{ .timestamp = stamp },
                .window_id = native_id,
                .id = null,
                .scancode = switch (key.key) {
                    .tab => .tab,
                    .left => .left,
                    .home => .home,
                    .end => .end,
                    else => null,
                },
                .key = switch (key.key) {
                    .tab => .tab,
                    .left => .left,
                    .home => .home,
                    .end => .end,
                    .escape => .escape,
                    else => null,
                },
                .mod = .{ .left_shift = key.shifted() },
                .raw = 0,
                .down = true,
                .repeat = key.repeat,
            } },
            .text_input => |committed| .{ .text_input = .{
                .common = .{ .timestamp = stamp },
                .window_id = native_id,
                .text = try self.sentinel(committed.text),
            } },
            .composition => |composition| blk: {
                const selection = sdlPreeditSelection(
                    composition.text,
                    composition.selection_start,
                    composition.selection_end,
                );
                break :blk .{ .text_editing = .{
                    .common = .{ .timestamp = stamp },
                    .window_id = native_id,
                    .text = try self.sentinel(composition.text),
                    .start = selection.start,
                    .length = selection.length,
                } };
            },
            else => return error.UntranslatableEvent,
        };
        try sdl3.events.push(raw);
        while (self.run.application.pollEvent()) |queued| {
            // The host keeps draining the whole queue, but the App sees only what
            // SDL addressed to THIS window. The script pushed its own key, text
            // and preedit events, and an event that names no window was addressed
            // to nobody here: on a machine whose touchscreen the driver has
            // opened, that is the developer's own fingers, and a deterministic
            // scenario must not hand them to the field.
            if (!deliveredToWindow(&queued, native_id)) {
                self.ambient += 1;
                continue;
            }
            const routed = try self.run.application.dispatch(&queued) orelse continue;
            switch (routed) {
                .window => |window_event| {
                    const translated = window_event.translated orelse continue;
                    // The host routed the event to its own window, and that
                    // window's App is this run's one App.
                    const app = (try self.run.application.getWindow(window_event.handle)).app;
                    switch (translated) {
                        .input => |value| try self.handle(app, value),
                        .key_down => |value| try self.handle(app, value.core),
                        .resize => |value| try self.handle(app, value.core),
                        .close => return error.HostClosedTheWindow,
                    }
                },
                else => {},
            }
        }
    }

    /// The host's own translation answer, released rather than dropped: the JSON
    /// a frame produced belongs to this run's allocator.
    fn handle(self: *const Hosted, app: *nogui.App, ev: nogui.Event) !void {
        if (try app.handle(ev)) |output| releaseFrame(self.editable.gpa, output);
    }
};

/// Does the rectangle the platform holds describe this caret?
///
/// The host converts every candidate the same way before a handover, so the
/// shaped caret goes through that SAME conversion and the two are compared: a
/// record that never made this comparison could report a green pair while the
/// rectangle SDL was holding tracked nothing the field ever measured. A
/// `caret` of null means the endpoint measured none, and a platform holding a
/// rectangle for an unmeasured field is the very same disagreement.
fn candidateAgrees(
    area: sdl3.rect.IRect,
    cursor: i32,
    caret: ?text_input.Caret,
) bool {
    const measured = caret orelse return false;
    return std.meta.eql(area, host.Window.candidateArea(measured.area)) and
        cursor == host.Window.candidateCursor(measured.cursor);
}

/// Run the scenario through the host and PRESENT it, then report what was
/// measured and what the platform itself holds.
pub fn runPresented(
    gpa: std.mem.Allocator,
    io: std.Io,
    shaders: Presented.Shaders,
    ppm: ?[]const u8,
) !FieldReport {
    const editable = try Editable.create(gpa);
    var run: PresentedRun = .{ .gpa = gpa, .io = io };
    // One cleanup owner covers construction failure and normal close. Layout
    // leases retire before the text cache, and surfaces before platform windows.
    defer run.deinit();
    try run.init(gpa, io, editable, shaders);

    // The driver context is the PUMP, not the run: every frame, send and focus
    // callback below takes the driver, and the driver's service and face are
    // the ones the field's layout is shaped with.
    try runSequence(editable, .{
        .context = run.pump,
        .service = Hosted.driverService,
        .face = Hosted.driverFace,
        .frame = Hosted.frame,
        .send = Hosted.send,
        .focus_ready = Hosted.focusReady,
    });
    // One more frame, asked for rather than hoped for. A redraw request is what
    // an application sends after it changes the field, and the frame that
    // answers it re-anchors the shaped layout to the box the App laid THIS
    // frame's bytes into. Its candidate rectangle is published inside that
    // frame, so the readback below describes the frame this run committed LAST,
    // and the report is built after it — so the caret the record carries is
    // the very rectangle the platform was handed, not one from an earlier
    // frame the report happened to catch.
    const before_frame = editable.app.frame_generation;
    try editable.session.requestRedraw(editable.app.window);
    try Hosted.frame(run.pump, editable);
    try run.route.hold();
    // The frame was asked for and owed: a frame that only drained the queue
    // would leave the readback below describing an earlier frame.
    if (editable.app.frame_generation == before_frame) return error.HostPublishedNoFrame;
    // A frame that drew nothing is refused rather than reported as a
    // presentation.
    if (run.route.pixels.len == 0) return error.NoRenderedTarget;

    var result = try editable.reportWithTrace();
    // The host bound this window's own native text-input port, so registering the
    // endpoint started real native input. The window-free route has no port to
    // start, which is exactly the difference this comparison holds apart.
    result.native_running = editable.app.textInputManager().native_status == .running;
    // What the queue carried that the scenario did not ask for, so a run on a
    // machine with a touchscreen says so instead of quietly ignoring it.
    result.ambient_events = run.pump.ambient;
    result.frames_presented = run.route.adapter.stats.frames_presented;

    if (ppm) |path| try v7_frame.writePpm(gpa, io, path, run.route.pixels, target);

    // What SDL itself holds for this window, read back from SDL and CHECKED
    // against the caret this run published before a single field is recorded.
    // The manager answers from the cache the publication left, so this is the
    // same measurement and not a second one; a rectangle the platform holds
    // that the shaped caret does not describe is refused, because it would
    // anchor an input method to geometry the field never had.
    const manager = editable.app.textInputManager();
    const stored = try sdl3.keyboard.getTextInputArea(
        (try run.application.getWindow(run.pump.window)).native.sdl,
    );
    if (!candidateAgrees(stored[0], stored[1], try manager.caretGeometry())) {
        return error.NativeCandidateDiffersFromPublishedCaret;
    }
    result.sdl_area = stored[0];
    result.sdl_cursor = stored[1];

    // The window closes while the App is still alive: a borrowed App outlives its
    // window, and closing retires only its session identity.
    if (!try run.application.closeWindow(run.pump.window)) return error.CloseRejected;
    if (editable.session.hasWindow(run.pump.window.session_window)) return error.HandleStillLive;
    run.window_open = false;
    return result;
}

// ── the command line ───────────────────────────────────────────────────────────
/// One loaded SPIR-V module: the bytes, and the u32 view the GPU wants.
const ShaderFile = struct {
    bytes: []u8,
    words: []const u32,

    fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !ShaderFile {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        errdefer gpa.free(bytes);
        if (bytes.len == 0 or bytes.len % @sizeOf(u32) != 0) return error.InvalidShaderBytes;
        return .{
            .bytes = bytes,
            .words = @alignCast(std.mem.bytesAsSlice(u32, bytes)),
        };
    }

    fn deinit(self: *ShaderFile, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// Which route this run takes, and the modules the presented one records with.
const RunOptions = struct {
    native: bool = false,
    vert: ?[]const u8 = null,
    frag: ?[]const u8 = null,
    sort: ?[]const u8 = null,
    fullscreen: ?[]const u8 = null,
    oklab: ?[]const u8 = null,
    ppm: ?[]const u8 = null,

    /// The modules are named by the build step; each falls back to the in-tree
    /// path the presented parity example already requires.
    fn vertPath(self: RunOptions) []const u8 {
        return self.vert orelse "shaders/quad_vert.spv";
    }

    fn fragPath(self: RunOptions) []const u8 {
        return self.frag orelse "shaders/quad_frag.spv";
    }

    fn sortPath(self: RunOptions) []const u8 {
        return self.sort orelse "shaders/sort_comp.spv";
    }

    fn fullscreenPath(self: RunOptions) []const u8 {
        return self.fullscreen orelse "shaders/fullscreen_vert.spv";
    }

    fn oklabPath(self: RunOptions) []const u8 {
        return self.oklab orelse "shaders/blit_oklab.spv";
    }
};

/// The five modules the presented route needs. `init` loads in the reverse of
/// `deinit`, and a failure part way through still releases what loaded.
const Rig = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    vert: ShaderFile = undefined,
    frag: ShaderFile = undefined,
    sort: ShaderFile = undefined,
    fullscreen: ?ShaderFile = null,
    oklab: ?ShaderFile = null,

    fn deinitBlit(self: *Rig) void {
        if (self.fullscreen) |*file| file.deinit(self.gpa);
        if (self.oklab) |*file| file.deinit(self.gpa);
        self.fullscreen = null;
        self.oklab = null;
    }

    fn init(gpa: std.mem.Allocator, io: std.Io, options: RunOptions) !Rig {
        var self: Rig = .{ .gpa = gpa, .io = io };
        self.vert = try ShaderFile.load(gpa, io, options.vertPath());
        errdefer self.vert.deinit(gpa);
        self.frag = try ShaderFile.load(gpa, io, options.fragPath());
        errdefer self.frag.deinit(gpa);
        self.sort = try ShaderFile.load(gpa, io, options.sortPath());
        errdefer self.sort.deinit(gpa);
        self.oklab = try ShaderFile.load(gpa, io, options.oklabPath());
        errdefer self.oklab.?.deinit(gpa);
        self.fullscreen = try ShaderFile.load(gpa, io, options.fullscreenPath());
        return self;
    }

    fn shaders(self: *const Rig) Presented.Shaders {
        return .{
            .vert = self.vert.words,
            .frag = self.frag.words,
            .sort = self.sort.words,
            .fullscreen = self.fullscreen.?.words,
            .oklab = self.oklab.?.words,
        };
    }

    fn deinit(self: *Rig) void {
        self.deinitBlit();
        self.sort.deinit(self.gpa);
        self.frag.deinit(self.gpa);
        self.vert.deinit(self.gpa);
        self.* = undefined;
    }
};

// ── output ─────────────────────────────────────────────────────────────────────
fn appendJsonText(out: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) !void {
    try out.append(gpa, '"');
    for (bytes) |byte| switch (byte) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try out.print(gpa, "\\u{x:0>4}", .{byte}),
        else => try out.append(gpa, byte),
    };
    try out.append(gpa, '"');
}

fn appendNumber(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: f32) !void {
    try out.print(gpa, "{d:.4}", .{value});
}

fn appendRect(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    label: []const u8,
    box: nogui.geometry.WindowRect,
) !void {
    try out.print(gpa, ",\"{s}\":{{\"x\":", .{label});
    try appendNumber(out, gpa, box.x);
    try out.appendSlice(gpa, ",\"y\":");
    try appendNumber(out, gpa, box.y);
    try out.appendSlice(gpa, ",\"w\":");
    try appendNumber(out, gpa, box.w);
    try out.appendSlice(gpa, ",\"h\":");
    try appendNumber(out, gpa, box.h);
    try out.append(gpa, '}');
}

fn emitRecord(gpa: std.mem.Allocator, io: std.Io, report: *const FieldReport, mode: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "TEXT-FIELD {");
    try out.appendSlice(gpa, "\"record\":\"text-field\",\"mode\":");
    try appendJsonText(&out, gpa, mode);
    try out.appendSlice(gpa, ",\"value\":");
    try appendJsonText(&out, gpa, report.valueSlice());
    try out.print(gpa, ",\"selection\":{{\"start\":{d},\"end\":{d},\"reversed\":{}}}", .{
        report.selection_start,
        report.selection_end,
        report.selection_reversed,
    });
    try out.print(
        gpa,
        ",\"preedit\":{},\"focus_is_field\":{},\"endpoint_live\":{},\"native_running\":{},\"frames_presented\":{d},\"ambient_events\":{d}",
        .{
            report.has_preedit,
            report.focus_is_field,
            report.endpoint_live,
            report.native_running,
            report.frames_presented,
            report.ambient_events,
        },
    );
    try appendRect(&out, gpa, "caret", report.caret);
    try out.appendSlice(gpa, ",\"caret_cursor\":");
    try appendNumber(&out, gpa, report.caret_cursor);
    try appendRect(&out, gpa, "line_box", report.line_box);
    try out.print(gpa, ",\"graphemes\":{d},\"first_advance\":", .{report.grapheme_count});
    try appendNumber(&out, gpa, report.first_advance);
    try out.appendSlice(gpa, ",\"second_advance\":");
    try appendNumber(&out, gpa, report.second_advance);
    try out.appendSlice(gpa, ",\"ink_width\":");
    try appendNumber(&out, gpa, report.ink_width);
    try out.appendSlice(gpa, ",\"advance_sum\":");
    try appendNumber(&out, gpa, report.advance_sum);
    try out.appendSlice(gpa, ",\"last_grapheme_end_x\":");
    try appendNumber(&out, gpa, report.last_grapheme_end_x);
    try out.appendSlice(gpa, ",\"semantic\":{\"role\":");
    try appendJsonText(&out, gpa, @tagName(@as(semantics.Role, @fromBackingInt(@intCast(report.semantic_role)))));
    try out.appendSlice(gpa, ",\"name\":");
    try appendJsonText(&out, gpa, report.semanticNameSlice());
    try out.appendSlice(gpa, ",\"value\":");
    try appendJsonText(&out, gpa, report.semanticValueSlice());
    try out.print(
        gpa,
        ",\"anchor\":{d},\"focus\":{d},\"addressable\":{},\"replaceable\":{},\"focusable\":{},\"focused\":{}}},\"published_nodes\":{d},\"steps\":[",
        .{
            report.semantic_anchor,
            report.semantic_focus,
            report.semantic_addressable,
            report.semantic_replaceable,
            report.semantic_focusable,
            report.semantic_focused,
            report.published_nodes,
        },
    );
    for (report.steps[0..report.step_count], 0..) |step, index| {
        if (index > 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, "{\"step\":");
        try appendJsonText(&out, gpa, step.name);
        try out.appendSlice(gpa, ",\"value\":");
        try appendJsonText(&out, gpa, step.valueSlice());
        try out.print(
            gpa,
            ",\"selection\":{{\"start\":{d},\"end\":{d},\"reversed\":{}}},\"preedit\":{},\"focus_is_field\":{}}}",
            .{
                step.selection_start,
                step.selection_end,
                step.selection_reversed,
                step.has_preedit,
                step.focus_is_field,
            },
        );
    }
    try out.appendSlice(gpa, "]}\n");
    try std.Io.File.stdout().writeStreamingAll(io, out.items);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;
    var options: RunOptions = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--native")) {
            options.native = true;
        } else if (std.mem.eql(u8, arg, "--ppm")) {
            if (options.ppm != null) return error.RepeatedArgument;
            options.ppm = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--quad-vert")) {
            if (options.vert != null) return error.RepeatedArgument;
            options.vert = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--quad-frag")) {
            if (options.frag != null) return error.RepeatedArgument;
            options.frag = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--sort-comp")) {
            if (options.sort != null) return error.RepeatedArgument;
            options.sort = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--fullscreen-vert")) {
            if (options.fullscreen != null) return error.RepeatedArgument;
            options.fullscreen = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--blit-oklab")) {
            if (options.oklab != null) return error.RepeatedArgument;
            options.oklab = args.next() orelse return error.MissingArgument;
        } else {
            return error.UnknownArgument;
        }
    }

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    if (!options.native) {
        const report = try runHeadless(gpa);
        if (options.ppm != null) return error.PpmNeedsThePresentedRoute;
        try emitRecord(gpa, io, &report, "windowless");
        return;
    }
    var rig = try Rig.init(gpa, io, options);
    defer rig.deinit();
    const report = try runPresented(gpa, io, rig.shaders(), options.ppm);
    try emitRecord(gpa, io, &report, "presented");
}

// ── tests ──────────────────────────────────────────────────────────────────────
/// A pinned text service and the face it registered first. Every test in this
/// file shapes through one of these, so a test's geometry is the pinned font's
/// geometry and not a rule the test itself wrote.
const TestFont = struct {
    gpa: std.mem.Allocator,
    service: TextService,
    font: nogui.text.FontHandle,

    const sources = [_]cpu.FontSource{.{ .family = "InterVariable", .bytes = font_bytes }};

    fn init(gpa: std.mem.Allocator) !TestFont {
        var service = try TextService.init(gpa);
        errdefer service.deinit();
        for (sources) |source| _ = try service.addFont(source);
        return .{
            .gpa = gpa,
            .service = service,
            .font = service.listFonts()[0].handle,
        };
    }

    fn deinit(self: *TestFont) void {
        self.service.deinit();
        self.* = undefined;
    }
};

/// How many bytes a routed clipboard action moved. An outcome that reported
/// anything else — no clipboard, an empty one, a read-only field, a failure —
/// moved nothing, so a caller sees `expected N, found 0` instead of reading a
/// payload out of a tag it did not expect.
fn movedBytes(outcome: text_input.EditOutcome) usize {
    return switch (outcome) {
        .copied => |bytes| bytes,
        .cut => |bytes| bytes,
        .pasted => |bytes| bytes,
        else => 0,
    };
}

/// The window-free rig every protocol test below drives: a real App, the frame
/// that builds its tree, the keyed identity that frame produced, the field model
/// created against it, and the endpoint registered on the App's OWN text
/// manager.
///
/// Nothing here builds a `text_input.Manager`, because no route does either.
/// `rig.manager()` is the one a window-free App owns, and every cut, paste,
/// caret answer and motion below is asked of it — so a test and the window-free
/// route take the same path, and a clipboard that only a test could reach would
/// be a defect rather than a passing assertion.
const TestRig = struct {
    gpa: std.mem.Allocator,
    session: Session,
    app: nogui.App,
    view: FieldView,
    consumer: Consumer,

    /// `init` never returns by value: the endpoint's `user` pointer is the
    /// consumer itself, so the rig has to live where it was created.
    fn init(self: *TestRig, gpa: std.mem.Allocator, pinned: *TestFont, initial: []const u8) !void {
        self.gpa = gpa;
        self.session = try Session.init(gpa);
        errdefer self.session.deinit() catch unreachable;
        self.app = try nogui.App.init(gpa, &self.session);
        errdefer self.app.deinit();
        // The view learns which window it draws for, so the model read during
        // a frame is recorded against that window and not a placeholder.
        self.view = .{ .window = self.app.window };
        try self.app.mountRoot(FieldView, &self.view);
        // The first frame builds the tree, so the keyed control resolves and
        // the model is created against the identity that frame produced.
        releaseFrame(gpa, (try self.app.handle(.{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
            return error.MissingFrameOutput);
        const field_id = self.app.widgetIdForKey(.root, .{ .static = key_field }) orelse
            return error.MissingFieldIdentity;
        try self.consumer.init(gpa, &self.app, &pinned.service, pinned.font, field_id, initial);
        errdefer self.consumer.deinit() catch unreachable;
        // The window now reads the model during every frame, so an edit through
        // the protocol asks this window to repaint.
        self.view.owner = &self.consumer;
        try self.session.requestRedraw(self.app.window);
        releaseFrame(gpa, (try self.app.handle(.{ .frame = .{ .tick = 2, .time_ms = 0 } })) orelse
            return error.MissingFrameOutput);
        // Focus the control the way a user does, then make the bindings a route
        // makes once the field owns the keyboard.
        _ = try self.routed(.{ .key_down = .{ .key = .tab } });
        if (!(self.app.focus_manager.current orelse return error.MissingFocus).eql(field_id)) {
            return error.FocusIsNotTheField;
        }
        self.consumer.focus(&self.app);
        self.consumer.bindClipboard();
        if (self.app.textInputManager().focusedId() == null) return error.EndpointNotRegistered;
    }

    /// The App's own text manager. The endpoint is registered on it, and it is
    /// the one every routed cut, paste and caret answer below is asked of.
    fn manager(self: *TestRig) *text_input.Manager {
        return self.app.textInputManager();
    }

    /// Route one event into the App, exactly as a route's driver does, and
    /// report whether the focused field consumed it. The App's own
    /// default-prevented flag is that answer: a caller cannot see a manager's
    /// private outcome, and the App's is the one that decides whether the
    /// window's default action runs.
    fn routed(self: *TestRig, ev: nogui.Event) !bool {
        if (try self.app.handle(ev)) |output| releaseFrame(self.gpa, output);
        return self.app.last_input_default_prevented;
    }

    fn deinit(self: *TestRig) void {
        self.view.owner = null;
        // The endpoint leaves the App's manager before its model does, so no
        // callback can reach a released model.
        self.app.textInputManager().clear();
        self.consumer.deinit() catch unreachable;
        self.app.deinit();
        self.session.deinit() catch unreachable;
        self.* = undefined;
    }
};

/// The transitions the editable script documents, in the order it reaches them.
/// Both routes run that script, so both must produce this trace. Every unit
/// here is read off the TEXT the script committed, never from a grid.
const documented: [trace_capacity]struct {
    name: []const u8,
    value: []const u8,
    start: usize,
    end: usize,
    reversed: bool,
    preedit: bool,
} = .{
    .{ .name = "focused", .value = "ab", .start = 2, .end = 2, .reversed = false, .preedit = false },
    .{ .name = "committed one key", .value = "abd", .start = 3, .end = 3, .reversed = false, .preedit = false },
    .{ .name = "preedit ended", .value = "abd\xe3\x81\x82", .start = 4, .end = 4, .reversed = false, .preedit = true },
    .{ .name = "committed preedit", .value = "abd\xe3\x81\x84", .start = 4, .end = 4, .reversed = false, .preedit = false },
    .{ .name = "one grapheme back", .value = "abd\xe3\x81\x84", .start = 3, .end = 4, .reversed = true, .preedit = false },
    .{ .name = "line end", .value = "abd\xe3\x81\x84", .start = 4, .end = 4, .reversed = false, .preedit = false },
    .{ .name = "line start", .value = "abd\xe3\x81\x84", .start = 0, .end = 4, .reversed = true, .preedit = false },
    .{ .name = "closing frame", .value = "abd\xe3\x81\x84", .start = 0, .end = 4, .reversed = true, .preedit = false },
};

/// Every recorded step must be the documented transition, in order. The field
/// keeps the keyboard for the whole script: no key in it moves focus away.
fn expectDocumentedTrace(report: *const FieldReport) !void {
    try std.testing.expectEqual(documented.len, report.step_count);
    for (documented, 0..) |want, index| {
        const step = report.steps[index];
        try std.testing.expectEqualStrings(want.value, step.valueSlice());
        try std.testing.expectEqual(want.start, step.selection_start);
        try std.testing.expectEqual(want.end, step.selection_end);
        try std.testing.expectEqual(want.reversed, step.selection_reversed);
        try std.testing.expectEqual(want.preedit, step.has_preedit);
        try std.testing.expect(step.focus_is_field);
    }
}

test "api-w25 the real-font window-free field runs the documented script and publishes shaped geometry" {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(gpa_state.deinit() == 0) catch {};
    const report = try runHeadless(gpa_state.allocator());

    // The sequence is not vacuous: "ab" plus one committed 'd', one composition
    // replaced by its commit, a one-grapheme shift+left, and shift+End then
    // shift+Home is a specific end state both routes must reach.
    try std.testing.expectEqualStrings("abd\xe3\x81\x84", report.valueSlice());
    try std.testing.expectEqual(@as(usize, 0), report.selection_start);
    try std.testing.expectEqual(@as(usize, 4), report.selection_end);
    try std.testing.expect(report.selection_reversed);
    try std.testing.expect(!report.has_preedit);
    try std.testing.expect(report.focus_is_field);
    try std.testing.expect(report.endpoint_live);
    // The window-free route bound no native port and created no device, so it
    // can only report that it did neither.
    try std.testing.expect(!report.native_running);
    try std.testing.expectEqual(@as(u32, 0), report.frames_presented);
    try std.testing.expectEqual(@as(?sdl3.rect.IRect, null), report.sdl_area);

    // PINNED FONT GEOMETRY, and this is where a fixed-advance grid fails: the
    // laid-out text is four shaped graphemes and the first two carry
    // DIFFERENT advances, which no single constant can produce.
    try std.testing.expectEqual(@as(usize, 4), report.grapheme_count);
    try std.testing.expect(report.first_advance > 0);
    try std.testing.expect(report.second_advance > 0);
    try std.testing.expect(report.first_advance != report.second_advance);
    // The line's ink width and the sum of every grapheme's shaped advance are
    // the SAME measurement read two ways, so they must agree: that is what
    // proves the reported geometry came from the layout's own advances rather
    // than from a constant this file wrote. The trailing edge of the last
    // grapheme, measured from the text origin, is that sum again.
    try std.testing.expect(report.ink_width > 0);
    try std.testing.expectApproxEqAbs(report.advance_sum, report.ink_width, 0.001);
    try std.testing.expectApproxEqAbs(
        report.last_grapheme_end_x - report.line_box.x,
        report.advance_sum,
        0.001,
    );

    // The caret is DRAWABLE: a POSITIVE width, the layout's own line height, an
    // origin the App measured rather than this file authoring, and the line box
    // the caret sits on.
    try std.testing.expect(report.caret.w > 0);
    try std.testing.expect(report.caret.h > 0);
    try std.testing.expectEqual(report.line_box.y, report.caret.y);
    try std.testing.expectEqual(report.line_box.h, report.caret.h);
    try std.testing.expect(report.line_box.h > 0);
    // The caret belongs INSIDE the line box it hangs from: its bar starts at the
    // box's left edge and its width is the bar this file authored.
    try std.testing.expectEqual(report.line_box.x, report.caret.x);
    try std.testing.expect(report.caret.x + report.caret.w <= report.line_box.x + report.line_box.w);

    // Semantics describe the live field: an addressable text input whose
    // published value and selection match the model.
    try std.testing.expectEqual(@as(u8, @backingInt(semantics.Role.text_input)), report.semantic_role);
    try std.testing.expectEqualStrings("abd\xe3\x81\x84", report.semanticValueSlice());
    // Shift+Home leaves the anchor at the UTF-8 end and the moving focus at 0.
    try std.testing.expectEqual(@as(usize, 6), report.semantic_anchor);
    try std.testing.expectEqual(@as(usize, 0), report.semantic_focus);
    try std.testing.expect(report.semantic_addressable);
    try std.testing.expect(report.semantic_replaceable);
    try std.testing.expect(report.semantic_focusable);
    try std.testing.expect(report.semantic_focused);

    try expectDocumentedTrace(&report);
}

test "api-w12 a routed paste replaces a selected multibyte range exactly once" {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(gpa_state.deinit() == 0) catch {};
    const gpa = gpa_state.allocator();

    // The window-free route and the sequence it runs, so the endpoint this test
    // edits is the one the ROUTE registered and the clipboard it copies through
    // is the one the ROUTE bound.
    const route = try gpa.create(Headless);
    defer gpa.destroy(route);
    try route.init(gpa);
    defer route.deinit();
    const editable = try Editable.create(gpa);
    defer editable.release();
    editable.app.measure = route.measure();
    try runSequence(editable, .{
        .context = route,
        .service = Headless.driverService,
        .face = Headless.driverFace,
        .frame = Headless.frame,
        .send = Headless.send,
        .focus_ready = Headless.focusReady,
    });

    // The App's OWN text manager: the one the route registered the endpoint on
    // and the one every routed copy, cut and paste is asked of.
    const consumer = editable.consumer.?;
    const manager = editable.app.textInputManager();

    // A value with an ASTRAL codepoint in it: "a", one supplementary
    // character, "b" — four UTF-16 units and seven UTF-8 bytes. Loaded the way
    // an application opening a document would, so the selection below has to be
    // answered by the model rather than by the script.
    var set: SetText = .{ .value = "a\xf0\x9d\x84\x9eb" };
    try consumer.update(SetText.apply, &set);
    try Headless.send(route, editable, .{ .key_down = .{ .key = .end } });
    try Headless.send(route, editable, .{ .key_down = .{ .key = .left } });
    try Headless.send(route, editable, .{ .key_down = .{ .key = .left, .shift = true } });
    var state: ReadState = .{};
    try consumer.read(ReadState.read, &state);
    try std.testing.expectEqualStrings("a\xf0\x9d\x84\x9eb", state.slice);
    // End puts the caret past "b"; one unshifted step walks it back over "b"
    // onto the astral codepoint's own trailing edge, and the extended step
    // after that extends from THERE. Extending from the end would have taken
    // the final character with it. The two backward steps span the astral
    // codepoint's BOTH UTF-16 units and all four of its UTF-8 bytes; a
    // selection that stopped between the two surrogate halves would be a
    // range no byte range can express.
    try std.testing.expectEqual(Utf16Range{ .start = 1, .end = 3 }, state.selection.range);
    try std.testing.expect(state.selection.reversed);

    // The cut is asked of the App, exactly as a platform edit action is. It
    // must reach the clipboard the route bound; a manager with no clipboard
    // answers `unavailable` and removes nothing, which is the whole difference
    // between a routed cut and a cut that only a test can perform.
    const cut = try manager.cut();
    try std.testing.expectEqual(@as(usize, 4), movedBytes(cut));
    try consumer.read(ReadState.read, &state);
    try std.testing.expectEqualStrings("ab", state.slice);
    try std.testing.expectEqual(@as(usize, 1), state.selection.range.start);
    const after_cut = (try manager.caretGeometry()).?.area.x;

    // Cut replaces the clipboard with the removed codepoint. Restore it, then
    // select that same grapheme so the next paste replaces a multibyte range.
    _ = try manager.paste();
    try consumer.read(ReadState.read, &state);
    try std.testing.expectEqualStrings("a\xf0\x9d\x84\x9eb", state.slice);
    try std.testing.expectEqual(@as(usize, 3), state.selection.range.start);
    try Headless.send(route, editable, .{ .key_down = .{ .key = .left, .shift = true } });
    try consumer.read(ReadState.read, &state);
    try std.testing.expectEqual(Utf16Range{ .start = 1, .end = 3 }, state.selection.range);
    try consumer.clipboard.set("\xe3\x81\x82");

    // The paste inserts those three bytes in ONE replacement.
    const pasted = try manager.paste();
    try std.testing.expectEqual(@as(usize, 3), movedBytes(pasted));
    try consumer.read(ReadState.read, &state);
    try std.testing.expectEqualStrings("a\xe3\x81\x82b", state.slice);
    // One unit for the prefix and one for the pasted character: a second
    // insertion would leave the caret at 3, and a split surrogate would have
    // replaced the character rather than stepped past it.
    try std.testing.expectEqual(Utf16Range{ .start = 2, .end = 2 }, state.selection.range);

    // The caret that moved is a SHAPED one. It sits at the trailing edge the
    // pinned face gave the pasted character, further right than the cut left
    // it, so a caret that never followed the bytes — or one produced by a
    // fixed-advance grid — cannot answer this.
    try std.testing.expect((try manager.caretGeometry()).?.area.x > after_cut);
}

test "api-w12 a candidate readback that disagrees with the shaped caret is rejected" {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(gpa_state.deinit() == 0) catch {};
    const gpa = gpa_state.allocator();

    var pinned = try TestFont.init(gpa);
    defer pinned.deinit();
    var rig: TestRig = undefined;
    try rig.init(gpa, &pinned, "i");
    defer rig.deinit();
    rig.consumer.shape.origin = .{ .x = 10, .y = 20 };

    // The caret the App's OWN manager measures, shaped by the pinned face. This
    // is the rectangle a publication hands the platform, and the readback below
    // is what the platform is asked to describe.
    const caret = (try rig.manager().caretGeometry()).?;
    try std.testing.expect(caret.area.w > 0);
    try std.testing.expect(caret.area.h > 0);

    // What the platform holds when the publication was this run's: the host's
    // own conversion of the shaped caret, and nothing else. So the comparison
    // agrees — and a record that filed that rectangle without ever agreeing
    // would have reported a green pair while the anchor tracked nothing.
    const area = host.Window.candidateArea(caret.area);
    const cursor = host.Window.candidateCursor(caret.cursor);
    try std.testing.expect(candidateAgrees(area, cursor, caret));

    // The same rectangle one logical unit to the left. Rounding cannot fold that
    // back — a rectangle a unit away rounds to a different pixel — so a
    // candidate still hanging off the PREVIOUS frame's origin is rejected.
    const shifted: text_input.Caret = .{
        .area = .{
            .x = caret.area.x - 1,
            .y = caret.area.y,
            .w = caret.area.w,
            .h = caret.area.h,
        },
        .cursor = caret.cursor,
    };
    try std.testing.expect(!candidateAgrees(area, cursor, shifted));

    // The same rectangle in the same place with the caret offset inside it
    // moved: an input method hanging a unit along from where the caret really
    // is is the same disagreement, so the offset is compared too.
    const nudged: text_input.Caret = .{ .area = caret.area, .cursor = caret.cursor + 1 };
    try std.testing.expect(!candidateAgrees(area, cursor, nudged));

    // An endpoint that measured no caret at all cannot describe a rectangle the
    // platform is still holding.
    try std.testing.expect(!candidateAgrees(area, cursor, null));
}

test "api-w12 example field types once, pastes back and cancels on blur" {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(gpa_state.deinit() == 0) catch {};
    const gpa = gpa_state.allocator();

    var pinned = try TestFont.init(gpa);
    defer pinned.deinit();

    var rig: TestRig = undefined;
    try rig.init(gpa, &pinned, "abc");
    defer rig.deinit();

    // A physical key inserts nothing; its commit inserts one character.
    try std.testing.expect(!try rig.routed(.{ .key_down = .{
        .key = .unidentified,
        .logical = .{ .codepoint = 'd' },
    } }));
    try std.testing.expect(try rig.routed(.{ .text_input = .{ .text = "d" } }));

    var text: ReadText = .{};
    try rig.consumer.read(ReadText.read, &text);
    try std.testing.expectEqualStrings("abcd", text.out);

    // Copy the selection, clear the field, and paste the clipboard back
    // through the App's own manager — the one the endpoint was registered on,
    // and the one the window-free route drives.
    try rig.consumer.update(SelectAll.apply, &rig.consumer);
    try std.testing.expectEqual(@as(usize, 4), movedBytes(try rig.manager().copy()));
    try rig.consumer.update(Clear.apply, &rig.consumer);
    try std.testing.expectEqual(@as(usize, 4), movedBytes(try rig.manager().paste()));
    try rig.consumer.read(ReadText.read, &text);
    try std.testing.expectEqualStrings("abcd", text.out);

    // A preedit is dropped by focus loss, and text after it is ignored. Escape
    // is the routed way to lose focus: the App blurs, and its own observer
    // reconciles the manager that holds the endpoint.
    _ = try rig.routed(.{ .composition = .{
        .phase = .update,
        .text = "\xe3\x81\x82",
    } });
    _ = try rig.routed(.{ .key_down = .{ .key = .escape } });
    try std.testing.expectEqual(@as(?nogui.WidgetId, null), rig.manager().focusedId());
    try std.testing.expect(!try rig.routed(.{ .text_input = .{ .text = "x" } }));
    try rig.consumer.read(ReadText.read, &text);
    try std.testing.expectEqualStrings("abcd", text.out);
}

test "api-w12 App routes committed text to its focused model and blocks button defaults" {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(gpa_state.deinit() == 0) catch {};
    const gpa = gpa_state.allocator();

    var pinned = try TestFont.init(gpa);
    defer pinned.deinit();
    var rig: TestRig = undefined;
    try rig.init(gpa, &pinned, "ab");
    defer rig.deinit();

    // Enter belongs to the focused field, so the App must not also run the
    // window's default: the control beside the field is never activated.
    _ = try rig.routed(.{ .key_down = .{ .key = .enter } });
    try std.testing.expect(rig.app.last_input_default_prevented);
    try std.testing.expectEqual(@as(u32, 0), rig.view.activations);
    _ = try rig.routed(.{ .text_input = .{ .text = "\xe3\x81\x84" } });
    try std.testing.expect(rig.app.last_input_default_prevented);
    var text: ReadText = .{};
    try rig.consumer.read(ReadText.read, &text);
    try std.testing.expectEqualStrings("ab\xe3\x81\x84", text.out);

    // Escape releases the keyboard, and text after it reaches nobody.
    _ = try rig.routed(.{ .key_down = .{ .key = .escape } });
    try std.testing.expectEqual(@as(?nogui.WidgetId, null), rig.manager().focusedId());
    _ = try rig.routed(.{ .text_input = .{ .text = "x" } });
    try rig.consumer.read(ReadText.read, &text);
    try std.testing.expectEqualStrings("ab\xe3\x81\x84", text.out);
}

/// Ask the endpoint's own motion op for one move. The manager maps keys onto
/// grapheme and line units, so the word unit is reachable only here.
const MoveOnce = struct {
    request: text_input.Move,
    out: Selection = .{},

    fn apply(field: *Field, context: *anyopaque) anyerror!void {
        const self: *MoveOnce = @ptrCast(@alignCast(context));
        self.out = try moveCaret(field, context, self.request);
    }
};

/// Replace the model text the way an application loading a document would.
const SetText = struct {
    value: []const u8,

    fn apply(field: *Field, context: *anyopaque) anyerror!void {
        const self: *SetText = @ptrCast(@alignCast(context));
        try field.setText(self.value);
    }
};

fn readUnits(consumer: *Consumer) !Selection {
    var state: ReadState = .{};
    try consumer.read(ReadState.read, &state);
    return state.selection;
}

test "api-w12 Home and End move by line, never by one character" {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(gpa_state.deinit() == 0) catch {};
    const gpa = gpa_state.allocator();

    var pinned = try TestFont.init(gpa);
    defer pinned.deinit();

    var rig: TestRig = undefined;
    try rig.init(gpa, &pinned, "abcd");
    defer rig.deinit();

    // A fresh field has the caret at the end of its own text.
    try std.testing.expectEqual(@as(usize, 4), (try readUnits(&rig.consumer)).range.start);
    try std.testing.expect(try rig.routed(.{ .key_down = .{ .key = .home } }));
    try std.testing.expectEqual(@as(usize, 0), (try readUnits(&rig.consumer)).range.start);
    try std.testing.expect(try rig.routed(.{ .key_down = .{ .key = .end } }));
    try std.testing.expectEqual(@as(usize, 4), (try readUnits(&rig.consumer)).range.start);

    // Shift+End from the start spans the line. A field that answered End with
    // one grapheme would select a single character here, which is the whole
    // difference this proves.
    try std.testing.expect(try rig.routed(.{ .key_down = .{ .key = .home } }));
    try std.testing.expect(try rig.routed(.{ .key_down = .{ .key = .end, .shift = true } }));
    const extended = try readUnits(&rig.consumer);
    try std.testing.expectEqual(Utf16Range{ .start = 0, .end = 4 }, extended.range);

    // Shift+Home pulls the moving end back to the start of the line, so the
    // selection it was extending collapses instead of reaching past the text.
    try std.testing.expect(try rig.routed(.{ .key_down = .{ .key = .home, .shift = true } }));
    const pulled = try readUnits(&rig.consumer);
    try std.testing.expectEqual(Utf16Range{ .start = 0, .end = 0 }, pulled.range);

    // None of it moved the text.
    var text: ReadText = .{};
    try rig.consumer.read(ReadText.read, &text);
    try std.testing.expectEqualStrings("abcd", text.out);
}

test "api-w25 line and word motion resolve against the layout's own lines and graphemes" {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(gpa_state.deinit() == 0) catch {};
    const gpa = gpa_state.allocator();

    var pinned = try TestFont.init(gpa);
    defer pinned.deinit();

    var rig: TestRig = undefined;
    try rig.init(gpa, &pinned, "");
    defer rig.deinit();

    // "ab cd\nef gh": the hard break sits at byte 5, so the layout's own second
    // line begins at byte 6 and that line edge is UTF-16 unit 6. Every number
    // below is read off the BYTES, not off a column count: a field with a
    // fixed eight-unit grid would answer a different one here.
    var set: SetText = .{ .value = "ab cd\nef gh" };
    try rig.consumer.update(SetText.apply, &set);
    var move: MoveOnce = .{ .request = .{} };

    move.request = .{ .unit = .line, .direction = .forward };
    try rig.consumer.update(MoveOnce.apply, &move);
    try std.testing.expectEqual(@as(usize, 6), move.out.range.start);

    // A line edge is not a dead end: from the second line one more step reaches
    // the end of the text, and stepping back from there lands on the second
    // line's start. The layout says the caret already IS at a line start there,
    // so one more backward step crosses to the FIRST line's start rather than
    // standing still.
    move.request = .{ .unit = .line, .direction = .forward };
    try rig.consumer.update(MoveOnce.apply, &move);
    try std.testing.expectEqual(@as(usize, 11), move.out.range.start);
    move.request = .{ .unit = .line, .direction = .backward };
    try rig.consumer.update(MoveOnce.apply, &move);
    try std.testing.expectEqual(@as(usize, 6), move.out.range.start);
    move.request = .{ .unit = .line, .direction = .backward };
    try rig.consumer.update(MoveOnce.apply, &move);
    try std.testing.expectEqual(@as(usize, 0), move.out.range.start);

    // A word is a run of non-whitespace plus the whitespace after it, walked
    // over the layout's OWN graphemes. Forward from the start clears "ab" and
    // its space, forward again clears "cd" and the newline, and backward lands
    // on the START of the word rather than on the whitespace before it.
    move.request = .{ .unit = .word, .direction = .forward };
    try rig.consumer.update(MoveOnce.apply, &move);
    try std.testing.expectEqual(@as(usize, 3), move.out.range.start);
    move.request = .{ .unit = .word, .direction = .forward };
    try rig.consumer.update(MoveOnce.apply, &move);
    try std.testing.expectEqual(@as(usize, 6), move.out.range.start);
    move.request = .{ .unit = .word, .direction = .backward };
    try rig.consumer.update(MoveOnce.apply, &move);
    try std.testing.expectEqual(@as(usize, 3), move.out.range.start);
    move.request = .{ .unit = .word, .direction = .backward };
    try rig.consumer.update(MoveOnce.apply, &move);
    try std.testing.expectEqual(@as(usize, 0), move.out.range.start);

    // The document unit still reaches both ends of the text.
    move.request = .{ .unit = .document, .direction = .backward };
    try rig.consumer.update(MoveOnce.apply, &move);
    try std.testing.expectEqual(@as(usize, 0), move.out.range.start);
    move.request = .{ .unit = .document, .direction = .forward };
    try rig.consumer.update(MoveOnce.apply, &move);
    try std.testing.expectEqual(@as(usize, 11), move.out.range.start);
}

test "api-w25 a stale layout is dropped and the caret follows the real glyphs" {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(gpa_state.deinit() == 0) catch {};
    const gpa = gpa_state.allocator();

    var pinned = try TestFont.init(gpa);
    defer pinned.deinit();

    var rig: TestRig = undefined;
    try rig.init(gpa, &pinned, "i");
    defer rig.deinit();
    rig.consumer.shape.origin = .{ .x = 10, .y = 20 };

    // The caret for one narrow glyph sits at the shaped x of that glyph's
    // trailing edge, offset from the origin THIS RUN authored and by nothing
    // else. It is drawable: a positive width and the layout's own line height.
    const narrow = (try rig.manager().caretGeometry()).?;
    try std.testing.expect(narrow.area.w > 0);
    try std.testing.expect(narrow.area.h > 0);
    try std.testing.expect(narrow.area.x >= 10);

    // An edit moves the revision, so the layout the next caret read uses is the
    // one shaped from the NEW bytes. A stale layout would leave the caret where
    // it was; 'W' is much wider than 'i' in this face, so the caret's x moves by
    // the shaped advance of the character that was appended.
    _ = try rig.routed(.{ .text_input = .{ .text = "W" } });
    const wide = (try rig.manager().caretGeometry()).?;
    try std.testing.expect(wide.area.x > narrow.area.x);
    try std.testing.expect(wide.area.w == narrow.area.w);
    try std.testing.expect(wide.area.y == narrow.area.y);

    // Replacing the whole value through the application path invalidates the
    // layout too, so a caret read describes the bytes the model holds NOW and
    // not the string it held before.
    var set: SetText = .{ .value = "i" };
    try rig.consumer.update(SetText.apply, &set);
    var end: MoveOnce = .{ .request = .{ .unit = .document, .direction = .forward } };
    try rig.consumer.update(MoveOnce.apply, &end);
    const reset = (try rig.manager().caretGeometry()).?;
    try std.testing.expectEqual(narrow.area.x, reset.area.x);
    try std.testing.expectEqual(narrow.area.h, reset.area.h);
}

test "api-w25 a combining mark and a non-BMP codepoint are one grapheme each" {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(gpa_state.deinit() == 0) catch {};
    const gpa = gpa_state.allocator();

    var pinned = try TestFont.init(gpa);
    defer pinned.deinit();

    // "e" + COMBINING ACUTE ACCENT, then ASTRAL SYMBOL, then "z". The first is
    // ONE grapheme of two codepoints and three UTF-8 bytes; the second is one
    // grapheme of one codepoint, two UTF-16 units and four UTF-8 bytes.
    var rig: TestRig = undefined;
    try rig.init(gpa, &pinned, "e\xcc\x81\xf0\x9d\x84\x9ez");
    defer rig.deinit();

    // The caret starts at the end: three graphemes, 2 + 2 + 1 UTF-16 units
    // and 3 + 4 + 1 UTF-8 bytes. The combining mark is its own UTF-16 unit.
    try std.testing.expectEqual(@as(usize, 5), (try readUnits(&rig.consumer)).range.start);

    // One grapheme back is "z", not half of the astral codepoint.
    try std.testing.expect(try rig.routed(.{ .key_down = .{ .key = .left } }));
    try std.testing.expectEqual(@as(usize, 4), (try readUnits(&rig.consumer)).range.start);

    // One more grapheme back is the WHOLE astral codepoint, both of its UTF-16
    // units at once. A byte-level cluster rule would have stopped inside it.
    try std.testing.expect(try rig.routed(.{ .key_down = .{ .key = .left } }));
    try std.testing.expectEqual(@as(usize, 2), (try readUnits(&rig.consumer)).range.start);

    // And one more is the composed letter: the base and its combining mark are a
    // single character, so no motion ever splits them, and a further step stays
    // at the start of the document.
    try std.testing.expect(try rig.routed(.{ .key_down = .{ .key = .left } }));
    try std.testing.expectEqual(@as(usize, 0), (try readUnits(&rig.consumer)).range.start);
    try std.testing.expect(try rig.routed(.{ .key_down = .{ .key = .left } }));
    try std.testing.expectEqual(@as(usize, 0), (try readUnits(&rig.consumer)).range.start);

    // Erasing FORWARD from the start of the composed letter removes the whole
    // grapheme: the base, its combining mark and all three bytes of UTF-8, in
    // one edit. The manager routes a forward erase through codepoint U+007F,
    // which is what a platform's own delete key carries.
    try std.testing.expect(try rig.routed(.{ .key_down = .{ .key = .end } }));
    try std.testing.expect(try rig.routed(.{ .text_input = .{ .text = "X" } }));
    try std.testing.expect(try rig.routed(.{ .key_down = .{ .key = .home } }));
    try std.testing.expect(try rig.routed(.{ .key_down = .{
        .key = .unidentified,
        .logical = .{ .codepoint = 0x7f },
    } }));
    var text: ReadText = .{};
    try rig.consumer.read(ReadText.read, &text);
    try std.testing.expectEqualStrings("\xf0\x9d\x84\x9ezX", text.out);
    // The caret is still at the start of what is left, and the astral codepoint
    // that followed the erased grapheme is intact.
    try std.testing.expectEqual(@as(usize, 0), (try readUnits(&rig.consumer)).range.start);
}

test "api-w25 a selected range is replaced exactly once across multibyte units" {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(gpa_state.deinit() == 0) catch {};
    const gpa = gpa_state.allocator();

    var pinned = try TestFont.init(gpa);
    defer pinned.deinit();

    var rig: TestRig = undefined;
    try rig.init(gpa, &pinned, "a\xf0\x9d\x84\x9eb");
    defer rig.deinit();

    // The bytes are "a", ASTRAL SYMBOL, "b": one UTF-16 unit, two UTF-16 units
    // and one, so the text is four units wide and the astral codepoint is units
    // 1 through 3. A caret walking back one grapheme at a time must land on unit
    // 3, never between the two surrogate halves at unit 2.
    try std.testing.expectEqual(@as(usize, 4), (try readUnits(&rig.consumer)).range.start);
    try std.testing.expect(try rig.routed(.{ .key_down = .{ .key = .left } }));
    try std.testing.expectEqual(@as(usize, 3), (try readUnits(&rig.consumer)).range.start);

    // Shift+Left from there extends over the WHOLE astral codepoint: unit 1
    // through unit 3, both surrogate halves at once. A selection that stopped at
    // unit 2 would be a range no UTF-8 byte range can express.
    try std.testing.expect(try rig.routed(.{ .key_down = .{ .key = .left, .shift = true } }));
    const selection = try readUnits(&rig.consumer);
    try std.testing.expectEqual(Utf16Range{ .start = 1, .end = 3 }, selection.range);
    try std.testing.expect(selection.reversed);

    // Copying that selection moves the ASTRAL codepoint's four bytes, not half
    // of them, because the endpoint's read snapped the range outward to the
    // layout's grapheme boundaries on both ends. Every action below is asked of
    // the App's own manager, so this is the routed consumer path and not a call
    // only a test could make.
    try std.testing.expectEqual(@as(usize, 4), movedBytes(try rig.manager().copy()));
    try std.testing.expectEqual(@as(usize, 4), movedBytes(try rig.manager().cut()));
    var text: ReadText = .{};
    try rig.consumer.read(ReadText.read, &text);
    try std.testing.expectEqualStrings("ab", text.out);

    // Pasting it back restores exactly those four bytes in one replacement.
    try std.testing.expectEqual(@as(usize, 4), movedBytes(try rig.manager().paste()));
    try rig.consumer.read(ReadText.read, &text);
    try std.testing.expectEqualStrings("a\xf0\x9d\x84\x9eb", text.out);

    // The prefix contributes one UTF-16 unit and the pasted astral character
    // contributes two. A repeated insertion would move the caret past unit 3.
    try std.testing.expectEqual(@as(usize, 3), (try readUnits(&rig.consumer)).range.start);
}

/// Ask the endpoint's own hit test about one point, in the endpoint's own unit.
const HitOnce = struct {
    point: nogui.geometry.WindowPoint,
    out: ?usize = null,

    fn apply(field: *const Field, context: *anyopaque) anyerror!void {
        const self: *HitOnce = @ptrCast(@alignCast(context));
        self.out = try indexAtPoint(field, context, self.point);
    }
};

test "api-w25 the hit test walks the shaped grapheme boxes, not a column count" {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(gpa_state.deinit() == 0) catch {};
    const gpa = gpa_state.allocator();

    var pinned = try TestFont.init(gpa);
    defer pinned.deinit();

    var rig: TestRig = undefined;
    try rig.init(gpa, &pinned, "mWi");
    defer rig.deinit();
    rig.consumer.shape.origin = .{ .x = 0, .y = 0 };

    // Measure where the three graphemes actually landed, so the points below are
    // chosen against the layout's own boxes rather than against a guess.
    var geometry: ReadGeometry = .{};
    try rig.consumer.read(ReadGeometry.read, &geometry);
    try std.testing.expect(geometry.ok);
    try std.testing.expectEqual(@as(usize, 3), geometry.total);
    // 'i' is narrower than 'W' in this face, which is the whole point: three
    // graphemes with three different advances cannot be a grid.
    try std.testing.expect(geometry.advances[2] < geometry.advances[1]);
    const middle_y = geometry.line_top + geometry.line_height / 2;

    // A point just inside the FIRST grapheme's leading edge names it; a point
    // inside the LAST one's names that one. Both answers are the layout's own
    // byte offsets converted through its own UTF-16 table.
    var leading: HitOnce = .{ .point = .{ .x = geometry.lefts[0] + 0.5, .y = middle_y } };
    try rig.consumer.read(HitOnce.apply, &leading);
    try std.testing.expectEqual(@as(?usize, 0), leading.out);

    var last: HitOnce = .{ .point = .{ .x = geometry.lefts[2] + geometry.advances[2] / 2, .y = middle_y } };
    try rig.consumer.read(HitOnce.apply, &last);
    try std.testing.expectEqual(@as(?usize, 2), last.out);

    // A point past the last grapheme names the end of the text.
    var beyond: HitOnce = .{ .point = .{ .x = geometry.rights[2] + 40, .y = middle_y } };
    try rig.consumer.read(HitOnce.apply, &beyond);
    try std.testing.expectEqual(@as(?usize, 3), beyond.out);

    // A point to the LEFT of the first grapheme still names the start, because
    // the layout's own position mapping clamps to its first edge.
    var before: HitOnce = .{ .point = .{ .x = -40, .y = middle_y } };
    try rig.consumer.read(HitOnce.apply, &before);
    try std.testing.expectEqual(@as(?usize, 0), before.out);
}

test "api-w12 the host driver's preedit selection is converted to codepoints" {
    // The core protocol counts the preedit selection in bytes and SDL counts it in
    // codepoints, so "あい" selected from its second character is reported as
    // codepoint 1 of length 1, not as byte 3 of length 3.
    const all = sdlPreeditSelection("\xe3\x81\x82\xe3\x81\x84", 0, 6);
    try std.testing.expectEqual(@as(?usize, 0), all.start);
    try std.testing.expectEqual(@as(?usize, 2), all.length);
    const second = sdlPreeditSelection("\xe3\x81\x82\xe3\x81\x84", 3, 6);
    try std.testing.expectEqual(@as(?usize, 1), second.start);
    try std.testing.expectEqual(@as(?usize, 1), second.length);
    // A collapsed selection, a byte inside a character, and an offset past the
    // text are all "no selection" rather than a wrong one.
    const collapsed = sdlPreeditSelection("\xe3\x81\x82", 3, 3);
    try std.testing.expectEqual(@as(?usize, null), collapsed.start);
    try std.testing.expectEqual(@as(?usize, null), collapsed.length);
    const inside = sdlPreeditSelection("\xe3\x81\x82\xe3\x81\x84", 0, 1);
    try std.testing.expectEqual(@as(?usize, null), inside.start);
    const past = sdlPreeditSelection("ab", 0, 9);
    try std.testing.expectEqual(@as(?usize, null), past.length);
}

// ── the build note ─────────────────────────────────────────────────────────────
// Two steps, two routes, and the modules each needs.
//
// The example's module imports are `nogui`, `nogui_host`, `sdl3`, `nogui_text`
// and `v7_frame`, plus the anonymous `font_bytes` import over the pinned
// `InterVariable.ttf`, and it links libc. `v7_render` is deliberately NOT
// imported: the presented route reaches its renderer through `NativeFrame`,
// which owns one.
//
//   run-parity-text-field
//     The window-free real-font arm. No window, no surface, no swapchain and no
//     GPU device, so it runs with DISPLAY unset:
//
//       env -u DISPLAY -u WAYLAND_DISPLAY zig build run-parity-text-field
//
//   run-parity-text-field-native
//     The presented arm, which needs a display server and a GPU:
//
//       zig build run-parity-text-field-native
//
//     It records with the five SPIR-V modules the scene renderer and the
//     Oklab blit need, and depends on the shader update step. They default to
//     `shaders/quad_vert.spv`, `quad_frag.spv`, `sort_comp.spv`,
//     `fullscreen_vert.spv` and `blit_oklab.spv` when the command line does not
//     name them; `--quad-vert`, `--quad-frag`, `--sort-comp`,
//     `--fullscreen-vert` and `--blit-oklab` each override one.
//
// Each run prints exactly one `TEXT-FIELD` JSON line. Compare the two records:
// every field except `mode`, `native_running`, `frames_presented`,
// `ambient_events` and the SDL readback must be equal, and `FieldReport.diff`
// in this file is that rule, naming the first field that differs.
//
// `zig build test -Dtest-filter=api-w25` covers the window-free arm only; it
// needs no display server and no GPU. The presented arm is exercised by its
// run step, because a frame that reaches a swapchain cannot be asserted from a
// unit test.
