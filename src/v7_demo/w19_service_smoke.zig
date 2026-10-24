//! W19 native notification and secure-credential service smoke.
//!
//! The default command is harmless: it connects the production providers,
//! reports what the platform answers, and refuses every store call. It posts
//! no notification and reads, writes and deletes no credential, so a run of
//! `zig build w19-service-smoke` needs no approval from anybody.
//!
//! Two arms exist for the parts that touch a person's desktop and a person's
//! keyring. Each one refuses to start without its authorization flag AND an
//! exact copy of its point-of-risk scope text, so a run that names an action
//! cannot silently stop short of the scope that was approved:
//!
//!   notify     posts two synthetic toasts, replaces the first one, waits for
//!              the daemon's own answer, and dismisses what is left.
//!   credential writes one synthetic secret into the exact namespace the
//!              operator named, reads its own bytes back, and deletes the entry
//!              it created.
//!
//! Three of its conditions are supposed to be refused. None of them is a call
//! this run declines to make: each one reaches the real store, and each one is
//! proved by what the store holds afterwards rather than by what it said at the
//! time. A locked collection has to refuse the real write with
//! org.freedesktop.Secret.Error.IsLocked, a denied write has to leave the
//! namespace empty, and a locked item is only read through a real Unlock.
//!
//! The locked read has a precondition a headless run cannot meet on its own:
//! the bytes are reached only on a store that unlocks without a person, or with
//! a person at the keyboard. Its outcome is therefore reported for what it is.
//! A store that raises a real prompt and has it answered for it reports
//! `LockedReadNeededAPerson`; a locked collection that produced no item reports
//! `LockedReadProducedNoItem`, because a read that produced no item cannot tell
//! an empty namespace from a collection it could not see. Neither name is a
//! pass, neither counts as a locked read that succeeded, and neither is a
//! password that has gone missing.
//!
//! What the run never does:
//!   * It never invents a provider answer. Every response an owner receives
//!     comes from `NotificationsService.pump` routing a real daemon signal, or
//!     from the service's own `shutdown`, and the run says which was which.
//!   * It never answers a keyring prompt. The person at the keyboard does that,
//!     and a dismissal is reported as `prompt_dismissed`.
//!   * It never reaches a real account name. The service must be exactly
//!     `nogui-w19-smoke` and the account exactly `w19-smoke-<nonce>`, both
//!     checked before any provider exists, so a command line naming a real
//!     namespace is refused instead of searched.
//!   * It never uses an existing credential. The service is the one fixed smoke
//!     service and the account is that prefix plus a nonce the operator invents,
//!     both are checked before a provider exists, an occupied namespace is
//!     refused instead of replaced, and only the entry this run created is ever
//!     deleted.
//!   * It never logs a secret. Only lengths and one comparison result are
//!     printed; the synthetic bytes are wiped before the buffer dies.
//!   * It never posts a toast whose own answer the wait cannot reach. The toast
//!     expiry is the only delivery this run can observe, so `--wait-ms` has to
//!     exceed `--expiry-ms` by two pump slices. A pair that does not is
//!     refused before a provider exists, the way a real namespace is.
//!
//! Unrun limits, stated here rather than discovered later:
//!   * A command-line flag is not an approval. The person who owns the desktop
//!     has to approve the exact scope in the session that runs the arm.
//!   * The production Secret Service provider reads its socket without a
//!     timeout, so a wedged daemon cannot be interrupted mid-call. Each call
//!     therefore runs on a worker with a deadline; a call that overruns is
//!     cancelled, reported, and ends the process instead of hanging.
//!   * Only `org.freedesktop.Notifications` and `org.freedesktop.secrets` are
//!     reachable from here. The macOS and Windows adapters are not exercised.
//!   * No approval was given for either arm, so nothing here has been run
//!     against a live daemon or a live keyring. The tests at the foot of this
//!     file are the only part that runs headless, against an in-memory
//!     provider and store instead of a bus, a keyring and a screen.
//!
//! Run it: `zig build w19-service-smoke`.
const std = @import("std");
const Io = std.Io;

const host = @import("nogui_host");
const notifications = host.notifications;
const credentials = host.credentials;
const dbus_notifications = host.linux.notifications_dbus;
const secret_service = host.linux.credentials_secret_service;

/// The name the run gives itself on the bus and in the toast.
const app_name: []const u8 = "nogui-w19-service-smoke";
const category: []const u8 = "w19-smoke";
/// The single action offered when the daemon advertises actions.
const action_set = [_]notifications.Action{.{
    .key = "w19-acknowledge",
    .label = "Acknowledge (W19 smoke)",
}};
const no_actions: [0]notifications.Action = .{};

const authorize_notification_flag = "--authorize-native-notification-post";
const notification_scope_flag = "--notification-scope";
const authorize_credential_flag = "--authorize-secret-store-round-trip";
const credential_scope_flag = "--credential-scope";
const service_flag = "--service";
const account_flag = "--account";
const collection_flag = "--collection";
const wait_flag = "--wait-ms";
const expiry_flag = "--expiry-ms";

/// Which notification condition the notify arm proves. `scenario` is the
/// two-toast round trip; the other two each end one real toast through a
/// different cause, and in every case the daemon is still the only source of
/// an answer.
const NotifyCase = enum { scenario, owner_lost, provider_disconnect };

/// Which credential condition the credential arm proves. Every case reaches
/// the real provider on the real bus and names the one typed result it needs;
/// none of them is satisfied by a store that merely agrees with itself.
const CredentialCase = enum { round_trip, locked, denied, disconnected };

const notify_case_flag = "--notify-case";
const credential_case_flag = "--credential-case";

/// The point-of-risk scope of the notification arm, byte for byte. An operator
/// approves this text; the arm refuses anything else, including a prefix.
const notification_scope_text =
    "post two synthetic w19 toasts on this desktop, replace the first one, " ++
    "dismiss what is left, and wait for the daemon's own answer";

/// The point-of-risk scope of the credential arm, byte for byte. It names the
/// namespace the operator passes on the command line and nothing else.
const credential_scope_text =
    "create, read back and delete one synthetic secret under the namespace named by --service and --account";

/// The only service this run may ever write under. Any other service is
/// refused before a provider exists, so no real namespace is reachable.
const smoke_service: []const u8 = "nogui-w19-smoke";
/// Every account is this prefix plus a nonce the operator chooses and never
/// reuses, so two runs can never address the same entry.
const account_prefix: []const u8 = "w19-smoke-";
const min_nonce_len: usize = 8;
const max_nonce_len: usize = 32;
/// Every collection path must stay under the Secret Service root and name the
/// same account, so no existing collection of the user becomes a write target.
const collection_prefix: []const u8 = "/org/freedesktop/secrets/";

const min_wait_ms: u64 = 200;
const max_wait_ms: u64 = 120_000;
const default_wait_ms: u64 = 8_000;
const min_expiry_ms: i32 = 200;
const max_expiry_ms: i32 = 60_000;
const default_expiry_ms: i32 = 2_000;
/// One `pump` slice. Short enough that the wait ends close to its deadline.
const pump_slice_ms: i32 = 200;
/// How much wait the notify arm needs past the toast expiry it is there to
/// observe: two `pump` slices. A daemon answers at, or a little after, the
/// timeout it was given, and the pump routes one slice at a time, so a wait
/// that ended inside the first slice after the expiry would be racing the
/// answer it exists to observe rather than waiting for it.
const min_pump_slack_ms: i64 = 2 * @as(i64, pump_slice_ms);
const worker_step_ms: i64 = 4;
const max_deliveries = 8;
const max_action_key = 32;

const Command = enum { capability, notify, credential, help };

const Options = struct {
    command: Command = .capability,
    authorize_notification: bool = false,
    authorize_credential: bool = false,
    notification_scope: ?[]const u8 = null,
    credential_scope: ?[]const u8 = null,
    service: ?[]const u8 = null,
    account: ?[]const u8 = null,
    collection: ?[]const u8 = null,
    wait_ms: u64 = default_wait_ms,
    expiry_ms: i32 = default_expiry_ms,
    notify_case: ?NotifyCase = null,
    credential_case: ?CredentialCase = null,
};

const Reporter = struct {
    io: Io,
    output: Io.File = .stdout(),
    buffer: [1024]u8 = @splat(0),

    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        // The buffer is reused for every line, so formatting into it is a
        // write and the result borrows it.
        const text = try std.fmt.bufPrint(&self.buffer, fmt, args);
        try self.output.writeStreamingAll(self.io, text);
    }
};

fn nowNs(io: Io) i96 {
    return Io.Timestamp.now(io, .awake).nanoseconds;
}

/// Text no other run of this binary can produce, so two runs never address the
/// same namespace and no stale entry is ever mistaken for a fresh one.
fn uniqueToken(io: Io, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d}-{d}", .{ std.os.linux.getpid(), nowNs(io) });
}

fn providerErrorTag(failure: notifications.ProviderError) []const u8 {
    return @tagName(failure);
}

fn credentialProviderErrorTag(failure: credentials.ProviderError) []const u8 {
    return @tagName(failure);
}

fn submitTag(outcome: notifications.SubmitOutcome) []const u8 {
    return switch (outcome) {
        .accepted => "accepted",
        .unsupported => "unsupported",
        .denied => "denied",
        .provider_failed => "provider_failed",
    };
}

fn dismissTag(outcome: notifications.DismissOutcome) []const u8 {
    return switch (outcome) {
        .closed => "closed",
        .unsupported => "unsupported",
        .refused => "refused",
        .provider_failed => "provider_failed",
    };
}

fn readTag(result: credentials.ReadResult) []const u8 {
    return switch (result) {
        .found => "found",
        .not_found => "not_found",
        .locked => "locked",
        .prompt_dismissed => "prompt_dismissed",
        .denied => "denied",
        .canceled => "canceled",
        .provider_failed => "provider_failed",
        .unsupported => "unsupported",
    };
}

fn writeTag(result: credentials.WriteResult) []const u8 {
    return switch (result) {
        .success => "success",
        .locked => "locked",
        .prompt_dismissed => "prompt_dismissed",
        .denied => "denied",
        .canceled => "canceled",
        .provider_failed => "provider_failed",
        .unsupported => "unsupported",
    };
}

fn deleteTag(result: credentials.DeleteResult) []const u8 {
    return switch (result) {
        .success => "success",
        .not_found => "not_found",
        .locked => "locked",
        .prompt_dismissed => "prompt_dismissed",
        .denied => "denied",
        .canceled => "canceled",
        .provider_failed => "provider_failed",
        .unsupported => "unsupported",
    };
}

/// Which call delivered a response. The run knows, because the run makes the
/// call: `pump` routes what the daemon sent, `shutdown` completes whatever is
/// still tracked without a daemon answer.
const Origin = enum { pump, shutdown };

const DeliveryKind = enum { action, closed, provider_lost };

const Delivery = struct {
    id: notifications.NotificationId = 0,
    origin: Origin = .pump,
    kind: DeliveryKind = .provider_lost,
    action_key: [max_action_key]u8 = @splat(0),
    action_len: usize = 0,
    close_reason: notifications.CloseReason = .undefined,
};

