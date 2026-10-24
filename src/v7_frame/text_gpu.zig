//! HarfBuzz-shaped graphics text engine.
//!
//! EXPERIMENT: the per-codepoint FreeType iteration (FT_Get_Char_Index +
//! advance sums, no kerning) is replaced with HarfBuzz shaping (hb_shape:
//! kerning, ligatures, mark positioning). FreeType remains as the rasterizer
//! backend ONLY — the hb-ft font delegates outline extraction to it, and we
//! load the shaped glyph ids from the shared face. All layout decisions
//! (glyph selection, advances, offsets) come from HarfBuzz.
//!
//! Public engine for any GPU host. It embeds no font and links no windowing
//! library: the caller hands it caller-owned font bytes at init, and the
//! text service copies them. Measurement and shaping are not reimplemented
//! here — every measure goes through nogui_text. The v7 CORE (src/v7/)
//! stays pure.

const std = @import("std");
const tracy = @import("tracy");
const noapi = @import("noapi");
const renderer = @import("v7_render");
const SceneRect = renderer.SceneRect;
const nogui = @import("nogui");
const CounterSink = nogui.CounterSink;
pub const MeasureInput = nogui.layout.MeasureInput;

// One C import, owned by the HarfBuzz binding: hb.h + hb-ft.h pull in
// freetype.h, so this exposes the full FreeType API we still need for
// outline extraction.
const hb = @import("harfbuzz");
const c = hb.c; // the binding's single C import: hb.h + hb-ft.h + freetype.h
const cpu = @import("nogui_text");
const shaping = cpu.shaping;

pub const NodeLayoutOptions = cpu.NodeLayoutOptions;
pub const TextLayout = cpu.TextLayout;

/// The vertical offset `emitNodeText` centres a caption's text block by inside
/// the box its layout options name. Only the emit path reads it, and it is the
/// only place that expression lives, so a caption can never be painted at one
/// origin and measured at another.
fn captionBlockInset(options: NodeLayoutOptions, layout_height: f32) f32 {
    const box_height = options.box_height orelse return 0;
    return @max(0, (box_height - layout_height) / 2);
}

/// Real font bytes for the tests below, which load actual faces. Test-only:
/// `@embedFile` cannot leave this module, so the build publishes the bytes
/// as `v7_frame_test_fonts`. Nothing outside a test block reads it.
const test_fonts = @import("v7_frame_test_fonts");

/// Slot 0 is solid. Glyphs, per-frame paint rings, and SVG materials use
/// disjoint regions; the host sets the exclusive glyph ceiling.
pub const max_materials: u32 = 4096;
/// The engine's default pixel size: the size of the bootstrap face, and the
/// size a measure request falls back to when it carries none. Every other
/// size comes from the host's layout policy.
pub const font_size_px: u32 = 14;
const fallback_scalar_advance: f32 = 10;

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

/// Leave at least one complete device-pixel footprint beyond each glyph
/// edge. The original two-unit surround stays exact at 1x and above.
fn glyphRasterMargins(scale: nogui.geometry.PixelScale) [2]f32 {
    return .{ @max(2.0, 1.0 / scale.x), @max(2.0, 1.0 / scale.y) };
}

fn glyphQuadRect(x: f32, y: f32, width: f32, height: f32, margin: [2]f32) [4]f32 {
    return .{
        x - margin[0],
        y - margin[1],
        @ceil(width) + 2.0 * margin[0],
        @ceil(height) + 2.0 * margin[1],
    };
}

const absent_glyph_entry_index: u32 = std.math.maxInt(u32);

/// One font size's FreeType face + HarfBuzz font + metrics. The engine
/// holds a small per-size cache of these — the ONLY per-size state in the
/// pipeline; the materials, slice emission and draw path are size-agnostic.
const FontState = struct {
    face: c.FT_Face,
    hb_font: hb.Font,
    font_id: u8,
    size: u32,
    /// Zero for embedded demo fonts; TextService handles use their generation.
    source_generation: u32,
    source_bytes: []const u8,
    weight: u16,
    ascent: f32,
    descent: f32,
    empty_glyphs: std.bit_set.Dynamic,
    /// One stable entry index per glyph id; absent entries use the sentinel.
    entry_indices: []u32,

    const InitOptions = struct {
        face: c.FT_Face,
        hb_font: hb.Font,
        font_id: u8,
        size: u32,
        source_generation: u32 = 0,
        source_bytes: []const u8,
        weight: u16 = 400,
        extents: c.hb_font_extents_t,
    };

    fn init(gpa: std.mem.Allocator, options: InitOptions) !FontState {
        const glyph_count = std.math.cast(usize, options.face.*.num_glyphs) orelse
            return error.FreeTypeFaceFailed;
        var empty_glyphs = try std.bit_set.Dynamic.initEmpty(gpa, glyph_count);
        errdefer empty_glyphs.deinit(gpa);
        const entry_indices = try gpa.alloc(u32, glyph_count);
        errdefer gpa.free(entry_indices);
        @memset(entry_indices, absent_glyph_entry_index);
        return .{
            .face = options.face,
            .hb_font = options.hb_font,
            .font_id = options.font_id,
            .size = options.size,
            .source_generation = options.source_generation,
            .source_bytes = options.source_bytes,
            .weight = options.weight,
            .ascent = @as(
                f32,
                @floatCast(@as(f64, @floatFromInt(options.extents.ascender)) / 64.0),
            ),
            .descent = @as(
                f32,
                @floatCast(@as(f64, @floatFromInt(options.extents.descender)) / 64.0),
            ),
            .empty_glyphs = empty_glyphs,
            .entry_indices = entry_indices,
        };
    }

    fn deinit(self: *FontState, gpa: std.mem.Allocator) void {
        gpa.free(self.entry_indices);
        self.empty_glyphs.deinit(gpa);
        self.hb_font.destroy();
        _ = c.FT_Done_Face(self.face);
        self.* = undefined;
    }

    fn knowsEmptyGlyph(self: *const FontState, gid: u32) bool {
        const glyph_index = std.math.cast(usize, gid) orelse return false;
        if (glyph_index >= self.empty_glyphs.capacity()) return false;
        return self.empty_glyphs.isSet(glyph_index);
    }

    fn rememberEmptyGlyph(self: *FontState, gid: u32) void {
        const glyph_index = std.math.cast(usize, gid) orelse return;
        if (glyph_index >= self.empty_glyphs.capacity()) return;
        self.empty_glyphs.set(glyph_index);
    }

    fn rememberGlyphEntry(self: *FontState, gid: u32, entry_index: usize) void {
        const glyph_index = std.math.cast(usize, gid) orelse return;
        if (glyph_index >= self.entry_indices.len) return;
        std.debug.assert(entry_index < @as(usize, std.math.maxInt(u32)));
        self.entry_indices[glyph_index] = @intCast(entry_index);
    }
};

const GlyphPos = shaping.Glyph;

// ─── Shared CPU measurement ──────────────────────────
// Measurement, shaping and cached-run policy live in nogui_text so the
// headless measure hook, the immutable text layout and this graphical host
// run one implementation over one shaping cache. The engine reaches them
// through `NodeMeasurer`, never through a second pipeline of its own.
const ShapedAdvance = cpu.ShapedAdvance;
const FallbackAdvance = cpu.FallbackAdvance;
const WidthMode = cpu.WidthMode;
const LineRange = cpu.LineRange;
const LineRangeIterator = cpu.LineRangeIterator;
const nextTextSegment = cpu.nextTextSegment;
const segmentHasContent = cpu.segmentHasContent;
const intrinsicMetrics = cpu.intrinsicMetrics;
const wrappedLineCount = cpu.wrappedLineCount;
const measureFlow = cpu.measureFlow;
const measureByLinePolicy = cpu.measureByLinePolicy;

const max_font_sizes = 16;

