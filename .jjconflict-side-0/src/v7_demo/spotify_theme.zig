//! Shared Spotify palette and stateless widgets.

const nogui = @import("nogui");
const DrawCtx = nogui.DrawCtx;
pub const srgbToOklab = @import("text.zig").srgbToOklab;
pub const Id = nogui.Id;

/// Outer breathing room between the application surface and its chrome.
pub const app_inset: f32 = 8;
/// Width of the complete library sidebar in the full desktop layout.
pub const sidebar_width_full: f32 = 280;
/// Width of the navigation-only sidebar in compact layouts.
pub const sidebar_width_compact: f32 = 64;
/// Width of the now-playing detail rail in the full desktop layout.
pub const now_playing_width_full: f32 = 240;
/// Horizontal inset applied to content scene sections.
pub const content_gutter: f32 = 16;
/// Vertical inset for the top navigation header.
pub const header_gutter_y: f32 = 6;
/// Separation between adjacent controls in the navigation header.
pub const header_control_gap: f32 = 6;
/// Hero section inset.
pub const hero_gutter: f32 = 16;
/// Hero artwork-to-copy separation.
pub const hero_content_gap: f32 = 18;
/// Hero top inset.
pub const hero_gutter_top: f32 = 32;
/// Hero bottom inset.
pub const hero_gutter_bottom: f32 = 26;
/// Actions rail inset.
pub const action_gutter_y: f32 = 12;
/// Separation between controls in the desktop actions rail.
pub const action_control_gap: f32 = 12;
/// Separation between controls in the compact actions rail.
pub const action_control_gap_compact: f32 = 8;
/// Track table horizontal inset.
pub const table_gutter: f32 = 12;
/// Track table header vertical inset.
pub const table_header_gutter_y: f32 = 6;
/// Track rows reserve enough vertical space for a readable two-line identity.
pub const track_row_height: f32 = 48;
/// Track artwork edge length.
pub const track_artwork_size: f32 = 28;
/// Separation between track artwork and text.
pub const track_artwork_gap: f32 = 8;
/// Title-header inset that aligns it with the identity copy after the artwork.
pub const track_identity_copy_offset: f32 = track_artwork_size + track_artwork_gap;
/// Minimum width of the artwork-and-copy identity column.
pub const track_identity_width_min: f32 = 120;
/// Compact-only cap that prevents identity copy from crowding fixed controls.
pub const track_identity_text_width_compact_max: f32 =
    track_identity_width_min - track_identity_copy_offset;
/// Maximum readable width for album metadata in the narrowest full table column.
pub const track_album_text_width_max: f32 = 100;
/// Maximum readable width for date metadata in the desktop date column.
pub const track_date_text_width_max: f32 = 90;
/// Separation between title and artist in a table row.
pub const track_text_gap: f32 = 3;
/// Height reserved for the track title.
pub const track_title_slot_height: f32 = 20;
/// Height reserved for the track artist.
pub const track_artist_slot_height: f32 = 17;
/// Fixed height of the bottom playback bar.
pub const player_height: f32 = 72;
/// Inner inset shared by sidebar sections and navigation controls.
pub const sidebar_padding: f32 = app_inset;
/// Vertical separation between the sidebar's distinct navigation and library groups.
pub const sidebar_section_gap: f32 = 8;
/// Vertical separation inside the primary navigation group.
pub const sidebar_nav_gap: f32 = 2;
/// Height of one primary navigation target.
pub const sidebar_nav_row_height: f32 = 36;
/// Square icon target shared by collapsed navigation and playlist controls.
pub const sidebar_compact_target_size: f32 = 36;
/// Fixed height of one playlist row in the expanded sidebar.
pub const sidebar_row_height: f32 = 44;
/// Vertical separation between adjacent sidebar rows.
pub const sidebar_row_gap: f32 = 4;
/// Separation between a playlist title and its supporting metadata.
pub const sidebar_playlist_copy_gap: f32 = 2;
/// Type size for a playlist title.
pub const sidebar_playlist_title_size: f32 = 13;
/// Type size for playlist metadata.
pub const sidebar_playlist_metadata_size: f32 = 11;

