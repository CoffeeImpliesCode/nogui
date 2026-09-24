//! Host asset loading, caching, deduplication, and invalidation.
//! Sources: embedded bytes, local files, caller-supplied HTTP transport, and
//! application loaders. Concurrent requests for one key share a single load;
//! a version stamp rejects completions that a removal or invalidation made
//! stale, and the cache evicts by byte budget while pins are honoured.
const std = @import("std");
const nogui = @import("nogui");

pub const asset_types = nogui.asset_types;
pub const AssetKey = asset_types.AssetKey;
pub const AssetSourceKind = asset_types.AssetSourceKind;
pub const AssetState = asset_types.AssetState;
pub const AssetError = asset_types.AssetError;

/// Maps a raw I/O or allocator error onto the bounded asset error set.
pub fn fromIo(err: anyerror) AssetError {
    return switch (err) {
        error.FileNotFound, error.NotDir => error.NotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.InvalidUtf8, error.BadPathName => error.InvalidUri,
        error.OutOfMemory => error.OutOfMemory,
        error.ConnectionRefused,
        error.TemporaryNameResolutionFailure,
        error.HostLacksNetworkAddresses,
        error.NetworkSubsystemFailed,
        error.ConnectionResetByPeer,
        error.HttpRequestWouldBlock,
        => error.NetworkError,
        else => error.IoError,
    };
}

/// The observable state of one key.
pub const Status = union(enum) {
    pending,
    ready: []const u8,
    failed: AssetError,

    pub fn state(self: Status) AssetState {
        return switch (self) {
            .pending => .pending,
            .ready => .ready,
            .failed => .error_state,
        };
    }
};

/// In-memory registry of embedded assets. The caller owns the registered bytes
/// and must keep them alive; `load` copies so the result is caller-owned.
pub const EmbeddedSource = struct {
    gpa: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged([]const u8) = .empty,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) EmbeddedSource {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *EmbeddedSource) void {
        self.mutex.lockUncancelable(self.io);
        self.entries.deinit(self.gpa);
        self.mutex.unlock(self.io);
        self.* = undefined;
    }

    pub fn register(self: *EmbeddedSource, name: []const u8, data: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.entries.put(self.gpa, name, data);
    }

    pub fn unregister(self: *EmbeddedSource, name: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        _ = self.entries.remove(name);
    }

    /// Copies the registered bytes. Fails with `not_found` for an unknown name.
    pub fn load(self: *EmbeddedSource, allocator: std.mem.Allocator, name: []const u8) AssetError![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.entries.get(name) orelse return error.NotFound;
        return allocator.dupe(u8, data) catch error.OutOfMemory;
    }
};

/// Local filesystem source. With a root set, a key path is joined to it and an
/// absolute or parent-escaping key is refused instead of resolved.
pub const FileSource = struct {
    io: std.Io,
    root: ?[]const u8 = null,
    max_bytes: usize = 128 * 1024 * 1024,

    pub fn init(io: std.Io, root: ?[]const u8) FileSource {
        return .{ .io = io, .root = root };
    }

    /// Joins `path` to the root into `buffer`, refusing absolute paths and any
    /// `..` component so a key cannot escape the root.
    pub fn resolve(self: FileSource, path: []const u8, buffer: []u8) AssetError![]const u8 {
        const root = self.root orelse {
            if (path.len == 0) return error.NotFound;
            if (path.len > buffer.len) return error.BudgetExceeded;
            @memcpy(buffer[0..path.len], path);
            return buffer[0..path.len];
        };
        if (path.len == 0 or std.fs.path.isAbsolute(path)) return error.AccessDenied;

        var written: usize = 0;
        for (root) |byte| {
            if (written == buffer.len) return error.BudgetExceeded;
            buffer[written] = byte;
            written += 1;
        }
        var segments = std.mem.tokenizeScalar(u8, path, '/');
        while (segments.next()) |segment| {
            if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
            if (std.mem.eql(u8, segment, "..")) return error.AccessDenied;
            if (written + 1 + segment.len > buffer.len) return error.BudgetExceeded;
            buffer[written] = '/';
            written += 1;
            @memcpy(buffer[written .. written + segment.len], segment);
            written += segment.len;
        }
        return buffer[0..written];
    }

    /// Reads the whole file into a caller-owned buffer.
    pub fn load(self: FileSource, allocator: std.mem.Allocator, path: []const u8) AssetError![]u8 {
        var path_buffer: [4096]u8 = undefined;
        const target = try self.resolve(path, &path_buffer);
        const file = std.Io.Dir.cwd().openFile(self.io, target, .{}) catch |err| return fromIo(err);
        defer file.close(self.io);

        const stat = file.stat(self.io) catch return error.IoError;
        if (stat.size > self.max_bytes) return error.BudgetExceeded;

        var read_buffer: [64 * 1024]u8 = undefined;
        // The reader must stay in place: its vtable recovers the enclosing
        // state with `@fieldParentPtr("interface", …)`, so copying the
        // interface into a local of its own points that recovery at the copy
        // and dereferences a fabricated parent.
        var file_reader = file.reader(self.io, &read_buffer);
        return file_reader.interface.allocRemaining(allocator, .limited(self.max_bytes)) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.StreamTooLong => error.BudgetExceeded,
            else => fromIo(err),
        };
    }
};