/// The live owner every notification of the run is bound to. It stays alive
/// until the run ends, so no delivery is dropped as a dead owner.
const Recorder = struct {
    alive: bool = true,
    origin: Origin = .pump,
    deliveries: [max_deliveries]Delivery = @splat(.{}),
    count: usize = 0,
    dropped: usize = 0,

    fn bind(context: *const anyopaque) notifications.WeakOwner {
        return .{ .context = context, .is_alive_fn = probe };
    }

    fn probe(context: *const anyopaque) bool {
        const self: *const Recorder = @ptrCast(@alignCast(context));
        return self.alive;
    }

    fn onResponse(
        context: ?*anyopaque,
        id: notifications.NotificationId,
        response: notifications.Response,
    ) void {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        if (self.count == self.deliveries.len) {
            self.dropped += 1;
            return;
        }
        const slot = &self.deliveries[self.count];
        self.count += 1;
        slot.id = id;
        slot.origin = self.origin;
        switch (response) {
            .action => |activation| {
                slot.kind = .action;
                // The key borrows the provider's frame, which the next drain
                // reuses, so it is copied here or nowhere.
                const key = activation.key;
                if (key.len <= slot.action_key.len) {
                    @memcpy(slot.action_key[0..key.len], key);
                    slot.action_len = key.len;
                } else {
                    slot.action_len = 0;
                }
            },
            .closed => |close| {
                slot.kind = .closed;
                slot.close_reason = close.reason;
            },
            .provider_lost => slot.kind = .provider_lost,
        }
    }

    fn emit(self: *const Recorder, report: *Reporter) !void {
        for (self.deliveries[0..self.count]) |delivery| {
            switch (delivery.kind) {
                .action => try report.emit(
                    "notification: delivered id={d} origin={s} action=\"{s}\"\n",
                    .{ delivery.id, @tagName(delivery.origin), delivery.action_key[0..delivery.action_len] },
                ),
                .closed => try report.emit(
                    "notification: delivered id={d} origin={s} closed reason={s}\n",
                    .{ delivery.id, @tagName(delivery.origin), @tagName(delivery.close_reason) },
                ),
                .provider_lost => try report.emit(
                    "notification: delivered id={d} origin={s} provider_lost\n",
                    .{ delivery.id, @tagName(delivery.origin) },
                ),
            }
        }
        if (self.dropped != 0) {
            try report.emit(
                "notification: {d} deliveries did not fit this recorder\n",
                .{self.dropped},
            );
        }
    }
};

fn emitCapabilities(report: *Reporter, capabilities: notifications.Capabilities) !void {
    try report.emit(
        "notification: capabilities body={} body_hyperlinks={} body_markup={} body_images={}" ++
            " actions={} action_icons={} sound={} persistence={}\n",
        .{
            capabilities.body,
            capabilities.body_hyperlinks,
            capabilities.body_markup,
            capabilities.body_images,
            capabilities.actions,
            capabilities.action_icons,
            capabilities.sound,
            capabilities.persistence,
        },
    );
}

fn emitSubmit(report: *Reporter, label: []const u8, outcome: notifications.SubmitOutcome) !void {
    switch (outcome) {
        .accepted => |id| try report.emit(
            "notification: {s} outcome=accepted id={d}\n",
            .{ label, id },
        ),
        else => try report.emit(
            "notification: {s} outcome={s}\n",
            .{ label, submitTag(outcome) },
        ),
    }
}

fn emitDismiss(report: *Reporter, label: []const u8, outcome: notifications.DismissOutcome) !void {
    switch (outcome) {
        .closed => try report.emit("notification: {s} outcome=closed\n", .{label}),
        .refused => try report.emit("notification: {s} outcome=refused\n", .{label}),
        .unsupported => try report.emit("notification: {s} outcome=unsupported\n", .{label}),
        .provider_failed => |failure| try report.emit(
            "notification: {s} outcome=provider_failed failure={s}\n",
            .{ label, providerErrorTag(failure) },
        ),
    }
}

/// Report one credential read and release whatever it brought back. The bytes
/// are never printed, only counted.
fn emitRead(report: *Reporter, label: []const u8, result: credentials.ReadResult) !void {
    var owned = result;
    defer if (owned == .found) owned.found.deinit();
    switch (owned) {
        .found => try report.emit(
            "credential: {s} outcome=found bytes={d}\n",
            .{ label, owned.found.secret.len },
        ),
        .provider_failed => |failure| try report.emit(
            "credential: {s} outcome=provider_failed failure={s}\n",
            .{ label, credentialProviderErrorTag(failure) },
        ),
        else => try report.emit(
            "credential: {s} outcome={s}\n",
            .{ label, readTag(owned) },
        ),
    }
}

fn emitWrite(report: *Reporter, label: []const u8, result: credentials.WriteResult) !void {
    switch (result) {
        .provider_failed => |failure| try report.emit(
            "credential: {s} outcome=provider_failed failure={s}\n",
            .{ label, credentialProviderErrorTag(failure) },
        ),
        else => try report.emit(
            "credential: {s} outcome={s}\n",
            .{ label, writeTag(result) },
        ),
    }
}

fn emitDelete(report: *Reporter, label: []const u8, result: credentials.DeleteResult) !void {
    switch (result) {
        .provider_failed => |failure| try report.emit(
            "credential: {s} outcome=provider_failed failure={s}\n",
            .{ label, credentialProviderErrorTag(failure) },
        ),
        else => try report.emit(
            "credential: {s} outcome={s}\n",
            .{ label, deleteTag(result) },
        ),
    }
}

/// One credential call and the slot its worker fills.
///
/// The record is heap allocated because a worker that outlives its deadline is
/// never killed: it must not be writing into a stack frame that has already
/// been unwound, and it must not reach a service that has been released under
/// it. The record therefore also owns the thread of a call that missed its
/// budget, so whoever outlives that call owns the worker with it.
const Call = struct {
    gpa: std.mem.Allocator,
    service: *credentials.CredentialsService,
    query: credentials.CredentialQuery,
    secret: []const u8,
    token: credentials.CancellationToken = .{},
    done: std.atomic.Value(bool) = .init(false),
    /// The thread of a call that missed its budget, or null when no worker is
    /// outstanding. It is handed over rather than detached so the owner of the
    /// record can join it: a detached thread is still writing into this record
    /// and still calling through `service` after a timeout has been reported.
    pending: ?std.Thread = null,
    read_result: credentials.ReadResult = .canceled,
    write_result: credentials.WriteResult = .unsupported,
    delete_result: credentials.DeleteResult = .unsupported,
};

fn readWorker(call: *Call) void {
    call.read_result = call.service.read(call.gpa, call.query, &call.token);
    call.done.store(true, .release);
}

fn writeWorker(call: *Call) void {
    call.write_result = call.service.write(call.query, call.secret, &call.token);
    call.done.store(true, .release);
}

fn deleteWorker(call: *Call) void {
    call.delete_result = call.service.delete(call.query, &call.token);
    call.done.store(true, .release);
}

/// Wait for a worker inside its budget.
///
/// The production provider waits on its socket without a timeout, so a call
/// that overruns is cancelled and reported rather than left hanging: the token
/// is the provider's own cancellation contract, and a worker that is still
/// inside a call when the budget ends is a thread that cannot be killed. What
/// happens next belongs to the caller, which is why the report says the worker
/// is still inside the provider and stops there.
fn waitForWorker(
    io: Io,
    call: *Call,
    deadline_ms: u64,
    label: []const u8,
    report: *Reporter,
) bool {
    const deadline = nowNs(io) + @as(i96, deadline_ms) * std.time.ns_per_ms;
    while (!call.done.load(.acquire)) {
        if (nowNs(io) >= deadline) {
            call.token.cancel();
            report.emit(
                "credential: {s} did not answer within {d} ms; the call was cancelled, its result is unknown," ++
                    " and its worker is still inside the provider\n",
                .{ label, deadline_ms },
            ) catch @panic("W19 service smoke could not report an unanswered call");
            return false;
        }
        Io.sleep(io, Io.Duration.fromMilliseconds(worker_step_ms), .real) catch |err| switch (err) {
            error.Canceled => {},
        };
    }
    return true;
}

/// Start one call on a worker, wait for it inside its budget, and join it.
///
/// This is the only place a call is started, so the per-call state of the
/// record is this function's business rather than each caller's. It answers
/// false when the budget ran out, and the worker is then still inside a
/// provider call that cannot be killed: the thread is left in the record
/// instead of being detached, so the record, the service and the provider all
/// outlive it. The wrappers end the process there, which is the only way a real
/// provider can be left behind, and a caller that returns to its own code owns
/// the worker instead and has to drain it with `drainCall` first.
fn awaitWorker(
    io: Io,
    call: *Call,
    deadline_ms: u64,
    label: []const u8,
    report: *Reporter,
    comptime worker: anytype,
) !bool {
    // A worker left over from a call that timed out is still inside its
    // provider, and starting a second call on the same record would lose the
    // only handle that thread has.
    std.debug.assert(call.pending == null);
    call.done.store(false, .monotonic);
    call.token = .{};
    const thread = try std.Thread.spawn(.{}, worker, .{call});
    if (!waitForWorker(io, call, deadline_ms, label, report)) {
        call.pending = thread;
        return false;
    }
    thread.join();
    return true;
}

/// Wait out a call that missed its budget, so the record it fills and the
/// service it calls outlive it.
///
/// This is the other half of `awaitWorker` answering false. The real wrappers
/// end the process there, so nothing reaches this; a caller that returns has to
/// do the waiting itself, because the worker is still inside a provider and is
/// about to write into a record that its caller is about to release. The bound
/// is generous on purpose: a worker that has stored its result is a thread away
/// from its end, and a bound that runs out says the provider is wedged, in which
/// case the record is left alone rather than freed under a live worker, which is
/// the failure this exists to prevent.
fn drainCall(
    io: Io,
    call: *Call,
    bound_ms: u64,
    label: []const u8,
    report: *Reporter,
) !void {
    const thread = call.pending orelse return;
    const bound = nowNs(io) + @as(i96, bound_ms) * std.time.ns_per_ms;
    while (!call.done.load(.acquire)) {
        if (nowNs(io) >= bound) {
            report.emit(
                "credential: {s} is still inside its provider after {d} ms, so this record is left" ++
                    " alone rather than released under a worker that is still writing into it\n",
                .{ label, bound_ms },
            ) catch @panic("W19 service smoke could not report a worker that never came back");
            return error.WorkerOutlivedItsRecord;
        }
        Io.sleep(io, Io.Duration.fromMilliseconds(worker_step_ms), .real) catch |err| switch (err) {
            error.Canceled => {},
        };
    }
    thread.join();
    call.pending = null;
}

fn awaitRead(
    io: Io,
    call: *Call,
    deadline_ms: u64,
    label: []const u8,
    report: *Reporter,
) !credentials.ReadResult {
    if (!try awaitWorker(io, call, deadline_ms, label, report, readWorker)) {
        std.process.exit(1);
    }
    return call.read_result;
}

fn awaitWrite(
    io: Io,
    call: *Call,
    deadline_ms: u64,
    label: []const u8,
    report: *Reporter,
) !credentials.WriteResult {
    if (!try awaitWorker(io, call, deadline_ms, label, report, writeWorker)) {
        std.process.exit(1);
    }
    return call.write_result;
}

fn awaitDelete(
    io: Io,
    call: *Call,
    deadline_ms: u64,
    label: []const u8,
    report: *Reporter,
) !credentials.DeleteResult {
    if (!try awaitWorker(io, call, deadline_ms, label, report, deleteWorker)) {
        std.process.exit(1);
    }
    return call.delete_result;
}

/// An authorization that has to be typed exactly. A near miss is a refusal,
/// because a scope nobody approved is not a shorter version of one that was.
fn requireScope(given: ?[]const u8, expected: []const u8, flag: []const u8) !void {
    const text = given orelse {
        std.log.err("missing {s}", .{flag});
        return error.MissingAuthorizationScope;
    };
    if (!std.mem.eql(u8, text, expected)) {
        std.log.err("{s} does not match the authorized scope", .{flag});
        std.log.err("expected exactly: {s}", .{expected});
        return error.AuthorizationScopeMismatch;
    }
}

fn requireNotificationAuthorization(options: Options) !void {
    if (!options.authorize_notification) {
        std.log.err(
            "the notification arm posts on a person's screen and needs {s}",
            .{authorize_notification_flag},
        );
        return error.MissingNotificationAuthorization;
    }
    try requireScope(options.notification_scope, notification_scope_text, notification_scope_flag);
}

fn requireCredentialAuthorization(options: Options) !void {
    if (!options.authorize_credential) {
        std.log.err(
            "the credential arm writes to a keyring and needs {s}",
            .{authorize_credential_flag},
        );
        return error.MissingCredentialAuthorization;
    }
    try requireScope(options.credential_scope, credential_scope_text, credential_scope_flag);
}

