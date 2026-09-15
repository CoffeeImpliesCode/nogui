//! Interactive local-FLAC playback through FFmpeg and an SDL audio stream.

const std = @import("std");
const sdl3 = @import("sdl3");

const decoder_module = @import("ffmpeg_decoder.zig");
const Decoder = decoder_module.Decoder;
const LocalTrack = @import("spotify_data.zig").LocalTrack;

const channel_count: usize = decoder_module.output_channel_count;
const bytes_per_frame: usize = channel_count * @sizeOf(f32);
const queue_chunks_low_water: usize = 12;
const queue_frames_low_water: usize =
    @as(usize, decoder_module.pcm_frame_capacity) * queue_chunks_low_water;
const queue_bytes_low_water: usize = queue_frames_low_water * bytes_per_frame;
const fill_chunks_max: u8 = @intCast(queue_chunks_low_water);

comptime {
    std.debug.assert(channel_count == 2);
    std.debug.assert(bytes_per_frame == 8);
    std.debug.assert(queue_frames_low_water > @as(usize, decoder_module.pcm_frame_capacity));
    std.debug.assert(fill_chunks_max > 0);
}

pub const SyncResult = enum {
    unchanged,
    request_next_track,
};

const EndOfStreamAction = enum {
    restart_current,
    request_next_track,
};

fn endOfStreamAction(repeat: bool) EndOfStreamAction {
    return if (repeat) .restart_current else .request_next_track;
}

const Control = union(enum) {
    select: ?usize,
    open: struct {
        selected_index: usize,
        playing: bool,
    },
    seek: f32,
    play,
    pause,
    volume: f32,
    repeat: bool,
    stop,
};

fn playbackControl(is_playing: bool) Control {
    return if (is_playing) .play else .pause;
}

fn boundedSeekSeconds(position_sec: f32, duration_sec: u32) ?f32 {
    if (!std.math.isFinite(position_sec)) return null;
    const duration: f32 = @floatFromInt(duration_sec);
    return @max(@as(f32, 0), @min(position_sec, duration));
}

const ControlQueue = struct {
    const capacity: usize = 32;

    allocator: std.mem.Allocator,
    io: std.Io,
    storage: []Control,
    queue: std.Io.Queue(Control),
    pending: std.atomic.Value(u32),

    fn init(allocator: std.mem.Allocator, io: std.Io) !ControlQueue {
        const storage = try allocator.alloc(Control, capacity);
        return .{
            .allocator = allocator,
            .io = io,
            .storage = storage,
            .queue = .init(storage),
            .pending = .init(0),
        };
    }

    fn deinit(self: *ControlQueue) void {
        self.queue.close(self.io);
        self.allocator.free(self.storage);
        self.* = undefined;
    }

    /// Enqueue without waiting. A full queue is visible to the caller.
    ///
    /// The payload is published before `pending` is incremented. The worker
    /// reserves one pending count before retrieving exactly one payload. This
    /// pairs the atomic counter with Queue's own synchronization and avoids
    /// a zero-count wakeup race.
    fn tryPush(self: *ControlQueue, command: Control) !void {
        const queued = try self.queue.putUncancelable(self.io, &.{command}, 0);
        if (queued == 0) return error.QueueFull;
        std.debug.assert(queued == 1);

        const previous = self.pending.fetchAdd(1, .release);
        std.debug.assert(previous < capacity);
        self.io.futexWake(u32, &self.pending.raw, 1);
    }

    /// Reserve a pending command, then consume its matching Queue payload.
    fn pop(self: *ControlQueue) !?Control {
        if (self.pending.load(.acquire) == 0) return null;

        // There is exactly one worker consumer. Producers only increment this
        // counter after a successful Queue put, so this cannot underflow.
        const previous = self.pending.fetchSub(1, .acquire);
        std.debug.assert(previous > 0);
        return self.queue.getOneUncancelable(self.io) catch |err| switch (err) {
            error.Closed => return error.ControlQueueClosed,
        };
    }

    fn pendingCount(self: *const ControlQueue) usize {
        return @intCast(self.pending.load(.acquire));
    }

    fn wait(self: *ControlQueue, timed: bool) !void {
        if (!timed) {
            self.io.futexWaitUncancelable(u32, &self.pending.raw, 0);
            return;
        }

        self.io.futexWaitTimeout(
            u32,
            &self.pending.raw,
            0,
            .{
                .duration = .{
                    .raw = std.Io.Duration.fromMilliseconds(10),
                    .clock = .awake,
                },
            },
        ) catch |err| switch (err) {
            error.Canceled => return err,
        };
    }
};

