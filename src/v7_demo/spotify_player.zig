//! Bottom player bar view for the Spotify demo.

const std = @import("std");
const DrawCtx = @import("v7/drawctx.zig").DrawCtx;
const widget = @import("v7/widget.zig");
const theme = @import("spotify_theme.zig");

const player_tracks = [_]widget.ColumnTrack{
    .{ .basis = 270, .grow = 0, .shrink = 1, .min_main = 118 },
    .{ .basis = 440, .grow = 1, .shrink = 1, .min_main = 142 },
    .{ .basis = 210, .grow = 0, .shrink = 1, .min_main = 88 },
};
const player_columns: widget.SharedColumns = .{ .tracks = &player_tracks };

pub fn draw(app: anytype, ctx: *DrawCtx) !void {
    const App = @TypeOf(app.*);
    const track_index = if (app.current_track_idx < app.tracks.len) app.current_track_idx else 0;
    const current_track = app.tracks[track_index];

    _ = try ctx.row(.{
        .columns = &player_columns,
        .basis = 82,
        .shrink = 0,
        .gap = 12,
        .clip = true,
        .padding = .{ .left = 14, .right = 14, .top = 8, .bottom = 8 },
        .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
        .fill = theme.c_player_bg,
        .gradient = theme.srgbToOklab(theme.c_player_bg),
        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
        .border_color = theme.c_border,
    });
    defer ctx.pop();

    try drawTrackInfo(App, current_track, ctx);
    try drawTransport(App, app, current_track, ctx);
    try drawPlayerActions(app, ctx);
}

fn drawTrackInfo(comptime App: type, track: anytype, ctx: *DrawCtx) !void {
    _ = try ctx.row(.{ .gap = 10, .shrink = 1, .clip = true, .@"align" = .center });
    defer ctx.pop();

    _ = try theme.drawArtworkTile(ctx, 48, track.artwork_seed);

    {
        _ = try ctx.column(.{ .grow = 1, .shrink = 1, .min_main = 24, .gap = 2, .clip = true });
        defer ctx.pop();
        _ = try ctx.label(.{
            .text = track.title,
            .text_overflow = .ellipsis,
            .max_width = 176,
            .color = theme.c_text,
            .font_size = 13,
        });
        _ = try ctx.label(.{
            .text = track.artist,
            .text_overflow = .ellipsis,
            .max_width = 176,
            .color = theme.c_text_sec,
            .font_size = 11,
        });
    }

    _ = try ctx.button(.{
        .label = if (track.is_liked) "♥" else "♡",
        .on_click = App.toggleCurrentLike,
        .basis = 28,
        .shrink = 1,
        .min_main = 24,
        .color = if (track.is_liked) theme.c_like_active else theme.c_text_muted,
        .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 },
        .radius = .{ .top = 14, .right = 14, .bottom = 14, .left = 14 },
        .fill = theme.c_player_bg,
        .gradient = theme.srgbToOklab(theme.c_player_bg),
        .font_size = 15,
    });
}

