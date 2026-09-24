//! Responsive Spotify shell classification.
//!
//! This module owns only surface-derived layout semantics. Scene modules consume
//! the resulting specification but do not need to repeat breakpoint logic.
const std = @import("std");

const nogui = @import("nogui");
const widget = nogui.widget;
const theme = @import("spotify_theme.zig");

pub const Mode = enum {
    desktop,
    medium,
    compact,
};

pub const Spec = struct {
    mode: Mode,
    sidebar_width: f32,
    now_playing_width: f32,
    show_now_playing: bool,
    show_sidebar_labels: bool,
    show_album_column: bool,
    show_date_column: bool,
};

/// Classify a host surface into the shell's semantic layout mode.
///
/// A missing surface is the legacy direct-draw path and retains the 1100x1160
/// desktop reference. Height is intentionally not a breakpoint: the shell's
/// horizontal regions determine this classification.
pub fn forSurface(surface: ?widget.Size) Spec {
    const width = if (surface) |size| size.width else 1100;
    if (width >= 1024) {
        return .{
            .mode = .desktop,
            .sidebar_width = theme.sidebar_width_full,
            .now_playing_width = theme.now_playing_width_full,
            .show_now_playing = true,
            .show_sidebar_labels = true,
            .show_album_column = true,
            .show_date_column = true,
        };
    }
    if (width >= 760) {
        return .{
            .mode = .medium,
            .sidebar_width = theme.sidebar_width_full,
            .now_playing_width = 0,
            .show_now_playing = false,
            .show_sidebar_labels = true,
            .show_album_column = true,
            .show_date_column = false,
        };
    }
    return .{
        .mode = .compact,
        .sidebar_width = theme.sidebar_width_compact,
        .now_playing_width = 0,
        .show_now_playing = false,
        .show_sidebar_labels = false,
        .show_album_column = false,
        .show_date_column = false,
    };
}

test "forSurface keeps the reference desktop semantics" {
    const spec = forSurface(.{ .width = 1100, .height = 1160 });
    try std.testing.expectEqual(Mode.desktop, spec.mode);
    try std.testing.expectEqual(theme.sidebar_width_full, spec.sidebar_width);
    try std.testing.expectEqual(theme.now_playing_width_full, spec.now_playing_width);
    try std.testing.expect(spec.show_now_playing);
    try std.testing.expect(spec.show_sidebar_labels);
    try std.testing.expect(spec.show_album_column);
    try std.testing.expect(spec.show_date_column);
}

test "forSurface preserves direct draw as desktop" {
    const spec = forSurface(null);
    try std.testing.expectEqual(Mode.desktop, spec.mode);
    try std.testing.expectEqual(theme.sidebar_width_full, spec.sidebar_width);
    try std.testing.expectEqual(theme.now_playing_width_full, spec.now_playing_width);
}

test "forSurface uses width thresholds and ignores height" {
    const medium = forSurface(.{ .width = 1023, .height = 1 });
    try std.testing.expectEqual(Mode.medium, medium.mode);
    try std.testing.expect(!medium.show_now_playing);
    try std.testing.expect(medium.show_sidebar_labels);
    try std.testing.expect(medium.show_album_column);
    try std.testing.expect(!medium.show_date_column);

    const compact = forSurface(.{ .width = 759, .height = 10_000 });
    try std.testing.expectEqual(Mode.compact, compact.mode);
    try std.testing.expectEqual(theme.sidebar_width_compact, compact.sidebar_width);
    try std.testing.expect(!compact.show_now_playing);
    try std.testing.expect(!compact.show_sidebar_labels);
    try std.testing.expect(!compact.show_album_column);
    try std.testing.expect(!compact.show_date_column);
}
