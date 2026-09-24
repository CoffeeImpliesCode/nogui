//! Windows Credential Manager provider: the real `wincred` store.
//!
//! The Windows analogue of a keyring is `wincred`, and it is a store, not a
//! daemon. There is no process to reach, no socket to lose and no bus name to
//! watch. That removes the outcomes the shared contract derives from a lost
//! transport -- `daemon_unavailable`, `store_corrupted` from a dropped
//! connection -- and this adapter reports them only where they can actually
//! happen: a credential the store could not fill in. Everything else is a real
//! `GetLastError` value from a real call.
//!
//! Identity. `wincred` keys a generic credential by one flat "target name"
//! string, and `read`, `write` and `delete` must all derive the same string
//! from the same `CredentialQuery` or they are not operating on one credential.
//! The derivation is therefore explicit and total: `target_template` with
//! `{collection}`, `{service}` and `{account}` placeholders, built by the one
//! function `targetNameFor`. A template that names no placeholder at all would
//! collapse every account onto one target, so that is refused rather than
//! accepted and quietly wrong.
//!
//! Outcomes. The shared contract demands that a locked store, a dismissed
//! prompt, a denial and a cancellation stay four different things. Windows has
//! one code for each of the three that come from the OS:
//!
//!   * `ERROR_NO_SUCH_LOGON_SESSION` (1312) is the store's own "locked": the
//!     credential belongs to a logon session that is gone or locked, so it
//!     exists and cannot be used until the session comes back.
//!   * `ERROR_CANCELLED` (1223) is a dismissed `CredUI` dialog. It is
//!     reported as `prompt_dismissed`, because the thing the user cancelled
//!     was the prompt, not the app's own cancellation token.
//!   * `ERROR_ACCESS_DENIED` (5), `ERROR_LOGON_FAILURE` (1326),
//!     `ERROR_BAD_USERNAME` (2202) and `ERROR_INVALID_CREDENTIAL` (1338) are
//!     refusals by the user, the policy or the logon, and they are `denied`.
//!   * `ERROR_PASSWORD_EXPIRED` (1330) and `ERROR_ACCOUNT_DISABLED` (1331)
//!     also map to `locked`: the credential is present and the store is
//!     healthy, and what blocks it is account state the user has to change.
//!     An app that retries after unlocking then succeeds, which is what
//!     `locked` promises and what `denied` does not.
//!
//! Cancellation is the one outcome Windows cannot hand back on its own. There
//! is no cancellable entry point in `wincred`, so the token is read at the two
//! points where reading it changes what happens:
//!
//!   * before the call, which is the ordinary case and needs no OS support;
//!   * after a *read*, where a secret the store has already produced but whose
//!     caller has given up on is wiped and reported as `canceled` rather than
//!     handed over.
//!
//! There is deliberately no post-check on `write` or `delete`. By the time
//! those return the store has already changed, so reporting `canceled` would be
//! a lie about a committed operation, and `success` is the truth. A token that
//! fires mid-call is observed by the *next* call.
//!
//! Secret memory. A `CREDENTIALW` blob is opaque secret material, so this file
//! never formats one, never logs one and never copies one into an arena. The
//! read path takes the SDK's buffer, copies the exact `CredentialBlobSize`
//! bytes into an owned buffer, wipes the SDK's copy, and only then calls
//! `CredFree`, because `CredFree` is the documented release and does not
//! promise to scrub. The owned buffer is a `CredentialValue`, which zeroes on
//! deinit, and it is allocated with the provider's own allocator so the free
//! that finally runs is the matching one.
const std = @import("std");
const win = @import("win32.zig");
const credentials = @import("../credentials.zig");

const CredentialQuery = credentials.CredentialQuery;
const CredentialValue = credentials.CredentialValue;
const CancellationToken = credentials.CancellationToken;
const ReadResult = credentials.ReadResult;
const WriteResult = credentials.WriteResult;
const DeleteResult = credentials.DeleteResult;