const WorkerState = struct {
    selected_index: ?usize = null,
    repeat: bool = false,
    playing: bool = false,
    paused: bool = true,
    ended: bool = false,
    gain: f32 = 1.0,
};

const Worker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    tracks: []const LocalTrack,
    stream: sdl3.audio.Stream,
    decoder: Decoder,
    controls: ControlQueue,
    shutdown_requested: std.atomic.Value(bool),
    failed: std.atomic.Value(bool),
    next_track_requested: std.atomic.Value(bool),
    thread: ?std.Thread = null,

    fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        tracks: []const LocalTrack,
    ) !Worker {
        var decoder = try Decoder.init(gpa);
        errdefer decoder.deinit();

        const stream = try sdl3.audio.Device.default_playback.openStream(
            .{
                .format = .floating_32_bit,
                .num_channels = channel_count,
                .sample_rate = @as(usize, decoder_module.output_sample_rate_hz),
            },
            void,
            null,
            null,
        );
        errdefer stream.deinit();

        var controls = try ControlQueue.init(gpa, io);
        errdefer controls.deinit();

        return .{
            .gpa = gpa,
            .io = io,
            .tracks = tracks,
            .stream = stream,
            .decoder = decoder,
            .controls = controls,
            .shutdown_requested = .init(false),
            .failed = .init(false),
            .next_track_requested = .init(false),
        };
    }

    fn start(self: *Worker) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *Worker) void {
        self.runLoop() catch |err| {
            if (!self.shutdown_requested.load(.acquire)) {
                std.log.err("audio worker stopped: {s}", .{@errorName(err)});
                self.failed.store(true, .release);
            }
        };
        self.shutdown_requested.store(true, .release);
        self.io.futexWake(u32, &self.controls.pending.raw, 1);
    }

    fn runLoop(self: *Worker) !void {
        var state: WorkerState = .{};

        while (!self.shutdown_requested.load(.acquire)) {
            var processed_control = false;
            while (self.controls.pendingCount() > 0) {
                const command = (try self.controls.pop()) orelse {
                    return error.ControlPendingUnderflow;
                };
                processed_control = true;
                switch (command) {
                    .select => |selected_index| {
                        if (selected_index) |index| {
                            if (state.selected_index != index) {
                                try self.openTrack(&state, index);
                            }
                        } else {
                            try self.clearSelection(&state);
                        }
                    },
                    .open => |request| {
                        try self.openTrack(&state, request.selected_index);
                        state.playing = request.playing;
                    },
                    .seek => |position_sec| {
                        try self.seek(&state, position_sec);
                    },
                    .play => {
                        state.playing = true;
                        const queued_bytes = try self.stream.getQueued();
                        if (queued_bytes > 0) try self.setPaused(&state, false);
                    },
                    .pause => {
                        state.playing = false;
                        try self.setPaused(&state, true);
                    },
                    .volume => |volume| try self.setGain(&state, volume),
                    .repeat => |repeat| state.repeat = repeat,
                    .stop => {
                        self.shutdown_requested.store(true, .release);
                        return;
                    },
                }
            }

            if (self.shutdown_requested.load(.acquire)) break;

            const made_progress = try self.pump(&state);
            if (!made_progress and !processed_control) {
                try self.controls.wait(state.playing and state.selected_index != null);
            }
        }
    }

    fn pump(self: *Worker, state: *WorkerState) !bool {
        if (state.selected_index == null or !state.playing) return false;

        var queued_bytes = try self.stream.getQueued();
        if (state.ended) {
            if (queued_bytes > 0) return false;
            return self.finishTrack(state);
        }
        if (queued_bytes >= queue_bytes_low_water) return false;

        var fill_chunk_count: u8 = 0;
        var made_progress = false;
        while (!state.ended and
            queued_bytes < queue_bytes_low_water and
            fill_chunk_count < fill_chunks_max)
        {
            switch (try self.decoder.read()) {
                .pcm => |chunk| {
                    const sample_count = @as(usize, chunk.frame_count) * channel_count;
                    if (chunk.format.sample_rate_hz != decoder_module.output_sample_rate_hz or
                        chunk.format.channel_count != decoder_module.output_channel_count or
                        chunk.samples_interleaved.len != sample_count)
                    {
                        return error.DecoderOutputMismatch;
                    }
                    if (chunk.frame_count == 0) return error.EmptyPcmChunk;

                    const pcm_bytes = std.mem.sliceAsBytes(chunk.samples_interleaved);
                    try self.stream.putData(pcm_bytes);
                    queued_bytes += pcm_bytes.len;
                    fill_chunk_count += 1;
                    made_progress = true;
                },
                .end_of_stream => {
                    state.ended = true;
                    made_progress = true;
                },
            }
        }

        if (queued_bytes > 0) try self.setPaused(state, false);
        return made_progress;
    }

    fn finishTrack(self: *Worker, state: *WorkerState) !bool {
        switch (endOfStreamAction(state.repeat)) {
            .restart_current => {
                const selected_index = state.selected_index orelse return error.NoTrackSelected;
                try self.openTrack(state, selected_index);
                return true;
            },
            .request_next_track => {
                try self.setPaused(state, true);
                state.playing = false;
                self.next_track_requested.store(true, .release);
                return true;
            },
        }
    }

    fn openTrack(self: *Worker, state: *WorkerState, selected_index: usize) !void {
        if (selected_index >= self.tracks.len) return error.TrackIndexOutOfBounds;

        try self.setPaused(state, true);
        try self.decoder.open(self.tracks[selected_index].path);
        try self.stream.clear();
        state.selected_index = selected_index;
        state.ended = false;
    }

    fn seek(self: *Worker, state: *WorkerState, position_sec: f32) !void {
        if (state.selected_index == null) return error.NoTrackSelected;

        // Pause before clearing queued PCM so the device cannot emit samples
        // decoded before the seek while the worker resets the decoder.
        try self.setPaused(state, true);
        try self.stream.clear();
        try self.decoder.seek(position_sec);
        state.ended = false;
    }

    fn clearSelection(self: *Worker, state: *WorkerState) !void {
        try self.setPaused(state, true);
        if (state.selected_index == null) return;

        try self.stream.clear();
        self.decoder.close();
        state.selected_index = null;
        state.ended = false;
    }

    fn setGain(self: *Worker, state: *WorkerState, volume: f32) !void {
        const gain = std.math.clamp(volume, 0.0, 1.0);
        if (gain == state.gain) return;
        try self.stream.setGain(gain);
        state.gain = gain;
    }

    fn setPaused(self: *Worker, state: *WorkerState, paused: bool) !void {
        if (paused == state.paused) return;

        if (paused) {
            try self.stream.pauseDevice();
        } else {
            try self.stream.resumeDevice();
        }
        state.paused = paused;
    }

    fn requestStop(self: *Worker) void {
        if (self.thread == null) return;

        self.controls.tryPush(.stop) catch |err| switch (err) {
            error.QueueFull => std.log.warn("audio control queue full during shutdown", .{}),
            error.Closed => {},
        };
        self.shutdown_requested.store(true, .release);
        self.io.futexWake(u32, &self.controls.pending.raw, 1);
        self.thread.?.join();
        self.thread = null;
    }

    fn deinit(self: *Worker) void {
        self.requestStop();
        self.controls.deinit();
        self.stream.deinit();
        self.decoder.deinit();
        self.* = undefined;
    }
};

