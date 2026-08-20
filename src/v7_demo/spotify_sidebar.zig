//! Sidebar view for the Spotify demo.

const DrawCtx = @import("v7/drawctx.zig").DrawCtx;
const flex = @import("v7/flex.zig");
const layout = @import("spotify_layout.zig");
const theme = @import("spotify_theme.zig");

/// Compatibility alias for callers that use the full desktop sidebar width.
pub const width: f32 = theme.sidebar_width_full;

pub fn draw(app: anytype, ctx: *DrawCtx, spec: layout.Spec) !void {
    const App = @TypeOf(app.*);
    const expanded = spec.show_sidebar_labels;

    _ = try ctx.column(.{
        .basis = spec.sidebar_width,
        .grow = 0,
        .shrink = 0,
        .min_main = spec.sidebar_width,
        .gap = theme.sidebar_section_gap,
        .clip = true,
        .padding = .{
            .top = theme.sidebar_padding,
            .right = theme.sidebar_padding,
            .bottom = theme.sidebar_padding,
            .left = theme.sidebar_padding,
        },
        .fill = theme.c_sidebar_bg,
        .gradient = theme.srgbToOklab(theme.c_sidebar_bg),
    });
    defer ctx.pop();

    {
        _ = try ctx.column(.{
            .gap = theme.sidebar_nav_gap,
            .shrink = 0,
            .clip = true,
        });
        defer ctx.pop();

        try navButton(ctx, "⌂", "⌂  Home", expanded, app.active_nav == .home, App.selectNavHome);
        try navButton(ctx, "⌕", "⌕  Search", expanded, app.active_nav == .search, App.selectNavSearch);
        try navButton(ctx, "▥", "▥  Your Library", expanded, app.active_nav == .library, App.selectNavLibrary);
    }

    if (expanded) {
        try libraryHeader(ctx);
    }

    _ = try ctx.column(.{
        .grow = 1,
        .shrink = 1,
        .min_main = 0,
        .gap = theme.sidebar_row_gap,
        .scroll_state = &app.sidebar_scroll,
        .scroll_axis = .vertical,
        .clip = true,
    });
    defer ctx.pop();

    const pl = app.playlists;
    try playlistRow(
        ctx,
        "Liked Songs",
        "You",
        4,
        app.selected_playlist == .liked_songs,
        expanded,
        App.selectPlaylistLiked,
    );
    try playlistRow(
        ctx,
        pl[0].name,
        pl[0].author,
        pl[0].artwork_seed,
        app.selected_playlist == .cyberpunk,
        expanded,
        App.selectPlaylist0,
    );
    try playlistRow(
        ctx,
        pl[1].name,
        pl[1].author,
        pl[1].artwork_seed,
        app.selected_playlist == .discover_weekly,
        expanded,
        App.selectPlaylist1,
    );
    try playlistRow(
        ctx,
        pl[2].name,
        pl[2].author,
        pl[2].artwork_seed,
        app.selected_playlist == .release_radar,
        expanded,
        App.selectPlaylist2,
    );
    try playlistRow(
        ctx,
        pl[3].name,
        pl[3].author,
        pl[3].artwork_seed,
        app.selected_playlist == .daily_mix,
        expanded,
        App.selectPlaylist3,
    );
    try playlistRow(
        ctx,
        pl[4].name,
        pl[4].author,
        pl[4].artwork_seed,
        app.selected_playlist == .deep_focus,
        expanded,
        App.selectPlaylist4,
    );
    try playlistRow(
        ctx,
        pl[5].name,
        pl[5].author,
        pl[5].artwork_seed,
        app.selected_playlist == .chill_lofi,
        expanded,
        App.selectPlaylist5,
    );
}