/// HTTP source. The default transport refuses: there is no ambient network
/// access, so a test or an application must install one explicitly.
pub const HttpSource = struct {
    pub const Transport = *const fn (
        allocator: std.mem.Allocator,
        ctx: ?*anyopaque,
        url: []const u8,
    ) AssetError![]u8;

    transport: ?Transport = null,
    transport_ctx: ?*anyopaque = null,
    max_bytes: usize = 64 * 1024 * 1024,

    pub fn init() HttpSource {
        return .{};
    }

    pub fn setTransport(self: *HttpSource, ctx: ?*anyopaque, transport: Transport) void {
        self.transport_ctx = ctx;
        self.transport = transport;
    }
    /// Fetches through the installed transport. With no transport, or with a
    /// key that is not http(s), it refuses instead of touching the network.
    pub fn load(self: *HttpSource, allocator: std.mem.Allocator, url: []const u8) AssetError![]u8 {
        const scheme_ok = std.mem.startsWith(u8, url, "http://") or
            std.mem.startsWith(u8, url, "https://");
        if (!scheme_ok) return error.InvalidUri;
        const transport = self.transport orelse return error.NetworkError;
        const data = try transport(allocator, self.transport_ctx, url);
        if (data.len > self.max_bytes) {
            allocator.free(data);
            return error.BudgetExceeded;
        }
        return data;
    }
};

/// Application-registered loader, selected by `app:` keys.
pub const AppSource = struct {
    pub const Loader = *const fn (
        allocator: std.mem.Allocator,
        ctx: ?*anyopaque,
        name: []const u8,
    ) AssetError![]u8;

    loader: ?Loader = null,
    ctx: ?*anyopaque = null,

    pub fn init() AppSource {
        return .{};
    }

    pub fn register(self: *AppSource, ctx: ?*anyopaque, loader: Loader) void {
        self.ctx = ctx;
        self.loader = loader;
    }

    /// Runs the registered loader. Fails with `not_found` when none is set.
    pub fn load(self: *AppSource, allocator: std.mem.Allocator, name: []const u8) AssetError![]u8 {
        const loader = self.loader orelse return error.NotFound;
        return loader(allocator, self.ctx, name);
    }
};

/// Cached bytes for one key. The key path is owned exactly once, here.
pub const CacheEntry = struct {
    key: AssetKey,
    path_storage: []u8,
    bytes: []u8,
    pins: u32 = 0,
    /// Set when a pin was live when the entry lost its hash or its
    /// generation. The bytes stay resident and stop being served; the last
    /// `unpin` frees them, so a live holder never reads freed memory.
    retired: bool = false,
    last_access_ns: i96 = 0,

    pub fn byteSize(self: CacheEntry) usize {
        return self.bytes.len;
    }
};

