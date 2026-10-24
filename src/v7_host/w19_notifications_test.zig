//! Pure unit tests for W19 notification service, identity, replacement,
//! weak owner callback routing, dismissal, and shutdown lifecycle.
const std = @import("std");
const notifications = @import("notifications.zig");
const NotificationsService = notifications.NotificationsService;
const MockNotificationProvider = notifications.MockNotificationProvider;
const NotificationId = notifications.NotificationId;
const WeakOwner = notifications.WeakOwner;
const ActionHandler = notifications.ActionHandler;
const Response = notifications.Response;
const CloseReason = notifications.CloseReason;
const dbus = @import("linux/dbus.zig");
const DbusNotificationProvider = @import("linux/notifications_dbus.zig").DbusNotificationProvider;

const TestOwner = struct {
    alive: bool = true,
    action_calls: usize = 0,
    closed_calls: usize = 0,
    lost_calls: usize = 0,
    last_action: ?[]const u8 = null,
    last_reason: ?CloseReason = null,

    fn isAlive(ctx: *const anyopaque) bool {
        const self: *const TestOwner = @ptrCast(@alignCast(ctx));
        return self.alive;
    }

    fn onResponse(ctx: ?*anyopaque, id: NotificationId, response: Response) void {
        _ = id;
        const self: *TestOwner = @ptrCast(@alignCast(ctx.?));
        switch (response) {
            .action => |act| {
                self.action_calls += 1;
                self.last_action = act.key;
            },
            .closed => |cls| {
                self.closed_calls += 1;
                self.last_reason = cls.reason;
            },
            .provider_lost => {
                self.lost_calls += 1;
            },
        }
    }
};

test "api-w19 notification submit returns accepted id with provider separate from action callback" {
    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    const outcome = service.submit(.{
        .summary = "Build Completed",
        .body = "All 42 tests passed.",
        .app_name = "nogui_editor",
    }, weak_owner, handler);

    try std.testing.expect(outcome == .accepted);
    const id = outcome.accepted;
    try std.testing.expectEqual(@as(NotificationId, 1), id);

    // Provider acceptance is separate from user response/display:
    // Callback must not have fired during submit!
    try std.testing.expectEqual(@as(usize, 0), owner.action_calls);
    try std.testing.expectEqual(@as(usize, 0), owner.closed_calls);

    // Later: user clicks the action
    service.handleResponse(id, .{ .action = .{ .key = "view_log" } });
    try std.testing.expectEqual(@as(usize, 1), owner.action_calls);
    try std.testing.expectEqualStrings("view_log", owner.last_action.?);
    try std.testing.expectEqual(@as(usize, 0), owner.closed_calls);
}

test "api-w19 notification replacement updates existing notification and preserves response routing" {
    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    // Submit initial notification
    const first_outcome = service.submit(.{
        .summary = "Downloading...",
        .body = "10% complete",
    }, weak_owner, handler);
    try std.testing.expect(first_outcome == .accepted);
    const id1 = first_outcome.accepted;

    // Replace with updated progress
    const replace_outcome = service.replace(id1, .{
        .summary = "Downloading...",
        .body = "90% complete",
    });
    try std.testing.expect(replace_outcome == .accepted);
    const id2 = replace_outcome.accepted;

    // New ID is different (mock assigns monotonic IDs)
    try std.testing.expect(id2 != id1);

    // Action targeted to the old ID is safely ignored
    service.handleResponse(id1, .{ .action = .{ .key = "cancel" } });
    try std.testing.expectEqual(@as(usize, 0), owner.action_calls);

    // Action targeted to the replacement ID correctly reaches the owner
    service.handleResponse(id2, .{ .action = .{ .key = "cancel" } });
    try std.testing.expectEqual(@as(usize, 1), owner.action_calls);
    try std.testing.expectEqualStrings("cancel", owner.last_action.?);
}

test "api-w19 a replacement with no live owner to inherit is refused and posts no toast" {
    // A replacement answers the owner that asked for the notification being
    // replaced, so it carries no owner of its own. An id the service does not
    // track, or one whose owner has since been released, has nobody to answer
    // it, and posting it anyway would put a toast on the user's screen whose
    // buttons reach no one. The provider must never be asked, so the user is
    // given no such toast at all.
    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    // An id this service never handed out. There is no entry to inherit from.
    const shown = mock.submitted.items.len;
    const unknown = service.replace(4242, .{ .summary = "Downloading" });
    try std.testing.expect(unknown == .provider_failed);
    try std.testing.expectEqual(notifications.ProviderError.rejected, unknown.provider_failed);
    try std.testing.expectEqual(shown, mock.submitted.items.len);
    try std.testing.expectEqual(@as(usize, 0), service.tracked.count());

    // A tracked notification whose owner has been released. The toast is still
    // on screen, but the owner behind it is gone, so a replacement would still
    // have nobody to answer.
    const accepted = service.submit(.{ .summary = "Uploading" }, weak_owner, handler);
    try std.testing.expect(accepted == .accepted);
    const id = accepted.accepted;
    owner.alive = false;

    const after_submit = mock.submitted.items.len;
    const released = service.replace(id, .{ .summary = "Uploading", .body = "2 of 3 files" });
    try std.testing.expect(released == .provider_failed);
    try std.testing.expectEqual(notifications.ProviderError.rejected, released.provider_failed);
    try std.testing.expectEqual(after_submit, mock.submitted.items.len);

    // The refused replacement reached neither the owner nor the daemon, and it
    // left the notification that was still on screen tracked and untouched, so
    // the one toast the host can account for is the one that stays.
    try std.testing.expectEqual(@as(usize, 0), owner.action_calls);
    try std.testing.expect(service.tracked.contains(id));
    try std.testing.expectEqual(@as(usize, 1), service.tracked.count());

    // A live owner still gets its replacement, so the refusal is about the
    // missing owner and not about replacing at all.
    var live: TestOwner = .{};
    const live_weak: WeakOwner = .{ .context = &live, .is_alive_fn = TestOwner.isAlive };
    const live_handler: ActionHandler = .{ .context = &live, .callback = TestOwner.onResponse };
    const first = service.submit(.{ .summary = "Downloading" }, live_weak, live_handler);
    try std.testing.expect(first == .accepted);
    const first_id = first.accepted;

    const replaced = service.replace(first_id, .{ .summary = "Downloading", .body = "90% complete" });
    try std.testing.expect(replaced == .accepted);
    const replaced_id = replaced.accepted;

    service.handleResponse(replaced_id, .{ .action = .{ .key = "cancel" } });
    try std.testing.expectEqual(@as(usize, 1), live.action_calls);
    try std.testing.expectEqualStrings("cancel", live.last_action.?);
}

test "api-w19 a close is reported distinctly from a user action and each close reason reaches its owner" {
    // Three different things end a notification, and the host has to be able
    // to tell them apart: the user pressed a button, the toast expired on its
    // own, and the host closed it by calling. A close that arrives while an
    // action is still possible must not read as the action, and a service
    // shutdown that closes what is left must name itself as the caller rather
    // than as the daemon.
    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    const first = service.submit(.{ .summary = "Build finished" }, weak_owner, handler);
    try std.testing.expect(first == .accepted);
    const first_id = first.accepted;

    const second = service.submit(.{ .summary = "Meeting reminder" }, weak_owner, handler);
    try std.testing.expect(second == .accepted);
    const second_id = second.accepted;

    // A user action is not a close: the toast may still be on screen and the
    // owner may still act, so the notification stays tracked.
    service.handleResponse(first_id, .{ .action = .{ .key = "view_log" } });
    try std.testing.expectEqual(@as(usize, 1), owner.action_calls);
    try std.testing.expectEqual(@as(usize, 0), owner.closed_calls);
    try std.testing.expectEqualStrings("view_log", owner.last_action.?);
    try std.testing.expect(service.tracked.contains(first_id));

    // An expiry names itself as the daemon's own expiry, and it ends the
    // notification: the same id answering again reaches nobody.
    service.handleResponse(first_id, .{ .closed = .{ .reason = .expired } });
    try std.testing.expectEqual(@as(usize, 1), owner.closed_calls);
    try std.testing.expectEqual(CloseReason.expired, owner.last_reason.?);
    try std.testing.expectEqual(@as(usize, 1), owner.action_calls);
    try std.testing.expect(!service.tracked.contains(first_id));

    service.handleResponse(first_id, .{ .action = .{ .key = "view_log" } });
    try std.testing.expectEqual(@as(usize, 1), owner.action_calls);
    try std.testing.expectEqual(@as(usize, 1), owner.closed_calls);

    // A host-initiated close names the caller, not the user and not the daemon.
    // It ends the notification while the action is still in reach.
    service.handleResponse(second_id, .{ .closed = .{ .reason = .closed_by_call } });
    try std.testing.expectEqual(@as(usize, 2), owner.closed_calls);
    try std.testing.expectEqual(CloseReason.closed_by_call, owner.last_reason.?);
    try std.testing.expect(!service.tracked.contains(second_id));

    // A shutdown closes what is left by name too, so the host never reads its
    // own teardown as something the daemon or the user did.
    const third = service.submit(.{ .summary = "Still waiting" }, weak_owner, handler);
    try std.testing.expect(third == .accepted);
    const third_id = third.accepted;

    service.shutdown();
    try std.testing.expectEqual(@as(usize, 3), owner.closed_calls);
    try std.testing.expectEqual(CloseReason.closed_by_call, owner.last_reason.?);
    try std.testing.expectEqual(@as(usize, 0), owner.lost_calls);
    try std.testing.expect(!service.tracked.contains(third_id));

    // Each of the three reasons was reported as itself, so the host can act on
    // the difference instead of treating every ending as one event.
    try std.testing.expectEqual(@as(usize, 0), service.tracked.count());
}