fn printUsage(report: *Reporter) !void {
    try report.emit("usage:\n", .{});
    try report.emit(
        "  w19-service-smoke                    safe default: capability report, nothing posted, nothing read\n",
        .{},
    );
    try report.emit("  w19-service-smoke capability         the same safe default, named\n", .{});
    try report.emit(
        "  w19-service-smoke notify {s} {s} \"<exact text>\" [--wait-ms N] [--expiry-ms N]\n",
        .{ authorize_notification_flag, notification_scope_flag },
    );
    try report.emit(
        "  w19-service-smoke credential {s} {s} \"<exact text>\" {s} <service> {s} <account>" ++
            " [--collection <path>] [--wait-ms N]\n",
        .{ authorize_credential_flag, credential_scope_flag, service_flag, account_flag },
    );
    try report.emit(
        "\nnotify conditions, exactly one, default \"scenario\":\n" ++
            "  {s} scenario             two toasts, the first replaced, both dismissed\n" ++
            "  {s} owner-lost           one real toast whose owner ends before the daemon answers\n" ++
            "  {s} provider-disconnect  one real toast ended because its transport really went away\n",
        .{ notify_case_flag, notify_case_flag, notify_case_flag },
    );
    try report.emit(
        "\ncredential conditions, exactly one, default \"round-trip\":\n" ++
            "  {s} round-trip    write, read back, delete, prove the namespace is empty again\n" ++
            "  {s} locked        a locked collection refuses a real write with IsLocked, and the\n" ++
            "                  namespace still holds nothing this run wrote\n" ++
            "  {s} denied        a real write is refused with a denial, and the namespace is empty after it\n" ++
            "  {s} disconnected  a connected provider goes away and the next call names it\n",
        .{ credential_case_flag, credential_case_flag, credential_case_flag, credential_case_flag },
    );
    try report.emit(
        "\nBoth refusal conditions are proved by the store, never by this run: the call that has to be\n" ++
            "refused is made first and the namespace is read back afterwards, because a refusal only counts\n" ++
            "when nothing this run wrote is in the store. A locked item is read through Secret.Service.Unlock,\n" ++
            "and reaching its bytes needs a store that unlocks without a person, or a person at the keyboard.\n" ++
            "This run answers no prompt, so a store that raises one has it answered for it: the run reports\n" ++
            "prompt_dismissed and ends the case as LockedReadNeededAPerson. A daemon that raises a prompt\n" ++
            "and never answers it ends that call at its budget instead. A locked collection that produced\n" ++
            "no item is a different answer and ends the case as LockedReadProducedNoItem, because a read\n" ++
            "that produced no item cannot tell an empty namespace from a collection it could not see.\n" ++
            "Neither is a successful locked read and neither is a password that is missing.\n" ++
            "Every write reports its typed outcome as a line of its own, the locked and the denied\n" ++
            "refusals included, so a caller reads what the store answered and not a sentence about it.\n",
        .{},
    );
    try report.emit(
        "\nA condition is not an approval: it is refused without the authorization flag and the exact\n" ++
            "scope text of its own command.\n",
        .{},
    );
    try report.emit("\nnotification scope, exactly:\n  {s}\n", .{notification_scope_text});
    try report.emit("\ncredential scope, exactly:\n  {s}\n", .{credential_scope_text});
    try report.emit(
        "\nnotify reads {s} as the daemon's toast expiry and {s} as the wait that routes the daemon's own\n" ++
            "answer, so {s} has to exceed {s} by at least {d} ms. A pair that does not is refused before\n" ++
            "anything is posted.\n",
        .{ expiry_flag, wait_flag, wait_flag, expiry_flag, min_pump_slack_ms },
    );
    try report.emit(
        "\nThe credential arm reaches exactly one namespace shape, checked before any provider exists:\n" ++
            "  {s} \"{s}\"\n" ++
            "  {s} \"{s}<nonce>\"   nonce is {d}-{d} characters of a-z and 0-9 that the operator never reuses\n" ++
            "  {s} <optional>      a path under \"{s}\" that contains that same account\n",
        .{
            service_flag,
            smoke_service,
            account_flag,
            account_prefix,
            min_nonce_len,
            max_nonce_len,
            collection_flag,
            collection_prefix,
        },
    );
    try report.emit(
        "\nAny other service or account is refused before the store is searched. A namespace that already\n" ++
            "holds an entry is refused rather than replaced, and only the entry this run created is deleted.\n",
        .{},
    );
}

/// The safe default: report what this session's providers answer and refuse
/// every store call. Nothing here can put a toast on a screen or reach an
/// entry in the keyring.
fn runCapabilityReport(gpa: std.mem.Allocator, report: *Reporter) !void {
    try report.emit(
        "capability: this command posts no notification and reads, writes and deletes no credential\n",
        .{},
    );

    // A real connect and a real capability query. No submit is reachable from
    // this path, so the user's screen stays as it is.
    var notification_provider = dbus_notifications.DbusNotificationProvider.init(gpa);
    if (notification_provider.connect()) {
        var notification_service = notifications.NotificationsService.init(gpa, notification_provider.provider());
        // The service owns the provider from here, so nothing else may hold a
        // reference to it once this scope ends.
        defer notification_service.deinit();
        const capabilities = notification_service.getCapabilities();
        try emitCapabilities(report, capabilities);
        try report.emit(
            "notification: daemon reachable, tracked notifications={d}\n",
            .{notification_service.tracked.count()},
        );
    } else |err| {
        try report.emit("notification: no daemon, connect error={s}\n", .{@errorName(err)});
        notification_provider.deinit();
    }

    // The real Secret Service provider is constructed and released without a
    // single call into it. The three refusals below are the production
    // `CredentialsService.validateQuery` answer to a query with no service and
    // no account, which runs before the provider is reached, so no message
    // reaches the bus, no entry is searched and no prompt is raised.
    var secret_provider = secret_service.SecretServiceCredentialProvider.init(gpa);
    var credential_service = credentials.CredentialsService.init(gpa, secret_provider.provider());
    defer credential_service.deinit();
    var token: credentials.CancellationToken = .{};
    const empty: credentials.CredentialQuery = .{ .service = "", .account = "" };
    try emitRead(report, "empty-query read", credential_service.read(gpa, empty, &token));
    try emitWrite(report, "empty-query write", credential_service.write(empty, "", &token));
    try emitDelete(report, "empty-query delete", credential_service.delete(empty, &token));
    try report.emit(
        "credential: every call was refused before the provider was reached, so the store was never searched\n",
        .{},
    );
}

/// The notification arm, behind its authorization. It reaches the daemon,
/// reports what this session can do, and hands the service to the scenario
/// below, which is where every toast is posted and closed.
fn runNotificationArm(
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    options: Options,
) !void {
    try requireNotificationAuthorization(options);
    try report.emit("notification: authorized scope\n  {s}\n", .{notification_scope_text});
    try report.emit(
        "notification: wait budget {d} ms, toast expiry {d} ms\n",
        .{ options.wait_ms, options.expiry_ms },
    );

    var token_buffer: [48]u8 = undefined;
    const token = try uniqueToken(io, &token_buffer);
    try report.emit("notification: run token {s}\n", .{token});

    var provider = dbus_notifications.DbusNotificationProvider.init(gpa);
    provider.connect() catch |err| {
        try report.emit("notification: provider connect failed, error={s}\n", .{@errorName(err)});
        provider.deinit();
        return error.NotificationProviderUnavailable;
    };
    try report.emit("notification: connected to org.freedesktop.Notifications\n", .{});

    // From here the service owns the provider: `deinit` disconnects it and
    // releases it, so this function holds no other reference to it.
    var notification_service = notifications.NotificationsService.init(gpa, provider.provider());
    defer notification_service.deinit();

    const capabilities = notification_service.getCapabilities();
    try emitCapabilities(report, capabilities);
    try report.emit("notification: case={s}\n", .{@tagName(options.notify_case orelse .scenario)});
    switch (options.notify_case orelse .scenario) {
        .scenario => try runNotifyScenario(io, report, options, &notification_service, capabilities, token),
        .owner_lost => try runOwnerLossScenario(io, report, options, &notification_service, capabilities, token),
        .provider_disconnect => try runProviderLossScenario(
            io,
            report,
            options,
            &notification_service,
            capabilities,
            token,
        ),
    }
}

/// What the arm does to a session's notifications: two synthetic toasts, the
/// first one replaced, a wait for the daemon's own answer, a dismissal of
/// whatever is left, and the never-expiring toast this run closes itself.
///
/// The service is a parameter rather than something this builds, so the
/// scenario is the same against a real bus and against a provider that answers
/// in memory. The caller owns the service, so every path out of here retires
/// the tracked notifications while the owner that received their answers is
/// still alive to be told.
fn runNotifyScenario(
    io: Io,
    report: *Reporter,
    options: Options,
    notification_service: *notifications.NotificationsService,
    capabilities: notifications.Capabilities,
    token: []const u8,
) !void {
    const actions: []const notifications.Action = if (capabilities.actions)
        action_set[0..]
    else
        no_actions[0..];
    try report.emit(
        "notification: actions offered={} (a daemon without actions gets none)\n",
        .{capabilities.actions},
    );
    if (!capabilities.actions) {
        // A daemon with no action buttons cannot deliver an activation, so
        // this run cannot observe one. That is a limit of the session rather
        // than a failure of it: neither close below depends on an action.
        try report.emit(
            "notification: this daemon offers no actions, so no action activation can be observed\n",
            .{},
        );
    }

    var summary_first: [128]u8 = undefined;
    var summary_replaced: [128]u8 = undefined;
    var summary_final: [128]u8 = undefined;
    var body_first: [192]u8 = undefined;
    var body_replaced: [192]u8 = undefined;
    var body_final: [192]u8 = undefined;
    const first_summary = try std.fmt.bufPrint(&summary_first, "w19 smoke {s}", .{token});
    const replaced_summary = try std.fmt.bufPrint(&summary_replaced, "w19 smoke {s} (replaced)", .{token});
    const final_summary = try std.fmt.bufPrint(&summary_final, "w19 smoke {s} (dismiss test)", .{token});
    const first_body = try std.fmt.bufPrint(
        &body_first,
        "Synthetic notification {s} from the nogui W19 service smoke. It carries no user data.",
        .{token},
    );
    const replaced_body = try std.fmt.bufPrint(
        &body_replaced,
        "Replacement for the synthetic notification {s} posted by the nogui W19 service smoke.",
        .{token},
    );
    const final_body = try std.fmt.bufPrint(
        &body_final,
        "Synthetic notification {s} that this run dismisses itself.",
        .{token},
    );

    var recorder: Recorder = .{};
    // The owner below is bound to this frame, so every path out of here has to
    // retire the tracked notifications while it is still there to receive
    // them. `shutdown` is what completes them, and it does nothing once it has
    // already run.
    defer notification_service.shutdown();
    const owner = Recorder.bind(&recorder);
    const handler: notifications.ActionHandler = .{
        .context = &recorder,
        .callback = Recorder.onResponse,
    };

    // The first toast expires on its own, so the answer the owner receives has
    // to come from the daemon itself rather than from a close this run asked
    // for. That is the delivery the pump below exists to observe.
    const first = notification_service.submit(.{
        .summary = first_summary,
        .body = first_body,
        .app_name = app_name,
        .category = category,
        .timeout_ms = options.expiry_ms,
        .actions = actions,
    }, owner, handler);
    try emitSubmit(report, "first submit", first);
    const first_id = switch (first) {
        .accepted => |id| id,
        else => return error.SubmitWasNotAccepted,
    };

    // The replacement reuses the tracked owner and handler, so the answer the
    // daemon sends for it still reaches the owner the run bound.
    const replaced = notification_service.replace(first_id, .{
        .summary = replaced_summary,
        .body = replaced_body,
        .app_name = app_name,
        .category = category,
        .timeout_ms = options.expiry_ms,
        .actions = actions,
    });
    try emitSubmit(report, "replacement submit", replaced);
    const current_id = switch (replaced) {
        .accepted => |id| id,
        else => return error.ReplacementWasNotAccepted,
    };
    try report.emit(
        "notification: replaced id={d} with id={d}, tracked after replacement={d}\n",
        .{ first_id, current_id, notification_service.tracked.count() },
    );

    recorder.origin = .pump;
    const deadline = nowNs(io) + @as(i96, options.wait_ms) * std.time.ns_per_ms;
    var routed: usize = 0;
    var slices: usize = 0;
    while (recorder.count == 0) {
        const now = nowNs(io);
        if (now >= deadline) break;
        const remaining_ms: i64 = @intCast(@divTrunc(deadline - now, std.time.ns_per_ms));
        const slice: i32 = @intCast(@max(@min(remaining_ms, pump_slice_ms), 1));
        slices += 1;
        routed += notification_service.pump(slice) catch |err| {
            try report.emit("notification: pump failed, error={s}\n", .{@errorName(err)});
            return error.PumpFailed;
        };
    }
    try report.emit(
        "notification: pump slices={d} routed={d} owner deliveries={d}\n",
        .{ slices, routed, recorder.count },
    );
    if (recorder.count == 0) {
        try report.emit(
            "notification: the daemon sent no answer within {d} ms, so no owner delivery was observed\n",
            .{options.wait_ms},
        );
    } else {
        // A response for an id this run never posted would mean the daemon is
        // answering somebody else, which the run must not report as its own.
        for (recorder.deliveries[0..recorder.count]) |delivery| {
            if (delivery.id != first_id and delivery.id != current_id) {
                try report.emit(
                    "notification: an answer arrived for id={d}, which this run never posted\n",
                    .{delivery.id},
                );
                return error.ResponseForAnUnknownNotification;
            }
        }
    }

    var closed: usize = 0;
    if (notification_service.tracked.contains(current_id)) {
        const outcome = notification_service.dismiss(current_id);
        try emitDismiss(report, "dismiss of the expiring notification", outcome);
        if (outcome == .closed) closed += 1;
        if (outcome != .closed) {
            try report.emit(
                "notification: id={d} is still on screen and is not gone: outcome={s}\n",
                .{ current_id, dismissTag(outcome) },
            );
        }
    } else {
        var daemon_closed = false;
        for (recorder.deliveries[0..recorder.count]) |delivery| {
            if (delivery.id == current_id and delivery.origin == .pump and delivery.kind == .closed) {
                daemon_closed = true;
                break;
            }
        }
        if (daemon_closed) closed += 1;
        try report.emit(
            "notification: id={d} is no longer tracked; daemon close observed={}\n",
            .{ current_id, daemon_closed },
        );
    }

    // A toast that never expires is the only way to see what a close this run
    // asked for answers.
    const final_submit = notification_service.submit(.{
        .summary = final_summary,
        .body = final_body,
        .app_name = app_name,
        .category = category,
        .timeout_ms = 0,
        .actions = actions,
    }, owner, handler);
    try emitSubmit(report, "dismiss-test submit", final_submit);
    const final_id = switch (final_submit) {
        .accepted => |id| id,
        else => return error.DismissTestSubmitWasNotAccepted,
    };
    const final_dismiss = notification_service.dismiss(final_id);
    try emitDismiss(report, "dismiss of the never-expiring notification", final_dismiss);
    if (final_dismiss == .closed) closed += 1;

    recorder.origin = .shutdown;
    notification_service.shutdown();
    try report.emit(
        "notification: shutdown completed; tracked now={d}\n",
        .{notification_service.tracked.count()},
    );
    try recorder.emit(report);
    try report.emit(
        "notification: posted=2 replaced=1 closed={d} owner deliveries={d} dropped={d}\n",
        .{ closed, recorder.count, recorder.dropped },
    );
    if (recorder.count == 0) return error.NoOwnerDeliveryObserved;
    if (closed != 2) return error.NotificationWasNotClosed;
}

