//! CPU-only text measurement for the headless layout path.
//!
//! Mirrors TextEngine.measureText (same embedded font, same HarfBuzz
//! shaping — kerning included) so the offscreen layout matches the
//! windowed one exactly — but needs no GPU: no materials, no sweeper
//! buffers. One FT face + hb font per SIZE (13/16/20), created lazily —
//! the same per-size structure the window uses for its engines. A shared
//! face that gets re-sized per call does NOT work: hb-ft's extents cache
//! the first size and ignore later FT_Set_Pixel_Sizes.
const std = @import("std");
const nogui = @import("nogui");
pub const WidgetSize = nogui.widget.Size;
pub const MeasureInput = nogui.layout.MeasureInput;

// Same single C import as text.zig (the HarfBuzz binding owns it).
const hb = @import("harfbuzz");
const c = hb.c;
const glyph_infos_type = @typeInfo(@TypeOf(hb.Buffer.getGlyphInfos)).@"fn".return_type.?;
const glyph_positions_type = @typeInfo(@TypeOf(hb.Buffer.getGlyphPositions)).@"fn".return_type.?;

const font_size_px: u32 = 16; // must match TextEngine.font_size_px
const fallback_scalar_advance: f32 = 10;
const fallback_line_height: f32 = 24;
const zero_width_space = "\xE2\x80\x8B";

const WidthMode = union(enum) {
    min_content,
    max_content,
    definite: f32,
};

const BreakKind = enum {
    soft,
    hard,
    end,
};

const TextSegment = struct {
    end: usize,
    next: usize,
    break_kind: BreakKind,
};

const IntrinsicMetrics = struct {
    min_width: f32,
    max_width: f32,
};

const FlowMetrics = struct {
    width: f32,
    line_count: usize,
};

const ShapedAdvance = struct {
    text: []const u8,
    infos: glyph_infos_type,
    positions: glyph_positions_type,
    glyph_index: usize = 0,
    last_offset: usize = 0,
    prefix_width: f32 = 0,

    fn init(text: []const u8, buffer: *hb.Buffer) ShapedAdvance {
        return .{
            .text = text,
            .infos = buffer.getGlyphInfos(),
            .positions = buffer.getGlyphPositions(),
        };
    }

    fn reset(self: *ShapedAdvance) void {
        self.glyph_index = 0;
        self.last_offset = 0;
        self.prefix_width = 0;
    }

    fn advanceRange(self: *ShapedAdvance, source: []const u8, start: usize, end: usize) f32 {
        _ = source;
        const start_width = self.prefixAt(start);
        const end_width = self.prefixAt(end);
        return end_width - start_width;
    }

    fn prefixAt(self: *ShapedAdvance, byte_offset: usize) f32 {
        std.debug.assert(byte_offset >= self.last_offset);
        std.debug.assert(byte_offset <= self.text.len);
        const positions = self.positions orelse &.{};
        const glyph_count = @min(self.infos.len, positions.len);
        while (self.glyph_index < glyph_count) {
            const info = self.infos[self.glyph_index];
            const cluster: usize = @intCast(info.cluster);
            if (cluster >= byte_offset) break;
            if (!self.clusterIsControl(cluster)) {
                const advance = @as(
                    f32,
                    @floatCast(@as(f64, @floatFromInt(positions[self.glyph_index].x_advance)) / 64.0),
                );
                self.prefix_width += advance;
            }
            self.glyph_index += 1;
        }
        self.last_offset = byte_offset;
        return self.prefix_width;
    }

    fn clusterIsControl(self: *const ShapedAdvance, cluster: usize) bool {
        if (cluster >= self.text.len) return false;
        if (self.text[cluster] == '\n' or self.text[cluster] == '\r') return true;
        return std.mem.startsWith(u8, self.text[cluster..], zero_width_space);
    }
};

fn hasMeasurerMethod(comptime T: type, comptime method_name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| hasMeasurerMethod(pointer.child, method_name),
        else => @hasDecl(T, method_name),
    };
}

const FallbackAdvance = struct {
    fn advance(_: FallbackAdvance, text: []const u8) f32 {
        var width: f32 = 0;
        var index: usize = 0;
        while (index < text.len) {
            if (std.mem.startsWith(u8, text[index..], zero_width_space)) {
                index += zero_width_space.len;
                continue;
            }
            if (text[index] == '\n' or text[index] == '\r') {
                index += 1;
                continue;
            }
            index += utf8ScalarLength(text, index);
            width += fallback_scalar_advance;
        }
        return width;
    }
};

