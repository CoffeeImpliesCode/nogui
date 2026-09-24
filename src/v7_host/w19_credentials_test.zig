//! Pure unit tests for W19 secure credentials, Secret Service model,
//! locked-store/prompt outcomes, cancellation, memory zeroing, and shutdown.
const std = @import("std");
const credentials = @import("credentials.zig");
const CredentialsService = credentials.CredentialsService;
const MockCredentialProvider = credentials.MockCredentialProvider;
const CredentialQuery = credentials.CredentialQuery;
const CredentialValue = credentials.CredentialValue;
const CancellationToken = credentials.CancellationToken;
const ReadResult = credentials.ReadResult;
const WriteResult = credentials.WriteResult;
const DeleteResult = credentials.DeleteResult;
const dbus = @import("linux/dbus.zig");
const SecretServiceCredentialProvider = @import("linux/credentials_secret_service.zig").SecretServiceCredentialProvider;

test "api-w19 credential synthetic secret write read and delete round-trip in test store" {
    var mock = MockCredentialProvider.init(std.testing.allocator);
    var service = CredentialsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    const query: CredentialQuery = .{
        .service = "com.zed.nogui.test",
        .account = "synthetic_user_42",
        .collection = "test_keyring",
    };

    // 1. Initial read is not_found
    const initial_res = service.read(std.testing.allocator, query, null);
    try std.testing.expectEqual(ReadResult.not_found, initial_res);

    // 2. Write synthetic secret
    const write_res = service.write(query, "super-confidential-token-999", null);
    try std.testing.expectEqual(WriteResult.success, write_res);

    // 3. Read back synthetic secret and verify exact bytes
    const read_res = service.read(std.testing.allocator, query, null);
    try std.testing.expect(read_res == .found);
    var val = read_res.found;
    defer val.deinit();

    try std.testing.expectEqualStrings("super-confidential-token-999", val.secret);

    // 4. Delete synthetic secret
    const del_res = service.delete(query, null);
    try std.testing.expectEqual(DeleteResult.success, del_res);

    // 5. Subsequent read must be not_found
    const post_del = service.read(std.testing.allocator, query, null);
    try std.testing.expectEqual(ReadResult.not_found, post_del);
}

test "api-w19 credential locked store with prompt dismissal does not appear as missing password" {
    var mock = MockCredentialProvider.init(std.testing.allocator);
    // Populate store with a credential while unlocked
    const query: CredentialQuery = .{
        .service = "com.zed.nogui.test",
        .account = "locked_account",
    };
    try std.testing.expectEqual(WriteResult.success, mock.provider().write(query, "existing_secret", null));

    // Now lock the store and simulate user dismissing the unlock prompt
    mock.store_locked = true;
    mock.prompt_behavior = .dismiss;

    var service = CredentialsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    // The read outcome must be prompt_dismissed, NEVER not_found!
    const res = service.read(std.testing.allocator, query, null);
    try std.testing.expectEqual(ReadResult.prompt_dismissed, res);
}

test "api-w19 credential locked store with prompt denial does not appear as missing password" {
    var mock = MockCredentialProvider.init(std.testing.allocator);
    const query: CredentialQuery = .{
        .service = "com.zed.nogui.test",
        .account = "denied_account",
    };
    try std.testing.expectEqual(WriteResult.success, mock.provider().write(query, "existing_secret", null));

    // Lock store and simulate denial
    mock.store_locked = true;
    mock.prompt_behavior = .deny;

    var service = CredentialsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    // Must return denied, NEVER not_found!
    const res = service.read(std.testing.allocator, query, null);
    try std.testing.expectEqual(ReadResult.denied, res);
}

test "api-w19 credential write failure or lock denial does not appear as successful write" {
    var mock = MockCredentialProvider.init(std.testing.allocator);
    var service = CredentialsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    const query: CredentialQuery = .{
        .service = "com.zed.nogui.test",
        .account = "write_test",
    };

    // 1. Lock store with dismissed prompt -> write must fail with prompt_dismissed
    mock.store_locked = true;
    mock.prompt_behavior = .dismiss;
    const write_dismissed = service.write(query, "new_secret", null);
    try std.testing.expectEqual(WriteResult.prompt_dismissed, write_dismissed);

    // 2. Lock store with denial -> write must fail with denied
    mock.prompt_behavior = .deny;
    const write_denied = service.write(query, "new_secret", null);
    try std.testing.expectEqual(WriteResult.denied, write_denied);

    // 3. Provider failure -> write must fail with provider_failed
    mock.store_locked = false;
    mock.simulate_failure = .daemon_unavailable;
    const write_failed = service.write(query, "new_secret", null);
    try std.testing.expect(write_failed == .provider_failed);
    try std.testing.expectEqual(credentials.ProviderError.daemon_unavailable, write_failed.provider_failed);
}

test "api-w19 credential provider disconnect returns typed error instead of not found or success" {
    var mock = MockCredentialProvider.init(std.testing.allocator);
    var service = CredentialsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    const query: CredentialQuery = .{
        .service = "com.zed.nogui.test",
        .account = "disconnect_test",
    };

    mock.disconnected = true;

    // Disconnect must NOT appear as missing password (not_found)
    const read_res = service.read(std.testing.allocator, query, null);
    try std.testing.expect(read_res == .provider_failed);
    try std.testing.expectEqual(credentials.ProviderError.disconnected, read_res.provider_failed);

    // Disconnect must NOT appear as successful write
    const write_res = service.write(query, "val", null);
    try std.testing.expect(write_res == .provider_failed);
    try std.testing.expectEqual(credentials.ProviderError.disconnected, write_res.provider_failed);

    // Disconnect must NOT appear as not_found or success on delete
    const del_res = service.delete(query, null);
    try std.testing.expect(del_res == .provider_failed);
    try std.testing.expectEqual(credentials.ProviderError.disconnected, del_res.provider_failed);
}

test "api-w19 credential cancellation aborts in-flight operation with typed canceled result" {
    var mock = MockCredentialProvider.init(std.testing.allocator);
    var service = CredentialsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    const query: CredentialQuery = .{
        .service = "com.zed.nogui.test",
        .account = "cancel_account",
    };

    var token: CancellationToken = .{};
    token.cancel();

    // Pre-canceled read
    const read_res = service.read(std.testing.allocator, query, &token);
    try std.testing.expectEqual(ReadResult.canceled, read_res);

    // Pre-canceled write
    const write_res = service.write(query, "secret", &token);
    try std.testing.expectEqual(WriteResult.canceled, write_res);

    // Pre-canceled delete
    const del_res = service.delete(query, &token);
    try std.testing.expectEqual(DeleteResult.canceled, del_res);
}