pub const AudioPlayer = struct {
    gpa: std.mem.Allocator,
    tracks: []const LocalTrack,
    worker: *Worker,
    selected_index_sent: ?usize = null,
    playing_sent: ?bool = null,
    repeat_sent: ?bool = null,
    volume_sent: ?f32 = null,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        tracks: []const LocalTrack,
    ) !AudioPlayer {
        const worker = try gpa.create(Worker);
        errdefer gpa.destroy(worker);

        worker.* = try Worker.init(gpa, io, tracks);
        errdefer worker.deinit();
        try worker.start();

        return .{
            .gpa = gpa,
            .tracks = tracks,
            .worker = worker,
        };
    }

    pub fn deinit(self: *AudioPlayer) void {
        const worker = self.worker;
        worker.deinit();
        self.gpa.destroy(worker);
        self.* = undefined;
    }

    /// Enqueue the UI playback state; all decoder and SDL writes stay on the worker.
    pub fn sync(
        self: *AudioPlayer,
        selected_index: usize,
        is_playing: bool,
        repeat: bool,
        volume: f32,
    ) !SyncResult {
        if (self.worker.failed.load(.acquire)) return error.AudioWorkerFailed;
        if (self.worker.next_track_requested.swap(false, .acq_rel)) {
            return .request_next_track;
        }

        if (self.volume_sent == null or self.volume_sent.? != volume) {
            try self.worker.controls.tryPush(.{ .volume = volume });
            self.volume_sent = volume;
        }
        if (self.repeat_sent == null or self.repeat_sent.? != repeat) {
            try self.worker.controls.tryPush(.{ .repeat = repeat });
            self.repeat_sent = repeat;
        }
        const selected_index_next: ?usize = if (selected_index < self.tracks.len) selected_index else null;
        if (self.selected_index_sent != selected_index_next) {
            try self.worker.controls.tryPush(.{ .select = selected_index_next });
            self.selected_index_sent = selected_index_next;
        }
        if (self.playing_sent == null or self.playing_sent.? != is_playing) {
            try self.worker.controls.tryPush(playbackControl(is_playing));
            self.playing_sent = is_playing;
        }

        if (self.worker.failed.load(.acquire)) return error.AudioWorkerFailed;
        return .unchanged;
    }

    /// Keep the selection and play transition in one queue item so EOF cannot
    /// cache a selection while dropping its playback transition.
    pub fn openTrack(
        self: *AudioPlayer,
        selected_index: usize,
        is_playing: bool,
    ) !void {
        if (selected_index >= self.tracks.len) return error.TrackIndexOutOfBounds;

        try self.worker.controls.tryPush(.{
            .open = .{
                .selected_index = selected_index,
                .playing = is_playing,
            },
        });
        self.selected_index_sent = selected_index;
        self.playing_sent = is_playing;
    }

    /// Enqueue a bounded seek; only the audio worker touches the decoder.
    pub fn seek(self: *AudioPlayer, selected_index: usize, position_sec: f32) !void {
        if (selected_index >= self.tracks.len) return error.TrackIndexOutOfBounds;
        const bounded_position = boundedSeekSeconds(
            position_sec,
            self.tracks[selected_index].duration_sec,
        ) orelse return error.InvalidSeekPosition;
        try self.worker.controls.tryPush(.{ .seek = bounded_position });
    }
};

