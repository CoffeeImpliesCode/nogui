//! E01: the macOS application — activation, hiding, reopening, and the
//! events AppKit delivers to a delegate.
//!
//! SDL already installs an `NSApplicationDelegate`, so this module does not
//! replace it. The shim installs a delegate that implements the four
//! callbacks a host needs and forwards every other selector to the delegate
//! that was registered before it, including through `respondsToSelector:`.
//! SDL's own application behaviour therefore keeps working, and this module
//! only observes.
//!
//! Every callback arrives on the macOS main thread, which is the thread the
//! host pumps. They are still queued rather than delivered straight into the
//! caller's struct: a host handler may drop a model, and an event that arrives
//! after teardown has to find a live ring rather than freed memory. `drain`
//! is the only way events reach a caller, and it runs on the host's own
//! thread.
const std = @import("std");
const native = @import("native.zig");

const Error = native.Error;
const Status = native.Status;
const shim = native.shim;

/// Whether this process owns a Dock icon and a menu bar.
pub const ActivationPolicy = enum {
    /// A normal application: Dock icon, menu bar, window focus.
    regular,
    /// No Dock icon, but a menu bar when the user activates it.
    accessory,
    /// Neither, and the process cannot become active.
    prohibited,
};

/// What AppKit told the delegate.
pub const Event = union(enum) {
    /// The Dock icon or a reopen file was used. `visible` is the platform's own
    /// `hasVisibleWindows` argument, which is what decides whether AppKit
    /// brings a window forward on its own.
    reopened: struct { visible: bool },
    became_active,
    resigned_active,
    will_terminate,

    pub fn name(self: Event) []const u8 {
        return switch (self) {
            .reopened => "reopened",
            .became_active => "became_active",
            .resigned_active => "resigned_active",
            .will_terminate => "will_terminate",
        };
    }
};

pub const Handler = *const fn (?*anyopaque, Event) void;

/// Events waiting to be delivered. A fixed ring, so a host that stops pumping
/// cannot make the platform's memory grow without bound.
pub const queue_limit = 32;

/// What AppKit reports about the whole application.
pub const State = struct {
    active: bool,
    hidden: bool,
    /// The bundle identifier, or an empty string in an unbundled process.
    /// UserNotifications and the recent-documents store both refuse to work
    /// without one, so callers that need them check here first.
    bundle_id: []const u8,
};

