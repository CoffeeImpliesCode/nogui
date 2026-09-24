//! Real shaped geometry AND real painted pixels for the W12 native run.
//!
//! The default headless mode of `w12_ime_smoke.zig` uses a fixed-advance grid
//! on purpose: its geometry is synthetic, and its report says so. That grid
//! is enough to prove the protocol and the host path, and it is not glyph
//! geometry.
//!
//! This file is the other half. The field the native modes register is shaped
//! by the SAME `TextService` the renderer rasterizes with — the engine
//! `v7_frame.NativeFrame` owns, reached as `&engine.service` — so the glyphs
//! on screen, the rectangle handed to `SDL_StartTextInputArea`, the grapheme
//! boundaries a motion walks and the UTF-16 ranges a commit replaces are one
//! measurement. There is no second service in this file that could agree today
//! and disagree tomorrow.
//!
//! ONE layout per model state: `Ink` keeps exactly one shaped snapshot, keyed
//! on the model's own revision, and the protocol operations mutate the model
//! the core already borrowed rather than taking a second store borrow. So
//! painted glyphs, range boxes, caret geometry and the published candidate
//! rectangle can never describe bytes the model no longer holds, and no
//! operation can fail with a conflicting access against the very borrow it was
//! called with.
//!
//! `Ink.paint` appends the field's own scene rects — its box, the selection
//! behind the text, the glyph quads of that one layout, the preedit's boxes
//! and underline, and the caret bar — to the frame's scene list through the
//! public renderer path, and returns what it actually recorded so a report
//! can name pixels instead of the text it meant to draw.
const std = @import("std");

const nogui = @import("nogui");
const cpu = @import("nogui_text");
const frame = @import("v7_frame");

const text_input = nogui.text_input;
pub const Utf16Range = text_input.Utf16Range;
const Selection = text_input.Selection;
const Session = nogui.Session;
const text_api = nogui.text;
const geometry = nogui.geometry;

/// One size, used by the layout, by the published caret and by anything that
/// later renders this field. Two sizes would make the caret on screen and the
/// caret the IME is told about different numbers, which is the failure this
/// whole file exists to prevent.
pub const font_size: u32 = 20;
pub const font_size_f32: f32 = @floatFromInt(font_size);

/// The layout's line box. Public because a caller that scrolls the field by
/// whole lines has to use the same number the layout does.
pub const line_height: f32 = 28;

/// The field's box in window coordinates. Wrapping width and the scroll offset
/// are resolved through the layout, never through a column count.
pub const Geometry = struct {
    origin_x: f32 = 24,
    origin_y: f32 = 40,
    width: f32 = 320,
    /// Visual lines the field shows.
    visible_lines: usize = 3,
    scroll_px: f32 = 0,

    pub fn viewportHeight(self: Geometry) f32 {
        return @as(f32, @floatFromInt(self.visible_lines)) * line_height;
    }
};

fn sameGeometry(a: Geometry, b: Geometry) bool {
    return a.origin_x == b.origin_x and a.origin_y == b.origin_y and
        a.width == b.width and a.visible_lines == b.visible_lines and
        a.scroll_px == b.scroll_px;
}

/// The field's own painted box, border included. The mounted view clips to
/// exactly this rectangle, so a scrolled line is cut by the field and not by
/// the window.
pub fn paintBox(box: Geometry, padding: f32) geometry.WindowRect {
    return .{
        .x = box.origin_x - padding,
        .y = box.origin_y - padding,
        .w = box.width + 2 * padding,
        .h = box.viewportHeight() + 2 * padding,
    };
}

/// The field's own style, in sRGB. The scene converts every one of these to
/// Oklab exactly like any other authored fill, so the field lives in the same
/// color space as the tree around it. `text` is part of the LAYOUT request, not
/// of the paint call: a glyph is the color its own runs were shaped with.
pub const Palette = struct {
    /// The unfocused border.
    border: [4]f32 = .{ 0.32, 0.36, 0.42, 1.0 },
    border_focused: [4]f32 = .{ 0.36, 0.64, 0.95, 1.0 },
    /// The fill under the text.
    surface: [4]f32 = .{ 0.09, 0.10, 0.12, 1.0 },
    text: [4]f32 = .{ 0.93, 0.94, 0.96, 1.0 },
    selection: [4]f32 = .{ 0.24, 0.42, 0.66, 0.85 },
    preedit: [4]f32 = .{ 0.20, 0.36, 0.58, 0.60 },
    preedit_underline: [4]f32 = .{ 0.42, 0.78, 1.0, 1.0 },
    caret: [4]f32 = .{ 0.98, 0.98, 1.0, 1.0 },
    caret_width: f32 = 2,
    padding: f32 = 6,
    /// The border's stroke, in logical units.
    border_width: f32 = 1,
};