test "api-w19 a delayed action for a dead owner retires its registration exactly once" {
    // The owner ends while its toast is still on the daemon's screen. The
    // delayed answer that follows must reach nobody, and the registration that
    // pointed at the dead owner must be retired by that answer so the service
    // stops holding it. Every later answer for the same id then finds nothing
    // left, so a dead owner is retired once and not once per answer.
    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    var dead: TestOwner = .{};
    var live: TestOwner = .{};
    const dead_weak: WeakOwner = .{ .context = &dead, .is_alive_fn = TestOwner.isAlive };
    const dead_handler: ActionHandler = .{ .context = &dead, .callback = TestOwner.onResponse };
    const live_weak: WeakOwner = .{ .context = &live, .is_alive_fn = TestOwner.isAlive };
    const live_handler: ActionHandler = .{ .context = &live, .callback = TestOwner.onResponse };

    const gone = service.submit(.{ .summary = "Uploading" }, dead_weak, dead_handler);
    try std.testing.expect(gone == .accepted);
    const gone_id = gone.accepted;

    const kept = service.submit(.{ .summary = "Downloading" }, live_weak, live_handler);
    try std.testing.expect(kept == .accepted);
    const kept_id = kept.accepted;

    // The owner is released while both toasts are still on the daemon.
    dead.alive = false;

    // The delayed action the user took on the dead owner's toast. It is
    // dropped: no callback runs, so nothing reaches a released owner.
    try mock.queued.append(std.testing.allocator, .{
        .id = gone_id,
        .response = .{ .action = .{ .key = "cancel" } },
    });
    try std.testing.expectEqual(@as(usize, 1), try service.pump(0));
    try std.testing.expectEqual(@as(usize, 0), dead.action_calls);
    try std.testing.expectEqual(@as(usize, 0), dead.closed_calls);
    try std.testing.expectEqual(@as(usize, 0), dead.lost_calls);

    // That answer also retired the registration, so the service holds nothing
    // for the dead owner while the other notification is untouched.
    try std.testing.expect(!service.tracked.contains(gone_id));
    try std.testing.expect(service.tracked.contains(kept_id));
    try std.testing.expectEqual(@as(usize, 1), service.tracked.count());

    // Further answers for the same id find nothing to deliver and nothing to
    // retire, and the shutdown that follows completes only the live owner.
    try mock.queued.append(std.testing.allocator, .{
        .id = gone_id,
        .response = .{ .action = .{ .key = "cancel" } },
    });
    try mock.queued.append(std.testing.allocator, .{
        .id = gone_id,
        .response = .{ .closed = .{ .reason = .expired } },
    });
    _ = try service.pump(0);
    try std.testing.expectEqual(@as(usize, 0), dead.action_calls);
    try std.testing.expectEqual(@as(usize, 0), dead.closed_calls);
    try std.testing.expectEqual(@as(usize, 0), dead.lost_calls);

    service.shutdown();
    try std.testing.expectEqual(@as(usize, 0), dead.closed_calls);
    try std.testing.expectEqual(@as(usize, 1), live.closed_calls);
    try std.testing.expectEqual(CloseReason.closed_by_call, live.last_reason.?);
    try std.testing.expectEqual(@as(usize, 0), service.tracked.count());
}

test "api-w19 notification response for dead weak owner is safely ignored" {
    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    const outcome = service.submit(.{
        .summary = "Warning",
        .body = "Disk space low",
    }, weak_owner, handler);
    try std.testing.expect(outcome == .accepted);
    const id = outcome.accepted;

    // Simulate owner destruction / deinit
    owner.alive = false;

    // Delayed response from native notification daemon arrives
    service.handleResponse(id, .{ .action = .{ .key = "clean_disk" } });

    // The dead owner is never invoked, preventing resurrection or use-after-free
    try std.testing.expectEqual(@as(usize, 0), owner.action_calls);
    try std.testing.expectEqual(@as(usize, 0), owner.closed_calls);
}

test "api-w19 notification dismissal routes closed reason and removes tracking" {
    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    const outcome = service.submit(.{
        .summary = "Meeting reminder",
        .body = "Starts in 5 minutes",
    }, weak_owner, handler);
    try std.testing.expect(outcome == .accepted);
    const id = outcome.accepted;

    // Dismiss the notification
    const dismissed = service.dismiss(id);
    try std.testing.expectEqual(notifications.DismissOutcome.closed, dismissed);

    // Provider received dismiss request
    try std.testing.expectEqual(@as(usize, 1), mock.dismissed.items.len);
    try std.testing.expectEqual(id, mock.dismissed.items[0]);

    // Delayed responses for dismissed notifications are dropped
    service.handleResponse(id, .{ .action = .{ .key = "snooze" } });
    try std.testing.expectEqual(@as(usize, 0), owner.action_calls);
}

test "api-w19 notification denial unsupported and provider failure report typed outcomes" {
    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    // 1. Permission denied
    mock.submit_outcome = .denied;
    const denied_res = service.submit(.{ .summary = "Denied" }, .{}, null);
    try std.testing.expectEqual(notifications.SubmitOutcome.denied, denied_res);

    // 2. Provider error
    mock.submit_outcome = .{ .provider_failed = .service_unknown };
    const fail_res = service.submit(.{ .summary = "Failed" }, .{}, null);
    try std.testing.expect(fail_res == .provider_failed);
    try std.testing.expectEqual(notifications.ProviderError.service_unknown, fail_res.provider_failed);

    // 3. Unsupported (service has no provider attached)
    var unsupported_service = NotificationsService.init(std.testing.allocator, null);
    defer unsupported_service.deinit();
    const unsup_res = unsupported_service.submit(.{ .summary = "No provider" }, .{}, null);
    try std.testing.expectEqual(notifications.SubmitOutcome.unsupported, unsup_res);
    // A dismissal has nowhere to go either, and that is not a refusal from
    // a provider that exists.
    try std.testing.expectEqual(notifications.DismissOutcome.unsupported, unsupported_service.dismiss(1));
}

test "api-w19 notification shutdown completes pending notifications and drops late callbacks" {
    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    const outcome = service.submit(.{
        .summary = "In Flight",
        .body = "Pending operation",
    }, weak_owner, handler);
    try std.testing.expect(outcome == .accepted);
    const id = outcome.accepted;

    // Shutdown service
    service.shutdown();
    try std.testing.expect(mock.disconnected);

    // Active notifications are closed with closed_by_call
    try std.testing.expectEqual(@as(usize, 1), owner.closed_calls);
    try std.testing.expectEqual(CloseReason.closed_by_call, owner.last_reason.?);

    // New submissions fail with disconnected
    const new_sub = service.submit(.{ .summary = "After shutdown" }, weak_owner, handler);
    try std.testing.expect(new_sub == .provider_failed);
    try std.testing.expectEqual(notifications.ProviderError.disconnected, new_sub.provider_failed);

    // Late arriving response after shutdown is dropped
    service.handleResponse(id, .{ .action = .{ .key = "late_action" } });
    try std.testing.expectEqual(@as(usize, 0), owner.action_calls);
}

