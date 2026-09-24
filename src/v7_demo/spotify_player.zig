//! Bottom player bar view for the Spotify demo.

const std = @import("std");
const nogui = @import("nogui");
const DrawCtx = nogui.DrawCtx;
const ComponentKey = nogui.ComponentKey;
const widget = nogui.widget;
const layout = @import("spotify_layout.zig");
const theme = @import("spotify_theme.zig");

// Shared 3-column shell: wide stable Now-Playing, flexible Transport,
// stable Volume. Side columns keep their width so play controls never
// jitter as track metadata changes.
const player_tracks = [_]widget.ColumnTrack{
    .{ .flex_basis = .{ .length = 240 }, .grow = 0, .shrink = 1, .min_width = .{ .length = 120 } },
    .{ .flex_basis = .{ .length = 0 }, .grow = 1, .shrink = 1, .min_width = .{ .length = 200 } },
    .{ .flex_basis = .{ .length = 200 }, .grow = 0, .shrink = 1, .min_width = .{ .length = 120 } },
};
const player_columns: widget.SharedColumns = .{ .tracks = &player_tracks };

const UtilityButton = struct {
    pub const default_style: nogui.Style = .{
        .direction = .row,
        .shrink = 1,
        .padding_inset = .{
            .left = .{ .length = 2 },
            .right = .{ .length = 2 },
            .top = .{ .length = 2 },
            .bottom = .{ .length = 2 },
        },
    };
    pub const default_paint: nogui.PaintStyle = .{
        .fill = theme.c_player_control_bg,
    };
};

const TransportButton = struct {
    pub const default_style: nogui.Style = .{
        .direction = .row,
        .shrink = 1,
        .padding_inset = .{
            .left = .{ .length = 4 },
            .right = .{ .length = 4 },
            .top = .{ .length = 4 },
            .bottom = .{ .length = 4 },
        },
    };
    pub const default_paint: nogui.PaintStyle = .{
        .fill = theme.c_player_control_bg,
    };
};

