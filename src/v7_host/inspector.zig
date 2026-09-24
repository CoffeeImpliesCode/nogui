//! Host platform inspector and diagnostics coordinator.
//!
//! Owns frame snapshot retention, element picking across windows, stale handle
//! verification, and bounded performance collection for frames, tasks, and actions.
const std = @import("std");
const nogui = @import("nogui");

pub const inspection = nogui.inspection;

pub const InspectError = inspection.InspectError;
pub const InspectHandle = inspection.InspectHandle;
pub const NodeSnapshot = inspection.NodeSnapshot;
pub const FrameSnapshot = inspection.FrameSnapshot;
pub const CaptureOptions = inspection.CaptureOptions;
pub const SourceLocation = inspection.SourceLocation;
pub const SourceMap = inspection.SourceMap;
pub const FrameRecord = inspection.FrameRecord;
pub const TaskRecord = inspection.TaskRecord;
pub const ActionRecord = inspection.ActionRecord;

/// Configuration options for the host inspector.
pub const InspectorConfig = struct {
    frame_capacity: usize = 256,
    task_capacity: usize = 1024,
    action_capacity: usize = 1024,
    enable_collectors: bool = false,
    enable_picking: bool = false,
    /// Capture a read-only frame snapshot on every committed frame. Off
    /// means `onFrame` allocates nothing, so an inspector left mounted in a
    /// shipping app costs one predictable branch per frame.
    capture_snapshots: bool = true,
};

