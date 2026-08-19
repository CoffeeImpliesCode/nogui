//! Main playlist header and action view for the Spotify demo.

const DrawCtx = @import("v7/drawctx.zig").DrawCtx;
const widget = @import("v7/widget.zig");
const layout = @import("spotify_layout.zig");
const theme = @import("spotify_theme.zig");
const tracks = @import("spotify_tracks.zig");

const header_tracks = [_]widget.ColumnTrack{
    .{ .basis = 520, .grow = 1, .min_main = 180 },
    .{ .basis = 100, .min_main = 76 },
};
const header_columns: widget.SharedColumns = .{ .tracks = &header_tracks };
const hero_content_max_width: f32 = 360;

pub fn draw(app: anytype, ctx: *DrawCtx, spec: layout.Spec) !void {
    const App = @TypeOf(app.*);

    _ = try ctx.column(.{ .grow = 1, .scroll_state = &app.content_scroll, .fill = theme.c_bg });
    defer ctx.pop();

    try drawHeader(App, app, ctx, spec);
    try drawHero(app, ctx, spec);
    try drawActions(App, app, ctx, spec);
    try tracks.draw(app, ctx, spec);
}

fn drawHeader(comptime App: type, app: anytype, ctx: *DrawCtx, spec: layout.Spec) !void {
    _ = try ctx.row(.{
        .columns = &header_columns,
        .gap = theme.header_control_gap,
        .@"align" = .center,
        .padding = .{
            .top = theme.header_gutter_y,
            .right = theme.content_gutter,
            .bottom = theme.header_gutter_y,
            .left = theme.content_gutter,
        },
        .fill = theme.c_bg,
    });
    defer ctx.pop();

    {
        _ = try ctx.row(.{ .gap = theme.header_control_gap, .@"align" = .center });
        defer ctx.pop();

        try drawCircleButton(ctx, "<", theme.c_text, 14, .{
            .basis = 26,
            .fill = theme.c_card_elevated,
        });
        if (spec.mode != .compact) {
            try drawCircleButton(ctx, ">", theme.c_text, 14, .{
                .basis = 26,
                .fill = theme.c_card_elevated,
            });
        }
        _ = try ctx.button(.{
            .label = "Search  What do you want to play?",
            .on_click = App.selectNavSearch,
            .grow = 1,
            .shrink = 1,
            .min_main = 0,
            .max_width = 240,
            .text_overflow = .ellipsis,
            .justify = .start,
            .box_sizing = .border_box,
            .color = theme.c_text_sec,
            .padding = .{ .left = 12, .right = 12, .top = 7, .bottom = 7 },
            .radius = .{ .top = 16, .right = 16, .bottom = 16, .left = 16 },
            .fill = theme.c_card_elevated,
            .font_size = 12,
        });
        if (spec.mode != .compact) {
            try drawFilterPill(ctx, "All", app.active_category == .all, App.selectCategoryAll);
            try drawFilterPill(ctx, "Music", app.active_category == .music, App.selectCategoryMusic);
            try drawFilterPill(ctx, "Podcasts", app.active_category == .podcasts, App.selectCategoryPodcasts);
        }
    }

    if (spec.mode != .compact) _ = try drawProfilePill(ctx, "Janis");
}

fn drawFilterPill(ctx: *DrawCtx, text: []const u8, active: bool, on_click: anytype) !void {
    _ = try ctx.button(.{
        .label = text,
        .on_click = on_click,
        .color = if (active) theme.c_bg else theme.c_text,
        .padding = .{ .left = 10, .right = 10, .top = 5, .bottom = 5 },
        .radius = .{ .top = 14, .right = 14, .bottom = 14, .left = 14 },
        .fill = if (active) theme.c_text else theme.c_hover,
        .font_size = 11,
    });
}

fn drawCircleButton(
    ctx: *DrawCtx,
    label: []const u8,
    color: [4]f32,
    font_size: f32,
    options: anytype,
) !void {
    const bordered: bool = if (@hasField(@TypeOf(options), "bordered")) options.bordered else false;
    const has_on_click = @hasField(@TypeOf(options), "on_click");
    const half: f32 = options.basis * 0.5;
    const border: f32 = if (bordered) 1 else 0;
    if (has_on_click) {
        _ = try ctx.button(.{
            .label = label,
            .on_click = options.on_click,
            .basis = options.basis,
            .shrink = 0,
            .box_sizing = .border_box,
            .color = color,
            .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 },
            .radius = .{ .top = half, .right = half, .bottom = half, .left = half },
            .fill = options.fill,
            .border = .{ .top = border, .right = border, .bottom = border, .left = border },
            .border_color = theme.c_border,
            .font_size = font_size,
        });
        return;
    }
    _ = try ctx.button(.{
        .label = label,
        .basis = options.basis,
        .shrink = 0,
        .box_sizing = .border_box,
        .color = color,
        .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 },
        .radius = .{ .top = half, .right = half, .bottom = half, .left = half },
        .fill = options.fill,
        .border = .{ .top = border, .right = border, .bottom = border, .left = border },
        .border_color = theme.c_border,
        .font_size = font_size,
    });
}