test "api-w19 credential shutdown aborts operations with typed result and disconnects provider" {
    var mock = MockCredentialProvider.init(std.testing.allocator);
    var service = CredentialsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    const query: CredentialQuery = .{
        .service = "com.zed.nogui.test",
        .account = "shutdown_test",
    };

    service.shutdown();
    try std.testing.expect(mock.disconnected);

    const r = service.read(std.testing.allocator, query, null);
    try std.testing.expect(r == .provider_failed);
    try std.testing.expectEqual(credentials.ProviderError.disconnected, r.provider_failed);

    const w = service.write(query, "secret", null);
    try std.testing.expect(w == .provider_failed);
    try std.testing.expectEqual(credentials.ProviderError.disconnected, w.provider_failed);

    const d = service.delete(query, null);
    try std.testing.expect(d == .provider_failed);
    try std.testing.expectEqual(credentials.ProviderError.disconnected, d.provider_failed);
}

test "api-w19 credential memory is securely zeroed on free and secrets are never formatted" {
    const raw_secret = "confidential-master-key-xyz";
    var val = try CredentialValue.init(std.testing.allocator, raw_secret);

    // Verify redaction in formatter
    var format_buf: [64]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&format_buf, "{f}", .{val});
    try std.testing.expectEqualStrings("[REDACTED SECRET]", formatted);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "confidential") == null);

    // Capture slice reference to verify zeroing
    const slice_copy = val.secret;
    try std.testing.expectEqualStrings(raw_secret, slice_copy);
    // The value owns the copy, so the wipe on free targets a heap block
    // rather than memory borrowed from the caller or a string literal.
    try std.testing.expect(slice_copy.ptr != raw_secret.ptr);

    // Deinit zeroes memory before free. The wipe and the release cover the
    // same bytes, and `std.mem.Allocator.free` overwrites a block with
    // `undefined` before it hands the block back, so a wiped byte is never
    // readable once `deinit` returns and the value must not be read either:
    // `deinit` poisons the struct behind that wipe. What stays observable is
    // the release, so it is checked on an arena that keeps every block and
    // therefore shows whether the secret block went back exactly once.
    var arena: [raw_secret.len]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena);
    const arena_secret = try fixed.allocator().dupe(u8, raw_secret);
    try std.testing.expectError(error.OutOfMemory, fixed.allocator().alloc(u8, arena.len));
    var arena_val = CredentialValue.initOwned(fixed.allocator(), arena_secret);
    arena_val.deinit();
    _ = try fixed.allocator().alloc(u8, arena.len);

    val.deinit();
}

const AsyncSink = struct {
    alive: bool = true,
    calls: usize = 0,
    last_operation: credentials.Operation = .read,
    // Both buffers are filled from the completion before their `*_len`
    // companion is read, and the zeroed tail past that length is never read.
    last_query: [64]u8 = [_]u8{0} ** 64,
    last_query_len: usize = 0,
    read_tag: std.meta.Tag(credentials.ReadResult) = .canceled,
    read_error: credentials.ProviderError = .disconnected,
    write_tag: std.meta.Tag(credentials.WriteResult) = .canceled,
    delete_tag: std.meta.Tag(credentials.DeleteResult) = .canceled,
    found_secret: [64]u8 = [_]u8{0} ** 64,
    found_len: usize = 0,

    fn probe(context: *const anyopaque) bool {
        const self: *const AsyncSink = @ptrCast(@alignCast(context));
        return self.alive;
    }

    /// The sink keeps a plaintext copy of a synthetic secret for its
    /// assertions, so it wipes that copy before the test frame dies.
    fn wipe(self: *AsyncSink) void {
        @memset(&self.found_secret, 0);
        self.found_len = 0;
    }

    fn onCompletion(context: ?*anyopaque, completion: *const credentials.Completion) void {
        const self: *AsyncSink = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.last_operation = completion.operation;

        const query = completion.query.service;
        self.last_query_len = @min(query.len, self.last_query.len);
        @memcpy(self.last_query[0..self.last_query_len], query[0..self.last_query_len]);

        switch (completion.result) {
            .read => |read| {
                self.read_tag = std.meta.activeTag(read);
                if (read == .found) {
                    self.found_len = @min(read.found.secret.len, self.found_secret.len);
                    @memcpy(self.found_secret[0..self.found_len], read.found.secret[0..self.found_len]);
                }
                if (read == .provider_failed) self.read_error = read.provider_failed;
            },
            .write => |write| self.write_tag = std.meta.activeTag(write),
            .delete => |del| self.delete_tag = std.meta.activeTag(del),
        }
    }
};

fn waitFor(sink: *AsyncSink, expected: usize) !void {
    var spins: usize = 0;
    while (sink.calls < expected and spins < 1_000_000) : (spins += 1) {
        try std.Thread.yield();
    }
}

/// One credential call against a loopback Secret Service.
const ProbeOp = enum { read, write, delete };

const probe_query: CredentialQuery = .{
    .service = "com.zed.nogui.probe",
    .account = "synthetic_probe_account",
};

/// A Secret Service that answers `OpenSession` and then fails the operation
/// with `error_name`. The client call runs on this thread, so the outcome is
/// deterministic and no native keyring or real credential is involved.
///
/// The client hangs up before the daemon is joined, so a call that stopped
/// early leaves the daemon reading the end of the socket rather than
/// waiting for a message nobody is going to send.
fn probeErrorReply(op: ProbeOp, error_name: []const u8) !credentials.CompletionResult {
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    const server_fd = fds[1];
    defer _ = std.os.linux.close(server_fd);

    var provider = SecretServiceCredentialProvider.initWithConnection(
        std.testing.allocator,
        dbus.Connection.initCustom(std.testing.allocator, fds[0]),
    );
    var service = CredentialsService.init(std.testing.allocator, provider.provider());

    const thread = try std.Thread.spawn(.{}, FailingSecretService.run, .{ server_fd, error_name });
    const result: credentials.CompletionResult = switch (op) {
        .read => .{ .read = service.read(std.testing.allocator, probe_query, null) },
        .write => .{ .write = service.write(probe_query, "synthetic-secret", null) },
        .delete => .{ .delete = service.delete(probe_query, null) },
    };
    service.deinit();
    thread.join();
    return result;
}

/// The item the scripted daemons below report, and the two prompt objects
/// they use. A completion belongs to the prompt whose object path it is
/// sent on, which is what makes the two prompts below distinguishable.
const locked_item_path = "/org/freedesktop/secrets/collection/login/i41";
const own_prompt_path = "/org/freedesktop/secrets/prompt/p41";
const other_prompt_path = "/org/freedesktop/secrets/prompt/p40";

