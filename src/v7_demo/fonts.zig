//! The faces this demo ships, in one place.
//!
//! The GPU host registers these bytes with its `TextEngine`; every headless
//! driver registers the same bytes with one `TextMeasurer`. A headless layout
//! check therefore measures with the faces the window paints with, and each
//! face is embedded exactly once in the demo binary.
const nogui_text = @import("nogui_text");

pub const pinned_fonts = [_]nogui_text.FontSource{
    .{ .family = "InterVariable", .bytes = @embedFile("InterVariable.ttf") },
    .{ .family = "Fira Code Nerd Font", .bytes = @embedFile("FiraCodeNerdFont-Regular.ttf") },
};

/// The size a node gets when it authors none. The GPU host's default is 14;
/// the headless demo has always measured and painted at 16, and its layout
/// golden is that 16.
pub const default_text_size: f32 = 16;
