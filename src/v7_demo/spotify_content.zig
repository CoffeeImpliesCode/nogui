//! Main playlist header and action view for the Spotify demo.

const DrawCtx = @import("v7/drawctx.zig").DrawCtx;
const theme = @import("spotify_theme.zig");
const tracks = @import("spotify_tracks.zig");

pub fn draw(app: anytype, ctx: *DrawCtx) !void {
    const App = @TypeOf(app.*);

    _ = try theme.spotifyCard(ctx, 1, theme.c_card_bg, true);
    defer ctx.pop();

    // 1. Top Navigation Bar (Header)
    {
        _ = try ctx.row(.{
            .justify = .space_between,
            .padding = .{ .bottom = 8 },
        });
        defer ctx.pop();

        // Left: Filter pills
        {
            _ = try ctx.row(.{ .gap = 8 });
            defer ctx.pop();
            _ = try theme.pillButton(ctx, "All", app.active_category == .all, App.selectCategoryAll);
            _ = try theme.pillButton(ctx, "Music", app.active_category == .music, App.selectCategoryMusic);
            _ = try theme.pillButton(
                ctx,
                "Podcasts",
                app.active_category == .podcasts,
                App.selectCategoryPodcasts,
            );
        }

        // Right: User Profile Pill
        {
            _ = try ctx.button(.{
                .label = "Janis (Premium)",
                .color = theme.c_text,
                .padding = .{ .left = 12, .right = 12, .top = 4, .bottom = 4 },
                .radius = .{ .top = 16, .right = 16, .bottom = 16, .left = 16 },
                .fill = theme.c_card_hover,
                .gradient = theme.srgbToOklab(theme.c_card_hover),
                .font_size = 12,
            });
        }
    }

    // 2. Hero Playlist Banner
    {
        _ = try ctx.row(.{
            .gap = 16,
            .padding = .{ .top = 16, .right = 16, .bottom = 16, .left = 16 },
            .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
            .fill = theme.c_hero_top,
            .gradient = theme.srgbToOklab(theme.c_hero_bot),
        });
        defer ctx.pop();

        // Album Artwork Placeholder
        {
            _ = try ctx.column(.{
                .basis = 80,
                .radius = .{ .top = 6, .right = 6, .bottom = 6, .left = 6 },
                .fill = theme.c_accent_dim,
                .gradient = theme.srgbToOklab(theme.c_accent),
                .padding = .{ .top = 28, .left = 14 },
            });
            defer ctx.pop();
            _ = try ctx.label(.{
                .text = "OST",
                .color = theme.c_text,
                .font_size = 18,
            });
        }

        // Playlist Meta Information
        {
            _ = try ctx.column(.{ .gap = 4, .grow = 1 });
            defer ctx.pop();

            _ = try ctx.label(.{
                .text = "PUBLIC PLAYLIST",
                .color = theme.c_text_muted,
                .font_size = 11,
            });

            _ = try ctx.label(.{
                .text = "Cyberpunk Ambient 2026",
                .color = theme.c_text,
                .font_size = 22,
            });

            _ = try ctx.label(.{
                .text = "Nocturnal synths, retro-futuristic soundscapes and deep focus beats.",
                .color = theme.c_text_sec,
                .font_size = 12,
            });

            _ = try ctx.label(.{
                .text = "Spotify • 1,482,910 saves • 7 songs, 32 min 8 sec",
                .color = theme.c_text_muted,
                .font_size = 11,
                .padding = .{ .top = 4 },
            });
        }
    }

    // 3. Action Bar (Big Play button, Save/Heart, More)
    {
        _ = try ctx.row(.{
            .gap = 12,
            .padding = .{ .top = 8, .bottom = 8 },
        });
        defer ctx.pop();

        const play_text = if (app.is_playing) "Pause" else "Play";
        _ = try ctx.button(.{
            .label = play_text,
            .on_click = App.togglePlay,
            .color = theme.c_bg,
            .padding = .{ .left = 24, .right = 24, .top = 8, .bottom = 8 },
            .radius = .{ .top = 20, .right = 20, .bottom = 20, .left = 20 },
            .fill = theme.c_accent,
            .gradient = theme.srgbToOklab(theme.c_accent_bright),
            .font_size = 14,
        });

        _ = try ctx.button(.{
            .label = if (app.playlist_saved) "♥ Saved" else "♥ Save",
            .on_click = App.togglePlaylistSaved,
            .color = theme.c_accent,
            .padding = .{ .left = 14, .right = 14, .top = 8, .bottom = 8 },
            .radius = .{ .top = 20, .right = 20, .bottom = 20, .left = 20 },
            .fill = theme.c_card_hover,
            .gradient = theme.srgbToOklab(theme.c_card_hover),
            .font_size = 13,
        });

        _ = try ctx.button(.{
            .label = "...",
            .color = theme.c_text_muted,
            .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
            .radius = .{ .top = 20, .right = 20, .bottom = 20, .left = 20 },
            .fill = theme.c_card_hover,
            .gradient = theme.srgbToOklab(theme.c_card_hover),
            .font_size = 13,
        });
    }

    try tracks.draw(app, ctx);
}