/// Byte-budgeted LRU cache. Pinned entries are never evicted; when the budget
/// cannot be met without breaking a pin, insertion is refused instead.
pub const AssetCache = struct {
    gpa: std.mem.Allocator,
    max_bytes: usize,
    used_bytes: usize = 0,
    entries: std.AutoHashMapUnmanaged(u64, CacheEntry) = .empty,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, max_bytes: usize) AssetCache {
        return .{ .gpa = gpa, .io = io, .max_bytes = max_bytes };
    }

    pub fn deinit(self: *AssetCache) void {
        self.mutex.lockUncancelable(self.io);
        var entries = self.entries.iterator();
        while (entries.next()) |item| {
            const entry = item.value_ptr;
            self.gpa.free(entry.path_storage);
            self.gpa.free(entry.bytes);
        }
        self.entries.deinit(self.gpa);
        self.used_bytes = 0;
        self.mutex.unlock(self.io);
        self.* = undefined;
    }

    /// Takes a pin and refreshes recency; the bytes stay valid until `unpin`.
    pub fn pin(self: *AssetCache, key: AssetKey, now_ns: i96) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.entries.getPtr(key.hash()) orelse return null;
        if (entry.key.generation != key.generation) return null;
        entry.pins += 1;
        entry.last_access_ns = now_ns;
        return entry.bytes;
    }

    pub fn unpin(self: *AssetCache, key: AssetKey) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.entries.getPtr(key.hash()) orelse return;
        if (entry.pins > 0) entry.pins -= 1;
        if (entry.pins == 0 and entry.retired) {
            // No caller is waiting for these bytes: the last pin is gone, so
            // the cache frees what it owns rather than handing it out.
            if (self.dropLocked(key.hash())) |bytes| self.gpa.free(bytes);
        }
    }

    /// Reads the bytes without pinning. The slice must not be retained.
    pub fn peek(self: *AssetCache, key: AssetKey, now_ns: i96) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.entries.getPtr(key.hash()) orelse return null;
        if (entry.key.generation != key.generation) return null;
        entry.last_access_ns = now_ns;
        return entry.bytes;
    }

    /// Retires the entry for `key` without breaking a pin. The entry stops
    /// being served immediately; an unpinned entry is freed here and its
    /// bytes handed back, a pinned one by the `unpin` that drops its last
    /// pin.
    pub fn invalidate(self: *AssetCache, key: AssetKey) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.entries.getPtr(key.hash()) orelse return null;
        if (entry.key.generation != key.generation) return null;
        // Serving the old version after an invalidation is the bug this
        // guards: the stored generation moves to the new one, so a peek or
        // pin against the old version misses while the map slot stays put
        // for the outstanding `unpin` to find.
        entry.key.generation +%= 1;
        if (entry.pins == 0) return self.dropLocked(key.hash());
        entry.retired = true;
        return null;
    }

    /// Inserts caller-owned bytes, evicting unpinned entries by recency.
    pub fn put(self: *AssetCache, key: AssetKey, bytes: []u8, now_ns: i96) AssetError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (bytes.len > self.max_bytes) return error.BudgetExceeded;
        if (!self.makeRoomLocked(bytes.len)) return error.BudgetExceeded;

        const owned_path = self.gpa.dupe(u8, key.path) catch return error.BudgetExceeded;
        errdefer self.gpa.free(owned_path);

        // A live entry can only exist under this hash when a reader already
        // holds the current version, and the load path returns from `peek`
        // before it can reach a replacement here. A pinned entry is
        // therefore impossible at this point, so the freed bytes have no
        // reader; a pinned entry reaches `invalidate`/`remove`, which retire
        // it instead of freeing it.
        if (self.entries.fetchRemove(key.hash())) |old| {
            self.used_bytes -= old.value.byteSize();
            self.gpa.free(old.value.path_storage);
            self.gpa.free(old.value.bytes);
        }
        var stored_key = key;
        stored_key.path = owned_path;
        self.entries.put(self.gpa, key.hash(), .{
            .key = stored_key,
            .path_storage = owned_path,
            .bytes = bytes,
            .pins = 0,
            .last_access_ns = now_ns,
        }) catch return error.BudgetExceeded;
        self.used_bytes += bytes.len;
    }

    fn makeRoomLocked(self: *AssetCache, needed: usize) bool {
        while (self.used_bytes + needed > self.max_bytes) {
            var victim: ?u64 = null;
            var oldest: i96 = std.math.maxInt(i96);
            var entries = self.entries.iterator();
            while (entries.next()) |item| {
                if (item.value_ptr.pins == 0 and item.value_ptr.last_access_ns < oldest) {
                    oldest = item.value_ptr.last_access_ns;
                    victim = item.key_ptr.*;
                }
            }
            const hash = victim orelse return false;
            const removed = self.entries.fetchRemove(hash).?;
            self.used_bytes -= removed.value.byteSize();
            self.gpa.free(removed.value.path_storage);
            self.gpa.free(removed.value.bytes);
        }
        return true;
    }

    /// Caller holds the mutex. Frees the entry and its bytes, if present.
    fn dropLocked(self: *AssetCache, hash: u64) ?[]u8 {
        const removed = self.entries.fetchRemove(hash) orelse return null;
        self.used_bytes -= removed.value.byteSize();
        self.gpa.free(removed.value.path_storage);
        return removed.value.bytes;
    }

    pub fn used(self: *AssetCache) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.used_bytes;
    }
};

