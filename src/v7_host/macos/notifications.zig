//! E02: UserNotifications as a `notifications.NotificationProvider`.
//!
//! PROVIDER ACCEPTANCE IS NOT DISPLAY. `addNotificationRequest:completion:`
//! answers on a queue the shim does not own, and the shim hops that answer
//! onto the main queue before any of it reaches Zig, so `submit` reports what
//! the provider could establish synchronously — that this application is
//! allowed to post at all — and everything later (the user's answer, a later
//! refusal) arrives through `poll` and reaches the model through the shared
//! service. Nothing here reports a request as accepted merely because it was
//! queued.
//!
//! EVERY NATIVE CALLBACK IS A MAIN-QUEUE OPERATION. The framework answers on
//! queues of its own choosing, the delegate's response among them, so the shim
//! marshals every answer onto the main queue and reads its callback table only
//! there. The ring below carries the answer from that queue to the host's
//! pump, and `detach` is itself a main-queue operation: once it returns, no
//! callback is running and none can start, which is what lets a caller release
//! this record.
//!
//! A BUNDLE IS REQUIRED. UserNotifications refuses to work in a process with
//! no bundle identifier, which is every unbundled executable. The provider
//! reports `unsupported` there instead of accepting requests the system would
//! drop.
//!
//! MACOS HAS NO REPLACE. FreeBSD's notification server can replace a delivered
//! notification in place; UserNotifications cannot. A replacement is therefore
//! remove-then-add, and the old identifier is withdrawn first so a person never
//! sees both. macOS also has no close signal, so a notification the user
//! swipes away is not observable from here; the shared model's `dismiss` is
//! the only way this provider learns a notification is gone.
const std = @import("std");
const native = @import("native.zig");
const notifications = @import("../notifications.zig");

const Error = native.Error;
const Status = native.Status;
const shim = native.shim;

const NotificationId = notifications.NotificationId;

/// What the system last said about this application's permission to post.
///
/// macOS has three reachable states: not determined, denied, and authorized.
/// `UNAuthorizationStatusProvisional` and `UNAuthorizationStatusEphemeral`
/// are declared unavailable on this platform — provisional is an iOS, tvOS
/// and watchOS authorization, ephemeral is an App Clip one — so a state this
/// platform cannot report is not one the host is given.
pub const Authorization = enum {
    /// No answer has arrived yet. A provider in this state cannot say whether
    /// a request would be accepted, and says so instead of guessing.
    unknown,
    /// The application never asked, and the centre rejects a request that
    /// arrives before the answer.
    not_determined,
    denied,
    /// The application asked and the system says it may post.
    authorized,
    /// The query itself failed. `authorizationError` carries the platform's
    /// own code, so a failed query is distinct from any state above.
    failed,

    /// Whether a request may be posted.
    pub fn mayPost(self: Authorization) bool {
        return switch (self) {
            .authorized => true,
            .not_determined, .denied, .failed, .unknown => false,
        };
    }
};

/// What this application asks the system for when it requests permission.
///
/// There is no provisional option, because
/// `UNAuthorizationOptionProvisional` is declared unavailable on macOS: a
/// macOS application asks, or it does not.
pub const Options = struct {
    alert: bool = true,
    sound: bool = true,
    badge: bool = true,
};

/// The identifier UserNotifications uses for a plain click.
pub const default_action = "default";

/// Completions buffered between the notification centre's queues and the host
/// thread.
pub const completion_limit = 32;

const Completion = struct {
    kind: enum { action, refused },
    id: NotificationId,
    /// The action key, NUL terminated. The shared service borrows it for the
    /// delivery, which is exactly how long this buffer lives.
    text: [128]u8,
    len: usize = 0,
};

/// One marshalled notification-centre call.
///
/// The shim's UserNotifications entry points are AppKit objects and require
/// the macOS main thread, but the shared service forwards its vtable to
/// whatever thread calls it and offers no thread of its own. Every call below
/// therefore goes through `native.onMain`, which runs the work inline when the
/// caller is already on the main thread and marshals it there (blocking) when
/// it is not. Each record lives on the calling method's stack, so the
/// arguments and the result are valid for the whole call and nothing is left
/// behind. This mirrors the marshalling `keychain.zig` uses for the same
/// reason.
///
/// Every callback below names the shim's entry points, and the shim is
/// Objective-C that a macOS build compiles and nothing else does. `onMain`
/// refuses a build without it before it reaches a callback, so off macOS none
/// of this work ever runs. The callback is compiled either way, though, and a
/// non-macOS link then fails on a symbol nothing defines. That is not
/// hypothetical: `provider`'s vtable retains `submit` and `dismiss`, so a test
/// that touches the provider compiles those two callbacks even off macOS. The
/// gate is therefore `comptime`, and the branch off macOS answers with the
/// typed unavailability each caller already maps to `unsupported` rather than
/// a status the shim never produced.
const AttachCall = struct {
    provider: *Provider,
    callbacks: shim.nogui_macos_notification_callbacks,
    handle: ?*anyopaque = null,
    /// The centre refused the process entirely: an unbundled executable, or a
    /// system that will not talk to it.
    unsupported: bool = false,
};

