//! Bottom player bar view for the Spotify demo.

const std = @import("std");
const DrawCtx = @import("v7/drawctx.zig").DrawCtx;
const theme = @import("spotify_theme.zig");

pub fn draw(app: anytype, ctx: *DrawCtx) !void {
    const App = @TypeOf(app.*);

    _ = try ctx.row(.{
        .basis = 72,
        .shrink = 0,
        .justify = .space_between,
        .padding = .{ .left = 16, .right = 16, .top = 8, .bottom = 8 },
        .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
        .fill = theme.c_player_bg,
        .gradient = theme.srgbToOklab(theme.c_player_bg),
        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
        .border_color = theme.c_border,
    });
    defer ctx.pop();

    const current_track = app.tracks[app.current_track_idx];

    // 1. Left: Track Info & Thumbnail
    {
        _ = try ctx.row(.{ .gap = 12, .basis = 240, .shrink = 0 });
        defer ctx.pop();

        // Cover Art thumbnail box
        {
            _ = try ctx.column(.{
                .basis = 44,
                .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
                .fill = theme.c_hero_top,
                .gradient = theme.srgbToOklab(theme.c_accent_dim),
                .padding = .{ .top = 12, .left = 10 },
            });
            defer ctx.pop();
            _ = try ctx.label(.{
                .text = "♫",
                .color = theme.c_text,
                .font_size = 16,
            });
        }

        // Title & Artist
        {
            _ = try ctx.column(.{ .gap = 2 });
            defer ctx.pop();
            _ = try ctx.label(.{
                .text = current_track.title,
                .color = theme.c_text,
                .font_size = 13,
            });
            _ = try ctx.label(.{
                .text = current_track.artist,
                .color = theme.c_text_sec,
                .font_size = 11,
            });
        }

        // Like Heart Button
        const heart_text = if (current_track.is_liked) "♥" else "♡";
        const heart_color = if (current_track.is_liked) theme.c_accent else theme.c_text_muted;
        _ = try ctx.button(.{
            .label = heart_text,
            .on_click = App.toggleCurrentLike,
            .color = heart_color,
            .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 },
            .radius = .{ .top = 12, .right = 12, .bottom = 12, .left = 12 },
            .fill = theme.c_player_bg,
            .gradient = theme.srgbToOklab(theme.c_player_bg),
            .font_size = 14,
        });
    }

    // 2. Center: Transport Controls & Seek Progress Bar
    {
        _ = try ctx.column(.{ .gap = 4, .grow = 1 });
        defer ctx.pop();

        // Transport Buttons Row
        {
            _ = try ctx.row(.{ .gap = 12, .justify = .center });
            defer ctx.pop();

            _ = try ctx.button(.{
                .label = if (app.shuffle) "Shuf:ON" else "Shuf",
                .on_click = App.toggleShuffle,
                .color = if (app.shuffle) theme.c_accent else theme.c_text_muted,
                .padding = .{ .left = 6, .right = 6, .top = 3, .bottom = 3 },
                .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
                .fill = theme.c_player_bg,
                .gradient = theme.srgbToOklab(theme.c_player_bg),
                .font_size = 11,
            });

            _ = try ctx.button(.{
                .label = "|< Prev",
                .on_click = App.prevTrack,
                .color = theme.c_text,
                .padding = .{ .left = 8, .right = 8, .top = 3, .bottom = 3 },
                .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
                .fill = theme.c_card_hover,
                .gradient = theme.srgbToOklab(theme.c_card_hover),
                .font_size = 11,
            });

            const play_icon = if (app.is_playing) "||" else "|>";
            _ = try ctx.button(.{
                .label = play_icon,
                .on_click = App.togglePlay,
                .color = theme.c_bg,
                .padding = .{ .left = 14, .right = 14, .top = 4, .bottom = 4 },
                .radius = .{ .top = 16, .right = 16, .bottom = 16, .left = 16 },
                .fill = theme.c_text,
                .gradient = theme.srgbToOklab(theme.c_text),
                .font_size = 12,
            });

            _ = try ctx.button(.{
                .label = "Next >|",
                .on_click = App.nextTrack,
                .color = theme.c_text,
                .padding = .{ .left = 8, .right = 8, .top = 3, .bottom = 3 },
                .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
                .fill = theme.c_card_hover,
                .gradient = theme.srgbToOklab(theme.c_card_hover),
                .font_size = 11,
            });

            _ = try ctx.button(.{
                .label = if (app.repeat) "Rep:ON" else "Rep",
                .on_click = App.toggleRepeat,
                .color = if (app.repeat) theme.c_accent else theme.c_text_muted,
                .padding = .{ .left = 6, .right = 6, .top = 3, .bottom = 3 },
                .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
                .fill = theme.c_player_bg,
                .gradient = theme.srgbToOklab(theme.c_player_bg),
                .font_size = 11,
            });
        }

        // Seek Bar & Timestamps
        {
            _ = try ctx.row(.{ .gap = 8, .justify = .center });
            defer ctx.pop();

            const cur_min: u32 = @intFromFloat(app.progress_sec / 60.0);
            const cur_sec: u32 = @intFromFloat(@mod(app.progress_sec, 60.0));
            const cur_time_str = try std.fmt.allocPrint(ctx.arena, "{d}:{d:0>2}", .{ cur_min, cur_sec });
            const duration_sec_f64: f64 = @floatFromInt(current_track.duration_sec);

            _ = try ctx.label(.{
                .text = cur_time_str,
                .color = theme.c_text_muted,
                .font_size = 11,
            });

            _ = try ctx.slider(.{
                .label = "seek",
                .value = &app.progress_sec,
                .min = 0,
                .max = @as(f32, @floatCast(duration_sec_f64)),
                .color = theme.c_accent,
                .padding = .{ .left = 6, .right = 6 },
            });

            _ = try ctx.label(.{
                .text = current_track.duration_str,
                .color = theme.c_text_muted,
                .font_size = 11,
            });
        }
    }

    // 3. Right: Volume Slider & Extras
    {
        _ = try ctx.row(.{ .gap = 8, .basis = 220, .shrink = 0, .justify = .end });
        defer ctx.pop();

        _ = try ctx.label(.{
            .text = "Vol",
            .color = theme.c_text_muted,
            .font_size = 11,
        });

        _ = try ctx.slider(.{
            .label = "vol",
            .value = &app.volume,
            .min = 0.0,
            .max = 1.0,
            .color = theme.c_accent,
            .padding = .{ .left = 4, .right = 4 },
        });
    }
}
