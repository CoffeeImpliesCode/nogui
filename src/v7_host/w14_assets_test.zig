//! Behavioral tests for the W14 asset key, source, loader, and cache:
//! in-flight deduplication, versioned invalidation, failure classes, source
//! policy, and byte-budget eviction with pins. Registered by w14_contract_test.
const std = @import("std");
const assets = @import("assets.zig");

const AssetKey = assets.AssetKey;

/// The asset services take a caller-owned `Io`, the same way the W05 task
/// service does, so each test owns one threaded implementation.
const TestIo = struct {
    threaded: std.Io.Threaded,
    io: std.Io,

    fn init() TestIo {
        // SAFETY: both fields are written on the next two lines, and `io` is
        // taken from `threaded` only once `threaded` holds its final value.
        var self: TestIo = .{ .threaded = undefined, .io = undefined };
        self.threaded = .init(std.testing.allocator, .{});
        self.io = self.threaded.io();
        return self;
    }

    fn deinit(self: *TestIo) void {
        self.threaded.deinit();
        self.* = undefined;
    }
};

/// An application loader that counts its calls and can block, so a test can
/// prove that two requesters share one load.
const CountingAppLoader = struct {
    calls: std.atomic.Value(u32) = .init(0),
    io: std.Io,
    gate: std.Io.Mutex = .init,
    release: std.Io.Condition = .init,
    blocked: bool = false,
    body: []const u8 = "shared-bytes",

    fn init(io: std.Io) CountingAppLoader {
        return .{ .io = io };
    }

    fn load(allocator: std.mem.Allocator, ctx: ?*anyopaque, name: []const u8) assets.AssetError![]u8 {
        const self: *CountingAppLoader = @ptrCast(@alignCast(ctx.?));
        _ = self.calls.fetchAdd(1, .monotonic);
        if (!std.mem.startsWith(u8, name, "logo")) return error.NotFound;
        self.gate.lockUncancelable(self.io);
        defer self.gate.unlock(self.io);
        while (self.blocked) self.release.waitUncancelable(self.io, &self.gate);
        return allocator.dupe(u8, self.body) catch error.OutOfMemory;
    }

    fn block(self: *CountingAppLoader) void {
        self.gate.lockUncancelable(self.io);
        defer self.gate.unlock(self.io);
        self.blocked = true;
    }

    fn unblock(self: *CountingAppLoader) void {
        self.gate.lockUncancelable(self.io);
        defer self.gate.unlock(self.io);
        self.blocked = false;
        self.release.broadcast(self.io);
    }
};

const LoadThread = struct {
    manager: *assets.AssetManager,
    name: []const u8 = "logo",
    result: assets.Status = .pending,

    fn run(self: *LoadThread) void {
        self.result = self.manager.load(AssetKey.init(.app, self.name));
    }
};

test "api-w14 concurrent requests share one load" {
    var tio = TestIo.init();
    defer tio.deinit();
    const io = tio.io;

    var manager = assets.AssetManager.init(std.testing.allocator, io, .{ .max_cache_bytes = 1 << 20 });
    defer manager.deinit();

    var loader = CountingAppLoader.init(io);
    manager.app.register(&loader, CountingAppLoader.load);

    // Repeated so that a thread-scheduling race between the requester that
    // runs the load and the requester that joins it cannot pass by luck. Each
    // round uses a fresh key, so the cache never answers the second request.
    var round: usize = 0;
    while (round < 64) : (round += 1) {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "logo-{d}", .{round});
        const before = loader.calls.load(.acquire);

        // Hold the first requester inside the loader.
        loader.block();
        var first: LoadThread = .{ .manager = &manager, .name = name };
        const first_thread = try std.Thread.spawn(.{}, LoadThread.run, .{&first});
        // The spin exists only to observe the counter change, so it yields the
        // rest of the slice between checks and gives up at a bound instead of
        // hanging the suite when the loader never runs.
        var spins: usize = 0;
        while (loader.calls.load(.acquire) == before and spins < 1_000_000) : (spins += 1) {
            try std.Thread.yield();
        }
        try std.testing.expect(loader.calls.load(.acquire) != before);

        // The second requester must join that load, not start its own.
        var second: LoadThread = .{ .manager = &manager, .name = name };
        const second_thread = try std.Thread.spawn(.{}, LoadThread.run, .{&second});

        loader.unblock();
        first_thread.join();
        second_thread.join();

        try std.testing.expectEqual(before + 1, loader.calls.load(.acquire));
        try std.testing.expectEqual(assets.AssetState.ready, first.result.state());
        try std.testing.expectEqual(assets.AssetState.ready, second.result.state());
        try std.testing.expectEqualStrings("shared-bytes", first.result.ready);
        try std.testing.expectEqualStrings("shared-bytes", second.result.ready);
    }
}

