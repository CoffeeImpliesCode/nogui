//! UI-thread-only owner of persistent models, typed globals, and FIFO effects.
//!
//! Models and effect payloads never live in an App frame arena. Callback
//! pointers are borrowed only for their synchronous invocation; never retain
//! `*T` or `*const T` from read/update/listener callbacks in a frame or task.
//! W05 worker completions must marshal to the Session's UI thread.
const std = @import("std");
const model = @import("model.zig");
const effects = @import("effects.zig");
const subscription = @import("subscription.zig");
const globals = @import("globals.zig");
const callback = @import("callback.zig");
const task = @import("task.zig");
const Clock = @import("clock.zig").Clock;
const ModelKey = model.ModelKey;
const ErasedModel = model.ErasedModel;
const ErasedWeakModel = model.ErasedWeakModel;

var next_store_id: std.atomic.Value(u64) = .init(1);
var next_window_id: std.atomic.Value(u64) = .init(1);

const SlotState = enum { free, reserved, live, retiring, quarantined };

const Slot = struct {
    generation: u32 = 1,
    state: SlotState = .free,
    type_marker: *const u8,
    payload: *anyopaque,
    destroy: *const fn (*anyopaque, *Session) void,
    strong: u32 = 0,
    readers: u32 = 0,
    writer: bool = false,
    next_free: ?u32 = null,
};

const Ticket = struct {
    generation: u32 = 1,
    slot: u32,
    active: bool = true,
    next_free: ?u32 = null,
};
const Target = union(enum) {
    model: ModelKey,
    global: *const u8,
};
const Dependency = struct {
    window: u64,
    target: Target,
};
const WindowDemand = struct {
    dirty: bool = false,
    retired: bool = false,
    in_flight: bool = false,
};

const maximum_effects_per_drain = 65_536;