fn drawProfilePill(ctx: *DrawCtx, name: []const u8) !void {
    _ = try ctx.row(.{
        .gap = 6,
        .@"align" = .center,
        .padding = .{ .left = 6, .right = 10, .top = 4, .bottom = 4 },
        .radius = .{ .top = 14, .right = 14, .bottom = 14, .left = 14 },
        .fill = theme.c_card_elevated,
    });
    defer ctx.pop();

    _ = try drawCircleButton(ctx, "J", theme.c_bg, 12, .{
        .basis = 20,
        .fill = theme.c_accent,
    });
    _ = try ctx.label(.{ .text = name, .text_overflow = .ellipsis, .color = theme.c_text, .font_size = 12 });
}

fn drawHero(app: anytype, ctx: *DrawCtx, spec: layout.Spec) !void {
    _ = try ctx.row(.{
        .gap = theme.hero_content_gap,
        .@"align" = .center,
        .padding = .{
            .top = theme.hero_gutter_top,
            .right = theme.hero_gutter,
            .bottom = theme.hero_gutter_bottom,
            .left = theme.hero_gutter,
        },
    });
    defer ctx.pop();

    if (spec.mode == .desktop) {
        _ = try theme.drawArtworkTile(ctx, theme.hero_artwork_size, app.playlists[0].artwork_seed);
    }

    _ = try ctx.column(.{
        .grow = 1,
        .shrink = 1,
        .min_main = 0,
        .box_sizing = .border_box,
        .gap = 7,
    });
    defer ctx.pop();

    _ = try ctx.label(.{
        .text = "PUBLIC PLAYLIST",
        .shrink = 1,
        .min_main = 0,
        .max_width = hero_content_max_width,
        .text_overflow = .ellipsis,
        .color = theme.c_text_sec,
        .font_size = theme.hero_overline_size,
    });
    _ = try ctx.label(.{
        .text = "Cyberpunk Ambient 2026",
        .shrink = 1,
        .min_main = 0,
        .max_width = hero_content_max_width,
        .text_overflow = .ellipsis,
        .color = theme.c_text,
        .font_size = theme.hero_title_size,
    });
    _ = try ctx.label(.{
        .text = "Nocturnal synths, retro-futuristic soundscapes and deep focus beats.",
        .shrink = 1,
        .min_main = 0,
        .max_width = hero_content_max_width,
        .text_overflow = .ellipsis,
        .color = theme.c_text_sec,
        .font_size = theme.hero_description_size,
    });
    _ = try ctx.label(.{
        .text = "Spotify • 1,482,910 saves • 7 songs, 32 min 8 sec",
        .shrink = 1,
        .min_main = 0,
        .max_width = hero_content_max_width,
        .text_overflow = .ellipsis,
        .color = theme.c_text,
        .font_size = theme.hero_metadata_size,
        .padding = .{ .top = 5 },
    });
}

fn drawActions(comptime App: type, app: anytype, ctx: *DrawCtx, spec: layout.Spec) !void {
    _ = try ctx.row(.{
        .gap = if (spec.mode == .compact)
            theme.action_control_gap_compact
        else
            theme.action_control_gap,
        .@"align" = .center,
        .padding = .{
            .top = theme.action_gutter_y,
            .right = theme.content_gutter,
            .bottom = theme.action_gutter_y,
            .left = theme.content_gutter,
        },
        .fill = theme.c_bg,
    });
    defer ctx.pop();

    _ = try ctx.button(.{
        .label = if (app.is_playing) "||" else ">",
        .on_click = App.togglePlay,
        .basis = 48,
        .shrink = 0,
        .box_sizing = .border_box,
        .color = theme.c_bg,
        .padding = .{ .left = 13, .right = 13, .top = 11, .bottom = 11 },
        .radius = .{ .top = 24, .right = 24, .bottom = 24, .left = 24 },
        .fill = theme.c_accent,
        .gradient = theme.srgbToOklab(theme.c_accent_hover),
        .font_size = 18,
    });
    try drawCircleButton(
        ctx,
        if (app.playlist_saved) "♥" else "+",
        if (app.playlist_saved) theme.c_accent else theme.c_text_sec,
        15,
        .{ .basis = 32, .fill = theme.c_bg, .on_click = App.togglePlaylistSaved },
    );
    try drawCircleButton(ctx, "...", theme.c_text_sec, 14, .{
        .basis = 32,
        .fill = theme.c_bg,
    });
}
