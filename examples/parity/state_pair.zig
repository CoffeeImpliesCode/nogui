//! ONE state scenario, TWO routes, and one strict record to compare.
//!
//! The scenario is an ordinary application: a model-owned editable field, a
//! checkbox bound to application state, and a clipboard port that REFUSES. It
//! makes real model changes, so a route that only moved pixels is caught:
//!
//!   1. Two frames, so the keyed controls resolve and the field's model is
//!      read while a frame builds.
//!   2. ONE click on the checkbox. It is not a tab stop, so it activates and
//!      the keyboard focus does not move — the App's own default action is
//!      what flips it, on both routes.
//!   3. Tab focuses the field, and the App registers the text endpoint the
//!      model's ops implement. The refusing clipboard port replaces whatever
//!      the host bound, so no edit path can reach a shared clipboard.
//!   4. A committed `ü` APPENDS: one real model change.
//!   5. Shift+Left three times selects `äöü` — a multibyte range in UTF-16
//!      units, so the boundaries only agree if both units were tracked.
//!   6. The App's own `Manager.cut` through the refusing port returns `failed`
//!      and the model is UNCHANGED: the port guards the edit path rather than
//!      being merely absent from it.
//!   7. A committed `é` REPLACES that selected multibyte range exactly once.
//!   8. A composition update marks `あ`, and `cancelComposition` cancels it:
//!      the marked bytes go and the bytes they replaced come back.
//!   9. One closing frame, and the readbacks of model, selection, focus, caret
//!      geometry and the published semantics.
//!
//! Which route carries it:
//!
//!   * DEFAULT: frames commit through `v7_frame.Offscreen` — no window, no
//!     surface, no swapchain, no present — and events go straight to
//!     `App.handle`.
//!   * `--native`: the same frames are presented by `v7_frame.NativeFrame`
//!     over `noapi.Surface.initSdl` into a REAL `nogui_host.Application`
//!     window, and every event is pushed onto SDL's queue and routed by
//!     `Application.dispatch`. THOSE EVENTS ARE SYNTHETIC. They show that the
//!     hosted path carries the same transitions; they are NOT real IME, NOT
//!     real keystrokes and NOT an external keyboard acceptance.
//!
//! Both routes lay out in the SAME logical target at 1x, so the geometry in
//! the record means the same thing twice. What the two routes may NOT agree on
//! is only what describes the platform: the mode name, the native text-input
//! status, the native window id and the presentation counters. Everything else
//! — the authored and model values, the focus identity, both selection unit
//! pairs, the semantic role/state/range and the numeric geometry — must be
//! equal, and the controller compares exactly that.
//!
//! The GEOMETRY in the record is measured, never counted. The field's caret,
//! its published character boxes, its selection mapping and the grapheme
//! boundaries a motion walks all come from ONE shaped layout, taken from the
//! text service the route itself rasterizes with, and anchored to the box the
//! App laid the text into. There is no fixed-advance grid and no hand-rolled
//! cluster rule in this file, so a route that substituted a codepoint count
//! for a font would fail here.
//!
//! The run REFUSES rather than reports: a snapshot with no nodes, a value that
//! is not what this scenario produced, or a window that is not the authored
//! target at 1x all end the process with a named error and no record. One
//! `STATE-PAIR` line reaches stdout, and only after every expectation held.
//!
//! Run it: `zig build run-parity-state-pair -- <vert.spv> <frag.spv> <sort.spv>`.
//! `--ppm PATH` writes the last frame as a P6 PPM, `--native` takes the
//! presented route, and `--fullscreen-vert PATH` / `--blit-oklab PATH` name
//! the two blit modules `--native` records with.
const std = @import("std");

const nogui = @import("nogui");
const host = @import("nogui_host");
const sdl3 = @import("sdl3");
const v7_frame = @import("v7_frame");
const v7_render = @import("v7_render");
const font_bytes = @import("font_bytes").bytes;

/// The route's own shaping and layout types, reached through the frame module's
/// public surface. `TextService` is the ONE service both routes shape with and
/// rasterize through, so a layout taken from it describes the very glyphs the
/// renderer drew. There is no second text engine in this file.
const frame_text = v7_frame.native;
const TextService = frame_text.TextService;
const TextLayout = frame_text.TextLayout;

const noapi = v7_frame.noapi;
const scene = v7_frame.scene;
const text_input = nogui.text_input;
const semantics = nogui.semantics;
const Selection = text_input.Selection;
const Utf16Range = text_input.Utf16Range;
const App = nogui.App;
const Session = nogui.Session;
const DrawCtx = nogui.DrawCtx;
const WidgetId = nogui.WidgetId;

/// The authored logical target. Both routes lay out in exactly this, and the
/// native window must report exactly this at a 1:1 pixel scale, or the run is
/// refused rather than compared against geometry it did not author.
const target: noapi.Extent2D = .{ .width = 320, .height = 220 };
const logical: nogui.geometry.WindowSize = .{
    .width = @floatFromInt(target.width),
    .height = @floatFromInt(target.height),
};

const app_id: [:0]const u8 = "dev.nogui.examples.parity.state-pair";
const window_title = "nogui state pair";

/// The stable keys this scene authors. The focus identity in the record is one
/// of these names, never a frame-local id.
const key_field = "field";
const key_agreed = "agreed";

/// The bytes the model starts with: Latin, then two multibyte characters, so a
/// byte index and a UTF-16 index are different numbers from the first step.
const authored_field: []const u8 = "seed \u{00e4}\u{00f6}";

/// Host event batches spent waiting for the window to take the authored
/// geometry, and then holding the presented frame. Bounds, not timeouts.
const readiness_polls: u32 = 32;
const hold_polls: u32 = 8;
const poll_delay_ms: i64 = 20;
/// Acquires spent waiting for a swapchain that was out of date.
const acquire_polls: u32 = 8;

/// The size every label on BOTH routes is measured and rasterized at. The
/// field's own layout is shaped at this size, so its caret, its character
/// boxes and its selection mapping describe the same glyphs the renderer drew.
/// A value that moved here would move the App's own measure seam with it.
const field_font_size: f32 = @floatFromInt(v7_frame.font_size_px);

/// The caret bar's own width in logical units. Its POSITION and its HEIGHT
/// come from the shaped line box, never from a character count.
const caret_bar_width: f32 = 1;

/// How much model text the annotation may publish and the view may paint. The
/// scenario's longest value is eleven bytes; a longer one is refused, never
/// truncated into a comparison.
const published_capacity = 32;

// ── The route's own shaped layout ────────────────────────────────────────────
/// ONE layout of the field's current bytes, shaped by the SAME text service
/// the route rasterizes with, plus the box the App laid that text into.
///
/// There is no second grapheme engine here and no fixed-advance grid. The
/// caret rectangle, the published character boxes, the selection mapping and
/// the boundaries a motion walks are all read from this one layout, so they
/// cannot describe bytes the model no longer holds and cannot disagree with
/// each other. The layout is keyed on the model's revision and is reshaped
/// only when the bytes change.
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
    /// their shaped runs, so reading a caret costs no allocation.
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

    /// Consumer whitespace-run policy, not Unicode word segmentation.
    /// Walk only the grapheme boundaries published by the shaped layout.
    fn wordBoundary(self: *const Shaped, byte: usize, forward: bool) usize {
        const layout = self.borrowedLayout() orelse return byte;
        if (forward) {
            var spaces = false;
            for (layout.graphemes) |item| {
                if (item.end <= byte) continue;
                const whitespace = switch (layout.content[item.start]) {
                    ' ', '\t', '\n', '\r' => true,
                    else => false,
                };
                if (whitespace) spaces = true;
                if (spaces and !whitespace) return item.start;
            }
            return layout.content.len;
        }
        var content = false;
        var index = layout.graphemes.len;
        while (index > 0) {
            index -= 1;
            const item = layout.graphemes[index];
            if (item.start >= byte) continue;
            const whitespace = switch (layout.content[item.start]) {
                ' ', '\t', '\n', '\r' => true,
                else => false,
            };
            if (!whitespace) content = true;
            if (content and whitespace) return item.end;
        }
        return 0;
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

    /// The caret bar at `byte`: its x is the shaped x of that byte and its
    /// height is the laid-out line box. Null only when the byte is not on a
    /// grapheme boundary this layout knows.
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
    /// layout the caret bar uses.
    fn lineHeight(self: *const Shaped) f32 {
        const layout = self.borrowedLayout() orelse return 0;
        if (layout.lines.len == 0) return 0;
        return layout.lines[0].height;
    }
};

// ── The application-owned model ──────────────────────────────────────────────

/// The field the application owns. `deinit` is the Session destructor hook,
/// and the core `Manager` never holds its bytes, its selection or its
/// preedit: every operation below is answered from this value.
const Field = struct {
    allocator: std.mem.Allocator,
    /// The route's shaped layout of this field's current bytes. It is set
    /// once, before the model is handed to the Session, and never replaced.
    /// The layout carries no bytes of its own: it reads this model.
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

    /// A null range means the marked range, else the selection. This is the one
    /// rule that makes a platform commit replace its own preedit instead of
    /// duplicating it.
    fn target(self: *Field, range: ?Utf16Range) Utf16Range {
        return range orelse self.marked orelse self.selection.range;
    }
};