fn attachOnMain(call: *AttachCall) void {
    if (comptime !native.available) {
        call.unsupported = true;
        return;
    }
    call.handle = shim.nogui_macos_notifications_new(&call.callbacks, @ptrCast(call.provider));
    call.unsupported = call.handle == null;
}

const QueryAuthCall = struct {
    handle: ?*anyopaque,
    status: Status = .ok,
};

fn queryAuthOnMain(call: *QueryAuthCall) void {
    if (comptime !native.available) {
        call.status = .unavailable;
        return;
    }
    call.status = Status.of(shim.nogui_macos_notifications_query_authorization(call.handle.?));
}

const RequestAuthCall = struct {
    handle: ?*anyopaque,
    wire: c_int,
    status: Status = .ok,
};

fn requestAuthOnMain(call: *RequestAuthCall) void {
    if (comptime !native.available) {
        call.status = .unavailable;
        return;
    }
    call.status =
        Status.of(shim.nogui_macos_notifications_request_authorization(call.handle.?, call.wire));
}

const CategoryCall = struct {
    handle: ?*anyopaque,
    identifier: [*:0]const u8,
    actions: []shim.nogui_macos_notification_action,
    allows_in_carplay: c_int,
    status: Status = .ok,
};

fn setCategoryOnMain(call: *CategoryCall) void {
    if (comptime !native.available) {
        call.status = .unavailable;
        return;
    }
    call.status = Status.of(shim.nogui_macos_notifications_set_category(
        call.handle.?,
        call.identifier,
        call.actions.ptr,
        call.actions.len,
        call.allows_in_carplay,
    ));
}

const SubmitCall = struct {
    handle: ?*anyopaque,
    id: NotificationId,
    replaces: ?NotificationId,
    identifier: [*:0]const u8,
    title: [*:0]const u8,
    subtitle: ?[*:0]const u8,
    body: [*:0]const u8,
    category: ?[*:0]const u8,
    icon: ?[*:0]const u8,
    sound: ?[*:0]const u8,
    thread: c_int,
    status: Status = .ok,
};

fn submitOnMain(call: *SubmitCall) void {
    if (comptime !native.available) {
        call.status = .unavailable;
        return;
    }
    // macOS cannot replace a delivered notification in place, so a
    // replacement withdraws the old one first: a person never sees both.
    if (call.replaces) |old| {
        var old_buffer: [16]u8 = undefined;
        if (Provider.identifierOf(old, &old_buffer)) |old_identifier| {
            _ = shim.nogui_macos_notifications_remove(call.handle.?, old_identifier);
        } else |_| {}
    }
    call.status = Status.of(shim.nogui_macos_notifications_add(
        call.handle.?,
        call.identifier,
        call.title,
        call.subtitle,
        call.body,
        call.category,
        call.icon,
        call.sound,
        call.thread,
        0,
    ));
}

const DismissCall = struct {
    handle: ?*anyopaque,
    identifier: [*:0]const u8,
    status: Status = .ok,
};

fn dismissOnMain(call: *DismissCall) void {
    if (comptime !native.available) {
        call.status = .unavailable;
        return;
    }
    call.status = Status.of(shim.nogui_macos_notifications_remove(call.handle.?, call.identifier));
}

/// Releasing the centre's delegate is itself a main-thread call: the shim
/// refuses anywhere else, and a refusal would leave the centre holding the
/// delegate and calling into a record the caller is about to release.
const FreeCall = struct {
    handle: *anyopaque,
};

fn freeOnMain(call: *FreeCall) void {
    if (comptime !native.available) return;
    shim.nogui_macos_notifications_free(call.handle);
}

/// One caller string, copied into the scratch a marshalled submit reads.
const CopiedText = union(enum) {
    /// The NUL-terminated copy, valid for as long as the scratch lives.
    text: [*:0]const u8,
    /// Why this provider cannot post the string it was handed.
    failure: notifications.SubmitOutcome,
};

/// Copy one caller string into `scratch`, or name the submit failure it is.
///
/// The two refusals stay distinct: a string past the shim's own limit is a
/// protocol error the caller caused, and an allocator that ran out is memory.
fn copyText(scratch: *native.Scratch, text: []const u8) CopiedText {
    const owned = scratch.nul(text) catch |err| switch (err) {
        error.OutOfMemory => return .{ .failure = .{ .provider_failed = .out_of_memory } },
        else => return .{ .failure = .{ .provider_failed = .protocol_error } },
    };
    return .{ .text = owned orelse return .{ .failure = .{ .provider_failed = .protocol_error } } };
}