// Spotify dark palette. Colors are authored in sRGB and converted at draw time.
pub const c_bg: [4]f32 = .{ 0.07, 0.07, 0.07, 1.0 };
pub const c_sidebar_bg: [4]f32 = .{ 0.02, 0.02, 0.02, 1.0 };
pub const c_card_bg: [4]f32 = .{ 0.09, 0.09, 0.09, 1.0 };
pub const c_card_elevated: [4]f32 = .{ 0.14, 0.14, 0.14, 1.0 };
pub const c_hover: [4]f32 = .{ 0.16, 0.16, 0.16, 1.0 };
pub const c_active_row: [4]f32 = .{ 0.165, 0.165, 0.165, 1.0 };
pub const c_track_active_bg: [4]f32 = .{ 0.10, 0.10, 0.10, 1.0 };
pub const c_table_divider: [4]f32 = .{ 1.0, 1.0, 1.0, 0.06 };
pub const playlist_artwork_size: f32 = 32.0;
pub const hero_artwork_size: f32 = 148.0;
pub const hero_overline_size: f32 = 10.0;
pub const hero_title_size: f32 = 28.0;
pub const hero_description_size: f32 = 12.0;
pub const hero_metadata_size: f32 = 11.0;
pub const c_player_bg: [4]f32 = .{ 0.09, 0.09, 0.09, 1.0 };
/// Secondary player controls blend into the fixed player band.
pub const c_player_control_bg: [4]f32 = c_player_bg;
pub const c_player_progress: [4]f32 = .{ 0.08, 0.52, 0.24, 1.0 };
pub const c_player_utility: [4]f32 = .{ 0.52, 0.52, 0.52, 1.0 };
pub const c_accent: [4]f32 = .{ 0.11, 0.73, 0.33, 1.0 };
pub const c_accent_hover: [4]f32 = .{ 0.12, 0.84, 0.38, 1.0 };
pub const c_accent_dim: [4]f32 = .{ 0.08, 0.28, 0.14, 1.0 };
pub const c_text: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 };
pub const c_text_sec: [4]f32 = .{ 0.70, 0.70, 0.70, 1.0 };
pub const c_text_muted: [4]f32 = .{ 0.42, 0.42, 0.42, 1.0 };
pub const c_border: [4]f32 = .{ 0.20, 0.20, 0.20, 0.5 };
pub const c_hero_grad_top: [4]f32 = .{ 0.20, 0.12, 0.30, 1.0 };
pub const c_hero_grad_bot: [4]f32 = .{ 0.07, 0.07, 0.08, 1.0 };
pub const c_like_active: [4]f32 = c_accent;

// Existing names stay public for callers that predate the expanded palette.
pub const c_card_hover: [4]f32 = c_hover;
pub const c_accent_bright: [4]f32 = c_accent_hover;
pub const c_hero_top: [4]f32 = c_hero_grad_top;
pub const c_hero_bot: [4]f32 = c_hero_grad_bot;

const artwork_gradients = [_][2][4]f32{
    .{ .{ 0.69, 0.12, 0.52, 1.0 }, .{ 0.25, 0.08, 0.48, 1.0 } },
    .{ .{ 0.10, 0.64, 0.78, 1.0 }, .{ 0.04, 0.20, 0.52, 1.0 } },
    .{ .{ 0.95, 0.42, 0.12, 1.0 }, .{ 0.54, 0.08, 0.18, 1.0 } },
    .{ .{ 0.22, 0.76, 0.42, 1.0 }, .{ 0.02, 0.30, 0.32, 1.0 } },
    .{ .{ 0.58, 0.34, 0.94, 1.0 }, .{ 0.14, 0.10, 0.52, 1.0 } },
    .{ .{ 0.92, 0.24, 0.38, 1.0 }, .{ 0.38, 0.06, 0.36, 1.0 } },
};

const artwork_emblems: [artwork_gradients.len][]const u8 = .{ "✦", "♪", "◉", "◆", "≈", "△" };

/// Returns a stable mark for compact playlist controls. The fixed playlist
/// seeds are explicit so adjacent recommendations never collapse to one icon.
pub fn compactArtworkMark(seed: u8) []const u8 {
    return switch (seed) {
        4 => "♥",
        37 => "✦",
        24 => "♪",
        45 => "◉",
        12 => "◆",
        18 => "≈",
        6 => "△",
        else => artwork_emblems[@as(usize, seed) % artwork_emblems.len],
    };
}

pub fn drawArtworkTile(
    ctx: *DrawCtx,
    size: f32,
    seed: u8,
    texture_index: ?u32,
) !Id {
    const index: usize = @as(usize, seed) % artwork_gradients.len;
    const colors = artwork_gradients[index];
    const radius: f32 = if (size <= track_artwork_size) 2.0 else 6.0;
    const tile = try ctx.column(.{
        .flex_basis = size,
        .min_width = size,
        .box_sizing = .border_box,
        .fill = colors[0],
        .gradient = srgbToOklab(colors[1]),
        .texture = texture_index,
        .radius = .{ .top = radius, .right = radius, .bottom = radius, .left = radius },
        .padding = .{
            .top = size * 0.28,
            .right = size * 0.18,
            .bottom = size * 0.18,
            .left = size * 0.18,
        },
        .shadow = @as(f32, if (size <= playlist_artwork_size) 0 else 4),
    });
    defer ctx.pop();

    if (texture_index != null) return tile;
    _ = try ctx.label(.{
        .text = compactArtworkMark(seed),
        .color = .{ 1.0, 1.0, 1.0, 0.88 },
        .font_size = size * 0.30,
    });
    _ = try ctx.spacer(.{ .size = size * 0.18 });
    return tile;
}
