//! E02: the macOS Keychain as a `credentials.CredentialProvider`.
//!
//! WHAT THE PLATFORM OFFERS. The data-protection keychain has no named
//! collections, so a query's `collection` names the keychain ACCESS GROUP
//! here. That is a real macOS concept, and it is not free: an application
//! without the matching entitlement gets `errSecMissingEntitlement`, which is
//! reported as `denied`. The alternative — quietly searching the default group
//! and returning whatever was there — would be a credential leak dressed as a
//! success, so it is not implemented.
//!
//! WHY THE MAIN THREAD. The Keychain shows its "allow access" prompt from the
//! calling thread, and AppKit-backed prompts must come from the main thread.
//! The shared credential facade runs its provider on a worker, so this
//! provider marshals every call onto the main thread and waits for it there.
//! The main thread is SDL's, which the host already pumps; nothing here starts
//! a thread of its own.
//!
//! NO PLAINTEXT FALLBACK. A locked store, a dismissed prompt, a denied item, a
//! missing item and a platform failure are five different results, and a
//! secret is never logged, formatted or left in a buffer after the call that
//! read it.
const std = @import("std");
const native = @import("native.zig");
const credentials = @import("../credentials.zig");

const Error = native.Error;
const Status = native.Status;
const shim = native.shim;

/// The Security status the shim saw. The provider reports the shim's coarse
/// code and keeps the raw `OSStatus` here for the mapping below, so a
/// decision is made once instead of by string matching on a number.
const os_status_err_sec_success: i32 = 0;
const os_status_err_sec_item_not_found: i32 = -25300;
const os_status_err_sec_duplicate_item: i32 = -25299;
const os_status_err_sec_user_canceled: i32 = -128;
const os_status_err_sec_auth_failed: i32 = -25293;
const os_status_err_sec_missing_entitlement: i32 = -34018;
const os_status_err_sec_interaction_not_allowed: i32 = -25308;
const os_status_err_sec_interaction_required: i32 = -25315;
const os_status_err_sec_not_available: i32 = -25291;

/// What one Keychain call reported, in the platform's own terms.
const Verdict = enum {
    ok,
    not_found,
    /// The item exists but the store is locked and no answer was possible.
    locked,
    /// A person dismissed the platform's own prompt.
    prompt_dismissed,
    /// The item, the group or the access was refused.
    denied,
    refused,
    platform_failed,

    fn of(status: i32) Verdict {
        return switch (status) {
            os_status_err_sec_success => .ok,
            os_status_err_sec_item_not_found => .not_found,
            os_status_err_sec_interaction_not_allowed, os_status_err_sec_interaction_required => .locked,
            os_status_err_sec_user_canceled => .prompt_dismissed,
            os_status_err_sec_auth_failed, os_status_err_sec_missing_entitlement => .denied,
            os_status_err_sec_not_available => .denied,
            os_status_err_sec_duplicate_item => .refused,
            else => .platform_failed,
        };
    }
};

/// One marshalled call, from the worker thread to the main thread and back.
///
/// It lives on the calling thread's stack: `native.onMain` does not return
/// until the work has run, so nothing outlives this value.
const Call = struct {
    gpa: std.mem.Allocator,
    operation: enum { read, write, delete },
    service: [:0]const u8,
    account: [:0]const u8,
    access_group: ?[:0]const u8,
    secret: ?[]const u8 = null,
    /// Where a read puts the secret. Zeroed before the call returns.
    scratch: [4096]u8,
    /// Storage for a secret longer than the scratch. Owned by this record and
    /// released by `wipe`, because a secret may not outlive the call.
    grown: ?[]u8 = null,
    produced: usize = 0,
    status: Status = .ok,
    os_status: i32 = 0,
    /// The caller re-checks its token before the work starts, so a token
    /// cancelled while the call was queued stops it here.
    cancel: ?*const credentials.CancellationToken = null,

    fn wipe(self: *Call) void {
        std.crypto.secureZero(u8, &self.scratch);
        if (self.grown) |grown| {
            std.crypto.secureZero(u8, grown);
            self.gpa.free(grown);
            self.grown = null;
        }
        self.produced = 0;
    }
};