pub const TextEngine = struct {
    const CachedColor = struct { source: [4]f32, converted: [4]f32 };
    gpu: *noapi.Gpu,
    gpa: std.mem.Allocator,
    /// Font metrics and scene geometry remain logical. Placement snaps to
    /// the device grid, and glyph quads cover the device-pixel footprint.
    pixel_scale: nogui.geometry.PixelScale = .{ .x = 1, .y = 1 },
    glyph_margin: [2]f32 = .{ 2, 2 },
    /// Per-size font states (FT face + hb font + metrics); the default
    /// size is created at init, others lazily on first use.
    fonts: [max_font_sizes]?FontState = @splat(null),
    // Parallel arrays, one element per rasterized glyph:
    // sweepers[i] owns the GPU curve buffer backing entries[i].
    sweepers: std.ArrayList(renderer.GlyphSweeper) = .empty, // per glyph
    entries: std.ArrayList(GlyphEntry) = .empty, // per glyph
    /// One retained arena shared by the measure seam and the emit path. A
    /// node layout is carved directly here and released before the arena is
    /// reset, so a warm frame performs no allocator traffic at all.
    scratch: std.heap.ArenaAllocator,
    /// The CPU measure hook over `service`, bound on first use so the engine
    /// is already in its final storage when the pointer is taken.
    node_measurer: ?cpu.NodeMeasurer = null,
    materials: noapi.GpuPtr, // max_materials * material_size, .default
    next_slot: u32 = 1,
    material_bda: u64 = 0,
    /// Exclusive ceiling for glyph materials; host-owned frame rings start here.
    glyph_slot_limit: u32 = max_materials,

    /// The one FreeType library, font registry and shaping cache. The engine
    /// paints exactly the runs `nodeLayoutIn` produced, and the measure seam
    /// shapes through the same cache, so neither path shapes text twice.
    service: cpu.TextService,
    counter_sink: CounterSink = CounterSink.init(null),
    // SAFETY: only entries before cached_color_count are read; the cache
    // writes slot next_color and grows the count afterwards.
    cached_colors: [32]CachedColor = undefined,
    cached_color_count: usize = 0,
    next_color: usize = 0,

    /// How many glyph material slots are live (slots 1..next_slot-1 from
    /// the bottom of the buffer). window.zig allocates its per-frame
    /// decoration materials downward from the top and asserts it stays
    /// above this count, so a decoration write can never overwrite an
    /// in-flight glyph material.
    pub fn glyphSlotCount(self: *TextEngine) u32 {
        return self.next_slot;
    }
    /// Reserve the upper material range before recording frame paints.
    /// Existing glyphs cannot be displaced by a later reservation.
    pub fn setGlyphSlotLimit(self: *TextEngine, limit: u32) !void {
        if (limit < self.next_slot or limit > max_materials) return error.InvalidMaterialLimit;
        self.glyph_slot_limit = limit;
    }

    pub fn setCounterSink(self: *TextEngine, counters: ?*nogui.Counters) void {
        self.counter_sink = CounterSink.init(counters);
        self.service.setCounterSink(counters);
    }
    pub fn counterSink(self: *const TextEngine) *const CounterSink {
        return &self.counter_sink;
    }

    pub fn setPixelScale(self: *TextEngine, scale: nogui.geometry.PixelScale) void {
        std.debug.assert(std.math.isFinite(scale.x));
        std.debug.assert(scale.x > 0);
        std.debug.assert(std.math.isFinite(scale.y));
        std.debug.assert(scale.y > 0);
        self.pixel_scale = scale;
        self.glyph_margin = glyphRasterMargins(scale);
    }

    /// Register the caller's fonts in the shared text service, load font 0
    /// at font_size_px, wrap it in a HarfBuzz font, and allocate the
    /// material buffer. The service copies the font bytes, so the caller's
    /// slices need not outlive this call. Returns errors (not panics) on
    /// FT/HB failures; on partial failure everything allocated so far is
    /// released.
    pub fn init(
        gpa: std.mem.Allocator,
        gpu: *noapi.Gpu,
        fonts: []const cpu.FontSource,
    ) !TextEngine {
        var service = try cpu.TextService.init(gpa);
        errdefer service.deinit();
        try registerFonts(&service, fonts);
        const ft_lib = service.library;

        // The bootstrap state must carry the registry's identity, otherwise
        // the first `fontFor` would build a second face for the same family.
        const registered = service.listFonts();
        if (registered.len == 0) return error.UnknownFont;
        const inter = registered[0].handle;
        const inter_source = try service.fontSource(inter);
        std.debug.assert(inter_source.bytes.len <= std.math.maxInt(u32));
        // SAFETY: assigned by FT_New_Memory_Face before any use; failures return errors.
        var face: c.FT_Face = undefined;
        const inter_len: c.FT_Long = @intCast(inter_source.bytes.len);
        if (c.FT_New_Memory_Face(ft_lib, inter_source.bytes.ptr, inter_len, 0, &face) != 0)
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
        const font_state = try FontState.init(gpa, .{
            .face = face,
            .hb_font = hb_font,
            .font_id = @intCast(inter.index),
            .source_generation = inter.generation,
            .source_bytes = inter_source.bytes,
            .size = font_size_px,
            .extents = font_ext,
        });
        return .{
            .gpu = gpu,
            .gpa = gpa,
            .scratch = std.heap.ArenaAllocator.init(gpa),
            .materials = materials,
            .material_bda = materials.gpu,
            .service = service,
            .fonts = blk: {
                var states: [max_font_sizes]?FontState = @splat(null);
                states[0] = font_state;
                break :blk states;
            },
        };
    }

    /// Install font sources in call order, so a face's registry position is
    /// stable for the whole life of the engine.
    fn registerFonts(service: *cpu.TextService, sources: []const cpu.FontSource) !void {
        for (sources) |source| {
            _ = try service.addFont(source);
        }
    }

    /// Get (or lazily create) the font state for the registered face at
    /// `index` and `size` px. One FT face + hb font per size is the only
    /// per-size state in the pipeline. This is a private bootstrap and test
    /// path: paint reaches faces through the handles a layout carries.
    fn fontFor(self: *TextEngine, index: usize, size: u32) !*FontState {
        const registered = self.service.listFonts();
        if (index >= registered.len) return error.UnknownFont;
        return self.fontForLayout(&self.service, registered[index].handle, size, 400);
    }

    fn fontForLayout(
        self: *TextEngine,
        service: *const cpu.TextService,
        handle: nogui.text.FontHandle,
        size: u32,
        weight: u16,
    ) !*FontState {
        const source = try service.fontSource(handle);
        if (handle.index > std.math.maxInt(u8)) return error.UnknownFont;
        return self.fontForBytes(@intCast(handle.index), handle.generation, source.bytes, size, weight);
    }

    fn fontForBytes(
        self: *TextEngine,
        font_id: u8,
        generation: u32,
        font_data: []const u8,
        size: u32,
        weight: u16,
    ) !*FontState {
        for (&self.fonts) |*f| {
            if (f.*) |*fs| {
                if (fs.font_id == font_id and fs.source_generation == generation and
                    fs.source_bytes.ptr == font_data.ptr and fs.source_bytes.len == font_data.len and
                    fs.size == size and fs.weight == weight) return fs;
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

        // FreeType holds the borrowed bytes for the lifetime of the face.
        // SAFETY: FT_New_Memory_Face writes the handle; a non-zero status returns first.
        var face: c.FT_Face = undefined;
        std.debug.assert(font_data.len <= std.math.maxInt(u32));
        const font_len: c.FT_Long = @intCast(font_data.len);
        if (c.FT_New_Memory_Face(self.service.library, font_data.ptr, font_len, 0, &face) != 0)
            return error.FreeTypeFaceFailed;
        errdefer _ = c.FT_Done_Face(face);
        if (c.FT_Set_Pixel_Sizes(face, 0, size) != 0) return error.FreeTypeSetPixelSizesFailed;

        const hb_handle = hb.c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed;
        var hb_font: hb.Font = .{ .handle = hb_handle };
        hb.c.hb_ft_font_set_funcs(hb_handle);
        _ = hb.c.hb_ft_font_set_load_flags(hb_handle, c.FT_LOAD_DEFAULT | c.FT_LOAD_NO_HINTING);
        const variation: c.hb_variation_t = .{
            .tag = nogui.text.tag("wght"),
            .value = @floatFromInt(weight),
        };
        c.hb_font_set_variations(hb_handle, &variation, 1);
        _ = c.hb_ft_hb_font_changed(hb_handle);
        errdefer hb_font.destroy();

        // SAFETY: hb_font_get_extents_for_direction fills every field before the reads.
        var font_ext: c.hb_font_extents_t = undefined;
        _ = c.hb_font_get_extents_for_direction(hb_handle, c.HB_DIRECTION_LTR, &font_ext);
        const font_state = try FontState.init(self.gpa, .{
            .face = face,
            .hb_font = hb_font,
            .font_id = font_id,
            .size = size,
            .extents = font_ext,
            .source_generation = generation,
            .source_bytes = font_data,
            .weight = weight,
        });

        self.fonts[idx] = font_state;
        if (self.fonts[idx]) |*font| return font;
        unreachable;
    }

    pub fn deinit(self: *TextEngine) void {
        for (self.sweepers.items) |*s| s.deinit(); // frees each GPU curve buffer
        self.sweepers.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        for (&self.fonts) |*f| {
            if (f.*) |*fs| fs.deinit(self.gpa);
        }
        // No layout may outlive the engine: every one pins a cache run.
        self.scratch.deinit();
        // The cache, the faces and the FreeType library all belong to the
        // service; releasing it drops the resident runs held by this engine.
        self.service.deinit();
        self.gpu.gpuFree(self.materials);
        self.* = undefined;
    }

    pub fn materialBda(self: *const TextEngine) u64 {
        return self.material_bda;
    }

    /// The shared material buffer every glyph and paint material is written
    /// into. Scene lowering reads it through this accessor; the field is the
    /// engine's own storage and must not be reassigned while frames are in
    /// flight.
    pub fn materialBuffer(self: *const TextEngine) noapi.GpuPtr {
        return self.materials;
    }

    /// Snap the run's logical pen and baseline to whole device pixels, then
    /// return logical units for the scene. Shaped offsets and advances inside
    /// the run stay exact, preserving kerning without a second scale step.
    fn snapToDeviceGrid(logical: f32, pixels_per_logical: f32) f32 {
        return @round(logical * pixels_per_logical) / pixels_per_logical;
    }

    /// The core measure hook for this engine's own text service. Core holds
    /// the returned source, so the engine must already be in the storage the
    /// caller keeps; the service pointer is taken on this first call and
    /// never rebound.
    pub fn measurer(self: *TextEngine) nogui.layout.MeasureSource {
        if (self.node_measurer == null) {
            // SAFETY: `init` assigns every field of the local before the copy
            // below reads it, and no statement between the two can observe
            // the storage.
            var bound: cpu.NodeMeasurer = undefined;
            bound.init(&self.service, &self.scratch, @as(f32, @floatFromInt(font_size_px)));
            self.node_measurer = bound;
        }
        return self.node_measurer.?.source();
    }

    /// Look up a resident glyph in its font-and-size-owned dense index.
    /// Glyph id 0 and glyph ids outside the font's bound are absent.
    fn glyphIndex(self: *const TextEngine, font: *const FontState, gid: u32) ?usize {
        if (gid == 0) return null;
        const glyph_index = std.math.cast(usize, gid) orelse return null;
        if (glyph_index >= font.entry_indices.len) return null;
        self.counter_sink.add(.glyph_entry_comparisons, 1);
        const entry_index = font.entry_indices[glyph_index];
        if (entry_index == absent_glyph_entry_index) return null;
        const index: usize = @intCast(entry_index);
        std.debug.assert(index < self.entries.items.len);
        return index;
    }

    /// Ensure a glyph is rasterized. Missing glyphs and unsupported outlines
    /// return null; allocation and material-budget failures remain errors.
    fn ensureGlyph(self: *TextEngine, font: *FontState, gid: u32) !?usize {
        if (gid == 0) return null;
        if (font.knowsEmptyGlyph(gid)) return null;
        if (self.glyphIndex(font, gid)) |index| return index;
        return self.ensureGlyphInner(font, gid);
    }

    fn ensureGlyphInner(self: *TextEngine, font: *FontState, gid: u32) !?usize {
        const curves = (extractGlyphCurvesCached(self.gpa, font, gid) catch |err| switch (err) {
            error.GlyphNotFound, error.GlyphDrawFailed => return null,
            else => return err,
        }) orelse return null;
        defer self.gpa.free(curves);
        std.debug.assert(curves.len > 0);

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
        if (self.next_slot >= self.glyph_slot_limit) return error.TooManyGlyphs;
        std.debug.assert(self.next_slot < self.glyph_slot_limit);

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

        // Transfer the sweeper into the parallel list. On any append failure
        // free the GPU curve buffer so nothing leaks and the two lists stay
        // index-aligned. The slot remains unpublished and is safe to retry.
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
        self.next_slot += 1;
        // Publish only after both the real glyph material and stable entry
        // exist. Empty, failed, and retryable glyphs never enter this table.
        font.rememberGlyphEntry(gid, entry_index);
        return entry_index;
    }

    fn ensureSceneCapacity(self: *TextEngine, out: *std.ArrayList(SceneRect), additional: usize) !void {
        if (additional > out.capacity - out.items.len) {
            self.counter_sink.add(.slice_rect_growth_events, 1);
            self.counter_sink.add(
                .slice_rect_growth_copy_bytes,
                @as(u64, @intCast(out.items.len)) * @sizeOf(SceneRect),
            );
        }
        try out.ensureTotalCapacity(self.gpa, out.items.len + additional);
    }

    fn layoutColor(self: *TextEngine, color: [4]f32) [4]f32 {
        for (self.cached_colors[0..self.cached_color_count]) |entry| {
            if (std.mem.eql(u8, std.mem.asBytes(&entry.source), std.mem.asBytes(&color)))
                return entry.converted;
        }
        const converted = srgbToOklab(color);
        self.cached_colors[self.next_color] = .{ .source = color, .converted = converted };
        self.next_color = (self.next_color + 1) % self.cached_colors.len;
        self.cached_color_count = @min(self.cached_color_count + 1, self.cached_colors.len);
        return converted;
    }

    fn appendLayoutSolid(
        self: *TextEngine,
        rect: nogui.text.Rect,
        color: nogui.text.Color,
        origin_x: f32,
        origin_y: f32,
        clip_id: u32,
        z: u32,
        out: *std.ArrayList(SceneRect),
    ) void {
        if (rect.width <= 0 or rect.height <= 0) return;
        const x = origin_x + rect.x;
        const y = origin_y + rect.y;
        out.appendAssumeCapacity(.{
            .dst = .{ x, y, rect.width, rect.height },
            .src = .{ 0, 0, 1, 1 },
            .corners = .{ 0, 0, 0, 0 },
            .color = self.layoutColor(color),
            .curve = .{ 0, 0, 0, 0 },
            .material_index = 0,
            .clip_id = clip_id,
            .origin = .{ x, y },
            .z = z,
        });
    }

    fn appendNotdef(
        self: *TextEngine,
        run_x: f32,
        baseline: f32,
        pen: f32,
        advance: f32,
        size: f32,
        color: nogui.text.Color,
        clip_id: u32,
        z: u32,
        out: *std.ArrayList(SceneRect),
    ) void {
        // A missing codepoint must not disappear merely because glyph zero
        // has no outline in this font. Four solid strokes show a tofu box.
        const width = @max(4, @min(@max(advance, 0), size * 0.7));
        const height = @max(6, size * 0.75);
        const stroke = @max(1, @min(width, height) / 8);
        const box_x = run_x + pen + (advance - width) / 2;
        const box_y = baseline - height;
        self.appendLayoutSolid(
            .{ .x = box_x, .y = box_y, .width = width, .height = stroke },
            color,
            0,
            0,
            clip_id,
            z,
            out,
        );
        self.appendLayoutSolid(
            .{ .x = box_x, .y = box_y + height - stroke, .width = width, .height = stroke },
            color,
            0,
            0,
            clip_id,
            z,
            out,
        );
        self.appendLayoutSolid(
            .{ .x = box_x, .y = box_y + stroke, .width = stroke, .height = height - 2 * stroke },
            color,
            0,
            0,
            clip_id,
            z,
            out,
        );
        self.appendLayoutSolid(
            .{ .x = box_x + width - stroke, .y = box_y + stroke, .width = stroke, .height = height - 2 * stroke },
            color,
            0,
            0,
            clip_id,
            z,
            out,
        );
    }

    /// Paint the exact glyph ids, advances, run positions and fallback faces a
    /// `TextService` layout produced. Never reshape in this path. Keep the
    /// service alive until this engine is destroyed: FT borrows its font bytes.
    pub fn emitLayout(
        self: *TextEngine,
        service: *const cpu.TextService,
        layout: *const cpu.TextLayout,
        x: f32,
        y: f32,
        clip_id: u32,
        z: u32,
        out: *std.ArrayList(SceneRect),
    ) !void {
        var additional: usize = 0;
        for (layout.runs) |run| {
            additional += run.glyphs.len + @intFromBool(run.style.background != null) +
                @intFromBool(run.style.underline) + @intFromBool(run.style.strike);
            if (run.missing_glyph) {
                for (run.glyphs) |glyph| {
                    if (glyph.gid == 0) additional += 3;
                }
            }
        }
        try self.ensureSceneCapacity(out, additional);

        // A later styled run can overlap its predecessor through kerning.
        // Paint every background before any glyph on the same layer.
        for (layout.lines) |line| {
            for (layout.runs[line.first_run..line.end_run]) |run| {
                if (run.backgroundRect(line.height)) |background|
                    self.appendLayoutSolid(
                        background,
                        run.style.background.?,
                        x,
                        y,
                        clip_id,
                        z,
                        out,
                    );
            }
        }
        for (layout.runs) |run| {
            const size = try service.fontPixelSize(run.style.font.size);
            const font = try self.fontForLayout(service, run.font, size, run.style.font.weight);
            const run_x = snapToDeviceGrid(x + run.x, self.pixel_scale.x);
            const baseline = snapToDeviceGrid(y + run.baseline, self.pixel_scale.y);
            const color = self.layoutColor(run.style.foreground);
            var cursor: f32 = 0;
            for (run.glyphs) |glyph| {
                if (run.missing_glyph and glyph.gid == 0) {
                    self.appendNotdef(
                        run_x,
                        baseline,
                        cursor + glyph.x_offset,
                        glyph.x_advance,
                        run.style.font.size,
                        run.style.foreground,
                        clip_id,
                        z,
                        out,
                    );
                    cursor += glyph.x_advance;
                    continue;
                }
                const before = out.items.len;
                try self.emitGlyph(font, glyph, run_x, baseline, clip_id, color, out, &cursor);
                if (out.items.len != before) out.items[out.items.len - 1].z = z;
            }
        }
        for (layout.runs) |run| {
            const decoration_color = run.decorationColor();
            if (run.underlineRect()) |underline|
                self.appendLayoutSolid(underline, decoration_color, x, y, clip_id, z, out);
            if (run.strikeRect()) |strike|
                self.appendLayoutSolid(strike, decoration_color, x, y, clip_id, z, out);
        }
    }

    /// The ordinary caption path: lay the node out ONCE through the same
    /// request builder the measure seam uses, emit the runs that layout
    /// produced, then release it. Paint chooses no script, no fallback and no
    /// fonts of its own, so a caption can never measure one way and paint
    /// another.
    pub fn emitNodeText(
        self: *TextEngine,
        content: []const u8,
        node: nogui.text.NodeText,
        options: NodeLayoutOptions,
        x: f32,
        y: f32,
        clip_id: u32,
        z: u32,
        out: *std.ArrayList(SceneRect),
    ) !void {
        const zone = tracy.Zone.begin(.{ .name = "emitNodeText", .src = @src() });
        defer zone.end();
        // Released before the arena is reset: every shaped run's lease is
        // dropped, and the run itself stays resident in the shared cache, so
        // the next frame reuses it instead of shaping the text again.
        defer _ = self.scratch.reset(.retain_capacity);
        var layout = try self.service.nodeLayoutIn(
            self.scratch.allocator(),
            content,
            node,
            options,
            @as(f32, @floatFromInt(font_size_px)),
        );
        defer layout.release();
        // A caption is centered in its content box, and the text block's own
        // height is only known once it has been laid out.
        try self.emitLayout(
            &self.service,
            &layout,
            x,
            y + captionBlockInset(options, layout.height),
            clip_id,
            z,
            out,
        );
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
            .dst = glyphQuadRect(ch_x, ch_y, entry.glyph_w, entry.glyph_h, self.glyph_margin),
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

/// Return caller-owned curves, or null when a successful extraction proves
/// that this font state has no outline for `gid`.
fn extractGlyphCurvesCached(
    gpa: std.mem.Allocator,
    font: *FontState,
    gid: u32,
) !?[]renderer.Curve {
    if (font.knowsEmptyGlyph(gid)) return null;

    const curves = try extractGlyphCurves(gpa, font.hb_font, gid);
    if (curves.len > 0) return curves;

    gpa.free(curves);
    font.rememberEmptyGlyph(gid);
    return null;
}

/// Extract glyph curves for a specific SHAPED glyph id via HarfBuzz's
/// draw API (hb_font_draw_glyph_or_fail — the hb-ft backend emits the
/// outline in the font's scale, 26.6 fixed-point px; /64 → px). No
/// FreeType calls in our code: the face exists only as the hb-ft backend.
/// Callbacks fill a 4096-curve stack buffer (cubic segments split into two
/// conics at t=0.5), then the caller-owned slice is dupe'd via `alloc`.
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
    if (c.hb_font_draw_glyph_or_fail(font.handle, gid, funcs, &ctx) == 0) {
        return error.GlyphDrawFailed;
    }

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

    pub fn advance(self: *CountingAdvanceMeasurer, text: []const u8) f32 {
        self.call_count += 1;
        self.input_bytes_total += text.len;
        return @floatFromInt(text.len);
    }
};

fn measurementScanCount(snapshot: anytype) u64 {
    return snapshot.value(.hard_line_bytes_scanned) +
        snapshot.value(.segment_bytes_scanned) +
        snapshot.value(.segment_content_rescan_bytes);
}

fn expectLineRanges(text: []const u8, limit: f32, expected: []const LineRange) !void {
    var measurer: CountingAdvanceMeasurer = .{};
    var counter_sink = CounterSink.init(null);
    var ranges = LineRangeIterator.init(text, limit, &counter_sink);

    for (expected) |expected_range| {
        const actual = ranges.next(&measurer) orelse return error.MissingLineRange;
        try testing.expectEqual(expected_range.start, actual.start);
        try testing.expectEqual(expected_range.end, actual.end);
    }
    try testing.expect(ranges.next(&measurer) == null);
}

fn expectCachedLineRangesEqual(
    text: []const u8,
    limit: f32,
    expected_measurer: *ShapedAdvance,
    actual_measurer: *ShapedAdvance,
    counter_sink: *const CounterSink,
) !void {
    expected_measurer.reset();
    actual_measurer.reset();
    var expected_ranges = LineRangeIterator.init(text, limit, counter_sink);
    var actual_ranges = LineRangeIterator.init(text, limit, counter_sink);
    while (true) {
        const expected = expected_ranges.next(expected_measurer);
        const actual = actual_ranges.next(actual_measurer);
        if (expected == null or actual == null) {
            try testing.expect(expected == null);
            try testing.expect(actual == null);
            break;
        }
        try testing.expectEqual(expected.?.start, actual.?.start);
        try testing.expectEqual(expected.?.end, actual.?.end);
    }
}

test "cached measurements reuse intrinsic width and policy results" {
    // A trailing hard break makes max-content and single-line widths equal,
    // but their line counts differ. This detects a policy-key collision.
    var ft_lib: c.FT_Library = undefined;
    try testing.expectEqual(@as(c_int, 0), c.FT_Init_FreeType(&ft_lib));
    defer testing.expectEqual(@as(c_int, 0), c.FT_Done_FreeType(ft_lib)) catch unreachable;
    const font_data = test_fonts.inter;
    var face: c.FT_Face = undefined;
    try testing.expectEqual(
        @as(c_int, 0),
        c.FT_New_Memory_Face(ft_lib, font_data.ptr, @intCast(font_data.len), 0, &face),
    );
    defer testing.expectEqual(@as(c_int, 0), c.FT_Done_Face(face)) catch unreachable;
    try testing.expectEqual(@as(c_int, 0), c.FT_Set_Pixel_Sizes(face, 0, font_size_px));
    var font: hb.Font = .{
        .handle = c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed,
    };
    defer font.destroy();
    var buffer = try hb.Buffer.create();
    defer buffer.destroy();
    const text = "AV office e\u{301} alpha\u{200B}beta \xff\r\n";
    buffer.addUTF8(text);
    buffer.setDirection(.ltr);
    buffer.setScript(.latin);
    hb.shape(font, buffer, null);

    var counters: nogui.Counters = .{};
    var cache_sink = CounterSink.init(&counters);
    var cache = shaping.Cache.init(testing.allocator);
    defer cache.deinit();
    var cached = ShapedAdvance.initCached(try cache.acquire(
        .{ .font_id = 0, .size = font_size_px },
        font,
        text,
        &cache_sink,
    ));
    defer cached.deinit();
    var original = ShapedAdvance.init(text, &buffer);
    var uncached_sink = CounterSink.init(null);

    const expected_intrinsic = intrinsicMetrics(&original, text, &uncached_sink);
    const actual_intrinsic = intrinsicMetrics(&cached, text, &cache_sink);
    try testing.expectEqualDeep(expected_intrinsic, actual_intrinsic);
    try testing.expect(actual_intrinsic.min_width < actual_intrinsic.max_width);
    const scans_after_intrinsic = measurementScanCount(try counters.snapshot());
    if (comptime nogui.options.perf_counters) {
        try testing.expect(scans_after_intrinsic > 0);
    }

    try testing.expectEqualDeep(
        expected_intrinsic,
        intrinsicMetrics(&cached, text, &cache_sink),
    );
    try testing.expectEqual(
        scans_after_intrinsic,
        measurementScanCount(try counters.snapshot()),
    );

    const max_input: MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .line_policy = .flow,
    };
    const expected_max = measureByLinePolicy(&original, text, max_input, &uncached_sink);
    const actual_max = measureByLinePolicy(&cached, text, max_input, &cache_sink);
    try testing.expectEqualDeep(expected_max, actual_max);
    const scans_after_max = measurementScanCount(try counters.snapshot());
    if (comptime nogui.options.perf_counters) {
        try testing.expect(scans_after_max > scans_after_intrinsic);
    }

    var single_input = max_input;
    single_input.line_policy = .single_line;
    const expected_single = measureByLinePolicy(&original, text, single_input, &uncached_sink);
    const actual_single = measureByLinePolicy(&cached, text, single_input, &cache_sink);
    try testing.expectEqualDeep(expected_single, actual_single);
    try testing.expectEqual(actual_max.width, actual_single.width);
    try testing.expect(actual_max.line_count != actual_single.line_count);
    try testing.expectEqual(
        scans_after_max,
        measurementScanCount(try counters.snapshot()),
    );

    var equivalent_max_input = max_input;
    equivalent_max_input.available_space.width = .{ .definite = std.math.inf(f32) };
    try testing.expectEqualDeep(
        measureByLinePolicy(&original, text, equivalent_max_input, &uncached_sink),
        measureByLinePolicy(&cached, text, equivalent_max_input, &cache_sink),
    );
    try testing.expectEqual(
        scans_after_max,
        measurementScanCount(try counters.snapshot()),
    );

    const middle_width =
        actual_intrinsic.min_width +
        (actual_intrinsic.max_width - actual_intrinsic.min_width) / 2;
    var middle_input = max_input;
    middle_input.available_space.width = .{ .definite = middle_width };
    const expected_middle = measureByLinePolicy(&original, text, middle_input, &uncached_sink);
    const actual_middle = measureByLinePolicy(&cached, text, middle_input, &cache_sink);
    try testing.expectEqualDeep(expected_middle, actual_middle);
    const scans_after_middle = measurementScanCount(try counters.snapshot());
    if (comptime nogui.options.perf_counters) {
        try testing.expect(scans_after_middle > scans_after_max);
    }

    try testing.expectEqualDeep(
        expected_middle,
        measureByLinePolicy(&cached, text, middle_input, &cache_sink),
    );
    try testing.expectEqualDeep(
        expected_max,
        measureByLinePolicy(&cached, text, max_input, &cache_sink),
    );
    try testing.expectEqual(
        scans_after_middle,
        measurementScanCount(try counters.snapshot()),
    );
}

test "cached shaping preserves wrapping across width changes" {
    // Compare both cursors against real shaping, including multi-byte clusters and breaks.
    var ft_lib: c.FT_Library = undefined;
    try testing.expectEqual(@as(c_int, 0), c.FT_Init_FreeType(&ft_lib));
    defer testing.expectEqual(@as(c_int, 0), c.FT_Done_FreeType(ft_lib)) catch unreachable;
    const font_data = test_fonts.inter;
    var face: c.FT_Face = undefined;
    try testing.expectEqual(
        @as(c_int, 0),
        c.FT_New_Memory_Face(ft_lib, font_data.ptr, @intCast(font_data.len), 0, &face),
    );
    defer testing.expectEqual(@as(c_int, 0), c.FT_Done_Face(face)) catch unreachable;
    try testing.expectEqual(@as(c_int, 0), c.FT_Set_Pixel_Sizes(face, 0, font_size_px));
    var font: hb.Font = .{
        .handle = c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed,
    };
    defer font.destroy();
    var buffer = try hb.Buffer.create();
    defer buffer.destroy();
    const text = "AV office e\u{301}\r\nalpha\u{200B}beta \xff\n";
    buffer.addUTF8(text);
    buffer.setDirection(.ltr);
    buffer.setScript(.latin);
    hb.shape(font, buffer, null);
    var cache = shaping.Cache.init(testing.allocator);
    defer cache.deinit();
    const sink = CounterSink.init(null);
    var cached = ShapedAdvance.initCached(try cache.acquire(
        .{ .font_id = 0, .size = font_size_px },
        font,
        text,
        &sink,
    ));
    defer cached.deinit();
    var original = ShapedAdvance.init(text, &buffer);
    const widths = [_]WidthMode{
        .min_content,        .max_content,         .{ .definite = 14 },
        .{ .definite = 40 }, .{ .definite = 130 }, .{ .definite = 40 },
    };
    for (widths) |width| {
        original.reset();
        cached.reset();
        const expected = measureFlow(&original, text, width, &sink);
        const actual = measureFlow(&cached, text, width, &sink);
        try testing.expectEqualDeep(expected, actual);
        try expectCachedLineRangesEqual(text, actual.width, &original, &cached, &sink);
    }
}

test "text segmentation counters record scans and rescans" {
    var counters: nogui.Counters = .{};
    var sink = CounterSink.init(&counters);
    _ = nextTextSegment("alpha\n", 0, &sink);
    var snapshot = try counters.snapshot();
    if (comptime nogui.options.perf_counters) {
        try std.testing.expect(snapshot.value(.hard_line_bytes_scanned) > 0);
        try std.testing.expect(snapshot.value(.segment_bytes_scanned) > 0);
    } else {
        try std.testing.expectEqual(@as(u64, 0), snapshot.value(.hard_line_bytes_scanned));
        try std.testing.expectEqual(@as(u64, 0), snapshot.value(.segment_bytes_scanned));
    }
    _ = segmentHasContent("\xE2\x80\x8B", &sink);
    snapshot = try counters.snapshot();
    if (comptime nogui.options.perf_counters) {
        try std.testing.expect(snapshot.value(.segment_content_rescan_bytes) > 0);
    } else {
        try std.testing.expectEqual(@as(u64, 0), snapshot.value(.segment_content_rescan_bytes));
    }
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
    var counter_sink = CounterSink.init(null);
    const flow = measureFlow(&measurer, "alpha beta\ngamma delta", .max_content, &counter_sink);

    try testing.expectEqual(@as(f32, 11), flow.width);
    try testing.expectEqual(@as(usize, 2), flow.line_count);
}
test "measureFlow: leading separators do not reserve painted width" {
    var measurer: CountingAdvanceMeasurer = .{};
    var counter_sink = CounterSink.init(null);
    const flow = measureFlow(&measurer, "  alpha\n\tbeta", .max_content, &counter_sink);

    try testing.expectEqual(@as(f32, 5), flow.width);
    try testing.expectEqual(@as(usize, 2), flow.line_count);
}

test "single-line policy ignores hard-break glyph advances" {
    const input: MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .line_policy = .single_line,
    };
    var counter_sink = CounterSink.init(null);
    const flow = measureByLinePolicy(FallbackAdvance{}, "a\nbb", input, &counter_sink);

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
    var counter_sink = CounterSink.init(null);
    const line_count = wrappedLineCount(&measurer, &text, line_width, &counter_sink);

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
    const font_data = test_fonts.inter;
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
    // surround (glyphQuadRect: ch-2 / ceil+4) must leave the two outermost
    // pixel rings completely clear of ink — so even a bb that hits a
    // pixel as a sliver resolves its AA edge fully inside the quad.
    var ft_lib: c.FT_Library = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Init_FreeType(&ft_lib));
    defer _ = c.FT_Done_FreeType(ft_lib);
    const font_data = test_fonts.inter;
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

test "glyph sweep stays inside its raster quad at subpixel device scales" {
    // Two vertical conics bound a closed rectangular glyph in the same
    // y-up sweep space as the shader. Fractional ink edges expose a clipped
    // device fragment at 0.2x with the old fixed two-unit surround.
    const curves = [_]renderer.Curve{
        .{ .p0x = 0, .p0y = 0, .p1x = 0, .p1y = -4, .p2x = 0, .p2y = -8 },
        .{ .p0x = 8, .p0y = -8, .p1x = 8, .p1y = -4, .p2x = 8, .p2y = 0 },
    };
    const x: f32 = 9.75;
    const y: f32 = 9.75;
    const scales = [_]nogui.geometry.PixelScale{
        .{ .x = 0.2, .y = 0.2 },
        .{ .x = 0.4, .y = 0.4 },
        .{ .x = 0.5, .y = 0.5 },
        .{ .x = 1, .y = 1 },
        .{ .x = 1.25, .y = 1.25 },
        .{ .x = 2, .y = 2 },
        .{ .x = 2, .y = 1 },
        .{ .x = 0.2, .y = 2 },
    };
    for (scales) |scale| {
        const rect = glyphQuadRect(x, y, 8, 8, glyphRasterMargins(scale));
        const pixel = [2]f32{ 1.0 / scale.x, 1.0 / scale.y };
        var saw_ink = false;
        for (0..40) |row| {
            for (0..40) |col| {
                const cx = (@as(f32, @floatFromInt(col)) + 0.5) / scale.x;
                const cy = (@as(f32, @floatFromInt(row)) + 0.5) / scale.y;
                const offset = [2]f32{
                    cx - x - pixel[0] * 0.5,
                    y - cy - pixel[1] * 0.5,
                };
                var area: f32 = 0;
                for (curves) |curve| {
                    area += sweepSegment(
                        pixel,
                        offset,
                        .{ curve.p0x, curve.p0y },
                        .{ curve.p1x, curve.p1y },
                        .{ curve.p2x, curve.p2y },
                    );
                }
                if (@abs(area) <= 1e-4) continue;
                saw_ink = true;
                try std.testing.expect(cx >= rect[0] and cx < rect[0] + rect[2]);
                try std.testing.expect(cy >= rect[1] and cy < rect[1] + rect[3]);
            }
        }
        try std.testing.expect(saw_ink);
    }
}

test "shaping: the hb-ft font scale is 26.6 fixed-point pixels" {
    // Standalone FT + hb setup (no GPU): a shaped 'A' at 20px must advance
    // ~13px = 832 in 26.6 units — the shaper positions are /64.0 → px.
    var ft_lib: c.FT_Library = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Init_FreeType(&ft_lib));
    defer _ = c.FT_Done_FreeType(ft_lib);
    const font_data = test_fonts.inter;
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
    const font_data = test_fonts.inter;
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
    const font_data = test_fonts.inter;
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
    const font_data = test_fonts.inter;
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

// A run moves by whole device pixels, but its placement stays in logical units.
// Both single-line and wrapped text use this helper for the pen and baseline.
test "api-w02 text origin and baseline snap to device pixels" {
    const cases = [_]struct {
        scale: nogui.geometry.PixelScale,
        logical: nogui.geometry.WindowPoint,
        snapped: nogui.geometry.WindowPoint,
    }{
        .{
            .scale = .{ .x = 1, .y = 1 },
            .logical = .{ .x = 10.3, .y = 17.3 },
            .snapped = .{ .x = 10, .y = 17 },
        },
        .{
            .scale = .{ .x = 1.25, .y = 1.25 },
            .logical = .{ .x = 10.3, .y = 17.3 },
            .snapped = .{ .x = 10.4, .y = 17.6 },
        },
        .{
            .scale = .{ .x = 2, .y = 2 },
            .logical = .{ .x = 10.3, .y = 17.3 },
            .snapped = .{ .x = 10.5, .y = 17.5 },
        },
        .{
            .scale = .{ .x = 1.25, .y = 1.25 },
            .logical = .{ .x = -3.3, .y = 25.55 },
            .snapped = .{ .x = -3.2, .y = 25.6 },
        },
        .{
            .scale = .{ .x = 1.25, .y = 2 },
            .logical = .{ .x = -3.3, .y = 25.55 },
            .snapped = .{ .x = -3.2, .y = 25.5 },
        },
    };
    for (cases) |case| {
        const run_x = TextEngine.snapToDeviceGrid(case.logical.x, case.scale.x);
        const run_baseline = TextEngine.snapToDeviceGrid(case.logical.y, case.scale.y);
        try std.testing.expectApproxEqAbs(case.snapped.x, run_x, 0.00001);
        try std.testing.expectApproxEqAbs(case.snapped.y, run_baseline, 0.00001);
        try std.testing.expectApproxEqAbs(
            @round(case.logical.x * case.scale.x),
            run_x * case.scale.x,
            0.00001,
        );
        try std.testing.expectApproxEqAbs(
            @round(case.logical.y * case.scale.y),
            run_baseline * case.scale.y,
            0.00001,
        );
    }
}

// At 1x, snapping uses the same rounding and retains the old signed-zero bit.
test "api-w02 1x text origin snapping is bit-identical" {
    const origins = [_]f32{ -5.5, -5.4, -0.1, 0, 0.5, 10.3, 100.7, 123.456 };
    for (origins) |origin| {
        const expected: u32 = @bitCast(@round(origin));
        const actual: u32 = @bitCast(TextEngine.snapToDeviceGrid(origin, 1));
        try std.testing.expectEqual(expected, actual);
    }
}

const EmptyGlyphDrawProvider = struct {
    call_count: usize = 0,
    successful_call_count: usize = 0,
    failures_remaining: usize = 0,

    fn install(self: *EmptyGlyphDrawProvider, font: *FontState) !void {
        const funcs = c.hb_font_funcs_create() orelse return error.HarfbuzzFailed;
        defer c.hb_font_funcs_destroy(funcs);
        c.hb_font_funcs_set_draw_glyph_or_fail_func(
            funcs,
            drawGlyph,
            null,
            null,
        );

        const child_handle = c.hb_font_create_sub_font(font.hb_font.handle) orelse
            return error.HarfbuzzFailed;
        var child: hb.Font = .{ .handle = child_handle };
        errdefer child.destroy();
        c.hb_font_set_funcs(child_handle, funcs, self, null);

        var parent = font.hb_font;
        font.hb_font = child;
        parent.destroy();
    }

    fn drawGlyph(
        font_handle: ?*c.hb_font_t,
        font_data: ?*anyopaque,
        gid: c.hb_codepoint_t,
        draw_funcs: ?*c.hb_draw_funcs_t,
        draw_data: ?*anyopaque,
        user_data: ?*anyopaque,
    ) callconv(.c) c.hb_bool_t {
        _ = user_data;
        const self: *EmptyGlyphDrawProvider = @ptrCast(@alignCast(font_data orelse return 0));
        self.call_count += 1;
        if (self.failures_remaining > 0) {
            self.failures_remaining -= 1;
            return 0;
        }

        const parent = c.hb_font_get_parent(font_handle orelse return 0) orelse return 0;
        const succeeded = c.hb_font_draw_glyph_or_fail(
            parent,
            gid,
            draw_funcs,
            draw_data,
        );
        if (succeeded != 0) self.successful_call_count += 1;
        return succeeded;
    }
};

const EmptyGlyphCpuFixture = struct {
    engine: TextEngine,

    fn init(gpa: std.mem.Allocator) !EmptyGlyphCpuFixture {
        var service = try cpu.TextService.init(gpa);
        errdefer service.deinit();
        try TextEngine.registerFonts(&service, &.{
            .{ .family = "InterVariable", .bytes = test_fonts.inter },
            .{ .family = "Fira Code Nerd Font", .bytes = test_fonts.fira },
        });
        // SAFETY: no GPU field is ever read on a CPU-only fixture. The
        // material budget below is exactly zero, so the engine's own guard
        // returns error.TooManyGlyphs before GlyphSweeper can touch the
        // undefined `gpu` pointer or the empty material buffer, and this
        // fixture's deinit frees neither. Every OTHER field is written here:
        // the engine starts as `undefined`, and an unwritten `node_measurer`
        // is not null, so measurer() hands core a garbage MeasureSource
        // context and the measure hook faults inside the service.
        var engine: TextEngine = undefined;
        engine.gpa = gpa;
        engine.pixel_scale = .{ .x = 1, .y = 1 };
        engine.glyph_margin = .{ 2, 2 };
        engine.fonts = @splat(null);
        engine.sweepers = .empty;
        engine.entries = .empty;
        engine.scratch = std.heap.ArenaAllocator.init(gpa);
        engine.node_measurer = null;
        engine.materials = .{};
        engine.next_slot = max_materials;
        engine.material_bda = 0;
        engine.glyph_slot_limit = max_materials;
        engine.service = service;
        engine.counter_sink = CounterSink.init(null);
        engine.cached_color_count = 0;
        engine.next_color = 0;
        return .{ .engine = engine };
    }

    fn deinit(self: *EmptyGlyphCpuFixture) void {
        const gpa = self.engine.gpa;
        self.engine.sweepers.deinit(gpa);
        self.engine.entries.deinit(gpa);
        for (&self.engine.fonts) |*optional_font| {
            if (optional_font.*) |*font| font.deinit(gpa);
        }
        self.engine.service.deinit();
        self.engine.scratch.deinit();
        self.* = undefined;
    }
};

fn emptySpaceGlyphId(font: *const FontState) !u32 {
    const gid: u32 = @intCast(c.FT_Get_Char_Index(font.face, ' '));
    if (gid == 0) return error.SpaceGlyphMissing;
    return gid;
}

fn glyphEntryForTest(font: *const FontState, gid: u32, slot: u32) GlyphEntry {
    return .{
        .gid = gid,
        .size = font.size,
        .font_id = font.font_id,
        .slot = slot,
        .advance = 0,
        .bearing_x = 0,
        .bearing_y = 0,
        .glyph_w = 0,
        .glyph_h = 0,
        .curve_left = 0,
        .curve_bottom = 0,
        .curve_w = 0,
        .curve_h = 0,
    };
}

// A resident glyph must resolve through its owning font-and-size state. The
// exact upper FreeType glyph bound and gid 0 must not probe the dense table.
test "glyph index is bounded and owned by font state" {
    var fixture = try EmptyGlyphCpuFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const inter_18 = try fixture.engine.fontFor(0, 18);
    const fira_18 = try fixture.engine.fontFor(1, 18);
    const inter_29 = try fixture.engine.fontFor(0, 29);
    const gid: u32 = 1;

    const inter_18_index = fixture.engine.entries.items.len;
    try fixture.engine.entries.append(
        std.testing.allocator,
        glyphEntryForTest(inter_18, gid, 11),
    );
    inter_18.rememberGlyphEntry(gid, inter_18_index);

    const fira_18_index = fixture.engine.entries.items.len;
    try fixture.engine.entries.append(
        std.testing.allocator,
        glyphEntryForTest(fira_18, gid, 12),
    );
    fira_18.rememberGlyphEntry(gid, fira_18_index);

    const inter_29_index = fixture.engine.entries.items.len;
    try fixture.engine.entries.append(
        std.testing.allocator,
        glyphEntryForTest(inter_29, gid, 13),
    );
    inter_29.rememberGlyphEntry(gid, inter_29_index);

    try std.testing.expectEqual(inter_18_index, fixture.engine.glyphIndex(inter_18, gid).?);
    try std.testing.expectEqual(fira_18_index, fixture.engine.glyphIndex(fira_18, gid).?);
    try std.testing.expectEqual(inter_29_index, fixture.engine.glyphIndex(inter_29, gid).?);

    const glyph_count = std.math.cast(u32, inter_18.face.*.num_glyphs) orelse
        return error.GlyphCountTooLarge;
    try std.testing.expect(fixture.engine.glyphIndex(inter_18, 0) == null);
    try std.testing.expect(fixture.engine.glyphIndex(inter_18, glyph_count) == null);
    try std.testing.expect(
        fixture.engine.glyphIndex(inter_18, std.math.maxInt(u32)) == null,
    );
}

// A failed second FontState allocation must release the first allocation. The
// unused font slot must remain available for a successful retry.
test "font state allocation failure releases ownership and retries" {
    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{},
    );
    const gpa = failing_allocator.allocator();
    {
        var fixture = try EmptyGlyphCpuFixture.init(gpa);
        defer fixture.deinit();

        failing_allocator.fail_index = failing_allocator.alloc_index + 1;
        try std.testing.expectError(
            error.OutOfMemory,
            fixture.engine.fontFor(0, 24),
        );
        try std.testing.expect(failing_allocator.has_induced_failure);

        failing_allocator.fail_index = std.math.maxInt(usize);
        _ = try fixture.engine.fontFor(0, 24);
    }
    try std.testing.expectEqual(
        failing_allocator.allocated_bytes,
        failing_allocator.freed_bytes,
    );
}

