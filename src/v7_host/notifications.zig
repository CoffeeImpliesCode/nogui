//! Host platform notification service with identity, replacement, dismissal,
//! and response callback routing to live weak owners.
//!
//! The service owns the provider and keeps no reference to it, so a response
//! that arrives outside the call that asked for it -- a bus signal, or a toast
//! the user clicked while the host was doing something else -- has exactly one
//! path to an owner: `NotificationsService.pump`. A host calls that once per
//! frame and needs nothing else, which is why the transport lives behind the
//! provider's vtable rather than in a reference the host has to keep.
const std = @import("std");

pub const NotificationId = u32;

pub const Urgency = enum(u8) {
    low = 0,
    normal = 1,
    critical = 2,
};

pub const Action = struct {
    key: []const u8,
    label: []const u8,
};

pub const NotificationOptions = struct {
    summary: []const u8,
    body: []const u8 = "",
    app_name: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    replaces_id: ?NotificationId = null,
    timeout_ms: i32 = -1, // -1: default, 0: never expire, >0: milliseconds
    urgency: Urgency = .normal,
    category: ?[]const u8 = null,
    sound: ?[]const u8 = null,
    actions: []const Action = &.{},
};

pub const CloseReason = enum(u32) {
    expired = 1,
    dismissed_by_user = 2,
    closed_by_call = 3,
    undefined = 4,
};

pub const Response = union(enum) {
    action: struct {
        /// Borrowed from the provider's message buffer. Copy the key to keep
        /// it past the callback that received it.
        key: []const u8,
    },
    closed: struct {
        reason: CloseReason,
    },
    /// The provider went away before the user answered. Nothing was displayed
    /// and nothing was dismissed, so this is deliberately not a close reason.
    provider_lost,
};

/// One response a provider received through its transport rather than inside a
/// call, which is what a bus signal or a toast activation is. The key borrows
/// from whatever buffer the provider owns, on the terms `Response` states.
pub const QueuedResponse = struct {
    id: NotificationId,
    response: Response,
};

pub const ProviderError = enum {
    disconnected,
    timeout,
    protocol_error,
    rejected,
    out_of_memory,
    io_error,
    service_unknown,
    permission_denied,
};

pub const SubmitOutcome = union(enum) {
    accepted: NotificationId,
    unsupported,
    denied,
    provider_failed: ProviderError,
};

/// The result of a dismissal. A caller must be able to tell a provider that
/// refused the close from a provider that could not be reached, because the
/// first leaves a notification on screen and the second cannot say.
pub const DismissOutcome = union(enum) {
    /// The provider closed the notification and tracking stopped.
    closed,
    /// Nothing could take the close: no provider is attached, or the one that
    /// is has no notification service behind it. There was never a
    /// notification to close, so this is not a refusal either.
    unsupported,
    /// The provider declined the close. The notification stays on screen with
    /// its actions intact, so it stays tracked.
    refused,
    /// The provider could not complete the close and names why. Nothing here
    /// is evidence that the notification went away, so it stays tracked: a
    /// provider whose transport is really gone completes the wait through
    /// `handleProviderDisconnect` instead of through a dismissal.
    provider_failed: ProviderError,
};

/// Weak owner descriptor shared with the credential service. Deliveries to a
/// dead owner are dropped instead of resurrecting a dead model or Session.
pub const WeakOwner = @import("weak_owner.zig").WeakOwner;

pub const ActionHandler = struct {
    context: ?*anyopaque = null,
    callback: *const fn (context: ?*anyopaque, id: NotificationId, response: Response) void,
};

pub const Capabilities = struct {
    // Every capability defaults to false so the zero value claims nothing.
    // A permissive default would let a provider that never answered advertise
    // a body and action buttons that can never be delivered.
    body: bool = false,
    body_hyperlinks: bool = false,
    body_markup: bool = false,
    body_images: bool = false,
    actions: bool = false,
    action_icons: bool = false,
    sound: bool = false,
    persistence: bool = false,

    /// Nothing is supported. This is what a missing, terminated or
    /// unreachable provider reports.
    pub const none: Capabilities = .{};
};

