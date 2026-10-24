//! Persistent UI timers and one priority-ordered worker. Work takes an owned
//! payload and the service's private Io; it must not borrow models, windows,
//! frame storage, or a shorter-lived executor. Session and model state stay
//! on UI. Cancellation leaves running storage intact until the worker exits.
//! An optional Observer reports queue and completion timings; it runs on the
//! UI thread, outside the Service lock, and allocates nothing.
const std = @import("std");
const Clock = @import("clock.zig").Clock;
const Session = @import("session.zig").Session;
const model = @import("model.zig");

pub const Handle = struct {
    session: u64 = 0,
    id: u64 = 0,
};

pub const Priority = enum { high, normal, low };
/// Borrowed only for the synchronous UI timeout callback.
pub const Timeout = struct {};

pub const Pending = struct {
    queued: usize = 0,
    running: usize = 0,
    ready: usize = 0,
    ui_timers: usize = 0,
    cancelled: usize = 0,
};
pub fn Options(comptime Owner: type) type {
    return struct {
        priority: Priority = .normal,
        /// The worker starts immediately; the result waits until this instant.
        not_before_ns: ?i96 = null,
        /// On timeout, notify the UI once and discard the eventual work result.
        timeout_ns: ?i96 = null,
        on_timeout: ?*const fn (*Owner, *const Timeout, *Session) void = null,
        /// The callback is skipped if this specific window is unregistered.
        window: ?u64 = null,
        /// Static label for observers; @typeName(Payload) is the default.
        name: ?[]const u8 = null,
    };
}

/// One queue fact for a scheduled task. The field set matches the inspector's
/// TaskRecord, so a sink copies fields instead of translating them.
pub const QueuedTask = struct {
    id: u64,
    priority: Priority,
    queued_ns: u64,
    /// Static label: the payload type name or a caller-supplied slice.
    name: []const u8,
    window: ?u64,
};

/// One completion fact for a task whose work has ended. A job that never ran
/// reports the cancel, timeout or shutdown instant as both start and end.
pub const FinishedTask = struct {
    id: u64,
    priority: Priority,
    queued_ns: u64,
    start_ns: u64,
    end_ns: u64,
    /// Static label: the payload type name or a caller-supplied slice.
    name: []const u8,
    window: ?u64,
};

/// Optional diagnostics sink, registered on the UI thread outside a frame and
/// cleared before its storage ends. Both callbacks run on the UI thread with no
/// Service lock held, and never on the worker thread. They must not block,
/// allocate, call Session, or retain a fact beyond its static name.
pub const Observer = struct {
    user: *anyopaque,
    on_queued: ?*const fn (*anyopaque, QueuedTask) void = null,
    on_finished: ?*const fn (*anyopaque, FinishedTask) void = null,
};

const State = enum { ui_timer, queued, running, ready, cancelled };
const Delivery = enum { delivered, stale };
const maximum_jobs_per_drain = 65_536;
const Job = struct {
    next: ?*Job = null,
    id: u64,
    state: State,
    priority: Priority = .normal,
    due_ns: ?i96 = null,
    timeout_ns: ?i96 = null,
    timed_out: bool = false,
    timeout_delivered: bool = false,
    suppressed: bool = false,
    window: ?u64 = null,
    /// Static label handed to observers; never borrowed from a payload.
    name: []const u8,
    queued_ns: u64 = 0,
    started_ns: u64 = 0,
    ended_ns: u64 = 0,
    /// True when a queue fact was published for this job.
    observed: bool = false,
    /// True once a worker run started; a fact without it is a non-run end.
    ran: bool = false,
    /// A completion fact is linked on Service.fact_first awaiting emission.
    fact_staged: bool = false,
    fact_next: ?*Job = null,
    move: *const fn (*Job, *anyopaque) void,
    free_unmoved: *const fn (*Job, std.mem.Allocator) void,
    run: ?*const fn (*Job, std.Io) void,
    deliver: *const fn (*Job, *Session) anyerror!Delivery,
    deliver_timeout: *const fn (*Job, *Session) anyerror!Delivery,
    destroy: *const fn (*Job, *Session) void,
};

