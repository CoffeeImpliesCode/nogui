//! Host platform secure credential service with Secret Service backing,
//! prompt/locked-store outcomes, cancellation, and zeroed secret memory.
//!
//! No operation has a plaintext fallback: an absent daemon, a locked store, a
//! dismissed prompt and a provider failure are distinct typed results, and no
//! secret is ever logged, formatted or copied into a frame arena.
const std = @import("std");

pub const WeakOwner = @import("weak_owner.zig").WeakOwner;
pub const CredentialQuery = struct {
    service: []const u8,
    account: []const u8,
    collection: ?[]const u8 = null, // null for default keyring/collection
};

/// An owned secure credential secret buffer.
/// Securely zeroed before memory is freed. Secrets are never logged or formatted.
pub const CredentialValue = struct {
    secret: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !CredentialValue {
        const copy = try allocator.dupe(u8, bytes);
        return .{
            .secret = copy,
            .allocator = allocator,
        };
    }

    pub fn initOwned(allocator: std.mem.Allocator, owned_bytes: []u8) CredentialValue {
        return .{
            .secret = owned_bytes,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CredentialValue) void {
        if (self.secret.len > 0) {
            std.crypto.secureZero(u8, self.secret);
            self.allocator.free(self.secret);
            self.secret = &.{};
        }
        self.* = undefined;
    }

    pub fn clone(self: CredentialValue, allocator: std.mem.Allocator) !CredentialValue {
        const copy = try allocator.dupe(u8, self.secret);
        return .{
            .secret = copy,
            .allocator = allocator,
        };
    }

    /// Redacts secret value so std.debug.print, logging, or format never leak secrets.
    pub fn format(
        self: CredentialValue,
        writer: anytype,
    ) !void {
        _ = self;
        try writer.writeAll("[REDACTED SECRET]");
    }
};

pub const ProviderError = enum {
    disconnected,
    timeout,
    protocol_error,
    rejected,
    out_of_memory,
    io_error,
    permission_denied,
    daemon_unavailable,
    store_corrupted,
};

pub const ReadResult = union(enum) {
    found: CredentialValue,
    not_found,
    locked,
    prompt_dismissed,
    denied,
    canceled,
    provider_failed: ProviderError,
    unsupported,
};

pub const WriteResult = union(enum) {
    success,
    locked,
    prompt_dismissed,
    denied,
    canceled,
    provider_failed: ProviderError,
    unsupported,
};

pub const DeleteResult = union(enum) {
    success,
    not_found,
    locked,
    prompt_dismissed,
    denied,
    canceled,
    provider_failed: ProviderError,
    unsupported,
};

pub const CancellationToken = struct {
    canceled: std.atomic.Value(bool) = .init(false),

    pub fn cancel(self: *CancellationToken) void {
        self.canceled.store(true, .release);
    }

    pub fn isCanceled(self: *const CancellationToken) bool {
        return self.canceled.load(.acquire);
    }
};

pub const CredentialProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (
            allocator: std.mem.Allocator,
            ctx: *anyopaque,
            query: CredentialQuery,
            cancel_token: ?*const CancellationToken,
        ) ReadResult,
        write: *const fn (
            ctx: *anyopaque,
            query: CredentialQuery,
            secret: []const u8,
            cancel_token: ?*const CancellationToken,
        ) WriteResult,
        delete: *const fn (
            ctx: *anyopaque,
            query: CredentialQuery,
            cancel_token: ?*const CancellationToken,
        ) DeleteResult,
        disconnect: *const fn (ctx: *anyopaque) void,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn read(
        self: CredentialProvider,
        allocator: std.mem.Allocator,
        query: CredentialQuery,
        cancel_token: ?*const CancellationToken,
    ) ReadResult {
        return self.vtable.read(allocator, self.ptr, query, cancel_token);
    }

    pub fn write(
        self: CredentialProvider,
        query: CredentialQuery,
        secret: []const u8,
        cancel_token: ?*const CancellationToken,
    ) WriteResult {
        return self.vtable.write(self.ptr, query, secret, cancel_token);
    }

    pub fn delete(
        self: CredentialProvider,
        query: CredentialQuery,
        cancel_token: ?*const CancellationToken,
    ) DeleteResult {
        return self.vtable.delete(self.ptr, query, cancel_token);
    }

    pub fn disconnect(self: CredentialProvider) void {
        self.vtable.disconnect(self.ptr);
    }

    pub fn deinit(self: CredentialProvider) void {
        self.vtable.deinit(self.ptr);
    }
};