// The exact upper glyph bound still reaches HarfBuzz. A provider failure must
// remain uncached and retryable instead of becoming a dense-index miss result.
test "out-of-range glyph draw remains retryable and unindexed" {
    var fixture = try EmptyGlyphCpuFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const font = try fixture.engine.fontFor(0, 25);
    var provider: EmptyGlyphDrawProvider = .{};
    try provider.install(font);
    const gid = std.math.cast(u32, font.face.*.num_glyphs) orelse
        return error.GlyphCountTooLarge;

    try std.testing.expect((try fixture.engine.ensureGlyph(font, gid)) == null);
    try std.testing.expectEqual(@as(usize, 1), provider.call_count);
    try std.testing.expectEqual(@as(usize, 0), provider.successful_call_count);
    try std.testing.expect(fixture.engine.glyphIndex(font, gid) == null);

    try std.testing.expect((try fixture.engine.ensureGlyph(font, gid)) == null);
    try std.testing.expectEqual(@as(usize, 2), provider.call_count);
    try std.testing.expectEqual(@as(usize, 0), provider.successful_call_count);
    try std.testing.expect(fixture.engine.glyphIndex(font, gid) == null);
}

// A material-budget failure must not consume a slot or publish a positive
// index. The next request must retry the provider.
test "material budget failure remains retryable and unpublished" {
    var fixture = try EmptyGlyphCpuFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const font = try fixture.engine.fontFor(0, 26);
    var provider: EmptyGlyphDrawProvider = .{};
    try provider.install(font);
    const gid: u32 = @intCast(c.FT_Get_Char_Index(font.face, 'A'));
    try std.testing.expect(gid != 0);
    const material_count = fixture.engine.glyphSlotCount();

    try std.testing.expectError(
        error.TooManyGlyphs,
        fixture.engine.ensureGlyph(font, gid),
    );
    try std.testing.expect(fixture.engine.glyphIndex(font, gid) == null);
    try std.testing.expectEqual(@as(usize, 1), provider.call_count);
    try std.testing.expectEqual(@as(usize, 1), provider.successful_call_count);
    try std.testing.expectEqual(material_count, fixture.engine.glyphSlotCount());

    try std.testing.expectError(
        error.TooManyGlyphs,
        fixture.engine.ensureGlyph(font, gid),
    );
    try std.testing.expect(fixture.engine.glyphIndex(font, gid) == null);
    try std.testing.expectEqual(@as(usize, 2), provider.call_count);
    try std.testing.expectEqual(@as(usize, 2), provider.successful_call_count);
    try std.testing.expectEqual(material_count, fixture.engine.glyphSlotCount());
}

