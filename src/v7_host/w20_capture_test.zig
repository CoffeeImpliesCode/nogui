//! Deterministic lifecycle tests for W20 screen capture.
//!
//! Every test drives the host facade through a provider that does no I/O, so
//! no portal dialog, display server or PipeWire daemon is involved. What is
//! checked is the behaviour a user can observe: a canceled chooser leaves no
//! stream, a stopped session delivers nothing more, a lost provider releases
//! every buffer, a format change never mixes two layouts, and a dead owner
//! lets go of the session.
const std = @import("std");
const capture = @import("capture.zig");
const pipewire = @import("linux/capture_pipewire.zig");

const Session = capture.Session;
const SessionState = capture.SessionState;
const FailureReason = capture.FailureReason;
const PixelFormat = capture.PixelFormat;
const ColorRange = capture.ColorRange;
const FrameDescriptor = capture.FrameDescriptor;
const Request = capture.Request;
const prop_header_bytes = pipewire.prop_header_bytes;

const TestOwner = struct {
    alive: bool = true,

    fn isAlive(ctx: *const anyopaque) bool {
        const self: *const TestOwner = @ptrCast(@alignCast(ctx));
        return self.alive;
    }
};

/// Counts how many producer buffers are alive, so a test can prove that every
/// frame the provider produced was handed back. `storage` is the memory the
/// fake producer maps its frames onto, so `pixels` names real bytes.
const Counters = struct {
    live: usize = 0,
    released: usize = 0,
    storage: [512]u8 = [_]u8{0} ** 512,
    next_slot: usize = 0,

    /// The byte size one fake frame occupies in `storage`.
    const frame_bytes = 64;
};

fn releaseCounter(ctx: ?*anyopaque) void {
    const counters: *Counters = @ptrCast(@alignCast(ctx.?));
    counters.live -= 1;
    counters.released += 1;
}

/// A frame shaped exactly like a capture frame: the payload is named by
/// `pixels`, `user_data` carries a caller tag, and releasing hands the
/// producer buffer back.
fn makeFrame(counters: *Counters, tag: u32) FrameDescriptor {
    const slots = counters.storage.len / Counters.frame_bytes;
    const slot = counters.next_slot % slots;
    counters.next_slot += 1;
    counters.storage[slot * Counters.frame_bytes] = @truncate(tag);
    counters.live += 1;

    var frame: FrameDescriptor = .{
        .width = 4,
        .height = 4,
        .format = .bgra8,
        .stride = 16,
        .pixels = counters.storage[slot * Counters.frame_bytes ..].ptr,
        .user_data = tag,
        .release_fn = releaseCounter,
        .release_ctx = counters,
    };
    frame.planes[0] = .{
        .offset = 0,
        .stride = 16,
        .width = 4,
        .height = 4,
        .size = Counters.frame_bytes,
    };
    return frame;
}

/// A provider that reports exactly what a test tells it to report.
const MockProvider = struct {
    sink: capture.Sink,
    counters: *Counters,
    begin_calls: usize = 0,
    stop_calls: usize = 0,
    /// Frames still held by the consumer when the provider was torn down.
    frames_live_at_stop: usize = 0,
    begin_error: ?anyerror = null,
    on_begin: ?*const fn (*MockProvider) void = null,
    last_request: Request = .{},

    fn init(sink: capture.Sink, counters: *Counters) MockProvider {
        return .{ .sink = sink, .counters = counters };
    }

    fn backend(self: *MockProvider) capture.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: capture.Backend.VTable = .{
        .begin = beginImpl,
        .stop = stopImpl,
    };

    fn beginImpl(ctx: *anyopaque, request: Request) anyerror!void {
        const self: *MockProvider = @ptrCast(@alignCast(ctx));
        self.last_request = request;
        self.begin_calls += 1;
        if (self.begin_error) |err| return err;
        if (self.on_begin) |hook| hook(self);
    }

    fn stopImpl(ctx: *anyopaque) void {
        const self: *MockProvider = @ptrCast(@alignCast(ctx));
        self.stop_calls += 1;
        self.frames_live_at_stop = self.counters.live;
    }

    /// Pushes a frame the way a PipeWire thread would.
    fn deliver(self: *MockProvider, counters: *Counters, tag: u32) void {
        self.sink.frame(self.sink.ctx, makeFrame(counters, tag));
    }

    fn reportState(self: *MockProvider, state: SessionState, failure: FailureReason) void {
        self.sink.state(self.sink.ctx, state, failure);
    }

    fn reportFormat(self: *MockProvider, info: capture.StreamInfo) void {
        self.sink.format(self.sink.ctx, info);
    }
};

/// A provider whose frames only move when it is asked for them, which is the
/// shape a platform with a frame pool and no producer thread has. Nothing here
/// runs on a thread of its own, so every frame the consumer ever sees is one
/// the session asked for.
const PollProvider = struct {
    sink: capture.Sink,
    counters: *Counters,
    /// Frames one drive hands over. Zero is the ordinary moment between frames.
    frames_per_drive: usize = 0,
    drive_calls: usize = 0,
    /// The timeout the session last drove with, so a test can say whether the
    /// consumer was ever made to wait for a frame.
    last_timeout_ms: i32 = -1,
    /// What the transport fails with, which models a transport that died.
    drive_error: ?anyerror = null,

    fn init(sink: capture.Sink, counters: *Counters) PollProvider {
        return .{ .sink = sink, .counters = counters };
    }

    fn backend(self: *PollProvider) capture.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: capture.Backend.VTable = .{
        .begin = beginImpl,
        .stop = stopImpl,
        .poll = pollImpl,
    };

    fn beginImpl(ctx: *anyopaque, request: capture.Request) anyerror!void {
        _ = request;
        const self: *PollProvider = @ptrCast(@alignCast(ctx));
        self.sink.state(self.sink.ctx, .selecting, .none);
        self.sink.state(self.sink.ctx, .starting, .none);
        self.sink.state(self.sink.ctx, .streaming, .none);
    }

    fn stopImpl(ctx: *anyopaque) void {
        const self: *PollProvider = @ptrCast(@alignCast(ctx));
        self.sink.state(self.sink.ctx, .stopped, .none);
    }

    fn pollImpl(ctx: *anyopaque, timeout_ms: i32) anyerror!usize {
        const self: *PollProvider = @ptrCast(@alignCast(ctx));
        self.drive_calls += 1;
        self.last_timeout_ms = timeout_ms;
        if (self.drive_error) |err| return err;
        for (0..self.frames_per_drive) |index| {
            const tag: u32 = @intCast(self.drive_calls * 100 + index);
            self.sink.frame(self.sink.ctx, makeFrame(self.counters, tag));
        }
        return self.frames_per_drive;
    }
};

test "api-w20 a canceled chooser leaves the session without a stream" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());

    provider.on_begin = struct {
        fn run(p: *MockProvider) void {
            p.reportState(.canceled, .none);
        }
    }.run;
    try session.begin(.{ .sources = .monitor });

    try std.testing.expectEqual(SessionState.canceled, session.state());
    try std.testing.expectEqual(FailureReason.none, session.failure());
    try std.testing.expectEqual(@as(usize, 1), provider.begin_calls);
    try std.testing.expect(session.acquireLatest() == null);
}