/// Runs on the main thread. It owns no lock: the calling worker is blocked
/// while this runs, so the record is only ever touched by one thread at a
/// time.
fn runOnMain(call: *Call) void {
    // onMain refuses a build without the shim before invoking this callback.
    if (!native.available) unreachable;
    if (call.cancel) |token| {
        if (token.isCanceled()) {
            call.status = .ok;
            call.os_status = os_status_err_sec_user_canceled;
            return;
        }
    }
    switch (call.operation) {
        .read => {
            var needed: usize = 0;
            var raw = shim.nogui_macos_keychain_read(
                call.service.ptr,
                call.account.ptr,
                if (call.access_group) |group| group.ptr else null,
                &call.scratch,
                call.scratch.len,
                &needed,
            );
            call.status = Status.of(raw);
            // The shim refuses a buffer that cannot hold the secret AND its
            // terminating NUL, and it reports the length of the SECRET. So a
            // secret of exactly the scratch length is refused too: comparing
            // `needed` against the capacity with `>` leaves that case without a
            // retry, `produced` at zero and the Security status at
            // `errSecSuccess`, which reads as a FOUND credential holding an
            // EMPTY password. `>=` is the shim's own test.
            if (call.status == .buffer and needed >= call.scratch.len) {
                // A secret that does not fit is read into storage this call
                // owns, rather than being truncated or refused for being long.
                // The allocation is one byte more than the secret because the
                // retry has to satisfy the same NUL rule that refused it.
                const grown = call.gpa.alloc(u8, needed + 1) catch {
                    call.status = .memory;
                    call.os_status = keychainOsStatus();
                    return;
                };
                call.grown = grown;
                needed = 0;
                raw = shim.nogui_macos_keychain_read(
                    call.service.ptr,
                    call.account.ptr,
                    if (call.access_group) |group| group.ptr else null,
                    grown.ptr,
                    grown.len,
                    &needed,
                );
                call.status = Status.of(raw);
            }
            call.produced = if (call.status.isOk()) needed else 0;
        },
        .write => {
            const secret = call.secret orelse {
                call.status = .argument;
                return;
            };
            call.status = Status.of(shim.nogui_macos_keychain_write(
                call.service.ptr,
                call.account.ptr,
                if (call.access_group) |group| group.ptr else null,
                secret.ptr,
                secret.len,
            ));
        },
        .delete => {
            call.status = Status.of(shim.nogui_macos_keychain_delete(
                call.service.ptr,
                call.account.ptr,
                if (call.access_group) |group| group.ptr else null,
            ));
        },
    }
    call.os_status = keychainOsStatus();
}

fn keychainOsStatus() i32 {
    if (!native.available) return 0;
    const raw = shim.nogui_macos_keychain_last_status();
    if (raw < 0) return raw;
    return 0;
}

