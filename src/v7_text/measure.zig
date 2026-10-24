//! CPU FreeType/HarfBuzz measurement and immutable Unicode text layout.
//!
//! The legacy Measure callback binds compile-time font bytes. TextService
//! owns added fonts and gives each size/weight a separate face.
const std = @import("std");
const nogui = @import("nogui");
const MeasureInput = nogui.layout.MeasureInput;
const CounterSink = nogui.CounterSink;

// Use the HarfBuzz binding's C import for both HarfBuzz and FreeType.
const hb = @import("harfbuzz");
const c = hb.c;

pub const font_size_px: u32 = 16;
pub const fallback_scalar_advance: f32 = 10;
const zero_width_space = "\xE2\x80\x8B";

/// One available-width mode for CPU measurement.
pub const WidthMode = union(enum) {
    min_content,
    max_content,
    definite: f32,
};

pub const BreakKind = enum {
    soft,
    hard,
    end,
};

pub const TextSegment = struct {
    end: usize,
    next: usize,
    break_kind: BreakKind,
};

/// Retained-width result types are shared with the shaping cache so a lease
/// memo and a fresh measurement are the same value type.
pub const IntrinsicMetrics = shaping.IntrinsicMetrics;
pub const FlowMetrics = shaping.FlowMetrics;
pub const FlowKey = shaping.FlowKey;

pub const ShapedAdvance = struct {
    text: []const u8,
    infos: @typeInfo(@TypeOf(hb.Buffer.getGlyphInfos)).@"fn".return_type.? = &.{},
    positions: @typeInfo(@TypeOf(hb.Buffer.getGlyphPositions)).@"fn".return_type.? = null,
    cached_glyphs: ?[]const shaping.Glyph = null,
    lease: ?shaping.Lease = null,
    glyph_index: usize = 0,
    last_offset: usize = 0,
    prefix_width: f32 = 0,

    pub fn init(text: []const u8, buffer: *hb.Buffer) ShapedAdvance {
        return .{
            .text = text,
            .infos = buffer.getGlyphInfos(),
            .positions = buffer.getGlyphPositions(),
        };
    }

    pub fn initCached(lease: shaping.Lease) ShapedAdvance {
        return .{
            .text = lease.run.text,
            .cached_glyphs = lease.run.glyphs,
            .lease = lease,
        };
    }

    pub fn deinit(self: *ShapedAdvance) void {
        if (self.lease) |*lease| lease.release();
        self.* = undefined;
    }

    pub fn reset(self: *ShapedAdvance) void {
        self.glyph_index = 0;
        self.last_offset = 0;
        self.prefix_width = 0;
    }

    pub fn advanceRange(self: *ShapedAdvance, source: []const u8, start: usize, end: usize) f32 {
        _ = source;
        const start_width = self.prefixAt(start);
        const end_width = self.prefixAt(end);
        return end_width - start_width;
    }

    pub fn prefixAt(self: *ShapedAdvance, byte_offset: usize) f32 {
        std.debug.assert(byte_offset >= self.last_offset);
        std.debug.assert(byte_offset <= self.text.len);
        if (self.cached_glyphs) |glyphs| {
            while (self.glyph_index < glyphs.len) {
                const glyph = glyphs[self.glyph_index];
                if (glyph.cluster >= byte_offset) break;
                self.prefix_width += glyph.x_advance;
                self.glyph_index += 1;
            }
            self.last_offset = byte_offset;
            return self.prefix_width;
        }
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
        return textClusterIsControl(self.text, cluster);
    }
};

pub fn textClusterIsControl(text: []const u8, cluster: usize) bool {
    if (cluster >= text.len) return false;
    if (text[cluster] == '\n' or text[cluster] == '\r') return true;
    return std.mem.startsWith(u8, text[cluster..], zero_width_space);
}

fn hasMeasurerMethod(comptime T: type, comptime method_name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| hasMeasurerMethod(pointer.child, method_name),
        else => @hasDecl(T, method_name),
    };
}