/// Take the `OpenSession` call the client sends and return its serial.
fn readSessionCall(s_conn: *dbus.Connection) !u32 {
    const open_req_bytes = try s_conn.readMessageBytes();
    defer std.testing.allocator.free(open_req_bytes);
    const open_req = try dbus.MessageParser.parse(open_req_bytes);
    try std.testing.expectEqualStrings("OpenSession", open_req.member.?);
    return open_req.serial;
}

/// The answer to an `OpenSession` call, sent on its own so a fixture can
/// put another frame in front of it.
fn sendSessionReply(s_conn: *dbus.Connection, serial: u32, reply_serial: u32) !void {
    var open_ret = dbus.MessageBuilder.init(std.testing.allocator, .method_return, serial);
    defer open_ret.deinit();
    open_ret.reply_serial = reply_serial;
    open_ret.signature = "vo";
    try open_ret.writeSignature("s");
    try open_ret.writeString("");
    try open_ret.writeObjectPath("/org/freedesktop/secrets/session/s1");
    const open_wire = try open_ret.build();
    defer std.testing.allocator.free(open_wire);
    try s_conn.sendRaw(open_wire);
}

/// Answer an `OpenSession` call with a plain session.
fn serveOpenSession(s_conn: *dbus.Connection) !void {
    try sendSessionReply(s_conn, 1, try readSessionCall(s_conn));
}

/// Take the `SearchItems` call the client sends and return its serial.
fn readSearchCall(s_conn: *dbus.Connection) !u32 {
    const search_bytes = try s_conn.readMessageBytes();
    defer std.testing.allocator.free(search_bytes);
    const search_req = try dbus.MessageParser.parse(search_bytes);
    try std.testing.expectEqualStrings("SearchItems", search_req.member.?);
    return search_req.serial;
}

/// The answer to a `SearchItems` call that matched nothing. An empty match
/// list is the only missing credential, so this is the reply a read that
/// finds nothing comes back with.
fn sendEmptySearchReply(s_conn: *dbus.Connection, serial: u32, reply_serial: u32) !void {
    var search_ret = dbus.MessageBuilder.init(std.testing.allocator, .method_return, serial);
    defer search_ret.deinit();
    search_ret.reply_serial = reply_serial;
    search_ret.signature = "aoao";
    const unlocked = try search_ret.startArray(4);
    search_ret.finishArray(unlocked);
    const locked = try search_ret.startArray(4);
    search_ret.finishArray(locked);
    const search_wire = try search_ret.build();
    defer std.testing.allocator.free(search_wire);
    try s_conn.sendRaw(search_wire);
}

/// The answer to a `SearchItems` call with one already unlocked item, so
/// the call can act on it without a prompt.
fn serveSearchUnlocked(s_conn: *dbus.Connection, serial: u32) !void {
    const search_serial = try readSearchCall(s_conn);

    var search_ret = dbus.MessageBuilder.init(std.testing.allocator, .method_return, serial);
    defer search_ret.deinit();
    search_ret.reply_serial = search_serial;
    search_ret.signature = "aoao";
    const unlocked = try search_ret.startArray(4);
    try search_ret.writeObjectPath(locked_item_path);
    search_ret.finishArray(unlocked);
    const locked = try search_ret.startArray(4);
    search_ret.finishArray(locked);
    const search_wire = try search_ret.build();
    defer std.testing.allocator.free(search_wire);
    try s_conn.sendRaw(search_wire);
}

/// Answer a `GetSecret` call with one secret. The reply is the Secret
/// struct: session, parameters, value, content type.
fn serveGetSecretReply(s_conn: *dbus.Connection, serial: u32, secret: []const u8) !void {
    const get_bytes = try s_conn.readMessageBytes();
    defer std.testing.allocator.free(get_bytes);
    const get_req = try dbus.MessageParser.parse(get_bytes);
    try std.testing.expectEqualStrings("GetSecret", get_req.member.?);

    var secret_ret = dbus.MessageBuilder.init(std.testing.allocator, .method_return, serial);
    defer secret_ret.deinit();
    secret_ret.reply_serial = get_req.serial;
    secret_ret.signature = "(oayays)";
    try secret_ret.startStruct();
    try secret_ret.writeObjectPath("/org/freedesktop/secrets/session/s1");
    const params = try secret_ret.startArray(1);
    secret_ret.finishArray(params);
    const value = try secret_ret.startArray(1);
    for (secret) |byte| try secret_ret.writeByte(byte);
    secret_ret.finishArray(value);
    try secret_ret.writeString("text/plain; charset=utf8");
    const secret_wire = try secret_ret.build();
    defer std.testing.allocator.free(secret_wire);
    try s_conn.sendRaw(secret_wire);
}

fn serveErrorReply(
    s_conn: *dbus.Connection,
    serial: u32,
    reply_serial: u32,
    error_name: []const u8,
) !void {
    var err_ret = dbus.MessageBuilder.init(std.testing.allocator, .error_reply, serial);
    defer err_ret.deinit();
    err_ret.reply_serial = reply_serial;
    err_ret.error_name = error_name;
    err_ret.signature = "s";
    try err_ret.writeString("synthetic probe failure");
    const err_wire = try err_ret.build();
    defer std.testing.allocator.free(err_wire);
    try s_conn.sendRaw(err_wire);
}

/// Emit the `Completed` signal for one prompt object.
fn serveCompleted(s_conn: *dbus.Connection, serial: u32, prompt_path: []const u8, dismissed: bool) !void {
    var sig = dbus.MessageBuilder.init(std.testing.allocator, .signal, serial);
    defer sig.deinit();
    sig.path = prompt_path;
    sig.interface = "org.freedesktop.Secret.Prompt";
    sig.member = "Completed";
    sig.signature = "b";
    try sig.writeBool(dismissed);
    const wire = try sig.build();
    defer std.testing.allocator.free(wire);
    try s_conn.sendRaw(wire);
}

/// One `read` against a loopback Secret Service whose behaviour `server`
/// decides. The credential call runs on this thread while the daemon runs
/// on its own, so the outcome is deterministic and no native keyring or
/// real credential is involved.
///
/// The client hangs up before the daemon is joined. A daemon whose script
/// is waiting for a call this read is not going to make reads the end of
/// the socket and returns, so a call that stopped early is still a finite
/// test rather than a join that waits for a message nobody sends.
fn probeRead(server: anytype, args: anytype) !ReadResult {
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;

    var provider = SecretServiceCredentialProvider.initWithConnection(
        std.testing.allocator,
        dbus.Connection.initCustom(std.testing.allocator, fds[0]),
    );
    var service = CredentialsService.init(std.testing.allocator, provider.provider());

    const thread = try std.Thread.spawn(.{}, server, .{ fds[1], args });
    const result = service.read(std.testing.allocator, probe_query, null);
    service.deinit();
    thread.join();
    return result;
}