/// Find a real common glyph id whose outline is empty in one font and inked
/// in another. The face-reported glyph counts bound the scan; no glyph id is
/// assumed from either font's character map.
fn findEmptyInkGlyphId(
    gpa: std.mem.Allocator,
    empty_font: *const FontState,
    ink_font: *const FontState,
) !u32 {
    const empty_count = std.math.cast(u32, empty_font.face.*.num_glyphs) orelse
        return error.GlyphCountTooLarge;
    const ink_count = std.math.cast(u32, ink_font.face.*.num_glyphs) orelse
        return error.GlyphCountTooLarge;
    const limit = @min(empty_count, ink_count);

    var gid: u32 = 1;
    while (gid < limit) : (gid += 1) {
        const empty_curves = extractGlyphCurves(gpa, empty_font.hb_font, gid) catch |err| switch (err) {
            error.GlyphNotFound, error.GlyphDrawFailed => continue,
            else => return err,
        };
        const is_empty = empty_curves.len == 0;
        gpa.free(empty_curves);
        if (!is_empty) continue;

        const ink_curves = extractGlyphCurves(gpa, ink_font.hb_font, gid) catch |err| switch (err) {
            error.GlyphNotFound, error.GlyphDrawFailed => continue,
            else => return err,
        };
        const is_ink = ink_curves.len > 0;
        gpa.free(ink_curves);
        if (is_ink) return gid;
    }
    return error.CommonEmptyInkGlyphNotFound;
}