/// Owner loss. One real toast is posted, this run's owner ends while the toast
/// is still on the daemon's screen, and the daemon's own expiry is then routed.
/// A retired owner must hear nothing and the tracking must go, because an
/// answer that resurrects a released owner is the failure this case exists to
/// catch.
fn runOwnerLossScenario(
    io: Io,
    report: *Reporter,
    options: Options,
    notification_service: *notifications.NotificationsService,
    capabilities: notifications.Capabilities,
    token: []const u8,
) !void {
    var summary_first: [128]u8 = undefined;
    var body_first: [192]u8 = undefined;
    const first_summary = try std.fmt.bufPrint(&summary_first, "w19 smoke {s}", .{token});
    const first_body = try std.fmt.bufPrint(
        &body_first,
        "Synthetic notification {s} whose owner this run releases before the daemon answers.",
        .{token},
    );

    var recorder: Recorder = .{};
    // Every path out of here retires the tracked notification while the owner
    // that received its answers is still bound, exactly as the scenario above.
    defer notification_service.shutdown();
    const owner = Recorder.bind(&recorder);
    const handler: notifications.ActionHandler = .{
        .context = &recorder,
        .callback = Recorder.onResponse,
    };

    const submitted = notification_service.submit(.{
        .summary = first_summary,
        .body = first_body,
        .app_name = app_name,
        .category = category,
        // The daemon's own expiry is the only answer this run can observe, so
        // the toast carries the same expiry the wait is built to outlast.
        .timeout_ms = options.expiry_ms,
        .actions = if (capabilities.actions) action_set[0..] else no_actions[0..],
    }, owner, handler);
    try emitSubmit(report, "owner-loss submit", submitted);
    const id = switch (submitted) {
        .accepted => |value| value,
        else => return error.SubmitWasNotAccepted,
    };

    // The only thing that changes now is this run's own owner. The daemon still
    // owns the toast and is still the only thing that can end it.
    recorder.alive = false;
    try report.emit(
        "notification: owner released while id={d} is tracked={} and still on screen\n",
        .{ id, notification_service.tracked.contains(id) },
    );

    recorder.origin = .pump;
    const deadline = nowNs(io) + @as(i96, options.wait_ms) * std.time.ns_per_ms;
    var slices: usize = 0;
    var routed: usize = 0;
    while (notification_service.tracked.contains(id)) {
        const now = nowNs(io);
        if (now >= deadline) break;
        const remaining_ms: i64 = @intCast(@divTrunc(deadline - now, std.time.ns_per_ms));
        const slice: i32 = @intCast(@max(@min(remaining_ms, pump_slice_ms), 1));
        slices += 1;
        routed += notification_service.pump(slice) catch |err| {
            try report.emit("notification: pump failed, error={s}\n", .{@errorName(err)});
            return error.PumpFailed;
        };
    }
    try report.emit(
        "notification: owner-loss pump slices={d} routed={d} owner deliveries={d} tracked={d}\n",
        .{ slices, routed, recorder.count, notification_service.tracked.count() },
    );
    if (notification_service.tracked.contains(id)) {
        try report.emit(
            "notification: the daemon never ended id={d} within {d} ms\n",
            .{ id, options.wait_ms },
        );
        return error.DaemonNeverEndedTheToast;
    }
    if (recorder.count != 0) return error.RetiredOwnerReceivedADelivery;
    try report.emit(
        "notification: the daemon ended id={d} and the retired owner heard nothing\n",
        .{id},
    );

    recorder.origin = .shutdown;
    notification_service.shutdown();
    try report.emit(
        "notification: shutdown completed; tracked now={d}\n",
        .{notification_service.tracked.count()},
    );
    try recorder.emit(report);
    try report.emit(
        "notification: verdict: owner loss delivered no answer to a released owner\n",
        .{},
    );
}

/// Provider loss. One real toast is posted and tracked, and after that nothing
/// in this run touches the provider: the run says it is waiting for the
/// transport to go away and pumps for it. Only the real poll can end that
/// wait, so the completion reported here is the one the provider's own lost
/// transport produced rather than one this run announced. Every live owner
/// must hear `provider_lost` exactly once, and a service that has lost its
/// provider must refuse more work rather than post a toast nobody can answer.
fn runProviderLossScenario(
    io: Io,
    report: *Reporter,
    options: Options,
    notification_service: *notifications.NotificationsService,
    capabilities: notifications.Capabilities,
    token: []const u8,
) !void {
    var summary_first: [128]u8 = undefined;
    var body_first: [192]u8 = undefined;
    const first_summary = try std.fmt.bufPrint(&summary_first, "w19 smoke {s}", .{token});
    const first_body = try std.fmt.bufPrint(
        &body_first,
        "Synthetic notification {s} whose provider this run loses before the daemon answers.",
        .{token},
    );

    var recorder: Recorder = .{};
    defer notification_service.shutdown();
    const owner = Recorder.bind(&recorder);
    const handler: notifications.ActionHandler = .{
        .context = &recorder,
        .callback = Recorder.onResponse,
    };

    const submitted = notification_service.submit(.{
        .summary = first_summary,
        .body = first_body,
        .app_name = app_name,
        .category = category,
        // No daemon expiry may end this toast: the only thing allowed to end
        // it is the transport going away, so it carries no expiry of its own.
        .timeout_ms = 0,
        .actions = if (capabilities.actions) action_set[0..] else no_actions[0..],
    }, owner, handler);
    try emitSubmit(report, "provider-loss submit", submitted);
    const id = switch (submitted) {
        .accepted => |value| value,
        else => return error.SubmitWasNotAccepted,
    };
    try report.emit(
        "notification: provider-loss tracked={d} before the provider goes away\n",
        .{notification_service.tracked.count()},
    );

    // The arm. Nothing below this line tells the service anything: the run
    // says it is waiting for a provider to go away and then only pumps, so
    // whatever ends this toast came from the transport itself.
    recorder.origin = .pump;
    try report.emit(
        "notification: provider-loss armed; id={d} is tracked={} and this run now waits" ++
            " for its transport to go away on its own\n",
        .{ id, notification_service.tracked.contains(id) },
    );
    const deadline = nowNs(io) + @as(i96, options.wait_ms) * std.time.ns_per_ms;
    var slices: usize = 0;
    var routed: usize = 0;
    while (notification_service.tracked.contains(id)) {
        const now = nowNs(io);
        if (now >= deadline) break;
        const remaining_ms: i64 = @intCast(@divTrunc(deadline - now, std.time.ns_per_ms));
        const slice: i32 = @intCast(@max(@min(remaining_ms, pump_slice_ms), 1));
        slices += 1;
        routed += notification_service.pump(slice) catch |err| {
            try report.emit("notification: pump failed, error={s}\n", .{@errorName(err)});
            return error.PumpFailed;
        };
    }
    try report.emit(
        "notification: provider-loss pump slices={d} routed={d} tracked={d} owner deliveries={d}\n",
        .{ slices, routed, notification_service.tracked.count(), recorder.count },
    );
    // A transport that was still there lost nothing, and a run that reports a
    // loss anyway is the failure this case exists to catch.
    if (notification_service.tracked.contains(id)) {
        try report.emit(
            "notification: the transport was still there after {d} ms, so no provider was lost\n",
            .{options.wait_ms},
        );
        return error.ProviderLossTransportStayed;
    }
    recorder.origin = .shutdown;
    if (notification_service.tracked.count() != 0) return error.ProviderLossLeftTracking;
    if (recorder.count != 1) return error.ProviderLossDidNotCompleteTheOwner;
    const delivery = recorder.deliveries[0];
    // The completion has to have arrived in a pump, from the transport's own
    // loss, and not from anything this run called directly.
    if (delivery.origin != .pump) return error.ProviderLossWasNotDeliveredByThePump;
    if (delivery.kind != .provider_lost or delivery.id != id) {
        return error.ProviderLossReportedTheWrongAnswer;
    }
    try report.emit(
        "notification: the transport went away during the pump, so the provider retired itself" ++
            " and completed the one live owner\n",
        .{},
    );

    // A service with no provider accepts nothing, so this cannot become a toast
    // the daemon shows and nobody ever hears about.
    const refused = notification_service.submit(.{
        .summary = first_summary,
        .body = first_body,
        .app_name = app_name,
        .category = category,
    }, owner, handler);
    try report.emit("notification: submit after the provider went away={s}\n", .{submitTag(refused)});
    // A union whose accepted case carries a value cannot be compared to a bare
    // tag, so the one outcome that would leak a toast is named as a case.
    switch (refused) {
        .accepted => return error.SubmitAfterProviderLossWasAccepted,
        else => {},
    }

    try recorder.emit(report);
    try report.emit(
        "notification: verdict: the provider really went away and one live owner heard once\n",
        .{},
    );
}