test "api-w19 dbus loopback mock exercises wire Notify and CloseNotification methods" {
    // Zero OS daemon dependency: use socketpair in memory
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    const client_fd = fds[0];
    const server_fd = fds[1];
    defer _ = std.os.linux.close(server_fd);

    // `NotificationsService` takes ownership of the provider handle and
    // deinits it from `deinit`, so the connection is moved into the provider
    // here and no second owner ever runs `provider.deinit()`. A second deinit
    // would read a poisoned `DbusNotificationProvider` and free a wild
    // pointer out of its `conn`.
    var provider = DbusNotificationProvider.initWithConnection(
        std.testing.allocator,
        dbus.Connection.initCustom(std.testing.allocator, client_fd),
    );

    var service = NotificationsService.init(std.testing.allocator, provider.provider());
    defer service.deinit();

    // Spawn mock server thread to reply to Notify call
    const ServerThread = struct {
        fn run(fd: i32) !void {
            var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
            defer {
                s_conn.detachFd();
                s_conn.deinit();
            }

            // Read method call from client
            const req_bytes = try s_conn.readMessageBytes();
            defer std.testing.allocator.free(req_bytes);

            const req = try dbus.MessageParser.parse(req_bytes);
            try std.testing.expectEqual(dbus.MessageType.method_call, req.msg_type);
            try std.testing.expectEqualStrings("Notify", req.member.?);

            // Send method return with id 77
            var ret_b = dbus.MessageBuilder.init(std.testing.allocator, .method_return, 10);
            defer ret_b.deinit();
            ret_b.reply_serial = req.serial;
            ret_b.signature = "u";
            try ret_b.writeU32(77);

            const ret_wire = try ret_b.build();
            defer std.testing.allocator.free(ret_wire);

            try s_conn.sendRaw(ret_wire);
        }
    };

    const thread = try std.Thread.spawn(.{}, ServerThread.run, .{server_fd});

    const outcome = service.submit(.{
        .summary = "Wire Test",
        .body = "Testing wire protocol",
    }, .{}, null);

    thread.join();

    try std.testing.expect(outcome == .accepted);
    try std.testing.expectEqual(@as(NotificationId, 77), outcome.accepted);
}

test "api-w19 notification dismiss refused by the provider keeps the notification routed" {
    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    const outcome = service.submit(.{ .summary = "Still on screen" }, weak_owner, handler);
    try std.testing.expect(outcome == .accepted);
    const id = outcome.accepted;

    // The provider refuses the close, so the daemon is still showing it.
    mock.dismiss_outcome = .refused;
    try std.testing.expectEqual(notifications.DismissOutcome.refused, service.dismiss(id));
    try std.testing.expectEqual(@as(usize, 1), mock.dismissed.items.len);

    // Dropping the routing of a notification that is still displayed would
    // silently discard the action the user can still take.
    service.handleResponse(id, .{ .action = .{ .key = "open" } });
    try std.testing.expectEqual(@as(usize, 1), owner.action_calls);
    try std.testing.expectEqualStrings("open", owner.last_action.?);
}

test "api-w19 provider disconnect completes every pending owner once without resurrecting it" {
    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    var live: TestOwner = .{};
    var dead: TestOwner = .{ .alive = false };
    const live_weak: WeakOwner = .{ .context = &live, .is_alive_fn = TestOwner.isAlive };
    const live_handler: ActionHandler = .{ .context = &live, .callback = TestOwner.onResponse };
    const dead_weak: WeakOwner = .{ .context = &dead, .is_alive_fn = TestOwner.isAlive };
    const dead_handler: ActionHandler = .{ .context = &dead, .callback = TestOwner.onResponse };

    const live_outcome = service.submit(.{ .summary = "Live owner" }, live_weak, live_handler);
    try std.testing.expect(live_outcome == .accepted);
    const live_id = live_outcome.accepted;
    const dead_outcome = service.submit(.{ .summary = "Dead owner" }, dead_weak, dead_handler);
    try std.testing.expect(dead_outcome == .accepted);
    const dead_id = dead_outcome.accepted;

    // The provider went away with both notifications unanswered. Nothing was
    // displayed or dismissed, so no owner may hear a close.
    try std.testing.expectEqual(@as(usize, 0), live.closed_calls);

    service.handleProviderDisconnect();

    // The live owner is completed exactly once with a typed result that is
    // not a user-visible close.
    try std.testing.expectEqual(@as(usize, 1), live.lost_calls);
    try std.testing.expectEqual(@as(usize, 0), live.closed_calls);
    try std.testing.expectEqual(@as(usize, 0), live.action_calls);

    // The dead owner is never completed and never resurrected.
    try std.testing.expectEqual(@as(usize, 0), dead.lost_calls);
    try std.testing.expectEqual(@as(usize, 0), dead.closed_calls);

    // Callbacks already in flight are dropped, and no pending result is
    // delivered twice.
    service.handleResponse(live_id, .{ .action = .{ .key = "late" } });
    service.handleResponse(dead_id, .{ .action = .{ .key = "late" } });
    service.handleProviderDisconnect();
    try std.testing.expectEqual(@as(usize, 1), live.lost_calls);
    try std.testing.expectEqual(@as(usize, 0), live.action_calls);

    // Work is refused with the typed disconnect result, and it never reaches
    // the provider.
    const after = service.submit(.{ .summary = "After the provider died" }, live_weak, live_handler);
    try std.testing.expect(after == .provider_failed);
    try std.testing.expectEqual(notifications.ProviderError.disconnected, after.provider_failed);
    try std.testing.expectEqual(@as(usize, 2), mock.submitted.items.len);
}

test "api-w19 dbus bus loss completes the pending owner once and leaves the provider dead" {
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    const client_fd = fds[0];

    var provider = DbusNotificationProvider.initWithConnection(
        std.testing.allocator,
        dbus.Connection.initCustom(std.testing.allocator, client_fd),
    );
    var service = NotificationsService.init(std.testing.allocator, provider.provider());
    defer service.deinit();

    // The mock server answers one Notify and then drops the bus, which is
    // what a daemon restart looks like to the provider.
    const ServerThread = struct {
        fn run(fd: i32) !void {
            var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
            // This thread owns `fd` and closes it on the way out.
            defer s_conn.deinit();

            const req_bytes = try s_conn.readMessageBytes();
            defer std.testing.allocator.free(req_bytes);
            const req = try dbus.MessageParser.parse(req_bytes);
            try std.testing.expectEqualStrings("Notify", req.member.?);

            var ret_b = dbus.MessageBuilder.init(std.testing.allocator, .method_return, 10);
            defer ret_b.deinit();
            ret_b.reply_serial = req.serial;
            ret_b.signature = "u";
            try ret_b.writeU32(55);

            const ret_wire = try ret_b.build();
            defer std.testing.allocator.free(ret_wire);
            try s_conn.sendRaw(ret_wire);
        }
    };

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    const thread = try std.Thread.spawn(.{}, ServerThread.run, .{fds[1]});
    const outcome = service.submit(.{ .summary = "Unanswered" }, weak_owner, handler);
    thread.join();

    try std.testing.expect(outcome == .accepted);
    const id = outcome.accepted;
    try std.testing.expectEqual(@as(NotificationId, 55), id);
    try std.testing.expectEqual(@as(usize, 0), owner.lost_calls);

    // The bus is gone. The pending owner is completed with the typed provider
    // result instead of waiting for an answer that cannot arrive.
    try std.testing.expectEqual(@as(usize, 0), try provider.poll(&service, 0));
    try std.testing.expectEqual(@as(usize, 1), owner.lost_calls);
    try std.testing.expectEqual(@as(usize, 0), owner.closed_calls);

    // The provider stays dead: a further poll neither revives the connection
    // nor completes a second time.
    try std.testing.expectEqual(@as(usize, 0), try provider.poll(&service, 0));
    try std.testing.expectEqual(@as(usize, 1), owner.lost_calls);

    // A signal that raced the disconnect cannot resurrect the dead owner.
    service.handleResponse(id, .{ .action = .{ .key = "late" } });
    try std.testing.expectEqual(@as(usize, 0), owner.action_calls);
    try std.testing.expectEqual(@as(usize, 1), owner.lost_calls);
}

test "api-w19 notification dismiss after provider disconnect is a typed failure and not a refusal" {
    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    const outcome = service.submit(.{ .summary = "Waiting for an answer" }, weak_owner, handler);
    try std.testing.expect(outcome == .accepted);
    const id = outcome.accepted;

    service.handleProviderDisconnect();

    // Nothing refused the close: there is no daemon left to refuse it. A
    // caller that reads this as `refused` waits on a notification whose
    // provider is gone, which is how a cancel turns into a hang.
    const after = service.dismiss(id);
    try std.testing.expect(after == .provider_failed);
    try std.testing.expectEqual(notifications.ProviderError.disconnected, after.provider_failed);

    // The dead provider is never asked to close anything.
    try std.testing.expectEqual(@as(usize, 0), mock.dismissed.items.len);
}