fn readText(
    gpa: std.mem.Allocator,
    field: *const Field,
    _: *anyopaque,
    range: Utf16Range,
    served: *Utf16Range,
) anyerror!?[]u8 {
    const span = try field.region(range);
    served.* = .{
        .start = try text_input.utf8ToUtf16(field.slice(), span.start),
        .end = try text_input.utf8ToUtf16(field.slice(), span.end),
    };
    return try gpa.dupe(u8, field.slice()[span.start..span.end]);
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
    // Every arm answers in bytes, and the conversion to the protocol's unit
    // happens once, below. A field that folds no newline has exactly one line,
    // so a line unit is the whole document.
    const next_byte: usize = switch (request.unit) {
        .grapheme => if (forward) shape.nextCluster(at) else shape.previousCluster(at),
        .word => shape.wordBoundary(at, forward),
        .line, .document => if (forward) field.slice().len else 0,
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
        Utf16Range{
            .start = try field.unit(at),
            .end = try field.unit(shape.nextCluster(at)),
        };
    const span = try field.region(range);
    try field.splice(span.start, span.end, "");
    const caret = try field.unit(span.start);
    field.marked = null;
    field.selection = .{ .range = .{ .start = caret, .end = caret } };
}

fn replaceText(field: *Field, _: *anyopaque, range: ?Utf16Range, text: []const u8) anyerror!void {
    const span = try field.region(field.target(range));
    try field.splice(span.start, span.end, text);
    const caret = try field.unit(span.start + text.len);
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
    const span = try field.region(field.target(range));
    try field.splice(span.start, span.end, text);
    const start = try field.unit(span.start);
    // `marked` is a UTF-16 range and `start` is a UTF-16 offset, so its end is
    // the inserted text's length IN ITS OWN UNITS. The UTF-8 byte count names
    // a different position for anything but ASCII.
    const units = try text_input.utf16Length(text);
    field.marked = .{ .start = start, .end = start + units };
    // The selection the platform names is inside the marked text, so it is
    // already in the model's own units here. Without one, the whole preedit is
    // the selection, in those same units.
    const selection: Utf16Range = inside orelse .{ .start = start, .end = start + units };
    field.selection = .{ .range = selection, .reversed = selection.end < selection.start };
}

fn unmarkText(field: *Field, _: *anyopaque) anyerror!void {
    field.marked = null;
}

fn caretGeometry(field: *const Field, _: *anyopaque, range: Utf16Range) anyerror!?text_input.Caret {
    const shape = try field.shaped();
    const byte = try text_input.utf16ToUtf8(field.slice(), range.end);
    const area = shape.caretRect(byte) orelse return null;
    return .{ .area = area, .cursor = 0 };
}

/// The character a point names, measured against the layout's own glyph boxes:
/// the first grapheme whose middle the point passed. This is a selection
/// mapping over real shaped advances, not a column count.
fn indexAtPoint(field: *const Field, _: *anyopaque, point: nogui.geometry.WindowPoint) anyerror!?usize {
    const shape = try field.shaped();
    const layout = shape.borrowedLayout() orelse return null;
    const height = shape.lineHeight();
    if (point.y < shape.origin.y or point.y > shape.origin.y + height) return null;
    for (layout.graphemes) |item| {
        const box = shape.clusterBox(layout, item.start, item.end) orelse continue;
        if (point.x < box.x + box.w / 2) return layout.byteToUtf16(item.start) catch null;
    }
    return layout.byteToUtf16(layout.content.len) catch null;
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

/// The address this port hands out as its user pointer. Both callbacks ignore
/// it, so the value is never read; a real static address is enough that
/// nothing can fault on a null user pointer.
var refusing_context: u8 = 0;

/// A clipboard port that REFUSES every call. This run shares no clipboard: the
/// machine's own service is never read and never written, and because the port
/// refuses rather than being absent, an edit path that depends on a successful
/// copy fails loudly instead of quietly editing anyway.
const RefusingClipboard = struct {
    fn read(_: std.mem.Allocator, _: *anyopaque) text_input.ClipboardRead {
        return .unavailable;
    }

    fn write(_: *anyopaque, _: []const u8) text_input.ClipboardWrite {
        return .failed;
    }

    fn port() text_input.Clipboard {
        return .{ .user = @ptrCast(&refusing_context), .read = read, .write = write };
    }
};

/// Read the model's own value and selection for a report or an audit.
const ReadValue = struct {
    slice: []const u8 = "",
    selection: Selection = .{},
    marked: ?Utf16Range = null,

    fn read(field: *const Field, context: *anyopaque) anyerror!void {
        const self: *ReadValue = @ptrCast(@alignCast(context));
        self.slice = field.slice();
        self.selection = field.selection;
        self.marked = field.marked;
    }
};

/// `Session.read` calls a handler as `(*const Field, *anyopaque)`, while the
/// annotation wants its own receiver. This bridge is that one conversion.
const Capture = struct {
    annotation: *Annotation,

    fn read(field: *const Field, context: *anyopaque) anyerror!void {
        const self: *Capture = @ptrCast(@alignCast(context));
        try self.annotation.capture(field);
    }
};

/// The published character geometry of the field. One entry per GRAPHEME the
/// route's layout shaped: the bytes it occupies, the x it starts at and the
/// advance it takes. These are the runs the renderer rasterized, so a
/// selection published against them is addressable in the same coordinates
/// the glyphs were drawn in.
const Annotation = struct {
    field_id: WidgetId = .{ .owner = 0, .slot = 0, .generation = 0 },
    value: [published_capacity]u8 = undefined,
    value_len: usize = 0,
    lengths: [published_capacity]u8 = undefined,
    positions: [published_capacity]f32 = undefined,
    widths: [published_capacity]f32 = undefined,
    count: usize = 0,
    anchor: usize = 0,
    focus: usize = 0,

    fn capture(self: *Annotation, field: *const Field) !void {
        const value = field.slice();
        if (value.len > self.value.len) return error.ModelValueTooLong;
        self.value_len = value.len;
        @memcpy(self.value[0..self.value_len], value[0..self.value_len]);
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
        const ordered = field.selection.range.ordered();
        self.anchor = try text_input.utf16ToUtf8(value, ordered.start);
        self.focus = try text_input.utf16ToUtf8(value, ordered.end);
    }

    fn annotate(raw: *anyopaque, node: *const nogui.WidgetNode, draft: *semantics.Draft) anyerror!void {
        const self: *Annotation = @ptrCast(@alignCast(raw));
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

// ── The view ─────────────────────────────────────────────────────────────────

/// The minimal scene: a caption, the model's own bytes, the editable control
/// those bytes belong to, and the checkbox. No widget suite.
const View = struct {
    /// The window this view draws for. A model read during a frame is recorded
    /// against THIS window; without it an edit would ask for no repaint.
    window: u64,
    /// Null only for the first frame, before the keyed identity exists.
    consumer: ?*Consumer = null,
    /// The model bytes this frame painted, copied out of the borrow.
    value: [published_capacity]u8 = undefined,
    value_len: usize = 0,
    /// Caller-owned checkbox state, bound to the control for both the current
    /// and the previous frame tree that retain this node.
    agreed: bool = false,
    last_agreed: bool = false,
    /// How many times the bound state changed between committed frames. A click
    /// that never reached the model leaves this at zero.
    flips: u32 = 0,

    pub fn draw(self: *View, ctx: *DrawCtx) !void {
        if (self.consumer) |consumer| {
            var state: ReadValue = .{};
            try consumer.readWindow(self.window, ReadValue.read, &state);
            if (state.slice.len > self.value.len) return error.ModelValueTooLong;
            self.value_len = state.slice.len;
            @memcpy(self.value[0..self.value_len], state.slice[0..self.value_len]);
        }
        if (self.agreed != self.last_agreed) {
            self.flips += 1;
            self.last_agreed = self.agreed;
        }
        const painted = try ctx.arena.alloc(u8, self.value_len);
        @memcpy(painted, self.value[0..self.value_len]);
        _ = try ctx.label(.{ .text = "nogui state pair" });
        _ = try ctx.label(.{ .text = painted });
        _ = try ctx.button(.{
            .key = .{ .static = key_field },
            .label = "Editable field",
        });
        _ = try ctx.checkbox(.{
            .key = .{ .static = key_agreed },
            .label = "Agreed",
            .value = &self.agreed,
            // Not a tab stop: the click activates it and the keyboard focus
            // stays where it is, so one Tab always lands on the field.
            .focusable = false,
        });
    }
};

/// The consumer handle the App keeps next to its field model. The endpoint's
/// `user` points here, so this value is heap-owned and outlives the run.
///
/// There is NO second text manager here. The App's own manager is the only
/// text runtime in this file: it owns the registered endpoint, the refusing
/// clipboard port and the preedit, and every cut, cancel and caret answer
/// below is asked of THAT one. A private copy would answer from its own empty
/// state and hide a broken registration behind a plausible result.
const Consumer = struct {
    session: *Session,
    field_id: WidgetId = undefined,
    owner: nogui.Model(Field) = undefined,
    user: *anyopaque = undefined,
    /// The ONE shaped layout of the field's bytes, reached through the model
    /// itself. It lives here, not in the model, so the App's endpoint holds a
    /// pointer to a stable value for the whole run.
    shape: Shaped = undefined,

    /// `service` is the route's own text service, so every answer this field
    /// gives is measured by the engine that rasterized its glyphs.
    fn init(
        self: *Consumer,
        gpa: std.mem.Allocator,
        session: *Session,
        service: *TextService,
        font: nogui.text.FontHandle,
        field_id: WidgetId,
        initial: []const u8,
    ) !void {
        self.* = .{
            .session = session,
            .field_id = field_id,
        };
        self.shape.init(gpa, service, font);
        errdefer self.shape.deinit();
        var value: Field = .{ .allocator = gpa, .shape = &self.shape };
        errdefer value.text.deinit(gpa);
        try value.text.appendSlice(gpa, initial);
        // A fresh field has its caret at the end of its own text.
        const units = try text_input.utf16Length(value.slice());
        value.selection = .{ .range = .{ .start = units, .end = units } };
        self.owner = try session.create(Field, &value);
        self.user = self;
    }

    /// Release the model, then the shaped layout that described it.
    ///
    /// The layout holds leases in the ROUTE'S OWN text service, so the caller
    /// must run this while that service is still alive: `TextService.deinit`
    /// refuses a cache with a pinned run. A session that refuses the model
    /// release is reported, never swallowed, and the layout is released on
    /// that path too rather than pinned for good.
    fn deinit(self: *Consumer) !void {
        errdefer self.shape.deinit();
        try self.session.release(Field, &self.owner);
        self.shape.deinit();
    }

    /// Read the model for a report. The handler runs inside the Session borrow
    /// and must not retain the model pointer.
    fn read(self: *Consumer, comptime handler: anytype, context: anytype) !void {
        try self.session.read(Field, self.owner, context, handler);
    }

    /// Read the model while a frame is built for `window`. This is the
    /// draw-scoped read: it records the model as a dependency of that window,
    /// so an edit through the protocol asks that window to repaint.
    fn readWindow(self: *Consumer, window: u64, comptime handler: anytype, context: anytype) !void {
        try self.session.readWindow(Field, window, self.owner, context, handler);
    }

    /// Copy the model's live value and selection into annotation storage while
    /// the model is borrowed, so a published snapshot keeps valid bytes after
    /// the next keystroke edits the model.
    fn capture(self: *Consumer, annotation: *Annotation) !void {
        var bridge: Capture = .{ .annotation = annotation };
        try self.session.read(Field, self.owner, &bridge, Capture.read);
    }
};

// ── The frame pipeline ───────────────────────────────────────────────────────

const Shaders = struct {
    vert: []const u32,
    frag: []const u32,
    sort: []const u32,
};

/// The two extra SPIR-V modules the presented route records with: the
/// fullscreen vertex stage and the Oklab-to-sRGB stage its blit samples the
/// Oklab target through.
const BlitShaders = struct {
    fullscreen: []const u32,
    oklab: []const u32,
};

const Mode = enum { windowless, presented };

/// The frame pipeline, in the two forms the two routes need. The App mounts
/// exactly one endpoint, `endpoint()`, the one this path owns, and detaches
/// from it before any device-side resource goes.
const Painter = struct {
    const Options = struct {
        mode: Mode,
        shaders: Shaders,
        blit: BlitShaders,
        /// The App the window belongs to: a host window owns exactly one App.
        app: *App,
        session: *Session,
    };

    gpa: std.mem.Allocator,
    io: std.Io,
    /// Which route this painter draws: the tag IS the mode, and the tag is what
    /// every accessor below dispatches on.
    path: union(enum) {
        windowless: Windowless,
        presented: Presented,
    },
    /// The Oklab pixels of the last submission. The readback buffer is reused,
    /// so these die at the next render.
    pixels: []const f32 = &.{},
    scale: nogui.geometry.PixelScale = .{ .x = 1, .y = 1 },
    /// Host event batches spent holding the presented frame.
    polls: u32 = 0,

    fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) !*Painter {
        const self = try gpa.create(Painter);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .path = undefined,
        };
        // Both paths initialise IN PLACE: the scene scratch borrows the
        // renderer, the renderer borrows the device, and a moved copy would
        // leave every one of them holding the address of the original.
        switch (options.mode) {
            .windowless => {
                self.path = .{ .windowless = undefined };
                try self.path.windowless.init(gpa, io, options.shaders);
            },
            .presented => {
                self.path = .{ .presented = undefined };
                try self.path.presented.init(gpa, io, options);
                // The record reports the scale the WINDOW answered with, so the
                // two routes' geometry can only be compared at 1x or not at all.
                self.scale = self.path.presented.scale;
            },
        }
        return self;
    }

    /// RETIRE every device-side resource. The App has already detached from the
    /// endpoint and the window and SDL are still up: the swapchain and the
    /// platform surface live on the device AND reference the native window, so
    /// nothing device-side may outlive the window it presents to, and nothing
    /// may be released after it either.
    fn retire(self: *Painter) void {
        switch (self.path) {
            .windowless => |*w| w.deinit(),
            .presented => |*p| p.retire(),
        }
    }

    /// CLOSE the window and then the host. The borrowed App, view and models
    /// are still alive here, so a borrowed App outlives its window. A host
    /// that refuses the close is reported; the host is still released, so a
    /// refusal never leaks the application.
    fn closeHost(self: *Painter) !void {
        switch (self.path) {
            .windowless => {},
            .presented => |*p| try p.closeHost(self.gpa),
        }
    }

    fn destroy(self: *Painter) void {
        self.gpa.destroy(self);
    }

    fn endpoint(self: *Painter) *nogui.GpuEndpoint {
        return switch (self.path) {
            .windowless => |*w| w.offscreen.endpoint(),
            .presented => |*p| p.adapter.gpuEndpoint(),
        };
    }

    fn measurer(self: *Painter) nogui.layout.MeasureSource {
        return switch (self.path) {
            .windowless => |*w| w.text.measurer(),
            .presented => |*p| p.adapter.measurer(),
        };
    }

    /// The ONE text service this route shapes with. The windowless route's own
    /// engine and the presented route's engine are both the renderer that
    /// rasterized the glyphs, so a layout taken here describes those glyphs.
    fn textService(self: *Painter) *TextService {
        return switch (self.path) {
            .windowless => |*w| &w.text.service,
            .presented => |*p| p.adapter.textService(),
        };
    }

    /// The face every label on this route was measured and rasterized with.
    /// The field's own layout names this face, so its geometry and the painted
    /// glyphs can never come from two different typefaces.
    fn face(self: *Painter) nogui.text.FontHandle {
        return self.textService().listFonts()[0].handle;
    }

    fn gpuFrame(self: *Painter) *nogui.GpuFrame {
        return switch (self.path) {
            .windowless => |*w| &w.gpu_frame,
            .presented => |*p| &p.frame.gpu_frame,
        };
    }

    fn beginFrame(self: *Painter) !void {
        switch (self.path) {
            .windowless => |*w| try w.beginFrame(),
            .presented => |*p| try p.beginFrame(),
        }
    }

    fn render(self: *Painter, output: *const nogui.FrameOutput) !void {
        self.pixels = switch (self.path) {
            .windowless => |*w| try w.render(output),
            .presented => |*p| try p.render(output),
        };
    }

    fn cancelFrame(self: *Painter) void {
        switch (self.path) {
            .windowless => |*w| w.cancelFrame(),
            .presented => |*p| p.cancelFrame(),
        }
    }

    /// Hold the presented frame for a BOUNDED number of host steps, so the
    /// platform has processed the present and anything it asked for.
    fn hold(self: *Painter) !void {
        if (self.path == .windowless) return;
        const presented = &self.path.presented;
        var polls: u32 = 0;
        while (polls < hold_polls) : (polls += 1) {
            self.polls += 1;
            _ = try presented.application.step();
        }
        try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(poll_delay_ms), .real);
    }

    fn windowId(self: *Painter) ?u32 {
        return switch (self.path) {
            .windowless => null,
            .presented => |*p| @as(u32, @intCast(p.native_id)),
        };
    }

    fn presentedFrames(self: *Painter) u32 {
        return switch (self.path) {
            .windowless => 0,
            .presented => |*p| p.adapter.stats.frames_presented,
        };
    }

    /// The windowless route: the shared scene lowering and text engine over a
    /// `v7_frame.Offscreen` target. No window, no surface, no swapchain and no
    /// present.
    const Windowless = struct {
        loader: v7_frame.SystemVulkanLoader,
        offscreen: v7_frame.Offscreen,
        text: v7_frame.TextEngine,
        gui: v7_render.Renderer,
        scratch: scene.SceneScratch,
        cmd: noapi.CommandBuffer = undefined,
        gpu_frame: nogui.GpuFrame = undefined,
        index: u32 = 0,

        fn init(self: *Windowless, gpa: std.mem.Allocator, io: std.Io, shaders: Shaders) !void {
            // The loader stays open until every GPU made from its options is gone.
            self.loader = try v7_frame.SystemVulkanLoader.open();
            errdefer self.loader.close();
            self.offscreen = try v7_frame.Offscreen.init(.{
                .allocator = gpa,
                .io = io,
                .loader = self.loader.options(),
                .extent = target,
                .app_name = "nogui_state_pair",
            });
            errdefer self.offscreen.deinit();
            self.text = try v7_frame.TextEngine.init(gpa, self.offscreen.gpu(), &.{
                .{ .family = "InterVariable", .bytes = font_bytes },
            });
            errdefer self.text.deinit();
            try self.text.setGlyphSlotLimit(scene.glyph_material_ceiling);
            self.gui = try v7_render.Renderer.init(
                self.offscreen.gpu(),
                shaders.vert,
                shaders.frag,
                shaders.sort,
            );
            errdefer self.gui.deinit();
            self.gui.configure(.{ .material_bda = self.text.materialBda() });
            self.scratch = scene.SceneScratch.init(gpa, &self.gui);
            self.index = 0;
        }

        fn deinit(self: *Windowless) void {
            self.scratch.deinit();
            self.gui.deinit();
            self.text.deinit();
            self.offscreen.deinit();
            self.loader.close();
        }

        fn beginFrame(self: *Windowless) !void {
            try self.offscreen.beginFrame(self.index, &self.cmd, &self.gpu_frame);
            self.index = (self.index + 1) %
                @as(u32, self.offscreen.gpu().frames_in_flight);
        }

        /// This is the whole submission stage: the same lowering and the same
        /// record the presented route uses, with no window in sight.
        fn render(self: *Windowless, output: *const nogui.FrameOutput) ![]const f32 {
            errdefer self.cancelFrame();
            self.scratch.beginFrame();
            var painted = try scene.buildFrameScene(&self.scratch, &self.text, .{}, output, false);
            defer painted.deinit();
            const device = self.offscreen.extent();
            const record: scene.RecordContext = .{
                .arena = output.tree.allocator,
                .renderer = &self.gui,
                .text = &self.text,
                .logical = logical,
                .device = device,
                .texture_heap = self.offscreen.heap().handle,
                .clips = output.tree.clip_rects[0..output.tree.clip_count],
            };
            _ = try scene.recordFrameScene(
                &record,
                &self.cmd,
                &self.scratch,
                self.scratch.rects.items,
                &painted,
                self.offscreen.target(),
            );
            return self.offscreen.submitRead(&self.gpu_frame);
        }

        fn cancelFrame(self: *Windowless) void {
            if (self.gpu_frame.recording != .active) return;
            self.gpu_frame.cancelRecording() catch
                @panic("state-pair offscreen recording cancellation failed");
        }
    };

    /// The presented route: the SAME scene lowering and the SAME text engine,
    /// over `v7_frame.NativeFrame`, into a real window's swapchain image.
    const Presented = struct {
        application: *host.Application,
        handle: nogui.window_contract.WindowHandle = undefined,
        managed: *host.ManagedWindow = undefined,
        native_id: sdl3.video.WindowId = 0,
        /// The frame module's own loader, the same one the windowless route
        /// builds its device from. It stays open until that device is gone.
        loader: v7_frame.SystemVulkanLoader = undefined,
        gpu: noapi.Gpu = undefined,
        /// The platform surface `noapi.Surface.initSdl` created from the SDL
        /// window and adopted. It owns the `VkSurfaceKHR` on the way out, so no
        /// SDL wrapper is kept beside it.
        surface: noapi.Surface = undefined,
        adapter: v7_frame.NativeFrame = undefined,
        frame: v7_frame.NativeFrame.Frame = undefined,
        retries: u32 = 0,
        scale: nogui.geometry.PixelScale = .{ .x = 1, .y = 1 },
        visible: bool = false,

        fn init(self: *Presented, gpa: std.mem.Allocator, io: std.Io, options: Painter.Options) !void {
            self.application = try gpa.create(host.Application);
            errdefer gpa.destroy(self.application);
            self.application.* = try host.Application.init(gpa, options.session, .{ .app_id = app_id });
            errdefer self.application.deinit();
            // The proof window is OURS for the length of the run. A platform
            // close request is vetoed and losing the last window does not ask
            // the process to quit, so nothing can retire the window this
            // surface presents to while the readbacks are still being taken.
            // No input and no frame callback are registered: this run drives
            // its own frames and routes its own events.
            self.application.setHooks(.{
                .context = self,
                .on_close_request = vetoClose,
                .on_last_window_closed = keepRunning,
            });
            self.handle = try self.application.openWindowWithApp(options.app, .{
                .title = window_title,
                .width = target.width,
                .height = target.height,
                .resizable = false,
                .visible = true,
                .gpu_surface = true,
            });
            self.managed = try self.application.getWindow(self.handle);
            self.native_id = self.managed.native.id;
            // The authored target or no run at all: every readback below is
            // measured against `target`, so a window that answered with
            // anything else is refused rather than measured.
            try self.awaitAuthoredTarget(io);
            self.loader = try v7_frame.SystemVulkanLoader.open();
            errdefer self.loader.close();
            self.gpu = try noapi.Gpu.init(.{
                // Three, not two: the renderer rings its per-frame paint
                // buffers over three slots, one per in-flight frame.
                .frames_in_flight = scene.frames_in_flight,
                .app_name = "nogui_state_pair",
                .validation = false,
                .loader = self.loader.options(),
                .io = io,
                .allocator = gpa,
            });
            errdefer self.gpu.deinit();
            // SDL's own Vulkan subsystem, for the platform surface call and
            // nothing else: on Wayland `SDL_Vulkan_CreateSurface` refuses with
            // "Vulkan is not loaded" unless this has run. The device above is
            // built from the frame module's loader, not from this one.
            try sdl3.vulkan.loadLibrary(null);
            // One call hands the window to the platform and takes the surface
            // back: the instance and the platform handle never leave noapi, and
            // a failed call destroys what the platform made. The surface is not
            // built on an unmeasured size.
            self.surface = try noapi.Surface.initSdl(
                &self.gpu,
                @ptrCast(self.managed.native.sdl.value),
                @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
                .{ .extent = try self.deviceExtent() },
            );
            errdefer self.surface.deinit();
            try self.adapter.init(.{
                .allocator = gpa,
                .gpu = &self.gpu,
                .fonts = &.{.{ .family = "InterVariable", .bytes = font_bytes }},
                .shaders = .{
                    .quad_vert = options.shaders.vert,
                    .quad_frag = options.shaders.frag,
                    .sort_comp = options.shaders.sort,
                    .fullscreen_vert = options.blit.fullscreen,
                    .blit_oklab = options.blit.oklab,
                },
                .name = "nogui_state_pair_blit_oklab",
            });
        }

        /// Every device-side resource, in the order this route owns: the
        /// adapter, then the surface, then the device, then the loader. The
        /// window and SDL are still up when this returns.
        fn retire(self: *Presented) void {
            self.adapter.deinit();
            self.surface.deinit();
            self.gpu.deinit();
            self.loader.close();
        }

        /// The window goes, then the host. The App, view and models are still
        /// alive, so closing retires only the window's session identity.
        ///
        /// The outcome is HELD as an error union across the cleanup, so the
        /// host is released whatever the close did, and BOTH answers are
        /// reported: an error from the close, and a close the host DECLINED.
        /// A declined close leaves a live window this run then stops naming,
        /// so it is named here rather than dropped.
        fn closeHost(self: *Presented, gpa: std.mem.Allocator) !void {
            // The external-close veto protects the live measurement, not this
            // owner's explicit retirement after device resources are gone.
            self.application.setHooks(.{});
            const outcome = self.application.closeWindow(self.handle);
            self.application.deinit();
            gpa.destroy(self.application);
            if (!try outcome) return error.HostRefusedToCloseTheWindow;
        }

        /// The window's own pixel extent, read from the platform rather than
        /// assumed.
        fn deviceExtent(self: *Presented) !noapi.Extent2D {
            const pixels = try self.managed.native.pixelExtent();
            return .{ .width = pixels.width, .height = pixels.height };
        }

        /// True when the window IS the authored target: the same logical size,
        /// the same device pixel size, and therefore a 1:1 scale.
        fn isAuthoredTarget(self: *Presented) bool {
            const state = self.managed.observed;
            return state.size.width == target.width and state.size.height == target.height and
                state.pixels.width == target.width and state.pixels.height == target.height;
        }

        /// Pump the host until the window has SHOWN at the authored geometry,
        /// bounded, and report what it actually answered if it never does.
        fn awaitAuthoredTarget(self: *Presented, io: std.Io) !void {
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
                    self.visible = true;
                    return;
                }
                try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(poll_delay_ms), .real);
            }
            self.reportGeometry(polls);
            return error.NativeWindowNeverBecameVisible;
        }

        /// The geometry the window ANSWERED, next to the one this run authored,
        /// so a refusal is never just a name.
        fn reportGeometry(self: *const Presented, polls: u32) void {
            const state = self.managed.observed;
            std.debug.print(
                "state_pair: authored {d}x{d}, window logical {d}x{d}, device {d}x{d}," ++
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
        /// recording. A swapchain that is out of date is not a failure: the
        /// acquire is retried inside a bound, so a driver that never settles
        /// fails the run instead of spinning.
        fn beginFrame(self: *Presented) !void {
            var attempts: u32 = 0;
            while (attempts < acquire_polls) : (attempts += 1) {
                const viewport: v7_frame.NativeFrame.Viewport = .{
                    .logical = logical,
                    .device = try self.deviceExtent(),
                    .scale = self.scale,
                };
                if (try self.adapter.beginFrame(&self.surface, viewport, &self.frame)) return;
                self.retries += 1;
                _ = try self.application.step();
            }
            return error.SwapchainNeverSettled;
        }

        /// The App's tree, the Oklab pass, the blit and the present are ONE
        /// event: a frame this run calls rendered is a frame whose pixels
        /// reached the swapchain image, and the readback below comes out of the
        /// Oklab target those same passes wrote.
        fn render(self: *Presented, output: *const nogui.FrameOutput) ![]const f32 {
            var painted = try self.adapter.buildScene(.{}, output);
            defer painted.deinit();
            try self.adapter.recordScene(&self.surface, &self.frame, output, &painted);
            // `present` closes the recording itself, so a present that fails
            // must propagate rather than reach a cancellation of a recording
            // that is gone.
            try self.adapter.present(&self.surface, &self.frame);
            self.managed.markPresented();
            return self.adapter.readTarget();
        }

        fn cancelFrame(self: *Presented) void {
            self.adapter.cancelFrame(&self.frame) catch |err| switch (err) {
                error.FrameNotRecording => {},
                else => @panic("state-pair presented recording cancellation failed"),
            };
        }

        fn vetoClose(_: *anyopaque, _: nogui.window_contract.WindowHandle) bool {
            return false;
        }

        fn keepRunning(_: *anyopaque, _: *host.Application) host.Application.LastWindowDecision {
            return .keep_running;
        }
    };
};