/// The credential arm's dispatcher. The round trip is the default condition;
/// the three others each name one typed result the real store has to produce,
/// and each of the two refusals is checked against what the store holds after
/// the call rather than after the word it answered with.
fn runCredentialArm(
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    options: Options,
    nonce: []const u8,
) !void {
    try report.emit("credential: case={s}\n", .{@tagName(options.credential_case orelse .round_trip)});
    switch (options.credential_case orelse .round_trip) {
        .round_trip => try runRoundTripArm(gpa, io, report, options, nonce),
        .locked, .denied, .disconnected => |condition| try runCredentialConditionArm(
            gpa,
            io,
            report,
            options,
            nonce,
            condition,
        ),
    }
}

/// What one read said about the bytes now in the namespace, with the value
/// released before this returns so no caller has to remember to. `ours` is
/// what separates a refusal that really stored nothing from one that stored
/// something anyway, and `locked` is the store naming the item locked on the
/// very path that read went through. `dismissed` is the store finding a locked
/// item and asking a person to unlock it: the item was there and was still not
/// read, which is a different answer from `empty`, the read that produced no
/// item at all and so cannot tell an empty namespace from a collection it could
/// not see. Neither of those two reached the bytes, and only the case whose own
/// proof is an absence after a refusal may read `empty` as one.
const ReadWitness = union(enum) {
    empty,
    ours,
    other: usize,
    locked,
    dismissed,
    refused: []const u8,
};

/// One read, reported and classified, with its bytes compared against the ones
/// this run would have written and then wiped. The comparison happens before
/// the value is released, because a refusal is only proved by what the store
/// holds afterwards and not by what it said at the time.
fn witnessRead(
    report: *Reporter,
    label: []const u8,
    result: credentials.ReadResult,
    secret: []const u8,
) !ReadWitness {
    var owned = result;
    defer if (owned == .found) owned.found.deinit();
    switch (owned) {
        .found => {
            try report.emit(
                "credential: {s} outcome=found bytes={d}\n",
                .{ label, owned.found.secret.len },
            );
            if (std.mem.eql(u8, owned.found.secret, secret)) return .ours;
            return .{ .other = owned.found.secret.len };
        },
        .provider_failed => |failure| {
            try report.emit(
                "credential: {s} outcome=provider_failed failure={s}\n",
                .{ label, credentialProviderErrorTag(failure) },
            );
            return .{ .refused = "provider_failed" };
        },
        else => {
            const tag = readTag(owned);
            try report.emit("credential: {s} outcome={s}\n", .{ label, tag });
            // The tag is a name this run prints. The classification comes from
            // the outcome itself, so no read result is filed by how its name
            // happens to read.
            return switch (owned) {
                .not_found => .empty,
                .locked => .locked,
                .prompt_dismissed => .dismissed,
                else => .{ .refused = tag },
            };
        },
    }
}

/// One refusal condition against the real store: a locked collection, a store
/// that denied the request, and a provider whose connection is gone.
///
/// Both refusal conditions are proved the same way round: the native call that
/// has to be refused is made first, and the namespace is read back afterwards.
/// A refusal is only real when the store holds nothing this run wrote, so an
/// entry the store accepted anyway is removed before the disagreement is
/// reported, and a refusal that left bytes behind is reported as exactly that.
fn runCredentialConditionArm(
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    options: Options,
    nonce: []const u8,
    condition: CredentialCase,
) !void {
    // The namespace reached this far is already this run's own, exactly as in
    // the round trip above.
    try requireCredentialAuthorization(options);
    const service_name = options.service.?;
    const account_name = options.account.?;

    try report.emit("credential: authorized scope\n  {s}\n", .{credential_scope_text});
    try report.emit(
        "credential: namespace service=\"{s}\" account=\"{s}\" nonce=\"{s}\" collection={s}\n",
        .{
            service_name,
            account_name,
            nonce,
            options.collection orelse collection_prefix ++ "aliases/default",
        },
    );
    try report.emit("credential: condition={s} wait budget {d} ms per call\n", .{
        @tagName(condition),
        options.wait_ms,
    });

    var token_buffer: [48]u8 = undefined;
    const token = try uniqueToken(io, &token_buffer);
    try report.emit("credential: run token {s}\n", .{token});

    var secret_buffer: [192]u8 = undefined;
    const secret = try std.fmt.bufPrint(
        &secret_buffer,
        "w19-smoke-synthetic-secret:{s}:this-is-not-a-real-credential\n",
        .{token},
    );
    defer std.crypto.secureZero(u8, secret_buffer[0..]);
    try report.emit(
        "credential: payload is {d} synthetic bytes made by this run; its text is never printed\n",
        .{secret.len},
    );

    var secret_provider = secret_service.SecretServiceCredentialProvider.init(gpa);
    var credential_service = credentials.CredentialsService.init(gpa, secret_provider.provider());
    defer credential_service.deinit();

    const call = try gpa.create(Call);
    defer gpa.destroy(call);
    call.* = .{
        .gpa = gpa,
        .service = &credential_service,
        .secret = secret,
        .query = .{
            .service = service_name,
            .account = account_name,
            .collection = options.collection,
        },
    };

    switch (condition) {
        .round_trip => unreachable,
        .locked => {
            // A locked collection refuses Secret.Collection.CreateItem, and that
            // refusal is the one part of this case no store can answer with a
            // prompt, so the write goes first and the read follows it.
            try report.emit(
                "credential: locked case: the write goes first, because a locked collection refuses\n" ++
                    "            Secret.Collection.CreateItem and asks for nothing in return\n",
                .{},
            );
            const write = try awaitWrite(io, call, options.wait_ms, "locked write", report);
            switch (write) {
                // The typed result is reported first in every arm, including the
                // one that agrees with the case: a refusal nobody can name is a
                // refusal nobody downstream can read either.
                .locked => {
                    try emitWrite(report, "locked write", write);
                    try report.emit(
                        "credential: the store refused the write with org.freedesktop.Secret.Error.IsLocked\n",
                        .{},
                    );
                },
                .success => {
                    try emitWrite(report, "locked write", write);
                    // The store took the bytes the refusal was supposed to stop,
                    // so it really holds this run's entry now. They go before the
                    // disagreement is reported, and the removal is reported.
                    cleanupEntry(io, call, options.wait_ms, report);
                    return error.LockWasNotObserved;
                },
                else => {
                    try emitWrite(report, "locked write", write);
                    return error.LockWasNotObserved;
                },
            }
            // The read is the one place a locked item is really touched:
            // SearchItems has to find it and Secret.Service.Unlock has to answer.
            // Reaching the bytes has a precondition this run cannot meet on its
            // own: a store that unlocks without a person, or a person at the
            // keyboard. This run answers no prompt of its own, so a store that
            // raises one has it answered for it and the read reports
            // prompt_dismissed, and a daemon that raises a prompt and never
            // answers it ends this call at its budget instead.
            try report.emit(
                "credential: the read of the same namespace follows; reaching the bytes needs a store\n" ++
                    "            that unlocks without a person, or a person at the keyboard, and no prompt\n" ++
                    "            is answered here, so a store that raises one has it answered for it and\n" ++
                    "            reports prompt_dismissed\n",
                .{},
            );
            const read = try awaitRead(io, call, options.wait_ms, "locked read", report);
            const witness = try witnessRead(report, "locked read", read, secret);
            switch (witness) {
                // A store with no person to ask finds the locked item, needs a real
                // Unlock for it and raises a real prompt. No person is here, so
                // the daemon answers its own prompt as dismissed and the provider
                // maps that to prompt_dismissed. The item was found and stayed
                // locked, which is what tells this apart from the case below
                // where no item was produced at all, and no bytes were read.
                .dismissed => {
                    try report.emit(
                        "credential: the store found the item, needed a real Unlock for it and raised a\n" ++
                            "            prompt; no person was there to answer, so the daemon answered its\n" ++
                            "            prompt as dismissed. The item is locked and was not read: this is not\n" ++
                            "            a successful locked read and not a missing password, and a headless run\n" ++
                            "            cannot reach the path that would have read it\n",
                        .{},
                    );
                    return error.LockedReadNeededAPerson;
                },
                // A locked collection that produced no item cannot tell an empty
                // namespace from a collection this read could not see at all, and
                // only the first of those says the refused write stored nothing.
                // Nothing is claimed from it either way: the real IsLocked refusal
                // the write produced is already reported, the case fails rather
                // than resting on an absence this read cannot explain, and the
                // absence is never read as a password that has gone missing.
                .empty => {
                    try report.emit(
                        "credential: the locked collection produced no item, so the read had nothing to\n" ++
                            "            unlock and cannot tell an empty namespace from a collection it could not\n" ++
                            "            see; it is not a locked read that asked a person and not a missing\n" ++
                            "            password, and it is not the proof that the refused write stored nothing;\n" ++
                            "            the refusal above stands on its own\n",
                        .{},
                    );
                    return error.LockedReadProducedNoItem;
                },
                .other => |bytes| try report.emit(
                    "credential: the namespace holds {d} bytes this run did not write, so the refused write" ++
                        " stored nothing\n",
                    .{bytes},
                ),
                .locked => try report.emit(
                    "credential: the store named the item locked on the read path as well\n",
                    .{},
                ),
                .ours => {
                    // The namespace holds exactly the bytes this run would have
                    // written, so the refusal is not what the store did and the
                    // entry is this run's own to remove.
                    cleanupEntry(io, call, options.wait_ms, report);
                    return error.LockWasNotObserved;
                },
                .refused => |tag| {
                    try report.emit(
                        "credential: the read of a locked namespace came back {s}, which is neither the\n" ++
                            "            locked item nor the prompt a locked item raises, so this read says\n" ++
                            "            nothing about the lock\n",
                        .{tag},
                    );
                    return error.LockedReadCameBackWrongAnswer;
                },
            }
            try report.emit(
                "credential: locked: a real write against a really locked collection was refused with\n" ++
                    "            org.freedesktop.Secret.Error.IsLocked, " ++
                    "and nothing this run wrote is in the namespace\n",
                .{},
            );
        },
        .denied => {
            try report.emit(
                "credential: denied case: the write goes first, and the refusal only counts when the\n" ++
                    "            namespace is empty after it\n",
                .{},
            );
            const write = try awaitWrite(io, call, options.wait_ms, "denied write", report);
            switch (write) {
                // The typed result is reported before the prose about it here
                // too, so the denial the consumer actually read is a line of its
                // own and not only a sentence in the middle of the run.
                .denied => {
                    try emitWrite(report, "denied write", write);
                    try report.emit(
                        "credential: the store refused the write, and the provider read that refusal as a denial\n" ++
                            "            from an error name carrying AccessDenied\n",
                        .{},
                    );
                },
                .success => {
                    try emitWrite(report, "denied write", write);
                    // The store allowed what a denial was expected to refuse,
                    // so it really holds these bytes now. They go before the run
                    // reports the disagreement, and the removal is reported.
                    cleanupEntry(io, call, options.wait_ms, report);
                    return error.DenialWasNotObserved;
                },
                else => {
                    try emitWrite(report, "denied write", write);
                    return error.DenialWasNotObserved;
                },
            }
            const read = try awaitRead(io, call, options.wait_ms, "absence after the denied write", report);
            const witness = try witnessRead(report, "absence after the denied write", read, secret);
            switch (witness) {
                .empty => try report.emit(
                    "credential: nothing was stored, so no entry of this run is left behind\n",
                    .{},
                ),
                .ours => {
                    // The namespace holds exactly the bytes the refusal was
                    // supposed to stop, so the entry is this run's own to remove.
                    cleanupEntry(io, call, options.wait_ms, report);
                    return error.DenialWasNotObserved;
                },
                .other => |bytes| {
                    try report.emit(
                        "credential: the namespace holds {d} bytes after a refused write, which this run" ++
                            " did not write and did not remove\n",
                        .{bytes},
                    );
                    return error.DeniedWriteLeftSomethingBehind;
                },
                .locked => {
                    try report.emit(
                        "credential: the namespace came back locked after a write that was refused as denied," ++
                            " so the two answers do not describe one store\n",
                        .{},
                    );
                    return error.DeniedWriteLeftSomethingBehind;
                },
                .dismissed => {
                    // A store that needs a person to read the namespace cannot
                    // show that it is empty, so the denial is reported without
                    // the proof that nothing was stored, exactly as it is for
                    // every other answer that is not the bytes themselves.
                    try report.emit(
                        "credential: reading the namespace back needed a person, so the denial is reported\n" ++
                            "            without the proof that nothing was stored\n",
                        .{},
                    );
                    return error.DenialWasNotObserved;
                },
                .refused => |tag| {
                    try report.emit(
                        "credential: the namespace could not be read back after the denial ({s}), so the" ++
                            " refusal is reported without the proof that nothing was stored\n",
                        .{tag},
                    );
                    return error.DenialWasNotObserved;
                },
            }
            try report.emit(
                "credential: denied: a real write was refused with a denial this provider maps to .denied,\n" ++
                    "            and the same store then held nothing this run wrote\n",
                .{},
            );
        },
        .disconnected => {
            // The first call really opens the provider's bus connection, so
            // what follows is a connection that was lost and not one that was
            // never made.
            const before = try awaitRead(io, call, options.wait_ms, "connect read", report);
            try emitRead(report, "connect read", before);
            try report.emit(
                "credential: the provider is connected and answered; this run now drops its own bus" ++
                    " connection, which is not a daemon crash and not a store answer\n",
                .{},
            );
            credential_service.shutdown();
            const after = try awaitRead(io, call, options.wait_ms, "read after the provider went away", report);
            switch (after) {
                .provider_failed => |failure| {
                    try report.emit(
                        "credential: after the provider went away outcome=provider_failed failure={s}\n",
                        .{@tagName(failure)},
                    );
                    if (failure != .disconnected) return error.DisconnectWasNotTheReportedFailure;
                },
                else => {
                    try emitRead(report, "read after the provider went away", after);
                    return error.DisconnectWasNotObserved;
                },
            }
        },
    }
    try report.emit("credential: verdict case={s} observed against the real store\n", .{@tagName(condition)});
}