pub const FallbackAdvance = struct {
    pub fn advance(_: FallbackAdvance, text: []const u8) f32 {
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

pub fn measureRange(measurer: anytype, text: []const u8, start: usize, end: usize) f32 {
    if (comptime hasMeasurerMethod(@TypeOf(measurer), "advanceRange")) {
        return measurer.advanceRange(text, start, end);
    }
    return measurer.advance(text[start..end]);
}

/// Advance accumulators carry running prefix width; a fresh scan starts over.
/// Only the real shaping adapter has a cursor to rewind.
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

/// The next break opportunity at or after `start`. `counter_sink` records
/// the bytes scanned so a host can prove linear measurement work.
pub fn nextTextSegment(
    text: []const u8,
    start: usize,
    counter_sink: ?*const CounterSink,
) TextSegment {
    var index = start;
    while (index < text.len) : (index += 1) {
        if (counter_sink) |sink| {
            sink.add(.segment_bytes_scanned, 1);
            sink.add(.hard_line_bytes_scanned, 1);
        }
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

/// True when the segment paints something other than zero-width spaces.
pub fn segmentHasContent(text: []const u8, counter_sink: ?*const CounterSink) bool {
    var index: usize = 0;
    while (index < text.len) {
        if (counter_sink) |sink| sink.add(.segment_content_rescan_bytes, 1);
        if (std.mem.startsWith(u8, text[index..], zero_width_space)) {
            index += zero_width_space.len;
        } else {
            return true;
        }
    }
    return false;
}

pub const LineRange = struct {
    start: usize,
    end: usize,
};

pub const PendingSegment = struct {
    segment: TextSegment,
    has_content: bool,
    width: f32,
};

pub const LineRangeIterator = struct {
    text: []const u8,
    limit: f32,
    counter_sink: ?*const CounterSink = null,
    segment_start: usize = 0,
    line_start: usize = 0,
    line_end: usize = 0,
    pending: ?PendingSegment = null,
    line_width: f32 = 0,
    line_has_content: bool = false,
    finished: bool = false,

    pub fn init(
        text: []const u8,
        limit: f32,
        counter_sink: ?*const CounterSink,
    ) LineRangeIterator {
        return .{ .text = text, .limit = limit, .counter_sink = counter_sink };
    }

    pub fn next(self: *LineRangeIterator, measurer: anytype) ?LineRange {
        if (self.finished) return null;

        while (true) {
            const current: PendingSegment = if (self.pending) |pending| from_pending: {
                self.pending = null;
                break :from_pending pending;
            } else fresh: {
                const segment = nextTextSegment(self.text, self.segment_start, self.counter_sink);
                break :fresh .{
                    .segment = segment,
                    .has_content = segmentHasContent(
                        self.text[self.segment_start..segment.end],
                        self.counter_sink,
                    ),
                    .width = measureRange(
                        measurer,
                        self.text,
                        self.segment_start,
                        segment.end,
                    ),
                };
            };
            const segment = current.segment;
            const has_content = current.has_content;
            const segment_width = current.width;
            const candidate_width = self.line_width + segment_width;
            if (self.line_has_content and has_content and candidate_width > self.limit) {
                const range: LineRange = .{ .start = self.line_start, .end = self.line_end };
                self.pending = .{
                    .segment = segment,
                    .has_content = has_content,
                    .width = segment_width,
                };
                self.line_start = self.segment_start;
                self.line_end = self.segment_start;
                self.line_width = 0;
                self.line_has_content = false;
                return range;
            }

            self.line_width = candidate_width;
            if (has_content) {
                self.line_has_content = true;
                self.line_end = segment.end;
            }

            switch (segment.break_kind) {
                .soft => {
                    if (self.line_has_content) {
                        self.line_width += separatorAdvance(measurer, self.text, segment);
                        self.line_end = segment.next;
                    } else {
                        self.line_start = segment.next;
                        self.line_end = segment.next;
                    }
                    self.segment_start = segment.next;
                },
                .hard => {
                    const range: LineRange = .{ .start = self.line_start, .end = self.line_end };
                    self.line_start = segment.next;
                    self.line_end = segment.next;
                    self.line_width = 0;
                    self.line_has_content = false;
                    self.segment_start = segment.next;
                    return range;
                },
                .end => {
                    self.finished = true;
                    return .{ .start = self.line_start, .end = self.line_end };
                },
            }
        }
    }
};

pub fn wrappedLineCount(
    measurer: anytype,
    text: []const u8,
    limit: f32,
    counter_sink: ?*const CounterSink,
) usize {
    resetMeasurer(measurer);
    var ranges = LineRangeIterator.init(text, limit, counter_sink);
    var line_count: usize = 0;
    while (ranges.next(measurer)) |_| {
        line_count += 1;
    }
    return line_count;
}

pub fn intrinsicMetricsUncached(
    measurer: anytype,
    text: []const u8,
    counter_sink: ?*const CounterSink,
) IntrinsicMetrics {
    resetMeasurer(measurer);
    var minimum_width: f32 = 0;
    var maximum_width: f32 = 0;
    var forced_line_width: f32 = 0;
    var segment_start: usize = 0;
    var line_has_content = false;

    while (true) {
        const segment = nextTextSegment(text, segment_start, counter_sink);
        const has_content = segmentHasContent(text[segment_start..segment.end], counter_sink);
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

fn intrinsicMetricsCached(
    measurer: *ShapedAdvance,
    text: []const u8,
    counter_sink: ?*const CounterSink,
) IntrinsicMetrics {
    if (measurer.lease) |*lease| {
        if (lease.loadIntrinsicMetrics()) |metrics| return metrics;
        const metrics = intrinsicMetricsUncached(measurer, text, counter_sink);
        lease.storeIntrinsicMetrics(metrics);
        return metrics;
    }
    return intrinsicMetricsUncached(measurer, text, counter_sink);
}

pub fn intrinsicMetrics(
    measurer: anytype,
    text: []const u8,
    counter_sink: ?*const CounterSink,
) IntrinsicMetrics {
    if (comptime @TypeOf(measurer) == *ShapedAdvance) {
        return intrinsicMetricsCached(measurer, text, counter_sink);
    }
    return intrinsicMetricsUncached(measurer, text, counter_sink);
}

pub fn normalizedFlowWidth(intrinsic: IntrinsicMetrics, mode: WidthMode) f32 {
    return switch (mode) {
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
}

fn flowMetricsForWidth(
    measurer: anytype,
    text: []const u8,
    inline_width: f32,
    counter_sink: ?*const CounterSink,
) FlowMetrics {
    if (comptime @TypeOf(measurer) == *ShapedAdvance) {
        if (measurer.lease) |*lease| {
            const key: FlowKey = .{
                .line_policy = .flow,
                .normalized_width = inline_width,
            };
            if (lease.loadFlowMetrics(key)) |metrics| return metrics;
            const metrics: FlowMetrics = .{
                .width = inline_width,
                .line_count = wrappedLineCount(measurer, text, inline_width, counter_sink),
            };
            lease.storeFlowMetrics(key, metrics);
            return metrics;
        }
    }
    return .{
        .width = inline_width,
        .line_count = wrappedLineCount(measurer, text, inline_width, counter_sink),
    };
}

/// A resident run's retained width answers a single-line policy without a
/// rescan. A transient lease falls back to prefix accumulation.
fn singleLineMetricsCached(measurer: *ShapedAdvance, text: []const u8) FlowMetrics {
    if (measurer.lease) |*lease| {
        if (lease.retainedRunWidth()) |run_width| {
            const key: FlowKey = .{
                .line_policy = .single_line,
                .normalized_width = run_width,
            };
            if (lease.loadFlowMetrics(key)) |metrics| return metrics;
            const metrics: FlowMetrics = .{ .width = run_width, .line_count = 1 };
            lease.storeFlowMetrics(key, metrics);
            return metrics;
        }
    }
    resetMeasurer(measurer);
    return .{
        .width = measureRange(measurer, text, 0, text.len),
        .line_count = 1,
    };
}

pub fn measureFlow(
    measurer: anytype,
    text: []const u8,
    mode: WidthMode,
    counter_sink: ?*const CounterSink,
) FlowMetrics {
    const intrinsic = intrinsicMetrics(measurer, text, counter_sink);
    return flowMetricsForWidth(
        measurer,
        text,
        normalizedFlowWidth(intrinsic, mode),
        counter_sink,
    );
}

pub fn measureByLinePolicy(
    measurer: anytype,
    text: []const u8,
    input: nogui.layout.MeasureInput,
    counter_sink: ?*const CounterSink,
) FlowMetrics {
    if (input.line_policy == .single_line) {
        if (comptime @TypeOf(measurer) == *ShapedAdvance) {
            return singleLineMetricsCached(measurer, text);
        }
        resetMeasurer(measurer);
        return .{
            .width = measureRange(measurer, text, 0, text.len),
            .line_count = 1,
        };
    }
    return measureFlow(measurer, text, widthMode(input), counter_sink);
}

pub fn widthMode(input: nogui.layout.MeasureInput) WidthMode {
    if (input.known_dimensions.width) |width| return .{ .definite = width };
    return switch (input.available_space.width) {
        .min_content => .min_content,
        .max_content => .max_content,
        .definite => |width| .{ .definite = width },
    };
}

fn scaleCountToF32(count: usize, unit: f32) f32 {
    const scaled = @as(f64, @floatFromInt(count)) * @as(f64, unit);
    const maximum: f64 = std.math.floatMax(f32);
    std.debug.assert(std.math.isFinite(scaled));
    std.debug.assert(scaled >= -maximum);
    std.debug.assert(scaled <= maximum);
    return @floatCast(scaled);
}

test "measureFlow excludes separators trimmed at hard-line starts" {
    const CountingAdvance = struct {
        const Self = @This();
        fn advance(_: *Self, text: []const u8) f32 {
            return scaleCountToF32(text.len, 1.0);
        }
    };
    var measurer: CountingAdvance = .{};
    const flow = measureFlow(&measurer, "  alpha\n\tbeta", .max_content, null);

    try std.testing.expectEqual(@as(f32, 5), flow.width);
    try std.testing.expectEqual(@as(usize, 2), flow.line_count);
}

test "single-line policy ignores hard-break glyph advances" {
    const input: MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .line_policy = .single_line,
    };
    const flow = measureByLinePolicy(FallbackAdvance{}, "a\nbb", input, null);

    try std.testing.expectEqual(@as(f32, 3 * fallback_scalar_advance), flow.width);
    try std.testing.expectEqual(@as(usize, 1), flow.line_count);
}

const text_api = nogui.text;
const shaping = @import("shape_cache.zig");

/// The failures a real text request can report. Core owns the set and unions
/// it into `sizing.Error`, so a refusal reaches App publication instead of
/// being replaced by a synthetic fallback. Aliasing the core set here means
/// the compiler proves at every public entry point that nothing escapes it.
pub const TextLayoutError = nogui.layout.LayoutError;

/// The width and overflow policy a host resolves for one text node before the
/// single request builder folds it into a `LayoutRequest`. Measure and paint
/// pass the same value, so a box cannot measure one way and paint another.
pub const NodeLayoutOptions = struct {
    /// The width the node's content box offers. null leaves the paragraph
    /// unconstrained, which is how a content probe is taken.
    width: ?f32 = null,
    /// The overflow policy for a box narrower than the text. null keeps the
    /// node's own authored policy.
    overflow: ?nogui.widget.TextOverflow = null,
    /// UTF-8 text placed at the truncation site for `.ellipsis`.
    suffix: []const u8 = "...",
    /// The box height a paint target centers the text block within. Only the
    /// emit path reads it; a content probe ignores it.
    box_height: ?f32 = null,
};

// FriBidi 1.0.16 fribidi-types.h/bidi.h, utf8proc 2.11.3 utf8proc.h.
// No C struct is passed to either library. The integer ABI is fixed by those
// headers: FriBidiChar=u32, FriBidiStrIndex=int, FriBidiLevel=signed char.
extern fn fribidi_get_bidi_types([*]const u32, c_int, [*]u32) void;
extern fn fribidi_get_bracket_types([*]const u32, c_int, [*]const u32, [*]u32) void;
extern fn fribidi_get_par_embedding_levels_ex([*]const u32, [*]const u32, c_int, *u32, [*]i8) i8;
extern fn utf8proc_grapheme_break_stateful(i32, i32, *i32) bool;

pub const FontInfo = struct {
    handle: text_api.FontHandle,
    family: []const u8,
    weight: u16,
    style: text_api.FontStyle,
};

pub const FontSource = struct {
    family: []const u8,
    /// The service copies bytes. Callers can release the source after addFont.
    bytes: []const u8,
    weight: u16 = 400,
    style: text_api.FontStyle = .normal,
};

const LoadedFace = struct {
    id: u8,
    size: u32,
    weight: u16,
    face: c.FT_Face,
    font: hb.Font,
    metrics: text_api.FontMetrics,

    fn deinit(self: *LoadedFace) void {
        self.font.destroy();
        _ = c.FT_Done_Face(self.face);
        self.* = undefined;
    }
};

pub const TextService = struct {
    gpa: std.mem.Allocator,
    library: c.FT_Library,
    infos: std.ArrayList(FontInfo) = .empty,
    data: std.ArrayList([]const u8) = .empty,
    faces: std.ArrayList(LoadedFace) = .empty,
    cache: shaping.Cache,
    sink: nogui.CounterSink = nogui.CounterSink.init(null),

    pub fn init(gpa: std.mem.Allocator) !TextService {
        // SAFETY: FT_Init_FreeType writes the handle; a non-zero status returns first.
        var library: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitFailed;
        return .{ .gpa = gpa, .library = library, .cache = shaping.Cache.init(gpa) };
    }

    /// Destroy layouts before their service; each live layout pins cache runs.
    pub fn deinit(self: *TextService) void {
        self.cache.deinit();
        for (self.faces.items) |*face| face.deinit();
        self.faces.deinit(self.gpa);
        for (self.infos.items, self.data.items) |info, bytes| {
            self.gpa.free(info.family);
            self.gpa.free(bytes);
        }
        self.infos.deinit(self.gpa);
        self.data.deinit(self.gpa);
        _ = c.FT_Done_FreeType(self.library);
        self.* = undefined;
    }

    pub fn listFonts(self: *const TextService) []const FontInfo {
        return self.infos.items;
    }

    /// Borrowed immutable font bytes for rasterizing this layout's glyph ids.
    /// The service must outlive any renderer face created from these bytes.
    pub fn fontSource(self: *const TextService, handle: text_api.FontHandle) !FontSource {
        const index = try self.fontIndex(handle);
        const info = self.infos.items[index];
        return .{
            .family = info.family,
            .bytes = self.data.items[index],
            .weight = info.weight,
            .style = info.style,
        };
    }

    pub fn fontPixelSize(_: *const TextService, size: f32) !u32 {
        return pixelSize(size);
    }

    pub fn shapeCount(self: *const TextService) u64 {
        return self.cache.shapeCount();
    }

    /// Forward performance counters to shaping and glyph work.
    pub fn setCounterSink(self: *TextService, counters: ?*nogui.Counters) void {
        self.sink = nogui.CounterSink.init(counters);
    }

    pub fn addFont(self: *TextService, source: FontSource) !text_api.FontHandle {
        if (source.family.len == 0 or source.bytes.len == 0) return error.InvalidFont;
        if (source.weight < 1 or source.weight > 1000) return error.InvalidWeight;
        if (self.infos.items.len >= @as(usize, std.math.maxInt(u8)) + 1) return error.TooManyFonts;
        const font_bytes = try self.gpa.dupe(u8, source.bytes);
        errdefer self.gpa.free(font_bytes);
        const family = try self.gpa.dupe(u8, source.family);
        errdefer self.gpa.free(family);
        if (font_bytes.len > std.math.maxInt(c.FT_Long)) return error.InvalidFont;
        // SAFETY: FT_New_Memory_Face writes the handle; a non-zero status returns first.
        var face: c.FT_Face = undefined;
        if (c.FT_New_Memory_Face(self.library, font_bytes.ptr, @intCast(font_bytes.len), 0, &face) != 0)
            return error.InvalidFont;
        defer _ = c.FT_Done_Face(face);
        const handle: text_api.FontHandle = .{
            .index = @intCast(self.infos.items.len),
            .generation = 1,
        };
        try self.infos.ensureUnusedCapacity(self.gpa, 1);
        try self.data.ensureUnusedCapacity(self.gpa, 1);
        self.infos.appendAssumeCapacity(.{
            .handle = handle,
            .family = family,
            .weight = source.weight,
            .style = source.style,
        });
        self.data.appendAssumeCapacity(font_bytes);
        return handle;
    }

    fn fontIndex(self: *const TextService, handle: text_api.FontHandle) !u8 {
        const index: usize = handle.index;
        if (handle.generation != 1 or index >= self.infos.items.len) return error.UnknownFont;
        return @intCast(index);
    }

    /// Resolve a request to one registered face. A handle is honoured only
    /// when its registered style matches the request, so a synthetic or
    /// unavailable slant reports a missing font instead of painting upright.
    pub fn resolve(self: *const TextService, request: text_api.FontRequest) !text_api.FontHandle {
        if (request.weight < 1 or request.weight > 1000) return error.InvalidWeight;
        if (request.handle) |handle| {
            const index = try self.fontIndex(handle);
            if (self.infos.items[index].style != request.style) return error.FontUnavailable;
            return handle;
        }
        if (request.family.len == 0) return error.FontUnavailable;
        var choice: ?text_api.FontHandle = null;
        var nearest: u16 = std.math.maxInt(u16);
        for (self.infos.items) |info| {
            if (!std.ascii.eqlIgnoreCase(info.family, request.family)) continue;
            if (info.style != request.style) continue;
            const distance = if (request.weight >= info.weight)
                request.weight - info.weight
            else
                info.weight - request.weight;
            if (distance < nearest) {
                choice = info.handle;
                nearest = distance;
            }
        }
        return choice orelse error.FontUnavailable;
    }

    pub fn hasGlyph(self: *TextService, handle: text_api.FontHandle, codepoint: u21) !bool {
        const id = try self.fontIndex(handle);
        const font = try self.faceFor(id, 16, 400);
        return c.FT_Get_Char_Index(font.face, codepoint) != 0;
    }

    pub fn metrics(self: *TextService, handle: text_api.FontHandle, size: f32) !text_api.FontMetrics {
        const id = try self.fontIndex(handle);
        return (try self.faceFor(id, try pixelSize(size), self.infos.items[id].weight)).metrics;
    }

    /// The output is an immutable snapshot that OWNS its allocation. The
    /// caller chooses its lifetime; release the layout, and therefore every
    /// cache lease it pins, before destroying this service.
    pub fn layout(
        self: *TextService,
        allocator: std.mem.Allocator,
        request: text_api.LayoutRequest,
    ) TextLayoutError!TextLayout {
        return layoutText(self, allocator, request, true);
    }

    /// The same layout carved DIRECTLY in `allocator`, with no owning nested
    /// allocator. A per-frame scratch arena is the intended argument:
    /// `deinit` then `reset(.retain_capacity)` returns every block, and the
    /// retained shaped runs outlive the frame through the shared cache.
    pub fn layoutIn(
        self: *TextService,
        allocator: std.mem.Allocator,
        request: text_api.LayoutRequest,
    ) TextLayoutError!TextLayout {
        return layoutText(self, allocator, request, false);
    }

    /// The node seam: normalize the host's default size into a valid request,
    /// build it through the ONE request builder the paint path also uses, then
    /// run the existing layout implementation. Overrides, inline ranges,
    /// fallback, bidi and missing-glyph policy are the same code.
    ///
    /// The builder borrows: it copies nothing, because `NodeText` already owns
    /// the published style and ranges and `layoutText` copies everything it
    /// keeps. So the returned layout's content, lines, runs, graphemes and
    /// leases are all carved in `allocator`, and nothing here allocates twice
    /// to say the same thing.
    ///
    /// One borrow escapes: a run's `style.font` still names the caller-owned
    /// family, features and fallback slices. `node` must therefore outlive the
    /// layout. Both callers satisfy that — the measure seam reads the core
    /// record through `input.text`, and the emit path holds its node for the
    /// whole call.
    pub fn nodeLayoutIn(
        self: *TextService,
        allocator: std.mem.Allocator,
        content: []const u8,
        node: text_api.NodeText,
        options: NodeLayoutOptions,
        default_size: f32,
    ) TextLayoutError!TextLayout {
        const resolved = try self.resolveNodeRequest(node, default_size);
        const request = text_api.nodeRequest(content, &resolved, .{
            .width = options.width,
            .overflow = options.overflow,
            .suffix = options.suffix,
        });
        return layoutText(self, allocator, request, false);
    }

    /// The one normalization a node seam owes the validated request API: a
    /// zero size means the host default, and a request that names NO face at
    /// all means the first registered font. Both are resolved once, into a
    /// copy; the published node record is never mutated.
    ///
    /// The face default is deliberately conjunctive. An authored family IS the
    /// face request, not a hint, so filling in the primary handle whenever the
    /// handle alone is null would silently repaint every family-named node
    /// with the first registered face and turn its missing glyphs into tofu.
    fn resolveNodeRequest(
        self: *const TextService,
        node: text_api.NodeText,
        default_size: f32,
    ) TextLayoutError!text_api.NodeText {
        var resolved = node;
        if (!(resolved.style.font.size > 0)) resolved.style.font.size = default_size;
        if (resolved.style.font.handle == null and resolved.style.font.family.len == 0) {
            if (self.infos.items.len == 0) return error.FontUnavailable;
            resolved.style.font.handle = self.infos.items[0].handle;
        }
        return resolved;
    }

    fn faceFor(self: *TextService, id: u8, size: u32, weight: u16) !*LoadedFace {
        for (self.faces.items) |*face| {
            if (face.id == id and face.size == size and face.weight == weight) return face;
        }
        // SAFETY: FT_New_Memory_Face writes the handle; a non-zero status returns first.
        var face: c.FT_Face = undefined;
        const font_bytes = self.data.items[id];
        if (c.FT_New_Memory_Face(self.library, font_bytes.ptr, @intCast(font_bytes.len), 0, &face) != 0)
            return error.InvalidFont;
        errdefer _ = c.FT_Done_Face(face);
        if (c.FT_Set_Pixel_Sizes(face, 0, size) != 0) return error.InvalidFontSize;
        if (face.*.units_per_EM == 0) return error.InvalidFont;
        const handle = c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed;
        var font: hb.Font = .{ .handle = handle };
        errdefer font.destroy();
        c.hb_ft_font_set_funcs(handle);
        _ = c.hb_ft_font_set_load_flags(handle, c.FT_LOAD_DEFAULT | c.FT_LOAD_NO_HINTING);
        // A request for a different weight must shape from a distinct font.
        // On a variable face HarfBuzz applies the OpenType wght axis.
        const variation: c.hb_variation_t = .{
            .tag = text_api.tag("wght"),
            .value = @floatFromInt(weight),
        };
        c.hb_font_set_variations(handle, &variation, 1);
        // hb-ft's outline callbacks read FT_Face. Keep that face's variable
        // coordinates in sync with HarfBuzz before querying any glyph metrics.
        _ = c.hb_ft_hb_font_changed(handle);
        // SAFETY: hb_font_get_extents_for_direction fills every field before the reads.
        var extents: c.hb_font_extents_t = undefined;
        c.hb_font_get_extents_for_direction(handle, c.HB_DIRECTION_LTR, &extents);
        const asc = fromFixed26Dot6(extents.ascender);
        const desc = fromFixed26Dot6(extents.descender);
        const gap = fromFixed26Dot6(extents.line_gap);
        const metrics_value: text_api.FontMetrics = .{
            .ascent = asc,
            .descent = desc,
            .line_gap = gap,
            .line_height = @max(1, asc - desc + gap),
            .underline_position = @as(f32, @floatFromInt(face.*.underline_position)) *
                @as(f32, @floatFromInt(size)) / @as(f32, @floatFromInt(face.*.units_per_EM)),
            .underline_thickness = @max(1, @as(f32, @floatFromInt(face.*.underline_thickness)) *
                @as(f32, @floatFromInt(size)) / @as(f32, @floatFromInt(face.*.units_per_EM))),
        };
        try self.faces.append(self.gpa, .{
            .id = id,
            .size = size,
            .weight = weight,
            .face = face,
            .font = font,
            .metrics = metrics_value,
        });
        return &self.faces.items[self.faces.items.len - 1];
    }
};

fn pixelSize(value: f32) !u32 {
    if (!std.math.isFinite(value) or value <= 0 or value > 4096) return error.InvalidFontSize;
    return @max(1, @as(u32, @intFromFloat(@round(value))));
}

fn fromFixed26Dot6(value: anytype) f32 {
    return @as(f32, @floatFromInt(value)) / 64.0;
}

const Scalar = struct {
    codepoint: u21,
    start: usize,
    end: usize,
    utf16: usize,
    grapheme: usize = 0,
    level: i8 = 0,
    base_level: i8 = 0,
    script: hb.Script = .common,
};

const Grapheme = struct {
    start: usize,
    end: usize,
    scalar_start: usize,
    scalar_end: usize,
    style: text_api.TextStyle = .{},
    font: text_api.FontHandle = .{ .index = 0, .generation = 0 },
    script: hb.Script = .common,
    level: i8 = 0,
    base_level: i8 = 0,
    width: f32 = 0,
    x: f32 = 0,
    line: usize = std.math.maxInt(usize),
    pending: usize = 0,
    missing_glyph: bool = false,
};

const PendingRun = struct {
    first: usize,
    end: usize,
    byte_start: usize,
    byte_end: usize,
    lease: shaping.Lease,
    metrics: text_api.FontMetrics,
};

pub const LayoutRun = struct {
    start: usize,
    end: usize,
    /// The run's text is either a slice of TextLayout.content or its suffix.
    text: []const u8,
    glyphs: []const shaping.Glyph,
    /// Glyph.cluster is relative to cluster_base, even after a line wrap.
    cluster_base: usize,
    font: text_api.FontHandle,
    style: text_api.TextStyle,
    script: hb.Script,
    level: i8,
    x: f32,
    y: f32,
    /// Logical baseline for these glyphs, after line-height adjustment.
    baseline: f32,
    font_metrics: text_api.FontMetrics,
    width: f32,
    missing_glyph: bool,
    is_suffix: bool = false,
    pub fn backgroundRect(self: LayoutRun, line_height: f32) ?text_api.Rect {
        if (self.style.background == null) return null;
        return .{ .x = self.x, .y = self.y, .width = self.width, .height = line_height };
    }

    pub fn decorationColor(self: LayoutRun) text_api.Color {
        return if (self.style.decoration) |decoration|
            decoration.color
        else
            self.style.foreground;
    }

    pub fn underlineRect(self: LayoutRun) ?text_api.Rect {
        if (!self.style.underline) return null;
        const decoration = self.style.decoration;
        const thickness = if (decoration) |value| value.thickness else self.font_metrics.underline_thickness;
        const offset = if (decoration) |value| value.offset else 0;
        return .{
            .x = self.x,
            .y = self.baseline - self.font_metrics.underline_position + offset,
            .width = self.width,
            .height = thickness,
        };
    }

    pub fn strikeRect(self: LayoutRun) ?text_api.Rect {
        if (!self.style.strike) return null;
        const decoration = self.style.decoration;
        const thickness = if (decoration) |value| value.thickness else self.font_metrics.underline_thickness;
        const offset = if (decoration) |value| value.offset else 0;
        return .{
            .x = self.x,
            .y = self.baseline - self.font_metrics.ascent / 3 + offset,
            .width = self.width,
            .height = thickness,
        };
    }
};

pub const LayoutLine = struct {
    start: usize,
    end: usize,
    first_grapheme: usize,
    end_grapheme: usize,
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    first_run: usize = 0,
    end_run: usize = 0,
};

pub const TextLayout = struct {
    /// The arena backing every slice in this layout, or null when the layout
    /// was carved DIRECTLY in a caller's allocator and must not free it.
    /// A borrowed layout never opens a nested allocator of its own: an arena
    /// created here and then dropped would leak every block it took, and the
    /// caller keeps no handle to release them.
    arena: ?std.heap.ArenaAllocator,
    content: []const u8,
    lines: []const LayoutLine,
    runs: []const LayoutRun,
    scalars: []const Scalar,
    graphemes: []const Grapheme,
    leases: []shaping.Lease,
    /// Owns separately shaped truncation text, including its fallback faces.
    suffix_layout: ?*TextLayout = null,
    width: f32,
    height: f32,
    /// The widest line this content occupies, ignoring any wrap width. This
    /// is measured ink, not the viewport the layout was carved for, so a
    /// max-content probe and a wrapped paint of the same text agree.
    ink_width: f32 = 0,
    /// The widest unbreakable segment: the smallest width at which this
    /// content can still paint without breaking a word.
    min_ink_width: f32 = 0,

    /// Release every cache lease this layout pins, its truncation suffix
    /// first, and only then any allocation it owns. A layout carved in a
    /// caller's arena frees nothing, so a caller may reset that arena
    /// immediately afterwards.
    pub fn release(self: *TextLayout) void {
        self.deinit();
    }

    /// The first shaped line's baseline relative to the text origin, or null
    /// when nothing was shaped. This is the baseline the runs were laid out
    /// against, not a second face-metrics query.
    pub fn firstBaseline(self: *const TextLayout) ?f32 {
        if (self.lines.len == 0) return null;
        const line = self.lines[0];
        if (line.end_run <= line.first_run) return null;
        return self.runs[line.first_run].baseline;
    }

    /// The widest measured line: the real ink extent of this content.
    pub fn inkWidth(self: *const TextLayout) f32 {
        return self.ink_width;
    }

    /// The widest unbreakable segment, which a no-wrap box must be able to
    /// show before any word is broken.
    pub fn minInkWidth(self: *const TextLayout) f32 {
        return self.min_ink_width;
    }

    pub fn deinit(self: *TextLayout) void {
        if (self.suffix_layout) |suffix| suffix.deinit();
        for (self.leases) |*lease| lease.release();
        if (self.arena) |*owned| owned.deinit();
        self.* = undefined;
    }

    fn checkByte(self: *const TextLayout, offset: usize) !void {
        if (offset > self.content.len) return error.InvalidRange;
        if (offset < self.content.len and (self.content[offset] & 0xc0) == 0x80)
            return error.InvalidUtf8Boundary;
    }

    fn graphemeIndex(self: *const TextLayout, offset: usize) !usize {
        try self.checkByte(offset);
        for (self.graphemes, 0..) |g, i| {
            if (g.start == offset) return i;
            if (offset > g.start and offset < g.end) return error.InvalidGraphemeBoundary;
        }
        if (offset == self.content.len) return self.graphemes.len;
        return error.InvalidGraphemeBoundary;
    }

    pub fn nextGrapheme(self: *const TextLayout, offset: usize) !?usize {
        const index = try self.graphemeIndex(offset);
        if (index == self.graphemes.len) return null;
        return self.graphemes[index].end;
    }

    pub fn previousGrapheme(self: *const TextLayout, offset: usize) !?usize {
        const index = try self.graphemeIndex(offset);
        if (index == 0) return null;
        return self.graphemes[index - 1].start;
    }

    pub fn byteToUtf16(self: *const TextLayout, offset: usize) !usize {
        try self.checkByte(offset);
        if (offset == self.content.len) {
            if (self.scalars.len == 0) return 0;
            const last = self.scalars[self.scalars.len - 1];
            const units: usize = if (last.codepoint > 0xffff) 2 else 1;
            return last.utf16 + units;
        }
        for (self.scalars) |scalar| {
            if (scalar.start == offset) return scalar.utf16;
        }
        return error.InvalidUtf8Boundary;
    }

    pub fn utf16ToByte(self: *const TextLayout, offset: usize) !usize {
        for (self.scalars) |scalar| {
            if (scalar.utf16 == offset) return scalar.start;
            const units: usize = if (scalar.codepoint > 0xffff) 2 else 1;
            if (offset > scalar.utf16 and offset < scalar.utf16 + units)
                return error.InvalidRange;
        }
        const end = try self.byteToUtf16(self.content.len);
        if (offset == end) return self.content.len;
        return error.InvalidRange;
    }

    pub fn byteToPosition(
        self: *const TextLayout,
        offset: usize,
        affinity: text_api.CaretAffinity,
    ) !text_api.TextPosition {
        _ = try self.graphemeIndex(offset);
        // A soft wrap has two valid positions for one byte offset.
        for (self.lines, 0..) |line, i| {
            if (affinity == .upstream and line.end == offset and i + 1 < self.lines.len) {
                const at_end = if (line.end_grapheme > line.first_grapheme)
                    self.graphemes[line.end_grapheme - 1]
                else
                    null;
                const caret_x = if (at_end) |g|
                    g.x + if ((g.level & 1) != 0) @as(f32, 0) else g.width
                else
                    line.x;
                return .{ .byte = offset, .line = i, .x = caret_x, .y = line.y, .affinity = affinity };
            }
            if (affinity == .downstream and line.start == offset) {
                const at_start = if (line.first_grapheme < line.end_grapheme)
                    self.graphemes[line.first_grapheme]
                else
                    null;
                const caret_x = if (at_start) |g|
                    g.x + if ((g.level & 1) != 0) g.width else @as(f32, 0)
                else
                    line.x;
                return .{ .byte = offset, .line = i, .x = caret_x, .y = line.y, .affinity = affinity };
            }
        }
        for (self.graphemes) |g| {
            if (g.line == std.math.maxInt(usize)) continue;
            const line = self.lines[g.line];
            const rtl = (g.level & 1) != 0;
            if (g.start == offset and affinity == .downstream)
                return .{
                    .byte = offset,
                    .line = g.line,
                    .x = g.x + if (rtl) g.width else @as(f32, 0),
                    .y = line.y,
                    .affinity = affinity,
                };
            if (g.end == offset and affinity == .upstream)
                return .{
                    .byte = offset,
                    .line = g.line,
                    .x = g.x + if (rtl) @as(f32, 0) else g.width,
                    .y = line.y,
                    .affinity = affinity,
                };
        }
        // At a direction change the requested affinity may not have a unique
        // edge. The opposite edge is still a valid caret at that byte.
        for (self.graphemes) |g| {
            if (g.line == std.math.maxInt(usize)) continue;
            const rtl = (g.level & 1) != 0;
            if (g.start == offset or g.end == offset) {
                return .{
                    .byte = offset,
                    .line = g.line,
                    .x = g.x + if ((g.start == offset) == rtl) g.width else @as(f32, 0),
                    .y = self.lines[g.line].y,
                    .affinity = affinity,
                };
            }
        }
        if (offset == self.content.len and self.lines.len > 0) {
            const i = self.lines.len - 1;
            const last = self.lines[i];
            return .{
                .byte = offset,
                .line = i,
                .x = last.x + last.width,
                .y = last.y,
                .affinity = affinity,
            };
        }
        return error.HiddenText;
    }

    pub fn positionToByte(self: *const TextLayout, line_index: usize, x: f32) !text_api.TextPosition {
        if (line_index >= self.lines.len or !std.math.isFinite(x)) return error.InvalidRange;
        const line = self.lines[line_index];
        var best: text_api.TextPosition = .{
            .byte = line.start,
            .line = line_index,
            .x = line.x,
            .y = line.y,
            .affinity = .downstream,
        };
        if (line.first_grapheme < line.end_grapheme) {
            const g = self.graphemes[line.first_grapheme];
            best.x = g.x + if ((g.level & 1) != 0) g.width else @as(f32, 0);
        }
        var distance = @abs(x - best.x);
        for (self.graphemes) |g| {
            if (g.line != line_index) continue;
            const rtl = (g.level & 1) != 0;
            const leading = g.x + if (rtl) g.width else @as(f32, 0);
            const trailing = g.x + if (rtl) @as(f32, 0) else g.width;
            const edges = [_]text_api.TextPosition{
                .{
                    .byte = g.start,
                    .line = line_index,
                    .x = leading,
                    .y = line.y,
                    .affinity = .downstream,
                },
                .{
                    .byte = g.end,
                    .line = line_index,
                    .x = trailing,
                    .y = line.y,
                    .affinity = .upstream,
                },
            };
            for (edges) |edge| {
                const d = @abs(x - edge.x);
                if (d < distance or (d == distance and edge.affinity == .downstream)) {
                    best = edge;
                    distance = d;
                }
            }
        }
        return best;
    }

    pub fn rangeBounds(
        self: *const TextLayout,
        allocator: std.mem.Allocator,
        range: text_api.ByteRange,
    ) ![]text_api.Rect {
        if (range.start > range.end) return error.InvalidRange;
        _ = try self.graphemeIndex(range.start);
        _ = try self.graphemeIndex(range.end);
        var rects: std.ArrayList(text_api.Rect) = .empty;
        errdefer rects.deinit(allocator);
        for (self.lines, 0..) |line, line_index| {
            for (self.graphemes) |g| {
                if (g.line != line_index or g.start < range.start or g.end > range.end) continue;
                if (g.width == 0) continue;
                try rects.append(allocator, .{ .x = g.x, .y = line.y, .width = g.width, .height = line.height });
            }
        }
        std.mem.sort(text_api.Rect, rects.items, {}, rectLess);
        var count: usize = 0;
        for (rects.items) |rect| {
            if (count > 0) {
                const prior = &rects.items[count - 1];
                if (prior.y == rect.y and rect.x <= prior.x + prior.width + 0.01) {
                    prior.width = @max(prior.x + prior.width, rect.x + rect.width) - prior.x;
                    continue;
                }
            }
            rects.items[count] = rect;
            count += 1;
        }
        rects.shrinkRetainingCapacity(count);
        return rects.toOwnedSlice(allocator);
    }
};

fn rectLess(_: void, a: text_api.Rect, b: text_api.Rect) bool {
    return a.y < b.y or (a.y == b.y and a.x < b.x);
}

fn decodeText(allocator: std.mem.Allocator, bytes: []const u8) !std.ArrayList(Scalar) {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    var scalars: std.ArrayList(Scalar) = .empty;
    var byte: usize = 0;
    var units: usize = 0;
    while (byte < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[byte]) catch return error.InvalidUtf8;
        const end = byte + length;
        const sequence = bytes[byte..end];
        // The slice passed utf8ValidateSlice above, so every sequence decodes
        // cleanly; report the failure instead of trapping if that ever changes.
        const codepoint: u21 = switch (sequence.len) {
            1 => sequence[0],
            2 => std.unicode.utf8Decode2(sequence[0..2].*) catch return error.InvalidUtf8,
            3 => std.unicode.utf8Decode3(sequence[0..3].*) catch return error.InvalidUtf8,
            4 => std.unicode.utf8Decode4(sequence[0..4].*) catch return error.InvalidUtf8,
            else => return error.InvalidUtf8,
        };
        try scalars.append(allocator, .{
            .codepoint = codepoint,
            .start = byte,
            .end = end,
            .utf16 = units,
        });
        units += if (codepoint > 0xffff) @as(usize, 2) else 1;
        byte = end;
    }
    return scalars;
}

fn scriptOf(codepoint: u21) hb.Script {
    const raw = c.hb_unicode_script(c.hb_unicode_funcs_get_default(), codepoint);
    const value: u31 = @intCast(raw);
    return std.enums.fromInt(hb.Script, value) orelse .unknown;
}

fn itemizeBidi(allocator: std.mem.Allocator, scalars: []Scalar, direction: text_api.Direction) !void {
    if (scalars.len == 0) return;
    if (scalars.len > std.math.maxInt(c_int)) return error.TextTooLong;
    const characters = try allocator.alloc(u32, scalars.len);
    const types = try allocator.alloc(u32, scalars.len);
    const brackets = try allocator.alloc(u32, scalars.len);
    const levels = try allocator.alloc(i8, scalars.len);
    for (scalars, characters) |*scalar, *character| {
        character.* = scalar.codepoint;
        scalar.script = scriptOf(scalar.codepoint);
    }
    // FriBidi operates on one paragraph at a time. CRLF is one hard break.
    var begin: usize = 0;
    while (begin < scalars.len) {
        var end = begin;
        while (end < scalars.len and scalars[end].codepoint != '\n' and
            scalars[end].codepoint != '\r') : (end += 1)
        {}
        if (end > begin) {
            const len: c_int = @intCast(end - begin);
            fribidi_get_bidi_types(characters[begin..end].ptr, len, types[begin..end].ptr);
            fribidi_get_bracket_types(characters[begin..end].ptr, len, types[begin..end].ptr, brackets[begin..end].ptr);
            var base: u32 = switch (direction) {
                .auto => 0x40, // FRIBIDI_PAR_ON
                .ltr => 0x110, // FRIBIDI_PAR_LTR
                .rtl => 0x111, // FRIBIDI_PAR_RTL
            };
            if (fribidi_get_par_embedding_levels_ex(
                types[begin..end].ptr,
                brackets[begin..end].ptr,
                len,
                &base,
                levels[begin..end].ptr,
            ) == 0) return error.BidiFailed;
            const base_level: i8 = if ((base & 1) == 1) 1 else 0;
            for (scalars[begin..end], levels[begin..end]) |*scalar, level| {
                scalar.level = level;
                scalar.base_level = base_level;
            }
        }
        if (end == scalars.len) break;
        const base_level: i8 = if (direction == .rtl) 1 else 0;
        scalars[end].level = base_level;
        scalars[end].base_level = base_level;
        begin = end + 1;
        if (scalars[end].codepoint == '\r' and begin < scalars.len and
            scalars[begin].codepoint == '\n')
        {
            scalars[begin].level = base_level;
            scalars[begin].base_level = base_level;
            begin += 1;
        }
    }
}

fn collectGraphemes(allocator: std.mem.Allocator, scalars: []Scalar) !std.ArrayList(Grapheme) {
    var graphemes: std.ArrayList(Grapheme) = .empty;
    if (scalars.len == 0) return graphemes;
    var begin: usize = 0;
    var state: i32 = 0;
    for (1..scalars.len + 1) |i| {
        const boundary = i == scalars.len or
            utf8proc_grapheme_break_stateful(
                @intCast(scalars[i - 1].codepoint),
                @intCast(scalars[i].codepoint),
                &state,
            );
        if (!boundary) continue;
        const index = graphemes.items.len;
        var script: hb.Script = .common;
        for (scalars[begin..i]) |*scalar| {
            scalar.grapheme = index;
            if (scalar.script != .common and scalar.script != .inherited and
                scalar.script != .unknown) script = scalar.script;
        }
        if (script == .common and index > 0) script = graphemes.items[index - 1].script;
        try graphemes.append(allocator, .{
            .start = scalars[begin].start,
            .end = scalars[i - 1].end,
            .scalar_start = begin,
            .scalar_end = i,
            .script = script,
            .level = scalars[begin].level,
            .base_level = scalars[begin].base_level,
        });
        begin = i;
    }
    return graphemes;
}

fn isHardBreak(g: Grapheme, bytes: []const u8) bool {
    return bytes[g.start] == '\n' or bytes[g.start] == '\r';
}

fn isSoftBreak(g: Grapheme, bytes: []const u8) bool {
    return bytes[g.start] == ' ' or bytes[g.start] == '\t' or
        std.mem.eql(u8, bytes[g.start..g.end], zero_width_space);
}

fn ignoredForCoverage(codepoint: u21) bool {
    return codepoint == 0x200d or codepoint == 0x200b or
        codepoint == '\r' or codepoint == '\n' or
        (codepoint >= 0xfe00 and codepoint <= 0xfe0f) or
        (codepoint >= 0xe0100 and codepoint <= 0xe01ef);
}

fn copiesStyle(allocator: std.mem.Allocator, style: text_api.TextStyle) !text_api.TextStyle {
    var copy = style;
    copy.font.features = try allocator.dupe(text_api.Feature, style.font.features);
    copy.font.fallback = try allocator.dupe(text_api.FontHandle, style.font.fallback);
    copy.font.family = try allocator.dupe(u8, style.font.family);
    return copy;
}

fn validateRanges(bytes: []const u8, graphemes: []const Grapheme, ranges: []const text_api.StyledRange) !void {
    for (ranges) |item| {
        if (item.range.start > item.range.end or item.range.end > bytes.len) return error.InvalidRange;
        for ([_]usize{ item.range.start, item.range.end }) |offset| {
            if (offset < bytes.len and (bytes[offset] & 0xc0) == 0x80) return error.InvalidUtf8Boundary;
            if (offset == bytes.len) continue;
            var valid = false;
            for (graphemes) |g| {
                if (g.start == offset) {
                    valid = true;
                    break;
                }
            }
            if (!valid) return error.InvalidGraphemeBoundary;
        }
    }
}

fn requestForGrapheme(base: text_api.TextStyle, ranges: []const text_api.StyledRange, g: Grapheme) text_api.TextStyle {
    var style = base;
    for (ranges) |item| {
        if (item.range.start <= g.start and item.range.end >= g.end)
            style = style.resolve(item.override);
    }
    return style;
}

fn matchesFont(self: *TextService, id: u8, grapheme: Grapheme, scalars: []const Scalar) !bool {
    const face = try self.faceFor(id, 16, self.infos.items[id].weight);
    for (scalars[grapheme.scalar_start..grapheme.scalar_end]) |scalar| {
        if (ignoredForCoverage(scalar.codepoint)) continue;
        if (c.FT_Get_Char_Index(face.face, scalar.codepoint) == 0) return false;
    }
    return true;
}

fn chooseFont(
    self: *TextService,
    g: Grapheme,
    scalars: []const Scalar,
    request: text_api.FontRequest,
    missing_policy: text_api.MissingGlyph,
) !struct { handle: text_api.FontHandle, missing: bool } {
    const primary: text_api.FontHandle = if (request.handle != null or request.family.len != 0)
        try self.resolve(request)
    else if (self.infos.items.len > 0)
        self.infos.items[0].handle
    else
        return error.FontUnavailable;
    const id = try self.fontIndex(primary);
    if (try matchesFont(self, id, g, scalars)) return .{ .handle = primary, .missing = false };
    for (request.fallback) |handle| {
        const fallback_id = try self.fontIndex(handle);
        if (try matchesFont(self, fallback_id, g, scalars))
            return .{ .handle = handle, .missing = false };
    }
    if (missing_policy == .error_if_missing) return error.MissingGlyph;
    return .{ .handle = primary, .missing = true };
}

fn styleShapesEqual(left: text_api.TextStyle, right: text_api.TextStyle) bool {
    const a = left.font;
    const b = right.font;
    if (a.size != b.size or a.weight != b.weight or a.style != b.style or
        !std.meta.eql(a.handle, b.handle) or !std.mem.eql(u8, a.family, b.family) or
        a.features.len != b.features.len or a.fallback.len != b.fallback.len) return false;
    for (a.features, b.features) |one, two| {
        if (one.tag != two.tag or one.value != two.value) return false;
    }
    for (a.fallback, b.fallback) |one, two| {
        if (!std.meta.eql(one, two)) return false;
    }
    // Paint changes split layout runs so backgrounds/decorations remain exact.
    return std.meta.eql(left.foreground, right.foreground) and
        std.meta.eql(left.background, right.background) and
        left.underline == right.underline and left.strike == right.strike and
        std.meta.eql(left.decoration, right.decoration);
}

fn featureDigest(features: []const text_api.Feature) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (features) |feature| {
        hasher.update(std.mem.asBytes(&feature.tag));
        hasher.update(std.mem.asBytes(&feature.value));
    }
    return hasher.final();
}

fn fallbackDigest(handles: []const text_api.FontHandle) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (handles) |handle| {
        hasher.update(std.mem.asBytes(&handle.index));
        hasher.update(std.mem.asBytes(&handle.generation));
    }
    return hasher.final();
}

const ClusterAdvance = struct {
    start: usize,
    width: f32,
};

fn clusterLess(_: void, left: ClusterAdvance, right: ClusterAdvance) bool {
    return left.start < right.start;
}

fn distributeAdvances(
    allocator: std.mem.Allocator,
    graphemes: []Grapheme,
    pending: PendingRun,
) !void {
    var clusters: std.ArrayList(ClusterAdvance) = .empty;
    for (pending.lease.run.glyphs) |glyph| {
        try clusters.append(allocator, .{
            .start = pending.byte_start + glyph.cluster,
            .width = glyph.x_advance,
        });
    }
    std.mem.sort(ClusterAdvance, clusters.items, {}, clusterLess);
    var cluster_index: usize = 0;
    var grapheme_index = pending.first;
    while (cluster_index < clusters.items.len) {
        const start = clusters.items[cluster_index].start;
        var width: f32 = 0;
        while (cluster_index < clusters.items.len and
            clusters.items[cluster_index].start == start) : (cluster_index += 1)
            width += clusters.items[cluster_index].width;
        const end = if (cluster_index < clusters.items.len)
            clusters.items[cluster_index].start
        else
            pending.byte_end;
        while (grapheme_index < pending.end and graphemes[grapheme_index].start < start)
            grapheme_index += 1;
        const first = grapheme_index;
        while (grapheme_index < pending.end and graphemes[grapheme_index].start < end)
            grapheme_index += 1;
        if (first == grapheme_index) continue;
        const share = width / @as(f32, @floatFromInt(grapheme_index - first));
        for (graphemes[first..grapheme_index]) |*g| g.width = share;
    }
}

const ShapedFontRun = struct {
    lease: shaping.Lease,
    metrics: text_api.FontMetrics,
};

fn acquireStyled(
    self: *TextService,
    allocator: std.mem.Allocator,
    font_handle: text_api.FontHandle,
    request: text_api.FontRequest,
    value: []const u8,
    script: hb.Script,
    direction: hb.Direction,
    paragraph_direction: text_api.Direction,
    generation: u64,
) !ShapedFontRun {
    const id = try self.fontIndex(font_handle);
    const face = try self.faceFor(id, try pixelSize(request.size), request.weight);
    const features = try allocator.alloc(hb.Feature, request.features.len);
    for (request.features, features) |feature, *hb_feature| {
        hb_feature.* = .{ .tag = feature.tag, .value = feature.value, .start = 0, .end = std.math.maxInt(u32) };
    }
    const lease = try self.cache.acquireWith(
        .{
            .font_id = id,
            .size = face.size,
            .content_generation = generation,
            .font_revision = font_handle.generation,
            .feature_digest = featureDigest(request.features),
            .fallback_digest = fallbackDigest(request.fallback),
            .weight = request.weight,
            .style = @backingInt(request.style),
            .direction = direction,
            .paragraph_direction = @backingInt(paragraph_direction),
            .script = script,
        },
        face.font,
        value,
        .{ .direction = direction, .script = script, .features = features },
        &self.sink,
    );
    return .{ .lease = lease, .metrics = face.metrics };
}

fn makePending(
    self: *TextService,
    allocator: std.mem.Allocator,
    graphemes: []Grapheme,
    first: usize,
    end: usize,
    content: []const u8,
    generation: u64,
    paragraph_direction: text_api.Direction,
) !PendingRun {
    const first_g = graphemes[first];
    const byte_start = first_g.start;
    const byte_end = graphemes[end - 1].end;
    const direction: hb.Direction = if ((first_g.level & 1) != 0) .rtl else .ltr;
    var shaped = try acquireStyled(
        self,
        allocator,
        first_g.font,
        first_g.style.font,
        content[byte_start..byte_end],
        first_g.script,
        direction,
        paragraph_direction,
        generation,
    );
    errdefer shaped.lease.release();
    const pending: PendingRun = .{
        .first = first,
        .end = end,
        .byte_start = byte_start,
        .byte_end = byte_end,
        .lease = shaped.lease,
        .metrics = shaped.metrics,
    };
    try distributeAdvances(allocator, graphemes, pending);
    return pending;
}

fn itemizeRuns(
    self: *TextService,
    allocator: std.mem.Allocator,
    graphemes: []Grapheme,
    content: []const u8,
    generation: u64,
    paragraph_direction: text_api.Direction,
    pending: *std.ArrayList(PendingRun),
) !void {
    var first: usize = 0;
    while (first < graphemes.len) {
        if (isHardBreak(graphemes[first], content)) {
            first += 1;
            continue;
        }
        const sample = graphemes[first];
        var end = first + 1;
        while (end < graphemes.len) : (end += 1) {
            const next = graphemes[end];
            if (isHardBreak(next, content) or !std.meta.eql(next.font, sample.font) or
                next.script != sample.script or next.level != sample.level or
                next.missing_glyph != sample.missing_glyph or
                !styleShapesEqual(next.style, sample.style)) break;
        }
        const owned_style = try copiesStyle(allocator, sample.style);
        const index = pending.items.len;
        for (graphemes[first..end]) |*g| {
            g.pending = index;
            g.style = owned_style;
        }
        var run = try makePending(self, allocator, graphemes, first, end, content, generation, paragraph_direction);
        errdefer run.lease.release();
        try pending.append(allocator, run);
        first = end;
    }
}

fn buildLines(
    allocator: std.mem.Allocator,
    graphemes: []const Grapheme,
    content: []const u8,
    paragraph: text_api.Paragraph,
) !std.ArrayList(LayoutLine) {
    var result: std.ArrayList(LayoutLine) = .empty;
    const cap: f32 = paragraph.wrap_width orelse std.math.floatMax(f32);
    var first: usize = 0;
    while (first <= graphemes.len) {
        var index = first;
        var width: f32 = 0;
        var last_space: ?usize = null;
        var broke = false;
        while (index < graphemes.len) : (index += 1) {
            const g = graphemes[index];
            if (isHardBreak(g, content)) {
                try result.append(allocator, .{
                    .start = if (first < graphemes.len) graphemes[first].start else content.len,
                    .end = g.end,
                    .first_grapheme = first,
                    .end_grapheme = index,
                    .width = width,
                });
                first = index + 1;
                broke = true;
                break;
            }
            if (paragraph.wrap == .flow and width + g.width > cap and index > first) {
                const end = if (last_space) |space| space else index;
                const after = if (last_space) |space| space + 1 else index;
                var visible_width: f32 = 0;
                for (graphemes[first..end]) |item| visible_width += item.width;
                try result.append(allocator, .{
                    .start = graphemes[first].start,
                    .end = if (after < graphemes.len) graphemes[after].start else content.len,
                    .first_grapheme = first,
                    .end_grapheme = end,
                    .width = visible_width,
                });
                first = after;
                broke = true;
                break;
            }
            width += g.width;
            if (isSoftBreak(g, content)) last_space = index;
        }
        if (broke) continue;
        try result.append(allocator, .{
            .start = if (first < graphemes.len) graphemes[first].start else content.len,
            .end = content.len,
            .first_grapheme = first,
            .end_grapheme = graphemes.len,
            .width = width,
        });
        break;
    }
    return result;
}

fn visualGraphemes(
    allocator: std.mem.Allocator,
    graphemes: []const Grapheme,
    first: usize,
    end: usize,
) ![]usize {
    const order = try allocator.alloc(usize, end - first);
    var highest: i8 = 0;
    var lowest_odd: i8 = std.math.maxInt(i8);
    for (order, 0..) |*slot, index| {
        slot.* = first + index;
        const level = graphemes[first + index].level;
        highest = @max(highest, level);
        if ((level & 1) == 1) lowest_odd = @min(lowest_odd, level);
    }
    if (lowest_odd == std.math.maxInt(i8)) return order;
    var level = highest;
    while (level >= lowest_odd) : (level -= 1) {
        var index: usize = 0;
        while (index < order.len) {
            if (graphemes[order[index]].level < level) {
                index += 1;
                continue;
            }
            const begin = index;
            while (index < order.len and graphemes[order[index]].level >= level) : (index += 1) {}
            std.mem.reverse(usize, order[begin..index]);
        }
    }
    return order;
}

const Interval = struct { first: usize, end: usize };
const VisiblePieces = struct {
    intervals: [2]Interval = .{ .{ .first = 0, .end = 0 }, .{ .first = 0, .end = 0 } },
    count: usize = 0,
    suffix_after: usize = 0,
};

fn clippedPieces(
    graphemes: []const Grapheme,
    content: []const u8,
    first: usize,
    mode: text_api.TruncateMode,
    available: f32,
) VisiblePieces {
    var pieces: VisiblePieces = .{};
    var tail_first = first;
    for (graphemes[first..], first..) |g, index| {
        if (isHardBreak(g, content)) tail_first = index + 1;
    }
    const tail_end = graphemes.len;
    switch (mode) {
        .end => {
            var end = first;
            var width: f32 = 0;
            while (end < tail_end and !isHardBreak(graphemes[end], content) and
                width + graphemes[end].width <= available) : (end += 1)
                width += graphemes[end].width;
            pieces.intervals[0] = .{ .first = first, .end = end };
            pieces.count = 1;
            pieces.suffix_after = 1;
        },
        .start => {
            var begin = tail_end;
            var width: f32 = 0;
            while (begin > tail_first and
                width + graphemes[begin - 1].width <= available)
            {
                begin -= 1;
                width += graphemes[begin].width;
            }
            pieces.intervals[0] = .{ .first = begin, .end = tail_end };
            pieces.count = 1;
            pieces.suffix_after = 0;
        },
        .middle => {
            var end = first;
            var begin = tail_end;
            var width: f32 = 0;
            var take_front = true;
            while (end < begin) {
                if (take_front and !isHardBreak(graphemes[end], content) and
                    width + graphemes[end].width <= available)
                {
                    width += graphemes[end].width;
                    end += 1;
                } else if (!take_front and begin > tail_first and
                    width + graphemes[begin - 1].width <= available)
                {
                    begin -= 1;
                    width += graphemes[begin].width;
                } else break;
                take_front = !take_front;
            }
            pieces.intervals[0] = .{ .first = first, .end = end };
            pieces.intervals[1] = .{ .first = begin, .end = tail_end };
            pieces.count = 2;
            pieces.suffix_after = 1;
        },
    }
    return pieces;
}

fn piecesWidth(graphemes: []const Grapheme, pieces: VisiblePieces) f32 {
    var width: f32 = 0;
    for (pieces.intervals[0..pieces.count]) |interval| {
        for (graphemes[interval.first..interval.end]) |g| width += g.width;
    }
    return width;
}

fn glyphsForRange(pending: PendingRun, start: usize, end: usize) []const shaping.Glyph {
    var low = pending.lease.run.glyphs.len;
    var high: usize = 0;
    for (pending.lease.run.glyphs, 0..) |glyph, index| {
        const cluster = pending.byte_start + glyph.cluster;
        if (cluster < start or cluster >= end) continue;
        low = @min(low, index);
        high = index + 1;
    }
    if (low >= high) return &.{};
    return pending.lease.run.glyphs[low..high];
}

fn emitInterval(
    allocator: std.mem.Allocator,
    graphemes: []Grapheme,
    pending: []const PendingRun,
    content: []const u8,
    interval: Interval,
    line_index: usize,
    y: f32,
    line_height: f32,
    cursor: *f32,
    runs: *std.ArrayList(LayoutRun),
) !void {
    const order = try visualGraphemes(allocator, graphemes, interval.first, interval.end);
    var index: usize = 0;
    while (index < order.len) {
        const g_index = order[index];
        const source = graphemes[g_index];
        const pending_index = source.pending;
        const x = cursor.*;
        var start = source.start;
        var end = source.end;
        var width: f32 = 0;
        while (index < order.len and graphemes[order[index]].pending == pending_index) : (index += 1) {
            const g = &graphemes[order[index]];
            g.x = cursor.*;
            g.line = line_index;
            cursor.* += g.width;
            width += g.width;
            start = @min(start, g.start);
            end = @max(end, g.end);
        }
        const shaped = pending[pending_index];
        try runs.append(allocator, .{
            .start = start,
            .end = end,
            .text = content[start..end],
            .glyphs = glyphsForRange(shaped, start, end),
            .cluster_base = shaped.byte_start,
            .font = source.font,
            .style = source.style,
            .script = source.script,
            .level = source.level,
            .x = x,
            .y = y,
            .baseline = y + (line_height - shaped.metrics.line_height) / 2 + shaped.metrics.ascent,
            .font_metrics = shaped.metrics,
            .width = width,
            .missing_glyph = source.missing_glyph,
        });
    }
}

fn alignedX(width: f32, line_width: f32, alignment: text_api.Align, rtl: bool) f32 {
    const slack = @max(0, width - line_width);
    return switch (alignment) {
        .center => slack / 2,
        .start => if (rtl) slack else 0,
        .end => if (rtl) 0 else slack,
        .left => 0,
        .right => slack,
    };
}

fn addSuffix(
    allocator: std.mem.Allocator,
    runs: *std.ArrayList(LayoutRun),
    suffix: *const TextLayout,
    source_byte: usize,
    y: f32,
    line_height: f32,
    cursor: *f32,
) !void {
    for (suffix.runs) |source| {
        var run = source;
        run.start = source_byte;
        run.end = source_byte;
        run.x += cursor.*;
        run.y = y;
        run.baseline = y + (line_height - source.font_metrics.line_height) / 2 +
            source.font_metrics.ascent;
        run.is_suffix = true;
        try runs.append(allocator, run);
    }
    cursor.* += suffix.width;
}

fn renderLine(
    allocator: std.mem.Allocator,
    graphemes: []Grapheme,
    pending: []const PendingRun,
    content: []const u8,
    line: *LayoutLine,
    line_index: usize,
    paragraphs: text_api.Paragraph,
    layout_width: f32,
    pieces: VisiblePieces,
    suffix: ?*const TextLayout,
    runs: *std.ArrayList(LayoutRun),
) !void {
    const suffix_width = if (suffix) |value| value.width else 0;
    line.width = piecesWidth(graphemes, pieces) + suffix_width;
    const rtl = if (line.first_grapheme < graphemes.len)
        (graphemes[line.first_grapheme].base_level & 1) != 0
    else
        paragraphs.direction == .rtl;
    line.x = alignedX(layout_width, line.width, paragraphs.alignment, rtl);
    line.first_run = runs.items.len;
    var cursor = line.x;
    for (0..pieces.count + 1) |index| {
        if (index == pieces.suffix_after) {
            if (suffix) |value| try addSuffix(
                allocator,
                runs,
                value,
                if (pieces.count > 0 and pieces.intervals[0].end < graphemes.len)
                    graphemes[pieces.intervals[0].end].start
                else
                    content.len,
                line.y,
                line.height,
                &cursor,
            );
        }
        if (index < pieces.count)
            try emitInterval(
                allocator,
                graphemes,
                pending,
                content,
                pieces.intervals[index],
                line_index,
                line.y,
                line.height,
                &cursor,
                runs,
            );
    }
    line.end_run = runs.items.len;
    std.debug.assert(@abs(cursor - (line.x + line.width)) < 0.1);
}

fn validateFontRequest(service: *const TextService, request: text_api.FontRequest) !void {
    _ = try pixelSize(request.size);
    if (request.weight < 1 or request.weight > 1000) return error.InvalidWeight;
    if (request.handle != null or request.family.len != 0) {
        _ = try service.resolve(request);
    } else if (service.infos.items.len == 0) {
        return error.FontUnavailable;
    }
    for (request.fallback) |fallback| _ = try service.fontIndex(fallback);
}

/// A layout either OWNS its memory, opening an arena over `allocator` that
/// `TextLayout.deinit` frees, or is carved DIRECTLY in `allocator`. A
/// borrowed layout must not open a nested arena: `TextLayout` is returned by
/// value, so such an arena would be dropped here and every block it took from
/// `allocator` would leak with no handle left to release them.
fn layoutText(
    service: *TextService,
    allocator: std.mem.Allocator,
    request: text_api.LayoutRequest,
    owns_arena: bool,
) !TextLayout {
    const paragraph = request.paragraph;
    if (paragraph.wrap_width) |width| {
        if (!std.math.isFinite(width) or width < 0) return error.InvalidWrapWidth;
    }
    if (paragraph.line_height) |height| {
        if (!std.math.isFinite(height) or height <= 0) return error.InvalidLineHeight;
    }
    if (paragraph.max_lines) |count| {
        if (count == 0) return error.InvalidLineClamp;
    }
    try validateFontRequest(service, request.style.font);
    if (paragraph.truncate) |truncation| {
        if (!std.unicode.utf8ValidateSlice(truncation.suffix)) return error.InvalidUtf8;
        if (std.mem.indexOfAny(u8, truncation.suffix, "\r\n") != null) return error.InvalidSuffix;
    }

    var owned: ?std.heap.ArenaAllocator = null;
    if (owns_arena) owned = std.heap.ArenaAllocator.init(allocator);
    errdefer if (owned) |*arena| arena.deinit();
    const scratch = if (owned) |*arena| arena.allocator() else allocator;
    const content = try scratch.dupe(u8, request.content);
    var scalar_list = try decodeText(scratch, content);
    try itemizeBidi(scratch, scalar_list.items, paragraph.direction);
    var grapheme_list = try collectGraphemes(scratch, scalar_list.items);
    const graphemes = grapheme_list.items;
    try validateRanges(content, graphemes, request.ranges);
    for (request.ranges) |item| {
        try validateFontRequest(service, request.style.resolve(item.override).font);
    }
    for (graphemes) |*g| {
        if (isHardBreak(g.*, content)) continue;
        g.style = requestForGrapheme(request.style, request.ranges, g.*);
        // Validated once per requested style, not once per grapheme.
        const choice = try chooseFont(service, g.*, scalar_list.items, g.style.font, request.missing_glyph);
        g.font = choice.handle;
        g.missing_glyph = choice.missing;
    }

    var pending: std.ArrayList(PendingRun) = .empty;
    var leases_transferred = false;
    errdefer if (!leases_transferred) {
        for (pending.items) |*run| run.lease.release();
    };
    try itemizeRuns(service, scratch, graphemes, content, request.content_generation, paragraph.direction, &pending);

    var line_list = try buildLines(scratch, graphemes, content, paragraph);
    const original_line_count = line_list.items.len;
    const limit = paragraph.max_lines orelse original_line_count;
    const visible = @min(limit, original_line_count);
    line_list.shrinkRetainingCapacity(visible);
    const lines = line_list.items;
    var natural_width: f32 = 0;
    for (lines) |line| natural_width = @max(natural_width, line.width);
    const layout_width = if (paragraph.truncate != null)
        paragraph.wrap_width orelse natural_width
    else
        @max(paragraph.wrap_width orelse 0, natural_width);

    // The content probes come from the itemized graphemes and their shaped
    // advances, not from a second shaping pass over a whole-line guess.
    const ink = intrinsicInk(graphemes, content);

    var suffix_layout: ?*TextLayout = null;
    errdefer if (suffix_layout) |suffix| suffix.deinit();
    var runs: std.ArrayList(LayoutRun) = .empty;
    var y: f32 = 0;
    for (lines, 0..) |*line, line_index| {
        const is_final = line_index + 1 == lines.len;
        const hidden_lines = original_line_count > lines.len;
        const clipped_line = paragraph.wrap == .no_wrap and
            paragraph.wrap_width != null and line.width > paragraph.wrap_width.?;
        const needs_truncation = is_final and (hidden_lines or clipped_line);
        var pieces: VisiblePieces = .{
            .intervals = .{ .{ .first = line.first_grapheme, .end = line.end_grapheme }, .{ .first = 0, .end = 0 } },
            .count = 1,
            .suffix_after = 1,
        };
        if (needs_truncation) {
            if (paragraph.truncate) |truncation| {
                const style_g = if (line.first_grapheme < graphemes.len and
                    !isHardBreak(graphemes[line.first_grapheme], content))
                    &graphemes[line.first_grapheme]
                else
                    null;
                const suffix_style = if (style_g) |g| g.style else try copiesStyle(scratch, request.style);
                const nested = try scratch.create(TextLayout);
                nested.* = try layoutText(service, scratch, .{
                    .content = truncation.suffix,
                    .content_generation = request.content_generation,
                    .style = suffix_style,
                    .paragraph = .{ .wrap = .no_wrap, .direction = paragraph.direction },
                    .missing_glyph = request.missing_glyph,
                }, false);
                suffix_layout = nested;
                const width_limit = paragraph.wrap_width orelse line.width + nested.width;
                if (nested.width > width_limit) return error.SuffixTooWide;
                pieces = clippedPieces(
                    graphemes,
                    content,
                    line.first_grapheme,
                    truncation.mode,
                    width_limit - nested.width,
                );
            }
        }
        line.y = y;
        const base_font = if (request.style.font.handle != null or request.style.font.family.len != 0)
            try service.resolve(request.style.font)
        else if (service.infos.items.len > 0)
            service.infos.items[0].handle
        else
            return error.FontUnavailable;
        var natural_height: f32 = (try service.metrics(base_font, request.style.font.size)).line_height;
        for (pieces.intervals[0..pieces.count]) |interval| {
            for (graphemes[interval.first..interval.end]) |g| {
                if (isHardBreak(g, content)) continue;
                const id = try service.fontIndex(g.font);
                const face = try service.faceFor(id, try pixelSize(g.style.font.size), g.style.font.weight);
                natural_height = @max(natural_height, face.metrics.line_height);
            }
        }
        if (suffix_layout) |suffix| {
            for (suffix.runs) |run| natural_height = @max(natural_height, run.font_metrics.line_height);
        }
        line.height = paragraph.line_height orelse natural_height;
        y += line.height;
        try renderLine(
            scratch,
            graphemes,
            pending.items,
            content,
            line,
            line_index,
            paragraph,
            layout_width,
            pieces,
            suffix_layout,
            &runs,
        );
        if (suffix_layout != null) break;
    }

    const leases = try scratch.alloc(shaping.Lease, pending.items.len);
    for (pending.items, leases) |source, *target| target.* = source.lease;
    const final_lines = try line_list.toOwnedSlice(scratch);
    const final_runs = try runs.toOwnedSlice(scratch);
    const final_scalars = try scalar_list.toOwnedSlice(scratch);
    const final_graphemes = try grapheme_list.toOwnedSlice(scratch);
    leases_transferred = true;
    const nested_layout = suffix_layout;
    suffix_layout = null;
    return .{
        .arena = if (owns_arena) owned else null,
        .content = content,
        .lines = final_lines,
        .runs = final_runs,
        .scalars = final_scalars,
        .graphemes = final_graphemes,
        .leases = leases,
        .suffix_layout = nested_layout,
        .width = if (paragraph.wrap == .no_wrap and paragraph.truncate == null) natural_width else layout_width,
        .height = y,
        .ink_width = ink.max,
        .min_ink_width = ink.min,
    };
}

/// The request-level width probes, read from the same itemized graphemes and
/// shaped advances the lines were built from. `max` is the widest hard-broken
/// line; `min` is the widest unbreakable segment, the smallest width at which
/// the content still paints without breaking a word. A break opportunity's own
/// separator belongs to neither probe: it trails a line without making the
/// unbreakable minimum wider.
fn intrinsicInk(
    graphemes: []const Grapheme,
    content: []const u8,
) struct { min: f32, max: f32 } {
    var min_width: f32 = 0;
    var max_width: f32 = 0;
    var line_width: f32 = 0;
    var segment_width: f32 = 0;
    for (graphemes) |g| {
        if (isHardBreak(g, content)) {
            max_width = @max(max_width, line_width);
            min_width = @max(min_width, segment_width);
            line_width = 0;
            segment_width = 0;
            continue;
        }
        if (isSoftBreak(g, content)) {
            min_width = @max(min_width, segment_width);
            segment_width = 0;
        } else {
            segment_width += g.width;
        }
        line_width += g.width;
    }
    max_width = @max(max_width, line_width);
    min_width = @max(min_width, segment_width);
    return .{ .min = min_width, .max = max_width };
}