/// Host-level inspection and diagnostics coordinator.
pub const Inspector = struct {
    allocator: std.mem.Allocator,
    config: InspectorConfig,
    latest_snapshot: ?FrameSnapshot = null,
    previous_snapshot: ?FrameSnapshot = null,
    frame_collector: inspection.BoundedCollector(FrameRecord),
    task_collector: inspection.BoundedCollector(TaskRecord),
    action_collector: inspection.BoundedCollector(ActionRecord),
    /// Borrowed. The registry must outlive this inspector or be detached first.
    action_registry: ?*nogui.action.Registry = null,
    source_map: SourceMap = .{},
    active_selection: ?InspectHandle = null,
    pick_mode: bool = false,
    /// When false, `onFrame` captures nothing and allocates nothing.
    snapshots_enabled: bool,
    /// The frame's resolved overlay placements, borrowed. Null is the honest
    /// answer for a frame that registered none, and every snapshot then
    /// reports laid-out bounds with no overlay flagged. Attach it after the
    /// frame resolves and before `onFrame` captures from that frame.
    overlay_frame: ?*const nogui.overlay.Frame = null,

    /// Allocate and initialize a heap-managed inspector.
    pub fn init(allocator: std.mem.Allocator, config: InspectorConfig) !*Inspector {
        const self = try allocator.create(Inspector);
        errdefer allocator.destroy(self);
        self.* = try initOwned(allocator, config);
        return self;
    }

    /// Initialize a value inspector.
    ///
    /// A disabled collector takes no memory: it keeps its reserved capacity
    /// and allocates the buffer only when collection is turned on.
    pub fn initOwned(allocator: std.mem.Allocator, config: InspectorConfig) !Inspector {
        var fc = inspection.BoundedCollector(FrameRecord).initLazy(allocator, config.frame_capacity);
        errdefer fc.deinit();
        try fc.setEnabled(config.enable_collectors);

        var tc = inspection.BoundedCollector(TaskRecord).initLazy(allocator, config.task_capacity);
        errdefer tc.deinit();
        try tc.setEnabled(config.enable_collectors);

        var ac = inspection.BoundedCollector(ActionRecord).initLazy(allocator, config.action_capacity);
        errdefer ac.deinit();
        try ac.setEnabled(config.enable_collectors);

        return .{
            .allocator = allocator,
            .config = config,
            .frame_collector = fc,
            .task_collector = tc,
            .action_collector = ac,
            .pick_mode = config.enable_picking,
            .snapshots_enabled = config.capture_snapshots,
        };
    }

    /// Register a caller-owned action registry for bounded dispatch timing.
    /// Attach after enabling collectors. Detach before destroying the registry.
    /// The registry supports one observer; another observer is not replaced.
    pub fn attachActionRegistry(
        self: *Inspector,
        io: std.Io,
        registry: *nogui.action.Registry,
    ) error{ CollectorsDisabled, ObserverAlreadyAttached }!void {
        if (!self.action_collector.enabled) return error.CollectorsDisabled;
        if (self.action_registry == registry) return;
        if (registry.observer != null) return error.ObserverAlreadyAttached;
        self.detachActionRegistry();
        registry.setObserver(.{
            .user = self,
            .clock = nogui.Clock.monotonic(io),
            .on_dispatch = recordRegistryAction,
        });
        self.action_registry = registry;
    }

    pub fn detachActionRegistry(self: *Inspector) void {
        const registry = self.action_registry orelse return;
        registry.setObserver(null);
        self.action_registry = null;
    }

    fn recordRegistryAction(user: *anyopaque, event: nogui.action.DispatchEvent) void {
        const self: *Inspector = @ptrCast(@alignCast(user));
        if (!self.action_collector.enabled) return;
        var rec: ActionRecord = .{
            .target = event.target,
            .start_ns = std.math.cast(u64, event.start_ns) orelse 0,
            .end_ns = std.math.cast(u64, event.end_ns) orelse 0,
            .duration_ns = event.duration_ns,
            .result = event.result,
            .dispatch_depth = event.depth,
        };
        rec.setName(event.name);
        self.action_collector.record(rec);
    }

    /// Observer for the real task service, so task attribution happens at
    /// the service boundary instead of at a hand-written call site.
    ///
    /// Register it with `task.Service.setObserver`. The service calls it on
    /// the UI thread with no lock held; both callbacks only fill a bounded
    /// ring, so they never allocate. Clear it before the inspector's storage
    /// ends.
    pub fn taskObserver(self: *Inspector) nogui.task.Observer {
        return .{
            .user = self,
            .on_queued = recordQueuedTask,
            .on_finished = recordFinishedTask,
        };
    }

    fn recordQueuedTask(user: *anyopaque, fact: nogui.task.QueuedTask) void {
        const self: *Inspector = @ptrCast(@alignCast(user));
        self.onTaskQueued(fact.id, fact.priority, fact.queued_ns, fact.name, fact.window);
    }

    fn recordFinishedTask(user: *anyopaque, fact: nogui.task.FinishedTask) void {
        const self: *Inspector = @ptrCast(@alignCast(user));
        self.onTaskFinished(
            fact.id,
            fact.priority,
            fact.queued_ns,
            fact.start_ns,
            fact.end_ns,
            fact.name,
            fact.window,
        );
    }

    /// Free resources owned by the inspector.
    pub fn deinit(self: *Inspector) void {
        self.detachActionRegistry();
        if (self.latest_snapshot) |*snap| {
            snap.deinit();
            self.latest_snapshot = null;
        }
        if (self.previous_snapshot) |*snap| {
            snap.deinit();
            self.previous_snapshot = null;
        }
        self.source_map.deinit(self.allocator);
        self.frame_collector.deinit();
        self.task_collector.deinit();
        self.action_collector.deinit();
        self.* = undefined;
    }

    /// Free a heap-allocated inspector.
    pub fn destroy(self: *Inspector) void {
        const alloc = self.allocator;
        self.deinit();
        alloc.destroy(self);
    }

    pub fn setPickMode(self: *Inspector, enabled: bool) void {
        self.pick_mode = enabled;
    }

    /// Attach the overlay frame the next captures are measured against.
    /// Detach with null when the owner retires it; a captured snapshot keeps
    /// its own copies, so detaching never invalidates a retained one.
    pub fn setOverlayFrame(self: *Inspector, frame: ?*const nogui.overlay.Frame) void {
        self.overlay_frame = frame;
    }

    /// The overlay frame captures are currently measured against, or null.
    pub fn overlayFrame(self: *const Inspector) ?*const nogui.overlay.Frame {
        return self.overlay_frame;
    }

    pub fn isPickMode(self: *const Inspector) bool {
        return self.pick_mode;
    }

    pub fn select(self: *Inspector, handle: ?InspectHandle) void {
        self.active_selection = handle;
    }

    pub fn selected(self: *const Inspector) ?InspectHandle {
        return self.active_selection;
    }

    /// Resolve the active selection against the latest frame.
    /// Returns error.NotFound without a selection and error.StaleHandle when
    /// the element is expired or replaced.
    ///
    /// The result points into the latest snapshot arena and stays valid until
    /// the next `onFrame`, `clearSnapshots`, or `deinit`.
    pub fn resolveSelection(self: *const Inspector) InspectError!*const NodeSnapshot {
        const handle = self.active_selection orelse return error.NotFound;
        return self.resolveHandle(handle);
    }

    /// Resolve any inspection handle against the latest frame snapshot.
    /// The result borrows the latest snapshot arena.
    pub fn resolveHandle(self: *const Inspector, handle: InspectHandle) InspectError!*const NodeSnapshot {
        const snap = if (self.latest_snapshot) |*s| s else return error.NotFound;
        return snap.resolve(handle);
    }

    /// Attach a measured GPU span to the frame record the host ALREADY
    /// recorded for `frame_number`.
    ///
    /// A GPU timestamp is only readable after the work that wrote it has
    /// completed, which is always later than the moment the host records the
    /// frame. The span therefore joins the existing record in place: no
    /// second record is created for that frame and no record is aliased, so
    /// the retained count, the overrun counter and the chronological merge
    /// still describe exactly the frames that ran. False is the honest
    /// answer for a frame the bounded ring has already overwritten, or one
    /// whose record was never collected.
    ///
    /// Attribution is per window, and that is the host's contract rather than
    /// this method's assumption: `Application.setInspector` refuses to mount
    /// one inspector on a second window (`error.InspectorAlreadyMounted`), so
    /// every record in this ring belongs to the one window whose App numbered
    /// them and a frame number names exactly one frame here. A record that
    /// already carries a measurement is refused as well, so a span that
    /// arrived twice — or that raced another window's numbering — is counted
    /// as unattached by the caller instead of silently overwriting a real
    /// measurement.
    pub fn attachGpuExecute(self: *Inspector, frame_number: u64, gpu_ns: u64) bool {
        var index = self.frame_collector.count;
        while (index > 0) {
            index -= 1;
            const record = self.frame_collector.at(index) orelse continue;
            if (record.frame_number != frame_number) continue;
            if (record.gpu_execute_ns != null) return false;
            record.gpu_execute_ns = gpu_ns;
            return true;
        }
        return false;
    }

    /// Pick at a logical window coordinate using real pointer routing.
    /// The unranked tree hit remains available for overlay diagnostics.
    pub fn pickAt(self: *Inspector, pos: [2]f32) inspection.PickResult {
        const snap = self.latest_snapshot orelse return .{};
        const outcome = snap.pickResult(pos);
        if (self.pick_mode) {
            if (outcome.node) |node_id| {
                if (snap.findByFrameNodeId(node_id)) |hit| {
                    self.active_selection = hit.handle;
                }
            }
        }
        return outcome;
    }

    /// Pick and return the routed target's handle.
    pub fn pickHandleAt(self: *Inspector, pos: [2]f32) ?InspectHandle {
        const snap = self.latest_snapshot orelse return null;
        return snap.pick(pos);
    }

    /// Turn per-frame snapshot capture on or off.
    ///
    /// Off, `onFrame` allocates nothing and keeps the retained frames it
    /// already holds, so a mounted inspector can be silenced at runtime.
    pub fn setSnapshotEnabled(self: *Inspector, enabled: bool) void {
        self.snapshots_enabled = enabled;
        if (!enabled) self.clearSnapshots();
    }

    pub fn isSnapshotEnabled(self: *const Inspector) bool {
        return self.snapshots_enabled;
    }

    /// The frame before the latest one, or null before the second frame.
    /// The result borrows the retained snapshot and stays valid until the next
    /// `onFrame`, `clearSnapshots`, or `deinit`.
    pub fn previousSnapshot(self: *const Inspector) ?*const FrameSnapshot {
        return if (self.previous_snapshot) |*snap| snap else null;
    }

    /// The most recent committed frame, or null before the first frame.
    /// The result borrows the retained snapshot under the same lifetime rules
    /// as `resolveSelection`.
    pub fn latestSnapshot(self: *const Inspector) ?*const FrameSnapshot {
        return if (self.latest_snapshot) |*snap| snap else null;
    }

    /// Hook invoked when a new frame is committed.
    /// Captures a snapshot into inspector memory and records frame timings if
    /// enabled. A failed capture leaves the retained snapshots untouched, so
    /// the previous frame stays resolvable and the caller may retry.
    ///
    /// With `snapshots_enabled` false this allocates nothing and keeps the
    /// frame collector, which is the whole point of the disabled state.
    pub fn onFrame(
        self: *Inspector,
        options: CaptureOptions,
        record: ?FrameRecord,
    ) !void {
        if (!self.snapshots_enabled) {
            if (record) |rec| self.frame_collector.record(rec);
            return;
        }
        var opt = options;
        if (opt.source_map == null) {
            opt.source_map = &self.source_map;
        }
        // A caller that resolves its own overlay frame keeps it; otherwise
        // the attached one supplies the placements, so overlay nodes report
        // their painted bounds and routing rank.
        if (opt.overlay_frame == null) opt.overlay_frame = self.overlay_frame;
        const captured = try inspection.captureFrame(self.allocator, opt);

        if (self.previous_snapshot) |*old| {
            old.deinit();
            self.previous_snapshot = null;
        }
        self.previous_snapshot = self.latest_snapshot;
        self.latest_snapshot = captured;

        if (record) |rec| {
            self.frame_collector.record(rec);
        }
    }

    /// Hook for task queueing.
    pub fn onTaskQueued(
        self: *Inspector,
        task_id: u64,
        priority: nogui.task.Priority,
        queued_ns: u64,
        name: []const u8,
        window_id: ?u64,
    ) void {
        if (!self.task_collector.enabled) return;
        var rec: TaskRecord = .{
            .task_id = task_id,
            .priority = priority,
            .queued_ns = queued_ns,
            .start_ns = 0,
            .end_ns = 0,
            .duration_ns = 0,
            .window_id = window_id,
        };
        rec.setName(name);
        self.task_collector.record(rec);
    }

    /// Hook for task completion.
    pub fn onTaskFinished(
        self: *Inspector,
        task_id: u64,
        priority: nogui.task.Priority,
        queued_ns: u64,
        start_ns: u64,
        end_ns: u64,
        name: []const u8,
        window_id: ?u64,
    ) void {
        if (!self.task_collector.enabled) return;
        const duration_ns = if (end_ns >= start_ns) end_ns - start_ns else 0;
        var rec: TaskRecord = .{
            .task_id = task_id,
            .priority = priority,
            .queued_ns = queued_ns,
            .start_ns = start_ns,
            .end_ns = end_ns,
            .duration_ns = duration_ns,
            .window_id = window_id,
        };
        rec.setName(name);
        self.task_collector.record(rec);
    }

    /// Hook for action dispatch.
    pub fn onActionDispatched(
        self: *Inspector,
        name: []const u8,
        target: ?nogui.WidgetId,
        start_ns: u64,
        end_ns: u64,
        result: nogui.action.Result,
        depth: u32,
    ) void {
        if (!self.action_collector.enabled) return;
        const duration_ns = if (end_ns >= start_ns) end_ns - start_ns else 0;
        var rec: ActionRecord = .{
            .target = target,
            .start_ns = start_ns,
            .end_ns = end_ns,
            .duration_ns = duration_ns,
            .result = result,
            .dispatch_depth = depth,
        };
        rec.setName(name);
        self.action_collector.record(rec);
    }

    /// Associate source code metadata with a widget ID.
    pub fn registerSource(self: *Inspector, id: nogui.WidgetId, loc: SourceLocation) !void {
        try self.source_map.put(self.allocator, id, loc);
    }

    /// Toggle performance metric collection on or off.
    /// Enabling allocates the reserved capacity of every collector once.
    pub fn enableCollectors(self: *Inspector, enabled: bool) error{OutOfMemory}!void {
        if (!enabled) self.detachActionRegistry();
        try self.frame_collector.setEnabled(enabled);
        try self.task_collector.setEnabled(enabled);
        try self.action_collector.setEnabled(enabled);
    }

    /// Output every retained record as JSON-lines in chronological order.
    ///
    /// The three collectors are merged on the record's own end timestamp, so
    /// a task that finished inside a frame is read in the order it actually
    /// happened rather than in collector order. A record is emitted once,
    /// from the collector that owns it.
    /// Write the three collectors as one chronological JSONL stream.
    ///
    /// A three-way merge of the collectors' HEADS is not chronological: the
    /// collectors record in call order, and a caller that records a late task
    /// before an early one would put the late record first and then hide the
    /// early one behind it. Every retained record is therefore ordered by its
    /// own instant. Ties keep frames, then tasks, then actions, so the order
    /// is total and stable. The sort works on caller-independent storage and
    /// allocates nothing: the collectors are bounded, so the working set is a
    /// fixed array of pointers.
    pub fn writePerformanceJsonl(self: *const Inspector, writer: *std.Io.Writer) !void {
        // Bounded by construction: the three collectors are bounded, so this
        // is exactly as large as the records they can hold and never grows.
        var scratch: [bounded_scratch_entries]MergeEntry = undefined;
        const total = self.frame_collector.capacity() + self.task_collector.capacity() +
            self.action_collector.capacity();
        std.debug.assert(total <= scratch.len);
        var filled: usize = 0;
        for (0..self.frame_collector.count) |index| {
            scratch[filled] = .{
                .kind = .frame,
                .stamp = self.frame_collector.get(index).?.timestamp_ns,
            };
            filled += 1;
        }
        for (0..self.task_collector.count) |index| {
            scratch[filled] = .{
                .kind = .task,
                .stamp = self.task_collector.get(index).?.orderNs(),
            };
            filled += 1;
        }
        for (0..self.action_collector.count) |index| {
            scratch[filled] = .{
                .kind = .action,
                .stamp = self.action_collector.get(index).?.end_ns,
            };
            filled += 1;
        }
        const order = scratch[0..filled];
        std.mem.sort(MergeEntry, order, {}, lessEntry);
        for (order) |entry| {
            switch (entry.kind) {
                .frame => for (0..self.frame_collector.count) |index| {
                    const record = self.frame_collector.get(index).?;
                    if (record.timestamp_ns == entry.stamp) {
                        try writeJsonlRecord(writer, record);
                        break;
                    }
                },
                .task => for (0..self.task_collector.count) |index| {
                    const record = self.task_collector.get(index).?;
                    if (record.orderNs() == entry.stamp) {
                        try writeJsonlRecord(writer, record);
                        break;
                    }
                },
                .action => for (0..self.action_collector.count) |index| {
                    const record = self.action_collector.get(index).?;
                    if (record.end_ns == entry.stamp) {
                        try writeJsonlRecord(writer, record);
                        break;
                    }
                },
            }
        }
    }

    /// Output JSON hierarchy of the current frame snapshot.
    pub fn dumpSnapshotJson(self: *const Inspector, writer: *std.Io.Writer) !void {
        if (self.latest_snapshot) |*snap| {
            try snap.writeJson(writer);
        } else {
            try writer.writeAll("{\"frame\":0,\"nodes\":[]}");
        }
    }

    /// Discard retained snapshots.
    pub fn clearSnapshots(self: *Inspector) void {
        if (self.latest_snapshot) |*snap| {
            snap.deinit();
            self.latest_snapshot = null;
        }
        if (self.previous_snapshot) |*snap| {
            snap.deinit();
            self.previous_snapshot = null;
        }
    }
};

