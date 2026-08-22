//! Bottom player bar view for the Spotify demo.

const std = @import("std");
const nogui = @import("nogui");
const DrawCtx = nogui.DrawCtx;
const widget = nogui.widget;
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
    const current_track = app.currentTrack();

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

    if (current_track) |track| {
        try drawNowPlaying(App, track, ctx);
        try drawTransport(App, app, track, ctx);
    } else {
        try drawUnavailable(ctx);
    }
    try drawVolume(app, ctx);
}

fn drawUnavailable(ctx: *DrawCtx) !void {
    _ = try ctx.label(.{
        .text = "No playable track",
        .grow = 1,
        .shrink = 1,
        .min_main = 120,
        .text_overflow = .ellipsis,
        .color = theme.c_player_utility,
        .font_size = 11,
    });
    _ = try ctx.label(.{
        .text = "Playback unavailable",
        .grow = 1,
        .shrink = 1,
        .min_main = 200,
        .justify = .center,
        .text_overflow = .ellipsis,
        .color = theme.c_player_utility,
        .font_size = 11,
    });
}

fn drawNowPlaying(comptime App: type, track: anytype, ctx: *DrawCtx) !void {
    _ = try ctx.row(.{ .gap = 8, .shrink = 1, .min_main = 0, .clip = true, .@"align" = .center });
    defer ctx.pop();

    _ = try theme.drawArtworkTile(
        ctx,
        36,
        track.artwork_seed,
        track.artwork_texture_index,
    );

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
        .label = "Like track",
        .accessible_label = "Like track",
        .visual_label = "",
        .icon = @as(widget.IconId, if (track.is_liked) .heart_filled else .heart),
        .on_click = App.toggleCurrentLike,
        .basis = 22,
        .shrink = 1,
        .min_main = 18,
        .color = if (track.is_liked) theme.c_player_progress else theme.c_player_utility,
        .padding = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 },
        .fill = theme.c_player_control_bg,
        .gradient = theme.srgbToOklab(theme.c_player_control_bg),
    });
}

fn drawTransport(comptime App: type, app: anytype, track: anytype, ctx: *DrawCtx) !void {
    _ = try ctx.column(.{ .grow = 1, .shrink = 1, .min_main = 200, .gap = 6, .clip = true, .@"align" = .center });
    defer ctx.pop();

    {
        _ = try ctx.row(.{ .gap = 6, .clip = true, .justify = .center });
        defer ctx.pop();
        try drawTransportButton(ctx, .shuffle, "Toggle shuffle", App.toggleShuffle, app.shuffle, 24);
        try drawTransportButton(ctx, .previous, "Previous track", App.prevTrack, false, 24);
        _ = try ctx.button(.{
            .label = if (app.is_playing) "Pause" else "Play",
            .accessible_label = if (app.is_playing) "Pause" else "Play",
            .visual_label = "",
            .icon = @as(widget.IconId, if (app.is_playing) .pause else .play),
            .on_click = App.togglePlay,
            .basis = 32,
            .shrink = 0,
            .min_main = 32,
            .color = theme.c_bg,
            .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 },
            .radius = .{ .top = 16, .right = 16, .bottom = 16, .left = 16 },
            .fill = theme.c_text,
            .gradient = theme.srgbToOklab(theme.c_text),
        });
        try drawTransportButton(ctx, .next, "Next track", App.nextTrack, false, 24);
        try drawTransportButton(ctx, .repeat, "Toggle repeat", App.toggleRepeat, app.repeat, 24);
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
    icon: widget.IconId,
    label: []const u8,
    handler: anytype,
    active: bool,
    basis: f32,
) !void {
    _ = try ctx.button(.{
        .label = label,
        .accessible_label = label,
        .visual_label = "",
        .icon = icon,
        .on_click = handler,
        .basis = basis,
        .shrink = 1,
        .min_main = basis,
        .color = if (active) theme.c_player_progress else theme.c_player_utility,
        .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 },
        .fill = theme.c_player_control_bg,
        .gradient = theme.srgbToOklab(theme.c_player_control_bg),
    });
}

fn drawVolume(app: anytype, ctx: *DrawCtx) !void {
    _ = try ctx.row(.{ .gap = 6, .shrink = 1, .min_main = 0, .clip = true, .@"align" = .center });
    defer ctx.pop();

    _ = try ctx.button(.{
        .label = "Queue",
        .accessible_label = "Queue",
        .visual_label = "",
        .icon = .queue,
        .basis = 22,
        .shrink = 1,
        .min_main = 18,
        .color = theme.c_player_utility,
        .padding = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 },
        .fill = theme.c_player_control_bg,
        .gradient = theme.srgbToOklab(theme.c_player_control_bg),
    });
    _ = try ctx.button(.{
        .label = "Connect to a device",
        .accessible_label = "Connect to a device",
        .visual_label = "",
        .icon = .devices,
        .basis = 22,
        .shrink = 1,
        .min_main = 18,
        .color = theme.c_player_utility,
        .padding = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 },
        .fill = theme.c_player_control_bg,
        .gradient = theme.srgbToOklab(theme.c_player_control_bg),
    });
    _ = try ctx.button(.{
        .label = "Volume",
        .accessible_label = "Volume",
        .visual_label = "",
        .icon = .volume,
        .basis = 16,
        .shrink = 0,
        .min_main = 16,
        .color = theme.c_player_utility,
    });
    _ = try ctx.slider(.{
        .label = "volume",
        .visual_label = "",
        .value = &app.volume,
        .min = 0.0,
        .max = 1.0,
        .grow = 0,
        .shrink = 1,
        .basis = 100,
        .min_main = 0,
        .color = theme.c_player_utility,
        .padding = .{ .left = 1, .right = 1, .top = 2, .bottom = 2 },
    });
}