test "end of stream action follows repeat mode" {
    try std.testing.expectEqual(
        EndOfStreamAction.restart_current,
        endOfStreamAction(true),
    );
    try std.testing.expectEqual(
        EndOfStreamAction.request_next_track,
        endOfStreamAction(false),
    );
}

test "EOF follow-up sends one next selection and resumes playback" {
    var io_impl = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_impl.deinit();

    // Model the UI/worker handoff without opening an SDL device or decoder.
    var tracks: [2]LocalTrack = undefined;
    var worker: Worker = .{
        .gpa = std.testing.allocator,
        .io = io_impl.io(),
        .tracks = &tracks,
        .stream = undefined,
        .decoder = undefined,
        .controls = try ControlQueue.init(std.testing.allocator, io_impl.io()),
        .shutdown_requested = .init(false),
        .failed = .init(false),
        .next_track_requested = .init(true),
    };
    defer worker.controls.deinit();

    var player: AudioPlayer = .{
        .gpa = std.testing.allocator,
        .tracks = &tracks,
        .worker = &worker,
        .selected_index_sent = 0,
        .playing_sent = true,
        .repeat_sent = false,
        .volume_sent = 1.0,
    };

    try std.testing.expectEqual(
        SyncResult.request_next_track,
        try player.sync(0, true, false, 1.0),
    );
    try std.testing.expect(!worker.next_track_requested.load(.acquire));
    try player.openTrack(1, true);
    try std.testing.expectEqual(@as(usize, 1), worker.controls.pendingCount());
    try std.testing.expectEqual(
        SyncResult.unchanged,
        try player.sync(1, true, false, 1.0),
    );

    var open_count: u8 = 0;
    while (try worker.controls.pop()) |command| {
        switch (command) {
            .open => |request| {
                open_count += 1;
                try std.testing.expectEqual(@as(usize, 1), request.selected_index);
                try std.testing.expect(request.playing);
            },
            else => return error.UnexpectedControl,
        }
    }
    try std.testing.expectEqual(@as(u8, 1), open_count);
}