pub const NotificationProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Must not call back into or mutate this service during submit. Later
        /// response events are delivered through poll. The service reserves its
        /// tracking capacity before this call.
        submit: *const fn (ctx: *anyopaque, options: NotificationOptions) SubmitOutcome,
        /// Close one notification and report what became of it.
        ///
        /// The answer is typed because the outcomes a close can have are
        /// different facts: a live provider that refused leaves the
        /// notification on screen, a transport that is gone can never close
        /// anything again, and a protocol or allocation failure is neither. A
        /// caller that reads a failure as a refusal waits on a notification
        /// nobody will ever close.
        dismiss: *const fn (ctx: *anyopaque, id: NotificationId) DismissOutcome,
        getCapabilities: *const fn (ctx: *anyopaque) Capabilities,
        disconnect: *const fn (ctx: *anyopaque) void,
        deinit: *const fn (ctx: *anyopaque) void,
        /// Moves responses the provider received outside a call into the
        /// service: a bus signal, or a toast the user activated while the host
        /// was busy. Returns how many it handed to the service.
        ///
        /// Null for a provider that answers inside the call that asked, which
        /// is the default, so such a provider is never asked to drive anything.
        poll: ?*const fn (
            ctx: *anyopaque,
            service: *NotificationsService,
            timeout_ms: i32,
        ) anyerror!usize = null,
    };

    pub fn submit(self: NotificationProvider, options: NotificationOptions) SubmitOutcome {
        return self.vtable.submit(self.ptr, options);
    }

    pub fn dismiss(self: NotificationProvider, id: NotificationId) DismissOutcome {
        return self.vtable.dismiss(self.ptr, id);
    }

    pub fn getCapabilities(self: NotificationProvider) Capabilities {
        return self.vtable.getCapabilities(self.ptr);
    }

    pub fn disconnect(self: NotificationProvider) void {
        self.vtable.disconnect(self.ptr);
    }

    pub fn deinit(self: NotificationProvider) void {
        self.vtable.deinit(self.ptr);
    }

    /// Deliver whatever the provider received since the last call. Returns how
    /// many it handed to the service, which is not the same as how many owners
    /// answered: a response for a notification nobody is tracking reaches
    /// nobody. `timeout_ms` of 0 never blocks. Zero when this provider has no
    /// transport to drain.
    pub fn poll(
        self: NotificationProvider,
        service: *NotificationsService,
        timeout_ms: i32,
    ) anyerror!usize {
        const pump = self.vtable.poll orelse return 0;
        return pump(self.ptr, service, timeout_ms);
    }

    /// True when this provider hands its responses over only when it is driven,
    /// so a service holding it has to call `poll` for a user answer to arrive.
    pub fn isPollDriven(self: NotificationProvider) bool {
        return self.vtable.poll != null;
    }
};

const TrackedNotification = struct {
    id: NotificationId,
    owner: WeakOwner,
    handler: ?ActionHandler,
};

