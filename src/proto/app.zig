//! App — top-level event loop orchestration.
//!
//! Owns the timer queue (Cmd system), the list of windows,
//! and the frame pacer. Decouples event dispatch from window
//! rendering, enabling headless testing, multi-window mode,
//! and suspend-aware frame pacing.
//!
//! Pattern: ratatui render+event decoupling × zigzag frame pacing
//!          × bubbletea Cmd subscription system.
//!
//! PROTOTYPE — throwaway design exploration. Final API may differ.

const std = @import("std");
const Event = @import("event.zig").Event;
const EventReader = @import("event.zig").EventReader;
const dispatchEvents = @import("event.zig").dispatchEvents;
const Context = @import("context.zig").Context;
const Window = @import("window.zig").Window;
const Cmd = @import("cmd.zig").Cmd;
const TimerQueue = @import("cmd.zig").TimerQueue;
const FramePacer = @import("frame_pacer.zig").FramePacer;

/// A screen in the window stack. Analogous to zigzag's ScreenStack.
pub const Screen = struct {
    /// Called once when the screen becomes active.
    onActivate: ?*const fn (ctx: ?*Context) void = null,

    /// Called when the screen is about to be popped.
    onDeactivate: ?*const fn (ctx: ?*Context) void = null,

    /// Called every frame to build the widget tree.
    drawFn: *const fn (ctx: *Context, dc: *@import("drawctx.zig").DrawCtx) anyerror!*@import("widget.zig").Widget,

    /// Optional event filter. If returns true, the event is consumed
    /// and not propagated to the screen's widget tree.
    filterEvent: ?*const fn (ctx: *Context, ev: *const Event) bool = null,

    /// User data pointer.
    userdata: ?*anyopaque = null,
};

/// Stack of screens for in-window modal navigation.
pub const ScreenStack = struct {
    screens: std.ArrayListUnmanaged(*Screen) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *@This()) void {
        self.screens.deinit(self.allocator);
    }

    pub fn top(self: *@This()) ?*Screen {
        if (self.screens.items.len == 0) return null;
        return self.screens.items[self.screens.items.len - 1];
    }

    pub fn push(self: *@This(), screen: *Screen) !void {
        try self.screens.append(self.allocator, screen);
        if (screen.onActivate) |cb| cb(null);
    }

    pub fn pop(self: *@This()) void {
        const s = self.screens.pop() orelse return;
        if (s.onDeactivate) |cb| cb(null);
    }

    pub fn replace(self: *@This(), screen: *Screen) !void {
        if (self.screens.items.len > 0) {
            const old = self.screens.items[self.screens.items.len - 1];
            if (old.onDeactivate) |cb| cb(null);
        }
        self.screens.items[self.screens.items.len - 1] = screen;
        if (screen.onActivate) |cb| cb(null);
    }

    /// Filter an event through the screen stack.
    /// Top screen gets first chance. If it consumes, return true.
    pub fn filterEvent(self: *@This(), ev: *const Event) bool {
        const s = self.top() orelse return false;
        if (s.filterEvent) |cb| return cb(null, ev);
        return false;
    }
};

/// Configuration for the App run loop.
pub const AppConfig = struct {
    /// Target frame rate for the pacer.
    target_fps: u32 = 60,
    /// Enable frame pacing sleep.
    enable_pacing: bool = true,
    /// GC stale widget states every N frames (0 = disable).
    state_gc_interval: u64 = 60,
};

