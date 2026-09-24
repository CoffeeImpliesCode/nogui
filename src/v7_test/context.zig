//! Reusable headless driver over the production Session, App and task service.
const std = @import("std");
const nogui = @import("nogui");
const Session = nogui.Session;
const App = nogui.App;
const task = nogui.task;
const headless = nogui.headless;
const Event = nogui.Event;
const widget = nogui.widget;
const WidgetId = nogui.WidgetId;
const ComponentId = nogui.ComponentId;
const ComponentKey = nogui.ComponentKey;
const VirtualClock = @import("clock.zig").VirtualClock;
const dispatcher = @import("dispatcher.zig");

/// A query is valid only for the App and the last successfully committed frame.
/// Stable WidgetId survives reorder; this frame stamp does not.
pub const QueryHandle = struct {
    window: u64,
    frame_generation: u64,
    widget: WidgetId,
};

/// A value view of the current semantic state. `label` borrows the current
/// frame's arena: consume it before the next frame attempt or copy it.
pub const NodeSnapshot = struct {
    widget: WidgetId,
    kind: std.meta.Tag(widget.WidgetKind),
    label: ?[]const u8 = null,
    checked: ?bool = null,
    selected: ?bool = null,
    value: ?f32 = null,
    choice: ?u32 = null,
    focused: bool,
    disabled: bool,
    visible: bool,
    visual_rect: widget.Rect,
};

pub const RunReport = struct {
    seed: u64,
    now_ns: i96,
    steps: usize = 0,
    worker_steps: usize = 0,
    ui_callbacks: usize = 0,
    last_task: ?u64 = null,
    next_deadline_ns: ?i96,
    pending: task.Pending,
};

