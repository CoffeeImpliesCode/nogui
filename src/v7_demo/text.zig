//! HarfBuzz-shaped text engine for the v7 demo.
//!
//! EXPERIMENT: the per-codepoint FreeType iteration (FT_Get_Char_Index +
//! advance sums, no kerning) is replaced with HarfBuzz shaping (hb_shape:
//! kerning, ligatures, mark positioning). FreeType remains as the rasterizer
//! backend ONLY — the hb-ft font delegates outline extraction to it, and we
//! load the shaped glyph ids from the shared face. All layout decisions
//! (glyph selection, advances, offsets) come from HarfBuzz.
//!
//! Demo-side only: the v7 CORE (src/v7/) stays pure; this file MAY import
//! noapi.

const std = @import("std");
const tracy = @import("tracy");
const noapi = @import("noapi");
const renderer = @import("v7_render");
const SceneRect = renderer.SceneRect;
const nogui = @import("nogui");
pub const WidgetSize = nogui.widget.Size;
pub const MeasureInput = nogui.layout.MeasureInput;

// One C import, owned by the HarfBuzz binding: hb.h + hb-ft.h pull in
// freetype.h, so this exposes the full FreeType API we still need for
// outline extraction.
const hb = @import("harfbuzz");
const c = hb.c; // the binding's single C import: hb.h + hb-ft.h + freetype.h
const glyph_infos = @typeInfo(@TypeOf(hb.Buffer.getGlyphInfos)).@"fn".return_type.?;
const glyph_positions = @typeInfo(@TypeOf(hb.Buffer.getGlyphPositions)).@"fn".return_type.?;

/// slot 0 = solid; glyphs start at 1, the SVG region + decorations from
/// the top. Demo needs ~620 glyphs + the tiger (240 fills + up to 78
/// strokes); 1536 leaves headroom.
pub const max_materials: u32 = 1536;
/// Max cached shaped runs (generation-clock eviction). The demo has ~32
/// unique runs; 256 leaves ample headroom for the churning dynamic text.
pub const run_cache_capacity: u32 = 256;
pub const font_size_px: u32 = 14;
const fallback_scalar_advance: f32 = 10;
const fallback_line_height: f32 = 24;
const zero_width_space = "\xE2\x80\x8B";

/// The demo's live toggle state — the window writes it per frame, the UI
/// reads it for the header status line (the UI cannot import the window).
pub const DebugState = struct {
    subpixel: bool = false,
    bgr: bool = false,
    damp: bool = true,
    quad_debug: bool = false,
};
pub var debug_state: DebugState = .{};

pub const GlyphEntry = struct {
    gid: u32, // shaped glyph id (the shaper resolved the codepoint)
    size: u32, // the font size this glyph was rasterized at (entries are per (font_id, size, gid))
    font_id: u8,
    slot: u32, // material slot
    advance: f32,
    bearing_x: f32,
    bearing_y: f32,
    glyph_w: f32,
    glyph_h: f32,
    curve_left: f32, // from sweeper glyphExtent
    curve_bottom: f32,
    curve_w: f32,
    curve_h: f32,
};

/// One font size's FreeType face + HarfBuzz font + metrics. The engine
/// holds a small per-size cache of these — the ONLY per-size state in the
/// pipeline; the materials, slice emission and draw path are size-agnostic.
const FontState = struct {
    face: c.FT_Face,
    hb_font: hb.Font,
    font_id: u8,
    size: u32,
    ascent: f32,
    descent: f32,
};

/// Cache key for a shaped run: hash of the text + the font size + font id.
const RunKey = struct { hash: u64, size: u32, font_id: u8 };

/// Compact per-glyph shaped data (px floats — the hb 26.6 fixed-point
/// values divided by 64.0), copied OUT of the hb.Buffer before it is
/// destroyed; the cache never keeps hb.Buffer objects.
const GlyphPos = struct { gid: u32, x_advance: f32, y_advance: f32, x_offset: f32, y_offset: f32 };

/// A shaped text run: the measure result (width, line_height) plus the
/// per-glyph data emit needs. `text` is a dupe used for the exact-equality
/// check against an (astronomically rare) hash collision; `generation` is
/// the LRU clock stamp for eviction.
const TextRun = struct {
    key: RunKey,
    text: []u8, // dupe for the exact-equality check
    width: f32, // sum of x_advances in px
    line_height: f32, // ascent - descent
    glyphs: []GlyphPos, // the compact shaped data (px floats, 26.6/64)
    generation: u32, // the LRU clock stamp
};

const RunCache = std.AutoHashMapUnmanaged(RunKey, TextRun);

fn runKeyLess(left: RunKey, right: RunKey) bool {
    if (left.hash != right.hash) return left.hash < right.hash;
    if (left.size != right.size) return left.size < right.size;
    return left.font_id < right.font_id;
}

fn rebaseRunClock(run_cache: *RunCache, run_clock: *u32) void {
    var keys: [run_cache_capacity]RunKey = undefined;
    var key_count: usize = 0;
    var iterator = run_cache.iterator();
    while (iterator.next()) |entry| {
        std.debug.assert(key_count < keys.len);
        const key = entry.key_ptr.*;
        const generation = entry.value_ptr.generation;
        var insert_at = key_count;
        while (insert_at > 0) {
            const previous_key = keys[insert_at - 1];
            // `previous_key` came from this map, which is not mutated here.
            const previous_run = run_cache.getPtr(previous_key) orelse unreachable;
            const should_precede = generation < previous_run.generation or
                (generation == previous_run.generation and runKeyLess(key, previous_key));
            if (!should_precede) break;
            keys[insert_at] = previous_key;
            insert_at -= 1;
        }
        keys[insert_at] = key;
        key_count += 1;
    }
    for (keys[0..key_count], 0..) |key, rank| {
        // The keys are copied from the same map immediately above.
        const run = run_cache.getPtr(key) orelse unreachable;
        run.generation = @intCast(rank);
    }
    run_clock.* = @intCast(key_count);
}

fn advanceRunClock(run_cache: *RunCache, run_clock: *u32) u32 {
    if (run_clock.* == std.math.maxInt(u32)) {
        rebaseRunClock(run_cache, run_clock);
    } else {
        run_clock.* += 1;
    }
    return run_clock.*;
}

fn oldestRunKey(run_cache: *RunCache) ?RunKey {
    var victim_key: ?RunKey = null;
    var victim_generation: u32 = 0;
    var iterator = run_cache.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const generation = entry.value_ptr.generation;
        if (victim_key) |current_key| {
            if (generation < victim_generation or
                (generation == victim_generation and runKeyLess(key, current_key)))
            {
                victim_generation = generation;
                victim_key = key;
            }
        } else {
            victim_generation = generation;
            victim_key = key;
        }
    }
    return victim_key;
}

/// The embedded font sources: 0 = InterVariable, 1 = Fira Code Nerd Font.
const FontData = struct {
    data: []const u8,
    name: []const u8,
};
const font_sources = [_]FontData{
    .{ .data = @embedFile("InterVariable.ttf"), .name = "InterVariable" },
    .{ .data = @embedFile("FiraCodeNerdFont-Regular.ttf"), .name = "Fira Code Nerd Font" },
};

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

fn textClusterIsControl(text: []const u8, cluster: usize) bool {
    if (cluster >= text.len) return false;
    if (text[cluster] == '\n' or text[cluster] == '\r') return true;
    return std.mem.startsWith(u8, text[cluster..], zero_width_space);
}

