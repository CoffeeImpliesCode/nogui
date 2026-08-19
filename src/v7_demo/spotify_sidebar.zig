//! Sidebar view for the Spotify demo.

const DrawCtx = @import("v7/drawctx.zig").DrawCtx;
const theme = @import("spotify_theme.zig");

pub fn draw(app: anytype, ctx: *DrawCtx) !void {
    const App = @TypeOf(app.*);

    _ = try ctx.column(.{
        .basis = 260,
        .shrink = 0,
        .gap = 8,
    });
    defer ctx.pop();

    // 1. Top Navigation Box
    {
        _ = try theme.spotifyCard(ctx, 0, theme.c_card_bg, false);
        defer ctx.pop();

        // Spotify Brand Logo
        {
            _ = try ctx.row(.{ .gap = 8, .padding = .{ .bottom = 8, .left = 4 } });
            defer ctx.pop();
            _ = try ctx.label(.{
                .text = "Spotify",
                .color = theme.c_text,
                .font_size = 20,
            });
            _ = try ctx.label(.{
                .text = "Mock",
                .color = theme.c_accent,
                .font_size = 12,
                .padding = .{ .top = 6 },
            });
        }

        // Navigation Items
        _ = try theme.spotifyButton(ctx, "  Home", app.active_nav == .home, App.selectNavHome);
        _ = try theme.spotifyButton(ctx, "  Search", app.active_nav == .search, App.selectNavSearch);
        _ = try theme.spotifyButton(ctx, "  Your Library", app.active_nav == .library, App.selectNavLibrary);
    }

    // 2. Playlists / Library Container
    {
        _ = try theme.spotifyCard(ctx, 1, theme.c_card_bg, true);
        defer ctx.pop();

        // Library Header
        {
            _ = try ctx.row(.{
                .justify = .space_between,
                .padding = .{ .bottom = 6, .left = 4, .right = 4 },
            });
            defer ctx.pop();
            _ = try ctx.label(.{
                .text = "PLAYLISTS",
                .color = theme.c_text_muted,
                .font_size = 11,
            });
            _ = try ctx.label(.{
                .text = "+ New",
                .color = theme.c_text_sec,
                .font_size = 11,
            });
        }

        // Liked Songs Special Row
        {
            const liked_fill = if (app.selected_playlist == .liked_songs)
                theme.c_active_row
            else
                theme.c_card_bg;
            _ = try ctx.button(.{
                .label = "Liked Songs (142)",
                .on_click = App.selectPlaylistLiked,
                .color = theme.c_text,
                .padding = .{ .left = 8, .right = 8, .top = 6, .bottom = 6 },
                .radius = .{ .top = 6, .right = 6, .bottom = 6, .left = 6 },
                .fill = liked_fill,
                .gradient = theme.srgbToOklab(liked_fill),
                .font_size = 13,
            });
        }

        // Pinned & Custom Playlists
        _ = try ctx.button(.{
            .label = "Cyberpunk Ambient 2026",
            .on_click = App.selectPlaylist0,
            .color = if (app.selected_playlist == .cyberpunk) theme.c_accent else theme.c_text_sec,
            .padding = .{ .left = 8, .right = 8, .top = 5, .bottom = 5 },
            .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
            .fill = theme.c_card_bg,
            .gradient = theme.srgbToOklab(theme.c_card_bg),
            .font_size = 13,
        });

        _ = try ctx.button(.{
            .label = "Discover Weekly",
            .on_click = App.selectPlaylist1,
            .color = if (app.selected_playlist == .discover_weekly) theme.c_accent else theme.c_text_sec,
            .padding = .{ .left = 8, .right = 8, .top = 5, .bottom = 5 },
            .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
            .fill = theme.c_card_bg,
            .gradient = theme.srgbToOklab(theme.c_card_bg),
            .font_size = 13,
        });

        _ = try ctx.button(.{
            .label = "Release Radar",
            .on_click = App.selectPlaylist2,
            .color = if (app.selected_playlist == .release_radar) theme.c_accent else theme.c_text_sec,
            .padding = .{ .left = 8, .right = 8, .top = 5, .bottom = 5 },
            .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
            .fill = theme.c_card_bg,
            .gradient = theme.srgbToOklab(theme.c_card_bg),
            .font_size = 13,
        });

        _ = try ctx.button(.{
            .label = "Daily Mix 1 (Synthwave)",
            .on_click = App.selectPlaylist3,
            .color = if (app.selected_playlist == .daily_mix) theme.c_accent else theme.c_text_sec,
            .padding = .{ .left = 8, .right = 8, .top = 5, .bottom = 5 },
            .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
            .fill = theme.c_card_bg,
            .gradient = theme.srgbToOklab(theme.c_card_bg),
            .font_size = 13,
        });

        _ = try ctx.button(.{
            .label = "Deep Focus & Study",
            .on_click = App.selectPlaylist4,
            .color = if (app.selected_playlist == .deep_focus) theme.c_accent else theme.c_text_sec,
            .padding = .{ .left = 8, .right = 8, .top = 5, .bottom = 5 },
            .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
            .fill = theme.c_card_bg,
            .gradient = theme.srgbToOklab(theme.c_card_bg),
            .font_size = 13,
        });

        _ = try ctx.button(.{
            .label = "Chill Lo-Fi Beats",
            .on_click = App.selectPlaylist5,
            .color = if (app.selected_playlist == .chill_lofi) theme.c_accent else theme.c_text_sec,
            .padding = .{ .left = 8, .right = 8, .top = 5, .bottom = 5 },
            .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
            .fill = theme.c_card_bg,
            .gradient = theme.srgbToOklab(theme.c_card_bg),
            .font_size = 13,
        });
    }
}
