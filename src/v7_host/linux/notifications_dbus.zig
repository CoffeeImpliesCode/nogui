//! Real Linux notification provider for org.freedesktop.Notifications.
//!
//! Submit, replace, dismiss and capability queries are one D-Bus round trip
//! each. Action and close responses arrive later as bus signals, drained by
//! `poll` on the host thread; provider acceptance is therefore reported
//! separately from any user display or response.
//!
//! Each round trip waits for the answer that names it, so a signal the daemon
//! sends while a call is in flight is left for the next `poll` instead of
//! being read as that call's reply, and a call that races another call's
//! answer keeps its own.
//!
//! This adapter never blocks the caller for a response and never retains the
//! borrowed slices in `NotificationOptions` after `submit` returns. A lost
//! transport is final: the provider completes every waiting notification and
//! never opens a new bus connection on its own.
//!
//! An allocation that fails while a dead transport's frames are collected
//! reaches the host after that completion, never in place of it: the frames
//! it could not take are dropped and the provider is retired anyway.
//!
//! A call that comes back nothing at all is read the same way whether it was
//! a submit or a close: memory that ran out, a bus that is gone and a frame
//! this build cannot read each keep their own name, because a host can act on
//! one of them and only wait on another.
//!
//! A close reports what became of it. A refusal comes from a daemon that is
//! still showing the notification, while a bus that is gone, a reply that is
//! not a frame and an authorization refusal each name themselves instead. A
//! caller that reads a lost bus as a refusal waits on a notification nothing
//! will ever close.
const std = @import("std");
const dbus = @import("dbus.zig");
const notifications = @import("../notifications.zig");

const service_name = "org.freedesktop.Notifications";
const service_path = "/org/freedesktop/Notifications";
const signal_match = "type='signal',interface='org.freedesktop.Notifications'";