// The real provider succeeds for the space glyph but emits no outline. The
// second request must stop before the provider and leave the material budget
// unchanged.
test "successful empty glyph extraction is retained without a material" {
    var fixture = try EmptyGlyphCpuFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const font = try fixture.engine.fontFor(0, font_size_px);
    var provider: EmptyGlyphDrawProvider = .{};
    try provider.install(font);
    const gid = try emptySpaceGlyphId(font);
    const material_count = fixture.engine.glyphSlotCount();

    try std.testing.expect((try fixture.engine.ensureGlyph(font, gid)) == null);
    try std.testing.expectEqual(@as(usize, 1), provider.call_count);
    try std.testing.expectEqual(@as(usize, 1), provider.successful_call_count);
    try std.testing.expectEqual(material_count, fixture.engine.glyphSlotCount());

    try std.testing.expect((try fixture.engine.ensureGlyph(font, gid)) == null);
    try std.testing.expectEqual(@as(usize, 1), provider.call_count);
    try std.testing.expectEqual(@as(usize, 1), provider.successful_call_count);
    try std.testing.expectEqual(material_count, fixture.engine.glyphSlotCount());
}

// Space glyph IDs are font-specific. Find a real same-gid empty/ink pair
// instead of assuming that the two fonts share the space glyph ID.
test "empty glyph retention is isolated by font identity and pixel size" {
    var fixture = try EmptyGlyphCpuFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const inter_18 = try fixture.engine.fontFor(0, 18);
    const fira_18 = try fixture.engine.fontFor(1, 18);
    const inter_29 = try fixture.engine.fontFor(0, 29);

    const inter_space_gid = try emptySpaceGlyphId(inter_18);
    const inter_29_space_gid = try emptySpaceGlyphId(inter_29);
    try std.testing.expectEqual(inter_space_gid, inter_29_space_gid);

    // This alias is empty in Fira but has real curves in Inter. A cached
    // negative result must not cross the font identity boundary.
    const common_gid = try findEmptyInkGlyphId(
        std.testing.allocator,
        fira_18,
        inter_18,
    );
    var fira_18_provider: EmptyGlyphDrawProvider = .{};
    var inter_18_provider: EmptyGlyphDrawProvider = .{};
    var inter_29_provider: EmptyGlyphDrawProvider = .{};
    try fira_18_provider.install(fira_18);
    try inter_18_provider.install(inter_18);
    try inter_29_provider.install(inter_29);

    // max_materials is a CPU-only sentinel: a real ink glyph must stop before
    // GlyphSweeper touches the fixture's intentionally uninitialized GPU data.
    const material_count = fixture.engine.glyphSlotCount();

    try std.testing.expect(
        (try fixture.engine.ensureGlyph(fira_18, common_gid)) == null,
    );
    try std.testing.expectError(
        error.TooManyGlyphs,
        fixture.engine.ensureGlyph(inter_18, common_gid),
    );
    try std.testing.expect(fixture.engine.glyphIndex(inter_18, common_gid) == null);
    try std.testing.expectEqual(@as(usize, 1), fira_18_provider.call_count);
    try std.testing.expectEqual(@as(usize, 1), fira_18_provider.successful_call_count);
    try std.testing.expectEqual(@as(usize, 1), inter_18_provider.call_count);
    try std.testing.expectEqual(@as(usize, 1), inter_18_provider.successful_call_count);
    try std.testing.expectEqual(material_count, fixture.engine.glyphSlotCount());

    // The Fira negative result is retained only for Fira's state.
    try std.testing.expect(
        (try fixture.engine.ensureGlyph(fira_18, common_gid)) == null,
    );
    try std.testing.expectEqual(@as(usize, 1), fira_18_provider.call_count);
    try std.testing.expectEqual(@as(usize, 1), fira_18_provider.successful_call_count);

    // Inter's own space is empty at 18px. The same gid at 29px must still
    // reach its distinct font-size state before it is retained there.
    try std.testing.expect(
        (try fixture.engine.ensureGlyph(inter_18, inter_space_gid)) == null,
    );
    try std.testing.expect(
        (try fixture.engine.ensureGlyph(inter_29, inter_space_gid)) == null,
    );
    try std.testing.expectEqual(@as(usize, 2), inter_18_provider.call_count);
    try std.testing.expectEqual(@as(usize, 2), inter_18_provider.successful_call_count);
    try std.testing.expectEqual(@as(usize, 1), inter_29_provider.call_count);
    try std.testing.expectEqual(@as(usize, 1), inter_29_provider.successful_call_count);
    try std.testing.expectEqual(material_count, fixture.engine.glyphSlotCount());
}

