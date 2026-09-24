//! Per-window, owner-scoped animations. Timelines live outside both frame arenas;
//! only scalar samples belong to a frame. All times are monotonic milliseconds.
const std = @import("std");
const WidgetId = @import("id.zig").WidgetId;
const IdentityRegistry = @import("identity.zig").IdentityRegistry;

const inline_steps = 16;

/// Separate channels let one widget animate independent values without inventing widget IDs.
pub const Key = struct {
    owner: WidgetId,
    lane: u64 = 0,
};

pub const Easing = union(enum) {
    linear,
    ease_in,
    ease_out,
    ease_in_out,
    /// `shape = duration / tau`: 8 on an 800ms press has a 100ms one-pole response.
    /// The finite endpoint snaps to the exact target instead of waking forever.
    exponential: f32,
};

pub const Step = struct {
    to: f32,
    duration_ms: u32,
    easing: Easing = .linear,
};

pub const Repeat = union(enum) {
    once,
    /// Total number of runs, including the first one. Must be positive.
    count: u32,
    forever,
};

pub const Transition = struct {
    from_if_absent: f32,
    to: f32,
    duration_ms: u32,
    easing: Easing = .linear,
    now_ms: u64,
};

/// The sequence slice is copied into persistent registry storage on start.
pub const Spec = struct {
    from: f32,
    steps: []const Step,
    repeat: Repeat = .once,
};

pub const Demand = struct {
    /// True only while a timeline can still change. A terminal presentation
    /// may be due even when active is false.
    active: bool = false,
    deadline_ms: ?u64 = null,
};

pub const Error = std.mem.Allocator.Error || error{
    WrongOwner,
    EmptySequence,
    InvalidDuration,
    InvalidRepeat,
    InvalidValue,
    InvalidEasing,
    DurationOverflow,
};

const Timeline = struct {
    key: Key,
    from: f32,
    // SAFETY: only steps before step_count are read; start copies that prefix.
    steps: [inline_steps]Step = undefined,
    heap_steps: ?[]Step = null,
    step_count: usize,
    repeat: Repeat,
    start_ms: u64,
    cycle_ms: u64,
    /// Null for an unbounded repeating sequence.
    end_ms: ?u64,
    /// A frame must successfully present the endpoint before a one-shot goes idle.
    presented_ms: ?u64 = null,
    pending_presentation: bool = true,

    fn stepSlice(self: *const Timeline) []const Step {
        return if (self.heap_steps) |heap| heap else self.steps[0..self.step_count];
    }

    fn endpoint(self: *const Timeline) f32 {
        const steps = self.stepSlice();
        return steps[steps.len - 1].to;
    }

    fn sample(self: *const Timeline, now_ms: u64) f32 {
        if (now_ms <= self.start_ms) return self.from;
        if (self.end_ms) |end_ms| {
            if (now_ms >= end_ms) return self.endpoint();
        }
        const elapsed_ms = now_ms - self.start_ms;
        var remaining_ms = elapsed_ms % self.cycle_ms;
        var from = self.from;
        for (self.stepSlice()) |step| {
            if (remaining_ms < step.duration_ms) {
                const fraction: f32 = @as(f32, @floatFromInt(remaining_ms)) /
                    @as(f32, @floatFromInt(step.duration_ms));
                const weight = ease(step.easing, fraction);
                return from * (1 - weight) + step.to * weight;
            }
            remaining_ms -= step.duration_ms;
            from = step.to;
        }
        unreachable;
    }

    fn nextBoundary(self: *const Timeline, now_ms: u64) u64 {
        if (now_ms < self.start_ms) return self.start_ms;
        const offset_ms = (now_ms - self.start_ms) % self.cycle_ms;
        const cycle_start_ms = now_ms - offset_ms;
        var step_end_ms: u64 = 0;
        for (self.stepSlice()) |step| {
            step_end_ms += step.duration_ms;
            if (step_end_ms > offset_ms) return cycle_start_ms +| step_end_ms;
        }
        unreachable;
    }
};

fn ease(easing: Easing, fraction: f32) f32 {
    if (fraction >= 1) return 1;
    return switch (easing) {
        .linear => fraction,
        .ease_in => fraction * fraction,
        .ease_out => 1 - (1 - fraction) * (1 - fraction),
        .ease_in_out => if (fraction < 0.5)
            2 * fraction * fraction
        else
            1 - 2 * (1 - fraction) * (1 - fraction),
        .exponential => |shape| 1 - std.math.exp(-shape * fraction),
    };
}

fn validateStep(step: Step) Error!void {
    if (step.duration_ms == 0) return error.InvalidDuration;
    if (!std.math.isFinite(step.to)) return error.InvalidValue;
    switch (step.easing) {
        .exponential => |shape| {
            if (!std.math.isFinite(shape) or shape <= 0) return error.InvalidEasing;
        },
        else => {},
    }
}