/// The application delegate the shim installed on the host's behalf.
///
/// Allocate one, then initialize it in place: the shim keeps the pointer, so
/// the address has to outlive `deinit`.
///     const delegate = try gpa.create(Delegate);
///     errdefer gpa.destroy(delegate);
///     delegate.* = Delegate.init(gpa, io);
pub const Delegate = struct {
    gpa: std.mem.Allocator,
    /// The Io the ring's mutex waits on. AppKit delivers its callbacks on the
    /// macOS main thread, so the window that owns this delegate has to keep
    /// its Io alive for the shim's whole hold on the pointer.
    io: std.Io,
    /// The shim's delegate object. Null before `attach` and after `detach`.
    handle: ?*anyopaque = null,
    /// Set once `deinit` ran, so a callback that arrives during teardown finds
    /// a closed ring instead of a freed one.
    closed: bool = false,
    events: [queue_limit]Event,
    event_count: u16 = 0,
    event_head: u16 = 0,
    /// Events the ring refused because it was full. Surfaced, never hidden.
    dropped: u32 = 0,
    mutex: std.Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Delegate {
        return .{
            .gpa = gpa,
            .io = io,
            // SAFETY: `drain` reads only the slots `push` counted, so no
            // event is ever read out of a slot nothing wrote.
            .events = undefined,
        };
    }

    /// Install the delegate. One per application, because AppKit has one.
    pub fn attach(self: *Delegate) Error!void {
        if (!native.available) return error.ShimUnavailable;
        if (self.handle != null) return;
        const callbacks: shim.nogui_macos_app_events = .{
            .user = @ptrCast(self),
            .on_reopen = onReopen,
            .on_become_active = onBecomeActive,
            .on_resign_active = onResignActive,
            .on_will_terminate = onWillTerminate,
        };
        const handle = shim.nogui_macos_app_events_install(&callbacks) orelse
            return error.ShimUnavailable;
        self.handle = handle;
    }

    /// Restore the delegate that was registered before `attach` and drop the
    /// shim's. Safe to call twice; the second call does nothing.
    pub fn detach(self: *Delegate) void {
        // The flag is set under the ring's own lock, because that is the lock
        // a callback reads it under and the one `push` holds while it writes
        // the ring. A flag written outside it would race a callback that
        // arrives while teardown runs, and this flag is the last thing between
        // that callback and a record the owner has already released.
        self.mutex.lockUncancelable(self.io);
        self.closed = true;
        self.mutex.unlock(self.io);
        const handle = self.handle orelse return;
        self.handle = null;
        if (!native.available) return;
        shim.nogui_macos_app_events_remove(handle);
    }

    /// Restore the previous delegate and empty the ring.
    pub fn deinit(self: *Delegate) void {
        self.detach();
        self.* = undefined;
    }

    /// Deliver every queued event to `handler` and return how many it
    /// delivered.
    ///
    /// The ring is emptied under the lock and handed over outside it, so a
    /// handler that calls back into this delegate cannot deadlock on itself.
    pub fn drain(self: *Delegate, context: ?*anyopaque, handler: Handler) usize {
        var pending: [queue_limit]Event = undefined;
        var count: usize = 0;
        self.mutex.lockUncancelable(self.io);
        if (!self.closed) {
            while (self.event_count > 0) {
                pending[count] = self.events[self.event_head];
                self.event_head = (self.event_head + 1) % queue_limit;
                self.event_count -= 1;
                count += 1;
            }
        }
        self.mutex.unlock(self.io);
        for (pending[0..count]) |event| handler(context, event);
        return count;
    }

    /// Events the ring refused because the host was not pumping.
    pub fn droppedCount(self: *const Delegate) u32 {
        return self.dropped;
    }

    fn push(self: *Delegate, event: Event) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return;
        if (self.event_count == queue_limit) {
            self.dropped +%= 1;
            return;
        }
        const tail = (self.event_head + self.event_count) % queue_limit;
        self.events[tail] = event;
        self.event_count += 1;
    }

    fn fromUser(user: ?*anyopaque) ?*Delegate {
        const ptr = user orelse return null;
        const self: *Delegate = @ptrCast(@alignCast(ptr));
        // Read under the lock `detach` writes it under, for the reason given
        // there: this gate is what a callback that arrives during teardown
        // finds closed, and a read outside the lock could see either answer.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return null;
        return self;
    }

    fn onReopen(user: ?*anyopaque, visible: c_int) callconv(.c) void {
        if (Delegate.fromUser(user)) |self| {
            self.push(.{ .reopened = .{ .visible = visible != 0 } });
        }
    }

    fn onBecomeActive(user: ?*anyopaque) callconv(.c) void {
        if (Delegate.fromUser(user)) |self| self.push(.became_active);
    }

    fn onResignActive(user: ?*anyopaque) callconv(.c) void {
        if (Delegate.fromUser(user)) |self| self.push(.resigned_active);
    }

    fn onWillTerminate(user: ?*anyopaque) callconv(.c) void {
        if (Delegate.fromUser(user)) |self| self.push(.will_terminate);
    }
};

/// Bring this application to the front. Reports what AppKit answered, because
/// a request to activate and an application that is active are two facts.
pub fn activate() Error!bool {
    if (!native.available) return error.ShimUnavailable;
    return native.fact(shim.nogui_macos_app_activate());
}

/// Hide this application. A windowless process cannot be hidden, and AppKit
/// says so rather than pretending.
pub fn hide() Error!bool {
    if (!native.available) return error.ShimUnavailable;
    return native.fact(shim.nogui_macos_app_hide());
}

pub fn unhide() Error!bool {
    if (!native.available) return error.ShimUnavailable;
    return native.fact(shim.nogui_macos_app_unhide());
}