/// The notification centre, as the shared service's provider.
///
/// Allocate one, then initialize it in place: the centre keeps the pointer for
/// as long as it is the delegate.
///     const provider = try gpa.create(Provider);
///     errdefer gpa.destroy(provider);
///     provider.* = Provider.init(gpa, io);
pub const Provider = struct {
    gpa: std.mem.Allocator,
    /// The Io the completion ring's mutex waits on. The centre's answers reach
    /// the ring from the main queue and the host drains it from whichever
    /// thread it pumps on, so the mutex is contended across threads and the
    /// window that owns this provider has to keep its Io alive for as long as
    /// the centre holds the delegate.
    io: std.Io,
    /// The shim's delegate. Null before `attach` and after `detach`.
    handle: ?*anyopaque = null,
    closed: bool = false,
    connected: bool = true,
    next_id: NotificationId = 1,
    authorization: Authorization = .unknown,
    /// The platform's own code for the last authorization answer, or zero.
    authorization_code: i32 = 0,
    /// Every request this provider handed to the centre, so a dismissal can
    /// name it. The shared service owns the weak owner; this is only the
    /// platform-side identity.
    posted: std.AutoHashMapUnmanaged(NotificationId, void) = .empty,
    completions: [completion_limit]Completion,
    completion_count: u16 = 0,
    completion_head: u16 = 0,
    dropped: u32 = 0,
    mutex: std.Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Provider {
        return .{
            .gpa = gpa,
            .io = io,
            // SAFETY: `poll` reads only the slots the callbacks counted, and
            // `push` filled every one of those before it counted it.
            .completions = undefined,
        };
    }

    /// Attach to the notification centre. Returns `unsupported` in a process
    /// the centre will not talk to, which is the honest answer for an
    /// unbundled executable.
    pub fn attach(self: *Provider) Error!void {
        if (!native.available) return error.ShimUnavailable;
        if (self.handle != null) return;
        const callbacks: shim.nogui_macos_notification_callbacks = .{
            .user = @ptrCast(self),
            .on_response = onResponse,
            .on_error = onError,
            .on_authorization = onAuthorization,
        };
        var call: AttachCall = .{ .provider = self, .callbacks = callbacks };
        native.onMain(AttachCall, attachOnMain, &call) catch return error.ShimUnavailable;
        if (call.unsupported) return error.Unsupported;
        self.handle = call.handle;
    }

    /// Ask the platform what this application is allowed to do, without
    /// prompting. The answer updates `authorizationOf` when it arrives.
    pub fn queryAuthorization(self: *Provider) Error!void {
        if (!native.available) return error.ShimUnavailable;
        const handle = self.handle orelse return error.Unsupported;
        var call: QueryAuthCall = .{ .handle = handle };
        native.onMain(QueryAuthCall, queryAuthOnMain, &call) catch return error.NotOnMainThread;
        try native.check(call.status);
    }

    /// Ask for permission. This shows the system prompt, so a host calls it
    /// only in answer to a person's action.
    pub fn requestAuthorization(self: *Provider, options: Options) Error!void {
        if (!native.available) return error.ShimUnavailable;
        const handle = self.handle orelse return error.Unsupported;
        // The wire mask IS `UNAuthorizationOptions`: badge is 1, sound is 2,
        // alert is 4. Sending the shim a second numbering to translate was
        // how the first version had alert and badge the wrong way round.
        var wire: c_int = 0;
        if (options.badge) wire |= 1;
        if (options.sound) wire |= 2;
        if (options.alert) wire |= 4;
        var call: RequestAuthCall = .{ .handle = handle, .wire = wire };
        native.onMain(RequestAuthCall, requestAuthOnMain, &call) catch return error.NotOnMainThread;
        try native.check(call.status);
    }

    /// What the platform last reported, without contacting it.
    ///
    /// Read under the mutex: the answer arrives on UserNotifications' private
    /// queue, so an unlocked read races the write that published it.
    pub fn authorizationOf(self: *Provider) Authorization {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.authorization;
    }

    /// The platform's code behind the last authorization answer, or zero.
    /// Read under the mutex, like the state it belongs to.
    pub fn authorizationError(self: *Provider) i32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.authorization_code;
    }

    /// Release the centre's delegate.
    ///
    /// The free runs on the main thread: the shim refuses anywhere else, and a
    /// refusal would leave the centre holding this delegate and calling into a
    /// record the caller is about to release. The free is a barrier, and the
    /// shim is what makes it one. Every native answer is marshalled onto the
    /// main queue before the shim reads its callback table, and this free is
    /// itself a main-queue operation, so an answer that ran before the free
    /// has finished and an answer the framework queues after it reads a table
    /// whose entries are all NULL. Neither can reach the record the caller is
    /// about to poison. `closed` covers the window between this flag and the
    /// free: an answer the main queue runs inside that window finds it set and
    /// returns without touching this record.
    ///
    /// A free that never reached the main thread leaves the centre holding this
    /// record, so there is no barrier and the record the caller is about to
    /// release is one the centre may still call. That case stops the process
    /// with a message naming the dispatch that never ran: the delegate cannot
    /// be dropped quietly here, because what it would then reach is released
    /// memory.
    pub fn detach(self: *Provider) void {
        self.mutex.lockUncancelable(self.io);
        self.closed = true;
        self.mutex.unlock(self.io);
        const handle = self.handle orelse return;
        self.handle = null;
        if (!native.available) return;
        var call: FreeCall = .{ .handle = handle };
        native.onMain(FreeCall, freeOnMain, &call) catch @panic(
            "macos notifications: the main-thread free never ran, so the centre still holds " ++
                "this delegate and would call into a record the caller is about to release",
        );
    }

    pub fn deinit(self: *Provider) void {
        self.detach();
        self.posted.deinit(self.gpa);
        self.* = undefined;
    }

    /// The vtable the shared service drives.
    pub fn provider(self: *Provider) notifications.NotificationProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Refuse new calls and forget what was posted.
    pub fn disconnect(self: *Provider) void {
        self.connected = false;
        self.posted.clearRetainingCapacity();
    }

    /// Deliver every buffered completion to the shared service. Returns how
    /// many the service took.
    ///
    /// The ring is emptied under the lock and delivered outside it, so a
    /// handler that shuts the service down cannot deadlock against itself.
    pub fn poll(self: *Provider, service: *notifications.NotificationsService) usize {
        var pending: [completion_limit]Completion = undefined;
        var count: usize = 0;
        self.mutex.lockUncancelable(self.io);
        if (!self.closed) {
            while (self.completion_count > 0) {
                pending[count] = self.completions[self.completion_head];
                self.completion_head = (self.completion_head + 1) % completion_limit;
                self.completion_count -= 1;
                count += 1;
            }
        }
        self.mutex.unlock(self.io);
        var routed: usize = 0;
        for (pending[0..count]) |completion| {
            switch (completion.kind) {
                .action => {
                    service.handleResponse(completion.id, .{
                        .action = .{ .key = completion.text[0..completion.len] },
                    });
                    _ = self.posted.remove(completion.id);
                    routed += 1;
                },
                .refused => {
                    // The centre rejected a request the provider had already
                    // accepted. The owner hears about it as a provider that
                    // went away, which is what it is from the model's point
                    // of view, rather than as an answer nobody chose.
                    _ = self.posted.remove(completion.id);
                    service.handleResponse(completion.id, .provider_lost);
                    routed += 1;
                },
            }
        }
        return routed;
    }

    /// Completions the ring refused because the host was not polling.
    pub fn droppedCompletions(self: *const Provider) u32 {
        return self.dropped;
    }

    /// Register a category and its actions. UserNotifications only shows the
    /// buttons of a category registered before the request that names it, so a
    /// host registers once at startup rather than per notification.
    pub fn setCategory(
        self: *Provider,
        identifier: []const u8,
        actions: []const notifications.Action,
        allows_in_carplay: bool,
    ) Error!void {
        if (!native.available) return error.ShimUnavailable;
        const handle = self.handle orelse return error.Unsupported;
        var scratch = native.Scratch.init(self.gpa);
        defer scratch.deinit();
        const alloc = scratch.arena.allocator();
        const owned_id = (try scratch.nul(identifier)) orelse return error.BadArgument;
        const built = try alloc.alloc(shim.nogui_macos_notification_action, actions.len);
        for (actions, 0..) |action, index| {
            built[index] = .{
                .identifier = (try scratch.nul(action.key)) orelse return error.BadArgument,
                .title = (try scratch.nul(action.label)) orelse return error.BadArgument,
                .destructive = 0,
                .foreground = 1,
            };
        }
        var call: CategoryCall = .{
            .handle = handle,
            .identifier = owned_id,
            .actions = built,
            .allows_in_carplay = if (allows_in_carplay) 1 else 0,
        };
        native.onMain(CategoryCall, setCategoryOnMain, &call) catch return error.NotOnMainThread;
        try native.check(call.status);
    }

    /// What this provider can actually do, as the shared model asks.
    pub fn capabilities() notifications.Capabilities {
        return .{
            .body = true,
            // UserNotifications takes one body string. A list of links has no
            // documented option, and reporting a capability nothing can
            // deliver is how a notification service starts lying.
            .body_hyperlinks = false,
            .body_markup = false,
            .body_images = true,
            // A category's actions are real, and a reply carries the
            // identifier the host chose.
            .actions = true,
            // An action has no icon of its own on macOS.
            .action_icons = false,
            .sound = true,
            // macOS decides how long a banner lives; there is no persistence
            // option to ask for.
            .persistence = false,
        };
    }

    const vtable: notifications.NotificationProvider.VTable = .{
        .submit = submitFn,
        .dismiss = dismissFn,
        .getCapabilities = getCapabilitiesFn,
        .disconnect = disconnectFn,
        .deinit = deinitFn,
        .poll = pollFn,
    };

    /// The drain behind the provider contract, so a host that handed the
    /// provider to a service needs no reference to it and no downcast. The
    /// centre's delegate already marshalled every response onto a ring, so the
    /// timeout means nothing here: there is nothing to wait for.
    fn pollFn(
        ctx: *anyopaque,
        service: *notifications.NotificationsService,
        timeout_ms: i32,
    ) anyerror!usize {
        _ = timeout_ms;
        const self: *Provider = @ptrCast(@alignCast(ctx));
        return self.poll(service);
    }

    /// The centre's request identifier for one notification. The buffer starts
    /// zeroed so the digits end in a NUL the centre can read; `bufPrint` alone
    /// would leave whatever was in the buffer behind them.
    pub fn identifierOf(id: NotificationId, buffer: *[16]u8) ![*:0]const u8 {
        @memset(buffer, 0);
        const text = try std.fmt.bufPrint(buffer, "{d}", .{id});
        return @ptrCast(text.ptr);
    }

    /// The identifier the centre named, read back from the NUL-terminated C
    /// string it hands back. A null pointer or bytes that are not an integer
    /// is a centre that named nothing, which is an answer a caller has to
    /// see rather than an identifier to guess at.
    pub fn parseIdentifier(text: [*c]const u8) ?NotificationId {
        if (text == null) return null;
        return std.fmt.parseInt(NotificationId, std.mem.span(text), 10) catch null;
    }

    fn submitFn(ctx: *anyopaque, options: notifications.NotificationOptions) notifications.SubmitOutcome {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        if (!self.connected) return .{ .provider_failed = .disconnected };
        if (self.handle == null) return .unsupported;
        switch (self.authorizationOf()) {
            .authorized => {},
            .denied => return .denied,
            // The application never asked, and the centre rejects a request
            // that arrives before the answer. That is a refusal of this
            // request, not a permission the user withheld.
            .not_determined, .failed => return .{ .provider_failed = .rejected },
            // No answer has arrived, so the provider cannot say whether the
            // request would be accepted. That is not a denial the user made.
            .unknown => return .{ .provider_failed = .timeout },
        }

        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;

        var scratch = native.Scratch.init(self.gpa);
        defer scratch.deinit();

        var id_buffer: [16]u8 = undefined;
        const identifier = identifierOf(id, &id_buffer) catch
            return .{ .provider_failed = .out_of_memory };

        // The strings are copied here, on the calling thread, because the
        // caller's slices are borrowed and the marshalled call below may run
        // after this frame would have returned.
        const title = switch (copyText(&scratch, options.summary)) {
            .text => |value| value,
            .failure => |outcome| return outcome,
        };
        const body = switch (copyText(&scratch, options.body)) {
            .text => |value| value,
            .failure => |outcome| return outcome,
        };
        const subtitle: ?[*:0]const u8 = if (options.app_name) |name| switch (copyText(&scratch, name)) {
            .text => |value| value,
            .failure => |outcome| return outcome,
        } else null;
        const category: ?[*:0]const u8 = if (options.category) |value| switch (copyText(&scratch, value)) {
            .text => |text| text,
            .failure => |outcome| return outcome,
        } else null;
        const sound: ?[*:0]const u8 = if (options.sound) |value| switch (copyText(&scratch, value)) {
            .text => |text| text,
            .failure => |outcome| return outcome,
        } else null;
        const icon: ?[*:0]const u8 = if (options.icon) |value| switch (copyText(&scratch, value)) {
            .text => |text| text,
            .failure => |outcome| return outcome,
        } else null;
        const thread: c_int = switch (options.urgency) {
            .low => 0,
            .normal => 1,
            .critical => 3,
        };

        if (options.replaces_id) |old| _ = self.posted.remove(old);
        var call: SubmitCall = .{
            .handle = self.handle,
            .id = id,
            .replaces = options.replaces_id,
            .identifier = identifier,
            .title = title,
            .subtitle = subtitle,
            .body = body,
            .category = category,
            .icon = icon,
            .sound = sound,
            .thread = thread,
        };
        native.onMain(SubmitCall, submitOnMain, &call) catch return submitFailure(.thread);
        if (!call.status.isOk()) return submitFailure(call.status);
        self.posted.put(self.gpa, id, {}) catch return .{ .provider_failed = .out_of_memory };
        return .{ .accepted = id };
    }

    fn submitFailure(status: Status) notifications.SubmitOutcome {
        return switch (status) {
            .ok, .unavailable => .unsupported,
            .refused => .denied,
            .argument, .encoding => .{ .provider_failed = .protocol_error },
            .buffer => .{ .provider_failed = .out_of_memory },
            .thread => .{ .provider_failed = .disconnected },
            .fault, .memory => .{ .provider_failed = .io_error },
        };
    }

    /// The shim's own answer, mapped the way a dismissal is read.
    ///
    /// A refusal is a refusal here exactly as it is for a submit: the centre
    /// is there, it answered, and its answer was no, so the notification stays
    /// on screen and stays tracked. The remaining statuses are the same
    /// failures `submit` names, because a close that could not be assembled or
    /// sent left no trace of itself anywhere.
    fn dismissFailure(status: Status) notifications.DismissOutcome {
        return switch (status) {
            .ok, .unavailable => .unsupported,
            .refused => .refused,
            .argument, .encoding => .{ .provider_failed = .protocol_error },
            .buffer => .{ .provider_failed = .out_of_memory },
            .thread => .{ .provider_failed = .disconnected },
            .fault, .memory => .{ .provider_failed = .io_error },
        };
    }

    fn dismissFn(ctx: *anyopaque, id: NotificationId) notifications.DismissOutcome {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        if (!self.connected) return .{ .provider_failed = .disconnected };
        // The centre is the provider. Without it there is nothing to close and
        // no notification to be on screen either.
        const handle = self.handle orelse return .unsupported;
        // An identifier the centre was never given names no notification, so
        // nothing was removed. That is a refusal, not a close.
        if (!self.posted.contains(id)) return .refused;
        var buffer: [16]u8 = undefined;
        const identifier = identifierOf(id, &buffer) catch
            return .{ .provider_failed = .out_of_memory };
        var call: DismissCall = .{ .handle = handle, .identifier = identifier };
        native.onMain(DismissCall, dismissOnMain, &call) catch return dismissFailure(.thread);
        if (!call.status.isOk()) return dismissFailure(call.status);
        _ = self.posted.remove(id);
        return .closed;
    }

    fn getCapabilitiesFn(ctx: *anyopaque) notifications.Capabilities {
        _ = ctx;
        return Provider.capabilities();
    }

    fn disconnectFn(ctx: *anyopaque) void {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        self.disconnect();
    }

    fn deinitFn(ctx: *anyopaque) void {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn fromUser(user: ?*anyopaque) ?*Provider {
        const ptr = user orelse return null;
        const self: *Provider = @ptrCast(@alignCast(ptr));
        // `closed` is read under the lock because `detach` writes it under the
        // lock and can be called from any thread. The shim orders an answer
        // against the whole of `detach`; this gate covers the part that
        // ordering cannot, an answer the main queue runs after the flag and
        // before the free marshalled from this call has landed.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return null;
        return self;
    }

    fn push(self: *Provider, completion: Completion) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.completion_count == completion_limit) {
            self.dropped +%= 1;
            return;
        }
        const tail = (self.completion_head + self.completion_count) % completion_limit;
        self.completions[tail] = completion;
        self.completion_count += 1;
    }

    fn onResponse(user: ?*anyopaque, identifier: [*c]const u8, action: [*c]const u8) callconv(.c) void {
        const self = Provider.fromUser(user) orelse return;
        const id = parseIdentifier(identifier) orelse return;
        const key = native.view(action);
        if (key.len >= 128) return;
        // SAFETY: the key is copied into this buffer on the next line, and
        // `poll` reads only the `len` bytes that copy wrote.
        var completion: Completion = .{ .kind = .action, .id = id, .len = key.len, .text = undefined };
        @memcpy(completion.text[0..key.len], key);
        self.push(completion);
    }

    fn onError(user: ?*anyopaque, identifier: [*c]const u8, status: c_int) callconv(.c) void {
        _ = status;
        const self = Provider.fromUser(user) orelse return;
        const id = parseIdentifier(identifier) orelse return;
        // SAFETY: a refusal carries no action key, and `poll` reads `text` only
        // for the `.action` kind.
        self.push(.{ .kind = .refused, .id = id, .text = undefined });
    }

    fn onAuthorization(user: ?*anyopaque, status: c_int) callconv(.c) void {
        const self = Provider.fromUser(user) orelse return;
        const answer: Authorization = switch (status) {
            0 => .not_determined,
            1 => .denied,
            2 => .authorized,
            // A negative answer is the platform's own error code, which is
            // distinct from a status the host could act on.
            else => .failed,
        };
        self.mutex.lockUncancelable(self.io);
        self.authorization = answer;
        self.authorization_code = status;
        self.mutex.unlock(self.io);
    }
};