/// One JSON-lines record of any collector type.
/// Frames, then tasks, then actions on an equal instant, so the JSONL order is
/// total and two runs of the same input produce the same file.
/// Three collectors, each bounded by its own reserved capacity. The merge
/// scratch is sized from those, so it is a constant and never a heap
/// allocation on the profiling path.
const bounded_scratch_entries = 64 * 3;

const MergeEntry = struct {
    kind: enum { frame, task, action },
    stamp: u64,
};

fn lessEntry(_: void, a: MergeEntry, b: MergeEntry) bool {
    if (a.stamp != b.stamp) return a.stamp < b.stamp;
    return @intFromEnum(a.kind) < @intFromEnum(b.kind);
}

fn writeJsonlRecord(writer: *std.Io.Writer, record: anytype) !void {
    try record.writeJson(writer);
    try writer.writeByte('\n');
}

/// Reusable benchmark context for a real, scheduled run.
///
/// A benchmark owns its own sample storage and times whole runs with the
/// clock it is given. Production passes `Clock.monotonic(io)`, so the
/// numbers are real elapsed time; a deterministic test injects a clock and
/// keeps virtual time. Nothing here reads, rewrites or replaces the existing
/// `perf.zig` JSONL, the public counters, Tracy zones or GPU timestamps: the
/// context is a second, independent view over the inspector's own bounded
/// collectors.
pub const BenchContext = struct {
    clock: nogui.Clock,
    label: []const u8 = "bench",
    /// Caller-owned sample storage, so a run never allocates on the hot path.
    samples: []u64,
    recorded: usize = 0,
    /// Samples the caller asked for that had no storage. A run that asks for
    /// more samples than it sized must SEE the loss, not discover it later by
    /// a statistic that quietly covers fewer runs than the caller believes.
    dropped: usize = 0,
    /// Frames, tasks and actions retained by the inspector at the last read.
    frame_records: usize = 0,
    task_records: usize = 0,
    action_records: usize = 0,
    frame_overruns: u64 = 0,
    task_overruns: u64 = 0,
    action_overruns: u64 = 0,
    /// Duration of the GPU work the host measured for the last frame, when
    /// the host actually measured one. Null means "not measured", never zero.
    gpu_execute_ns: ?u64 = null,

    pub fn init(clock: nogui.Clock, samples: []u64) BenchContext {
        return .{ .clock = clock, .samples = samples };
    }

    /// A context on the production monotonic clock.
    pub fn initMonotonic(io: std.Io, samples: []u64) BenchContext {
        return init(nogui.Clock.monotonic(io), samples);
    }

    fn now(self: *const BenchContext) u64 {
        return std.math.cast(u64, @max(0, self.clock.now())) orelse 0;
    }

    /// Run one iteration, record its real elapsed nanoseconds and return it.
    ///
    /// A full sample buffer stops recording rather than growing, so a caller
    /// that asks for more samples than it sized sees the loss in
    /// `recorded` rather than in a silent allocation.
    pub fn run(self: *BenchContext, io: std.Io, body: *const fn (std.Io) void) u64 {
        const started = self.now();
        body(io);
        const span = self.now() -| started;
        if (self.recorded < self.samples.len) {
            self.samples[self.recorded] = span;
            self.recorded += 1;
        } else self.dropped += 1;
        return span;
    }

    /// Read the inspector's bounded retention without copying records.
    pub fn observe(self: *BenchContext, inspector: *const Inspector) void {
        self.frame_records = inspector.frame_collector.count;
        self.task_records = inspector.task_collector.count;
        self.action_records = inspector.action_collector.count;
        self.frame_overruns = inspector.frame_collector.overruns;
        self.task_overruns = inspector.task_collector.overruns;
        self.action_overruns = inspector.action_collector.overruns;
        self.gpu_execute_ns = if (inspector.frame_collector.latest()) |latest|
            latest.gpu_execute_ns
        else
            null;
    }

    /// Wall-clock statistics over the recorded samples, in nanoseconds.
    ///
    /// `min_ns` is null when no sample was recorded, so an empty run reads
    /// as "not measured" instead of as an instant zero.
    pub fn summary(self: *const BenchContext) Summary {
        if (self.recorded == 0) return .{};
        var total: u128 = 0;
        var smallest: u64 = self.samples[0];
        var largest: u64 = self.samples[0];
        for (self.samples[0..self.recorded]) |sample| {
            total += sample;
            smallest = @min(smallest, sample);
            largest = @max(largest, sample);
        }
        return .{
            .iterations = self.recorded,
            .min_ns = smallest,
            .max_ns = largest,
            .mean_ns = @intCast(total / self.recorded),
            .total_ns = @intCast(total),
        };
    }

    /// Write the benchmark report. The schema is this type's own; the demo
    /// recorder's per-frame JSONL is untouched by it.
    pub fn writeJson(self: *const BenchContext, writer: *std.Io.Writer) !void {
        const stats = self.summary();
        // `encodeJsonString` writes the quotes itself, so the field is opened
        // with the key alone: emitting a quote here produced `""label""`,
        // which is not JSON.
        try writer.writeAll("{\"bench\":");
        try std.json.Stringify.encodeJsonString(self.label, .{}, writer);
        try writer.print(
            // The string already closed itself, so this continues after it.
            ",\"iterations\":{d},\"dropped\":{d},\"min_ns\":",
            .{
                stats.iterations orelse 0,
                self.dropped,
            },
        );
        if (stats.min_ns) |value| {
            try writer.print("{d}", .{value});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"max_ns\":");
        if (stats.max_ns) |value| {
            try writer.print("{d}", .{value});
        } else {
            try writer.writeAll("null");
        }
        try writer.print(
            ",\"frame_records\":{d},\"task_records\":{d},\"action_records\":{d}," ++
                "\"frame_overruns\":{d},\"task_overruns\":{d},\"action_overruns\":{d}," ++
                "\"mean_ns\":",
            .{
                self.frame_records,
                self.task_records,
                self.action_records,
                self.frame_overruns,
                self.task_overruns,
                self.action_overruns,
            },
        );
        if (stats.mean_ns) |value| {
            try writer.print("{d}", .{value});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"total_ns\":");
        if (stats.total_ns) |value| {
            try writer.print("{d}", .{value});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"gpu_execute_ns\":");
        if (self.gpu_execute_ns) |value| {
            try writer.print("{d}", .{value});
        } else {
            try writer.writeAll("null");
        }
        // No trailing newline: this is a single report, and a consumer that
        // parses the buffer as JSON would see a syntax error after the object.
        try writer.writeAll("}");
    }

    /// Per-run statistics. A null field means the run recorded nothing.
    pub const Summary = struct {
        iterations: ?usize = null,
        min_ns: ?u64 = null,
        max_ns: ?u64 = null,
        mean_ns: ?u64 = null,
        total_ns: ?u64 = null,
    };
};

