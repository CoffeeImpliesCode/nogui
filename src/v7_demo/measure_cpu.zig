//! CPU-only text measurement for the headless layout path.
//!
//! Mirrors TextEngine.measureText (same embedded font, same HarfBuzz
//! shaping — kerning included) so the offscreen layout matches the
//! windowed one exactly — but needs no GPU: no materials, no sweeper
//! buffers. One FT face + hb font per SIZE (13/16/20), created lazily —
//! the same per-size structure the window uses for its engines. A shared
//! face that gets re-sized per call does NOT work: hb-ft's extents cache
//! the first size and ignore later FT_Set_Pixel_Sizes.
const nogui = @import("nogui");
pub const WidgetSize = nogui.widget.Size;

// Same single C import as text.zig (the HarfBuzz binding owns it).
const hb = @import("harfbuzz");
const c = hb.c;

const font_size_px: u32 = 16; // must match TextEngine.font_size_px

const SizeState = struct {
    ft_lib: c.FT_Library,
    face: c.FT_Face,
    hb_font: hb.Font,
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
    const hb_font: hb.Font = .{ .handle = hb_handle };
    c.hb_ft_font_set_funcs(hb_handle);
    // Unhinted — same policy as the window engine (see text.zig's note):
    // positions and extents must scale linearly with the size.
    _ = c.hb_ft_font_set_load_flags(hb_handle, c.FT_LOAD_DEFAULT | c.FT_LOAD_NO_HINTING);

    // SAFETY: assigned by hb_font_get_extents_for_direction before any read.
    var font_ext: c.hb_font_extents_t = undefined;
    _ = c.hb_font_get_extents_for_direction(hb_handle, c.HB_DIRECTION_LTR, &font_ext);

    entries[idx] = .{
        .ft_lib = ft_lib,
        .face = face,
        .hb_font = hb_font,
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
            s.hb_font.destroy();
            _ = c.FT_Done_Face(s.face);
            _ = c.FT_Done_FreeType(s.ft_lib);
            e.* = null;
        }
    }
}

/// Flex measure callback: content size only — the SHAPED width (sum of the
/// shaper's advances, kerning included), the font's line height tall.
/// Padding/border come from the widget box; the flex adds the box.
/// Identical shape to TextEngine.measureText. `font_size` 0 = the default.
/// On shape failure falls back to the baked estimate.
pub fn measure(text: []const u8, font_size: f32, font_id: u8) WidgetSize {
    const px: u32 = if (font_size > 0)
        @intFromFloat(@round(font_size))
    else
        font_size_px;
    const s = entryFor(font_id, px) catch return fallback(text);

    var buf = shape(s, text) catch return fallback(text);
    defer buf.destroy();
    var w: f32 = 0;
    for (buf.getGlyphPositions() orelse &.{}) |pos| {
        w += @as(f32, @floatCast(@as(f64, @floatFromInt(pos.x_advance)) / 64.0));
    }
    return .{ .width = w, .height = s.ascent - s.descent };
}

fn fallback(text: []const u8) WidgetSize {
    const len_f: f32 = @floatFromInt(@min(text.len, 1 << 24));
    return .{
        .width = len_f * 10,
        .height = 24,
    };
}

fn shape(s: *SizeState, text: []const u8) !hb.Buffer {
    var buf = try hb.Buffer.create();
    errdefer buf.destroy();
    buf.addUTF8(text);
    buf.setDirection(.ltr);
    buf.setScript(.latin);
    hb.shape(s.hb_font, buf, null);
    return buf;
}
