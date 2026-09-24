//! Windows host services: the one place a Windows build assembles the E03
//! adapters.
//!
//! Every provider in this directory needs the same three things to be usable,
//! and getting them in the wrong order produces failures that look like
//! platform bugs:
//!
//!   1. An AppUserModelID on the process, set before the first window exists.
//!      `app_identity.setProcessIdentity` does that, and everything else here
//!      reads it back rather than assuming it.
//!   2. A `std.Io` that the provider's own locks run against, so the provider
//!      and the host share one instance instead of two that cannot see each
//!      other.
//!   3. An allocator, so a provider holding a secret or a path can be wiped and
//!      freed with a matching one.
//!
//! So the factory takes all three once and hands out finished providers. It is
//! a factory and not a bag of globals because a host may have more than one
//! window, and a process-wide singleton for a per-window thing is the wrong
//! shape.
//!
//! Ownership follows the shared contracts exactly, and the difference matters:
//!
//!   * `NotificationsService` and `CredentialsService` **take ownership** of the
//!     provider handle and call its `deinit` from their own. `Host` builds a
//!     provider, hands it over and does not keep a reference, so a second
//!     release is impossible rather than merely unlikely.
//!   * `capture.Session` does **not** own its `Backend`; the session outlives
//!     frames that point back into the provider, and a provider that went away
//!     first would leave a release callback writing into freed memory. So the
//!     caller keeps the `Provider` and the session only borrows a `Backend`.
//!
//! What is not here is as deliberate as what is. The clipboard and the file
//! dialogs are already correct on Windows through the shared SDL-backed
//! `host/clipboard.zig` and `host/dialogs.zig`, because SDL implements both for
//! this backend; a Windows-specific reimplementation would be a second clipboard
//! and a second dialog, which is the duplication the plan forbids. The same is
//! true of the text-input and IME paths. What Windows adds on top of SDL is what
//! this directory implements: app identity, the jump list, native menus, the
//! credential store, toast notifications, capture, the accessibility attach, and
//! the window interop those need.
const std = @import("std");
const win = @import("win32.zig");
const accessibility = @import("accessibility.zig");
pub const app_identity = @import("app_identity.zig");
const capture = @import("capture.zig");
const credentials = @import("credentials.zig");
const menus = @import("menus.zig");
const notifications = @import("notifications.zig");
pub const jump_list = @import("jump_list.zig");
pub const window_interop = @import("window_interop.zig");

pub const win32 = win;
pub const Accessibility = accessibility;
pub const Capture = capture;
pub const Credentials = credentials;
pub const Menus = menus;
pub const Notifications = notifications;

/// The shared clipboard, re-exported because it is the Windows answer and not a
/// second implementation. See the module comment for why.
pub const clipboard = @import("../clipboard.zig");
/// The shared file dialogs, for the same reason.
pub const dialogs = @import("../dialogs.zig");

pub const Options = struct {
    /// The AppUserModelID to claim. It is set on the process by `init`, and
    /// every other adapter reads it back rather than trusting this string.
    app_id: []const u8,
    /// The credential store's target-name grammar. See
    /// `credentials.Options.target_template`.
    credential_target_template: []const u8 = "{service}/{account}",
    /// A credential read that finds nothing may ask the user through the Windows
    /// credential dialog. Off by default because it shows a window.
    credential_prompt_on_miss: bool = false,
    /// The group Windows files this app's toasts under.
    toast_group: []const u8 = "nogui",
    /// The COM class id the shell activates for this app's toasts. Empty means
    /// no action delivery, and the notification capabilities then say so.
    toast_activator_cls_id: []const u8 = "",
};

pub const Error = app_identity.Error || notifications.Error || credentials.Error || capture.Error;