test "api-w19 notification capabilities support nothing without a provider and after shutdown" {
    var bare = NotificationsService.init(std.testing.allocator, null);
    defer bare.deinit();

    // No provider supports nothing. Falling back to the struct defaults would
    // claim a body and action buttons that no daemon will ever deliver.
    try std.testing.expectEqual(notifications.Capabilities.none, bare.getCapabilities());

    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    // A terminated service is in the same position: the daemon is unreachable,
    // so a caller must not keep offering controls that can never fire.
    service.shutdown();
    try std.testing.expectEqual(notifications.Capabilities.none, service.getCapabilities());
}

test "api-w19 notification service shutdown leaves the provider dead instead of redialing the bus" {
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    defer _ = std.os.linux.close(fds[1]);

    var provider = DbusNotificationProvider.initWithConnection(
        std.testing.allocator,
        dbus.Connection.initCustom(std.testing.allocator, fds[0]),
    );
    var service = NotificationsService.init(std.testing.allocator, provider.provider());
    defer service.deinit();

    service.shutdown();

    // Shutdown released the bus, so the provider is latched dead. Only an
    // explicit `connect` may reach a daemon again; a late host call that still
    // holds the handle must not open a fresh connection and raise a
    // notification after the service stopped.
    try std.testing.expect(provider.is_gone);
    const direct = provider.provider().submit(.{ .summary = "After shutdown" });
    try std.testing.expect(direct == .provider_failed);
    try std.testing.expectEqual(notifications.ProviderError.disconnected, direct.provider_failed);

    // The same hold applies through the service.
    const after = service.dismiss(1);
    try std.testing.expect(after == .provider_failed);
    try std.testing.expectEqual(notifications.ProviderError.disconnected, after.provider_failed);
}

test "api-w19 a dismissal the provider could not complete is a named failure and not a refusal" {
    var mock = MockNotificationProvider.init(std.testing.allocator);
    var service = NotificationsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    const outcome = service.submit(.{ .summary = "Cancel this" }, weak_owner, handler);
    try std.testing.expect(outcome == .accepted);
    const id = outcome.accepted;

    // The transport failed while the close was in flight. There is no answer
    // here to read as a refusal, so a caller told "refused" waits on a
    // notification a live provider never said it had closed.
    mock.dismiss_outcome = .{ .provider_failed = .io_error };
    const failed = service.dismiss(id);
    try std.testing.expect(failed == .provider_failed);
    try std.testing.expectEqual(notifications.ProviderError.io_error, failed.provider_failed);

    // Nothing was closed, so the notification is still on screen and the
    // action the user can take is still that owner's.
    service.handleResponse(id, .{ .action = .{ .key = "open" } });
    try std.testing.expectEqual(@as(usize, 1), owner.action_calls);

    // A provider whose bus is gone is named rather than refused as well, and
    // its notifications stay routed: a transport that really went away
    // completes the wait through `handleProviderDisconnect`, not by closing.
    mock.dismiss_outcome = .{ .provider_failed = .disconnected };
    const gone = service.dismiss(id);
    try std.testing.expectEqual(
        notifications.DismissOutcome{ .provider_failed = .disconnected },
        gone,
    );
    try std.testing.expectEqual(@as(usize, 2), mock.dismissed.items.len);
    service.handleResponse(id, .{ .action = .{ .key = "open" } });
    try std.testing.expectEqual(@as(usize, 2), owner.action_calls);
}

test "api-w19 dbus close on a bus that went away is a named transport failure" {
    // The loopback peer reads the call and then drops the socket, which is what
    // a bus that went away mid-close looks like from here. Nothing refused
    // anything, so the close is not a refusal from a daemon that is still
    // showing the notification.
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;

    var provider = DbusNotificationProvider.initWithConnection(
        std.testing.allocator,
        dbus.Connection.initCustom(std.testing.allocator, fds[0]),
    );
    var service = NotificationsService.init(std.testing.allocator, provider.provider());
    defer service.deinit();

    const Peer = struct {
        fn run(fd: i32) !void {
            var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
            // This thread owns `fd` and closes it on the way out, which is the
            // loss the client is meant to observe.
            defer s_conn.deinit();

            // Reading the call is what keeps the socket open long enough for
            // the write to land. The reply is never sent.
            const req_bytes = try s_conn.readMessageBytes();
            defer std.testing.allocator.free(req_bytes);
            const req = try dbus.MessageParser.parse(req_bytes);
            try std.testing.expectEqualStrings("CloseNotification", req.member.?);
        }
    };

    const thread = try std.Thread.spawn(.{}, Peer.run, .{fds[1]});
    const failed = service.dismiss(7);
    thread.join();

    try std.testing.expect(failed == .provider_failed);
    try std.testing.expectEqual(notifications.ProviderError.disconnected, failed.provider_failed);
}

test "api-w19 dbus close answered with something that is not a frame is a protocol failure" {
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;

    var provider = DbusNotificationProvider.initWithConnection(
        std.testing.allocator,
        dbus.Connection.initCustom(std.testing.allocator, fds[0]),
    );
    var service = NotificationsService.init(std.testing.allocator, provider.provider());
    defer service.deinit();

    const Peer = struct {
        fn run(fd: i32) !void {
            var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
            defer s_conn.deinit();

            const req_bytes = try s_conn.readMessageBytes();
            defer std.testing.allocator.free(req_bytes);
            const req = try dbus.MessageParser.parse(req_bytes);
            try std.testing.expectEqualStrings("CloseNotification", req.member.?);

            // Bytes that are not a D-Bus frame at all. A reply that cannot be
            // read is not a close the daemon accepted and not a close it
            // refused, so it is named as the protocol failure it is.
            const garbage: [64]u8 = @splat(0xaa);
            try s_conn.sendRaw(&garbage);
        }
    };

    const thread = try std.Thread.spawn(.{}, Peer.run, .{fds[1]});
    const failed = service.dismiss(7);
    thread.join();

    try std.testing.expect(failed == .provider_failed);
    try std.testing.expectEqual(notifications.ProviderError.protocol_error, failed.provider_failed);
}

test "api-w19 dbus close the daemon refused keeps the notification routed" {
    // The loopback peer stands in for the daemon: it accepts one Notify, then
    // refuses both closes, first with its own error and then with an
    // authorization refusal. What is under test is how the adapter reads the
    // daemon's answer, not any acceptance by a real notification daemon.
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;

    var provider = DbusNotificationProvider.initWithConnection(
        std.testing.allocator,
        dbus.Connection.initCustom(std.testing.allocator, fds[0]),
    );
    var service = NotificationsService.init(std.testing.allocator, provider.provider());
    defer service.deinit();

    const Peer = struct {
        fn run(fd: i32) !void {
            var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
            defer s_conn.deinit();

            const notify_bytes = try s_conn.readMessageBytes();
            defer std.testing.allocator.free(notify_bytes);
            const notify = try dbus.MessageParser.parse(notify_bytes);
            try std.testing.expectEqualStrings("Notify", notify.member.?);
            try sendReturn(&s_conn, notify.serial, 77);

            const refusals = [_][]const u8{
                "org.freedesktop.Notifications.Error.NotFound",
                "org.freedesktop.DBus.Error.AccessDenied",
            };
            for (refusals) |error_name| {
                const close_bytes = try s_conn.readMessageBytes();
                defer std.testing.allocator.free(close_bytes);
                const close = try dbus.MessageParser.parse(close_bytes);
                try std.testing.expectEqualStrings("CloseNotification", close.member.?);
                try sendError(&s_conn, close.serial, error_name);
            }
        }

        fn sendReturn(s_conn: *dbus.Connection, reply_serial: u32, id: NotificationId) !void {
            var builder = dbus.MessageBuilder.init(std.testing.allocator, .method_return, 10);
            defer builder.deinit();
            builder.reply_serial = reply_serial;
            builder.signature = "u";
            try builder.writeU32(id);
            const wire = try builder.build();
            defer std.testing.allocator.free(wire);
            try s_conn.sendRaw(wire);
        }

        fn sendError(s_conn: *dbus.Connection, reply_serial: u32, error_name: []const u8) !void {
            var builder = dbus.MessageBuilder.init(std.testing.allocator, .error_reply, 10);
            defer builder.deinit();
            builder.reply_serial = reply_serial;
            builder.error_name = error_name;
            const wire = try builder.build();
            defer std.testing.allocator.free(wire);
            try s_conn.sendRaw(wire);
        }
    };

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    const thread = try std.Thread.spawn(.{}, Peer.run, .{fds[1]});

    const accepted = service.submit(.{ .summary = "Still on screen" }, weak_owner, handler);
    try std.testing.expect(accepted == .accepted);
    const id = accepted.accepted;
    try std.testing.expectEqual(@as(NotificationId, 77), id);

    // A live daemon that refused the close is a refusal and nothing more. The
    // notification is still on screen, so it stays tracked.
    const refused = service.dismiss(id);
    try std.testing.expectEqual(notifications.DismissOutcome.refused, refused);

    // An authorization refusal is named rather than folded into the refusal
    // above: the close did not happen either way, and who stopped it is the
    // difference a host has to be able to report.
    const denied = service.dismiss(id);
    try std.testing.expect(denied == .provider_failed);
    try std.testing.expectEqual(notifications.ProviderError.permission_denied, denied.provider_failed);

    thread.join();

    // Neither close was a close, so the action on screen still belongs to the
    // owner that submitted it.
    service.handleResponse(id, .{ .action = .{ .key = "open" } });
    try std.testing.expectEqual(@as(usize, 1), owner.action_calls);
    try std.testing.expectEqualStrings("open", owner.last_action.?);
}

