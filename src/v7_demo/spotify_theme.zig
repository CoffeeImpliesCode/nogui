//! Shared Spotify palette and stateless widgets.

const DrawCtx = @import("v7/drawctx.zig").DrawCtx;
pub const srgbToOklab = @import("text.zig").srgbToOklab;
const Id = @import("v7/id.zig").Id;

// Spotify Dark Theme Palette (sRGB authored, Oklab converted).
pub const c_bg: [4]f32 = .{ 0.07, 0.07, 0.07, 1.0 }; // #121212 main canvas
pub const c_sidebar_bg: [4]f32 = .{ 0.05, 0.05, 0.05, 1.0 }; // #0d0d0d deep black
pub const c_card_bg: [4]f32 = .{ 0.10, 0.10, 0.10, 1.0 }; // #181818 card surface
pub const c_card_hover: [4]f32 = .{ 0.16, 0.16, 0.16, 1.0 }; // #282828 elevated
pub const c_active_row: [4]f32 = .{ 0.18, 0.18, 0.20, 1.0 }; // row selection highlight
pub const c_player_bg: [4]f32 = .{ 0.09, 0.09, 0.09, 1.0 }; // bottom bar surface
pub const c_accent: [4]f32 = .{ 0.11, 0.73, 0.33, 1.0 }; // #1DB954 Spotify green
pub const c_accent_bright: [4]f32 = .{ 0.12, 0.84, 0.38, 1.0 }; // #1ED760 hover green
pub const c_accent_dim: [4]f32 = .{ 0.08, 0.28, 0.14, 1.0 }; // accent surface
pub const c_text: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 }; // pure white primary
pub const c_text_sec: [4]f32 = .{ 0.70, 0.70, 0.70, 1.0 }; // #B3B3B3 secondary text
pub const c_text_muted: [4]f32 = .{ 0.45, 0.45, 0.45, 1.0 }; // captions / track #
pub const c_border: [4]f32 = .{ 0.22, 0.22, 0.22, 0.6 }; // card borders / dividers
pub const c_hero_top: [4]f32 = .{ 0.24, 0.14, 0.42, 1.0 }; // purple/indigo hero gradient
pub const c_hero_bot: [4]f32 = .{ 0.10, 0.10, 0.12, 1.0 }; // hero gradient bottom
pub const c_like_active: [4]f32 = .{ 0.11, 0.73, 0.33, 1.0 }; // green heart

pub fn spotifyCard(ctx: *DrawCtx, grow: f32, fill: [4]f32, clip: bool) !Id {
    return ctx.column(.{
        .grow = grow,
        .clip = clip,
        .fill = fill,
        .gradient = srgbToOklab(fill),
        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
        .border_color = c_border,
        .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
        .padding = .{ .top = 12, .right = 12, .bottom = 12, .left = 12 },
    });
}

pub fn spotifyButton(ctx: *DrawCtx, text: []const u8, active: bool, on_click: anytype) !Id {
    if (active) {
        return ctx.button(.{
            .label = text,
            .on_click = on_click,
            .color = c_accent,
            .padding = .{ .left = 12, .right = 12, .top = 6, .bottom = 6 },
            .radius = .{ .top = 6, .right = 6, .bottom = 6, .left = 6 },
            .fill = c_card_hover,
            .gradient = srgbToOklab(c_card_hover),
            .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
            .border_color = c_accent,
            .font_size = 13,
        });
    }
    return ctx.button(.{
        .label = text,
        .on_click = on_click,
        .color = c_text_sec,
        .padding = .{ .left = 12, .right = 12, .top = 6, .bottom = 6 },
        .radius = .{ .top = 6, .right = 6, .bottom = 6, .left = 6 },
        .fill = c_card_bg,
        .gradient = srgbToOklab(c_card_bg),
        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
        .border_color = c_border,
        .font_size = 13,
    });
}

pub fn pillButton(ctx: *DrawCtx, text: []const u8, active: bool, on_click: anytype) !Id {
    if (active) {
        return ctx.button(.{
            .label = text,
            .on_click = on_click,
            .color = c_bg,
            .padding = .{ .left = 12, .right = 12, .top = 4, .bottom = 4 },
            .radius = .{ .top = 16, .right = 16, .bottom = 16, .left = 16 },
            .fill = c_text,
            .gradient = srgbToOklab(c_text),
            .font_size = 12,
        });
    }
    return ctx.button(.{
        .label = text,
        .on_click = on_click,
        .color = c_text,
        .padding = .{ .left = 12, .right = 12, .top = 4, .bottom = 4 },
        .radius = .{ .top = 16, .right = 16, .bottom = 16, .left = 16 },
        .fill = c_card_hover,
        .gradient = srgbToOklab(c_card_hover),
        .font_size = 12,
    });
}

pub fn drawTrackActions(
    comptime on_click: anytype,
    ctx: *DrawCtx,
    index_label: []const u8,
    title_label: []const u8,
    album_label: []const u8,
    date_label: []const u8,
    duration_label: []const u8,
    num_color: [4]f32,
    title_color: [4]f32,
    row_fill: [4]f32,
) !void {
    _ = try ctx.button(.{
        .label = index_label,
        .on_click = on_click,
        .color = num_color,
        .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 },
        .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
        .fill = row_fill,
        .gradient = srgbToOklab(row_fill),
        .font_size = 12,
    });
    _ = try ctx.button(.{
        .label = title_label,
        .on_click = on_click,
        .color = title_color,
        .padding = .{ .left = 6, .right = 16, .top = 2, .bottom = 2 },
        .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
        .fill = row_fill,
        .gradient = srgbToOklab(row_fill),
        .font_size = 13,
    });
    _ = try ctx.button(.{
        .label = album_label,
        .on_click = on_click,
        .color = c_text_sec,
        .padding = .{ .left = 8, .right = 16, .top = 2, .bottom = 2 },
        .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
        .fill = row_fill,
        .gradient = srgbToOklab(row_fill),
        .font_size = 12,
    });
    _ = try ctx.button(.{
        .label = date_label,
        .on_click = on_click,
        .color = c_text_muted,
        .padding = .{ .left = 0, .right = 16, .top = 2, .bottom = 2 },
        .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
        .fill = row_fill,
        .gradient = srgbToOklab(row_fill),
        .font_size = 12,
    });
    _ = try ctx.button(.{
        .label = duration_label,
        .on_click = on_click,
        .color = c_text_sec,
        .padding = .{ .left = 0, .right = 0, .top = 2, .bottom = 2 },
        .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
        .fill = row_fill,
        .gradient = srgbToOklab(row_fill),
        .font_size = 12,
    });
}