test "api-w24: host inspector lifecycle, selection, and stale detection" {
    const gpa = std.testing.allocator;

    var inspector = try Inspector.initOwned(gpa, .{
        .frame_capacity = 8,
        .task_capacity = 16,
        .action_capacity = 16,
        .enable_collectors = true,
        .enable_picking = true,
    });
    defer inspector.deinit();

    try std.testing.expect(inspector.isPickMode());

    // Frame 1: widget with generation 1
    const target_id: nogui.WidgetId = .{ .owner = 5, .slot = 1, .generation = 1 };
    var tree1 = nogui.WidgetTree.init(gpa);
    defer tree1.deinit();
    try tree1.nodes.append(gpa, .{
        .id = @enumFromInt(1),
        .widget_id = target_id,
        .kind = .{ .button = .{ .label = "Inspect Target" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 30 },
    });

    try inspector.onFrame(.{
        .frame_number = 1,
        .viewport = .{ .w = 200, .h = 200 },
        .tree = &tree1,
    }, null);

    // Pick at (20, 20)
    const pick = inspector.pickAt(.{ 20, 20 });
    try std.testing.expect(pick.node != null);
    // No overlay is mounted, so the routed pick and the engine's own hit
    // test must name the same node.
    try std.testing.expectEqual(
        nogui.input.hitTest(&tree1, .{ 20, 20 }).?,
        pick.node.?,
    );
    const picked = inspector.pickHandleAt(.{ 20, 20 }).?;
    try std.testing.expectEqual(target_id.slot, picked.id.slot);

    // Active selection set because pick_mode = true
    try std.testing.expect(inspector.selected() != null);
    const sel_node = try inspector.resolveSelection();
    try std.testing.expectEqualStrings("Inspect Target", sel_node.semantics.label.?);

    // Frame 2: widget slot 1 recycled with generation 2
    var tree2 = nogui.WidgetTree.init(gpa);
    defer tree2.deinit();
    try tree2.nodes.append(gpa, .{
        .id = @enumFromInt(1),
        .widget_id = .{ .owner = 5, .slot = 1, .generation = 2 },
        .kind = .{ .button = .{ .label = "New Generation Target" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 30 },
    });

    try inspector.onFrame(.{
        .frame_number = 2,
        .viewport = .{ .w = 200, .h = 200 },
        .tree = &tree2,
    }, null);

    // Resolving prior selection against frame 2 fails with StaleHandle!
    try std.testing.expectError(error.StaleHandle, inspector.resolveSelection());

    // The stale handle survives the frame that replaced it, so a host can keep
    // reporting what the user had selected.
    try std.testing.expectError(error.StaleHandle, inspector.resolveHandle(picked));

    // The snapshot dump of the current frame is valid JSON.
    var dump: std.Io.Writer.Allocating = .init(gpa);
    defer dump.deinit();
    try inspector.dumpSnapshotJson(&dump.writer);
    const parsed_dump = try std.json.parseFromSlice(std.json.Value, gpa, dump.written(), .{});
    defer parsed_dump.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed_dump.value.object.get("frame").?.integer);

    // Task and Action collection hooks
    inspector.onTaskQueued(42, .high, 1000, "async_fetch", 1);
    inspector.onTaskFinished(42, .high, 1000, 1100, 1500, "async_fetch", 1);

    inspector.onActionDispatched("close_window", target_id, 2000, 2050, .handled, 0);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try inspector.writePerformanceJsonl(&out.writer);
    const jsonl = out.written();
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"task_id\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"name\":\"async_fetch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"name\":\"close_window\"") != null);
}