test "api-w20 a refused chooser is reported as denied" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());

    provider.on_begin = struct {
        fn run(p: *MockProvider) void {
            p.reportState(.denied, .rejected);
        }
    }.run;

    try session.begin(.{ .sources = .window });

    try std.testing.expectEqual(SessionState.denied, session.state());
    try std.testing.expectEqual(FailureReason.rejected, session.failure());
    try std.testing.expectEqual(@as(usize, 1), provider.begin_calls);
    try std.testing.expect(session.acquireLatest() == null);
}

test "api-w20 a second selection is refused while one is in flight" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());

    // The provider never answers, so the session stays in `selecting`.
    try session.begin(.{});
    try std.testing.expectEqual(SessionState.selecting, session.state());

    try std.testing.expectError(error.InvalidState, session.begin(.{}));
    try std.testing.expectEqual(@as(usize, 1), provider.begin_calls);

    // The refusal is about the second request only. The selection in flight
    // keeps its state, and the stream the first request opened still delivers.
    try std.testing.expectEqual(SessionState.selecting, session.state());
    try std.testing.expectEqual(FailureReason.none, session.failure());
    provider.reportState(.streaming, .none);
    provider.deliver(&counters, 1);
    var held = session.acquireLatest().?;
    session.releaseFrame(&held);
    try std.testing.expectEqual(@as(usize, 1), counters.released);
}

test "api-w20 a request with no provider records why it never started" {
    var owner: TestOwner = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    try std.testing.expectError(error.NoBackend, session.begin(.{}));

    // A caller that only polls the state has to learn the request failed,
    // rather than sit at `idle` waiting for a chooser nobody ever opened.
    try std.testing.expectEqual(SessionState.failed, session.state());
    try std.testing.expectEqual(FailureReason.unsupported, session.failure());
    try std.testing.expect(!session.isStreaming());
}

test "api-w20 a request from a dead owner records why it never started" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());
    owner.alive = false;
    try std.testing.expectError(error.OwnerLost, session.begin(.{}));

    try std.testing.expectEqual(@as(usize, 0), provider.begin_calls);
    try std.testing.expectEqual(SessionState.failed, session.state());
    try std.testing.expectEqual(FailureReason.disconnected, session.failure());
}

test "api-w20 a provider failure is reported and released when the owner stops" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());

    try session.begin(.{});
    provider.reportState(.streaming, .none);
    try std.testing.expectEqual(SessionState.streaming, session.state());
    try std.testing.expect(session.isStreaming());

    provider.deliver(&counters, 1);
    provider.deliver(&counters, 2);
    try std.testing.expectEqual(@as(usize, 2), counters.live);
    // The session bus or the PipeWire daemon went away mid-stream. The
    // callback runs on the provider's own thread, so it reports the failure
    // and leaves the teardown to the owner.
    provider.reportState(.failed, .disconnected);

    try std.testing.expectEqual(SessionState.failed, session.state());
    try std.testing.expectEqual(FailureReason.disconnected, session.failure());
    try std.testing.expect(session.needsTeardown());
    try std.testing.expectEqual(@as(usize, 0), provider.stop_calls);
    try std.testing.expectEqual(@as(usize, 2), counters.live);

    try std.testing.expectEqual(@as(u32, 0), session.stop());
    try std.testing.expect(!session.needsTeardown());
    try std.testing.expectEqual(@as(usize, 1), provider.stop_calls);
    try std.testing.expectEqual(@as(usize, 0), counters.live);
    try std.testing.expectEqual(@as(usize, 2), counters.released);
    try std.testing.expect(session.acquireLatest() == null);
}

test "api-w20 a stopped session delivers no further frame" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());

    try session.begin(.{});
    provider.reportState(.streaming, .none);
    provider.deliver(&counters, 7);
    try std.testing.expectEqual(@as(usize, 1), counters.live);

    try std.testing.expectEqual(@as(u32, 0), session.stop());
    try std.testing.expectEqual(SessionState.stopped, session.state());
    try std.testing.expect(!session.isStreaming());
    try std.testing.expectEqual(@as(usize, 0), counters.live);

    // A frame that raced with teardown must be released, never queued.
    provider.deliver(&counters, 8);
    try std.testing.expectEqual(@as(usize, 0), counters.live);
    try std.testing.expectEqual(@as(usize, 2), counters.released);
    try std.testing.expect(session.acquireLatest() == null);
}

test "api-w20 a frame arriving before the stream runs is released" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());

    try session.begin(.{});
    try std.testing.expectEqual(SessionState.selecting, session.state());

    provider.deliver(&counters, 1);
    try std.testing.expectEqual(@as(usize, 0), counters.live);
    try std.testing.expectEqual(@as(usize, 1), counters.released);
    try std.testing.expect(session.acquireLatest() == null);
}

test "api-w20 a format change raises the epoch and drops queued frames" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());

    try session.begin(.{});
    provider.reportState(.streaming, .none);
    provider.reportFormat(.{ .node_id = 42, .width = 1920, .height = 1080, .format = .bgra8 });
    try std.testing.expectEqual(@as(u32, 1), session.streamInfo().format_epoch);

    provider.deliver(&counters, 1);
    const presented = session.acquireLatest().?;
    try std.testing.expectEqual(@as(usize, 1), counters.live);
    session.presentFrame(presented);
    try std.testing.expectEqual(@as(u32, 0), session.outstandingFrames());

    // A second frame is queued, then the source changes resolution.
    provider.deliver(&counters, 2);
    try std.testing.expectEqual(@as(usize, 2), counters.live);
    provider.reportFormat(.{ .node_id = 42, .width = 1280, .height = 720, .format = .bgra8 });

    try std.testing.expectEqual(@as(u32, 2), session.streamInfo().format_epoch);
    try std.testing.expectEqual(@as(u32, 1280), session.streamInfo().width);
    // The stale queued frame is gone; the presented one still belongs to the
    // consumer until it is replaced.
    try std.testing.expectEqual(@as(usize, 1), counters.live);
    try std.testing.expect(session.acquireLatest() == null);

    provider.deliver(&counters, 3);
    const next = session.acquireLatest().?;
    session.presentFrame(next);
    try std.testing.expectEqual(@as(u32, 0), session.outstandingFrames());
    try std.testing.expectEqual(@as(usize, 1), counters.live);
    try std.testing.expectEqual(@as(usize, 2), counters.released);
}

test "api-w20 the same layout reported twice does not raise the epoch" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());

    try session.begin(.{});
    provider.reportState(.streaming, .none);
    const info: capture.StreamInfo = .{ .width = 1920, .height = 1080, .format = .bgra8 };
    provider.reportFormat(info);
    provider.reportFormat(info);
    try std.testing.expectEqual(@as(u32, 1), session.streamInfo().format_epoch);

    // Only a real layout change counts.
    provider.reportFormat(.{ .width = 1920, .height = 1080, .format = .rgba8 });
    try std.testing.expectEqual(@as(u32, 2), session.streamInfo().format_epoch);
}