// A provider failure emits no curves but is not a successful empty outline.
// The next request must reach the real parent; only that success may be cached.
test "failed empty glyph draw is retried before successful retention" {
    var fixture = try EmptyGlyphCpuFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const font = try fixture.engine.fontFor(0, 21);
    var provider: EmptyGlyphDrawProvider = .{ .failures_remaining = 1 };
    try provider.install(font);
    const gid = try emptySpaceGlyphId(font);
    const material_count = fixture.engine.glyphSlotCount();

    try std.testing.expect((try fixture.engine.ensureGlyph(font, gid)) == null);
    try std.testing.expectEqual(@as(usize, 1), provider.call_count);
    try std.testing.expectEqual(@as(usize, 0), provider.successful_call_count);

    try std.testing.expect((try fixture.engine.ensureGlyph(font, gid)) == null);
    try std.testing.expectEqual(@as(usize, 2), provider.call_count);
    try std.testing.expectEqual(@as(usize, 1), provider.successful_call_count);

    try std.testing.expect((try fixture.engine.ensureGlyph(font, gid)) == null);
    try std.testing.expectEqual(@as(usize, 2), provider.call_count);
    try std.testing.expectEqual(@as(usize, 1), provider.successful_call_count);
    try std.testing.expectEqual(material_count, fixture.engine.glyphSlotCount());
}