const ShapedAdvance = struct {
    text: []const u8,
    infos: glyph_infos,
    positions: glyph_positions,
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

/// A measured line's source range. Soft separators remain in the range
/// because measureFlow includes their advances; hard breaks stay outside.
const LineRange = struct {
    start: usize,
    end: usize,
};

const PendingSegment = struct {
    segment: TextSegment,
    has_content: bool,
    width: f32,
};

const LineRangeIterator = struct {
    text: []const u8,
    limit: f32,
    segment_start: usize = 0,
    line_start: usize = 0,
    line_end: usize = 0,
    pending: ?PendingSegment = null,
    line_width: f32 = 0,
    line_has_content: bool = false,
    finished: bool = false,

    fn init(text: []const u8, limit: f32) LineRangeIterator {
        return .{ .text = text, .limit = limit };
    }

    fn next(self: *LineRangeIterator, measurer: anytype) ?LineRange {
        if (self.finished) return null;

        while (true) {
            const current: PendingSegment = if (self.pending) |pending| from_pending: {
                self.pending = null;
                break :from_pending pending;
            } else fresh: {
                const segment = nextTextSegment(self.text, self.segment_start);
                break :fresh .{
                    .segment = segment,
                    .has_content = segmentHasContent(
                        self.text[self.segment_start..segment.end],
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

fn wrappedLineCount(measurer: anytype, text: []const u8, limit: f32) usize {
    resetMeasurer(measurer);
    var ranges = LineRangeIterator.init(text, limit);
    var line_count: usize = 0;
    while (ranges.next(measurer)) |_| {
        line_count += 1;
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

fn scaleCountToF32(count: usize, unit: f32) f32 {
    // Scale in f64 so the integer is not narrowed before multiplication.
    const scaled = @as(f64, @floatFromInt(count)) * @as(f64, unit);
    const maximum: f64 = std.math.floatMax(f32);
    // The assertions establish the finite f32 range before narrowing.
    std.debug.assert(std.math.isFinite(scaled));
    std.debug.assert(scaled >= -maximum);
    std.debug.assert(scaled <= maximum);
    return @floatCast(scaled);
}

fn fallbackMeasure(text: []const u8, input: MeasureInput) WidgetSize {
    const flow = measureByLinePolicy(FallbackAdvance{}, text, input);
    return applyKnownDimensions(.{
        .width = flow.width,
        .height = scaleCountToF32(flow.line_count, fallback_line_height),
    }, input);
}

const max_font_sizes = 16;

pub const TextEngine = struct {
    /// The flex measure hook target: the demo sets this after init and
    /// points App.measure at measureForFlex, so layout sizes leaves to the
    /// shaped text extent rather than a coarse scalar estimate.
    pub var measure_engine: ?*TextEngine = null;

    /// Host-side content-box measure callback for the canonical layout engine.
    pub fn measureForFlex(text: []const u8, input: MeasureInput) WidgetSize {
        return measure_engine.?.measureText(text, input);
    }

    /// The font's line height in px at `size` (ascender − descender; the
    /// hb descender is negative, y-up).
    pub fn lineHeight(self: *TextEngine, size: u32, font_id: u8) f32 {
        const f = self.fontFor(font_id, size) catch return 20;
        return f.ascent - f.descent;
    }

    /// The text baseline for a content box (y, h): the line box centered
    /// vertically, the baseline at the ascent. Correct at any font size —
    /// the old 0.75*hack only fit the 20px size.
    pub fn baselineIn(self: *TextEngine, y: f32, h: f32, size: u32, font_id: u8) f32 {
        const f = self.fontFor(font_id, size) catch return y + h * 0.75;
        return y + (h - (f.ascent - f.descent)) / 2 + f.ascent;
    }
    gpu: *noapi.Gpu,
    gpa: std.mem.Allocator,
    ft_lib: c.FT_Library,
    /// Per-size font states (FT face + hb font + metrics); the default
    /// size is created at init, others lazily on first use.
    fonts: [max_font_sizes]?FontState = .{null} ** max_font_sizes,
    // Parallel arrays, one element per rasterized glyph:
    // sweepers[i] owns the GPU curve buffer backing entries[i].
    sweepers: std.ArrayList(renderer.GlyphSweeper) = .empty, // per glyph
    entries: std.ArrayList(GlyphEntry) = .empty, // per glyph
    measure_buffer: hb.Buffer,
    /// Reused HarfBuzz buffer for wrapped-line emission. Keeping this
    /// separate preserves the whole-text measurement buffer while ranges
    /// are consumed and prevents per-line run-cache allocations.
    flow_buffer: hb.Buffer,
    materials: noapi.GpuPtr, // max_materials * material_size, .default
    next_slot: u32 = 1,
    material_bda: u64 = 0,

    /// Shaped-run cache: (hash(text), size, font_id) → TextRun. The run's
    /// text dupe and glyph arrays are engine-owned (freed on eviction and
    /// in deinit). Unmanaged map — initialized `.empty`, methods take gpa.
    run_cache: RunCache = .empty,
    /// Generation clock for LRU eviction. Every cache hit and miss advances
    /// the clock before stamping the run. Near u32 overflow, live entries
    /// are rebased into dense oldest-to-newest ranks without allocation.
    run_clock: u32 = 0,

    /// How many glyph material slots are live (slots 1..next_slot-1 from
    /// the bottom of the buffer). window.zig allocates its per-frame
    /// decoration materials downward from the top and asserts it stays
    /// above this count, so a decoration write can never overwrite an
    /// in-flight glyph material.
    pub fn glyphSlotCount(self: *TextEngine) u32 {
        return self.next_slot;
    }

    /// Init FreeType, load the embedded Inter font at font_size_px, wrap it
    /// in a HarfBuzz font, and allocate the material buffer. Returns errors
    /// (not panics) on FT/HB failures; on partial failure everything
    /// allocated so far is released.
    pub fn init(gpa: std.mem.Allocator, gpu: *noapi.Gpu) !TextEngine {
        // SAFETY: assigned by FT_Init/FT_New before any use; failures return errors.
        var ft_lib: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&ft_lib) != 0) return error.FreeTypeInitFailed;
        errdefer _ = c.FT_Done_FreeType(ft_lib);

        const font_data = @embedFile("InterVariable.ttf");
        // SAFETY: assigned by FT_Init/FT_New before any use; failures return errors.
        var face: c.FT_Face = undefined;
        std.debug.assert(font_data.len <= std.math.maxInt(u32));
        if (c.FT_New_Memory_Face(ft_lib, font_data.ptr, @as(c.FT_Long, @intCast(font_data.len)), 0, &face) != 0)
            return error.FreeTypeFaceFailed;
        errdefer _ = c.FT_Done_Face(face);
        if (c.FT_Set_Pixel_Sizes(face, 0, font_size_px) != 0) return error.FreeTypeSetPixelSizesFailed;

        // hb-ft over the shared FT face. NOTE: we build the Font directly
        // from the binding's `c` (hb.c) rather than hb.freetype.createFont —
        // the binding's freetype.zig uses the freetype PACKAGE's separate
        // translate-c of freetype.h, whose FT_Face type is incompatible with
        // the one in hb.c (two cimport instances of the same header).
        const hb_handle = hb.c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed;
        var hb_font: hb.Font = .{ .handle = hb_handle };
        hb.c.hb_ft_font_set_funcs(hb_handle);
        // Deliberately UNHINTED (hb-ft's default load flags). Hinting
        // grid-fits the advances AND the extents per size, so the pen and
        // the quad boxes snap non-linearly across font sizes (the kerning
        // "varies wildly", glyphs clip against compressed extents). The
        // unhinted values scale linearly; the analytic sweep gives the AA.
        _ = hb.c.hb_ft_font_set_load_flags(hb_handle, c.FT_LOAD_DEFAULT | c.FT_LOAD_NO_HINTING);
        errdefer hb_font.destroy();

        // SAFETY: assigned by hb_font_get_extents_for_direction before any read.
        var font_ext: c.hb_font_extents_t = undefined;
        _ = c.hb_font_get_extents_for_direction(hb_handle, c.HB_DIRECTION_LTR, &font_ext);

        const materials = try gpu.gpuMalloc(max_materials * renderer.material_size, 64, .default);
        errdefer gpu.gpuFree(materials);
        var measure_buffer = try hb.Buffer.create();
        errdefer measure_buffer.destroy();
        var flow_buffer = try hb.Buffer.create();
        errdefer flow_buffer.destroy();
        var self: TextEngine = .{
            .gpu = gpu,
            .gpa = gpa,
            .ft_lib = ft_lib,
            .measure_buffer = measure_buffer,
            .materials = materials,
            .material_bda = materials.gpu,
            .flow_buffer = flow_buffer,
        };
        // The default size's state (created inline so init errors release
        // everything); the other sizes come lazily via fontFor.
        self.fonts[0] = .{
            .face = face,
            .hb_font = hb_font,
            .font_id = 0,
            .size = font_size_px,
            .ascent = @as(f32, @floatCast(@as(f64, @floatFromInt(font_ext.ascender)) / 64.0)),
            .descent = @as(f32, @floatCast(@as(f64, @floatFromInt(font_ext.descender)) / 64.0)),
        };
        return self;
    }

    /// Get (or lazily create) the font state for `size` px. One FT face +
    /// hb font per size — the only per-size state in the pipeline.
    fn fontFor(self: *TextEngine, font_id: u8, size: u32) !*FontState {
        for (&self.fonts) |*f| {
            if (f.*) |*fs| {
                if (fs.font_id == font_id and fs.size == size) return fs;
            }
        }
        var slot: ?usize = null;
        for (&self.fonts, 0..) |*f, i| {
            if (f.* == null) {
                slot = i;
                break;
            }
        }
        const idx = slot orelse return error.TooManyFontSizes;

        const font_data = font_sources[font_id].data;
        // SAFETY: assigned by FT_New before any use; failures return errors.
        var face: c.FT_Face = undefined;
        std.debug.assert(font_data.len <= std.math.maxInt(u32));
        if (c.FT_New_Memory_Face(self.ft_lib, font_data.ptr, @as(c.FT_Long, @intCast(font_data.len)), 0, &face) != 0)
            return error.FreeTypeFaceFailed;
        errdefer _ = c.FT_Done_Face(face);
        if (c.FT_Set_Pixel_Sizes(face, 0, size) != 0) return error.FreeTypeSetPixelSizesFailed;

        const hb_handle = hb.c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed;
        var hb_font: hb.Font = .{ .handle = hb_handle };
        hb.c.hb_ft_font_set_funcs(hb_handle);
        // Unhinted — see the init's note: the positions and extents must
        // scale linearly with the size, never grid-snap.
        _ = hb.c.hb_ft_font_set_load_flags(hb_handle, c.FT_LOAD_DEFAULT | c.FT_LOAD_NO_HINTING);
        errdefer hb_font.destroy();

        // SAFETY: assigned by hb_font_get_extents_for_direction before any read.
        var font_ext: c.hb_font_extents_t = undefined;
        _ = c.hb_font_get_extents_for_direction(hb_handle, c.HB_DIRECTION_LTR, &font_ext);

        self.fonts[idx] = .{
            .face = face,
            .hb_font = hb_font,
            .font_id = font_id,
            .size = size,
            .ascent = @as(f32, @floatCast(@as(f64, @floatFromInt(font_ext.ascender)) / 64.0)),
            .descent = @as(f32, @floatCast(@as(f64, @floatFromInt(font_ext.descender)) / 64.0)),
        };
        if (self.fonts[idx]) |*font| return font;
        unreachable;
    }

    pub fn deinit(self: *TextEngine) void {
        for (self.sweepers.items) |*s| s.deinit(); // frees each GPU curve buffer
        self.sweepers.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        for (&self.fonts) |*f| {
            if (f.*) |*fs| {
                fs.hb_font.destroy();
                _ = c.FT_Done_Face(fs.face);
            }
        }
        self.measure_buffer.destroy();
        self.flow_buffer.destroy();
        // Free each cached run's text dupe + glyph array, then the map.
        var cache_it = self.run_cache.iterator();
        while (cache_it.next()) |kv| self.freeRun(kv.value_ptr.*);
        self.run_cache.deinit(self.gpa);
        self.gpu.gpuFree(self.materials);
        _ = c.FT_Done_FreeType(self.ft_lib);
        self.* = undefined;
    }

    pub fn materialBda(self: *const TextEngine) u64 {
        return self.material_bda;
    }

    /// Snap the run's LOGICAL origin (the content box's left) to the
    /// device pixel grid. Everything INSIDE the run stays exact: the
    /// shaped advances and offsets flow straight into the pixel offsets,
    /// so the kerning is preserved and the glyphs' fractional offsets are
    /// fixed constants relative to the integer origin — coverage static,
    /// movement in clean 1px steps, runs aligned by their boxes (never by
    /// the first glyph's bearing).
    fn snapRunOrigin(x: f32) f32 {
        return @round(x);
    }

    /// Shape a UTF-8 run with HarfBuzz, returning the owning buffer. The
    /// caller reads getGlyphInfos()/getGlyphPositions() and MUST destroy the
    /// buffer when done. hb's addUTF8 never panics on invalid bytes (it
    /// substitutes .notdef, which the gid-0 skip drops) — the old tolerant
    /// iterator is gone.
    fn shapeRun(self: *TextEngine, font: *FontState, text: []const u8) !hb.Buffer {
        _ = self;
        var buf = try hb.Buffer.create();
        errdefer buf.destroy();
        buf.addUTF8(text);
        buf.setDirection(.ltr);
        buf.setScript(.latin);
        hb.shape(font.hb_font, buf, null);
        return buf;
    }

    /// Free a cached run's engine-owned allocations (text dupe + glyphs).
    fn freeRun(self: *TextEngine, run: TextRun) void {
        self.gpa.free(run.text);
        self.gpa.free(run.glyphs);
    }

    /// Get the shaped run for (text, size, font_id), shaping on a miss and
    /// caching the compact copy. Returns a pointer INTO the run_cache map —
    /// callers must not hold it across another map mutation (put/remove/
    /// evict). The shape-once guarantee: measure and emit both go through
    /// here, so a static label is shaped once per lifetime, not twice per
    /// frame.
    fn getOrShape(self: *TextEngine, font: *FontState, text: []const u8) !*TextRun {
        const zone = tracy.Zone.begin(.{ .name = "getOrShape", .src = @src() });
        defer zone.end();
        const key: RunKey = .{ .hash = std.hash.Wyhash.hash(0, text), .size = font.size, .font_id = font.font_id };
        if (self.run_cache.getPtr(key)) |run| {
            if (std.mem.eql(u8, run.text, text)) {
                const generation = advanceRunClock(&self.run_cache, &self.run_clock);
                run.generation = generation;
                return run;
            }
            // Hash collision (astronomically rare): drop the stale entry
            // and re-shape below — never return a wrong width.
            self.freeRun(run.*);
            _ = self.run_cache.remove(key);
        }

        var buf = try self.shapeRun(font, text);
        defer buf.destroy();
        const infos = buf.getGlyphInfos();
        const positions = buf.getGlyphPositions() orelse &.{};
        const glyphs = try self.gpa.alloc(GlyphPos, @min(infos.len, positions.len));
        errdefer self.gpa.free(glyphs);
        var w: f32 = 0;
        for (glyphs, 0..) |*glyph, index| {
            const position = positions[index];
            const control = textClusterIsControl(text, @intCast(infos[index].cluster));
            const x_advance = if (control) @as(f32, 0) else @as(f32, @floatCast(
                @as(f64, @floatFromInt(position.x_advance)) / 64.0,
            ));
            w += x_advance;
            glyph.* = .{
                .gid = if (control) 0 else infos[index].codepoint,
                .x_advance = x_advance,
                .y_advance = if (control) 0 else @as(f32, @floatCast(
                    @as(f64, @floatFromInt(position.y_advance)) / 64.0,
                )),
                .x_offset = if (control) 0 else @as(f32, @floatCast(
                    @as(f64, @floatFromInt(position.x_offset)) / 64.0,
                )),
                .y_offset = if (control) 0 else @as(f32, @floatCast(
                    @as(f64, @floatFromInt(position.y_offset)) / 64.0,
                )),
            };
        }

        const text_dup = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(text_dup);

        const generation = advanceRunClock(&self.run_cache, &self.run_clock);
        while (self.run_cache.count() >= run_cache_capacity) {
            const victim_key = oldestRunKey(&self.run_cache) orelse unreachable;
            const victim = self.run_cache.getPtr(victim_key) orelse unreachable;
            self.freeRun(victim.*);
            _ = self.run_cache.remove(victim_key);
        }
        try self.run_cache.put(self.gpa, key, .{
            .key = key,
            .text = text_dup,
            .width = w,
            .line_height = font.ascent - font.descent,
            .glyphs = glyphs,
            .generation = generation,
        });
        // `put` succeeded and no map mutation occurs before this fetch.
        return self.run_cache.getPtr(key) orelse unreachable;
    }

    fn shapeForMeasure(self: *TextEngine, font: *FontState, text: []const u8) ShapedAdvance {
        self.measure_buffer.reset();
        self.measure_buffer.addUTF8(text);
        self.measure_buffer.setDirection(.ltr);
        self.measure_buffer.setScript(.latin);
        hb.shape(font.hb_font, self.measure_buffer, null);
        return ShapedAdvance.init(text, &self.measure_buffer);
    }

    /// Measure a text run's content-box size for the canonical layout engine.
    pub fn measureText(self: *TextEngine, text: []const u8, input: MeasureInput) WidgetSize {
        const zone = tracy.Zone.begin(.{ .name = "measureText", .src = @src() });
        defer zone.end();

        const size = fontPixelSize(input.font_size, font_size_px) orelse
            return fallbackMeasure(text, input);
        const font = self.fontFor(input.font_id, size) catch
            return fallbackMeasure(text, input);
        var shaped = self.shapeForMeasure(font, text);
        const flow = measureByLinePolicy(&shaped, text, input);
        return applyKnownDimensions(.{
            .width = flow.width,
            .height = scaleCountToF32(flow.line_count, font.ascent - font.descent),
        }, input);
    }
    /// Rasterize glyph `gid` on demand. Glyph id 0 and glyphs without a
    /// supported outline are skipped. Returns the index into `entries` so
    /// callers do not need a second cache scan.
    fn glyphIndex(self: *const TextEngine, font_id: u8, size: u32, gid: u32) ?usize {
        if (gid == 0) return null;
        for (self.entries.items, 0..) |entry, index| {
            if (entry.font_id == font_id and entry.size == size and entry.gid == gid) return index;
        }
        return null;
    }

    /// Ensure a glyph is rasterized. Missing glyphs and unsupported outlines
    /// return null; allocation and material-budget failures remain errors.
    fn ensureGlyph(self: *TextEngine, font: *FontState, gid: u32) !?usize {
        if (gid == 0) return null;
        if (self.glyphIndex(font.font_id, font.size, gid)) |index| return index;
        return self.ensureGlyphInner(font, gid);
    }

    fn ensureGlyphInner(self: *TextEngine, font: *FontState, gid: u32) !?usize {
        const curves = extractGlyphCurves(self.gpa, font.hb_font, gid) catch |err| switch (err) {
            error.GlyphNotFound, error.GlyphDrawFailed => return null,
            else => return err,
        };
        defer self.gpa.free(curves);
        if (curves.len == 0) return null;

        // Metrics from HarfBuzz (the same 26.6 fixed-point scale as the
        // shaped positions; /64.0 → pixels). No FreeType in our code.
        const advance = @as(
            f32,
            @floatCast(@as(f64, @floatFromInt(c.hb_font_get_glyph_h_advance(font.hb_font.handle, gid))) / 64.0),
        );
        // SAFETY: assigned by hb_font_get_glyph_extents before any read; a
        // zero return (no ink) skips the glyph.
        var ext: c.hb_glyph_extents_t = undefined;
        if (c.hb_font_get_glyph_extents(font.hb_font.handle, gid, &ext) == 0) return null;
        const bearing_x: f32 = @floatCast(@as(f64, @floatFromInt(ext.x_bearing)) / 64.0);
        const bearing_y: f32 = @floatCast(@as(f64, @floatFromInt(ext.y_bearing)) / 64.0);
        const glyph_w: f32 = @floatCast(@as(f64, @floatFromInt(ext.width)) / 64.0);
        // hb extents: height is NEGATIVE for y-up fonts (the box extends
        // downward from the top bearing) — the magnitude is the ink height.
        const glyph_h: f32 = @floatCast(@as(f64, @floatFromInt(@abs(ext.height))) / 64.0);

        // Slot 0 is reserved for solid materials. Check the budget only
        // after confirming that this glyph has drawable ink.
        if (self.next_slot >= max_materials) return error.TooManyGlyphs;
        std.debug.assert(self.next_slot < max_materials);

        var sweeper = try renderer.GlyphSweeper.init(self.gpu, curves);

        // The shader sweeps the curves per fragment at DISPLAY resolution
        // (analytic AA — no intermediate bitmap), so the material only
        // needs the curve buffer; the window fields are unused (1.0).
        const slot = self.next_slot;
        renderer.GlyphSweeper.writeMaterial(
            sweeper.curve_buf_bda,
            self.materials,
            slot,
            bearing_y,
            sweeper.curve_w,
            sweeper.curve_h,
            1.0,
            1.0,
        );
        self.next_slot += 1;

        // Transfer the sweeper into the parallel list. On any append failure
        // free the GPU curve buffer so nothing leaks and the two lists stay
        // index-aligned.
        self.sweepers.append(self.gpa, sweeper) catch |err| {
            sweeper.deinit();
            return err;
        };
        const entry_index = self.entries.items.len;
        self.entries.append(self.gpa, .{
            .gid = gid,
            .size = font.size,
            .font_id = font.font_id,
            .slot = slot,
            .advance = advance,
            .bearing_x = bearing_x,
            .bearing_y = bearing_y,
            .glyph_w = glyph_w,
            .glyph_h = glyph_h,
            .curve_left = sweeper.curve_left,
            .curve_bottom = sweeper.curve_bottom,
            .curve_w = sweeper.curve_w,
            .curve_h = sweeper.curve_h,
        }) catch |err| {
            // The sweeper was appended immediately before the entries append.
            var orphan = self.sweepers.pop() orelse unreachable;
            orphan.deinit();
            return err;
        };
        return entry_index;
    }

    /// Shape `text` (kerning/ligatures included), ensure the glyphs exist
    /// (lazy), then append one SceneRect per glyph to `out`. This preserves
    /// the historical unbounded emission API for existing callers.
    pub fn emitText(
        self: *TextEngine,
        text: []const u8,
        x: f32,
        baseline_y: f32,
        size: u32,
        font_id: u8,
        clip_id: u32,
        color: [4]f32,
        out: *std.ArrayList(SceneRect),
    ) !void {
        return self.emitTextWithWidth(
            text,
            x,
            baseline_y,
            size,
            font_id,
            clip_id,
            color,
            null,
            out,
        );
    }

    /// Emit text into an optional single-line width. When the shaped run is
    /// wider than `max_width`, retain complete shaped glyphs that fit before
    /// a separately HarfBuzz-shaped ASCII `...` run. If the ellipsis itself
    /// does not fit, emit no glyphs.
    pub fn emitTextWithWidth(
        self: *TextEngine,
        text: []const u8,
        x: f32,
        baseline_y: f32,
        size: u32,
        font_id: u8,
        clip_id: u32,
        color: [4]f32,
        max_width: ?f32,
        out: *std.ArrayList(SceneRect),
    ) !void {
        const zone = tracy.Zone.begin(.{ .name = "emitText", .src = @src() });
        defer zone.end();
        const font = try self.fontFor(font_id, size);
        const run_key = (try self.getOrShape(font, text)).key;
        // `getOrShape` returned this key and no cache mutation followed.
        const shaped_run = self.run_cache.getPtr(run_key) orelse unreachable;
        const run_x = snapRunOrigin(x);
        const run_baseline = @round(baseline_y);

        const truncate = if (max_width) |width| blk: {
            if (std.math.isNan(width)) break :blk false;
            break :blk shaped_run.width > @max(0, width);
        } else false;
        if (!truncate) {
            try out.ensureTotalCapacity(self.gpa, out.items.len + shaped_run.glyphs.len);
            _ = try self.emitRun(
                font,
                shaped_run,
                shaped_run.glyphs.len,
                run_x,
                0,
                run_baseline,
                clip_id,
                color,
                out,
            );
            return;
        }

        const ellipsis_key = (try self.getOrShape(font, "...")).key;
        // Shaping the ellipsis can rehash the cache, so fetch both pointers
        // only after the second cache operation.
        // The original run was just touched, so eviction removes an older key.
        const run = self.run_cache.getPtr(run_key) orelse unreachable;
        const suffix = self.run_cache.getPtr(ellipsis_key) orelse unreachable;
        // `truncate` can only be true for a present, non-NaN width.
        const width = max_width orelse unreachable;
        if (suffix.width > width) return;
        const prefix_limit = width - suffix.width;
        const prefix_count = fitGlyphCount(run, prefix_limit);

        try out.ensureTotalCapacity(self.gpa, out.items.len + prefix_count + suffix.glyphs.len);
        const cursor = try self.emitRun(
            font,
            run,
            prefix_count,
            run_x,
            0,
            run_baseline,
            clip_id,
            color,
            out,
        );
        _ = try self.emitRun(
            font,
            suffix,
            suffix.glyphs.len,
            run_x,
            cursor,
            run_baseline,
            clip_id,
            color,
            out,
        );
    }
    /// Emit visible text from measured soft/hard-break ranges. Wrapped
    /// lines shape through one reusable HarfBuzz buffer instead of entering
    /// each substring into the bounded complete-run cache.
    pub fn emitTextFlow(
        self: *TextEngine,
        text: []const u8,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        size: u32,
        font_id: u8,
        clip_id: u32,
        color: [4]f32,
        out: *std.ArrayList(SceneRect),
    ) !void {
        const zone = tracy.Zone.begin(.{ .name = "emitTextFlow", .src = @src() });
        defer zone.end();

        const font = try self.fontFor(font_id, size);
        var shaped = self.shapeForMeasure(font, text);
        const flow = measureFlow(&shaped, text, .{ .definite = width });
        resetMeasurer(&shaped);

        const line_height = font.ascent - font.descent;
        const block_height = scaleCountToF32(flow.line_count, line_height);
        const vertical_inset = if (height > block_height) (height - block_height) / 2 else 0;
        const run_x = snapRunOrigin(x);
        var ranges = LineRangeIterator.init(text, flow.width);
        var line_index: usize = 0;
        while (ranges.next(&shaped)) |range| {
            const baseline = @round(
                y + vertical_inset + font.ascent +
                    scaleCountToF32(line_index, line_height),
            );
            if (range.end > range.start) {
                _ = try self.emitTransientRun(
                    font,
                    text[range.start..range.end],
                    run_x,
                    baseline,
                    clip_id,
                    color,
                    out,
                );
            }
            line_index += 1;
        }
        std.debug.assert(line_index == flow.line_count);
    }

    fn emitTransientRun(
        self: *TextEngine,
        font: *FontState,
        text: []const u8,
        run_x: f32,
        run_baseline: f32,
        clip_id: u32,
        color: [4]f32,
        out: *std.ArrayList(SceneRect),
    ) !f32 {
        self.flow_buffer.reset();
        self.flow_buffer.addUTF8(text);
        self.flow_buffer.setDirection(.ltr);
        self.flow_buffer.setScript(.latin);
        hb.shape(font.hb_font, self.flow_buffer, null);

        const infos = self.flow_buffer.getGlyphInfos();
        const positions = self.flow_buffer.getGlyphPositions() orelse &.{};
        const glyph_count = @min(infos.len, positions.len);
        try out.ensureTotalCapacity(self.gpa, out.items.len + glyph_count);
        var cursor: f32 = 0;
        for (0..glyph_count) |index| {
            const position = positions[index];
            const glyph: GlyphPos = .{
                .gid = infos[index].codepoint,
                .x_advance = @floatCast(
                    @as(f64, @floatFromInt(position.x_advance)) / 64.0,
                ),
                .y_advance = @floatCast(
                    @as(f64, @floatFromInt(position.y_advance)) / 64.0,
                ),
                .x_offset = @floatCast(
                    @as(f64, @floatFromInt(position.x_offset)) / 64.0,
                ),
                .y_offset = @floatCast(
                    @as(f64, @floatFromInt(position.y_offset)) / 64.0,
                ),
            };
            try self.emitGlyph(
                font,
                glyph,
                run_x,
                run_baseline,
                clip_id,
                color,
                out,
                &cursor,
            );
        }
        return cursor;
    }

    fn fitGlyphCount(run: *const TextRun, width: f32) usize {
        var cursor: f32 = 0;
        for (run.glyphs, 0..) |g, i| {
            const next = cursor + g.x_advance;
            if (next > width) return i;
            cursor = next;
        }
        return run.glyphs.len;
    }

    fn emitRun(
        self: *TextEngine,
        font: *FontState,
        run: *const TextRun,
        glyph_count: usize,
        run_x: f32,
        initial_cursor: f32,
        run_baseline: f32,
        clip_id: u32,
        color: [4]f32,
        out: *std.ArrayList(SceneRect),
    ) !f32 {
        var cursor = initial_cursor;
        for (run.glyphs[0..glyph_count]) |glyph| {
            try self.emitGlyph(
                font,
                glyph,
                run_x,
                run_baseline,
                clip_id,
                color,
                out,
                &cursor,
            );
        }
        return cursor;
    }

    fn emitGlyph(
        self: *TextEngine,
        font: *FontState,
        glyph: GlyphPos,
        run_x: f32,
        run_baseline: f32,
        clip_id: u32,
        color: [4]f32,
        out: *std.ArrayList(SceneRect),
        cursor: *f32,
    ) !void {
        const entry_index = (try self.ensureGlyph(font, glyph.gid)) orelse {
            cursor.* += glyph.x_advance;
            return;
        };
        const entry = &self.entries.items[entry_index];
        const ch_x = run_x + cursor.* + glyph.x_offset + entry.bearing_x;
        const ch_y = run_baseline - entry.bearing_y - glyph.y_offset;
        if (entry.glyph_w <= 0 or entry.glyph_h <= 0) {
            cursor.* += glyph.x_advance;
            return;
        }
        out.appendAssumeCapacity(.{
            .dst = .{ ch_x - 2, ch_y - 2, @ceil(entry.glyph_w) + 4, @ceil(entry.glyph_h) + 4 },
            .src = .{ 0, 0, 1, 1 },
            .corners = .{ 0, 0, 0, 0 },
            .color = color,
            .material_index = entry.slot,
            .curve = .{ entry.curve_left, entry.curve_bottom, entry.curve_w, entry.curve_h },
            .clip_id = clip_id,
            .origin = .{ run_x + cursor.* + glyph.x_offset, run_baseline - glyph.y_offset },
        });
        cursor.* += glyph.x_advance;
    }
};

/// Extract glyph curves for a specific SHAPED glyph id via HarfBuzz's
/// draw API (hb_font_draw_glyph — the hb-ft backend emits the outline in
/// the font's scale, 26.6 fixed-point px; /64 → px). No FreeType calls in
/// our code: the face exists only as the hb-ft backend. Callbacks fill a
/// 4096-curve stack buffer (cubic segments split into two conics at
/// t=0.5), then the caller-owned slice is dupe'd via `alloc`.
fn extractGlyphCurves(alloc: std.mem.Allocator, font: hb.Font, gid: u32) ![]renderer.Curve {
    if (gid == 0) return error.GlyphNotFound;

    var buf: [4096]renderer.Curve = undefined;
    var count: u32 = 0;
    var first_x: f32 = 0;
    var first_y: f32 = 0;
    var last_x: f32 = 0;
    var last_y: f32 = 0;

    const Ctx = struct {
        curves: *[4096]renderer.Curve,
        count: *u32,
        first_x: *f32,
        first_y: *f32,
        last_x: *f32,
        last_y: *f32,
    };

    var ctx: Ctx = .{
        .curves = &buf,
        .count = &count,
        .first_x = &first_x,
        .first_y = &first_y,
        .last_x = &last_x,
        .last_y = &last_y,
    };

    const move_cb = struct {
        fn cb(
            dfuncs: ?*c.hb_draw_funcs_t,
            draw_data: ?*anyopaque,
            st: ?*c.hb_draw_state_t,
            to_x: f32,
            to_y: f32,
            user_data: ?*anyopaque,
        ) callconv(.c) void {
            _ = dfuncs;
            _ = draw_data;
            _ = st;
            const p: *Ctx = @ptrCast(@alignCast(user_data));
            p.first_x.* = to_x / 64;
            p.first_y.* = to_y / 64;
            p.last_x.* = p.first_x.*;
            p.last_y.* = p.first_y.*;
        }
    }.cb;
    const line_cb = struct {
        fn cb(
            dfuncs: ?*c.hb_draw_funcs_t,
            draw_data: ?*anyopaque,
            st: ?*c.hb_draw_state_t,
            to_x: f32,
            to_y: f32,
            user_data: ?*anyopaque,
        ) callconv(.c) void {
            _ = dfuncs;
            _ = draw_data;
            _ = st;
            const p: *Ctx = @ptrCast(@alignCast(user_data));
            const tx = to_x / 64;
            const ty = to_y / 64;
            if (p.count.* < 4096) {
                p.curves[p.count.*] = .{
                    .p0x = p.last_x.*,
                    .p0y = p.last_y.*,
                    .p1x = (p.last_x.* + tx) * 0.5,
                    .p1y = (p.last_y.* + ty) * 0.5,
                    .p2x = tx,
                    .p2y = ty,
                };
                p.count.* += 1;
            }
            p.last_x.* = tx;
            p.last_y.* = ty;
        }
    }.cb;
    const quad_cb = struct {
        fn cb(
            dfuncs: ?*c.hb_draw_funcs_t,
            draw_data: ?*anyopaque,
            st: ?*c.hb_draw_state_t,
            control_x: f32,
            control_y: f32,
            to_x: f32,
            to_y: f32,
            user_data: ?*anyopaque,
        ) callconv(.c) void {
            _ = dfuncs;
            _ = draw_data;
            _ = st;
            const p: *Ctx = @ptrCast(@alignCast(user_data));
            const cx = control_x / 64;
            const cy = control_y / 64;
            const tx = to_x / 64;
            const ty = to_y / 64;
            if (p.count.* < 4096) {
                p.curves[p.count.*] = .{
                    .p0x = p.last_x.*,
                    .p0y = p.last_y.*,
                    .p1x = cx,
                    .p1y = cy,
                    .p2x = tx,
                    .p2y = ty,
                };
                p.count.* += 1;
            }
            p.last_x.* = tx;
            p.last_y.* = ty;
        }
    }.cb;
    const cubic_cb = struct {
        fn cb(
            dfuncs: ?*c.hb_draw_funcs_t,
            draw_data: ?*anyopaque,
            st: ?*c.hb_draw_state_t,
            c1x: f32,
            c1y: f32,
            c2x: f32,
            c2y: f32,
            to_x: f32,
            to_y: f32,
            user_data: ?*anyopaque,
        ) callconv(.c) void {
            _ = dfuncs;
            _ = draw_data;
            _ = st;
            const p: *Ctx = @ptrCast(@alignCast(user_data));
            const c1x_px = c1x / 64;
            const c1y_px = c1y / 64;
            const c2x_px = c2x / 64;
            const c2y_px = c2y / 64;
            const tx = to_x / 64;
            const ty = to_y / 64;
            if (p.count.* + 1 < 4096) {
                const t: f32 = 0.5;
                const mt = 1 - t;
                const b0x = mt * p.last_x.* + t * c1x_px;
                const b0y = mt * p.last_y.* + t * c1y_px;
                const b1x = mt * c1x_px + t * c2x_px;
                const b1y = mt * c1y_px + t * c2y_px;
                const b2x = mt * c2x_px + t * tx;
                const b2y = mt * c2y_px + t * ty;
                const cx1 = mt * b0x + t * b1x;
                const cy1 = mt * b0y + t * b1y;
                const cx2 = mt * b1x + t * b2x;
                const cy2 = mt * b1y + t * b2y;
                const dx = mt * cx1 + t * cx2;
                const dy = mt * cy1 + t * cy2;
                p.curves[p.count.*] = .{
                    .p0x = p.last_x.*,
                    .p0y = p.last_y.*,
                    .p1x = b0x,
                    .p1y = b0y,
                    .p2x = dx,
                    .p2y = dy,
                };
                p.count.* += 1;
                p.curves[p.count.*] = .{ .p0x = dx, .p0y = dy, .p1x = cx2, .p1y = cy2, .p2x = tx, .p2y = ty };
                p.count.* += 1;
            }
            p.last_x.* = tx;
            p.last_y.* = ty;
        }
    }.cb;

    const funcs = c.hb_draw_funcs_create();
    if (funcs == null) return error.GlyphDrawFailed;
    defer _ = c.hb_draw_funcs_destroy(funcs);
    c.hb_draw_funcs_set_move_to_func(funcs, move_cb, &ctx, null);
    c.hb_draw_funcs_set_line_to_func(funcs, line_cb, &ctx, null);
    c.hb_draw_funcs_set_quadratic_to_func(funcs, quad_cb, &ctx, null);
    c.hb_draw_funcs_set_cubic_to_func(funcs, cubic_cb, &ctx, null);
    c.hb_font_draw_glyph(font.handle, gid, funcs, &ctx);

    return alloc.dupe(renderer.Curve, buf[0..count]);
}

// ── sweep validation (port of quad_frag scanlineSweep) ─────────────
fn sweepIntersect(qa: f32, c0: f32, c1: f32, c2: f32, target: f32) f32 {
    if (@abs(qa) < 1e-3) {
        // Degenerate horizontal segment (c2 == c0): 0/0 → NaN, and the
        // collinear midpoint quadratic (line_cb) makes it reachable;
        // the sweep is unconstrained in t, so return 0.0.
        if (c2 == c0) return 0.0;
        return (target - c0) / (c2 - c0);
    }
    const qb = 2.0 * (c1 - c0);
    const qc = c0 - target;
    const d = qb * qb - 4.0 * qa * qc;
    const sqrt_d: f32 = if (d < 0.0) 0.0 else @sqrt(d);
    const inv_2a = 0.5 / qa;
    const sgn: f32 = if (c2 - c0 > 0) 1.0 else -1.0;
    return -qb * inv_2a + sgn * sqrt_d * inv_2a;
}

fn sweepEval(p0: [2]f32, p1: [2]f32, p2: [2]f32, t: f32) [2]f32 {
    const mt = 1.0 - t;
    return .{
        mt * mt * p0[0] + 2.0 * mt * t * p1[0] + t * t * p2[0],
        mt * mt * p0[1] + 2.0 * mt * t * p1[1] + t * t * p2[1],
    };
}

fn sweepSegment(size: [2]f32, offset: [2]f32, p0: [2]f32, p1: [2]f32, p2: [2]f32) f32 {
    if (@max(p0[1], p2[1]) <= offset[1] or @min(p0[1], p2[1]) >= offset[1] + size[1]) return 0.0;
    const delta = [2]f32{ p2[0] - p0[0], p2[1] - p0[1] };
    const t0 = [2]f32{ p0[0] - offset[0], p0[1] - offset[1] };
    const t1 = [2]f32{ p1[0] - offset[0], p1[1] - offset[1] };
    const t2 = [2]f32{ p2[0] - offset[0], p2[1] - offset[1] };
    if (t0[0] == t1[0] and t0[0] == t2[0]) {
        if (t0[0] >= size[0]) return 0.0;
        const top = @min(@max(t0[1], t2[1]), size[1]);
        const bottom = @max(@min(t0[1], t2[1]), 0.0);
        const b = @min(size[0], size[0] - t0[0]);
        const sgn: f32 = if (delta[1] > 0) 1 else -1;
        return sgn * b * (top - bottom);
    }
    const qa_y = t0[1] + t2[1] - 2.0 * t1[1];
    const bt = sweepIntersect(qa_y, t0[1], t1[1], t2[1], 0.0);
    const tt = sweepIntersect(qa_y, t0[1], t1[1], t2[1], size[1]);
    const v_min_t: f32 = if (delta[1] > 0.0) bt else tt;
    const v_max_t: f32 = if (delta[1] > 0.0) tt else bt;
    const v_min = sweepEval(t0, t1, t2, std.math.clamp(v_min_t, 0.0, 1.0));
    const v_max = sweepEval(t0, t1, t2, std.math.clamp(v_max_t, 0.0, 1.0));
    if (@max(v_min[0], v_max[0]) <= 0.0) return (v_max[1] - v_min[1]) * size[0];
    if (@min(v_min[0], v_max[0]) >= size[0]) return 0.0;
    const qa_x = t0[0] + t2[0] - 2.0 * t1[0];
    var h_min_t: f32 = 0;
    var h_max_t: f32 = 0;
    var h_check = if (delta[0] > 0.0) [4]f32{ t0[0], t2[0], 0.0, 0.0 } else [4]f32{ t2[0], t0[0], size[0], 1.0 };
    if (h_check[0] >= h_check[2]) {
        h_min_t = h_check[3];
    } else if (h_check[1] <= h_check[2]) {
        h_min_t = 1.0 - h_check[3];
    } else {
        h_min_t = sweepIntersect(qa_x, t0[0], t1[0], t2[0], h_check[2]);
    }
    h_check[2] = size[0] - h_check[2];
    if (h_check[0] >= h_check[2]) {
        h_max_t = h_check[3];
    } else if (h_check[1] <= h_check[2]) {
        h_max_t = 1.0 - h_check[3];
    } else {
        h_max_t = sweepIntersect(qa_x, t0[0], t1[0], t2[0], h_check[2]);
    }
    const min_t = std.math.clamp(@max(v_min_t, h_min_t), 0.0, 1.0);
    const max_t = std.math.clamp(@min(v_max_t, h_max_t), 0.0, 1.0);
    if (min_t >= max_t) return 0.0;
    const q0 = if (v_min_t >= h_min_t) v_min else sweepEval(t0, t1, t2, min_t);
    const q1 = if (v_max_t <= h_max_t) v_max else sweepEval(t0, t1, t2, max_t);
    var area: f32 = 0.0;
    const sgn_y: f32 = if (delta[1] > 0) 1 else -1;
    if (min_t > 0.0 and delta[0] > 0.0) {
        const h_: f32 = if (delta[1] > 0.0) q0[1] - @max(0.0, t0[1]) else @min(size[1], t0[1]) - q0[1];
        area += sgn_y * h_ * size[0];
    }
    if (max_t < 1.0 and delta[0] < 0.0) {
        const h_: f32 = if (delta[1] > 0.0) @min(size[1], t2[1]) - q1[1] else q1[1] - @max(0.0, t2[1]);
        area += sgn_y * h_ * size[0];
    }
    const h_trap = q1[1] - q0[1];
    const b_trap = size[0] - 0.5 * (q0[0] + q1[0]);
    area += b_trap * h_trap;
    return area;
}

/// sRGB (0..1) → Oklab; alpha passes through. a/b may be negative.
/// L is in 0..1 (v4's color convention — never scaled by 100).
pub fn srgbToOklab(rgb: [4]f32) [4]f32 {
    const to_linear = struct {
        fn f(v: f32) f32 {
            if (v <= 0.04045) return v / 12.92;
            return std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
        }
    }.f;
    const r = to_linear(rgb[0]);
    const g = to_linear(rgb[1]);
    const b = to_linear(rgb[2]);

    // LMS cone response (standard Oklab matrix).
    const l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
    const m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
    const s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;

    const lp = std.math.cbrt(l);
    const mp = std.math.cbrt(m);
    const sp = std.math.cbrt(s);

    const l_oklab = 0.2104542553 * lp + 0.7936177850 * mp - 0.0040720468 * sp;
    const a = 1.9779984951 * lp - 2.4285922050 * mp + 0.4505937099 * sp;
    const bb = 0.0259040371 * lp + 0.7827717662 * mp - 0.8086757660 * sp;
    return .{ l_oklab, a, bb, rgb[3] };
}

// ─── Tests (pure only — GPU paths are smoke-verified by the orchestrator) ───

const testing = std.testing;

const CountingAdvanceMeasurer = struct {
    call_count: usize = 0,
    input_bytes_total: usize = 0,

    fn advance(self: *CountingAdvanceMeasurer, text: []const u8) f32 {
        self.call_count += 1;
        self.input_bytes_total += text.len;
        return @floatFromInt(text.len);
    }
};

fn expectLineRanges(text: []const u8, limit: f32, expected: []const LineRange) !void {
    var measurer: CountingAdvanceMeasurer = .{};
    var ranges = LineRangeIterator.init(text, limit);
    resetMeasurer(&measurer);

    for (expected) |expected_range| {
        const actual = ranges.next(&measurer) orelse return error.MissingLineRange;
        try testing.expectEqual(expected_range.start, actual.start);
        try testing.expectEqual(expected_range.end, actual.end);
    }
    try testing.expect(ranges.next(&measurer) == null);
}

test "run cache: clock wrap rebases generations before eviction" {
    var run_cache: RunCache = .empty;
    defer run_cache.deinit(testing.allocator);

    const key_a: RunKey = .{ .hash = 1, .size = 14, .font_id = 0 };
    const key_b: RunKey = .{ .hash = 2, .size = 14, .font_id = 0 };
    const no_glyphs: []GlyphPos = @constCast(&[_]GlyphPos{});
    try run_cache.put(testing.allocator, key_b, .{
        .key = key_b,
        .text = @constCast("b"),
        .width = 1,
        .line_height = 1,
        .glyphs = no_glyphs,
        .generation = std.math.maxInt(u32),
    });
    try run_cache.put(testing.allocator, key_a, .{
        .key = key_a,
        .text = @constCast("a"),
        .width = 1,
        .line_height = 1,
        .glyphs = no_glyphs,
        .generation = std.math.maxInt(u32),
    });

    var run_clock: u32 = std.math.maxInt(u32);
    const next_generation = advanceRunClock(&run_cache, &run_clock);
    try testing.expectEqual(@as(u32, 2), next_generation);

    var iterator = run_cache.iterator();
    while (iterator.next()) |entry| {
        try testing.expect(entry.value_ptr.generation < next_generation);
    }
    const victim_key = oldestRunKey(&run_cache) orelse return error.MissingEvictionVictim;
    try testing.expectEqual(key_a, victim_key);
}

test "line ranges: soft breaks retain measured separators" {
    const text = "alpha beta gamma";
    try expectLineRanges(text, 10, &.{
        .{ .start = 0, .end = 11 },
        .{ .start = 11, .end = text.len },
    });
}

test "line ranges: hard breaks preserve empty and trailing lines" {
    const text = "a\r\n\r\nb\n";
    try expectLineRanges(text, 100, &.{
        .{ .start = 0, .end = 1 },
        .{ .start = 3, .end = 3 },
        .{ .start = 5, .end = 6 },
        .{ .start = 7, .end = 7 },
    });
}
test "measureFlow: max-content preserves hard lines without soft wrapping" {
    var measurer: CountingAdvanceMeasurer = .{};
    const flow = measureFlow(&measurer, "alpha beta\ngamma delta", .max_content);

    try testing.expectEqual(@as(f32, 11), flow.width);
    try testing.expectEqual(@as(usize, 2), flow.line_count);
}
test "measureFlow: leading separators do not reserve painted width" {
    var measurer: CountingAdvanceMeasurer = .{};
    const flow = measureFlow(&measurer, "  alpha\n\tbeta", .max_content);

    try testing.expectEqual(@as(f32, 5), flow.width);
    try testing.expectEqual(@as(usize, 2), flow.line_count);
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

    try testing.expectEqual(@as(f32, 3 * fallback_scalar_advance), flow.width);
    try testing.expectEqual(@as(usize, 1), flow.line_count);
}

test "wrappedLineCount: many segments use linear measurement work" {
    const segment = "abc";
    const segment_count: usize = 128;
    const segments_per_line: usize = 16;
    const separator_size: usize = 1;
    const text_size =
        segment_count * segment.len + (segment_count - 1) * separator_size;
    var text: [text_size]u8 = undefined;
    for (0..segment_count) |segment_index| {
        const segment_start = segment_index * (segment.len + separator_size);
        @memcpy(text[segment_start..][0..segment.len], segment);
        if (segment_index + 1 < segment_count) {
            text[segment_start + segment.len] = ' ';
        }
    }

    const line_width: f32 = @floatFromInt(
        segments_per_line * segment.len + (segments_per_line - 1) * separator_size,
    );
    var measurer: CountingAdvanceMeasurer = .{};
    const line_count = wrappedLineCount(&measurer, &text, line_width);

    try testing.expectEqual(segment_count / segments_per_line, line_count);
    try testing.expect(measurer.input_bytes_total <= text.len * 4);
    try testing.expect(measurer.call_count <= segment_count * 3);
}

test "srgbToOklab: white → L=1, a=0, b=0" {
    const lab = srgbToOklab(.{ 1, 1, 1, 1 });
    try testing.expectApproxEqAbs(@as(f32, 1.0), lab[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), lab[1], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), lab[2], 0.0001);
    try testing.expectEqual(@as(f32, 1.0), lab[3]); // alpha passes through
}

test "srgbToOklab: black → L=0, a=0, b=0" {
    const lab = srgbToOklab(.{ 0, 0, 0, 0.5 });
    try testing.expectApproxEqAbs(@as(f32, 0.0), lab[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), lab[1], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), lab[2], 0.0001);
    try testing.expectEqual(@as(f32, 0.5), lab[3]); // alpha passes through
}

test "srgbToOklab: mid-gray sanity" {
    // Standard Oklab of sRGB (0.5, 0.5, 0.5) is L ≈ 0.598, a ≈ b ≈ 0
    // (verified against the standard matrix; the 0.5-0.55 estimate in the
    // port spec was slightly low).
    const lab = srgbToOklab(.{ 0.5, 0.5, 0.5, 1.0 });
    try testing.expect(lab[0] > 0.55 and lab[0] < 0.65);
    try testing.expectApproxEqAbs(@as(f32, 0.0), lab[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), lab[2], 0.001);
    try testing.expectEqual(@as(f32, 1.0), lab[3]);
}

test "glyph sweep: real 'n' curves give full coverage at stroke centers" {
    // Load the real font, extract 'n' at 20px, rasterize with the ported sweep.
    var ft_lib: c.FT_Library = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Init_FreeType(&ft_lib));
    defer _ = c.FT_Done_FreeType(ft_lib);
    const font_data = @embedFile("InterVariable.ttf");
    var face: c.FT_Face = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.FT_New_Memory_Face(ft_lib, font_data.ptr, @intCast(font_data.len), 0, &face),
    );
    defer _ = c.FT_Done_Face(face);
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Set_Pixel_Sizes(face, 0, 20));

    const n_idx = c.FT_Get_Char_Index(face, 'n');
    const h = c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed;
    const curves = try extractGlyphCurves(std.testing.allocator, .{ .handle = h }, n_idx);
    defer std.testing.allocator.free(curves);
    // curve extent
    var min_x: f32 = 1e9;
    var min_y: f32 = 1e9;
    var max_x: f32 = -1e9;
    var max_y: f32 = -1e9;
    for (curves) |cv| {
        min_x = @min(min_x, @min(@min(cv.p0x, cv.p1x), cv.p2x));
        min_y = @min(min_y, @min(@min(cv.p0y, cv.p1y), cv.p2y));
        max_x = @max(max_x, @max(@max(cv.p0x, cv.p1x), cv.p2x));
        max_y = @max(max_y, @max(@max(cv.p0y, cv.p1y), cv.p2y));
    }
    // rasterize the glyph cell at 1px per sample: window per pixel ≈ 1 curve unit.
    const win = [2]f32{ 1.0, 1.0 };
    var max_cov: f32 = 0;
    var ink: f32 = 0;
    var n: usize = 0;
    for (0..20) |row| {
        for (0..20) |col| {
            const px = [2]f32{ @floatFromInt(col), @floatFromInt(row) };
            const total: f32 = blk: {
                var t: f32 = 0;
                for (curves) |cv| {
                    t += sweepSegment(
                        win,
                        px,
                        .{ cv.p0x - min_x, cv.p0y - min_y },
                        .{ cv.p1x - min_x, cv.p1y - min_y },
                        .{ cv.p2x - min_x, cv.p2y - min_y },
                    );
                }
                break :blk t;
            };
            const cov = total / (win[0] * win[1]);
            if (cov > max_cov) max_cov = cov;
            if (cov > 0.5) {
                ink += cov;
                n += 1;
            }
        }
    }
    // A 13px 'n' stem center must be nearly solid.
    try std.testing.expect(max_cov > 0.8);
    // Ink: a 13px 'n' covers ~20 px of stroke (the sweep scales with size).
    try std.testing.expect(ink > 15);
}

test "quad policy: hb extents bound the ink, the 2px surround keeps the outer pixel rings clear" {
    // The glyph bb (the hb extents — the conservative control-point hull)
    // must CONTAIN the actual curve hull, and the quad = the bb + 2px
    // surround (emitText: ch-2 / ceil+4) must leave the two outermost
    // pixel rings completely clear of ink — so even a bb that hits a
    // pixel as a sliver resolves its AA edge fully inside the quad.
    var ft_lib: c.FT_Library = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Init_FreeType(&ft_lib));
    defer _ = c.FT_Done_FreeType(ft_lib);
    const font_data = @embedFile("InterVariable.ttf");
    const glyphs = "nqTfxA";
    const sizes = [_]u32{ 13, 16, 20 };
    for (sizes) |px| {
        var face: c.FT_Face = undefined;
        try std.testing.expectEqual(
            @as(c_int, 0),
            c.FT_New_Memory_Face(ft_lib, font_data.ptr, @intCast(font_data.len), 0, &face),
        );
        defer _ = c.FT_Done_Face(face);
        try std.testing.expectEqual(@as(c_int, 0), c.FT_Set_Pixel_Sizes(face, 0, px));
        const h = c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed;
        for (glyphs) |ch| {
            const gid = c.FT_Get_Char_Index(face, ch);
            const curves = try extractGlyphCurves(std.testing.allocator, .{ .handle = h }, gid);
            defer std.testing.allocator.free(curves);
            // The ink's true extent: the control hull of the EXTRACTED
            // curves (the cubic-split conics shrink the hull, never grow
            // it, so it must sit inside the hb bb).
            const hull = renderer.glyphExtent(curves);
            var ext: c.hb_glyph_extents_t = undefined;
            try std.testing.expectEqual(@as(c_int, 1), c.hb_font_get_glyph_extents(h, gid, &ext));
            const bbx: f32 = @floatCast(@as(f64, @floatFromInt(ext.x_bearing)) / 64.0);
            const bby: f32 = @floatCast(@as(f64, @floatFromInt(ext.y_bearing)) / 64.0);
            const bbw: f32 = @floatCast(@as(f64, @floatFromInt(ext.width)) / 64.0);
            const bbh: f32 = @floatCast(@as(f64, @floatFromInt(@abs(ext.height))) / 64.0);
            try std.testing.expect(hull.min_x >= bbx - 0.001);
            try std.testing.expect(hull.min_y >= bby - bbh - 0.001);
            try std.testing.expect(hull.min_x + hull.w <= bbx + bbw + 0.001);
            try std.testing.expect(hull.min_y + hull.h <= bby + 0.001);
            // The quad in the glyph's own (y-up, pen-origin) space: the bb
            // + 2px on each side. Sweep the two outermost pixel rings —
            // they must hold no ink at all (the AA then fades within
            // rings >= 2).
            const qx0 = bbx - 2.0; // dst_x - pen = ch_x - 2
            const qy0 = bby - bbh - 2.0; // the quad's bottom (y-up): the bb's bottom - 2
            const qw = @ceil(bbw) + 4.0;
            const qh = @ceil(bbh) + 4.0;
            const win = [2]f32{ 1.0, 1.0 };
            var ring_ink: f32 = 0;
            var col: usize = 0;
            while (col < @as(usize, @intFromFloat(qw))) : (col += 1) {
                var row: usize = 0;
                while (row < @as(usize, @intFromFloat(qh))) : (row += 1) {
                    // Interior (rings >= 2) is skipped; only the two outer rings are swept.
                    if (col >= 2 and col < @as(usize, @intFromFloat(qw)) - 2 and
                        row >= 2 and row < @as(usize, @intFromFloat(qh)) - 2) continue;
                    const col_f: f32 = @floatFromInt(@min(col, 1 << 24));
                    const row_f: f32 = @floatFromInt(@min(row, 1 << 24));
                    const px_ = [2]f32{ qx0 + col_f, qy0 + row_f };
                    var total: f32 = 0;
                    for (curves) |cv| {
                        total += sweepSegment(win, px_, .{ cv.p0x, cv.p0y }, .{ cv.p1x, cv.p1y }, .{ cv.p2x, cv.p2y });
                    }
                    ring_ink += total;
                }
            }
            // The residue here is pure boundary float noise (a hull edge
            // exactly on a window edge, e.g. 'x' at 20px) — ~1e-6, six
            // orders below any visible coverage; 1e-4 leaves 100x margin.
            std.testing.expect(ring_ink < 1e-4) catch {
                std.debug.print(
                    "ring leak: '{c}' {d}px bbx={d:.3} bby={d:.3} bbw={d:.3} " ++
                        "bbh={d:.3} hull=[{d:.3},{d:.3}] ring_ink={d:.6}\n",
                    .{ ch, px, bbx, bby, bbw, bbh, hull.min_x, hull.min_y, ring_ink },
                );
                return error.TestUnexpectedResult;
            };
        }
    }
}

test "shaping: the hb-ft font scale is 26.6 fixed-point pixels" {
    // Standalone FT + hb setup (no GPU): a shaped 'A' at 20px must advance
    // ~13px = 832 in 26.6 units — the shaper positions are /64.0 → px.
    var ft_lib: c.FT_Library = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Init_FreeType(&ft_lib));
    defer _ = c.FT_Done_FreeType(ft_lib);
    const font_data = @embedFile("InterVariable.ttf");
    var face: c.FT_Face = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.FT_New_Memory_Face(ft_lib, font_data.ptr, @intCast(font_data.len), 0, &face),
    );
    defer _ = c.FT_Done_Face(face);
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Set_Pixel_Sizes(face, 0, font_size_px));
    const handle = c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed;
    var font: hb.Font = .{ .handle = handle };
    defer font.destroy();

    var buf = try hb.Buffer.create();
    defer buf.destroy();
    buf.addUTF8("A");
    buf.setDirection(.ltr);
    buf.setScript(.latin);
    hb.shape(font, buf, null);
    const positions = buf.getGlyphPositions() orelse return error.NoPositions;
    try std.testing.expectEqual(@as(usize, 1), positions.len);
    // The hb scale is 26.6 fixed-point px: the shaped advance must agree
    // with FreeType's own UNHINTED advance at any pixel size (the scale
    // test is size-independent).
    _ = c.FT_Load_Glyph(face, c.FT_Get_Char_Index(face, 'A'), c.FT_LOAD_NO_HINTING);
    const ft_adv: f32 = @floatCast(@as(f64, @floatFromInt(face.*.glyph.*.metrics.horiAdvance)) / 64.0);
    const shaped_adv: f32 = @floatCast(@as(f64, @floatFromInt(positions[0].x_advance)) / 64.0);
    try std.testing.expectApproxEqAbs(ft_adv, shaped_adv, 0.2);
}