test "api-w19 dbus poll reports an allocation failure, retires the provider and completes the owner once" {
    // The daemon sends the action the user took and then drops the bus. The
    // frame arrives before the loss, but no list can hold it, so its owner
    // has to hear that the provider is gone instead of waiting for an action
    // nobody routed, and the host has to hear that the poll did not drain.
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;

    var builder = dbus.MessageBuilder.init(std.testing.allocator, .signal, 1);
    defer builder.deinit();
    builder.path = "/org/freedesktop/Notifications";
    builder.interface = "org.freedesktop.Notifications";
    builder.member = "ActionInvoked";
    builder.signature = "us";
    try builder.writeU32(77);
    try builder.writeString("open_log");
    const wire = try builder.build();
    defer std.testing.allocator.free(wire);

    // The transport reads into a buffer of at least 4096 bytes and copies
    // each frame out of it, so a request of exactly the frame's own length is
    // that copy and nothing else. Once armed, the gate lets that copy
    // through and refuses every allocation after it: the window where the
    // drain owns a frame it has not handed to the list yet.
    const FrameCopyGate = struct {
        back: std.mem.Allocator,
        frame_bytes: usize,
        // Set once the round trips of a submit are over, so that only the
        // allocations a drain makes are judged by the rule above.
        armed: bool = false,
        copies: usize = 0,
        refusals: usize = 0,

        // A local declaration cannot name itself, so the methods say `Self`.
        const Self = @This();

        const vtable: std.mem.Allocator.VTable = .{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        };

        fn allocator(self: *Self) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.armed) {
                if (len == self.frame_bytes) {
                    self.copies += 1;
                    return self.back.rawAlloc(len, alignment, ret_addr);
                }
                if (self.copies > 0) {
                    self.refusals += 1;
                    return null;
                }
            }
            return self.back.rawAlloc(len, alignment, ret_addr);
        }

        fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.armed and self.copies > 0) return false;
            return self.back.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remapFn(
            ctx: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.armed and self.copies > 0) return null;
            return self.back.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.back.rawFree(memory, alignment, ret_addr);
        }
    };
    var gate: FrameCopyGate = .{ .back = std.testing.allocator, .frame_bytes = wire.len };

    var provider = DbusNotificationProvider.initWithConnection(
        gate.allocator(),
        dbus.Connection.initCustom(gate.allocator(), fds[0]),
    );
    var service = NotificationsService.init(std.testing.allocator, provider.provider());
    defer service.deinit();

    const Peer = struct {
        fn run(fd: i32, signal: []const u8) !void {
            var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
            // This thread owns `fd` and closes it on the way out, which is the
            // bus loss the client is meant to observe.
            defer s_conn.deinit();

            const req_bytes = try s_conn.readMessageBytes();
            defer std.testing.allocator.free(req_bytes);
            const req = try dbus.MessageParser.parse(req_bytes);
            try std.testing.expectEqualStrings("Notify", req.member.?);

            var ret_b = dbus.MessageBuilder.init(std.testing.allocator, .method_return, 10);
            defer ret_b.deinit();
            ret_b.reply_serial = req.serial;
            ret_b.signature = "u";
            try ret_b.writeU32(77);
            const ret_wire = try ret_b.build();
            defer std.testing.allocator.free(ret_wire);
            try s_conn.sendRaw(ret_wire);

            // The action reaches the bus before the bus is gone.
            try s_conn.sendRaw(signal);
        }
    };

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    const thread = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], wire });
    const outcome = service.submit(.{ .summary = "Unanswered" }, weak_owner, handler);
    thread.join();

    try std.testing.expect(outcome == .accepted);
    try std.testing.expectEqual(@as(NotificationId, 77), outcome.accepted);
    try std.testing.expectEqual(@as(usize, 0), owner.action_calls);

    gate.armed = true;
    try std.testing.expectError(error.OutOfMemory, provider.poll(&service, 0));

    // The frame was copied before the list refused it, so the failure is the
    // ownership boundary and not a drain that never worked.
    try std.testing.expectEqual(@as(usize, 1), gate.copies);
    try std.testing.expectEqual(@as(usize, 1), gate.refusals);

    // A frame no list could hold is not an action the owner gets. Its
    // notification completes with the typed provider result instead, exactly
    // once, and the provider is dead even though the allocation failed.
    try std.testing.expectEqual(@as(usize, 0), owner.action_calls);
    try std.testing.expectEqual(@as(usize, 1), owner.lost_calls);
    try std.testing.expectEqual(@as(usize, 0), owner.closed_calls);
    try std.testing.expect(provider.is_gone);

    try std.testing.expectEqual(@as(usize, 0), try provider.poll(&service, 0));
    try std.testing.expectEqual(@as(usize, 1), owner.lost_calls);
}