// Force the allocation that copies a real nonempty outline to fail after the
// font state's bitmap allocation. A retry must extract again, and teardown must
// return both successful allocations to the backing test allocator.
test "outline allocation failure remains retryable and releases ownership" {
    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{},
    );
    const gpa = failing_allocator.allocator();
    {
        var fixture = try EmptyGlyphCpuFixture.init(gpa);
        defer fixture.deinit();
        const font = try fixture.engine.fontFor(0, 23);
        var provider: EmptyGlyphDrawProvider = .{};
        try provider.install(font);
        const gid: u32 = @intCast(c.FT_Get_Char_Index(font.face, 'A'));
        try std.testing.expect(gid != 0);

        failing_allocator.fail_index = failing_allocator.alloc_index;
        try std.testing.expectError(
            error.OutOfMemory,
            extractGlyphCurvesCached(gpa, font, gid),
        );
        try std.testing.expect(failing_allocator.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 1), provider.call_count);
        try std.testing.expectEqual(@as(usize, 1), provider.successful_call_count);

        failing_allocator.fail_index = std.math.maxInt(usize);
        const curves = (try extractGlyphCurvesCached(gpa, font, gid)) orelse
            return error.DrawableGlyphReportedEmpty;
        defer gpa.free(curves);
        try std.testing.expect(curves.len > 0);
        try std.testing.expectEqual(@as(usize, 2), provider.call_count);
        try std.testing.expectEqual(@as(usize, 2), provider.successful_call_count);
    }
    try std.testing.expectEqual(
        failing_allocator.allocated_bytes,
        failing_allocator.freed_bytes,
    );
}

test "api-w11 scene adapter paints cached glyph ids from fallback faces" {
    var service = try cpu.TextService.init(testing.allocator);
    defer service.deinit();
    const inter = try service.addFont(.{ .family = "Inter", .bytes = test_fonts.inter });
    const fira = try service.addFont(.{ .family = "Fira", .bytes = test_fonts.fira });
    var fixture = try EmptyGlyphCpuFixture.init(testing.allocator);
    defer fixture.deinit();
    fixture.engine.glyph_margin = .{ 2, 2 };

    // U+E0BE is a Nerd Font private-use glyph Fira covers and Inter does
    // not. InterVariable maps U+E0B0 itself, so a powerline codepoint alone
    // never reaches the fallback: face selection follows the primary
    // face's cmap, not the glyph's intended family.
    var layout = try service.layout(testing.allocator, .{
        .content = "A\xee\x82\xbe",
        .style = .{
            .font = .{ .handle = inter, .fallback = &.{fira}, .size = 22, .weight = 600 },
            .foreground = .{ 1, 0, 0, 1 },
            .background = .{ 0, 1, 0, 1 },
            .underline = true,
            .strike = true,
        },
    });
    defer layout.deinit();
    try testing.expectEqual(@as(usize, 2), layout.runs.len);

    for (layout.runs, 0..) |run, index| {
        const font = try fixture.engine.fontForLayout(&service, run.font, 22, 600);
        try testing.expectEqual(run.font.generation, font.source_generation);
        try testing.expectEqual(@as(u16, 600), font.weight);
        try testing.expectEqual(if (index == 0) inter.index else fira.index, run.font.index);
        try testing.expectEqual(@as(usize, 1), run.glyphs.len);
        const gid = run.glyphs[0].gid;
        try testing.expect(gid != 0);
        const expected_char: u32 = if (index == 0) 'A' else 0xe0be;
        try testing.expectEqual(gid, @as(u32, @intCast(c.FT_Get_Char_Index(font.face, expected_char))));
        const entry_index = fixture.engine.entries.items.len;
        try fixture.engine.entries.append(testing.allocator, .{
            .gid = gid,
            .size = 22,
            .font_id = @intCast(run.font.index),
            .slot = @intCast(index + 1),
            .advance = 0,
            .bearing_x = 0,
            .bearing_y = 0,
            .glyph_w = 7,
            .glyph_h = 11,
            .curve_left = 0,
            .curve_bottom = 0,
            .curve_w = 7,
            .curve_h = 11,
        });
        font.rememberGlyphEntry(gid, entry_index);
    }

    var rects: std.ArrayList(SceneRect) = .empty;
    defer rects.deinit(testing.allocator);
    try fixture.engine.emitLayout(&service, &layout, 10, 20, 3, 7, &rects);
    try testing.expectEqual(@as(usize, 8), rects.items.len);
    for (rects.items[0..2]) |rect| {
        try testing.expectEqual(@as(u32, 0), rect.material_index);
        try testing.expectEqual(srgbToOklab(.{ 0, 1, 0, 1 }), rect.color);
    }
    for (rects.items[2..4], layout.runs, 0..) |rect, run, index| {
        try testing.expectEqual(@as(u32, @intCast(index + 1)), rect.material_index);
        try testing.expectEqual(srgbToOklab(.{ 1, 0, 0, 1 }), rect.color);
        try testing.expectApproxEqAbs(
            @round(@as(f32, 10) + run.x) + run.glyphs[0].x_offset,
            rect.origin[0],
            0.001,
        );
        try testing.expectApproxEqAbs(
            @round(@as(f32, 20) + run.baseline) - run.glyphs[0].y_offset,
            rect.origin[1],
            0.001,
        );
    }
    for (rects.items[4..]) |rect| {
        try testing.expectEqual(@as(u32, 0), rect.material_index);
    }
    for (rects.items) |rect| {
        try testing.expectEqual(@as(u32, 3), rect.clip_id);
        try testing.expectEqual(@as(u32, 7), rect.z);
    }
}