pub const DbusNotificationProvider = struct {
    allocator: std.mem.Allocator,
    conn: ?dbus.Connection = null,
    matched: bool = false,
    /// Set once the transport is gone for good. A provider that lost its
    /// connection is never reconnected, so a late native callback cannot
    /// reach the live daemon through a fresh connection.
    is_gone: bool = false,
    /// Cached `GetCapabilities` result; null until the first query.
    cached: ?notifications.Capabilities = null,

    pub fn init(allocator: std.mem.Allocator) DbusNotificationProvider {
        return .{ .allocator = allocator };
    }

    /// Adopt an already connected socket. Used by loopback tests and by hosts
    /// that share one bus connection between services.
    pub fn initWithConnection(allocator: std.mem.Allocator, conn: dbus.Connection) DbusNotificationProvider {
        return .{ .allocator = allocator, .conn = conn };
    }

    pub fn deinit(self: *DbusNotificationProvider) void {
        self.disconnect();
        self.* = undefined;
    }

    pub fn provider(self: *DbusNotificationProvider) notifications.NotificationProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Release the transport and latch the provider dead.
    ///
    /// `connect` is the only path back to a daemon. Nothing else reopens the
    /// bus, so a late host call that still holds this handle cannot reach a
    /// live notification service through a fresh connection.
    pub fn disconnect(self: *DbusNotificationProvider) void {
        self.is_gone = true;
        if (self.conn) |*c| {
            c.deinit();
            self.conn = null;
        }
        self.matched = false;
        self.cached = null;
    }

    /// Connect and subscribe to the daemon's signals. Returns
    /// `error.NoNotificationService` when no daemon owns the well-known name.
    /// This is the one path that revives a provider that lost its transport.
    pub fn connect(self: *DbusNotificationProvider) !void {
        self.is_gone = false;
        const c = try self.ensureConnected();
        if (!try c.nameHasOwner(service_name)) return error.NoNotificationService;
        try c.addMatch(signal_match);
        self.matched = true;
    }

    fn ensureConnected(self: *DbusNotificationProvider) !*dbus.Connection {
        if (self.is_gone) return error.ProviderGone;
        if (self.conn) |*c| return c;
        const c = try dbus.Connection.connectSessionBus(self.allocator);
        self.conn = c;
        return &self.conn.?;
    }

    const vtable: notifications.NotificationProvider.VTable = .{
        .submit = submitFn,
        .dismiss = dismissFn,
        .getCapabilities = getCapabilitiesFn,
        .disconnect = disconnectFn,
        .deinit = deinitFn,
        .poll = pollFn,
    };

    fn classify(reply: dbus.Message) notifications.SubmitOutcome {
        const name = reply.error_name orelse return .{ .provider_failed = .rejected };
        if (std.mem.eql(u8, name, "org.freedesktop.DBus.Error.ServiceUnknown")) return .unsupported;
        if (std.mem.indexOf(u8, name, "AccessDenied") != null) return .denied;
        return .{ .provider_failed = .rejected };
    }

    /// What a round trip that never came back names itself.
    ///
    /// A call is answered by the daemon, by nothing at all, or by a
    /// transport that could not hold the answer. Those are different facts
    /// for a host: memory that ran out, a bus that is gone, and a frame this
    /// build cannot read each say something the caller acts on differently.
    /// The reading is written once here so a submit and a dismissal cannot
    /// drift apart and report the same loss under two different names.
    fn classifyCallFailure(err: anyerror) notifications.ProviderError {
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
            // The bus socket is the only way to a daemon, so one that is
            // closed or has no peer is a lost provider, not a daemon that
            // said no.
            error.NotConnected, error.ConnectionClosed => .disconnected,
            // Bytes that are not a D-Bus frame at all, from a build that
            // cannot assemble one.
            error.UnsupportedEndianness,
            error.InvalidMessageType,
            error.UnsupportedProtocolVersion,
            error.MessageTooLarge,
            => .protocol_error,
            else => .io_error,
        };
    }

    fn submitFn(ctx: *anyopaque, options: notifications.NotificationOptions) notifications.SubmitOutcome {
        const self: *DbusNotificationProvider = @ptrCast(@alignCast(ctx));
        const c = self.ensureConnected() catch |err| return switch (err) {
            error.NoSessionBusAddress, error.UnsupportedBusAddress => .unsupported,
            else => .{ .provider_failed = .disconnected },
        };
        // The reply copy comes from the connection's allocator, so it goes
        // back through that one and not through this provider's.
        const reply_allocator = c.allocator;

        var b = dbus.MessageBuilder.init(self.allocator, .method_call, c.nextSerial());
        defer b.deinit();

        b.destination = service_name;
        b.path = service_path;
        b.interface = service_name;
        b.member = "Notify";
        b.signature = "susssasa{sv}i";

        const oom: notifications.SubmitOutcome = .{ .provider_failed = .out_of_memory };
        b.writeString(options.app_name orelse "nogui") catch return oom;
        b.writeU32(options.replaces_id orelse 0) catch return oom;
        b.writeString(options.icon orelse "") catch return oom;
        b.writeString(options.summary) catch return oom;
        b.writeString(options.body) catch return oom;

        // Actions are a flat key/label array; the default action uses "default".
        const actions_offset = b.startArray(4) catch return oom;
        for (options.actions) |act| {
            b.writeString(act.key) catch return oom;
            b.writeString(act.label) catch return oom;
        }
        b.finishArray(actions_offset);

        const hints_offset = b.startArray(8) catch return oom;
        tryAppendHint(&b, "urgency", "y", .{
            .byte = @backingInt(options.urgency),
        }) catch return oom;
        if (options.category) |category| {
            tryAppendHint(&b, "category", "s", .{ .text = category }) catch return oom;
        }
        if (options.sound) |sound| {
            tryAppendHint(&b, "sound-file", "s", .{ .text = sound }) catch return oom;
        }
        b.finishArray(hints_offset);

        b.writeI32(options.timeout_ms) catch return oom;

        const reply_bytes = c.call(&b) catch |err|
            return .{ .provider_failed = classifyCallFailure(err) };
        defer reply_allocator.free(reply_bytes);

        const reply = dbus.MessageParser.parse(reply_bytes) catch
            return .{ .provider_failed = .protocol_error };
        if (reply.msg_type == .error_reply) return classify(reply);
        if (reply.msg_type != .method_return) return .{ .provider_failed = .protocol_error };

        var reader = dbus.BodyReader.init(reply.body);
        return .{ .accepted = reader.readU32() catch return .{ .provider_failed = .protocol_error } };
    }

    const HintValue = union(enum) {
        byte: u8,
        text: []const u8,
    };

    fn tryAppendHint(b: *dbus.MessageBuilder, key: []const u8, signature: []const u8, value: HintValue) !void {
        try b.startStruct();
        try b.writeString(key);
        try b.writeSignature(signature);
        switch (value) {
            .byte => |raw| try b.writeByte(raw),
            .text => |text| try b.writeString(text),
        }
    }

    /// The daemon's own verdict on `CloseNotification`, which is not the same
    /// question its verdict on `Notify` answers.
    ///
    /// A live daemon that answered with an error refused the close, so the
    /// notification is still on screen and still tracked. A missing service is
    /// nothing to close at all, and an authorization refusal is a named
    /// provider failure: the daemon is there, it answered, and its answer was
    /// no.
    fn classifyDismiss(reply: dbus.Message) notifications.DismissOutcome {
        // ERROR_NAME is required on an error reply, so a frame without one is a
        // transport speaking something else rather than a daemon refusing.
        const name = reply.error_name orelse return .{ .provider_failed = .protocol_error };
        if (std.mem.eql(u8, name, "org.freedesktop.DBus.Error.ServiceUnknown")) return .unsupported;
        if (std.mem.indexOf(u8, name, "AccessDenied") != null) {
            return .{ .provider_failed = .permission_denied };
        }
        return .refused;
    }

    fn dismissFn(ctx: *anyopaque, id: notifications.NotificationId) notifications.DismissOutcome {
        const self: *DbusNotificationProvider = @ptrCast(@alignCast(ctx));
        const c = self.ensureConnected() catch |err| return switch (err) {
            error.NoSessionBusAddress, error.UnsupportedBusAddress => .unsupported,
            else => .{ .provider_failed = .disconnected },
        };
        // The reply copy comes from the connection's allocator, so it goes
        // back through that one and not through this provider's.
        const reply_allocator = c.allocator;

        var b = dbus.MessageBuilder.init(self.allocator, .method_call, c.nextSerial());
        defer b.deinit();

        b.destination = service_name;
        b.path = service_path;
        b.interface = service_name;
        b.member = "CloseNotification";
        b.signature = "u";
        b.writeU32(id) catch return .{ .provider_failed = .out_of_memory };

        const reply_bytes = c.call(&b) catch |err|
            return .{ .provider_failed = classifyCallFailure(err) };
        defer reply_allocator.free(reply_bytes);

        const reply = dbus.MessageParser.parse(reply_bytes) catch
            return .{ .provider_failed = .protocol_error };
        if (reply.msg_type == .error_reply) return classifyDismiss(reply);
        if (reply.msg_type != .method_return) return .{ .provider_failed = .protocol_error };
        return .closed;
    }

    fn getCapabilitiesFn(ctx: *anyopaque) notifications.Capabilities {
        const self: *DbusNotificationProvider = @ptrCast(@alignCast(ctx));
        if (self.cached) |known| return known;
        const c = self.ensureConnected() catch return .none;
        // The reply copy comes from the connection's allocator, so it goes
        // back through that one and not through this provider's.
        const reply_allocator = c.allocator;

        var b = dbus.MessageBuilder.init(self.allocator, .method_call, c.nextSerial());
        defer b.deinit();

        b.destination = service_name;
        b.path = service_path;
        b.interface = service_name;
        b.member = "GetCapabilities";

        const reply_bytes = c.call(&b) catch return .none;
        defer reply_allocator.free(reply_bytes);

        const reply = dbus.MessageParser.parse(reply_bytes) catch return .none;
        if (reply.msg_type != .method_return) return .none;

        var reader = dbus.BodyReader.init(reply.body);
        const names = reader.readArray(4) catch return .none;
        const capabilities = parseCapabilities(names);
        self.cached = capabilities;
        return capabilities;
    }

    pub fn parseCapabilities(names: []const u8) notifications.Capabilities {
        var capabilities: notifications.Capabilities = .none;

        var reader = dbus.BodyReader.init(names);
        while (reader.cursor < reader.bytes.len) {
            const name = reader.readString() catch break;
            if (std.mem.eql(u8, name, "body")) capabilities.body = true;
            if (std.mem.eql(u8, name, "body-hyperlinks")) capabilities.body_hyperlinks = true;
            if (std.mem.eql(u8, name, "body-markup")) capabilities.body_markup = true;
            if (std.mem.eql(u8, name, "body-images")) capabilities.body_images = true;
            if (std.mem.eql(u8, name, "actions")) capabilities.actions = true;
            if (std.mem.eql(u8, name, "action-icons")) capabilities.action_icons = true;
            if (std.mem.eql(u8, name, "sound")) capabilities.sound = true;
            if (std.mem.eql(u8, name, "persistence")) capabilities.persistence = true;
        }
        return capabilities;
    }

    fn disconnectFn(ctx: *anyopaque) void {
        const self: *DbusNotificationProvider = @ptrCast(@alignCast(ctx));
        self.disconnect();
    }

    fn deinitFn(ctx: *anyopaque) void {
        const self: *DbusNotificationProvider = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    /// Drain available daemon signals and route them to the service.
    /// `timeout_ms` of 0 never blocks. Returns the number of routed signals.
    ///
    /// A transport that dies mid-drain still delivers the frames the daemon
    /// already sent, then completes every notification that is still waiting
    /// for a user answer with the typed provider result. The connection is
    /// never reopened: a signal that arrives after this cannot reach an owner.
    ///
    /// An allocation that fails while a frame is copied or a list is grown
    /// never decides the fate of the frames that were copied. They are routed
    /// first and the failure is reported after, on both paths: a live
    /// transport keeps its provider, and a dead one is retired with every
    /// waiting owner completed, because a provider that stays live only
    /// because an allocation failed is a host waiting on answers that can no
    /// longer arrive. What the caller loses is the frame the drain could not
    /// take, not the frames it already has.
    pub fn poll(self: *DbusNotificationProvider, service: *notifications.NotificationsService, timeout_ms: i32) !usize {
        // Every frame in this list was copied by the connection, with the
        // allocator that connection was built on, and it is released with
        // that same one. A host that adopts a connection belonging to another
        // service must not have its frames, or the list holding them, freed
        // through this provider's allocator.
        const copy_allocator: std.mem.Allocator = if (self.conn) |*c| c.allocator else self.allocator;
        var messages: std.ArrayList([]u8) = .empty;
        defer {
            for (messages.items) |message| copy_allocator.free(message);
            messages.deinit(copy_allocator);
        }

        var lost = false;
        // A frame the copy or the list could not hold. Reported at the end of
        // this scope, after a dead provider has been retired.
        var oom = false;
        if (self.conn) |*c| {
            // A stream that faulted cannot be resynchronized, so every
            // transport error drops the provider rather than one message. That
            // includes a staged frame that is not a D-Bus frame: the drain
            // reports it here rather than dropping it, so a live transport
            // never keeps draining a stream it cannot read.
            if (c.drainAvailable(timeout_ms, &messages)) |drained| {
                // A live transport drained what it had. The count is the
                // frames the daemon sent, not the frames the service took, so
                // it is not what `poll` reports.
                _ = drained;
            } else |err| switch (err) {
                // The frames this drain did copy are answers the daemon has
                // already sent and the service can still take, so they are
                // routed below. The transport is not lost here and the
                // provider stays for the next poll; what the host loses is
                // the frame that could not be copied, not the ones it got.
                error.OutOfMemory => oom = true,
                else => {
                    lost = true;
                    // The failed drain gave up before it copied what it had
                    // already staged, so that is where the rest comes from.
                    drainBufferedAfterLoss(c.allocator, c, &messages) catch |copy_err| switch (copy_err) {
                        error.OutOfMemory => oom = true,
                    };
                },
            }
        }

        // `c` is out of scope here: a routed response may shut the service
        // down and close the connection under the loop.
        var routed: usize = 0;
        for (messages.items) |message| {
            const parsed = dbus.MessageParser.parse(message) catch continue;
            if (route(parsed, service)) routed += 1;
        }

        if (lost) {
            // Whatever the last drain cost, a lost transport is final and
            // every notification still waiting for a user answer completes.
            self.disconnect();
            service.handleProviderDisconnect();
        }
        if (oom) return error.OutOfMemory;
        return routed;
    }

    /// The drain behind the provider contract, so a host that handed the
    /// provider to a service needs no reference to it and no downcast: pumping
    /// the service is the whole of what a host has to do.
    fn pollFn(
        ctx: *anyopaque,
        service: *notifications.NotificationsService,
        timeout_ms: i32,
    ) anyerror!usize {
        const self: *DbusNotificationProvider = @ptrCast(@alignCast(ctx));
        return self.poll(service, timeout_ms);
    }

    /// Collect every complete frame a failed transport had already buffered.
    ///
    /// The drain that gave up cannot synchronize the stream, so what the
    /// daemon already sent is read from the staging buffer. This runs only
    /// once the transport is already lost, which is why bytes it cannot parse
    /// are the end of what it can still offer rather than a second transport
    /// fault: there is no live connection left to retire. A frame this list
    /// cannot take is released here, because this scope is the only owner of
    /// the copy, and `error.OutOfMemory` reports the loss instead of counting
    /// a frame that nobody will route.
    fn drainBufferedAfterLoss(
        allocator: std.mem.Allocator,
        c: *dbus.Connection,
        out: *std.ArrayList([]u8),
    ) !void {
        while (true) {
            // `nextBuffered` answers with an optional frame inside an error
            // union, so the two are unwrapped apart: a fault ends the drain,
            // and a null frame is the normal end of it.
            var staged: ?[]u8 = null;
            if (c.nextBuffered()) |frames| {
                staged = frames;
            } else |err| switch (err) {
                // Only a failed allocation is reported to the caller. Bytes a
                // dead stream cannot parse are the end of what it can still
                // offer rather than a second transport failure, and the
                // connection wipes them with the rest of its staging buffer.
                error.OutOfMemory => return error.OutOfMemory,
                else => return,
            }
            // Nothing complete is left in the staging buffer, so the drain is
            // finished rather than failed.
            const message = staged orelse return;
            // The copy belongs to the list from the append onwards, and to
            // this scope until then.
            errdefer allocator.free(message);
            try out.append(allocator, message);
        }
    }

    /// Route one daemon signal. Returns true when the service took it. The
    /// action key borrows from the message, so it is only valid for the
    /// delivery.
    fn route(message: dbus.Message, service: *notifications.NotificationsService) bool {
        if (message.msg_type != .signal) return false;
        if (message.interface == null or
            !std.mem.eql(u8, message.interface.?, "org.freedesktop.Notifications")) return false;

        var reader = dbus.BodyReader.init(message.body);
        if (std.mem.eql(u8, message.member orelse "", "ActionInvoked")) {
            const id = reader.readU32() catch return false;
            const key = reader.readString() catch return false;
            service.handleResponse(id, .{ .action = .{ .key = key } });
            return true;
        }
        if (std.mem.eql(u8, message.member orelse "", "NotificationClosed")) {
            const id = reader.readU32() catch return false;
            const raw = reader.readU32() catch return false;
            const reason: notifications.CloseReason = switch (raw) {
                1 => .expired,
                2 => .dismissed_by_user,
                3 => .closed_by_call,
                else => .undefined,
            };
            service.handleResponse(id, .{ .closed = .{ .reason = reason } });
            return true;
        }
        return false;
    }
};

test "api-w19 dbus capability names map to reported capabilities" {
    var builder = dbus.MessageBuilder.init(std.testing.allocator, .method_return, 1);
    defer builder.deinit();
    const offset = try builder.startArray(4);
    try builder.writeString("body");
    try builder.writeString("actions");
    try builder.writeString("persistence");
    try builder.writeString("not-a-real-capability");
    builder.finishArray(offset);

    const wire = try builder.build();
    defer std.testing.allocator.free(wire);

    const parsed = try dbus.MessageParser.parse(wire);
    var reader = dbus.BodyReader.init(parsed.body);
    const capabilities = DbusNotificationProvider.parseCapabilities(reader.readArray(4) catch return error.MissingBody);

    try std.testing.expect(capabilities.body);
    try std.testing.expect(capabilities.actions);
    try std.testing.expect(capabilities.persistence);
    try std.testing.expect(!capabilities.body_markup);
    try std.testing.expect(!capabilities.sound);
}