test "api-w19 dbus poll routes the frames it received before reporting an allocation failure" {
    // Two notifications are on screen. The daemon answers both, sends the
    // action for the first and then goes away. The frame of the second cannot
    // be copied, and that failure must not cost the action the daemon had
    // already delivered.
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;

    var action_b = dbus.MessageBuilder.init(std.testing.allocator, .signal, 1);
    defer action_b.deinit();
    action_b.path = "/org/freedesktop/Notifications";
    action_b.interface = "org.freedesktop.Notifications";
    action_b.member = "ActionInvoked";
    action_b.signature = "us";
    try action_b.writeU32(77);
    try action_b.writeString("open_log");
    const action_wire = try action_b.build();
    defer std.testing.allocator.free(action_wire);

    var closed_b = dbus.MessageBuilder.init(std.testing.allocator, .signal, 2);
    defer closed_b.deinit();
    closed_b.path = "/org/freedesktop/Notifications";
    closed_b.interface = "org.freedesktop.Notifications";
    closed_b.member = "NotificationClosed";
    closed_b.signature = "uu";
    try closed_b.writeU32(78);
    try closed_b.writeU32(2);
    const closed_wire = try closed_b.build();
    defer std.testing.allocator.free(closed_wire);

    // The gate refuses the copy of exactly one frame, so the two frames this
    // test routes have to differ in length for the rule to name one of them.
    try std.testing.expect(closed_wire.len != action_wire.len);

    // The transport copies a frame out of its staging buffer with
    // `dupe(u8, frame)`, which asks for exactly that frame's own length at
    // one-byte alignment. The list holding the copies asks for storage at the
    // slice's own alignment instead, so a gate keyed on the length AND the
    // alignment names the copy and cannot be tripped by that list growing
    // into a byte count that happens to match a frame. The whole rule is
    // that: the close frame cannot be copied, everything else keeps working.
    const FrameCopyRefuser = struct {
        back: std.mem.Allocator,
        refused_bytes: usize,
        // Set once the round trips of the submits are over, so that only the
        // allocations a drain makes are judged by the rule above.
        armed: bool = false,
        refusals: usize = 0,

        // A local declaration cannot name itself, so the methods say `Self`.
        const Self = @This();

        const vtable: std.mem.Allocator.VTable = .{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        };

        fn allocator(self: *Self) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.armed and alignment == .@"1" and len == self.refused_bytes) {
                self.refusals += 1;
                return null;
            }
            return self.back.rawAlloc(len, alignment, ret_addr);
        }

        fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.back.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remapFn(
            ctx: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.back.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.back.rawFree(memory, alignment, ret_addr);
        }
    };
    var gate: FrameCopyRefuser = .{ .back = std.testing.allocator, .refused_bytes = closed_wire.len };

    var provider = DbusNotificationProvider.initWithConnection(
        gate.allocator(),
        dbus.Connection.initCustom(gate.allocator(), fds[0]),
    );
    var service = NotificationsService.init(std.testing.allocator, provider.provider());
    defer service.deinit();

    const Peer = struct {
        fn run(fd: i32, action: []const u8, closed: []const u8) !void {
            var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
            // This thread owns `fd` and closes it on the way out, which is the
            // bus loss the client is meant to observe.
            defer s_conn.deinit();

            const first_bytes = try s_conn.readMessageBytes();
            defer std.testing.allocator.free(first_bytes);
            const first = try dbus.MessageParser.parse(first_bytes);
            try std.testing.expectEqualStrings("Notify", first.member.?);

            var first_b = dbus.MessageBuilder.init(std.testing.allocator, .method_return, 10);
            defer first_b.deinit();
            first_b.reply_serial = first.serial;
            first_b.signature = "u";
            try first_b.writeU32(77);
            const first_reply = try first_b.build();
            defer std.testing.allocator.free(first_reply);
            try s_conn.sendRaw(first_reply);

            const second_bytes = try s_conn.readMessageBytes();
            defer std.testing.allocator.free(second_bytes);
            const second = try dbus.MessageParser.parse(second_bytes);
            try std.testing.expectEqualStrings("Notify", second.member.?);

            var second_b = dbus.MessageBuilder.init(std.testing.allocator, .method_return, 11);
            defer second_b.deinit();
            second_b.reply_serial = second.serial;
            second_b.signature = "u";
            try second_b.writeU32(78);
            const second_reply = try second_b.build();
            defer std.testing.allocator.free(second_reply);

            // The second answer and both signals leave the daemon in one
            // burst, so the frames are staged before the bus goes away. That is
            // the state a poll has to drain, and it keeps the test off the
            // question of whether one read or two delivered them.
            var burst: [1024]u8 = undefined;
            var len: usize = 0;
            for ([_][]const u8{ second_reply, action, closed }) |part| {
                @memcpy(burst[len..][0..part.len], part);
                len += part.len;
            }
            try writeAll(fd, burst[0..len]);
        }

        fn writeAll(fd: i32, bytes: []const u8) !void {
            var sent: usize = 0;
            while (sent < bytes.len) {
                const n = std.os.linux.write(fd, bytes[sent..].ptr, bytes.len - sent);
                if (std.os.linux.errno(n) != .SUCCESS) return error.SendFailed;
                if (n == 0) return error.SendFailed;
                sent += n;
            }
        }
    };

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    const thread = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], action_wire, closed_wire });
    const first = service.submit(.{ .summary = "Acted on" }, weak_owner, handler);
    const second = service.submit(.{ .summary = "Still open" }, weak_owner, handler);
    thread.join();

    try std.testing.expect(first == .accepted);
    try std.testing.expect(second == .accepted);
    try std.testing.expectEqual(@as(NotificationId, 77), first.accepted);
    try std.testing.expectEqual(@as(NotificationId, 78), second.accepted);

    gate.armed = true;
    try std.testing.expectError(error.OutOfMemory, provider.poll(&service, 0));
    try std.testing.expectEqual(@as(usize, 1), gate.refusals);

    // The action the user took is still routed: the copy that failed was the
    // second frame, and the frames before it are still answered.
    try std.testing.expectEqual(@as(usize, 1), owner.action_calls);

    // Neither notification was closed. An action is not a close, and the
    // close that could not be copied never reached anybody, so both wait out
    // the dead provider: completed once each, and reported as gone rather
    // than as a close.
    try std.testing.expectEqual(@as(usize, 2), owner.lost_calls);
    try std.testing.expectEqual(@as(usize, 0), owner.closed_calls);
    try std.testing.expect(provider.is_gone);

    try std.testing.expectEqual(@as(usize, 0), try provider.poll(&service, 0));
    try std.testing.expectEqual(@as(usize, 2), owner.lost_calls);
}

test "api-w19 dbus poll reports an allocation failure without retiring a live provider" {
    // The daemon answers, delivers the action the user took and then the
    // close that followed it, and it stays on the bus. The frame that cannot
    // be copied is the second one, so the first still has to be routed: an
    // allocation that failed on a live transport costs the host the frame it
    // could not take, not the answers the daemon has already sent.
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    const daemon_fd = fds[1];
    defer _ = std.os.linux.close(daemon_fd);

    // A second channel says the daemon has both frames on the wire, so the
    // drain under test never races it. The bus itself stays open until the
    // client hangs up, which is what keeps the transport live.
    var control: [2]i32 = undefined;
    const control_rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &control);
    if (std.os.linux.errno(control_rc) != .SUCCESS) return error.ControlSocketPairFailed;
    const control_read = control[0];
    const control_write = control[1];
    defer _ = std.os.linux.close(control_read);

    var action_b = dbus.MessageBuilder.init(std.testing.allocator, .signal, 1);
    defer action_b.deinit();
    action_b.path = "/org/freedesktop/Notifications";
    action_b.interface = "org.freedesktop.Notifications";
    action_b.member = "ActionInvoked";
    action_b.signature = "us";
    try action_b.writeU32(77);
    try action_b.writeString("open_log");
    const action_wire = try action_b.build();
    defer std.testing.allocator.free(action_wire);

    var closed_b = dbus.MessageBuilder.init(std.testing.allocator, .signal, 2);
    defer closed_b.deinit();
    closed_b.path = "/org/freedesktop/Notifications";
    closed_b.interface = "org.freedesktop.Notifications";
    closed_b.member = "NotificationClosed";
    closed_b.signature = "uu";
    try closed_b.writeU32(77);
    try closed_b.writeU32(2);
    const closed_wire = try closed_b.build();
    defer std.testing.allocator.free(closed_wire);

    // The gate refuses the copy of exactly one frame, so the two frames this
    // test routes have to differ in length for the rule to name one of them.
    try std.testing.expect(closed_wire.len != action_wire.len);

    // The transport copies a frame out of its staging buffer with
    // `dupe(u8, frame)`, which asks for exactly that frame's own length at
    // one-byte alignment. The list holding the copies asks for storage at the
    // slice's own alignment instead, so a gate keyed on the length AND the
    // alignment names the copy and cannot be tripped by that list growing
    // into a byte count that happens to match a frame. The whole rule is
    // that: the close frame cannot be copied, everything else keeps working.
    const FrameCopyRefuser = struct {
        back: std.mem.Allocator,
        refused_bytes: usize,
        // Set once the round trip of the submit is over, so that only the
        // allocations a drain makes are judged by the rule above.
        armed: bool = false,
        refusals: usize = 0,

        // A local declaration cannot name itself, so the methods say `Self`.
        const Self = @This();

        const vtable: std.mem.Allocator.VTable = .{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        };

        fn allocator(self: *Self) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.armed and alignment == .@"1" and len == self.refused_bytes) {
                self.refusals += 1;
                return null;
            }
            return self.back.rawAlloc(len, alignment, ret_addr);
        }

        fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.back.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remapFn(
            ctx: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.back.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.back.rawFree(memory, alignment, ret_addr);
        }
    };
    var gate: FrameCopyRefuser = .{ .back = std.testing.allocator, .refused_bytes = closed_wire.len };

    const Peer = struct {
        fn run(fd: i32, control_fd: i32, action: []const u8, closed: []const u8) !void {
            var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
            // This thread keeps the bus open for as long as the client polls,
            // so it hands the fd over on the way out instead of closing it.
            defer {
                s_conn.detachFd();
                s_conn.deinit();
            }

            const req_bytes = try s_conn.readMessageBytes();
            defer std.testing.allocator.free(req_bytes);
            const req = try dbus.MessageParser.parse(req_bytes);
            try std.testing.expectEqualStrings("Notify", req.member.?);

            var ret_b = dbus.MessageBuilder.init(std.testing.allocator, .method_return, 10);
            defer ret_b.deinit();
            ret_b.reply_serial = req.serial;
            ret_b.signature = "u";
            try ret_b.writeU32(77);
            const ret_wire = try ret_b.build();
            defer std.testing.allocator.free(ret_wire);
            try s_conn.sendRaw(ret_wire);

            // Both signals follow the answer, so the transport that reads
            // them stages them beside the reply it is still holding.
            try s_conn.sendRaw(action);
            try s_conn.sendRaw(closed);

            // Say the frames are on the wire, then hold the bus open. The
            // client hangs up when the provider is deinited, and a daemon
            // that closed here would be the loss these tests cover instead.
            const marker = [_]u8{1};
            const written = std.os.linux.write(control_fd, marker[0..].ptr, marker.len);
            _ = std.os.linux.close(control_fd);
            if (std.os.linux.errno(written) != .SUCCESS) return error.MarkerWriteFailed;

            var sink: [1]u8 = undefined;
            _ = std.os.linux.read(fd, &sink, sink.len);
        }
    };

    const thread = try std.Thread.spawn(.{}, Peer.run, .{ daemon_fd, control_write, action_wire, closed_wire });
    // The provider is released before the peer is joined: that hangup is what
    // releases the peer.
    defer thread.join();

    var provider = DbusNotificationProvider.initWithConnection(
        gate.allocator(),
        dbus.Connection.initCustom(gate.allocator(), fds[0]),
    );
    var service = NotificationsService.init(std.testing.allocator, provider.provider());
    defer service.deinit();

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    const outcome = service.submit(.{ .summary = "Acted on" }, weak_owner, handler);
    try std.testing.expect(outcome == .accepted);
    try std.testing.expectEqual(@as(NotificationId, 77), outcome.accepted);
    try std.testing.expectEqual(@as(usize, 0), owner.action_calls);

    var marker: [1]u8 = undefined;
    const marked = std.os.linux.read(control_read, &marker, marker.len);
    if (std.os.linux.errno(marked) != .SUCCESS) return error.MarkerReadFailed;
    if (marked != marker.len) return error.MarkerMissing;

    gate.armed = true;
    try std.testing.expectError(error.OutOfMemory, provider.poll(&service, 0));
    try std.testing.expectEqual(@as(usize, 1), gate.refusals);

    // The action the user took is routed before the failure is reported, and
    // a live transport is not a lost provider: nobody is told the daemon is
    // gone, and the provider is still there for the next poll.
    try std.testing.expectEqual(@as(usize, 1), owner.action_calls);
    try std.testing.expectEqual(@as(usize, 0), owner.lost_calls);
    try std.testing.expect(!provider.is_gone);

    // The frame the drain could not copy is still staged, so the next poll
    // delivers the close rather than losing it to the failure.
    gate.armed = false;
    try std.testing.expectEqual(@as(usize, 1), try provider.poll(&service, 0));
    try std.testing.expectEqual(@as(usize, 1), owner.closed_calls);
    try std.testing.expectEqual(CloseReason.dismissed_by_user, owner.last_reason.?);
    try std.testing.expectEqual(@as(usize, 0), owner.lost_calls);
    try std.testing.expect(!provider.is_gone);
}