pub const NotificationsService = struct {
    allocator: std.mem.Allocator,
    provider: ?NotificationProvider,
    tracked: std.AutoHashMap(NotificationId, TrackedNotification),
    /// Set once the host shut the service down or the provider went away.
    /// While it is set no provider call starts and no owner is delivered to.
    is_terminated: bool = false,

    pub fn init(allocator: std.mem.Allocator, provider: ?NotificationProvider) NotificationsService {
        return .{
            .allocator = allocator,
            .provider = provider,
            .tracked = std.AutoHashMap(NotificationId, TrackedNotification).init(allocator),
            .is_terminated = false,
        };
    }

    pub fn deinit(self: *NotificationsService) void {
        self.shutdown();
        self.tracked.deinit();
        if (self.provider) |p| {
            p.deinit();
            self.provider = null;
        }
        self.* = undefined;
    }

    /// Shutdown the notification service. Disconnects provider and completes
    /// pending tracking. Native callbacks after shutdown cannot resurrect dead owners.
    pub fn shutdown(self: *NotificationsService) void {
        self.terminate(.{ .closed = .{ .reason = .closed_by_call } });
    }

    /// Report that the provider went away, for example because its bus
    /// connection dropped. Every notification still waiting for a user answer
    /// completes with `provider_lost`, so no owner waits for an answer that
    /// cannot arrive, and a late native callback finds nothing left to
    /// resurrect.
    pub fn handleProviderDisconnect(self: *NotificationsService) void {
        self.terminate(.provider_lost);
    }

    /// Stop accepting work, release the provider and complete every tracked
    /// notification once with `result`. The flag is raised before the first
    /// delivery, so a reentrant call cannot mutate the map this walks.
    fn terminate(self: *NotificationsService, result: Response) void {
        if (self.is_terminated) return;
        self.is_terminated = true;

        if (self.provider) |p| {
            p.disconnect();
        }

        // Tell every live owner that its notification is over. A dead owner is
        // dropped: its notification does not get a second chance to reach it.
        var it = self.tracked.iterator();
        while (it.next()) |entry| {
            const tracked_item = entry.value_ptr.*;
            if (tracked_item.owner.isAlive()) {
                if (tracked_item.handler) |h| {
                    h.callback(h.context, tracked_item.id, result);
                }
            }
        }
        self.tracked.clearRetainingCapacity();
    }

    /// Submit a notification.
    /// Provider acceptance is reported separately from actual user display or response.
    pub fn submit(
        self: *NotificationsService,
        options: NotificationOptions,
        owner: WeakOwner,
        handler: ?ActionHandler,
    ) SubmitOutcome {
        if (self.is_terminated) return .{ .provider_failed = .disconnected };

        // Validate options
        if (!std.unicode.utf8ValidateSlice(options.summary)) return .{ .provider_failed = .protocol_error };
        if (!std.unicode.utf8ValidateSlice(options.body)) return .{ .provider_failed = .protocol_error };
        if (options.summary.len == 0) return .{ .provider_failed = .protocol_error };

        const p = self.provider orelse return .unsupported;

        // Reserve tracking before the provider can accept. A tracked
        // replacement reuses the old entry's slot.
        var needs_room = true;
        if (options.replaces_id) |old_id| needs_room = !self.tracked.contains(old_id);
        if (needs_room) {
            self.tracked.ensureUnusedCapacity(1) catch
                return .{ .provider_failed = .out_of_memory };
        }

        const outcome = p.submit(options);

        switch (outcome) {
            .accepted => |new_id| {
                // If replacing an existing notification, update or remove old entry
                if (options.replaces_id) |old_id| {
                    _ = self.tracked.remove(old_id);
                }

                // The room was taken before the provider was asked, so this
                // insert cannot allocate and cannot fail after acceptance.
                self.tracked.putAssumeCapacity(new_id, .{
                    .id = new_id,
                    .owner = owner,
                    .handler = handler,
                });

                return .{ .accepted = new_id };
            },
            else => return outcome,
        }
    }

    /// Replace an existing notification, keeping the owner that asked for it.
    ///
    /// A replacement is the same notification with new content, so it answers
    /// the owner that asked for the original one. This call takes no owner of
    /// its own, which means an id the service does not track, or one whose
    /// owner has since been released, has nothing to inherit. Submitting
    /// anyway would post a toast whose buttons reach nobody: the host believes
    /// it is tracking a notification and the user's screen gains one that no
    /// owner can answer. Both are refused before the provider is asked, so
    /// such a toast is never posted.
    pub fn replace(
        self: *NotificationsService,
        id: NotificationId,
        options: NotificationOptions,
    ) SubmitOutcome {
        // Copied out before the provider is called: the submit below removes
        // this entry, and the replacement has to carry the owner that asked.
        const existing = self.tracked.get(id) orelse
            return .{ .provider_failed = .rejected };
        if (!existing.owner.isAlive()) return .{ .provider_failed = .rejected };

        var opts = options;
        opts.replaces_id = id;
        return self.submit(opts, existing.owner, existing.handler);
    }

    /// Dismiss an active notification.
    ///
    /// Only a notification the provider actually closed stops being routed: a
    /// refused close leaves it on screen with its actions intact, and so does a
    /// close that failed, because a provider that could not answer is not
    /// evidence that anything went away. A missing or gone provider is
    /// reported as such rather than as a refusal.
    pub fn dismiss(self: *NotificationsService, id: NotificationId) DismissOutcome {
        if (self.is_terminated) return .{ .provider_failed = .disconnected };
        const p = self.provider orelse return .unsupported;

        const outcome = p.dismiss(id);
        switch (outcome) {
            .closed => _ = self.tracked.remove(id),
            .refused, .unsupported, .provider_failed => {},
        }
        return outcome;
    }

    /// Dispatch an incoming response from the native provider.
    /// Delayed action for a dead owner is ignored safely without resurrecting Session.
    pub fn handleResponse(self: *NotificationsService, id: NotificationId, response: Response) void {
        if (self.is_terminated) return;

        const entry = self.tracked.get(id) orelse return;

        // Verify that weak owner is still alive
        if (!entry.owner.isAlive()) {
            // Owner is dead: safely ignore delayed action and unregister
            _ = self.tracked.remove(id);
            return;
        }

        // A close ends this notification, so the entry goes before the owner
        // is told. A handler that shuts the service down from its close
        // callback then finds nothing left to complete, and one id produces
        // one terminal response instead of the same answer twice.
        const closed = response == .closed;
        if (closed) {
            _ = self.tracked.remove(id);
        }

        if (entry.handler) |h| {
            h.callback(h.context, id, response);
        }
    }

    /// Let the provider's transport deliver, and route whatever it received.
    /// Returns how many it handed to this service.
    ///
    /// `timeout_ms` of 0 never blocks, so a host can call this once per frame
    /// beside its input pump. A provider that answers inside the call that asked
    /// has nothing to drain, and this reports zero for it rather than refusing.
    ///
    /// A transport that fails is returned to the host, not folded into the
    /// count: a drain that failed to drain is not a service with nothing to
    /// say, and a host that cannot tell the two apart stops reporting answers
    /// it never got.
    pub fn pump(self: *NotificationsService, timeout_ms: i32) anyerror!usize {
        if (self.is_terminated) return 0;
        const p = self.provider orelse return 0;
        return p.poll(self, timeout_ms);
    }

    pub fn getCapabilities(self: *const NotificationsService) Capabilities {
        if (self.is_terminated) return .none;
        if (self.provider) |p| {
            return p.getCapabilities();
        }
        return .none;
    }
};