/// The round trip, behind its authorization. It writes bytes it made up,
/// proves they are its own, and removes exactly what it created.
fn runRoundTripArm(
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    options: Options,
    nonce: []const u8,
) !void {
    // The namespace reached this far is already this run's own: `main` checked
    // the exact service, the exact account form and the collection scope
    // before it built a provider, so there is no real account left to search.
    try requireCredentialAuthorization(options);
    const service_name = options.service.?;
    const account_name = options.account.?;

    try report.emit("credential: authorized scope\n  {s}\n", .{credential_scope_text});
    try report.emit(
        "credential: namespace service=\"{s}\" account=\"{s}\" nonce=\"{s}\" collection={s}\n",
        .{
            service_name,
            account_name,
            nonce,
            options.collection orelse collection_prefix ++ "aliases/default",
        },
    );
    try report.emit("credential: wait budget {d} ms per call\n", .{options.wait_ms});

    var token_buffer: [48]u8 = undefined;
    const token = try uniqueToken(io, &token_buffer);
    try report.emit("credential: run token {s}\n", .{token});

    // The bytes this run writes are the only bytes it can write. They are
    // synthetic, they are known to this run, and they are wiped before the
    // buffer dies.
    var secret_buffer: [192]u8 = undefined;
    const secret = try std.fmt.bufPrint(
        &secret_buffer,
        "w19-smoke-synthetic-secret:{s}:this-is-not-a-real-credential\n",
        .{token},
    );
    defer std.crypto.secureZero(u8, secret_buffer[0..]);
    try report.emit(
        "credential: payload is {d} synthetic bytes made by this run; its text is never printed\n",
        .{secret.len},
    );

    var secret_provider = secret_service.SecretServiceCredentialProvider.init(gpa);
    var credential_service = credentials.CredentialsService.init(gpa, secret_provider.provider());
    // The service owns the provider from here, so nothing else may hold a
    // reference to it. The deadline abort is the one path that ends this
    // process without unwinding, and it never reaches this defer.
    defer credential_service.deinit();

    const call = try gpa.create(Call);
    // A worker that overruns its deadline is never killed, so this record is
    // deliberately leaked on that path instead of released under the worker.
    // That path cannot reach this defer: `awaitRead`, `awaitWrite` and
    // `awaitDelete` end the process the moment a budget runs out, so the only
    // way a worker is still inside the provider here is a call that answered.
    defer gpa.destroy(call);
    call.* = .{
        .gpa = gpa,
        .service = &credential_service,
        .secret = secret,
        .query = .{
            .service = service_name,
            .account = account_name,
            .collection = options.collection,
        },
    };

    // The daemon replaces an item with the same attributes, so an existing
    // entry has to be refused before anything is written. The search covers
    // every collection, which is wider than this run writes.
    try report.emit("credential: checking the namespace before writing\n", .{});
    const before = try awaitRead(io, call, options.wait_ms, "existence read", report);
    switch (before) {
        .found => |existing| {
            var untouched = existing;
            untouched.deinit();
            try report.emit(
                "credential: refused, the smoke namespace already holds an entry; it is neither" ++
                    " replaced nor deleted, so pick a new nonce\n",
                .{},
            );
            return error.NamespaceAlreadyOccupied;
        },
        .not_found => try report.emit(
            "credential: the namespace is empty, this run may create it\n",
            .{},
        ),
        else => {
            try emitRead(report, "existence read", before);
            return error.ExistenceReadDidNotResolve;
        },
    }

    var created = false;
    // Whatever goes wrong after this line, the entry this run created is
    // removed and the removal is reported.
    errdefer if (created) cleanupEntry(io, call, options.wait_ms, report);

    const written = try awaitWrite(io, call, options.wait_ms, "write", report);
    switch (written) {
        .success => {
            created = true;
            try report.emit("credential: the daemon stored the {d} synthetic bytes\n", .{secret.len});
        },
        else => {
            try emitWrite(report, "write", written);
            return error.WriteDidNotSucceed;
        },
    }

    const read_back = try awaitRead(io, call, options.wait_ms, "read back", report);
    switch (read_back) {
        .found => |value| {
            var owned = value;
            defer owned.deinit();
            const matches = std.mem.eql(u8, owned.secret, secret);
            try report.emit(
                "credential: read back {d} bytes, equals what this run wrote={}\n",
                .{ owned.secret.len, matches },
            );
            if (!matches) return error.ReadBackDidNotMatch;
        },
        else => {
            try emitRead(report, "read back", read_back);
            return error.ReadBackDidNotResolve;
        },
    }

    const removed = try awaitDelete(io, call, options.wait_ms, "delete", report);
    switch (removed) {
        .success => {
            created = false;
            try report.emit("credential: the daemon deleted the entry this run created\n", .{});
        },
        else => {
            try emitDelete(report, "delete", removed);
            return error.DeleteDidNotSucceed;
        },
    }

    // Ownership check through the same real service: the namespace is empty
    // again, so nothing of this run is left behind.
    const after = try awaitRead(io, call, options.wait_ms, "absence read", report);
    switch (after) {
        .not_found => try report.emit(
            "credential: the namespace is empty again, so this run owns nothing\n",
            .{},
        ),
        else => {
            try emitRead(report, "absence read", after);
            return error.EntrySurvivedTheDelete;
        },
    }
    try report.emit("credential: verdict written, read back, deleted, absent\n", .{});
}

/// Remove what this run created on the error path and say what became of it.
/// The caller is already failing, so a failure here is reported rather than
/// returned.
fn cleanupEntry(io: Io, call: *Call, deadline_ms: u64, report: *Reporter) void {
    const removed = awaitDelete(io, call, deadline_ms, "cleanup delete", report) catch |err| {
        report.emit("credential: cleanup could not start; removal is unconfirmed, error={s}\n", .{
            @errorName(err),
        }) catch @panic("W19 service smoke could not report a cleanup failure");
        return;
    };
    emitDelete(report, "cleanup delete", removed) catch
        @panic("W19 service smoke could not report the cleanup delete");
    switch (removed) {
        .success, .not_found => {},
        else => report.emit("credential: cleanup did not confirm removal of this run's entry\n", .{}) catch
            @panic("W19 service smoke could not report an unconfirmed removal"),
    }
}

/// The one notify condition this run was asked to prove, named exactly. An
/// unknown name is refused here, before a provider exists.
fn parseNotifyCase(text: []const u8) !NotifyCase {
    if (std.mem.eql(u8, text, "scenario")) return .scenario;
    if (std.mem.eql(u8, text, "owner-lost")) return .owner_lost;
    if (std.mem.eql(u8, text, "provider-disconnect")) return .provider_disconnect;
    std.log.err(
        "{s} must be exactly scenario, owner-lost or provider-disconnect",
        .{notify_case_flag},
    );
    return error.UnknownScenarioCase;
}

/// The one credential condition this run was asked to prove, named exactly.
fn parseCredentialCase(text: []const u8) !CredentialCase {
    if (std.mem.eql(u8, text, "round-trip")) return .round_trip;
    if (std.mem.eql(u8, text, "locked")) return .locked;
    if (std.mem.eql(u8, text, "denied")) return .denied;
    if (std.mem.eql(u8, text, "disconnected")) return .disconnected;
    std.log.err(
        "{s} must be exactly round-trip, locked, denied or disconnected",
        .{credential_case_flag},
    );
    return error.UnknownScenarioCase;
}