// ── The scenario ─────────────────────────────────────────────────────────────

/// One Session, one App, one view, one publisher, one model and one endpoint.
/// The two routes build exactly this and differ only in how a frame is drawn
/// and how an event is carried.
const Scenario = struct {
    gpa: std.mem.Allocator,
    session: *Session,
    app: *App,
    view: *View,
    consumer: ?*Consumer = null,
    publisher: semantics.Publisher,
    annotation: Annotation = .{},
    painter: ?*Painter = null,
    tick: u32 = 0,
    field_id: WidgetId = .{ .owner = 0, .slot = 0, .generation = 0 },
    checkbox_id: WidgetId = .{ .owner = 0, .slot = 0, .generation = 0 },

    fn init(gpa: std.mem.Allocator) !*Scenario {
        const self = try gpa.create(Scenario);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .session = undefined,
            .app = undefined,
            .view = undefined,
            .publisher = semantics.Publisher.init(gpa),
        };
        errdefer self.publisher.deinit();
        self.session = try gpa.create(Session);
        errdefer gpa.destroy(self.session);
        self.session.* = try Session.init(gpa);
        // A later failure must not leave the session's task service live. No
        // window exists yet, so a refusal here is an invariant break and is
        // named rather than swallowed.
        errdefer self.session.deinit() catch |err| std.debug.panic(
            "state_pair: a partial build left a live session: {s}",
            .{@errorName(err)},
        );
        self.app = try gpa.create(App);
        errdefer gpa.destroy(self.app);
        self.app.* = try App.init(gpa, self.session);
        errdefer self.app.deinit();

        self.view = try gpa.create(View);
        errdefer gpa.destroy(self.view);
        self.view.* = .{ .window = self.app.window };
        try self.app.mountRoot(View, self.view);
        return self;
    }

    /// Mount the chosen route's ONE endpoint and measure through the text engine
    /// that same route owns: a measured label and a painted glyph are then one
    /// measurement whichever route this run took.
    fn attachGpu(self: *Scenario, painter: *Painter) !void {
        self.app.measure = painter.measurer();
        try self.app.attachGpu(painter.endpoint());
        self.painter = painter;
    }

    /// The teardown order this value owns, and the reason for it.
    ///
    /// Drop layout leases before their TextService, but keep the consumer,
    /// model and view alive until both App trees retire. Device-side resources
    /// retire before the host window and SDL. The Session outlives every model.
    ///
    /// Return the FIRST recoverable failure after releasing every owner.
    /// Failed task shutdown terminates before worker-owned state is freed.
    fn release(self: *Scenario) !void {
        self.app.detachGpu();
        var failure: ?anyerror = null;
        // Clear the endpoint while its model lives, and return cache pins
        // before the painter destroys the TextService. Keep callback/model
        // storage until the App's previous and current trees are gone.
        self.app.textInputManager().clear();
        if (self.consumer) |consumer| consumer.shape.releaseLayout();
        if (self.painter) |painter| {
            painter.retire();
            painter.closeHost() catch |err| {
                failure = failure orelse err;
            };
        }
        // The native host unregisters its task wake before the Session retires
        // the service. Keep completion, payload and model owners alive through
        // bounded shutdown; never free worker-reachable storage on refusal.
        if (self.session.tasksStarted()) {
            self.session.shutdownTasks(2_000 * std.time.ns_per_ms) catch |err|
                std.debug.panic("state_pair: task shutdown refused {s}", .{@errorName(err)});
        }
        if (self.painter) |painter| {
            painter.destroy();
            self.painter = null;
        }
        self.publisher.deinit();
        self.app.deinit();
        self.gpa.destroy(self.app);
        if (self.consumer) |consumer| {
            consumer.deinit() catch |err| {
                failure = failure orelse err;
            };
            self.view.consumer = null;
            self.gpa.destroy(consumer);
            self.consumer = null;
        }
        self.gpa.destroy(self.view);
        self.session.deinit() catch |err|
            std.debug.panic("state_pair: Session retirement refused {s}", .{@errorName(err)});
        self.gpa.destroy(self.session);
        self.gpa.destroy(self);
        if (failure) |err| return err;
    }

    /// Release this scenario, naming a teardown failure that an error return
    /// cannot carry. Used on the paths where a failure is already in flight.
    fn teardown(self: *Scenario) void {
        self.release() catch |err| std.debug.panic(
            "state_pair: teardown reported {s}",
            .{@errorName(err)},
        );
    }

    /// Commit one frame and publish that frame's semantics. Both routes share
    /// it, so a snapshot always describes the frame it was staged from.
    fn commit(self: *Scenario) !nogui.FrameOutput {
        self.tick += 1;
        const output = try self.app.frameWithGpuAtTime(self.tick, 0, .{
            .width = logical.width,
            .height = logical.height,
        }, self.painter.?.gpuFrame());
        if (self.consumer) |consumer| {
            // The field's text box is the box the App laid out THIS frame, so
            // the shaped layout is anchored where the glyphs really are.
            const box = try self.valueBox();
            consumer.shape.origin = .{ .x = box.x, .y = box.y };
            try consumer.capture(&self.annotation);
        }
        try self.publisher.stage(.{
            .tree = output.tree,
            .focus = output.focus,
            .generation = self.app.frame_generation,
            .surface = .{
                .width = logical.width,
                .height = logical.height,
            },
            .window_name = "state pair",
            .annotator = .{
                .context = &self.annotation,
                .annotate = Annotation.annotate,
            },
        });
        self.publisher.commit();
        return output;
    }

    /// Commit one frame and draw it through the mounted route.
    fn publish(self: *Scenario) !void {
        const painter = self.painter.?;
        try painter.beginFrame();
        errdefer painter.cancelFrame();
        const output = try self.commit();
        // The frame's own debug JSON belongs to this run's allocator, and a
        // frame that produced one must not drop it.
        defer if (output.json) |json| self.gpa.free(json);
        try painter.render(&output);
    }

    /// The App's own handler, with the frame output it may answer a `.frame`
    /// event with released rather than dropped.
    fn handle(self: *Scenario, ev: nogui.Event) !void {
        if (try self.app.handle(ev)) |output| {
            defer if (output.json) |json| self.gpa.free(json);
        }
    }

    /// The model's own state, read through the same Session borrow the
    /// protocol uses.
    fn read(self: *Scenario) !ReadValue {
        const consumer = self.consumer orelse return error.NoFieldModel;
        var state: ReadValue = .{};
        try consumer.read(ReadValue.read, &state);
        return state;
    }

    fn focusId(self: *const Scenario) ?WidgetId {
        return self.app.focus_manager.current;
    }

    fn isFocused(self: *const Scenario, id: WidgetId) bool {
        return if (self.focusId()) |current| current.eql(id) else false;
    }

    /// The stable key the current focus belongs to, or `other` when focus sits
    /// somewhere this scenario did not author. A frame-local id would mean
    /// nothing twice.
    fn focusKey(self: *const Scenario) []const u8 {
        const current = self.focusId() orelse return "none";
        if (current.eql(self.field_id)) return key_field;
        if (current.eql(self.checkbox_id)) return key_agreed;
        return "other";
    }

    fn rectOf(self: *Scenario, id: WidgetId) ![4]f32 {
        const tree = self.app.tree_ptr orelse return error.NoCommittedTree;
        const node = tree.frameNode(id) orelse return error.MissingControlNode;
        const box = nogui.widget.visualBorderRect(tree, node);
        return .{ box.x, box.y, box.w, box.h };
    }

    /// The box the model's own bytes were laid out into: the label whose text
    /// IS the model value, so this is the real text box the renderer painted
    /// into, not a guess at which node it was.
    fn valueBox(self: *Scenario) !nogui.widget.Rect {
        const tree = self.app.tree_ptr orelse return error.NoCommittedTree;
        const value = self.view.value[0..self.view.value_len];
        for (tree.nodes.items) |node| {
            if (node.kind != .label) continue;
            if (!std.mem.eql(u8, node.kind.label.text, value)) continue;
            return nogui.widget.visualContentRect(tree, node.id);
        }
        return error.MissingValueNode;
    }

    fn valueRect(self: *Scenario) ![4]f32 {
        const box = try self.valueBox();
        return .{ box.x, box.y, box.w, box.h };
    }
};

