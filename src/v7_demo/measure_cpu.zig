//! CPU-only text measurement for the headless layout path.
//!
//! Mirrors TextEngine.measureText (same embedded font, same 20px size, same
//! FreeType advance sums) so the offscreen layout matches the windowed one
//! exactly — but needs no GPU: no materials, no sweeper buffers. The headless
//! mode initializes this and points `App.measure` at `measure`.
const WidgetSize = @import("v7/widget.zig").Size;

const c = @cImport({
    @cDefine("FT2_BUILD_LIBRARY", "1");
    @cInclude("freetype/freetype.h");
});

const FONT_SIZE_PX: u32 = 20; // must match TextEngine.FONT_SIZE_PX

const State = struct {
    ft_lib: c.FT_Library,
    face: c.FT_Face,
    /// Per-char advance cache (0 = not loaded). Keys are the char itself.
    advances: [256]f32 = [_]f32{0} ** 256,
};

var state: ?State = null;

/// Load the embedded Inter font at 20px. Call once before any `measure`;
/// `deinit` releases FreeType. Errors propagate (caller decides how to
/// degrade — measure() falls back to the baked approximation).
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

    state = .{ .ft_lib = ft_lib, .face = face };
}

pub fn deinit() void {
    if (state) |*s| {
        _ = c.FT_Done_Face(s.face);
        _ = c.FT_Done_FreeType(s.ft_lib);
    }
    state = null;
}

/// Flex measure callback: content size only — the sum of per-glyph
/// advances, 24px tall. Padding/border come from the widget box; the flex
/// adds the box. Identical shape to TextEngine.measureText.
pub fn measure(text: []const u8) WidgetSize {
    if (state) |*s| {
        var w: f32 = 0;
        for (text) |ch| {
            w += advance(s, ch);
        }
        return .{ .width = w, .height = 24 };
    }
    return .{
        .width = @as(f32, @floatFromInt(text.len)) * 10,
        .height = 24,
    };
}

/// Advance for `ch` in layout pixels (26.6 fixed point / 64), cached.
fn advance(s: *State, ch: u8) f32 {
    const cached = s.advances[ch];
    if (cached != 0) return cached;
    const idx = c.FT_Get_Char_Index(s.face, ch);
    if (idx == 0) {
        s.advances[ch] = 10; // unknown char: fall back to the flex estimate
        return 10;
    }
    if (c.FT_Load_Glyph(s.face, idx, c.FT_LOAD_NO_BITMAP) != 0) {
        s.advances[ch] = 10;
        return 10;
    }
    const adv = @as(f32, @floatFromInt(s.face.*.glyph.*.metrics.horiAdvance)) / 64.0;
    s.advances[ch] = adv;
    return adv;
}