fn parseArgs(gpa: std.mem.Allocator, init: std.process.Init) !Options {
    var options: Options = .{};
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    var saw_command = false;
    while (args.next()) |arg| {
        if (!saw_command and !std.mem.startsWith(u8, arg, "--")) {
            options.command = std.meta.stringToEnum(Command, arg) orelse {
                std.log.err("unknown command: {s}", .{arg});
                return error.UnknownCommand;
            };
            saw_command = true;
        } else if (std.mem.eql(u8, arg, authorize_notification_flag)) {
            options.authorize_notification = true;
        } else if (std.mem.eql(u8, arg, notification_scope_flag)) {
            options.notification_scope = args.next() orelse return error.MissingAuthorizationScope;
        } else if (std.mem.eql(u8, arg, authorize_credential_flag)) {
            options.authorize_credential = true;
        } else if (std.mem.eql(u8, arg, credential_scope_flag)) {
            options.credential_scope = args.next() orelse return error.MissingAuthorizationScope;
        } else if (std.mem.eql(u8, arg, service_flag)) {
            options.service = args.next() orelse return error.MissingServiceNamespace;
        } else if (std.mem.eql(u8, arg, account_flag)) {
            options.account = args.next() orelse return error.MissingAccountNamespace;
        } else if (std.mem.eql(u8, arg, collection_flag)) {
            options.collection = args.next() orelse return error.MissingCollectionPath;
        } else if (std.mem.eql(u8, arg, wait_flag)) {
            const value = args.next() orelse return error.MissingWaitMs;
            options.wait_ms = std.fmt.parseInt(u64, value, 10) catch return error.BadWaitMs;
            options.wait_ms = @max(min_wait_ms, @min(max_wait_ms, options.wait_ms));
        } else if (std.mem.eql(u8, arg, expiry_flag)) {
            const value = args.next() orelse return error.MissingExpiryMs;
            options.expiry_ms = std.fmt.parseInt(i32, value, 10) catch return error.BadExpiryMs;
            options.expiry_ms = @max(min_expiry_ms, @min(max_expiry_ms, options.expiry_ms));
        } else if (std.mem.eql(u8, arg, notify_case_flag)) {
            options.notify_case = try parseNotifyCase(args.next() orelse return error.MissingScenarioCase);
        } else if (std.mem.eql(u8, arg, credential_case_flag)) {
            options.credential_case = try parseCredentialCase(args.next() orelse return error.MissingScenarioCase);
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }
    return options;
}

/// An authorization flag is not an approval on its own, so a flag that names an
/// arm nobody asked for is refused rather than ignored.
fn checkFlagPlacement(options: Options) !void {
    if (options.authorize_notification and options.command != .notify) {
        std.log.err("{s} belongs to the notify command only", .{authorize_notification_flag});
        return error.AuthorizationFlagWithoutItsCommand;
    }
    if (options.authorize_credential and options.command != .credential) {
        std.log.err("{s} belongs to the credential command only", .{authorize_credential_flag});
        return error.AuthorizationFlagWithoutItsCommand;
    }
    if (options.command != .credential and (options.service != null or
        options.account != null or options.collection != null))
    {
        std.log.err("{s}, {s} and {s} belong to the credential command only", .{
            service_flag,
            account_flag,
            collection_flag,
        });
        return error.NamespaceFlagWithoutItsCommand;
    }
    if (options.command != .notify and options.notification_scope != null) {
        std.log.err("{s} belongs to the notify command only", .{notification_scope_flag});
        return error.AuthorizationFlagWithoutItsCommand;
    }
    if (options.command != .credential and options.credential_scope != null) {
        std.log.err("{s} belongs to the credential command only", .{credential_scope_flag});
        return error.AuthorizationFlagWithoutItsCommand;
    }
    if (options.command != .notify and options.notify_case != null) {
        std.log.err("{s} belongs to the notify command only", .{notify_case_flag});
        return error.ScenarioFlagWithoutItsCommand;
    }
    if (options.command != .credential and options.credential_case != null) {
        std.log.err("{s} belongs to the credential command only", .{credential_case_flag});
        return error.ScenarioFlagWithoutItsCommand;
    }
    // A condition is not an approval. Naming the case an operator never
    // authorized would arm nothing here, so the two are refused together rather
    // than the case quietly falling back to the default round trip.
    if (options.notify_case != null and !options.authorize_notification) {
        std.log.err("{s} needs {s} beside it", .{ notify_case_flag, authorize_notification_flag });
        return error.ScenarioCaseWithoutAuthorization;
    }
    if (options.credential_case != null and !options.authorize_credential) {
        std.log.err("{s} needs {s} beside it", .{ credential_case_flag, authorize_credential_flag });
        return error.ScenarioCaseWithoutAuthorization;
    }
}

/// The notify arm's two budgets have to be coherent, or the run fails by
/// construction instead of by observation.
///
/// The only delivery this run can observe is the daemon's own expiry of the
/// first toast, which lands at `expiry_ms`, and the pump that routes it stops
/// at a deadline built from `wait_ms`. An expiry at or past that deadline is a
/// budget no wait can reach: the run posts two toasts, spins the whole wait,
/// dismisses both of them and then reports that nothing answered, which is a
/// fact about the command line rather than about the daemon. That pair is
/// refused here, beside the other refusals, so no provider exists and nothing
/// reaches a screen. The wait has to clear the expiry by two whole pump slices,
/// because a daemon answers at or a little after the timeout it was given.
///
/// The refusal itself is typed and this says nothing: the reason belongs to the
/// caller that owns a terminal, so `main` reports it and the headless contract
/// tests can drive this without a run writing to their output.
fn checkNotificationBudget(options: Options) !void {
    if (options.command != .notify) return;
    // Signed on both sides, so a budget this check has not seen before is
    // judged by its slack rather than by a cast that could trap.
    const slack_ms: i64 = @as(i64, @intCast(options.wait_ms)) - @as(i64, options.expiry_ms);
    if (slack_ms >= min_pump_slack_ms) return;
    return error.NotificationWaitCannotObserveTheExpiry;
}

/// The nonce of an account of the exact form `w19-smoke-<nonce>`: 8 to 32
/// characters of a-z and 0-9. Anything else is refused here, which is the last
/// point before a provider exists and therefore before any store is searched.
fn parseNonce(account: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, account, account_prefix)) return error.AccountIsNotSynthetic;
    const nonce = account[account_prefix.len..];
    if (nonce.len < min_nonce_len or nonce.len > max_nonce_len) {
        return error.AccountNonceHasBadLength;
    }
    for (nonce) |byte| {
        const digit = byte >= '0' and byte <= '9';
        const lower = byte >= 'a' and byte <= 'z';
        if (!digit and !lower) return error.AccountNonceIsNotLowerAlnum;
    }
    return nonce;
}

/// The namespace refusal boundary. The credential arm runs one namespace shape
/// and nothing else: the fixed smoke service, an account that is this run's own
/// prefix plus a nonce, and a collection that names that same account. A real
/// service or account never reaches a provider, so no existing credential is
/// even searched for. Returns the nonce the arm reports, and null for every
/// other command.
fn checkNamespaceForm(options: Options) !?[]const u8 {
    if (options.command != .credential) return null;
    const service = options.service orelse return error.MissingServiceNamespace;
    if (!std.mem.eql(u8, service, smoke_service)) {
        std.log.err("{s} must be exactly \"{s}\"", .{ service_flag, smoke_service });
        return error.ServiceIsNotTheSmokeService;
    }
    const account = options.account orelse return error.MissingAccountNamespace;
    const nonce = parseNonce(account) catch |err| {
        std.log.err(
            "{s} must be \"{s}<nonce>\" with a nonce of {d}-{d} characters of a-z and 0-9 that is never reused",
            .{ account_flag, account_prefix, min_nonce_len, max_nonce_len },
        );
        return err;
    };
    if (options.collection) |collection| {
        if (!std.mem.startsWith(u8, collection, collection_prefix) or
            std.mem.indexOf(u8, collection, account) == null)
        {
            std.log.err(
                "{s} must be a path under \"{s}\" that contains the account \"{s}\"",
                .{ collection_flag, collection_prefix, account },
            );
            return error.CollectionIsNotScopedToThisRun;
        }
    }
    return nonce;
}

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    const options = try parseArgs(gpa, init);
    try checkFlagPlacement(options);
    // The notify budget is checked here for the same reason the namespace is:
    // an incoherent pair is refused before a provider is built and before
    // anything can reach a screen, not after a run that could not have worked.
    checkNotificationBudget(options) catch |err| {
        std.log.err(
            "{s} must exceed {s} by at least {d} ms; received wait={d} ms, expiry={d} ms",
            .{ wait_flag, expiry_flag, min_pump_slack_ms, options.wait_ms, options.expiry_ms },
        );
        return err;
    };
    // The namespace is checked here, before any provider is built and before
    // the arm runs, so a command line naming a real account is refused here.
    const nonce = try checkNamespaceForm(options);

    var report: Reporter = .{ .io = io };
    try report.emit("W19 notification and secure-credential service smoke\n", .{});
    try report.emit("mode: {s}\n", .{@tagName(options.command)});
    switch (options.command) {
        .capability => try runCapabilityReport(gpa, &report),
        .notify => try runNotificationArm(gpa, io, &report, options),
        .credential => try runCredentialArm(gpa, io, &report, options, nonce orelse
            return error.MissingAccountNamespace),
        .help => try printUsage(&report),
    }
    try report.emit("W19 service smoke done\n", .{});
}

// ── Headless regressions ──
// Nothing below reaches a bus, a keyring, a screen or a prompt. The
// credential half drives the real service, the real provider vtable and a real
// worker thread against an in-memory store; the notification half drives the
// arm's own scenario against a provider that expires toasts the way a daemon
// does. Neither is a way to reach an arm: the authorization gate and the bus
// stay above this line.

/// The account the headless credential tests use. It is the synthetic shape
/// the arm insists on and it exists only inside the in-memory store.
const headless_account: []const u8 = "w19-smoke-headless01";
/// The payload the headless tests hand in. Only a read that found bytes ever
/// compares against it, so it exists to be compared and never to be printed.
const headless_secret: []const u8 = "w19-smoke-synthetic-secret";
/// The budget a call with no answer at all is given. A parked provider holds
/// its worker for the whole of the wait, so the budget is the only thing that
/// can end a wait on a parked call.
const headless_deadline_ms: u64 = 50;
/// How long the backstop waits before it opens the latch itself. It exists so
/// a wait that ignored its budget is a failure instead of a hang, and it is two
/// hundred budgets long, so a machine under load cannot be the reason a parked
/// call comes back early. The drain opens the latch before it joins the
/// backstop, so a correct wait never pays any of it.
const headless_backstop_ms: i64 = 10_000;
/// One slice of the backstop's own wait, and so the most the drain can be made
/// to wait for the backstop to notice that the latch is already open.
const backstop_slice_ms: i64 = 20;
/// The bound on waiting a drained worker out. A worker parked in the mock is
/// one step from the end of its own provider, so this covers the provider
/// finishing and the worker storing its result, not the budget above.
const headless_drain_bound_ms: u64 = 5_000;

/// The in-memory credential store the headless tests drive: the real service
/// over the real provider vtable, plus the record a worker fills.
///
/// The mock owns its store, the service owns the mock and the record names the
/// service, so all three die together and none of them may die under a worker.
/// A worker that missed its budget is still inside the provider when the wait
/// returns false, and it stores its result in the record afterwards, so this
/// owner is what keeps a reported timeout from becoming a use-after-free: the
/// drain opens the latch the worker is parked on and joins it, and only then
/// does `deinit` retire the record and the service. The arm needs no such dance
/// because it ends the process instead of returning to its own code.
const HeadlessStore = struct {
    io: Io,
    report: *Reporter,
    mock: credentials.MockCredentialProvider,
    service: credentials.CredentialsService,
    call: Call,
    /// The mock holds a call here until the latch opens, which is what makes a
    /// call with no answer for the wait to end on.
    latch: credentials.MockCredentialProvider.Gate = .{},
    backstop: ?std.Thread = null,

    /// The provider and the record both point at storage inside this owner, so
    /// they are taken after `self` has its final address and neither is left
    /// naming a frame that a return value would move.
    fn init(self: *HeadlessStore, gpa: std.mem.Allocator, io: Io, report: *Reporter) void {
        self.* = .{
            .io = io,
            .report = report,
            .mock = credentials.MockCredentialProvider.init(gpa),
            // SAFETY: the service is the very next statement and the mock it
            // names is already in place, so nothing reads this storage first.
            .service = undefined,
            // SAFETY: the record is written after the service it points at, so
            // nothing reads this storage before that write.
            .call = undefined,
        };
        self.service = credentials.CredentialsService.init(gpa, self.mock.provider());
        self.call = .{
            .gpa = gpa,
            .service = &self.service,
            .secret = headless_secret,
            .query = .{ .service = smoke_service, .account = headless_account },
        };
    }

    /// Retire the record, then the service, then the store the mock owns. The
    /// drain runs first because it is the only thing that makes releasing any of
    /// the three safe, and because it is the same drain a failed assertion
    /// unwinds through.
    fn deinit(self: *HeadlessStore) void {
        self.drain() catch
            @panic("W19 headless store could not wait its parked worker out before its record died");
        self.service.deinit();
        // The poison is registered after the drain and the service release,
        // because both have to be complete before anything may treat this
        // owner as dead: the record the service names lives inside this value.
        defer self.* = undefined;
    }

    /// Park the next call inside the provider, so the wait under test has no
    /// answer to end on and can only end on its budget.
    fn parkNextCall(self: *HeadlessStore) void {
        self.mock.gate = &self.latch;
    }

    /// Open the latch after a real delay, on a thread of its own. A wait that
    /// ignored its budget still has to be told the worker may stop, or the suite
    /// hangs instead of reporting the failure. The thread does not touch the
    /// `Io` the wait under test is using, and the drain joins it.
    fn startBackstop(self: *HeadlessStore) !void {
        self.backstop = try std.Thread.spawn(
            .{},
            openLatchAfterBackstop,
            .{ &self.latch, headless_backstop_ms },
        );
    }

    /// One call on a worker with a budget, exactly as the arm runs it. False
    /// means the budget ran out with the worker still inside the provider, so
    /// the record is not safe to read or to release until the drain has run.
    fn readWithin(self: *HeadlessStore, deadline_ms: u64, label: []const u8) !bool {
        return awaitWorker(self.io, &self.call, deadline_ms, label, self.report, readWorker);
    }

    /// Wait a parked worker out, so the record it fills and the service it calls
    /// outlive it. The latch opens first: the mock is the only thing that parks a
    /// worker here, and it parks because the test asked it to, so the worker is
    /// one step from the end of its own provider. The bound covers that step
    /// rather than the budget the test was measuring.
    fn drain(self: *HeadlessStore) !void {
        self.latch.open.store(true, .release);
        if (self.backstop) |thread| {
            thread.join();
            self.backstop = null;
        }
        try drainCall(self.io, &self.call, headless_drain_bound_ms, "parked call", self.report);
    }
};