/// One in-flight or finished load, shared by every requester of the same key.
pub const Load = struct {
    gpa: std.mem.Allocator,
    key: AssetKey,
    generation: u64,
    state: AssetState = .pending,
    failure: AssetError = error.NotFound,
    /// Set while this handle still owns the bytes. Handed to the cache on
    /// success, or freed here when the completion is stale.
    bytes: ?[]u8 = null,
    owns_bytes: bool = false,
    refs: u32 = 1,
    /// True while the tracker still lists this handle in its map.
    listed: bool = true,

    /// Valid only while this handle owns the bytes or the cache holds them.
    pub fn status(self: *Load) Status {
        return switch (self.state) {
            .pending => .pending,
            .ready => .{ .ready = self.bytes.? },
            .error_state => .{ .failed = self.failure },
            .invalidated => .{ .failed = error.Cancelled },
        };
    }

    pub fn stateOf(self: *Load) AssetState {
        return self.state;
    }

    fn retain(self: *Load) void {
        std.debug.assert(self.refs > 0);
        self.refs += 1;
    }

    fn release(self: *Load) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs != 0) return;
        if (self.owns_bytes) {
            if (self.bytes) |bytes| self.gpa.free(bytes);
        }
        self.gpa.destroy(self);
    }
};

/// Registry of live loads keyed by hash, plus the per-identity version counter.
pub const InFlightTracker = struct {
    gpa: std.mem.Allocator,
    loads: std.AutoHashMapUnmanaged(u64, *Load) = .empty,
    versions: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) InFlightTracker {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *InFlightTracker) void {
        self.mutex.lockUncancelable(self.io);
        var live = self.loads.iterator();
        while (live.next()) |item| {
            const load = item.value_ptr.*;
            load.listed = false;
            load.release();
        }
        self.loads.deinit(self.gpa);
        self.versions.deinit(self.gpa);
        self.mutex.unlock(self.io);
        self.* = undefined;
    }

    /// A key's identity ignores the version, so a new version replaces an old
    /// one instead of running beside it.
    pub fn identity(key: AssetKey) u64 {
        var hasher = std.hash.Wyhash.init(0x8899_abcd_ef01_2345);
        hasher.update(@tagName(key.kind));
        hasher.update(key.path);
        return hasher.final();
    }

    pub fn currentVersion(self: *InFlightTracker, key: AssetKey) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.versions.get(identity(key)) orelse 0;
    }

    /// Bumps the version. A load already running for the old version completes
    /// as cancelled and releases its bytes, so it cannot reach a live owner.
    pub fn invalidate(self: *InFlightTracker, key: AssetKey) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const id = identity(key);
        const next = (self.versions.get(id) orelse 0) +% 1;
        self.versions.put(self.gpa, id, next) catch return next;
        if (self.loads.getPtr(key.hash())) |slot_ptr| {
            const slot = slot_ptr.*;
            if (slot.generation != next and slot.state == .pending) {
                slot.state = .invalidated;
                self.condition.broadcast(self.io);
            }
        }
        return next;
    }

    pub const Acquire = union(enum) {
        /// The caller must run the load and then publish the outcome.
        start: *Load,
        /// A load for this key is already running; wait on the handle.
        join: *Load,
        /// The same version already finished; the handle carries its result.
        finished: *Load,
    };

    /// Registers interest in `key` at its current version. The caller holds one
    /// reference to the handle and must pass it to `releaseHandle`.
    pub fn acquire(self: *InFlightTracker, key: AssetKey) std.mem.Allocator.Error!Acquire {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const version = self.versions.get(identity(key)) orelse 0;
        var current = key;
        current.generation = version;

        if (self.loads.getPtr(current.hash())) |slot_ptr| {
            const slot = slot_ptr.*;
            if (slot.generation == version) {
                switch (slot.state) {
                    .pending => {
                        slot.retain();
                        return .{ .join = slot };
                    },
                    .ready, .error_state => {
                        slot.retain();
                        return .{ .finished = slot };
                    },
                    .invalidated => {},
                }
            }
            // A superseded or invalidated version cannot satisfy this request.
            self.unlistLocked(current.hash());
        }

        const load = try self.gpa.create(Load);
        load.* = .{ .gpa = self.gpa, .key = current, .generation = version };
        try self.loads.put(self.gpa, current.hash(), load);
        return .{ .start = load };
    }

    pub const Outcome = union(enum) { ok: []u8, err: AssetError };

    pub const Publish = enum { accepted, stale };

    /// Records a load outcome. On `stale` the bytes are released here, so a
    /// removal during the load can never resurrect content.
    pub fn publish(self: *InFlightTracker, load: *Load, outcome: Outcome) Publish {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const live_version = self.versions.get(identity(load.key)) orelse 0;
        if (load.generation != live_version or load.state == .invalidated) {
            switch (outcome) {
                .ok => |bytes| self.gpa.free(bytes),
                .err => {},
            }
            return .stale;
        }

        switch (outcome) {
            .ok => |bytes| {
                load.bytes = bytes;
                load.owns_bytes = true;
                load.state = .ready;
            },
            .err => |failure| {
                load.failure = failure;
                load.state = .error_state;
            },
        }
        self.condition.broadcast(self.io);
        return .accepted;
    }

    /// Blocks until a joined load publishes or is invalidated.
    pub fn awaitSettled(self: *InFlightTracker, load: *Load) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (load.state == .pending) self.condition.waitUncancelable(self.io, &self.mutex);
    }

    /// Drops the caller's reference and unlists a finished load.
    pub fn releaseHandle(self: *InFlightTracker, load: *Load) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (load.listed and load.state != .pending) self.unlistLocked(load.key.hash());
        load.release();
    }

    /// Caller holds the mutex.
    fn unlistLocked(self: *InFlightTracker, hash: u64) void {
        const removed = self.loads.fetchRemove(hash) orelse return;
        removed.value.listed = false;
    }
};

