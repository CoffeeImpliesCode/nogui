//! Mock Spotify UI implementation using the nogui v7 immediate-mode framework.

const std = @import("std");

const DrawCtx = @import("v7/drawctx.zig").DrawCtx;
const widget = @import("v7/widget.zig");
const WidgetTree = widget.WidgetTree;
const theme = @import("spotify_theme.zig");
const data = @import("spotify_data.zig");
const sidebar = @import("spotify_sidebar.zig");
const content = @import("spotify_content.zig");
const player = @import("spotify_player.zig");

pub const c_bg = theme.c_bg;
pub const c_sidebar_bg = theme.c_sidebar_bg;
pub const c_card_bg = theme.c_card_bg;
pub const c_card_elevated = theme.c_card_elevated;
pub const c_hover = theme.c_hover;
pub const c_card_hover = theme.c_card_hover;
pub const c_active_row = theme.c_active_row;
pub const c_player_bg = theme.c_player_bg;
pub const c_accent = theme.c_accent;
pub const c_accent_hover = theme.c_accent_hover;
pub const c_accent_bright = theme.c_accent_bright;
pub const c_accent_dim = theme.c_accent_dim;
pub const c_text = theme.c_text;
pub const c_text_sec = theme.c_text_sec;
pub const c_text_muted = theme.c_text_muted;
pub const c_border = theme.c_border;
pub const c_hero_grad_top = theme.c_hero_grad_top;
pub const c_hero_grad_bot = theme.c_hero_grad_bot;
pub const c_hero_top = theme.c_hero_top;
pub const c_hero_bot = theme.c_hero_bot;
pub const c_like_active = theme.c_like_active;