/// One Windows host's identity and services.
///
/// This owns the AppUserModelID it claimed and nothing else. Providers are built
/// on demand and handed to whoever owns them, so there is no field here that a
/// caller could free twice.
pub const Host = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    /// The identity the shell accepted, kept so a host can report what it is
    /// grouped under without reading the process again.
    identity: app_identity.Identity,

    /// Claim the identity. This must run before the first window is created:
    /// the shell reads the process identity when a window appears, so an
    /// identity set afterwards leaves that window grouped under the fallback.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) !Host {
        const identity = try app_identity.setProcessIdentity(gpa, options.app_id);
        errdefer identity.deinit();
        return .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .identity = identity,
        };
    }

    pub fn deinit(self: *Host) void {
        self.identity.deinit();
        self.* = undefined;
    }

    /// Build the notification service, transferring the provider to it.
    ///
    /// The service calls the provider's `deinit` from its own `deinit`, so the
    /// host must not also release it. `Host` therefore keeps no reference.
    ///
    /// That is also why the service is what drives the provider's transport. A
    /// toast the user clicks arrives on a thread the shell chooses, and
    /// `service.pump` once per frame is the whole of what a host has to do to
    /// hand it to the owner that offered the action. A host that wants the
    /// provider's own diagnostics -- why a toast is silent, how many clicks the
    /// ring dropped -- builds the provider itself and hands it to
    /// `NotificationsService.init`, which is the same ownership in one more
    /// step.
    pub fn notificationService(self: *Host) !notifications.NotificationsService {
        const provider = try notifications.Provider.init(self.gpa, self.io, .{
            .app_id = self.options.app_id,
            .group = self.options.toast_group,
            .activator_cls_id = self.options.toast_activator_cls_id,
        });
        errdefer provider.deinit();
        return notifications.NotificationsService.init(self.gpa, provider.provider());
    }

    /// Build the credential service, transferring the provider to it.
    ///
    /// The same stable address the notification service needs, and for the same
    /// reason: the service outlives this call and releases the provider from
    /// its own `deinit`.
    pub fn credentialService(self: *Host) !credentials.CredentialsService {
        const provider = try credentials.Provider.init(self.gpa, .{
            .target_template = self.options.credential_target_template,
            .prompt_on_miss = self.options.credential_prompt_on_miss,
        });
        errdefer provider.deinit();
        return credentials.CredentialsService.init(self.gpa, provider.provider());
    }

    /// Build a capture provider bound to one session's sink.
    ///
    /// The sink has to be the session's own, because the session is what decides
    /// whether a frame may reach the renderer, and a provider publishing into
    /// anything else would bypass that decision. The caller keeps the provider
    /// and hands the session only a `Backend`.
    ///
    /// No call of this provider's is needed to get frames: the Windows frame
    /// pool is driven by the session while a consumer takes a frame, so a host
    /// that attaches, begins and acquires reaches real frames through the shared
    /// facade alone.
    pub fn captureProvider(self: *Host, sink: capture.Sink, owner: capture.WeakOwner) capture.Provider {
        return capture.Provider.init(self.gpa, self.io, sink, owner);
    }
};

/// Whether this build could serve an accessibility tree at all.
///
/// Two things have to be true, and both are facts about the build rather than
/// intentions: the build has to be a Windows build, and it has to link the
/// AccessKit bridge. A build that can still has nothing to say about a tree
/// until a window is attached, and it still cannot say whether a screen reader
/// is listening: `Accessibility.attach` and `Accessibility.screenReaderAsked`
/// are those two facts, and neither is this one.
pub fn accessibilityAvailable() bool {
    return comptime win.is_windows and Accessibility.linked;
}

/// True when this build has a Windows platform to ask at all.
///
/// A build that does not is not a build whose services are merely off: the
/// identity cannot be claimed, the jump list cannot exist, the credential store
/// is not there, a toast has no shell to show it and a capture has no picker.
/// Each adapter says so by name, and this is the one answer for the directory.
pub fn isApplicable() bool {
    return comptime win.is_windows;
}

test "api-w23 windows host services are a named refusal off windows" {
    // Off Windows there is no shell, no credential store and no capture picker,
    // so the factory refuses before it builds anything. It does not return a
    // half-built host whose providers would each fail differently later.
    if (comptime !win.is_windows) {
        // The factory takes the host's own `std.Io`, so the refusal is
        // exercised against a real one rather than a fabricated vtable.
        var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
        defer threaded.deinit();
        try std.testing.expectError(
            error.InvalidAppId,
            Host.init(std.testing.allocator, threaded.io(), .{ .app_id = "not a valid id" }),
        );
        try std.testing.expect(!isApplicable());
    }
}

test "api-w23 windows accessibility availability is a build fact" {
    // Whether this build could ever attach is a fact about the target and the
    // link, and off Windows it is false. What an adapter is doing is a separate
    // question with its own answer in the adapter module.
    if (comptime !win.is_windows) {
        try std.testing.expect(!accessibilityAvailable());
    }
}

test "api-w23 windows has no primary selection and the shared clipboard says so" {
    // The shared clipboard reports primary-selection support from the live SDL
    // video driver. On Windows the answer is no, and that is a fact the shared
    // code already encodes; this test is what keeps a future Windows adapter
    // from adding a second clipboard that answers differently.
    if (comptime win.is_windows) {
        try std.testing.expect(!clipboard.supportsPrimarySelection());
    }
}

test {
    _ = @import("w23_windows_test.zig");
}