test "api-w19 dbus notification call keeps a signal for the poll that follows" {
    // The daemon sends the action first and answers the call second. The
    // signal is not the answer to anything this host sent, so the call must
    // not take it as one: it stays staged and the poll that follows is what
    // delivers it to the owner.
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    const daemon_fd = fds[1];
    defer _ = std.os.linux.close(daemon_fd);

    var action_b = dbus.MessageBuilder.init(std.testing.allocator, .signal, 1);
    defer action_b.deinit();
    action_b.path = "/org/freedesktop/Notifications";
    action_b.interface = "org.freedesktop.Notifications";
    action_b.member = "ActionInvoked";
    action_b.signature = "us";
    try action_b.writeU32(77);
    try action_b.writeString("open_log");
    const action_wire = try action_b.build();
    defer std.testing.allocator.free(action_wire);

    const Peer = struct {
        fn run(fd: i32, action: []const u8) !void {
            var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
            // The bus stays open under the test's own copy of `fd`, so this
            // peer is finished the moment it has sent what it had to say.
            defer {
                s_conn.detachFd();
                s_conn.deinit();
            }

            const req_bytes = try s_conn.readMessageBytes();
            defer std.testing.allocator.free(req_bytes);
            const req = try dbus.MessageParser.parse(req_bytes);
            try std.testing.expectEqualStrings("Notify", req.member.?);

            // The action leaves before the answer to the call.
            try s_conn.sendRaw(action);

            var ret_b = dbus.MessageBuilder.init(std.testing.allocator, .method_return, 10);
            defer ret_b.deinit();
            ret_b.reply_serial = req.serial;
            ret_b.signature = "u";
            try ret_b.writeU32(77);
            const ret_wire = try ret_b.build();
            defer std.testing.allocator.free(ret_wire);
            try s_conn.sendRaw(ret_wire);
        }
    };

    const thread = try std.Thread.spawn(.{}, Peer.run, .{ daemon_fd, action_wire });
    var peer_live = true;
    defer {
        if (peer_live) thread.join();
    }

    var provider = DbusNotificationProvider.initWithConnection(
        std.testing.allocator,
        dbus.Connection.initCustom(std.testing.allocator, fds[0]),
    );
    var service = NotificationsService.init(std.testing.allocator, provider.provider());
    defer service.deinit();

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    const outcome = service.submit(.{ .summary = "Acted on" }, weak_owner, handler);
    try std.testing.expect(outcome == .accepted);
    try std.testing.expectEqual(@as(NotificationId, 77), outcome.accepted);

    // The daemon has sent everything it had to say, and its socket is still
    // open because this thread holds the other end. Joining here is the
    // whole of its completion: a poll that never blocks reads only what is
    // already here, so asking it before the producer ran is asking early.
    thread.join();
    peer_live = false;

    // The call answered itself and left the signal alone, so nobody has heard
    // the action yet.
    try std.testing.expectEqual(@as(usize, 0), owner.action_calls);

    // The poll that follows is where the signal reaches its owner.
    try std.testing.expectEqual(@as(usize, 1), try provider.poll(&service, 0));
    try std.testing.expectEqual(@as(usize, 1), owner.action_calls);
    try std.testing.expectEqual(@as(usize, 0), owner.lost_calls);
}