pub const Service = struct {
    gpa: std.mem.Allocator,
    executor: std.Io.Threaded,
    io: std.Io,
    clock: Clock,
    session_id: u64,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    wake_event: std.Io.Event = .unset,
    sequence: u64 = 0,
    first: ?*Job = null,
    last: ?*Job = null,
    next_id: u64 = 1,
    worker: ?std.Thread = null,
    worker_alive: bool = false,
    stopping: bool = false,
    deterministic: bool = false,
    wake_context: ?*anyopaque = null,
    wake_callback: ?*const fn (*anyopaque) void = null,
    observer: ?Observer = null,
    /// Completion facts staged by the worker or the UI. The UI thread drains
    /// this chain without the Service lock; it never allocates.
    fact_first: ?*Job = null,
    fact_last: ?*Job = null,

    pub fn init(gpa: std.mem.Allocator, clock: Clock, session_id: u64) !*Service {
        const self = try initOwned(gpa, session_id);
        self.clock = clock;
        return self;
    }
    /// Uses the production queue and callbacks, but runs one worker job only
    /// when the caller explicitly steps it. No OS worker races the test clock.
    pub fn initDeterministic(
        gpa: std.mem.Allocator,
        clock: Clock,
        session_id: u64,
    ) !*Service {
        const self = try init(gpa, clock, session_id);
        self.deterministic = true;
        return self;
    }

    pub fn initOwned(gpa: std.mem.Allocator, session_id: u64) !*Service {
        const self = try gpa.create(Service);
        self.* = .{
            .gpa = gpa,
            .executor = std.Io.Threaded.init(gpa, .{}),
            // SAFETY: io is bound to this stable executor before use.
            .io = undefined,
            // SAFETY: initOwned assigns the clock before exposing the service.
            .clock = undefined,
            .session_id = session_id,
        };
        self.io = self.executor.io();
        self.clock = .monotonic(self.io);
        return self;
    }

    /// The notifier must not allocate, block, or reenter Session. Registration
    /// and publication use one mutex. Clearing it fences in-flight invocations.
    pub fn setWake(self: *Service, context: ?*anyopaque, callback: ?*const fn (*anyopaque) void) void {
        std.debug.assert((context == null) == (callback == null));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.wake_context = context;
        self.wake_callback = callback;
    }

    /// UI thread only, outside a frame and outside a Session transaction. The
    /// sink is UI-owned, so no worker can read it; a fact staged by a worker
    /// waits for the next UI flush. Clear it before the sink's storage ends.
    pub fn setObserver(self: *Service, observer: ?Observer) void {
        self.observer = observer;
    }

    fn publish(self: *Service) void {
        // Caller holds mutex; the event and notifier cannot race unregister.
        self.sequence +%= 1;
        self.wake_event.set(self.io);
        if (self.wake_callback) |callback| callback(self.wake_context.?);
    }

    pub fn snapshot(self: *Service) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.sequence;
    }

    /// UI checks the generation and resets the event under the same mutex as
    /// worker publication. A completion between drain and sleep is not lost.
    pub fn wait(self: *Service, seen: u64, timeout_ns: u64) !bool {
        self.mutex.lockUncancelable(self.io);
        if (self.sequence != seen) {
            self.mutex.unlock(self.io);
            return true;
        }
        self.wake_event.reset();
        self.mutex.unlock(self.io);
        const capped = @min(timeout_ns, @as(u64, std.math.maxInt(i64)));
        self.wake_event.waitTimeout(self.io, .{
            .duration = .{ .raw = .fromNanoseconds(@intCast(capped)), .clock = .awake },
        }) catch |err| switch (err) {
            error.Timeout => {},
            else => return err,
        };
        return self.snapshot() != seen;
    }

    pub fn nextDeadline(self: *Service) ?i96 {
        const now = self.clock.now();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var earliest: ?i96 = null;
        var job = self.first;
        while (job) |item| : (job = item.next) {
            switch (item.state) {
                .ready => {
                    if (item.suppressed or item.timed_out or item.due_ns == null or
                        item.due_ns.? <= now) return now;
                    earliest = earlier(earliest, item.due_ns.?);
                },
                .cancelled => return now,
                .ui_timer => earliest = earlier(earliest, item.due_ns.?),
                .queued, .running => {},
            }
            if (!item.timed_out and !item.suppressed) {
                if (item.timeout_ns) |deadline| earliest = earlier(earliest, deadline);
            }
        }
        return earliest;
    }

    pub fn scheduleUi(
        self: *Service,
        comptime Payload: type,
        comptime Owner: type,
        comptime handler: fn (*Owner, *Payload, *Session) void,
        session: *Session,
        owner: model.WeakModel(Owner),
        value: *Payload,
        deadline_ns: i96,
    ) !Handle {
        try session.validateTaskOwner(Owner, owner);
        const item = try self.makeJob(Payload, Owner, handler, null, owner, .{
            .due_ns = deadline_ns,
            .state = .ui_timer,
        });
        errdefer item.free_unmoved(item, self.gpa);
        return self.enqueue(item, value);
    }

    pub fn spawnWorker(
        self: *Service,
        comptime Payload: type,
        comptime Owner: type,
        comptime work: fn (*Payload, std.Io) void,
        comptime handler: fn (*Owner, *Payload, *Session) void,
        session: *Session,
        owner: model.WeakModel(Owner),
        value: *Payload,
        options: Options(Owner),
    ) !Handle {
        try session.validateTaskOwner(Owner, owner);
        if (options.window) |window| {
            if (!session.hasWindow(window)) return error.UnknownWindow;
        }
        const item = try self.makeJob(Payload, Owner, handler, work, owner, .{
            .state = .queued,
            .priority = options.priority,
            .due_ns = options.not_before_ns,
            .timeout_ns = options.timeout_ns,
            .on_timeout = options.on_timeout,
            .window = options.window,
            .name = options.name,
        });
        errdefer item.free_unmoved(item, self.gpa);
        if (!self.deterministic) try self.ensureWorker();
        return self.enqueue(item, value);
    }

    fn makeJob(
        self: *Service,
        comptime Payload: type,
        comptime Owner: type,
        comptime handler: fn (*Owner, *Payload, *Session) void,
        comptime work: ?fn (*Payload, std.Io) void,
        owner: model.WeakModel(Owner),
        config: struct {
            state: State,
            priority: Priority = .normal,
            due_ns: ?i96 = null,
            timeout_ns: ?i96 = null,
            on_timeout: ?*const fn (*Owner, *const Timeout, *Session) void = null,
            window: ?u64 = null,
            name: ?[]const u8 = null,
        },
    ) !*Job {
        const Concrete = struct {
            const Self = @This();
            base: Job,
            owner: model.WeakModel(Owner),
            payload: Payload,
            timeout_handler: ?*const fn (*Owner, *const Timeout, *Session) void,
            fn move(base: *Job, raw: *anyopaque) void {
                const item: *Self = @fieldParentPtr("base", base);
                const source: *Payload = @ptrCast(@alignCast(raw));
                item.payload = source.*;
                // SAFETY: the job owns this value after enqueue, and source is not reused.
                source.* = undefined;
            }
            fn freeUnmoved(base: *Job, gpa: std.mem.Allocator) void {
                const item: *Self = @fieldParentPtr("base", base);
                gpa.destroy(item);
            }
            fn run(base: *Job, io: std.Io) void {
                const item: *Self = @fieldParentPtr("base", base);
                work.?(&item.payload, io);
            }
            const Completion = struct { item: *Self, session: *Session };
            fn deliver(base: *Job, session: *Session) !Delivery {
                const item: *Self = @fieldParentPtr("base", base);
                var context: Completion = .{ .item = item, .session = session };
                session.update(Owner, item.owner, &context, complete) catch |err| switch (err) {
                    error.StaleModel => return .stale,
                    else => return err,
                };
                return .delivered;
            }
            fn complete(owner_ptr: *Owner, context: *Completion) !void {
                handler(owner_ptr, &context.item.payload, context.session);
            }
            const Deadline = struct { item: *Self, session: *Session, timeout: Timeout = .{} };
            fn deliverTimeout(base: *Job, session: *Session) !Delivery {
                const item: *Self = @fieldParentPtr("base", base);
                if (item.timeout_handler == null) return .stale;
                var context: Deadline = .{ .item = item, .session = session };
                session.update(Owner, item.owner, &context, timedOut) catch |err| switch (err) {
                    error.StaleModel => return .stale,
                    else => return err,
                };
                return .delivered;
            }
            fn timedOut(owner_ptr: *Owner, context: *Deadline) !void {
                context.item.timeout_handler.?(owner_ptr, &context.timeout, context.session);
            }
            fn destroy(base: *Job, session: *Session) void {
                const item: *Self = @fieldParentPtr("base", base);
                if (comptime hasDeinit(Payload)) item.payload.deinit(session);
                session.gpa.destroy(item);
            }
        };
        const item = try self.gpa.create(Concrete);
        item.* = .{
            .base = .{
                .id = 0,
                .state = config.state,
                .priority = config.priority,
                .due_ns = config.due_ns,
                .timeout_ns = config.timeout_ns,
                .window = config.window,
                .name = config.name orelse @typeName(Payload),
                .move = Concrete.move,
                .free_unmoved = Concrete.freeUnmoved,
                .run = if (work == null) null else Concrete.run,
                .deliver = Concrete.deliver,
                .deliver_timeout = Concrete.deliverTimeout,
                .destroy = Concrete.destroy,
            },
            .owner = owner,
            // SAFETY: enqueue initializes payload before any worker can read it.
            .payload = undefined,
            .timeout_handler = config.on_timeout,
        };
        return &item.base;
    }

    pub fn pending(self: *Service) Pending {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var counts: Pending = .{};
        var item = self.first;
        while (item) |job| : (item = job.next) {
            switch (job.state) {
                .queued => counts.queued += 1,
                .running => counts.running += 1,
                .ready => counts.ready += 1,
                .ui_timer => counts.ui_timers += 1,
                .cancelled => counts.cancelled += 1,
            }
        }
        return counts;
    }

    /// Run exactly one queued worker job using the same priority/FIFO selector
    /// as the OS worker. Its UI completion remains pending until drain().
    pub fn stepDeterministicWorker(self: *Service) !?u64 {
        if (!self.deterministic) return error.NotDeterministic;
        self.mutex.lockUncancelable(self.io);
        if (self.stopping) {
            self.mutex.unlock(self.io);
            return error.TasksShuttingDown;
        }
        const job = self.bestQueued() orelse {
            self.mutex.unlock(self.io);
            return null;
        };
        job.state = .running;
        self.stampStart(job);
        self.mutex.unlock(self.io);
        job.run.?(job, self.io);
        self.mutex.lockUncancelable(self.io);
        self.finishRun(job);
        self.publish();
        self.mutex.unlock(self.io);
        return job.id;
    }

    /// Caller holds mutex. Stable queue order gives FIFO inside a priority.
    fn bestQueued(self: *Service) ?*Job {
        var best: ?*Job = null;
        var item = self.first;
        while (item) |candidate| : (item = candidate.next) {
            if (candidate.state != .queued) continue;
            if (best == null or @backingInt(candidate.priority) <
                @backingInt(best.?.priority)) best = candidate;
        }
        return best;
    }

    /// Caller holds mutex; keep UI delivery in actual completion order.
    fn finishRun(self: *Service, job: *Job) void {
        job.state = .ready;
        self.stageFact(job);
        if (self.last != job) {
            var cursor = &self.first;
            while (cursor.* != job) cursor = &cursor.*.?.next;
            cursor.* = job.next;
            job.next = null;
            self.last.?.next = job;
            self.last = job;
        }
    }

    fn ensureWorker(self: *Service) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping) return error.TasksShuttingDown;
        if (self.worker != null) return;
        self.worker_alive = true;
        self.worker = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
            self.worker_alive = false;
            return err;
        };
    }

    fn enqueue(self: *Service, job: *Job, value: anytype) !Handle {
        const handle = try self.link(job, value);
        // The queue fact belongs to the UI thread that enqueued; it must not
        // run while the Service lock is held.
        self.emitQueued(job);
        return handle;
    }

    fn link(self: *Service, job: *Job, value: anytype) !Handle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping) return error.TasksShuttingDown;
        if (self.next_id == std.math.maxInt(u64)) return error.CapacityExceeded;
        job.id = self.next_id;
        self.next_id += 1;
        if (self.last) |last| last.next = job else self.first = job;
        self.last = job;
        job.move(job, @ptrCast(value));
        if (self.observer != null) {
            job.observed = true;
            job.queued_ns = elapsedNs(self.clock.now());
        }
        if (job.state == .queued) self.condition.signal(self.io);
        self.publish();
        return .{ .session = self.session_id, .id = job.id };
    }

    fn workerMain(self: *Service) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            var best: ?*Job = null;
            while (best == null and !self.stopping) {
                best = self.bestQueued();
                if (best == null) self.condition.waitUncancelable(self.io, &self.mutex);
            }
            if (self.stopping) {
                self.worker_alive = false;
                self.publish();
                self.mutex.unlock(self.io);
                return;
            }
            const job = best.?;
            job.state = .running;
            self.stampStart(job);
            self.mutex.unlock(self.io);
            job.run.?(job, self.io);
            self.mutex.lockUncancelable(self.io);
            self.finishRun(job);
            self.publish();
            self.mutex.unlock(self.io);
        }
    }

    fn find(self: *Service, handle: Handle) ?*Job {
        if (handle.session != self.session_id or handle.id == 0) return null;
        var current = self.first;
        while (current) |job| : (current = job.next) {
            if (job.id == handle.id) return job;
        }
        return null;
    }

    pub fn cancel(self: *Service, handle: *Handle) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const job = self.find(handle.*) orelse return false;
        if (job.state == .cancelled or job.timed_out) return false;
        if (job.state != .running) {
            // The work never starts, so the cancel instant is its end.
            job.state = .cancelled;
            self.stageFact(job);
        }
        job.suppressed = true;
        handle.* = .{};
        self.publish();
        return true;
    }

    pub fn detach(self: *Service, handle: *Handle) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.find(handle.*) == null) return false;
        handle.* = .{};
        return true;
    }

    pub fn drain(self: *Service, session: *Session) !usize {
        // Facts the worker staged since the last pass leave the lock here.
        self.flushObserver();
        var delivered: usize = 0;
        var processed: usize = 0;
        while (true) {
            if (processed == maximum_jobs_per_drain) {
                self.flushObserver();
                return delivered;
            }
            const now = self.clock.now();
            self.mutex.lockUncancelable(self.io);
            var cursor = &self.first;
            var action: enum { none, success, timeout, discard } = .none;
            var selected: ?*Job = null;
            while (cursor.*) |job| {
                if (!self.stopping and !job.suppressed and !job.timed_out and
                    job.timeout_ns != null and now >= job.timeout_ns.?)
                {
                    job.timed_out = true;
                    if (job.state != .running) {
                        // The result is discarded, so the timeout instant ends
                        // a run that never started.
                        job.state = .cancelled;
                        self.stageFact(job);
                    }
                }
                if (job.timed_out and !job.timeout_delivered and !self.stopping) {
                    action = .timeout;
                    selected = job;
                    break;
                }
                const eligible = switch (job.state) {
                    .ui_timer => now >= job.due_ns.?,
                    .ready => job.suppressed or job.timed_out or job.due_ns == null or
                        now >= job.due_ns.?,
                    .cancelled => true,
                    else => false,
                };
                if (eligible) {
                    action = if (job.state == .cancelled or job.suppressed or job.timed_out or self.stopping)
                        .discard
                    else
                        .success;
                    selected = job;
                    if (action == .success and job.state == .ui_timer) self.stageFact(job);
                    cursor.* = job.next;
                    if (self.last == job) self.last = findLast(self.first);
                    job.next = null;
                    break;
                }
                cursor = &job.next;
            }
            self.mutex.unlock(self.io);
            const job = selected orelse break;
            processed += 1;
            switch (action) {
                .success => {
                    if (job.window == null or session.hasWindow(job.window.?)) {
                        const result = job.deliver(job, session) catch |err| {
                            self.requeue(job);
                            return err;
                        };
                        if (result == .delivered) delivered += 1;
                    }
                    self.retireFact(job);
                    job.destroy(job, session);
                },
                .timeout => {
                    if (job.window == null or session.hasWindow(job.window.?)) {
                        const result = try job.deliver_timeout(job, session);
                        if (result == .delivered) delivered += 1;
                    }
                    self.mutex.lockUncancelable(self.io);
                    job.timeout_delivered = true;
                    self.mutex.unlock(self.io);
                },
                .discard => {
                    self.retireFact(job);
                    job.destroy(job, session);
                },
                .none => unreachable,
            }
        }
        self.flushObserver();
        return delivered;
    }

    fn requeue(self: *Service, job: *Job) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        job.next = self.first;
        self.first = job;
        if (self.last == null) self.last = job;
        self.publish();
    }

    // Observer facts.

    /// Caller holds mutex. One job reports its end once. The clock is read
    /// only for an observed job, so a cleared observer costs one branch.
    fn stageFact(self: *Service, job: *Job) void {
        if (!job.observed or job.fact_staged) return;
        const end_ns = elapsedNs(self.clock.now());
        job.ended_ns = end_ns;
        // A job that never ran reports its single instant as both ends.
        if (!job.ran) job.started_ns = end_ns;
        job.fact_staged = true;
        if (self.fact_last) |last| last.fact_next = job else self.fact_first = job;
        self.fact_last = job;
    }

    /// Caller holds mutex. Record when a job's run began.
    fn stampStart(self: *Service, job: *Job) void {
        job.ran = true;
        if (job.observed) job.started_ns = elapsedNs(self.clock.now());
    }

    /// Caller holds mutex. Detach one staged fact. An emitted job left the
    /// chain, so the walk simply ends without a match.
    fn unlinkFact(self: *Service, job: *Job) void {
        var cursor = &self.fact_first;
        while (cursor.*) |item| : (cursor = &item.fact_next) {
            if (item != job) continue;
            cursor.* = item.fact_next;
            item.fact_next = null;
            if (self.fact_last == item) {
                // An emptied chain ends with both ends clear.
                self.fact_last = null;
                var tail = self.fact_first;
                while (tail) |node| : (tail = node.fact_next) {
                    if (node.fact_next == null) self.fact_last = node;
                }
            }
            return;
        }
    }

    /// Unlink a staged fact and copy it out; the caller holds no lock.
    fn takeFact(self: *Service, job: *Job) ?FinishedTask {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!job.fact_staged) return null;
        job.fact_staged = false;
        self.unlinkFact(job);
        return .{
            .id = job.id,
            .priority = job.priority,
            .queued_ns = job.queued_ns,
            .start_ns = job.started_ns,
            .end_ns = job.ended_ns,
            .name = job.name,
            .window = job.window,
        };
    }

    /// UI thread, no lock held: the enqueue site holds neither.
    fn emitQueued(self: *Service, job: *const Job) void {
        if (self.observer) |sink| {
            if (sink.on_queued) |notify| notify(sink.user, .{
                .id = job.id,
                .priority = job.priority,
                .queued_ns = job.queued_ns,
                .name = job.name,
                .window = job.window,
            });
        }
    }

    /// UI thread, no lock held while the callback runs.
    fn emitFinished(self: *Service, job: *Job) void {
        const fact = self.takeFact(job) orelse return;
        if (self.observer) |sink| {
            if (sink.on_finished) |notify| notify(sink.user, fact);
        }
    }

    fn nextStaged(self: *Service) ?*Job {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.fact_first;
    }

    /// Drain the staged chain on the calling UI thread. Worker completions and
    /// UI-decided outcomes reach the sink in the order the service learned
    /// them, and each fact leaves the lock before the callback runs.
    fn flushObserver(self: *Service) void {
        while (self.nextStaged()) |job| self.emitFinished(job);
    }

    /// The job storage ends here. A fact the chain still holds is emitted now
    /// so no observer call can follow the memory it describes.
    fn retireFact(self: *Service, job: *Job) void {
        if (!job.observed) return;
        self.emitFinished(job);
    }

    /// Shutdown requests stop, never joins a running worker past the bound.
    /// UnfinishedWork keeps the service, its job buffers and Session alive.
    pub fn shutdown(self: *Service, session: *Session, timeout_ns: u64) !void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        var job = self.first;
        while (job) |item| : (job = item.next) {
            if (item.state != .running) {
                item.state = .cancelled;
                self.stageFact(item);
            }
            item.suppressed = true;
        }
        self.condition.broadcast(self.io);
        self.publish();
        self.mutex.unlock(self.io);

        const deadline = std.Io.Timestamp.now(self.io, .awake).nanoseconds +
            @as(i96, @intCast(timeout_ns));
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const alive = self.worker_alive;
            const seen = self.sequence;
            self.mutex.unlock(self.io);
            if (!alive) break;
            const now = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
            if (now >= deadline) return error.UnfinishedWork;
            const remaining: u64 = @intCast(@min(deadline - now, @as(i96, std.math.maxInt(u64))));
            _ = try self.wait(seen, remaining);
        }
        if (self.worker) |worker| worker.join();
        self.worker = null;
        while (self.first != null) {
            _ = try self.drain(session);
        }
        std.debug.assert(self.first == null);
        // Every destroyed job retired its fact, so no pointer outlives storage.
        std.debug.assert(self.fact_first == null);
        self.executor.deinit();
        self.gpa.destroy(self);
    }
};

/// Observer facts carry the unsigned nanoseconds of inspection.TaskRecord; an
/// injected clock at or before zero reports 0.
fn elapsedNs(now: i96) u64 {
    return if (now <= 0) 0 else @intCast(now);
}

fn earlier(current: ?i96, candidate: i96) ?i96 {
    return if (current) |time| @min(time, candidate) else candidate;
}

fn findLast(first: ?*Job) ?*Job {
    var current = first;
    while (current) |job| {
        if (job.next == null) return job;
        current = job.next;
    }
    return null;
}

fn hasDeinit(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "deinit"),
        else => false,
    };
}