/// Answer a `SearchItems` call with `locked` as the only match, so the call
/// has to unlock before it can read or delete the item.
fn serveSearchLocked(s_conn: *dbus.Connection, serial: u32) !void {
    const search_bytes = try s_conn.readMessageBytes();
    defer std.testing.allocator.free(search_bytes);
    const search_req = try dbus.MessageParser.parse(search_bytes);
    try std.testing.expectEqualStrings("SearchItems", search_req.member.?);

    var search_ret = dbus.MessageBuilder.init(std.testing.allocator, .method_return, serial);
    defer search_ret.deinit();
    search_ret.reply_serial = search_req.serial;
    search_ret.signature = "aoao";
    const unlocked = try search_ret.startArray(4);
    search_ret.finishArray(unlocked);
    const locked = try search_ret.startArray(4);
    try search_ret.writeObjectPath(locked_item_path);
    search_ret.finishArray(locked);
    const search_wire = try search_ret.build();
    defer std.testing.allocator.free(search_wire);
    try s_conn.sendRaw(search_wire);
}

/// Answer an `Unlock` call with a prompt, so the item stays locked until a
/// person answers it.
fn serveUnlockWithPrompt(s_conn: *dbus.Connection, serial: u32) !void {
    const unlock_bytes = try s_conn.readMessageBytes();
    defer std.testing.allocator.free(unlock_bytes);
    const unlock_req = try dbus.MessageParser.parse(unlock_bytes);
    try std.testing.expectEqualStrings("Unlock", unlock_req.member.?);

    var unlock_ret = dbus.MessageBuilder.init(std.testing.allocator, .method_return, serial);
    defer unlock_ret.deinit();
    unlock_ret.reply_serial = unlock_req.serial;
    unlock_ret.signature = "aoo";
    const still_locked = try unlock_ret.startArray(4);
    unlock_ret.finishArray(still_locked);
    try unlock_ret.writeObjectPath(own_prompt_path);
    const unlock_wire = try unlock_ret.build();
    defer std.testing.allocator.free(unlock_wire);
    try s_conn.sendRaw(unlock_wire);
}

/// Take the `Prompt` call the client sends for `own_prompt_path`.
fn servePromptCall(s_conn: *dbus.Connection) !u32 {
    const prompt_bytes = try s_conn.readMessageBytes();
    defer std.testing.allocator.free(prompt_bytes);
    const prompt_req = try dbus.MessageParser.parse(prompt_bytes);
    try std.testing.expectEqualStrings("Prompt", prompt_req.member.?);
    try std.testing.expectEqualStrings(own_prompt_path, prompt_req.path.?);
    return prompt_req.serial;
}

/// Reach the point where the client is waiting for a prompt answer, and
/// return the serial of the `Prompt` call it sent there.
fn serveUntilPrompt(s_conn: *dbus.Connection) !u32 {
    try serveOpenSession(s_conn);
    try serveSearchLocked(s_conn, 2);
    try serveUnlockWithPrompt(s_conn, 3);
    return servePromptCall(s_conn);
}

const FailingSecretService = struct {
    fn run(fd: i32, error_name: []const u8) !void {
        var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
        defer {
            s_conn.detachFd();
            s_conn.deinit();
        }

        try serveOpenSession(&s_conn);

        const req_bytes = try s_conn.readMessageBytes();
        defer std.testing.allocator.free(req_bytes);
        const req = try dbus.MessageParser.parse(req_bytes);

        try serveErrorReply(&s_conn, 2, req.serial, error_name);
    }
};

/// A provider that reports whether it was torn down while a call was inside
/// it. `Async` owns the provider for every submitted call, so a teardown
/// during a call releases the connection and the session state that call is
/// still using.
const TeardownProbe = struct {
    entered: std.atomic.Value(bool) = .init(false),
    open: std.atomic.Value(bool) = .init(false),
    in_call: std.atomic.Value(bool) = .init(false),
    torn_down_in_call: std.atomic.Value(bool) = .init(false),
    teardowns: std.atomic.Value(usize) = .init(0),

    fn provider(self: *TeardownProbe) credentials.CredentialProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Holds the call open until the host releases the gate, then reports the
    /// cancellation the host gave it.
    fn hold(self: *TeardownProbe, cancel_token: ?*const CancellationToken) bool {
        self.in_call.store(true, .release);
        self.entered.store(true, .release);
        while (!self.open.load(.acquire)) {
            std.Thread.yield() catch std.log.debug("sched_yield refused while waiting", .{});
        }
        self.in_call.store(false, .release);
        if (cancel_token) |token| return token.isCanceled();
        return false;
    }

    const vtable: credentials.CredentialProvider.VTable = .{
        .read = readFn,
        .write = writeFn,
        .delete = deleteFn,
        .disconnect = disconnectFn,
        .deinit = deinitFn,
    };

    fn readFn(
        _: std.mem.Allocator,
        ctx: *anyopaque,
        _: CredentialQuery,
        cancel_token: ?*const CancellationToken,
    ) ReadResult {
        const self: *TeardownProbe = @ptrCast(@alignCast(ctx));
        return if (self.hold(cancel_token)) .canceled else .not_found;
    }

    fn writeFn(
        ctx: *anyopaque,
        _: CredentialQuery,
        _: []const u8,
        cancel_token: ?*const CancellationToken,
    ) WriteResult {
        const self: *TeardownProbe = @ptrCast(@alignCast(ctx));
        return if (self.hold(cancel_token)) .canceled else .unsupported;
    }

    fn deleteFn(
        ctx: *anyopaque,
        _: CredentialQuery,
        cancel_token: ?*const CancellationToken,
    ) DeleteResult {
        const self: *TeardownProbe = @ptrCast(@alignCast(ctx));
        return if (self.hold(cancel_token)) .canceled else .not_found;
    }

    fn disconnectFn(ctx: *anyopaque) void {
        const self: *TeardownProbe = @ptrCast(@alignCast(ctx));
        if (self.in_call.load(.acquire)) self.torn_down_in_call.store(true, .release);
        _ = self.teardowns.fetchAdd(1, .acq_rel);
    }

    /// The probe owns no memory, so deinit leaves the counters readable for
    /// the assertions that follow it.
    fn deinitFn(_: *anyopaque) void {}
};

