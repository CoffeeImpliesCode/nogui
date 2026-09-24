//! Mock Spotify UI implementation using the nogui v7 immediate-mode framework.

const std = @import("std");

const nogui = @import("nogui");
const nogui_text = @import("nogui_text");
const DrawCtx = nogui.DrawCtx;
const widget = nogui.widget;
const WidgetTree = widget.WidgetTree;
const headless = nogui.headless;
const demo_fonts = @import("fonts.zig");
const theme = @import("spotify_theme.zig");
const data = @import("spotify_data.zig");
const sidebar = @import("spotify_sidebar.zig");
const content = @import("spotify_content.zig");
const player = @import("spotify_player.zig");
const now_playing = @import("spotify_now_playing.zig");
const spotify_layout = @import("spotify_layout.zig");

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
pub const track_capacity: usize = data.local_queue_capacity;
pub const default_track_count: usize = data.default_tracks.len;

fn defaultTrackStorage() [track_capacity]Track {
    var tracks: [track_capacity]Track = undefined;
    for (data.default_tracks, 0..) |track, index| {
        tracks[index] = track;
    }
    return tracks;
}

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

    // Data set. The fixed array keeps the UI storage allocation-free.
    // Interactive startup replaces fixture tracks with this local queue.
    local_audio_queue_initialized: bool = false,
    active_track_count: usize = default_track_count,
    tracks: [track_capacity]Track = defaultTrackStorage(),

    playlists: [6]PlaylistInfo = data.default_playlists,

    // Interaction callbacks.

    pub fn activeTrackCount(self: *const SpotifyApp) usize {
        return @min(self.active_track_count, self.tracks.len);
    }

    pub fn activeTracks(self: *const SpotifyApp) []const Track {
        return self.tracks[0..self.activeTrackCount()];
    }

    pub fn currentTrackIndex(self: *const SpotifyApp) ?usize {
        const count = self.activeTrackCount();
        if (count == 0) return null;
        return if (self.current_track_idx < count) self.current_track_idx else 0;
    }

    pub fn currentTrack(self: *const SpotifyApp) ?*const Track {
        const index = self.currentTrackIndex() orelse return null;
        return &self.tracks[index];
    }

    /// Copy the bounded local queue into the fixed UI track storage.
    ///
    /// LocalLibrary owns the metadata slices. The UI only borrows those
    /// immutable slices for the lifetime of the interactive window.
    pub fn initLocalTracks(self: *SpotifyApp, local_tracks: []const data.LocalTrack) usize {
        const count = @min(local_tracks.len, track_capacity);
        self.local_audio_queue_initialized = true;
        self.active_track_count = count;
        self.current_track_idx = 0;
        self.progress_sec = 0;
        self.is_playing = false;
        if (count == 0) return 0;

        for (local_tracks[0..count], 0..) |local_track, index| {
            self.tracks[index] = .{
                .id = (@as(u64, 1) << 60) |
                    (std.hash.Wyhash.hash(0, local_track.path) & std.math.maxInt(u60)),
                .title = local_track.title,
                .artist = local_track.artist,
                .album = local_track.album,
                .duration_str = local_track.duration_str,
                .duration_sec = @intCast(@min(
                    local_track.duration_sec,
                    @as(u32, std.math.maxInt(u24)),
                )),
                .date_added = "Local library",
                .artwork_seed = @intCast(index % (@as(usize, std.math.maxInt(u8)) + 1)),
            };
        }

        return count;
    }

    /// Bind a persistent window-owned texture index to one local track.
    pub fn setArtworkTextureIndex(self: *SpotifyApp, index: usize, texture_index: ?u32) void {
        if (index < self.activeTrackCount()) {
            self.tracks[index].artwork_texture_index = texture_index;
        }
    }

    pub fn togglePlay(self: *SpotifyApp) void {
        if (self.currentTrackIndex() == null) {
            self.is_playing = false;
            return;
        }
        self.is_playing = !self.is_playing;
    }

    pub fn nextTrack(self: *SpotifyApp) void {
        const count = self.activeTrackCount();
        if (count == 0) return;

        const current_index = self.currentTrackIndex() orelse return;
        self.current_track_idx = (current_index + 1) % count;
        self.progress_sec = 0;
        self.is_playing = true;
    }

    /// Advance after decoder EOF without changing the play/pause state.
    pub fn advancePlaybackAtEnd(self: *SpotifyApp) void {
        const was_playing = self.is_playing;
        self.nextTrack();
        self.is_playing = was_playing;
    }

    pub fn prevTrack(self: *SpotifyApp) void {
        const count = self.activeTrackCount();
        if (count == 0) return;

        const current_index = self.currentTrackIndex() orelse return;
        self.current_track_idx = if (current_index > 0) current_index - 1 else count - 1;
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
        if (self.currentTrackIndex()) |index| {
            self.tracks[index].is_liked = !self.tracks[index].is_liked;
        }
    }

    pub fn toggleTrackLike(self: *SpotifyApp, idx: usize) void {
        if (idx < self.activeTrackCount()) {
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
        if (idx < self.activeTrackCount()) {
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
        const spec = spotify_layout.forSurface(ctx.surface);
        const workspace_tracks = [_]widget.ColumnTrack{
            .{
                .flex_basis = .{ .length = spec.sidebar_width },
                .grow = 0,
                .shrink = 0,
                .min_width = .{ .length = spec.sidebar_width },
            },
            .{
                .flex_basis = .{ .length = 0 },
                .grow = 1,
                .shrink = 1,
                .min_width = .{ .length = 360 },
            },
            .{
                .flex_basis = .{ .length = spec.now_playing_width },
                .grow = 0,
                .shrink = 0,
                .min_width = .{ .length = if (spec.show_now_playing) 220 else 0 },
            },
        };
        const workspace_columns: widget.SharedColumns = .{
            .tracks = if (spec.show_now_playing)
                workspace_tracks[0..]
            else
                workspace_tracks[0..2],
        };

        _ = try ctx.column(.{
            .gap = 8,
            .grow = 1,
            .padding = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
            .fill = c_bg,
        });
        defer ctx.pop();

        {
            // The row only arranges the three panels. Each panel paints its own
            // surface, so the gaps must reveal the outer application background.
            _ = try ctx.row(.{
                .columns = &workspace_columns,
                .gap = 8,
                .grow = 1,
                .shrink = 1,
                .min_height = 0,
                .clip = true,
                .transparent = true,
            });
            defer ctx.pop();

            try sidebar.draw(self, ctx, spec);
            try content.draw(self, ctx, spec);

            if (spec.show_now_playing) {
                // The rail column below paints the rail surface itself.
                _ = try ctx.row(.{
                    .flex_basis = spec.now_playing_width,
                    .grow = 0,
                    .shrink = 0,
                    .min_width = spec.now_playing_width,
                    .box_sizing = .border_box,
                    .clip = true,
                    .transparent = true,
                });
                defer ctx.pop();

                try now_playing.draw(self, ctx, spec);
            }
        }

        try player.draw(self, ctx, spec);
    }
};

test "SpotifyApp draws without error in DrawCtx" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    var app: SpotifyApp = .{};
    try std.testing.expectEqual(default_track_count, app.activeTrackCount());
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

fn verifySpotifyLayout(surface: widget.Size, expect_center_priority: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // SAFETY: `init` fills the measurer before this scope reads it.
    var measurer: nogui_text.TextMeasurer = undefined;
    try measurer.init(std.testing.allocator, &demo_fonts.pinned_fonts, demo_fonts.default_text_size);
    defer measurer.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{
        .tree = &tree,
        .arena = arena.allocator(),
        .surface = surface,
    };

    var app: SpotifyApp = .{};
    try app.draw(&ctx);

    try nogui.layout.layoutTree(&tree, .{
        .allocator = arena.allocator(),
        .available = surface,
        .measure = measurer.source(),
    });
    const report = try headless.verifyLayout(
        std.testing.allocator,
        &tree,
        measurer.source(),
        surface,
    );
    defer std.testing.allocator.free(report);
    try std.testing.expectEqualStrings("OK\n", report);

    if (!expect_center_priority) return;

    var workspace_row: ?*const widget.WidgetNode = null;
    for (tree.nodes.items) |*node| {
        switch (node.kind) {
            .row => {
                if (node.shared_columns != null and node.children.items.len == 3) {
                    workspace_row = node;
                    break;
                }
            },
            else => {},
        }
    }
    const row = workspace_row orelse return error.WorkspaceRowNotFound;
    const sidebar_node = tree.nodeConst(row.children.items[0]) orelse
        return error.WorkspaceSidebarNotFound;
    const center_node = tree.nodeConst(row.children.items[1]) orelse
        return error.WorkspaceCenterNotFound;
    const now_playing_node = tree.nodeConst(row.children.items[2]) orelse
        return error.WorkspaceNowPlayingNotFound;
    try std.testing.expect(center_node.rect.w > sidebar_node.rect.w);
    try std.testing.expect(center_node.rect.w > now_playing_node.rect.w);
}

test "SpotifyApp desktop layout verifier at 1100x1160 prioritizes center" {
    try verifySpotifyLayout(.{ .width = 1100, .height = 1160 }, true);
}

test "SpotifyApp medium layout verifier omits now-playing" {
    try verifySpotifyLayout(.{ .width = 900, .height = 1160 }, false);
}

test "SpotifyApp compact layout verifier omits now-playing and labels" {
    try verifySpotifyLayout(.{ .width = 640, .height = 1160 }, false);
}

test "Spotify compact generated sidebar labels use the final button width" {
    const surface: widget.Size = .{ .width = 640, .height = 1160 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var measurer: nogui_text.TextMeasurer = undefined;
    try measurer.init(std.testing.allocator, &demo_fonts.pinned_fonts, demo_fonts.default_text_size);
    defer measurer.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{
        .tree = &tree,
        .arena = arena.allocator(),
        .surface = surface,
    };

    var app: SpotifyApp = .{};
    try app.draw(&ctx);
    try nogui.layout.layoutTree(&tree, .{
        .allocator = arena.allocator(),
        .available = surface,
        .measure = measurer.source(),
    });

    // Compact sidebar buttons give each generated label a 36 px minimum.
    // The final main pass must recalculate centering after that minimum applies.
    const epsilon: f32 = 0.001;
    var compact_label_count: usize = 0;
    for (tree.nodes.items) |*node| {
        const parent = tree.nodeConst(node.parent) orelse continue;
        const visual_label = switch (parent.kind) {
            .button => |button| button.visual_label orelse continue,
            else => continue,
        };
        if (visual_label.len == 0) continue;
        const parent_content = try widget.contentRect(&tree, parent.id);
        if (@abs(parent_content.w - theme.sidebar_compact_target_size) > epsilon) continue;

        compact_label_count += 1;
        try std.testing.expectApproxEqAbs(@as(f32, 0), node.rect.x, epsilon);
        try std.testing.expectApproxEqAbs(parent_content.w, node.rect.w, epsilon);
    }
    try std.testing.expectEqual(@as(usize, 10), compact_label_count);
}

test "Spotify seek slider keeps minimum on its parent axis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{
        .tree = &tree,
        .arena = arena.allocator(),
        .surface = .{ .width = 1100, .height = 1160 },
    };

    var app: SpotifyApp = .{};
    try app.draw(&ctx);
    try nogui.layout.layoutTree(&tree, .{
        .allocator = arena.allocator(),
        .available = .{ .width = 1100, .height = 1160 },
        .measure = null,
    });

    var seek: ?*const widget.WidgetNode = null;
    for (tree.nodes.items) |*node| {
        switch (node.kind) {
            .slider => |slider| {
                if (std.mem.eql(u8, slider.label, "seek")) {
                    seek = node;
                    break;
                }
            },
            else => {},
        }
    }
    const seek_node = seek orelse return error.SeekSliderNotFound;
    try std.testing.expect(std.meta.eql(
        @as(nogui.Dimension, .{ .length = 100 }),
        seek_node.style.flex_basis,
    ));
    try std.testing.expect(std.meta.eql(
        @as(nogui.Dimension, .{ .length = 100 }),
        seek_node.style.min_size.width,
    ));
    try std.testing.expect(seek_node.rect.h < 100);
    try std.testing.expect(seek_node.rect.w >= 100);
}

