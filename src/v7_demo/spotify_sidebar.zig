//! Sidebar view for the Spotify demo.
//!
//! The sidebar panel owns theme.c_sidebar_bg and every container under it
//! inherits that surface: each row and column here is `.transparent` unless
//! it paints a fill of its own, so no box falls back to the framework
//! container grey and patches the sidebar.

const nogui = @import("nogui");
const DrawCtx = nogui.DrawCtx;
const ComponentKey = nogui.ComponentKey;
const layout = @import("spotify_layout.zig");
const theme = @import("spotify_theme.zig");

const NavButton = struct {
    pub const default_style: nogui.Style = .{
        .direction = .row,
        .shrink = 0,
    };
    pub const default_paint: nogui.PaintStyle = .{
        .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
    };
};

pub fn draw(app: anytype, ctx: *DrawCtx, spec: layout.Spec) !void {
    const App = @TypeOf(app.*);
    const expanded = spec.show_sidebar_labels;

    _ = try ctx.column(.{
        .flex_basis = spec.sidebar_width,
        .grow = 0,
        .shrink = 0,
        .min_width = spec.sidebar_width,
        .gap = theme.sidebar_section_gap,
        .clip = true,
        .padding = .{
            .top = theme.sidebar_padding,
            .right = theme.sidebar_padding,
            .bottom = theme.sidebar_padding,
            .left = theme.sidebar_padding,
        },
        .fill = theme.c_sidebar_bg,
    });
    defer ctx.pop();

    {
        // The nav group only stacks the nav buttons, and each of those paints
        // its own row fill. Inherits the sidebar panel's theme.c_sidebar_bg.
        _ = try ctx.column(.{
            .gap = theme.sidebar_nav_gap,
            .shrink = 0,
            .clip = true,
            .transparent = true,
        });
        defer ctx.pop();

        try navButton(
            ctx,
            .{ .static = "nav-home" },
            "⌂",
            "⌂  Home",
            expanded,
            app.active_nav == .home,
            App.selectNavHome,
        );
        try navButton(
            ctx,
            .{ .static = "nav-search" },
            "⌕",
            "⌕  Search",
            expanded,
            app.active_nav == .search,
            App.selectNavSearch,
        );
        try navButton(
            ctx,
            .{ .static = "nav-library" },
            "▥",
            "▥  Your Library",
            expanded,
            app.active_nav == .library,
            App.selectNavLibrary,
        );
    }

    if (expanded) {
        try libraryHeader(ctx);
    }

    // The playlist list only scrolls the rows below it. Each row paints its
    // own fill or inherits the sidebar panel's theme.c_sidebar_bg.
    _ = try ctx.column(.{
        .grow = 1,
        .shrink = 1,
        .min_height = 0,
        .gap = theme.sidebar_row_gap,
        .scroll_state = &app.sidebar_scroll,
        .scroll_axis = .vertical,
        .clip = true,
        .transparent = true,
    });
    defer ctx.pop();

    const pl = app.playlists;
    try playlistRow(
        ctx,
        .{ .static = "sidebar-liked-songs" },
        "Liked Songs",
        "You",
        4,
        app.selected_playlist == .liked_songs,
        expanded,
        App.selectPlaylistLiked,
    );
    try playlistRow(
        ctx,
        .{ .static = "sidebar-cyberpunk" },
        pl[0].name,
        pl[0].author,
        pl[0].artwork_seed,
        app.selected_playlist == .cyberpunk,
        expanded,
        App.selectPlaylist0,
    );
    try playlistRow(
        ctx,
        .{ .static = "sidebar-discover-weekly" },
        pl[1].name,
        pl[1].author,
        pl[1].artwork_seed,
        app.selected_playlist == .discover_weekly,
        expanded,
        App.selectPlaylist1,
    );
    try playlistRow(
        ctx,
        .{ .static = "sidebar-release-radar" },
        pl[2].name,
        pl[2].author,
        pl[2].artwork_seed,
        app.selected_playlist == .release_radar,
        expanded,
        App.selectPlaylist2,
    );
    try playlistRow(
        ctx,
        .{ .static = "sidebar-daily-mix" },
        pl[3].name,
        pl[3].author,
        pl[3].artwork_seed,
        app.selected_playlist == .daily_mix,
        expanded,
        App.selectPlaylist3,
    );
    try playlistRow(
        ctx,
        .{ .static = "sidebar-deep-focus" },
        pl[4].name,
        pl[4].author,
        pl[4].artwork_seed,
        app.selected_playlist == .deep_focus,
        expanded,
        App.selectPlaylist4,
    );
    try playlistRow(
        ctx,
        .{ .static = "sidebar-chill-lofi" },
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
    key: ComponentKey,
    compact_label: []const u8,
    expanded_label: []const u8,
    expanded: bool,
    active: bool,
    comptime on_click: anytype,
) !void {
    const fill = if (active) theme.c_active_row else theme.c_sidebar_bg;
    const style = NavButton.default_style;
    const paint = NavButton.default_paint;

    if (!expanded) {
        // The compact row only centres the button, which paints its own fill.
        // Inherits the nav group's theme.c_sidebar_bg.
        _ = try ctx.row(.{
            .direction = style.direction,
            .flex_basis = theme.sidebar_nav_row_height,
            .min_height = theme.sidebar_nav_row_height,
            .shrink = style.shrink,
            .justify = .center,
            .@"align" = .center,
            .clip = true,
            .transparent = true,
        });
        defer ctx.pop();

        _ = try ctx.button(.{
            .key = key,
            .direction = style.direction,
            .label = expanded_label,
            .visual_label = compact_label,
            .accessible_label = expanded_label,
            .on_click = on_click,
            .flex_basis = theme.sidebar_compact_target_size,
            .min_width = theme.sidebar_compact_target_size,
            .grow = 0,
            .shrink = style.shrink,
            .color = if (active) theme.c_text else theme.c_text_sec,
            .font_size = 16,
            .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
            .radius = paint.radius,
            .fill = fill,
        });
        return;
    }

    _ = try ctx.button(.{
        .key = key,
        .direction = style.direction,
        .label = expanded_label,
        .on_click = on_click,
        .flex_basis = theme.sidebar_nav_row_height,
        .min_height = theme.sidebar_nav_row_height,
        .shrink = style.shrink,
        .justify = .start,
        .color = if (active) theme.c_text else theme.c_text_sec,
        .font_size = 13,
        .padding = .{ .left = 10, .right = 8, .top = 0, .bottom = 0 },
        .radius = paint.radius,
        .fill = fill,
        .text_overflow = .ellipsis,
    });
}

fn libraryHeader(ctx: *DrawCtx) !void {
    // The header only arranges its two labels, which paint no surface at all.
    // Inherits the sidebar panel's theme.c_sidebar_bg.
    _ = try ctx.row(.{
        .flex_basis = theme.sidebar_nav_row_height,
        .min_height = theme.sidebar_nav_row_height,
        .justify = .space_between,
        .@"align" = .center,
        .padding = .{ .left = 10, .right = 8 },
        .clip = true,
        .transparent = true,
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
    key: ComponentKey,
    name: []const u8,
    author: []const u8,
    artwork_seed: u8,
    active: bool,
    expanded: bool,
    comptime on_click: anytype,
) !void {
    if (active) {
        _ = try ctx.row(.{
            .flex_basis = theme.sidebar_row_height,
            .min_height = theme.sidebar_row_height,
            .shrink = 0,
            .@"align" = .center,
            .justify = @as(nogui.Justify, if (expanded) .start else .center),
            .gap = if (expanded) theme.sidebar_section_gap else 0,
            .padding = .{
                .left = if (expanded) @as(f32, 6) else @as(f32, 0),
                .right = if (expanded) @as(f32, 6) else @as(f32, 0),
                .top = 4,
                .bottom = 4,
            },
            .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
            .fill = theme.c_active_row,
            .clip = true,
        });
    } else {
        // An inactive row paints no surface of its own, so the scroll column's
        // theme.c_sidebar_bg shows through. That is the surface the selected
        // row above replaces with theme.c_active_row.
        _ = try ctx.row(.{
            .flex_basis = theme.sidebar_row_height,
            .min_height = theme.sidebar_row_height,
            .shrink = 0,
            .@"align" = .center,
            .justify = @as(nogui.Justify, if (expanded) .start else .center),
            .gap = if (expanded) theme.sidebar_section_gap else 0,
            .padding = .{
                .left = if (expanded) @as(f32, 6) else @as(f32, 0),
                .right = if (expanded) @as(f32, 6) else @as(f32, 0),
                .top = 4,
                .bottom = 4,
            },
            .clip = true,
            .transparent = true,
        });
    }
    defer ctx.pop();

    if (!expanded) {
        _ = try ctx.button(.{
            .key = key,
            .label = name,
            .visual_label = theme.compactArtworkMark(artwork_seed),
            .accessible_label = name,
            .on_click = on_click,
            .flex_basis = theme.sidebar_compact_target_size,
            .min_width = theme.sidebar_compact_target_size,
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
    // The copy column only arranges the transparent title button and the
    // author label. Inherits the row's surface: theme.c_active_row while the
    // playlist is selected, theme.c_sidebar_bg otherwise.
    _ = try ctx.column(.{
        .grow = 1,
        .shrink = 1,
        .min_width = 0,
        .gap = theme.sidebar_playlist_copy_gap,
        .transparent = true,
    });
    defer ctx.pop();

    _ = try ctx.button(.{
        .key = key,
        .label = name,
        .on_click = on_click,
        .grow = 1,
        .shrink = 1,
        .min_height = 0,
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