test "api-w20 backpressure keeps the newest frame and releases the stale ones" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());

    try session.begin(.{});
    provider.reportState(.streaming, .none);

    provider.deliver(&counters, 1);
    provider.deliver(&counters, 2);
    provider.deliver(&counters, 3);
    try std.testing.expectEqual(@as(usize, 2), counters.live);
    try std.testing.expectEqual(@as(usize, 1), counters.released);

    var newest = session.acquireLatest().?;
    try std.testing.expectEqual(@as(usize, 3), newest.user_data);
    try std.testing.expectEqual(@as(usize, 1), counters.live);
    try std.testing.expectEqual(@as(u32, 1), session.outstandingFrames());

    session.releaseFrame(&newest);
    try std.testing.expectEqual(@as(u32, 0), session.outstandingFrames());
    try std.testing.expectEqual(@as(usize, 0), counters.live);
    try std.testing.expectEqual(@as(usize, 3), counters.released);
}

test "api-w20 a dead weak owner stops the session and releases the provider" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());

    try session.begin(.{});
    provider.reportState(.streaming, .none);
    provider.deliver(&counters, 1);
    try std.testing.expectEqual(@as(usize, 1), counters.live);

    owner.alive = false;
    session.enforceOwnerLifetime();

    try std.testing.expectEqual(SessionState.stopped, session.state());
    try std.testing.expectEqual(@as(usize, 1), provider.stop_calls);
    try std.testing.expectEqual(@as(usize, 0), counters.live);

    // The provider is gone, so a late frame cannot be queued anywhere.
    provider.deliver(&counters, 2);
    try std.testing.expectEqual(@as(usize, 0), counters.live);
    try std.testing.expectEqual(@as(usize, 2), counters.released);
}

test "api-w20 a live owner leaves a running session alone" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());

    try session.begin(.{});
    provider.reportState(.streaming, .none);
    provider.deliver(&counters, 1);

    session.enforceOwnerLifetime();
    try std.testing.expectEqual(SessionState.streaming, session.state());
    try std.testing.expectEqual(@as(usize, 0), provider.stop_calls);
    try std.testing.expectEqual(@as(usize, 1), counters.live);
}

test "api-w20 a terminal producer callback defers teardown until owner stops" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};
    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());
    try session.begin(.{});
    provider.reportState(.streaming, .none);
    provider.deliver(&counters, 1);

    provider.reportState(.failed, .disconnected);
    try std.testing.expectEqual(SessionState.failed, session.state());
    try std.testing.expectEqual(FailureReason.disconnected, session.failure());
    try std.testing.expectEqual(@as(usize, 0), provider.stop_calls);
    try std.testing.expectEqual(@as(usize, 1), counters.live);

    try std.testing.expectEqual(@as(u32, 0), session.stop());
    try std.testing.expectEqual(@as(usize, 1), provider.stop_calls);
    try std.testing.expectEqual(@as(usize, 0), provider.frames_live_at_stop);
    try std.testing.expectEqual(@as(usize, 0), counters.live);
    try std.testing.expectEqual(@as(usize, 1), counters.released);
    try std.testing.expectEqual(@as(u32, 0), session.stop());
    try std.testing.expectEqual(@as(usize, 1), provider.stop_calls);
}

test "api-w20 the provider is torn down only after its frames are released" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());

    try session.begin(.{});
    provider.reportState(.streaming, .none);
    provider.deliver(&counters, 1);
    provider.deliver(&counters, 2);
    const presented = session.acquireLatest().?;
    session.presentFrame(presented);
    try std.testing.expectEqual(@as(usize, 1), counters.live);
    try std.testing.expectEqual(@as(u32, 0), session.outstandingFrames());

    try std.testing.expectEqual(@as(u32, 0), session.stop());

    // Releasing a frame hands a buffer back to the producer, so the producer
    // must already be gone by then, never still holding a dead pointer.
    try std.testing.expectEqual(@as(usize, 0), provider.frames_live_at_stop);
    try std.testing.expectEqual(@as(usize, 0), counters.live);
}

test "api-w20 a held frame refuses destruction and the retry frees it" {
    // The hazard: a consumer keeps a frame, the owner tears the session down,
    // and the frame comes back afterwards. That return walks the session's
    // queue and the provider behind it, so the teardown is refused instead of
    // freeing memory the frame still names.
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());
    try session.begin(.{});
    provider.reportState(.streaming, .none);
    provider.deliver(&counters, 1);
    var held = session.acquireLatest().?;
    try std.testing.expectEqual(@as(u32, 1), session.outstandingFrames());

    try std.testing.expectError(error.FramesStillBorrowed, session.deinit());
    // The refusal consumes nothing: the session still answers, the provider is
    // already stopped so it hands out nothing new, and the frame is still the
    // consumer's to return.
    try std.testing.expectEqual(SessionState.stopped, session.state());
    try std.testing.expectEqual(@as(u32, 1), session.outstandingFrames());
    try std.testing.expectEqual(@as(usize, 1), provider.stop_calls);
    try std.testing.expectEqual(@as(usize, 1), counters.live);
    try std.testing.expectEqual(@as(usize, 0), counters.released);
    try std.testing.expectEqual(@as(u32, 1), session.stop());
    try std.testing.expectError(error.FramesStillBorrowed, session.deinit());

    session.releaseFrame(&held);
    try std.testing.expectEqual(@as(usize, 1), counters.released);
    try std.testing.expectEqual(@as(u32, 0), session.outstandingFrames());

    // The retry succeeds and releases the provider exactly once, because the
    // refused call already stopped it.
    try session.deinit();
    try std.testing.expectEqual(@as(usize, 1), provider.stop_calls);
    try std.testing.expectEqual(@as(usize, 1), counters.released);
}

test "api-w20 a frame source refuses destruction while a frame is out" {
    // The same hazard one level down. A returned error rather than an assert,
    // because an assert is compiled out of a ReleaseFast build, which is
    // exactly where a freed queue would be released into.
    var source = capture.FrameSource.init(std.testing.allocator, std.testing.io, 2);
    var counters: Counters = .{};

    try source.pushFrame(makeFrame(&counters, 1));
    var held = source.acquireLatest().?;
    try std.testing.expectEqual(@as(u32, 1), source.outstandingFrames());

    try std.testing.expectError(error.FramesStillBorrowed, source.deinit());
    try std.testing.expectEqual(@as(usize, 1), counters.live);
    try std.testing.expectEqual(@as(usize, 0), counters.released);

    source.releaseFrame(&held);
    try std.testing.expectEqual(@as(usize, 1), counters.released);
    try source.deinit();
}

test "api-w20 stopping twice releases the provider only once" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());

    try session.begin(.{});
    provider.reportState(.streaming, .none);
    try std.testing.expectEqual(@as(u32, 0), session.stop());
    try std.testing.expectEqual(@as(u32, 0), session.stop());

    try std.testing.expectEqual(@as(usize, 1), provider.stop_calls);
}

test "api-w20 a request after a terminal outcome keeps that outcome" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());
    try session.begin(.{});
    provider.reportState(.denied, .rejected);

    // The platform already gave the reason. A second request that cannot start
    // says nothing truer than that, so it is refused without touching it.
    try std.testing.expectError(error.InvalidState, session.begin(.{}));
    try std.testing.expectEqual(@as(usize, 1), provider.begin_calls);
    try std.testing.expectEqual(SessionState.denied, session.state());
    try std.testing.expectEqual(FailureReason.rejected, session.failure());
}