pub const Track = data.Track;
pub const PlaylistInfo = data.PlaylistInfo;
pub const NavTab = data.NavTab;
pub const CategoryPill = data.CategoryPill;
pub const PlaylistSelection = data.PlaylistSelection;
pub const SpotifyApp = struct {
    // Playback state
    is_playing: bool = true,
    current_track_idx: usize = 0,
    progress_sec: f32 = 84.0, // 1:24
    volume: f32 = 0.70,
    shuffle: bool = false,
    repeat: bool = false,

    // Navigation and filtering.
    active_nav: NavTab = .home,
    active_category: CategoryPill = .all,
    selected_playlist: PlaylistSelection = .cyberpunk,

    sidebar_scroll: widget.ScrollState = .{},
    content_scroll: widget.ScrollState = .{},
    playlist_saved: bool = false,

    // Data set
    tracks: [7]Track = data.default_tracks,
    playlists: [6]PlaylistInfo = data.default_playlists,

    // Interaction callbacks.

    pub fn togglePlay(self: *SpotifyApp) void {
        self.is_playing = !self.is_playing;
    }

    pub fn nextTrack(self: *SpotifyApp) void {
        self.current_track_idx = (self.current_track_idx + 1) % self.tracks.len;
        self.progress_sec = 0;
        self.is_playing = true;
    }

    pub fn prevTrack(self: *SpotifyApp) void {
        if (self.current_track_idx > 0) {
            self.current_track_idx -= 1;
        } else {
            self.current_track_idx = self.tracks.len - 1;
        }
        self.progress_sec = 0;
        self.is_playing = true;
    }

    pub fn toggleShuffle(self: *SpotifyApp) void {
        self.shuffle = !self.shuffle;
    }

    pub fn toggleRepeat(self: *SpotifyApp) void {
        self.repeat = !self.repeat;
    }

    pub fn toggleCurrentLike(self: *SpotifyApp) void {
        if (self.current_track_idx < self.tracks.len) {
            self.tracks[self.current_track_idx].is_liked = !self.tracks[self.current_track_idx].is_liked;
        }
    }

    pub fn toggleTrackLike(self: *SpotifyApp, idx: usize) void {
        if (idx < self.tracks.len) {
            self.tracks[idx].is_liked = !self.tracks[idx].is_liked;
        }
    }

    pub fn selectNavHome(self: *SpotifyApp) void {
        self.active_nav = .home;
    }

    pub fn selectNavSearch(self: *SpotifyApp) void {
        self.active_nav = .search;
    }

    pub fn selectNavLibrary(self: *SpotifyApp) void {
        self.active_nav = .library;
    }

    pub fn selectCategoryAll(self: *SpotifyApp) void {
        self.active_category = .all;
    }

    pub fn selectCategoryMusic(self: *SpotifyApp) void {
        self.active_category = .music;
    }

    pub fn selectCategoryPodcasts(self: *SpotifyApp) void {
        self.active_category = .podcasts;
    }
    pub fn togglePlaylistSaved(self: *SpotifyApp) void {
        self.playlist_saved = !self.playlist_saved;
    }

    pub fn selectTrack0(self: *SpotifyApp) void {
        self.selectTrack(0);
    }
    pub fn selectTrack1(self: *SpotifyApp) void {
        self.selectTrack(1);
    }
    pub fn selectTrack2(self: *SpotifyApp) void {
        self.selectTrack(2);
    }
    pub fn selectTrack3(self: *SpotifyApp) void {
        self.selectTrack(3);
    }
    pub fn selectTrack4(self: *SpotifyApp) void {
        self.selectTrack(4);
    }
    pub fn selectTrack5(self: *SpotifyApp) void {
        self.selectTrack(5);
    }
    pub fn selectTrack6(self: *SpotifyApp) void {
        self.selectTrack(6);
    }

    pub fn selectTrack(self: *SpotifyApp, idx: usize) void {
        if (idx < self.tracks.len) {
            self.current_track_idx = idx;
            self.progress_sec = 0;
            self.is_playing = true;
        }
    }

    pub fn selectPlaylistLiked(self: *SpotifyApp) void {
        self.selected_playlist = .liked_songs;
    }

    pub fn selectPlaylist0(self: *SpotifyApp) void {
        self.selected_playlist = .cyberpunk;
    }
    pub fn selectPlaylist1(self: *SpotifyApp) void {
        self.selected_playlist = .discover_weekly;
    }
    pub fn selectPlaylist2(self: *SpotifyApp) void {
        self.selected_playlist = .release_radar;
    }
    pub fn selectPlaylist3(self: *SpotifyApp) void {
        self.selected_playlist = .daily_mix;
    }
    pub fn selectPlaylist4(self: *SpotifyApp) void {
        self.selected_playlist = .deep_focus;
    }
    pub fn selectPlaylist5(self: *SpotifyApp) void {
        self.selected_playlist = .chill_lofi;
    }

    pub fn draw(self: *SpotifyApp, ctx: *DrawCtx) !void {
        // Root container column spanning whole window
        _ = try ctx.column(.{
            .gap = 8,
            .grow = 1,
            .padding = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
            .fill = c_bg,
            .gradient = theme.srgbToOklab(c_bg),
        });
        defer ctx.pop();

        // Upper workspace.
        {
            _ = try ctx.row(.{ .gap = 8, .grow = 1 });
            defer ctx.pop();

            // Left Navigation Sidebar
            try sidebar.draw(self, ctx);

            // Main Content Area (Playlist View / Catalog)
            try content.draw(self, ctx);
        }

        // Bottom player bar.
        try player.draw(self, ctx);
    }
};

test "SpotifyApp draws without error in DrawCtx" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    var app: SpotifyApp = .{};
    try app.draw(&ctx);

    // Verify node tree has been populated with essential hierarchy
    try std.testing.expect(tree.nodes.items.len > 20);

    // Verify interactions
    app.nextTrack();
    try std.testing.expectEqual(@as(usize, 1), app.current_track_idx);
    try std.testing.expectEqual(@as(f32, 0), app.progress_sec);
    try std.testing.expect(app.is_playing);

    app.prevTrack();
    try std.testing.expectEqual(@as(usize, 0), app.current_track_idx);

    app.togglePlay();
    try std.testing.expect(!app.is_playing);

    app.toggleShuffle();
    try std.testing.expect(app.shuffle);

    app.toggleRepeat();
    try std.testing.expect(app.repeat);
    app.selectPlaylistLiked();
    try std.testing.expectEqual(PlaylistSelection.liked_songs, app.selected_playlist);
    app.selectPlaylist0();
    try std.testing.expectEqual(PlaylistSelection.cyberpunk, app.selected_playlist);
    app.togglePlaylistSaved();
    try std.testing.expect(app.playlist_saved);
}