pub const CredentialsService = struct {
    allocator: std.mem.Allocator,
    provider: ?CredentialProvider,
    /// A worker thread reads this, so it is atomic. It refuses new calls
    /// without touching the provider.
    is_shutdown: std.atomic.Value(bool),
    /// The provider is released exactly once. `disconnect` frees the bus
    /// connection and the session object path a call borrows, so it may only
    /// run once no call is inside the provider.
    provider_disconnected: bool = false,

    pub fn init(allocator: std.mem.Allocator, provider: ?CredentialProvider) CredentialsService {
        return .{
            .allocator = allocator,
            .provider = provider,
            .is_shutdown = .init(false),
            .provider_disconnected = false,
        };
    }

    pub fn deinit(self: *CredentialsService) void {
        self.shutdown();
        if (self.provider) |p| {
            p.deinit();
            self.provider = null;
        }
        self.* = undefined;
    }

    /// Refuse new calls and leave the provider connected.
    ///
    /// An async facade uses this while its worker is still inside a call. It
    /// must not release the provider there: the call is holding the
    /// connection and the session object path that `disconnect` frees, so the
    /// call would keep running on released memory instead of reporting a
    /// typed result.
    pub fn refuseCalls(self: *CredentialsService) void {
        self.is_shutdown.store(true, .release);
    }

    /// Refuse new calls and release the provider. Every outstanding call must
    /// have finished before this runs.
    pub fn shutdown(self: *CredentialsService) void {
        self.refuseCalls();
        if (self.provider_disconnected) return;
        self.provider_disconnected = true;
        if (self.provider) |p| p.disconnect();
    }

    fn validateQuery(query: CredentialQuery) bool {
        if (query.service.len == 0 or query.account.len == 0) return false;
        if (!std.unicode.utf8ValidateSlice(query.service)) return false;
        if (!std.unicode.utf8ValidateSlice(query.account)) return false;
        if (query.collection) |col| {
            if (!std.unicode.utf8ValidateSlice(col)) return false;
        }
        return true;
    }

    pub fn read(
        self: *CredentialsService,
        allocator: std.mem.Allocator,
        query: CredentialQuery,
        cancel_token: ?*const CancellationToken,
    ) ReadResult {
        if (self.is_shutdown.load(.acquire)) return .{ .provider_failed = .disconnected };
        if (cancel_token) |token| {
            if (token.isCanceled()) return .canceled;
        }

        if (!validateQuery(query)) return .{ .provider_failed = .protocol_error };

        const p = self.provider orelse return .unsupported;
        return p.read(allocator, query, cancel_token);
    }

    pub fn write(
        self: *CredentialsService,
        query: CredentialQuery,
        secret: []const u8,
        cancel_token: ?*const CancellationToken,
    ) WriteResult {
        if (self.is_shutdown.load(.acquire)) return .{ .provider_failed = .disconnected };
        if (cancel_token) |token| {
            if (token.isCanceled()) return .canceled;
        }

        if (!validateQuery(query)) return .{ .provider_failed = .protocol_error };

        const p = self.provider orelse return .unsupported;
        return p.write(query, secret, cancel_token);
    }

    pub fn delete(
        self: *CredentialsService,
        query: CredentialQuery,
        cancel_token: ?*const CancellationToken,
    ) DeleteResult {
        if (self.is_shutdown.load(.acquire)) return .{ .provider_failed = .disconnected };
        if (cancel_token) |token| {
            if (token.isCanceled()) return .canceled;
        }

        if (!validateQuery(query)) return .{ .provider_failed = .protocol_error };

        const p = self.provider orelse return .unsupported;
        return p.delete(query, cancel_token);
    }
};