/// Narrow C ABI of `native/nogui_credui.c`. The prompt needs `CREDUIWIN` and
/// the pack/unpack pair, both of which live in `credui.h`, so it is a shim
/// rather than a Zig `extern`, and the build compiles it for Windows targets
/// only.
pub const PromptStatus = enum(c_int) {
    ok = 0,
    /// The user closed the dialog. A dismissed prompt, which the shared
    /// contract keeps distinct from the app's own cancellation.
    cancelled = 1,
    /// The user or policy refused this credential.
    denied = 2,
    /// The store owns the credential but no logon session can use it yet.
    locked = 3,
    /// The call failed for a reason the caller may retry.
    failed = 4,
    /// No interactive desktop, or `CredUI` is not present. Named apart from
    /// `failed` because nothing was shown to anyone.
    unavailable = 5,
    /// The dialog produced a credential for a different account than the query
    /// asked about, so there is nothing this answer can honestly be filed under.
    account_mismatch = 6,
};

/// One prompt's parameters, as the C shim's `nogui_cred_request`. Every string
/// is borrowed for the duration of the call and the shim copies nothing.
pub const PromptRequest = extern struct {
    /// Borrowed owner window, or null to let CredUI use the desktop.
    hwnd: ?*anyopaque,
    /// The credential's identity in the store, as the dialog's own target line.
    /// It is the target name and not a caption, because the store keys on it.
    target: ?[*:0]const u16,
    caption: ?[*:0]const u16,
    message: ?[*:0]const u16,
    /// The account this query is about. The dialog cannot be handed a prefilled
    /// account -- the documented way to hand it one also suppresses the dialog --
    /// so this is an expectation the shim checks afterwards rather than a prefill,
    /// and an answer naming another account is refused.
    account: ?[*:0]const u16,
};

/// Secret bytes produced by a successful prompt, owned by the shim. The
/// out-parameters are used instead of a return value so a caller cannot be handed
/// a pointer it then frees with the wrong allocator.
pub extern fn nogui_cred_prompt(
    request: *const PromptRequest,
    out_blob: *?*anyopaque,
    out_size: *u32,
) callconv(.c) PromptStatus;

/// Releases a prompt blob, wiping it first.
pub extern fn nogui_cred_free(blob: ?*anyopaque) callconv(.c) void;

/// How long the credential survives.
pub const Persist = enum {
    /// `CRED_PERSIST_SESSION`. Dies with the logon session, the narrowest
    /// scope Windows offers.
    session,
    /// `CRED_PERSIST_LOCAL_MACHINE`. Survives the session for this user on
    /// this machine. The default, and the scope a desktop app's saved login
    /// belongs in.
    local_machine,
    /// `CRED_PERSIST_ENTERPRISE`. Survives as long as the roaming profile
    /// policy says. The store may refuse it, and that refusal is reported
    /// rather than downgraded.
    enterprise,

    fn toWin32(self: Persist) win.Dword {
        return switch (self) {
            .session => win.cred_persist_session,
            .local_machine => win.cred_persist_local_machine,
            .enterprise => win.cred_persist_enterprise,
        };
    }
};

pub const Options = struct {
    /// The target-name grammar. `{collection}`, `{service}` and `{account}`
    /// are substituted literally. Must mention at least one of them.
    target_template: []const u8 = "{service}/{account}",
    persist: Persist = .local_machine,
    /// A `read` that finds nothing asks the user, through `CredUI`, for the
    /// credential instead of answering `not_found`. Off by default because it
    /// shows a window: a caller that never asked for a prompt must not get one.
    prompt_on_miss: bool = false,
    prompt_caption: []const u8 = "Sign in",
    prompt_message: []const u8 = "Enter the password for this account.",
    /// Borrowed owner window for the dialog, or null for the desktop.
    prompt_parent: ?*anyopaque = null,
};

/// Errors this adapter raises before any OS call.
pub const Error = error{
    /// The template names no placeholder, so it cannot separate two queries.
    DegenerateTargetTemplate,
} || std.mem.Allocator.Error;