test "api-w23 macos authorization separates unknown from denied" {
    // A provider that has not heard back must not be mistaken for a refusal
    // the user made.
    try std.testing.expect(!Authorization.unknown.mayPost());
    try std.testing.expect(!Authorization.not_determined.mayPost());
    try std.testing.expect(!Authorization.denied.mayPost());
    try std.testing.expect(!Authorization.failed.mayPost());
    try std.testing.expect(Authorization.authorized.mayPost());
}

test "api-w23 macos notification identifiers round trip through the centre" {
    var buffer: [16]u8 = undefined;
    for ([_]NotificationId{ 1, 42, 65535, std.math.maxInt(NotificationId) }) |id| {
        const text = try Provider.identifierOf(id, &buffer);
        try std.testing.expectEqual(id, Provider.parseIdentifier(text).?);
    }
    // A centre that named no request answers NULL, and bytes that are not an
    // integer are not an identifier this host may guess at.
    try std.testing.expect(Provider.parseIdentifier(null) == null);
    try std.testing.expect(Provider.parseIdentifier("not-a-number".ptr) == null);
}

test "api-w23 macos completion ring is bounded and drains oldest first" {
    var provider = Provider.init(std.testing.allocator, std.testing.io);
    defer provider.deinit();
    for (0..completion_limit) |index| {
        // SAFETY: `len` is zero, so no byte of this buffer is ever read.
        provider.completions[index] = .{ .kind = .action, .id = @intCast(index + 1), .text = undefined, .len = 0 };
    }
    provider.completion_count = completion_limit;
    provider.mutex.lockUncancelable(provider.io);
    const before = provider.completion_count;
    provider.mutex.unlock(provider.io);
    try std.testing.expectEqual(@as(u16, completion_limit), before);
    // A full ring counts what it refused rather than growing without bound.
    // SAFETY: a refusal carries no action key, and `poll` reads `text` only for
    // the `.action` kind.
    provider.push(.{ .kind = .refused, .id = 99, .text = undefined });
    try std.testing.expectEqual(@as(u32, 1), provider.droppedCompletions());
}