pub const Session = struct {
    gpa: std.mem.Allocator,
    id: u64,
    slots: std.ArrayListUnmanaged(*Slot) = .empty,
    tickets: std.ArrayListUnmanaged(Ticket) = .empty,
    free_slot: ?u32 = null,
    free_ticket: ?u32 = null,
    active_slots: u32 = 0,
    active_windows: std.AutoHashMapUnmanaged(u64, WindowDemand) = .empty,
    live_apps: u32 = 0,
    draw_depth: u32 = 0,
    frame_window: ?u64 = null,
    staged_dependencies: std.ArrayListUnmanaged(Dependency) = .empty,
    dependencies: std.ArrayListUnmanaged(Dependency) = .empty,
    listeners: std.ArrayListUnmanaged(subscription.Entry) = .empty,
    next_listener: u64 = 1,
    /// Suspends every `pump`, so queued effects and listeners wait for
    /// `resumeDelivery`. Only an owner finishing work between a frame's close
    /// and its delivery sets this.
    defer_delivery: bool = false,
    effect_queue: effects.Queue = .{},
    global_store: globals.Store = .{},
    update_depth: u32 = 0,
    borrow_depth: u32 = 0,
    release_depth: u32 = 0,
    shutting_down: bool = false,
    task_service: ?*task.Service = null,

    pub fn init(gpa: std.mem.Allocator) !Session {
        return .{ .gpa = gpa, .id = try nextId(&next_store_id) };
    }

    /// Stop tasks with a finite bound before retiring models. Unfinished work
    /// reports UnfinishedWork and keeps its buffers, executor and Session live
    /// for a later shutdownTasks/deinit retry.
    pub fn deinit(self: *Session) !void {
        if (self.task_service != null) {
            try self.shutdownTasks(100 * std.time.ns_per_ms);
        }
        try self.requireEmpty();
        self.shutting_down = true;
        // Queued payloads belong to this Session even when the last listener
        // was cancelled. Destructors may inspect still-live globals.
        for (self.effect_queue.items.items[self.effect_queue.head..]) |effect| {
            effect.drop(@ptrCast(self));
        }
        self.effect_queue.deinit(self.gpa);
        for (self.global_store.entries.items) |entry| {
            entry.destroy(entry.payload, @ptrCast(self));
            self.gpa.destroy(entry);
        }
        self.global_store.deinit(self.gpa);
        self.listeners.deinit(self.gpa);
        self.dependencies.deinit(self.gpa);
        self.staged_dependencies.deinit(self.gpa);
        for (self.slots.items) |slot| self.gpa.destroy(slot);
        self.slots.deinit(self.gpa);
        self.tickets.deinit(self.gpa);
        self.active_windows.deinit(self.gpa);
        self.* = undefined;
    }

    fn requireEmpty(self: *const Session) !void {
        if (self.live_apps != 0) return error.LiveApps;
        if (self.active_slots != 0 or self.draw_depth != 0 or self.frame_window != null or
            self.update_depth != 0 or self.borrow_depth != 0 or self.release_depth != 0 or
            self.effect_queue.draining) return error.LiveModels;
    }

    /// Start the task service with a caller-owned clock. Injected clock data
    /// must live until shutdownTasks succeeds.
    pub fn startTasks(self: *Session, clock: Clock) !void {
        try self.requireOutsideDraw();
        if (self.task_service != null) return error.TasksAlreadyStarted;
        self.task_service = try task.Service.init(self.gpa, clock, self.id);
    }

    /// Test-controlled worker steps; all queueing, ownership and UI delivery
    /// still pass through the production task service.
    pub fn startTasksDeterministic(self: *Session, clock: Clock) !void {
        try self.requireOutsideDraw();
        if (self.task_service != null) return error.TasksAlreadyStarted;
        self.task_service = try task.Service.initDeterministic(self.gpa, clock, self.id);
    }

    /// Use a private monotonic executor. It survives a bounded shutdown error
    /// until the caller retries shutdownTasks and releases the Session.
    pub fn startTasksOwned(self: *Session) !void {
        try self.requireOutsideDraw();
        if (self.task_service != null) return error.TasksAlreadyStarted;
        self.task_service = try task.Service.initOwned(self.gpa, self.id);
    }

    pub fn tasksStarted(self: *const Session) bool {
        return self.task_service != null;
    }

    /// Callback is called after wake publication under the service lock. It
    /// must not block, allocate, or call Session. Clearing waits for any
    /// concurrent invocation to finish before returning.
    pub fn setTaskWake(
        self: *Session,
        context: ?*anyopaque,
        callback_fn: ?*const fn (*anyopaque) void,
    ) !void {
        const service = self.task_service orelse return error.TasksNotStarted;
        service.setWake(context, callback_fn);
    }

    pub fn taskWakeSnapshot(self: *Session) !u64 {
        const service = self.task_service orelse return error.TasksNotStarted;
        return service.snapshot();
    }

    pub fn waitForTaskWake(self: *Session, snapshot: u64, timeout_ns: u64) !bool {
        const service = self.task_service orelse return error.TasksNotStarted;
        return service.wait(snapshot, timeout_ns);
    }

    /// Absolute nanoseconds of the configured monotonic clock; null means no
    /// timer is pending. Ready worker results return an immediate deadline.
    pub fn nextTaskDeadline(self: *Session) !?i96 {
        const service = self.task_service orelse return error.TasksNotStarted;
        return service.nextDeadline();
    }

    pub fn taskPending(self: *Session) !task.Pending {
        const service = self.task_service orelse return error.TasksNotStarted;
        return service.pending();
    }

    /// A deterministic worker step is still forbidden during a frame/borrow.
    pub fn stepDeterministicWorker(self: *Session) !?u64 {
        if (self.frame_window != null or self.draw_depth != 0 or self.update_depth != 0 or
            self.borrow_depth != 0 or self.release_depth != 0 or self.effect_queue.draining)
        {
            return error.TransactionInProgress;
        }
        const service = self.task_service orelse return error.TasksNotStarted;
        return service.stepDeterministicWorker();
    }

    pub fn hasWindow(self: *const Session, window: u64) bool {
        const demand = self.active_windows.get(window) orelse return false;
        return !demand.retired;
    }

    /// Native close retires a borrowed App's task/redraw identity while its
    /// owner still holds the App. App.deinit later unregisters the slot.
    pub fn retireWindow(self: *Session, window: u64) !void {
        if (self.frame_window != null or self.draw_depth != 0 or self.update_depth != 0 or
            self.borrow_depth != 0 or self.release_depth != 0 or self.effect_queue.draining)
        {
            return error.TransactionInProgress;
        }
        const demand = self.active_windows.getPtr(window) orelse return error.UnknownWindow;
        if (demand.retired) return error.UnknownWindow;
        demand.* = .{ .retired = true };
        try self.clearWindowDependencies(window);
    }

    pub fn validateTaskOwner(self: *Session, comptime Owner: type, owner: model.WeakModel(Owner)) !void {
        try self.requireOutsideDraw();
        try self.checkLive(Owner, owner.key);
    }

    pub fn scheduleUi(
        self: *Session,
        comptime Payload: type,
        comptime Owner: type,
        comptime handler: fn (*Owner, *Payload, *Session) void,
        owner: model.WeakModel(Owner),
        value: *Payload,
        deadline_ns: i96,
    ) !task.Handle {
        const service = self.task_service orelse return error.TasksNotStarted;
        return service.scheduleUi(Payload, Owner, handler, self, owner, value, deadline_ns);
    }

    pub fn spawnWorker(
        self: *Session,
        comptime Payload: type,
        comptime Owner: type,
        comptime work: fn (*Payload, std.Io) void,
        comptime handler: fn (*Owner, *Payload, *Session) void,
        owner: model.WeakModel(Owner),
        value: *Payload,
        options: task.Options(Owner),
    ) !task.Handle {
        const service = self.task_service orelse return error.TasksNotStarted;
        return service.spawnWorker(Payload, Owner, work, handler, self, owner, value, options);
    }

    pub fn cancelTask(self: *Session, handle: *task.Handle) bool {
        return if (self.task_service) |service| service.cancel(handle) else false;
    }

    /// Consume a handle without cancelling its weak-owner callback.
    pub fn detachTask(self: *Session, handle: *task.Handle) bool {
        return if (self.task_service) |service| service.detach(handle) else false;
    }

    /// Drain only between Session transactions; effects deliver through the
    /// existing deferOwned queue, never within a partial frame or borrow.
    pub fn drainTasks(self: *Session) !usize {
        if (self.frame_window != null or self.draw_depth != 0 or self.update_depth != 0 or
            self.borrow_depth != 0 or self.release_depth != 0 or self.effect_queue.draining)
        {
            return error.TransactionInProgress;
        }
        const service = self.task_service orelse return error.TasksNotStarted;
        return service.drain(self);
    }

    /// On UnfinishedWork the worker, payloads and executor remain live.
    /// Retry on the UI thread; do not deinit Session until this succeeds.
    pub fn shutdownTasks(self: *Session, timeout_ns: u64) !void {
        const service = self.task_service orelse return error.TasksNotStarted;
        if (self.frame_window != null or self.draw_depth != 0 or self.update_depth != 0 or
            self.borrow_depth != 0 or self.release_depth != 0 or self.effect_queue.draining)
        {
            return error.TransactionInProgress;
        }
        try service.shutdown(self, timeout_ns);
        self.task_service = null;
    }

    /// Register one live App; window IDs never repeat, including across Sessions.
    pub fn registerApp(self: *Session) !u64 {
        if (self.shutting_down) return error.SessionShuttingDown;
        if (self.live_apps == std.math.maxInt(u32)) return error.CapacityExceeded;
        try self.active_windows.ensureUnusedCapacity(self.gpa, 1);
        const window = try nextId(&next_window_id);
        self.active_windows.putAssumeCapacity(window, WindowDemand{});
        self.live_apps += 1;
        return window;
    }

    pub fn unregisterApp(self: *Session, window: u64) void {
        const removed = self.active_windows.remove(window);
        std.debug.assert(removed);
        std.debug.assert(self.frame_window != window);
        std.debug.assert(self.live_apps > 0);
        self.live_apps -= 1;
        var i: usize = 0;
        while (i < self.dependencies.items.len) {
            if (self.dependencies.items[i].window == window) {
                _ = self.dependencies.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn beginDraw(self: *Session) void {
        std.debug.assert(self.draw_depth < std.math.maxInt(u32));
        self.draw_depth += 1;
    }

    pub fn endDraw(self: *Session) void {
        std.debug.assert(self.draw_depth > 0);
        self.draw_depth -= 1;
    }

    /// Stage dependencies for one whole frame, including measure and paint.
    /// A failed frame must call finishFrame(window, false); it keeps the old
    /// dependency set and never publishes reads from the failed candidate.
    pub fn beginFrame(self: *Session, window: u64) !void {
        if (!self.hasWindow(window)) return error.UnknownWindow;
        if (self.frame_window != null) return error.FrameInProgress;
        if (self.update_depth != 0 or self.borrow_depth != 0 or self.release_depth != 0 or
            self.effect_queue.draining) return error.TransactionInProgress;
        self.frame_window = window;
        self.staged_dependencies.clearRetainingCapacity();
    }

    pub fn isFrameBuilding(self: *const Session) bool {
        return self.frame_window != null;
    }

    /// Only a successful App publication replaces the committed read set.
    /// All listener delivery waits for this boundary, never seeing half a frame.
    pub fn finishFrame(self: *Session, window: u64, committed: bool) void {
        self.endFrame(window, committed);
        self.pumpListeners();
    }

    /// Close the frame WITHOUT delivering queued listeners. An owner with
    /// work that must land between the close and the delivery ends the frame
    /// here, finishes that work, then calls `pumpListeners`. The read set
    /// commits and the in-flight demand settles exactly as `finishFrame`
    /// does; only the delivery moves.
    pub fn endFrame(self: *Session, window: u64, committed: bool) void {
        std.debug.assert(self.frame_window == window);
        std.debug.assert(self.draw_depth == 0);
        const demand = self.active_windows.getPtr(window).?;
        if (demand.in_flight and !committed) demand.dirty = true;
        demand.in_flight = false;
        if (committed) {
            var i: usize = 0;
            while (i < self.dependencies.items.len) {
                if (self.dependencies.items[i].window == window) {
                    _ = self.dependencies.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
            for (self.staged_dependencies.items) |dep| self.dependencies.appendAssumeCapacity(dep);
        }
        self.staged_dependencies.clearRetainingCapacity();
        self.frame_window = null;
    }

    /// Deliver queued effects and listener callbacks now. Suspended delivery
    /// makes this a no-op, so a caller that owes input to an endpoint can ask
    /// for the queue to stay put across its own work.
    pub fn pumpListeners(self: *Session) void {
        self.pump();
    }

    /// Suspend listener delivery. Effects keep queueing and nothing is
    /// dropped; `resumeDelivery` drains them. A model write made while
    /// delivery is suspended must not reach a listener before the work it
    /// belongs behind has finished.
    pub fn holdDelivery(self: *Session) void {
        self.defer_delivery = true;
    }

    /// Resume listener delivery and drain whatever queued while it was held.
    pub fn resumeDelivery(self: *Session) void {
        self.defer_delivery = false;
        self.pump();
    }

    /// Poll once per window. Repeated mutations coalesce until consumed; no
    /// dirty bit may be observed during an update or an unfinished frame.
    pub fn takeRedraw(self: *Session, window: u64) !bool {
        const demand = self.active_windows.getPtr(window) orelse return error.UnknownWindow;
        if (demand.retired) return error.UnknownWindow;
        if (self.frame_window != null or self.update_depth != 0 or
            self.borrow_depth != 0 or self.release_depth != 0 or
            self.effect_queue.draining) return error.TransactionInProgress;
        if (!demand.dirty) return false;
        demand.dirty = false;
        demand.in_flight = true;
        return true;
    }

    /// External frame demand joins the same coalesced per-window dirty set.
    /// Hosts also use this to re-arm consumption if beginFrame fails.
    pub fn requestRedraw(self: *Session, window: u64) !void {
        const demand = self.active_windows.getPtr(window) orelse return error.UnknownWindow;
        if (demand.retired) return error.UnknownWindow;
        demand.dirty = true;
    }

    /// Drop reads from a successfully replaced root. New roots start with no
    /// dependencies until their first committed frame.
    pub fn clearWindowDependencies(self: *Session, window: u64) !void {
        if (!self.active_windows.contains(window)) return error.UnknownWindow;
        if (self.frame_window != null) return error.FrameInProgress;
        var i: usize = 0;
        while (i < self.dependencies.items.len) {
            if (self.dependencies.items[i].window == window) {
                _ = self.dependencies.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Observe accepted updates to one model. The owner is weak by default:
    /// retaining/copying its handle is never implicit. The callback receives
    /// a weak subject key after the outermost update and may schedule more work.
    pub fn observe(
        self: *Session,
        comptime Subject: type,
        comptime Owner: type,
        source: model.WeakModel(Subject),
        owner: model.WeakModel(Owner),
        comptime handler: anytype,
    ) !subscription.Token {
        return self.addListener(.{
            .id = 0,
            .kind = .changed,
            .source = source.key,
            .source_marker = model.marker(Subject),
            .owner = owner.erase(),
            .handler = callback.modelHandler(Subject, Owner, handler),
        });
    }

    /// Observe final owner release, not each strong-ticket release. The weak
    /// subject is already invalid when called; the destructor has completed.
    pub fn observeRelease(
        self: *Session,
        comptime Subject: type,
        comptime Owner: type,
        source: model.WeakModel(Subject),
        owner: model.WeakModel(Owner),
        comptime handler: anytype,
    ) !subscription.Token {
        return self.addListener(.{
            .id = 0,
            .kind = .released,
            .source = source.key,
            .source_marker = model.marker(Subject),
            .owner = owner.erase(),
            .handler = callback.modelHandler(Subject, Owner, handler),
        });
    }

    /// A subscription sees every distinct typed event from one source, in
    /// emission order; registration during delivery starts with the next event.
    pub fn subscribe(
        self: *Session,
        comptime Event: type,
        comptime Source: type,
        comptime Owner: type,
        source: model.WeakModel(Source),
        owner: model.WeakModel(Owner),
        comptime handler: anytype,
    ) !subscription.Token {
        return self.addListener(.{
            .id = 0,
            .kind = .event,
            .source = source.key,
            .source_marker = model.marker(Source),
            .event_marker = model.marker(Event),
            .owner = owner.erase(),
            .handler = callback.eventHandler(Event, Owner, handler),
        });
    }

    pub fn observeGlobal(
        self: *Session,
        comptime Global: type,
        comptime Owner: type,
        owner: model.WeakModel(Owner),
        comptime handler: anytype,
    ) !subscription.Token {
        if (self.global_store.find(model.marker(Global)) == null) return error.GlobalNotFound;
        return self.addListener(.{
            .id = 0,
            .kind = .global_changed,
            .event_marker = model.marker(Global),
            .owner = owner.erase(),
            .handler = callback.globalHandler(Global, Owner, handler),
        });
    }

    /// A copied Token does not gain cancellation ownership. Either copy can
    /// cancel once; wrong-Session and already-retired tokens return false.
    pub fn unsubscribe(self: *Session, token: *subscription.Token) bool {
        if (token.session != self.id or token.id == 0) return false;
        for (self.listeners.items) |*entry| {
            if (entry.id == token.id and entry.active) {
                entry.active = false;
                token.* = .{};
                if (!self.effect_queue.draining) self.compactListeners();
                return true;
            }
        }
        return false;
    }

    /// Move a payload only after allocating its persistent storage. A type
    /// with owned members must implement `deinit(*T, *Session)`; borrowed
    /// pointers/slices must never be placed in a queued payload. Delivery
    /// borrows `*const Event` only until the handler returns.
    pub fn emit(
        self: *Session,
        comptime Event: type,
        comptime Source: type,
        source: model.WeakModel(Source),
        value: *Event,
    ) !void {
        try self.requireOutsideDraw();
        try self.checkLive(Source, source.key);
        try self.effect_queue.items.ensureUnusedCapacity(self.gpa, 1);
        const payload = try self.gpa.create(Event);
        payload.* = value.*;
        // SAFETY: the queued effect owns the value after this move.
        value.* = undefined;
        self.effect_queue.items.appendAssumeCapacity(.{
            .event = .{
                .source = source.erase(),
                .marker = model.marker(Event),
                .payload = .{ .ptr = payload, .destroy = destroyPayload(Event) },
            },
        });
        self.pump();
    }

    /// Move deferred work into the Session queue. The owner is weak; releasing
    /// it before delivery skips invocation but still drops the payload once.
    pub fn deferOwned(
        self: *Session,
        comptime Payload: type,
        comptime Owner: type,
        owner: model.WeakModel(Owner),
        value: *Payload,
        comptime handler: anytype,
    ) !void {
        try self.queueDeferred(Payload, Owner, owner, null, value, handler);
    }

    /// Explicitly retain an independent strong ticket until invocation/drop.
    /// Do not use a copied strong handle: only retain creates a new ticket.
    pub fn deferRetained(
        self: *Session,
        comptime Payload: type,
        comptime Owner: type,
        owner: model.Model(Owner),
        value: *Payload,
        comptime handler: anytype,
    ) !void {
        try self.queueDeferred(Payload, Owner, owner.weak(), owner, value, handler);
    }

    fn queueDeferred(
        self: *Session,
        comptime Payload: type,
        comptime Owner: type,
        owner: model.WeakModel(Owner),
        strong: ?model.Model(Owner),
        value: *Payload,
        comptime handler: anytype,
    ) !void {
        try self.requireOutsideDraw();
        try self.checkLive(Owner, owner.key);
        try self.effect_queue.items.ensureUnusedCapacity(self.gpa, 1);
        const payload = try self.gpa.create(Payload);
        errdefer self.gpa.destroy(payload);
        var retained: ?ErasedModel = null;
        if (strong) |ticket| {
            var extra = try self.retain(Owner, ticket);
            retained = extra.erase();
        }
        payload.* = value.*;
        // SAFETY: the deferred effect owns the payload after this move.
        value.* = undefined;
        self.effect_queue.items.appendAssumeCapacity(.{ .deferred = .{
            .owner = owner.erase(),
            .strong_owner = retained,
            .payload = .{ .ptr = payload, .destroy = destroyPayload(Payload) },
            .invoke = callback.deferredHandler(Payload, Owner, handler),
        } });
        self.pump();
    }

    fn addListener(self: *Session, entry: subscription.Entry) !subscription.Token {
        try self.requireOutsideDraw();
        try self.checkLiveErased(entry.owner);
        if (entry.kind != .global_changed) {
            try self.checkLiveErased(.{
                .key = entry.source,
                .type_marker = entry.source_marker,
            });
        }
        if (self.next_listener == std.math.maxInt(u64)) return error.CapacityExceeded;
        try self.listeners.ensureUnusedCapacity(self.gpa, 1);
        var installed = entry;
        installed.id = self.next_listener;
        self.next_listener += 1;
        self.listeners.appendAssumeCapacity(installed);
        return .{ .session = self.id, .id = installed.id };
    }

    fn checkLive(self: *Session, comptime T: type, key: ModelKey) !void {
        try self.checkLiveErased(.{ .key = key, .type_marker = model.marker(T) });
    }

    fn checkLiveErased(self: *Session, weak: ErasedWeakModel) !void {
        const slot = (try self.slotForKey(weak.key)) orelse return error.StaleModel;
        if (slot.type_marker != weak.type_marker) return error.WrongType;
        if (slot.state == .reserved) return error.UninitializedModel;
        if (slot.state != .live) return error.StaleModel;
    }

    fn compactListeners(self: *Session) void {
        var write_index: usize = 0;
        for (self.listeners.items) |entry| {
            if (!entry.active) continue;
            self.listeners.items[write_index] = entry;
            write_index += 1;
        }
        self.listeners.items.len = write_index;
    }

    fn pump(self: *Session) void {
        if (self.defer_delivery) return;
        if (self.update_depth != 0 or self.borrow_depth != 0 or self.release_depth != 0 or
            self.frame_window != null or self.effect_queue.draining) return;
        self.effect_queue.draining = true;
        defer {
            self.effect_queue.draining = false;
            self.effect_queue.items.clearRetainingCapacity();
            self.effect_queue.head = 0;
            self.compactListeners();
        }
        var delivered: usize = 0;
        while (self.effect_queue.head < self.effect_queue.items.items.len) {
            if (delivered == maximum_effects_per_drain) @panic("effect drain limit exceeded");
            const effect = self.effect_queue.items.items[self.effect_queue.head];
            self.effect_queue.head += 1;
            delivered += 1;
            self.dispatch(effect);
            effect.drop(@ptrCast(self));
        }
    }

    fn dispatch(self: *Session, effect: effects.Effect) void {
        switch (effect) {
            .changed => |source| self.dispatchListeners(.changed, source, model.marker(void), null),
            .released => |source| {
                self.dispatchListeners(.released, source, model.marker(void), null);
                for (self.listeners.items) |*entry| {
                    if (entry.kind == .released and sameKey(entry.source, source.key)) {
                        entry.active = false;
                    }
                }
            },
            .event => |event| self.dispatchListeners(.event, event.source, event.marker, event.payload.ptr),
            .global_changed => |marker| {
                const global = self.global_store.find(marker) orelse return;
                std.debug.assert(!global.writer);
                std.debug.assert(global.readers < std.math.maxInt(u32));
                global.readers += 1;
                self.borrow_depth += 1;
                self.dispatchListeners(.global_changed, .{
                    .key = .{},
                    .type_marker = model.marker(void),
                }, marker, global.payload);
                self.borrow_depth -= 1;
                global.readers -= 1;
            },
            .deferred => |deferred| {
                self.invokeOwner(deferred.owner, deferred.invoke, deferred.payload.ptr);
                if (deferred.strong_owner) |strong| {
                    var ticket = strong;
                    self.releaseErased(&ticket) catch @panic("deferred owner release failed");
                }
            },
        }
    }

    fn dispatchListeners(
        self: *Session,
        kind: subscription.Kind,
        source: ErasedWeakModel,
        event_marker: *const u8,
        payload: ?*anyopaque,
    ) void {
        // Snapshot the registration boundary; callbacks can add/tombstone
        // entries and grow the list without invalidating this index.
        const limit = self.listeners.items.len;
        var i: usize = 0;
        while (i < limit) : (i += 1) {
            const entry = self.listeners.items[i];
            if (!entry.active or entry.kind != kind) continue;
            if (kind == .global_changed) {
                if (entry.event_marker != event_marker) continue;
            } else {
                if (!sameKey(entry.source, source.key) or
                    entry.source_marker != source.type_marker) continue;
                if (kind == .event and entry.event_marker != event_marker) continue;
            }
            if (kind == .changed and !self.isLive(source)) continue;
            if (kind == .released or kind == .changed) {
                self.invokeOwner(entry.owner, entry.handler, @ptrCast(&source.key));
            } else {
                self.invokeOwner(entry.owner, entry.handler, payload.?);
            }
        }
    }

    fn isLive(self: *Session, weak: ErasedWeakModel) bool {
        self.checkLiveErased(weak) catch return false;
        return true;
    }

    fn invokeOwner(
        self: *Session,
        weak: ErasedWeakModel,
        handler: subscription.Handler,
        payload: *const anyopaque,
    ) void {
        const slot = (self.slotForKey(weak.key) catch return) orelse return;
        if (slot.state != .live or slot.type_marker != weak.type_marker or slot.writer) return;
        std.debug.assert(slot.readers < std.math.maxInt(u32));
        slot.readers += 1;
        self.borrow_depth += 1;
        handler(slot.payload, payload, @ptrCast(self));
        self.borrow_depth -= 1;
        slot.readers -= 1;
        self.pump();
    }

    /// Move the source only after all allocations and ticket admission succeed.
    pub fn create(self: *Session, comptime T: type, value: *T) !model.Model(T) {
        var reservation = try self.reserve(T);
        errdefer self.cancel(T, &reservation) catch @panic("model reservation rollback failed");
        return self.insert(T, &reservation, value);
    }

    pub fn reserve(self: *Session, comptime T: type) !model.Reservation(T) {
        try self.requireOutsideDraw();
        if (self.active_slots == std.math.maxInt(u32)) return error.CapacityExceeded;
        try self.prepareSlot();
        try self.prepareTicket();
        const slot_index = try self.takeSlot();
        const slot = self.slots.items[slot_index];
        std.debug.assert(slot.state == .free);
        slot.state = .reserved;
        slot.type_marker = model.marker(T);
        slot.strong = 0;
        slot.readers = 0;
        slot.writer = false;
        self.active_slots += 1;
        return .{
            .key = .{ .store = self.id, .slot = slot_index, .generation = slot.generation },
            .ticket = self.takeTicket(slot_index),
            .pending = .reservation,
        };
    }

    pub fn insert(
        self: *Session,
        comptime T: type,
        reservation: *model.Reservation(T),
        value: *T,
    ) !model.Model(T) {
        try self.requireOutsideDraw();
        const slot = try self.ownedSlot(T, reservation.key, reservation.ticket);
        if (slot.state != .reserved) return error.AlreadyReleased;
        const payload = try self.gpa.create(T);
        // The source may alias the reservation's key or ticket.
        const result: model.Model(T) = .{
            .key = reservation.key,
            .ticket = reservation.ticket,
        };
        payload.* = value.*;
        // SAFETY: the Session now owns the value; the caller must not use the moved source.
        value.* = undefined;
        slot.payload = payload;
        slot.destroy = destroyModel(T);
        slot.strong = 1;
        slot.state = .live;
        reservation.* = .{};
        return result;
    }

    pub fn cancel(self: *Session, comptime T: type, reservation: *model.Reservation(T)) !void {
        try self.requireOutsideDraw();
        const slot = try self.ownedSlot(T, reservation.key, reservation.ticket);
        if (slot.state != .reserved) return error.AlreadyReleased;
        self.retireTicket(reservation.ticket);
        self.retireSlot(reservation.key.slot, slot);
        reservation.* = .{};
    }

    pub fn retain(self: *Session, comptime T: type, handle: model.Model(T)) !model.Model(T) {
        try self.requireOutsideDraw();
        const slot = try self.ownedSlot(T, handle.key, handle.ticket);
        if (slot.state != .live) return error.UninitializedModel;
        if (slot.strong == std.math.maxInt(u32)) return error.CapacityExceeded;
        try self.prepareTicket();
        const ticket = self.takeTicket(handle.key.slot);
        slot.strong += 1;
        return .{ .key = handle.key, .ticket = ticket };
    }

    pub fn release(self: *Session, comptime T: type, handle: *model.Model(T)) !void {
        try self.requireOutsideDraw();
        const slot = try self.ownedSlot(T, handle.key, handle.ticket);
        if (slot.state != .live) return error.UninitializedModel;
        if (slot.writer or slot.readers != 0) return error.ConflictingAccess;
        try self.prepareRelease(slot, handle.key);
        const key = handle.key;
        const ticket = handle.ticket;
        handle.* = .{};
        self.releaseOwned(key, ticket, slot);
    }

    /// Check that an App root can be retired before replacing GPU mounts.
    /// Callers must not reenter Session between this check and release.
    pub fn canReleaseErased(self: *Session, handle: ErasedModel) !void {
        try self.requireOutsideDraw();
        const slot = try self.ownedSlotErased(handle.key, handle.ticket, handle.type_marker);
        if (slot.state != .live) return error.UninitializedModel;
        if (slot.writer or slot.readers != 0) return error.ConflictingAccess;
    }

    /// Release an erased owner without temporarily duplicating its ticket.
    pub fn releaseErased(self: *Session, handle: *ErasedModel) !void {
        try self.canReleaseErased(handle.*);
        const slot = try self.ownedSlotErased(handle.key, handle.ticket, handle.type_marker);
        try self.prepareRelease(slot, handle.key);
        const key = handle.key;
        const ticket = handle.ticket;
        handle.* = .{};
        self.releaseOwned(key, ticket, slot);
    }

    pub fn upgrade(self: *Session, comptime T: type, weak: model.WeakModel(T)) !?model.Model(T) {
        try self.requireOutsideDraw();
        const slot = try self.slotForKey(weak.key);
        if (slot == null) return null;
        const live_slot = slot.?;
        if (live_slot.type_marker != model.marker(T)) return error.WrongType;
        if (live_slot.state == .reserved) return error.UninitializedModel;
        if (live_slot.state != .live) return null;
        if (live_slot.strong == std.math.maxInt(u32)) return error.CapacityExceeded;
        try self.prepareTicket();
        const ticket = self.takeTicket(weak.key.slot);
        live_slot.strong += 1;
        return .{ .key = weak.key, .ticket = ticket };
    }

    /// Cast transfers the strong ticket only when the exact type matches.
    pub fn cast(self: *Session, comptime T: type, handle: *ErasedModel) !model.Model(T) {
        const slot = try self.ownedSlotErased(handle.key, handle.ticket, handle.type_marker);
        if (slot.type_marker != model.marker(T)) return error.WrongType;
        if (slot.state != .live) return error.UninitializedModel;
        const result: model.Model(T) = .{ .key = handle.key, .ticket = handle.ticket };
        handle.* = .{};
        return result;
    }

    pub fn castWeak(self: *Session, comptime T: type, handle: ErasedWeakModel) !model.WeakModel(T) {
        if (handle.type_marker != model.marker(T)) return error.WrongType;
        const slot = (try self.slotForKey(handle.key)) orelse return error.StaleModel;
        if (slot.type_marker != handle.type_marker) return error.WrongType;
        if (slot.state != .live and slot.state != .reserved) return error.StaleModel;
        return .{ .key = handle.key };
    }

    /// Synchronous scoped borrow. Pointer lifetimes end at callback return.
    /// Listener effects emitted inside a read wait until its borrow ends.
    pub fn read(
        self: *Session,
        comptime T: type,
        ref: anytype,
        user: anytype,
        comptime handler: anytype,
    ) !void {
        if (self.shutting_down) return error.SessionShuttingDown;
        const slot = try self.readableSlot(T, ref);
        if (slot.writer) return error.ConflictingAccess;
        if (slot.readers == std.math.maxInt(u32)) return error.CapacityExceeded;
        slot.readers += 1;
        self.borrow_depth += 1;
        const value: *const T = @ptrCast(@alignCast(slot.payload));
        const result: anyerror!void = @call(.auto, handler, .{ value, user });
        slot.readers -= 1;
        self.borrow_depth -= 1;
        self.pump();
        try result;
    }

    /// Draw-scoped read. Dependencies publish only after finishFrame(true).
    /// A failed borrow does not create a dependency or enqueue an effect.
    pub fn readWindow(
        self: *Session,
        comptime T: type,
        window: u64,
        ref: anytype,
        user: anytype,
        comptime handler: anytype,
    ) !void {
        if (self.frame_window != window) return error.FrameNotActive;
        const dependency: Dependency = .{ .window = window, .target = .{ .model = ref.key } };
        try self.read(T, ref, user, handler);
        const fresh = try self.prepareDependency(dependency);
        if (fresh) self.staged_dependencies.appendAssumeCapacity(dependency);
    }

    /// An accepted update invalidates dependent windows and queues a typed
    /// observation before calling user code. Nested updates therefore enqueue
    /// observations in admission order; delivery waits for the outer borrow.
    /// Callback errors release the borrow but do not roll back prior writes.
    pub fn update(
        self: *Session,
        comptime T: type,
        ref: anytype,
        user: anytype,
        comptime handler: anytype,
    ) !void {
        try self.requireOutsideDraw();
        const slot = try self.readableSlot(T, ref);
        if (slot.writer or slot.readers != 0) return error.ConflictingAccess;
        const source: ErasedWeakModel = .{ .key = ref.key, .type_marker = model.marker(T) };
        const observed = self.hasListener(.changed, source);
        if (observed) try self.effect_queue.items.ensureUnusedCapacity(self.gpa, 1);
        self.invalidate(.{ .model = ref.key });
        if (observed) self.effect_queue.items.appendAssumeCapacity(.{ .changed = source });
        slot.writer = true;
        self.update_depth += 1;
        const value: *T = @ptrCast(@alignCast(slot.payload));
        const result: anyerror!void = @call(.auto, handler, .{ value, user });
        slot.writer = false;
        self.update_depth -= 1;
        self.pump();
        try result;
    }

    /// Install one typed global. The caller transfers owned members on
    /// success; later changes must use updateGlobal's scoped mutable borrow.
    pub fn putGlobal(self: *Session, comptime T: type, value: *T) !void {
        try self.requireOutsideDraw();
        if (self.global_store.find(model.marker(T)) != null) return error.GlobalExists;
        try self.global_store.entries.ensureUnusedCapacity(self.gpa, 1);
        const entry = try self.gpa.create(globals.Entry);
        errdefer self.gpa.destroy(entry);
        const payload = try self.gpa.create(T);
        payload.* = value.*;
        // SAFETY: the global store owns the value after this move.
        value.* = undefined;
        entry.* = .{ .marker = model.marker(T), .payload = payload, .destroy = destroyPayload(T) };
        self.global_store.entries.appendAssumeCapacity(entry);
    }

    pub fn readGlobal(
        self: *Session,
        comptime T: type,
        user: anytype,
        comptime handler: anytype,
    ) !void {
        if (self.shutting_down) return error.SessionShuttingDown;
        const entry = self.global_store.find(model.marker(T)) orelse return error.GlobalNotFound;
        if (entry.writer) return error.ConflictingAccess;
        if (entry.readers == std.math.maxInt(u32)) return error.CapacityExceeded;
        entry.readers += 1;
        self.borrow_depth += 1;
        const value: *const T = @ptrCast(@alignCast(entry.payload));
        const result: anyerror!void = @call(.auto, handler, .{ value, user });
        self.borrow_depth -= 1;
        entry.readers -= 1;
        self.pump();
        try result;
    }

    pub fn readGlobalWindow(
        self: *Session,
        comptime T: type,
        window: u64,
        user: anytype,
        comptime handler: anytype,
    ) !void {
        if (self.frame_window != window) return error.FrameNotActive;
        const dependency: Dependency = .{ .window = window, .target = .{ .global = model.marker(T) } };
        try self.readGlobal(T, user, handler);
        const fresh = try self.prepareDependency(dependency);
        if (fresh) self.staged_dependencies.appendAssumeCapacity(dependency);
    }

    /// Global writes use the same borrow admission, deferral and window
    /// coalescing rules as model updates. Callback errors do not undo writes.
    pub fn updateGlobal(
        self: *Session,
        comptime T: type,
        user: anytype,
        comptime handler: anytype,
    ) !void {
        try self.requireOutsideDraw();
        const entry = self.global_store.find(model.marker(T)) orelse return error.GlobalNotFound;
        if (entry.writer or entry.readers != 0) return error.ConflictingAccess;
        var observed = false;
        for (self.listeners.items) |listener| {
            if (listener.active and listener.kind == .global_changed and
                listener.event_marker == model.marker(T))
            {
                observed = true;
                break;
            }
        }
        if (observed) try self.effect_queue.items.ensureUnusedCapacity(self.gpa, 1);
        self.invalidate(.{ .global = model.marker(T) });
        if (observed) self.effect_queue.items.appendAssumeCapacity(.{
            .global_changed = model.marker(T),
        });
        entry.writer = true;
        self.update_depth += 1;
        const value: *T = @ptrCast(@alignCast(entry.payload));
        const result: anyerror!void = @call(.auto, handler, .{ value, user });
        entry.writer = false;
        self.update_depth -= 1;
        self.pump();
        try result;
    }

    /// Removal invalidates dependent windows but does not call observers with
    /// a dangling global value; their tokens become inactive.
    pub fn removeGlobal(self: *Session, comptime T: type) !void {
        try self.requireOutsideDraw();
        const marker = model.marker(T);
        const entry = self.global_store.find(marker) orelse return error.GlobalNotFound;
        if (entry.writer or entry.readers != 0) return error.ConflictingAccess;
        self.invalidate(.{ .global = marker });
        var dependency_index: usize = 0;
        while (dependency_index < self.dependencies.items.len) {
            if (sameTarget(self.dependencies.items[dependency_index].target, .{
                .global = marker,
            })) {
                _ = self.dependencies.orderedRemove(dependency_index);
            } else {
                dependency_index += 1;
            }
        }
        for (self.listeners.items) |*listener| {
            if (listener.kind == .global_changed and listener.event_marker == marker) {
                listener.active = false;
            }
        }
        for (self.global_store.entries.items, 0..) |item, i| {
            if (item != entry) continue;
            _ = self.global_store.entries.orderedRemove(i);
            break;
        }
        self.release_depth += 1;
        entry.destroy(entry.payload, @ptrCast(self));
        self.gpa.destroy(entry);
        self.release_depth -= 1;
        self.pump();
    }

    fn requireOutsideDraw(self: *const Session) !void {
        if (self.shutting_down) return error.SessionShuttingDown;
        if (self.draw_depth != 0 or self.frame_window != null) return error.DrawMutationForbidden;
    }

    fn prepareDependency(self: *Session, dependency: Dependency) !bool {
        for (self.staged_dependencies.items) |existing| {
            if (sameDependency(existing, dependency)) return false;
        }
        try self.dependencies.ensureTotalCapacity(
            self.gpa,
            self.dependencies.items.len + self.staged_dependencies.items.len + 1,
        );
        try self.staged_dependencies.ensureUnusedCapacity(self.gpa, 1);
        return true;
    }

    fn invalidate(self: *Session, target: Target) void {
        for (self.dependencies.items) |dependency| {
            if (!sameTarget(dependency.target, target)) continue;
            if (self.active_windows.getPtr(dependency.window)) |demand| {
                if (!demand.retired) demand.dirty = true;
            }
        }
    }

    fn hasListener(self: *const Session, kind: subscription.Kind, source: ErasedWeakModel) bool {
        for (self.listeners.items) |entry| {
            if (entry.active and entry.kind == kind and
                entry.source_marker == source.type_marker and sameKey(entry.source, source.key))
            {
                return true;
            }
        }
        return false;
    }

    fn readableSlot(self: *Session, comptime T: type, ref: anytype) !*Slot {
        const Ref = @TypeOf(ref);
        const slot = if (Ref == model.Model(T))
            try self.ownedSlot(T, ref.key, ref.ticket)
        else if (Ref == model.WeakModel(T))
            (try self.slotForKey(ref.key)) orelse return error.StaleModel
        else
            @compileError("Session.read/update requires Model(T) or WeakModel(T); " ++
                "a Reservation(T) carries no value yet");
        if (slot.type_marker != model.marker(T)) return error.WrongType;
        if (slot.state == .reserved) return error.UninitializedModel;
        if (slot.state != .live) return error.StaleModel;
        return slot;
    }

    fn slotForKey(self: *Session, key: ModelKey) !?*Slot {
        if (key.store != self.id) return error.WrongStore;
        if (key.slot >= self.slots.items.len) return null;
        const slot = self.slots.items[key.slot];
        if (slot.generation != key.generation) return null;
        if (slot.state == .free or slot.state == .quarantined or slot.state == .retiring) {
            return null;
        }
        return slot;
    }

    fn ownedSlot(self: *Session, comptime T: type, key: ModelKey, ticket: u64) !*Slot {
        return self.ownedSlotErased(key, ticket, model.marker(T));
    }

    fn ownedSlotErased(
        self: *Session,
        key: ModelKey,
        ticket: u64,
        type_marker: *const u8,
    ) !*Slot {
        if (ticket == 0) return error.AlreadyReleased;
        if (key.store != self.id) return error.WrongStore;
        const index: u32 = @truncate(ticket);
        const generation: u32 = @truncate(ticket >> 32);
        if (index >= self.tickets.items.len) return error.AlreadyReleased;
        const entry = self.tickets.items[index];
        if (!entry.active or entry.generation != generation or entry.slot != key.slot) {
            return error.AlreadyReleased;
        }
        const slot = (try self.slotForKey(key)) orelse return error.StaleModel;
        if (slot.type_marker != type_marker) return error.WrongType;
        return slot;
    }

    // The caller must consume its handle before a destructor can reenter Session.
    fn prepareRelease(self: *Session, slot: *const Slot, key: ModelKey) !void {
        if (slot.strong != 1) return;
        const weak: ErasedWeakModel = .{ .key = key, .type_marker = slot.type_marker };
        if (self.hasListener(.released, weak)) {
            try self.effect_queue.items.ensureUnusedCapacity(self.gpa, 1);
        }
    }

    fn releaseOwned(self: *Session, key: ModelKey, ticket: u64, slot: *Slot) void {
        std.debug.assert(slot.state == .live);
        std.debug.assert(!slot.writer);
        std.debug.assert(slot.readers == 0);
        std.debug.assert(slot.strong > 0);
        self.retireTicket(ticket);
        slot.strong -= 1;
        if (slot.strong != 0) return;
        self.invalidate(.{ .model = key });
        var i: usize = 0;
        while (i < self.dependencies.items.len) {
            const target = self.dependencies.items[i].target;
            if (sameTarget(target, .{ .model = key })) {
                _ = self.dependencies.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Invalidate weak identity and the last ticket before any destructor
        // or release callback can reenter. Quarantine prevents slot reuse.
        slot.state = .retiring;
        const weak: ErasedWeakModel = .{ .key = key, .type_marker = slot.type_marker };
        if (self.hasListener(.released, weak)) {
            self.effect_queue.items.appendAssumeCapacity(.{ .released = weak });
        }
        for (self.listeners.items) |*entry| {
            if (sameKey(entry.owner.key, key)) entry.active = false;
        }
        self.release_depth += 1;
        const payload = slot.payload;
        const destroy = slot.destroy;
        destroy(payload, self);
        self.retireSlot(key.slot, slot);
        self.release_depth -= 1;
        self.pump();
    }

    fn prepareSlot(self: *Session) !void {
        if (self.free_slot != null) return;
        if (self.slots.items.len >= std.math.maxInt(u32)) return error.CapacityExceeded;
        try self.slots.ensureUnusedCapacity(self.gpa, 1);
    }

    fn takeSlot(self: *Session) !u32 {
        if (self.free_slot) |index| {
            const slot = self.slots.items[index];
            self.free_slot = slot.next_free;
            slot.next_free = null;
            return index;
        }
        const slot = try self.gpa.create(Slot);
        // SAFETY: payload and destructor are unreadable in a free slot and
        // are initialized by insert before the state becomes live.
        slot.* = .{ .type_marker = model.marker(void), .payload = undefined, .destroy = undefined };
        const index: u32 = @intCast(self.slots.items.len);
        self.slots.appendAssumeCapacity(slot);
        return index;
    }

    fn retireSlot(self: *Session, index: u32, slot: *Slot) void {
        std.debug.assert(slot.readers == 0);
        std.debug.assert(!slot.writer);
        std.debug.assert(self.active_slots > 0);
        self.active_slots -= 1;
        slot.strong = 0;
        if (slot.generation == std.math.maxInt(u32)) {
            slot.state = .quarantined;
        } else {
            slot.generation += 1;
            slot.state = .free;
            slot.next_free = self.free_slot;
            self.free_slot = index;
        }
    }

    fn prepareTicket(self: *Session) !void {
        if (self.free_ticket != null) return;
        if (self.tickets.items.len >= std.math.maxInt(u32)) return error.CapacityExceeded;
        try self.tickets.ensureUnusedCapacity(self.gpa, 1);
    }

    fn takeTicket(self: *Session, slot_index: u32) u64 {
        const index: u32 = if (self.free_ticket) |reused| blk: {
            const entry = &self.tickets.items[reused];
            self.free_ticket = entry.next_free;
            entry.slot = slot_index;
            entry.active = true;
            entry.next_free = null;
            break :blk reused;
        } else blk: {
            const next: u32 = @intCast(self.tickets.items.len);
            self.tickets.appendAssumeCapacity(.{ .slot = slot_index });
            break :blk next;
        };
        return (@as(u64, self.tickets.items[index].generation) << 32) | index;
    }

    fn retireTicket(self: *Session, ticket: u64) void {
        const index: u32 = @truncate(ticket);
        const entry = &self.tickets.items[index];
        std.debug.assert(entry.active);
        entry.active = false;
        if (entry.generation == std.math.maxInt(u32)) return;
        entry.generation += 1;
        entry.next_free = self.free_ticket;
        self.free_ticket = index;
    }
};

fn destroyModel(comptime T: type) *const fn (*anyopaque, *Session) void {
    return struct {
        fn destroy(payload: *anyopaque, session: *Session) void {
            const value: *T = @ptrCast(@alignCast(payload));
            if (comptime hasDeinit(T)) value.deinit(session);
            session.gpa.destroy(value);
        }
    }.destroy;
}

fn destroyPayload(comptime T: type) *const fn (*anyopaque, *anyopaque) void {
    return struct {
        fn destroy(payload: *anyopaque, erased_session: *anyopaque) void {
            const session: *Session = @ptrCast(@alignCast(erased_session));
            const value: *T = @ptrCast(@alignCast(payload));
            if (comptime hasDeinit(T)) value.deinit(session);
            session.gpa.destroy(value);
        }
    }.destroy;
}

fn sameKey(a: ModelKey, b: ModelKey) bool {
    return a.store == b.store and a.slot == b.slot and a.generation == b.generation;
}

fn sameTarget(a: Target, b: Target) bool {
    return switch (a) {
        .model => |key| switch (b) {
            .model => |other| sameKey(key, other),
            else => false,
        },
        .global => |marker| switch (b) {
            .global => |other| marker == other,
            else => false,
        },
    };
}

fn sameDependency(a: Dependency, b: Dependency) bool {
    return a.window == b.window and sameTarget(a.target, b.target);
}

fn hasDeinit(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "deinit"),
        else => false,
    };
}

fn nextId(counter: *std.atomic.Value(u64)) !u64 {
    var current = counter.load(.monotonic);
    while (current != 0 and current != std.math.maxInt(u64)) {
        if (counter.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |observed| {
            current = observed;
        } else {
            return current;
        }
    }
    return error.IdExhausted;
}

test "a failed insert keeps its reservation and source valid" {
    const Value = struct { count: u32 };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var session = try Session.init(failing.allocator());
    defer session.deinit() catch unreachable;
    var reservation = try session.reserve(Value);
    var value: Value = .{ .count = 73 };

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, session.insert(Value, &reservation, &value));
    try std.testing.expectEqual(@as(u32, 73), value.count);
    try std.testing.expectError(error.LiveModels, session.deinit());
    failing.fail_index = std.math.maxInt(usize);

    var owner = try session.insert(Value, &reservation, &value);
    try session.release(Value, &owner);
}

test "cancelled reservations never run a destructor" {
    const Value = struct {
        const Self = @This();
        var calls: u32 = 0;
        pub fn deinit(self: *Self, _: *Session) void {
            calls += 1;
            self.* = undefined;
        }
    };
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var reservation = try session.reserve(Value);
    const copy = reservation;
    const weak = reservation.weak();
    try session.cancel(Value, &reservation);
    try std.testing.expectEqual(@as(u32, 0), Value.calls);
    var duplicate = copy;
    try std.testing.expectError(error.AlreadyReleased, session.cancel(Value, &duplicate));
    try std.testing.expect((try session.upgrade(Value, weak)) == null);
    var value: Value = .{};
    var owner = try session.create(Value, &value);
    try session.release(Value, &owner);
    try std.testing.expectEqual(@as(u32, 1), Value.calls);
}

test "callback errors release borrows while release inside a borrow is denied" {
    const Reentry = struct {
        const Self = @This();
        session: *Session,
        owner: *model.Model(u32),

        fn failBorrow(_: *const u32, self: *Self) !void {
            try std.testing.expectError(error.ConflictingAccess, self.session.release(u32, self.owner));
            return error.CallbackFailed;
        }
    };
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var value: u32 = 9;
    var owner = try session.create(u32, &value);
    var reentry: Reentry = .{ .session = &session, .owner = &owner };
    try std.testing.expectError(
        error.CallbackFailed,
        session.read(u32, owner, &reentry, Reentry.failBorrow),
    );
    try session.release(u32, &owner);
}

test "same-size distinct types cannot be cast through erased weak handles" {
    const First = struct { value: u32 };
    const Second = struct { value: u32 };
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var value: First = .{ .value = 8 };
    var owner = try session.create(First, &value);
    defer session.release(First, &owner) catch unreachable;
    const erased = owner.weak().erase();
    try std.testing.expectError(error.WrongType, session.castWeak(Second, erased));
}

test "slot memory stays stable when a read callback adds another model" {
    const Reentry = struct {
        const Self = @This();
        session: *Session,

        fn addDuringRead(_: *const u32, self: *Self) !void {
            var second_value: u32 = 2;
            var second = try self.session.create(u32, &second_value);
            try self.session.release(u32, &second);
        }
    };
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var first_value: u32 = 1;
    var first = try session.create(u32, &first_value);
    defer session.release(u32, &first) catch unreachable;
    var reentry: Reentry = .{ .session = &session };
    try session.read(u32, first, &reentry, Reentry.addDuringRead);
}

test "exhausted slot and ticket generations are quarantined" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var reservation = try session.reserve(u8);
    const old_slot = reservation.key.slot;
    const old_ticket: u32 = @truncate(reservation.ticket);
    const exhausted = std.math.maxInt(u32);
    session.slots.items[old_slot].generation = exhausted;
    session.tickets.items[old_ticket].generation = exhausted;
    reservation.key.generation = exhausted;
    reservation.ticket = (@as(u64, exhausted) << 32) | old_ticket;
    try session.cancel(u8, &reservation);

    var next = try session.reserve(u8);
    try std.testing.expect(next.key.slot != old_slot);
    try std.testing.expect(@as(u32, @truncate(next.ticket)) != old_ticket);
    try session.cancel(u8, &next);
}

test "live App registrations prevent shutdown and window IDs never repeat" {
    var first = try Session.init(std.testing.allocator);
    var second = try Session.init(std.testing.allocator);
    const first_window = try first.registerApp();
    const second_window = try second.registerApp();
    try std.testing.expect(first_window != second_window);
    try std.testing.expectError(error.LiveApps, first.deinit());
    first.unregisterApp(first_window);
    second.unregisterApp(second_window);
    try first.deinit();
    try second.deinit();
}

test "draw callbacks may read but cannot mutate shared models" {
    const Callbacks = struct {
        fn readValue(value: *const u32, observed: *u32) !void {
            observed.* = value.*;
        }
        fn changeValue(value: *u32, _: void) !void {
            value.* += 1;
        }
    };
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var value: u32 = 4;
    var owner = try session.create(u32, &value);
    defer session.release(u32, &owner) catch unreachable;

    var observed: u32 = 0;
    {
        session.beginDraw();
        defer session.endDraw();
        try session.read(u32, owner, &observed, Callbacks.readValue);
        try std.testing.expectEqual(@as(u32, 4), observed);
        try std.testing.expectError(
            error.DrawMutationForbidden,
            session.update(u32, owner, {}, Callbacks.changeValue),
        );
    }
    try session.update(u32, owner, {}, Callbacks.changeValue);
    try session.read(u32, owner, &observed, Callbacks.readValue);
    try std.testing.expectEqual(@as(u32, 5), observed);
}

test "erased ownership transfer consumes one ticket and double release fails" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var value: u32 = 19;
    var owner = try session.create(u32, &value);
    var erased = owner.erase();
    var copy = erased;
    try session.releaseErased(&erased);
    try std.testing.expectError(error.AlreadyReleased, session.releaseErased(&copy));
    try std.testing.expectError(error.AlreadyReleased, session.releaseErased(&erased));
}

test "nested reads coexist and a different model can update during a read" {
    const Callbacks = struct {
        const Reentry = struct {
            session: *Session,
            first: model.Model(u32),
            second: model.Model(u32),
        };

        fn observe(value: *const u32, out: *u32) !void {
            out.* = value.*;
        }
        fn increment(value: *u32, _: void) !void {
            value.* += 1;
        }
        fn outer(value: *const u32, reentry: *Reentry) !void {
            var nested: u32 = 0;
            try reentry.session.read(u32, reentry.first, &nested, observe);
            try std.testing.expectEqual(value.*, nested);
            try reentry.session.update(u32, reentry.second, {}, increment);
        }
    };
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var first_value: u32 = 3;
    var second_value: u32 = 7;
    var first = try session.create(u32, &first_value);
    defer session.release(u32, &first) catch unreachable;
    var second = try session.create(u32, &second_value);
    defer session.release(u32, &second) catch unreachable;
    var reentry: Callbacks.Reentry = .{ .session = &session, .first = first, .second = second };
    try session.read(u32, first, &reentry, Callbacks.outer);
    var observed: u32 = 0;
    try session.read(u32, second, &observed, Callbacks.observe);
    try std.testing.expectEqual(@as(u32, 8), observed);
}

test "erased retirement preflight rejects an active borrow without consuming ownership" {
    const Probe = struct {
        const Self = @This();
        session: *Session,
        erased: *ErasedModel,

        fn duringRead(_: *const u32, self: *Self) !void {
            try std.testing.expectError(
                error.ConflictingAccess,
                self.session.canReleaseErased(self.erased.*),
            );
            const ticket = self.erased.ticket;
            try std.testing.expectError(
                error.ConflictingAccess,
                self.session.releaseErased(self.erased),
            );
            try std.testing.expectEqual(ticket, self.erased.ticket);
        }
    };
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var value: u32 = 4;
    var owner = try session.create(u32, &value);
    defer session.release(u32, &owner) catch unreachable;
    var other = try session.retain(u32, owner);
    var erased = other.erase();
    var probe: Probe = .{ .session = &session, .erased = &erased };
    try session.read(u32, owner, &probe, Probe.duringRead);
    try session.canReleaseErased(erased);
    try session.releaseErased(&erased);
}

test "erased reentrant destruction preserves a replacement owner" {
    const Reentrant = struct {
        const Self = @This();
        owner: *ErasedModel,
        spawn: bool,

        pub fn deinit(self: *Self, session: *Session) void {
            if (self.spawn) {
                var replacement: Self = .{ .owner = self.owner, .spawn = false };
                var next = session.create(Self, &replacement) catch @panic("replacement failed");
                self.owner.* = next.erase();
            }
            self.* = undefined;
        }
    };

    var session = try Session.init(std.testing.allocator);
    var erased: ErasedModel = .{};
    var value: Reentrant = .{ .owner = &erased, .spawn = true };
    var owner = try session.create(Reentrant, &value);
    erased = owner.erase();
    try session.releaseErased(&erased);
    try std.testing.expect(erased.ticket != 0);
    try session.releaseErased(&erased);
    try session.deinit();
}