/// Allocate this Context at a stable address: its task Clock borrows `clock`
/// until shutdownTasks completes. Own the root view and persistent models in
/// the caller; release them before deinit. No native window, GPU, or sleep.
pub const Context = struct {
    gpa: std.mem.Allocator,
    clock: VirtualClock = .{},
    session: Session,
    app: App,
    seed: u64,
    random_state: u64,
    last_tick: u32 = 0,
    last_run: ?RunReport = null,
    app_live: bool = true,

    pub fn create(gpa: std.mem.Allocator, seed: u64) !*Context {
        const self = try gpa.create(Context);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .session = try Session.init(gpa),
            .app = undefined,
            .seed = seed,
            .random_state = seed,
        };
        errdefer self.session.deinit() catch unreachable;
        try self.session.startTasksDeterministic(self.clock.injected());
        self.app = try App.init(gpa, &self.session);
        return self;
    }

    /// Do not silently drop a future timer. On LiveModels the App has closed,
    /// but the Session stays live so the caller can release models and retry.
    /// Keep the caller-owned root view alive until the first deinit attempt.
    pub fn deinit(self: *Context) !void {
        try self.requireNoPendingTasks();
        if (self.app_live) {
            self.app.deinit();
            self.app_live = false;
        }
        try self.requireClean();
        if (self.session.tasksStarted()) try self.session.shutdownTasks(0);
        try self.session.deinit();
        self.gpa.destroy(self);
    }

    /// A live caller-owned model prevents teardown; an App-owned root model
    /// is released by deinit before this check runs again.
    pub fn requireClean(self: *Context) !void {
        try self.requireNoPendingTasks();
        if (self.session.active_slots != 0) return error.LiveModels;
    }

    fn requireNoPendingTasks(self: *Context) !void {
        const pending = try self.session.taskPending();
        const count = pending.queued + pending.running + pending.ready +
            pending.ui_timers + pending.cancelled;
        if (count != 0 or (try self.session.nextTaskDeadline()) != null) return error.PendingTasks;
    }

    /// Both entrypoints feed the same App.handle path. Returned JSON, when
    /// app.serialize_json is enabled, belongs to the caller (App's GPA).
    pub fn dispatch(self: *Context, input: Event) !?headless.FrameOutput {
        if (!self.app_live) return error.ContextClosed;
        const output = try dispatcher.dispatch(&self.app, &self.clock, input);
        if (output) |frame| self.last_tick = frame.frame_number;
        return output;
    }

    pub fn dispatchJson(self: *Context, line: []const u8) !?headless.FrameOutput {
        if (!self.app_live) return error.ContextClosed;
        const output = try dispatcher.dispatchJson(&self.app, &self.clock, self.gpa, line);
        if (output) |frame| self.last_tick = frame.frame_number;
        return output;
    }

    /// Build a frame explicitly. The App receives whole milliseconds, while
    /// the injected task clock keeps its exact nanosecond value.
    pub fn flushFrame(self: *Context) !headless.FrameOutput {
        if (!self.app_live) return error.ContextClosed;
        const tick = std.math.add(u32, self.last_tick, 1) catch return error.FrameTickOverflow;
        const ms = @divFloor(self.clock.now(), @as(i96, std.time.ns_per_ms));
        if (ms > std.math.maxInt(u64)) return error.TimeOverflow;
        const frame = (try dispatcher.dispatch(&self.app, null, .{
            .frame = .{ .tick = tick, .time_ms = @intCast(ms) },
        })).?;
        self.last_tick = tick;
        return frame;
    }

    /// Build against an active caller-owned GPU recording. This uses the same
    /// deterministic clock and publication counter as the CPU-only path.
    pub fn flushGpuFrame(self: *Context, gpu_frame: *nogui.GpuFrame) !headless.FrameOutput {
        if (!self.app_live) return error.ContextClosed;
        const tick = std.math.add(u32, self.last_tick, 1) catch return error.FrameTickOverflow;
        const ms = @divFloor(self.clock.now(), @as(i96, std.time.ns_per_ms));
        const time_ms = std.math.cast(u64, ms) orelse return error.TimeOverflow;
        const frame = try self.app.frameWithGpuAtTime(tick, time_ms, self.app.surface, gpu_frame);
        self.last_tick = tick;
        return frame;
    }

    pub fn handleForKey(self: *const Context, scope: ComponentId, key: ComponentKey) !QueryHandle {
        if (!self.app_live) return error.ContextClosed;
        const id = self.app.widgetIdForKey(scope, key) orelse return error.WidgetNotFound;
        return .{ .window = self.app.window, .frame_generation = self.app.frame_generation, .widget = id };
    }

    pub fn queryKey(self: *const Context, scope: ComponentId, key: ComponentKey) !NodeSnapshot {
        return self.query(try self.handleForKey(scope, key));
    }

    pub fn query(self: *const Context, handle: QueryHandle) !NodeSnapshot {
        if (!self.app_live) return error.ContextClosed;
        if (handle.window != self.app.window or handle.frame_generation != self.app.frame_generation)
            return error.StaleFrame;
        const tree = self.app.tree_ptr orelse return error.NoFrame;
        const id = tree.frameNode(handle.widget) orelse return error.StaleWidget;
        const node = tree.nodeConst(id) orelse return error.StaleWidget;
        var result: NodeSnapshot = .{
            .widget = handle.widget,
            .kind = std.meta.activeTag(node.kind),
            .focused = if (self.app.focus_manager.current) |focus| focus.eql(handle.widget) else false,
            .disabled = node.interaction.disabled,
            .visible = widget.isVisible(tree, id),
            .visual_rect = widget.visualBorderRect(tree, id),
        };
        switch (node.kind) {
            .label => |label| result.label = label.text,
            .button => |button| result.label = button.accessible_label orelse button.label,
            .checkbox => |box| {
                result.label = box.label;
                result.checked = box.value.*;
            },
            .switch_control => |toggle| {
                result.label = toggle.label;
                result.checked = toggle.value.*;
            },
            .radio => |radio| {
                result.label = radio.label;
                result.selected = if (radio.selected.*) |choice| choice == radio.option else false;
                result.choice = radio.option;
            },
            .slider => |slider| {
                result.label = slider.label;
                result.value = slider.value.*;
            },
            .progress => |progress| {
                result.label = progress.label;
                result.value = progress.value;
            },
            else => {},
        }
        return result;
    }

    pub fn focused(self: *const Context) ?WidgetId {
        if (!self.app_live) return null;
        return self.app.focus_manager.current;
    }

    pub fn focusesKey(self: *const Context, scope: ComponentId, key: ComponentKey) !bool {
        const handle = try self.handleForKey(scope, key);
        return if (self.focused()) |focus| focus.eql(handle.widget) else false;
    }

    /// Drain only work eligible at current virtual time. Leave future timers
    /// pending. Every worker step runs the production Job.run; every UI step
    /// uses Session.drainTasks. Seed chooses which side proceeds when both can.
    /// On StepLimitExceeded, last_run contains counts and the next deadline.
    pub fn runUntilIdle(self: *Context, max_steps: usize) !RunReport {
        if (!self.app_live) return error.ContextClosed;
        var report: RunReport = .{
            .seed = self.seed,
            .now_ns = self.clock.now(),
            .next_deadline_ns = try self.session.nextTaskDeadline(),
            .pending = try self.session.taskPending(),
        };
        self.last_run = report;
        while (true) {
            const due = if (report.next_deadline_ns) |deadline|
                deadline <= self.clock.now()
            else
                false;
            if (!due and report.pending.queued == 0) break;
            if (report.steps == max_steps) return error.StepLimitExceeded;

            const choose_worker = report.pending.queued != 0 and
                (!due or (self.nextRandom() & 1) == 0);
            if (choose_worker) {
                report.last_task = (try self.session.stepDeterministicWorker()) orelse
                    return error.NoProgress;
                report.worker_steps += 1;
            } else {
                report.ui_callbacks += try self.session.drainTasks();
            }
            report.steps += 1;
            report.now_ns = self.clock.now();
            report.next_deadline_ns = try self.session.nextTaskDeadline();
            report.pending = try self.session.taskPending();
            self.last_run = report;
        }
        return report;
    }

    fn nextRandom(self: *Context) u64 {
        self.random_state +%= 0x9e3779b97f4a7c15;
        var value = self.random_state;
        value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
        value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
        return value ^ (value >> 31);
    }
};