test "api-w24: a disabled inspector allocates nothing and allocates on enable" {
    const gpa = std.testing.allocator;

    // Every allocation fails, so a disabled inspector proves it reserves no
    // collector buffer at construction.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var inspector = try Inspector.initOwned(failing.allocator(), .{
        .frame_capacity = 8,
        .task_capacity = 16,
        .action_capacity = 16,
        .enable_collectors = false,
    });
    defer inspector.deinit();
    try std.testing.expect(!failing.has_induced_failure);

    // The reservation is kept for later use; no buffer exists yet.
    try std.testing.expectEqual(@as(usize, 0), inspector.frame_collector.capacity());
    try std.testing.expectEqual(@as(usize, 8), inspector.frame_collector.reservedCapacity());
    try std.testing.expectEqual(@as(usize, 16), inspector.task_collector.reservedCapacity());

    // Records raised while disabled are dropped, not buffered.
    inspector.onTaskQueued(1, .high, 10, "while_disabled", null);
    inspector.onActionDispatched("while_disabled", null, 0, 1, .handled, 0);
    try std.testing.expectEqual(@as(u64, 0), inspector.task_collector.total_recorded);
    try std.testing.expectEqual(@as(u64, 0), inspector.action_collector.total_recorded);

    // Enabling takes the reserved capacity of each collector.
    failing.fail_index = std.math.maxInt(usize);
    try inspector.enableCollectors(true);
    try std.testing.expectEqual(@as(usize, 8), inspector.frame_collector.capacity());
    try std.testing.expectEqual(@as(usize, 16), inspector.task_collector.capacity());
    try std.testing.expectEqual(@as(usize, 16), inspector.action_collector.capacity());

    inspector.onTaskQueued(7, .high, 30, "after_enable", 3);
    try std.testing.expectEqual(@as(u64, 1), inspector.task_collector.total_recorded);
    try std.testing.expectEqual(@as(u64, 7), inspector.task_collector.latest().?.task_id);

    // Disabling keeps the buffer and stops collecting.
    try inspector.enableCollectors(false);
    inspector.onTaskQueued(8, .high, 40, "after_disable", 3);
    try std.testing.expectEqual(@as(u64, 1), inspector.task_collector.total_recorded);
    try std.testing.expectEqual(@as(u64, 7), inspector.task_collector.latest().?.task_id);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try inspector.writePerformanceJsonl(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"name\":\"after_enable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "after_disable") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "while_disabled") == null);
}

