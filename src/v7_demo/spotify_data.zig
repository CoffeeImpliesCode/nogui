//! Spotify demo models and immutable seed data.
const std = @import("std");

/// Owned embedded artwork copied from an audio container.
pub const Artwork = struct {
    bytes: []u8,
    width: u32,
    height: u32,
    codec_id: c_int,

    pub fn deinit(self: *Artwork, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};
/// Maximum number of local tracks retained by the scanner and playback queue.
pub const local_queue_capacity: usize = 4096;
pub const Track = struct {
    id: u64,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    duration_str: []const u8,
    duration_sec: u24,
    date_added: []const u8,
    artwork_seed: u8 = 0,
    artwork_texture_index: ?u32 = null,
    is_liked: bool = false,
};
/// Borrowed local-library metadata. The owning library keeps these slices and
/// the optional artwork bytes alive.
pub const LocalTrack = struct {
    path: []const u8,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    duration_str: []const u8,
    duration_sec: u32,
    artwork: ?Artwork = null,
};

pub const PlaylistInfo = struct {
    name: []const u8,
    author: []const u8,
    artwork_seed: u8 = 0,
    is_pinned: bool = false,
};

pub const NavTab = enum {
    home,
    search,
    library,
};

pub const CategoryPill = enum {
    all,
    music,
    podcasts,
};

pub const PlaylistSelection = enum {
    liked_songs,
    cyberpunk,
    discover_weekly,
    release_radar,
    daily_mix,
    deep_focus,
    chill_lofi,
};

pub const default_tracks = [_]Track{
    .{
        .id = 1,
        .title = "Resonance",
        .artist = "HOME",
        .album = "Odyssey",
        .duration_str = "3:32",
        .duration_sec = 212,
        .date_added = "3 days ago",
        .artwork_seed = 37,
        .is_liked = true,
    },
    .{
        .id = 2,
        .title = "Nightcall",
        .artist = "Kavinsky",
        .album = "OutRun",
        .duration_str = "4:19",
        .duration_sec = 259,
        .date_added = "1 week ago",
        .artwork_seed = 12,
        .is_liked = true,
    },
    .{
        .id = 3,
        .title = "Memory Reboot",
        .artist = "VOJ & Narvent",
        .album = "Memory Reboot",
        .duration_str = "3:14",
        .duration_sec = 194,
        .date_added = "2 weeks ago",
        .artwork_seed = 24,
    },
    .{
        .id = 4,
        .title = "After Dark",
        .artist = "Mr.Kitty",
        .album = "Time",
        .duration_str = "4:17",
        .duration_sec = 257,
        .date_added = "May 12, 2026",
        .artwork_seed = 45,
    },
    .{
        .id = 5,
        .title = "Tech Noir",
        .artist = "Gunship",
        .album = "Gunship",
        .duration_str = "4:57",
        .duration_sec = 297,
        .date_added = "Apr 3, 2026",
        .artwork_seed = 6,
        .is_liked = true,
    },
    .{
        .id = 6,
        .title = "Sunset",
        .artist = "The Midnight",
        .album = "Endless Summer",
        .duration_str = "5:26",
        .duration_sec = 326,
        .date_added = "Feb 18, 2026",
        .artwork_seed = 18,
        .is_liked = true,
    },
    .{
        .id = 7,
        .title = "Days of Thunder",
        .artist = "The Midnight",
        .album = "Days of Thunder",
        .duration_str = "5:49",
        .duration_sec = 349,
        .date_added = "Jan 10, 2026",
        .artwork_seed = 31,
    },
    .{
        .id = 8,
        .title = "Midnight City",
        .artist = "M83",
        .album = "Hurry Up, We're Dreaming",
        .duration_str = "4:03",
        .duration_sec = 243,
        .date_added = "Dec 22, 2025",
        .artwork_seed = 42,
        .is_liked = true,
    },
    .{
        .id = 9,
        .title = "A Real Hero",
        .artist = "College & Electric Youth",
        .album = "Drive",
        .duration_str = "4:27",
        .duration_sec = 267,
        .date_added = "Nov 9, 2025",
        .artwork_seed = 9,
    },
    .{
        .id = 10,
        .title = "Running in the Night",
        .artist = "FM-84 feat. Ollie Wride",
        .album = "Atlas",
        .duration_str = "4:30",
        .duration_sec = 270,
        .date_added = "Oct 17, 2025",
        .artwork_seed = 28,
        .is_liked = true,
    },
    .{
        .id = 11,
        .title = "Turbo Killer",
        .artist = "Carpenter Brut",
        .album = "Trilogy",
        .duration_str = "3:33",
        .duration_sec = 213,
        .date_added = "Sep 4, 2025",
        .artwork_seed = 51,
    },
    .{
        .id = 12,
        .title = "Ocean Drive",
        .artist = "Miami Nights 1984",
        .album = "Turbulence",
        .duration_str = "4:53",
        .duration_sec = 293,
        .date_added = "Aug 16, 2025",
        .artwork_seed = 15,
    },
};

pub const default_playlists: [6]PlaylistInfo = .{
    .{
        .name = "Cyberpunk Ambient 2026",
        .author = "Spotify",
        .artwork_seed = 37,
        .is_pinned = true,
    },
    .{
        .name = "Discover Weekly",
        .author = "Made for you",
        .artwork_seed = 24,
        .is_pinned = true,
    },
    .{
        .name = "Release Radar",
        .author = "Made for you",
        .artwork_seed = 45,
        .is_pinned = true,
    },
    .{
        .name = "Daily Mix 1 (Synthwave)",
        .author = "Spotify",
        .artwork_seed = 12,
    },
    .{
        .name = "Deep Focus & Study",
        .author = "Spotify",
        .artwork_seed = 18,
    },
    .{
        .name = "Chill Lo-Fi Beats",
        .author = "Spotify",
        .artwork_seed = 6,
    },
};