/// Loader dispatch plus the cache and the load registry.
pub const AssetManager = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cache: AssetCache,
    loads: InFlightTracker,
    embedded: EmbeddedSource,
    file: FileSource,
    http: HttpSource,
    app: AppSource,
    now_ns: i96 = 0,

    pub const Options = struct {
        max_cache_bytes: usize = 32 * 1024 * 1024,
        file_root: ?[]const u8 = null,
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) AssetManager {
        return .{
            .gpa = gpa,
            .io = io,
            .cache = AssetCache.init(gpa, io, options.max_cache_bytes),
            .loads = InFlightTracker.init(gpa, io),
            .embedded = EmbeddedSource.init(gpa, io),
            .file = FileSource.init(io, options.file_root),
            .http = HttpSource.init(),
            .app = AppSource.init(),
        };
    }

    pub fn deinit(self: *AssetManager) void {
        self.loads.deinit();
        self.cache.deinit();
        self.embedded.deinit();
        self.* = undefined;
    }

    /// Sets the timestamp used for cache recency; the caller owns the clock.
    pub fn setClock(self: *AssetManager, now_ns: i96) void {
        self.now_ns = now_ns;
    }

    /// Reads the source bytes for a key. The result is caller-owned.
    pub fn loadDirect(self: *AssetManager, key: AssetKey) AssetError![]u8 {
        return switch (key.kind) {
            .embedded => self.embedded.load(self.gpa, key.path),
            .file => self.file.load(self.gpa, key.path),
            .http => self.http.load(self.gpa, key.path),
            .app => self.app.load(self.gpa, key.path),
        };
    }

    /// Loads a key, sharing one load between concurrent requesters. A requester
    /// that joins a running load waits for that load's single result.
    /// The returned bytes are owned by the cache and stay valid until
    /// invalidation or eviction, so a caller that retains them must `pin`.
    pub fn load(self: *AssetManager, key: AssetKey) Status {
        var current = key;
        current.generation = self.loads.currentVersion(key);
        if (self.cache.peek(current, self.now_ns)) |bytes| return .{ .ready = bytes };

        const handle = self.loads.acquire(current) catch return .{ .failed = error.OutOfMemory };
        return switch (handle) {
            .start => |pending| self.runStart(current, pending),
            .join => |joined| self.shareLoad(joined),
            .finished => |done| self.shareLoad(done),
        };
    }

    /// Runs a load this request owns, unless another requester's load for the
    /// SAME version finished between this request's cache probe and its
    /// acquire. That window is real: the other requester inserted the bytes
    /// and unlisted its handle, so this acquire legitimately starts a new load
    /// and the source is read a second time. Re-probing the cache here is what
    /// makes the share hold for every interleaving, not only the ones where
    /// both requesters are still inside the load.
    fn runStart(self: *AssetManager, current: AssetKey, pending: *Load) Status {
        if (self.cache.peek(current, self.now_ns)) |bytes| {
            // This request never owned the load, so it must not run one and
            // must not touch the handle beyond releasing its own reference.
            self.loads.releaseHandle(pending);
            return .{ .ready = bytes };
        }
        return self.runLoad(pending);
    }

    /// Runs the source for a load this request started, publishes the outcome,
    /// and hands accepted bytes to the cache.
    fn runLoad(self: *AssetManager, pending: *Load) Status {
        const outcome: InFlightTracker.Outcome = blk: {
            const bytes = self.loadDirect(pending.key) catch |failure| break :blk .{ .err = failure };
            break :blk .{ .ok = bytes };
        };
        switch (self.loads.publish(pending, outcome)) {
            // A removal or invalidation during the load discarded the bytes.
            .stale => {
                self.loads.releaseHandle(pending);
                return .{ .failed = error.Cancelled };
            },
            .accepted => {},
        }
        const result: Status = if (pending.state == .ready) blk: {
            const bytes = pending.bytes.?;
            self.cache.put(pending.key, bytes, self.now_ns) catch |failure| {
                // The cache refused, so the bytes would have no owner. Report
                // the refusal and release them here rather than leaving a
                // window where a waiter holds a pointer nobody frees.
                self.gpa.free(bytes);
                pending.bytes = null;
                pending.owns_bytes = false;
                self.loads.releaseHandle(pending);
                return .{ .failed = failure };
            };
            // The cache owns the memory now. The handle keeps a borrowed view
            // so a waiter can still read the result, but must not free it.
            pending.owns_bytes = false;
            break :blk .{ .ready = bytes };
        } else .{ .failed = pending.failure };
        self.loads.releaseHandle(pending);
        return result;
    }

    /// Waits for a load another requester started and reports its result, so
    /// the source is read once no matter how many owners ask. The bytes are
    /// read through the handle while it is still held, because publication
    /// and cache insertion are not one atomic step.
    fn shareLoad(self: *AssetManager, other: *Load) Status {
        self.loads.awaitSettled(other);
        const result: Status = switch (other.state) {
            .ready => if (other.bytes) |bytes| .{ .ready = bytes } else .{ .failed = error.IoError },
            .error_state => .{ .failed = other.failure },
            .pending, .invalidated => .{ .failed = error.Cancelled },
        };
        self.loads.releaseHandle(other);
        return result;
    }

    /// Drops the cached bytes for a key, freeing them once no pin holds them.
    ///
    /// The cache entry is stored under the version that LOADED it, so
    /// invalidation retires that version and not the new one: removing by the
    /// post-bump generation would hash a version nothing was ever stored
    /// under, and the bytes would stay resident until unrelated pressure
    /// evicted them.
    pub fn invalidate(self: *AssetManager, key: AssetKey) u64 {
        const previous = self.loads.currentVersion(key);
        const version = self.loads.invalidate(key);
        if (self.cache.invalidate(key.withGeneration(previous))) |bytes| self.gpa.free(bytes);
        return version;
    }
};
