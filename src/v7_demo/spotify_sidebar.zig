//! Sidebar view for the Spotify demo.

const DrawCtx = @import("v7/drawctx.zig").DrawCtx;
const theme = @import("spotify_theme.zig");
const Id = @import("v7/id.zig").Id;

pub fn draw(app: anytype, ctx: *DrawCtx) !void {
    const App = @TypeOf(app.*);

    _ = try ctx.column(.{
        .basis = 260,
        .shrink = 0,
        .gap = 8,
    });
    defer ctx.pop();

    {
        _ = try theme.spotifyCard(ctx, 0, theme.c_card_bg, false);
        defer ctx.pop();

        {
            _ = try ctx.row(.{
                .gap = 8,
                .@"align" = .center,
                .padding = .{ .bottom = 8, .left = 4 },
            });
            defer ctx.pop();
            _ = try ctx.label(.{
                .text = "●",
                .color = theme.c_accent,
                .font_size = 18,
            });
            _ = try ctx.label(.{
                .text = "Spotify",
                .color = theme.c_text,
                .font_size = 20,
            });
        }

        _ = try theme.spotifyButton(ctx, "⌂  Home", app.active_nav == .home, App.selectNavHome);
        _ = try theme.spotifyButton(ctx, "⌕  Search", app.active_nav == .search, App.selectNavSearch);
        _ = try theme.spotifyButton(ctx, "▥  Your Library", app.active_nav == .library, App.selectNavLibrary);
    }

    {
        _ = try theme.spotifyCard(ctx, 1, theme.c_card_bg, true);
        defer ctx.pop();

        {
            _ = try ctx.row(.{
                .justify = .space_between,
                .@"align" = .center,
                .padding = .{ .bottom = 6, .left = 4, .right = 4 },
            });
            defer ctx.pop();
            _ = try ctx.label(.{
                .text = "Your Library",
                .color = theme.c_text,
                .font_size = 14,
            });
            _ = try ctx.label(.{
                .text = "+",
                .color = theme.c_text_sec,
                .font_size = 18,
            });
        }

        {
            _ = try ctx.row(.{
                .gap = 6,
                .padding = .{ .bottom = 6 },
            });
            defer ctx.pop();
            _ = try filterPill(ctx, "Playlists", true);
            _ = try filterPill(ctx, "Artists", false);
            _ = try filterPill(ctx, "Albums", false);
        }

        _ = try ctx.column(.{
            .grow = 1,
            .scroll_state = &app.sidebar_scroll,
            .scroll_axis = .vertical,
            .gap = 2,
            .padding = .{ .top = 4, .bottom = 4 },
        });
        defer ctx.pop();

        try playlistRow(
            ctx,
            "Liked Songs",
            "Playlist • You",
            true,
            app.selected_playlist == .liked_songs,
            App.selectPlaylistLiked,
        );
        try playlistRow(
            ctx,
            app.playlists[0].name,
            "Playlist • Spotify",
            app.playlists[0].is_pinned,
            app.selected_playlist == .cyberpunk,
            App.selectPlaylist0,
        );
        try playlistRow(
            ctx,
            app.playlists[1].name,
            "Playlist • Spotify",
            app.playlists[1].is_pinned,
            app.selected_playlist == .discover_weekly,
            App.selectPlaylist1,
        );
        try playlistRow(
            ctx,
            app.playlists[2].name,
            "Playlist • Spotify",
            app.playlists[2].is_pinned,
            app.selected_playlist == .release_radar,
            App.selectPlaylist2,
        );
        try playlistRow(
            ctx,
            app.playlists[3].name,
            "Playlist • Spotify",
            app.playlists[3].is_pinned,
            app.selected_playlist == .daily_mix,
            App.selectPlaylist3,
        );
        try playlistRow(
            ctx,
            app.playlists[4].name,
            "Playlist • Spotify",
            app.playlists[4].is_pinned,
            app.selected_playlist == .deep_focus,
            App.selectPlaylist4,
        );
        try playlistRow(
            ctx,
            app.playlists[5].name,
            "Playlist • Spotify",
            app.playlists[5].is_pinned,
            app.selected_playlist == .chill_lofi,
            App.selectPlaylist5,
        );
    }
}

fn filterPill(ctx: *DrawCtx, text: []const u8, active: bool) !Id {
    const fill = if (active) theme.c_text else theme.c_card_hover;
    return ctx.label(.{
        .text = text,
        .color = if (active) theme.c_bg else theme.c_text,
        .font_size = 11,
        .padding = .{ .left = 10, .right = 10, .top = 4, .bottom = 4 },
        .radius = .{ .top = 14, .right = 14, .bottom = 14, .left = 14 },
        .fill = fill,
        .gradient = theme.srgbToOklab(fill),
    });
}

fn playlistRow(
    ctx: *DrawCtx,
    name: []const u8,
    subtitle: []const u8,
    pinned: bool,
    active: bool,
    comptime on_click: anytype,
) !void {
    const fill = if (active) theme.c_active_row else theme.c_card_bg;
    const marker = if (active) "▶" else if (pinned) "◆" else "•";

    _ = try ctx.row(.{
        .gap = 6,
        .@"align" = .center,
        .padding = .{ .left = 6, .right = 6, .top = 4, .bottom = 4 },
        .radius = .{ .top = 5, .right = 5, .bottom = 5, .left = 5 },
        .fill = fill,
        .gradient = theme.srgbToOklab(fill),
    });
    defer ctx.pop();

    _ = try ctx.label(.{
        .text = marker,
        .color = if (active) theme.c_accent else theme.c_text_muted,
        .font_size = 10,
        .basis = 14,
        .shrink = 0,
    });

    _ = try ctx.column(.{
        .grow = 1,
        .gap = 0,
        .clip = true,
    });
    defer ctx.pop();

    _ = try ctx.button(.{
        .label = name,
        .on_click = on_click,
        .color = if (active) theme.c_text else theme.c_text_sec,
        .font_size = 13,
        .padding = .{ .top = 1, .bottom = 1 },
        .fill = fill,
        .gradient = theme.srgbToOklab(fill),
        .text_overflow = .ellipsis,
    });
    _ = try ctx.label(.{
        .text = subtitle,
        .color = theme.c_text_muted,
        .font_size = 11,
        .text_overflow = .ellipsis,
    });
}