fn utf8ScalarLength(text: []const u8, index: usize) usize {
    const first = text[index];
    const length: usize = if (first <= 0x7f)
        1
    else if (first >= 0xc2 and first <= 0xdf)
        2
    else if (first >= 0xe0 and first <= 0xef)
        3
    else if (first >= 0xf0 and first <= 0xf4)
        4
    else
        1;
    if (length == 1 or length > text.len - index) return 1;

    for (text[index + 1 .. index + length]) |byte| {
        if (byte < 0x80 or byte > 0xbf) return 1;
    }
    const second = text[index + 1];
    if (first == 0xe0 and second < 0xa0) return 1;
    if (first == 0xed and second > 0x9f) return 1;
    if (first == 0xf0 and second < 0x90) return 1;
    if (first == 0xf4 and second > 0x8f) return 1;
    return length;
}

fn measureRange(measurer: anytype, text: []const u8, start: usize, end: usize) f32 {
    if (comptime hasMeasurerMethod(@TypeOf(measurer), "advanceRange")) {
        return measurer.advanceRange(text, start, end);
    }
    return measurer.advance(text[start..end]);
}

fn resetMeasurer(measurer: anytype) void {
    if (comptime hasMeasurerMethod(@TypeOf(measurer), "reset")) {
        measurer.reset();
    }
}

fn separatorAdvance(measurer: anytype, text: []const u8, segment: TextSegment) f32 {
    if (segment.break_kind != .soft) return 0;
    const separator = text[segment.end..segment.next];
    if (std.mem.eql(u8, separator, zero_width_space)) return 0;
    return measureRange(measurer, text, segment.end, segment.next);
}

fn nextTextSegment(text: []const u8, start: usize) TextSegment {
    var index = start;
    while (index < text.len) : (index += 1) {
        if (std.mem.startsWith(u8, text[index..], zero_width_space)) {
            const next = index + zero_width_space.len;
            return .{ .end = index, .next = next, .break_kind = .soft };
        }
        switch (text[index]) {
            ' ', '\t' => {
                const next = index + 1;
                return .{ .end = index, .next = next, .break_kind = .soft };
            },
            '\n' => return .{ .end = index, .next = index + 1, .break_kind = .hard },
            '\r' => {
                const next = if (index + 1 < text.len and text[index + 1] == '\n')
                    index + 2
                else
                    index + 1;
                return .{ .end = index, .next = next, .break_kind = .hard };
            },
            else => {},
        }
    }
    return .{ .end = text.len, .next = text.len, .break_kind = .end };
}

fn segmentHasContent(text: []const u8) bool {
    var index: usize = 0;
    while (index < text.len) {
        if (std.mem.startsWith(u8, text[index..], zero_width_space)) {
            index += zero_width_space.len;
        } else {
            return true;
        }
    }
    return false;
}

fn intrinsicMetrics(measurer: anytype, text: []const u8) IntrinsicMetrics {
    resetMeasurer(measurer);
    var minimum_width: f32 = 0;
    var maximum_width: f32 = 0;
    var forced_line_width: f32 = 0;
    var segment_start: usize = 0;
    var line_has_content = false;

    while (true) {
        const segment = nextTextSegment(text, segment_start);
        const has_content = segmentHasContent(text[segment_start..segment.end]);
        if (has_content) {
            const segment_width = measureRange(measurer, text, segment_start, segment.end);
            minimum_width = @max(minimum_width, segment_width);
            forced_line_width += segment_width;
            line_has_content = true;
        }
        switch (segment.break_kind) {
            .soft => {
                if (line_has_content) {
                    forced_line_width += separatorAdvance(measurer, text, segment);
                }
            },
            .hard => {
                maximum_width = @max(maximum_width, forced_line_width);
                forced_line_width = 0;
                line_has_content = false;
            },
            .end => {
                maximum_width = @max(maximum_width, forced_line_width);
                break;
            },
        }
        segment_start = segment.next;
    }
    return .{ .min_width = minimum_width, .max_width = maximum_width };
}