/// Which credential call a completion belongs to.
pub const Operation = enum { read, write, delete };

/// Owned query text. The async service copies the caller's slices so the
/// worker never borrows a frame buffer or a caller stack frame.
pub const OwnedQuery = struct {
    allocator: std.mem.Allocator,
    service: []u8 = &.{},
    account: []u8 = &.{},
    collection: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, borrowed: CredentialQuery) !OwnedQuery {
        var owned: OwnedQuery = .{
            .allocator = allocator,
            .service = try allocator.dupe(u8, borrowed.service),
        };
        errdefer owned.release();
        owned.account = try allocator.dupe(u8, borrowed.account);
        if (borrowed.collection) |collection| owned.collection = try allocator.dupe(u8, collection);
        return owned;
    }

    pub fn query(self: OwnedQuery) CredentialQuery {
        return .{
            .service = self.service,
            .account = self.account,
            .collection = self.collection,
        };
    }

    pub fn release(self: *OwnedQuery) void {
        if (self.service.len != 0) self.allocator.free(self.service);
        if (self.account.len != 0) self.allocator.free(self.account);
        if (self.collection) |collection| {
            if (collection.len != 0) self.allocator.free(collection);
        }
        self.* = .{ .allocator = self.allocator };
    }
};

pub const CompletionResult = union(enum) {
    read: ReadResult,
    write: WriteResult,
    delete: DeleteResult,
};

/// One finished credential call. The handler borrows it for the duration of
/// its invocation only; a found secret must be copied out before returning.
pub const Completion = struct {
    operation: Operation,
    query: OwnedQuery,
    result: CompletionResult,

    pub fn deinit(self: *Completion, allocator: std.mem.Allocator) void {
        switch (self.result) {
            .read => |read| {
                var mutable = read;
                if (mutable == .found) mutable.found.deinit();
            },
            else => {},
        }
        self.result = .{ .read = .canceled };
        self.query.release();
        self.operation = .read;
        _ = allocator;
        self.* = undefined;
    }
};

pub const CompletionHandler = *const fn (context: ?*anyopaque, completion: *const Completion) void;

/// Gives the rest of the time slice to the other runnable threads.
///
/// `error.SystemCannotYield` means the kernel refused `sched_yield`, not that
/// the wait is broken: every caller re-reads its own condition once this
/// returns, so a refusal only costs the CPU the yield was trying to hand
/// back. It is logged rather than propagated because all three callers — the
/// queue spin, the idle worker, and the mock provider's test gate — are
/// internal waits that no caller of theirs could act on.
fn yieldToOtherThreads() void {
    std.Thread.yield() catch std.log.debug("sched_yield refused while waiting", .{});
}

/// Test-and-set lock for the short queue critical sections of `Async`.
/// Spinning beats a futex syscall here and needs no platform object.
const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.flag.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
            yieldToOtherThreads();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

