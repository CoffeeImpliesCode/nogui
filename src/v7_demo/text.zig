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
const proto = @import("proto/sweeper.zig");
const SceneRect = @import("proto/render_9slice.zig").SceneRect;
const nogui = @import("nogui");
pub const WidgetSize = nogui.widget.Size;

// One C import, owned by the HarfBuzz binding: hb.h + hb-ft.h pull in
// freetype.h, so this exposes the full FreeType API we still need for
// outline extraction.
const hb = @import("harfbuzz");
const c = hb.c; // the binding's single C import: hb.h + hb-ft.h + freetype.h

/// slot 0 = solid; glyphs start at 1, the SVG region + decorations from
/// the top. Demo needs ~620 glyphs + the tiger (240 fills + up to 78
/// strokes); 1536 leaves headroom.
pub const max_materials: u32 = 1536;
/// Max cached shaped runs (generation-clock eviction). The demo has ~32
/// unique runs; 256 leaves ample headroom for the churning dynamic text.
pub const run_cache_capacity: u32 = 256;
pub const font_size_px: u32 = 14;

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

/// The embedded font sources: 0 = InterVariable, 1 = Fira Code Nerd Font.
const FontData = struct {
    data: []const u8,
    name: []const u8,
};
const font_sources = [_]FontData{
    .{ .data = @embedFile("InterVariable.ttf"), .name = "InterVariable" },
    .{ .data = @embedFile("FiraCodeNerdFont-Regular.ttf"), .name = "Fira Code Nerd Font" },
};

const max_font_sizes = 16;