test "api-w20 a terminal outcome survives a later provider report" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());

    try session.begin(.{});
    provider.reportState(.canceled, .none);
    provider.reportState(.streaming, .none);
    provider.reportState(.failed, .disconnected);

    try std.testing.expectEqual(SessionState.canceled, session.state());
    try std.testing.expectEqual(FailureReason.none, session.failure());
}

test "api-w20 a failed selection records the reason it failed" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());
    provider.begin_error = error.NoSessionBus;

    try std.testing.expectError(error.NoSessionBus, session.begin(.{}));
    try std.testing.expectEqual(SessionState.failed, session.state());
    try std.testing.expectEqual(FailureReason.no_session_bus, session.failure());
}

test "api-w20 a missing PipeWire reads as a disconnected provider" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());
    provider.begin_error = error.PipeWireMissing;

    try std.testing.expectError(error.PipeWireMissing, session.begin(.{}));
    try std.testing.expectEqual(FailureReason.disconnected, session.failure());
}

test "api-w20 a portal that refuses the call reads as an unavailable portal" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());
    provider.begin_error = error.PortalCallFailed;

    try std.testing.expectError(error.PortalCallFailed, session.begin(.{}));
    try std.testing.expectEqual(SessionState.failed, session.state());
    try std.testing.expectEqual(FailureReason.portal_unavailable, session.failure());
}

test "api-w20 every shipped provider error name maps to its own reason" {
    // The names are the ones the providers and their transports return. A
    // mapping that misses one leaves a caller polling the state with a reason
    // nobody can act on, so the table is spelled out rather than sampled.
    const cases = [_]struct { err: anyerror, reason: FailureReason }{
        // A chooser the user closed is not a failure, and one the user refused
        // is a rejection, whatever else the handshake reported.
        .{ .err = error.CaptureCanceled, .reason = .none },
        .{ .err = error.CaptureDenied, .reason = .rejected },
        .{ .err = error.MultipleStreamsUnsupported, .reason = .rejected },
        .{ .err = error.CaptureUnsupported, .reason = .unsupported },
        .{ .err = error.UnsupportedSources, .reason = .unsupported },
        .{ .err = error.UnsupportedCursorMode, .reason = .unsupported },
        .{ .err = error.NoSessionBus, .reason = .no_session_bus },
        .{ .err = error.PortalUnavailable, .reason = .portal_unavailable },
        .{ .err = error.PortalCallFailed, .reason = .portal_unavailable },
        .{ .err = error.InvalidReply, .reason = .portal_unavailable },
        .{ .err = error.NoFileDescriptor, .reason = .portal_unavailable },
        .{ .err = error.StreamDisconnected, .reason = .disconnected },
        .{ .err = error.ConnectionClosed, .reason = .disconnected },
        .{ .err = error.NotConnected, .reason = .disconnected },
        .{ .err = error.ReadFailed, .reason = .disconnected },
        .{ .err = error.PipeWireMissing, .reason = .disconnected },
        .{ .err = error.PipeWireIncomplete, .reason = .disconnected },
        .{ .err = error.StreamConnectFailed, .reason = .disconnected },
        .{ .err = error.OwnerLost, .reason = .disconnected },
        .{ .err = error.FormatUnsupported, .reason = .format_unsupported },
        .{ .err = error.PortalNoStream, .reason = .provider_failed },
        .{ .err = error.PortalInvalidReply, .reason = .provider_failed },
        .{ .err = error.CaptureFailed, .reason = .provider_failed },
        .{ .err = error.MalformedParentWindow, .reason = .provider_failed },
        .{ .err = error.FramesStillBorrowed, .reason = .provider_failed },
        .{ .err = error.OutOfMemory, .reason = .io_failed },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.reason, capture.classifyFailure(case.err));
    }
}

test "api-w20 source and mode sets carry the portal wire values" {
    try std.testing.expectEqual(@as(u32, 1), capture.SourceType.monitor.bits);
    try std.testing.expectEqual(@as(u32, 2), capture.SourceType.window.bits);
    try std.testing.expectEqual(@as(u32, 4), capture.SourceType.virtual.bits);

    const both = capture.SourceType.monitor.with(.window);
    try std.testing.expect(both.has(.monitor));
    try std.testing.expect(both.has(.window));
    try std.testing.expect(!both.has(.virtual));
    try std.testing.expect(capture.SourceType.none.isEmpty());

    const modes = capture.CursorModes.embedded.with(.hidden);
    try std.testing.expect(modes.supports(.embedded));
    try std.testing.expect(modes.supports(.hidden));
    try std.testing.expect(!modes.supports(.metadata));

    const levels = capture.PersistenceModes.while_connected;
    try std.testing.expect(levels.supports(.while_connected));
    try std.testing.expect(!levels.supports(.until_revoked));

    // The portal spells the cursor and persistence levels as plain integers.
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(capture.CursorMode.embedded));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(capture.CursorMode.metadata));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(capture.PersistenceMode.until_revoked));
}

test "api-w20 only active states may still change and terminal states may not" {
    try std.testing.expect(!capture.isTerminal(.idle));
    try std.testing.expect(!capture.isTerminal(.selecting));
    try std.testing.expect(!capture.isTerminal(.starting));
    try std.testing.expect(!capture.isTerminal(.streaming));
    try std.testing.expect(capture.isTerminal(.canceled));
    try std.testing.expect(capture.isTerminal(.denied));
    try std.testing.expect(capture.isTerminal(.stopped));
    try std.testing.expect(capture.isTerminal(.failed));

    try std.testing.expect(capture.isActive(.selecting));
    try std.testing.expect(capture.isActive(.streaming));
    try std.testing.expect(!capture.isActive(.stopped));
    try std.testing.expect(!capture.isActive(.idle));
}

test "api-w20 a delivered frame names its own pixels and gives the buffer back once" {
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());

    try session.begin(.{});
    provider.reportState(.streaming, .none);
    provider.reportFormat(.{ .width = 4, .height = 4, .format = .bgra8 });
    provider.deliver(&counters, 0x5a);

    var frame = session.acquireLatest() orelse return error.NoFrame;
    // The payload is named by the descriptor, not hidden in a private field,
    // so a consumer can reach the bytes without knowing the producer.
    try std.testing.expect(frame.pixels != null);
    try std.testing.expectEqual(@as(u8, 0x5a), frame.pixels.?[0]);
    const payload = pipewire.payloadOf(frame).?;
    try std.testing.expectEqual(@intFromPtr(frame.pixels.?), @intFromPtr(payload.base));
    try std.testing.expect(payload.len > 0);
    try std.testing.expectEqual(frame.planes[0].size, payload.len);
    // The consumer tag is still available and is not the payload pointer.
    try std.testing.expectEqual(@as(usize, 0x5a), frame.user_data);

    // Releasing hands the producer buffer back exactly once, and returns the
    // frame to the source's account so it is no longer waiting for it.
    try std.testing.expectEqual(@as(u32, 1), session.outstandingFrames());
    session.releaseFrame(&frame);
    try std.testing.expectEqual(@as(u32, 0), session.outstandingFrames());
    try std.testing.expectEqual(@as(usize, 0), counters.live);
    try std.testing.expectEqual(@as(usize, 1), counters.released);
    try std.testing.expect(frame.release_fn == null);
    frame.release();
    try std.testing.expectEqual(@as(usize, 1), counters.released);
}