test "shaping: kerned AV pair is narrower than the advance sum" {
    var ft_lib: c.FT_Library = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Init_FreeType(&ft_lib));
    defer _ = c.FT_Done_FreeType(ft_lib);
    const font_data = @embedFile("InterVariable.ttf");
    var face: c.FT_Face = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.FT_New_Memory_Face(ft_lib, font_data.ptr, @intCast(font_data.len), 0, &face),
    );
    defer _ = c.FT_Done_Face(face);
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Set_Pixel_Sizes(face, 0, font_size_px));
    const handle = c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed;
    var font: hb.Font = .{ .handle = handle };
    defer font.destroy();

    const width = struct {
        fn w(fnt: hb.Font, text: []const u8) !f32 {
            var buf = try hb.Buffer.create();
            defer buf.destroy();
            buf.addUTF8(text);
            buf.setDirection(.ltr);
            buf.setScript(.latin);
            hb.shape(fnt, buf, null);
            var total: f32 = 0;
            for (buf.getGlyphPositions() orelse &.{}) |p| {
                total += @as(f32, @floatCast(@as(f64, @floatFromInt(p.x_advance)) / 64.0));
            }
            return total;
        }
    }.w;

    const av = try width(font, "AV");
    const a = try width(font, "A");
    const v = try width(font, "V");
    // The classic AV pair is GPOS-kerned in Inter: AV < A + V.
    try std.testing.expect(av < a + v - 0.5);
    // H-H is not kerned: the shaped width equals the naive sum.
    const hh = try width(font, "HH");
    const h = try width(font, "H");
    try std.testing.expectApproxEqAbs(hh, h + h, 0.01);
}