test "api-w19 async credential calls complete on the host thread with typed results" {
    var mock = MockCredentialProvider.init(std.testing.allocator);
    var service = credentials.Async.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    var sink: AsyncSink = .{};
    defer sink.wipe();
    const owner: credentials.WeakOwner = .{ .context = &sink, .is_alive_fn = AsyncSink.probe };
    const query: CredentialQuery = .{ .service = "async-service", .account = "async-account" };

    try service.submitWrite(query, "async-secret-value", owner, AsyncSink.onCompletion, &sink);
    try service.submitRead(query, owner, AsyncSink.onCompletion, &sink);
    try service.submitDelete(query, owner, AsyncSink.onCompletion, &sink);

    var spins: usize = 0;
    while (sink.calls < 3 and spins < 1_000_000) : (spins += 1) {
        if (service.poll(4) == 0) try std.Thread.yield();
    }

    try std.testing.expectEqual(@as(usize, 3), sink.calls);
    try std.testing.expectEqualStrings("async-service", sink.last_query[0..sink.last_query_len]);
    try std.testing.expectEqual(@as(std.meta.Tag(credentials.WriteResult), .success), sink.write_tag);
    try std.testing.expectEqual(@as(std.meta.Tag(credentials.DeleteResult), .success), sink.delete_tag);
    try std.testing.expectEqual(@as(std.meta.Tag(credentials.ReadResult), .found), sink.read_tag);
    try std.testing.expectEqualStrings("async-secret-value", sink.found_secret[0..sink.found_len]);
}

test "api-w19 async completion for a dead owner is dropped without a callback" {
    var mock = MockCredentialProvider.init(std.testing.allocator);
    var service = credentials.Async.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    var sink: AsyncSink = .{};
    defer sink.wipe();
    const query: CredentialQuery = .{ .service = "async-service", .account = "dead-owner" };
    _ = mock.provider().write(query, "secret", null);

    const owner: credentials.WeakOwner = .{ .context = &sink, .is_alive_fn = AsyncSink.probe };
    try service.submitRead(query, owner, AsyncSink.onCompletion, &sink);

    sink.alive = false;
    try waitFor(&sink, 1);
    _ = service.poll(4);

    try std.testing.expectEqual(@as(usize, 0), sink.calls);
    try std.testing.expect(!service.busy());
}

test "api-w19 async shutdown cancels an in-flight call and refuses new ones" {
    var mock = MockCredentialProvider.init(std.testing.allocator);
    var gate: MockCredentialProvider.Gate = .{};
    mock.gate = &gate;

    var service = credentials.Async.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    var sink: AsyncSink = .{};
    defer sink.wipe();
    const owner: credentials.WeakOwner = .{ .context = &sink, .is_alive_fn = AsyncSink.probe };
    const query: CredentialQuery = .{ .service = "async-service", .account = "cancel-me" };

    try service.submitRead(query, owner, AsyncSink.onCompletion, &sink);

    // Wait until the worker is inside the provider, then cancel through shutdown.
    var spins: usize = 0;
    while (!gate.entered.load(.acquire) and spins < 1_000_000) : (spins += 1) {
        try std.Thread.yield();
    }
    try std.testing.expect(gate.entered.load(.acquire));

    service.shutdown();
    gate.open.store(true, .release);

    var delivered: usize = 0;
    spins = 0;
    while (delivered < 1 and spins < 1_000_000) : (spins += 1) {
        delivered = service.poll(4);
        if (delivered == 0) try std.Thread.yield();
    }

    try std.testing.expectEqual(@as(usize, 1), sink.calls);
    // Shutdown hands the call it is holding open its cancellation. The
    // provider stays connected until the worker joins, so the result is that
    // cancellation and never a missing secret or a successful read.
    try std.testing.expectEqual(@as(std.meta.Tag(credentials.ReadResult), .canceled), sink.read_tag);
    try std.testing.expectEqual(@as(usize, 0), sink.found_len);
    try std.testing.expectError(error.ServiceShutdown, service.submitRead(query, owner, AsyncSink.onCompletion, &sink));
}

test "api-w19 async shutdown keeps the provider alive until the worker has joined" {
    var probe: TeardownProbe = .{};
    var sink: AsyncSink = .{};
    defer sink.wipe();
    const owner: credentials.WeakOwner = .{ .context = &sink, .is_alive_fn = AsyncSink.probe };
    const query: CredentialQuery = .{ .service = "async-service", .account = "in-flight" };

    var delivered: usize = 0;
    {
        var service = credentials.Async.init(std.testing.allocator, probe.provider());
        defer service.deinit();

        try service.submitRead(query, owner, AsyncSink.onCompletion, &sink);

        // Wait until the worker is inside the provider, then shut down while
        // the call is still running.
        var spins: usize = 0;
        while (!probe.entered.load(.acquire) and spins < 1_000_000) : (spins += 1) {
            try std.Thread.yield();
        }
        try std.testing.expect(probe.entered.load(.acquire));

        service.shutdown();
        probe.open.store(true, .release);

        spins = 0;
        while (delivered < 1 and spins < 1_000_000) : (spins += 1) {
            delivered = service.poll(4);
            if (delivered == 0) try std.Thread.yield();
        }
    }

    try std.testing.expect(!probe.torn_down_in_call.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), probe.teardowns.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), delivered);
    try std.testing.expectEqual(@as(std.meta.Tag(credentials.ReadResult), .canceled), sink.read_tag);
}

test "api-w19 secret service locked search reply is a locked store and not a missing password" {
    const result = try probeErrorReply(.read, "org.freedesktop.Secret.Error.IsLocked");
    try std.testing.expectEqual(ReadResult.locked, result.read);
}

test "api-w19 secret service denied search reply is not a missing password" {
    const result = try probeErrorReply(.read, "org.freedesktop.DBus.Error.AccessDenied");
    try std.testing.expectEqual(ReadResult.denied, result.read);
}

test "api-w19 secret service disconnected search reply is a typed provider failure" {
    const result = try probeErrorReply(.read, "org.freedesktop.DBus.Error.Disconnected");
    try std.testing.expect(result.read == .provider_failed);
    try std.testing.expectEqual(credentials.ProviderError.disconnected, result.read.provider_failed);
}

test "api-w19 secret service delete against a locked store is not a successful delete" {
    const result = try probeErrorReply(.delete, "org.freedesktop.Secret.Error.IsLocked");
    try std.testing.expectEqual(DeleteResult.locked, result.delete);
}

test "api-w19 secret service write refused by the bus is not a successful write" {
    const result = try probeErrorReply(.write, "org.freedesktop.DBus.Error.AuthFailed");
    try std.testing.expectEqual(WriteResult.denied, result.write);
}

/// Acknowledge a `Prompt` call. `Prompt.Prompt(IN window_id)` returns
/// nothing, so this answer carries no out args and says only which call it
/// belongs to.
fn servePromptAck(s_conn: *dbus.Connection, serial: u32, reply_serial: u32) !void {
    var ack = dbus.MessageBuilder.init(std.testing.allocator, .method_return, serial);
    defer ack.deinit();
    ack.reply_serial = reply_serial;
    const ack_wire = try ack.build();
    defer std.testing.allocator.free(ack_wire);
    try s_conn.sendRaw(ack_wire);
}

