//! Real Linux Secret Service provider over D-Bus.
//! Talks to org.freedesktop.secrets via Unix domain socket without external C libraries.
const std = @import("std");
const dbus = @import("dbus.zig");
const credentials = @import("../credentials.zig");

/// The daemon answers a prompt with a `Completed` signal on this interface.
/// The interface and the object path together are what identify which
/// prompt a completion belongs to.
const prompt_interface = "org.freedesktop.Secret.Prompt";

pub const SecretServiceCredentialProvider = struct {
    allocator: std.mem.Allocator,
    conn: ?dbus.Connection = null,
    session_path: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) SecretServiceCredentialProvider {
        return .{
            .allocator = allocator,
            .conn = null,
            .session_path = null,
        };
    }

    pub fn initWithConnection(allocator: std.mem.Allocator, conn: dbus.Connection) SecretServiceCredentialProvider {
        return .{
            .allocator = allocator,
            .conn = conn,
            .session_path = null,
        };
    }

    pub fn deinit(self: *SecretServiceCredentialProvider) void {
        self.disconnect();
        self.* = undefined;
    }

    pub fn disconnect(self: *SecretServiceCredentialProvider) void {
        if (self.session_path) |sp| {
            self.allocator.free(sp);
            self.session_path = null;
        }
        if (self.conn) |*c| {
            c.deinit();
            self.conn = null;
        }
    }

    pub fn provider(self: *SecretServiceCredentialProvider) credentials.CredentialProvider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn ensureConnected(self: *SecretServiceCredentialProvider) !*dbus.Connection {
        if (self.conn) |*c| return c;
        const c = try dbus.Connection.connectSessionBus(self.allocator);
        self.conn = c;
        return &self.conn.?;
    }

    /// Zero a frame the connection copied for us, then hand it back to the
    /// allocator that made it. A reply belongs to the connection that read
    /// it, so releasing it through the provider's allocator would be a
    /// release of memory this provider never handed out.
    fn releaseFrame(c: *dbus.Connection, frame: []u8) void {
        if (frame.len != 0) std.crypto.secureZero(u8, frame);
        c.allocator.free(frame);
    }

    /// D-Bus error names classify into distinct outcomes: a locked store, a
    /// denial from the user or the bus, an absent service, an object the
    /// store does not have, or a provider failure. None of them may degrade
    /// into a missing password or a successful write.
    const ErrorClass = union(enum) {
        locked,
        denied,
        unsupported,
        /// The store answered, and the object path this call named is not
        /// one it holds: a collection the daemon does not have, an alias it
        /// never resolved, an item that went away between the search and the
        /// call. That is a fact about the store, not about a fault it
        /// reports, so it keeps an outcome of its own.
        no_object,
        /// A refusal the daemon named that has no rule here of its own. It
        /// stays a refusal, and `rejected` is the outcome that says so.
        unrecognized,
        failed: credentials.ProviderError,
    };

    /// One rule per distinguishable error name. A name with no rule falls to
    /// `unrecognized` rather than onto a rule that was meant for another
    /// name, so a missing object and an unknown name never read the same.
    fn classify(self: *SecretServiceCredentialProvider, reply: dbus.Message) ErrorClass {
        _ = self;
        const name = reply.error_name orelse return .unrecognized;
        if (std.mem.eql(u8, name, "org.freedesktop.Secret.Error.IsLocked")) return .locked;
        if (std.mem.indexOf(u8, name, "AccessDenied") != null) return .denied;
        if (std.mem.indexOf(u8, name, "PermissionDenied") != null) return .denied;
        // A refused unlock password or prompt identity is a denial, not a
        // provider fault the caller could retry.
        if (std.mem.indexOf(u8, name, "AuthFailed") != null) return .denied;
        // The store is there and it says the object is not. The bus names
        // that once as the Secret Service error and once as its own, and both
        // say the same thing about a missing collection.
        if (std.mem.indexOf(u8, name, "NoSuchObject") != null) return .no_object;
        if (std.mem.indexOf(u8, name, "UnknownObject") != null) return .no_object;
        // The session this provider opened is not one the store knows, so it
        // cannot serve the call either.
        if (std.mem.indexOf(u8, name, "NoSession") != null) return .{ .failed = .daemon_unavailable };
        // Refusals the store names as its own. They are a refusal, and
        // `rejected` is the outcome that says so.
        if (std.mem.indexOf(u8, name, "AlreadyExists") != null) return .{ .failed = .rejected };
        if (std.mem.indexOf(u8, name, "LimitsExceeded") != null) return .{ .failed = .rejected };
        // Nothing is listening under a name the store would answer to.
        if (std.mem.indexOf(u8, name, "ServiceUnknown") != null) return .unsupported;
        if (std.mem.indexOf(u8, name, "NameHasNoOwner") != null) return .unsupported;
        if (std.mem.indexOf(u8, name, "NoKeyringDaemon") != null) return .unsupported;
        if (std.mem.indexOf(u8, name, "NotSupported") != null) return .unsupported;
        if (std.mem.indexOf(u8, name, "Disconnected") != null) return .{ .failed = .disconnected };
        if (std.mem.indexOf(u8, name, "NoReply") != null) return .{ .failed = .disconnected };
        if (std.mem.indexOf(u8, name, "Timeout") != null) return .{ .failed = .timeout };
        // The store does not know what the call asked for, so the call and
        // the store do not agree on the protocol between them.
        if (std.mem.indexOf(u8, name, "InvalidArgs") != null) return .{ .failed = .protocol_error };
        if (std.mem.indexOf(u8, name, "UnknownMethod") != null) return .{ .failed = .protocol_error };
        if (std.mem.indexOf(u8, name, "UnknownInterface") != null) return .{ .failed = .protocol_error };
        if (std.mem.indexOf(u8, name, "UnknownProperty") != null) return .{ .failed = .protocol_error };
        // The store answered, and could not reach the file behind it.
        if (std.mem.indexOf(u8, name, "FileNotFound") != null) return .{ .failed = .io_error };
        return .unrecognized;
    }

    fn readError(self: *SecretServiceCredentialProvider, reply: dbus.Message) credentials.ReadResult {
        return switch (self.classify(reply)) {
            .locked => .locked,
            .denied => .denied,
            .unsupported => .unsupported,
            // The collection or the item this read named is not in the
            // store, which is not a missing password.
            .no_object => .{ .provider_failed = .daemon_unavailable },
            .unrecognized => .{ .provider_failed = .rejected },
            .failed => |other| .{ .provider_failed = other },
        };
    }

    fn writeError(self: *SecretServiceCredentialProvider, reply: dbus.Message) credentials.WriteResult {
        return switch (self.classify(reply)) {
            .locked => .locked,
            .denied => .denied,
            .unsupported => .unsupported,
            // The collection this write named is not in the store, and a
            // refused write is never a stored secret.
            .no_object => .{ .provider_failed = .daemon_unavailable },
            .unrecognized => .{ .provider_failed = .rejected },
            .failed => |other| .{ .provider_failed = other },
        };
    }

    fn deleteError(self: *SecretServiceCredentialProvider, reply: dbus.Message) credentials.DeleteResult {
        return switch (self.classify(reply)) {
            .locked => .locked,
            .denied => .denied,
            .unsupported => .unsupported,
            // The item this delete named is not in the store, which is not a
            // successful delete either.
            .no_object => .{ .provider_failed = .daemon_unavailable },
            .unrecognized => .{ .provider_failed = .rejected },
            .failed => |other| .{ .provider_failed = other },
        };
    }

    fn ensureSession(self: *SecretServiceCredentialProvider) ![]const u8 {
        if (self.session_path) |sp| return sp;
        const c = try self.ensureConnected();

        const serial = c.nextSerial();
        var b = dbus.MessageBuilder.init(self.allocator, .method_call, serial);
        defer b.deinit();

        b.destination = "org.freedesktop.secrets";
        b.path = "/org/freedesktop/secrets";
        b.interface = "org.freedesktop.Secret.Service";
        b.member = "OpenSession";
        b.signature = "sv";

        try b.writeString("plain");
        try b.writeSignature("s");
        try b.writeString("");

        // The call waits for the frame that names its own serial. A signal
        // or another call's answer that arrives first belongs to somebody
        // else, and it stays staged rather than being taken as this reply.
        const reply_bytes = try c.call(&b);
        defer releaseFrame(c, reply_bytes);

        const reply = try dbus.MessageParser.parse(reply_bytes);
        if (reply.msg_type != .method_return) return error.OpenSessionFailed;

        var reader = dbus.BodyReader.init(reply.body);
        // OpenSession returns (v output, o session), not a variant path.
        // The negotiated plain algorithm carries an empty string output.
        const variant = try reader.readSignature();
        if (!std.mem.eql(u8, variant, "s")) return error.OpenSessionAlgorithmRejected;
        if ((try reader.readString()).len != 0) return error.OpenSessionAlgorithmRejected;
        self.session_path = try self.allocator.dupe(u8, try reader.readObjectPath());
        return self.session_path.?;
    }

    const vtable: credentials.CredentialProvider.VTable = .{
        .read = readFn,
        .write = writeFn,
        .delete = deleteFn,
        .disconnect = disconnectFn,
        .deinit = deinitFn,
    };

    fn readFn(
        allocator: std.mem.Allocator,
        ctx: *anyopaque,
        query: credentials.CredentialQuery,
        cancel_token: ?*const credentials.CancellationToken,
    ) credentials.ReadResult {
        const self: *SecretServiceCredentialProvider = @ptrCast(@alignCast(ctx));
        if (cancel_token) |t| {
            if (t.isCanceled()) return .canceled;
        }

        const sess = self.ensureSession() catch |err| {
            return switch (err) {
                error.NoSessionBusAddress, error.UnsupportedBusAddress => .unsupported,
                else => .{ .provider_failed = .disconnected },
            };
        };

        const c = if (self.conn) |*conn| conn else return .{ .provider_failed = .disconnected };

        // 1. Search items
        const search = self.searchItems(c, query, cancel_token);
        const matched = switch (search) {
            .matched => |found| found,
            .locked => return .locked,
            .denied => return .denied,
            .unsupported => return .unsupported,
            .canceled => return .canceled,
            .failed => |other| return .{ .provider_failed = other },
        };
        defer SearchOutcome.deinit(self.allocator, matched);

        // Only an empty match list is a missing password. A locked store, a
        // denial and a lost connection each keep their own outcome.
        const item_path = switch (self.resolveItem(c, matched, cancel_token)) {
            .missing => return .not_found,
            .item => |path| path,
            .prompt_dismissed => return .prompt_dismissed,
            .denied => return .denied,
            .locked => return .locked,
            .canceled => return .canceled,
            .failed => |other| return .{ .provider_failed = other },
        };

        // 2. GetSecret
        if (cancel_token) |t| {
            if (t.isCanceled()) return .canceled;
        }

        const serial = c.nextSerial();
        var b = dbus.MessageBuilder.init(self.allocator, .method_call, serial);
        defer b.deinit();

        b.destination = "org.freedesktop.secrets";
        b.path = item_path;
        b.interface = "org.freedesktop.Secret.Item";
        b.member = "GetSecret";
        b.signature = "o";

        b.writeObjectPath(sess) catch return .{ .provider_failed = .out_of_memory };

        // The reply carries the secret, so it is zeroed before it goes back
        // to the allocator that copied it.
        const reply_bytes = c.call(&b) catch return .{ .provider_failed = .io_error };
        defer releaseFrame(c, reply_bytes);

        const reply = dbus.MessageParser.parse(reply_bytes) catch return .{ .provider_failed = .protocol_error };
        if (reply.msg_type == .error_reply) return self.readError(reply);
        if (reply.msg_type != .method_return) return .{ .provider_failed = .protocol_error };

        // The reply is one Secret struct: session, parameters, value, content type.
        var reader = dbus.BodyReader.init(reply.body);
        reader.alignStruct();
        _ = reader.readObjectPath() catch return .{ .provider_failed = .protocol_error };
        _ = reader.readArray(1) catch return .{ .provider_failed = .protocol_error };
        const secret_bytes = reader.readArray(1) catch return .{ .provider_failed = .protocol_error };
        _ = reader.readString() catch return .{ .provider_failed = .protocol_error };

        return .{ .found = credentials.CredentialValue.init(allocator, secret_bytes) catch
            return .{ .provider_failed = .out_of_memory } };
    }

    fn writeFn(
        ctx: *anyopaque,
        query: credentials.CredentialQuery,
        secret: []const u8,
        cancel_token: ?*const credentials.CancellationToken,
    ) credentials.WriteResult {
        const self: *SecretServiceCredentialProvider = @ptrCast(@alignCast(ctx));
        if (cancel_token) |t| {
            if (t.isCanceled()) return .canceled;
        }

        const sess = self.ensureSession() catch |err| {
            return switch (err) {
                error.NoSessionBusAddress, error.UnsupportedBusAddress => .unsupported,
                else => .{ .provider_failed = .disconnected },
            };
        };

        const c = if (self.conn) |*conn| conn else return .{ .provider_failed = .disconnected };

        const coll_path = query.collection orelse "/org/freedesktop/secrets/aliases/default";

        const serial = c.nextSerial();
        var b = dbus.MessageBuilder.init(self.allocator, .method_call, serial);
        defer b.deinit();
        // The plaintext secret goes into the body below, so every exit from
        // this function wipes it and not only the success path. The wipe
        // runs before `b.deinit` releases the body.
        defer std.crypto.secureZero(u8, b.body.items);

        b.destination = "org.freedesktop.secrets";
        b.path = coll_path;
        b.interface = "org.freedesktop.Secret.Collection";
        b.member = "CreateItem";
        b.signature = "a{sv}(oayays)b";

        // Properties a{sv}
        const props_offset = b.startArray(8) catch return .{ .provider_failed = .out_of_memory };

        // Label
        b.startStruct() catch return .{ .provider_failed = .out_of_memory };
        b.writeString("org.freedesktop.Secret.Item.Label") catch return .{ .provider_failed = .out_of_memory };
        b.writeSignature("s") catch return .{ .provider_failed = .out_of_memory };
        b.writeString("nogui credential") catch return .{ .provider_failed = .out_of_memory };

        // Attributes a{ss}
        b.startStruct() catch return .{ .provider_failed = .out_of_memory };
        b.writeString("org.freedesktop.Secret.Item.Attributes") catch return .{ .provider_failed = .out_of_memory };
        b.writeSignature("a{ss}") catch return .{ .provider_failed = .out_of_memory };
        const attrs_offset = b.startArray(8) catch return .{ .provider_failed = .out_of_memory };

        b.startStruct() catch return .{ .provider_failed = .out_of_memory };
        b.writeString("service") catch return .{ .provider_failed = .out_of_memory };
        b.writeString(query.service) catch return .{ .provider_failed = .out_of_memory };

        b.startStruct() catch return .{ .provider_failed = .out_of_memory };
        b.writeString("account") catch return .{ .provider_failed = .out_of_memory };
        b.writeString(query.account) catch return .{ .provider_failed = .out_of_memory };

        b.finishArray(attrs_offset);
        b.finishArray(props_offset);

        // Secret struct (oayays)
        b.startStruct() catch return .{ .provider_failed = .out_of_memory };
        b.writeObjectPath(sess) catch return .{ .provider_failed = .out_of_memory };
        // parameters ay
        const params_offset = b.startArray(1) catch return .{ .provider_failed = .out_of_memory };
        b.finishArray(params_offset);
        // Writing the secret one byte at a time makes the builder grow its
        // body repeatedly, and every growth releases the block that already
        // holds part of the plaintext. Reserving the rest of the message
        // first keeps the secret in one buffer for the wipe to cover.
        b.body.ensureTotalCapacity(self.allocator, b.body.items.len + secret.len + 64) catch
            return .{ .provider_failed = .out_of_memory };
        // value ay
        const val_offset = b.startArray(1) catch return .{ .provider_failed = .out_of_memory };
        for (secret) |byte| {
            b.writeByte(byte) catch return .{ .provider_failed = .out_of_memory };
        }
        b.finishArray(val_offset);
        // content_type s
        b.writeString("text/plain; charset=utf8") catch return .{ .provider_failed = .out_of_memory };

        // replace b
        b.writeBool(true) catch return .{ .provider_failed = .out_of_memory };

        // The wire the call builds and sends is the connection's to release
        // and wipe; this provider never sees it. The builder body above is
        // still this function's to wipe on the way out.
        const reply_bytes = c.call(&b) catch return .{ .provider_failed = .io_error };
        defer releaseFrame(c, reply_bytes);

        const reply = dbus.MessageParser.parse(reply_bytes) catch return .{ .provider_failed = .protocol_error };
        if (reply.msg_type == .error_reply) return self.writeError(reply);
        if (reply.msg_type != .method_return) return .{ .provider_failed = .protocol_error };

        var reader = dbus.BodyReader.init(reply.body);
        _ = reader.readObjectPath() catch return .{ .provider_failed = .protocol_error };
        const prompt_path = reader.readObjectPath() catch return .{ .provider_failed = .protocol_error };

        if (!std.mem.eql(u8, prompt_path, "/")) {
            // A prompt the user answered is the only path to a written
            // credential. Every other answer keeps its own outcome so a
            // dismissal or a refusal is never reported as a stored secret.
            switch (self.handlePrompt(c, prompt_path, cancel_token) catch
                return .{ .provider_failed = .protocol_error }) {
                .accepted => {},
                .dismissed => return .prompt_dismissed,
                .denied => return .denied,
                .locked => return .locked,
                .canceled => return .canceled,
                .failed => |other| return .{ .provider_failed = other },
            }
        }

        return .success;
    }

    fn deleteFn(
        ctx: *anyopaque,
        query: credentials.CredentialQuery,
        cancel_token: ?*const credentials.CancellationToken,
    ) credentials.DeleteResult {
        const self: *SecretServiceCredentialProvider = @ptrCast(@alignCast(ctx));
        if (cancel_token) |t| {
            if (t.isCanceled()) return .canceled;
        }

        _ = self.ensureSession() catch |err| {
            return switch (err) {
                error.NoSessionBusAddress, error.UnsupportedBusAddress => .unsupported,
                else => .{ .provider_failed = .disconnected },
            };
        };

        const c = if (self.conn) |*conn| conn else return .{ .provider_failed = .disconnected };

        const search = self.searchItems(c, query, cancel_token);
        const matched = switch (search) {
            .matched => |found| found,
            .locked => return .locked,
            .denied => return .denied,
            .unsupported => return .unsupported,
            .canceled => return .canceled,
            .failed => |other| return .{ .provider_failed = other },
        };
        defer SearchOutcome.deinit(self.allocator, matched);

        // Only an empty match list means there is nothing to delete. A locked
        // store, a denial and a lost connection each keep their own outcome.
        const item_path = switch (self.resolveItem(c, matched, cancel_token)) {
            .missing => return .not_found,
            .item => |path| path,
            .prompt_dismissed => return .prompt_dismissed,
            .denied => return .denied,
            .locked => return .locked,
            .canceled => return .canceled,
            .failed => |other| return .{ .provider_failed = other },
        };

        const serial = c.nextSerial();
        var b = dbus.MessageBuilder.init(self.allocator, .method_call, serial);
        defer b.deinit();

        b.destination = "org.freedesktop.secrets";
        b.path = item_path;
        b.interface = "org.freedesktop.Secret.Item";
        b.member = "Delete";

        const reply_bytes = c.call(&b) catch return .{ .provider_failed = .io_error };
        defer releaseFrame(c, reply_bytes);

        const reply = dbus.MessageParser.parse(reply_bytes) catch return .{ .provider_failed = .protocol_error };
        if (reply.msg_type == .error_reply) return self.deleteError(reply);
        if (reply.msg_type != .method_return) return .{ .provider_failed = .protocol_error };

        var reader = dbus.BodyReader.init(reply.body);
        const prompt_path = reader.readObjectPath() catch return .{ .provider_failed = .protocol_error };

        if (!std.mem.eql(u8, prompt_path, "/")) {
            // Only a prompt the user accepted deletes the item. Every other
            // answer keeps its own outcome, so a dismissal is never a
            // successful delete.
            switch (self.handlePrompt(c, prompt_path, cancel_token) catch
                return .{ .provider_failed = .protocol_error }) {
                .accepted => {},
                .dismissed => return .prompt_dismissed,
                .denied => return .denied,
                .locked => return .locked,
                .canceled => return .canceled,
                .failed => |other| return .{ .provider_failed = other },
            }
        }

        return .success;
    }

    fn disconnectFn(ctx: *anyopaque) void {
        const self: *SecretServiceCredentialProvider = @ptrCast(@alignCast(ctx));
        self.disconnect();
    }

    fn deinitFn(ctx: *anyopaque) void {
        const self: *SecretServiceCredentialProvider = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    /// The two object-path lists `SearchItems` returns. The caller owns
    /// them and releases them with `deinit`.
    const SearchOutcome = struct {
        unlocked: [][]u8,
        locked: [][]u8,

        fn deinit(allocator: std.mem.Allocator, self: SearchOutcome) void {
            releasePaths(allocator, self.unlocked);
            releasePaths(allocator, self.locked);
        }
    };

    /// What a search produced, or the typed refusal that stopped it.
    ///
    /// An empty `matched` list is the only missing credential. A refused
    /// search never becomes one, so a locked store, a denial and a lost
    /// connection keep their own outcome all the way to the caller.
    const SearchResult = union(enum) {
        matched: SearchOutcome,
        locked,
        denied,
        unsupported,
        canceled,
        failed: credentials.ProviderError,
    };

    fn fromClass(class: ErrorClass) SearchResult {
        return switch (class) {
            .locked => .locked,
            .denied => .denied,
            .unsupported => .unsupported,
            // A refused search is never an empty match, and an object the
            // store does not hold is not a match either.
            .no_object => .{ .failed = .daemon_unavailable },
            .unrecognized => .{ .failed = .rejected },
            .failed => |other| .{ .failed = other },
        };
    }

    fn releasePaths(allocator: std.mem.Allocator, paths: [][]u8) void {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }

    /// The item a call can act on, or the typed refusal that stopped it.
    /// The path borrows from the caller's `SearchOutcome`.
    const ItemResolution = union(enum) {
        missing,
        item: []const u8,
        prompt_dismissed,
        denied,
        locked,
        canceled,
        failed: credentials.ProviderError,
    };

    fn searchItems(
        self: *SecretServiceCredentialProvider,
        c: *dbus.Connection,
        query: credentials.CredentialQuery,
        cancel_token: ?*const credentials.CancellationToken,
    ) SearchResult {
        if (cancel_token) |t| {
            if (t.isCanceled()) return .canceled;
        }

        const serial = c.nextSerial();
        var b = dbus.MessageBuilder.init(self.allocator, .method_call, serial);
        defer b.deinit();

        b.destination = "org.freedesktop.secrets";
        b.path = "/org/freedesktop/secrets";
        b.interface = "org.freedesktop.Secret.Service";
        b.member = "SearchItems";
        b.signature = "a{ss}";

        const array_offset = b.startArray(8) catch return .{ .failed = .out_of_memory };

        b.startStruct() catch return .{ .failed = .out_of_memory };
        b.writeString("service") catch return .{ .failed = .out_of_memory };
        b.writeString(query.service) catch return .{ .failed = .out_of_memory };

        b.startStruct() catch return .{ .failed = .out_of_memory };
        b.writeString("account") catch return .{ .failed = .out_of_memory };
        b.writeString(query.account) catch return .{ .failed = .out_of_memory };

        b.finishArray(array_offset);

        const reply_bytes = c.call(&b) catch return .{ .failed = .io_error };
        defer releaseFrame(c, reply_bytes);

        const reply = dbus.MessageParser.parse(reply_bytes) catch
            return .{ .failed = .protocol_error };
        // A refused search is not an empty match. The daemon's own error
        // name decides which outcome the caller sees.
        if (reply.msg_type == .error_reply) return fromClass(self.classify(reply));
        if (reply.msg_type != .method_return) return .{ .failed = .protocol_error };

        var reader = dbus.BodyReader.init(reply.body);
        const unlocked = self.readObjectPaths(&reader) catch |err| return pathError(err);
        errdefer releasePaths(self.allocator, unlocked);
        const locked = self.readObjectPaths(&reader) catch |err| return pathError(err);

        return .{ .matched = .{ .unlocked = unlocked, .locked = locked } };
    }

    fn pathError(err: error{ MalformedReply, OutOfMemory }) SearchResult {
        return .{ .failed = if (err == error.OutOfMemory) .out_of_memory else .protocol_error };
    }

    /// Copy one `ao` array of object paths out of a reply body.
    fn readObjectPaths(
        self: *SecretServiceCredentialProvider,
        reader: *dbus.BodyReader,
    ) error{ MalformedReply, OutOfMemory }![][]u8 {
        const slice = reader.readArray(4) catch return error.MalformedReply;
        var sub = dbus.BodyReader.init(slice);

        var paths: std.ArrayList([]u8) = .empty;
        errdefer {
            for (paths.items) |path| self.allocator.free(path);
            paths.deinit(self.allocator);
        }

        while (sub.cursor < sub.bytes.len) {
            const path = sub.readObjectPath() catch return error.MalformedReply;
            const owned = self.allocator.dupe(u8, path) catch return error.OutOfMemory;
            paths.append(self.allocator, owned) catch {
                self.allocator.free(owned);
                return error.OutOfMemory;
            };
        }
        return paths.toOwnedSlice(self.allocator);
    }

    /// Pick the item to act on. An item that is already unlocked needs no
    /// prompt; one that is locked needs a user answer first, and every way
    /// that can go wrong keeps its own outcome.
    fn resolveItem(
        self: *SecretServiceCredentialProvider,
        c: *dbus.Connection,
        matched: SearchOutcome,
        cancel_token: ?*const credentials.CancellationToken,
    ) ItemResolution {
        if (matched.unlocked.len > 0) return .{ .item = matched.unlocked[0] };
        if (matched.locked.len == 0) return .missing;

        if (cancel_token) |token| {
            if (token.isCanceled()) return .canceled;
        }

        return switch (self.unlockObject(c, matched.locked[0], cancel_token) catch
            return .{ .failed = .protocol_error }) {
            .unlocked => |path| .{ .item = path },
            .prompt_dismissed => .prompt_dismissed,
            .denied => .denied,
            .locked => .locked,
            .canceled => .canceled,
            .failed => |other| .{ .failed = other },
        };
    }

    const UnlockOutcome = union(enum) {
        unlocked: []const u8,
        prompt_dismissed,
        denied,
        canceled,
        locked,
        failed: credentials.ProviderError,
    };

    fn unlockObject(
        self: *SecretServiceCredentialProvider,
        c: *dbus.Connection,
        obj_path: []const u8,
        cancel_token: ?*const credentials.CancellationToken,
    ) !UnlockOutcome {
        const serial = c.nextSerial();
        var b = dbus.MessageBuilder.init(self.allocator, .method_call, serial);
        defer b.deinit();

        b.destination = "org.freedesktop.secrets";
        b.path = "/org/freedesktop/secrets";
        b.interface = "org.freedesktop.Secret.Service";
        b.member = "Unlock";
        b.signature = "ao";

        const arr_offset = try b.startArray(4);
        try b.writeObjectPath(obj_path);
        b.finishArray(arr_offset);

        const reply_bytes = c.call(&b) catch return .{ .failed = .io_error };
        defer releaseFrame(c, reply_bytes);

        const reply = dbus.MessageParser.parse(reply_bytes) catch
            return .{ .failed = .protocol_error };
        if (reply.msg_type == .error_reply) return self.unlockError(reply);
        if (reply.msg_type != .method_return) return .{ .failed = .protocol_error };

        var reader = dbus.BodyReader.init(reply.body);
        const unlocked_slice = reader.readArray(4) catch
            return .{ .failed = .protocol_error };
        const prompt_path = reader.readObjectPath() catch
            return .{ .failed = .protocol_error };

        if (unlocked_slice.len > 0) {
            return .{ .unlocked = obj_path };
        }

        if (!std.mem.eql(u8, prompt_path, "/")) {
            return switch (self.handlePrompt(c, prompt_path, cancel_token) catch
                return .{ .failed = .protocol_error }) {
                .accepted => .{ .unlocked = obj_path },
                .dismissed => .prompt_dismissed,
                .denied => .denied,
                .locked => .locked,
                .canceled => .canceled,
                .failed => |other| .{ .failed = other },
            };
        }

        // The item still needs a password and the daemon asked for no
        // prompt, so it is a locked store rather than a missing secret.
        return .locked;
    }

    fn unlockError(self: *SecretServiceCredentialProvider, reply: dbus.Message) UnlockOutcome {
        return switch (self.classify(reply)) {
            .locked => .locked,
            .denied => .denied,
            .unsupported => .{ .failed = .daemon_unavailable },
            // The object this unlock named is not in the store, so it cannot
            // be unlocked either.
            .no_object => .{ .failed = .daemon_unavailable },
            .unrecognized => .{ .failed = .rejected },
            .failed => |other| .{ .failed = other },
        };
    }

    /// The answer to one prompt.
    ///
    /// The daemon routes a completion by object path, so a signal for
    /// another prompt is somebody else's answer and must never confirm this
    /// call.
    const PromptResult = union(enum) {
        accepted,
        dismissed,
        denied,
        locked,
        canceled,
        failed: credentials.ProviderError,
    };

    fn promptError(self: *SecretServiceCredentialProvider, reply: dbus.Message) PromptResult {
        return switch (self.classify(reply)) {
            .locked => .locked,
            .denied => .denied,
            .unsupported => .{ .failed = .daemon_unavailable },
            // The prompt this call named is not in the store, so there was
            // never an answer to take from it.
            .no_object => .{ .failed = .daemon_unavailable },
            .unrecognized => .{ .failed = .rejected },
            .failed => |other| .{ .failed = other },
        };
    }

    fn handlePrompt(
        self: *SecretServiceCredentialProvider,
        c: *dbus.Connection,
        prompt_path: []const u8,
        cancel_token: ?*const credentials.CancellationToken,
    ) !PromptResult {
        if (cancel_token) |t| {
            if (t.isCanceled()) return .canceled;
        }

        const serial = c.nextSerial();
        var b = dbus.MessageBuilder.init(self.allocator, .method_call, serial);
        defer b.deinit();

        b.destination = "org.freedesktop.secrets";
        b.path = prompt_path;
        b.interface = prompt_interface;
        b.member = "Prompt";
        b.signature = "s";

        try b.writeString(""); // window_id

        // The daemon answers the `Prompt` call on its own serial. That
        // answer carries no out args at all, so only its type and the serial
        // it names say anything, and the object path cannot be what picks it
        // out: this is the one call in this provider that is acknowledged
        // rather than run as a signal loop.
        const ack_bytes = c.call(&b) catch return .{ .failed = .io_error };
        defer releaseFrame(c, ack_bytes);

        const ack = try dbus.MessageParser.parse(ack_bytes);
        // A refusal is the daemon declining the prompt, and it arrives as
        // the answer to this very call. Its error name is what decides
        // whether the user denied it or the store is locked.
        if (ack.msg_type == .error_reply) return self.promptError(ack);
        if (ack.msg_type != .method_return) return .{ .failed = .protocol_error };

        // The completion is a separate signal and is still awaited on its
        // own. Its body is only a dismissed flag, so the object path is the
        // one thing that says which prompt it answers, and a completion that
        // arrived before the acknowledgement above is still staged in the
        // connection rather than lost to it.
        while (true) {
            if (cancel_token) |t| {
                if (t.isCanceled()) return .canceled;
            }

            const msg_bytes = c.readMessageBytes() catch return .{ .failed = .io_error };
            defer releaseFrame(c, msg_bytes);

            const msg = try dbus.MessageParser.parse(msg_bytes);
            // This prompt was already acknowledged or refused above, so an
            // error reply here answers some other call and says nothing
            // about this one.
            if (msg.msg_type != .signal) continue;
            if (!std.mem.eql(u8, msg.interface orelse "", prompt_interface)) continue;
            if (!std.mem.eql(u8, msg.member orelse "", "Completed")) continue;
            if (!std.mem.eql(u8, msg.path orelse "", prompt_path)) continue;

            var reader = dbus.BodyReader.init(msg.body);
            const dismissed = reader.readBool() catch return .{ .failed = .protocol_error };
            return if (dismissed) .dismissed else .accepted;
        }
    }
};
