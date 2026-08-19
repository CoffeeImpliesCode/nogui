//! Track table view for the Spotify demo.

const std = @import("std");
const DrawCtx = @import("v7/drawctx.zig").DrawCtx;
const theme = @import("spotify_theme.zig");

pub fn draw(app: anytype, ctx: *DrawCtx) !void {
    const App = @TypeOf(app.*);

    // 4. Track List Table Header
    {
        _ = try ctx.row(.{
            .gap = 8,
            .padding = .{ .left = 8, .right = 8, .top = 6, .bottom = 6 },
            .border = .{ .bottom = 1 },
            .border_color = theme.c_border,
        });
        defer ctx.pop();

        _ = try ctx.label(.{ .text = "#", .color = theme.c_text_muted, .font_size = 12, .margin = .{ .right = 8 } });
        _ = try ctx.label(.{
            .text = "Title",
            .color = theme.c_text_muted,
            .font_size = 12,
            .margin = .{ .right = 180 },
        });
        _ = try ctx.label(.{
            .text = "Album",
            .color = theme.c_text_muted,
            .font_size = 12,
            .margin = .{ .right = 120 },
        });
        _ = try ctx.label(.{
            .text = "Date added",
            .color = theme.c_text_muted,
            .font_size = 12,
            .margin = .{ .right = 80 },
        });
        _ = try ctx.label(.{ .text = "Time", .color = theme.c_text_muted, .font_size = 12 });
    }

    // 5. Track List Rows
    for (app.tracks, 0..) |track, i| {
        const is_active = (i == app.current_track_idx);
        const row_fill = if (is_active) theme.c_active_row else theme.c_card_bg;

        _ = try ctx.row(.{
            .gap = 8,
            .padding = .{ .left = 8, .right = 8, .top = 6, .bottom = 6 },
            .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
            .fill = row_fill,
            .gradient = theme.srgbToOklab(row_fill),
        });
        defer ctx.pop();

        // Track index or playing indicator
        const idx_str = try std.fmt.allocPrint(ctx.arena, "{d}", .{track.id});
        const num_color = if (is_active) theme.c_accent else theme.c_text_muted;

        // Both action buttons use a compile-time callback. DrawCtx wraps
        // callbacks at comptime, so runtime function-pointer selection is
        // not valid for this immediate-mode call.
        const title_color = if (is_active) theme.c_accent else theme.c_text;
        const full_title = try std.fmt.allocPrint(ctx.arena, "{s} - {s}", .{ track.title, track.artist });
        switch (i) {
            0 => try theme.drawTrackActions(
                App.selectTrack0,
                ctx,
                idx_str,
                full_title,
                track.album,
                track.date_added,
                track.duration_str,
                num_color,
                title_color,
                row_fill,
            ),
            1 => try theme.drawTrackActions(
                App.selectTrack1,
                ctx,
                idx_str,
                full_title,
                track.album,
                track.date_added,
                track.duration_str,
                num_color,
                title_color,
                row_fill,
            ),
            2 => try theme.drawTrackActions(
                App.selectTrack2,
                ctx,
                idx_str,
                full_title,
                track.album,
                track.date_added,
                track.duration_str,
                num_color,
                title_color,
                row_fill,
            ),
            3 => try theme.drawTrackActions(
                App.selectTrack3,
                ctx,
                idx_str,
                full_title,
                track.album,
                track.date_added,
                track.duration_str,
                num_color,
                title_color,
                row_fill,
            ),
            4 => try theme.drawTrackActions(
                App.selectTrack4,
                ctx,
                idx_str,
                full_title,
                track.album,
                track.date_added,
                track.duration_str,
                num_color,
                title_color,
                row_fill,
            ),
            5 => try theme.drawTrackActions(
                App.selectTrack5,
                ctx,
                idx_str,
                full_title,
                track.album,
                track.date_added,
                track.duration_str,
                num_color,
                title_color,
                row_fill,
            ),
            else => try theme.drawTrackActions(
                App.selectTrack6,
                ctx,
                idx_str,
                full_title,
                track.album,
                track.date_added,
                track.duration_str,
                num_color,
                title_color,
                row_fill,
            ),
        }

        // Like heart icon
        const heart_str = if (track.is_liked) "♥" else "♡";
        const heart_col = if (track.is_liked) theme.c_like_active else theme.c_text_muted;
        _ = try ctx.label(.{
            .text = heart_str,
            .color = heart_col,
            .font_size = 12,
        });
    }
}
