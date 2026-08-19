//! Shared Spotify palette and stateless widgets.

const DrawCtx = @import("v7/drawctx.zig").DrawCtx;
pub const srgbToOklab = @import("text.zig").srgbToOklab;
const Id = @import("v7/id.zig").Id;
const UserCallback = @import("v7/callback.zig").UserCallback;

// Spotify dark palette. Colors are authored in sRGB and converted at draw time.
pub const c_bg: [4]f32 = .{ 0.07, 0.07, 0.07, 1.0 };
pub const c_sidebar_bg: [4]f32 = .{ 0.02, 0.02, 0.02, 1.0 };
pub const c_card_bg: [4]f32 = .{ 0.09, 0.09, 0.09, 1.0 };
pub const c_card_elevated: [4]f32 = .{ 0.14, 0.14, 0.14, 1.0 };
pub const c_hover: [4]f32 = .{ 0.16, 0.16, 0.16, 1.0 };
pub const c_active_row: [4]f32 = .{ 0.165, 0.165, 0.165, 1.0 };
pub const c_player_bg: [4]f32 = .{ 0.09, 0.09, 0.09, 1.0 };
pub const c_accent: [4]f32 = .{ 0.11, 0.73, 0.33, 1.0 };
pub const c_accent_hover: [4]f32 = .{ 0.12, 0.84, 0.38, 1.0 };
pub const c_accent_dim: [4]f32 = .{ 0.08, 0.28, 0.14, 1.0 };
pub const c_text: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 };
pub const c_text_sec: [4]f32 = .{ 0.70, 0.70, 0.70, 1.0 };
pub const c_text_muted: [4]f32 = .{ 0.42, 0.42, 0.42, 1.0 };
pub const c_border: [4]f32 = .{ 0.20, 0.20, 0.20, 0.5 };
pub const c_hero_grad_top: [4]f32 = .{ 0.28, 0.15, 0.48, 1.0 };
pub const c_hero_grad_bot: [4]f32 = .{ 0.09, 0.09, 0.10, 1.0 };
pub const c_like_active: [4]f32 = c_accent;

// Existing names stay public for callers that predate the expanded palette.
pub const c_card_hover: [4]f32 = c_hover;
pub const c_accent_bright: [4]f32 = c_accent_hover;
pub const c_hero_top: [4]f32 = c_hero_grad_top;
pub const c_hero_bot: [4]f32 = c_hero_grad_bot;

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

const artwork_gradients = [_][2][4]f32{
    .{ .{ 0.69, 0.12, 0.52, 1.0 }, .{ 0.25, 0.08, 0.48, 1.0 } },
    .{ .{ 0.10, 0.64, 0.78, 1.0 }, .{ 0.04, 0.20, 0.52, 1.0 } },
    .{ .{ 0.95, 0.42, 0.12, 1.0 }, .{ 0.54, 0.08, 0.18, 1.0 } },
    .{ .{ 0.22, 0.76, 0.42, 1.0 }, .{ 0.02, 0.30, 0.32, 1.0 } },
    .{ .{ 0.58, 0.34, 0.94, 1.0 }, .{ 0.14, 0.10, 0.52, 1.0 } },
    .{ .{ 0.92, 0.24, 0.38, 1.0 }, .{ 0.38, 0.06, 0.36, 1.0 } },
};

const artwork_emblems = [_][]const u8{ "✦", "♪", "◉", "◆", "≈", "△" };

pub fn drawArtworkTile(ctx: *DrawCtx, size: f32, seed: u8) !Id {
    const index: usize = @as(usize, seed) % artwork_gradients.len;
    const colors = artwork_gradients[index];
    const tile = try ctx.column(.{
        .basis = size,
        .min_main = size,
        .clip = true,
        .fill = colors[0],
        .gradient = srgbToOklab(colors[1]),
        .radius = .{ .top = 6, .right = 6, .bottom = 6, .left = 6 },
        .padding = .{
            .top = size * 0.28,
            .right = size * 0.18,
            .bottom = size * 0.18,
            .left = size * 0.18,
        },
        .shadow = 8,
    });
    defer ctx.pop();

    _ = try ctx.label(.{
        .text = artwork_emblems[index],
        .color = .{ 1.0, 1.0, 1.0, 0.88 },
        .font_size = size * 0.30,
    });
    _ = try ctx.spacer(.{ .size = size * 0.18 });
    return tile;
}

pub fn spotifyButton(ctx: *DrawCtx, text: []const u8, active: bool, handler: anytype) !Id {
    const color = if (active) c_accent else c_text_sec;
    const fill = if (active) c_hover else c_card_bg;
    const border_color = if (active) c_accent else c_border;
    if (comptime @TypeOf(handler) == UserCallback) {
        return ctx.button(.{
            .label = text,
            .on_click_with_data = handler,
            .color = color,
            .padding = .{ .left = 12, .right = 12, .top = 6, .bottom = 6 },
            .radius = .{ .top = 6, .right = 6, .bottom = 6, .left = 6 },
            .fill = fill,
            .gradient = srgbToOklab(fill),
            .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
            .border_color = border_color,
            .font_size = 13,
        });
    }
    return ctx.button(.{
        .label = text,
        .on_click = handler,
        .color = color,
        .padding = .{ .left = 12, .right = 12, .top = 6, .bottom = 6 },
        .radius = .{ .top = 6, .right = 6, .bottom = 6, .left = 6 },
        .fill = fill,
        .gradient = srgbToOklab(fill),
        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
        .border_color = border_color,
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
