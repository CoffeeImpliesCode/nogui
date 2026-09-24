//! Now-playing rail view for the Spotify demo.

const nogui = @import("nogui");
const DrawCtx = nogui.DrawCtx;
const layout = @import("spotify_layout.zig");
const theme = @import("spotify_theme.zig");

const now_playing_rail_padding_x: f32 = 14;
const now_playing_artwork_size: f32 = 160;

const MetadataRow = struct {
    pub const default_style: nogui.Style = .{
        .direction = .row,
        .gap = .{ .length = 8 },
        .@"align" = .center,
    };
};

pub fn draw(app: anytype, ctx: *DrawCtx, spec: layout.Spec) !void {
    if (!spec.show_now_playing) return;

    const current_track = app.currentTrack();
    const content_width = spec.now_playing_width - now_playing_rail_padding_x * 2;

    _ = try ctx.column(.{
        .flex_basis = spec.now_playing_width,
        .grow = 0,
        .shrink = 0,
        .min_width = spec.now_playing_width,
        .box_sizing = .border_box,
        .gap = 10,
        .clip = true,
        .padding = .{
            .top = 16,
            .right = now_playing_rail_padding_x,
            .bottom = 12,
            .left = now_playing_rail_padding_x,
        },
        .fill = theme.c_sidebar_bg,
    });
    defer ctx.pop();

    {
        _ = try ctx.row(.{ .gap = 6, .justify = .space_between, .@"align" = .center });
        defer ctx.pop();
        _ = try ctx.label(.{
            .text = "Now Playing",
            .shrink = 1,
            .min_width = 0,
            .text_overflow = .ellipsis,
            .max_width = content_width,
            .color = theme.c_text,
            .font_size = 12,
        });
        _ = try ctx.label(.{
            .text = "⋯",
            .shrink = 0,
            .color = theme.c_text_muted,
            .font_size = 14,
        });
    }

    if (current_track) |track| {
        {
            _ = try ctx.row(.{ .justify = .center, .clip = true });
            defer ctx.pop();
            const artwork_tile = try theme.drawArtworkTile(
                ctx,
                now_playing_artwork_size,
                track.artwork_seed,
                track.artwork_texture_index,
            );
            const artwork_node = ctx.tree.node(artwork_tile) orelse return error.InvalidStyle;
            artwork_node.style.padding_inset.bottom = .{ .length = 0 };
        }
        _ = try ctx.label(.{
            .text = track.title,
            .shrink = 1,
            .min_height = 0,
            .text_overflow = .ellipsis,
            .max_width = content_width,
            .color = theme.c_text,
            .font_size = 16,
        });
        _ = try ctx.label(.{
            .text = track.artist,
            .shrink = 1,
            .min_height = 0,
            .text_overflow = .ellipsis,
            .max_width = content_width,
            .color = theme.c_text_sec,
            .font_size = 12,
        });

        try drawMetadata(ctx, content_width, track.album, track.date_added);
    } else {
        _ = try ctx.label(.{
            .text = "Playback unavailable",
            .shrink = 1,
            .min_height = 0,
            .text_overflow = .ellipsis,
            .max_width = content_width,
            .color = theme.c_text_sec,
            .font_size = 13,
        });
    }
}

fn drawMetadata(
    ctx: *DrawCtx,
    content_width: f32,
    album: []const u8,
    date_added: []const u8,
) !void {
    _ = try ctx.column(.{
        .shrink = 1,
        .min_height = 0,
        .box_sizing = .border_box,
        .gap = 6,
        .clip = true,
        .padding = .{ .top = 10, .right = 12, .bottom = 10, .left = 12 },
        .fill = theme.c_card_bg,
        .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
    });
    defer ctx.pop();

    try drawMetadataRow(ctx, content_width - 24, "Album", album);
    try drawMetadataRow(ctx, content_width - 24, "Added", date_added);
}

fn drawMetadataRow(
    ctx: *DrawCtx,
    content_width: f32,
    heading: []const u8,
    value: []const u8,
) !void {
    const style = MetadataRow.default_style;
    _ = try ctx.row(.{
        .direction = style.direction,
        .gap = style.gap,
        .clip = true,
        .@"align" = style.@"align",
    });
    defer ctx.pop();
    _ = try ctx.label(.{
        .text = heading,
        .flex_basis = 42,
        .shrink = 0,
        .color = theme.c_text_muted,
        .font_size = 10,
        .text_overflow = .ellipsis,
    });
    _ = try ctx.label(.{
        .text = value,
        .grow = 1,
        .shrink = 1,
        .min_width = 0,
        .max_width = content_width - 50,
        .color = theme.c_text,
        .font_size = 11,
        .text_overflow = .ellipsis,
    });
}