fn wrappedLineCount(measurer: anytype, text: []const u8, limit: f32) usize {
    resetMeasurer(measurer);
    var line_count: usize = 0;
    var line_width: f32 = 0;
    var segment_start: usize = 0;
    var line_has_content = false;

    while (true) {
        const segment = nextTextSegment(text, segment_start);
        const has_content = segmentHasContent(text[segment_start..segment.end]);
        const segment_width = measureRange(measurer, text, segment_start, segment.end);
        const candidate_width = line_width + segment_width;
        if (line_has_content and has_content and candidate_width > limit) {
            line_count += 1;
            line_width = segment_width;
            line_has_content = false;
        } else {
            line_width = candidate_width;
        }
        if (has_content) line_has_content = true;

        switch (segment.break_kind) {
            .soft => {
                if (line_has_content) {
                    line_width += separatorAdvance(measurer, text, segment);
                }
                segment_start = segment.next;
            },
            .hard => {
                line_count += 1;
                line_width = 0;
                segment_start = segment.next;
                line_has_content = false;
            },
            .end => {
                line_count += 1;
                break;
            },
        }
    }
    return line_count;
}

fn measureFlow(measurer: anytype, text: []const u8, mode: WidthMode) FlowMetrics {
    const intrinsic = intrinsicMetrics(measurer, text);
    const inline_width = switch (mode) {
        .min_content => intrinsic.min_width,
        .max_content => intrinsic.max_width,
        .definite => |available_width| blk: {
            const finite_width = if (std.math.isFinite(available_width))
                @max(0, available_width)
            else
                intrinsic.max_width;
            break :blk @max(
                intrinsic.min_width,
                @min(finite_width, intrinsic.max_width),
            );
        },
    };
    return .{
        .width = inline_width,
        .line_count = wrappedLineCount(measurer, text, inline_width),
    };
}
fn measureByLinePolicy(measurer: anytype, text: []const u8, input: MeasureInput) FlowMetrics {
    if (input.line_policy == .single_line) {
        resetMeasurer(measurer);
        return .{
            .width = measureRange(measurer, text, 0, text.len),
            .line_count = 1,
        };
    }
    return measureFlow(measurer, text, widthMode(input));
}

fn widthMode(input: MeasureInput) WidthMode {
    if (input.known_dimensions.width) |width| return .{ .definite = width };
    return switch (input.available_space.width) {
        .min_content => .min_content,
        .max_content => .max_content,
        .definite => |width| .{ .definite = width },
    };
}

fn fontPixelSize(font_size: f32, default_size: u32) ?u32 {
    if (!(font_size > 0)) return default_size;
    if (!std.math.isFinite(font_size)) return null;
    const rounded_size: f64 = @round(@as(f64, font_size));
    const maximum_size: f64 = @floatFromInt(std.math.maxInt(u32));
    if (rounded_size < 1 or rounded_size > maximum_size) return null;
    return @intFromFloat(rounded_size);
}

fn applyKnownDimensions(size: WidgetSize, input: MeasureInput) WidgetSize {
    var result = size;
    if (input.known_dimensions.width) |width| result.width = width;
    if (input.known_dimensions.height) |height| result.height = height;
    return result;
}

fn fallbackMeasure(text: []const u8, input: MeasureInput) WidgetSize {
    const flow = measureByLinePolicy(FallbackAdvance{}, text, input);
    return applyKnownDimensions(.{
        .width = flow.width,
        .height = @as(f32, @floatFromInt(flow.line_count)) * fallback_line_height,
    }, input);
}

const SizeState = struct {
    ft_lib: c.FT_Library,
    face: c.FT_Face,
    hb_font: hb.Font,
    measure_buffer: hb.Buffer,
    size: u32,
    /// Font line metrics at `size` (26.6 → px).
    ascent: f32,
    descent: f32,
    font_id: u8,
};

const max_entries = 16;
var entries: [max_entries]?SizeState = .{null} ** max_entries;

