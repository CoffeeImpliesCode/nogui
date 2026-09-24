const std = @import("std");
const ffmpeg_decoder = @import("ffmpeg_decoder.zig");
const spotify_data = @import("spotify_data.zig");

/// Bounded resource limits for a local-library scan.
pub const ScanOptions = struct {
    /// The root directory has depth zero. A nested directory at max_depth is
    /// scanned, but traversal into a deeper directory is rejected.
    max_depth: usize = 32,
    max_records: usize = spotify_data.local_queue_capacity,
    max_path_bytes: usize = 4096,
    max_metadata_bytes: usize = 1024,
};

pub const ScanError = error{
    RootPathNotAbsolute,
    DepthLimitExceeded,
    RecordLimitExceeded,
    PathLimitExceeded,
    MetadataLimitExceeded,
} || ffmpeg_decoder.ProbeError;

/// An allocator-owned, immutable-after-scan local audio library.
///
/// `records()` returns borrowed records. Their fields remain valid until
/// `deinit()` is called by the owner.
pub const LocalLibrary = struct {
    allocator: std.mem.Allocator,
    records_owned: std.ArrayList(spotify_data.LocalTrack),
    options: ScanOptions,

    pub fn scan(
        allocator: std.mem.Allocator,
        io: std.Io,
        root_path: []const u8,
        options: ScanOptions,
    ) (ScanError || std.Io.Dir.OpenError || std.Io.Dir.Iterator.Error || std.mem.Allocator.Error)!LocalLibrary {
        if (!std.fs.path.isAbsolute(root_path)) return error.RootPathNotAbsolute;
        if (root_path.len > options.max_path_bytes) return error.PathLimitExceeded;

        var library: LocalLibrary = .{
            .allocator = allocator,
            .records_owned = .empty,
            .options = options,
        };
        errdefer library.deinit();

        var root_dir = try std.Io.Dir.openDirAbsolute(io, root_path, .{
            .iterate = true,
            .follow_symlinks = false,
        });
        defer root_dir.close(io);

        try library.scanDirectory(io, root_dir, root_path, 0);
        std.sort.pdq(spotify_data.LocalTrack, library.records_owned.items, {}, lessThan);
        return library;
    }

    pub fn deinit(self: *LocalLibrary) void {
        for (self.records_owned.items) |*record| {
            self.allocator.free(record.path);
            self.allocator.free(record.title);
            self.allocator.free(record.artist);
            self.allocator.free(record.album);
            self.allocator.free(record.duration_str);
            if (record.artwork) |*artwork| artwork.deinit(self.allocator);
        }
        self.records_owned.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn records(self: *const LocalLibrary) []const spotify_data.LocalTrack {
        return self.records_owned.items;
    }

    fn scanDirectory(
        self: *LocalLibrary,
        io: std.Io,
        dir: std.Io.Dir,
        directory_path: []const u8,
        depth: usize,
    ) (ScanError || std.Io.Dir.OpenError || std.Io.Dir.Iterator.Error || std.mem.Allocator.Error)!void {
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            const child_path = try self.joinPath(directory_path, entry.name);

            switch (entry.kind) {
                .file => {
                    if (!isSupportedAudioExtension(child_path)) {
                        self.allocator.free(child_path);
                        continue;
                    }
                    try self.appendRecord(child_path);
                },
                .directory => {
                    defer self.allocator.free(child_path);
                    if (depth >= self.options.max_depth) return error.DepthLimitExceeded;

                    var child_dir = try dir.openDir(io, entry.name, .{
                        .iterate = true,
                        .follow_symlinks = false,
                    });
                    defer child_dir.close(io);
                    try self.scanDirectory(io, child_dir, child_path, depth + 1);
                },
                else => self.allocator.free(child_path),
            }
        }
    }

    fn joinPath(self: *LocalLibrary, parent: []const u8, name: []const u8) (ScanError || std.mem.Allocator.Error)![]u8 {
        const separator_bytes: usize = if (parent.len == 0 or parent[parent.len - 1] == std.fs.path.sep) 0 else 1;
        if (name.len > self.options.max_path_bytes or
            parent.len > self.options.max_path_bytes -| separator_bytes or
            name.len > self.options.max_path_bytes -| parent.len -| separator_bytes)
        {
            return error.PathLimitExceeded;
        }

        return std.fs.path.join(self.allocator, &.{ parent, name });
    }

    fn appendRecord(
        self: *LocalLibrary,
        owned_path: []u8,
    ) (ScanError || std.mem.Allocator.Error)!void {
        errdefer self.allocator.free(owned_path);
        if (self.records_owned.items.len >= self.options.max_records) {
            return error.RecordLimitExceeded;
        }
        var metadata = try ffmpeg_decoder.probeMetadata(self.allocator, owned_path);
        errdefer metadata.deinit(self.allocator);

        if (metadata.title.len > self.options.max_metadata_bytes or
            metadata.artist.len > self.options.max_metadata_bytes or
            metadata.album.len > self.options.max_metadata_bytes or
            metadata.duration_str.len > self.options.max_metadata_bytes)
        {
            return error.MetadataLimitExceeded;
        }

        try self.records_owned.append(self.allocator, .{
            .path = owned_path,
            .title = metadata.title,
            .artist = metadata.artist,
            .album = metadata.album,
            .duration_str = metadata.duration_str,
            .duration_sec = metadata.duration_sec,
            .artwork = metadata.artwork,
        });
        metadata.artwork = null;
    }
};