test "api-w11 missing glyph policy paints a visible notdef marker" {
    var service = try cpu.TextService.init(testing.allocator);
    defer service.deinit();
    const inter = try service.addFont(.{ .family = "Inter", .bytes = test_fonts.inter });
    var fixture = try EmptyGlyphCpuFixture.init(testing.allocator);
    defer fixture.deinit();
    fixture.engine.glyph_margin = .{ 2, 2 };
    var layout = try service.layout(testing.allocator, .{
        .content = "\xf4\x8f\xbf\xbd",
        .style = .{ .font = .{ .handle = inter, .size = 20 }, .foreground = .{ 1, 0, 0, 1 } },
    });
    defer layout.deinit();
    try testing.expectEqual(@as(usize, 1), layout.runs.len);
    try testing.expect(layout.runs[0].missing_glyph);
    try testing.expectEqual(@as(u32, 0), layout.runs[0].glyphs[0].gid);
    var rects: std.ArrayList(SceneRect) = .empty;
    defer rects.deinit(testing.allocator);
    try fixture.engine.emitLayout(&service, &layout, 5, 6, 2, 4, &rects);
    try testing.expectEqual(@as(usize, 4), rects.items.len);
    for (rects.items) |rect| {
        try testing.expectEqual(@as(u32, 0), rect.material_index);
        try testing.expectEqual(@as(u32, 2), rect.clip_id);
        try testing.expectEqual(@as(u32, 4), rect.z);
        try testing.expectEqual(srgbToOklab(.{ 1, 0, 0, 1 }), rect.color);
        try testing.expect(rect.dst[2] > 0 and rect.dst[3] > 0);
    }
}

/// Register a resident entry for every glyph a layout will paint, so the
/// emit path never reaches the GPU rasterizer. The engine is CPU-only here,
/// and a layout's runs are the cached ones the next identical request reuses.
fn retainRunsForTest(
    gpa: std.mem.Allocator,
    engine: *TextEngine,
    service: *const cpu.TextService,
    layout: *const cpu.TextLayout,
) !void {
    for (layout.runs) |run| {
        const size = try service.fontPixelSize(run.style.font.size);
        const font = try engine.fontForLayout(service, run.font, size, run.style.font.weight);
        for (run.glyphs) |glyph| {
            if (glyph.gid == 0) continue;
            if (engine.glyphIndex(font, glyph.gid)) |existing| {
                _ = existing;
                continue;
            }
            const entry_index = engine.entries.items.len;
            try engine.entries.append(gpa, .{
                .gid = glyph.gid,
                .size = size,
                .font_id = @intCast(run.font.index),
                .slot = @intCast(entry_index + 1),
                .advance = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .glyph_w = 7,
                .glyph_h = 11,
                .curve_left = 0,
                .curve_bottom = 0,
                .curve_w = 7,
                .curve_h = 11,
            });
            font.rememberGlyphEntry(glyph.gid, entry_index);
        }
    }
}

// The ordinary caption path: one request, one layout, the runs that layout
// produced. Styled runs keep their own color, a fallback face keeps its own
// glyphs, and a character neither face covers paints a visible tofu box
// instead of disappearing.
test "api-w11 the caption path paints styled, fallback and notdef runs" {
    var fixture = try EmptyGlyphCpuFixture.init(testing.allocator);
    defer fixture.deinit();
    fixture.engine.glyph_margin = .{ 2, 2 };
    const service = &fixture.engine.service;

    // "a" + U+E0BE (Fira only) + U+FFFD (neither face), with "a" styled.
    const content = "a\xee\x82\xbe\xf4\x8f\xbf\xbd";
    const ranges = [_]nogui.text.StyledRange{
        .{ .range = .{ .start = 0, .end = 1 }, .override = .{ .foreground = .{ 0, 0, 1, 1 } } },
    };
    const node: nogui.text.NodeText = .{
        .style = .{
            .font = .{
                // Resolved by exact (case-insensitive) equality against a
                // registered FontInfo, so the request must name the family
                // this fixture actually registered.
                .family = "InterVariable",
                .size = font_size_px,
                .fallback = &.{service.listFonts()[1].handle},
            },
            .foreground = .{ 1, 0, 0, 1 },
        },
        .extra = &.{ .ranges = &ranges },
    };
    const options: cpu.NodeLayoutOptions = .{ .width = null, .box_height = 60 };

    // The same content, style and ranges, so this layout is the one the emit
    // path reuses: the runs and their cached glyphs are already resident.
    var probe = try service.layout(testing.allocator, .{
        .content = content,
        .style = node.style,
        .ranges = &ranges,
    });
    defer probe.release();
    try testing.expect(probe.runs.len >= 3);
    try retainRunsForTest(testing.allocator, &fixture.engine, service, &probe);

    var rects: std.ArrayList(SceneRect) = .empty;
    defer rects.deinit(testing.allocator);
    try fixture.engine.emitNodeText(content, node, options, 5, 6, 2, 4, &rects);
    const expected_rects = rects.items.len;
    try testing.expect(expected_rects > 0);

    var saw_styled = false;
    var saw_fallback = false;
    var saw_tofu = false;
    for (rects.items) |rect| {
        try testing.expectEqual(@as(u32, 2), rect.clip_id);
        try testing.expectEqual(@as(u32, 4), rect.z);
        const blue = srgbToOklab(.{ 0, 0, 1, 1 });
        const red = srgbToOklab(.{ 1, 0, 0, 1 });
        if (std.mem.eql(u8, std.mem.asBytes(&rect.color), std.mem.asBytes(&blue))) saw_styled = true;
        if (std.mem.eql(u8, std.mem.asBytes(&rect.color), std.mem.asBytes(&red))) {
            if (rect.material_index == 0 and rect.dst[2] > 0 and rect.dst[3] > 0) saw_tofu = true;
            if (rect.material_index != 0) saw_fallback = true;
        }
    }
    try testing.expect(saw_styled);
    try testing.expect(saw_fallback);
    try testing.expect(saw_tofu);

    // The caption is centered in its box, so the first glyph sits below the
    // top edge the box starts at.
    try testing.expect(rects.items[0].origin[1] > 6);

    // Repeating the caption reuses the scratch blocks and the cached runs:
    // the arena never grows and every pass emits the same scene.
    const settled_capacity = fixture.engine.scratch.queryCapacity();
    var pass: usize = 1;
    while (pass < 8) : (pass += 1) {
        rects.clearRetainingCapacity();
        try fixture.engine.emitNodeText(content, node, options, 5, 6, 2, 4, &rects);
        try testing.expectEqual(expected_rects, rects.items.len);
        try testing.expectEqual(settled_capacity, fixture.engine.scratch.queryCapacity());
    }
}

// The measure hook and the caption path must agree: a box measured at a
// width paints the layout of that same request, from the same runs.
test "api-w11 the measure hook and the caption path share one request" {
    var fixture = try EmptyGlyphCpuFixture.init(testing.allocator);
    defer fixture.deinit();
    const service = &fixture.engine.service;
    const content = "alpha beta gamma delta";
    const node: nogui.text.NodeText = .{
        // The registered family, for the same reason as the caption-path
        // test above: the resolver matches a registered FontInfo exactly.
        .style = .{ .font = .{ .family = "InterVariable", .size = font_size_px } },
    };
    const width: f32 = 70;
    const input: nogui.layout.MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .{ .definite = width }, .height = .max_content },
        .text = &node,
    };
    const source = fixture.engine.measurer();
    const measured = try source.callback(source.context, content, input);
    try testing.expect(measured.width <= width);
    try testing.expect(measured.first_baseline != null);

    // The caption path builds the layout of that same request, and reports the
    // same width, the same height and the same first shaped baseline.
    var scratch: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var layout = try service.layoutIn(scratch.allocator(), .{
        .content = content,
        .style = node.style,
        .paragraph = .{ .wrap = .flow, .wrap_width = width },
    });
    defer layout.release();
    // The box really wrapped, so the agreement is not a single-line accident.
    try testing.expect(layout.lines.len > 1);
    try testing.expectApproxEqAbs(measured.width, layout.width, 0.001);
    try testing.expectApproxEqAbs(measured.height, layout.height, 0.001);
    try testing.expectApproxEqAbs(
        measured.first_baseline orelse 0,
        layout.runs[0].baseline,
        0.001,
    );

    // The hook is bound once, so a second call through the source the host
    // kept measures the same content identically.
    const again = try source.callback(source.context, content, input);
    try testing.expectApproxEqAbs(measured.width, again.width, 0.0001);
    try testing.expectApproxEqAbs(measured.height, again.height, 0.0001);
    try testing.expectEqual(measured.first_baseline, again.first_baseline);
}