pub fn hideOthers() Error!void {
    if (!native.available) return error.ShimUnavailable;
    try native.check(Status.of(shim.nogui_macos_app_hide_others()));
}

pub fn showAll() Error!void {
    if (!native.available) return error.ShimUnavailable;
    try native.check(Status.of(shim.nogui_macos_app_show_all()));
}

/// Run the reopen action itself, the one the Quit Applications shortcut uses.
/// A host calls this to ask AppKit to bring its windows back; the Dock path
/// arrives as an `Event.reopened` instead.
pub fn reopen() Error!void {
    if (!native.available) return error.ShimUnavailable;
    try native.check(Status.of(shim.nogui_macos_app_reopen()));
}

pub fn isActive() bool {
    if (!native.available) return false;
    return shim.nogui_macos_app_is_active() == 1;
}

pub fn isHidden() bool {
    if (!native.available) return false;
    return shim.nogui_macos_app_is_hidden() == 1;
}

/// Set the activation policy. Reports whether AppKit accepted it: a process
/// that cannot become active refuses an accessory or regular policy.
pub fn setActivationPolicy(policy: ActivationPolicy) Error!bool {
    if (!native.available) return error.ShimUnavailable;
    const wire: c_int = switch (policy) {
        .regular => 0,
        .accessory => 1,
        .prohibited => 2,
    };
    return native.fact(shim.nogui_macos_app_set_activation_policy(wire));
}

/// Read the policy AppKit currently holds.
pub fn activationPolicy() Error!ActivationPolicy {
    if (comptime !native.available) return error.ShimUnavailable;
    const raw = shim.nogui_macos_app_activation_policy();
    if (raw < 0) return native.fail(Status.of(raw));
    return switch (raw) {
        0 => .regular,
        1 => .accessory,
        2 => .prohibited,
        else => error.PlatformFault,
    };
}

/// The Dock tile's badge. A null label clears it.
pub fn setDockBadge(label: ?[]const u8) Error!void {
    if (!native.available) return error.ShimUnavailable;
    var scratch = native.Scratch.init(std.heap.page_allocator);
    defer scratch.deinit();
    const owned = if (label) |text| try scratch.nul(text) else null;
    try native.check(Status.of(shim.nogui_macos_app_dock_badge(owned)));
}

/// The whole application state in one reading. `bundle_id` is owned by `gpa`.
pub fn state(gpa: std.mem.Allocator) Error!State {
    if (!native.available) return error.ShimUnavailable;
    return .{
        .active = isActive(),
        .hidden = isHidden(),
        .bundle_id = try native.readString(gpa, .bundle_id, 0, null),
    };
}

test "api-w23 macos delegate ring is bounded and counts what it refused" {
    var delegate = Delegate.init(std.testing.allocator, std.testing.io);
    defer delegate.deinit();
    const Sink = struct {
        const Self = @This();
        seen: usize = 0,
        order: [queue_limit]Event,
        fn count(context: ?*anyopaque, event: Event) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.order[self.seen] = event;
            self.seen += 1;
        }
    };
    // SAFETY: `count` writes the slot it is about to count, so every entry the
    // comparisons below read was written by a delivered callback.
    var sink: Sink = .{ .order = undefined };

    // A full ring, filled with events a reader can tell apart. It hands over
    // every one of them, oldest first: a delegate that reorders its callbacks
    // reports a resign-active after the activate it belongs after.
    for (0..queue_limit) |i| delegate.push(switch (i % 3) {
        0 => .became_active,
        1 => .resigned_active,
        else => .{ .reopened = .{ .visible = i % 2 == 0 } },
    });
    try std.testing.expectEqual(queue_limit, delegate.drain(&sink, Sink.count));
    try std.testing.expectEqual(@as(usize, queue_limit), sink.seen);
    for (sink.order, 0..) |event, i| {
        try std.testing.expectEqual(
            switch (i % 3) {
                0 => Event.became_active,
                1 => Event.resigned_active,
                else => Event{ .reopened = .{ .visible = i % 2 == 0 } },
            },
            event,
        );
    }

    // Draining takes the ring, so a pump with nothing new delivers nothing:
    // the host must not act on a callback AppKit has already reported.
    sink.seen = 0;
    try std.testing.expectEqual(@as(usize, 0), delegate.drain(&sink, Sink.count));
    try std.testing.expectEqual(@as(usize, 0), sink.seen);

    // The same ring, filled again, then three callbacks it cannot take. It
    // refuses and counts them rather than overwriting the ones the host has not
    // been given yet, so what reaches the host is still what arrived first,
    // whole and in order, and none of the three ever arrives at all.
    for (0..queue_limit) |i| delegate.push(switch (i % 3) {
        0 => .became_active,
        1 => .resigned_active,
        else => .{ .reopened = .{ .visible = i % 2 == 0 } },
    });
    for (0..3) |_| delegate.push(.will_terminate);
    try std.testing.expectEqual(@as(u32, 3), delegate.droppedCount());
    try std.testing.expectEqual(queue_limit, delegate.drain(&sink, Sink.count));
    try std.testing.expectEqual(@as(usize, queue_limit), sink.seen);
    for (sink.order, 0..) |event, i| {
        try std.testing.expectEqual(
            switch (i % 3) {
                0 => Event.became_active,
                1 => Event.resigned_active,
                else => Event{ .reopened = .{ .visible = i % 2 == 0 } },
            },
            event,
        );
    }
}