test "api-w20 a held frame keeps its producer alive until it comes back" {
    // The exact hazard: a consumer acquires a frame, the session stops, and
    // the consumer releases the frame afterwards. The release returns a buffer
    // into a producer, so the producer must not be destroyed in between.
    var life = pipewire.SharedLifetime.init;
    life.begin();
    life.hold();

    // The producer asks to go away while the frame is still out.
    try std.testing.expect(!life.requestTeardown());
    try std.testing.expect(!life.mayDestroy());

    // The frame comes back, and only now may the producer be destroyed.
    try std.testing.expect(life.drop());
    try std.testing.expect(life.mayDestroy());
    life.destroyOnce();
    try std.testing.expect(!life.mayDestroy());

    // A second release must not destroy anything twice.
    life.destroyOnce();
    try std.testing.expect(life.destroyed);
}

test "api-w20 a producer with no outstanding frame is destroyed at once" {
    var life = pipewire.SharedLifetime.init;
    life.begin();
    try std.testing.expect(life.requestTeardown());
    try std.testing.expect(life.mayDestroy());
    life.destroyOnce();
    try std.testing.expect(life.destroyed);
}

test "api-w20 a frame returned before teardown does not free the producer" {
    var life = pipewire.SharedLifetime.init;
    life.begin();
    life.hold();
    try std.testing.expect(!life.drop());
    try std.testing.expect(!life.mayDestroy());
    try std.testing.expect(life.requestTeardown());
    life.destroyOnce();
    try std.testing.expect(life.destroyed);
}

test "api-w20 several held frames keep the producer alive until the last returns" {
    var life = pipewire.SharedLifetime.init;
    life.begin();
    life.hold();
    life.hold();
    try std.testing.expect(!life.requestTeardown());

    // The first two returns leave the last frame outstanding.
    try std.testing.expect(!life.drop());
    try std.testing.expect(!life.mayDestroy());
    try std.testing.expect(life.drop());
    try std.testing.expect(life.mayDestroy());
    life.destroyOnce();
    try std.testing.expect(life.destroyed);
}

test "api-w20 a release thread never destroys the transport, the owner does" {
    // A consumer can release a frame on any thread, including a PipeWire
    // callback thread that refuses a frame. Stopping a thread loop from such
    // a thread deadlocks, so a release may only account. The owner thread
    // destroys the transport, and only once.
    var owner: TestOwner = .{};
    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        1,
    );
    defer session.deinit() catch unreachable;

    var destroys: u32 = 0;
    const Hook = struct {
        fn run(context: ?*anyopaque) void {
            const count: *u32 = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
    };
    var stream = pipewire.Stream.init(
        std.testing.allocator,
        std.testing.io,
        // No PipeWire object exists here, so the entry-point table is never
        // read; only the lifetime accounting is exercised.
        undefined,
        session.sink(),
    );
    stream.lifetime.begin();
    stream.lifetime.destroy_hook = Hook.run;
    stream.lifetime.hook_ctx = &destroys;
    stream.lifetime.hold();

    // The producer asks to go away while a frame is still out.
    stream.mutex.lockUncancelable(std.testing.io);
    try std.testing.expect(!stream.lifetime.requestTeardown());
    stream.mutex.unlock(std.testing.io);
    stream.destroyIfReady();
    try std.testing.expectEqual(@as(u32, 0), destroys);
    try std.testing.expectEqual(@as(u32, 1), stream.outstandingFrames());

    // The frame comes back on the releasing thread, which still only counts.
    // The release is accepted, because the producer was holding that frame and
    // it was the last one, so the destroy hook is now free to run — and it
    // still has not run here.
    try std.testing.expect(stream.dropFrame());
    try std.testing.expectEqual(@as(u32, 0), stream.outstandingFrames());
    try std.testing.expectEqual(@as(u32, 0), destroys);

    // The owner thread destroys it, exactly once.
    stream.destroyIfReady();
    stream.destroyIfReady();
    try std.testing.expectEqual(@as(u32, 1), destroys);
}

test "api-w20 returning a frame keeps the source account at zero" {
    // The two counters have to agree or any teardown check against the source
    // count fails permanently on the capture path. A frame that comes back
    // through `releaseFrame` must not leave the source waiting for it.
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = MockProvider.init(session.sink(), &counters);
    session.attach(provider.backend());

    try session.begin(.{});
    provider.reportState(.streaming, .none);

    // Three rounds of acquire and return must end at zero every time, not
    // accumulate one stuck count per round.
    var round: u32 = 0;
    while (round < 3) : (round += 1) {
        provider.deliver(&counters, round);
        try std.testing.expectEqual(@as(u32, 0), session.outstandingFrames());

        var held = session.acquireLatest().?;
        try std.testing.expectEqual(@as(u32, 1), session.outstandingFrames());

        session.releaseFrame(&held);
        try std.testing.expectEqual(@as(u32, 0), session.outstandingFrames());
    }

    // Presenting a frame also returns it to the source's account.
    provider.deliver(&counters, 7);
    const presented = session.acquireLatest().?;
    try std.testing.expectEqual(@as(u32, 1), session.outstandingFrames());
    session.presentFrame(presented);
    try std.testing.expectEqual(@as(u32, 0), session.outstandingFrames());

    // So the source has nothing outstanding when teardown runs.
    try std.testing.expectEqual(@as(u32, 0), session.stop());
}

test "api-w20 a frame without pixels reports no payload" {
    const bare: FrameDescriptor = .{
        .width = 4,
        .height = 4,
        .format = .bgra8,
        .stride = 16,
    };
    try std.testing.expect(pipewire.payloadOf(bare) == null);

    // A descriptor that names a buffer but no planes is still not readable,
    // because the length would be a guess.
    const no_planes: FrameDescriptor = .{
        .width = 4,
        .height = 4,
        .format = .bgra8,
        .stride = 16,
        .pixels = @ptrCast(&[_]u8{ 1, 2, 3, 4 }),
        .plane_count = 0,
    };
    try std.testing.expect(pipewire.payloadOf(no_planes) == null);
}

// -- PipeWire format negotiation ---------------------------------------------

/// Builds a `Format` object pod the way PipeWire sends one back, so the
/// reader is exercised against the same wire layout it meets at runtime.
const TestPod = struct {
    // `put` writes every byte that `len` covers before the reader takes the
    // pod, so the zeroed tail beyond `len` is never part of the message.
    bytes: [256]u8 = [_]u8{0} ** 256,
    len: usize = 0,

    fn put(self: *TestPod, value: u32) void {
        std.mem.writeInt(u32, self.bytes[self.len..][0..4], value, .little);
        self.len += 4;
    }

    fn pad(self: *TestPod) void {
        const remainder = self.len % pipewire.pod_align;
        if (remainder != 0) self.len += pipewire.pod_align - remainder;
    }

    fn putProp(self: *TestPod, key: u32, value_type: u32, value_size: u32) void {
        self.put(key);
        self.put(0);
        self.put(value_size);
        self.put(value_type);
    }

    fn putIdProp(self: *TestPod, key: u32, value: u32) void {
        self.putProp(key, pipewire.spa_type_id, 4);
        self.put(value);
        self.pad();
    }

    fn putRectangleProp(self: *TestPod, key: u32, width: u32, height: u32) void {
        self.putProp(key, pipewire.spa_type_rectangle, 8);
        self.put(width);
        self.put(height);
        self.pad();
    }

    fn putFractionProp(self: *TestPod, key: u32, num: u32, denom: u32) void {
        self.putProp(key, pipewire.spa_type_fraction, 8);
        self.put(num);
        self.put(denom);
        self.pad();
    }
};