/// The two ways this scenario reaches the App. The script below is written
/// against this alone, so both routes execute the same steps.
const Driver = struct {
    context: *anyopaque,
    /// Commit one App frame, publish its semantics and draw it.
    frame: *const fn (*anyopaque, *Scenario) anyerror!void,
    /// Deliver one core event. The windowless route hands it to the App; the
    /// hosted route turns it into an SDL event and routes the host's own
    /// translation back.
    send: *const fn (*anyopaque, *Scenario, nogui.Event) anyerror!void,
};

/// What the guarding ports and the preedit actually did, read back live. The
/// record reports these observations, not what the scenario hoped for.
const Guarded = struct {
    cut_bytes: usize = 0,
    cut_selection: Utf16Range = .{},
    cut_selection_bytes: Utf16Range = .{},
    preedit_marked: bool = false,
    preedit_marked_bytes: usize = 0,
    preedit_after_cancel_marked: bool = false,
};

/// The scenario both routes run, written against the App contract only: nothing
/// here knows whether an event came from a caller or from SDL's queue.
fn runScenario(scenario: *Scenario, driver: Driver) !Guarded {
    // ── 1. Two frames, so the keyed controls resolve and the model is read
    // while a frame builds. ──
    try driver.frame(driver.context, scenario);
    scenario.field_id = scenario.app.widgetIdForKey(.root, .{ .static = key_field }) orelse
        return error.MissingFieldIdentity;
    scenario.checkbox_id = scenario.app.widgetIdForKey(.root, .{ .static = key_agreed }) orelse
        return error.MissingCheckboxIdentity;
    scenario.annotation.field_id = scenario.field_id;

    const consumer = try scenario.gpa.create(Consumer);
    scenario.consumer = consumer;
    // The field shapes with the SAME service the route rasterizes with, so
    // its caret, its character boxes and its selection mapping describe the
    // glyphs that were actually painted.
    const painter = scenario.painter orelse return error.NoPainter;
    consumer.init(
        scenario.gpa,
        scenario.session,
        painter.textService(),
        painter.face(),
        scenario.field_id,
        authored_field,
    ) catch |err| {
        scenario.consumer = null;
        scenario.gpa.destroy(consumer);
        return err;
    };
    scenario.view.consumer = consumer;
    try scenario.session.requestRedraw(scenario.app.window);
    try driver.frame(driver.context, scenario);

    // ── 2. ONE click on the checkbox. The App's own default action flips the
    // bound state, and the control is not a tab stop, so focus does not move. ──
    const box = try scenario.rectOf(scenario.checkbox_id);
    const point = [2]f32{ box[0] + box[2] / 2, box[1] + box[3] / 2 };
    try driver.send(driver.context, scenario, .{ .mouse_move = .{ .x = point[0], .y = point[1] } });
    try driver.send(driver.context, scenario, .{
        .mouse_down = .{ .button = .left, .x = point[0], .y = point[1] },
    });
    try driver.send(driver.context, scenario, .{
        .mouse_up = .{ .button = .left, .click_count = 1, .x = point[0], .y = point[1] },
    });
    if (!scenario.view.agreed) return error.CheckboxWasNotActivated;
    if (scenario.focusId() != null) return error.ClickMovedKeyboardFocus;

    // ── 3. Tab focuses the field, and the App binds the model's endpoint. No
    // shared clipboard: the host bound its own clipboard to this window when
    // the window opened, so the refusing port replaces it HERE, before any edit
    // path on either route could reach a shared service. A port that refuses
    // rather than being absent is what makes the cut below fail loudly. ──
    try driver.send(driver.context, scenario, .{ .key_down = .{ .key = .tab } });
    if (!scenario.isFocused(scenario.field_id)) return error.FocusIsNotTheField;
    scenario.app.textInputManager().clipboard = RefusingClipboard.port();
    scenario.app.registerTextEndpoint(.{
        .id = scenario.field_id,
        .owner = consumer.owner.weak().erase(),
        .ops = fieldOps(),
        .user = consumer.user,
    });
    if (scenario.app.textInputManager().focusedId() == null) return error.EndpointNotRegistered;

    // Exercise the consumer's word policy through its public model adapter.
    // The two multibyte letters are one whitespace-delimited run; neither
    // direction may treat a word as the entire document.
    const endpoint = scenario.app.textInputManager().focused.?;
    const call: text_input.Call = .{
        .session = scenario.session,
        .owner = endpoint.owner,
        .user = endpoint.user,
        .allocator = scenario.gpa,
    };
    const backward_word = try endpoint.ops.move(call, .{
        .unit = .word,
        .direction = .backward,
        .extend = true,
    });
    if (backward_word.range.start != 5 or backward_word.range.end != 7 or
        !backward_word.reversed) return error.WordSelectionCrossedTheWhitespaceRun;
    const first_word = try endpoint.ops.move(call, .{ .unit = .word, .direction = .backward });
    if (first_word.cursor() != 0) return error.BackwardWordDidNotReachTheFirstRun;
    const second_word = try endpoint.ops.move(call, .{ .unit = .word, .direction = .forward });
    if (second_word.cursor() != 5) return error.ForwardWordSkippedTheSecondRun;
    const restored = try endpoint.ops.move(call, .{ .unit = .word, .direction = .forward });
    if (restored.cursor() != 7 or !restored.range.isEmpty()) return error.WordMovementDidNotRestoreTheCaret;

    // ── 4. A committed `ü` appends: one real model change. ──
    try driver.send(driver.context, scenario, .{ .text_input = .{ .text = "\u{00fc}" } });
    if (!std.mem.eql(u8, (try scenario.read()).slice, "seed \u{00e4}\u{00f6}\u{00fc}")) {
        return error.AppendDidNotLand;
    }

    // ── 5. Three Shift+Left steps select `äöü`: a multibyte range. ──
    for (0..3) |_| {
        try driver.send(driver.context, scenario, .{ .key_down = .{
            .key = .left,
            .shift = true,
        } });
    }
    const selected = try scenario.read();
    if (selected.selection.range.start != 5 or selected.selection.range.end != 8) {
        return error.SelectionIsNotTheMultibyteRange;
    }

    // ── 6. The refusing port guards the edit path. ──
    var guarded: Guarded = .{};
    switch (try scenario.app.textInputManager().cut()) {
        .failed => {},
        else => return error.RefusingClipboardDidNotRefuse,
    }
    const after_cut = try scenario.read();
    if (!std.mem.eql(u8, after_cut.slice, "seed \u{00e4}\u{00f6}\u{00fc}")) return error.RefusedCutStillEdited;
    if (after_cut.selection.range.start != 5 or after_cut.selection.range.end != 8) {
        return error.RefusedCutStillMovedTheCaret;
    }
    guarded.cut_bytes = after_cut.slice.len;
    guarded.cut_selection = after_cut.selection.range.ordered();
    guarded.cut_selection_bytes = .{
        .start = try text_input.utf16ToUtf8(after_cut.slice, guarded.cut_selection.start),
        .end = try text_input.utf16ToUtf8(after_cut.slice, guarded.cut_selection.end),
    };

    // ── 7. A committed `é` replaces that range exactly once. ──
    try driver.send(driver.context, scenario, .{ .text_input = .{ .text = "\u{00e9}" } });
    if (!std.mem.eql(u8, (try scenario.read()).slice, "seed \u{00e9}")) {
        return error.MultibyteRangeNotReplacedOnce;
    }

    // ── 8. A preedit is marked, then cancelled: the marked bytes go and the
    // bytes they replaced come back. ──
    try driver.send(driver.context, scenario, .{ .composition = .{
        .phase = .update,
        .text = "\u{3042}",
    } });
    const marked = try scenario.read();
    if (marked.marked == null) return error.PreeditWasNotMarked;
    if (!std.mem.eql(u8, marked.slice, "seed \u{00e9}\u{3042}")) return error.PreeditDidNotMark;
    guarded.preedit_marked = true;
    guarded.preedit_marked_bytes = marked.slice.len;
    try scenario.app.textInputManager().cancelComposition();
    const cancelled = try scenario.read();
    if (!std.mem.eql(u8, cancelled.slice, "seed \u{00e9}")) return error.PreeditCancelDidNotRestore;
    guarded.preedit_after_cancel_marked = cancelled.marked != null;

    // ── 9. The closing frame, and the readbacks that follow it. ──
    try driver.frame(driver.context, scenario);
    return guarded;
}

