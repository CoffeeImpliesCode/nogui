//! Spotify demo models and immutable seed data.

pub const Track = struct {
    id: u32,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    duration_str: []const u8,
    duration_sec: u24,
    date_added: []const u8,
    is_liked: bool = false,
};

pub const PlaylistInfo = struct {
    name: []const u8,
    author: []const u8,
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

pub const default_tracks: [7]Track = .{
    .{
        .id = 1,
        .title = "Resonance",
        .artist = "HOME",
        .album = "Odyssey",
        .duration_str = "3:32",
        .duration_sec = 212,
        .date_added = "3 days ago",
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
    },
    .{
        .id = 4,
        .title = "After Dark",
        .artist = "Mr.Kitty",
        .album = "Time",
        .duration_str = "4:17",
        .duration_sec = 257,
        .date_added = "May 12, 2026",
    },
    .{
        .id = 5,
        .title = "Tech Noir",
        .artist = "Gunship",
        .album = "Gunship",
        .duration_str = "4:57",
        .duration_sec = 297,
        .date_added = "Apr 3, 2026",
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
    },
};

pub const default_playlists: [6]PlaylistInfo = .{
    .{ .name = "Cyberpunk Ambient 2026", .author = "Spotify", .is_pinned = true },
    .{ .name = "Discover Weekly", .author = "Made for you", .is_pinned = true },
    .{ .name = "Release Radar", .author = "Made for you", .is_pinned = true },
    .{ .name = "Daily Mix 1 (Synthwave)", .author = "Spotify", .is_pinned = false },
    .{ .name = "Deep Focus & Study", .author = "Spotify", .is_pinned = false },
    .{ .name = "Chill Lo-Fi Beats", .author = "Spotify", .is_pinned = false },
};