/// Get (or lazily create) the state for `px` pixels. One shared FT
/// library; a fresh face + hb font per size — identical init to the
/// window's TextEngine, so the extents/advances match the window exactly.
fn entryFor(font_id: u8, px: u32) !*SizeState {
    for (&entries) |*e| {
        if (e.*) |*s| {
            if (s.font_id == font_id and s.size == px) return s;
        }
    }
    // Evict a free slot (LRU-ish: first free, else the first entry).
    var slot: ?usize = null;
    for (&entries, 0..) |*e, i| {
        if (e.* == null) {
            slot = i;
            break;
        }
    }
    if (slot == null) {
        // All busy: reuse the first (the demo only ever uses 13/16/20, so
        // this never triggers in practice).
        const old = &entries[0].?;
        old.measure_buffer.destroy();
        old.hb_font.destroy();
        _ = c.FT_Done_Face(old.face);
        // Each entry owns its own FT library (see entryFor); release it too.
        _ = c.FT_Done_FreeType(old.ft_lib);
        entries[0] = null;
        slot = 0;
    }
    const idx = slot.?;

    // SAFETY: assigned by FT_Init/FT_New before any use; failures return errors.
    var ft_lib: c.FT_Library = undefined;
    if (c.FT_Init_FreeType(&ft_lib) != 0) return error.FreeTypeInitFailed;
    errdefer _ = c.FT_Done_FreeType(ft_lib);

    const font_data = if (font_id == 0) @embedFile("InterVariable.ttf") else @embedFile("FiraCodeNerdFont-Regular.ttf");
    // SAFETY: assigned by FT_Init/FT_New before any use; failures return errors.
    var face: c.FT_Face = undefined;
    if (c.FT_New_Memory_Face(ft_lib, font_data.ptr, @intCast(font_data.len), 0, &face) != 0)
        return error.FreeTypeFaceFailed;
    errdefer _ = c.FT_Done_Face(face);
    if (c.FT_Set_Pixel_Sizes(face, 0, px) != 0) return error.FreeTypeSetPixelSizesFailed;

    const hb_handle = c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed;
    var hb_font: hb.Font = .{ .handle = hb_handle };
    c.hb_ft_font_set_funcs(hb_handle);
    errdefer hb_font.destroy();
    // Unhinted — same policy as the window engine (see text.zig's note):
    // positions and extents must scale linearly with the size.
    _ = c.hb_ft_font_set_load_flags(hb_handle, c.FT_LOAD_DEFAULT | c.FT_LOAD_NO_HINTING);

    // SAFETY: assigned by hb_font_get_extents_for_direction before any read.
    var font_ext: c.hb_font_extents_t = undefined;
    _ = c.hb_font_get_extents_for_direction(hb_handle, c.HB_DIRECTION_LTR, &font_ext);
    var measure_buffer = try hb.Buffer.create();
    errdefer measure_buffer.destroy();
    entries[idx] = .{
        .ft_lib = ft_lib,
        .face = face,
        .hb_font = hb_font,
        .measure_buffer = measure_buffer,
        .size = px,
        .ascent = @as(f32, @floatCast(@as(f64, @floatFromInt(font_ext.ascender)) / 64.0)),
        .descent = @as(f32, @floatCast(@as(f64, @floatFromInt(font_ext.descender)) / 64.0)),
        .font_id = font_id,
    };
    return &entries[idx].?;
}

/// Release every size entry. Call once at shutdown.
pub fn deinit() void {
    for (&entries) |*e| {
        if (e.*) |*s| {
            s.measure_buffer.destroy();
            s.hb_font.destroy();
            _ = c.FT_Done_Face(s.face);
            _ = c.FT_Done_FreeType(s.ft_lib);
            e.* = null;
        }
    }
}

/// Flex measure callback for the canonical content-box measurement contract.
pub fn measure(text: []const u8, input: MeasureInput) WidgetSize {
    const size = fontPixelSize(input.font_size, font_size_px) orelse
        return fallbackMeasure(text, input);
    const state = entryFor(input.font_id, size) catch
        return fallbackMeasure(text, input);
    state.measure_buffer.reset();
    state.measure_buffer.addUTF8(text);
    state.measure_buffer.setDirection(.ltr);
    state.measure_buffer.setScript(.latin);
    hb.shape(state.hb_font, state.measure_buffer, null);
    var shaped = ShapedAdvance.init(text, &state.measure_buffer);
    const flow = measureByLinePolicy(&shaped, text, input);
    return applyKnownDimensions(.{
        .width = flow.width,
        .height = @as(f32, @floatFromInt(flow.line_count)) * (state.ascent - state.descent),
    }, input);
}
test "measureFlow excludes separators trimmed at hard-line starts" {
    const CountingAdvance = struct {
        const Self = @This();

        fn advance(_: *Self, text: []const u8) f32 {
            return @floatFromInt(text.len);
        }
    };
    var measurer: CountingAdvance = .{};
    const flow = measureFlow(&measurer, "  alpha\n\tbeta", .max_content);

    try std.testing.expectEqual(@as(f32, 5), flow.width);
    try std.testing.expectEqual(@as(usize, 2), flow.line_count);
}

test "single-line policy ignores hard-break glyph advances" {
    const input: MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .font_size = 20,
        .font_id = 0,
        .line_policy = .single_line,
    };
    const flow = measureByLinePolicy(FallbackAdvance{}, "a\nbb", input);

    try std.testing.expectEqual(@as(f32, 3 * fallback_scalar_advance), flow.width);
    try std.testing.expectEqual(@as(usize, 1), flow.line_count);
}