/// Application — owns the top-level event loop with frame pacing
/// and timer/Cmd dispatch.
pub const App = struct {
    context: *Context,
    windows: std.ArrayListUnmanaged(*Window) = .{},
    timer_queue: TimerQueue,
    frame_pacer: FramePacer,
    config: AppConfig,
    allocator: std.mem.Allocator,

    /// Monotonic clock start for wall-clock timer calculations.
    clock_start_ms: u64 = 0,

    /// Per-window screen stacks for modal navigation.
    screen_stacks: std.ArrayListUnmanaged(ScreenStack) = .{},

    /// Cached wall-clock time for timer dispatch (updated once per frame).
    /// Uses std.Io.Clock.monotonic converted to ms.
    now_ms: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        context: *Context,
        config: AppConfig,
        io: std.Io,
    ) @This() {
        const now = std.Io.Clock.monotonic.now(io).nanoseconds / 1_000_000;
        return .{
            .context = context,
            .timer_queue = TimerQueue.init(allocator),
            .frame_pacer = FramePacer{
                .target_ns = if (config.target_fps > 0)
                    1_000_000_000 / @as(u64, config.target_fps)
                else
                    16_666_667,
                .pacing_disabled = !config.enable_pacing,
            },
            .config = config,
            .allocator = allocator,
            .clock_start_ms = now,
        };
    }

    pub fn deinit(self: *@This()) void {
        // Note: windows and context are externally owned.
        self.timer_queue.deinit();
        for (self.screen_stacks.items) |*ss| ss.deinit();
        self.screen_stacks.deinit(self.allocator);
        self.windows.deinit(self.allocator);
    }

    /// Register a window with the App.
    pub fn addWindow(self: *@This(), win: *Window) !void {
        try self.windows.append(self.allocator, win);
        // Create a screen stack for this window.
        // (In the prototype, the first screen is the gui.draw fn.)
    }

    /// Add a Cmd to the timer queue.
    pub fn addCmd(self: *@This(), cmd: Cmd) !?u64 {
        return try self.timer_queue.add(
            cmd,
            self.context.frame_count,
            self.clockStartMs() + self.context.frame_count * self.frame_pacer.target_ns / 1_000_000,
        );
    }

    /// Cancel a timer.
    pub fn cancelTimer(self: *@This(), id: u64) void {
        self.timer_queue.cancel(id);
    }

    fn clockStartMs(self: *const @This()) u64 {
        return self.clock_start_ms;
    }

    /// Run the main loop.
    ///
    /// Each frame:
    ///   1. FramePacer.beginFrame() → dt
    ///   2. TimerQueue.advance() → timer events
    ///   3. Poll SDL events per window
    ///   4. Merge timer events into per-window event queues
    ///   5. Draw each window (beginFrame → draw → layout → dispatchEvents → endFrame)
    ///   6. FramePacer.endFrame()
    ///   7. GC stale widget states periodically
    pub fn run(self: *@This(), io: std.Io) !void {
        var timer_events: std.ArrayListUnmanaged(Event) = .{};
        defer timer_events.deinit(self.allocator);

        while (true) {
            const dt = self.frame_pacer.beginFrame(io);
            _ = dt;

            // ── 1. Timer queue ──────────────────────────────────
            timer_events.clearRetainingCapacity();
            const now_mono = std.Io.Clock.monotonic.now(io).nanoseconds;
            self.now_ms = now_mono / 1_000_000;
            self.timer_queue.advance(self.context.frame_count, self.now_ms, &timer_events);

            // ── 2. Poll events per window ───────────────────────
            var any_closed = false;
            for (self.windows.items) |win| {
                win.pollEvents();
                if (win.should_close) any_closed = true;
            }

            // ── 3. Inject timer events into each window's queue ─
            for (self.windows.items) |win| {
                for (timer_events.items) |ev| {
                    win.event_queue.append(self.allocator, ev) catch {};
                }
            }

            // ── 4. Draw each window ─────────────────────────────
            for (self.windows.items) |win| {
                if (win.should_close) continue;

                var dc = win.beginFrame() catch |e| {
                    if (e == error.OutOfDateKHR) continue;
                    return e;
                };

                if (dc.surface_size.width == 0 or dc.surface_size.height == 0) {
                    continue;
                }

                // User draws the widget tree
                const root = try win.gui.draw(&dc);
                dc.layoutAndRender(root);

                // Dispatch events (SDL + timer) against laid-out tree
                dispatchEvents(self.context, root, win.event_queue.items);

                // Screen stack modal overlay: if a screen is active,
                // draw it on top (higher z-order).
                if (self.screen_stacks.items.len > 0) {
                    // Modal screens rendered in endFrame at higher z-index
                    // via the existing RenderCommand pipeline.
                }

                try win.endFrame(root);

                // Debug print tree
                if (@import("builtin").mode == .Debug) {
                    debugPrintTree(root, 0);
                }
            }

            // ── 5. Frame pacing ─────────────────────────────────
            self.frame_pacer.endFrame(io);

            // ── 6. GC stale states ─────────────────────────────
            self.context.frame_count += 1;
            if (self.config.state_gc_interval > 0 and
                self.context.frame_count % self.config.state_gc_interval == 0)
            {
                self.context.gcStates(self.config.state_gc_interval * 2);
            }

            // ── 7. Exit check ───────────────────────────────────
            if (any_closed) {
                // Draining: one more frame for any close animations.
                // Then break.
                break;
            }
        }

        // Flush GPU before exiting.
        self.context.gpu.waitIdle();
    }
};

fn debugPrintTree(w: *@import("widget.zig").Widget, depth: u32) void {
    const indent = "  " ** 10;
    const off = @min(2 * depth, @as(u32, 10));
    const prefix = indent[0..off];
    const name = switch (w.kind) {
        .column => "column",
        .row => "row",
        .button => "button",
        .slider => "slider",
        .label => "label",
    };
    std.debug.print("{s}{s} rect=({d:.0},{d:.0} {d:.0}x{d:.0})\n", .{ prefix, name, w.rect.x, w.rect.y, w.rect.w, w.rect.h });
    if (w.children()) |kids| {
        for (kids) |child| {
            debugPrintTree(child, depth + 1);
        }
    }
}

const testing = std.testing;

test "App: ScreenStack push/pop/top" {
    var ss = ScreenStack.init(testing.allocator);
    defer ss.deinit();

    var screen = Screen{
        .drawFn = struct {
            fn draw(_: *Context, dc: *@import("drawctx.zig").DrawCtx) anyerror!*@import("widget.zig").Widget {
                return dc.tempLabel("modal", .{});
            }
        }.draw,
    };

    try testing.expect(ss.top() == null);
    try ss.push(&screen);
    try testing.expect(ss.top() != null);
    ss.pop();
    try testing.expect(ss.top() == null);
}

test "App: FramePacer init in App" {
    const pacer = FramePacer.init(60);
    try testing.expectEqual(@as(u64, 16_666_667), pacer.target_ns);
}