fn drawTransport(comptime App: type, app: anytype, track: anytype, ctx: *DrawCtx) !void {
    _ = try ctx.column(.{ .grow = 1, .shrink = 1, .min_main = 142, .gap = 5, .clip = true });
    defer ctx.pop();

    {
        _ = try ctx.row(.{ .gap = 8, .clip = true, .justify = .center });
        defer ctx.pop();
        try drawTransportButton(ctx, "⇄", App.toggleShuffle, app.shuffle, 26);
        try drawTransportButton(ctx, "|◀", App.prevTrack, false, 30);
        _ = try ctx.button(.{
            .label = if (app.is_playing) "⏸" else "▶",
            .on_click = App.togglePlay,
            .basis = 36,
            .shrink = 1,
            .min_main = 32,
            .color = theme.c_bg,
            .padding = .{ .left = 9, .right = 9, .top = 7, .bottom = 7 },
            .radius = .{ .top = 20, .right = 20, .bottom = 20, .left = 20 },
            .fill = theme.c_text,
            .gradient = theme.srgbToOklab(theme.c_text),
            .font_size = 13,
        });
        try drawTransportButton(ctx, "▶|", App.nextTrack, false, 30);
        try drawTransportButton(ctx, "↻", App.toggleRepeat, app.repeat, 26);
    }

    {
        _ = try ctx.row(.{ .gap = 7, .clip = true, .@"align" = .center });
        defer ctx.pop();
        const duration_sec: f32 = @floatFromInt(track.duration_sec);
        const elapsed_sec = @max(@as(f32, 0), @min(app.progress_sec, duration_sec));
        const elapsed_minutes: u32 = @intFromFloat(elapsed_sec / 60.0);
        const elapsed_seconds: u32 = @intFromFloat(@mod(elapsed_sec, 60.0));
        const elapsed_text = try std.fmt.allocPrint(
            ctx.arena,
            "{d}:{d:0>2}",
            .{ elapsed_minutes, elapsed_seconds },
        );
        _ = try ctx.label(.{
            .text = elapsed_text,
            .color = theme.c_text_muted,
            .font_size = 10,
        });
        _ = try ctx.slider(.{
            .label = "seek",
            .value = &app.progress_sec,
            .min = 0,
            .max = duration_sec,
            .grow = 1,
            .shrink = 1,
            .basis = 100,
            .min_main = 36,
            .color = theme.c_accent,
            .padding = .{ .left = 2, .right = 2 },
        });
        _ = try ctx.label(.{
            .text = track.duration_str,
            .color = theme.c_text_muted,
            .font_size = 10,
        });
    }
}

fn drawTransportButton(
    ctx: *DrawCtx,
    label: []const u8,
    handler: anytype,
    active: bool,
    basis: f32,
) !void {
    _ = try ctx.button(.{
        .label = label,
        .on_click = handler,
        .basis = basis,
        .shrink = 1,
        .min_main = basis,
        .color = if (active) theme.c_accent else theme.c_text_sec,
        .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 },
        .radius = .{ .top = 14, .right = 14, .bottom = 14, .left = 14 },
        .fill = theme.c_player_bg,
        .gradient = theme.srgbToOklab(theme.c_player_bg),
        .font_size = 12,
    });
}

fn drawPlayerActions(app: anytype, ctx: *DrawCtx) !void {
    _ = try ctx.row(.{ .gap = 7, .shrink = 1, .min_main = 88, .clip = true, .@"align" = .center });
    defer ctx.pop();

    _ = try ctx.button(.{
        .label = "☷",
        .basis = 24,
        .shrink = 1,
        .min_main = 20,
        .color = theme.c_text_sec,
        .padding = .{ .left = 3, .right = 3, .top = 4, .bottom = 4 },
        .radius = .{ .top = 12, .right = 12, .bottom = 12, .left = 12 },
        .fill = theme.c_player_bg,
        .gradient = theme.srgbToOklab(theme.c_player_bg),
        .font_size = 14,
    });
    _ = try ctx.button(.{
        .label = "▣",
        .basis = 24,
        .shrink = 1,
        .min_main = 20,
        .color = theme.c_text_sec,
        .padding = .{ .left = 3, .right = 3, .top = 4, .bottom = 4 },
        .radius = .{ .top = 12, .right = 12, .bottom = 12, .left = 12 },
        .fill = theme.c_player_bg,
        .gradient = theme.srgbToOklab(theme.c_player_bg),
        .font_size = 14,
    });
    _ = try ctx.label(.{ .text = "🔊", .color = theme.c_text_sec, .font_size = 12 });
    _ = try ctx.slider(.{
        .label = "volume",
        .value = &app.volume,
        .min = 0.0,
        .max = 1.0,
        .grow = 1,
        .shrink = 1,
        .basis = 72,
        .min_main = 26,
        .color = theme.c_accent,
        .padding = .{ .left = 2, .right = 2 },
    });
}