test "api-w23 macos delegate drops callbacks after teardown" {
    var delegate = Delegate.init(std.testing.allocator, std.testing.io);
    defer delegate.deinit();
    // A callback the host never pumped, so the ring is not empty when
    // teardown closes it.
    delegate.push(.will_terminate);
    // Teardown is what closes the ring, not a flag set beside it. A test
    // that only sets the flag proves nothing about the path a caller has to
    // survive, and this one runs it: the shim was never installed, so this is
    // the whole of what a host sees.
    delegate.detach();
    // Every callback the shim can deliver, and the null user pointer it
    // reports when it has nothing to name.
    Delegate.onReopen(@ptrCast(&delegate), 1);
    Delegate.onBecomeActive(@ptrCast(&delegate));
    Delegate.onResignActive(@ptrCast(&delegate));
    Delegate.onWillTerminate(@ptrCast(&delegate));
    Delegate.onBecomeActive(null);
    // Nothing may be delivered to a ring the owner has already released, and
    // an event the closed ring refused is not one the full ring refused, so
    // it is not counted as a drop.
    try std.testing.expectEqual(@as(usize, 0), delegate.drain(null, struct {
        fn ignore(_: ?*anyopaque, _: Event) void {}
    }.ignore));
    try std.testing.expectEqual(@as(u32, 0), delegate.droppedCount());
}

test "api-w23 macos delegate keeps a handler that reenters its own ring" {
    var delegate = Delegate.init(std.testing.allocator, std.testing.io);
    defer delegate.deinit();
    const Sink = struct {
        const Self = @This();
        delegate: *Delegate,
        reentered: usize = 0,
        seen: usize = 0,

        // A handler that pumps the ring it is being handed is the one way a
        // host can call back into its own delegate from inside `drain`. The
        // ring has to survive that: the events already handed over are in a
        // local buffer, and the lock is not held while this runs.
        fn count(context: ?*anyopaque, event: Event) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            _ = event;
            self.seen += 1;
            self.reentered += self.delegate.drain(null, struct {
                fn ignore(_: ?*anyopaque, _: Event) void {}
            }.ignore);
        }
    };
    // SAFETY: `count` counts before it reads, so every value the assertions
    // compare was written by a delivered callback.
    var sink: Sink = .{ .delegate = &delegate };
    for (0..queue_limit) |_| delegate.push(.became_active);
    try std.testing.expectEqual(queue_limit, delegate.drain(&sink, Sink.count));
    try std.testing.expectEqual(@as(usize, queue_limit), sink.seen);
    // The reentrant drains found nothing: `drain` took the whole ring out
    // before the first handler ran, so no event is delivered twice.
    try std.testing.expectEqual(@as(usize, 0), sink.reentered);
    try std.testing.expectEqual(@as(u32, 0), delegate.droppedCount());
}