/// A Secret Service that reaches a prompt and sends both completions
/// before it acknowledges the call: a completion for a different prompt
/// object, and this prompt's own dismissal. The foreign completion is a
/// late answer to some earlier prompt, and it does not answer this call.
fn serveForeignCompletion(fd: i32, _: void) !void {
    var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
    defer s_conn.deinit();

    const prompt_serial = try serveUntilPrompt(&s_conn);
    // Both completions go out ahead of the acknowledgement, so the client
    // has to hold on to them while it waits for the answer to its own call
    // instead of losing them to that wait.
    try serveCompleted(&s_conn, 4, other_prompt_path, false);
    try serveCompleted(&s_conn, 5, own_prompt_path, true);
    try servePromptAck(&s_conn, 6, prompt_serial);
    // Closing here ends the daemon. A client that took the foreign
    // completion asks for the secret afterwards and gets a closed
    // connection, which is a typed failure rather than a hang.
}

/// The secret a prompt the user accepted eventually hands back.
const prompt_accepted_secret = "synthetic-prompt-accepted-secret";

/// A Secret Service that reaches a prompt, has the user accept it, and
/// only then releases the item. The completion goes out ahead of the
/// acknowledgement, and accepting the prompt is the whole reason the read
/// is able to go on and ask for a secret at all.
fn serveAcceptedCompletion(fd: i32, _: void) !void {
    var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
    defer s_conn.deinit();

    const prompt_serial = try serveUntilPrompt(&s_conn);
    try serveCompleted(&s_conn, 4, own_prompt_path, false);
    try servePromptAck(&s_conn, 5, prompt_serial);
    try serveGetSecretReply(&s_conn, 6, prompt_accepted_secret);
}

/// A Secret Service that reaches a prompt and then refuses it outright.
/// The refusal is the answer to the `Prompt` call itself, which is how a
/// daemon declines before a prompt ever exists.
fn servePromptRefusal(fd: i32, _: void) !void {
    var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
    defer s_conn.deinit();

    const prompt_serial = try serveUntilPrompt(&s_conn);
    try serveErrorReply(&s_conn, 4, prompt_serial, "org.freedesktop.DBus.Error.AccessDenied");
}

test "api-w19 secret service prompt completion for another prompt is not this call's answer" {
    // The daemon completes somebody else's prompt and dismisses this one,
    // both before acknowledging the call. Taking the first completion would
    // report a read the user never allowed.
    const result = try probeRead(serveForeignCompletion, {});
    try std.testing.expectEqual(ReadResult.prompt_dismissed, result);
}

test "api-w19 secret service prompt completed before the acknowledgement still reads the secret" {
    // The completion lands ahead of the answer to the client's own call, so
    // waiting for that answer must not lose it. The prompt was answered by
    // the user, so the read goes on and finds the secret rather than
    // reporting a dismissal nobody made.
    const result = try probeRead(serveAcceptedCompletion, {});
    try std.testing.expect(result == .found);
    var value = result.found;
    try std.testing.expectEqualStrings(prompt_accepted_secret, value.secret);
    value.deinit();
}

test "api-w19 secret service refused prompt is a denial and not a stored credential" {
    // A prompt the daemon refuses is the user declining, not a missing
    // password and not a successful unlock.
    const result = try probeRead(servePromptRefusal, {});
    try std.testing.expectEqual(ReadResult.denied, result);
}

/// Which call the daemon puts an unrelated signal in front of. The signal
/// belongs to no call this client made, so it must not answer either one.
const SignalBefore = enum { session, search };

/// A Secret Service that forwards a signal for somebody else's prompt
/// before the reply to a call the client is waiting for. The signal is a
/// late answer to a prompt this client never raised; the reply behind it is
/// still the answer to the call that named it.
fn serveSignalBeforeReply(fd: i32, before: SignalBefore) !void {
    var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
    defer {
        s_conn.detachFd();
        s_conn.deinit();
    }

    const session_serial = try readSessionCall(&s_conn);
    if (before == .session) try serveCompleted(&s_conn, 4, other_prompt_path, false);
    try sendSessionReply(&s_conn, 5, session_serial);

    const search_serial = try readSearchCall(&s_conn);
    if (before == .search) try serveCompleted(&s_conn, 6, other_prompt_path, false);
    try sendEmptySearchReply(&s_conn, 7, search_serial);
    // Closing here ends the daemon. A client that took the signal for a
    // reply has no session to search with, so it stops calling and reads
    // the end of the socket instead of waiting for this script to grow.
}

test "api-w19 secret service signal before the session reply does not answer OpenSession" {
    // The daemon forwards a completion for another prompt and then answers
    // `OpenSession`. The call still gets its own session, so the read comes
    // back with the documented outcome for a query that matched nothing.
    const result = try probeRead(serveSignalBeforeReply, .session);
    try std.testing.expectEqual(ReadResult.not_found, result);
}

test "api-w19 secret service signal before the search reply does not answer SearchItems" {
    // The session is answered cleanly and the signal arrives in front of the
    // search reply instead. The match list behind the signal is still the
    // answer, and an empty one is still a missing credential.
    const result = try probeRead(serveSignalBeforeReply, .search);
    try std.testing.expectEqual(ReadResult.not_found, result);
}