test "api-w23 macos dismissal names an absent centre instead of refusing a close" {
    // Off macOS the shim never attaches, so there is no notification centre to
    // ask and nothing on screen to close. A refusal here would report a live
    // centre declining a close it never received, and a caller reading it that
    // way waits on a notification nobody is showing.
    var provider = Provider.init(std.testing.allocator, std.testing.io);
    defer provider.deinit();
    try std.testing.expectEqual(
        notifications.DismissOutcome.unsupported,
        provider.provider().dismiss(1),
    );

    // A provider that was disconnected names the transport as gone, which is a
    // failure to reach the centre rather than a decision by it.
    provider.disconnect();
    try std.testing.expectEqual(
        notifications.DismissOutcome{ .provider_failed = .disconnected },
        provider.provider().dismiss(1),
    );
}

/// One owner, and what its handler does the first time the service reaches it
/// with a response.
///
/// The drain delivers from inside the host's own pump, so this is the ordinary
/// case where a click is answered by the application doing something with its
/// own lifecycle: shutting down the service that owns the notification. The
/// service and the provider behind it stay alive, because the host owns both
/// and the handler is reached while the drain is still standing in them.
const DrainingOwner = struct {
    /// Every action this owner was handed.
    actions: usize = 0,
    closes: usize = 0,
    lost: usize = 0,
    last_id: NotificationId = 0,
    /// The key copied out of the callback. The key itself borrows the
    /// provider's ring, which the drain has left behind by the time a test
    /// reads this.
    key: [64]u8 = @splat(0),
    key_len: usize = 0,
    teardown: enum { none, shutdown_service } = .none,
    shutdowns: usize = 0,
    service: ?*notifications.NotificationsService = null,

    fn onResponse(ctx: ?*anyopaque, id: NotificationId, response: notifications.Response) void {
        const self: *DrainingOwner = @ptrCast(@alignCast(ctx orelse return));
        self.last_id = id;
        switch (response) {
            .action => |act| {
                self.actions += 1;
                const len = @min(act.key.len, self.key.len);
                @memcpy(self.key[0..len], act.key[0..len]);
                self.key_len = len;
            },
            .closed => self.closes += 1,
            .provider_lost => self.lost += 1,
        }
        if (self.teardown != .none) self.tearDown();
    }

    /// What the owner's own code does to the service it was reached through.
    /// The shutdown completes every tracked notification, and that calls back
    /// into this owner, so the teardown is spent before it runs rather than
    /// after.
    fn tearDown(self: *DrainingOwner) void {
        const teardown = self.teardown;
        self.teardown = .none;
        switch (teardown) {
            .none => {},
            .shutdown_service => {
                self.shutdowns += 1;
                self.service.?.shutdown();
            },
        }
    }

    fn weak(self: *const DrainingOwner) notifications.WeakOwner {
        // A context with no probe is one the host vouches for, which is what a
        // test owner is: it is alive for every delivery it is given.
        return .{ .context = self };
    }

    fn handler(self: *DrainingOwner) notifications.ActionHandler {
        return .{ .context = self, .callback = onResponse };
    }

    fn copiedKey(self: *const DrainingOwner) []const u8 {
        return self.key[0..self.key_len];
    }
};