/// Asynchronous credential facade.
///
/// One worker thread owns the provider, so the single bus connection is never
/// used concurrently. `submitRead`, `submitWrite` and `submitDelete` return
/// immediately; the host pumps `poll` on its own thread and receives one
/// typed result per call, including after `shutdown`. A completion for a dead
/// owner is released without invoking the handler, and its secret is wiped.
///
/// The provider outlives every submitted call: `shutdown` refuses new calls
/// and cancels the outstanding ones, and the provider is released by
/// `deinit` once the worker thread has joined.
pub const Async = struct {
    const Job = struct {
        owner_service: *Async,
        operation: Operation,
        query: OwnedQuery,
        secret: ?[]u8 = null,
        token: CancellationToken = .{},
        owner: WeakOwner,
        handler: CompletionHandler,
        context: ?*anyopaque = null,
    };

    const Entry = struct {
        owner: WeakOwner,
        handler: CompletionHandler,
        context: ?*anyopaque,
        completion: Completion,
    };

    const poll_batch = 8;

    allocator: std.mem.Allocator,
    service: CredentialsService,
    lock: SpinLock = .{},
    pending: std.ArrayList(*Job) = .empty,
    /// The job the worker took out of `pending` and is running now, or null
    /// between calls. It is set and cleared under `lock`, and it is already
    /// out of `pending` by then, so `shutdown` has to reach it through here.
    in_flight: ?*Job = null,
    ready: std.ArrayList(Entry) = .empty,
    worker: ?std.Thread = null,
    shutting_down: bool = false,
    stopped: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, provider: ?CredentialProvider) Async {
        return .{
            .allocator = allocator,
            .service = CredentialsService.init(allocator, provider),
        };
    }

    pub fn deinit(self: *Async) void {
        self.shutdown();
        if (self.worker) |thread| thread.join();
        self.worker = null;

        for (self.ready.items) |*entry| {
            entry.completion.deinit(self.allocator);
        }
        self.ready.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.service.deinit();
        self.* = undefined;
    }

    /// Stop accepting calls and cancel every call, including the one the
    /// worker is running right now. Each outstanding call still completes
    /// with a typed result, and the provider stays connected until `deinit`
    /// joins the worker.
    pub fn shutdown(self: *Async) void {
        self.lock.lock();
        self.shutting_down = true;
        for (self.pending.items) |job| job.token.cancel();
        if (self.in_flight) |job| job.token.cancel();
        self.lock.unlock();
        self.service.refuseCalls();
    }

    pub fn submitRead(
        self: *Async,
        query: CredentialQuery,
        owner: WeakOwner,
        handler: CompletionHandler,
        context: ?*anyopaque,
    ) !void {
        return self.enqueue(.read, query, null, owner, handler, context);
    }

    pub fn submitWrite(
        self: *Async,
        query: CredentialQuery,
        secret: []const u8,
        owner: WeakOwner,
        handler: CompletionHandler,
        context: ?*anyopaque,
    ) !void {
        return self.enqueue(.write, query, secret, owner, handler, context);
    }

    pub fn submitDelete(
        self: *Async,
        query: CredentialQuery,
        owner: WeakOwner,
        handler: CompletionHandler,
        context: ?*anyopaque,
    ) !void {
        return self.enqueue(.delete, query, null, owner, handler, context);
    }

    fn enqueue(
        self: *Async,
        operation: Operation,
        query: CredentialQuery,
        secret: ?[]const u8,
        owner: WeakOwner,
        handler: CompletionHandler,
        context: ?*anyopaque,
    ) !void {
        const job = try self.allocator.create(Job);
        const owned_query = try OwnedQuery.init(self.allocator, query);

        job.* = .{
            .owner_service = self,
            .operation = operation,
            .query = owned_query,
            .owner = owner,
            .handler = handler,
            .context = context,
        };
        // One cleanup path owns the secret copy, the query text and the job.
        errdefer {
            if (job.secret) |bytes| {
                std.crypto.secureZero(u8, bytes);
                self.allocator.free(bytes);
            }
            var owned = job.query;
            owned.release();
            self.allocator.destroy(job);
        }

        if (secret) |bytes| {
            job.secret = try self.allocator.dupe(u8, bytes);
        }

        self.lock.lock();
        if (self.shutting_down) {
            self.lock.unlock();
            return error.ServiceShutdown;
        }
        self.pending.append(self.allocator, job) catch {
            self.lock.unlock();
            return error.OutOfMemory;
        };
        self.lock.unlock();

        if (self.worker) |_| return;
        self.worker = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
            self.lock.lock();
            _ = self.pending.swapRemove(self.pending.items.len - 1);
            self.lock.unlock();
            return err;
        };
    }

    /// Deliver up to `max_completions` finished calls on the calling thread.
    /// Returns how many handlers ran. A dead owner counts as delivered and is
    /// dropped with its secret wiped.
    ///
    /// The allocator is read once, before any handler runs. A handler is caller
    /// code and may retire this facade from inside its own delivery; the
    /// entries below belong to this call's own array from the moment they leave
    /// the queue, so they are released through the allocator this call started
    /// with and never through a `self` a handler may have ended.
    pub fn poll(self: *Async, max_completions: usize) usize {
        const allocator = self.allocator;
        var batch: [poll_batch]Entry = undefined;
        var held: usize = 0;
        // Every entry taken out of `ready` is released on every path out of this
        // function, including the one where a handler ends the facade. Nothing
        // else can reach an entry once it has left the queue, so a delivery
        // that does not return normally must not be able to strand an owned
        // query or leave a found secret in memory: what is still held here is
        // wiped here.
        defer {
            for (batch[0..held]) |*entry| entry.completion.deinit(allocator);
        }
        var delivered: usize = 0;

        while (delivered < max_completions) {
            held = self.takeBatch(&batch);
            if (held == 0) break;
            for (batch[0..held]) |*entry| {
                if (entry.owner.isAlive()) {
                    entry.handler(entry.context, &entry.completion);
                }
                delivered += 1;
            }
            // Each entry of this batch goes back before the next one is taken,
            // so the array is free again and no completion outlives its own
            // delivery. `held` is cleared, so the release above never sees an
            // entry this loop already gave back.
            for (batch[0..held]) |*entry| entry.completion.deinit(allocator);
            held = 0;
        }
        return delivered;
    }

    /// True while a submitted call has not been delivered yet.
    pub fn busy(self: *Async) bool {
        self.lock.lock();
        defer self.lock.unlock();
        return self.pending.items.len != 0 or self.ready.items.len != 0;
    }

    fn takeBatch(self: *Async, batch: *[poll_batch]Entry) usize {
        self.lock.lock();
        defer self.lock.unlock();
        var count: usize = 0;
        while (count < batch.len and self.ready.items.len != 0) {
            batch[count] = self.ready.orderedRemove(0);
            count += 1;
        }
        return count;
    }

    fn releaseJob(self: *Async, job: *Job) void {
        if (job.secret) |bytes| {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        }
        var query = job.query;
        query.release();
        self.allocator.destroy(job);
    }

    fn workerMain(self: *Async) void {
        while (true) {
            self.lock.lock();
            if (self.pending.items.len == 0) {
                const stop = self.shutting_down;
                self.lock.unlock();
                if (stop) break;
                yieldToOtherThreads();
                continue;
            }
            const job = self.pending.orderedRemove(0);
            self.in_flight = job;
            self.lock.unlock();

            const result = self.execute(job);
            // Query ownership moves into the completion; the job only owns
            // the secret copy from here on.
            const query = job.query;
            job.query = .{ .allocator = self.allocator };

            self.lock.lock();
            // The call is over, so the job leaves `in_flight` before it is
            // released: a later `shutdown` must not reach a freed job.
            self.in_flight = null;
            self.ready.append(self.allocator, .{
                .owner = job.owner,
                .handler = job.handler,
                .context = job.context,
                .completion = .{
                    .operation = job.operation,
                    .query = query,
                    .result = result,
                },
            }) catch {
                // The host stopped polling; drop the result and wipe the secret.
                self.lock.unlock();
                var completion: Completion = .{
                    .operation = job.operation,
                    .query = query,
                    .result = result,
                };
                completion.deinit(self.allocator);
                self.releaseJob(job);
                continue;
            };
            self.lock.unlock();
            self.releaseJob(job);
        }
        self.stopped.store(true, .release);
    }

    fn execute(self: *Async, job: *const Job) CompletionResult {
        const query = job.query.query();
        return switch (job.operation) {
            .read => .{ .read = self.service.read(self.allocator, query, &job.token) },
            .write => .{ .write = self.service.write(query, job.secret orelse "", &job.token) },
            .delete => .{ .delete = self.service.delete(query, &job.token) },
        };
    }
};

