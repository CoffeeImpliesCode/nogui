//! Track table view for the Spotify demo.

const std = @import("std");
const nogui = @import("nogui");
const DrawCtx = nogui.DrawCtx;
const callback = nogui.callback;
const layout = @import("spotify_layout.zig");
const theme = @import("spotify_theme.zig");
const widget = nogui.widget;
const Id = nogui.Id;

const track_row_height = theme.track_row_height;
const track_text_gap = theme.track_text_gap;
const track_title_slot_height = theme.track_title_slot_height;
const track_artist_slot_height = theme.track_artist_slot_height;
const track_identity_text_width_compact_max = theme.track_identity_text_width_compact_max;
const track_album_text_width_max = theme.track_album_text_width_max;

const desktop_columns: widget.SharedColumns = .{
    .tracks = &.{
        .{ .basis = 32, .shrink = 0 },
        .{ .grow = 6, .basis = 240, .min_main = theme.track_identity_width_min },
        .{ .grow = 2, .basis = 120, .min_main = 70 },
        .{ .grow = 1, .basis = 90, .min_main = 60 },
        .{ .basis = 32, .shrink = 0 },
        .{ .basis = 50, .shrink = 0 },
    },
};
const medium_columns: widget.SharedColumns = .{
    .tracks = &.{
        .{ .basis = 32, .shrink = 0 },
        .{ .grow = 6, .basis = 240, .min_main = theme.track_identity_width_min },
        .{ .grow = 2, .basis = 120, .min_main = 70 },
        .{ .basis = 32, .shrink = 0 },
        .{ .basis = 50, .shrink = 0 },
    },
};
const compact_columns: widget.SharedColumns = .{
    .tracks = &.{
        .{ .basis = 32, .shrink = 0 },
        .{ .grow = 1, .basis = 160, .min_main = 0 },
        .{ .basis = 32, .shrink = 0 },
        .{ .basis = 50, .shrink = 0 },
    },
};

fn columnsFor(spec: layout.Spec) *const widget.SharedColumns {
    return switch (spec.mode) {
        .desktop => &desktop_columns,
        .medium => &medium_columns,
        .compact => &compact_columns,
    };
}

fn constrainIdentityText(tree: *widget.WidgetTree, id: Id, max_width: ?f32) void {
    const node = tree.node(id).?;
    node.flex.shrink = 1;
    node.flex.min_main = 0;
    node.text_overflow = .ellipsis;
    if (max_width) |width| node.text_max_width = width;
}