/// One buffered action, as the centre's response callback leaves it.
fn actionCompletion(id: NotificationId, key: []const u8) Completion {
    std.debug.assert(key.len < 128);
    // SAFETY: the key is copied into this buffer on the next line, and `poll`
    // reads only the `len` bytes that copy wrote.
    var completion: Completion = .{ .kind = .action, .id = id, .len = key.len, .text = undefined };
    @memcpy(completion.text[0..key.len], key);
    return completion;
}

/// One buffered refusal, which carries no action key.
fn refusedCompletion(id: NotificationId) Completion {
    // SAFETY: a refusal carries no action key, and `poll` reads `text` only
    // for the `.action` kind.
    return .{ .kind = .refused, .id = id, .text = undefined };
}

/// Track one notification and record it with the provider, which together is
/// what an accepted submit does on a machine with a notification centre in it.
///
/// Off macOS there is no centre to accept anything, so the routing under test
/// is the service's, and it is the service's on every platform.
fn track(
    gpa: std.mem.Allocator,
    service: *notifications.NotificationsService,
    provider: *Provider,
    id: NotificationId,
    owner: *DrainingOwner,
) !void {
    try service.tracked.put(id, .{
        .id = id,
        .owner = owner.weak(),
        .handler = owner.handler(),
    });
    try provider.posted.put(gpa, id, {});
}