test "api-w19 dbus provider releases frames through the allocator that made them" {
    // A host may hand the provider a connection built on an allocator of its
    // own: `initWithConnection` exists for hosts that share one connection
    // between services. Everything the connection hands out is charged to that
    // allocator, so everything has to come back through it, and this ledger is
    // what says whether it did.
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    const daemon_fd = fds[1];
    defer _ = std.os.linux.close(daemon_fd);

    const ConnectionLedger = struct {
        back: std.mem.Allocator,
        live_bytes: usize = 0,

        // A local declaration cannot name itself, so the methods say `Self`.
        const Self = @This();

        const vtable: std.mem.Allocator.VTable = .{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        };

        fn allocator(self: *Self) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const memory = self.back.rawAlloc(len, alignment, ret_addr) orelse return null;
            self.live_bytes += len;
            return memory;
        }

        fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (!self.back.rawResize(memory, alignment, new_len, ret_addr)) return false;
            self.live_bytes = self.live_bytes - memory.len + new_len;
            return true;
        }

        fn remapFn(
            ctx: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const moved = self.back.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
            self.live_bytes = self.live_bytes - memory.len + new_len;
            return moved;
        }

        fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            // Only what this ledger charged can be taken off it. A block
            // released through another allocator still reaches `back`, so the
            // heap stays intact and this count is what reports the mistake.
            if (self.live_bytes >= memory.len) self.live_bytes -= memory.len;
            self.back.rawFree(memory, alignment, ret_addr);
        }
    };
    // What the provider allocates for itself is not what this measures, so it
    // comes from scratch space. The connection's allocator is the one under
    // test, and the ledger over it is the only thing that reports a mistake:
    // neither scratch allocator can panic, so a frame released through the
    // wrong allocator shows up as a count here instead of a crash.
    var provider_scratch: [16 * 1024]u8 = undefined;
    var provider_fixed = std.heap.FixedBufferAllocator.init(&provider_scratch);
    var connection_scratch: [16 * 1024]u8 = undefined;
    var connection_fixed = std.heap.FixedBufferAllocator.init(&connection_scratch);

    var ledger: ConnectionLedger = .{ .back = connection_fixed.allocator() };

    var action_b = dbus.MessageBuilder.init(std.testing.allocator, .signal, 1);
    defer action_b.deinit();
    action_b.path = "/org/freedesktop/Notifications";
    action_b.interface = "org.freedesktop.Notifications";
    action_b.member = "ActionInvoked";
    action_b.signature = "us";
    try action_b.writeU32(77);
    try action_b.writeString("open_log");
    const action_wire = try action_b.build();
    defer std.testing.allocator.free(action_wire);

    const Peer = struct {
        fn run(fd: i32, action: []const u8) !void {
            var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
            // The bus stays open under the test's own copy of `fd`, so this
            // peer is finished the moment it has sent what it had to say.
            defer {
                s_conn.detachFd();
                s_conn.deinit();
            }

            const req_bytes = try s_conn.readMessageBytes();
            defer std.testing.allocator.free(req_bytes);
            const req = try dbus.MessageParser.parse(req_bytes);
            try std.testing.expectEqualStrings("Notify", req.member.?);

            var ret_b = dbus.MessageBuilder.init(std.testing.allocator, .method_return, 10);
            defer ret_b.deinit();
            ret_b.reply_serial = req.serial;
            ret_b.signature = "u";
            try ret_b.writeU32(77);
            const ret_wire = try ret_b.build();
            defer std.testing.allocator.free(ret_wire);
            try s_conn.sendRaw(ret_wire);
            try s_conn.sendRaw(action);
        }
    };

    const thread = try std.Thread.spawn(.{}, Peer.run, .{ daemon_fd, action_wire });
    var peer_live = true;
    defer {
        if (peer_live) thread.join();
    }

    var provider = DbusNotificationProvider.initWithConnection(
        provider_fixed.allocator(),
        dbus.Connection.initCustom(ledger.allocator(), fds[0]),
    );
    var service = NotificationsService.init(std.testing.allocator, provider.provider());
    var service_live = true;
    defer {
        if (service_live) service.deinit();
    }

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    const outcome = service.submit(.{ .summary = "Acted on" }, weak_owner, handler);
    try std.testing.expect(outcome == .accepted);
    try std.testing.expectEqual(@as(NotificationId, 77), outcome.accepted);

    // The daemon has sent everything it had to say, and its socket is still
    // open because this thread holds the other end. Joining here is the
    // whole of its completion: a poll that never blocks reads only what is
    // already here, so asking it before the producer ran is asking early.
    thread.join();
    peer_live = false;

    // The drain copies the signal with the connection's allocator and routes
    // it to its owner. How many frames the drain counted is its own business;
    // that the owner heard the action, and that every byte came back through
    // this ledger below, is what this test is about.
    _ = try provider.poll(&service, 0);
    try std.testing.expectEqual(@as(usize, 1), owner.action_calls);

    // Releasing the provider gives every byte the connection charged back to
    // this ledger, the copy the drain made included.
    service.deinit();
    service_live = false;
    try std.testing.expectEqual(@as(usize, 0), ledger.live_bytes);
}

test "api-w19 dbus notify the answer to which cannot be held is a memory failure and not an I/O failure" {
    // The daemon answered, so the bus is fine and nothing refused anything.
    // What ran out is memory, and a caller has to be able to tell that from
    // an I/O failure over the same healthy bus.
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;

    // Only the transport is starved: its allocator stages the answer and
    // copies it out. The provider builds its call from a different one, so a
    // refusal below came from the transport and not from an unbuilt call.
    const StarvingConnection = struct {
        back: std.mem.Allocator,
        armed: bool = true,
        refusals: usize = 0,

        // A local declaration cannot name itself, so the methods say `Self`.
        const Self = @This();

        const vtable: std.mem.Allocator.VTable = .{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        };

        fn allocator(self: *Self) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }

        // Nothing here is keyed to a length or to which request comes
        // first: an allocator that is out of memory cannot tell, and neither
        // should the test.
        fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.armed) {
                self.refusals += 1;
                return null;
            }
            return self.back.rawAlloc(len, alignment, ret_addr);
        }

        fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.armed) return false;
            return self.back.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remapFn(
            ctx: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.armed) return null;
            return self.back.rawRemap(memory, alignment, new_len, ret_addr);
        }

        // Blocks handed out before the refusal came from `back`, so they go
        // back the same way.
        fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.back.rawFree(memory, alignment, ret_addr);
        }
    };
    var starving: StarvingConnection = .{ .back = std.testing.allocator };

    var provider = DbusNotificationProvider.initWithConnection(
        std.testing.allocator,
        dbus.Connection.initCustom(starving.allocator(), fds[0]),
    );
    var service = NotificationsService.init(std.testing.allocator, provider.provider());
    defer service.deinit();

    // The daemon answers two calls. The first answer is never taken off the
    // socket, so the second call has to pick its own out of what is there.
    const Peer = struct {
        fn run(fd: i32) !void {
            var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
            // This thread owns `fd` and closes it on the way out, so the join
            // below cannot outlive the socket the client reads.
            defer s_conn.deinit();

            for ([_]u32{ 41, 42 }) |id| {
                const req_bytes = try s_conn.readMessageBytes();
                defer std.testing.allocator.free(req_bytes);
                const req = try dbus.MessageParser.parse(req_bytes);
                try std.testing.expectEqualStrings("Notify", req.member.?);

                var ret_b = dbus.MessageBuilder.init(std.testing.allocator, .method_return, 10);
                defer ret_b.deinit();
                ret_b.reply_serial = req.serial;
                ret_b.signature = "u";
                try ret_b.writeU32(id);
                const ret_wire = try ret_b.build();
                defer std.testing.allocator.free(ret_wire);
                try s_conn.sendRaw(ret_wire);
            }
        }
    };

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    const thread = try std.Thread.spawn(.{}, Peer.run, .{fds[1]});
    const starved = service.submit(.{ .summary = "No room" }, weak_owner, handler);
    // Memory is back before the next call, over a bus that never went away.
    starving.armed = false;
    const recovered = service.submit(.{ .summary = "Room again" }, weak_owner, handler);
    thread.join();

    // The daemon answered, so this is not a refusal and not a protocol
    // failure. An allocation failed, and the caller cannot act on that unless
    // the outcome names it.
    try std.testing.expect(starved == .provider_failed);
    try std.testing.expectEqual(notifications.ProviderError.out_of_memory, starved.provider_failed);
    try std.testing.expect(starving.refusals > 0);

    // The submit the daemon answered was still never tracked, so no owner is
    // waiting on it and none of them is completed.
    try std.testing.expectEqual(@as(usize, 0), owner.action_calls);
    try std.testing.expectEqual(@as(usize, 0), owner.closed_calls);
    try std.testing.expectEqual(@as(usize, 0), owner.lost_calls);

    // A host told the memory ran out sheds memory and calls again over the
    // same bus. One told the bus failed would abandon a usable provider, so
    // the failure must not mark the transport lost.
    try std.testing.expect(!provider.is_gone);

    // The same provider over the same socket takes the next call, so the
    // transport stayed usable through the failure.
    try std.testing.expect(recovered == .accepted);
    try std.testing.expectEqual(@as(NotificationId, 42), recovered.accepted);
}

test "api-w19 dbus notify on a bus that went away is a lost provider and not an I/O failure" {
    // The daemon reads the call and drops the socket. The socket is the only
    // way to a daemon, so there is nothing left to ask, and a generic I/O
    // failure leaves the host retrying a transport that can never answer.
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;

    var provider = DbusNotificationProvider.initWithConnection(
        std.testing.allocator,
        dbus.Connection.initCustom(std.testing.allocator, fds[0]),
    );
    var service = NotificationsService.init(std.testing.allocator, provider.provider());
    defer service.deinit();

    const Peer = struct {
        fn run(fd: i32) !void {
            var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
            // This thread owns `fd` and closes it on the way out, which is the
            // loss the client is meant to observe.
            defer s_conn.deinit();

            // Reading the call is what keeps the socket open long enough for
            // the write to land. The answer is never sent.
            const req_bytes = try s_conn.readMessageBytes();
            defer std.testing.allocator.free(req_bytes);
            const req = try dbus.MessageParser.parse(req_bytes);
            try std.testing.expectEqualStrings("Notify", req.member.?);
        }
    };

    var owner: TestOwner = .{};
    const weak_owner: WeakOwner = .{ .context = &owner, .is_alive_fn = TestOwner.isAlive };
    const handler: ActionHandler = .{ .context = &owner, .callback = TestOwner.onResponse };

    const thread = try std.Thread.spawn(.{}, Peer.run, .{fds[1]});
    const failed = service.submit(.{ .summary = "Unanswered" }, weak_owner, handler);
    thread.join();

    // Nothing refused anything, so this is not a daemon verdict, and the
    // socket that closed is the only transport there was.
    try std.testing.expect(failed == .provider_failed);
    try std.testing.expectEqual(notifications.ProviderError.disconnected, failed.provider_failed);
}
