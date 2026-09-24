//! Core value contracts for asset keys, sources, states, and error sets.
//! Independent of host I/O or platform loaders.
const std = @import("std");

/// Classification of the origin source for an asset.
pub const AssetSourceKind = enum {
    /// In-memory binary data registered with the application bundle.
    embedded,
    /// Local filesystem file path.
    file,
    /// HTTP/HTTPS URL resource.
    http,
    /// Custom application-registered loader procedure.
    app,
};

/// Unique identifier for an asset, capturing source kind, path/URI, and display density variant.
pub const AssetKey = struct {
    kind: AssetSourceKind = .file,
    path: []const u8,
    dpi_scale: f32 = 1.0,
    generation: u64 = 0,

    pub fn init(kind: AssetSourceKind, path: []const u8) AssetKey {
        return .{
            .kind = kind,
            .path = path,
            .dpi_scale = 1.0,
            .generation = 0,
        };
    }

    pub fn withScale(self: AssetKey, scale: f32) AssetKey {
        var copy = self;
        copy.dpi_scale = scale;
        return copy;
    }

    pub fn withGeneration(self: AssetKey, gen: u64) AssetKey {
        var copy = self;
        copy.generation = gen;
        return copy;
    }

    /// Parses a URI string into an AssetKey.
    /// Recognizes schemas: "embedded:", "file:", "http://", "https://", "app:".
    /// Unadorned paths default to `.file`.
    pub fn parse(uri: []const u8) AssetKey {
        if (std.mem.startsWith(u8, uri, "embedded:")) {
            return .{ .kind = .embedded, .path = uri["embedded:".len..] };
        } else if (std.mem.startsWith(u8, uri, "file://")) {
            return .{ .kind = .file, .path = uri["file://".len..] };
        } else if (std.mem.startsWith(u8, uri, "file:")) {
            return .{ .kind = .file, .path = uri["file:".len..] };
        } else if (std.mem.startsWith(u8, uri, "http://") or std.mem.startsWith(u8, uri, "https://")) {
            return .{ .kind = .http, .path = uri };
        } else if (std.mem.startsWith(u8, uri, "app:")) {
            return .{ .kind = .app, .path = uri["app:".len..] };
        } else {
            return .{ .kind = .file, .path = uri };
        }
    }

    pub fn eql(a: AssetKey, b: AssetKey) bool {
        if (a.kind != b.kind) return false;
        if (!std.mem.eql(u8, a.path, b.path)) return false;
        if (@abs(a.dpi_scale - b.dpi_scale) > 0.0001) return false;
        return a.generation == b.generation;
    }

    pub fn hash(self: AssetKey) u64 {
        var hasher = std.hash.Wyhash.init(0x14A55E7);
        hasher.update(@tagName(self.kind));
        hasher.update(self.path);
        const scale_bits: u32 = @bitCast(self.dpi_scale);
        hasher.update(std.mem.asBytes(&scale_bits));
        hasher.update(std.mem.asBytes(&self.generation));
        return hasher.final();
    }
};

/// Lifecycle state of an asset within a loader or cache.
pub const AssetState = enum {
    /// In-flight load is pending or in progress.
    pending,
    /// Asset data is fully loaded and ready for consumption.
    ready,
    /// Load failed or yielded an error.
    error_state,
    /// Asset was explicitly invalidated or removed.
    invalidated,
};

/// Standard error set for asset operations.
pub const AssetError = error{
    NotFound,
    InvalidUri,
    NetworkError,
    DecodingFailed,
    FormatUnsupported,
    Cancelled,
    StaleGeneration,
    BudgetExceeded,
    OutOfMemory,
    IoError,
    AccessDenied,
    /// The source refused to read the bytes it was asked for.
    SourceUnavailable,
};