test "api-w23 macos a buffered refusal reaches its owner as a provider that went away" {
    // The centre can refuse a request the provider already accepted, and the
    // owner hears that as the provider going away rather than as an answer
    // nobody chose. Translating it is the ring's own work, and the delivery
    // runs inside the host's pump like every other one, so the host still owns
    // the service and the provider both when the pump returns.
    const gpa = std.testing.allocator;
    var provider = Provider.init(gpa, std.testing.io);
    var service = notifications.NotificationsService.init(gpa, provider.provider());
    defer service.deinit();
    var owner: DrainingOwner = .{};
    try track(gpa, &service, &provider, 7, &owner);
    provider.push(refusedCompletion(7));

    try std.testing.expectEqual(@as(usize, 1), try service.pump(0));
    try std.testing.expectEqual(@as(usize, 1), owner.lost);
    try std.testing.expectEqual(@as(usize, 0), owner.actions);
    // A request the centre would not take is forgotten, so a later dismissal of
    // it reports a refusal instead of closing a notification nobody was shown.
    try std.testing.expect(!provider.posted.contains(7));
}

test "api-w23 macos a handler that shuts its service down leaves no answer waiting" {
    // The drain is built for this: the ring is emptied under the lock and
    // delivered outside it, so a handler that shuts the service down cannot
    // deadlock against the delivery that called it. That shutdown completes
    // every notification the service was tracking exactly once, and the answer
    // still buffered behind it reaches nobody.
    const gpa = std.testing.allocator;
    var provider = Provider.init(gpa, std.testing.io);
    var service = notifications.NotificationsService.init(gpa, provider.provider());
    // The host still owns the service here, so the shutdown is the whole of
    // what the handler did and the release stays with the test.
    defer service.deinit();
    var owner: DrainingOwner = .{ .service = &service, .teardown = .shutdown_service };
    try track(gpa, &service, &provider, 7, &owner);
    try track(gpa, &service, &provider, 8, &owner);
    provider.push(actionCompletion(7, "open"));
    provider.push(actionCompletion(8, "reply"));

    // How many answers the drain counts is its own business; what the host sees
    // is which owners heard what.
    _ = try service.pump(0);
    try std.testing.expectEqual(@as(usize, 1), owner.actions);
    try std.testing.expectEqual(@as(NotificationId, 7), owner.last_id);
    try std.testing.expectEqual(@as(usize, 1), owner.shutdowns);
    try std.testing.expectEqual(@as(usize, 2), owner.closes);
}

