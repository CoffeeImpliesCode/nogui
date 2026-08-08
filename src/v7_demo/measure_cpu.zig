//! CPU-only text measurement for the headless layout path.
//!
//! Mirrors TextEngine.measureText (same embedded font, same 20px size, same
//! HarfBuzz shaping — kerning included) so the offscreen layout matches the
//! windowed one exactly — but needs no GPU: no materials, no sweeper
//! buffers. The headless mode initializes this and points `App.measure` at
//! `measure`.
const WidgetSize = @import("v7/widget.zig").Size;

// Same single C import as text.zig (the HarfBuzz binding owns it).
const hb = @import("harfbuzz");
const c = hb.c;

const FONT_SIZE_PX: u32 = 16; // must match TextEngine.FONT_SIZE_PX

const State = struct {
    ft_lib: c.FT_Library,
    face: c.FT_Face,
    hb_font: hb.Font,
    /// Font line metrics at FONT_SIZE_PX (26.6 → px).
    ascent: f32,
    descent: f32,
};

var state: ?State = null;

/// Load the embedded Inter font at 20px and wrap it in a HarfBuzz font.
/// Call once before any `measure`; `deinit` releases both. Errors propagate
/// (caller decides how to degrade — measure() falls back to the baked
/// approximation).
pub fn init() !void {
    if (state != null) return;

    // SAFETY: assigned by FT_Init/FT_New before any use; failures return errors.
    var ft_lib: c.FT_Library = undefined;
    if (c.FT_Init_FreeType(&ft_lib) != 0) return error.FreeTypeInitFailed;
    errdefer _ = c.FT_Done_FreeType(ft_lib);

    const font_data = @embedFile("InterVariable.ttf");
    // SAFETY: assigned by FT_Init/FT_New before any use; failures return errors.
    var face: c.FT_Face = undefined;
    if (c.FT_New_Memory_Face(ft_lib, font_data.ptr, @intCast(font_data.len), 0, &face) != 0)
        return error.FreeTypeFaceFailed;
    errdefer _ = c.FT_Done_Face(face);
    if (c.FT_Set_Pixel_Sizes(face, 0, FONT_SIZE_PX) != 0) return error.FreeTypeSetPixelSizesFailed;

    const hb_handle = c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzFailed;
    const hb_font = hb.Font{ .handle = hb_handle };
    c.hb_ft_font_set_funcs(hb_handle);
    _ = c.hb_ft_font_set_load_flags(hb_handle, c.FT_LOAD_DEFAULT);

    // SAFETY: assigned by hb_font_get_extents_for_direction before any read.
    var font_ext: c.hb_font_extents_t = undefined;
    _ = c.hb_font_get_extents_for_direction(hb_handle, c.HB_DIRECTION_LTR, &font_ext);

    state = .{
        .ft_lib = ft_lib,
        .face = face,
        .hb_font = hb_font,
        .ascent = @as(f32, @floatFromInt(font_ext.ascender)) / 64.0,
        .descent = @as(f32, @floatFromInt(font_ext.descender)) / 64.0,
    };
}

pub fn deinit() void {
    if (state) |*s| {
        s.hb_font.destroy();
        _ = c.FT_Done_Face(s.face);
        _ = c.FT_Done_FreeType(s.ft_lib);
    }
    state = null;
}

/// Flex measure callback: content size only — the SHAPED width (sum of the
/// shaper's advances, kerning included), 24px tall. Padding/border come
/// from the widget box; the flex adds the box. Identical shape to
/// TextEngine.measureText. On shape failure falls back to the baked
/// estimate.
pub fn measure(text: []const u8) WidgetSize {
    if (state) |*s| {
        var buf = shape(s, text) catch return fallback(text);
        defer buf.destroy();
        var w: f32 = 0;
        for (buf.getGlyphPositions() orelse &.{}) |pos| {
            w += @as(f32, @floatFromInt(pos.x_advance)) / 64.0;
        }
        return .{ .width = w, .height = s.ascent - s.descent };
    }
    return fallback(text);
}

fn fallback(text: []const u8) WidgetSize {
    return .{
        .width = @as(f32, @floatFromInt(text.len)) * 10,
        .height = 24,
    };
}

fn shape(s: *State, text: []const u8) !hb.Buffer {
    var buf = try hb.Buffer.create();
    errdefer buf.destroy();
    buf.addUTF8(text);
    buf.setDirection(.ltr);
    buf.setScript(.latin);
    hb.shape(s.hb_font, buf, null);
    return buf;
}