test "api-w14 removal during load cannot resurrect stale content" {
    var tio = TestIo.init();
    defer tio.deinit();
    const io = tio.io;

    var tracker = assets.InFlightTracker.init(std.testing.allocator, io);
    defer tracker.deinit();

    const key = AssetKey.init(.app, "logo");
    const load = switch (try tracker.acquire(key)) {
        .start => |started| started,
        else => unreachable,
    };
    try std.testing.expectEqual(@as(u64, 0), load.generation);

    // A removal lands while the load is still running.
    try std.testing.expectEqual(@as(u64, 1), tracker.invalidate(key));

    // The load finishes late. The bytes are released here and the handle can
    // never report ready, so no owner receives the stale content.
    const stale = try std.testing.allocator.dupe(u8, "stale-payload");
    try std.testing.expectEqual(
        assets.InFlightTracker.Publish.stale,
        tracker.publish(load, .{ .ok = stale }),
    );
    try std.testing.expectEqual(assets.AssetState.invalidated, load.stateOf());
    tracker.releaseHandle(load);
}

test "api-w14 failed load reports a failure class and caches nothing" {
    var tio = TestIo.init();
    defer tio.deinit();
    const io = tio.io;

    var manager = assets.AssetManager.init(std.testing.allocator, io, .{ .max_cache_bytes = 4096 });
    defer manager.deinit();

    const missing = manager.load(AssetKey.init(.app, "not-registered"));
    try std.testing.expectEqual(assets.AssetState.error_state, missing.state());
    try std.testing.expectEqual(error.NotFound, missing.failed);
    try std.testing.expectEqual(@as(usize, 0), manager.cache.used());

    // A repeat request re-runs the source instead of caching the failure.
    const again = manager.load(AssetKey.init(.app, "not-registered"));
    try std.testing.expectEqual(error.NotFound, again.failed);
}

test "api-w14 invalidated key is not served from the old cache entry" {
    var tio = TestIo.init();
    defer tio.deinit();
    const io = tio.io;

    var manager = assets.AssetManager.init(std.testing.allocator, io, .{ .max_cache_bytes = 4096 });
    defer manager.deinit();

    var loader = CountingAppLoader.init(io);
    manager.app.register(&loader, CountingAppLoader.load);
    loader.body = "first";

    const key = AssetKey.init(.app, "logo");
    const first = manager.load(key);
    try std.testing.expectEqualStrings("first", first.ready);
    try std.testing.expectEqual(@as(usize, 5), manager.cache.used());

    loader.body = "second";
    _ = manager.invalidate(key);
    try std.testing.expectEqual(@as(usize, 0), manager.cache.used());

    const after = manager.load(key);
    try std.testing.expectEqualStrings("second", after.ready);
}

test "api-w14 invalidating a pinned version retains its bytes until the last pin retires" {
    var tio = TestIo.init();
    defer tio.deinit();
    var manager = assets.AssetManager.init(std.testing.allocator, tio.io, .{ .max_cache_bytes = 32 });
    defer manager.deinit();

    var loader = CountingAppLoader.init(tio.io);
    manager.app.register(&loader, CountingAppLoader.load);
    loader.body = "first";
    const key = AssetKey.init(.app, "logo");
    try std.testing.expectEqualStrings("first", manager.load(key).ready);
    const pinned = manager.cache.pin(key, 0) orelse return error.NoPinnedBytes;

    try std.testing.expectEqual(@as(u64, 1), manager.invalidate(key));
    try std.testing.expectEqualStrings("first", pinned);
    try std.testing.expectEqual(@as(usize, 5), manager.cache.used());
    try std.testing.expect(manager.cache.peek(key, 0) == null);

    loader.body = "second";
    try std.testing.expectEqualStrings("second", manager.load(key).ready);
    try std.testing.expectEqual(@as(usize, 11), manager.cache.used());
    manager.cache.unpin(key);
    try std.testing.expectEqual(@as(usize, 6), manager.cache.used());
}

test "api-w14 http source refuses without an installed transport" {
    var source = assets.HttpSource.init();
    // No ambient network access: an http key cannot resolve on its own.
    try std.testing.expectEqual(
        error.NetworkError,
        source.load(std.testing.allocator, "http://127.0.0.1/tile.png"),
    );
    try std.testing.expectEqual(
        error.InvalidUri,
        source.load(std.testing.allocator, "/tmp/tile.png"),
    );
}