fn buildFormatPod(media_type: u32, format: u32, width: u32, height: u32, color_range: u32) TestPod {
    var pod: TestPod = .{};

    const body_len: usize = 2 * @sizeOf(u32) +
        prop_header_bytes + 4 + // format, an Id
        prop_header_bytes + 8 + // size, a Rectangle
        prop_header_bytes + 8 + // framerate, a Fraction
        prop_header_bytes + 4; // colorRange, an Id

    pod.put(@intCast(body_len));
    pod.put(pipewire.spa_type_object);
    pod.put(pipewire.spa_type_object_format);
    pod.put(pipewire.spa_param_enum_format);
    pod.putIdProp(pipewire.spa_format_media_type, media_type);
    pod.putIdProp(pipewire.spa_format_media_subtype, pipewire.spa_media_subtype_raw);
    pod.putIdProp(pipewire.spa_format_video_format, format);
    pod.putRectangleProp(pipewire.spa_format_video_size, width, height);
    // spa fractions are num/denom frames per second, so 60/1 is 60 fps.
    pod.putFractionProp(pipewire.spa_format_video_framerate, 60, 1);
    pod.putIdProp(pipewire.spa_format_video_color_range, color_range);
    return pod;
}

test "api-w20 a negotiated format pod reports size, rate and colour metadata" {
    const pod = buildFormatPod(
        pipewire.spa_media_type_video,
        pipewire.spa_video_format_bgra,
        1920,
        1080,
        pipewire.spa_video_color_range_16_235,
    );
    const parsed = pipewire.parseFormatBytes(pod.bytes[0..pod.len]) orelse return error.ParseFailed;

    try std.testing.expectEqual(pipewire.spa_video_format_bgra, parsed.format);
    try std.testing.expectEqual(@as(u32, 1920), parsed.width);
    try std.testing.expectEqual(@as(u32, 1080), parsed.height);
    try std.testing.expectEqual(@as(u32, 60), parsed.framerate_num);
    try std.testing.expectEqual(@as(u32, 1), parsed.framerate_denom);
    try std.testing.expectEqual(pipewire.spa_video_color_range_16_235, parsed.color_range);
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s / 60), parsed.frameIntervalNs());
    try std.testing.expectEqual(ColorRange.limited, pipewire.colorRangeOf(parsed.color_range));
    try std.testing.expectEqual(PixelFormat.bgra8, pipewire.pixelFormatOf(parsed.format).?);
}

test "api-w20 an unknown rate does not pretend to know the frame interval" {
    const pod = buildFormatPod(
        pipewire.spa_media_type_video,
        pipewire.spa_video_format_bgra,
        640,
        480,
        pipewire.spa_video_color_range_0_255,
    );
    const parsed = pipewire.parseFormatBytes(pod.bytes[0..pod.len]).?;
    // The pod carries a rate, so the interval is known.
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s / 60), parsed.frameIntervalNs());

    var no_rate = parsed;
    no_rate.framerate_num = 0;
    try std.testing.expectEqual(@as(u64, 0), no_rate.frameIntervalNs());
    try std.testing.expectEqual(ColorRange.full, pipewire.colorRangeOf(no_rate.color_range));
}

test "api-w20 a planar format is refused instead of being described wrongly" {
    // A single mapped buffer does not carry per-plane offsets, so a planar
    // layout must be reported as unsupported rather than guessed at.
    try std.testing.expect(pipewire.pixelFormatOf(pipewire.spa_video_format_i420) == null);
    try std.testing.expect(pipewire.pixelFormatOf(pipewire.spa_video_format_nv12) == null);
    try std.testing.expect(pipewire.pixelFormatOf(pipewire.spa_video_format_unknown) == null);

    // A truncated or foreign pod is not a format at all.
    const garbage = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try std.testing.expect(pipewire.parseFormatBytes(&garbage) == null);
    const truncated_pod = buildFormatPod(pipewire.spa_media_type_video, pipewire.spa_video_format_bgra, 8, 8, 0);
    const head_only = truncated_pod.bytes[0..12];
    try std.testing.expect(pipewire.parseFormatBytes(head_only) == null);

    // A pod of the right shape that describes audio is not a video format.
    const audio = buildFormatPod(1, pipewire.spa_video_format_bgra, 8, 8, 0);
    try std.testing.expect(pipewire.parseFormatBytes(audio.bytes[0..audio.len]) == null);
}

test "api-w20 the connect parameter advertises only describable formats" {
    const param = pipewire.buildFormatParam();
    const bytes = param.slice();
    const head: *const pipewire.Pod = @ptrCast(@alignCast(bytes.ptr));
    try std.testing.expectEqual(pipewire.spa_type_object, head.type);
    try std.testing.expect(pipewire.isFormatObject(bytes, pipewire.spa_param_enum_format));
    // The declared body must match what was written, or the peer reads past it.
    try std.testing.expectEqual(bytes.len, @sizeOf(pipewire.Pod) + head.size);

    const properties: pipewire.ObjectProperties = .{ .bytes = bytes };
    try std.testing.expectEqual(
        pipewire.spa_media_type_video,
        properties.find(pipewire.spa_format_media_type).?.asId().?,
    );
    try std.testing.expectEqual(
        pipewire.spa_media_subtype_raw,
        properties.find(pipewire.spa_format_media_subtype).?.asId().?,
    );

    // The format is offered as a choice, not pinned, so the session may pick
    // any layout this build can hand to the renderer.
    const choice = properties.find(pipewire.spa_format_video_format).?;
    try std.testing.expectEqual(pipewire.spa_type_choice, choice.type);
    try std.testing.expect(choice.asId() == null);
    try std.testing.expect(choice.data.len >= 16 + 4 * pipewire.requested_formats.len);
    for (0..pipewire.requested_formats.len) |index| {
        const offset = 16 + 4 * index;
        const format = std.mem.readInt(u32, choice.data[offset..][0..4], .little);
        try std.testing.expect(pipewire.pixelFormatOf(format) != null);
    }
}

