//! Bottom player bar view for the Spotify demo.

const std = @import("std");
const DrawCtx = @import("v7/drawctx.zig").DrawCtx;
const widget = @import("v7/widget.zig");
const layout = @import("spotify_layout.zig");
const theme = @import("spotify_theme.zig");

// Shared 3-column shell: wide stable Now-Playing, flexible Transport,
// stable Volume. Side columns keep their width so play controls never
// jitter as track metadata changes.
const player_tracks = [_]widget.ColumnTrack{
    .{ .basis = 240, .grow = 0, .shrink = 1, .min_main = 120 },
    .{ .basis = 0, .grow = 1, .shrink = 1, .min_main = 200 },
    .{ .basis = 200, .grow = 0, .shrink = 1, .min_main = 120 },
};
const player_columns: widget.SharedColumns = .{ .tracks = &player_tracks };

pub fn draw(app: anytype, ctx: *DrawCtx, spec: layout.Spec) !void {
    _ = spec;
    const App = @TypeOf(app.*);
    const track_index = if (app.current_track_idx < app.tracks.len) app.current_track_idx else 0;
    const current_track = app.tracks[track_index];

    _ = try ctx.row(.{
        .columns = &player_columns,
        .basis = theme.player_height,
        .min_main = theme.player_height,
        .shrink = 0,
        .gap = 16,
        .clip = true,
        .padding = .{ .left = 16, .right = 16, .top = 8, .bottom = 8 },
        .fill = theme.c_player_bg,
        .gradient = theme.srgbToOklab(theme.c_player_bg),
        .border = .{ .top = 1 },
        .border_color = theme.c_border,
    });
    defer ctx.pop();

    try drawNowPlaying(App, current_track, ctx);
    try drawTransport(App, app, current_track, ctx);
    try drawVolume(app, ctx);
}

fn drawNowPlaying(comptime App: type, track: anytype, ctx: *DrawCtx) !void {
    _ = try ctx.row(.{ .gap = 8, .shrink = 1, .min_main = 0, .clip = true, .@"align" = .center });
    defer ctx.pop();

    _ = try theme.drawArtworkTile(ctx, 36, track.artwork_seed);

    {
        _ = try ctx.column(.{ .grow = 1, .shrink = 1, .min_main = 20, .gap = 2, .clip = true });
        defer ctx.pop();
        _ = try ctx.label(.{
            .text = track.title,
            .text_overflow = .ellipsis,
            .color = theme.c_text,
            .font_size = 11,
        });
        _ = try ctx.label(.{
            .text = track.artist,
            .text_overflow = .ellipsis,
            .color = theme.c_player_utility,
            .font_size = 9,
        });
    }

    _ = try ctx.button(.{
        .label = if (track.is_liked) "♥" else "♡",
        .on_click = App.toggleCurrentLike,
        .basis = 22,
        .shrink = 1,
        .min_main = 18,
        .color = if (track.is_liked) theme.c_player_progress else theme.c_player_utility,
        .padding = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 },
        .font_size = 13,
        .fill = theme.c_player_control_bg,
        .gradient = theme.srgbToOklab(theme.c_player_control_bg),
    });
}

fn drawTransport(comptime App: type, app: anytype, track: anytype, ctx: *DrawCtx) !void {
    _ = try ctx.column(.{ .grow = 1, .shrink = 1, .min_main = 200, .gap = 6, .clip = true, .@"align" = .center });
    defer ctx.pop();

    {
        _ = try ctx.row(.{ .gap = 8, .clip = true, .justify = .center });
        defer ctx.pop();
        try drawTransportButton(ctx, "S", App.toggleShuffle, app.shuffle, 24);
        try drawTransportButton(ctx, "|<", App.prevTrack, false, 24);
        _ = try ctx.button(.{
            .label = if (app.is_playing) "||" else ">",
            .on_click = App.togglePlay,
            .basis = 32,
            .shrink = 0,
            .min_main = 32,
            .color = theme.c_bg,
            .padding = .{ .left = 8, .right = 8, .top = 6, .bottom = 6 },
            .radius = .{ .top = 16, .right = 16, .bottom = 16, .left = 16 },
            .fill = theme.c_text,
            .gradient = theme.srgbToOklab(theme.c_text),
            .font_size = 12,
        });
        try drawTransportButton(ctx, ">|", App.nextTrack, false, 24);
        try drawTransportButton(ctx, "R", App.toggleRepeat, app.repeat, 24);
    }

    {
        _ = try ctx.row(.{ .gap = 6, .clip = true, .@"align" = .center });
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
        {
            _ = try ctx.row(.{ .basis = 28, .shrink = 0, .justify = .end, .clip = true });
            defer ctx.pop();
            _ = try ctx.label(.{ .text = elapsed_text, .color = theme.c_player_utility, .font_size = 9 });
        }
        _ = try ctx.slider(.{
            .label = "seek",
            .visual_label = "",
            .value = &app.progress_sec,
            .min = 0,
            .max = duration_sec,
            .grow = 1,
            .shrink = 1,
            .basis = 100,
            .min_main = 100,
            .color = theme.c_player_progress,
            .padding = .{ .left = 1, .right = 1 },
        });
        _ = try ctx.label(.{
            .text = track.duration_str,
            .color = theme.c_player_utility,
            .font_size = 9,
            .basis = 28,
            .shrink = 0,
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
        .color = if (active) theme.c_player_progress else theme.c_player_utility,
        .padding = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 },
        .fill = theme.c_player_control_bg,
        .gradient = theme.srgbToOklab(theme.c_player_control_bg),
        .font_size = 12,
    });
}

fn drawVolume(app: anytype, ctx: *DrawCtx) !void {
    _ = try ctx.row(.{ .gap = 6, .shrink = 1, .min_main = 0, .clip = true, .@"align" = .center });
    defer ctx.pop();

    _ = try ctx.button(.{
        .label = "=",
        .basis = 22,
        .shrink = 1,
        .min_main = 18,
        .color = theme.c_player_utility,
        .padding = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 },
        .fill = theme.c_player_control_bg,
        .gradient = theme.srgbToOklab(theme.c_player_control_bg),
        .font_size = 12,
    });
    _ = try ctx.button(.{
        .label = "[]",
        .basis = 22,
        .shrink = 1,
        .min_main = 18,
        .color = theme.c_player_utility,
        .padding = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 },
        .fill = theme.c_player_control_bg,
        .gradient = theme.srgbToOklab(theme.c_player_control_bg),
        .font_size = 12,
    });
    _ = try ctx.label(.{ .text = "<", .color = theme.c_player_utility, .font_size = 12 });
    _ = try ctx.slider(.{
        .label = "volume",
        .visual_label = "",
        .value = &app.volume,
        .min = 0.0,
        .max = 1.0,
        .grow = 0,
        .shrink = 1,
        .basis = 100,
        .min_main = 100,
        .color = theme.c_player_utility,
        .padding = .{ .left = 1, .right = 1 },
    });
}