fn navButton(
    ctx: *DrawCtx,
    compact_label: []const u8,
    expanded_label: []const u8,
    expanded: bool,
    active: bool,
    comptime on_click: anytype,
) !void {
    const fill = if (active) theme.c_active_row else theme.c_sidebar_bg;

    if (!expanded) {
        _ = try ctx.row(.{
            .basis = theme.sidebar_nav_row_height,
            .min_main = theme.sidebar_nav_row_height,
            .shrink = 0,
            .justify = .center,
            .@"align" = .center,
            .clip = true,
        });
        defer ctx.pop();

        _ = try ctx.button(.{
            .label = expanded_label,
            .visual_label = compact_label,
            .accessible_label = expanded_label,
            .on_click = on_click,
            .basis = theme.sidebar_compact_target_size,
            .min_main = theme.sidebar_compact_target_size,
            .grow = 0,
            .shrink = 0,
            .color = if (active) theme.c_text else theme.c_text_sec,
            .font_size = 16,
            .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
            .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
            .fill = fill,
            .gradient = theme.srgbToOklab(fill),
        });
        return;
    }

    _ = try ctx.button(.{
        .label = expanded_label,
        .on_click = on_click,
        .basis = theme.sidebar_nav_row_height,
        .min_main = theme.sidebar_nav_row_height,
        .shrink = 0,
        .justify = .start,
        .color = if (active) theme.c_text else theme.c_text_sec,
        .font_size = 13,
        .padding = .{ .left = 10, .right = 8, .top = 0, .bottom = 0 },
        .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
        .fill = fill,
        .gradient = theme.srgbToOklab(fill),
        .text_overflow = .ellipsis,
    });
}

fn libraryHeader(ctx: *DrawCtx) !void {
    _ = try ctx.row(.{
        .basis = theme.sidebar_nav_row_height,
        .min_main = theme.sidebar_nav_row_height,
        .justify = .space_between,
        .@"align" = .center,
        .padding = .{ .left = 10, .right = 8 },
        .clip = true,
    });
    defer ctx.pop();

    _ = try ctx.label(.{
        .text = "Your Library",
        .color = theme.c_text,
        .font_size = 13,
        .text_overflow = .ellipsis,
    });
    _ = try ctx.label(.{ .text = "+", .color = theme.c_text_muted, .font_size = 16 });
}

fn playlistRow(
    ctx: *DrawCtx,
    name: []const u8,
    author: []const u8,
    artwork_seed: u8,
    active: bool,
    expanded: bool,
    comptime on_click: anytype,
) !void {
    if (active) {
        _ = try ctx.row(.{
            .basis = theme.sidebar_row_height,
            .min_main = theme.sidebar_row_height,
            .shrink = 0,
            .@"align" = .center,
            .justify = @as(flex.Justify, if (expanded) .start else .center),
            .gap = if (expanded) theme.sidebar_section_gap else 0,
            .padding = .{
                .left = if (expanded) @as(f32, 6) else @as(f32, 0),
                .right = if (expanded) @as(f32, 6) else @as(f32, 0),
                .top = 4,
                .bottom = 4,
            },
            .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
            .fill = theme.c_active_row,
            .gradient = theme.srgbToOklab(theme.c_active_row),
            .clip = true,
        });
    } else {
        _ = try ctx.row(.{
            .basis = theme.sidebar_row_height,
            .min_main = theme.sidebar_row_height,
            .shrink = 0,
            .@"align" = .center,
            .justify = @as(flex.Justify, if (expanded) .start else .center),
            .gap = if (expanded) theme.sidebar_section_gap else 0,
            .padding = .{
                .left = if (expanded) @as(f32, 6) else @as(f32, 0),
                .right = if (expanded) @as(f32, 6) else @as(f32, 0),
                .top = 4,
                .bottom = 4,
            },
            .clip = true,
        });
    }
    defer ctx.pop();

    if (!expanded) {
        _ = try ctx.button(.{
            .label = name,
            .visual_label = theme.compactArtworkMark(artwork_seed),
            .accessible_label = name,
            .on_click = on_click,
            .basis = theme.sidebar_compact_target_size,
            .min_main = theme.sidebar_compact_target_size,
            .grow = 0,
            .shrink = 0,
            .color = if (active) theme.c_text else theme.c_text_sec,
            .font_size = 13,
            .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
            .transparent = true,
        });
        return;
    }

    _ = try theme.drawArtworkTile(ctx, theme.playlist_artwork_size, artwork_seed, null);
    _ = try ctx.column(.{ .grow = 1, .shrink = 1, .min_main = 0, .gap = theme.sidebar_playlist_copy_gap });
    defer ctx.pop();

    _ = try ctx.button(.{
        .label = name,
        .on_click = on_click,
        .grow = 1,
        .shrink = 1,
        .min_main = 0,
        .justify = .start,
        .color = if (active) theme.c_text else theme.c_text_sec,
        .transparent = true,
        .font_size = theme.sidebar_playlist_title_size,
        .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
        .text_overflow = .ellipsis,
    });
    _ = try ctx.label(.{
        .text = author,
        .color = theme.c_text_muted,
        .font_size = theme.sidebar_playlist_metadata_size,
        .text_overflow = .ellipsis,
    });
}