/// In-memory mock notification provider for deterministic unit testing.
pub const MockNotificationProvider = struct {
    allocator: std.mem.Allocator,
    next_id: NotificationId = 1,
    submit_outcome: SubmitOutcome = .{ .accepted = 1 },
    /// What one close reports. A test names the failure it is about here,
    /// which is the only way to reach a path a live platform will not produce
    /// on demand.
    dismiss_outcome: DismissOutcome = .closed,
    capabilities: Capabilities = .{},
    submitted: std.ArrayList(NotificationOptions) = .empty,
    dismissed: std.ArrayList(NotificationId) = .empty,
    disconnected: bool = false,
    /// Responses that arrive through the transport rather than inside a call,
    /// which is what a bus signal or a toast activation is. `poll` delivers
    /// them, one per queued entry.
    queued: std.ArrayList(QueuedResponse) = .empty,
    /// What one drain fails with, so a test can drive a transport that dies.
    poll_error: ?anyerror = null,
    /// How many times the service drove this provider.
    poll_calls: usize = 0,

    pub fn init(allocator: std.mem.Allocator) MockNotificationProvider {
        return .{
            .allocator = allocator,
            .next_id = 1,
            .submit_outcome = .{ .accepted = 1 },
            .dismiss_outcome = .closed,
            .capabilities = .{},
            .submitted = .empty,
            .dismissed = .empty,
            .disconnected = false,
            .queued = .empty,
        };
    }

    pub fn deinit(self: *MockNotificationProvider) void {
        self.submitted.deinit(self.allocator);
        self.dismissed.deinit(self.allocator);
        self.queued.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn provider(self: *MockNotificationProvider) NotificationProvider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable: NotificationProvider.VTable = .{
        .submit = submitFn,
        .dismiss = dismissFn,
        .getCapabilities = getCapabilitiesFn,
        .disconnect = disconnectFn,
        .deinit = deinitFn,
        .poll = pollFn,
    };

    fn submitFn(ctx: *anyopaque, options: NotificationOptions) SubmitOutcome {
        const self: *MockNotificationProvider = @ptrCast(@alignCast(ctx));
        if (self.disconnected) return .{ .provider_failed = .disconnected };

        self.submitted.append(self.allocator, options) catch return .{ .provider_failed = .out_of_memory };

        switch (self.submit_outcome) {
            .accepted => {
                const id = self.next_id;
                self.next_id += 1;
                return .{ .accepted = id };
            },
            else => return self.submit_outcome,
        }
    }

    fn dismissFn(ctx: *anyopaque, id: NotificationId) DismissOutcome {
        const self: *MockNotificationProvider = @ptrCast(@alignCast(ctx));
        if (self.disconnected) return .{ .provider_failed = .disconnected };
        self.dismissed.append(self.allocator, id) catch
            return .{ .provider_failed = .out_of_memory };
        return self.dismiss_outcome;
    }

    fn getCapabilitiesFn(ctx: *anyopaque) Capabilities {
        const self: *MockNotificationProvider = @ptrCast(@alignCast(ctx));
        return self.capabilities;
    }

    fn disconnectFn(ctx: *anyopaque) void {
        const self: *MockNotificationProvider = @ptrCast(@alignCast(ctx));
        self.disconnected = true;
    }

    fn pollFn(
        ctx: *anyopaque,
        service: *NotificationsService,
        timeout_ms: i32,
    ) anyerror!usize {
        _ = timeout_ms;
        const self: *MockNotificationProvider = @ptrCast(@alignCast(ctx));
        self.poll_calls += 1;
        // A provider that was disconnected has no transport left, so the drain
        // fails rather than answering from a ring the service stopped owning.
        if (self.disconnected) return error.ProviderGone;
        if (self.poll_error) |err| return err;

        var routed: usize = 0;
        while (self.queued.items.len != 0) {
            const queued = self.queued.orderedRemove(0);
            service.handleResponse(queued.id, queued.response);
            routed += 1;
        }
        return routed;
    }

    fn deinitFn(ctx: *anyopaque) void {
        const self: *MockNotificationProvider = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};

/// The owner a service delivers to, recorded so a test can say what reached it
/// rather than only how often.
const TestOwner = struct {
    alive: bool = true,
    action_called: usize = 0,
    closed_called: usize = 0,
    last_action: ?[]const u8 = null,
    /// The notification the last response was for. Two notifications can offer
    /// the same action key, so the key alone does not say which one answered.
    last_id: NotificationId = 0,
    provider_lost_called: usize = 0,
    last_reason: ?CloseReason = null,

    fn checkAlive(ctx: *const anyopaque) bool {
        const self: *const TestOwner = @ptrCast(@alignCast(ctx));
        return self.alive;
    }

    fn onResponse(ctx: ?*anyopaque, id: NotificationId, response: Response) void {
        const self: *TestOwner = @ptrCast(@alignCast(ctx.?));
        self.last_id = id;
        switch (response) {
            .action => |act| {
                self.action_called += 1;
                self.last_action = act.key;
            },
            .closed => |cls| {
                self.closed_called += 1;
                self.last_reason = cls.reason;
            },
            .provider_lost => {
                self.provider_lost_called += 1;
            },
        }
    }

    fn weak(self: *TestOwner) WeakOwner {
        return .{ .context = self, .is_alive_fn = checkAlive };
    }

    fn handler(self: *TestOwner) ActionHandler {
        return .{ .context = self, .callback = onResponse };
    }
};

test "notifications service submit and separate response dispatch" {
    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    var owner: TestOwner = .{};
    const weak_owner = owner.weak();
    const handler = owner.handler();

    // 1. Submit returns accepted ID immediately
    const outcome = service.submit(.{
        .summary = "Hello",
        .body = "World",
    }, weak_owner, handler);

    try std.testing.expect(outcome == .accepted);
    const id = outcome.accepted;
    try std.testing.expectEqual(@as(NotificationId, 1), id);

    // Acceptance is reported separately from user display or response:
    // callback must NOT have been called yet!
    try std.testing.expectEqual(@as(usize, 0), owner.action_called);
    try std.testing.expectEqual(@as(usize, 0), owner.closed_called);

    // 2. Simulate user action click
    service.handleResponse(id, .{ .action = .{ .key = "default" } });
    try std.testing.expectEqual(@as(usize, 1), owner.action_called);
    try std.testing.expectEqualStrings("default", owner.last_action.?);

    // 3. Simulate notification dismissed
    service.handleResponse(id, .{ .closed = .{ .reason = .dismissed_by_user } });
    try std.testing.expectEqual(@as(usize, 1), owner.closed_called);
    try std.testing.expectEqual(CloseReason.dismissed_by_user, owner.last_reason.?);
}

test "notifications service pumps a provider transport and routes what it delivers" {
    // The service owns the provider and keeps no reference to it, so a response
    // that arrives outside the call that asked has exactly one path to an owner:
    // the service driving the provider. A provider whose queue nobody drains
    // holds the user's answer and never runs the owner's callback, which looks
    // exactly like a user who never clicked.
    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    try std.testing.expect(mock.provider().isPollDriven());

    var first: TestOwner = .{};
    var second: TestOwner = .{};
    const outcome = service.submit(.{ .summary = "Hello" }, first.weak(), first.handler());
    try std.testing.expect(outcome == .accepted);
    const id = outcome.accepted;

    // Nothing is delivered before the transport is pumped: provider acceptance
    // is reported separately from a user response.
    try std.testing.expectEqual(@as(usize, 0), try service.pump(0));
    try std.testing.expectEqual(@as(usize, 0), first.action_called);

    // Two notifications offering the same action key. The response carries the
    // notification it belongs to, so each owner hears about its own and not
    // about whichever happened to be drained first.
    const other = service.submit(
        .{ .summary = "Hello" },
        second.weak(),
        second.handler(),
    );
    try std.testing.expect(other == .accepted);
    const other_id = other.accepted;
    try std.testing.expect(other_id != id);

    try mock.queued.append(std.testing.allocator, .{
        .id = id,
        .response = .{ .action = .{ .key = "reply" } },
    });
    try mock.queued.append(std.testing.allocator, .{
        .id = other_id,
        .response = .{ .action = .{ .key = "reply" } },
    });
    try std.testing.expectEqual(@as(usize, 2), try service.pump(0));
    try std.testing.expectEqual(@as(usize, 1), first.action_called);
    try std.testing.expectEqual(id, first.last_id);
    try std.testing.expectEqualStrings("reply", first.last_action.?);
    try std.testing.expectEqual(@as(usize, 1), second.action_called);
    try std.testing.expectEqual(other_id, second.last_id);

    // A drained queue is drained once: pumping again reaches the provider and
    // delivers nothing, rather than reporting a second answer nobody gave.
    try std.testing.expectEqual(@as(usize, 0), try service.pump(0));
    try std.testing.expectEqual(@as(usize, 1), first.action_called);
    try std.testing.expectEqual(@as(usize, 1), second.action_called);

    // A transport that fails mid-drain is named to the host. Folding it into
    // the count would report a service with nothing to say for a transport
    // that broke, and the host would keep waiting for an answer it never got.
    mock.poll_error = error.OutOfMemory;
    try std.testing.expectError(error.OutOfMemory, service.pump(0));
    try std.testing.expectEqual(@as(usize, 1), first.action_called);

    // A shutdown service answers nothing, whatever the provider still holds, so
    // a host that pumps after its own shutdown cannot resurrect a dead owner.
    service.shutdown();
    mock.poll_error = null;
    const calls = mock.poll_calls;
    try mock.queued.append(std.testing.allocator, .{
        .id = id,
        .response = .{ .closed = .{ .reason = .dismissed_by_user } },
    });
    try std.testing.expectEqual(@as(usize, 0), try service.pump(0));
    try std.testing.expectEqual(@as(usize, 1), first.closed_called);
    // The provider is not even asked: a transport that a terminated service no
    // longer owns has nothing to deliver to, and a drain that reached into it
    // would be a second owner of a queue this service has already released.
    try std.testing.expectEqual(calls, mock.poll_calls);
}

test "notifications service keeps one terminal response when its handler shuts down" {
    // A response handler is free to shut the service down, and a host does
    // exactly that when the notification it was told about is the one that
    // ended the session. The owner that dismissed its own toast must still
    // report that dismissal: a second terminal response naming the shutdown
    // reason tells the host the user closed something the service closed, and
    // counts one answer twice.
    const DismissingOwner = struct {
        const Self = @This();

        service: *NotificationsService,
        record: ActionHandler,
        shutdowns: usize = 0,

        fn dispatch(ctx: ?*anyopaque, id: NotificationId, response: Response) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.record.callback(self.record.context, id, response);
            self.shutdowns += 1;
            self.service.shutdown();
        }
    };

    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    var first: TestOwner = .{};
    var second: TestOwner = .{};
    var dismissing: DismissingOwner = .{ .service = &service, .record = first.handler() };

    const first_outcome = service.submit(
        .{ .summary = "Hello" },
        first.weak(),
        .{ .context = &dismissing, .callback = DismissingOwner.dispatch },
    );
    try std.testing.expect(first_outcome == .accepted);
    const first_id = first_outcome.accepted;

    const second_outcome = service.submit(.{ .summary = "World" }, second.weak(), second.handler());
    try std.testing.expect(second_outcome == .accepted);
    const second_id = second_outcome.accepted;

    // The user dismissed the first notification and that answer is what ends
    // the session. The close comes off the transport, so it travels the one
    // dispatch path a bus signal and a toast activation both take.
    try mock.queued.append(std.testing.allocator, .{
        .id = first_id,
        .response = .{ .closed = .{ .reason = .dismissed_by_user } },
    });
    try std.testing.expectEqual(@as(usize, 1), try service.pump(0));
    try std.testing.expectEqual(@as(usize, 1), dismissing.shutdowns);

    // The owner that dismissed its notification is completed once, for that
    // notification, with the reason the user gave.
    try std.testing.expectEqual(@as(usize, 1), first.closed_called);
    try std.testing.expectEqual(first_id, first.last_id);
    try std.testing.expectEqual(CloseReason.dismissed_by_user, first.last_reason.?);

    // The other notification never got a user answer, so the shutdown is the
    // only thing that ends it, and it ends it exactly once.
    try std.testing.expectEqual(@as(usize, 0), second.action_called);
    try std.testing.expectEqual(@as(usize, 1), second.closed_called);
    try std.testing.expectEqual(second_id, second.last_id);
    try std.testing.expectEqual(CloseReason.closed_by_call, second.last_reason.?);

    // That one terminal completion released the transport.
    try std.testing.expect(mock.disconnected);
    const polls = mock.poll_calls;

    // Events that raced the shutdown find no tracking left, so neither owner
    // hears a second answer to a notification that is already over, and the
    // released transport is not asked for anything again.
    service.handleResponse(first_id, .{ .closed = .{ .reason = .expired } });
    service.handleResponse(second_id, .{ .action = .{ .key = "reply" } });
    try std.testing.expectEqual(@as(usize, 0), try service.pump(0));
    try std.testing.expectEqual(polls, mock.poll_calls);
    try std.testing.expectEqual(@as(usize, 1), first.closed_called);
    try std.testing.expectEqual(CloseReason.dismissed_by_user, first.last_reason.?);
    try std.testing.expectEqual(@as(usize, 1), second.closed_called);
    try std.testing.expectEqual(CloseReason.closed_by_call, second.last_reason.?);
    try std.testing.expectEqual(@as(usize, 0), second.action_called);
}

/// What a run of submits under memory pressure produced: every notification
/// the service accepted on the way, and the id the provider would have handed
/// out to the one it refused.
const Refusal = struct {
    accepted: std.ArrayList(NotificationId) = .empty,
    spent_id: NotificationId = 0,
};

/// Track one notification while the service still has memory, then take that
/// memory away and keep submitting until the service refuses one. Every
/// notification it accepted on the way is recorded, and so is what the refused
/// submit must not have done: the service tracks on a failing allocator while
/// the provider keeps a working one, so the pressure belongs to the service
/// and the provider is the witness.
fn submitUntilRefused(
    gpa: std.mem.Allocator,
    failing: *std.testing.FailingAllocator,
    service: *NotificationsService,
    mock: *MockNotificationProvider,
    owner: WeakOwner,
    handler: ActionHandler,
) !Refusal {
    var refusal: Refusal = .{};
    // The caller owns the list once this returns it, so every failure below
    // has to release it instead of dropping it on the floor.
    errdefer refusal.accepted.deinit(gpa);

    // A service that never tracked anything is not what runs out of room, so
    // the walk starts from a notification the service is holding.
    const first = service.submit(.{ .summary = "Build finished" }, owner, handler);
    switch (first) {
        .accepted => |id| try refusal.accepted.append(gpa, id),
        else => return error.FirstSubmitRefused,
    }

    // The service now refuses every allocation it makes. A refused allocation
    // leaves the counter where it was, so the pressure lasts until the caller
    // takes it away again.
    failing.fail_index = failing.alloc_index;

    // A budget, so a service that never refuses fails this test instead of
    // running it forever. It is not a count of submissions anything relies on.
    const budget = 4096;
    var tried: usize = 0;
    while (tried < budget) : (tried += 1) {
        // What the provider had done before this submit, so the refused one
        // can be shown not to have reached it.
        const shown = mock.submitted.items.len;
        const next_id = mock.next_id;

        const outcome = service.submit(.{ .summary = "Build finished" }, owner, handler);
        switch (outcome) {
            .accepted => |id| try refusal.accepted.append(gpa, id),
            .provider_failed => |failure| {
                try std.testing.expectEqual(ProviderError.out_of_memory, failure);
                try std.testing.expectEqual(shown, mock.submitted.items.len);
                try std.testing.expectEqual(next_id, mock.next_id);
                refusal.spent_id = next_id;
                return refusal;
            },
            .unsupported, .denied => return error.SubmitRefusedWithoutMemoryPressure,
        }
    }
    return error.ServiceNeverRefused;
}

test "api-w19 a notification the service cannot track is refused before the provider is asked" {
    // A memory the service cannot get stops it taking notifications somewhere.
    // Every notification it accepted before that point is a toast on the
    // user's screen, so every one of them must still answer the owner that
    // asked for it, and the one it refused must never have reached the
    // desktop: a submit that cannot be tracked is refused before the provider
    // is asked, so the user is given no toast the host can never hear from and
    // the daemon spends no id on it.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(failing.allocator(), mock.provider());
    defer service.deinit();

    var owner: TestOwner = .{};
    var refused = try submitUntilRefused(
        std.testing.allocator,
        &failing,
        &service,
        &mock,
        owner.weak(),
        owner.handler(),
    );
    defer refused.accepted.deinit(std.testing.allocator);

    // Every notification the service accepted is on the screen, so each one
    // answers its owner under the id that owner knows.
    for (refused.accepted.items) |id| {
        service.handleResponse(id, .{ .action = .{ .key = "view_log" } });
        try std.testing.expectEqual(id, owner.last_id);
    }
    try std.testing.expectEqual(refused.accepted.items.len, owner.action_called);

    // With memory again the next notification is accepted, and it takes the id
    // the refused submit left unspent.
    failing.fail_index = std.math.maxInt(usize);
    const recovered = service.submit(
        .{ .summary = "Build finished" },
        owner.weak(),
        owner.handler(),
    );
    try std.testing.expect(recovered == .accepted);
    try std.testing.expectEqual(refused.spent_id, recovered.accepted);

    service.handleResponse(recovered.accepted, .{ .action = .{ .key = "view_log" } });
    try std.testing.expectEqual(refused.accepted.items.len + 1, owner.action_called);
    try std.testing.expectEqual(recovered.accepted, owner.last_id);
}

test "api-w19 a refused replacement spends no id and leaves the live notification with its owner" {
    // A host replaces a notification the service no longer tracks, which is an
    // id nothing frees a slot for: the owner died, the entry went with it and
    // the toast is still on the screen. Under memory pressure that
    // replacement is refused, and the refusal is about the replacement alone.
    // The daemon is not asked, so no toast the host cannot hear from replaces
    // one it can, the notification the host is still showing keeps its owner
    // and its handler, and the id the refused replacement would have used
    // answers nobody.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(failing.allocator(), mock.provider());
    defer service.deinit();

    var owner: TestOwner = .{};
    var dead: TestOwner = .{};

    const live = service.submit(
        .{ .summary = "Downloading", .body = "10% complete" },
        owner.weak(),
        owner.handler(),
    );
    try std.testing.expect(live == .accepted);
    const live_id = live.accepted;

    const gone = service.submit(
        .{ .summary = "Uploading", .body = "1 of 3 files" },
        dead.weak(),
        dead.handler(),
    );
    try std.testing.expect(gone == .accepted);
    const gone_id = gone.accepted;

    // The owner is gone, so the service stops tracking its notification while
    // the toast stays on the screen and the host keeps the id.
    dead.alive = false;
    service.handleResponse(gone_id, .{ .action = .{ .key = "cancel" } });
    try std.testing.expectEqual(@as(usize, 0), dead.action_called);

    var refused = try submitUntilRefused(
        std.testing.allocator,
        &failing,
        &service,
        &mock,
        owner.weak(),
        owner.handler(),
    );
    defer refused.accepted.deinit(std.testing.allocator);

    const outcome = service.submit(
        .{ .summary = "Uploading", .body = "2 of 3 files", .replaces_id = gone_id },
        owner.weak(),
        owner.handler(),
    );
    try std.testing.expect(outcome == .provider_failed);
    try std.testing.expectEqual(ProviderError.out_of_memory, outcome.provider_failed);
    try std.testing.expectEqual(refused.spent_id, mock.next_id);

    // The notification the host is still showing is untouched: its owner hears
    // the action, with the id that owner knows.
    service.handleResponse(live_id, .{ .action = .{ .key = "cancel" } });
    try std.testing.expectEqual(@as(usize, 1), owner.action_called);
    try std.testing.expectEqual(live_id, owner.last_id);
    try std.testing.expectEqualStrings("cancel", owner.last_action.?);

    // The refused replacement answers nobody. There is no toast with that id,
    // so a frame the transport may still deliver goes nowhere.
    service.handleResponse(refused.spent_id, .{ .action = .{ .key = "cancel" } });
    try std.testing.expectEqual(@as(usize, 1), owner.action_called);

    // With memory again the replacement goes through, takes the unspent id and
    // answers the owner that asked for it.
    failing.fail_index = std.math.maxInt(usize);
    const recovered = service.submit(
        .{ .summary = "Uploading", .body = "2 of 3 files", .replaces_id = gone_id },
        owner.weak(),
        owner.handler(),
    );
    try std.testing.expect(recovered == .accepted);
    try std.testing.expectEqual(refused.spent_id, recovered.accepted);

    service.handleResponse(recovered.accepted, .{ .action = .{ .key = "view" } });
    try std.testing.expectEqual(@as(usize, 2), owner.action_called);
    try std.testing.expectEqual(recovered.accepted, owner.last_id);
    try std.testing.expectEqualStrings("view", owner.last_action.?);
}

test "api-w19 a tracked replacement under memory pressure still replaces and routes to its owner" {
    // A full table can still replace an entry while every allocation fails.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(failing.allocator(), mock.provider());
    defer service.deinit();

    var owner: TestOwner = .{};
    var refused = try submitUntilRefused(
        std.testing.allocator,
        &failing,
        &service,
        &mock,
        owner.weak(),
        owner.handler(),
    );
    defer refused.accepted.deinit(std.testing.allocator);
    const first_id = refused.accepted.items[0];
    const submitted_before = mock.submitted.items.len;

    const replace = service.replace(
        first_id,
        .{ .summary = "Downloading", .body = "90% complete" },
    );
    try std.testing.expect(replace == .accepted);
    const replace_id = replace.accepted;
    try std.testing.expect(replace_id != first_id);
    try std.testing.expectEqual(submitted_before + 1, mock.submitted.items.len);

    // The old id is gone, and the toast that replaced it answers the same owner
    // under the new id.
    service.handleResponse(first_id, .{ .action = .{ .key = "cancel" } });
    try std.testing.expectEqual(@as(usize, 0), owner.action_called);

    service.handleResponse(replace_id, .{ .action = .{ .key = "cancel" } });
    try std.testing.expectEqual(@as(usize, 1), owner.action_called);
    try std.testing.expectEqual(replace_id, owner.last_id);
    try std.testing.expectEqualStrings("cancel", owner.last_action.?);
}