test "api-w20 a transport that only moves when it is asked delivers through the session" {
    // The documented flow is attach, begin, acquire. A platform whose frames
    // move only when the host asks therefore delivers nothing at all unless the
    // session drives the provider, and a session that reports itself healthy
    // while it never delivers a frame is the worst answer there is: a black
    // screen with no error anywhere to explain it.
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = PollProvider.init(session.sink(), &counters);
    provider.frames_per_drive = 1;
    session.attach(provider.backend());
    try std.testing.expect(provider.backend().isPollDriven());

    try session.begin(.{ .sources = .monitor });
    try std.testing.expect(session.isStreaming());

    // Nothing has been produced, because nothing has been asked for.
    try std.testing.expectEqual(@as(usize, 0), provider.drive_calls);
    try std.testing.expectEqual(@as(usize, 0), counters.live);

    // Asking for the newest frame is what drives the transport, so the one
    // call a host already makes hands back a real frame. It does not wait for
    // one either: a consumer that asked is not made to block, so the drive
    // carries no timeout.
    var frame = session.acquireLatest();
    try std.testing.expect(frame != null);
    const first_tag = frame.?.user_data;
    try std.testing.expectEqual(@as(usize, 1), provider.drive_calls);
    try std.testing.expectEqual(@as(i32, 0), provider.last_timeout_ms);
    try std.testing.expectEqual(@as(usize, 1), counters.live);
    try std.testing.expectEqual(@as(u32, 1), session.outstandingFrames());

    // The lease is the consumer's and comes back through the session, which is
    // what lets the producer reuse the buffer. Releasing the descriptor
    // directly would hand the buffer back with the count still owed.
    session.releaseFrame(&frame.?);
    try std.testing.expectEqual(@as(usize, 1), counters.released);
    try std.testing.expectEqual(@as(usize, 0), counters.live);
    try std.testing.expectEqual(@as(u32, 0), session.outstandingFrames());

    // A second acquisition drives the transport again and hands back the newest
    // frame, not the one already returned: video is only worth the newest.
    provider.frames_per_drive = 2;
    var next = session.acquireLatest();
    try std.testing.expect(next != null);
    try std.testing.expectEqual(@as(usize, 2), provider.drive_calls);
    try std.testing.expect(next.?.user_data != first_tag);
    // Two were produced and the older was handed straight back as the newer
    // became the newest, so exactly one buffer is the consumer's and one has
    // already gone home.
    try std.testing.expectEqual(@as(usize, 2), counters.released);
    try std.testing.expectEqual(@as(usize, 1), counters.live);
    try std.testing.expectEqual(@as(u32, 1), session.outstandingFrames());
    session.releaseFrame(&next.?);
    try std.testing.expectEqual(@as(u32, 0), session.outstandingFrames());

    // A transport with nothing ready publishes nothing and leaves the session
    // streaming: an empty queue between frames is not a failure.
    provider.frames_per_drive = 0;
    try std.testing.expect(session.acquireLatest() == null);
    try std.testing.expect(session.isStreaming());
    try std.testing.expectEqual(@as(usize, 3), provider.drive_calls);
    try std.testing.expectEqual(FailureReason.none, session.failure());

    // Every produced buffer is back with the producer, and the teardown finds
    // no frame the consumer still holds.
    try std.testing.expectEqual(@as(u32, 0), session.stop());
    try std.testing.expectEqual(@as(usize, 3), counters.released);
    try std.testing.expectEqual(@as(usize, 0), counters.live);
}

test "api-w20 a transport that fails while it is driven ends the session by name" {
    // A transport that dies has to end the session the same way a provider
    // report does, with the shared mapping naming the reason. Swallowing it
    // leaves a session that reports itself healthy and never delivers, which is
    // the one failure a host cannot diagnose from its own state.
    var owner: TestOwner = .{};
    var counters: Counters = .{};

    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        2,
    );
    defer session.deinit() catch unreachable;

    var provider = PollProvider.init(session.sink(), &counters);
    provider.frames_per_drive = 1;
    session.attach(provider.backend());
    try session.begin(.{ .sources = .monitor });
    try std.testing.expect(session.isStreaming());

    provider.drive_error = error.StreamDisconnected;
    try std.testing.expect(session.acquireLatest() == null);
    try std.testing.expectEqual(SessionState.failed, session.state());
    try std.testing.expectEqual(FailureReason.disconnected, session.failure());

    // A transport that is gone is not asked again: the session is terminal, and
    // driving a dead provider once per frame is what turns one failure into a
    // busy loop.
    const calls = provider.drive_calls;
    try std.testing.expect(session.acquireLatest() == null);
    try std.testing.expectEqual(calls, provider.drive_calls);

    // The teardown still belongs to the owner thread, exactly as it does for a
    // provider that reported the failure itself.
    try std.testing.expect(session.needsTeardown());
    try std.testing.expectEqual(@as(u32, 0), session.stop());
    try std.testing.expect(!session.needsTeardown());
}

// -- Exact-once release -------------------------------------------------------

test "api-w20 a release the producer is not holding is refused, not counted" {
    // The count is the only authority on which frames a producer still owns,
    // and it is read from every thread that touches a frame. An assert is the
    // wrong guard for that: it is compiled out of a ReleaseFast build, and a
    // count taken below zero there wraps to the largest `usize` there is. The
    // transport would then wait on a frame that will never come back and would
    // never be destroyed, so a refused release has to be refused by the count
    // itself and reported to the caller.
    var life = pipewire.SharedLifetime.init;
    life.begin();

    try std.testing.expect(!life.drop());
    try std.testing.expectEqual(@as(usize, 0), life.outstanding());

    // A refused release leaves the teardown exactly where it was: it neither
    // re-opens a claimed one nor holds a pending one back.
    try std.testing.expect(life.requestTeardown());
    try std.testing.expect(life.claimDestroy());
    try std.testing.expect(!life.drop());
    try std.testing.expectEqual(@as(usize, 0), life.outstanding());
    try std.testing.expect(!life.claimDestroy());

    // Two frames in flight, each released once, is the whole of the contract.
    var fresh = pipewire.SharedLifetime.init;
    fresh.begin();
    fresh.hold();
    fresh.hold();
    try std.testing.expect(!fresh.drop());
    try std.testing.expectEqual(@as(usize, 1), fresh.outstanding());
    try std.testing.expect(!fresh.drop());
    try std.testing.expectEqual(@as(usize, 0), fresh.outstanding());
}

test "api-w20 a producer refuses a release it never handed out" {
    // The same refusal through the producer, so a caller learns whether the
    // frame was its own to give back. The count is what a teardown waits on,
    // so a release that moved it would either free a transport under a live
    // consumer or never free one at all.
    var owner: TestOwner = .{};
    var session = Session.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &owner, .is_alive_fn = TestOwner.isAlive },
        1,
    );
    defer session.deinit() catch unreachable;

    var stream = pipewire.Stream.init(
        std.testing.allocator,
        std.testing.io,
        // No PipeWire object exists here, so the entry-point table is never
        // read; only the lifetime accounting is exercised.
        undefined,
        session.sink(),
    );
    stream.lifetime.begin();

    // Nothing was handed out, so there is nothing of the producer's to give
    // back and the frame count stays where a teardown can read it.
    try std.testing.expect(!stream.dropFrame());
    try std.testing.expectEqual(@as(u32, 0), stream.outstandingFrames());

    stream.lifetime.hold();
    try std.testing.expect(stream.dropFrame());
    try std.testing.expectEqual(@as(u32, 0), stream.outstandingFrames());

    // The refused release cost the producer nothing: the teardown it was
    // waiting for still claims, and its hook runs exactly once.
    var destroys: u32 = 0;
    const Hook = struct {
        fn run(context: ?*anyopaque) void {
            const count: *u32 = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
    };
    stream.lifetime.destroy_hook = Hook.run;
    stream.lifetime.hook_ctx = &destroys;
    stream.stop();
    try std.testing.expectEqual(@as(u32, 1), destroys);
}