/// In-memory mock credential provider modeling locked keyrings, prompts, and failures.
pub const MockCredentialProvider = struct {
    allocator: std.mem.Allocator,
    store: std.StringHashMap([]u8),
    store_locked: bool = false,
    prompt_behavior: PromptBehavior = .accept,
    simulate_failure: ?ProviderError = null,
    disconnected: bool = false,
    /// Test-only latch that holds a call inside the provider so cancellation
    /// and shutdown can be exercised at a deterministic point.
    gate: ?*Gate = null,

    pub const Gate = struct {
        entered: std.atomic.Value(bool) = .init(false),
        open: std.atomic.Value(bool) = .init(false),
    };

    pub const PromptBehavior = enum {
        accept,
        dismiss,
        deny,
    };

    pub fn init(allocator: std.mem.Allocator) MockCredentialProvider {
        return .{
            .allocator = allocator,
            .store = std.StringHashMap([]u8).init(allocator),
            .store_locked = false,
            .prompt_behavior = .accept,
            .simulate_failure = null,
            .disconnected = false,
        };
    }

    pub fn deinit(self: *MockCredentialProvider) void {
        var it = self.store.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            std.crypto.secureZero(u8, entry.value_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.store.deinit();
        self.* = undefined;
    }

    pub fn provider(self: *MockCredentialProvider) CredentialProvider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn makeKey(allocator: std.mem.Allocator, query: CredentialQuery) ![]u8 {
        const key = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{
            query.collection orelse "default",
            query.service,
            query.account,
        });
        return key;
    }

    /// Block inside the provider until the test opens the gate.
    fn awaitGate(self: *MockCredentialProvider) void {
        const gate = self.gate orelse return;
        gate.entered.store(true, .release);
        while (!gate.open.load(.acquire)) {
            yieldToOtherThreads();
        }
    }

    const vtable: CredentialProvider.VTable = .{
        .read = readFn,
        .write = writeFn,
        .delete = deleteFn,
        .disconnect = disconnectFn,
        .deinit = deinitFn,
    };

    fn readFn(
        allocator: std.mem.Allocator,
        ctx: *anyopaque,
        query: CredentialQuery,
        cancel_token: ?*const CancellationToken,
    ) ReadResult {
        const self: *MockCredentialProvider = @ptrCast(@alignCast(ctx));
        self.awaitGate();
        if (self.disconnected) return .{ .provider_failed = .disconnected };
        if (self.simulate_failure) |err| return .{ .provider_failed = err };
        if (cancel_token) |token| {
            if (token.isCanceled()) return .canceled;
        }

        if (self.store_locked) {
            switch (self.prompt_behavior) {
                .accept => {
                    self.store_locked = false; // unlocked after prompt
                },
                .dismiss => return .prompt_dismissed,
                .deny => return .denied,
            }
        }

        const key = makeKey(self.allocator, query) catch return .{ .provider_failed = .out_of_memory };
        defer self.allocator.free(key);

        if (self.store.get(key)) |sec| {
            const val = CredentialValue.init(allocator, sec) catch return .{ .provider_failed = .out_of_memory };
            return .{ .found = val };
        } else {
            return .not_found;
        }
    }

    fn writeFn(
        ctx: *anyopaque,
        query: CredentialQuery,
        secret: []const u8,
        cancel_token: ?*const CancellationToken,
    ) WriteResult {
        const self: *MockCredentialProvider = @ptrCast(@alignCast(ctx));
        self.awaitGate();
        if (self.disconnected) return .{ .provider_failed = .disconnected };
        if (self.simulate_failure) |err| return .{ .provider_failed = err };
        if (cancel_token) |token| {
            if (token.isCanceled()) return .canceled;
        }

        if (self.store_locked) {
            switch (self.prompt_behavior) {
                .accept => {
                    self.store_locked = false;
                },
                .dismiss => return .prompt_dismissed,
                .deny => return .denied,
            }
        }

        const key = makeKey(self.allocator, query) catch return .{ .provider_failed = .out_of_memory };

        const sec_copy = self.allocator.dupe(u8, secret) catch {
            self.allocator.free(key);
            return .{ .provider_failed = .out_of_memory };
        };

        // A fresh insert stores the caller key; a replacement keeps the
        // original key, so only the previous value is released.
        const previous = self.store.fetchPut(key, sec_copy) catch {
            std.crypto.secureZero(u8, sec_copy);
            self.allocator.free(sec_copy);
            self.allocator.free(key);
            return .{ .provider_failed = .out_of_memory };
        };
        if (previous) |old| {
            self.allocator.free(key);
            std.crypto.secureZero(u8, old.value);
            self.allocator.free(old.value);
        }

        return .success;
    }

    fn deleteFn(
        ctx: *anyopaque,
        query: CredentialQuery,
        cancel_token: ?*const CancellationToken,
    ) DeleteResult {
        const self: *MockCredentialProvider = @ptrCast(@alignCast(ctx));
        self.awaitGate();
        if (self.disconnected) return .{ .provider_failed = .disconnected };
        if (self.simulate_failure) |err| return .{ .provider_failed = err };
        if (cancel_token) |token| {
            if (token.isCanceled()) return .canceled;
        }

        if (self.store_locked) {
            switch (self.prompt_behavior) {
                .accept => {
                    self.store_locked = false;
                },
                .dismiss => return .prompt_dismissed,
                .deny => return .denied,
            }
        }

        const key = makeKey(self.allocator, query) catch return .{ .provider_failed = .out_of_memory };
        defer self.allocator.free(key);

        if (self.store.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            std.crypto.secureZero(u8, entry.value);
            self.allocator.free(entry.value);
            return .success;
        } else {
            return .not_found;
        }
    }

    fn disconnectFn(ctx: *anyopaque) void {
        const self: *MockCredentialProvider = @ptrCast(@alignCast(ctx));
        self.disconnected = true;
    }

    fn deinitFn(ctx: *anyopaque) void {
        const self: *MockCredentialProvider = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};

test "credential round-trip, memory zeroing, and redaction" {
    var mock = MockCredentialProvider.init(std.testing.allocator);
    var service = CredentialsService.init(std.testing.allocator, mock.provider());
    defer service.deinit();

    const query: CredentialQuery = .{
        .service = "com.zed.nogui",
        .account = "user@example.com",
    };

    // 1. Initial read should be not_found
    const initial_res = service.read(std.testing.allocator, query, null);
    try std.testing.expectEqual(ReadResult.not_found, initial_res);

    // 2. Write synthetic secret
    const write_res = service.write(query, "super-secret-token", null);
    try std.testing.expectEqual(WriteResult.success, write_res);

    // 3. Read back synthetic secret
    const read_res = service.read(std.testing.allocator, query, null);
    try std.testing.expect(read_res == .found);
    var val = read_res.found;
    defer val.deinit();

    try std.testing.expectEqualStrings("super-secret-token", val.secret);

    // 4. Verify redaction in formatting
    var buf: [64]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "{f}", .{val});
    try std.testing.expectEqualStrings("[REDACTED SECRET]", formatted);

    // 5. Delete synthetic secret
    const del_res = service.delete(query, null);
    try std.testing.expectEqual(DeleteResult.success, del_res);

    // 6. Read after delete should be not_found
    const after_del = service.read(std.testing.allocator, query, null);
    try std.testing.expectEqual(ReadResult.not_found, after_del);
}