test "control queue reports overflow and preserves FIFO order" {
    var io_impl = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_impl.deinit();

    var queue = try ControlQueue.init(std.testing.allocator, io_impl.io());
    defer queue.deinit();

    for (0..ControlQueue.capacity) |index| {
        try queue.tryPush(.{ .select = index });
    }
    try std.testing.expectEqual(@as(usize, ControlQueue.capacity), queue.pendingCount());
    try std.testing.expectError(error.QueueFull, queue.tryPush(.pause));

    for (0..ControlQueue.capacity) |expected_index| {
        const command = (try queue.pop()) orelse return error.TestUnexpectedResult;
        switch (command) {
            .select => |index| {
                try std.testing.expectEqual(expected_index, index orelse return error.TestUnexpectedResult);
            },
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqual(@as(usize, 0), queue.pendingCount());
}
test "bounded seek seconds clamps finite positions" {
    try std.testing.expectEqual(@as(?f32, 0.0), boundedSeekSeconds(-1.0, 120));
    try std.testing.expectEqual(@as(?f32, 37.5), boundedSeekSeconds(37.5, 120));
    try std.testing.expectEqual(@as(?f32, 120.0), boundedSeekSeconds(121.0, 120));
}

test "bounded seek seconds rejects non-finite positions" {
    try std.testing.expectEqual(@as(?f32, null), boundedSeekSeconds(std.math.nan(f32), 120));
    try std.testing.expectEqual(@as(?f32, null), boundedSeekSeconds(std.math.inf(f32), 120));
}

test "seek control keeps pending counter paired with payload" {
    var io_impl = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_impl.deinit();

    var queue = try ControlQueue.init(std.testing.allocator, io_impl.io());
    defer queue.deinit();

    try queue.tryPush(.{ .seek = 37.5 });
    try std.testing.expectEqual(@as(usize, 1), queue.pendingCount());
    const command = (try queue.pop()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 37.5), command.seek);
    try std.testing.expectEqual(@as(usize, 0), queue.pendingCount());
}

test "audio player seek clamps before enqueue" {
    var io_impl = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_impl.deinit();

    var tracks = [_]LocalTrack{.{
        .path = "track.flac",
        .title = "Track",
        .artist = "Artist",
        .album = "Album",
        .duration_str = "2:00",
        .duration_sec = 120,
    }};
    var worker: Worker = .{
        .gpa = std.testing.allocator,
        .io = io_impl.io(),
        .tracks = &tracks,
        .stream = undefined,
        .decoder = undefined,
        .controls = try ControlQueue.init(std.testing.allocator, io_impl.io()),
        .shutdown_requested = .init(false),
        .failed = .init(false),
        .next_track_requested = .init(false),
    };
    defer worker.controls.deinit();

    var player: AudioPlayer = .{
        .gpa = std.testing.allocator,
        .tracks = &tracks,
        .worker = &worker,
    };
    try player.seek(0, 999.0);

    const command = (try worker.controls.pop()) orelse return error.TestUnexpectedResult;
    switch (command) {
        .seek => |position_sec| {
            try std.testing.expectEqual(@as(f32, 120.0), position_sec);
        },
        else => return error.UnexpectedControl,
    }
    try std.testing.expectEqual(@as(usize, 0), worker.controls.pendingCount());
}

const ControlQueueRace = struct {
    queue: *ControlQueue,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn pushControlAfterFull(context: *ControlQueueRace) void {
    context.started.store(true, .release);
    while (true) {
        context.queue.tryPush(.{ .volume = 0.25 }) catch |err| switch (err) {
            error.QueueFull => {
                std.atomic.spinLoopHint();
                continue;
            },
            else => unreachable,
        };
        context.completed.store(true, .release);
        return;
    }
}

test "control queue pairs pending count with concurrent drain" {
    var io_impl = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_impl.deinit();

    var queue = try ControlQueue.init(std.testing.allocator, io_impl.io());
    defer queue.deinit();
    for (0..ControlQueue.capacity) |index| {
        try queue.tryPush(.{ .select = index });
    }

    var race: ControlQueueRace = .{ .queue = &queue };
    const producer = try std.Thread.spawn(.{}, pushControlAfterFull, .{&race});
    while (!race.started.load(.acquire)) std.atomic.spinLoopHint();

    var selected_count: usize = 0;
    var volume_count: usize = 0;
    for (0..ControlQueue.capacity) |_| {
        const command = (try queue.pop()) orelse return error.TestUnexpectedResult;
        switch (command) {
            .select => |index| {
                _ = index orelse return error.TestUnexpectedResult;
                selected_count += 1;
            },
            .volume => |gain| {
                try std.testing.expectEqual(@as(f32, 0.25), gain);
                volume_count += 1;
            },
            else => return error.TestUnexpectedResult,
        }
    }
    producer.join();

    while (try queue.pop()) |command| {
        switch (command) {
            .volume => |gain| {
                try std.testing.expectEqual(@as(f32, 0.25), gain);
                volume_count += 1;
            },
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqual(ControlQueue.capacity, selected_count);
    try std.testing.expectEqual(@as(usize, 1), volume_count);
    try std.testing.expect(race.completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), queue.pendingCount());
}