// -- Entry-point table --------------------------------------------------------

test "api-w20 the entry-point table cannot be built half resolved" {
    // A table is handed to callers as one value, so the only thing that can
    // make one partial is a field that was declared and never resolved. Every
    // field therefore names a symbol of its own, in field order, and the two
    // lists are checked against each other when this file is compiled.
    const fields = std.meta.fields(pipewire.Api);
    try std.testing.expectEqual(fields.len, pipewire.Api.symbols.len);
    // `StructField` values are comptime data, so the walk over them is
    // unrolled rather than indexed at runtime.
    inline for (fields, pipewire.Api.symbols) |field, name| {
        try std.testing.expectEqualStrings(field.name, name);
        // A field with a default would let a table be built by omission, and
        // that omission is exactly the partial table nothing may observe.
        try std.testing.expect(field.default_value_ptr == null);
        // Every entry point is a C function pointer, so a resolved field has
        // no other shape a half filled table could be carrying. A function
        // pointer is two type unions deep, so each one is read through its
        // active variant: the outer one is the pointer, and the calling
        // convention lives on the function it points at. A field that is
        // neither is refused here instead of passing a check it cannot make.
        const convention: std.builtin.CallingConvention = switch (@typeInfo(field.type)) {
            .pointer => |pointer| switch (@typeInfo(pointer.child)) {
                .@"fn" => |fun| fun.calling_convention,
                else => @compileError("an Api field points at something that is not callable"),
            },
            .@"fn" => |fun| fun.calling_convention,
            else => @compileError("an Api field is neither a function nor a pointer to one"),
        };
        try std.testing.expectEqual(std.builtin.CallingConvention.c, convention);
    }
}

// -- Format negotiation -------------------------------------------------------

/// A `Format` pod whose size property is written with the wire type and body
/// length the caller names, so a reader that trusts the zero value instead of
/// the type has somewhere to show it.
fn buildPodWithSize(size_type: u32, size_size: u32, width: u32, height: u32) TestPod {
    var pod: TestPod = .{};
    const body_len: usize = 2 * @sizeOf(u32) +
        prop_header_bytes + 4 + // format, an Id
        prop_header_bytes + @as(usize, size_size) + // size, shaped by the caller
        prop_header_bytes + 4; // colorRange, an Id
    pod.put(@intCast(body_len));
    pod.put(pipewire.spa_type_object);
    pod.put(pipewire.spa_type_object_format);
    pod.put(pipewire.spa_param_enum_format);
    pod.putIdProp(pipewire.spa_format_media_type, pipewire.spa_media_type_video);
    pod.putIdProp(pipewire.spa_format_media_subtype, pipewire.spa_media_subtype_raw);
    pod.putIdProp(pipewire.spa_format_video_format, pipewire.spa_video_format_bgra);
    pod.putProp(pipewire.spa_format_video_size, size_type, size_size);
    pod.put(width);
    pod.put(height);
    pod.pad();
    pod.putIdProp(pipewire.spa_format_video_color_range, pipewire.spa_video_color_range_0_255);
    return pod;
}

test "api-w20 a malformed format property is refused instead of read as zero" {
    // A property that is present but malformed is not the same as a property
    // that is absent. Read as its zero value it produces a negotiation that
    // looks agreed on: a size that is not a rectangle becomes 0x0, and a
    // renegotiation carrying that is dropped while the stream keeps
    // delivering frames measured against the layout before it.
    const malformed = [_]struct { size_type: u32, size_size: u32, width: u32, height: u32 }{
        // A size that says it is an id rather than a rectangle.
        .{ .size_type = pipewire.spa_type_id, .size_size = 8, .width = 8, .height = 4 },
        // A rectangle whose body stops before both sides of it.
        .{ .size_type = pipewire.spa_type_rectangle, .size_size = 4, .width = 8, .height = 4 },
        // A rectangle nobody can measure a frame against.
        .{ .size_type = pipewire.spa_type_rectangle, .size_size = 8, .width = 0, .height = 4 },
        .{ .size_type = pipewire.spa_type_rectangle, .size_size = 8, .width = 8, .height = 0 },
    };
    for (malformed) |shape| {
        const pod = buildPodWithSize(shape.size_type, shape.size_size, shape.width, shape.height);
        try std.testing.expect(pipewire.parseFormatBytes(pod.bytes[0..pod.len]) == null);
    }

    // The same pod written the way a session writes it still parses, so the
    // refusals above are about the bytes and not about the shape.
    const well_formed = buildPodWithSize(pipewire.spa_type_rectangle, 8, 8, 4);
    const parsed = pipewire.parseFormatBytes(well_formed.bytes[0..well_formed.len]).?;
    try std.testing.expectEqual(@as(u32, 8), parsed.width);
    try std.testing.expectEqual(@as(u32, 4), parsed.height);
    try std.testing.expectEqual(pipewire.spa_video_format_bgra, parsed.format);
}

test "api-w20 a format pod is read from any byte range" {
    // The parsers take a byte range, and a byte range carries no promise about
    // how it is aligned. Casting one that starts mid word to a pod pointer is
    // undefined behaviour, and where a pod lands inside a buffer is the
    // caller's choice, not something the reader may assume.
    const pod = buildFormatPod(
        pipewire.spa_media_type_video,
        pipewire.spa_video_format_bgra,
        8,
        4,
        pipewire.spa_video_color_range_0_255,
    );
    const bytes = pod.bytes[0..pod.len];

    var storage: [512]u8 align(8) = undefined;
    @memcpy(storage[1..][0..bytes.len], bytes);
    const shifted = storage[1..][0..bytes.len];
    try std.testing.expect(@intFromPtr(shifted.ptr) % @alignOf(u32) != 0);

    try std.testing.expect(pipewire.isFormatObject(shifted, pipewire.spa_param_enum_format));
    const parsed = pipewire.parseFormatBytes(shifted).?;
    try std.testing.expectEqual(@as(u32, 8), parsed.width);
    try std.testing.expectEqual(@as(u32, 4), parsed.height);

    const properties: pipewire.ObjectProperties = .{ .bytes = shifted };
    try std.testing.expectEqual(
        pipewire.spa_media_type_video,
        properties.find(pipewire.spa_format_media_type).?.asId().?,
    );
    // A truncated range is still a refusal rather than a read past the end.
    try std.testing.expect(properties.find(pipewire.spa_format_media_type) != null);
    try std.testing.expect(pipewire.parseFormatBytes(shifted[0 .. pipewire.object_header_bytes - 1]) == null);
}

test "api-w20 every pixel format the parser names has a byte size" {
    // A format id that falls between two known ones reads as unknown, never as
    // the nearest neighbour, and a format that is named is one a frame
    // descriptor can be measured against.
    var probe: u32 = 0;
    while (probe < 0x40) : (probe += 1) {
        if (pipewire.pixelFormatOf(probe)) |format| {
            try std.testing.expect(format.bytesPerPixel() != null);
        }
    }
    try std.testing.expect(pipewire.pixelFormatOf(0xffff_ffff) == null);
    try std.testing.expect(pipewire.pixelFormatOf(pipewire.spa_video_format_i420) == null);
    try std.testing.expect(pipewire.pixelFormatOf(pipewire.spa_video_format_nv12) == null);
}