/// Backing allocator that keeps every block it hands out inside one buffer
/// the test owns, and relocates a block that needs to grow. That is what the
/// system allocator does with a large message, and it is why a builder that
/// appends a secret one byte at a time leaves the earlier copies behind:
/// `std.mem.Allocator.free` wipes a block it releases, but a growth copies
/// the old contents into a new block and leaves the old one in the heap.
///
/// Two probes in one test own disjoint buffers, so the address a block sits
/// at says which allocator made it. A release through the wrong one is
/// recorded here rather than carried out: that block is not this
/// allocator's to reuse, and pretending otherwise is the fault under test.
const ResidueProbe = struct {
    /// The buffer a carve is cut from. It carries the alignment itself, so
    /// a block handed out for something wider than a byte cannot land
    /// unaligned however the backing store was declared.
    buffer: []align(16) u8,
    used: usize = 0,
    /// Blocks this probe handed out and has not taken back. A block that
    /// `remap` moves is consumed rather than released, because `remap`
    /// takes ownership of the memory it is given: one block leaves and one
    /// arrives, and the old bytes stay readable in `buffer` either way.
    live_blocks: usize = 0,
    /// Releases of blocks this probe never handed out. A block is only ever
    /// released through the allocator that created it, so a count here is a
    /// mismatched release, caught here rather than corrupting a heap.
    foreign_releases: usize = 0,

    /// Blocks handed out and not taken back. Zero once every owner has
    /// released what it was given.
    fn live(self: *const ResidueProbe) usize {
        return self.live_blocks;
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    fn allocator(self: *ResidueProbe) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn carve(self: *ResidueProbe, len: usize, alignment: std.mem.Alignment) ?[]u8 {
        // An empty block holds nothing and answers to no address, so it is
        // neither counted as handed out nor searched for on release.
        if (len == 0) return self.buffer[0..0];
        const start = std.mem.alignForward(usize, self.used, alignment.toByteUnits());
        const end = std.math.add(usize, start, len) catch return null;
        if (end > self.buffer.len) return null;
        self.used = end;
        self.live_blocks += 1;
        return self.buffer[start..end];
    }

    /// True when `memory` is a block this probe carved out of its own
    /// buffer.
    fn owns(self: *const ResidueProbe, memory: []const u8) bool {
        const base = @intFromPtr(self.buffer.ptr);
        const addr = @intFromPtr(memory.ptr);
        return addr >= base and addr + memory.len <= base + self.buffer.len;
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *ResidueProbe = @ptrCast(@alignCast(ctx));
        const block = self.carve(len, alignment) orelse return null;
        return block.ptr;
    }

    /// Growing in place is only possible when the block shrinks. Refusing
    /// is allowed: the caller then allocates and copies itself, which keeps
    /// every hand-out here paired with a take-back.
    fn resizeFn(
        _: *anyopaque,
        memory: []u8,
        _: std.mem.Alignment,
        new_len: usize,
        _: usize,
    ) bool {
        return new_len <= memory.len;
    }

    /// A block that already has the room stays where it is. A block that
    /// needs more is copied elsewhere and the old bytes stay behind, which
    /// is what leaves the earlier copies of a secret readable.
    fn remapFn(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        _: usize,
    ) ?[*]u8 {
        const self: *ResidueProbe = @ptrCast(@alignCast(ctx));
        if (new_len <= memory.len) return memory.ptr;
        const block = self.carve(new_len, alignment) orelse return null;
        @memcpy(block[0..memory.len], memory);
        // `carve` handed out the replacement. The block it replaced leaves
        // the count only when it was in it: an empty slice is the empty
        // list's own placeholder, which was never carved and so was never
        // counted.
        if (memory.len != 0) self.live_blocks -= 1;
        return block.ptr;
    }

    /// A released block is not reused, so a scan of `buffer` still shows
    /// whatever the credential path left in it. A block from another
    /// allocator is not released at all: it is counted, because releasing
    /// it here is the mismatched release this test exists to catch.
    fn freeFn(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *ResidueProbe = @ptrCast(@alignCast(ctx));
        if (memory.len == 0) return;
        if (!self.owns(memory)) {
            self.foreign_releases += 1;
            return;
        }
        self.live_blocks -= 1;
    }
};

/// A Secret Service that stores one item without asking anything.
fn serveCreateItem(fd: i32, _: void) !void {
    var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
    defer {
        s_conn.detachFd();
        s_conn.deinit();
    }

    try serveOpenSession(&s_conn);

    const create_bytes = try s_conn.readMessageBytes();
    defer std.testing.allocator.free(create_bytes);
    const create_req = try dbus.MessageParser.parse(create_bytes);
    try std.testing.expectEqualStrings("CreateItem", create_req.member.?);

    var create_ret = dbus.MessageBuilder.init(std.testing.allocator, .method_return, 2);
    defer create_ret.deinit();
    create_ret.reply_serial = create_req.serial;
    create_ret.signature = "oo";
    try create_ret.writeObjectPath(locked_item_path);
    try create_ret.writeObjectPath("/"); // no prompt
    const create_wire = try create_ret.build();
    defer std.testing.allocator.free(create_wire);
    try s_conn.sendRaw(create_wire);
}

test "api-w19 secret service write leaves no plaintext in released provider memory" {
    const synthetic_secret = "synthetic-plaintext-never-persisted";

    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    defer _ = std.os.linux.close(fds[1]);

    var backing: [128 * 1024]u8 align(16) = undefined;
    // Zeroed so a scan can only match bytes some code actually wrote.
    @memset(&backing, 0);
    var probe: ResidueProbe = .{ .buffer = &backing };

    var provider = SecretServiceCredentialProvider.initWithConnection(
        probe.allocator(),
        dbus.Connection.initCustom(probe.allocator(), fds[0]),
    );
    var service = CredentialsService.init(probe.allocator(), provider.provider());

    const thread = try std.Thread.spawn(.{}, serveCreateItem, .{ fds[1], {} });
    const result = service.write(probe_query, synthetic_secret, null);
    // The client's end goes first: a daemon still waiting for the call
    // this write did not make reads the end of the socket and returns.
    service.deinit();
    thread.join();

    try std.testing.expectEqual(WriteResult.success, result);
    // The write returned, so the message it carried is gone. Any copy of
    // the secret still readable in the provider's memory is plaintext the
    // write path left behind in a block it no longer owns.
    try std.testing.expect(std.mem.indexOf(u8, probe.buffer, synthetic_secret) == null);
    @memset(&backing, 0);
}

/// A Secret Service that returns one unlocked item and its secret. The
/// secret is a parameter so the caller can make the reply larger than the
/// transport staging window.
fn serveGetSecret(fd: i32, secret: []const u8) !void {
    var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
    defer {
        s_conn.detachFd();
        s_conn.deinit();
    }

    try serveOpenSession(&s_conn);

    // SearchItems: the item is already unlocked, so reading it needs no
    // prompt and goes straight to GetSecret.
    try serveSearchUnlocked(&s_conn, 2);
    try serveGetSecretReply(&s_conn, 3, secret);
}

test "api-w19 secret service read leaves no plaintext in the transport staging buffer" {
    // Larger than the transport's 4096 byte staging window, so the reply
    // is still arriving when the buffer has to grow. A buffer that grows
    // mid-frame releases the block that already holds part of the secret.
    const secret_len = 6000;
    var secret_backing: [secret_len]u8 = undefined;
    for (&secret_backing, 0..) |*byte, i| byte.* = @intCast('a' + (i % 26));
    const synthetic_secret = secret_backing[0..];

    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    defer _ = std.os.linux.close(fds[1]);

    var backing: [128 * 1024]u8 align(16) = undefined;
    @memset(&backing, 0);
    var probe: ResidueProbe = .{ .buffer = &backing };

    var provider = SecretServiceCredentialProvider.initWithConnection(
        probe.allocator(),
        dbus.Connection.initCustom(probe.allocator(), fds[0]),
    );
    var service = CredentialsService.init(probe.allocator(), provider.provider());

    const thread = try std.Thread.spawn(.{}, serveGetSecret, .{ fds[1], synthetic_secret });
    const result = service.read(probe.allocator(), probe_query, null);

    try std.testing.expect(result == .found);
    var value = result.found;
    try std.testing.expectEqualStrings(synthetic_secret, value.secret);
    value.deinit();

    // The connection is still open and its staging buffer is still
    // allocated, and the copy handed to the caller has been wiped. Nothing
    // the transport kept may still hold the secret.
    try std.testing.expect(std.mem.indexOf(u8, probe.buffer, synthetic_secret) == null);
    // The client's end goes last, after the scan above: a daemon still
    // waiting for the call this read did not make reads the end of the
    // socket and returns.
    service.deinit();
    thread.join();
    @memset(&backing, 0);
    @memset(&secret_backing, 0);
}

test "api-w19 secret service adopted connection frees reply copies through the allocator that made them" {
    // The provider and the connection it was handed are backed by two
    // different allocators, which is what `initWithConnection` allows and
    // what a host that owns its transport memory does. Every reply copy
    // belongs to the connection that read it, so the provider has to
    // release it through that allocator. Releasing it through its own is a
    // mismatched release, and it shows up here as a release of a block this
    // allocator never handed out.
    const synthetic_secret = "synthetic-adopted-allocator-secret";

    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    defer _ = std.os.linux.close(fds[1]);

    var provider_backing: [64 * 1024]u8 align(16) = undefined;
    // Zeroed so a scan can only match bytes some code actually wrote.
    @memset(&provider_backing, 0);
    var provider_probe: ResidueProbe = .{ .buffer = &provider_backing };

    var connection_backing: [128 * 1024]u8 align(16) = undefined;
    @memset(&connection_backing, 0);
    var connection_probe: ResidueProbe = .{ .buffer = &connection_backing };

    var provider = SecretServiceCredentialProvider.initWithConnection(
        provider_probe.allocator(),
        dbus.Connection.initCustom(connection_probe.allocator(), fds[0]),
    );
    var service = CredentialsService.init(std.testing.allocator, provider.provider());

    const thread = try std.Thread.spawn(.{}, serveGetSecret, .{ fds[1], synthetic_secret });
    const result = service.read(std.testing.allocator, probe_query, null);
    service.deinit();
    thread.join();

    // The read itself is unaffected by who owns the memory: the documented
    // outcome for a stored item is still the secret it holds.
    try std.testing.expect(result == .found);
    var value = result.found;
    try std.testing.expectEqualStrings(synthetic_secret, value.secret);
    value.deinit();

    // Neither allocator was asked to release a block the other one made.
    try std.testing.expectEqual(@as(usize, 0), provider_probe.foreign_releases);
    try std.testing.expectEqual(@as(usize, 0), connection_probe.foreign_releases);

    // Every block the connection made came back to it: the reply copies
    // the reads handed over were released, not leaked.
    try std.testing.expectEqual(@as(usize, 0), connection_probe.live());

    // A released reply copy is wiped, so neither allocator's memory still
    // reads back as plaintext.
    try std.testing.expect(std.mem.indexOf(u8, &provider_backing, synthetic_secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, &connection_backing, synthetic_secret) == null);
    @memset(&provider_backing, 0);
    @memset(&connection_backing, 0);
}

/// One D-Bus method return whose body is a single string.
fn buildFrame(allocator: std.mem.Allocator, body_text: []const u8) ![]u8 {
    var builder = dbus.MessageBuilder.init(allocator, .method_return, 1);
    defer builder.deinit();
    builder.destination = "org.freedesktop.secrets";
    builder.signature = "s";
    try builder.writeString(body_text);
    return builder.build();
}

/// A daemon that writes two frames in one send, so the client takes the
/// first one out of a buffer that already holds part of the second, and
/// then closes once the first has been taken.
const TwoFrameDaemon = struct {
    payload: []const u8,
    first_taken: *std.atomic.Value(bool),

    fn run(self: TwoFrameDaemon, fd: i32) !void {
        var s_conn = dbus.Connection.initCustom(std.testing.allocator, fd);
        defer s_conn.deinit();

        try s_conn.sendRaw(self.payload);
        var spins: usize = 0;
        while (!self.first_taken.load(.acquire) and spins < 10_000_000) : (spins += 1) {
            try std.Thread.yield();
        }
        // Closing here still delivers what is already queued, so the
        // client can finish the second frame.
    }
};

test "api-w19 dbus compaction keeps the arriving frame and drops no secret" {
    const secret = "synthetic-transport-secret-0000";

    const frame_a = try buildFrame(std.testing.allocator, secret);
    defer {
        std.crypto.secureZero(u8, frame_a);
        std.testing.allocator.free(frame_a);
    }

    var filler: [4096]u8 = undefined;
    for (&filler, 0..) |*byte, i| byte.* = @intCast('A' + (i % 26));
    const frame_b = try buildFrame(std.testing.allocator, &filler);
    defer {
        std.crypto.secureZero(u8, frame_b);
        std.testing.allocator.free(frame_b);
    }

    var payload: [16 * 1024]u8 = undefined;
    const payload_len = frame_a.len + frame_b.len;
    @memcpy(payload[0..frame_a.len], frame_a);
    @memcpy(payload[frame_a.len..payload_len], frame_b);

    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;

    var backing: [256 * 1024]u8 align(16) = undefined;
    @memset(&backing, 0);
    var probe: ResidueProbe = .{ .buffer = &backing };

    var conn = dbus.Connection.initCustom(probe.allocator(), fds[0]);
    defer conn.deinit();

    var first_taken: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, TwoFrameDaemon.run, .{
        TwoFrameDaemon{ .payload = payload[0..payload_len], .first_taken = &first_taken },
        fds[1],
    });

    const taken_a = try conn.readMessageBytes();
    first_taken.store(true, .release);
    const taken_b = try conn.readMessageBytes();
    thread.join();

    // The frame that was still arriving has to come back exactly as it was
    // sent, even though the buffer underneath it was compacted and grown
    // while it was incomplete.
    try std.testing.expectEqualSlices(u8, frame_a, taken_a);
    try std.testing.expectEqualSlices(u8, frame_b, taken_b);

    std.crypto.secureZero(u8, taken_a);
    probe.allocator().free(taken_a);
    std.crypto.secureZero(u8, taken_b);
    probe.allocator().free(taken_b);

    // The bytes the compaction dropped belonged to a frame the client had
    // already read. None of them may still hold that frame's secret.
    try std.testing.expect(std.mem.indexOf(u8, probe.buffer, secret) == null);
    @memset(&backing, 0);
    @memset(&payload, 0);
}