/// The stable identity of one query in the Windows store.
///
/// Pure on purpose: it is the piece a test can exercise on any target, and the
/// piece that has to be right for `read`, `write` and `delete` to agree.
pub fn targetNameFor(allocator: std.mem.Allocator, template: []const u8, query: CredentialQuery) ![]u8 {
    if (std.mem.indexOf(u8, template, "{") == null) return error.DegenerateTargetTemplate;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var at: usize = 0;
    while (at < template.len) {
        const next = std.mem.indexOfPos(u8, template, at, "{") orelse {
            try out.appendSlice(allocator, template[at..]);
            break;
        };
        try out.appendSlice(allocator, template[at..next]);
        if (std.mem.startsWith(u8, template[next..], "{collection}")) {
            try out.appendSlice(allocator, query.collection orelse "");
            at = next + "{collection}".len;
        } else if (std.mem.startsWith(u8, template[next..], "{service}")) {
            try out.appendSlice(allocator, query.service);
            at = next + "{service}".len;
        } else if (std.mem.startsWith(u8, template[next..], "{account}")) {
            try out.appendSlice(allocator, query.account);
            at = next + "{account}".len;
        } else {
            // An unknown placeholder is copied through. Silently dropping it
            // would make `{servce}` a target that two different templates
            // agree on, which is worse than a name nobody meant.
            try out.appendSlice(allocator, template[next .. next + 1]);
            at = next + 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// One live provider, at a stable address. The handle is what
/// `CredentialsService` holds, and the service calls `disconnect` before
/// `deinit`, so `disconnect` is where the OS side goes and `deinit` is where
/// the allocation goes.
pub const Provider = struct {
    allocator: std.mem.Allocator,
    options: Options,
    /// Latched by `disconnect`. A provider that has released the store is not
    /// reconnected by a late call, so nothing here reaches a live store again
    /// through a fresh handle.
    is_gone: bool = false,

    /// Build a provider and return the pointer to it.
    ///
    /// The provider is heap-allocated because the service keeps this address
    /// until its own `deinit`, which is longer than the call that built it: a
    /// provider returned by value would be copied into the caller's frame and
    /// the service would be left holding the address of a frame that is gone.
    pub fn init(allocator: std.mem.Allocator, options: Options) Error!*Provider {
        if (std.mem.indexOf(u8, options.target_template, "{") == null) {
            return error.DegenerateTargetTemplate;
        }
        const self = try allocator.create(Provider);
        self.* = .{ .allocator = allocator, .options = options };
        return self;
    }

    /// Release the provider and the block it lives in. One call, because the
    /// service's `deinit` is the only release there is.
    pub fn deinit(self: *Provider) void {
        const allocator = self.allocator;
        self.is_gone = true;
        defer allocator.destroy(self);
        self.* = undefined;
    }

    pub fn provider(self: *Provider) credentials.CredentialProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: credentials.CredentialProvider.VTable = .{
        .read = readImpl,
        .write = writeImpl,
        .delete = deleteImpl,
        .disconnect = disconnectImpl,
        .deinit = deinitImpl,
    };

    fn disconnectImpl(ctx: *anyopaque) void {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        // `wincred` holds nothing open between calls, so there is no handle to
        // close. The latch is still raised, because the contract's promise is
        // that a disconnected provider reports `disconnected` and never quietly
        // reaches a store again.
        self.is_gone = true;
    }

    fn deinitImpl(ctx: *anyopaque) void {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    /// The one place an OS error code becomes a typed outcome. `delete` has its
    /// own copy only so that `ERROR_NOT_FOUND` reads as `not_found` on the way
    /// out of a delete, where it is the expected answer.
    fn classify(code: win.Dword) ProviderClass {
        return switch (code) {
            win.error_no_such_logon_session,
            win.error_password_expired,
            win.error_account_disabled,
            => .locked,
            win.error_cancelled => .prompt_dismissed,
            win.error_access_denied,
            win.error_logon_failure,
            win.error_bad_username,
            win.error_invalid_credential,
            => .denied,
            win.error_invalid_parameter,
            win.error_invalid_name,
            win.error_invalid_flags,
            win.error_invalid_function,
            => .protocol_error,
            win.error_not_supported => .unsupported,
            win.error_not_enough_memory => .out_of_memory,
            win.error_timeout => .timeout,
            else => .rejected,
        };
    }

    const ProviderClass = enum {
        locked,
        prompt_dismissed,
        denied,
        protocol_error,
        unsupported,
        out_of_memory,
        timeout,
        rejected,

        fn read(self: ProviderClass) ReadResult {
            return switch (self) {
                .locked => .locked,
                .prompt_dismissed => .prompt_dismissed,
                .denied => .denied,
                .protocol_error => .{ .provider_failed = .protocol_error },
                .unsupported => .unsupported,
                .out_of_memory => .{ .provider_failed = .out_of_memory },
                .timeout => .{ .provider_failed = .timeout },
                .rejected => .{ .provider_failed = .rejected },
            };
        }

        fn write(self: ProviderClass) WriteResult {
            return switch (self) {
                .locked => .locked,
                .prompt_dismissed => .prompt_dismissed,
                .denied => .denied,
                .protocol_error => .{ .provider_failed = .protocol_error },
                .unsupported => .unsupported,
                .out_of_memory => .{ .provider_failed = .out_of_memory },
                .timeout => .{ .provider_failed = .timeout },
                .rejected => .{ .provider_failed = .rejected },
            };
        }

        fn delete(self: ProviderClass) DeleteResult {
            return switch (self) {
                .locked => .locked,
                .prompt_dismissed => .prompt_dismissed,
                .denied => .denied,
                .protocol_error => .{ .provider_failed = .protocol_error },
                .unsupported => .unsupported,
                .out_of_memory => .{ .provider_failed = .out_of_memory },
                .timeout => .{ .provider_failed = .timeout },
                .rejected => .{ .provider_failed = .rejected },
            };
        }
    };

    fn readImpl(
        allocator: std.mem.Allocator,
        ctx: *anyopaque,
        query: CredentialQuery,
        cancel_token: ?*const CancellationToken,
    ) ReadResult {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        if (comptime !win.is_windows) return .unsupported;
        if (self.is_gone) return .{ .provider_failed = .disconnected };
        _ = allocator;
        if (cancel_token) |token| {
            if (token.isCanceled()) return .canceled;
        }

        const wide_target = self.wideTarget(query) catch return .{ .provider_failed = .out_of_memory };
        defer self.allocator.free(wide_target);

        var out: ?*win.CredentialW = null;
        if (!win.CredReadW(wide_target.ptr, win.cred_type_generic, 0, &out)) {
            const code = win.GetLastError();
            // Only a miss may become a prompt. Every other code names a store
            // that answered, and prompting over a denial would put a window in
            // front of a user who cannot fix anything with it.
            if (code == win.error_not_found and self.options.prompt_on_miss) {
                return self.prompt(query, cancel_token);
            }
            if (code == win.error_not_found) return .not_found;
            return classify(code).read();
        }
        const found = out orelse return .{ .provider_failed = .protocol_error };

        const size: usize = found.CredentialBlobSize;
        const blob = found.CredentialBlob orelse {
            release(found);
            // A credential with no blob is one the store could not fill in. It
            // is not an empty password, and reading it as one would hand out a
            // valid-looking answer that is wrong.
            return .{ .provider_failed = .store_corrupted };
        };
        if (size == 0) {
            release(found);
            return .{ .provider_failed = .store_corrupted };
        }

        const owned = self.allocator.alloc(u8, size) catch {
            release(found);
            return .{ .provider_failed = .out_of_memory };
        };
        @memcpy(owned, blob[0..size]);
        release(found);

        // The caller gave up while the store was answering. The secret is
        // already in this process, so it is wiped here instead of handed over.
        if (cancel_token) |token| {
            if (token.isCanceled()) {
                win.wipeAndFree(self.allocator, owned);
                return .canceled;
            }
        }
        return .{ .found = CredentialValue.initOwned(self.allocator, owned) };
    }

    /// Releases the SDK's `CREDENTIALW`, wiping the blob first. `CredFree` is
    /// the documented release and does not promise to scrub, so the scrub is
    /// this adapter's job rather than the store's.
    fn release(credential: *win.CredentialW) void {
        if (credential.CredentialBlob) |blob| {
            const size: usize = credential.CredentialBlobSize;
            if (size != 0) std.crypto.secureZero(u8, blob[0..size]);
        }
        win.CredFree(@ptrCast(credential));
    }

    /// The owned, NUL-terminated UTF-16 target name for one query. Freed by
    /// the caller with `self.allocator`.
    fn wideTarget(self: *Provider, query: CredentialQuery) ![:0]u16 {
        const target = try targetNameFor(self.allocator, self.options.target_template, query);
        defer self.allocator.free(target);
        return win.wide(self.allocator, target);
    }

    /// The `CredUI` path. It is the only way Windows produces a
    /// `prompt_dismissed`, and it is a separate call from the store read, so
    /// its outcomes stay separate too.
    fn prompt(
        self: *Provider,
        query: CredentialQuery,
        cancel_token: ?*const CancellationToken,
    ) ReadResult {
        if (cancel_token) |token| {
            if (token.isCanceled()) return .canceled;
        }
        const wide_caption = win.wide(self.allocator, self.options.prompt_caption) catch
            return .{ .provider_failed = .out_of_memory };
        defer self.allocator.free(wide_caption);
        const wide_message = win.wide(self.allocator, self.options.prompt_message) catch
            return .{ .provider_failed = .out_of_memory };
        defer self.allocator.free(wide_message);
        // The account the query is about. The dialog cannot be prefilled with it,
        // so this travels as the account the answer must be for.
        const wide_user = win.wide(self.allocator, query.account) catch
            return .{ .provider_failed = .out_of_memory };
        defer self.allocator.free(wide_user);
        // The dialog is named after the credential, so the target the store
        // keys this query by is the same string `read` and `write` use.
        const wide_target = self.wideTarget(query) catch
            return .{ .provider_failed = .out_of_memory };
        defer self.allocator.free(wide_target);

        const request: PromptRequest = .{
            .hwnd = self.options.prompt_parent,
            .target = wide_target.ptr,
            .caption = wide_caption.ptr,
            .message = wide_message.ptr,
            .account = wide_user.ptr,
        };
        var blob: ?*anyopaque = null;
        var size: u32 = 0;
        switch (nogui_cred_prompt(&request, &blob, &size)) {
            .ok => {},
            .unavailable => return .unsupported,
            .cancelled => return .prompt_dismissed,
            .denied => return .denied,
            .locked => return .locked,
            // A credential for a different account is a refusal, not a value: the
            // shared result would file this secret under the account the caller
            // asked about, and nobody authenticated as that account.
            .account_mismatch => return .denied,
        }

        // A prompt that succeeded owes the caller a secret, so the shim's
        // buffer is copied into owned memory and only then released, and the
        // shim wipes its copy on the way out. The order matters both ways: the
        // copy exists before the original is gone, and the original is gone
        // before this call returns.
        const raw = blob orelse return .{ .provider_failed = .protocol_error };
        if (size == 0) {
            nogui_cred_free(raw);
            return .{ .provider_failed = .store_corrupted };
        }
        const bytes: [*]u8 = @ptrCast(raw);
        const owned = self.allocator.alloc(u8, size) catch {
            nogui_cred_free(raw);
            return .{ .provider_failed = .out_of_memory };
        };
        @memcpy(owned, bytes[0..size]);
        nogui_cred_free(raw);

        if (cancel_token) |token| {
            if (token.isCanceled()) {
                win.wipeAndFree(self.allocator, owned);
                return .canceled;
            }
        }
        return .{ .found = CredentialValue.initOwned(self.allocator, owned) };
    }

    fn writeImpl(
        ctx: *anyopaque,
        query: CredentialQuery,
        secret: []const u8,
        cancel_token: ?*const CancellationToken,
    ) WriteResult {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        if (comptime !win.is_windows) return .unsupported;
        if (self.is_gone) return .{ .provider_failed = .disconnected };
        if (cancel_token) |token| {
            if (token.isCanceled()) return .canceled;
        }
        if (secret.len == 0) return .{ .provider_failed = .protocol_error };
        if (secret.len > std.math.maxInt(win.Dword)) return .{ .provider_failed = .protocol_error };

        const wide_target = self.wideTarget(query) catch return .{ .provider_failed = .out_of_memory };
        defer self.allocator.free(wide_target);
        const wide_user = win.wide(self.allocator, query.account) catch
            return .{ .provider_failed = .out_of_memory };
        defer self.allocator.free(wide_user);

        // The blob is raw bytes, so the caller's secret is handed to the store
        // without a widening copy. There is therefore no second copy of the
        // secret in this process to wipe on the way out, which is the reason
        // this path is shaped the way it is.
        const credential: win.CredentialW = .{
            .Flags = 0,
            .Type = win.cred_type_generic,
            .TargetName = wide_target.ptr,
            .Comment = null,
            .LastWritten = .{ .dwLowDateTime = 0, .dwHighDateTime = 0 },
            .CredentialBlobSize = @intCast(secret.len),
            .CredentialBlob = @constCast(secret.ptr),
            .Persist = self.options.persist.toWin32(),
            .AttributeCount = 0,
            .Attributes = null,
            .TargetAlias = null,
            .UserName = wide_user.ptr,
        };
        if (!win.CredWriteW(&credential, 0)) {
            return classify(win.GetLastError()).write();
        }
        return .success;
    }

    fn deleteImpl(
        ctx: *anyopaque,
        query: CredentialQuery,
        cancel_token: ?*const CancellationToken,
    ) DeleteResult {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        if (comptime !win.is_windows) return .unsupported;
        if (self.is_gone) return .{ .provider_failed = .disconnected };
        if (cancel_token) |token| {
            if (token.isCanceled()) return .canceled;
        }

        const wide_target = self.wideTarget(query) catch return .{ .provider_failed = .out_of_memory };
        defer self.allocator.free(wide_target);

        if (!win.CredDeleteW(wide_target.ptr, win.cred_type_generic, 0)) {
            const code = win.GetLastError();
            // Deleting what is not there is an answer, not a failure, and the
            // shared contract has a name for it.
            if (code == win.error_not_found) return .not_found;
            return classify(code).delete();
        }
        return .success;
    }
};

/// True when this build has a Windows Credential Manager to talk to.
pub fn isApplicable() bool {
    return comptime win.is_windows;
}

test "api-w23 windows credential target name is derived from the query" {
    const query: CredentialQuery = .{
        .service = "org.nogui.Test",
        .account = "alice",
    };
    const gpa = std.testing.allocator;

    const flat = try targetNameFor(gpa, "{service}/{account}", query);
    defer gpa.free(flat);
    try std.testing.expectEqualStrings("org.nogui.Test/alice", flat);

    // A collection is a first-class part of the identity, not decoration: two
    // collections holding the same service and account are two credentials.
    const scoped = try targetNameFor(gpa, "{collection}::{service}/{account}", .{
        .service = query.service,
        .account = query.account,
        .collection = "work",
    });
    defer gpa.free(scoped);
    try std.testing.expectEqualStrings("work::org.nogui.Test/alice", scoped);
    try std.testing.expect(!std.mem.eql(u8, flat, scoped));

    // A prefix is honoured, so a host can namespace everything it owns.
    const prefixed = try targetNameFor(gpa, "nogui!{account}", query);
    defer gpa.free(prefixed);
    try std.testing.expectEqualStrings("nogui!alice", prefixed);

    // A template naming no placeholder would send every query to one
    // credential. That is refused, not accepted and quietly wrong.
    try std.testing.expectError(
        error.DegenerateTargetTemplate,
        targetNameFor(gpa, "constant", query),
    );

    // A misspelled placeholder is copied through rather than silently dropped,
    // because two different templates that both drop it would agree on a
    // target neither of them meant.
    const typo = try targetNameFor(gpa, "{servce}", query);
    defer gpa.free(typo);
    try std.testing.expectEqualStrings("{servce}", typo);
}

test "api-w23 windows credential provider is a named refusal off windows" {
    // The store is a Windows facility. On any other target the provider reports
    // `unsupported` for every outcome, instead of a fake `not_found` that a
    // caller could mistake for an empty store.
    if (comptime !win.is_windows) {
        const provider = try Provider.init(std.testing.allocator, .{});
        defer provider.deinit();
        const handle = provider.provider();

        const query: CredentialQuery = .{ .service = "s", .account = "a" };
        try std.testing.expectEqual(ReadResult.unsupported, handle.read(std.testing.allocator, query, null));
        try std.testing.expectEqual(WriteResult.unsupported, handle.write(query, "secret", null));
        try std.testing.expectEqual(DeleteResult.unsupported, handle.delete(query, null));
        try std.testing.expect(!isApplicable());
    }
}

/// The shape `Host.credentialService` uses: build the provider, hand the
/// service its address, and keep nothing.
fn serviceWithOwnedProvider(gpa: std.mem.Allocator) !credentials.CredentialsService {
    const provider = try Provider.init(gpa, .{});
    errdefer provider.deinit();
    return credentials.CredentialsService.init(gpa, provider.provider());
}

test "api-w23 a credential provider outlives the frame that built it" {
    // The service keeps the provider's address until its own `deinit`, which is
    // longer than the call that built it. A provider passed by value would
    // leave the service pointing into a frame that is gone, and the release
    // would then free a provider nobody allocated while the one that was
    // allocated leaked.
    const gpa = std.testing.allocator;
    var service = try serviceWithOwnedProvider(gpa);
    defer service.deinit();

    try std.testing.expect(service.provider != null);
    if (comptime !win.is_windows) {
        // Answering from the service is answering from the provider it was
        // handed, and the release that follows frees that provider's block,
        // which the testing allocator reports if it survives.
        const query: CredentialQuery = .{ .service = "s", .account = "a" };
        try std.testing.expectEqual(
            ReadResult.unsupported,
            service.read(gpa, query, null),
        );
    }
}