/// The windowless route: the App's own `handle`, frames drawn into a
/// `v7_frame.Offscreen` target. No host, no window, no SDL.
fn windowlessFrame(context: *anyopaque, scenario: *Scenario) anyerror!void {
    _ = context;
    try scenario.publish();
}

fn windowlessSend(context: *anyopaque, scenario: *Scenario, ev: nogui.Event) anyerror!void {
    _ = context;
    try scenario.handle(ev);
}

/// The hosted route: the same App inside a real `nogui_host.Application`
/// window. Frames are presented by `v7_frame.NativeFrame`, and every event is
/// pushed onto SDL's queue and routed by the host's own window.
///
/// The events are SYNTHETIC. Nothing here is real IME input and nothing here is
/// an external keyboard; this route exists to show that the platform path
/// carries the same transitions the windowless route carried directly.
const Hosted = struct {
    application: *host.Application,
    window: nogui.window_contract.WindowHandle,
    /// SDL event text is sentinel-terminated; the copy outlives both the push
    /// and the poll that reads the event back.
    text_buffer: [64]u8 = @splat(0),
    /// Events SDL delivered that named no window this run opened. A fact about
    /// the machine, so it is reported and never compared.
    ambient: usize = 0,

    /// SDL event text is sentinel terminated. Text too long for the buffer is
    /// REFUSED rather than truncated: a cut commit would silently change the
    /// model this run is comparing.
    fn sentinel(self: *Hosted, text: []const u8) ![:0]const u8 {
        if (text.len >= self.text_buffer.len) return error.SdlTextBufferIsTooSmall;
        @memcpy(self.text_buffer[0..text.len], text);
        self.text_buffer[text.len] = 0;
        return self.text_buffer[0..text.len :0];
    }

    /// SDL types the window itself: lifecycle events name it directly and input
    /// events name it optionally, because a device with no window to point at —
    /// an evdev touchscreen, a trackpad gesture — delivers an event that names
    /// none. The host reads such an event as belonging to its only live window,
    /// which is right for a real display and wrong for a driver whose window is
    /// synthetic, so this harness decides here.
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
            // An event that names no window is the host's business and not the
            // App's: it is never routed into a window, so it cannot reach the
            // model however the host reads it.
            else => true,
        };
    }

    fn hostedFrame(context: *anyopaque, scenario: *Scenario) anyerror!void {
        const self: *Hosted = @ptrCast(@alignCast(context));
        try scenario.publish();
        // Let the window process the frame that was just presented before the
        // next event is pushed onto its queue.
        _ = try self.application.step();
    }

    /// Turn one core event into the SDL event the platform would really
    /// deliver, push it onto SDL's queue, and route the host's own translated
    /// result back into the App. The core event never reaches the App directly
    /// on this route.
    fn hostedSend(context: *anyopaque, scenario: *Scenario, ev: nogui.Event) anyerror!void {
        const self: *Hosted = @ptrCast(@alignCast(context));
        const native_id = (try self.application.getWindow(self.window)).native.id;
        const stamp = sdl3.timer.getNanosecondsSinceInit();
        const raw: sdl3.events.Event = switch (ev) {
            .key_down => |key| .{ .key_down = .{
                .common = .{ .timestamp = stamp },
                .window_id = native_id,
                .id = null,
                .scancode = switch (key.key) {
                    .tab => .tab,
                    .left => .left,
                    else => null,
                },
                .key = switch (key.key) {
                    .tab => .tab,
                    .left => .left,
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
            .composition => |composition| .{ .text_editing = .{
                .common = .{ .timestamp = stamp },
                .window_id = native_id,
                .text = try self.sentinel(composition.text),
                .start = null,
                .length = null,
            } },
            .mouse_move => |move| .{ .mouse_motion = .{
                .common = .{ .timestamp = stamp },
                .window_id = native_id,
                .state = sdl3.mouse.ButtonFlags.fromSdl(0),
                .x = move.x,
                .y = move.y,
                .x_rel = 0,
                .y_rel = 0,
            } },
            .mouse_down => |down| .{ .mouse_button_down = .{
                .common = .{ .timestamp = stamp },
                .window_id = native_id,
                .button = .left,
                .down = true,
                .clicks = @intCast(down.click_count),
                .x = down.x,
                .y = down.y,
            } },
            .mouse_up => |up| .{ .mouse_button_up = .{
                .common = .{ .timestamp = stamp },
                .window_id = native_id,
                .button = .left,
                .down = false,
                .clicks = @intCast(up.click_count),
                .x = up.x,
                .y = up.y,
            } },
            else => return error.UntranslatableEvent,
        };
        try sdl3.events.push(raw);
        while (self.application.pollEvent()) |queued| {
            if (!deliveredToWindow(&queued, native_id)) {
                self.ambient += 1;
                continue;
            }
            const routed = try self.application.dispatch(&queued) orelse continue;
            switch (routed) {
                .window => |window_event| {
                    const translated = window_event.translated orelse continue;
                    // The host routed the event to its own window, and that
                    // window's App is this run's one App.
                    switch (translated) {
                        .input => |value| try scenario.handle(value),
                        .key_down => |value| try scenario.handle(value.core),
                        .resize => |value| try scenario.handle(value.core),
                        .close => return error.HostClosedTheWindow,
                    }
                },
                else => {},
            }
        }
    }
};

// ── The record ───────────────────────────────────────────────────────────────

/// One window's state, as an outside observer can see it. Both routes build
/// this from the same live App, the same live model and the same publisher, so
/// a difference in the record is a difference in the route.
const Pair = struct {
    target_width: u32 = 0,
    target_height: u32 = 0,
    scale_x: f32 = 1,
    scale_y: f32 = 1,

    authored_field: []const u8 = "",
    authored_bytes: usize = 0,
    authored_utf16: usize = 0,
    authored_checkbox: bool = false,

    text: []const u8 = "",
    bytes: usize = 0,
    utf16: usize = 0,

    sel_utf16_start: usize = 0,
    sel_utf16_end: usize = 0,
    sel_byte_start: usize = 0,
    sel_byte_end: usize = 0,
    reversed: bool = false,
    marked: bool = false,

    focus_key: []const u8 = "",
    focus_is_field: bool = false,
    endpoint_registered: bool = false,

    caret_x: f32 = 0,
    caret_y: f32 = 0,
    caret_w: f32 = 0,
    caret_h: f32 = 0,

    /// The line box the route's own layout shaped for the field's text. The
    /// caret bar is exactly this tall: the height comes from the text engine,
    /// never from a row height this file authored.
    text_line_height: f32 = 0,
    /// The shaped ink of the field's own bytes at the pinned font size.
    text_ink_width: f32 = 0,
    /// One entry per shaped grapheme, in window coordinates: the x it starts
    /// at and the advance it takes. Real proportional advances, so a run of
    /// equal widths here would mean a fixed grid had replaced the font.
    char_x: [published_capacity]f32 = @splat(0),
    char_w: [published_capacity]f32 = @splat(0),
    char_count: usize = 0,
    char_advance_min: f32 = 0,
    char_advance_max: f32 = 0,
    /// How many character boxes the PUBLISHED text node carried. It must equal
    /// `char_count`: the node an outside observer reads is the same layout.
    semantic_char_count: usize = 0,

    checkbox: bool = false,
    flips: u32 = 0,

    clipboard_port: []const u8 = "",
    clipboard_cut: []const u8 = "",
    clipboard_bytes_after_cut: usize = 0,
    clipboard_sel_utf16_start: usize = 0,
    clipboard_sel_utf16_end: usize = 0,
    clipboard_sel_byte_start: usize = 0,
    clipboard_sel_byte_end: usize = 0,

    preedit_marked: bool = false,
    preedit_marked_bytes: usize = 0,
    preedit_after_cancel_bytes: usize = 0,
    preedit_after_cancel_marked: bool = false,

    semantic_role: []const u8 = "",
    semantic_name: []const u8 = "",
    semantic_value: []const u8 = "",
    semantic_anchor: usize = 0,
    semantic_focus: usize = 0,
    semantic_addressable: bool = false,
    semantic_replaceable: bool = false,
    semantic_focusable: bool = false,
    semantic_focused: bool = false,

    semantic_checkbox_role: []const u8 = "",
    semantic_checkbox_name: []const u8 = "",
    semantic_checkbox_checked: []const u8 = "",
    semantic_checkbox_focusable: bool = false,
    semantic_checkbox_focused: bool = false,

    published_nodes: usize = 0,
    field_rect: [4]f32 = .{ 0, 0, 0, 0 },
    checkbox_rect: [4]f32 = .{ 0, 0, 0, 0 },
    value_rect: [4]f32 = .{ 0, 0, 0, 0 },

    // Platform description, and the only part of the record a comparison may
    // hold apart.
    mode: []const u8 = "",
    synthetic_input: bool = false,
    native_text_input: []const u8 = "",
    native_window_id: ?u32 = null,
    presented_frames: u32 = 0,
    host_polls: u32 = 0,
};

/// Build the record from the live App, the live model and the published
/// snapshot, plus the readbacks the scenario took while it ran. Both routes
/// call this same function, so the comparison cannot differ because it
/// measured different things.
fn buildPair(scenario: *Scenario, mode: Mode, guarded: Guarded) !Pair {
    const consumer = scenario.consumer orelse return error.NoFieldModel;
    const painter = scenario.painter.?;
    var pair: Pair = .{
        .target_width = target.width,
        .target_height = target.height,
        .scale_x = painter.scale.x,
        .scale_y = painter.scale.y,
        .authored_field = authored_field,
        .authored_bytes = authored_field.len,
        .authored_utf16 = try text_input.utf16Length(authored_field),
        .authored_checkbox = false,
    };
    const state = try scenario.read();
    pair.text = state.slice;
    pair.bytes = state.slice.len;
    pair.utf16 = try text_input.utf16Length(state.slice);

    const ordered = state.selection.range.ordered();
    pair.sel_utf16_start = ordered.start;
    pair.sel_utf16_end = ordered.end;
    pair.sel_byte_start = try text_input.utf16ToUtf8(state.slice, ordered.start);
    pair.sel_byte_end = try text_input.utf16ToUtf8(state.slice, ordered.end);
    pair.reversed = state.selection.reversed;
    pair.marked = state.marked != null;

    pair.focus_key = scenario.focusKey();
    pair.focus_is_field = scenario.isFocused(scenario.field_id);
    pair.endpoint_registered = scenario.app.textInputManager().focusedId() != null;
    const caret = (try scenario.app.textInputManager().caretGeometry()) orelse
        return error.NoCaretGeometry;
    pair.caret_x = caret.area.x;
    pair.caret_y = caret.area.y;
    pair.caret_w = caret.area.w;
    pair.caret_h = caret.area.h;

    // The text engine's own answers for the field's current bytes: the line
    // box, the ink it measured, and one box per shaped grapheme. These are the
    // same runs the renderer rasterized, and the same boxes the annotation
    // published, so the caret, the character boxes and the painted ink are one
    // measurement instead of three.
    pair.text_line_height = consumer.shape.lineHeight();
    if (consumer.shape.text) |*layout| {
        pair.text_ink_width = layout.inkWidth();
        var widest: f32 = 0;
        var narrowest: f32 = 0;
        for (layout.graphemes, 0..) |item, index| {
            if (index >= pair.char_x.len) break;
            const box = consumer.shape.clusterBox(layout, item.start, item.end) orelse
                return error.TextLayoutRejectedAGrapheme;
            pair.char_x[index] = box.x;
            pair.char_w[index] = box.w;
            pair.char_count += 1;
            narrowest = if (pair.char_count == 1) box.w else @min(narrowest, box.w);
            widest = @max(widest, box.w);
        }
        pair.char_advance_min = narrowest;
        pair.char_advance_max = widest;
    }

    pair.checkbox = scenario.view.agreed;
    pair.flips = scenario.view.flips;

    pair.clipboard_port = "refusing";
    pair.clipboard_cut = "failed";
    pair.clipboard_bytes_after_cut = guarded.cut_bytes;
    pair.clipboard_sel_utf16_start = guarded.cut_selection.start;
    pair.clipboard_sel_utf16_end = guarded.cut_selection.end;
    pair.clipboard_sel_byte_start = guarded.cut_selection_bytes.start;
    pair.clipboard_sel_byte_end = guarded.cut_selection_bytes.end;

    pair.preedit_marked = guarded.preedit_marked;
    pair.preedit_marked_bytes = guarded.preedit_marked_bytes;
    pair.preedit_after_cancel_bytes = state.slice.len;
    pair.preedit_after_cancel_marked = guarded.preedit_after_cancel_marked;

    // The published snapshot. A snapshot with no nodes, or without the two
    // controls this scenario authored, is refused rather than reported as an
    // empty or null-only readback.
    const snapshot = scenario.publisher.snapshot() orelse return error.MissingSemanticSnapshot;
    pair.published_nodes = snapshot.count();
    if (pair.published_nodes == 0) return error.EmptySemanticSnapshot;
    const field_node = snapshot.node(semantics.nodeId(scenario.field_id, .self_node)) orelse
        return error.MissingSemanticField;
    pair.semantic_role = @tagName(field_node.role);
    pair.semantic_name = field_node.name;
    const published_text = field_node.text orelse return error.MissingSemanticText;
    pair.semantic_value = published_text.value;
    pair.semantic_char_count = published_text.character_lengths.len;
    const published_range = published_text.selection orelse return error.MissingSemanticSelection;
    pair.semantic_anchor = published_range.anchor;
    pair.semantic_focus = published_range.focus;
    pair.semantic_addressable = published_text.addressable();
    pair.semantic_replaceable = field_node.actions.has(.replace_selected_text);
    pair.semantic_focusable = field_node.states.focusable;
    pair.semantic_focused = field_node.states.focused;

    const checkbox_node = snapshot.node(semantics.nodeId(scenario.checkbox_id, .self_node)) orelse
        return error.MissingSemanticCheckbox;
    pair.semantic_checkbox_role = @tagName(checkbox_node.role);
    pair.semantic_checkbox_name = checkbox_node.name;
    pair.semantic_checkbox_checked = @tagName(checkbox_node.states.checked);
    pair.semantic_checkbox_focusable = checkbox_node.states.focusable;
    pair.semantic_checkbox_focused = checkbox_node.states.focused;

    pair.field_rect = try scenario.rectOf(scenario.field_id);
    pair.checkbox_rect = try scenario.rectOf(scenario.checkbox_id);
    pair.value_rect = try scenario.valueRect();

    pair.mode = if (mode == .windowless) "windowless" else "native";
    pair.synthetic_input = mode == .presented;
    pair.native_text_input = @tagName(scenario.app.textInputManager().native_status);
    pair.native_window_id = painter.windowId();
    pair.presented_frames = painter.presentedFrames();
    pair.host_polls = painter.polls;
    return pair;
}

/// Refuse a record this scenario did not produce. Every refusal names the field
/// that is wrong, so a failure says what disagreed rather than that something
/// did. The scalar oracles are the scenario's own: authored bytes 9 and UTF-16
/// 7, model bytes 7 and UTF-16 6, a caret at UTF-16 6 and byte 7, one checkbox
/// flip, a refused cut that left 11 bytes and the selection at 5..8 UTF-16 and
/// 5..11 bytes, a 10-byte preedit that cancelled back to 7 unmarked bytes, and
/// a published field that is an addressable, replaceable, focused text input
/// whose selection is at byte 7.
///
/// The GEOMETRY is not pinned to numbers this file chose. It is refused when it
/// is not the text engine's own answer: the caret must be exactly the shaped
/// line box tall, must sit where the last shaped character ends, must lie
/// inside the box the App really laid the text into, and the advances must
/// differ from each other. A fixed per-codepoint grid would satisfy none of
/// those.
fn expectPair(pair: *const Pair) !void {
    if (pair.scale_x != 1 or pair.scale_y != 1) return error.NotOneToOne;
    if (pair.target_width != 320 or pair.target_height != 220) return error.TargetMoved;
    if (pair.authored_bytes != 9 or pair.authored_utf16 != 7) return error.AuthoredValueMoved;
    if (!std.mem.eql(u8, pair.authored_field, authored_field)) return error.AuthoredBytesMoved;
    if (pair.authored_checkbox) return error.AuthoredCheckboxWasNotFalse;
    if (!std.mem.eql(u8, pair.text, "seed \u{00e9}")) return error.ModelValueIsNotTheScenarioValue;
    if (pair.bytes != 7 or pair.utf16 != 6) return error.ModelValueIsNotNormalized;
    if (pair.sel_utf16_start != 6 or pair.sel_utf16_end != 6) return error.SelectionIsNotTheCaret;
    if (pair.sel_byte_start != 7 or pair.sel_byte_end != 7) return error.SelectionBytesAreNotTheCaret;
    if (pair.reversed) return error.CaretSelectionIsReversed;
    if (pair.marked) return error.APreeditIsStillMarked;
    if (!std.mem.eql(u8, pair.focus_key, key_field)) return error.FocusIsNotTheFieldKey;
    if (!pair.focus_is_field) return error.FocusIsNotTheField;
    if (!pair.endpoint_registered) return error.EndpointIsNotLive;
    // One logical unit of slack: the laid-out box and the shaped line box are
    // two measurements of the same font, and the bar's own width sits on top
    // of the last advance.
    const slack: f32 = 1;
    if (!(pair.caret_w > 0) or !(pair.caret_h > 0)) return error.CaretHasNoBox;
    if (pair.caret_h != pair.text_line_height) return error.CaretIsNotTheShapedLineBox;
    if (pair.char_count == 0) return error.ShapedTextHasNoCharacters;
    if (pair.char_count > pair.char_x.len) return error.ShapedTextOverflowedTheRecord;
    if (!(pair.text_ink_width > 0)) return error.ShapedTextHasNoInk;
    if (!(pair.char_advance_min > 0)) return error.CharacterAdvanceIsNotAPositiveWidth;
    if (!(pair.char_advance_min < pair.char_advance_max)) return error.AdvancesAreAFixedGrid;
    const last = pair.char_count - 1;
    if (@abs(pair.caret_x - (pair.char_x[last] + pair.char_w[last])) > slack) {
        return error.CaretIsNotWhereTheShapedTextEnds;
    }
    if (pair.caret_x < pair.value_rect[0] - slack) return error.CaretIsLeftOfTheTextBox;
    if (pair.caret_x + pair.caret_w > pair.value_rect[0] + pair.value_rect[2] + slack) {
        return error.CaretIsRightOfTheTextBox;
    }
    if (pair.caret_y < pair.value_rect[1] - slack) return error.CaretIsAboveTheTextBox;
    if (pair.caret_y + pair.caret_h > pair.value_rect[1] + pair.value_rect[3] + slack) {
        return error.CaretIsBelowTheTextBox;
    }
    if (!pair.checkbox or pair.flips != 1) return error.CheckboxWasNotActivatedOnce;
    if (!std.mem.eql(u8, pair.clipboard_port, "refusing")) return error.ClipboardPortIsNotTheRefusingOne;
    if (!std.mem.eql(u8, pair.clipboard_cut, "failed")) return error.RefusingPortDidNotRefuse;
    if (pair.clipboard_bytes_after_cut != 11) return error.RefusedCutStillEdited;
    if (pair.clipboard_sel_utf16_start != 5 or pair.clipboard_sel_utf16_end != 8) {
        return error.RefusedCutStillMovedTheCaret;
    }
    if (pair.clipboard_sel_byte_start != 5 or pair.clipboard_sel_byte_end != 11) {
        return error.RefusedCutByteRangeIsNotTheSelection;
    }
    if (!pair.preedit_marked or pair.preedit_marked_bytes != 10) return error.PreeditWasNotMarked;
    if (pair.preedit_after_cancel_bytes != 7 or pair.preedit_after_cancel_marked) {
        return error.PreeditCancelDidNotRestore;
    }
    if (!std.mem.eql(u8, pair.semantic_role, "text_input")) return error.SemanticRoleIsNotATextInput;
    if (!std.mem.eql(u8, pair.semantic_name, "Editable field")) return error.SemanticNameIsNotTheField;
    if (!std.mem.eql(u8, pair.semantic_value, "seed \u{00e9}")) return error.SemanticValueIsNotTheModel;
    if (pair.semantic_anchor != 7 or pair.semantic_focus != 7) return error.SemanticSelectionIsNotTheCaret;
    if (!pair.semantic_addressable) return error.SemanticFieldIsNotAddressable;
    if (!pair.semantic_replaceable) return error.SemanticFieldCannotReplaceItsSelection;
    if (!pair.semantic_focusable) return error.SemanticFieldIsNotFocusable;
    if (!pair.semantic_focused) return error.SemanticFieldLostItsFocusState;
    if (!std.mem.eql(u8, pair.semantic_checkbox_role, "check_box")) return error.CheckboxRoleIsNotACheckBox;
    if (!std.mem.eql(u8, pair.semantic_checkbox_name, "Agreed")) return error.CheckboxNameMoved;
    if (!std.mem.eql(u8, pair.semantic_checkbox_checked, "on")) return error.CheckboxIsNotPublishedOn;
    if (pair.semantic_checkbox_focusable) return error.CheckboxPublishedItselfFocusable;
    if (pair.semantic_checkbox_focused) return error.CheckboxPublishedItselfFocused;
    if (pair.semantic_char_count != pair.char_count) {
        return error.PublishedBoxesAreNotTheShapedOnes;
    }
    // Three real boxes: the two controls and the box the model's own bytes were
    // measured into.
    if (pair.field_rect[2] <= 0 or pair.field_rect[3] <= 0) return error.FieldLaidOutNoBox;
    if (pair.checkbox_rect[2] <= 0 or pair.checkbox_rect[3] <= 0) return error.CheckboxLaidOutNoBox;
    if (pair.value_rect[2] <= 0 or pair.value_rect[3] <= 0) return error.ModelValueLaidOutNoBox;
}

// ── Output ───────────────────────────────────────────────────────────────────

fn appendJsonString(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    bytes: []const u8,
) !void {
    try out.append(gpa, '"');
    for (bytes) |byte| switch (byte) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
            const escaped = try std.fmt.allocPrint(gpa, "\\u{x:0>4}", .{byte});
            defer gpa.free(escaped);
            try out.appendSlice(gpa, escaped);
        },
        // A UTF-8 continuation byte is part of the value, not a control
        // character: the record is UTF-8 and those bytes pass through.
        else => try out.append(gpa, byte),
    };
    try out.append(gpa, '"');
}