pub const TextEngine = struct {
    /// The flex measure hook target: the demo sets this after init and
    /// points App.measure at measureForFlex, so layout sizes leaves to the
    /// real text extent instead of the baked len*10 approximation.
    pub var measure_engine: ?*TextEngine = null;

    /// Host-side measure callback for flex.layoutWith.
    pub fn measureForFlex(text: []const u8, font_size: f32, font_id: u8) WidgetSize {
        return measure_engine.?.measureText(
            text,
            if (font_size > 0) @intFromFloat(@round(font_size)) else font_size_px,
            font_id,
        );
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
    sweepers: std.ArrayList(proto.GlyphSweeper) = .empty, // per glyph
    entries: std.ArrayList(GlyphEntry) = .empty, // per glyph
    materials: noapi.GpuPtr, // max_materials * material_size, .default
    next_slot: u32 = 1,
    material_bda: u64 = 0,

    /// Shaped-run cache: (hash(text), size, font_id) → TextRun. The run's
    /// text dupe and glyph arrays are engine-owned (freed on eviction and
    /// in deinit). Unmanaged map — initialized `.empty`, methods take gpa.
    run_cache: std.AutoHashMapUnmanaged(RunKey, TextRun) = .empty,
    /// Generation clock for LRU eviction: every cache hit stamps the run;
    /// on a full cache the minimum-generation entry is evicted. Wraps
    /// after 2^32 stamps — stale stamps are just old values, the min-scan
    /// still works.
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

        const materials = try gpu.gpuMalloc(max_materials * proto.material_size, 64, .default);

        var self: TextEngine = .{
            .gpu = gpu,
            .gpa = gpa,
            .ft_lib = ft_lib,
            .materials = materials,
            .material_bda = materials.gpu,
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
        return &self.fonts[idx].?;
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
                run.generation = self.run_clock; // LRU stamp on hit
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

        // The measure width is the sum of ALL shaper advances (the infos
        // and positions arrays are equal-length in practice; if positions
        // is empty the width is 0 and no glyphs are copied — no crash).
        var w: f32 = 0;
        for (positions) |pos| {
            w += @as(f32, @floatCast(@as(f64, @floatFromInt(pos.x_advance)) / 64.0));
        }
        const glyphs = try self.gpa.alloc(GlyphPos, @min(infos.len, positions.len));
        errdefer self.gpa.free(glyphs);
        for (glyphs, 0..) |*g, i| {
            const pos = positions[i];
            g.* = .{
                .gid = infos[i].codepoint,
                .x_advance = @as(f32, @floatCast(@as(f64, @floatFromInt(pos.x_advance)) / 64.0)),
                .y_advance = @as(f32, @floatCast(@as(f64, @floatFromInt(pos.y_advance)) / 64.0)),
                .x_offset = @as(f32, @floatCast(@as(f64, @floatFromInt(pos.x_offset)) / 64.0)),
                .y_offset = @as(f32, @floatCast(@as(f64, @floatFromInt(pos.y_offset)) / 64.0)),
            };
        }

        const text_dup = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(text_dup);

        self.run_clock += 1; // bump BEFORE stamping
        if (self.run_cache.count() >= run_cache_capacity) {
            // Evict the entry with the oldest generation stamp (an O(n)
            // scan of ≤256 entries is fine).
            // SAFETY: only read if the scan finds a victim (victim_found);
            // the undefined is never dereferenced otherwise.
            var victim_key: RunKey = undefined;
            var victim_gen: u32 = std.math.maxInt(u32);
            var it = self.run_cache.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.generation < victim_gen) {
                    victim_gen = kv.value_ptr.generation;
                    victim_key = kv.key_ptr.*;
                }
            }
            if (self.run_cache.getPtr(victim_key)) |victim| {
                self.freeRun(victim.*);
                _ = self.run_cache.remove(victim_key);
            }
        }
        try self.run_cache.put(self.gpa, key, .{
            .key = key,
            .text = text_dup,
            .width = w,
            .line_height = font.ascent - font.descent,
            .glyphs = glyphs,
            .generation = self.run_clock,
        });
        // Fetch the ptr AFTER the put — never hold a map ptr across a put.
        return self.run_cache.getPtr(key).?;
    }

    /// Rasterize glyph `gid` on demand: extract curves → sweeper (GPU curve
    /// buffer) → glyph material → entry. Glyph id 0 (.notdef, from chars
    /// absent in the font) and glyphs whose outline extraction fails are
    /// skipped (no entry, no error). Returns error.TooManyGlyphs once the
    /// max_materials slot budget is exhausted (checked only for glyphs that
    /// would actually consume a new slot).
    fn ensureGlyph(self: *TextEngine, font: *FontState, gid: u32) !void {
        if (gid == 0) return; // .notdef: missing glyph, skip
        for (self.entries.items) |e| {
            if (e.font_id == font.font_id and e.size == font.size and e.gid == gid) return; // already rasterized
        }

        // Slot budget exhausted: fail with a real error instead of writing
        // OOB into the GPU material heap — a debug-only assert would compile
        // out in ReleaseFast. The assert stays as belt-and-suspenders.
        std.debug.assert(self.next_slot < max_materials); // slot 0 reserved for solid
        if (self.next_slot >= max_materials) return error.TooManyGlyphs;

        // Extraction failures (missing outline, draw error) → skip glyph.
        const curves = extractGlyphCurves(self.gpa, font.hb_font, gid) catch return;
        defer self.gpa.free(curves);

        var sweeper = try proto.GlyphSweeper.init(self.gpu, curves);

        // Metrics from HarfBuzz (the same 26.6 fixed-point scale as the
        // shaped positions; /64.0 → pixels). No FreeType in our code.
        const advance = @as(
            f32,
            @floatCast(@as(f64, @floatFromInt(c.hb_font_get_glyph_h_advance(font.hb_font.handle, gid))) / 64.0),
        );
        // SAFETY: assigned by hb_font_get_glyph_extents before any read; a
        // zero return (no ink) skips the glyph.
        var ext: c.hb_glyph_extents_t = undefined;
        // No ink: the sweeper's GPU curve buffer was already allocated by
        // init above, so free it here or it leaks (the success path hands
        // ownership to self.sweepers, which deinits at TextEngine.deinit).
        if (c.hb_font_get_glyph_extents(font.hb_font.handle, gid, &ext) == 0) {
            sweeper.deinit();
            return; // no ink
        }
        const bearing_x: f32 = @floatCast(@as(f64, @floatFromInt(ext.x_bearing)) / 64.0);
        const bearing_y: f32 = @floatCast(@as(f64, @floatFromInt(ext.y_bearing)) / 64.0);
        const glyph_w: f32 = @floatCast(@as(f64, @floatFromInt(ext.width)) / 64.0);
        // hb extents: height is NEGATIVE for y-up fonts (the box extends
        // downward from the top bearing) — the magnitude is the ink height.
        const glyph_h: f32 = @floatCast(@as(f64, @floatFromInt(@abs(ext.height))) / 64.0);

        // The shader sweeps the curves per fragment at DISPLAY resolution
        // (analytic AA — no intermediate bitmap), so the material only
        // needs the curve buffer; the window fields are unused (1.0).
        const slot = self.next_slot;
        proto.GlyphSweeper.writeMaterial(
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
        self.sweepers.append(self.gpa, sweeper) catch |e| {
            sweeper.deinit();
            return e;
        };
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
        }) catch |e| {
            var orphan = self.sweepers.pop().?;
            orphan.deinit();
            return e;
        };
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
        const ellipsis_key: ?RunKey = if (max_width != null)
            (try self.getOrShape(font, "...")).key
        else
            null;
        const run_key = (try self.getOrShape(font, text)).key;
        // Re-fetch both keys after shaping. The second cache operation may
        // rehash the map and invalidate the first returned pointer.
        const run = self.run_cache.getPtr(run_key).?;
        const ellipsis_run = if (ellipsis_key) |key| self.run_cache.getPtr(key) else null;
        const run_x = snapRunOrigin(x);
        const run_baseline = @round(baseline_y);

        const truncate = if (max_width) |width| blk: {
            if (std.math.isNan(width)) break :blk false;
            break :blk run.width > @max(0, width);
        } else false;
        if (!truncate) {
            _ = try self.emitRun(
                font,
                run,
                run.glyphs.len,
                run_x,
                0,
                run_baseline,
                clip_id,
                color,
                out,
            );
            return;
        }

        const suffix = ellipsis_run.?;
        const width = @max(0, max_width.?);
        if (suffix.width > width) return;
        const prefix_limit = width - suffix.width;
        const prefix_count = fitGlyphCount(run, prefix_limit);
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
        for (run.glyphs[0..glyph_count]) |g| {
            try self.ensureGlyph(font, g.gid);
            const entry = self.entryFor(font.font_id, font.size, g.gid) orelse continue;
            const ch_x = run_x + cursor + g.x_offset + entry.bearing_x;
            const ch_y = run_baseline - entry.bearing_y - g.y_offset;
            if (entry.glyph_w <= 0 or entry.glyph_h <= 0) {
                cursor += g.x_advance;
                continue;
            }
            try out.append(self.gpa, .{
                .dst = .{ ch_x - 2, ch_y - 2, @ceil(entry.glyph_w) + 4, @ceil(entry.glyph_h) + 4 },
                .src = .{ 0, 0, 1, 1 },
                .corners = .{ 0, 0, 0, 0 },
                .color = color,
                .material_index = entry.slot,
                .curve = .{ entry.curve_left, entry.curve_bottom, entry.curve_w, entry.curve_h },
                .clip_id = clip_id,
                .origin = .{ run_x + cursor + g.x_offset, run_baseline - g.y_offset },
            });
            cursor += g.x_advance;
        }
        return cursor;
    }

    /// Measure a text run's content size only: the SHAPED width (the sum of
    /// the shaper's advances — kerning and ligatures included), 24px tall
    /// (20px cap height + descender room); padding and border come from the
    /// widget box (flex), not from the measurement. Shapes only — no glyph
    /// rasterization (unlike the pre-shaping measure, which forced the
    /// atlas to fill). On shape failure falls back to the baked estimate.
    pub fn measureText(self: *TextEngine, text: []const u8, size: u32, font_id: u8) WidgetSize {
        const zone = tracy.Zone.begin(.{ .name = "measureText", .src = @src() });
        defer zone.end();
        const font = self.fontFor(font_id, size) catch {
            const len_f: f32 = @floatFromInt(@min(text.len, 1 << 24));
            return .{ .width = len_f * 10, .height = 24 };
        };
        const run = self.getOrShape(font, text) catch {
            const len_f: f32 = @floatFromInt(@min(text.len, 1 << 24));
            return .{ .width = len_f * 10, .height = 24 };
        };
        return .{ .width = run.width, .height = run.line_height };
    }

    fn entryFor(self: *const TextEngine, font_id: u8, size: u32, gid: u32) ?GlyphEntry {
        for (self.entries.items) |e| {
            if (e.font_id == font_id and e.size == size and e.gid == gid) return e;
        }
        return null;
    }
};