/// The registry belongs to exactly one App / identity-registry owner, not Session.
/// Starting a new key or a long sequence can allocate; sampling and deadline scans cannot.
pub const Registry = struct {
    gpa: std.mem.Allocator,
    widget_owner: u64,
    timelines: std.ArrayListUnmanaged(Timeline) = .empty,
    indexes: std.AutoHashMapUnmanaged(Key, usize) = .empty,
    reduced_motion: bool = false,

    pub fn init(gpa: std.mem.Allocator, widget_owner: u64) Registry {
        std.debug.assert(widget_owner != 0);
        return .{ .gpa = gpa, .widget_owner = widget_owner };
    }

    pub fn deinit(self: *Registry) void {
        self.clear();
        self.timelines.deinit(self.gpa);
        self.indexes.deinit(self.gpa);
        self.* = undefined;
    }

    /// Restart from the authored initial value, even if this key is in flight.
    /// Invalid input or allocation failure leaves an existing timeline unchanged.
    pub fn start(self: *Registry, key: Key, spec: Spec, now_ms: u64) Error!void {
        if (key.owner.owner != self.widget_owner) return error.WrongOwner;
        if (spec.steps.len == 0) return error.EmptySequence;
        if (!std.math.isFinite(spec.from)) return error.InvalidValue;

        var cycle_ms: u64 = 0;
        for (spec.steps) |step| {
            try validateStep(step);
            cycle_ms = std.math.add(u64, cycle_ms, step.duration_ms) catch
                return error.DurationOverflow;
        }
        const end_ms: ?u64 = switch (spec.repeat) {
            .once => std.math.add(u64, now_ms, cycle_ms) catch
                return error.DurationOverflow,
            .count => |count| blk: {
                if (count == 0) return error.InvalidRepeat;
                const total_ms = std.math.mul(u64, cycle_ms, count) catch
                    return error.DurationOverflow;
                break :blk std.math.add(u64, now_ms, total_ms) catch
                    return error.DurationOverflow;
            },
            .forever => blk: {
                _ = std.math.add(u64, now_ms, cycle_ms) catch
                    return error.DurationOverflow;
                break :blk null;
            },
        };

        var timeline: Timeline = .{
            .key = key,
            .from = spec.from,
            .step_count = spec.steps.len,
            .repeat = spec.repeat,
            .start_ms = now_ms,
            .cycle_ms = cycle_ms,
            .end_ms = end_ms,
        };
        if (spec.steps.len <= inline_steps) {
            @memcpy(timeline.steps[0..spec.steps.len], spec.steps);
        } else {
            timeline.heap_steps = try self.gpa.dupe(Step, spec.steps);
        }
        errdefer if (timeline.heap_steps) |heap| self.gpa.free(heap);
        if (self.indexes.get(key)) |index| {
            const old_heap = self.timelines.items[index].heap_steps;
            self.timelines.items[index] = timeline;
            if (old_heap) |heap| self.gpa.free(heap);
            return;
        }
        const index = self.timelines.items.len;
        try self.timelines.append(self.gpa, timeline);
        errdefer _ = self.timelines.pop();
        try self.indexes.put(self.gpa, key, index);
    }

    /// Replace a running plan, using its value at the interruption time as the
    /// new first value. A missing key uses spec.from.
    pub fn interrupt(self: *Registry, key: Key, spec: Spec, now_ms: u64) Error!void {
        var next = spec;
        if (self.sample(key, now_ms)) |value| next.from = value;
        try self.start(key, next, now_ms);
    }

    /// Idempotent single-step retargeting for hover/press. A missing idle key
    /// with equal endpoints needs neither storage nor a decorative frame.
    pub fn transition(self: *Registry, key: Key, options: Transition) Error!void {
        if (key.owner.owner != self.widget_owner) return error.WrongOwner;
        if (!std.math.isFinite(options.from_if_absent)) return error.InvalidValue;
        const step: Step = .{
            .to = options.to,
            .duration_ms = options.duration_ms,
            .easing = options.easing,
        };
        const previous = self.indexes.get(key);
        const from = if (previous) |index| blk: {
            const current = &self.timelines.items[index];
            const one_run = switch (current.repeat) {
                .once => true,
                else => false,
            };
            if (one_run and current.step_count == 1) {
                const old = current.steps[0];
                if (old.to == step.to and old.duration_ms == step.duration_ms and
                    std.meta.eql(old.easing, step.easing)) return;
            }
            break :blk self.sample(key, options.now_ms).?;
        } else options.from_if_absent;
        if (previous == null and from == options.to) {
            try validateStep(step);
            return;
        }
        const steps = [_]Step{step};
        try self.start(key, .{ .from = from, .steps = &steps }, options.now_ms);
    }

    /// Sampling is pure: a failed App frame does not consume animation state.
    /// An absent or wrong-window key has no sample.
    pub fn sample(self: *const Registry, key: Key, now_ms: u64) ?f32 {
        if (key.owner.owner != self.widget_owner) return null;
        const index = self.indexes.get(key) orelse return null;
        const timeline = &self.timelines.items[index];
        if (self.reduced_motion) return timeline.endpoint();
        return timeline.sample(now_ms);
    }

    /// Called only after a successful presentation. A failed frame preserves
    /// the pending initial/terminal deadline and retries on the next wake.
    pub fn framePresented(self: *Registry, now_ms: u64) void {
        for (self.timelines.items) |*timeline| {
            timeline.presented_ms = now_ms;
            timeline.pending_presentation = false;
        }
    }

    /// One deadline for all active values. Also request one frame for a changed
    /// static endpoint, or a final one-shot sample that has not been presented.
    /// `interval_ms` is the host's nonzero maximum spacing between animation frames.
    pub fn demand(self: *const Registry, now_ms: u64, interval_ms: u32) Demand {
        std.debug.assert(interval_ms > 0);
        var result: Demand = .{};
        for (self.timelines.items) |*timeline| {
            var deadline_ms: ?u64 = null;
            if (!self.reduced_motion) {
                if (now_ms < timeline.start_ms) {
                    deadline_ms = timeline.start_ms;
                } else if (timeline.end_ms) |end_ms| {
                    if (now_ms >= end_ms) {
                        if (timeline.presented_ms == null or
                            timeline.presented_ms.? < end_ms or
                            timeline.pending_presentation)
                        {
                            deadline_ms = now_ms;
                        }
                    } else {
                        result.active = true;
                        deadline_ms = @min(
                            (timeline.presented_ms orelse now_ms) +| interval_ms,
                            timeline.nextBoundary(now_ms),
                        );
                    }
                } else {
                    result.active = true;
                    deadline_ms = @min(
                        (timeline.presented_ms orelse now_ms) +| interval_ms,
                        timeline.nextBoundary(now_ms),
                    );
                }
            }
            if (timeline.pending_presentation) deadline_ms = now_ms;
            if (deadline_ms) |next_ms| {
                result.deadline_ms = if (result.deadline_ms) |previous_ms|
                    @min(previous_ms, next_ms)
                else
                    next_ms;
            }
        }
        return result;
    }

    /// Static endpoint is the last step's target even for an infinite repeat.
    /// Enabling reduced motion paints an unfinished animation's endpoint once.
    pub fn setReducedMotion(self: *Registry, enabled: bool, now_ms: u64) void {
        if (self.reduced_motion == enabled) return;
        for (self.timelines.items) |*timeline| {
            if (enabled) {
                const already_presented = if (timeline.end_ms) |end_ms|
                    timeline.presented_ms != null and timeline.presented_ms.? >= end_ms
                else
                    false;
                if (!already_presented) timeline.pending_presentation = true;
            } else if (timeline.sample(now_ms) != timeline.endpoint()) {
                timeline.pending_presentation = true;
            }
        }
        self.reduced_motion = enabled;
    }

    /// Remove every channel of an owner immediately, including pending wakes.
    pub fn removeOwner(self: *Registry, owner: WidgetId) void {
        if (owner.owner != self.widget_owner) return;
        var index: usize = 0;
        while (index < self.timelines.items.len) {
            if (self.timelines.items[index].key.owner.eql(owner)) {
                self.removeAt(index);
            } else {
                index += 1;
            }
        }
    }

    /// Reconcile only with committed identities, after IdentityRegistry.commitFrame.
    /// Generation checks prevent a recycled slot inheriting a retired timeline.
    pub fn pruneDead(self: *Registry, live: *const IdentityRegistry) void {
        std.debug.assert(live.owner == self.widget_owner);
        var index: usize = 0;
        while (index < self.timelines.items.len) {
            if (!live.isLive(self.timelines.items[index].key.owner)) {
                self.removeAt(index);
            } else {
                index += 1;
            }
        }
    }

    pub fn clear(self: *Registry) void {
        for (self.timelines.items) |timeline| {
            if (timeline.heap_steps) |heap| self.gpa.free(heap);
        }
        self.timelines.clearRetainingCapacity();
        self.indexes.clearRetainingCapacity();
    }

    fn removeAt(self: *Registry, index: usize) void {
        const key = self.timelines.items[index].key;
        const removed = self.indexes.remove(key);
        std.debug.assert(removed);
        const old = self.timelines.swapRemove(index);
        if (index < self.timelines.items.len) {
            self.indexes.getPtr(self.timelines.items[index].key).?.* = index;
        }
        if (old.heap_steps) |heap| self.gpa.free(heap);
    }
};