fn appendName(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
) !void {
    if (out.items.len != 0) try out.append(gpa, ',');
    try appendJsonString(gpa, out, name);
    try out.append(gpa, ':');
}

fn appendValue(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    comptime fmt: []const u8,
    value: anytype,
) !void {
    try appendName(gpa, out, name);
    const text = try std.fmt.allocPrint(gpa, fmt, .{value});
    defer gpa.free(text);
    try out.appendSlice(gpa, text);
}

fn appendBool(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    value: bool,
) !void {
    try appendName(gpa, out, name);
    try out.appendSlice(gpa, if (value) "true" else "false");
}

fn appendText(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    value: []const u8,
) !void {
    try appendName(gpa, out, name);
    try appendJsonString(gpa, out, value);
}

fn appendRect(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    rect: [4]f32,
) !void {
    try appendName(gpa, out, name);
    try out.append(gpa, '[');
    for (rect, 0..) |value, index| {
        if (index != 0) try out.append(gpa, ',');
        const text = try std.fmt.allocPrint(gpa, "{d:.3}", .{value});
        defer gpa.free(text);
        try out.appendSlice(gpa, text);
    }
    try out.append(gpa, ']');
}

/// One JSON array of the numbers a real measurement produced. A shape
/// substitute that repeated one number for every character would still print
/// here, which is why the record also publishes the smallest and the largest
/// advance: a fixed grid gives the same answer twice.
fn appendNumbers(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    values: []const f32,
) !void {
    try appendName(gpa, out, name);
    try out.append(gpa, '[');
    for (values, 0..) |value, index| {
        if (index != 0) try out.append(gpa, ',');
        const text = try std.fmt.allocPrint(gpa, "{d:.3}", .{value});
        defer gpa.free(text);
        try out.appendSlice(gpa, text);
    }
    try out.append(gpa, ']');
}