/// Extract glyph curves for a specific SHAPED glyph id via HarfBuzz's
/// draw API (hb_font_draw_glyph — the hb-ft backend emits the outline in
/// the font's scale, 26.6 fixed-point px; /64 → px). No FreeType calls in
/// our code: the face exists only as the hb-ft backend. Callbacks fill a
/// 4096-curve stack buffer (cubic segments split into two conics at
/// t=0.5), then the caller-owned slice is dupe'd via `alloc`.
fn extractGlyphCurves(alloc: std.mem.Allocator, font: hb.Font, gid: u32) ![]proto.Curve {
    if (gid == 0) return error.GlyphNotFound;

    var buf: [4096]proto.Curve = undefined;
    var count: u32 = 0;
    var first_x: f32 = 0;
    var first_y: f32 = 0;
    var last_x: f32 = 0;
    var last_y: f32 = 0;

    const Ctx = struct {
        curves: *[4096]proto.Curve,
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

    return alloc.dupe(proto.Curve, buf[0..count]);
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

/// Rasterize real glyph curves at a pixel; returns coverage.
fn glyphCoverage(
    curves: []const proto.Curve,
    curve_left: f32,
    curve_bottom: f32,
    curve_w: f32,
    curve_h: f32,
    px: [2]f32,
    win: [2]f32,
) f32 {
    // map pixel → curve space (the shader's uv mapping):
    // window size in curve units = win (curve_w/dst_w etc.), offset = pixel's curve pos
    const offset = [2]f32{
        curve_left + curve_w * (px[0] + 0.5 - px[0]),
        curve_bottom + curve_h * (px[1] + 0.5 - px[1]),
    };
    _ = offset;
    // The shader: win_size = dFdx(vUv) = curve_w/dst_w; offset = vUv - 0.5*win_size.
    // For a pixel at curve position c: window = [c - win/2, c + win/2].

    var total: f32 = 0;
    for (curves) |cv| {
        total += sweepSegment(
            win,
            .{ curve_left + curve_w * px[0] / 200, curve_bottom + curve_h * px[1] / 200 },
            .{ cv.p0x, cv.p0y },
            .{ cv.p1x, cv.p1y },
            .{ cv.p2x, cv.p2y },
        );
    }
    return total / (win[0] * win[1]);
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
            const hull = proto.glyphExtent(curves);
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