/// The sort key the field's own rects start at. A widget's layer is a small
/// layout number, and this field is an application-owned model rather than a
/// tree node, so it paints on its own layer above all of them: a caret can
/// never end up behind a button. Inside the field the order is box, preedit
/// fill, selection, glyphs, preedit underline, caret.
pub const field_layer: u32 = 1 << 24;
pub const box_layer: u32 = field_layer;
pub const preedit_layer: u32 = field_layer + 1;
pub const selection_layer: u32 = field_layer + 2;
pub const glyph_layer: u32 = field_layer + 3;
pub const underline_layer: u32 = field_layer + 4;
pub const caret_layer: u32 = field_layer + 5;

/// The application-owned field. The core holds none of these bytes: the
/// endpoint borrows the model for one call and everything resolves here.
pub const Field = struct {
    gpa: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    selection: Selection = .{},
    marked: ?Utf16Range = null,
    geometry: Geometry = .{},
    /// A second insertion of the same bytes still moves this counter, so a
    /// duplicate is visible even when the resulting text compares equal.
    replacements: u32 = 0,
    marks: u32 = 0,
    /// Bumped by every change to the bytes or the box. The one shaped layout
    /// is keyed on it, so a layout can never describe text this model no
    /// longer holds. A selection change does not bump it: the layout does not
    /// depend on where the caret is.
    revision: u64 = 1,

    pub fn deinit(self: *Field, _: *Session) void {
        self.text.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn slice(self: *const Field) []const u8 {
        return self.text.items;
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
        self.revision += 1;
    }

    /// The protocol target: an explicit range, else the marked range, else
    /// the selection. This order is what keeps a platform commit from
    /// appending after the preedit it is committing.
    fn target(self: *const Field, range: ?Utf16Range) Utf16Range {
        return range orelse self.marked orelse self.selection.range;
    }
};

/// One shaped snapshot of the field's own bytes at the field's own width.
pub const Shaped = struct {
    layout: cpu.TextLayout,
    geometry: Geometry,
    /// The model revision this layout was shaped from.
    revision: u64 = 0,

    pub fn deinit(self: *Shaped) void {
        self.layout.deinit();
        self.* = undefined;
    }

    fn lineOf(self: *const Shaped, unit: usize) ?cpu.LayoutLine {
        const byte = self.layout.utf16ToByte(unit) catch return null;
        const position = self.layout.byteToPosition(byte, .downstream) catch return null;
        if (position.line >= self.layout.lines.len) return null;
        return self.layout.lines[position.line];
    }

    /// The caret box in window coordinates, or null when the caret is scrolled
    /// out of the field. A candidate window anchored to a caret nobody can see
    /// is worse than no candidate window at all.
    pub fn caretRect(self: *const Shaped, unit: usize) ?geometry.WindowRect {
        const line = self.lineOf(unit) orelse return null;
        const byte = self.layout.utf16ToByte(unit) catch return null;
        const position = self.layout.byteToPosition(byte, .downstream) catch return null;
        const top = self.geometry.origin_y + line.y - self.geometry.scroll_px;
        if (top + line.height <= self.geometry.origin_y) return null;
        if (top >= self.geometry.origin_y + self.geometry.viewportHeight()) return null;
        return .{
            .x = self.geometry.origin_x + position.x,
            .y = top,
            .w = 0,
            .h = line.height,
        };
    }

    /// A UTF-16 range's boxes in window coordinates, one per visual line it
    /// touches, from this one layout.
    pub fn rangeBoxes(self: *const Shaped, gpa: std.mem.Allocator, range: Utf16Range) ![]geometry.WindowRect {
        const region = self.snapUnits(
            @min(range.start, range.end),
            @max(range.start, range.end),
        );
        if (region.start == region.end) return &.{};
        const boxes = try self.layout.rangeBounds(gpa, .{
            .start = self.layout.utf16ToByte(region.start) catch return &.{},
            .end = self.layout.utf16ToByte(region.end) catch return &.{},
        });
        defer gpa.free(boxes);
        const out = try gpa.alloc(geometry.WindowRect, boxes.len);
        for (boxes, out) |box, *mapped| {
            mapped.* = .{
                .x = self.geometry.origin_x + box.x,
                .y = self.geometry.origin_y + box.y - self.geometry.scroll_px,
                .w = box.width,
                .h = box.height,
            };
        }
        return out;
    }

    /// Snap a UTF-16 range outward to the layout's own grapheme boundaries, so
    /// a range that lands inside one user-perceived character can never split
    /// it. The core validates the unit arithmetic; the endpoint owns where a
    /// character begins, and the layout is the authority.
    pub fn snapUnits(self: *const Shaped, low: usize, high: usize) Utf16Range {
        return .{
            .start = self.snapUnit(low, .backward),
            .end = self.snapUnit(high, .forward),
        };
    }

    const Direction = enum { forward, backward };

    fn snapUnit(self: *const Shaped, unit: usize, direction: Direction) usize {
        const byte = self.layout.utf16ToByte(unit) catch return 0;
        for (self.layout.graphemes) |item| {
            if (byte > item.start and byte < item.end) {
                return self.layout.byteToUtf16(if (direction == .forward) item.end else item.start) catch unit;
            }
        }
        // A byte that is not inside any grapheme is already on a boundary.
        return self.layout.byteToUtf16(byte) catch unit;
    }
};

/// What one painted frame of the field actually contained. Every number is
/// what went into the scene, so a report can name the pixels it recorded
/// instead of the text it meant to record.
pub const Painted = struct {
    /// Scene rects this call added to the frame.
    rects: u32 = 0,
    /// Rects the one layout's runs emitted: one per glyph, plus any run
    /// background or decoration the style asked for. This field's style asks
    /// for neither, so a frame that reports glyphs reported glyphs.
    glyphs: u32 = 0,
    /// Selection boxes behind the text.
    selection: u32 = 0,
    /// Preedit boxes under the composition.
    preedit: u32 = 0,
    /// The caret bar was painted.
    caret: bool = false,
    /// The candidate rectangle this paint published, in window coordinates.
    /// Null exactly when the caret was scrolled out of the field, which is
    /// also exactly when no caret was painted.
    caret_rect: ?geometry.WindowRect = null,
};

pub const PaintOptions = struct {
    /// An unfocused field paints no caret: the caret IS the focus indicator.
    focused: bool = true,
    /// The frame's clip id for the field's viewport, or `frame.native.no_clip` when
    /// the caller has no clip for it. A clip is how a scrolled line is cut by
    /// the field instead of by the window.
    clip: u32 = frame.native.no_clip,
};

/// The native field, the shared text engine that shapes it, and the one layout
/// of its current bytes.
pub const Ink = struct {
    gpa: std.mem.Allocator,
    /// The engine whose `service` shapes every layout here and whose
    /// `emitLayout` rasterizes the same runs. There is no second service: the
    /// caret this file publishes and the glyphs it paints are one
    /// measurement.
    engine: *frame.TextEngine,
    /// The engine's first registered face. It is the same face the engine
    /// rasterizes, so a missing glyph is missing in both.
    font: text_api.FontHandle,
    session: *Session,
    owner: nogui.Model(Field),
    /// Choose before registering an endpoint for this field.
    policy: text_input.Policy = .{},
    // SAFETY: init sets user to this stable address before exposing an endpoint.
    user: *anyopaque = undefined,
    /// Set when the model is gone, so the run reports a retired field instead
    /// of editing freed bytes.
    released: bool = false,
    /// The model's ONE shaped snapshot, kept until its bytes or box change.
    shaped: ?Shaped = null,
    /// The field's own style, used by both the layout request and the paint.
    palette: Palette = .{},

    /// `engine` must outlive this field: the service borrows the font bytes
    /// and the engine is what rasterizes the painted runs.
    pub fn init(
        self: *Ink,
        gpa: std.mem.Allocator,
        engine: *frame.TextEngine,
        session: *Session,
        initial: []const u8,
    ) !void {
        self.* = .{
            .gpa = gpa,
            .engine = engine,
            // The field paints the engine's PRIMARY face. Registration order
            // is the order the engine was given, and there is no integer
            // selector to look a face up by any more.
            .font = engine.service.listFonts()[0].handle,
            .session = session,
            // SAFETY: Session.create sets owner before init returns successfully.
            .owner = undefined,
        };
        var value: Field = .{ .gpa = gpa };
        try value.text.appendSlice(gpa, initial);
        const units = try text_input.utf16Length(initial);
        value.selection = .{ .range = .{ .start = units, .end = units } };
        self.owner = try session.create(Field, &value);
        self.user = self;
    }

    pub fn deinit(self: *Ink) void {
        self.dropLayout();
        if (!self.released) {
            self.session.release(Field, &self.owner) catch |err|
                std.debug.panic("W12 field model release failed: {s}", .{@errorName(err)});
            self.released = true;
        }
        self.* = undefined;
    }

    /// Shape the field's own bytes at its own width, in its own style. The
    /// service caches the shaping, so an unchanged string costs a request and
    /// not a re-shape.
    pub fn shape(self: *Ink, text: []const u8, box: Geometry) !Shaped {
        const request: text_api.LayoutRequest = .{
            .content = text,
            .style = .{
                .font = .{ .handle = self.font, .size = font_size },
                .foreground = self.palette.text,
            },
            .paragraph = .{
                .wrap = .flow,
                .wrap_width = box.width,
                .line_height = line_height,
            },
        };
        return .{ .layout = try self.engine.service.layout(self.gpa, request), .geometry = box };
    }

    /// THE layout of the model's current bytes.
    ///
    /// The core calls the protocol with the model already borrowed, so this
    /// never takes a store borrow of its own: it shapes from the borrow in
    /// hand and keeps the result until the bytes or the box change. Painted
    /// glyphs, grapheme motion, range boxes, the caret and the candidate
    /// rectangle all read this one value.
    fn layoutFor(self: *Ink, model: *const Field) anyerror!*Shaped {
        if (self.shaped) |*live| {
            if (live.revision == model.revision and sameGeometry(live.geometry, model.geometry)) return live;
            live.deinit();
            self.shaped = null;
        }
        var fresh = try self.shape(model.slice(), model.geometry);
        fresh.revision = model.revision;
        self.shaped = fresh;
        return &self.shaped.?;
    }

    fn dropLayout(self: *Ink) void {
        if (self.shaped) |*live| {
            live.deinit();
            self.shaped = null;
        }
    }

    /// The protocol vtable for this model. It reads the shaped layout through
    /// the endpoint's own `user` pointer, so building it needs no receiver:
    /// one value serves every field of this type.
    pub fn ops() text_input.Ops {
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

    pub fn endpoint(self: *Ink, id: nogui.WidgetId) text_input.Endpoint {
        return .{
            .id = id,
            .owner = self.owner.weak().erase(),
            .ops = Ink.ops(),
            .user = self.user,
            .policy = self.policy,
        };
    }

    /// Append the field's own scene rects: its box, the selection behind the
    /// text, the glyph quads of the ONE layout, the preedit's boxes and
    /// underline, and the caret bar. Call it after the frame's scene is built
    /// and before the frame is recorded, with that frame's own scene list.
    ///
    /// Every rect is clipped by `options.clip` when the caller supplies one,
    /// so a scrolled line is cut by the field. Nothing here reads a second
    /// layout, and nothing here paints text the model does not hold.
    pub fn paint(
        self: *Ink,
        out: *std.ArrayList(frame.native.SceneRect),
        options: PaintOptions,
    ) !Painted {
        if (self.released) return error.EndpointReleased;
        const Body = struct {
            const Self = @This();
            ink: *Ink,
            out: *std.ArrayList(frame.native.SceneRect),
            options: PaintOptions,
            painted: Painted = .{},
            fn run(model: *const Field, context: *anyopaque) anyerror!void {
                const typed: *Self = @ptrCast(@alignCast(context));
                typed.painted = try typed.ink.paintModel(model, typed.out, typed.options);
            }
        };
        var exchange: Body = .{ .ink = self, .out = out, .options = options };
        try self.session.read(Field, self.owner, &exchange, Body.run);
        return exchange.painted;
    }

    fn paintModel(
        self: *Ink,
        model: *const Field,
        out: *std.ArrayList(frame.native.SceneRect),
        options: PaintOptions,
    ) !Painted {
        const shaped = try self.layoutFor(model);
        const box = shaped.geometry;
        const palette = self.palette;
        const first: u32 = @intCast(out.items.len);
        var painted: Painted = .{};

        // The box: the border, then the surface inside it. A focused field
        // says so with its border and with its caret, and the caret is
        // skipped entirely while another target owns the keyboard.
        const frame_box = paintBox(box, palette.padding);
        try appendSolid(self.gpa, out, box_layer, options.clip, frame_box, if (options.focused)
            palette.border_focused
        else
            palette.border);
        try appendSolid(self.gpa, out, box_layer, options.clip, .{
            .x = frame_box.x + palette.border_width,
            .y = frame_box.y + palette.border_width,
            .w = frame_box.w - 2 * palette.border_width,
            .h = frame_box.h - 2 * palette.border_width,
        }, palette.surface);

        // The preedit's own boxes, resolved ONCE: the fill goes under the
        // glyphs and the underline over them, and both come from the one
        // layout, so they cannot describe different ranges.
        var preedit: ?[]geometry.WindowRect = null;
        defer if (preedit) |boxes| self.gpa.free(boxes);
        if (model.marked) |marked| preedit = try shaped.rangeBoxes(self.gpa, marked);
        if (preedit) |boxes| {
            for (boxes) |box_rect| {
                try appendSolid(self.gpa, out, preedit_layer, options.clip, box_rect, palette.preedit);
            }
            painted.preedit = @intCast(boxes.len);
        }

        // The selection, behind the text it covers.
        if (!model.selection.range.isEmpty()) {
            const boxes = try shaped.rangeBoxes(self.gpa, model.selection.range);
            defer self.gpa.free(boxes);
            for (boxes) |box_rect| {
                try appendSolid(self.gpa, out, selection_layer, options.clip, box_rect, palette.selection);
            }
            painted.selection = @intCast(boxes.len);
        }

        // The glyphs, from the one layout every other number came from.
        const glyph_first: u32 = @intCast(out.items.len);
        try self.engine.emitLayout(
            &self.engine.service,
            &shaped.layout,
            box.origin_x,
            box.origin_y - box.scroll_px,
            options.clip,
            glyph_layer,
            out,
        );
        painted.glyphs = @as(u32, @intCast(out.items.len)) - glyph_first;

        // The preedit's underline, over the glyphs it belongs to.
        if (preedit) |boxes| {
            for (boxes) |box_rect| {
                try appendSolid(self.gpa, out, underline_layer, options.clip, .{
                    .x = box_rect.x,
                    .y = box_rect.y + box_rect.h - 2,
                    .w = box_rect.w,
                    .h = 2,
                }, palette.preedit_underline);
            }
        }

        // The caret, from the same layout the candidate rectangle comes from.
        painted.caret_rect = shaped.caretRect(model.selection.cursor());
        if (options.focused) {
            if (painted.caret_rect) |caret| {
                try appendSolid(self.gpa, out, caret_layer, options.clip, .{
                    .x = caret.x - palette.caret_width / 2,
                    .y = caret.y,
                    .w = palette.caret_width,
                    .h = caret.h,
                }, palette.caret);
                painted.caret = true;
            }
        }

        painted.rects = @as(u32, @intCast(out.items.len)) - first;
        return painted;
    }

    /// Scroll the field. One store borrow, taken by the run and not by the
    /// protocol, and the revision moves so the next paint re-shapes.
    pub fn setScroll(self: *Ink, px: f32) !void {
        if (self.released) return error.EndpointReleased;
        const Body = struct {
            const Self = @This();
            px: f32,
            fn run(model: *Field, context: *anyopaque) anyerror!void {
                const typed: *Self = @ptrCast(@alignCast(context));
                if (typed.px == model.geometry.scroll_px) return;
                model.geometry.scroll_px = typed.px;
                model.revision += 1;
            }
        };
        var exchange: Body = .{ .px = px };
        try self.session.update(Field, self.owner, &exchange, Body.run);
    }

    // ── mutations, all on the borrow the core already handed us ──

    /// Replace the target range and collapse the caret onto the end of what
    /// was inserted. The range is snapped against the layout of the bytes
    /// being replaced, and the caret is converted through the layout of the
    /// bytes that replace them — one service, and never a layout that
    /// outlives its own text.
    fn replaceIn(self: *Ink, model: *Field, range: ?Utf16Range, text: []const u8) !void {
        const target = model.target(range);
        const region = blk: {
            const before = try self.layoutFor(model);
            const snapped = before.snapUnits(
                @min(target.start, target.end),
                @max(target.start, target.end),
            );
            const start = before.layout.utf16ToByte(snapped.start) catch model.slice().len;
            const end = before.layout.utf16ToByte(snapped.end) catch start;
            break :blk .{ .start = start, .end = end };
        };
        try model.splice(region.start, region.end, text);
        model.marked = null;
        const caret = blk: {
            const after = try self.layoutFor(model);
            break :blk after.layout.byteToUtf16(region.start + text.len) catch region.start;
        };
        model.selection = .{ .range = .{ .start = caret, .end = caret } };
        model.replacements += 1;
    }

    fn replaceAndMarkIn(
        self: *Ink,
        model: *Field,
        range: ?Utf16Range,
        text: []const u8,
        inside: ?Utf16Range,
    ) !void {
        const target = model.target(range);
        const region = blk: {
            const before = try self.layoutFor(model);
            const snapped = before.snapUnits(
                @min(target.start, target.end),
                @max(target.start, target.end),
            );
            const start = before.layout.utf16ToByte(snapped.start) catch model.slice().len;
            const end = before.layout.utf16ToByte(snapped.end) catch start;
            break :blk .{ .start = start, .end = end };
        };
        try model.splice(region.start, region.end, text);
        const outcome = blk: {
            const after = try self.layoutFor(model);
            const base = after.layout.byteToUtf16(region.start) catch 0;
            const length = try text_input.utf16Length(text);
            break :blk .{
                .base = base,
                .length = length,
                .caret = if (inside) |value| base + @min(value.end, length) else base + length,
            };
        };
        model.marked = if (text.len == 0) null else Utf16Range{
            .start = outcome.base,
            .end = outcome.base + outcome.length,
        };
        model.selection = .{ .range = .{ .start = outcome.caret, .end = outcome.caret } };
        model.marks += 1;
    }
};

/// One solid scene rect, in the same Oklab space every authored fill lowers
/// into. A zero-area or non-finite box is dropped rather than submitted: the
/// renderer has no meaning for it and a NaN in the bag poisons the sort.
fn appendSolid(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(frame.native.SceneRect),
    z: u32,
    clip: u32,
    box: geometry.WindowRect,
    color: [4]f32,
) !void {
    if (box.w <= 0 or box.h <= 0) return;
    if (!std.math.isFinite(box.x) or !std.math.isFinite(box.y) or
        !std.math.isFinite(box.w) or !std.math.isFinite(box.h)) return;
    try out.append(gpa, .{
        .dst = .{ box.x, box.y, box.w, box.h },
        .src = .{ 0, 0, 1, 1 },
        .corners = .{ 0, 0, 0, 0 },
        .color = frame.srgbToOklab(color),
        .curve = .{ 0, 0, 0, 0 },
        .material_index = 0,
        .clip_id = clip,
        .z = z,
        .origin = .{ box.x, box.y },
    });
}

fn inkOf(user: *anyopaque) *Ink {
    return @ptrCast(@alignCast(user));
}

// ── the ten protocol operations, answered from the shared layout ──

fn readText(
    allocator: std.mem.Allocator,
    field: *const Field,
    user: *anyopaque,
    range: Utf16Range,
    served: *Utf16Range,
) anyerror!?[]u8 {
    const ink = inkOf(user);
    const shaped = try ink.layoutFor(field);
    const region = shaped.snapUnits(@min(range.start, range.end), @max(range.start, range.end));
    const start = shaped.layout.utf16ToByte(region.start) catch return null;
    const end = shaped.layout.utf16ToByte(region.end) catch start;
    served.* = .{
        .start = shaped.layout.byteToUtf16(start) catch region.start,
        .end = shaped.layout.byteToUtf16(end) catch region.end,
    };
    const bytes = try allocator.dupe(u8, shaped.layout.content[start..end]);
    return bytes;
}

fn readSelection(field: *const Field, _: *anyopaque) anyerror!Selection {
    return field.selection;
}

fn readMarked(field: *const Field, _: *anyopaque) anyerror!?Utf16Range {
    return field.marked;
}

fn moveCaret(field: *Field, user: *anyopaque, request: text_input.Move) anyerror!Selection {
    const ink = inkOf(user);
    if (request.offset) |offset| {
        field.selection = .{ .range = .{ .start = offset, .end = offset } };
        return field.selection;
    }
    const shaped = try ink.layoutFor(field);
    const byte = shaped.layout.utf16ToByte(field.selection.cursor()) catch return field.selection;
    const next_byte: usize = switch (request.unit) {
        .grapheme => if (request.direction == .forward)
            (shaped.layout.nextGrapheme(byte) catch null) orelse shaped.layout.content.len
        else
            (shaped.layout.previousGrapheme(byte) catch null) orelse 0,
        // The layout's own line table decides where a line begins and ends,
        // so a wrapped caret and a wrapped line edge cannot disagree.
        .line => blk: {
            const position = shaped.layout.byteToPosition(byte, .downstream) catch break :blk byte;
            const lines = shaped.layout.lines;
            if (request.direction == .forward) {
                if (position.line + 1 >= lines.len) break :blk shaped.layout.content.len;
                break :blk lines[position.line + 1].start;
            }
            break :blk lines[position.line].start;
        },
        // A word is a run of non-whitespace plus the whitespace after it,
        // walked over the laid-out bytes. A fixture rule, not a language
        // tokenizer, and the only caller is the protocol's own word motion.
        .word => blk: {
            const words = shaped.layout.content;
            if (request.direction == .forward) {
                var at = byte;
                while (at < words.len and !isSpace(words[at])) at += sizeAt(words, at);
                while (at < words.len and isSpace(words[at])) at += 1;
                break :blk at;
            }
            var at = byte;
            while (at > 0 and isSpace(words[at - 1])) at -= 1;
            while (at > 0 and !isSpace(words[at - 1])) at -= sizeBefore(words, at);
            break :blk at;
        },
        .document => if (request.direction == .forward) shaped.layout.content.len else 0,
    };
    const unit = shaped.layout.byteToUtf16(next_byte) catch return field.selection;
    const anchor = field.selection.anchor();
    field.selection = if (request.extend)
        .{
            .range = .{ .start = @min(anchor, unit), .end = @max(anchor, unit) },
            .reversed = unit < anchor,
        }
    else
        .{ .range = .{ .start = unit, .end = unit } };
    return field.selection;
}

fn isSpace(value: u8) bool {
    return value == ' ' or value == '\t' or value == '\n' or value == '\r';
}

fn sizeAt(bytes: []const u8, index: usize) usize {
    if (index >= bytes.len) return 1;
    return std.unicode.utf8ByteSequenceLength(bytes[index]) catch 1;
}

fn sizeBefore(bytes: []const u8, index: usize) usize {
    var start = index - 1;
    while (start > 0 and bytes[start] & 0xc0 == 0x80) start -= 1;
    return index - start;
}

fn eraseText(field: *Field, user: *anyopaque, request: text_input.Erase) anyerror!void {
    const ink = inkOf(user);
    if (request.extend or !field.selection.range.isEmpty()) {
        try ink.replaceIn(field, null, "");
        return;
    }
    const shaped = try ink.layoutFor(field);
    const byte = shaped.layout.utf16ToByte(field.selection.cursor()) catch return;
    const next_byte = if (request.backward)
        (shaped.layout.previousGrapheme(byte) catch null) orelse 0
    else
        (shaped.layout.nextGrapheme(byte) catch null) orelse shaped.layout.content.len;
    const unit = shaped.layout.byteToUtf16(next_byte) catch return;
    const cursor = field.selection.cursor();
    try ink.replaceIn(field, .{
        .start = @min(cursor, unit),
        .end = @max(cursor, unit),
    }, "");
}

fn replaceText(field: *Field, user: *anyopaque, range: ?Utf16Range, text: []const u8) anyerror!void {
    try inkOf(user).replaceIn(field, range, text);
}

fn replaceAndMark(
    field: *Field,
    user: *anyopaque,
    range: ?Utf16Range,
    text: []const u8,
    inside: ?Utf16Range,
) anyerror!void {
    try inkOf(user).replaceAndMarkIn(field, range, text, inside);
}

fn unmarkText(field: *Field, _: *anyopaque) anyerror!void {
    field.marked = null;
}

fn caretGeometry(field: *const Field, user: *anyopaque, range: Utf16Range) anyerror!?text_input.Caret {
    const ink = inkOf(user);
    const shaped = try ink.layoutFor(field);
    // The line box is the candidate anchor and the caret's own x is already
    // folded into its origin, which is what SDL is given. It is the SAME
    // layout the painted caret comes from, in the same frame.
    const rect = shaped.caretRect(range.end) orelse return null;
    return .{ .area = rect, .cursor = 0 };
}

fn indexAtPoint(field: *const Field, user: *anyopaque, point: geometry.WindowPoint) anyerror!?usize {
    const ink = inkOf(user);
    const shaped = try ink.layoutFor(field);
    const top = shaped.geometry.origin_y;
    if (point.y < top) return 0;
    if (point.y > top + shaped.geometry.viewportHeight()) return 0;
    const row = @floor((point.y - top + shaped.geometry.scroll_px) / line_height);
    if (row < 0) return 0;
    const line_index: usize = @intFromFloat(row);
    if (line_index >= shaped.layout.lines.len) return 0;
    const position = shaped.layout.positionToByte(
        line_index,
        point.x - shaped.geometry.origin_x,
    ) catch return 0;
    return shaped.layout.byteToUtf16(position.byte) catch 0;
}

/// What the shaped field holds, copied out of its Session borrow. Nothing here
/// keeps a pointer into the model: the borrow ends when the read returns.
pub const State = struct {
    // SAFETY: copyState fills buffer[0..len] before text reads the snapshot.
    buffer: [512]u8 = undefined,
    len: usize = 0,
    selection: Selection = .{},
    marked: ?Utf16Range = null,
    replacements: u32 = 0,
    marks: u32 = 0,
    lines: usize = 0,
    width: f32 = 0,
    geometry: Geometry = .{},

    pub fn text(self: *const State) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// The real geometry one report line needs: the shaped field's own state, the
/// caret rectangle the endpoint would publish, and the preedit's own boxes.
pub const Measured = struct {
    state: State,
    caret: ?geometry.WindowRect,
    /// Owned by the field's allocator; empty when no preedit is open. Release
    /// it with `deinit`.
    preedit: []geometry.WindowRect,

    pub fn deinit(self: *Measured, gpa: std.mem.Allocator) void {
        gpa.free(self.preedit);
        self.* = undefined;
    }
};

/// The whole model as one shaped snapshot: its state, the caret rectangle the
/// endpoint would publish, and the preedit's own boxes. Null once the model is
/// gone.
pub fn measure(self: *Ink) !?Measured {
    if (self.released) return null;
    var out: Measured = .{ .state = .{}, .caret = null, .preedit = &.{} };
    const Body = struct {
        const Self = @This();
        ink: *Ink,
        out: *Measured,
        fn run(model: *const Field, context: *anyopaque) anyerror!void {
            const typed: *Self = @ptrCast(@alignCast(context));
            const shaped = try typed.ink.layoutFor(model);
            typed.out.state = .{
                .lines = shaped.layout.lines.len,
                .width = shaped.layout.width,
                .geometry = shaped.geometry,
            };
            try copyState(model, &typed.out.state);
            typed.out.caret = shaped.caretRect(model.selection.cursor());
            typed.out.preedit = if (model.marked) |marked|
                try shaped.rangeBoxes(typed.ink.gpa, marked)
            else
                &.{};
        }
    };
    var exchange: Body = .{ .ink = self, .out = &out };
    self.session.read(Field, self.owner, &exchange, Body.run) catch |err| {
        if (isModelLost(err)) self.released = true;
        return null;
    };
    return out;
}

/// The field's own state, read through the same Session borrow the protocol
/// uses.
pub fn state(self: *Ink) !?State {
    if (self.released) return null;
    var out: State = .{};
    const Body = struct {
        const Self = @This();
        ink: *Ink,
        out: *State,
        fn run(model: *const Field, context: *anyopaque) anyerror!void {
            const typed: *Self = @ptrCast(@alignCast(context));
            const shaped = try typed.ink.layoutFor(model);
            typed.out.* = .{
                .lines = shaped.layout.lines.len,
                .width = shaped.layout.width,
                .geometry = shaped.geometry,
            };
            try copyState(model, typed.out);
        }
    };
    var exchange: Body = .{ .ink = self, .out = &out };
    self.session.read(Field, self.owner, &exchange, Body.run) catch |err| {
        if (isModelLost(err)) self.released = true;
        return null;
    };
    return out;
}

fn copyState(model: *const Field, out: *State) !void {
    const bytes = model.slice();
    if (bytes.len > out.buffer.len) return error.FieldTooLongForReport;
    @memcpy(out.buffer[0..bytes.len], bytes);
    out.len = bytes.len;
    out.selection = model.selection;
    out.marked = model.marked;
    out.replacements = model.replacements;
    out.marks = model.marks;
}

/// A released, stale or wrongly typed model is gone, and the run must say so
/// rather than read freed bytes. An allocation failure is NOT that, and must
/// not retire a live field.
fn isModelLost(err: anyerror) bool {
    return switch (err) {
        error.StaleModel,
        error.UninitializedModel,
        error.WrongType,
        error.WrongStore,
        error.AlreadyReleased,
        => true,
        else => false,
    };
}