pub fn draw(app: anytype, ctx: *DrawCtx, spec: layout.Spec) !void {
    const App = @TypeOf(app.*);

    _ = try ctx.column(.{
        .gap = 0,
        .clip = true,
        .fill = theme.c_bg,
        .gradient = theme.srgbToOklab(theme.c_bg),
    });
    defer ctx.pop();

    {
        _ = try ctx.row(.{
            .columns = columnsFor(spec),
            .gap = 0,
            .padding = .{
                .left = theme.table_gutter,
                .right = theme.table_gutter,
                .top = theme.table_header_gutter_y,
                .bottom = theme.table_header_gutter_y,
            },
            .border = .{ .bottom = 1 },
            .border_color = theme.c_table_divider,
            .fill = theme.c_bg,
            .gradient = theme.srgbToOklab(theme.c_bg),
        });
        defer ctx.pop();

        _ = try ctx.label(.{ .text = "#", .color = theme.c_text_muted, .font_size = 11 });
        _ = try ctx.label(.{
            .text = "Title",
            .color = theme.c_text_muted,
            .font_size = 11,
            .padding = .{ .left = theme.track_identity_copy_offset },
        });
        if (spec.show_album_column) {
            _ = try ctx.label(.{ .text = "Album", .color = theme.c_text_muted, .font_size = 11 });
        }
        if (spec.show_date_column) {
            _ = try ctx.label(.{
                .text = "Date added",
                .color = theme.c_text_muted,
                .font_size = 11,
            });
        }
        _ = try ctx.label(.{ .text = "♡", .color = theme.c_text_muted, .font_size = 11 });
        _ = try ctx.label(.{
            .text = "Time",
            .color = theme.c_text_muted,
            .font_size = 11,
            .justify = .end,
        });
    }

    const active_tracks = app.activeTracks();
    const current_track_idx = app.currentTrackIndex();
    if (app.local_audio_queue_initialized and active_tracks.len == 0) {
        _ = try ctx.label(.{
            .text = "No local tracks available",
            .color = theme.c_text_sec,
            .font_size = 13,
            .padding = .{ .left = theme.table_gutter, .top = 20, .bottom = 20 },
        });
        return;
    }
    for (active_tracks, 0..) |track, i| {
        const is_active = if (current_track_idx) |index| i == index else false;
        const select_track = callback.bind(App.selectTrack, i);
        const index_label = if (is_active)
            "▶"
        else
            try std.fmt.allocPrint(ctx.arena, "{d}", .{i + 1});

        if (is_active) {
            _ = try ctx.row(.{
                .columns = columnsFor(spec),
                .gap = 0,
                .clip = true,
                .@"align" = .center,
                .basis = track_row_height,
                .box_sizing = .border_box,
                .padding = .{ .left = theme.table_gutter, .right = theme.table_gutter },
                .radius = .{ .top = 2, .right = 2, .bottom = 2, .left = 2 },
                .fill = theme.c_track_active_bg,
                .gradient = theme.srgbToOklab(theme.c_track_active_bg),
            });
        } else {
            _ = try ctx.row(.{
                .columns = columnsFor(spec),
                .gap = 0,
                .clip = true,
                .@"align" = .center,
                .basis = track_row_height,
                .box_sizing = .border_box,
                .padding = .{ .left = theme.table_gutter, .right = theme.table_gutter },
                .radius = .{ .top = 2, .right = 2, .bottom = 2, .left = 2 },
                .transparent = true,
            });
        }
        defer ctx.pop();

        _ = try ctx.button(.{
            .label = index_label,
            .on_click_with_data = select_track,
            .color = if (is_active) theme.c_accent else theme.c_text_muted,
            .font_size = 12,
            .justify = .start,
            .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
            .transparent = !is_active,
        });

        {
            _ = try ctx.row(.{
                .gap = theme.track_artwork_gap,
                .clip = true,
                .@"align" = .center,
                .transparent = !is_active,
            });
            defer ctx.pop();

            _ = try theme.drawArtworkTile(
                ctx,
                theme.track_artwork_size,
                track.artwork_seed,
                track.artwork_texture_index,
            );

            {
                _ = try ctx.column(.{
                    .grow = 1,
                    .shrink = 1,
                    .min_main = 0,
                    .gap = track_text_gap,
                    .clip = true,
                    .justify = .start,
                    .transparent = !is_active,
                });
                defer ctx.pop();

                const identity_text_max_width: ?f32 = if (spec.mode == .compact)
                    track_identity_text_width_compact_max
                else
                    null;
                const title_button = try ctx.button(.{
                    .label = track.title,
                    .on_click_with_data = select_track,
                    .color = if (is_active) theme.c_accent else theme.c_text,
                    .font_size = 13,
                    .basis = track_title_slot_height,
                    .shrink = 1,
                    .min_main = 0,
                    .justify = .start,
                    .transparent = !is_active,
                    .text_overflow = .ellipsis,
                });
                const title_button_node = ctx.tree.node(title_button).?;
                std.debug.assert(title_button_node.children.len == 1);
                constrainIdentityText(ctx.tree, title_button_node.children.items[0], identity_text_max_width);
                const artist_label = try ctx.label(.{
                    .text = track.artist,
                    .color = theme.c_text_sec,
                    .font_size = 11,
                    .basis = track_artist_slot_height,
                    .shrink = 1,
                    .min_main = 0,
                    .text_overflow = .ellipsis,
                });
                constrainIdentityText(ctx.tree, artist_label, identity_text_max_width);
            }
        }

        if (spec.show_album_column) {
            const album_button = try ctx.button(.{
                .label = track.album,
                .on_click_with_data = select_track,
                .color = theme.c_text_sec,
                .font_size = 12,
                .shrink = 1,
                .min_main = 0,
                .max_width = track_album_text_width_max,
                .justify = .start,
                .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
                .transparent = !is_active,
                .text_overflow = .ellipsis,
            });
            const album_button_node = ctx.tree.node(album_button).?;
            std.debug.assert(album_button_node.children.len == 1);
            constrainIdentityText(
                ctx.tree,
                album_button_node.children.items[0],
                track_album_text_width_max,
            );
        }

        if (spec.show_date_column) {
            _ = try ctx.button(.{
                .label = track.date_added,
                .on_click_with_data = select_track,
                .color = theme.c_text_muted,
                .font_size = 12,
                .shrink = 1,
                .min_main = 0,
                .max_width = theme.track_date_text_width_max,
                .justify = .start,
                .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
                .transparent = !is_active,
                .text_overflow = .ellipsis,
            });
        }

        _ = try ctx.button(.{
            .label = if (track.is_liked) "♥" else "♡",
            .on_click_with_data = callback.bind(App.toggleTrackLike, i),
            .color = if (track.is_liked) theme.c_like_active else theme.c_text_muted,
            .font_size = 13,
            .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
            .transparent = !is_active,
        });

        _ = try ctx.button(.{
            .label = track.duration_str,
            .on_click_with_data = select_track,
            .color = theme.c_text_sec,
            .font_size = 12,
            .justify = .end,
            .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
            .transparent = !is_active,
            .text_overflow = .ellipsis,
        });
    }
}