test "api-w24: a failed capture keeps the committed frame and its selection" {
    const gpa = std.testing.allocator;

    var inspector = try Inspector.initOwned(gpa, .{
        .frame_capacity = 0,
        .task_capacity = 0,
        .action_capacity = 0,
    });
    defer inspector.deinit();

    const first_id: nogui.WidgetId = .{ .owner = 9, .slot = 1, .generation = 1 };
    var tree1 = nogui.WidgetTree.init(gpa);
    defer tree1.deinit();
    try tree1.nodes.append(gpa, .{
        .id = @enumFromInt(1),
        .widget_id = first_id,
        .kind = .{ .button = .{ .label = "Committed" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 20 },
    });

    try inspector.onFrame(.{
        .frame_number = 1,
        .viewport = .{ .w = 100, .h = 100 },
        .tree = &tree1,
    }, null);
    inspector.setPickMode(true);
    const selection = inspector.pickHandleAt(.{ 5, 5 }).?;
    inspector.select(selection);

    // A capture that cannot allocate must not disturb the retained frame.
    var tree2 = nogui.WidgetTree.init(gpa);
    defer tree2.deinit();
    try tree2.nodes.append(gpa, .{
        .id = @enumFromInt(1),
        .widget_id = .{ .owner = 9, .slot = 1, .generation = 2 },
        .kind = .{ .button = .{ .label = "Rejected" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 20 },
    });

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const owned = inspector.allocator;
    inspector.allocator = failing.allocator();
    const attempt = inspector.onFrame(.{
        .frame_number = 2,
        .viewport = .{ .w = 100, .h = 100 },
        .tree = &tree2,
    }, null);
    inspector.allocator = owned;

    try std.testing.expectError(error.OutOfMemory, attempt);
    try std.testing.expect(failing.has_induced_failure);

    const kept = try inspector.resolveSelection();
    try std.testing.expectEqualStrings("Committed", kept.semantics.label.?);
    try std.testing.expectEqual(@as(u64, 1), inspector.latest_snapshot.?.frame_number);
    try std.testing.expect(inspector.previous_snapshot == null);

    // A later successful capture replaces the retained frame.
    try inspector.onFrame(.{
        .frame_number = 2,
        .viewport = .{ .w = 100, .h = 100 },
        .tree = &tree2,
    }, null);
    try std.testing.expectError(error.StaleHandle, inspector.resolveSelection());
    try std.testing.expectEqual(@as(u64, 2), inspector.latest_snapshot.?.frame_number);
}

test "api-w24: action registry dispatch records into the host inspector" {
    const gpa = std.testing.allocator;
    var session = try nogui.Session.init(gpa);
    defer session.deinit() catch unreachable;
    var registry = try nogui.action.Registry.init(gpa, &session);
    defer registry.deinit();
    const Inspect = nogui.action.Action(void, "inspector.inspect");
    try registry.register(Inspect);

    var inspector = try Inspector.initOwned(gpa, .{
        .frame_capacity = 0,
        .task_capacity = 0,
        .action_capacity = 2,
        .enable_collectors = true,
    });
    defer inspector.deinit();
    try inspector.attachActionRegistry(std.testing.io, &registry);

    var tree = nogui.WidgetTree.init(gpa);
    defer tree.deinit();
    try std.testing.expectEqual(
        nogui.action.Result.unavailable,
        try registry.dispatch(&tree, null, Inspect.name, null),
    );
    const rec = inspector.action_collector.latest().?;
    try std.testing.expectEqualStrings(Inspect.name, rec.getName());
    try std.testing.expectEqual(nogui.action.Result.unavailable, rec.result);
    try std.testing.expect(rec.target == null);
    try std.testing.expectEqual(@as(u32, 0), rec.dispatch_depth);
    try std.testing.expect(rec.end_ns >= rec.start_ns);
    try std.testing.expectEqual(rec.end_ns - rec.start_ns, rec.duration_ns);

    inspector.detachActionRegistry();
    try std.testing.expectEqual(
        nogui.action.Result.unavailable,
        try registry.dispatch(&tree, null, Inspect.name, null),
    );
    try std.testing.expectEqual(@as(u64, 1), inspector.action_collector.total_recorded);
}