test "api-w23 macos an answer that arrives after detach reaches no owner" {
    // The shim reads its callback table on the main queue and clears that table
    // in the free, so an answer the framework queues after the host released
    // the centre finds nothing left to call. What this test drives is the gate
    // the host owns, by calling the three entry points directly: an answer that
    // arrives once the record is closed is refused on any thread. The
    // Objective-C queue that orders a table read against the free is macOS
    // behaviour, and a Linux run proves nothing about it.
    const gpa = std.testing.allocator;
    var provider = Provider.init(gpa, std.testing.io);
    var service = notifications.NotificationsService.init(gpa, provider.provider());
    defer service.deinit();
    var owner: DrainingOwner = .{};
    for ([_]NotificationId{ 7, 8, 9 }) |id| {
        try track(gpa, &service, &provider, id, &owner);
    }

    // While the centre is attached, an answer is the owner's.
    Provider.onAuthorization(@ptrCast(&provider), 2);
    Provider.onResponse(@ptrCast(&provider), "7".ptr, "opened".ptr);
    try std.testing.expectEqual(@as(usize, 1), try service.pump(0));
    try std.testing.expectEqual(@as(usize, 1), owner.actions);
    try std.testing.expectEqual(@as(NotificationId, 7), owner.last_id);
    try std.testing.expectEqualStrings("opened", owner.copiedKey());
    try std.testing.expectEqual(Authorization.authorized, provider.authorizationOf());

    // The host closes the centre. Off macOS there is no centre to free, which is
    // the state a completed free leaves behind: the delegate is released and the
    // record is closed.
    provider.detach();
    Provider.onResponse(@ptrCast(&provider), "8".ptr, "reply".ptr);
    Provider.onError(@ptrCast(&provider), "9".ptr, -1);
    Provider.onAuthorization(@ptrCast(&provider), 1);
    try std.testing.expectEqual(@as(usize, 0), try service.pump(0));
    try std.testing.expectEqual(@as(usize, 1), owner.actions);
    try std.testing.expectEqual(@as(usize, 0), owner.lost);
    try std.testing.expectEqual(@as(u32, 0), provider.droppedCompletions());
    // A closed provider keeps the answer it last reported instead of taking a
    // new one from a queue it no longer owns.
    try std.testing.expectEqual(Authorization.authorized, provider.authorizationOf());
    try std.testing.expectEqual(@as(i32, 2), provider.authorizationError());
}