fn appendWindowId(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    value: ?u32,
) !void {
    try appendName(gpa, out, name);
    if (value) |id| {
        const text = try std.fmt.allocPrint(gpa, "{d}", .{id});
        defer gpa.free(text);
        try out.appendSlice(gpa, text);
    } else {
        try out.appendSlice(gpa, "null");
    }
}

/// One `STATE-PAIR` line: a single strict JSON object, written only after every
/// expectation above held.
fn emitPair(gpa: std.mem.Allocator, io: std.Io, pair: *const Pair) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try appendText(gpa, &body, "record", "state-pair");
    try appendValue(gpa, &body, "target_width", "{d}", pair.target_width);
    try appendValue(gpa, &body, "target_height", "{d}", pair.target_height);
    try appendValue(gpa, &body, "scale_x", "{d:.3}", pair.scale_x);
    try appendValue(gpa, &body, "scale_y", "{d:.3}", pair.scale_y);
    try appendText(gpa, &body, "authored_field", pair.authored_field);
    try appendValue(gpa, &body, "authored_bytes", "{d}", pair.authored_bytes);
    try appendValue(gpa, &body, "authored_utf16", "{d}", pair.authored_utf16);
    try appendBool(gpa, &body, "authored_checkbox", pair.authored_checkbox);
    try appendText(gpa, &body, "model_text", pair.text);
    try appendValue(gpa, &body, "model_bytes", "{d}", pair.bytes);
    try appendValue(gpa, &body, "model_utf16", "{d}", pair.utf16);
    try appendValue(gpa, &body, "sel_utf16_start", "{d}", pair.sel_utf16_start);
    try appendValue(gpa, &body, "sel_utf16_end", "{d}", pair.sel_utf16_end);
    try appendValue(gpa, &body, "sel_byte_start", "{d}", pair.sel_byte_start);
    try appendValue(gpa, &body, "sel_byte_end", "{d}", pair.sel_byte_end);
    try appendBool(gpa, &body, "sel_reversed", pair.reversed);
    try appendBool(gpa, &body, "marked", pair.marked);
    try appendText(gpa, &body, "focus_key", pair.focus_key);
    try appendBool(gpa, &body, "focus_is_field", pair.focus_is_field);
    try appendBool(gpa, &body, "endpoint_registered", pair.endpoint_registered);
    try appendValue(gpa, &body, "caret_x", "{d:.3}", pair.caret_x);
    try appendValue(gpa, &body, "caret_y", "{d:.3}", pair.caret_y);
    try appendValue(gpa, &body, "caret_w", "{d:.3}", pair.caret_w);
    try appendValue(gpa, &body, "caret_h", "{d:.3}", pair.caret_h);
    // The text engine's own geometry. These are compared between the routes
    // and checked against the box the App laid out; none of them is a number
    // this file chose.
    try appendValue(gpa, &body, "text_line_height", "{d:.3}", pair.text_line_height);
    try appendValue(gpa, &body, "text_ink_width", "{d:.3}", pair.text_ink_width);
    try appendNumbers(gpa, &body, "char_x", pair.char_x[0..pair.char_count]);
    try appendNumbers(gpa, &body, "char_w", pair.char_w[0..pair.char_count]);
    try appendValue(gpa, &body, "char_count", "{d}", pair.char_count);
    try appendValue(gpa, &body, "char_advance_min", "{d:.3}", pair.char_advance_min);
    try appendValue(gpa, &body, "char_advance_max", "{d:.3}", pair.char_advance_max);
    try appendValue(gpa, &body, "semantic_char_count", "{d}", pair.semantic_char_count);
    try appendBool(gpa, &body, "checkbox", pair.checkbox);
    try appendValue(gpa, &body, "flips", "{d}", pair.flips);
    try appendText(gpa, &body, "clipboard_port", pair.clipboard_port);
    try appendText(gpa, &body, "clipboard_cut", pair.clipboard_cut);
    try appendValue(gpa, &body, "clipboard_bytes_after_cut", "{d}", pair.clipboard_bytes_after_cut);
    try appendValue(gpa, &body, "clipboard_sel_utf16_start", "{d}", pair.clipboard_sel_utf16_start);
    try appendValue(gpa, &body, "clipboard_sel_utf16_end", "{d}", pair.clipboard_sel_utf16_end);
    try appendValue(gpa, &body, "clipboard_sel_byte_start", "{d}", pair.clipboard_sel_byte_start);
    try appendValue(gpa, &body, "clipboard_sel_byte_end", "{d}", pair.clipboard_sel_byte_end);
    try appendBool(gpa, &body, "preedit_marked", pair.preedit_marked);
    try appendValue(gpa, &body, "preedit_marked_bytes", "{d}", pair.preedit_marked_bytes);
    try appendValue(gpa, &body, "preedit_after_cancel_bytes", "{d}", pair.preedit_after_cancel_bytes);
    try appendBool(gpa, &body, "preedit_after_cancel_marked", pair.preedit_after_cancel_marked);
    try appendText(gpa, &body, "semantic_role", pair.semantic_role);
    try appendText(gpa, &body, "semantic_name", pair.semantic_name);
    try appendText(gpa, &body, "semantic_value", pair.semantic_value);
    try appendValue(gpa, &body, "semantic_anchor", "{d}", pair.semantic_anchor);
    try appendValue(gpa, &body, "semantic_focus", "{d}", pair.semantic_focus);
    try appendBool(gpa, &body, "semantic_addressable", pair.semantic_addressable);
    try appendBool(gpa, &body, "semantic_replaceable", pair.semantic_replaceable);
    try appendBool(gpa, &body, "semantic_focusable", pair.semantic_focusable);
    try appendBool(gpa, &body, "semantic_focused", pair.semantic_focused);
    try appendText(gpa, &body, "semantic_checkbox_role", pair.semantic_checkbox_role);
    try appendText(gpa, &body, "semantic_checkbox_name", pair.semantic_checkbox_name);
    try appendText(gpa, &body, "semantic_checkbox_checked", pair.semantic_checkbox_checked);
    try appendBool(gpa, &body, "semantic_checkbox_focusable", pair.semantic_checkbox_focusable);
    try appendBool(gpa, &body, "semantic_checkbox_focused", pair.semantic_checkbox_focused);
    try appendValue(gpa, &body, "published_nodes", "{d}", pair.published_nodes);
    try appendRect(gpa, &body, "field_rect", pair.field_rect);
    try appendRect(gpa, &body, "checkbox_rect", pair.checkbox_rect);
    try appendRect(gpa, &body, "value_rect", pair.value_rect);
    // The only fields that describe the platform rather than the state.
    try appendText(gpa, &body, "mode", pair.mode);
    try appendBool(gpa, &body, "synthetic_input", pair.synthetic_input);
    try appendText(gpa, &body, "native_text_input", pair.native_text_input);
    try appendWindowId(gpa, &body, "native_window_id", pair.native_window_id);
    try appendValue(gpa, &body, "presented_frames", "{d}", pair.presented_frames);
    try appendValue(gpa, &body, "host_polls", "{d}", pair.host_polls);
    try body.append(gpa, '}');

    const line = try std.fmt.allocPrint(gpa, "STATE-PAIR {{{s}\n", .{body.items});
    defer gpa.free(line);
    try std.Io.File.stdout().writeStreamingAll(io, line);
}