/// The backstop's own wait. `poll` with nothing to watch is a bounded wait that
/// needs no `Io` of its own, and slicing it lets a latch opened elsewhere end
/// this early instead of costing the drain the whole bound.
fn openLatchAfterBackstop(latch: *credentials.MockCredentialProvider.Gate, bound_ms: i64) void {
    var nothing: [0]std.posix.pollfd = .{};
    var waited: i64 = 0;
    while (waited < bound_ms) {
        const slice = @min(backstop_slice_ms, bound_ms - waited);
        _ = std.posix.poll(&nothing, @intCast(slice)) catch return;
        waited += slice;
        if (latch.open.load(.acquire)) return;
    }
    latch.open.store(true, .release);
}

test "w19-service-smoke: a call that missed its budget is waited out before the record dies" {
    const gpa = std.testing.allocator;
    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();
    // Zig's test runner owns stdout for its binary protocol.
    var report: Reporter = .{ .io = io, .output = .stderr() };

    var store: HeadlessStore = undefined;
    store.init(gpa, io, &report);
    defer store.deinit();

    // The very first call of the run parks inside the provider, so it has no
    // answer to give and the budget is the only thing that can end this wait.
    // Nothing here depends on how loaded the machine is: the latch is shut for
    // the whole of it, so a missed budget is the outcome rather than a risk.
    store.parkNextCall();
    try store.startBackstop();

    const answered = try store.readWithin(headless_deadline_ms, "parked first read");
    try std.testing.expect(!answered);
    // The wait ended on its budget with a worker still inside the provider, so
    // the record and the service are both still in use at this point.
    try std.testing.expect(!store.call.done.load(.acquire));
    try std.testing.expect(store.call.pending != null);

    // Whoever outlives that worker owns it. The result it stores is readable
    // here only because the record was still there to receive it, and the
    // cancellation is the one the timeout reported, so both the join and the
    // answer the run gave are visible from the owner. `deinit` runs this same
    // drain, so an assertion that fails above unwinds through the wait instead
    // of releasing the record under it.
    try store.drain();
    try std.testing.expect(store.call.pending == null);
    try std.testing.expect(store.call.done.load(.acquire));
    try std.testing.expect(store.call.read_result == .canceled);
}

test "w19-service-smoke: the second credential call is bounded even though the first one answered" {
    const gpa = std.testing.allocator;
    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();
    // Zig's test runner owns stdout for its binary protocol.
    var report: Reporter = .{ .io = io, .output = .stderr() };

    var store: HeadlessStore = undefined;
    store.init(gpa, io, &report);
    defer store.deinit();

    // The first call answers through the real service and the real provider.
    // That answer is what leaves the record in the state a reused flag would
    // let the next call mistake for its own.
    try std.testing.expect(try store.readWithin(headless_deadline_ms, "existence read"));
    try std.testing.expect(store.call.read_result == .not_found);

    // The second call parks inside the provider, so it has no answer at all.
    store.parkNextCall();
    try store.startBackstop();

    const answered = try store.readWithin(headless_deadline_ms, "second read");
    try std.testing.expect(!answered);
    try std.testing.expect(!store.call.done.load(.acquire));
    try std.testing.expect(store.call.pending != null);

    // Nothing may outlive the record, so the parked worker is finished before
    // this scope ends, exactly as the process ending would have left it. The
    // bound covers the provider finishing rather than the latch above it, so a
    // worker that never comes back is a failure instead of a hang.
    try store.drain();
    try std.testing.expect(store.call.done.load(.acquire));
    try std.testing.expect(store.call.read_result == .canceled);
}

test "w19-service-smoke: a locked read that needed a person is not an empty namespace" {
    const gpa = std.testing.allocator;
    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();
    // Zig's test runner owns stdout for its binary protocol.
    var report: Reporter = .{ .io = io, .output = .stderr() };

    // A store with no person at its screen raises the unlock prompt and has it
    // answered for it, so the provider hands back prompt_dismissed. The item was
    // found and stayed locked, so this is neither the read that produced no item
    // at all nor a refusal of any other kind, and it is not a missing password.
    // The classification is what keeps the locked arm from filing it as a
    // namespace that held nothing, or as a lock that was not observed at all.
    const dismissed = try witnessRead(&report, "locked read", .prompt_dismissed, headless_secret);
    try std.testing.expect(dismissed == .dismissed);

    const empty = try witnessRead(&report, "locked read", .not_found, headless_secret);
    try std.testing.expect(empty == .empty);

    const locked = try witnessRead(&report, "locked read", .locked, headless_secret);
    try std.testing.expect(locked == .locked);

    const refused = try witnessRead(&report, "locked read", .denied, headless_secret);
    try std.testing.expect(refused == .refused);
    try std.testing.expectEqualStrings("denied", refused.refused);
}

/// The daemon the notification scenario needs, in memory: it hands out ids,
/// expires whatever was posted with a timeout the way a real daemon expires a
/// toast, and confirms a close. The expiry for a replaced id is queued while
/// that id still exists, so the run also sees the late answer it must not
/// count as a closure of anything it still owns.
const ExpiringDaemon = struct {
    capabilities: notifications.Capabilities = .none,
    next_id: notifications.NotificationId = 1,
    /// The answers this daemon owes its client. `submitFn` writes an entry and
    /// counts it, `pollFn` hands over exactly the counted ones, and
    /// `queued_len` starts at zero, so an entry is never read before the call
    /// that wrote it. The storage is handed over by `init`, never defaulted.
    queued: [8]notifications.QueuedResponse,
    queued_len: usize = 0,
    posted: usize = 0,
    posted_with_actions: usize = 0,
    closed: usize = 0,

    /// The one construction. The queue is built here rather than defaulted, so
    /// a daemon nobody built can never be mistaken for one with an empty queue.
    fn init(capabilities: notifications.Capabilities) ExpiringDaemon {
        return .{
            .capabilities = capabilities,
            // SAFETY: queued_len starts at zero. submitFn initializes a slot
            // before counting it; pollFn reads only those counted slots.
            .queued = undefined,
        };
    }

    fn provider(self: *ExpiringDaemon) notifications.NotificationProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: notifications.NotificationProvider.VTable = .{
        .submit = submitFn,
        .dismiss = dismissFn,
        .getCapabilities = getCapabilitiesFn,
        .disconnect = disconnectFn,
        .deinit = deinitFn,
        .poll = pollFn,
    };

    fn submitFn(
        ctx: *anyopaque,
        options: notifications.NotificationOptions,
    ) notifications.SubmitOutcome {
        const self: *ExpiringDaemon = @ptrCast(@alignCast(ctx));
        self.posted += 1;
        if (options.actions.len != 0) self.posted_with_actions += 1;
        const id = self.next_id;
        self.next_id += 1;
        // A toast posted with a timeout is the one a daemon expires, and its
        // answer arrives through the transport rather than out of a call.
        if (options.timeout_ms != 0 and self.queued_len != self.queued.len) {
            self.queued[self.queued_len] = .{
                .id = id,
                .response = .{ .closed = .{ .reason = .expired } },
            };
            self.queued_len += 1;
        }
        return .{ .accepted = id };
    }

    fn dismissFn(ctx: *anyopaque, id: notifications.NotificationId) notifications.DismissOutcome {
        _ = id;
        const self: *ExpiringDaemon = @ptrCast(@alignCast(ctx));
        self.closed += 1;
        return .closed;
    }

    fn getCapabilitiesFn(ctx: *anyopaque) notifications.Capabilities {
        const self: *ExpiringDaemon = @ptrCast(@alignCast(ctx));
        return self.capabilities;
    }

    fn disconnectFn(_: *anyopaque) void {}

    fn deinitFn(_: *anyopaque) void {}

    fn pollFn(
        ctx: *anyopaque,
        service: *notifications.NotificationsService,
        timeout_ms: i32,
    ) anyerror!usize {
        _ = timeout_ms;
        const self: *ExpiringDaemon = @ptrCast(@alignCast(ctx));
        // Everything that was queued is handed over once, in the order it was
        // queued, and the queue is emptied before the first delivery: a
        // response this daemon already sent must not be routed again by a
        // later drain, and a handler that answered back must not find the
        // responses it is looking at overwritten.
        var pending: [8]notifications.QueuedResponse = undefined;
        const count = self.queued_len;
        @memcpy(pending[0..count], self.queued[0..count]);
        self.queued_len = 0;
        for (pending[0..count]) |queued| {
            service.handleResponse(queued.id, queued.response);
        }
        return count;
    }
};

test "w19-service-smoke: the notify arm counts the daemon's own expiry as that id closing" {
    const gpa = std.testing.allocator;
    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();
    var report: Reporter = .{ .io = io, .output = .stderr() };

    var daemon: ExpiringDaemon = .init(.{ .actions = true });
    var service = notifications.NotificationsService.init(gpa, daemon.provider());
    defer service.deinit();

    // The scenario is what the arm runs once it is authorized; the scenario is
    // not the gate, and the arm is still the only path to a real bus. The budget
    // is one the arm itself would have accepted, so a scenario is never driven
    // with a wait that could not have seen the expiry it is watching for.
    const options: Options = .{ .command = .notify, .wait_ms = 1_000, .expiry_ms = 200 };
    try checkNotificationBudget(options);
    try runNotifyScenario(io, &report, options, &service, daemon.capabilities, "headless");

    try std.testing.expectEqual(@as(usize, 3), daemon.posted);
    // The replacement expired on its own, so only the never-expiring toast was
    // closed by a call this run made.
    try std.testing.expectEqual(@as(usize, 1), daemon.closed);
}

test "w19-service-smoke: a notify wait that cannot reach the expiry is refused, and nothing else is" {
    // An expiry exactly at the wait is the case a run cannot pass: the pump
    // deadline and the daemon's own expiry are the same instant, so the answer
    // this run exists to observe arrives after the run has stopped watching.
    try std.testing.expectError(
        error.NotificationWaitCannotObserveTheExpiry,
        checkNotificationBudget(.{
            .command = .notify,
            .wait_ms = 2_000,
            .expiry_ms = 2_000,
        }),
    );
    // An expiry past the wait loses the same race by more, and is refused for
    // the same reason rather than for the size of the miss.
    try std.testing.expectError(
        error.NotificationWaitCannotObserveTheExpiry,
        checkNotificationBudget(.{
            .command = .notify,
            .wait_ms = 2_000,
            .expiry_ms = max_expiry_ms,
        }),
    );
    // The margin is the whole rule, so one millisecond short of it is refused
    // and the margin itself is not.
    try std.testing.expectError(
        error.NotificationWaitCannotObserveTheExpiry,
        checkNotificationBudget(.{
            .command = .notify,
            .wait_ms = 2_000 + @as(u64, @intCast(min_pump_slack_ms)) - 1,
            .expiry_ms = 2_000,
        }),
    );
    try checkNotificationBudget(.{
        .command = .notify,
        .wait_ms = 2_000 + @as(u64, @intCast(min_pump_slack_ms)),
        .expiry_ms = 2_000,
    });
    // The shipped defaults clear the margin, so the arm runs without flags.
    try checkNotificationBudget(.{
        .command = .notify,
        .wait_ms = default_wait_ms,
        .expiry_ms = default_expiry_ms,
    });
    // The credential arm has no toast to observe, so its wait is a per-call
    // budget of its own and this rule is not its business. Neither is the safe
    // default's.
    try checkNotificationBudget(.{
        .command = .credential,
        .wait_ms = min_wait_ms,
        .expiry_ms = max_expiry_ms,
    });
    try checkNotificationBudget(.{});
}

test "w19-service-smoke: a daemon that offers no actions still closes what the run posted" {
    const gpa = std.testing.allocator;
    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();
    var report: Reporter = .{ .io = io, .output = .stderr() };

    var daemon: ExpiringDaemon = .init(.none);
    var service = notifications.NotificationsService.init(gpa, daemon.provider());
    defer service.deinit();

    const options: Options = .{ .command = .notify, .wait_ms = 1_000, .expiry_ms = 200 };
    try checkNotificationBudget(options);
    try runNotifyScenario(io, &report, options, &service, daemon.capabilities, "headless");

    try std.testing.expectEqual(@as(usize, 3), daemon.posted);
    // Nothing was offered because nothing is available, which is a limit of
    // this daemon and not a failure of either close.
    try std.testing.expectEqual(@as(usize, 0), daemon.posted_with_actions);
    try std.testing.expectEqual(@as(usize, 1), daemon.closed);
}