/// The macOS Keychain, as the shared credential service's provider.
pub const Provider = struct {
    allocator: std.mem.Allocator,
    /// Set once the provider is disconnected. A call after that reports
    /// `disconnected` without touching the keychain, so a late worker cannot
    /// reach a store the host has already released.
    connected: bool = true,

    pub fn init(allocator: std.mem.Allocator) Provider {
        return .{ .allocator = allocator };
    }

    /// The vtable the shared service drives.
    pub fn provider(self: *Provider) credentials.CredentialProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Refuse new calls. The provider stays allocated: the worker that owns it
    /// is still inside a call, and freeing it here would run that call on
    /// released memory.
    pub fn disconnect(self: *Provider) void {
        self.connected = false;
    }

    pub fn deinit(self: *Provider) void {
        self.* = undefined;
    }

    /// Whether the provider can still reach the keychain.
    pub fn isConnected(self: *const Provider) bool {
        return self.connected;
    }

    const vtable: credentials.CredentialProvider.VTable = .{
        .read = readFn,
        .write = writeFn,
        .delete = deleteFn,
        .disconnect = disconnectFn,
        .deinit = deinitFn,
    };

    const OwnedQuery = struct {
        service: [:0]u8,
        account: [:0]u8,
        group: ?[:0]u8,
    };

    /// Copy the query's text into NUL-terminated storage the main-thread call
    /// can read. The caller's slices may die the moment this returns.
    fn scratchQuery(self: *Provider, query: credentials.CredentialQuery) Error!OwnedQuery {
        const service = self.allocator.dupeSentinel(u8, query.service, 0) catch return error.OutOfMemory;
        errdefer self.allocator.free(service);
        const account = self.allocator.dupeSentinel(u8, query.account, 0) catch return error.OutOfMemory;
        errdefer self.allocator.free(account);
        if (query.collection) |collection| {
            const group = self.allocator.dupeSentinel(u8, collection, 0) catch return error.OutOfMemory;
            return .{ .service = service, .account = account, .group = group };
        }
        return .{ .service = service, .account = account, .group = null };
    }

    fn releaseQuery(self: *Provider, owned: anytype) void {
        self.allocator.free(owned.service);
        self.allocator.free(owned.account);
        if (owned.group) |group| self.allocator.free(group);
    }

    fn readFn(
        allocator: std.mem.Allocator,
        ctx: *anyopaque,
        query: credentials.CredentialQuery,
        cancel_token: ?*const credentials.CancellationToken,
    ) credentials.ReadResult {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        if (!self.connected) return .{ .provider_failed = .disconnected };
        if (cancel_token) |token| {
            if (token.isCanceled()) return .canceled;
        }
        if (!native.available) return .unsupported;
        const owned = self.scratchQuery(query) catch return .{ .provider_failed = .out_of_memory };
        defer self.releaseQuery(owned);

        var call: Call = .{
            .gpa = self.allocator,
            .operation = .read,
            .service = owned.service,
            .account = owned.account,
            .access_group = owned.group,
            // SAFETY: the shim writes the secret here and every read is
            // gated by produced; `wipe` zeroes the buffer on the way out.
            .scratch = undefined,
            .cancel = cancel_token,
        };
        defer call.wipe();
        native.onMain(Call, runOnMain, &call) catch |err| switch (err) {
            error.ShimUnavailable => return .unsupported,
            else => return .{ .provider_failed = .disconnected },
        };
        if (call.cancel) |token| {
            if (token.isCanceled()) return .canceled;
        }
        switch (Verdict.of(call.os_status)) {
            .ok => {
                const bytes = if (call.grown) |grown| grown[0..call.produced] else call.scratch[0..call.produced];
                const secret = credentials.CredentialValue.init(allocator, bytes) catch
                    return .{ .provider_failed = .out_of_memory };
                return .{ .found = secret };
            },
            .not_found => return .not_found,
            .locked => return .locked,
            .prompt_dismissed => return .prompt_dismissed,
            .denied => return .denied,
            .refused => return .{ .provider_failed = .rejected },
            .platform_failed => return .{ .provider_failed = .rejected },
        }
    }

    fn writeFn(
        ctx: *anyopaque,
        query: credentials.CredentialQuery,
        secret: []const u8,
        cancel_token: ?*const credentials.CancellationToken,
    ) credentials.WriteResult {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        if (!self.connected) return .{ .provider_failed = .disconnected };
        if (cancel_token) |token| {
            if (token.isCanceled()) return .canceled;
        }
        if (!native.available) return .unsupported;
        const owned = self.scratchQuery(query) catch return .{ .provider_failed = .out_of_memory };
        defer self.releaseQuery(owned);

        var call: Call = .{
            .gpa = self.allocator,
            .operation = .write,
            .service = owned.service,
            .account = owned.account,
            .access_group = owned.group,
            // SAFETY: a write never reads the scratch; `wipe` zeroes it.
            .scratch = undefined,
            .secret = secret,
            .cancel = cancel_token,
        };
        native.onMain(Call, runOnMain, &call) catch |err| switch (err) {
            error.ShimUnavailable => return .unsupported,
            else => return .{ .provider_failed = .disconnected },
        };
        if (call.cancel) |token| {
            if (token.isCanceled()) return .canceled;
        }
        return switch (Verdict.of(call.os_status)) {
            .ok => .success,
            .locked => .locked,
            .prompt_dismissed => .prompt_dismissed,
            .denied => .denied,
            .not_found => .success,
            .refused, .platform_failed => .{ .provider_failed = .rejected },
        };
    }

    fn deleteFn(
        ctx: *anyopaque,
        query: credentials.CredentialQuery,
        cancel_token: ?*const credentials.CancellationToken,
    ) credentials.DeleteResult {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        if (!self.connected) return .{ .provider_failed = .disconnected };
        if (cancel_token) |token| {
            if (token.isCanceled()) return .canceled;
        }
        if (!native.available) return .unsupported;
        const owned = self.scratchQuery(query) catch return .{ .provider_failed = .out_of_memory };
        defer self.releaseQuery(owned);

        var call: Call = .{
            .gpa = self.allocator,
            .operation = .delete,
            .service = owned.service,
            .account = owned.account,
            .access_group = owned.group,
            // SAFETY: a delete never reads the scratch; `wipe` zeroes it.
            .scratch = undefined,
            .cancel = cancel_token,
        };
        native.onMain(Call, runOnMain, &call) catch |err| switch (err) {
            error.ShimUnavailable => return .unsupported,
            else => return .{ .provider_failed = .disconnected },
        };
        if (call.cancel) |token| {
            if (token.isCanceled()) return .canceled;
        }
        return switch (Verdict.of(call.os_status)) {
            .ok => .success,
            .not_found => .not_found,
            .locked => .locked,
            .prompt_dismissed => .prompt_dismissed,
            .denied => .denied,
            .refused, .platform_failed => .{ .provider_failed = .rejected },
        };
    }

    fn disconnectFn(ctx: *anyopaque) void {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        self.disconnect();
    }

    fn deinitFn(ctx: *anyopaque) void {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};

test "api-w23 macos keychain provider reports disconnect before it reaches the store" {
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try std.testing.expect(provider.isConnected());
    const handle = provider.provider();
    provider.disconnect();
    try std.testing.expect(!provider.isConnected());
    // A call that arrives after a disconnect is refused, so a late worker
    // cannot reach a store the host has already released.
    const result = handle.read(
        std.testing.allocator,
        .{ .service = "svc", .account = "acct" },
        null,
    );
    try std.testing.expect(result == .provider_failed);
}
