//! Track table view for the Spotify demo.

const std = @import("std");
const DrawCtx = @import("v7/drawctx.zig").DrawCtx;
const callback = @import("v7/callback.zig");
const theme = @import("spotify_theme.zig");
const widget = @import("v7/widget.zig");

pub const table_columns: widget.SharedColumns = .{
    .tracks = &.{
        .{ .basis = 32, .shrink = 0 },
        .{ .grow = 4, .basis = 180, .min_main = 120 },
        .{ .grow = 3, .basis = 140, .min_main = 80 },
        .{ .grow = 2, .basis = 100, .min_main = 60 },
        .{ .basis = 32, .shrink = 0 },
        .{ .basis = 48, .shrink = 0 },
    },
};

pub fn draw(app: anytype, ctx: *DrawCtx) !void {
    const App = @TypeOf(app.*);

    {
        _ = try ctx.row(.{
            .columns = &table_columns,
            .gap = 8,
            .padding = .{ .left = 8, .right = 8, .top = 6, .bottom = 6 },
            .border = .{ .bottom = 1 },
            .border_color = theme.c_border,
        });
        defer ctx.pop();

        _ = try ctx.label(.{ .text = "#", .color = theme.c_text_muted, .font_size = 12 });
        _ = try ctx.label(.{ .text = "Title", .color = theme.c_text_muted, .font_size = 12 });
        _ = try ctx.label(.{ .text = "Album", .color = theme.c_text_muted, .font_size = 12 });
        _ = try ctx.label(.{ .text = "Date added", .color = theme.c_text_muted, .font_size = 12 });
        _ = try ctx.label(.{ .text = "♥", .color = theme.c_text_muted, .font_size = 12 });
        _ = try ctx.label(.{ .text = "Time", .color = theme.c_text_muted, .font_size = 12 });
    }

    for (app.tracks, 0..) |track, i| {
        const is_active = i == app.current_track_idx;
        const row_fill = if (is_active) theme.c_active_row else theme.c_card_bg;
        const select_track = callback.bind(App.selectTrack, i);
        const index_label = if (is_active)
            "▶"
        else
            try std.fmt.allocPrint(ctx.arena, "{d}", .{i + 1});

        _ = try ctx.row(.{
            .columns = &table_columns,
            .gap = 8,
            .padding = .{ .left = 8, .right = 8, .top = 6, .bottom = 6 },
            .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
            .fill = row_fill,
            .gradient = theme.srgbToOklab(row_fill),
        });
        defer ctx.pop();

        _ = try ctx.button(.{
            .label = index_label,
            .on_click_with_data = select_track,
            .color = if (is_active) theme.c_accent else theme.c_text_muted,
            .font_size = 12,
            .padding = .{ .left = 4, .right = 4, .top = 2, .bottom = 2 },
            .fill = row_fill,
            .gradient = theme.srgbToOklab(row_fill),
        });

        {
            _ = try ctx.column(.{
                .gap = 1,
                .clip = true,
            });
            defer ctx.pop();
            _ = try ctx.button(.{
                .label = track.title,
                .on_click_with_data = select_track,
                .color = if (is_active) theme.c_accent else theme.c_text,
                .font_size = 13,
                .padding = .{ .top = 1, .bottom = 1 },
                .fill = row_fill,
                .gradient = theme.srgbToOklab(row_fill),
                .text_overflow = .ellipsis,
            });
            _ = try ctx.label(.{
                .text = track.artist,
                .color = theme.c_text_sec,
                .font_size = 11,
                .text_overflow = .ellipsis,
            });
        }

        _ = try ctx.button(.{
            .label = track.album,
            .on_click_with_data = select_track,
            .color = theme.c_text_sec,
            .font_size = 12,
            .fill = row_fill,
            .gradient = theme.srgbToOklab(row_fill),
            .text_overflow = .ellipsis,
        });

        _ = try ctx.button(.{
            .label = track.date_added,
            .on_click_with_data = select_track,
            .color = theme.c_text_muted,
            .font_size = 12,
            .fill = row_fill,
            .gradient = theme.srgbToOklab(row_fill),
            .text_overflow = .ellipsis,
        });

        _ = try ctx.button(.{
            .label = if (track.is_liked) "♥" else "♡",
            .on_click_with_data = callback.bind(App.toggleTrackLike, i),
            .color = if (track.is_liked) theme.c_like_active else theme.c_text_muted,
            .font_size = 13,
            .fill = row_fill,
            .gradient = theme.srgbToOklab(row_fill),
        });

        _ = try ctx.button(.{
            .label = track.duration_str,
            .on_click_with_data = select_track,
            .color = theme.c_text_sec,
            .font_size = 12,
            .fill = row_fill,
            .gradient = theme.srgbToOklab(row_fill),
            .text_overflow = .ellipsis,
        });
    }
}