const FixtureTransport = struct {
    body: []const u8 = "http-fixture",

    fn fetch(allocator: std.mem.Allocator, ctx: ?*anyopaque, url: []const u8) assets.AssetError![]u8 {
        const self: *FixtureTransport = @ptrCast(@alignCast(ctx.?));
        if (!std.mem.startsWith(u8, url, "http://127.0.0.1:8080/")) return error.NotFound;
        return allocator.dupe(u8, self.body) catch error.OutOfMemory;
    }
};

test "api-w14 http fixture bytes load through an installed transport" {
    var tio = TestIo.init();
    defer tio.deinit();
    const io = tio.io;

    var manager = assets.AssetManager.init(std.testing.allocator, io, .{ .max_cache_bytes = 4096 });
    defer manager.deinit();

    var fixture: FixtureTransport = .{};
    manager.http.setTransport(&fixture, FixtureTransport.fetch);

    const status = manager.load(AssetKey.init(.http, "http://127.0.0.1:8080/tile.png"));
    try std.testing.expectEqualStrings("http-fixture", status.ready);

    // A cache hit makes no further transport call.
    const again = manager.load(AssetKey.init(.http, "http://127.0.0.1:8080/tile.png"));
    try std.testing.expectEqualStrings("http-fixture", again.ready);
}

test "api-w14 file source refuses a key that escapes its root" {
    var tio = TestIo.init();
    defer tio.deinit();
    const io = tio.io;

    var source = assets.FileSource.init(io, "/srv/assets");
    var buffer: [256]u8 = undefined;

    try std.testing.expectEqualStrings(
        "/srv/assets/icons/save.png",
        try source.resolve("icons/save.png", &buffer),
    );
    try std.testing.expectEqual(
        error.AccessDenied,
        source.resolve("../etc/passwd", &buffer),
    );
    try std.testing.expectEqual(
        error.AccessDenied,
        source.resolve("/etc/passwd", &buffer),
    );
}

test "api-w14 a pinned entry survives pressure and becomes evictable on unpin" {
    var tio = TestIo.init();
    defer tio.deinit();
    const io = tio.io;

    var cache = assets.AssetCache.init(std.testing.allocator, io, 100);
    defer cache.deinit();

    const now: i96 = 1000;
    const held = AssetKey.init(.embedded, "held");
    const pinned_bytes = try std.testing.allocator.dupe(u8, "1234567890123456789012345678901234567890"); // 40
    try cache.put(held, pinned_bytes, now);
    _ = cache.pin(held, now);

    // 40 held + 80 requested exceeds the 100-byte budget. Nothing else is
    // evictable, so the insert is refused rather than dropping a live image.
    var body: [80]u8 = undefined;
    @memset(&body, 'L');
    const refused = try std.testing.allocator.dupe(u8, &body);
    try std.testing.expectEqual(
        error.BudgetExceeded,
        cache.put(AssetKey.init(.embedded, "refused"), refused, now + 1) catch |failure| failure,
    );
    std.testing.allocator.free(refused);

    // The pinned entry is untouched and still readable.
    try std.testing.expect(cache.peek(held, now + 2) != null);
    try std.testing.expectEqual(@as(usize, 40), cache.used());

    // The same insert succeeds once the pin is released, because the entry is
    // now evictable.
    cache.unpin(held);
    const accepted = try std.testing.allocator.dupe(u8, &body);
    try cache.put(AssetKey.init(.embedded, "accepted"), accepted, now + 3);

    try std.testing.expect(cache.peek(held, now + 4) == null);
    try std.testing.expectEqual(@as(usize, 80), cache.used());
}

test "api-w14 byte-budget eviction drops the least recently used entry first" {
    var tio = TestIo.init();
    defer tio.deinit();
    const io = tio.io;

    var cache = assets.AssetCache.init(std.testing.allocator, io, 100);
    defer cache.deinit();

    const now: i96 = 2000;
    const oldest = AssetKey.init(.embedded, "oldest");
    const middle = AssetKey.init(.embedded, "middle");
    const newest = AssetKey.init(.embedded, "newest");

    const first = try std.testing.allocator.dupe(u8, "12345678901234567890"); // 20
    try cache.put(oldest, first, now);
    const second = try std.testing.allocator.dupe(u8, "12345678901234567890"); // 20
    try cache.put(middle, second, now + 10);

    // Touching the oldest entry makes the middle one the eviction candidate.
    _ = cache.peek(oldest, now + 20);

    var large: [70]u8 = undefined;
    @memset(&large, 'L');
    const third = try std.testing.allocator.dupe(u8, &large);
    try cache.put(newest, third, now + 30);

    try std.testing.expect(cache.peek(middle, now + 40) == null);
    try std.testing.expect(cache.peek(oldest, now + 40) != null);
    try std.testing.expect(cache.peek(newest, now + 40) != null);
    try std.testing.expectEqual(@as(usize, 90), cache.used());
}