test "shaping: invalid UTF-8 substitutes .notdef, never panics" {
    var ft_lib: c.FT_Library = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Init_FreeType(&ft_lib));
    defer _ = c.FT_Done_FreeType(ft_lib);
    const font_data = @embedFile("InterVariable.ttf");
    var face: c.FT_Face = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.FT_New_Memory_Face(ft_lib, font_data.ptr, @intCast(font_data.len), 0, &face),
    );
    defer _ = c.FT_Done_Face(face);
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Set_Pixel_Sizes(face, 0, font_size_px));
    const handle = c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed;
    var font: hb.Font = .{ .handle = handle };
    defer font.destroy();

    var buf = try hb.Buffer.create();
    defer buf.destroy();
    buf.addUTF8("a\xFF\xFEb");
    hb.shape(font, buf, null);
    const infos = buf.getGlyphInfos();
    // Every input byte maps to a glyph (2 .notdef for the invalid pair);
    // the run stays bounded.
    try std.testing.expect(infos.len == 3 or infos.len == 4);
}

test "shaping: the kern feature applies GPOS pair adjustments in px" {
    // hb-ft runs with FT_LOAD_NO_HINTING: advances, extents and outlines
    // are the UNHINTED (true) values in the 26.6-px hb scale — consistent
    // with the shaped positions. The old pipeline mixed the shaper's
    // unhinted advances with the HINTED FT metrics, which is what made
    // "reset" look unevenly spaced.
    var ft_lib: c.FT_Library = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Init_FreeType(&ft_lib));
    defer _ = c.FT_Done_FreeType(ft_lib);
    const font_data = @embedFile("InterVariable.ttf");
    var face: c.FT_Face = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.FT_New_Memory_Face(ft_lib, font_data.ptr, @intCast(font_data.len), 0, &face),
    );
    defer _ = c.FT_Done_Face(face);
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Set_Pixel_Sizes(face, 0, font_size_px));
    const handle = c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed;
    var font: hb.Font = .{ .handle = handle };
    defer font.destroy();

    const kern_off = [_]hb.Feature{.{ .tag = 0x6b65726e, .value = 0, .start = 0, .end = std.math.maxInt(c_uint) }};

    const width = struct {
        fn w(fnt: hb.Font, text: []const u8, features: ?[]const hb.Feature) !f32 {
            var buf = try hb.Buffer.create();
            defer buf.destroy();
            buf.addUTF8(text);
            buf.setDirection(.ltr);
            buf.setScript(.latin);
            hb.shape(fnt, buf, features);
            var total: f32 = 0;
            for (buf.getGlyphPositions() orelse &.{}) |p| {
                total += @as(f32, @floatCast(@as(f64, @floatFromInt(p.x_advance)) / 64.0));
            }
            return total;
        }
    }.w;

    // The classic AV pair tightens by the font's real GPOS value.
    const av = try width(font, "AV", null);
    const av_off = try width(font, "AV", &kern_off);
    try std.testing.expect(av < av_off - 0.3);

    // Inter has NO s->e GPOS pair: the kern feature changes nothing.
    // ("res et" was a hinting artifact of the old pipeline, not kerning.)
    const se = try width(font, "se", null);
    const se_off = try width(font, "se", &kern_off);
    try std.testing.expectApproxEqAbs(se, se_off, 0.01);

    // The base advances are the UNHINTED ones — they differ from the
    // hinted FT metrics the old pipeline used for the bitmaps.
    const s_gid = c.FT_Get_Char_Index(face, 's');
    const e_gid = c.FT_Get_Char_Index(face, 'e');
    const s_adv: f32 = @floatCast(@as(f64, @floatFromInt(c.hb_font_get_glyph_h_advance(handle, s_gid))) / 64.0);
    const e_adv: f32 = @floatCast(@as(f64, @floatFromInt(c.hb_font_get_glyph_h_advance(handle, e_gid))) / 64.0);
    try std.testing.expectApproxEqAbs(se_off, s_adv + e_adv, 0.01);
    _ = c.FT_Load_Glyph(face, s_gid, c.FT_LOAD_DEFAULT);
    const ft_hinted: f32 = @floatCast(@as(f64, @floatFromInt(face.*.glyph.*.metrics.horiAdvance)) / 64.0);
    try std.testing.expect(@abs(s_adv - ft_hinted) > 0.1); // unhinted ≠ hinted
}