fn isSupportedAudioExtension(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".flac") or
        std.ascii.eqlIgnoreCase(extension, ".opus") or
        std.ascii.eqlIgnoreCase(extension, ".mp3") or
        std.ascii.eqlIgnoreCase(extension, ".m4a") or
        std.ascii.eqlIgnoreCase(extension, ".aac") or
        std.ascii.eqlIgnoreCase(extension, ".wav") or
        std.ascii.eqlIgnoreCase(extension, ".ogg");
}

fn lessThan(_: void, left: spotify_data.LocalTrack, right: spotify_data.LocalTrack) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}

const testing = std.testing;

fn createEmptyFile(dir: std.Io.Dir, sub_path: []const u8) !void {
    const file = try dir.createFile(testing.io, sub_path, .{});
    file.close(testing.io);
}

fn tempRootPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

test "scan owns sorted mixed-case FLAC records with fallback metadata" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "Alpha");
    try tmp.dir.createDirPath(testing.io, "Beta");
    try createEmptyFile(tmp.dir, "Alpha/One.flac");
    try createEmptyFile(tmp.dir, "Alpha/Two.FLAC");
    try createEmptyFile(tmp.dir, "Beta/three.FlAc");
    try createEmptyFile(tmp.dir, "Beta/ignored.aiff");

    const root = try tempRootPath(testing.allocator, &tmp);
    var library = LocalLibrary.scan(testing.allocator, testing.io, root, .{}) catch |err| {
        testing.allocator.free(root);
        return err;
    };
    defer library.deinit();
    testing.allocator.free(root);

    const found = library.records();
    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqualStrings("One", found[0].title);
    try testing.expectEqualStrings("Alpha", found[0].album);
    try testing.expectEqualStrings("Two", found[1].title);
    try testing.expectEqualStrings("Alpha", found[1].album);
    try testing.expectEqualStrings("three", found[2].title);
    try testing.expectEqualStrings("Beta", found[2].album);
    for (found) |record| {
        try testing.expect(std.fs.path.isAbsolute(record.path));
        try testing.expect(std.ascii.eqlIgnoreCase(std.fs.path.extension(record.path), ".flac"));
    }
}

test "supported local audio extensions retain common formats" {
    const supported_paths = [_][]const u8{
        "track.FLAC",
        "track.OpUs",
        "track.MP3",
        "track.M4A",
        "track.AaC",
        "track.WaV",
        "track.OGG",
    };
    for (supported_paths) |path| {
        try testing.expect(isSupportedAudioExtension(path));
    }

    const unsupported_paths = [_][]const u8{
        "track.AiFf",
        "track.FLAC.bak",
        "track",
    };
    for (unsupported_paths) |path| {
        try testing.expect(!isSupportedAudioExtension(path));
    }
}

test "scan rejects relative roots" {
    try testing.expectError(
        error.RootPathNotAbsolute,
        LocalLibrary.scan(testing.allocator, testing.io, "relative/music", .{}),
    );
}

test "scan enforces recursive depth and record limits" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "one/two");
    try createEmptyFile(tmp.dir, "one/two/deep.flac");
    try createEmptyFile(tmp.dir, "first.flac");
    try createEmptyFile(tmp.dir, "second.FLAC");

    const root = try tempRootPath(testing.allocator, &tmp);
    defer testing.allocator.free(root);

    try testing.expectError(
        error.DepthLimitExceeded,
        LocalLibrary.scan(testing.allocator, testing.io, root, .{ .max_depth = 1 }),
    );
    try testing.expectError(
        error.RecordLimitExceeded,
        LocalLibrary.scan(testing.allocator, testing.io, root, .{ .max_records = 1 }),
    );
}

test "scan enforces owned path and metadata limits" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createEmptyFile(tmp.dir, "long-title.flac");
    const root = try tempRootPath(testing.allocator, &tmp);
    defer testing.allocator.free(root);

    try testing.expectError(
        error.PathLimitExceeded,
        LocalLibrary.scan(testing.allocator, testing.io, root, .{ .max_path_bytes = root.len }),
    );
    try testing.expectError(
        error.MetadataLimitExceeded,
        LocalLibrary.scan(testing.allocator, testing.io, root, .{ .max_metadata_bytes = 4 }),
    );
}