test "SpotifyApp draw selects shell from surface" {
    var desktop_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer desktop_arena.deinit();
    var desktop_tree = WidgetTree.init(desktop_arena.allocator());
    defer desktop_tree.deinit();
    var desktop_ctx: DrawCtx = .{
        .tree = &desktop_tree,
        .arena = desktop_arena.allocator(),
    };
    var desktop_app: SpotifyApp = .{};
    try desktop_app.draw(&desktop_ctx);

    var medium_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer medium_arena.deinit();
    var medium_tree = WidgetTree.init(medium_arena.allocator());
    defer medium_tree.deinit();
    var medium_ctx: DrawCtx = .{
        .tree = &medium_tree,
        .arena = medium_arena.allocator(),
        .surface = .{ .width = 800, .height = 600 },
    };
    var medium_app: SpotifyApp = .{};
    try medium_app.draw(&medium_ctx);

    try std.testing.expectEqual(spotify_layout.Mode.desktop, spotify_layout.forSurface(null).mode);
    try std.testing.expectEqual(spotify_layout.Mode.medium, spotify_layout.forSurface(medium_ctx.surface).mode);
    try std.testing.expect(medium_tree.nodes.items.len < desktop_tree.nodes.items.len);
}

test "SpotifyApp generated album label stays inside its button at 1100x1160" {
    const surface: widget.Size = .{ .width = 1100, .height = 1160 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var measurer: nogui_text.TextMeasurer = undefined;
    try measurer.init(std.testing.allocator, &demo_fonts.pinned_fonts, demo_fonts.default_text_size);
    defer measurer.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{
        .tree = &tree,
        .arena = arena.allocator(),
        .surface = surface,
    };

    var app: SpotifyApp = .{};
    try app.draw(&ctx);
    try nogui.layout.layoutTree(&tree, .{
        .allocator = arena.allocator(),
        .available = surface,
        .measure = measurer.source(),
    });

    const expected_text = "Hurry Up, We're Dreaming";
    var generated_label: ?*const widget.WidgetNode = null;
    for (tree.nodes.items) |*node| {
        switch (node.kind) {
            .label => |label| {
                if (!std.mem.eql(u8, label.text, expected_text)) continue;
                const parent = tree.nodeConst(node.parent) orelse continue;
                switch (parent.kind) {
                    .button => |button| {
                        if (std.mem.eql(u8, button.label, expected_text)) {
                            generated_label = node;
                            break;
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
    const label_node = generated_label orelse return error.GeneratedAlbumLabelNotFound;
    const button_node = tree.nodeConst(label_node.parent) orelse
        return error.GeneratedAlbumButtonNotFound;

    try std.testing.expectEqual(widget.TextOverflow.ellipsis, label_node.text_overflow);
    const max_width = label_node.text_max_width orelse
        return error.GeneratedAlbumLabelMaxWidthMissing;
    try std.testing.expect(max_width > 0);

    const label_rect = widget.absoluteRect(&tree, label_node.id);
    const button_content_rect = try widget.contentRect(&tree, button_node.id);
    const epsilon: f32 = 0.001;
    try std.testing.expect(label_rect.x >= button_content_rect.x - epsilon);
    try std.testing.expect(label_rect.y >= button_content_rect.y - epsilon);
    try std.testing.expect(
        label_rect.x + label_rect.w <= button_content_rect.x + button_content_rect.w + epsilon,
    );
    try std.testing.expect(
        label_rect.y + label_rect.h <= button_content_rect.y + button_content_rect.h + epsilon,
    );
}

test "api-w02 local track IDs follow paths across queue reordering" {
    var local_tracks: [2]data.LocalTrack = .{
        .{
            .path = "music/a.flac",
            .title = "A",
            .artist = "Artist",
            .album = "Album",
            .duration_str = "1:00",
            .duration_sec = 60,
        },
        .{
            .path = "music/b.flac",
            .title = "B",
            .artist = "Artist",
            .album = "Album",
            .duration_str = "1:00",
            .duration_sec = 60,
        },
    };
    var app: SpotifyApp = .{};
    _ = app.initLocalTracks(&local_tracks);
    const a_id = app.tracks[0].id;
    const b_id = app.tracks[1].id;
    try std.testing.expect(a_id != b_id);

    std.mem.swap(data.LocalTrack, &local_tracks[0], &local_tracks[1]);
    _ = app.initLocalTracks(&local_tracks);
    try std.testing.expectEqual(b_id, app.tracks[0].id);
    try std.testing.expectEqual(a_id, app.tracks[1].id);
}

test "SpotifyApp retains a full local queue at the shared capacity" {
    var local_tracks: [track_capacity]data.LocalTrack = undefined;
    for (&local_tracks, 0..) |*local_track, index| {
        local_track.* = .{
            .path = "local.flac",
            .title = if (index == track_capacity - 1) "last" else "local",
            .artist = "Artist",
            .album = "Album",
            .duration_str = "1:00",
            .duration_sec = 60,
        };
    }

    var app: SpotifyApp = .{};
    const active_count = app.initLocalTracks(&local_tracks);

    try std.testing.expectEqual(track_capacity, active_count);
    try std.testing.expectEqual(track_capacity, app.activeTrackCount());
    try std.testing.expectEqualStrings("last", app.activeTracks()[track_capacity - 1].title);
}
test "SpotifyApp local queue starts paused until explicit play" {
    const local_tracks = [_]data.LocalTrack{.{
        .path = "local.flac",
        .title = "Local",
        .artist = "Artist",
        .album = "Album",
        .duration_str = "1:00",
        .duration_sec = 60,
    }};

    var app: SpotifyApp = .{};
    try std.testing.expect(app.is_playing);
    try std.testing.expectEqual(@as(usize, 1), app.initLocalTracks(&local_tracks));
    try std.testing.expect(!app.is_playing);

    app.togglePlay();
    try std.testing.expect(app.is_playing);
}

test "SpotifyApp local tracks share rendered order and report unavailable playback when empty" {
    const local_tracks = [_]data.LocalTrack{
        .{
            .path = "first.flac",
            .title = "Local First",
            .artist = "Local Artist",
            .album = "Local Album",
            .duration_str = "1:01",
            .duration_sec = 61,
        },
        .{
            .path = "second.flac",
            .title = "Local Second",
            .artist = "Second Artist",
            .album = "Second Album",
            .duration_str = "2:02",
            .duration_sec = 122,
        },
    };

    var app: SpotifyApp = .{};
    try std.testing.expectEqual(@as(usize, 2), app.initLocalTracks(&local_tracks));
    try std.testing.expectEqualStrings("Local First", app.activeTracks()[0].title);
    app.selectTrack(1);
    const current_track = app.currentTrack() orelse return error.CurrentTrackUnavailable;
    try std.testing.expectEqualStrings("Local Second", current_track.title);

    var empty_app: SpotifyApp = .{};
    const empty_tracks: [0]data.LocalTrack = .{};
    try std.testing.expectEqual(@as(usize, 0), empty_app.initLocalTracks(&empty_tracks));
    try std.testing.expectEqual(@as(usize, 0), empty_app.activeTrackCount());
    try std.testing.expect(!empty_app.is_playing);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
    try empty_app.draw(&ctx);

    var unavailable_tracks_label_found = false;
    var unavailable_player_label_found = false;
    var fallback_track_label_found = false;
    for (tree.nodes.items) |*node| {
        switch (node.kind) {
            .label => |label| {
                if (std.mem.eql(u8, label.text, "No local tracks available")) {
                    unavailable_tracks_label_found = true;
                }
                if (std.mem.eql(u8, label.text, "Playback unavailable")) {
                    unavailable_player_label_found = true;
                }
                if (std.mem.eql(u8, label.text, "Resonance")) {
                    fallback_track_label_found = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(unavailable_tracks_label_found);
    try std.testing.expect(unavailable_player_label_found);
    try std.testing.expect(!fallback_track_label_found);
}