pub fn draw(app: anytype, ctx: *DrawCtx, spec: layout.Spec) !void {
    _ = spec;
    const App = @TypeOf(app.*);
    const current_track = app.currentTrack();

    _ = try ctx.row(.{
        .columns = &player_columns,
        .flex_basis = theme.player_height,
        .min_height = theme.player_height,
        .shrink = 0,
        .gap = 16,
        .clip = true,
        .padding = .{ .left = 16, .right = 16, .top = 8, .bottom = 8 },
        .fill = theme.c_player_bg,
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

fn drawUtilityButton(
    ctx: *DrawCtx,
    key: ComponentKey,
    label: []const u8,
    icon: widget.IconId,
    flex_basis: f32,
    min_width: f32,
    color: [4]f32,
    options: anytype,
) !void {
    const style = UtilityButton.default_style;
    const paint = UtilityButton.default_paint;
    const has_on_click = @hasField(@TypeOf(options), "on_click");
    if (has_on_click) {
        _ = try ctx.button(.{
            .key = key,
            .direction = style.direction,
            .label = label,
            .accessible_label = label,
            .visual_label = "",
            .icon = icon,
            .on_click = options.on_click,
            .flex_basis = flex_basis,
            .shrink = style.shrink,
            .min_width = min_width,
            .color = color,
            .padding = style.padding_inset,
            .fill = paint.fill,
        });
        return;
    }
    _ = try ctx.button(.{
        .key = key,
        .direction = style.direction,
        .label = label,
        .accessible_label = label,
        .visual_label = "",
        .icon = icon,
        .flex_basis = flex_basis,
        .shrink = style.shrink,
        .min_width = min_width,
        .color = color,
        .padding = style.padding_inset,
        .fill = paint.fill,
    });
}

fn drawUnavailable(ctx: *DrawCtx) !void {
    _ = try ctx.label(.{
        .text = "No playable track",
        .grow = 1,
        .shrink = 1,
        .min_width = 120,
        .text_overflow = .ellipsis,
        .color = theme.c_player_utility,
        .font_size = 11,
    });
    _ = try ctx.label(.{
        .text = "Playback unavailable",
        .grow = 1,
        .shrink = 1,
        .min_width = 200,
        .justify = .center,
        .text_overflow = .ellipsis,
        .color = theme.c_player_utility,
        .font_size = 11,
    });
}

fn drawNowPlaying(comptime App: type, track: anytype, ctx: *DrawCtx) !void {
    _ = try ctx.row(.{ .gap = 8, .shrink = 1, .min_width = 0, .clip = true, .@"align" = .center });
    defer ctx.pop();

    _ = try theme.drawArtworkTile(
        ctx,
        36,
        track.artwork_seed,
        track.artwork_texture_index,
    );

    {
        _ = try ctx.column(.{ .grow = 1, .shrink = 1, .min_width = 20, .gap = 2, .clip = true });
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

    try drawUtilityButton(
        ctx,
        .{ .static = "player-like-toggle" },
        "Like track",
        @as(widget.IconId, if (track.is_liked) .heart_filled else .heart),
        22,
        18,
        if (track.is_liked) theme.c_player_progress else theme.c_player_utility,
        .{ .on_click = App.toggleCurrentLike },
    );
}

fn drawTransport(comptime App: type, app: anytype, track: anytype, ctx: *DrawCtx) !void {
    _ = try ctx.column(.{ .grow = 1, .shrink = 1, .min_width = 200, .gap = 6, .clip = true, .@"align" = .center });
    defer ctx.pop();

    {
        _ = try ctx.row(.{ .gap = 6, .clip = true, .justify = .center });
        defer ctx.pop();
        try drawTransportButton(
            ctx,
            .{ .static = "player-shuffle" },
            .shuffle,
            "Toggle shuffle",
            App.toggleShuffle,
            app.shuffle,
            24,
        );
        try drawTransportButton(
            ctx,
            .{ .static = "player-previous" },
            .previous,
            "Previous track",
            App.prevTrack,
            false,
            24,
        );
        _ = try ctx.button(.{
            .key = @as(ComponentKey, .{ .static = "player-play-toggle" }),
            .label = if (app.is_playing) "Pause" else "Play",
            .accessible_label = if (app.is_playing) "Pause" else "Play",
            .visual_label = "",
            .icon = @as(widget.IconId, if (app.is_playing) .pause else .play),
            .on_click = App.togglePlay,
            .flex_basis = 32,
            .shrink = 0,
            .min_width = 32,
            .color = theme.c_bg,
            .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 },
            .radius = .{ .top = 16, .right = 16, .bottom = 16, .left = 16 },
            .fill = theme.c_text,
        });
        try drawTransportButton(
            ctx,
            .{ .static = "player-next" },
            .next,
            "Next track",
            App.nextTrack,
            false,
            24,
        );
        try drawTransportButton(
            ctx,
            .{ .static = "player-repeat" },
            .repeat,
            "Toggle repeat",
            App.toggleRepeat,
            app.repeat,
            24,
        );
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
            _ = try ctx.row(.{ .flex_basis = 28, .shrink = 0, .justify = .end, .clip = true });
            defer ctx.pop();
            _ = try ctx.label(.{ .text = elapsed_text, .color = theme.c_player_utility, .font_size = 9 });
        }
        _ = try ctx.slider(.{
            .key = @as(ComponentKey, .{ .static = "player-seek" }),
            .label = "seek",
            .visual_label = "",
            .value = &app.progress_sec,
            .min = 0,
            .max = duration_sec,
            .grow = 1,
            .shrink = 1,
            .flex_basis = 100,
            .min_width = 100,
            .color = theme.c_player_progress,
            .padding = .{ .left = 1, .right = 1 },
        });
        _ = try ctx.label(.{
            .text = track.duration_str,
            .color = theme.c_player_utility,
            .font_size = 9,
            .flex_basis = 28,
            .shrink = 0,
        });
    }
}

fn drawTransportButton(
    ctx: *DrawCtx,
    key: ComponentKey,
    icon: widget.IconId,
    label: []const u8,
    handler: anytype,
    active: bool,
    flex_basis: f32,
) !void {
    const style = TransportButton.default_style;
    const paint = TransportButton.default_paint;
    _ = try ctx.button(.{
        .key = key,
        .direction = style.direction,
        .label = label,
        .accessible_label = label,
        .visual_label = "",
        .icon = icon,
        .on_click = handler,
        .flex_basis = flex_basis,
        .shrink = style.shrink,
        .min_width = flex_basis,
        .color = if (active) theme.c_player_progress else theme.c_player_utility,
        .padding = style.padding_inset,
        .fill = paint.fill,
    });
}

fn drawVolume(app: anytype, ctx: *DrawCtx) !void {
    _ = try ctx.row(.{ .gap = 6, .shrink = 1, .min_width = 0, .clip = true, .@"align" = .center });
    defer ctx.pop();

    try drawUtilityButton(
        ctx,
        .{ .static = "player-queue" },
        "Queue",
        .queue,
        22,
        18,
        theme.c_player_utility,
        .{},
    );
    try drawUtilityButton(
        ctx,
        .{ .static = "player-connect-device" },
        "Connect to a device",
        .devices,
        22,
        18,
        theme.c_player_utility,
        .{},
    );
    _ = try ctx.button(.{
        .key = @as(ComponentKey, .{ .static = "player-volume-toggle" }),
        .label = "Volume",
        .accessible_label = "Volume",
        .visual_label = "",
        .icon = .volume,
        .flex_basis = 16,
        .shrink = 0,
        .min_width = 16,
        .color = theme.c_player_utility,
    });
    _ = try ctx.slider(.{
        .key = @as(ComponentKey, .{ .static = "player-volume" }),
        .label = "volume",
        .visual_label = "",
        .value = &app.volume,
        .min = 0.0,
        .max = 1.0,
        .shrink = 1,
        .flex_basis = 100,
        .min_width = 0,
        .color = theme.c_player_utility,
        .padding = .{ .left = 1, .right = 1, .top = 2, .bottom = 2 },
    });
}
