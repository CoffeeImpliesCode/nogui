//! Main playlist header and action view for the Spotify demo.

const DrawCtx = @import("v7/drawctx.zig").DrawCtx;
const widget = @import("v7/widget.zig");
const theme = @import("spotify_theme.zig");
const tracks = @import("spotify_tracks.zig");

const header_tracks = [_]widget.ColumnTrack{
    .{ .basis = 620, .grow = 1, .shrink = 1, .min_main = 160 },
    .{ .basis = 142, .grow = 0, .shrink = 1, .min_main = 64 },
};
const header_columns: widget.SharedColumns = .{ .tracks = &header_tracks };

const hero_tracks = [_]widget.ColumnTrack{
    .{ .basis = 120, .grow = 0, .shrink = 0, .min_main = 120 },
    .{ .basis = 520, .grow = 1, .shrink = 1, .min_main = 80 },
};
const hero_columns: widget.SharedColumns = .{ .tracks = &hero_tracks };

pub fn draw(app: anytype, ctx: *DrawCtx) !void {
    const App = @TypeOf(app.*);

    _ = try ctx.column(.{
        .grow = 1,
        .gap = 12,
        .clip = true,
        .scroll_state = &app.content_scroll,
        .scroll_axis = .vertical,
        .fill = theme.c_card_bg,
        .gradient = theme.srgbToOklab(theme.c_card_bg),
        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
        .border_color = theme.c_border,
        .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
        .padding = .{ .top = 12, .right = 12, .bottom = 12, .left = 12 },
    });
    defer ctx.pop();

    try drawHeader(App, app, ctx);
    try drawHero(app, ctx);
    try drawActions(App, app, ctx);
    try tracks.draw(app, ctx);
}

fn drawHeader(comptime App: type, app: anytype, ctx: *DrawCtx) !void {
    _ = try ctx.row(.{
        .columns = &header_columns,
        .gap = 12,
        .clip = true,
        .justify = .space_between,
        .padding = .{ .bottom = 4 },
    });
    defer ctx.pop();

    {
        _ = try ctx.row(.{ .gap = 8, .clip = true, .@"align" = .center });
        defer ctx.pop();

        try drawChromeButton(ctx, "<");
        try drawChromeButton(ctx, ">");
        _ = try ctx.button(.{
            .label = "⌕  Search music, artists...",
            .on_click = App.selectNavSearch,
            .basis = 230,
            .shrink = 1,
            .min_main = 80,
            .text_overflow = .ellipsis,
            .max_width = 220,
            .color = theme.c_text_sec,
            .padding = .{ .left = 14, .right = 14, .top = 7, .bottom = 7 },
            .radius = .{ .top = 18, .right = 18, .bottom = 18, .left = 18 },
            .fill = theme.c_hover,
            .gradient = theme.srgbToOklab(theme.c_hover),
            .font_size = 12,
        });
        _ = try theme.pillButton(ctx, "All", app.active_category == .all, App.selectCategoryAll);
        _ = try theme.pillButton(
            ctx,
            "Music",
            app.active_category == .music,
            App.selectCategoryMusic,
        );
        _ = try theme.pillButton(
            ctx,
            "Podcasts",
            app.active_category == .podcasts,
            App.selectCategoryPodcasts,
        );
    }

    _ = try ctx.button(.{
        .label = "Janis (Premium)",
        .text_overflow = .ellipsis,
        .max_width = 130,
        .color = theme.c_text,
        .padding = .{ .left = 12, .right = 12, .top = 6, .bottom = 6 },
        .radius = .{ .top = 18, .right = 18, .bottom = 18, .left = 18 },
        .fill = theme.c_hover,
        .gradient = theme.srgbToOklab(theme.c_hover),
        .font_size = 12,
    });
}

fn drawChromeButton(ctx: *DrawCtx, label: []const u8) !void {
    _ = try ctx.button(.{
        .label = label,
        .basis = 32,
        .shrink = 0,
        .min_main = 32,
        .color = theme.c_text,
        .padding = .{ .left = 10, .right = 10, .top = 6, .bottom = 6 },
        .radius = .{ .top = 16, .right = 16, .bottom = 16, .left = 16 },
        .fill = theme.c_bg,
        .gradient = theme.srgbToOklab(theme.c_bg),
        .font_size = 14,
    });
}

fn drawHero(app: anytype, ctx: *DrawCtx) !void {
    _ = try ctx.row(.{
        .columns = &hero_columns,
        .gap = 20,
        .clip = true,
        .@"align" = .center,
        .padding = .{ .top = 20, .right = 20, .bottom = 20, .left = 20 },
        .radius = .{ .top = 10, .right = 10, .bottom = 10, .left = 10 },
        .fill = theme.c_hero_grad_top,
        .gradient = theme.srgbToOklab(theme.c_hero_grad_bot),
    });
    defer ctx.pop();

    _ = try theme.drawArtworkTile(ctx, 120, app.playlists[0].artwork_seed);

    {
        _ = try ctx.column(.{ .gap = 5, .clip = true, .justify = .center });
        defer ctx.pop();
        _ = try ctx.label(.{
            .text = "PUBLIC PLAYLIST",
            .color = theme.c_text_sec,
            .font_size = 11,
        });
        _ = try ctx.label(.{
            .text = "Cyberpunk Ambient 2026",
            .text_overflow = .ellipsis,
            .color = theme.c_text,
            .font_size = 26,
        });
        _ = try ctx.label(.{
            .text = "Nocturnal synths, retro-futuristic soundscapes and deep focus beats.",
            .text_overflow = .ellipsis,
            .color = theme.c_text_sec,
            .font_size = 13,
        });
        _ = try ctx.label(.{
            .text = "Spotify • 1,482,910 saves • 7 songs, 32 min 8 sec",
            .text_overflow = .ellipsis,
            .color = theme.c_text,
            .font_size = 12,
            .padding = .{ .top = 5 },
        });
    }
}

fn drawActions(comptime App: type, app: anytype, ctx: *DrawCtx) !void {
    _ = try ctx.row(.{ .gap = 12, .@"align" = .center, .padding = .{ .top = 2, .bottom = 2 } });
    defer ctx.pop();

    _ = try ctx.button(.{
        .label = if (app.is_playing) "⏸" else "▶",
        .on_click = App.togglePlay,
        .basis = 48,
        .shrink = 0,
        .min_main = 48,
        .color = theme.c_bg,
        .padding = .{ .left = 14, .right = 14, .top = 11, .bottom = 11 },
        .radius = .{ .top = 24, .right = 24, .bottom = 24, .left = 24 },
        .fill = theme.c_accent,
        .gradient = theme.srgbToOklab(theme.c_accent_hover),
        .font_size = 17,
    });
    _ = try ctx.button(.{
        .label = if (app.playlist_saved) "♥ Saved" else "♥ Save",
        .on_click = App.togglePlaylistSaved,
        .color = if (app.playlist_saved) theme.c_accent else theme.c_text_sec,
        .padding = .{ .left = 14, .right = 14, .top = 8, .bottom = 8 },
        .radius = .{ .top = 18, .right = 18, .bottom = 18, .left = 18 },
        .fill = theme.c_hover,
        .gradient = theme.srgbToOklab(theme.c_hover),
        .font_size = 13,
    });
    _ = try ctx.button(.{
        .label = "•••",
        .color = theme.c_text_sec,
        .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
        .radius = .{ .top = 18, .right = 18, .bottom = 18, .left = 18 },
        .fill = theme.c_card_bg,
        .gradient = theme.srgbToOklab(theme.c_card_bg),
        .font_size = 15,
    });
}