// ── The command line ─────────────────────────────────────────────────────────

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

const RunOptions = struct {
    vert: []const u8,
    frag: []const u8,
    sort: []const u8,
    ppm: ?[]const u8 = null,
    fullscreen: ?[]const u8 = null,
    oklab: ?[]const u8 = null,
    native: bool = false,

    /// Where the blit modules come from when the command line does not name
    /// them: relative to the working directory, exactly as the in-tree presented
    /// parity examples already require.
    fn fullscreenPath(self: RunOptions) []const u8 {
        return self.fullscreen orelse "shaders/fullscreen_vert.spv";
    }

    fn oklabPath(self: RunOptions) []const u8 {
        return self.oklab orelse "shaders/blit_oklab.spv";
    }
};

/// Everything this run owns. `init` builds in the reverse of `deinit`, so a
/// failure part way through still retires exactly what was built, and
/// `deinit` retires in the order the resources require: the App's own detach,
/// then every device-side resource, then the window and the host, then the
/// model and the publisher, then the App, the view and the session.
///
/// A cleanup guard is registered only AFTER the value it guards exists. A
/// guard over an `undefined` field would free bytes nobody allocated, so the
/// two blit modules are nullable owners and the three always-loaded modules
/// register their guard after their own load.
const Rig = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: RunOptions,
    scenario: *Scenario = undefined,
    painter: *Painter = undefined,
    vert: ShaderFile = undefined,
    frag: ShaderFile = undefined,
    sort: ShaderFile = undefined,
    fullscreen: ?ShaderFile = null,
    oklab: ?ShaderFile = null,

    /// Release the blit modules this route opened. A missing module is not an
    /// error: only the presented route opens them, and one of the two can be
    /// absent when the other load failed.
    fn deinitBlit(self: *Rig) void {
        if (self.fullscreen) |*file| file.deinit(self.gpa);
        if (self.oklab) |*file| file.deinit(self.gpa);
        self.fullscreen = null;
        self.oklab = null;
    }

    fn init(gpa: std.mem.Allocator, io: std.Io, options: RunOptions) !*Rig {
        const self = try gpa.create(Rig);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .options = options };
        self.sort = try ShaderFile.load(gpa, io, options.sort);
        errdefer self.sort.deinit(gpa);
        self.frag = try ShaderFile.load(gpa, io, options.frag);
        errdefer self.frag.deinit(gpa);
        self.vert = try ShaderFile.load(gpa, io, options.vert);
        errdefer self.vert.deinit(gpa);
        errdefer self.deinitBlit();
        // Only the presented route records a blit, so only it opens the two
        // modules that blit is drawn with. `oklab` is published the moment it
        // exists, so a failed second load still releases it.
        if (options.native) {
            self.oklab = try ShaderFile.load(gpa, io, options.oklabPath());
            self.fullscreen = try ShaderFile.load(gpa, io, options.fullscreenPath());
        }
        self.scenario = try Scenario.init(gpa);
        // A painter that fails to build releases itself, and exactly one
        // release path ever owns the scenario.
        self.painter = Painter.init(gpa, io, .{
            .mode = if (options.native) .presented else .windowless,
            .shaders = .{ .vert = self.vert.words, .frag = self.frag.words, .sort = self.sort.words },
            .blit = .{
                .fullscreen = if (self.fullscreen) |file| file.words else &[_]u32{},
                .oklab = if (self.oklab) |file| file.words else &[_]u32{},
            },
            .app = self.scenario.app,
            .session = self.scenario.session,
        }) catch |err| {
            self.scenario.teardown();
            return err;
        };
        // From here the scenario owns the painter's teardown, in the order the
        // resources require, including the window and the host.
        errdefer self.scenario.teardown();
        try self.scenario.attachGpu(self.painter);
        return self;
    }

    fn deinit(self: *Rig) !void {
        defer self.gpa.destroy(self);
        defer self.vert.deinit(self.gpa);
        defer self.frag.deinit(self.gpa);
        defer self.sort.deinit(self.gpa);
        defer self.deinitBlit();
        try self.scenario.release();
    }
};

/// Run the scenario on one route, refuse anything this scenario did not
/// produce, and print the record.
fn runPair(rig: *Rig) !void {
    const mode: Mode = if (rig.options.native) .presented else .windowless;
    const scenario = rig.scenario;
    var guarded: Guarded = undefined;
    switch (mode) {
        .windowless => guarded = try runScenario(scenario, .{
            .context = scenario,
            .frame = windowlessFrame,
            .send = windowlessSend,
        }),
        .presented => {
            var hosted: Hosted = .{
                .application = rig.painter.path.presented.application,
                .window = rig.painter.path.presented.handle,
            };
            // The host bound this window's own native text-input port at open,
            // so the endpoint the scenario registers starts REAL native text
            // input. The refusing clipboard port is installed inside the
            // scenario, before its first edit, on both routes.
            guarded = try runScenario(scenario, .{
                .context = &hosted,
                .frame = Hosted.hostedFrame,
                .send = Hosted.hostedSend,
            });
            // The windowless route presents nothing, so there is nothing to
            // hold: only this one waits for the platform to finish.
            try rig.painter.hold();
            if (hosted.ambient != 0) {
                std.debug.print(
                    "state_pair: {d} SDL events named no window this run opened and were left alone\n",
                    .{hosted.ambient},
                );
            }
        },
    }

    // The pixels are inspected separately from the state: a frame that drew
    // nothing is refused here, and the optional PPM is where a person looks.
    if (rig.painter.pixels.len == 0) return error.NoRenderedTarget;
    const pair = try buildPair(scenario, mode, guarded);
    try expectPair(&pair);
    if (rig.options.ppm) |path| {
        try v7_frame.writePpm(rig.gpa, rig.io, path, rig.painter.pixels, target);
    }
    try emitPair(rig.gpa, rig.io, &pair);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;
    var options: RunOptions = .{
        .vert = args.next() orelse return error.MissingVertexShader,
        .frag = args.next() orelse return error.MissingFragmentShader,
        .sort = args.next() orelse return error.MissingSortShader,
    };
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--native")) {
            options.native = true;
        } else if (std.mem.eql(u8, arg, "--ppm")) {
            if (options.ppm != null) return error.RepeatedArgument;
            options.ppm = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--fullscreen-vert")) {
            if (options.fullscreen != null) return error.RepeatedShaderPath;
            options.fullscreen = args.next() orelse return error.MissingShaderPath;
        } else if (std.mem.eql(u8, arg, "--blit-oklab")) {
            if (options.oklab != null) return error.RepeatedShaderPath;
            options.oklab = args.next() orelse return error.MissingShaderPath;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownArgument;
        } else if (options.ppm == null) {
            // A bare trailing path is the PPM, exactly as the windowless
            // consumer has always taken it.
            options.ppm = arg;
        } else return error.UnexpectedArgument;
    }

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const rig = try Rig.init(gpa, threaded.io(), options);
    var rig_live = true;
    // A failed run still retires everything it built, and a teardown failure
    // while another failure is in flight is named rather than dropped.
    errdefer if (rig_live) rig.deinit() catch |err| std.debug.panic(
        "state_pair: teardown after a failed run reported {s}",
        .{@errorName(err)},
    );
    try runPair(rig);
    rig_live = false;
    try rig.deinit();
}