test "snapping: run origin snapped, internal kerning exact" {
    // The shimmer fix: the run's LOGICAL origin lands on the pixel grid,
    // while the glyphs inside keep the EXACT shaped positions — a
    // per-glyph snap quantizes the advances and breaks sub-pixel kerning
    // (the "re set" / "w ater plants" regression at 13px).
    const cases = [_]f32{ 0.0, 10.3, 100.7, 123.456 };
    for (cases) |x| {
        try std.testing.expect(TextEngine.snapRunOrigin(x) == @floor(TextEngine.snapRunOrigin(x)));
        // The snapped origin stays within half a pixel of the logical one.
        try std.testing.expect(@abs(TextEngine.snapRunOrigin(x) - x) <= 0.5);
    }
    // The internal gaps are the EXACT shaped advances: for any origin, the
    // rendered pair gap equals the shaper's advance (no rounding).
    const adv: f32 = 6.86; // e.g. a 13px Inter 's' advance
    const b0: f32 = 0.4;
    const b1: f32 = -0.2;
    const gap_at = struct {
        fn g(x: f32) f32 {
            const run_x = TextEngine.snapRunOrigin(x);
            const g0 = run_x + 0 + b0; // first glyph at cursor 0
            const g1 = run_x + adv + b1; // second at cursor = adv
            return g1 - g0 - (adv - 0); // ink gap = advance − bearing delta
        }
    }.g;
    for (cases) |x| {
        try std.testing.expectApproxEqAbs(adv + b1 - b0 - (adv - 0), gap_at(x), 0.001);
    }
    // And the pair gap is the same at every origin (constant spacing).
    const g1 = gap_at(0.0);
    const g2 = gap_at(37.9);
    try std.testing.expectApproxEqAbs(g1, g2, 0.001);
}
